use super::*;
use crate::csp::http_context::test_support::Request;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for TingShijie {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_text(url).await
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
async fn global_proxy_catalog_v3_ting_shijie_preserves_real_get_contract() {
    contract::exercise(TingShijie::new()).await;
}
