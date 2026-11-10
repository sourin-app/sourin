use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::Arc};

const PATH: &str = "/probe?first=alpha%2Bbeta&second=two";

fn payload(label: &str) -> String {
    serde_json::json!({"rescode":0,"fixture":label}).to_string()
}

fn assert_request(request: &Request) {
    assert_eq!(request.method, Method::GET);
    assert_eq!(request.uri.query(), Some("first=alpha%2Bbeta&second=two"));
    assert!(request.body.is_empty());
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["app"], APP_ID);
    assert_eq!(request.headers["accept"], "*/*");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    assert!(!request.headers.contains_key("accept-language"));
    if request.uri.path() == "/probe" {
        assert!(!request.headers.contains_key("referer"));
    }
}

async fn fetch(site: &Hxq, target: &str) -> Result<Value, String> {
    tokio::time::timeout(Duration::from_secs(3), site.get_json_url(target, PATH))
        .await.expect("loopback Hxq request exceeded its fixture budget")
}

#[tokio::test]
async fn global_proxy_catalog_v3_hxq_routes_real_json_helper_and_business_errors() {
    let origin = serve(|request| {
        assert_request(&request);
        payload("origin").into_response()
    }).await;
    let first = serve(|request| {
        assert_request(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        payload("first").into_response()
    }).await;
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(payload("second").as_bytes()).unwrap();
    let compressed = encoder.finish().unwrap();
    let redirect = format!("{}/landed?first=alpha%2Bbeta&second=two", origin.url);
    let second = serve(move |request| {
        assert_request(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/probe" {
            (StatusCode::FOUND, [("location", redirect.clone()), ("set-cookie", "fixture=must-not-persist; Path=/".to_string())]).into_response()
        } else {
            assert_eq!(request.uri.path(), "/landed");
            ([("content-type", "application/json"), ("content-encoding", "gzip")], compressed.clone()).into_response()
        }
    }).await;
    let target = format!("{}{PATH}", origin.url);
    let site = Hxq::new();
    assert_eq!(fetch(&site, &target).await.unwrap()["fixture"], "origin");
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "hxq-json-fixture");
    assert_eq!(fetch(&site, &target).await.unwrap()["fixture"], "first");
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    custom(&store, &second.url);
    assert_eq!(fetch(&site, &target).await.unwrap()["fixture"], "second");
    assert_eq!(second.hits.lock().unwrap().len(), 2);
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding.to_str().unwrap().contains("gzip"));
    for proxy in [&first, &second] {
        for request in proxy.hits.lock().unwrap().iter() {
            assert_eq!(request.headers["accept-encoding"], encoding);
        }
    }

    for (status, body, expected) in [
        (StatusCode::BAD_GATEWAY, "fixture rejection", "返回 HTTP 502"),
        (StatusCode::OK, "fixture invalid JSON", "不是 JSON"),
        (StatusCode::OK, r#"{"rescode":-2,"errmsg":"fixture bad params"}"#, "上游 rescode=-2：fixture bad params"),
        (StatusCode::OK, r#"{"fixture":"missing rescode"}"#, "响应没有 rescode 字段"),
    ] {
        let rejected = serve(move |request| {
            assert_request(&request);
            (status, body).into_response()
        }).await;
        custom(&store, &rejected.url);
        let error = fetch(&site, &target).await.unwrap_err();
        assert!(error.contains(PATH), "{error}");
        assert!(error.contains(expected), "{error}");
        assert_eq!(rejected.hits.lock().unwrap().len(), 1);
        assert_eq!(origin.hits.lock().unwrap().len(), 1, "failed proxy response must not retry origin");
    }
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    custom(&store, &unavailable);
    assert!(fetch(&site, &target).await.unwrap_err().contains("请求"));
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch(&site, &target).await.unwrap()["fixture"], "origin");
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
}
