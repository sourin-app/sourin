use super::*;
use crate::csp::http_context::test_support::{custom, serve, Request};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::sync::Arc;

const HOST: &str = "http://app-parser-fixture.invalid";
const VALUE: &str = "opaque-selected%2Fpart|tail";

fn detail(parsers: &[String], ua: &str) -> Value {
    serde_json::json!({"code":1,"data":{"vod_name":"Fixture title","vod_play_list":[{
        "flag":"code-a","name":"Line A","ua":ua,"parse_urls":parsers,
        "urls":[{"name":"Episode 1","nid":1,"url":"wrong-episode"},
                {"name":"Episode 2","nid":2,"url":VALUE}]
    }]}})
}

fn parser_fields(request: &Request) -> std::collections::BTreeMap<String, String> {
    assert_eq!(request.method, Method::GET);
    assert_eq!(request.uri.host(), Some("app-parser-fixture.invalid"));
    assert_eq!(request.headers["referer"], "", "parser Referer follows the reference contract");
    let parsed = reqwest::Url::parse(&request.uri.to_string()).unwrap();
    let fields: std::collections::BTreeMap<String, String> = parsed.query_pairs().into_owned().collect();
    assert_eq!(fields["url"], VALUE, "must resolve the selected episode, preserving percent and pipe bytes");
    let timestamp = fields.get("timestamp").expect("parser request needs its own timestamp");
    let seconds = timestamp.parse::<u64>().unwrap();
    assert!(seconds.abs_diff(ts_secs()) <= 3, "timestamp must be current unix seconds");
    assert_eq!(fields.get("sign"), Some(&sign_of(timestamp)), "parser request needs a matching signature");
    fields
}

#[tokio::test]
async fn app_rj_parser_http_contract_signs_selected_episode_and_returns_response_ua() {
    let parsers = vec![format!("{HOST}/parse?key=fixture&url=")];
    let response = detail(&parsers, "LineUA/1");
    let fixture = serve(move |request| {
        if request.method == Method::POST {
            return axum::Json(response.clone()).into_response();
        }
        parser_fields(&request);
        axum::Json(serde_json::json!({"code":200,"url":"https://media.invalid/episode-2.m3u8","UA":"MediaUA/2"})).into_response()
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &fixture.url);
    let site = AppRJ::new();
    site.set_http_context(store, "app-rj-parser-contract");
    let detail = site.detail("item-42", &format!(r#"{{"url":"{HOST}"}}"#)).await.unwrap();
    let episode = &detail.episodes[1];
    let plays = site.play(&episode.flag, &episode.id, "").await.unwrap();
    assert_eq!(plays.len(), 1);
    assert_eq!(plays[0].url, "https://media.invalid/episode-2.m3u8");
    assert_eq!(plays[0].headers, vec![("User-Agent".into(), "MediaUA/2".into())]);
    assert_eq!(fixture.hits.lock().unwrap().len(), 2, "detail POST plus actual signed parser GET");
}

#[tokio::test]
async fn app_rj_declared_parser_fallback_keeps_line_ua_and_current_proxy() {
    let parsers = vec![format!("{HOST}/first?url="), format!("{HOST}/second?url=")];
    let fixture = serve(move |request| {
        parser_fields(&request);
        match request.uri.path() {
            "/first" => axum::Json(serde_json::json!({"code":500,"msg":"fixture unavailable", "url":"https://media.invalid/error-short.mp4"})).into_response(),
            "/second" => axum::Json(serde_json::json!({"code":200,"url":"https://media.invalid/selected.mp4"})).into_response(),
            _ => panic!("must only use the declared parsers"),
        }
    }).await;
    let site = AppRJ::new();
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &fixture.url);
    site.set_http_context(store, "app-rj-parser-fallback");
    let details = detail_of(&detail(&parsers, "DeclaredUA/3"), "42").unwrap();
    let episode = &details.episodes[1];
    let plays = site.play(&episode.flag, &episode.id, "").await.unwrap();
    assert_eq!(plays[0].url, "https://media.invalid/selected.mp4");
    assert_eq!(plays[0].headers, vec![("User-Agent".into(), "DeclaredUA/3".into())]);
    let hits = fixture.hits.lock().unwrap();
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].uri.path(), "/first");
    assert_eq!(hits[1].uri.path(), "/second");
}

