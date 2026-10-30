//! task-8 门禁：resolve 链路把 HLS 清单真实整集时长带进 StreamCandidate
//!
//! ```text
//! 背景（真机取证定论，勿再猜）：dur=6 的「第33集」清单实为 17 段 EXTINF 求和 82.72s
//!       + 2 个 DISCONTINUITY；mpv 在不连续点重建时间轴 ⇒ stream.duration 报"当前分片"。
//! 判据核心：hls_facts::fields_from_facts（纯决策，硬约束①⑤钉死）+ probe_playlist
//!       （1500ms 预算 / master 追子清单 / 失败留 None）+ playback 接线（只对 hls 读）。
//! 注入证红：把「无 ENDLIST 则 None」短路（让直播也填）⇒ 直播用例必红（记录见笔记）。
//! ```
//!
//! 详见 .agents/notes/implemented/feature/2026-10-30-hls-playlist-total-ms.md

use sourin_core::hls_facts::{fields_from_facts, parse_playlist_facts, probe_playlist};

/// 真机取证的那段清单（与 hls_facts.rs 内测同一现场样本：TARGETDURATION:6 +
/// 6/4 交替 17 段 + 2 个 DISCONTINUITY + ENDLIST）
const REAL_CASE: &str = "#EXTM3U\n\
#EXT-X-TARGETDURATION:6\n\
#EXT-X-MEDIA-SEQUENCE:0\n\
#EXTINF:6.000000,\nseg0.ts\n\
#EXTINF:4.000000,\nseg1.ts\n\
#EXTINF:6.000000,\nseg2.ts\n\
#EXTINF:4.000000,\nseg3.ts\n\
#EXTINF:6.000000,\nseg4.ts\n\
#EXTINF:4.000000,\nseg5.ts\n\
#EXTINF:6.000000,\nseg6.ts\n\
#EXTINF:4.000000,\nseg7.ts\n\
#EXTINF:6.000000,\nseg8.ts\n\
#EXTINF:4.000000,\nseg9.ts\n\
#EXTINF:6.000000,\nseg10.ts\n\
#EXTINF:4.000000,\nseg11.ts\n\
#EXTINF:6.000000,\nseg12.ts\n\
#EXTINF:4.000000,\nseg13.ts\n\
#EXTINF:6.000000,\nseg14.ts\n\
#EXTINF:3.720000,\nseg15.ts\n\
#EXT-X-DISCONTINUITY\n\
#EXTINF:3.000000,\nseg16.ts\n\
#EXT-X-DISCONTINUITY\n\
#EXT-X-ENDLIST\n";

/// 真实清单：total=82720 且 ≠ TARGETDURATION*1000（「6 秒」假象的根因）
#[test]
fn real_playlist_yields_82720_not_targetduration() {
    let f = parse_playlist_facts(REAL_CASE);
    assert_eq!(f.total_ms, 82_720, "EXTINF 求和 = 82.72s");
    assert_ne!(
        f.total_ms,
        f.target_duration_secs.unwrap() * 1000,
        "★ 绝不把 TARGETDURATION(6) 当整集时长 —— 这就是「6 秒」假象"
    );
    let probe = fields_from_facts(&f);
    assert_eq!(probe.total_ms, Some(82_720), "点播完结 ⇒ 必须填总时长");
    assert!(probe.discontinuous, "2 个 DISCONTINUITY ⇒ 事实标记为真");
}

/// 硬约束①：**同一份清单去掉 ENDLIST（直播中）⇒ total 必须 None**
#[test]
fn live_playlist_without_endlist_must_be_none() {
    let live = REAL_CASE.replace("#EXT-X-ENDLIST\n", "");
    let f = parse_playlist_facts(&live);
    assert!(!f.has_endlist);
    assert_eq!(f.total_ms, 82_720, "EXTINF 求和照样算得出来（但语义不同）");
    let probe = fields_from_facts(&f);
    assert_eq!(
        probe.total_ms, None,
        "★ 直播没有总时长 —— 填了就是错的（硬约束①）"
    );
    assert!(
        probe.discontinuous,
        "约束⑤：discontinuous 是事实标记，与 ENDLIST 无关"
    );
}

/// 硬约束③：解析不出分片的完结清单 ⇒ total 留 None（0 毫秒同样是错误读数）
#[test]
fn endlist_without_segments_yields_none() {
    let f = parse_playlist_facts("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-ENDLIST\n");
    assert!(f.has_endlist);
    let probe = fields_from_facts(&f);
    assert_eq!(probe.total_ms, None);
}

// ═══════════════════════════════════════════════════════════════════════
//  probe_playlist 全链路（本地 axum，离线；master 追子清单 / 超时留 None）
// ═══════════════════════════════════════════════════════════════════════

