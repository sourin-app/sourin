use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::Arc};

#[derive(Clone, Copy)]
enum Entry {
    Graphql,
    Detail,
}

fn fixture_query() -> String {
    search_query("fixture \"quoted\" \\ path", 2)
}

fn payload(label: &str) -> String {
    serde_json::json!({"fixture":label,"album":{"id":"9","title":label,"cover":"http://127.0.0.1/cover.png","description":"fixture description"}}).to_string()
}

fn assert_request(request: &Request, entry: Entry) {
    assert_eq!(request.uri.query(), Some("first=alpha%2Bbeta&second=two"));
    assert_eq!(request.headers["user-agent"], UA);
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    assert!(!request.headers.contains_key("accept-language"));
    if request.uri.path() == "/probe" {
        assert_eq!(request.headers["referer"], BASE);
    }
    match entry {
        Entry::Graphql => {
            assert_eq!(request.method, Method::POST);
            assert_eq!(request.headers["accept"], "application/json, text/plain, */*");
            assert_eq!(request.headers["content-type"], "application/json");
            assert_eq!(request.body.as_ref(), serde_json::json!({"query":fixture_query()}).to_string().as_bytes());
        }
        Entry::Detail => {
            assert_eq!(request.method, Method::GET);
            assert_eq!(request.headers["accept"], "*/*");
            assert!(!request.headers.contains_key("content-type"));
            assert!(request.body.is_empty());
        }
    }
}

async fn fetch(site: &QingtingFM, target: &str, entry: Entry) -> Result<String, String> {
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        match entry {
            Entry::Graphql => site.graphql_url(target, &fixture_query()).await
                .map(|value| value["fixture"].as_str().unwrap().to_string()),
            Entry::Detail => site.detail_url(target, "9").await.map(|detail| {
                assert_eq!(detail.id, "9");
                assert_eq!(detail.cover.as_deref(), Some("http://127.0.0.1/cover.png"));
                assert_eq!(detail.description.as_deref(), Some("fixture description"));
                assert_eq!(detail.episodes.len(), 1);
                assert_eq!(detail.episodes[0].id, "9");
                assert_eq!(detail.episodes[0].title, detail.title);
                assert_eq!(detail.episodes[0].flag, "蜻蜓FM");
                detail.title
            }),
        }
    }).await.expect("loopback Qingting request exceeded its fixture budget")
}

async fn exercise(entry: Entry) {
    let origin = serve(move |request| {
        assert_request(&request, entry);
        payload("origin").into_response()
    }).await;
    let first = serve(move |request| {
        assert_request(&request, entry);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        payload("first").into_response()
    }).await;
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(payload("second").as_bytes()).unwrap();
    let compressed = encoder.finish().unwrap();
    let redirect = format!("{}/landed?first=alpha%2Bbeta&second=two", origin.url);
    let second = serve(move |request| {
        assert_request(&request, entry);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/probe" {
            (StatusCode::TEMPORARY_REDIRECT, [("location", redirect.clone()), ("set-cookie", "fixture=must-not-persist; Path=/".to_string())]).into_response()
        } else {
            assert_eq!(request.uri.path(), "/landed");
            ([("content-type", "application/json"), ("content-encoding", "gzip")], compressed.clone()).into_response()
        }
    }).await;
    let target = format!("{}/probe?first=alpha%2Bbeta&second=two", origin.url);
    let site = QingtingFM::new();
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), "origin");
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "qingting-fixture");
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), "first");
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    custom(&store, &second.url);
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), "second");
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
        (StatusCode::BAD_GATEWAY, "fixture rejection", "HTTP 502"),
        (StatusCode::OK, "fixture invalid JSON", "不是 JSON"),
    ] {
        let rejected = serve(move |request| {
            assert_request(&request, entry);
            (status, body).into_response()
        }).await;
        custom(&store, &rejected.url);
        let error = fetch(&site, &target, entry).await.unwrap_err();
        assert!(error.contains(expected), "{error}");
        assert!(error.contains(body), "{error}");
        assert_eq!(rejected.hits.lock().unwrap().len(), 1);
        assert_eq!(origin.hits.lock().unwrap().len(), 1);
    }
    if let Entry::Detail = entry {
        let missing_album = serve(|_| "{}".into_response()).await;
        custom(&store, &missing_album.url);
        assert!(fetch(&site, &target, entry).await.unwrap_err().contains("详情里没有 album"));
        assert_eq!(missing_album.hits.lock().unwrap().len(), 1);
        assert_eq!(origin.hits.lock().unwrap().len(), 1);
    }
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    custom(&store, &unavailable);
    assert!(fetch(&site, &target, entry).await.unwrap_err().contains("请求失败"));
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), "origin");
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn global_proxy_catalog_v3_qingting_routes_graphql_body_and_errors() {
    exercise(Entry::Graphql).await;
}

#[tokio::test]
async fn global_proxy_catalog_v3_qingting_routes_detail_get_and_errors() {
    exercise(Entry::Detail).await;
}
