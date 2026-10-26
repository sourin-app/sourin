//! 网盘分享链接识别
//!
//! # 这是网盘能力的**第一步**，不是全部
//!
//! 完整链路是：`识别链接 → 解析分享页 → 拿文件列表 → 换下载直链 → 交给播放器`，
//! 若涉及私有内容还要 `账号登录 → 拿 cookie/token`。
//!
//! 本模块只做**第一跳**：把用户粘贴的一坨文本，认成
//! 「哪个网盘 + 分享 id + 提取码」。
//!
//! # 为什么先做这一跳
//!
//! - 它是**纯函数**：不发请求、不需要账号 ⇒ 可以离线全量测，
//!   也能在没拿到测试账号前就把最容易错的部分（域名判定、id 提取、
//!   提取码从哪来）做扎实。
//! - 后面每一跳都依赖它。识别错了，后面全白做。
//!
//! # 一条硬纪律：**不猜**
//!
//! 认不出就返回 `Unknown`，绝不"大概是夸克吧"。
//! 理由与 TVBox 那边一致：错误的识别会让用户拿到一个打不开的结果，
//! 而排查成本极高（他不知道是哪一步坏的）。
//!
//! # 域名表为什么写死
//!
//! 网盘域名是**外部契约**，但它是稳定的（不像内容接口会改版），
//! 且必须**精确匹配 host**（`pan.quark.cn` 不能靠 `contains("quark")` 认，
//! 否则 `evil-quark.example.com` 也会被认成夸克）。
//! 总结见 `docs/`：用 `ends_with` 匹配 host 后缀，并要求后缀前是 `.` 或字符串开头。

/// 支持识别的网盘种类
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PanKind {
    /// 夸克网盘
    Quark,
    /// UC 网盘（与夸克同源，接口相近）
    Uc,
    /// 百度网盘
    Baidu,
    /// 阿里云盘 / 阿里云盘（新域名）
    Aliyun,
    /// 123 网盘
    Pan123,
    /// 115 网盘
    Pan115,
    /// 天翼云盘
    Tianyi,
    /// 认不出（**不是错误**，是"这个链接不归我管"）
    Unknown,
}

impl PanKind {
    /// 稳定的机器可读标识（落盘 / 日志 / 埋点用，**不要用 Debug 输出**）
    pub fn code(self) -> &'static str {
        match self {
            PanKind::Quark => "quark",
            PanKind::Uc => "uc",
            PanKind::Baidu => "baidu",
            PanKind::Aliyun => "aliyun",
            PanKind::Pan123 => "123",
            PanKind::Pan115 => "115",
            PanKind::Tianyi => "tianyi",
            PanKind::Unknown => "unknown",
        }
    }

    /// 面向用户的名字（UI 直接显示）
    pub fn display(self) -> &'static str {
        match self {
            PanKind::Quark => "夸克网盘",
            PanKind::Uc => "UC 网盘",
            PanKind::Baidu => "百度网盘",
            PanKind::Aliyun => "阿里云盘",
            PanKind::Pan123 => "123 网盘",
            PanKind::Pan115 => "115 网盘",
            PanKind::Tianyi => "天翼云盘",
            PanKind::Unknown => "未知网盘",
        }
    }

    /// 是否是需要账号登录才能看私有文件的盘
    ///
    /// ⚠️ 这里是**能力声明**，不是"已实现"。登录链路尚未实现，
    /// 该字段供 UI 决定是否显示"登录"按钮，不冒充可用。
    pub fn needs_login_for_private(self) -> bool {
        !matches!(self, PanKind::Unknown)
    }
}

// ══════════════════════════════════════════════════════════════════════
//  「为什么还不能取直链」—— 分档判据（**纯函数**）
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么要把它从 `pan_auth::load` 里剥出来
// ```text
// 原来的分档判定是内联在 FFI 命令里的，入参含 `pan_auth::load(kind)`
// （读 **OS 钥匙串**）⇒ 在测试机上钥匙串不可用 ⇒
// ④「需要登录」⑤「登录已过期」这两档**永远执行不到**，
// 台账里"逐字断言已就位"其实是**恒不跑的空断言**（假绿）。
// ⇒ 把**判定**抽成纯函数（入参是三个 bool），钥匙串只负责算这几个 bool。
// ```

