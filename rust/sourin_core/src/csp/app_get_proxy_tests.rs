use super::*;
use crate::csp::http_context::test_support::{custom, scratch, serve, Request};
use crate::{provider::ListRequest, state::AppState};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use std::{io::Write, sync::Arc, time::Duration};

const KEY: &str = "0123456789abcdef";
const IV: &str = "fedcba9876543210";
const FIXTURE_UA: &str = "AppGet loopback fixture/1";
const VID: &str = "71 +&/";

#[derive(Clone, Copy)]
enum Entry { EncryptedGet, PlayPost }

fn cfg(base: &str, entry: Entry) -> Cfg {
    Cfg {
        site: base.to_string(), data_key: KEY.into(), data_iv: IV.into(),
        device_id: "fixture-device".into(), version: "fixture-version".into(),
        ua: FIXTURE_UA.into(),
        token: match entry { Entry::EncryptedGet => String::new(), Entry::PlayPost => "fixture-token".into() },
    }
}

fn encrypted(value: Value) -> String {
    use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
    let plain = value.to_string();
    let mut buffer = vec![0; plain.len() + 16];
    buffer[..plain.len()].copy_from_slice(plain.as_bytes());
    let cipher = cbc::Encryptor::<aes::Aes128>::new_from_slices(KEY.as_bytes(), IV.as_bytes()).unwrap()
        .encrypt_padded_mut::<Pkcs7>(&mut buffer, plain.len()).unwrap();
    serde_json::json!({"code":1,"data":b64_encode(cipher)}).to_string()
}

fn media(label: &str) -> String { format!("http://127.0.0.1/fixture-{label}.m3u8") }

fn payload(entry: Entry, label: &str) -> String {
    match entry {
        Entry::EncryptedGet => encrypted(serde_json::json!({"fixture":label})),
        Entry::PlayPost => serde_json::json!({"code":1,"data":{"url":media(label)}}).to_string(),
    }
}

fn assert_headers(request: &Request, entry: Entry) {
    assert_eq!(request.headers["user-agent"], FIXTURE_UA);
    assert_eq!(request.headers["accept"], "*/*");
    assert_eq!(request.headers["connection"], "Keep-Alive");
    assert_eq!(request.headers["content-type"], "application/x-www-form-urlencoded");
    assert_eq!(request.headers["app-version-code"], "fixture-version");
    assert_eq!(request.headers["app-ui-mode"], "light");
    assert_eq!(request.headers["app-user-device-id"], "fixture-device");
    assert_eq!(request.headers["app-api-verify-sign"], "");
    assert!(request.headers["app-api-verify-time"].to_str().unwrap().parse::<u64>().unwrap() > 0);
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    match entry {
        Entry::EncryptedGet => assert!(!request.headers.contains_key("app-user-token")),
        Entry::PlayPost => assert_eq!(request.headers["app-user-token"], "fixture-token"),
    }
}

