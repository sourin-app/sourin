use super::*;
use crate::csp::http_context::test_support::{custom, serve, Fixture};
use axum::{http::StatusCode, response::IntoResponse};
use serde_json::json;

async fn api_fixture(label: &'static str, denied: bool) -> Fixture {
    serve(move |request| {
        assert!(request.headers.get("cookie").is_none());
        assert!(request.headers.get("authorization").is_none());
        let path = request.uri.path();
        if path.ends_with(".json") {
            if denied { return StatusCode::FORBIDDEN.into_response(); }
            return axum::Json(json!({"class":[{"type_id":"theme", "type_name":label}]})).into_response();
        }
        let body = match path {
            "/x/web-interface/nav" => json!({"code":-101,"data":{"wbi_img":{
                "img_url":"https://image.invalid/7cd084941338484aae1ad9425b84077c.png",
                "sub_url":"https://image.invalid/4932caff0ff746eab6f01bf08b70ac45.png"
            }}}),
            "/x/web-interface/wbi/search/type" => json!({"code":0,"data":{
                "result":[{"bvid":"BVtheme","title":label}], "numResults":1,"numPages":1
            }}),
            "/x/web-interface/ranking/v2" => json!({"code":0,"data":{"list":[]}}),
            _ => panic!("unexpected loopback request"),
        };
        axum::Json(body).into_response()
    }).await
}

fn directory_reads(fixture: &Fixture) -> usize {
    fixture.hits.lock().unwrap().iter().filter(|hit| hit.uri.path().ends_with(".json")).count()
}

#[tokio::test]
async fn bili_theme_cache_reuses_one_declared_resource_and_reloads_changed_configuration() {
    let fixture = api_fixture("first", false).await;
    let site = Bili::with_base(&fixture.url);
    let ext_a = json!({"json":format!("{}/first.json", fixture.url)}).to_string();
    let ext_b = json!({"json":format!("{}/second.json", fixture.url)}).to_string();
    assert_eq!(site.home(&ext_a).await.unwrap().categories[0].name, "first");
    assert_eq!(site.home(&ext_a).await.unwrap().categories[0].name, "first");
    assert_eq!(site.list("theme", 1, &ext_a).await.unwrap().items[0].title, "first");
    assert_eq!(directory_reads(&fixture), 1, "home/list must share the current resource cache");
    site.home(&ext_b).await.unwrap();
    assert_eq!(directory_reads(&fixture), 2, "resource identity must invalidate the single-entry cache");
}

#[tokio::test]
async fn bili_theme_cache_reloads_for_store_revision_provider_and_store_identity() {
    let origin = serve(|_| panic!("directory request must keep the configured proxy")).await;
    let first = api_fixture("first", false).await;
    let second = api_fixture("second", false).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    let site = Bili::with_base(&origin.url);
    let ext = json!({"json":format!("{}/theme.json", origin.url)}).to_string();
    site.set_http_context(store.clone(), "provider-a");
    assert_eq!(site.home(&ext).await.unwrap().categories[0].name, "first");
    custom(&store, &second.url);
    assert_eq!(site.home(&ext).await.unwrap().categories[0].name, "second");
    assert_eq!(directory_reads(&first), 1);
    assert_eq!(directory_reads(&second), 1, "hot route revision must load via the new proxy");
    site.set_http_context(store, "provider-b");
    site.home(&ext).await.unwrap();
    assert_eq!(directory_reads(&second), 2, "source identity must bind the directory cache");
    let replacement_store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&replacement_store, &second.url);
    custom(&replacement_store, &second.url);
    site.set_http_context(replacement_store, "provider-b");
    site.home(&ext).await.unwrap();
    assert_eq!(directory_reads(&second), 3, "equal revisions from different stores must not share cache");
    assert!(origin.hits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn bili_theme_cache_rejected_new_route_cannot_reuse_an_old_success() {
    let origin = serve(|_| panic!("denied configured proxy must not fall back to origin")).await;
    let first = api_fixture("first", false).await;
    let rejected = api_fixture("must-not-use", true).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    let site = Bili::with_base(&origin.url);
    site.set_http_context(store.clone(), "source");
    let ext = json!({"json":format!("{}/theme.json", origin.url)}).to_string();
    site.home(&ext).await.unwrap();
    custom(&store, &rejected.url);
    assert!(site.home(&ext).await.unwrap_err().contains("403"));
    assert_eq!(directory_reads(&first), 1);
    assert_eq!(directory_reads(&rejected), 1);
    assert!(origin.hits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn bili_theme_cache_oversized_directory_is_rejected_without_general_fallback() {
    let fixture = serve(|_| "x".repeat(512 * 1024 + 1).into_response()).await;
    let site = Bili::with_base(&fixture.url);
    let ext = json!({"json":format!("{}/oversized.json", fixture.url)}).to_string();
    assert!(site.home(&ext).await.unwrap_err().contains("过大"));
    let hits = fixture.hits.lock().unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].uri.path(), "/oversized.json");
}

#[tokio::test]
async fn bili_theme_cache_invalid_declared_resource_never_uses_default_ranking() {
    let fixture = api_fixture("must-not-use", false).await;
    let site = Bili::with_base(&fixture.url);
    for json_value in [json!("./theme.json"), json!(null), json!(12), json!("file:///theme.json")] {
        assert!(site.home(&json!({"json":json_value}).to_string()).await.is_err());
    }
    assert!(fixture.hits.lock().unwrap().is_empty(), "invalid explicit directory configuration must fail before HTTP");
}

#[tokio::test]
async fn bili_theme_cache_unknown_category_cannot_escape_the_declared_directory() {
    let fixture = api_fixture("current", false).await;
    let site = Bili::with_base(&fixture.url);
    let ext = json!({"json":format!("{}/theme.json", fixture.url)}).to_string();
    assert!(site.list("unlisted", 1, &ext).await.is_err());
    let hits = fixture.hits.lock().unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].uri.path(), "/theme.json");
}
