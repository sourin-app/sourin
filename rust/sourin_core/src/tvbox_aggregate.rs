//! TVBox **聚合源**（A′ 的 Rust 半边）：把用户启用的 TVBox 子站聚成**一个条目**。
//!
//! # 它解决的问题
//! 导入一份 TVBox 配置会冒出 10~20 个条目，首页被同一批站点刷满。
//! 现在这些子站统一置 `hidden: true`（列表不展示），改由**一个** `tvbox_agg` 代表它们；
//! 子站仍在 registry 里 ⇒ `provider:native` 路由不变 ⇒ **收藏/进度/弹幕绑定零迁移**。
//!
//! # 三条硬纪律
//! ```text
//! ① 单站失败隔离：一个子站挂掉不影响整体，**失败原因要留进结果**（warnings + 日志），
//!    绝不允许"一个站超时 ⇒ 整个首页空"。
//! ② 合并去重：两个子站给同一条内容（同 title 同 native 语义）只留一条。
//! ③ hidden 只是"列表不展示"：聚合器不引入新 id，也不复制子站数据。
//! ```
//!
//! # 落盘
//! `<数据目录>/tvbox-aggregate.json`，**不塞进** `third-party-providers.json`：
//! ```json
//! { "version": 1, "enabledSiteIds": ["tvbox1"], "hiddenSiteIds": ["tvbox1"],
//!   "pan": { "shareText": "", "pwd": null } }
//! ```
//!
//! # 为什么直接 `impl MediaProvider` 而不是 `CspSite`
//! 聚合源本来就该出现在 `listProviders` 里（它是 registry 里的一条 provider）；
//! 走 `CspSite` 反而要在 `csp/mod.rs` 注册类名（那是另一个人的独占文件）。
//! 扇出所需的子 provider 通过 `Arc<Registry>` **现查**（不是快照）⇒ 注册顺序无关。

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;

use crate::model::{
    Capabilities, Category, ErrorKind, MediaDetail, MediaId, MediaItem, Page, PlayRequest,
    ProviderError, ProviderManifest, Section, SectionSource, StreamCandidate,
};
use crate::provider::{ListRequest, MediaProvider};
use crate::registry::Registry;

/// 聚合源的 provider id（**固定值**，前端据此渲染"TVBox 聚合"这一条）
pub const AGGREGATE_ID: &str = "tvbox_agg";
/// 落盘文件名
pub const FILE_NAME: &str = "tvbox-aggregate.json";
/// 单个子站的超时（隔离用：超时算这个子站失败，不影响别人）
const CHILD_TIMEOUT: Duration = Duration::from_secs(8);
/// 聚合搜索的**并发上限**（真机度量后定的：47 子站串行要 32.8s）
///
/// ```text
/// 取值依据（真机，搜「老舅」）：
///   串行           → 32.8s（240 条，条数本来就够，慢在"一个等一个"）
///   8~12 路并发    → 与 registry 搜索内核同一档位（那边实测 12 路是拐点）
/// 取 10：47 个子站里大多数 0.5~2s，10 路能把总耗时压到个位数秒级；
///        同时不至于对"同主机多子站"（同一采集站家族）瞬间打出 10 个并发请求。
/// ```
const AGG_FANOUT_LIMIT: usize = 10;
/// 上一次扇出的**失败明细**（子站 id + 原因）—— 给真机探针看"为什么只有十来个源有结果"
static LAST_FAILS: std::sync::OnceLock<Mutex<Vec<(String, String)>>> = std::sync::OnceLock::new();

fn last_fails() -> &'static Mutex<Vec<(String, String)>> {
    LAST_FAILS.get_or_init(|| Mutex::new(Vec::new()))
}

/// 上一次扇出里**失败/超时**的子站（生产不读；探针与排障用）
pub fn last_fanout_failures() -> Vec<(String, String)> {
    last_fails().lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// 上一次扇出的**峰值并发**（门禁靠它证明"真的并发"，而不是"看起来并发"）
static FANOUT_PEAK: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// 上一个测试/上一次扇出的峰值并发（暴露给门禁；生产不读）
pub fn last_fanout_peak() -> usize {
    FANOUT_PEAK.load(std::sync::atomic::Ordering::SeqCst)
}
/// 子站 native 的分隔符：`<child_id>::<原始 native>`
const SEP: &str = "::";

// ══════════════════════════════════════════════════════════════════════
//  配置（纯数据 + 纯函数：全部可离线测）
// ══════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PanConfig {
    pub share_text: String,
    pub pwd: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AggregateConfig {
    pub version: i64,
    /// ★ 2026-10-29（Owner："还要可以起备注，如果有多个聚合源 有备注就能区分了"）
    ///
    /// 聚合源在列表里显示的名字是固定的「TVBox 聚合」；用户导入了多份订阅/多个聚合时
    /// 靠这条**备注**区分（存配置、跟着配置走，不进 manifest —— manifest 是编译期常量）。
    pub note: String,
    /// ? 2026-10-29?Owner?"????????????? tvbox ???????"??
    /// **?????**?? ?? ???????????/???????
    /// ?????"??????"?`enabled_children` ?? enabled ???
    /// ???????????????????????????????????
    pub solo: bool,
    pub enabled_site_ids: Vec<String>,
    pub hidden_site_ids: Vec<String>,
    pub pan: PanConfig,
}

impl Default for AggregateConfig {
    fn default() -> Self {
        Self {
            version: 1,
            note: String::new(),
            solo: false,
            enabled_site_ids: Vec::new(),
            hidden_site_ids: Vec::new(),
            pan: PanConfig::default(),
        }
    }
}

impl AggregateConfig {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "version": self.version,
            "note": self.note,
            "solo": self.solo,
            "enabledSiteIds": self.enabled_site_ids,
            "hiddenSiteIds": self.hidden_site_ids,
            "pan": {
                "shareText": self.pan.share_text,
                "pwd": self.pan.pwd,
            },
        })
    }

    /// 从 JSON 解析（缺字段用默认值 ⇒ 旧文件/半截文件都能读）
    pub fn from_json(v: &serde_json::Value) -> Self {
        let mut out = AggregateConfig::default();
        if let Some(x) = v.get("version").and_then(|x| x.as_i64()) {
            out.version = x;
        }
        out.note = v
            .get("note")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        out.solo = v.get("solo").and_then(|x| x.as_bool()).unwrap_or(false);
        out.enabled_site_ids = str_list(v.get("enabledSiteIds"));
        out.hidden_site_ids = str_list(v.get("hiddenSiteIds"));
        if let Some(pan) = v.get("pan") {
            out.pan.share_text = pan
                .get("shareText")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            out.pan.pwd = pan
                .get("pwd")
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string());
        }
        out
    }
}

fn str_list(v: Option<&serde_json::Value>) -> Vec<String> {
    v.and_then(|x| x.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
                .collect()
        })
        .unwrap_or_default()
}

/// 读配置：文件不存在 / 解析失败 ⇒ 一律回默认值（**不报错**，首次启动就是没文件）
pub fn load(data_dir: &Path) -> AggregateConfig {
    let p = data_dir.join(FILE_NAME);
    let Ok(text) = std::fs::read_to_string(&p) else {
        return AggregateConfig::default();
    };
    match serde_json::from_str::<serde_json::Value>(&text) {
        Ok(v) => AggregateConfig::from_json(&v),
        Err(e) => {
            log::warn!("{} 解析失败（按默认值处理）：{e}", p.display());
            AggregateConfig::default()
        }
    }
}

/// 写配置（错误文案逐字给用户看）
pub fn save(data_dir: &Path, cfg: &AggregateConfig) -> Result<(), String> {
    let p = data_dir.join(FILE_NAME);
    let text = serde_json::to_string_pretty(&cfg.to_json())
        .map_err(|e| format!("写聚合配置失败：{e}"))?;
    std::fs::write(&p, text).map_err(|e| format!("写聚合配置失败：{e}"))?;
    Ok(())
}

/// 由启用集合推导被接管的子站（`hiddenSiteIds` 前端不用传）
pub fn derive_hidden(enabled: &[String]) -> Vec<String> {
    let mut v: Vec<String> = enabled.to_vec();
    v.sort();
    v.dedup();
    v
}

/// `set` 的入参（部分更新：`None` = 不动这个字段）
#[derive(Debug, Clone, Default)]
pub struct SetPatch {
    pub enabled_site_ids: Option<Vec<String>>,
    pub pan_share_text: Option<String>,
    pub pan_pwd: Option<Option<String>>,
    /// ★ 2026-10-29：备注（Owner："多个聚合源靠备注区分"）。`Some("")` = 清空
    pub note: Option<String>,
    /// ★ 2026-10-29：列表只留聚合源（测试用开关；不动子站的搜索）
    pub solo: Option<bool>,
}

/// 校验 + 合并 + 落盘（**纯逻辑可离线测**；`known` = `(id, kind)` 全量子站）
///
/// 三条错误文案逐字（契约 §4）：
/// ```text
/// 启用集合里有不认识的源：<id>
/// 这个源不是 TVBox 导入的：<id>
/// 写聚合配置失败：<io>
/// ```
pub fn apply_patch(
    data_dir: &Path,
    known: &[(String, String)],
    cur: &AggregateConfig,
    patch: &SetPatch,
) -> Result<AggregateConfig, String> {
    let mut next = cur.clone();
    if let Some(enabled) = &patch.enabled_site_ids {
        for id in enabled {
            match known.iter().find(|(k, _)| k == id) {
                None => return Err(format!("启用集合里有不认识的源：{id}")),
                Some((_, kind)) if kind != "tvbox" => {
                    return Err(format!("这个源不是 TVBox 导入的：{id}"))
                }
                Some(_) => {}
            }
        }
        // 去重但**保序**（用户勾选顺序就是展示顺序）
        let mut seen = std::collections::BTreeSet::new();
        next.enabled_site_ids = enabled.iter().filter(|x| seen.insert((*x).clone())).cloned().collect();
        next.hidden_site_ids = derive_hidden(&next.enabled_site_ids);
    }
    if let Some(t) = &patch.pan_share_text {
        next.pan.share_text = t.clone();
    }
    if let Some(p) = &patch.pan_pwd {
        next.pan.pwd = p.clone().filter(|s| !s.is_empty());
    }
    if let Some(solo) = patch.solo {
        next.solo = solo;
    }
    if let Some(n) = &patch.note {
        // 备注：trim 后最多 60 字（列表里要一行放得下；超长会撑破卡片）
        let t = n.trim();
        let clipped: String = t.chars().take(60).collect();
        next.note = clipped;
    }
    save(data_dir, &next)?;
    Ok(next)
}

/// 子站清单里"是不是已实现类"的可读原因（与导入报告同一句话）
pub fn unimplemented_reason(api: &str) -> String {
    format!("{api} 尚未实现")
}

/// 聚合条目的**渠道条区块** key（N9）
///
/// ★ 这是跨层契约：Dart 侧靠 `SectionSource::Custom { key }` **等于**这个字符串
///   来识别"这块是聚合源的渠道条"，进而调 `tvbox_agg_channels` 取清单。
///   不许改这个字面量 —— 改了 Dart 侧就退化成"custom 型直播条"
///   （`home_page.dart` 把所有 custom 区块当直播条画，空名单 ⇒ 整块零尺寸消失，
///    表现为该区块静默不见，且**不会报错**）。
pub const CHANNELS_SECTION_KEY: &str = "tvbox_agg_channels";

/// ★★ 2026-10-27（R2-B）：**兜底是否该生效** —— 三处 fail-open 共用的唯一判据
///
/// # 它解决的问题（Owner 报的真缺陷，逐字）
/// ```text
/// > 而且首页关闭了,但是搜索页面还是能搜索出来,这属于bug
/// ```
/// 本机真数据：`disabled-providers.json` 停用 **51** 条（含全部 16 个 csp 子站），
/// 但 `tvbox-aggregate.json` 的 `enabledSiteIds = []`（空）
/// ⇒ 空集合触发兜底 ⇒ **把已停用的子站照样扇出来** ⇒ 搜索经聚合源仍能搜到。
///
/// # 为什么原兜底是"适用范围过宽"而不是"有意契约"
/// ```text
/// 原注释的意图是保护「**尚未配置**」：用户导入了 100 个源、还没在聚合页勾选，
///   别让搜索/首页整个空掉。
/// 但实现上「尚未配置」与「用户主动全停用」**都表现为空集合** ⇒ 不可区分
///   ⇒ 兜底把"用户明确说不要"也一起吃掉了。
/// ```
///
/// # 判据：**用户是否已经显式表达过"我不要这些"**
/// ```text
/// 从 **registry 内存**派生（有任一 handle `enabled == false` ⇒ 用户停用过东西）：
///   有停用记录 ⇒ **不把停用源扇出来**（也不拿"集合为空"当借口退回）
///   从未停用   ⇒ 兜底（保持原意：别让首页/搜索空掉）
/// ★ 为什么不读 `disabled-providers.json`：
///   ① 内存里的 enabled **本来就是从那份文件装载的**（`state.rs` bootstrap），同一真相；
///   ② 读内存**天然热重载**（`set_enabled` 一改，下一次调用立刻看到）；
///   ③ 不必给 `Registry` 加路径字段（那会牵动 `state.rs` 构造点，超出本卡 writeScope）。
/// ★ 判据**只有这一份**：`registry` 的两处与 `enabled_children` 都走同一语义。
/// ```
///
/// ⚠️ 注意判据的**精确语义**（我第一版写错过，被自己的门禁抓出来）：
/// ```text
/// 它回答的是「**要不要走兜底这条退路**」，**不是**「停用源要不要出现」。
/// 停用源是否出现由**候选集本身**决定（`enabled_manifests()` 只含 enabled）。
/// ⇒ 两个机制**各管一件事**，叠加起来才是完整语义：
///     候选集：停用的一律不在（无论走不走兜底）
///     兜底：仅在"用户还没表达过停用"时才允许"退回 hidden 子站"
/// ```
pub fn fallback_allowed(registry: &Arc<Registry>) -> bool {
    registry
        .manifests_all_enabled()
        .unwrap_or(true)
}

