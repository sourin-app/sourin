use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::{provider::ListRequest, state::AppState};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{sync::Arc, time::Duration};

#[path = "catalog_proxy_test_support.rs"]
mod contract;

fn assert_headers(request: &Request) {
    assert_eq!(request.method, Method::GET);
    assert!(request.body.is_empty());
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["accept"], "application/json");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
}

#[async_trait::async_trait]
impl contract::FixtureSite for AppYsV2 {
    async fn fetch(&self, url: &str) -> Result<String, String> {
        self.get_json(url).await.map(|v| v.to_string())
    }

    fn assert_headers(request: &Request) {
        assert_headers(request);
    }
}

#[tokio::test]
async fn catalog_proxy_appysv2_real_helper_preserves_policy_and_headers() {
    contract::exercise(AppYsV2::new()).await;
}

fn list_payload(label: &str) -> Value {
    serde_json::json!({"code":1,"pagecount":"3","total":"21","list":[{
        "vod_id":101,"vod_name":format!("AppYsV2 {label}"),"vod_remarks":"fixture"
    }]})
}

async fn assert_list(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.list(ListRequest {
        category_id: "1".into(), page: 2, ..Default::default()
    })).await.expect("loopback list exceeded its fixture budget").unwrap();
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].title, format!("AppYsV2 {label}"));
    assert_eq!(page.page, 2);
    assert_eq!(page.page_count, Some(3));
    assert_eq!(page.total, Some(21));
}

#[tokio::test]
async fn catalog_proxy_appysv2_import_runtime_hot_change_and_restore() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let base = origin.url.clone();
    // AppYsV2 accepts a URL string ext; an object would choose its public default.
    let subscription = serde_json::json!({"sites":[{
        "key":"appysv2-local", "name":"AppYsV2 local fixture", "type":3,
        "api":"csp_AppYsV2", "ext":format!("{base}/ys/")
    }]});
    let first = serve(move |request| {
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/subscription.json" {
            return axum::Json(subscription.clone()).into_response();
        }
        assert_headers(&request);
        match request.uri.path() {
            "/ys/nav" => {
                assert_eq!(request.uri.query(), Some("token="));
                axum::Json(serde_json::json!({"code":1,"list":[{"type_id":1,"type_name":"电影"}]})).into_response()
            }
            "/ys/index_video" => {
                assert_eq!(request.uri.query(), Some("token="));
                axum::Json(serde_json::json!({"code":1,"list":[{"vlist":[{"vod_id":101,"vod_name":"home fixture"}]}]})).into_response()
            }
            "/ys/video" => {
                assert_eq!(request.uri.query(), Some("ac=list&tid=1&pg=2"));
                axum::Json(list_payload("first proxy")).into_response()
            }
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let second = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.path(), "/ys/video");
        assert_eq!(request.uri.query(), Some("ac=list&tid=1&pg=2"));
        axum::Json(list_payload("second proxy")).into_response()
    }).await;
    let root = scratch("appysv2-proxy-factories");
    let dir = root.join("data");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{base}/subscription.json"),
    )).await.expect("loopback import exceeded its fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let imported = report["imported"].as_array().unwrap();
    assert_eq!(imported.len(), 1, "{report}");
    let row = &imported[0];
    assert_eq!(row["api"], "csp_AppYsV2");
    assert_eq!(row["categories"], 1);
    assert!(row["probeFailed"].is_null(), "{row}");
    assert_eq!(row["persisted"], true);
    let id = row["id"].as_str().unwrap().to_string();
    assert_list(&state, &id, "first proxy").await;
    assert_eq!(first.hits.lock().unwrap().len(), 4, "config, nav, index prefetch, runtime list");
    assert!(origin.hits.lock().unwrap().is_empty());

    custom(&state.proxy, &second.url);
    assert_list(&state, &id, "second proxy").await;
    assert_eq!(first.hits.lock().unwrap().len(), 4);
    assert_eq!(second.hits.lock().unwrap().len(), 1);
    drop(state);
    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_list(&restored, &id, "second proxy").await;
    assert_eq!(second.hits.lock().unwrap().len(), 2);
    assert!(origin.hits.lock().unwrap().is_empty(), "no factory may bypass its injected policy");
    drop(restored);
    let _ = std::fs::remove_dir_all(root);
}

#[tokio::test]
async fn catalog_proxy_appysv2_hot_change_keeps_detail_cache_for_play() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let media = format!("{}/fixture.m3u8?first=alpha%2Bbeta&second=two", origin.url);
    let cached_media = media.clone();
    let first = serve(move |request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.path(), "/ys/video_detail");
        assert_eq!(request.uri.query(), Some("id=101"));
        axum::Json(serde_json::json!({"code":1,"data":{
            "vod_name":"cached detail", "vod_play_from":"lineA",
            "vod_play_url":format!("Episode 1${cached_media}")
        }})).into_response()
    }).await;
    let second = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/ys/video_detail" {
            return (StatusCode::BAD_GATEWAY, "detail must stay cached").into_response();
        }
        assert_eq!(request.uri.path(), "/ys/search");
        assert_eq!(request.uri.query(), Some("text=alpha%2Bbeta%20two&pg=2"));
        axum::Json(list_payload("after change")).into_response()
    }).await;
    let site = AppYsV2::new();
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "appysv2-cache-fixture");
    let ext = format!("{}/ys/", origin.url);
    let detail = tokio::time::timeout(Duration::from_secs(3), site.detail("101", &ext))
        .await.expect("loopback detail exceeded its fixture budget").unwrap();
    assert_eq!(detail.title, "cached detail");
    assert_eq!(detail.episodes.len(), 1);
    assert_eq!(first.hits.lock().unwrap().len(), 1);

    custom(&store, &second.url);
    let list = tokio::time::timeout(Duration::from_secs(3), site.search("alpha+beta two", 2, &ext))
        .await.expect("loopback search exceeded its fixture budget").unwrap();
    assert_eq!(list.items[0].title, "AppYsV2 after change");
    assert_eq!(second.hits.lock().unwrap().len(), 1, "the same site rebuilds its HTTP client");
    // Empty embedded URL requires the cached detail, not a URL copied into id.
    let play = tokio::time::timeout(Duration::from_secs(3), site.play("lineA", "lineA|0|", &ext))
        .await.expect("cached play exceeded its fixture budget").unwrap();
    assert_eq!(play.len(), 1);
    assert_eq!(play[0].url, media);
    assert_eq!(play[0].label.as_deref(), Some("lineA"));
    assert_eq!(play[0].headers, vec![("User-Agent".to_string(), UA.to_string())]);
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(second.hits.lock().unwrap().len(), 1, "play must not refetch detail after a policy change");
    assert!(origin.hits.lock().unwrap().is_empty(), "neither detail nor media can be opened directly");
}
