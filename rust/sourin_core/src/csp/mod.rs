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

pub mod bili;
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
/// 形如 `csp_PanWebShare 尚未实现` —— 与配置里写的 api 逐字对应，
/// 用户能直接看出是哪个类、并且知道**不是配置坏了**。
pub fn unimplemented_reason(api: &str) -> String {
    format!("{} 尚未实现", api.trim())
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
    }

    #[test]
    fn route_misses_unimplemented_class() {
        // ★ 反向断言：没写的类必须**返回 None**，而不是给个空实现糊过去
        assert!(route("csp_PanWebShare").is_none());
        assert!(!is_implemented("csp_PanWebShare"));
        assert!(route("csp_AppDrama").is_none());
        assert!(route("csp_4KZhinan").is_none());
        // 大小写不同 = 不同的类名，不许命中
        assert!(route("csp_bili").is_none());
    }

    #[test]
    fn unimplemented_reason_quotes_api_verbatim() {
        assert_eq!(
            unimplemented_reason("csp_PanWebShare"),
            "csp_PanWebShare 尚未实现"
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
