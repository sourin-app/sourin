//! Independent loopback/real SQLite cover cases. These reference only baseline
//! production symbols and use no bootstrap, profile, account or plugin restore.
use super::{probe_cover, repair, CoverProbe};
use async_trait::async_trait;
use axum::{http::Uri, response::IntoResponse, routing::get};
use crate::{
    model::*, provider::MediaProvider, proxy::ProxyStore, registry::Registry,
    remote::RemoteHub, state::AppState, store::{Db, Favorite, HistoryEntry, Progress},
    streamproxy::StreamProxy,
};
use std::sync::{Arc, Mutex, RwLock, atomic::{AtomicBool, AtomicI64}};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const HTML: &[u8] = b"<html><body></body></html>";
const PNG: &[u8] = &[
    137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,32,0,0,0,48,8,2,0,0,0,
    255,206,239,56,0,0,0,98,73,68,65,84,120,156,99,84,14,157,203,64,75,192,68,83,211,
    25,70,45,32,2,140,198,1,65,48,26,68,3,31,68,44,184,36,118,6,206,34,213,44,247,
    245,105,152,130,163,145,76,16,140,6,17,65,48,26,68,4,193,104,16,17,4,163,65,68,
    16,140,6,17,65,48,26,68,4,193,104,16,141,128,32,98,28,237,198,14,255,72,102,26,
    181,128,16,160,121,16,1,0,72,237,5,139,37,191,209,101,0,0,0,0,73,69,78,68,174,66,96,130,
];

#[derive(Clone, Copy)]
enum RootBody { Html, Poster, Opaque, OverLimitHtml, Missing }

struct Fixture {
    base: String,
    hits: Arc<Mutex<Vec<String>>>,
    task: tokio::task::JoinHandle<()>,
}

impl Fixture {
    async fn new(mode: RootBody) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let hits = Arc::new(Mutex::new(Vec::new()));
        let observed = hits.clone();
        let app = axum::Router::new().fallback(get(move |uri: Uri| {
            let observed = observed.clone();
            async move {
                observed.lock().unwrap().push(uri.path().to_owned());
                if uri.path() == "/" && matches!(mode, RootBody::Missing) {
                    return (axum::http::StatusCode::NOT_FOUND, HTML).into_response();
                }
                let bytes = if uri.path() == "/" {
                    match mode {
                        RootBody::Html | RootBody::Missing => HTML.to_vec(),
                        RootBody::Poster => PNG.to_vec(),
                        RootBody::Opaque => b"opaque unrecognized fixture body".to_vec(),
                        RootBody::OverLimitHtml => {
                            let mut body = b"<html>".to_vec();
                            body.extend(std::iter::repeat(b' ').take(65_536));
                            body.extend_from_slice(b"</html>");
                            body
                        }
                    }
                } else { PNG.to_vec() };
                // Deliberately not authoritative: a root URL can contain PNG
                // even when this MIME claims text/html.
                ([(axum::http::header::CONTENT_TYPE, "text/html")], bytes).into_response()
            }
        }));
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
        Self { base, hits, task }
    }
    fn root(&self) -> String { format!("{}/", self.base) }
    fn poster(&self) -> String { format!("{}/poster", self.base) }
    fn requests(&self) -> usize { self.hits.lock().unwrap().len() }
}
impl Drop for Fixture {
    fn drop(&mut self) { self.task.abort(); }
}

fn state() -> AppState {
    let proxy = Arc::new(ProxyStore::new()); // Default is explicit direct.
    AppState {
        registry: Arc::new(Registry::new()),
        db: Arc::new(Db::in_memory().unwrap()),
        proxy: proxy.clone(),
        sync: tokio::sync::RwLock::new(None),
        device_id: "artwork-memory-fixture".into(),
        data_dir: std::path::PathBuf::from("unused-artwork-memory-fixture"),
        third_party: RwLock::new(Vec::new()),
        remote: Arc::new(RemoteHub::new()),
        stream_proxy: Arc::new(StreamProxy::with_proxy_store(proxy)),
        cover_repair: tokio::sync::Mutex::new(Default::default()),
        providers_updated_at: AtomicI64::new(0),
        auto_loop_started: AtomicBool::new(false),
    }
}

