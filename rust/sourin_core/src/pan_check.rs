//! 网盘分享链接的**零凭据预检**（T1b-预检，2026-10-31）
//!
//! # 它解决什么
//! ```text
//! Owner：「网盘不能播放 / 大多源还是无法播放」——其中一大类是**分享链接本身就是死的**
//! （过期 / 取消 / 审核未通过 / 链接根本不存在）。这类失败在点开之前就能发现。
//! 参考 APK（FongMi fork，见 .probe/reference-apk-benchmark.md ①/⑤）有一个原生预检引擎
//! `hp0`：对分享链接逐条探活，状态机 ok/locked/bad/uncertain/unsupported + 结果缓存。
//! 本模块按 T2 取证的协议底稿复刻它（四家先行 + UC 同族）。
//! ```
//!
//! # FFI 契约（后来人照着接）
//!
//! 命令：`tvbox_pan_check`（ffi.rs async 段）。**items 是序列化成字符串的 JSON 数组**
//! （ffi.rs 的参数解析器只有 `a.str(`，没有数组方法 ⇒ 外面包一层字符串）。
//!
//! 请求：
//! ```json
//! {"items": "[{\"url\":\"https://pan.quark.cn/s/abc123\",\"pwd\":\"8x2k\"},{\"url\":\"https://pan.baidu.com/s/1AbCd\"}]"}
//! ```
//! * `url` 必填；`pwd` 可选（用户已知的提取码；URL/正文里带的码 `pan::parse_share` 也会抓）。
//!
//! 响应（`results` 与 `items` 等长、等序；条数超过 [`MAX_CHECK_ITEMS`]（100）时
//! 截断并标注 `truncated` = 被丢弃的条数）：
//! ```json
//! {"ok":true,"truncated":0,"results":[
//!   {"url":"https://pan.quark.cn/s/abc123","kind":"quark","shareId":"abc123",
//!    "state":"ok","summary":"链接有效","cacheable":true}
//! ]}
//! ```
//! * `state` ∈ `ok / locked / bad / uncertain / unsupported`（照抄参考实现 hp0 的状态机）。
//! * `kind` 是 `pan.rs::PanKind::code()`（quark/uc/baidu/aliyun/xunlei/...）。
//! * `cacheable`：true = 该结果已写入进程内缓存（10 分钟 TTL）；
//!   `uncertain` 恒 false（风控/瞬态不可缓存），`unsupported` 恒 true（静态能力）。
//!
//! # 归因文案
//! 逐字来自参考实现 hp0 的用户文案：`链接有效 / 需要提取码 / 链接失效 /
//! 分享因审核未通过已失效 / 分享链接不存在 / 分享文件不存在 / 无法确认链接状态 /
//! 检测失败 / 链接格式无效`。唯一自造的一句是 unsupported 的
//! `该网盘的预检尚未接入`（hp0 没有对应文案——它没有"没接入"的盘）。
//!
//! # 各家口径（证据：.probe/reference-apk-benchmark.md ⑤ + pan_list.rs 实测段）
//! ```text
//! 夸克 / UC：page → token → detail 三步，HTTP 在本模块发（端点可注入 ⇒
//!   协议门禁起 axum 假服务器回放），**解析器复用 pan_list.rs 的 pub 纯函数**。
//!   UC 的 token 主机是 pc-api.uc.cn（drive.uc.cn 实测 403，pan_list.rs:487）。
//! 百度：page（拿 cookie + 重定向后的 surl）→ [verify 提交已知提取码] →
//!   share/list?web=1...（hp0 的 JSON 端点）。
//! 迅雷：drive/v1/share（hp0 的常量与头部逐字）；签名被拒时走 captcha/init 拿
//!   captcha_token 重试一次，再被拒 ⇒ uncertain。
//!   ⚠️ **captcha_sign 的计算算法未取证**（参考实现里被字符串加密）⇒ 不猜。
//! 阿里：adrive/v3/share_link/get_share_by_anonymous（零凭据，hp0）。
//! 115/123/天翼/光鸭/139/caiyun：hp0 里被字符串加密，本阶段 unsupported（如实）。
//! ```
//!
//! # 并发与风控
//! ```text
//! · 批内并发上限 Semaphore(4)（hls_facts/registry 的限流先例）；
//! · 429 / 风控文案响应 ⇒ 该 host 冷却 30s（冷却期内的请求直接 uncertain，不硬重试）；
//! · reqwest 一律 .no_proxy()（pan_list 纪律③：本机代理会把 200 变 502）。
//! ```

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::pan::PanKind;

// ══════════════════════════════════════════════════════════════════════
//  状态机（照抄参考实现 hp0：ok/locked/bad/uncertain/unsupported）
// ══════════════════════════════════════════════════════════════════════

/// 一次预检的状态（hp0 状态机的五档，机器可读码稳定——会进结果 JSON 与缓存键位）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckState {
    /// 分享在、文件非空 ⇒ 值得转存/取直链
    Ok,
    /// 需要提取码（**不等于死**：用户有码就能过——UI 仍可点，lead 批复③）
    Locked,
    /// 死链（过期/取消/违规/审核未通过/文件不存在）
    Bad,
    /// 没测出来（网络失败/风控/签名被拒）——不缓存、不冤枉
    Uncertain,
    /// 该盘的预检没接入（115/123/天翼/139/光鸭/caiyun，hp0 密文未解）
    Unsupported,
}

impl CheckState {
    /// 稳定的机器可读码（结果 JSON 的 `state` 字段）
    pub fn code(self) -> &'static str {
        match self {
            CheckState::Ok => "ok",
            CheckState::Locked => "locked",
            CheckState::Bad => "bad",
            CheckState::Uncertain => "uncertain",
            CheckState::Unsupported => "unsupported",
        }
    }
}

// ── 归因文案（逐字来自 hp0 的用户文案；unsupported 一句自造，见模块头） ──
pub const TEXT_OK: &str = "链接有效";
pub const TEXT_LOCKED: &str = "需要提取码";
pub const TEXT_DEAD: &str = "链接失效";
pub const TEXT_AUDIT: &str = "分享因审核未通过已失效";
pub const TEXT_MISSING: &str = "分享链接不存在";
pub const TEXT_NO_FILE: &str = "分享文件不存在";
pub const TEXT_UNVERIFIABLE: &str = "无法确认链接状态";
pub const TEXT_FAILED: &str = "检测失败";
pub const TEXT_INVALID: &str = "链接格式无效";
pub const TEXT_UNSUPPORTED: &str = "该网盘的预检尚未接入";

/// 一次预检的产出（state + 给用户的 summary + 是否可缓存）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckOutcome {
    pub state: CheckState,
    pub summary: String,
    pub cacheable: bool,
}

impl CheckOutcome {
    fn new(state: CheckState, summary: impl Into<String>) -> Self {
        // ★ 缓存纪律：uncertain 恒不可缓存（瞬态/风控——缓存它就是把"没测出来"固化）
        Self { state, summary: summary.into(), cacheable: state != CheckState::Uncertain }
    }
}

/// 上游响应/错误文本 → 状态归因（关键词表来自 hp0 的归因词：取消/过期/违规/失效/
/// 不存在/审核 + 提取码/密码/HasPwd + 频繁/limit/exceed/frequency/风控）。
///
/// ★ 顺序即优先级：**风控/限流最先判**（它命中时该 host 要进冷却，且不能被
///   "提取码"之类的误配抢先）。门禁 `risk_keyword_wins_over_locked` 钉住。
fn map_upstream_text(text: &str) -> Option<CheckOutcome> {
    let t = text.to_lowercase();
    // ① 风控/限流 → uncertain（不可缓存）
    const RISK: [&str; 7] =
        ["请求过于频繁", "频繁", "风控", "frequency", "limit", "exceed", "critical_pressure"];
    if RISK.iter().any(|k| t.contains(k)) {
        return Some(CheckOutcome::new(CheckState::Uncertain, TEXT_UNVERIFIABLE));
    }
    // ② 提取码 → locked
    const LOCKED: [&str; 4] = ["提取码", "密码", "pass_code", "haspwd"];
    if LOCKED.iter().any(|k| t.contains(k)) {
        return Some(CheckOutcome::new(CheckState::Locked, TEXT_LOCKED));
    }
    // ③ 死链归因
    if t.contains("审核") || t.contains("illegal") {
        return Some(CheckOutcome::new(CheckState::Bad, TEXT_AUDIT));
    }
    const MISSING: [&str; 4] = ["不存在", "not found", "sharenotfound", "shareinfonotfound"];
    if MISSING.iter().any(|k| t.contains(k)) {
        return Some(CheckOutcome::new(CheckState::Bad, TEXT_MISSING));
    }
    const DEAD: [&str; 7] =
        ["失效", "过期", "取消", "违规", "shareexpirederror", "expired", "cancel"];
    if DEAD.iter().any(|k| t.contains(k)) {
        return Some(CheckOutcome::new(CheckState::Bad, TEXT_DEAD));
    }
    None
}

