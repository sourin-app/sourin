use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::Arc};

#[derive(Clone, Copy)]
enum Entry { Text, JsonCookie }

const QUERY: &str = "first=alpha%2Bbeta&second=two";
const COOKIE: &str = "fixture_session=alpha%2Bbeta; fixture_device=two";

fn payload(label: &str) -> String {
    serde_json::json!({"fixture":label}).to_string()
}

fn assert_request(request: &Request, entry: Entry) {
    assert_eq!(request.uri.query(), Some(QUERY));
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["accept"], "application/json, text/plain, */*");
    match entry {
        Entry::Text => assert!(!request.headers.contains_key("cookie")),
        Entry::JsonCookie => assert_eq!(request.headers["cookie"], COOKIE),
    }
    assert!(!request.headers.contains_key("authorization"));
    if request.uri.path() == "/probe" {
        let expected = REFERER.to_string();
        assert_eq!(request.headers["referer"].to_str().unwrap(), expected);
    } else {
        assert_eq!(request.uri.path(), "/landed");
        let referer = reqwest::Url::parse(request.headers["referer"].to_str().unwrap()).unwrap();
        assert_eq!(referer.host_str(), Some("127.0.0.1"));
        assert_eq!(referer.path(), "/probe");
        assert_eq!(referer.query(), Some(QUERY));
    }
    assert_eq!(request.method, Method::GET);
    assert!(request.body.is_empty());
    assert!(!request.headers.contains_key("content-type"));
}

async fn fetch(site: &BiliYS, target: &str, entry: Entry) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), async {
        match entry {
            Entry::Text => site.get_text(target).await,
            Entry::JsonCookie => site.get_json(target, Some(COOKIE)).await.map(|v| v.to_string()),
        }
    }).await.expect("loopback BiliYS request exceeded its fixture budget")
}

async fn exercise(entry: Entry) {
    assert_eq!(TIMEOUT, Duration::from_secs(15));
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
    let site = BiliYS::new();
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), payload("origin"));
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "biliys-fixture");
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
    if let Entry::JsonCookie = entry {
        let invalid = serve(move |request| {
            assert_request(&request, entry);
            "fixture invalid JSON".into_response()
        }).await;
        custom(&store, &invalid.url);
        let error = fetch(&site, &target, entry).await.unwrap_err();
        assert!(error.contains("不是 JSON") && error.contains("fixture invalid JSON"), "{error}");
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
async fn catalog_proxy_biliys_real_cookie_text_get_preserves_policy_and_headers() {
    exercise(Entry::Text).await;
}

#[tokio::test]
async fn catalog_proxy_biliys_real_json_get_preserves_explicit_cookie_and_policy() {
    exercise(Entry::JsonCookie).await;
}

fn assert_cache_request(request: &Request, cookie: Option<&str>) {
    assert_eq!(request.uri.scheme_str(), Some("http"));
    assert_eq!(request.method, Method::GET);
    assert!(request.body.is_empty());
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["referer"], REFERER);
    assert_eq!(request.headers["accept"], "application/json, text/plain, */*");
    assert!(!request.headers.contains_key("authorization"));
    match cookie {
        Some(cookie) => assert_eq!(request.headers["cookie"].to_str().unwrap(), cookie),
        None => assert!(!request.headers.contains_key("cookie")),
    }
}

async fn cookie_fixture(site: &BiliYS, ext: &str) -> Option<String> {
    tokio::time::timeout(Duration::from_secs(3), site.cookie(ext))
        .await.expect("loopback cookie resolution exceeded its fixture budget")
}