/// 已启用的子 provider（现查 registry，注册顺序无关）
///
/// ★ 2026-10-27（N9）：从 `TvboxAggregate::enabled_children` 的方法体抽成
///   **自由函数**，让下面三条路径共用同一份口径，避免三处各写一遍再漂移：
///   ```text
///   ① TvboxAggregate 的各 provider 方法（home/list/search/categories）
///   ② command_channels()     渠道清单
///   ③ command_channel_home() 按渠道取数
///   ```
///   口径本身（含 fail-open 的理由）见下面 `TvboxAggregate::enabled_children`
///   的原始注释 —— 逻辑一字未改，只换了归属。
///
/// ★★ 2026-10-27（R2-B）：**两个分支都必须尊重"停用"**
/// ```text
/// 改前两处都不看 `enabled`：
///   · `registry.get(id)`（:127）**不看 enabled** ⇒ 显式勾选的停用源也能被取到
///   · 兜底分支用 `registry.manifests()`（不看 enabled）⇒ 停用源照样扇出
/// ⇒ 这就是"首页关了、搜索还能搜出来"的最后一段链路。
/// 改法：两个分支的**入口都换成 `enabled_manifests()`**（只含 enabled）。
/// ```
pub fn enabled_children(
    registry: &Arc<Registry>,
    data_dir: &Path,
) -> Vec<Arc<dyn MediaProvider>> {
    // ★ 入口就只要**已启用**的那些 ⇒ 显式勾选的停用源不会被 `registry.get` 放进来
    //   （`registry.get` 本身不看 enabled —— 那是它的既有语义，不改它）
    let enabled_ids: std::collections::HashSet<String> = registry
        .enabled_manifests()
        .into_iter()
        .map(|m| m.id)
        .collect();
    let cfg = load(data_dir);
    let picked: Vec<Arc<dyn MediaProvider>> = cfg
        .enabled_site_ids
        .iter()
        .filter(|id| enabled_ids.contains(*id))
        .filter_map(|id| registry.get(id))
        /*
         * ★ 2026-10-29 试过按 `capabilities.search` 预筛掉"不支持搜索"的子站，
         *   但真机读数证明**筛不掉**：那 17 家（直播/豆瓣/网盘/短视频）的 manifest
         *   声明的是 `search: true`，真正拒绝发生在 `search()` 里（返回 Unsupported）。
         *   ⇒ 预筛只会制造"以为干净了"的假象，还会误伤测试里的假源 ⇒ **回退**。
         *   现状保留：它们进扇出、立刻返回 Unsupported、进 fails（探针里能看见原因）。
         */
        .collect();
    if !picked.is_empty() {
        return picked;
    }
    // 空启用集合 ⇒ **兜底**：退回"仍启用的 hidden 子站"（= TVBox 导入的那批）
    //
    // ★★★ R2-B 主修（两个机制各管一件事，叠加才完整）：
    //   · 候选集已按 enabled 过滤 ⇒ **停用的一律不在**（无论走不走兜底）
    //   · 下面这个 `fallback_allowed` 只管"**要不要走兜底这条退路**"——
    //     用户已显式停用过源 ⇒ 不再拿"没勾选"当借口退回（那才是 Owner 报的 bug）
    /*
     * ★★★ 2026-10-28（Owner 现场对照原版：搜索"老舅"原版 73 条，我们 0 条）
     * ```text
     * 改前：兜底只收 `.filter(|m| m.hidden)` —— 也就是**只有 TVBox 导入的隐藏子站**。
     *       内置 csp 源（`csp-*`，不 hidden）永远进不了聚合；
     *       而你那批导入的 hidden 子站在 disabled-providers.json 里全被停用
     *       ⇒ 候选集为空 ⇒ 聚合 0 个渠道 ⇒ 搜索 0 条。
     * 原版的行为是**"全部" = 所有站都扇出**（他截图里左侧十几个源分组、73/73）。
     * ⇒ 兜底改成：**所有仍启用的 provider，除了聚合自己**。
     *   `hidden` 只该决定"要不要在源列表里露脸"，不该决定"能不能被搜到"。
     * ```
     */
    let mut all: Vec<Arc<dyn MediaProvider>> = registry
        /*
         * ★★★ 2026-10-29（Owner："75 个源，就是 tvbox 聚合源支持的那个"）
         * ```text
         * 真机读数（逐个源直测，绕过聚合）：注册 98 个源 ⇒ **50 个能搜到「老舅」**。
         * 而聚合扇出只有 47 个候选（14 出结果）—— 差在 `disabled-providers.json`
         * 里躺着我方自动化写进去的 **51 个 id**（api/bfzyapi/cj/caiji/ffzy/cctv/bilibili…），
         * 它们被 `enabled_manifests()` 整体排除。
         *
         * 试过在**这里**忽略停用（直接 `manifests()`）⇒ 扇出 98、结果 50，
         * 但把 R2-B「用户显式停用就不搜」也一起推翻了，4 个门禁立刻红。
         * ⇒ 正确做法是**修数据而不是破坏规则**：新增一次性迁移
         *   [`crate::provider_migration::restore_auto_disabled_searchable`]，
         *   把"自动化停用、且本身可搜索"的源从 disabled 列表里摘出来；
         *   这里继续只用 `enabled_manifests()`（R2-B 不变，用户手停的仍不参与）。
         * ```
         */
        .enabled_manifests()
        .into_iter()
        .filter(|m| m.id != AGGREGATE_ID)
        .filter_map(|m| registry.get(&m.id))
        .collect();
    all.sort_by(|a, b| a.manifest().id.cmp(&b.manifest().id));
    if !fallback_allowed(registry) {
        // 用户已表达过停用 ⇒ 兜底仍可"扇出**仍启用的**那些"，但**不许**因为
        // "集合是空的"就把已停用的也拉回来 —— 候选集已经保证它们不在，
        // 这里只是记一条可查日志（区分这两类意图）。
        log::debug!(
            "[tvbox_agg] 启用集合为空、且用户已显式停用过源 ⇒ 兜底只含「仍启用」的 {} 个子站",
            all.len()
        );
        return all;
    }
    if !all.is_empty() {
        log::warn!(
            "[tvbox_agg] 启用集合为空 ⇒ 兜底扇出全部 {} 个导入子站（否则 csp 源搜不到）",
            all.len()
        );
    }
    all
}

// ══════════════════════════════════════════════════════════════════════
//  聚合 Provider
// ══════════════════════════════════════════════════════════════════════

pub struct TvboxAggregate {
    registry: Arc<Registry>,
    data_dir: PathBuf,
    manifest: ProviderManifest,
    /// 最近一次扇出里失败的子站原因（`②`：失败要留进结果，不能只打日志）
    warnings: Mutex<Vec<String>>,
}

impl TvboxAggregate {
    pub fn new(registry: Arc<Registry>, data_dir: PathBuf) -> Self {
        let manifest = ProviderManifest {
            id: AGGREGATE_ID.to_string(),
            name: "TVBox 聚合".to_string(),
            version: "1.0.0".to_string(),
            kind: "tvbox".to_string(),
            description: Some(
                "把已启用的 TVBox 子站聚成一个条目（子站在列表里隐藏）".to_string(),
            ),
            icon: None,
            id_prefixes: vec![format!("{AGGREGATE_ID}{SEP}")],
            capabilities: crate::model::Capabilities {
                vod: true,
                search: true,
                ..Default::default()
            },
            hidden: false,
            cover_headers: Vec::new(),
            config: Vec::new(),
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            enabled: None,
        };
        Self {
            registry,
            data_dir,
            manifest,
            warnings: Mutex::new(Vec::new()),
        }
    }

    /// 取走（并清空）最近一次扇出的失败原因
    pub fn take_warnings(&self) -> Vec<String> {
        self.warnings.lock().map(|mut w| std::mem::take(&mut *w)).unwrap_or_default()
    }

    fn warn(&self, msg: String) {
        log::warn!("[tvbox_agg] {msg}");
        if let Ok(mut w) = self.warnings.lock() {
            w.push(msg);
        }
    }

    /// 已启用的子 provider（现查 registry，注册顺序无关）
    ///
    /// ★ 2026-10-26 修（composer-ui 真机核实发现的**产品回归**）：
    ///   `registry` 的搜索/首页轮询现在会**排除 `hidden` 子站**（A′ 去重），
    ///   而聚合源原本只扇出 `enabledSiteIds` 里的子站。两者叠起来就是：
    ///   **用户刚导入、还没在聚合页勾任何子站时**，
    ///   `enabledSiteIds` 空 ⇒ 聚合源一个子站都不扇出 ⇒ 16 个 csp 子站
    ///   既不进 registry 的搜索目标（hidden 被排除）、也不进聚合扇出
    ///   ⇒ **csp 源从"能被搜到"退化成"参与不了"**（实测：三次设不同
    ///   `enabledSiteIds` 都只有 18 个 JS 源、112 条，`tvbox_agg` 一条不出）。
    ///
    ///   修法与 `registry` 的 fail-open 同一精神：**空启用集合 ⇒ 扇出全部
    ///   `hidden` 子站**（也就是"导入过的全部"）。用户一旦在聚合页勾了子站，
    ///   就严格按勾选的来。
    ///
    /// ★ 2026-10-27（N9）：核心逻辑抽成自由函数 [`enabled_children`]，
    ///   供渠道清单/按渠道取数命令与 provider 方法共用同一份口径。
    fn enabled_children(&self) -> Vec<Arc<dyn MediaProvider>> {
        enabled_children(&self.registry, &self.data_dir)
    }

    /// 按 `child::native` 找到子 provider + 原始 native
    fn route(&self, native: &str) -> Result<(Arc<dyn MediaProvider>, String), ProviderError> {
        let (child, rest) = native.split_once(SEP).ok_or_else(|| {
            ProviderError::new(
                ErrorKind::Other,
                format!("聚合条目的 id 缺少子站前缀（应为 <子站id>{SEP}<原始id>）：{native}"),
            )
        })?;
        let p = self.registry.get(child).ok_or_else(|| {
            ProviderError::new(
                ErrorKind::Other,
                format!("找不到子站 {child}（可能已被移除或禁用）"),
            )
        })?;
        Ok((p, rest.to_string()))
    }

    fn child_id(p: &Arc<dyn MediaProvider>) -> String {
        p.manifest().id.clone()
    }

    /// ★ N9：某个渠道（子站）的首页分区块 —— 见自由函数 [`child_home_of`]
    ///
    /// 逻辑在自由函数里（命令层拿不到 `TvboxAggregate` 实例，要与它共用一份，
    /// 理由见 [`channel_home_of`] 的文档）。这里只是给 provider 方法留个入口。
    #[allow(dead_code)]
    async fn child_home(&self, p: &Arc<dyn MediaProvider>) -> Result<Vec<Section>, ProviderError> {
        child_home_of(p).await
    }

    /// ★ N9：渠道清单（子站清单）—— 见自由函数 [`channels_of`]
    ///
    /// 口径与扇出口径**同一份**（[`enabled_children`]）：用户勾了就用勾的，
    /// 没勾就兜底全部 hidden 子站。顺序即展示顺序（勾选顺序 / 兜底按 id 排序）。
    pub fn channels(&self) -> Vec<(String, String, bool)> {
        channels_of(&self.registry, &self.data_dir)
    }

    /// ★ N9：按渠道取首页分区块 —— 见自由函数 [`channel_home_of`]
    ///
    /// 判据：**只触发 `channel_id` 这一个子站的请求**（懒加载，见 `n9_channel_home_*` 门禁）。
    /// 不在渠道清单里的 id ⇒ 可读 Err（不是"越权取别的源"）。
    ///
    /// ⚠️ 与 [`channel_home_of`] 共用一份实现 ⇒ 命令层（拿不到本实例）与
    ///    provider 方法（测得到）不会漂移。测试就调这个方法。
    pub async fn channel_home(&self, channel_id: &str) -> Result<Vec<Section>, ProviderError> {
        channel_home_of(&self.registry, &self.data_dir, channel_id).await
    }

    fn wrap_item(child: &str, mut it: MediaItem) -> MediaItem {
        it.id = MediaId {
            provider: AGGREGATE_ID.to_string(),
            native: format!("{child}{SEP}{}", it.id.native),
        };
        it
    }

    /// 合并去重：**只合并"同一条"** —— 同一子站 + 同一个 `native`
    ///
    /// # ★★★ 2026-10-28（Owner 现场对照原版：搜"老舅"原版 73 条、我们 0 条）
    /// ```text
    /// 改前：key = (title, kind) ⇒ **跨源同名即合并**。
    ///   十几个子站都返回「老舅（2023）」⇒ 只剩 1 条；
    ///   而"全部"在原版里是**按源分组**逐条列的（同一个剧在 5 个源里就是 5 条）。
    ///   ⇒ 这就是"原版几十条、我们几条"的直接原因（扇出没问题，是被合并掉了）。
    /// 现在：只合并 `(provider, native)` 完全相同的重复（同一源翻页重叠才会出现），
    ///   跨源同名**一律保留** —— 分组与去重各管一件事：
    ///     分组：UI 按 id 前缀（子站）拆开（search_page 的 `splitAggregateHit`）
    ///     去重：只挡"同一条被收了两次"
    /// ```
    fn dedupe(items: Vec<MediaItem>) -> Vec<MediaItem> {
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::with_capacity(items.len());
        for it in items {
            let key = (it.id.provider.clone(), it.id.native.clone());
            if seen.insert(key) {
                out.push(it);
            }
        }
        out
    }

