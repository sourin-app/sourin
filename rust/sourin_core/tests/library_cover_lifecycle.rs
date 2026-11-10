use async_trait::async_trait;
use sourin_core::{
    commands, commands_write, library_covers, model::*, provider::MediaProvider, state::AppState,
    store::{HistoryEntry, Progress},
};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

// Public CDN failures can be successful image responses: this is a complete,
// transparent 4 x 8 GIF, not an HTTP/decode error.
const EMPTY_GIF: &[u8] = &[
    71, 73, 70, 56, 57, 97, 4, 0, 8, 0, 145, 2, 0, 255, 255, 255, 0, 0, 0, 255, 255, 255,
    0, 0, 0, 33, 249, 4, 1, 0, 0, 2, 0, 44, 0, 0, 0, 0, 4, 0, 8, 0, 0, 2, 5, 148, 143,
    169, 139, 5, 0, 59,
];
const POSTER_PNG: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 32, 0, 0, 0,
    48, 8, 2, 0, 0, 0, 255, 206, 239, 56, 0, 0, 0, 98, 73, 68, 65, 84, 120, 156, 99, 84,
    14, 157, 203, 64, 75, 192, 68, 83, 211, 25, 70, 45, 32, 2, 140, 198, 1, 65, 48, 26, 68,
    3, 31, 68, 44, 184, 36, 118, 6, 206, 34, 213, 44, 247, 245, 105, 152, 130, 163, 145, 76,
    16, 140, 6, 17, 65, 48, 26, 68, 4, 193, 104, 16, 17, 4, 163, 65, 68, 16, 140, 6, 17,
    65, 48, 26, 68, 4, 193, 104, 16, 141, 128, 32, 98, 28, 237, 198, 14, 255, 72, 102, 26,
    181, 128, 16, 160, 121, 16, 1, 0, 72, 237, 5, 139, 37, 191, 209, 101, 0, 0, 0, 0, 73,
    69, 78, 68, 174, 66, 96, 130,
];

struct CoverSource {
    manifest: ProviderManifest,
    cover: String,
    details: Arc<AtomicUsize>,
}

#[async_trait]
impl MediaProvider for CoverSource {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }
    async fn detail(&self, id: &MediaId) -> std::result::Result<MediaDetail, ProviderError> {
        self.details.fetch_add(1, Ordering::SeqCst);
        if id.native.starts_with("missing-") {
            return Ok(serde_json::from_value(
                serde_json::json!({"id":id.as_key(),"title":"Unavailable cover"}),
            )
            .unwrap());
        }
        let reported = if id.native == "foreign-detail" {
            MediaId::new("another-provider", "another-work")
        } else { id.clone() };
        Ok(serde_json::from_value(
            serde_json::json!({"id":reported.as_key(),"title":"Cover fixture","cover":self.cover}),
        )
        .unwrap())
    }
    async fn resolve(
        &self,
        _: &MediaId,
        _: &PlayRequest,
    ) -> std::result::Result<Vec<StreamCandidate>, ProviderError> {
        Ok(vec![])
    }
}

#[tokio::test]
async fn recovery_advances_past_unavailable_covers() {
    let (state, _, calls, server) = fixture().await;
    for id in (0..24)
        .map(|i| format!("missing-{i:02}"))
        .chain(std::iter::once("z-available".into()))
    {
        commands_write::set_following(
            &state,
            "cover-fixture",
            &id,
            true,
            Some("Fixture".into()),
            None,
            None,
        )
        .await
        .unwrap();
    }
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    assert_eq!(calls.load(Ordering::SeqCst), 24);
    assert_eq!(library_covers::repair(&state).await.unwrap(), 1);
    assert!(state
        .db
        .get_favorite("cover-fixture:z-available")
        .unwrap()
        .unwrap()
        .cover
        .is_some());
    server.abort();
}

#[tokio::test]
async fn browsing_thousands_of_covers_keeps_active_stream_segment_headers() {
    let (state, raw, _, server) = fixture().await;
    state.stream_proxy.ensure_started().await.unwrap();
    let stream = state.stream_proxy.register(
        &raw.replace("/cover", "/playlist.m3u8"),
        vec![("X-Cover-Source".into(), "playing-video".into())],
    );
    let playlist = reqwest::Client::builder().no_proxy().build().unwrap()
        .get(stream).send().await.unwrap().text().await.unwrap();
    let segment = playlist.lines().find(|line| line.starts_with("http://")).unwrap();
    assert_loads(&segment, "playing-video").await;
    for i in 0..4096 {
        state.stream_proxy.register_cover(
            &format!("{raw}?poster={i}"),
            vec![("X-Cover-Source".into(), "poster".into())],
        );
    }
    assert_loads(&segment, "playing-video").await;
    server.abort();
}

fn register(state: &AppState, raw: &str, calls: Arc<AtomicUsize>) {
    state.registry.register(Arc::new(CoverSource {
        manifest: ProviderManifest {
            id: "cover-fixture".into(),
            name: "Cover fixture".into(),
            version: "1".into(),
            kind: "fixture".into(),
            description: None,
            icon: None,
            id_prefixes: vec![],
            capabilities: Default::default(),
            hidden: false,
            cover_headers: vec![("X-Cover-Source".into(), "origin-a".into())],
            config: vec![],
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            enabled: None,
        },
        cover: raw.into(),
        details: calls,
    }));
}