fn favorite(provider: &str, id: &str, cover: &str) -> Favorite {
    serde_json::from_value(serde_json::json!({
        "key":format!("{provider}:{id}"), "provider":provider, "native_id":id,
        "title":"Identical fixture title", "cover":cover, "group_name":"Keep group",
        "kind":"series", "favorited":true, "following":true,
        "last_episode_count":12, "last_episode_title":"Episode 12", "unread_count":2,
        "last_checked_at":500, "last_update_at":400, "note":"Keep label",
        "created_at":100, "updated_at":300, "deleted":false
    })).unwrap()
}

fn progress(provider: &str, id: &str, cover: &str) -> Progress {
    Progress {
        key:"caller-key-is-not-identity".into(), provider:provider.into(), native_id:id.into(),
        title:"Identical fixture title".into(), cover:Some(cover.into()),
        episode_id:Some("episode-current".into()), episode_title:Some("Current episode".into()),
        position:63, duration:180, finished:false, updated_at:900,
    }
}

fn history(provider: &str, id: &str, cover: Option<&str>, key: &str, at: i64) -> HistoryEntry {
    HistoryEntry {
        key:key.into(), provider:provider.into(), native_id:id.into(),
        title:"Identical fixture title".into(), cover:cover.map(str::to_owned),
        episode_title:Some("Historical episode".into()), position:41, duration:180, watched_at:at,
    }
}

fn json<T: serde::Serialize>(value: T) -> serde_json::Value {
    serde_json::to_value(value).unwrap()
}

struct Source {
    manifest: ProviderManifest,
    cover: String,
    ids: Arc<Mutex<Vec<MediaId>>>,
}
#[async_trait]
impl MediaProvider for Source {
    fn manifest(&self) -> &ProviderManifest { &self.manifest }
    async fn detail(&self, id: &MediaId) -> std::result::Result<MediaDetail, ProviderError> {
        self.ids.lock().unwrap().push(id.clone());
        Ok(serde_json::from_value(serde_json::json!({
            "id":id.as_key(), "title":"Identical fixture title", "cover":self.cover
        })).unwrap())
    }
    async fn resolve(&self, _: &MediaId, _: &PlayRequest) -> std::result::Result<Vec<StreamCandidate>, ProviderError> {
        Ok(vec![])
    }
}

fn register(state: &AppState, cover: &str) -> Arc<Mutex<Vec<MediaId>>> {
    let ids = Arc::new(Mutex::new(Vec::new()));
    state.registry.register(Arc::new(Source {
        manifest: ProviderManifest {
            id:"art-source".into(), name:"Artwork fixture".into(), version:"1".into(),
            kind:"fixture".into(), description:None, icon:None, id_prefixes:vec![],
            capabilities:Default::default(), hidden:false, cover_headers:vec![], config:vec![],
            api_version:1, theme_color:None, working:true, broken_reason:None, enabled:None,
        },
        cover:cover.into(), ids:ids.clone(),
    }));
    ids
}

fn client() -> reqwest::Client {
    reqwest::Client::builder().no_proxy().timeout(std::time::Duration::from_secs(3)).build().unwrap()
}

#[tokio::test]
async fn complete_html_200_at_origin_root_is_non_image_evidence() {
    assert_eq!(HTML.len(), 26);
    let fixture = Fixture::new(RootBody::Html).await;
    let response = client().get(fixture.root()).send().await.unwrap();
    assert_eq!(response.status().as_u16(), 200);
    assert_eq!(response.headers()["content-type"], "text/html");
    assert_eq!(response.bytes().await.unwrap().as_ref(), HTML);
    let probe = probe_cover(&client(), &fixture.root()).await;
    assert!(probe.invalid(), "complete HTTP200 HTML is not merely an unknown image");
    assert!(!probe.poster());
}