    async fn fanout_search(&self, kw: &str, page: u32) -> Result<Vec<MediaItem>, ProviderError> {
        let children = self.enabled_children();
        if children.is_empty() {
            return Ok(Vec::new());
        }
        let total = children.len();
        /*
         * ★★★ 2026-10-29（真机度量：搜「老舅」出 240 条，但耗时 **32.8 秒**）
         * ```text
         * 改前：逐个子站 `await`（串行）⇒ 47 个子站 × 每站 0.5~3s = 30s 量级。
         *   条数早就够了（240 ≥ 原版 75），但用户等不了 —— 原版是秒级出结果。
         * 改后：**有界并发**（[AGG_FANOUT_LIMIT] 路），与 registry 的搜索内核同一精神：
         *   · 单站失败/超时仍只记原因，不中断（硬纪律①不变）；
         *   · 结果按**子站 id 排序**再拼接 ⇒ 顺序稳定，不随完成次序抖动；
         *   · 峰值并发由 [FANOUT_PEAK] 可观测（门禁靠它证明"真的并发"）。
         * ⚠️ 不用 `join_all` 一把梭：那会等最慢的那个才返回，且没有上限。
         * ```
         */
        let sem = std::sync::Arc::new(tokio::sync::Semaphore::new(AGG_FANOUT_LIMIT));
        let live = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let peak = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut set: tokio::task::JoinSet<(String, Result<Page<MediaItem>, String>)> =
            tokio::task::JoinSet::new();
        let kw_owned = kw.to_string();
        for p in children {
            let cid = Self::child_id(&p);
            let sem = sem.clone();
            let live = live.clone();
            let peak = peak.clone();
            let kw = kw_owned.clone();
            set.spawn(async move {
                let _permit = match sem.acquire_owned().await {
                    Ok(g) => g,
                    Err(_) => {
                        return (
                            cid,
                            Err("内部错误：并发闸门已关闭".to_string()),
                        )
                    }
                };
                let now = live.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                peak.fetch_max(now, std::sync::atomic::Ordering::SeqCst);
                let r = match tokio::time::timeout(CHILD_TIMEOUT, p.search(&kw, page)).await {
                    Ok(Ok(page)) => Ok(page),
                    Ok(Err(e)) => Err(format!("{e}")),
                    Err(_) => Err(format!("超时（{}s）", CHILD_TIMEOUT.as_secs())),
                };
                live.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
                (cid, r)
            });
        }
        let mut got: Vec<(String, Page<MediaItem>)> = Vec::new();
        let mut fails: Vec<(String, String)> = Vec::new();
        while let Some(joined) = set.join_next().await {
            match joined {
                Ok((cid, Ok(page))) => got.push((cid, page)),
                Ok((cid, Err(why))) => {
                    self.warn(format!("子站 {cid} 搜索失败：{why}"));
                    fails.push((cid, why));
                }
                Err(e) => {
                    self.warn(format!("子站任务 join 失败：{e}"));
                    fails.push(("<join>".to_string(), format!("{e}")));
                }
            }
        }
        FANOUT_PEAK.store(peak.load(std::sync::atomic::Ordering::SeqCst), std::sync::atomic::Ordering::SeqCst);
        // 记下失败明细（探针/排障用；不参与业务判断）
        {
            let mut g = last_fails().lock().unwrap_or_else(|e| e.into_inner());
            g.clear();
            g.extend(fails.iter().cloned());
        }
        // 顺序稳定：按子站 id 排序后再拼接（否则"哪个源先回来"会决定列表顺序 ⇒ 每次刷新都变）
        got.sort_by(|a, b| a.0.cmp(&b.0));
        let mut all = Vec::new();
        for (cid, page) in got {
            all.extend(page.items.into_iter().map(|i| Self::wrap_item(&cid, i)));
        }
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-10-26（Owner："为什么搜不到"必须能看到）
         * ══════════════════════════════════════════════════════════════
         *
         * ```text
         * 改前：单站失败只进 `self.warn(...)`（=log::warn + 内存列表），
         *   **没有任何对用户可见的通道** ⇒ registry 把整条记成裸 `miss`，
         *   用户只看到"搜不到"，看不到"登录态不可用"这类原因。
         * ⇒ 现在分两种情形：
         *   ① **部分失败**：有结果就算成功（保持原行为），失败仍进 warn；
         *   ② **全部失败**：返回 Err ⇒ registry 的 `run_one` 会把它记成
         *      **skipped 带 reason**，其中含子站名 + 前 3 条原因。
         * 判据：只有"一个条目都没有"才算全失败 —— 只要有一条命中就不该报错。
         * ```
         */
        if all.is_empty() && fails.len() == total && total > 0 {
            let head: Vec<String> = fails
                .iter()
                .take(3)
                .map(|(cid, why)| format!("{cid}：{why}"))
                .collect();
            self.warn(format!(
                "全部 {total} 个子站都搜不到「{kw}」：{}",
                head.join("；")
            ));
            return Err(ProviderError::new(
                ErrorKind::Other,
                format!(
                    "全部 {total} 个子站都搜不到「{kw}」：{}",
                    head.join("；")
                ),
            ));
        }
        Ok(Self::dedupe(all))
    }
}

#[async_trait]
impl MediaProvider for TvboxAggregate {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    /// ★★★ 2026-10-27（N9）：**home() 收敛为单个「渠道条」区块**，不再扇出
    ///
    /// # 修的是什么（Owner 原话）
    /// > 首页的 tvbox 聚合源，本身是一个多渠道的，支持有二级横向渠道，
    /// > 不然一次性加载太多非常卡顿。
    ///
    /// ```text
    /// 改前：N 个子站 ⇒ 首页一次性返回 N 组（实测 16 子站 ⇒ 26 个分组），
    ///       且**每进一次首页就重发 N 个 home() 请求**（请求放大）。
    /// 改后：home() 只返回**一个** Section（渠道条本身），**一个子站请求都不发**：
    ///       {id:"tvbox_agg::channels", source:Custom{key:"tvbox_agg_channels"}, items:[]}
    ///       用户点开/切到某个渠道时，由 `channel_home(channel_id)` 按需取**那一个**渠道。
    /// ```
    ///
    /// # 三条不许动的契约（改了就是静默坏）
    /// ```text
    /// ① `items` 必须是**空**：渠道清单走 `tvbox_agg_channels` 命令取，
    ///    不从区块 items 里塞 —— 首页不该为了"渠道条"先把 N 个子站拉一遍。
    /// ② `source.key` 逐字 == [`CHANNELS_SECTION_KEY`]：Dart 侧靠它分流。
    ///    ⚠️ 漏了这条，`home_page.dart` 会把本区块当成**直播条**
    ///    （它按 `src.type == 'custom'` 判断），空名单 ⇒ 整块零尺寸消失，且不报错。
    /// ③ `id` 带 `tvbox_agg::` 前缀：保持"区块 id 可路由回 provider"的既有形状。
    /// ```
    async fn home(&self) -> Result<Vec<Section>, ProviderError> {
        // ★ 注意：这里**刻意不调** `self.enabled_children()` ——
        //   连子站列表都不需要，home() 是一次**零网络**的纯构造。
        //   （注入点：把下面这行换成"遍历子站并 push 它们各自的 home()" ⇒ 懒加载门禁红）
        Ok(vec![Section {
            id: format!("{AGGREGATE_ID}{SEP}channels"),
            title: "TVBox 聚合".to_string(),
            source: SectionSource::Custom {
                key: CHANNELS_SECTION_KEY.to_string(),
            },
            items: Vec::new(),
        }])
    }

