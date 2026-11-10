//! Stable class identity normalization through the actual directory loader.
//! The local reference returns declared JSON directly; stable first-wins
//! deduplication is the host's explicit compatibility policy, not a DEX claim.
use super::*;
use crate::csp::http_context::test_support::{custom, serve, Fixture};
use axum::{http::Method, response::IntoResponse};
use serde_json::json;

async fn directory_fixture(classes: Value) -> (Bili, String, Fixture, Fixture) {
    let origin = serve(|_| panic!("directory normalization must keep the configured route")).await;
    let proxy = serve(move |request| {
        assert_eq!(request.method, Method::GET);
        assert_eq!(request.uri.path(), "/theme.json", "only the declared resource may be requested");
        assert!(request.headers.get("cookie").is_none());
        assert!(request.headers.get("authorization").is_none());
        axum::Json(json!({"class":classes,"filters":{}})).into_response()
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = Bili::with_base(&origin.url);
    site.set_http_context(store, "directory-duplicate-fixture");
    let ext = json!({"json":format!("{}/theme.json", origin.url)}).to_string();
    (site, ext, origin, proxy)
}

fn assert_one_resource_read(origin: &Fixture, proxy: &Fixture) {
    assert!(origin.hits.lock().unwrap().is_empty(), "no direct origin fallback");
    assert_eq!(proxy.hits.lock().unwrap().len(), 1, "one actual declared-resource request");
}

#[tokio::test]
async fn bili_theme_duplicate_ids_keep_first_name_and_first_seen_order() {
    let (site, ext, origin, proxy) = directory_fixture(json!([
        {"type_id":"theme + 合集","type_name":"First category"},
        {"type_id":"4","type_name":"Numeric keyword"},
        {"type_id":"theme + 合集","type_name":"Later replacement must not win"},
        {"type_id":"other","type_name":"Last distinct category"},
        {"type_id":"4","type_name":"Later numeric replacement must not win"},
        {"type_id":"theme + 合集","type_name":"First category"}
    ])).await;
    let expected = vec![
        CspCategory { id:"theme + 合集".into(), name:"First category".into() },
        CspCategory { id:"4".into(), name:"Numeric keyword".into() },
        CspCategory { id:"other".into(), name:"Last distinct category".into() },
    ];
    let first = site.home(&ext).await.expect("valid repeated category ids must remain a usable directory");
    assert_eq!(first.categories, expected, "preserve first exact id/name and first-seen order");
    assert!(first.items.is_empty(), "do not substitute the general ranking");
    let cached = site.home(&ext).await.unwrap();
    assert_eq!(cached.categories, expected, "cache the same normalized directory");
    assert_one_resource_read(&origin, &proxy);
}

async fn assert_invalid_category_rejected(classes: Value, required_field: &str) {
    let (site, ext, origin, proxy) = directory_fixture(classes).await;
    let result = site.home(&ext).await;
    assert!(result.is_err(), "empty category identity or name must remain invalid");
    assert!(result.err().unwrap().contains(required_field), "retain the actual invalid field");
    assert_one_resource_read(&origin, &proxy);
}

#[tokio::test]
async fn bili_theme_duplicate_control_empty_id_still_rejects_the_directory() {
    assert_invalid_category_rejected(json!([
        {"type_id":"valid","type_name":"Valid"},
        {"type_id":"  ","type_name":"Invalid id"}
    ]), "type_id").await;
}

#[tokio::test]
async fn bili_theme_duplicate_control_empty_name_still_rejects_the_directory() {
    assert_invalid_category_rejected(json!([
        {"type_id":"valid","type_name":"Valid"},
        {"type_id":"other","type_name":"  "}
    ]), "type_name").await;
}

#[tokio::test]
async fn bili_theme_duplicate_control_invalid_repeated_row_cannot_hide_behind_first_entry() {
    assert_invalid_category_rejected(json!([
        {"type_id":"same","type_name":"First valid name"},
        {"type_id":"same","type_name":"  "}
    ]), "type_name").await;
}
