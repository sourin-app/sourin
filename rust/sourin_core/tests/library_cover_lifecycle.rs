use async_trait::async_trait;
use sourin_core::{
    commands, commands_write, library_covers, model::*, provider::MediaProvider, state::AppState,
};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

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
        Ok(serde_json::from_value(
            serde_json::json!({"id":id.as_key(),"title":"Cover fixture","cover":self.cover}),
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
        let app = axum::Router::new().route("/playlist.m3u8", axum::routing::get(|| async {
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
