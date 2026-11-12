//! Capacity regression for a stream and the headers of its rewritten HLS children.
use super::*;
use crate::proxy::{ProxyConfig, ProxyMode, ProxyScope, ProxyStore, GLOBAL_PROXY};
use axum::http::Request;
use tokio::sync::oneshot;

#[test]
fn every_retained_stream_keeps_its_header_across_fifo_eviction() {
    let proxy = StreamProxy::new();
    for index in 0..(STREAM_MAX * 8) {
        proxy.register_at(&format!("http://127.0.0.1:1/fixture/{index}.m3u8"),
            vec![("X-Fixture".into(), index.to_string())], 12345);
        let streams = proxy.table.lock().unwrap();
        let headers = proxy.hdr_table.lock().unwrap();
        let missing = streams.values().filter(|entry| !headers.contains_key(&entry.hdr_token)).count();
        assert_eq!(missing, 0, "registration {index} leaves retained streams without HLS headers");
        for entry in streams.values() {
            assert_eq!(headers[&entry.hdr_token].headers, entry.headers,
                "retained header belongs to this exact stream");
        }
    }
}

#[test]
fn evicted_streams_leave_no_orphan_header_entries() {
    let proxy = StreamProxy::new();
    for index in 0..(STREAM_MAX + 2) {
        proxy.register_at(&format!("http://127.0.0.1:1/fixture/{index}.m3u8"), vec![], 12345);
    }
    let streams = proxy.table.lock().unwrap();
    let headers = proxy.hdr_table.lock().unwrap();
    assert!(streams.len() < STREAM_MAX, "the actual capacity boundary evicted entries");
    assert_eq!(headers.len(), streams.len(), "one header entry per retained stream");
    for token in headers.keys() {
        assert!(streams.values().any(|entry| &entry.hdr_token == token),
            "every header has a retained owner");
    }
}

#[tokio::test]
async fn retained_playlist_child_still_fetches_after_capacity_eviction() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let recorded = seen.clone();
    let app = Router::new().fallback(move |request: Request<Body>| {
        let path = request.uri().path().to_string();
        recorded.lock().unwrap().push((path.clone(), request.headers().clone()));
        let response = if path.ends_with(".m3u8") {
            Response::builder().header(header::CONTENT_TYPE, "application/vnd.apple.mpegurl")
                .body(Body::from("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1.0,\nsegment.ts\n#EXT-X-ENDLIST\n")).unwrap()
        } else {
            assert_eq!(path, "/fixture/segment.ts");
            Response::builder().header(header::CONTENT_TYPE, "video/mp2t")
                .body(Body::from("fixture-segment-bytes")).unwrap()
        };
        async move { response }
    });
    let (stop, stopped) = oneshot::channel();
    let server = tokio::spawn(async move {
        axum::serve(listener, app).with_graceful_shutdown(async { let _ = stopped.await; }).await
    });
    let store = Arc::new(ProxyStore::new());
    store.set(GLOBAL_PROXY, ProxyConfig {
        mode: ProxyMode::Direct, scope: ProxyScope::All, ..ProxyConfig::default()
    }).unwrap();
    let proxy = Arc::new(StreamProxy::with_proxy_store(store));
    let port = proxy.ensure_started().await.unwrap();
    for index in 0..(STREAM_MAX + 2) {
        proxy.register_at(&format!("{origin}/fixture/{index}.m3u8"),
            vec![("X-Fixture".into(), index.to_string())], port);
    }
    // The old unordered eviction can lose any retained stream's header. Inspect
    // actual retained entries and exercise one affected entry; when all are valid,
    // exercise the newest retained entry. The HTTP expectation is identical.
    let (token, expected_header, affected) = {
        let streams = proxy.table.lock().unwrap();
        let headers = proxy.hdr_table.lock().unwrap();
        let mut entries: Vec<_> = streams.iter().collect();
        entries.sort_by_key(|(_, entry)| entry.headers[0].1.parse::<usize>().unwrap());
        let affected = entries.iter().filter(|(_, entry)| !headers.contains_key(&entry.hdr_token)).count();
        let selected = entries.iter().rev().find(|(_, entry)| !headers.contains_key(&entry.hdr_token))
            .unwrap_or_else(|| entries.last().unwrap());
        (selected.0.clone(), selected.1.headers[0].1.clone(), affected)
    };
    println!("retained streams with missing HLS headers: {affected}");
    let consumer = reqwest::Client::builder().no_proxy()
        .timeout(std::time::Duration::from_secs(5)).build().unwrap();
    let root = consumer.get(format!("http://127.0.0.1:{port}/s/{token}/")).send().await.unwrap();
    let root_status = root.status();
    let playlist = root.text().await.unwrap();
    let child = playlist.lines().find(|line| !line.starts_with('#') && line.contains("segment.ts")).unwrap();
    let response = consumer.get(child).send().await.unwrap();
    let child_status = response.status();
    let bytes = response.bytes().await.unwrap();
    let task = proxy.serve_task.lock().unwrap().take();
    if let Some(task) = task {
        task.abort();
        let exit = task.await;
        assert!(exit.is_ok() || exit.unwrap_err().is_cancelled());
    }
    let _ = stop.send(());
    tokio::time::timeout(std::time::Duration::from_secs(5), server).await.unwrap().unwrap().unwrap();
    let requests = seen.lock().unwrap();
    assert_eq!(root_status, StatusCode::OK, "the retained playlist remains registered");
    assert_eq!(child_status, StatusCode::OK, "the rewritten child of a retained playlist must still fetch");
    assert_eq!(bytes.as_ref(), b"fixture-segment-bytes");
    assert_eq!(requests.len(), 2, "the origin receives one playlist and one segment request");
    for (_, headers) in requests.iter() {
        assert_eq!(headers.get("X-Fixture").unwrap().to_str().unwrap(), expected_header);
    }
}
