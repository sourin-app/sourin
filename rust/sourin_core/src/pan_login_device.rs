//! OAuth **设备码**（device flow，RFC 8628 形态）那一族：光鸭 / 迅雷
//!
//! # 为什么单独开一个文件（而不是塞进 `pan_login`）
//!
//! ```text
//! `pan_login` 里那五家（夸克/UC/百度/115/阿里）虽然端点各异，但**提问方式**相同：
//!   「把 token 拼进一个固定 URL → 让用户扫 → 轮询这个 token」。
//! 光鸭/迅雷不是这个形状：
//!   ① 二维码里装的不是"我拼的 URL"，而是服务端给的 `verification_uri_complete`；
//!   ② 轮询要提交 `device_code` + `grant_type=…:device_code`（OAuth 标准授权类型）；
//!   ③ 报文是 **POST JSON**（不是 form、不是 query）；
//!   ④ 凭据是 bearer token，不是 cookie。
//! ⇒ 四件事全不一样 ⇒ 会话状态机与状态判据都不能复用。
//! ```
//!
//! # 为什么两家**能**共用一个 core（而 `pan_login` 那五家不能）
//!
//! ```text
//! 取证（`.probe/pan-login-evidence-remaining.md` §3.1-A）写明：
//!   `buildXunleiQrInfo` 与 `buildGuangyaQrInfo` **指令结构逐条同形**
//!   （都是 73 insns，只有 UA / client_id / scope 值 / 端点四处不同）。
//! ⇒ 差异**只是常量**（主机、client_id、scope、UA），逻辑一条也没多。
//!   而 `pan_login` 那五家的差异是**结构性**的（cookie 在响应头 vs 在 body、
//!   状态在业务码 vs 枚举串 vs "Set-Cookie 里出现某个键"）—— 合并只会造分支。
//! ⇒ 这里共用一个 core + 一张 [`DeviceFlowSpec`] 表；那边各写各的。
//!   依据是"**现在就有两个同构实现**"，不是"将来可能要"。
//! ```
//!
//! # 取证（逐字，带出处）
//!
//! ```text
//! 【光鸭】`merge.m.G.buildGuangyaQrInfo`（73 insns）/ `handleGuangya`
//!   ① 申请设备码  POST https://account.guangyapan.com/v1/auth/device/code
//!                 ← str#18370（佐证 .probe/r3-t20-strpool-urls.txt:147）
//!      体   {"client_id":"aMe-8VSlkrbQXpUR","scope":"user"}       ← 0x0011–0x001c
//!      头   User-Agent:<Chrome/151> + Content-Type: application/json; charset=utf-8
//!   ② 响应绑定  url ← `verification_uri_complete` ；token ← `device_code`  ← 0x0032–0x0045
//!   ③ 换 token  POST https://account.guangyapan.com/v1/auth/token
//!                 ← str#18371（佐证 :148）
//!      体   {"client_id":"aMe-8VSlkrbQXpUR","device_code":"<①的 token>",
//!            "grant_type":"urn:ietf:params:oauth:grant-type:device_code"}  ← 0x0026–0x003e
//!      判定 `if (!resp.has("access_token")) return;`                     ← 0x0051
//!
//! 【迅雷】`merge.m.G.buildXunleiQrInfo`（同形 73 insns）/ `handleXunlei`
//!   ① 申请设备码  POST https://xluser-ssl.xunlei.com/v1/auth/device/code
//!                 ← str#18853（佐证 .probe/r3-t20-strpool-urls.txt:630）
//!      体   {"client_id":"XW-G4v1H72tgfJym","scope":""}   ← 0x0011–0x001c（scope 是 str#0 空串）
//!      头   User-Agent:<安卓迅雷 UA> + Content-Type: application/json; charset=utf-8
//!   ② 响应绑定  同光鸭（verification_uri_complete / device_code）
//!   ③ 换 token  POST https://xluser-ssl.xunlei.com/v1/auth/token   ← str#18854（佐证 :631）
//!      ★ client_id 换成 **Xp6vsxz_7IYVw2BB**（≠ ①那个）            ← 0x0007 str#12432
//!      体   {"client_id":"Xp6vsxz_7IYVw2BB","device_code":"<①的 token>",
//!            "grant_type":"urn:ietf:params:oauth:grant-type:device_code"}
//! ```
//!
//! # ⚠️ 未取证清单（逐条登记；读代码时**不许**把下面这些当成读数）
//!
//! ```text
//! ① `interval`：全 dex 9 条命中**全是播放进度**（PlayInterval 之类），
//!    device flow 那一步**没有** ⇒ 轮询节奏只能按 RFC 8628 §3.5 的默认 5 秒。
//!    本文件把它写成 [`DEVICE_POLL_INTERVAL_SECS`]，注释与门禁都标"推断"。
//!    （本仓 UI 自己控制节奏，这个常量目前不进协议 —— 但仍如实导出，免得下一个人
//!     再猜一次。）
//! ② `expires_in`：全池只有 1 条，且只出现在 refresh / captcha 两步，
//!    **不在** device/code 那一步 ⇒ 本文件"有就用、没有就用本地兜底"，
//!    并且**不**把它当"服务端一定会给"。
//! ③ 轮询期的四个错误码字面量（`authorization_pending` / `slow_down` /
//!    `expired_token` / `access_denied`）：dex **0 命中**（参考实现只判
//!    `has("access_token")`）⇒ 本文件按 RFC 8628 §3.5 实现，**必须真机确认**
//!    服务端到底回哪个。见 [`classify_device_error`] 的说明。
//! ④ 迅雷 `captcha/init`（`merge.b.X.l`）与设备码的**先后关系**：只知它存在，
//!    无法从字符串判定是否需要、在 device/code 之前还是之后 ⇒ 本文件**不调用**它。
//!    真机若要求验证码，会在 device/code 那一步被拒 ⇒ 会如实报 HTTP/响应摘要。
//! ⑤ `/v1/user/me`（两家都有）**不用**：它的头是 `X-Client-Id / X-Device-Id /
//!    Authorization`（§2.1-E / §3.1-E），而**申请码与换 token 那两步的头逐字只有**
//!    `User-Agent` + `Content-Type` ⇒ 那三个头**不发**（见 [`auth_step_headers`]）。
//!    账号显示名写死 `display()`（与阿里同一取舍）。
//! ⑥ `user_code`：dex **0 命中**（参考实现不解析人读码）⇒ 本文件也不解析、不展示，
//!    只把 `verification_uri_complete` 编成码（它本身已含码）。
//! ⑦ 整条链路**没有真账号跑过**。失败一律如实报"哪一步 HTTP 多少 + 响应摘要"。
//! ```
//!
//! # ★★★ 真读数（2026-10-29，curl 直接打端点；**修掉了上表 ①②③ 三条"推断"**）
//!
//! ```text
//! 【光鸭】POST https://account.guangyapan.com/v1/auth/device/code
//!   Content-Type: application/json; charset=utf-8   ← ★ 真网证明"JSON 而非表单"是对的
//!   {"client_id":"aMe-8VSlkrbQXpUR","scope":"user"}
//!   → 200 {"device_code":"AWriittPL185…","user_code":"AWriitvRm_m7ffZG9g",
//!          "expires_in":120,"interval":2,
//!          "verification_url":"https://account.guangyapan.com/__/auth/device/?…",
//!          "verification_uri_complete":"https://account.guangyapan.com/__/auth/device/?…&user_code=AWriitvRm_m7ffZG9g"}
//!
//! 【迅雷】POST https://xluser-ssl.xunlei.com/v1/auth/device/code
//!   {"client_id":"XW-G4v1H72tgfJym","scope":""}
//!   → 200 {"device_code":"AWriitswoiyd…","user_code":"AWriitvVUMpI_NcMJQ",
//!          "expires_in":120,"interval":2,
//!          "verification_uri_complete":"https://i.xunlei.com/center/account/personal/qrcode-login/?…&user_code=…",
//!          "short_uri_complete":"https://xluser-ssl.xunlei.com/api/v1/reurl?action=scan&code=PNJNb"}
//!
//! 【两家的 token 端点（未确认时）】POST /v1/auth/token   ⇒ **HTTP 400** + 
//!   {"error":"authorization_pending","error_code":4050,
//!    "error_description":"Precondition Required","details":[…"message":"Authorizing"]}
//! ```
//!
//! # 这三条读数改了什么（不要改回去）
//! ```text
//! ① `interval` **真的存在**（=2 秒）⇒ 上表①"没有这个字段"是错的。
//!    但本仓仍以 UI 的 2 秒节拍轮询，`DEVICE_POLL_INTERVAL_SECS` 保持 5（不在协议里用），
//!    仅在日志里记服务端给的值（判读节奏用）。
//! ② `expires_in` **真的给了**（=120 秒）⇒ 会话 TTL 走 `min(120, 300) = 120`。
//! ③ `authorization_pending` **就是真串** ⇒ `classify_device_error` 那条不再是纯推断
//!    （`slow_down` / `expired_token` / `access_denied` 仍未观测到，如实保留标注）。
//!    ★ 同时证明：**未确认时是 HTTP 400**，所以"按 HTTP 码判失败"会把正常的等待
//!      当成错误 ⇒ 现有实现（先看 body 再判）是对的。
//! ④ 迅雷换 token 用哪个 client_id（`Xp6vsxz_7IYVw2BB` vs `XW-G4v1H72tgfJym`）
//!    **仍未证实**：两个都在 authorization_pending 阶段被接受（服务端此时还没校验
//!    client 与 code 的绑定）⇒ 只能等真账号确认那一刻才见分晓。dex 的证词不变。
//! ```
//!
//! # 契约（`pan_login` 的 dispatch 调这四个）
//!
//! ```rust
//! pub async fn guangya_start() -> Result<QrSession, String>;
//! pub async fn guangya_poll(key: &str) -> Result<PollOutcome, String>;
//! pub async fn xunlei_start()  -> Result<QrSession, String>;
//! pub async fn xunlei_poll(key: &str) -> Result<PollOutcome, String>;
//! ```
//!
//! ★★ **集成注意（Lead 侧的 `pan_login::qr_login_poll` 必读）**
//! ```text
//! `qr_login_poll` 开头有一道"这个 key 在 SESSIONS 里吗 / 超时了吗"的检查，
//! 它查的是 **pan_login 自己的** SESSIONS。本文件的会话在**自己的**表里
//! （纪律：不许动它的私有表）⇒ 那两家若走同一条检查，key 永远"不存在"，
//! 会被判 Expired，**一次 HTTP 都不会发生**（现场表现为"刚出码就过期"）。
//! ⇒ 分流方式：`if pan_login_device::is_device_flow(kind) { 直接进本模块的 poll }`
//!   并**跳过** `pan_login` 的会话存在性检查（本模块自己会做同样的检查）。
//! ```
//!
//! ★ 凭据的写入口仍然只有一个：`pan_login::qr_login_poll` 末尾那句
//! `crate::pan_auth::save(cred)`。本文件的 `poll` **只产出** `PollOutcome.credential`，
//! 不自己落盘 —— 否则凭据就有两个写入点了。
//!
//! ★ 凭据形状（token 型网盘的约定键，见
//!   `.agents/notes/implemented/feature/2026-10-28-aliyun-qr-login-and-token-shape.md`）：
//!   `access_token=<…>; refresh_token=<…>`（没有 refresh_token 就只写前者）。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use crate::pan::PanKind;
use crate::pan_auth::PanCredential;
use crate::pan_login::{PollOutcome, QrSession, QrStatus};

