use super::*;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct Replay {
    drive: PanDrive,
    requests: Arc<Mutex<Vec<Request>>>,
    server: tokio::task::JoinHandle<()>,
    entered: Arc<tokio::sync::Notify>,
    release: Arc<tokio::sync::Notify>,
}

struct Request {
    method: String,
    target: String,
    cookie: String,
    body: serde_json::Value,
}

impl Drop for Replay {
    fn drop(&mut self) {
        self.server.abort();
        PanDrive::debug_set_test_cookie("quark", "");
        PanDrive::debug_set_test_cookie("uc", "");
    }
}

async fn replay(kind: PanKind, download_code: i64, video: serde_json::Value) -> Replay {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let host = listener.local_addr().unwrap().to_string();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let captured = requests.clone();
    let entered = Arc::new(tokio::sync::Notify::new());
    let release = Arc::new(tokio::sync::Notify::new());
    let signal = entered.clone();
    let resume = release.clone();
    let server = tokio::spawn(async move {
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0; 4096];
            let header_end = loop {
                let len = stream.read(&mut buffer).await.unwrap();
                if len == 0 { return; }
                bytes.extend_from_slice(&buffer[..len]);
                if let Some(pos) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                    break pos + 4;
                }
            };
            let headers = String::from_utf8_lossy(&bytes[..header_end]).to_string();
            let content_len = headers.lines().find_map(|line| {
                let (key, value) = line.split_once(':')?;
                key.eq_ignore_ascii_case("content-length").then(|| value.trim().parse::<usize>().unwrap())
            }).unwrap_or(0);
            while bytes.len() < header_end + content_len {
                let len = stream.read(&mut buffer).await.unwrap();
                if len == 0 { return; }
                bytes.extend_from_slice(&buffer[..len]);
            }
            let path = headers.split_whitespace().nth(1).unwrap().to_string();
            let body = serde_json::from_slice::<serde_json::Value>(&bytes[header_end..])
                .unwrap_or(serde_json::Value::Null);
            captured.lock().unwrap().push(Request {
                method: headers.split_whitespace().next().unwrap().to_string(),
                target: path.clone(),
                cookie: headers.lines().find_map(|line| {
                    let (key, value) = line.split_once(':')?;
                    key.eq_ignore_ascii_case("cookie").then(|| value.trim().to_string())
                }).unwrap_or_default(),
                body,
            });
            if path.starts_with("/1/clouddrive/file/v2/play?") && video["_pause"] == true {
                signal.notify_one();
                resume.notified().await;
            }
            let (status, value) = if path.starts_with("/1/clouddrive/file/v2/play?") {
                (video["_http"].as_u64().unwrap_or(200) as u16, video.clone())
            } else if download_code == 0 {
                (200, serde_json::json!({"code":0,"data":[{"download_url":"https://fixture.invalid/original.mp4"}]}))
            } else {
                (400, serde_json::json!({"code":download_code,"message":"download file size limit 23018 fixture-secret"}))
            };
            let body = value.as_str().map(str::to_string).unwrap_or_else(|| value.to_string());
            let rotated = if path.starts_with("/1/clouddrive/file/v2/play?") {
                "video-session"
            } else {
                "download-session"
            };
            let response = format!(
                "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nSet-Cookie: __puus={rotated}; Path=/\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        }
    });
    PanDrive::debug_set_test_api_base(&host, &format!("http://{host}"));
    PanDrive::debug_set_test_cookie(kind.code(), "__pus=test; __kps=test; __puus=old-session");
    let mut spec = if kind == PanKind::Quark { quark_spec() } else { uc_spec() };
    spec.api_host = Box::leak(host.into_boxed_str());
    Replay { drive: PanDrive::with_spec("PanQuark", spec), requests, server, entered, release }
}

fn video() -> serde_json::Value {
    serde_json::json!({
        "code":0,"data":{"default_resolution":"high","video_list":[
            {"resolution":"4k","accessable":false,"trans_status":"success","video_info":{"url":"https://fixture.invalid/locked.mp4"}},
            {"resolution":"super","accessable":true,"trans_status":"transcoding","video_info":{"url":"https://fixture.invalid/pending.mp4"}},
            {"resolution":"low","accessable":true,"trans_status":"success","video_info":{"url":"https://fixture.invalid/low.m3u8"}},
            {"resolution":"high","accessable":true,"trans_status":"success","video_info":{"url":"https://fixture.invalid/high.mp4"}}
        ]}
    })
}

