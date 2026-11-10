use super::*;
use crate::hls_query_policy::ScopedHlsQueryPolicy;
use crate::proxy::{ProxyConfig, ProxyMode, ProxyScope, ProxyStore, GLOBAL_PROXY};
use axum::http::Request;

const KEYS: &[&str] = &["pid", "utk", "uk", "spl", "t", "sign", "ip"];

#[derive(Clone)]
struct Fixture {
    hits: Arc<Mutex<Vec<(String, HeaderMap)>>>,
    foreign: String,
    marker: &'static str,
}

async fn respond(State(fixture): State<Fixture>, request: Request<Body>) -> Response {
    fixture.hits.lock().unwrap().push((request.uri().to_string(), request.headers().clone()));
    let path = request.uri().path();
    if path == "/denied.m3u8" {
        return (StatusCode::FORBIDDEN, "source permission denied").into_response();
    }
    let redirect = match path {
        "/start.m3u8" => Some("/effective/nested/root.m3u8?ignored=x&pid=a+b&sign=x%2fY&t=".to_string()),
        "/cross.m3u8" => Some(format!("{}/target.ts?sign=issued", fixture.foreign)),
        _ => None,
    };
    if let Some(location) = redirect {
        return Response::builder().status(302).header(header::LOCATION, location).body(Body::empty()).unwrap();
    }
    let body = match path {
        "/effective/nested/root.m3u8" => "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n../child.m3u8\n".to_string(),
        "/effective/child.m3u8" => "#EXTM3U\n#EXT-X-MAP:URI=\"/init.bin\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:9,\n./media%20part.ts\n#EXTINF:1,\n/existing.ts?own=1+raw&sign=child%2f\n#EXT-X-ENDLIST\n".to_string(),
        "/foreign.m3u8" => format!("#EXTM3U\n#EXTINF:9,\n{}/target.ts\n#EXT-X-ENDLIST\n", fixture.foreign),
        "/root.m3u8" => "#EXTM3U\n#EXTINF:9,\nsegment.ts\n#EXT-X-ENDLIST\n".to_string(),
        _ => fixture.marker.to_string(),
    };
    Response::builder().header(header::CONTENT_TYPE, if path.ends_with(".m3u8") {
        "application/vnd.apple.mpegurl"
    } else { "video/mp2t" }).body(Body::from(body)).unwrap()
}

async fn fixture(marker: &'static str, foreign: &str) -> (String, Fixture) {
    let state = Fixture { hits: Arc::new(Mutex::new(Vec::new())), foreign: foreign.into(), marker };
    let app = Router::new().fallback(respond).with_state(state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap(); });
    (url, state)
}

fn client() -> reqwest::Client {
    reqwest::Client::builder().no_proxy().timeout(std::time::Duration::from_secs(5)).build().unwrap()
}

fn media_uri(text: &str, index: usize) -> String {
    text.lines().filter(|line| !line.is_empty() && !line.starts_with('#')).nth(index).unwrap().into()
}

async fn scoped(proxy: &Arc<StreamProxy>, url: &str) -> String {
    let policy = ScopedHlsQueryPolicy::new(url, KEYS).unwrap();
    maybe_proxy_with_policy(proxy, url, &[("User-Agent".into(), "FixtureMedia".into())], false, Some(&policy))
        .await.unwrap().expect("declared policy must force the wrapper under ApiOnly")
}

#[tokio::test]
async fn declared_hls_query_real_nested_requests_preserve_bytes_headers_and_effective_base() {
    let (origin, observed) = fixture("segment", "http://127.0.0.1:1").await;
    let store = Arc::new(ProxyStore::new());
    let stream = Arc::new(StreamProxy::with_proxy_store(store));
    let source_url = format!("{origin}/start.m3u8?pid=stale");
    let mut candidates = vec![crate::model::StreamCandidate::new(&source_url, crate::model::StreamKind::Hls)
        .with_headers(vec![("User-Agent".into(), "FixtureMedia".into())])];
    candidates[0].hls_query_policy = ScopedHlsQueryPolicy::new(&source_url, KEYS);
    crate::playback::prepare_scoped_hls_candidates(&mut candidates, &stream).await.unwrap();
    let local = candidates[0].url.clone();
    assert!(stream.owns_url(&local), "real resolve preparation must consume the internal policy");
    crate::hls_facts::probe_candidates_with_proxy(&mut candidates, stream.clone()).await;
    assert_eq!(candidates[0].playlist_total_ms, Some(10_000));
    let client = client();
    let master = client.get(&local).send().await.unwrap().text().await.unwrap();
    let child_url = media_uri(&master, 0);
    let child = client.get(&child_url).send().await.unwrap().text().await.unwrap();
    for index in 0..2 {
        assert_eq!(client.get(media_uri(&child, index)).send().await.unwrap().text().await.unwrap(), "segment");
    }
    for line in child.lines().filter(|line| line.contains("URI=\"")) {
        let uri = line.split_once("URI=\"").unwrap().1.split('"').next().unwrap();
        assert_eq!(client.get(uri).send().await.unwrap().text().await.unwrap(), "segment");
    }
    let hits = observed.hits.lock().unwrap();
    let requests: Vec<_> = hits.iter().map(|hit| hit.0.as_str()).collect();
    assert!(requests.contains(&"/effective/child.m3u8?pid=a+b&sign=x%2fY&t="));
    assert!(requests.contains(&"/effective/media%20part.ts?pid=a+b&sign=x%2fY&t="),
        "real upstream URI must retain the declared signed query and encoded path");
    assert!(requests.contains(&"/existing.ts?own=1+raw&sign=child%2f"));
    assert!(requests.contains(&"/init.bin"));
    assert!(requests.contains(&"/effective/key.bin"));
    assert!(hits.iter().all(|hit| hit.1[header::USER_AGENT] == "FixtureMedia"));
    assert!(hits.iter().all(|hit| hit.1[header::ACCEPT] == "*/*"));
}

