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
/*
 * ── R3 批新增（**Lead 独占本段**）─────────────────────────────────────
 *
 * # 为什么由 Lead 独占
 * R3 批有 6 个执行者**同时**在补 csp 类（batch A/B/C + 网盘 + AppDrama/XBPQ）。
 * 每个类都要在这里加一行 `pub mod` ⇒ 若各写各的，同一时刻多人改同一段会互相覆盖。
 * ⇒ 各执行者「**先写文件 → 报 Lead → Lead 加行 → 执行者复跑**」。
 *
 * # ⚠️ 加行的时序（这条必须遵守）
 * ```text
 * `pub mod x;` 指向的**文件必须已存在**，否则 `cargo check --lib` 直接失败 ——
 * 而它会**连累所有并行执行者的读数**（他们跑什么都红，且红因不在自己身上）。
 * ⇒ 所以**先确认文件存在再加行**，不许"先把行加上占位"。
 * ```
 */
pub mod sports_kafei;
pub mod ting_bokan;
pub mod shared;
pub mod app_yqk;
pub mod jpys;
pub mod app_ly;
pub mod app_drama;
pub mod djuu;
pub mod shuang_xing;
pub mod sou4k;
pub mod yinhai;
pub mod web1905;
pub mod pan_drive;
pub mod short_haokan;
pub mod ting_shijie;
pub mod hxq;
pub mod wwys;
pub mod app_ys_v2;
pub mod douban;
pub mod app_get;
pub mod gui_gui;
pub mod app_sy;
pub mod app3q;
pub mod app_fox;
pub mod app_qi;
pub mod app_ys;
pub mod duboku;
pub mod gulu;
pub mod sao_huo;
pub mod sou_ju;
pub mod app_rj;
pub mod hd_moli;
pub mod libvio;
pub mod yun_duo;
pub mod czsapp;
pub mod provider;

/*
 * ── R4 增量批（2026-10-27 深夜，Lead 独占本段，沿用 R3 批同一条纪律）──
 * 25 个占位 `pub mod` 已先于实现接线：占位文件已存在 ⇒ cargo check 不会连累
 * 并行执行者的读数（R3 批注释里的时序规则照样成立）。
 * 三个执行者各写各的文件，互不重叠：
 *   csp-b24 = sports_feiqiu…seed_hub（11，官方 jar 有参考）
 *   csp-b25 = juhe_so…guan_ying（11，官方 jar 有参考）
 *   csp-b26 = ren_ren / djlh / all_live（3，官方 jar 没有 ⇒ Owner 授权按站点协议独立反推）
 */
pub mod sports_feiqiu;
pub mod ting_jinxia;
pub mod short_weiguan;
pub mod sports_guazi;
pub mod sports_88;
pub mod qingting_fm;
pub mod short_hema;
pub mod qu_pan_so;
pub mod mi_pan_sou;
pub mod pan_sou;
pub mod seed_hub;
pub mod juhe_so;
pub mod yidong_4k;
pub mod short_qimao;
pub mod short_xingya;
pub mod wogg;
pub mod bili_ys;
pub mod bdjmcc;
pub mod hjzhen_cai;
pub mod juying;
pub mod wn4k;
pub mod guan_ying;
pub mod ren_ren;
pub mod djlh;
pub mod all_live;
pub mod pan_share;
pub mod a_list;
pub mod pan115;
pub mod pan_xunlei;
pub mod pan_guangya;
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

    /// 这个类**真的**支持搜索吗？（必选，与 [`CspSite::search`] 同一口径）
    ///
    /// # 为什么必须手写而不是给默认值
    /// `capabilities.search` 会用它决定"要不要让 registry 把这个源纳入搜索"
    /// （`registry.rs:287` 的 `h.enabled && capabilities.search` 会直接排除 false 的源）。
    /// 如果默认给 `true`，占位 `Err` 的类也会被拉进搜索 ⇒ 假能力位；
    /// 默认给 `false`，真实现了的类会被静默排除 ⇒ 又回到"csp 源搜不到"。
    /// 所以**必选**：每个类自己表态。
    fn supports_search(&self) -> bool;

    /// 详情（含剧集）
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String>;

    /// 取流（`flag` 是线路标记，`id` 是 [`CspEpisode::id`]）
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String>;
}

// ═══════════════════════════════════════════════════════════════════════
//  注册表 + 路由
// ═══════════════════════════════════════════════════════════════════════
//
// ★★★ 2026-10-27（R3-D）：注册方式从「核心写死」改成「**类自注册**」
//
// # Owner 原话（逐字）
// ```text
// 「要插件化开发,不要耦合太严重,未来还可能兼容其他平台」
// ```
//
// # 改前有什么问题（这是本项要修的）
// ```text
// `build_registry()` 里**逐行 `m.insert(类::CLASS, || …)` 写死**：
//   · 新增一个类 = **改核心文件 + 加一行** ⇒ 69 个待补类 = 69 行写死（"耦合太严重"）
//   · 键 `&'static str` + 值 `fn()` 函数指针 = **静态表** ⇒ **外部/其他平台无法注册**
//     ⇒ "未来兼容其他平台"在旧结构下**做不成**。
// ```
//
// # 改后（判据见下）
// ```text
// 每个类在**自己的文件**里 `inventory::submit! { CspRegistration { … } }` 自注册；
// 核心只做一件事：**遍历这份注册表并检测冲突**。
// ⇒ 新增一个类**不需要改本文件的任何函数体**（只可能在 `pub mod` 列表里加一行声明；
//   若新类放在已有模块里，连那行都不用加）。
// ```
pub use inventory;

