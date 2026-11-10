//! Independent v60/v2 synthetic response goldens and request inspectors.
//! No candidate engine/encoder is used to generate expected protocol responses.
use crate::csp::{app_drama::AppDrama, CspSite};
use serde_json::{json, Value};
use std::sync::Arc;
pub(super) const ZONE: &str = "/api/v5/find/app/zone";
pub(super) const LIST: &str = "/api/proto/v5/drama/category";
pub(super) const SEARCH: &str = "/api/proto/v5/drama/search";
pub(super) const DETAIL: &str = "/api/proto/v5/drama/getDetail";
pub(super) const PLAY: &str = "/api/proto/v5/videoUsableUrl";
use crate::csp::http_context::test_support::{custom, serve, Fixture, Request};
use aes::cipher::{block_padding::Pkcs7, BlockDecrypt, BlockDecryptMut, KeyInit, KeyIvInit};
use axum::{
    http::Method,
    response::{IntoResponse, Response},
};
use rsa::{pkcs8::DecodePrivateKey, Pkcs1v15Encrypt, RsaPrivateKey};

pub(super) fn fixtures() -> Value {
    serde_json::from_str(include_str!("app_drama_synthetic_fixtures.json")).unwrap()
}
fn decode64(value: &str) -> Vec<u8> {
    crate::csp::shared::b64_decode(value).unwrap()
}
fn unhex(value: &str) -> Vec<u8> {
    assert_eq!(value.len() % 2, 0);
    (0..value.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&value[at..at + 2], 16).unwrap())
        .collect()
}

// Independent fixture scanner, not the candidate Message reader/serializer.
fn sent_fields(input: &[u8]) -> Vec<(u64, u8, Vec<u8>)> {
    fn read(input: &[u8], at: &mut usize) -> u64 {
        let mut value = 0u64;
        for shift in (0..70).step_by(7) {
            let byte = input[*at];
            *at += 1;
            value |= u64::from(byte & 127) << shift;
            if byte & 128 == 0 {
                return value;
            }
        }
        panic!("fixture varint overflow")
    }
    let mut at = 0;
    let mut out = Vec::new();
    while at < input.len() {
        let tag = read(input, &mut at);
        let wire = (tag & 7) as u8;
        let value = match wire {
            0 => read(input, &mut at).to_le_bytes().to_vec(),
            2 => {
                let size = read(input, &mut at) as usize;
                let bytes = input[at..at + size].to_vec();
                at += size;
                bytes
            }
            _ => panic!("unexpected request wire"),
        };
        out.push((tag >> 3, wire, value));
    }
    out
}
fn sent_text(fields: &[(u64, u8, Vec<u8>)], number: u64) -> String {
    let (_, wire, bytes) = fields
        .iter()
        .find(|(field, _, _)| *field == number)
        .unwrap();
    assert_eq!(*wire, 2);
    String::from_utf8(bytes.clone()).unwrap()
}
fn sent_number(fields: &[(u64, u8, Vec<u8>)], number: u64) -> u64 {
    let (_, wire, bytes) = fields
        .iter()
        .find(|(field, _, _)| *field == number)
        .unwrap();
    assert_eq!(*wire, 0);
    u64::from_le_bytes(bytes.as_slice().try_into().unwrap())
}
fn nonce_shape(value: &str, size: usize) {
    assert_eq!(value.len(), size);
    assert!(value.ends_with('='));
    assert!(value[..size - 1]
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric()));
}
fn private(fixture: &Value, kind: &str) -> RsaPrivateKey {
    RsaPrivateKey::from_pkcs8_der(&decode64(
        fixture["rsaKeys"][kind]["privateDerBase64"]
            .as_str()
            .unwrap(),
    ))
    .unwrap()
}
fn decrypt_ecb(key: &[u8], data: &[u8]) -> Vec<u8> {
    assert_eq!(key.len(), 32);
    assert_eq!(data.len() % 16, 0);
    let cipher = aes::Aes256::new_from_slice(key).unwrap();
    let mut data = data.to_vec();
    for chunk in data.chunks_mut(16) {
        cipher.decrypt_block(aes::cipher::Block::<aes::Aes256>::from_mut_slice(chunk));
    }
    let padding = *data.last().unwrap() as usize;
    assert!((1..=16).contains(&padding));
    assert!(data[data.len() - padding..]
        .iter()
        .all(|byte| *byte as usize == padding));
    data.truncate(data.len() - padding);
    data
}
fn inspect_headers(request: &Request, fixture: &Value, kind: &str, proto: bool) {
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    assert_eq!(request.headers["user-agent"], "okhttp/3.12.1");
    let outer: Value =
        serde_json::from_str(request.headers["publicParams"].to_str().unwrap()).unwrap();
    assert_eq!(outer.as_object().unwrap().len(), 1);
    let mut cipher = unhex(outer["paramsData"].as_str().unwrap());
    let key = fixture["headerKeyIv"].as_str().unwrap().as_bytes();
    let decoded = cbc::Decryptor::<aes::Aes128>::new_from_slices(key, key)
        .unwrap()
        .decrypt_padded_mut::<Pkcs7>(&mut cipher)
        .unwrap();
    let descriptor: Value = serde_json::from_slice(decoded).unwrap();
    assert_eq!(descriptor["plat"], std::env::consts::OS);
    assert_eq!(descriptor["pkg"], "synthetic.desktop.fixture");
    assert_eq!(descriptor["vApp"], "000");
    assert!(descriptor.get("androidID").is_none());
    assert!(descriptor.get("cpuId").is_none());
    assert!(descriptor.get("mac").is_none());
    if proto {
        assert_eq!(request.headers["accept"], "application/x-protobuf");
        assert_eq!(request.headers["content-type"], "application/x-protobuf");
        let time = descriptor["timestamp"].as_u64().unwrap();
        let random = descriptor["random_str"].as_str().unwrap();
        nonce_shape(random, 16);
        let sign = decode64(descriptor["sig"].as_str().unwrap());
        assert_eq!(
            private(fixture, kind)
                .decrypt(Pkcs1v15Encrypt, &sign)
                .unwrap(),
            format!("{time}{random}000").as_bytes()
        );
        let aes = decode64(&format!(
            "{}{}",
            descriptor["sig2"].as_str().unwrap(),
            descriptor["sig3"].as_str().unwrap()
        ));
        assert_eq!(
            decrypt_ecb(fixture["dataIv"].as_str().unwrap().as_bytes(), &aes),
            format!("{time}{random}").as_bytes()
        );
    } else {
        assert_eq!(
            request.headers["content-type"],
            "application/json; charset=utf-8"
        );
        for name in ["sig", "sig2", "sig3", "random_str", "timestamp"] {
            assert!(descriptor.get(name).is_none());
        }
    }
}
fn inspect_secure(request: &Request, fixture: &Value) -> std::collections::HashMap<String, String> {
    let fields = sent_fields(&request.body);
    assert_eq!(fields.len(), 5);
    let time = sent_number(&fields, 4);
    let random = sent_text(&fields, 5);
    nonce_shape(&random, 8);
    nonce_shape(&sent_text(&fields, 3), 20);
    let joined = format!("{}{}", sent_text(&fields, 1), sent_text(&fields, 2));
    assert_eq!(sent_text(&fields, 1).len(), 20);
    assert!(joined.starts_with(&random));
    let text = String::from_utf8(decrypt_ecb(
        fixture["dataKey"].as_str().unwrap().as_bytes(),
        &decode64(&joined[8..]),
    ))
    .unwrap();
    let pairs = text.strip_suffix(&time.to_string()).unwrap();
    pairs
        .split('&')
        .map(|pair| {
            let (key, value) = pair.split_once('=').unwrap();
            (key.into(), value.into())
        })
        .collect()
}

