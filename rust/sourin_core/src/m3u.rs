//! m3u / txt 直播播放列表解析
//!
//! # 为什么需要它
//!
//! TVBox 配置里的 `lives[]` 是一组**直播源地址**（`{name, url}`），
//! 而 `url` 指向的是 `.m3u` 或 `.txt` 播放列表。本仓此前**只能把这份清单
//! 原样回报给 UI**（`tvbox.rs` 的注释写着"本版本不导入"），
//! 因为没有解析器 ⇒ 拿不到频道。
//!
//! ⇒ 本模块补的就是这一跳：URL 里的文本 → [`LiveChannel`] 列表。
//!
//! # 两种格式
//!
//! ```text
//! #EXTM3U                                    ← 标准 m3u
//! #EXTINF:-1 tvg-logo="..." group-title="央视",CCTV-1
//! http://host/1.m3u8
//!
//! 央视一套,http://host/1.m3u8                 ← 朴素 txt（很多 "tv.txt" 就是这种）
//! ```
//!
//! # 设计原则
//!
//! **宽容解析，但绝不编造**：
//! - 属性缺失（没有 logo / 没有分组）⇒ 字段为 `None`，不是空串
//! - 某一行坏掉 ⇒ 跳过那一行，继续解析后面的
//! - **绝不**因为一行坏就整体失败：真实世界的直播列表里
//!   混着注释、空行、BOM、行尾空格、半截 URL，全都很常见

use crate::model::LiveChannel;

/// 解析一份播放列表文本
///
/// 自动识别 m3u（以 `#EXTM3U`/`#EXTINF` 开头）与朴素 txt（`名字,url`）。
/// 返回的 `id` 是**稳定**的（由 URL 与出现序号决定），
/// 这样刷新列表后同一个频道的 id 不变，用户的"上次看的台"才不会丢。
pub fn parse_playlist(text: &str, source_key: &str) -> Vec<LiveChannel> {
    let body = strip_bom(text);
    if looks_like_m3u(body) {
        parse_m3u(body, source_key)
    } else {
        parse_txt(body, source_key)
    }
}

fn strip_bom(s: &str) -> &str {
    s.strip_prefix('\u{feff}').unwrap_or(s)
}

fn looks_like_m3u(s: &str) -> bool {
    s.lines().take(5).any(|l| {
        let t = l.trim_start();
        t.starts_with("#EXTM3U") || t.starts_with("#EXTINF")
    })
}

// ─────────────────────────── m3u ───────────────────────────

fn parse_m3u(text: &str, source_key: &str) -> Vec<LiveChannel> {
    let mut out: Vec<LiveChannel> = Vec::new();
    // 待与 URL 配对的 EXTINF 信息
    let mut pending: Option<Attrs> = None;

    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXTINF") {
            pending = Some(parse_extinf(rest));
            continue;
        }
        if line.starts_with('#') {
            // 其它指令（#EXTGRP / #EXTVLCOPT / #KODIPROP …）一律忽略但不打断配对
            continue;
        }
        // 非 # 行 = 播放地址
        let url = line;
        if !is_playable_url(url) {
            // 半截/非法 URL：丢掉这一条，但保留 pending 之后的解析能力
            continue;
        }
        let attrs = pending.take().unwrap_or_default();
        // 名字优先取 EXTINF 逗号后的显式名；没有就用 tvg-name；
        // 再没有就退化成 URL 尾段（总比空白强，但绝不编造节目名）
        let name = attrs
            .display_name
            .clone()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| attrs.tvg_name.clone().filter(|s| !s.trim().is_empty()))
            .unwrap_or_else(|| fallback_name(url));
        out.push(make_channel(source_key, &name, url, &attrs, out.len()));
    }
    out
}

#[derive(Debug, Default, Clone)]
struct Attrs {
    tvg_name: Option<String>,
    logo: Option<String>,
    group: Option<String>,
    /// `#EXTINF:-1 attrs,显示名` 里逗号后面那段
    display_name: Option<String>,
}

/// 解析 `#EXTINF` 之后的内容：`:-1 tvg-logo="x" group-title="y",频道名`
fn parse_extinf(rest: &str) -> Attrs {
    // 先在**引号外**找最后一个逗号 —— 名字里可能有逗号，属性值里也可能有
    let (attr_part, display) = split_outside_quotes(rest);
    let mut a = Attrs {
        display_name: display.map(|s| s.trim().to_string()),
        ..Default::default()
    };
    a.tvg_name = attr_value(attr_part, "tvg-name");
    a.logo = attr_value(attr_part, "tvg-logo");
    a.group = attr_value(attr_part, "group-title");
    a
}

/// 在引号外定位第一个逗号，切成（属性部分, 名字部分）
fn split_outside_quotes(s: &str) -> (&str, Option<&str>) {
    let mut in_q = false;
    for (i, c) in s.char_indices() {
        match c {
            '"' => in_q = !in_q,
            ',' if !in_q => return (&s[..i], Some(&s[i + 1..])),
            _ => {}
        }
    }
    (s, None)
}

