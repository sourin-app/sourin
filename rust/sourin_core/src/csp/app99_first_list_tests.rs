//! Cold default-provider directory requests must obtain their own session.
//! Fixtures use only loopback traffic and independently inspect signed bodies.
use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use axum::{http::{Method, StatusCode}, response::IntoResponse};
use crate::csp::http_context::test_support::{custom, serve, Fixture, Request};
use crate::model::TvboxCategoryEntry;
use crate::provider::{ListRequest, MediaProvider};
use serde_json::{json, Value};
use std::io::Write;
use std::sync::Arc;

const UUID_A: &str = "aabbccddeeff00112233445566778899";
const UUID_B: &str = "99887766554433221100ffeeddccbbaa";
const KEY_A: &[u8; 32] = b"aabbccddeeff00112233445566778899";
const KEY_B: &[u8; 32] = b"99887766554433221100ffeeddccbbaa";

fn open(request: &Request, uuid: &str, key: &[u8], token: &str) -> Value {
    assert_eq!(request.method, Method::POST);
    assert_eq!(request.headers["uuid"], uuid);
    assert_eq!(request.headers["content-type"], "application/json; charset=utf-8");
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    let encrypted = std::str::from_utf8(&request.body).unwrap();
    let mut bytes = crate::csp::shared::b64_decode(encrypted).unwrap();
    let (iv, ciphertext) = bytes.split_at_mut(16);
    let plaintext = cbc::Decryptor::<aes::Aes256>::new_from_slices(key, iv).unwrap()
        .decrypt_padded_mut::<Pkcs7>(ciphertext).unwrap();
    let value: Value = serde_json::from_slice(plaintext).unwrap();
    assert_eq!(value["token"], token);
    assert_eq!(value["timestamp"], request.headers["timestamp"].to_str().unwrap());
    assert_eq!(value["nonce"], request.headers["nonce"].to_str().unwrap());
    let signed = format!("{encrypted}:{}:{}:{token}",
        request.headers["timestamp"].to_str().unwrap(),
        request.headers["nonce"].to_str().unwrap());
    let digest = ring::digest::digest(&ring::digest::SHA256, signed.as_bytes());
    let expected: String = digest.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
    assert_eq!(request.headers["sign"], expected);
    value
}

fn seal(value: &Value, key: &[u8]) -> String {
    // Independent response encoder, not App99 encrypt/decrypt/request builders.
    let mut zlib = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    zlib.write_all(value.to_string().as_bytes()).unwrap();
    let compressed = zlib.finish().unwrap();
    let iv = [0x42u8; 16];
    let mut buffer = vec![0; (compressed.len() / 16 + 1) * 16];
    buffer[..compressed.len()].copy_from_slice(&compressed);
    let encrypted = cbc::Encryptor::<aes::Aes256>::new_from_slices(key, &iv).unwrap()
        .encrypt_padded_mut::<Pkcs7>(&mut buffer, compressed.len()).unwrap();
    crate::csp::shared::b64_encode(&[iv.as_slice(), encrypted].concat())
}

struct DirectoryFixture {
    origin: Fixture,
    proxy: Fixture,
    store: Arc<crate::proxy::ProxyStore>,
    ext: String,
}

impl DirectoryFixture {
    async fn new(uuid: &'static str, key: &'static [u8], label: &'static str, denied: bool) -> Self {
        let origin = serve(|_| panic!("cold directory requests must respect the selected proxy")).await;
        let token = format!("synthetic-directory-{label}");
        let proxy = serve(move |request| {
            // A stale source identity gets a deterministic local denial. The
            // baseline must fail on returned behavior, not a server task panic.
            if request.headers.get("uuid").and_then(|value| value.to_str().ok()) != Some(uuid) {
                return StatusCode::BAD_REQUEST.into_response();
            }
            let expected_token = if request.uri.path() == "/app/systemInit" { "" } else { &token };
            let value = open(&request, uuid, key, expected_token);
            let response = match request.uri.path() {
                "/app/systemInit" => {
                    assert_eq!(value["v"], "3.5.8");
                    if denied { return StatusCode::BAD_GATEWAY.into_response(); }
                    // The existing protocol explicitly accepts a bootstrap's
                    // direct token. No real or synthetic guest endpoint is used.
                    json!({"code":0,"categorys":{"data":[{"id":"2","name":"Synthetic directory"}]},
                        "userInfo":{"user_token":token}})
                }
                "/vod/search" => {
                    assert_eq!(value["kw"], "");
                    assert_eq!(value["pid"], "2");
                    assert_eq!(value["page"], "3");
                    assert_eq!(value["limit"], 21);
                    assert_eq!(value["isCategory"], 1);
                    assert_eq!(value["orderBy"], "time");
                    json!({"code":0,"data":[{"id":202,"name":label}]})
                }
                _ => panic!("unexpected directory request"),
            };
            seal(&response, key).into_response()
        }).await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let ext = json!({"host":origin.url,"name":"synthetic-app","buildSignature":"FIXTURE-SIG",
            "buildNumber":"2001","versionName":"3.5.8","package":"synthetic.desktop",
            "uuid":uuid}).to_string();
        Self { origin, proxy, store, ext }
    }

