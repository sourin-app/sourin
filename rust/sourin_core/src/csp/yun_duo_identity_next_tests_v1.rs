use super::*;
use crate::csp::http_context::test_support::{custom, serve};
use crate::model::{MediaId, PlayRequest};
use crate::provider::MediaProvider;
use axum::{http::Method, response::IntoResponse};
use serde_json::json;
use std::sync::Arc;

const HOST: &str = "http://yunduo-identity-fixture.invalid";
const MEDIA: &str = "https://media.invalid/selected.m3u8?sign=fixture%2Bvalue";

fn success_response() -> Vec<u8> {
    // Independent minimal protobuf response, unrelated to the owning decoder.
    assert!(MEDIA.len() < 128);
    let mut bytes = vec![8, 1, 18, 7];
    bytes.extend_from_slice(b"success");
    bytes.extend_from_slice(&[26, MEDIA.len() as u8]);
    bytes.extend_from_slice(MEDIA.as_bytes());
    bytes
}

fn assert_selected_request(body: &[u8], expected_line: &str, expected_value: &str) {
    // Fixture fields are shorter than 128 bytes. Inspect the actual independent
    // protobuf field boundaries before comparing either selected field.
    assert!(expected_line.len() < 128 && expected_value.len() < 128);
    assert_eq!(body.first(), Some(&10), "first protobuf field is opaque value");
    let value_length = usize::from(body[1]);
    assert!(value_length < 128);
    let line_tag = 2 + value_length;
    assert_eq!(body[line_tag], 18, "second protobuf field is selected line");
    let line_length = usize::from(body[line_tag + 1]);
    assert!(line_length < 128);
    let after_line = line_tag + 2 + line_length;
    assert_eq!(body[after_line], 24, "the real request also carries its time field");
    assert_eq!(
        &body[2..line_tag], expected_value.as_bytes(),
        "selected opaque value must exclude every part of the display title"
    );
    assert_eq!(
        &body[line_tag + 2..after_line], expected_line.as_bytes(),
        "selected line must survive its own separator bytes"
    );
}

async fn detail_to_selected_request(line: &str, title: &str, value: &str, ordinary_id: bool) {
    let response_line = line.to_string();
    let response_title = title.to_string();
    let response_value = value.to_string();
    let fixture = serve(move |request| {
        match request.uri.path() {
            "/api.php/web/vod/get_detail" => {
                assert_eq!(request.method, Method::GET);
                axum::Json(json!({
                    "code": 200,
                    "data": [{
                        "vod_id": 363,
                        "vod_name": "identity fixture",
                        "vod_play_from": response_line,
                        "vod_play_url": format!(
                            "第01集$opaque-distractor#{}${}",
                            response_title, response_value
                        )
                    }]
                })).into_response()
            }
            "/api.php/web/decode/url" => {
                assert_eq!(request.method, Method::POST);
                // Always respond. Identity defects must fail the test matcher,
                // rather than aborting a server task or producing transport RED.
                ([("content-type", "application/x-protobuf")], success_response()).into_response()
            }
            _ => panic!("unexpected fixture route: {}", request.uri),
        }
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &fixture.url);
    let ext = json!({"host": HOST, "client": "fixture-client", "sign": "fixture-sign"}).to_string();
    let provider = crate::csp::provider::CspProvider::new(
        "yunduo-selected-identity-fixture", "fixture", "csp_YunDuo", &ext,
        vec![], true, false,
    ).unwrap().with_proxy(store);
    let media = MediaId::new("yunduo-selected-identity-fixture", "363");
    let detail = provider.detail(&media).await.unwrap();
    assert_eq!(detail.episodes.len(), 2, "the selection has a real distractor");
    let selected = &detail.episodes[1];
    assert_eq!(selected.title, title, "public display title is preserved");
    assert_eq!(selected.flag, line, "public selected line is preserved");
    assert_ne!(selected.id, detail.episodes[0].id, "episode identities are distinct");
    if ordinary_id {
        assert_eq!(selected.id, format!("{line}|{title}|{value}"), "ordinary stored id bytes stay unchanged");
    }
    let mut request = PlayRequest::default();
    request.episode_id = Some(selected.id.clone());
    request.episode_title = Some(selected.title.clone());
    request.episode_order = Some(selected.order);
    request.flag = Some(selected.flag.clone());
    let result = provider.resolve(&media, &request).await;
    assert!(result.is_ok(), "the selected identity must reach the decoder: {result:?}");
    let streams = result.unwrap();
    assert_eq!(streams.len(), 1);
    assert_eq!(streams[0].url, MEDIA);
    let hits = fixture.hits.lock().unwrap();
    assert_eq!(hits.len(), 2, "one detail request followed by one selected decode, without detail fallback");
    let decoded = &hits[1];
    assert_eq!(decoded.uri.path(), "/api.php/web/decode/url");
    assert_eq!(decoded.uri.host(), Some("yunduo-identity-fixture.invalid"));
    assert_eq!(decoded.headers["content-type"], "application/x-protobuf");
    assert_eq!(decoded.headers["accept"], "application/x-protobuf");
    assert_eq!(decoded.headers["x-client"], "fixture-client");
    assert_eq!(decoded.headers["web-sign"], "fixture-sign");
    assert!(!decoded.headers.contains_key("cookie"));
    assert!(!decoded.headers.contains_key("authorization"));
    assert_selected_request(&decoded.body, line, value);
}

#[tokio::test(flavor = "current_thread")]
async fn selected_title_pipe_does_not_become_an_opaque_payload_prefix() {
    detail_to_selected_request("PAN1", "第03集|国语", "PAN1-exact%2Fselected+value/&x=1|tail", false).await;
}

#[tokio::test(flavor = "current_thread")]
async fn selected_line_pipe_survives_provider_and_decoder_identity() {
    detail_to_selected_request("PAN1|备用", "第03集", "exact-selected%2F+value", false).await;
}

#[tokio::test(flavor = "current_thread")]
async fn ordinary_detail_id_retains_its_existing_bytes_and_selected_value() {
    detail_to_selected_request("PAN1", "第03集", "PAN1-exact%2Fselected+value", true).await;
}

#[tokio::test(flavor = "current_thread")]
async fn persisted_legacy_id_keeps_reserved_opaque_value_bytes() {
    let fixture = serve(|request| {
        assert_eq!(request.method, Method::POST);
        assert_eq!(request.uri.path(), "/api.php/web/decode/url");
        ([("content-type", "application/x-protobuf")], success_response()).into_response()
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &fixture.url);
    let site = YunDuo::new();
    site.set_http_context(store, "yunduo-legacy-id-fixture");
    let ext = json!({"host": HOST}).to_string();
    let value = "legacy%2F+value/&x=1|tail|last";
    let id = format!("PAN1|普通话版|{value}");
    let plays = site.play("PAN1", &id, &ext).await.unwrap();
    assert_eq!(plays.len(), 1);
    assert_eq!(plays[0].url, MEDIA);
    let hits = fixture.hits.lock().unwrap();
    assert_eq!(hits.len(), 1);
    assert_selected_request(&hits[0].body, "PAN1", value);
}
