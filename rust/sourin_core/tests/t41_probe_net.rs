// ═══════════════════════════════════════════════════════════════════════
//  task-41 第 2 步：host.playback.probe —— 本地 TcpListener 真响应头验证
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须起真 server（硬要求）
//
//   纯函数测试证明了「给出 Content-Type ⇒ 结论对」。
//   但它没证明**「真能从 HTTP 响应里读出 Content-Type」**。
//   而后者才是 probe 的实际工作 —— 读头这一步如果错了，
//   纯函数再对也没用（读到的永远是空串 ⇒ 全部退回按 URL 猜）。
//
// # 为什么不 mock
//
//   mock 掉 HTTP 会把「读响应头」这个被测逻辑本身替换掉 ⇒ 假绿。
//   这里起真 TcpListener，喂**真的** HTTP 响应字节，走真的 reqwest。
//
// # 为什么不用外网
//
//   CI 不能依赖外网可用性（会时绿时红）。本地 127.0.0.1 永远可达。
//
// # ⚠️ 一个踩过的坑（第一版测试直接卡死）
//
//   第一版让 server 线程 `for _ in 0..3 { accept() }`，然后主线程 `join()`。
//   但 probe 只发 1 次请求 ⇒ 第 2 次 accept 永远阻塞 ⇒ join 永不返回。
//   ⇒ 现在改成：server 服务指定次数，主线程**不 join**（detach，进程退出自然回收）。

use std::io::{Read, Write};
use std::net::TcpListener;

use sourin_core::model::StreamKind;
use sourin_core::plugins::{probe_url, ProbeVerdict};

/// 起一个只服务 `times` 次请求的极简 HTTP server（**不 join**）
fn serve(content_type: &str, body: &str, times: usize) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 失败");
    let port = listener.local_addr().unwrap().port();
    let url = format!("http://127.0.0.1:{port}/probe");

    let ct = content_type.to_string();
    let bd = body.to_string();

    std::thread::spawn(move || {
        for _ in 0..times {
            let (mut stream, _) = match listener.accept() {
                Ok(v) => v,
                Err(_) => return,
            };
            let mut buf = [0u8; 2048];
            let _ = stream.read(&mut buf);
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{bd}",
                bd.len()
            );
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.flush();
        }
    });

    url
}

/// 起一个会 302 跳到 `/final` 的 server，`/final` 返回指定 Content-Type
fn serve_redirect(final_ct: &str, final_body: &str, times: usize) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 失败");
    let port = listener.local_addr().unwrap().port();
    let url = format!("http://127.0.0.1:{port}/start");

    let ct = final_ct.to_string();
    let bd = final_body.to_string();

    std::thread::spawn(move || {
        for _ in 0..times {
            let (mut stream, _) = match listener.accept() {
                Ok(v) => v,
                Err(_) => return,
            };
            let mut buf = [0u8; 2048];
            let n = stream.read(&mut buf).unwrap_or(0);
            let req = String::from_utf8_lossy(&buf[..n]).to_string();

            let resp = if req.contains("/start") {
                // ★ 302 跳到 /final（相对路径，测 reqwest 是否跟随）
                "HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    .to_string()
            } else {
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{bd}",
                    bd.len()
                )
            };
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.flush();
        }
    });

    url
}

// ═══════════════════════════════════════════════════════════════════
//  ① Content-Type → StreamKind（六种必须覆盖）
// ═══════════════════════════════════════════════════════════════════

#[tokio::test]
async fn probe_apple_mpegurl_is_hls() {
    let url = serve("application/vnd.apple.mpegurl", "#EXTM3U\n", 4);
    let r = probe_url(&None, "test", &url).await;
    match &r.verdict {
        ProbeVerdict::Playable { kind, .. } => assert_eq!(*kind, StreamKind::Hls),
        other => panic!("应是 Hls，实际: {other:?}"),
    }
    assert_eq!(r.status_code, 200);
}

/// ★ 大小写变体：application/x-mpegURL 也必须认
#[tokio::test]
async fn probe_x_mpegurl_case_variant_is_hls() {
    let url = serve("application/x-mpegURL", "#EXTM3U\n", 4);
    let r = probe_url(&None, "test", &url).await;
    assert!(
        matches!(&r.verdict, ProbeVerdict::Playable { kind, .. } if *kind == StreamKind::Hls),
        "x-mpegURL 变体也要认，实际: {:?}",
        r.verdict
    );
}

#[tokio::test]
async fn probe_dash_xml_is_dash_unsupported() {
    let url = serve("application/dash+xml", "<?xml version=\"1.0\"?><MPD></MPD>", 4);
    let r = probe_url(&None, "test", &url).await;
    assert!(
        matches!(r.verdict, ProbeVerdict::DashUnsupported { .. }),
        "DASH 应报 DashUnsupported，实际: {:?}",
        r.verdict
    );
    assert!(!r.verdict.retryable());
}