#[derive(Clone, Copy)]
pub(super) enum ResponseMode {
    Normal,
    Gzip,
}

pub(super) fn ext_for(origin: &str) -> String {
    let fixture = fixtures();
    json!({
        "host": origin,
        "site": format!("{origin}/dispatch?first=alpha%2Bbeta&second=two"),
        "publicKey": fixture["rsaKeys"]["bootstrap"]["publicDerBase64"],
        "dataKey": fixture["dataKey"], "dataIv": fixture["dataIv"],
        "pkg": "synthetic.desktop.fixture", "appName": "Synthetic desktop",
        "version": "0.0.0"
    })
    .to_string()
}

fn response_body(mode: ResponseMode, media_type: &str, bytes: Vec<u8>) -> Response {
    match mode {
        ResponseMode::Normal => ([("content-type", media_type)], bytes).into_response(),
        ResponseMode::Gzip => {
            use std::io::Write;
            let mut encoder =
                flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            encoder.write_all(&bytes).unwrap();
            let encoded = encoder.finish().unwrap();
            assert_eq!(&encoded[..3], &[0x1f, 0x8b, 0x08]);
            (
                [("content-type", media_type), ("content-encoding", "gzip")],
                encoded,
            )
                .into_response()
        }
    }
}

pub(super) fn dispatch_headers(request: &Request) {
    assert_eq!(request.method, Method::GET);
    assert!(request.body.is_empty());
    assert_eq!(request.headers["user-agent"],
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36");
    assert_eq!(request.uri.query(), Some("first=alpha%2Bbeta&second=two"));
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    assert!(
        !request.headers.contains_key("publicparams"),
        "signed protocol headers do not belong on the dispatch hop"
    );
}

/// Serve the exact independent frozen envelopes, not values serialized by the
/// candidate implementation. Request decryption/inspection above is retained
/// from v60/v2 and never calls the candidate wire module.
pub(super) fn respond(
    request: &Request,
    fixture: &Value,
    domain: &str,
    mode: ResponseMode,
) -> Response {
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    if request.uri.path() == "/subscription.json" {
        assert_eq!(request.method, Method::GET);
        let ext: Value = serde_json::from_str(&ext_for(domain)).unwrap();
        let value = json!({"sites":[{"key":"drama-local", "name":"Drama local",
            "type":3, "api":"csp_AppDrama", "ext":ext}]});
        return response_body(
            mode,
            "application/json",
            serde_json::to_vec(&value).unwrap(),
        );
    }
    if request.uri.path() == "/dispatch" {
        dispatch_headers(request);
        return response_body(
            mode,
            "application/json",
            serde_json::to_vec(&json!({"domain":domain,"enabled":true})).unwrap(),
        );
    }
    if request.uri.path() == ZONE {
        assert_eq!(request.method, Method::POST);
        inspect_headers(request, fixture, "bootstrap", true);
        let fields = sent_fields(&request.body);
        let time = sent_number(&fields, 1);
        let random = sent_text(&fields, 4);
        nonce_shape(&random, 16);
        nonce_shape(&sent_text(&fields, 3), 16);
        nonce_shape(&sent_text(&fields, 5), 16);
        assert_eq!(
            private(fixture, "bootstrap")
                .decrypt(Pkcs1v15Encrypt, &decode64(&sent_text(&fields, 2)))
                .unwrap(),
            format!("{time}{random}").as_bytes()
        );
        return response_body(
            mode,
            "application/x-protobuf",
            unhex(fixture["zoneHex"].as_str().unwrap()),
        );
    }
    if request.uri.path() == "/api/v3/drama/getCategory" {
        assert_eq!(request.method, Method::GET);
        assert_eq!(request.uri.query(), Some("orderBy=type_id"));
        inspect_headers(request, fixture, "derived", false);
        return response_body(
            mode,
            "application/json",
            serde_json::to_vec(&fixture["categoryJson"]).unwrap(),
        );
    }
    assert_eq!(request.method, Method::POST);
    inspect_headers(request, fixture, "derived", true);
    let pairs = inspect_secure(request, fixture);
    let response_key = match request.uri.path() {
        LIST => {
            assert_eq!(pairs["typeId1"], "cat-one");
            assert!(matches!(pairs["page"].as_str(), "1" | "2"));
            assert_eq!(pairs["pagesize"], "21");
            assert_eq!(pairs["vodOrderBy"], "最新");
            "pageHex"
        }
        SEARCH => {
            assert_eq!(pairs["searchKeys"], "synthetic-query");
            assert_eq!(pairs["page"], "1");
            "pageHex"
        }
        DETAIL => {
            assert_eq!(pairs["id"], "1001");
            "detailHex"
        }
        PLAY => {
            assert_eq!(pairs["vodPlayFrom"], "source-b");
            assert_eq!(pairs["playUrl"], "opaque-selected|%2F+part");
            "playHex"
        }
        _ => panic!("unexpected public protocol operation: {}", request.uri),
    };
    response_body(
        mode,
        "application/x-protobuf",
        unhex(fixture[response_key].as_str().unwrap()),
    )
}

pub(super) struct PublicFixture {
    pub origin: Fixture,
    pub proxy: Fixture,
    pub store: Arc<crate::proxy::ProxyStore>,
    pub ext: String,
}

impl PublicFixture {
    pub async fn new(mode: ResponseMode) -> Self {
        let domain_slot = Arc::new(std::sync::Mutex::new(String::new()));
        let origin_domain = domain_slot.clone();
        let data = fixtures();
        let origin = serve(move |request| {
            let domain = origin_domain.lock().unwrap().clone();
            respond(&request, &data, &domain, mode)
        })
        .await;
        *domain_slot.lock().unwrap() = origin.url.clone();
        let domain = origin.url.clone();
        let data = fixtures();
        let proxy = serve(move |request| {
            assert_eq!(
                request.uri.scheme_str(),
                Some("http"),
                "HTTP proxy receives absolute-form loopback requests"
            );
            respond(&request, &data, &domain, mode)
        })
        .await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let ext = ext_for(&origin.url);
        Self {
            origin,
            proxy,
            store,
            ext,
        }
    }

    pub fn site(&self) -> AppDrama {
        let site = AppDrama::new();
        site.set_http_context(self.store.clone(), "appdrama-public-migration");
        site
    }

    pub fn assert_proxy_only(&self) {
        assert!(
            self.origin.hits.lock().unwrap().is_empty(),
            "a configured proxy must not silently retry directly"
        );
    }
}
