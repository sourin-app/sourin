use super::*;

fn scratch(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "sourin-source-identity-{tag}-{}-{}", std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos(),
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn source<'a>(catalog: &'a SourceCatalog, id: &str) -> &'a SourceOrigin {
    let origins: Vec<_> = catalog.origins.iter()
        .filter(|origin| origin.provider_ids.iter().any(|provider| provider == id)).collect();
    assert_eq!(origins.len(), 1, "each provider must have exactly one origin: {id}");
    origins[0]
}

fn assert_provider_groups(catalog: &SourceCatalog, expected: &[&[&str]]) {
    let mut actual: Vec<_> = catalog.origins.iter().map(|origin| {
        let mut ids = origin.provider_ids.clone();
        ids.sort();
        ids
    }).collect();
    let mut expected: Vec<Vec<String>> = expected.iter().map(|ids| {
        let mut ids: Vec<_> = ids.iter().map(|id| id.to_string()).collect();
        ids.sort();
        ids
    }).collect();
    actual.sort();
    expected.sort();
    assert_eq!(actual, expected, "every expected provider must retain its exact origin membership");
}

#[test]
fn absent_urls_and_shared_js_download_urls_never_imply_shared_identity() {
    let mut catalog = SourceCatalog::default();
    for (kind, id, url) in [
        ("js", "local-a", ""), ("js", "local-b", " \t "),
        ("js", "remote-a", "https://download.invalid/plugin.js"),
        ("js", "remote-b", "https://download.invalid/plugin.js"),
        ("tvbox", "local-tv-a", ""), ("tvbox", "local-tv-b", " \n "),
        ("tvbox", "remote-tv-a", "https://subscription.invalid/config"),
        ("tvbox", "remote-tv-b", "https://subscription.invalid/config"),
    ] {
        add_legacy(&mut catalog, &legacy_origin(kind, id, url, id));
    }
    assert_eq!(catalog.origins.len(), 7);
    assert_ne!(source(&catalog, "remote-a").id, source(&catalog, "remote-b").id);
    assert_eq!(source(&catalog, "local-b").primary_url, "");
    assert_eq!(source(&catalog, "local-tv-b").primary_url, "");
    assert_eq!(source(&catalog, "remote-tv-a").provider_ids.len(), 2);
    let old_empty = SourceOrigin {
        id: origin_id("js", ""), kind: "js".into(),
        backup_urls: vec!["".into()], last_successful_url: Some("".into()),
        ..Default::default()
    };
    assert!(!has_url(&old_empty, ""));
    assert!(!has_url(&old_empty, " \t "));
    assert!(matching_origin(&catalog, "tvbox", None, "").is_none());
}

#[test]
fn persisted_32_plugin_group_splits_and_preserves_only_identifiable_owner_edits() {
    let sources: Vec<_> = (0..32).map(|index| {
        legacy_origin("js", &format!("Plugin {index}"), "", &format!("plugin-{index}"))
    }).collect();
    let old = SourceOrigin {
        id: "js-local-plugin-0".into(), name: "Custom first plugin".into(), kind: "js".into(),
        primary_url: "https://first.invalid/plugin.js".into(),
        backup_urls: vec!["https://first-backup.invalid/plugin.js".into()],
        last_successful_endpoint: Some("https://first-backup.invalid/plugin.js".into()),
        last_successful_url: Some("https://first-cdn.invalid/plugin.js".into()),
        last_success_at: 100,
        provider_ids: sources.iter().map(|entry| entry.provider_ids[0].clone()).collect(),
        related_provider_ids: Vec::new(),
        ..Default::default()
    };
    let mut catalog = SourceCatalog { origins: vec![old.clone()], ..Default::default() };
    reconcile_origins(&mut catalog, &sources);
    assert_eq!(catalog.origins.len(), 32);
    let first = source(&catalog, "plugin-0");
    assert_eq!(first.id, "js-plugin-0");
    assert_eq!(first.name, old.name);
    assert_eq!(first.primary_url, old.primary_url);
    assert_eq!(first.backup_urls, old.backup_urls);
    assert_eq!(first.last_success_at, old.last_success_at);
    for expected in sources.iter().skip(1) {
        assert_eq!(source(&catalog, &expected.provider_ids[0]), expected);
    }
    let repaired = catalog.origins.clone();
    reconcile_origins(&mut catalog, &sources);
    assert_eq!(catalog.origins, repaired, "repair must remain stable across reads/restarts");
}

