use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use axum::{http::StatusCode, response::IntoResponse};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn html_for(path: &str) -> String {
    if path.starts_with(PATH_DETAIL) {
        super::tests::DETAIL_HTML.to_string()
    } else if path.starts_with(PATH_SEARCH) {
        super::tests::LIST_HTML.replace("module-item", "module-search-item")
    } else {
        super::tests::LIST_HTML.to_string()
    }
}

fn assert_html_headers(request: &Request) {
    assert_eq!(request.method, axum::http::Method::GET);
    assert_eq!(request.headers["user-agent"], UA);
    assert_eq!(request.headers["accept"], "text/html,application/xhtml+xml");
    assert!(!request.headers.contains_key("cookie"));
    assert!(request.body.is_empty());
}

#[tokio::test]
async fn pan_web_share_proxy_preserves_sticky_mirrors_headers_redirects_and_no_direct_fallback() {
    let first = serve(|request| {
        assert_html_headers(&request);
        if request.uri.host() == Some("panweb-first.invalid") {
            StatusCode::BAD_GATEWAY.into_response()
        } else {
            html_for(request.uri.path()).into_response()
        }
    })
    .await;
    let second = serve(|request| {
        assert_html_headers(&request);
        if request.uri.host() == Some("panweb-second.invalid")
            && request.uri.path().ends_with("/page/2.html")
        {
            (
                StatusCode::FOUND,
                [
                    ("location", "http://panweb-redirect.invalid/list.html"),
                    ("set-cookie", "fixture=unpersisted; Path=/"),
                ],
            )
                .into_response()
        } else {
            html_for(request.uri.path()).into_response()
        }
    })
    .await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    let site = PanWebShare::new();
    site.set_http_context(store.clone(), "panweb-fixture");
    let ext = r#"{"site":["http://panweb-first.invalid","http://panweb-second.invalid"]}"#;
    custom(&store, &first.url);
    assert_eq!(site.home(ext).await.unwrap().categories.len(), 3);
    assert_eq!(
        site.sticky.lock().unwrap().as_deref(),
        Some("http://panweb-second.invalid")
    );
    custom(&store, &second.url);
    assert_eq!(
        site.list("1", 2, ext).await.unwrap().items[0].title,
        "示例片 甲"
    );
    assert_eq!(
        site.search("示例 +", 2, ext).await.unwrap().items[0].title,
        "示例片 甲"
    );
    let detail = site.detail("1234", ext).await.unwrap();
    assert_eq!(detail.title, "示例片 甲");
    assert!(!detail.episodes.is_empty());
    let share = site
        .play("", "pan|https://pan.quark.cn/s/fixture1234", ext)
        .await
        .unwrap();
    assert_eq!(share[0].url, "https://pan.quark.cn/s/fixture1234");
    // This site returns an intermediate share candidate. Host cloud requests
    // belong to a separate context migration and must not be implied by this test.
    {
        let hits = first.hits.lock().unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].uri.host(), Some("panweb-first.invalid"));
        assert_eq!(hits[1].uri.host(), Some("panweb-second.invalid"));
    }
    {
        let hits = second.hits.lock().unwrap();
        assert_eq!(hits.len(), 4);
        assert_eq!(
            hits[0].uri.host(),
            Some("panweb-second.invalid"),
            "hot policy changes retain the successful mirror"
        );
        assert_eq!(hits[1].uri.host(), Some("panweb-redirect.invalid"));
        assert_eq!(
            hits[2].uri.path(),
            format!("{PATH_SEARCH}{}/page/2", encode_path("示例 +"))
        );
        assert_eq!(hits[3].uri.path(), format!("{PATH_DETAIL}1234.html"));
    }
    let direct = serve(|request| html_for(request.uri.path()).into_response()).await;
    let rejected = serve(|_| StatusCode::BAD_GATEWAY.into_response()).await;
    custom(&store, &rejected.url);
    let ext = serde_json::json!({"site":[direct.url,"http://panweb-negative.invalid"]}).to_string();
    assert!(site.home(&ext).await.unwrap_err().contains("HTTP 502"));
    assert_eq!(
        rejected.hits.lock().unwrap().len(),
        2,
        "mirror fallback must retain the configured proxy"
    );
    assert!(direct.hits.lock().unwrap().is_empty());
    store
        .set(
            crate::proxy::GLOBAL_PROXY,
            crate::proxy::ProxyConfig::default(),
        )
        .unwrap();
    assert_eq!(
        site.home(&serde_json::json!({"site":[direct.url]}).to_string())
            .await
            .unwrap()
            .categories
            .len(),
        3
    );
    assert_eq!(direct.hits.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn pan_web_share_proxy_context_reaches_import_runtime_and_restored_provider_instances() {
    let proxy = serve(|request| {
        if request.uri.path() == "/subscription.json" {
            axum::Json(serde_json::json!({"sites":[{
                "key":"panweb-fixture","name":"PanWebShare fixture","type":3,"api":"csp_PanWebShare",
                "ext":{"site":["http://panweb-fixture.invalid"]}
            }]})).into_response()
        } else {
            assert_html_headers(&request);
            html_for(request.uri.path()).into_response()
        }
    }).await;
    let dir = scratch("panweb-import");
    let state = crate::state::AppState::bootstrap(dir.clone())
        .await
        .unwrap();
    custom(&state.proxy, &proxy.url);
    let report = crate::tvbox::import_tvbox_config(
        &state,
        "http://panweb-fixture.invalid/subscription.json",
    )
    .await
    .unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty());
    let row = &report["imported"][0];
    assert!(row["probeFailed"].is_null());
    assert_eq!(row["categories"], 3);
    let id = row["id"].as_str().unwrap().to_string();
    let request = || crate::provider::ListRequest {
        category_id: "1".into(),
        page: 1,
        ..Default::default()
    };
    assert_eq!(
        state
            .registry
            .get(&id)
            .unwrap()
            .list(request())
            .await
            .unwrap()
            .items[0]
            .title,
        "示例片 甲"
    );
    drop(state);
    let restored = crate::state::AppState::bootstrap(dir.clone())
        .await
        .unwrap();
    assert_eq!(
        restored
            .registry
            .get(&id)
            .unwrap()
            .list(request())
            .await
            .unwrap()
            .items[0]
            .title,
        "示例片 甲"
    );
    assert_eq!(proxy.hits.lock().unwrap().len(), 4);
    drop(restored);
    let _ = std::fs::remove_dir_all(dir);
}

