use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{sync::Arc, time::Duration};

#[path = "catalog_proxy_test_support.rs"]
mod contract;

fn assert_headers(r: &Request) {
    assert_eq!(r.method, Method::GET); assert!(r.body.is_empty());
    assert_eq!(r.headers["user-agent"], UA); assert_eq!(r.headers["accept"], ACCEPT);
    if r.uri.path() != "/landed" { assert_eq!(r.headers["referer"], REFERER); }
    assert!(!r.headers.contains_key("cookie")); assert!(!r.headers.contains_key("authorization"));
    assert!(!r.headers.contains_key("content-type"));
}

#[async_trait::async_trait]
impl contract::FixtureSite for Web1905 {
    async fn fetch(&self, url: &str) -> Result<String, String> { self.get(url).await }
    fn assert_headers(r: &Request) { assert_headers(r); }
}

#[tokio::test]
async fn catalog_proxy_web1905_real_get_preserves_headers_and_policy() {
    contract::exercise(Web1905::new()).await;
}

// SHA-1 independently computed from the fixed protocol string with .NET SHA1.
const SIGNATURE: &str = "80aeeb32f33bd978d02252250ca65f927adeb332";
const QUERY: &str = "nonce=1700000000000&expiretime=1700000600000&cid=1104007&uuid=ABCDEF0123456789ABCD.dde3d61a0411511d&playerid=ABCDEF0123456789ABCD&page=https%3A%2F%2Fwww.1905.com%2Fvod%2Fplay%2F1104007.shtml&type=hls&signature=80aeeb32f33bd978d02252250ca65f927adeb332&callback=cbfixture";

fn assert_signed_request(r: &Request) {
    assert_headers(r); assert_eq!(r.uri.path(), "/mvod/getVideoinfo.php");
    assert_eq!(r.uri.query(), Some(QUERY), "proxy changes may not rewrite the encoded signature query");
}

fn signed_payload(label: &str) -> String {
    let value = serde_json::json!({"StatusCode":200,"data":{"sign":{"hd":"fixture"},
        "quality":{"hd":{"host":"http://127.0.0.1/","path":format!("{label}.m3u8")}}}});
    format!("cbfixture({value})")
}

async fn fetch_signed(site: &Web1905, target: &str) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), async {
        let raw = site.get(target).await?;
        let value: Value = serde_json::from_str(&strip_jsonp(&raw)).map_err(|e| e.to_string())?;
        if let Some(error) = play_status_error(&value) { return Err(error); }
        play_url_from(&value)
    }).await.expect("loopback Web1905 signed GET exceeded fixture budget")
}

#[tokio::test]
async fn catalog_proxy_web1905_signed_query_and_waf_errors_survive_hot_policy() {
    let source = sign_source("1104007", 1_700_000_000_000, "ABCDEF0123456789ABCD", &play_page_of("1104007"));
    assert_eq!(sha1_hex(&source), SIGNATURE);
    let original = playinfo_url("1104007", 1_700_000_000_000, "ABCDEF0123456789ABCD", SIGNATURE, "cbfixture");
    assert_eq!(original, format!("{PROFILE}/mvod/getVideoinfo.php?{QUERY}"));
    let origin = serve(|r| { assert_signed_request(&r); signed_payload("origin").into_response() }).await;
    // Only the destination authority changes. The production URL query remains byte-identical.
    let target = format!("{}{}", origin.url, original.strip_prefix(PROFILE).unwrap());
    let first = serve(|r| { assert_signed_request(&r); assert_eq!(r.uri.scheme_str(), Some("http")); signed_payload("first").into_response() }).await;
    let second = serve(|r| { assert_signed_request(&r); assert_eq!(r.uri.scheme_str(), Some("http")); signed_payload("second").into_response() }).await;
    let site = Web1905::new(); assert_eq!(fetch_signed(&site, &target).await.unwrap(), "http://127.0.0.1/origin.m3u8");
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    site.set_http_context(store.clone(), "web1905-signature-loopback");
    assert_eq!(fetch_signed(&site, &target).await.unwrap(), "http://127.0.0.1/first.m3u8");
    custom(&store, &second.url); assert_eq!(fetch_signed(&site, &target).await.unwrap(), "http://127.0.0.1/second.m3u8");
    assert_eq!(first.hits.lock().unwrap().len(), 1); assert_eq!(second.hits.lock().unwrap().len(), 1);
    let waf = serve(|r| {
        assert_signed_request(&r);
        (StatusCode::FORBIDDEN, [("ws-action", "bot")], "fixture Embed Iframe ws_sec_page.js").into_response()
    }).await;
    custom(&store, &waf.url); let error = fetch_signed(&site, &target).await.unwrap_err();
    assert!(error.contains("HTTP 403") && error.contains("WAF") && error.contains("bot") && error.contains("fixture Embed Iframe"), "{error}");
    assert_eq!(waf.hits.lock().unwrap().len(), 1);
    let rejected = serve(|r| { assert_signed_request(&r); r#"cbfixture({"StatusCode":403,"info":"fixture signature rejected","data":""})"#.into_response() }).await;
    custom(&store, &rejected.url); let error = fetch_signed(&site, &target).await.unwrap_err();
    assert!(error.contains("StatusCode=403") && error.contains("fixture signature rejected"), "{error}");
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    custom(&store, &format!("http://{}", unused.local_addr().unwrap())); drop(unused);
    assert!(fetch_signed(&site, &target).await.is_err());
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "WAF, business and transport failures cannot retry directly");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch_signed(&site, &target).await.unwrap(), "http://127.0.0.1/origin.m3u8");
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
}
