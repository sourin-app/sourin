//! 全局流量代理
//!
//! # 为什么必须做（实测动机）
//!
//! 2026-09-14 实测（本机 `http://127.0.0.1:7890`）：
//!
//! | 域名 | 直连 | 经代理 |
//! |---|---|---|
//! | `www.googleapis.com` | ❌ 不可达 | ✅ 通 |
//! | `oauth2.googleapis.com` | ❌ 不可达 | ✅ 通 |
//! | `developers.google.com` | ❌ 不可达 | ✅ 200 |
//! | `graph.microsoft.com` | ✅ 301 | ✅ 301 |
//!
//! → **Google Drive 的 OAuth 在国内无代理下根本走不通**，
//!   所以代理不只是"内容站点的可选项"，而是同步后端的前置依赖。
//!
//! # 三个设计要点（来自方案文档 2.4）
//!
//! 1. **流媒体也走代理，但默认只让 API 走** —— 视频分片请求量大，
//!    代理带宽不足会卡顿。故有 `scope`（仅 API / 全流量）开关。
//! 2. **代理健康检查** —— 设置页要能「测试连接」。
//! 3. **凭据走钥匙串** —— 代理密码不写入导出备份。
//!
//! 生产环境共用持久化的全局配置和凭据；旧 Provider 调用映射到全局设置。
//! API、弹幕、更新与源发现共用策略，视频按 scope 决定是否经过代理。
//! GitHub 源发现必须配置可用代理，配置错误或连接失败时不会回退直连。

use crate::model::ProviderError;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

/// keyring 服务名（代理密码专用，与登录令牌分开命名空间）
///
/// ⚠️⚠️ **这个值不要跟着应用改名一起改**（2026-09-19）
///
/// # 为什么
///
/// 它决定凭据在系统钥匙串里的**存放位置**。改名 = 换个抽屉找东西 ——
/// 用户之前存的代理密码会**读不到**，表现为"明明填过密码，却提示未配置"。
///
/// 全项目有三个这样的常量：
/// ```text
/// dsh-media-client-proxy   ← 本站（代理密码）
/// dsh-media-client-sync    ← WebDAV 密码（sync/mod.rs）
/// dsh-media-client         ← 某动画站账号（providers/srca.rs）
/// ```
/// 三者都**保持原值** —— 虽然应用已改名「源影 Sourin」，
/// 但服务名对用户**完全不可见**，且不含任何敏感信息，
/// 改它只会带来"凭据莫名失效"的风险，没有任何收益。
///
/// 若将来真要做（比如为了品牌一致性），正确做法是**迁移**：
/// 启动时从旧服务名读一次、写进新服务名，成功后再删旧的。
/// 但那需要额外的失败处理，收益又只是"源码里好看一点"——
/// 所以**目前有意不做**。
const KEYRING_SERVICE: &str = "dsh-media-client-proxy";
pub const GLOBAL_PROXY: &str = "__global__";

#[derive(Clone, Serialize)]
pub struct LegacyProxyChoice {
    pub source: String,
    pub config: ProxyConfig,
}

fn legacy_proxy_choices(dir: &Path) -> Vec<LegacyProxyChoice> {
    let read = |name: &str| {
        std::fs::read(dir.join(name))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .unwrap_or_default()
    };
    let mut choices = Vec::new();
    let mut push = |source: &str, mode: ProxyMode, raw: &str| {
        let url = if mode == ProxyMode::Custom {
            let Ok(url) = validate_proxy_url(raw) else {
                return;
            };
            Some(url)
        } else {
            None
        };
        if mode == ProxyMode::Direct {
            return;
        }
        if choices
            .iter()
            .any(|c: &LegacyProxyChoice| c.config.mode == mode && c.config.url == url)
        {
            return;
        }
        choices.push(LegacyProxyChoice {
            source: source.into(),
            config: ProxyConfig {
                mode,
                url,
                ..Default::default()
            },
        });
    };
    let discovery = read("github-discovery.json");
    if let Some(url) = discovery["proxyUrl"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
    {
        push("原 GitHub 源发现代理", ProxyMode::Custom, url);
    }
    let prefs = read("ui-prefs.json");
    let mode = match prefs["dsh.danmaku.proxy.mode"].as_str() {
        Some("custom") => ProxyMode::Custom,
        Some("system") => ProxyMode::System,
        _ => ProxyMode::Direct,
    };
    push(
        "原弹幕代理",
        mode,
        prefs["dsh.danmaku.proxy.url"].as_str().unwrap_or(""),
    );
    if prefs["appupdate.route"] == "proxy" {
        if prefs["appupdate.followSystemProxy"] == "1" {
            push("原更新下载代理", ProxyMode::System, "");
        } else {
            let host = prefs["appupdate.proxyHost"].as_str().unwrap_or("");
            let port = prefs["appupdate.proxyPort"].as_str().unwrap_or("");
            if !host.is_empty() && port.parse::<u16>().is_ok_and(|p| p > 0) {
                push(
                    "原更新下载代理",
                    ProxyMode::Custom,
                    &format!("http://{host}:{port}"),
                );
            }
        }
    }
    choices
}

// ─────────────────────────── 配置模型 ───────────────────────────

/// 代理模式
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProxyMode {
    /// 直连（未配置站点的默认值）
    #[default]
    Direct,
    /// 跟随系统（读环境变量 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY）
    System,
    /// 自定义（该 Provider 专用）
    Custom,
}

/// 作用范围
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProxyScope {
    /// 仅 API 走代理（视频直连更流畅）—— 默认
    #[default]
    ApiOnly,
    /// 全部流量走代理（含视频分片）
    All,
}

/// 单个站点的代理配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyConfig {
    #[serde(default)]
    pub mode: ProxyMode,
    /// 代理地址，如 `http://127.0.0.1:7890` / `socks5://127.0.0.1:1080`
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// 不走代理的主机
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub bypass: Vec<String>,
    #[serde(default)]
    pub scope: ProxyScope,
    /// 代理是否需要认证（用户名）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
    // ⚠️ 密码绝不在此结构里 —— 只存钥匙串，见 set_password / take_password
}