#[tokio::test]
async fn declared_hls_query_denies_foreign_children_redirects_and_forged_token_paths_before_network() {
    let (foreign, denied) = fixture("foreign", "http://127.0.0.1:1").await;
    let (origin, _) = fixture("origin", &foreign).await;
    let stream = Arc::new(StreamProxy::with_proxy_store(Arc::new(ProxyStore::new())));
    let client = client();
    for path in ["foreign.m3u8", "cross.m3u8"] {
        let local = scoped(&stream, &format!("{origin}/{path}?sign=issued")).await;
        let response = client.get(local).send().await.unwrap();
        assert_eq!(response.status(), StatusCode::BAD_GATEWAY);
        assert!(!response.text().await.unwrap().contains("issued"));
    }
    let local = scoped(&stream, &format!("{origin}/root.m3u8?pid=issued")).await;
    let text = client.get(local).send().await.unwrap().text().await.unwrap();
    let origin_host = origin.strip_prefix("http://").unwrap();
    let foreign_host = foreign.strip_prefix("http://").unwrap();
    let forged = media_uri(&text, 0).replace(&format!("/http/{origin_host}/"), &format!("/http/{foreign_host}/"));
    assert_eq!(client.get(forged).send().await.unwrap().status(), StatusCode::BAD_GATEWAY);
    assert!(denied.hits.lock().unwrap().is_empty(), "not one credential-bearing cross-origin request may escape");
}

#[tokio::test]
async fn declared_hls_query_keeps_default_sources_and_global_route_changes() {
    let (origin, origin_seen) = fixture("origin", "http://127.0.0.1:1").await;
    let (selected_proxy, proxy_seen) = fixture("selected-proxy", "http://127.0.0.1:1").await;
    let store = Arc::new(ProxyStore::new());
    let cfg = ProxyConfig { mode: ProxyMode::Custom, url: Some(selected_proxy), scope: ProxyScope::ApiOnly,
        ..ProxyConfig::default() };
    store.set(GLOBAL_PROXY, cfg.clone()).unwrap();
    let stream = Arc::new(StreamProxy::with_proxy_store(store.clone()));
    let ordinary = format!("{origin}/root.m3u8?pid=ordinary");
    assert!(maybe_proxy(&stream, &ordinary, &[], false).await.unwrap().is_none());
    let generic = maybe_proxy(&stream, &ordinary, &[("User-Agent".into(), "FixtureMedia".into())], true)
        .await.unwrap().unwrap();
    let client = client();
    let text = client.get(generic).send().await.unwrap().text().await.unwrap();
    assert!(!media_uri(&text, 0).contains("pid="), "ordinary HLS must not acquire declared-source semantics");
    let local = scoped(&stream, &format!("{origin}/segment.ts?pid=fixture")).await;
    assert_eq!(client.get(&local).send().await.unwrap().text().await.unwrap(), "origin");
    assert!(proxy_seen.hits.lock().unwrap().is_empty());
    let origin_count = origin_seen.hits.lock().unwrap().len();
    store.set(GLOBAL_PROXY, ProxyConfig { scope: ProxyScope::All, ..cfg }).unwrap();
    assert_eq!(client.get(&local).send().await.unwrap().text().await.unwrap(), "selected-proxy");
    assert_eq!(origin_seen.hits.lock().unwrap().len(), origin_count);
    assert_eq!(proxy_seen.hits.lock().unwrap().len(), 1);
    store.set(GLOBAL_PROXY, ProxyConfig { mode:ProxyMode::Custom, url:Some("http://127.0.0.1:1".into()),
        scope:ProxyScope::All, ..ProxyConfig::default() }).unwrap();
    assert_eq!(client.get(&local).send().await.unwrap().status(), StatusCode::BAD_GATEWAY);
    assert_eq!(origin_seen.hits.lock().unwrap().len(), origin_count, "a failed selected route must not fall back direct");
}

#[tokio::test]
async fn declared_hls_query_preserves_source_access_refusal_without_retry() {
    let (origin, observed) = fixture("origin", "http://127.0.0.1:1").await;
    let stream = Arc::new(StreamProxy::with_proxy_store(Arc::new(ProxyStore::new())));
    let local = scoped(&stream, &format!("{origin}/denied.m3u8?pid=fixture&sign=issued")).await;
    let response = client().get(local).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert!(!response.text().await.unwrap().contains("issued"));
    assert_eq!(observed.hits.lock().unwrap().len(), 1);
}
