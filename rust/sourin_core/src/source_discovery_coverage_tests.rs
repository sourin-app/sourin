//! These tests observe proxy HTTP requests and persisted results, not selection helpers.
use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

async fn proxy(
    route: impl Fn(&str) -> Value + Send + Sync + 'static,
) -> (String, Arc<Mutex<Vec<String>>>, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let requests = Arc::new(Mutex::new(Vec::new()));
    let hits = requests.clone();
    let route = Arc::new(route);
    let server = tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let route = route.clone();
            let hits = hits.clone();
            tokio::spawn(async move {
                let mut bytes = vec![0; 16384];
                let count = socket.read(&mut bytes).await.unwrap();
                let request = String::from_utf8_lossy(&bytes[..count]);
                let target = request
                    .lines()
                    .next()
                    .unwrap()
                    .split_whitespace()
                    .nth(1)
                    .unwrap();
                hits.lock().unwrap().push(target.to_owned());
                let body = route(target).to_string();
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(response.as_bytes()).await.unwrap();
            });
        }
    });
    (url, requests, server)
}

fn repositories(names: &[&str]) -> Value {
    json!({"items": names.iter().map(|name| json!({"full_name":name,"default_branch":"main"})).collect::<Vec<_>>()})
}

fn tree(count: usize) -> Value {
    json!({"tree": (0..count).map(|i| json!({"type":"blob","path":format!("config{i}.json"),"size":500})).collect::<Vec<_>>()})
}

fn catalog(api: &str) -> Value {
    json!({"sites":[{"key":"native","name":"Synthetic native","type":1,"api":api}]})
}

fn valid_catalog() -> Value {
    json!({"class":[{"type_id":"1","type_name":"Examples"}],"list":[{"vod_id":"1","vod_name":"Example"}],"total":1})
}

fn scripts() -> Value {
    json!({"sites": (0..100).map(|i| json!({"key":format!("script{i}"),"name":"Synthetic script","type":3,"api":format!("http://scripts.invalid/{i}.js")})).collect::<Vec<_>>()})
}

#[tokio::test]
async fn coverage_later_repository_survives_early_script_catalogs() {
    let (proxy, hits, server) = proxy(|url| {
        if url.contains("/search/repositories") {
            repositories(&["fixture/scripts", "fixture/native"])
        } else if url.contains("/git/trees/") {
            tree(3)
        } else if url.contains("/fixture/scripts/") {
            scripts()
        } else if url.contains("/fixture/native/") {
            catalog("http://content.invalid/api")
        } else {
            valid_catalog()
        }
    })
    .await;
    let result = collect(
        &strict_client(&proxy).unwrap(),
        "http://github.invalid",
        "http://raw.invalid",
    )
    .await
    .unwrap();
    assert_eq!(
        result
            .candidates
            .iter()
            .filter(|c| c.status == "ready")
            .count(),
        1
    );
    assert!(result
        .candidates
        .iter()
        .any(|c| c.repository == "fixture/native" && c.status == "ready"));
    let requests = hits.lock().unwrap();
    assert_eq!(
        requests
            .iter()
            .filter(|u| u.contains("content.invalid"))
            .count(),
        2
    );
    assert!(requests.iter().all(|u| !u.contains("scripts.invalid")));
    server.abort();
}

#[tokio::test]
async fn coverage_repository_without_topic_is_discovered() {
    let (proxy, hits, server) = proxy(|url| {
        if url.contains("/search/repositories") {
            if url.contains("sort=stars") {
                repositories(&["fixture/untagged"])
            } else {
                repositories(&["fixture/scripts"])
            }
        } else if url.contains("/git/trees/") {
            tree(1)
        } else if url.contains("/fixture/scripts/") {
            scripts()
        } else if url.contains("/fixture/untagged/") {
            catalog("http://content.invalid/api")
        } else {
            valid_catalog()
        }
    })
    .await;
    let result = collect(
        &strict_client(&proxy).unwrap(),
        "http://github.invalid",
        "http://raw.invalid",
    )
    .await
    .unwrap();
    assert!(result
        .candidates
        .iter()
        .any(|c| c.repository == "fixture/untagged" && c.status == "ready"));
    let requests = hits.lock().unwrap();
    assert_eq!(
        requests
            .iter()
            .filter(|u| u.contains("/search/repositories"))
            .count(),
        3
    );
    assert_eq!(
        requests
            .iter()
            .filter(|u| u.contains("/fixture/untagged/git/trees/"))
            .count(),
        1
    );
    server.abort();
}

#[tokio::test]
async fn coverage_configuration_beyond_first_three_is_read() {
    let (proxy, hits, server) = proxy(|url| {
        if url.contains("/search/repositories") {
            repositories(&["fixture/many-configs"])
        } else if url.contains("/git/trees/") {
            tree(6)
        } else if url.contains("config4.json") {
            catalog("http://content.invalid/api")
        } else if url.contains("raw.invalid") {
            scripts()
        } else {
            valid_catalog()
        }
    })
    .await;
    let result = collect(
        &strict_client(&proxy).unwrap(),
        "http://github.invalid",
        "http://raw.invalid",
    )
    .await
    .unwrap();
    assert!(result
        .candidates
        .iter()
        .any(|c| c.status == "ready" && c.config_url.ends_with("config4.json")));
    assert_eq!(
        hits.lock()
            .unwrap()
            .iter()
            .filter(|u| u.contains("raw.invalid"))
            .count(),
        6
    );
    server.abort();
}

