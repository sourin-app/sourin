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

const ORIGINAL: &str = "fixture-account=A; fixture-session=old; fixture-marker=stable";
const ROTATED: &str = "fixture-account=A; fixture-session=new; fixture-marker=stable";
const REORDERED: &str = "fixture-marker=stable; fixture-account=A; fixture-session=old";
const COPIED_FID: &str = "SAME-ACCOUNT-DEDUPLICATED-COPY";
const SOURCE_FID: &str = "SHARED-EPISODE";

/// Restore only fixture-owned state; never read a real account or insert ledger records.
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

#[derive(Clone, Debug)]
struct Seen {
    method: Method,
    path: String,
    cookie: String,
    body: Value,
}

#[derive(Default)]
struct Cloud {
    copy_parent: Option<String>,
    copy_exists: bool,
    save_count: usize,
}

struct Replay {
    drive: PanDrive,
    host: String,
    seen: Arc<Mutex<Vec<Seen>>>,
    cloud: Arc<Mutex<Cloud>>,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for Replay {
    fn drop(&mut self) {
        self.server.abort();
        PanDrive::debug_set_test_api_base(&self.host, "");
    }
}

impl Replay {
    async fn start(kind: PanKind, changed_cookie: &'static str) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let host = listener.local_addr().unwrap().to_string();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let captured = seen.clone();
        let cloud = Arc::new(Mutex::new(Cloud::default()));
        let stored = cloud.clone();
        let app = Router::new().fallback(move |request: Request<Body>| {
            let captured = captured.clone();
            let stored = stored.clone();
            async move {
                let (parts, body) = request.into_parts();
                let body = to_bytes(body, 64 * 1024).await.unwrap();
                let query: std::collections::HashMap<String, String> =
                    reqwest::Url::parse(&format!("http://fixture{}", parts.uri)).unwrap()
                        .query_pairs().into_owned().collect();
                let request = Seen {
                    method: parts.method,
                    path: parts.uri.path().to_string(),
                    cookie: parts.headers.get("cookie").unwrap().to_str().unwrap().to_string(),
                    body: serde_json::from_slice(&body).unwrap_or(Value::Null),
                };
                // The fixture server explicitly accepts both credentials for one account.
                // Production must not infer account identity from these synthetic fields.
                assert!(request.cookie == ORIGINAL || request.cookie == changed_cookie);
                captured.lock().unwrap().push(request.clone());
                let value = match (request.method.clone(), request.path.as_str()) {
                    (Method::POST, "/1/clouddrive/share/sharepage/token") => {
                        json!({"status":200,"code":0,"data":{"stoken":"ROTATION-TOKEN"}})
                    }
                    (Method::GET, "/1/clouddrive/share/sharepage/detail") => {
                        assert_eq!(query.get("stoken").map(String::as_str), Some("ROTATION-TOKEN"));
                        json!({"status":200,"code":0,"data":{"list":[{
                            "fid":SOURCE_FID,"file_name":"Episode01.mkv","size":100,"dir":false,
                            "share_fid_token":"ROTATION-TOKEN/SHARED-EPISODE"
                        }]}})
                    }
                    (Method::GET, "/1/clouddrive/file/sort") => {
                        let list = if query.get("pdir_fid").map(String::as_str) == Some("0") {
                            json!([{"fid":"ACCOUNT-A-TEMP","file_name":TEMP_DIR_NAME,"dir":true}])
                        } else { json!([]) };
                        json!({"code":0,"data":{"list":list}})
                    }
                    (Method::POST, "/1/clouddrive/file") => {
                        assert_eq!(request.body["pdir_fid"], "ACCOUNT-A-TEMP");
                        json!({"code":0,"data":{"fid":request.body["file_name"]}})
                    }
                    (Method::POST, "/1/clouddrive/share/sharepage/save") => {
                        assert_eq!(request.body["fid_list"], json!([SOURCE_FID]));
                        assert_eq!(request.body["fid_token_list"], json!(["ROTATION-TOKEN/SHARED-EPISODE"]));
                        let mut cloud = stored.lock().unwrap();
                        cloud.save_count += 1;
                        if cloud.copy_parent.is_none() {
                            cloud.copy_parent = Some(request.body["to_pdir_fid"].as_str().unwrap().into());
                            cloud.copy_exists = true;
                        }
                        // Later content-deduplicated saves echo the original account fid;
                        // the second operation's unique directory remains empty.
                        json!({"status":200,"code":0,"data":{"task_id":format!("SAVE-{}", cloud.save_count)}})
                    }
                    (Method::GET, "/1/clouddrive/task") => {
                        let cloud = stored.lock().unwrap();
                        assert!(cloud.save_count > 0);
                        assert_eq!(query.get("task_id").unwrap(), &format!("SAVE-{}", cloud.save_count));
                        json!({"status":200,"code":0,"data":{"status":2,"save_as":{
                            "save_as_top_fids":[COPIED_FID]
                        }}})
                    }
                    (Method::POST, "/1/clouddrive/file/download") => {
                        assert_eq!(request.body["fids"], json!([COPIED_FID]));
                        assert!(stored.lock().unwrap().copy_exists, "download must address the live account copy");
                        json!({"code":0,"data":[{"download_url":"https://fixture.invalid/episode.mp4"}]})
                    }
                    (Method::POST, "/1/clouddrive/file/delete") => {
                        let fid = request.body["filelist"][0].as_str().unwrap();
                        let mut cloud = stored.lock().unwrap();
                        if fid == COPIED_FID || cloud.copy_parent.as_deref() == Some(fid) {
                            cloud.copy_exists = false;
                        }
                        json!({"code":0})
                    }
                    _ => return StatusCode::NOT_FOUND.into_response(),
                };
                axum::Json(value).into_response()
            }
        });
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        PanDrive::debug_set_test_api_base(&host, &format!("http://{host}"));
        let mut spec = if kind == PanKind::Quark { quark_spec() } else { uc_spec() };
        spec.api_host = Box::leak(host.clone().into_boxed_str());
        Self { drive: PanDrive::with_spec("CookieRotationFixture", spec), host, seen, cloud, server }
    }

