//! Public protocol implementation behind the registered AppDrama facade.
//! with honest Windows/public application metadata, never a forged Android ID.
use crate::csp::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};

#[path = "app_drama_reference_constants.rs"]
mod reference_constants;
#[path = "app_drama_wire.rs"]
pub(super) mod wire;
use wire::{Failure, Message, Result};

const ZONE: &str = "/api/v5/find/app/zone";
const CATEGORIES: &str = "/api/v3/drama/getCategory?orderBy=type_id";
const LIST: &str = "/api/proto/v5/drama/category";
const SEARCH: &str = "/api/proto/v5/drama/search";
const DETAIL: &str = "/api/proto/v5/drama/getDetail";
const PLAY: &str = "/api/proto/v5/videoUsableUrl";
const MAX_EPISODES: usize = 4096;
const SESSION_TTL: Duration = Duration::from_secs(60);
const FAILURE_BACKOFF: Duration = Duration::from_secs(3);
// Accounted owned payload; entry count independently bounds allocator overhead.
const MAX_ISSUED_BYTES: usize = 4 * 1024 * 1024;
const DISPATCH_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
    (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

#[derive(Clone)]
struct Config {
    host: String,
    site: String,
    public_key: String,
    data_key: Vec<u8>,
    data_iv: Vec<u8>,
    app_name: String,
    pkg: String,
    version: String,
}

impl Config {
    fn parse(ext: &str) -> Result<Self> {
        let value: Value = serde_json::from_str(ext).map_err(|_| Failure::Parse("ext JSON"))?;
        let text = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string()
        };
        let cfg = Self {
            host: text("host"),
            site: text("site"),
            public_key: text("publicKey"),
            data_key: text("dataKey").into_bytes(),
            data_iv: text("dataIv").into_bytes(),
            app_name: text("appName"),
            pkg: text("pkg"),
            version: text("version"),
        };
        if cfg.host.is_empty() && cfg.site.is_empty() {
            return Err(Failure::Parse("缺少 host/site"));
        }
        if cfg.public_key.is_empty() {
            return Err(Failure::Parse("缺少 publicKey"));
        }
        if cfg.pkg.is_empty() || cfg.version.is_empty() {
            return Err(Failure::Parse("缺少应用 pkg/version"));
        }
        for key in [&cfg.data_key, &cfg.data_iv] {
            if !matches!(key.len(), 16 | 24 | 32) {
                return Err(Failure::Parse("原始 AES key 长度"));
            }
        }
        if !cfg.host.is_empty() {
            checked_base(&cfg.host)?;
        }
        if !cfg.site.is_empty() {
            checked_http(&cfg.site)?;
        }
        Ok(cfg)
    }
}

type Route = (usize, u64, String);
#[derive(Clone)]
struct Session {
    fingerprint: Vec<u8>,
    route: Route,
    generation: u64,
    expires: Instant,
    client: reqwest::Client,
    base: String,
    public_key: String,
}
#[derive(Clone)]
struct Cooldown {
    fingerprint: Vec<u8>,
    route: Route,
    until: Instant,
    failure: Failure,
}
#[derive(Default)]
struct SessionState {
    current: Option<Session>,
    cooldown: Option<Cooldown>,
    generation: u64,
}
#[derive(Clone)]
struct IssuedRecipe {
    recipe: EpisodeRecipe,
    fingerprint: Vec<u8>,
    route: Route,
    generation: u64,
    expires: Instant,
    cost: usize,
}
#[derive(Default)]
struct IssuedState {
    entries: HashMap<String, IssuedRecipe>,
    order: VecDeque<String>,
    bytes: usize,
}

pub(super) struct ProtocolAppDrama {
    client: crate::csp::http_context::CspHttpContext,
    policy: RwLock<Option<(Arc<crate::proxy::ProxyStore>, String)>>,
    session: tokio::sync::Mutex<SessionState>,
    issued: tokio::sync::Mutex<IssuedState>,
    selection_refresh: tokio::sync::Mutex<()>,
}

