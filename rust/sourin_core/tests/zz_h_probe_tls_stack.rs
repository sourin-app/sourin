// ═══════════════════════════════════════════════════════════════════════
//  轨道 H · 取证 B：**为什么产品连不上解析服务，而 curl/openssl 连得上**
// ═══════════════════════════════════════════════════════════════════════
//
// # 已确认的事实（真读数）
// ```text
// openssl s_client  → TLSv1.3 / TLS_AES_256_GCM_SHA384 / 证书 GTS WE1 / notAfter 2027-01-10
//                     手工 GET ⇒ HTTP/1.1 200 OK + {"code":200,...,"msg":"解析成功"}
// python ssl        → TLS OK，GET ⇒ HTTP/1.1 200 OK
// curl（schannel）  → status=000 tls=0.000000（握手失败）
// reqwest(rustls)   → "tls handshake eof"
// ```
// ⇒ 站点**活着**，证书**有效**，但两个特定客户端栈握不上手。
//   这必须查清：若是产品的栈有问题，那**所有用户**都会碰到
//   「只给播放页的源全部不可播」——正是 Owner 第 8 条的现场。
//
// # 本文件要区分的三个假设
// ```text
// H1 ALPN：客户端声明 h2，Cloudflare 选了 h2，但我们的 reqwest 没配 h2 支持 ⇒ 握手崩
// H2 TLS 版本/套件：某个 rustls 默认套件被这对端拒绝
// H3 证书链：webpki-roots 里缺 GTS WE1 的根（reqwest 默认不读系统证书）
// ```
//
// 跑法：`cargo test --test zz_h_probe_tls_stack -- --ignored --nocapture`

use std::time::{Duration, Instant};

const HOST: &str = "player.gimy.bot";
const PORT: u16 = 443;

#[tokio::test]
#[ignore = "真网络取证"]
async fn probe_tls_stack() {
    println!("══════ 假设 H1/H2：reqwest 的 ALPN 与版本组合 ══════");

    // ① 默认（reqwest 会按 features 声明 ALPN）
    run("默认", |b| b).await;

    // ② 只 HTTP/1.1（关掉 h2 ⇒ ALPN 只声明 http/1.1）
    run("http1_only", |b| b.http1_only()).await;

    // ③ 强制 HTTP/2 —— ★ 本仓 reqwest **没开 http2 feature**
    //
    // ```text
    // Cargo.toml:75
    //   reqwest = { version = "0.12", features = ["json","rustls-tls","gzip",
    //               "brotli","deflate","socks","stream"], default-features = false }
    // ⇒ 没有 "http2" ⇒ ClientBuilder 上根本**没有** http2_prior_knowledge()
    //   （编译期就报 E0599，这条读数本身就是假设 H1 的证据）
    // ⇒ 也就是说：h2 在这条链路上**不可能**被我们声明。
    // ```
    println!("  [http2_prior_knowledge] ✗ 编译期不存在 —— 本仓 reqwest 未启用 http2 feature");

    // ④ 只在 TLS 层关 h2 但保持请求层
    run("tls 关 h2 (用 min/max tls 确认版本无关)", |b| b).await;

    println!("\n══════ 假设 H3：证书链 ══════");
    println!("  reqwest 的 rustls 默认用 webpki-roots（内置根），**不读**系统证书库。");
    println!("  本机证书链由 Google Trust Services WE1 签发。");
    println!("  ⇒ 若 webpki-roots 缺该根，握手会在**验证阶段**失败。");
}

async fn run(label: &str, tweak: impl FnOnce(reqwest::ClientBuilder) -> reqwest::ClientBuilder) {
    let base = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .no_proxy();
    let client = match tweak(base).build() {
        Ok(c) => c,
        Err(e) => {
            println!("  [{label}] ✗ build 失败: {e}");
            return;
        }
    };
    let t0 = Instant::now();
    match client.get(format!("https://{HOST}:{PORT}/")).send().await {
        Ok(r) => println!(
            "  [{label}] ✓ status={} elapsed={}ms version={:?}",
            r.status().as_u16(),
            t0.elapsed().as_millis(),
            r.version()
        ),
        Err(e) => {
            let mut chain = String::new();
            let mut src: Option<&(dyn std::error::Error + 'static)> =
                Some(&e as &(dyn std::error::Error + 'static));
            while let Some(s) = src {
                chain.push_str(&format!(" <- {s}"));
                src = s.source();
            }
            println!(
                "  [{label}] ✗ elapsed={}ms{chain}",
                t0.elapsed().as_millis()
            );
        }
    }
}
