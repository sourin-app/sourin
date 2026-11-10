//! Actual registered-cover forwarding and log output, not a helper fed its own
//! expected result. Root runs this module with --test-threads=1 because the
//! existing log override is process scoped. Endpoints are loopback-only.
use super::*;
use crate::proxy::{ProxyConfig, ProxyMode, ProxyScope, ProxyStore, GLOBAL_PROXY};
use axum::http::Request;
use axum::routing::any;
use serde_json::Value;
use std::convert::Infallible;
use std::ffi::OsString;
use std::sync::atomic::{AtomicUsize, Ordering};

const DIAGNOSTIC_PREFIX: &str = "COVER_FAILURE ";
const SECRET_PATH: &str = "fixture-private-poster";
const SECRET_QUERY: &str = "fixture-query-value";
const SECRET_HEADER: &str = "fixture-private-header";
const SECRET_BODY: &str = "fixture-private-body";

struct LogFile {
    previous: Option<OsString>,
    directory: std::path::PathBuf,
    path: std::path::PathBuf,
}

impl LogFile {
    fn new() -> Self {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "sourin-cover-diagnostics-{}-{nonce}", std::process::id(),
        ));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("diagnostics.log");
        let previous = std::env::var_os("SOURIN_LOG_FILE");
        std::env::set_var("SOURIN_LOG_FILE", &path);
        Self { previous, directory, path }
    }

    fn records(&self) -> Vec<Value> {
        std::fs::read_to_string(&self.path).unwrap_or_default().lines()
            .filter_map(|line| line.split_once(DIAGNOSTIC_PREFIX).map(|(_, json)| json))
            .map(|json| serde_json::from_str(json).expect("diagnostic is valid JSON"))
            .collect()
    }
}

impl Drop for LogFile {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => std::env::set_var("SOURIN_LOG_FILE", value),
            None => std::env::remove_var("SOURIN_LOG_FILE"),
        }
        let _ = std::fs::remove_file(&self.path);
        let _ = std::fs::remove_dir(&self.directory);
    }
}

struct NeverBody;

impl Stream for NeverBody {
    type Item = Result<Bytes, Infallible>;
    fn poll_next(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        Poll::Pending
    }
}

#[derive(Clone)]
struct Endpoint {
    status: StatusCode,
    headers: Vec<(&'static str, &'static str)>,
    requests: Arc<AtomicUsize>,
    redirect_first: bool,
    endless_body: bool,
}

async fn respond(State(endpoint): State<Endpoint>, request: Request<Body>) -> Response {
    endpoint.requests.fetch_add(1, Ordering::SeqCst);
    if endpoint.redirect_first && request.uri().path().starts_with("/entry/") {
        return Response::builder().status(StatusCode::FOUND)
            .header(header::LOCATION,
                format!("/final/{SECRET_PATH}?token={SECRET_QUERY}"))
            .body(Body::empty()).unwrap();
    }
    let mut response = Response::builder().status(endpoint.status)
        .header(header::CONTENT_TYPE, "text/plain; charset=utf-8");
    for (name, value) in endpoint.headers {
        response = response.header(name, value);
    }
    response.body(if endpoint.endless_body {
        Body::from_stream(NeverBody)
    } else {
        Body::from(SECRET_BODY)
    }).unwrap()
}

struct Fixture {
    base: String,
    requests: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

impl Fixture {
    async fn start(
        status: StatusCode,
        headers: Vec<(&'static str, &'static str)>,
        redirect_first: bool,
        endless_body: bool,
    ) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(AtomicUsize::new(0));
        let app = Router::new().fallback(any(respond)).with_state(Endpoint {
            status, headers, requests: requests.clone(), redirect_first, endless_body,
        });
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self { base, requests, task }
    }

    fn url(&self, redirect: bool) -> String {
        format!("{}/{}/{SECRET_PATH}?token={SECRET_QUERY}", self.base,
            if redirect { "entry" } else { "final" })
    }
}

impl Drop for Fixture {
    fn drop(&mut self) { self.task.abort(); }
}

