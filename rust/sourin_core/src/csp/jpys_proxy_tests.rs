use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::{provider::ListRequest, state::AppState};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{sync::Arc, time::Duration};

#[path = "catalog_proxy_test_support.rs"]
mod contract;

fn assert_headers(r: &Request) {
    assert_eq!(r.headers["user-agent"], UA);
    assert!(!r.headers.contains_key("cookie")); assert!(!r.headers.contains_key("authorization"));
    assert!(!r.headers.contains_key("content-type")); assert!(r.body.is_empty());
    if r.method == Method::HEAD {
        assert_eq!(r.headers["accept"], "*/*");
        for key in ["sign", "t", "deviceid"] { assert!(!r.headers.contains_key(key)); }
    } else {
        assert_eq!(r.method, Method::GET); assert_eq!(r.headers["accept"], "application/json");
        assert_eq!(r.headers["deviceid"], device_id());
        assert!(r.headers["t"].to_str().unwrap().parse::<u64>().unwrap() > 0);
        let sign = r.headers["sign"].to_str().unwrap();
        assert_eq!(sign.len(), 40); assert!(sign.bytes().all(|b| b.is_ascii_hexdigit()));
    }
}

fn assert_signature(r: &Request) {
    use md5::{Digest, Md5};
    let time = r.headers["t"].to_str().unwrap();
    let source = format!("keyword=alpha+beta two&pageNum=2&pageSize=8&key=cb808529bae6b6be45ecfab29a4889bc&t={time}");
    let md5 = format!("{:x}", Md5::digest(source.as_bytes()));
    let digest = ring::digest::digest(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY, md5.as_bytes());
    let expected: String = digest.as_ref().iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(r.headers["sign"].to_str().unwrap(), expected);
}

#[async_trait::async_trait]
impl contract::FixtureSite for Jpys {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        let url = reqwest::Url::parse(url).unwrap();
        let base = format!("http://{}:{}", url.host_str().unwrap(), url.port().unwrap());
        let path = format!("{}?{}", url.path(), url.query().unwrap());
        self.get_signed(&base,
            "keyword=alpha+beta two&pageNum=2&pageSize=8&key=cb808529bae6b6be45ecfab29a4889bc&t={t}", &path).await
    }
    fn assert_headers(r: &Request) { assert_headers(r); assert_signature(r); }
}

#[tokio::test]
async fn catalog_proxy_jpys_signed_get_preserves_signature_device_and_policy() {
    contract::exercise(Jpys::new()).await;
}

async fn probe(site: &Jpys, target: &str) -> bool {
    tokio::time::timeout(Duration::from_secs(3), site.probe_domain(target))
        .await.expect("loopback Jpys HEAD probe exceeded fixture budget")
}

#[tokio::test]
async fn catalog_proxy_jpys_head_probe_hot_change_and_failures_never_go_direct() {
    let origin = serve(|r| { assert_headers(&r); assert_eq!(r.method, Method::HEAD); StatusCode::FORBIDDEN.into_response() }).await;
    let first = serve(|r| { assert_headers(&r); assert_eq!(r.method, Method::HEAD); assert_eq!(r.uri.scheme_str(), Some("http")); StatusCode::OK.into_response() }).await;
    let redirect = format!("{}/landed?first=alpha%2Bbeta&second=two", origin.url);
    let second = serve(move |r| {
        assert_headers(&r); assert_eq!(r.method, Method::HEAD); assert_eq!(r.uri.scheme_str(), Some("http"));
        assert_eq!(r.uri.query(), Some("first=alpha%2Bbeta&second=two"));
        if r.uri.path() == "/probe" { (StatusCode::TEMPORARY_REDIRECT, [("location", redirect.clone())]).into_response() }
        else { assert_eq!(r.uri.path(), "/landed"); StatusCode::NO_CONTENT.into_response() }
    }).await;
    let target = format!("{}/probe?first=alpha%2Bbeta&second=two", origin.url);
    let site = Jpys::new(); assert!(!probe(&site, &target).await);
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    site.set_http_context(store.clone(), "jpys-probe-loopback"); assert!(probe(&site, &target).await);
    custom(&store, &second.url); assert!(probe(&site, &target).await);
    assert_eq!(first.hits.lock().unwrap().len(), 1); assert_eq!(second.hits.lock().unwrap().len(), 2);
    let rejected = serve(|r| { assert_headers(&r); assert_eq!(r.method, Method::HEAD); StatusCode::BAD_GATEWAY.into_response() }).await;
    custom(&store, &rejected.url); assert!(!probe(&site, &target).await); assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    custom(&store, &format!("http://{}", unused.local_addr().unwrap())); drop(unused);
    assert!(!probe(&site, &target).await);
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "HEAD failures cannot retry directly");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert!(!probe(&site, &target).await); assert_eq!(origin.hits.lock().unwrap().len(), 2);
}

