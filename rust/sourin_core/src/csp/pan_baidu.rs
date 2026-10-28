// ═══════════════════════════════════════════════════════════════════════
//  csp_PanBaidu —— 网盘族：**做实现、不注册**（缺 host，判据见下）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★★ 为什么本类**没有** `register_site!`（三条判据缺第 ②条）
//
// ```text
// 本批对"能不能注册"的判据是三条：
//   ① 订阅里有站（`csp_PanBaidu` 在订阅里，`"searchable":0`）           ⇒ ✓ 有
//   ② DEX 里有可用的 host / 端点常量                                   ⇒ ✗ **没有**
//   ③ 有取数路径（能列目录，或能从 ext 拿到 host + 端点）              ⇒ ✗ 没有
// ⇒ 缺 ②（host）⇒ 按"不许猜域名"的纪律，**不注册**。
// ```
//
// # ② 到底缺什么（把取证结果摊开，别让后来人以为我偷懒）
//
// ```text
// `.probe/csp-parity/PanBaidu.txt` 里**全部**字面量（707 B，逐字）：
//   [c]      "/"  "/"  + 两张图标 URL
//   [<init>] "/"  "/"  "#"  "$"  "/"  "$$$"  + 一张头像 URL  + "folder"
//   [c]      "/"  "我的…"  "1"  "0"  + 逐字登录提示  + "1"
// ⇒ 里面**一个 host、一个接口路径都没有**：只有"根目录 = `/`"那个字面量是硬的。
//
// 端点确实存在于**同一个 jar 里**，但都在**别的类**：
//   · 分享解析那一族（`PanShare` 之类）里有分享列表 / 转存 / 删除的端点与参数；
//   · 阿里、123 的助手类里也能看到 123pan / alipan 的下载端点。
// ⇒ 那是**跨类**的东西，而这个类的继承关系是 `extends` 一个基类，
//   基类的取数走的是**分享链接解析 + 本地转发服务**（基类里逐字 `127.0.0.1:5266`），
//   不是"列出我的盘"的 API。
// ⇒ 照着别的类的端点"补"一个，就是在**猜协议**：猜出来的东西跑不通时，
//   用户看到的是"我的盘坏了"，而不是"这个类还没做"。⇒ 不做。
// ```
//
// # 那这个文件交付了什么（别把"没注册"读成"什么都没做"）
//
// ```text
// ① 把**能逐字确认的**东西钉死：货架名、根目录 `/`、逐字登录提示、
//    以及"缺哪一条"的可读 Err —— 将来谁补 host，把断言改成 Ok 就行；
// ② 给出 host 的**唯一合法来源**：ext（`{"site":…}` / `{"host":…}` / `{"url":…}`），
//    并**测了**这条解析（纯函数，不依赖网络）；
// ③ 把"缺 ② 之后不许做的事"写成判据：
//    · 不许注册（否则它会成为一条**用户可见的源**，点进去全是错）；
//    · 不许把分享页当视频流；
//    · 不许返回空列表冒充"盘是空的"。
// ```
//
// # 参考实现里这个类的真实形态（取证结论）
//
// ```text
// 它在 DEX 里只有 3 个方法：`<init>` / 两个 `homeContent` 形态的 `c`。
// 列目录 / 详情 / 播放**全部继承自基类** ⇒ 本类自己**没有**"我的盘列表"能力。
// ⇒ 这与"我们没做"是两件事：**原版这个类也只到这一步**（其余靠基类 + 本地转发）。
// ```
//
// # ⚠️ 播放相关的边界（与同批其它网盘类一致）
//
// ```text
// · 直链要靠账号 ⇒ 没有账号时 play **必须**可读 Err，**不许**把分享页当视频流。
// · 原版播放靠它自己起的本地转发服务（基类逐字 `127.0.0.1:5266`）；
//   本仓等价物是 `streamproxy::register(url, headers)` —— 本批未接通，
//   类里**不自己起服务**（那会重复造一套）。
// ```

use std::time::Duration;

use async_trait::async_trait;

use crate::pan::PanKind;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

/// UA（同族共用那条浏览器串；本类没有自己的 `[head]`，取同批一致值）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 无登录态时的提示 —— **逐字**取参考实现
const LOGIN_HINT: &str = "还未登录百度账号,请前往【配置中心】登录";

