use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::Arc, time::Duration};

#[derive(Clone, Copy)]
enum Entry { Form, DormantAppui }

fn request(r: &Request, entry: Entry) {
    assert_eq!(r.method, Method::POST); assert_eq!(r.uri.query(), Some("osbranch=a0"));
    assert_eq!(r.headers["user-agent"], UA); assert_eq!(r.headers["cookie"], COOKIE);
    assert_eq!(r.headers["talos-module-version"], "1.0.71.1");
    assert_eq!(r.headers["talos-module-name"], "shortDrama");
    assert!(!r.headers.contains_key("authorization"));
    match entry {
        Entry::Form => {
            assert_eq!(r.headers["content-type"], "application/x-www-form-urlencoded");
            assert_eq!(r.body.as_ref(), b"video%2Fcommonlist=&id=71+%2B%26%2F&from=feed");
        }
        Entry::DormantAppui => {
            assert_eq!(r.headers["content-type"], "application/x-www-form-urlencoded; charset=utf-8");
            assert_eq!(r.body.as_ref(), b"video/commonlist=&id=71%20%2B%26%2F&from=feed%20%2B%26%2F");
        }
    }
}

async fn fetch(site: &ShortHaokan, target: &str, entry: Entry) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), async {
        let value = match entry {
            Entry::Form => site.post_form(target, &[("video/commonlist", ""), ("id", "71 +&/"), ("from", "feed")]).await?,
            Entry::DormantAppui => site.post_appui_url(target, "video/commonlist", "71 +&/", &[("from", "feed +&/")]).await?,
        };
        Ok(value["fixture"].as_str().unwrap().to_string())
    }).await.expect("loopback ShortHaokan helper exceeded fixture budget")
}

fn payload(label: &str) -> String { serde_json::json!({"fixture":label}).to_string() }

async fn exercise(entry: Entry) {
    assert_eq!(POST_TIMEOUT, Duration::from_secs(20));
    let origin = serve(move |r| { request(&r, entry); payload("origin").into_response() }).await;
    let first = serve(move |r| { request(&r, entry); assert_eq!(r.uri.scheme_str(), Some("http")); payload("first").into_response() }).await;
    let redirect = format!("{}/landed?osbranch=a0", origin.url);
    let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    gzip.write_all(payload("second").as_bytes()).unwrap(); let compressed = gzip.finish().unwrap();
    let second = serve(move |r| {
        request(&r, entry); assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() == "/probe" {
            (StatusCode::TEMPORARY_REDIRECT, [("location", redirect.clone()),
                ("set-cookie", "fixture=must-not-replace-static-cookie; Path=/".into())]).into_response()
        } else { assert_eq!(r.uri.path(), "/landed"); ([("content-encoding", "gzip")], compressed.clone()).into_response() }
    }).await;
    let target = format!("{}/probe?osbranch=a0", origin.url); let site = ShortHaokan::new();
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), "origin");
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    site.set_http_context(store.clone(), "haokan-loopback"); assert_eq!(fetch(&site, &target, entry).await.unwrap(), "first");
    custom(&store, &second.url); assert_eq!(fetch(&site, &target, entry).await.unwrap(), "second");
    assert_eq!(first.hits.lock().unwrap().len(), 1); assert_eq!(second.hits.lock().unwrap().len(), 2);
    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding.to_str().unwrap().contains("gzip"));
    for fixture in [&first, &second] { for r in fixture.hits.lock().unwrap().iter() { assert_eq!(r.headers["accept-encoding"], encoding); } }
    for (status, body, expected) in [(StatusCode::BAD_GATEWAY, "fixture rejection", "HTTP 502"),
        (StatusCode::OK, "fixture invalid JSON", "不是合法 JSON")] {
        let failed = serve(move |r| { request(&r, entry); (status, body).into_response() }).await;
        custom(&store, &failed.url); assert!(fetch(&site, &target, entry).await.unwrap_err().contains(expected));
        assert_eq!(failed.hits.lock().unwrap().len(), 1);
    }
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    custom(&store, &format!("http://{}", unused.local_addr().unwrap())); drop(unused);
    assert!(fetch(&site, &target, entry).await.is_err());
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "failures cannot retry directly");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch(&site, &target, entry).await.unwrap(), "origin");
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn catalog_proxy_shorthaokan_form_keeps_encoding_static_headers_and_hot_policy() { exercise(Entry::Form).await; }

// This helper currently has no business caller. Its transport coverage does
// not enable or establish ShortHaokan detail/play support.
#[tokio::test]
async fn catalog_proxy_shorthaokan_dormant_appui_keeps_literal_method_slash() { exercise(Entry::DormantAppui).await; }
