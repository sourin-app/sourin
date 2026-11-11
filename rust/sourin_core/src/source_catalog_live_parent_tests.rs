use super::*;
use axum::{http::{StatusCode, Uri}, response::{IntoResponse}, routing::get};

fn scratch(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("sourin-live-parent-{tag}-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

async fn fixture() -> (String, Arc<Mutex<Vec<String>>>, Arc<Mutex<String>>, tokio::task::JoinHandle<()>) {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let observed = requests.clone();
    let a_live = Arc::new(Mutex::new("./a.m3u".to_string()));
    let current_live = a_live.clone();
    let app = axum::Router::new().fallback(get(move |uri: Uri| {
        let seen = observed.clone();
        let a_live = current_live.clone();
        async move {
            seen.lock().unwrap().push(uri.to_string());
            match uri.path() {
                "/a.json" => serde_json::json!({"sites":[{"key":"vod-a","name":"VOD A","type":1,"api":"http://catalog.invalid/cms"}],"lives":[{"name":"Live A","url":a_live.lock().unwrap().clone()}]}).to_string().into_response(),
                "/b.json" => serde_json::json!({"sites":[],"lives":[{"name":"Live B","url":"./b.m3u"}]}).to_string().into_response(),
                "/shared.json" => serde_json::json!({"sites":[],"lives":[{"name":"Shared A","url":"./a.m3u"}]}).to_string().into_response(),
                "/cms" => r#"{"class":[{"type_id":"1","type_name":"Movies"}],"list":[{"vod_id":"fixture-video","vod_name":"Fixture movie"}],"total":1}"#.into_response(),
                "/a.m3u" | "/b.m3u" => format!("#EXTM3U\n#EXTINF:-1 group-title=\"News\",{}\n./streams/channel.m3u8\n", uri.path()).into_response(),
                "/a-down.m3u" => StatusCode::SERVICE_UNAVAILABLE.into_response(),
                "/a-backup.m3u" => "#EXTM3U\n#EXTINF:-1,Backup A\n./backup/channel.m3u8\n".into_response(),
                _ => StatusCode::NOT_FOUND.into_response(),
            }
        }
    }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (base, requests, a_live, server)
}

fn use_proxy(state: &AppState, url: &str) {
    state.proxy.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig { mode: crate::proxy::ProxyMode::Custom, url: Some(url.into()), ..Default::default() }).unwrap();
}

async fn import(state: &AppState, path: &str, name: &str) -> serde_json::Value {
    crate::tvbox::import_tvbox_config_with_options(state, &format!("http://catalog.invalid/{path}"), &[], Some(name)).await.unwrap()
}

fn origin(state: &AppState, id: &str) -> serde_json::Value {
    command_get(state).unwrap()["origins"].as_array().unwrap().iter().find(|o| o["id"] == id).unwrap().clone()
}

#[tokio::test]
async fn tvbox_live_parent_import_and_restart_keep_playlist_ownership() {
    let (proxy, _, _, server) = fixture().await;
    let dir = scratch("mixed-and-live-only");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let a = import(&state, "a.json", "Subscription A").await;
    let b = import(&state, "b.json", "Subscription B").await;
    assert_eq!(a["imported"].as_array().unwrap().len(), 1);
    assert!(b["imported"].as_array().unwrap().is_empty());
    let a_id = a["liveImported"][0]["id"].as_str().unwrap();
    let b_id = b["liveImported"][0]["id"].as_str().unwrap();
    let a_parent = a["originId"].as_str().unwrap();
    let b_parent = b["originId"].as_str().unwrap();
    let cat = catalog(&state).unwrap();
    let live = cat.origins.iter().find(|o| o.kind == "live" && o.provider_ids.contains(&a_id.into())).unwrap();
    assert_eq!(live.primary_url, "http://catalog.invalid/a.m3u");
    assert_eq!(origin(&state, a_parent)["providerIds"], serde_json::json!([a["imported"][0]["id"]]));
    assert_eq!(origin(&state, a_parent)["relatedProviderIds"], serde_json::json!([a_id]), "mixed TVBox parent must include its live child separately");
    assert_eq!(origin(&state, b_parent)["relatedProviderIds"], serde_json::json!([b_id]), "live-only TVBox parent must include its live child");
    let live_id = live.id.clone();
    command_set_origin(&state, &serde_json::json!({"id":a_parent,"name":"Renamed A","primaryUrl":"http://catalog.invalid/a-new.json","backupUrls":["http://catalog.invalid/a.json"]})).unwrap();
    assert_eq!(origin(&state, &live_id)["primaryUrl"], "http://catalog.invalid/a.m3u");
    drop(state);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_eq!(origin(&state, a_parent)["relatedProviderIds"], serde_json::json!([a_id]));
    assert_eq!(origin(&state, a_parent)["name"], "Renamed A");
    assert_eq!(origin(&state, b_parent)["relatedProviderIds"], serde_json::json!([b_id]));
    drop(state); server.abort(); let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn tvbox_live_parent_address_fallback_never_fetches_parent_as_playlist() {
    let (proxy, requests, _, server) = fixture().await;
    let dir = scratch("fallback");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let a = import(&state, "a.json", "Subscription A").await;
    let b = import(&state, "b.json", "Subscription B").await;
    let a_id = a["liveImported"][0]["id"].as_str().unwrap();
    let b_id = b["liveImported"][0]["id"].as_str().unwrap();
    let live_origin = catalog(&state).unwrap().origins.into_iter().find(|o| o.kind == "live" && o.provider_ids.contains(&a_id.into())).unwrap();
    command_set_origin(&state, &serde_json::json!({"id":live_origin.id,"primaryUrl":"http://catalog.invalid/a-down.m3u","backupUrls":["http://catalog.invalid/a-backup.m3u"]})).unwrap();
    requests.lock().unwrap().clear();
    let channels = state.registry.get(a_id).unwrap().live_channels().await.unwrap();
    assert_eq!(channels.len(), 1);
    assert_eq!(channels[0].name, "Backup A");
    let streams = crate::commands::get_live_stream(&state, a_id, &channels[0].id).await.unwrap();
    assert_eq!(streams[0].url, "http://catalog.invalid/backup/channel.m3u8");
    assert_eq!(requests.lock().unwrap().as_slice(), &["http://catalog.invalid/a-down.m3u", "http://catalog.invalid/a-backup.m3u"]);
    let b_live = catalog(&state).unwrap().origins.into_iter().find(|o| o.kind == "live" && o.provider_ids.contains(&b_id.into())).unwrap();
    assert_eq!(b_live.primary_url, "http://catalog.invalid/b.m3u");
    assert!(b_live.backup_urls.is_empty());
    assert_eq!(origin(&state, a["originId"].as_str().unwrap())["relatedProviderIds"], serde_json::json!([a_id]));
    drop(state);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    requests.lock().unwrap().clear();
    let channels = state.registry.get(a_id).unwrap().live_channels().await.unwrap();
    assert_eq!(channels[0].name, "Backup A");
    assert_eq!(requests.lock().unwrap().as_slice(), &["http://catalog.invalid/a-backup.m3u"]);
    drop(state); server.abort(); let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn tvbox_live_parent_refresh_updates_membership_without_stealing_shared_live() {
    let (proxy, _, a_live, server) = fixture().await;
    let dir = scratch("shared-refresh");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let a = import(&state, "a.json", "Subscription A").await;
    let shared = import(&state, "shared.json", "Subscription Shared").await;
    let live = a["liveImported"][0]["id"].as_str().unwrap();
    assert_eq!(shared["liveImported"][0]["id"], live);
    assert_eq!(origin(&state, shared["originId"].as_str().unwrap())["relatedProviderIds"], serde_json::json!([live]));
    *a_live.lock().unwrap() = "./b.m3u".into();
    let refreshed = import(&state, "a.json", "Subscription A").await;
    let new_live = refreshed["liveImported"][0]["id"].as_str().unwrap();
    assert_ne!(new_live, live);
    assert_eq!(origin(&state, a["originId"].as_str().unwrap())["relatedProviderIds"], serde_json::json!([new_live]));
    assert_eq!(origin(&state, shared["originId"].as_str().unwrap())["relatedProviderIds"], serde_json::json!([live]));
    drop(state);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_eq!(origin(&state, a["originId"].as_str().unwrap())["relatedProviderIds"], serde_json::json!([new_live]));
    assert_eq!(origin(&state, shared["originId"].as_str().unwrap())["relatedProviderIds"], serde_json::json!([live]));
    drop(state); server.abort(); let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn tvbox_live_parent_live_only_reimport_preserves_disabled_selection() {
    let (proxy, _, _, server) = fixture().await;
    let dir = scratch("disabled-live-only");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let b = import(&state, "b.json", "Subscription B").await;
    let live = b["liveImported"][0]["id"].as_str().unwrap();
    assert!(crate::commands_provider::set_enabled_persisted(&state, live, false).unwrap());
    assert!(!state.registry.enabled_manifests().iter().any(|m| m.id == live));
    import(&state, "b.json", "Subscription B").await;
    assert!(!state.registry.enabled_manifests().iter().any(|m| m.id == live), "live-only reimport must not revive a source the user disabled");
    assert_eq!(origin(&state, b["originId"].as_str().unwrap())["relatedProviderIds"], serde_json::json!([live]));
    assert!(crate::commands::load_disabled(&dir).iter().any(|id| id == live));
    drop(state);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert!(!state.registry.enabled_manifests().iter().any(|m| m.id == live));
    assert_eq!(origin(&state, b["originId"].as_str().unwrap())["relatedProviderIds"], serde_json::json!([live]));
    drop(state); server.abort(); let _ = std::fs::remove_dir_all(dir);
}
