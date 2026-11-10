use super::*;
use super::super::pan_playback_guard::{self as guard, PlaybackOwner};
use axum::{
    body::{to_bytes, Body},
    http::{Method, Request, StatusCode},
    response::IntoResponse,
    Router,
};
use serde_json::{json, Value};
use std::sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex};

const ACCOUNT_A: &str = "fixture-account=A; fixture-session=operation-a";
const ACCOUNT_B: &str = "fixture-account=B; fixture-session=operation-b";
const SHARED_FID: &str = "SAME-OWNER-SAME-FID";

struct Isolation(Option<Box<dyn FnOnce()>>);

impl Isolation {
    fn new() -> Self {
        let saved = std::mem::take(&mut *temp_saved().lock().unwrap_or_else(|e| e.into_inner()));
        let directories = std::mem::take(&mut *temp_dir_cache().lock().unwrap_or_else(|e| e.into_inner()));
        let cookies = std::mem::take(&mut *TEST_COOKIE_OVERRIDES
            .get_or_init(|| Mutex::new(Vec::new())).lock().unwrap_or_else(|e| e.into_inner()));
        Self(Some(Box::new(move || {
            *temp_saved().lock().unwrap_or_else(|e| e.into_inner()) = saved;
            *temp_dir_cache().lock().unwrap_or_else(|e| e.into_inner()) = directories;
            *TEST_COOKIE_OVERRIDES.get().unwrap().lock().unwrap_or_else(|e| e.into_inner()) = cookies;
        })))
    }
}

impl Drop for Isolation {
    fn drop(&mut self) {
        if let Some(restore) = self.0.take() { restore(); }
    }
}

#[derive(Clone, Copy)]
enum Entry {
    Degrade,
    Share,
    Selected,
}

impl Entry {
    fn label(self) -> &'static str {
        match self { Self::Degrade => "degrade", Self::Share => "share", Self::Selected => "selected" }
    }

    fn gate_path(self) -> &'static str {
        match self {
            Self::Degrade => "/1/clouddrive/task",
            Self::Share | Self::Selected => "/1/clouddrive/share/sharepage/detail",
        }
    }

    fn expected_source(self) -> &'static str {
        match self { Self::Share => "LARGER-FILE", Self::Degrade | Self::Selected => "SELECTED-FILE" }
    }
}

#[derive(Clone)]
struct Gate {
    entered: Arc<tokio::sync::Semaphore>,
    release: Arc<tokio::sync::Semaphore>,
    used: Arc<AtomicBool>,
}

impl Gate {
    fn new() -> Self {
        Self {
            entered: Arc::new(tokio::sync::Semaphore::new(0)),
            release: Arc::new(tokio::sync::Semaphore::new(0)),
            used: Arc::new(AtomicBool::new(false)),
        }
    }
}

#[derive(Clone, Debug)]
struct Seen {
    method: Method,
    path: String,
    cookie: String,
    body: Value,
}

