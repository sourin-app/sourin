use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::sync::Arc;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for GuiGui {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_json(url).await.map(|value| value.to_string())
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "application/json");
        assert!(!request.headers.contains_key("accept-language"));
        if request.uri.path() == "/probe" {
            assert!(!request.headers.contains_key("referer"));
        }
    }
}

#[tokio::test]
async fn global_proxy_catalog_v3_gui_gui_preserves_real_json_get_contract() {
    contract::exercise(GuiGui::new()).await;
}

fn search_payload(label: &str) -> String {
    serde_json::json!({"code":200,"data":[{
        "id":"fixture-id", "name":format!("fixture + {label}"),
        "cover":"http://127.0.0.1/cover.png", "episodes":7,
        "url":format!("http://127.0.0.1/share/{label}")
    }]}).to_string()
}

fn assert_search_request(request: &Request) {
    assert_eq!(request.method, Method::GET);
    assert_eq!(request.uri.path(), "/api/video/duanju");
    assert_eq!(request.uri.query(), Some("act=search&name=fixture%20%2B"));
    assert!(request.body.is_empty());
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["accept"], "application/json");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    assert!(!request.headers.contains_key("referer"));
    assert!(!request.headers.contains_key("accept-language"));
}

async fn search_fixture(site: &GuiGui, target: &str) -> Result<CspList, String> {
    tokio::time::timeout(std::time::Duration::from_secs(3), site.search_at(target, "fixture +", 1))
        .await.expect("loopback GuiGui search exceeded its fixture budget")
}

async fn assert_cached(site: &GuiGui, label: &str) {
    let detail = site.detail("fixture-id", "").await.unwrap();
    assert_eq!(detail.title, format!("fixture + {label}"));
    assert_eq!(detail.episodes.len(), 1);
    assert_eq!(detail.episodes[0].id, format!("fixture-id|http://127.0.0.1/share/{label}"));
    for id in ["fixture-id", detail.episodes[0].id.as_str()] {
        let play = site.play("", id, "").await.unwrap();
        assert_eq!(play[0].url, format!("http://127.0.0.1/share/{label}"));
        assert_eq!(play[0].headers, vec![("User-Agent".to_string(), UA.to_string())]);
        assert_eq!(play[0].label.as_deref(), Some("网盘分享页（需 Pan 链路解析）"));
    }
}

#[tokio::test]
async fn global_proxy_catalog_v3_gui_gui_preserves_search_cache_across_policy_and_errors() {
    let origin = serve(|request| {
        assert_search_request(&request);
        ([("set-cookie", "fixture=must-not-persist; Path=/")], search_payload("origin")).into_response()
    }).await;
    let first = serve(|request| {
        assert_search_request(&request);
        search_payload("first").into_response()
    }).await;
    let second = serve(|request| {
        assert_search_request(&request);
        search_payload("second").into_response()
    }).await;
    let target = format!("{}/api/video/duanju?act=search&name=fixture%20%2B", origin.url);
    let site = GuiGui::new();
    assert_eq!(search_fixture(&site, &target).await.unwrap().items[0].title, "fixture + origin");
    assert_cached(&site, "origin").await;
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "gui-gui-cache-fixture");
    assert_cached(&site, "origin").await;
    let list = search_fixture(&site, &target).await.unwrap();
    assert_eq!(list.items[0].title, "fixture + first");
    assert_eq!(list.items[0].subtitle.as_deref(), Some("共7集"));
    assert_eq!(list.page, 1);
    assert_eq!(list.page_count, None);
    assert_eq!(list.total, None);
    assert_cached(&site, "first").await;
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    site.set_http_context(store.clone(), "gui-gui-cache-fixture");
    assert_cached(&site, "first").await;
    custom(&store, &second.url);
    assert_cached(&site, "first").await;
    assert_eq!(search_fixture(&site, &target).await.unwrap().items[0].title, "fixture + second");
    assert_cached(&site, "second").await;
    assert_eq!(second.hits.lock().unwrap().len(), 1);
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    for (status, body, expected) in [
        (StatusCode::BAD_GATEWAY, "fixture rejection", "HTTP 502"),
        (StatusCode::OK, "fixture invalid JSON", "不是合法 JSON"),
        (StatusCode::OK, r#"{"code":403,"msg":"fixture denied"}"#, "返回 code=403"),
        (StatusCode::OK, r#"{"code":200}"#, "没有 data 数组"),
        (StatusCode::OK, r#"{"code":200,"data":[]}"#, "data 解析出 0 条"),
    ] {
        let rejected = serve(move |request| {
            assert_search_request(&request);
            (status, body).into_response()
        }).await;
        custom(&store, &rejected.url);
        let error = search_fixture(&site, &target).await.unwrap_err();
        assert!(error.contains(expected), "{error}");
        assert_cached(&site, "second").await;
        assert_eq!(rejected.hits.lock().unwrap().len(), 1);
        assert_eq!(origin.hits.lock().unwrap().len(), 1);
    }
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    custom(&store, &unavailable);
    assert!(search_fixture(&site, &target).await.is_err());
    assert_cached(&site, "second").await;
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(search_fixture(&site, &target).await.unwrap().items[0].title, "fixture + origin");
    assert_cached(&site, "origin").await;
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
}