#[tokio::test]
async fn app_rj_access_rejection_cannot_promote_media_url_or_try_another_parser() {
    let parsers = vec![format!("{HOST}/denied?url="), format!("{HOST}/must-not-run?url=")];
    let fixture = serve(|request| {
        parser_fields(&request);
        assert_eq!(request.uri.path(), "/denied");
        axum::Json(serde_json::json!({"code":403,"msg":"VIP_REQUIRED", "url":"https://media.invalid/private-error.mp4"})).into_response()
    }).await;
    let site = AppRJ::new();
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &fixture.url);
    site.set_http_context(store, "app-rj-parser-denied");
    let details = detail_of(&detail(&parsers, "LineUA/1"), "42").unwrap();
    let error = site.play("Line A", &details.episodes[1].id, "").await.unwrap_err();
    assert!(error.contains("权限") || error.contains("会员"));
    assert!(!error.contains("private-error"));
    assert_eq!(fixture.hits.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn app_rj_failed_proxy_does_not_retry_origin() {
    let origin = serve(|_| panic!("failed application proxy must never fall back to origin")).await;
    let rejected = serve(|_| StatusCode::FORBIDDEN.into_response()).await;
    let parsers = vec![format!("{}/parse?url=", origin.url)];
    let site = AppRJ::new();
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &rejected.url);
    site.set_http_context(store, "app-rj-parser-failed-route");
    let details = detail_of(&detail(&parsers, "LineUA/1"), "42").unwrap();
    assert!(site.play("Line A", &details.episodes[1].id, "").await.is_err());
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    assert!(origin.hits.lock().unwrap().is_empty());
}

#[tokio::test]
async fn app_rj_legacy_parser_id_is_signed_and_opaque_without_parser_is_rejected() {
    let fixture = serve(|request| {
        parser_fields(&request);
        axum::Json(serde_json::json!({"code":200,"url":"https://media.invalid/legacy.m3u8","UA":"LegacyMediaUA"})).into_response()
    }).await;
    let site = AppRJ::new();
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &fixture.url);
    site.set_http_context(store, "app-rj-legacy-parser");
    let id = format!("42@Line A|1|2|{HOST}/legacy?url=|{VALUE}");
    let plays = site.play("Line A", &id, "").await.unwrap();
    assert_eq!(plays[0].url, "https://media.invalid/legacy.m3u8");
    assert_eq!(plays[0].headers, vec![("User-Agent".into(), "LegacyMediaUA".into())]);
    assert!(site.play("Line A", "42@Line A|1|2||opaque-private", "").await.is_err());
    assert_eq!(fixture.hits.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn app_rj_real_provider_detail_and_resolve_keep_the_selected_recipe() {
    use crate::{model::{MediaId, PlayRequest}, provider::MediaProvider};
    let parsers = vec![format!("{HOST}/parse?url=")];
    let response = detail(&parsers, "LineUA/1");
    let fixture = serve(move |request| {
        if request.method == Method::POST { return axum::Json(response.clone()).into_response(); }
        parser_fields(&request);
        axum::Json(serde_json::json!({"code":200,"url":"https://media.invalid/provider-episode-2.m3u8"})).into_response()
    }).await;
    let site = Arc::new(AppRJ::new());
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &fixture.url);
    site.set_http_context(store, "app-rj-provider");
    let provider = crate::csp::provider::CspProvider::for_test("app-rj-provider", site, &format!(r#"{{"url":"{HOST}"}}"#));
    let item = MediaId::new("app-rj-provider", "42");
    let detail = provider.detail(&item).await.unwrap();
    let selected = &detail.episodes[1];
    let request = PlayRequest { episode_id: Some(selected.id.clone()), flag: Some(selected.flag.clone()),
        episode_title: Some(selected.title.clone()), episode_order: Some(2), ..Default::default() };
    let plays = provider.resolve(&item, &request).await.unwrap();
    assert_eq!(plays[0].url, "https://media.invalid/provider-episode-2.m3u8");
    assert_eq!(fixture.hits.lock().unwrap().len(), 2);
}