/// 一次"能不能取直链"的输入状态（由调用方从钥匙串/凭据算出来）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PanLoginState {
    /// 有没有该盘的凭据（`pan_auth::load(kind).is_some()`）
    pub logged_in: bool,
    /// 凭据是否已过期（有 `expires_at` 且早于 now；**没写过期时间 = 不过期**）
    pub expired: bool,
    /// 本版本是否已实现"取直链"（当前恒 false，见 `pan_list` 的模块头）
    pub has_direct_link: bool,
}

impl PanLoginState {
    /// 游客（未登录、无直链）
    pub fn guest() -> Self {
        Self { logged_in: false, expired: false, has_direct_link: false }
    }
}

/// 分档结果（机器可读码 + 逐字文案的唯一来源）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PanReasonTier {
    /// ① 认不出网盘
    Unknown,
    /// ② 认出了，但链接里没有分享 id
    NoShareId,
    /// ③ 没登录
    NeedLogin,
    /// ④ 登录过期
    Expired,
    /// ⑤ 已登录且未过期，但本版本还没接入取直链
    LoggedInNoDirectLink,
    /// ⑥ 真的能取（`has_direct_link = true` 且已登录未过期）
    Ready,
}

impl PanReasonTier {
    /// 稳定的机器可读码（落盘/埋点用，**不要用 Debug 输出**）
    pub fn code(self) -> &'static str {
        match self {
            PanReasonTier::Unknown => "unknown",
            PanReasonTier::NoShareId => "no_share_id",
            PanReasonTier::NeedLogin => "need_login",
            PanReasonTier::Expired => "expired",
            PanReasonTier::LoggedInNoDirectLink => "logged_in_no_direct_link",
            PanReasonTier::Ready => "ready",
        }
    }
    /// 这一档是否"还取不到直链"
    pub fn resolvable(self) -> bool {
        matches!(self, PanReasonTier::Ready)
    }
}

/// **分档判定（纯函数）**：给定识别结果与登录状态，落在哪一档
///
/// ⚠️ **顺序即优先级**，改顺序就是改语义：
/// ```text
/// ① 认不出            → Unknown      （连"哪个盘"都不知道，轮不到谈登录）
/// ② 没有分享 id       → NoShareId    （认出了盘，但这不是一条分享链接）
/// ③ 没登录            → NeedLogin    （**必须先判它**：未登录时谈"过期"没有意义）
/// ④ 过期              → Expired
/// ⑤ 已登录但没直链     → LoggedInNoDirectLink
/// ⑥ 都可              → Ready
/// ```
/// 注入反面：把 ③④ 顺序对调（先判 expired）⇒ `expired_tier_wins_over_need_login` 立刻红。
pub fn reason_tier(kind: PanKind, share_id: &str, st: PanLoginState) -> PanReasonTier {
    if kind == PanKind::Unknown {
        return PanReasonTier::Unknown;
    }
    if share_id.trim().is_empty() {
        return PanReasonTier::NoShareId;
    }
    if st.expired {
        return PanReasonTier::Expired;   // INJECT: 顺序对调（过期判在未登录之前）
    }
    if !st.logged_in {
        return PanReasonTier::NeedLogin;
    }
    if !st.has_direct_link {
        return PanReasonTier::LoggedInNoDirectLink;
    }
    PanReasonTier::Ready
}

