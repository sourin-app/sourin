use super::*;
use crate::csp::http_context::test_support::Request;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for ShuangXing {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_html(url).await
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "*/*");
        assert!(!request.headers.contains_key("accept-language"));
        if request.uri.path() == "/probe" {
            assert_eq!(request.headers["referer"].to_str().unwrap(), format!("{BASE}/"));
        }
    }
}

#[tokio::test]
async fn global_proxy_catalog_v2_shuang_xing_preserves_real_get_contract() {
    contract::exercise(ShuangXing::new()).await;
}
