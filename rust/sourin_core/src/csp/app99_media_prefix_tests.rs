//! Default selected playback keeps media signatures that cross HTTP chunks.
//! This verifies candidate selection and HTTP prefix handling, not decoding.
use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use axum::{body::{Body, Bytes}, http::{Method, header}, response::{IntoResponse, Response}};
use crate::csp::http_context::test_support::{custom, serve, Fixture, Request};
use crate::model::{MediaId, PlayRequest};
use crate::provider::MediaProvider;
use futures_core::Stream;
use serde_json::{json, Value};
use std::{future::Future, io::Write, pin::Pin, sync::Arc, task::{Context, Poll}, time::Duration};

const UUID: &str = "aabbccddeeff00112233445566778899";
const KEY: &[u8; 32] = b"aabbccddeeff00112233445566778899";
const TOKEN: &str = "synthetic-media-prefix-token";

fn open(request: &Request, token: &str) -> Value {
    assert_eq!(request.method, Method::POST);
    assert_eq!(request.headers["uuid"], UUID);
    assert!(!request.headers.contains_key("cookie"));
    assert!(!request.headers.contains_key("authorization"));
    let encoded = std::str::from_utf8(&request.body).unwrap();
    let mut bytes = crate::csp::shared::b64_decode(encoded).unwrap();
    let (iv, ciphertext) = bytes.split_at_mut(16);
    let plain = cbc::Decryptor::<aes::Aes256>::new_from_slices(KEY, iv).unwrap()
        .decrypt_padded_mut::<Pkcs7>(ciphertext).unwrap();
    let value: Value = serde_json::from_slice(plain).unwrap();
    assert_eq!(value["token"], token);
    assert_eq!(value["timestamp"], request.headers["timestamp"].to_str().unwrap());
    assert_eq!(value["nonce"], request.headers["nonce"].to_str().unwrap());
    let signed = format!("{encoded}:{}:{}:{token}",
        request.headers["timestamp"].to_str().unwrap(), request.headers["nonce"].to_str().unwrap());
    let hash = ring::digest::digest(&ring::digest::SHA256, signed.as_bytes());
    let expected: String = hash.as_ref().iter().map(|byte| format!("{byte:02x}")).collect();
    assert_eq!(request.headers["sign"], expected);
    value
}

fn seal(value: &Value) -> String {
    // Independent response encryption; never candidate request/response helpers.
    let mut zlib = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    zlib.write_all(value.to_string().as_bytes()).unwrap();
    let compressed = zlib.finish().unwrap();
    let iv = [0x31u8; 16];
    let mut buffer = vec![0; (compressed.len() / 16 + 1) * 16];
    buffer[..compressed.len()].copy_from_slice(&compressed);
    let encrypted = cbc::Encryptor::<aes::Aes256>::new_from_slices(KEY, &iv).unwrap()
        .encrypt_padded_mut::<Pkcs7>(&mut buffer, compressed.len()).unwrap();
    crate::csp::shared::b64_encode(&[iv.as_slice(), encrypted].concat())
}

struct TwoChunks {
    first: Option<Bytes>,
    rest: Option<Bytes>,
    delayed: Pin<Box<tokio::time::Sleep>>,
    pending_after_first: bool,
}

impl Stream for TwoChunks {
    type Item = std::result::Result<Bytes, std::io::Error>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        if let Some(first) = self.first.take() { return Poll::Ready(Some(Ok(first))); }
        if self.pending_after_first { return Poll::Pending; }
        if self.delayed.as_mut().poll(cx).is_pending() { return Poll::Pending; }
        Poll::Ready(self.rest.take().map(Ok))
    }
}

#[derive(Clone, Copy)]
enum MediaMode { FragmentedMp4, FragmentedHls, FragmentedHtml, PrefixLimit }

fn media(mode: MediaMode) -> Response {
    let (first, rest, pending) = match mode {
        MediaMode::FragmentedMp4 => (Bytes::from_static(b"\0\0\0"), Bytes::from_static(b"\x20ftypisom"), false),
        MediaMode::FragmentedHls => (Bytes::from_static(b"#EX"), Bytes::from_static(b"TM3U\n#EXTINF:1,\nsegment.ts\n"), false),
        MediaMode::FragmentedHtml => (Bytes::from_static(b"<ht"), Bytes::from_static(b"ml>synthetic error page</html>"), false),
        MediaMode::PrefixLimit => (Bytes::from(vec![b'x'; 512]), Bytes::new(), true),
    };
    let body = Body::from_stream(TwoChunks { first:Some(first), rest:Some(rest),
        delayed:Box::pin(tokio::time::sleep(Duration::from_millis(120))), pending_after_first:pending });
    let mut response = Response::new(body);
    response.headers_mut().insert(header::CONTENT_TYPE, header::HeaderValue::from_static("application/octet-stream"));
    response
}