async fn fixture() -> (
    Arc<AppState>,
    String,
    Arc<AtomicUsize>,
    tokio::task::JoinHandle<()>,
) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let raw = format!("http://{}/cover", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let app = axum::Router::new()
        .route("/empty.gif", axum::routing::get(|| async { EMPTY_GIF }))
        .route("/poster.png", axum::routing::get(|headers: axum::http::HeaderMap| async move {
            if headers.get("x-cover-source").and_then(|v| v.to_str().ok()) == Some("origin-a") {
                (axum::http::StatusCode::OK, POSTER_PNG)
            } else {
                (axum::http::StatusCode::FORBIDDEN, b"missing header".as_slice())
            }
        }))
        .route("/unknown", axum::routing::get(|| async { "<html>not an image</html>" }))
        .route("/offline", axum::routing::get(|| async { axum::http::StatusCode::SERVICE_UNAVAILABLE }))
        .route("/gone", axum::routing::get(|| async { axum::http::StatusCode::GONE }))
        .route("/playlist.m3u8", axum::routing::get(|| async {
            ([(axum::http::header::CONTENT_TYPE, "application/vnd.apple.mpegurl")],
                "#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\ncover\n#EXT-X-ENDLIST\n")
        })).route(
            "/cover",
            axum::routing::get(|headers: axum::http::HeaderMap| async move {
                match headers.get("x-cover-source").and_then(|v| v.to_str().ok()) {
                    Some(value) => (axum::http::StatusCode::OK, value.to_string()),
                    None => (
                        axum::http::StatusCode::FORBIDDEN,
                        "missing image header".into(),
                    ),
                }
            }),
        );
        axum::serve(listener, app).await.unwrap();
    });
    let dir = std::env::temp_dir().join(format!(
        "sourin-cover-lifecycle-{}-{}",
        std::process::id(),
        chrono::Utc::now().timestamp_nanos_opt().unwrap()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir).await.unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    register(&state, &raw, calls.clone());
    (state, raw, calls, server)
}

async fn assert_loads(url: &str, expected: &str) {
    let response = reqwest::Client::builder()
        .no_proxy()
        .build()
        .unwrap()
        .get(url)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    assert_eq!(response.text().await.unwrap(), expected);
}

#[tokio::test]
async fn following_persists_origin_and_all_library_views_reproxy_after_restart() {
    let (state, raw, calls, server) = fixture().await;
    state.stream_proxy.ensure_started().await.unwrap();
    let temporary = state
        .stream_proxy
        .register_cover(&raw, vec![("X-Cover-Source".into(), "origin-a".into())]);
    commands_write::set_following(
        &state,
        "cover-fixture",
        "series",
        true,
        Some("Fixture".into()),
        Some(temporary.clone()),
        None,
    )
    .await
    .unwrap();
    assert_eq!(
        state
            .db
            .get_favorite("cover-fixture:series")
            .unwrap()
            .unwrap()
            .cover
            .as_deref(),
        Some(raw.as_str())
    );
    commands_write::set_favorite(
        &state,
        "cover-fixture",
        "series",
        true,
        Some("Fixture".into()),
        Some(temporary.clone()),
        None,
        None,
    )
    .await
    .unwrap();
    commands_write::save_progress(
        &state,
        "cover-fixture",
        "series",
        "Fixture",
        Some(temporary),
        Some("ep1".into()),
        None,
        42,
        120,
        None,
    )
    .unwrap();

    let restarted = AppState::bootstrap(state.data_dir.clone()).await.unwrap();
    register(&restarted, &raw, calls);
    let favorites = commands::list_favorites(&restarted, false).await.unwrap();
    let following = commands::list_favorites(&restarted, true).await.unwrap();
    let progress = commands::continue_watching_for_ui(&restarted, None)
        .await
        .unwrap();
    let history = commands::list_history_for_ui(&restarted, None)
        .await
        .unwrap();
    for cover in [
        &favorites[0].cover,
        &following[0].cover,
        &progress[0].cover,
        &history[0].cover,
    ] {
        assert_loads(cover.as_deref().unwrap(), "origin-a").await;
    }
    assert_eq!(
        restarted
            .db
            .get_progress("cover-fixture:series")
            .unwrap()
            .unwrap()
            .cover
            .as_deref(),
        Some(raw.as_str())
    );
    server.abort();
}

