//! HLS 播放清单的**客观结构判定**（离线纯函数，只读文本）
//!
//! # 这个模块回答什么问题
//!
//! Owner 2026-10-30：「我今天还看了你大部分的都是播放都是6秒，根本就不是完整的视频内容」
//!
//! ⚠️ **不许用时长阈值判断**（Owner 明确指出"不应该以时间判断"）。时长是结果，
//! 不是原因；拿 `<60s`、`<20min` 这类自定阈值贴标签，本质还是在猜。
//!
//! 本模块改为读**清单里客观存在的标记**，让流自己说话：
//!
//! ```text
//! · #EXT-X-DISCONTINUITY  —— 清单声明了时间轴不连续（拼接/拼接广告/多段合成）
//! · #EXT-X-ENDLIST        —— 清单是否已完结（点播）还是直播中
//! · #EXTINF 段数与总时长   —— 事实读数（不是判断依据，是给人看的读数）
//! · #EXT-X-TARGETDURATION —— ★ 这个**不是内容时长**，是分片目标时长。
//!                            现场踩过：把 6 当成视频总长，实际那集是 82.72s。
//! ```
//!
//! # 实测依据（真机取证，`.probe/play-audit-all-sources-2026-10-30.md`）
//!
//! 那条报 `dur=6` 的「第33集」，源站清单实际是：
//!
//! ```text
//! #EXT-X-TARGETDURATION:6          ← mpv 报告的 duration=6 就来自这里
//! #EXTINF:6.000000, / #EXTINF:4.000000, ... 交替 17 段
//! #EXTINF:3.720000,
//! #EXT-X-DISCONTINUITY             ← 不连续点 1
//! #EXTINF:3.000000,
//! #EXT-X-DISCONTINUITY             ← 不连续点 2
//! #EXT-X-ENDLIST
//! ```
//! ⇒ `EXTINF` 求和 **82.72s**，但 mpv 在 DISCONTINUITY 处重建时间轴、
//! `stream.duration` 只报当前段（6/4/3s）、`pos` 反复归零。
//! ⇒ 用户看到「每次都是 6 秒」= **进度被重置 + 自动滚下一集**，不是视频真的 6 秒。
//!
//! # 边界（如实记录）
//!
//! · 本模块只做**结构判定**，不联网、不下载分片、不判定画质。
//! · `DISCONTINUITY` 不等于"坏流"：合法的多段拼接（广告切回正片）也会用它。
//!   所以只能作为"时间轴会跳"的**事实标记**上报，不能据此说流不可用。

/// 清单的结构事实（全部来自文本本身，无任何阈值）
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PlaylistFacts {
    /// 是否为 master（多码率）清单
    pub is_master: bool,
    /// 是否声明了 `#EXT-X-ENDLIST`（点播已完结）
    pub has_endlist: bool,
    /// `#EXT-X-DISCONTINUITY` 出现次数（>0 表示时间轴会跳）
    pub discontinuity_count: usize,
    /// `#EXTINF` 段数
    pub segment_count: usize,
    /// `#EXTINF` 求和（毫秒；四舍五入到毫秒避免浮点比对）
    pub total_ms: u64,
    /// `#EXT-X-TARGETDURATION` 声明的分片目标时长（秒）
    ///
    /// ⚠️ **这不是内容时长**。mpv/media_kit 在某些清单上会把它当 `stream.duration` 报，
    /// 这是"dur=6"假象的来源。字段名保留 target_ 前缀就是为了不让人误用。
    pub target_duration_secs: Option<u64>,
}

impl PlaylistFacts {
    /// 时间轴是否会跳（有 DISCONTINUITY 且不止一段）
    ///
    /// 只报告**事实**：清单自己声明了不连续。具体影响由调用方决定
    /// （UI 可以据此提示"该线路时间轴可能跳变"，播放层可以据此不做跨段 seek）。
    pub fn timeline_discontinuous(&self) -> bool {
        self.discontinuity_count > 0
    }

    /// 一句话读数（给日志/UI 用，不含任何判断）
    pub fn summary(&self) -> String {
        format!(
            "master={} endlist={} segs={} total={:.3}s disc={} target={}",
            self.is_master,
            self.has_endlist,
            self.segment_count,
            self.total_ms as f64 / 1000.0,
            self.discontinuity_count,
            self.target_duration_secs
                .map(|v| format!("{v}s"))
                .unwrap_or_else(|| "-".to_string()),
        )
    }
}