struct PlaybackFixture { origin:Fixture, proxy:Fixture, store:Arc<crate::proxy::ProxyStore>, ext:String }

impl PlaybackFixture {
    async fn new(mode: MediaMode) -> Self {
        let origin = serve(|_| panic!("all default playback requests must remain on the configured proxy")).await;
        let resource = format!("{}/resource", origin.url);
        let parser_result = resource.clone();
        let proxy = serve(move |request| {
            if request.uri.path() == "/resource" {
                assert_eq!(request.method, Method::GET);
                assert_eq!(request.headers["range"], "bytes=0-511");
                assert!(!request.headers.contains_key("cookie"));
                assert!(!request.headers.contains_key("authorization"));
                return media(mode);
            }
            let value = open(&request, if request.uri.path() == "/app/systemInit" { "" } else { TOKEN });
            let response = match request.uri.path() {
                "/app/systemInit" => json!({"code":0,"userInfo":{"user_token":TOKEN},
                    "player":{"synthetic-line":{"name":"Synthetic line","type":1,"parseUrl":"7"}},
                    "parser_api":[{"id":7}]}),
                "/vod/detail" => {
                    assert_eq!(value["id"], "77");
                    json!({"code":0,"data":{"id":"77","name":"Synthetic title",
                        "play_from":"synthetic-line","play_url":"Selected episode$opaque-selected"}})
                }
                "/app/vodParser" => {
                    assert_eq!(value["id"], 7);
                    assert_eq!(value["url"], "opaque-selected");
                    json!({"code":0,"data":parser_result})
                }
                _ => panic!("unexpected default selected-play request"),
            };
            seal(&response).into_response()
        }).await;
        let store = Arc::new(crate::proxy::ProxyStore::new());
        custom(&store, &proxy.url);
        let ext = json!({"host":origin.url,"name":"synthetic-app","buildSignature":"FIXTURE-SIG",
            "buildNumber":"2001","versionName":"3.5.8","package":"synthetic.desktop","uuid":UUID}).to_string();
        Self { origin, proxy, store, ext }
    }

    async fn resolve(&self) -> crate::model::Result<Vec<crate::model::StreamCandidate>> {
        let provider = crate::csp::provider::CspProvider::new("synthetic-media-prefix", "Synthetic media prefix",
            "csp_App99", &self.ext, vec![], false, false).unwrap().with_proxy(self.store.clone());
        let id = MediaId::new("synthetic-media-prefix", "77");
        let detail = provider.detail(&id).await.unwrap();
        assert_eq!(detail.episodes[0].title, "Selected episode");
        let selected = &detail.episodes[0];
        let request = PlayRequest { episode_id:Some(selected.id.clone()), flag:Some(selected.flag.clone()),
            episode_title:Some(selected.title.clone()), episode_order:Some(1), ..Default::default() };
        provider.resolve(&id, &request).await
    }

    fn assert_routes(&self) {
        assert!(self.origin.hits.lock().unwrap().is_empty());
        assert_eq!(self.proxy.hits.lock().unwrap().iter().map(|hit| hit.uri.path()).collect::<Vec<_>>(),
            ["/app/systemInit", "/vod/detail", "/app/vodParser", "/resource"],
            "one selected parser and one bounded media prefix request, no fallback");
    }
}

#[tokio::test]
async fn app99_media_prefix_default_selected_play_accepts_signatures_across_http_chunks() {
    for mode in [MediaMode::FragmentedMp4, MediaMode::FragmentedHls] {
        let fixture = PlaybackFixture::new(mode).await;
        let candidates = tokio::time::timeout(Duration::from_secs(3), fixture.resolve()).await.unwrap()
            .expect("selected media must not be discarded because its signature crosses HTTP chunks");
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].url, format!("{}/resource", fixture.origin.url));
        fixture.assert_routes();
    }
}

#[tokio::test]
async fn app99_media_prefix_non_media_and_512_byte_limit_remain_bounded_errors() {
    for mode in [MediaMode::FragmentedHtml, MediaMode::PrefixLimit] {
        let fixture = PlaybackFixture::new(mode).await;
        let error = tokio::time::timeout(Duration::from_secs(3), fixture.resolve()).await
            .expect("invalid prefix must stop without reading beyond the existing 512-byte bound")
            .unwrap_err();
        assert!(!error.message.contains(&fixture.origin.url));
        fixture.assert_routes();
    }
}
