use super::*;
#[path = "catalog_proxy_test_support.rs"]
mod catalog_proxy_test_support;
use catalog_proxy_test_support::FixtureSite;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{sync::Arc, time::Duration};

fn headers(r: &Request) {
    assert_eq!(r.method, Method::GET);
    assert!(r.body.is_empty());
    assert_eq!(r.headers["user-agent"], UA);
    assert_eq!(r.headers["accept"], "application/json");
    assert_eq!(r.headers["connection"], "Keep-Alive");
    assert!(!r.headers.contains_key("cookie"));
    assert!(!r.headers.contains_key("authorization"));
    if r.uri.path() != "/landed" { assert_eq!(r.headers["referer"], REFERER); }
}

#[async_trait::async_trait]
impl FixtureSite for Duboku {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_json(url, "fixture").await.map(|v| v.to_string())
    }
    fn assert_headers(r: &Request) { headers(r); }
}

#[tokio::test]
async fn catalog_proxy_duboku_get_headers_redirect_gzip_and_hot_policy() {
    catalog_proxy_test_support::exercise(Duboku::new()).await;
}

async fn get(site: &Duboku, url: &str) -> Result<Value, String> {
    tokio::time::timeout(Duration::from_secs(3), site.get_json(url, "fixture"))
        .await.expect("loopback Duboku request exceeded fixture budget")
}

#[tokio::test]
async fn catalog_proxy_duboku_preserves_generated_token_query_and_error_classification() {
    // An existing DEX token vector is independent of the request helper and
    // does not use encode_token/b_plain to derive its expected bytes.
    let fixed = token_query_at(1_793_256_000_123);
    let token = fixed.split("&token=").nth(1).unwrap();
    assert_eq!(token, "YTMzM3MzkyQzUjNjN2Mwk0AjMDMjNxM2IzUzAzMgN3..");

    let generated = reqwest::Url::parse(&api_url("/vodsearch?wd=alpha%2B%20beta")).unwrap();
    let query = generated.query().unwrap().to_string();
    assert!(query.starts_with("wd=alpha%2B%20beta&sign="));
    let fields: Vec<_> = query.split('&').collect();
    assert_eq!(fields.len(), 4);
    assert_eq!(fields[1].strip_prefix("sign=").unwrap().len(), 60);
    assert_eq!(fields[2].strip_prefix("ssid=").unwrap().len(), 38);
    assert!(fields[3].starts_with("token="));
    assert_ne!(api_url("/home"), api_url("/home"), "request signing retains changing sign/ssid values");
    let origin = serve(|_| r#"{"fixture":"origin"}"#.into_response()).await;
    // Only the destination authority/scheme changes; the real API path and
    // already-generated query are copied verbatim and no public host is used.
    let target = format!("{}{}?{}", origin.url, generated.path(), query);
    let expected_query = query.clone();
    let proxy = serve(move |r| {
        headers(&r);
        assert_eq!(r.uri.scheme_str(), Some("http"));
        assert_eq!(r.uri.path(), "/vodsearch");
        assert_eq!(r.uri.query(), Some(expected_query.as_str()));
        r#"{"fixture":"proxy"}"#.into_response()
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = Duboku::new(); site.set_http_context(store.clone(), "duboku-signature");
    assert_eq!(get(&site, &target).await.unwrap()["fixture"], "proxy");
    for status in [StatusCode::BAD_REQUEST, StatusCode::EXPECTATION_FAILED] {
        let failed = serve(move |r| { headers(&r); (status, "Failure").into_response() }).await;
        custom(&store, &failed.url);
        let error = get(&site, &target).await.unwrap_err();
        assert!(error.contains(&format!("HTTP {}", status.as_u16())) && error.contains("Failure"), "{error}");
        assert!(error.contains(classify_upstream(status.as_u16(), "Failure")), "{error}");
        assert_eq!(failed.hits.lock().unwrap().len(), 1);
    }
    let malformed = serve(|_| "fixture invalid JSON".into_response()).await;
    custom(&store, &malformed.url);
    assert!(get(&site, &target).await.unwrap_err().contains("不是合法 JSON"));
    assert_eq!(malformed.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty(), "errors cannot retry directly");
}