struct Replay {
    drive: PanDrive,
    checker: crate::pan_check::PanChecker,
    host: String,
    seen: Arc<Mutex<Vec<Seen>>>,
    gate: Gate,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for Replay {
    fn drop(&mut self) {
        self.server.abort();
        PanDrive::debug_set_test_api_base(&self.host, "");
    }
}

impl Replay {
    async fn start(kind: PanKind, entry: Entry) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let host = listener.local_addr().unwrap().to_string();
        let base = format!("http://{host}");
        let seen = Arc::new(Mutex::new(Vec::new()));
        let captured = seen.clone();
        let gate = Gate::new();
        let pause = gate.clone();
        let saved_fid = Arc::new(Mutex::new(String::new()));
        let app = Router::new().fallback(move |request: Request<Body>| {
            let captured = captured.clone();
            let pause = pause.clone();
            let saved_fid = saved_fid.clone();
            async move {
                let (parts, body) = request.into_parts();
                let body = to_bytes(body, 64 * 1024).await.unwrap();
                let query: std::collections::HashMap<String, String> =
                    reqwest::Url::parse(&format!("http://fixture{}", parts.uri)).unwrap()
                        .query_pairs().into_owned().collect();
                let request = Seen {
                    method: parts.method,
                    path: parts.uri.path().to_string(),
                    cookie: parts.headers.get("cookie").map(|v| v.to_str().unwrap()).unwrap_or("").to_string(),
                    body: serde_json::from_slice(&body).unwrap_or(Value::Null),
                };
                captured.lock().unwrap().push(request.clone());
                if request.path == entry.gate_path() && !pause.used.swap(true, Ordering::SeqCst) {
                    assert_eq!(request.cookie, ACCOUNT_A, "the paused operation must start under A");
                    pause.entered.add_permits(1);
                    pause.release.acquire().await.unwrap().forget();
                }
                let account = if request.cookie == ACCOUNT_A { "A" } else if request.cookie == ACCOUNT_B {
                    "B"
                } else { "anonymous" };
                let value = match (request.method.clone(), request.path.as_str()) {
                    (Method::GET, path) if path.starts_with("/gatepage/") => {
                        return (StatusCode::OK, "fixture share page").into_response();
                    }
                    (Method::POST, "/gate_token") => json!({"status":200,"code":0,"data":{"stoken":"CHECK"}}),
                    (Method::GET, "/gate_detail") => json!({"status":200,"code":0,"data":{"list":[{
                        "fid":"gate-file","file_name":"gate.mp4","file_type":1,"size":1
                    }]}}),
                    (Method::POST, "/1/clouddrive/share/sharepage/token") => {
                        json!({"status":200,"code":0,"data":{"stoken":"OPERATION-TOKEN"}})
                    }
                    (Method::GET, "/1/clouddrive/share/sharepage/detail") => {
                        let stoken = query.get("stoken").unwrap();
                        json!({"status":200,"code":0,"data":{"list":[
                            {"fid":"LARGER-FILE","file_name":"Episode01.mkv","size":9000,"dir":false,
                                "share_fid_token":format!("{stoken}/LARGER-FILE")},
                            {"fid":"SELECTED-FILE","file_name":"Episode02.mkv","size":100,"dir":false,
                                "share_fid_token":format!("{stoken}/SELECTED-FILE")}
                        ]}})
                    }
                    (Method::GET, "/1/clouddrive/file/sort") => {
                        let list = if query.get("pdir_fid").map(String::as_str) == Some("0") {
                            json!([{"fid":format!("TEMP-{account}"),"file_name":TEMP_DIR_NAME,"dir":true}])
                        } else { json!([]) };
                        json!({"code":0,"data":{"list":list}})
                    }
                    (Method::POST, "/1/clouddrive/file") => {
                        json!({"code":0,"data":{"fid":request.body["file_name"]}})
                    }
                    (Method::POST, "/1/clouddrive/share/sharepage/save") => {
                        let source = request.body["fid_list"][0].as_str().unwrap();
                        *saved_fid.lock().unwrap() = format!("COPY-{source}");
                        json!({"status":200,"code":0,"data":{"task_id":"SAVE-TASK"}})
                    }
                    (Method::GET, "/1/clouddrive/task") => {
                        let fid = saved_fid.lock().unwrap().clone();
                        assert!(!fid.is_empty(), "the real save must precede task polling");
                        json!({"status":200,"code":0,"data":{"status":2,"save_as":{"save_as_top_fids":[fid]}}})
                    }
                    (Method::POST, "/1/clouddrive/file/download") => {
                        json!({"code":0,"data":[{"download_url":"https://fixture.invalid/media.mp4"}]})
                    }
                    (Method::POST, "/1/clouddrive/file/delete") => json!({"code":0}),
                    _ => return StatusCode::NOT_FOUND.into_response(),
                };
                axum::Json(value).into_response()
            }
        });
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        PanDrive::debug_set_test_api_base(&host, &base);
        let mut spec = if kind == PanKind::Quark { quark_spec() } else { uc_spec() };
        spec.api_host = Box::leak(host.clone().into_boxed_str());
        let checker = crate::pan_check::PanChecker::with_endpoints(crate::pan_check::PanEndpoints {
            quark_page: format!("{base}/gatepage"),
            quark_token: format!("{base}/gate_token"),
            quark_detail: format!("{base}/gate_detail"),
            uc_page: format!("{base}/gatepage"),
            uc_token: format!("{base}/gate_token"),
            uc_detail: format!("{base}/gate_detail"),
            baidu_page: format!("{base}/unused"),
            baidu_verify: format!("{base}/unused"),
            baidu_list: format!("{base}/unused"),
            xunlei_captcha: format!("{base}/unused"),
            xunlei_share: format!("{base}/unused"),
            aliyun_anon: format!("{base}/unused"),
        });
        Self { drive: PanDrive::with_spec("OperationFixture", spec), checker, host, seen, gate, server }
    }

