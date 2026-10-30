// ═══════════════════════════════════════════════════════════════════════
//  取证：现存子源里到底有没有「清单 EXTINF 求和真 < 60s」的样片线路？
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这条（2026-10-30 更正后）
//
// 1.3「疑似样片 (m:ss)」判据的正例（线路时长真的 < 60s）一直拿不到真机样本。
// 曾经的依据「某直播频道源 老舅 CDN 线 dur=10s」已被实测推翻：看门 20:20 读数
// `S0_STATE dur=2724`（45 分钟正片）⇒ 那个 10s 是 P7 修的同一类
// DISCONTINUITY 分片伪影，**不是真短内容**。
//
// 所以要么找到真样片（短剧/预告类），要么如实结论"当前源里没有"。
// 判据必须用**清单事实**（hls_facts 的 EXTINF 求和），不许用 mpv 广播的
// stream.duration（那正是伪影来源）。
//
// # 做法
//
// ```text
// ① 对短剧类子源（csp-shorthaokan / csp-shortweiguan / csp-biliys）直连搜索
// ② 取前若干条，走生产 resolve_stream 拿候选（会带上 playlist_total_ms）
// ③ 报告每条候选的 playlist_total_ms，统计 < 60s 的条数
// ④ 找到 ⇒ 打印 provider/id 供真机复现 1.3 正例；找不到 ⇒ 如实打印"无样本"
// ```
//
// # 跑法
//
// ```powershell
// cd rust\sourin_core
// cargo test --test live_hunt_real_sample --release -- --ignored --nocapture --test-threads=1
// ```

use std::sync::Arc;

use sourin_core::state::AppState;

/// 短剧/短内容倾向的子源（聚合扇出未覆盖它们，但注册表里有）
const SHORT_SOURCES: [&str; 3] = [
    "csp-shorthaokan-aa0e2dbc",
    "csp-shortweiguan-5abb52dd",
    "csp-biliys-a0464f57",
];

const KEYWORDS: [&str; 3] = ["短剧", "逆袭", "总裁"];

/// 1.3 的样片阈值（与 lib/ui/player_page.dart 的 kSampleLineThresholdSeconds 同值）
const SAMPLE_THRESHOLD_S: u64 = 60;

async fn real_state() -> Arc<AppState> {
    let dir = std::env::var("APPDATA")
        .map(|p| std::path::PathBuf::from(p).join("app.sourin.player"))
        .expect("APPDATA");
    AppState::bootstrap(dir).await.expect("bootstrap")
}

#[tokio::test]
#[ignore = "真网取证：需要网络，用 --ignored 显式执行"]
async fn hunt_real_sample_line() {
    let st = real_state().await;
    let mut checked = 0usize;
    let mut samples: Vec<(String, String, String, u64)> = Vec::new();

    for src in SHORT_SOURCES {
        let Some(p) = st.registry.get(src) else {
            println!("SKIP\t{src}\t未注册");
            continue;
        };
        for kw in KEYWORDS {
            let page = match p.search(kw, 1).await {
                Ok(pg) => pg,
                Err(e) => {
                    println!("SEARCH_ERR\t{src}\t{kw}\t{}", e.message.chars().take(80).collect::<String>());
                    continue;
                }
            };
            // 每个源每个词最多看 3 条，控制真网请求量
            for item in page.items.iter().take(3) {
                checked += 1;
                let native = item.id.native.clone();
                match sourin_core::playback::resolve_stream(&st, src, &native, None).await {
                    Ok(list) => {
                        for c in &list {
                            let ms = c.playlist_total_ms;
                            let secs = ms.map(|v| v / 1000);
                            println!(
                                "CAND\t{src}\t{}\tdur_from_playlist={:?}s\tdisc={}",
                                item.title.chars().take(28).collect::<String>(),
                                secs,
                                c.playlist_discontinuous
                            );
                            if let Some(s) = secs {
                                if s > 0 && s < SAMPLE_THRESHOLD_S {
                                    samples.push((
                                        src.to_string(),
                                        native.clone(),
                                        item.title.clone(),
                                        s,
                                    ));
                                }
                            }
                        }
                    }
                    Err(e) => {
                        println!(
                            "RESOLVE_ERR\t{src}\t{}\t{}",
                            item.title.chars().take(20).collect::<String>(),
                            e.chars().take(70).collect::<String>()
                        );
                    }
                }
            }
        }
    }

    println!("\n=== 结论 === 检查条目 {checked} 条，找到真样片（<{SAMPLE_THRESHOLD_S}s）{} 条", samples.len());
    for (src, id, title, s) in &samples {
        println!("REAL_SAMPLE\t{src}\t{id}\t{s}s\t{title}");
    }
    if samples.is_empty() {
        println!(
            "NO_SAMPLE：当前这几个短内容源里没找到「清单 EXTINF 求和 <{SAMPLE_THRESHOLD_S}s」的线路。\
             ⇒ 1.3 的正例证据只能以单元门禁（注入假缓存值）为准，不虚报真机样本。"
        );
    }

    // 不判红：这是取证，不是门禁。真网环境变化不该让门禁红。
    assert!(checked > 0, "一条候选都没检查到 ⇒ 搜索/注册表异常，取证无效");
}
