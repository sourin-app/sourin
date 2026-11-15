use super::*;
use axum::{
    http::{StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::get,
};
use std::sync::atomic::{AtomicUsize, Ordering};

fn scratch(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "sourin-source-lifecycle-{tag}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos(),
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

async fn serve(app: axum::Router) -> (String, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (base, task)
}

async fn proxy_fixture<F>(
    respond: F,
) -> (String, Arc<Mutex<Vec<String>>>, tokio::task::JoinHandle<()>)
where
    F: Fn(&Uri) -> Response + Send + Sync + 'static,
{
    let requests = Arc::new(Mutex::new(Vec::new()));
    let observed = requests.clone();
    let respond = Arc::new(respond);
    let app = axum::Router::new().fallback(get(move |uri: Uri| {
        let observed = observed.clone();
        let respond = respond.clone();
        async move {
            observed.lock().unwrap().push(uri.to_string());
            respond(&uri)
        }
    }));
    let (base, server) = serve(app).await;
    (base, requests, server)
}

fn use_proxy(state: &AppState, url: &str) {
    state
        .proxy
        .set(
            crate::proxy::GLOBAL_PROXY,
            crate::proxy::ProxyConfig {
                mode: crate::proxy::ProxyMode::Custom,
                url: Some(url.into()),
                ..Default::default()
            },
        )
        .unwrap();
}

fn assert_proxy(state: &AppState, url: &str) {
    let policy = state.proxy.get(crate::proxy::GLOBAL_PROXY);
    assert_eq!(policy.mode, crate::proxy::ProxyMode::Custom);
    assert_eq!(policy.url.as_deref(), Some(url));
}

fn assert_disabled(state: &AppState, id: &str) {
    assert!(state.registry.get(id).is_some());
    assert!(!state
        .registry
        .enabled_manifests()
        .iter()
        .any(|m| m.id == id));
    assert!(crate::commands::list_providers(state)
        .unwrap()
        .iter()
        .any(|m| m.id == id && m.enabled == Some(false)));
    assert!(crate::commands::load_disabled(&state.data_dir)
        .iter()
        .any(|entry| entry == id));
}

fn expire_success(dir: &Path, id: &str) {
    let mut catalog = load(dir);
    catalog
        .origins
        .iter_mut()
        .find(|origin| origin.provider_ids.iter().any(|pid| pid == id))
        .unwrap()
        .last_success_at = now_secs() - 301;
    save(dir, &catalog).unwrap();
}

fn plugin_script(version: usize) -> String {
    format!(
        r#"/**
 * @id lifecycle-js
 * @name Lifecycle JS
 * @version {version}.0.0
 */
 globalThis.plugin = {{
   capabilities: {{ vod: true, search: true }},
   async home() {{ return []; }},
   async search(keyword, page) {{ return {{ items: [], page: page }}; }}
 }};"#
    )
}

#[tokio::test]
async fn js_install_and_update_fail_over_through_global_proxy_and_preserve_disabled_on_restart() {
    let version = Arc::new(AtomicUsize::new(1));
    let remote_version = version.clone();
    let (proxy, requests, server) = proxy_fixture(move |uri| match uri.path() {
        "/primary.js" => StatusCode::SERVICE_UNAVAILABLE.into_response(),
        "/backup.js" => (
            StatusCode::TEMPORARY_REDIRECT,
            [("location", "http://plugins.invalid/releases/plugin.js")],
        )
            .into_response(),
        "/releases/plugin.js" => {
            plugin_script(remote_version.load(Ordering::SeqCst)).into_response()
        }
        _ => StatusCode::NOT_FOUND.into_response(),
    })
    .await;
    let primary = "http://plugins.invalid/primary.js";
    let backup = "http://plugins.invalid/backup.js";
    let actual = "http://plugins.invalid/releases/plugin.js";
    let dir = scratch("js");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let installed =
        crate::commands_remote::install_plugin_with_backups(&state, primary, &[backup.into()])
            .await
            .unwrap();
    assert_eq!(installed["id"], "lifecycle-js");
    assert_eq!(installed["version"], "1.0.0");
    assert_eq!(installed["resolvedUrl"], actual);
    assert_eq!(
        requests.lock().unwrap().as_slice(),
        &[primary, backup, actual]
    );
    let file = installed["file"].as_str().unwrap().to_owned();
    assert_eq!(
        std::fs::read_to_string(crate::state::plugins_dir(&dir).join(&file)).unwrap(),
        plugin_script(1)
    );
    assert!(
        crate::commands_provider::set_enabled_persisted(&state, "lifecycle-js", false).unwrap()
    );
    drop(state);

    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_proxy(&state, &proxy);
    assert_disabled(&state, "lifecycle-js");
    let origin = load(&dir)
        .origins
        .into_iter()
        .find(|o| o.provider_ids == ["lifecycle-js"])
        .unwrap();
    assert_eq!(origin.primary_url, primary);
    assert_eq!(origin.backup_urls, [backup]);
    assert_eq!(origin.last_successful_endpoint.as_deref(), Some(backup));
    assert_eq!(origin.last_successful_url.as_deref(), Some(actual));
    version.store(2, Ordering::SeqCst);
    expire_success(&dir, "lifecycle-js");
    requests.lock().unwrap().clear();
    let checked = crate::commands_provider::check_plugin_update(&state, "lifecycle-js")
        .await
        .unwrap();
    assert!(checked.has_update && checked.error.is_none());
    assert_eq!(checked.remote_version.as_deref(), Some("2.0.0"));
    assert_eq!(checked.source_url.as_deref(), Some(primary));
    assert_eq!(
        requests.lock().unwrap().as_slice(),
        &[primary, backup, actual]
    );
    assert_disabled(&state, "lifecycle-js");
    expire_success(&dir, "lifecycle-js");
    requests.lock().unwrap().clear();
    let updated = crate::commands_provider::update_plugin_from_source(&state, "lifecycle-js")
        .await
        .unwrap();
    assert_eq!(updated["updated"], true);
    assert_eq!(updated["version"], "2.0.0");
    assert_eq!(
        requests.lock().unwrap().as_slice(),
        &[primary, backup, actual]
    );
    assert_eq!(
        state
            .registry
            .get("lifecycle-js")
            .unwrap()
            .manifest()
            .version,
        "2.0.0"
    );
    assert_disabled(&state, "lifecycle-js");
    assert_proxy(&state, &proxy);
    drop(state);

    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_disabled(&state, "lifecycle-js");
    assert_proxy(&state, &proxy);
    assert_eq!(
        state
            .registry
            .get("lifecycle-js")
            .unwrap()
            .manifest()
            .version,
        "2.0.0"
    );
    assert_eq!(
        std::fs::read_to_string(crate::state::plugins_dir(&dir).join(&file)).unwrap(),
        plugin_script(2)
    );
    let origin = load(&dir)
        .origins
        .into_iter()
        .find(|o| o.provider_ids == ["lifecycle-js"])
        .unwrap();
    assert_eq!(origin.primary_url, primary);
    assert_eq!(origin.backup_urls, [backup]);
    assert_eq!(origin.last_successful_endpoint.as_deref(), Some(backup));
    assert_eq!(origin.last_successful_url.as_deref(), Some(actual));
    drop(state);
    server.abort();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn live_import_refresh_and_restart_keep_proxy_fallback_relative_assets_and_disabled_state() {
    let version = Arc::new(AtomicUsize::new(1));
    let remote_version = version.clone();
    let (proxy, requests, server) = proxy_fixture(move |uri| match uri.path() {
        "/primary.m3u" => StatusCode::BAD_GATEWAY.into_response(),
        "/backup.m3u" => (StatusCode::TEMPORARY_REDIRECT,
            [("location", "http://live.invalid/cdn/channel/list.m3u")]).into_response(),
        "/cdn/channel/list.m3u" => {
            let version = remote_version.load(Ordering::SeqCst);
            format!("#EXTM3U\n#EXTINF:-1 tvg-id=\"fixture\" tvg-logo=\"../logos/station-{version}.png\",Fixture {version}\n./streams/station-{version}.m3u8\n").into_response()
        }
        _ => StatusCode::NOT_FOUND.into_response(),
    }).await;
    let primary = "http://live.invalid/primary.m3u";
    let backup = "http://live.invalid/backup.m3u";
    let actual = "http://live.invalid/cdn/channel/list.m3u";
    let dir = scratch("live");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let imported = import_live(&state, primary, "Proxy live", &[backup.into()])
        .await
        .unwrap();
    let id = imported["id"].as_str().unwrap().to_owned();
    assert_eq!(
        requests.lock().unwrap().as_slice(),
        &[primary, backup, actual]
    );
    for manifest in state.registry.manifests() {
        if manifest.id != id {
            state.registry.set_enabled(&manifest.id, false);
        }
    }
    requests.lock().unwrap().clear();
    let first = crate::commands::get_live_channels(&state).await.unwrap();
    assert_eq!(first.len(), 1);
    assert_eq!(first[0]["provider"], id);
    assert_eq!(first[0]["channels"][0]["name"], "Fixture 1");
    assert_eq!(
        first[0]["channels"][0]["logo"],
        "http://live.invalid/cdn/logos/station-1.png"
    );
    let channel = first[0]["channels"][0]["id"].as_str().unwrap();
    let streams = crate::commands::get_live_stream(&state, &id, channel)
        .await
        .unwrap();
    assert_eq!(
        streams[0].url,
        "http://live.invalid/cdn/channel/streams/station-1.m3u8"
    );
    assert_eq!(requests.lock().unwrap().as_slice(), &[backup, actual]);

    version.store(2, Ordering::SeqCst);
    expire_success(&dir, &id);
    requests.lock().unwrap().clear();
    let refreshed = crate::commands::get_live_channels(&state).await.unwrap();
    assert_eq!(refreshed[0]["channels"][0]["name"], "Fixture 2");
    assert_eq!(
        refreshed[0]["channels"][0]["logo"],
        "http://live.invalid/cdn/logos/station-2.png"
    );
    let channel = refreshed[0]["channels"][0]["id"].as_str().unwrap();
    assert_eq!(
        crate::commands::get_live_stream(&state, &id, channel)
            .await
            .unwrap()[0]
            .url,
        "http://live.invalid/cdn/channel/streams/station-2.m3u8"
    );
    assert_eq!(
        requests.lock().unwrap().as_slice(),
        &[primary, backup, actual]
    );
    assert!(crate::commands_provider::set_enabled_persisted(&state, &id, false).unwrap());
    requests.lock().unwrap().clear();
    assert!(crate::commands::get_live_channels(&state)
        .await
        .unwrap()
        .is_empty());
    assert!(
        requests.lock().unwrap().is_empty(),
        "disabled live source must not refresh"
    );
    let reimported = import_live(&state, primary, "Proxy live refreshed", &[backup.into()])
        .await
        .unwrap();
    assert_eq!(reimported["id"], id);
    assert_disabled(&state, &id);
    assert_proxy(&state, &proxy);
    drop(state);

    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_disabled(&state, &id);
    assert_proxy(&state, &proxy);
    for manifest in state.registry.manifests() {
        if manifest.id != id {
            state.registry.set_enabled(&manifest.id, false);
        }
    }
    requests.lock().unwrap().clear();
    assert!(crate::commands::get_live_channels(&state)
        .await
        .unwrap()
        .is_empty());
    assert!(requests.lock().unwrap().is_empty());
    let origin = load(&dir)
        .origins
        .into_iter()
        .find(|o| o.provider_ids.contains(&id))
        .unwrap();
    assert_eq!(origin.primary_url, primary);
    assert_eq!(origin.backup_urls, [backup]);
    assert_eq!(origin.last_successful_endpoint.as_deref(), Some(backup));
    assert_eq!(origin.last_successful_url.as_deref(), Some(actual));
    assert!(crate::commands_provider::set_enabled_persisted(&state, &id, true).unwrap());
    let restarted = crate::commands::get_live_channels(&state).await.unwrap();
    assert_eq!(restarted[0]["channels"][0]["name"], "Fixture 2");
    assert_eq!(
        restarted[0]["channels"][0]["logo"],
        "http://live.invalid/cdn/logos/station-2.png"
    );
    let channel = restarted[0]["channels"][0]["id"].as_str().unwrap();
    assert_eq!(
        crate::commands::get_live_stream(&state, &id, channel)
            .await
            .unwrap()[0]
            .url,
        "http://live.invalid/cdn/channel/streams/station-2.m3u8"
    );
    assert_eq!(requests.lock().unwrap().as_slice(), &[backup, actual]);
    assert!(crate::commands_provider::set_enabled_persisted(&state, &id, false).unwrap());
    drop(state);
    server.abort();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn tvbox_fallback_resolves_supported_xbpq_ext_and_restarts_with_real_content() {
    use axum::response::Redirect;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let config = serde_json::json!({
        "分类": "Movies$1", "分类url": format!("{base}/items/{{cateId}}/{{catePg}}"),
        "数组": "<entry>&&</entry>", "标题": "<title>&&</title>", "链接": "<url>&&</url>"
    })
    .to_string();
    let ext_hits = Arc::new(AtomicUsize::new(0));
    let page_hits = Arc::new(AtomicUsize::new(0));
    let ext_seen = ext_hits.clone();
    let page_seen = page_hits.clone();
    let app = axum::Router::new()
        .route("/primary.json", get(|| async { StatusCode::SERVICE_UNAVAILABLE }))
        .route("/backup.json", get(|| async { Redirect::temporary("/actual/config.json") }))
        .route("/actual/config.json", get(|| async {
            r#"{"sites":[{"key":"xbpq-fixture","name":"XBPQ fixture","type":3,"api":"csp_XBPQ","ext":"./rules/xbpq.json"}]}"#
        }))
        .route("/actual/rules/xbpq.json", get(move || {
            let config = config.clone();
            let hits = ext_seen.clone();
            async move { hits.fetch_add(1, Ordering::SeqCst); config }
        }))
        .route("/items/1/1", get(move || {
            let hits = page_seen.clone();
            async move {
                hits.fetch_add(1, Ordering::SeqCst);
                "<entry><title>Local XBPQ content</title><url>fixture-item</url></entry>"
            }
        }));
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let dir = scratch("relative-xbpq-ext");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    let primary = format!("{base}/primary.json");
    let backup = format!("{base}/backup.json");
    let ext = format!("{base}/actual/rules/xbpq.json");
    let imported =
        crate::tvbox::import_tvbox_config_with_options(&state, &primary, &[backup.clone()], None)
            .await
            .unwrap();
    assert_eq!(imported["imported"].as_array().unwrap().len(), 1);
    assert!(imported["skipped"].as_array().unwrap().is_empty());
    assert_eq!(imported["imported"][0]["categories"], 1);
    assert!(imported["imported"][0]["probeFailed"].is_null());
    assert_eq!(ext_hits.load(Ordering::SeqCst), 1);
    assert_eq!(page_hits.load(Ordering::SeqCst), 1);
    let id = imported["imported"][0]["id"].as_str().unwrap().to_owned();
    assert!(crate::commands_provider::set_enabled_persisted(&state, &id, false).unwrap());
    drop(state);

    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_disabled(&state, &id);
    match crate::commands_provider::get_provider_config(&state, &id)
        .unwrap()
        .unwrap()
    {
        PersistedProvider::Tvbox {
            api, ext: saved, ..
        } => {
            assert_eq!(api, "csp_XBPQ");
            assert_eq!(saved.as_deref(), Some(ext.as_str()));
        }
        _ => panic!("XBPQ must retain its supported TVBox configuration"),
    }
    assert!(crate::commands_provider::set_enabled_persisted(&state, &id, true).unwrap());
    let content = state
        .registry
        .get(&id)
        .unwrap()
        .list(crate::provider::ListRequest {
            category_id: "1".into(),
            page: 1,
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(content.items.len(), 1);
    assert_eq!(content.items[0].title, "Local XBPQ content");
    assert_eq!(
        ext_hits.load(Ordering::SeqCst),
        2,
        "restored provider must load the persisted ext URL"
    );
    assert_eq!(page_hits.load(Ordering::SeqCst), 2);
    assert!(crate::commands_provider::set_enabled_persisted(&state, &id, false).unwrap());
    drop(state);
    server.abort();
    let _ = std::fs::remove_dir_all(dir);
}


// Test-only qualification: no product seam and no external HTTP authority.
// Both cases exercise the real install/update/remove/reload commands.
struct PluginUpdateDeleteObservation {
    update: Result<serde_json::Value, String>,
    deleted_before_release: bool,
    file_exists_after_update: bool,
    file_after_update: Option<String>,
    registry_version_after_update: Option<String>,
    file_exists_after_restart: bool,
    file_after_restart: Option<String>,
    registry_version_after_restart: Option<String>,
    meta_before_release: Option<Vec<u8>>,
    meta_after_update: Option<Vec<u8>>,
    catalog_before_release: Vec<u8>,
    catalog_after_update: Vec<u8>,
    source_requests: usize,
}

async fn observe_held_plugin_update(
    delete_while_held: bool,
    change_source_while_held: bool,
) -> Result<PluginUpdateDeleteObservation, String> {
    use std::sync::atomic::AtomicBool;
    use tokio::sync::{oneshot, Semaphore};
    use tokio::time::{timeout, Duration};

    // No platform credential backend may be installed in this isolated test process.
    let credential_builder = keyring::mock::default_credential_builder();
    assert!(matches!(
        credential_builder.persistence(),
        keyring::credential::CredentialPersistence::EntryOnly,
    ));
    keyring::set_default_credential_builder(credential_builder);

    if std::env::var("SOURIN_NO_REMOTE_AUTOSTART").ok().as_deref() != Some("1") {
        return Err("fixture requires SOURIN_NO_REMOTE_AUTOSTART=1 before process launch".to_string());
    }
    let entered = Arc::new(Semaphore::new(0));
    let release = Arc::new(Semaphore::new(0));
    let hold = Arc::new(AtomicBool::new(false));
    let hits = Arc::new(AtomicUsize::new(0));
    let v2_released = Arc::new(AtomicBool::new(false));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await.map_err(|e| format!("fixture bind: {e}"))?;
    let base = format!("http://{}", listener.local_addr().map_err(|e| e.to_string())?);
    let source = format!("{base}/plugin.js");
    let app = {
        let entered = entered.clone();
        let release = release.clone();
        let hold = hold.clone();
        let hits = hits.clone();
        let v2_released = v2_released.clone();
        axum::Router::new().fallback(get(move |uri: Uri| {
            let entered = entered.clone();
            let release = release.clone();
            let hold = hold.clone();
            let hits = hits.clone();
            let v2_released = v2_released.clone();
            async move {
                if uri.path() != "/plugin.js" {
                    return StatusCode::NOT_FOUND.into_response();
                }
                hits.fetch_add(1, Ordering::SeqCst);
                if hold.load(Ordering::SeqCst) {
                    entered.add_permits(1);
                    match timeout(Duration::from_secs(6), release.acquire()).await {
                        Ok(Ok(permit)) => permit.forget(),
                        _ => return StatusCode::GATEWAY_TIMEOUT.into_response(),
                    }
                    v2_released.store(true, Ordering::SeqCst);
                    plugin_script(2).into_response()
                } else {
                    plugin_script(1).into_response()
                }
            }
        }))
    };
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    let server = tokio::spawn(async move {
        axum::serve(listener, app).with_graceful_shutdown(async move {
            let _ = shutdown_rx.await;
        }).await
    });
    let fixture_root = scratch(if delete_while_held { "held-update-delete" } else { "held-update-control" });
    // bootstrap migration inspects sibling legacy names: own the parent too.
    let dir = fixture_root.join("data");
    // Keep this isolated directory for the owning runner's frozen evidence.
    // Every assertion is made only after the server's graceful join below.
    let observation = async {
        std::fs::create_dir_all(&dir).map_err(|e| format!("fixture data directory: {e}"))?;
        for (name, value) in [
            ("github-discovery.json", serde_json::json!({ "automatic": false })),
            ("tvbox-update-schedule.json", serde_json::json!({ "enabled": false, "intervalSecs": 86400 })),
            ("global-proxy.json", serde_json::json!({ "mode": "custom", "url": base.clone(), "scope": "all" })),
        ] {
            std::fs::write(dir.join(name), serde_json::to_vec(&value).map_err(|e| e.to_string())?)
                .map_err(|e| format!("fixture isolated configuration: {e}"))?;
        }
        let state = AppState::bootstrap(dir.clone()).await
            .map_err(|e| format!("fixture bootstrap: {e}"))?;
        let policy = state.proxy.get(crate::proxy::GLOBAL_PROXY);
        if policy.mode != crate::proxy::ProxyMode::Custom || policy.url.as_deref() != Some(base.as_str()) {
            return Err("fixture loopback proxy policy was not restored".to_string());
        }
        let installed = crate::commands_remote::install_plugin_with_backups(
            &state, &source, &if change_source_while_held { vec![format!("{base}/old-backup.js")] } else { vec![] },
        ).await.map_err(|e| format!("fixture install: {e}"))?;
        let file = installed["file"].as_str().ok_or("fixture install omitted file")?.to_owned();
        let path = crate::state::plugins_dir(&dir).join(&file);
        if installed["id"] != "lifecycle-js" || installed["version"] != "1.0.0"
            || std::fs::read_to_string(&path).ok().as_deref() != Some(plugin_script(1).as_str())
            || state.registry.get("lifecycle-js").is_none() {
            return Err("fixture v1 install business precondition failed".to_string());
        }
        let meta_path = crate::plugins::plugin_meta_dir(&crate::state::plugins_dir(&dir))
            .join("lifecycle-js.json");
        if std::fs::read(&meta_path).is_err() {
            return Err("fixture install omitted durable source meta".to_string());
        }
        hold.store(true, Ordering::SeqCst);
        let update_started = std::time::Instant::now();
        let update = crate::commands_provider::update_plugin_from_source(&state, "lifecycle-js");
        let while_held = async {
            let entered_result = timeout(Duration::from_secs(4), entered.acquire()).await;
            let entered_ok = match entered_result {
                Ok(Ok(permit)) => { permit.forget(); true }
                _ => false,
            };
            let result = if !entered_ok {
                Err("fixture update never entered held HTTP response".to_string())
            } else if delete_while_held {
                match crate::commands_provider::remove_plugin(&state, &file) {
                    Ok(()) if !path.exists() && state.registry.get("lifecycle-js").is_none() => Ok(true),
                    Ok(()) => Err("fixture delete returned success without removing file/registry".to_string()),
                    Err(error) => Err(format!("fixture delete failed before release: {error}")),
                }
            } else if change_source_while_held {
                let replacement = format!("{base}/replacement.js");
                let changed = (|| -> Result<(), String> {
                    // Saving the same primary preserves the existing mirror configuration.
                    crate::commands_provider::set_plugin_source(&state, "lifecycle-js", &source)?;
                    let same = load(&dir).origins.into_iter()
                        .find(|o| o.kind == "js" && o.provider_ids.iter().any(|id| id == "lifecycle-js"))
                        .ok_or("fixture missing same-primary origin")?;
                    if same.backup_urls != vec![format!("{base}/old-backup.js")] {
                        return Err("fixture same-primary save erased configured mirror".into());
                    }
                    crate::commands_provider::set_plugin_source(&state, "lifecycle-js", &replacement)?;
                    let changed = load(&dir).origins.into_iter()
                        .find(|o| o.kind == "js" && o.provider_ids.iter().any(|id| id == "lifecycle-js"))
                        .ok_or("fixture missing replacement origin")?;
                    if changed.primary_url != replacement || !changed.backup_urls.is_empty() {
                        return Err("fixture replacement retained a previous-source mirror".into());
                    }
                    Ok(())
                })();
                changed.map(|_| false)
            } else {
                let epoch = state.js_epoch_locked();
                match crate::commands_provider::remove_provider(&state, "missing-non-js-fixture") {
                    Ok(false) if state.js_epoch_locked() == epoch => Ok(false),
                    Ok(_) => Err("unrelated missing provider removal invalidated a JS update".into()),
                    Err(error) => Err(format!("unrelated provider removal failed: {error}")),
                }
            };
            // Snapshot the actual successful delete's state; do not prescribe
            // whether deletion should retain or remove metadata/catalog rows.
            let meta_before_release = std::fs::read(&meta_path).ok();
            let catalog_before_release = std::fs::read(dir.join("source-catalog.json"))
                .map_err(|e| format!("fixture catalog snapshot: {e}"));
            // Always release, including a failed precondition, so no handler stays held.
            release.add_permits(1);
            result.and_then(|deleted| Ok((deleted, meta_before_release, catalog_before_release?)))
        };
        // No timing sleeps or production instrumentation: the update is polled
        // concurrently with the real delete, which runs only after HTTP entry.
        let (update, deleted_before_release) = tokio::join!(update, while_held);
        let (deleted_before_release, meta_before_release, catalog_before_release) = deleted_before_release?;
        if !v2_released.load(Ordering::SeqCst) || update_started.elapsed() >= Duration::from_secs(7) {
            return Err("fixture response gate exceeded qualified budget; exclude from behavior RED".to_string());
        }
        let file_exists_after_update = path.exists();
        let file_after_update = std::fs::read_to_string(&path).ok();
        let registry_version_after_update = state.registry.get("lifecycle-js")
            .map(|p| p.manifest().version.clone());
        let meta_after_update = std::fs::read(&meta_path).ok();
        let catalog_after_update = std::fs::read(dir.join("source-catalog.json"))
            .map_err(|e| format!("fixture catalog readback: {e}"))?;
        drop(state);
        let restarted = AppState::bootstrap(dir.clone()).await
            .map_err(|e| format!("fixture restart: {e}"))?;
        let file_exists_after_restart = path.exists();
        let file_after_restart = std::fs::read_to_string(&path).ok();
        let registry_version_after_restart = restarted.registry.get("lifecycle-js")
            .map(|p| p.manifest().version.clone());
        drop(restarted);
        Ok(PluginUpdateDeleteObservation {
            update, deleted_before_release, file_exists_after_update, file_after_update,
            registry_version_after_update, file_exists_after_restart, file_after_restart,
            registry_version_after_restart, meta_before_release,
            meta_after_update, catalog_before_release, catalog_after_update,
            source_requests: hits.load(Ordering::SeqCst),
        })
    }.await;
    hold.store(false, Ordering::SeqCst);
    release.add_permits(1);
    let _ = shutdown_tx.send(());
    match timeout(Duration::from_secs(10), server).await {
        Ok(Ok(Ok(()))) => observation,
        Ok(Ok(Err(error))) => Err(format!("fixture HTTP server failed: {error}")),
        Ok(Err(error)) => Err(format!("fixture HTTP server task failed: {error}")),
        Err(_) => Err("fixture HTTP server did not gracefully join".to_string()),
    }
}

#[tokio::test]
async fn js_held_update_delete_does_not_resurrect_plugin() {
    let observed = observe_held_plugin_update(true, false).await
        .expect("fixture must finish and gracefully join before business assertions");
    assert!(observed.deleted_before_release, "real remove_plugin must finish before releasing v2");
    assert_eq!(observed.source_requests, 2, "one v1 install and one held v2 update only");
    assert!(!observed.file_exists_after_update,
        "obsolete update recreated the plugin file after remove_plugin completed");
    assert!(observed.registry_version_after_update.is_none(),
        "obsolete update registered the deleted plugin");
    assert!(!observed.file_exists_after_restart, "deleted plugin file must remain absent on restart");
    assert!(observed.registry_version_after_restart.is_none(), "deleted plugin must remain absent on restart");
    assert_eq!(observed.meta_after_update, observed.meta_before_release,
        "obsolete update replaced durable metadata after deletion");
    assert_eq!(observed.catalog_after_update, observed.catalog_before_release,
        "obsolete update changed the source catalog after deletion");
    assert!(observed.update.is_err(), "obsolete update must not report a successful committed update");
}

#[tokio::test]
async fn js_held_update_without_delete_commits_new_version() {
    let observed = observe_held_plugin_update(false, false).await
        .expect("fixture must finish and gracefully join before business assertions");
    assert!(!observed.deleted_before_release);
    assert_eq!(observed.source_requests, 2, "one v1 install and one held v2 update only");
    let updated = observed.update.expect("current update must succeed");
    assert_eq!(updated["updated"], true);
    assert_eq!(updated["version"], "2.0.0");
    assert_eq!(observed.file_after_update.as_deref(), Some(plugin_script(2).as_str()));
    assert_eq!(observed.registry_version_after_update.as_deref(), Some("2.0.0"));
    assert_eq!(observed.file_after_restart.as_deref(), Some(plugin_script(2).as_str()));
    assert_eq!(observed.registry_version_after_restart.as_deref(), Some("2.0.0"));
    let meta: crate::plugins::PluginSourceMeta = serde_json::from_slice(
        observed.meta_after_update.as_deref().expect("updated source meta must exist")
    ).expect("updated source meta must decode");
    assert_eq!(meta.installed_version, "2.0.0");
}

#[tokio::test]
async fn js_held_update_cannot_restore_replaced_source_or_old_mirrors() {
    let observed = observe_held_plugin_update(false, true).await
        .expect("source replacement fixture must finish and gracefully join");
    assert_eq!(observed.source_requests, 2);
    let error = observed.update.expect_err("old update must lose its source ownership");
    assert!(error.contains("过期"), "unexpected update error: {error}");
    assert_eq!(observed.file_after_update.as_deref(), Some(plugin_script(1).as_str()));
    assert_eq!(observed.registry_version_after_update.as_deref(), Some("1.0.0"));
    assert_eq!(observed.file_after_restart.as_deref(), Some(plugin_script(1).as_str()));
    assert_eq!(observed.registry_version_after_restart.as_deref(), Some("1.0.0"));
    assert_eq!(observed.meta_after_update, observed.meta_before_release,
        "obsolete response overwrote the replacement source metadata");
    assert_eq!(observed.catalog_after_update, observed.catalog_before_release,
        "obsolete response attributed success to the replacement origin");
}


// Only hydration's real canAutoLogin HTTP response is held: no reload seam.
struct PluginReloadHydrateObservation {
    reload: Result<usize, String>,
    deleted_before_release: bool,
    file_exists_after_reload: bool,
    capabilities_after_reload: Option<(bool, bool, bool)>,
    subsequent_reload: Option<Result<usize, String>>,
    file_exists_after_subsequent_reload: bool,
    registered_after_subsequent_reload: bool,
    requests: usize,
}

async fn observe_held_plugin_reload_hydrate(
    delete_while_held: bool,
) -> Result<PluginReloadHydrateObservation, String> {
    use std::sync::atomic::AtomicBool;
    use tokio::sync::{oneshot, Semaphore};
    use tokio::time::{timeout, Duration};

    let credential_builder = keyring::mock::default_credential_builder();
    if !matches!(
        credential_builder.persistence(),
        keyring::credential::CredentialPersistence::EntryOnly,
    ) {
        return Err("fixture requires EntryOnly mock credentials".into());
    }
    keyring::set_default_credential_builder(credential_builder);
    if std::env::var("SOURIN_NO_REMOTE_AUTOSTART").ok().as_deref() != Some("1") {
        return Err("fixture requires SOURIN_NO_REMOTE_AUTOSTART=1 before process launch".into());
    }

    // Own bootstrap's parent as well: no sibling legacy data can migrate here.
    let fixture_root = scratch(if delete_while_held {
        "held-reload-hydrate-delete"
    } else {
        "held-reload-hydrate-control"
    });
    let dir = fixture_root.join("data");

    let entered = Arc::new(Semaphore::new(0));
    let release = Arc::new(Semaphore::new(0));
    let requests = Arc::new(AtomicUsize::new(0));
    let response_released = Arc::new(AtomicBool::new(false));
    let handler_failed = Arc::new(AtomicBool::new(false));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await.map_err(|e| format!("fixture bind: {e}"))?;
    let base = format!("http://{}", listener.local_addr().map_err(|e| e.to_string())?);
    let app = {
        let entered = entered.clone();
        let release = release.clone();
        let requests = requests.clone();
        let response_released = response_released.clone();
        let handler_failed = handler_failed.clone();
        axum::Router::new().fallback(get(move |uri: Uri| {
            let entered = entered.clone();
            let release = release.clone();
            let requests = requests.clone();
            let response_released = response_released.clone();
            let handler_failed = handler_failed.clone();
            async move {
                let previous = requests.fetch_add(1, Ordering::SeqCst);
                if uri.path() != "/hydrate-ready" || uri.query().is_some() || previous != 0 {
                    handler_failed.store(true, Ordering::SeqCst);
                    return StatusCode::BAD_REQUEST.into_response();
                }
                entered.add_permits(1);
                match timeout(Duration::from_secs(6), release.acquire()).await {
                    Ok(Ok(permit)) => permit.forget(),
                    _ => {
                        handler_failed.store(true, Ordering::SeqCst);
                        return StatusCode::GATEWAY_TIMEOUT.into_response();
                    }
                }
                response_released.store(true, Ordering::SeqCst);
                "ready".into_response()
            }
        }))
    };
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    let mut server = tokio::spawn(async move {
        axum::serve(listener, app).with_graceful_shutdown(async move {
            let _ = shutdown_rx.await;
        }).await
    });
    // Retain this isolated directory for the owning runner's evidence.
    let observation = async {
        std::fs::create_dir_all(&dir).map_err(|e| format!("fixture data directory: {e}"))?;
        for (name, value) in [
            ("github-discovery.json", serde_json::json!({ "automatic": false })),
            ("tvbox-update-schedule.json", serde_json::json!({ "enabled": false, "intervalSecs": 86400 })),
            ("global-proxy.json", serde_json::json!({ "mode": "custom", "url": base.clone(), "scope": "all" })),
        ] {
            std::fs::write(dir.join(name), serde_json::to_vec(&value).map_err(|e| e.to_string())?)
                .map_err(|e| format!("fixture isolated configuration: {e}"))?;
        }
        let state = timeout(Duration::from_secs(15), AppState::bootstrap(dir.clone())).await
            .map_err(|_| "fixture bootstrap timed out; not behavior RED".to_string())?
            .map_err(|e| format!("fixture bootstrap: {e}"))?;
        let policy = state.proxy.get(crate::proxy::GLOBAL_PROXY);
        if policy.mode != crate::proxy::ProxyMode::Custom || policy.url.as_deref() != Some(base.as_str()) {
            return Err("fixture loopback proxy policy was not restored".into());
        }
        // Normal bootstrap's unrelated demo is retained; the target is not seeded.
        if state.registry.get("held-hydrate").is_some() || requests.load(Ordering::SeqCst) != 0 {
            return Err("fixture target or HTTP request existed before writing synthetic JS".into());
        }
        let file = "held-hydrate.js";
        let path = crate::state::plugins_dir(&dir).join(file);
        let url = serde_json::to_string(&format!("{base}/hydrate-ready"))
            .map_err(|e| format!("fixture URL: {e}"))?;
        let script = format!(r#"/**
 * @id held-hydrate
 * @name Held hydrate
 * @version 1.0.0
 */
 globalThis.plugin = {{
   capabilities: {{ vod: true, loginRequired: true }},
   async canAutoLogin() {{
     const r = await host.http.get({url});
     return r === 'ready';
   }}
 }};"#);
        std::fs::write(&path, script).map_err(|e| format!("fixture synthetic JS: {e}"))?;

        let reload = timeout(Duration::from_secs(8), crate::commands_provider::reload_plugins(&state));
        let while_held = async {
            let entered_ok = match timeout(Duration::from_secs(4), entered.acquire()).await {
                Ok(Ok(permit)) => { permit.forget(); true }
                _ => false,
            };
            let result = if !entered_ok {
                Err("fixture hydrate never entered held HTTP response; not behavior RED".to_string())
            } else if delete_while_held {
                match crate::commands_provider::remove_plugin(&state, file) {
                    Ok(()) if !path.exists() && state.registry.get("held-hydrate").is_none() => Ok(true),
                    Ok(()) => Err("fixture delete did not remove target before release".into()),
                    Err(error) => Err(format!("fixture remove_plugin failed before release: {error}")),
                }
            } else if !path.is_file() || state.registry.get("held-hydrate").is_some() {
                Err("fixture control target must remain on disk and unpublished during hydrate".into())
            } else {
                Ok(false)
            };
            // Release even when entry/deletion qualification fails.
            release.add_permits(1);
            result
        };
        let (reload, deleted_before_release) = tokio::join!(reload, while_held);
        let deleted_before_release = deleted_before_release?;
        let reload = reload.map_err(|_| "fixture reload timed out; not behavior RED".to_string())?;
        let file_exists_after_reload = path.exists();
        let capabilities_after_reload = state.registry.get("held-hydrate").map(|p| {
            let caps = &p.manifest().capabilities;
            (caps.vod, caps.login_required, caps.can_auto_login)
        });
        let subsequent_reload = if delete_while_held {
            Some(timeout(Duration::from_secs(8), crate::commands_provider::reload_plugins(&state)).await
                .map_err(|_| "fixture subsequent reload timed out; not behavior RED".to_string())?)
        } else {
            None
        };
        let observed = PluginReloadHydrateObservation {
            reload, deleted_before_release, file_exists_after_reload, capabilities_after_reload,
            subsequent_reload,
            file_exists_after_subsequent_reload: path.exists(),
            registered_after_subsequent_reload: state.registry.get("held-hydrate").is_some(),
            requests: requests.load(Ordering::SeqCst),
        };
        drop(state);
        Ok(observed)
    }.await;

    // No business assertion runs until all real HTTP work has gracefully joined.
    release.add_permits(1);
    let _ = shutdown_tx.send(());
    match timeout(Duration::from_secs(10), &mut server).await {
        Ok(Ok(Ok(()))) => {}
        Ok(Ok(Err(error))) => return Err(format!("fixture HTTP server failed: {error}")),
        Ok(Err(error)) => return Err(format!("fixture HTTP server task failed: {error}")),
        Err(_) => {
            server.abort();
            let _ = timeout(Duration::from_secs(2), &mut server).await;
            return Err("fixture HTTP server did not gracefully join; not behavior RED".into());
        }
    }
    if handler_failed.load(Ordering::SeqCst) || !response_released.load(Ordering::SeqCst)
        || requests.load(Ordering::SeqCst) != 1 {
        return Err("fixture requires exactly one legal, released hydrate HTTP request; not behavior RED".into());
    }
    observation
}

#[tokio::test]
async fn js_held_reload_hydrate_delete_does_not_resurrect_plugin() {
    let observed = observe_held_plugin_reload_hydrate(true).await
        .expect("fixture must qualify and gracefully join; fixture failures are not behavior RED");
    assert!(observed.deleted_before_release, "real remove_plugin must remove the file before HTTP release");
    assert_eq!(observed.requests, 1, "only hydrate may issue the single loopback request");
    let error = observed.reload.expect_err("reload hydrated before deletion must expire");
    assert!(error.contains("过期"), "unexpected reload error: {error}");
    assert!(!observed.file_exists_after_reload, "expired reload must not recreate the deleted file");
    assert!(observed.capabilities_after_reload.is_none(), "expired hydrate must not publish the deleted id");
    observed.subsequent_reload.expect("delete case must perform another real reload")
        .expect("subsequent reload must succeed");
    assert!(!observed.file_exists_after_subsequent_reload, "subsequent scan must not recreate the target file");
    assert!(!observed.registered_after_subsequent_reload, "subsequent reload must not resurrect the target id");
}

#[tokio::test]
async fn js_held_reload_hydrate_without_delete_registers_plugin() {
    let observed = observe_held_plugin_reload_hydrate(false).await
        .expect("fixture must qualify and gracefully join; fixture failures are not behavior RED");
    assert!(!observed.deleted_before_release);
    assert_eq!(observed.requests, 1, "only hydrate may issue the single loopback request");
    assert!(observed.reload.expect("current hydrated reload must succeed") >= 1);
    assert!(observed.file_exists_after_reload);
    assert_eq!(observed.capabilities_after_reload, Some((true, true, true)),
        "real hydrate must await ready and publish vod/loginRequired/probed can_auto_login");
    assert!(observed.registered_after_subsequent_reload);
    assert!(observed.subsequent_reload.is_none(), "control requires only the held reload");
}

#[tokio::test]
async fn js_local_edit_rollback_and_source_clear_retain_ownership_and_user_data() {
    let credential_builder = keyring::mock::default_credential_builder();
    assert!(matches!(credential_builder.persistence(), keyring::credential::CredentialPersistence::EntryOnly));
    keyring::set_default_credential_builder(credential_builder);
    assert_eq!(std::env::var("SOURIN_NO_REMOTE_AUTOSTART").ok().as_deref(), Some("1"));
    let parent = scratch("js-local-edit-rollback");
    let dir = parent.join("data");
    std::fs::create_dir_all(&dir).unwrap();
    for (name, value) in [
        ("github-discovery.json", serde_json::json!({ "automatic": false })),
        ("tvbox-update-schedule.json", serde_json::json!({ "enabled": false, "intervalSecs": 86400 })),
        ("global-proxy.json", serde_json::json!({ "mode": "custom", "url": "http://127.0.0.1:9", "scope": "all" })),
    ] {
        std::fs::write(dir.join(name), serde_json::to_vec(&value).unwrap()).unwrap();
    }
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    let installed = crate::commands_remote::install_plugin_source(&state, &plugin_script(1), None).await.unwrap();
    let file = installed["file"].as_str().unwrap();
    let plugins = crate::state::plugins_dir(&dir);
    let config = plugins.join(".data").join("lifecycle-js").join("user.json");
    std::fs::create_dir_all(config.parent().unwrap()).unwrap();
    std::fs::write(&config, br#"{"preserved":"synthetic"}"#).unwrap();
    let original_config = std::fs::read(&config).unwrap();
    crate::plugins::archive_plugin_version(&plugins, "lifecycle-js", "1.0.0", &plugin_script(1)).unwrap();

    crate::commands_provider::save_plugin_source(&state, file, &plugin_script(2)).await.unwrap();
    assert_eq!(state.registry.get("lifecycle-js").unwrap().manifest().version, "2.0.0");
    let before_rejected_edit = std::fs::read(plugins.join(file)).unwrap();
    let changed_id = plugin_script(2).replace("lifecycle-js", "different-plugin-id");
    let error = crate::commands_provider::save_plugin_source(&state, file, &changed_id).await.unwrap_err();
    assert!(error.contains("@id"));
    assert_eq!(std::fs::read(plugins.join(file)).unwrap(), before_rejected_edit);
    assert!(state.registry.get("different-plugin-id").is_none());

    let rolled_back = crate::commands_provider::rollback_plugin(&state, "lifecycle-js", "1.0.0").await.unwrap();
    assert_eq!(rolled_back["version"], "1.0.0");
    assert_eq!(std::fs::read_to_string(plugins.join(file)).unwrap(), plugin_script(1));
    assert_eq!(state.registry.get("lifecycle-js").unwrap().manifest().version, "1.0.0");
    assert_eq!(std::fs::read(&config).unwrap(), original_config);

    crate::commands_provider::set_plugin_source(&state, "lifecycle-js", "http://127.0.0.1:9/primary.js").unwrap();
    let origin = load(&dir).origins.into_iter().find(|o| o.kind == "js" && o.provider_ids.iter().any(|id| id == "lifecycle-js")).unwrap();
    command_set_origin(&state, &serde_json::json!({"id":origin.id,"primaryUrl":"http://127.0.0.1:9/primary.js","backupUrls":["http://127.0.0.1:9/mirror.js"]})).unwrap();
    let configured = load(&dir).origins.into_iter().find(|o| o.kind == "js" && o.provider_ids.iter().any(|id| id == "lifecycle-js")).unwrap();
    assert_eq!(configured.backup_urls, vec!["http://127.0.0.1:9/mirror.js"]);
    crate::commands_provider::set_plugin_source(&state, "lifecycle-js", "").unwrap();
    let cleared = load(&dir).origins.into_iter().find(|o| o.kind == "js" && o.provider_ids.iter().any(|id| id == "lifecycle-js")).unwrap();
    assert!(cleared.primary_url.is_empty() && cleared.backup_urls.is_empty());
    assert!(cleared.last_successful_url.is_none() && cleared.last_successful_endpoint.is_none());
    assert!(crate::plugins::read_plugin_meta(&plugins, "lifecycle-js").unwrap().source_url.is_none());
    assert_eq!(crate::commands_provider::check_plugin_update(&state, "lifecycle-js").await.unwrap().needs_source, true);

    // The missing-file UI fallback still revokes a currently registered JS owner.
    std::fs::remove_file(plugins.join(file)).unwrap();
    let epoch = state.js_epoch_locked();
    assert!(crate::commands_provider::remove_provider(&state, "lifecycle-js").unwrap());
    assert!(state.js_epoch_locked() > epoch);
    assert!(state.registry.get("lifecycle-js").is_none());
    assert_eq!(std::fs::read(&config).unwrap(), original_config);
}
