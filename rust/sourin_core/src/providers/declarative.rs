//! 声明式 Provider —— 用户写一个 JSON 即可接入标准视频站，**零代码**
//!
//! # 适用场景
//!
//! 覆盖中文影视生态的绝大多数站点（苹果 CMS / MacCMS 系列），其接口是标准的：
//! ```text
//! GET {base}?ac=class                     → 分类列表
//! GET {base}?ac=videolist&t={cat}&pg={n}  → 分类内容
//! GET {base}?ac=detail&ids={id}           → 详情
//! GET {base}?wd={kw}&ac=videolist         → 搜索
//! ```
//!
//! # 设计依据
//!
//! - **借鉴 zyfun 的适配器模式**（8895★）：源用统一数据结构 + `type` 字段区分适配器
//! - **借鉴 Stremio 的字段设计**：`idPrefixes` / `proxyHeaders` / `notWebReady`
//! - **借鉴 Legado 的教训**：规则引擎必须**避免自研小语言失控**。Legado 的规则语法演化成
//!   6 种前缀 + 3 种组合符 + 6 种插值的自研语言，官方教程标题是《从入门到入土》，
//!   最终不得不加 `mainJs` 全代码逃生舱（其 `BookSource.kt` L99）。
//!   → 我们**只用 JSONPath**（成熟标准），不发明新语法。
//! - **必须支持「两级取值」**：某电视台就是「先取列表的 guid，再套 URL 模板」。
//!   故 `resolve` 支持 `from_list` + `url_template` 两阶段。

use crate::model::*;
use crate::provider::*;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;

// ─────────────────────────── 描述文件格式 ───────────────────────────

/// 声明式 Provider 描述文件
///
/// 用户写这样一个 JSON 就能接入新站点。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeclarativeSpec {
    pub id: String,
    pub name: String,
    #[serde(default = "one")]
    pub version: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub theme_color: Option<String>,

    /// API 基址
    pub base: String,

    /// 默认请求头（防盗链场景）
    #[serde(default)]
    pub headers: HashMap<String, String>,

    /// 自定义 UA
    #[serde(default)]
    pub user_agent: Option<String>,

    /// 该源处理的 ID 前缀
    #[serde(default)]
    pub id_prefixes: Vec<String>,

    #[serde(default)]
    pub capabilities: DeclarativeCapabilities,

    /// 各端点定义
    pub endpoints: Endpoints,
}

