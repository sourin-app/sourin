use super::*;
use crate::{
    model::PersistedProvider,
    provider::ListRequest,
    proxy::{ProxyConfig, ProxyMode, ProxyStore, GLOBAL_PROXY},
    state::AppState,
};
use axum::{http::Uri, response::IntoResponse, routing::get};
use std::sync::Mutex;

fn rules(base: &str) -> String {
    serde_json::json!({
        "分类": "Movies$1", "分类url": format!("{base}/items/{{cateId}}/{{catePg}}"),
        "数组": "<entry>&&</entry>", "标题": "<title>&&</title>", "链接": "<url>&&</url>"
    }).to_string()
}

async fn fixture(label: &'static str) -> (String, Arc<Mutex<Vec<String>>>, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let direct_base = base.clone();
    let hits = Arc::new(Mutex::new(Vec::new()));
    let observed = hits.clone();
    let app = axum::Router::new().fallback(get(move |uri: Uri| {
        let hits = observed.clone();
        let direct_base = direct_base.clone();
        async move {
            hits.lock().unwrap().push(uri.to_string());
            match uri.path() {
                "/subscription.json" => r#"{"sites":[{"key":"proxy-xbpq","name":"Proxy XBPQ","type":3,"api":"csp_XBPQ","ext":"./rules.json"}]}"#.to_string().into_response(),
                "/rules.json" => rules(if uri.authority().is_some() { "http://xbpq.invalid" } else { &direct_base }).into_response(),
                "/items/1/1" => format!("<entry><title>{label}</title><url>fixture-item</url></entry>").into_response(),
                _ => axum::http::StatusCode::NOT_FOUND.into_response(),
            }
        }
    }));
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (base, hits, server)
}

fn set_proxy(store: &ProxyStore, url: &str) {
    store.set(GLOBAL_PROXY, ProxyConfig {
        mode: ProxyMode::Custom, url: Some(url.into()), ..Default::default()
    }).unwrap();
}

fn scratch() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("sourin-xbpq-proxy-{}-{}",
        std::process::id(), chrono::Utc::now().timestamp_nanos_opt().unwrap()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    dir
}

#[tokio::test]
async fn global_proxy_covers_import_content_policy_changes_restart_and_disabled_home() {
    let (first, first_hits, first_server) = fixture("First proxy content").await;
    let (second, second_hits, second_server) = fixture("Second proxy content").await;
    let dir = scratch();
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    for manifest in state.registry.manifests() {
        crate::commands_provider::set_enabled_persisted(&state, &manifest.id, false).unwrap();
    }
    set_proxy(&state.proxy, &first);
    let report = crate::tvbox::import_tvbox_config(&state, "http://xbpq.invalid/subscription.json")
        .await.unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty());
    assert_eq!(report["imported"][0]["categories"], 1);
    assert!(report["imported"][0]["probeFailed"].is_null());
    let id = report["imported"][0]["id"].as_str().unwrap().to_string();
    assert_eq!(*first_hits.lock().unwrap(), vec![
        "http://xbpq.invalid/subscription.json", "http://xbpq.invalid/rules.json",
        "http://xbpq.invalid/items/1/1",
    ]);
    let provider = state.registry.get(&id).unwrap();
    let request = || ListRequest { category_id: "1".into(), page: 1, ..Default::default() };
    assert_eq!(provider.list(request()).await.unwrap().items[0].title, "First proxy content");
    let first_count = first_hits.lock().unwrap().len();
    set_proxy(&state.proxy, &second);
    assert_eq!(provider.list(request()).await.unwrap().items[0].title, "Second proxy content");
    assert_eq!(first_hits.lock().unwrap().len(), first_count);
    assert_eq!(*second_hits.lock().unwrap(), vec![
        "http://xbpq.invalid/rules.json", "http://xbpq.invalid/items/1/1",
    ]);
    crate::commands_provider::set_enabled_persisted(&state, &id, false).unwrap();
    // An empty saved category cache makes home issue real requests when enabled.
    let mut saved = crate::persist::load_persisted(&dir);
    for item in &mut saved {
        if let PersistedProvider::Tvbox { id: saved_id, categories, .. } = item {
            if saved_id == &id { categories.clear(); }
        }
    }
    crate::persist::save_persisted(&dir, &saved).unwrap();
    drop(provider);
    drop(state);

    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    assert!(!state.registry.enabled_manifests().iter().any(|m| m.id == id));
    assert_eq!(state.proxy.get(GLOBAL_PROXY).url.as_deref(), Some(second.as_str()));
    let before = second_hits.lock().unwrap().len();
    assert!(state.registry.home_all().await.is_empty());
    let _ = state.registry.search_all("fixture", 1).await;
    state.registry.search_all_stream("fixture", 1, |_| true).await;
    assert_eq!(second_hits.lock().unwrap().len(), before, "disabled source must not make requests");
    assert_eq!(first_hits.lock().unwrap().len(), first_count);
    crate::commands_provider::set_enabled_persisted(&state, &id, true).unwrap();
    let home = state.registry.home_all().await;
    assert_eq!(home.len(), 1);
    assert_eq!(home[0].0, id);
    assert_eq!(second_hits.lock().unwrap().len(), before + 2, "enabled home must fetch ext and content");
    let page = state.registry.get(&id).unwrap().list(request()).await.unwrap();
    assert_eq!(page.items[0].title, "Second proxy content");
    assert_eq!(second_hits.lock().unwrap().len(), before + 4);
    drop(state);
    first_server.abort();
    second_server.abort();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn unavailable_proxy_never_falls_back_for_ext_or_content_and_direct_and_bypass_still_work() {
    let (origin, hits, origin_server) = fixture("Direct content").await;
    let (proxy, proxy_hits, proxy_server) = fixture("Proxy content").await;
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    let store = Arc::new(ProxyStore::new());
    set_proxy(&store, &unavailable);
    let site = Xbpq::new().with_proxy(store.clone(), "xbpq-policy-fixture".into());
    let ext = format!("{origin}/rules.json");
    for config in [ext.clone(), rules(&origin)] {
        let result = tokio::time::timeout(Duration::from_secs(3), site.list("1", 1, &config)).await;
        assert!(result.unwrap().is_err());
        assert!(hits.lock().unwrap().is_empty(), "failed proxy cannot retry directly");
    }
    store.set(GLOBAL_PROXY, ProxyConfig::default()).unwrap();
    assert_eq!(site.list("1", 1, &ext).await.unwrap().items[0].title, "Direct content");
    assert_eq!(hits.lock().unwrap().len(), 2);
    store.set(GLOBAL_PROXY, ProxyConfig {
        mode: ProxyMode::Custom, url: Some(proxy), bypass: vec!["127.0.0.1".into()],
        ..Default::default()
    }).unwrap();
    assert_eq!(site.list("1", 1, &ext).await.unwrap().items[0].title, "Direct content");
    assert_eq!(hits.lock().unwrap().len(), 4);
    assert!(proxy_hits.lock().unwrap().is_empty(), "explicit bypass must retain its policy");
    origin_server.abort();
    proxy_server.abort();
}