/// 解析清单文本 → 结构事实（纯函数，永不 panic）
///
/// 对 master 清单：`segment_count`/`total_ms` 为 0（master 本身不含分片），
/// `is_master = true`。调用方若要拿子清单的事实，需自行追一层再解析。
pub fn parse_playlist_facts(text: &str) -> PlaylistFacts {
    let mut f = PlaylistFacts::default();
    let mut total_ms: u64 = 0;

    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with("#EXT-X-STREAM-INF") {
            f.is_master = true;
            continue;
        }
        if line.starts_with("#EXT-X-ENDLIST") {
            f.has_endlist = true;
            continue;
        }
        if line.starts_with("#EXT-X-DISCONTINUITY") {
            // ⚠️ 注意 `#EXT-X-DISCONTINUITY-SEQUENCE` 也以此开头，
            //    但它表达的是"序列号"不是"不连续点"，不能算进去。
            if !line.starts_with("#EXT-X-DISCONTINUITY-SEQUENCE") {
                f.discontinuity_count += 1;
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXT-X-TARGETDURATION:") {
            f.target_duration_secs = rest
                .split(',')
                .next()
                .and_then(|s| s.trim().parse::<f64>().ok())
                .map(|v| v.round() as u64);
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXTINF:") {
            f.segment_count += 1;
            // 形如 `#EXTINF:6.000000,` 或 `#EXTINF:6,标题`
            if let Some(secs) = rest
                .split(',')
                .next()
                .and_then(|s| s.trim().parse::<f64>().ok())
            {
                total_ms += (secs * 1000.0).round() as u64;
            }
        }
    }

    f.total_ms = total_ms;
    f
}

// ═══════════════════════════════════════════════════════════════════════
//  resolve 链路接线（task-8，2026-10-30）：读清单 → 候选字段
// ═══════════════════════════════════════════════════════════════════════

/// 清单探测预算（lead 定死：1500ms；超时/失败一律留 None，绝不阻断起播）
pub const PROBE_BUDGET_MS: u64 = 1500;

/// 探测结果 = 要填进 `StreamCandidate` 的两个字段（task-8 契约）
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PlaylistProbe {
    /// 清单真实整集时长（仅 `#EXT-X-ENDLIST` 时有值；直播/失败 = None）
    pub total_ms: Option<u64>,
    /// 清单声明了 DISCONTINUITY（事实标记，不判好坏）
    pub discontinuous: bool,
}

/// 纯决策：清单事实 → 候选字段（离线门禁直接喂，不发网络）
///
/// ```text
/// 约束①：只有 has_endlist（点播已完结）才填 total —— 直播清单必须 None
///         （直播本来没有总时长，填了就是错的）。
/// 约束⑤：discontinuous 照实反映 DISCONTINUITY 计数>0 —— 事实标记，不判好坏。
/// total_ms==0（有 ENDLIST 但解析不出分片）也不填 —— 0 毫秒同样是错误读数。
/// ```
pub fn fields_from_facts(f: &PlaylistFacts) -> PlaylistProbe {
    PlaylistProbe {
        total_ms: if f.has_endlist && f.total_ms > 0 {
            Some(f.total_ms)
        } else {
            None
        },
        discontinuous: f.timeline_discontinuous(),
    }
}

fn probe_client() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            // 与 csp 站点同一条纪律：不读系统代理（代理会把「清单可读」测成「全失败」）
            .no_proxy()
            .build()
            .expect("HTTP client 构建失败（TLS 后端不可用）—— 不许退回无 no_proxy 的兜底")
    })
}

/// master 清单里第一个变体子清单的 URI（`#EXT-X-STREAM-INF` 后的第一条非注释行）
fn master_variant_uri(text: &str) -> Option<String> {
    let mut pending = false;
    for raw in text.lines() {
        let line = raw.trim();
        if line.starts_with("#EXT-X-STREAM-INF") {
            pending = true;
            continue;
        }
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if pending {
            return Some(line.to_string());
        }
        pending = false;
    }
    None
}

/// 相对 URI → 绝对（够 HLS 用的最小实现：绝对 URL 原样；`/` 开头接 scheme://host；
/// 其余接 base 的目录前缀）
///
/// ⚠️ base 必须先剥 query/fragment —— 现场 URL 形如 `master.m3u8?sign=…`，
///    不剥的话子清单会拼进 query 后面（`720/…index.m3u8?sign=…` 之后）必 404
///    （门禁 probe_candidate_fills_mislabeled_mp4_hls 抓到的真 bug）。
fn resolve_uri(base: &str, uri: &str) -> String {
    if uri.starts_with("http://") || uri.starts_with("https://") {
        return uri.to_string();
    }
    let base = base.split(['?', '#']).next().unwrap_or(base);
    if let Some(rest) = uri.strip_prefix('/') {
        if let Some(scheme_end) = base.find("://") {
            if let Some(host_end) = base[scheme_end + 3..].find('/') {
                let host = &base[..scheme_end + 3 + host_end];
                return format!("{host}/{rest}");
            }
        }
    }
    match base.rfind('/') {
        Some(i) => format!("{}{}", &base[..=i], uri),
        None => uri.to_string(),
    }
}