/// 逐字文案（**唯一来源**：FFI 与测试都用它，避免两处各写一份漂移）
pub fn reason_text(kind: PanKind, tier: PanReasonTier) -> String {
    match tier {
        PanReasonTier::Unknown => "无法识别为受支持的网盘".to_string(),
        PanReasonTier::NoShareId => {
            "认出了网盘，但链接里没有分享 id（可能不是分享链接）".to_string()
        }
        PanReasonTier::NeedLogin => format!("需要先登录{}", kind.display()),
        PanReasonTier::Expired => format!("{}的登录已过期，请重新登录", kind.display()),
        PanReasonTier::LoggedInNoDirectLink => format!(
            "已登录{}：能列出分享里的文件，但本版本仍未接入取直链",
            kind.display()
        ),
        PanReasonTier::Ready => String::new(),
    }
}

/// 一次分享的识别结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanShare {
    pub kind: PanKind,
    /// 分享 id（各盘路径里那一段）
    pub share_id: String,
    /// URL 自带的提取码（`?pwd=xxxx` / `#pwd=xxxx`）
    pub pwd_in_url: Option<String>,
}

/// 从一段用户粘贴的文本里识别分享
///
/// # 为什么要吃"一段文本"而不是"一个 URL"
/// 用户实际粘贴的是这样的：
/// ```text
/// 我用夸克网盘分享了「某影片」，点击链接即可保存。
/// 链接：https://pan.quark.cn/s/abcdef123456
/// 提取码：8x2k
/// ```
/// 提取码**不在链接里**，而在正文。只接受干净 URL 会把这一半信息丢掉。
pub fn parse_share(text: &str) -> PanShare {
    let url = first_url(text).unwrap_or_default();
    let kind = detect_kind(&url);
    let share_id = if url.is_empty() {
        String::new()
    } else {
        extract_share_id(&url, kind)
    };
    let pwd_in_url = pwd_from_url(&url);
    // URL 里没有提取码 ⇒ 从正文找（"提取码：xxxx" / "密码: xxxx"）
    let pwd = pwd_in_url.clone().or_else(|| pwd_from_text(text));
    PanShare {
        kind,
        share_id,
        pwd_in_url: pwd,
    }
}

/// 只认 http(s) 的第一个 URL；没有就返回 None
fn first_url(text: &str) -> Option<String> {
    let lower = text.to_ascii_lowercase();
    for scheme in ["https://", "http://"] {
        if let Some(i) = lower.find(scheme) {
            let rest = &text[i..];
            // 链接在正文里通常以空白/中文标点结束
            let end = rest
                .find(|c: char| {
                    c.is_whitespace() || matches!(c, '，' | '。' | '、' | '）' | ')' | '"' | '\'' | '<' | '>')
                })
                .unwrap_or(rest.len());
            let u = rest[..end].trim_end_matches(['.', ',', ';']);
            if u.len() > scheme.len() {
                return Some(u.to_string());
            }
        }
    }
    None
}

/// 从 URL 里取 host（不含 userinfo / port）
fn host_of(url: &str) -> String {
    let after = url
        .split_once("://")
        .map(|(_, r)| r)
        .unwrap_or(url);
    let hostport = after.split(['/', '?', '#']).next().unwrap_or("");
    // 去掉 userinfo（`user:pass@host`）
    let hostport = hostport.rsplit_once('@').map(|(_, h)| h).unwrap_or(hostport);
    hostport.split(':').next().unwrap_or("").to_ascii_lowercase()
}

/// host 是否等于 `domain` 或以 `.domain` 结尾
///
/// ★ **不能用 `contains`**：`evil-quark.example.com` 含 `quark`，
///   但那是别人的域名。必须锚定在「整串相等」或「点号边界」。
fn host_is(host: &str, domain: &str) -> bool {
    host == domain || host.ends_with(&format!(".{domain}"))
}

