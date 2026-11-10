use super::*;
use crate::csp::http_context::test_support::{custom, serve};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::sync::Arc;

fn response(code: u8, message: &str, url: &str) -> Vec<u8> {
    // Independent minimal protobuf fixture writer: no production decoder helpers.
    let mut out = vec![8, code];
    for (tag, value) in [(18, message), (26, url)] {
        let bytes = value.as_bytes();
        assert!(bytes.len() < 128);
        out.extend_from_slice(&[tag, bytes.len() as u8]);
        out.extend_from_slice(bytes);
    }
    out
}

#[tokio::test]
async fn anonymous_playback_posts_selected_episode_and_routes_through_current_proxy() {
    let origin = serve(|_| panic!("configured playback must never contact origin")).await;
    let first = serve(|request| {
        assert_eq!(request.method, Method::POST);
        assert_eq!(request.uri.path(), "/api.php/web/decode/url");
        assert_eq!(request.headers["content-type"], "application/x-protobuf");
        assert_eq!(request.headers["accept"], "application/x-protobuf");
        assert_eq!(request.headers["x-client"], "fixture-client");
        assert_eq!(request.headers["web-sign"], "fixture-sign");
        assert_eq!(request.headers["user-agent"], UA);
        assert!(!request.headers.contains_key("cookie"));
        assert!(!request.headers.contains_key("authorization"));
        let payload = b"PAN1-exact%2Fselected+value";
        assert_eq!(&request.body[..2], &[10, payload.len() as u8]);
        assert_eq!(&request.body[2..2 + payload.len()], payload);
        assert_eq!(&request.body[2 + payload.len()..8 + payload.len()], b"\x12\x04PAN1");
        ([("content-type", "application/x-protobuf")],
            response(1, "success", "https://media.invalid/selected.m3u8?sign=keep%2Bthis")).into_response()
    }).await;
    let second = serve(|_| ([("content-type", "application/x-protobuf")],
        response(1, "success", "https://media.invalid/second.m3u8")).into_response()).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    let site = YunDuo::new();
    site.set_http_context(store.clone(), "decode-fixture");
    custom(&store, &first.url);
    let ext = serde_json::json!({"host": origin.url, "client":"fixture-client", "sign":"fixture-sign"}).to_string();
    let plays = site.play("PAN1", "PAN1|episode two|PAN1-exact%2Fselected+value", &ext).await.unwrap();
    assert_eq!(plays.len(), 1);
    assert_eq!(plays[0].url, "https://media.invalid/selected.m3u8?sign=keep%2Bthis");
    assert_eq!(plays[0].label.as_deref(), Some("PAN1"));
    assert!(plays[0].headers.contains(&("User-Agent".into(), UA.into())));
    assert!(plays[0].headers.contains(&("Referer".into(), format!("{}/", origin.url))));
    custom(&store, &second.url);
    let plays = site.play("PAN1", "PAN1|episode two|PAN1-exact%2Fselected+value", &ext).await.unwrap();
    assert_eq!(plays[0].url, "https://media.invalid/second.m3u8");
    assert!(origin.hits.lock().unwrap().is_empty());
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(second.hits.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn anonymous_playback_rejects_access_and_http_failures_without_direct_fallback() {
    let origin = serve(|_| panic!("failed proxy must never fall back to origin")).await;
    let denied = serve(|_| ([("content-type", "application/x-protobuf")],
        response(100, "VIP_REQUIRED", "https://media.invalid/?token=private")).into_response()).await;
    let failed = serve(|_| (StatusCode::FORBIDDEN, "private token https://media.invalid").into_response()).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    let site = YunDuo::new();
    site.set_http_context(store.clone(), "decode-denied-fixture");
    let ext = serde_json::json!({"host": origin.url}).to_string();
    custom(&store, &denied.url);
    let error = site.play("line", "line|episode|opaque-private-value", &ext).await.unwrap_err();
    assert!(error.contains("会员权限"));
    assert!(!error.contains("private"));
    custom(&store, &failed.url);
    let error = site.play("line", "line|episode|opaque-private-value", &ext).await.unwrap_err();
    assert!(error.contains("HTTP 403"));
    assert!(!error.contains("private"));
    assert!(origin.hits.lock().unwrap().is_empty());
    assert_eq!(denied.hits.lock().unwrap().len(), 1);
    assert_eq!(failed.hits.lock().unwrap().len(), 1);
}
