use super::*;
use crate::{model::{MediaId, PlayRequest}, provider::MediaProvider};
use crate::csp::http_context::test_support::serve;
use axum::response::IntoResponse;
use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use md5::{Digest, Md5};
use std::sync::Arc;

fn encrypted_media(uk: &str) -> String {
    let mut bytes = crate::csp::app99::b64_decode(uk).unwrap();
    let uid = cbc::Decryptor::<aes::Aes128>::new_from_slices(b"f349wghhe784tqwh", b"d3w8hf94fidk38lk").unwrap()
        .decrypt_padded_mut::<Pkcs7>(&mut bytes).unwrap();
    let identity = format!("{:x}", Md5::digest(uid));
    let key = format!("{:x}", Md5::digest(format!("{identity}34F9Q53w/HJW8E6Q").as_bytes()));
    let plain = br#"{"playUrl":"https://media.invalid/selected-episode.m3u8","header":{"User-Agent":"FixtureMediaUA"}}"#;
    let mut buffer = vec![0; (plain.len() / 16 + 1) * 16];
    buffer[..plain.len()].copy_from_slice(plain);
    let cipher = cbc::Encryptor::<aes::Aes128>::new_from_slices(&key.as_bytes()[..16], &key.as_bytes()[16..]).unwrap()
        .encrypt_padded_mut::<Pkcs7>(&mut buffer, plain.len()).unwrap();
    crate::csp::app99::b64_encode(cipher)
}

async fn http_fixture() -> crate::csp::http_context::test_support::Fixture {
    serve(|request| {
        let parsed = reqwest::Url::parse(&request.uri.to_string()).unwrap_or_else(|_|
            reqwest::Url::parse(&format!("http://fixture.invalid{}", request.uri)).unwrap());
        let fields = parsed.query_pairs().collect::<std::collections::HashMap<_, _>>();
        match request.uri.path() {
            "/api/series/detail" => {
                assert_eq!(fields.get("sid").unwrap(), "content-id", "episode pid must never become a content sid");
                axum::Json(serde_json::json!({"rescode":0,"series":{"sid":"content-id","name":"Fixture title"},
                    "playItems":[{"pid":"first-pid","serialNo":1,"title":"Episode 1"},
                                 {"pid":"selected-pid","serialNo":2,"title":"Episode 2"}]})).into_response()
            }
            "/api/common/configs" => axum::Json(serde_json::json!({"rescode":0})).into_response(),
            "/api/series2/episode/detail" => {
                assert_eq!(fields.get("pid").unwrap(), "selected-pid");
                axum::Json(serde_json::json!({"playItem":{"pid":"selected-pid","permission":{"allowPlay":1},
                    "sources":[{"scid":"selected-source"}]}})).into_response()
            }
            "/api/series/rslvV4" => {
                assert_eq!(fields.get("pid").unwrap(), "selected-pid");
                assert_eq!(fields.get("scid").unwrap(), "selected-source");
                let data = encrypted_media(request.headers["uk"].to_str().unwrap());
                axum::Json(serde_json::json!({"rescode":0,"datas":[{"data":data}]})).into_response()
            }
            _ => panic!("unexpected local endpoint"),
        }
    }).await
}

fn real_provider(url: &str) -> crate::csp::provider::CspProvider {
    let mut site = Hxq::new();
    site.base_override = Some(url.to_string());
    crate::csp::provider::CspProvider::for_test("hxq-provider-contract", Arc::new(site), "")
}

#[tokio::test]
async fn hxq_real_provider_selection_must_not_reinterpret_episode_pid_as_content_id() {
    let fixture = http_fixture().await;
    let provider = real_provider(&fixture.url);
    let item = MediaId::new("hxq-provider-contract", "content-id");
    let detail = provider.detail(&item).await.unwrap();
    let selected = &detail.episodes[1];
    let request = PlayRequest { episode_id: Some(selected.id.clone()), flag: Some(selected.flag.clone()),
        episode_title: Some(selected.title.clone()), episode_order: Some(2), ..Default::default() };
    let plays = provider.resolve(&item, &request).await.expect("real provider must dispatch selected playback");
    assert_eq!(plays[0].url, "https://media.invalid/selected-episode.m3u8");
    let hits = fixture.hits.lock().unwrap();
    assert_eq!(hits.len(), 4, "one content detail, configs, selected episode detail, media resolve");
    assert_eq!(hits.iter().filter(|hit| hit.uri.path() == "/api/series/detail").count(), 1);
}