    async fn categories(&self) -> Result<Vec<Category>, ProviderError> {
        let children = self.enabled_children();
        let mut out = Vec::new();
        for p in children {
            let cid = Self::child_id(&p);
            match tokio::time::timeout(CHILD_TIMEOUT, p.categories()).await {
                Ok(Ok(cats)) => {
                    for c in cats {
                        out.push(Category {
                            id: format!("{cid}{SEP}{}", c.id),
                            name: c.name,
                            children: Vec::new(),
                        });
                    }
                }
                Ok(Err(e)) => self.warn(format!("子站 {cid} 分类失败：{e}")),
                Err(_) => self.warn(format!("子站 {cid} 分类超时")),
            }
        }
        Ok(out)
    }

    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>, ProviderError> {
        let page_no = if req.page == 0 { 1 } else { req.page };
        // `category_id` 可能是 `<子站>::<原分类>`；没有前缀就当"所有子站都用这个分类"
        match req.category_id.split_once(SEP) {
            Some((cid, rest)) => {
                let p = self.registry.get(cid).ok_or_else(|| {
                    ProviderError::new(ErrorKind::Other, format!("找不到子站 {cid}"))
                })?;
                let out = p
                    .list(ListRequest {
                        category_id: rest.to_string(),
                        page: page_no,
                        filters: req.filters,
                    })
                    .await?;
                Ok(Page {
                    items: out
                        .items
                        .into_iter()
                        .map(|i| Self::wrap_item(cid, i))
                        .collect(),
                    page: out.page,
                    page_count: out.page_count,
                    total: out.total,
                })
            }
            None => {
                let children = self.enabled_children();
                let mut all = Vec::new();
                let mut max_page = 1u32;
                for p in children {
                    let cid = Self::child_id(&p);
                    match tokio::time::timeout(
                        CHILD_TIMEOUT,
                        p.list(ListRequest {
                            category_id: req.category_id.clone(),
                            page: page_no,
                            filters: req.filters.clone(),
                        }),
                    )
                    .await
                    {
                        Ok(Ok(page)) => {
                            max_page = max_page.max(page.page);
                            all.extend(page.items.into_iter().map(|i| Self::wrap_item(&cid, i)));
                        }
                        Ok(Err(e)) => self.warn(format!("子站 {cid} 列表失败：{e}")),
                        Err(_) => self.warn(format!("子站 {cid} 列表超时")),
                    }
                }
                let items = Self::dedupe(all);
                Ok(Page {
                    items,
                    page: max_page,
                    page_count: None,
                    total: None,
                })
            }
        }
    }

    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>, ProviderError> {
        let page_no = if page == 0 { 1 } else { page };
        let items = self.fanout_search(keyword, page_no).await?;
        Ok(Page {
            items,
            page: page_no,
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail, ProviderError> {
        let (child, native) = self.route(&id.native)?;
        let cid = Self::child_id(&child);
        let mut d = child
            .detail(&MediaId {
                provider: cid.clone(),
                native: native.clone(),
            })
            .await?;
        // ★ 回填聚合 id（前端记住的是聚合条目），剧集 id 也带前缀 ⇒ play 能路由
        d.id = MediaId {
            provider: AGGREGATE_ID.to_string(),
            native: format!("{cid}{SEP}{native}"),
        };
        for e in d.episodes.iter_mut() {
            if !e.id.starts_with(&format!("{cid}{SEP}")) {
                e.id = format!("{cid}{SEP}{}", e.id);
            }
        }
        Ok(d)
    }

    async fn resolve(
        &self,
        id: &MediaId,
        req: &PlayRequest,
    ) -> Result<Vec<StreamCandidate>, ProviderError> {
        let (child, native) = self.route(&id.native)?;
        let cid = Self::child_id(&child);
        /*
         * ★★★ 2026-10-29 现场（Owner："夸克的还是不能播放"）—— 真根因就是这里：
         * ```text
         * `detail()` 把**每一集的 id 也加了 `<child>::` 前缀**（见本文件 791-795 行），
         * 而 `resolve()` 只剥了 `id.native` 的前缀，**`req.episode_id` 原样透传**给子站。
         * ⇒ 子站拿到 `csp-gui-gui::https://pan.quark.cn/s/xxx`：
         *     · 它自己的 `play()` 认不出这是分享页（前缀挡着）⇒ 原样交回
         *     · 我新加的分享页兜底也认不出（`parse_share_page` 要求 host 精确匹配）
         *     ⇒ 播放器收到带前缀的"URL" ⇒ 报"格式解不了/不能播放"。
         * 真网对照：直接用同一 share_id 调 `resolve_share_play` 能拿到直链，
         *   且 CDN 在带 Cookie 时回 `video/mp4`（不带 Cookie 是 403 XML）—— 证明解析没错、是前缀断了链路。
         * ```
         * ⇒ 这里把 `episode_id` 的前缀**对称剥掉**（与 detail 加前缀成对）。
         */
        let prefix = format!("{cid}{SEP}");
        let stripped = req.episode_id.as_deref().map(|e| match e.strip_prefix(&prefix) {
            Some(rest) => rest.to_string(),
            None => e.to_string(),
        });
        let fixed = PlayRequest {
            episode_id: stripped,
            ..req.clone()
        };
        child
            .resolve(
                &MediaId {
                    provider: cid,
                    native,
                },
                &fixed,
            )
            .await
    }
}

// ══════════════════════════════════════════════════════════════════════
//  FFI 两条命令的实现（形状严格按 .probe/ffi-contract-tvbox-aggregate.md）
// ══════════════════════════════════════════════════════════════════════

/// 全部 TVBox 子站：`(id, name, api)`，来自 sidecar（`tvbox-sources.json`）
///
/// 只认 registry 里真的存在、且 `kind == "tvbox"` 的源 —— 这样"配置里有但
/// 已被删除"的残留不会出现在二级页里。
fn tvbox_sites(st: &crate::state::AppState) -> Vec<(String, String, String)> {
    let metas = crate::tvbox::load_tvbox_metas(&st.data_dir);
    let mut out: Vec<(String, String, String)> = st
        .registry
        .manifests()
        .into_iter()
        .filter(|m| m.kind == "tvbox" && m.id != AGGREGATE_ID)
        .map(|m| {
            let meta = metas.get(&m.id);
            (
                m.id.clone(),
                meta.map(|x| x.site_name.clone())
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| m.name.clone()),
                /*
                 * ★★★ 2026-10-28（Owner 图3：47 条子站全显示「appleCms / 尚未实现」）
                 * ```text
                 * 内置 csp 源（id `csp-4k-zhinan`）**没有 TVBox 导入元数据**
                 * ⇒ meta 为 None ⇒ api 空串 ⇒ 页面 kindTag=appleCms、implemented=false
                 * ⇒ 47 条全被画成"尚未实现"并灰掉（实际它们都能用）。
                 * ⇒ 元数据缺失时按 id 反查类名，得到真实 api（`csp_4KZhinan`）。
                 * ```
                 */
                meta.map(|x| x.api.clone()).filter(|a| !a.is_empty()).unwrap_or_else(|| {
                    crate::csp::class_from_builtin_id(&m.id)
                        .map(|c| format!("csp_{c}"))
                        .unwrap_or_default()
                }),
            )
        })
        .collect();
    out.sort_by(|a, b| a.1.cmp(&b.1));
    out
}

/// `tvbox_aggregate_get`
pub fn command_get(
    st: &crate::state::AppState,
) -> Result<serde_json::Value, String> {
    let cfg = load(&st.data_dir);
    Ok(build_response(st, &cfg))
}

/// 组装响应（`get` 与 `set` 共用：契约要求 set 回读一次再返回）
fn build_response(st: &crate::state::AppState, cfg: &AggregateConfig) -> serde_json::Value {
    let sites: Vec<serde_json::Value> = tvbox_sites(st)
        .into_iter()
        .map(|(id, name, api)| {
            let implemented = crate::csp::route(&api).is_some();
            serde_json::json!({
                "id": id,
                "name": name,
                "api": api,
                "kindTag": if api.starts_with("csp_") { "csp" } else { "appleCms" },
                "implemented": implemented,
                /*
                 * ★★★ 2026-10-28（Owner：「tvbox 编辑，这些都没勾选是啥意思？我看不懂」）
                 * ```text
                 * 改前：`enabled` 直接查 `enabled_site_ids`。而他的配置里这个数组是**空**的
                 * ⇒ 47 条全部"未勾选"，但实际**全都在用**（空数组 = 全部启用，见 enabled_children
                 *   的兜底语义）。⇒ 界面说"没选"，行为是"全选"，自相矛盾。
                 * ⇒ 空数组时按"全部启用"回报（与扇出/渠道条同一份判据）。
                 * ```
                 */
                "enabled": if cfg.enabled_site_ids.is_empty() {
                    true
                } else {
                    cfg.enabled_site_ids.iter().any(|x| x == &id2(&id))
                },
                // ★ 未实现类不许显示成可启用：这里给出与导入报告**同一句**原因
                "reason": if implemented { serde_json::Value::Null }
                          else { serde_json::Value::String(unimplemented_reason(&api)) },
            })
        })
        .collect();
    serde_json::json!({
        "ok": true,
        "version": cfg.version,
        "aggregateId": AGGREGATE_ID,
        // ★ 2026-10-29：备注与"只显示聚合源"开关都要回给 UI（否则开关回显不了）
        "note": cfg.note,
        "solo": cfg.solo,
        "enabledSiteIds": cfg.enabled_site_ids,
        "sites": sites,
        "pan": {
            "shareText": cfg.pan.share_text,
            "pwd": cfg.pan.pwd,
        },
    })
}

fn id2(s: &String) -> String {
    s.clone()
}

/// `tvbox_aggregate_set`（**部分更新**：只改传进来的字段）
pub fn command_set(
    st: &crate::state::AppState,
    args: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    let cur = load(&st.data_dir);
    let mut patch = SetPatch::default();
    if let Some(v) = args.get("enabledSiteIds") {
        let arr = v
            .as_array()
            .ok_or_else(|| "enabledSiteIds 必须是字符串数组".to_string())?;
        patch.enabled_site_ids = Some(
            arr.iter()
                .map(|x| {
                    x.as_str()
                        .map(|s| s.to_string())
                        .ok_or_else(|| "enabledSiteIds 里有非字符串元素".to_string())
                })
                .collect::<Result<Vec<_>, _>>()?,
        );
    }
    if let Some(pan) = args.get("pan") {
        if let Some(t) = pan.get("shareText").and_then(|x| x.as_str()) {
            patch.pan_share_text = Some(t.to_string());
        }
        if let Some(p) = pan.get("pwd") {
            // `null` 或 `""` ⇒ 清空；字符串 ⇒ 设置
            patch.pan_pwd = Some(p.as_str().filter(|s| !s.is_empty()).map(|s| s.to_string()));
        }
    }
    // ★ 2026-10-29：备注（缺省 = 不动；空串 = 清空）
    if let Some(n) = args.get("note") {
        let s = n
            .as_str()
            .ok_or_else(|| "note 必须是字符串".to_string())?;
        patch.note = Some(s.to_string());
    }
    // ★ 2026-10-29：测试用开关「列表只留聚合源」（缺省 = 不动）
    if let Some(v) = args.get("solo") {
        patch.solo = Some(
            v.as_bool()
                .ok_or_else(|| "solo 必须是布尔值".to_string())?,
        );
    }
    // 校验用的"已知源"：id + kind（非 tvbox 的要能报出专属错误）
    let known: Vec<(String, String)> = st
        .registry
        .manifests()
        .into_iter()
        .filter(|m| m.id != AGGREGATE_ID)
        .map(|m| (m.id.clone(), m.kind.clone()))
        .collect();
    let next = apply_patch(&st.data_dir, &known, &cur, &patch)?;
    Ok(build_response(st, &next))
}

// ══════════════════════════════════════════════════════════════════════
//  N9 两条命令（渠道清单 / 按渠道取数）
// ══════════════════════════════════════════════════════════════════════
//
// # FFI 接线（本批写范围不含 ffi.rs —— 那是含 NUL 的文件，归 Lead）
//
// ```rust
// // sync 段（与 tvbox_aggregate_get 同一段，ffi.rs:778 附近）：
// "tvbox_agg_channels" => with_state(|st| crate::tvbox_aggregate::command_channels(st)),
// // async 段（与 import_tvbox_config 同一段，ffi.rs:2257 附近）：
// "tvbox_agg_channel_home" => {
//     let channel_id = match a.str("channel_id") { Ok(s) => s.to_string(), Err(e) => return err_json(&e, "other") };
//     with_state_async(move |st| async move {
//         crate::tvbox_aggregate::command_channel_home(st, &channel_id).await
//     }).await
// }
// ```
//
// # 为什么 `channels` 走 sync、`channel_home` 走 async
// ```text
// channels     只读 registry + tvbox-aggregate.json，**零网络** ⇒ sync（不占工作线程）
// channel_home 要真的去子站发请求 ⇒ 必须 async（与 get_home 同一类）
// ```

/// ★ N9：单个渠道（子站）的首页分区块 —— `channel_home` 的实现体（自由函数）
///
/// ★ 这就是旧 `TvboxAggregate::home()` 扇出循环里**单个子站**那一段，
///   逻辑一字未改地搬家，只是从"被 N 个子站无条件共执行"变成
///   "只在用户真的切到这个渠道时执行一次"。
///
/// 形状契约（与旧扇出逐字一致 ⇒ 前端零改动）：
/// ```text
/// 区块 id     "{cid}::{原区块 id}"      ← list() 靠它路由回子站
/// 区块 title  "{子站名} · {原标题}"     ← 子站名为空白则退回原标题
/// source      Category{category_id:"{cid}::{原分类}"}
/// ```
pub async fn child_home_of(p: &Arc<dyn MediaProvider>) -> Result<Vec<Section>, ProviderError> {
    let cid = p.manifest().id.clone();
    /*
     * ★ 2026-10-26 修（perf-probe 复核发现的用户可见缺陷）：
     *   原来 `title: s.title` 原样用子站的标题 ⇒ 16 个子站都有「电影」「电视剧」
     *   ⇒ 首页平铺出十几个**同名区块**，用户分不清哪条来自哪个源。
     *   改成 `"{子站名} · {原标题}"`；子站名取不到时退回原标题（绝不出现" · 电影"这种残缺）。
     */
    let child_name = p.manifest().name.clone();
    let secs = tokio::time::timeout(CHILD_TIMEOUT, p.home())
        .await
        .map_err(|_| ProviderError::new(ErrorKind::Network, format!("子站 {cid} 首页超时")))??;
    let mut out = Vec::new();
    for s in secs {
        out.push(Section {
            id: format!("{cid}{SEP}{}", s.id),
            title: if child_name.trim().is_empty() {
                s.title
            } else {
                format!("{} · {}", child_name.trim(), s.title)
            },
            source: match s.source {
                SectionSource::Category { category_id } => SectionSource::Category {
                    category_id: format!("{cid}{SEP}{category_id}"),
                },
                other => other,
            },
            items: Vec::new(),
        });
    }
    Ok(out)
}

/// ★ N9：按渠道取首页分区块（自由函数版，见 [`TvboxAggregate::channel_home`]）
///
/// # 为什么在命令层用自由函数而不是 downcast provider
/// ```text
/// `Registry::get` 返回 `Arc<dyn MediaProvider>`，而 `MediaProvider` 上
/// **没有** `as_any()`/downcast（本仓刻意的：trait 只暴露契约，不暴露具体类型）。
/// 命令层只有 `st.registry` + `st.data_dir` 这两个 pub 字段，
/// 而这两样**恰好就是**判定渠道所需的全部输入 ⇒ 直接在这层做，零新架构。
/// ```
///
/// # 为什么先查"是不是本聚合器的渠道"（而不是直接 `registry.get`）
/// ```text
/// 直接 get 的话，前端传任意一个 provider id（比如某个 JS 插件）也能取到它的首页
/// —— 那不是"聚合器的渠道"，是**越权取别的源**。
/// 判据取 `enabled_children()`（= 渠道清单本身）⇒ 清单里有才有。
/// ```
pub async fn channel_home_of(
    registry: &Arc<Registry>,
    data_dir: &Path,
    channel_id: &str,
) -> Result<Vec<Section>, ProviderError> {
    let p = enabled_children(registry, data_dir)
        .into_iter()
        .find(|p| p.manifest().id == channel_id)
        .ok_or_else(|| {
            ProviderError::new(
                ErrorKind::Other,
                format!("找不到渠道 {channel_id}（可能已被移除或未启用）"),
            )
        })?;
    child_home_of(&p).await
}

/// ★ N9：渠道清单（自由函数版，见 [`TvboxAggregate::channels`]）
///
/// 口径与扇出口径**同一份**（[`enabled_children`]）：用户勾了就用勾的，
/// 没勾就兜底全部 hidden 子站。顺序即展示顺序（勾选顺序 / 兜底按 id 排序）。
pub fn channels_of(registry: &Arc<Registry>, data_dir: &Path) -> Vec<(String, String, bool)> {
    /*
     * ★★★ 2026-10-28（修我自己上一处改动的连带）：**渠道条只列用户导入的子站**
     *
     * ```text
     * 上一处把"兜底候选集"从 `.filter(hidden)` 放开成"所有启用源"——那是对的，
     * 因为 Owner 要的是搜索像原版那样**扇出所有源**（73 条 vs 我们 0 条）。
     * 但 `enabled_children` 被**两处**共用：扇出 + 这里的"渠道条"。
     * ⇒ 放开的副作用是：首页那条横向渠道条从 1 个变成 **49 个 chip**（内置源全上条）。
     *   门禁 `zz_n9_agg_channel_rail` 的 ⑥ 立刻抓到（Expected 1 / Actual 49）。
     *
     * ⇒ 分工写死在这里：
     *   · **扇出（home/list/search）**：所有启用源（原版行为）
     *   · **渠道条（channels）**  ：只列"用户导入的隐藏子站"（那是用户自己的分组概念）
     * ```
     */
    enabled_children(registry, data_dir)
        .into_iter()
        .filter(|p| p.manifest().hidden)
        .collect::<Vec<_>>()
        .into_iter()
        .map(|p| {
            let m = p.manifest();
            (m.id.clone(), m.name.clone(), m.enabled.unwrap_or(true))
        })
        .collect()
}

/// `tvbox_agg_channels`：渠道清单（**只读、零网络**）
///
/// 返回：
/// ```json
/// {"ok":true,"aggregateId":"tvbox_agg",
///  "channels":[{"id":"tvbox1","name":"某站","enabled":true}]}
/// ```
/// ★ 字段名逐字 `id`/`name`（Dart 侧已按此写）；外层是 `channels` **数组**，不是裸数组。
/// ★★★ 2026-10-29（Owner："还要可以去重"）：把**重复的子源**停用，只保留第一个
///
/// # 什么叫"重复"
/// ```text
/// 同一份订阅导两次、或两份订阅里有同一个站 ⇒ 注册表里会出现两个 id、但**同一个站**：
///   例：`csp-4kzhinan-79a914e4` 与 `csp-4kzhinan-47098b5a`（同一个 api、同一个站名）
/// 判据取 `(站名, api)`：站名是给人看的那个名字，api 是它的实现类；
///   两者都相同 = 用户眼里同一个源（点进去内容也一样）。
/// ```
///
/// # 为什么"停用"而不是"删除"
/// ```text
/// 删除不可逆（配置里那条记录就没了）；停用可以一键恢复（源列表里勾回来）。
/// 而且用户此刻的诉求是"列表别重复"，不是"把这些站从磁盘抹掉"。
/// ```
/// 去重的**纯逻辑**（给门禁穷举；`items` = `(id, 站名, api)`）
///
/// 返回 `(保留下来的 id 顺序, 判为重复的 id)`
pub fn plan_dedupe(items: &[(String, String, String)]) -> (Vec<String>, Vec<String>) {
    let mut first_of: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    let mut kept: Vec<String> = Vec::new();
    let mut dupes: Vec<String> = Vec::new();
    for (id, name, api) in items {
        let key = format!("{}|{}", name.trim(), api.trim());
        match first_of.get(&key) {
            None => {
                first_of.insert(key, id.clone());
                kept.push(id.clone());
            }
            Some(first) => {
                if id != first {
                    dupes.push(id.clone());
                }
            }
        }
    }
    (kept, dupes)
}

pub fn command_dedupe_sites(
    st: &crate::state::AppState,
) -> Result<serde_json::Value, String> {
    let metas = crate::tvbox::load_tvbox_metas(&st.data_dir);
    let items: Vec<(String, String, String)> = st
        .registry
        .manifests()
        .into_iter()
        .filter(|m| m.kind == "tvbox" && m.id != AGGREGATE_ID)
        .map(|m| {
            let api = metas
                .get(&m.id)
                .map(|x| x.api.trim().to_string())
                .unwrap_or_default();
            (m.id, m.name, api)
        })
        .collect();
    let (kept, dupes) = plan_dedupe(&items);
    if dupes.is_empty() {
        return Ok(serde_json::json!({ "duplicates": 0, "disabled": [] }));
    }
    let mut disabled = crate::commands::load_disabled(&st.data_dir);
    for id in &dupes {
        st.registry.set_enabled(id, false);
        if !disabled.contains(id) {
            disabled.push(id.clone());
        }
    }
    crate::commands::save_disabled(&st.data_dir, &disabled)?;
    log::warn!(
        "[tvbox_agg] 去重：停用 {} 个重复子源（保留 {} 个）：{:?}",
        dupes.len(),
        kept.len(),
        dupes
    );
    Ok(serde_json::json!({
        "duplicates": dupes.len(),
        "disabled": dupes,
        "kept": kept.len(),
    }))
}

pub fn command_channels(st: &crate::state::AppState) -> Result<serde_json::Value, String> {
    let channels: Vec<serde_json::Value> = channels_of(&st.registry, &st.data_dir)
        .into_iter()
        .map(|(id, name, enabled)| {
            serde_json::json!({ "id": id, "name": name, "enabled": enabled })
        })
        .collect();
    Ok(serde_json::json!({
        "ok": true,
        "aggregateId": AGGREGATE_ID,
        "channels": channels,
    }))
}

/// `tvbox_agg_channel_home`：按渠道取首页分区块（**会联网**）
///
/// 参数：`{"channel_id":"<子站 provider id>"}`
///
/// 返回：
/// ```json
/// {"ok":true,"channelId":"tvbox1","channelName":"某站","sections":[ ...Section... ]}
/// ```
/// `sections` 里的每一条就是**该渠道**的区块（id/title/source 都带子站前缀，
/// 与旧 `home()` 扇出时的形状逐字一致）⇒ 前端拿到后走既有的
/// `child::category` 前缀 list 路由，**零新代码**。
pub async fn command_channel_home(
    st: &crate::state::AppState,
    channel_id: &str,
) -> Result<serde_json::Value, String> {
    let cid = channel_id.trim();
    if cid.is_empty() {
        return Err("channel_id 不能为空".to_string());
    }
    let name = channels_of(&st.registry, &st.data_dir)
        .into_iter()
        .find(|(id, _, _)| id == cid)
        .map(|(_, n, _)| n)
        .unwrap_or_default();
    let sections = channel_home_of(&st.registry, &st.data_dir, cid)
        .await
        .map_err(|e| format!("{e}"))?;
    Ok(serde_json::json!({
        "ok": true,
        "channelId": cid,
        "channelName": name,
        "sections": sections,
    }))
}

// ══════════════════════════════════════════════════════════════════════
//  测试（全 hermetic：假子站 + 真 Registry + 临时目录）
// ══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::MediaKind;

    fn manifest(id: &str, kind: &str) -> ProviderManifest {
        ProviderManifest {
            id: id.to_string(),
            name: id.to_string(),
            version: "1".into(),
            kind: kind.to_string(),
            description: None,
            icon: None,
            id_prefixes: vec![format!("{id}:")],
            capabilities: Capabilities::default(),
            hidden: true,
            cover_headers: Vec::new(),
            config: Vec::new(),
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            enabled: None,
        }
    }

    fn item(native: &str, title: &str) -> MediaItem {
        MediaItem {
            id: MediaId {
                provider: "x".into(),
                native: native.into(),
            },
            title: title.into(),
            cover: None,
            subtitle: None,
            badges: Vec::new(),
            kind: MediaKind::Movie,
            description: None,
        }
    }

    /// 假子站：`fail_search` 时搜索报错，其余照常
    struct FakeChild {
        manifest: ProviderManifest,
        items: Vec<MediaItem>,
        fail_search: bool,
    }

    #[async_trait]
    impl MediaProvider for FakeChild {
        fn manifest(&self) -> &ProviderManifest {
            &self.manifest
        }
        async fn home(&self) -> Result<Vec<Section>, ProviderError> {
            Ok(vec![Section {
                id: "c1".into(),
                title: format!("{}-分类", self.manifest.id),
                source: SectionSource::Category {
                    category_id: "c1".into(),
                },
                items: Vec::new(),
            }])
        }
        async fn search(&self, _kw: &str, page: u32) -> Result<Page<MediaItem>, ProviderError> {
            if self.fail_search {
                return Err(ProviderError::new(ErrorKind::Network, "子站挂了"));
            }
            Ok(Page {
                items: self.items.clone(),
                page,
                page_count: None,
                total: None,
            })
        }
        async fn detail(&self, id: &MediaId) -> Result<MediaDetail, ProviderError> {
            Ok(MediaDetail {
                id: id.clone(),
                title: format!("{}@{}", self.manifest.id, id.native),
                cover: None,
                description: None,
                badges: Vec::new(),
                kind: MediaKind::Movie,
                meta: Default::default(),
                sources: Vec::new(),
                episodes: Vec::new(),
            })
        }
        async fn resolve(
            &self,
            _id: &MediaId,
            _req: &PlayRequest,
        ) -> Result<Vec<StreamCandidate>, ProviderError> {
            Ok(vec![])
        }
    }

    fn tmp_dir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("tvbox_agg_test_{tag}_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&p);
        p
    }

    /// 造一个"一个正常 + 一个必挂"的聚合器
    fn agg_with(tag: &str, children: Vec<Arc<dyn MediaProvider>>, enabled: &[&str]) -> TvboxAggregate {
        let reg = Arc::new(Registry::new());
        for c in &children {
            reg.register(c.clone());
        }
        let dir = tmp_dir(tag);
        let mut cfg = AggregateConfig::default();
        cfg.enabled_site_ids = enabled.iter().map(|s| s.to_string()).collect();
        cfg.hidden_site_ids = derive_hidden(&cfg.enabled_site_ids);
        save(&dir, &cfg).expect("写配置");
        TvboxAggregate::new(reg, dir)
    }

    /// ★ 注入点：把 `fanout_search` 里的 `match` 改成 `?`（不隔离）⇒ 本条红
    #[tokio::test]
    async fn fanout_isolates_failing_child() {
        let ok = Arc::new(FakeChild {
            manifest: manifest("tvbox1", "tvbox"),
            items: vec![item("a1", "条目A")],
            fail_search: false,
        }) as Arc<dyn MediaProvider>;
        let bad = Arc::new(FakeChild {
            manifest: manifest("tvbox2", "tvbox"),
            items: vec![],
            fail_search: true,
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("iso", vec![ok, bad], &["tvbox1", "tvbox2"]);
        let page = agg.search("兰香如故", 1).await.expect("单站挂了不许拖垮整体");
        assert_eq!(page.items.len(), 1, "好站的条目必须在");
        let w = agg.take_warnings();
        assert!(w.iter().any(|m| m.contains("tvbox2")), "失败原因要留进结果：{w:?}");
    }

    /// ★★ 全部子站都失败 ⇒ **必须返回 Err 且带子站名+原因**（Owner 可见的唯一通道）
    ///
    /// # 为什么这条是"用户能不能看到原因"的判据
    /// ```text
    /// 改前全部失败也只 `warn` ⇒ registry 记成裸 `miss`（"搜不到"，但为什么？）
    /// ⇒ 现在全部失败返回 Err ⇒ `run_one` 记成 skipped **带 reason**。
    /// 注入：把"全部失败"改回 `Ok(vec![])` ⇒ 本条红。
    /// ```
    #[tokio::test]
    async fn fanout_all_children_failed_returns_error_with_reasons() {
        let a = Arc::new(FakeChild {
            manifest: manifest("tvbox1", "tvbox"),
            items: vec![],
            fail_search: true,
        }) as Arc<dyn MediaProvider>;
        let b = Arc::new(FakeChild {
            manifest: manifest("tvbox2", "tvbox"),
            items: vec![],
            fail_search: true,
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("allfail", vec![a, b], &["tvbox1", "tvbox2"]);
        let err = agg
            .search("兰香如故", 1)
            .await
            .expect_err("★ 全部子站失败必须报错（否则用户只看到裸 miss）");
        let msg = format!("{err}");
        assert!(msg.contains("全部 2 个子站都搜不到"), "要点名数量：{msg}");
        assert!(msg.contains("tvbox1"), "要带失败子站名：{msg}");
        assert!(msg.contains("子站挂了"), "要带子站给的原因：{msg}");
        // 同时仍留一条 warn（排查用）
        let w = agg.take_warnings();
        assert!(
            w.iter().any(|m| m.contains("全部 2 个子站都搜不到")),
            "汇总也要进 warn：{w:?}"
        );
    }

    /// ★★★ `episode_id` 的前缀必须**对称剥掉**（Owner："夸克不能播放"的真根因）
    ///
    /// ```text
    /// detail() 给每集 id 加了 `<child>::`；resolve() 若不剥，子站拿到
    /// `csp-gui-gui::https://pan.quark.cn/s/xxx` ⇒ 认不出分享页 ⇒ 播放器拿到的不是媒体流。
    /// 注入验证：把 `strip_prefix` 那三行删掉 ⇒ 本条 FAILED（记录到的还是带前缀的串）。
    /// ```
    #[tokio::test]
    async fn resolve_strips_child_prefix_from_episode_id() {
        struct RecChild {
            manifest: ProviderManifest,
            seen: Arc<Mutex<Vec<String>>>,
        }
        #[async_trait]
        impl MediaProvider for RecChild {
            fn manifest(&self) -> &ProviderManifest {
                &self.manifest
            }
            async fn home(&self) -> Result<Vec<Section>, ProviderError> {
                Ok(vec![])
            }
            async fn categories(&self) -> Result<Vec<Category>, ProviderError> {
                Ok(vec![])
            }
            async fn list(&self, _req: ListRequest) -> Result<Page<MediaItem>, ProviderError> {
                Ok(Page { items: vec![], page: 1, page_count: None, total: None })
            }
            async fn search(&self, _kw: &str, _page: u32) -> Result<Page<MediaItem>, ProviderError> {
                Ok(Page { items: vec![], page: 1, page_count: None, total: None })
            }
            async fn detail(&self, _id: &MediaId) -> Result<MediaDetail, ProviderError> {
                Ok(MediaDetail {
                    id: MediaId { provider: self.manifest.id.clone(), native: "n".into() },
                    title: "t".into(),
                    kind: MediaKind::Movie,
                    cover: None,
                    description: None,
                    badges: Vec::new(),
                    meta: Default::default(),
                    sources: Vec::new(),
                    episodes: Vec::new(),
                })
            }
            async fn resolve(
                &self,
                _id: &MediaId,
                req: &PlayRequest,
            ) -> Result<Vec<StreamCandidate>, ProviderError> {
                self.seen.lock().unwrap().push(req.episode_id.clone().unwrap_or_default());
                Ok(vec![])
            }
        }

        let seen = Arc::new(Mutex::new(Vec::new()));
        let child: Arc<dyn MediaProvider> = Arc::new(RecChild {
            manifest: manifest("csp-gui-gui", "csp"),
            seen: seen.clone(),
        });
        let agg = agg_with("prefix", vec![child], &["csp-gui-gui"]);
        let id = MediaId {
            provider: AGGREGATE_ID.to_string(),
            native: format!("csp-gui-gui{SEP}n"),
        };
        let req = PlayRequest {
            source_code: None,
            episode_id: Some(format!(
                "csp-gui-gui{SEP}https://pan.quark.cn/s/09350e7add7c"
            )),
            quality: None,
            flag: Some("网盘分享页".into()),
        };
        agg.resolve(&id, &req).await.expect("resolve 应成功");
        let got = seen.lock().unwrap().clone();
        assert_eq!(
            got,
            vec!["https://pan.quark.cn/s/09350e7add7c".to_string()],
            "★★★ 子站必须收到**裸 URL**（带前缀就认不出分享页 ⇒ 不能播放）"
        );
    }

    /// ★★★ 去重命令必须**真的接到 FFI 上**（只写函数没人调 = 没做）
    ///
    /// ```text
    /// 本仓既有先例：`pan_drive` 用 include_str! 守"命令名与调用点都在"。
    /// 注入验证：删掉 ffi.rs 里那条 arm ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn dedupe_command_is_wired_in_ffi() {
        let ffi = include_str!("ffi.rs");
        assert!(
            ffi.contains("\"tvbox_aggregate_dedupe_sites\""),
            "★ 命令名必须逐字存在（Dart 侧 `SourinApi.tvboxAggregateDedupeSites` 靠它）"
        );
        assert!(
            ffi.contains("command_dedupe_sites"),
            "★ 必须真的调到实现，不许是空分支"
        );
        // 备注/开关要在响应里回给 UI（否则弹窗回显不了）—— 由下面的序列化断言守
        let cfg = AggregateConfig {
            note: "n".into(),
            solo: true,
            ..Default::default()
        };
        let j = cfg.to_json();
        assert_eq!(j.get("note").and_then(|v| v.as_str()), Some("n"));
        assert_eq!(j.get("solo").and_then(|v| v.as_bool()), Some(true));
    }

    /// ★★★ 测试用开关 solo：存得住、读得回、默认关
    ///
    /// ```text
    /// 语义（写在 `commands::list_providers` 里）：solo=true 时**列表**只留聚合源，
    /// 子站的搜索/扇出**照旧** —— 因为 Owner 要的是"列表干净"，不是"把子站关掉"
    /// （真关掉会让 `enabled_children` 变空 ⇒ 剩下一个空聚合源）。
    /// 注入验证：把 `next.solo = solo` 删掉 ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn solo_flag_roundtrips_and_defaults_off() {
        let dir = std::env::temp_dir().join(format!("agg-solo-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(!AggregateConfig::default().solo, "★ 默认必须是关（不许偷偷只剩一个源）");
        let cur = AggregateConfig::default();
        let on = apply_patch(
            &dir,
            &[],
            &cur,
            &SetPatch {
                solo: Some(true),
                ..Default::default()
            },
        )
        .expect("开 solo 应成功");
        assert!(on.solo);
        assert!(load(&dir).solo, "★★ 必须落盘");
        assert_eq!(
            load(&dir).to_json().get("solo").and_then(|v| v.as_bool()),
            Some(true),
            "★★ FFI 响应要带 solo（UI 开关靠它回显）"
        );
        let off = apply_patch(
            &dir,
            &[],
            &on,
            &SetPatch {
                solo: Some(false),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(!off.solo, "★ 关掉要能恢复");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★★★ 备注：存得住、读得回、超长要截断（Owner："多个聚合源靠备注区分"）
    ///
    /// ```text
    /// 注入验证：把 `next.note = clipped` 改成 `next.note = String::new()` ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn note_roundtrips_and_clips() {
        let dir = std::env::temp_dir().join(format!("agg-note-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let cur = AggregateConfig::default();
        let p = SetPatch {
            note: Some("  家里那份订阅 · 2026 秋  ".to_string()),
            ..Default::default()
        };
        let next = apply_patch(&dir, &[], &cur, &p).expect("保存备注应成功");
        assert_eq!(next.note, "家里那份订阅 · 2026 秋", "★ 前后空白要 trim");
        let back = load(&dir);
        assert_eq!(back.note, next.note, "★★ 必须能从磁盘读回");
        assert_eq!(
            back.to_json().get("note").and_then(|v| v.as_str()),
            Some("家里那份订阅 · 2026 秋"),
            "★★ FFI 响应里也要带上 note（UI 要显示）"
        );
        // 超长截断到 60 字
        let long = "备".repeat(80);
        let p2 = SetPatch {
            note: Some(long),
            ..Default::default()
        };
        let n2 = apply_patch(&dir, &[], &back, &p2).unwrap();
        assert_eq!(n2.note.chars().count(), 60, "★ 备注最多 60 字（卡片要一行放得下）");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★★★ 子源去重：同名 + 同 api 才算重复；第一个必须保留；不同 api 不许误删
    ///
    /// ```text
    /// 真机依据：`csp-4kzhinan-79a914e4` 与 `csp-4kzhinan-47098b5a` 是同一个站（同 api 同站名），
    /// 用户在子源列表里看到两行一样的东西。
    /// 注入验证：把 key 改成只按 `name` ⇒ 第三条断言 FAILED（不同 api 会被误判重复）。
    /// ```
    #[test]
    fn dedupe_keeps_first_and_respects_api() {
        let items = vec![
            ("a1".to_string(), "指南".to_string(), "csp_4KZhinan".to_string()),
            ("a2".to_string(), "指南".to_string(), "csp_4KZhinan".to_string()),
            ("b1".to_string(), "指南".to_string(), "csp_PanShare".to_string()),
            ("c1".to_string(), "玩耦".to_string(), "csp_Wogg".to_string()),
        ];
        let (kept, dupes) = plan_dedupe(&items);
        assert_eq!(kept, vec!["a1".to_string(), "b1".to_string(), "c1".to_string()]);
        assert_eq!(dupes, vec!["a2".to_string()], "★ 只有 a2 是同名同 api 的重复项");
    }

    /// ★★★ 扇出必须**真的并发**（真机：47 子站串行 32.8s；原版是秒级）
    ///
    /// ```text
    /// 判据：`last_fanout_peak()` —— 上一次扇出的**峰值并发**。
    ///   串行实现恒为 1；有界并发应 > 1 且 ≤ AGG_FANOUT_LIMIT。
    /// 为什么不用"耗时断言"：CI 上时间抖动大，容易假红/假绿；峰值并发是确定性判据。
    /// 注入验证：把 AGG_FANOUT_LIMIT 改成 1 ⇒ 本条 FAILED（峰值=1）。
    /// ```
    #[tokio::test]
    async fn fanout_runs_concurrently_within_the_limit() {
        struct SlowChild {
            manifest: ProviderManifest,
            delay_ms: u64,
        }
        #[async_trait]
        impl MediaProvider for SlowChild {
            fn manifest(&self) -> &ProviderManifest {
                &self.manifest
            }
            async fn home(&self) -> Result<Vec<Section>, ProviderError> {
                Ok(vec![])
            }
            async fn categories(&self) -> Result<Vec<Category>, ProviderError> {
                Ok(vec![])
            }
            async fn list(&self, _req: ListRequest) -> Result<Page<MediaItem>, ProviderError> {
                Ok(Page {
                    items: vec![],
                    page: 1,
                    page_count: None,
                    total: None,
                })
            }
            async fn search(&self, _kw: &str, _page: u32) -> Result<Page<MediaItem>, ProviderError> {
                tokio::time::sleep(Duration::from_millis(self.delay_ms)).await;
                Ok(Page {
                    items: vec![item(&self.manifest.id, "同一部剧")],
                    page: 1,
                    page_count: None,
                    total: None,
                })
            }
            async fn detail(&self, id: &MediaId) -> Result<MediaDetail, ProviderError> {
                Err(ProviderError::new(ErrorKind::NotFound, format!("{:?}", id)))
            }
            async fn resolve(
                &self,
                _id: &MediaId,
                _req: &PlayRequest,
            ) -> Result<Vec<StreamCandidate>, ProviderError> {
                Ok(vec![])
            }
        }

        let mut children: Vec<Arc<dyn MediaProvider>> = Vec::new();
        let mut ids: Vec<String> = Vec::new();
        for i in 0..8 {
            let id = format!("slow{i}");
            ids.push(id.clone());
            children.push(Arc::new(SlowChild {
                manifest: manifest(&id, "tvbox"),
                delay_ms: 60,
            }) as Arc<dyn MediaProvider>);
        }
        let refs: Vec<&str> = ids.iter().map(|s| s.as_str()).collect();
        let agg = agg_with("concurrency", children, &refs);
        let page = agg.search("x", 1).await.expect("应成功");
        assert_eq!(page.items.len(), 8, "★ 并发不许丢结果（8 个子站各 1 条）");
        let peak = last_fanout_peak();
        assert!(peak > 1, "★★ 串行实现（峰值=1）会让 47 子站搜索 30 秒以上：peak={peak}");
        assert!(
            peak <= AGG_FANOUT_LIMIT,
            "★★ 峰值并发不许超过上限 {AGG_FANOUT_LIMIT}：peak={peak}"
        );
        // ★ 顺序稳定：结果按子站 id 排序拼接（否则"谁先回来"决定顺序，每次刷新都变）
        let order: Vec<String> = page
            .items
            .iter()
            .map(|i| {
                i.id.native
                    .split_once(SEP)
                    .map(|(c, _)| c.to_string())
                    .unwrap_or_default()
            })
            .collect();
        let mut sorted = order.clone();
        sorted.sort();
        assert_eq!(order, sorted, "★★ 结果顺序必须与完成次序无关：{order:?}");
    }

    /// ★★★ 跨源同名**不许合并**（原版"全部"就是按源逐条列 —— 几十条的来源）
    ///
    /// ```text
    /// 注入验证：把 `dedupe` 的 key 改回 `(title, kind)` ⇒ 本条 FAILED（只剩 1 条）。
    /// 这是 Owner 那条"搜老舅原版 73 条、我们 0 条"的直接判据。
    /// ```
    #[tokio::test]
    async fn fanout_keeps_same_title_from_different_sources() {
        let a = Arc::new(FakeChild {
            manifest: manifest("tvbox1", "tvbox"),
            items: vec![item("same", "同一部剧")],
            fail_search: false,
        }) as Arc<dyn MediaProvider>;
        let b = Arc::new(FakeChild {
            manifest: manifest("tvbox2", "tvbox"),
            items: vec![item("same2", "同一部剧")],
            fail_search: false,
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("dedupe-cross", vec![a, b], &["tvbox1", "tvbox2"]);
        let page = agg.search("x", 1).await.expect("应成功");
        assert_eq!(
            page.items.len(),
            2,
            "★★ 两个子站各有一条 ⇒ 必须都留着（原版按源分组就是两条）：{:?}",
            page.items.iter().map(|i| &i.title).collect::<Vec<_>>()
        );
        let mut children: Vec<String> = page
            .items
            .iter()
            .map(|i| {
                i.id.native
                    .split_once(SEP)
                    .map(|(c, _)| c.to_string())
                    .unwrap_or_default()
            })
            .collect();
        children.sort();
        assert_eq!(children, vec!["tvbox1".to_string(), "tvbox2".to_string()],
            "★ 两条必须分属两个子站（UI 靠这个前缀分组）");
    }

    /// ★ 同一子站把同一条内容返回两次（翻页重叠）⇒ 仍只留一条
    ///
    /// ```text
    /// 去重不能整个删掉：`_page` 重叠时同一 native 会被收两次，
    /// 那会在列表里出现两个一模一样的卡片（用户点了两次同一条）。
    /// 注入验证：把 `dedupe` 改成 `return items` ⇒ 本条 FAILED。
    /// ```
    #[tokio::test]
    async fn fanout_dedupes_exact_same_item() {
        let a = Arc::new(FakeChild {
            manifest: manifest("tvbox1", "tvbox"),
            items: vec![item("same", "同一部剧"), item("same", "同一部剧")],
            fail_search: false,
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("dedupe-exact", vec![a], &["tvbox1"]);
        let page = agg.search("x", 1).await.expect("应成功");
        assert_eq!(page.items.len(), 1, "同一条被收两次 ⇒ 只留一条");
    }

    /// ★ 注入点：`route()` 里把 `split_once` 改成"整段当子站 id" ⇒ 本条红
    #[tokio::test]
    async fn detail_routes_to_child_by_prefix() {
        let a = Arc::new(FakeChild {
            manifest: manifest("tvbox1", "tvbox"),
            items: vec![],
            fail_search: false,
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("route", vec![a], &["tvbox1"]);
        let d = agg
            .detail(&MediaId {
                provider: AGGREGATE_ID.into(),
                native: "tvbox1::abc123".into(),
            })
            .await
            .expect("应能路由到子站");
        assert_eq!(d.title, "tvbox1@abc123", "子站要收到**去掉前缀**的 native");
        assert_eq!(d.id.provider, AGGREGATE_ID);
        assert_eq!(d.id.native, "tvbox1::abc123");
    }

    /// 没有前缀 ⇒ 可读 Err（不猜）
    #[tokio::test]
    async fn detail_without_prefix_errors() {
        let agg = agg_with("noprefix", vec![], &[]);
        let e = agg
            .detail(&MediaId {
                provider: AGGREGATE_ID.into(),
                native: "abc123".into(),
            })
            .await
            .expect_err("必须 Err");
        assert!(format!("{e}").contains("缺少子站前缀"), "{e}");
    }

    /// ★ 注入点：`apply_patch` 里静默丢弃非法 id ⇒ 本条红
    #[test]
    fn set_rejects_unknown_id_with_exact_message() {
        let dir = tmp_dir("reject");
        let cur = AggregateConfig::default();
        let known = vec![("tvbox1".to_string(), "tvbox".to_string())];
        let e = apply_patch(
            &dir,
            &known,
            &cur,
            &SetPatch {
                enabled_site_ids: Some(vec!["tvbox1".into(), "不存在".into()]),
                ..Default::default()
            },
        )
        .expect_err("非法 id 必须报错");
        assert_eq!(e, "启用集合里有不认识的源：不存在", "文案要逐字");
        // 非 tvbox 的源
        let known2 = vec![("plug1".to_string(), "plugin".to_string())];
        let e2 = apply_patch(
            &dir,
            &known2,
            &cur,
            &SetPatch {
                enabled_site_ids: Some(vec!["plug1".into()]),
                ..Default::default()
            },
        )
        .expect_err("非 TVBox 源必须报错");
        assert_eq!(e2, "这个源不是 TVBox 导入的：plug1");
    }

    /// ★ 注入点：`derive_hidden` 恒返回空 ⇒ 本条红
    #[test]
    fn set_writes_derived_hidden_ids() {
        let dir = tmp_dir("hidden");
        let cur = AggregateConfig::default();
        let known = vec![
            ("tvbox1".to_string(), "tvbox".to_string()),
            ("tvbox2".to_string(), "tvbox".to_string()),
        ];
        let next = apply_patch(
            &dir,
            &known,
            &cur,
            &SetPatch {
                enabled_site_ids: Some(vec!["tvbox2".into(), "tvbox1".into()]),
                ..Default::default()
            },
        )
        .expect("应成功");
        assert_eq!(next.enabled_site_ids, vec!["tvbox2", "tvbox1"], "保序");
        assert_eq!(next.hidden_site_ids, vec!["tvbox1", "tvbox2"], "自动推导+排序");
        // 落盘后读回要一致
        let back = load(&dir);
        assert_eq!(back.hidden_site_ids, vec!["tvbox1", "tvbox2"]);
        assert_eq!(back.version, 1);
    }

    /// 轮转读：旧文件/半截文件都要能读（serde 兼容）
    #[test]
    fn load_tolerates_missing_and_partial() {
        let dir = tmp_dir("partial");
        assert_eq!(load(&dir), AggregateConfig::default(), "没文件 ⇒ 默认值");
        std::fs::write(dir.join(FILE_NAME), "{}").unwrap();
        let c = load(&dir);
        assert_eq!(c.version, 1);
        assert!(c.enabled_site_ids.is_empty());
        std::fs::write(dir.join(FILE_NAME), "这不是 json").unwrap();
        assert_eq!(load(&dir), AggregateConfig::default(), "坏文件 ⇒ 默认值，不 panic");
    }

    /// 最小假子站：只实现了 `home()`，且**标题写死**（不看 id）——
    /// 专给"两个子站同名分类"用：`FakeChild` 的标题带 id，天然可区分，测不出本缺陷。
    struct SameTitleChild {
        manifest: ProviderManifest,
    }

    #[async_trait]
    impl MediaProvider for SameTitleChild {
        fn manifest(&self) -> &ProviderManifest {
            &self.manifest
        }
        async fn home(&self) -> Result<Vec<Section>, ProviderError> {
            Ok(vec![Section {
                id: "cat_movie".into(),
                title: "电影".into(),
                source: SectionSource::Category {
                    category_id: "cat_movie".into(),
                },
                items: Vec::new(),
            }])
        }
        async fn search(&self, _kw: &str, page: u32) -> Result<Page<MediaItem>, ProviderError> {
            Ok(Page {
                items: Vec::new(),
                page,
                page_count: None,
                total: None,
            })
        }
        async fn detail(&self, id: &MediaId) -> Result<MediaDetail, ProviderError> {
            Ok(MediaDetail {
                id: id.clone(),
                title: String::new(),
                cover: None,
                description: None,
                badges: Vec::new(),
                kind: MediaKind::Movie,
                meta: Default::default(),
                sources: Vec::new(),
                episodes: Vec::new(),
            })
        }
        async fn resolve(
            &self,
            _id: &MediaId,
            _req: &PlayRequest,
        ) -> Result<Vec<StreamCandidate>, ProviderError> {
            Ok(vec![])
        }
    }

    /// ★ A4 门禁（总计划第 19 项）：两个子站有**同名分类** ⇒ 渠道内的区块标题必须能区分子站
    ///
    /// # ★★ 2026-10-27（N9）**判据重定位**（不是删掉，是换对象）
    /// ```text
    /// 旧版：断言 `agg.home()` 出 2 个区块（每个子站一个）+ 标题可区分。
    /// ⇒ N9 收敛后 home() **只出 1 个渠道条区块**，旧断言必然红 ——
    ///   但红的原因是"判据对象过时"，不是"缺陷回归"。
    /// ⇒ 本条改为断言 `channel_home("tvbox1")` 出的区块标题带子站名，
    ///   与 `channel_home("tvbox2")` 出的**同名分类**标题可区分。
    ///   缺陷（`title: s.title` 原样用子站标题）在新对象上**仍然能被抓到**：
    ///   两条 channel_home 的标题都会退化成裸「电影」。
    /// ```
    /// 注入：把 `child_home_of` 里的 title 改回 `s.title` ⇒ 本条红。
    #[tokio::test]
    async fn home_titles_distinguish_same_named_sections_across_children() {
        let a = Arc::new(SameTitleChild {
            manifest: manifest("tvbox1", "tvbox"),
        }) as Arc<dyn MediaProvider>;
        let b = Arc::new(SameTitleChild {
            manifest: manifest("tvbox2", "tvbox"),
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("aggtitle", vec![a, b], &["tvbox1", "tvbox2"]);

        let s1 = agg.channel_home("tvbox1").await.expect("渠道①应成功");
        let s2 = agg.channel_home("tvbox2").await.expect("渠道②应成功");
        assert_eq!(s1.len(), 1, "渠道①只出它自己的区块");
        assert_eq!(s2.len(), 1, "渠道②只出它自己的区块");

        // ① 标题可区分（本门禁的核心）
        assert_ne!(s1[0].title, s2[0].title, "同名分类的区块标题必须可区分：{:?} vs {:?}", s1[0].title, s2[0].title);

        // ② 标题里要能看到各自的子站名 + 原标题
        assert!(
            s1[0].title.contains("tvbox1") && s1[0].title.contains("电影"),
            "渠道①要带子站名 tvbox1 和原标题「电影」：{}",
            s1[0].title
        );
        assert!(
            s2[0].title.contains("tvbox2") && s2[0].title.contains("电影"),
            "渠道②要带子站名 tvbox2 和原标题「电影」：{}",
            s2[0].title
        );

        // ③ 反向断言（路由契约不被牵动）：区块 id / source 仍带子站前缀
        assert!(s1[0].id.starts_with("tvbox1::"), "{}", s1[0].id);
        assert!(s2[0].id.starts_with("tvbox2::"), "{}", s2[0].id);
        match &s1[0].source {
            SectionSource::Category { category_id } => {
                assert_eq!(category_id, "tvbox1::cat_movie", "分类也要带前缀才能路由回去")
            }
            other => panic!("渠道区块的 source 应是 Category：{other:?}"),
        }

        // ④ 反向断言（防御"前缀残缺"回归）：子站名为空白时必须退回原标题，不许出现" · 电影"
        let blank = Arc::new(SameTitleChild {
            manifest: {
                let mut m = manifest("tvbox9", "tvbox");
                m.name = "   ".into();
                m
            },
        }) as Arc<dyn MediaProvider>;
        let agg9 = agg_with("aggtitle9", vec![blank], &["tvbox9"]);
        let secs9 = agg9.channel_home("tvbox9").await.expect("应成功");
        assert_eq!(secs9[0].title, "电影", "子站名取不到 ⇒ 退回原标题（不许残缺前缀）");
    }

    // ══════════════════════════════════════════════════════════════════
    //  N9 门禁：home() 收敛 + 渠道清单 + **按渠道懒加载**（请求计数）
    // ══════════════════════════════════════════════════════════════════

    /// 计数型假子站：`home()` 每被调用一次就 +1
    ///
    /// ★ 为什么必须有它：N9 的判据不是"命令存在"，而是
    ///   **"调 channel_home(A) 只触发 A 的子站请求"**。没有计数就测不出
    ///   "全量扇出"回归 —— 那是本项要防的**唯一**缺陷形态。
    struct CountingChild {
        manifest: ProviderManifest,
        home_calls: Arc<std::sync::atomic::AtomicUsize>,
    }

    #[async_trait]
    impl MediaProvider for CountingChild {
        fn manifest(&self) -> &ProviderManifest {
            &self.manifest
        }
        async fn home(&self) -> Result<Vec<Section>, ProviderError> {
            self.home_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(vec![Section {
                id: "c1".into(),
                title: "电影".into(),
                source: SectionSource::Category {
                    category_id: "c1".into(),
                },
                items: Vec::new(),
            }])
        }
        async fn search(&self, _kw: &str, page: u32) -> Result<Page<MediaItem>, ProviderError> {
            Ok(Page { items: Vec::new(), page, page_count: None, total: None })
        }
        async fn detail(&self, id: &MediaId) -> Result<MediaDetail, ProviderError> {
            Ok(MediaDetail {
                id: id.clone(),
                title: String::new(),
                cover: None,
                description: None,
                badges: Vec::new(),
                kind: MediaKind::Movie,
                meta: Default::default(),
                sources: Vec::new(),
                episodes: Vec::new(),
            })
        }
        async fn resolve(
            &self,
            _id: &MediaId,
            _req: &PlayRequest,
        ) -> Result<Vec<StreamCandidate>, ProviderError> {
            Ok(vec![])
        }
    }

    /// ★★ N9 门禁①：home() 收敛成**一个**渠道条区块，且**一个子站请求都不发**
    ///
    /// # 为什么这是判据（Owner 原话）
    /// > 首页的 tvbox 聚合源……支持有二级横向渠道，不然一次性加载太多非常卡顿。
    ///
    /// ```text
    /// 缺陷（改前）：home() 遍历 N 个子站各发一次 home() ⇒ 请求放大，
    ///               且返回 N 组区块 ⇒ 首页一次铺 16 组（实测 26 个分组）。
    /// 修法：home() 纯构造，**零网络**；返回单区块 Custom{key:"tvbox_agg_channels"}。
    /// 注入：把 home() 改回"遍历子站各 push 它们 home()" ⇒ 本条两条断言同时红
    ///       （区块数 1→N、请求数 0→N）。
    /// ```
    #[tokio::test]
    async fn n9_home_is_single_channels_section_and_sends_zero_child_requests() {
        let c1 = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let c2 = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let a = Arc::new(CountingChild {
            manifest: manifest("sub1", "tvbox"),
            home_calls: c1.clone(),
        }) as Arc<dyn MediaProvider>;
        let b = Arc::new(CountingChild {
            manifest: manifest("sub2", "tvbox"),
            home_calls: c2.clone(),
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("n9home", vec![a, b], &["sub1", "sub2"]);

        let secs = agg.home().await.expect("聚合首页应成功");
        assert_eq!(
            secs.len(),
            1,
            "★ home() 必须收敛为**单个**渠道条区块（旧行为是 N 个子站 N 个区块）：{:?}",
            secs.iter().map(|s| &s.title).collect::<Vec<_>>()
        );
        assert_eq!(secs[0].id, "tvbox_agg::channels", "① 区块 id 逐字");
        assert_eq!(secs[0].title, "TVBox 聚合");
        match &secs[0].source {
            SectionSource::Custom { key } => {
                assert_eq!(key, CHANNELS_SECTION_KEY, "② source.key 逐字（Dart 侧靠它分流）")
            }
            other => panic!("③ 必须是 Custom 型（否则 Dart 侧会当直播条）：{other:?}"),
        }
        assert!(secs[0].items.is_empty(), "④ items 必须为空（渠道清单走 tvbox_agg_channels）");

        // ★★ 懒加载的硬证据：**零**子站请求
        let total =
            c1.load(std::sync::atomic::Ordering::SeqCst) + c2.load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(
            total, 0,
            "★ 首屏 home() 不许发任何子站请求（改前是 2 个；注入「改回全量扇出」⇒ 本条红）"
        );
    }

    /// ★★ N9 门禁②：**请求数 = 已看过的渠道数**（懒加载，防一次性全拉回归）
    ///
    /// ```text
    /// 进聚合区块   → 0 个子站请求（渠道条本身零网络，见门禁①）
    /// 切到 sub1    → sub1 计数 1、sub2 计数 0（**只触发被选中的那个**）
    /// 再切到 sub2  → sub1 计数 1、sub2 计数 1（sub1 **没有**被重复请求）
    /// 切回 sub1    → 两个计数都不变（缓存/复用由 UI 层负责，数据层不重复扇出）
    /// ```
    /// 注入：把 `channel_home_of` 改成"遍历所有子站" ⇒ 第 2 步的 `sub2 == 0` 立刻红。
    #[tokio::test]
    async fn n9_channel_home_only_touches_requested_channel() {
        let c1 = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let c2 = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let a = Arc::new(CountingChild {
            manifest: manifest("sub1", "tvbox"),
            home_calls: c1.clone(),
        }) as Arc<dyn MediaProvider>;
        let b = Arc::new(CountingChild {
            manifest: manifest("sub2", "tvbox"),
            home_calls: c2.clone(),
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("n9lazy", vec![a, b], &["sub1", "sub2"]);

        let n = |c: &Arc<std::sync::atomic::AtomicUsize>| c.load(std::sync::atomic::Ordering::SeqCst);

        // 首屏：渠道条本身不发请求
        let _ = agg.home().await.expect("home");
        assert_eq!((n(&c1), n(&c2)), (0, 0), "★ 首屏 0 个子站请求");

        // 切到 sub1 ⇒ 只有 sub1 被请求
        agg.channel_home("sub1").await.expect("渠道1");
        assert_eq!((n(&c1), n(&c2)), (1, 0), "★ 调 sub1 不许碰到 sub2");

        // 切到 sub2 ⇒ sub1 不再被请求
        agg.channel_home("sub2").await.expect("渠道2");
        assert_eq!((n(&c1), n(&c2)), (1, 1), "★ 切 sub2 不许重复拉 sub1");

        // 判据汇总（一眼可读的那一栏）
        let seen_channels = 2usize;
        let total = n(&c1) + n(&c2);
        assert_eq!(
            total, seen_channels,
            "★ 请求数({total}) 必须 == 已看过的渠道数({seen_channels}) —— N9 懒加载判据"
        );
    }

    /// ★ N9 门禁③：渠道清单（命令 `tvbox_agg_channels` 的数据源）
    ///
    /// ```text
    /// · 清单条数 == 启用子站数
    /// · 字段是 id/name/enabled，且 id 与 MediaId.provider 同一字符串
    /// · 渠道 id 不存在 ⇒ channel_home 给**可读 Err**（不是 panic / 不是空结果）
    /// ```
    #[tokio::test]
    async fn n9_channels_lists_enabled_children_by_id() {
        let mk = |id: &str| {
            Arc::new(FakeChild {
                manifest: manifest(id, "tvbox"),
                items: vec![],
                fail_search: false,
            }) as Arc<dyn MediaProvider>
        };
        let agg = agg_with("n9channels", vec![mk("aaa"), mk("bbb")], &["bbb", "aaa"]);

        let ch = agg.channels();
        assert_eq!(ch.len(), 2, "两个启用子站 ⇒ 两条渠道：{ch:?}");
        // 保序：apply_patch 保序 ⇒ 这里的口径是"勾选顺序"
        assert_eq!(ch[0].0, "bbb", "顺序按启用集合（勾选顺序）：{ch:?}");
        assert_eq!(ch[1].0, "aaa");
        assert_eq!(ch[0].1, "bbb", "name 取子站 manifest.name");
        assert!(ch[0].2, "enabled 默认 true");

        // 未启用/不存在的渠道 ⇒ 可读 Err（且不是空 Ok）
        let err = agg
            .channel_home("nope")
            .await
            .expect_err("不存在的渠道必须 Err");
        let msg = format!("{err}");
        assert!(msg.contains("找不到渠道 nope"), "错误文案要能指名：{msg}");
    }

    /// ★ N9 门禁④：**未实现的 csp 子站根本不在渠道清单里**
    ///
    /// ```text
    /// csp 未实现类在 `collect_sites` 就被拦进 skipped（reason「csp_X 尚未实现」），
    /// **压根不会注册成 provider** ⇒ registry 里没有 ⇒ 渠道清单里也不该有。
    /// 这条防的是"渠道条里出现一个点了必然报错的死渠道"。
    /// ```
    #[tokio::test]
    async fn n9_channels_excludes_non_tvbox_provider() {
        let tv = Arc::new(FakeChild {
            manifest: manifest("tvbox1", "tvbox"),
            items: vec![],
            fail_search: false,
        }) as Arc<dyn MediaProvider>;
        let mut plugin_m = manifest("plug1", "plugin");
        plugin_m.hidden = false;
        let plug = Arc::new(FakeChild {
            manifest: plugin_m,
            items: vec![],
            fail_search: false,
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("n9filter", vec![tv, plug], &["tvbox1"]);

        let ids: Vec<String> = agg.channels().into_iter().map(|(id, _, _)| id).collect();
        assert_eq!(ids, vec!["tvbox1"], "启用集合只勾了 tvbox1 ⇒ 渠道清单只有它：{ids:?}");

        // 未勾选的非 tvbox 源，即便在 registry 里也不该被 channel_home 取到
        let err = agg
            .channel_home("plug1")
            .await
            .expect_err("不在渠道清单里的 provider 不许被取首页（越权取别的源）");
        assert!(format!("{err}").contains("找不到渠道 plug1"), "{err}");
    }

    /// ★ N9 门禁⑤：**实网读数** —— 真订阅导入 ⇒ 渠道清单 + 按渠道取数（默认不跑）
    ///
    /// ```text
    /// CSP_LIVE=1 cargo test --lib csp_live_n9 --release -- --ignored --nocapture
    /// ```
    ///
    /// # 为什么是 `#[ignore]` + 显式环境变量（照 csp/route_tests.rs 的既有范式）
    /// ```text
    /// 「没设变量就 return」会把这条记成 **ok**（假绿：报告里"通过"但什么都没验）。
    /// 这里：默认 ignored（不计入 passed）；显式 --ignored 跑就必须 CSP_LIVE=1，
    /// 否则 assert 失败。⇒ "没联网"永远不会被伪装成"通过"。
    /// ```
    ///
    /// # 它验的是 N9 的**用户可见那一步**
    /// ```text
    /// ① 真配置导入 ⇒ channels() 非空，且每个 id 都能在 registry 查到（id 契约）
    /// ② 首屏 home() ⇒ **1 个**渠道条区块 + items 空（懒加载在真数据上同样成立）
    /// ③ channel_home(第一个渠道) ⇒ **真发请求**拿到只属于它的区块，
    ///    且区块 id/title 带该渠道的前缀/名字
    /// ```
    /// ⚠️ 站名中性化：只用配置里的显示名，不写任何具体视频网站名（t98 纪律）。
    #[allow(non_snake_case)]
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_n9 --release -- --ignored --nocapture"]
    async fn csp_live_n9_channels_and_channel_home_with_real_config() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 这条是 --ignored 才跑的真网络用例：显式跑就必须给 CSP_LIVE=1；不给就失败，而不是 return 后被记成 ok（假绿）"
        );
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let dir = tmp_dir("n9live");
        // 真形态配置：csp 类站点，站名中性化（只留协议与类名）
        // ⚠️ 这里**不写任何镜像 URL**：既守 t98「仓库不出现站名」，
        //    也让这条门禁只验 N9 的渠道链路（镜像可达性不是本项议题）。
        let cfg = r#"{
          "sites": [
            {"key":"a1","name":"甲站","type":3,"api":"csp_Bili",
             "ext":{"json":"https://x/cover.png","cookie":"http://127.0.0.1:9978/file/cookie.txt"}}
          ]
        }"#;
        let st = crate::state::AppState::bootstrap(dir.clone())
            .await
            .expect("bootstrap 失败");
        let res = crate::tvbox::import_tvbox_config(&st, cfg)
            .await
            .expect("导入不该失败");
        println!("[EVIDENCE] n9-live-import {res}");

        // ① 渠道清单：非空 + id 契约（channels.id 必须能在 registry 里查到）
        let ch = channels_of(&st.registry, &st.data_dir);
        println!("[EVIDENCE] n9-live-channels {} 条：{:?}", ch.len(), ch);
        assert!(!ch.is_empty(), "真导入后必须有渠道：{res}");
        for (id, _name, _en) in &ch {
            assert!(
                st.registry.get(id).is_some(),
                "★ 渠道 id 必须能在 registry 里查到（id 契约）：{id}"
            );
        }
        assert!(
            res["imported"].as_array().map(|a| a.len()).unwrap_or(0) > 0,
            "前置：真导入必须真的进了源（否则下面验的是空数据集）：{res}"
        );

        // ② 首屏 home()：单区块 + items 空（真数据上同样成立）
        //    ★ 用 `TvboxAggregate::new(...)` —— 与 bootstrap 注册进 registry 的
        //      那个**同输入同实现**（工厂幂等），所以走的是同一段代码，
        //      不是"另造一个对象糊弄门禁"。`Arc<dyn MediaProvider>` 没有 downcast，
        //      这是拿到该实例的唯一不越界途径。
        let agg = TvboxAggregate::new(st.registry.clone(), st.data_dir.clone());
        let secs = agg.home().await.expect("home 应成功");
        println!("[EVIDENCE] n9-live-home sections={}", secs.len());
        assert_eq!(secs.len(), 1, "★ 真数据上 home() 也只能出 1 个区块：{secs:?}");
        assert!(secs[0].items.is_empty(), "渠道条 items 必须为空");
        match &secs[0].source {
            SectionSource::Custom { key } => assert_eq!(key, CHANNELS_SECTION_KEY),
            other => panic!("必须是 Custom 型：{other:?}"),
        }

        // ③ 按渠道取数：真去那个渠道发请求
        let (cid, cname, _) = ch[0].clone();
        let got = channel_home_of(&st.registry, &st.data_dir, &cid)
            .await
            .expect("真渠道取数应成功");
        println!(
            "[EVIDENCE] n9-live-channel-home channel={cid} name={cname} sections={}",
            got.len()
        );
        assert!(
            !got.is_empty(),
            "★ 真渠道要真出区块（为空 ⇒ 可能模板改版/风控，需人工看，不许当成「这源没内容」）"
        );
        for s in &got {
            assert!(s.id.starts_with(&format!("{cid}{SEP}")), "区块 id 带子站前缀：{}", s.id);
            assert!(s.title.contains(&cname), "标题带渠道名：{}", s.title);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `hidden` 与旧数据的兼容：false 时不落盘这个键；缺这个键读回来必须是 false
    ///
    /// 用"自己序列化 → 再反序列化"来验，而不是手写一份 JSON ——
    /// 手写 JSON 会因为将来给 `ProviderManifest` 加必填字段而假红（我第一版就这么红过）。
    #[test]
    fn manifest_hidden_defaults_false() {
        let mut m = manifest("x", "tvbox");
        m.hidden = false;
        let j = serde_json::to_value(&m).expect("manifest 应能序列化");
        assert!(
            j.get("hidden").is_none(),
            "★ false 时不该出现 hidden 键（旧前端/旧文件都不用改）：{j}"
        );
        let back: ProviderManifest = serde_json::from_value(j).expect("缺 hidden 也要能读");
        assert!(!back.hidden, "缺字段 ⇒ 默认 false");

        // 反面：true 时必须真的写出来（否则 Dart 侧过滤看不到）
        let mut t = manifest("y", "tvbox");
        t.hidden = true;
        let jt = serde_json::to_value(&t).expect("序列化");
        assert_eq!(jt.get("hidden").and_then(|v| v.as_bool()), Some(true));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  R2-B 门禁：**停用必须被尊重**（兜底不许吃掉停用）+ **热重载**
    //
    //  Owner 报的真缺陷（逐字）：
    //   · 「首页关闭了,但是搜索页面还是能搜索出来,这属于bug」
    //   · 「这个源 的开关要热重载生效,而不是开关状态之后必须重启软件才能生效」
    //
    //  # 真数据背景（本机实测）
    //  ```text
    //  disabled-providers.json 停用 51 条（含全部 16 个 csp 子站）
    //  但 tvbox-aggregate.json 的 enabledSiteIds = []（空）
    //  ⇒ 空集合触发兜底 ⇒ 把**已停用**的子站照样扇出 ⇒ 搜索经聚合源仍能搜到。
    //  ```
    // ══════════════════════════════════════════════════════════════════════

    /// 造一个"n 个已启用 hidden 子站 + 可选停用名单"的聚合器
    ///
    /// ★ 与 `agg_with` 的区别：本夹具**能表达"用户显式停用"**（写 disabled 文件），
    ///   那正是 R2-B 要区分的那一维（`agg_with` 表达不了）。
    fn agg_disabled(
        tag: &str,
        children: &[&str],
        enabled_site_ids: &[&str],
        disabled: &[&str],
    ) -> (TvboxAggregate, std::path::PathBuf, Arc<Registry>) {
        let reg = Arc::new(Registry::new());
        for id in children {
            reg.register(Arc::new(FakeChild {
                manifest: manifest(id, "tvbox"),
                items: vec![item("x", "条目X")],
                fail_search: false,
            }) as Arc<dyn MediaProvider>);
            // hidden 子站默认启用（与真实导入一致）
        }
        let dir = tmp_dir(tag);
        let mut cfg = AggregateConfig::default();
        cfg.enabled_site_ids = enabled_site_ids.iter().map(|s| s.to_string()).collect();
        cfg.hidden_site_ids = derive_hidden(&cfg.enabled_site_ids);
        save(&dir, &cfg).expect("写聚合配置");
        // 停用名单
        crate::commands::save_disabled(
            &dir,
            &disabled.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
        )
        .expect("写停用名单");
        // 内存里的 enabled 也要跟着停用（bootstrap 会这么做）
        for id in disabled {
            reg.set_enabled(id, false);
        }
        (TvboxAggregate::new(reg.clone(), dir.clone()), dir, reg)
    }

    /// ★★★ 门禁①：**已显式停用的子站不许被兜底扇出来**（Owner 报的 bug 本体）
    ///
    /// ```text
    /// 场景 = Owner 的机器：enabledSiteIds 为空 + disabled 非空
    /// 注入「把 fallback_allowed 判据去掉（无条件兜底）」⇒ 本条红。
    /// ```
    #[tokio::test]
    async fn r2b_disabled_children_are_not_fanned_out() {
        let (agg, _dir, _reg) = agg_disabled(
            "r2b-nofanout",
            &["sub-a", "sub-b"],
            &[],                    // enabledSiteIds 空（= 真数据）
            &["sub-a", "sub-b"],    // 两个都显式停用
        );
        let kids = agg.enabled_children();
        assert!(
            kids.is_empty(),
            "★★★ 两个子站都被用户显式停用 ⇒ 扇出集合必须为空，实际 {} 个：{:?}",
            kids.len(),
            kids.iter().map(|p| p.manifest().id.clone()).collect::<Vec<_>>()
        );
        // 反面（防"改成永远空"这种反向假修）：真搜一次也不该出结果
        let page = agg.search("条目", 1).await;
        let n = page.map(|p| p.items.len()).unwrap_or(0);
        assert_eq!(
            n, 0,
            "★★★ 停用后搜索不许出结果（Owner 的验收动作：首页关了，搜索也得空）"
        );
    }

    /// ★★★ 门禁②：**兜底仍然保护"尚未配置"**（不许把能力砍了）
    ///
    /// ```text
    /// 反面场景：enabledSiteIds 空 + **没有任何停用记录**（用户还没配置过）
    ///   ⇒ 兜底必须**仍然生效**（否则会回归"导入了 100 个源却搜不到东西"）。
    /// ★ 这条是"别修过头"的守门人 —— 与门禁① 一起才构成完整判据。
    /// ```
    #[tokio::test]
    async fn r2b_fallback_still_works_when_nothing_disabled() {
        let (agg, _dir, _reg) = agg_disabled(
            "r2b-fallback-kept",
            &["sub-a", "sub-b"],
            &[],
            &[],                    // 从未停用任何源
        );
        let kids = agg.enabled_children();
        assert_eq!(
            kids.len(),
            2,
            "★★ 从未停用任何源 ⇒ 兜底必须仍然扇出（保护\"尚未配置\"的原意）"
        );
    }

    /// ★★★ 门禁③：**兜底不吃"部分停用"**（部分停用时只扇出**仍启用**的那些）
    ///
    /// ```text
    /// 场景：两个子站，停用其中一个；enabledSiteIds 仍为空
    /// ⇒ 扇出集合 = **1**（只含仍启用的那个），**不是** 2、也不是 0。
    /// 注入「兜底改用 manifests()（不看 enabled）」⇒ 变成 2 ⇒ 本条红。
    /// ```
    #[tokio::test]
    async fn r2b_partial_disable_fans_out_only_enabled() {
        let (agg, _dir, _reg) = agg_disabled(
            "r2b-partial",
            &["sub-a", "sub-b"],
            &[],
            &["sub-a"],             // 只停用 a
        );
        let ids: Vec<String> = agg
            .enabled_children()
            .iter()
            .map(|p| p.manifest().id.clone())
            .collect();
        assert_eq!(
            ids,
            vec!["sub-b".to_string()],
            "★★★ 只扇出**仍启用**的那个；停用的 sub-a 不许出现（实际 {ids:?}）"
        );
    }

    /// ★★★ 门禁④（⚡ Owner 硬要求）：**热重载** —— 改 enabled 后**同一进程内**立即生效
    ///
    /// ```text
    /// 判据（Owner 的验收动作）：点开关 ⇒ 不重启 ⇒ 扇出集合立即变。
    /// ★ 关键：`enabled_children` 每次调用都**现读**（配置 + registry）
    ///   ⇒ 两个方向都要热：
    ///     停用后立即消失（不许还留着旧集合）
    ///     重新启用后立即回来（不许还空着）
    /// 注入「把 enabled_children 的结果缓存起来」⇒ 本条红。
    /// ```
    #[tokio::test]
    async fn r2b_hot_reload_without_restart() {
        let reg = Arc::new(Registry::new());
        for id in ["sub-a", "sub-b"] {
            reg.register(Arc::new(FakeChild {
                manifest: manifest(id, "tvbox"),
                items: vec![],
                fail_search: false,
            }) as Arc<dyn MediaProvider>);
        }
        let dir = tmp_dir("r2b-hot");
        let mut cfg = AggregateConfig::default(); // enabledSiteIds 空 + 无停用 ⇒ 兜底生效
        save(&dir, &cfg).expect("写配置");
        crate::commands::save_disabled(&dir, &[]).expect("写空停用名单");
        let agg = TvboxAggregate::new(reg.clone(), dir.clone());

        // 前置：兜底生效 ⇒ 2 个（反空真）
        assert_eq!(agg.enabled_children().len(), 2, "前置：初始应扇出 2 个");

        // ★ 模拟"用户点开关停用 sub-a"（**不重启**）：
        //   1) 内存（真实链路里 set_enabled_persisted 做的）
        reg.set_enabled("sub-a", false);
        //   2) 落盘（同上）
        crate::commands::save_disabled(&dir, &["sub-a".to_string()]).expect("写停用");

        let after = agg.enabled_children();
        assert_eq!(
            after.len(), 1,
            "★★★ 热重载失败：停用 sub-a 后（未重启）扇出集合应立即从 2 变 1，实际 {}",
            after.len()
        );
        assert_eq!(after[0].manifest().id, "sub-b");

        // ★ 反向也热：重新启用 ⇒ 立即回来
        reg.set_enabled("sub-a", true);
        crate::commands::save_disabled(&dir, &[]).expect("清停用");
        assert_eq!(
            agg.enabled_children().len(), 2,
            "★★★ 热重载失败：重新启用后（未重启）应立即回到 2"
        );
    }

    /// ★★★ R2-B **真数据复现**（卡里的硬要求）：用 Owner 真实停用名单的**逐字副本**跑一次真扇出
    ///
    /// ```text
    /// 夹具由 `.probe/r2-t13-realdata-copy.py` 生成（**只读**真实目录；
    ///   铁律 store.rs:4457：用户真实库绝不能碰）。
    /// 形状 = Owner 机器现状：enabledSiteIds 空 + disabled 51 条（含全部 16 个 csp 子站）。
    ///
    /// ★ 为什么必须有这一条：上面几条用的是**造出来的** 2 个子站 ⇒
    ///   可能"造得像"而"真形状不同"（51 条、名字前缀 csp-*）。
    ///   这条用**真名单 + 真配置形状**跑，是"真读数"而非推理。
    /// ★ 反空真（铁律 149）：先断言夹具**确实**是那个形状（条数/前缀/空集合），
    ///   否则"扇出为空"可能是"因为夹具根本是空的"这种空真。
    /// ```
    #[test]
    fn r2b_realdata_shape_fans_out_nothing() {
        let real_dir = std::env::var("R2B_REALDATA_DIR")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::env::temp_dir().join("r2b-realdata"));
        let dis_file = real_dir.join("disabled-providers.json");
        let agg_file = real_dir.join("tvbox-aggregate.json");
        if !dis_file.exists() || !agg_file.exists() {
            // 夹具没生成 ⇒ **不静默跳过**（静默跳过 = 永久绿的空门禁）
            panic!(
                "★★ 真数据夹具不存在：{}\n\
                 先跑 `.probe/r2-t13-realdata-copy.py`（它**只读**真实目录并复刻到 %TEMP%\\r2b-realdata）",
                real_dir.display()
            );
        }

        // ── ① 反空真：夹具必须**真的是** Owner 那个形状 ──
        let disabled: Vec<String> =
            serde_json::from_str(&std::fs::read_to_string(&dis_file).unwrap()).unwrap();
        let agg_json: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&agg_file).unwrap()).unwrap();
        assert!(
            disabled.len() >= 40,
            "★★ 夹具停用名单应 ≥40 条（反空真），实际 {}",
            disabled.len()
        );
        let n_csp = disabled.iter().filter(|x| x.starts_with("csp-")).count();
        assert!(
            n_csp >= 10,
            "★★ 夹具应含 ≥10 个 csp 子站（Owner 形状的特征），实际 {n_csp}"
        );
        let enabled_ids = agg_json
            .get("enabledSiteIds")
            .and_then(|v| v.as_array())
            .expect("agg 配置应有 enabledSiteIds");
        assert!(
            enabled_ids.is_empty(),
            "★★ 夹具的 enabledSiteIds 应为空（那正是触发兜底的条件），实际 {} 项",
            enabled_ids.len()
        );

        // ── ② 真形状下扇出必须为空 ──
        let reg = Arc::new(Registry::new());
        for id in &disabled {
            reg.register(Arc::new(FakeChild {
                manifest: manifest(id, "tvbox"),
                items: vec![item("x", "条目X")],
                fail_search: false,
            }) as Arc<dyn MediaProvider>);
            reg.set_enabled(id, false); // 逐字照真实名单停用
        }
        let agg = TvboxAggregate::new(reg.clone(), real_dir.clone());
        let kids = agg.enabled_children();
        assert!(
            kids.is_empty(),
            "★★★ 真数据形状（{} 条停用 + 空启用集合）下扇出必须为空，实际 {} 个：{:?}\n\
             （非空 ⇒ 停用仍被兜底绕过 = Owner 报的 bug 复现）",
            disabled.len(),
            kids.len(),
            kids.iter().map(|p| p.manifest().id.clone()).collect::<Vec<_>>()
        );
    }

    /// ★★ 门禁⑤：`fallback_allowed` 是**判据的唯一来源**（三处共用，防漂移）
    ///
    /// ```text
    /// 三处 fail-open（registry search_all / registry home_all / enabled_children）
    /// 若各自写一遍"是否兜底"，就会漂移成"修了搜索、首页仍漏"。
    /// 本条断言：该判据**只有一份定义**（源码级），且 registry 两处也引它。
    /// ```
    #[test]
    fn r2b_fallback_judgement_has_single_source() {
        let src = include_str!("tvbox_aggregate.rs");
        // ⚠️ 数的是**定义行**（`pub fn fallback_allowed(`），不是"文本出现次数" ——
        //    本文件里这个符号还会在注释与文档里出现（第一版数错成 2 被自己的门禁抓出来）。
        let n = src
            .lines()
            .filter(|l| l.trim_start().starts_with("pub fn fallback_allowed("))
            .count();
        assert_eq!(n, 1, "★★ 判据必须只有一份**定义**（实际 {n} 份 ⇒ 会漂移）");

        let reg_src = include_str!("registry.rs");
        // registry 两处兜底必须调同一个判据（而不是各自读 disabled 文件）
        let calls = reg_src.matches("fallback_allowed(").count();
        assert!(
            calls >= 2,
            "★★ registry 的两处兜底都必须调 fallback_allowed（实际 {calls} 处）\n\
             （search_all 与 home_all 各一处 —— 缺一处就是\"修了搜索、首页仍漏\"）"
        );
        // 反面：registry 不许自己再读 disabled 文件（那是判据分裂）
        assert!(
            !reg_src.contains("load_disabled"),
            "★★ registry 不许自己读 disabled-providers.json —— 判据必须走 fallback_allowed"
        );
    }
}
