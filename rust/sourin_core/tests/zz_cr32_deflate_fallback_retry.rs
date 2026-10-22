// ═══════════════════════════════════════════════════════════════════════
//  CodeRabbit PR#32 ②：raw-deflate 回退**不许**在非解码错误时重发
// ═══════════════════════════════════════════════════════════════════════
//
// # 被钉住的缺陷
//
// ```text
// do_http 里 `match r.text().await { Ok(t) => …, Err(e) => 回退 }`
// ⇒ Err(e) 分支**不区分错误类型**。
//
// `r.text()` 失败至少三种原因：
//   ① 解码失败（raw-deflate 被当 zlib 解）   e.is_decode()
//   ② 读 body 时超时                        e.is_timeout()
//   ③ 连接被重置 / body 读一半断开           e.is_body() / is_request() / is_connect()
//
// 只有 ① 该回退。②③ 回退 = **把已经到达服务端的请求再发一次**。
// ```
//
// # 为什么这是用户可见事故（不是洁癖）
//
// ```text
// `host.http.post` 用来发弹幕、做登录类操作。
// 若响应 body 读到一半超时 ⇒ 回退再发一次同样的 POST
// ⇒ **服务端执行两次** ⇒ 用户发一条弹幕，屏幕上出现两条。
//
// GET 更糟：读超时后再等最多 HTTP_TIMEOUT_SECS(15s)
// ⇒ 插件感知的失败延迟最长 30s。
// ```
//
// # 判据为什么是「accept 次数」而不是「返回值」
//
// ```text
// 返回值只能说明"我们这边怎么处理的"；
// 用户在意的是**服务端被执行了几次**。
// accept 次数是这条链路上唯一的**外部**读数 —— 它是被请求方看到的次数。
// ```
//
// # 服务端怎么造出「头已发出、body 读到一半就断」
//
// ```text
// ① 先把响应头写完并 flush（客户端此时已认为响应开始）
// ② 声明 `Content-Length: 1000`（让客户端期待 1000 字节）
// ③ 只写 10 字节就 sleep（超过 HTTP_TIMEOUT_SECS）后关连接
// ⇒ 客户端 r.text() 在等剩余字节时超时 ⇒ Err(is_timeout) 而不是 is_decode
// ```
//
// ★ 修复前：accept = 2（第二次是回退重发）
// ★ 修复后：accept = 1（非解码错误不回退）

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// 服务端行为模式
#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// 头写完 + 只发一小段 body 就挂住 ⇒ 客户端读超时（is_timeout）
    /// ★ 这是本文件的核心场景：**不是**解码错误
    StallBody,
    /// 完整返回一段 raw-deflate 字节 + `Content-Encoding: deflate`
    /// ⇒ 客户端解码失败（is_decode）⇒ **应当**回退
    RawDeflate,
}

/// 起一个服务端，返回 (url, accept 计数)
///
/// ⚠️ **不 join**：服务的次数不确定（修复前会多一次），
///    join 会让测试在"回退没发生时"永远阻塞。
///    线程随进程退出自然回收（与 `tests/t41_probe_net.rs` 同一手法）。
fn spawn_server(mode: Mode) -> (String, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 失败");
    let port = listener.local_addr().unwrap().port();
    let url = format!("http://127.0.0.1:{port}/x");

    let accepts = Arc::new(AtomicUsize::new(0));
    let counter = accepts.clone();

    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            counter.fetch_add(1, Ordering::SeqCst);
            handle(&mut stream, mode);
        }
    });

    (url, accepts)
}

fn handle(stream: &mut TcpStream, mode: Mode) {
    // 读掉请求（不解析内容，只要把请求收完）
    let mut buf = [0u8; 4096];
    let _ = stream.read(&mut buf);

    match mode {
        Mode::StallBody => {
            /*
             * 关键：**头先写完并 flush**，然后只发 10 字节。
             * 客户端会认为"响应已开始、还差 990 字节"，
             * 在等剩余字节时撞上 15s 超时 ⇒ e.is_timeout()。
             *
             * ⚠️ 若一次性把连接关掉而不 sleep，reqwest 会报 is_body()
             *    （连接提前关闭）—— 那也**不是** is_decode，
             *    同样能证明"不该回退"，但不如超时贴近真实事故。
             */
            let head = "HTTP/1.1 200 OK\r\n\
                        Content-Type: text/plain\r\n\
                        Content-Length: 1000\r\n\
                        \r\n";
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.flush();
            let _ = stream.write_all(b"0123456789");
            let _ = stream.flush();
            // 挂住，让客户端读超时（HTTP_TIMEOUT_SECS = 15s，留足余量）
            std::thread::sleep(Duration::from_secs(25));
        }
        Mode::RawDeflate => {
            // 一小段 raw-deflate（无 zlib 头）：
            // 用 flate2 现编一个，保证字节真的解不开 zlib 但 raw 能解
            let payload = raw_deflate(b"hello raw deflate");
            let head = format!(
                "HTTP/1.1 200 OK\r\n\
                 Content-Type: text/plain\r\n\
                 Content-Encoding: deflate\r\n\
                 Content-Length: {}\r\n\
                 \r\n",
                payload.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&payload);
            let _ = stream.flush();
        }
    }
}

