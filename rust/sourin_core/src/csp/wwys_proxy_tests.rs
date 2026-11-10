use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::response::IntoResponse;
use std::sync::Arc;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for Wwys {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get(url).await
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml");
    }
}

#[tokio::test]
async fn catalog_proxy_wwys_real_helper_preserves_policy_and_headers() {
    contract::exercise(Wwys::new()).await;
}

#[tokio::test]
async fn catalog_proxy_wwys_retains_success_status_template_error() {
    let origin = serve(|_| "ordinary origin page".into_response()).await;
    let proxy = serve(|_| "缺少文件：fixture/template.html".into_response()).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = Wwys::new();
    site.set_http_context(store, "wwys-template");
    let error = site.get(&format!("{}/index.php", origin.url)).await.unwrap_err();
    assert!(error.contains("模板缺失/路径形式不对"));
    assert_eq!(proxy.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty());
}
