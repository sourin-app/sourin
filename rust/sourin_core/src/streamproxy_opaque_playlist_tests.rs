//! Real HTTP requests through the production forwarding/token boundary.
use super::*;
use crate::proxy::ProxyStore;
use axum::http::Request;
use std::convert::Infallible;
use std::time::Duration;

#[derive(Clone)]
struct Fixture {
    origin: String,
    hits: Arc<Mutex<Vec<(String, HeaderMap)>>>,
    release: Arc<tokio::sync::Notify>,
}

struct Chunks(mpsc::Receiver<Bytes>);
impl futures_core::Stream for Chunks {
    type Item = Result<Bytes, Infallible>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.0.poll_recv(cx).map(|item| item.map(Ok))
    }
}

fn playlist(origin: &str) -> String {
    format!("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"{origin}/key?sign=k%2fY\"\n#EXTINF:10,\n{origin}/segment?token=a%2fb+Q&time=42\n#EXT-X-ENDLIST\n")
}

fn binary() -> Vec<u8> {
    let mut body = b"#EXTM3UX\0".to_vec();
    body.extend((0..300_000).map(|i| (i % 251) as u8));
    body
}

async fn respond(State(fixture): State<Fixture>, req: Request<Body>) -> Response {
    fixture
        .hits
        .lock()
        .unwrap()
        .push((req.uri().to_string(), req.headers().clone()));
    let path = req.uri().path();
    if path == "/redirect" {
        return Response::builder()
            .status(302)
            .header(header::LOCATION, "/effective/root.m3u8")
            .body(Body::empty())
            .unwrap();
    }
    let text = playlist(&fixture.origin);
    let mut out = Response::builder().header(
        header::CONTENT_TYPE,
        if path == "/mime" {
            "application/vnd.apple.mpegurl"
        } else {
            "application/octet-stream"
        },
    );
    if path == "/fragmented" || path == "/stalled" {
        let (tx, rx) = mpsc::channel(4);
        let stalled = path == "/stalled";
        tokio::spawn(async move {
            if stalled {
                tx.send(Bytes::from_static(b"#")).await.unwrap();
                fixture.release.notified().await;
                let _ = tx.send(Bytes::from_static(b"tail\0\xff")).await;
            } else {
                for bytes in [b"\xef".as_slice(), b"\xbb\xbf#EX", b"TM3U\r", b"\n"] {
                    tx.send(Bytes::copy_from_slice(bytes)).await.unwrap();
                    tokio::time::sleep(Duration::from_millis(15)).await;
                }
                let _ = tx
                    .send(Bytes::copy_from_slice(
                        text.strip_prefix("#EXTM3U\n").unwrap().as_bytes(),
                    ))
                    .await;
            }
        });
        return out.body(Body::from_stream(Chunks(rx))).unwrap();
    }
    let body = match path {
        "/opaque"
        | "/mime"
        | "/effective/root.m3u8"
        | "/known-gzip.m3u8"
        | "/opaque-gzip"
        | "/partial" => text.into_bytes(),
        "/binary" | "/ignored-range" => binary(),
        "/segment" => b"segment\0\xff".to_vec(),
        "/key" => b"key-bytes".to_vec(),
        _ => b"ordinary bytes".to_vec(),
    };
    if path == "/partial" {
        out = out
            .status(206)
            .header(
                header::CONTENT_RANGE,
                format!("bytes 0-{}/{}", body.len() - 1, body.len()),
            )
            .header(header::ACCEPT_RANGES, "bytes");
    }
    if path.contains("gzip") {
        use std::io::Write;
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(&body).unwrap();
        let encoded = encoder.finish().unwrap();
        return out
            .header(header::CONTENT_ENCODING, "gzip")
            .header(header::CONTENT_LENGTH, encoded.len())
            .body(Body::from(encoded))
            .unwrap();
    }
    out.header(header::CONTENT_LENGTH, body.len())
        .body(Body::from(body))
        .unwrap()
}

