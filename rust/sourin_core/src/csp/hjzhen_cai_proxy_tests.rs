use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::{provider::ListRequest, state::AppState};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::sync::Arc;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

fn assert_headers(request: &Request) {
    assert_eq!(request.method, Method::GET);
    assert!(request.body.is_empty());
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml,application/json");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
}

#[async_trait::async_trait]
impl contract::FixtureSite for HJZhenCai {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_text(url).await
    }

    fn assert_headers(request: &Request) {
        assert_headers(request);
    }
}

#[tokio::test]
async fn catalog_proxy_hjzhencai_real_helper_preserves_policy_and_headers() {
    contract::exercise(HJZhenCai::new()).await;
}

fn html(label: &str) -> String {
    format!(r#"<nav><a href="/index.php/vod/type/id/1.html">电影</a></nav>
<a href="/index.php/vod/detail/id/101.html" title="HJZhenCai {label}" class="module-item"><img src="http://cover.invalid/101.jpg"></a>
<a href="/index.php/vod/show/id/1/page/3.html">3</a>"#)
}

async fn assert_list(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.list(ListRequest {
        category_id: "1".into(), page: 2, ..Default::default()
    })).await.expect("loopback list exceeded its fixture budget").unwrap();
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].title, format!("HJZhenCai {label}"));
    assert_eq!(page.page, 2);
    assert_eq!(page.page_count, Some(3));
}

#[tokio::test]
async fn catalog_proxy_hjzhencai_import_runtime_hot_change_and_restore() {
    // Origin remains reachable, but all configured destinations are loopback.
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let base = origin.url.clone();
    let subscription = serde_json::json!({"sites":[{
        "key":"hjzhencai-local", "name":"HJZhenCai local fixture", "type":3,
        "api":"csp_HJZhenCai", "ext":{"site":[format!("{base}/hj")]}
    }]});
    let first = serve(move |request| {
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/subscription.json" {
            return axum::Json(subscription.clone()).into_response();
        }
        assert_headers(&request);
        assert!(matches!(request.uri.path(), "/hj/" | "/hj/index.php/vod/show/id/1/page/2.html"));
        assert_eq!(request.uri.query(), None);
        html("first proxy").into_response()
    }).await;
    let second = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.path(), "/hj/index.php/vod/show/id/1/page/2.html");
        assert_eq!(request.uri.query(), None);
        html("second proxy").into_response()
    }).await;
    let root = scratch("hjzhencai-proxy-factories");
    // Bootstrap's legacy lookup is confined to this newly created parent.
    let dir = root.join("data");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{base}/subscription.json"),
    )).await.expect("loopback import exceeded its fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let imported = report["imported"].as_array().unwrap();
    assert_eq!(imported.len(), 1, "{report}");
    let row = &imported[0];
    assert_eq!(row["api"], "csp_HJZhenCai");
    assert_eq!(row["categories"], 1);
    assert!(row["probeFailed"].is_null(), "{row}");
    assert_eq!(row["persisted"], true);
    let id = row["id"].as_str().unwrap().to_string();
    assert_list(&state, &id, "first proxy").await;
    assert_eq!(first.hits.lock().unwrap().len(), 3, "config, home probe, runtime list");
    assert!(origin.hits.lock().unwrap().is_empty());

    custom(&state.proxy, &second.url);
    assert_list(&state, &id, "second proxy").await;
    assert_eq!(first.hits.lock().unwrap().len(), 3);
    assert_eq!(second.hits.lock().unwrap().len(), 1);
    drop(state);

    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_list(&restored, &id, "second proxy").await;
    assert_eq!(second.hits.lock().unwrap().len(), 2);
    assert!(origin.hits.lock().unwrap().is_empty(), "no factory may bypass its injected policy");
    drop(restored);
    let _ = std::fs::remove_dir_all(root);
}

#[tokio::test]
async fn catalog_proxy_hjzhencai_suggest_failure_keeps_proxy_and_html_fallback() {
    let origin = serve(|_| html("unexpected direct").into_response()).await;
    let proxy = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        match request.uri.path() {
            "/index.php/ajax/suggest" => {
                assert_eq!(request.uri.query(), Some("mid=1&wd=alpha%2Bbeta%20two&limit=50"));
                (StatusCode::BAD_GATEWAY, "suggest fixture rejection").into_response()
            }
            "/index.php/vod/search.html" => {
                assert_eq!(request.uri.query(), Some("wd=alpha%2Bbeta%20two"));
                html("HTML fallback").into_response()
            }
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let site = HJZhenCai::new();
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    site.set_http_context(store, "hjzhencai-search-fixture");
    let ext = serde_json::json!({"site":[origin.url.clone()]}).to_string();
    let list = tokio::time::timeout(Duration::from_secs(3), site.search("alpha+beta two", 1, &ext))
        .await.expect("loopback search exceeded its fixture budget").unwrap();
    assert_eq!(list.items.len(), 1);
    assert_eq!(list.items[0].title, "HJZhenCai HTML fallback");
    assert_eq!(proxy.hits.lock().unwrap().len(), 2);
    assert!(origin.hits.lock().unwrap().is_empty(), "suggest rejection must not enable direct fallback");
}
