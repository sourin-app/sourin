// Include as a child module of source_catalog_tvbox_clock_tests.rs.
// These use real update/import, HTTP and file boundaries; no clock implementation
// or production test seam is injected. The owning root runs qualification.
use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

#[tokio::test]
async fn tvbox_parent_clock_partial_probe_failure_is_not_successful_just_because_result_is_ok() {
    let env = Env::new("clock-partial-failure").await;
    env.put(
        "/partial.json",
        direct(vec![site("vod", "Original VOD", "/cms-original")], vec![]),
    );
    let state = env.state().await;
    let imported = import(&state, "/partial.json", "Partial parent").await;
    let parent = imported["originId"].as_str().unwrap();
    let vod = imported["imported"][0]["id"].as_str().unwrap();
    seed_clock(&env.dir, parent, 1234, true, None);
    env.put(
        "/partial.json",
        direct(
            vec![site("vod", "Original VOD", "/missing-vod-api")],
            vec![],
        ),
    );
    env.clear_requests();
    let result = crate::tvbox::update_tvbox_source(&state, parent, true, false)
        .await
        .expect("per-site failure is an actual structured Ok result");
    assert_eq!(result["updated"], false);
    assert_eq!(result["failed"].as_array().unwrap().len(), 1);
    assert!(result["failed"][0]["reason"]
        .as_str()
        .is_some_and(|why| !why.is_empty()));
    assert!(env
        .observed_requests()
        .iter()
        .any(|request| request.contains("/missing-vod-api")));
    assert!(
        state.registry.get(vod).is_some(),
        "failed probing retains the existing provider"
    );
    let saved = raw_parent(&env.dir, parent);
    assert!(saved["lastUpdateAt"].as_i64().is_some_and(|at| at > 1234));
    assert_eq!(
        saved["lastUpdateOk"], false,
        "Ok reports can contain real per-site failures and cannot stamp parent success"
    );
    assert!(saved["lastUpdateError"]
        .as_str()
        .is_some_and(|why| !why.is_empty()));
}

#[tokio::test]
async fn tvbox_parent_clock_explicit_zero_is_not_replaced_by_recent_owned_vod_history() {
    let env = Env::new("clock-explicit-zero").await;
    env.put(
        "/mixed.json",
        direct(vec![site("vod", "VOD", "/cms-vod")], vec![]),
    );
    let state = env.state().await;
    let imported = import(&state, "/mixed.json", "Explicit zero").await;
    let parent = imported["originId"].as_str().unwrap();
    let vod = imported["imported"][0]["id"].as_str().unwrap();
    assert!(
        crate::tvbox::read_tvbox_meta(&env.dir, vod)
            .unwrap()
            .last_update_at
            > 0
    );
    seed_clock(&env.dir, parent, 0, false, None);
    let before_sidecar = std::fs::read(env.dir.join("tvbox-sources.json")).unwrap();
    let catalog = command_get(&state).unwrap();
    let current = catalog["origins"]
        .as_array()
        .unwrap()
        .iter()
        .find(|origin| origin["id"] == parent)
        .unwrap();
    assert_eq!(
        current["lastUpdateAt"], 0,
        "only a missing clock can migrate; explicit zero remains due despite recent VOD stamps"
    );
    assert_eq!(current["lastUpdateOk"], false);
    assert_eq!(
        stamp_value(&env.dir, parent),
        serde_json::json!([0, false, null])
    );
    assert_eq!(
        std::fs::read(env.dir.join("tvbox-sources.json")).unwrap(),
        before_sidecar
    );
}

#[derive(Clone, Default)]
struct FaultObservation {
    probe_requests: usize,
    fetch_saved_before_block: bool,
    blocked: bool,
    clock_before_block: serde_json::Value,
    errors: Vec<String>,
}

