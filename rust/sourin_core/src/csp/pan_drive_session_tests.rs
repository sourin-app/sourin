use super::*;
use super::super::pan_playback_guard::{self as guard, PlaybackOwner};
use axum::{
    body::{to_bytes, Body},
    http::{Method, Request, StatusCode},
    response::IntoResponse,
    Router,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

const ACCOUNT_A: &str = "fixture-account=A; fixture-session=synthetic-a";
const ACCOUNT_B: &str = "fixture-account=B; fixture-session=synthetic-b";

/// Restore fixture-owned process state even if a RED assertion panics.
struct Isolation {
    restore: Option<Box<dyn FnOnce()>>,
}

impl Isolation {
    fn new() -> Self {
        let saved = std::mem::take(&mut *temp_saved().lock().unwrap_or_else(|e| e.into_inner()));
        let directories = std::mem::take(&mut *temp_dir_cache().lock().unwrap_or_else(|e| e.into_inner()));
        let cookies = std::mem::take(&mut *TEST_COOKIE_OVERRIDES
            .get_or_init(|| Mutex::new(Vec::new())).lock().unwrap_or_else(|e| e.into_inner()));
        Self {
            // Infer both cache types so adding a production session key does not
            // require changing these frozen behavior tests after their RED run.
            restore: Some(Box::new(move || {
                *temp_saved().lock().unwrap_or_else(|e| e.into_inner()) = saved;
                *temp_dir_cache().lock().unwrap_or_else(|e| e.into_inner()) = directories;
                *TEST_COOKIE_OVERRIDES.get().unwrap().lock().unwrap_or_else(|e| e.into_inner()) = cookies;
            })),
        }
    }
}

impl Drop for Isolation {
    fn drop(&mut self) {
        if let Some(restore) = self.restore.take() { restore(); }
    }
}

#[derive(Clone, Debug)]
struct Seen {
    method: Method,
    path: String,
    cookie: String,
    body: Value,
}

#[derive(Clone)]
struct CreationGate {
    entered: Arc<tokio::sync::Semaphore>,
    release: Arc<tokio::sync::Semaphore>,
}

impl CreationGate {
    fn new() -> Self {
        Self {
            entered: Arc::new(tokio::sync::Semaphore::new(0)),
            release: Arc::new(tokio::sync::Semaphore::new(0)),
        }
    }
}

struct Replay {
    drive: PanDrive,
    host: String,
    seen: Arc<Mutex<Vec<Seen>>>,
    fail_delete: Arc<std::sync::atomic::AtomicBool>,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for Replay {
    fn drop(&mut self) {
        self.server.abort();
        PanDrive::debug_set_test_api_base(&self.host, "");
    }
}

impl Replay {
    async fn start(kind: PanKind, endpoint: &'static str, gate: Option<CreationGate>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let host = listener.local_addr().unwrap().to_string();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let captured = seen.clone();
        let fail_delete = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let refuse = fail_delete.clone();
        let app = Router::new().fallback(move |request: Request<Body>| {
            let captured = captured.clone();
            let refuse = refuse.clone();
            let gate = gate.clone();
            async move {
                let (parts, body) = request.into_parts();
                let body = to_bytes(body, 64 * 1024).await.unwrap();
                let request = Seen {
                    method: parts.method,
                    path: parts.uri.path().to_string(),
                    cookie: parts.headers.get("cookie").unwrap().to_str().unwrap().to_string(),
                    body: serde_json::from_slice(&body).unwrap_or(Value::Null),
                };
                captured.lock().unwrap().push(request.clone());
                match (request.method.clone(), request.path.as_str()) {
                    (Method::GET, "/1/clouddrive/file/sort") => {
                        let account = if request.cookie == ACCOUNT_A { "A" } else if request.cookie == ACCOUNT_B {
                            "B"
                        } else {
                            panic!("unexpected fixture credential");
                        };
                        axum::Json(json!({"code":0,"data":{"list":[{
                            "fid":format!("DIR-{endpoint}-{account}"),
                            "file_name":TEMP_DIR_NAME,"dir":true
                        }]}})).into_response()
                    }
                    (Method::POST, "/1/clouddrive/file") => {
                        if let Some(gate) = gate {
                            gate.entered.add_permits(1);
                            gate.release.acquire().await.unwrap().forget();
                        }
                        axum::Json(json!({"code":0,"data":{"fid":request.body["file_name"]}}))
                            .into_response()
                    }
                    (Method::POST, "/1/clouddrive/file/delete") => {
                        if refuse.swap(false, std::sync::atomic::Ordering::SeqCst) {
                            (StatusCode::SERVICE_UNAVAILABLE, axum::Json(json!({"code":503})))
                                .into_response()
                        } else {
                            axum::Json(json!({"code":0})).into_response()
                        }
                    }
                    _ => StatusCode::NOT_FOUND.into_response(),
                }
            }
        });
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        PanDrive::debug_set_test_api_base(&host, &format!("http://{host}"));
        let mut spec = if kind == PanKind::Quark { quark_spec() } else { uc_spec() };
        spec.api_host = Box::leak(host.clone().into_boxed_str());
        Self { drive: PanDrive::with_spec("SessionFixture", spec), host, seen, fail_delete, server }
    }

    fn requests(&self, path: &str) -> Vec<Seen> {
        self.seen.lock().unwrap().iter().filter(|r| r.path == path).cloned().collect()
    }

    fn deletes(&self) -> Vec<Seen> {
        self.requests("/1/clouddrive/file/delete")
    }
}

fn owner(kind: PanKind, label: &str, generation: u64) -> PlaybackOwner {
    PlaybackOwner { consumer: format!("session-fixture-{}-{label}", kind.code()), generation }
}

fn select_account(kind: PanKind, cookie: &str) {
    PanDrive::debug_set_test_cookie(kind.code(), cookie);
}

async fn create_owned(replay: &Replay, cookie: &str, owner: Option<PlaybackOwner>, fid: &str) {
    guard::register(owner.clone()).unwrap();
    let legacy = owner.is_none();
    guard::with_scope(owner, async {
        let created = replay.drive.ensure_dir_under(cookie, "0", fid).await.unwrap();
        assert_eq!(created, fid);
        // The legacy production caller records a returned directory itself.
        if legacy { replay.drive.remember_temp(&created); }
    }).await;
}

fn assert_delete(request: &Seen, cookie: &str, fid: &str) {
    assert_eq!(request.cookie, cookie);
    assert_eq!(request.body["action_type"], 2);
    assert_eq!(request.body["filelist"], json!([fid]));
    assert_eq!(request.body["exclude_fids"], json!([]));
}

async fn cache_accounts(kind: PanKind) {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _isolation = Isolation::new();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let replay = Replay::start(kind, "ONE", None).await;
    assert_eq!(replay.drive.ensure_temp_dir(ACCOUNT_A).await.unwrap(), "DIR-ONE-A");
    assert_eq!(replay.drive.ensure_temp_dir(ACCOUNT_B).await.unwrap(), "DIR-ONE-B",
        "another account must not reuse the first account's cached directory");
    assert_eq!(replay.drive.ensure_temp_dir(ACCOUNT_A).await.unwrap(), "DIR-ONE-A");
    let lists = replay.requests("/1/clouddrive/file/sort");
    assert_eq!(lists.iter().map(|r| r.cookie.as_str()).collect::<Vec<_>>(), [ACCOUNT_A, ACCOUNT_B]);
}

async fn cache_endpoints(kind: PanKind) {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _isolation = Isolation::new();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let a = Replay::start(kind, "ONE", None).await;
    let b = Replay::start(kind, "TWO", None).await;
    assert_eq!(a.drive.ensure_temp_dir(ACCOUNT_A).await.unwrap(), "DIR-ONE-A");
    assert_eq!(b.drive.ensure_temp_dir(ACCOUNT_A).await.unwrap(), "DIR-TWO-A",
        "another endpoint must not reuse a directory from the first endpoint");
    assert_eq!(a.drive.ensure_temp_dir(ACCOUNT_A).await.unwrap(), "DIR-ONE-A");
    assert_eq!(a.requests("/1/clouddrive/file/sort").len(), 1);
    assert_eq!(b.requests("/1/clouddrive/file/sort").len(), 1);
}

async fn cleanup_accounts(kind: PanKind) {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _isolation = Isolation::new();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let replay = Replay::start(kind, "ONE", None).await;
    let owner = owner(kind, "accounts", 1);
    select_account(kind, ACCOUNT_A);
    create_owned(&replay, ACCOUNT_A, Some(owner.clone()), "SAME-FID").await;
    select_account(kind, ACCOUNT_B);
    create_owned(&replay, ACCOUNT_B, Some(owner.clone()), "SAME-FID").await;
    replay.drive.purge_owned(Some(owner.clone())).await;
    let deleted = replay.deletes();
    assert_eq!(deleted.len(), 1, "B cleanup must only consume B's record despite identical kind/owner/fid");
    assert_delete(&deleted[0], ACCOUNT_B, "SAME-FID");
    select_account(kind, ACCOUNT_A);
    replay.drive.purge_owned(Some(owner)).await;
    let deleted = replay.deletes();
    assert_eq!(deleted.len(), 2, "A's record must remain available for A's later cleanup");
    assert_delete(&deleted[1], ACCOUNT_A, "SAME-FID");
}

async fn cleanup_endpoints(kind: PanKind) {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _isolation = Isolation::new();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let a = Replay::start(kind, "ONE", None).await;
    let b = Replay::start(kind, "TWO", None).await;
    let owner = owner(kind, "endpoints", 1);
    select_account(kind, ACCOUNT_A);
    create_owned(&a, ACCOUNT_A, Some(owner.clone()), "SAME-FID").await;
    create_owned(&b, ACCOUNT_A, Some(owner.clone()), "SAME-FID").await;
    b.drive.purge_owned(Some(owner.clone())).await;
    assert_eq!(b.deletes().len(), 1, "B cannot consume a same-fid record belonging to endpoint A");
    assert!(a.deletes().is_empty());
    a.drive.purge_owned(Some(owner)).await;
    assert_eq!(a.deletes().len(), 1, "the original endpoint must retain its cleanup record");
    assert_delete(&a.deletes()[0], ACCOUNT_A, "SAME-FID");
    assert_delete(&b.deletes()[0], ACCOUNT_A, "SAME-FID");
}

async fn late_creation(kind: PanKind) {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _isolation = Isolation::new();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let gate = CreationGate::new();
    let replay = Replay::start(kind, "ONE", Some(gate.clone())).await;
    let owner = owner(kind, "late-creation", 1);
    select_account(kind, ACCOUNT_A);
    let create = create_owned(&replay, ACCOUNT_A, Some(owner.clone()), "SAME-FID");
    let switch = async {
        tokio::time::timeout(Duration::from_secs(3), gate.entered.acquire())
            .await.unwrap().unwrap().forget();
        select_account(kind, ACCOUNT_B);
        gate.release.add_permits(1);
    };
    tokio::join!(create, switch);
    let created = replay.requests("/1/clouddrive/file");
    assert_eq!(created.len(), 1);
    assert_eq!(created[0].cookie, ACCOUNT_A);
    replay.drive.purge_owned(Some(owner.clone())).await;
    assert!(replay.deletes().is_empty(), "a late A response cannot become a B-owned resource");
    select_account(kind, ACCOUNT_A);
    replay.drive.purge_owned(Some(owner)).await;
    assert_eq!(replay.deletes().len(), 1);
    assert_delete(&replay.deletes()[0], ACCOUNT_A, "SAME-FID");
}

async fn failed_cleanup(kind: PanKind) {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _isolation = Isolation::new();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let replay = Replay::start(kind, "ONE", None).await;
    let owner = owner(kind, "failed-delete", 1);
    select_account(kind, ACCOUNT_A);
    create_owned(&replay, ACCOUNT_A, Some(owner.clone()), "SAME-FID").await;
    select_account(kind, ACCOUNT_B);
    create_owned(&replay, ACCOUNT_B, Some(owner.clone()), "SAME-FID").await;
    replay.fail_delete.store(true, std::sync::atomic::Ordering::SeqCst);
    replay.drive.purge_owned(Some(owner.clone())).await;
    assert_eq!(replay.deletes().len(), 1, "failed B cleanup must not also attempt A's record with B credentials");
    select_account(kind, ACCOUNT_A);
    replay.drive.purge_owned(Some(owner.clone())).await;
    let deleted = replay.deletes();
    assert_eq!(deleted.len(), 2);
    assert_delete(&deleted[1], ACCOUNT_A, "SAME-FID");
    select_account(kind, ACCOUNT_B);
    replay.drive.purge_owned(Some(owner)).await;
    let deleted = replay.deletes();
    assert_eq!(deleted.len(), 3, "failed B record must survive A cleanup and remain retryable");
    assert_delete(&deleted[2], ACCOUNT_B, "SAME-FID");
}

async fn ownership_boundaries(kind: PanKind) {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _isolation = Isolation::new();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let replay = Replay::start(kind, "ONE", None).await;
    let old = owner(kind, "owner-preserved", 1);
    let new = owner(kind, "owner-preserved", 2);
    let other = owner(kind, "other-consumer", 1);
    select_account(kind, ACCOUNT_A);
    for (owner, fid) in [(Some(old.clone()), "OLD"), (Some(new.clone()), "NEW"),
        (Some(other.clone()), "OTHER"), (None, "LEGACY")] {
        create_owned(&replay, ACCOUNT_A, owner, fid).await;
    }
    for (target, fid) in [(Some(old), "OLD"), (None, "LEGACY"), (Some(other), "OTHER"), (Some(new), "NEW")] {
        let previous = replay.deletes().len();
        replay.drive.purge_owned(target).await;
        let deleted = replay.deletes();
        assert_eq!(deleted.len(), previous + 1, "cleanup must retain other consumer, later generation and legacy boundaries");
        assert_delete(deleted.last().unwrap(), ACCOUNT_A, fid);
    }
}

macro_rules! session_cases {
    ($name:ident, $case:ident, $kind:expr) => {
        #[tokio::test]
        async fn $name() { $case($kind).await; }
    };
}

session_cases!(quark_temp_directory_cache_does_not_cross_accounts, cache_accounts, PanKind::Quark);
session_cases!(uc_temp_directory_cache_does_not_cross_accounts, cache_accounts, PanKind::Uc);
session_cases!(quark_temp_directory_cache_does_not_cross_endpoints, cache_endpoints, PanKind::Quark);
session_cases!(uc_temp_directory_cache_does_not_cross_endpoints, cache_endpoints, PanKind::Uc);
session_cases!(quark_cleanup_same_owner_and_fid_does_not_cross_accounts, cleanup_accounts, PanKind::Quark);
session_cases!(uc_cleanup_same_owner_and_fid_does_not_cross_accounts, cleanup_accounts, PanKind::Uc);
session_cases!(quark_cleanup_same_owner_and_fid_does_not_cross_endpoints, cleanup_endpoints, PanKind::Quark);
session_cases!(uc_cleanup_same_owner_and_fid_does_not_cross_endpoints, cleanup_endpoints, PanKind::Uc);
session_cases!(quark_late_creation_keeps_request_account_after_login_switch, late_creation, PanKind::Quark);
session_cases!(uc_late_creation_keeps_request_account_after_login_switch, late_creation, PanKind::Uc);
session_cases!(quark_failed_cleanup_keeps_only_its_account_record_for_retry, failed_cleanup, PanKind::Quark);
session_cases!(uc_failed_cleanup_keeps_only_its_account_record_for_retry, failed_cleanup, PanKind::Uc);
session_cases!(quark_session_fix_preserves_owner_generation_and_legacy_boundaries, ownership_boundaries, PanKind::Quark);
session_cases!(uc_session_fix_preserves_owner_generation_and_legacy_boundaries, ownership_boundaries, PanKind::Uc);
