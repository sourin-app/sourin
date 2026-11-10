use super::*;
use crate::csp::http_context::test_support::{custom, serve};
use axum::response::IntoResponse;

#[tokio::test]
async fn bili_both_request_helpers_keep_headers_and_follow_live_proxy_policy() {
    let make = |label: &'static str| move |_| axum::Json(serde_json::json!({
        "code":0,"data":{"archives":[{"bvid":"BVfixture","title":label}],"label":label}
    })).into_response();
    let first = serve(make("first")).await;
    let second = serve(make("second")).await;
    let store = std::sync::Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    let site = Bili::with_base("http://bili-fixture.invalid");
    site.set_http_context(store.clone(), "bili-fixture");
    assert_eq!(site.list("1", 1, "").await.unwrap().items[0].title, "first");
    assert_eq!(site.get_json_ignoring_code("/nav").await.unwrap()["data"]["label"], "first");
    custom(&store, &second.url);
    assert_eq!(site.list("1", 1, "").await.unwrap().items[0].title, "second");
    assert_eq!(site.get_json_ignoring_code("/nav").await.unwrap()["data"]["label"], "second");
    for proxy in [&first, &second] {
        let hits = proxy.hits.lock().unwrap();
        assert_eq!(hits.len(), 2);
        for hit in hits.iter() {
            assert_eq!(hit.headers["user-agent"], UA);
            assert_eq!(hit.headers["referer"], REFERER);
            assert_eq!(hit.headers["accept"], "application/json");
            assert_eq!(hit.uri.host(), Some("bili-fixture.invalid"));
        }
    }
}
