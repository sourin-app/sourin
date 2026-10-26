// ═══════════════════════════════════════════════════════════════════════
//  TVBox `csp_Xxx` 路由层 —— 不嵌 JVM，用 Rust 重写
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一层在解决什么
//
// TVBox 配置里 `type: 3` + `api: "csp_Bili"` 的源，在原版 APK 里是
// **Android DEX jar 里的 Java 类**（`com.github.catvod.spider.Bili`），
// 必须塞进 Android 的 DexClassLoader 才能跑。
//
// 本仓是 Flutter + Rust（Windows/Android 同一套业务层），
// 塞 JVM 意味着：
// ```text
// · 多一个 ~30MB 的运行时
// · 只支持 Android（桌面端没有 DexClassLoader）
// · 每个类还是 Android 专属 ⇒ 跨平台复用率为 0
// ```
// ⇒ 结论：**不嵌 JVM**，把用得到的类用 Rust 重写一遍。
//
// # 与配置格式的关系
//
// **零改动**。配置里还是 `{"type":3,"api":"csp_Bili"}`，用户不用改一个字，
// 也不需要知道我们内部换成了 Rust 实现。
//
// # 三类结局（必须能区分，不能混）
//
// ```text
// ① api 是 csp_X 且 X 已注册   → 路由成功，注册成 Provider，真发 HTTP
// ② api 是 csp_X 但 X 没写     → 进 skipped，reason = "csp_X 尚未实现"
// ③ api 不是 csp_ 的 type:3    → 走原来的 skip_reason()（drpy / 需要 Java）
// ```
//
// ★ ② 的文案是**唯一来源** [`unimplemented_reason`] —— 不许各处自己拼，
//   否则同一个东西在不同界面（导入报告 / 检测更新 / 日志）文案会漂。

pub mod app99;
pub mod first_aid;
pub mod ikanbot;
pub mod bili;
pub mod pan_web_share;
pub mod zhinan;
pub mod provider;

use std::collections::BTreeMap;
use std::sync::Arc;

/// TVBox 配置里 spider 类的前缀（`csp_` + 类名）
pub const PREFIX: &str = "csp_";

/// 从 `api` 里取出**类名**（去掉 `csp_` 前缀）
///
/// ```text
/// "csp_Bili"          → Some("Bili")
/// "csp_Bili?x=1"      → Some("Bili")      ← 配置里偶尔带查询串
/// "csp_"              → None
/// "Bili"              → None             ← 没前缀不是 csp 源
/// "https://x/y"       → None
/// ```
///
/// ★ 类名只允许 `[A-Za-z0-9_]`：注册表是**精确匹配**的，
///   带斜杠/空格/中文的东西一定是配置写错了，不该猜。
pub fn class_of(api: &str) -> Option<&str> {
    let api = api.trim();
    let rest = api.strip_prefix(PREFIX)?;
    let rest = rest
        .split(|c| c == '?' || c == '&' || c == '#')
        .next()
        .unwrap_or(rest)
        .trim();
    if rest.is_empty() {
        return None;
    }
    if !rest
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_')
    {
        return None;
    }
    Some(rest)
}

/// 是不是一个 `csp_Xxx` 接口（只看前缀形态，不看有没有实现）
pub fn is_csp(api: &str) -> bool {
    class_of(api).is_some()
}

/// 「这一类我们还没写」的**唯一**文案
///
/// 形如 `csp_AppDrama 尚未实现` —— 与配置里写的 api 逐字对应，
/// 用户能直接看出是哪个类、并且知道**不是配置坏了**。
pub fn unimplemented_reason(api: &str) -> String {
    let api = api.trim();
    match unimplemented_note(api) {
        // ★ 有具体原因的类：说清"为什么还不能用"，比笼统的"尚未实现"更有用，
        //   也不会被误读成"我们还没动手"（App99 是**实现完了但服务端拒绝**）。
        Some(note) => format!("{api} 暂不可用：{note}"),
        None => format!("{api} 尚未实现"),
    }
}

