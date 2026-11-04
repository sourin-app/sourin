use super::{resolve_with, BaiduEndpoints};
use axum::{
    body::{to_bytes, Body},
    http::{HeaderMap, Request, StatusCode},
    Router,
};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

const SHARE_PAGE: &str = r#"<html><script>locals.mset({"shareid":123,"share_uk":456,"bdstoken":"PAGE_TOKEN"});</script></html>"#;
const VERIFY_OK: &str = r#"{"errno":0,"randsk":"RANDOM_SHARE_KEY"}"#;
const LIST_OK: &str = r#"{"errno":0,"list":[{"fs_id":1,"server_filename":"episode01.mkv"}]}"#;
const ECHO: &str = "SYNTHETIC_RESPONSE_MUST_NOT_ESCAPE";

#[derive(Clone)]
struct Reply {
    path: &'static str,
    status: u16,
    body: String,
    headers: Vec<(&'static str, &'static str)>,
    redirect_to: Option<String>,
    cookie_headers: Vec<String>,
    delay: std::time::Duration,
}

impl Reply {
    fn ok(path: &'static str, body: &str) -> Self {
        Self {
            path,
            status: 200,
            body: body.into(),
            headers: Vec::new(),
            redirect_to: None,
            cookie_headers: Vec::new(),
            delay: std::time::Duration::ZERO,
        }
    }
}

#[derive(Clone)]
struct Seen {
    path: String,
    target: String,
    headers: HeaderMap,
    body: String,
}

struct Replay {
    endpoints: BaiduEndpoints,
    seen: Arc<Mutex<Vec<Seen>>>,
    task: tokio::task::JoinHandle<()>,
}

impl Replay {
    async fn start(replies: Vec<Reply>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let capture = seen.clone();
        let replies = Arc::new(replies);
        let router = Router::new().fallback(move |request: Request<Body>| {
            let capture = capture.clone();
            let replies = replies.clone();
            async move {
                let path = request.uri().path().to_string();
                let target = request.uri().to_string();
                let headers = request.headers().clone();
                let body = to_bytes(request.into_body(), 64 * 1024).await.unwrap();
                capture.lock().unwrap().push(Seen {
                    path: path.clone(),
                    target,
                    headers,
                    body: String::from_utf8(body.to_vec()).unwrap(),
                });
                let response = replies.iter().find(|reply| path == reply.path);
                let Some(response) = response else {
                    return (StatusCode::NOT_FOUND, HeaderMap::new(), String::new());
                };
                let mut headers = HeaderMap::new();
                for (key, value) in &response.headers {
                    headers.append(*key, value.parse().unwrap());
                }
                if let Some(location) = &response.redirect_to {
                    headers.insert("location", location.parse().unwrap());
                }
                for cookie in &response.cookie_headers {
                    headers.append("set-cookie", cookie.parse().unwrap());
                }
                tokio::time::sleep(response.delay).await;
                (
                    StatusCode::from_u16(response.status).unwrap(),
                    headers,
                    response.body.clone(),
                )
            }
        });
        let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        Self {
            endpoints: BaiduEndpoints {
                page: format!("{base}/s"),
                verify: format!("{base}/share/verify"),
                list: format!("{base}/share/list"),
            },
            seen,
            task,
        }
    }

    async fn standard(page: &str, verify: &str, list: &str) -> Self {
        Self::start(vec![
            Reply::ok("/s/5Ab_Cd", page),
            Reply::ok("/share/verify", verify),
            Reply::ok("/share/list", list),
        ])
        .await
    }

    fn requests(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }

    async fn resolve(&self, pwd: &str) -> String {
        resolve_with(
            &self.endpoints,
            Some("BDUSS=SEED; BAIDUID=abc"),
            "5Ab_Cd",
            pwd,
        )
        .await
        .expect_err("the complete-file dlink boundary must remain an error")
    }
}

