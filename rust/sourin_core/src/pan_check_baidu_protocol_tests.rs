use super::*;
use axum::{
    body::{to_bytes, Body},
    http::{HeaderMap, Request, StatusCode},
    Router,
};
use std::collections::BTreeMap;

const SHARE: &str = "https://pan.baidu.com/s/1Ab_Cd";
const PAGE: &str = r#"<html><script>locals.mset({"shareid":123,"share_uk":456,"bdstoken":"PAGE_TOKEN"});</script></html>"#;
const VERIFY: &str = r#"{"errno":0,"randsk":"a%2Bb+c"}"#;
const LIST: &str =
    r#"{"errno":0,"list":[{"fs_id":1,"server_filename":"episode01.mkv","isdir":0}]}"#;

#[derive(Clone)]
struct Reply {
    path: &'static str,
    status: u16,
    body: String,
    headers: Vec<(&'static str, &'static str)>,
    delay: Duration,
}

impl Reply {
    fn ok(path: &'static str, body: &str) -> Self {
        Self {
            path,
            status: 200,
            body: body.into(),
            headers: Vec::new(),
            delay: Duration::ZERO,
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
    checker: PanChecker,
    seen: Arc<Mutex<Vec<Seen>>>,
    task: tokio::task::JoinHandle<()>,
}

impl Replay {
    async fn start(replies: Vec<Reply>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let captured = seen.clone();
        let replies = Arc::new(replies);
        let router = Router::new().fallback(move |request: Request<Body>| {
            let captured = captured.clone();
            let replies = replies.clone();
            async move {
                let path = request.uri().path().to_string();
                let target = request.uri().to_string();
                let headers = request.headers().clone();
                let body = to_bytes(request.into_body(), 64 * 1024).await.unwrap();
                let previous = {
                    let mut seen = captured.lock().unwrap();
                    let count = seen
                        .iter()
                        .filter(|request: &&Seen| request.path == path)
                        .count();
                    seen.push(Seen {
                        path: path.clone(),
                        target,
                        headers,
                        body: String::from_utf8(body.to_vec()).unwrap(),
                    });
                    count
                };
                let choices: Vec<_> = replies.iter().filter(|reply| reply.path == path).collect();
                let Some(reply) = choices.get(previous.min(choices.len().saturating_sub(1))) else {
                    return (StatusCode::NOT_FOUND, HeaderMap::new(), String::new());
                };
                let mut headers = HeaderMap::new();
                for (key, value) in &reply.headers {
                    headers.append(*key, value.parse().unwrap());
                }
                tokio::time::sleep(reply.delay).await;
                (
                    StatusCode::from_u16(reply.status).unwrap(),
                    headers,
                    reply.body.clone(),
                )
            }
        });
        let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let checker = PanChecker::with_endpoints(PanEndpoints {
            baidu_page: format!("{base}/s"),
            baidu_verify: format!("{base}/share/verify?fixture=preserved"),
            baidu_list: format!("{base}/share/list"),
            ..PanEndpoints::default()
        });
        Self {
            checker,
            seen,
            task,
        }
    }

    async fn standard(verify: &str, list: &str) -> Self {
        Self::start(vec![
            Reply::ok("/s/1Ab_Cd", PAGE),
            Reply::ok("/share/verify", verify),
            Reply::ok("/share/list", list),
        ])
        .await
    }
    async fn check(&self, pwd: Option<&str>) -> CheckOutcome {
        let (outcome, kind, id) = self.checker.check_one(SHARE, pwd).await;
        assert_eq!(kind, PanKind::Baidu);
        assert_eq!(id, "1Ab_Cd");
        outcome
    }
    fn requests(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
    fn assert_uncertain(&self, outcome: &CheckOutcome) {
        assert_eq!(outcome.state, CheckState::Uncertain);
        assert!(!outcome.cacheable);
        assert!(self.checker.shared.cache.lock().unwrap().is_empty());
    }
}

impl Drop for Replay {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn query(request: &Seen) -> BTreeMap<String, String> {
    reqwest::Url::parse(&format!("http://fixture.invalid{}", request.target))
        .unwrap()
        .query_pairs()
        .into_owned()
        .collect()
}
fn form(request: &Seen) -> BTreeMap<String, String> {
    reqwest::Url::parse(&format!("http://fixture.invalid/?{}", request.body))
        .unwrap()
        .query_pairs()
        .into_owned()
        .collect()
}
fn cookies(request: &Seen) -> BTreeMap<String, String> {
    request
        .headers
        .get("cookie")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .split(';')
        .filter_map(|pair| pair.trim().split_once('='))
        .map(|(key, value)| (key.into(), value.into()))
        .collect()
}

#[tokio::test]
async fn unknown_verify_codes_never_claim_wrong_password_or_dead_share() {
    for errno in [-6, -12, -9876, -62, -64, -65, 8046] {
        let body = json!({"errno":errno,"errmsg":"synthetic opaque refusal"}).to_string();
        let replay = Replay::standard(&body, LIST).await;
        replay.assert_uncertain(&replay.check(Some("code")).await);
        assert_eq!(replay.requests().len(), 2);
    }
}

#[tokio::test]
async fn unknown_list_codes_never_create_dead_link_cache() {
    for errno in [-6, -12, 105, -9876] {
        let body = json!({"errno":errno,"errmsg":"synthetic opaque refusal","list":[]}).to_string();
        let replay = Replay::standard(VERIFY, &body).await;
        replay.assert_uncertain(&replay.check(None).await);
        assert_eq!(replay.requests().len(), 2);
    }
}

#[tokio::test]
async fn malformed_verify_or_missing_randsk_never_advances_to_list() {
    for body in [
        "not-json",
        "{}",
        r#"{"errno":false,"randsk":"fixture"}"#,
        r#"{"errno":0.0,"randsk":"fixture"}"#,
        r#"{"errno":0}"#,
        r#"{"errno":0,"randsk":false}"#,
        r#"{"errno":0,"randsk":"   "}"#,
    ] {
        let replay = Replay::standard(body, LIST).await;
        replay.assert_uncertain(&replay.check(Some("code")).await);
        assert_eq!(replay.requests().len(), 2);
    }
}

#[tokio::test]
async fn successful_names_and_metadata_do_not_enter_error_attribution() {
    for name in [
        "密码.E01.mp4",
        "不存在.E01.mp4",
        "过期.E01.mp4",
        "Limit.E01.mp4",
        "审核.E01.mp4",
    ] {
        let list =
            json!({"errno":0,"HasPwd":false,"expired":false,"message":"验证码错误密码过期Limit",
            "list":[{"fs_id":1,"server_filename":name,"isdir":0}],
            "data":{"error":{"message":"分享已取消"}}})
            .to_string();
        let replay = Replay::standard(VERIFY, &list).await;
        let outcome = replay.check(None).await;
        assert_eq!(outcome.state, CheckState::Ok);
        assert!(outcome.cacheable);
        assert!(replay.checker.shared.cooldown.lock().unwrap().is_empty());
    }
}

#[tokio::test]
async fn nonempty_list_requires_real_file_objects() {
    for list in [
        json!([null]),
        json!([true]),
        json!([{}]),
        json!(["fixture"]),
        json!([{"fs_id":false,"server_filename":"a.mkv"}]),
        json!([{"fs_id":0,"server_filename":"a.mkv"}]),
        json!([{"fs_id":1,"server_filename":""}]),
        json!([{"fs_id":1}]),
    ] {
        let body = json!({"errno":0,"list":list}).to_string();
        let replay = Replay::standard(VERIFY, &body).await;
        replay.assert_uncertain(&replay.check(None).await);
    }
}

#[tokio::test]
async fn absent_bad_json_or_noninteger_list_schema_is_uncertain_not_empty() {
    for body in [
        "not-json",
        "[]",
        "true",
        "{}",
        r#"{"errno":0}"#,
        r#"{"errno":false,"list":[]}"#,
        r#"{"list":[{"fs_id":1,"server_filename":"a.mkv"}]}"#,
    ] {
        let replay = Replay::standard(VERIFY, body).await;
        replay.assert_uncertain(&replay.check(None).await);
    }
}

#[tokio::test]
async fn failed_http_does_not_accept_a_success_looking_payload() {
    for status in [403, 404, 429, 500] {
        for path in ["/s/1Ab_Cd", "/share/verify", "/share/list"] {
            let mut replies = vec![
                Reply::ok("/s/1Ab_Cd", PAGE),
                Reply::ok("/share/verify", VERIFY),
                Reply::ok("/share/list", LIST),
            ];
            let failed = replies.iter_mut().find(|reply| reply.path == path).unwrap();
            failed.status = status;
            let replay = Replay::start(replies).await;
            replay.assert_uncertain(&replay.check(Some("code")).await);
        }
    }
}

#[tokio::test]
async fn known_password_and_dead_rejections_remain_protected() {
    for (verify, list, pwd, state, summary) in [
        (
            VERIFY,
            r#"{"errno":0,"HasPwd":true,"list":[]}"#,
            None,
            CheckState::Locked,
            TEXT_LOCKED,
        ),
        (
            r#"{"errno":-9}"#,
            LIST,
            Some("bad-code"),
            CheckState::Locked,
            TEXT_LOCKED,
        ),
        (
            VERIFY,
            r#"{"errno":777,"errmsg":"分享链接不存在","data":{"title":"密码过期Limit"}}"#,
            None,
            CheckState::Bad,
            TEXT_MISSING,
        ),
        (
            VERIFY,
            r#"{"errno":777,"error":{"message":"分享已取消"}}"#,
            None,
            CheckState::Bad,
            TEXT_DEAD,
        ),
        (
            VERIFY,
            r#"{"errno":777,"error_description":"分享审核未通过"}"#,
            None,
            CheckState::Bad,
            TEXT_AUDIT,
        ),
        (
            VERIFY,
            r#"{"errno":777,"message":"请输入提取码"}"#,
            None,
            CheckState::Locked,
            TEXT_LOCKED,
        ),
    ] {
        let replay = Replay::standard(verify, list).await;
        let outcome = replay.check(pwd).await;
        assert_eq!(outcome.state, state);
        assert_eq!(outcome.summary, summary);
        assert!(outcome.cacheable);
        let count = replay.requests().len();
        assert_eq!(replay.check(pwd).await, outcome);
        assert_eq!(
            replay.requests().len(),
            count,
            "genuine bad/locked caches remain intact"
        );
    }
}

#[tokio::test]
async fn authoritative_auth_captcha_and_unknown_errors_do_not_reflect_body() {
    for body in [
        r#"{"errno":-6,"message":"登录信息已过期"}"#,
        r#"{"errno":-12,"message":"提取码错误"}"#,
        r#"{"errno":777,"errmsg":"验证码错误，请输入提取码"}"#,
        r#"{"errno":777,"message":"SYNTHETIC_SECRET_MUST_NOT_ESCAPE","data":{"title":"过期"}}"#,
    ] {
        let replay = Replay::standard(VERIFY, body).await;
        let outcome = replay.check(None).await;
        replay.assert_uncertain(&outcome);
        assert!(!outcome.summary.contains("SYNTHETIC_SECRET"));
    }
}

#[tokio::test]
async fn known_risk_error_stays_uncertain_and_uncacheable() {
    let body = r#"{"errno":777,"message":"请求过于频繁","data":{"title":"分享已过期"}}"#;
    let replay = Replay::standard(body, LIST).await;
    let outcome = replay.check(Some("code")).await;
    replay.assert_uncertain(&outcome);
    assert_eq!(outcome.summary, TEXT_UNVERIFIABLE);
}

#[tokio::test]
async fn anonymous_check_uses_the_same_official_wire_protocol_and_cookies() {
    let mut page = Reply::ok("/s/1Ab_Cd", PAGE);
    page.headers = vec![
        ("set-cookie", "BAIDUID=abc; Path=/"),
        ("set-cookie", "SHARE_CONTEXT=page; Path=/"),
    ];
    let mut verify = Reply::ok("/share/verify", VERIFY);
    verify.headers = vec![("set-cookie", "VERIFY_CONTEXT=verify; Path=/")];
    let replay = Replay::start(vec![page, verify, Reply::ok("/share/list", LIST)]).await;
    let outcome = replay.check(Some("p +&=/?中")).await;
    assert_eq!(outcome.state, CheckState::Ok);
    let seen = replay.requests();
    let page = seen
        .iter()
        .find(|request| request.path == "/s/1Ab_Cd")
        .unwrap();
    assert!(
        cookies(page).is_empty(),
        "anonymous inspection cannot load account cookies"
    );
    let verify = seen
        .iter()
        .find(|request| request.path == "/share/verify")
        .unwrap();
    let query = query(verify);
    for (key, value) in [
        ("fixture", "preserved"),
        ("surl", "Ab_Cd"),
        ("bioc", "1"),
        ("channel", "chunlei"),
        ("bdstoken", "PAGE_TOKEN"),
        ("logid", "YWJj"),
    ] {
        assert_eq!(query.get(key).map(String::as_str), Some(value));
    }
    assert!(query.get("t").unwrap().parse::<u128>().unwrap() > 0);
    let form = form(verify);
    assert_eq!(
        form.keys().map(String::as_str).collect::<Vec<_>>(),
        ["pwd", "vcode", "vcode_str"]
    );
    assert_eq!(form.get("pwd").map(String::as_str), Some("p +&=/?中"));
    assert_eq!(
        cookies(verify).get("SHARE_CONTEXT").map(String::as_str),
        Some("page")
    );
    let list = seen
        .iter()
        .find(|request| request.path == "/share/list")
        .unwrap();
    let cookie = cookies(list);
    assert_eq!(cookie.get("BDCLND").map(String::as_str), Some("a%2Bb+c"));
    assert_eq!(
        cookie.get("VERIFY_CONTEXT").map(String::as_str),
        Some("verify")
    );
    assert_eq!(
        self::query(list).get("sekey").map(String::as_str),
        Some("a+b+c")
    );
}

#[tokio::test]
async fn transient_unknown_result_is_rechecked_instead_of_cached() {
    let replay = Replay::start(vec![
        Reply::ok("/s/1Ab_Cd", PAGE),
        Reply::ok("/share/list", r#"{"errno":-12}"#),
        Reply::ok("/share/list", LIST),
    ])
    .await;
    replay.assert_uncertain(&replay.check(None).await);
    assert_eq!(replay.check(None).await.state, CheckState::Ok);
    assert_eq!(replay.requests().len(), 4);
}

#[tokio::test]
async fn clearly_successful_empty_list_is_no_file_not_uncertain() {
    let replay = Replay::standard(VERIFY, r#"{"errno":0,"list":[]}"#).await;
    let outcome = replay.check(None).await;
    assert_eq!(outcome.state, CheckState::Bad);
    assert_eq!(outcome.summary, TEXT_NO_FILE);
    assert!(outcome.cacheable);
}

#[tokio::test]
async fn login_only_page_cannot_be_misrepresented_as_successful_anonymous_inspection() {
    let replay = Replay::start(vec![
        Reply::ok(
            "/s/1Ab_Cd",
            "<title>登录百度网盘</title><script>passLoginType='qrcode'</script>",
        ),
        Reply::ok("/share/list", LIST),
    ])
    .await;
    replay.assert_uncertain(&replay.check(None).await);
    assert_eq!(replay.requests().len(), 1);
}

#[tokio::test]
async fn late_anonymous_page_cannot_continue_after_playback_generation_changed() {
    use crate::csp::pan_playback_guard as guard;
    let mut page = Reply::ok("/s/1Ab_Cd", PAGE);
    page.delay = Duration::from_millis(350);
    let replay = Replay::start(vec![page, Reply::ok("/share/list", LIST)]).await;
    let owner = guard::PlaybackOwner {
        consumer: "baidu-anonymous-late-page".into(),
        generation: 1,
    };
    guard::register(Some(owner.clone())).unwrap();
    let request = guard::with_scope(Some(owner.clone()), replay.check(None));
    let invalidate = async {
        tokio::time::timeout(Duration::from_secs(2), async {
            while replay.requests().is_empty() {
                tokio::time::sleep(Duration::from_millis(5)).await;
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
    let (outcome, _) = tokio::join!(request, invalidate);
    replay.assert_uncertain(&outcome);
    assert_eq!(
        replay.requests().len(),
        1,
        "stale page cannot lead to another HTTP hop"
    );
}