async fn setup() -> (Arc<StreamProxy>, Fixture, reqwest::Client) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let state = Fixture {
        origin: format!("http://{}", listener.local_addr().unwrap()),
        hits: Arc::new(Mutex::new(Vec::new())),
        release: Arc::new(tokio::sync::Notify::new()),
    };
    let app = Router::new().fallback(respond).with_state(state.clone());
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let proxy = Arc::new(StreamProxy::with_proxy_store(Arc::new(ProxyStore::new())));
    let client = reqwest::Client::builder()
        .no_proxy()
        .no_gzip()
        .no_deflate()
        .no_brotli()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();
    (proxy, state, client)
}

async fn local(proxy: &Arc<StreamProxy>, fixture: &Fixture, path: &str) -> String {
    maybe_proxy(
        proxy,
        &format!("{}{path}", fixture.origin),
        &[
            ("Referer".into(), "https://fixture.invalid/view".into()),
            ("User-Agent".into(), "OpaquePlaylistFixture".into()),
        ],
        true,
    )
    .await
    .unwrap()
    .unwrap()
}

async fn assert_rewritten(
    proxy: &Arc<StreamProxy>,
    fixture: &Fixture,
    client: &reqwest::Client,
    path: &str,
) {
    let local = local(proxy, fixture, path).await;
    let response = client.get(&local).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers()[header::CONTENT_TYPE],
        "application/vnd.apple.mpegurl",
        "opaque real HLS must enter the same rewriting boundary"
    );
    assert!(!response.headers().contains_key(header::CONTENT_ENCODING));
    let text = response.text().await.unwrap();
    let segment = text
        .lines()
        .find(|line| !line.is_empty() && !line.starts_with('#') && !line.starts_with('\u{feff}'))
        .unwrap();
    assert!(
        proxy.owns_url(segment),
        "absolute child must use the original token proxy"
    );
    let key = text
        .split_once("URI=\"")
        .unwrap()
        .1
        .split('"')
        .next()
        .unwrap();
    assert!(proxy.owns_url(key));
    assert_eq!(
        segment.split("/p/").nth(1).unwrap().split('/').next(),
        key.split("/p/").nth(1).unwrap().split('/').next()
    );
    assert_eq!(
        &client
            .get(segment)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()[..],
        b"segment\0\xff"
    );
    assert_eq!(
        client.get(key).send().await.unwrap().text().await.unwrap(),
        "key-bytes"
    );
    let hits = fixture.hits.lock().unwrap();
    assert!(hits
        .iter()
        .any(|hit| hit.0 == "/segment?token=a%2fb+Q&time=42"));
    assert!(hits.iter().any(|hit| hit.0 == "/key?sign=k%2fY"));
    assert!(hits
        .iter()
        .all(|hit| hit.1[header::REFERER] == "https://fixture.invalid/view"));
    assert!(hits
        .iter()
        .all(|hit| hit.1[header::USER_AGENT] == "OpaquePlaylistFixture"));
}

#[tokio::test]
async fn opaque_hls_rewrites_absolute_children_with_original_token_headers_and_query() {
    let (proxy, fixture, client) = setup().await;
    assert_rewritten(&proxy, &fixture, &client, "/opaque").await;
}

#[tokio::test]
async fn fragmented_bom_hls_without_suffix_is_rewritten_without_losing_prefix() {
    let (proxy, fixture, client) = setup().await;
    assert_rewritten(&proxy, &fixture, &client, "/fragmented").await;
}

#[tokio::test]
async fn recognized_mime_redirect_and_compressed_hls_keep_rewriting() {
    for path in ["/mime", "/redirect", "/known-gzip.m3u8"] {
        let (proxy, fixture, client) = setup().await;
        assert_rewritten(&proxy, &fixture, &client, path).await;
    }
}

#[tokio::test]
async fn opaque_binary_false_signature_streams_all_bytes_unchanged() {
    let (proxy, fixture, client) = setup().await;
    let response = client
        .get(local(&proxy, &fixture, "/binary").await)
        .send()
        .await
        .unwrap();
    assert_eq!(
        response.headers()[header::CONTENT_TYPE],
        "application/octet-stream"
    );
    assert_eq!(
        response.headers()[header::CONTENT_LENGTH],
        binary().len().to_string()
    );
    assert_eq!(response.bytes().await.unwrap().as_ref(), binary());
}

