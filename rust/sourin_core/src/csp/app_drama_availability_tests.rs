use super::*;

const REASON: &str = "AppDrama 的浏览和播放能力尚未实现，配置已保留";
const EXT: &str = r#"{"site":"https://fixture.invalid/dispatch","appName":"fixture","dataKey":"fixture","publicKey":"fixture"}"#;

fn cached_classes() -> Vec<TvboxCategoryEntry> {
    vec![TvboxCategoryEntry { id: "old-category".into(), name: "Saved category".into(), pid: None }]
}

fn assert_unavailable(manifest: &ProviderManifest) {
    assert!(!manifest.working);
    assert!(!manifest.capabilities.vod);
    assert!(!manifest.capabilities.search);
    assert_eq!(manifest.broken_reason.as_deref(), Some(REASON));
}

#[test]
fn appdrama_constructor_reports_fixed_limit_and_preserves_configuration() {
    for (api, from_import, hidden) in [
        ("csp_AppDrama", true, true),
        (" csp_AppDrama?fixture=1 ", false, false),
    ] {
        let provider = CspProvider::new(
            "apple", "苹果", api, EXT, cached_classes(), from_import, hidden,
        ).unwrap();
        assert_unavailable(provider.manifest());
        assert_eq!(provider.manifest().id, "apple");
        assert_eq!(provider.manifest().name, "苹果");
        assert_eq!(provider.manifest().hidden, hidden);
        assert_eq!(provider.manifest().enabled, None, "availability must not rewrite the user's switch");
        assert_eq!(provider.api, api.trim());
        assert_eq!(provider.ext, EXT);
        assert_eq!(provider.classes, cached_classes());
    }

    // No probe result or ext validity is used as a permanent availability
    // verdict for implemented engines; their ordinary runtime errors remain.
    let other = CspProvider::new("other", "Other", "csp_AppRJ", "", vec![], true, true).unwrap();
    assert!(other.manifest().working);
    assert!(other.manifest().capabilities.vod);
    assert_eq!(other.manifest().broken_reason, None);
}

#[tokio::test]
async fn appdrama_home_fanout_excludes_even_saved_categories() {
    let registry = crate::registry::Registry::new();
    let provider = CspProvider::new(
        "apple", "苹果", "csp_AppDrama", EXT, cached_classes(), true, false,
    ).unwrap();
    // Cached categories would produce a nonempty home without any network if
    // the registry accidentally called it. This tests exclusion, not an error.
    registry.register(Arc::new(provider));
    assert!(registry.enabled_manifests().iter().any(|manifest| manifest.id == "apple"));
    assert!(registry.home_all().await.is_empty());
}

#[tokio::test]
async fn appdrama_restart_preserves_saved_config_and_both_enabled_choices() {
    use crate::model::PersistedProvider;
    use crate::state::AppState;

    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    let dir = std::env::temp_dir().join(format!(
        "sourin-appdrama-availability-{}-{}", std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos(),
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let rows: Vec<_> = ["apple-enabled", "apple-disabled"].into_iter().map(|id| {
        PersistedProvider::Tvbox {
            id: id.into(), name: id.into(), api: "csp_AppDrama".into(),
            categories: cached_classes(), parsers: vec![], ext: Some(EXT.into()),
        }
    }).collect();
    let saved_rows = serde_json::to_vec(&rows).unwrap();
    std::fs::write(dir.join("third-party-providers.json"), &saved_rows).unwrap();
    crate::commands::save_disabled(&dir, &["apple-disabled".into(), "demo".into()]).unwrap();
    // The fixture represents an existing user choice, after the unrelated
    // historical searchable-source migration has already completed.
    crate::provider_migration::preserve_current_selection(&dir).unwrap();
    crate::tvbox_aggregate::save(&dir, &crate::tvbox_aggregate::AggregateConfig {
        site_selection_explicit: true,
        enabled_site_ids: vec!["apple-enabled".into(), "apple-disabled".into()],
        ..Default::default()
    }).unwrap();

    for _ in 0..2 {
        let state = AppState::bootstrap(dir.clone()).await.unwrap();
        let listed = crate::commands::list_providers(&state).unwrap();
        for (id, enabled) in [("apple-enabled", true), ("apple-disabled", false)] {
            let manifest = listed.iter().find(|manifest| manifest.id == id).unwrap();
            assert_unavailable(manifest);
            assert!(!manifest.hidden, "the saved source and its reason stay visible in settings");
            assert_eq!(manifest.enabled, Some(enabled));
            assert_eq!(crate::commands::get_provider_enabled(&state, id).unwrap(), enabled);
        }
        assert!(state.registry.enabled_manifests().iter().any(|manifest| manifest.id == "apple-enabled"));
        assert!(state.registry.home_all().await.is_empty(), "unsupported sources never create an empty home tab");
        assert_eq!(*state.third_party.read().unwrap(), rows);
        assert_eq!(std::fs::read(dir.join("third-party-providers.json")).unwrap(), saved_rows);
        assert!(!crate::commands::load_disabled(&dir).iter().any(|id| id == "apple-enabled"));
        assert!(crate::commands::load_disabled(&dir).iter().any(|id| id == "apple-disabled"));
    }
}