    fn requests(&self, path: &str) -> Vec<Seen> {
        self.seen.lock().unwrap().iter().filter(|r| r.path == path).cloned().collect()
    }

    fn deletes(&self) -> Vec<Seen> {
        self.requests("/1/clouddrive/file/delete")
    }
}

async fn seed_account(replay: &Replay, kind: PanKind, cookie: &str, owner: &PlaybackOwner) {
    PanDrive::debug_set_test_cookie(kind.code(), cookie);
    guard::with_scope(Some(owner.clone()), async {
        assert_eq!(replay.drive.ensure_dir_under(cookie, "0", SHARED_FID).await.unwrap(), SHARED_FID);
    }).await;
}

async fn run_entry(replay: &Replay, kind: PanKind, entry: Entry) -> Result<CspPlay, String> {
    match entry {
        Entry::Degrade => replay.drive.degrade_attempt(ACCOUNT_A, "fixture", "", &DriveEntry {
            fid: "SELECTED-FILE".into(), name: "Episode02.mkv".into(), size: 100,
            is_dir: false, fid_token: Some("stale-token".into()),
        }).await,
        Entry::Share => replay.drive.resolve_share_play("fixture", "").await,
        Entry::Selected => {
            let url = if kind == PanKind::Quark {
                "https://pan.quark.cn/s/fixture"
            } else { "https://drive.uc.cn/s/fixture" };
            super::super::pan_episode_select::resolve_family_with(
                &replay.checker, &replay.drive, url, "fixture", "", Some("SELECTED-FILE"),
                &super::super::pan_episode_select::EpisodeSpec::default(),
            ).await
        }
    }
}

fn assert_delete(request: &Seen, cookie: &str, fid: &str) {
    assert_eq!(request.cookie, cookie);
    assert_eq!(request.body["action_type"], 2);
    assert_eq!(request.body["filelist"], json!([fid]));
    assert_eq!(request.body["exclude_fids"], json!([]));
}

