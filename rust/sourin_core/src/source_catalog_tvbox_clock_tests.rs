use super::*;
use axum::{
    http::{StatusCode, Uri},
    response::IntoResponse,
    routing::get,
};

const BASE: &str = "http://catalog.invalid";

struct Env {
    dir: std::path::PathBuf,
    proxy: String,
    configs: Arc<Mutex<BTreeMap<String, serde_json::Value>>>,
    requests: Arc<Mutex<Vec<String>>>,
    server: tokio::task::JoinHandle<()>,
}

impl Env {
    async fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "sourin-origin-refresh-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let mut schedule = crate::tvbox::load_tvbox_update_schedule(&dir);
        schedule.enabled = false;
        crate::tvbox::save_tvbox_update_schedule(&dir, &schedule).unwrap();
        let configs = Arc::new(Mutex::new(BTreeMap::<String, serde_json::Value>::new()));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let route_configs = configs.clone();
        let route_requests = requests.clone();
        let app = axum::Router::new().fallback(get(move |uri: Uri| {
            let configs = route_configs.clone();
            let requests = route_requests.clone();
            async move {
                requests.lock().unwrap().push(uri.to_string());
                let configured = configs.lock().unwrap().get(uri.path()).cloned();
                if let Some(configured) = configured {
                    return configured.to_string().into_response();
                }
                if uri.path().ends_with("-down.json") || uri.path().ends_with("-down.m3u") {
                    return StatusCode::SERVICE_UNAVAILABLE.into_response();
                }
                if uri.path().starts_with("/cms-") {
                    return r#"{"class":[{"type_id":"1","type_name":"Movies"}],"list":[{"vod_id":"fixture-video","vod_name":"Fixture movie"}],"total":1}"#.into_response();
                }
                if uri.path().ends_with(".m3u") {
                    return "#EXTM3U\n#EXTINF:-1,Fixture channel\n./streams/channel.m3u8\n".into_response();
                }
                StatusCode::NOT_FOUND.into_response()
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self {
            dir,
            proxy,
            configs,
            requests,
            server,
        }
    }

    fn put(&self, path: &str, config: serde_json::Value) {
        self.configs.lock().unwrap().insert(path.to_owned(), config);
    }

    async fn state(&self) -> Arc<AppState> {
        let state = AppState::bootstrap(self.dir.clone()).await.unwrap();
        assert!(
            !crate::tvbox::load_tvbox_update_schedule(&self.dir).enabled,
            "the synthetic fixture must not schedule background refresh"
        );
        state
            .proxy
            .set(
                crate::proxy::GLOBAL_PROXY,
                crate::proxy::ProxyConfig {
                    mode: crate::proxy::ProxyMode::Custom,
                    url: Some(self.proxy.clone()),
                    ..Default::default()
                },
            )
            .unwrap();
        state
    }

    fn clear_requests(&self) {
        self.requests.lock().unwrap().clear();
    }

    fn observed_requests(&self) -> Vec<String> {
        self.requests.lock().unwrap().clone()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        self.server.abort();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn url(path: &str) -> String {
    format!("{BASE}{path}")
}

fn live(name: &str, path: &str) -> serde_json::Value {
    serde_json::json!({"name":name,"url":url(path)})
}

fn site(key: &str, name: &str, api_path: &str) -> serde_json::Value {
    serde_json::json!({"key":key,"name":name,"type":1,"api":url(api_path)})
}

fn direct(sites: Vec<serde_json::Value>, lives: Vec<serde_json::Value>) -> serde_json::Value {
    serde_json::json!({"sites":sites,"lives":lives})
}

fn live_only(lives: Vec<serde_json::Value>) -> serde_json::Value {
    serde_json::json!({"lives":lives})
}

async fn import(state: &AppState, path: &str, name: &str) -> serde_json::Value {
    crate::tvbox::import_tvbox_config_with_options(state, &url(path), &[], Some(name))
        .await
        .expect("actual loopback import must establish the fixture before refresh")
}

fn raw_parent(dir: &Path, id: &str) -> serde_json::Value {
    let saved: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.join("source-catalog.json")).unwrap()).unwrap();
    saved["origins"]
        .as_array()
        .unwrap()
        .iter()
        .find(|origin| origin["id"] == id)
        .unwrap()
        .clone()
}

fn stamp_value(dir: &Path, id: &str) -> serde_json::Value {
    let origin = raw_parent(dir, id);
    serde_json::json!([
        origin["lastUpdateAt"],
        origin["lastUpdateOk"],
        origin["lastUpdateError"]
    ])
}

fn seed_clock(dir: &Path, id: &str, at: i64, ok: bool, error: Option<&str>) {
    let path = dir.join("source-catalog.json");
    let mut saved: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let origin = saved["origins"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|origin| origin["id"] == id)
        .unwrap();
    origin["lastUpdateAt"] = at.into();
    origin["lastUpdateOk"] = ok.into();
    origin["lastUpdateError"] = error.map(str::to_owned).into();
    std::fs::write(path, serde_json::to_vec_pretty(&saved).unwrap()).unwrap();
}

fn live_id(path: &str) -> String {
    let provider = crate::providers::m3u_live::M3uLiveProvider::new("Fixture", &url(path));
    crate::provider::MediaProvider::manifest(&provider)
        .id
        .clone()
}

#[tokio::test]
async fn tvbox_parent_clock_import_records_a_real_pure_live_update() {
    let env = Env::new("clock-import").await;
    env.put("/parent.json", live_only(vec![live("A", "/a.m3u")]));
    let state = env.state().await;
    let before = now_secs();
    let imported = import(&state, "/parent.json", "Pure live clock").await;
    let id = imported["originId"].as_str().unwrap();
    let saved = raw_parent(&env.dir, id);
    assert_eq!(saved["providerIds"], serde_json::json!([]));
    assert!(
        saved["lastUpdateAt"]
            .as_i64()
            .is_some_and(|at| at >= before && at <= now_secs()),
        "successful real pure-live import must establish a parent update time: {saved}"
    );
    assert_eq!(saved["lastUpdateOk"], true);
    assert_eq!(saved["lastUpdateError"], serde_json::Value::Null);
    assert!(state.registry.get(&live_id("/a.m3u")).is_some());
}

#[tokio::test]
async fn tvbox_parent_clock_check_is_not_update_and_unchanged_update_is_stamped() {
    let env = Env::new("clock-check").await;
    env.put("/parent.json", live_only(vec![live("A", "/a.m3u")]));
    let state = env.state().await;
    let imported = import(&state, "/parent.json", "Check clock").await;
    let id = imported["originId"].as_str().unwrap();
    seed_clock(&env.dir, id, 1234, false, Some("earlier synthetic failure"));
    let expected = stamp_value(&env.dir, id);
    let checked = crate::tvbox::check_tvbox_updates(&state, Some(id))
        .await
        .unwrap();
    assert_eq!(checked["items"][0]["ok"], true);
    assert_eq!(
        stamp_value(&env.dir, id),
        expected,
        "fetch success while checking cannot masquerade as an applied update"
    );
    let updated = crate::tvbox::update_tvbox_source(&state, id, true, false)
        .await
        .unwrap();
    assert_eq!(
        updated["updated"], false,
        "fixture is an actual unchanged subscription"
    );
    let saved = raw_parent(&env.dir, id);
    assert!(saved["lastUpdateAt"].as_i64().is_some_and(|at| at > 1234));
    assert_eq!(saved["lastUpdateOk"], true);
    assert_eq!(saved["lastUpdateError"], serde_json::Value::Null);
}

#[tokio::test]
async fn tvbox_parent_clock_failed_pure_live_update_is_durable_and_exact() {
    let env = Env::new("clock-failure").await;
    env.put("/first.json", live_only(vec![live("A", "/a.m3u")]));
    env.put("/second.json", live_only(vec![live("B", "/b.m3u")]));
    let state = env.state().await;
    let first = import(&state, "/first.json", "First").await;
    let second = import(&state, "/second.json", "Second").await;
    let a = first["originId"].as_str().unwrap();
    let b = second["originId"].as_str().unwrap();
    command_set_origin(
        &state,
        &serde_json::json!({
            "id":a,"primaryUrl":url("/failure-down.json"),"backupUrls":[],
        }),
    )
    .unwrap();
    seed_clock(&env.dir, a, 1234, true, None);
    seed_clock(&env.dir, b, 5678, false, Some("second retained failure"));
    let before_b = stamp_value(&env.dir, b);
    assert!(crate::tvbox::update_tvbox_source(&state, a, true, false)
        .await
        .is_err());
    let failed = raw_parent(&env.dir, a);
    assert!(failed["lastUpdateAt"].as_i64().is_some_and(|at| at > 1234));
    assert_eq!(failed["lastUpdateOk"], false);
    assert!(failed["lastUpdateError"]
        .as_str()
        .is_some_and(|error| !error.trim().is_empty()));
    assert_eq!(stamp_value(&env.dir, b), before_b);
    let bootstrap = env.state().await;
    let restored = command_get(&bootstrap).unwrap();
    assert_eq!(
        restored["origins"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == a)
            .unwrap(),
        &failed
    );
}

#[tokio::test]
async fn tvbox_parent_clock_invalid_target_never_stamps_or_requests() {
    let env = Env::new("clock-invalid").await;
    env.put("/parent.json", live_only(vec![live("A", "/a.m3u")]));
    let state = env.state().await;
    let imported = import(&state, "/parent.json", "Invalid control").await;
    let id = imported["originId"].as_str().unwrap();
    seed_clock(&env.dir, id, 1234, true, None);
    let before = std::fs::read(env.dir.join("source-catalog.json")).unwrap();
    env.clear_requests();
    assert!(
        crate::tvbox::update_tvbox_source(&state, "missing-parent", true, false)
            .await
            .is_err()
    );
    assert_eq!(
        std::fs::read(env.dir.join("source-catalog.json")).unwrap(),
        before
    );
    assert!(env.observed_requests().is_empty());
}

#[tokio::test]
async fn tvbox_parent_clock_migrates_only_its_owned_vod_stamps() {
    let env = Env::new("clock-legacy").await;
    env.put(
        "/mixed.json",
        direct(
            vec![
                site("one", "One", "/cms-one"),
                site("two", "Two", "/cms-two"),
            ],
            vec![],
        ),
    );
    let state = env.state().await;
    let imported = import(&state, "/mixed.json", "Legacy mixed").await;
    let id = imported["originId"].as_str().unwrap();
    let ids: Vec<_> = imported["imported"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(ids.len(), 2);
    for (i, vod) in ids.iter().enumerate() {
        let mut meta = crate::tvbox::read_tvbox_meta(&env.dir, vod).unwrap();
        meta.last_update_at = if i == 0 { 1234 } else { 5678 };
        meta.last_update_ok = i != 0;
        meta.last_update_error = (i == 0).then(|| "retained child failure".to_owned());
        crate::tvbox::write_tvbox_meta(&env.dir, vod, &meta).unwrap();
    }
    let path = env.dir.join("source-catalog.json");
    let mut saved: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let origin = saved["origins"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|row| row["id"] == id)
        .unwrap()
        .as_object_mut()
        .unwrap();
    for key in ["lastUpdateAt", "lastUpdateOk", "lastUpdateError"] {
        origin.remove(key);
    }
    std::fs::write(&path, serde_json::to_vec_pretty(&saved).unwrap()).unwrap();
    let output = command_get(&state).unwrap();
    let migrated = output["origins"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == id)
        .unwrap();
    assert_eq!(migrated["lastUpdateAt"], 5678);
    assert_eq!(migrated["lastUpdateOk"], false);
    assert_eq!(migrated["lastUpdateError"], "retained child failure");
    assert_eq!(
        raw_parent(&env.dir, id),
        *migrated,
        "migration must be durable, not a transient JSON facade"
    );
}

// Keep an executable task ready so paused Tokio time cannot auto-jump across
// reqwest timers while real loopback I/O is in flight. The runtime and production
// scheduler remain real; only their clock is advanced explicitly by the test.
struct Awake(tokio::task::JoinHandle<()>);
impl Awake {
    fn new() -> Self {
        Self(tokio::spawn(async {
            loop {
                tokio::task::yield_now().await;
            }
        }))
    }
}
impl Drop for Awake {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn drive_runtime() {
    let end = std::time::Instant::now() + std::time::Duration::from_millis(180);
    while std::time::Instant::now() < end {
        tokio::task::yield_now().await;
    }
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn tvbox_parent_clock_bootstrap_scheduler_updates_same_url_pure_live_parents_independently() {
    let _awake = Awake::new();
    let env = Env::new("clock-scheduler").await;
    env.put("/first.json", live_only(vec![live("A", "/old-a.m3u")]));
    env.put("/second.json", live_only(vec![live("B", "/old-b.m3u")]));
    let state = env.state().await;
    drive_runtime().await;
    let first = import(&state, "/first.json", "First clock").await;
    let second = import(&state, "/second.json", "Second clock").await;
    let a = first["originId"].as_str().unwrap();
    let b = second["originId"].as_str().unwrap();
    for (id, backup) in [(a, "/first.json"), (b, "/second.json")] {
        command_set_origin(
            &state,
            &serde_json::json!({
                "id":id,"primaryUrl":url("/shared-down.json"),"backupUrls":[url(backup)],
            }),
        )
        .unwrap();
        seed_clock(&env.dir, id, 0, false, None);
        assert_eq!(
            raw_parent(&env.dir, id)["providerIds"],
            serde_json::json!([])
        );
    }
    let old_live = live_id("/old-a.m3u");
    crate::commands::save_disabled(&env.dir, std::slice::from_ref(&old_live)).unwrap();
    sync_enabled(&state.registry, &env.dir);
    let old_owner = command_get(&state).unwrap()["origins"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| {
            row["kind"] == "live"
                && row["providerIds"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|id| id == &old_live)
        })
        .unwrap()
        .clone();
    env.put("/first.json", live_only(vec![live("A new", "/new-a.m3u")]));
    env.put("/second.json", live_only(vec![live("B new", "/new-b.m3u")]));
    env.clear_requests();
    crate::tvbox::tvbox_update_schedule_set(&state, true, 21600).unwrap();
    tokio::time::advance(Duration::from_secs(59)).await;
    drive_runtime().await;
    assert!(
        env.observed_requests().is_empty(),
        "startup delay must remain intact"
    );
    tokio::time::advance(Duration::from_secs(1)).await;
    drive_runtime().await;
    assert!(
        state.registry.get(&live_id("/new-a.m3u")).is_some(),
        "the actual bootstrap scheduler omits due pure-live parents: {:?}",
        env.observed_requests()
    );
    assert!(
        state.registry.get(&live_id("/new-b.m3u")).is_some(),
        "same primary URL cannot collapse distinct parent backup chains"
    );
    let requests = env.observed_requests();
    assert_eq!(
        requests
            .iter()
            .filter(|url| url.ends_with("/first.json"))
            .count(),
        1
    );
    assert_eq!(
        requests
            .iter()
            .filter(|url| url.ends_with("/second.json"))
            .count(),
        1
    );
    for id in [a, b] {
        let parent = raw_parent(&env.dir, id);
        assert!(parent["lastUpdateAt"].as_i64().is_some_and(|at| at > 0));
        assert_eq!(parent["lastUpdateOk"], true);
    }
    assert_eq!(
        raw_parent(&env.dir, a)["relatedProviderIds"],
        serde_json::json!([live_id("/new-a.m3u")])
    );
    assert_eq!(
        raw_parent(&env.dir, b)["relatedProviderIds"],
        serde_json::json!([live_id("/new-b.m3u")])
    );
    assert!(crate::commands::load_disabled(&env.dir).contains(&old_live));
    assert!(
        state.registry.get(&old_live).is_some(),
        "automatic update detaches attribution without deleting a playlist"
    );
    let stored = command_get(&state).unwrap();
    assert_eq!(
        stored["origins"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == old_owner["id"])
            .unwrap(),
        &old_owner
    );
    env.clear_requests();
    tokio::time::advance(Duration::from_secs(60)).await;
    drive_runtime().await;
    assert!(
        env.observed_requests().is_empty(),
        "accepted clocks prevent a second overdue fetch"
    );
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn tvbox_parent_clock_disabled_scheduler_does_not_request_or_stamp() {
    let _awake = Awake::new();
    let env = Env::new("clock-off").await;
    env.put("/parent.json", live_only(vec![live("A", "/a.m3u")]));
    let state = env.state().await;
    drive_runtime().await;
    let imported = import(&state, "/parent.json", "Disabled clock").await;
    let id = imported["originId"].as_str().unwrap();
    seed_clock(&env.dir, id, 0, false, None);
    let before = stamp_value(&env.dir, id);
    env.clear_requests();
    tokio::time::advance(Duration::from_secs(120)).await;
    drive_runtime().await;
    assert!(env.observed_requests().is_empty());
    assert_eq!(stamp_value(&env.dir, id), before);
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn tvbox_parent_clock_vod_scheduler_control_reaches_the_real_update_path() {
    let _awake = Awake::new();
    let env = Env::new("clock-vod-control").await;
    env.put(
        "/mixed.json",
        direct(vec![site("vod", "VOD", "/cms-vod")], vec![]),
    );
    let state = env.state().await;
    drive_runtime().await;
    let imported = import(&state, "/mixed.json", "VOD control").await;
    let id = imported["originId"].as_str().unwrap();
    let vod = imported["imported"][0]["id"].as_str().unwrap();
    let mut meta = crate::tvbox::read_tvbox_meta(&env.dir, vod).unwrap();
    meta.last_update_at = 0;
    meta.last_update_ok = false;
    crate::tvbox::write_tvbox_meta(&env.dir, vod, &meta).unwrap();
    seed_clock(&env.dir, id, 0, false, None);
    env.clear_requests();
    crate::tvbox::tvbox_update_schedule_set(&state, true, 21600).unwrap();
    tokio::time::advance(Duration::from_secs(60)).await;
    drive_runtime().await;
    assert!(
        !env.observed_requests().is_empty(),
        "the clock harness must execute the existing VOD scheduler"
    );
    assert!(
        crate::tvbox::read_tvbox_meta(&env.dir, vod)
            .unwrap()
            .last_update_at
            > 0
    );
    assert!(state.registry.get(vod).is_some());
}

#[tokio::test]
async fn tvbox_parent_clock_partial_probe_failure_cannot_be_a_success_stamp() {
    let env = Env::new("clock-partial").await;
    env.put("/partial.json", live_only(vec![live("A", "/a.m3u")]));
    let state = env.state().await;
    let imported = import(&state, "/partial.json", "Partial update").await;
    let id = imported["originId"].as_str().unwrap();
    seed_clock(&env.dir, id, 1234, true, None);
    env.put(
        "/partial.json",
        direct(
            vec![site("failed-later", "Failed later", "/reject")],
            vec![live("A", "/a.m3u")],
        ),
    );
    let updated = crate::tvbox::update_tvbox_source(&state, id, true, false)
        .await
        .unwrap();
    assert_eq!(updated["failed"].as_array().unwrap().len(), 1,
        "the real probe must produce a failed result within a successful outer response");
    assert_eq!(updated["updated"], false);
    let saved = raw_parent(&env.dir, id);
    assert_eq!(saved["lastUpdateOk"], false,
        "Result::Ok with an actual failed probe cannot be recorded as a successful parent update");
    assert!(saved["lastUpdateAt"].as_i64().is_some_and(|at| at > 1234));
    assert!(saved["lastUpdateError"].as_str().is_some_and(|error| !error.trim().is_empty()));
}

#[path = "source_catalog_tvbox_clock_additional_tests.rs"]
mod additional_clock_tests;
