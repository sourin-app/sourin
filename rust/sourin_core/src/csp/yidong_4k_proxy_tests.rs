use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::{Arc, atomic::Ordering}};

#[derive(Clone, Copy)]
enum Entry { Text, Json }

fn payload(label: &str) -> String { serde_json::json!({"code":"000000","fixture":label}).to_string() }

fn assert_request(r: &Request, fprint: &str) {
    assert_eq!(r.method, Method::POST);
    assert_eq!(r.uri.query(), Some("first=alpha%2Bbeta&second=two"));
    assert_eq!(r.headers["user-agent"], UA);
    assert_eq!(r.headers["origin"], BASE);
    assert_eq!(r.headers["accept"], "application/json, text/plain, */*");
    assert_eq!(r.headers["cache-control"], "no-cache"); assert_eq!(r.headers["pragma"], "no-cache");
    assert_eq!(r.headers["content-type"], "application/json; charset=utf-8");
    if r.uri.path() == "/probe" { assert_eq!(r.headers["referer"], format!("{BASE}/vid/app/")); }
    else { assert_eq!(r.uri.path(), "/landed"); }
    assert!(!r.headers.contains_key("cookie")); assert!(!r.headers.contains_key("authorization"));
    let expected = format!(r#"{{"fprint":"{fprint}","videoId":71}}"#);
    assert_eq!(r.body.as_ref(), expected.as_bytes());
}

async fn fetch(site: &Yidong4K, target: &str, body: &Value, entry: Entry) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), async {
        match entry {
            Entry::Text => site.post_text(target, body).await,
            Entry::Json => site.post_json(target, body).await.map(|v| v.to_string()),
        }
    }).await.expect("loopback Yidong4K POST exceeded fixture budget")
}

async fn exercise(entry: Entry) {
    assert_eq!(TIMEOUT, Duration::from_secs(20));
    let site = Yidong4K::new(); assert_eq!(site.seq.load(Ordering::Relaxed), 0);
    let fprint = site.fprint(); assert_eq!(fprint.len(), 32);
    assert!(fprint.bytes().all(|b| b.is_ascii_hexdigit())); assert_eq!(site.seq.load(Ordering::Relaxed), 1);
    let body = detail_body("71", &fprint).unwrap();
    let origin_fp = fprint.clone();
    let origin = serve(move |r| { assert_request(&r, &origin_fp); payload("origin").into_response() }).await;
    let first_fp = fprint.clone();
    let first = serve(move |r| { assert_request(&r, &first_fp); assert_eq!(r.uri.scheme_str(), Some("http")); payload("first").into_response() }).await;
    let redirect = format!("{}/landed?first=alpha%2Bbeta&second=two", origin.url);
    let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    gzip.write_all(payload("second").as_bytes()).unwrap(); let compressed = gzip.finish().unwrap();
    let second_fp = fprint.clone();
    let second = serve(move |r| {
        assert_request(&r, &second_fp); assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() == "/probe" {
            (StatusCode::TEMPORARY_REDIRECT, [("location", redirect.clone()),
                ("set-cookie", "fixture=must-not-persist; Path=/".to_string())]).into_response()
        } else { ([("content-encoding", "gzip")], compressed.clone()).into_response() }
    }).await;
    let target = format!("{}/probe?first=alpha%2Bbeta&second=two", origin.url);
    assert_eq!(fetch(&site, &target, &body, entry).await.unwrap(), payload("origin"));
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    site.set_http_context(store.clone(), "yidong4k-loopback");
    assert_eq!(fetch(&site, &target, &body, entry).await.unwrap(), payload("first"));
    assert_eq!(site.seq.load(Ordering::Relaxed), 1, "binding HTTP policy retains the fingerprint sequence");
    custom(&store, &second.url); assert_eq!(fetch(&site, &target, &body, entry).await.unwrap(), payload("second"));
    assert_eq!(site.seq.load(Ordering::Relaxed), 1, "rebuilding HTTP client retains the fingerprint sequence");
    let next_fprint = site.fprint(); assert_ne!(next_fprint, fprint); assert_eq!(site.seq.load(Ordering::Relaxed), 2);
    let other = Yidong4K::new(); other.set_http_context(store.clone(), "yidong4k-other-loopback");
    assert_eq!(other.seq.load(Ordering::Relaxed), 0, "fingerprint counters stay per instance");
    assert_eq!(first.hits.lock().unwrap().len(), 1); assert_eq!(second.hits.lock().unwrap().len(), 2);
    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding.to_str().unwrap().contains("gzip"));
    for fixture in [&first, &second] { for r in fixture.hits.lock().unwrap().iter() { assert_eq!(r.headers["accept-encoding"], encoding); } }
    let rejected_fp = fprint.clone();
    let rejected = serve(move |r| { assert_request(&r, &rejected_fp); (StatusCode::BAD_GATEWAY, "fixture rejected").into_response() }).await;
    custom(&store, &rejected.url); let error = fetch(&site, &target, &body, entry).await.unwrap_err();
    assert!(error.contains("HTTP 502") && error.contains("fixture rejected"), "{error}");
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    if let Entry::Json = entry {
        let invalid_fp = fprint.clone();
        let invalid = serve(move |r| { assert_request(&r, &invalid_fp); "fixture invalid JSON".into_response() }).await;
        custom(&store, &invalid.url); assert!(fetch(&site, &target, &body, entry).await.unwrap_err().contains("不是 JSON"));
        assert_eq!(invalid.hits.lock().unwrap().len(), 1);
    }
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    custom(&store, &format!("http://{}", unused.local_addr().unwrap())); drop(unused);
    assert!(fetch(&site, &target, &body, entry).await.is_err());
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "HTTP and transport failures cannot retry directly");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch(&site, &target, &body, entry).await.unwrap(), payload("origin"));
    assert_eq!(origin.hits.lock().unwrap().len(), 2); assert_eq!(site.seq.load(Ordering::Relaxed), 2);
}

#[tokio::test]
async fn catalog_proxy_yidong4k_access_post_preserves_bytes_sequence_and_policy() { exercise(Entry::Text).await; }

#[tokio::test]
async fn catalog_proxy_yidong4k_json_post_preserves_bytes_sequence_and_policy() { exercise(Entry::Json).await; }