fn detect_kind(url: &str) -> PanKind {
    if url.is_empty() {
        return PanKind::Unknown;
    }
    let h = host_of(url);
    // 顺序无关（各域名互不包含），但保持稳定便于阅读
    if host_is(&h, "pan.quark.cn") {
        PanKind::Quark
    } else if host_is(&h, "drive.uc.cn") {
        PanKind::Uc
    } else if host_is(&h, "pan.baidu.com") {
        PanKind::Baidu
    } else if host_is(&h, "aliyundrive.com") || host_is(&h, "alipan.com") {
        PanKind::Aliyun
    } else if host_is(&h, "123pan.com") || host_is(&h, "123684.com") {
        PanKind::Pan123
    } else if host_is(&h, "115.com") || host_is(&h, "115cdn.com") {
        PanKind::Pan115
    } else if host_is(&h, "cloud.189.cn") {
        PanKind::Tianyi
    } else {
        PanKind::Unknown
    }
}

/// 从路径里取分享 id
///
/// 各盘形态：
/// ```text
/// pan.quark.cn/s/<id>          drive.uc.cn/s/<id>
/// pan.baidu.com/s/<id>         aliyundrive.com/s/<id>
/// 123pan.com/s/<id>            115.com/s/<id>
/// cloud.189.cn/t/<id>
/// ```
/// 统一取「`/s/` 或 `/t/` 之后那一段」，其余形态返回空串（**不猜**）。
fn extract_share_id(url: &str, _kind: PanKind) -> String {
    let after_scheme = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    // 去掉 host 部分，只留 path + query
    let path = match after_scheme.find('/') {
        Some(i) => &after_scheme[i..],
        None => return String::new(),
    };
    let path = path.split(['?', '#']).next().unwrap_or(path);
    for seg in ["/s/", "/t/"] {
        if let Some(pos) = path.find(seg) {
            let rest = &path[pos + seg.len()..];
            let id = rest.split('/').next().unwrap_or("");
            if !id.is_empty() {
                return id.to_string();
            }
        }
    }
    String::new()
}

/// URL 自带提取码：`?pwd=xxxx`、`&pwd=xxxx`、`#pwd=xxxx`
fn pwd_from_url(url: &str) -> Option<String> {
    let lower = url.to_ascii_lowercase();
    let i = lower.find("pwd=")?;
    let rest = &url[i + 4..];
    let end = rest
        .find(|c: char| !c.is_ascii_alphanumeric())
        .unwrap_or(rest.len());
    let v = &rest[..end];
    if v.is_empty() {
        None
    } else {
        Some(v.to_string())
    }
}