/// 一个类的**注册项** —— 类自己在文件里提交这一条
///
/// # 字段
/// ```text
/// class  去掉 `csp_` 前缀的类名，必须与 `api` 里的后半段**逐字**相同
///        （大小写敏感：DEX 里 `Bili` 与 `bili` 是两个类，猜错等于"假装实现了"）
/// make   无参构造函数（同一个类对 10 个站可以各建一个实例）
/// ```
///
/// # 为什么用「自由函数 + 结构体」而不是 trait 对象
/// ```text
/// 与改前 `Builder = fn()` 同一形状 ⇒ **零运行期抽象成本**：
/// 注册期只往静态链表里放一个结构体，取用时一次函数指针调用。
/// ```
pub struct CspRegistration {
    pub class: &'static str,
    pub make: fn() -> Arc<dyn CspSite>,
}

inventory::collect!(CspRegistration);

/// ★★ 类**自注册**的唯一入口宏 —— 在类自己的文件里写一行即可
///
/// # 用法（照抄）
/// ```rust,ignore
/// crate::csp::register_site!(Bili);      // 类名：csp_Bili ⇒ 键 "Bili"
/// ```
///
/// # 为什么做成宏而不是让每个文件手写 `inventory::submit!`
/// ```text
/// ① **统一形状**：`CspRegistration` 的字段名/构造方式只在一处定义 ⇒
///    将来给注册项加字段（如"作者""能力位"）时，改这一个宏，不必改 69 个类。
/// ② **把 `CLASS` 与注册键绑在一起**：宏里用 `$site::CLASS` **同时**当类名，
///    ⇒ "注册键"与"类自己声明的 CLASS"在结构上不可能写歪
///      （手写时很容易出现 `class: "Bili "` 这种带空格的静默错）。
/// ```
///
/// # 它展开成什么
/// ```text
/// `inventory::submit! { CspRegistration { class: <$site>::CLASS, make: || Arc::new(<$site>::new()) } }`
/// ⇒ 一个 `#[used]` + `link_section` 的链接器构造器（ELF `.text.startup` / PE `.CRT$XCU`）。
///   **编译/链接期就位，运行期零额外成本**（见 Cargo.toml 里那段依赖说明）。
/// ```
///
/// ⚠️ `$site` 必须是一个 `pub struct`，且有：
/// `pub const CLASS: &'static str` 与 `pub fn new() -> Self` ——
/// 缺任何一样都是**编译错误**（这正是我们要的：不许"注册了但构造不出来"）。
#[macro_export]
macro_rules! register_site {
    ($site:ty) => {
        $crate::csp::inventory::submit! {
            $crate::csp::CspRegistration {
                class: <$site>::CLASS,
                make: || ::std::sync::Arc::new(<$site>::new())
                    as ::std::sync::Arc<dyn $crate::csp::CspSite>,
            }
        }
    };
}
pub use register_site;

/// 从链接期注册表构建「类名 → 构造函数」，并在构建时**检测同名冲突**
///
/// # ★★ 为什么必须显式报错（验收②）
/// ```text
/// `inventory` 会把**所有**提交项都收进来 —— 包括两个模块注册了**同一个 CLASS** 的情况。
/// 若用「后写覆盖先写」的朴素做法：
///   ⇒ 用户会看到"我实现了这个类，但它没生效"（一个**静默故障**，
///     而且排查方向会被带偏：他会去查配置，而不是查重名）。
/// ⇒ 这里**必须在构建期就把它变成响亮错误**。
/// ```
///
/// # 为什么冲突时**不返回一个"少一条"的表**（而是直接报错）
/// ```text
/// 少一条 = 那个类静默掉进「尚未实现」⇒ 与上面同一个故障，只是换了个位置。
/// ```
///
/// # `Err` 的文案要求
/// ```text
/// 必须**点名那个重复的 class** —— 不然作者无法知道该改哪一个。
/// ```
pub fn build_registry_from_inventory() -> Result<BTreeMap<&'static str, Builder>, String> {
    /*
     * ⚠️ `inventory::iter::<T>` **不是**标准 `Iterator`（它是个专用类型，
     *    只保证 `IntoIterator`）⇒ 不能直接 `.map(...)`。
     *    ⇒ 用 `for` 收成 Vec 再交给纯函数（形状与 `submit!` 的收集语义无关，
     *      纯函数那边只认 `IntoIterator<Item = CspRegistration>`）。
     */
    let mut regs: Vec<CspRegistration> = Vec::new();
    for r in inventory::iter::<CspRegistration> {
        regs.push(CspRegistration {
            class: r.class,
            make: r.make,
        });
    }
    build_registry_from(regs)
}

