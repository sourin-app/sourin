//! Exact-identity refresh tests. Independent literal protobuf detail writer;
//! only synthetic loopback traffic, no account helper or returned-media fetch.
use super::*;
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    RwLock,
};

fn vi(out: &mut Vec<u8>, mut value: u64) {
    while value >= 128 {
        out.push((value as u8 & 127) | 128);
        value >>= 7;
    }
    out.push(value as u8);
}
fn num(out: &mut Vec<u8>, field: u64, value: u64) {
    vi(out, field << 3);
    vi(out, value);
}
fn blob(out: &mut Vec<u8>, field: u64, value: &[u8]) {
    vi(out, field << 3 | 2);
    vi(out, value.len() as u64);
    out.extend_from_slice(value);
}
fn episode(title: &str, path: &str, source: &str, line: &str, restricted: bool) -> Vec<u8> {
    let mut out = Vec::new();
    for (field, value) in [(2, title), (4, path), (9, source), (10, line)] {
        blob(&mut out, field, value.as_bytes());
    }
    if restricted {
        num(&mut out, 14, 1);
    }
    out
}
fn detail(mode: u8) -> Vec<u8> {
    let first = episode(
        "First",
        "https://media.invalid/first.mp4",
        "",
        "Line A",
        false,
    );
    let selected = episode(
        "Selected",
        if mode == 1 {
            "changed-opaque"
        } else {
            "opaque-selected|%2F+part"
        },
        if mode == 2 {
            "changed-source"
        } else {
            "source-b"
        },
        if mode == 3 { "Changed line" } else { "Line B" },
        mode == 4,
    );
    let direct = episode(
        "Direct",
        "https://media.invalid/direct.mp4",
        "",
        "Direct",
        false,
    );
    let mut inner = Vec::new();
    num(&mut inner, 4, if mode == 7 { 1002 } else { 1001 });
    blob(&mut inner, 9, b"Synthetic detail");
    if mode == 6 {
        num(&mut inner, 35, 1);
    }
    for row in if mode == 5 {
        vec![first, direct, selected]
    } else {
        vec![first, selected, direct]
    } {
        blob(&mut inner, 29, &row);
    }
    let mut out = Vec::new();
    num(&mut out, 1, 200);
    blob(&mut out, 3, &inner);
    out
}
struct RefreshFixture {
    origin: Fixture,
    proxy: Fixture,
    store: Arc<crate::proxy::ProxyStore>,
    ext: String,
    body: Arc<RwLock<Vec<u8>>>,
    zones: Arc<AtomicUsize>,
    details: Arc<AtomicUsize>,
    plays: Arc<AtomicUsize>,
    deny: Arc<AtomicBool>,
}
impl RefreshFixture {
    async fn new() -> Self {
        let origin = serve(|_| panic!("refresh must never fall back to origin")).await;
        let domain = origin.url.clone();
        let fixture = fixtures();
        let body = Arc::new(RwLock::new(detail(0)));
        let changed = body.clone();
        let zones = Arc::new(AtomicUsize::new(0));
        let z = zones.clone();
        let details = Arc::new(AtomicUsize::new(0));
        let d = details.clone();
        let plays = Arc::new(AtomicUsize::new(0));
        let p = plays.clone();
        let deny = Arc::new(AtomicBool::new(false));
        let denied = deny.clone();
        let proxy = serve(move |request| {
            assert!(!request.headers.contains_key("cookie"));
            assert!(!request.headers.contains_key("authorization"));
            match request.uri.path() {
                "/dispatch" => axum::Json(json!({"domain":domain,"enabled":true})).into_response(),
                ZONE => {
                    z.fetch_add(1, Ordering::SeqCst);
                    if denied.load(Ordering::SeqCst) {
                        StatusCode::FORBIDDEN.into_response()
                    } else {
                        unhex(fixture["zoneHex"].as_str().unwrap()).into_response()
                    }
                }
                DETAIL => {
                    d.fetch_add(1, Ordering::SeqCst);
                    assert_eq!(inspect_secure(&request, &fixture)["id"], "1001");
                    changed.read().unwrap().clone().into_response()
                }
                PLAY => {
                    p.fetch_add(1, Ordering::SeqCst);
                    let pairs = inspect_secure(&request, &fixture);
                    assert_eq!(pairs["vodPlayFrom"], "source-b");
                    assert_eq!(pairs["playUrl"], "opaque-selected|%2F+part");
                    unhex(fixture["playHex"].as_str().unwrap()).into_response()
                }
                _ => panic!("unexpected refresh request"),
            }
        })
        .await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let fixture = fixtures();
        let ext=json!({"host":origin.url,"site":format!("{}/dispatch",origin.url),
            "publicKey":fixture["rsaKeys"]["bootstrap"]["publicDerBase64"],"dataKey":fixture["dataKey"],"dataIv":fixture["dataIv"],
            "pkg":"synthetic.desktop.fixture","appName":"Synthetic desktop","version":"0.0.0"}).to_string();
        Self {
            origin,
            proxy,
            store,
            ext,
            body,
            zones,
            details,
            plays,
            deny,
        }
    }
    fn site(&self) -> ProtocolAppDrama {
        let site = ProtocolAppDrama::new();
        site.set_http_context(self.store.clone(), "refresh-fixture");
        site
    }
    async fn expire(&self, site: &ProtocolAppDrama) {
        site.session.lock().await.current.as_mut().unwrap().expires =
            Instant::now() - Duration::from_secs(1);
    }
    fn no_origin(&self) {
        assert!(self.origin.hits.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn expired_issued_opaque_and_direct_selections_refresh_same_identity_without_a_new_detail_click(
) {
    let fixture = RefreshFixture::new().await;
    let site = fixture.site();
    let original = site.detail("1001", &fixture.ext).await.unwrap();
    let selected = &original.episodes[1];
    fixture.expire(&site).await;
    assert_eq!(
        site.play("", &selected.id, &fixture.ext).await.unwrap()[0].url,
        "https://media.invalid/selected-2.m3u8"
    );
    assert_eq!(
        (
            fixture.zones.load(Ordering::SeqCst),
            fixture.details.load(Ordering::SeqCst),
            fixture.plays.load(Ordering::SeqCst)
        ),
        (2, 2, 1)
    );
    site.play("", &selected.id, &fixture.ext).await.unwrap();
    assert_eq!(fixture.details.load(Ordering::SeqCst), 2);
    fixture.expire(&site).await;
    let direct = &original.episodes[2];
    assert_eq!(
        site.play("", &direct.id, &fixture.ext).await.unwrap()[0].url,
        "https://media.invalid/direct.mp4"
    );
    assert_eq!(
        (
            fixture.zones.load(Ordering::SeqCst),
            fixture.details.load(Ordering::SeqCst),
            fixture.plays.load(Ordering::SeqCst)
        ),
        (3, 3, 2)
    );
    fixture.no_origin();
}

#[tokio::test]
async fn changed_exact_index_source_path_line_or_restriction_revokes_old_token_without_decoder_or_alternative(
) {
    for mode in 1..=7 {
        let fixture = RefreshFixture::new().await;
        let site = fixture.site();
        let original = site.detail("1001", &fixture.ext).await.unwrap();
        let selected = &original.episodes[1];
        *fixture.body.write().unwrap() = detail(mode);
        fixture.expire(&site).await;
        assert!(site
            .play(&selected.flag, &selected.id, &fixture.ext)
            .await
            .err()
            .unwrap()
            .starts_with("unsupported:"));
        assert_eq!(fixture.plays.load(Ordering::SeqCst), 0);
        assert_eq!(fixture.details.load(Ordering::SeqCst), 2);
        let before = fixture.proxy.hits.lock().unwrap().len();
        assert!(site.play("", &selected.id, &fixture.ext).await.is_err());
        assert_eq!(
            fixture.proxy.hits.lock().unwrap().len(),
            before,
            "revoked token cannot repeatedly request an alternative"
        );
        fixture.no_origin();
    }
}

#[tokio::test]
async fn stale_cross_ext_or_route_never_refreshes_and_denied_refresh_keeps_bounded_cooldown() {
    let fixture = RefreshFixture::new().await;
    let site = fixture.site();
    let original = site.detail("1001", &fixture.ext).await.unwrap();
    let selected = &original.episodes[1];
    fixture.expire(&site).await;
    let before = fixture.proxy.hits.lock().unwrap().len();
    assert!(site
        .play("", &selected.id, &format!("{} ", fixture.ext))
        .await
        .is_err());
    assert_eq!(fixture.proxy.hits.lock().unwrap().len(), before);
    fixture.deny.store(true, Ordering::SeqCst);
    assert!(site
        .play("", &selected.id, &fixture.ext)
        .await
        .err()
        .unwrap()
        .contains("HTTP 403"));
    assert!(site.play("", &selected.id, &fixture.ext).await.is_err());
    assert_eq!(fixture.zones.load(Ordering::SeqCst), 2);
    site.session.lock().await.cooldown.as_mut().unwrap().until =
        Instant::now() - Duration::from_secs(1);
    fixture.deny.store(false, Ordering::SeqCst);
    site.play("", &selected.id, &fixture.ext).await.unwrap();
    assert_eq!(
        (
            fixture.zones.load(Ordering::SeqCst),
            fixture.details.load(Ordering::SeqCst),
            fixture.plays.load(Ordering::SeqCst)
        ),
        (3, 2, 1)
    );
    let before = fixture.proxy.hits.lock().unwrap().len();
    custom(&fixture.store, &fixture.proxy.url);
    assert!(site.play("", &selected.id, &fixture.ext).await.is_err());
    assert_eq!(fixture.proxy.hits.lock().unwrap().len(), before);
    fixture.no_origin();
}