async fn operation_keeps_original_session(kind: PanKind, entry: Entry) {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _isolation = Isolation::new();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let replay = Replay::start(kind, entry).await;
    let owner = PlaybackOwner {
        consumer: format!("operation-session-{}-{}", kind.code(), entry.label()), generation: 1,
    };
    guard::register(Some(owner.clone())).unwrap();
    // Real mkdir responses create both ledger records; equal kind/owner/fid is intentional.
    seed_account(&replay, kind, ACCOUNT_A, &owner).await;
    seed_account(&replay, kind, ACCOUNT_B, &owner).await;
    replay.seen.lock().unwrap().clear();
    PanDrive::debug_set_test_cookie(kind.code(), ACCOUNT_A);
    let switch = async {
        tokio::time::timeout(Duration::from_secs(5), replay.gate.entered.acquire())
            .await.unwrap().unwrap().forget();
        PanDrive::debug_set_test_cookie(kind.code(), ACCOUNT_B);
        replay.gate.release.add_permits(1);
    };
    let (result, ()) = tokio::join!(
        guard::with_scope(Some(owner.clone()), run_entry(&replay, kind, entry)), switch,
    );
    let play = result.unwrap();
    assert!(replay.gate.used.load(Ordering::SeqCst));
    let automatic = replay.deletes();
    if matches!(entry, Entry::Degrade) {
        assert!(automatic.is_empty(), "degrade_attempt does not initiate cleanup");
    } else {
        assert_eq!(automatic.len(), 1, "the operation must clean its one prior A resource");
        assert_delete(&automatic[0], ACCOUNT_A, SHARED_FID);
    }

    let expected_copy = format!("COPY-{}", entry.expected_source());
    let saved = replay.requests("/1/clouddrive/share/sharepage/save");
    assert_eq!(saved.len(), 1);
    assert_eq!(saved[0].cookie, ACCOUNT_A);
    assert_eq!(saved[0].body["fid_list"], json!([entry.expected_source()]));
    assert_eq!(saved[0].body["fid_token_list"], json!([format!("OPERATION-TOKEN/{}", entry.expected_source())]));
    let downloaded = replay.requests("/1/clouddrive/file/download");
    assert_eq!(downloaded.len(), 1);
    assert_eq!(downloaded[0].cookie, ACCOUNT_A, "the saved A copy must never be downloaded with the new B login");
    assert_eq!(downloaded[0].body["fids"], json!([expected_copy]));
    assert_eq!(play.url, "https://fixture.invalid/media.mp4");
    assert_eq!(play.headers.iter().find(|(name, _)| name == "Cookie").map(|(_, value)| value.as_str()), Some(ACCOUNT_A));
    assert!(replay.seen.lock().unwrap().iter()
        .filter(|request| request.path.starts_with("/1/clouddrive/"))
        .all(|request| request.cookie == ACCOUNT_A), "all authenticated operation requests must retain A");
    if matches!(entry, Entry::Selected) {
        assert_eq!(replay.requests("/gate_token").len(), 1, "selected-file entry must run the real validity check");
    }

    // Explicit B cleanup after the operation may consume only B's original record.
    let before = replay.deletes().len();
    replay.drive.purge_owned(Some(owner.clone())).await;
    let deleted = replay.deletes();
    assert_eq!(deleted.len(), before + 1, "the A operation must leave B's identical record available");
    assert_delete(deleted.last().unwrap(), ACCOUNT_B, SHARED_FID);
    PanDrive::debug_set_test_cookie(kind.code(), ACCOUNT_A);
    let before = deleted.len();
    replay.drive.purge_owned(Some(owner)).await;
    let deleted = replay.deletes();
    let expected_count = if matches!(entry, Entry::Degrade) { 3 } else { 2 };
    assert_eq!(deleted.len(), before + expected_count);
    assert!(deleted[before..].iter().all(|request| request.cookie == ACCOUNT_A));
    assert_delete(&deleted[before], ACCOUNT_A, &expected_copy);
    if matches!(entry, Entry::Degrade) {
        assert_delete(deleted.last().unwrap(), ACCOUNT_A, SHARED_FID);
    }
    assert!(temp_saved().lock().unwrap_or_else(|e| e.into_inner()).is_empty());
}

macro_rules! operation_cases {
    ($name:ident, $kind:expr, $entry:expr) => {
        #[tokio::test]
        async fn $name() { operation_keeps_original_session($kind, $entry).await; }
    };
}

operation_cases!(quark_degrade_download_keeps_original_session_after_save_await, PanKind::Quark, Entry::Degrade);
operation_cases!(uc_degrade_download_keeps_original_session_after_save_await, PanKind::Uc, Entry::Degrade);
operation_cases!(quark_resolve_share_cleanup_keeps_original_session_after_listing_await, PanKind::Quark, Entry::Share);
operation_cases!(uc_resolve_share_cleanup_keeps_original_session_after_listing_await, PanKind::Uc, Entry::Share);
operation_cases!(quark_selected_file_cleanup_keeps_original_session_after_listing_await, PanKind::Quark, Entry::Selected);
operation_cases!(uc_selected_file_cleanup_keeps_original_session_after_listing_await, PanKind::Uc, Entry::Selected);