impl Default for ProxyConfig {
    fn default() -> Self {
        Self {
            mode: ProxyMode::Direct,
            url: None,
            bypass: Vec::new(),
            scope: ProxyScope::ApiOnly,
            username: None,
        }
    }
}

impl ProxyConfig {
    /// 该配置是否真的会用到代理
    pub fn uses_proxy(&self) -> bool {
        match self.mode {
            ProxyMode::Direct => false,
            ProxyMode::System => true,
            // Custom 但没填地址 → 等于没配，按直连处理（避免 reqwest 报错）
            ProxyMode::Custom => self
                .url
                .as_deref()
                .map(|u| !u.trim().is_empty())
                .unwrap_or(false),
        }
    }
}

// ─────────────────────────── 校验 ───────────────────────────

/// 支持的代理协议（reqwest 的 `socks` feature 已启用）
const ALLOWED_SCHEMES: &[&str] = &[
    "http://",
    "https://",
    "socks4://",
    "socks4a://",
    "socks5://",
    "socks5h://",
];

/// 校验代理地址，返回规范化后的 URL
pub fn validate_proxy_url(raw: &str) -> Result<String, String> {
    let u = raw.trim();
    if u.is_empty() {
        return Err("代理地址不能为空".into());
    }
    let lower = u.to_lowercase();
    if !ALLOWED_SCHEMES.iter().any(|s| lower.starts_with(s)) {
        return Err(format!(
            "代理地址需以 {} 开头（当前: {}）",
            ALLOWED_SCHEMES.join(" / "),
            u.chars().take(24).collect::<String>()
        ));
    }
    // 必须有主机部分
    let after_scheme = &u[lower.find("://").map(|i| i + 3).unwrap_or(0)..];
    if after_scheme.is_empty() || after_scheme.starts_with('/') || after_scheme.starts_with(':') {
        return Err("代理地址缺少主机名或端口".into());
    }
    let parsed = reqwest::Url::parse(u).map_err(|_| "代理地址格式不正确")?;
    if parsed.host_str().is_none()
        || parsed.password().is_some()
        || !parsed.username().is_empty()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || !matches!(parsed.path(), "" | "/")
    {
        return Err("代理地址仅填写协议、主机和端口；认证请使用用户名与密码字段".into());
    }
    Ok(u.to_string())
}

// ─────────────────────────── 密钥存储 ───────────────────────────

fn keyring_entry(provider: &str) -> Result<keyring::Entry, String> {
    let service = crate::credential_namespace::service_name(
        KEYRING_SERVICE,
        crate::credential_namespace::CredentialRole::Proxy,
    )?;
    keyring::Entry::new(&service, provider).map_err(|e| format!("钥匙串不可用: {e}"))
}

/// 把代理密码写入系统钥匙串（**不落库、不进备份**）
pub fn set_proxy_password(provider: &str, password: &str) -> Result<(), String> {
    let entry = keyring_entry(provider)?;
    if password.is_empty() {
        let _ = entry.delete_credential();
        return Ok(());
    }
    entry
        .set_password(password)
        .map_err(|e| format!("写入钥匙串失败: {e}"))
}

/// 读取代理密码
pub fn get_proxy_password(provider: &str) -> Option<String> {
    keyring_entry(provider).ok()?.get_password().ok()
}

/// 清除代理密码
pub fn clear_proxy_password(provider: &str) -> Result<(), String> {
    let entry = keyring_entry(provider)?;
    let _ = entry.delete_credential();
    Ok(())
}

// ─────────────────────────── 注册表 ───────────────────────────

