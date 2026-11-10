use super::*;
#[path = "catalog_proxy_test_support.rs"]
mod catalog_proxy_test_support;
use catalog_proxy_test_support::FixtureSite;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::{provider::ListRequest, state::AppState};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{sync::Arc, time::Duration};

fn headers(r: &Request) {
    assert_eq!(r.method, Method::GET); assert!(r.body.is_empty());
    assert_eq!(r.headers["user-agent"], UA);
    assert_eq!(r.headers["accept"], "text/html,application/xhtml+xml");
    assert_eq!(r.headers["accept-language"], "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7");
    assert!(!r.headers.contains_key("authorization"));
}

#[async_trait::async_trait]
impl FixtureSite for SaoHuo {
    async fn fetch(&self, url: &str) -> Result<String, String> { self.get_text(url, "fixture").await }
    fn assert_headers(r: &Request) { headers(r); }
}

async fn text(site: &SaoHuo, url: &str) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), site.get_text(url, "fixture"))
        .await.expect("loopback SaoHuo helper exceeded fixture budget")
}

fn card(label: &str) -> String { format!(r#"<a href="/movie/1.html" title="{label}">entry</a>"#) }

#[tokio::test]
async fn catalog_proxy_saohuo_get_headers_redirect_gzip_and_hot_policy() {
    catalog_proxy_test_support::exercise(SaoHuo::new()).await;
}

#[tokio::test]
async fn catalog_proxy_saohuo_first_cookie_survives_errors_rebuilds_and_instance_isolation() {
    let origin = serve(|_| "origin must not be fetched".into_response()).await;
    let first = serve(|r| {
        headers(&r); assert!(!r.headers.contains_key("cookie"));
        assert_eq!(r.uri.scheme_str(), Some("http")); assert_eq!(r.uri.path(), "/seed");
        (StatusCode::BAD_GATEWAY, [("set-cookie", "fixture=first; Path=/; HttpOnly")], "fixture seed error").into_response()
    }).await;
    let second = serve(|r| {
        headers(&r); assert_eq!(r.uri.scheme_str(), Some("http"));
        match r.uri.path() {
            "/check" => {
                assert_eq!(r.headers["cookie"], "fixture=first");
                ([("set-cookie", "fixture=replacement; Path=/")], "second").into_response()
            }
            "/fresh" => {
                assert!(!r.headers.contains_key("cookie"));
                ([("set-cookie", "fixture=isolated; Path=/")], "fresh").into_response()
            }
            "/fresh-again" => { assert_eq!(r.headers["cookie"], "fixture=isolated"); "isolated".into_response() }
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    let site = SaoHuo::new(); site.set_http_context(store.clone(), "saohuo-cookie");
    assert!(text(&site, &format!("{}/seed", origin.url)).await.unwrap_err().contains("HTTP 502"));
    assert_eq!(*site.cookie.lock().unwrap(), "fixture=first", "first Set-Cookie is retained even on an HTTP error");
    custom(&store, &second.url);
    for _ in 0..2 { assert_eq!(text(&site, &format!("{}/check", origin.url)).await.unwrap(), "second"); }
    assert_eq!(*site.cookie.lock().unwrap(), "fixture=first", "later Set-Cookie cannot rotate the stored value");
    let fresh = SaoHuo::new(); fresh.set_http_context(store.clone(), "saohuo-cookie-fresh");
    assert_eq!(text(&fresh, &format!("{}/fresh", origin.url)).await.unwrap(), "fresh");
    assert_eq!(text(&fresh, &format!("{}/fresh-again", origin.url)).await.unwrap(), "isolated");
    assert_eq!(*site.cookie.lock().unwrap(), "fixture=first");
    assert_eq!(first.hits.lock().unwrap().len(), 1); assert_eq!(second.hits.lock().unwrap().len(), 4);
    assert!(origin.hits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn catalog_proxy_saohuo_release_page_and_selected_site_cache_keep_current_policy() {
    let origin = serve(|_| r#"<div class="content-top"><a href="http://127.0.0.1/origin">old</a></div>"#.into_response()).await;
    let chosen = format!("{}/picked", origin.url); let selected = chosen.clone();
    let first = serve(move |r| {
        headers(&r); assert_eq!(r.uri.scheme_str(), Some("http"));
        assert_eq!(r.uri.path(), "/release");
        format!(r#"<div class="content-top"><a href="{selected}/">new</a></div>"#).into_response()
    }).await;
    let second = serve(|r| {
        headers(&r); assert_eq!(r.uri.scheme_str(), Some("http"));
        match r.uri.path() {
            "/picked/list/1-2.html" => card("cached through second").into_response(),
            "/new/list/1-1.html" => card("fresh ext").into_response(),
            "/bad-release" => "fixture no release anchor".into_response(),
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    let site = SaoHuo::new(); site.set_http_context(store.clone(), "saohuo-release");
    let resolved = tokio::time::timeout(Duration::from_secs(3), site.resolve_from_release_url("", &format!("{}/release", origin.url)))
        .await.expect("loopback SaoHuo release exceeded fixture budget").unwrap();
    assert_eq!(resolved, chosen);
    custom(&store, &second.url);
    let changed_ext = format!("{}/new", origin.url);
    let page = tokio::time::timeout(Duration::from_secs(3), site.list("1", 2, &changed_ext))
        .await.unwrap().unwrap();
    assert_eq!(page.items[0].title, "cached through second");
    assert_eq!(*site.site.lock().unwrap(), chosen, "a new ext cannot replace this instance's selected-site cache");
    let fresh = SaoHuo::new(); fresh.set_http_context(store.clone(), "saohuo-release-fresh");
    let page = tokio::time::timeout(Duration::from_secs(3), fresh.list("1", 1, &changed_ext)).await.unwrap().unwrap();
    assert_eq!(page.items[0].title, "fresh ext");
    let failed = SaoHuo::new(); failed.set_http_context(store, "saohuo-release-invalid");
    let error = tokio::time::timeout(Duration::from_secs(3), failed.resolve_from_release_url("", &format!("{}/bad-release", origin.url)))
        .await.unwrap().unwrap_err();
    assert!(error.contains("探到新域名"), "{error}"); assert!(failed.site.lock().unwrap().is_empty());
    assert_eq!(first.hits.lock().unwrap().len(), 1); assert_eq!(second.hits.lock().unwrap().len(), 3);
    assert!(origin.hits.lock().unwrap().is_empty());
}

async fn play(site: &SaoHuo, base: &str, path: &str) -> Vec<CspPlay> {
    let id = format!("{base}/movie/1.html@fixture-line|0|{base}/{path}");
    tokio::time::timeout(Duration::from_secs(3), site.play("ignored", &id, ""))
        .await.expect("loopback SaoHuo play exceeded fixture budget").unwrap()
}

#[tokio::test]
async fn catalog_proxy_saohuo_public_search_detail_and_play_keep_fallback_without_direct_retry() {
    let origin = serve(|_| r#"<iframe src="http://127.0.0.1/origin"></iframe>"#.into_response()).await;
    let proxy = serve(|r| {
        headers(&r); assert_eq!(r.uri.scheme_str(), Some("http"));
        match r.uri.path() {
            "/frame" => r#"<iframe src="http://127.0.0.1/fixture-media"></iframe>"#.into_response(),
            "/none" => "fixture page without iframe".into_response(),
            "/failed" => (StatusCode::BAD_GATEWAY, "fixture failure").into_response(),
            "/s----------.html" => { assert_eq!(r.uri.query(), Some("wd=alpha%20%2B%26%2F")); card("search fixture").into_response() }
            "/movie/1.html" => r#"<h1>detail fixture</h1><ul id="play_link"><li><a href="/frame">first</a></li></ul>"#.into_response(),
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &proxy.url);
    let site = SaoHuo::new(); site.set_http_context(store.clone(), "saohuo-public");
    let frame = play(&site, &origin.url, "frame").await;
    assert_eq!(frame.len(), 1); assert_eq!(frame[0].url, "http://127.0.0.1/fixture-media");
    assert_eq!(frame[0].label.as_deref(), Some("fixture-line"));
    assert_eq!(frame[0].headers, vec![("User-Agent".into(), UA.into()), ("accept-language".into(), ACCEPT_LANG.into())]);
    for path in ["none", "failed"] {
        let result = play(&site, &origin.url, path).await;
        assert_eq!(result[0].url, format!("{}/{path}", origin.url));
        assert!(result[0].label.as_deref().unwrap().contains("未找到 iframe"));
    }
    let found = tokio::time::timeout(Duration::from_secs(3), site.search("alpha +&/", 1, &origin.url)).await.unwrap().unwrap();
    assert_eq!(found.items[0].title, "search fixture");
    let detail = tokio::time::timeout(Duration::from_secs(3), site.detail(&format!("{}/movie/1.html", origin.url), "")).await.unwrap().unwrap();
    assert_eq!(detail.title, "detail fixture"); assert_eq!(detail.episodes.len(), 1);
    assert!(detail.episodes[0].id.ends_with(&format!("|{}/frame", origin.url)));
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    custom(&store, &format!("http://{}", unused.local_addr().unwrap())); drop(unused);
    let result = play(&site, &origin.url, "closed").await;
    assert_eq!(result[0].url, format!("{}/closed", origin.url));
    assert_eq!(proxy.hits.lock().unwrap().len(), 5); assert!(origin.hits.lock().unwrap().is_empty());
}

async fn runtime_list(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.list(ListRequest {
        category_id:"1".into(), page:2, ..Default::default()
    })).await.expect("loopback SaoHuo factory list exceeded fixture budget").unwrap();
    assert_eq!(page.items.len(), 1); assert_eq!(page.items[0].title, label);
}

#[tokio::test]
async fn catalog_proxy_saohuo_constant_home_import_runtime_hot_change_and_restore() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let subscription = serde_json::json!({"sites":[{"key":"saohuo-local","name":"SaoHuo local",
        "type":3,"api":"csp_SaoHuo","ext":origin.url}]});
    let first = serve(move |r| {
        assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() == "/subscription.json" { return axum::Json(subscription.clone()).into_response(); }
        headers(&r); assert_eq!(r.uri.path(), "/list/1-2.html"); card("first").into_response()
    }).await;
    let second = serve(|r| {
        headers(&r); assert_eq!(r.uri.scheme_str(), Some("http")); assert_eq!(r.uri.path(), "/list/1-2.html"); card("second").into_response()
    }).await;
    let dir = scratch("saohuo-proxy-factories"); let state = AppState::bootstrap(dir.clone()).await.unwrap(); custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{}/subscription.json", origin.url)
    )).await.expect("loopback SaoHuo import exceeded fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let rows = report["imported"].as_array().unwrap(); assert_eq!(rows.len(), 1, "{report}");
    let row = &rows[0]; assert_eq!(row["categories"].as_u64(), Some(cats().len() as u64));
    assert!(row["probeFailed"].is_null()); assert_eq!(row["persisted"], true);
    assert_eq!(first.hits.lock().unwrap().len(), 1, "constant home is not content HTTP coverage");
    let id = row["id"].as_str().unwrap().to_string(); runtime_list(&state, &id, "first").await;
    custom(&state.proxy, &second.url); runtime_list(&state, &id, "second").await;
    drop(state); let restored = AppState::bootstrap(dir.clone()).await.unwrap(); runtime_list(&restored, &id, "second").await;
    assert_eq!(first.hits.lock().unwrap().len(), 2); assert_eq!(second.hits.lock().unwrap().len(), 2);
    assert!(origin.hits.lock().unwrap().is_empty()); drop(restored); let _ = std::fs::remove_dir_all(dir);
}
