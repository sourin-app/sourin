//! Real loopback HTTP evidence for source UA/Referer across a different host.
//! Exercises the ordinary streaming store and a real default-client control.
use super::*;
use crate::proxy::{ProxyConfig, ProxyMode, ProxyScope, ProxyStore, GLOBAL_PROXY};
use axum::http::Request;
use std::net::{Ipv4Addr, SocketAddr};
use tokio::sync::oneshot;

const SOURCE_UA: &str = "SourinCrossHostFixture/1.0";
const SOURCE_REFERER: &str = "https://source.invalid/watch";
const PLAYLIST: &str = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-ENDLIST\n";

#[derive(Clone, Debug)]
struct Seen {
    method: axum::http::Method,
    path: String,
    host: String,
    headers: HeaderMap,
}

struct FixtureServer {
    base: String,
    seen: Arc<Mutex<Vec<Seen>>>,
    stop: oneshot::Sender<()>,
    task: tokio::task::JoinHandle<std::io::Result<()>>,
}

impl FixtureServer {
    async fn start(ip: Ipv4Addr, redirect: Option<String>) -> Self {
        assert!(ip.is_loopback(), "fixture listener must be loopback");
        let listener = tokio::net::TcpListener::bind(SocketAddr::from((ip, 0))).await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let recorded = seen.clone();
        let app = Router::new().fallback(move |request: Request<Body>| {
            recorded.lock().unwrap().push(Seen {
                method: request.method().clone(),
                path: request.uri().path().to_string(),
                host: request.headers().get(header::HOST).unwrap().to_str().unwrap().to_string(),
                headers: request.headers().clone(),
            });
            let response = if let Some(destination) = &redirect {
                assert_eq!(request.uri().path(), "/entry.m3u8");
                Response::builder().status(StatusCode::FOUND)
                    .header(header::LOCATION, destination.as_str())
                    .body(Body::empty()).unwrap()
            } else {
                assert_eq!(request.uri().path(), "/landed.m3u8");
                Response::builder().header(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")
                    .body(Body::from(PLAYLIST)).unwrap()
            };
            async move { response }
        });
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(async move {
            axum::serve(listener, app).with_graceful_shutdown(async { let _ = stopped.await; }).await
        });
        Self { base, seen, stop, task }
    }

    async fn finish(self) -> Vec<Seen> {
        let _ = self.stop.send(());
        tokio::time::timeout(std::time::Duration::from_secs(5), self.task)
            .await.expect("fixture server did not finish").unwrap().unwrap();
        let recorded = self.seen.lock().unwrap().clone();
        recorded
    }
}

struct RedirectPair {
    first: FixtureServer,
    last: FixtureServer,
    entry: String,
    destination: String,
}

impl RedirectPair {
    async fn start() -> Self {
        let last = FixtureServer::start(Ipv4Addr::new(127, 0, 0, 2), None).await;
        let destination = format!("{}/landed.m3u8", last.base);
        let first = FixtureServer::start(Ipv4Addr::LOCALHOST, Some(destination.clone())).await;
        let entry = format!("{}/entry.m3u8", first.base);
        let from = reqwest::Url::parse(&entry).unwrap();
        let to = reqwest::Url::parse(&destination).unwrap();
        assert_ne!(from.host_str(), to.host_str(), "must exercise different hosts, not only different ports");
        for url in [&from, &to] {
            assert!(url.host_str().unwrap().parse::<Ipv4Addr>().unwrap().is_loopback());
            assert!(url.username().is_empty() && url.password().is_none() && url.query().is_none());
        }
        Self { first, last, entry, destination }
    }

    async fn finish(self) -> (Seen, Seen) {
        let first = self.first.finish().await;
        let last = self.last.finish().await;
        assert_eq!(first.len(), 1, "exactly one initial request");
        assert_eq!(last.len(), 1, "exactly one redirected request");
        let first = first.into_iter().next().unwrap();
        let last = last.into_iter().next().unwrap();
        assert_eq!(first.method, axum::http::Method::GET);
        assert_eq!(last.method, axum::http::Method::GET);
        assert_eq!(first.path, "/entry.m3u8");
        assert_eq!(last.path, "/landed.m3u8");
        assert!(first.host.starts_with("127.0.0.1:"));
        assert!(last.host.starts_with("127.0.0.2:"));
        (first, last)
    }
}

fn loopback_consumer() -> reqwest::Client {
    reqwest::Client::builder().no_proxy().redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(5)).build().unwrap()
}

async fn finish_wrapper(proxy: &StreamProxy) {
    let task = proxy.serve_task.lock().unwrap().take();
    if let Some(task) = task {
        task.abort();
        let outcome = task.await;
        assert!(outcome.is_ok() || outcome.as_ref().err().is_some_and(|error| error.is_cancelled()));
    }
}

#[tokio::test]
async fn normal_store_cross_host_redirect_preserves_source_headers() {
    let pair = RedirectPair::start().await;
    let store = Arc::new(ProxyStore::new());
    store.set(GLOBAL_PROXY, ProxyConfig {
        mode: ProxyMode::Direct, scope: ProxyScope::All, ..ProxyConfig::default()
    }).unwrap();
    let proxy = Arc::new(StreamProxy::with_proxy_store(store));
    let source_headers = vec![("User-Agent".into(), SOURCE_UA.into()),
        ("Referer".into(), SOURCE_REFERER.into())];
    let local = maybe_proxy(&proxy, &pair.entry, &source_headers, true).await.unwrap().unwrap();
    assert!(proxy.owns_url(&local));
    // The consumer supplies neither source header; the actual wrapper must do it.
    let response = loopback_consumer().get(&local).send().await.unwrap();
    let status = response.status();
    let body = response.text().await.unwrap();
    finish_wrapper(&proxy).await;
    let (first, last) = pair.finish().await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, PLAYLIST);
    for request in [&first, &last] {
        assert_eq!(request.headers.get(header::USER_AGENT).unwrap(), SOURCE_UA,
            "source User-Agent must reach both actual HTTP hosts");
    }
    assert_eq!(first.headers.get(header::REFERER).unwrap(), SOURCE_REFERER);
    assert_eq!(last.headers.get(header::REFERER).unwrap(), SOURCE_REFERER,
        "source Referer must survive the actual cross-host redirect");
}

#[tokio::test]
async fn default_client_redirect_rewrites_referer_control() {
    let pair = RedirectPair::start().await;
    let expected_default_referer = pair.entry.clone();
    let expected_destination = pair.destination.clone();
    let client = reqwest::Client::builder().no_proxy()
        .timeout(std::time::Duration::from_secs(5)).build().unwrap();
    let response = client.get(&pair.entry).header(header::USER_AGENT, SOURCE_UA)
        .header(header::REFERER, SOURCE_REFERER).send().await.unwrap();
    let status = response.status();
    let final_url = response.url().to_string();
    let body = response.text().await.unwrap();
    let (first, last) = pair.finish().await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(final_url, expected_destination);
    assert_eq!(body, PLAYLIST);
    assert_eq!(first.headers.get(header::REFERER).unwrap(), SOURCE_REFERER);
    for request in [&first, &last] {
        assert_eq!(request.headers.get(header::USER_AGENT).unwrap(), SOURCE_UA);
    }
    assert_eq!(last.headers.get(header::REFERER).unwrap(), expected_default_referer.as_str(),
        "control must observe reqwest's actual automatic Referer replacement");
    assert_ne!(last.headers.get(header::REFERER).unwrap(), SOURCE_REFERER);
}