/// 已知的"不是简单未实现"的具体原因（按 api 逐字匹配）
///
/// 为什么需要它：`csp_App99` 的代码已经写完并验证到"能解开真实响应"，
/// 卡在服务端拒绝第二段握手 —— 说成"尚未实现"是**不准确**的。
pub fn unimplemented_note(api: &str) -> Option<&'static str> {
    match class_of(api)? {
        // App99 已注册（浏览链路实证可用）⇒ 不再需要"暂不可用"的原因。
        // 保留这个 match 作为**机制**：将来某个类"实现了但被服务端挡住"时，往这里加一条。
        "App99" => None,
        _ => None,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  数据契约（TVBox spider 的四段接口的最小映射）
// ═══════════════════════════════════════════════════════════════════════
//
// 对应 Java 侧（catvod 的 `Spider`）：
// ```text
// homeContent(boolean filter)                                  → home()
// categoryContent(String tid, String pg, boolean, HashMap ext)  → list(tid, page, ext)
// detailContent(List<String> ids)                               → detail(id, ext)
// playerContent(String flag, String id, List<String> vip)       → play(flag, id, ext)
// ```
//
// ★ `ext` 是**原样透传**的配置文本（见 [`CspSite`] 的说明），
//   本层不解析、不改写、不补默认值。

/// 一个分类
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CspCategory {
    pub id: String,
    pub name: String,
}

/// 列表里的一个条目
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CspItem {
    /// 条目的原生 id（上游就是 bvid）
    pub id: String,
    pub title: String,
    pub cover: Option<String>,
    pub subtitle: Option<String>,
}

/// 首页结果：分类表 + 预取条目（可为空）
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CspHome {
    pub categories: Vec<CspCategory>,
    pub items: Vec<CspItem>,
}

/// 一页列表
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CspList {
    pub items: Vec<CspItem>,
    pub page: u32,
    pub page_count: Option<u32>,
    pub total: Option<u64>,
}

/// 一集
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CspEpisode {
    pub id: String,
    pub title: String,
    /// 线路名（`vod_play_from` 里的那一段；单线路源填 `"默认"`）
    ///
    /// # 为什么加在 episode 上而不是 CspDetail 上
    /// 多线路源（如 Ikanbot）的同一个"第 1 集"会在 N 条线路上各出现一次，
    /// 线路是**集的一个维度**而不是详情的一个独立集合。加在这里：
    /// ```text
    /// · CspDetail 的扁平结构不动（方案 A，最小改动）
    /// · CspSite::play(flag, …) 的 `flag` 终于有值（此前恒为空串）
    /// · UI 按 flag 分组即可
    /// ```
    pub flag: String,
}

/// 详情
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CspDetail {
    pub id: String,
    pub title: String,
    pub cover: Option<String>,
    pub description: Option<String>,
    pub episodes: Vec<CspEpisode>,
}

/// 一条可用播放线路
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CspPlay {
    pub url: String,
    /// 取流必须带的请求头（上游 CDN 认 Referer，缺了会 403）
    pub headers: Vec<(String, String)>,
    pub label: Option<String>,
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite trait —— 一个 csp 类 = 一个实现
// ═══════════════════════════════════════════════════════════════════════

/// 一个 TVBox `csp_Xxx` 类的 Rust 实现
///
/// # `ext` 的语义：**原样透传**
///
/// 配置里 `sites[].ext` 可能是字符串，也可能是对象
/// （实测 100 个站里 30 个是对象、11 个是字符串）。本层在收集时
/// 把它归一成**一段文本**（对象就紧凑序列化），原封不动交给实现：
/// ```text
/// 配置   "ext": {"site": ["https://4kzn.cc"], "n": "指南"}
/// 传进来  {"site":["https://4kzn.cc"],"n":"指南"}
/// ```
/// 实现自己决定认哪些键。**本层绝不填默认值、绝不删键** ——
/// 一填默认值，实现就分不清「配置没写」和「配置写了空」。
#[async_trait::async_trait]
pub trait CspSite: Send + Sync {
    /// 类名（= api 去掉 `csp_` 前缀，注册表键）
    fn class(&self) -> &'static str;

    /// 首页：分类表 + 可选的预取条目
    async fn home(&self, ext: &str) -> Result<CspHome, String>;

    /// 分类列表（`tid` 为 home 里给出的分类 id）
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String>;

    /// 搜索（`kw` 为关键词，`page` 从 1 起）
    ///
    /// # 为什么是**必选**方法而不是给默认实现
    /// 默认 `Err("该类未实现搜索")` 会让"新增一个类"时**静默**留下一个"不支持"，
    /// 正是本项目最忌讳的"看起来支持"。必选 ⇒ 编译器强迫每个类表态：
    /// 真做，或**手写** `Err("<类名> 不支持搜索（原因）")` —— 写的人必须想一下。
    ///
    /// 方法体由各实现负责（本文件只声明）。
    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String>;

    /// 详情（含剧集）
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String>;

    /// 取流（`flag` 是线路标记，`id` 是 [`CspEpisode::id`]）
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String>;
}

// ═══════════════════════════════════════════════════════════════════════
//  注册表 + 路由
// ═══════════════════════════════════════════════════════════════════════

/// 构造函数（无参：同一个类对 10 个站可以各建一个实例）
type Builder = fn() -> Arc<dyn CspSite>;

fn build_registry() -> BTreeMap<&'static str, Builder> {
    let mut m: BTreeMap<&'static str, Builder> = BTreeMap::new();
    // ── 已实现 ────────────────────────────────────────────────────────
    // csp_Bili：配置里覆盖 10 个源。真发 HTTP（上游公开 web 接口）。
    m.insert(bili::Bili::CLASS, || {
        Arc::new(bili::Bili::new()) as Arc<dyn CspSite>
    });
    // csp_PanWebShare：配置里覆盖 6 个源（仅次于 csp_Bili）。
    // 浏览类接口（home/list/detail）真抓站点 HTML；网盘分享的直链需要
    // 账号 + 本地转发服务 ⇒ play 如实报「需要登录」（见该文件头的能力边界）。
    // csp_App99：配置里 2 个源。AES/CBC 加密协议（取证 + 真网络都过了，见文件头）。
    // ⚠️ 已验：home（8 分类）/ list（20 条目）；未验：detail / play。
    m.insert(app99::App99::CLASS, || {
        Arc::new(app99::App99::new()) as Arc<dyn CspSite>
    });
    /*
     * csp_FirstAid：**已实现但未注册（未通电）**。
     * 2026-10-26 真网络：home/list/play 三段通了（见 .probe/firstaid-live4.log），
     * 但 detail 的标题解析仍命中页面 <style> 里的 CSS 文本 ⇒ **四段未全通**，
     * 按"未通过真网络验证不许注册"的规矩撤掉。修好后把下面三行恢复即可。
     */
    // m.insert(first_aid::FirstAid::CLASS, || { … });

    /*
     * csp_Ikanbot（爱看｜蓝光秒播）：**已注册**（四段真网络全通，2026-10-26）。
     * ```text
     * home   6 分类 / 48 条
     * list   /category/1 电影 48 条
     * detail 线路维度：普通条目 1 条；/play/1001027 → **31 条**（xlm3u8/gsm3u8/jsm3u8…）
     * play   返回 m3u8 + UA/Referer；实测该 CDN 直连 200 + #EXTM3U（真能播）
     * ```
     * 卡点历史（留档）：`/api/getResN` 曾返回 401，因为页面 `e_token` 是解扰过的 ——
     * DEX 的 `Ikanbot.get_tks`（取 videoId 末 4 位、每位 `d%3+1` 起取 8 字符）
     * 复刻后才通；那段读数是寄存器级反汇编得出的，别再"猜着重写"。
     */
    m.insert(ikanbot::Ikanbot::CLASS, || {
        Arc::new(ikanbot::Ikanbot::new()) as Arc<dyn CspSite>
    });
    m.insert(pan_web_share::PanWebShare::CLASS, || {
        Arc::new(pan_web_share::PanWebShare::new()) as Arc<dyn CspSite>
    });
    // csp_4KZhinan：配置里覆盖 2 个源（指南 / 小丑）。纯 HTML 抓取，
    // 站点从 `ext.site` 取；播放是网盘分享页（见该文件头的能力边界）。
    m.insert(zhinan::Zhinan::CLASS, || {
        Arc::new(zhinan::Zhinan::new()) as Arc<dyn CspSite>
    });
    m
}

/// 已实现的注册表（类名 → 构造函数）
///
/// 键是**去掉 `csp_` 前缀的类名**，与配置里 `api` 的后半段逐字对应：
/// ```text
/// api: "csp_Bili"  → 键 "Bili"
/// ```
/// ★ 大小写敏感：DEX 里 `Bili` 与 `bili` 是两个不同的类名，
///   这里跟着区分，猜错就等于「假装实现了」。
pub fn registry() -> &'static BTreeMap<&'static str, Builder> {
    static R: once_cell::sync::Lazy<BTreeMap<&'static str, Builder>> =
        once_cell::sync::Lazy::new(build_registry);
    &R
}

/// 已实现的类名清单（给日志/报告用，顺序稳定）
pub fn implemented_classes() -> Vec<&'static str> {
    registry().keys().copied().collect()
}

