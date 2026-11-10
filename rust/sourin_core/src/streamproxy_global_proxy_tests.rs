use super::*;
use crate::proxy::{ProxyConfig, ProxyMode, ProxyScope, ProxyStore, GLOBAL_PROXY};
use axum::extract::ConnectInfo;
use axum::http::Request;
use std::collections::HashSet;
use std::net::SocketAddr;

#[derive(Clone)]
struct Endpoint {
    marker: &'static str,
    seen: Arc<Mutex<Vec<(u16, String, HeaderMap)>>>,
    store_change: Option<(Arc<ProxyStore>, ProxyConfig)>,
}

async fn serve_endpoint(
    State(endpoint): State<Endpoint>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request<Body>,
) -> Response {
    endpoint
        .seen
        .lock()
        .unwrap()
        .push((addr.port(), req.uri().to_string(), req.headers().clone()));
    let path = req.uri().path();
    if path.ends_with("prefetch.mp4") {
        let total = PREFETCH_WINDOW * 2 + 19;
        let range = req
            .headers()
            .get(header::RANGE)
            .and_then(|v| v.to_str().ok());
        let (start, end) = match range {
            Some(range) => {
                let (start, end) = range
                    .strip_prefix("bytes=")
                    .unwrap()
                    .split_once('-')
                    .unwrap();
                (
                    start.parse::<usize>().unwrap(),
                    end.parse::<usize>().unwrap_or(total - 1),
                )
            }
            None => (0, total - 1),
        };
        let data = (start..=end).map(|i| (i % 251) as u8).collect::<Vec<_>>();
        return Response::builder()
            .status(if range.is_some() {
                StatusCode::PARTIAL_CONTENT
            } else {
                StatusCode::OK
            })
            .header(header::CONTENT_TYPE, "video/mp4")
            .header(header::ACCEPT_RANGES, "bytes")
            .header(header::CONTENT_LENGTH, data.len())
            .header(
                header::CONTENT_RANGE,
                format!("bytes {start}-{end}/{total}"),
            )
            .body(Body::from(data))
            .unwrap();
    }
    let text = if path.ends_with("master.m3u8") {
        if let Some((store, cfg)) = &endpoint.store_change {
            store.set(GLOBAL_PROXY, cfg.clone()).unwrap();
        }
        "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8\n".to_string()
    } else if path.ends_with("child.m3u8") || path.ends_with("gzip.m3u8") {
        "#EXTM3U\n#EXTINF:7,\nsegment.ts\n#EXT-X-ENDLIST\n".to_string()
    } else {
        endpoint.marker.to_string()
    };
    let mut out = Response::builder().header(
        header::CONTENT_TYPE,
        if path.ends_with(".m3u8") {
            "application/vnd.apple.mpegurl"
        } else {
            "video/mp2t"
        },
    );
    if path.ends_with("gzip.m3u8") || path.ends_with("gzip.png") {
        use std::io::Write;
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(text.as_bytes()).unwrap();
        return out
            .header(header::CONTENT_ENCODING, "gzip")
            .body(Body::from(encoder.finish().unwrap()))
            .unwrap();
    }
    if let Some(range) = req
        .headers()
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
    {
        let (start, end) = range
            .strip_prefix("bytes=")
            .unwrap()
            .split_once('-')
            .unwrap();
        let start: usize = start.parse().unwrap();
        let end: usize = end.parse().unwrap();
        out = out.status(StatusCode::PARTIAL_CONTENT).header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{}", text.len()),
        );
        return out
            .body(Body::from(text.as_bytes()[start..=end].to_vec()))
            .unwrap();
    }
    out.body(Body::from(text)).unwrap()
}

async fn endpoint(
    marker: &'static str,
    change: Option<(Arc<ProxyStore>, ProxyConfig)>,
) -> (String, Endpoint) {
    let state = Endpoint {
        marker,
        seen: Arc::new(Mutex::new(Vec::new())),
        store_change: change,
    };
    let app = Router::new()
        .fallback(serve_endpoint)
        .with_state(state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .unwrap();
    });
    (base, state)
}

fn config(url: &str, scope: ProxyScope) -> ProxyConfig {
    ProxyConfig {
        mode: ProxyMode::Custom,
        url: Some(url.into()),
        scope,
        ..ProxyConfig::default()
    }
}

fn direct_client() -> reqwest::Client {
    reqwest::Client::builder()
        .no_proxy()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .unwrap()
}

