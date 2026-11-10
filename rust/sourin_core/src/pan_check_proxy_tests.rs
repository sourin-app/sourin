use super::*;
use axum::{
    body::{to_bytes, Body},
    http::{HeaderMap, Method, Request, StatusCode, Uri},
    response::{IntoResponse, Response},
    Router,
};
use crate::proxy::{ProxyConfig, ProxyMode, ProxyStore, GLOBAL_PROXY};
use std::collections::BTreeMap;
use tokio::sync::Semaphore;

const QUARK: &str = "https://pan.quark.cn/s/proxy-fixture";
const UC: &str = "https://drive.uc.cn/s/proxy-fixture";
const BAIDU: &str = "https://pan.baidu.com/s/1Ab_Cd";
const ALI: &str = "https://www.alipan.com/s/proxy-fixture";
const XUNLEI: &str = "https://pan.xunlei.com/s/proxy-fixture";
const PAGE: &str = r#"<html><script>locals.mset({"shareid":123,"share_uk":456,"bdstoken":"PAGE_TOKEN"});</script></html>"#;

#[derive(Clone, Debug)]
struct Seen {
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Vec<u8>,
}

#[derive(Clone, Copy)]
enum Answer {
    Healthy,
    Locked,
    Risk,
    Refused,
}

#[derive(Clone)]
struct Gate {
    entered: Arc<Semaphore>,
    release: Arc<Semaphore>,
}

impl Gate {
    fn new() -> Self {
        Self {
            entered: Arc::new(Semaphore::new(0)),
            release: Arc::new(Semaphore::new(0)),
        }
    }

    async fn wait(&self) {
        tokio::time::timeout(Duration::from_secs(3), self.entered.acquire())
            .await.expect("the configured proxy did not receive the in-flight token request")
            .unwrap().forget();
    }
}