fn one() -> String {
    "1.0.0".into()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeclarativeCapabilities {
    /// 默认开启点播（声明式源绝大多数是点播站）
    #[serde(default = "t")]
    pub vod: bool,
    #[serde(default)]
    pub live: bool,
    #[serde(default)]
    pub search: bool,
    #[serde(default)]
    pub multi_source: bool,
}

impl Default for DeclarativeCapabilities {
    fn default() -> Self {
        Self {
            vod: true,
            live: false,
            search: false,
            multi_source: false,
        }
    }
}

fn t() -> bool {
    true
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Endpoints {
    /// 分类列表
    #[serde(default)]
    pub categories: Option<Endpoint>,
    /// 分类内容
    #[serde(default)]
    pub list: Option<Endpoint>,
    /// 详情
    #[serde(default)]
    pub detail: Option<Endpoint>,
    /// 搜索
    #[serde(default)]
    pub search: Option<Endpoint>,
    /// 取流
    #[serde(default)]
    pub resolve: Option<ResolveEndpoint>,
    /// 直播源（m3u）
    #[serde(default)]
    pub live: Option<Endpoint>,
}

/// 一个普通端点：路径 + 参数模板 + 字段映射
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Endpoint {
    /// 路径（可含 `{placeholder}`）
    #[serde(default)]
    pub path: String,
    /// 查询参数模板，如 `{"t": "{category}", "pg": "{page}"}`
    #[serde(default)]
    pub params: HashMap<String, String>,
    /// 字段映射：`{ 目标字段: JSONPath }`
    ///
    /// 目标字段见下方常量；JSONPath 用 `$.` 前缀。
    #[serde(default)]
    pub map: HashMap<String, String>,
    /// 请求方法，默认 GET
    #[serde(default)]
    pub method: Option<String>,
}

/// 取流端点 —— 支持有/无「两级取值」
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ResolveEndpoint {
    /// 方式一：直接从详情响应取地址
    #[serde(default)]
    pub direct: Option<Endpoint>,
    /// 方式二：★ 两级取值 —— 先调列表接口取 id，再套 URL 模板
    #[serde(default)]
    pub from_list: Option<FromListResolve>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FromListResolve {
    /// 先请求的列表端点
    pub endpoint: Endpoint,
    /// 从列表响应中提取 id 的 JSONPath
    pub id_path: String,
    /// URL 模板，用 `{id}` 占位
    pub url_template: String,
    /// 可选：URL 模板变体（多清晰度），如 `{"2000": "...{id}.../2000.m3u8"}`
    #[serde(default)]
    pub variants: HashMap<String, String>,
}

// ─────────────────────────── 映射目标字段名 ───────────────────────────

const K_ITEMS: &str = "items";
const K_ID: &str = "id";
const K_TITLE: &str = "title";
const K_COVER: &str = "cover";
const K_SUBTITLE: &str = "subtitle";
const K_DESC: &str = "description";
const K_URL: &str = "url";
const K_EPISODES: &str = "episodes";

// ─────────────────────────── Provider 实现 ───────────────────────────

pub struct DeclarativeProvider {
    manifest: ProviderManifest,
    spec: DeclarativeSpec,
    client: reqwest::Client,
    /// 应用数据目录 —— **只**用来定位 `<数据目录>/overrides/<id>.json`。
    ///
    /// # 为什么必须由调用方注入（P5，2026-10-24）
    ///
    /// 覆盖层（`crate::overrides`）按 `target_id` 读文件，需要数据目录。
    /// 但 `state.rs:17` 立过规矩：**核心层不该知道 Tauri 的路径 API**，
    /// 所以这里不自己猜 `%APPDATA%`，而由 `state.rs` / `commands_remote.rs`
    /// 两个构造点显式挂上（`with_data_dir`）。
    ///
    /// `None` ⇒ 覆盖层整条链路**零命中**（连一次 stat 都不发），
    /// 这也是单测与「未挂目录」场景下的默认行为。
    data_dir: Option<std::path::PathBuf>,
}

impl DeclarativeProvider {
    /// 挂上应用数据目录 —— 覆盖层据此定位 `overrides/<id>.json`
    ///
    /// 照抄 `plugins/mod.rs::PluginProvider::with_data_dir` 的写法（同一种语义：
    /// 核心对象不持有全局路径，由装配层注入）。
    ///
    /// ⚠️ **两个构造点都要挂**（`state.rs` 启动恢复 + `commands_remote.rs` 导入）。
    /// 只挂一处会出现最难查的分裂：导入后能用、重启后失效（或反之）。
    /// 门禁 `overlay_is_wired_on_both_construction_sites` 钉死这一点。
    pub fn with_data_dir(mut self, dir: std::path::PathBuf) -> Self {
        self.data_dir = Some(dir);
        self
    }

    pub fn from_json(json: &str) -> Result<Self> {
        let spec: DeclarativeSpec = serde_json::from_str(json)
            .map_err(|e| ProviderError::parse(format!("描述文件格式错误: {e}")))?;
        Self::new(spec)
    }

    pub fn new(spec: DeclarativeSpec) -> Result<Self> {
        if spec.id.trim().is_empty() {
            return Err(ProviderError::parse("缺少 id 字段"));
        }
        if spec.base.trim().is_empty() {
            return Err(ProviderError::parse("缺少 base 字段"));
        }
        // base 必须是 http(s)
        if !spec.base.starts_with("http://") && !spec.base.starts_with("https://") {
            return Err(ProviderError::parse("base 必须是 http:// 或 https:// 开头"));
        }

        let ua = spec.user_agent.clone().unwrap_or_else(|| {
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36".into()
        });

        let client = reqwest::Client::builder()
            .user_agent(ua)
            .timeout(Duration::from_secs(20))
            .build()
            .map_err(|e| ProviderError::network(format!("构建客户端失败: {e}")))?;

        let caps = Capabilities {
            vod: spec.capabilities.vod,
            live: spec.capabilities.live,
            epg: false,
            search: spec.capabilities.search && spec.endpoints.search.is_some(),
            login_required: false,
            multi_source: spec.capabilities.multi_source,
            server_side_history: false,
            favorites: false,
            timeshift: false,
            danmaku: false,
            // task-T2：声明式源是纯 JSON 拉取模型，没有弹幕通道（也不该假装有）
            danmaku_send: false,
            // 声明式源的 schema 里还没有登录声明（它是纯 HTTP 拉取模型）
            login_supported: false,
            login_hint: None,
            login_needs_username: true,
            login_qr_supported: false,
            // task-38：声明式源没有登录能力
            can_auto_login: false,
        };

        let manifest = ProviderManifest {
            id: spec.id.clone(),
            name: spec.name.clone(),
            version: spec.version.clone(),
            kind: "declarative".into(),
            description: spec.description.clone(),
            icon: spec.icon.clone(),
            id_prefixes: spec.id_prefixes.clone(),
            capabilities: caps,
            // 声明式源暂不声明配置项（JSON 规则里没有这一块）
            cover_headers: Vec::new(),
            config: Vec::new(),
            api_version: 1,
            theme_color: spec.theme_color.clone(),
            working: true,
            broken_reason: None,
            enabled: None,
        };

        Ok(Self {
            manifest,
            spec,
            client,
            data_dir: None,
        })
    }

    /// 对**已归一化**的返回值应用源个性化覆盖层（P5，2026-10-24）
    ///
    /// # 为什么挂在归一化之后，而不是 `fetch()` 出口
    ///
    /// `fetch()` 拿到的是**站点原始 JSON**（`{"list":[{"vod_id","vod_name",...}]}`）。
    /// 若在那里套覆盖层，同一份覆盖层文件在 JS 插件上作用于 `title`、
    /// 在声明式源上却作用于 `vod_name` —— 这正是 Owner 要避免的**语义分裂**，
    /// 只是换了个方向而已。
    ///
    /// ⇒ 挂在 `map_items()` / 模型构造**之后**，对 `Page<MediaItem>` /
    ///   `MediaDetail` / `Vec<Category>` / `Vec<StreamCandidate>` 这些
    ///   **与 JS 路径同形状**的结构套用。同一份 `overrides/<id>.json`
    ///   对两种源通用。
    ///
    /// # 阴性对照是**构造性成立**的（不靠运气）
    ///
    /// 只有 `OverrideOutcome::Applied` 才做 `to_value` / `from_value` 往返；
    /// `Absent` / `Disabled` / `NotApplicable` / `Broken` 四种 outcome
    /// **直接返回原 `T`**（连序列化都不做），所以"无覆盖层时输出与原行为
    /// 逐字节一致"由控制流本身保证。
    ///
    /// # 失败语义（与 `overrides` 模块一致：绝不因覆盖层出错让源不可用）
    ///
    /// 覆盖层产物还原不回 `T`（例如用户 `rename` 掉了必填的 `title`）⇒
    /// **原样透出原始数据** + 记日志，不抛错、不返回空列表。
    ///
    /// # ⚠️ id 冲突是设计意图
    ///
    /// 声明式源 id 与 JS 插件 id 撞了会**共用同一份**覆盖层
    /// （`overrides.rs:108` 的注释就写着「插件 @id 或声明式源 id」）。
    /// 这是有意的：用户对「同一个 id」的个性化只该有一份。
    fn apply_layer<T>(&self, method: &str, v: T) -> Result<T>
    where
        T: Serialize + serde::de::DeserializeOwned,
    {
        // 未挂数据目录 ⇒ 零命中（连一次文件 stat 都不发）
        let Some(dir) = self.data_dir.as_deref() else {
            return Ok(v);
        };

        let mut val = match serde_json::to_value(&v) {
            Ok(x) => x,
            // 序列化不了就不该动它 —— 原样透出
            Err(e) => {
                log::warn!("覆盖层跳过（{method} 无法序列化）: {e}");
                return Ok(v);
            }
        };

        let outcome = crate::overrides::apply_override(
            Some(dir),
            &self.manifest.id,
            method,
            &mut val,
        );

        // ★ 只有 Applied 才往返。其余四种一律返回**原结构体** ——
        //   这让「无覆盖层时逐字节一致」由控制流保证，而不是靠 serde 恰好还原。
        if outcome != crate::overrides::OverrideOutcome::Applied {
            return Ok(v);
        }

        match serde_json::from_value::<T>(val) {
            Ok(t) => Ok(t),
            Err(e) => {
                // 覆盖层把数据改成了不合法的形状（例如删掉了必填字段）——
                // 原样透出，绝不让源因此不可用
                log::warn!("覆盖层产物无法还原为 {method} 的结果（已原样透出）: {e}");
                Ok(v)
            }
        }
    }

    /// 构建完整 URL（替换参数模板）
    fn build_url(&self, ep: &Endpoint, vars: &HashMap<String, String>) -> String {
        let path = subst(&ep.path, vars);
        let mut url = if path.starts_with("http") {
            path
        } else {
            format!("{}{}", self.spec.base.trim_end_matches('/'), ensure_slash(&path))
        };

        if !ep.params.is_empty() {
            let qs: Vec<String> = ep
                .params
                .iter()
                .map(|(k, v)| {
                    format!(
                        "{}={}",
                        urlencoding::encode(k),
                        urlencoding::encode(&subst(v, vars))
                    )
                })
                .collect();
            let sep = if url.contains('?') { '&' } else { '?' };
            url.push(sep);
            url.push_str(&qs.join("&"));
        }
        url
    }

    async fn fetch(&self, ep: &Endpoint, vars: &HashMap<String, String>) -> Result<serde_json::Value> {
        let url = self.build_url(ep, vars);

        let method = ep.method.as_deref().unwrap_or("GET").to_uppercase();
        let mut req = if method == "POST" {
            self.client.post(&url)
        } else {
            self.client.get(&url)
        };

        for (k, v) in &self.spec.headers {
            req = req.header(k, v);
        }

        let resp = req
            .send()
            .await
            .map_err(|e| ProviderError::network(format!("请求失败 {url}: {e}")))?;

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ProviderError::network(format!("读取失败: {e}")))?;

        if !status.is_success() {
            return Err(ProviderError::network(format!(
                "HTTP {status}: {}",
                text.chars().take(160).collect::<String>()
            )));
        }

        serde_json::from_str(&text).map_err(|e| {
            ProviderError::parse(format!(
                "响应不是 JSON（站点可能改版或有反爬）: {e} — {}",
                text.chars().take(160).collect::<String>()
            ))
        })
    }

    /// 把映射应用到响应，产出 MediaItem 列表
    fn map_items(&self, json: &serde_json::Value, map: &HashMap<String, String>) -> Vec<MediaItem> {
        // items 是数组的 JSONPath
        let items_path = map.get(K_ITEMS).map(String::as_str).unwrap_or("$.list");
        let arr = select(json, items_path);

        let arr = match arr {
            serde_json::Value::Array(a) => a,
            // 若整体就是数组
            serde_json::Value::Null => return vec![],
            other => vec![other],
        };

        let get = |node: &serde_json::Value, key: &str| -> Option<String> {
            map.get(key)
                .and_then(|p| select(node, p).as_str().map(String::from))
                .filter(|s| !s.is_empty())
        };

        arr.iter()
            .filter_map(|node| {
                let id = get(node, K_ID)?;
                Some(MediaItem {
                    id: MediaId::new(&self.spec.id, &id),
                    title: get(node, K_TITLE).unwrap_or_else(|| id.clone()),
                    cover: get(node, K_COVER),
                    subtitle: get(node, K_SUBTITLE),
                    badges: vec![],
                    kind: MediaKind::Movie,
                    description: get(node, K_DESC),
                })
            })
            .collect()
    }

    /// `resolve` 的原始取流逻辑（**不含**覆盖层）
    ///
    /// # 为什么拆出来
    ///
    /// `resolve` 内部有 3 条返回路径（剧集直链 / `direct` / `from_list`）。
    /// 若在每条路径各自套一次覆盖层，将来加第四条就会漏。
    /// 所以取流逻辑留在这里，覆盖层只在 `resolve` 的**单一出口**套一次 ——
    /// 门禁按 `self.apply_layer(` 的调用次数 == 5 钉死这一点。
    async fn resolve_candidates(
        &self,
        id: &MediaId,
        req: &PlayRequest,
    ) -> Result<Vec<StreamCandidate>> {
        // 剧集 id 直接就是播放地址（来自 episodes 的 link）
        if let Some(ep_id) = req.episode_id.as_deref() {
            if ep_id.starts_with("http") {
                return Ok(vec![candidate_from_url(ep_id, &self.spec)]);
            }
        }

        let Some(r) = &self.spec.endpoints.resolve else {
            return Err(ProviderError::unsupported("该源未配置取流端点"));
        };

        // 方式一：直接取
        if let Some(direct) = &r.direct {
            let mut vars = HashMap::new();
            vars.insert("id".into(), id.native.clone());
            let json = self.fetch(direct, &vars).await?;
            let url_path = direct.map.get(K_URL).map(String::as_str).unwrap_or("$.url");
            if let Some(u) = select(&json, url_path).as_str() {
                if u.starts_with("http") {
                    return Ok(vec![candidate_from_url(u, &self.spec)]);
                }
            }
        }

        // ★ 方式二：两级取值（某电视台式）
        if let Some(fl) = &r.from_list {
            let mut vars = HashMap::new();
            vars.insert("id".into(), id.native.clone());
            let json = self.fetch(&fl.endpoint, &vars).await?;

            let node = select(&json, &fl.id_path);
            // 可能是数组（取第一个）或字符串
            let extracted = match &node {
                serde_json::Value::Array(a) => a
                    .first()
                    .and_then(|v| v.as_str())
                    .map(String::from),
                serde_json::Value::String(s) => Some(s.clone()),
                _ => None,
            };

            let Some(v) = extracted else {
                return Err(ProviderError::parse(format!(
                    "两级取值失败：{} 未取到值",
                    fl.id_path
                )));
            };

            let mut out = Vec::new();
            if fl.variants.is_empty() {
                out.push(candidate_from_url(
                    &fl.url_template.replace("{id}", &v),
                    &self.spec,
                ));
            } else {
                for (label, tpl) in &fl.variants {
                    // kind 按 URL 推断而不是硬编码 Hls：
                    // variants 也可能直接给 mp4 直链
                    let u = tpl.replace("{id}", &v);
                    out.push(
                        StreamCandidate::new(&u, StreamKind::from_url(&u))
                            .with_quality(label)
                            .with_label("声明式")
                            .with_headers(spec_headers(&self.spec)),
                    );
                }
            }
            return Ok(out);
        }

        Err(ProviderError::unsupported("取流端点配置不完整"))
    }
}

fn ensure_slash(p: &str) -> String {
    if p.starts_with('/') {
        p.to_string()
    } else {
        format!("/{p}")
    }
}

/// 模板替换：`{key}` → vars[key]
fn subst(tpl: &str, vars: &HashMap<String, String>) -> String {
    let mut out = tpl.to_string();
    for (k, v) in vars {
        out = out.replace(&format!("{{{k}}}"), v);
    }
    out
}

// ─────────────────────────── JSONPath 子集 ───────────────────────────

/// 极简 JSONPath 求值 —— 支持 `$.a.b`、`$.a[*]`、`$.a[0]`、裸 `a.b`
///
/// **刻意只支持子集**：Legado 的教训是自研规则语言会失控（最终加了 `mainJs` 逃生舱）。
/// 我们用成熟标准的子集，不发明新语法。
pub fn select<'a>(root: &'a serde_json::Value, path: &str) -> serde_json::Value {
    let p = path.trim();
    let p = p.strip_prefix("$.").or_else(|| p.strip_prefix("$")).unwrap_or(p);
    if p.is_empty() {
        return root.clone();
    }

    let mut cur = root.clone();
    for seg in split_path(p) {
        match seg {
            Seg::Key(k) => {
                cur = cur.get(&k).cloned().unwrap_or(serde_json::Value::Null);
            }
            Seg::Index(i) => {
                cur = cur.get(i).cloned().unwrap_or(serde_json::Value::Null);
            }
            Seg::Wildcard => {
                // 通配返回数组本身，交由调用方迭代
                if !cur.is_array() {
                    if cur.is_null() {
                        return serde_json::Value::Null;
                    }
                    cur = serde_json::Value::Array(vec![cur]);
                }
            }
        }
        if cur.is_null() {
            return serde_json::Value::Null;
        }
    }
    cur
}

enum Seg {
    Key(String),
    Index(usize),
    Wildcard,
}

fn split_path(p: &str) -> Vec<Seg> {
    let mut out = Vec::new();
    for raw in p.split('.') {
        let mut s = raw;
        // 处理 a[0] / a[*] / a[0][1]
        if let Some(bracket) = s.find('[') {
            let key = &s[..bracket];
            if !key.is_empty() {
                out.push(Seg::Key(key.to_string()));
            }
            s = &s[bracket..];
            let mut rest = s;
            while let Some(start) = rest.find('[') {
                let Some(end) = rest[start..].find(']') else {
                    break;
                };
                let idx = &rest[start + 1..start + end];
                if idx == "*" {
                    out.push(Seg::Wildcard);
                } else if let Ok(i) = idx.parse::<usize>() {
                    out.push(Seg::Index(i));
                }
                rest = &rest[start + end + 1..];
            }
        } else if !s.is_empty() {
            out.push(Seg::Key(s.to_string()));
        }
    }
    out
}

// ─────────────────────────── Trait 实现 ───────────────────────────

#[async_trait]
impl MediaProvider for DeclarativeProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    async fn categories(&self) -> Result<Vec<Category>> {
        let Some(ep) = &self.spec.endpoints.categories else {
            return Ok(vec![]);
        };
        let json = self.fetch(ep, &HashMap::new()).await?;

        let path = ep.map.get(K_ITEMS).map(String::as_str).unwrap_or("$.class");
        let arr = match select(&json, path) {
            serde_json::Value::Array(a) => a,
            serde_json::Value::Null => return Ok(vec![]),
            v => vec![v],
        };

        let id_path = ep.map.get(K_ID).map(String::as_str).unwrap_or("$.type_id");
        let name_path = ep
            .map
            .get(K_TITLE)
            .map(String::as_str)
            .unwrap_or("$.type_name");

        Ok(self.apply_layer("categories", arr
            .iter()
            .filter_map(|n| {
                let id = select(n, id_path).as_str().map(String::from)?;
                let name = select(n, name_path)
                    .as_str()
                    .map(String::from)
                    .unwrap_or_else(|| id.clone());
                Some(Category {
                    id,
                    name,
                    children: vec![],
                })
            })
            .collect::<Vec<Category>>())?)
    }

    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let ep = self
            .spec
            .endpoints
            .list
            .as_ref()
            .ok_or_else(|| ProviderError::unsupported("该源未配置列表端点"))?;

        let mut vars = HashMap::new();
        vars.insert("category".into(), req.category_id.clone());
        vars.insert("page".into(), req.page.to_string());
        for (k, v) in &req.filters {
            vars.insert(k.clone(), v.clone());
        }

        let json = self.fetch(ep, &vars).await?;
        let items = self.map_items(&json, &ep.map);

        // 分页信息（可选）
        let total = select(&json, "$.total").as_u64();
        let page_count = select(&json, "$.pagecount").as_u64().map(|v| v as u32);

        Ok(self.apply_layer("list", Page {
            items,
            page: req.page,
            page_count,
            total,
        })?)
    }

    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        let ep = self
            .spec
            .endpoints
            .search
            .as_ref()
            .ok_or_else(|| ProviderError::unsupported("该源未配置搜索端点"))?;

        let mut vars = HashMap::new();
        vars.insert("keyword".into(), keyword.to_string());
        vars.insert("page".into(), page.to_string());

        let json = self.fetch(ep, &vars).await?;
        Ok(self.apply_layer("search", Page {
            items: self.map_items(&json, &ep.map),
            page,
            page_count: None,
            total: None,
        })?)
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let ep = self
            .spec
            .endpoints
            .detail
            .as_ref()
            .ok_or_else(|| ProviderError::unsupported("该源未配置详情端点"))?;

        let mut vars = HashMap::new();
        vars.insert("id".into(), id.native.clone());

        let json = self.fetch(ep, &vars).await?;
        let items = self.map_items(&json, &ep.map);
        let first = items.first();

        // 剧集解析（`vod_play_url` 的 `$$$` / `#` / `$` 分隔符约定 —— TVBox 生态事实标准）
        let mut episodes = Vec::new();
        let mut sources = Vec::new();
        if let Some(ep_path) = ep.map.get(K_EPISODES) {
            if let Some(raw) = select(&json, ep_path).as_str() {
                let parsed = parse_play_url(raw);
                for (idx, (line_name, eps)) in parsed.iter().enumerate() {
                    sources.push(PlaySource {
                        code: format!("line{idx}"),
                        title: line_name.clone(),
                        count: eps.len() as u32,
                        nested: vec![],
                    });
                    for (i, (title, link)) in eps.iter().enumerate() {
                        episodes.push(Episode {
                            id: link.clone(),
                            title: title.clone(),
                            order: (i + 1) as u32,
                            player_id: Some(format!("line{idx}")),
                            flag: String::new(),
                        });
                    }
                }
            }
        }

        Ok(self.apply_layer("detail", MediaDetail {
            id: id.clone(),
            title: first.map(|i| i.title.clone()).unwrap_or_else(|| id.native.clone()),
            cover: first.and_then(|i| i.cover.clone()),
            description: first.and_then(|i| i.description.clone()),
            badges: vec![],
            kind: if episodes.is_empty() {
                MediaKind::Movie
            } else {
                MediaKind::Series
            },
            meta: serde_json::Map::new(),
            sources,
            episodes,
        })?)
    }

    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        // ★ 单出口：`resolve` 内部有 3 条返回路径（剧集直链 / direct / from_list），
        //   若每条各自套一次覆盖层，将来加第四条就会漏 ——
        //   门禁 `overlay_is_applied_on_all_five_data_methods` 按调用次数 == 5 钉死，
        //   所以这里必须收敛成一个出口。
        let out = self.resolve_candidates(id, req).await?;
        self.apply_layer("resolve", out)
    }

    async fn health_check(&self) -> bool {
        // ★ 刻意**不**套覆盖层：这是探活，不是数据方法
        //   （与 JS 路径的方法名白名单同理 —— 会话/探活结果不该被个性化改写）。
        // 有 categories 就探它，否则探 list
        let (ep, vars) = if let Some(c) = &self.spec.endpoints.categories {
            (c, HashMap::new())
        } else if let Some(l) = &self.spec.endpoints.list {
            let mut v = HashMap::new();
            v.insert("category".to_string(), "1".to_string());
            v.insert("page".to_string(), "1".to_string());
            (l, v)
        } else {
            return false;
        };

        tokio::time::timeout(
            Duration::from_secs(12),
            self.fetch(ep, &vars),
        )
        .await
        .map(|r| r.is_ok())
        .unwrap_or(false)
    }
}