#[tokio::test]
async fn coverage_mirrored_normalized_api_is_validated_once() {
    let (proxy, hits, server) = proxy(|url| {
        if url.contains("/search/repositories") {
            repositories(&["fixture/mirror-a", "fixture/mirror-b"])
        } else if url.contains("/git/trees/") {
            tree(2)
        } else if url.contains("/fixture/mirror-a/") {
            catalog("http://content.invalid/api/?ac=list#one")
        } else if url.contains("/fixture/mirror-b/") {
            catalog("http://content.invalid/api?unused=value")
        } else {
            valid_catalog()
        }
    })
    .await;
    let result = collect(
        &strict_client(&proxy).unwrap(),
        "http://github.invalid",
        "http://raw.invalid",
    )
    .await
    .unwrap();
    assert_eq!(result.candidates.len(), 1);
    assert_eq!(result.candidates[0].status, "ready");
    assert_eq!(
        hits.lock()
            .unwrap()
            .iter()
            .filter(|u| u.contains("content.invalid"))
            .count(),
        2
    );
    server.abort();
}

#[tokio::test]
async fn coverage_mirror_scan_preserves_installed_identity_and_origin() {
    let mirror = Arc::new(AtomicBool::new(false));
    let dir = std::env::temp_dir().join(format!(
        "sourin-coverage-{}-{}",
        std::process::id(),
        chrono::Utc::now().timestamp_nanos_opt().unwrap()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir).await.unwrap();
    let source = mirror.clone();
    let (proxy, _, server) = proxy(move |url| {
        if url.contains("/search/repositories") {
            repositories(&[if source.load(Ordering::SeqCst) {
                "fixture/mirror"
            } else {
                "fixture/original"
            }])
        } else if url.contains("/git/trees/") {
            tree(1)
        } else if url.contains("raw.invalid") {
            catalog("http://content.invalid/api")
        } else {
            valid_catalog()
        }
    })
    .await;
    configure(&state, &proxy, false).unwrap();
    scan_at(&state, "http://github.invalid", "http://raw.invalid")
        .await
        .unwrap();
    let original = read(&state.data_dir).unwrap().candidates[0].clone();
    enable(&state, &original.id).await.unwrap();
    mirror.store(true, Ordering::SeqCst);
    scan_at(&state, "http://github.invalid", "http://raw.invalid")
        .await
        .unwrap();
    let candidates = status(&state).unwrap()["candidates"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["id"], original.id);
    assert_eq!(candidates[0]["repository"], "fixture/original");
    assert_eq!(candidates[0]["installed"], true);
    server.abort();
}

#[tokio::test]
async fn coverage_legacy_uninstalled_mirror_does_not_hide_installed_refresh() {
    let dir = std::env::temp_dir().join(format!(
        "sourin-legacy-coverage-{}-{}",
        std::process::id(),
        chrono::Utc::now().timestamp_nanos_opt().unwrap()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir).await.unwrap();
    let (proxy, _, server) = proxy(|url| {
        if url.contains("/search/repositories") {
            repositories(&["fixture/original"])
        } else if url.contains("/git/trees/") {
            tree(1)
        } else if url.contains("raw.invalid") {
            catalog("http://content.invalid/api")
        } else {
            valid_catalog()
        }
    })
    .await;
    configure(&state, &proxy, false).unwrap();
    scan_at(&state, "http://github.invalid", "http://raw.invalid")
        .await
        .unwrap();
    let original = read(&state.data_dir).unwrap().candidates[0].clone();
    enable(&state, &original.id).await.unwrap();
    edit(&state.data_dir, |saved| {
        let installed = &mut saved.candidates[0];
        installed.status = "failed".into();
        installed.message = "Previous request failed".into();
        let mut mirror = installed.clone();
        mirror.id = "legacy-mirror".into();
        mirror.provider_id = None;
        mirror.repository = "fixture/mirror".into();
        saved.candidates.insert(0, mirror);
    })
    .unwrap();
    scan_at(&state, "http://github.invalid", "http://raw.invalid")
        .await
        .unwrap();
    let candidates = status(&state).unwrap()["candidates"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0]["id"], original.id);
    assert_eq!(candidates[0]["repository"], "fixture/original");
    assert_eq!(candidates[0]["installed"], true);
    assert_eq!(candidates[0]["status"], "ready");
    server.abort();
}

#[tokio::test]
async fn coverage_duplicate_native_entries_do_not_hide_distinct_tail_api() {
    let (proxy, hits, server) = proxy(|url| {
        if url.contains("/search/repositories") {
            repositories(&["fixture/large-config"])
        } else if url.contains("/git/trees/") {
            tree(1)
        } else if url.contains("raw.invalid") {
            let mut sites = scripts()["sites"].as_array().unwrap().clone();
            sites.extend((0..100).map(|i| {
                json!({"key":format!("copy{i}"),"name":"Repeated native","type":1,"api":"http://content.invalid/repeated"})
            }));
            sites.push(json!({"key":"tail","name":"Distinct tail","type":1,"api":"http://content.invalid/tail"}));
            json!({"sites":sites})
        } else {
            valid_catalog()
        }
    })
    .await;
    let result = collect(
        &strict_client(&proxy).unwrap(),
        "http://github.invalid",
        "http://raw.invalid",
    )
    .await
    .unwrap();
    assert_eq!(
        result
            .candidates
            .iter()
            .filter(|c| c.status == "ready")
            .count(),
        2
    );
    assert!(result
        .candidates
        .iter()
        .any(|c| c.api.ends_with("/tail") && c.status == "ready"));
    assert_eq!(
        hits.lock()
            .unwrap()
            .iter()
            .filter(|url| url.contains("content.invalid"))
            .count(),
        4
    );
    server.abort();
}
