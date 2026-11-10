use super::*;
use crate::csp::http_context::test_support::Request;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for AllLive {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_json(url, UA_DART, "http://fixture-referer.invalid/")
            .await.map(|value| value.to_string())
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA_DART, "request UA overrides builder UA");
        assert_eq!(request.headers["accept"], "application/json, text/plain, */*");
        if request.uri.path() == "/probe" {
            assert_eq!(request.headers["referer"], "http://fixture-referer.invalid/");
        }
    }
}

#[tokio::test]
async fn catalog_proxy_all_live_real_helper_preserves_policy_and_headers() {
    contract::exercise(AllLive::new()).await;
}