/// 这个 api 是否有 Rust 实现（不看网络，只看注册表）
pub fn is_implemented(api: &str) -> bool {
    route(api).is_some()
}

/// ★ 路由的唯一入口：配置里的 api → 一个可用的实现
///
/// 返回 `None` 表示**这一类还没写**（此时调用方必须走
/// [`unimplemented_reason`]，不许静默忽略）。
///
/// ⚠️ 这是门禁的故障注入点：把它改成恒 `None`，
///    `csp_Bili` 就会掉进「尚未实现」—— 对应单测必须立刻变红。
pub fn route(api: &str) -> Option<Arc<dyn CspSite>> {
    let class = class_of(api)?;
    registry().get(class).map(|f| f())
}

// ═══════════════════════════════════════════════════════════════════════
//  ext 归一（配置原样 → 一段文本）
// ═══════════════════════════════════════════════════════════════════════

/// 把配置里的 `ext` 归一成**透传文本**
///
/// ```text
/// 缺失 / null                      → ""                  （= 没写）
/// 字符串 "{\"site\":[...]}"        → 原样（字符串本身）
/// 对象 {"site":[...]}              → {"site":[...]}      （紧凑序列化）
/// 数字 / 布尔                      → 其文本形态（配置写错了，但别丢）
/// ```
///
/// ★ 字符串形态**不再二次解析**：TVBox 里 ext 就是一个字符串，
///   有些站写的是 JSON 文本、有些站写的是裸字符串，
///   我们一律原样交下去，由具体实现自己判断。
pub fn ext_text(v: Option<&serde_json::Value>) -> String {
    match v {
        None | Some(serde_json::Value::Null) => String::new(),
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(other) => serde_json::to_string(other).unwrap_or_default(),
    }
}