async fn json_fixture(site: &BiliYS, url: &str, cookie: Option<&str>) -> String {
    tokio::time::timeout(Duration::from_secs(3), site.get_json(url, cookie))
        .await.expect("loopback JSON request exceeded its fixture budget")
        .unwrap()["fixture"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn catalog_proxy_biliys_cookie_cache_survives_hot_change_and_stays_per_instance() {
    const FIRST_COOKIE: &str = "fixture_session=first; fixture_device=one";
    const SECOND_COOKIE: &str = "fixture_session=second; fixture_device=two";
    let origin = serve(|_| "fixture_session=unexpected-direct".into_response()).await;
    let first = serve(|request| {
        assert_eq!(request.uri.path(), "/cookie.txt");
        assert_eq!(request.uri.query(), Some("first=alpha%2Bbeta&second=two"));
        assert_cache_request(&request, None);
        ([ ("set-cookie", "automatic=must-not-persist; Path=/") ], format!("  {FIRST_COOKIE}\n")).into_response()
    }).await;
    let second = serve(|request| {
        match request.uri.path() {
            "/cookie.txt" => {
                assert_cache_request(&request, None);
                SECOND_COOKIE.into_response()
            }
            "/api" => {
                assert_cache_request(&request, Some(FIRST_COOKIE));
                payload("first cached identity through second proxy").into_response()
            }
            "/other-api" => {
                assert_cache_request(&request, Some(SECOND_COOKIE));
                payload("second independent identity").into_response()
            }
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    let site = BiliYS::new();
    site.set_http_context(store.clone(), "biliys-first-cache-fixture");
    let ext = serde_json::json!({"cookie":format!("{}/cookie.txt?{QUERY}", origin.url)}).to_string();
    let cookie = cookie_fixture(&site, &ext).await;
    assert_eq!(cookie.as_deref(), Some(FIRST_COOKIE), "HTTP cookie text is trimmed and cached");
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty());

    custom(&store, &second.url);
    assert_eq!(json_fixture(&site, &format!("{}/api", origin.url), cookie.as_deref()).await,
        "first cached identity through second proxy");
    assert_eq!(second.hits.lock().unwrap().len(), 1, "a real request triggers client rebuilding");
    assert_eq!(cookie_fixture(&site, &ext).await.as_deref(), Some(FIRST_COOKIE));
    assert_eq!(second.hits.lock().unwrap().len(), 1, "rebuilding the HTTP client cannot refetch cached cookie text");

    let other = BiliYS::new();
    other.set_http_context(store, "biliys-second-cache-fixture");
    let other_cookie = cookie_fixture(&other, &ext).await;
    assert_eq!(other_cookie.as_deref(), Some(SECOND_COOKIE));
    assert_eq!(second.hits.lock().unwrap().len(), 2, "another site resolves its own cookie");
    assert_eq!(json_fixture(&other, &format!("{}/other-api", origin.url), other_cookie.as_deref()).await,
        "second independent identity");
    let cached = cookie_fixture(&site, &ext).await;
    assert_eq!(cached.as_deref(), Some(FIRST_COOKIE));
    assert_eq!(json_fixture(&site, &format!("{}/api", origin.url), cached.as_deref()).await,
        "first cached identity through second proxy");
    assert_eq!(second.hits.lock().unwrap().len(), 4);
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn catalog_proxy_biliys_failed_cookie_cache_survives_hot_change_without_direct_retry() {
    const NEW_COOKIE: &str = "fixture_session=new-instance";
    let origin = serve(|_| "fixture_session=unexpected-direct".into_response()).await;
    let rejected = serve(|request| {
        assert_eq!(request.uri.path(), "/cookie.txt");
        assert_cache_request(&request, None);
        (StatusCode::BAD_GATEWAY, "cookie file unavailable").into_response()
    }).await;
    let second = serve(|request| {
        match request.uri.path() {
            "/cookie.txt" => {
                assert_cache_request(&request, None);
                NEW_COOKIE.into_response()
            }
            "/api" => {
                assert_cache_request(&request, None);
                payload("anonymous after hot change").into_response()
            }
            "/other-api" => {
                assert_cache_request(&request, Some(NEW_COOKIE));
                payload("new instance can resolve cookie").into_response()
            }
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &rejected.url);
    let site = BiliYS::new();
    site.set_http_context(store.clone(), "biliys-negative-cache-fixture");
    let ext = serde_json::json!({"cookie":format!("{}/cookie.txt", origin.url)}).to_string();
    assert_eq!(cookie_fixture(&site, &ext).await, None);
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty(), "cookie failure may become anonymous, never a direct retry");

    custom(&store, &second.url);
    assert_eq!(json_fixture(&site, &format!("{}/api", origin.url), None).await, "anonymous after hot change");
    assert_eq!(cookie_fixture(&site, &ext).await, None);
    assert_eq!(second.hits.lock().unwrap().len(), 1, "Some(None) remains cached through client rebuilding");
    let other = BiliYS::new();
    other.set_http_context(store, "biliys-negative-cache-other-fixture");
    let cookie = cookie_fixture(&other, &ext).await;
    assert_eq!(cookie.as_deref(), Some(NEW_COOKIE));
    assert_eq!(json_fixture(&other, &format!("{}/other-api", origin.url), cookie.as_deref()).await,
        "new instance can resolve cookie");
    assert_eq!(second.hits.lock().unwrap().len(), 3);
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty());
}
