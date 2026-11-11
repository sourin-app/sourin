use super::*;
use axum::{
    http::{StatusCode, Uri},
    response::IntoResponse,
    routing::get,
};

fn scratch() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "sourin-live-refresh-persistence-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos(),
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

async fn fixture() -> (String, Arc<Mutex<String>>, tokio::task::JoinHandle<()>) {
    let current_live = Arc::new(Mutex::new("./old.m3u".to_owned()));
    let route_live = current_live.clone();
    let app = axum::Router::new().fallback(get(move |uri: Uri| {
        let current_live = route_live.clone();
        async move {
            match uri.path() {
                "/subscription.json" => serde_json::json!({
                    "sites": [{
                        "key": "vod-a",
                        "name": "VOD A",
                        "type": 1,
                        "api": "http://catalog.invalid/cms"
                    }],
                    "lives": [{
                        "name": "Fixture live",
                        "url": current_live.lock().unwrap().clone()
                    }]
                }).to_string().into_response(),
                "/cms" => r#"{"class":[{"type_id":"1","type_name":"Movies"}],"list":[{"vod_id":"fixture-video","vod_name":"Fixture movie"}],"total":1}"#.into_response(),
                "/old.m3u" | "/new.m3u" => "#EXTM3U\n#EXTINF:-1,Fixture live\n./streams/channel.m3u8\n".into_response(),
                _ => StatusCode::NOT_FOUND.into_response(),
            }
        }
    }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (proxy, current_live, server)
}

fn registry_ids(state: &AppState) -> HashSet<String> {
    state
        .registry
        .manifests()
        .into_iter()
        .map(|m| m.id)
        .collect()
}

fn memory_rows(state: &AppState) -> serde_json::Value {
    serde_json::to_value(state.third_party.read().unwrap().clone()).unwrap()
}

fn disk_has_live(dir: &Path, wanted: &str) -> bool {
    crate::persist::load_persisted(dir)
        .into_iter()
        .any(|row| matches!(row, PersistedProvider::M3uLive { id, .. } if id == wanted))
}

fn saved_parent_related(dir: &Path, parent: &str) -> Vec<String> {
    load(dir)
        .origins
        .into_iter()
        .find(|origin| origin.id == parent)
        .expect("the imported parent must remain saved")
        .related_provider_ids
}

fn check(problems: &mut Vec<String>, condition: bool, description: &str) {
    if !condition {
        problems.push(description.to_owned());
    }
}

#[tokio::test]
async fn tvbox_live_refresh_persistence_failure_does_not_publish_and_retry_survives_restart() {
    let (proxy, current_live, server) = fixture().await;
    let dir = scratch();
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    state
        .proxy
        .set(
            crate::proxy::GLOBAL_PROXY,
            crate::proxy::ProxyConfig {
                mode: crate::proxy::ProxyMode::Custom,
                url: Some(proxy),
                ..Default::default()
            },
        )
        .unwrap();
    let imported = crate::tvbox::import_tvbox_config_with_options(
        &state,
        "http://catalog.invalid/subscription.json",
        &[],
        Some("Persistence fixture parent"),
    )
    .await
    .expect("the unchanged VOD and old live fixture must import successfully");
    assert_eq!(imported["imported"].as_array().unwrap().len(), 1);
    assert_eq!(imported["liveImported"].as_array().unwrap().len(), 1);
    let vod = imported["imported"][0]["id"].as_str().unwrap().to_owned();
    let old_live = imported["liveImported"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let parent = imported["originId"].as_str().unwrap().to_owned();
    let provider = crate::providers::m3u_live::M3uLiveProvider::new(
        "Fixture live",
        "http://catalog.invalid/new.m3u",
    );
    let new_live = crate::provider::MediaProvider::manifest(&provider)
        .id
        .clone();
    assert_ne!(new_live, old_live);
    assert!(state.registry.get(&vod).is_some());
    assert!(state.registry.get(&old_live).is_some());
    assert!(disk_has_live(&dir, &old_live));
    assert!(state.registry.get(&new_live).is_none());
    assert!(!disk_has_live(&dir, &new_live));
    assert_eq!(saved_parent_related(&dir, &parent), vec![old_live.clone()]);

    let providers_file = crate::persist::providers_file(&dir);
    let blocked_tmp = providers_file.with_extension("json.tmp");
    let before_disk = std::fs::read(&providers_file).unwrap();
    let before_memory = memory_rows(&state);
    let before_registry = registry_ids(&state);
    assert!(
        !blocked_tmp.exists(),
        "a previous fixture write must have completed"
    );
    std::fs::create_dir(&blocked_tmp).expect("create only the synthetic save obstruction");
    assert!(blocked_tmp.is_dir());
    *current_live.lock().unwrap() = "./new.m3u".to_owned();

    // VOD is unchanged and deletion is disabled: no other update path can
    // incidentally rewrite third-party rows and hide the live failure.
    let failed = crate::tvbox::update_tvbox_source(&state, &vod, true, false)
        .await
        .expect_err("the actual providers-file save must fail");
    assert!(
        failed.contains("写入临时清单失败"),
        "the failure must come from real save_persisted, not fixture readiness: {failed}"
    );

    // Collect contract failures so the original candidate also reaches retry
    // and restart. The final assertion still makes every violation a failure.
    let mut problems = Vec::new();
    check(
        &mut problems,
        std::fs::read(&providers_file).unwrap() == before_disk,
        "failed save changed the original providers file",
    );
    check(
        &mut problems,
        registry_ids(&state) == before_registry,
        "failed save changed the registered provider set",
    );
    check(
        &mut problems,
        state.registry.get(&new_live).is_none(),
        "failed save published the new live provider in the registry",
    );
    check(
        &mut problems,
        memory_rows(&state) == before_memory,
        "failed save committed the new live row to third_party memory",
    );
    check(
        &mut problems,
        saved_parent_related(&dir, &parent) == vec![old_live.clone()],
        "failed save changed the parent's saved live membership",
    );

    std::fs::remove_dir(&blocked_tmp).expect("remove the synthetic empty obstruction");
    let retry = crate::tvbox::update_tvbox_source(&state, &vod, true, false).await;
    match retry {
        Ok(result) => check(
            &mut problems,
            result["updated"] == true,
            "retry did not report applying the live refresh",
        ),
        Err(error) => problems.push(format!(
            "retry failed after repairing the save path: {error}"
        )),
    }
    check(
        &mut problems,
        state.registry.get(&new_live).is_some(),
        "retry did not register the new live provider",
    );
    check(
        &mut problems,
        disk_has_live(&dir, &new_live),
        "retry succeeded without persisting the new live row",
    );
    check(
        &mut problems,
        disk_has_live(&dir, &old_live),
        "retry deleted the independent old live provider row",
    );
    check(
        &mut problems,
        saved_parent_related(&dir, &parent) == vec![new_live.clone()],
        "retry did not save the new parent live membership",
    );
    drop(state);

    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    check(
        &mut problems,
        restored.registry.get(&new_live).is_some(),
        "restart lost the new live provider after the retry",
    );
    check(
        &mut problems,
        restored.registry.get(&vod).is_some(),
        "restart lost the unchanged VOD provider",
    );
    check(
        &mut problems,
        restored.registry.get(&old_live).is_some(),
        "restart lost the independent old live provider",
    );
    let restored_parent = catalog(&restored)
        .unwrap()
        .origins
        .into_iter()
        .find(|origin| origin.id == parent)
        .expect("restart must retain the TVBox parent");
    check(
        &mut problems,
        restored_parent.related_provider_ids == vec![new_live],
        "restart pruned or changed the new parent live membership",
    );
    drop(restored);
    server.abort();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        problems.is_empty(),
        "live persistence contract violations:\n{}",
        problems.join("\n")
    );
}
