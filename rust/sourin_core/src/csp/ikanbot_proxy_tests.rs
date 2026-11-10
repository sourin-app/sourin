use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve};
use axum::response::IntoResponse;

#[tokio::test]
async fn ikanbot_import_probe_content_and_restore_share_proxy_and_preserve_xhr_headers() {
    let version = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(1));
    let remote_version = version.clone();
    let proxy = serve(move |request| match request.uri.path() {
        "/subscription.json" => axum::Json(serde_json::json!({"sites":[{
            "key":"ikan-fixture","name":format!("Ikan fixture {}", remote_version.load(std::sync::atomic::Ordering::SeqCst)),"type":3,"api":"csp_Ikanbot",
            "ext":{"host":"http://ikan-fixture.invalid"}
        }]})).into_response(),
        "/xhr" => "xhr fixture".into_response(),
        _ => r#"<a href="/play/12345"><p>Ikan fixture item</p></a>"#.into_response(),
    }).await;
    let dir = scratch("ikan");
    let state = crate::state::AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &proxy.url);
    let report = crate::tvbox::import_tvbox_config(&state, "http://ikan-fixture.invalid/subscription.json").await.unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty());
    assert!(report["imported"][0]["probeFailed"].is_null());
    assert!(report["imported"][0]["categories"].as_u64().unwrap() > 0);
    let id = report["imported"][0]["id"].as_str().unwrap().to_string();
    let request = || crate::provider::ListRequest { category_id:"1".into(), page:1, ..Default::default() };
    assert_eq!(state.registry.get(&id).unwrap().list(request()).await.unwrap().items[0].title, "Ikan fixture item");
    let site = Ikanbot::new();
    site.set_http_context(state.proxy.clone(), "xhr-fixture");
    assert_eq!(site.get_res("http://ikan-fixture.invalid/xhr").await.unwrap(), "xhr fixture");
    version.store(2, std::sync::atomic::Ordering::SeqCst);
    let updated = crate::tvbox::update_tvbox_source(&state, &id, true, false).await.unwrap();
    assert_eq!(updated["updated"], true);
    assert_eq!(state.registry.get(&id).unwrap().manifest().name, "Ikan fixture 2");
    assert_eq!(state.registry.get(&id).unwrap().list(request()).await.unwrap().items[0].title, "Ikan fixture item");
    drop(state);
    let restored = crate::state::AppState::bootstrap(dir.clone()).await.unwrap();
    assert_eq!(restored.registry.get(&id).unwrap().list(request()).await.unwrap().items[0].title, "Ikan fixture item");
    let hits = proxy.hits.lock().unwrap();
    assert_eq!(hits.len(), 8);
    for hit in hits.iter().filter(|r| r.uri.path() != "/subscription.json") {
        assert_eq!(hit.headers["user-agent"], UA);
        assert_eq!(hit.headers["referer"], REFERER);
    }
    let xhr = hits.iter().find(|r| r.uri.path() == "/xhr").unwrap();
    assert_eq!(xhr.headers["x-requested-with"], "XMLHttpRequest");
    drop(hits);
    drop(restored);
    let _ = std::fs::remove_dir_all(dir);
}
