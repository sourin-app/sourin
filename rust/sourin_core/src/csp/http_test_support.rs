use axum::{http::{HeaderMap, Method, Uri}, response::Response, routing::any};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug)]
pub(crate) struct Request {
    pub method: Method,
    pub uri: Uri,
    pub headers: HeaderMap,
    pub body: bytes::Bytes,
}

pub(crate) struct Fixture {
    pub url: String,
    pub hits: Arc<Mutex<Vec<Request>>>,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for Fixture {
    fn drop(&mut self) { self.server.abort(); }
}

pub(crate) async fn serve<F>(respond: F) -> Fixture
where F: Fn(Request) -> Response + Send + Sync + 'static {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let hits = Arc::new(Mutex::new(Vec::new()));
    let observed = hits.clone();
    let respond = Arc::new(respond);
    let app = axum::Router::new().fallback(any(move |method: Method, uri: Uri, headers: HeaderMap, body: bytes::Bytes| {
        let hits = observed.clone();
        let respond = respond.clone();
        async move {
            let request = Request { method, uri, headers, body };
            hits.lock().unwrap().push(request.clone());
            respond(request)
        }
    }));
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    Fixture { url, hits, server }
}

pub(crate) fn custom(store: &crate::proxy::ProxyStore, url: &str) {
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig {
        mode: crate::proxy::ProxyMode::Custom, url: Some(url.to_string()), ..Default::default()
    }).unwrap();
}

pub(crate) fn scratch(label: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("sourin-csp-http-{label}-{}-{}",
        std::process::id(), chrono::Utc::now().timestamp_nanos_opt().unwrap()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    dir
}
