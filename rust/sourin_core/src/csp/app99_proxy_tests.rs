use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Fixture, Request};
use axum::{http::StatusCode, response::IntoResponse};
use std::sync::Arc;

const UUID_A: &str = "01234567-89ab-cdef-0123-456789abcdef";
const UUID_B: &str = "fedcba98-7654-3210-fedc-ba9876543210";

fn ext(host: &str, uuid: &str) -> String {
    serde_json::json!({
        "host":host,"name":"fixture-app","buildSignature":"FIXTURE-SIG",
        "buildNumber":"2001","versionName":"3.5.8","package":"com.fixture",
        "uuid":uuid,"version":"fixture-version","LoginPath":"/fixture/guest"
    }).to_string()
}

fn guest_token(uuid: &str) -> String { format!("fixture-token-{uuid}") }

fn request_body(request: &Request) -> serde_json::Value {
    assert_eq!(request.method, axum::http::Method::POST);
    let header = |key| request.headers.get(key).unwrap().to_str().unwrap();
    assert_eq!(header("user-agent"), UA);
    assert_eq!(header("accept"), "application/json");
    assert_eq!(header("content-type"), "application/json; charset=utf-8");
    assert_eq!(header("client_type"), "android");
    assert_eq!(header("version"), "fixture-version");
    assert_eq!(header("api_version"), "v1");
    assert_eq!(header("content-length"), request.body.len().to_string());
    assert!(!request.headers.contains_key("content-encoding"));
    assert!(!request.headers.contains_key("transfer-encoding"));
    assert!(!request.headers.contains_key("cookie"));
    let encrypted = std::str::from_utf8(&request.body).unwrap();
    let key = key_of(header("uuid")).unwrap();
    let plain = super::tests::open_request(&key, encrypted);
    assert_eq!(plain["timestamp"], header("timestamp"));
    assert_eq!(plain["nonce"], header("nonce"));
    let signed = format!("{encrypted}:{}:{}:{}", header("timestamp"), header("nonce"), plain["token"].as_str().unwrap());
    let digest = ring::digest::digest(&ring::digest::SHA256, signed.as_bytes());
    let expected: String = digest.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
    assert_eq!(header("sign"), expected);
    plain
}

async fn app_fixture(label: &'static str) -> Fixture {
    // The production live-capture switch must not write synthetic captures.
    assert_ne!(std::env::var("CSP_LIVE").ok().as_deref(), Some("1"));
    serve(move |request| {
        if request.uri.path() == "/subscription.json" {
            return axum::Json(serde_json::json!({"sites":[{
                "key":"app99-fixture","name":"App99 fixture","type":3,"api":"csp_App99",
                "ext":serde_json::from_str::<serde_json::Value>(&ext("http://app99-fixture.invalid", UUID_A)).unwrap()
            }]})).into_response();
        }
        if request.method == axum::http::Method::GET {
            assert_eq!(request.headers["user-agent"], UA);
            assert_eq!(request.headers["range"], "bytes=0-511");
            assert!(!request.headers.contains_key("cookie"));
            return match request.uri.path() {
                "/resource" => (StatusCode::FOUND, [
                    ("location", "http://app99-final.invalid/media"),
                    ("set-cookie", "fixture=unpersisted; Path=/"),
                ]).into_response(),
                "/media" => ([("content-type", "application/octet-stream")], "#EXTM3U\n#EXTINF:10,\nsegment.ts\n").into_response(),
                _ => StatusCode::NOT_FOUND.into_response(),
            };
        }
        let body = request_body(&request);
        let uuid = request.headers["uuid"].to_str().unwrap();
        let rejected_guest = uuid == UUID_B;
        let response = match request.uri.path() {
            "/app/systemInit" => {
                assert_eq!(body["v"], "3.5.8");
                assert_eq!(body["token"], "");
                serde_json::json!({"code":0,"categorys":{"data":[{"id":"1","name":"fixture"}]},
                    "player":{"parser":{"name":"Fixture parser","type":1,"parseUrl":"1"}},
                    "parser_api":[{"id":1}]})
            }
            "/fixture/guest" => {
                assert_eq!(body["token"], "");
                assert_eq!(body["app"]["package"], "com.fixture");
                if rejected_guest { serde_json::json!({"code":1,"msg":"fixture rejected"}) }
                else { serde_json::json!({"code":0,"userInfo":{"user_token":guest_token(uuid)}}) }
            }
            path => {
                assert_eq!(body["token"], if rejected_guest { String::new() } else { guest_token(uuid) });
                match path {
                    "/vod/search" => serde_json::json!({"code":0,"data":[{"id":77,"name":label}]}),
                    "/vod/detail" => serde_json::json!({"code":0,"data":{"name":label,
                        "play_from":"parser","play_url":"Episode 2$opaque-selected"}}),
                    "/app/vodParser" => {
                        assert_eq!(body["id"], 1);
                        assert_eq!(body["url"], "opaque-selected");
                        serde_json::json!({"code":0,"data":"http://app99-media.invalid/resource"})
                    }
                    _ => return StatusCode::NOT_FOUND.into_response(),
                }
            }
        };
        super::tests::seal_fixture(&key_of(uuid).unwrap(), &response).into_response()
    }).await
}