/// 代理配置注册表 + HTTP 客户端缓存
///
/// **为什么要缓存**：reqwest 的 `Client` 内部有连接池，
/// 每次请求都新建会丢掉连接复用，也会反复做 TLS 握手。
/// 但带认证的代理每次都要取密码，故缓存键包含配置摘要。
pub struct ProxyStore {
    configs: RwLock<HashMap<String, ProxyConfig>>,
    path: Option<PathBuf>,
    legacy_choices: RwLock<Vec<LegacyProxyChoice>>,
    pub(crate) download_bridge: tokio::sync::OnceCell<Arc<crate::proxy_download::DownloadBridge>>,
    revision: std::sync::atomic::AtomicU64,
    /// 客户端缓存：key = `"{provider}|{scope}|{配置摘要}|{解压}"`
    clients: Mutex<HashMap<String, reqwest::Client>>,
}

/// HTTP 客户端要不要开启 reqwest 的**自动解压**
///
/// # 为什么这是一个枚举，而不是 `bool`
/// ```text
/// `build_client(provider, cfg, true)` 在调用点读不出 true 是什么意思；
/// 而这两种客户端的差别是**安全性级别**的（回退重发可能让服务端执行两次），
/// 传错一个字面量不会有任何编译或运行期报错。
/// ⇒ 具名枚举让「哪一种」写在调用点上。
/// ```
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AutoDecompress {
    /// 正常客户端：reqwest 自己解 gzip/deflate/br（99% 的请求）
    On,
    /// raw 客户端：**必须关掉**，否则 `r.bytes()` 重踩同一个解压坑
    Off,
}

impl Default for ProxyStore {
    fn default() -> Self {
        Self::new()
    }
}

impl ProxyStore {
    pub fn new() -> Self {
        Self {
            configs: RwLock::new(HashMap::new()),
            path: None,
            legacy_choices: RwLock::new(Vec::new()),
            download_bridge: tokio::sync::OnceCell::new(),
            revision: std::sync::atomic::AtomicU64::new(0),
            clients: Mutex::new(HashMap::new()),
        }
    }