impl ProtocolAppDrama {
    pub(super) fn new() -> Self {
        Self {
            client: crate::csp::http_context::CspHttpContext::new(|| {
                reqwest::Client::builder()
                    .user_agent("okhttp/3.12.1")
                    .no_proxy()
                    .referer(false)
                    .redirect(reqwest::redirect::Policy::none())
                    .timeout(Duration::from_secs(5))
            }),
            policy: RwLock::new(None),
            session: tokio::sync::Mutex::new(SessionState::default()),
            issued: tokio::sync::Mutex::new(IssuedState::default()),
            selection_refresh: tokio::sync::Mutex::new(()),
        }
    }
    fn descriptor(cfg: &Config) -> Result<Vec<(String, Value)>> {
        use rsa::rand_core::{OsRng, RngCore};
        let mut bytes = [0u8; 16];
        OsRng
            .try_fill_bytes(&mut bytes)
            .map_err(|_| Failure::Transport)?;
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        let client_id: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
        // Public client metadata only. The absent Android Build/secure ID fields
        // are NOT populated from fake phone values or host/account fingerprints.
        // Server acceptance of this Windows descriptor remains a real-test gate.
        Ok(vec![
            ("vName".into(), json!(cfg.version)),
            ("pkg".into(), json!(cfg.pkg)),
            ("uuid".into(), json!(client_id)),
            ("model".into(), json!("desktop")),
            ("plat".into(), json!(std::env::consts::OS)),
            ("udid".into(), json!(client_id)),
            ("appName".into(), json!(cfg.app_name)),
            ("cpu".into(), json!(std::env::consts::ARCH)),
            ("vOs".into(), json!(std::env::consts::OS)),
            ("v".into(), json!(1)),
            ("vApp".into(), json!(cfg.version.replace('.', ""))),
        ])
    }
    fn route_locked(policy: &Option<(Arc<crate::proxy::ProxyStore>, String)>) -> Route {
        policy
            .as_ref()
            .map(|(store, provider)| {
                (
                    Arc::as_ptr(store) as usize,
                    store.policy_revision(),
                    provider.clone(),
                )
            })
            .unwrap_or_default()
    }
    fn route(&self) -> Result<Route> {
        let policy = self.policy.read().map_err(|_| Failure::Transport)?;
        Ok(Self::route_locked(&policy))
    }
    fn same_route(&self, route: &Route) -> Result<()> {
        if &self.route()? == route {
            Ok(())
        } else {
            Err(Failure::PolicyChanged)
        }
    }
    async fn response(&self, request: reqwest::RequestBuilder, route: &Route) -> Result<Vec<u8>> {
        self.same_route(route)?;
        let mut response = request.send().await.map_err(|_| Failure::Transport)?;
        self.same_route(route)?;
        let status = response.status().as_u16();
        if matches!(status, 401 | 403 | 429) {
            return Err(Failure::Access(status));
        }
        if (300..400).contains(&status) {
            return Err(Failure::Unsupported("请求发生重定向，需独立确认访问规则"));
        }
        if !response.status().is_success() {
            return Err(Failure::Http(status));
        }
        if response
            .content_length()
            .is_some_and(|size| size > wire::MAX_BODY as u64)
        {
            return Err(Failure::Parse("响应大小"));
        }
        let mut data = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| Failure::Transport)? {
            if data.len().saturating_add(chunk.len()) > wire::MAX_BODY {
                return Err(Failure::Parse("响应大小"));
            }
            data.extend_from_slice(&chunk);
        }
        self.same_route(route)?;
        Ok(data)
    }
    fn headers(&self, key: &str, cfg: &Config, proto: bool) -> Result<reqwest::header::HeaderMap> {
        let value = wire::public_params(
            &reference_constants::HEADER_KEY_IV,
            &Self::descriptor(cfg)?,
            proto,
            key,
            &cfg.data_iv,
            wire::now()?,
            &wire::nonce(16)?,
        )?;
        let mut headers = reqwest::header::HeaderMap::new();
        let media = if proto {
            "application/x-protobuf"
        } else {
            "application/json"
        };
        headers.insert(
            reqwest::header::ACCEPT,
            reqwest::header::HeaderValue::from_static(media),
        );
        headers.insert(
            reqwest::header::CONTENT_TYPE,
            reqwest::header::HeaderValue::from_static(if proto {
                "application/x-protobuf"
            } else {
                "application/json; charset=utf-8"
            }),
        );
        headers.insert(
            "publicparams",
            reqwest::header::HeaderValue::from_str(&value)
                .map_err(|_| Failure::Parse("publicParams"))?,
        );
        Ok(headers)
    }
    async fn session(&self, cfg: &Config, ext: &str) -> Result<Session> {
        let fingerprint = ring::digest::digest(&ring::digest::SHA256, ext.as_bytes())
            .as_ref()
            .to_vec();
        let mut cached = self.session.lock().await;
        let (client, route) = {
            let policy = self.policy.read().map_err(|_| Failure::Transport)?;
            let route = Self::route_locked(&policy);
            let client = self.client.client().map_err(|_| Failure::Transport)?;
            if route != Self::route_locked(&policy) {
                return Err(Failure::PolicyChanged);
            }
            (client, route)
        };
        if let Some(session) = cached.current.as_ref().filter(|old| {
            old.fingerprint == fingerprint && old.route == route && old.expires > Instant::now()
        }) {
            return Ok(session.clone());
        }
        if let Some(cooldown) = cached.cooldown.as_ref().filter(|failure| {
            failure.fingerprint == fingerprint
                && failure.route == route
                && failure.until > Instant::now()
        }) {
            return Err(cooldown.failure.clone());
        }
        cached.current = None;
        cached.cooldown = None;
        cached.generation = cached.generation.checked_add(1).ok_or(Failure::Transport)?;
        let generation = cached.generation;
        let attempt = async {
            let base = if cfg.site.is_empty() {
                checked_base(&cfg.host)?
            } else {
                let raw = self
                    .response(
                        client
                            .get(&cfg.site)
                            .header(reqwest::header::ACCEPT, "application/json")
                            .header(reqwest::header::USER_AGENT, DISPATCH_UA),
                        &route,
                    )
                    .await?;
                let value: Value =
                    serde_json::from_slice(&raw).map_err(|_| Failure::Parse("域名下发 JSON"))?;
                if value.get("enabled").and_then(Value::as_bool) == Some(false) {
                    return Err(Failure::Restricted);
                }
                let domain = value
                    .get("domain")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                    .ok_or(Failure::Parse("下发 domain"))?;
                checked_base(domain)?
            };
            let body = wire::rsa_request(
                &cfg.public_key,
                wire::now()?,
                &wire::nonce(16)?,
                &wire::nonce(16)?,
                &wire::nonce(16)?,
            )?;
            // DEX init invokes c() twice then putAll. Preserve the second header set.
            let mut headers = self.headers(&cfg.public_key, cfg, true)?;
            let second = self.headers(&cfg.public_key, cfg, true)?;
            for (name, value) in second.iter() {
                headers.insert(name.clone(), value.clone());
            }
            let data = self
                .response(
                    client
                        .post(format!("{base}{ZONE}"))
                        .headers(headers)
                        .body(body),
                    &route,
                )
                .await?;
            let key_data = wire::api_data(&data)?;
            let public = Message::parse(key_data)?;
            let mut key = String::new();
            for field in 2..=5 {
                key.push_str(
                    public
                        .string(field)?
                        .ok_or(Failure::Parse("RSAPublic key parts"))?,
                );
            }
            wire::checked_public_key(&key)?;
            self.same_route(&route)?;
            Ok::<_, Failure>(Session {
                fingerprint: fingerprint.clone(),
                route: route.clone(),
                generation,
                expires: Instant::now() + SESSION_TTL,
                client,
                base,
                public_key: key,
            })
        }
        .await;
        match attempt {
            Ok(session) => {
                cached.current = Some(session.clone());
                Ok(session)
            }
            Err(failure) => {
                // Cache only this exact source/store/revision's failure. No
                // retry, identity rotation or different address in this call.
                cached.cooldown = Some(Cooldown {
                    fingerprint,
                    route,
                    until: Instant::now() + FAILURE_BACKOFF,
                    failure: failure.clone(),
                });
                Err(failure)
            }
        }
    }
    async fn invalidate(&self, session: &Session, failure: &Failure) {
        let mut state = self.session.lock().await;
        if state.current.as_ref().is_some_and(|current| {
            current.generation == session.generation
                && current.fingerprint == session.fingerprint
                && current.route == session.route
        }) {
            state.current = None;
            state.cooldown = Some(Cooldown {
                fingerprint: session.fingerprint.clone(),
                route: session.route.clone(),
                until: Instant::now() + FAILURE_BACKOFF,
                failure: failure.clone(),
            });
        }
    }
    async fn active_session(&self, session: &Session) -> Result<()> {
        self.same_route(&session.route)?;
        let state = self.session.lock().await;
        if session.expires <= Instant::now()
            || !state.current.as_ref().is_some_and(|current| {
                current.generation == session.generation
                    && current.fingerprint == session.fingerprint
                    && current.route == session.route
                    && current.expires > Instant::now()
            })
        {
            return Err(Failure::Unsupported("剧集会话已失效，请刷新详情"));
        }
        Ok(())
    }
    fn issued_payload(session: &Session, recipe: &EpisodeRecipe) -> Result<(String, usize)> {
        let encoded = serde_json::to_vec(recipe).map_err(|_| Failure::Parse("剧集序列化"))?;
        let id = format!("app-drama:v2|{}", wire::b64(&encoded));
        let cost = [
            id.len(),
            id.len(),
            recipe.content.len(),
            recipe.flag.len(),
            recipe.source.len(),
            recipe.value.len(),
            recipe.binding.len(),
            session.fingerprint.len(),
            session.route.2.len(),
        ]
        .into_iter()
        .try_fold(0usize, |sum, size| sum.checked_add(size))
        .ok_or(Failure::Parse("剧集大小"))?;
        Ok((id, cost))
    }
    async fn remember_batch(
        &self,
        session: &Session,
        recipes: Vec<EpisodeRecipe>,
    ) -> Result<Vec<String>> {
        self.active_session(session).await?;
        if recipes.is_empty() || recipes.len() > MAX_EPISODES {
            return Err(Failure::Parse("剧集数量"));
        }
        let mut prepared = Vec::with_capacity(recipes.len());
        let mut ids = std::collections::HashSet::new();
        let mut total_cost = 0usize;
        for recipe in recipes {
            let (id, cost) = Self::issued_payload(session, &recipe)?;
            total_cost = total_cost
                .checked_add(cost)
                .ok_or(Failure::Parse("详情剧集总大小"))?;
            if total_cost > MAX_ISSUED_BYTES {
                return Err(Failure::Parse("详情剧集总大小"));
            }
            if !ids.insert(id.clone()) {
                return Err(Failure::Parse("重复剧集令牌"));
            }
            prepared.push((id, recipe, cost));
        }
        let mut state = self.issued.lock().await;
        if session.expires <= Instant::now() {
            return Err(Failure::Unsupported("详情会话已过期，请刷新"));
        }
        if prepared
            .iter()
            .any(|(id, _, _)| state.entries.contains_key(id))
        {
            return Err(Failure::Parse("重复剧集令牌"));
        }
        // Reserve the whole batch before mutation. Newly issued siblings cannot
        // evict one another, and malformed/oversized detail changes no ledger.
        while state.entries.len().saturating_add(prepared.len()) > MAX_EPISODES
            || state.bytes.saturating_add(total_cost) > MAX_ISSUED_BYTES
        {
            let old = state
                .order
                .pop_front()
                .ok_or(Failure::Parse("剧集缓存状态"))?;
            if let Some(removed) = state.entries.remove(&old) {
                state.bytes = state.bytes.saturating_sub(removed.cost);
            }
        }
        state.bytes += total_cost;
        let mut issued_ids = Vec::with_capacity(prepared.len());
        for (id, recipe, cost) in prepared {
            state.order.push_back(id.clone());
            issued_ids.push(id.clone());
            state.entries.insert(
                id,
                IssuedRecipe {
                    recipe,
                    fingerprint: session.fingerprint.clone(),
                    route: session.route.clone(),
                    generation: session.generation,
                    expires: session.expires,
                    cost,
                },
            );
        }
        Ok(issued_ids)
    }
    async fn remember(&self, session: &Session, recipe: EpisodeRecipe) -> Result<String> {
        self.remember_batch(session, vec![recipe])
            .await?
            .pop()
            .ok_or(Failure::Parse("剧集签发"))
    }
    async fn selected(&self, flag: &str, id: &str, ext: &str) -> Result<(EpisodeRecipe, Session)> {
        // One revalidation decision per engine at a time. A waiter rereads the
        // ledger/current generation after the preceding refresh completes; a
        // late stale response cannot retire or downgrade its refreshed token.
        let _refresh = self.selection_refresh.lock().await;
        let value = {
            let state = self.issued.lock().await;
            state
                .entries
                .get(id)
                .cloned()
                .ok_or(Failure::Unsupported("所选剧集未由当前来源签发，请刷新详情"))?
        };
        let fingerprint = ring::digest::digest(&ring::digest::SHA256, ext.as_bytes());
        if value.fingerprint.as_slice() != fingerprint.as_ref() || value.route != self.route()? {
            return Err(Failure::Unsupported("所选剧集已过期或来源变化，请刷新详情"));
        }
        let encoded = id
            .strip_prefix("app-drama:v2|")
            .ok_or(Failure::Parse("剧集版本"))?;
        let decoded: EpisodeRecipe = serde_json::from_slice(&wire::unb64(encoded)?)
            .map_err(|_| Failure::Parse("剧集 recipe"))?;
        if decoded != value.recipe
            || decoded.version != 2
            || (!flag.is_empty() && decoded.flag != flag)
            || decoded.content.is_empty()
            || decoded.binding.is_empty()
        {
            return Err(Failure::Parse("剧集选择身份"));
        }
        let fresh = {
            let state = self.session.lock().await;
            state
                .current
                .as_ref()
                .filter(|current| {
                    current.generation == value.generation
                        && current.fingerprint == value.fingerprint
                        && current.route == value.route
                        && current.expires > Instant::now()
                        && value.expires > Instant::now()
                })
                .cloned()
        };
        if let Some(current) = fresh {
            return Ok((decoded, current));
        }

        // The bounded ledger is the authority for an already issued identity.
        // Expiry means revalidate that identity, never accept arbitrary JSON or
        // silently find another episode by title/size/order.
        let cfg = Config::parse(ext)?;
        let current = self.session(&cfg, ext).await?;
        if current.route != value.route || current.fingerprint != value.fingerprint {
            return Err(Failure::Unsupported("所选剧集来源变化，请刷新详情"));
        }
        let bytes = self
            .call(
                &cfg,
                &current,
                DETAIL,
                vec![("id".into(), decoded.content.clone())],
            )
            .await?;
        let refreshed = match Self::refreshed_identity(&bytes, &decoded) {
            Ok(Some(recipe)) if recipe == decoded => recipe,
            Ok(_) => {
                self.active_session(&current).await?;
                self.retire_selected(id, &value).await;
                return Err(Failure::Unsupported("所选剧集信息已变化，请刷新详情"));
            }
            Err(failure) => {
                self.invalidate(&current, &failure).await;
                return Err(failure);
            }
        };
        self.active_session(&current).await?;
        {
            let mut state = self.issued.lock().await;
            let issued = state
                .entries
                .get_mut(id)
                .filter(|issued| {
                    issued.recipe == decoded
                        && issued.fingerprint == value.fingerprint
                        && issued.route == value.route
                })
                .ok_or(Failure::Unsupported("所选剧集已移除，请刷新详情"))?;
            issued.generation = current.generation;
            issued.expires = current.expires;
        }
        Ok((refreshed, current))
    }
    fn refreshed_identity(bytes: &[u8], anchor: &EpisodeRecipe) -> Result<Option<EpisodeRecipe>> {
        let detail = Message::parse(bytes)?;
        let content = detail
            .int32(4)?
            .filter(|value| *value > 0)
            .ok_or(Failure::Parse("详情 id"))?
            .to_string();
        if content != anchor.content {
            return Ok(None);
        }
        required(detail.string(9)?, "详情 name")?;
        let restricted = detail.integer(35)?.unwrap_or(0) != 0;
        let videos = detail.repeated(29)?;
        if videos.len() > MAX_EPISODES {
            return Err(Failure::Parse("剧集数量"));
        }
        let Some(bytes) = videos.get(anchor.index) else {
            return Ok(None);
        };
        let video = Message::parse(bytes)?;
        required(video.string(2)?, "剧集 title")?;
        let flag = video
            .string(10)?
            .filter(|value| !value.is_empty())
            .unwrap_or("默认")
            .to_string();
        let source = video.string(9)?.unwrap_or("").to_string();
        let value = required(video.string(4)?, "剧集 path")?.to_string();
        if !direct_media(&value) && source.is_empty() {
            return Err(Failure::Parse("剧集 source"));
        }
        Ok(Some(EpisodeRecipe {
            version: anchor.version,
            content,
            index: anchor.index,
            flag,
            source,
            value,
            restricted: restricted || video.integer(14)?.unwrap_or(0) != 0,
            binding: anchor.binding.clone(),
        }))
    }
    async fn retire_selected(&self, id: &str, anchor: &IssuedRecipe) {
        let mut state = self.issued.lock().await;
        if state.entries.get(id).is_some_and(|issued| {
            issued.recipe == anchor.recipe
                && issued.fingerprint == anchor.fingerprint
                && issued.route == anchor.route
        }) {
            if let Some(removed) = state.entries.remove(id) {
                state.bytes = state.bytes.saturating_sub(removed.cost);
            }
            state.order.retain(|entry| entry != id);
        }
    }
    fn ordered_pairs(&self, mut pairs: Vec<(String, String)>) -> Vec<(String, String)> {
        // Reference uses a default HashMap with <=8 known string keys. Model
        // OpenJDK/modern Android's first 16 buckets and preserve insertion within
        // collisions. Exact runtime iteration is an explicitly unverified gate;
        // do not mislabel an arbitrary alphabetical sort as the reference.
        let bucket = |text: &str| {
            let hash = text.encode_utf16().fold(0u32, |hash, ch| {
                hash.wrapping_mul(31).wrapping_add(ch as u32)
            });
            ((hash ^ (hash >> 16)) & 15) as u8
        };
        pairs.sort_by_key(|(key, _)| bucket(key));
        pairs
    }
    async fn call(
        &self,
        cfg: &Config,
        session: &Session,
        path: &'static str,
        pairs: Vec<(String, String)>,
    ) -> Result<Vec<u8>> {
        self.active_session(session).await?;
        let pairs = self.ordered_pairs(pairs);
        let body = wire::secure_request(
            &cfg.data_key,
            &pairs,
            wire::now()?,
            &wire::nonce(8)?,
            &wire::nonce(20)?,
        )?;
        let result = async {
            let response = self
                .response(
                    session
                        .client
                        .post(format!("{}{path}", session.base))
                        .headers(self.headers(&session.public_key, cfg, true)?)
                        .body(body),
                    &session.route,
                )
                .await?;
            let data = wire::api_data(&response)?.to_vec();
            self.active_session(session).await?;
            Ok::<_, Failure>(data)
        }
        .await;
        if let Err(failure) = &result {
            self.invalidate(session, failure).await;
        }
        result
    }
    async fn home_inner(&self, ext: &str) -> Result<CspHome> {
        let cfg = Config::parse(ext)?;
        let session = self.session(&cfg, ext).await?;
        let result = async {
            self.active_session(&session).await?;
            let bytes = self
                .response(
                    session
                        .client
                        .get(format!("{}{CATEGORIES}", session.base))
                        .headers(self.headers(&session.public_key, &cfg, false)?),
                    &session.route,
                )
                .await?;
            self.active_session(&session).await?;
            let value: Value =
                serde_json::from_slice(&bytes).map_err(|_| Failure::Parse("分类 JSON"))?;
            let rows = value
                .get("data")
                .and_then(Value::as_array)
                .filter(|rows| rows.len() <= 512)
                .ok_or(Failure::Parse("分类 data"))?;
            let mut categories = Vec::new();
            let mut ids = std::collections::HashSet::new();
            for row in rows {
                let name = row
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|name| !name.trim().is_empty())
                    .ok_or(Failure::Parse("分类 name"))?;
                if name == "公告" {
                    continue;
                }
                let id = row
                    .get("id")
                    .and_then(|id| {
                        id.as_str()
                            .map(str::to_string)
                            .or_else(|| id.as_i64().map(|n| n.to_string()))
                    })
                    .filter(|id| !id.trim().is_empty())
                    .ok_or(Failure::Parse("分类 id"))?;
                if ids.insert(id.clone()) {
                    categories.push(CspCategory {
                        id,
                        name: name.into(),
                    });
                }
            }
            if categories.is_empty() {
                return Err(Failure::Parse("分类为空"));
            }
            self.active_session(&session).await?;
            Ok::<_, Failure>(CspHome {
                categories,
                items: vec![],
            })
        }
        .await;
        if let Err(failure) = &result {
            self.invalidate(&session, failure).await;
        }
        result
    }
    async fn list_inner(&self, tid: &str, page: u32, ext: &str) -> Result<CspList> {
        if tid.trim().is_empty() {
            return Err(Failure::Parse("分类 id"));
        }
        let cfg = Config::parse(ext)?;
        let session = self.session(&cfg, ext).await?;
        let pairs = vec![
            ("pagesize".into(), "21".into()),
            ("typeId1".into(), tid.into()),
            ("page".into(), page.max(1).to_string()),
            ("vodOrderBy".into(), "最新".into()),
            ("vodArea".into(), String::new()),
            ("vodLang".into(), String::new()),
            ("vodClass".into(), String::new()),
            ("vodYear".into(), String::new()),
        ];
        let bytes = self.call(&cfg, &session, LIST, pairs).await?;
        list_from(&bytes, page.max(1))
    }
    async fn search_inner(&self, kw: &str, page: u32, ext: &str) -> Result<CspList> {
        if kw.trim().is_empty() {
            return Err(Failure::Parse("搜索词"));
        }
        let cfg = Config::parse(ext)?;
        let session = self.session(&cfg, ext).await?;
        let bytes = self
            .call(
                &cfg,
                &session,
                SEARCH,
                vec![
                    ("searchKeys".into(), kw.into()),
                    ("page".into(), page.max(1).to_string()),
                    ("pagesize".into(), "21".into()),
                ],
            )
            .await?;
        list_from(&bytes, page.max(1))
    }
    async fn detail_inner(&self, id: &str, ext: &str) -> Result<CspDetail> {
        let cfg = Config::parse(ext)?;
        let session = self.session(&cfg, ext).await?;
        let bytes = self
            .call(&cfg, &session, DETAIL, vec![("id".into(), id.into())])
            .await?;
        let detail = Message::parse(&bytes)?;
        let returned_id = detail
            .int32(4)?
            .filter(|id| *id > 0)
            .ok_or(Failure::Parse("详情 id"))?
            .to_string();
        if returned_id != id {
            return Err(Failure::Parse("详情身份不匹配"));
        }
        let title = required(detail.string(9)?, "详情 name")?.to_string();
        let restricted = detail.integer(35)?.unwrap_or(0) != 0;
        let videos = detail.repeated(29)?;
        if videos.is_empty() || videos.len() > MAX_EPISODES {
            return Err(Failure::Parse("剧集数量"));
        }
        let mut labels = Vec::with_capacity(videos.len());
        let mut recipes = Vec::with_capacity(videos.len());
        for (index, video) in videos.into_iter().enumerate() {
            let video = Message::parse(video)?;
            let line = video
                .string(10)?
                .filter(|value| !value.is_empty())
                .unwrap_or("默认");
            let recipe = EpisodeRecipe {
                version: 2,
                content: returned_id.clone(),
                index,
                flag: line.into(),
                source: video.string(9)?.unwrap_or("").into(),
                value: required(video.string(4)?, "剧集 path")?.into(),
                binding: wire::nonce(32)?,
                restricted: restricted || video.integer(14)?.unwrap_or(0) != 0,
            };
            if !direct_media(&recipe.value) && recipe.source.is_empty() {
                return Err(Failure::Parse("剧集 source"));
            }
            labels.push((
                required(video.string(2)?, "剧集 title")?.to_string(),
                line.to_string(),
            ));
            recipes.push(recipe);
        }
        let image = cover(&detail)?;
        let description = detail
            .string(6)?
            .filter(|text| !text.is_empty())
            .map(str::to_string);
        let ids = self.remember_batch(&session, recipes).await?;
        let episodes = labels
            .into_iter()
            .zip(ids)
            .map(|((title, flag), id)| CspEpisode { id, title, flag })
            .collect();
        Ok(CspDetail {
            id: returned_id,
            title,
            cover: image,
            description,
            episodes,
        })
    }
    async fn play_inner(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>> {
        let (recipe, session) = self.selected(flag, id, ext).await?;
        if recipe.restricted {
            return Err(Failure::Restricted);
        }
        if direct_media(&recipe.value) {
            public_media(&recipe.value)?;
            self.active_session(&session).await?;
            return Ok(vec![CspPlay {
                url: recipe.value,
                headers: vec![],
                label: Some(recipe.flag),
            }]);
        }
        // Never refresh after validating an issued recipe: the decoder must use
        // exactly the generation captured with that recipe, or ask for detail.
        let cfg = Config::parse(ext)?;
        let bytes = self
            .call(
                &cfg,
                &session,
                PLAY,
                vec![
                    ("vodPlayFrom".into(), recipe.source),
                    ("playUrl".into(), recipe.value),
                ],
            )
            .await?;
        let data = Message::parse(&bytes)?;
        let media = required(data.string(1)?, "play_url")?;
        public_media(media)?;
        let mut headers = Vec::new();
        for entry in data.repeated(6)? {
            let entry = Message::parse(entry)?;
            let key = required(entry.string(1)?, "header key")?;
            let value = entry.string(2)?.unwrap_or("");
            reqwest::header::HeaderName::from_bytes(key.as_bytes())
                .map_err(|_| Failure::Parse("媒体 header key"))?;
            reqwest::header::HeaderValue::from_str(value)
                .map_err(|_| Failure::Parse("媒体 header value"))?;
            headers.retain(|(name, _): &(String, String)| !name.eq_ignore_ascii_case(key));
            headers.push((key.into(), value.into()));
        }
        Ok(vec![CspPlay {
            url: media.into(),
            headers,
            label: Some(recipe.flag),
        }])
    }
    async fn bounded<T>(
        &self,
        future: impl std::future::Future<Output = Result<T>>,
    ) -> std::result::Result<T, String> {
        tokio::time::timeout(Duration::from_secs(20), future)
            .await
            .map_err(|_| Failure::Transport.public())?
            .map_err(|failure| failure.public())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct EpisodeRecipe {
    version: u8,
    content: String,
    index: usize,
    flag: String,
    source: String,
    value: String,
    restricted: bool,
    binding: String,
}
fn required<'a>(value: Option<&'a str>, reason: &'static str) -> Result<&'a str> {
    value
        .filter(|value| !value.trim().is_empty())
        .ok_or(Failure::Parse(reason))
}
fn checked_http(raw: &str) -> Result<reqwest::Url> {
    let url = reqwest::Url::parse(raw).map_err(|_| Failure::Parse("HTTP 地址"))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(Failure::Parse("HTTP 地址形态"));
    }
    Ok(url)
}
fn checked_base(raw: &str) -> Result<String> {
    let url = checked_http(raw)?;
    if url.query().is_some() || url.fragment().is_some() {
        return Err(Failure::Parse("API 基址不能含 query/fragment"));
    }
    Ok(url.as_str().trim_end_matches('/').to_string())
}
fn public_media(raw: &str) -> Result<()> {
    checked_http(raw)?;
    // Exactly the same detector used by CspProvider's account-backed share
    // promotion. Never return a known share for another layer to resolve.
    if crate::pan::parse_share(raw).kind != crate::pan::PanKind::Unknown {
        return Err(Failure::Unsupported("网盘分享需独立选集和权限流程"));
    }
    Ok(())
}
fn direct_media(raw: &str) -> bool {
    checked_http(raw).is_ok_and(|url| {
        [
            "mp4", "m3u8", "flv", "mkv", "avi", "ts", "mov", "mpd", "m4a", "wmv",
        ]
        .iter()
        .any(|extension| {
            url.path()
                .to_ascii_lowercase()
                .ends_with(&format!(".{extension}"))
        })
    })
}
fn cover(message: &Message<'_>) -> Result<Option<String>> {
    let Some(cover) = message.merged_message(2)? else {
        return Ok(None);
    };
    Ok(cover
        .string(2)?
        .filter(|url| checked_http(url).is_ok())
        .map(str::to_string))
}
fn list_from(bytes: &[u8], page: u32) -> Result<CspList> {
    let message = Message::parse(bytes)?;
    let rows = message.repeated(1)?;
    let reported_total = message.int32(16)?;
    // Repeated items may be absent in a valid zero-hit or exhausted page.
    // Require a recognized Page field before accepting an empty batch so that
    // unrelated/unknown response messages cannot become successful empty pages.
    if rows.len() > 512 || (rows.is_empty() && reported_total.is_none()) {
        return Err(Failure::Parse("列表形态或长度"));
    }
    let mut items = Vec::with_capacity(rows.len());
    for row in rows {
        let row = Message::parse(row)?;
        items.push(CspItem {
            id: row
                .int32(3)?
                .filter(|id| *id > 0)
                .ok_or(Failure::Parse("列表 id"))?
                .to_string(),
            title: required(row.string(5)?, "列表 name")?.into(),
            cover: cover(&row)?,
            subtitle: row
                .string(13)?
                .filter(|value| !value.is_empty())
                .map(str::to_string),
        });
    }
    let (total, page_count) = wire::checked_page_total(reported_total)?;
    Ok(CspList {
        items,
        page,
        total,
        page_count,
    })
}

#[async_trait]
impl CspSite for ProtocolAppDrama {
    fn class(&self) -> &'static str {
        "AppDrama"
    }
    fn accepts_selected_episode_id(&self, id: &str) -> bool {
        id.starts_with("app-drama:v2|")
    }
    fn set_http_context(&self, store: Arc<crate::proxy::ProxyStore>, provider: &str) {
        let mut policy = self.policy.write().unwrap();
        self.client.set_proxy(store.clone(), provider);
        *policy = Some((store, provider.into()));
    }
    fn supports_search(&self) -> bool {
        true
    }
    fn needs_ext(&self) -> bool {
        true
    }
    async fn home(&self, ext: &str) -> std::result::Result<CspHome, String> {
        self.bounded(self.home_inner(ext)).await
    }
    async fn list(&self, tid: &str, page: u32, ext: &str) -> std::result::Result<CspList, String> {
        self.bounded(self.list_inner(tid, page, ext)).await
    }
    async fn search(
        &self,
        word: &str,
        page: u32,
        ext: &str,
    ) -> std::result::Result<CspList, String> {
        self.bounded(self.search_inner(word, page, ext)).await
    }
    async fn detail(&self, id: &str, ext: &str) -> std::result::Result<CspDetail, String> {
        self.bounded(self.detail_inner(id, ext)).await
    }
    async fn play(
        &self,
        flag: &str,
        id: &str,
        ext: &str,
    ) -> std::result::Result<Vec<CspPlay>, String> {
        self.bounded(self.play_inner(flag, id, ext)).await
    }
}

#[cfg(test)]
#[path = "app_drama_contract_tests.rs"]
mod contract_tests;

#[cfg(test)]
#[path = "app_drama_protocol_negative_tests.rs"]
mod negative_tests;

#[cfg(test)]
#[path = "app_drama_protocol_state_tests.rs"]
mod state_tests;