fn spec_headers(spec: &DeclarativeSpec) -> Vec<(String, String)> {
    spec.headers
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}

fn candidate_from_url(url: &str, spec: &DeclarativeSpec) -> StreamCandidate {
    StreamCandidate::new(url, StreamKind::from_url(url))
        .with_label(spec.name.clone())
        .with_headers(spec_headers(spec))
}

/// 解析 TVBox 生态的 `vod_play_url` 编码（**事实标准**，跨 TVBox/zyfun/CatVod）
///
/// ```text
/// "线路A$$$线路B"          —— `$$$` 分隔线路
/// "第1集$url1#第2集$url2"  —— `#` 分隔剧集，`$` 分隔「剧名与地址」
/// ```
pub fn parse_play_url(raw: &str) -> Vec<(String, Vec<(String, String)>)> {
    raw.split("$$$")
        .enumerate()
        .map(|(li, line)| {
            let name = format!("线路{}", li + 1);
            let eps: Vec<(String, String)> = line
                .split('#')
                .filter(|s| !s.trim().is_empty())
                .map(|item| match item.split_once('$') {
                    Some((t, u)) => (t.trim().to_string(), u.trim().to_string()),
                    None => (item.trim().to_string(), item.trim().to_string()),
                })
                .filter(|(_, u)| !u.is_empty())
                .collect();
            (name, eps)
        })
        .filter(|(_, eps)| !eps.is_empty())
        .collect()
}

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jsonpath_subset_works() {
        let v: serde_json::Value = serde_json::json!({
            "class": [{"type_id":"1","type_name":"电影"}],
            "data": {"list": [{"vod_id":"a"},{"vod_id":"b"}]}
        });
        assert_eq!(select(&v, "$.class").as_array().unwrap().len(), 1);
        assert_eq!(select(&v, "$.class[0].type_name").as_str().unwrap(), "电影");
        assert_eq!(select(&v, "$.data.list[1].vod_id").as_str().unwrap(), "b");
        assert_eq!(select(&v, "$.data.list").as_array().unwrap().len(), 2);
        // 裸路径也支持
        assert_eq!(select(&v, "data.list[0].vod_id").as_str().unwrap(), "a");
    }

    #[test]
    fn tvbox_play_url_separators_parsed() {
        // 生态事实标准：$$$ 分线路，# 分集，$ 分「名与址」
        let raw = "第1集$http://a/1.m3u8#第2集$http://a/2.m3u8$$$第1集$http://b/1.m3u8";
        let parsed = parse_play_url(raw);
        assert_eq!(parsed.len(), 2, "应解析出 2 条线路");
        assert_eq!(parsed[0].1.len(), 2, "线路1 应有 2 集");
        assert_eq!(parsed[1].1.len(), 1, "线路2 应有 1 集");
        assert_eq!(parsed[0].1[0].1, "http://a/1.m3u8");
    }

    #[test]
    fn rejects_invalid_spec() {
        assert!(DeclarativeProvider::from_json("{}").is_err());
        assert!(DeclarativeProvider::from_json(
            r#"{"id":"x","name":"X","base":"ftp://bad"}"#
        )
        .is_err());
    }

    #[test]
    fn accepts_valid_spec() {
        let spec = r#"{
            "id":"demo","name":"示例站","base":"https://api.example.com",
            "endpoints":{
                "list":{"path":"/list","params":{"ac":"videolist","t":"{category}","pg":"{page}"},
                        "map":{"items":"$.list","id":"$.vod_id","title":"$.vod_name"}}
            }
        }"#;
        let p = DeclarativeProvider::from_json(spec).unwrap();
        assert_eq!(p.manifest().id, "demo");
        assert!(p.manifest().capabilities.vod);
    }

    #[test]
    fn build_url_substitutes_params() {
        let spec = r#"{
            "id":"demo","name":"D","base":"https://api.x.com",
            "endpoints":{"list":{"path":"/vod","params":{"t":"{category}","pg":"{page}"}}}
        }"#;
        let p = DeclarativeProvider::from_json(spec).unwrap();
        let ep = p.spec.endpoints.list.as_ref().unwrap();
        let mut vars = HashMap::new();
        vars.insert("category".to_string(), "1".to_string());
        vars.insert("page".to_string(), "3".to_string());
        let u = p.build_url(ep, &vars);
        assert!(u.starts_with("https://api.x.com/vod?"));
        assert!(u.contains("t=1"));
        assert!(u.contains("pg=3"));
    }

    // ═══════════════════════════════════════════════════════════════════
    //  P5：声明式源接入源个性化覆盖层（2026-10-24）
    // ═══════════════════════════════════════════════════════════════════
    //
    // # 这一组防的是什么
    //
    // 覆盖层原先只挂在 `plugins/mod.rs::PluginProvider::call_js`（:2007），
    // 而声明式源**不经 call_js**（`providers/declarative.rs` 自己 reqwest 拉取）
    // ⇒ 对声明式源写 `overrides/<id>.json` 曾经**一次都不生效**，
    //   而且不报错、不打日志 —— 最难查的那种"配了但没反应"。
    //
    // # 为什么用真 TcpListener 而不是 mock
    //
    // 覆盖层挂在 `map_items()` / 模型构造**之后**，所以必须让真实
    // `fetch()` → 真实 JSON → 真实 `map_items()` 跑完，才能证明
    // "覆盖层吃的是归一化后的 `title`，不是站点原始字段 `vod_name`"。
    // mock 掉网络就验不到这一层。写法照 `tests/t9_episode_and_entities.rs:60`，
    // 不引新依赖。

    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;

    /// 本地假苹果CMS接口 —— 返回一条两集的内容
    ///
    /// 每次请求都回同一份 body（不区分路径/参数）：
    /// `list` / `detail` / `search` 三条链路都能跑。
    fn spawn_fake_cms() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 失败");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut s) = stream else { continue };
                let mut reader = BufReader::new(s.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    continue;
                }
                // 读掉请求头
                loop {
                    let mut h = String::new();
                    if reader.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                        break;
                    }
                }
                let body = r#"{"code":1,"total":2,"pagecount":1,
