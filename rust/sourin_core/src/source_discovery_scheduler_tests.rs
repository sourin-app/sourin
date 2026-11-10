use super::*;
use axum::{http::Uri, response::IntoResponse, routing::get};

const API: &str = "http://github-scheduler.invalid";
const RAW: &str = "http://raw-scheduler.invalid";

async fn fixture_proxy() -> (String, Arc<Mutex<Vec<String>>>, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let hits = Arc::new(Mutex::new(Vec::new()));
    let observed = hits.clone();
    let app = axum::Router::new().fallback(get(move |uri: Uri| {
        let hits = observed.clone();
        async move {
            hits.lock().unwrap().push(uri.to_string());
            let body = match (uri.host(), uri.path()) {
                (Some("github-scheduler.invalid"), "/search/repositories") =>
                    json!({"items":[{"full_name":"fixture/scheduled","default_branch":"main"}]}),
                (Some("github-scheduler.invalid"), "/repos/fixture/scheduled/git/trees/main") =>
                    json!({"tree":[{"path":"config.json","type":"blob","size":300}]}),
                (Some("raw-scheduler.invalid"), "/fixture/scheduled/main/config.json") =>
                    json!({"sites":[{"key":"native","name":"Scheduled fixture","type":1,"api":"http://scheduled-content.invalid/api"}]}),
                (Some("scheduled-content.invalid"), "/api") =>
                    json!({"class":[{"type_id":"1","type_name":"Examples"}],"list":[{"vod_id":"1","vod_name":"Example"}]}),
                _ => return axum::http::StatusCode::BAD_GATEWAY.into_response(),
            };
            axum::Json(body).into_response()
        }
    }));
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    (url, hits, server)
}

fn start(state: &Arc<AppState>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(auto_discovery_loop(Arc::downgrade(state), API, RAW, Duration::from_millis(20)))
}

async fn wait_for_notice(state: &AppState, count: usize) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let complete = {
                let _guard = STORE_LOCK.lock().unwrap();
                read(&state.data_dir).unwrap().notices.len() >= count
            };
            if complete { break; }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await.expect("automatic loop did not complete its proxy scan");
}

#[tokio::test]
async fn automatic_loop_requires_opt_in_proxy_and_persisted_daily_deadline_across_restart() {
    let dir = std::env::temp_dir().join(format!("sourin-discovery-scheduler-{}-{}",
        std::process::id(), chrono::Utc::now().timestamp_nanos_opt().unwrap()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let (proxy, hits, server) = fixture_proxy().await;
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    configure(&state, &proxy, false).unwrap();
    let worker = start(&state);
    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(hits.lock().unwrap().is_empty(), "automatic discovery is opt-in");

    state.proxy.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    configure(&state, "", true).unwrap();
    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(hits.lock().unwrap().is_empty(), "automatic discovery cannot use direct mode");

    edit(&dir, |s| s.last_scan = now() - 3600).unwrap();
    configure(&state, &proxy, true).unwrap();
    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(hits.lock().unwrap().is_empty(), "an hour-old scan is not due");
    edit(&dir, |s| s.last_scan = now() - 86401).unwrap();
    wait_for_notice(&state, 1).await;
    let saved = read(&dir).unwrap();
    assert!(saved.automatic && saved.last_scan > now() - 60);
    assert_eq!(saved.candidates.len(), 1);
    assert_eq!(saved.candidates[0].status, "ready");
    assert!(saved.candidates[0].provider_id.is_none());
    assert!(saved.notices[0].unread);
    assert!(state.registry.manifests().iter().all(|p| !p.id.starts_with("github-")));
    assert_eq!(hits.lock().unwrap().len(), 7);
    let completed_at = saved.last_scan;
    // Bootstrap's unrelated TVBox updater retains an Arc<AppState>. Explicitly
    // join this fixture worker before creating the restored application state.
    worker.abort();
    assert!(worker.await.unwrap_err().is_cancelled());
    drop(state);

    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_eq!(read(&dir).unwrap().last_scan, completed_at);
    assert!(read(&dir).unwrap().automatic);
    assert_eq!(
        reqwest::Url::parse(restored.proxy.get(crate::proxy::GLOBAL_PROXY).url.as_deref().unwrap()).unwrap(),
        reqwest::Url::parse(&proxy).unwrap(),
    );
    let worker = start(&restored);
    tokio::time::sleep(Duration::from_millis(80)).await;
    assert_eq!(hits.lock().unwrap().len(), 7, "restart must retain the daily cooldown");
    edit(&dir, |s| s.last_scan = now() - 86401).unwrap();
    wait_for_notice(&restored, 2).await;
    assert_eq!(hits.lock().unwrap().len(), 14);
    let saved = read(&dir).unwrap();
    assert_eq!(saved.candidates.len(), 1, "a repeated scan must reuse the candidate");
    assert!(saved.candidates[0].provider_id.is_none());
    assert!(restored.registry.manifests().iter().all(|p| !p.id.starts_with("github-")));
    assert!(hits.lock().unwrap().iter().all(|target|
        target.starts_with(API) || target.starts_with(RAW)
            || target.starts_with("http://scheduled-content.invalid/")));
    worker.abort();
    assert!(worker.await.unwrap_err().is_cancelled());
    drop(restored);
    server.abort();
    let _ = std::fs::remove_dir_all(dir);
}