async fn fetch_text(url: &str, headers: &[(String, String)]) -> Option<String> {
    let mut req = probe_client().get(url);
    for (k, v) in headers {
        // 头解析失败就丢这一条（探测是 best-effort，绝不因头坏而失败）
        if let (Ok(name), Ok(val)) = (
            reqwest::header::HeaderName::from_bytes(k.as_bytes()),
            reqwest::header::HeaderValue::from_str(v),
        ) {
            req = req.header(name, val);
        }
    }
    let resp = req.send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.text().await.ok()
}

/// 读清单事实并按硬约束产出两个字段（task-8 接线入口）
///
/// ```text
/// 预算：整体 1500ms（PROBE_BUDGET_MS）—— master + 子清单两次取数共用这一份预算，
///       超时/非 200/解析失败一律返回默认值（None/false），绝不 Err、绝不阻断起播。
/// 约束②：master 清单追一层子清单再取事实（实测案例2：master→720/hls/index.m3u8，
///       子清单才是分片；master 本身 EXTINF 求和恒为 0）。
/// ```
pub async fn probe_playlist(url: &str, headers: &[(String, String)]) -> PlaylistProbe {
    let mut out = PlaylistProbe::default();
    let work = async {
        let text = fetch_text(url, headers).await?;
        let facts = parse_playlist_facts(&text);
        let facts = if facts.is_master {
            let uri = master_variant_uri(&text)?;
            let child = resolve_uri(url, &uri);
            let child_text = fetch_text(&child, headers).await?;
            parse_playlist_facts(&child_text)
        } else {
            facts
        };
        out = fields_from_facts(&facts);
        Some(())
    };
    let _ = tokio::time::timeout(std::time::Duration::from_millis(PROBE_BUDGET_MS), work).await;
    out
}

/// URL 是否**明显是 HLS 清单**（客观事实：去 query/fragment 后 path 以 `.m3u8` 结尾）
///
/// # 为什么只有 kind==Hls 不够（2026-10-30 真机实测）
/// ```text
/// csp-appyqk「老舅除三害」（就是取证里 82.72s 的 DISCONTINUITY 清单）把一个
/// 实际是 master.m3u8 的流标成了 kind=Mp4 ⇒ 守卫按 kind==Hls 判，正好跳过
/// ⇒ 日志无「清单事实」行、duration 没被修正。这类"标 mp4 实为 m3u8"
///   在插件源里不会是孤例 ⇒ kind（源的自述）之外补 URL path 事实，两条件取或。
/// ```
pub fn looks_like_hls_url(url: &str) -> bool {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    path.to_ascii_lowercase().ends_with(".m3u8")
}

/// 该候选要不要读清单（task-8 硬约束④的**唯一判据**）
///
/// ```text
/// kind==Hls（源的自述）或 URL path 明显是 .m3u8（客观事实）⇒ 读；
/// mp4 直链/无后缀且非 Hls ⇒ 不读（不给起播加延迟）。
/// ```
pub fn should_probe_candidate(kind: &crate::model::StreamKind, url: &str) -> bool {
    matches!(kind, crate::model::StreamKind::Hls) || looks_like_hls_url(url)
}

/// 候选级入口：按守卫探测并就地填两字段（playback.rs 的 resolve 出口调用）
pub async fn probe_candidate(c: &mut crate::model::StreamCandidate) {
    if !should_probe_candidate(&c.kind, &c.url) {
        return;
    }
    let probe = probe_playlist(&c.url, &c.headers).await;
    c.playlist_total_ms = probe.total_ms;
    c.playlist_discontinuous = probe.discontinuous;
}

