//! Snapshot covers cross a process boundary; stream-proxy addresses do not.
//!
//! The public FFI cases cover packet parsing and dispatch. The independent
//! runtime case exercises the existing owning functions, with Runtime A fully
//! destroyed before Runtime B starts. It does not pretend OnceLock FFI globals
//! can be restarted inside one process. All HTTP fixtures are strict loopback.

use async_trait::async_trait;
use serde_json::{json, Value};
use sourin_core::{
    library_covers,
    model::{MediaDetail, MediaId, PlayRequest, ProviderError, ProviderManifest, StreamCandidate},
    provider::MediaProvider,
    proxy::{ProxyConfig, ProxyMode, ProxyScope, GLOBAL_PROXY},
    state::AppState,
    store::{Db, Favorite, HistoryEntry, Progress},
    tvbox_aggregate::AGGREGATE_ID,
};
use std::{
    ffi::{CStr, CString},
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex, OnceLock,
    },
    thread,
    time::Duration,
};

// Complete 32 x 48 PNG, shared in shape with the library lifecycle fixture.
const POSTER_PNG: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 32, 0, 0, 0,
    48, 8, 2, 0, 0, 0, 255, 206, 239, 56, 0, 0, 0, 98, 73, 68, 65, 84, 120, 156, 99, 84,
    14, 157, 203, 64, 75, 192, 68, 83, 211, 25, 70, 45, 32, 2, 140, 198, 1, 65, 48, 26, 68,
    3, 31, 68, 44, 184, 36, 118, 6, 206, 34, 213, 44, 247, 245, 105, 152, 130, 163, 145, 76,
    16, 140, 6, 17, 65, 48, 26, 68, 4, 193, 104, 16, 17, 4, 163, 65, 68, 16, 140, 6, 17,
    65, 48, 26, 68, 4, 193, 104, 16, 141, 128, 32, 98, 28, 237, 198, 14, 255, 72, 102, 26,
    181, 128, 16, 160, 121, 16, 1, 0, 72, 237, 5, 139, 37, 191, 209, 101, 0, 0, 0, 0, 73,
    69, 78, 68, 174, 66, 96, 130,
];

#[derive(Clone, Debug)]
struct ObservedRequest {
    target: String,
    headers: Vec<(String, String)>,
}

impl ObservedRequest {
    fn header(&self, name: &str) -> Vec<&str> {
        self.headers.iter().filter(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str()).collect()
    }
}

// The fixture owns its own OS thread, outside both core runtimes. It is also an
// HTTP proxy trap: requests receive PNG bytes without contacting any upstream.
struct HttpFixture {
    address: SocketAddr,
    seen: Arc<Mutex<Vec<ObservedRequest>>>,
    stopped: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}

impl HttpFixture {
    fn new(poster: bool) -> Self {
        Self::bind("127.0.0.1:0".parse().unwrap(), poster)
    }