struct RunningProxy(Arc<StreamProxy>);

impl RunningProxy {
    async fn direct() -> Self {
        Self::start(ProxyConfig::default()).await
    }

    async fn start(config: ProxyConfig) -> Self {
        let store = Arc::new(ProxyStore::new());
        store.set(GLOBAL_PROXY, config).unwrap();
        let proxy = Arc::new(StreamProxy::with_proxy_store(store));
        proxy.ensure_started().await.unwrap();
        Self(proxy)
    }
}

impl Drop for RunningProxy {
    fn drop(&mut self) {
        if let Some(task) = self.0.serve_task.lock().unwrap().take() {
            task.abort();
        }
    }
}

fn client() -> reqwest::Client {
    reqwest::Client::builder().no_proxy()
        .timeout(std::time::Duration::from_secs(5)).build().unwrap()
}

fn one_record(log: &LogFile) -> Value {
    let records = log.records();
    assert_eq!(records.len(), 1, "one Cover failure must emit one safe diagnostic");
    let record = records.into_iter().next().unwrap();
    let expected = ["status", "final_scheme", "https_only_marker", "proxy_status_present",
        "proxy_authenticate_present", "via_present", "attribution"];
    let object = record.as_object().unwrap();
    assert_eq!(object.len(), expected.len(), "no unbounded/raw diagnostic fields");
    assert!(expected.iter().all(|field| object.contains_key(*field)));
    let serialized = record.to_string();
    for forbidden in [SECRET_PATH, SECRET_QUERY, SECRET_HEADER, SECRET_BODY,
        "127.0.0.1", "http://", "https://", "username", "token=", "source-cookie"] {
        assert!(!serialized.contains(forbidden), "raw network values cannot enter the diagnostic");
    }
    record
}

async fn fetch_cover(proxy: &RunningProxy, url: &str) -> reqwest::Response {
    let registered = proxy.0.register_cover(url,
        vec![("Referer".into(), format!("https://source.invalid/{SECRET_HEADER}"))]);
    client().get(registered).send().await.unwrap()
}

#[tokio::test]
async fn response_status_and_final_scheme_come_from_registered_cover_forwarding() {
    let log = LogFile::new();
    let upstream = Fixture::start(StatusCode::IM_A_TEAPOT, vec![], true, false).await;
    let proxy = RunningProxy::direct().await;
    let response = fetch_cover(&proxy, &upstream.url(true)).await;
    assert_eq!(response.status(), StatusCode::IM_A_TEAPOT);
    assert_eq!(response.text().await.unwrap(), "上游返回 418 ");
    assert_eq!(upstream.requests.load(Ordering::SeqCst), 2,
        "the original redirect is followed once; diagnostics add no request");
    let record = one_record(&log);
    assert_eq!(record["status"], 418);
    assert_eq!(record["final_scheme"], "http");
    assert_eq!(record["https_only_marker"], "absent");
    assert_eq!(record["attribution"], "http_response_unattributed");
}

#[tokio::test]
async fn configured_proxy_block_marker_is_advertised_without_confirming_its_origin() {
    let log = LogFile::new();
    let origin = Fixture::start(StatusCode::OK, vec![], false, false).await;
    let remote_proxy = Fixture::start(StatusCode::FORBIDDEN,
        vec![("x-mitmproxy-blocked-reason", "HTTPS-ONLY")], false, false).await;
    let proxy = RunningProxy::start(ProxyConfig {
        mode: ProxyMode::Custom, url: Some(remote_proxy.base.clone()),
        scope: ProxyScope::ApiOnly, ..ProxyConfig::default()
    }).await;
    let response = fetch_cover(&proxy, &origin.url(false)).await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert_eq!(response.text().await.unwrap(),
        "上游返回 403 （可能被防盗链拦截或地址已过期）");
    assert_eq!(origin.requests.load(Ordering::SeqCst), 0);
    assert_eq!(remote_proxy.requests.load(Ordering::SeqCst), 1);
    let record = one_record(&log);
    assert_eq!(record["status"], 403);
    assert_eq!(record["https_only_marker"], "explicit");
    assert_eq!(record["attribution"], "proxy_advertised_block");
}

