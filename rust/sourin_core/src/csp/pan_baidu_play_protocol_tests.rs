use super::{inspect_with, resolve_with, BaiduEndpoints, BaiduInspection};
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

#[tokio::test]
async fn full_resolver_late_sign_cannot_send_download() {
    use super::super::pan_playback_guard as guard;
    let mut sign = Reply::ok(
        "/share/tplconfig",
        r#"{"errno":0,"data":{"sign":"fixture","timestamp":123}}"#,
    );
    sign.delay = std::time::Duration::from_millis(150);
    let replay = Replay::start(vec![
        Reply::ok("/s/5Ab_Cd", SHARE_PAGE),
        Reply::ok(
            "/share/list",
            r#"{"errno":0,"list":[{"fs_id":11,"server_filename":"EP03.mp4","isdir":0,"size":42}]}"#,
        ),
        Reply::ok(
            "/api/loginStatus",
            r#"{"errno":0,"login_info":{"uk":56,"bdstoken":"viewer","vip_identity":0}}"#,
        ),
        sign,
    ])
    .await;
    let owner = guard::PlaybackOwner {
        consumer: "baidu-full-late-sign".into(),
        generation: 1,
    };
    guard::register(Some(owner.clone())).unwrap();
    let spec = super::super::pan_episode_select::EpisodeSpec::default();
    let resolve = guard::with_scope(
        Some(owner.clone()),
        super::resolve_selected_with(
            &replay.endpoints,
            Some("BDUSS=SEED"),
            "5Ab_Cd",
            "",
            Some("11"),
            &spec,
        ),
    );
    let invalidate = async {
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while !replay
                .requests()
                .iter()
                .any(|v| v.path == "/share/tplconfig")
            {
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
    let (result, _) = tokio::join!(resolve, invalidate);
    assert_eq!(result.unwrap_err(), "播放解析请求已过期");
    assert!(!replay
        .requests()
        .iter()
        .any(|v| v.path == "/api/sharedownload"));
}

#[tokio::test]
async fn full_resolver_permission_and_unsafe_urls_are_not_playback() {
    for response in [
        r#"{"errno":118,"errmsg":"BDUSS=SECRET https://private.invalid"}"#,
        r#"{"errno":0,"list":[{"fs_id":11,"dlink":"https://user:password@cdn.example/full.mp4"}]}"#,
        r#"{"errno":0,"list":[{"fs_id":11,"dlink":"https://pan.baidu.com/s/not-media"}]}"#,
        r#"{"errno":0,"list":[{"fs_id":11,"dlink":"file:///private"}]}"#,
    ] {
        let replay = Replay::start(vec![
            Reply::ok("/s/5Ab_Cd", SHARE_PAGE),
            Reply::ok("/share/list", r#"{"errno":0,"list":[{"fs_id":11,"server_filename":"EP03.mp4","isdir":0,"size":42}]}"#),
            Reply::ok("/api/loginStatus", r#"{"errno":0,"login_info":{"uk":"56","bdstoken":"viewer","vip_identity":"0"}}"#),
            Reply::ok("/share/tplconfig", r#"{"errno":0,"data":{"sign":"fixture","timestamp":123}}"#),
            Reply::ok("/api/sharedownload", response),
        ]).await;
        let spec = super::super::pan_episode_select::EpisodeSpec::default();
        let error = super::resolve_selected_with(
            &replay.endpoints,
            Some("BDUSS=SEED"),
            "5Ab_Cd",
            "",
            Some("11"),
            &spec,
        )
        .await
        .expect_err("unsafe or forbidden download fails");
        assert!(
            !error.contains("SECRET") && !error.contains("https://") && !error.contains("password")
        );
        assert!(replay
            .requests()
            .iter()
            .any(|v| v.path == "/api/sharedownload"));
    }
}

#[tokio::test]
async fn full_resolver_deleted_or_ambiguous_file_stops_before_sign() {
    for fid in [None, Some("deleted")] {
        let replay = Replay::start(vec![
            Reply::ok("/s/5Ab_Cd", SHARE_PAGE),
            Reply::ok("/share/list", r#"{"errno":0,"list":[{"fs_id":11,"server_filename":"EP03.mp4","isdir":0,"size":42},{"fs_id":12,"server_filename":"EP03.mkv","isdir":0,"size":42}]}"#),
        ]).await;
        let spec = super::super::pan_episode_select::EpisodeSpec {
            title: "EP03".into(),
            order: Some(3),
        };
        assert!(super::resolve_selected_with(
            &replay.endpoints,
            Some("BDUSS=SEED"),
            "5Ab_Cd",
            "",
            fid,
            &spec
        )
        .await
        .is_err());
        assert_eq!(replay.requests().len(), 2);
    }
}

#[tokio::test]
async fn full_resolver_selects_episode_on_second_root_page() {
    let items: Vec<_> = (1..=20).map(|id| serde_json::json!({"fs_id":id,"server_filename":format!("note{id}.txt"),"isdir":0,"size":1})).collect();
    let first = serde_json::json!({"errno":0,"list":items}).to_string();
    let replay = Replay::start(vec![
        Reply::ok("/s/5Ab_Cd", SHARE_PAGE),
        Reply::ok("/share/list", &first),
        Reply::ok(
            "/share/list",
            r#"{"errno":0,"list":[{"fs_id":21,"server_filename":"EP03.mp4","isdir":0,"size":42}]}"#,
        ),
        Reply::ok(
            "/api/loginStatus",
            r#"{"errno":0,"login_info":{"uk":56,"bdstoken":"viewer","vip_identity":0}}"#,
        ),
        Reply::ok(
            "/share/tplconfig",
            r#"{"errno":0,"data":{"sign":"fixture","timestamp":123}}"#,
        ),
        Reply::ok(
            "/api/sharedownload",
            r#"{"errno":0,"list":[{"fs_id":21,"dlink":"https://cdn.example.test/full.mp4"}]}"#,
        ),
    ])
    .await;
    let spec = super::super::pan_episode_select::EpisodeSpec {
        title: "episode".into(),
        order: Some(3),
    };
    let play = super::resolve_selected_with(
        &replay.endpoints,
        Some("BDUSS=SEED"),
        "5Ab_Cd",
        "",
        None,
        &spec,
    )
    .await
    .expect("second page episode resolves");
    assert!(play.label.unwrap().contains("EP03.mp4"));
    assert!(replay
        .requests()
        .iter()
        .any(|v| v.path == "/share/list" && v.target.contains("page=2")));
}

#[tokio::test]
async fn full_resolver_nested_selected_file_keeps_rotated_session() {
    let mut viewer = Reply::ok(
        "/api/loginStatus",
        r#"{"errno":0,"login_info":{"uk":56,"bdstoken":"viewer","vip_identity":0}}"#,
    );
    viewer.cookie_headers.push("BDUSS=ROTATED; Path=/".into());
    let replay = Replay::start(vec![
        Reply::ok("/s/5Ab_Cd", SHARE_PAGE),
        Reply::ok("/share/list", r#"{"errno":0,"list":[{"fs_id":10,"server_filename":"Season","isdir":1,"path":"/Season"}]}"#),
        Reply::ok("/share/list", r#"{"errno":0,"list":[{"fs_id":11,"server_filename":"EP03.mp4","isdir":0,"size":42},{"fs_id":12,"server_filename":"EP01.mp4","isdir":0,"size":99}]}"#),
        Reply::ok("/share/list", r#"{"errno":0,"list":[{"fs_id":10,"server_filename":"Season","isdir":1,"path":"/Season"}]}"#),
        Reply::ok("/share/list", r#"{"errno":0,"list":[{"fs_id":11,"server_filename":"EP03.mp4","isdir":0,"size":42},{"fs_id":12,"server_filename":"EP01.mp4","isdir":0,"size":99}]}"#),
        viewer,
        Reply::ok("/share/tplconfig", r#"{"errno":0,"data":{"sign":"fixture","timestamp":123}}"#),
        Reply::ok("/api/sharedownload", r#"{"errno":0,"list":[{"fs_id":11,"dlink":"https://cdn.example.test/full.mp4"}]}"#),
    ]).await;
    let files = super::list_share_files_with(&replay.endpoints, "5Ab_Cd", "")
        .await
        .expect("anonymous nested listing");
    let episodes = super::super::pan_episode_select::baidu_episodes("5Ab_Cd", "", "Baidu", files);
    assert_eq!(episodes.len(), 2);
    assert!(replay
        .requests()
        .iter()
        .all(|v| v.path != "/api/loginStatus" && v.headers.get("cookie").is_none()));
    let file = super::super::pan_episode_select::decode_file_id(&episodes[0].id).unwrap();
    assert_eq!(file.kind, "baidu");
    assert_eq!(file.fid, "11");
    let spec = super::super::pan_episode_select::EpisodeSpec {
        title: "EP01".into(),
        order: Some(1),
    };
    let play = super::resolve_selected_with(
        &replay.endpoints,
        Some("BDUSS=SEED"),
        &file.share_id,
        &file.passcode,
        Some(&file.fid),
        &spec,
    )
    .await
    .expect("nested exact selected file resolves");
    assert!(play.label.unwrap().contains("EP03.mp4"));
    let seen = replay.requests();
    let lists: Vec<_> = seen.iter().filter(|v| v.path == "/share/list").collect();
    assert_eq!(lists.len(), 4);
    assert!(lists[1].target.contains("dir=%2FSeason") && lists[1].target.contains("uk=456"));
    let post = seen
        .iter()
        .find(|v| v.path == "/api/sharedownload")
        .unwrap();
    assert!(post.body.contains("fid_list=%5B11%5D"));
    assert!(post
        .headers
        .get("cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .contains("BDUSS=ROTATED"));
}

#[tokio::test]
async fn full_resolver_string_directory_flags_keep_exact_anonymous_selection() {
    let root = r#"{"errno":0,"list":[{"fs_id":"10","server_filename":"Season","isdir":"1","path":"/Season"}]}"#;
    let nested = r#"{"errno":0,"list":[{"fs_id":"11","server_filename":"EP03.mp4","isdir":"0","size":42},{"fs_id":"12","server_filename":"EP01.mp4","isdir":"0","size":99}]}"#;
    let replay = Replay::start(vec![
        Reply::ok("/s/5Ab_Cd", SHARE_PAGE),
        Reply::ok("/share/list", root),
        Reply::ok("/share/list", nested),
        Reply::ok("/share/list", root),
        Reply::ok("/share/list", nested),
        Reply::ok(
            "/api/loginStatus",
            r#"{"errno":0,"login_info":{"uk":56,"bdstoken":"viewer","vip_identity":0}}"#,
        ),
        Reply::ok(
            "/share/tplconfig",
            r#"{"errno":0,"data":{"sign":"fixture","timestamp":123}}"#,
        ),
        Reply::ok(
            "/api/sharedownload",
            r#"{"errno":0,"list":[{"fs_id":11,"dlink":"https://cdn.example.test/full.mp4"}]}"#,
        ),
    ])
    .await;
    let (files, rejected_shape) = super::with_initial_list_rejection_shape(
        super::list_share_files_with(&replay.endpoints, "5Ab_Cd", ""),
    )
    .await;
    let files = files.expect("canonical text directory and file flags list anonymously");
    assert!(rejected_shape.is_none());
    let episodes = super::super::pan_episode_select::baidu_episodes("5Ab_Cd", "", "Baidu", files);
    assert_eq!(episodes.len(), 2);
    let file = episodes
        .iter()
        .map(|episode| super::super::pan_episode_select::decode_file_id(&episode.id).unwrap())
        .find(|file| file.fid == "11")
        .expect("EP03 has an exact selected file identity");
    let anonymous = replay.requests();
    assert_eq!(anonymous.len(), 3);
    assert!(anonymous.iter().all(|request| {
        !request.path.starts_with("/api/") && !request.headers.contains_key("cookie")
    }));
    let spec = super::super::pan_episode_select::EpisodeSpec {
        title: "EP01".into(),
        order: Some(1),
    };
    let play = super::resolve_selected_with(
        &replay.endpoints,
        Some("BDUSS=SEED"),
        &file.share_id,
        &file.passcode,
        Some(&file.fid),
        &spec,
    )
    .await
    .expect("string flags preserve EP03 rather than the EP01 title hint");
    assert!(play.label.unwrap().contains("EP03.mp4"));
    let seen = replay.requests();
    let downloads: Vec<_> = seen
        .iter()
        .filter(|request| request.path == "/api/sharedownload")
        .collect();
    assert_eq!(downloads.len(), 1);
    let form = pairs(&downloads[0].body);
    let selected: Vec<u64> = serde_json::from_str(form.get("fid_list").unwrap()).unwrap();
    assert_eq!(selected, vec![11]);
    let lists: Vec<_> = seen
        .iter()
        .filter(|request| request.path == "/share/list")
        .collect();
    assert_eq!(lists.len(), 4);
    for index in [1, 3] {
        let query = pairs(lists[index].target.split_once('?').unwrap().1);
        assert_eq!(query.get("dir").map(String::as_str), Some("/Season"));
        assert_eq!(query.get("uk").map(String::as_str), Some("456"));
    }
}

#[tokio::test]
async fn full_resolver_mixed_directory_flags_cover_root_and_nested_second_pages() {
    let mut root = vec![serde_json::json!({
        "fs_id": 10, "server_filename": "Season", "isdir": "1", "path": "/Season"
    })];
    root.extend((100..119).map(|id| {
        serde_json::json!({
            "fs_id": id, "server_filename": format!("root{id}.txt"),
            "isdir": if id % 2 == 0 { serde_json::json!(0) } else { serde_json::json!("0") },
            "size": 1
        })
    }));
    let nested: Vec<_> = (200..220)
        .map(|id| {
            serde_json::json!({
                "fs_id": id, "server_filename": format!("nested{id}.txt"),
                "isdir": if id % 2 == 0 { serde_json::json!("0") } else { serde_json::json!(0) },
                "size": 1
            })
        })
        .collect();
    let pages = [
        serde_json::json!({"errno":0,"list":root}).to_string(),
        serde_json::json!({"errno":0,"list":[
            {"fs_id":12,"server_filename":"EP01.mp4","isdir":0,"size":99},
            {"fs_id":13,"server_filename":"root-last.txt","isdir":"0","size":1}
        ]})
        .to_string(),
        serde_json::json!({"errno":0,"list":nested}).to_string(),
        serde_json::json!({"errno":0,"list":[
            {"fs_id":"11","server_filename":"EP03.mp4","isdir":"0","size":42},
            {"fs_id":14,"server_filename":"nested-last.txt","isdir":0,"size":1}
        ]})
        .to_string(),
    ];
    let mut replies = vec![Reply::ok("/s/5Ab_Cd", SHARE_PAGE)];
    for _ in 0..2 {
        replies.extend(pages.iter().map(|page| Reply::ok("/share/list", page)));
    }
    replies.extend([
        Reply::ok(
            "/api/loginStatus",
            r#"{"errno":0,"login_info":{"uk":56,"bdstoken":"viewer","vip_identity":0}}"#,
        ),
        Reply::ok(
            "/share/tplconfig",
            r#"{"errno":0,"data":{"sign":"fixture","timestamp":123}}"#,
        ),
        Reply::ok(
            "/api/sharedownload",
            r#"{"errno":0,"list":[{"fs_id":11,"dlink":"https://cdn.example.test/full.mp4"}]}"#,
        ),
    ]);
    let replay = Replay::start(replies).await;
    let files = super::list_share_files_with(&replay.endpoints, "5Ab_Cd", "")
        .await
        .expect("mixed flags traverse both second pages anonymously");
    let episodes = super::super::pan_episode_select::baidu_episodes("5Ab_Cd", "", "Baidu", files);
    assert_eq!(episodes.len(), 2);
    let file = episodes
        .iter()
        .map(|episode| super::super::pan_episode_select::decode_file_id(&episode.id).unwrap())
        .find(|file| file.fid == "11")
        .unwrap();
    let anonymous = replay.requests();
    assert_eq!(anonymous.len(), 5);
    assert!(anonymous
        .iter()
        .all(|request| !request.headers.contains_key("cookie")));
    let spec = super::super::pan_episode_select::EpisodeSpec {
        title: "EP01".into(),
        order: Some(1),
    };
    let play = super::resolve_selected_with(
        &replay.endpoints,
        Some("BDUSS=SEED"),
        &file.share_id,
        &file.passcode,
        Some(&file.fid),
        &spec,
    )
    .await
    .expect("nested second-page EP03 remains the selected file");
    assert!(play.label.unwrap().contains("EP03.mp4"));
    let seen = replay.requests();
    let lists: Vec<_> = seen
        .iter()
        .filter(|request| request.path == "/share/list")
        .collect();
    assert_eq!(lists.len(), 8);
    for pass in lists.chunks_exact(4) {
        for (request, page, dir) in [
            (pass[0], "1", None),
            (pass[1], "2", None),
            (pass[2], "1", Some("/Season")),
            (pass[3], "2", Some("/Season")),
        ] {
            let query = pairs(request.target.split_once('?').unwrap().1);
            assert_eq!(query.get("page").map(String::as_str), Some(page));
            assert_eq!(query.get("dir").map(String::as_str), dir);
            if dir.is_some() {
                assert_eq!(query.get("uk").map(String::as_str), Some("456"));
                assert!(!query.contains_key("root") && !query.contains_key("shorturl"));
            } else {
                assert_eq!(query.get("root").map(String::as_str), Some("1"));
            }
        }
    }
    let downloads: Vec<_> = seen
        .iter()
        .filter(|request| request.path == "/api/sharedownload")
        .collect();
    assert_eq!(downloads.len(), 1);
    let form = pairs(&downloads[0].body);
    let selected: Vec<u64> = serde_json::from_str(form.get("fid_list").unwrap()).unwrap();
    assert_eq!(selected, vec![11]);
}

#[tokio::test]
async fn full_resolver_invalid_directory_flags_stop_before_account_requests_at_every_page() {
    let invalid_flags = [
        serde_json::json!("01"),
        serde_json::json!("+0"),
        serde_json::json!(" 0"),
        serde_json::json!("0 "),
        serde_json::json!(""),
        serde_json::json!("2"),
        serde_json::json!(2),
        serde_json::json!(null),
        serde_json::json!(0.0),
        serde_json::json!(1.5),
        serde_json::json!(true),
        serde_json::json!([]),
        serde_json::json!({}),
    ];
    for flag in invalid_flags {
        for stage in ["initial", "root-second", "nested-first", "nested-second"] {
            // A permissive parse of "01" cannot fail merely because a directory path is missing.
            let invalid = serde_json::json!({
                "fs_id": 11, "server_filename": "EP03.mp4", "isdir": flag,
                "path": "/Invalid", "size": 42, "debug": ECHO
            });
            let full: Vec<_> = (100..120)
                .map(|id| {
                    serde_json::json!({
                        "fs_id": id, "server_filename": format!("note{id}.txt"),
                        "isdir": 0, "size": 1
                    })
                })
                .collect();
            let full = serde_json::json!({"errno":0,"list":full}).to_string();
            let directory = r#"{"errno":0,"list":[{"fs_id":10,"server_filename":"Season","isdir":"1","path":"/Season"}]}"#;
            let invalid = serde_json::json!({"errno":0,"list":[invalid]}).to_string();
            let pages = match stage {
                "initial" => vec![invalid],
                "root-second" => vec![full, invalid],
                "nested-first" => vec![directory.into(), invalid],
                "nested-second" => vec![directory.into(), full, invalid],
                _ => unreachable!(),
            };
            for authenticated in [false, true] {
                let mut replies = vec![Reply::ok("/s/5Ab_Cd", SHARE_PAGE)];
                replies.extend(pages.iter().map(|page| Reply::ok("/share/list", page)));
                replies.extend([
                    Reply::ok(
                        "/api/loginStatus",
                        r#"{"errno":0,"login_info":{"uk":56,"bdstoken":"viewer","vip_identity":0}}"#,
                    ),
                    Reply::ok(
                        "/share/tplconfig",
                        r#"{"errno":0,"data":{"sign":"fixture","timestamp":123}}"#,
                    ),
                    Reply::ok(
                        "/api/sharedownload",
                        r#"{"errno":0,"list":[{"fs_id":11,"dlink":"https://cdn.example.test/full.mp4"}]}"#,
                    ),
                ]);
                let replay = Replay::start(replies).await;
                let error = if authenticated {
                    super::resolve_selected_with(
                        &replay.endpoints,
                        Some("BDUSS=SEED"),
                        "5Ab_Cd",
                        "",
                        Some("11"),
                        &super::super::pan_episode_select::EpisodeSpec::default(),
                    )
                    .await
                    .expect_err("invalid flag cannot reach authenticated download")
                } else {
                    super::list_share_files_with(&replay.endpoints, "5Ab_Cd", "")
                        .await
                        .expect_err("invalid flag cannot become an anonymous episode")
                };
                assert!(
                    !error.contains(ECHO) && !error.contains("SEED") && !error.contains("https://"),
                    "invalid list errors must not echo response or session values"
                );
                let seen = replay.requests();
                assert_eq!(
                    seen.iter()
                        .filter(|request| request.path == "/share/list")
                        .count(),
                    pages.len(),
                    "invalid flag must stop at its listing page"
                );
                assert!(seen.iter().all(|request| {
                    !request.path.starts_with("/api/") && request.path != "/share/tplconfig"
                }));
                if !authenticated {
                    assert!(seen
                        .iter()
                        .all(|request| !request.headers.contains_key("cookie")));
                }
            }
        }
    }
}

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
                let index = capture
                    .lock()
                    .unwrap()
                    .iter()
                    .filter(|v| v.path == path)
                    .count()
                    .saturating_sub(1);
                let matching: Vec<_> = replies.iter().filter(|reply| path == reply.path).collect();
                let response = matching
                    .get(index.min(matching.len().saturating_sub(1)))
                    .copied();
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
        match inspect_with(&self.endpoints, "BDUSS=SEED; BAIDUID=abc", "5Ab_Cd", pwd).await {
            Ok(BaiduInspection::Files) => "dlink inspection prerequisite satisfied".into(),
            Ok(_) => "inspection did not list files".into(),
            Err(failure) => failure.message,
        }
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
    let list = seen
        .iter()
        .find(|request| request.path == "/share/list")
        .unwrap();
    let list_query = pairs(list.target.split_once('?').unwrap().1);
    assert_eq!(
        list_query.get("shorturl").map(String::as_str),
        Some("Ab_Cd"),
        "official share-list helper removes the leading share marker"
    );
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
    .expect_err("incomplete file metadata must stop download");
    assert!(error.contains("目录标记缺失"));
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

#[derive(Clone, Copy)]
enum TraversalCase {
    Cycle,
    RepeatedPage,
    TooManyDirectories,
    TooManyRequests,
}

async fn traversal_replay(case: TraversalCase) -> Replay {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let capture = seen.clone();
    let router = Router::new().fallback(move |request: Request<Body>| {
        let capture = capture.clone();
        async move {
            let path = request.uri().path().to_string();
            let query = pairs(request.uri().query().unwrap_or(""));
            capture.lock().unwrap().push(Seen {
                path: path.clone(),
                target: request.uri().to_string(),
                headers: request.headers().clone(),
                body: String::new(),
            });
            if path.starts_with("/s/") {
                return (StatusCode::OK, SHARE_PAGE.to_string());
            }
            if path != "/share/list" {
                return (StatusCode::NOT_FOUND, String::new());
            }
            let directory = |index: usize| {
                serde_json::json!({
                    "fs_id": index + 1, "server_filename": format!("d{index}"),
                    "path": format!("/d{index}"), "isdir": 1, "size": 0,
                })
            };
            let file = |index: usize| {
                serde_json::json!({
                    "fs_id": index + 1000, "server_filename": format!("EP{index}.mkv"),
                    "isdir": 0, "size": 42,
                })
            };
            let page = query.get("page").unwrap().parse::<usize>().unwrap();
            let dir = query.get("dir").map(String::as_str);
            let items: Vec<_> = match case {
                TraversalCase::Cycle => vec![directory(0)],
                TraversalCase::RepeatedPage => (0..20).map(file).collect(),
                TraversalCase::TooManyDirectories => {
                    let index = dir
                        .map(|dir| dir[2..].parse::<usize>().unwrap() + 1)
                        .unwrap_or(0);
                    vec![directory(index)]
                }
                TraversalCase::TooManyRequests => match dir {
                    None => (((page - 1) * 20)..(page * 20).min(64))
                        .map(directory)
                        .collect(),
                    Some(dir) if page == 1 => {
                        let index = dir[2..].parse::<usize>().unwrap();
                        (index * 20..index * 20 + 20).map(file).collect()
                    }
                    Some(_) => vec![],
                },
            };
            (
                StatusCode::OK,
                serde_json::json!({"errno":0,"list":items}).to_string(),
            )
        }
    });
    let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    Replay {
        endpoints: BaiduEndpoints {
            page: format!("{base}/s"),
            verify: format!("{base}/share/verify"),
            list: format!("{base}/share/list"),
        },
        seen,
        task,
    }
}

#[tokio::test]
async fn selected_guards_directory_cycles_and_repeated_pages_stop_before_account_requests() {
    for (case, message) in [
        (TraversalCase::Cycle, "目录循环"),
        (TraversalCase::RepeatedPage, "重复文件标识"),
    ] {
        let replay = traversal_replay(case).await;
        let error = super::list_share_files_with(&replay.endpoints, "5Ab_Cd", "")
            .await
            .unwrap_err();
        assert!(error.contains(message));
        let seen = replay.requests();
        assert_eq!(
            seen.iter()
                .filter(|request| request.path == "/share/list")
                .count(),
            2
        );
        assert!(seen
            .iter()
            .all(|request| !request.path.starts_with("/api/")));
        assert!(seen
            .iter()
            .all(|request| !request.headers.contains_key("cookie")));
    }
}

#[tokio::test]
async fn selected_guards_directory_and_request_limits_apply_to_real_traversal() {
    for (case, expected_requests) in [
        (TraversalCase::TooManyDirectories, 65),
        (TraversalCase::TooManyRequests, 129),
    ] {
        let replay = traversal_replay(case).await;
        let error = super::list_share_files_with(&replay.endpoints, "5Ab_Cd", "")
            .await
            .unwrap_err();
        assert!(error.contains("遍历超过限制"));
        let seen = replay.requests();
        assert_eq!(
            seen.iter()
                .filter(|request| request.path == "/share/list")
                .count(),
            expected_requests
        );
        assert!(seen
            .iter()
            .all(|request| !request.path.starts_with("/api/")));
    }
}

#[tokio::test]
async fn selected_guards_export_only_cookies_in_the_media_urls_scope() {
    for (url, same_domain) in [
        ("http://127.0.0.1:7777/full.mp4", true),
        ("https://unrelated.example.test/full.mp4", false),
    ] {
        let mut page = Reply::ok("/s/5Ab_Cd", SHARE_PAGE);
        page.headers = vec![("set-cookie", "PAGE_COOKIE=present; Path=/")];
        let mut download = Reply::ok(
            "/api/sharedownload",
            &serde_json::json!({
                "errno":0,"list":[{"fs_id":3,"dlink":url}],
            })
            .to_string(),
        );
        download.headers = vec![
            ("set-cookie", "BDUSS=LATEST; Path=/"),
            ("set-cookie", "API_ONLY=private; Path=/api"),
            ("set-cookie", "SHARE_ONLY=private; Path=/share"),
        ];
        let replay = Replay::start(vec![
            page,
            Reply::ok("/share/list", r#"{"errno":0,"list":[{"fs_id":3,"server_filename":"EP03.mp4","isdir":0,"size":42}]}"#),
            Reply::ok("/api/loginStatus", r#"{"errno":0,"login_info":{"uk":56,"bdstoken":"fixture","vip_identity":0}}"#),
            Reply::ok("/share/tplconfig", r#"{"errno":0,"data":{"sign":"fixture","timestamp":123}}"#),
            download,
        ]).await;
        let play = super::resolve_selected_with(
            &replay.endpoints,
            Some("BDUSS=SEED"),
            "5Ab_Cd",
            "",
            Some("3"),
            &super::super::pan_episode_select::EpisodeSpec::default(),
        )
        .await
        .unwrap();
        let cookie = play
            .headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("cookie"));
        if same_domain {
            let values: BTreeMap<_, _> = cookie
                .unwrap()
                .1
                .split(';')
                .filter_map(|part| part.trim().split_once('='))
                .collect();
            assert_eq!(values.get("BDUSS"), Some(&"LATEST"));
            assert_eq!(values.get("PAGE_COOKIE"), Some(&"present"));
            assert!(!values.contains_key("API_ONLY") && !values.contains_key("SHARE_ONLY"));
        } else {
            assert!(
                cookie.is_none(),
                "Unrelated media hosts must not receive account cookies"
            );
        }
    }
}
