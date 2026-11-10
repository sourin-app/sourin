use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::{provider::ListRequest, state::AppState};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::Arc};

// Fixed AES-CBC/PKCS7 vectors independently generated with .NET Aes.
const ALL_QUERY: &str = "parameter=Nq5l5KXowgch2kV8LyyEUg%3D%3D";
const FOOTBALL_QUERY: &str = "parameter=LJ6JyZxcMKdqnJ7tXLMN9D8ruBexj53WdpBB8pHfcm0rssHmIqjZ8V2dSrl1KbXX";

fn assert_headers(request: &Request) {
    assert_eq!(request.method, Method::GET);
    assert!(request.body.is_empty());
    assert_eq!(request.headers["user-agent"], "okhttp/3.12.0");
    assert_eq!(request.headers["accept"], "application/json, text/plain, */*");
    assert_eq!(request.headers["user-platform"], "null");
    assert_eq!(request.headers["client-version"], "3.0.1.1");
    assert_eq!(request.headers["client-channel"], "");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
}

fn envelope(plain: &str) -> Value {
    serde_json::json!({"code":200,"data":encrypt_param(plain).unwrap()})
}

fn marker(label: &str) -> String {
    serde_json::json!({"fixture":label}).to_string()
}

async fn call(site: &SportsGuazi, host: &str) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), site.call(host, "/gz/live/sports", "{}"))
        .await.expect("loopback encrypted request exceeded its fixture budget")
}

#[tokio::test]
async fn catalog_proxy_sportsguazi_real_helper_preserves_encrypted_bytes_and_policy() {
    let origin = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.query(), Some(ALL_QUERY));
        axum::Json(envelope(&marker("origin"))).into_response()
    }).await;
    let site = SportsGuazi::new();
    assert_eq!(call(&site, &origin.url).await.unwrap(), marker("origin"));
    assert_eq!(origin.hits.lock().unwrap().len(), 1);
    let first = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.path(), "/gz/live/sports");
        assert_eq!(request.uri.query(), Some(ALL_QUERY));
        axum::Json(envelope(&marker("first proxy"))).into_response()
    }).await;
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(envelope(&marker("second proxy gzip")).to_string().as_bytes()).unwrap();
    let compressed = encoder.finish().unwrap();
    assert_eq!(&compressed[..3], &[0x1f, 0x8b, 0x08]);
    let redirect = format!("{}/landed?{ALL_QUERY}", origin.url);
    let second = serve(move |request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.query(), Some(ALL_QUERY));
        if request.uri.path() == "/gz/live/sports" {
            (StatusCode::FOUND, [
                ("location", redirect.clone()),
                ("set-cookie", "fixture=must-not-persist; Path=/".to_string()),
            ]).into_response()
        } else {
            assert_eq!(request.uri.path(), "/landed");
            ([
                ("content-type", "application/json; charset=utf-8"),
                ("content-encoding", "gzip"),
            ], compressed.clone()).into_response()
        }
    }).await;
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "sportsguazi-encrypted-fixture");
    assert_eq!(call(&site, &origin.url).await.unwrap(), marker("first proxy"));
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1);

    custom(&store, &second.url);
    assert_eq!(call(&site, &origin.url).await.unwrap(), marker("second proxy gzip"));
    assert_eq!(second.hits.lock().unwrap().len(), 2, "original redirect/decompression behavior is retained");
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "redirect cannot bypass proxy");
    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding.to_str().unwrap().split(',').any(|part| part.trim() == "gzip"));
    for proxy in [&first, &second] {
        for request in proxy.hits.lock().unwrap().iter() {
            assert_eq!(request.headers["accept-encoding"], encoding);
        }
    }

    let rejected = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.query(), Some(ALL_QUERY));
        (StatusCode::BAD_GATEWAY, "fixture rejection").into_response()
    }).await;
    custom(&store, &rejected.url);
    let error = call(&site, &origin.url).await.unwrap_err();
    assert!(error.contains("HTTP 502"), "preserve the engine HTTP error: {error}");
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "HTTP failure cannot retry directly");
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    custom(&store, &unavailable);
    assert!(call(&site, &origin.url).await.is_err());
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "transport failure cannot retry directly");

    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(call(&site, &origin.url).await.unwrap(), marker("origin"));
    assert_eq!(origin.hits.lock().unwrap().len(), 2, "explicit direct policy takes effect");
}