#[tokio::test]
async fn quark_video_fallback_same_fid_default_quality_and_rotated_cookie() {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let fixture = replay(PanKind::Quark, 23018, video()).await;
    let result = fixture.drive.play("", "EXACT-SECOND-COPY", "").await.unwrap();
    assert_eq!(result[0].url, "https://fixture.invalid/high.mp4");
    assert_eq!(result.len(), 2, "Only ready authorized variants may be exposed");
    let cookie = &result[0].headers.iter().find(|(key, _)| key == "Cookie").unwrap().1;
    assert!(cookie.contains("__puus=video-session"));
    assert!(!cookie.contains("__puus=old-session"));
    let requests = fixture.requests.lock().unwrap();
    assert_eq!(requests.len(), 2, "No resave, reselect, or secondary download");
    assert_eq!(requests[0].body["fids"], serde_json::json!(["EXACT-SECOND-COPY"]));
    assert_eq!(requests[1].body, serde_json::json!({
        "fid":"EXACT-SECOND-COPY","resolutions":"normal,low,high,super,2k,4k","supports":"fmp4,m3u8"
    }));
    assert!(requests.iter().all(|request| request.method == "POST"));
    assert!(requests[1].target.starts_with("/1/clouddrive/file/v2/play?"));
    assert!(requests[1].cookie.contains("__puus=download-session"));
    assert!(!requests[1].cookie.contains("__puus=old-session"));
    assert!(result.iter().all(|play| play.headers.iter().any(|(key, value)|
        key == "Cookie" && value.contains("__puus=video-session")
            && !value.contains("__puus=download-session")
            && !value.contains("__puus=old-session"))));
}

#[tokio::test]
async fn quark_video_fallback_rejects_locked_pending_and_invalid_urls_without_echo() {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    for value in [
        serde_json::json!({"code":0,"data":{"video_list":[{"accessable":false,"trans_status":"success","video_info":{"url":"https://fixture.invalid/credential-secret"}}]}}),
        serde_json::json!({"code":0,"data":{"video_list":[{"accessable":true,"trans_status":"transcoding","video_info":{"url":"https://fixture.invalid/credential-secret"}}]}}),
        serde_json::json!({"code":0,"data":{"video_list":[{"accessable":true,"trans_status":"success","video_info":{"url":"file:///credential-secret"}}]}}),
    ] {
        let fixture = replay(PanKind::Quark, 23018, value).await;
        let error = fixture.drive.play("", "EXACT-SECOND-COPY", "").await.unwrap_err();
        assert!(error.contains("视频播放"), "{error}");
        assert!(!error.contains("credential-secret") && !error.contains("fixture-secret"));
        assert_eq!(fixture.requests.lock().unwrap().len(), 2);
    }
}

#[tokio::test]
async fn quark_video_fallback_does_not_hide_business_errors_or_cross_to_uc() {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    for (kind, code) in [(PanKind::Quark, 21001), (PanKind::Quark, 31001), (PanKind::Uc, 23018)] {
        let fixture = replay(kind, code, video()).await;
        assert!(fixture.drive.play("", "EXACT-SECOND-COPY", "").await.is_err());
        assert_eq!(fixture.requests.lock().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn quark_video_fallback_leaves_successful_original_download_unchanged() {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let fixture = replay(PanKind::Quark, 0, video()).await;
    let result = fixture.drive.play("", "EXACT-SECOND-COPY", "").await.unwrap();
    assert_eq!(result[0].url, "https://fixture.invalid/original.mp4");
    assert_eq!(fixture.requests.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn quark_video_fallback_api_errors_are_sanitized_and_login_is_distinct() {
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    for (value, login) in [
        (serde_json::json!({"_http":403,"code":31001,"message":"credential-secret","data":{}}), true),
        (serde_json::json!({"code":41003,"message":"credential-secret","data":{}}), false),
        (serde_json::json!("invalid JSON credential-secret https://fixture.invalid/private"), false),
    ] {
        let fixture = replay(PanKind::Quark, 23018, value).await;
        let error = fixture.drive.play("", "EXACT-SECOND-COPY", "").await.unwrap_err();
        assert_eq!(error.starts_with("NEED_LOGIN:quark|"), login, "{error}");
        assert!(error.contains("视频播放"), "{error}");
        assert!(!error.contains("credential-secret") && !error.contains("https://"));
    }
}

#[tokio::test]
async fn quark_video_fallback_late_response_cannot_enter_a_new_generation() {
    use crate::csp::pan_playback_guard as guard;
    let _serial = FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut value = video();
    value["_pause"] = serde_json::json!(true);
    let fixture = replay(PanKind::Quark, 23018, value).await;
    let owner = guard::PlaybackOwner {
        consumer: format!("video-fallback-{}", std::process::id()),
        generation: 1,
    };
    guard::register(Some(owner.clone())).unwrap();
    let (result, ()) = tokio::join!(
        guard::with_scope(Some(owner.clone()), fixture.drive.play("", "EXACT-SECOND-COPY", "")),
        async {
            tokio::time::timeout(Duration::from_secs(3), fixture.entered.notified()).await.unwrap();
            guard::register(Some(guard::PlaybackOwner {
                consumer: owner.consumer.clone(), generation: 2,
            })).unwrap();
            fixture.release.notify_one();
        },
    );
    assert_eq!(result.unwrap_err(), "播放解析请求已过期");
    assert_eq!(fixture.requests.lock().unwrap().len(), 2, "The stale request cannot restart");
}
