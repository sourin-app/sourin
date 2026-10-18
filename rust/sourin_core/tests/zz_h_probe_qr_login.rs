// ═══════════════════════════════════════════════════════════════════════
//  N12 取证 · 第 4 步：二维码登录链路（**真调用、真网络**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要单独探这条链
// ```text
// 上一步已证明：**账号密码**登录报的是
//     kind=Other  message="<该站>接口返回 code=-101 账号未登录"
//   ⇒ 与「网络异常」无关。
//
// 全仓 grep「网络异常」只有一个**用户可见**产生点：
//     lib/ui/widgets/provider_login_panel.dart:814
//       catch (_) { setState(() => _qrMsg = '网络异常，重试中…'); }
//   ⇒ 它包住的是 `SourinApi.providerQrLoginPoll(...)`
//   ⇒ 所以「网络异常」= **qr_login_poll 这个命令抛了异常**
//
// 本文件就是去问：qr_login_poll 到底在什么情况下抛、抛什么。
// ```
//
// 跑法：`cargo test --test zz_h_probe_qr_login -- --ignored --nocapture`

use std::time::Instant;

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
#[ignore = "真网络取证"]
async fn probe_qr_login() {
    let dir = data_dir();
    println!("══════ N12 第4步：二维码登录链路 ══════");
    let st = sourin_core::state::AppState::bootstrap(dir.clone())
        .await
        .expect("bootstrap");

    // 找一个声明了 qr 登录的源
    let targets: Vec<_> = st
        .registry
        .manifests()
        .iter()
        .filter(|m| m.capabilities.login_qr_supported)
        .map(|m| m.id.clone())
        .collect();
    println!("声明支持二维码登录的源: {targets:?}\n");
    if targets.is_empty() {
        println!("✗ 没有源支持二维码登录 —— 无从取证");
        return;
    }

    let pid = std::env::var("H_PROVIDER").unwrap_or_else(|_| targets[0].clone());
    let p = st.registry.get(&pid).expect("registry.get");

    // ── ① 申请二维码 ──────────────────────────────────────────────
    println!("──── ① qr_login_start ────");
    let t0 = Instant::now();
    let start = match p.qr_login_start().await {
        Ok(s) => {
            println!(
                "  ✓ {}ms key={:?} url_len={} hint={:?}",
                t0.elapsed().as_millis(),
                s.key,
                s.url.len(),
                s.hint
            );
            Some(s)
        }
        Err(e) => {
            println!(
                "  ✗ {}ms kind={:?}\n        message = {:?}",
                t0.elapsed().as_millis(),
                e.kind,
                e.message
            );
            None
        }
    };

    // ── ② 轮询（用**假 key**，模拟"码过期/无效"）──────────────────
    println!("\n──── ② qr_login_poll（假 key，看失败形态）────");
    let t0 = Instant::now();
    match p.qr_login_poll("definitely_invalid_probe_key").await {
        Ok(r) => println!(
            "  ✓ 返回（不是异常）{}ms status={:?} message={:?}",
            t0.elapsed().as_millis(),
            r.status,
            r.message
        ),
        Err(e) => {
            println!(
                "  ✗ **抛异常了** {}ms kind={:?}\n        message = {:?}",
                t0.elapsed().as_millis(),
                e.kind,
                e.message
            );
            println!("        ★★ 这就是 provider_login_panel.dart:814 会显示成「网络异常」的情形");
        }
    }

    // ── ③ 用真 key 轮询一次（未扫码应回 pending，**不该抛**）────────
    if let Some(s) = &start {
        println!("\n──── ③ qr_login_poll（真 key，未扫码）────");
        let t0 = Instant::now();
        match p.qr_login_poll(&s.key).await {
            Ok(r) => println!(
                "  ✓ {}ms status={:?} message={:?}",
                t0.elapsed().as_millis(),
                r.status,
                r.message
            ),
            Err(e) => {
                println!(
                    "  ✗ {}ms kind={:?} message={:?}",
                    t0.elapsed().as_millis(),
                    e.kind,
                    e.message
                );
                println!("        ★★ 连「未扫码」都抛 ⇒ 每次轮询都会显示「网络异常」");
            }
        }
    }

    // ── ④ 连打 3 次，看是否**间歇**抛（风控/超时）──────────────────
    if let Some(s) = &start {
        println!("\n──── ④ 连打 3 次（查间歇性失败）────");
        for i in 1..=3 {
            let t0 = Instant::now();
            match p.qr_login_poll(&s.key).await {
                Ok(r) => println!(
                    "  try{i} ✓ {}ms status={:?}",
                    t0.elapsed().as_millis(),
                    r.status
                ),
                Err(e) => println!(
                    "  try{i} ✗ {}ms kind={:?} msg={:?}",
                    t0.elapsed().as_millis(),
                    e.kind,
                    e.message
                ),
            }
        }
    }

    println!("\n★ 读数结束");
}