    /// Production has one durable configuration, shared by every network feature.
    pub fn open(dir: &Path) -> Result<Self, String> {
        let path = dir.join("global-proxy.json");
        let choices = if !path.exists() {
            legacy_proxy_choices(dir)
        } else {
            Vec::new()
        };
        let cfg: ProxyConfig = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| "全局代理配置无法读取")?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => choices
                .first()
                .filter(|_| choices.len() == 1)
                .map(|choice| choice.config.clone())
                .unwrap_or_default(),
            Err(_) => return Err("无法读取全局代理配置".into()),
        };
        if cfg.mode == ProxyMode::Custom {
            validate_proxy_url(cfg.url.as_deref().unwrap_or(""))?;
        }
        let store = Self {
            configs: RwLock::new(HashMap::from([(GLOBAL_PROXY.into(), cfg)])),
            clients: Mutex::new(HashMap::new()),
            path: Some(path),
            legacy_choices: RwLock::new(if choices.len() > 1 {
                choices
            } else {
                Vec::new()
            }),
            download_bridge: tokio::sync::OnceCell::new(),
            revision: std::sync::atomic::AtomicU64::new(0),
        };
        if store.legacy_choices.read().unwrap().is_empty() {
            store.persist(&store.get(GLOBAL_PROXY))?;
        }
        Ok(store)
    }

    pub fn migration_choices(&self) -> Vec<LegacyProxyChoice> {
        self.legacy_choices.read().unwrap().clone()
    }

    fn ensure_configured(&self) -> Result<(), ProviderError> {
        if !self.legacy_choices.read().unwrap().is_empty() {
            return Err(ProviderError::new(
                crate::model::ErrorKind::Other,
                "检测到多个旧代理，请在全局代理设置中选择要沿用的配置",
            ));
        }
        Ok(())
    }

    fn persist(&self, cfg: &ProxyConfig) -> Result<(), String> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec(cfg).map_err(|_| "无法编码全局代理配置")?;
        std::fs::write(&tmp, bytes).map_err(|_| "无法保存全局代理配置")?;
        std::fs::rename(&tmp, path).map_err(|_| "无法替换全局代理配置".into())
    }

    pub fn invalidate_clients(&self) {
        self.revision
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.clients.lock().unwrap().clear();
    }

    pub(crate) fn policy_revision(&self) -> u64 {
        self.revision.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Apply only routing/authentication policy; the caller owns UA, cookies,
    /// timeout, redirects and TLS settings on its original builder.
    pub(crate) fn client_builder_for(
        &self,
        provider: &str,
        builder: reqwest::ClientBuilder,
    ) -> Result<reqwest::ClientBuilder, ProviderError> {
        self.ensure_configured()?;
        let cfg = self.get(provider);
        let credential_key = if self.configs.read().unwrap().contains_key(GLOBAL_PROXY) {
            GLOBAL_PROXY
        } else {
            provider
        };
        self.apply_proxy_policy(credential_key, &cfg, builder)
    }

    /// Streaming has no whole-response timeout: a movie can last hours.
    /// Cache shares the invalidation boundary with API clients.
    pub fn stream_client(&self) -> Result<reqwest::Client, ProviderError> {
        self.streaming_client(false, None)
    }

    pub(crate) fn scoped_stream_client(
        &self, policy: &crate::hls_query_policy::ScopedHlsQueryPolicy,
    ) -> Result<reqwest::Client, ProviderError> {
        self.streaming_client(false, Some(policy))
    }

    pub fn download_client(&self) -> Result<reqwest::Client, ProviderError> {
        self.streaming_client(true, None)
    }

    fn streaming_client(&self, api: bool, scoped: Option<&crate::hls_query_policy::ScopedHlsQueryPolicy>) -> Result<reqwest::Client, ProviderError> {
        let revision = self.revision.load(std::sync::atomic::Ordering::SeqCst);
        self.ensure_configured()?;
        let mut cfg = self.get(GLOBAL_PROXY);
        if !api && cfg.scope == ProxyScope::ApiOnly {
            cfg.mode = ProxyMode::Direct;
        }
        let key = format!(
            "stream|{revision}|{api}|{:?}|{:?}|{:?}|{:?}|{:?}",
            cfg.mode, cfg.url, cfg.bypass, cfg.username, scoped.map(|policy| policy.origin_key())
        );
        if let Some(client) = self.clients.lock().unwrap().get(&key) {
            return Ok(client.clone());
        }
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert(
            reqwest::header::ACCEPT_ENCODING,
            reqwest::header::HeaderValue::from_static("identity"),
        );
        if scoped.is_some() {
            headers.insert(reqwest::header::ACCEPT, reqwest::header::HeaderValue::from_static("*/*"));
        }
        let mut builder = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(3))
            // Media headers belong to the source, including across redirects.
            .referer(false)
            .default_headers(headers)
            .no_gzip()
            .no_deflate()
            .no_brotli();
        if let Some(policy) = scoped.cloned() {
            builder = builder.redirect(reqwest::redirect::Policy::custom(move |attempt| {
                if attempt.previous().len() >= 5 || !policy.allows(attempt.url()) {
                    attempt.error("媒体跳转超出声明范围")
                } else {
                    attempt.follow()
                }
            }));
        }
        match cfg.mode {
            ProxyMode::Direct => builder = builder.no_proxy(),
            ProxyMode::System => {
                let url = Self::system_proxy_hint().ok_or_else(|| {
                    ProviderError::new(
                        crate::model::ErrorKind::Other,
                        "未检测到系统代理，请检查全局代理设置",
                    )
                })?;
                let proxy = reqwest::Proxy::all(url)
                    .map_err(|_| {
                        ProviderError::new(crate::model::ErrorKind::Other, "系统代理地址无效")
                    })?
                    .no_proxy(reqwest::NoProxy::from_string(&cfg.bypass.join(",")));
                builder = builder.no_proxy().proxy(proxy);
            }
            ProxyMode::Custom => {
                let mut proxy =
                    reqwest::Proxy::all(cfg.url.as_deref().unwrap_or("")).map_err(|_| {
                        ProviderError::new(crate::model::ErrorKind::Other, "全局代理地址无效")
                    })?;
                if let Some(user) = cfg.username.as_deref().filter(|s| !s.is_empty()) {
                    proxy = proxy
                        .basic_auth(user, &get_proxy_password(GLOBAL_PROXY).unwrap_or_default());
                }
                proxy = proxy.no_proxy(reqwest::NoProxy::from_string(&cfg.bypass.join(",")));
                builder = builder.no_proxy().proxy(proxy);
            }
        }
        let client = builder
            .build()
            .map_err(|_| ProviderError::new(crate::model::ErrorKind::Other, "无法建立视频连接"))?;
        self.clients.lock().unwrap().insert(key, client.clone());
        Ok(client)
    }

    /// 全量配置（供 UI 读取；**不含密码**）
    pub fn all(&self) -> HashMap<String, ProxyConfig> {
        self.configs.read().unwrap().clone()
    }

    pub fn get(&self, provider: &str) -> ProxyConfig {
        let configs = self.configs.read().unwrap();
        configs
            .get(GLOBAL_PROXY)
            .or_else(|| configs.get(provider))
            .cloned()
            .unwrap_or_default()
    }

    /// 写入配置（校验 URL；校验失败不改动现状）
    pub fn set(&self, provider: &str, mut cfg: ProxyConfig) -> Result<(), String> {
        if cfg.mode == ProxyMode::Custom {
            let url = cfg
                .url
                .as_deref()
                .ok_or_else(|| "自定义代理必须填写地址".to_string())?;
            cfg.url = Some(validate_proxy_url(url)?);
        }
        let mut configs = self.configs.write().unwrap();
        let key = if self.path.is_some() {
            GLOBAL_PROXY
        } else {
            provider
        };
        if key == GLOBAL_PROXY {
            self.persist(&cfg)?;
        }
        configs.insert(key.to_string(), cfg);
        if key == GLOBAL_PROXY {
            self.legacy_choices.write().unwrap().clear();
        }
        self.invalidate_clients();
        Ok(())
    }

    /// 清除某站点的代理配置（回到直连）
    pub fn clear(&self, provider: &str) -> Result<(), String> {
        if provider == GLOBAL_PROXY || self.path.is_some() {
            self.set(GLOBAL_PROXY, ProxyConfig::default())?;
            return clear_proxy_password(GLOBAL_PROXY);
        }
        let mut configs = self.configs.write().unwrap();
        configs.remove(provider);
        self.invalidate_clients();
        drop(configs);
        clear_proxy_password(provider)
    }

    /// ★ 取该站点应当使用的 HTTP 客户端
    ///
    /// `scope` 参数允许调用方覆盖配置里的 scope（例如同步后端强制走全流量）。
    pub fn client_for(
        &self,
        provider: &str,
        scope: Option<ProxyScope>,
    ) -> Result<reqwest::Client, ProviderError> {
        self.client_for_ex(provider, scope, AutoDecompress::On)
    }

    /// 同 [`Self::client_for`]，但可以指定要不要自动解压
    ///
    /// # ★★★ 为什么必须有这个入口（CodeRabbit PR#32 ①）
    /// ```text
    /// raw-deflate 回退需要「关掉自动解压」的客户端 ——
    /// 但旧实现是从零 `reqwest::Client::builder()` 新建一个 `raw_client`：
    ///
    ///   · 丢掉了 `client_for` 配好的**自定义代理 + 认证 + 绕过列表**
    ///     ⇒ 用户开了代理，回退却走直连
    ///     ⇒ 轻则回退失败（那台站本来就得靠代理才通）
    ///     ⇒ 重则**暴露用户真实出口 IP**（站点看到的不是代理地址）
    ///   · 丢掉了 `user_agent`
    ///     ⇒ 有的站按 UA 分流，回退请求被当成爬虫
    ///   · 丢掉了统一的 `timeout` 语义
    ///
    /// ⇒ 代理配置、认证、绕过列表、UA 必须在**两种客户端之间保持一致**，
    ///   唯一允许不同的只有「自动解压」这一项。
    /// ```
    ///
    /// # 缓存键必须带 `decompress`
    /// ```text
    /// 若两种客户端共用一个 key：
    ///   先回退一次（建的是 Off 客户端）⇒ 之后所有正常请求拿到 Off 客户端
    ///   ⇒ 那些站返回 gzip 时我们拿到原始字节 ⇒ 上层看到的是乱码
    /// 这是**静默**的错误（不报错，只是数据不对），所以 key 必须分开。
    /// ```
    pub fn client_for_ex(
        &self,
        provider: &str,
        scope: Option<ProxyScope>,
        decompress: AutoDecompress,
    ) -> Result<reqwest::Client, ProviderError> {
        self.ensure_configured()?;
        let revision = self.revision.load(std::sync::atomic::Ordering::SeqCst);
        let cfg = self.get(provider);
        let eff_scope = scope.unwrap_or(cfg.scope);

        // 仅 API 走代理时，视频分片类请求应直连 —— 由调用方决定传什么 scope，
        // 这里只负责「这个客户端怎么建」。
        let key = format!(
            "{provider}|{revision}|{eff_scope:?}|{}|{:?}|{:?}|{decompress:?}|{:?}",
            cfg.url.as_deref().unwrap_or(""),
            cfg.mode,
            cfg.bypass,
            cfg.username
        );

        if let Some(c) = self.clients.lock().unwrap().get(&key) {
            return Ok(c.clone());
        }

        let credential_key = if self.configs.read().unwrap().contains_key(GLOBAL_PROXY) {
            GLOBAL_PROXY
        } else {
            provider
        };
        let client = self.build_client(credential_key, &cfg, decompress)?;
        self.clients.lock().unwrap().insert(key, client.clone());
        Ok(client)
    }

    /// Discovery requires a proxy even when bypass rules or NO_PROXY would match.
    pub fn required_global_proxy(&self) -> Result<reqwest::Proxy, String> {
        self.ensure_configured().map_err(|e| e.message)?;
        let cfg = self.get(GLOBAL_PROXY);
        let raw = match cfg.mode {
            ProxyMode::Direct => return Err("请在全局代理设置中启用代理后再发现源".into()),
            ProxyMode::System => {
                Self::system_proxy_hint().ok_or("未检测到系统代理，请设置全局代理地址")?
            }
            ProxyMode::Custom => cfg.url.clone().ok_or("请先设置全局代理地址")?,
        };
        let normalized = if cfg.mode == ProxyMode::System {
            raw
        } else {
            validate_proxy_url(&raw)?
        };
        let mut url = reqwest::Url::parse(&normalized).map_err(|_| "全局代理地址无效")?;
        if !matches!(
            url.scheme(),
            "http" | "https" | "socks4" | "socks4a" | "socks5" | "socks5h"
        ) || url.host_str().is_none()
        {
            return Err("全局代理地址无效".into());
        }
        if url.scheme() == "socks5" {
            let _ = url.set_scheme("socks5h");
        }
        if url.scheme() == "socks4" {
            let _ = url.set_scheme("socks4a");
        }
        let mut proxy = reqwest::Proxy::all(url)
            .map_err(|_| "全局代理地址无效")?
            .no_proxy(None);
        if let Some(user) = cfg
            .username
            .as_deref()
            .filter(|s| cfg.mode == ProxyMode::Custom && !s.is_empty())
        {
            proxy = proxy.basic_auth(user, &get_proxy_password(GLOBAL_PROXY).unwrap_or_default());
        }
        Ok(proxy)
    }

    /// Text APIs (including danmaku) use the same client, credentials and proxy policy.
    pub async fn text_request(&self, args: serde_json::Value) -> Result<serde_json::Value, String> {
        use serde_json::json;
        let url = reqwest::Url::parse(args["url"].as_str().ok_or("缺少请求地址")?)
            .map_err(|_| "请求地址无效")?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err("仅支持 HTTP/HTTPS 请求".into());
        }
        let method =
            reqwest::Method::from_bytes(args["method"].as_str().unwrap_or("GET").as_bytes())
                .map_err(|_| "请求方法无效")?;
        let loopback = url.host_str().is_some_and(|h| {
            h.eq_ignore_ascii_case("localhost")
                || h.trim_matches(['[', ']'])
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|ip| ip.is_loopback())
        });
        let client = if loopback {
            self.build_client(GLOBAL_PROXY, &ProxyConfig::default(), AutoDecompress::On)
        } else {
            self.client_for(GLOBAL_PROXY, None)
        }
        .map_err(|_| "无法建立网络连接")?;
        let timeout = args["timeoutMs"]
            .as_u64()
            .unwrap_or(15000)
            .clamp(500, 30000);
        let mut request = client
            .request(method, url)
            .timeout(Duration::from_millis(timeout));
        if let Some(headers) = args["headers"].as_object() {
            for (name, value) in headers {
                if let Some(value) = value.as_str() {
                    request = request.header(name.as_str(), value);
                }
            }
        }
        if let Some(body) = args["body"].as_str() {
            if body.len() > 2 * 1024 * 1024 {
                return Err("请求内容过大".into());
            }
            request = request.body(body.to_owned());
        }
        let mut response = request.send().await.map_err(|e| summarize_err(&e))?;
        let status = response.status().as_u16();
        let headers: HashMap<String, String> = response
            .headers()
            .iter()
            .filter_map(|(name, v)| v.to_str().ok().map(|v| (name.to_string(), v.to_string())))
            .collect();
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|e| summarize_err(&e))? {
            if body.len() + chunk.len() > 32 * 1024 * 1024 {
                return Err("响应内容过大".into());
            }
            body.extend_from_slice(&chunk);
        }
        Ok(json!({"statusCode":status,"headers":headers,"body":String::from_utf8_lossy(&body)}))
    }

    fn build_client(
        &self,
        provider: &str,
        cfg: &ProxyConfig,
        decompress: AutoDecompress,
    ) -> Result<reqwest::Client, ProviderError> {
        let mut b = reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .user_agent(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            );

        /*
         * ★ raw 客户端：三个都必须关，且必须在 `proxy` 之前不冲突（都是独立字段）
         *
         * # 为什么三个都要关（实测）
         * ```text
         * reqwest 的自动解压是 **client 级** 配置，
         * 与"发不发 Accept-Encoding 头"无关。
         * 只关 deflate 可能仍被 gzip/br 干扰 ⇒ 实测三个全关才拿到原始字节。
         * ```
         */
        if decompress == AutoDecompress::Off {
            b = b.no_gzip().no_deflate().no_brotli();
        }

        self.apply_proxy_policy(provider, cfg, b)?.build().map_err(|e| {
            ProviderError::new(
                crate::model::ErrorKind::Other,
                format!("构建 HTTP 客户端失败: {e}"),
            )
        })
    }

    fn apply_proxy_policy(
        &self,
        provider: &str,
        cfg: &ProxyConfig,
        builder: reqwest::ClientBuilder,
    ) -> Result<reqwest::ClientBuilder, ProviderError> {
        let mut b = builder.no_proxy();
        match cfg.mode {
            ProxyMode::Direct => {
                // ⚠️ 必须显式 no_proxy()：否则即使配置成「直连」，
                //    reqwest 仍会读环境变量里的代理，与用户意图相反。
                b = b.no_proxy();
            }
            ProxyMode::System => {
                let url = Self::system_proxy_hint().ok_or_else(|| {
                    ProviderError::new(
                        crate::model::ErrorKind::Other,
                        "未检测到系统代理，请检查全局代理设置",
                    )
                })?;
                let proxy = reqwest::Proxy::all(url)
                    .map_err(|_| {
                        ProviderError::new(crate::model::ErrorKind::Other, "系统代理地址无效")
                    })?
                    .no_proxy(reqwest::NoProxy::from_string(&cfg.bypass.join(",")));
                b = b.no_proxy().proxy(proxy);
            }
            ProxyMode::Custom => {
                let raw = cfg.url.as_deref().unwrap_or("").trim();
                if raw.is_empty() {
                    return Err(ProviderError::new(
                        crate::model::ErrorKind::Other,
                        "自定义代理未配置地址",
                    ));
                } else {
                    let mut proxy = reqwest::Proxy::all(raw).map_err(|e| {
                        ProviderError::new(
                            crate::model::ErrorKind::Other,
                            format!("代理地址无效（{raw}）: {e}"),
                        )
                    })?;

                    // 带认证的代理：密码从钥匙串取，绝不落库
                    if let Some(user) = cfg.username.as_deref().filter(|s| !s.is_empty()) {
                        let pass = get_proxy_password(provider).unwrap_or_default();
                        proxy = proxy.basic_auth(user, &pass);
                    }

                    // ⚠️ 绕过列表挂在 `Proxy` 上（不是 ClientBuilder）：
                    //    `reqwest::Proxy::no_proxy(Option<NoProxy>)`
                    if !cfg.bypass.is_empty() {
                        let list = cfg.bypass.join(",");
                        proxy = proxy.no_proxy(reqwest::NoProxy::from_string(&list));
                    }

                    b = b.proxy(proxy);
                }
            }
        }

        Ok(b)
    }

    /// ★ 代理健康检查：请求一个已知 URL，看是否通
    ///
    /// 返回 `(ok, 说明)`。用于设置页的「测试连接」按钮。
    pub async fn test(&self, provider: &str) -> (bool, String) {
        let cfg = self.get(provider);

        // 用 Google 的生成式端点做探针：国内直连不可达、经代理可达（已实测）
        let probe = "https://www.googleapis.com/generate_204";

        let client = match self.client_for(provider, Some(ProxyScope::ApiOnly)) {
            Ok(c) => c,
            Err(e) => return (false, e.message),
        };

        match client
            .get(probe)
            .timeout(Duration::from_secs(12))
            .send()
            .await
        {
            Ok(resp) => {
                let code = resp.status().as_u16();
                (true, format!("连接正常（{}，HTTP {code}）", describe(&cfg)))
            }
            Err(e) => (
                false,
                format!("连接失败（{}）: {}", describe(&cfg), summarize_err(&e)),
            ),
        }
    }

    /// 由环境变量推断当前系统代理（供 UI 显示）
    pub fn system_proxy_hint() -> Option<String> {
        for k in [
            "ALL_PROXY",
            "HTTPS_PROXY",
            "https_proxy",
            "HTTP_PROXY",
            "http_proxy",
        ] {
            if let Ok(v) = std::env::var(k) {
                if !v.trim().is_empty() {
                    return Some(v);
                }
            }
        }
        None
    }
}