fn list_payload(label: &str) -> Value {
    serde_json::json!({"code":200,"data":{"list":[{"vodId":71,"vodName":label}],"totalPage":3,"totalCount":21}})
}

async fn assert_list(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.list(ListRequest {
        category_id:"1".into(),page:2,..Default::default()
    })).await.expect("loopback Jpys factory list exceeded fixture budget").unwrap();
    assert_eq!(page.items.len(), 1); assert_eq!(page.items[0].title, label);
    assert_eq!(page.page, 2); assert_eq!(page.page_count, Some(3)); assert_eq!(page.total, Some(21));
}

#[tokio::test]
async fn catalog_proxy_jpys_import_runtime_hot_change_and_restore() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let subscription = serde_json::json!({"sites":[{"key":"jpys-local","name":"Jpys local",
        "type":3,"api":"csp_Jpys","ext":origin.url}]});
    let first = serve(move |r| {
        assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() == "/subscription.json" { return axum::Json(subscription.clone()).into_response(); }
        assert_headers(&r);
        if r.method == Method::HEAD { assert_eq!(r.uri.path(), "/"); return StatusCode::OK.into_response(); }
        match r.uri.path() {
            P_HOT => axum::Json(serde_json::json!({"code":200,"data":[{"vodId":70,"vodName":"home fixture"}]})).into_response(),
            P_LIST => { assert_eq!(r.uri.query(), Some("type1=1&pageNum=2&area=&year=")); axum::Json(list_payload("first")).into_response() },
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let second = serve(|r| {
        assert_headers(&r); assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.method == Method::HEAD { assert_eq!(r.uri.path(), "/"); return StatusCode::OK.into_response(); }
        assert_eq!(r.uri.path(), P_LIST); assert_eq!(r.uri.query(), Some("type1=1&pageNum=2&area=&year="));
        axum::Json(list_payload("second")).into_response()
    }).await;
    let root = scratch("jpys-proxy-factories"); let dir = root.join("data"); std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir.clone()).await.unwrap(); custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{}/subscription.json", origin.url)
    )).await.expect("loopback Jpys import exceeded fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let rows = report["imported"].as_array().unwrap(); assert_eq!(rows.len(), 1, "{report}");
    let row = &rows[0]; assert_eq!(row["api"], "csp_Jpys"); assert_eq!(row["categories"], Jpys::CATS.len());
    assert!(row["probeFailed"].is_null(), "{row}"); assert_eq!(row["persisted"], true);
    let id = row["id"].as_str().unwrap().to_string(); assert_list(&state, &id, "first").await;
    assert_eq!(first.hits.lock().unwrap().len(), 5, "config, probe, home, runtime probe and list");
    custom(&state.proxy, &second.url); assert_list(&state, &id, "second").await;
    drop(state); let restored = AppState::bootstrap(dir).await.unwrap(); assert_list(&restored, &id, "second").await;
    assert_eq!(second.hits.lock().unwrap().len(), 4); assert!(origin.hits.lock().unwrap().is_empty());
    drop(restored); let _ = std::fs::remove_dir_all(root);
}
