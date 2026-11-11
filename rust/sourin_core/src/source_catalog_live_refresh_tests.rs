use super::*;
use axum::{
    http::{StatusCode, Uri},
    response::IntoResponse,
    routing::get,
};

fn scratch(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "sourin-live-parent-{tag}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

async fn fixture() -> (
    String,
    Arc<Mutex<Vec<String>>>,
    Arc<Mutex<String>>,
    tokio::task::JoinHandle<()>,
) {
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
                "/a.json" => {
                    let live = a_live.lock().unwrap().clone();
                    let lives = if live == "__no_live__" { Vec::new() }
                        else { vec![serde_json::json!({"name":"Live A","url":live})] };
                    serde_json::json!({"sites":[{"key":"vod-a","name":"VOD A","type":1,"api":"http://catalog.invalid/cms"}],"lives":lives}).to_string().into_response()
                },
                "/b.json" => serde_json::json!({"sites":[],"lives":[{"name":"Live B","url":"./b.m3u"}]}).to_string().into_response(),
                "/shared.json" => serde_json::json!({"sites":[],"lives":[{"name":"Shared A","url":"./a.m3u"}]}).to_string().into_response(),
                "/cms" => r#"{"class":[{"type_id":"1","type_name":"Movies"}],"list":[{"vod_id":"fixture-video","vod_name":"Fixture movie"}],"total":1}"#.into_response(),
                "/a.m3u" | "/b.m3u" | "/standalone.m3u" => format!("#EXTM3U\n#EXTINF:-1 group-title=\"News\",{}\n./streams/channel.m3u8\n", uri.path()).into_response(),
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

async fn import(state: &AppState, path: &str, name: &str) -> serde_json::Value {
    crate::tvbox::import_tvbox_config_with_options(
        state,
        &format!("http://catalog.invalid/{path}"),
        &[],
        Some(name),
    )
    .await
    .unwrap()
}

fn origin(state: &AppState, id: &str) -> serde_json::Value {
    command_get(state).unwrap()["origins"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["id"] == id)
        .unwrap()
        .clone()
}

fn live_id_for(url: &str) -> String {
    let provider = crate::providers::m3u_live::M3uLiveProvider::new("Fixture", url);
    crate::provider::MediaProvider::manifest(&provider)
        .id
        .clone()
}

fn persisted_live_ids(state: &AppState) -> HashSet<String> {
    crate::persist::load_persisted(&state.data_dir)
        .into_iter()
        .filter_map(|row| match row {
            PersistedProvider::M3uLive { id, .. } => Some(id),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn tvbox_live_actual_update_with_unchanged_vod_registers_persists_and_restores() {
    let (proxy, requests, a_live, server) = fixture().await;
    let dir = scratch("actual-update");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let a = import(&state, "a.json", "Subscription A").await;
    let shared = import(&state, "shared.json", "Subscription Shared").await;
    let vod = a["imported"][0]["id"].as_str().unwrap().to_owned();
    let old_live = a["liveImported"][0]["id"].as_str().unwrap().to_owned();
    let parent = a["originId"].as_str().unwrap().to_owned();
    let shared_parent = shared["originId"].as_str().unwrap().to_owned();
    let old_owner = catalog(&state)
        .unwrap()
        .origins
        .into_iter()
        .find(|o| o.kind == "live" && o.provider_ids.contains(&old_live))
        .unwrap();
    command_set_origin(&state, &serde_json::json!({"id":old_owner.id,"primaryUrl":"http://catalog.invalid/a-down.m3u","backupUrls":["http://catalog.invalid/a-backup.m3u"]})).unwrap();
    state
        .registry
        .get(&old_live)
        .unwrap()
        .live_channels()
        .await
        .unwrap();
    crate::commands_provider::set_enabled_persisted(&state, &old_live, false).unwrap();
    let saved_owner = origin(&state, &old_owner.id);
    *a_live.lock().unwrap() = "./b.m3u".into();
    let new_live = live_id_for("http://catalog.invalid/b.m3u");
    let before_related = origin(&state, &parent)["relatedProviderIds"].clone();
    let before_registered: HashSet<String> = state
        .registry
        .manifests()
        .into_iter()
        .map(|m| m.id)
        .collect();
    let before_persisted = persisted_live_ids(&state);
    let check = crate::tvbox::check_tvbox_updates(&state, Some(&vod))
        .await
        .unwrap();
    assert_eq!(
        origin(&state, &parent)["relatedProviderIds"],
        before_related,
        "check preview must not change parent attribution"
    );
    assert_eq!(
        state
            .registry
            .manifests()
            .into_iter()
            .map(|m| m.id)
            .collect::<HashSet<_>>(),
        before_registered,
        "check preview must not register providers"
    );
    assert_eq!(
        persisted_live_ids(&state),
        before_persisted,
        "check preview must not persist providers"
    );
    assert!(state.registry.get(&new_live).is_none());
    assert_eq!(origin(&state, &old_owner.id), saved_owner);
    let updated = crate::tvbox::update_tvbox_source(&state, &vod, true, false)
        .await
        .unwrap();
    assert_eq!(updated["updated"], true);
    assert_eq!(check["items"][0]["added"], serde_json::json!([]));
    assert_eq!(check["items"][0]["changed"], serde_json::json!([]));
    assert_eq!(check["items"][0]["liveHasChanges"], true);
    assert_eq!(check["items"][0]["liveAdded"][0]["id"], new_live);
    assert_eq!(updated["liveAdded"][0]["id"], new_live);
    assert_eq!(updated["liveRemoved"][0]["id"], old_live);
    assert_eq!(updated["liveDeleted"], serde_json::json!([]));
    assert!(state.registry.get(&new_live).is_some());
    assert!(persisted_live_ids(&state).contains(&new_live));
    assert!(persisted_live_ids(&state).contains(&old_live));
    assert_eq!(
        origin(&state, &parent)["relatedProviderIds"],
        serde_json::json!([new_live])
    );
    assert_eq!(
        origin(&state, &shared_parent)["relatedProviderIds"],
        serde_json::json!([old_live])
    );
    assert_eq!(origin(&state, &old_owner.id), saved_owner);
    assert!(!state
        .registry
        .enabled_manifests()
        .iter()
        .any(|m| m.id == old_live));
    requests.lock().unwrap().clear();
    state
        .registry
        .get(&new_live)
        .unwrap()
        .live_channels()
        .await
        .unwrap();
    assert_eq!(
        requests.lock().unwrap().as_slice(),
        &["http://catalog.invalid/b.m3u"]
    );
    drop(state);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert!(state.registry.get(&new_live).is_some());
    assert_eq!(
        origin(&state, &parent)["relatedProviderIds"],
        serde_json::json!([new_live])
    );
    assert_eq!(
        origin(&state, &shared_parent)["relatedProviderIds"],
        serde_json::json!([old_live])
    );
    assert_eq!(origin(&state, &old_owner.id), saved_owner);
    assert!(!state
        .registry
        .enabled_manifests()
        .iter()
        .any(|m| m.id == old_live));
    drop(state);
    server.abort();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn tvbox_live_actual_update_apply_new_false_does_not_register_new_playlist() {
    let (proxy, _, a_live, server) = fixture().await;
    let dir = scratch("actual-update-no-new");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let a = import(&state, "a.json", "Subscription A").await;
    let vod = a["imported"][0]["id"].as_str().unwrap().to_owned();
    let old_live = a["liveImported"][0]["id"].as_str().unwrap().to_owned();
    let parent = a["originId"].as_str().unwrap().to_owned();
    crate::commands_provider::set_enabled_persisted(&state, &old_live, false).unwrap();
    *a_live.lock().unwrap() = "./b.m3u".into();
    let new_live = live_id_for("http://catalog.invalid/b.m3u");
    let updated = crate::tvbox::update_tvbox_source(&state, &vod, false, false)
        .await
        .unwrap();
    assert_eq!(updated["liveAdded"], serde_json::json!([]));
    assert_eq!(updated["liveNotApplied"][0]["id"], new_live);
    assert_eq!(updated["liveDeleted"], serde_json::json!([]));
    assert!(state.registry.get(&new_live).is_none());
    assert!(!persisted_live_ids(&state).contains(&new_live));
    assert!(persisted_live_ids(&state).contains(&old_live));
    assert_eq!(
        origin(&state, &parent)["relatedProviderIds"],
        serde_json::json!([])
    );
    drop(state);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert!(state.registry.get(&new_live).is_none());
    assert!(!state
        .registry
        .enabled_manifests()
        .iter()
        .any(|m| m.id == old_live));
    assert_eq!(
        origin(&state, &parent)["relatedProviderIds"],
        serde_json::json!([])
    );
    use_proxy(&state, &proxy);
    let updated = crate::tvbox::update_tvbox_source(&state, &vod, true, false)
        .await
        .unwrap();
    assert_eq!(updated["updated"], true);
    assert!(state.registry.get(&new_live).is_some());
    assert_eq!(
        origin(&state, &parent)["relatedProviderIds"],
        serde_json::json!([new_live])
    );
    drop(state);
    server.abort();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn tvbox_live_actual_update_does_not_adopt_foreign_live_when_apply_new_false() {
    let (proxy, _, a_live, server) = fixture().await;
    let dir = scratch("actual-update-foreign-disabled");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let a = import(&state, "a.json", "Subscription A").await;
    let b = import(&state, "b.json", "Independent B parent").await;
    let vod = a["imported"][0]["id"].as_str().unwrap();
    let b_live = b["liveImported"][0]["id"].as_str().unwrap().to_owned();
    let b_parent = b["originId"].as_str().unwrap().to_owned();
    let b_owner = catalog(&state)
        .unwrap()
        .origins
        .into_iter()
        .find(|o| o.kind == "live" && o.provider_ids.contains(&b_live))
        .unwrap();
    command_set_origin(&state, &serde_json::json!({"id":b_owner.id,"primaryUrl":"http://catalog.invalid/a-down.m3u","backupUrls":["http://catalog.invalid/a-backup.m3u"]})).unwrap();
    crate::commands_provider::set_enabled_persisted(&state, &b_live, false).unwrap();
    let saved_owner = origin(&state, &b_owner.id);
    let saved_name = state.registry.get(&b_live).unwrap().manifest().name.clone();
    *a_live.lock().unwrap() = "./b.m3u".into();
    let not_applied = crate::tvbox::update_tvbox_source(&state, vod, false, false)
        .await
        .unwrap();
    assert_eq!(not_applied["liveNotApplied"][0]["id"], b_live);
    assert_eq!(
        origin(&state, a["originId"].as_str().unwrap())["relatedProviderIds"],
        serde_json::json!([])
    );
    assert_eq!(
        origin(&state, &b_parent)["relatedProviderIds"],
        serde_json::json!([b_live])
    );
    let applied = crate::tvbox::update_tvbox_source(&state, vod, true, false)
        .await
        .unwrap();
    assert_eq!(applied["updated"], true);
    assert_eq!(
        origin(&state, a["originId"].as_str().unwrap())["relatedProviderIds"],
        serde_json::json!([b_live])
    );
    assert_eq!(
        origin(&state, &b_parent)["relatedProviderIds"],
        serde_json::json!([b_live])
    );
    assert_eq!(origin(&state, &b_owner.id), saved_owner);
    assert_eq!(
        state.registry.get(&b_live).unwrap().manifest().name,
        saved_name
    );
    assert!(!state
        .registry
        .enabled_manifests()
        .iter()
        .any(|m| m.id == b_live));
    drop(state);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_eq!(origin(&state, &b_owner.id), saved_owner);
    assert!(!state
        .registry
        .enabled_manifests()
        .iter()
        .any(|m| m.id == b_live));
    drop(state);
    server.abort();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn tvbox_live_actual_update_delete_missing_never_deletes_shared_or_independent_owners() {
    let (proxy, _, a_live, server) = fixture().await;
    let dir = scratch("actual-update-no-live-delete");
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    use_proxy(&state, &proxy);
    let a = import(&state, "a.json", "Subscription A").await;
    let shared = import(&state, "shared.json", "Subscription Shared").await;
    let b = import(&state, "b.json", "Independent B parent").await;
    let standalone = crate::source_catalog::import_live(
        &state,
        "http://catalog.invalid/standalone.m3u",
        "Standalone playlist",
        &[],
    )
    .await
    .unwrap();
    let standalone_live = standalone["id"].as_str().unwrap().to_owned();
    let standalone_owner = catalog(&state)
        .unwrap()
        .origins
        .into_iter()
        .find(|o| o.kind == "live" && o.provider_ids.contains(&standalone_live))
        .unwrap();
    let saved_standalone_owner = origin(&state, &standalone_owner.id);
    let vod = a["imported"][0]["id"].as_str().unwrap().to_owned();
    let old_live = a["liveImported"][0]["id"].as_str().unwrap().to_owned();
    let parent = a["originId"].as_str().unwrap().to_owned();
    let shared_parent = shared["originId"].as_str().unwrap().to_owned();
    let b_live = b["liveImported"][0]["id"].as_str().unwrap().to_owned();
    let b_parent = b["originId"].as_str().unwrap().to_owned();
    crate::commands_provider::set_enabled_persisted(&state, &old_live, false).unwrap();
    *a_live.lock().unwrap() = "__no_live__".into();
    let updated = crate::tvbox::update_tvbox_source(&state, &vod, true, true)
        .await
        .unwrap();
    assert_eq!(updated["updated"], true);
    assert_eq!(updated["liveRemoved"][0]["id"], old_live);
    assert_eq!(updated["liveDeleted"], serde_json::json!([]));
    assert_eq!(
        origin(&state, &parent)["relatedProviderIds"],
        serde_json::json!([])
    );
    assert_eq!(
        origin(&state, &shared_parent)["relatedProviderIds"],
        serde_json::json!([old_live])
    );
    assert_eq!(
        origin(&state, &b_parent)["relatedProviderIds"],
        serde_json::json!([b_live])
    );
    assert!(state.registry.get(&old_live).is_some());
    assert!(state.registry.get(&b_live).is_some());
    assert!(state.registry.get(&standalone_live).is_some());
    assert!(persisted_live_ids(&state).contains(&old_live));
    assert!(persisted_live_ids(&state).contains(&b_live));
    assert!(persisted_live_ids(&state).contains(&standalone_live));
    assert_eq!(origin(&state, &standalone_owner.id), saved_standalone_owner);
    drop(state);
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert!(state.registry.get(&old_live).is_some());
    assert!(state.registry.get(&b_live).is_some());
    assert!(state.registry.get(&standalone_live).is_some());
    assert_eq!(origin(&state, &standalone_owner.id), saved_standalone_owner);
    assert_eq!(
        origin(&state, &parent)["relatedProviderIds"],
        serde_json::json!([])
    );
    assert_eq!(
        origin(&state, &shared_parent)["relatedProviderIds"],
        serde_json::json!([old_live])
    );
    assert!(!state
        .registry
        .enabled_manifests()
        .iter()
        .any(|m| m.id == old_live));
    drop(state);
    server.abort();
    let _ = std::fs::remove_dir_all(dir);
}