#[tokio::test]
async fn probe_video_mp4_is_mp4() {
    let url = serve("video/mp4", "fake", 4);
    let r = probe_url(&None, "test", &url).await;
    assert!(matches!(
        r.verdict,
        ProbeVerdict::Playable {
            kind: StreamKind::Mp4,
            ..
        }
    ));
}

#[tokio::test]
async fn probe_audio_mpeg_is_audio_only() {
    let url = serve("audio/mpeg", "fake", 4);
    let r = probe_url(&None, "test", &url).await;
    assert!(matches!(
        r.verdict,
        ProbeVerdict::Playable {
            kind: StreamKind::AudioOnly,
            ..
        }
    ));
}

/// ★★ 关键：text/html 必须判「不是流」，不能退回按 URL 猜
#[tokio::test]
async fn probe_text_html_is_not_a_stream() {
    let url = serve("text/html; charset=utf-8", "<html>login page</html>", 4);
    let r = probe_url(&None, "test", &url).await;
    assert!(
        matches!(r.verdict, ProbeVerdict::NotAStream { .. }),
        "text/html 应报 NotAStream（不是 Playable/Unreachable），实际: {:?}",
        r.verdict
    );
    assert!(!r.verdict.retryable(), "内容不对，重试无用");
}

// ═══════════════════════════════════════════════════════════════════
//  ② 302 跳转链路（Content-Type 在最终响应上）
// ═══════════════════════════════════════════════════════════════════

#[tokio::test]
async fn probe_follows_redirect_and_uses_final_content_type() {
    let url = serve_redirect("application/vnd.apple.mpegurl", "#EXTM3U\n", 6);
    let r = probe_url(&None, "test", &url).await;

    assert!(r.redirected, "应记录发生过跳转，实际 finalUrl={}", r.final_url);
    assert!(
        r.final_url.contains("/final"),
        "finalUrl 应是跳转后的地址，实际: {}",
        r.final_url
    );
    assert!(
        matches!(&r.verdict, ProbeVerdict::Playable { kind, .. } if *kind == StreamKind::Hls),
        "应使用最终响应的 Content-Type 判为 Hls，实际: {:?}",
        r.verdict
    );
}

// ═══════════════════════════════════════════════════════════════════
//  ③ DRM 嗅探（真响应体）
// ═══════════════════════════════════════════════════════════════════

#[tokio::test]
async fn probe_sample_aes_is_drm() {
    let m = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://k\"\n";
    let url = serve("application/vnd.apple.mpegurl", m, 4);
    let r = probe_url(&None, "test", &url).await;
    match r.verdict {
        ProbeVerdict::DrmProtected { reason } => {
            assert!(reason.contains("SAMPLE-AES"), "实际: {reason}");
        }
        other => panic!("SAMPLE-AES 应报 DrmProtected，实际: {other:?}"),
    }
}

/// ★★ 反例：AES-128 是普通加密，libmpv 能解 ⇒ 不能判 DRM
#[tokio::test]
async fn probe_aes128_is_playable() {
    let m = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n";
    let url = serve("application/vnd.apple.mpegurl", m, 4);
    let r = probe_url(&None, "test", &url).await;
    assert!(
        matches!(r.verdict, ProbeVerdict::Playable { .. }),
        "AES-128 能解，不该判 DRM，实际: {:?}",
        r.verdict
    );
}

// ═══════════════════════════════════════════════════════════════════
//  ④ 不可达
// ═══════════════════════════════════════════════════════════════════

#[tokio::test]
async fn probe_unreachable_is_retryable() {
    // .invalid 是 RFC 2606 保留 TLD，保证解析失败
    let r = probe_url(&None, "test", "http://bad.invalid/x.m3u8").await;
    assert!(
        matches!(r.verdict, ProbeVerdict::Unreachable { .. }),
        "实际: {:?}",
        r.verdict
    );
    assert!(r.verdict.retryable(), "网络失败应可重试");

    // ⚠️ 不要写死 status_code == 0。
    //
    // 这台机器上装了系统代理（127.0.0.1:7890），reqwest 会走它，
    // 于是 DNS 失败变成代理返回的 502 —— 两种情况都是「不可达」，
    // 但状态码不同。断言 0 会让**有代理的机器**上假红。
    //
    // ⇒ 只断言「状态码不是 2xx」（即确实没拿到内容），
    //   这是两种路径的共同本质。
    assert!(
        !(200..300).contains(&r.status_code),
        "不可达时不该拿到 2xx，实际: {}",
        r.status_code
    );
}
