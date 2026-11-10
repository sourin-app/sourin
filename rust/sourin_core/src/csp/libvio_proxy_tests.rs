use super::*;
use crate::csp::http_context::test_support::{custom, serve};
use axum::response::IntoResponse;

#[tokio::test]
async fn libvio_manual_redirect_cookie_cache_survives_proxy_rebuild_on_the_same_site() {
    let first = serve(|request| {
        if request.uri.path() == "/start" {
            (axum::http::StatusCode::FOUND, [
                ("location", "http://libvio-fixture.invalid/landing"),
                ("set-cookie", "__cdn_verified=fixture-cookie; Path=/"),
            ]).into_response()
        } else if request.headers.get("cookie").and_then(|v| v.to_str().ok()) == Some("__cdn_verified=fixture-cookie") {
            "first body".into_response()
        } else {
            axum::http::StatusCode::FORBIDDEN.into_response()
        }
    }).await;
    let second = serve(|request| {
        if request.headers.get("cookie").and_then(|v| v.to_str().ok()) == Some("__cdn_verified=fixture-cookie") {
            "second body".into_response()
        } else { axum::http::StatusCode::FORBIDDEN.into_response() }
    }).await;
    let store = std::sync::Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    let site = Libvio::new();
    site.set_http_context(store.clone(), "libvio-fixture");
    assert_eq!(site.get_text("http://libvio-fixture.invalid/start", "fixture").await.unwrap(), "first body");
    assert_eq!(site.cached_verified().as_deref(), Some("fixture-cookie"));
    custom(&store, &second.url);
    assert_eq!(site.get_text("http://libvio-fixture.invalid/again", "fixture").await.unwrap(), "second body");
    assert_eq!(site.cached_verified().as_deref(), Some("fixture-cookie"));
    assert_eq!(first.hits.lock().unwrap().len(), 2);
    assert_eq!(second.hits.lock().unwrap().len(), 1);
    for proxy in [&first, &second] {
        for hit in proxy.hits.lock().unwrap().iter() {
            assert_eq!(hit.headers["user-agent"], UA);
            assert!(hit.headers.contains_key("referer"));
        }
    }
}