#[tokio::test]
async fn hxq_legacy_explicit_bare_pid_uses_play_without_content_lookup() {
    let fixture = http_fixture().await;
    let provider = real_provider(&fixture.url);
    let item = MediaId::new("hxq-provider-contract", "content-id");
    let request = PlayRequest { episode_id: Some("selected-pid".into()),
        flag: Some("韩圈".into()), episode_title: Some("Episode 2".into()), episode_order: Some(2), ..Default::default() };
    let plays = provider.resolve(&item, &request).await.unwrap();
    assert_eq!(plays[0].url, "https://media.invalid/selected-episode.m3u8");
    let hits = fixture.hits.lock().unwrap();
    assert_eq!(hits.len(), 3);
    assert!(hits.iter().all(|request| request.uri.path() != "/api/series/detail"),
        "cold restored explicit pid must not be treated as a content id");
}

#[tokio::test]
async fn hxq_content_without_explicit_episode_still_fetches_content_detail() {
    let fixture = http_fixture().await;
    let provider = real_provider(&fixture.url);
    let item = MediaId::new("hxq-provider-contract", "content-id");
    let request = PlayRequest { episode_title: Some("Episode 2".into()), episode_order: Some(2), ..Default::default() };
    let plays = provider.resolve(&item, &request).await.unwrap();
    assert_eq!(plays[0].url, "https://media.invalid/selected-episode.m3u8");
    let hits = fixture.hits.lock().unwrap();
    assert_eq!(hits.len(), 4);
    assert_eq!(hits[0].uri.path(), "/api/series/detail");
}

struct DefaultSelectedHook { detail_calls: std::sync::Mutex<Vec<String>> }

#[async_trait::async_trait]
impl CspSite for DefaultSelectedHook {
    fn class(&self) -> &'static str { "FixtureDefaultSelectedHook" }
    fn supports_search(&self) -> bool { false }
    async fn home(&self, _ext: &str) -> Result<CspHome, String> { Err("unused".into()) }
    async fn list(&self, _id: &str, _page: u32, _ext: &str) -> Result<CspList, String> { Err("unused".into()) }
    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> { Err("unused".into()) }
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        self.detail_calls.lock().unwrap().push(id.to_string());
        Ok(CspDetail { id: id.into(), title: "Fixture".into(), cover: None, description: None,
            episodes: vec![CspEpisode { id: "fixture|selected".into(), title: "Episode 2".into(), flag: "line".into() }] })
    }
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        assert_eq!(id, "fixture|selected");
        Ok(vec![CspPlay { url: "https://media.invalid/default.mp4".into(), headers: Vec::new(), label: None }])
    }
}

#[tokio::test]
async fn default_source_hook_keeps_the_previous_bare_selection_behavior() {
    let site = Arc::new(DefaultSelectedHook { detail_calls: std::sync::Mutex::new(Vec::new()) });
    assert!(!site.accepts_selected_episode_id("bare-selection"));
    assert!(!crate::csp::app_rj::AppRJ::new().accepts_selected_episode_id("bare-selection"));
    let provider = crate::csp::provider::CspProvider::for_test("default-hook", site.clone(), "");
    let request = PlayRequest { episode_id: Some("bare-selection".into()), episode_title: Some("Episode 2".into()), ..Default::default() };
    let plays = provider.resolve(&MediaId::new("default-hook", "content-id"), &request).await.unwrap();
    assert_eq!(plays[0].url, "https://media.invalid/default.mp4");
    assert_eq!(*site.detail_calls.lock().unwrap(), ["bare-selection"]);
}

#[test]
fn hxq_structured_identity_keeps_selected_metadata_and_rejects_bad_payloads() {
    let id = selected_episode_id("content-id", "selected-pid", 2, "Episode 2", "selected-line");
    assert!(id.contains('|'));
    assert_eq!(selected_pid(&id, "selected-line").unwrap(), "selected-pid");
    assert!(selected_pid(&id, "different-line").is_err());
    assert!(selected_pid("hxq:v1|invalid-data", "").is_err());
    assert!(!Hxq::new().accepts_selected_episode_id("pid?token=private"));
}