fn quark_family_response_failure(http_status: u16, body: &str) -> Option<CheckOutcome> {
    if matches!(http_status, 403 | 429) {
        return Some(CheckOutcome::new(CheckState::Uncertain, TEXT_UNVERIFIABLE));
    }
    if http_status >= 500 {
        return Some(CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED));
    }
    let response = serde_json::from_str::<Value>(body).ok();
    let api_failed = response.as_ref().is_some_and(|value| {
        value.get("code").is_some_and(|code| code.as_i64() != Some(0))
            || value.get("status").is_some_and(|status| !matches!(status.as_i64(), Some(0 | 200)))
            || (value.is_object()
                && value.get("code").is_none()
                && value.get("data").is_none()
                && ["message", "error", "error_description", "msg", "errmsg"]
                    .iter()
                    .any(|key| value.get(key).is_some()))
    });
    if (200..300).contains(&http_status) && !api_failed {
        return None;
    }
    // Error fields are authoritative only in a failed envelope, never in data.
    let mut error_text = String::new();
    if let Some(value) = response {
        for key in ["message", "error", "error_description", "msg", "errmsg", "code"] {
            if let Some(text) = value.get(key).and_then(Value::as_str) {
                error_text.push_str(text);
                error_text.push('\n');
            }
        }
        if let Some(error) = value.get("error").and_then(Value::as_object) {
            for key in ["message", "code", "name"] {
                if let Some(text) = error.get(key).and_then(Value::as_str) {
                    error_text.push_str(text);
                    error_text.push('\n');
                }
            }
        }
    }
    Some(
        map_upstream_text(&error_text)
            .unwrap_or_else(|| CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED)),
    )
}

// ══════════════════════════════════════════════════════════════════════
//  端点（可注入 ⇒ 协议门禁用 axum 假服务器回放）
// ══════════════════════════════════════════════════════════════════════

/// 各家端点（Default = 真网端点；测试注入 127.0.0.1 假服务器）
#[derive(Debug, Clone)]
pub struct PanEndpoints {
    /// 夸克分享页（只为拿 cookie）
    pub quark_page: String,
    /// hp0 取证：token 在 drive-h；pan_list 实测 drive-pc 两步同主机可用 ⇒ 以实测为准
    pub quark_token: String,
    pub quark_detail: String,
    pub uc_page: String,
    /// ★ UC 的 token 主机是 pc-api.uc.cn（drive.uc.cn 实测 403 —— pan_list.rs:487）
    pub uc_token: String,
    pub uc_detail: String,
    /// 百度分享页（拿 cookie + 重定向后的 surl）
    pub baidu_page: String,
    /// 百度 verify（提交提取码）
    pub baidu_verify: String,
    /// 百度 share/list（JSON 端点，hp0）
    pub baidu_list: String,
    pub xunlei_captcha: String,
    pub xunlei_share: String,
    pub aliyun_anon: String,
}

impl Default for PanEndpoints {
    fn default() -> Self {
        Self {
            quark_page: "https://pan.quark.cn/s".into(),
            quark_token: "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token".into(),
            quark_detail: "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail".into(),
            uc_page: "https://drive.uc.cn/s".into(),
            uc_token: "https://pc-api.uc.cn/1/clouddrive/share/sharepage/token".into(),
            uc_detail: "https://pc-api.uc.cn/1/clouddrive/share/sharepage/detail".into(),
            baidu_page: "https://pan.baidu.com/s".into(),
            baidu_verify: "https://pan.baidu.com/share/verify".into(),
            baidu_list: "https://pan.baidu.com/share/list".into(),
            xunlei_captcha: "https://xluser-ssl.xunlei.com/v1/shield/captcha/init".into(),
            xunlei_share: "https://pan.xunlei.com/drive/v1/share".into(),
            aliyun_anon:
                "https://api.aliyundrive.com/adrive/v3/share_link/get_share_by_anonymous".into(),
        }
    }
}

// UA（hp0 逐字：桌面 Chrome/124 与 Android Mobile Chrome/124 两组）
const UA_DESKTOP: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
     (KHTML, like Gecko) Chrome/124.0 Safari/537.36";
const UA_MOBILE: &str = "Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 \
     (KHTML, like Gecko) Chrome/124.0 Safari/537.36";
// hp0 的迅雷常量（逐字；两个值按出现顺序分给 x-device-id / x-client-id——
// 分配次序是推断，鉴权被拒时会落 uncertain，不影响状态机正确性）
const XL_DEVICE_ID: &str = "5505bd0cab8c9469b98e5891d9fb3e0d";
const XL_CLIENT_ID: &str = "ZUBzD9J_XPXfn7f7";
const XL_CLIENT_VERSION: &str = "1.10.0.2633";
const XL_PACKAGE: &str = "com.xunlei.browser";

const HTTP_TIMEOUT: Duration = Duration::from_secs(12);
const COOLDOWN: Duration = Duration::from_secs(30);
const CACHE_TTL: Duration = Duration::from_secs(600); // 10 分钟

/// 单次命令允许的**最大条数**（超出截断并标注 truncated——批量扇出要有闸，P3-5）
pub const MAX_CHECK_ITEMS: usize = 100;

// ══════════════════════════════════════════════════════════════════════
//  执行器
// ══════════════════════════════════════════════════════════════════════

struct Shared {
    endpoints: PanEndpoints,
    client: reqwest::Client,
    sem: Arc<tokio::sync::Semaphore>,
    /// drive_check_cache 语义：键 = 归一化 URL，值 = (结果, 过期时刻)
    cache: Mutex<HashMap<String, (CheckOutcome, Instant)>>,
    /// 风控冷却：键 = host，值 = 冷却截止时刻
    cooldown: Mutex<HashMap<String, Instant>>,
}

/// 预检执行器（缓存/冷却/并发上限长在 `Arc<Shared>` 上 ⇒ 批内任务可共享，
/// 测试各造一份互不污染）
#[derive(Clone)]
pub struct PanChecker {
    shared: Arc<Shared>,
}

impl Default for PanChecker {
    fn default() -> Self {
        Self::with_endpoints(PanEndpoints::default())
    }
}

impl PanChecker {
    /// 真网执行器（FFI 走全局单例，见 [`global_checker`]）
    pub fn new() -> Self {
        Self::default()
    }

    /// 测试用：注入假服务器端点
    pub fn with_endpoints(endpoints: PanEndpoints) -> Self {
        let client = reqwest::Client::builder()
            // ★ 硬纪律：直连（pan_list 纪律③——本机代理会把 200 变 502）
            .no_proxy()
            .timeout(HTTP_TIMEOUT)
            .build()
            .expect("reqwest client 建不出来");
        Self {
            shared: Arc::new(Shared {
                endpoints,
                client,
                sem: Arc::new(tokio::sync::Semaphore::new(4)),
                cache: Mutex::new(HashMap::new()),
                cooldown: Mutex::new(HashMap::new()),
            }),
        }
    }

