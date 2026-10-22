// ═══════════════════════════════════════════════════════════════════════
//  CodeRabbit PR#32 ①：raw-deflate 回退**必须**走同一套代理配置
// ═══════════════════════════════════════════════════════════════════════
//
// # 被钉住的缺陷
//
// ```text
// `try_raw_deflate_fallback` 没有用调用方传进来的 client，
// 而是从零 `reqwest::Client::builder()...build()` 新建了一个 raw_client：
//
//   · 丢掉 `ProxyStore::client_for` 配好的**自定义代理 + 认证 + 绕过列表**
//   · 丢掉统一的 `user_agent`
//
// ⇒ 用户给某源配了代理，回退请求走**直连**
//   ⇒ 轻则回退失败（那台站本来就得靠代理才通）
//   ⇒ 重则**暴露用户真实出口 IP**（站点看到的不是代理地址）
// ```
//
// # 判据为什么是「代理看到的请求数 + UA」
//
// ```text
// 本地起一个**最小 HTTP 代理**，它记录：
//   ① 收到的请求行（含绝对 URL ⇒ 证明请求确实经过代理）
//   ② 收到的 User-Agent
//
// 修复前：代理只看到 1 次（第一次正常请求），
//         回退那一次**绕过代理直连**了 ⇒ 代理计数停在 1，
//         而且目标站（这里由代理自己扮演）压根收不到第二次。
// 修复后：代理看到 2 次（第一次 + 回退），两次 UA 一致。
//
// ★ 更强的一条：把目标站设成一个**只有代理能到达**的地址。
//   修复前回退必然失败（直连打不到），修复后能拿到明文。
// ```
//
// # 为什么不用 `HTTPS_PROXY` 环境变量去测
//
// ```text
// 环境变量是**进程级**的，cargo test 默认多线程并行，
// 别的测试会被这个变量污染（我们自己的 do_http 也读它）。
// ⇒ 必须走 `ProxyStore::set(provider, Custom)` 这条**按源配置**的路，
//   这也是真实用户点「设置 → 代理」时走的那条路。
// ```

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use sourin_core::proxy::{ProxyConfig, ProxyMode, ProxyStore};

/// 代理记录到的东西
#[derive(Default, Debug)]
struct Seen {
    /// 每个请求行（形如 `GET http://host:port/x HTTP/1.1`）
    request_lines: Vec<String>,
    /// 每个请求的 User-Agent
    user_agents: Vec<String>,
}

/// 起一个最小 HTTP 正向代理
///
/// 它**自己**扮演目标站：收到 `GET http://…/x` 后直接返回 raw-deflate 正文。
/// 这样「回退有没有经过代理」这件事完全由代理的计数决定。
///
/// 返回 `(proxy_url, seen, accepts)`
fn spawn_proxy() -> (String, Arc<Mutex<Seen>>, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind proxy");
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(Mutex::new(Seen::default()));
    let accepts = Arc::new(AtomicUsize::new(0));

    let seen2 = seen.clone();
    let accepts2 = accepts.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { return };
            accepts2.fetch_add(1, Ordering::SeqCst);
            handle(&mut s, &seen2);
        }
    });

    (format!("http://127.0.0.1:{port}"), seen, accepts)
}