"list":[
 {"vod_id":"m1","vod_name":"原始标题一","vod_pic":"http://c/1.jpg","vod_remarks":"更新至2集",
  "vod_content":"原始简介",
  "vod_play_url":"第1集$http://cdn.test/e1.m3u8#第2集$http://cdn.test/e2.m3u8"},
 {"vod_id":"m2","vod_name":"原始标题二","vod_pic":"http://c/2.jpg","vod_remarks":"",
  "vod_content":"原始简介2","vod_play_url":""}
]}"#;
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.as_bytes().len(),
                    body
                );
                let _ = s.write_all(resp.as_bytes());
                let _ = s.flush();
            }
        });
        format!("http://127.0.0.1:{port}/api.php/provide/vod")
    }

    /// 一份完整的声明式源 spec（list + detail + search 都指向假站点）
    fn spec_json(id: &str, base: &str) -> String {
        format!(
            r#"{{
  "id":"{id}","name":"覆盖层测试源","base":"{base}",
  "capabilities":{{"vod":true,"search":true}},
  "endpoints":{{
    "list":{{
      "path":"","params":{{"ac":"videolist","t":"{{category}}","pg":"{{page}}"}},
      "map":{{"items":"$.list","id":"$.vod_id","title":"$.vod_name",
              "cover":"$.vod_pic","subtitle":"$.vod_remarks","description":"$.vod_content"}}
    }},
    "search":{{
      "path":"","params":{{"wd":"{{keyword}}","ac":"videolist"}},
      "map":{{"items":"$.list","id":"$.vod_id","title":"$.vod_name","subtitle":"$.vod_remarks"}}
    }},
    "detail":{{
      "path":"","params":{{"ac":"detail","ids":"{{id}}"}},
      "map":{{"items":"$.list","id":"$.vod_id","title":"$.vod_name",
              "cover":"$.vod_pic","description":"$.vod_content","episodes":"$.list[0].vod_play_url"}}
    }}
  }}
}}"#
        )
    }

    fn tmpdir(tag: &str) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!(
            "sourin_decl_ovr_{tag}_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    /// 把一份覆盖层写进 `<dir>/overrides/<id>.json`
    fn write_layer(dir: &std::path::Path, layer: &crate::overrides::OverrideLayer) {
        crate::overrides::save_layer(dir, layer).expect("写覆盖层失败");
    }

    /// 一份只做 L1 常量覆盖的最小层
    fn layer_set(id: &str, to: &str, value: &str) -> crate::overrides::OverrideLayer {
        crate::overrides::OverrideLayer {
            target_id: id.to_string(),
            enabled: true,
            methods: vec![],
            mappings: vec![crate::overrides::MapRule::Set {
                to: to.to_string(),
                value: serde_json::Value::String(value.to_string()),
            }],
            transforms: vec![],
            js_hook: String::new(),
            note: "P5 门禁".into(),
        }
    }

    fn rt() -> tokio::runtime::Runtime {
        tokio::runtime::Runtime::new().unwrap()
    }

    fn list_req() -> ListRequest {
        ListRequest {
            category_id: "1".into(),
            page: 1,
            filters: Default::default(),
        }
    }

    /// ★ A1 正向：声明式源也能被覆盖层改写
    ///
    /// 断言的是**用户可见的结果**（`subtitle` 变成覆盖层的值），
    /// 而不是"某个函数被调用了"。没挂 `apply_layer` 时这条必红。
    #[test]
    fn declarative_list_is_overridden_by_layer() {
        let base = spawn_fake_cms();
        let dir = tmpdir("a1");
        let p = DeclarativeProvider::from_json(&spec_json("decl_a1", &base))
            .unwrap()
            .with_data_dir(dir.clone());

        // 先确认原始数据长什么样（否则"被改写"可能是假象）
        let raw = rt().block_on(p.list(list_req())).expect("list 失败");
        assert_eq!(raw.items.len(), 2, "假站点应有 2 条");
        assert_eq!(raw.items[0].subtitle.as_deref(), Some("更新至2集"),
            "前置条件：未加覆盖层时必须是站点原值");

        write_layer(&dir, &layer_set("decl_a1", "subtitle", "已个性化"));

        let got = rt().block_on(p.list(list_req())).expect("list 失败");
        assert_eq!(got.items.len(), 2, "覆盖层不该改变条数");
        assert_eq!(got.items[0].subtitle.as_deref(), Some("已个性化"),
            "★ 声明式源的 list 必须被覆盖层改写");
        // ★ 关键：改的是**归一化后的 subtitle**，不是站点原始字段 vod_remarks
        //   （后者根本不会出现在 MediaItem 上 —— 这正是挂载位置正确的证据）
        assert_eq!(got.items[0].title, "原始标题一",
            "未被规则触及的字段必须保持原样");
    }

    /// ★ A2 阴性对照：无覆盖层 ⇒ 输出与原行为**逐字节一致**
    ///
    /// 两组对照：
    /// ① 挂 data_dir 但目录里**没有** layer 文件（Absent）
    /// ② 压根不挂 data_dir（`data_dir=None`）
    /// 两者的序列化结果必须与"从未有过覆盖层"完全相同。
    #[test]
    fn no_layer_is_byte_identical() {
        let base = spawn_fake_cms();
        let dir = tmpdir("a2");
        let spec = spec_json("decl_a2", &base);

        let with_dir = DeclarativeProvider::from_json(&spec)
            .unwrap()
            .with_data_dir(dir.clone());
        let without = DeclarativeProvider::from_json(&spec).unwrap();

        let a = rt().block_on(with_dir.list(list_req())).expect("list 失败");
        let b = rt().block_on(without.list(list_req())).expect("list 失败");

        let ja = serde_json::to_string(&a).unwrap();
        let jb = serde_json::to_string(&b).unwrap();
        assert_eq!(ja, jb, "★ 无覆盖层时「挂了目录」与「没挂目录」必须逐字节一致");
        // 也钉住具体值，防止两边一起漂
        assert_eq!(a.items[0].subtitle.as_deref(), Some("更新至2集"));
        assert_eq!(a.items[0].title, "原始标题一");
    }

    /// ★ A3 阴性对照2：`enabled=false` / 文件损坏 ⇒ 原样透出，且**不返回 Err**
    ///
    /// 覆盖层坏掉绝不能把源弄挂 —— 这是 `overrides.rs` 模块头的铁律 2。
    #[test]
    fn disabled_or_broken_layer_passes_through() {
        let base = spawn_fake_cms();
        let dir = tmpdir("a3");
        let p = DeclarativeProvider::from_json(&spec_json("decl_a3", &base))
            .unwrap()
            .with_data_dir(dir.clone());

        let baseline = serde_json::to_string(&rt().block_on(p.list(list_req())).unwrap()).unwrap();

        // ① enabled=false
        let mut off = layer_set("decl_a3", "subtitle", "不该出现");
        off.enabled = false;
        write_layer(&dir, &off);
        let got = rt().block_on(p.list(list_req()))
            .expect("★ enabled=false 时绝不能报错");
        assert_eq!(serde_json::to_string(&got).unwrap(), baseline,
            "★ enabled=false ⇒ 必须原样透出（逐字节一致）");

        // ② 文件损坏（Broken）
        let path = crate::overrides::layer_path(&dir, "decl_a3");
        std::fs::write(&path, b"{ this is not json ").unwrap();
        let got2 = rt().block_on(p.list(list_req()))
            .expect("★ 覆盖层损坏时绝不能报错，必须原样透出");
        assert_eq!(serde_json::to_string(&got2).unwrap(), baseline,
            "★ Broken ⇒ 必须原样透出（逐字节一致），不能静默清空");

        // ③ 删除后完全回到原行为
        std::fs::remove_file(&path).unwrap();
        let got3 = rt().block_on(p.list(list_req())).unwrap();
        assert_eq!(serde_json::to_string(&got3).unwrap(), baseline,
            "★ 删除覆盖层 = 完全回到原行为");
    }

    /// ★ A4 方法白名单：`methods:["detail"]` ⇒ `list()` 不受影响
    ///
    /// 这条防的是"白名单被写成黑名单/被绕过" —— 一旦绕过，
    /// 用户只给详情页配的规则会污染列表页。
    #[test]
    fn method_whitelist_filters_list() {
        let base = spawn_fake_cms();
        let dir = tmpdir("a4");
        let p = DeclarativeProvider::from_json(&spec_json("decl_a4", &base))
            .unwrap()
            .with_data_dir(dir.clone());

        let baseline = serde_json::to_string(&rt().block_on(p.list(list_req())).unwrap()).unwrap();

        let mut only_detail = layer_set("decl_a4", "subtitle", "只该在详情页出现");
        only_detail.methods = vec!["detail".into()];
        write_layer(&dir, &only_detail);

        // ① list 不在白名单 ⇒ 逐字节不变
        let got = rt().block_on(p.list(list_req())).unwrap();
        assert_eq!(serde_json::to_string(&got).unwrap(), baseline,
            "★ methods=[detail] 时 list 必须逐字节不变");

        // ② 但 detail 必须生效（证明白名单不是"整层失效"）
        let detail = rt()
            .block_on(p.detail(&MediaId::new("decl_a4", "m1")))
            .expect("detail 失败");
        assert_eq!(detail.badges.len(), 0, "前置条件");
        // detail 的 title 来自第一条 item，被 set 改的是 subtitle —— 详情页没有 subtitle
        // ⇒ 改 title 来验证（同一份 layer 在 detail 上必须真的生效）
        let mut only_detail2 = layer_set("decl_a4", "title", "详情页标题");
        only_detail2.methods = vec!["detail".into()];
        write_layer(&dir, &only_detail2);
        let detail2 = rt()
            .block_on(p.detail(&MediaId::new("decl_a4", "m1")))
            .expect("detail 失败");
        assert_eq!(detail2.title, "详情页标题",
            "★ 白名单内的 detail 必须真的生效（否则白名单=整层失效）");
    }

    /// ★ A5 三层一致：L2 变换与 L3 JS 劫持在声明式源上同样生效
    ///
    /// 防的是"只接了 L1" —— 那样 P5 只算接了一半。
    #[test]
    fn transforms_and_js_hook_work_on_declarative() {
        let base = spawn_fake_cms();
        let dir = tmpdir("a5");
        let p = DeclarativeProvider::from_json(&spec_json("decl_a5", &base))
            .unwrap()
            .with_data_dir(dir.clone());

        // ① L2：只留 1 条
        let mut l2 = layer_set("decl_a5", "subtitle", "占位");
        l2.mappings.clear();
        l2.transforms = vec![crate::overrides::TransformRule::TakeFirst { limit: 1 }];
        write_layer(&dir, &l2);
        let got = rt().block_on(p.list(list_req())).unwrap();
        assert_eq!(got.items.len(), 1, "★ L2 take_first 必须在声明式源上生效");

        // ② L3：JS 劫持把标题全改掉
        let mut l3 = layer_set("decl_a5", "subtitle", "占位");
        l3.mappings.clear();
        l3.js_hook = "data.items.forEach(i => { i.title = 'JS改的'; }); return data;".into();
        write_layer(&dir, &l3);
        let got3 = rt().block_on(p.list(list_req())).unwrap();
        assert_eq!(got3.items.len(), 2, "L3 不该改变条数");
        assert_eq!(got3.items[0].title, "JS改的",
            "★ L3 JS 劫持必须在声明式源上生效");
        assert_eq!(got3.items[1].title, "JS改的");
    }

    /// ★ A6 fail-safe：覆盖层把数据改坏 ⇒ **原样透出**，不报错、不空列表
    ///
    /// 用 `rename` 把必填的 `title` 搬走 ⇒ `from_value::<Page<MediaItem>>` 必然失败。
    /// 正确的处置是"记日志 + 用原始数据"，绝不能让源因此不可用。
    #[test]
    fn malformed_override_falls_back_to_original() {
        let base = spawn_fake_cms();
        let dir = tmpdir("a6");
        let p = DeclarativeProvider::from_json(&spec_json("decl_a6", &base))
            .unwrap()
            .with_data_dir(dir.clone());

        let baseline = serde_json::to_string(&rt().block_on(p.list(list_req())).unwrap()).unwrap();

        // rename 掉 title（不 keep）⇒ MediaItem.title 缺失 ⇒ 反序列化必失败
        let mut bad = layer_set("decl_a6", "x", "y");
        bad.mappings = vec![crate::overrides::MapRule::Rename {
            from: "title".into(),
            to: "title_moved".into(),
            keep: false,
        }];
        write_layer(&dir, &bad);

        let got = rt().block_on(p.list(list_req()))
            .expect("★ 覆盖层产物不合法时绝不能报错");
        assert_eq!(got.items.len(), 2, "★ 也不能返回空列表");
        assert_eq!(got.items[0].title, "原始标题一",
            "★ 必须原样透出原始数据（fail-safe）");
        assert_eq!(serde_json::to_string(&got).unwrap(), baseline,
            "★ 与「从未配置覆盖层」逐字节一致");
    }

    /// ★ 门禁：五个数据方法**都**挂了覆盖层
    ///
    /// # 为什么用源码断言
    ///
    /// 这是本仓 `save_hook` "两条路径发散"教训的小规模版本：
    /// 将来加 `live` / `epg` / `danmaku` 时忘了挂 `apply_layer`，
    /// 表现为"配了覆盖层但那个页面没反应"，且**不报错**。
    ///
    /// 判据取 `self.apply_layer(` 的**出现次数 == 5**（categories/list/search/detail/resolve），
    /// 且五个方法名各出现一次 —— 只数总数会被"一个方法挂两次、另一个没挂"骗过。
    ///
    /// ⚠️ `health_check` **不该**出现（探活不是数据方法，与 JS 路径的白名单同理）。
    #[test]
    fn overlay_is_applied_on_all_five_data_methods() {
        let src = include_str!("declarative.rs");

        /*
         * ⚠️ 判据是 `self.apply_layer("`（**带左引号**），不是 `self.apply_layer(`。
         *
         * 两次踩坑记录：
         * ① 第一版没截测试模块 ⇒ 数出 10（实现 5 + 本测试里的 5 处字面量）；
         * ② 截了之后仍数出 6 —— 因为实现区里有一处**文档注释**写着
         *    `门禁按 self.apply_layer( 的调用次数 == 5 钉死`，被算成了调用点。
         *
         * 带引号只匹配**真的传了方法名**的调用，注释里那句没有引号 ⇒ 不计入。
         * 这不是放宽断言：多挂一次、少挂一次都仍然会红。
         */
        let impl_only = src
            .split("#[cfg(test)]")
            .next()
            .expect("源码里必然有实现区");

        let calls = impl_only.matches("self.apply_layer(\"").count();
        assert_eq!(
            calls, 5,
            "★ 覆盖层调用点必须恰好 5 处（categories/list/search/detail/resolve），实际 {calls}。\n\
             少一处 = 某个数据方法没接覆盖层（配了没反应）；\n\
             多一处 = 有方法挂了两遍（同一次请求套两层，语义不可推理）。"
        );

        for m in ["categories", "list", "search", "detail", "resolve"] {
            let needle = format!("self.apply_layer(\"{m}\"");
            assert!(
                impl_only.contains(&needle),
                "★ 方法 {m} 必须挂覆盖层（找不到 `{needle}`）—— \
                 新增数据方法时忘了挂，表现为「配了覆盖层但该页面没反应」且不报错"
            );
        }

        // health_check 是探活，不是数据方法 ⇒ 不该被覆盖层改写
        let hc_start = impl_only.find("async fn health_check").expect("必须有 health_check");
        let hc_body = &impl_only[hc_start..(hc_start + 1200).min(impl_only.len())];
        assert!(
            !hc_body.contains("self.apply_layer("),
            "★ health_check 不该套覆盖层（探活不是数据方法，与 JS 路径白名单同理）"
        );
    }

    /// ★ 门禁：**两个构造点都**挂了 `with_data_dir`
    ///
    /// # 这条防的是一个最难查的分裂
    ///
    /// 声明式源有两处构造点：
    /// ① `state.rs` 启动恢复（`PersistedProvider::Declarative`）
    /// ② `commands_remote.rs` `import_declarative_provider`
    ///
    /// 只挂一处 ⇒ **导入后能用、重启后失效**（或反之）。
    /// 两个文件都在 `providers/` 之外，光跑本模块的测试**抓不到**，
    /// 所以只能读源码断言。这是本仓"两条路径发散"教训的直接移植。
    #[test]
    fn overlay_is_wired_on_both_construction_sites() {
        let state_src = include_str!("../state.rs");
        assert!(
            state_src.contains("DeclarativeProvider::from_json(json)")
                && state_src.contains(".map(|p| p.with_data_dir(data_dir.clone()))"),
            "★ state.rs 的启动恢复路径必须给声明式源挂 data_dir，\
             否则重启后覆盖层静默失效（导入时还正常，最难查）"
        );

        let remote_src = include_str!("../commands_remote.rs");
        assert!(
            remote_src.contains("DeclarativeProvider::from_json(json)")
                && remote_src.contains(".map(|p| p.with_data_dir(state.data_dir.clone()))"),
            "★ commands_remote.rs 的导入路径必须给声明式源挂 data_dir，\
             否则刚导入的源覆盖层不生效（重启后才生效 —— 同样是分裂）"
        );

        // 反面对照：全仓 `DeclarativeProvider::from_json` 的构造点必须**只有这两处**
        // （多出第三处而没挂 with_data_dir，就是新的漏洞）
        let providers_src = include_str!("mod.rs");
        assert!(!providers_src.contains("from_json(json).unwrap()"),
            "providers/mod.rs 不该自己构造声明式源");
    }
}