fn gzip_html(title: &str) -> Vec<u8> {
    use std::io::Write as _;
    let html = super::tests::LIST_HTML.replace("示例片 甲", title);
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(html.as_bytes()).unwrap();
    let body = encoder.finish().unwrap();
    assert_eq!(&body[..3], &[0x1f, 0x8b, 0x08], "serve actual gzip bytes");
    body
}

#[tokio::test]
async fn pan_web_share_gzip_html_matches_original_builder_and_survives_proxy_switch() {
    let fixture = |title: &'static str| {
        let compressed = gzip_html(title);
        move |request: Request| {
            assert_html_headers(&request);
            (
                [
                    ("content-type", "text/html; charset=utf-8"),
                    ("content-encoding", "gzip"),
                ],
                compressed.clone(),
            )
                .into_response()
        }
    };
    let origin = serve(fixture("Original gzip fixture")).await;
    let first = serve(fixture("First gzip fixture")).await;
    let second = serve(fixture("Second gzip fixture")).await;
    // This is the original PanWebShare builder recipe before context injection.
    let original = reqwest::Client::builder()
        .user_agent(UA)
        .timeout(Duration::from_secs(8))
        .no_proxy()
        .build()
        .unwrap();
    let original_html = original
        .get(format!("{}{PATH_SHOW}1.html", origin.url))
        .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let home = home_from_html(&original_html).unwrap();
    assert_eq!(home.categories.len(), 3);
    assert_eq!(home.items[0].title, "Original gzip fixture");

    let store = Arc::new(crate::proxy::ProxyStore::new());
    let site = PanWebShare::new();
    site.set_http_context(store.clone(), "panweb-gzip");
    let ext = r#"{"site":["http://panweb-gzip.invalid"]}"#;
    custom(&store, &first.url);
    let home = site.home(ext).await.unwrap();
    assert_eq!(home.categories.len(), 3);
    assert_eq!(home.items[0].title, "First gzip fixture");
    custom(&store, &second.url);
    let list = site.list("1", 2, ext).await.unwrap();
    assert_eq!(list.items[0].title, "Second gzip fixture");
    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding
        .to_str()
        .unwrap()
        .split(',')
        .any(|value| value.trim() == "gzip"));
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    for proxy in [&first, &second] {
        let hits = proxy.hits.lock().unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].headers["accept-encoding"], encoding);
        assert_eq!(hits[0].uri.host(), Some("panweb-gzip.invalid"));
    }
}