fn assert_request(request: &Request, entry: Entry) {
    assert_headers(request, entry);
    match entry {
        Entry::EncryptedGet => {
            assert_eq!(request.method, Method::GET);
            assert!(request.body.is_empty());
            assert_eq!(request.uri.query(), Some("first=alpha%2Bbeta&second=two"));
            assert!(matches!(request.uri.path(), "/probe" | "/landed"));
        }
        Entry::PlayPost => {
            assert_eq!(request.method, Method::POST);
            assert_eq!(request.body.as_ref(), br#"{"url":"71 +&/"}"#);
            assert!(request.uri.query().is_none());
            assert!(request.uri.path() == P_VOD_PARSE || request.uri.path() == "/landed");
        }
    }
    if request.uri.path() != "/landed" { assert!(!request.headers.contains_key("referer")); }
}

async fn fetch(site: &AppGet, base: &str, entry: Entry) -> Result<String, String> {
    tokio::time::timeout(Duration::from_secs(3), async {
        let cfg = cfg(base, entry);
        match entry {
            Entry::EncryptedGet => site.get_decoded(&cfg, "/probe?first=alpha%2Bbeta&second=two", "fixture")
                .await.map(|v| v["fixture"].as_str().unwrap().to_string()),
            Entry::PlayPost => site.vod_parse(&cfg, VID, "fixture-line").await.map(|plays| {
                assert_eq!(plays.len(), 1);
                assert_eq!(plays[0].label.as_deref(), Some("fixture-line"));
                assert_eq!(plays[0].headers, vec![("User-Agent".to_string(), FIXTURE_UA.to_string())]);
                plays[0].url.clone()
            }),
        }
    }).await.expect("loopback AppGet request exceeded fixture budget")
}

fn expected(entry: Entry, label: &str) -> String {
    match entry { Entry::EncryptedGet => label.into(), Entry::PlayPost => media(label) }
}

async fn exercise(entry: Entry) {
    let origin = serve(move |r| { assert_request(&r, entry); payload(entry, "origin").into_response() }).await;
    let first = serve(move |r| {
        assert_request(&r, entry); assert_eq!(r.uri.scheme_str(), Some("http"));
        payload(entry, "first").into_response()
    }).await;
    let redirect = format!("{}/landed{}", origin.url, match entry {
        Entry::EncryptedGet => "?first=alpha%2Bbeta&second=two", Entry::PlayPost => "",
    });
    let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    gzip.write_all(payload(entry, "second").as_bytes()).unwrap();
    let compressed = gzip.finish().unwrap();
    let second = serve(move |r| {
        assert_request(&r, entry); assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() != "/landed" {
            (StatusCode::TEMPORARY_REDIRECT, [("location", redirect.clone()),
                ("set-cookie", "fixture=must-not-persist; Path=/".into())]).into_response()
        } else { ([("content-encoding", "gzip")], compressed.clone()).into_response() }
    }).await;
    let site = AppGet::new();
    assert_eq!(fetch(&site, &origin.url, entry).await.unwrap(), expected(entry, "origin"));
    let store = Arc::new(crate::proxy::ProxyStore::new());
    custom(&store, &first.url);
    site.set_http_context(store.clone(), "appget-loopback");
    assert_eq!(fetch(&site, &origin.url, entry).await.unwrap(), expected(entry, "first"));
    custom(&store, &second.url);
    assert_eq!(fetch(&site, &origin.url, entry).await.unwrap(), expected(entry, "second"));
    assert_eq!(first.hits.lock().unwrap().len(), 1);
    let second_hits = second.hits.lock().unwrap().clone();
    assert_eq!(second_hits.len(), 2);
    assert_eq!(second_hits[0].body, second_hits[1].body);
    assert_eq!(second_hits[0].headers["app-api-verify-time"], second_hits[1].headers["app-api-verify-time"]);
    let encoding = origin.hits.lock().unwrap()[0].headers["accept-encoding"].clone();
    assert!(encoding.to_str().unwrap().contains("gzip"));
    for r in first.hits.lock().unwrap().iter().chain(second_hits.iter()) { assert_eq!(r.headers["accept-encoding"], encoding); }
    let rejected = serve(move |r| { assert_request(&r, entry); (StatusCode::BAD_GATEWAY, "fixture rejected").into_response() }).await;
    custom(&store, &rejected.url);
    assert!(fetch(&site, &origin.url, entry).await.unwrap_err().contains("HTTP 502"));
    assert_eq!(rejected.hits.lock().unwrap().len(), 1);
    let invalid = serve(move |r| { assert_request(&r, entry); "fixture invalid JSON".into_response() }).await;
    custom(&store, &invalid.url);
    assert!(fetch(&site, &origin.url, entry).await.unwrap_err().contains("不是合法 JSON"));
    assert_eq!(invalid.hits.lock().unwrap().len(), 1);
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    custom(&store, &format!("http://{}", unused.local_addr().unwrap())); drop(unused);
    assert!(fetch(&site, &origin.url, entry).await.is_err());
    assert_eq!(origin.hits.lock().unwrap().len(), 1, "failures cannot retry directly");
    store.set(crate::proxy::GLOBAL_PROXY, crate::proxy::ProxyConfig::default()).unwrap();
    assert_eq!(fetch(&site, &origin.url, entry).await.unwrap(), expected(entry, "origin"));
    assert_eq!(origin.hits.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn catalog_proxy_appget_encrypted_get_keeps_headers_and_policy() { exercise(Entry::EncryptedGet).await; }

#[tokio::test]
async fn catalog_proxy_appget_play_post_keeps_exact_bytes_and_policy() { exercise(Entry::PlayPost).await; }

async fn assert_list(state: &AppState, id: &str, label: &str) {
    let provider = state.registry.get(id).unwrap();
    let page = tokio::time::timeout(Duration::from_secs(3), provider.list(ListRequest {
        category_id: "1".into(), page: 2, ..Default::default()
    })).await.expect("loopback AppGet factory list exceeded fixture budget").unwrap();
    assert_eq!(page.items.len(), 1); assert_eq!(page.items[0].title, label);
    assert_eq!(page.page, 2); assert_eq!(page.total, Some(21));
}

fn list_payload(label: &str) -> String {
    encrypted(serde_json::json!({"recommend_list":[{"vod_id":71,"vod_name":label}],"total":21}))
}

#[tokio::test]
async fn catalog_proxy_appget_import_runtime_hot_change_and_restore() {
    let origin = serve(|_| StatusCode::IM_A_TEAPOT.into_response()).await;
    let base = origin.url.clone();
    let subscription = serde_json::json!({"sites":[{"key":"appget-local","name":"AppGet local",
        "type":3,"api":"csp_AppGet","ext":{"url":base,"dataKey":KEY,"dataIv":IV,
        "deviceId":"fixture-device","version":"fixture-version","ua":FIXTURE_UA}}]});
    let first = serve(move |r| {
        assert_eq!(r.uri.scheme_str(), Some("http"));
        if r.uri.path() == "/subscription.json" { return axum::Json(subscription.clone()).into_response(); }
        assert_headers(&r, Entry::EncryptedGet); assert_eq!(r.method, Method::GET); assert!(r.body.is_empty());
        match r.uri.path() {
            P_INIT => encrypted(serde_json::json!({"type_list":[{"type_id":1,"type_name":"电影"}],
                "recommend_list":[{"vod_id":70,"vod_name":"home fixture"}]})).into_response(),
            P_FILTER => { assert_eq!(r.uri.query(), Some("page=2&type_id=1")); list_payload("first").into_response() },
            _ => StatusCode::NOT_FOUND.into_response(),
        }
    }).await;
    let second = serve(|r| {
        assert_headers(&r, Entry::EncryptedGet); assert_eq!(r.method, Method::GET); assert!(r.body.is_empty());
        assert_eq!(r.uri.scheme_str(), Some("http")); assert_eq!(r.uri.path(), P_FILTER);
        assert_eq!(r.uri.query(), Some("page=2&type_id=1")); list_payload("second").into_response()
    }).await;
    let root = scratch("appget-proxy-factories"); let dir = root.join("data");
    std::fs::create_dir(&dir).unwrap(); std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = AppState::bootstrap(dir.clone()).await.unwrap(); custom(&state.proxy, &first.url);
    let report = tokio::time::timeout(Duration::from_secs(5), crate::tvbox::import_tvbox_config(
        &state, &format!("{}/subscription.json", origin.url)
    )).await.expect("loopback AppGet import exceeded fixture budget").unwrap();
    assert!(report["skipped"].as_array().unwrap().is_empty(), "{report}");
    let rows = report["imported"].as_array().unwrap(); assert_eq!(rows.len(), 1, "{report}");
    let row = &rows[0]; assert_eq!(row["api"], "csp_AppGet"); assert_eq!(row["categories"], 1);
    assert!(row["probeFailed"].is_null(), "{row}"); assert_eq!(row["persisted"], true);
    let id = row["id"].as_str().unwrap().to_string(); assert_list(&state, &id, "first").await;
    assert_eq!(first.hits.lock().unwrap().len(), 3, "subscription, home, runtime list");
    custom(&state.proxy, &second.url); assert_list(&state, &id, "second").await;
    drop(state); let restored = AppState::bootstrap(dir).await.unwrap(); assert_list(&restored, &id, "second").await;
    assert_eq!(second.hits.lock().unwrap().len(), 2); assert!(origin.hits.lock().unwrap().is_empty());
    drop(restored); let _ = std::fs::remove_dir_all(root);
}
