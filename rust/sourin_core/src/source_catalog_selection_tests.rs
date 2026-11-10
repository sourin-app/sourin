use super::*;
use crate::model::{
    Capabilities, MediaId, MediaItem, Page, PlayRequest, ProviderError,
    ProviderManifest, Section, SectionSource, StreamCandidate,
};
use crate::provider::MediaProvider;

struct SourceSpy {
    manifest: ProviderManifest,
    calls: Arc<Mutex<Vec<String>>>,
}

fn spy(id: &str, kind: &str, calls: &Arc<Mutex<Vec<String>>>) -> Arc<dyn MediaProvider> {
    Arc::new(SourceSpy {
        manifest: ProviderManifest {
            id: id.into(), name: id.into(), version: "1".into(), kind: kind.into(),
            description: None, icon: None, id_prefixes: vec![],
            capabilities: Capabilities { vod: true, search: true, ..Default::default() },
            hidden: kind == "tvbox", cover_headers: vec![], config: vec![], api_version: 1,
            theme_color: None, working: true, broken_reason: None, enabled: None,
        },
        calls: calls.clone(),
    })
}

#[async_trait::async_trait]
impl MediaProvider for SourceSpy {
    fn manifest(&self) -> &ProviderManifest { &self.manifest }

    async fn home(&self) -> Result<Vec<Section>, ProviderError> {
        self.calls.lock().unwrap().push(format!("home:{}", self.manifest.id));
        Ok(vec![Section {
            id: "home".into(), title: "Home".into(), items: vec![],
            source: SectionSource::Category { category_id: "home".into() },
        }])
    }

    async fn search(&self, _: &str, page: u32) -> Result<Page<MediaItem>, ProviderError> {
        self.calls.lock().unwrap().push(format!("search:{}", self.manifest.id));
        Ok(Page { items: vec![], page, page_count: None, total: None })
    }

    async fn resolve(&self, _: &MediaId, _: &PlayRequest) -> Result<Vec<StreamCandidate>, ProviderError> {
        Ok(vec![])
    }
}