fn candidate(url: String) -> crate::model::StreamCandidate {
    crate::model::StreamCandidate::new(url, crate::model::StreamKind::Hls)
}

#[tokio::test]
async fn global_scope_updates_existing_wrapper_without_direct_fallback() {
    let (origin, origin_state) = endpoint("origin", None).await;
    let (proxy_a, a) = endpoint("proxy-a", None).await;
    let (proxy_b, b) = endpoint("proxy-b", None).await;
    let store = Arc::new(ProxyStore::new());
    store
        .set(GLOBAL_PROXY, config(&proxy_a, ProxyScope::All))
        .unwrap();
    let stream = Arc::new(StreamProxy::with_proxy_store(store.clone()));
    let url = format!("{origin}/video.mp4?token=private-fixture");
    let local = maybe_proxy(&stream, &url, &[], false)
        .await
        .unwrap()
        .unwrap();
    assert!(maybe_proxy(&stream, &local, &[], false)
        .await
        .unwrap()
        .is_none());
    let client = direct_client();
    for _ in 0..3 {
        assert_eq!(
            client
                .get(&local)
                .send()
                .await
                .unwrap()
                .text()
                .await
                .unwrap(),
            "proxy-a"
        );
    }
    assert_eq!(a.seen.lock().unwrap().len(), 3);
    assert_eq!(
        a.seen
            .lock()
            .unwrap()
            .iter()
            .map(|v| v.0)
            .collect::<HashSet<_>>()
            .len(),
        1,
        "Stream clients must reuse their connection pool"
    );
    assert!(origin_state.seen.lock().unwrap().is_empty());

    store
        .set(GLOBAL_PROXY, config(&proxy_a, ProxyScope::ApiOnly))
        .unwrap();
    assert!(maybe_proxy(&stream, &url, &[], false)
        .await
        .unwrap()
        .is_none());
    assert_eq!(
        client
            .get(&local)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap(),
        "origin"
    );
    store
        .set(GLOBAL_PROXY, config(&proxy_b, ProxyScope::All))
        .unwrap();
    assert_eq!(
        client
            .get(&local)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap(),
        "proxy-b"
    );
    assert_eq!(b.seen.lock().unwrap().len(), 1);

    let mut bypass = config(&proxy_b, ProxyScope::All);
    bypass.bypass = vec!["127.0.0.1".into()];
    store.set(GLOBAL_PROXY, bypass).unwrap();
    assert_eq!(
        client
            .get(&local)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap(),
        "origin"
    );
    let before = origin_state.seen.lock().unwrap().len();
    let dead = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let dead_url = format!("http://{}", dead.local_addr().unwrap());
    drop(dead);
    store
        .set(GLOBAL_PROXY, config(&dead_url, ProxyScope::All))
        .unwrap();
    let response = client.get(&local).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    let error = response.text().await.unwrap();
    assert!(!error.contains("private-fixture") && !error.contains(&origin));
    assert_eq!(
        origin_state.seen.lock().unwrap().len(),
        before,
        "A failed proxy must never retry the reachable origin directly"
    );
}