#[tokio::test]
async fn repairs_expired_and_missing_covers_without_moving_progress_or_favorites() {
    let (state, raw, calls, server) = fixture().await;
    commands_write::set_following(
        &state,
        "cover-fixture",
        "series",
        true,
        Some("Fixture".into()),
        None,
        None,
    )
    .await
    .unwrap();
    let stale = "http://127.0.0.1:1/s/expired-cover-token";
    let mut original = state
        .db
        .get_favorite("cover-fixture:series")
        .unwrap()
        .unwrap();
    original.cover = Some(stale.into());
    state.db.upsert_favorite(&original).unwrap();
    commands_write::save_progress(
        &state,
        "cover-fixture",
        "series",
        "Fixture",
        None,
        Some("ep3".into()),
        Some("Episode 3".into()),
        63,
        180,
        None,
    )
    .unwrap();
    let before = state
        .db
        .get_progress("cover-fixture:series")
        .unwrap()
        .unwrap();
    let before_history = state.db.list_history(10).unwrap().remove(0);
    assert!(commands::list_favorites(&state, true).await.unwrap()[0]
        .cover
        .is_none());
    assert_eq!(library_covers::repair(&state).await.unwrap(), 3);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let mut expected_favorite = original;
    expected_favorite.cover = Some(raw.clone());
    assert_eq!(
        serde_json::to_value(state.db.get_favorite("cover-fixture:series").unwrap()).unwrap(),
        serde_json::to_value(Some(expected_favorite)).unwrap()
    );
    let mut expected_progress = before;
    expected_progress.cover = Some(raw.clone());
    assert_eq!(
        serde_json::to_value(state.db.get_progress("cover-fixture:series").unwrap()).unwrap(),
        serde_json::to_value(Some(expected_progress)).unwrap()
    );
    let mut expected_history = before_history;
    expected_history.cover = Some(raw);
    assert_eq!(
        serde_json::to_value(state.db.list_history(10).unwrap()[0].clone()).unwrap(),
        serde_json::to_value(expected_history).unwrap()
    );
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    server.abort();
}

#[tokio::test]
async fn header_scopes_and_aggregate_child_headers_are_kept_separate() {
    let (state, raw, _, server) = fixture().await;
    state.stream_proxy.ensure_started().await.unwrap();
    let a = state
        .stream_proxy
        .register_cover(&raw, vec![("X-Cover-Source".into(), "origin-a".into())]);
    let b = state
        .stream_proxy
        .register_cover(&raw, vec![("X-Cover-Source".into(), "origin-b".into())]);
    assert_ne!(a, b);
    assert_loads(&a, "origin-a").await;
    assert_loads(&b, "origin-b").await;
    let aggregate =
        library_covers::for_display(&state, "tvbox_agg", "cover-fixture::series", Some(&raw))
            .await
            .unwrap();
    assert_loads(&aggregate, "origin-a").await;
    assert_eq!(library_covers::durable(&state, Some(&raw)), Some(raw));
    assert!(library_covers::durable(&state, Some("http://127.0.0.1:1/s/expired")).is_none());
    server.abort();
}

#[tokio::test]
async fn repair_skips_disabled_sources_and_cannot_overwrite_a_newer_cover() {
    let (state, raw, calls, server) = fixture().await;
    commands_write::set_following(
        &state,
        "cover-fixture",
        "series",
        true,
        Some("Fixture".into()),
        None,
        None,
    )
    .await
    .unwrap();
    state.registry.set_enabled("cover-fixture", false);
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    let mut favorite = state
        .db
        .get_favorite("cover-fixture:series")
        .unwrap()
        .unwrap();
    favorite.cover = Some(raw.clone());
    state.db.upsert_favorite(&favorite).unwrap();
    assert_eq!(
        state
            .db
            .repair_library_cover(
                "cover-fixture",
                "series",
                &[None],
                "https://older.invalid/cover"
            )
            .unwrap(),
        0
    );
    assert_eq!(
        state
            .db
            .get_favorite("cover-fixture:series")
            .unwrap()
            .unwrap()
            .cover,
        Some(raw)
    );
    server.abort();
}

#[tokio::test]
async fn transparent_success_response_uses_same_identity_history_even_when_source_disabled() {
    let (state, raw, calls, server) = fixture().await;
    let empty = raw.replace("/cover", "/empty.gif");
    let poster = raw.replace("/cover", "/poster.png");
    commands_write::set_following(
        &state, "cover-fixture", "series", true,
        Some("Identical title".into()), Some(empty.clone()), None,
    ).await.unwrap();
    commands_write::save_progress(
        &state, "cover-fixture", "series", "Identical title", Some(poster.clone()),
        Some("ep3".into()), Some("Episode 3".into()), 63, 180, None,
    ).unwrap();
    // A matching title/native ID from another provider must not donate a cover.
    commands_write::set_following(
        &state, "other-provider", "series", true,
        Some("Identical title".into()), Some(empty.clone()), None,
    ).await.unwrap();
    state.registry.set_enabled("cover-fixture", false);
    let before_favorite = state.db.get_favorite("cover-fixture:series").unwrap().unwrap();
    let before_progress = serde_json::to_value(state.db.get_progress("cover-fixture:series").unwrap()).unwrap();
    let before_history = serde_json::to_value(state.db.list_history(10).unwrap()).unwrap();
    let before_other = serde_json::to_value(state.db.get_favorite("other-provider:series").unwrap()).unwrap();
    assert_eq!(library_covers::repair(&state).await.unwrap(), 1);
    assert_eq!(calls.load(Ordering::SeqCst), 0, "disabled source detail must not run");
    let mut expected_favorite = before_favorite;
    expected_favorite.cover = Some(poster);
    assert_eq!(
        serde_json::to_value(state.db.get_favorite("cover-fixture:series").unwrap()).unwrap(),
        serde_json::to_value(Some(expected_favorite)).unwrap(),
    );
    assert_eq!(serde_json::to_value(state.db.get_progress("cover-fixture:series").unwrap()).unwrap(), before_progress);
    assert_eq!(serde_json::to_value(state.db.list_history(10).unwrap()).unwrap(), before_history);
    assert_eq!(serde_json::to_value(state.db.get_favorite("other-provider:series").unwrap()).unwrap(), before_other);
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    server.abort();
}