// ═══════════════════════════════════════════════════════════════════════
//  协议常量（两家共用 / 逐字取证）
// ═══════════════════════════════════════════════════════════════════════

/// RFC 8628 定义的设备码授权类型（逐字取证：`handleGuangya` 0x003e / `handleXunlei` 0x003e）
///
/// ★ 为什么把它提成常量而不是写进两处 `format!`：
///   这个串错一个字符，服务端回的是 `unsupported_grant_type`（HTTP 400）——
///   本模块最容易写错、也最容易被"看起来在等"掩盖的一处。
///   ⇒ 单一来源 + 门禁逐字断言。
const DEVICE_GRANT_TYPE: &str = "urn:ietf:params:oauth:grant-type:device_code";

/// 两步共用的 Content-Type（逐字取证：`merge.k.c.<init>` 里硬编码的那条）
///
/// ★ 必须是 `application/json; charset=utf-8` **整串**（带 charset）：
///   参考实现用的是那个 5 参构造器，串里就有 charset。
///   写成 reqwest 的 `.json()` 只会发 `application/json`（少 charset）——
///   大概率也能用，但"能跑"不是我们的标准：**能逐字对上的地方就该逐字对上**。
const JSON_CONTENT_TYPE: &str = "application/json; charset=utf-8";

/// 光鸭：UA（逐字，`buildGuangyaQrInfo` 0x0005–0x0009）
const UA_GUANGYA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                         (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
/// 光鸭：client_id（逐字，0x0013）
const GUANGYA_CLIENT_ID: &str = "aMe-8VSlkrbQXpUR";
/// 光鸭：scope（逐字，0x001a；就是 `user`，**不是** openid 之类）
const GUANGYA_SCOPE: &str = "user";

/// 迅雷：UA（逐字，`buildXunleiQrInfo` 0x0005–0x0009 / str#3398）
///
/// ⚠️ 这是**安卓客户端**的 UA，不是浏览器 —— 它是这条链路的"客户端身份"，
///    少一个字段都可能被当成别的客户端。
const UA_XUNLEI: &str = "ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G \
                         appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC \
                         OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 \
                         Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)";
/// 迅雷：**申请设备码**用的 client_id（逐字，`buildXunleiQrInfo` 0x0013 = str#18852 邻位）
const XUNLEI_CLIENT_ID_DEVICE: &str = "XW-G4v1H72tgfJym";
/// 迅雷：**换 token**用的 client_id —— 与上面那个**不是同一个**
///
/// ★ 为什么这是本文件最容易串的一处（与 UC 的 529/381 同一种坑）：
///   取证 `handleXunlei` 0x0007 = str#12432，`merge.b.X.<clinit>` 也是这一串；
///   `XW-G4v1H72tgfJym` 全 dex **只出现 1 次**（就在 buildXunleiQrInfo）。
///   两串都是"大写字母 + 下划线 + 数字"，扫一眼分不出。
///   写错的表现：**出码成功**（所以看着像好的），换 token 永远 4xx ⇒
///   用户点了同意却登不上 —— 静默失败里最难查的一种。
const XUNLEI_CLIENT_ID_TOKEN: &str = "Xp6vsxz_7IYVw2BB";
/// 迅雷：scope（逐字取证是**空串** str#0；照样发空值，不"顺手补一个"）
const XUNLEI_SCOPE: &str = "";

/// 轮询节奏：**RFC 8628 §3.5 的默认 5 秒** —— ⚠️ **推断，不是 dex 读数**
///
/// ```text
/// dex 里 `interval` 9 条命中全是播放进度（PlayInterval / getPlayInterval / …），
/// device flow 那一步**一个也没有** ⇒ 服务端到底建议多久一次，我们不知道。
/// ⇒ 取 RFC 8628 的默认值；收到 `slow_down` 时按标准再加 5 秒（本仓 UI 控节奏，
///   这个常量目前**不进协议**，导出它是为了：①记录我们的假设；②真机确认后改一处）。
/// 批末真机读数的判据：若 5 秒太密，服务端会回 `slow_down`（见 classify_device_error）
/// ⇒ 那时把它调大即可，不影响协议形状。
/// ```
pub const DEVICE_POLL_INTERVAL_SECS: i64 = 5;

// ═══════════════════════════════════════════════════════════════════════
//  纯函数：URL / 请求体 / 请求头（写错不报错、只"扫了没反应" ⇒ 必须能逐字断言）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这些必须是纯函数
// ```text
// 本模块有一种**不报错**的失败：形状对了、值错了（client_id 串了、scope 多一字、
// grant_type 少一字母、body 用了表单而不是 JSON）——
// 服务端照样回 4xx，但"出码那一步"可能是好的 ⇒ 现场表现是"扫了没反应"。
// 这类错不可能靠跑一次真网络发现（没账号），只能靠**逐字断言**。
// ⇒ 值不写在 `format!` 里，而是纯函数产出，门禁把整串与取证对照。
// ```
//
// ══ 端点（四条，逐字） ══

/// 光鸭：申请设备码（str#18370 / `.probe/r3-t20-strpool-urls.txt:147`）
fn guangya_device_code_url() -> &'static str {
    "https://account.guangyapan.com/v1/auth/device/code"
}

/// 光鸭：换 token（str#18371 / `:148`）
fn guangya_token_url() -> &'static str {
    "https://account.guangyapan.com/v1/auth/token"
}

/// 迅雷：申请设备码（str#18853 / `:630`）
///
/// ★ 这条**存在**是上一轮被工具漏报（`.probe/r3c-dexstrings.py` 的指令长度表有 12 处错，
///   `const-string` 因此被跳过）而误判成"没取证"的。本轮已修正工具并复核。
fn xunlei_device_code_url() -> &'static str {
    "https://xluser-ssl.xunlei.com/v1/auth/device/code"
}

/// 迅雷：换 token（str#18854 / `:631`）
fn xunlei_token_url() -> &'static str {
    "https://xluser-ssl.xunlei.com/v1/auth/token"
}

// ══ 请求体（JSON，**不是表单**） ══
//
// ★★ 这是本轮最容易写错的一处，所以把"为什么是 JSON"写在代码旁边：
// ```text
// 简报里原本写的是"报文形状未取证，按 RFC 8628 标准形态（form-urlencoded）实现"。
// 取证结果推翻了它：参考实现走 `merge.k.c.<init>(String,String,Map)` /
// `merge.k.b.f(String,String,Map)` —— **POST + application/json + JSONObject.toString()**，
// 三个参数分别是 URL / Content-Type / body。
// ⇒ 真按表单发，服务端会 4xx（或 200 但字段读不到）⇒ 现场"点了没反应"。
//   RFC 8628 只说"表单或 JSON 都可以给"，具体用哪种**必须看实现**。
// ```