#[tokio::test]
async fn api_only_does_not_use_legacy_fallback_on_connection_error() {
    let (fallback, seen) = endpoint("unexpected fallback", None).await;
    let store = Arc::new(ProxyStore::new());
    store
        .set(GLOBAL_PROXY, config(&fallback, ProxyScope::ApiOnly))
        .unwrap();
    let mut stream = StreamProxy::with_proxy_store(store);
    stream.proxied = reqwest::Client::builder()
        .no_proxy()
        .proxy(reqwest::Proxy::all(&fallback).unwrap())
        .build()
        .unwrap();
    let stream = Arc::new(stream);
    let dead = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/video.mp4", dead.local_addr().unwrap());
    drop(dead);
    let local = maybe_proxy(
        &stream,
        &url,
        &[("Referer".into(), "https://fixture.test/".into())],
        true,
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(
        direct_client().get(local).send().await.unwrap().status(),
        StatusCode::BAD_GATEWAY
    );
    assert!(seen.seen.lock().unwrap().is_empty());
}

#[tokio::test]
async fn all_scope_hls_probe_rewrite_and_independent_audio_share_proxy() {
    let (origin, trap) = endpoint("direct-origin", None).await;
    let (upstream, seen) = endpoint("proxy-media", None).await;
    let store = Arc::new(ProxyStore::new());
    store
        .set(GLOBAL_PROXY, config(&upstream, ProxyScope::All))
        .unwrap();
    let stream = Arc::new(StreamProxy::with_proxy_store(store));
    let mut list = vec![candidate(format!("{origin}/master.m3u8"))];
    crate::hls_facts::probe_candidates_with_proxy(&mut list, stream.clone()).await;
    assert_eq!(list[0].playlist_total_ms, Some(7000));
    let local = maybe_proxy(&stream, &list[0].url, &[], false)
        .await
        .unwrap()
        .unwrap();
    let client = direct_client();
    let master = client
        .get(&local)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let child = master.lines().find(|v| !v.starts_with('#')).unwrap();
    assert!(stream.owns_url(child));
    let playlist = client
        .get(child)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let segment = playlist.lines().find(|v| !v.starts_with('#')).unwrap();
    assert!(stream.owns_url(segment));
    assert_eq!(
        client
            .get(segment)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap(),
        "proxy-media"
    );
    let mut wrapped = vec![candidate(local)];
    crate::hls_facts::probe_candidates_with_proxy(&mut wrapped, stream.clone()).await;
    assert_eq!(
        wrapped[0].playlist_total_ms,
        Some(7000),
        "Existing local wrappers remain usable for probing"
    );
    let audio = maybe_proxy(&stream, &format!("{origin}/audio.m4a"), &[], false)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        client
            .get(audio)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap(),
        "proxy-media"
    );
    let gzip = maybe_proxy(
        &stream,
        &format!("{origin}/gzip.m3u8"),
        &[("Accept-Encoding".into(), "gzip, br".into())],
        true,
    )
    .await
    .unwrap()
    .unwrap();
    let response = client.get(gzip).send().await.unwrap();
    assert!(response.headers().get(header::CONTENT_ENCODING).is_none());
    assert!(response.text().await.unwrap().contains("/p/"));
    assert!(trap.seen.lock().unwrap().is_empty());
    for (_, uri, headers) in seen.seen.lock().unwrap().iter() {
        assert!(
            uri.starts_with(&origin),
            "The remote proxy receives the origin, never the local wrapper"
        );
        assert_eq!(headers.get(header::ACCEPT_ENCODING).unwrap(), "identity");
    }
}

#[tokio::test]
async fn hls_child_and_prefetch_segments_reselect_updated_configuration() {
    let (origin, trap) = endpoint("origin", None).await;
    let (proxy_b, b) = endpoint("second", None).await;
    let store = Arc::new(ProxyStore::new());
    let next = config(&proxy_b, ProxyScope::All);
    let (proxy_a, a) = endpoint("first", Some((store.clone(), next.clone()))).await;
    store
        .set(GLOBAL_PROXY, config(&proxy_a, ProxyScope::All))
        .unwrap();
    let stream = Arc::new(StreamProxy::with_proxy_store(store.clone()));
    let mut list = vec![candidate(format!("{origin}/master.m3u8"))];
    crate::hls_facts::probe_candidates_with_proxy(&mut list, stream.clone()).await;
    assert_eq!(list[0].playlist_total_ms, Some(7000));
    assert_eq!(a.seen.lock().unwrap().len(), 1);
    assert!(b
        .seen
        .lock()
        .unwrap()
        .iter()
        .any(|(_, uri, _)| uri.ends_with("/child.m3u8")));

    store
        .set(GLOBAL_PROXY, config(&proxy_a, ProxyScope::All))
        .unwrap();
    let source = StreamClientSource {
        client: stream.upstream_client().unwrap(),
        store: Some(store.clone()),
    };
    let url = format!("{origin}/range.mp4");
    let headers = vec![("Referer".into(), "https://fixture.test/".into())];
    assert_eq!(
        &fetch_segment(source.clone(), url.clone(), headers.clone(), 1, 3)
            .await
            .unwrap()[..],
        b"irs"
    );
    store.set(GLOBAL_PROXY, next).unwrap();
    assert_eq!(
        &fetch_segment(source, url, headers, 1, 3).await.unwrap()[..],
        b"eco"
    );
    assert!(trap.seen.lock().unwrap().is_empty());
    let records = b.seen.lock().unwrap();
    let (_, _, headers) = records.last().unwrap();
    assert_eq!(headers.get(header::RANGE).unwrap(), "bytes=1-3");
    assert_eq!(
        headers.get(header::REFERER).unwrap(),
        "https://fixture.test/"
    );
}

