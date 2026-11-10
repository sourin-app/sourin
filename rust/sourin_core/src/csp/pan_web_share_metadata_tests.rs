use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve};
use axum::response::IntoResponse;

fn cards(marker: &str) -> String {
    format!(
        r#"
<div class="module-items"><div data-note="module-item" class="{marker}-advertisement">
  <a href="/index.php/vod/detail/id/99.html" title="Not a card"><img data-src="/ad.jpg"></a>
</div>
<div class="featured {marker}">
 <div class="module-item-cover"><div class="module-item-pic">
  <a href="/index.php/vod/detail/id/101.html" title="Series A"></a>
  <img data-src="/a.jpg">
 </div></div>
 <div class="module-item-titlebox"><a href="/index.php/vod/detail/id/101.html" title="Series A">Series A</a></div>
 <div class="muted module-item-text"><span>更新至</span>03集</div>
</div>
<article class='featured {marker}'><div class="module-item-pic">
 <a href="/index.php/vod/detail/id/102.html" title="Series B"><img data-original='/b.jpg'></a>
 </div><div class='module-item-text muted'>全&#52;0集</div>
</article>
<div class="{marker}"><a href="/index.php/vod/detail/id/103.html" title="Series C"><img data-src="/c.jpg"></a>
 <div class="module-item-text">已完结</div></div>
<div class="{marker}"><a href="/index.php/vod/detail/id/104.html" title="Series D"><img data-src="/d.jpg"></a>
 <div class="module-item-text">MA 4K DV&amp;HDR</div></div>
<div class="{marker}"><a href="/index.php/vod/detail/id/105.html" title="Series E"></a></div>
<div class="module-item-text">全999集</div></div>"#
    )
}

fn assert_metadata(items: &[CspItem]) {
    assert_eq!(
        items.len(),
        5,
        "only whole card class tokens identify entries"
    );
    for (index, item) in items.iter().enumerate() {
        assert_eq!(item.id, (101 + index).to_string());
        assert_eq!(
            item.title,
            format!("Series {}", char::from(b'A' + index as u8))
        );
    }
    assert_eq!(
        items
            .iter()
            .map(|i| i.subtitle.as_deref())
            .collect::<Vec<_>>(),
        [
            Some("更新至03集"),
            Some("全40集"),
            Some("已完结"),
            Some("MA 4K DV&HDR"),
            None
        ]
    );
    assert_eq!(items[0].cover.as_deref(), Some("/a.jpg"));
    assert_eq!(items[1].cover.as_deref(), Some("/b.jpg"));
    assert!(items[4].cover.is_none());
}

#[test]
fn catalog_card_boundaries_preserve_own_status_and_cover() {
    assert_metadata(&parse_items(&cards("module-item")));
}

#[test]
fn search_card_boundaries_preserve_own_status_and_cover() {
    let html = cards("module-search-item").replace("title=\"Series", "title=\"立即播放Series");
    assert_metadata(&parse_search_items(&html));
}

#[test]
fn child_classes_alone_cannot_create_entries_or_borrow_status() {
    let outside = r#"<div class="module-item-pic"><a href="/index.php/vod/detail/id/1.html" title="Outside"></a></div>"#;
    assert!(parse_items(outside).is_empty());
    let single = r#"<div class="module-item"><a href="/index.php/vod/detail/id/1.html" title="No status"></a></div><span class="module-item-text">已完结</span>"#;
    let items = parse_items(single);
    assert_eq!(items.len(), 1);
    assert!(items[0].subtitle.is_none());
}

#[tokio::test]
async fn imported_catalog_and_search_keep_status_through_provider_mapping() {
    let proxy = serve(|request| {
        if request.uri.path() == "/subscription.json" {
            axum::Json(serde_json::json!({"sites":[{
                "key":"metadata-fixture","name":"Metadata fixture","type":3,"api":"csp_PanWebShare",
                "ext":{"site":["http://metadata.invalid"]}
            }]}))
            .into_response()
        } else {
            let marker = if request.uri.path().starts_with(PATH_SEARCH) {
                "module-search-item"
            } else {
                "module-item"
            };
            ("<a href=\"/index.php/vod/show/id/1.html\">Category</a>".to_string() + &cards(marker))
                .into_response()
        }
    })
    .await;
    let dir = scratch("panweb-metadata");
    let state = crate::state::AppState::bootstrap(dir.clone())
        .await
        .unwrap();
    custom(&state.proxy, &proxy.url);
    let report =
        crate::tvbox::import_tvbox_config(&state, "http://metadata.invalid/subscription.json")
            .await
            .unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty());
    let row = &report["imported"][0];
    assert!(row["probeFailed"].is_null());
    let id = row["id"].as_str().unwrap();
    let provider = state.registry.get(id).unwrap();
    let listed = provider
        .list(crate::provider::ListRequest {
            category_id: "1".into(),
            page: 1,
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(listed.items.len(), 5);
    assert_eq!(listed.items[0].subtitle.as_deref(), Some("更新至03集"));
    assert_eq!(listed.items[1].subtitle.as_deref(), Some("全40集"));
    assert_eq!(listed.items[2].subtitle.as_deref(), Some("已完结"));
    let searched = provider.search("fixture", 1).await.unwrap();
    assert_eq!(searched.items[0].subtitle.as_deref(), Some("更新至03集"));
    assert_eq!(
        searched.items[0].cover.as_deref(),
        Some("http://metadata.invalid/a.jpg")
    );
    drop(provider);
    drop(state);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn markup_noise_and_unclosed_cards_cannot_steal_a_neighbours_metadata() {
    let html = r#"
<div class=module-items>
<!-- <div class="module-item"><a href="/index.php/vod/detail/id/90.html" title="Comment"></a></div> -->
<script class="module-item">const html = '<div class="module-item"><a href="/index.php/vod/detail/id/91.html" title="Script"></a></div>';</script>
<div data-example=' class="module-item" '><a href="/index.php/vod/detail/id/92.html" title="Attribute"></a></div>
<div class="module-item"><a href="/index.php/vod/detail/id/1.html" title="Unclosed"></a>
<ARTICLE data-example=">" CLASS=module-item><a href="/index.php/vod/detail/id/2.html" title="Intact"></a>
 <div class=module-item-text><span>全</span>8集</div></ARTICLE>
</div></div>"#;
    let items = parse_items(html);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, "2");
    assert_eq!(items[0].title, "Intact");
    assert_eq!(items[0].subtitle.as_deref(), Some("全8集"));
}

#[test]
fn catalog_deduplicates_ids_and_caps_whole_cards() {
    let repeated = cards("module-item");
    assert_metadata(&parse_items(&(repeated.clone() + &repeated)));
    let html = (1..=MAX_ITEMS+5).map(|id| format!(
        r#"<div class="module-item"><a href="/index.php/vod/detail/id/{id}.html" title="Series {id}"></a><span class="module-item-text">更新至{id}集</span></div>"#
    )).collect::<String>();
    let items = parse_items(&html);
    assert_eq!(items.len(), MAX_ITEMS);
    assert_eq!(items.last().unwrap().id, MAX_ITEMS.to_string());
    assert_eq!(
        items.last().unwrap().subtitle.as_deref(),
        Some(format!("更新至{MAX_ITEMS}集").as_str())
    );
}
