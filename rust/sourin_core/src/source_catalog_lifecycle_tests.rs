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