#[tokio::test]
async fn same_identity_history_outside_preview_repairs_only_bad_cover_fields() {
    let fixture = Fixture::new(RootBody::Html).await;
    let state = state();
    let bad = fixture.root();
    let good = fixture.poster();
    let before_favorite = favorite("art-source", "target", &bad);
    let before_progress = progress("art-source", "target", &bad);
    state.db.upsert_favorite(&before_favorite).unwrap();
    state.db.upsert_progress(&before_progress).unwrap();
    state.db.add_history(&history("art-source", "target", Some(&good), "old-target", 1)).unwrap();
    // The only valid donor is deliberately outside list_history(100).
    for index in 0..130 {
        state.db.add_history(&history("noise", &format!("n{index}"), None, &format!("noise-{index}"), 1000 + index)).unwrap();
    }
    assert!(!state.db.list_history(100).unwrap().iter().any(|h| h.native_id == "target"));
    let before_history = json(state.db.list_history(500).unwrap());
    let before_progress = state.db.get_progress("art-source:target").unwrap().unwrap();
    assert_eq!(repair(&state).await.unwrap(), 2, "same provider/native ID history must supply the valid donor");
    let mut expected_favorite = before_favorite;
    expected_favorite.cover = Some(good.clone());
    let mut expected_progress = before_progress;
    expected_progress.cover = Some(good);
    assert_eq!(json(state.db.get_favorite("art-source:target").unwrap()), json(Some(expected_favorite)));
    assert_eq!(json(state.db.get_progress("art-source:target").unwrap()), json(Some(expected_progress)));
    assert_eq!(json(state.db.list_history(500).unwrap()), before_history);
    assert_eq!(repair(&state).await.unwrap(), 0);
}

#[tokio::test]
async fn title_or_native_id_collision_never_borrows_a_foreign_cover() {
    let fixture = Fixture::new(RootBody::Html).await;
    let state = state();
    let bad = fixture.root();
    let original = favorite("art-source", "target", &bad);
    state.db.upsert_favorite(&original).unwrap();
    state.db.add_history(&history("other-provider", "target", Some(&fixture.poster()), "foreign-provider", 1)).unwrap();
    state.db.add_history(&history("art-source", "another-native", Some(&fixture.poster()), "foreign-native", 2)).unwrap();
    let calls = register(&state, &bad);
    let before_history = json(state.db.list_history(100).unwrap());
    assert_eq!(repair(&state).await.unwrap(), 0);
    assert_eq!(json(state.db.get_favorite("art-source:target").unwrap()), json(Some(original)));
    assert_eq!(json(state.db.list_history(100).unwrap()), before_history);
    assert!(calls.lock().unwrap().iter().all(|id| id.provider == "art-source" && id.native == "target"));
}

#[tokio::test]
async fn valid_image_at_root_is_retained_even_if_mime_claims_html() {
    let fixture = Fixture::new(RootBody::Poster).await;
    let state = state();
    let original = favorite("art-source", "target", &fixture.root());
    state.db.upsert_favorite(&original).unwrap();
    state.db.add_history(&history("art-source", "target", Some(&fixture.poster()), "valid-history", 1)).unwrap();
    assert!(probe_cover(&client(), &fixture.root()).await.poster());
    assert_eq!(repair(&state).await.unwrap(), 0);
    assert_eq!(json(state.db.get_favorite("art-source:target").unwrap()), json(Some(original)));
}

#[tokio::test]
async fn complete_opaque_body_does_not_authorize_replacing_an_unknown_format() {
    let fixture = Fixture::new(RootBody::Opaque).await;
    let state = state();
    let original = favorite("art-source", "target", &fixture.root());
    state.db.upsert_favorite(&original).unwrap();
    state.db.add_history(&history("art-source", "target", Some(&fixture.poster()), "valid-history", 1)).unwrap();
    assert!(matches!(probe_cover(&client(), &fixture.root()).await, CoverProbe::Unknown));
    assert_eq!(repair(&state).await.unwrap(), 0);
    assert_eq!(json(state.db.get_favorite("art-source:target").unwrap()), json(Some(original)));
}

#[tokio::test]
async fn truncated_http_body_with_html_prefix_remains_unknown() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = [0; 4096];
        stream.read(&mut request).await.unwrap();
        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 256\r\nConnection: close\r\n\r\n<html><body>").await.unwrap();
        stream.shutdown().await.unwrap();
    });
    assert!(matches!(probe_cover(&client(), &url).await, CoverProbe::Unknown));
    task.await.unwrap();
}

#[tokio::test]
async fn over_limit_html_prefix_remains_unknown_without_complete_body_evidence() {
    let fixture = Fixture::new(RootBody::OverLimitHtml).await;
    assert!(matches!(probe_cover(&client(), &fixture.root()).await, CoverProbe::Unknown));
}