/// 取 `key="value"` 或 `key=value` 的值
fn attr_value(s: &str, key: &str) -> Option<String> {
    // ★ 必须**逐个**候选位置试：`x-tvg-name` 里也含 `tvg-name`，
    //   只看第一个匹配就 return None 会漏掉后面真正的 `tvg-name="..."`。
    let mut from = 0usize;
    let idx = loop {
        let rel = s[from..].find(key)?;
        let at = from + rel;
        let prev_ok = at == 0 || {
            let prev = s[..at].chars().next_back()?;
            !(prev.is_alphanumeric() || prev == '-' || prev == '_')
        };
        if prev_ok {
            break at;
        }
        from = at + key.len();
    };
    let after = &s[idx + key.len()..];
    let after = after.trim_start();
    let after = after.strip_prefix('=')?;
    let after = after.trim_start();
    if let Some(stripped) = after.strip_prefix('"') {
        let end = stripped.find('"')?;
        Some(stripped[..end].to_string())
    } else {
        // 无引号：取到空白为止
        let end = after
            .find(|c: char| c.is_whitespace())
            .unwrap_or(after.len());
        let v = &after[..end];
        if v.is_empty() {
            None
        } else {
            Some(v.to_string())
        }
    }
}

// ─────────────────────────── txt ───────────────────────────

fn parse_txt(text: &str, source_key: &str) -> Vec<LiveChannel> {
    let mut out = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // 两种写法都认：`名字,url` 与 `名字,url$分组`（部分列表在 URL 后跟 `$分组`）
        let Some((name, rest)) = line.split_once(',') else {
            continue;
        };
        let name = name.trim();
        let (url, group) = match rest.split_once('$') {
            Some((u, g)) => (u.trim(), Some(g.trim().to_string())),
            None => (rest.trim(), None),
        };
        if !is_playable_url(url) {
            continue;
        }
        let a = Attrs {
            group,
            ..Default::default()
        };
        // 名字为空时用 URL 尾段兜底（临时值要先绑出来，否则借用立即失效）
        let fb;
        let display = if name.is_empty() {
            fb = fallback_name(url);
            fb.as_str()
        } else {
            name
        };
        out.push(make_channel(
            source_key, display, url, &a, out.len(),
        ));
    }
    out
}

// ─────────────────────────── 公共 ───────────────────────────

/// 只接受看起来能播的地址
///
/// 放宽到允许 `rtmp:` / `rtsp:` / `mms:` 等老协议 —— 直播列表里确实有，
/// 我们不主动拒绝（能不能播由播放器决定），但**必须排除**裸文本/相对路径
/// （那些是解析失败的残渣，收进来只会变成点不开的台）。
fn is_playable_url(s: &str) -> bool {
    let l = s.to_ascii_lowercase();
    if !l.contains("://") {
        return false;
    }
    l.starts_with("http://")
        || l.starts_with("https://")
        || l.starts_with("rtmp://")
        || l.starts_with("rtsp://")
        || l.starts_with("mms://")
        || l.starts_with("udp://")
        || l.starts_with("rtp://")
}

fn fallback_name(url: &str) -> String {
    let no_query = url.split(['?', '#']).next().unwrap_or(url);
    let tail = no_query.rsplit('/').next().unwrap_or(no_query);
    let stem = tail.rsplit_once('.').map(|(a, _)| a).unwrap_or(tail);
    if stem.is_empty() {
        "未命名频道".to_string()
    } else {
        stem.to_string()
    }
}

fn make_channel(
    source_key: &str,
    name: &str,
    url: &str,
    attrs: &Attrs,
    index: usize,
) -> LiveChannel {
    LiveChannel {
        // ★ id 必须**稳定**：由 源key + url 决定，不掺 index 之外的易变因素。
        //   index 参与是为了让同一 URL 在列表里出现两次时也能区分（真实列表有重复）。
        id: format!("{source_key}::{index}::{}", short_hash(url)),
        name: name.to_string(),
        logo: attrs.logo.clone().filter(|s| !s.is_empty()),
        group: attrs.group.clone().filter(|s| !s.is_empty()),
        now_playing: None,
    }
}