    fn bind(address: SocketAddr, poster: bool) -> Self {
        let listener = TcpListener::bind(address).expect("bind isolated HTTP fixture");
        let address = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let observed = seen.clone();
        let stopped = Arc::new(AtomicBool::new(false));
        let done = stopped.clone();
        let worker = thread::spawn(move || {
            while !done.load(Ordering::SeqCst) {
                let (mut connection, _) = match listener.accept() {
                    Ok(connection) => connection,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                        continue;
                    }
                    Err(error) => panic!("fixture accept failed: {error}"),
                };
                // The accept loop is nonblocking, but this thread reads each
                // accepted HTTP request synchronously. Set its mode explicitly
                // instead of dropping it on an unreported WouldBlock read.
                connection.set_nonblocking(false).unwrap();
                connection.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                connection.set_write_timeout(Some(Duration::from_secs(2))).unwrap();
                let mut bytes = Vec::new();
                let mut chunk = [0; 2048];
                while !bytes.windows(4).any(|part| part == b"\r\n\r\n") {
                    match connection.read(&mut chunk) {
                        Ok(0) => break,
                        Err(error) => {
                            eprintln!("[HOME_COVER_FIXTURE] request read failed: {:?}; bytes={}", error.kind(), bytes.len());
                            break;
                        }
                        Ok(count) => bytes.extend_from_slice(&chunk[..count]),
                    }
                    assert!(bytes.len() <= 32 * 1024, "bounded fixture request");
                }
                if bytes.is_empty() { continue; }
                let request = String::from_utf8(bytes).unwrap();
                let mut lines = request.split("\r\n");
                let target = lines.next().unwrap().split_whitespace().nth(1).unwrap().to_string();
                let headers = lines.take_while(|line| !line.is_empty())
                    .map(|line| {
                        let (name, value) = line.split_once(':').expect("HTTP header");
                        (name.to_string(), value.trim().to_string())
                    }).collect();
                observed.lock().unwrap().push(ObservedRequest { target, headers });
                let (status, content_type, body) = if poster {
                    ("200 OK", "image/png", POSTER_PNG)
                } else {
                    ("418 I'm a teapot", "text/plain", b"direct/expired route forbidden".as_slice())
                };
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len(),
                );
                connection.write_all(response.as_bytes()).unwrap();
                connection.write_all(body).unwrap();
            }
        });
        Self { address, seen, stopped, worker: Some(worker) }
    }

    fn base(&self) -> String { format!("http://{}", self.address) }

    fn requests(&self) -> Vec<ObservedRequest> { self.seen.lock().unwrap().clone() }
}

impl Drop for HttpFixture {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() { worker.join().unwrap(); }
    }
}

fn isolated_profile(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "sourin-home-cover-{label}-{}-{}", std::process::id(),
        chrono::Utc::now().timestamp_nanos_opt().unwrap(),
    )).join("profile");
    std::fs::create_dir_all(&dir).unwrap();
    // Existing DB skips legacy migration. No real APPDATA profile is consulted.
    drop(Db::open(&dir.join("dsh-media.db")).unwrap());
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    dir
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap()
}

static FFI_LOCK: Mutex<()> = Mutex::new(());

fn ensure_ffi_started() {
    static PROFILE: OnceLock<PathBuf> = OnceLock::new();
    PROFILE.get_or_init(|| {
        let dir = isolated_profile("ffi");
        let config = CString::new(json!({"dataDir":dir.to_string_lossy()}).to_string()).unwrap();
        let pointer = unsafe { sourin_core::ffi::sourin_start(config.as_ptr()) };
        assert!(!pointer.is_null());
        let response = unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned();
        unsafe { sourin_core::ffi::sourin_free(pointer) };
        let response: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(response["ok"], true, "fixture core must start before dispatch assertions");
        dir
    });
}

fn ffi_call(command: &str, args: Value) -> Value {
    ensure_ffi_started();
    let packet = CString::new(json!({"cmd":command,"args":args}).to_string()).unwrap();
    let pointer = unsafe { sourin_core::ffi::sourin_call(packet.as_ptr()) };
    assert!(!pointer.is_null());
    let response = unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned();
    unsafe { sourin_core::ffi::sourin_free(pointer) };
    serde_json::from_str(&response).expect("public FFI must return JSON")
}

fn success(command: &str, args: Value) -> Value {
    let response = ffi_call(command, args);
    assert!(response.get("error").is_none(), "{command} must succeed: {response}");
    response
}