#[tokio::test]
async fn failed_singleton_retry_is_coalesced_by_exact_identity_and_cover_key() {
    let fixture = Fixture::new(RootBody::Html).await;
    let state = state();
    let bad = fixture.root();
    let original = favorite("art-source", "target", &bad);
    state.db.upsert_favorite(&original).unwrap();
    let calls = register(&state, &bad);
    assert_eq!(repair(&state).await.unwrap(), 0);
    let request_count = fixture.requests();
    let detail_count = calls.lock().unwrap().len();
    assert_eq!(detail_count, 1, "a complete HTML singleton must reach its exact source detail");
    assert!(request_count > 0);
    {
        let checks = state.cover_repair.lock().await;
        assert!(checks.checked.contains_key(&("art-source".into(), "target".into(), bad.clone())));
    }
    assert_eq!(repair(&state).await.unwrap(), 0);
    assert_eq!(fixture.requests(), request_count);
    assert_eq!(calls.lock().unwrap().len(), detail_count);
    assert_eq!(json(state.db.get_favorite("art-source:target").unwrap()), json(Some(original)));
}

#[tokio::test]
async fn singleton_complete_html_refresh_keeps_all_other_fields() {
    let fixture = Fixture::new(RootBody::Html).await;
    let state = state();
    let bad = fixture.root();
    let good = fixture.poster();
    let before_favorite = favorite("art-source", "target", &bad);
    state.db.upsert_favorite(&before_favorite).unwrap();
    state.db.upsert_progress(&progress("art-source", "target", &bad)).unwrap();
    state.db.add_history(&history("art-source", "target", Some(&bad), "same-work", 100)).unwrap();
    let before_progress = state.db.get_progress("art-source:target").unwrap().unwrap();
    let before_history = state.db.list_history(100).unwrap();
    let calls = register(&state, &good);

    assert_eq!(repair(&state).await.unwrap(), 3);
    assert_eq!(calls.lock().unwrap().as_slice(), &[MediaId::new("art-source", "target")]);
    let mut expected_favorite = before_favorite;
    let mut expected_progress = before_progress;
    let mut expected_history = before_history;
    expected_favorite.cover = Some(good.clone());
    expected_progress.cover = Some(good.clone());
    expected_history[0].cover = Some(good);
    assert_eq!(json(state.db.get_favorite("art-source:target").unwrap()), json(Some(expected_favorite)));
    assert_eq!(json(state.db.get_progress("art-source:target").unwrap()), json(Some(expected_progress)));
    assert_eq!(json(state.db.list_history(100).unwrap()), json(expected_history));
}

struct WrongIdentitySource {
    source: Source,
    reported: MediaId,
}

#[async_trait]
impl MediaProvider for WrongIdentitySource {
    fn manifest(&self) -> &ProviderManifest { &self.source.manifest }
    async fn detail(&self, id: &MediaId) -> std::result::Result<MediaDetail, ProviderError> {
        self.source.ids.lock().unwrap().push(id.clone());
        Ok(serde_json::from_value(serde_json::json!({
            "id":self.reported.as_key(), "title":"Identical fixture title", "cover":self.source.cover
        })).unwrap())
    }
    async fn resolve(&self, _: &MediaId, _: &PlayRequest) -> std::result::Result<Vec<StreamCandidate>, ProviderError> {
        Ok(vec![])
    }
}

#[tokio::test]
async fn complete_html_refresh_rejects_wrong_detail_identity() {
    let fixture = Fixture::new(RootBody::Html).await;
    for reported in [MediaId::new("other-provider", "target"), MediaId::new("art-source", "other-native")] {
        let state = state();
        let bad = fixture.root();
        let original = favorite("art-source", "target", &bad);
        state.db.upsert_favorite(&original).unwrap();
        let calls = register(&state, &fixture.poster());
        let manifest = state.registry.get("art-source").unwrap().manifest().clone();
        state.registry.register(Arc::new(WrongIdentitySource {
            source: Source { manifest, cover:fixture.poster(), ids:calls.clone() }, reported,
        }));
        assert_eq!(repair(&state).await.unwrap(), 0);
        // This must reach details: an Unknown probe would make the rejection vacuous.
        assert_eq!(calls.lock().unwrap().as_slice(), &[MediaId::new("art-source", "target")]);
        assert_eq!(json(state.db.get_favorite("art-source:target").unwrap()), json(Some(original)));
    }
}

