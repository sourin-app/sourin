use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::response::IntoResponse;
use std::sync::Arc;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for Yinhai {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_json(url).await.map(|value| value.to_string())
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "*/*");
        assert!(!request.headers.contains_key("accept-language"));
        if request.uri.path() == "/probe" {
            assert!(!request.headers.contains_key("referer"));
        }
    }
}

#[tokio::test]
async fn global_proxy_catalog_v2_yinhai_preserves_real_get_contract() {
    contract::exercise(Yinhai::new()).await;
}

#[tokio::test]
async fn global_proxy_catalog_v2_yinhai_preserves_json_errors_without_direct_retry() {
    let origin = serve(|_| axum::Json(serde_json::json!({"fixture":"origin"})).into_response()).await;
    let proxy = serve(|_| "fixture invalid JSON".into_response()).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = Yinhai::new();
    site.set_http_context(store, "yinhai-json-fixture");
    let error = site.get_json(&origin.url).await.unwrap_err();
    assert!(error.contains("不是合法 JSON"), "{error}");
    assert!(error.contains("fixture invalid JSON"), "{error}");
    assert_eq!(proxy.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty());
}
