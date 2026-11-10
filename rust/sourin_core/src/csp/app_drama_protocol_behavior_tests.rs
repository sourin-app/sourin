//! Public AppDrama behavior tests against an independent loopback fixture.
//! Responses/goldens are Python-generated synthetic
//! data, never saved server responses. All request HTTP is strict loopback.
use crate::csp::{app_drama::AppDrama as ProtocolAppDrama, CspSite};
use serde_json::{json, Value};
use std::sync::Arc;
const ZONE: &str = "/api/v5/find/app/zone";
const LIST: &str = "/api/proto/v5/drama/category";
const SEARCH: &str = "/api/proto/v5/drama/search";
const DETAIL: &str = "/api/proto/v5/drama/getDetail";
const PLAY: &str = "/api/proto/v5/videoUsableUrl";
use crate::csp::http_context::test_support::{custom, serve, Fixture, Request};
use aes::cipher::{block_padding::Pkcs7, BlockDecrypt, BlockDecryptMut, KeyInit, KeyIvInit};
use axum::{
    http::{Method, StatusCode},
    response::IntoResponse,
};
use rsa::{pkcs8::DecodePrivateKey, Pkcs1v15Encrypt, RsaPrivateKey};

fn fixtures() -> Value {
    serde_json::from_str(include_str!("app_drama_synthetic_fixtures.json")).unwrap()
}
fn decode64(value: &str) -> Vec<u8> {
    crate::csp::shared::b64_decode(value).unwrap()
}
fn unhex(value: &str) -> Vec<u8> {
    assert_eq!(value.len() % 2, 0);
    (0..value.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&value[at..at + 2], 16).unwrap())
        .collect()
}
fn hex(value: &[u8]) -> String {
    value.iter().map(|byte| format!("{byte:02x}")).collect()
}

