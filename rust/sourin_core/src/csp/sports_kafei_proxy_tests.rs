use super::*;
use crate::csp::http_context::test_support::Request;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for SportsKafei {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_json(url).await.map(|value| value.to_string())
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "application/json", "retain builder default_headers");
    }
}

#[tokio::test]
async fn catalog_proxy_sports_kafei_real_helper_preserves_policy_and_headers() {
    contract::exercise(SportsKafei::new()).await;
}