fn scratch(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "sourin-source-selection-{tag}-{}-{}", std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos(),
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn imported_meta(dir: &Path, id: &str) {
    crate::tvbox::write_tvbox_meta(dir, id, &crate::tvbox::TvboxSourceMeta {
        source_url: Some("https://example.invalid/config".into()),
        site_key: id.into(), site_name: id.into(), api: "https://example.invalid/vod".into(),
        ..Default::default()
    }).unwrap();
}

async fn assert_dispatch(state: &AppState, calls: &Arc<Mutex<Vec<String>>>, expected: &[&str]) {
    let mut displayed: Vec<_> = crate::commands::list_providers(state).unwrap().into_iter()
        .filter(|manifest| manifest.enabled == Some(true)).map(|manifest| manifest.id).collect();
    displayed.sort();
    let mut expected_ids: Vec<_> = expected.iter().map(|id| id.to_string()).collect();
    expected_ids.sort();
    assert_eq!(displayed, expected_ids, "settings and home must keep the saved selection");
    calls.lock().unwrap().clear();
    let mut home: Vec<_> = state.registry.home_all().await.into_iter().map(|row| row.0).collect();
    home.sort();
    assert_eq!(home, expected_ids);
    crate::commands::search_all(state, "selection test", 1).await.unwrap();
    crate::commands::search_all_stream(state, "selection test", 1, |_| true).await.unwrap();
    let mut observed = calls.lock().unwrap().clone();
    observed.sort();
    let mut expected_calls: Vec<_> = expected.iter()
        .flat_map(|id| [format!("home:{id}"), format!("search:{id}"), format!("search:{id}")]).collect();
    expected_calls.sort();
    assert_eq!(observed, expected_calls, "hidden/disabled sources must never receive requests");
}

#[tokio::test]
async fn legacy_solo_boot_migrates_selection_and_manual_js_enable_survives_restart() {
    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    let dir = scratch("restart");
    let plugin_dir = crate::state::plugins_dir(&dir);
    std::fs::create_dir_all(&plugin_dir).unwrap();
    std::fs::write(plugin_dir.join("legacy-js.js"), r#"/**
 * @id legacy-js
 * @name Legacy JS
 * @version 1.0.0
 */
globalThis.plugin = {
  capabilities: { vod: true, search: true },
  async home() { return []; },
  async search(keyword, page) { return { items: [], page: page }; }
};"#).unwrap();
    let rows: Vec<_> = ["picked", "manually-disabled", "unselected"].into_iter().map(|id| {
        imported_meta(&dir, id);
        PersistedProvider::Tvbox {
            id: id.into(), name: id.into(), api: "https://example.invalid/vod".into(),
            categories: vec![], parsers: vec![], ext: None,
        }
    }).collect();
    std::fs::write(dir.join("third-party-providers.json"), serde_json::to_vec(&rows).unwrap()).unwrap();
    crate::commands::save_disabled(&dir, &["manually-disabled".into(), "absent-disabled".into()]).unwrap();
    crate::tvbox_aggregate::save(&dir, &crate::tvbox_aggregate::AggregateConfig {
        solo: true, site_selection_explicit: true,
        enabled_site_ids: vec!["picked".into(), "manually-disabled".into(), "unlinked-native".into()],
        hidden_site_ids: vec!["picked".into()],
        ..Default::default()
    }).unwrap();

    for restart in 0..2 {
        let state = AppState::bootstrap(dir.clone()).await.unwrap();
        assert!(!crate::tvbox_aggregate::load(&dir).solo, "bootstrap must consume legacy solo");
        assert!(state.registry.get("legacy-js").is_some(), "load a real JS manifest before replacing its methods with spies");
        assert!(crate::commands::load_disabled(&dir).contains(&"absent-disabled".into()));
        assert!(!crate::commands::get_provider_enabled(&state, "manually-disabled").unwrap());
        let calls = Arc::new(Mutex::new(Vec::new()));
        for id in ["picked", "manually-disabled", "unselected", "unlinked-native"] {
            state.registry.register(spy(id, "tvbox", &calls));
        }
        state.registry.register(spy("legacy-js", "js", &calls));
        sync_enabled(&state.registry, &dir);
        let expected: &[&str] = if restart == 0 { &["picked"] } else { &["picked", "legacy-js"] };
        assert_dispatch(&state, &calls, expected).await;
        assert!(!migrate_legacy_solo(&state.registry, &dir, &rows).unwrap(), "migration must run once");
        if restart == 0 {
            crate::commands_provider::set_enabled_persisted(&state, "legacy-js", true).unwrap();
            assert_dispatch(&state, &calls, &["picked", "legacy-js"]).await;
        }
        drop(state);
    }
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn legacy_solo_empty_disabled_aggregate_and_default_selection_do_not_revive_sources() {
    for (tag, explicit, aggregate_disabled, expected) in [
        ("empty", true, false, Vec::<String>::new()),
        ("aggregate-disabled", false, true, Vec::new()),
        ("default", false, false, vec!["picked".into()]),
    ] {
        let dir = scratch(tag);
        let registry = crate::registry::Registry::new();
        let calls = Arc::new(Mutex::new(Vec::new()));
        for id in ["picked", "manually-disabled"] {
            registry.register(spy(id, "tvbox", &calls));
            imported_meta(&dir, id);
        }
        registry.register(spy("old-js", "js", &calls));
        let mut disabled = vec!["manually-disabled".into()];
        if aggregate_disabled { disabled.push(crate::tvbox_aggregate::AGGREGATE_ID.into()); }
        crate::commands::save_disabled(&dir, &disabled).unwrap();
        crate::tvbox_aggregate::save(&dir, &crate::tvbox_aggregate::AggregateConfig {
            solo: true, site_selection_explicit: explicit,
            hidden_site_ids: vec!["picked".into()], ..Default::default()
        }).unwrap();
        let pending = vec![PersistedProvider::Http {
            id: "late-http".into(), base_url: "http://127.0.0.1:1".into(), headers: Default::default(),
        }];
        assert!(migrate_legacy_solo(&registry, &dir, &pending).unwrap());
        sync_enabled(&registry, &dir);
        assert_eq!(crate::tvbox_aggregate::load(&dir).enabled_site_ids, expected);
        assert_eq!(registry.enabled_manifests().iter().map(|m| m.id.clone()).collect::<Vec<_>>(), expected);
        // Pending HTTP restoration must not expose even one enabled snapshot.
        registry.register_with_default_enabled(spy("late-http", "http", &calls),
            !crate::commands::load_disabled(&dir).contains(&"late-http".into()));
        assert!(!registry.enabled_manifests().iter().any(|m| m.id == "late-http"));
        assert_eq!(crate::provider_migration::run_once(&dir, &registry.manifests()), None,
            "the obsolete automatic restore must not undo this explicit selection");
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn legacy_solo_save_failure_rolls_back_switches_and_keeps_migration_pending() {
    let dir = scratch("rollback");
    let registry = crate::registry::Registry::new();
    let calls = Arc::new(Mutex::new(Vec::new()));
    registry.register(spy("old-js", "js", &calls));
    let disabled = vec!["already-disabled".into()];
    crate::commands::save_disabled(&dir, &disabled).unwrap();
    crate::tvbox_aggregate::save(&dir, &crate::tvbox_aggregate::AggregateConfig {
        solo: true, ..Default::default()
    }).unwrap();
    std::fs::create_dir(dir.join("tvbox-aggregate.json.tmp")).unwrap();
    assert!(migrate_legacy_solo(&registry, &dir, &[]).is_err());
    assert_eq!(crate::commands::load_disabled(&dir), disabled);
    assert!(crate::tvbox_aggregate::load(&dir).solo);
    assert!(registry.enabled_manifests().iter().any(|m| m.id == "old-js"), "failed disk writes must not mutate handles");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn normal_source_selection_is_not_treated_as_legacy_solo() {
    let dir = scratch("normal");
    let registry = crate::registry::Registry::new();
    let calls = Arc::new(Mutex::new(Vec::new()));
    registry.register(spy("normal-js", "js", &calls));
    assert!(!migrate_legacy_solo(&registry, &dir, &[]).unwrap());
    assert!(!dir.join("disabled-providers.json").exists());
    assert!(!dir.join("provider-migration.json").exists());
    assert!(registry.enabled_manifests().iter().any(|m| m.id == "normal-js"));
    std::fs::remove_dir_all(dir).unwrap();
}
