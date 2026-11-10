use super::*;
use crate::csp::http_context::test_support::Request;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for Wn4k {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get(url).await
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml");
        assert!(!request.headers.contains_key("accept-language"));
        if request.uri.path() == "/probe" {
            assert_eq!(request.headers["referer"].to_str().unwrap(), format!("{SITE}/"));
        }
    }
}

#[tokio::test]
async fn global_proxy_catalog_v2_wn4k_preserves_real_get_contract() {
    contract::exercise(Wn4k::new()).await;
}