#[test]
fn ffi_batch_roundtrip_preserves_identity_order_nulls_and_full_raw_metadata() {
    let _guard = FFI_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    let origin = HttpFixture::new(false);
    let raw = format!("{}/poster.png?size=2%2F3@Referer=https://inline.fixture/frame@User-Agent=Inline%20Fixture/1.0", origin.base());
    let data_cover = concat!("data:", "image/png;base64,AA==");
    let registered = success("covers_to_display", json!({"items":[
        {"provider":"fixture","id":"native:with::separators","cover":raw},
    ]}));
    let local = registered["items"][0]["cover"].as_str().expect("remote cover wrapper");
    assert!(local.starts_with("http://127.0.0.1:") && local.contains("/s/"));
    let expected = json!({"items":[
        {"provider":"fixture","id":"native:with::separators","cover":raw},
        {"provider":"fixture","id":"no-cover","cover":null},
        {"provider":"fixture","id":"missing-cover","cover":null},
        {"provider":"fixture","id":"blank-cover","cover":null},
        {"provider":"fixture","id":"data","cover":data_cover},
        {"provider":"fixture","id":"local-file","cover":"C:\\posters\\fixture.png"},
        {"provider":"fixture","id":"expired","cover":null},
        {"provider":"fixture","id":"ordinary-local-server","cover":"http://127.0.0.1:1/images/poster.png"},
        {"provider":AGGREGATE_ID,"id":"child-provider::native-id","cover":raw},
        {"provider":"","id":"","cover":null},
    ]});
    let actual = success("covers_to_durable", json!({"items":[
        {"provider":"fixture","id":"native:with::separators","cover":local},
        {"provider":"fixture","id":"no-cover","cover":null},
        {"provider":"fixture","id":"missing-cover"},
        {"provider":"fixture","id":"blank-cover","cover":" \r\n "},
        {"provider":"fixture","id":"data","cover":data_cover},
        {"provider":"fixture","id":"local-file","cover":"C:\\posters\\fixture.png"},
        {"provider":"fixture","id":"expired","cover":"http://127.0.0.1:1/s/unknown-previous-process-token"},
        {"provider":"fixture","id":"ordinary-local-server","cover":"http://127.0.0.1:1/images/poster.png"},
        {"provider":AGGREGATE_ID,"id":"child-provider::native-id","cover":raw},
        {"provider":"","id":"","cover":null},
    ]}));
    assert_eq!(actual, expected, "convert covers only; keep every card and its native identity");
    let display = success("covers_to_display", actual.clone());
    assert_eq!(success("covers_to_durable", display), expected);
    for command in ["covers_to_durable", "covers_to_display"] {
        assert_eq!(success(command, json!({"items":[]})), json!({"items":[]}));
        assert_eq!(success(command, json!({"items":[
            {"provider":"fixture","id":"old","cover":"http://127.0.0.1:1/s/unknown-previous-process-token"},
        ]})), json!({"items":[{"provider":"fixture","id":"old","cover":null}]}));
    }
    assert!(origin.requests().is_empty(), "roundtrip conversion performs no image request");
}

#[test]
fn ffi_batch_rejects_invalid_packets_and_bounds_the_batch() {
    let _guard = FFI_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    for command in ["covers_to_durable", "covers_to_display"] {
        for (args, field) in [
            (json!({}), "items"),
            (json!({"items":null}), "items"),
            (json!({"items":{}}), "items"),
            (json!({"items":[null]}), "items"),
            (json!({"items":[{"id":"native","cover":null}]}), "provider"),
            (json!({"items":[{"provider":1,"id":"native","cover":null}]}), "provider"),
            (json!({"items":[{"provider":"fixture","cover":null}]}), "id"),
            (json!({"items":[{"provider":"fixture","id":null,"cover":null}]}), "id"),
            (json!({"items":[{"provider":"fixture","id":"native","cover":{"secret":"never-echo"}}]}), "cover"),
        ] {
            let response = ffi_call(command, args);
            let error = response["error"].as_str().expect("invalid batch must return an error");
            assert_ne!(response["kind"], "unsupported", "command must be wired before validating input");
            assert!(error.contains(field), "validation must identify {field}: {response}");
            assert!(!error.contains("never-echo"), "validation must not echo cover metadata");
        }
        let at_limit: Vec<_> = (0..4096).map(|index| json!({
            "provider":"fixture", "id":format!("item-{index}"), "cover":null,
        })).collect();
        assert_eq!(success(command, json!({"items":at_limit}))["items"].as_array().unwrap().len(), 4096);
        let over_limit = vec![json!({"provider":"fixture","id":"native","cover":null}); 4097];
        let response = ffi_call(command, json!({"items":over_limit}));
        assert_ne!(response["kind"], "unsupported");
        assert!(response["error"].as_str().is_some_and(|error| error.contains("items")),
            "over-limit packet must fail with an items error");
    }
}