/// 给字符串加 JSON 引号与转义（`device_code` 是服务端给的串，不假设它"一定干净"）
fn json_str(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

/// 申请设备码的请求体（纯函数；字段顺序与取证指令流一致：client_id → scope）
///
/// 逐字对照（光鸭）：`{"client_id":"aMe-8VSlkrbQXpUR","scope":"user"}`
/// 逐字对照（迅雷）：`{"client_id":"XW-G4v1H72tgfJym","scope":""}`
fn device_code_body(client_id: &str, scope: &str) -> String {
    format!(
        r#"{{"client_id":{},"scope":{}}}"#,
        json_str(client_id),
        json_str(scope)
    )
}

/// 换 token 的请求体（纯函数；字段顺序与取证一致：client_id → device_code → grant_type）
///
/// 逐字对照（光鸭）：`{"client_id":"aMe-8VSlkrbQXpUR","device_code":"<dc>",`
///                  `"grant_type":"urn:ietf:params:oauth:grant-type:device_code"}`
/// 逐字对照（迅雷）：同上，但 client_id 是 `Xp6vsxz_7IYVw2BB`。
fn token_body(client_id: &str, device_code: &str) -> String {
    format!(
        r#"{{"client_id":{},"device_code":{},"grant_type":{}}}"#,
        json_str(client_id),
        json_str(device_code),
        json_str(DEVICE_GRANT_TYPE)
    )
}

/// 两步共用的请求头（纯函数，门禁逐字断言）
///
/// ★★ 这里**故意只有 Content-Type 一条**，而且是个"减法"决定：
/// ```text
/// 我第一版把 `X-Client-Id` / `X-Device-Id` / `Referer` 也发了（因为"helper 那个类里有"）。
/// 取证纠正了它：那三个头属于 **`/v1/user/me`**（§2.1-E / §3.1-E），
/// 而 device/code 与 token 那两步的头逐字只有 `User-Agent` + `Content-Type`
/// （buildGuangyaQrInfo 0x0005–0x0009 只有一个 User-Agent；
///   handleGuangya 0x0018–0x0023 只有 User-Agent + Content-Type）。
/// ⇒ "同一个类的另一个方法带了某头" ≠ "这一步也要带"。多发的头不会报错，
///   却会把"我们到底验证过什么"糊掉 —— 所以删掉，并把这段留在原处防止再加回来。
/// （UA 由 `client()` 统一设，所以这里只剩 Content-Type。）
/// ```
fn auth_step_headers() -> [(&'static str, &'static str); 1] {
    [("Content-Type", JSON_CONTENT_TYPE)]
}

// ═══════════════════════════════════════════════════════════════════════
//  两家的差异表（唯一一处"哪家是什么"）
// ═══════════════════════════════════════════════════════════════════════

/// 一条设备码流程的全部"这家特有的东西"
struct DeviceFlowSpec {
    /// 哪一家（会话表分区 / 日志 / 凭据 kind）
    kind: PanKind,
    /// 日志与报错里的短名（中文，现场读得懂）
    label: &'static str,
    /// 账号显示名（`/v1/user/me` 不用，见文件头未取证⑤）
    account: &'static str,
    /// 这一家的 UA（两家差别极大：浏览器 vs 安卓客户端）
    ua: &'static str,
    /// 申请设备码时带的 client_id
    device_client_id: &'static str,
    /// 换 token 时带的 client_id（**迅雷与上面不同**）
    token_client_id: &'static str,
    /// scope（光鸭 `user` / 迅雷空串）
    scope: &'static str,
    /// 申请设备码的端点（函数指针 ⇒ URL 仍是纯函数，可被门禁单独断言）
    device_code_url: fn() -> &'static str,
    /// 换 token 的端点
    token_url: fn() -> &'static str,
}

/// 光鸭那一行
fn guangya_spec() -> DeviceFlowSpec {
    DeviceFlowSpec {
        kind: PanKind::Guangya,
        label: "光鸭",
        account: "光鸭云盘",
        ua: UA_GUANGYA,
        device_client_id: GUANGYA_CLIENT_ID,
        token_client_id: GUANGYA_CLIENT_ID,
        scope: GUANGYA_SCOPE,
        device_code_url: guangya_device_code_url,
        token_url: guangya_token_url,
    }
}

/// 迅雷那一行
fn xunlei_spec() -> DeviceFlowSpec {
    DeviceFlowSpec {
        kind: PanKind::Xunlei,
        label: "迅雷",
        account: "迅雷云盘",
        ua: UA_XUNLEI,
        device_client_id: XUNLEI_CLIENT_ID_DEVICE,
        token_client_id: XUNLEI_CLIENT_ID_TOKEN,
        scope: XUNLEI_SCOPE,
        device_code_url: xunlei_device_code_url,
        token_url: xunlei_token_url,
    }
}

/// 这家是不是走**设备码**流程
///
/// ★ 给 `pan_login::qr_login_poll` 分流用（原因见文件头"集成注意"）：
///   那两家的 `key` 不在 `pan_login` 的会话表里，若走它开头的存在性检查
///   会被判成 Expired ⇒ **必须**在检查之前用这个函数分流。
pub fn is_device_flow(kind: PanKind) -> bool {
    matches!(kind, PanKind::Guangya | PanKind::Xunlei)
}

// ═══════════════════════════════════════════════════════════════════════
//  自备的小工具（`pan_login` 里同名的是私有函数，而本次只能改本文件）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不 `use crate::pan_login::client`
// ```text
// 那边是 `fn client`（私有，不是 pub(crate)），而本次协作纪律是"只许改本文件"
// ⇒ 不能给它加可见性，只能自备。这在本仓不是新做法：`streamproxy.rs:117-164`
// 与 `pan_login.rs:197-248` 就各自有一份日志实现（同样的理由）。
// ⇒ 代价是 4 个小函数重复；收益是两边能独立演进，不会因为一方改签名就连锁爆。
// ```

/// 单次 HTTP 的预算（登录接口都很快；卡住说明网络问题，早失败早提示）
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

/// 建 HTTP 客户端
///
/// ⚠️ 与 `pan_login::client` 同一条纪律：reqwest **默认读环境代理**，
/// 而用户机器上的代理会把"接口可用"测成"全失败"。登录尤其不能走代理
/// （这类账号服务对出口 IP 敏感）。
fn client(ua: &str) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent(ua)
        .timeout(HTTP_TIMEOUT)
        .no_proxy()
        .build()
        .map_err(|e| format!("建 HTTP 客户端失败：{e}"))
}

/// 当前时刻（Unix 秒）
fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 摘要一行响应（报错时给用户看，不要甩整页 HTML）
fn tail(s: &str) -> String {
    let t = s.trim();
    let cut = t.char_indices().nth(200).map(|(i, _)| i).unwrap_or(t.len());
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

/// JSON **顶层键名**（逗号分隔；**只键名，不取值**）
///
/// # 为什么需要它
/// ```text
/// 申请设备码的响应里有 `device_code` —— 它是换 token 的**唯一**钥匙，等同凭据。
/// 所以不能像别处那样把 body 摘要直接写日志。但"响应到底有哪些字段"是现场判读的
/// 关键（服务端加个 `interval` 我们就能对上节奏）⇒ 只记键名。
/// 非 JSON ⇒ 回 "<非 JSON>"，让日志里一眼看出"回来的不是 JSON"。
/// ```
fn json_keys(body: &str) -> String {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(body) else {
        return "<非 JSON>".to_string();
    };
    let Some(obj) = v.as_object() else {
        return "<非对象>".to_string();
    };
    obj.keys().cloned().collect::<Vec<_>>().join(",")
}

/// 顶层某个数值字段（数字或数字串都给；读不到 ⇒ None）
fn top_level_i64(body: &str, key: &str) -> Option<i64> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    num_i64(v.get(key)?)
}

// ═══════════════════════════════════════════════════════════════════════
//  落盘日志（现场可读性的前提；与 `pan_login` 同一份纪律）
// ═══════════════════════════════════════════════════════════════════════

/// 日志 tag：与 `pan_login` **同一个** `[PAN]`
///
/// ★ 为什么不新开一个 `[PAND]`：现场排查时 Owner 只会被告知一句 `grep '\[PAN\]'`。
///   两家用不同 tag ⇒ 他捞不到设备码那几行，而"扫码没反应"恰恰最需要那几行。
const LOG_TAG: &str = "PAN";

/// 测试进程判定（★ 必须用编译期 `cfg!(test)`，不能用环境变量 —— 见 `pan_login` 的踩坑记录）
fn in_test_process() -> bool {
    cfg!(test)
        || matches!(std::env::var("FLUTTER_TEST").as_deref(), Ok("true") | Ok("1"))
        || std::env::var("DART_TEST").is_ok()
        || std::env::var("SOURIN_TEST_LOG").is_ok()
}

fn log_file_path() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var("SOURIN_LOG_FILE") {
        if !p.trim().is_empty() {
            return Some(std::path::PathBuf::from(p));
        }
    }
    if in_test_process() {
        return None;
    }
    let base = std::env::var("APPDATA").ok()?;
    let day = chrono::Local::now().format("%Y-%m-%d").to_string();
    Some(
        std::path::PathBuf::from(base)
            .join("app.sourin.player")
            .join("logs")
            .join(format!("sourin-{day}.log")),
    )
}

/// 追加一行（失败静默 —— 日志不该影响功能）
fn write_log(msg: &str) {
    let Some(path) = log_file_path() else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let line = format!(
        "{} [{LOG_TAG}] {msg}\n",
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f"),
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write as _;
        let _ = f.write_all(line.as_bytes());
    }
}

/// 脱敏摘要（**只写形状，不写值**）
///
/// ★ token 是登录凭据，与 cookie 同一条硬规矩：**绝不进日志**。
///   但"多少字节"足够判"服务端给的是不是我们以为的那种 token"，且不泄密。
fn secret_digest(name: &str, value: &str) -> String {
    format!("{name}（{} 字节）", value.len())
}