#[tokio::test]
async fn opaque_range_and_ignored_range_do_not_rewrite_or_change_bytes() {
    for path in ["/partial", "/ignored-range"] {
        let (proxy, fixture, client) = setup().await;
        let response = client
            .get(local(&proxy, &fixture, path).await)
            .header(header::RANGE, "bytes=0-4095")
            .send()
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            if path == "/partial" {
                StatusCode::PARTIAL_CONTENT
            } else {
                StatusCode::OK
            }
        );
        assert_eq!(
            response.headers()[header::CONTENT_TYPE],
            "application/octet-stream"
        );
        if path == "/partial" {
            assert!(response.headers().contains_key(header::CONTENT_RANGE));
        }
        let expected = if path == "/partial" {
            playlist(&fixture.origin).into_bytes()
        } else {
            binary()
        };
        assert_eq!(response.bytes().await.unwrap().as_ref(), expected);
        assert_eq!(
            fixture.hits.lock().unwrap()[0].1[header::RANGE],
            "bytes=0-4095"
        );
    }
}

#[tokio::test]
async fn opaque_compressed_body_keeps_encoding_and_exact_wire_bytes() {
    let (proxy, fixture, client) = setup().await;
    let direct = client
        .get(format!("{}/opaque-gzip", fixture.origin))
        .send()
        .await
        .unwrap()
        .bytes()
        .await
        .unwrap();
    let response = client
        .get(local(&proxy, &fixture, "/opaque-gzip").await)
        .send()
        .await
        .unwrap();
    assert_eq!(response.headers()[header::CONTENT_ENCODING], "gzip");
    assert_eq!(
        response.headers()[header::CONTENT_TYPE],
        "application/octet-stream"
    );
    assert_eq!(response.bytes().await.unwrap(), direct);
}

#[tokio::test]
async fn ambiguous_prefix_cannot_wait_for_eof_and_is_replayed_after_deadline() {
    let (proxy, fixture, client) = setup().await;
    let start = std::time::Instant::now();
    let response = tokio::time::timeout(
        Duration::from_secs(2),
        client.get(local(&proxy, &fixture, "/stalled").await).send(),
    )
    .await
    .expect("prefix sniff must be bounded even before upstream EOF")
    .unwrap();
    let mut stream = Box::pin(response.bytes_stream());
    let first = tokio::time::timeout(
        Duration::from_secs(2),
        std::future::poll_fn(|cx| stream.as_mut().poll_next(cx)),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    assert_eq!(first.as_ref(), b"#");
    assert!(start.elapsed() < Duration::from_secs(2));
    fixture.release.notify_one();
    let mut rest = Vec::new();
    while let Some(chunk) = std::future::poll_fn(|cx| stream.as_mut().poll_next(cx)).await {
        rest.extend_from_slice(&chunk.unwrap());
    }
    assert_eq!(rest, b"tail\0\xff");
}

#[tokio::test]
async fn initial_decoder_range_receiving_full_opaque_hls_is_rewritten() {
    let (proxy, fixture, client) = setup().await;
    let response = client
        .get(local(&proxy, &fixture, "/opaque").await)
        .header(header::RANGE, "bytes=0-")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response.headers()[header::CONTENT_TYPE],
        "application/vnd.apple.mpegurl"
    );
    let text = response.text().await.unwrap();
    assert!(text.starts_with("#EXTM3U\n"));
    let segment = text
        .lines()
        .find(|line| !line.is_empty() && !line.starts_with('#'))
        .unwrap();
    assert!(proxy.owns_url(segment));
    assert_eq!(
        client
            .get(segment)
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
            .as_ref(),
        b"segment\0\xff"
    );
    let hits = fixture.hits.lock().unwrap();
    assert_eq!(hits[0].1[header::RANGE], "bytes=0-");
    assert!(hits
        .iter()
        .any(|hit| hit.0 == "/segment?token=a%2fb+Q&time=42"));
    assert!(hits
        .iter()
        .all(|hit| hit.1[header::REFERER] == "https://fixture.invalid/view"));
}