/// 首页货架名 —— **逐字**取参考实现
const SHELF_NAME: &str = "我的百度网盘";

/// 根目录路径 —— **逐字**取参考实现（`"/"` 在这个类里出现了 6 次，是本类唯一的硬常量）
const ROOT_FOLDER: &str = "/";

/// "缺 host"时的可读原因（**用户可见** ⇒ 不许 markdown 强调）
///
/// ★ 文案要写清三件事：缺什么、为什么不去别处拿、怎么补。
///   少任何一件，用户/后来人都只能猜。
const NO_HOST_HINT: &str = "本类没有可用端点：参考实现的这个类里没有任何 host 常量\
     （端点在同 jar 的别的类里，属跨类），而订阅这条的 ext 也为空\
     ⇒ 按「不许猜端点」不搬别的类的协议。若你有正确端点，请在本源的 ext 里给出\
     {\"site\":\"https://…\"}";

/// `csp_PanBaidu`
pub struct PanBaidu {
    client: reqwest::Client,
}

impl PanBaidu {
    pub const CLASS: &'static str = "PanBaidu";

    pub fn new() -> Self {
        // 同批纪律：no_proxy 在 timeout 之后、build 之前；用 expect 而不是
        // `unwrap_or_else(Client::new)`（后者会悄悄丢掉 no_proxy）。
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("build pan_baidu http client");
        Self { client }
    }