#[tokio::test]
async fn app99_proxy_preserves_signed_handshake_session_parser_and_media_redirects() {
    let first = app_fixture("first").await;
    let second = app_fixture("second").await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    let site = App99::new();
    site.set_http_context(store.clone(), "app99-fixture");
    let ext = ext("http://app99-fixture.invalid", UUID_A);
    assert_eq!(site.search("fixture", 1, &ext).await.unwrap().items[0].title, "first");
    custom(&store, &second.url);
    assert_eq!(site.list("1", 2, &ext).await.unwrap().items[0].title, "second");
    let detail = site.detail("77", &ext).await.unwrap();
    let episode = &detail.episodes[0];
    let play = site.play(&episode.flag, &episode.id, &ext).await.unwrap();
    assert_eq!(play[0].url, "http://app99-media.invalid/resource");
    assert_eq!(site.state.lock().unwrap().as_ref().unwrap().token, guest_token(UUID_A));
    let initial = first.hits.lock().unwrap();
    assert_eq!(initial.iter().map(|r| r.uri.path()).collect::<Vec<_>>(), vec![
        "/app/systemInit", "/fixture/guest", "/vod/search",
    ]);
    let changed = second.hits.lock().unwrap();
    assert_eq!(changed.iter().map(|r| r.uri.path()).collect::<Vec<_>>(), vec![
        "/vod/search", "/vod/detail", "/app/vodParser", "/resource", "/media",
    ], "proxy revision must keep the authenticated site and follow media redirects");
    assert_eq!(changed[3].uri.host(), Some("app99-media.invalid"));
    assert_eq!(changed[4].uri.host(), Some("app99-final.invalid"));
}

#[tokio::test]
async fn app99_proxy_keeps_concurrent_site_identities_and_guest_failure_separate() {
    let proxy = app_fixture("concurrent").await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let first = App99::new();
    let second = App99::new();
    first.set_http_context(store.clone(), "app99-first");
    second.set_http_context(store, "app99-second");
    let first_ext = ext("http://app99-first.invalid", UUID_A);
    let second_ext = ext("http://app99-second.invalid", UUID_B);
    let (a, b) = tokio::join!(first.search("first", 1, &first_ext), second.search("second", 1, &second_ext));
    assert_eq!(a.unwrap().items[0].title, "concurrent");
    assert_eq!(b.unwrap().items[0].title, "concurrent");
    assert_eq!(first.state.lock().unwrap().as_ref().unwrap().token, guest_token(UUID_A));
    assert!(second.state.lock().unwrap().as_ref().unwrap().token.is_empty());
    let hits = proxy.hits.lock().unwrap();
    assert_eq!(hits.len(), 6);
    for (host, uuid, keyword) in [("app99-first.invalid", UUID_A, "first"), ("app99-second.invalid", UUID_B, "second")] {
        let requests: Vec<_> = hits.iter().filter(|r| r.uri.host() == Some(host)).collect();
        assert_eq!(requests.len(), 3);
        assert!(requests.iter().all(|r| r.headers["uuid"] == uuid));
        let search = requests.iter().find(|r| r.uri.path() == "/vod/search").unwrap();
        assert_eq!(request_body(search)["kw"], keyword);
    }
}

#[tokio::test]
async fn app99_proxy_failure_never_falls_back_for_handshake_business_or_media() {
    let direct = app_fixture("direct").await;
    let rejected = serve(|_| StatusCode::BAD_GATEWAY.into_response()).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &rejected.url);
    let site = App99::new();
    site.set_http_context(store.clone(), "app99-negative");
    let ext = ext(&direct.url, UUID_A);
    assert!(site.search("fixture", 1, &ext).await.unwrap_err().contains("systemInit HTTP 502"));
    assert!(direct.hits.lock().unwrap().is_empty());
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(site.search("fixture", 1, &ext).await.unwrap().items[0].title, "direct");
    assert_eq!(direct.hits.lock().unwrap().len(), 3);
    custom(&store, &rejected.url);
    assert!(site.search("fixture", 1, &ext).await.unwrap_err().contains("业务 HTTP 502"));
    assert!(site.verify_media_response(&format!("{}/media", direct.url)).await.unwrap_err().contains("HTTP 502"));
    assert_eq!(direct.hits.lock().unwrap().len(), 3);
    assert_eq!(rejected.hits.lock().unwrap().len(), 3);
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    site.verify_media_response(&format!("{}/media", direct.url)).await.unwrap();
    assert_eq!(direct.hits.lock().unwrap().len(), 4);
}

#[tokio::test]
async fn app99_proxy_context_reaches_import_runtime_and_restored_provider_instances() {
    let first = app_fixture("first").await;
    let second = app_fixture("second").await;
    let dir = scratch("app99-import");
    let state = crate::state::AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &first.url);
    let report = crate::tvbox::import_tvbox_config(&state, "http://app99-fixture.invalid/subscription.json").await.unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty());
    let row = &report["imported"][0];
    assert!(row["probeFailed"].is_null());
    assert_eq!(row["categories"], 1);
    let id = row["id"].as_str().unwrap().to_string();
    assert_eq!(state.registry.get(&id).unwrap().search("fixture", 1).await.unwrap().items[0].title, "first");
    assert_eq!(first.hits.lock().unwrap().len(), 6, "import probe and runtime each retain their own handshake");
    custom(&state.proxy, &second.url);
    assert_eq!(state.registry.get(&id).unwrap().search("fixture", 1).await.unwrap().items[0].title, "second");
    assert_eq!(second.hits.lock().unwrap().len(), 1, "policy changes must not discard the runtime token");
    drop(state);
    let restored = crate::state::AppState::bootstrap(dir.clone()).await.unwrap();
    assert_eq!(restored.registry.get(&id).unwrap().search("fixture", 1).await.unwrap().items[0].title, "second");
    assert_eq!(second.hits.lock().unwrap().len(), 4, "restored source must obtain its session through the saved proxy");
    drop(restored);
    let _ = std::fs::remove_dir_all(dir);
}
