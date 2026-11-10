use crate::csp::http_context::test_support::{custom, serve, Request};
use crate::csp::CspSite;
use axum::{http::StatusCode, response::IntoResponse};
use std::{io::Write, sync::Arc, time::Duration};

#[async_trait::async_trait]
pub(super) trait FixtureSite: CspSite {
    async fn fetch(&self, url: &str) -> Result<String, String>;
    fn assert_headers(request: &Request);
}

fn payload(label: &str) -> String {
    serde_json::json!({"fixture":label}).to_string()
}

fn assert_request<S: FixtureSite>(request: &Request) {
    assert_eq!(request.method, axum::http::Method::GET);
    assert!(request.body.is_empty());
    assert_eq!(request.uri.query(), Some("first=alpha%2Bbeta&second=two"));
    assert!(!request.headers.contains_key("cookie"), "these engines have no cookie jar");
    assert!(!request.headers.contains_key("authorization"));
    S::assert_headers(request);
}

async fn fetch<S: FixtureSite>(site: &S, url: &str) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), site.fetch(url))
        .await
        .expect("loopback helper request exceeded its fixture budget")
}

/// Exercise the production helper, keeping a reachable origin to detect any
/// silent direct retry. No fixture URL can reach an external endpoint.
pub(super) async fn exercise<S: FixtureSite + 'static>(site: S) {
    let origin = serve(|request| {
        assert_request::<S>(&request);
        payload("origin").into_response()
    }).await;
    let target = format!("{}/probe?first=alpha%2Bbeta&second=two", origin.url);
    assert_eq!(fetch(&site, &target).await.unwrap(), payload("origin"));
    assert_eq!(origin.hits.lock().unwrap().len(), 1);

    let first = serve(|request| {
        assert_request::<S>(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        payload("first proxy").into_response()
    }).await;
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(payload("second proxy gzip").as_bytes()).unwrap();
    let compressed = encoder.finish().unwrap();
    assert_eq!(&compressed[..3], &[0x1f, 0x8b, 0x08]);
    let redirect = format!("{}/landed?first=alpha%2Bbeta&second=two", origin.url);
    let second = serve(move |request| {
        assert_request::<S>(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/probe" {
            (StatusCode::FOUND, [
                ("location", redirect.clone()),
                ("set-cookie", "fixture=must-not-persist; Path=/".to_string()),
            ]).into_response()
        } else {
            assert_eq!(request.uri.path(), "/landed");
            ([
                ("content-type", "application/json; charset=utf-8"),
                ("content-encoding", "gzip"),
            ], compressed.clone()).into_response()
        }
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "catalog-batch-fixture");
    assert_eq!(fetch(&site, &target).await.unwrap(), payload("first proxy"));
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);

    custom(&store, &second.url);
    assert_eq!(fetch(&site, &target).await.unwrap(), payload("second proxy gzip"));
    assert_eq!(second.hits.lock().unwrap().len(), 2, "the original redirect policy is retained");
    assert_eq!(first.hits.lock().unwrap().len(), 1, "the same site stops using its old proxy");
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "redirects retain the proxy");

    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding.to_str().unwrap().split(',').any(|part| part.trim() == "gzip"));
    for proxy in [&first, &second] {
        for request in proxy.hits.lock().unwrap().iter() {
            assert_eq!(request.headers["accept-encoding"], encoding);
        }
    }

    let rejected = serve(|request| {
        assert_request::<S>(&request);
        (StatusCode::BAD_GATEWAY, "fixture rejection").into_response()
    }).await;
    custom(&store, &rejected.url);
    let error = fetch(&site, &target).await.unwrap_err();
    assert!(error.contains("HTTP 502"), "preserve the engine HTTP error: {error}");
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "HTTP failure cannot retry directly");

    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    custom(&store, &unavailable);
    assert!(fetch(&site, &target).await.is_err());
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "transport failure cannot retry directly");

    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch(&site, &target).await.unwrap(), payload("origin"));
    assert_eq!(origin.hits.lock().unwrap().len(), 2, "explicit direct policy takes effect");
}
