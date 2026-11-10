use super::*;
#[path = "app_drama_public_fixture.rs"]
mod app_drama_public_fixture;
use app_drama_public_fixture::{PublicFixture, ResponseMode};

fn cached_classes() -> Vec<TvboxCategoryEntry> {
    vec![TvboxCategoryEntry {
        id: "cat-one".into(),
        name: "Synthetic category".into(),
        pid: None,
    }]
}

fn assert_available(manifest: &ProviderManifest) {
    assert!(manifest.working);
    assert!(manifest.capabilities.vod);
    assert!(manifest.capabilities.search);
    assert_eq!(manifest.broken_reason, None);
}

#[test]
fn appdrama_constructor_declares_implemented_capabilities_without_rewriting_configuration() {
    let ext = app_drama_public_fixture::ext_for("http://127.0.0.1:1");
    for (api, from_import, hidden) in [
        ("csp_AppDrama", true, true),
        (" csp_AppDrama?fixture=1 ", false, false),
    ] {
        let provider = CspProvider::new(
            "apple",
            "苹果",
            api,
            &ext,
            cached_classes(),
            from_import,
            hidden,
        )
        .unwrap();
        assert_available(provider.manifest());
        assert_eq!(provider.manifest().id, "apple");
        assert_eq!(provider.manifest().name, "苹果");
        assert_eq!(provider.manifest().hidden, hidden);
        assert_eq!(
            provider.manifest().enabled,
            None,
            "implementation capability must not rewrite the user's enabled choice"
        );
        assert_eq!(provider.api, api.trim());
        assert_eq!(provider.ext, ext);
        assert_eq!(provider.classes, cached_classes());
        let routed = crate::csp::route(api).unwrap();
        assert_eq!(routed.class(), "AppDrama");
        assert!(routed.supports_search());
        assert!(routed.needs_ext());
        assert!(crate::csp::class_needs_ext("AppDrama"));
        assert_eq!(crate::csp::unimplemented_note(api), None);
    }
    // Invalid ext remains a runtime parse failure, not a permanent capability
    // or enabled-state verdict. Construction performs no network operation.
    let empty =
        CspProvider::new("empty", "Empty", "csp_AppDrama", "", vec![], true, false).unwrap();
    assert_available(empty.manifest());
    let other = CspProvider::new("other", "Other", "csp_AppRJ", "", vec![], true, true).unwrap();
    assert!(other.manifest().working && other.manifest().capabilities.vod);
    assert_eq!(other.manifest().broken_reason, None);
}

#[tokio::test]
async fn appdrama_home_fanout_includes_real_default_protocol_and_respects_disabled_choice() {
    let fixture = PublicFixture::new(ResponseMode::Normal).await;
    let registry = crate::registry::Registry::new();
    // Empty classes force the registered default constructor through its actual
    // dispatch/zone/categories HTTP path, rather than a cached or fake site.
    let provider = CspProvider::new(
        "apple",
        "苹果",
        "csp_AppDrama",
        &fixture.ext,
        vec![],
        true,
        false,
    )
    .unwrap()
    .with_proxy(fixture.store.clone());
    assert_available(provider.manifest());
    registry.register(Arc::new(provider));
    assert!(registry
        .enabled_manifests()
        .iter()
        .any(|manifest| manifest.id == "apple"));
    let homes = registry.home_all().await;
    let (_, name, sections) = homes.iter().find(|(id, _, _)| id == "apple").unwrap();
    assert_eq!(name, "苹果");
    assert_eq!(sections.len(), 1);
    assert_eq!(sections[0].title, "Synthetic category");
    assert!(matches!(&sections[0].source,
        crate::model::SectionSource::Category { category_id } if category_id == "cat-one"));
    assert_eq!(fixture.proxy.hits.lock().unwrap().len(), 3);
    fixture.assert_proxy_only();
    assert!(registry.set_enabled("apple", false));
    assert!(registry.home_all().await.is_empty());
    assert_eq!(
        fixture.proxy.hits.lock().unwrap().len(),
        3,
        "an implemented source still must not probe after the user disables it"
    );
}

