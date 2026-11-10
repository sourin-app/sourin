use super::*;
use crate::csp::http_context::test_support::{custom, serve};
use axum::response::IntoResponse;

#[tokio::test]
async fn douban_keeps_content_headers_across_proxy_changes_and_never_falls_back() {
    let make = |label: &'static str| move |_| axum::Json(serde_json::json!({
        "items":[{"id":"fixture","title":label,"pic":{"normal":"http://douban-fixture.invalid/cover.jpg"}}]
    })).into_response();
    let first = serve(make("first")).await;
    let second = serve(make("second")).await;
    let store = std::sync::Arc::new(crate::proxy::ProxyStore::new());
    let site = Douban::new();
    site.set_http_context(store.clone(), "douban-fixture");
    for (proxy, label) in [(&first, "first"), (&second, "second")] {
        custom(&store, &proxy.url);
        let value = site.get_json("http://douban-fixture.invalid/items?start=20&count=20").await.unwrap();
        assert_eq!(items_of(&value, "items", "fixture").unwrap()[0].title, label);
        let hits = proxy.hits.lock().unwrap();
        assert_eq!(hits.len(), 1);
        let hit = &hits[0];
        assert_eq!(hit.method, axum::http::Method::GET);
        assert_eq!(hit.uri.host(), Some("douban-fixture.invalid"));
        assert_eq!(hit.uri.query(), Some("start=20&count=20"));
        assert_eq!(hit.headers["host"], MSG_HOST);
        assert_eq!(hit.headers["connection"], "Keep-Alive");
        assert_eq!(hit.headers["referer"], MSG_REFERER);
        assert_eq!(hit.headers["user-agent"], MSG_UA);
        assert_eq!(hit.headers["accept"], "application/json");
        assert!(hit.body.is_empty());
    }

    let direct = serve(make("direct")).await;
    let rejected = serve(|_| axum::http::StatusCode::BAD_GATEWAY.into_response()).await;
    custom(&store, &rejected.url);
    assert!(site.get_json(&format!("{}/items", direct.url)).await.unwrap_err().contains("502"));
    // The real fixed HTTPS home endpoint is refused by the local proxy. Its
    // optional prefetch must still leave the original eight static categories.
    let home = site.home("").await.unwrap();
    assert_eq!(home.categories.len(), 8);
    assert!(home.items.is_empty());
    assert!(direct.hits.lock().unwrap().is_empty());
    assert_eq!(rejected.hits.lock().unwrap().len(), 2);

    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(site.get_json(&format!("{}/items", direct.url)).await.unwrap()["items"][0]["title"], "direct");
    assert_eq!(direct.hits.lock().unwrap().len(), 1);
}
