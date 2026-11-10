use super::*;
use crate::csp::http_context::test_support::Request;

#[path = "catalog_proxy_test_support.rs"]
mod contract;

#[async_trait::async_trait]
impl contract::FixtureSite for HDMoli {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_text(url, "loopback fixture").await
    }

    fn assert_headers(request: &Request) {
        assert_eq!(request.headers["user-agent"], UA);
        assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml");
        assert_eq!(request.headers["accept-language"], "zh-CN,zh;q=0.9");
        if request.uri.path() == "/probe" {
            assert_eq!(request.headers["referer"].to_str().unwrap(), format!("{SITE}/"));
        }
    }
}

#[tokio::test]
async fn global_proxy_catalog_v2_hd_moli_preserves_real_get_contract() {
    contract::exercise(HDMoli::new()).await;
}