#[tokio::test]
async fn uncertain_or_unavailable_cover_never_overwrites_existing_metadata() {
    let (state, raw, calls, server) = fixture().await;
    let empty = raw.replace("/cover", "/empty.gif");
    let poster = raw.replace("/cover", "/poster.png");
    let unknown = raw.replace("/cover", "/unknown");
    let offline = raw.replace("/cover", "/offline");
    for (id, favorite, progress) in [
        ("unknown-current", &unknown, &poster),
        ("offline-current", &offline, &poster),
        ("unknown-donor", &empty, &unknown),
    ] {
        commands_write::set_following(
            &state, "cover-fixture", id, true, Some("Fixture".into()),
            Some(favorite.clone()), None,
        ).await.unwrap();
        commands_write::save_progress(
            &state, "cover-fixture", id, "Fixture", Some(progress.clone()),
            Some("ep1".into()), None, 1, 120, None,
        ).unwrap();
    }
    state.registry.set_enabled("cover-fixture", false);
    let before = serde_json::to_value(state.db.list_following_for_ui().unwrap()).unwrap();
    let before_progress = serde_json::to_value(state.db.continue_watching(100).unwrap()).unwrap();
    let before_history = serde_json::to_value(state.db.list_history(100).unwrap()).unwrap();
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    assert_eq!(serde_json::to_value(state.db.list_following_for_ui().unwrap()).unwrap(), before);
    assert_eq!(serde_json::to_value(state.db.continue_watching(100).unwrap()).unwrap(), before_progress);
    assert_eq!(serde_json::to_value(state.db.list_history(100).unwrap()).unwrap(), before_history);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    server.abort();
}

#[tokio::test]
async fn valid_favorite_repairs_tiny_progress_and_history_without_changing_other_fields() {
    let (state, raw, calls, server) = fixture().await;
    let empty = raw.replace("/cover", "/empty.gif");
    let poster = raw.replace("/cover", "/poster.png");
    commands_write::set_following(
        &state, "cover-fixture", "series", true,
        Some("Fixture".into()), Some(poster.clone()), None,
    ).await.unwrap();
    commands_write::save_progress(
        &state, "cover-fixture", "series", "Fixture", Some(empty),
        Some("ep3".into()), Some("Episode 3".into()), 63, 180, None,
    ).unwrap();
    state.registry.set_enabled("cover-fixture", false);
    let before_favorite = serde_json::to_value(state.db.get_favorite("cover-fixture:series").unwrap()).unwrap();
    let mut expected_progress = state.db.get_progress("cover-fixture:series").unwrap().unwrap();
    let mut expected_history = state.db.list_history(10).unwrap().remove(0);
    expected_progress.cover = Some(poster.clone());
    expected_history.cover = Some(poster);

    assert_eq!(library_covers::repair(&state).await.unwrap(), 2);
    assert_eq!(calls.load(Ordering::SeqCst), 0, "disabled source detail must not run");
    assert_eq!(
        serde_json::to_value(state.db.get_favorite("cover-fixture:series").unwrap()).unwrap(),
        before_favorite,
    );
    assert_eq!(
        serde_json::to_value(state.db.get_progress("cover-fixture:series").unwrap()).unwrap(),
        serde_json::to_value(Some(expected_progress)).unwrap(),
    );
    assert_eq!(
        serde_json::to_value(state.db.list_history(10).unwrap()).unwrap(),
        serde_json::to_value(vec![expected_history]).unwrap(),
    );
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    server.abort();
}