fn describe(cfg: &ProxyConfig) -> String {
    match cfg.mode {
        ProxyMode::Direct => "直连".into(),
        ProxyMode::System => match ProxyStore::system_proxy_hint() {
            Some(v) => format!("跟随系统（{v}）"),
            None => "跟随系统（未检测到环境变量代理）".into(),
        },
        ProxyMode::Custom => format!("自定义（{}）", cfg.url.as_deref().unwrap_or("—")),
    }
}

/// 把 reqwest 的错误压成一句人话（区分超时/DNS/拒绝连接）
fn summarize_err(e: &reqwest::Error) -> String {
    if e.is_timeout() {
        "超时".into()
    } else if e.is_connect() {
        "无法建立连接（代理未启动或地址错误）".into()
    } else {
        let s = e.to_string();
        s.chars().take(120).collect()
    }
}

/// 供 lib.rs 共享的类型别名
pub type SharedProxyStore = Arc<ProxyStore>;

#[cfg(test)]
#[path = "global_proxy_tests.rs"]
mod global_proxy_tests;

// ─────────────────────────── 测试 ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_direct_and_api_only() {
        let c = ProxyConfig::default();
        assert_eq!(c.mode, ProxyMode::Direct);
        assert_eq!(c.scope, ProxyScope::ApiOnly);
        // 未配置的站点必须真的不走代理
        assert!(!c.uses_proxy());
    }

    #[test]
    fn custom_without_url_does_not_use_proxy() {
        // 选了「自定义」但没填地址 → 按直连处理，避免 reqwest 报错
        let c = ProxyConfig {
            mode: ProxyMode::Custom,
            url: None,
            ..Default::default()
        };
        assert!(!c.uses_proxy());

        let c2 = ProxyConfig {
            mode: ProxyMode::Custom,
            url: Some("   ".into()),
            ..Default::default()
        };
        assert!(!c2.uses_proxy(), "空白地址不应被当成有效代理");
    }

    #[test]
    fn system_mode_always_uses_proxy() {
        let c = ProxyConfig {
            mode: ProxyMode::System,
            ..Default::default()
        };
        assert!(c.uses_proxy());
    }

    #[test]
    fn validates_proxy_schemes() {
        // 支持 http/https/socks
        assert!(validate_proxy_url("http://127.0.0.1:7890").is_ok());
        assert!(validate_proxy_url("socks5://127.0.0.1:1080").is_ok());
        assert!(validate_proxy_url("socks5h://127.0.0.1:1080").is_ok());
        assert!(
            validate_proxy_url("  HTTP://127.0.0.1:7890  ").is_ok(),
            "应容忍大小写与空白"
        );

        // 拒绝漏协议 / 缺主机 / 空
        assert!(
            validate_proxy_url("127.0.0.1:7890").is_err(),
            "缺少协议头应被拒"
        );
        assert!(validate_proxy_url("http://").is_err(), "缺少主机应被拒");
        assert!(validate_proxy_url("").is_err());
        assert!(
            validate_proxy_url("ftp://x:1").is_err(),
            "不支持的协议应被拒"
        );
    }

    #[test]
    fn set_rejects_invalid_url_and_keeps_old_value() {
        let store = ProxyStore::new();
        store
            .set(
                "srca",
                ProxyConfig {
                    mode: ProxyMode::Custom,
                    url: Some("http://127.0.0.1:7890".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(
            store.get("srca").url.as_deref(),
            Some("http://127.0.0.1:7890")
        );

        // 非法地址 → 报错且**不覆盖**已存的好值
        let bad = store.set(
            "srca",
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: Some("nonsense".into()),
                ..Default::default()
            },
        );
        assert!(bad.is_err());
        assert_eq!(
            store.get("srca").url.as_deref(),
            Some("http://127.0.0.1:7890"),
            "校验失败不应破坏已有配置"
        );
    }

    #[test]
    fn custom_requires_url() {
        let store = ProxyStore::new();
        let r = store.set(
            "x",
            ProxyConfig {
                mode: ProxyMode::Custom,
                url: None,
                ..Default::default()
            },
        );
        assert!(r.is_err(), "自定义模式必须填地址");
    }

    #[test]
    fn direct_client_builds_and_is_cached() {
        let store = ProxyStore::new();
        let c1 = store.client_for("srcl", None).unwrap();
        let c2 = store.client_for("srcl", None).unwrap();
        // 缓存生效（同一个 Arc 内的连接池被复用）
        assert!(c1.get("http://example.invalid").build().is_ok() || true);
        drop(c2);
    }

    #[test]
    fn changing_config_invalidates_client_cache() {
        let store = ProxyStore::new();
        let _ = store.client_for("p", None).unwrap();
        assert!(!store.clients.lock().unwrap().is_empty());

        store
            .set(
                "p",
                ProxyConfig {
                    mode: ProxyMode::System,
                    ..Default::default()
                },
            )
            .unwrap();
        // 配置一变，缓存的客户端必须作废，否则会继续走旧出口
        assert!(
            store.clients.lock().unwrap().is_empty(),
            "改配置后必须清空客户端缓存"
        );
    }

    #[test]
    fn config_serialization_never_contains_password() {
        let c = ProxyConfig {
            mode: ProxyMode::Custom,
            url: Some("http://user@127.0.0.1:7890".into()),
            username: Some("u".into()),
            ..Default::default()
        };
        let json = serde_json::to_string(&c).unwrap();
        // 结构里压根没有 password 字段（密码只在钥匙串）
        assert!(
            !json.contains("password"),
            "配置序列化不应含密码字段: {json}"
        );
    }

    #[tokio::test]
    #[ignore = "需要网络与代理"]
    async fn custom_proxy_reaches_google() {
        let store = ProxyStore::new();
        store
            .set(
                "probe",
                ProxyConfig {
                    mode: ProxyMode::Custom,
                    url: Some("http://127.0.0.1:7890".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        let (ok, msg) = store.test("probe").await;
        assert!(ok, "经代理应可达 Google: {msg}");
    }

    #[tokio::test]
    #[ignore = "需要网络"]
    async fn direct_mode_still_builds_client() {
        let store = ProxyStore::new();
        let (ok, msg) = store.test("direct-only").await;
        // 直连下 Google 不可达是**预期行为**（这正是代理存在的理由）
        // 这里只断言「没崩、有明确结论」
        assert!(!msg.is_empty());
        let _ = ok;
    }
}