/// 批处理入口（task-8 在 resolve 出口的唯一调用点）
///
/// # 为什么要有这一层（P9 立案，实测数字）
///
/// ```text
/// 单候选预算 PROBE_BUDGET_MS=1500，且 master 还要在同一预算内追子清单。
/// 按候选**串行** await 的实测墙钟（门禁 p9_batch_probe_wallclock_has_hard_cap，
/// 每条清单故意慢 1200ms）：
///     8 条候选  = 9615ms
///     32 条候选 = 38457ms      ⇒ 完全线性（N×单候选）
/// 真机形态里多线路内容很常见（思君如故 8 线路、聚合条目十几条候选），
/// 这些时间**全部堆在首帧之前** ⇒ 与 Owner 在 1.3 定的「不增加起播延迟」直接冲突。
/// ```
///
/// # 现在的做法（并发 + 限流 + 批级截止）
///
/// ```text
/// · 只对通过守卫（should_probe_candidate）的候选探测 ⇒ mp4 直链零成本；
/// · 同时在飞上限 PROBE_MAX_CONCURRENCY=8（不给单台上游砸并发，与 registry
///   搜索并发取 12 的理由同源）；
/// · 整批硬截止 PROBE_BATCH_DEADLINE_MS=2500：到点没探完的候选**一律留 None**
///   —— 约束③「失败/没读到 ⇒ None，绝不编读数」；宁可这条线路没有权威时长
///   （退回 mpv 广播值，行为与修复前一致），也不让它继续拖住起播。
/// ```
///
/// 剩余代价（如实记录）：worst case 仍会为首帧前探测花到 2500ms（只在候选多
/// 且上游慢时出现）；彻底消除需把探测挪到起播后台回填，那要动推送通道，另议。
pub async fn probe_candidates(list: &mut [crate::model::StreamCandidate]) {
    /// 同时在飞的探测上限（与 registry 搜索并发取 12 同源：不给同一上游砸满并发）
    const PROBE_MAX_CONCURRENCY: usize = 8;
    /// 整批硬截止（与候选数无关）—— 超预算的候选留 None，绝不为凑齐而拖住起播
    const PROBE_BATCH_DEADLINE_MS: u64 = 2500;

    let targets: Vec<ProbeTarget> = list
        .iter()
        .enumerate()
        .filter(|(_, c)| should_probe_candidate(&c.kind, &c.url))
        .map(|(i, c)| ProbeTarget {
            idx: i,
            url: c.url.clone(),
            headers: c.headers.clone(),
            total_ms: None,
            discontinuous: false,
        })
        .collect();
    if targets.is_empty() {
        return;
    }
    let _ = tokio::time::timeout(
        std::time::Duration::from_millis(PROBE_BATCH_DEADLINE_MS),
        drain_probes(list, targets, PROBE_MAX_CONCURRENCY),
    )
    .await;
    // 超时 ⇒ 上面的 future 被丢弃，未回填的候选保持 None/false（约束③）。
    // ⚠️ 准确说法：drop JoinSet 是**脱管**（detached）而非 abort —— 已在飞的探测任务
    //    会继续跑完它自己那 1500ms 预算，只是没人再接收结果。
    //    安全性来自"回填只发生在 drain_probes 的接收循环里"：那个循环随 future
    //    一起被丢弃 ⇒ 绝不会有任务往 list 写，也就不存在写脏或写下标越界。
    //    代价是最多多耗几个后台任务的网络往返，不影响起播（起播不等它们）。
}

/// 一个待探测候选（spawn 的 future 必须 'static ⇒ 字段全 owned）
///
/// `total_ms`/`discontinuous` 由探测任务回填；初值 None/false 就是约束③的语义
/// （没读到 ⇒ 没有读数，绝不编）。
#[derive(Clone)]
struct ProbeTarget {
    idx: usize,
    url: String,
    headers: Vec<(String, String)>,
    total_ms: Option<u64>,
    discontinuous: bool,
}