#[tokio::test]
async fn repair_recovers_donors_hidden_by_resume_filters() {
    let (state, raw, calls, server) = fixture().await;
    let empty = raw.replace("/cover", "/empty.gif");
    let poster = raw.replace("/cover", "/poster.png");
    for (id, latest_position, finished) in [("brief", 2, false), ("finished", 180, true)] {
        commands_write::set_following(
            &state, "cover-fixture", id, true,
            Some("Fixture".into()), Some(empty.clone()), None,
        ).await.unwrap();
        let donor = Progress {
            key: String::new(), provider: "cover-fixture".into(), native_id: id.into(),
            title: "Fixture".into(), cover: Some(poster.clone()),
            episode_id: Some("old".into()), episode_title: Some("Old episode".into()),
            position: 63, duration: 180, finished, updated_at: 100,
        };
        state.db.upsert_progress(&donor).unwrap();
        state.db.upsert_progress(&Progress {
            cover: Some(empty.clone()), episode_id: Some("latest".into()),
            episode_title: Some("Latest episode".into()), position: latest_position,
            updated_at: 200, ..donor
        }).unwrap();
        state.db.add_history(&HistoryEntry {
            key: format!("cover-fixture:{id}"), provider: "cover-fixture".into(),
            native_id: id.into(), title: "Fixture".into(), cover: Some(empty.clone()),
            episode_title: Some("Latest episode".into()), position: latest_position,
            duration: 180, watched_at: 200,
        }).unwrap();
    }
    // These UI rows provide only the tiny cover; neither old donor is visible.
    assert!(state.db.continue_watching(100).unwrap().is_empty());
    assert!(state.db.list_history(100).unwrap().iter().all(|row| row.cover.as_ref() == Some(&empty)));
    state.registry.set_enabled("cover-fixture", false);
    let mut expected_favorites = state.db.list_following_for_ui().unwrap();
    let mut expected_progress = state.db.list_all_progress().unwrap();
    let mut expected_history = state.db.list_history(100).unwrap();
    for row in &mut expected_favorites { row.cover = Some(poster.clone()); }
    for row in &mut expected_progress { row.cover = Some(poster.clone()); }
    for row in &mut expected_history { row.cover = Some(poster.clone()); }

    assert_eq!(library_covers::repair(&state).await.unwrap(), 6);
    assert_eq!(calls.load(Ordering::SeqCst), 0, "disabled source detail must not run");
    assert_eq!(
        serde_json::to_value(state.db.list_following_for_ui().unwrap()).unwrap(),
        serde_json::to_value(expected_favorites).unwrap(),
    );
    assert_eq!(
        serde_json::to_value(state.db.list_all_progress().unwrap()).unwrap(),
        serde_json::to_value(expected_progress).unwrap(),
    );
    assert_eq!(
        serde_json::to_value(state.db.list_history(100).unwrap()).unwrap(),
        serde_json::to_value(expected_history).unwrap(),
    );
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    server.abort();
}

#[tokio::test]
async fn repair_recovers_exact_identity_history_cover_beyond_preview_limit() {
    let (state, raw, calls, server) = fixture().await;
    let empty = raw.replace("/cover", "/empty.gif");
    let poster = raw.replace("/cover", "/poster.png");
    for (provider, id) in [
        ("cover-fixture", "series"),
        ("cover-fixture", "other-id"),
        ("other-provider", "series"),
    ] {
        commands_write::set_following(
            &state, provider, id, true,
            Some("Identical title".into()), Some(empty.clone()), None,
        ).await.unwrap();
    }
    let donor = HistoryEntry {
        key: "cover-fixture:series:old".into(), provider: "cover-fixture".into(),
        native_id: "series".into(), title: "Identical title".into(), cover: Some(poster.clone()),
        episode_title: Some("Old episode".into()), position: 63, duration: 180, watched_at: 1,
    };
    state.db.add_history(&donor).unwrap();
    for i in 0..100 {
        state.db.add_history(&HistoryEntry {
            key: format!("other-provider:series:{i}"), provider: "other-provider".into(),
            cover: Some(empty.clone()), watched_at: i + 2, ..donor.clone()
        }).unwrap();
    }
    assert!(state.db.continue_watching(100).unwrap().is_empty());
    assert!(state.db.list_history(100).unwrap().iter().all(|row| row.provider == "other-provider"));
    state.registry.set_enabled("cover-fixture", false);
    let mut expected_favorites = state.db.list_following_for_ui().unwrap();
    for row in &mut expected_favorites {
        if row.provider == "cover-fixture" && row.native_id == "series" {
            row.cover = Some(poster.clone());
        }
    }
    let before_history = serde_json::to_value(state.db.list_history(101).unwrap()).unwrap();

    assert_eq!(library_covers::repair(&state).await.unwrap(), 1);
    assert_eq!(calls.load(Ordering::SeqCst), 0, "disabled source detail must not run");
    assert_eq!(
        serde_json::to_value(state.db.list_following_for_ui().unwrap()).unwrap(),
        serde_json::to_value(expected_favorites).unwrap(),
    );
    assert_eq!(serde_json::to_value(state.db.list_history(101).unwrap()).unwrap(), before_history);
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    server.abort();
}

#[tokio::test]
async fn covers_without_source_headers_use_global_api_proxy_in_library_and_detail() {
    use sourin_core::proxy::{ProxyConfig, ProxyMode, ProxyScope, GLOBAL_PROXY};
    let (state, raw, calls, origin) = fixture().await;
    let raw = raw.replace("/cover", "/empty.gif");
    let mut manifest = state.registry.get("cover-fixture").unwrap().manifest().clone();
    manifest.cover_headers.clear();
    state.registry.register(Arc::new(CoverSource {
        manifest, cover: raw.clone(), details: calls,
    }));
    let seen = Arc::new(AtomicUsize::new(0));
    let seen_request = seen.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = format!("http://{}", listener.local_addr().unwrap());
    let proxy_server = tokio::spawn(async move {
        let app = axum::Router::new().fallback(move || {
            seen_request.fetch_add(1, Ordering::SeqCst);
            async { ([("Content-Type", "image/png")], POSTER_PNG) }
        });
        axum::serve(listener, app).await.unwrap();
    });
    state.proxy.set(GLOBAL_PROXY, ProxyConfig {
        mode: ProxyMode::Custom, url: Some(proxy), scope: ProxyScope::ApiOnly,
        ..ProxyConfig::default()
    }).unwrap();
    commands_write::set_following(&state, "cover-fixture", "series", true,
        Some("Fixture".into()), Some(raw.clone()), None).await.unwrap();
    let library = commands::list_favorites(&state, true).await.unwrap();
    let detail = sourin_core::playback::get_detail(&state, "cover-fixture", "series").await.unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    for cover in [&library[0].cover, &detail.cover] {
        let response = client.get(cover.as_ref().unwrap()).send().await.unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::OK);
        assert_eq!(&response.bytes().await.unwrap()[..], POSTER_PNG,
            "No-header covers must use the selected API proxy, not the direct sentinel");
    }
    assert_eq!(seen.load(Ordering::SeqCst), 2);
    assert_eq!(state.db.get_favorite("cover-fixture:series").unwrap().unwrap().cover, Some(raw));
    assert_eq!(library[0].cover, detail.cover, "Display wrappers stay stable for image caching");
    origin.abort();
    proxy_server.abort();
}