#[test]
fn ffi_display_uses_the_global_api_proxy_and_preserves_inline_request_metadata() {
    let _guard = FFI_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    let origin = HttpFixture::new(false);
    let proxy = HttpFixture::new(true);
    success("set_proxy_config", json!({"provider":GLOBAL_PROXY,"config":{
        "mode":"custom","url":proxy.base(),"scope":"api_only","bypass":[],
    }}));
    let target = format!("{}/ffi-poster.png?size=2%2F3", origin.base());
    let raw = format!("{target}@Referer=https://inline.fixture/frame@User-Agent=Inline%20Fixture/1.0");
    let display = success("covers_to_display", json!({"items":[
        {"provider":"unregistered-fixture","id":"native","cover":raw},
    ]}));
    assert!(origin.requests().is_empty() && proxy.requests().is_empty(), "conversion performs no image request");
    let local = display["items"][0]["cover"].as_str().expect("registered display wrapper");
    runtime().block_on(assert_png(local));
    let durable = success("covers_to_durable", display);
    assert_eq!(durable["items"][0]["cover"], raw, "durable form retains the complete original recipe");
    assert!(origin.requests().is_empty(), "configured API proxy must prevent a direct origin request");
    let seen = proxy.requests();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].target, target);
    assert_eq!(seen[0].header("referer"), vec!["https://inline.fixture/frame"]);
    assert_eq!(seen[0].header("user-agent"), vec!["Inline Fixture/1.0"]);
    success("set_proxy_config", json!({"provider":GLOBAL_PROXY,"config":{"mode":"direct"}}));
}

struct ManifestSource {
    manifest: ProviderManifest,
    details: Arc<AtomicUsize>,
}

#[async_trait]
impl MediaProvider for ManifestSource {
    fn manifest(&self) -> &ProviderManifest { &self.manifest }

    async fn detail(&self, _: &MediaId) -> Result<MediaDetail, ProviderError> {
        self.details.fetch_add(1, Ordering::SeqCst);
        Err(ProviderError::parse("conversion must not request detail"))
    }

    async fn resolve(&self, _: &MediaId, _: &PlayRequest) -> Result<Vec<StreamCandidate>, ProviderError> {
        panic!("cover conversion must not resolve playback")
    }
}

fn register_manifest(state: &AppState, id: &str, generation: &str, details: Arc<AtomicUsize>) {
    let manifest = ProviderManifest {
        id: id.into(), name: "Snapshot fixture".into(), version: generation.into(), kind: "fixture".into(),
        description: None, icon: None, id_prefixes: vec![], capabilities: Default::default(), hidden: false,
        cover_headers: vec![
            ("X-Cache-Generation".into(), generation.into()),
            ("REFERER".into(), format!("https://manifest-{generation}.fixture/")),
            ("user-agent".into(), format!("Manifest{generation}/1.0")),
        ],
        config: vec![], api_version: 1, theme_color: None, working: true, broken_reason: None, enabled: None,
    };
    state.registry.register(Arc::new(ManifestSource { manifest, details }));
}

fn seed_library(state: &AppState, raw: &str) {
    state.db.upsert_favorite(&Favorite {
        key: "cache-child:series".into(), provider: "cache-child".into(), native_id: "series".into(),
        title: "Unchanged title".into(), cover: Some(raw.into()), group_name: Some("Owner group".into()),
        kind: "series".into(), favorited: true, following: true, last_episode_count: 3,
        last_episode_title: Some("Episode 3".into()), unread_count: 2, last_checked_at: 123,
        last_update_at: 120, note: Some("Unchanged note".into()), created_at: 10, updated_at: 20, deleted: false,
    }).unwrap();
    state.db.upsert_progress(&Progress {
        key: "cache-child:series:ep3".into(), provider: "cache-child".into(), native_id: "series".into(),
        title: "Unchanged title".into(), cover: Some(raw.into()), episode_id: Some("ep3".into()),
        episode_title: Some("Episode 3".into()), position: 63, duration: 180, finished: false, updated_at: 30,
    }).unwrap();
    state.db.add_history(&HistoryEntry {
        key: "cache-child:series:history".into(), provider: "cache-child".into(), native_id: "series".into(),
        title: "Unchanged title".into(), cover: Some(raw.into()), episode_title: Some("Episode 3".into()),
        position: 63, duration: 180, watched_at: 40,
    }).unwrap();
}

