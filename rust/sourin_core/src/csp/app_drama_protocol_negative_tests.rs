//! Additional v2 negatives. Own literal response/varint fixtures; never invokes
//! production account/cloud resolvers and never fetches returned media URLs.
use super::*;
use crate::csp::http_context::test_support::{custom, serve, Fixture};
use axum::{http::StatusCode, response::IntoResponse};
use std::sync::atomic::{AtomicUsize, Ordering};

fn data() -> Value {
    serde_json::from_str(include_str!("app_drama_synthetic_fixtures.json")).unwrap()
}
fn unhex(value: &str) -> Vec<u8> {
    (0..value.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&value[at..at + 2], 16).unwrap())
        .collect()
}
// Deliberately separate simple fixture writer, not candidate wire::bytes/text.
fn field(number: u8, bytes: &[u8]) -> Vec<u8> {
    assert!(number < 16 && bytes.len() < 128);
    let mut result = vec![(number << 3) | 2, bytes.len() as u8];
    result.extend_from_slice(bytes);
    result
}
fn media_response(url: &str) -> Vec<u8> {
    field(3, &field(1, url.as_bytes()))
}

struct NegativeFixture {
    origin: Fixture,
    proxy: Fixture,
    store: Arc<crate::proxy::ProxyStore>,
    ext: String,
    zones: Arc<AtomicUsize>,
}
impl NegativeFixture {
    async fn new(denied_zone: bool, returned_media: Option<&'static str>) -> Self {
        let origin = serve(|_| panic!("negative test must never fall back to origin")).await;
        let domain = origin.url.clone();
        let fixture = data();
        let zones = Arc::new(AtomicUsize::new(0));
        let count = zones.clone();
        let proxy = serve(move |request| {
            assert!(!request.headers.contains_key("cookie"));
            assert!(!request.headers.contains_key("authorization"));
            match request.uri.path() {
                "/dispatch" => axum::Json(json!({"domain":domain,"enabled":true})).into_response(),
                ZONE => {
                    count.fetch_add(1, Ordering::SeqCst);
                    if denied_zone {
                        StatusCode::FORBIDDEN.into_response()
                    } else {
                        unhex(fixture["zoneHex"].as_str().unwrap()).into_response()
                    }
                }
                "/api/v3/drama/getCategory" => {
                    axum::Json(fixture["categoryJson"].clone()).into_response()
                }
                DETAIL => unhex(fixture["detailHex"].as_str().unwrap()).into_response(),
                PLAY => returned_media
                    .map(media_response)
                    .unwrap_or_else(|| unhex(fixture["playHex"].as_str().unwrap()))
                    .into_response(),
                _ => panic!("unexpected negative-fixture operation"),
            }
        })
        .await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let fixture = data();
        let ext=json!({"host":origin.url,"site":format!("{}/dispatch",origin.url),
            "publicKey":fixture["rsaKeys"]["bootstrap"]["publicDerBase64"],"dataKey":fixture["dataKey"],"dataIv":fixture["dataIv"],
            "pkg":"synthetic.desktop.fixture","appName":"Synthetic desktop","version":"0.0.0"}).to_string();
        Self {
            origin,
            proxy,
            store,
            ext,
            zones,
        }
    }
    fn site(&self) -> ProtocolAppDrama {
        let site = ProtocolAppDrama::new();
        site.set_http_context(self.store.clone(), "negative-fixture");
        site
    }
    fn no_origin(&self) {
        assert!(self.origin.hits.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn v2_all_production_known_share_families_are_stopped_before_return_or_account_promotion() {
    for url in [
        "https://pan.baidu.com/s/1Fixture",
        "https://pan.xunlei.com/s/fixture",
        "https://www.alipan.com/s/fixture",
        "https://123pan.com/s/fixture",
        "https://115.com/s/fixture",
        "https://cloud.189.cn/t/fixture",
        "https://pan.quark.cn/s/fixture",
        "https://drive.uc.cn/s/fixture",
        "https://app.guangyapan.com/pan",
    ] {
        assert!(
            public_media(url).is_err(),
            "production-recognized share must not leave site.play"
        );
    }
    assert!(
        public_media("https://pan.baidu.com.evil.invalid/video.mp4").is_ok(),
        "exact production host matching retained"
    );
    let fixture = NegativeFixture::new(false, Some("https://pan.baidu.com/s/1Fixture")).await;
    let site = fixture.site();
    let detail = site.detail("1001", &fixture.ext).await.unwrap();
    let episode = &detail.episodes[1];
    let result = site.play(&episode.flag, &episode.id, &fixture.ext).await;
    assert!(result.is_err());
    assert!(result.err().unwrap().starts_with("unsupported:"));
    assert_eq!(
        fixture
            .proxy
            .hits
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.uri.path() == PLAY)
            .count(),
        1
    );
    fixture.no_origin();
    // Deliberately do not call provider.resolve on a failed candidate: if this
    // guard regresses the test must fail without invoking a real cloud helper.
}

#[test]
fn v2_signed_int32_total_and_ids_reject_negative_or_overflow_without_panicking() {
    let negative =
        wire::Message::parse(b"\x80\x01\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01").unwrap();
    assert_eq!(negative.int32(16).unwrap(), Some(-1));
    assert!(wire::checked_page_total(negative.int32(16).unwrap()).is_err());
    let too_large = wire::Message::parse(b"\x80\x01\x80\x80\x80\x80\x08").unwrap();
    assert!(too_large.int32(16).is_err());
    let (total, pages) = wire::checked_page_total(Some(i32::MAX)).unwrap();
    assert_eq!(total, Some(2_147_483_647));
    assert_eq!(pages, Some(102_261_127));
    assert_eq!(wire::checked_page_total(Some(0)).unwrap(), (None, None));
    assert!(list_from(
        b"\x0a\x07\x18\x01\x2a\x03abc\x80\x01\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01",
        1
    )
    .is_err());
}

#[test]
fn v2_wrong_wires_duplicate_messages_field_count_and_body_size_fail_closed() {
    let total_fixed = Message::parse(b"\x85\x01\x00\x00\x00\x00").unwrap();
    assert!(total_fixed.int32(16).is_err());
    let vip_fixed = Message::parse(b"\x75\x00\x00\x00\x00").unwrap();
    assert!(vip_fixed.integer(14).is_err());
    let vip_mixed = Message::parse(b"\x75\x00\x00\x00\x00\x70\x00").unwrap();
    assert!(vip_mixed.integer(14).is_err());
    let duplicate_bytes = [
        field(2, &field(2, b"https://media.invalid/thumb.jpg")),
        field(2, &field(1, b"https://media.invalid/full.jpg")),
    ]
    .concat();
    let duplicate_cover = Message::parse(&duplicate_bytes).unwrap();
    assert_eq!(
        cover(&duplicate_cover).unwrap().as_deref(),
        Some("https://media.invalid/thumb.jpg"),
        "later path-only singular cover must merge without deleting earlier thumbnail"
    );
    let scalar = Message::parse(b"\x0a\x01a\x0a\x01b").unwrap();
    assert_eq!(scalar.string(1).unwrap(), Some("b"));
    let fixed_fields = b"\x0d\x00\x00\x00\x00".repeat(16385);
    assert!(Message::parse(&fixed_fields).is_err());
    assert!(Message::parse(&vec![0u8; wire::MAX_BODY + 1]).is_err());
    assert!(
        Message::parse(b"\x0b").is_err(),
        "proto3 groups remain unsupported"
    );
    assert!(wire::checked_public_key(&"A".repeat(4097)).is_err());
    assert!(checked_base("https://api.invalid/base?token=fixture").is_err());
    assert!(checked_base("https://api.invalid/base#fragment").is_err());
}

#[tokio::test]
async fn v2_issued_recipe_binds_source_ext_engine_exact_identity_and_restrictions() {
    let fixture = NegativeFixture::new(false, None).await;
    let site = fixture.site();
    let detail = site.detail("1001", &fixture.ext).await.unwrap();
    let direct = &detail.episodes[2];
    let before = fixture.proxy.hits.lock().unwrap().len();
    assert!(site
        .play(&direct.flag, &direct.id, &format!("{} ", fixture.ext))
        .await
        .is_err());
    assert!(
        fixture
            .site()
            .play(&direct.flag, &direct.id, &fixture.ext)
            .await
            .is_err(),
        "another engine did not issue this recipe"
    );
    let opaque = &detail.episodes[1];
    let original: Value = serde_json::from_slice(
        &wire::unb64(opaque.id.strip_prefix("app-drama:v2|").unwrap()).unwrap(),
    )
    .unwrap();
    for (key, value) in [
        ("content", json!("other")),
        ("index", json!(999)),
        ("source", json!("other")),
        ("value", json!("https://media.invalid/other.mp4")),
        ("restricted", json!(true)),
    ] {
        let mut edited = original.clone();
        edited[key] = value;
        let id = format!(
            "app-drama:v2|{}",
            wire::b64(&serde_json::to_vec(&edited).unwrap())
        );
        assert!(site.play(&opaque.flag, &id, &fixture.ext).await.is_err());
    }
    assert_eq!(
        fixture.proxy.hits.lock().unwrap().len(),
        before,
        "invalid selection sends no decoder/media/account request"
    );
    assert_eq!(
        site.play(&direct.flag, &direct.id, &fixture.ext)
            .await
            .unwrap()[0]
            .url,
        "https://media.invalid/direct.mp4"
    );
    fixture.no_origin();
}

#[tokio::test]
async fn v2_expired_session_revalidates_exact_issued_recipe_and_old_generation_cannot_send() {
    let fixture = NegativeFixture::new(false, None).await;
    let site = fixture.site();
    let detail = site.detail("1001", &fixture.ext).await.unwrap();
    let old = site.session.lock().await.current.clone().unwrap();
    site.home(&fixture.ext).await.unwrap();
    assert_eq!(fixture.zones.load(Ordering::SeqCst), 1);
    site.session.lock().await.current.as_mut().unwrap().expires =
        Instant::now() - Duration::from_secs(1);
    assert!(
        site.play(
            &detail.episodes[2].flag,
            &detail.episodes[2].id,
            &fixture.ext
        )
        .await
        .is_ok(),
        "expired key refreshes only the same issued direct episode identity"
    );
    site.home(&fixture.ext).await.unwrap();
    assert_eq!(fixture.zones.load(Ordering::SeqCst), 2);
    let new = site.session.lock().await.current.clone().unwrap();
    assert_ne!(old.generation, new.generation);
    let before = fixture.proxy.hits.lock().unwrap().len();
    let cfg = Config::parse(&fixture.ext).unwrap();
    assert!(
        site.call(&cfg, &old, PLAY, vec![]).await.is_err(),
        "captured old generation cannot refresh into a new selected request"
    );
    assert_eq!(
        fixture.proxy.hits.lock().unwrap().len(),
        before,
        "stale captured session sends no request"
    );
    site.invalidate(&old, &Failure::Transport).await;
    site.home(&fixture.ext).await.unwrap();
    assert_eq!(
        fixture.zones.load(Ordering::SeqCst),
        2,
        "late old failure cannot erase newer bootstrap"
    );
    assert_eq!(
        site.session
            .lock()
            .await
            .current
            .as_ref()
            .unwrap()
            .generation,
        new.generation
    );
    fixture.no_origin();
}

#[tokio::test]
async fn v2_failed_bootstrap_has_bounded_keyed_backoff_without_infinite_or_in_call_retry() {
    let failed = NegativeFixture::new(true, None).await;
    let site = failed.site();
    for _ in 0..3 {
        assert!(site
            .home(&failed.ext)
            .await
            .err()
            .unwrap()
            .contains("HTTP 403"));
    }
    assert_eq!(
        failed.zones.load(Ordering::SeqCst),
        1,
        "repeated callers within cooldown do not hammer zone"
    );
    assert_eq!(
        failed.proxy.hits.lock().unwrap().len(),
        2,
        "one dispatch and one zone; no automatic fallback"
    );
    site.session.lock().await.cooldown.as_mut().unwrap().until =
        Instant::now() - Duration::from_secs(1);
    assert!(site.home(&failed.ext).await.is_err());
    assert_eq!(failed.zones.load(Ordering::SeqCst), 2);
    let current = NegativeFixture::new(false, None).await;
    custom(&failed.store, &current.proxy.url);
    site.home(&failed.ext).await.unwrap();
    assert_eq!(
        current.zones.load(Ordering::SeqCst),
        1,
        "different live route not blocked by prior cooldown"
    );
    failed.no_origin();
    current.no_origin();
}

#[tokio::test]
async fn v2_issued_ledger_evicts_old_entries_with_bounded_payload_and_stable_uuid_format() {
    let fixture = NegativeFixture::new(false, None).await;
    let site = fixture.site();
    let detail = site.detail("1001", &fixture.ext).await.unwrap();
    let cfg = Config::parse(&fixture.ext).unwrap();
    let descriptor = ProtocolAppDrama::descriptor(&cfg).unwrap();
    let uuid = descriptor
        .iter()
        .find(|(key, _)| key == "uuid")
        .unwrap()
        .1
        .as_str()
        .unwrap();
    assert_eq!(uuid.len(), 32);
    assert_eq!(&uuid[12..13], "4");
    assert!(matches!(&uuid[16..17], "8" | "9" | "A" | "B"));
    // Make this capacity test independent of execution speed; expiry is tested
    // separately above. No production timer/limit is relaxed.
    let session = {
        let mut state = site.session.lock().await;
        let current = state.current.as_mut().unwrap();
        current.expires = Instant::now() + Duration::from_secs(3600);
        current.clone()
    };
    for index in 0..MAX_EPISODES {
        site.remember(
            &session,
            EpisodeRecipe {
                version: 2,
                content: "1001".into(),
                index,
                flag: "Line".into(),
                source: "a".into(),
                value: "https://media.invalid/fixture.mp4".into(),
                restricted: false,
                binding: format!("fixture-binding-{index}"),
            },
        )
        .await
        .unwrap();
    }
    let ledger = site.issued.lock().await;
    assert!(ledger.entries.len() <= MAX_EPISODES);
    assert!(ledger.bytes <= MAX_ISSUED_BYTES);
    assert!(!ledger.entries.contains_key(&detail.episodes[0].id));
    fixture.no_origin();
}