// ═══════════════════════════════════════════════════════════════════════
//  会话表（**本文件私有**，不碰 `pan_login::SESSIONS`）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须自己一张表
// ```text
// 纪律：不许改 `pan_login`（Lead 的文件）⇒ 它的 `SESSIONS` 是私有的，也进不去。
// 而且两张表本来就更对：设备码会话的过期依据**理想上**是服务端给的 expires_in，
// 而 `pan_login` 那边是陪跑一个 5 分钟常数。硬塞一张表就要为一个字段分两种语义。
// ```

/// `key` → 进行中的设备码会话
static SESSIONS: OnceLock<Mutex<HashMap<String, DeviceSession>>> = OnceLock::new();

struct DeviceSession {
    /// 服务端给的 `device_code`（换 token 的**唯一**钥匙；取证 §2.1-C 的 `token` 字段）
    device_code: String,
    /// 这个会话在本地的失效时刻（Unix 秒）
    ///
    /// ★ `min(本地兜底, 服务端 expires_in)`：
    ///   `expires_in` **未取证**（文件头②）⇒ 通常走本地兜底；
    ///   若服务端哪天给了，就用更短的那个（宁可让用户重来，也不让他对着一个
    ///   已失效的码干等）。
    expires_at: i64,
}

fn sessions() -> &'static Mutex<HashMap<String, DeviceSession>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 本地兜底有效期（`expires_in` 未取证 ⇒ 这是**实际**生效的那个；标为推断）
const SESSION_TTL_SECS: i64 = 300;

fn kind_key(kind: PanKind, key: &str) -> String {
    format!("{}:{}", kind.code(), key)
}

/// 看一眼会话还在不在（在 ⇒ 回 `device_code`）
///
/// ★ 为什么是 `get` 而不是 `remove`：**轮询要能被重复调用**。
///   第一版写成 `remove`（想顺手清掉过期项），后果是"一次 Pending 之后会话就没了
///   ⇒ 第二次轮询报『会话不在』⇒ 用户永远看不到自己确认后的结果"。
///   这个 bug 只在**多次轮询**时现形，一次单测发现不了 ⇒ 所以现在按"读"实现，
///   过期项才删。
fn peek_session(kind: PanKind, key: &str) -> Option<String> {
    let mut map = sessions().lock().unwrap_or_else(|e| e.into_inner());
    let k = kind_key(kind, key);
    let expired = matches!(map.get(&k), Some(rec) if now() >= rec.expires_at);
    if expired {
        map.remove(&k);
        return None;
    }
    map.get(&k).map(|rec| rec.device_code.clone())
}

// ═══════════════════════════════════════════════════════════════════════
//  解析：申请设备码的响应（取证 §2.1-C / §3.1-B 的字段绑定）
// ═══════════════════════════════════════════════════════════════════════

/// 申请设备码拿到的两样（+ 一个未取证的 `expires_in`）
#[derive(Debug, Clone, PartialEq, Eq)]
struct DeviceCodeInfo {
    /// 轮询用的钥匙（← 响应里的 `device_code`；**不给用户看**，只回给 UI 当 key）
    device_code: String,
    /// 服务端给的完整授权链接 ← **就是要编成二维码的那个 URL**
    verification_uri_complete: String,
    /// 有效期（秒）—— ⚠️ 未取证（文件头②）⇒ 通常为 None
    expires_in: Option<i64>,
}

