use super::*;
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn isolated_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "sourin-global-proxy-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn global_setting_is_durable_and_overrides_every_provider() {
    let dir = isolated_dir();
    let store = ProxyStore::open(&dir).unwrap();
    store
        .set(
            "old-provider",
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: Some("socks5://127.0.0.1:1080".into()),
                ..Default::default()
            },
        )
        .unwrap();
    let reopened = ProxyStore::open(&dir).unwrap();
    for id in [GLOBAL_PROXY, "tvbox_agg", "danmaku", "another-source"] {
        assert_eq!(
            reopened.get(id).url.as_deref(),
            Some("socks5://127.0.0.1:1080")
        );
    }
    assert_eq!(reopened.all().len(), 1);
    let saved = std::fs::read_to_string(dir.join("global-proxy.json")).unwrap();
    assert!(!saved.contains("password"));
    assert!(reopened
        .set(
            GLOBAL_PROXY,
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: Some("http://user:secret@localhost:8080".into()),
                ..Default::default()
            }
        )
        .is_err());
    assert_eq!(reopened.get(GLOBAL_PROXY).url, store.get(GLOBAL_PROXY).url);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn failed_persistence_keeps_last_working_configuration() {
    let dir = isolated_dir();
    let store = ProxyStore::open(&dir).unwrap();
    std::fs::create_dir(dir.join("global-proxy.json.tmp")).unwrap();
    assert!(store
        .set(
            GLOBAL_PROXY,
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: Some("http://127.0.0.1:7890".into()),
                ..Default::default()
            }
        )
        .is_err());
    assert_eq!(store.get("some-source").mode, ProxyMode::Direct);
    assert!(store.required_global_proxy().is_err());
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn migration_preserves_a_unique_old_proxy_and_requires_choice_for_conflicts() {
    let dir = isolated_dir();
    std::fs::write(
        dir.join("ui-prefs.json"),
        r#"{"dsh.danmaku.proxy.mode":"custom","dsh.danmaku.proxy.url":"http://127.0.0.1:7890"}"#,
    )
    .unwrap();
    let store = ProxyStore::open(&dir).unwrap();
    assert_eq!(
        store.get(GLOBAL_PROXY).url.as_deref(),
        Some("http://127.0.0.1:7890")
    );
    assert!(store.migration_choices().is_empty());
    std::fs::remove_dir_all(&dir).unwrap();
    let dir = isolated_dir();
    std::fs::write(
        dir.join("ui-prefs.json"),
        r#"{"dsh.danmaku.proxy.mode":"custom","dsh.danmaku.proxy.url":"http://127.0.0.1:7890"}"#,
    )
    .unwrap();
    std::fs::write(
        dir.join("github-discovery.json"),
        r#"{"proxyUrl":"http://127.0.0.1:8080"}"#,
    )
    .unwrap();
    let store = ProxyStore::open(&dir).unwrap();
    assert_eq!(store.migration_choices().len(), 2);
    assert!(store.client_for("some-source", None).is_err());
    assert!(store.required_global_proxy().is_err());
    assert!(!dir.join("global-proxy.json").exists());
    store
        .set(GLOBAL_PROXY, store.migration_choices()[1].config.clone())
        .unwrap();
    assert!(store.migration_choices().is_empty());
    assert_eq!(
        ProxyStore::open(&dir)
            .unwrap()
            .get(GLOBAL_PROXY)
            .url
            .as_deref(),
        Some("http://127.0.0.1:7890")
    );
    std::fs::remove_dir_all(dir).unwrap();
}

async fn response_server(body: &'static str) -> (String, tokio::task::JoinHandle<String>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut bytes = vec![0; 8192];
        let n = socket.read(&mut bytes).await.unwrap();
        socket.write_all(format!("HTTP/1.1 403 Forbidden\r\nContent-Length: {}\r\nX-Error-Message: fixture\r\nConnection: close\r\n\r\n{}",body.len(),body).as_bytes()).await.unwrap();
        String::from_utf8_lossy(&bytes[..n]).into_owned()
    });
    (url, task)
}

#[tokio::test]
async fn danmaku_reuses_global_policy_and_observes_proxy_changes() {
    let store = ProxyStore::new();
    for body in ["first", "second"] {
        let (proxy, task) = response_server(body).await;
        store
            .set(
                GLOBAL_PROXY,
                ProxyConfig {
                    mode: ProxyMode::Custom,
                    url: Some(proxy),
                    ..Default::default()
                },
            )
            .unwrap();
        let response = store
            .text_request(
                json!({"url":"http://danmaku.invalid/comment/1","method":"GET",
            "headers":{"X-AppId":"fixture"}}),
            )
            .await
            .unwrap();
        assert_eq!(response["statusCode"], 403);
        assert_eq!(response["body"], body);
        assert_eq!(response["headers"]["x-error-message"], "fixture");
        let request = task.await.unwrap().to_lowercase();
        assert!(request.starts_with("get http://danmaku.invalid/comment/1 "));
        assert!(request.contains("x-appid: fixture"));
    }
    // Local desktop services remain reachable even when the configured proxy is down.
    let (local, task) = response_server("local").await;
    store
        .set(
            GLOBAL_PROXY,
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: Some("http://127.0.0.1:1".into()),
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(
        store.text_request(json!({"url":local})).await.unwrap()["body"],
        "local"
    );
    task.await.unwrap();
    assert!(store
        .text_request(json!({"url":"http://danmaku.invalid/comment/2"}))
        .await
        .is_err());
}

#[tokio::test]
async fn required_proxy_ignores_bypass_and_never_falls_back_to_direct() {
    let store = ProxyStore::new();
    assert!(store.required_global_proxy().is_err());
    let (proxy, task) = response_server("strict").await;
    store
        .set(
            GLOBAL_PROXY,
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: Some(proxy),
                bypass: vec!["*".into()],
                ..Default::default()
            },
        )
        .unwrap();
    let client = reqwest::Client::builder()
        .no_proxy()
        .proxy(store.required_global_proxy().unwrap())
        .build()
        .unwrap();
    assert_eq!(
        client
            .get("http://public.invalid/test")
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap(),
        "strict"
    );
    assert!(task
        .await
        .unwrap()
        .starts_with("GET http://public.invalid/test "));
}