async fn probe_complete_body(body: &'static [u8]) -> CoverProbe {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    let app = axum::Router::new().fallback(get(move || async move {
        // Neither MIME nor URL suffix participates in body classification.
        ([(axum::http::header::CONTENT_TYPE, "image/png")], body).into_response()
    }));
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    let result = probe_cover(&client(), &url).await;
    server.abort();
    result
}

#[tokio::test]
async fn html_bom_whitespace_case_and_doctype_have_complete_body_evidence() {
    for body in [
        b"\xef\xbb\xbf \r\n\t<HTML><body>error</body></HTML>".as_slice(),
        b" \n<!DOCTYPE HTML><html></html>".as_slice(),
        b"<html lang='en'>error</html>".as_slice(),
    ] {
        assert!(probe_complete_body(body).await.invalid());
    }
}

#[tokio::test]
async fn html_prefix_lookalikes_do_not_replace_unknown_image_formats() {
    for body in [
        b"<htmlish>opaque</htmlish>".as_slice(),
        b"<!doctype htmlish>opaque".as_slice(),
        b"<?xml version='1.0'?><svg/>".as_slice(),
        b"{\"error\":\"not an image\"}".as_slice(),
    ] {
        assert!(matches!(probe_complete_body(body).await, CoverProbe::Unknown));
    }
}

// A real trigger aborts the third table update after the transaction has
// attempted favorites and progress. This is not a fake Db method or a returned
// success value: before/after rows and the next real repair are observed.
#[tokio::test]
async fn database_failure_rolls_back_all_rows_and_keeps_singleton_retry_due() {
    let fixture = Fixture::new(RootBody::Missing).await;
    let db_path = std::env::temp_dir().join(format!(
        "sourin-cover-save-fixture-{}-{}.sqlite",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos(),
    ));
    let mut state = state();
    state.db = Arc::new(Db::open(&db_path).unwrap());
    let bad = fixture.root();
    let good = fixture.poster();
    state.db.upsert_favorite(&favorite("art-source", "target", &bad)).unwrap();
    state.db.upsert_progress(&progress("art-source", "target", &bad)).unwrap();
    state.db.add_history(&history("art-source", "target", Some(&bad), "history-target", 100)).unwrap();
    let before_favorites = json(state.db.list_favorites(false).unwrap());
    let before_progress = json(state.db.list_all_progress().unwrap());
    let before_history = json(state.db.list_history(100).unwrap());
    let connection = rusqlite::Connection::open(&db_path).unwrap();
    connection.execute_batch("CREATE TRIGGER reject_cover_save BEFORE UPDATE OF cover ON history BEGIN SELECT RAISE(ABORT, 'fixture rejects cover save'); END;").unwrap();
    let calls = register(&state, &good);

    let failure = repair(&state).await;
    assert!(failure.is_err(), "a failed real SQLite save cannot report successful repair");
    assert_eq!(json(state.db.list_favorites(false).unwrap()), before_favorites);
    assert_eq!(json(state.db.list_all_progress().unwrap()), before_progress);
    assert_eq!(json(state.db.list_history(100).unwrap()), before_history);
    {
        let checks = state.cover_repair.lock().await;
        assert!(!checks.checked.contains_key(&("art-source".into(), "target".into(), bad.clone())),
            "failed persistence must not publish a ten-minute success check");
    }
    connection.execute_batch("DROP TRIGGER reject_cover_save;").unwrap();
    assert_eq!(repair(&state).await.unwrap(), 3, "removing the real save fault must permit an immediate retry");
    assert_eq!(calls.lock().unwrap().len(), 2);
    assert_eq!(state.db.get_favorite("art-source:target").unwrap().unwrap().cover, Some(good.clone()));
    assert_eq!(state.db.get_progress("art-source:target").unwrap().unwrap().cover, Some(good.clone()));
    assert_eq!(state.db.list_history(100).unwrap()[0].cover, Some(good));
    drop(connection);
    drop(state);
    let _ = std::fs::remove_file(&db_path);
}
