use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::{Arc, Mutex}};

const PATH: &str = "/v2/api/vodInfo/playUrl?first=alpha%2Bbeta&second=two";
const KEYWORD: &str = "quoted\"\\line\n+&";

fn extras() -> Vec<(String, String)> {
    vec![("vodId".into(), "71 +&/".into()), ("epId".into(), "3".into()),
        ("vodResolution".into(), "2".into()), ("keyword".into(), KEYWORD.into())]
}

fn assert_body(body: &[u8]) -> String {
    use md5::{Digest, Md5};
    let value: Value = serde_json::from_slice(body).unwrap();
    let id = value["requestId"].as_str().unwrap();
    assert_eq!(id.len(), 36);
    assert_eq!(&id[14..15], "4");
    for (i, b) in id.bytes().enumerate() {
        if matches!(i, 8 | 13 | 18 | 23) { assert_eq!(b, b'-'); }
        else { assert!(b.is_ascii_hexdigit()); }
    }
    // Independent fixed key order and raw values; do not call app_sign or common_pairs.
    let source = format!("appId=e6ddefe09e0349739874563459f56c54&cus1tom=aabbcc&deviceInfo=Android&epId=3&keyword={KEYWORD}&reqDomain=yqk1.app&requestId={id}&udid=0123456789abcdef&version=1.2.7.104&vodId=71 +&/&vodResolution=2&appKey=3359de478f8d45638125e446a10ec541");
    let signature = format!("{:x}", Md5::digest(source.as_bytes()));
    let expected = format!(r#"{{"appId":"e6ddefe09e0349739874563459f56c54","cus1tom":"aabbcc","deviceInfo":"Android","epId":"3","keyword":"quoted\"\\line\n+&","reqDomain":"yqk1.app","requestId":"{id}","sign":"{signature}","udid":"0123456789abcdef","version":"1.2.7.104","vodId":"71 +&/","vodResolution":"2"}}"#);
    assert_eq!(body, expected.as_bytes(), "signed JSON must preserve exact serialized bytes");
    id.to_string()
}

fn assert_request(r: &Request) {
    assert_eq!(r.method, Method::POST);
    assert_eq!(r.uri.query(), Some("first=alpha%2Bbeta&second=two"));
    assert_eq!(r.headers["user-agent"], UA);
    assert_eq!(r.headers["accept"], "*/*");
    assert_eq!(r.headers["content-type"], "application/json");
    assert_eq!(r.headers["origin"], ORIGIN);
    if r.uri.path() != "/landed" { assert_eq!(r.headers["referer"], ORIGIN); }
    assert!(!r.headers.contains_key("cookie")); assert!(!r.headers.contains_key("authorization"));
    assert!(!r.headers.contains_key("sign")); assert_body(&r.body);
}

fn payload(label: &str) -> String { serde_json::json!({"result":true,"fixture":label}).to_string() }

async fn fetch(site: &AppYQK, base: &str) -> Result<Value, String> {
    tokio::time::timeout(Duration::from_secs(3), site.post_at(base, PATH, &extras()))
        .await.expect("loopback AppYQK request exceeded fixture budget")
}

#[tokio::test]
async fn catalog_proxy_appyqk_signed_post_preserves_bytes_and_hot_policy() {
    assert_eq!(TIMEOUT, Duration::from_secs(20)); assert_eq!(RETRIES, 3);
    let origin = serve(|r| { assert_request(&r); payload("origin").into_response() }).await;
    let first = serve(|r| { assert_request(&r); assert_eq!(r.uri.scheme_str(), Some("http")); payload("first").into_response() }).await;
    let redirect = format!("{}/landed?first=alpha%2Bbeta&second=two", origin.url);
    let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    gzip.write_all(payload("second").as_bytes()).unwrap(); let compressed = gzip.finish().unwrap();
    let second = serve(move |r| {
        assert_request(&r); assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() != "/landed" {
            (StatusCode::TEMPORARY_REDIRECT, [("location", redirect.clone()),
                ("set-cookie", "fixture=must-not-persist; Path=/".to_string())]).into_response()
        } else { ([("content-encoding", "gzip")], compressed.clone()).into_response() }
    }).await;
    let site = AppYQK::new(); assert_eq!(fetch(&site, &origin.url).await.unwrap()["fixture"], "origin");
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    site.set_http_context(store.clone(), "appyqk-loopback");
    assert_eq!(fetch(&site, &origin.url).await.unwrap()["fixture"], "first");
    custom(&store, &second.url); assert_eq!(fetch(&site, &origin.url).await.unwrap()["fixture"], "second");
    let direct = origin.hits.lock().unwrap().clone(); let first_hits = first.hits.lock().unwrap().clone();
    let second_hits = second.hits.lock().unwrap().clone();
    assert_eq!((direct.len(), first_hits.len(), second_hits.len()), (1, 1, 2));
    assert_ne!(assert_body(&direct[0].body), assert_body(&first_hits[0].body));
    assert_ne!(assert_body(&first_hits[0].body), assert_body(&second_hits[0].body));
    assert_eq!(second_hits[0].body, second_hits[1].body, "redirect reuses the signed requestId and body");
    let encoding = &direct[0].headers["accept-encoding"]; assert!(encoding.to_str().unwrap().contains("gzip"));
    for r in first_hits.iter().chain(second_hits.iter()) { assert_eq!(&r.headers["accept-encoding"], encoding); }
    let rejected = serve(|r| { assert_request(&r); (StatusCode::BAD_GATEWAY, "fixture rejected").into_response() }).await;
    custom(&store, &rejected.url); let error = fetch(&site, &origin.url).await.unwrap_err();
    assert!(error.contains("HTTP 502") && error.contains("fixture rejected"), "{error}");
    assert_eq!(rejected.hits.lock().unwrap().len(), 1, "HTTP errors are never transport retries");
    let invalid = serve(|r| { assert_request(&r); "fixture invalid JSON".into_response() }).await;
    custom(&store, &invalid.url); assert!(fetch(&site, &origin.url).await.unwrap_err().contains("不是 JSON"));
    assert_eq!(invalid.hits.lock().unwrap().len(), 1);
    let business = serve(|r| { assert_request(&r); r#"{"result":false,"msg":"fixture sign error"}"#.into_response() }).await;
    custom(&store, &business.url); let value = fetch(&site, &origin.url).await.unwrap();
    assert!(AppYQK::ensure_ok("fixture", &value).unwrap_err().contains("fixture sign error"));
    assert_eq!(business.hits.lock().unwrap().len(), 1, "business failures cannot be retried");
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "failed proxy requests cannot retry directly");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch(&site, &origin.url).await.unwrap()["fixture"], "origin");
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
}

struct DisconnectProxy {
    url: String,
    requests: Arc<Mutex<Vec<Request>>>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for DisconnectProxy { fn drop(&mut self) { self.task.abort(); } }

async fn disconnect_proxy() -> DisconnectProxy {
    use tokio::io::AsyncReadExt;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let requests = Arc::new(Mutex::new(Vec::new())); let captured = requests.clone();
    let task = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap(); let mut raw = Vec::new();
            let header_end = loop {
                let mut chunk = [0; 4096]; let n = socket.read(&mut chunk).await.unwrap(); assert!(n > 0);
                raw.extend_from_slice(&chunk[..n]);
                if let Some(p) = raw.windows(4).position(|v| v == b"\r\n\r\n") { break p + 4; }
                assert!(raw.len() < 32768);
            };
            let header_text = std::str::from_utf8(&raw[..header_end]).unwrap();
            let mut lines = header_text.split("\r\n"); let first = lines.next().unwrap();
            let mut parts = first.split_whitespace(); let method = parts.next().unwrap().parse().unwrap();
            let uri = parts.next().unwrap().parse().unwrap(); let mut headers = axum::http::HeaderMap::new();
            for line in lines.filter(|line| !line.is_empty()) {
                let (key, value) = line.split_once(':').unwrap();
                headers.insert(axum::http::HeaderName::from_bytes(key.as_bytes()).unwrap(), value.trim().parse().unwrap());
            }
            let length = headers["content-length"].to_str().unwrap().parse::<usize>().unwrap();
            while raw.len() < header_end + length {
                let mut chunk = [0; 4096]; let n = socket.read(&mut chunk).await.unwrap(); assert!(n > 0);
                raw.extend_from_slice(&chunk[..n]);
            }
            captured.lock().unwrap().push(Request { method, uri, headers,
                body: bytes::Bytes::copy_from_slice(&raw[header_end..header_end + length]) });
            // Close after reading the POST, before sending any response headers.
        }
    });
    DisconnectProxy { url, requests, task }
}

#[tokio::test]
async fn catalog_proxy_appyqk_transport_retries_keep_signed_body_without_direct_retry() {
    let origin = serve(|_| payload("unexpected direct").into_response()).await;
    let broken = disconnect_proxy().await; let site = AppYQK::new();
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &broken.url);
    site.set_http_context(store.clone(), "appyqk-retry-loopback");
    let error = fetch(&site, &origin.url).await.unwrap_err(); assert!(error.contains("第 3/3 次"), "{error}");
    let requests = broken.requests.lock().unwrap().clone(); assert_eq!(requests.len(), 3);
    for r in &requests { assert_request(r); assert_eq!(r.uri.scheme_str(), Some("http")); assert_eq!(r.body, requests[0].body); }
    assert!(origin.hits.lock().unwrap().is_empty());
    let second = serve(|r| { assert_request(&r); payload("second").into_response() }).await;
    custom(&store, &second.url); assert_eq!(fetch(&site, &origin.url).await.unwrap()["fixture"], "second");
    assert_ne!(assert_body(&requests[0].body), assert_body(&second.hits.lock().unwrap()[0].body));
    assert_eq!(second.hits.lock().unwrap().len(), 1); assert!(origin.hits.lock().unwrap().is_empty());
}
