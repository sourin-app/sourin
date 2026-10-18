// ═══════════════════════════════════════════════════════════════════════
//  N12 取证：插件登录到底报什么错（**真调用、真网络**）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// > 我刚刚测试某个视频站的插件无法登陆，提示网络异常 这也是bug
// （站名按仓库硬门禁 t98 的要求中性化：不许出现具体视频网站名）
//
// # 要回答的三层（Lead 要求先查清再改）
// ```text
// ① 「网络异常」这句是谁产生的
//    → 已 grep 全仓：宿主侧只有 provider_login_panel.dart:814 的
//      `'网络异常，重试中…'`（**二维码轮询**路径）。
//      账号密码路径是 `'登录失败：$e'` ⇒ 会把插件抛的原文带出来。
//    → 所以「网络异常」四个字**大概率来自插件自己的 getJson 兜底**。
//
// ② 真请求打到哪个域名、返回什么
//    → 本文件直接调 plugin.login()，把异常原文与网络读数都打出来。
//
// ③ 是本机网络到不了，还是请求构造错了
//    → 对照组：同一 client 打 nav 接口（已实测 200 / code:-101）。
// ```
//
// 跑法：
// ```powershell
// cd rust/sourin_core
// cargo test --test zz_h_probe_plugin_login -- --ignored --nocapture
// ```

use std::time::Instant;

/// 隔离数据目录（与样本采集脚本同一个，绝不碰用户真实目录）
fn data_dir() -> std::path::PathBuf {
    if let Ok(d) = std::env::var("H_DATA_DIR") {
        return std::path::PathBuf::from(d);
    }
    let mut p = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.pop();
    p.pop();
    p.join(".probe").join("round65-c").join("devdata")
}

#[tokio::test]
#[ignore = "真网络取证，需要人工确认"]
async fn probe_plugin_login() {
    let dir = data_dir();
    println!("══════ N12 插件登录取证 ══════");
    println!("数据目录: {}", dir.display());
    assert!(
        dir.join("dsh-media.db").exists(),
        "隔离目录不存在，先跑 tools/seed_dev_data.ps1"
    );

    let st = sourin_core::state::AppState::bootstrap(dir.clone())
        .await
        .expect("bootstrap");
    let manifests = st.registry.manifests();
    println!("已加载源: {} 个", manifests.len());

    // 找声明了 loginSupported 的源
    let mut targets: Vec<_> = manifests
        .iter()
        .filter(|m| m.capabilities.login_supported)
        .map(|m| m.id.clone())
        .collect();
    if targets.is_empty() {
        println!("✗ 没有任何源声明 loginSupported —— 无从取证");
        return;
    }
    if let Ok(only) = std::env::var("H_PROVIDER") {
        targets.retain(|x| x == &only);
    }
    println!("声明支持登录的源: {targets:?}\n");

    for pid in &targets {
        println!("──── 源 {pid} ────");

        // ① 先看 session（未登录应为 None，不该抛）
        match st.registry.get(pid) {
            Some(p) => {
                let t0 = Instant::now();
                match p.session().await {
                    Ok(Some(_)) => println!("  session → 已登录"),
                    Ok(None) => println!("  session → 未登录（正常）"),
                    Err(e) => println!(
                        "  session ✗ {}ms kind={:?} msg={}",
                        t0.elapsed().as_millis(),
                        e.kind,
                        e.message
                    ),
                }
            }
            None => {
                println!("  ✗ registry.get 拿不到这个源");
                continue;
            }
        }

        // ② 真调 login()，用**明显无效**的凭据
        //
        // ⚠️ 只测「错误凭据下报什么」，不尝试真登录 ——
        //    取证不需要真账号，也不该拿用户凭据试。
        let p = st.registry.get(pid).unwrap();
        let cred = sourin_core::provider::Credentials {
            username: String::new(),
            password: "SESSDATA=definitely_invalid_probe_value".to_string(),
            extra: std::collections::HashMap::new(),
        };
        let t0 = Instant::now();
        match p.login(cred).await {
            Ok(_) => println!(
                "  login → 竟然成功了（{}ms）—— 说明校验没做",
                t0.elapsed().as_millis()
            ),
            Err(e) => {
                println!(
                    "  login ✗ {}ms  kind={:?}\n        message = {:?}",
                    t0.elapsed().as_millis(),
                    e.kind,
                    e.message
                );
                // ★ 关键判据：文案里有没有「网络」二字
                if e.message.contains("网络") {
                    println!("        ★★ 这句就是 Owner 看到的「网络异常」的来源");
                }
            }
        }
        println!();
    }

    // ③ 对照组：证明本机到**该站**是通的（同一台机器、同一时刻）
    //
    // ⚠️ 域名从环境变量取，默认用 IANA 保留域名 ——
    //    站名不许写进仓库（硬门禁 t98 扫全仓，注释也算）。
    //    取证时：H_CONTROL_URL="https://<某个站>/x/web-interface/nav"
    println!("──── 对照组：nav 接口（证明网络本身通）────");
    let control = std::env::var("H_CONTROL_URL").unwrap_or_else(|_| {
        "https://example.com/".to_string()
    });
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .no_proxy()
        .build()
        .expect("client");
    let t0 = Instant::now();
    match client
        .get(&control)
        .header("Referer", "https://example.com")
        .header(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
             (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        .send()
        .await
    {
        Ok(r) => {
            let st_code = r.status().as_u16();
            let body = r.text().await.unwrap_or_default();
            let head: String = body.chars().take(200).collect();
            println!(
                "  ✓ status={st_code} {}ms body={head}",
                t0.elapsed().as_millis()
            );
        }
        Err(e) => println!("  ✗ 对照组也失败 ⇒ 本机网络问题: {e}"),
    }

    println!("\n★ 读数结束");
}