#[tokio::test]
async fn wrapped_cdn_covers_keep_exact_host_defaults_and_source_overrides() {
    use sourin_core::proxy::{ProxyConfig, ProxyMode, ProxyScope, GLOBAL_PROXY};
    let (state, _, _, origin) = fixture().await;
    let requests = Arc::new(std::sync::Mutex::new(Vec::new()));
    let seen = requests.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let app = axum::Router::new().fallback(move |req: axum::extract::Request| {
            seen.lock().unwrap().push((req.uri().to_string(), req.headers().clone()));
            async { ([("Content-Type", "image/png")], POSTER_PNG) }
        });
        axum::serve(listener, app).await.unwrap();
    });
    state.proxy.set(GLOBAL_PROXY, ProxyConfig {
        mode: ProxyMode::Custom, url: Some(proxy), scope: ProxyScope::ApiOnly,
        ..ProxyConfig::default()
    }).unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    for (host, expected) in [
        ("img3.doubanio.com", true), ("img12.doubanio.com", true),
        ("img3.doubanio.com.example.invalid", false), ("img.doubanio.com", false),
        ("notimg3.doubanio.com", false),
    ] {
        let raw = format!("http://{host}/cover.png");
        let local = library_covers::for_display(&state, "cover-fixture", "series", Some(&raw)).await.unwrap();
        let response = client.get(local).send().await.unwrap();
        assert_eq!(&response.bytes().await.unwrap()[..], POSTER_PNG);
        let records = requests.lock().unwrap();
        let (uri, headers) = records.last().unwrap();
        assert_eq!(uri, &raw);
        assert_eq!(headers.get("referer").is_some(), expected, "{host}");
        assert_eq!(headers.get("x-cover-source").unwrap(), "origin-a");
        if expected {
            assert_eq!(headers.get("referer").unwrap(), "https://movie.douban.com/");
            assert!(headers.get("user-agent").unwrap().to_str().unwrap().contains("Chrome/130."));
        }
    }
    let mut manifest = state.registry.get("cover-fixture").unwrap().manifest().clone();
    manifest.cover_headers = vec![("referer".into(), "https://fixture.test/".into()),
        ("USER-AGENT".into(), "fixture-agent".into())];
    let raw = "http://img3.doubanio.com/override.png";
    state.registry.register(Arc::new(CoverSource { manifest, cover: raw.into(),
        details: Arc::new(AtomicUsize::new(0)) }));
    let local = library_covers::for_display(&state, "cover-fixture", "series", Some(raw)).await.unwrap();
    assert_eq!(&client.get(local).send().await.unwrap().bytes().await.unwrap()[..], POSTER_PNG);
    {
        let records = requests.lock().unwrap();
        let (_, headers) = records.last().unwrap();
        assert_eq!(headers.get("referer").unwrap(), "https://fixture.test/");
        assert_eq!(headers.get_all("referer").iter().count(), 1);
        assert_eq!(headers.get("user-agent").unwrap(), "fixture-agent");
        assert_eq!(headers.get_all("user-agent").iter().count(), 1);
    }
    for raw in ["file:///fixture/cover.png", "data:image/png;base64,fixture"] {
        assert_eq!(library_covers::for_display(&state, "cover-fixture", "series", Some(raw)).await.as_deref(), Some(raw));
    }
    origin.abort();
    server.abort();
}

#[tokio::test]
async fn a_single_expired_cover_refreshes_same_identity_without_moving_library_records() {
    let (state, raw, calls, server) = fixture().await;
    let poster = raw.replace("/cover", "/poster.png");
    register(&state, &poster, calls.clone());
    for (id, cover) in [("missing", raw.replace("/cover", "/not-found")),
                        ("gone", raw.replace("/cover", "/gone")),
                        ("tiny", raw.replace("/cover", "/empty.gif"))] {
        commands_write::set_following(&state, "cover-fixture", id, true,
            Some("Fixture".into()), Some(cover.clone()), None).await.unwrap();
        commands_write::save_progress(&state, "cover-fixture", id, "Fixture", Some(cover),
            Some("ep3".into()), Some("Episode 3".into()), 63, 180, None).unwrap();
    }
    let mut expected_favorites = serde_json::to_value(state.db.list_following_for_ui().unwrap()).unwrap();
    let mut expected_progress = serde_json::to_value(state.db.continue_watching(100).unwrap()).unwrap();
    let mut expected_history = serde_json::to_value(state.db.list_history(100).unwrap()).unwrap();
    for rows in [&mut expected_favorites, &mut expected_progress, &mut expected_history] {
        for row in rows.as_array_mut().unwrap() { row["cover"] = poster.clone().into(); }
    }
    assert_eq!(library_covers::repair(&state).await.unwrap(), 9,
        "A nonempty but expired singleton cover must not be skipped");
    assert_eq!(calls.load(Ordering::SeqCst), 3);
    assert_eq!(serde_json::to_value(state.db.list_following_for_ui().unwrap()).unwrap(), expected_favorites);
    assert_eq!(serde_json::to_value(state.db.continue_watching(100).unwrap()).unwrap(), expected_progress);
    assert_eq!(serde_json::to_value(state.db.list_history(100).unwrap()).unwrap(), expected_history);
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    assert_eq!(calls.load(Ordering::SeqCst), 3);
    server.abort();
}