    fn requests(&self, path: &str) -> Vec<Seen> {
        self.seen.lock().unwrap().iter().filter(|request| request.path == path).cloned().collect()
    }

    fn deletes(&self) -> Vec<Seen> {
        self.requests("/1/clouddrive/file/delete")
    }
}

async fn resolve_for(replay: &Replay, kind: PanKind, cookie: &str, owner: &PlaybackOwner) -> Result<CspPlay, String> {
    PanDrive::debug_set_test_cookie(kind.code(), cookie);
    guard::register(Some(owner.clone())).unwrap();
    tokio::time::timeout(Duration::from_secs(10), guard::with_scope(Some(owner.clone()),
        replay.drive.resolve_share_play("rotation-fixture", ""),
    )).await.expect("loopback resolution must complete within the fixture budget")
}

fn assert_delete(request: &Seen, cookie: &str, fid: &str) {
    assert_eq!(request.cookie, cookie);
    assert_eq!(request.body["action_type"], 2);
    assert_eq!(request.body["filelist"], json!([fid]));
    assert_eq!(request.body["exclude_fids"], json!([]));
}

async fn changed_cookie_cannot_steal_copy(kind: PanKind, label: &str, changed_cookie: &'static str) {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _isolation = Isolation::new();
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let replay = Replay::start(kind, changed_cookie).await;
    let old = PlaybackOwner { consumer: format!("cookie-{label}-{}-first", kind.code()), generation: 1 };
    let new = PlaybackOwner { consumer: format!("cookie-{label}-{}-second", kind.code()), generation: 1 };
    let first = resolve_for(&replay, kind, ORIGINAL, &old).await.unwrap();
    assert_eq!(first.url, "https://fixture.invalid/episode.mp4");
    assert_eq!(replay.requests("/1/clouddrive/file/download").len(), 1);
    assert!(replay.deletes().is_empty());

    let second = resolve_for(&replay, kind, changed_cookie, &new).await;
    // Exercise exit cleanup before asserting the rejected result so RED captures
    // the destructive effect of an incorrectly accepted duplicate, not just an Ok.
    guard::invalidate(&new);
    replay.drive.purge_owned(Some(new.clone())).await;
    let second_deletes = replay.deletes();
    let old_copy_survived = replay.cloud.lock().unwrap().copy_exists;
    let downloads = replay.requests("/1/clouddrive/file/download");
    let creates = replay.requests("/1/clouddrive/file");
    let saves = replay.requests("/1/clouddrive/share/sharepage/save");
    let (old_records, old_copy_records, new_records) = {
        let ledger = temp_saved().lock().unwrap_or_else(|e| e.into_inner());
        (
            ledger.iter().filter(|saved| saved.owner.as_ref() == Some(&old)).count(),
            ledger.iter().filter(|saved| saved.owner.as_ref() == Some(&old) && saved.fid == COPIED_FID).count(),
            ledger.iter().filter(|saved| saved.owner.as_ref() == Some(&new)).count(),
        )
    };

    // The original exact session remains independently cleanable after the
    // second owner's cleanup; this also checks retained ownership and LIFO.
    PanDrive::debug_set_test_cookie(kind.code(), ORIGINAL);
    let before_original_cleanup = second_deletes.len();
    replay.drive.purge_owned(Some(old)).await;
    let all_deletes = replay.deletes();

    assert_eq!(creates.len(), 2, "both owners must reach distinct real mkdir responses");
    let first_dir = creates[0].body["file_name"].as_str().unwrap();
    let second_dir = creates[1].body["file_name"].as_str().unwrap();
    assert_ne!(first_dir, second_dir, "directory ownership must not cause the save collision");
    assert_eq!(creates[0].cookie, ORIGINAL);
    assert_eq!(creates[1].cookie, changed_cookie);
    assert_eq!(saves.len(), 2, "both operations must reach real save/task responses");
    assert_eq!(saves[0].body["to_pdir_fid"], first_dir);
    assert_eq!(saves[1].body["to_pdir_fid"], second_dir);
    assert_eq!(replay.requests("/1/clouddrive/task").len(), 2);
    assert!(old_copy_survived && second_deletes.iter().all(|request| request.body["filelist"] != json!([COPIED_FID])),
        "changed-cookie owner deleted the first owner's live copy: second_accepted={}, downloads={}, deletes={:?}",
        second.is_ok(), downloads.len(), second_deletes);
    assert!(second.as_ref().err().is_some_and(|error| error.contains("文件归属")),
        "deduplicated save must be rejected as an ownership collision after Cookie bytes change");
    assert_eq!(downloads.len(), 1, "a rejected foreign copy must never reach download");
    assert_eq!(downloads[0].cookie, ORIGINAL);
    assert_eq!(second_deletes.len(), 1, "the second owner may clean only its empty unique directory");
    assert_delete(&second_deletes[0], changed_cookie, second_dir);
    assert_eq!((old_records, old_copy_records, new_records), (2, 1, 0));
    assert_eq!(all_deletes.len(), before_original_cleanup + 2);
    assert_delete(&all_deletes[before_original_cleanup], ORIGINAL, COPIED_FID);
    assert_delete(&all_deletes[before_original_cleanup + 1], ORIGINAL, first_dir);
    assert!(temp_saved().lock().unwrap_or_else(|e| e.into_inner()).is_empty());
}

macro_rules! cookie_cases {
    ($name:ident, $kind:expr, $label:expr, $cookie:expr) => {
        #[tokio::test]
        async fn $name() { changed_cookie_cannot_steal_copy($kind, $label, $cookie).await; }
    };
}

cookie_cases!(quark_cookie_rotation_rejects_other_consumer_copy_and_preserves_cleanup, PanKind::Quark, "rotation", ROTATED);
cookie_cases!(uc_cookie_rotation_rejects_other_consumer_copy_and_preserves_cleanup, PanKind::Uc, "rotation", ROTATED);
cookie_cases!(quark_cookie_reordering_rejects_other_consumer_copy_and_preserves_cleanup, PanKind::Quark, "reordering", REORDERED);
cookie_cases!(uc_cookie_reordering_rejects_other_consumer_copy_and_preserves_cleanup, PanKind::Uc, "reordering", REORDERED);