// Independent fixture scanner, not the candidate Message reader/serializer.
fn sent_fields(input: &[u8]) -> Vec<(u64, u8, Vec<u8>)> {
    fn read(input: &[u8], at: &mut usize) -> u64 {
        let mut value = 0u64;
        for shift in (0..70).step_by(7) {
            let byte = input[*at];
            *at += 1;
            value |= u64::from(byte & 127) << shift;
            if byte & 128 == 0 {
                return value;
            }
        }
        panic!("fixture varint overflow")
    }
    let mut at = 0;
    let mut out = Vec::new();
    while at < input.len() {
        let tag = read(input, &mut at);
        let wire = (tag & 7) as u8;
        let value = match wire {
            0 => read(input, &mut at).to_le_bytes().to_vec(),
            2 => {
                let size = read(input, &mut at) as usize;
                let bytes = input[at..at + size].to_vec();
                at += size;
                bytes
            }
            _ => panic!("unexpected request wire"),
        };
        out.push((tag >> 3, wire, value));
    }
    out
}
fn sent_text(fields: &[(u64, u8, Vec<u8>)], number: u64) -> String {
    let (_, wire, bytes) = fields
        .iter()
        .find(|(field, _, _)| *field == number)
        .unwrap();
    assert_eq!(*wire, 2);
    String::from_utf8(bytes.clone()).unwrap()
}
fn sent_number(fields: &[(u64, u8, Vec<u8>)], number: u64) -> u64 {
    let (_, wire, bytes) = fields
        .iter()
        .find(|(field, _, _)| *field == number)
        .unwrap();
    assert_eq!(*wire, 0);
    u64::from_le_bytes(bytes.as_slice().try_into().unwrap())
}
fn nonce_shape(value: &str, size: usize) {
    assert_eq!(value.len(), size);
    assert!(value.ends_with('='));
    assert!(value[..size - 1]
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric()));
}
fn private(fixture: &Value, kind: &str) -> RsaPrivateKey {
    RsaPrivateKey::from_pkcs8_der(&decode64(
        fixture["rsaKeys"][kind]["privateDerBase64"]
            .as_str()
            .unwrap(),
    ))
    .unwrap()
}
fn decrypt_ecb(key: &[u8], data: &[u8]) -> Vec<u8> {
    assert_eq!(key.len(), 32);
    assert_eq!(data.len() % 16, 0);
    let cipher = aes::Aes256::new_from_slice(key).unwrap();
    let mut data = data.to_vec();
    for chunk in data.chunks_mut(16) {
        cipher.decrypt_block(aes::cipher::Block::<aes::Aes256>::from_mut_slice(chunk));
    }
    let padding = *data.last().unwrap() as usize;
    assert!((1..=16).contains(&padding));
    assert!(data[data.len() - padding..]
        .iter()
        .all(|byte| *byte as usize == padding));
    data.truncate(data.len() - padding);
    data
}
fn inspect_headers(request: &Request, fixture: &Value, kind: &str, proto: bool) {
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    assert_eq!(request.headers["user-agent"], "okhttp/3.12.1");
    let outer: Value =
        serde_json::from_str(request.headers["publicParams"].to_str().unwrap()).unwrap();
    assert_eq!(outer.as_object().unwrap().len(), 1);
    let mut cipher = unhex(outer["paramsData"].as_str().unwrap());
    let key = fixture["headerKeyIv"].as_str().unwrap().as_bytes();
    let decoded = cbc::Decryptor::<aes::Aes128>::new_from_slices(key, key)
        .unwrap()
        .decrypt_padded_mut::<Pkcs7>(&mut cipher)
        .unwrap();
    let descriptor: Value = serde_json::from_slice(decoded).unwrap();
    assert_eq!(descriptor["plat"], std::env::consts::OS);
    assert_eq!(descriptor["pkg"], "synthetic.desktop.fixture");
    assert_eq!(descriptor["vApp"], "000");
    assert!(descriptor.get("androidID").is_none());
    assert!(descriptor.get("cpuId").is_none());
    assert!(descriptor.get("mac").is_none());
    if proto {
        assert_eq!(request.headers["accept"], "application/x-protobuf");
        assert_eq!(request.headers["content-type"], "application/x-protobuf");
        let time = descriptor["timestamp"].as_u64().unwrap();
        let random = descriptor["random_str"].as_str().unwrap();
        nonce_shape(random, 16);
        let sign = decode64(descriptor["sig"].as_str().unwrap());
        assert_eq!(
            private(fixture, kind)
                .decrypt(Pkcs1v15Encrypt, &sign)
                .unwrap(),
            format!("{time}{random}000").as_bytes()
        );
        let aes = decode64(&format!(
            "{}{}",
            descriptor["sig2"].as_str().unwrap(),
            descriptor["sig3"].as_str().unwrap()
        ));
        assert_eq!(
            decrypt_ecb(fixture["dataIv"].as_str().unwrap().as_bytes(), &aes),
            format!("{time}{random}").as_bytes()
        );
    } else {
        assert_eq!(
            request.headers["content-type"],
            "application/json; charset=utf-8"
        );
        for name in ["sig", "sig2", "sig3", "random_str", "timestamp"] {
            assert!(descriptor.get(name).is_none());
        }
    }
}
fn inspect_secure(request: &Request, fixture: &Value) -> std::collections::HashMap<String, String> {
    let fields = sent_fields(&request.body);
    assert_eq!(fields.len(), 5);
    let time = sent_number(&fields, 4);
    let random = sent_text(&fields, 5);
    nonce_shape(&random, 8);
    nonce_shape(&sent_text(&fields, 3), 20);
    let joined = format!("{}{}", sent_text(&fields, 1), sent_text(&fields, 2));
    assert_eq!(sent_text(&fields, 1).len(), 20);
    assert!(joined.starts_with(&random));
    let text = String::from_utf8(decrypt_ecb(
        fixture["dataKey"].as_str().unwrap().as_bytes(),
        &decode64(&joined[8..]),
    ))
    .unwrap();
    let pairs = text.strip_suffix(&time.to_string()).unwrap();
    pairs
        .split('&')
        .map(|pair| {
            let (key, value) = pair.split_once('=').unwrap();
            (key.into(), value.into())
        })
        .collect()
}