/// 生成 raw-deflate（无 zlib 包装）
fn raw_deflate(input: &[u8]) -> Vec<u8> {
    use flate2::write::DeflateEncoder;
    use flate2::Compression;
    use std::io::Write as _;
    let mut e = DeflateEncoder::new(Vec::new(), Compression::default());
    e.write_all(input).expect("deflate 写入失败");
    e.finish().expect("deflate 结束失败")
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn c1_timeout_must_not_retry_post() {
    /*
     * ★★★ 本文件的核心判据。
     *
     * 读超时**不是**解码错误 ⇒ 不许回退 ⇒ 服务端只能看到 **1** 次请求。
     *
     * 修复前这里是 2：第一次超时 ⇒ 回退再发 ⇒ 服务端执行两次
     * ⇒ 用户发一条弹幕，屏幕上出现两条。
     */
    let (url, accepts) = spawn_server(Mode::StallBody);

    let started = std::time::Instant::now();
    let out = sourin_core::plugins::do_http_for_test(
        &None,
        "probe",
        "POST",
        &url,
        &std::collections::HashMap::new(),
        Some(r#"{"text":"一条弹幕"}"#.to_string()),
    )
    .await;
    let elapsed = started.elapsed();

    println!("[C1] 返回: {}", &out.chars().take(120).collect::<String>());
    println!("[C1] accept 次数 = {}", accepts.load(Ordering::SeqCst));
    println!("[C1] 耗时 = {:.1}s", elapsed.as_secs_f64());

    /*
     * ★ 判据：服务端只应被请求一次。
     *
     * 修复前 = 2（回退重发）⇒ 这条会红，并打印出 2。
     * 修复后 = 1。
     */
    assert_eq!(
        accepts.load(Ordering::SeqCst),
        1,
        "★ 读超时不该重发请求 —— 服务端被请求了 {} 次（应为 1）。\
         多出来的那次 = 已经到达服务端的 POST 又执行了一遍\
         ⇒ 用户发一条弹幕会变成两条。",
        accepts.load(Ordering::SeqCst)
    );

    /*
     * ★ 延迟判据：修复前是「15s 超时 + 15s 回退超时 ≈ 30s」。
     * 修复后只等一次超时 ⇒ 应当 < 25s。
     * 这个数字也是用户可感知的（转圈 30 秒 vs 15 秒）。
     */
    assert!(
        elapsed < Duration::from_secs(25),
        "★ 失败延迟过长：{:.1}s（修复前因回退会等两次超时 ≈ 30s）",
        elapsed.as_secs_f64()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn c2_decode_error_still_falls_back() {
    /*
     * ★ 正面对照：**解码错误**仍然必须回退。
     *
     * 这条防的是「修 ② 时把回退整个删掉」——
     * 那会让 2026-10-18 修好的 raw-deflate 站再次失效。
     *
     * 判据：accept = 2（第一次解码失败 + 回退一次），且最终拿到明文。
     */
    let (url, accepts) = spawn_server(Mode::RawDeflate);

    let out = sourin_core::plugins::do_http_for_test(
        &None,
        "probe",
        "GET",
        &url,
        &std::collections::HashMap::new(),
        None,
    )
    .await;

    println!("[C2] 返回: {}", &out.chars().take(200).collect::<String>());
    println!("[C2] accept 次数 = {}", accepts.load(Ordering::SeqCst));

    assert_eq!(
        accepts.load(Ordering::SeqCst),
        2,
        "★ 解码失败**必须**回退（第一次 + 回退一次 = 2）。\
         若这里是 1，说明回退被删掉了 —— raw-deflate 站会重新失效。"
    );
    assert!(
        out.contains("hello raw deflate"),
        "★ 回退必须真的解出正文，实际拿到: {}",
        &out.chars().take(200).collect::<String>()
    );
}
