// ═══════════════════════════════════════════════════════════════════════
//  Owner 2026-10-15：「bibili源没有声音,你看看应该是插件的问题」
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一层补上最后一个缺口：**插件 → Rust 的 audio_url 到底有没有传过来**
//
// 已知（其它层已证）：
//   · 插件自己会算 audioUrl（bilibili.js 的 buildCandidates）
//   · Rust `StreamCandidate.audio_url` 会套代理（playback.rs:180-191）
//   · Dart 读 `j['audio_url']`（models.dart:842）
//   · mpv 侧 `audio-add` 能把外挂音轨挂上（zz_t1015b）
//
// 缺的是**中间那一跳**：JS 侧写的 camelCase `audioUrl` 经 bridge
// 转成 snake_case `audio_url` 之后，值还在不在。
// 若这一跳丢了，那么「没声音」的根因就在插件/桥，而不是播放页。
//
// 跑法（真网络，必须 --ignored）：
//   cargo test --manifest-path rust/sourin_core/Cargo.toml \
//     --test zz_t1015_bili_audio_url -- --ignored --nocapture --test-threads=1
//
// ★ 只读用户目录：plugins 从 %APPDATA%\app.sourin.player\plugins 复制到临时目录，
//   绝不写入用户目录。
// ═══════════════════════════════════════════════════════════════════════

use sourin_core::model::{MediaId, PlayRequest};
use sourin_core::state::AppState;
use std::sync::Arc;

fn head(s: &str, n: usize) -> String {
    s.chars().take(n).collect::<String>()
}

async fn with_real_plugins(tag: &str) -> Arc<AppState> {
    let dir = std::env::temp_dir().join(format!(
        "sourin-t1015-{tag}-{}",
        chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let st = AppState::bootstrap(dir).await.expect("bootstrap");
    let appdata = std::env::var("APPDATA").unwrap();
    let src = std::path::PathBuf::from(&appdata)
        .join("app.sourin.player")
        .join("plugins");
    let dst = st.data_dir.join("plugins");
    std::fs::create_dir_all(&dst).unwrap();
    let mut copied = 0;
    for e in std::fs::read_dir(&src).unwrap().flatten() {
        if e.path().extension().and_then(|s| s.to_str()) == Some("js") {
            if std::fs::copy(e.path(), dst.join(e.file_name())).is_ok() {
                copied += 1;
            }
        }
    }
    if copied > 0 {
        let _ = sourin_core::commands_provider::reload_plugins(&st).await;
    }
    println!("[t1015] 隔离目录 {} | 复制插件 {copied} 个", st.data_dir.display());
    st
}

#[tokio::test]
#[ignore = "真网络探针，显式 --ignored 运行"]
async fn bili_audio_url_survives_bridge() {
    let st = with_real_plugins("bili").await;

    // 真 bilibili 条目：用 bvid 直接构造 episode id（插件认这个格式）
    let bvid = std::env::var("BILI_BVID").unwrap_or_else(|_| "BV1GJ411x7h7".to_string());
    let mid = MediaId::new("bilibili", bvid.clone());

    let Some(p) = st.registry.route(&mid) else {
        panic!("[t1015] ★ 源 bilibili 未注册 —— 插件没被加载，本条探针无从断言");
    };

    match p.resolve(&mid, &PlayRequest::default()).await {
        Ok(list) => {
            println!("[t1015] {bvid} → 候选 {} 条", list.len());
            let with_audio = list.iter().filter(|c| c.audio_url.is_some()).count();
            println!("[t1015] ==== 带 audio_url 的候选：{with_audio} / {}", list.len());
            for (i, c) in list.iter().enumerate() {
                println!(
                    "[t1015]   #{i} quality={:?} label={:?} drm={} not_web_ready={}",
                    c.quality, c.label, c.drm_protected, c.not_web_ready
                );
                println!("[t1015]        video_url = {}", head(&c.url, 120));
                match c.audio_url.as_deref() {
                    Some(a) => println!("[t1015]        audio_url = {}", head(a, 120)),
                    None => println!("[t1015]        audio_url = <none> ★"),
                }
            }
            if with_audio == 0 {
                panic!(
                    "[t1015] ★★ 没有任何候选带 audio_url —— 缺口在插件/桥这一侧（{} 条候选全部缺 audio_url）",
                    list.len()
                );
            } else {
                println!("[t1015] ✓ audio_url 确实过了桥（缺口不在这里）");
            }
        }
        Err(e) => panic!("[t1015] ★ resolve 报错: {}", e.message),
    }
}