#[derive(Clone, Copy)]
enum ResponseMode {
    Normal,
    DeniedZone,
    InvalidZone,
    RestrictedDetail,
    DeniedPlay,
}
struct LocalFixture {
    origin: Fixture,
    proxy: Fixture,
    store: Arc<crate::proxy::ProxyStore>,
    ext: String,
}
impl LocalFixture {
    async fn new(mode: ResponseMode) -> Self {
        let origin = serve(|_| panic!("application proxy must never fall back to origin")).await;
        let fixture = fixtures();
        let domain = origin.url.clone();
        let proxy = serve(move |request| {
            if request.uri.path() == "/dispatch" {
                assert_eq!(request.method, Method::GET);
                assert!(!request.headers.contains_key("cookie"));
                assert!(!request.headers.contains_key("authorization"));
                return axum::Json(json!({"domain":domain,"enabled":true})).into_response();
            }
            if request.uri.path() == ZONE {
                assert_eq!(request.method, Method::POST);
                if matches!(mode, ResponseMode::DeniedZone) {
                    return StatusCode::FORBIDDEN.into_response();
                }
                inspect_headers(&request, &fixture, "bootstrap", true);
                let fields = sent_fields(&request.body);
                let time = sent_number(&fields, 1);
                let random = sent_text(&fields, 4);
                nonce_shape(&random, 16);
                nonce_shape(&sent_text(&fields, 3), 16);
                nonce_shape(&sent_text(&fields, 5), 16);
                assert_eq!(
                    private(&fixture, "bootstrap")
                        .decrypt(Pkcs1v15Encrypt, &decode64(&sent_text(&fields, 2)))
                        .unwrap(),
                    format!("{time}{random}").as_bytes()
                );
                let key = if matches!(mode, ResponseMode::InvalidZone) {
                    "badZoneHex"
                } else {
                    "zoneHex"
                };
                return unhex(fixture[key].as_str().unwrap()).into_response();
            }
            if request.uri.path() == "/api/v3/drama/getCategory" {
                assert_eq!(request.method, Method::GET);
                assert_eq!(request.uri.query(), Some("orderBy=type_id"));
                inspect_headers(&request, &fixture, "derived", false);
                return axum::Json(fixture["categoryJson"].clone()).into_response();
            }
            inspect_headers(&request, &fixture, "derived", true);
            let pairs = inspect_secure(&request, &fixture);
            let response_key = match request.uri.path() {
                LIST => {
                    assert_eq!(pairs["typeId1"], "cat-one");
                    assert_eq!(pairs["page"], "2");
                    assert_eq!(pairs["pagesize"], "21");
                    assert_eq!(pairs["vodOrderBy"], "最新");
                    "pageHex"
                }
                SEARCH => {
                    assert_eq!(pairs["searchKeys"], "synthetic-query");
                    "pageHex"
                }
                DETAIL => {
                    assert_eq!(pairs["id"], "1001");
                    if matches!(mode, ResponseMode::RestrictedDetail) {
                        "restrictedDetailHex"
                    } else {
                        "detailHex"
                    }
                }
                PLAY => {
                    assert_eq!(pairs["vodPlayFrom"], "source-b");
                    assert_eq!(pairs["playUrl"], "opaque-selected|%2F+part");
                    if matches!(mode, ResponseMode::DeniedPlay) {
                        return StatusCode::FORBIDDEN.into_response();
                    }
                    "playHex"
                }
                _ => panic!("unexpected protocol operation"),
            };
            unhex(fixture[response_key].as_str().unwrap()).into_response()
        })
        .await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let data = fixtures();
        let ext = json!({"host":origin.url,"site":format!("{}/dispatch",origin.url),"publicKey":data["rsaKeys"]["bootstrap"]["publicDerBase64"],
            "dataKey":data["dataKey"],"dataIv":data["dataIv"],"pkg":"synthetic.desktop.fixture",
            "appName":"Synthetic desktop","version":"0.0.0"}).to_string();
        Self {
            origin,
            proxy,
            store,
            ext,
        }
    }
    fn site(&self) -> ProtocolAppDrama {
        let site = ProtocolAppDrama::new();
        site.set_http_context(self.store.clone(), "app-drama-fixture");
        site
    }
    fn assert_proxy_only(&self) {
        assert!(self.origin.hits.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn app_drama_candidate_default_bootstrap_catalog_detail_and_exact_selected_play_are_real_http(
) {
    let fixture = LocalFixture::new(ResponseMode::Normal).await;
    let site = fixture.site();
    assert_eq!(
        site.home(&fixture.ext).await.unwrap().categories[0].id,
        "cat-one"
    );
    assert_eq!(
        site.list("cat-one", 2, &fixture.ext).await.unwrap().items[0].id,
        "1001"
    );
    assert_eq!(
        site.search("synthetic-query", 1, &fixture.ext)
            .await
            .unwrap()
            .items[0]
            .id,
        "1001"
    );
    let detail = site.detail("1001", &fixture.ext).await.unwrap();
    assert_eq!(detail.episodes.len(), 3);
    let selected = &detail.episodes[1];
    let plays = site
        .play(&selected.flag, &selected.id, &fixture.ext)
        .await
        .unwrap();
    assert_eq!(plays[0].url, "https://media.invalid/selected-2.m3u8");
    assert!(plays[0]
        .headers
        .contains(&("User-Agent".into(), "SyntheticMedia/1".into())));
    assert!(site
        .play("Wrong line", &selected.id, &fixture.ext)
        .await
        .is_err());
    let before = fixture.proxy.hits.lock().unwrap().len();
    let direct = &detail.episodes[2];
    assert_eq!(
        site.play(&direct.flag, &direct.id, &fixture.ext)
            .await
            .unwrap()[0]
            .url,
        "https://media.invalid/direct.mp4"
    );
    assert_eq!(fixture.proxy.hits.lock().unwrap().len(), before);
    let hits = fixture.proxy.hits.lock().unwrap();
    assert_eq!(hits.iter().filter(|hit| hit.uri.path() == ZONE).count(), 1);
    assert_eq!(hits.iter().filter(|hit| hit.uri.path() == PLAY).count(), 1);
    assert_eq!(
        hits.len(),
        7,
        "dispatch, bootstrap and five actual content calls; no media fetch/account request"
    );
    fixture.assert_proxy_only();
}

#[tokio::test]
async fn app_drama_candidate_provider_bridge_keeps_the_exact_selected_versioned_recipe() {
    use crate::{
        model::{MediaId, PlayRequest},
        provider::MediaProvider,
    };
    let fixture = LocalFixture::new(ResponseMode::Normal).await;
    let provider = crate::csp::provider::CspProvider::for_test(
        "drama-provider-fixture",
        Arc::new(fixture.site()),
        &fixture.ext,
    );
    let id = MediaId::new("drama-provider-fixture", "1001");
    let detail = provider.detail(&id).await.unwrap();
    let selected = &detail.episodes[1];
    let request = PlayRequest {
        episode_id: Some(selected.id.clone()),
        flag: Some(selected.flag.clone()),
        episode_title: Some(selected.title.clone()),
        episode_order: Some(2),
        ..Default::default()
    };
    let media = provider.resolve(&id, &request).await.unwrap();
    assert_eq!(media[0].url, "https://media.invalid/selected-2.m3u8");
    assert!(media[0]
        .headers
        .contains(&("User-Agent".into(), "SyntheticMedia/1".into())));
    let hits = fixture.proxy.hits.lock().unwrap();
    assert_eq!(
        hits.iter()
            .filter(|request| request.uri.path() == DETAIL)
            .count(),
        1,
        "versioned selected recipe must not be mistaken for a bare detail id"
    );
    assert_eq!(
        hits.iter()
            .filter(|request| request.uri.path() == PLAY)
            .count(),
        1
    );
    fixture.assert_proxy_only();
}

#[tokio::test]
async fn app_drama_candidate_denied_or_malformed_bootstrap_stops_without_catalog_fallback() {
    for mode in [ResponseMode::DeniedZone, ResponseMode::InvalidZone] {
        let fixture = LocalFixture::new(mode).await;
        let result = fixture.site().home(&fixture.ext).await;
        assert!(result.is_err());
        let error = result.err().unwrap();
        assert!(!error.contains(&fixture.origin.url));
        assert!(!error.contains("publicParams"));
        assert_eq!(fixture.proxy.hits.lock().unwrap().len(), 2);
        fixture.assert_proxy_only();
    }
}

#[tokio::test]
async fn app_drama_candidate_restriction_and_parser_access_denial_never_switch_episodes() {
    let restricted = LocalFixture::new(ResponseMode::RestrictedDetail).await;
    let site = restricted.site();
    let detail = site.detail("1001", &restricted.ext).await.unwrap();
    let selected = &detail.episodes[0];
    assert!(site
        .play(&selected.flag, &selected.id, &restricted.ext)
        .await
        .is_err());
    assert!(!restricted
        .proxy
        .hits
        .lock()
        .unwrap()
        .iter()
        .any(|hit| hit.uri.path() == PLAY));
    restricted.assert_proxy_only();
    let denied = LocalFixture::new(ResponseMode::DeniedPlay).await;
    let site = denied.site();
    let detail = site.detail("1001", &denied.ext).await.unwrap();
    let selected = &detail.episodes[1];
    let error = site
        .play(&selected.flag, &selected.id, &denied.ext)
        .await
        .err()
        .unwrap();
    assert!(error.contains("HTTP 403"));
    assert!(!error.contains("重试"));
    assert_eq!(
        denied
            .proxy
            .hits
            .lock()
            .unwrap()
            .iter()
            .filter(|hit| hit.uri.path() == PLAY)
            .count(),
        1
    );
    denied.assert_proxy_only();
}

#[tokio::test]
async fn app_drama_candidate_live_policy_change_reinitializes_on_new_proxy_without_origin_fallback()
{
    let first = LocalFixture::new(ResponseMode::Normal).await;
    let second = LocalFixture::new(ResponseMode::Normal).await;
    let site = first.site();
    site.home(&first.ext).await.unwrap();
    custom(&first.store, &second.proxy.url);
    site.home(&first.ext).await.unwrap();
    assert_eq!(first.proxy.hits.lock().unwrap().len(), 3);
    assert_eq!(
        second.proxy.hits.lock().unwrap().len(),
        3,
        "new route performs its own dispatch, zone and categories"
    );
    first.assert_proxy_only();
    second.assert_proxy_only();
}