impl Drop for Replay {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn pairs(form: &str) -> BTreeMap<String, String> {
    reqwest::Url::parse(&format!("http://fixture.invalid/?{form}"))
        .unwrap()
        .query_pairs()
        .into_owned()
        .collect()
}

fn cookies(request: &Seen) -> BTreeMap<String, String> {
    request
        .headers
        .get("cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .split(';')
        .filter_map(|part| part.trim().split_once('='))
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect()
}

#[tokio::test]
async fn official_verify_query_form_and_ajax_metadata_are_observed_on_wire() {
    let mut replay = Replay::standard(SHARE_PAGE, VERIFY_OK, LIST_OK).await;
    replay.endpoints.verify.push_str("?fixture=preserved");
    let error = replay.resolve("p +&=/?中").await;
    assert!(error.contains("dlink"));
    let seen = replay.requests();
    let verify = seen
        .iter()
        .find(|request| request.path == "/share/verify")
        .unwrap();
    let query = pairs(verify.target.split_once('?').unwrap().1);
    assert_eq!(query.get("surl").map(String::as_str), Some("Ab_Cd"));
    assert_eq!(query.get("bioc").map(String::as_str), Some("1"));
    assert!(query.get("t").unwrap().parse::<u128>().unwrap() > 0);
    for (key, value) in [
        ("fixture", "preserved"),
        ("channel", "chunlei"),
        ("web", "1"),
        ("app_id", "250528"),
        ("clienttype", "0"),
        ("bdstoken", "PAGE_TOKEN"),
        ("logid", "YWJj"),
    ] {
        assert_eq!(query.get(key).map(String::as_str), Some(value));
    }
    let body = pairs(&verify.body);
    assert_eq!(
        body.keys().map(String::as_str).collect::<Vec<_>>(),
        ["pwd", "vcode", "vcode_str"]
    );
    assert_eq!(body.get("pwd").map(String::as_str), Some("p +&=/?中"));
    assert_eq!(body.get("vcode").map(String::as_str), Some(""));
    assert_eq!(body.get("vcode_str").map(String::as_str), Some(""));
    assert!(verify
        .headers
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .starts_with("application/x-www-form-urlencoded"));
}

#[tokio::test]
async fn normal_share_with_login_widget_continues_without_expiry_claim() {
    let page = format!(
        "{SHARE_PAGE}<script>passLoginType='qrcode';</script><button>登录百度网盘</button>"
    );
    let replay = Replay::standard(&page, VERIFY_OK, LIST_OK).await;
    let error = replay.resolve("pwd").await;
    assert!(error.contains("dlink"));
    assert!(!error.contains("已失效") && !error.starts_with("NEED_LOGIN:"));
    assert_eq!(replay.requests().len(), 3);
}

#[tokio::test]
async fn login_only_response_does_not_prove_saved_account_expiry() {
    let replay = Replay::standard(
        "<title>登录百度网盘</title><script>passLoginType='qrcode'</script>",
        VERIFY_OK,
        LIST_OK,
    )
    .await;
    let error = replay.resolve("pwd").await;
    assert!(error.contains("当前请求未获分享信息"));
    assert!(
        !error.contains("已失效") && !error.contains("重新") && !error.starts_with("NEED_LOGIN:")
    );
    assert_eq!(replay.requests().len(), 1);
}

#[tokio::test]
async fn response_cookie_rotation_and_randsk_reach_the_actual_list_request() {
    let mut page = Reply::ok("/s/5Ab_Cd", SHARE_PAGE);
    page.headers = vec![
        ("set-cookie", "BDUSS=ROTATED; Path=/; HttpOnly"),
        ("set-cookie", "PAGE_SESSION=NEW; Path=/"),
    ];
    let mut verify = Reply::ok("/share/verify", VERIFY_OK);
    verify.headers = vec![
        ("set-cookie", "VERIFY_SESSION=NEW; Path=/"),
        ("set-cookie", "BDCLND=REPLACED_BY_RANDSK; Path=/"),
    ];
    let replay = Replay::start(vec![page, verify, Reply::ok("/share/list", LIST_OK)]).await;
    let error = replay.resolve("pwd").await;
    assert!(error.contains("dlink"));
    let seen = replay.requests();
    let verify = cookies(
        seen.iter()
            .find(|request| request.path == "/share/verify")
            .unwrap(),
    );
    assert_eq!(verify.get("BDUSS").map(String::as_str), Some("ROTATED"));
    assert_eq!(verify.get("PAGE_SESSION").map(String::as_str), Some("NEW"));
    let list = seen
        .iter()
        .find(|request| request.path == "/share/list")
        .unwrap();
    let cookie = cookies(list);
    assert_eq!(cookie.get("BDUSS").map(String::as_str), Some("ROTATED"));
    assert_eq!(cookie.get("PAGE_SESSION").map(String::as_str), Some("NEW"));
    assert_eq!(
        cookie.get("VERIFY_SESSION").map(String::as_str),
        Some("NEW")
    );
    assert_eq!(
        cookie.get("BDCLND").map(String::as_str),
        Some("RANDOM_SHARE_KEY")
    );
    assert!(!cookie.contains_key("Path") && !cookie.contains_key("HttpOnly"));
    assert_eq!(
        pairs(list.target.split_once('?').unwrap().1)
            .get("sekey")
            .map(String::as_str),
        Some("RANDOM_SHARE_KEY")
    );
}

#[tokio::test]
async fn missing_empty_or_nonstring_randsk_cannot_advance_to_listing() {
    for value in [
        serde_json::Value::Null,
        "".into(),
        "   ".into(),
        123.into(),
        "unsafe;pair=x".into(),
    ] {
        let verify = serde_json::json!({"errno":0,"randsk":value}).to_string();
        let replay = Replay::standard(SHARE_PAGE, &verify, LIST_OK).await;
        let error = replay.resolve("pwd").await;
        assert!(error.contains("randsk"));
        assert!(!error.contains("dlink"));
        assert_eq!(replay.requests().len(), 2);
    }
}

#[tokio::test]
async fn noninteger_errno_is_not_an_invented_integer_business_code() {
    for value in [
        serde_json::Value::Null,
        false.into(),
        true.into(),
        "0".into(),
        serde_json::json!(0.0),
    ] {
        let verify = serde_json::json!({"errno":value,"randsk":"fixture"}).to_string();
        let replay = Replay::standard(SHARE_PAGE, &verify, LIST_OK).await;
        let error = replay.resolve("pwd").await;
        assert!(error.contains("整数 errno"));
        assert!(!error.contains("errno=-1") && !error.contains("dlink"));
        assert_eq!(replay.requests().len(), 2);
    }
}

#[tokio::test]
async fn unknown_verify_integer_code_is_reported_without_guess_or_reflection() {
    let body =
        serde_json::json!({"errno":-9876,"errmsg":ECHO,"url":"https://fixture.invalid/sensitive"})
            .to_string();
    let replay = Replay::standard(SHARE_PAGE, &body, LIST_OK).await;
    let error = replay.resolve("pwd").await;
    assert!(error.contains("errno=-9876"));
    assert!(!error.contains(ECHO) && !error.contains("失效") && !error.contains("不对"));
}

#[tokio::test]
async fn verify_http_error_cannot_reflect_an_authenticated_response() {
    let mut verify = Reply::ok("/share/verify", ECHO);
    verify.status = 403;
    let replay = Replay::start(vec![Reply::ok("/s/5Ab_Cd", SHARE_PAGE), verify]).await;
    let error = replay.resolve("pwd").await;
    assert!(error.contains("HTTP 403"));
    assert!(!error.contains(ECHO));
}

#[tokio::test]
async fn malformed_verify_json_cannot_reflect_response_text() {
    let replay = Replay::standard(SHARE_PAGE, ECHO, LIST_OK).await;
    let error = replay.resolve("pwd").await;
    assert!(error.contains("JSON"));
    assert!(!error.contains(ECHO));
}

#[tokio::test]
async fn malformed_list_json_cannot_reflect_response_text() {
    let replay = Replay::standard(SHARE_PAGE, VERIFY_OK, ECHO).await;
    let error = replay.resolve("").await;
    assert!(error.contains("JSON"));
    assert!(!error.contains(ECHO));
}

#[tokio::test]
async fn page_http_error_cannot_reflect_response_text() {
    let mut page = Reply::ok("/s/5Ab_Cd", ECHO);
    page.status = 500;
    let replay = Replay::start(vec![page]).await;
    let error = replay.resolve("pwd").await;
    assert!(error.contains("HTTP 500"));
    assert!(!error.contains(ECHO));
}

#[tokio::test]
async fn redirect_response_cookie_reaches_the_followed_same_origin_page() {
    let mut redirect = Reply::ok("/s/5Ab_Cd", "");
    redirect.status = 302;
    redirect.headers = vec![
        ("location", "/landing"),
        ("set-cookie", "BDUSS=REDIRECT_ROTATED; Path=/"),
    ];
    let replay = Replay::start(vec![
        redirect,
        Reply::ok("/landing", SHARE_PAGE),
        Reply::ok("/share/verify", VERIFY_OK),
        Reply::ok("/share/list", LIST_OK),
    ])
    .await;
    let error = replay.resolve("pwd").await;
    assert!(error.contains("dlink"));
    let seen = replay.requests();
    assert_eq!(
        cookies(
            seen.iter()
                .find(|request| request.path == "/landing")
                .unwrap()
        )
        .get("BDUSS")
        .map(String::as_str),
        Some("REDIRECT_ROTATED")
    );
}

#[tokio::test]
async fn raw_bdclnd_and_percent_only_sekey_do_not_form_decode_plus() {
    let verify = r#"{"errno":0,"randsk":"a%2Bb+c%2F"}"#;
    let replay = Replay::standard(SHARE_PAGE, verify, LIST_OK).await;
    assert!(replay.resolve("pwd").await.contains("dlink"));
    let seen = replay.requests();
    let list = seen
        .iter()
        .find(|request| request.path == "/share/list")
        .unwrap();
    assert_eq!(
        cookies(list).get("BDCLND").map(String::as_str),
        Some("a%2Bb+c%2F")
    );
    assert_eq!(
        pairs(list.target.split_once('?').unwrap().1)
            .get("sekey")
            .map(String::as_str),
        Some("a+b+c/")
    );
}

#[tokio::test]
async fn third_origin_redirect_is_refused_before_any_third_origin_request() {
    let third = Replay::standard(SHARE_PAGE, VERIFY_OK, LIST_OK).await;
    let mut redirect = Reply::ok("/s/5Ab_Cd", "");
    redirect.status = 302;
    redirect.redirect_to = Some(format!("{}/5Ab_Cd", third.endpoints.page));
    let replay = Replay::start(vec![redirect]).await;
    let error = replay.resolve("pwd").await;
    assert!(error.contains("跳转"));
    assert!(third.requests().is_empty());
}

#[tokio::test]
async fn cookie_paths_and_max_age_deletions_are_observed_on_wire() {
    let mut page = Reply::ok("/s/5Ab_Cd", SHARE_PAGE);
    page.headers = vec![
        ("set-cookie", "VERIFY_ONLY=YES; Path=/share/verify"),
        ("set-cookie", "TO_DELETE=; Max-Age=0; Path=/"),
    ];
    let replay = Replay::start(vec![
        page,
        Reply::ok("/share/verify", VERIFY_OK),
        Reply::ok("/share/list", LIST_OK),
    ])
    .await;
    let error = resolve_with(
        &replay.endpoints,
        Some("BDUSS=SEED; TO_DELETE=SEED"),
        "5Ab_Cd",
        "pwd",
    )
    .await
    .expect_err("dlink is not integrated");
    assert!(error.contains("dlink"));
    let seen = replay.requests();
    let verify = cookies(
        seen.iter()
            .find(|request| request.path == "/share/verify")
            .unwrap(),
    );
    assert_eq!(verify.get("VERIFY_ONLY").map(String::as_str), Some("YES"));
    assert!(!verify.contains_key("TO_DELETE"));
    let list = cookies(
        seen.iter()
            .find(|request| request.path == "/share/list")
            .unwrap(),
    );
    assert!(!list.contains_key("VERIFY_ONLY") && !list.contains_key("TO_DELETE"));
}

#[tokio::test]
async fn unknown_list_code_and_noninteger_list_errno_are_not_guessed() {
    let unknown = serde_json::json!({"errno":-9876,"errmsg":ECHO}).to_string();
    let replay = Replay::standard(SHARE_PAGE, VERIFY_OK, &unknown).await;
    let error = replay.resolve("").await;
    assert!(error.contains("errno=-9876"));
    assert!(!error.contains(ECHO) && !error.contains("失效"));
    let replay = Replay::standard(SHARE_PAGE, VERIFY_OK, r#"{"errno":false,"list":[{}]}"#).await;
    let error = replay.resolve("").await;
    assert!(error.contains("整数 errno"));
    assert!(!error.contains("errno=-1") && !error.contains("dlink"));
}

#[tokio::test]
async fn transport_errors_do_not_reflect_request_url_or_cookie_values() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    let endpoints = BaiduEndpoints {
        page: format!("{base}/s?marker={ECHO}"),
        verify: format!("{base}/share/verify"),
        list: format!("{base}/share/list"),
    };
    let error = resolve_with(&endpoints, Some("BDUSS=SYNTHETIC_COOKIE"), "5Ab_Cd", "pwd")
        .await
        .expect_err("the closed loopback port must fail");
    assert!(!error.contains(ECHO) && !error.contains("SYNTHETIC_COOKIE") && !error.contains(&base));
}

#[tokio::test]
async fn latest_randsk_removes_shadowing_bdclnd_from_other_cookie_paths() {
    let mut verify = Reply::ok("/share/verify", VERIFY_OK);
    verify.headers = vec![("set-cookie", "BDCLND=STALE_SCOPED_KEY; Path=/share")];
    let replay = Replay::start(vec![
        Reply::ok("/s/5Ab_Cd", SHARE_PAGE),
        verify,
        Reply::ok("/share/list", LIST_OK),
    ])
    .await;
    assert!(replay.resolve("pwd").await.contains("dlink"));
    let seen = replay.requests();
    let list = seen
        .iter()
        .find(|request| request.path == "/share/list")
        .unwrap();
    let cookie = list.headers.get("cookie").unwrap().to_str().unwrap();
    assert_eq!(
        cookie
            .split(';')
            .filter(|pair| pair.trim().starts_with("BDCLND="))
            .count(),
        1
    );
    assert_eq!(
        cookies(list).get("BDCLND").map(String::as_str),
        Some("RANDOM_SHARE_KEY")
    );
}

#[test]
fn business_endpoint_parser_accepts_only_official_pan_or_loopback() {
    for url in [
        "https://pan.baidu.com/s",
        "http://127.0.0.1:1234/s",
        "http://[::1]:1234/s",
    ] {
        assert!(super::endpoint(url).is_ok());
    }
    for url in [
        "https://example.invalid/s",
        "https://passport.baidu.com/share/verify",
        "http://pan.baidu.com/s",
        "https://pan.baidu.com:444/s",
    ] {
        assert!(super::endpoint(url).is_err());
    }
}

fn expiry_header(seconds: i64) -> String {
    (chrono::Utc::now() + chrono::Duration::seconds(seconds))
        .format("%a, %d %b %Y %H:%M:%S GMT")
        .to_string()
}

#[tokio::test]
async fn cookie_max_age_elapsed_between_hops_filters_actual_header_and_value() {
    let mut page = Reply::ok("/s/5Ab_Cd", SHARE_PAGE);
    page.headers = vec![("set-cookie", "BAIDUID=temporary; Max-Age=1; Path=/")];
    let mut verify = Reply::ok("/share/verify", VERIFY_OK);
    verify.delay = std::time::Duration::from_millis(2100);
    let replay = Replay::start(vec![page, verify, Reply::ok("/share/list", LIST_OK)]).await;
    assert!(replay.resolve("pwd").await.contains("dlink"));
    let seen = replay.requests();
    let verify = seen
        .iter()
        .find(|request| request.path == "/share/verify")
        .unwrap();
    assert_eq!(
        cookies(verify).get("BAIDUID").map(String::as_str),
        Some("temporary")
    );
    assert_eq!(
        pairs(verify.target.split_once('?').unwrap().1)
            .get("logid")
            .map(String::as_str),
        Some("dGVtcG9yYXJ5")
    );
    let list = seen
        .iter()
        .find(|request| request.path == "/share/list")
        .unwrap();
    assert!(!cookies(list).contains_key("BAIDUID"));
    assert_eq!(
        pairs(list.target.split_once('?').unwrap().1)
            .get("logid")
            .map(String::as_str),
        Some("")
    );
}

#[tokio::test]
async fn cookie_future_expires_elapsed_between_hops_filters_actual_header() {
    let mut page = Reply::ok("/s/5Ab_Cd", SHARE_PAGE);
    page.cookie_headers = vec![format!(
        "FUTURE_COOKIE=temporary; Expires={}; Path=/",
        expiry_header(3)
    )];
    let mut verify = Reply::ok("/share/verify", VERIFY_OK);
    verify.delay = std::time::Duration::from_millis(3200);
    let replay = Replay::start(vec![page, verify, Reply::ok("/share/list", LIST_OK)]).await;
    assert!(replay.resolve("pwd").await.contains("dlink"));
    let seen = replay.requests();
    let verify = seen
        .iter()
        .find(|request| request.path == "/share/verify")
        .unwrap();
    assert_eq!(
        cookies(verify).get("FUTURE_COOKIE").map(String::as_str),
        Some("temporary")
    );
    let list = seen
        .iter()
        .find(|request| request.path == "/share/list")
        .unwrap();
    assert!(!cookies(list).contains_key("FUTURE_COOKIE"));
}

#[tokio::test]
async fn cookie_lifetime_keeps_unexpired_values_and_max_age_overrides_expires() {
    let future = expiry_header(86400);
    let past = expiry_header(-86400);
    let mut page = Reply::ok("/s/5Ab_Cd", SHARE_PAGE);
    page.cookie_headers = vec![
        "LONG_MAX_AGE=present; Max-Age=30; Path=/".into(),
        format!("LONG_EXPIRES=present; Expires={future}; Path=/"),
        format!("MAX_AGE_WINS=present; Max-Age=30; Expires={past}; Path=/"),
        format!("SHORT_MAX_AGE_WINS=temporary; Max-Age=1; Expires={future}; Path=/"),
        format!("DELETE_WINS=deleted; Max-Age=0; Expires={future}; Path=/"),
    ];
    let mut verify = Reply::ok("/share/verify", VERIFY_OK);
    verify.delay = std::time::Duration::from_millis(2100);
    let replay = Replay::start(vec![page, verify, Reply::ok("/share/list", LIST_OK)]).await;
    assert!(replay.resolve("pwd").await.contains("dlink"));
    let seen = replay.requests();
    let verify = cookies(
        seen.iter()
            .find(|request| request.path == "/share/verify")
            .unwrap(),
    );
    assert_eq!(
        verify.get("SHORT_MAX_AGE_WINS").map(String::as_str),
        Some("temporary")
    );
    assert!(!verify.contains_key("DELETE_WINS"));
    let list = cookies(
        seen.iter()
            .find(|request| request.path == "/share/list")
            .unwrap(),
    );
    for key in ["LONG_MAX_AGE", "LONG_EXPIRES", "MAX_AGE_WINS"] {
        assert_eq!(list.get(key).map(String::as_str), Some("present"));
    }
    assert!(!list.contains_key("SHORT_MAX_AGE_WINS") && !list.contains_key("DELETE_WINS"));
}

#[tokio::test]
async fn late_private_page_preserves_expired_generation_error_without_followup() {
    use super::super::pan_playback_guard as guard;
    let mut page = Reply::ok("/s/5Ab_Cd", SHARE_PAGE);
    page.delay = std::time::Duration::from_millis(350);
    let replay = Replay::start(vec![
        page,
        Reply::ok("/share/verify", VERIFY_OK),
        Reply::ok("/share/list", LIST_OK),
    ])
    .await;
    let owner = guard::PlaybackOwner {
        consumer: "baidu-private-late-page".into(),
        generation: 1,
    };
    guard::register(Some(owner.clone())).unwrap();
    let request = guard::with_scope(Some(owner.clone()), replay.resolve("pwd"));
    let invalidate = async {
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while replay.requests().is_empty() {
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        guard::register(Some(guard::PlaybackOwner {
            generation: 2,
            ..owner
        }))
        .unwrap();
    };
    let (error, _) = tokio::join!(request, invalidate);
    assert_eq!(error, "播放解析请求已过期");
    assert_eq!(
        replay.requests().len(),
        1,
        "stale page cannot send account cookies again"
    );
}

#[tokio::test]
async fn expired_private_generation_is_rejected_before_first_request() {
    use super::super::pan_playback_guard as guard;
    let replay = Replay::standard(SHARE_PAGE, VERIFY_OK, LIST_OK).await;
    let owner = guard::PlaybackOwner {
        consumer: "baidu-private-expired-entry".into(),
        generation: 1,
    };
    guard::register(Some(owner.clone())).unwrap();
    guard::register(Some(guard::PlaybackOwner {
        generation: 2,
        ..owner.clone()
    }))
    .unwrap();
    let error = guard::with_scope(Some(owner), replay.resolve("pwd")).await;
    assert_eq!(error, "播放解析请求已过期");
    assert!(replay.requests().is_empty());
}
