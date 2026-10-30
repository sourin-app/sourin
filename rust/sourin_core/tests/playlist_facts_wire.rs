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

/// 硬约束④（接线）：playback 只对 hls 候选探测 —— mp4 直链不读
///
/// 源码级断言（include_str! 先例 tvbox_aggregate.rs:2720）：探测调用必须被
/// `matches!(c.kind, …StreamKind::Hls)` 守卫包住。
#[test]
fn playback_probes_only_hls_candidates() {
    let src = include_str!("../src/playback.rs").replace("\r\n", "\n");
    let seg = src
        .split("if matches!(c.kind, crate::model::StreamKind::Hls) {")
        .nth(1)
        .expect("playback.rs 的探测必须由 StreamKind::Hls 守卫（约束④：mp4 不读）");
    let probe_seg = seg
        .split("}")
        .next()
        .expect("守卫块必须闭合");
    assert!(
        probe_seg.contains("hls_facts::probe_playlist"),
        "Hls 守卫块内必须调 probe_playlist"
    );
    assert!(
        src.contains("probe_playlist(&c.url, &c.headers)"),
        "探测必须用原始上游 URL 与候选自带头（在 maybe_proxy 之前）"
    );
}
