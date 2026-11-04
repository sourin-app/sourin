// ═══════════════════════════════════════════════════════════════════════
//  分享页识别与宿主中间候选；候选地址不是可直接播放的媒体
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
// # parse_share_page 仍只认 Quark/UC 两族分享形状，不猜
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
    let Ok(parsed) = reqwest::Url::parse(url) else { return String::new(); };
    parsed.query_pairs().find(|(key, _)| {
        ["pwd", "passcode", "password", "code"].iter().any(|alias| key.eq_ignore_ascii_case(alias))
    }).map(|(_, value)| value.trim().to_string())
        .or_else(|| crate::pan::parse_share(url).pwd_in_url).unwrap_or_default()
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
    /*
     * ★ 2026-10-31（T4-C 防御纵深）：share_id 里混进**控制字符**就不是分享 id 了
     * （真 id 是十六进制串）。混入途径实测过：复合剧集 id 双重拼接后 `\u{1}` 落进
     * URL 段（见 provider.rs::episode_id_is_direct_play 的根因注释）。
     * 放它过去 ⇒ 它会进 Referer header ⇒ reqwest `Error::builder`（客户端构造失败，
     * 一个字节都没发出去，报错完全没指向性）。这里认不出就**如实交回 None**，
     * 由调用方原样处理 —— 不猜、不洗数据。
     */
    if share_id.chars().any(char::is_control) {
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

/// 分享页的中间候选，不是播放器可直接使用的媒体地址。
/// Quark/UC 继续复用两族识别器；Baidu/Xunlei 只交给宿主已接管的预检与解析。
/// provider.resolve 必须拦截这些候选，百度仍可能停在完整取流未接入的诚实边界。
pub fn share_page_play(url: &str, ua: &str) -> Option<super::CspPlay> {
    let label = if let Some(sr) = parse_share_page(url) {
        format!("网盘分享页（原生转直链：{}）", sr.kind.display())
    } else {
        if url.chars().any(char::is_control) { return None; }
        let parsed = reqwest::Url::parse(url.trim()).ok()?;
        let authority = url.trim().split_once("://")?.1.split(['/', '?', '#']).next()?;
        if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none()
            || !parsed.username().is_empty() || parsed.password().is_some() || authority.contains('@') {
            return None;
        }
        let share = crate::pan::parse_share(parsed.as_str());
        if !matches!(share.kind, PanKind::Baidu | PanKind::Xunlei)
            || share.share_id.is_empty()
            || !share.share_id.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte))
            || share.pwd_in_url.as_deref().is_some_and(|pwd| pwd.chars().any(char::is_control)) {
            return None;
        }
        format!("网盘分享页（待宿主检查解析：{}）", share.kind.display())
    };
    Some(super::CspPlay {
        url: url.trim().to_string(),
        headers: vec![("User-Agent".to_string(), ua.to_string())],
        label: Some(label),
    })
}

