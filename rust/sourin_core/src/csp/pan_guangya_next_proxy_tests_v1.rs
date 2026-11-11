use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::sync::Arc;

// Only this synthetic value is sent. These tests never call cookie(), pan_auth,
// list(), or play(), and never contact the production cloud endpoints.
const FIXTURE_COOKIE: &str = "c12-next-fixture-account=synthetic";

fn response(label: &str) -> axum::response::Response {
    axum::Json(serde_json::json!({"code":0,"success":true,"data":{"fixture":label}})).into_response()
}

fn assert_request(request: &Request, expected_path: &str, expected_body: &str) {
    assert_eq!(request.method, Method::POST);
    assert_eq!(request.uri.path(), expected_path);
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["content-type"], "application/json");
    assert_eq!(request.headers["accept"], "application/json, text/plain, */*");
    assert_eq!(request.headers["cookie"], FIXTURE_COOKIE);
    assert_eq!(request.body.as_ref(), expected_body.as_bytes());
}

#[tokio::test]
async fn guangya_list_and_signed_requests_follow_global_proxy_with_exact_recipe() {
    let origin = serve(|_| response("origin")).await;
    let proxy = serve(|_| response("proxy")).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = PanGuangya::new();
    site.set_http_context(store, "guangya-next-fixture");
    let list = list_body("fixture-parent", 2);
    let signed = signed_body("fixture-file");
    let list_url = format!("{}/fixture/list", origin.url);
    let signed_url = format!("{}/fixture/signed", origin.url);
    let list_response = site.post_json(FIXTURE_COOKIE, &list_url, &list).await.unwrap();
    let signed_response = site.post_json(FIXTURE_COOKIE, &signed_url, &signed).await.unwrap();
    let observed = proxy.hits.lock().unwrap();
    assert_eq!(observed.len(), 2, "both actual requests must use the configured proxy");
    assert_request(&observed[0], "/fixture/list", &list);
    assert_request(&observed[1], "/fixture/signed", &signed);
    assert_eq!(observed[0].uri.to_string(), list_url);
    assert_eq!(observed[1].uri.to_string(), signed_url);
    assert_eq!(list_response["data"]["fixture"], "proxy");
    assert_eq!(signed_response["data"]["fixture"], "proxy");
    assert!(origin.hits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn guangya_next_request_uses_hot_global_policy_without_changing_cookie_or_body() {
    let origin = serve(|_| response("origin")).await;
    let first = serve(|_| response("first")).await;
    let second = serve(|_| response("second")).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    let site = PanGuangya::new();
    site.set_http_context(store.clone(), "guangya-next-fixture");
    let url = format!("{}/fixture/signed", origin.url);
    let body = signed_body("unchanged-fixture-file");
    custom(&store, &first.url);
    let a = site.post_json(FIXTURE_COOKIE, &url, &body).await.unwrap();
    custom(&store, &second.url);
    let b = site.post_json(FIXTURE_COOKIE, &url, &body).await.unwrap();
    let a_hits = first.hits.lock().unwrap();
    let b_hits = second.hits.lock().unwrap();
    assert_eq!(a_hits.len(), 1, "the first request must use the first policy");
    assert_eq!(b_hits.len(), 1, "the next request must use the updated policy");
    assert_request(&a_hits[0], "/fixture/signed", &body);
    assert_request(&b_hits[0], "/fixture/signed", &body);
    assert_eq!(a["data"]["fixture"], "first");
    assert_eq!(b["data"]["fixture"], "second");
    assert!(origin.hits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn guangya_proxy_rejection_never_falls_back_to_the_direct_origin() {
    let origin = serve(|_| response("direct-origin-must-not-be-used")).await;
    let rejected = serve(|_| {
        (StatusCode::BAD_GATEWAY, axum::Json(serde_json::json!({"code":117,"msg":"fixture rejected"}))).into_response()
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &rejected.url);
    let site = PanGuangya::new();
    site.set_http_context(store, "guangya-next-fixture");
    let body = signed_body("fixture-file");
    let result = site.post_json(FIXTURE_COOKIE, &format!("{}/fixture/signed", origin.url), &body).await;
    assert!(result.is_err(), "a rejected configured proxy must not become direct success");
    let error = result.unwrap_err();
    assert!(error.contains("HTTP 502 code=117"));
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn guangya_unbound_direct_control_keeps_the_original_request_recipe() {
    let origin = serve(|_| response("direct-control")).await;
    let site = PanGuangya::new();
    let body = list_body("fixture-parent", 0);
    let value = site.post_json(FIXTURE_COOKIE, &format!("{}/fixture/list", origin.url), &body).await.unwrap();
    assert_eq!(value["data"]["fixture"], "direct-control");
    let observed = origin.hits.lock().unwrap();
    assert_eq!(observed.len(), 1);
    assert_request(&observed[0], "/fixture/list", &body);
}