#[tokio::test]
async fn unknown_and_spoofed_proxy_headers_do_not_upgrade_attribution_or_leak_values() {
    let log = LogFile::new();
    let upstream = Fixture::start(StatusCode::FORBIDDEN, vec![
        ("x-mitmproxy-blocked-reason", "HTTPS-ONLY fixture-private-header"),
        ("via", "1.1 fixture-private-header"),
        ("proxy-status", "fixture; details=fixture-private-header"),
        ("proxy-authenticate", "Basic realm=fixture-private-header"),
        ("server", "mitmproxy fixture-private-header"),
        ("set-cookie", "source-cookie=fixture-private-header"),
    ], false, false).await;
    let proxy = RunningProxy::direct().await;
    let response = fetch_cover(&proxy, &upstream.url(false)).await;
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert_eq!(upstream.requests.load(Ordering::SeqCst), 1);
    let record = one_record(&log);
    assert_eq!(record["https_only_marker"], "unrecognized");
    assert_eq!(record["proxy_status_present"], true);
    assert_eq!(record["proxy_authenticate_present"], true);
    assert_eq!(record["via_present"], true);
    assert_eq!(record["attribution"], "http_response_unattributed");
}

#[tokio::test]
async fn unmarked_403_is_not_inferred_from_http_or_plain_text() {
    let log = LogFile::new();
    let upstream = Fixture::start(StatusCode::FORBIDDEN, vec![], false, false).await;
    let proxy = RunningProxy::direct().await;
    assert_eq!(fetch_cover(&proxy, &upstream.url(false)).await.status(), StatusCode::FORBIDDEN);
    let record = one_record(&log);
    assert_eq!(record["status"], 403);
    assert_eq!(record["final_scheme"], "http");
    assert_eq!(record["https_only_marker"], "absent");
    assert_eq!(record["proxy_status_present"], false);
    assert_eq!(record["proxy_authenticate_present"], false);
    assert_eq!(record["via_present"], false);
    assert_eq!(record["attribution"], "http_response_unattributed");
}

#[tokio::test]
async fn cover_failure_diagnostics_do_not_read_or_wait_for_the_error_body() {
    let log = LogFile::new();
    let upstream = Fixture::start(StatusCode::FORBIDDEN, vec![], false, true).await;
    let proxy = RunningProxy::direct().await;
    let response = tokio::time::timeout(std::time::Duration::from_secs(2),
        fetch_cover(&proxy, &upstream.url(false))).await.expect("headers alone must complete failure");
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert_eq!(response.text().await.unwrap(),
        "上游返回 403 （可能被防盗链拦截或地址已过期）");
    assert_eq!(upstream.requests.load(Ordering::SeqCst), 1);
    assert_eq!(one_record(&log)["https_only_marker"], "absent");
}

#[tokio::test]
async fn successful_covers_and_failed_media_never_emit_cover_failure_diagnostics() {
    let log = LogFile::new();
    let success = Fixture::start(StatusCode::OK, vec![], false, false).await;
    let failure = Fixture::start(StatusCode::FORBIDDEN,
        vec![("x-mitmproxy-blocked-reason", "HTTPS-ONLY")], false, false).await;
    let proxy = RunningProxy::direct().await;
    assert_eq!(fetch_cover(&proxy, &success.url(false)).await.text().await.unwrap(), SECRET_BODY);
    let registered_media = proxy.0.register(&failure.url(false), vec![]);
    assert_eq!(client().get(registered_media).send().await.unwrap().status(), StatusCode::FORBIDDEN);
    assert_eq!(success.requests.load(Ordering::SeqCst), 1);
    assert_eq!(failure.requests.load(Ordering::SeqCst), 1);
    assert!(log.records().is_empty(), "unrelated success/media paths must remain unchanged");
}