/// JSON 里的数字：既认数字也认字符串（两种报文都见过；不是本家取证，属防御）
fn num_i64(v: &serde_json::Value) -> Option<i64> {
    match v {
        serde_json::Value::Number(n) => n.as_i64(),
        serde_json::Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

/// 解析申请设备码的响应（**纯函数**，可离线断言）
///
/// # 字段绑定（逐字取证，不是猜的）
/// ```text
/// url   ← verification_uri_complete   （buildGuangyaQrInfo 0x0032–0x003a）
/// token ← device_code                 （buildGuangyaQrInfo 0x003d–0x0045）
/// ```
///
/// # ★★★ 一条"宁可报错也不许补"的硬线
/// ```text
/// 少了 `verification_uri_complete` 时，**不许**回落到 `verification_uri` + 拼一个码。
/// 理由：
///   ① 取证写明 `verification_uri_complete` 是**唯一**的那条串（str#23792），
///      而 `verification_uri`（不带 _complete）在全 dex **0 命中**
///      ⇒ 我们连它长什么样都不知道，"回落到它"纯属凭空发明；
///   ② 拼出来的 URL 形状完全正常 ⇒ UI 画出二维码 ⇒ 用户认真扫 ⇒ 什么都不会发生
///      （比直接报错难查得多）；
///   ③ 缺这个字段本身就是"协议变了"的信号，那正是我们最需要立刻知道的事。
/// ⇒ 缺字段 = `Err`，错误里点名字段、附 `tail`。
/// ```
fn device_code_info(body: &str, label: &str) -> Result<DeviceCodeInfo, String> {
    let v: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| format!("{label}的设备码响应不是 JSON（{e}）：{}", tail(body)))?;

    let get_str = |k: &str| -> String {
        v.get(k)
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .trim()
            .to_string()
    };

    let device_code = get_str("device_code");
    if device_code.is_empty() {
        return Err(format!(
            "{label}的设备码响应里没有 device_code ⇒ 没有轮询用的钥匙（协议可能变了）：{}",
            tail(body)
        ));
    }

    let verification_uri_complete = get_str("verification_uri_complete");
    if verification_uri_complete.is_empty() {
        return Err(format!(
            "{label}的设备码响应里没有 verification_uri_complete ⇒ 没有可编成二维码的 URL。\
             （本模块不用别的字段拼一个替代品：那会造出一个看起来能扫、实际扫不动的码）\
             响应摘要：{}",
            tail(body)
        ));
    }

    Ok(DeviceCodeInfo {
        device_code,
        verification_uri_complete,
        expires_in: v.get("expires_in").and_then(num_i64),
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  解析：换 token 的响应
// ═══════════════════════════════════════════════════════════════════════

/// 一次换 token 的结果
#[derive(Debug, Clone, PartialEq, Eq)]
enum TokenStep {
    /// 拿到了真 token ⇒ 这是**唯一**可以判 Confirmed 的分支
    Token {
        access_token: String,
        /// 空串 = 服务端没给（不是错误：很多实现不发）
        refresh_token: String,
        expires_in: Option<i64>,
    },
    /// 还没成（Pending / Scanned / Expired / Failed 都在这里 —— 共同点是**没有凭据**）
    NotConfirmed(QrStatus, String),
    /// 响应体根本不是 JSON（连"在等"都判不出来）
    NotJson,
}

/// RFC 8628 §3.5 的 `error` 串 → 三态
///
/// `None` = 不是这几个已知值（由调用方决定怎么处置，见 [`token_step_of`]）。
///
/// # ⚠️⚠️ 这四个字面量 **dex 里 0 命中**（文件头③）
/// ```text
/// 参考实现根本不判它们，只判 `has("access_token")`（handleGuangya 0x0051 /
/// handleXunlei 0x0051）。⇒ 本函数是**按 RFC 8628 标准形态推断**出来的，
/// **不是读数**。两条后果必须记住：
///   ① 服务端实际回哪个串我们**不知道** ⇒ 认不出的串一律按"未确认"走（见下），
///      并把原始串塞进 message ⇒ 真机一跑就能从日志读到它到底是什么；
///   ② 若服务端用的是完全另一套（比如 JSON 里给 `status: 1`），本函数一条都不会命中
///      ⇒ 表现是"一直 Pending"。那时**不要**猜着加分支，去读日志里的原始 body。
/// ```
///
/// ★ 为什么仍按这套写而不是"只判 access_token"：
///   `authorization_pending` 与 `slow_down` 是**正常中间态**，但服务端会用
///   **HTTP 400** 返回它们（RFC 8628 §3.5 就是这么定的）⇒ 只看 HTTP 码会把
///   "用户还没确认"当失败，UI 立刻报错，而用户其实正要确认。
///   ⇒ 认得出的中间态必须**不**当错误。
fn classify_device_error(err: &str) -> Option<(QrStatus, &'static str)> {
    match err {
        "authorization_pending" => Some((QrStatus::Pending, "等待你在手机上/网页上确认…")),
        "slow_down" => Some((QrStatus::Pending, "等待确认…（服务端要求放慢轮询）")),
        "access_denied" => Some((QrStatus::Failed, "授权被拒绝了（在授权页点了拒绝）")),
        "expired_token" => Some((QrStatus::Expired, "设备码已过期，请重新获取")),
        _ => None,
    }
}

/// 解析换 token 的响应（**纯函数**，可离线断言）
///
/// # 判定顺序（顺序本身就是纪律）
/// ```text
/// ① 有非空 access_token ⇒ Token（**唯一**的 Confirmed 来源；
///    空串不算 —— 空串冒充"拿到了"就会出现"登录成功但没有凭据"，
///    而参考实现的判据正是 `has("access_token")`，一个 `""` 也能过它）
/// ② 有已知 error 串      ⇒ NotConfirmed(对应态)
/// ③ 有未知 error 串      ⇒ NotConfirmed(Pending, 带上原始串)
///    （纪律："未确认一律 Pending"；但把原始串写进 message，免得真出错时看不见）
/// ④ 既没 token 也没 error ⇒ NotConfirmed(Pending)
/// ⑤ 不是 JSON            ⇒ NotJson（由调用方报 Err，带 HTTP 码与摘要）
/// ```
fn token_step_of(body: &str) -> TokenStep {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(body) else {
        return TokenStep::NotJson;
    };
    let access = v
        .get("access_token")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if !access.is_empty() {
        let refresh = v
            .get("refresh_token")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        return TokenStep::Token {
            access_token: access,
            refresh_token: refresh,
            expires_in: v.get("expires_in").and_then(num_i64),
        };
    }
    let err = v
        .get("error")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    match classify_device_error(&err) {
        Some((st, msg)) => TokenStep::NotConfirmed(st, msg.to_string()),
        None if !err.is_empty() => TokenStep::NotConfirmed(
            QrStatus::Pending,
            format!("等待确认…（服务端状态：{err}）"),
        ),
        None => TokenStep::NotConfirmed(
            QrStatus::Pending,
            "等待你在手机上/网页上确认…".to_string(),
        ),
    }
}

/// 把 token 写成**约定键名**的凭据串（token 型网盘的统一存法）
///
/// `access_token=<…>` 必有；`refresh_token` 有就一起写（没有就不写 ——
/// 写一个空的 `refresh_token=` 会让消费方以为"有但为空"，与"没有"混不起来）。
fn token_credential_string(access: &str, refresh: &str) -> String {
    let refresh = refresh.trim();
    if refresh.is_empty() {
        format!("access_token={access}")
    } else {
        format!("access_token={access}; refresh_token={refresh}")
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  共用 core：① 申请设备码 → ② 轮询换 token
// ═══════════════════════════════════════════════════════════════════════

/// 申请设备码并建一个会话（两家共用）
async fn device_start(spec: &DeviceFlowSpec) -> Result<QrSession, String> {
    // ★★ 第一行就落日志：Owner 现场"点了获取二维码、**没有任何日志、也没反应**"
    //    ⇒ 一条日志都没有时，连"到底走到哪一步"都无从判断。所以从建客户端开始，
    //    每一步（含**所有**出错分支）都必须留一行。
    write_log(&format!(
        "申请设备码开始 kind={} url={} body_len={}",
        spec.kind.code(),
        (spec.device_code_url)(),
        device_code_body(spec.device_client_id, spec.scope).len()
    ));
    let c = client(spec.ua).map_err(|e| {
        write_log(&format!(
            "建 HTTP 客户端失败 kind={} err={e}",
            spec.kind.code()
        ));
        e
    })?;
    let body = device_code_body(spec.device_client_id, spec.scope);
    let mut req = c.post((spec.device_code_url)()).body(body);
    for (k, v) in auth_step_headers() {
        req = req.header(k, v);
    }

    let resp = req.send().await.map_err(|e| {
        // 这条分支原来**完全静默**：网络/TLS/超时失败时现场看不到任何痕迹
        write_log(&format!(
            "申请设备码请求失败 kind={} err={e} （检查 DNS/防火墙/是否需代理）",
            spec.kind.code()
        ));
        format!("请求{}设备码接口失败：{e}", spec.label)
    })?;
    let status = resp.status();
    let body = resp.text().await.map_err(|e| {
        write_log(&format!(
            "读设备码响应失败 kind={} HTTP {status} err={e}",
            spec.kind.code()
        ));
        format!("读{}设备码响应失败：{e}", spec.label)
    })?;
    if !status.is_success() {
        write_log(&format!(
            "申请设备码失败 kind={} HTTP {status} body={}",
            spec.kind.code(),
            tail(&body)
        ));
        return Err(format!(
            "{}申请设备码返回 HTTP {status}：{}",
            spec.label,
            tail(&body)
        ));
    }

    // ★ 只记**键名**与几个数值：`device_code` 是轮询钥匙（等同凭据），不许进日志
    write_log(&format!(
        "申请设备码响应 kind={} HTTP {status} body_len={} keys=[{}] interval={:?}",
        spec.kind.code(),
        body.len(),
        json_keys(&body),
        top_level_i64(&body, "interval")
    ));

    let info = match device_code_info(&body, spec.label) {
        Ok(i) => i,
        Err(e) => {
            write_log(&format!(
                "解析设备码响应失败 kind={} err={e}",
                spec.kind.code()
            ));
            return Err(e);
        }
    };

    // 有效期：`min(本地兜底, 服务端 expires_in)`（`expires_in` 未取证 ⇒ 通常走兜底）
    let ttl = match info.expires_in {
        Some(s) if s > 0 => s.min(SESSION_TTL_SECS),
        _ => SESSION_TTL_SECS,
    };
    let created_at = now();
    sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(
            kind_key(spec.kind, &info.device_code),
            DeviceSession {
                device_code: info.device_code.clone(),
                expires_at: created_at + ttl,
            },
        );

    let svg = crate::remote::qr_svg_for(&info.verification_uri_complete).unwrap_or_default();
    // ★ 现场判读用：device_code 只记长度（它是轮询钥匙，等同凭据，不许进日志）
    write_log(&format!(
        "取码成功 kind={} {} svg_len={} ttl={ttl}s expires_in={:?}",
        spec.kind.code(),
        secret_digest("device_code", &info.device_code),
        svg.len(),
        info.expires_in
    ));

    Ok(QrSession {
        key: info.device_code,
        url: info.verification_uri_complete,
        svg,
        // ★ 设备码流程的提示与扫码流程**不同**：这里的 URL 是一个"要用户去访问的授权链接"
        //   （它已含码），所以提示里同时给"扫码"和"打开链接"两条路。
        //   取证里没有 `user_code`（0 命中）⇒ 不展示人读码，也不编一个。
        hint: format!("用{} App 扫这个码，或在浏览器打开链接确认登录", spec.label),
        created_at,
    })
}

/// 轮询一次（两家共用）
///
/// # 三条纪律（都在这个函数里体现）
/// ```text
/// ① **未确认一律 Pending**：只有 `access_token` 非空才 Confirmed 并产出凭据；
///    `authorization_pending`/`slow_down` 是 HTTP 400 ⇒ 不能按 HTTP 码判失败。
/// ② 失败/缺字段/HTTP 非 2xx ⇒ 可读 Err，**必须**带 HTTP 码与响应摘要。
/// ③ 会话检查在**任何网络请求之前**（否则一个不存在的 key 也会去打服务端）。
/// ```
async fn device_poll(spec: &DeviceFlowSpec, key: &str) -> Result<PollOutcome, String> {
    let key = key.trim();
    if key.is_empty() {
        return Err(format!("{}登录会话 key 为空 —— 请重新获取", spec.label));
    }

    let Some(device_code) = peek_session(spec.kind, key) else {
        // 没这个会话 / 已超时 ⇒ 如实说"失效"，不假装还在轮询（否则 UI 永远转圈）
        write_log(&format!(
            "轮询 kind={} 会话不在或已超时 key_len={}",
            spec.kind.code(),
            key.len()
        ));
        return Ok(PollOutcome {
            status: QrStatus::Expired,
            message: "这个设备码已失效（会话不在或已超时），请重新获取".to_string(),
            credential: None,
        });
    };

    let c = client(spec.ua).map_err(|e| {
        write_log(&format!(
            "轮询前建 HTTP 客户端失败 kind={} err={e}",
            spec.kind.code()
        ));
        e
    })?;
    let body = token_body(spec.token_client_id, &device_code);
    let mut req = c.post((spec.token_url)()).body(body);
    for (k, v) in auth_step_headers() {
        req = req.header(k, v);
    }
    let resp = req.send().await.map_err(|e| {
        write_log(&format!(
            "轮询请求失败 kind={} err={e}",
            spec.kind.code()
        ));
        format!("轮询{}登录状态失败：{e}", spec.label)
    })?;
    let status = resp.status();
    let body = resp.text().await.map_err(|e| {
        write_log(&format!(
            "读轮询响应失败 kind={} HTTP {status} err={e}",
            spec.kind.code()
        ));
        format!("读{}轮询响应失败：{e}", spec.label)
    })?;

    let step = token_step_of(&body);
    write_log(&format!(
        "轮询 kind={} HTTP {status} step={} body={}",
        spec.kind.code(),
        match &step {
            TokenStep::Token { .. } => "token",
            TokenStep::NotConfirmed(st, _) => st.code(),
            TokenStep::NotJson => "not-json",
        },
        tail(&body)
    ));

    match step {
        TokenStep::Token {
            access_token,
            refresh_token,
            expires_in,
        } => {
            // ★ 到这里才 Confirmed —— 而且这是**唯一**的 Confirmed 分支
            write_log(&format!(
                "换 token 成功 kind={} {} {} 有效期={:?}",
                spec.kind.code(),
                secret_digest("access_token", &access_token),
                secret_digest(
                    "refresh_token",
                    if refresh_token.is_empty() {
                        "<无>"
                    } else {
                        refresh_token.as_str()
                    }
                ),
                expires_in
            ));
            // 会话用完即弃：`device_code` 是一次性的（同一把钥匙再换一次 token，
            // 服务端会回 invalid_grant）；删掉也让"再轮询一次"不会产出第二份凭据。
            sessions()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(&kind_key(spec.kind, key));
            Ok(PollOutcome {
                status: QrStatus::Confirmed,
                message: format!("登录成功：{}", spec.account),
                credential: Some(PanCredential {
                    kind: spec.kind,
                    account: spec.account.to_string(),
                    cookie: token_credential_string(&access_token, &refresh_token),
                    saved_at: now(),
                    expires_at: expires_in.map(|s| now() + s),
                }),
            })
        }
        TokenStep::NotConfirmed(st, msg) => Ok(PollOutcome {
            status: st,
            message: msg,
            credential: None,
        }),
        // 不是 JSON ⇒ 连"在等"都判不出 ⇒ 如实 Err（带 HTTP 码 + 摘要）
        TokenStep::NotJson => Err(format!(
            "{}换 token 的响应不是 JSON（HTTP {status}）：{}",
            spec.label,
            tail(&body)
        )),
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  对外 API（`pan_login` 的 dispatch 只调这四个）
// ═══════════════════════════════════════════════════════════════════════

/// 光鸭：申请设备码（`url` = 服务端给的 `verification_uri_complete`）
pub async fn guangya_start() -> Result<QrSession, String> {
    device_start(&guangya_spec()).await
}

/// 光鸭：轮询；拿到 token 才产出凭据（落盘由 `pan_login::qr_login_poll` 统一做）
pub async fn guangya_poll(key: &str) -> Result<PollOutcome, String> {
    device_poll(&guangya_spec(), key).await
}

/// 迅雷：申请设备码
///
/// ★ 端点**已取证**：`https://xluser-ssl.xunlei.com/v1/auth/device/code`
///   （str#18853 / `.probe/r3-t20-strpool-urls.txt:630`）。
///   上一版骨架写"申请设备码的端点本轮仍未取证"，那是**工具漏报**造成的
///   （`.probe/r3c-dexstrings.py` 的指令长度表有 12 处错，`const-string` 被跳过）；
///   本轮修正后复核，这条串确实在 `merge.m.G.buildXunleiQrInfo` 里 ⇒ 按取证实现。
pub async fn xunlei_start() -> Result<QrSession, String> {
    device_start(&xunlei_spec()).await
}

/// 迅雷：轮询；拿到 token 才产出凭据
pub async fn xunlei_poll(key: &str) -> Result<PollOutcome, String> {
    device_poll(&xunlei_spec(), key).await
}

// ═══════════════════════════════════════════════════════════════════════
//  门禁（每条都能真的变红；注入方式写在各自注释里）
// ═══════════════════════════════════════════════════════════════════════
#[cfg(test)]
mod tests {
    use super::*;

    // ── URL / 请求体 / 请求头：逐字钉住 ──

    /// ★★★ 光鸭：端点、client_id、scope、**请求体整串**、UA 逐字
    ///
    /// ```text
    /// 注入验证（已实测）：把 `GUANGYA_CLIENT_ID` 改一个字符
    ///   ⇒ 本条 FAILED。
    /// 为什么这条重要：出码那一步若 client_id 错了，服务端**未必**报错
    ///   （很多 OAuth 服务对未知 client 返回 400，但有的直接当匿名）⇒
    ///   现场表现是"扫了没反应"，而日志里 HTTP 是 200。
    /// ```
    #[test]
    fn guangya_device_flow_matches_evidence() {
        assert_eq!(
            guangya_device_code_url(),
            "https://account.guangyapan.com/v1/auth/device/code",
            "★ str#18370 / .probe/r3-t20-strpool-urls.txt:147"
        );
        assert_eq!(
            guangya_token_url(),
            "https://account.guangyapan.com/v1/auth/token",
            "★ str#18371 / :148"
        );
        assert_eq!(GUANGYA_CLIENT_ID, "aMe-8VSlkrbQXpUR");
        assert_eq!(GUANGYA_SCOPE, "user", "★ 取证 0x001a 就是 user");

        // ★★ 请求体**整串**逐字（含字段顺序）—— 取证 0x0011–0x001c
        assert_eq!(
            device_code_body(GUANGYA_CLIENT_ID, GUANGYA_SCOPE),
            r#"{"client_id":"aMe-8VSlkrbQXpUR","scope":"user"}"#
        );

        let s = guangya_spec();
        assert_eq!(s.kind, PanKind::Guangya);
        assert_eq!(
            s.token_client_id, GUANGYA_CLIENT_ID,
            "★ 光鸭两步是**同一个** client_id（迅雷不是）"
        );
        // UA 必须是桌面 Chrome（取证 0x0005–0x0009）
        assert!(s.ua.contains("Chrome/151.0.0.0"), "{}", s.ua);
        assert!(!s.ua.contains("ANDROID"), "★ 光鸭不是安卓端：{}", s.ua);
    }

    /// ★★★ 迅雷：端点、两个 client_id、**请求体整串**、安卓 UA 逐字
    ///
    /// ```text
    /// 注入验证（已实测）：把 `XUNLEI_CLIENT_ID_TOKEN` 改成与
    ///   `XUNLEI_CLIENT_ID_DEVICE` 相同 ⇒ 本条 FAILED（assert_ne + 请求体断言）。
    /// 这类错在真机上表现为"用户点了同意，轮询永远换不到 token"，极难查。
    /// ```
    #[test]
    fn xunlei_device_flow_matches_evidence() {
        assert_eq!(
            xunlei_device_code_url(),
            "https://xluser-ssl.xunlei.com/v1/auth/device/code",
            "★ str#18853 / .probe/r3-t20-strpool-urls.txt:630"
        );
        assert_eq!(
            xunlei_token_url(),
            "https://xluser-ssl.xunlei.com/v1/auth/token",
            "★ str#18854 / :631"
        );
        assert_eq!(XUNLEI_CLIENT_ID_DEVICE, "XW-G4v1H72tgfJym");
        assert_eq!(XUNLEI_CLIENT_ID_TOKEN, "Xp6vsxz_7IYVw2BB");
        assert_ne!(
            XUNLEI_CLIENT_ID_DEVICE, XUNLEI_CLIENT_ID_TOKEN,
            "★★ 出码与换 token 是**两个** client_id（取证 §3.1-C）"
        );
        assert_eq!(XUNLEI_SCOPE, "", "★ 取证的 scope 是空串（str#0）");

        // ★★ 出码请求体整串逐字 —— 空 scope 也要**照样发**
        assert_eq!(
            device_code_body(XUNLEI_CLIENT_ID_DEVICE, XUNLEI_SCOPE),
            r#"{"client_id":"XW-G4v1H72tgfJym","scope":""}"#
        );

        let s = xunlei_spec();
        assert_eq!(s.kind, PanKind::Xunlei);
        assert!(
            s.ua.starts_with("ANDROID-com.xunlei.downloadprovider/8.31.0.9726"),
            "{}",
            s.ua
        );
        assert!(s.ua.contains("appid/40") && s.ua.contains("Oauth2Client/0.9"), "{}", s.ua);
    }

    /// ★★★ 换 token 的请求体：grant_type 逐字 + **client_id 用对那一个**
    ///
    /// ```text
    /// 注入验证（已实测）：把 `DEVICE_GRANT_TYPE` 改成一个普通字符串
    ///   ⇒ 本条 FAILED（服务端回 unsupported_grant_type）。
    /// ```
    #[test]
    fn token_body_matches_evidence_for_both() {
        assert_eq!(
            DEVICE_GRANT_TYPE,
            "urn:ietf:params:oauth:grant-type:device_code"
        );
        assert_eq!(
            token_body(GUANGYA_CLIENT_ID, "dc1"),
            r#"{"client_id":"aMe-8VSlkrbQXpUR","device_code":"dc1","grant_type":"urn:ietf:params:oauth:grant-type:device_code"}"#
        );
        // ★ 迅雷换 token 用的是**另一个** id
        assert_eq!(
            token_body(XUNLEI_CLIENT_ID_TOKEN, "dc1"),
            r#"{"client_id":"Xp6vsxz_7IYVw2BB","device_code":"dc1","grant_type":"urn:ietf:params:oauth:grant-type:device_code"}"#
        );
        // 反空真：两个 spec 产出的 body 必须不同（串了 id 就会相同）
        assert_ne!(
            token_body(guangya_spec().token_client_id, "x"),
            token_body(xunlei_spec().token_client_id, "x")
        );
        // device_code 里的引号必须被转义（否则 body 不是合法 JSON）
        let b = token_body(GUANGYA_CLIENT_ID, r#"a"b"#);
        assert!(b.contains(r#"a\"b"#), "★ 必须转义，否则 body 坏掉：{b}");
        assert!(serde_json::from_str::<serde_json::Value>(&b).is_ok(), "{b}");
    }

    /// ★★★ 请求头**故意只有** Content-Type —— 守住"不多发未取证的头"
    ///
    /// ```text
    /// 注入验证（已实测）：在 `auth_step_headers()` 里加回一条
    ///   ("X-Device-Id", "dev") ⇒ 本条 FAILED。
    /// 为什么这条要存在：那三个头属于 `/v1/user/me`（§2.1-E），**不在**这两步。
    /// 多发的头不会报错，却会把"我们到底验证过什么"糊掉 ⇒ 用门禁挡住。
    /// ```
    #[test]
    fn auth_step_headers_are_minimal_on_purpose() {
        let h = auth_step_headers();
        assert_eq!(h.len(), 1, "★ 取证里这两步的头只有 Content-Type（UA 在 client 里）：{h:?}");
        assert_eq!(h[0].0, "Content-Type");
        assert_eq!(
            h[0].1, "application/json; charset=utf-8",
            "★ 取证是**带 charset** 的整串（merge.k.c.<init>）"
        );
        for banned in ["X-Device-Id", "X-Client-Id", "Authorization", "Referer"] {
            assert!(
                !h.iter().any(|(k, _)| *k == banned),
                "★★ `{banned}` 属于 /v1/user/me，不在 device/code 与 token 这两步（取证 §2.1-E）"
            );
        }
    }

    /// ★★ 轮询节奏常量：5 秒，且**注释里说的是推断**
    ///
    /// 这条钉的是"值只在一处"+"它确实是 RFC 默认"，不是"服务端就要 5 秒"。
    #[test]
    fn poll_interval_is_the_rfc_default_and_labelled_as_inferred() {
        assert_eq!(
            DEVICE_POLL_INTERVAL_SECS, 5,
            "★ RFC 8628 §3.5 默认 5 秒（dex 无 interval 读数）"
        );
    }

    // ── 申请设备码：响应解析 ──

    /// ★★★ 字段绑定 + 缺 `verification_uri_complete` **必须** Err（不许拼一个）
    ///
    /// ```text
    /// 注入验证（已实测）：在 `device_code_info` 里加一个回落分支
    ///   `if empty { format!("{}?user_code={}", ...) }` ⇒ 本条 FAILED
    ///   （第二条断言期望 Err）。
    /// 为什么这条最重要：拼出来的 URL 形状完全正常 ⇒ UI 画出二维码 ⇒
    ///   用户认真扫 ⇒ 什么都不会发生。**假绿**里最难查的一种。
    /// ```
    #[test]
    fn device_code_binds_url_and_token_and_requires_complete_uri() {
        // 取证 §2.1-C：url ← verification_uri_complete ；token ← device_code
        let ok = r#"{"device_code":"DC","verification_uri_complete":"https://x/auth?code=AB12",
            "expires_in":600}"#;
        let info = device_code_info(ok, "测试盘").expect("字段齐全必须成功");
        assert_eq!(info.device_code, "DC", "★ key 就是 device_code");
        assert_eq!(
            info.verification_uri_complete, "https://x/auth?code=AB12",
            "★ 二维码内容就是这个字段"
        );
        assert_eq!(info.expires_in, Some(600));

        // ★ 只有 verification_uri（不带 _complete）⇒ 必须报错，不许拼
        let no_complete =
            r#"{"device_code":"DC","verification_uri":"https://x/auth","user_code":"AB12"}"#;
        let e = device_code_info(no_complete, "测试盘").expect_err(
            "★★ 缺 verification_uri_complete 必须报错（verification_uri 全 dex 0 命中，不许回落到它）",
        );
        assert!(e.contains("verification_uri_complete"), "要点名缺的字段：{e}");
        assert!(e.contains("测试盘"), "要带上哪一家：{e}");
        assert!(e.contains("共"), "要附响应摘要（tail）：{e}");

        // 缺 device_code 也要报错（它是轮询的钥匙）
        let no_dc = r#"{"verification_uri_complete":"https://x/a"}"#;
        let e = device_code_info(no_dc, "测试盘").expect_err("缺 device_code 必须报错");
        assert!(e.contains("device_code"), "{e}");

        // 空白等同缺失（反空真：Some("") 不能冒充"有"）
        let blank = r#"{"device_code":"DC","verification_uri_complete":"   "}"#;
        assert!(device_code_info(blank, "测试盘").is_err(), "空白不算有 URL");

        // 不是 JSON ⇒ 报错并附摘要（不许"解析失败就当 Pending"）
        let e = device_code_info("<html>502</html>", "测试盘").expect_err("非 JSON 必须报错");
        assert!(e.contains("不是 JSON"), "{e}");
    }

    /// ★★ `expires_in` 未取证但若出现要能读（数字/字符串两种都认）
    #[test]
    fn device_code_tolerates_expires_in_shapes() {
        let n = r#"{"device_code":"DC","verification_uri_complete":"https://x/a","expires_in":600}"#;
        assert_eq!(device_code_info(n, "t").unwrap().expires_in, Some(600));
        let s = r#"{"device_code":"DC","verification_uri_complete":"https://x/a","expires_in":"600"}"#;
        assert_eq!(device_code_info(s, "t").unwrap().expires_in, Some(600));
        // 没有也不许报错（它本来就没取证）
        let none = r#"{"device_code":"DC","verification_uri_complete":"https://x/a"}"#;
        assert_eq!(device_code_info(none, "t").unwrap().expires_in, None);
    }

    // ── 换 token：状态机 ──

    /// ★★★ RFC 8628 的四个错误串 → 正确三态（**推断，非读数**，见注释）
    ///
    /// ```text
    /// 注入验证（已实测）：把 `"expired_token"` 那一支删掉（让它落到 Pending）
    ///   ⇒ 本条 FAILED。后果：用户拿着已过期的码，UI 永远显示"等待确认"。
    /// ```
    #[test]
    fn token_step_maps_rfc_states_as_inferred() {
        let mk = |e: &str| format!(r#"{{"error":"{e}","error_description":"x"}}"#);
        assert_eq!(
            token_step_of(&mk("authorization_pending")),
            TokenStep::NotConfirmed(QrStatus::Pending, "等待你在手机上/网页上确认…".to_string()),
            "★★ authorization_pending 是**正常中间态**（HTTP 400 也要当 Pending）"
        );
        assert_eq!(
            token_step_of(&mk("slow_down")),
            TokenStep::NotConfirmed(
                QrStatus::Pending,
                "等待确认…（服务端要求放慢轮询）".to_string()
            )
        );
        assert_eq!(
            token_step_of(&mk("access_denied")),
            TokenStep::NotConfirmed(
                QrStatus::Failed,
                "授权被拒绝了（在授权页点了拒绝）".to_string()
            )
        );
        assert_eq!(
            token_step_of(&mk("expired_token")),
            TokenStep::NotConfirmed(QrStatus::Expired, "设备码已过期，请重新获取".to_string())
        );
        // 未知错误串 ⇒ **仍算未确认**（纪律：未确认一律 Pending），但原始串要留着
        // （这样真机一跑，日志里就能读到"服务端到底回的是什么"）
        match token_step_of(&mk("weird_new_error")) {
            TokenStep::NotConfirmed(QrStatus::Pending, msg) => {
                assert!(msg.contains("weird_new_error"), "未知错误要把原始串带出来：{msg}");
            }
            other => panic!("未知错误串不许判成别的：{other:?}"),
        }
        // 既没 token 也没 error ⇒ Pending（不是失败）
        assert!(matches!(
            token_step_of(r#"{"k":"v"}"#),
            TokenStep::NotConfirmed(QrStatus::Pending, _)
        ));
        // 不是 JSON ⇒ NotJson（由调用方报 Err，带 HTTP 码）
        assert_eq!(token_step_of("<html>oops</html>"), TokenStep::NotJson);
    }

    /// ★★★ **只有真 token 才 Confirmed**：空串不算
    ///
    /// ```text
    /// 注入验证（已实测）：把 `if !access.is_empty()` 改成 `if true`
    ///   ⇒ 本条 FAILED。
    /// 后果正是"登录成功但没有凭据"：`token_credential_string("")` 会产出
    /// `access_token=`，看起来存了、用起来全 401。
    /// （参考实现只判 `has("access_token")`，一个 "" 也能过它 ⇒ 我们这里必须更严。）
    /// ```
    #[test]
    fn only_a_real_access_token_confirms() {
        let t = token_step_of(r#"{"access_token":"AT","refresh_token":"RT","expires_in":7200}"#);
        assert_eq!(
            t,
            TokenStep::Token {
                access_token: "AT".to_string(),
                refresh_token: "RT".to_string(),
                expires_in: Some(7200)
            }
        );
        assert!(
            !matches!(
                token_step_of(r#"{"access_token":""}"#),
                TokenStep::Token { .. }
            ),
            "★★ 空串不许冒充 token（会造出『登录成功但凭据为空』）"
        );
        assert!(!matches!(
            token_step_of(r#"{"access_token":"   "}"#),
            TokenStep::Token { .. }
        ));
        // 没有 refresh_token 不是错
        assert_eq!(
            token_step_of(r#"{"access_token":"AT"}"#),
            TokenStep::Token {
                access_token: "AT".to_string(),
                refresh_token: String::new(),
                expires_in: None
            }
        );
    }

    /// ★★★ 凭据是**约定键名**（`access_token=`），refresh 有才写
    ///
    /// ```text
    /// 注入验证：把 `"refresh_token={refresh}"` 改成 `"refresh={refresh}"`
    ///   ⇒ 本条 FAILED（消费方按 refresh_token= 取会取不到）。
    /// ```
    #[test]
    fn token_credential_uses_the_agreed_keys() {
        assert_eq!(
            token_credential_string("AT", "RT"),
            "access_token=AT; refresh_token=RT"
        );
        assert_eq!(token_credential_string("AT", ""), "access_token=AT");
        assert_eq!(token_credential_string("AT", "  "), "access_token=AT");
        assert!(
            !token_credential_string("AT", "").contains("refresh_token"),
            "★ 没有就别写空键（消费方会以为『有但为空』）"
        );
        assert!(!token_credential_string("AT", "RT").contains("Cookie"));
    }

    // ── 会话表 / 对外行为（**都不打网络**：会话不在时先于 HTTP 返回）──

    /// ★★★ 未知 key ⇒ Expired（**不发请求**、不静默 Pending）
    ///
    /// 这条同时守住"没有会话时根本不该打网络"：若有人把会话检查挪到 HTTP 之后，
    /// 本测试会真去连光鸭/迅雷（10s 超时）⇒ 立刻暴露。
    #[tokio::test]
    async fn unknown_key_reports_expired_not_pending() {
        for (label, out) in [
            ("光鸭", guangya_poll("no-such-key").await),
            ("迅雷", xunlei_poll("no-such-key").await),
        ] {
            let out = out.expect("『会话不在』是正常状态，不是错误");
            assert_eq!(
                out.status,
                QrStatus::Expired,
                "★★ {label}：会话不在 ⇒ 必须说失效，不许假装在轮询"
            );
            assert!(out.credential.is_none(), "{label}：没有会话就不该产出凭据");
            assert!(out.message.contains("重新获取"), "{}", out.message);
        }
    }

    /// ★★ 空 key ⇒ 可读 Err（而不是去查一个 "" 的会话）
    #[tokio::test]
    async fn empty_key_is_an_error() {
        for e in [
            guangya_poll("  ").await.expect_err("空 key 应报错"),
            xunlei_poll("").await.expect_err("空 key 应报错"),
        ] {
            assert!(e.contains("重新获取"), "{}", e);
        }
    }

    /// ★★★ 本地 TTL：过期的会话 ⇒ Expired，且**不会**打网络
    ///
    /// ```text
    /// 注入验证：把 `peek_session` 里的 `now() >= rec.expires_at` 改成 `false`
    ///   ⇒ 本条 FAILED（会把过期会话当有效，然后真去连服务端）。
    /// ```
    #[tokio::test]
    async fn expired_session_is_expired_without_network() {
        for kind in [PanKind::Guangya, PanKind::Xunlei] {
            sessions()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .insert(
                    kind_key(kind, "old-key"),
                    DeviceSession {
                        device_code: "DC-OLD".to_string(),
                        expires_at: now() - 1,
                    },
                );
        }
        let g = guangya_poll("old-key").await.unwrap();
        assert_eq!(g.status, QrStatus::Expired, "光鸭过期会话要判 Expired");
        assert!(g.credential.is_none());
        let x = xunlei_poll("old-key").await.unwrap();
        assert_eq!(x.status, QrStatus::Expired, "迅雷过期会话要判 Expired");
        assert!(x.credential.is_none());
    }

    /// ★★★ 同一 key 可以**重复**轮询（会话不被第一次读就走）
    ///
    /// ```text
    /// 这条守的是一个真踩过的 bug：第一版 `take_session` 用 `remove`，
    /// 一次 Pending 之后会话就没了 ⇒ 第二次轮询报"会话不在" ⇒
    /// 用户确认后永远看不到结果。⇒ 现在连查两次，会话必须还在。
    /// 注入验证：把 `peek_session` 的 `.get(&k)` 改成 `.remove(&k)`
    ///   ⇒ 本条 FAILED（第二次为 None）。
    /// ```
    #[test]
    fn session_survives_repeated_peeks() {
        let k = kind_key(PanKind::Guangya, "keep-key");
        sessions()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(
                k,
                DeviceSession {
                    device_code: "DC-KEEP".to_string(),
                    expires_at: now() + 60,
                },
            );
        assert_eq!(
            peek_session(PanKind::Guangya, "keep-key").as_deref(),
            Some("DC-KEEP")
        );
        assert_eq!(
            peek_session(PanKind::Guangya, "keep-key").as_deref(),
            Some("DC-KEEP"),
            "★★ 第二次看必须还在（否则一次 Pending 就永久失效）"
        );
        // 但不许串家：迅雷查同一个 key 应该查不到
        assert!(peek_session(PanKind::Xunlei, "keep-key").is_none(), "★ 会话按 kind 分区");
    }

    /// ★★ `is_device_flow` 只认这两家（Lead 的分流依赖它；多认一家就会把
    ///    CAS 那几家的 key 送进本模块的会话表 ⇒ 刚出码就"过期"）
    #[test]
    fn is_device_flow_is_exactly_two_kinds() {
        assert!(is_device_flow(PanKind::Guangya));
        assert!(is_device_flow(PanKind::Xunlei));
        for k in [
            PanKind::Quark,
            PanKind::Uc,
            PanKind::Baidu,
            PanKind::Aliyun,
            PanKind::Pan123,
            PanKind::Pan115,
            PanKind::Tianyi,
            PanKind::Unknown,
        ] {
            assert!(!is_device_flow(k), "★ {:?} 不是设备码流程", k);
        }
    }

    // ── 日志纪律（与 `pan_login` 同一套门禁的"自备副本"）──

    /// ★★★ token **绝不许**进日志（与 cookie 同一条硬规矩）
    ///
    /// ```text
    /// 注入验证：把 `secret_digest("access_token", &access_token)` 换成直接 `&access_token`
    ///   ⇒ 本条 FAILED。日志会被 Owner 复制给我们、也可能随诊断包外发 ⇒ 写进去就泄了。
    /// ```
    #[test]
    fn log_digest_never_contains_the_secret() {
        let secret = "a1b2c3supersecrettoken";
        let d = secret_digest("access_token", secret);
        assert!(!d.contains(secret), "★★★ 摘要里出现了 token 的值：{d}");
        assert!(d.contains("access_token"), "键名要留下（判形状用）：{d}");
        assert!(
            d.contains(&format!("{} 字节", secret.len())),
            "长度要留下：{d}"
        );
    }

    /// ★★ 测试进程**不许**写用户真实日志（否则每次 cargo test 都往 logs/ 写噪声）
    ///
    /// ```text
    /// 注入验证：删掉 `log_file_path` 里 `if in_test_process() { return None }`
    ///   ⇒ 本条红（读数里会直接打印出用户真实路径）。
    /// ```
    #[test]
    fn log_path_is_guarded_in_test_process() {
        assert!(in_test_process(), "cargo test 里 `cfg!(test)` 必须为真");
        if let Some(path) = log_file_path() {
            let s = path.to_string_lossy().to_string();
            assert!(
                !s.contains("app.sourin.player"),
                "★★★ 测试进程解析出了用户真实日志路径：{s}\n\
                 （若显式设了 SOURIN_LOG_FILE 则允许 —— 那是『要验格式』的意图）"
            );
        }
    }

    /// ★★ `tail` 不许在多字节字符中间切（否则日志本身变乱码）
    #[test]
    fn tail_never_panics_on_multibyte() {
        assert!(tail("").contains("0 字节"));
        let s = "光".repeat(300);
        assert!(tail(&s).contains("共"));
    }

    // ══════════════════════════════════════════════════════════════════
    //  真网 smoke test（默认 **ignored**；缺环境变量就跳过）
    // ══════════════════════════════════════════════════════════════════

    /// ★★★ 真网 smoke：两家各走一次 `device/code` → 立刻 `token`（应当 Pending）
    ///
    /// ```text
    /// 跑法（本机 2026-10-29 真跑过，读数见文件头的"真读数"段）：
    ///   cargo test --lib pan_login_device --release -- --ignored --nocapture
    /// 前提：`SOURIN_LIVE_DEVICE=1`（缺了就跳过 —— 不许在 CI/离线机器上自动联网）。
    /// ```
    ///
    /// # 它验的不是"能不能登录"（那要真账号），而是三件**此刻就能验的**事
    /// ```text
    /// ① 端点与请求形状（JSON + 那个 Content-Type + 那家自己的 UA）在真网**接受**；
    /// ② `verification_uri_complete` 真的给了 ⇒ 二维码有东西可编（这才是 Owner 点
    ///    "获取登录二维码"要看到的东西）；
    /// ③ 未确认时 token 端点回的是**可识别**的 pending（不是被我们当失败吞掉）。
    /// ```
    #[tokio::test]
    #[ignore = "真网；需要 SOURIN_LIVE_DEVICE=1"]
    async fn live_device_flow_reaches_device_code_and_pending() {
        if std::env::var("SOURIN_LIVE_DEVICE").as_deref() != Ok("1") {
            eprintln!("[skip] 未设 SOURIN_LIVE_DEVICE=1 ⇒ 不联网（这条是真网 smoke）");
            return;
        }

        for spec in [guangya_spec(), xunlei_spec()] {
            eprintln!(
                "\n===== {} =====",
                spec.label
            );
            let session = device_start(&spec)
                .await
                .unwrap_or_else(|e| panic!("{}申请设备码必须成功：{e}", spec.label));
            eprintln!(
                "start OK key_len={} url_host={} svg_len={}",
                session.key.len(),
                session
                    .url
                    .split('/')
                    .nth(2)
                    .unwrap_or("<no-host>"),
                session.svg.len()
            );
            assert!(
                session.url.starts_with("https://"),
                "{}的二维码 URL 必须是 https：{}",
                spec.label,
                session.url
            );
            assert!(
                !session.svg.is_empty(),
                "★ {}出了码但 svg 是空的 ⇒ UI 上什么都看不到（就是 Owner 说的『没反应』）",
                spec.label
            );

            // 立刻轮询一次：服务端此时**必然**未确认 ⇒ 我们应该如实 Pending
            let out = device_poll(&spec, &session.key)
                .await
                .unwrap_or_else(|e| panic!("{}轮询不该是 Err：{e}", spec.label));
            eprintln!(
                "poll #1 status={} message={}",
                out.status.code(),
                out.message
            );
            assert_eq!(
                out.status,
                QrStatus::Pending,
                "★★ {}未确认时必须 Pending（拿到凭据才算 Confirmed）：{}",
                spec.label,
                out.message
            );
            assert!(
                out.credential.is_none(),
                "★★ {}未确认却产出了凭据 —— 这就是「把失败伪造成成功」",
                spec.label
            );
        }
    }
}
