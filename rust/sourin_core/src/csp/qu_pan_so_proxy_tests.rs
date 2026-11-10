use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::state::AppState;
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::Arc, time::Duration};

const KEYWORD: &str = "alpha +&/";
const BODY: &[u8] = br#"{"keyword":"alpha +&/","categoryid":0,"filetypeid":1,"courseid":1,"page":1,"pageSize":15,"sortBy":"sort","order":"desc","offset":0}"#;

fn payload(label: &str) -> String {
    serde_json::json!({"code":200,"data":{"total":1,"list":[
        {"title":label,"url":"http://127.0.0.1/fixture-share"}
    ]}}).to_string()
}

fn request(r: &Request) {
    assert_eq!(r.method, Method::POST); assert_eq!(r.body.as_ref(), BODY);
    assert_eq!(r.headers["user-agent"], UA);
    assert_eq!(r.headers["content-type"], "application/json");
    assert!(!r.headers.contains_key("cookie")); assert!(!r.headers.contains_key("authorization"));
    let host = reqwest::Url::parse(r.headers["origin"].to_str().unwrap()).unwrap();
    assert_eq!(host.host_str(), Some("127.0.0.1"));
    if r.uri.path() == "/search" { assert_eq!(r.headers["referer"].to_str().unwrap(), host.as_str()); }
    assert!(r.uri.query().is_none());
}

fn ext(base: &str) -> String { serde_json::json!({"site":base}).to_string() }

async fn search(site: &QuPanSo, base: &str) -> Result<CspList, String> {
    tokio::time::timeout(Duration::from_secs(3), site.search(" alpha +&/ ", 0, &ext(base)))
        .await.expect("loopback QuPanSo search exceeded fixture budget")
}

fn title(page: CspList) -> String {
    assert_eq!(page.page, 1); assert_eq!(page.total, Some(1));
    assert_eq!(page.items.len(), 1); page.items[0].title.clone()
}

#[tokio::test]
async fn catalog_proxy_qupanso_search_preserves_body_redirect_gzip_and_errors() {
    let origin = serve(|r| { request(&r); payload("origin").into_response() }).await;
    let first = serve(|r| { request(&r); assert_eq!(r.uri.scheme_str(), Some("http")); payload("first").into_response() }).await;
    let redirect = format!("{}/landed", origin.url);
    let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    gzip.write_all(payload("second").as_bytes()).unwrap(); let compressed = gzip.finish().unwrap();
    let second = serve(move |r| {
        request(&r); assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() == "/search" {
            (StatusCode::TEMPORARY_REDIRECT, [("location", redirect.clone()),
                ("set-cookie", "fixture=must-not-persist; Path=/".into())]).into_response()
        } else { assert_eq!(r.uri.path(), "/landed"); ([("content-encoding", "gzip")], compressed.clone()).into_response() }
    }).await;
    let site = QuPanSo::new(); assert_eq!(title(search(&site, &origin.url).await.unwrap()), "origin");
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    site.set_http_context(store.clone(), "qupanso-loopback");
    assert_eq!(title(search(&site, &origin.url).await.unwrap()), "first");
    custom(&store, &second.url); assert_eq!(title(search(&site, &origin.url).await.unwrap()), "second");
    assert_eq!(first.hits.lock().unwrap().len(), 1); assert_eq!(second.hits.lock().unwrap().len(), 2);
    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding.to_str().unwrap().contains("gzip"));
    for fixture in [&first, &second] { for r in fixture.hits.lock().unwrap().iter() { assert_eq!(r.headers["accept-encoding"], encoding); } }
    for (status, body, error_part) in [
        (StatusCode::BAD_GATEWAY, "fixture rejected", "HTTP 502"),
        (StatusCode::OK, "fixture invalid JSON", "不是 JSON"),
        (StatusCode::OK, r#"{"code":403,"msg":"fixture blocked"}"#, "code=403"),
        (StatusCode::OK, r#"{"code":200,"data":{}}"#, "data.list"),
    ] {
        let failed = serve(move |r| { request(&r); (status, body).into_response() }).await;
        custom(&store, &failed.url);
        assert!(search(&site, &origin.url).await.unwrap_err().contains(error_part));
        assert_eq!(failed.hits.lock().unwrap().len(), 1);
    }
    let empty = serve(|r| { request(&r); r#"{"code":200,"data":{"total":0,"list":[]}}"#.into_response() }).await;
    custom(&store, &empty.url); assert!(search(&site, &origin.url).await.unwrap().items.is_empty());
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    custom(&store, &format!("http://{}", unused.local_addr().unwrap())); drop(unused);
    assert!(search(&site, &origin.url).await.is_err());
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "failures cannot retry directly");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(title(search(&site, &origin.url).await.unwrap()), "origin");
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
}

async fn runtime_search(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.search(KEYWORD, 1)).await
        .expect("loopback QuPanSo factory search exceeded fixture budget").unwrap();
    assert_eq!(page.items.len(), 1); assert_eq!(page.items[0].title, label);
}

#[tokio::test]
async fn catalog_proxy_qupanso_failed_home_probe_keeps_search_runtime_hot_policy_and_restore() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let cfg = ext(&origin.url);
    let subscription = serde_json::json!({"sites":[{"key":"qupanso-local","name":"QuPanSo local",
        "type":3,"api":"csp_QuPanSo","ext":serde_json::from_str::<Value>(&cfg).unwrap()}]});
    let first = serve(move |r| {
        assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() == "/subscription.json" { return axum::Json(subscription.clone()).into_response(); }
        request(&r); assert_eq!(r.uri.path(), "/search"); payload("first").into_response()
    }).await;
    let second = serve(|r| { request(&r); assert_eq!(r.uri.scheme_str(), Some("http")); payload("second").into_response() }).await;
    let dir = scratch("qupanso-proxy-factories"); let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{}/subscription.json", origin.url)
    )).await.expect("loopback QuPanSo import exceeded fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let rows = report["imported"].as_array().unwrap(); assert_eq!(rows.len(), 1, "{report}");
    let row = &rows[0]; assert_eq!(row["categories"], 0); assert_eq!(row["persisted"], true);
    assert!(row["probeFailed"].as_str().unwrap().contains("纯搜索源"), "{row}");
    let id = row["id"].as_str().unwrap().to_string(); runtime_search(&state, &id, "first").await;
    assert_eq!(first.hits.lock().unwrap().len(), 2, "subscription and runtime search; home probe has no HTTP");
    custom(&state.proxy, &second.url); runtime_search(&state, &id, "second").await;
    drop(state); let restored = AppState::bootstrap(dir.clone()).await.unwrap(); runtime_search(&restored, &id, "second").await;
    assert_eq!(second.hits.lock().unwrap().len(), 2); assert!(origin.hits.lock().unwrap().is_empty());
    drop(restored); let _ = std::fs::remove_dir_all(dir);
}
