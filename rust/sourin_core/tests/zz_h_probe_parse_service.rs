// ═══════════════════════════════════════════════════════════════════════
//  轨道 H · 取证 A：解析服务可达性（用**产品自己的 HTTP 栈**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不能用 curl 读数就下结论
// ```text
// curl（schannel）与 reqwest（rustls/native-tls）的 TLS 行为**不是一回事**：
// scheduler/证书链/SNI/超时都不同。用 curl 的结果去解释产品行为，
// 就是本仓踩过的「仪器不是被测对象」。
// ⇒ 这里直接用 reqwest（产品 core 的 HTTP 客户端）去打同一个地址。
// ```
//
// # 这条取证要回答什么
// ```text
// 源 154 的三条样本 resolve 全部失败，报「这个源没有可直接播放的地址」。
// tvbox.rs:1439 那条分支的成立条件是：
//   extract_m3u8(播放页) 找不到 && try_parsers(播放页) 也找不到
// 而 PARSE_SERVICES 只有**一个**公网地址（tvbox.rs:121-123）。
// ⇒ 若那个地址不可达，则**所有**「只给播放页」的源都会这样失败。
//   这不是某一条片子的问题，是一个宿主侧的**单点**。
// ```
//
// 跑法：
// ```powershell
// cd rust/sourin_core
// cargo test --test zz_h_probe_parse_service -- --ignored --nocapture
// ```

use std::time::{Duration, Instant};

/// 产品里唯一的解析服务（与 `src/tvbox.rs:PARSE_SERVICES` 逐字一致）
///
/// ⚠️ 这里**复制一份**而不是 import：`PARSE_SERVICES` 是 `pub const`，
///    可以 import。用 import 才能保证"探的就是产品那个值"。
use sourin_core::tvbox::PARSE_SERVICES;

#[tokio::test]
#[ignore = "真网络取证，需要人工确认网络环境"]
async fn probe_parse_service() {
    /*
     * ★★★ 必须**显式关掉**系统代理，否则读数没有意义
     *
     * 实测（这台机器）：
     * ```text
     * env: http_proxy=https_proxy=http://127.0.0.1:7890/
     * 直连   example.com       → 200
     * 直连   player.gimy.bot   → 000（TLS handshake eof）
     * 走 7890 example.com      → 000   ← ★ 代理自己就是坏的
     * 走 7890 player.gimy.bot  → 000
     * ```
     * reqwest **默认读 env 里的代理**。若不关，
     * 「解析服务不可达」这个结论就被一个坏掉的本地代理污染了 ——
     * 那会把「我这台机器的网络环境问题」误报成「产品依赖已死」。
     *
     * ⇒ 这里用 `.no_proxy()` 关掉，让读数只反映**目标站点的真实状态**。
     *   要复现"用户开着代理"的情形，用 `H_USE_PROXY=1` 另测一组。
     */
    let use_proxy = std::env::var("H_USE_PROXY").is_ok();
    let mut builder = reqwest::Client::builder().timeout(Duration::from_secs(20));
    if !use_proxy {
        builder = builder.no_proxy();
    }
    let client = builder.build().expect("client");
    println!(
        "★ 本次读数：{}（H_USE_PROXY={}）",
        if use_proxy { "走系统代理" } else { "直连（已关代理）" },
        use_proxy
    );

    println!("══════ 解析服务可达性（reqwest = 产品同款栈）══════");
    println!("PARSE_SERVICES 共 {} 个条目", PARSE_SERVICES.len());
    for (i, base) in PARSE_SERVICES.iter().enumerate() {
        println!("  [{i}] {base}");
    }
    println!();

    // ① 裸打 host 根（最小请求，只测"能不能连上 + TLS 握手"）
    for base in PARSE_SERVICES {
        let host = base
            .split("://")
            .nth(1)
            .and_then(|s| s.split('/').next())
            .unwrap_or("");
        let root = format!("https://{host}/");
        let t0 = Instant::now();
        match client.get(&root).send().await {
            Ok(r) => {
                println!(
                    "  GET {root}\n    ✓ status={} elapsed={}ms ct={:?}",
                    r.status().as_u16(),
                    t0.elapsed().as_millis(),
                    r.headers()
                        .get(reqwest::header::CONTENT_TYPE)
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or(""),
                );
            }
            Err(e) => {
                println!(
                    "  GET {root}\n    ✗ elapsed={}ms err={e}",
                    t0.elapsed().as_millis()
                );
                // 逐层展开，看是 DNS / TCP / TLS 哪一层
                let mut src: Option<&(dyn std::error::Error + 'static)> =
                    Some(&e as &(dyn std::error::Error + 'static));
                let mut depth = 0;
                while let Some(s) = src {
                    println!("       └─ {}: {s}", depth);
                    src = s.source();
                    depth += 1;
                    if depth > 6 {
                        break;
                    }
                }
            }
        }
    }

    // ② 用**真实播放页**打完整解析 URL（复刻 tvbox 的拼法）
    //
    // ⚠️ 站名不许写进仓库（硬门禁 test/t98 扫全仓，含 rust/）。
    //    这里用一个**中性的**播放页地址：它只用于「把 URL 填进解析服务的
    //    查询参数」这一用途，解析服务自己的响应才是读数来源。
    //    真实取样时用环境变量换掉即可，不必改代码：
    //      H_PAGE_URL="https://<某个站>/x/cover/<id>/<vid>.html"
    let page_owned = std::env::var("H_PAGE_URL").unwrap_or_else(|_| {
        "https://example-video.test/x/cover/demo/demo.html".to_string()
    });
    let page = page_owned.as_str();
    println!("\n══════ 真实播放页走解析（产品拼法）══════");
    println!("  page = {page}");
    for base in PARSE_SERVICES {
        let u = format!("{}{}", base, urlencoding::encode(page));
        let t0 = Instant::now();
        match client.get(&u).send().await {
            Ok(r) => {
                let st = r.status().as_u16();
                let ct = r
                    .headers()
                    .get(reqwest::header::CONTENT_TYPE)
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or("")
                    .to_string();
                let body = r.text().await.unwrap_or_default();
                let head: String = body.chars().take(300).collect();
                println!(
                    "  ✓ status={st} elapsed={}ms ct={ct}\n    body[0..300]={head:?}",
                    t0.elapsed().as_millis()
                );
            }
            Err(e) => {
                println!(
                    "  ✗ elapsed={}ms err={e}",
                    t0.elapsed().as_millis()
                );
            }
        }
    }

    // ③ 对照组：一个能连的 https（证明 client 本身没问题）
    //
    // ⚠️ 同上：不许写站名。用 HTTP 通用测试域名 `example.com`
    //    （IANA 保留域名，不属于任何视频站），它只用来证明
    //    「同一个 client 打别的 https 是通的」。
    println!("\n══════ 对照组（证明 client 正常）══════");
    let t0 = Instant::now();
    match client.get("https://example.com/").send().await {
        Ok(r) => println!(
            "  ✓ 对照 status={} elapsed={}ms",
            r.status().as_u16(),
            t0.elapsed().as_millis()
        ),
        Err(e) => println!("  ✗ 对照组也失败 ⇒ 是网络问题，不是解析服务问题: {e}"),
    }
    println!("\n★ 读数结束");
}
