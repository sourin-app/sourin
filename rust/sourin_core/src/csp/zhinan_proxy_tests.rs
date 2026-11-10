use super::*;
use crate::csp::http_context::test_support::Request;

#[path = "catalog_proxy_test_support.rs"]
mod contract;
#[path = "catalog_proxy_factory_tests.rs"]
mod factories;

#[async_trait::async_trait]
impl contract::FixtureSite for Zhinan {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get(url).await
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml");
    }
}

#[tokio::test]
async fn catalog_proxy_zhinan_real_helper_preserves_policy_and_headers() {
    contract::exercise(Zhinan::new()).await;
}