fn library_snapshot(state: &AppState) -> Value {
    json!({
        "favorites":state.db.list_favorites(true).unwrap(),
        "progress":state.db.list_all_progress().unwrap(),
        "history":state.db.list_history(100).unwrap(),
    })
}

async fn assert_png(local: &str) {
    let response = reqwest::Client::builder().no_proxy().timeout(Duration::from_secs(5))
        .build().unwrap().get(local).send().await.unwrap();
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    assert_eq!(response.headers().get("content-type").unwrap(), "image/png");
    assert_eq!(response.bytes().await.unwrap().as_ref(), POSTER_PNG);
}

async fn assert_png_with_policy_diagnostics(
    local: &str,
    state: &AppState,
    raw: &str,
    origin: &HttpFixture,
    proxy: &HttpFixture,
    retired: &HttpFixture,
) {
    let response = reqwest::Client::builder().no_proxy().timeout(Duration::from_secs(5))
        .build().unwrap().get(local).send().await.unwrap();
    if response.status() != reqwest::StatusCode::OK {
        eprintln!("[HOME_COVER_DIAG] wrapper_status={} origin_hits={} proxy_hits={} retired_hits={}",
            response.status().as_u16(), origin.requests().len(), proxy.requests().len(), retired.requests().len());
        // Diagnostic requests run only after the real owning path has already
        // failed. They can never turn that failure into a passing assertion.
        let client = state.proxy.client_for_ex(GLOBAL_PROXY, Some(ProxyScope::ApiOnly),
            sourin_core::proxy::AutoDecompress::Off).unwrap();
        let result = client.get(raw).header("X-Cache-Generation", "b")
            .header("Referer", "https://manifest-b.fixture/")
            .header("User-Agent", "Manifestb/1.0").send().await;
        match result {
            Ok(diagnostic) => eprintln!("[HOME_COVER_DIAG] same_policy_status={} origin_hits={} proxy_hits={}",
                diagnostic.status().as_u16(), origin.requests().len(), proxy.requests().len()),
            Err(error) => eprintln!("[HOME_COVER_DIAG] same_policy_error={:?}", error.without_url()),
        }
    }
    assert_eq!(response.status(), reqwest::StatusCode::OK);
    assert_eq!(response.headers().get("content-type").unwrap(), "image/png");
    assert_eq!(response.bytes().await.unwrap().as_ref(), POSTER_PNG);
}

