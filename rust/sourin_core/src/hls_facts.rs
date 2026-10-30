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
}
