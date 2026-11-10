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
    assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
}

#[async_trait::async_trait]
impl contract::FixtureSite for Wogg {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_html(url).await
    }

    fn assert_headers(request: &Request) {
        assert_headers(request);
    }
}

#[tokio::test]
async fn catalog_proxy_wogg_real_helper_preserves_policy_and_headers() {
    contract::exercise(Wogg::new()).await;
}

fn html(label: &str) -> String {
    format!(r#"<nav><a class="nav-link" href="/vodtype/1.html">电影</a></nav>
<div class="module-item"><a href="/voddetail/101.html" title="Wogg {label}">film</a></div>"#)
}

async fn assert_list(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.list(ListRequest {
        category_id: "1".into(), page: 2, ..Default::default()
    })).await.expect("loopback list exceeded its fixture budget").unwrap();
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].title, format!("Wogg {label}"));
    assert_eq!(page.page, 2);
    assert_eq!(page.page_count, None);
}

#[tokio::test]
async fn catalog_proxy_wogg_import_runtime_hot_change_and_restore() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let base = origin.url.clone();
    let subscription = serde_json::json!({"sites":[{
        "key":"wogg-local", "name":"Wogg local fixture", "type":3,
        "api":"csp_Wogg", "ext":{"site":[format!("{base}/wogg")]}
    }]});
    let first = serve(move |request| {
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/subscription.json" {
            return axum::Json(subscription.clone()).into_response();
        }
        assert_headers(&request);
        assert!(matches!(request.uri.path(), "/wogg/" | "/wogg/vodshow/1--------2---.html"));
        assert_eq!(request.uri.query(), None);
        html("first proxy").into_response()
    }).await;
    let second = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.path(), "/wogg/vodshow/1--------2---.html");
        assert_eq!(request.uri.query(), None);
        html("second proxy").into_response()
    }).await;
    let root = scratch("wogg-proxy-factories");
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
    assert_eq!(row["api"], "csp_Wogg");
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
async fn catalog_proxy_wogg_hot_change_keeps_sticky_mirror_and_encoded_search() {
    let origin = serve(|_| html("unexpected direct").into_response()).await;
    let first = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.query(), None);
        match request.uri.path() {
            "/a/" => (StatusCode::BAD_GATEWAY, "first mirror rejected").into_response(),
            "/b/" => html("mirror B").into_response(),
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let second = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.path(), "/b/index.php/vodsearch/alpha%2Bbeta%20two----------2---.html");
        assert_eq!(request.uri.query(), None);
        html("sticky B after change").into_response()
    }).await;
    let site = Wogg::new();
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "wogg-sticky-fixture");
    let ext = serde_json::json!({"site":[format!("{}/a", origin.url), format!("{}/b", origin.url)]}).to_string();
    let home = tokio::time::timeout(Duration::from_secs(3), site.home(&ext))
        .await.expect("loopback home exceeded its fixture budget").unwrap();
    assert_eq!(home.items[0].title, "Wogg mirror B");
    let paths: Vec<_> = first.hits.lock().unwrap().iter().map(|r| r.uri.path().to_string()).collect();
    assert_eq!(paths, ["/a/", "/b/"]);

    custom(&store, &second.url);
    let list = tokio::time::timeout(Duration::from_secs(3), site.search("alpha+beta two", 2, &ext))
        .await.expect("loopback search exceeded its fixture budget").unwrap();
    assert_eq!(list.items[0].title, "Wogg sticky B after change");
    assert_eq!(second.hits.lock().unwrap().len(), 1, "client rebuild preserves successful-mirror ordering");
    assert_eq!(first.hits.lock().unwrap().len(), 2);
    assert!(origin.hits.lock().unwrap().is_empty());

    let rejected = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        (StatusCode::BAD_GATEWAY, "all mirrors rejected").into_response()
    }).await;
    custom(&store, &rejected.url);
    let error = tokio::time::timeout(Duration::from_secs(3), site.list("1", 1, &ext))
        .await.expect("loopback mirror failure exceeded its fixture budget").unwrap_err();
    assert!(error.contains("HTTP 502"), "{error}");
    let paths: Vec<_> = rejected.hits.lock().unwrap().iter().map(|r| r.uri.path().to_string()).collect();
    assert_eq!(paths, ["/b/vodshow/1--------1---.html", "/a/vodshow/1--------1---.html"]);
    assert!(origin.hits.lock().unwrap().is_empty(), "mirror retries cannot bypass the failing proxy");
}