    fn provider(&self) -> crate::csp::provider::CspProvider {
        crate::csp::provider::CspProvider::new(
            "synthetic-cold-directory", "Synthetic directory", "csp_App99", &self.ext,
            vec![TvboxCategoryEntry { id:"2".into(), name:"Saved category".into(), pid:None }],
            true, false,
        ).unwrap().with_proxy(self.store.clone())
    }

    fn assert_routes(&self, routes: &[&str]) {
        assert!(self.origin.hits.lock().unwrap().is_empty(), "no origin fallback");
        let hits = self.proxy.hits.lock().unwrap();
        assert_eq!(hits.iter().map(|hit| hit.uri.path()).collect::<Vec<_>>(), routes);
        let origin = reqwest::Url::parse(&self.origin.url).unwrap();
        assert!(hits.iter().all(|hit|
            hit.uri.host() == origin.host_str() && hit.uri.port_u16() == origin.port()),
            "each signed request retains the exact configured source authority");
    }
}

fn directory_request() -> ListRequest {
    ListRequest { category_id:"2".into(), page:3, ..Default::default() }
}

#[tokio::test]
async fn app99_first_list_restored_categories_bootstrap_on_the_default_provider_path() {
    let fixture = DirectoryFixture::new(UUID_A, KEY_A, "Restored result", false).await;
    let provider = fixture.provider();
    assert_eq!(provider.home().await.unwrap()[0].title, "Saved category");
    assert_eq!(provider.categories().await.unwrap()[0].name, "Saved category");
    fixture.assert_routes(&[]);
    let page = provider.list(directory_request()).await
        .expect("a fresh restored provider must bootstrap before its first category request");
    assert_eq!(page.items[0].id.native, "202");
    assert_eq!(page.items[0].title, "Restored result");
    assert_eq!(page.page, 3);
    provider.list(directory_request()).await.unwrap();
    fixture.assert_routes(&["/app/systemInit", "/vod/search", "/vod/search"]);
}

#[tokio::test]
async fn app99_first_list_rechecks_ext_before_reusing_a_different_source_session() {
    use crate::csp::{app99::App99, CspSite};
    let first = DirectoryFixture::new(UUID_A, KEY_A, "First source", false).await;
    let second = DirectoryFixture::new(UUID_B, KEY_B, "Second source", false).await;
    let site = App99::new();
    site.set_http_context(first.store.clone(), "synthetic-ext-change");
    site.home(&first.ext).await.unwrap();
    custom(&first.store, &second.proxy.url);
    let page = site.list("2", 3, &second.ext).await
        .expect("list must bind its configured ext before signing business requests");
    assert_eq!(page.items[0].title, "Second source");
    first.assert_routes(&["/app/systemInit"]);
    second.assert_routes(&["/app/systemInit", "/vod/search"]);
}

#[tokio::test]
async fn app99_first_list_bootstrap_failure_stops_before_business_and_never_retries_directly() {
    let fixture = DirectoryFixture::new(UUID_A, KEY_A, "Denied source", true).await;
    let error = fixture.provider().list(directory_request()).await.unwrap_err();
    assert!(error.message.contains("HTTP 502"), "the actual bootstrap failure must surface: {}", error.message);
    assert!(!error.message.contains(&fixture.origin.url));
    fixture.assert_routes(&["/app/systemInit"]);
}