#[tokio::test]
async fn singleton_repair_preserves_outages_unverified_donors_and_foreign_details() {
    for (id, old_path, fresh_path, disabled, expected_details) in [
        ("outage", "/offline", "/poster.png", false, 0),
        ("unknown", "/unknown", "/poster.png", false, 0),
        ("bad-donor", "/not-found", "/unknown", false, 1),
        ("missing-donor", "/not-found", "/another-missing", false, 1),
        ("unchanged-donor", "/not-found", "/not-found", false, 1),
        ("tiny-donor", "/not-found", "/empty.gif", false, 1),
        ("foreign-detail", "/not-found", "/poster.png", false, 1),
        ("disabled", "/not-found", "/poster.png", true, 0),
    ] {
        let (state, raw, calls, server) = fixture().await;
        register(&state, &raw.replace("/cover", fresh_path), calls.clone());
        commands_write::set_following(&state, "cover-fixture", id, true,
            Some("Identical title".into()), Some(raw.replace("/cover", old_path)), None).await.unwrap();
        if disabled { state.registry.set_enabled("cover-fixture", false); }
        let before = serde_json::to_value(state.db.list_following_for_ui().unwrap()).unwrap();
        assert_eq!(library_covers::repair(&state).await.unwrap(), 0, "{id}");
        assert_eq!(serde_json::to_value(state.db.list_following_for_ui().unwrap()).unwrap(), before, "{id}");
        assert_eq!(calls.load(Ordering::SeqCst), expected_details, "{id}");
        assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
        assert_eq!(calls.load(Ordering::SeqCst), expected_details, "retry cooldown: {id}");
        server.abort();
    }
}

#[tokio::test]
async fn singleton_checks_are_bounded_coalesced_and_cached_without_metadata_requests() {
    let (state, _, calls, origin) = fixture().await;
    let hits = Arc::new(AtomicUsize::new(0));
    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let (seen, inflight, maximum) = (hits.clone(), active.clone(), peak.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let raw = format!("http://{}/poster.png", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let app = axum::Router::new().fallback(move || {
            let (seen, inflight, maximum) = (seen.clone(), inflight.clone(), maximum.clone());
            async move {
                seen.fetch_add(1, Ordering::SeqCst);
                let n = inflight.fetch_add(1, Ordering::SeqCst) + 1;
                maximum.fetch_max(n, Ordering::SeqCst);
                tokio::time::sleep(std::time::Duration::from_millis(40)).await;
                inflight.fetch_sub(1, Ordering::SeqCst);
                ([("Content-Type", "image/png")], POSTER_PNG)
            }
        });
        axum::serve(listener, app).await.unwrap();
    });
    register(&state, &raw, calls.clone());
    for i in 0..30 {
        commands_write::set_following(&state, "cover-fixture", &format!("item-{i:02}"), true,
            Some("Fixture".into()), Some(raw.clone()), None).await.unwrap();
    }
    let (first, overlapping) = tokio::join!(library_covers::repair(&state), library_covers::repair(&state));
    assert_eq!(first.unwrap() + overlapping.unwrap(), 0);
    assert_eq!(hits.load(Ordering::SeqCst), 24, "A repair pass is capped even with overlapping callers");
    assert!((2..=4).contains(&peak.load(Ordering::SeqCst)), "Background work stays bounded and concurrent");
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    assert_eq!(hits.load(Ordering::SeqCst), 30, "Next pass advances past cached healthy covers");
    assert_eq!(library_covers::repair(&state).await.unwrap(), 0);
    assert_eq!(hits.load(Ordering::SeqCst), 30, "Healthy URLs are not probed again on page re-entry");
    assert_eq!(calls.load(Ordering::SeqCst), 0, "Healthy images never trigger metadata requests");
    origin.abort();server.abort();
}