#[test]
fn ambiguous_shared_js_group_uses_each_sidecar_and_drops_unattributable_backups() {
    let shared = "https://download.invalid/current.js";
    let sources = vec![legacy_origin("js", "Alpha", shared, "alpha"),
        legacy_origin("js", "Beta", shared, "beta")];
    let mut catalog = SourceCatalog {
        origins: vec![SourceOrigin {
            id: origin_id("js", shared), name: "Misleading old shared label".into(), kind: "js".into(),
            primary_url: shared.into(), backup_urls: vec!["https://ambiguous.invalid/plugin.js".into()],
            provider_ids: vec!["alpha".into(), "beta".into()], last_success_at: 123,
            ..Default::default()
        }], ..Default::default()
    };
    reconcile_origins(&mut catalog, &sources);
    assert_eq!(catalog.origins, sources);

    // Removing the original owner must not turn a formerly merged group into
    // an apparently valid singleton carrying the missing plugin's addresses.
    let mut old_local = legacy_origin("js", "Missing", "https://missing.invalid/plugin.js", "missing");
    old_local.id = "js-local-missing".into();
    old_local.provider_ids.push("survivor".into());
    let survivor = legacy_origin("js", "Survivor", "", "survivor");
    catalog.origins = vec![old_local];
    reconcile_origins(&mut catalog, &[survivor.clone()]);
    assert_eq!(catalog.origins, vec![survivor]);
}

#[test]
fn shared_url_lookups_and_success_never_borrow_another_providers_settings() {
    let dir = scratch("lookup");
    let shared = "https://download.invalid/current.js";
    let mut alpha = legacy_origin("js", "Alpha", shared, "alpha");
    alpha.backup_urls = vec!["https://alpha-backup.invalid/plugin.js".into()];
    alpha.last_success_at = now_secs();
    alpha.last_successful_endpoint = Some(alpha.backup_urls[0].clone());
    let mut beta = legacy_origin("js", "Beta", shared, "beta");
    beta.backup_urls = vec!["https://beta-backup.invalid/plugin.js".into()];
    save(&dir, &SourceCatalog { origins: vec![alpha.clone(), beta.clone()], ..Default::default() }).unwrap();
    assert_eq!(urls_for(&dir, "js", Some("beta"), shared), vec![shared.to_owned(), beta.backup_urls[0].clone()]);
    assert_eq!(urls_for(&dir, "js", Some("alpha"), shared)[0], alpha.backup_urls[0]);
    assert_eq!(urls_for(&dir, "js", Some("missing"), shared), vec![shared]);
    record_success(&dir, "js", Some("beta"), shared, "https://beta-cdn.invalid/plugin.js", &beta.backup_urls[0]);
    let updated = load(&dir);
    assert_eq!(source(&updated, "alpha"), &alpha);
    assert_eq!(source(&updated, "beta").last_successful_endpoint, Some(beta.backup_urls[0].clone()));
    assert_eq!(urls_for(&dir, "js", Some("beta"), shared)[0], beta.backup_urls[0]);
    record_success(&dir, "js", Some("missing"), shared, "https://unknown.invalid", shared);
    assert_eq!(load(&dir).origins, updated.origins);
    assert_eq!(primary_for(&dir, "js", "beta").as_deref(), Some(shared));

    let mut remote_a = legacy_origin("tvbox", "A", "https://a.invalid/config", "tv-a");
    let remote_b = legacy_origin("tvbox", "B", "https://b.invalid/config", "tv-b");
    remote_a.backup_urls.push(remote_b.primary_url.clone());
    let catalog = SourceCatalog { origins: vec![remote_a, remote_b], ..Default::default() };
    assert_eq!(matching_origin(&catalog, "tvbox", None, "https://b.invalid/config"), Some(1));
}

#[test]
fn local_tvbox_groups_split_but_real_subscription_groups_keep_configuration() {
    let sources = vec![
        legacy_origin("tvbox", "Local A", "", "local-a"),
        legacy_origin("tvbox", "Local B", "", "local-b"),
        legacy_origin("tvbox", "Remote", "https://remote.invalid/config", "remote-a"),
        legacy_origin("tvbox", "Remote", "https://remote.invalid/config", "remote-b"),
    ];
    let mut local = sources[0].clone();
    local.provider_ids.push("local-b".into());
    let mut remote = sources[2].clone();
    remote.name = "My subscription".into();
    remote.backup_urls.push("https://remote-backup.invalid/config".into());
    remote.provider_ids.push("remote-b".into());
    let mut catalog = SourceCatalog { origins: vec![local, remote.clone()], ..Default::default() };
    reconcile_origins(&mut catalog, &sources);
    assert_eq!(catalog.origins.len(), 3);
    assert_eq!(source(&catalog, "local-a"), &sources[0]);
    assert_eq!(source(&catalog, "local-b"), &sources[1]);
    assert_eq!(source(&catalog, "remote-a"), &remote);
}

