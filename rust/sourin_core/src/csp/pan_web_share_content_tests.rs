use super::*;
use crate::csp::http_context::test_support::{custom, serve};
use axum::{http::StatusCode, response::IntoResponse};
use std::sync::Arc;

const INVALID_PAGE: &str =
    "<html><title>Temporarily unavailable</title><body>Retry later</body></html>";
const EXT: &str =
    r#"{"site":["http://panweb-content-primary.invalid","http://panweb-content-backup.invalid"]}"#;

async fn read_content(
    site: &PanWebShare,
    operation: &str,
) -> Result<(String, Option<String>), String> {
    match operation {
        "home" => site.home(EXT).await.map(|home| {
            assert_eq!(home.categories.len(), 3);
            let item = home
                .items
                .into_iter()
                .next()
                .expect("a real parsed home item");
            (item.title, item.cover)
        }),
        "list" => site.list("1", 2, EXT).await.map(|list| {
            assert_eq!(list.page, 2);
            let item = list
                .items
                .into_iter()
                .next()
                .expect("a real parsed category item");
            (item.title, item.cover)
        }),
        "search" => site.search("fixture", 2, EXT).await.map(|list| {
            assert_eq!(list.page, 2);
            let item = list
                .items
                .into_iter()
                .next()
                .expect("a real parsed search item");
            (item.title, item.cover)
        }),
        "detail" => site.detail("1234", EXT).await.map(|detail| {
            assert_eq!(detail.episodes.len(), 3);
            (detail.title, detail.cover)
        }),
        _ => unreachable!(),
    }
}

async fn content_failover(operation: &str) {
    let proxy = serve(|request| {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml");
        assert!(!request.headers.contains_key("cookie"));
        match request.uri.host().unwrap() {
            "panweb-content-primary.invalid" => INVALID_PAGE.into_response(),
            "panweb-content-backup.invalid" => (
                StatusCode::FOUND,
                [(
                    "location",
                    format!("http://panweb-content-final.invalid{}", request.uri.path()),
                )],
            )
                .into_response(),
            "panweb-content-final.invalid" => {
                let html = if request.uri.path().starts_with(PATH_DETAIL) {
                    super::tests::DETAIL_HTML.to_string()
                } else if request.uri.path().starts_with(PATH_SEARCH) {
                    super::tests::LIST_HTML.replace("module-item", "module-search-item")
                } else {
                    super::tests::LIST_HTML.to_string()
                };
                html.replace("https://img.example/a.jpg", "/posters/a.jpg")
                    .into_response()
            }
            _ => panic!("unexpected request target"),
        }
    })
    .await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = PanWebShare::new();
    site.set_http_context(store, "panweb-content");
    for _ in 0..2 {
        let (title, cover) = read_content(&site, operation)
            .await
            .expect("invalid HTTP-200 content must try backup");
        assert_eq!(title, "示例片 甲");
        assert_eq!(
            cover.as_deref(),
            Some("http://panweb-content-final.invalid/posters/a.jpg")
        );
        assert_eq!(
            site.sticky.lock().unwrap().as_deref(),
            Some("http://panweb-content-backup.invalid")
        );
    }
    let hits = proxy.hits.lock().unwrap();
    let hosts: Vec<_> = hits.iter().map(|hit| hit.uri.host().unwrap()).collect();
    assert_eq!(
        hosts,
        [
            "panweb-content-primary.invalid",
            "panweb-content-backup.invalid",
            "panweb-content-final.invalid",
            "panweb-content-backup.invalid",
            "panweb-content-final.invalid"
        ],
        "only validated content earns sticky priority; all attempts and redirects retain the proxy"
    );
}

#[tokio::test]
async fn http200_invalid_home_uses_validated_backup() {
    content_failover("home").await;
}
#[tokio::test]
async fn http200_invalid_category_uses_validated_backup() {
    content_failover("list").await;
}
#[tokio::test]
async fn http200_invalid_search_uses_validated_backup() {
    content_failover("search").await;
}
#[tokio::test]
async fn http200_invalid_detail_uses_validated_backup() {
    content_failover("detail").await;
}

#[tokio::test]
async fn all_http200_invalid_pages_report_both_failures_without_sticky_success() {
    let proxy = serve(|_| INVALID_PAGE.into_response()).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = PanWebShare::new();
    site.set_http_context(store, "panweb-content");
    let error = site.home(EXT).await.unwrap_err();
    assert_eq!(
        proxy.hits.lock().unwrap().len(),
        2,
        "both configured mirrors must be attempted"
    );
    assert!(error.contains("panweb-content-primary.invalid"), "{error}");
    assert!(error.contains("panweb-content-backup.invalid"), "{error}");
    assert!(error.contains("没解析出任何分类"), "{error}");
    assert!(site.sticky.lock().unwrap().is_none());
}

#[tokio::test]
async fn valid_home_with_categories_but_no_items_does_not_force_backup() {
    let proxy = serve(|_| {
        r#"<nav><a href="/index.php/vod/show/id/1.html">Category</a></nav>"#.into_response()
    })
    .await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = PanWebShare::new();
    site.set_http_context(store, "panweb-content");
    let home = site.home(EXT).await.unwrap();
    assert_eq!(home.categories.len(), 1);
    assert!(home.items.is_empty());
    assert_eq!(proxy.hits.lock().unwrap().len(), 1);
    assert_eq!(
        site.sticky.lock().unwrap().as_deref(),
        Some("http://panweb-content-primary.invalid")
    );
}