#[tokio::test]
async fn appdrama_restart_preserves_saved_configuration_and_both_enabled_choices() {
    use crate::model::PersistedProvider;
    use crate::state::AppState;
    let fixture = PublicFixture::new(ResponseMode::Normal).await;
    let dir = crate::csp::http_context::test_support::scratch("appdrama-available-restore");
    let rows: Vec<_> = ["apple-enabled", "apple-disabled"]
        .into_iter()
        .map(|id| PersistedProvider::Tvbox {
            id: id.into(),
            name: id.into(),
            api: "csp_AppDrama".into(),
            categories: cached_classes(),
            parsers: vec![],
            ext: Some(fixture.ext.clone()),
        })
        .collect();
    let saved_rows = serde_json::to_vec(&rows).unwrap();
    std::fs::write(dir.join("third-party-providers.json"), &saved_rows).unwrap();
    crate::commands::save_disabled(&dir, &["apple-disabled".into(), "demo".into()]).unwrap();
    crate::provider_migration::preserve_current_selection(&dir).unwrap();
    crate::tvbox_aggregate::save(
        &dir,
        &crate::tvbox_aggregate::AggregateConfig {
            site_selection_explicit: true,
            enabled_site_ids: vec!["apple-enabled".into(), "apple-disabled".into()],
            ..Default::default()
        },
    )
    .unwrap();
    for _ in 0..2 {
        let before = fixture.proxy.hits.lock().unwrap().len();
        let state = AppState::bootstrap(dir.clone()).await.unwrap();
        crate::csp::http_context::test_support::custom(&state.proxy, &fixture.proxy.url);
        let listed = crate::commands::list_providers(&state).unwrap();
        for (id, enabled) in [("apple-enabled", true), ("apple-disabled", false)] {
            let manifest = listed.iter().find(|manifest| manifest.id == id).unwrap();
            assert_available(manifest);
            assert!(
                !manifest.hidden,
                "the public source list keeps restored children at the user-requested top level"
            );
            assert_eq!(manifest.enabled, Some(enabled));
            assert_eq!(
                crate::commands::get_provider_enabled(&state, id).unwrap(),
                enabled
            );
        }
        assert_eq!(
            fixture.proxy.hits.lock().unwrap().len(),
            before,
            "restoring registered capabilities must not probe at startup"
        );
        assert!(state
            .registry
            .enabled_manifests()
            .iter()
            .any(|manifest| manifest.id == "apple-enabled"));
        assert!(!state
            .registry
            .enabled_manifests()
            .iter()
            .any(|manifest| manifest.id == "apple-disabled"));
        let enabled = state.registry.get("apple-enabled").unwrap();
        let sections = enabled.home().await.unwrap();
        assert_eq!(sections[0].title, "Synthetic category");
        assert_eq!(
            fixture.proxy.hits.lock().unwrap().len(),
            before,
            "the exact saved categories remain usable without a startup/network refresh"
        );
        let page = enabled
            .list(crate::provider::ListRequest {
                category_id: "cat-one".into(),
                page: 2,
                filters: Default::default(),
            })
            .await
            .unwrap();
        assert_eq!(page.items[0].id.native, "1001");
        let result = enabled.search("synthetic-query", 1).await.unwrap();
        assert_eq!(result.items[0].id.native, "1001");
        assert_eq!(fixture.proxy.hits.lock().unwrap().len(), before + 4,
            "explicit restored list/search use default dispatch, zone and content, never a fake engine");
        assert_eq!(*state.third_party.read().unwrap(), rows);
        assert_eq!(
            std::fs::read(dir.join("third-party-providers.json")).unwrap(),
            saved_rows
        );
        assert!(!crate::commands::load_disabled(&dir)
            .iter()
            .any(|id| id == "apple-enabled"));
        assert!(crate::commands::load_disabled(&dir)
            .iter()
            .any(|id| id == "apple-disabled"));
        fixture.assert_proxy_only();
    }
    let _ = std::fs::remove_dir_all(dir);
}