    /// 批量预检：results 与 items 等长等序（见模块头的 JSON 形状）
    pub async fn check(&self, items: &[Value]) -> Vec<Value> {
        let mut outs: Vec<Option<Value>> = vec![None; items.len()];
        let mut join = tokio::task::JoinSet::new();
        for (idx, item) in items.iter().enumerate() {
            let url = item.get("url").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let pwd = item.get("pwd").and_then(|v| v.as_str()).map(|s| s.to_string());
            let shared = Arc::clone(&self.shared);
            join.spawn(async move {
                let checker = PanChecker { shared };
                (idx, checker.check_one(&url, pwd.as_deref()).await)
            });
        }
        while let Some(done) = join.join_next().await {
            let Ok((idx, (outcome, kind, share_id))) = done else { continue };
            let url = items
                .get(idx)
                .and_then(|v| v.get("url"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            outs[idx] = Some(json!({
                "url": url,
                "kind": kind.code(),
                "shareId": share_id,
                "state": outcome.state.code(),
                "summary": outcome.summary,
                "cacheable": outcome.cacheable,
            }));
        }
        outs.into_iter().flatten().collect()
    }

    /// 单条预检（分类 → 缓存 → 冷却 → 分发）
    pub(crate) async fn check_one(&self, url: &str, pwd: Option<&str>) -> (CheckOutcome, PanKind, String) {
        let share = crate::pan::parse_share(url);
        let kind = share.kind;
        let share_id = share.share_id.clone();
        // 提取码：调用方显式给的 > URL/正文里抓的
        let pwd_owned: Option<String> = pwd.map(|s| s.to_string()).or(share.pwd_in_url);
        // 同一链接补提取码后必须重新检查，不能沿用无码时的 locked 缓存。
        let key = format!("{}\u{0}{}", url.trim(), pwd_owned.as_deref().unwrap_or(""));

        // ① 分类层第一刀：**不是分享链接**（认不出网盘）⇒ bad + 链接格式无效（hp0.d）
        if kind == PanKind::Unknown {
            return (CheckOutcome::new(CheckState::Bad, TEXT_INVALID), kind, share_id);
        }
        // ② 分类层第二刀：**没接入预检的盘**（115/123/天翼/光鸭/139/caiyun）。
        //    ★ 必须排在"没有分享 id"之前：`app.guangyapan.com/pan` 这类不带 /s/<id>
        //      的合法分享页 URL，老实说"没接入"比冤它"格式无效"准。
        if !is_implemented(kind) {
            return (CheckOutcome::new(CheckState::Unsupported, TEXT_UNSUPPORTED), kind, share_id);
        }
        // ③ 已接入的盘但没有分享 id ⇒ bad + 链接格式无效（hp0.d）
        if share_id.is_empty() {
            return (CheckOutcome::new(CheckState::Bad, TEXT_INVALID), kind, share_id);
        }
        // ④ 缓存（写也在本层：调用方走 check() 批层或直接 check_one 语义一致）
        if let Ok(c) = self.shared.cache.lock() {
            if let Some((outcome, until)) = c.get(&key) {
                if *until > Instant::now() {
                    return (outcome.clone(), kind, share_id);
                }
            }
        }
        // ⑤ 该 host 冷却中 ⇒ 直接 uncertain（退避，不是硬重试）
        let host = host_of(url.trim());
        if let Ok(cd) = self.shared.cooldown.lock() {
            if let Some(until) = cd.get(&host) {
                if *until > Instant::now() {
                    return (
                        CheckOutcome::new(CheckState::Uncertain, TEXT_UNVERIFIABLE),
                        kind,
                        share_id,
                    );
                }
            }
        }
        // ⑥ 分发（unsupported 的盘不发请求）
        let outcome = match kind {
            PanKind::Quark | PanKind::Uc | PanKind::Baidu | PanKind::Aliyun | PanKind::Xunlei => {
                let _permit = self.shared.sem.clone().acquire_owned().await;
                let out = match kind {
                    PanKind::Quark => self.check_quark(&share_id, pwd_owned.as_deref()).await,
                    PanKind::Uc => self.check_uc(&share_id, pwd_owned.as_deref()).await,
                    PanKind::Baidu => self.check_baidu(&share_id, pwd_owned.as_deref()).await,
                    PanKind::Aliyun => self.check_aliyun(&share_id).await,
                    PanKind::Xunlei => self.check_xunlei(&share_id, pwd_owned.as_deref()).await,
                    _ => unreachable!("外层 match 已收窄"),
                };
                // 风控/签名被拒（unverifiable）⇒ 该 host 进冷却
                if out.state == CheckState::Uncertain && out.summary == TEXT_UNVERIFIABLE {
                    if let Ok(mut cd) = self.shared.cooldown.lock() {
                        cd.insert(host, Instant::now() + COOLDOWN);
                    }
                }
                out
            }
            _ => unreachable!("② 已拦截未接入的盘"),
        };
        if outcome.cacheable {
            if let Ok(mut c) = self.shared.cache.lock() {
                c.insert(key, (outcome.clone(), Instant::now() + CACHE_TTL));
            }
        }
        (outcome, kind, share_id)
    }

    async fn get_text(
        &self,
        url: &str,
        ua: &str,
        headers: &[(&str, String)],
    ) -> Result<(u16, String), String> {
        let mut req = self.shared.client.get(url).header(reqwest::header::USER_AGENT, ua);
        for (k, v) in headers {
            req = req.header(*k, v);
        }
        let r = req.send().await.map_err(|e| format!("请求失败：{e}"))?;
        let st = r.status().as_u16();
        let body = r.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        Ok((st, body))
    }

    async fn page_cookies(&self, page: &str, ua: &str) -> String {
        match self.shared.client.get(page).header(reqwest::header::USER_AGENT, ua).send().await {
            Ok(r) => cookies_of(&r),
            Err(_) => String::new(),
        }
    }

    // ── 夸克 / UC（同族：page → token → detail；解析器复用 pan_list 的 pub 纯函数） ──

    async fn check_quark(&self, share_id: &str, pwd: Option<&str>) -> CheckOutcome {
        self.check_quark_family(
            PanKind::Quark,
            share_id,
            pwd,
            &format!("{}/{}", self.shared.endpoints.quark_page, share_id),
            &self.shared.endpoints.quark_token,
            &self.shared.endpoints.quark_detail,
            "ucpro",
            "pc",
            UA_DESKTOP,
            "https://pan.quark.cn",
            crate::pan_list::parse_quark_token,
            crate::pan_list::parse_quark_detail,
        )
        .await
    }

    async fn check_uc(&self, share_id: &str, pwd: Option<&str>) -> CheckOutcome {
        self.check_quark_family(
            PanKind::Uc,
            share_id,
            pwd,
            &format!("{}/{}", self.shared.endpoints.uc_page, share_id),
            &self.shared.endpoints.uc_token,
            &self.shared.endpoints.uc_detail,
            "UCBrowser",
            "pc",
            UA_DESKTOP,
            "https://drive.uc.cn",
            crate::pan_list::parse_uc_token,
            crate::pan_list::parse_uc_detail,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn check_quark_family(
        &self,
        kind: PanKind,
        share_id: &str,
        pwd: Option<&str>,
        page: &str,
        token_url: &str,
        detail_url: &str,
        pr: &str,
        fr: &str,
        ua: &str,
        origin: &str,
        parse_token: fn(&str) -> Result<(String, String), String>,
        parse_detail: fn(&str) -> Result<Vec<crate::pan_list::PanEntry>, String>,
    ) -> CheckOutcome {
        // ① 分享页拿 cookie（尽力而为；pan_list 实测：UC 的 token 必须带它）
        let cookies = self.page_cookies(page, ua).await;
        // ② token（匿名，提交已知提取码）
        let mut req = self
            .shared
            .client
            .post(token_url)
            .query(&[("pr", pr), ("fr", fr)])
            .header(reqwest::header::USER_AGENT, ua)
            .header(reqwest::header::ORIGIN, origin)
            .header(reqwest::header::REFERER, page)
            .json(&json!({
                "pwd_id": share_id,
                "passcode": pwd.unwrap_or(""),
                "support_visit_limit_private_share": true,
            }));
        if !cookies.is_empty() {
            req = req.header(reqwest::header::COOKIE, cookies.clone());
        }
        let (status, body) = match req.send().await {
            Ok(r) => {
                let status = r.status().as_u16();
                match r.text().await {
                    Ok(t) => (status, t),
                    Err(_) => return CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
                }
            }
            Err(_) => return CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
        };
        if let Some(mapped) = quark_family_response_failure(status, &body) {
            return mapped;
        }
        let (stoken, _title) = match parse_token(&body) {
            Ok(v) => v,
            Err(_) => return CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
        };
        // ③ detail（非空文件列表 = 链接有效；根目录 pdir_fid=0 —— nav_params 同款）
        let mut detail = match reqwest::Url::parse(detail_url) {
            Ok(url) => url,
            Err(_) => return CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
        };
        detail.query_pairs_mut().extend_pairs([
            ("pr", pr),
            ("fr", fr),
            ("pwd_id", share_id),
            ("stoken", stoken.as_str()),
            ("force", "0"),
            ("_page", "1"),
            ("_size", "50"),
        ]);
        detail.query_pairs_mut().extend_pairs(crate::pan_list::nav_params(kind, None));
        let mut headers = vec![("Origin", origin.to_string()), ("Referer", page.to_string())];
        if !cookies.is_empty() {
            headers.push(("Cookie", cookies));
        }
        match self.get_text(detail.as_str(), ua, &headers).await {
            Ok((status, body)) => {
                if let Some(mapped) = quark_family_response_failure(status, &body) {
                    return mapped;
                }
                match parse_detail(&body) {
                    Ok(entries) if entries.is_empty() => {
                        CheckOutcome::new(CheckState::Bad, TEXT_NO_FILE)
                    }
                    Ok(_) => CheckOutcome::new(CheckState::Ok, TEXT_OK),
                    Err(_) => CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
                }
            }
            Err(_) => CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
        }
    }

    // ── 百度：复用生产只读协议；匿名检查不加载账号或扫描成功元数据 ──

    async fn check_baidu(&self, share_id: &str, pwd: Option<&str>) -> CheckOutcome {
        use crate::csp::pan_baidu_play::{
            inspect_anonymous, BaiduEndpoints, BaiduFailureCause, BaiduInspection, BaiduStage,
        };
        let endpoints = BaiduEndpoints {
            page: self.shared.endpoints.baidu_page.clone(),
            verify: self.shared.endpoints.baidu_verify.clone(),
            list: self.shared.endpoints.baidu_list.clone(),
        };
        match inspect_anonymous(&endpoints, share_id, pwd.unwrap_or("")).await {
            Ok(BaiduInspection::Files) => CheckOutcome::new(CheckState::Ok, TEXT_OK),
            Ok(BaiduInspection::Empty) => CheckOutcome::new(CheckState::Bad, TEXT_NO_FILE),
            Ok(BaiduInspection::NeedsPasscode) => CheckOutcome::new(CheckState::Locked, TEXT_LOCKED),
            Err(failure) => {
                match failure.cause {
                    BaiduFailureCause::Http(403 | 429) => {
                        return CheckOutcome::new(CheckState::Uncertain, TEXT_UNVERIFIABLE);
                    }
                    BaiduFailureCause::Business(BaiduStage::Verify, -9) => {
                        // Official verify explicitly identifies -9 as extraction-code refusal.
                        return CheckOutcome::new(CheckState::Locked, TEXT_LOCKED);
                    }
                    BaiduFailureCause::Business(_, -6 | -12 | -62 | -19 | -63 | 8046 | -64 | -65) => {
                        return CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED);
                    }
                    BaiduFailureCause::Business(_, _) => {}
                    _ => return CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
                }
                let error_text = failure.error_messages.join("\n").to_lowercase();
                // An authentication/captcha refusal cannot establish a dead share.
                if ["登录", "认证", "验证码", "captcha", "authentication", "unauthorized",
                    "not logged", "login", "token", "cookie", "session", "credential", "bduss"]
                    .iter().any(|word| error_text.contains(word))
                {
                    return CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED);
                }
                map_upstream_text(&error_text)
                    .unwrap_or_else(|| CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED))
            }
        }
    }

    // ── 迅雷（captcha/init → drive/v1/share；签名未取证 ⇒ 被拒落 uncertain） ──

    async fn check_xunlei(&self, share_id: &str, pwd: Option<&str>) -> CheckOutcome {
        let share_url = format!(
            "{}?share_id={share_id}&pass_code={}&limit=100&pass_code_token=&page_token=&thumbnail_size=SIZE_SMALL",
            self.shared.endpoints.xunlei_share,
            pwd.unwrap_or(""),
        );
        let headers: [(&str, String); 6] = [
            ("x-device-id", XL_DEVICE_ID.into()),
            ("x-client-id", XL_CLIENT_ID.into()),
            ("x-client-version", XL_CLIENT_VERSION.into()),
            ("x-package-name", XL_PACKAGE.into()),
            ("Origin", "https://pan.xunlei.com".into()),
            ("Referer", "https://pan.xunlei.com/".into()),
        ];
        let (st, body) = match self.get_text(&share_url, UA_MOBILE, &headers).await {
            Ok(v) => v,
            Err(_) => return CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
        };
        if let Some(mapped) = map_upstream_text(&body) {
            return mapped;
        }
        // 签名/验证码被拒 ⇒ init 拿 captcha_token 重试一次；再被拒就 uncertain（不猜签名）
        if body.contains("captcha") || st == 403 {
            if let Ok((_, init_body)) =
                self.get_text(&self.shared.endpoints.xunlei_captcha, UA_MOBILE, &headers).await
            {
                let token = serde_json::from_str::<Value>(&init_body)
                    .ok()
                    .and_then(|v| {
                        v.get("captcha_token")
                            .or_else(|| v.get("data").and_then(|d| d.get("captcha_token")))
                            .and_then(|x| x.as_str())
                            .map(|s| s.to_string())
                    })
                    .unwrap_or_default();
                if !token.is_empty() {
                    let retry = format!("{share_url}&captcha_token={token}");
                    if let Ok((_, body2)) = self.get_text(&retry, UA_MOBILE, &headers).await {
                        if let Some(mapped) = map_upstream_text(&body2) {
                            return mapped;
                        }
                        if let Ok(v) = serde_json::from_str::<Value>(&body2) {
                            return xunlei_verdict(&v);
                        }
                    }
                }
            }
            return CheckOutcome::new(CheckState::Uncertain, TEXT_UNVERIFIABLE);
        }
        match serde_json::from_str::<Value>(&body) {
            Ok(v) => xunlei_verdict(&v),
            Err(_) => CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
        }
    }

    // ── 阿里（零凭据 anonymous 端点） ──

    async fn check_aliyun(&self, share_id: &str) -> CheckOutcome {
        let url = format!("{}?share_id={share_id}", self.shared.endpoints.aliyun_anon);
        match self
            .get_text(&url, UA_DESKTOP, &[("Referer", "https://www.alipan.com".into())])
            .await
        {
            Ok((_, body)) => {
                if let Some(mapped) = map_upstream_text(&body) {
                    return mapped;
                }
                let v: Value = match serde_json::from_str(&body) {
                    Ok(v) => v,
                    Err(_) => return CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
                };
                // hp0 归因词（frequency/limit/exceed/cancel/expired/illegal）出现在
                // code/status/message 字段里 ⇒ 先过一遍关键词归因再谈 has_share
                let fields = ["code", "status", "message"]
                    .iter()
                    .filter_map(|k| v.get(*k).and_then(|x| x.as_str()))
                    .collect::<Vec<_>>()
                    .join(" ");
                if let Some(mapped) = map_upstream_text(&fields) {
                    return mapped;
                }
                let has_share = v
                    .get("has_share")
                    .or_else(|| v.get("hasShare"))
                    .and_then(|x| x.as_bool())
                    .unwrap_or(false);
                let file_count = v
                    .get("file_count")
                    .or_else(|| v.get("fileCount"))
                    .and_then(|x| x.as_i64())
                    .unwrap_or(0);
                if has_share || file_count > 0 {
                    CheckOutcome::new(CheckState::Ok, TEXT_OK)
                } else {
                    CheckOutcome::new(CheckState::Uncertain, TEXT_UNVERIFIABLE)
                }
            }
            Err(_) => CheckOutcome::new(CheckState::Uncertain, TEXT_FAILED),
        }
    }
}

/// 迅雷 share 响应的判据（hp0：`share_status_text` OK / CRITICAL_PRESSURE / pass_code）
fn xunlei_verdict(v: &Value) -> CheckOutcome {
    let status = v
        .get("share_status_text")
        .or_else(|| v.get("shareStatusText"))
        .and_then(|x| x.as_str())
        .unwrap_or("");
    match status {
        "OK" => CheckOutcome::new(CheckState::Ok, TEXT_OK),
        "CRITICAL_PRESSURE" => CheckOutcome::new(CheckState::Uncertain, TEXT_UNVERIFIABLE),
        _ => {
            let lower = status.to_lowercase();
            if lower.contains("pass") || lower.contains("code") {
                CheckOutcome::new(CheckState::Locked, TEXT_LOCKED)
            } else if lower.contains("expired") || lower.contains("cancel") {
                CheckOutcome::new(CheckState::Bad, TEXT_DEAD)
            } else if lower.contains("audit") || lower.contains("illegal") {
                CheckOutcome::new(CheckState::Bad, TEXT_AUDIT)
            } else {
                CheckOutcome::new(CheckState::Uncertain, TEXT_UNVERIFIABLE)
            }
        }
    }
}

/// 本阶段**已接入**预检的盘（其余一律 unsupported；115/123/天翼/139/光鸭/caiyun
/// 的端点在参考实现里被字符串加密，如实不做——不许猜）
fn is_implemented(kind: PanKind) -> bool {
    matches!(kind, PanKind::Quark | PanKind::Uc | PanKind::Baidu | PanKind::Aliyun | PanKind::Xunlei)
}

/// 从 URL 取 host（小写、不含端口；与 pan.rs::host_of 同判据，此处私有小抄）
fn host_of(url: &str) -> String {
    let after = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    let hostport = after.split(['/', '?', '#']).next().unwrap_or("");
    let hostport = hostport.rsplit_once('@').map(|(_, h)| h).unwrap_or(hostport);
    hostport.split(':').next().unwrap_or("").to_ascii_lowercase()
}

/// Set-Cookie 头拼成一条 Cookie 值（pan_list::cookies_of 是私有 ⇒ 同判据重写）
fn cookies_of(resp: &reqwest::Response) -> String {
    let mut out = Vec::new();
    for v in resp.headers().get_all(reqwest::header::SET_COOKIE).iter() {
        if let Ok(s) = v.to_str() {
            if let Some(first) = s.split(';').next() {
                let kv = first.trim();
                if kv.contains('=') {
                    out.push(kv.to_string());
                }
            }
        }
    }
    out.join("; ")
}

// ══════════════════════════════════════════════════════════════════════
//  FFI 命令
// ══════════════════════════════════════════════════════════════════════

static GLOBAL: OnceLock<PanChecker> = OnceLock::new();

#[cfg(test)]
thread_local! {
    static TEST_GLOBAL_CHECKER: std::cell::Cell<Option<&'static PanChecker>> = const {
        std::cell::Cell::new(None)
    };
}

