use super::*;
use crate::csp::http_context::test_support::Request;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for RenRen {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get(url).await
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml");
        if request.uri.path() == "/probe" {
            assert_eq!(request.headers["referer"].to_str().unwrap(), format!("{SITE}/"));
        }
    }
}

#[tokio::test]
async fn catalog_proxy_ren_ren_real_helper_preserves_policy_and_headers() {
    contract::exercise(RenRen::new()).await;
}
