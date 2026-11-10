//! Provider-owned error-kind and account-boundary regression tests.
use super::*;

const ERRORS: [(&str, ErrorKind); 3] = [
    ("network: 请求未完成", ErrorKind::Network),
    ("parse: 响应格式不符合协议（字段类型）", ErrorKind::Parse),
    (
        "unsupported: 网盘分享需独立选集和权限流程",
        ErrorKind::Unsupported,
    ),
];

#[test]
fn explicit_csp_error_prefixes_preserve_kind_before_incidental_words() {
    for (message, expected) in ERRORS {
        let error = classify_err("AppDrama", message.into());
        assert_eq!(error.kind, expected);
        assert_eq!(error.message, message);
        assert!(!error.needs_login && error.login_kind.is_none());
    }
    let error = classify_err(
        "Pan115",
        "unsupported: 请重新登录只是原文，并非宿主登录指令".into(),
    );
    assert_eq!(error.kind, ErrorKind::Unsupported);
    assert!(!error.needs_login && error.login_kind.is_none());
    let explicit = classify_err("Pan115", "NEED_LOGIN:115|需要登录".into());
    assert_eq!(explicit.kind, ErrorKind::Unauthorized);
    assert_eq!(explicit.login_kind.as_deref(), Some("115"));
}

struct PrefixSite(&'static str);
#[async_trait]
impl CspSite for PrefixSite {
    fn class(&self) -> &'static str {
        "AppDrama"
    }
    fn supports_search(&self) -> bool {
        true
    }
    fn accepts_selected_episode_id(&self, id: &str) -> bool {
        id.starts_with("app-drama:v2|")
    }
    async fn home(&self, _: &str) -> std::result::Result<crate::csp::CspHome, String> {
        Err(self.0.into())
    }
    async fn list(&self, _: &str, _: u32, _: &str) -> std::result::Result<CspList, String> {
        Err(self.0.into())
    }
    async fn search(&self, _: &str, _: u32, _: &str) -> std::result::Result<CspList, String> {
        Err(self.0.into())
    }
    async fn detail(&self, _: &str, _: &str) -> std::result::Result<crate::csp::CspDetail, String> {
        Err(self.0.into())
    }
    async fn play(
        &self,
        _: &str,
        _: &str,
        _: &str,
    ) -> std::result::Result<Vec<crate::csp::CspPlay>, String> {
        Err(self.0.into())
    }
}

#[tokio::test]
async fn actual_provider_bridge_preserves_prefix_kinds_without_entering_account_resolution() {
    for (message, expected) in ERRORS {
        let provider = CspProvider::for_test("prefix-fixture", Arc::new(PrefixSite(message)), "");
        let id = MediaId::new("prefix-fixture", "1001");
        let request = PlayRequest {
            episode_id: Some("app-drama:v2|synthetic-selected".into()),
            flag: Some("Fixture".into()),
            ..Default::default()
        };
        let errors = [
            provider.categories().await.err().unwrap(),
            provider.detail(&id).await.err().unwrap(),
            provider.resolve(&id, &request).await.err().unwrap(),
        ];
        for error in errors {
            assert_eq!(error.kind, expected);
            assert_eq!(error.message, message);
            assert!(!error.needs_login && error.login_kind.is_none());
        }
    }
}