/// 从**任意一组**注册项构建注册表（校验 + 冲突检测）
/// —— 上面的函数只是它"输入来自链接期注册表"的包装
///
/// # 为什么把它单独抽出来（而不是只留 `…_from_inventory`）
/// ```text
/// 冲突与校验这两条**必须能被门禁驱动**，而链接期注册表在一个 test binary 里
/// 是**不可追加**的（`submit!` 一旦写进任何被编译的文件，就永久生效了 ——
/// 想在测试里"临时再注册一个"就只能靠全局状态，那比不测更糟）。
/// ⇒ 把"构建"抽成接收输入的纯函数，门禁就能直接喂"两个同名项"来验它报错。
/// ★ 生产路径**走的是同一个函数**（见 `registry()` 里那次调用）⇒
///   不是"只测了个辅助函数"。
/// ```
pub fn build_registry_from(
    regs: impl IntoIterator<Item = CspRegistration>,
) -> Result<BTreeMap<&'static str, Builder>, String> {
    let mut m: BTreeMap<&'static str, Builder> = BTreeMap::new();
    let mut dupes: Vec<&'static str> = Vec::new();
    /*
     * ⚠️ 必须遍历**传进来的 `regs`** —— 我第一版这里写成了
     *    `for reg in inventory::iter::<CspRegistration>`（直接读全局链接期表）。
     *    后果：这个"纯函数"其实**完全忽略了自己的参数**，于是门禁喂进去的
     *    "两个同名类"根本没被看到，冲突检测那条用例**假红**（它读到的是全局表里的 5 个真类）。
     *    ★ 这正是"签名说有输入、实现却读全局"这一类静默错误 ——
     *      单元测试之所以能抓住它，是因为我**故意**喂了与全局表不同的输入。
     */
    for reg in regs {
        // ── 注册期校验（见文件头 Risks：不许出现"注册了但名字是空的"）──
        if reg.class.trim().is_empty() {
            return Err("csp 注册表：有一个类的 CLASS 是空串（注册项必须给出非空类名）".to_string());
        }
        // class 必须满足与配置里 api 同一套字符约束 —— 否则它**永远匹配不上**，
        // 等于一个"注册了但谁也路由不到"的静默项。
        if !reg
            .class
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            return Err(format!(
                "csp 注册表：类名 `{}` 含非法字符（只允许 [A-Za-z0-9_]）—— \
                 它永远匹配不上配置里的 api",
                reg.class
            ));
        }
        if m.insert(reg.class, reg.make).is_some() {
            dupes.push(reg.class);
        }
    }
    if !dupes.is_empty() {
        dupes.sort_unstable();
        dupes.dedup();
        return Err(format!(
            "csp 注册表：有 {} 个类名被「重复注册」：{}。\
             每个 CLASS 只能注册一次 —— 两个模块注册同一个类名时，\
             谁来生效是不确定的，所以这里显式失败而不是静默取一个。",
            dupes.len(),
            dupes.join(", ")
        ));
    }
    Ok(m)
}

/// 构造函数（无参：同一个类对 10 个站可以各建一个实例）
type Builder = fn() -> Arc<dyn CspSite>;


/// 已实现的注册表（类名 → 构造函数）—— **由类自己注册**（不再是核心写死）
///
/// 键是**去掉 `csp_` 前缀的类名**，与配置里 `api` 的后半段逐字对应：
/// ```text
/// api: "csp_Bili"  → 键 "Bili"
/// ```
/// ★ 大小写敏感：DEX 里 `Bili` 与 `bili` 是两个不同的类名，
///   这里跟着区分，猜错就等于「假装实现了」。
///
/// # ⚠️ 这里 `expect` 掉 `Err` 会不会把冲突变成静默故障？
/// ```text
/// 不会，而且这正是**故意的**：
///   · 同名冲突是**编译/链接期的代码缺陷**（两个作者撞了名字），不是运行期数据问题
///     ⇒ 需要在**开发阶段**就炸掉，而不是等某个用户的数据触发。
///   · 门禁 `zz_r3_csp_registry` 里有一条**独立**的用例直接调
///     `build_registry_from_inventory()` 并断言"注入两个同名类 ⇒ 返回 Err"，
///     ⇒ 冲突**不可能**悄悄溜过去（那个用例会红）。
///   · 若这里改成"返回一个少一条的表"，才是真正的静默故障（见上函数的注释）。
/// ```
pub fn registry() -> &'static BTreeMap<&'static str, Builder> {
    static R: once_cell::sync::Lazy<BTreeMap<&'static str, Builder>> =
        once_cell::sync::Lazy::new(|| {
            build_registry_from_inventory().unwrap_or_else(|e| panic!("{e}"))
        });
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