/// 取一个**当前仍未实现**的 `csp_X` 样本（只给测试用）
///
/// # 为什么不是写死一个类名
/// 第 19 项是"按覆盖面逐个实现"的滚动任务：`csp_4KZhinan` 在本轮就被另一位执行者
/// 实现了（我写死的反向断言当场变红）。写死类名的判据**会随着别人推进而失效**，
/// 而失效方式是"红"，容易被误读成回归。
/// ⇒ 候选表按"最不可能马上被实现"的顺序排，运行时取第一个仍未实现的；
///    真的全实现了 ⇒ 明确 panic 说"这个反向断言该删了或换判据"。
#[cfg(test)]
pub fn unimplemented_sample() -> &'static str {
    const CANDIDATES: &[&str] = &[
        "csp_App99",
        "csp_XBPQ",
        "csp_Wogg",
        "csp_HJZhenCai",
        "csp_DongLi",
        "csp_AppDrama",
        "csp_PanWebShare",
        "csp_4KZhinan",
    ];
    for c in CANDIDATES {
        // ★ 有 unimplemented_note 的类（如 App99）文案是"暂不可用：…"，
        //   不能拿来当"尚未实现"字面量的样本 —— 否则断言会随文案升级而假红。
        if !is_implemented(c) && unimplemented_note(c).is_none() {
            return c;
        }
    }
    panic!("所有候选项都已实现 —— 这条反向断言需要换一个新样本");
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_of_strips_prefix_and_query() {
        assert_eq!(class_of("csp_Bili"), Some("Bili"));
        assert_eq!(class_of("  csp_Bili  "), Some("Bili"));
        assert_eq!(class_of("csp_Bili?ext=1"), Some("Bili"));
        assert_eq!(class_of("csp_Bili&a=1"), Some("Bili"));
        assert_eq!(class_of("csp_Bili#frag"), Some("Bili"));
    }

    #[test]
    fn class_of_rejects_non_csp_shapes() {
        assert_eq!(class_of(""), None);
        assert_eq!(class_of("csp_"), None);
        assert_eq!(class_of("csp_  "), None);
        assert_eq!(class_of("Bili"), None);
        assert_eq!(class_of("https://api.example.com/vod"), None);
        // 类名不允许带路径/空格/中文 —— 这种 api 是配错了，不能猜
        assert_eq!(class_of("csp_Bili/x"), None);
        assert_eq!(class_of("csp_Bi li"), None);
        assert_eq!(class_of("csp_哔哩"), None);
    }

    #[test]
    fn registry_key_is_class_without_prefix() {
        // 注册表的键必须与 api 去掉前缀后**逐字相同**
        for api in ["csp_Bili", "csp_Bili?x=1"] {
            let class = class_of(api).expect("应能取出类名");
            assert!(
                registry().contains_key(class),
                "注册表缺少键 {class}（api={api}）"
            );
        }
    }

    #[test]
    fn route_hits_implemented_class() {
        let site = route("csp_Bili").expect("csp_Bili 必须能路由到实现");
        assert_eq!(site.class(), "Bili", "实现的类名必须与注册键一致");
        assert!(is_implemented("csp_Bili"));
        assert!(implemented_classes().contains(&"Bili"));
        // ★ 第 19 项第二个实现类：PanWebShare（配置里 6 个源）
        let pan = route("csp_PanWebShare").expect("csp_PanWebShare 必须能路由到实现");
        assert_eq!(pan.class(), "PanWebShare");
    }

    #[test]
    fn route_misses_unimplemented_class() {
        // ★ 反向断言：没写的类必须**返回 None**，而不是给个空实现糊过去
        let sample = unimplemented_sample();
        assert!(
            route(sample).is_none(),
            "★ {sample} 目前仍未实现，route 必须返回 None（不许给空实现糊过去）"
        );
        assert!(!is_implemented(sample));
        // 大小写不同 = 不同的类名，不许命中
        assert!(route("csp_bili").is_none());
        assert!(route("csp_panwebshare").is_none(), "类名大小写敏感");
    }

    #[test]
    fn unimplemented_reason_quotes_api_verbatim() {
        assert_eq!(
            unimplemented_reason("csp_AppDrama"),
            "csp_AppDrama 尚未实现"
        );
        assert_eq!(
            unimplemented_reason("  csp_AppDrama "),
            "csp_AppDrama 尚未实现"
        );
    }

    #[test]
    fn ext_text_passes_string_through_verbatim() {
        let v = serde_json::json!("{\"site\":[\"https://4kzn.cc\"]}");
        assert_eq!(ext_text(Some(&v)), "{\"site\":[\"https://4kzn.cc\"]}");
    }

    #[test]
    fn ext_text_serializes_object_without_losing_keys() {
        let v = serde_json::json!({"site":["https://4kzn.cc"],"n":"指南"});
        let s = ext_text(Some(&v));
        let back = crate::tvbox::parse_loose_json(&s).expect("归一后必须仍是合法 JSON");
        assert_eq!(back["n"], "指南");
        assert_eq!(back["site"][0], "https://4kzn.cc");
    }

    #[test]
    fn ext_text_absent_is_empty_not_default() {
        // 没写 ext ⇒ 空文本。**不许**填 "{}" 之类的默认值，
        // 否则实现分不清「没写」与「写了空对象」
        assert_eq!(ext_text(None), "");
        assert_eq!(ext_text(Some(&serde_json::Value::Null)), "");
    }
}