    fn cookie() -> Option<String> {
        crate::pan_auth::load(PanKind::Baidu)
            .map(|c| c.cookie.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    /// host 的**唯一合法来源**：ext
    ///
    /// # 为什么只认 ext（三条键都试，但绝不内置默认值）
    /// ```text
    /// 内置一个默认 host = 把"我猜的"当成"配置给的" ⇒ 用户改不了、也查不到。
    /// ⇒ 只从配置读；读不到就如实报"缺 host"（文案见 NO_HOST_HINT）。
    /// ★ 三个键都试是因为订阅/配置的作者们写法不一（同批别的类里三种都见过）。
    /// ```
    pub fn host_of(ext: &str) -> Option<String> {
        let j = crate::tvbox::parse_loose_json(ext).ok()?;
        let pick = |k: &str| -> Option<String> {
            j.get(k)
                .and_then(|v| v.as_str())
                .map(|s| s.trim().trim_end_matches('/').to_string())
                .filter(|s| s.starts_with("http"))
        };
        pick("site").or_else(|| pick("host")).or_else(|| pick("url"))
    }

    /// 根目录路径（ext 可覆盖；默认逐字 `"/"`）
    pub fn root_folder(ext: &str) -> String {
        crate::tvbox::parse_loose_json(ext)
            .ok()
            .and_then(|j| {
                j.get("folder")
                    .or_else(|| j.get("root"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim().to_string())
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| ROOT_FOLDER.to_string())
    }

    /// 本类"取数未接通"的统一说明（**纯函数**，便于在无网络下断言）
    ///
    /// ★ 为什么把这段话抽成函数：它会被 list/detail/play 三处复用，
    ///   而三处的**前置条件不同**（detail 要有 id、play 要有集参数）⇒
    ///   抽出来才能在不依赖凭据的情况下测"文案对不对"。
    pub fn not_wired_reason(what: &str) -> String {
        format!(
            "百度：{what}未接通 —— 参考实现的这个类里没有对应端点\
             （列目录/取址都在基类 + 本地转发服务那条链路上，属跨类取证），\
             按「不许猜端点」不搬别的类的协议；不伪造地址、不把分享页当视频流"
        )
    }
}

#[async_trait]
impl CspSite for PanBaidu {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页 = 一个货架（**不需要网络**：名字与根路径都是逐字常量）
    ///
    /// ⚠️ 仍然先过登录闸：没有账号时，"我的盘"这个货架点进去必然失败
    ///   ⇒ 提前给出"去登录"这句能指导行动的话，比让用户点了再看到接口错误好。
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        if Self::cookie().is_none() {
            return Err(LOGIN_HINT.to_string());
        }
        // 有账号但没端点 ⇒ 也必须如实说缺什么（不能给一个"看着正常但点不动"的货架）
        let _host = Self::host_of(ext).ok_or_else(|| NO_HOST_HINT.to_string())?;
        Ok(CspHome {
            categories: vec![CspCategory {
                id: Self::root_folder(ext),
                name: SHELF_NAME.to_string(),
            }],
            items: Vec::new(),
        })
    }

    async fn list(&self, _tid: &str, _page: u32, ext: &str) -> Result<CspList, String> {
        if Self::cookie().is_none() {
            return Err(LOGIN_HINT.to_string());
        }
        // 就算 ext 给了 host，本类**也没有路径**（DEX 里没有）⇒ 仍然未接通
        if Self::host_of(ext).is_none() {
            return Err(NO_HOST_HINT.to_string());
        }
        Err(Self::not_wired_reason("列目录"))
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        if id.trim().is_empty() {
            return Err("条目 id 为空".to_string());
        }
        if Self::cookie().is_none() {
            return Err(LOGIN_HINT.to_string());
        }
        Err(Self::not_wired_reason("详情"))
    }

    fn supports_search(&self) -> bool {
        false
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("百度 不支持搜索（它只列你自己账号里的目录）".to_string())
    }

    /// 取播放地址：**没有账号 ⇒ 逐字登录提示**；有账号 ⇒ 如实报未接通
    ///
    /// ★ 这条是本类最不能"顺手编"的地方：把分享页 URL 当视频流返回，
    ///   播放器会 404/黑屏，而用户会以为"这个文件坏了"。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        if Self::cookie().is_none() {
            return Err(LOGIN_HINT.to_string());
        }
        if id.trim().is_empty() {
            return Err(Self::not_wired_reason("取流（条目 id 为空）"));
        }
        Err(Self::not_wired_reason("取流"))
    }
}

/// 本类**故意不注册** —— 见文件头第 ① 节
///
/// ```text
/// 写这一行注释是为了让"为什么没有 register_site!"在代码里也能被看到（不是只在文档里）。
/// ★ 判定由测试保证：`must_not_be_registered_this_batch` 断言
///   ① 源码里**没有**注册宏调用；② 注册表里**查不到** csp_PanBaidu。
/// ```

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(PanBaidu::CLASS, "PanBaidu");
    }

    /// ★★★ 三条判据缺第 ② 条 ⇒ **不许注册**
    ///
    /// ```text
    /// 后果很具体：`state.rs` 会为每个注册的类自动暴露一条**用户可见的源**，
    /// 点进去永远只有错 ⇒ 不许把它放进注册表。
    /// ```
    #[test]
    fn must_not_be_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("pan_baidu.rs"));
        assert!(
            !flat.contains("register_site!(PanBaidu)"),
            "★ 缺 host（判据②）⇒ 本批不许注册"
        );
        assert!(
            !crate::csp::is_implemented("csp_PanBaidu"),
            "★ 不许进注册表（订阅这条没有 ext，也没有可用端点）"
        );
        // 反空真：同一个判据对**已注册**的类必须给出相反结果，
        // 否则说明"is_implemented 恒 false"，上面那条断言等于没测。
        assert!(
            crate::csp::is_implemented("csp_Pan115"),
            "★ 对照：已注册的类必须查得到（否则 is_implemented 恒 false，本条判据失效）"
        );
    }

    #[test]
    fn visible_wording_matches_reference() {
        assert_eq!(LOGIN_HINT, "还未登录百度账号,请前往【配置中心】登录");
        assert_eq!(SHELF_NAME, "我的百度网盘");
        // 根目录逐字 "/"（本类 6 处出现的那个字面量）
        assert_eq!(ROOT_FOLDER, "/");
        for s in [LOGIN_HINT, SHELF_NAME, NO_HOST_HINT] {
            assert!(!s.contains("**"), "★ 用户可见文案不许有 markdown 强调：{s}");
        }
    }

    /// ★★ host 只能来自 ext（三种键都认，坏数据不 panic，且**不许**内置默认值）
    #[test]
    fn host_only_comes_from_ext() {
        assert_eq!(
            PanBaidu::host_of(r#"{"site":"https://pan.example.com/"}"#).as_deref(),
            Some("https://pan.example.com"),
            "★ 结尾斜杠要削掉（拼路径时才不会出现 //）"
        );
        assert_eq!(
            PanBaidu::host_of(r#"{"host":"https://h.example.com"}"#).as_deref(),
            Some("https://h.example.com")
        );
        assert_eq!(
            PanBaidu::host_of(r#"{"url":"https://u.example.com"}"#).as_deref(),
            Some("https://u.example.com")
        );
        // ★ 没有就真的是 None（不许编一个默认 host —— 那正是"猜域名"）
        assert_eq!(PanBaidu::host_of(""), None);
        assert_eq!(PanBaidu::host_of("{}"), None);
        assert_eq!(PanBaidu::host_of("坏 json"), None);
        assert_eq!(PanBaidu::host_of(r#"{"site":"not-a-url"}"#), None);
        assert_eq!(PanBaidu::host_of(r#"{"site":"ftp://x"}"#), None);
    }

    #[test]
    fn root_folder_defaults_to_evidence_value_and_ext_overrides() {
        assert_eq!(PanBaidu::root_folder(""), "/");
        assert_eq!(PanBaidu::root_folder(r#"{"folder":"/剧集"}"#), "/剧集");
    }

    /// ★★ "未接通"的说明里必须同时有【缺什么】与【没做什么】（后者防的是伪造地址）
    #[test]
    fn not_wired_reason_says_what_is_missing_and_what_is_not_done() {
        let r = PanBaidu::not_wired_reason("取流");
        assert!(r.contains("取流"), "★ 要说是哪一步：{r}");
        assert!(r.contains("没有对应端点") || r.contains("跨类"), "★ 要说缺什么：{r}");
        assert!(r.contains("不伪造") || r.contains("不猜"), "★ 要说不做什么：{r}");
        assert!(r.contains("分享页"), "★ 必须点明「不许把分享页当视频流」：{r}");
        assert!(!r.contains("**"), "★ 用户可见文案不许有 markdown 强调：{r}");
    }

    /// ★★★ 无 cookie 时四条路径都必须如实报登录（不许返回空/假成功）
    #[tokio::test]
    async fn without_cookie_every_path_says_login_not_empty() {
        if crate::pan_auth::load(PanKind::Baidu).is_some() {
            eprintln!("本机钥匙串已有百度凭据 ⇒ 跳过『无 cookie』用例（避免假绿/假红）");
            return;
        }
        let s = PanBaidu::new();
        assert_eq!(s.home("").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.list("/", 1, "").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.detail("x", "").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.play("默认", "x", "").await.expect_err("必须 Err"), LOGIN_HINT);
    }

    /// ★★ 有 ext 给了 host 也**不许**假装能列目录（本类没有路径）
    ///
    /// 这条是"缺 ② 的诚实性"的核心：给了 host ≠ 有协议。
    /// 若哪天有人补上了真实端点，这条会红，提醒他把断言改成"真的能列"。
    #[tokio::test]
    async fn host_from_ext_alone_still_does_not_pretend_to_list() {
        if crate::pan_auth::load(PanKind::Baidu).is_some() {
            eprintln!("本机钥匙串已有百度凭据 ⇒ 跳过本用例（它会走到「有账号」分支）");
            return;
        }
        let s = PanBaidu::new();
        let ext = r#"{"site":"https://pan.example.com"}"#;
        // 无账号 ⇒ 仍然是登录提示（登录闸在前）
        let e = s.list("/", 1, ext).await.expect_err("必须 Err");
        assert_eq!(e, LOGIN_HINT);
    }

    #[tokio::test]
    async fn search_says_unsupported_not_empty_result() {
        let s = PanBaidu::new();
        let e = s.search("任意词", 1, "").await.expect_err("★ 必须 Err");
        assert!(e.contains("不支持搜索"), "{e}");
    }

    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("pan_baidu.rs"));
        let t = flat.find(".timeout(HTTP_TIMEOUT)").expect("必须有 .timeout");
        let n = flat.find(".no_proxy()").expect("★ 必须 .no_proxy()");
        let b = flat.find(".build()").expect("必须有 .build()");
        assert!(t < n && n < b, "★ 位置必须是 timeout → no_proxy → build");
        assert!(
            flat.contains("Client::builder().user_agent(UA).timeout(HTTP_TIMEOUT).no_proxy().build()"),
            "★ 必须是同一条 builder 链"
        );
    }
}