fn install_fixture(dir: &Path, id: &str, name: &str, url: Option<&str>) {
    let plugins = crate::state::plugins_dir(dir);
    std::fs::create_dir_all(&plugins).unwrap();
    std::fs::write(plugins.join(format!("{id}.js")), format!(r#"/**
 * @id {id}
 * @name {name}
 * @version 1.0.0
 */
globalThis.plugin = {{
  capabilities: {{ vod: true, search: true }},
  async home() {{ return []; }},
  async search(keyword, page) {{ return {{ items: [], page: page }}; }}
}};"#)).unwrap();
    if let Some(url) = url {
        crate::plugins::write_plugin_meta(&plugins, id, &crate::plugins::PluginSourceMeta {
            source_url: Some(url.into()), file: format!("{id}.js"), ..Default::default()
        }).unwrap();
    }
}

#[tokio::test]
async fn bootstrap_repairs_saved_origins_and_edits_updates_and_restart_stay_isolated() {
    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    let dir = scratch("bootstrap");
    let shared = "https://download.invalid/current.js";
    for (id, url) in [("local-alpha", None), ("local-beta", None),
        ("remote-alpha", Some(shared)), ("remote-beta", Some(shared))] {
        install_fixture(&dir, id, id, url);
    }
    let rows: Vec<_> = ["local-tv-a", "local-tv-b", "remote-tv-a", "remote-tv-b"].into_iter().map(|id| {
        crate::tvbox::write_tvbox_meta(&dir, id, &crate::tvbox::TvboxSourceMeta {
            source_url: id.starts_with("remote").then(|| "https://remote.invalid/config".into()),
            site_key: id.into(), site_name: id.into(), api: "https://api.invalid/vod".into(),
            last_update_at: now_secs(), last_update_ok: true,
            ..Default::default()
        }).unwrap();
        PersistedProvider::Tvbox {
            id: id.into(), name: id.into(), api: "https://api.invalid/vod".into(),
            categories: vec![], parsers: vec![], ext: None,
        }
    }).collect();
    std::fs::write(dir.join("third-party-providers.json"), serde_json::to_vec(&rows).unwrap()).unwrap();
    let mut local = legacy_origin("js", "local-alpha", "", "local-alpha");
    local.id = "js-local-local-alpha".into();
    local.provider_ids.push("local-beta".into());
    let mut remote = legacy_origin("js", "remote-alpha", shared, "remote-alpha");
    remote.id = origin_id("js", shared);
    remote.provider_ids.push("remote-beta".into());
    let mut local_tv = legacy_origin("tvbox", "Local", "", "local-tv-a");
    local_tv.provider_ids.push("local-tv-b".into());
    save(&dir, &SourceCatalog { origins: vec![local, remote, local_tv], ..Default::default() }).unwrap();

    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    let repaired = load(&dir);
    // Bootstrap also installs the shipped demo.js. It must remain an
    // independent local origin, alongside all repaired fixture identities.
    assert_provider_groups(&repaired, &[
        &["local-alpha"], &["local-beta"], &["remote-alpha"], &["remote-beta"],
        &["local-tv-a"], &["local-tv-b"], &["remote-tv-a", "remote-tv-b"], &["demo"],
    ]);
    assert_eq!(source(&repaired, "remote-tv-a").provider_ids.len(), 2);
    assert_eq!(source(&repaired, "local-beta").name, "local-beta");
    let other_js = source(&repaired, "local-beta").clone();
    let other_tv = source(&repaired, "local-tv-b").clone();
    command_set_origin(&state, &serde_json::json!({
        "id": source(&repaired, "local-alpha").id, "name": "Custom alpha",
        "primaryUrl": "https://alpha.invalid/plugin.js", "backupUrls": ["https://alpha-backup.invalid/plugin.js"]
    })).unwrap();
    command_set_origin(&state, &serde_json::json!({
        "id": source(&repaired, "local-tv-a").id, "primaryUrl": "https://local-a.invalid/config"
    })).unwrap();
    record_plugin(&state, "remote-beta", "Beta", shared, &["https://beta-backup.invalid/plugin.js".into()],
        "https://beta-cdn.invalid/plugin.js", shared).unwrap();
    let updated = load(&dir);
    assert_eq!(source(&updated, "local-beta"), &other_js);
    assert_eq!(source(&updated, "local-tv-b"), &other_tv);
    assert_eq!(source(&updated, "remote-alpha"), source(&repaired, "remote-alpha"));
    assert_eq!(urls_for(&dir, "js", Some("remote-beta"), shared),
        vec![shared, "https://beta-backup.invalid/plugin.js"]);
    assert_eq!(crate::tvbox::read_tvbox_meta(&dir, "local-tv-b").unwrap().source_url, None);
    assert!(primary_for(&dir, "js", "local-beta").is_none());
    drop(state);
    let restarted = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_eq!(load(&dir).origins, updated.origins);
    assert_eq!(catalog(&restarted).unwrap().origins, updated.origins);
}

#[tokio::test]
async fn catalog_read_and_mutation_repair_saved_groups_and_failed_save_keeps_original() {
    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    let dir = scratch("read-mutation");
    install_fixture(&dir, "alpha", "Alpha", None);
    install_fixture(&dir, "beta", "Beta", None);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    let mut merged = legacy_origin("js", "Alpha", "", "alpha");
    merged.id = "js-local-alpha".into();
    merged.provider_ids.push("beta".into());
    let old = SourceCatalog { origins: vec![merged], ..Default::default() };
    save(&dir, &old).unwrap();
    std::fs::create_dir(dir.join("source-catalog.json.tmp")).unwrap();
    assert!(catalog(&state).is_err());
    assert_eq!(load(&dir).origins, old.origins);
    std::fs::remove_dir(dir.join("source-catalog.json.tmp")).unwrap();
    let value = command_get(&state).unwrap();
    let displayed: SourceCatalog = serde_json::from_value(value).unwrap();
    assert_provider_groups(&displayed, &[&["alpha"], &["beta"], &["demo"]]);
    assert_eq!(load(&dir).origins, displayed.origins);
    save(&dir, &old).unwrap();
    command_set_origin(&state, &serde_json::json!({
        "id": "js-alpha", "primaryUrl": "https://alpha.invalid/plugin.js"
    })).unwrap();
    let updated = load(&dir);
    assert_eq!(source(&updated, "alpha").primary_url, "https://alpha.invalid/plugin.js");
    assert_eq!(source(&updated, "beta").primary_url, "");
}

struct ExtIdentitySpy {
    manifest: crate::model::ProviderManifest,
}

#[async_trait::async_trait]
impl crate::provider::MediaProvider for ExtIdentitySpy {
    fn manifest(&self) -> &crate::model::ProviderManifest {
        &self.manifest
    }

    async fn resolve(
        &self,
        _: &crate::model::MediaId,
        _: &crate::model::PlayRequest,
    ) -> Result<Vec<crate::model::StreamCandidate>, crate::model::ProviderError> {
        Ok(vec![])
    }
}

fn register_ext_identity_fixture(state: &AppState, id: &str, ext: Option<&str>) {
    state.registry.register(Arc::new(ExtIdentitySpy {
        manifest: crate::model::ProviderManifest {
            id: id.into(), name: "Shared site key".into(), version: "1".into(),
            kind: "tvbox".into(), description: None, icon: None, id_prefixes: vec![],
            capabilities: crate::model::Capabilities {
                vod: true, search: true, ..Default::default()
            },
            hidden: true, cover_headers: vec![], config: vec![], api_version: 1,
            theme_color: None, working: true, broken_reason: None, enabled: None,
        },
    }));
    state.third_party.write().unwrap().push(PersistedProvider::Tvbox {
        id: id.into(), name: "Shared site key".into(), api: "csp_XBPQ".into(),
        categories: vec![], parsers: vec![], ext: ext.map(str::to_owned),
    });
    crate::tvbox::write_tvbox_meta(&state.data_dir, id, &crate::tvbox::TvboxSourceMeta {
        source_url: Some(format!("https://{id}.invalid/config")),
        site_key: "xbpq".into(), site_name: "Shared site key".into(),
        api: "csp_XBPQ".into(), ..Default::default()
    }).unwrap();
}

#[tokio::test]
async fn different_csp_ext_is_not_an_alternative_provider_for_the_same_child() {
    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    let dir = scratch("csp-ext-isolation");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    // Registration after bootstrap avoids initializing a network-backed CSP.
    // The production catalog and selection commands are still used directly.
    register_ext_identity_fixture(&state, "mirror-a", Some("https://rules-a.invalid/xbpq.json"));
    register_ext_identity_fixture(&state, "mirror-b", Some("https://rules-a.invalid/xbpq.json"));
    register_ext_identity_fixture(&state, "independent", Some("https://rules-b.invalid/xbpq.json"));
    sync_enabled(&state.registry, &dir);
    let original_configs = serde_json::to_value(&*state.third_party.read().unwrap()).unwrap();
    let before = catalog(&state).unwrap();
    let shared = before.groups.iter().find(|g| g.provider_ids.contains(&"mirror-a".into())).unwrap();
    assert_eq!(shared.provider_ids, vec!["mirror-a", "mirror-b"],
        "different CSP ext describes a separate source, not another provider for this source");
    let independent = before.groups.iter().find(|g| g.provider_ids.contains(&"independent".into())).unwrap();
    assert_eq!(independent.provider_ids, vec!["independent"]);
    let shared_id = shared.id.clone();
    let independent_id = independent.id.clone();
    let original_origins = before.origins.clone();

    command_select(&state, &shared_id, &["mirror-b".into()]).unwrap();
    let after = catalog(&state).unwrap();
    assert_eq!(after.origins, original_origins, "provider choices do not rewrite source addresses");
    assert_eq!(source(&after, "independent"), source(&before, "independent"));
    assert_eq!(serde_json::to_value(&*state.third_party.read().unwrap()).unwrap(), original_configs);
    let selected = crate::commands::list_providers(&state).unwrap();
    let enabled = |id: &str| selected.iter().find(|p| p.id == id).unwrap().enabled;
    assert_eq!(enabled("mirror-a"), Some(false));
    assert_eq!(enabled("mirror-b"), Some(true));
    assert_eq!(enabled("independent"), Some(true), "choosing a mirror must leave a different source enabled");
    assert_eq!(after.groups.iter().find(|g| g.id == shared_id).unwrap().selected_provider_ids,
        vec!["mirror-b"]);
    assert_eq!(after.groups.iter().find(|g| g.id == independent_id).unwrap().selected_provider_ids,
        vec!["independent"]);

    command_select(&state, &shared_id, &[]).unwrap();
    let all_off = crate::commands::list_providers(&state).unwrap();
    assert_eq!(all_off.iter().find(|p| p.id == "independent").unwrap().enabled, Some(true));
    assert_eq!(all_off.iter().find(|p| p.id == "mirror-b").unwrap().enabled, Some(false));
    drop(state);
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn missing_and_empty_ext_keep_legacy_provider_group_identity() {
    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    let dir = scratch("csp-ext-empty");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    register_ext_identity_fixture(&state, "unset", None);
    register_ext_identity_fixture(&state, "blank", Some(" \t "));
    sync_enabled(&state.registry, &dir);
    let current = catalog(&state).unwrap();
    let group = current.groups.iter().find(|g| g.provider_ids.contains(&"unset".into())).unwrap();
    assert_eq!(group.provider_ids, vec!["unset", "blank"]);
    assert_eq!(group.id, format!("site-{}", crate::m3u::stable_key("xbpq\ncsp_XBPQ")));
    assert_eq!(group.selected_provider_ids, vec!["unset", "blank"]);
    drop(state);
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn trimmed_ext_groups_mirrors_without_reviving_independent_disabled_source() {
    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    let dir = scratch("csp-ext-disabled");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    register_ext_identity_fixture(&state, "mirror-a", Some("https://rules-a.invalid/xbpq.json"));
    register_ext_identity_fixture(&state, "mirror-b", Some(" \nhttps://rules-a.invalid/xbpq.json\t "));
    register_ext_identity_fixture(&state, "independent", Some("{\"host\":\"https://rules-b.invalid\"}"));
    sync_enabled(&state.registry, &dir);
    assert!(crate::commands_provider::set_enabled_persisted(&state, "independent", false).unwrap());
    let before = catalog(&state).unwrap();
    let group = before.groups.iter().find(|g| g.provider_ids.contains(&"mirror-a".into())).unwrap();
    assert_eq!(group.provider_ids, vec!["mirror-a", "mirror-b"]);
    let independent = before.groups.iter().find(|g| g.provider_ids.contains(&"independent".into())).unwrap();
    assert!(independent.selected_provider_ids.is_empty());
    command_select(&state, &group.id, &["mirror-b".into()]).unwrap();
    assert!(!crate::commands::get_provider_enabled(&state, "independent").unwrap());
    assert!(crate::commands::load_disabled(&dir).contains(&"independent".to_owned()));
    assert!(crate::commands::get_provider_enabled(&state, "mirror-b").unwrap());
    drop(state);
    let _ = std::fs::remove_dir_all(dir);
}
