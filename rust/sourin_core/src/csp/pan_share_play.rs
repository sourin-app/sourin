// ═══════════════════════════════════════════════════════════════════════
//  分享页当剧集 —— 把 `pan.quark.cn/s/<id>` / `drive.uc.cn/s/<id>` 解析成直链
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这一层（Owner 现场：`冰雪奇缘` 点开 ⇒ "这个格式解不了"）
//
// ```text
// `csp-4k-zhinan` / `GuiGui` / `HdMoli` / `PanSou` 这些源，详情页给的"线路"
// **本来就是分享页 URL**（label 里写着「夸克网盘（分享页）」）。
// 它们自己的 `play()` 只能把 URL 原样交回去 ⇒ 播放器拿到的不是媒体流
// ⇒ `Failed to recognize file format.`
//
// `PanDrive::resolve_share_play` 已经能做"分享页 → 转存 → 直链"那一段；
// 这里只做**识别 + 建对应的盘**，让所有 csp 源共享同一跳
// （否则每个源都要自己接一遍网盘，等于把协议抄 N 份）。
// ```
//
// # 只认"分享页"这一种形状，不猜
// ```text
// 认：`pan.quark.cn/s/<id>`、`drive.uc.cn/s/<id>`（可带 `?pwd=xxxx`）
// 不认：直链、播放页、别的网盘（百度/115/阿里/天翼/迅雷/123/光鸭）
//       ⇒ 返回 None，由调用方原样交回（那些盘的解析还没接，不能假装能播）
// ```

use crate::pan::PanKind;

use super::pan_drive::{quark_spec, uc_spec, PanDrive};

/// 一次识别结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareRef {
    pub kind: PanKind,
    pub share_id: String,
    /// 提取码（`?pwd=xxxx`；没有就是空串）
    pub passcode: String,
}

/// 从 URL 里取出 host 之后的路径段（自己写，避免为一个字段引 url 依赖）
fn path_of(url: &str) -> &str {
    let after_scheme = match url.split_once("://") {
        Some((_, rest)) => rest,
        None => url,
    };
    let after_host = match after_scheme.find('/') {
        Some(i) => &after_scheme[i..],
        None => "",
    };
    after_host
}

/// `?pwd=` / `&pwd=` 的值（大小写不敏感；没有 ⇒ 空串）
fn passcode_of(url: &str) -> String {
    let Some((_, query)) = url.split_once('?') else {
        return String::new();
    };
    let query = query.split('#').next().unwrap_or("");
    for kv in query.split('&') {
        let (k, v) = match kv.split_once('=') {
            Some(p) => p,
            None => continue,
        };
        if k.eq_ignore_ascii_case("pwd") || k.eq_ignore_ascii_case("passcode") {
            return v.trim().to_string();
        }
    }
    String::new()
}

/// 识别"分享页 URL"。**纯函数**（门禁直接喂 URL，不碰网络）
///
/// ⚠️ 域名用**精确匹配**（与 `pan.rs::host_is` 同一条纪律）：
///   `contains("quark.cn")` 会把 `quark.cn.evil.com` 也认成夸克分享。
pub fn parse_share_page(url: &str) -> Option<ShareRef> {
    let u = url.trim();
    if u.is_empty() {
        return None;
    }
    let host = u
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(u)
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    let host = host.split(':').next().unwrap_or(""); // 去掉端口
    let kind = if host == "pan.quark.cn" || host.ends_with(".pan.quark.cn") {
        PanKind::Quark
    } else if host == "drive.uc.cn" || host.ends_with(".drive.uc.cn") {
        PanKind::Uc
    } else {
        return None;
    };
    // 路径必须形如 `/s/<id>`（分享页）。其它路径（`/list`、`/`）不是分享
    let path = path_of(u);
    let rest = path.strip_prefix("/s/")?;
    let share_id = rest.split(['/', '?', '#']).next().unwrap_or("").trim();
    if share_id.is_empty() {
        return None;
    }
    Some(ShareRef {
        kind,
        share_id: share_id.to_string(),
        passcode: passcode_of(u),
    })
}

/// 按盘种建一个 `PanDrive`（规格来自 `pan_drive.rs` 的两份数据）
pub fn drive_for(kind: PanKind) -> Option<PanDrive> {
    match kind {
        PanKind::Quark => Some(PanDrive::with_spec("PanQuark", quark_spec())),
        PanKind::Uc => Some(PanDrive::with_spec("PanUC", uc_spec())),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★ 两种分享页形状都要认（这是"能不能播"的第一跳）
    #[test]
    fn recognizes_quark_and_uc_share_pages() {
        let q = parse_share_page("https://pan.quark.cn/s/6c3812f483a6").expect("夸克分享页");
        assert_eq!(q.kind, PanKind::Quark);
        assert_eq!(q.share_id, "6c3812f483a6");
        assert_eq!(q.passcode, "");

        let u = parse_share_page("https://drive.uc.cn/s/ba2e2f0417114?pwd=8x2k").expect("UC 分享页");
        assert_eq!(u.kind, PanKind::Uc);
        assert_eq!(u.share_id, "ba2e2f0417114");
        assert_eq!(u.passcode, "8x2k", "★ 提取码要带出来（带码分享不带就 15000）");
    }

    /// ★★★ 反面：**长得像的域名不算**、别的路径不算、别的网盘不算
    ///
    /// ```text
    /// 注入验证：把 host 判断改成 `host.contains("quark.cn")`
    ///   ⇒ `quark.cn.evil.com` 这条 FAILED。
    /// ```
    #[test]
    fn rejects_lookalikes_and_non_share_paths() {
        assert!(parse_share_page("https://pan.quark.cn.evil.com/s/abc").is_none());
        assert!(parse_share_page("https://pan.quark.cn/list/abc").is_none(), "不是 /s/");
        assert!(parse_share_page("https://pan.quark.cn/s/").is_none(), "空 id");
        assert!(parse_share_page("https://pan.baidu.com/s/1abc").is_none(), "百度未接");
        assert!(parse_share_page("http://example.com/video.mp4").is_none());
        assert!(parse_share_page("").is_none());
    }

    /// ★★ 提取码的两种键名 + 大小写 + 非 pwd 参数不许误抓
    #[test]
    fn passcode_parsing_is_narrow() {
        assert_eq!(passcode_of("https://x/s/a?pwd=ab12"), "ab12");
        assert_eq!(passcode_of("https://x/s/a?PWD=ab12&t=1"), "ab12");
        assert_eq!(passcode_of("https://x/s/a?passcode=zz"), "zz");
        assert_eq!(passcode_of("https://x/s/a?q=1"), "", "别的参数不算提取码");
        assert_eq!(passcode_of("https://x/s/a"), "");
    }
}