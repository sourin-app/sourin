//! Loopback state-race tests; no native media or account access.
use super::*;
use crate::csp::http_context::test_support::{custom, serve, Fixture};
use axum::{
    body::Body,
    response::{IntoResponse, Response},
};
use std::{
    future::Future,
    pin::Pin,
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    task::{Context, Poll},
};

struct OneChunk {
    future: Pin<Box<dyn Future<Output = Vec<u8>> + Send>>,
    done: bool,
}
impl futures_core::Stream for OneChunk {
    type Item = std::result::Result<bytes::Bytes, std::convert::Infallible>;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let stream = self.get_mut();
        if stream.done {
            return Poll::Ready(None);
        }
        match stream.future.as_mut().poll(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(bytes) => {
                stream.done = true;
                Poll::Ready(Some(Ok(bytes.into())))
            }
        }
    }
}
fn gated(
    bytes: Vec<u8>,
    entered: Arc<tokio::sync::Notify>,
    release: Arc<tokio::sync::Notify>,
) -> Response {
    Response::new(Body::from_stream(OneChunk {
        future: Box::pin(async move {
            entered.notify_one();
            release.notified().await;
            bytes
        }),
        done: false,
    }))
}
fn fixture_data() -> Value {
    serde_json::from_str(include_str!("app_drama_synthetic_fixtures.json")).unwrap()
}
fn unhex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&s[at..at + 2], 16).unwrap())
        .collect()
}
struct StateFixture {
    origin: Fixture,
    proxy: Fixture,
    store: Arc<crate::proxy::ProxyStore>,
    ext: String,
    home_mode: Arc<AtomicUsize>,
    hold_home: Arc<AtomicBool>,
    hold_detail: Arc<AtomicBool>,
    entered: Arc<tokio::sync::Notify>,
    release: Arc<tokio::sync::Notify>,
    zones: Arc<AtomicUsize>,
    homes: Arc<AtomicUsize>,
    details: Arc<AtomicUsize>,
}
impl StateFixture {
    async fn new() -> Self {
        let origin = serve(|_| panic!("state test cannot fall back to origin")).await;
        let domain = origin.url.clone();
        let data = fixture_data();
        let home_mode = Arc::new(AtomicUsize::new(0));
        let hm = home_mode.clone();
        let hold_home = Arc::new(AtomicBool::new(false));
        let hh = hold_home.clone();
        let hold_detail = Arc::new(AtomicBool::new(false));
        let hd = hold_detail.clone();
        let entered = Arc::new(tokio::sync::Notify::new());
        let en = entered.clone();
        let release = Arc::new(tokio::sync::Notify::new());
        let re = release.clone();
        let zones = Arc::new(AtomicUsize::new(0));
        let z = zones.clone();
        let homes = Arc::new(AtomicUsize::new(0));
        let h = homes.clone();
        let details = Arc::new(AtomicUsize::new(0));
        let d = details.clone();
        let proxy = serve(move |request| match request.uri.path() {
            "/dispatch" => axum::Json(json!({"domain":domain,"enabled":true})).into_response(),
            ZONE => {
                z.fetch_add(1, Ordering::SeqCst);
                unhex(data["zoneHex"].as_str().unwrap()).into_response()
            }
            "/api/v3/drama/getCategory" => {
                h.fetch_add(1, Ordering::SeqCst);
                let bytes = if hm.load(Ordering::SeqCst) == 1 {
                    b"malformed category JSON".to_vec()
                } else {
                    serde_json::to_vec(&data["categoryJson"]).unwrap()
                };
                if hh.swap(false, Ordering::SeqCst) {
                    gated(bytes, en.clone(), re.clone())
                } else {
                    bytes.into_response()
                }
            }
            DETAIL => {
                d.fetch_add(1, Ordering::SeqCst);
                let bytes = unhex(data["detailHex"].as_str().unwrap());
                if hd.swap(false, Ordering::SeqCst) {
                    gated(bytes, en.clone(), re.clone())
                } else {
                    bytes.into_response()
                }
            }
            PLAY => unhex(data["playHex"].as_str().unwrap()).into_response(),
            _ => panic!("unexpected state request"),
        })
        .await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let data = fixture_data();
        let ext=json!({"site":format!("{}/dispatch",origin.url),"publicKey":data["rsaKeys"]["bootstrap"]["publicDerBase64"],
            "dataKey":data["dataKey"],"dataIv":data["dataIv"],"pkg":"synthetic.desktop.fixture","appName":"Synthetic desktop","version":"0.0.0"}).to_string();
        Self {
            origin,
            proxy,
            store,
            ext,
            home_mode,
            hold_home,
            hold_detail,
            entered,
            release,
            zones,
            homes,
            details,
        }
    }
    fn site(&self) -> Arc<ProtocolAppDrama> {
        let site = Arc::new(ProtocolAppDrama::new());
        site.set_http_context(self.store.clone(), "state-fixture");
        site
    }
    fn no_origin(&self) {
        assert!(self.origin.hits.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn a_delayed_old_home_body_cannot_succeed_after_same_route_generation_replacement() {
    let fixture = StateFixture::new().await;
    let site = fixture.site();
    fixture.hold_home.store(true, Ordering::SeqCst);
    let old = {
        let site = site.clone();
        let ext = fixture.ext.clone();
        tokio::spawn(async move { site.home(&ext).await })
    };
    tokio::time::timeout(Duration::from_secs(2), fixture.entered.notified())
        .await
        .unwrap();
    let captured = site.session.lock().await.current.clone().unwrap();
    site.invalidate(&captured, &Failure::Transport).await;
    site.session.lock().await.cooldown.as_mut().unwrap().until =
        Instant::now() - Duration::from_secs(1);
    let cfg = Config::parse(&fixture.ext).unwrap();
    let new = site.session(&cfg, &fixture.ext).await.unwrap();
    assert_ne!(new.generation, captured.generation);
    fixture.release.notify_one();
    assert!(old.await.unwrap().is_err());
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
    assert!(site.home(&fixture.ext).await.is_ok());
    assert_eq!(fixture.zones.load(Ordering::SeqCst), 2);
    fixture.no_origin();
}

#[tokio::test]
async fn malformed_home_data_invalidates_only_its_captured_generation_and_observes_cooldown() {
    let fixture = StateFixture::new().await;
    let site = fixture.site();
    fixture.home_mode.store(1, Ordering::SeqCst);
    for _ in 0..3 {
        assert!(site
            .home(&fixture.ext)
            .await
            .err()
            .unwrap()
            .starts_with("parse:"));
    }
    assert_eq!(fixture.zones.load(Ordering::SeqCst), 1);
    assert_eq!(fixture.homes.load(Ordering::SeqCst), 1);
    site.session.lock().await.cooldown.as_mut().unwrap().until =
        Instant::now() - Duration::from_secs(1);
    fixture.home_mode.store(0, Ordering::SeqCst);
    assert!(site.home(&fixture.ext).await.is_ok());
    assert_eq!(fixture.zones.load(Ordering::SeqCst), 2);
    fixture.no_origin();
}

#[tokio::test]
async fn concurrent_expired_selection_revalidates_once_then_waiter_uses_the_refreshed_anchor() {
    let fixture = StateFixture::new().await;
    let site = fixture.site();
    let detail = site.detail("1001", &fixture.ext).await.unwrap();
    let selected = &detail.episodes[1];
    site.session.lock().await.current.as_mut().unwrap().expires =
        Instant::now() - Duration::from_secs(1);
    fixture.hold_detail.store(true, Ordering::SeqCst);
    let first = {
        let site = site.clone();
        let ext = fixture.ext.clone();
        let id = selected.id.clone();
        tokio::spawn(async move { site.play("", &id, &ext).await })
    };
    tokio::time::timeout(Duration::from_secs(2), fixture.entered.notified())
        .await
        .unwrap();
    let mut second = {
        let site = site.clone();
        let ext = fixture.ext.clone();
        let id = selected.id.clone();
        tokio::spawn(async move { site.play("", &id, &ext).await })
    };
    assert!(
        tokio::time::timeout(Duration::from_millis(120), &mut second)
            .await
            .is_err(),
        "waiter cannot run its own duplicate revalidation"
    );
    fixture.release.notify_one();
    assert!(first.await.unwrap().is_ok());
    assert!(second.await.unwrap().is_ok());
    assert_eq!(
        fixture.details.load(Ordering::SeqCst),
        2,
        "original detail plus one exact refresh"
    );
    fixture.no_origin();
}