#[tokio::test]
async fn missing_records_do_not_hide_the_only_expired_cover_from_same_pass_recovery() {
    let (state, raw, calls, server) = fixture().await;
    let old = raw.replace("/cover", "/not-found");
    let poster = raw.replace("/cover", "/poster.png");
    register(&state, &poster, calls.clone());
    commands_write::set_following(&state, "cover-fixture", "series", true,
        Some("Fixture".into()), Some(old), None).await.unwrap();
    commands_write::save_progress(&state, "cover-fixture", "series", "Fixture", None,
        Some("ep3".into()), Some("Episode 3".into()), 63, 180, None).unwrap();
    assert!(library_covers::repair(&state).await.unwrap() > 0);
    assert_eq!(state.db.get_favorite("cover-fixture:series").unwrap().unwrap().cover, Some(poster.clone()));
    assert_eq!(state.db.get_progress("cover-fixture:series").unwrap().unwrap().cover, Some(poster.clone()));
    assert_eq!(state.db.list_history(10).unwrap()[0].cover, Some(poster));
    assert_eq!(calls.load(Ordering::SeqCst), 1,
        "Copying the stale donor to missing rows must not postpone refresh until another visit");
    server.abort();
}


#[tokio::test]
async fn inline_cover_headers_survive_library_restart_and_use_global_proxy() {
    use sourin_core::proxy::{ProxyConfig, ProxyMode, ProxyScope, GLOBAL_PROXY};
    let (state, _, calls, origin) = fixture().await;
    let requests = Arc::new(std::sync::Mutex::new(Vec::new()));
    let seen = requests.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let app = axum::Router::new().fallback(move |req: axum::extract::Request| {
            let ok = req.uri().to_string() == "http://img3.doubanio.com/poster.png?size=2"
                && req.headers().get("referer").and_then(|h| h.to_str().ok()) == Some("https://inline.fixture/frame")
                && req.headers().get("user-agent").and_then(|h| h.to_str().ok()) == Some("Inline Fixture/1.0")
                && req.headers().get_all("referer").iter().count() == 1;
            seen.lock().unwrap().push((req.uri().to_string(), req.headers().clone()));
            async move {
                if ok { (axum::http::StatusCode::OK, [("Content-Type", "image/png")], POSTER_PNG) }
                else { (axum::http::StatusCode::FORBIDDEN, [("Content-Type", "text/plain")], &b"wrong cover request"[..]) }
            }
        });
        axum::serve(listener, app).await.unwrap();
    });
    let config = ProxyConfig { mode: ProxyMode::Custom, url: Some(proxy), scope: ProxyScope::ApiOnly,
        ..ProxyConfig::default() };
    state.proxy.set(GLOBAL_PROXY, config.clone()).unwrap();
    let raw = "http://img3.doubanio.com/poster.png?size=2@Referer=https://inline.fixture/frame@User-Agent=Inline%20Fixture/1.0";
    let mut manifest = state.registry.get("cover-fixture").unwrap().manifest().clone();
    manifest.cover_headers.push(("REFERER".into(), "https://source.fixture/".into()));
    state.registry.register(Arc::new(CoverSource { manifest, cover: raw.into(), details: calls.clone() }));
    let local = library_covers::for_display(&state, "cover-fixture", "series", Some(raw)).await.unwrap();
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let response = client.get(&local).send().await.unwrap();
    assert_eq!(response.status(), reqwest::StatusCode::OK, "inline metadata must become headers, not URL query");
    assert_eq!(&response.bytes().await.unwrap()[..], POSTER_PNG);
    assert_eq!(library_covers::durable(&state, Some(&local)).as_deref(), Some(raw));
    let relative = local.replace("/s/", "/p/") + "/http/img3.doubanio.com/poster.png?size=2";
    assert_eq!(&client.get(relative).send().await.unwrap().bytes().await.unwrap()[..], POSTER_PNG);
    assert_eq!(library_covers::for_display(&state, "cover-fixture", "series", Some(raw)).await.unwrap(), local);
    commands_write::set_following(&state, "cover-fixture", "series", true,
        Some("Fixture".into()), Some(local.clone()), None).await.unwrap();
    commands_write::set_favorite(&state, "cover-fixture", "series", true,
        Some("Fixture".into()), Some(local.clone()), None, None).await.unwrap();
    commands_write::save_progress(&state, "cover-fixture", "series", "Fixture", Some(local),
        Some("ep1".into()), None, 42, 120, None).unwrap();
    assert_eq!(state.db.get_favorite("cover-fixture:series").unwrap().unwrap().cover.as_deref(), Some(raw));
    let restarted = AppState::bootstrap(state.data_dir.clone()).await.unwrap();
    register(&restarted, raw, calls);
    restarted.proxy.set(GLOBAL_PROXY, config).unwrap();
    let favorites = commands::list_favorites(&restarted, false).await.unwrap();
    let following = commands::list_favorites(&restarted, true).await.unwrap();
    let progress = commands::continue_watching_for_ui(&restarted, None).await.unwrap();
    let history = commands::list_history_for_ui(&restarted, None).await.unwrap();
    for cover in [&favorites[0].cover, &following[0].cover, &progress[0].cover, &history[0].cover] {
        let response = client.get(cover.as_deref().unwrap()).send().await.unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::OK);
        assert_eq!(&response.bytes().await.unwrap()[..], POSTER_PNG);
        assert_eq!(library_covers::durable(&restarted, cover.as_deref()).as_deref(), Some(raw));
    }
    assert_eq!(requests.lock().unwrap().len(), 6, "every read uses the configured API proxy");
    assert_eq!(restarted.db.get_progress("cover-fixture:series").unwrap().unwrap().position, 42);
    origin.abort(); server.abort();
}
