use async_trait::async_trait;
use sourin_core::{
    commands,
    model::{
        Capabilities, MediaId, MediaItem, Page, PlayRequest, ProviderError, ProviderManifest,
        StreamCandidate,
    },
    provider::MediaProvider,
    registry::Registry,
    state::AppState,
    tvbox::{write_tvbox_meta, TvboxSourceMeta},
    tvbox_aggregate::{self, AggregateConfig, AGGREGATE_ID},
};
use std::sync::{Arc, Mutex};

struct SearchFixture {
    manifest: ProviderManifest,
    calls: Arc<Mutex<Vec<String>>>,
}

fn provider(id: &str, hidden: bool, calls: &Arc<Mutex<Vec<String>>>) -> Arc<dyn MediaProvider> {
    Arc::new(SearchFixture {
        manifest: ProviderManifest {
            id: id.into(),
            name: id.into(),
            version: "1".into(),
            kind: "fixture".into(),
            description: None,
            icon: None,
            id_prefixes: vec![],
            capabilities: Capabilities {
                search: true,
                ..Default::default()
            },
            hidden,
            cover_headers: vec![],
            config: vec![],
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            enabled: None,
        },
        calls: calls.clone(),
    })
}

#[async_trait]
impl MediaProvider for SearchFixture {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    async fn search(&self, _keyword: &str, page: u32) -> Result<Page<MediaItem>, ProviderError> {
        self.calls.lock().unwrap().push(self.manifest.id.clone());
        Ok(Page {
            items: vec![serde_json::from_value(serde_json::json!({
                "id": format!("{}:item", self.manifest.id), "title": "Scope fixture"
            }))
            .unwrap()],
            page,
            page_count: Some(1),
            total: Some(1),
        })
    }

    async fn resolve(
        &self,
        _id: &MediaId,
        _req: &PlayRequest,
    ) -> Result<Vec<StreamCandidate>, ProviderError> {
        Ok(vec![])
    }
}

async fn fixture() -> (Arc<AppState>, Arc<Mutex<Vec<String>>>) {
    let dir = std::env::temp_dir().join(format!(
        "sourin-search-scope-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir).await.unwrap();
    for manifest in state.registry.manifests() {
        state
            .registry
            .set_enabled(&manifest.id, manifest.id == AGGREGATE_ID);
    }
    let calls = Arc::new(Mutex::new(vec![]));
    for (id, hidden, imported) in [
        ("imported-enabled", true, true),
        ("imported-disabled", true, true),
        ("builtin-hidden", true, false),
        ("ordinary-visible", false, false),
    ] {
        state.registry.register(provider(id, hidden, &calls));
        if imported {
            write_tvbox_meta(
                &state.data_dir,
                id,
                &TvboxSourceMeta {
                    site_key: id.into(),
                    site_name: id.into(),
                    ..Default::default()
                },
            )
            .unwrap();
        }
    }
    state.registry.set_enabled("imported-disabled", false);
    tvbox_aggregate::save(
        &state.data_dir,
        &AggregateConfig {
            solo: true,
            ..Default::default()
        },
    )
    .unwrap();
    (state, calls)
}

async fn run_both(state: &AppState, calls: &Arc<Mutex<Vec<String>>>, expected: &[&str]) {
    for stream in [false, true] {
        calls.lock().unwrap().clear();
        let mut item_count = 0;
        if stream {
            commands::search_all_stream(state, "scope", 1, |event| {
                if let commands::SearchStreamEvent::Hit { items, .. } = event {
                    item_count += items.len();
                }
                true
            })
            .await
            .unwrap();
        } else {
            let result = commands::search_all(state, "scope", 1).await.unwrap();
            item_count = result
                .results
                .iter()
                .map(|(_, _, page)| page.items.len())
                .sum();
        }
        let mut actual = calls.lock().unwrap().clone();
        actual.sort();
        let mut expected_sorted = expected.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        expected_sorted.sort();
        assert_eq!(
            actual, expected_sorted,
            "actual provider calls, streaming={stream}"
        );
        assert_eq!(
            item_count,
            expected.len(),
            "renderable results, streaming={stream}"
        );
    }
}

#[tokio::test]
async fn solo_search_only_calls_enabled_imported_children_and_can_be_turned_off() {
    let (state, calls) = fixture().await;
    run_both(&state, &calls, &["imported-enabled"]).await;
    let mut config = tvbox_aggregate::load(&state.data_dir);
    config.solo = false;
    tvbox_aggregate::save(&state.data_dir, &config).unwrap();
    calls.lock().unwrap().clear();
    commands::search_all(&state, "scope", 1).await.unwrap();
    let actual = calls.lock().unwrap();
    assert!(actual.iter().any(|id| id == "ordinary-visible"));
    assert!(!actual.iter().any(|id| id == "imported-disabled"));
}

#[tokio::test]
async fn disabling_aggregate_in_solo_mode_does_not_search_other_sources() {
    let (state, calls) = fixture().await;
    state.registry.set_enabled(AGGREGATE_ID, false);
    run_both(&state, &calls, &[]).await;
}

#[tokio::test]
async fn explicit_disabled_or_unimported_selection_does_not_expand_scope() {
    let (state, calls) = fixture().await;
    for selected in ["imported-disabled", "ordinary-visible", "missing-source"] {
        let config = AggregateConfig {
            solo: true,
            enabled_site_ids: vec![selected.into()],
            ..Default::default()
        };
        tvbox_aggregate::save(&state.data_dir, &config).unwrap();
        run_both(&state, &calls, &[]).await;
    }
    let config = AggregateConfig {
        solo: false,
        enabled_site_ids: vec!["imported-disabled".into()],
        ..Default::default()
    };
    tvbox_aggregate::save(&state.data_dir, &config).unwrap();
    assert!(tvbox_aggregate::enabled_children(&state.registry, &state.data_dir).is_empty());
}

#[tokio::test]
async fn no_import_provenance_does_not_fall_back_to_builtin_sources() {
    let (state, calls) = fixture().await;
    std::fs::remove_file(state.data_dir.join("tvbox-sources.json")).unwrap();
    run_both(&state, &calls, &[]).await;
}

#[tokio::test]
async fn replacement_keeps_disabled_handle_out_of_search() {
    let registry = Registry::new();
    let calls = Arc::new(Mutex::new(vec![]));
    registry.register(provider("first", false, &calls));
    registry.register(provider("second", false, &calls));
    registry.set_enabled("first", false);
    registry.register(provider("first", false, &calls));
    assert_eq!(
        registry
            .manifests()
            .iter()
            .map(|m| m.id.as_str())
            .collect::<Vec<_>>(),
        ["first", "second"]
    );
    registry.search_all("scope", 1).await;
    assert_eq!(*calls.lock().unwrap(), ["second"]);
    calls.lock().unwrap().clear();
    registry.register_with_priority(provider("first", false, &calls), -1);
    registry.search_all("scope", 1).await;
    assert_eq!(*calls.lock().unwrap(), ["second"]);
}
