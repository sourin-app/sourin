use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::Arc};

#[derive(Clone, Copy)]
enum Entry { Catalog, PlayPost }

const QUERY: &str = "first=alpha%2Bbeta&second=two";
const FORM_ID: &str = "327745 +&/";

fn payload(label: &str) -> String {
    serde_json::json!({"fixture":label}).to_string()
}

fn assert_request(request: &Request, entry: Entry) {
    assert_eq!(request.uri.query(), Some(QUERY));
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["accept"], "*/*");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    if request.uri.path() == "/probe" {
        let expected = match entry {
            Entry::Catalog => REFERER.to_string(),
            Entry::PlayPost => format!("{BASE}/play/{FORM_ID}.html"),
        };
        assert_eq!(request.headers["referer"].to_str().unwrap(), expected);
    } else {
        assert_eq!(request.uri.path(), "/landed");
        let referer = reqwest::Url::parse(request.headers["referer"].to_str().unwrap()).unwrap();
        assert_eq!(referer.host_str(), Some("127.0.0.1"));
        assert_eq!(referer.path(), "/probe");
        assert_eq!(referer.query(), Some(QUERY));
    }
    match entry {
        Entry::Catalog => {
            assert_eq!(request.method, Method::GET);
            assert!(request.body.is_empty());
            assert!(!request.headers.contains_key("content-type"));
        }
        Entry::PlayPost => {
            assert_eq!(request.method, Method::POST);
            assert_eq!(request.headers["content-type"], "application/x-www-form-urlencoded");
            assert_eq!(request.body.as_ref(), b"id=327745+%2B%26%2F");
        }
    }
}

async fn fetch(site: &Djuu, target: &str, entry: Entry) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), async {
        match entry {
            Entry::Catalog => site.get_html(target).await,
            Entry::PlayPost => site.post_play_url(target, FORM_ID).await.map(|v| v.to_string()),
        }
    }).await.expect("loopback Djuu request exceeded its fixture budget")
}

async fn exercise(entry: Entry) {
    assert_eq!(GET_TIMEOUT, Duration::from_secs(15));
    let origin = serve(move |request| {
        assert_request(&request, entry);
        payload("origin").into_response()
    }).await;
    let first = serve(move |request| {
        assert_request(&request, entry);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        payload("first proxy").into_response()
    }).await;
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(payload("second proxy gzip").as_bytes()).unwrap();
    let compressed = encoder.finish().unwrap();
    assert_eq!(&compressed[..3], &[0x1f, 0x8b, 0x08]);
    let redirect = format!("{}/landed?{QUERY}", origin.url);
    let second = serve(move |request| {
        assert_request(&request, entry);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/probe" {
            (StatusCode::TEMPORARY_REDIRECT, [
                ("location", redirect.clone()),
                ("set-cookie", "fixture=must-not-persist; Path=/".to_string()),
            ]).into_response()
        } else {
            ([("content-type", "application/json"), ("content-encoding", "gzip")], compressed.clone()).into_response()
        }
    }).await;
    let target = format!("{}/probe?{QUERY}", origin.url);
    let site = Djuu::new();
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), payload("origin"));
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "djuu-fixture");
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), payload("first proxy"));
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    custom(&store, &second.url);
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), payload("second proxy gzip"));
    assert_eq!(second.hits.lock().unwrap().len(), 2, "redirect retains the method/body and proxy");
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding.to_str().unwrap().split(',').any(|v| v.trim() == "gzip"));
    for proxy in [&first, &second] {
        for request in proxy.hits.lock().unwrap().iter() {
            assert_eq!(request.headers["accept-encoding"], encoding);
        }
    }
    let rejected = serve(move |request| {
        assert_request(&request, entry);
        (StatusCode::BAD_GATEWAY, "fixture rejection").into_response()
    }).await;
    custom(&store, &rejected.url);
    let error = fetch(&site, &target, entry).await.unwrap_err();
    assert!(error.contains("HTTP 502") && error.contains("fixture rejection"), "{error}");
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "HTTP failure cannot retry directly");
    if let Entry::PlayPost = entry {
        let invalid = serve(move |request| {
            assert_request(&request, entry);
            "fixture invalid JSON".into_response()
        }).await;
        custom(&store, &invalid.url);
        let error = fetch(&site, &target, entry).await.unwrap_err();
        assert!(error.contains("不是合法 JSON") && error.contains("fixture invalid JSON"), "{error}");
        assert_eq!(invalid.hits.lock().unwrap().len(), 1);
        assert_eq!(origin.hits.lock().unwrap().len(), 1);
    }
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    custom(&store, &unavailable);
    assert!(fetch(&site, &target, entry).await.is_err());
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "transport failure cannot retry directly");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), payload("origin"));
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn catalog_proxy_djuu_real_catalog_get_preserves_policy_and_headers() {
    exercise(Entry::Catalog).await;
}

#[tokio::test]
async fn catalog_proxy_djuu_real_play_post_preserves_form_and_policy() {
    exercise(Entry::PlayPost).await;
}
