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
    pub enabled_site_ids: Vec<String>,
    pub hidden_site_ids: Vec<String>,
    pub pan: PanConfig,
}

impl Default for AggregateConfig {
    fn default() -> Self {
        Self {
            version: 1,
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
    save(data_dir, &next)?;
    Ok(next)
}

/// 子站清单里"是不是已实现类"的可读原因（与导入报告同一句话）
pub fn unimplemented_reason(api: &str) -> String {
    format!("{api} 尚未实现")
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
    fn enabled_children(&self) -> Vec<Arc<dyn MediaProvider>> {
        let cfg = load(&self.data_dir);
        let picked: Vec<Arc<dyn MediaProvider>> = cfg
            .enabled_site_ids
            .iter()
            .filter_map(|id| self.registry.get(id))
            .collect();
        if !picked.is_empty() {
            return picked;
        }
        // 空启用集合 ⇒ 兜底：所有 hidden 子站（= TVBox 导入的那批）
        let mut all: Vec<Arc<dyn MediaProvider>> = self
            .registry
            .manifests()
            .into_iter()
            .filter(|m| m.hidden)
            .filter_map(|m| self.registry.get(&m.id))
            .collect();
        all.sort_by(|a, b| a.manifest().id.cmp(&b.manifest().id));
        if !all.is_empty() {
            log::warn!(
                "[tvbox_agg] 启用集合为空 ⇒ 兜底扇出全部 {} 个导入子站（否则 csp 源搜不到）",
                all.len()
            );
        }
        all
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

    fn wrap_item(child: &str, mut it: MediaItem) -> MediaItem {
        it.id = MediaId {
            provider: AGGREGATE_ID.to_string(),
            native: format!("{child}{SEP}{}", it.id.native),
        };
        it
    }

    /// 合并去重：同一子站同一 native 视为同一条；跨子站同 (title, kind) 也合并
    fn dedupe(items: Vec<MediaItem>) -> Vec<MediaItem> {
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::with_capacity(items.len());
        for it in items {
            let key = (it.title.clone(), format!("{:?}", it.kind));
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
        let mut all = Vec::new();
        // ★ 失败明细：`(子站 id, 原因)` —— 用于 ①汇总 warn ②"全部失败"时透给 registry
        let mut fails: Vec<(String, String)> = Vec::new();
        for p in children {
            let cid = Self::child_id(&p);
            // ★ 硬纪律①：单站失败只记原因，**不中断**
            match tokio::time::timeout(CHILD_TIMEOUT, p.search(kw, page)).await {
                Ok(Ok(page)) => all.extend(page.items.into_iter().map(|i| Self::wrap_item(&cid, i))),
                Ok(Err(e)) => {
                    let why = format!("{e}");
                    self.warn(format!("子站 {cid} 搜索失败：{why}"));
                    fails.push((cid, why));
                }
                Err(_) => {
                    let why = format!("超时（{}s）", CHILD_TIMEOUT.as_secs());
                    self.warn(format!("子站 {cid} 搜索{why}"));
                    fails.push((cid, why));
                }
            }
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

    async fn home(&self) -> Result<Vec<Section>, ProviderError> {
        let children = self.enabled_children();
        let mut out = Vec::new();
        for p in children {
            let cid = Self::child_id(&p);
            /*
             * ★ 2026-10-26 修（perf-probe 复核发现的用户可见缺陷）：
             *   原来 `title: s.title` 原样用子站的标题 ⇒ 16 个子站都有「电影」「电视剧」
             *   ⇒ 首页平铺出十几个**同名区块**，用户分不清哪条来自哪个源。
             *   改成 `"{子站名} · {原标题}"`；子站名取不到时退回原标题（绝不出现" · 电影"这种残缺）。
             */
            let child_name = p.manifest().name.clone();
            match tokio::time::timeout(CHILD_TIMEOUT, p.home()).await {
                Ok(Ok(secs)) => {
                    for s in secs {
                        out.push(Section {
                            // 区块 id 带子站前缀 ⇒ list() 能路由回哪个子站
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
                }
                Ok(Err(e)) => self.warn(format!("子站 {cid} 首页失败：{e}")),
                Err(_) => self.warn(format!("子站 {cid} 首页超时")),
            }
        }
        Ok(out)
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
        child
            .resolve(
                &MediaId {
                    provider: cid,
                    native,
                },
                req,
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
                meta.map(|x| x.api.clone()).unwrap_or_default(),
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
                "enabled": cfg.enabled_site_ids.iter().any(|x| x == &id2(&id)),
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

    /// ★ 注入点：删掉 `dedupe` 调用 ⇒ 本条红
    #[tokio::test]
    async fn fanout_dedupes_same_media() {
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
        let agg = agg_with("dedupe", vec![a, b], &["tvbox1", "tvbox2"]);
        let page = agg.search("x", 1).await.expect("应成功");
        assert_eq!(page.items.len(), 1, "两个子站给同一条内容只留一条：{:?}",
            page.items.iter().map(|i| &i.title).collect::<Vec<_>>());
        assert!(page.items[0].id.native.starts_with("tvbox1::"), "保留先到的那个");
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

    /// ★ A4 门禁（总计划第 19 项）：两个子站有**同名分类** ⇒ 聚合首页的区块标题必须能区分子站
    ///
    /// # 为什么这条是判据
    /// ```text
    /// 缺陷：`home()` 里 `title: s.title` 原样用子站标题 ⇒ 16 个子站都有「电影」
    ///   ⇒ 聚合首页平铺十几个同名区块，用户分不清哪条来自哪个源。
    /// 修法（2135314 已落库）：`"{子站名} · {原标题}"`；子站名取不到时退回原标题。
    /// 注入：把 title 改回 `s.title` ⇒ 本条红（两个区块标题都变成裸「电影」）。
    /// ```
    #[tokio::test]
    async fn home_titles_distinguish_same_named_sections_across_children() {
        let a = Arc::new(SameTitleChild {
            manifest: manifest("tvbox1", "tvbox"),
        }) as Arc<dyn MediaProvider>;
        let b = Arc::new(SameTitleChild {
            manifest: manifest("tvbox2", "tvbox"),
        }) as Arc<dyn MediaProvider>;
        let agg = agg_with("aggtitle", vec![a, b], &["tvbox1", "tvbox2"]);
        let secs = agg.home().await.expect("聚合首页应成功");
        assert_eq!(secs.len(), 2, "两个子站各出一个区块：{:?}", secs.iter().map(|s| &s.title).collect::<Vec<_>>());

        // ① 标题可区分（本门禁的核心）
        let titles: Vec<&str> = secs.iter().map(|s| s.title.as_str()).collect();
        assert_ne!(titles[0], titles[1], "同名分类的区块标题必须可区分：{titles:?}");

        // ② 标题里要能看到各自的子站名 + 原标题
        assert!(
            titles[0].contains("tvbox1") && titles[0].contains("电影"),
            "区块①要带子站名 tvbox1 和原标题「电影」：{titles:?}"
        );
        assert!(
            titles[1].contains("tvbox2") && titles[1].contains("电影"),
            "区块②要带子站名 tvbox2 和原标题「电影」：{titles:?}"
        );

        // ③ 反向断言（路由契约不被牵动）：区块 id 仍带子站前缀，且不带子站名污染
        assert!(secs[0].id.starts_with("tvbox1::"), "{}", secs[0].id);
        assert!(secs[1].id.starts_with("tvbox2::"), "{}", secs[1].id);

        // ④ 反向断言（防御"前缀残缺"回归）：子站名为空白时必须退回原标题，不许出现" · 电影"
        let blank = Arc::new(SameTitleChild {
            manifest: {
                let mut m = manifest("tvbox9", "tvbox");
                m.name = "   ".into();
                m
            },
        }) as Arc<dyn MediaProvider>;
        let agg9 = agg_with("aggtitle9", vec![blank], &["tvbox9"]);
        let secs9 = agg9.home().await.expect("应成功");
        assert_eq!(secs9[0].title, "电影", "子站名取不到 ⇒ 退回原标题（不许残缺前缀）");
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
}