/// 稳定短哈希（FNV-1a 64），只用于拼 id，不需要密码学强度
fn short_hash(s: &str) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_standard_m3u_with_attrs() {
        let text = "#EXTM3U\n\
                    #EXTINF:-1 tvg-id=\"c1\" tvg-name=\"CCTV1\" tvg-logo=\"http://x/l.png\" group-title=\"央视\",综合频道\n\
                    http://host/1.m3u8\n\
                    #EXTINF:-1 group-title=\"卫视\",某卫视\n\
                    http://host/2.m3u8\n";
        let ch = parse_playlist(text, "src");
        assert_eq!(ch.len(), 2);
        assert_eq!(ch[0].name, "综合频道", "逗号后的显式名优先");
        assert_eq!(ch[0].logo.as_deref(), Some("http://x/l.png"));
        assert_eq!(ch[0].group.as_deref(), Some("央视"));
        assert_eq!(ch[1].name, "某卫视");
        assert_eq!(ch[1].group.as_deref(), Some("卫视"));
    }

    #[test]
    fn parses_plain_txt_list() {
        let text = "综合,http://host/1.m3u8\n\
                    卫视,http://host/2.m3u8$地方\n";
        let ch = parse_playlist(text, "src");
        assert_eq!(ch.len(), 2);
        assert_eq!(ch[0].name, "综合");
        assert_eq!(ch[1].group.as_deref(), Some("地方"), "txt 支持 url$分组");
    }

    #[test]
    fn bad_lines_are_skipped_not_fatal() {
        // 真实列表里注释、空行、半截 URL 混在一起；不许因为一行坏就整体失败
        let text = "#EXTM3U\n\
                    \n\
                    # 这是注释\n\
                    #EXTINF:-1,好台\n\
                    http://host/ok.m3u8\n\
                    坏行没有URL\n\
                    #EXTINF:-1,也没地址\n\
                    not-a-url\n\
                    #EXTINF:-1,又一个好台\n\
                    http://host/ok2.m3u8\n";
        let ch = parse_playlist(text, "src");
        assert_eq!(ch.len(), 2, "只保留两个真的有 URL 的台");
        assert_eq!(ch[0].name, "好台");
        assert_eq!(ch[1].name, "又一个好台");
    }

    #[test]
    fn name_with_comma_is_not_truncated() {
        // 频道名里带逗号很常见（"新闻,综合"），不能被当成属性分隔符
        let text = "#EXTM3U\n#EXTINF:-1 group-title=\"g\",新闻,综合\nhttp://host/a.m3u8\n";
        let ch = parse_playlist(text, "src");
        assert_eq!(ch.len(), 1);
        assert_eq!(ch[0].name, "新闻,综合", "名字里的逗号必须保留");
    }

    #[test]
    fn missing_attrs_become_none_not_empty_string() {
        let text = "#EXTM3U\n#EXTINF:-1,只有名字\nhttp://host/a.m3u8\n";
        let ch = parse_playlist(text, "src");
        assert!(ch[0].logo.is_none(), "缺 logo ⇒ None，不是空串");
        assert!(ch[0].group.is_none(), "缺分组 ⇒ None，不是空串");
    }

    #[test]
    fn id_is_stable_across_reparses() {
        let text = "#EXTM3U\n#EXTINF:-1,A\nhttp://host/a.m3u8\n#EXTINF:-1,B\nhttp://host/b.m3u8\n";
        let a = parse_playlist(text, "src");
        let b = parse_playlist(text, "src");
        assert_eq!(a[0].id, b[0].id, "同样输入必须产出同样 id（用户的'上次看的台'不能丢）");
        assert_ne!(a[0].id, a[1].id, "不同频道 id 必须不同");
    }

    #[test]
    fn legacy_protocols_are_accepted_but_relative_paths_are_not() {
        let text = "#EXTM3U\n\
                    #EXTINF:-1,RTSP台\nrtsp://host/a\n\
                    #EXTINF:-1,相对路径\n/relative/a.m3u8\n";
        let ch = parse_playlist(text, "src");
        assert_eq!(ch.len(), 1, "rtsp 保留，相对路径是残渣要丢");
        assert_eq!(ch[0].name, "RTSP台");
    }

    #[test]
    fn unknown_attr_key_does_not_hijack_tvg_name() {
        // `x-tvg-name` 不能被当成 `tvg-name`
        let text = "#EXTM3U\n#EXTINF:-1 x-tvg-name=\"错\" tvg-name=\"对\",名字\nhttp://host/a.m3u8\n";
        let ch = parse_playlist(text, "src");
        // 显式名优先，所以这里验的是 attr_value 不串键：删掉显式名再看
        let text2 = "#EXTM3U\n#EXTINF:-1 x-tvg-name=\"错\" tvg-name=\"对\"\nhttp://host/a.m3u8\n";
        let ch2 = parse_playlist(text2, "src");
        assert_eq!(ch[0].name, "名字");
        assert_eq!(ch2[0].name, "对", "x-tvg-name 不许冒充 tvg-name");
    }

    #[test]
    fn empty_input_yields_empty_list() {
        assert!(parse_playlist("", "src").is_empty());
        assert!(parse_playlist("\n\n\n", "src").is_empty());
    }

    #[test]
    fn bom_is_stripped() {
        let text = "\u{feff}#EXTM3U\n#EXTINF:-1,A\nhttp://host/a.m3u8\n";
        assert_eq!(parse_playlist(text, "src").len(), 1, "BOM 不许让整份列表解析失败");
    }
}