#[test]
fn owning_cover_paths_rebind_only_after_the_old_runtime_and_listener_are_gone() {
    let origin = HttpFixture::new(false);
    let proxy = HttpFixture::new(true);
    let dir = isolated_profile("restart");
    let plain = format!("{}/poster.png?size=2%2F3", origin.base());
    let inline = format!("{plain}@Referer=https://inline.fixture/frame@User-Agent=Inline%20Fixture/1.0");
    let details = Arc::new(AtomicUsize::new(0));
    let config = ProxyConfig {
        mode: ProxyMode::Custom, url: Some(proxy.base()), scope: ProxyScope::ApiOnly,
        ..ProxyConfig::default()
    };
    let runtime_a = runtime();
    let (old_plain, old_inline, durable_plain, durable_inline, before) = runtime_a.block_on(async {
        let state_a = AppState::bootstrap(dir.clone()).await.unwrap();
        register_manifest(&state_a, "cache-child", "a", details.clone());
        register_manifest(&state_a, AGGREGATE_ID, "wrong-aggregate-a", details.clone());
        state_a.proxy.set(GLOBAL_PROXY, config.clone()).unwrap();
        seed_library(&state_a, &inline);
        let before = library_snapshot(&state_a);
        let old_plain = library_covers::for_display(&state_a, "cache-child", "series", Some(&plain)).await.unwrap();
        let old_inline = library_covers::for_display(&state_a, AGGREGATE_ID, "cache-child::series", Some(&inline)).await.unwrap();
        let durable_plain = library_covers::durable(&state_a, Some(&old_plain)).unwrap();
        let durable_inline = library_covers::durable(&state_a, Some(&old_inline)).unwrap();
        assert_eq!(durable_plain, plain);
        assert_eq!(durable_inline, inline);
        assert_eq!(library_snapshot(&state_a), before);
        assert_eq!(details.load(Ordering::SeqCst), 0);
        assert!(origin.requests().is_empty() && proxy.requests().is_empty());
        (old_plain, old_inline, durable_plain, durable_inline, before)
    });
    // Dropping AppState alone would leave its spawned server alive. Destroy the
    // actual runtime and prove its old listener closed before creating B.
    drop(runtime_a);
    let old_url = reqwest::Url::parse(&old_plain).unwrap();
    let old_address = SocketAddr::from(([127, 0, 0, 1], old_url.port().unwrap()));
    assert!(TcpStream::connect_timeout(&old_address, Duration::from_millis(300)).is_err(),
        "Runtime A's listener must be gone before the restart assertion");
    let retired_port = HttpFixture::bind(old_address, false);
    let runtime_b = runtime();
    runtime_b.block_on(async {
        // A genuinely separate state loads the same durable DB and a changed
        // provider manifest. No Arc or registry from A is reused.
        let state_b = AppState::bootstrap(dir).await.unwrap();
        register_manifest(&state_b, "cache-child", "b", details.clone());
        register_manifest(&state_b, AGGREGATE_ID, "wrong-aggregate-b", details.clone());
        state_b.proxy.set(GLOBAL_PROXY, config).unwrap();
        assert_eq!(library_snapshot(&state_b), before);
        for old in [&old_plain, &old_inline] {
            assert_eq!(library_covers::durable(&state_b, Some(old)), None);
            assert_eq!(library_covers::for_display(&state_b, "cache-child", "series", Some(old)).await, None,
                "an unknown retired wrapper must not be repaired by changing its port");
        }
        let current_plain = library_covers::for_display(&state_b, "cache-child", "series", Some(&durable_plain)).await.unwrap();
        let current_inline = library_covers::for_display(&state_b, AGGREGATE_ID, "cache-child::series", Some(&durable_inline)).await.unwrap();
        for current in [&current_plain, &current_inline] {
            assert_ne!(reqwest::Url::parse(current).unwrap().port(), Some(old_address.port()));
        }
        assert_eq!(library_covers::durable(&state_b, Some(&current_plain)).as_deref(), Some(plain.as_str()));
        assert_eq!(library_covers::durable(&state_b, Some(&current_inline)).as_deref(), Some(inline.as_str()));
        assert_eq!(library_snapshot(&state_b), before);
        assert_eq!(details.load(Ordering::SeqCst), 0, "rebinding must not refresh source details");
        assert!(origin.requests().is_empty() && proxy.requests().is_empty(), "rebinding alone performs no HTTP");
        assert_png_with_policy_diagnostics(&current_plain, &state_b, &plain, &origin, &proxy, &retired_port).await;
        assert_png_with_policy_diagnostics(&current_inline, &state_b, &plain, &origin, &proxy, &retired_port).await;
        assert_eq!(library_snapshot(&state_b), before, "display conversion must preserve every library field");
    });
    drop(runtime_b);
    assert_eq!(details.load(Ordering::SeqCst), 0);
    assert!(origin.requests().is_empty(), "API-only policy must not bypass the proxy for covers");
    assert!(retired_port.requests().is_empty(), "no restored cover may use the retired listener");
    let seen = proxy.requests();
    assert_eq!(seen.len(), 2);
    for request in &seen {
        assert_eq!(request.target, plain, "inline recipe must be removed only from the HTTP request");
        assert_eq!(request.header("x-cache-generation"), vec!["b"], "use B's current child manifest");
    }
    assert_eq!(seen[0].header("referer"), vec!["https://manifest-b.fixture/"]);
    assert_eq!(seen[0].header("user-agent"), vec!["Manifestb/1.0"]);
    assert_eq!(seen[1].header("referer"), vec!["https://inline.fixture/frame"]);
    assert_eq!(seen[1].header("user-agent"), vec!["Inline Fixture/1.0"]);
}
