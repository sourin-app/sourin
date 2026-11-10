use super::*;
#[path = "catalog_proxy_test_support.rs"]
mod catalog_proxy_test_support;
use catalog_proxy_test_support::FixtureSite;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::state::AppState;
use axum::{http::Method, response::IntoResponse};
use std::{sync::Arc, time::Duration};

fn headers(r: &Request) {
    assert_eq!(r.method, Method::GET);
    assert!(r.body.is_empty());
    assert_eq!(r.headers["user-agent"], UA);
    assert!(!r.headers.contains_key("cookie"));
    assert!(!r.headers.contains_key("authorization"));
}

#[async_trait::async_trait]
impl FixtureSite for AppDrama {
    async fn fetch(&self, url: &str) -> Result<String, String> { self.get_text(url).await }
    fn assert_headers(r: &Request) { headers(r); }
}

#[tokio::test]
async fn catalog_proxy_appdrama_dispatch_get_keeps_transport_contract() {
    catalog_proxy_test_support::exercise(AppDrama::new()).await;
}

fn ext(site: &str) -> String {
    serde_json::json!({"site":site,"publicKey":"fixture-public-key",
        "dataKey":"fixture-data-key","appName":"fixture"}).to_string()
}

async fn home_error(site: &AppDrama, cfg: &str) -> String {
    tokio::time::timeout(Duration::from_secs(3), site.home(cfg)).await
        .expect("loopback AppDrama dispatch exceeded fixture budget").unwrap_err()
}

fn unavailable(state: &AppState, id: &str, cfg: &str) {
    let provider = state.registry.get(id).unwrap();
    let manifest = provider.manifest();
    assert!(!manifest.working && !manifest.capabilities.vod && !manifest.capabilities.search);
    assert_eq!(manifest.broken_reason.as_deref(), Some("AppDrama 的浏览和播放能力尚未实现，配置已保留"));
    let saved = crate::persist::load_persisted(&state.data_dir);
    assert!(saved.iter().any(|row| matches!(row,
        crate::model::PersistedProvider::Tvbox { id: saved_id, ext: Some(saved_ext), .. }
            if saved_id == id && saved_ext == cfg)));
}

#[tokio::test]
async fn catalog_proxy_appdrama_public_dispatch_probe_and_restore_remain_unavailable() {
    let downstream = serve(|_| panic!("AppDrama must not fetch the dispatched API domain")).await;
    let origin = serve(|_| r#"{"domain":"http://127.0.0.1/origin","enabled":true}"#.into_response()).await;
    let cfg = ext(&format!("{}/dispatch?first=alpha%2Bbeta&second=two", origin.url));
    let subscription = serde_json::json!({"sites":[{"key":"drama-local","name":"Drama local",
        "type":3,"api":"csp_AppDrama","ext":serde_json::from_str::<Value>(&cfg).unwrap()}]});
    let first_domain = format!("{}/first-api", downstream.url);
    let domain = first_domain.clone();
    let first = serve(move |r| {
        assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() == "/subscription.json" { return axum::Json(subscription.clone()).into_response(); }
        headers(&r); assert_eq!(r.uri.path(), "/dispatch");
        assert_eq!(r.uri.query(), Some("first=alpha%2Bbeta&second=two"));
        axum::Json(serde_json::json!({"domain":domain,"enabled":true})).into_response()
    }).await;
    let second_domain = format!("{}/second-api", downstream.url);
    let domain = second_domain.clone();
    let second = serve(move |r| {
        headers(&r); assert_eq!(r.uri.scheme_str(), Some("http"));
        axum::Json(serde_json::json!({"domain":domain,"enabled":true})).into_response()
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new()); custom(&store, &first.url);
    let site = AppDrama::new(); site.set_http_context(store.clone(), "appdrama-public");
    let error = home_error(&site, &cfg).await;
    assert!(error.contains(&first_domain) && error.contains("分类段尚未打通"), "{error}");
    custom(&store, &second.url);
    let error = home_error(&site, &cfg).await;
    assert!(error.contains(&second_domain) && error.contains("分类段尚未打通"), "{error}");
    let disabled = serve(|_| r#"{"domain":"http://127.0.0.1/disabled","enabled":false}"#.into_response()).await;
    custom(&store, &disabled.url);
    assert!(home_error(&site, &cfg).await.contains("enabled=false"));
    let invalid = serve(|_| "fixture invalid JSON".into_response()).await;
    custom(&store, &invalid.url);
    assert!(home_error(&site, &cfg).await.contains("不是合法 JSON"));

    let dir = scratch("appdrama-proxy-dispatch");
    let state = AppState::bootstrap(dir.clone()).await.unwrap(); custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{}/subscription.json", origin.url)
    )).await.expect("loopback AppDrama import exceeded fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let rows = report["imported"].as_array().unwrap(); assert_eq!(rows.len(), 1, "{report}");
    let row = &rows[0]; assert_eq!(row["persisted"], true); assert_eq!(row["categories"], 0);
    let failure = row["probeFailed"].as_str().unwrap();
    assert!(failure.contains(&first_domain) && failure.contains("分类段尚未打通"), "{failure}");
    let id = row["id"].as_str().unwrap().to_string(); unavailable(&state, &id, &cfg);
    assert_eq!(first.hits.lock().unwrap().len(), 3, "public dispatch, subscription, import dispatch");
    custom(&state.proxy, &second.url); drop(state);
    let restored = AppState::bootstrap(dir.clone()).await.unwrap(); unavailable(&restored, &id, &cfg);
    assert_eq!(second.hits.lock().unwrap().len(), 1, "restore must not probe unsupported catalog capability");
    assert!(downstream.hits.lock().unwrap().is_empty()); assert!(origin.hits.lock().unwrap().is_empty());
    assert!(!site.supports_search());
    drop(restored); let _ = std::fs::remove_dir_all(dir);
}