fn matches(label: &str) -> Value {
    envelope(&serde_json::json!([{
        "mid":101,"home":{"name":format!("SportsGuazi {label}")},"visiting":{"name":"away"}
    }]).to_string())
}

async fn assert_list(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.list(ListRequest {
        category_id: "football".into(), page: 1, ..Default::default()
    })).await.expect("loopback list exceeded its fixture budget").unwrap();
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].title, format!("SportsGuazi {label} vs away"));
    assert_eq!(page.page, 1);
    assert_eq!(page.page_count, None);
}

#[tokio::test]
async fn catalog_proxy_sportsguazi_import_runtime_hot_change_and_restore() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let base = origin.url.clone();
    let subscription = serde_json::json!({"sites":[{
        "key":"sportsguazi-local", "name":"SportsGuazi local fixture", "type":3,
        "api":"csp_SportsGuazi", "ext":{"host":base.clone()}
    }]});
    let first = serve(move |request| {
        assert_eq!(request.uri.scheme_str(), Some("http"));
        if request.uri.path() == "/subscription.json" {
            return axum::Json(subscription.clone()).into_response();
        }
        assert_headers(&request);
        assert_eq!(request.uri.path(), "/gz/live/sports");
        assert!(matches!(request.uri.query(), Some(ALL_QUERY) | Some(FOOTBALL_QUERY)));
        axum::Json(matches("first proxy")).into_response()
    }).await;
    let second = serve(|request| {
        assert_headers(&request);
        assert_eq!(request.uri.scheme_str(), Some("http"));
        assert_eq!(request.uri.path(), "/gz/live/sports");
        assert_eq!(request.uri.query(), Some(FOOTBALL_QUERY));
        axum::Json(matches("second proxy")).into_response()
    }).await;
    let root = scratch("sportsguazi-proxy-factories");
    let dir = root.join("data");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir.clone()).await.unwrap();
    custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{base}/subscription.json"),
    )).await.expect("loopback import exceeded its fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let imported = report["imported"].as_array().unwrap();
    assert_eq!(imported.len(), 1, "{report}");
    let row = &imported[0];
    assert_eq!(row["api"], "csp_SportsGuazi");
    assert_eq!(row["categories"], 5);
    assert!(row["probeFailed"].is_null(), "{row}");
    assert_eq!(row["persisted"], true);
    let id = row["id"].as_str().unwrap().to_string();
    assert_list(&state, &id, "first proxy").await;
    let queries: Vec<_> = first.hits.lock().unwrap().iter()
        .filter(|r| r.uri.path() == "/gz/live/sports")
        .map(|r| r.uri.query().unwrap().to_string()).collect();
    assert_eq!(queries, [ALL_QUERY, FOOTBALL_QUERY], "home and football list retain distinct encrypted templates");
    assert_eq!(first.hits.lock().unwrap().len(), 3, "config, home probe, runtime list");
    assert!(origin.hits.lock().unwrap().is_empty());

    custom(&state.proxy, &second.url);
    assert_list(&state, &id, "second proxy").await;
    assert_eq!(first.hits.lock().unwrap().len(), 3);
    assert_eq!(second.hits.lock().unwrap().len(), 1);
    drop(state);
    let restored = AppState::bootstrap(dir.clone()).await.unwrap();
    assert_list(&restored, &id, "second proxy").await;
    assert_eq!(second.hits.lock().unwrap().len(), 2);
    assert!(origin.hits.lock().unwrap().is_empty(), "no factory may bypass its injected policy");
    drop(restored);
    let _ = std::fs::remove_dir_all(root);
}
