use super::*;
use crate::csp::http_context::test_support::{custom, serve};
use axum::{http::StatusCode, response::IntoResponse};
use std::sync::Arc;

fn fixture(cover: &str) -> String {
    format!(
        r#"<a href="/index.php/vod/show/id/1.html">分类</a>
      <div class="module-item"><a href="/index.php/vod/detail/id/1.html" title="示例作品">
      <img data-src="{cover}"></a></div>
      <div class="module-search-item"><a href="/index.php/vod/detail/id/1.html" title="示例作品">
      <img data-src="{cover}"></a></div>
      <h1 class="page-title">示例作品</h1>
      <div data-clipboard-text="https://pan.quark.cn/s/fixture"></div>"#
    )
}

#[test]
fn cover_markup_keeps_relative_urls_and_decodes_entities_once() {
    for (input, expected) in [
        (
            "/posters/a.jpg?size=2&amp;lang=zh",
            "/posters/a.jpg?size=2&lang=zh",
        ),
        ("../images/a.jpg", "../images/a.jpg"),
        ("//cdn.example.test/a.jpg", "//cdn.example.test/a.jpg"),
        (
            "https://cdn.example.test/a.jpg?x=1&amp;amp;y=2",
            "https://cdn.example.test/a.jpg?x=1&amp;y=2",
        ),
    ] {
        let html = fixture(input);
        assert_eq!(
            home_from_html(&html).unwrap().items[0].cover.as_deref(),
            Some(expected)
        );
        assert_eq!(
            list_from_html(&html, 1, "/list").unwrap().items[0]
                .cover
                .as_deref(),
            Some(expected)
        );
        assert_eq!(
            parse_search_items(&html)[0].cover.as_deref(),
            Some(expected)
        );
        assert_eq!(parse_detail(&html, "1").cover.as_deref(), Some(expected));
    }
}

#[test]
fn cover_markup_supports_original_attribute_and_rejects_non_network_schemes() {
    let html = fixture("/images/a.jpg?x=1&#38;y=2").replace(
        "data-src=\"/images/a.jpg?x=1&#38;y=2\"",
        "data-original='/images/a.jpg?x=1&#38;y=2'",
    );
    assert_eq!(
        parse_items(&html)[0].cover.as_deref(),
        Some("/images/a.jpg?x=1&y=2")
    );
    for input in [
        "",
        "javascript:alert(1)",
        "data:image/gif;base64,AAAA",
        "file:///tmp/poster.jpg",
        "#poster",
    ] {
        assert!(parse_items(&fixture(input))[0].cover.is_none(), "{input}");
    }
}

#[tokio::test]
async fn cover_transport_resolves_against_successful_final_page_for_all_entrypoints() {
    let proxy = serve(|request| match request.uri.host().unwrap() {
        "primary-cover.invalid" => StatusCode::BAD_GATEWAY.into_response(),
        "backup-cover.invalid" => (
            StatusCode::FOUND,
            [(
                "location",
                "http://final-cover.invalid/catalog/pages/list.html",
            )],
        )
            .into_response(),
        "final-cover.invalid" => fixture("../posters/a.jpg?x=1&amp;y=2").into_response(),
        _ => panic!("unexpected request"),
    })
    .await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = PanWebShare::new();
    site.set_http_context(store, "cover-fixture");
    let ext = r#"{"site":["http://primary-cover.invalid","http://backup-cover.invalid"]}"#;
    let expected = Some("http://final-cover.invalid/catalog/posters/a.jpg?x=1&y=2");
    assert_eq!(
        site.home(ext).await.unwrap().items[0].cover.as_deref(),
        expected
    );
    assert_eq!(
        site.list("1", 1, ext).await.unwrap().items[0]
            .cover
            .as_deref(),
        expected
    );
    assert_eq!(
        site.search("示例", 1, ext).await.unwrap().items[0]
            .cover
            .as_deref(),
        expected
    );
    assert_eq!(
        site.detail("1", ext).await.unwrap().cover.as_deref(),
        expected
    );
    assert_eq!(
        site.sticky.lock().unwrap().as_deref(),
        Some("http://backup-cover.invalid")
    );
    let hits = proxy.hits.lock().unwrap();
    assert_eq!(
        hits.len(),
        9,
        "one primary failure then two requests per operation"
    );
    assert_eq!(
        hits.iter()
            .filter(|r| r.uri.host() == Some("primary-cover.invalid"))
            .count(),
        1
    );
}