/// 正文里的提取码：`提取码：8x2k` / `提取码: 8x2k` / `密码：abcd`
///
/// ★ 只认**紧跟在提示词后面**的 4~8 位字母数字，不全文瞎抓：
///   否则正文里的年份、集数、清晰度都会被当成提取码。
fn pwd_from_text(text: &str) -> Option<String> {
    const MARKERS: [&str; 4] = ["提取码", "密码", "访问码", "pwd"];
    for m in MARKERS {
        let lower_text = text.to_ascii_lowercase();
        let lower_m = m.to_ascii_lowercase();
        let mut from = 0usize;
        while let Some(rel) = lower_text[from..].find(&lower_m) {
            let at = from + rel;
            let after = &text[at + m.len()..];
            // 允许 `：` `:` 空格 等分隔
            let after = after.trim_start_matches(|c: char| {
                c.is_whitespace() || matches!(c, '：' | ':' | '=' | '「' | '」' | '"')
            });
            let code: String = after
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric())
                .collect();
            if (4..=8).contains(&code.len()) {
                return Some(code);
            }
            from = at + m.len();
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_each_supported_kind_by_exact_host() {
        let cases = [
            ("https://pan.quark.cn/s/abc123", PanKind::Quark),
            ("https://drive.uc.cn/s/abc123", PanKind::Uc),
            ("https://pan.baidu.com/s/1AbCd", PanKind::Baidu),
            ("https://www.aliyundrive.com/s/xyz", PanKind::Aliyun),
            ("https://www.alipan.com/s/xyz", PanKind::Aliyun),
            ("https://www.123pan.com/s/abc", PanKind::Pan123),
            ("https://115.com/s/abc", PanKind::Pan115),
            ("https://cloud.189.cn/t/abc", PanKind::Tianyi),
        ];
        for (url, want) in cases {
            assert_eq!(detect_kind(url), want, "url={url}");
        }
    }

    #[test]
    fn lookalike_hosts_are_not_recognized() {
        // ★ 这是本模块最重要的一条：不能用 contains 认域名
        let bad = [
            "https://evil-quark.example.com/s/abc",
            "https://pan.quark.cn.evil.com/s/abc",
            "https://notpan.baidu.com/s/abc",
            "https://quark.cn/s/abc", // 不是 pan. 子域
        ];
        for url in bad {
            assert_eq!(
                detect_kind(url),
                PanKind::Unknown,
                "★ 长得像的域名不许被认成网盘：{url}"
            );
        }
    }

    #[test]
    fn extracts_share_id_from_common_paths() {
        assert_eq!(extract_share_id("https://pan.quark.cn/s/abc123", PanKind::Quark), "abc123");
        assert_eq!(
            extract_share_id("https://pan.baidu.com/s/1AbCd?pwd=1234", PanKind::Baidu),
            "1AbCd",
            "query 不许混进 id"
        );
        assert_eq!(
            extract_share_id("https://cloud.189.cn/t/xyz789", PanKind::Tianyi),
            "xyz789"
        );
    }

    #[test]
    fn unknown_path_shape_yields_empty_id_not_guess() {
        // 路径里没有 /s/ 或 /t/ ⇒ 返回空串，不瞎猜
        assert_eq!(extract_share_id("https://pan.quark.cn/", PanKind::Quark), "");
        assert_eq!(
            extract_share_id("https://pan.quark.cn/some/other/path", PanKind::Quark),
            ""
        );
    }

    #[test]
    fn parses_pwd_from_url_query() {
        let r = parse_share("https://pan.baidu.com/s/1AbCd?pwd=8x2k");
        assert_eq!(r.kind, PanKind::Baidu);
        assert_eq!(r.share_id, "1AbCd");
        assert_eq!(r.pwd_in_url.as_deref(), Some("8x2k"));
    }

    #[test]
    fn parses_pwd_from_surrounding_text() {
        // 真实粘贴形态：提取码在正文，不在链接里
        let text = "我用夸克网盘分享了「某影片」，点击链接即可保存。\n\
                    链接：https://pan.quark.cn/s/abcdef123456\n\
                    提取码：8x2k";
        let r = parse_share(text);
        assert_eq!(r.kind, PanKind::Quark);
        assert_eq!(r.share_id, "abcdef123456");
        assert_eq!(r.pwd_in_url.as_deref(), Some("8x2k"), "提取码要能从正文取到");
    }

    #[test]
    fn does_not_mistake_numbers_in_text_for_pwd() {
        // 正文里有年份/集数，不能被当成提取码
        let text = "2024年上映 共12集 https://pan.quark.cn/s/abc";
        let r = parse_share(text);
        assert_eq!(r.share_id, "abc");
        assert_eq!(
            r.pwd_in_url, None,
            "★ 不许把正文里的数字抓成提取码（提示词后面才算）"
        );
    }

    #[test]
    fn unknown_text_yields_unknown_kind_not_error() {
        let r = parse_share("这不是链接");
        assert_eq!(r.kind, PanKind::Unknown);
        assert!(r.share_id.is_empty());
        assert_eq!(r.pwd_in_url, None);
        // 不是错误：这个链接不归我们管，不是"解析失败"
        assert_eq!(r.kind.display(), "未知网盘");
    }

    #[test]
    fn code_and_display_are_stable() {
        // 这两个值会进落盘/日志，改了就是破坏兼容
        assert_eq!(PanKind::Quark.code(), "quark");
        assert_eq!(PanKind::Pan123.code(), "123");
        assert_eq!(PanKind::Uc.display(), "UC 网盘");
    }
    // ── 分档判据（纯函数，★ 全部离线可跑；④⑤ 不再"执行不到"）──────────────
    #[test]
    fn tier_wise_texts_are_exact() {
        use PanReasonTier::*;
        let cases: [(PanLoginState, PanReasonTier); 6] = [
            (PanLoginState::guest(), NeedLogin),
            (
                PanLoginState { logged_in: true, expired: true, has_direct_link: false },
                Expired,
            ),
            (
                PanLoginState { logged_in: true, expired: false, has_direct_link: false },
                LoggedInNoDirectLink,
            ),
            (
                PanLoginState { logged_in: true, expired: false, has_direct_link: true },
                Ready,
            ),
            (PanLoginState { logged_in: false, expired: true, has_direct_link: false }, NeedLogin),
            (PanLoginState { logged_in: false, expired: false, has_direct_link: true }, NeedLogin),
        ];
        for (st, want) in cases {
            let got = reason_tier(PanKind::Quark, "abc", st);
            assert_eq!(got, want, "状态 {st:?} 应落在 {want:?}，实际 {got:?}");
        }
        // ★ ④ 登录（逐字）
        assert_eq!(
            reason_text(PanKind::Quark, NeedLogin),
            "需要先登录夸克网盘"
        );
        assert_eq!(reason_text(PanKind::Baidu, NeedLogin), "需要先登录百度网盘");
        // ★ ⑤ 过期（逐字）
        assert_eq!(
            reason_text(PanKind::Quark, Expired),
            "夸克网盘的登录已过期，请重新登录"
        );
        // 另一档（已登录但没直链）也逐字钉住
        assert_eq!(
            reason_text(PanKind::Uc, LoggedInNoDirectLink),
            "已登录UC 网盘：能列出分享里的文件，但本版本仍未接入取直链"
        );
    }

    /// ★ 识别层两档：认不出 / 没分享 id（与登录状态**无关**，要先判）
    #[test]
    fn tier_unknown_and_no_share_id_come_first() {
        use PanReasonTier::*;
        let logged_in = PanLoginState { logged_in: true, expired: false, has_direct_link: false };
        assert_eq!(reason_tier(PanKind::Unknown, "abc", logged_in), Unknown);
        assert_eq!(reason_tier(PanKind::Quark, "", logged_in), NoShareId);
        assert_eq!(reason_tier(PanKind::Quark, "   ", logged_in), NoShareId);
        assert_eq!(
            reason_text(PanKind::Unknown, Unknown),
            "无法识别为受支持的网盘"
        );
        assert_eq!(
            reason_text(PanKind::Quark, NoShareId),
            "认出了网盘，但链接里没有分享 id（可能不是分享链接）"
        );
    }

    /// ★★ 顺序判据：**未登录 + 已过期** 必须落在 ③ 而不是 ④
    ///
    /// 注入反面：把 `reason_tier` 里 `expired` 的判断挪到 `!logged_in` 之前 ⇒ 本条红。
    /// 语义理由：从没登录过的人看到"登录已过期"会以为"我登录过"，那是误导。
    #[test]
    fn expired_tier_wins_over_need_login() {
        let st = PanLoginState { logged_in: false, expired: true, has_direct_link: false };
        assert_eq!(
            reason_tier(PanKind::Quark, "abc", st),
            PanReasonTier::NeedLogin,
            "★ 未登录优先于过期"
        );
    }

    /// 码值稳定（落盘/埋点会用到）
    #[test]
    fn tier_codes_are_stable() {
        assert_eq!(PanReasonTier::Unknown.code(), "unknown");
        assert_eq!(PanReasonTier::NoShareId.code(), "no_share_id");
        assert_eq!(PanReasonTier::NeedLogin.code(), "need_login");
        assert_eq!(PanReasonTier::Expired.code(), "expired");
        assert_eq!(PanReasonTier::LoggedInNoDirectLink.code(), "logged_in_no_direct_link");
        assert_eq!(PanReasonTier::Ready.code(), "ready");
        assert!(PanReasonTier::Ready.resolvable());
        assert!(!PanReasonTier::LoggedInNoDirectLink.resolvable());
    }

}