fn handle(s: &mut TcpStream, seen: &Arc<Mutex<Seen>>) {
    // 读到请求头结束（\r\n\r\n）
    let mut buf = Vec::new();
    let mut tmp = [0u8; 1024];
    loop {
        match s.read(&mut tmp) {
            Ok(0) => return,
            Ok(n) => {
                buf.extend_from_slice(&tmp[..n]);
                if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            Err(_) => return,
        }
    }
    let head = String::from_utf8_lossy(&buf).to_string();
    let mut lines = head.lines();
    let request_line = lines.next().unwrap_or_default().to_string();
    let mut ua = String::new();
    for l in lines {
        if let Some(v) = l.strip_prefix("User-Agent: ").or_else(|| l.strip_prefix("user-agent: ")) {
            ua = v.trim().to_string();
        }
    }

    {
        let mut g = seen.lock().unwrap();
        g.request_lines.push(request_line);
        g.user_agents.push(ua);
    }

    /*
     * 返回 raw-deflate 正文 + `Content-Encoding: deflate`
     * ⇒ 正常客户端（自动解压）会解码失败 ⇒ 触发回退
     * ⇒ 回退若走代理，代理会被再请求一次
     */
    use flate2::write::DeflateEncoder;
    use flate2::Compression;
    let mut e = DeflateEncoder::new(Vec::new(), Compression::default());
    e.write_all(b"hello via proxy").unwrap();
    let payload = e.finish().unwrap();

    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\
         Content-Encoding: deflate\r\nContent-Length: {}\r\n\r\n",
        payload.len()
    );
    let _ = s.write_all(head.as_bytes());
    let _ = s.write_all(&payload);
    let _ = s.flush();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a1_fallback_must_go_through_configured_proxy() {
    let (proxy_url, seen, accepts) = spawn_proxy();

    // 按源配置自定义代理 —— 这是 UI 里「设置 → 代理」写进去的那条路径
    let store = ProxyStore::new();
    store
        .set(
            "probe-provider",
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: Some(proxy_url.clone()),
                ..Default::default()
            },
        )
        .expect("set proxy");

    /*
     * ★ 目标地址故意用一个**只有代理能解释**的主机名。
     *
     * 直连时 DNS 必然失败（`.invalid` 是 RFC 2606 保留的永不解析域）
     * ⇒ 修复前回退必然失败 ⇒ 这条测试会红。
     */
    let target = "http://sourin-probe.invalid/x";

    let out = sourin_core::plugins::do_http_for_test(
        &Some(Arc::new(store)),
        "probe-provider",
        "GET",
        target,
        &HashMap::new(),
        None,
    )
    .await;

    let seen_g = seen.lock().unwrap();
    println!("[A1] 代理 accept 次数 = {}", accepts.load(Ordering::SeqCst));
    println!("[A1] 代理收到的请求行 = {:?}", seen_g.request_lines);
    println!("[A1] 代理收到的 UA   = {:?}", seen_g.user_agents);
    println!("[A1] 返回 = {}", &out.chars().take(160).collect::<String>());

    assert_eq!(
        accepts.load(Ordering::SeqCst),
        2,
        "★ 回退请求**必须**经过用户配的代理（第一次 + 回退 = 2 次）。\
         实际 {} 次 ⇒ 回退绕过了代理 ⇒ 用户真实出口 IP 暴露给站点。\
         代理收到的请求行: {:?}",
        accepts.load(Ordering::SeqCst),
        seen_g.request_lines
    );

    assert!(
        out.contains("hello via proxy"),
        "★ 回退必须真的拿到正文（说明回退请求被代理正确转发），实际: {}",
        &out.chars().take(200).collect::<String>()
    );

    /*
     * ★ UA 一致性：两次请求必须带**同一个** UA。
     * 旧代码裸建 builder ⇒ 回退那次连 UA 都没有。
     */
    assert_eq!(
        seen_g.user_agents.len(),
        2,
        "★ 应有两次请求经过代理，实际 {}",
        seen_g.user_agents.len()
    );
    assert!(
        !seen_g.user_agents[1].is_empty(),
        "★ 回退请求丢了 User-Agent（旧代码裸建 builder 就没有 UA）"
    );
    assert_eq!(
        seen_g.user_agents[0], seen_g.user_agents[1],
        "★ 两次请求的 UA 必须一致：正常={:?} 回退={:?}",
        seen_g.user_agents[0], seen_g.user_agents[1]
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a2_no_proxy_path_still_keeps_user_agent() {
    /*
     * ★ 无代理路径也不能裸建：`default_client()` 有统一 UA + timeout，
     * 旧代码的裸 builder 连 UA 都没有。
     *
     * 这里用本地真服务端（不是代理）验证「回退那次也带 UA」。
     */
    use flate2::write::DeflateEncoder;
    use flate2::Compression;

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    let uas: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let uas2 = uas.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { return };
            let mut buf = Vec::new();
            let mut tmp = [0u8; 1024];
            loop {
                match s.read(&mut tmp) {
                    Ok(0) => break,
                    Ok(n) => {
                        buf.extend_from_slice(&tmp[..n]);
                        if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            let head = String::from_utf8_lossy(&buf).to_string();
            for l in head.lines() {
                if let Some(v) = l
                    .strip_prefix("User-Agent: ")
                    .or_else(|| l.strip_prefix("user-agent: "))
                {
                    uas2.lock().unwrap().push(v.trim().to_string());
                }
            }
            let mut e = DeflateEncoder::new(Vec::new(), Compression::default());
            let _ = e.write_all(b"hello direct");
            let payload = e.finish().unwrap();
            let h = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\
                 Content-Encoding: deflate\r\nContent-Length: {}\r\n\r\n",
                payload.len()
            );
            let _ = s.write_all(h.as_bytes());
            let _ = s.write_all(&payload);
            let _ = s.flush();
            std::thread::sleep(Duration::from_millis(20));
        }
    });

    let url = format!("http://127.0.0.1:{port}/x");
    let out = sourin_core::plugins::do_http_for_test(
        &None,
        "probe",
        "GET",
        &url,
        &HashMap::new(),
        None,
    )
    .await;

    let uas_g = uas.lock().unwrap();
    println!("[A2] 服务端收到的 UA = {:?}", *uas_g);
    println!("[A2] 返回 = {}", &out.chars().take(120).collect::<String>());

    assert!(
        out.contains("hello direct"),
        "★ 回退必须成功，实际: {}",
        &out.chars().take(160).collect::<String>()
    );
    assert_eq!(uas_g.len(), 2, "★ 应有两次请求（第一次 + 回退），实际 {}", uas_g.len());
    assert!(
        !uas_g[1].is_empty(),
        "★ 无代理路径的回退请求也必须带 UA（旧代码裸建 builder 没有）"
    );
}