/// 并发探测并把结果回填到 list[idx]，限流 max_in_flight
async fn drain_probes(list: &mut [crate::model::StreamCandidate], targets: Vec<ProbeTarget>, max_in_flight: usize) {
    let mut set = tokio::task::JoinSet::new();
    let mut launched = 0usize;
    while launched < max_in_flight.min(targets.len()) {
        let mut t = targets[launched].clone();
        launched += 1;
        set.spawn(async move {
            let probe = probe_playlist(&t.url, &t.headers).await;
            t.total_ms = probe.total_ms;
            t.discontinuous = probe.discontinuous;
            t
        });
    }
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok(done) => {
                if let Some(c) = list.get_mut(done.idx) {
                    c.playlist_total_ms = done.total_ms;
                    c.playlist_discontinuous = done.discontinuous;
                }
            }
            Err(e) => {
                // 任务 panic/被取消 ⇒ 该候选保持 None（约束③），不阻断其它候选。
                // ★ 落文件日志走 applog（本 crate 的 log 门面从未装 sink，
                //   log::warn 会被整个丢弃 —— 2026-10-30 真机已实锤过一次）。
                crate::applog::write_file_log("PLAY", &format!("清单探测任务失败（该线路留无读数）：{e}"));
            }
        }
        if launched < targets.len() {
            let mut t = targets[launched].clone();
            launched += 1;
            set.spawn(async move {
                let probe = probe_playlist(&t.url, &t.headers).await;
                t.total_ms = probe.total_ms;
                t.discontinuous = probe.discontinuous;
                t
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 现场取证的那条清单（`.probe` 抓的真实内容，缩略为关键行）
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

    #[test]
    fn real_case_reports_82s_not_6s() {
        let f = parse_playlist_facts(REAL_CASE);
        // ★ 这条断言就是整个模块的存在理由：真实总时长 82.72s，
        //   而 mpv 报的 duration=6 来自 TARGETDURATION。
        assert_eq!(f.segment_count, 17, "17 个分片");
        assert_eq!(f.total_ms, 82_720, "EXTINF 求和 = 82.72s");
        assert_eq!(f.target_duration_secs, Some(6), "TARGETDURATION 是 6（分片目标时长）");
        assert_ne!(
            f.total_ms,
            f.target_duration_secs.unwrap() * 1000,
            "★ 内容总时长绝不等于 TARGETDURATION —— 混用就是「6 秒」假象的根因"
        );
        assert_eq!(f.discontinuity_count, 2, "两个不连续点");
        assert!(f.has_endlist, "点播清单已完结");
        assert!(f.timeline_discontinuous(), "时间轴会跳");
        assert!(!f.is_master);
    }

    #[test]
    fn targetduration_alone_is_not_duration() {
        // 只有 TARGETDURATION、没有任何分段 ⇒ 总时长必须是 0，不能回落成 6
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-ENDLIST\n";
        let f = parse_playlist_facts(text);
        assert_eq!(f.segment_count, 0);
        assert_eq!(f.total_ms, 0, "没有分片就没有时长 —— 不许拿 TARGETDURATION 顶替");
        assert_eq!(f.target_duration_secs, Some(6));
    }

    #[test]
    fn discontinuity_sequence_is_not_a_discontinuity_point() {
        // #EXT-X-DISCONTINUITY-SEQUENCE 是序列号，不是不连续点
        let text = "#EXTM3U\n#EXT-X-DISCONTINUITY-SEQUENCE:5\n#EXTINF:2,\na.ts\n";
        let f = parse_playlist_facts(text);
        assert_eq!(f.discontinuity_count, 0, "SEQUENCE 不能被算成不连续点");
        assert!(!f.timeline_discontinuous());
    }

    #[test]
    fn master_playlist_is_flagged_and_has_no_segments() {
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128\n720/index.m3u8\n";
        let f = parse_playlist_facts(text);
        assert!(f.is_master);
        assert_eq!(f.segment_count, 0);
        assert_eq!(f.total_ms, 0);
    }

    #[test]
    fn clean_playlist_has_no_false_alarm() {
        // 正常单片清单：无 DISCONTINUITY ⇒ 不许误报"时间轴会跳"
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n\
#EXTINF:4.0,\na.ts\n#EXTINF:4.0,\nb.ts\n#EXT-X-ENDLIST\n";
        let f = parse_playlist_facts(text);
        assert_eq!(f.discontinuity_count, 0);
        assert!(!f.timeline_discontinuous());
        assert_eq!(f.total_ms, 8000);
    }

    /// ★ task-8 硬约束①的**正向常驻门禁**（lead 要求长期跑在 --lib 里）：
    /// 直播形态清单（有 EXTINF 分片、**无** DISCONTINUITY 也**无** ENDLIST）
    /// ⇒ fields_from_facts 的 total 必须是 None（直播没有总时长，填了就是错的）。
    #[test]
    fn live_form_without_endlist_yields_none_total() {
        let live = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n\
#EXTINF:4.0,\na.ts\n#EXTINF:4.0,\nb.ts\n";
        let f = parse_playlist_facts(live);
        assert!(!f.has_endlist, "前置：直播形态（无 ENDLIST）");
        assert_eq!(f.discontinuity_count, 0, "前置：也无 DISCONTINUITY");
        assert_eq!(f.total_ms, 8000, "EXTINF 求和照样算得出（但语义不是整集）");
        let probe = fields_from_facts(&f);
        assert_eq!(
            probe.total_ms, None,
            "★ 硬约束①：无 ENDLIST ⇒ total 必须 None（注入证红的正向常驻对）"
        );
        assert!(!probe.discontinuous, "无 DISCONTINUITY ⇒ 事实标记为 false");
    }
}
