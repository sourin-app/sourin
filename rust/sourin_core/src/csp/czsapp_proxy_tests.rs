use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::StatusCode, response::IntoResponse};
use std::sync::Arc;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for Czsapp {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get(url).await
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml");
        assert_eq!(request.headers["accept-language"], "zh-CN,zh;q=0.9");
    }
}

#[tokio::test]
async fn catalog_proxy_czsapp_real_helper_preserves_policy_and_headers() {
    contract::exercise(Czsapp::new()).await;
}

#[tokio::test]
async fn catalog_proxy_czsapp_keeps_waf_error_before_generic_status_error() {
    let origin = serve(|_| "ordinary origin page".into_response()).await;
    let proxy = serve(|_| {
        (StatusCode::FORBIDDEN, "<link href=\"/.safeline/static/favicon.png\">").into_response()
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = Czsapp::new();
    site.set_http_context(store, "czsapp-waf");
    let error = site.get(&origin.url).await.unwrap_err();
    assert!(error.contains("上游被 WAF 拦截"));
    assert!(error.contains("HTTP 403"));
    assert!(error.contains("/.safeline/static/favicon.png"));
    assert_eq!(proxy.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty());
}