#[tokio::test]
async fn global_prefetch_uses_proxy_for_every_range_and_preserves_bytes() {
    let (origin, trap) = endpoint("origin", None).await;
    let (upstream, seen) = endpoint("proxy", None).await;
    let store = Arc::new(ProxyStore::new());
    store
        .set(GLOBAL_PROXY, config(&upstream, ProxyScope::All))
        .unwrap();
    let stream = Arc::new(StreamProxy::with_proxy_store(store));
    stream.set_prefetch_disabled(false);
    let local = maybe_proxy(&stream, &format!("{origin}/prefetch.mp4"), &[], false)
        .await
        .unwrap()
        .unwrap();
    let response = direct_client()
        .get(local)
        .header(header::RANGE, "bytes=0-")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    let bytes = response.bytes().await.unwrap();
    let expected = (0..PREFETCH_WINDOW * 2 + 19)
        .map(|i| (i % 251) as u8)
        .collect::<Vec<_>>();
    assert_eq!(&bytes[..], &expected);
    let records = seen.seen.lock().unwrap();
    assert!(
        records.len() >= 5,
        "The response must exercise actual parallel prefetch requests"
    );
    assert!(records
        .iter()
        .all(|(_, _, h)| h.contains_key(header::RANGE)));
    assert!(trap.seen.lock().unwrap().is_empty());
}

#[tokio::test]
async fn registered_cover_uses_api_policy_without_changing_media_routing() {
    let (origin, origin_state) = endpoint("origin", None).await;
    let (proxy_a, a) = endpoint("proxy-a", None).await;
    let (proxy_b, b) = endpoint("proxy-b", None).await;
    let store = Arc::new(ProxyStore::new());
    store.set(GLOBAL_PROXY, config(&proxy_a, ProxyScope::ApiOnly)).unwrap();
    let stream = Arc::new(StreamProxy::with_proxy_store(store.clone()));
    stream.ensure_started().await.unwrap();
    let referer = "https://fixture.test/poster";
    let local = stream.register_cover(
        &format!("{origin}/poster.png?token=private-cover-fixture"),
        vec![("Referer".into(), referer.into())],
    );
    let client = direct_client();
    for _ in 0..3 {
        let response = client.get(&local).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.text().await.unwrap(), "proxy-a",
            "Covers are API metadata even when video uses a direct route");
    }
    assert!(origin_state.seen.lock().unwrap().is_empty());
    {
        let records = a.seen.lock().unwrap();
        assert_eq!(records.len(), 3);
        assert_eq!(records.iter().map(|v| v.0).collect::<HashSet<_>>().len(), 1,
            "Cover clients must reuse their connection pool");
        assert!(records.iter().all(|(_, _, h)| h.get(header::REFERER).unwrap() == referer));
        assert!(records.iter().all(|(_, _, h)| h.get(header::ACCEPT_ENCODING).unwrap() == "identity"));
    }

    let media = maybe_proxy(&stream, &format!("{origin}/video.mp4"),
        &[("Referer".into(), referer.into())], true).await.unwrap().unwrap();
    assert_eq!(client.get(&media).send().await.unwrap().text().await.unwrap(), "origin");
    assert_eq!(origin_state.seen.lock().unwrap().len(), 1);
    assert_eq!(a.seen.lock().unwrap().len(), 3);

    store.set(GLOBAL_PROXY, config(&proxy_b, ProxyScope::ApiOnly)).unwrap();
    assert_eq!(client.get(&local).send().await.unwrap().text().await.unwrap(), "proxy-b");
    assert_eq!(b.seen.lock().unwrap().len(), 1);
    let mut bypass = config(&proxy_b, ProxyScope::ApiOnly);
    bypass.bypass = vec!["127.0.0.1".into()];
    store.set(GLOBAL_PROXY, bypass).unwrap();
    assert_eq!(client.get(&local).send().await.unwrap().text().await.unwrap(), "origin");
    store.set(GLOBAL_PROXY, ProxyConfig { mode: ProxyMode::Direct, ..ProxyConfig::default() }).unwrap();
    assert_eq!(client.get(&local).send().await.unwrap().text().await.unwrap(), "origin");
    let before = origin_state.seen.lock().unwrap().len();
    let dead = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let dead_url = format!("http://{}", dead.local_addr().unwrap());
    drop(dead);
    store.set(GLOBAL_PROXY, config(&dead_url, ProxyScope::ApiOnly)).unwrap();
    let response = client.get(&local).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
    let error = response.text().await.unwrap();
    assert!(!error.contains("private-cover-fixture") && !error.contains(&origin));
    assert_eq!(origin_state.seen.lock().unwrap().len(), before,
        "A failed cover proxy must not fall back to the reachable origin");
}

