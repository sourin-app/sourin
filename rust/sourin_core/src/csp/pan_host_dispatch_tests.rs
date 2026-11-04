use super::*;
use axum::{body::Body, http::Request, Router};
use std::sync::Mutex;

// Records the production call while delegating to the real source handler.
struct RecordingRealSite {
    inner: Arc<dyn CspSite>,
    calls: Mutex<Vec<(String, String)>>,
}

#[async_trait]
impl CspSite for RecordingRealSite {
    fn class(&self) -> &'static str { self.inner.class() }
    fn supports_search(&self) -> bool { self.inner.supports_search() }
    async fn search(&self, keyword: &str, page: u32, ext: &str) -> std::result::Result<CspList, String> {
        self.inner.search(keyword, page, ext).await
    }
    async fn home(&self, ext: &str) -> std::result::Result<crate::csp::CspHome, String> {
        self.inner.home(ext).await
    }
    async fn list(&self, tid: &str, page: u32, ext: &str) -> std::result::Result<CspList, String> {
        self.inner.list(tid, page, ext).await
    }
    async fn detail(&self, id: &str, ext: &str) -> std::result::Result<crate::csp::CspDetail, String> {
        self.inner.detail(id, ext).await
    }
    async fn play(&self, flag: &str, id: &str, ext: &str) -> std::result::Result<Vec<crate::csp::CspPlay>, String> {
        self.calls.lock().unwrap().push((flag.into(), id.into()));
        self.inner.play(flag, id, ext).await
    }
}

async fn assert_real_host_dispatch(inner: Arc<dyn CspSite>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let captured = seen.clone();
    let app = Router::new().fallback(move |request: Request<Body>| {
        let captured = captured.clone();
        async move {
            let path = request.uri().path().to_string();
            captured.lock().unwrap().push(path.clone());
            if path.starts_with("/s/") {
                r#"<script>locals.mset({"shareid":123,"share_uk":456,"bdstoken":"fixture"});</script>"#
            } else if path == "/share/verify" {
                r#"{"errno":0,"randsk":"fixture-share-key"}"#
            } else {
                r#"{"errno":0,"list":[{"fs_id":1,"server_filename":"fixture.mp4","isdir":0}]}"#
            }
        }
    });
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let mut endpoints = crate::pan_check::PanEndpoints::default();
    endpoints.baidu_page = format!("{base}/s");
    endpoints.baidu_verify = format!("{base}/share/verify");
    endpoints.baidu_list = format!("{base}/share/list");
    let checker = Box::leak(Box::new(crate::pan_check::PanChecker::with_endpoints(endpoints)));
    let _checker_scope = crate::pan_check::override_global_checker_for_tests(checker);
    let _credentials = crate::pan_auth::debug_override_credentials(vec![]);
    let site = Arc::new(RecordingRealSite { inner, calls: Mutex::new(Vec::new()) });
    let provider = CspProvider::for_test("real-share-source", site.clone(), "");
    let episode = "pan|https://pan.baidu.com/s/1fixture?pwd=test";
    let request = PlayRequest {
        episode_id: Some(episode.into()), flag: Some("selected-line".into()),
        episode_title: Some("02.mp4".into()), episode_order: Some(2),
        ..Default::default()
    };
    let result = provider.resolve(&MediaId::new("real-share-source", "fixture-item"), &request).await;
    server.abort();
    let error = result.expect_err("Baidu preface must not return a share webpage as media");
    assert_eq!(error.kind, ErrorKind::Unauthorized);
    assert_eq!(error.login_kind.as_deref(), Some("baidu"));
    assert!(error.message.contains("还未登录百度网盘账号"));
    assert_eq!(*site.calls.lock().unwrap(), [("selected-line".into(), episode.into())]);
    assert!(seen.lock().unwrap().iter().any(|path| path == "/share/list"), "The real anonymous precheck must execute before the Baidu resolver");
    // Intent is preserved; Baidu preface does not yet consume a selected fid/spec.
    assert_eq!(request.episode_title.as_deref(), Some("02.mp4"));
    assert_eq!(request.episode_order, Some(2));
}

#[tokio::test]
async fn hj_real_provider_dispatches_baidu_share_instead_of_returning_html() {
    assert_real_host_dispatch(Arc::new(crate::csp::hjzhen_cai::HJZhenCai::new())).await;
}

#[tokio::test]
async fn wogg_real_provider_dispatches_baidu_share_instead_of_returning_html() {
    assert_real_host_dispatch(Arc::new(crate::csp::wogg::Wogg::new())).await;
}

#[tokio::test]
async fn pan_web_share_real_provider_dispatches_baidu_share_instead_of_returning_html() {
    assert_real_host_dispatch(Arc::new(crate::csp::pan_web_share::PanWebShare::new())).await;
}