use std::sync::Arc;

use axum::extract::State;
use axum::routing::get;
use axum::Router;

#[derive(Clone)]
struct ProbeUp {
    media: Arc<String>,
    master: Arc<String>,
    slow: Arc<bool>,
}

async fn serve_media(State(up): State<ProbeUp>) -> String {
    if *up.slow {
        tokio::time::sleep(std::time::Duration::from_millis(2500)).await;
    }
    (*up.media).clone()
}

async fn serve_master(State(up): State<ProbeUp>) -> String {
    (*up.master).clone()
}

async fn start_up(media: &str, master: Option<String>, slow: bool) -> String {
    let has_master = master.is_some();
    let up = ProbeUp {
        media: Arc::new(media.to_string()),
        master: Arc::new(master.unwrap_or_default()),
        slow: Arc::new(slow),
    };
    let mut app = Router::new().route("/media.m3u8", get(serve_media).with_state(up.clone()));
    if has_master {
        // master 用例2的形态：子清单 URI 是相对路径 720/hls/index.m3u8
        app = app
            .route("/master.m3u8", get(serve_master).with_state(up.clone()))
            .route("/720/hls/index.m3u8", get(serve_media).with_state(up));
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

#[tokio::test]
async fn probe_media_playlist_returns_total_82720() {
    let base = start_up(REAL_CASE, None, false).await;
    let probe = probe_playlist(&format!("{base}/media.m3u8"), &[]).await;
    assert_eq!(probe.total_ms, Some(82_720));
    assert!(probe.discontinuous);
}

/// 硬约束②：master 清单追一层子清单再取事实（实测案例2：master→720/hls/index.m3u8）
#[tokio::test]
async fn probe_master_follows_variant_child() {
    let master =
        "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128\n720/hls/index.m3u8\n".to_string();
    let base = start_up(REAL_CASE, Some(master), false).await;
    let probe = probe_playlist(&format!("{base}/master.m3u8"), &[]).await;
    assert_eq!(
        probe.total_ms,
        Some(82_720),
        "事实必须来自子清单（master 本身 EXTINF 求和恒为 0）"
    );
    assert!(probe.discontinuous);
}

/// 硬约束③：清单端 2.5s 不响应 ⇒ 1500ms 预算耗尽 ⇒ None/false，绝不 Err
#[tokio::test]
async fn probe_timeout_leaves_fields_none() {
    let base = start_up(REAL_CASE, None, true).await;
    let sw = std::time::Instant::now();
    let probe = probe_playlist(&format!("{base}/media.m3u8"), &[]).await;
    let elapsed = sw.elapsed();
    assert_eq!(probe.total_ms, None, "超时 ⇒ 留 None");
    assert!(!probe.discontinuous, "超时 ⇒ 无事实");
    assert!(
        elapsed < std::time::Duration::from_millis(2200),
        "探测预算 1500ms，不许拖到上游的 2.5s：{elapsed:?}"
    );
}

// ═══════════════════════════════════════════════════════════════════════
//  守卫补漏（2026-10-30 真机实测）：kind 错标 Mp4 的 m3u8 也必须读
// ═══════════════════════════════════════════════════════════════════════

use sourin_core::hls_facts::{looks_like_hls_url, probe_candidate, should_probe_candidate};
use sourin_core::model::{StreamCandidate, StreamKind};

#[test]
fn looks_like_hls_url_matches_path_fact_only() {
    // 大小写与 query 形态都要认（.m3u8?token=… 是现场常见形态）
    assert!(looks_like_hls_url("https://usaydd.example/720/master.m3u8"));
    assert!(looks_like_hls_url("https://usaydd.example/720/MASTER.M3U8"));
    assert!(looks_like_hls_url("https://usaydd.example/720/master.m3u8?sign=abc&exp=1"));
    assert!(looks_like_hls_url("https://usaydd.example/720/master.m3u8#frag"));
    // mp4 直链与无后缀不是清单
    assert!(!looks_like_hls_url("https://cdn.example/v.mp4"));
    assert!(!looks_like_hls_url("https://cdn.example/v"));
    assert!(!looks_like_hls_url("https://cdn.example/v.mp4?x=.m3u8"), "query 不算 path");
}

#[test]
fn should_probe_or_combines_kind_and_url_fact() {
    // kind 自述是 Hls ⇒ 无论 URL 形态都读
    assert!(should_probe_candidate(&StreamKind::Hls, "https://cdn.example/v"));
    // ★ 真机教训：标 Mp4 实为 m3u8 ⇒ URL 事实兜底必须读
    assert!(should_probe_candidate(&StreamKind::Mp4, "https://usaydd.example/720/master.m3u8"));
    assert!(should_probe_candidate(&StreamKind::Mp4, "https://usaydd.example/v.m3u8?sign=1"));
    // 标 Mp4 且确实是 mp4/无后缀 ⇒ 不读（不给起播加延迟）
    assert!(!should_probe_candidate(&StreamKind::Mp4, "https://cdn.example/v.mp4"));
    assert!(!should_probe_candidate(&StreamKind::Mp4, "https://cdn.example/v"));
}

/// ★ 守卫补漏的全链门禁：kind=Mp4 但 url 是 master.m3u8 ⇒ 照样读出 82.72s
///
/// （appyqk「老舅除三害」现场的镜像：旧守卫按 kind==Hls 判正好跳过。
///  注入删掉 URL 兜底那半 ⇒ 本条必红。）
#[tokio::test]
async fn probe_candidate_fills_mislabeled_mp4_hls() {
    let master =
        "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128\n720/hls/index.m3u8\n".to_string();
    let base = start_up(REAL_CASE, Some(master), false).await;
    let mut c = StreamCandidate::new(format!("{base}/master.m3u8?sign=abc"), StreamKind::Mp4);
    probe_candidate(&mut c).await;
    assert_eq!(
        c.playlist_total_ms,
        Some(82_720),
        "kind 错标 Mp4 不许挡住清单事实（82.72s，不是 6）"
    );
    assert!(c.playlist_discontinuous);
}

/// 硬约束④（守卫）：只对「kind==Hls 或 URL path 明显是 .m3u8」的候选探测
///
/// 源码级断言（include_str! 先例 tvbox_aggregate.rs:2720）：playback 必须调
/// probe_candidate（守卫收在 hls_facts::should_probe_candidate 一处）。
#[test]
fn playback_probes_via_candidate_entry() {
    let src = include_str!("../src/playback.rs").replace("\r\n", "\n");
    // ★ P9 后的接线契约：必须走**批处理入口**一次探完，不许退回按候选串行 await。
    assert!(
        src.contains("crate::hls_facts::probe_candidates(&mut list).await;"),
        "playback.rs 必须经 probe_candidates 批处理探测（串行 = 起播延迟随线路数线性增长）"
    );
    assert!(
        !src.contains("crate::hls_facts::probe_candidate(c).await;"),
        "★P9：不许在候选循环里逐个 await 探测（实测 8 条 = 9615ms、32 条 = 38457ms）"
    );
    // 批探测必须在 maybe_proxy 之前 —— 代理后的本地地址读不到上游清单
    let i_batch = src
        .find("crate::hls_facts::probe_candidates(&mut list).await;")
        .expect("批探测调用点缺失");
    let i_proxy = src
        .find("crate::streamproxy::maybe_proxy(")
        .expect("maybe_proxy 调用点缺失");
    assert!(
        i_batch < i_proxy,
        "批探测必须在 maybe_proxy 之前（用原始上游 URL + 候选自带头）：batch={i_batch} proxy={i_proxy}"
    );
    let facts = include_str!("../src/hls_facts.rs").replace("\r\n", "\n");
    let seg = facts
        .split("pub fn should_probe_candidate(")
        .nth(1)
        .expect("hls_facts 必须有 should_probe_candidate");
    let body = seg.split('}').next().unwrap_or("");
    assert!(
        body.contains("looks_like_hls_url(url)"),
        "守卫必须含 URL 事实兜底（appyqk 错标 Mp4 的教训，注入删掉它 ⇒ Mp4 m3u8 用例红）"
    );
}

// ═══════════════════════════════════════════════════════════════════════
//  P9：批探测的**起播延迟**必须量化，不能靠读代码断言"应该没问题"
// ═══════════════════════════════════════════════════════════════════════
//
// task-8 为了修时长读数，在 resolve 出口给每个 HLS 候选读一次清单
// （单候选预算 1500ms）。若按候选**串行** await ⇒ 多线路内容（真机实测：
// 思君如故 8 线路、聚合条目十几条候选）最坏 N×预算全部堆在**首帧之前**
// ⇒ 与 Owner 在 1.3 定的「不增加起播延迟」冲突。
//
// 这两条门禁的作用：
//   ① 把"修前最坏多少 ms"用实测数字钉在案发现场（串行实现必红）；
//   ② 钉住修后的两个要求：总延迟与候选数无关（有硬上限）、
//      以及**不许为了快把没探到的候选编出假事实**（只能 None）。

use sourin_core::hls_facts::probe_candidates;

#[derive(Clone)]
struct BatchUp {
    media: Arc<String>,
    delay_ms: Arc<u64>,
}

async fn serve_batch(State(up): State<BatchUp>) -> String {
    if *up.delay_ms > 0 {
        tokio::time::sleep(std::time::Duration::from_millis(*up.delay_ms)).await;
    }
    (*up.media).clone()
}

/// 起 N 个慢清单端点（/s0.m3u8 … /s{N-1}.m3u8），每个都延迟 delay_ms
async fn start_batch_up(media: &str, n: usize, delay_ms: u64) -> String {
    let up = BatchUp {
        media: Arc::new(media.to_string()),
        delay_ms: Arc::new(delay_ms),
    };
    let mut app = Router::new();
    for i in 0..n {
        app = app.route(
            &format!("/s{i}.m3u8"),
            axum::routing::get(serve_batch).with_state(up.clone()),
        );
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

/// ★ P9 主判据：8 条候选、每条清单慢 1200ms ⇒ 批探测总耗时必须有硬上限
///
/// 串行实现的实测最坏 = 8×1200 ≈ 9600ms ⇒ **本条必红**（红即立案成立）。
/// 并发化后应 ≈ 单个 1200ms，且 8 条候选都要拿到真实事实（不许为快漏探）。
#[tokio::test]
async fn p9_batch_probe_wallclock_has_hard_cap() {
    const N: usize = 8;
    const SLOW_MS: u64 = 1200;
    let base = start_batch_up(REAL_CASE, N, SLOW_MS).await;
    let mut list: Vec<StreamCandidate> = (0..N)
        .map(|i| {
            StreamCandidate::new(format!("{base}/s{i}.m3u8"), StreamKind::Hls)
        })
        .collect();

    let sw = std::time::Instant::now();
    probe_candidates(&mut list).await;
    let elapsed_ms = sw.elapsed().as_millis() as u64;

    // 事实完整性：每条都必须拿到 82.72s（"只探第一条"的偷懒修法在这里红）
    for (i, c) in list.iter().enumerate() {
        assert_eq!(
            c.playlist_total_ms,
            Some(82_720),
            "候选 {i} 没拿到清单事实 —— 不许为了少花时间跳过候选（那是把缺陷藏起来）"
        );
    }

    assert!(
        elapsed_ms <= 2_500,
        "★P9：{N} 条候选 × {SLOW_MS}ms 的批探测墙钟 = {elapsed_ms}ms，超硬上限 2500ms。\
         串行实现 ≈ N×单候选耗时（{expected}ms）⇒ 起播延迟随线路数线性增长，\
         违反 Owner 在 1.3 定的「不增加起播延迟」。修法=并发化（限流）+ 批级截止。",
        expected = N as u64 * SLOW_MS
    );
}

/// ★ P9 第二条：候选数更多时延迟仍必须有上限，且**不许编假事实**
///
/// 32 条候选、每条 1200ms：并发+限流+批截止 ⇒ 墙钟仍须有界；
/// 来不及探的候选只能是 None（"没读到"），绝不能是某个编造的数字。
#[tokio::test]
async fn p9_batch_probe_scales_without_fabricating() {
    const N: usize = 32;
    const SLOW_MS: u64 = 1200;
    let base = start_batch_up(REAL_CASE, N, SLOW_MS).await;
    let mut list: Vec<StreamCandidate> = (0..N)
        .map(|i| {
            StreamCandidate::new(format!("{base}/s{i}.m3u8"), StreamKind::Hls)
        })
        .collect();

    let sw = std::time::Instant::now();
    probe_candidates(&mut list).await;
    let elapsed_ms = sw.elapsed().as_millis() as u64;

    let got: usize = list.iter().filter(|c| c.playlist_total_ms.is_some()).count();
    for (i, c) in list.iter().enumerate() {
        match c.playlist_total_ms {
            None => {}
            Some(v) => assert_eq!(v, 82_720, "候选 {i} 的读数必须是清单真值，不许编"),
        }
    }
    assert!(
        elapsed_ms <= 4_500,
        "★P9：{N} 条候选墙钟 {elapsed_ms}ms 仍随候选数线性增长（32×{SLOW_MS}=\
         {}ms 是纯串行的量级），必须有界。\
         上限取 4500 的理由：批截止 {deadline}ms + 被丢弃那一批在飞探测各自的单候选\
         预算 {budget}ms + 调度余量；纯串行是 {ser}ms，两者相差一个量级，本判据能区分。\
         （修前实测 N=32 = 38457ms）",
        N as u64 * SLOW_MS,
        deadline = 2500,
        budget = 1500,
        ser = N as u64 * SLOW_MS
    );
    println!("P9_SCALING N={N} elapsed_ms={elapsed_ms} got_facts={got}/{N}");
}