#[cfg(test)]
#[path = "pan_share_dispatch_tests.rs"]
mod share_dispatch_tests;

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
        assert_eq!(passcode_of("https://x/s/a?password=a%2Bb%2F%3D"), "a+b/=");
        assert_eq!(passcode_of("https://pan.quark.cn/s/a#pwd=zz12"), "zz12");
        assert_eq!(parse_share_page("https://drive.uc.cn/s/a#pwd=ab12").unwrap().passcode, "ab12");
        assert_eq!(passcode_of("https://x/s/a?q=1"), "", "别的参数不算提取码");
        assert_eq!(passcode_of("https://x/s/a"), "");
    }

    /// ★★★ T1a 门禁（2026-10-31）：share_page_play 只认夸克/UC 族，真 URL 形态全过
    ///
    /// # 夹具来源（**全部真网抓取，不自造** —— lead 条件①）
    /// ```text
    /// · wogg 114504「老舅（臻彩）」详情页（www.wogg.net/voddetail/114504.html）
    ///   2026-10-31 真抓：UC 带 ?public=1（多余参数最坏形态）、夸克、百度 ?pwd=wogg
    /// · hjzhencai 754 详情页 2026-10-31 真抓：夸克 f84677cde4ff、百度 ?pwd=vp3x
    /// · hdmoli 2857 详情页 2026-10-31 真抓（cleanenv 审计 n=60 的实际条目）
    /// · yidong_4k 的 139 分享页 resUrl（真站形态，其它族反例）
    /// ```
    #[test]
    fn share_page_play_preserves_family_and_offers_host_supported_shares() {
        let ua = "Mozilla/5.0";
        // 夸克族真 URL（wogg 真抓）
        let p = share_page_play("https://pan.quark.cn/s/384ca6d78a7b", ua).expect("真夸克分享页");
        assert_eq!(p.url, "https://pan.quark.cn/s/384ca6d78a7b");
        let lab = p.label.as_deref().unwrap_or("");
        assert!(lab.contains("原生转直链") && lab.contains("夸克"), "{lab}");
        // UC 族真 URL：带多余参数 ?public=1（wogg 真抓的最坏形态）
        let p = share_page_play("https://drive.uc.cn/s/8e1d7a0ade134?public=1", ua)
            .expect("真 UC 分享页（带 public 参数）");
        assert_eq!(p.url, "https://drive.uc.cn/s/8e1d7a0ade134?public=1");
        assert!(p.label.as_deref().unwrap_or("").contains("UC"));
        // UA 要带上（调用方站点的）
        assert_eq!(p.headers[0].0, "User-Agent");
        assert_eq!(p.headers[0].1, ua);
        // http 明文形态也要认（audit 里百度线路有 http 形态的先例）
        assert!(share_page_play("http://pan.quark.cn/s/8efcd269e4b7", ua).is_some());
        // 百度候选只用于宿主检查/解析，不宣称本层已经返回媒体。
        assert!(share_page_play("https://pan.baidu.com/s/1iLOQ464Uz5Q3MYQ3Qu0y9w?pwd=wogg", ua).unwrap().label.unwrap().contains("宿主检查解析"));
        assert!(share_page_play("https://pan.baidu.com/s/1yCHnLlsJLd_yyoaZjvRSEg?pwd=vp3x", ua).is_some());
        // 139（yidong_4k 真 resUrl 形态）⇒ None
        assert!(share_page_play("https://yun.139.com/shareweb/#/w/i/2yA8x3HAXdV06", ua).is_none());
        // 直链媒体不是分享页 ⇒ None
        assert!(share_page_play("https://cdn.example/vod/a.m3u8", ua).is_none());
    }

    /// ★★★ T4-C 门禁（2026-10-31）：share_id 混进控制字符 ⇒ 拒认（防御纵深）
    ///
    /// ```text
    /// 根因实测形态：复合剧集 id 双重拼接后 `\u{1}` 落进 URL 段 ⇒
    /// `parse_share_page` 在 `/` 截断产出 `8efcd269e4b7\u{1}https:` —— 旧代码照单
    /// 全收 ⇒ 它进 Referer ⇒ reqwest `Error::builder`。
    /// 注入证红：把 `share_id.chars().any(char::is_control)` 那个分支删掉 ⇒ 本条红。
    /// ```
    #[test]
    fn rejects_share_ids_with_control_chars() {
        // 根因现场形态（provider.rs 判据注释里的完整链条）
        assert!(parse_share_page("https://pan.quark.cn/s/8efcd269e4b7\u{1}https:").is_none());
        // 其它控制字符同样拒
        assert!(parse_share_page("https://pan.quark.cn/s/ab\u{7}cd").is_none());
        assert!(parse_share_page("https://pan.quark.cn/s/ab\ncd").is_none());
        // 正常 id（含提取码）不受影响
        assert!(parse_share_page("https://pan.quark.cn/s/8efcd269e4b7").is_some());
        assert!(parse_share_page("https://drive.uc.cn/s/ba2e2f0417114?pwd=8x2k").is_some());
    }
}