struct ClockSaveEnv {
    dir: std::path::PathBuf,
    proxy: String,
    replacement: Arc<AtomicBool>,
    armed: Arc<AtomicBool>,
    block_save: bool,
    parent: Arc<Mutex<Option<String>>>,
    observation: Arc<Mutex<FaultObservation>>,
    requests: Arc<Mutex<Vec<String>>>,
    server: tokio::task::JoinHandle<()>,
}

impl ClockSaveEnv {
    async fn new(block_save: bool) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "sourin-clock-save-fault-{}-{}",
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
        let replacement = Arc::new(AtomicBool::new(false));
        let armed = Arc::new(AtomicBool::new(false));
        let parent = Arc::new(Mutex::new(None::<String>));
        let observation = Arc::new(Mutex::new(FaultObservation::default()));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let route_dir = dir.clone();
        let route_replacement = replacement.clone();
        let route_armed = armed.clone();
        let route_parent = parent.clone();
        let route_observation = observation.clone();
        let route_requests = requests.clone();
        let app = axum::Router::new().fallback(get(move |uri: Uri| {
            let dir = route_dir.clone();
            let replacement = route_replacement.clone();
            let armed = route_armed.clone();
            let parent = route_parent.clone();
            let observation = route_observation.clone();
            let requests = route_requests.clone();
            async move {
                requests.lock().unwrap().push(uri.to_string());
                match uri.path() {
                    "/changed.json" => {
                        let (name, api) = if replacement.load(Ordering::SeqCst) {
                            ("Replacement VOD", "/cms-next")
                        } else {
                            ("Original VOD", "/cms-original")
                        };
                        direct(vec![site("same-vod-key", name, api)], vec![]).to_string().into_response()
                    }
                    "/cms-original" => {
                        r#"{"class":[{"type_id":"1","type_name":"Original category"}],"list":[{"vod_id":"old","vod_name":"Original item"}],"total":1}"#.into_response()
                    }
                    "/cms-next" => {
                        if armed.load(Ordering::SeqCst) {
                            let id = parent.lock().unwrap().clone();
                            let mut observed = observation.lock().unwrap();
                            observed.probe_requests += 1;
                            if let Some(id) = id {
                                let path = dir.join("source-catalog.json");
                                let stored = std::fs::read(&path).ok()
                                    .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
                                if let Some(stored) = stored {
                                    if let Some(origin) = stored["origins"].as_array().unwrap().iter()
                                        .find(|origin| origin["id"] == id)
                                    {
                                        observed.fetch_saved_before_block =
                                            origin["lastSuccessfulUrl"] == url("/changed.json")
                                            && origin["lastSuccessfulEndpoint"] == url("/changed.json")
                                            && origin["lastSuccessAt"].as_i64().is_some_and(|at| at > 0);
                                        observed.clock_before_block = serde_json::json!([
                                            origin["lastUpdateAt"], origin["lastUpdateOk"], origin["lastUpdateError"],
                                        ]);
                                    } else {
                                        observed.errors.push("the real fetched parent is missing before probe".into());
                                    }
                                } else {
                                    observed.errors.push("could not read the actual fetched catalog before probe".into());
                                }
                            } else {
                                observed.errors.push("the synthetic parent was not established before arming".into());
                            }
                            if block_save {
                                let blocked = dir.join("source-catalog.json.tmp");
                                if blocked.is_dir() {
                                    observed.blocked = true;
                                } else {
                                    match std::fs::create_dir(&blocked) {
                                        Ok(()) => observed.blocked = true,
                                        Err(error) => observed.errors.push(format!("could not create the actual save fault: {error}")),
                                    }
                                }
                            }
                        }
                        r#"{"class":[{"type_id":"2","type_name":"Replacement category"}],"list":[{"vod_id":"new","vod_name":"Replacement item"}],"total":1}"#.into_response()
                    }
                    _ => StatusCode::NOT_FOUND.into_response(),
                }
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self {
            dir,
            proxy,
            replacement,
            armed,
            block_save,
            parent,
            observation,
            requests,
            server,
        }
    }

    async fn state(&self) -> Arc<AppState> {
        let state = AppState::bootstrap(self.dir.clone()).await.unwrap();
        assert!(!crate::tvbox::load_tvbox_update_schedule(&self.dir).enabled);
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

    fn prepare_changed_update(&self, parent: &str) {
        *self.parent.lock().unwrap() = Some(parent.to_owned());
        seed_clock(&self.dir, parent, 1234, true, None);
        let path = self.dir.join("source-catalog.json");
        let mut catalog: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        let row = catalog["origins"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|origin| origin["id"] == parent)
            .unwrap();
        // Make the real fetch persistence observable independently of import.
        row["lastSuccessfulUrl"] = serde_json::Value::Null;
        row["lastSuccessfulEndpoint"] = serde_json::Value::Null;
        row["lastSuccessAt"] = 0.into();
        std::fs::write(path, serde_json::to_vec_pretty(&catalog).unwrap()).unwrap();
        self.requests.lock().unwrap().clear();
        self.replacement.store(true, Ordering::SeqCst);
        self.armed.store(true, Ordering::SeqCst);
    }
}

impl Drop for ClockSaveEnv {
    fn drop(&mut self) {
        self.server.abort();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn assert_replacement_is_persisted(state: &AppState, vod: &str) {
    assert_eq!(
        state.registry.get(vod).unwrap().manifest().name,
        "Replacement VOD"
    );
    let rows = crate::persist::load_persisted(&state.data_dir);
    let row = rows.iter().find(|provider| provider.id() == vod).unwrap();
    match row {
        crate::model::PersistedProvider::Tvbox { api, name, .. } => {
            assert_eq!(api, &url("/cms-next"));
            assert_eq!(name, "Replacement VOD");
        }
        _ => panic!("the real stable-ID VOD row must remain persisted"),
    }
    let meta = crate::tvbox::read_tvbox_meta(&state.data_dir, vod).unwrap();
    assert_eq!(meta.api, url("/cms-next"));
    assert_eq!(meta.source_url, Some(url("/changed.json")));
}

async fn exercise_clock_save_boundary(block_save: bool) {
    let env = ClockSaveEnv::new(block_save).await;
    let state = env.state().await;
    let imported = crate::tvbox::import_tvbox_config_with_options(
        &state,
        &url("/changed.json"),
        &[],
        Some("Clock save parent"),
    )
    .await
    .unwrap();
    assert_eq!(imported["imported"].as_array().unwrap().len(), 1);
    let parent = imported["originId"].as_str().unwrap();
    let vod = imported["imported"][0]["id"].as_str().unwrap();
    env.prepare_changed_update(parent);
    let result = crate::tvbox::update_tvbox_source(&state, parent, true, false)
        .await
        .expect("a failed status save cannot erase an actually applied VOD result");
    let observed = env.observation.lock().unwrap().clone();
    assert!(
        observed.errors.is_empty(),
        "fixture qualification failed: {:?}",
        observed.errors
    );
    assert!(
        observed.probe_requests > 0,
        "actual update must request the changed API"
    );
    assert!(
        observed.fetch_saved_before_block,
        "fault must occur after actual config fetch persistence"
    );
    assert_eq!(observed.blocked, env.block_save);
    assert_eq!(result["updated"], true);
    assert_eq!(result["changed"].as_array().unwrap().len(), 1);
    assert_eq!(
        result["changed"][0]["id"], vod,
        "existing provider identity must remain stable"
    );
    assert_eq!(result["changed"][0]["api"], url("/cms-next"));
    assert_eq!(result["added"], serde_json::json!([]));
    assert_eq!(result["failed"], serde_json::json!([]));
    assert_replacement_is_persisted(&state, vod);
    if block_save {
        assert_eq!(
            result["updateClockWarning"], "订阅内容已更新，但更新时间未保存，请稍后重试",
            "successful source changes must carry an explicit safe status-save warning"
        );
        assert_eq!(
            stamp_value(&env.dir, parent),
            observed.clock_before_block,
            "failed clock save cannot advertise a newer persisted attempt"
        );
        assert_eq!(raw_parent(&env.dir, parent)["lastUpdateAt"], 1234);
        assert!(env.dir.join("source-catalog.json.tmp").is_dir());
        env.armed.store(false, Ordering::SeqCst);
        std::fs::remove_dir(env.dir.join("source-catalog.json.tmp")).unwrap();
        let retry = crate::tvbox::update_tvbox_source(&state, parent, true, false)
            .await
            .unwrap();
        assert_eq!(
            retry["updated"], false,
            "repair/retry does not duplicate applied VOD changes"
        );
        assert_eq!(retry["changed"], serde_json::json!([]));
        assert_eq!(retry["updateClockWarning"], serde_json::Value::Null);
        let saved = raw_parent(&env.dir, parent);
        assert!(saved["lastUpdateAt"].as_i64().is_some_and(|at| at > 1234));
        assert_eq!(saved["lastUpdateOk"], true);
        assert_replacement_is_persisted(&state, vod);
        let restored = env.state().await;
        assert_replacement_is_persisted(&restored, vod);
    } else {
        assert_eq!(result["updateClockWarning"], serde_json::Value::Null);
        assert!(!env.dir.join("source-catalog.json.tmp").exists());
    }
}

#[tokio::test]
async fn tvbox_parent_clock_late_save_fault_retains_real_applied_content_and_warns() {
    exercise_clock_save_boundary(true).await;
}

#[tokio::test]
async fn tvbox_parent_clock_no_save_fault_control_keeps_the_same_real_vod_update_path() {
    exercise_clock_save_boundary(false).await;
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn tvbox_parent_clock_fresh_parent_excludes_its_stale_vod_from_legacy_scheduler() {
    let _awake = Awake::new();
    let env = Env::new("clock-fresh-parent-stale-sidecar").await;
    env.put(
        "/fresh.json",
        direct(vec![site("fresh-vod", "Fresh VOD", "/cms-fresh")], vec![]),
    );
    let state = env.state().await;
    drive_runtime().await;
    let imported = import(&state, "/fresh.json", "Fresh parent").await;
    let parent = imported["originId"].as_str().unwrap();
    let vod = imported["imported"][0]["id"].as_str().unwrap();
    let mut meta = crate::tvbox::read_tvbox_meta(&env.dir, vod).unwrap();
    meta.last_update_at = 0;
    meta.last_update_ok = false;
    crate::tvbox::write_tvbox_meta(&env.dir, vod, &meta).unwrap();
    seed_clock(&env.dir, parent, now_secs(), true, None);
    let before = stamp_value(&env.dir, parent);
    env.clear_requests();
    crate::tvbox::tvbox_update_schedule_set(&state, true, 21600).unwrap();
    tokio::time::advance(Duration::from_secs(60)).await;
    drive_runtime().await;
    assert!(
        env.observed_requests().is_empty(),
        "all URL-backed parent IDs cover their VOD, even when the parent is not due: {:?}",
        env.observed_requests()
    );
    assert_eq!(stamp_value(&env.dir, parent), before);
    assert_eq!(
        crate::tvbox::read_tvbox_meta(&env.dir, vod)
            .unwrap()
            .last_update_at,
        0
    );
}

#[tokio::test]
async fn tvbox_parent_clock_retained_configuration_probe_failure_also_marks_parent_failed() {
    let env = Env::new("clock-retained-config-failure").await;
    let configured = |revision: i64| {
        serde_json::json!({
            "sites": [{"key":"configured-protocol","name":"Configured VOD","type":3,
                "api":"csp_AppDrama","ext":{"revision":revision}}],
            "lives": [],
        })
    };
    env.put("/configured.json", configured(1));
    let state = env.state().await;
    let imported = import(&state, "/configured.json", "Configured parent").await;
    assert_eq!(imported["imported"].as_array().unwrap().len(), 1);
    assert!(
        imported["imported"][0]["probeFailed"].is_string(),
        "invalid public-protocol configuration must reach the real keep-configuration path"
    );
    let parent = imported["originId"].as_str().unwrap();
    let vod = imported["imported"][0]["id"].as_str().unwrap();
    seed_clock(&env.dir, parent, 1234, true, None);
    env.put("/configured.json", configured(2));
    let result = crate::tvbox::update_tvbox_source(&state, parent, true, false)
        .await
        .unwrap();
    assert_eq!(result["updated"], true);
    assert_eq!(result["failed"], serde_json::json!([]));
    assert_eq!(result["changed"].as_array().unwrap().len(), 1);
    assert_eq!(result["changed"][0]["id"], vod);
    assert!(
        result["changed"][0]["probeFailed"]
            .as_str()
            .is_some_and(|why| !why.is_empty()),
        "the structured row must retain the actual probe failure"
    );
    let persisted = crate::persist::load_persisted(&env.dir);
    let row = persisted.iter().find(|row| row.id() == vod).unwrap();
    match row {
        crate::model::PersistedProvider::Tvbox { ext: Some(ext), .. } => {
            let ext: serde_json::Value = serde_json::from_str(ext).unwrap();
            assert_eq!(
                ext["revision"], 2,
                "probe failure must not discard accepted configuration changes"
            );
        }
        _ => panic!("the accepted configured VOD must remain persisted"),
    }
    let saved = raw_parent(&env.dir, parent);
    assert!(saved["lastUpdateAt"].as_i64().is_some_and(|at| at > 1234));
    assert_eq!(
        saved["lastUpdateOk"], false,
        "added/changed probeFailed is an actual failure even when failed[] is empty"
    );
    assert!(saved["lastUpdateError"]
        .as_str()
        .is_some_and(|why| !why.is_empty()));
}

struct ClockQueueEnv {
    dir: std::path::PathBuf,
    proxy: String,
    hold_a: Arc<AtomicBool>,
    a_entered: Arc<AtomicBool>,
    release_a: Arc<tokio::sync::Notify>,
    requests: Arc<Mutex<Vec<String>>>,
    server: tokio::task::JoinHandle<()>,
}

impl ClockQueueEnv {
    async fn new() -> Self {
        let dir = std::env::temp_dir().join(format!(
            "sourin-clock-queue-{}-{}",
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
        let hold_a = Arc::new(AtomicBool::new(false));
        let a_entered = Arc::new(AtomicBool::new(false));
        let release_a = Arc::new(tokio::sync::Notify::new());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let route_hold = hold_a.clone();
        let route_entered = a_entered.clone();
        let route_release = release_a.clone();
        let route_requests = requests.clone();
        let app = axum::Router::new().fallback(get(move |uri: Uri| {
            let hold = route_hold.clone();
            let entered = route_entered.clone();
            let release = route_release.clone();
            let requests = route_requests.clone();
            async move {
                requests.lock().unwrap().push(uri.path().to_owned());
                let path = uri.path();
                if path == "/queue-a.json" && hold.load(Ordering::SeqCst) {
                    entered.store(true, Ordering::SeqCst);
                    release.notified().await;
                }
                let (key, name, api) = match path {
                    "/queue-a.json" => ("a", "Queue A VOD", "/cms-queue-a"),
                    "/queue-b.json" => ("b", "Queue B VOD", "/cms-queue-b"),
                    "/queue-c.json" => ("c", "Queue C VOD", "/cms-queue-c"),
                    _ => {
                        if path.starts_with("/cms-queue-") {
                            return r#"{"class":[{"type_id":"1","type_name":"Queue category"}],"list":[{"vod_id":"queue-item","vod_name":"Queue item"}],"total":1}"#.into_response();
                        }
                        return StatusCode::NOT_FOUND.into_response();
                    }
                };
                direct(vec![site(key, name, api)], vec![]).to_string().into_response()
            }
        }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self {
            dir,
            proxy,
            hold_a,
            a_entered,
            release_a,
            requests,
            server,
        }
    }

    async fn state(&self) -> Arc<AppState> {
        let state = AppState::bootstrap(self.dir.clone()).await.unwrap();
        assert!(!crate::tvbox::load_tvbox_update_schedule(&self.dir).enabled);
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
}

impl Drop for ClockQueueEnv {
    fn drop(&mut self) {
        self.release_a.notify_waiters();
        self.server.abort();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

async fn wait_queue_observation(mut ready: impl FnMut() -> bool, stage: &str) {
    let end = std::time::Instant::now() + Duration::from_secs(3);
    while !ready() {
        assert!(
            std::time::Instant::now() < end,
            "runtime qualification stalled at {stage}"
        );
        tokio::task::yield_now().await;
    }
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn tvbox_parent_clock_scheduler_rechecks_due_after_a_queued_manual_update() {
    let _awake = Awake::new();
    let env = ClockQueueEnv::new().await;
    let state = env.state().await;
    drive_runtime().await;
    let mut parents = Vec::new();
    let mut providers = Vec::new();
    for (path, name) in [
        ("/queue-a.json", "Queue A"),
        ("/queue-b.json", "Queue B"),
        ("/queue-c.json", "Queue C"),
    ] {
        let imported =
            crate::tvbox::import_tvbox_config_with_options(&state, &url(path), &[], Some(name))
                .await
                .unwrap();
        assert_eq!(imported["imported"].as_array().unwrap().len(), 1);
        parents.push(imported["originId"].as_str().unwrap().to_owned());
        providers.push(imported["imported"][0]["id"].as_str().unwrap().to_owned());
    }
    for (parent, vod) in parents.iter().zip(&providers) {
        let mut meta = crate::tvbox::read_tvbox_meta(&env.dir, vod).unwrap();
        meta.last_update_at = 0;
        meta.last_update_ok = false;
        crate::tvbox::write_tvbox_meta(&env.dir, vod, &meta).unwrap();
        seed_clock(&env.dir, parent, 0, false, None);
    }
    env.requests.lock().unwrap().clear();
    env.hold_a.store(true, Ordering::SeqCst);
    crate::tvbox::tvbox_update_schedule_set(&state, true, 21600).unwrap();
    tokio::time::advance(Duration::from_secs(60)).await;
    wait_queue_observation(
        || env.a_entered.load(Ordering::SeqCst),
        "scheduled A entering the held config request",
    )
    .await;
    let manual_started = Arc::new(AtomicBool::new(false));
    let task_started = manual_started.clone();
    let manual_state = state.clone();
    let manual_parent = parents[1].clone();
    let manual = tokio::spawn(async move {
        // The following public update is polled until its mutex acquisition
        // yields; scheduled A is still held in the actual HTTP handler.
        task_started.store(true, Ordering::SeqCst);
        crate::tvbox::update_tvbox_source(&manual_state, &manual_parent, true, false).await
    });
    wait_queue_observation(
        || manual_started.load(Ordering::SeqCst),
        "manual B queued behind A",
    )
    .await;
    assert!(
        !manual.is_finished(),
        "manual B must actually wait for A's update lock"
    );
    assert!(!env
        .requests
        .lock()
        .unwrap()
        .iter()
        .any(|path| path == "/queue-b.json"));
    env.release_a.notify_one();
    wait_queue_observation(
        || manual.is_finished(),
        "manual B completing its real request",
    )
    .await;
    let result = manual.await.unwrap().unwrap();
    assert_eq!(result["originId"], parents[1]);
    assert_eq!(
        result["updated"], false,
        "unchanged manual update still refreshes its true clock"
    );
    // C follows B in both the real imported provider order and parent order.
    // Its successful sidecar stamp proves the scheduler advanced beyond B.
    wait_queue_observation(
        || {
            crate::tvbox::read_tvbox_meta(&env.dir, &providers[2])
                .is_some_and(|meta| meta.last_update_at > 0)
        },
        "scheduled trailing C after the B slot",
    )
    .await;
    drive_runtime().await;
    let requests = env.requests.lock().unwrap().clone();
    assert_eq!(
        requests
            .iter()
            .filter(|path| *path == "/queue-a.json")
            .count(),
        1
    );
    assert_eq!(
        requests
            .iter()
            .filter(|path| *path == "/queue-c.json")
            .count(),
        1
    );
    assert_eq!(requests.iter().filter(|path| *path == "/queue-b.json").count(), 1,
        "a sampled overdue B must be rechecked under UPDATE_LOCK after the real manual B update: {requests:?}");
    let saved_b = raw_parent(&env.dir, &parents[1]);
    assert!(saved_b["lastUpdateAt"].as_i64().is_some_and(|at| at > 0));
    assert_eq!(saved_b["lastUpdateOk"], true);
    let b_meta = crate::tvbox::read_tvbox_meta(&env.dir, &providers[1]).unwrap();
    assert!(b_meta.last_update_at > 0 && b_meta.last_update_ok);
}

#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn tvbox_parent_clock_disabling_schedule_retires_waiting_targets_without_canceling_started_a()
{
    let _awake = Awake::new();
    let env = ClockQueueEnv::new().await;
    let state = env.state().await;
    drive_runtime().await;
    let mut parents = Vec::new();
    let mut providers = Vec::new();
    for (path, name) in [
        ("/queue-a.json", "Queue A"),
        ("/queue-b.json", "Queue B"),
        ("/queue-c.json", "Queue C"),
    ] {
        let imported =
            crate::tvbox::import_tvbox_config_with_options(&state, &url(path), &[], Some(name))
                .await
                .unwrap();
        parents.push(imported["originId"].as_str().unwrap().to_owned());
        providers.push(imported["imported"][0]["id"].as_str().unwrap().to_owned());
    }
    for (parent, vod) in parents.iter().zip(&providers) {
        let mut meta = crate::tvbox::read_tvbox_meta(&env.dir, vod).unwrap();
        meta.last_update_at = 0;
        meta.last_update_ok = false;
        crate::tvbox::write_tvbox_meta(&env.dir, vod, &meta).unwrap();
        seed_clock(&env.dir, parent, 0, false, None);
    }
    env.requests.lock().unwrap().clear();
    env.hold_a.store(true, Ordering::SeqCst);
    crate::tvbox::tvbox_update_schedule_set(&state, true, 21600).unwrap();
    tokio::time::advance(Duration::from_secs(60)).await;
    wait_queue_observation(
        || env.a_entered.load(Ordering::SeqCst),
        "started A before schedule is disabled",
    )
    .await;
    crate::tvbox::tvbox_update_schedule_set(&state, false, 21600).unwrap();
    env.release_a.notify_one();
    wait_queue_observation(
        || {
            crate::tvbox::read_tvbox_meta(&env.dir, &providers[0])
                .is_some_and(|meta| meta.last_update_at > 0)
        },
        "already-started A finishing after disable",
    )
    .await;
    drive_runtime().await;
    let requests = env.requests.lock().unwrap().clone();
    assert_eq!(
        requests
            .iter()
            .filter(|path| *path == "/queue-a.json")
            .count(),
        1,
        "schedule changes do not cancel a real request which has already started"
    );
    assert!(
        !requests
            .iter()
            .any(|path| path == "/queue-b.json" || path == "/queue-c.json"),
        "a disabled schedule must retire sampled targets which have not started: {requests:?}"
    );
    for (parent, vod) in parents.iter().zip(&providers).skip(1) {
        assert_eq!(raw_parent(&env.dir, parent)["lastUpdateAt"], 0);
        assert_eq!(
            crate::tvbox::read_tvbox_meta(&env.dir, vod)
                .unwrap()
                .last_update_at,
            0
        );
    }
    env.requests.lock().unwrap().clear();
    tokio::time::advance(Duration::from_secs(60)).await;
    drive_runtime().await;
    assert!(env.requests.lock().unwrap().is_empty());
}
