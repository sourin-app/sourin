// ═══════════════════════════════════════════════════════════════════════
//  真网冒烟：网盘二维码**出码** —— 走生产代码路径（任务 4.1/4.2/4.3 的验收补强）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要这个测试（而不是继续用 curl 手工复刻请求）
//
// `.probe/pan-login-t5-livenet-2026-10-30.log` 里的真网读数是**手工构造请求**得到的，
// 它证明了"服务端接受这些参数"，但**没证明 App 自己走的代码路径能出码**。
// 本测试直接调 `pan_login::command_qr_start`（UI 按"扫码登录"时走的同一个函数），
// 因此它的成功 = "App 里点网盘登录能拿到二维码"。
//
// # 判据
//
// ```text
// ① Ok 且 key 非空          —— 会话确实建立
// ② url 非空且是 http(s)    —— 二维码内容是可扫的链接
// ③ svg 非空                —— UI 能画出码（失败时 UI 退化成显示 URL，不算失败但要如实打印）
// ```
// 三家（阿里/115/百度）**各自独立断言**：任何一家失败都不许把其它家判红，
// 也不许因为"这家今天不通"就整体跳过（那是假绿）。
//
// # 真网测试的跑法
//
// ```powershell
// cd rust\sourin_core
// cargo test --test live_qr_login_smoke --release -- --ignored --nocapture --test-threads=1
// ```
// 必须 `--ignored`（默认门禁不联网）、`--test-threads=1`（避免并发压服务端）。
//
// # 边界（如实记录）
//
// - 出码 ≠ 登录成功。确认态必须真扫码（手机），本测试不覆盖。
// - 三家服务端都可能对这个出口 IP 限流；失败要区分"参数被拒"与"网络/限流"，
//   所以断言消息里带上原始错误的类别。

use sourin_core::pan_login;

/// 从结果里提取"能不能出码"的三条判据，供三家共用。
fn assert_qr_shape(tag: &str, r: &pan_login::QrStartResult) {
    assert!(
        !r.key.trim().is_empty(),
        "[{tag}] 会话 key 为空 —— 说明取码请求没被服务端接受（或解析失败）"
    );
    assert!(
        r.url.starts_with("http://") || r.url.starts_with("https://"),
        "[{tag}] 二维码内容不是 http(s) 链接：{:?}",
        r.url
    );
    // svg 为空是"画图失败"而非"出码失败"，如实打印不判红（UI 会退化成显示 URL）
    if r.svg.trim().is_empty() {
        println!("[{tag}] WARN 二维码 SVG 为空（UI 会退化成显示 URL，不算出码失败）");
    }
    println!(
        "[{tag}] OK key_len={} url_host={} svg_len={} hint={}",
        r.key.len(),
        r.url
            .split("://")
            .nth(1)
            .and_then(|s| s.split('/').next())
            .unwrap_or("<none>"),
        r.svg.len(),
        if r.hint.is_empty() { "<无>" } else { &r.hint }
    );
}

#[tokio::test]
#[ignore = "真网测试：需要网络，默认门禁不跑；用 --ignored 显式执行"]
async fn live_qr_start_aliyun() {
    match pan_login::command_qr_start("aliyun").await {
        Ok(r) => assert_qr_shape("aliyun", &r),
        Err(e) => panic!("[aliyun] 出码失败：{e}"),
    }
}

#[tokio::test]
#[ignore = "真网测试：需要网络，默认门禁不跑；用 --ignored 显式执行"]
async fn live_qr_start_pan115() {
    // kind code 逐字 = "115"（见 pan_login::kind_from_code 的可用值清单：
    // quark / uc / baidu / guangya / xunlei / tianyi / 123 / aliyun / 115）
    match pan_login::command_qr_start("115").await {
        Ok(r) => assert_qr_shape("pan115", &r),
        Err(e) => panic!("[pan115] 出码失败：{e}"),
    }
}

#[tokio::test]
#[ignore = "真网测试：需要网络，默认门禁不跑；用 --ignored 显式执行"]
async fn live_qr_start_baidu() {
    match pan_login::command_qr_start("baidu").await {
        Ok(r) => assert_qr_shape("baidu", &r),
        Err(e) => panic!("[baidu] 出码失败：{e}"),
    }
}