struct TruncatedBodyProxy {
    url: String,
    targets: Arc<Mutex<Vec<String>>>,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for TruncatedBodyProxy {
    fn drop(&mut self) {
        self.server.abort();
    }
}

async fn truncated_body_proxy() -> TruncatedBodyProxy {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let targets = Arc::new(Mutex::new(Vec::new()));
    let observed = targets.clone();
    let server = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(socket.read_u8().await.unwrap());
                assert!(request.len() < 16_384);
            }
            let request = String::from_utf8(request).unwrap();
            let target = request
                .lines()
                .next()
                .unwrap()
                .split_whitespace()
                .nth(1)
                .unwrap();
            observed.lock().unwrap().push(target.to_string());
            if target.starts_with("http://panweb-status.invalid/") {
                // A complete 444 header followed by chunked HTML without its
                // terminating zero chunk reproduces the observed HTTP failure.
                let response = b"HTTP/1.1 444 Rejected\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\noops\r\n";
                let _ = socket.write_all(response).await;
            } else {
                assert!(target.starts_with("http://panweb-backup.invalid/"));
                let body = gzip_html("Backup gzip fixture");
                let header = format!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                let _ = socket.write_all(header.as_bytes()).await;
                let _ = socket.write_all(&body).await;
            }
        }
    });
    TruncatedBodyProxy {
        url,
        targets,
        server,
    }
}

#[tokio::test]
async fn pan_web_share_preserves_non_success_status_with_truncated_body_and_tries_next_mirror() {
    let proxy = truncated_body_proxy().await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &proxy.url);
    let site = PanWebShare::new();
    site.set_http_context(store, "panweb-status");
    let bad_url = format!("http://panweb-status.invalid{PATH_SHOW}1.html");
    // Prove that this fixture would fail if the response body were read first.
    let response = site
        .client
        .client()
        .unwrap()
        .get(&bad_url)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status().as_u16(), 444);
    assert!(response.text().await.unwrap_err().is_decode());
    let error = site.get_html(&bad_url).await.unwrap_err();
    assert_eq!(error, format!("HTTP 444（{bad_url}）"));
    let summary = site
        .home(r#"{"site":["http://panweb-status.invalid"]}"#)
        .await
        .unwrap_err();
    assert!(summary.contains("HTTP 444"));
    assert!(!summary.contains("decoding response body"));

    let ext = r#"{"site":["http://panweb-status.invalid","http://panweb-backup.invalid"]}"#;
    let home = tokio::time::timeout(Duration::from_secs(2), site.home(ext))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(home.categories.len(), 3);
    assert_eq!(home.items[0].title, "Backup gzip fixture");
    assert_eq!(
        site.sticky.lock().unwrap().as_deref(),
        Some("http://panweb-backup.invalid")
    );
    let targets = proxy.targets.lock().unwrap();
    assert_eq!(targets.len(), 5);
    assert!(targets[..4].iter().all(|target| target == &bad_url));
    assert_eq!(
        targets[4],
        format!("http://panweb-backup.invalid{PATH_SHOW}1.html")
    );
}