struct Fixture {
    base: String,
    seen: Arc<Mutex<Vec<Seen>>>,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl Fixture {
    async fn start(answer: Answer) -> Self {
        Self::with_gate(answer, None).await
    }

    async fn with_gate(answer: Answer, gate: Option<Gate>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let captured = seen.clone();
        let app = Router::new().fallback(move |request: Request<Body>| {
            let captured = captured.clone();
            let gate = gate.clone();
            async move {
                let (parts, body) = request.into_parts();
                let request = Seen {
                    method: parts.method,
                    uri: parts.uri,
                    headers: parts.headers,
                    body: to_bytes(body, 64 * 1024).await.unwrap().to_vec(),
                };
                captured.lock().unwrap().push(request.clone());
                if request.uri.path() == "/qtoken" {
                    if let Some(gate) = gate {
                        gate.entered.add_permits(1);
                        gate.release.acquire().await.unwrap().forget();
                    }
                }
                reply(&request, answer)
            }
        });
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Self { base, seen, server }
    }

    fn requests(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

fn reply(request: &Seen, answer: Answer) -> Response {
    if matches!(answer, Answer::Refused) {
        return (StatusCode::PROXY_AUTHENTICATION_REQUIRED, "fixture refusal").into_response();
    }
    let path = request.uri.path();
    if path.starts_with("/qpage/") || path.starts_with("/upage/") {
        return ([("set-cookie", "ctoken=fixture; Path=/; HttpOnly")], "share page")
            .into_response();
    }
    if path == "/qtoken" || path == "/utoken" {
        return match answer {
            Answer::Locked => r#"{"status":400,"code":41001,"message":"需要提取码"}"#.into_response(),
            Answer::Risk => (StatusCode::TOO_MANY_REQUESTS, "请求过于频繁").into_response(),
            _ => r#"{"status":200,"code":0,"data":{"stoken":"ST+/=&next=%value","title":"fixture"}}"#.into_response(),
        };
    }
    match path {
        "/qdetail" | "/udetail" => r#"{"status":200,"code":0,"data":{"list":[{"fid":"f1","file_name":"A.mp4","file_type":0,"size":"1"}]}}"#.into_response(),
        "/bs/1Ab_Cd" => (
            StatusCode::FOUND,
            [("location", "/baidu-page"), ("set-cookie", "BAIDUID=abc; Path=/")],
            "",
        ).into_response(),
        "/baidu-page" => ([("set-cookie", "SHARE_CONTEXT=page; Path=/")], PAGE).into_response(),
        "/share/verify" => (
            [("set-cookie", "VERIFY_CONTEXT=verify; Path=/")],
            r#"{"errno":0,"randsk":"a%2Bb+c"}"#,
        ).into_response(),
        "/share/list" => r#"{"errno":0,"list":[{"fs_id":1,"server_filename":"episode01.mkv","isdir":0}]}"#.into_response(),
        "/captcha/init" => r#"{"captcha_token":"fixture-captcha"}"#.into_response(),
        "/drive/v1/share" if !query(request).contains_key("captcha_token") => {
            (StatusCode::FORBIDDEN, r#"{"error":"captcha_required"}"#).into_response()
        }
        "/drive/v1/share" => r#"{"share_status_text":"OK","files":[{"id":"f1"}]}"#.into_response(),
        "/adrive/get_share_by_anonymous" => r#"{"has_share":true,"file_count":1}"#.into_response(),
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

fn endpoints(base: &str) -> PanEndpoints {
    PanEndpoints {
        quark_page: format!("{base}/qpage"),
        quark_token: format!("{base}/qtoken"),
        quark_detail: format!("{base}/qdetail"),
        uc_page: format!("{base}/upage"),
        uc_token: format!("{base}/utoken"),
        uc_detail: format!("{base}/udetail"),
        baidu_page: format!("{base}/bs"),
        baidu_verify: format!("{base}/share/verify?fixture=preserved"),
        baidu_list: format!("{base}/share/list"),
        xunlei_captcha: format!("{base}/captcha/init"),
        xunlei_share: format!("{base}/drive/v1/share"),
        aliyun_anon: format!("{base}/adrive/get_share_by_anonymous"),
    }
}

fn configure(store: &ProxyStore, provider: &str, proxy: &str) {
    store.set(provider, ProxyConfig {
        mode: ProxyMode::Custom,
        url: Some(proxy.into()),
        bypass: vec![],
        username: None,
        ..Default::default()
    }).unwrap();
}

fn query(request: &Seen) -> BTreeMap<String, String> {
    reqwest::Url::parse(&format!("http://fixture.invalid/?{}", request.uri.query().unwrap_or("")))
        .unwrap().query_pairs().into_owned().collect()
}

fn cookie(request: &Seen) -> &str {
    request.headers.get("cookie").and_then(|v| v.to_str().ok()).unwrap_or("")
}

async fn check(checker: &PanChecker, store: &Arc<ProxyStore>, provider: &str, url: &str, pwd: &str) -> Value {
    let results = checker.check_with_proxy(
        &[json!({"url":url,"pwd":pwd})], store.clone(), provider,
    ).await.unwrap();
    assert_eq!(results.len(), 1);
    results[0].clone()
}

#[tokio::test]
async fn five_protocols_use_proxy_and_retain_headers_queries_bodies_and_order() {
    let origin = Fixture::start(Answer::Healthy).await;
    let proxy = Fixture::start(Answer::Healthy).await;
    let checker = PanChecker::with_endpoints(endpoints(&origin.base));
    let store = Arc::new(ProxyStore::new());
    configure(&store, GLOBAL_PROXY, &proxy.base);
    let items = [QUARK, UC, BAIDU, ALI, XUNLEI].map(|url| json!({"url":url,"pwd":"a1b2"}));
    let result = checker.check_with_proxy(&items, store, "fixture-source").await.unwrap();
    assert_eq!(result.iter().map(|r| r["kind"].as_str().unwrap()).collect::<Vec<_>>(),
        ["quark", "uc", "baidu", "aliyun", "xunlei"]);
    assert!(result.iter().all(|r| r["state"] == "ok"), "{result:?}");
    let requests = proxy.requests();
    assert_eq!(requests.len(), 14, "all five request sequences must use the configured proxy");
    assert!(origin.requests().is_empty(), "a configured proxy must receive every request");
    assert!(requests.iter().all(|r| r.uri.scheme_str() == Some("http")));
    for (token_path, detail_path, pr, share_origin) in [
        ("/qtoken", "/qdetail", "ucpro", "https://pan.quark.cn"),
        ("/utoken", "/udetail", "UCBrowser", "https://drive.uc.cn"),
    ] {
        let token = requests.iter().find(|r| r.uri.path() == token_path).unwrap();
        assert_eq!(token.method, Method::POST);
        assert_eq!(token.headers["user-agent"], UA_DESKTOP);
        assert_eq!(token.headers["origin"], share_origin);
        assert_eq!(query(token)["pr"], pr);
        assert_eq!(query(token)["fr"], "pc");
        assert_eq!(cookie(token), "ctoken=fixture");
        let body: Value = serde_json::from_slice(&token.body).unwrap();
        assert_eq!(body["pwd_id"], "proxy-fixture");
        assert_eq!(body["passcode"], "a1b2");
        let detail = requests.iter().find(|r| r.uri.path() == detail_path).unwrap();
        assert_eq!(query(detail)["stoken"], "ST+/=&next=%value");
        assert_eq!(query(detail)["pdir_fid"], "0");
        assert!(!query(detail).contains_key("next"));
        assert_eq!(cookie(detail), "ctoken=fixture");
    }
    let xl: Vec<_> = requests.iter().filter(|r| r.uri.path() == "/drive/v1/share").collect();
    assert_eq!(xl.len(), 2);
    assert_eq!(xl[0].headers["user-agent"], UA_MOBILE);
    assert_eq!(xl[0].headers["x-device-id"], XL_DEVICE_ID);
    assert_eq!(xl[0].headers["x-client-id"], XL_CLIENT_ID);
    assert_eq!(query(xl[1])["captcha_token"], "fixture-captcha");
    let ali = requests.iter().find(|r| r.uri.path() == "/adrive/get_share_by_anonymous").unwrap();
    assert_eq!(ali.headers["referer"], "https://www.alipan.com");
    assert_eq!(query(ali)["share_id"], "proxy-fixture");
}

#[tokio::test]
async fn baidu_inner_page_redirect_verify_and_list_use_proxy_without_account_cookies() {
    let origin = Fixture::start(Answer::Healthy).await;
    let proxy = Fixture::start(Answer::Healthy).await;
    let checker = PanChecker::with_endpoints(endpoints(&origin.base));
    let store = Arc::new(ProxyStore::new());
    configure(&store, GLOBAL_PROXY, &proxy.base);
    assert_eq!(check(&checker, &store, "baidu", BAIDU, "p +&=/?中").await["state"], "ok");
    let requests = proxy.requests();
    assert_eq!(requests.iter().map(|r| r.uri.path()).collect::<Vec<_>>(),
        ["/bs/1Ab_Cd", "/baidu-page", "/share/verify", "/share/list"]);
    assert!(origin.requests().is_empty());
    assert!(cookie(&requests[0]).is_empty());
    assert_eq!(cookie(&requests[1]), "BAIDUID=abc");
    let verify = &requests[2];
    assert_eq!(verify.method, Method::POST);
    for (key, value) in [("fixture", "preserved"), ("surl", "Ab_Cd"),
        ("bioc", "1"), ("bdstoken", "PAGE_TOKEN"), ("logid", "YWJj")] {
        assert_eq!(query(verify)[key], value);
    }
    let form: BTreeMap<_, _> = reqwest::Url::parse(&format!(
        "http://fixture.invalid/?{}", String::from_utf8_lossy(&verify.body),
    )).unwrap().query_pairs().into_owned().collect();
    assert_eq!(form["pwd"], "p +&=/?中");
    assert_eq!(form.keys().map(String::as_str).collect::<Vec<_>>(), ["pwd", "vcode", "vcode_str"]);
    assert!(cookie(verify).contains("SHARE_CONTEXT=page"));
    let list = &requests[3];
    assert!(cookie(list).contains("BDCLND=a%2Bb+c"));
    assert!(cookie(list).contains("VERIFY_CONTEXT=verify"));
    assert!(!cookie(list).contains("BDUSS"));
    assert_eq!(query(list)["sekey"], "a+b+c");
    assert_eq!(query(list)["root"], "1");
    assert_eq!(list.headers["x-requested-with"], "XMLHttpRequest");
}

#[tokio::test]
async fn policy_revision_rechecks_identical_url_and_password_instead_of_reusing_cached_verdict() {
    let origin = Fixture::start(Answer::Locked).await;
    let first = Fixture::start(Answer::Locked).await;
    let second = Fixture::start(Answer::Healthy).await;
    let checker = PanChecker::with_endpoints(endpoints(&origin.base));
    let store = Arc::new(ProxyStore::new());
    configure(&store, GLOBAL_PROXY, &first.base);
    assert_eq!(check(&checker, &store, "source", QUARK, "code").await["state"], "locked");
    assert_eq!(check(&checker, &store, "source", QUARK, "code").await["state"], "locked");
    assert_eq!(first.requests().len(), 2, "the first route must cache its result");
    configure(&store, GLOBAL_PROXY, &second.base);
    assert_eq!(check(&checker, &store, "source", QUARK, "code").await["state"], "ok");
    assert_eq!(second.requests().len(), 3);
    assert!(origin.requests().is_empty());
}

#[tokio::test]
async fn passcode_is_part_of_the_proxy_cache_key() {
    let origin = Fixture::start(Answer::Locked).await;
    let proxy = Fixture::start(Answer::Locked).await;
    let checker = PanChecker::with_endpoints(endpoints(&origin.base));
    let store = Arc::new(ProxyStore::new());
    configure(&store, GLOBAL_PROXY, &proxy.base);
    for pwd in ["one", "one", "two"] {
        assert_eq!(check(&checker, &store, "source", QUARK, pwd).await["state"], "locked");
    }
    let tokens: Vec<Value> = proxy.requests().iter().filter(|r| r.uri.path() == "/qtoken")
        .map(|r| serde_json::from_slice(&r.body).unwrap()).collect();
    assert_eq!(tokens.iter().map(|r| r["passcode"].as_str().unwrap()).collect::<Vec<_>>(), ["one", "two"]);
    assert!(origin.requests().is_empty());
}

#[tokio::test]
async fn policy_change_exits_old_route_cooldown_without_waiting_thirty_seconds() {
    let origin = Fixture::start(Answer::Risk).await;
    let first = Fixture::start(Answer::Risk).await;
    let second = Fixture::start(Answer::Healthy).await;
    let checker = PanChecker::with_endpoints(endpoints(&origin.base));
    let store = Arc::new(ProxyStore::new());
    configure(&store, GLOBAL_PROXY, &first.base);
    let first_result = check(&checker, &store, "source", QUARK, "code").await;
    assert_eq!(first_result["state"], "uncertain");
    assert_eq!(first_result["cacheable"], false);
    assert_eq!(check(&checker, &store, "source", QUARK, "other").await["state"], "uncertain");
    assert_eq!(first.requests().len(), 2, "cooldown must suppress another request on the same route");
    configure(&store, GLOBAL_PROXY, &second.base);
    assert_eq!(check(&checker, &store, "source", QUARK, "code").await["state"], "ok");
    assert_eq!(second.requests().len(), 3);
    assert!(origin.requests().is_empty());
}

#[tokio::test]
async fn stores_and_provider_origins_do_not_share_results_even_with_equal_revision() {
    let origin = Fixture::start(Answer::Locked).await;
    let first = Fixture::start(Answer::Locked).await;
    let second = Fixture::start(Answer::Healthy).await;
    let checker = PanChecker::with_endpoints(endpoints(&origin.base));
    let one = Arc::new(ProxyStore::new());
    let two = Arc::new(ProxyStore::new());
    configure(&one, "same-source", &first.base);
    configure(&two, "same-source", &second.base);
    assert_eq!(one.policy_revision(), two.policy_revision());
    assert_eq!(check(&checker, &one, "same-source", QUARK, "code").await["state"], "locked");
    assert_eq!(check(&checker, &two, "same-source", QUARK, "code").await["state"], "ok");
    configure(&one, "other-source", &second.base);
    assert_eq!(check(&checker, &one, "same-source", QUARK, "code").await["state"], "locked");
    assert_eq!(check(&checker, &one, "other-source", QUARK, "code").await["state"], "ok");
    assert_eq!(second.requests().len(), 6);
    assert!(origin.requests().is_empty());
}

#[tokio::test]
async fn in_flight_old_revision_cannot_publish_into_new_route_cache() {
    let origin = Fixture::start(Answer::Locked).await;
    let gate = Gate::new();
    let first = Fixture::with_gate(Answer::Locked, Some(gate.clone())).await;
    let second = Fixture::start(Answer::Healthy).await;
    let checker = PanChecker::with_endpoints(endpoints(&origin.base));
    let store = Arc::new(ProxyStore::new());
    configure(&store, GLOBAL_PROXY, &first.base);
    let pending_checker = checker.clone();
    let pending_store = store.clone();
    let pending = tokio::spawn(async move {
        check(&pending_checker, &pending_store, "source", QUARK, "code").await
    });
    gate.wait().await;
    configure(&store, GLOBAL_PROXY, &second.base);
    assert_eq!(check(&checker, &store, "source", QUARK, "code").await["state"], "ok");
    gate.release.add_permits(1);
    assert_eq!(pending.await.unwrap()["state"], "locked");
    assert_eq!(check(&checker, &store, "source", QUARK, "code").await["state"], "ok");
    assert_eq!(second.requests().len(), 3, "new result remains cached after old request completion");
    assert!(origin.requests().is_empty());
}

#[tokio::test]
async fn failed_proxy_never_retries_direct_and_explicit_direct_is_the_only_origin_route() {
    let origin = Fixture::start(Answer::Healthy).await;
    let refused = Fixture::start(Answer::Refused).await;
    let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    let store = Arc::new(ProxyStore::new());
    for proxy in [&unavailable, &refused.base] {
        configure(&store, GLOBAL_PROXY, proxy);
        let checker = PanChecker::with_endpoints(endpoints(&origin.base));
        for share in [QUARK, UC, BAIDU, ALI, XUNLEI] {
            let result = check(&checker, &store, "source", share, "code").await;
            assert_eq!(result["state"], "uncertain", "{share}: {result}");
            assert_eq!(result["cacheable"], false);
        }
        assert!(origin.requests().is_empty(), "failed proxy must never leak a request to the origin");
    }
    store.set(GLOBAL_PROXY, ProxyConfig::default()).unwrap();
    let checker = PanChecker::with_endpoints(endpoints(&origin.base));
    assert_eq!(check(&checker, &store, "source", QUARK, "code").await["state"], "ok");
    assert_eq!(origin.requests().len(), 3);
}

#[tokio::test]
async fn command_uses_real_application_store_on_every_call_and_keeps_items_json_contract() {
    let origin = Fixture::start(Answer::Locked).await;
    let first = Fixture::start(Answer::Locked).await;
    let second = Fixture::start(Answer::Healthy).await;
    let checker = Box::leak(Box::new(PanChecker::with_endpoints(endpoints(&origin.base))));
    let _override = override_global_checker_for_tests(checker);
    let dir = std::env::temp_dir().join(format!("sourin-pan-proxy-command-{}-{}",
        std::process::id(), chrono::Utc::now().timestamp_nanos_opt().unwrap()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
    let state = crate::state::AppState::bootstrap(dir).await.unwrap();
    let items = json!([{"url":QUARK,"pwd":"code"}]).to_string();
    configure(&state.proxy, GLOBAL_PROXY, &first.base);
    let a = command_check_for_state(&state, "actual-source", &items).await.unwrap();
    configure(&state.proxy, GLOBAL_PROXY, &second.base);
    let b = command_check_for_state(&state, "actual-source", &items).await.unwrap();
    assert_eq!(a["results"][0]["state"], "locked");
    assert_eq!(b["results"][0]["state"], "ok");
    assert_eq!(b["ok"], true);
    assert_eq!(b["truncated"], 0);
    assert_eq!(first.requests().len(), 2);
    assert_eq!(second.requests().len(), 3);
    assert!(origin.requests().is_empty());
    assert!(command_check_for_state(&state, "actual-source", "{}").await.is_err());
    let empty = command_check_for_state(&state, "tvbox", "[]").await.unwrap();
    assert_eq!(empty["results"], json!([]));
    // Older internal callers retain the items-only entry and its pure validation.
    assert_eq!(command_check("[]").await.unwrap()["results"], json!([]));
}