#[cfg(test)]
pub(crate) struct ScopedCheckerOverride {
    previous: Option<&'static PanChecker>,
    thread_bound: std::marker::PhantomData<std::rc::Rc<()>>,
}

#[cfg(test)]
impl Drop for ScopedCheckerOverride {
    fn drop(&mut self) {
        TEST_GLOBAL_CHECKER.with(|slot| slot.set(self.previous));
    }
}

/// Current-thread tests only; the guard is not Send and restores nested overrides.
#[cfg(test)]
pub(crate) fn override_global_checker_for_tests(checker: &'static PanChecker) -> ScopedCheckerOverride {
    ScopedCheckerOverride {
        previous: TEST_GLOBAL_CHECKER.with(|slot| slot.replace(Some(checker))),
        thread_bound: std::marker::PhantomData,
    }
}

pub(crate) fn global_checker() -> &'static PanChecker {
    #[cfg(test)]
    if let Some(checker) = TEST_GLOBAL_CHECKER.with(|slot| slot.get()) {
        return checker;
    }
    GLOBAL.get_or_init(PanChecker::new)
}

/// `tvbox_pan_check`：形状契约见模块头（items 是序列化成字符串的 JSON 数组）。
///
/// ★ 条数上限 [`MAX_CHECK_ITEMS`]（100）：超出部分**截断**，并在结果里标注
///   `truncated`（被丢弃的条数）。截断是防御，不是错误——调用方一次塞几千条
///   线路不该把并发打穿（限流再加倍也兜不住批量扇出）。
pub async fn command_check(items_json: &str) -> Result<Value, String> {
    let mut items: Vec<Value> =
        serde_json::from_str(items_json).map_err(|e| format!("items 不是 JSON 数组：{e}"))?;
    let truncated = items.len().saturating_sub(MAX_CHECK_ITEMS);
    if truncated > 0 {
        items.truncate(MAX_CHECK_ITEMS);
    }
    let results = global_checker().check(&items).await;
    Ok(json!({ "ok": true, "results": results, "truncated": truncated }))
}