#[tokio::test]
async fn cover_forwarding_keeps_encoded_bytes_and_response_headers() {
    let (origin, trap) = endpoint("origin", None).await;
    let (upstream, seen) = endpoint("compressed-cover", None).await;
    let store = Arc::new(ProxyStore::new());
    store.set(GLOBAL_PROXY, config(&upstream, ProxyScope::ApiOnly)).unwrap();
    let stream = Arc::new(StreamProxy::with_proxy_store(store));
    stream.ensure_started().await.unwrap();
    let local = stream.register_cover(&format!("{origin}/gzip.png"), vec![]);
    let response = reqwest::Client::builder().no_proxy().no_gzip().no_deflate().no_brotli()
        .build().unwrap().get(local).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers().get(header::CONTENT_ENCODING).unwrap(), "gzip");
    let length = response.content_length().unwrap();
    let bytes = response.bytes().await.unwrap();
    assert_eq!(length, bytes.len() as u64);
    let mut decoded = String::new();
    use std::io::Read;
    flate2::read::GzDecoder::new(&bytes[..]).read_to_string(&mut decoded).unwrap();
    assert_eq!(decoded, "compressed-cover");
    assert_eq!(seen.seen.lock().unwrap().len(), 1);
    assert!(trap.seen.lock().unwrap().is_empty());
}


#[tokio::test]
async fn rewritten_hls_signed_segment_key_and_relative_queries_reach_upstream_intact() {
    let (origin, trap) = endpoint("origin", None).await;
    let query = "sign=a%2Bb%2Fc%3D&expires=42&repeated=1&repeated=2&empty=&plus=a+b";
    let playlist = format!("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin?{query}\"\nseg.ts?{query}\n");
    let records = Arc::new(Mutex::new(Vec::new()));
    let seen = records.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let upstream = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        let app = Router::new().fallback(move |req: Request<Body>| {
            let master = req.uri().path().ends_with(".m3u8");
            seen.lock().unwrap().push((req.uri().to_string(), req.headers().clone()));
            let body = if master { playlist.clone() } else { "segment-or-key".into() };
            async move { ([("Content-Type", if master { "application/vnd.apple.mpegurl" } else { "application/octet-stream" })], body) }
        });
        axum::serve(listener, app).await.unwrap();
    });
    let store = Arc::new(ProxyStore::new());
    store.set(GLOBAL_PROXY, config(&upstream, ProxyScope::All)).unwrap();
    let stream = Arc::new(StreamProxy::with_proxy_store(store));
    stream.ensure_started().await.unwrap();
    let master = format!("{origin}/folder/master.m3u8?parent=unchanged");
    let local = stream.register(&master, vec![("Referer".into(), "https://fixture.test/".into())]);
    let client = direct_client();
    let response = client.get(&local).send().await.unwrap();
    assert!(response.status().is_success());
    let rewritten = response.text().await.unwrap();
    let key = rewritten.split("URI=\"").nth(1).unwrap().split('"').next().unwrap();
    let segment = rewritten.lines().find(|line| line.starts_with("http")).unwrap();
    for url in [key.to_string(), segment.to_string(), format!("{}seg.ts?{query}", local),
        format!("{}seg.ts", local)] {
        assert!(client.get(url).send().await.unwrap().status().is_success());
    }
    assert!(trap.seen.lock().unwrap().is_empty());
    let records = records.lock().unwrap();
    let expected = [master, format!("{origin}/folder/key.bin?{query}"), format!("{origin}/folder/seg.ts?{query}"),
        format!("{origin}/folder/seg.ts?{query}"), format!("{origin}/folder/seg.ts")];
    assert_eq!(records.len(), expected.len());
    for ((uri, headers), expected) in records.iter().zip(expected) {
        assert_eq!(uri, &expected, "signed query bytes must survive local proxy routing");
        assert_eq!(headers.get(header::REFERER).unwrap(), "https://fixture.test/");
    }
    server.abort();
}
