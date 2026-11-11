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

fn imported_parent(imported: &serde_json::Value) -> String {
    imported["originId"]
        .as_str()
        .expect("import must identify its saved parent")
        .to_owned()
}

fn imported_live(imported: &serde_json::Value) -> String {
    assert_eq!(imported["liveImported"].as_array().unwrap().len(), 1);
    imported["liveImported"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn parent(state: &AppState, id: &str) -> SourceOrigin {
    catalog(state)
        .unwrap()
        .origins
        .into_iter()
        .find(|origin| origin.id == id)
        .expect("the exact saved TVBox parent must exist")
}

fn owner(state: &AppState, live_id: &str) -> SourceOrigin {
    catalog(state)
        .unwrap()
        .origins
        .into_iter()
        .find(|origin| origin.kind == "live" && origin.provider_ids.iter().any(|id| id == live_id))
        .expect("the imported live must have its own address owner")
}

fn addresses(origin: &SourceOrigin) -> (String, String, Vec<String>) {
    (
        origin.name.clone(),
        origin.primary_url.clone(),
        origin.backup_urls.clone(),
    )
}

fn registered_ids(state: &AppState) -> HashSet<String> {
    state
        .registry
        .manifests()
        .into_iter()
        .map(|manifest| manifest.id)
        .collect()
}

fn disk_rows(state: &AppState) -> serde_json::Value {
    serde_json::to_value(crate::persist::load_persisted(&state.data_dir)).unwrap()
}

fn disk_has(state: &AppState, wanted: &str) -> bool {
    crate::persist::load_persisted(&state.data_dir)
        .iter()
        .any(|row| row.id() == wanted)
}

fn live_id(path: &str) -> String {
    let provider = crate::providers::m3u_live::M3uLiveProvider::new("Fixture", &url(path));
    crate::provider::MediaProvider::manifest(&provider)
        .id
        .clone()
}

fn row_ids(rows: &serde_json::Value) -> HashSet<String> {
    rows.as_array()
        .unwrap()
        .iter()
        .map(|row| row["id"].as_str().unwrap().to_owned())
        .collect()
}

fn only_item(check: &serde_json::Value, origin_id: &str) -> serde_json::Value {
    assert_eq!(check["checked"], 1);
    let items = check["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(
        items[0]["originId"], origin_id,
        "check must identify the exact origin independently of VOD ids"
    );
    assert!(
        !items[0]["ids"]
            .as_array()
            .unwrap()
            .iter()
            .any(|id| id == origin_id),
        "an origin id must not masquerade as a provider id"
    );
    items[0].clone()
}

fn disabled(state: &AppState, id: &str) -> bool {
    !state
        .registry
        .enabled_manifests()
        .iter()
        .any(|manifest| manifest.id == id)
        && crate::commands::load_disabled(&state.data_dir)
            .iter()
            .any(|saved| saved == id)
}

#[tokio::test]
async fn tvbox_origin_live_only_check_update_preserves_owner_and_restores() {
    let env = Env::new("pure-live").await;
    env.put(
        "/pure.json",
        direct(vec![], vec![live("Old live", "/old.m3u")]),
    );
    let state = env.state().await;
    let imported = import(&state, "/pure.json", "Pure live parent").await;
    assert!(imported["imported"].as_array().unwrap().is_empty());
    let origin_id = imported_parent(&imported);
    let old = imported_live(&imported);
    assert!(parent(&state, &origin_id).provider_ids.is_empty());
    let live_owner = owner(&state, &old);
    command_set_origin(
        &state,
        &serde_json::json!({
            "id":live_owner.id,"name":"User live address",
            "primaryUrl":url("/old-down.m3u"),"backupUrls":[url("/old-backup.m3u")]
        }),
    )
    .unwrap();
    assert_eq!(
        state
            .registry
            .get(&old)
            .unwrap()
            .live_channels()
            .await
            .unwrap()
            .len(),
        1,
        "the user's independent live address must work in the loopback fixture"
    );
    crate::commands_provider::set_enabled_persisted(&state, &old, false).unwrap();
    command_set_origin(
        &state,
        &serde_json::json!({
            "id":origin_id,"name":"Renamed pure live parent",
            "backupUrls":[url("/pure-backup.json")]
        }),
    )
    .unwrap();
    let saved_live_owner = owner(&state, &old);
    let saved_addresses = addresses(&parent(&state, &origin_id));
    let before_ids = registered_ids(&state);
    let before_rows = disk_rows(&state);
    let new = live_id("/new.m3u");
    env.put("/pure.json", live_only(vec![live("New live", "/new.m3u")]));
    env.put(
        "/pure-backup.json",
        live_only(vec![live("New live", "/new.m3u")]),
    );
    env.clear_requests();

    let check = crate::tvbox::check_tvbox_updates(&state, Some(&origin_id))
        .await
        .expect("a URL-backed pure-live origin must have a manual check route");
    let item = only_item(&check, &origin_id);
    assert_eq!(item["ok"], true);
    assert_eq!(item["ids"], serde_json::json!([]));
    assert_eq!(item["remoteTotalSites"], 0);
    assert_eq!(item["liveHasChanges"], true);
    assert_eq!(row_ids(&item["liveAdded"]), HashSet::from([new.clone()]));
    assert_eq!(
        registered_ids(&state),
        before_ids,
        "preview must not register the new live"
    );
    assert_eq!(
        disk_rows(&state),
        before_rows,
        "preview must not apply provider rows"
    );
    assert_eq!(
        parent(&state, &origin_id).related_provider_ids,
        vec![old.clone()]
    );
    assert_eq!(owner(&state, &old), saved_live_owner);
    assert!(disabled(&state, &old));
    assert_eq!(env.observed_requests(), vec![url("/pure.json")]);

    let updated = crate::tvbox::update_tvbox_source(&state, &origin_id, true, false)
        .await
        .expect("a zero-VOD origin must use the existing update pipeline");
    assert_eq!(updated["originId"], origin_id);
    assert_eq!(updated["updated"], true);
    assert_eq!(row_ids(&updated["liveAdded"]), HashSet::from([new.clone()]));
    assert_eq!(
        row_ids(&updated["liveRemoved"]),
        HashSet::from([old.clone()])
    );
    assert_eq!(updated["liveDeleted"], serde_json::json!([]));
    assert!(state.registry.get(&new).is_some() && disk_has(&state, &new));
    assert!(state.registry.get(&old).is_some() && disk_has(&state, &old));
    assert_eq!(
        parent(&state, &origin_id).related_provider_ids,
        vec![new.clone()]
    );
    assert_eq!(addresses(&parent(&state, &origin_id)), saved_addresses);
    assert_eq!(owner(&state, &old), saved_live_owner);
    assert!(disabled(&state, &old));
    drop(state);

    let restored = env.state().await;
    assert!(restored.registry.get(&new).is_some());
    assert_eq!(
        parent(&restored, &origin_id).related_provider_ids,
        vec![new]
    );
    assert_eq!(addresses(&parent(&restored, &origin_id)), saved_addresses);
    assert_eq!(owner(&restored, &old), saved_live_owner);
    assert!(disabled(&restored, &old));
}

#[tokio::test]
async fn tvbox_origin_apply_new_false_does_not_adopt_live_or_first_vod() {
    let env = Env::new("apply-new-false").await;
    env.put("/a.json", direct(vec![], vec![live("Old A", "/a.m3u")]));
    env.put("/b.json", direct(vec![], vec![live("Foreign B", "/b.m3u")]));
    let state = env.state().await;
    let a = import(&state, "/a.json", "Parent A").await;
    let b = import(&state, "/b.json", "Parent B").await;
    let a_parent = imported_parent(&a);
    let b_parent = imported_parent(&b);
    let old = imported_live(&a);
    let foreign = imported_live(&b);
    crate::commands_provider::set_enabled_persisted(&state, &old, false).unwrap();
    crate::commands_provider::set_enabled_persisted(&state, &foreign, false).unwrap();
    let mut aggregate = crate::tvbox_aggregate::load(&env.dir);
    aggregate.site_selection_explicit = true;
    aggregate.enabled_site_ids.clear();
    aggregate.note = "Saved empty VOD selection".into();
    crate::tvbox_aggregate::save(&env.dir, &aggregate).unwrap();
    sync_enabled(&state.registry, &env.dir);
    let before_ids = registered_ids(&state);
    let before_rows = disk_rows(&state);
    let saved_b = parent(&state, &b_parent);
    let saved_foreign_owner = owner(&state, &foreign);
    let new = live_id("/new.m3u");
    env.put(
        "/a.json",
        direct(
            vec![site("late-vod", "Late VOD", "/cms-late")],
            vec![
                live("Old A", "/a.m3u"),
                live("Foreign B", "/b.m3u"),
                live("New", "/new.m3u"),
            ],
        ),
    );

    let check = crate::tvbox::check_tvbox_updates(&state, Some(&a_parent))
        .await
        .expect("pure-live parent must be checkable before it adds VOD");
    let item = only_item(&check, &a_parent);
    assert_eq!(item["ok"], true);
    assert_eq!(item["added"].as_array().unwrap().len(), 1);
    assert_eq!(
        row_ids(&item["liveAdded"]),
        HashSet::from([foreign.clone(), new.clone()])
    );
    assert_eq!(registered_ids(&state), before_ids);
    assert_eq!(disk_rows(&state), before_rows);
    let updated = crate::tvbox::update_tvbox_source(&state, &a_parent, false, false)
        .await
        .expect("applyNew=false is a valid origin update");
    assert_eq!(updated["originId"], a_parent);
    assert_eq!(updated["updated"], false);
    assert_eq!(updated["notApplied"].as_array().unwrap().len(), 1);
    assert_eq!(
        row_ids(&updated["liveNotApplied"]),
        HashSet::from([foreign.clone(), new.clone()])
    );
    assert_eq!(registered_ids(&state), before_ids);
    assert_eq!(disk_rows(&state), before_rows);
    assert_eq!(
        parent(&state, &a_parent).related_provider_ids,
        vec![old.clone()]
    );
    assert!(parent(&state, &a_parent).provider_ids.is_empty());
    assert_eq!(parent(&state, &b_parent), saved_b);
    assert_eq!(owner(&state, &foreign), saved_foreign_owner);
    assert!(disabled(&state, &old) && disabled(&state, &foreign));
    assert!(state.registry.get(&new).is_none() && !disk_has(&state, &new));
    assert_eq!(crate::tvbox_aggregate::load(&env.dir), aggregate);
    drop(state);

    let restored = env.state().await;
    assert_eq!(registered_ids(&restored), before_ids);
    assert!(parent(&restored, &a_parent).provider_ids.is_empty());
    assert_eq!(
        parent(&restored, &a_parent).related_provider_ids,
        vec![old.clone()]
    );
    assert_eq!(parent(&restored, &b_parent), saved_b);
    assert_eq!(owner(&restored, &foreign), saved_foreign_owner);
    assert!(disabled(&restored, &old) && disabled(&restored, &foreign));
    assert_eq!(crate::tvbox_aggregate::load(&env.dir), aggregate);
}

#[tokio::test]
async fn tvbox_origin_same_url_uses_exact_parent_backups_and_success_stamp() {
    let env = Env::new("same-url-backups").await;
    env.put(
        "/alpha.json",
        direct(vec![], vec![live("Alpha", "/alpha.m3u")]),
    );
    env.put(
        "/beta.json",
        direct(vec![], vec![live("Beta", "/beta.m3u")]),
    );
    env.put(
        "/alpha-backup.json",
        direct(vec![], vec![live("Alpha new", "/alpha-new.m3u")]),
    );
    env.put(
        "/beta-backup.json",
        direct(vec![], vec![live("Beta new", "/beta-new.m3u")]),
    );
    let state = env.state().await;
    let alpha = import(&state, "/alpha.json", "Alpha parent").await;
    let beta = import(&state, "/beta.json", "Beta parent").await;
    let a = imported_parent(&alpha);
    let b = imported_parent(&beta);
    assert_ne!(a, b);
    for (id, backup) in [(&a, "/alpha-backup.json"), (&b, "/beta-backup.json")] {
        command_set_origin(
            &state,
            &serde_json::json!({
                "id":id,"primaryUrl":url("/shared-down.json"),"backupUrls":[url(backup)]
            }),
        )
        .unwrap();
    }
    let saved_a = parent(&state, &a);
    let saved_b_addresses = addresses(&parent(&state, &b));
    assert_eq!(saved_a.primary_url, parent(&state, &b).primary_url);
    assert!(saved_a.provider_ids.is_empty() && parent(&state, &b).provider_ids.is_empty());
    let old_b = imported_live(&beta);
    let new_b = live_id("/beta-new.m3u");
    env.clear_requests();

    let check = crate::tvbox::check_tvbox_updates(&state, Some(&b))
        .await
        .expect("an exact origin id must isolate two same-URL parents");
    let item = only_item(&check, &b);
    assert_eq!(item["ok"], true);
    assert_eq!(row_ids(&item["liveAdded"]), HashSet::from([new_b.clone()]));
    assert_eq!(
        env.observed_requests(),
        vec![url("/shared-down.json"), url("/beta-backup.json")]
    );
    assert_eq!(
        parent(&state, &a),
        saved_a,
        "preview B must not stamp same-URL A"
    );
    assert_eq!(
        parent(&state, &b).last_successful_url,
        Some(url("/beta-backup.json"))
    );
    assert_eq!(parent(&state, &b).related_provider_ids, vec![old_b]);
    env.clear_requests();

    let updated = crate::tvbox::update_tvbox_source(&state, &b, true, false)
        .await
        .expect("same-URL parent B must apply its own endpoint result");
    assert_eq!(updated["originId"], b);
    assert_eq!(updated["updated"], true);
    let observed = env.observed_requests();
    assert!(observed.contains(&url("/beta-backup.json")));
    assert!(!observed.contains(&url("/alpha-backup.json")));
    assert_eq!(
        parent(&state, &a),
        saved_a,
        "update B must not alter same-URL A"
    );
    assert_eq!(parent(&state, &b).related_provider_ids, vec![new_b.clone()]);
    assert_eq!(addresses(&parent(&state, &b)), saved_b_addresses);
    drop(state);

    let restored = env.state().await;
    assert_eq!(parent(&restored, &a), saved_a);
    assert_eq!(parent(&restored, &b).related_provider_ids, vec![new_b]);
    assert_eq!(addresses(&parent(&restored, &b)), saved_b_addresses);
}

#[tokio::test]
async fn tvbox_origin_same_url_first_vod_binds_to_requested_parent() {
    let env = Env::new("same-url-first-vod").await;
    env.put(
        "/alpha.json",
        direct(vec![], vec![live("Alpha", "/alpha.m3u")]),
    );
    env.put(
        "/beta.json",
        direct(vec![], vec![live("Beta", "/beta.m3u")]),
    );
    let state = env.state().await;
    let alpha = import(&state, "/alpha.json", "Alpha parent").await;
    let beta = import(&state, "/beta.json", "Beta parent").await;
    let a = imported_parent(&alpha);
    let b = imported_parent(&beta);
    for (id, backup) in [(&a, "/alpha.json"), (&b, "/beta.json")] {
        command_set_origin(
            &state,
            &serde_json::json!({
                "id":id,"primaryUrl":url("/shared.json"),"backupUrls":[url(backup)]
            }),
        )
        .unwrap();
    }
    let order: Vec<_> = catalog(&state)
        .unwrap()
        .origins
        .into_iter()
        .filter(|origin| origin.kind == "tvbox")
        .map(|origin| origin.id)
        .collect();
    assert!(
        order.iter().position(|id| id == &a).unwrap()
            < order.iter().position(|id| id == &b).unwrap(),
        "A must precede B so URL-first inference would select the wrong parent"
    );
    let saved_a = parent(&state, &a);
    let saved_b_addresses = addresses(&parent(&state, &b));
    env.put(
        "/shared.json",
        direct(
            vec![site("late-b", "Late B VOD", "/cms-late-b")],
            vec![live("Beta", "/beta.m3u")],
        ),
    );

    let updated = crate::tvbox::update_tvbox_source(&state, &b, true, false)
        .await
        .expect("an empty exact origin must acquire newly created VOD without reimport");
    assert_eq!(updated["originId"], b);
    assert_eq!(updated["updated"], true);
    assert_eq!(updated["added"].as_array().unwrap().len(), 1);
    let vod = updated["added"][0]["id"].as_str().unwrap().to_owned();
    assert!(state.registry.get(&vod).is_some() && disk_has(&state, &vod));
    assert_eq!(parent(&state, &b).provider_ids, vec![vod.clone()]);
    assert_eq!(
        parent(&state, &a),
        saved_a,
        "new B VOD must not attach or stamp first same-URL A"
    );
    assert_eq!(addresses(&parent(&state, &b)), saved_b_addresses);
    assert_eq!(
        crate::tvbox::read_tvbox_meta(&env.dir, &vod)
            .unwrap()
            .source_url,
        Some(url("/shared.json"))
    );

    let check = crate::tvbox::check_tvbox_updates(&state, Some(&vod))
        .await
        .expect("the newly added provider ID must resolve the same precise B origin");
    let item = only_item(&check, &b);
    assert_eq!(item["ok"], true);
    assert_eq!(item["ids"], serde_json::json!([vod]));
    assert_eq!(item["unchanged"], 1);
    let again = crate::tvbox::update_tvbox_source(&state, &vod, true, false)
        .await
        .unwrap();
    assert_eq!(again["originId"], b);
    assert_eq!(again["updated"], false);
    assert_eq!(parent(&state, &a), saved_a);
    drop(state);

    let restored = env.state().await;
    assert_eq!(parent(&restored, &b).provider_ids, vec![vod]);
    assert_eq!(addresses(&parent(&restored, &b)), saved_b_addresses);
    assert_eq!(parent(&restored, &a), saved_a);
}

#[tokio::test]
async fn tvbox_origin_after_final_vod_delete_can_add_vod_preserving_explicit_all_off() {
    let env = Env::new("last-vod").await;
    env.put(
        "/mixed.json",
        direct(
            vec![site("old-vod", "Old VOD", "/cms-old")],
            vec![live("Old live", "/old.m3u")],
        ),
    );
    let state = env.state().await;
    let imported = import(&state, "/mixed.json", "Original mixed parent").await;
    assert_eq!(imported["imported"].as_array().unwrap().len(), 1);
    let old_vod = imported["imported"][0]["id"].as_str().unwrap().to_owned();
    let old_live = imported_live(&imported);
    let origin_id = imported_parent(&imported);
    command_set_origin(
        &state,
        &serde_json::json!({
            "id":origin_id,"name":"User parent name",
            "primaryUrl":url("/mixed-down.json"),"backupUrls":[url("/mixed.json")]
        }),
    )
    .unwrap();
    let mut aggregate = crate::tvbox_aggregate::load(&env.dir);
    aggregate.site_selection_explicit = true;
    aggregate.enabled_site_ids.clear();
    aggregate.note = "User all-off selection".into();
    crate::tvbox_aggregate::save(&env.dir, &aggregate).unwrap();
    crate::commands_provider::set_enabled_persisted(&state, &old_vod, false).unwrap();
    crate::commands_provider::set_enabled_persisted(&state, &old_live, false).unwrap();
    sync_enabled(&state.registry, &env.dir);
    assert!(disabled(&state, &old_vod) && disabled(&state, &old_live));
    let saved_addresses = addresses(&parent(&state, &origin_id));
    let saved_live_owner = owner(&state, &old_live);
    env.put(
        "/mixed.json",
        direct(vec![], vec![live("Old live", "/old.m3u")]),
    );

    let deleted = crate::tvbox::update_tvbox_source(&state, &old_vod, true, true)
        .await
        .expect("fixture must actually delete its final VOD through the production update");
    assert_eq!(
        row_ids(&deleted["deleted"]),
        HashSet::from([old_vod.clone()])
    );
    assert!(state.registry.get(&old_vod).is_none() && !disk_has(&state, &old_vod));
    assert!(parent(&state, &origin_id).provider_ids.is_empty());
    assert_eq!(
        parent(&state, &origin_id).related_provider_ids,
        vec![old_live.clone()]
    );
    assert_eq!(addresses(&parent(&state, &origin_id)), saved_addresses);
    drop(state);

    let state = env.state().await;
    assert!(parent(&state, &origin_id).provider_ids.is_empty());
    assert_eq!(addresses(&parent(&state, &origin_id)), saved_addresses);
    let check = crate::tvbox::check_tvbox_updates(&state, Some(&origin_id))
        .await
        .expect("after restart a surviving zero-VOD parent must have a manual check route");
    let item = only_item(&check, &origin_id);
    assert_eq!(item["ok"], true);
    assert_eq!(item["ids"], serde_json::json!([]));
    env.put(
        "/mixed.json",
        direct(
            vec![site("new-vod", "New VOD", "/cms-new")],
            vec![live("Old live", "/old.m3u")],
        ),
    );
    let before_ids = registered_ids(&state);
    let skipped = crate::tvbox::update_tvbox_source(&state, &origin_id, false, false)
        .await
        .unwrap();
    assert_eq!(skipped["originId"], origin_id);
    assert_eq!(skipped["updated"], false);
    assert_eq!(skipped["notApplied"].as_array().unwrap().len(), 1);
    assert_eq!(registered_ids(&state), before_ids);
    assert!(parent(&state, &origin_id).provider_ids.is_empty());

    let added = crate::tvbox::update_tvbox_source(&state, &origin_id, true, false)
        .await
        .expect("the surviving parent must reuse the existing VOD pipeline for a new VOD");
    assert_eq!(added["originId"], origin_id);
    assert_eq!(added["added"].as_array().unwrap().len(), 1);
    let new_vod = added["added"][0]["id"].as_str().unwrap().to_owned();
    assert!(state.registry.get(&new_vod).is_some() && disk_has(&state, &new_vod));
    assert_eq!(
        parent(&state, &origin_id).provider_ids,
        vec![new_vod.clone()]
    );
    assert_eq!(addresses(&parent(&state, &origin_id)), saved_addresses);
    assert_eq!(owner(&state, &old_live), saved_live_owner);
    assert!(disabled(&state, &old_live));
    assert!(
        !state
            .registry
            .enabled_manifests()
            .iter()
            .any(|manifest| manifest.id == new_vod),
        "a newly added VOD must respect the user's saved explicit empty VOD selection"
    );
    assert_eq!(crate::tvbox_aggregate::load(&env.dir), aggregate);
    let by_vod = crate::tvbox::check_tvbox_updates(&state, Some(&new_vod))
        .await
        .unwrap();
    assert_eq!(only_item(&by_vod, &origin_id)["unchanged"], 1);
    drop(state);

    let restored = env.state().await;
    assert_eq!(
        parent(&restored, &origin_id).provider_ids,
        vec![new_vod.clone()]
    );
    assert_eq!(addresses(&parent(&restored, &origin_id)), saved_addresses);
    assert_eq!(owner(&restored, &old_live), saved_live_owner);
    assert!(disabled(&restored, &old_live));
    assert!(restored.registry.get(&new_vod).is_some());
    assert!(!restored
        .registry
        .enabled_manifests()
        .iter()
        .any(|manifest| manifest.id == new_vod));
    assert_eq!(crate::tvbox_aggregate::load(&env.dir), aggregate);
}

#[tokio::test]
async fn tvbox_origin_legacy_provider_accepts_lives_only_and_still_rejects_multi_repo_apply() {
    let env = Env::new("legacy-shapes").await;
    env.put(
        "/mixed.json",
        direct(
            vec![site("vod", "VOD", "/cms-vod")],
            vec![live("Old", "/old.m3u")],
        ),
    );
    let state = env.state().await;
    let imported = import(&state, "/mixed.json", "Legacy provider parent").await;
    let vod = imported["imported"][0]["id"].as_str().unwrap().to_owned();
    let origin_id = imported_parent(&imported);
    assert!(state.registry.get(&vod).is_some());
    env.put("/mixed.json", live_only(vec![live("New", "/new.m3u")]));

    let check = crate::tvbox::check_tvbox_updates(&state, Some(&vod))
        .await
        .unwrap();
    let item = only_item(&check, &origin_id);
    assert_eq!(
        item["ok"], true,
        "a missing sites section with real lives is a direct config"
    );
    assert_eq!(item["ids"], serde_json::json!([vod]));
    assert_eq!(item["removed"].as_array().unwrap().len(), 1);
    let updated = crate::tvbox::update_tvbox_source(&state, &vod, true, false)
        .await
        .expect("the legacy provider route must also accept live-only remote configs");
    assert_eq!(updated["originId"], origin_id);
    assert_eq!(updated["updated"], true);
    assert_eq!(updated["deleted"], serde_json::json!([]));
    assert!(
        state.registry.get(&vod).is_some(),
        "deleteMissing=false must keep the VOD"
    );
    let before_ids = registered_ids(&state);
    let before_rows = disk_rows(&state);
    let before_related = parent(&state, &origin_id).related_provider_ids;
    env.put(
        "/mixed.json",
        serde_json::json!({
            "urls":[{"name":"Child repository","url":url("/child.json")}]
        }),
    );
    let check = crate::tvbox::check_tvbox_updates(&state, Some(&vod))
        .await
        .unwrap();
    let item = only_item(&check, &origin_id);
    assert_eq!(item["ok"], false);
    assert_eq!(item["multiRepo"], true);
    assert_eq!(item["repos"].as_array().unwrap().len(), 1);
    let error = crate::tvbox::update_tvbox_source(&state, &vod, true, true)
        .await
        .expect_err("URLs-only multi-repository configs must not apply as an empty direct config");
    assert!(
        error.contains("多仓"),
        "multi-repository rejection must remain explicit: {error}"
    );
    assert_eq!(registered_ids(&state), before_ids);
    assert_eq!(disk_rows(&state), before_rows);
    assert_eq!(
        parent(&state, &origin_id).related_provider_ids,
        before_related
    );
}

#[tokio::test]
async fn tvbox_origin_unknown_or_non_tvbox_target_rejects_before_request() {
    let env = Env::new("invalid-targets").await;
    env.put(
        "/target.json",
        direct(vec![], vec![live("Fixture live", "/old.m3u")]),
    );
    let state = env.state().await;
    let imported = import(&state, "/target.json", "Fixture parent").await;
    let origin_id = imported_parent(&imported);
    let old = imported_live(&imported);
    let live_owner = owner(&state, &old);
    assert_eq!(parent(&state, &origin_id).kind, "tvbox");
    assert_eq!(live_owner.kind, "live");
    let before_ids = registered_ids(&state);
    let before_rows = disk_rows(&state);
    env.clear_requests();
    for target in [
        "tvbox-origin-does-not-exist".to_owned(),
        live_owner.id,
        url("/target.json"),
    ] {
        crate::tvbox::check_tvbox_updates(&state, Some(&target))
            .await
            .expect_err("an explicit target must be an exact known TVBox origin or VOD ID");
        crate::tvbox::update_tvbox_source(&state, &target, true, false)
            .await
            .expect_err("an invalid target must not fall back to URL lookup");
    }
    assert!(
        env.observed_requests().is_empty(),
        "invalid identity must reject before HTTP"
    );
    assert_eq!(registered_ids(&state), before_ids);
    assert_eq!(disk_rows(&state), before_rows);
}

#[tokio::test]
async fn tvbox_origin_extra_malformed_live_sections_do_not_detach_or_apply() {
    let env = Env::new("malformed-shapes").await;
    env.put(
        "/shape.json",
        direct(
            vec![site("vod", "VOD", "/cms-vod")],
            vec![live("Existing live", "/existing.m3u")],
        ),
    );
    let state = env.state().await;
    let imported = import(&state, "/shape.json", "Shape parent").await;
    let vod = imported["imported"][0]["id"].as_str().unwrap().to_owned();
    let parent_id = imported_parent(&imported);
    let before_ids = registered_ids(&state);
    let before_rows = disk_rows(&state);
    let before_members = parent(&state, &parent_id).related_provider_ids;
    for config in [
        serde_json::json!({"sites":[],"lives":{}}),
        serde_json::json!({"sites":{},"lives":[]}),
        serde_json::json!({"sites":{},"urls":[]}),
        serde_json::json!({"urls":[],"lives":{}}),
        serde_json::json!({}),
    ] {
        env.put("/shape.json", config);
        let checked = crate::tvbox::check_tvbox_updates(&state, Some(&vod))
            .await
            .unwrap();
        assert_eq!(checked["checked"], 1);
        assert_eq!(
            checked["items"][0]["ok"], false,
            "a malformed present section cannot become an empty success"
        );
        assert!(crate::tvbox::update_tvbox_source(&state, &vod, true, true)
            .await
            .is_err());
        assert_eq!(registered_ids(&state), before_ids);
        assert_eq!(disk_rows(&state), before_rows);
        assert_eq!(
            parent(&state, &parent_id).related_provider_ids,
            before_members
        );
    }
}

#[tokio::test]
async fn tvbox_origin_extra_check_all_enumerates_exact_pure_live_parents() {
    let env = Env::new("check-all").await;
    env.put(
        "/alpha.json",
        direct(vec![], vec![live("Alpha", "/alpha.m3u")]),
    );
    env.put(
        "/beta.json",
        direct(vec![], vec![live("Beta", "/beta.m3u")]),
    );
    let state = env.state().await;
    let alpha = import(&state, "/alpha.json", "Alpha parent").await;
    let beta = import(&state, "/beta.json", "Beta parent").await;
    let a = imported_parent(&alpha);
    let b = imported_parent(&beta);
    for (id, backup) in [(&a, "/alpha.json"), (&b, "/beta.json")] {
        command_set_origin(
            &state,
            &serde_json::json!({
                "id":id,"primaryUrl":url("/shared-down.json"),"backupUrls":[url(backup)]
            }),
        )
        .unwrap();
    }
    env.clear_requests();
    let before_ids = registered_ids(&state);
    let before_rows = disk_rows(&state);
    let checked = crate::tvbox::check_tvbox_updates(&state, None)
        .await
        .unwrap();
    assert_eq!(
        checked["checked"], 2,
        "pure-live origins must each be checked once"
    );
    let items = checked["items"].as_array().unwrap();
    let actual: HashSet<String> = items
        .iter()
        .map(|item| {
            assert_eq!(item["ok"], true);
            assert_eq!(item["ids"], serde_json::json!([]));
            item["originId"].as_str().unwrap().to_owned()
        })
        .collect();
    assert_eq!(actual, HashSet::from([a, b]));
    let requests = env.observed_requests();
    assert_eq!(
        requests
            .iter()
            .filter(|u| **u == url("/shared-down.json"))
            .count(),
        2
    );
    assert_eq!(
        requests
            .iter()
            .filter(|u| **u == url("/alpha.json"))
            .count(),
        1
    );
    assert_eq!(
        requests.iter().filter(|u| **u == url("/beta.json")).count(),
        1
    );
    assert_eq!(registered_ids(&state), before_ids);
    assert_eq!(disk_rows(&state), before_rows);
}

#[tokio::test]
async fn tvbox_origin_unowned_sidecar_never_borrows_another_parent_backup_or_stamp() {
    let env = Env::new("unowned-sidecar").await;
    env.put(
        "/owned.json",
        direct(
            vec![site("owned", "Owned VOD", "/cms-owned")],
            vec![live("Owned live", "/owned.m3u")],
        ),
    );
    let state = env.state().await;
    let imported = import(&state, "/owned.json", "Owned parent").await;
    let origin_id = imported_parent(&imported);
    let owned_vod = imported["imported"][0]["id"].as_str().unwrap().to_owned();
    command_set_origin(
        &state,
        &serde_json::json!({
            "id":origin_id,"primaryUrl":url("/shared-down.json"),"backupUrls":[url("/owned.json")]
        }),
    )
    .unwrap();
    let legacy_id = "unrestored-legacy";
    state
        .third_party
        .write()
        .unwrap()
        .push(crate::model::PersistedProvider::Tvbox {
            id: legacy_id.into(),
            name: "Legacy row".into(),
            api: url("/cms-legacy"),
            categories: vec![],
            parsers: vec![],
            ext: None,
        });
    crate::commands_provider::persist_from_registry(&state).unwrap();
    crate::tvbox::write_tvbox_meta(
        &env.dir,
        legacy_id,
        &crate::tvbox::TvboxSourceMeta {
            source_url: Some(url("/shared-down.json")),
            site_key: "legacy".into(),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(
        state.registry.get(legacy_id).is_none(),
        "legacy fixture must remain unowned after failed restoration"
    );
    let before_parent = parent(&state, &origin_id);
    assert!(!before_parent.provider_ids.iter().any(|id| id == legacy_id));
    let before_meta =
        serde_json::to_value(crate::tvbox::read_tvbox_meta(&env.dir, &owned_vod).unwrap()).unwrap();
    let before_rows = disk_rows(&state);
    env.clear_requests();
    let checked = crate::tvbox::check_tvbox_updates(&state, Some(legacy_id))
        .await
        .unwrap();
    assert_eq!(
        checked["items"][0]["ok"], false,
        "an unowned row has no right to borrow another parent's backup"
    );
    assert_eq!(checked["items"][0]["ids"], serde_json::json!([legacy_id]));
    assert_eq!(env.observed_requests(), vec![url("/shared-down.json")]);
    assert_eq!(parent(&state, &origin_id), before_parent);
    env.clear_requests();
    assert!(
        crate::tvbox::update_tvbox_source(&state, legacy_id, true, false)
            .await
            .is_err()
    );
    assert_eq!(env.observed_requests(), vec![url("/shared-down.json")]);
    assert_eq!(parent(&state, &origin_id), before_parent);
    assert_eq!(
        serde_json::to_value(crate::tvbox::read_tvbox_meta(&env.dir, &owned_vod).unwrap()).unwrap(),
        before_meta,
        "the unowned row's failed update must not stamp an owned same-URL VOD"
    );
    assert_eq!(disk_rows(&state), before_rows);
}

#[tokio::test]
async fn tvbox_origin_url_less_local_owner_keeps_later_sidecar_refresh() {
    let env = Env::new("local-sidecar").await;
    let config = direct(vec![site("vod", "Local VOD", "/cms-local")], vec![]);
    env.put("/local.json", config.clone());
    let state = env.state().await;
    let imported = crate::tvbox::import_tvbox_config(&state, &config.to_string())
        .await
        .unwrap();
    let vod = imported["imported"][0]["id"].as_str().unwrap().to_owned();
    let local = catalog(&state)
        .unwrap()
        .origins
        .into_iter()
        .find(|origin| origin.kind == "tvbox" && origin.provider_ids.contains(&vod))
        .unwrap();
    assert!(
        local.primary_url.is_empty(),
        "text import has a URL-less local owner"
    );
    crate::tvbox::set_tvbox_source(&state, &vod, &url("/local.json")).unwrap();
    env.clear_requests();
    let checked = crate::tvbox::check_tvbox_updates(&state, Some(&vod))
        .await
        .unwrap();
    assert_eq!(checked["items"][0]["ok"], true);
    assert_eq!(checked["items"][0]["ids"], serde_json::json!([vod]));
    assert_eq!(
        checked["items"][0]["unchanged"], 1,
        "a URL-less local owner cannot hide its existing VOD from the legacy pairing pool"
    );
    assert_eq!(checked["items"][0]["added"], serde_json::json!([]));
    let updated = crate::tvbox::update_tvbox_source(&state, &vod, true, false)
        .await
        .unwrap();
    assert_eq!(updated["updated"], false);
    assert_eq!(updated["added"], serde_json::json!([]));
    assert!(
        crate::tvbox::read_tvbox_meta(&env.dir, &vod)
            .unwrap()
            .last_update_at
            > 0
    );
}
