use super::*;
use crate::csp::http_context::test_support::{custom, serve};
use axum::response::IntoResponse;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const HOST: &str = "http://yunduo-fixture.invalid";
const EXT: &str = r#"{"host":"http://yunduo-fixture.invalid","client":"fixture-client","sign":"fixture-sign"}"#;

#[tokio::test]
async fn yun_duo_keeps_headers_and_category_mapping_across_proxy_changes_without_http_retries() {
    let make = |label: &'static str| move |request: crate::csp::http_context::test_support::Request| {
        match request.uri.path() {
            "/api.php/web/index/home" => axum::Json(serde_json::json!({
                "code":200,"data":{"categories":[{"type_id":1,"type_name":"电影"}]}
            })).into_response(),
            "/api.php/http-failure" => axum::http::StatusCode::BAD_GATEWAY.into_response(),
            "/api.php/business-failure" => axum::Json(serde_json::json!({"code":0,"msg":"fixture"})).into_response(),
            _ => axum::Json(serde_json::json!({
                "code":200,"data":[{"vod_id":123,"vod_name":label}],"total":25,"pageCount":2
            })).into_response(),
        }
    };
    let first = serve(make("first")).await;
    let second = serve(make("second")).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    let site = YunDuo::new();
    site.set_http_context(store.clone(), "yunduo-fixture");
    custom(&store, &first.url);
    let list = site.list("1", 2, EXT).await.unwrap();
    assert_eq!(list.items[0].title, "first");
    assert_eq!(list.total, Some(25));
    assert_eq!(list.page_count, Some(2));
    custom(&store, &second.url);
    assert_eq!(site.list("电影", 1, EXT).await.unwrap().items[0].title, "second");
    let cfg = YunDuo::cfg_of(EXT);
    assert!(site.get_json(&cfg, "/api.php/http-failure").await.unwrap_err().contains("502"));
    assert!(site.get_json(&cfg, "/api.php/business-failure").await.unwrap_err().contains("code=0"));
    for (proxy, count) in [(&first, 2), (&second, 3)] {
        let hits = proxy.hits.lock().unwrap();
        assert_eq!(hits.len(), count, "HTTP and business failures return after one request");
        for hit in hits.iter() {
            assert_eq!(hit.method, axum::http::Method::GET);
            assert_eq!(hit.uri.host(), Some("yunduo-fixture.invalid"));
            assert_eq!(hit.headers["user-agent"], UA);
            assert_eq!(hit.headers["accept"], "application/json");
            assert_eq!(hit.headers["x-client"], "fixture-client");
            assert_eq!(hit.headers["web-sign"], "fixture-sign");
            assert_eq!(hit.headers["referer"], format!("{HOST}/"));
            assert!(hit.body.is_empty());
        }
    }
    let hits = first.hits.lock().unwrap();
    assert_eq!(hits[0].uri.path(), "/api.php/web/index/home");
    let url = reqwest::Url::parse(&hits[1].uri.to_string()).unwrap();
    assert_eq!(url.query_pairs().into_owned().collect::<Vec<_>>(), vec![
        ("type_name".into(), "电影".into()), ("page".into(), "2".into()),
    ]);
}

struct TransportFixture {
    url: String,
    hits: Arc<Mutex<Vec<(Instant, String)>>>,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for TransportFixture {
    fn drop(&mut self) { self.server.abort(); }
}

// Close complete requests without sending an HTTP response to produce actual
// transport failures. Every accepted connection is local; .invalid is never resolved.
async fn transport_fixture(failures: usize) -> TransportFixture {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let hits = Arc::new(Mutex::new(Vec::new()));
    let observed = hits.clone();
    let server = tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let byte = socket.read_u8().await.unwrap();
                request.push(byte);
                assert!(request.len() < 16_384);
            }
            let count = {
                let mut hits = observed.lock().unwrap();
                hits.push((Instant::now(), String::from_utf8(request).unwrap()));
                hits.len()
            };
            if count <= failures { continue; }
            let body = r#"{"code":200,"data":[]}"#;
            let response = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            socket.write_all(response.as_bytes()).await.unwrap();
        }
    });
    TransportFixture { url, hits, server }
}

#[tokio::test]
async fn yun_duo_retries_transport_failures_with_original_backoff_and_limit() {
    let first = transport_fixture(1).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    let site = YunDuo::new();
    site.set_http_context(store.clone(), "yunduo-retry-fixture");
    let cfg = YunDuo::cfg_of(EXT);
    custom(&store, &first.url);
    let value = tokio::time::timeout(Duration::from_secs(5), site.get_json(&cfg, "/api.php/retry")).await.unwrap().unwrap();
    assert_eq!(value["code"], 200);
    {
        let hits = first.hits.lock().unwrap();
        assert_eq!(hits.len(), 2);
        assert!(hits[1].0.duration_since(hits[0].0) >= Duration::from_millis(450));
        for (_, request) in hits.iter() {
            assert!(request.starts_with("GET http://yunduo-fixture.invalid/api.php/retry HTTP/1.1\r\n"));
            let headers = request.to_ascii_lowercase();
            assert!(headers.contains("x-client: fixture-client\r\n"));
            assert!(headers.contains("web-sign: fixture-sign\r\n"));
        }
    }

    let failing = transport_fixture(usize::MAX).await;
    custom(&store, &failing.url);
    let direct = serve(|_| axum::Json(serde_json::json!({"code":200})).into_response()).await;
    let cfg = ExtCfg { host: direct.url.clone(), ..cfg };
    let error = tokio::time::timeout(Duration::from_secs(5), site.get_json(&cfg, "/api.php/retry")).await.unwrap().unwrap_err();
    assert!(error.contains("第 3/3 次"), "{error}");
    assert!(direct.hits.lock().unwrap().is_empty(), "exhausted retries must not fall back to direct");
    {
        let hits = failing.hits.lock().unwrap();
        assert_eq!(hits.len(), 3);
        assert!(hits[1].0.duration_since(hits[0].0) >= Duration::from_millis(450));
        assert!(hits[2].0.duration_since(hits[1].0) >= Duration::from_millis(950));
    }
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(site.get_json(&cfg, "/api.php/retry").await.unwrap()["code"], 200);
    assert_eq!(direct.hits.lock().unwrap().len(), 1);
}