// ══════════════════════════════════════════════════════════════════════
//  门禁
// ══════════════════════════════════════════════════════════════════════

#[cfg(test)]
#[path = "pan_check_baidu_protocol_tests.rs"]
mod baidu_protocol_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    // ── 纯层：状态机与文案 ──

    #[test]
    fn state_codes_are_stable() {
        // 这些码进结果 JSON 与缓存键位，改了就是破坏兼容
        assert_eq!(CheckState::Ok.code(), "ok");
        assert_eq!(CheckState::Locked.code(), "locked");
        assert_eq!(CheckState::Bad.code(), "bad");
        assert_eq!(CheckState::Uncertain.code(), "uncertain");
        assert_eq!(CheckState::Unsupported.code(), "unsupported");
    }

    /// 归因文案逐字（hp0 用户文案——同一句话只有一个来源）
    #[test]
    fn texts_are_verbatim_from_hp0() {
        assert_eq!(TEXT_OK, "链接有效");
        assert_eq!(TEXT_LOCKED, "需要提取码");
        assert_eq!(TEXT_DEAD, "链接失效");
        assert_eq!(TEXT_AUDIT, "分享因审核未通过已失效");
        assert_eq!(TEXT_MISSING, "分享链接不存在");
        assert_eq!(TEXT_NO_FILE, "分享文件不存在");
        assert_eq!(TEXT_UNVERIFIABLE, "无法确认链接状态");
        assert_eq!(TEXT_FAILED, "检测失败");
        assert_eq!(TEXT_INVALID, "链接格式无效");
    }

    #[test]
    fn cacheability_policy() {
        assert!(CheckOutcome::new(CheckState::Ok, "").cacheable);
        assert!(CheckOutcome::new(CheckState::Locked, "").cacheable);
        assert!(CheckOutcome::new(CheckState::Bad, "").cacheable);
        assert!(CheckOutcome::new(CheckState::Unsupported, "").cacheable);
        // ★ uncertain 恒不可缓存（瞬态/风控——缓存它就是把"没测出来"固化）
        assert!(!CheckOutcome::new(CheckState::Uncertain, "").cacheable);
    }

    #[test]
    fn risk_keyword_wins_over_locked() {
        // ★ 风控词表含 "limit"，locked 词表含 "pass_code"——混合响应必须先判风控
        //   （它还带 30s 冷却副作用，判错顺序会把限流误判成"输提取码"）。
        let out = map_upstream_text("请求过于频繁，需要 pass_code").unwrap();
        assert_eq!(out.state, CheckState::Uncertain, "★ 风控优先于 locked");
        // 注入反面：把 map_upstream_text 的 ①② 两段对调 ⇒ 本条红。
    }

    #[test]
    fn maps_each_attribution_keyword() {
        assert_eq!(map_upstream_text("分享已过期").unwrap().state, CheckState::Bad);
        assert_eq!(map_upstream_text("分享已过期").unwrap().summary, TEXT_DEAD);
        assert_eq!(map_upstream_text("分享因审核未通过已失效").unwrap().summary, TEXT_AUDIT);
        assert_eq!(map_upstream_text("分享不存在").unwrap().summary, TEXT_MISSING);
        assert_eq!(map_upstream_text("请输入提取码").unwrap().state, CheckState::Locked);
        // 都不命中 ⇒ None（调用方自己落 uncertain）
        assert!(map_upstream_text("一切正常").is_none());
    }

    #[test]
    fn unknown_or_empty_share_id_is_invalid_link() {
        // 非网盘 URL：bad + 链接格式无效（不是 unsupported——它压根不是分享链接）
        let checker = PanChecker::with_endpoints(PanEndpoints::default());
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (out, kind, _) = rt.block_on(checker.check_one("https://example.com/video.mp4", None));
        assert_eq!(out.state, CheckState::Bad);
        assert_eq!(out.summary, TEXT_INVALID);
        assert_eq!(kind, PanKind::Unknown);
        // 网盘域名但没有 /s/<id>：同样格式无效
        let (out, _, _) = rt.block_on(checker.check_one("https://pan.quark.cn/", None));
        assert_eq!(out.state, CheckState::Bad);
        assert_eq!(out.summary, TEXT_INVALID);
    }

    #[test]
    fn unsupported_kinds_never_hit_network() {
        let checker = PanChecker::with_endpoints(PanEndpoints::default());
        let rt = tokio::runtime::Runtime::new().unwrap();
        for url in [
            "https://115.com/s/abc",
            "https://www.123pan.com/s/abc",
            "https://cloud.189.cn/t/abc",
            "https://app.guangyapan.com/pan",
        ] {
            let (out, kind, _) = rt.block_on(checker.check_one(url, None));
            assert_eq!(out.state, CheckState::Unsupported, "url={url}");
            assert_eq!(out.summary, TEXT_UNSUPPORTED);
            assert!(kind != PanKind::Unknown, "url={url} 应先被 pan.rs 认出来");
        }
    }

    // ── 协议层：axum 假服务器回放 ──

    /// 起一个按"路径包含"回放的假服务器，返回 (base, 命中计数)
    async fn spawn_replay(
        routes: Vec<(&'static str, u16, String)>,
        hits: Arc<AtomicUsize>,
    ) -> String {
        use axum::response::IntoResponse;
        let app = axum::Router::new().fallback(move |req: axum::extract::Request| {
            let hits = hits.clone();
            let routes = routes.clone();
            async move {
                hits.fetch_add(1, Ordering::SeqCst);
                let path = req.uri().path().to_string();
                for (p, status, body) in &routes {
                    if path.contains(p) {
                        return (axum::http::StatusCode::from_u16(*status).unwrap(), body.clone())
                            .into_response();
                    }
                }
                (axum::http::StatusCode::NOT_FOUND, "no route".to_string()).into_response()
            }
        });
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        tokio::spawn(async move { axum::serve(l, app).await });
        format!("http://127.0.0.1:{port}")
    }

    fn endpoints_at(base: &str) -> PanEndpoints {
        PanEndpoints {
            quark_page: format!("{base}/qpage"),
            quark_token: format!("{base}/qtoken"),
            quark_detail: format!("{base}/qdetail"),
            uc_page: format!("{base}/upage"),
            uc_token: format!("{base}/utoken"),
            uc_detail: format!("{base}/udetail"),
            baidu_page: format!("{base}/bs"),
            baidu_verify: format!("{base}/share/verify"),
            baidu_list: format!("{base}/share/list"),
            xunlei_captcha: format!("{base}/captcha/init"),
            xunlei_share: format!("{base}/drive/v1/share"),
            aliyun_anon: format!("{base}/adrive/get_share_by_anonymous"),
        }
    }

    const QTOKEN_OK: &str =
        r#"{"status":200,"code":0,"message":"ok","data":{"stoken":"ST","title":"甲"}}"#;
    const QDETAIL_OK: &str =
        r#"{"status":200,"code":0,"data":{"list":[{"fid":"f1","file_name":"A.mp4","file_type":0,"size":"1"}]}}"#;

    async fn observed_family_detail_context(
        kind: PanKind,
        stoken: &'static str,
    ) -> (String, Vec<(String, String)>) {
        use axum::response::IntoResponse;
        let observed = Arc::new(Mutex::new(None));
        let captured = observed.clone();
        let token_body = json!({
            "status": 200, "code": 0, "data": {"stoken": stoken, "title": "fixture"}
        })
        .to_string();
        let app = axum::Router::new().fallback(move |req: axum::extract::Request| {
            let captured = captured.clone();
            let token_body = token_body.clone();
            async move {
                let path = req.uri().path();
                if path.contains("page") {
                    return (
                        [(axum::http::header::SET_COOKIE, "ctoken=fixture; Path=/; HttpOnly")],
                        "share page",
                    )
                        .into_response();
                }
                if path.contains("token") {
                    return token_body.into_response();
                }
                if path.contains("detail") {
                    let cookie = req
                        .headers()
                        .get(axum::http::header::COOKIE)
                        .and_then(|value| value.to_str().ok())
                        .unwrap_or("")
                        .to_string();
                    let url =
                        reqwest::Url::parse(&format!("http://localhost{}", req.uri())).unwrap();
                    let query = url.query_pairs().into_owned().collect::<Vec<_>>();
                    *captured.lock().unwrap() = Some((cookie, query));
                    return QDETAIL_OK.into_response();
                }
                axum::http::StatusCode::NOT_FOUND.into_response()
            }
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await });
        let checker = PanChecker::with_endpoints(endpoints_at(&base));
        let share = match kind {
            PanKind::Quark => "https://pan.quark.cn/s/context-fixture",
            PanKind::Uc => "https://drive.uc.cn/s/context-fixture",
            _ => unreachable!(),
        };
        let result = checker.check_one(share, None).await.0;
        server.abort();
        let _ = server.await;
        assert_eq!(result.state, CheckState::Ok);
        let context = observed.lock().unwrap().take().expect("production detail was requested");
        context
    }

    #[tokio::test]
    async fn family_detail_request_keeps_share_page_cookie() {
        for kind in [PanKind::Quark, PanKind::Uc] {
            let (cookie, _) = observed_family_detail_context(kind, "ST").await;
            assert_eq!(cookie, "ctoken=fixture", "{kind:?} detail must retain anonymous session");
            assert!(!cookie.contains("HttpOnly"));
        }
    }

    #[tokio::test]
    async fn family_detail_request_selects_root_directory() {
        for kind in [PanKind::Quark, PanKind::Uc] {
            let (_, query) = observed_family_detail_context(kind, "ST").await;
            let roots = query
                .iter()
                .filter(|(key, _)| key == "pdir_fid")
                .map(|(_, value)| value.as_str())
                .collect::<Vec<_>>();
            assert_eq!(roots, vec!["0"], "{kind:?} detail must explicitly request the share root");
        }
    }

    #[tokio::test]
    async fn family_detail_request_roundtrips_reserved_token() {
        let token = "ST+/=&next=%value";
        for kind in [PanKind::Quark, PanKind::Uc] {
            let (_, query) = observed_family_detail_context(kind, token).await;
            let tokens = query
                .iter()
                .filter(|(key, _)| key == "stoken")
                .map(|(_, value)| value.as_str())
                .collect::<Vec<_>>();
            assert_eq!(tokens, vec![token], "{kind:?} token must survive URL decoding");
            assert!(
                !query.iter().any(|(key, _)| key == "next"),
                "token must not inject parameters"
            );
        }
    }

    async fn check_family_replay(
        kind: PanKind,
        token_status: u16,
        token: String,
        detail_status: u16,
        detail: String,
    ) -> (PanChecker, Arc<AtomicUsize>, CheckOutcome) {
        let hits = Arc::new(AtomicUsize::new(0));
        let base = spawn_replay(
            vec![
                ("/qtoken", token_status, token.clone()),
                ("/utoken", token_status, token),
                ("/qdetail", detail_status, detail.clone()),
                ("/udetail", detail_status, detail),
            ],
            hits.clone(),
        )
        .await;
        let checker = PanChecker::with_endpoints(endpoints_at(&base));
        let url = match kind {
            PanKind::Quark => "https://pan.quark.cn/s/metadata-fixture",
            PanKind::Uc => "https://drive.uc.cn/s/metadata-fixture",
            _ => unreachable!(),
        };
        let outcome = checker.check_one(url, None).await.0;
        (checker, hits, outcome)
    }

    #[tokio::test]
    async fn family_success_token_metadata_does_not_classify_as_error() {
        for kind in [PanKind::Quark, PanKind::Uc] {
            for title in ["不存在的电影", "取消的约定", "审核", "密码", "Limit", "metadata-only"]
            {
                let token = json!({
                    "status": 200,
                    "code": 0,
                    "data": if title == "metadata-only" {
                        json!({"stoken": "ST", "expired": false, "pass_code": ""})
                    } else {
                        json!({"stoken": "ST", "title": title})
                    }
                })
                .to_string();
                let (checker, hits, outcome) =
                    check_family_replay(kind, 200, token, 200, QDETAIL_OK.into()).await;
                assert_eq!(outcome.state, CheckState::Ok, "{kind:?}: {title}");
                assert_eq!(hits.load(Ordering::SeqCst), 3, "page, token, detail");
                assert!(outcome.cacheable);
                assert!(checker.shared.cooldown.lock().unwrap().is_empty());
                assert!(checker
                    .shared
                    .cache
                    .lock()
                    .unwrap()
                    .values()
                    .all(|(cached, _)| cached.state == CheckState::Ok));
            }
        }
    }

    #[tokio::test]
    async fn family_success_detail_names_do_not_classify_as_error() {
        for kind in [PanKind::Quark, PanKind::Uc] {
            for name in ["密码.E01.mp4", "Limit.E01.mp4", "不存在.E01.mp4", "过期.E01.mp4"] {
                let detail = json!({
                    "status": 200,
                    "code": 0,
                    "data": {"list": [{"fid": "F", "file_name": name, "file_type": 1, "size": 1}]}
                })
                .to_string();
                let (checker, hits, outcome) =
                    check_family_replay(kind, 200, QTOKEN_OK.into(), 200, detail).await;
                assert_eq!(outcome.state, CheckState::Ok, "{kind:?}: {name}");
                assert_eq!(hits.load(Ordering::SeqCst), 3);
                assert!(checker.shared.cooldown.lock().unwrap().is_empty());
            }
        }
    }

    #[tokio::test]
    async fn family_failed_http_or_status_cannot_accept_success_payload() {
        for kind in [PanKind::Quark, PanKind::Uc] {
            for status in [403, 429, 500] {
                let (checker, hits, outcome) =
                    check_family_replay(kind, status, QTOKEN_OK.into(), 200, QDETAIL_OK.into())
                        .await;
                assert_eq!(outcome.state, CheckState::Uncertain, "{kind:?} token HTTP {status}");
                let risk = matches!(status, 403 | 429);
                let summary = if risk { TEXT_UNVERIFIABLE } else { TEXT_FAILED };
                assert_eq!(outcome.summary, summary);
                assert_eq!(!checker.shared.cooldown.lock().unwrap().is_empty(), risk);
                assert!(!outcome.cacheable);
                assert_eq!(hits.load(Ordering::SeqCst), 2, "failed token must not request detail");
                let (checker, hits, outcome) =
                    check_family_replay(kind, 200, QTOKEN_OK.into(), status, QDETAIL_OK.into())
                        .await;
                assert_eq!(outcome.state, CheckState::Uncertain, "{kind:?} detail HTTP {status}");
                assert_eq!(outcome.summary, summary);
                assert_eq!(!checker.shared.cooldown.lock().unwrap().is_empty(), risk);
                assert!(!outcome.cacheable);
                assert_eq!(hits.load(Ordering::SeqCst), 3);
            }
            let token = json!({"status": 500, "code": 0, "data": {"stoken": "ST"}}).to_string();
            let (_, hits, outcome) =
                check_family_replay(kind, 200, token, 200, QDETAIL_OK.into()).await;
            assert_eq!(outcome.state, CheckState::Uncertain, "{kind:?} token envelope status");
            assert_eq!(hits.load(Ordering::SeqCst), 2);
            let detail = json!({
                "status": 500,
                "code": 0,
                "data": {"list": [{"fid": "F", "file_name": "A.mp4", "file_type": 1}]}
            })
            .to_string();
            let (_, _, outcome) =
                check_family_replay(kind, 200, QTOKEN_OK.into(), 200, detail).await;
            assert_eq!(outcome.state, CheckState::Uncertain, "{kind:?} detail envelope status");
        }
    }

    #[tokio::test]
    async fn family_failure_attribution_uses_error_fields_not_data() {
        for kind in [PanKind::Quark, PanKind::Uc] {
            for (error, expected, summary) in [
                (json!({"message": "分享已过期"}), CheckState::Bad, TEXT_DEAD),
                (json!({"error": "分享已过期"}), CheckState::Bad, TEXT_DEAD),
                (json!({"error": {"message": "分享已过期"}}), CheckState::Bad, TEXT_DEAD),
                (json!({"error": {"code": "ShareExpiredError"}}), CheckState::Bad, TEXT_DEAD),
                (json!({"error": {"name": "ShareNotFound"}}), CheckState::Bad, TEXT_MISSING),
                (json!({"error_description": "分享已过期"}), CheckState::Bad, TEXT_DEAD),
                (json!({"msg": "分享已过期"}), CheckState::Bad, TEXT_DEAD),
                (json!({"errmsg": "分享已过期"}), CheckState::Bad, TEXT_DEAD),
                (json!({"message": "请输入提取码"}), CheckState::Locked, TEXT_LOCKED),
                (json!({"error": "请输入提取码"}), CheckState::Locked, TEXT_LOCKED),
                (
                    json!({"message": "limit", "error": "pass_code"}),
                    CheckState::Uncertain,
                    TEXT_UNVERIFIABLE,
                ),
                (json!({"message": "unknown failure"}), CheckState::Uncertain, TEXT_FAILED),
            ] {
                for sparse in [false, true] {
                    let mut response = error.clone();
                    if !sparse {
                        response["code"] = json!(123);
                        response["data"] = json!({"title": "密码过期Limit", "expired": false});
                    }
                    let (checker, hits, outcome) =
                        check_family_replay(kind, 200, response.to_string(), 200, QDETAIL_OK.into())
                            .await;
                    assert_eq!(outcome.state, expected, "{kind:?}: {response}");
                    assert_eq!(outcome.summary, summary);
                    assert_eq!(
                        !checker.shared.cooldown.lock().unwrap().is_empty(),
                        summary == TEXT_UNVERIFIABLE
                    );
                    assert_eq!(hits.load(Ordering::SeqCst), 2);
                    let (checker, hits, outcome) =
                        check_family_replay(kind, 200, QTOKEN_OK.into(), 200, response.to_string())
                            .await;
                    assert_eq!(outcome.state, expected, "{kind:?} detail: {response}");
                    assert_eq!(outcome.summary, summary);
                    assert_eq!(
                        !checker.shared.cooldown.lock().unwrap().is_empty(),
                        summary == TEXT_UNVERIFIABLE
                    );
                    assert_eq!(hits.load(Ordering::SeqCst), 3);
                }
            }
        }
    }

    #[tokio::test]
    async fn family_malformed_success_response_is_uncertain_not_content_attribution() {
        for kind in [PanKind::Quark, PanKind::Uc] {
            for token in [
                r#"{"code":0,"data":{"title":"过期密码Limit"}}"#,
                "<html>分享过期 密码 Limit</html>",
            ] {
                let (_, hits, outcome) =
                    check_family_replay(kind, 200, token.into(), 200, QDETAIL_OK.into()).await;
                assert_eq!(outcome.state, CheckState::Uncertain, "{kind:?}: {token}");
                assert_eq!(outcome.summary, TEXT_FAILED);
                assert!(!outcome.cacheable);
                assert_eq!(hits.load(Ordering::SeqCst), 2);
            }
            for detail in [
                r#"{"code":0,"data":{"title":"过期密码Limit"}}"#,
                "<html>分享过期 密码 Limit</html>",
            ] {
                let (checker, hits, outcome) =
                    check_family_replay(kind, 200, QTOKEN_OK.into(), 200, detail.into()).await;
                assert_eq!(outcome.state, CheckState::Uncertain, "{kind:?}: {detail}");
                assert_eq!(outcome.summary, TEXT_FAILED);
                assert!(!outcome.cacheable);
                assert!(checker.shared.cooldown.lock().unwrap().is_empty());
                assert_eq!(hits.load(Ordering::SeqCst), 3);
            }
        }
    }

    #[tokio::test]
    async fn supplied_password_does_not_reuse_locked_cache() {
        use axum::response::IntoResponse;
        let hits = Arc::new(AtomicUsize::new(0));
        let counter = hits.clone();
        let app = axum::Router::new().fallback(move |req: axum::extract::Request| {
            let hits = counter.clone();
            async move {
                hits.fetch_add(1, Ordering::SeqCst);
                if req.uri().path().contains("qtoken") {
                    let body = axum::body::to_bytes(req.into_body(), 4096).await.unwrap();
                    let value: Value = serde_json::from_slice(&body).unwrap();
                    return if value["passcode"] == "correct" { QTOKEN_OK.to_string() } else {
                        r#"{"status":41009,"message":"提取码错误"}"#.to_string()
                    }.into_response();
                }
                QDETAIL_OK.to_string().into_response()
            }
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await });
        let checker = PanChecker::with_endpoints(endpoints_at(&base));
        let url = "https://pan.quark.cn/s/cache-fixture";
        assert_eq!(checker.check_one(url, None).await.0.state, CheckState::Locked);
        let before = hits.load(Ordering::SeqCst);
        assert_eq!(checker.check_one(url, Some("correct")).await.0.state, CheckState::Ok);
        assert!(hits.load(Ordering::SeqCst) > before);
        let before = hits.load(Ordering::SeqCst);
        assert_eq!(checker.check_one(url, Some("correct")).await.0.state, CheckState::Ok);
        assert_eq!(hits.load(Ordering::SeqCst), before, "同提取码可复用有效缓存");
    }

    #[tokio::test]
    async fn quark_ok_locked_expired_replay() {
        // ok：token 过 → detail 非空 ⇒ 链接有效
        let base = spawn_replay(
            vec![
                ("/qtoken", 200, QTOKEN_OK.into()),
                ("/qdetail", 200, QDETAIL_OK.into()),
            ],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let checker = PanChecker::with_endpoints(endpoints_at(&base));
        let (out, kind, sid) = checker.check_one("https://pan.quark.cn/s/abc123", None).await;
        assert_eq!(out.state, CheckState::Ok, "summary={}", out.summary);
        assert_eq!(out.summary, TEXT_OK);
        assert_eq!(kind, PanKind::Quark);
        assert_eq!(sid, "abc123");

        // locked：token 响应带提取码关键词
        let base2 = spawn_replay(
            vec![("/qtoken", 200, r#"{"status":41009,"message":"提取码错误"}"#.into())],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c2 = PanChecker::with_endpoints(endpoints_at(&base2));
        let (out, _, _) = c2.check_one("https://pan.quark.cn/s/abc123", None).await;
        assert_eq!(out.state, CheckState::Locked);
        assert_eq!(out.summary, TEXT_LOCKED);

        // bad：过期
        let base3 = spawn_replay(
            vec![("/qtoken", 200, r#"{"status":41003,"message":"分享已过期"}"#.into())],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c3 = PanChecker::with_endpoints(endpoints_at(&base3));
        let (out, _, _) = c3.check_one("https://pan.quark.cn/s/abc123", None).await;
        assert_eq!(out.state, CheckState::Bad);
        assert_eq!(out.summary, TEXT_DEAD);
    }

    #[tokio::test]
    async fn uc_uses_own_host_and_replays() {
        let base = spawn_replay(
            vec![
                ("/utoken", 200, QTOKEN_OK.into()),
                ("/udetail", 200, QDETAIL_OK.into()),
            ],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c = PanChecker::with_endpoints(endpoints_at(&base));
        let (out, kind, _) = c.check_one("https://drive.uc.cn/s/uc123", None).await;
        assert_eq!(out.state, CheckState::Ok, "{}", out.summary);
        assert_eq!(kind, PanKind::Uc);
    }

    #[tokio::test]
    async fn baidu_haspwd_errno_replay() {
        // 无码 + HasPwd ⇒ locked
        let base = spawn_replay(
            vec![("/bs", 200, "share page".into()),
                ("/share/list", 200, r#"{"errno":0,"HasPwd":true,"list":[],"count":0}"#.into())],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c = PanChecker::with_endpoints(endpoints_at(&base));
        let (out, kind, _) = c.check_one("https://pan.baidu.com/s/1AbCd", None).await;
        assert_eq!(out.state, CheckState::Locked, "{}", out.summary);
        assert_eq!(kind, PanKind::Baidu);

        // 有文件 ⇒ ok
        let base2 = spawn_replay(
            vec![("/bs", 200, "share page".into()),
                ("/share/list", 200, r#"{"errno":0,"list":[{"fs_id":1,"server_filename":"a.mkv"}],"count":1}"#.into())],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c2 = PanChecker::with_endpoints(endpoints_at(&base2));
        let (out, _, _) = c2.check_one("https://pan.baidu.com/s/1AbCd", None).await;
        assert_eq!(out.state, CheckState::Ok);

        // 未知 errno 没有明确拒绝信息，不证明分享失效。
        let base3 = spawn_replay(
            vec![("/bs", 200, "share page".into()),
                ("/share/list", 200, r#"{"errno":105,"list":[]}"#.into())],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c3 = PanChecker::with_endpoints(endpoints_at(&base3));
        let (out, _, _) = c3.check_one("https://pan.baidu.com/s/1AbCd", None).await;
        assert_eq!(out.state, CheckState::Uncertain);
        assert_eq!(out.summary, TEXT_FAILED);
        assert!(!out.cacheable);
    }

    #[tokio::test]
    async fn aliyun_ok_and_illegal_replay() {
        // ok：has_share true
        let base = spawn_replay(
            vec![(
                "/adrive/get_share_by_anonymous",
                200,
                r#"{"has_share":true,"file_count":2}"#.into(),
            )],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c = PanChecker::with_endpoints(endpoints_at(&base));
        let (out, kind, _) = c.check_one("https://www.alipan.com/s/xyz", None).await;
        assert_eq!(out.state, CheckState::Ok);
        assert_eq!(kind, PanKind::Aliyun);
        // bad：审核未通过（illegal）
        let base2 = spawn_replay(
            vec![(
                "/adrive/get_share_by_anonymous",
                200,
                r#"{"code":"ShareLink.Illegal"}"#.into(),
            )],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c2 = PanChecker::with_endpoints(endpoints_at(&base2));
        let (out, _, _) = c2.check_one("https://www.alipan.com/s/xyz", None).await;
        assert_eq!(out.state, CheckState::Bad);
        assert_eq!(out.summary, TEXT_AUDIT);
    }

    #[tokio::test]
    async fn xunlei_ok_and_sign_denied_falls_to_uncertain() {
        // OK
        let base = spawn_replay(
            vec![(
                "/drive/v1/share",
                200,
                r#"{"share_status_text":"OK","file_count":3}"#.into(),
            )],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c = PanChecker::with_endpoints(endpoints_at(&base));
        let (out, kind, _) = c.check_one("https://pan.xunlei.com/s/abc", None).await;
        assert_eq!(out.state, CheckState::Ok);
        assert_eq!(kind, PanKind::Xunlei);
        // 签名被拒（captcha 要求 + init 不给 token）⇒ uncertain，**不猜签名**
        let base2 = spawn_replay(
            vec![
                ("/drive/v1/share", 403, r#"{"error":"NeedCaptcha"}"#.into()),
                ("/captcha/init", 200, r#"{}"#.into()),
            ],
            Arc::new(AtomicUsize::new(0)),
        )
        .await;
        let c2 = PanChecker::with_endpoints(endpoints_at(&base2));
        let (out, _, _) = c2.check_one("https://pan.xunlei.com/s/abc", None).await;
        assert_eq!(out.state, CheckState::Uncertain);
        assert_eq!(out.summary, TEXT_UNVERIFIABLE);
    }

    #[tokio::test]
    async fn risk_response_sets_cooldown_and_not_cached() {
        let hits = Arc::new(AtomicUsize::new(0));
        let base = spawn_replay(
            vec![("/bs", 200, "share page".into()),
                ("/share/list", 429, r#"{"errno":429,"message":"请求过于频繁"}"#.into())],
            hits.clone(),
        )
        .await;
        let c = PanChecker::with_endpoints(endpoints_at(&base));
        let (out, _, _) = c.check_one("https://pan.baidu.com/s/1AbCd", None).await;
        assert_eq!(out.state, CheckState::Uncertain);
        assert_eq!(out.summary, TEXT_UNVERIFIABLE);
        assert!(!out.cacheable, "★ 风控结果不许缓存");
        // 冷却期内第二次：**不发请求**（hits 不再增长）
        let before = hits.load(Ordering::SeqCst);
        let (out2, _, _) = c.check_one("https://pan.baidu.com/s/1AbCd", None).await;
        assert_eq!(out2.state, CheckState::Uncertain);
        assert_eq!(
            hits.load(Ordering::SeqCst),
            before,
            "★★ 冷却期内不许再打上游（退避，不是硬重试）"
        );
    }

    #[tokio::test]
    async fn cacheable_result_hits_server_once() {
        let hits = Arc::new(AtomicUsize::new(0));
        let base = spawn_replay(
            vec![
                ("/qtoken", 200, QTOKEN_OK.into()),
                ("/qdetail", 200, QDETAIL_OK.into()),
            ],
            hits.clone(),
        )
        .await;
        let c = PanChecker::with_endpoints(endpoints_at(&base));
        let first = c.check_one("https://pan.quark.cn/s/abc123", None).await;
        assert_eq!(first.0.state, CheckState::Ok);
        let after_first = hits.load(Ordering::SeqCst);
        assert!(after_first > 0);
        // 第二次：缓存命中 ⇒ 零请求
        let second = c.check_one("https://pan.quark.cn/s/abc123", None).await;
        assert_eq!(second.0.state, CheckState::Ok);
        assert_eq!(second.0.summary, TEXT_OK);
        assert_eq!(
            hits.load(Ordering::SeqCst),
            after_first,
            "★★★ 缓存命中不许再打上游（drive_check_cache 语义）"
        );
    }

    #[tokio::test]
    async fn command_check_shape_is_stable() {
        // FFI 出口形状（rustdoc 里的举例要有门禁钉住）
        let items = r#"[{"url":"https://115.com/s/abc"},{"url":"https://example.com/x"}]"#;
        let v = command_check(items).await.expect("命令不该失败（失败在 results 里）");
        assert_eq!(v["ok"], true);
        assert_eq!(v["truncated"], 0, "没超上限 ⇒ truncated=0");
        let results = v["results"].as_array().unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0]["state"], "unsupported");
        assert_eq!(results[0]["kind"], "115");
        assert_eq!(results[1]["state"], "bad");
        assert_eq!(results[1]["summary"], TEXT_INVALID);
        for r in results {
            assert!(r["url"].is_string());
            assert!(r["shareId"].is_string());
            assert!(r["summary"].is_string());
            assert!(r["cacheable"].is_boolean());
        }
    }

    /// ★ P3-5：条数上限 —— 超出截断并标注 truncated（批量扇出要有闸）
    #[tokio::test]
    async fn command_check_truncates_over_limit() {
        // 101 条 unsupported 类链接（115 不发请求 ⇒ 快且确定性）
        let mut urls = Vec::new();
        for i in 0..(MAX_CHECK_ITEMS + 1) {
            urls.push(format!(r#"{{"url":"https://115.com/s/{i}"}}"#));
        }
        let items = format!("[{}]", urls.join(","));
        let v = command_check(&items).await.expect("命令不该失败");
        assert_eq!(v["truncated"], 1, "101 条 ⇒ 截断 1 条并标注");
        let results = v["results"].as_array().unwrap();
        assert_eq!(
            results.len(),
            MAX_CHECK_ITEMS,
            "★ 结果条数必须被闸在 MAX_CHECK_ITEMS（实际 {}）",
            results.len()
        );
        // 截断保序：前 100 条按原序返回
        assert_eq!(results[0]["shareId"], "0");
        assert_eq!(results[99]["shareId"], "99");
        // 恰好等于上限 ⇒ 不截断
        let items2 = format!("[{}]", urls[..MAX_CHECK_ITEMS].join(","));
        let v2 = command_check(&items2).await.unwrap();
        assert_eq!(v2["truncated"], 0);
        assert_eq!(v2["results"].as_array().unwrap().len(), MAX_CHECK_ITEMS);
    }
}
