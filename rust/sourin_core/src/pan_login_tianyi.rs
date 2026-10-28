//! 天翼云盘（`PanKind::Tianyi`）—— logbox 的 uuid 扫码
//!
//! # 为什么单独开一个文件（而不是塞进 `pan_login`）
//!
//! ```text
//! `pan_login` 那几家的形状是「服务端给 token → 我把它拼进固定 URL → 轮询这个 token」。
//! 天翼不是：
//!   ① 二维码内容**是本机算出来的**：`URLDecoder.decode(getUUID.do 的 encodeuuid)`，
//!      不是服务端下发的 QR，也不是"固定前缀 + token"（dex 里没有拼接指令，见取证 B）；
//!   ② 准备会话要三跳（loginUrl.action → appConf.do → getUUID.do），
//!      而第 ① 跳**必须关闭重定向**去读 `Location` 头拿 lt/reqId；
//!   ③ 轮询的 11 个表单参数里有一半是"上一跳拿到的中间件"（paramId/uuid/encryuuid），
//!      外加一个几乎肯定是硬编码错的 `clientType=appId`。
//! ⇒ 会话状态机与判据都不能复用 `pan_login`，硬塞进去只会让两边都变 if/else。
//! ```
//!
//! # 取证（唯一权威：`.probe/pan-login-evidence-remaining.md` §4）
//!
//! ```text
//! A. 出码链路 = merge.m.G.buildCloudQrInfo → merge.b.l.k() → merge.b.l.j()
//! B. l.j() 只有 3 条指令（sget-object merge.b.l.b; return-object）
//!    ⇒ 二维码内容 = 静态字段 l.b；而 l.b 的唯一写入点是 k() 的 0x00d7–0x00e3：
//!      const-str '"encodeuuid":"(.+?)"'  → 正则取组 → URLDecoder.decode(…,"UTF-8")
//!      → sput-object merge.b.l.b
//! C. 三跳端点/参数/取值（本文件每个常量旁边都标了出处）
//! D. 轮询 qrcodeLoginState.do 的 11 个表单参数 + 3 个请求头 + 成功判据
//! E. 成功后 GET redirectUrl（跟随）→ 再取昵称 / 换 token
//! ```
//!
//! # 本轮**实现**了哪几步
//!
//! ```text
//! ① GET  loginUrl.action（**不跟随重定向**，从 Location 取 lt/reqId）      [`tianyi_login_url`]
//! ② POST appConf.do     （appKey=cloud&version=2.0，头 lt/reqId）           → reqId / paramId
//! ③ POST getUUID.do     （同参同头）                                       → uuid / encryuuid / encodeuuid
//!    二维码内容 = url_decode(encodeuuid)     ← 本文件自己写的纯函数 [`url_decode`]
//! ④ POST qrcodeLoginState.do（11 个表单参数）→ status==0 && redirectUrl≠空
//! ⑤ GET  redirectUrl（**跟随**，逐跳收 Set-Cookie）→ 登录态 cookie
//!    GET  getUserBriefInfo.action（带 cookie）→ nickname（取不到就用"天翼云盘"）
//! ```
//!
//! # ⚠️ **本轮不做**：`getAccessTokenBySsKey`（换 accessToken）
//!
//! ```text
//! 取证只到"端点 + 头名（appkey:600100422 / timestamp / sign-type:1）+ 待签串
//! `AppKey=600100422&Timestamp=<ts>&sessionKey=<sk>` + `signature`"。
//! **`signature` 的算法（HmacSHA1? MD5? 密钥是什么?）没有任何证据**（§8 自评表把它标成"中"）。
//! ⇒ 本轮**不实现**、不猜、更不编一段签名：编一段的结果是"看起来在换 token、
//!   永远 401 invalid signature"，比不做更难查。
//!   凭据就是 ⑤ 拿到的 cookie（天翼的 web 登录态本来就在 cookie 里）。
//!   留 TODO（见 [`tianyi_poll`] 里 `getUserBriefInfo` 之后那段注释）。
//! ```
//!
//! # ⚠️ 逐条"推断待真机确认"（**不许在读代码时当成已验证**）
//!
//! ```text
//! ① 轮询间隔：dex 全池**没有** device-flow 的 interval 用法 ⇒ 按 2s（"推断值"）。
//!    这不在本文件里设：UI 侧本来就是 ~2s 一次 poll，本文件不引入 sleep。
//! ② `status` 的非 0 取值语义：dex 只确证 `==0` 进成功分支，其余**无映射**
//!    ⇒ 本文件把"非 0 / 0 但 redirectUrl 空"一律当**继续等**（Pending），不猜"已扫/过期"。
//!    过期只能靠本地 TTL（[`SESSION_TTL_SECS`]）。
//! ③ `clientType="appId"`：dex 原文如此（疑为把 appId 误填给 clientType）。
//!    **逐字保留**，旁边留 TODO「若真机 400，先试 clientType=1」。
//! ④ ②③ 两跳的 `referer`：dex 只说"带 referer 头"，**值未逐字取证**
//!    ⇒ 用 [`REFERER_LOGIN`]（与第 ① 跳同一个值）。
//! ⑤ ②③④ 的报文形态按 `application/x-www-form-urlencoded`（dex 走 `merge.k.b.g`
//!    表单构造器；具体编码未逐字取证）。
//! ⑥ `getUserBriefInfo.action` 要带 `Cookie`（dex 只给了"读 nickname"，
//!    鉴权方式未逐字取证）⇒ 带上 ⑤ 的 cookie，失败**不影响**登录结果（只影响显示名）。
//! ⑦ 整条链路**没有真账号跑过**。
//! ```
//!
//! # 契约（`pan_login` 的 dispatch 调这两个）
//!
//! ```rust
//! pub async fn tianyi_start() -> Result<QrSession, String>;
//! pub async fn tianyi_poll(key: &str) -> Result<PollOutcome, String>;
//! ```
//!
//! ★★ **集成注意（Lead 侧的 `pan_login::qr_login_poll` 必读）**
//! ```text
//! 那个函数开头有一道"这个 key 在 SESSIONS 里吗 / 超时了吗"的检查，
//! 查的是 **pan_login 自己的** SESSIONS；本文件的会话在**自己的**表里
//! （纪律：本文件只许改自己 ⇒ 进不去它的私有表）。
//! ⇒ 天翼若走那条检查，key 永远"不存在" ⇒ 判成 Expired，**一次 HTTP 都不会发生**
//!   （UI 表现：刚出码就"已失效"）。
//! ⇒ 分流方式：`if pan_login_tianyi::is_tianyi_login(kind) { 直接进本模块的 poll }`
//!   并**跳过** `pan_login` 的会话存在性检查（本模块自己会做同样的检查）。
//! ```
//!
//! ★ 凭据的写入口仍然只有一个：`pan_login::qr_login_poll` 末尾那句
//!   `crate::pan_auth::save(cred)`。本文件的 `poll` **只产出** `PollOutcome.credential`。
//!
//! ★ 凭据形状：**cookie 串**（`k1=v1; k2=v2`），即 ⑤ 逐跳收下的 `Set-Cookie`。
//!   天翼不做 token 型凭据（原因见上"本轮不做"）。

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use crate::pan::PanKind;
use crate::pan_auth::PanCredential;
use crate::pan_login::{PollOutcome, QrSession, QrStatus};

// ═══════════════════════════════════════════════════════════════════════
//  ① 协议常量（逐字，出处标在每一条旁边）
// ═══════════════════════════════════════════════════════════════════════

/// 出码侧 UA —— 逐字 Chrome/151 桌面（§4.1-C 的 `user-agent`；dex 里就是这个串）
const UA_TIANYI: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                         (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// ★★ **硬编码常量**，不是随机 UUID
///
/// ```text
/// §4.1-D / §4.4-④：`be49bf790869632e336aac2d9c7877b8` 在 dex 里以**逐字常量**出现 3 处
/// （loginUrl.action 的 query、callbackUnify.action 的 query、轮询表单的 returnUrl）。
/// ⚠️ 别自己生成：服务端把 browserId 当"同一台设备"的钥匙，
///   换成随机值 ⇒ 三处不一致 ⇒ 回调那跳认不出这次扫码（表现是"扫了确认了，但没有登录态"）。
/// ```
const BROWSER_ID: &str = "be49bf790869632e336aac2d9c7877b8";

/// 第 ① 跳的 referer（`https://cloud.189.cn/web/login.html`，strpool:260）
///
/// ⚠️ ②③ 两跳的 referer 值**未逐字取证**（推断待确认 ④）⇒ 跟着用这个值。
const REFERER_LOGIN: &str = "https://cloud.189.cn/web/login.html";

/// logbox 域下的 referer（§4.1-D 的轮询头，逐字 `https://open.e.189.cn`）
const REFERER_LOGBOX: &str = "https://open.e.189.cn";

/// 第 ① 跳：准备扫码会话（**GET，必须关闭重定向**）
///
/// 逐字：`.probe/r3-t20-strpool-urls.txt:258`
/// ⇒ `https://cloud.189.cn/api/portal/loginUrl.action?redirectURL=https%3A%2F%2Fcloud.189.cn%2Fweb%2Fredirect.html&defaultSaveName=3&defaultSaveNameCheck=uncheck&browserId=<BROWSER_ID>`
/// （`lt` / `reqId` **只在 302 的 Location 头里**，见 §4.1-C 下方那个 ★ 注）
fn tianyi_login_url() -> &'static str {
    // ★ `redirectURL` 是**已百分号编码**的，且 `%3A%2F%2F` 一个都不能改：
    //   解码后是 `https://cloud.189.cn/web/redirect.html`，改一个字符服务端就回另一套回落页。
    "https://cloud.189.cn/api/portal/loginUrl.action\
     ?redirectURL=https%3A%2F%2Fcloud.189.cn%2Fweb%2Fredirect.html\
     &defaultSaveName=3&defaultSaveNameCheck=uncheck\
     &browserId=be49bf790869632e336aac2d9c7877b8"
}

/// 第 ② 跳：`appConf.do`（strpool:405，§4.1-C ②）
fn tianyi_appconf_url() -> &'static str {
    "https://open.e.189.cn/api/logbox/oauth2/appConf.do"
}

/// 第 ③ 跳：`getUUID.do`（strpool:406，§4.1-C ③）
fn tianyi_getuuid_url() -> &'static str {
    "https://open.e.189.cn/api/logbox/oauth2/getUUID.do"
}

/// 第 ④ 步：`qrcodeLoginState.do`（strpool:408，§4.1-D 0x0080）
fn tianyi_poll_url() -> &'static str {
    "https://open.e.189.cn/api/logbox/oauth2/qrcodeLoginState.do"
}

/// 第 ⑤ 步：取昵称（strpool:259，§4.1-E）
fn tianyi_userinfo_url() -> &'static str {
    "https://cloud.189.cn/api/portal/v2/getUserBriefInfo.action"
}

/// 轮询表单里的 `returnUrl`（**逐字**，strpool:256）
///
/// ★ 注意它自带 `browserId` 与**已编码**的 `redirectURL`：
///   这是 dex 里那个字符串常量的原文，不是我们拼的。
fn tianyi_return_url() -> &'static str {
    "https://cloud.189.cn/api/portal/callbackUnify.action\
     ?browserId=be49bf790869632e336aac2d9c7877b8\
     &redirectURL=https%3A%2F%2Fcloud.189.cn%2Fweb%2Fredirect.html"
}

/// ②③ 两跳共用的表单（`appKey=cloud`、`version=2.0`，§4.1-C）
///
/// ★ 返回**顺序无关**的键值对：门禁按 map 断言键名与值（表单语义上顺序无语义）。
fn tianyi_appconf_form() -> [(&'static str, &'static str); 2] {
    [("appKey", "cloud"), ("version", "2.0")]
}

/// 第 ④ 步的 11 个表单参数（**逐字**，§4.1-D 0x0018–0x0063）
///
/// # 为什么参数里有两个"看起来不属于这里"的东西
/// ```text
/// · `returnUrl` 是本文件写死的常量（含 browserId）—— 回调要靠它把登录态带回来；
/// · `paramId` / `uuid` / `encryuuid` 是前两跳拿到的中间件，**必须与本会话那一次一致**，
///   否则服务端会说"没有这个码"（表现：永远 Pending，且 HTTP 200）。
/// ```
///
/// ⚠️ `clientType="appId"`：**dex 原文如此**，疑为参考实现把 appId 误填给 clientType。
///    逐字保留 —— 改成"猜的正确值"就是拿不可证的猜测覆盖逐字证据。
///    TODO（推断待真机确认 ③）：若真机回 HTTP 400 / status 非 0，**先试 `clientType=1`**。
fn tianyi_poll_form(
    param_id: &str,
    uuid: &str,
    encryuuid: &str,
    date: &str,
    ts_ms: i64,
) -> Vec<(&'static str, String)> {
    vec![
        // `new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS").format(new Date())`
        ("date", date.to_string()),
        // `String.valueOf(new Date().getTime())` —— 毫秒
        ("timeStamp", ts_ms.to_string()),
        ("isOauth2", "false".to_string()),
        ("clientType", "appId".to_string()), // TODO: 真机 400 先试 "1"
        ("appId", "cloud".to_string()),
        ("cb_SaveName", "3".to_string()),
        ("state", String::new()), // 空串，但**键必须在**（dex 就是这个形态）
        ("returnUrl", tianyi_return_url().to_string()),
        ("paramId", param_id.to_string()),
        ("uuid", uuid.to_string()),
        ("encryuuid", encryuuid.to_string()),
    ]
}

/// 这家是不是天翼（给 `pan_login::qr_login_poll` 分流用，理由见文件头"集成注意"）
pub fn is_tianyi_login(kind: PanKind) -> bool {
    matches!(kind, PanKind::Tianyi)
}

// ═══════════════════════════════════════════════════════════════════════
//  本文件自备的小工具（与 `pan_login` 的同名私有函数**必须是两份**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不 `use crate::pan_login::client`
// ```text
// 那边是 `fn client`（私有，不是 `pub(crate)`），而本次协作的纪律是
// **只许改本文件** ⇒ 不能给它加可见性，只能自备。
// 这在本仓不是新做法：`pan_login_device.rs:298-419` 与 `pan_login.rs:197-248`
// 就是各自一份（同样的理由）。
// ```

/// 单次 HTTP 的预算（登录接口都很快；卡住说明网络问题，早失败早提示）
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

/// 建 HTTP 客户端（**跟随**重定向 —— 只给"取昵称"那一跳用）
///
/// ⚠️ 与 `pan_login::client` 同一条纪律：reqwest **默认读环境代理**，
/// 而用户机器上的代理会把"接口可用"测成"全失败"。登录接口尤其不能走代理
/// （189 的 logbox 对出口 IP 敏感）。
///
/// ★ 为什么重定向链那一步**不**用它：reqwest 跟随重定向后只看得到最后一跳的响应头，
///   中间几跳的 `Set-Cookie` 会被丢掉（本仓没开 `cookie_store`，也不能改 Cargo.toml）
///   ⇒ 回调那跳自己走跳数（[`follow_get_collecting_cookies`]）。
///   而"取昵称"没有这个需求（它就是一个普通 GET，跟随到位才拿得到 JSON）。
fn client(ua: &str) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent(ua)
        .timeout(HTTP_TIMEOUT)
        .no_proxy()
        .build()
        .map_err(|e| format!("建 HTTP 客户端失败：{e}"))
}

/// 建**不跟随**重定向的客户端 —— 第 ① 跳专用
///
/// # ★★★ 这一个 `.redirect(Policy::none())` 是整个天翼登录的成败点
/// ```text
/// 参考实现是 `OkHttpClient.newBuilder().followRedirects(false).followSSLRedirects(false)`
/// （§4.1-C 下方 ★ 注，`merge.k.b.b` insns=129）。
/// 若用 reqwest 的默认（跟随）：请求会一路跳到 https://cloud.189.cn/web/login.html，
/// 拿到的是登录页 **HTML**，`Location` 头根本不存在（早被消费掉）
/// ⇒ `lt`/`reqId` 取不到 ⇒ ②③ 全 401，而且**不会报错**（HTTP 200 一路到底）。
/// ⇒ 这就是"看着对、实际静默失败"的典型：必须显式关掉，且拿不到 Location 时**大声报错**
///   （错误文案里点名"重定向被跟随了"，见 [`tianyi_start`]）。
/// ```
fn client_no_redirect(ua: &str) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent(ua)
        .timeout(HTTP_TIMEOUT)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|e| format!("建 HTTP 客户端（不跟随重定向）失败：{e}"))
}

/// 当前时刻（Unix 秒）
fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 当前时刻（Unix 毫秒）—— 轮询表单的 `timeStamp`
fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 轮询表单的 `date`（`yyyy-MM-dd HH:mm:ss.SSS`，本地时区）
///
/// 与 dex 的 `new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS")` 同形（本地时区、毫秒 3 位）。
fn now_date_string() -> String {
    chrono::Local::now()
        .format("%Y-%m-%d %H:%M:%S%.3f")
        .to_string()
}

/// 摘要一行响应（报错时给用户看，不要甩整页 HTML）
fn tail(s: &str) -> String {
    let t = s.trim();
    let cut = t.char_indices().nth(200).map(|(i, _)| i).unwrap_or(t.len());
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

// ═══════════════════════════════════════════════════════════════════════
//  落盘日志（现场可读性的前提；机制与 `pan_login` 同一份纪律）
// ═══════════════════════════════════════════════════════════════════════

/// 日志 tag：与 `pan_login` **同一个** `[PAN]`（现场一句 `grep '\[PAN\]'` 能捞全）
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
/// ★ cookie 是登录凭据，与 `pan_login::cookie_digest` 同一条硬规矩：绝不进日志。
fn cookie_digest(cookie: &str) -> String {
    let keys: Vec<&str> = cookie
        .split(';')
        .filter_map(|p| p.split('=').next())
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    format!(
        "{} 个键（{} 字节）: {}",
        keys.len(),
        cookie.len(),
        keys.join(",")
    )
}

/// 收集响应里**全部** `Set-Cookie`（按 "; " 拼成一个 Cookie 头值）
///
/// ★ 与 `pan_login::collect_set_cookie` 同源同理由：网盘登录会下发多条 cookie，
///   只留第一条 ⇒ 后续接口缺 cookie ⇒ 表现为"登录了但拉不到列表"（很难查）。
fn collect_set_cookie(resp: &reqwest::Response) -> String {
    let mut parts: Vec<String> = Vec::new();
    for v in resp.headers().get_all(reqwest::header::SET_COOKIE).iter() {
        let Ok(s) = v.to_str() else { continue };
        if let Some(kv) = s.split(';').next() {
            let kv = kv.trim();
            if !kv.is_empty() {
                parts.push(kv.to_string());
            }
        }
    }
    parts.join("; ")
}

/// 把两段 cookie 合并（**同名键后者覆盖前者**，保持首次出现的顺序）
///
/// # 为什么需要它（而不是直接字符串拼接）
/// ```text
/// 回调那跳是一条**重定向链**，每一跳都可能 Set-Cookie：
///   第1跳 → `COOKIE_LOGIN_USER=…`
///   第2跳 → `JSESSIONID=…`（并且可能**刷新**上一跳的同名键）
/// 直接 `a; b` 拼会出现两个同名键（`JSESSIONID=x; JSESSIONID=y`）——
/// 服务端取第一个 ⇒ 用的是**旧值** ⇒ "扫码成功了但一访问就未登录"。
/// ⇒ 按 key 覆盖合并。
/// ```
fn merge_cookie_pairs(base: &str, extra: &str) -> String {
    let mut pairs: Vec<(String, String)> = Vec::new();
    for seg in base.split(';').chain(extra.split(';')) {
        let seg = seg.trim();
        if seg.is_empty() {
            continue;
        }
        let (k, v) = match seg.split_once('=') {
            Some((k, v)) => (k.trim().to_string(), v.trim().to_string()),
            None => (seg.to_string(), String::new()),
        };
        if k.is_empty() {
            continue;
        }
        match pairs.iter_mut().find(|(pk, _)| *pk == k) {
            Some(slot) => slot.1 = v, // 后到的覆盖前到的
            None => pairs.push((k, v)),
        }
    }
    pairs
        .into_iter()
        .map(|(k, v)| {
            if v.is_empty() {
                k
            } else {
                format!("{k}={v}")
            }
        })
        .collect::<Vec<_>>()
        .join("; ")
}

// ═══════════════════════════════════════════════════════════════════════
//  解码 / 解析（**全是纯函数**，离线可断言）
// ═══════════════════════════════════════════════════════════════════════

/// 十六进制字符 → 数值
fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// `URLDecoder.decode(s, "UTF-8")` 的等价物（**自己写，不引依赖**）
///
/// # 两条规则都必须对（dex 用的就是 Java 的 URLDecoder）
/// ```text
/// ① `%XX` → 一个字节（大小写十六进制都认）；字符集是 **UTF-8**
///    ⇒ 一个中文字是 3 个 `%XX`，必须**先按字节拼**再整体做 UTF-8 解码；
///      若按"每个 %XX 转成一个 char"来写，`%E4%B8%AD` 会变成三个乱码字符。
/// ② `+` → 空格（这是 form-urlencoded 的规则，Java 的 URLDecoder 就是这么做的）
///    ⚠️ 这条**不是可选**：`encodeuuid` 是服务端用 form 编码给的，
///      二维码内容里若真有空格，它一定以 `+` 形式出现。
/// ③ 不完整的 `%`（`%4`、末尾 `%`）→ **原样保留**，不 panic、不丢字符。
/// ```
fn url_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => match (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                (Some(h), Some(l)) => {
                    out.push((h << 4) | l);
                    i += 3;
                }
                _ => {
                    out.push(b'%');
                    i += 1;
                }
            },
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    // UTF-8 非法（服务端给了坏字节）⇒ 用有损转换，**不丢整条 URL**
    // （丢整条 = 用户看到一个空二维码，比"有几个替换字符"更难查）
    String::from_utf8(out)
        .unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

/// 取 query 里的某个参数（`key=value` 形式；`?` 与 `&` 分隔，`#` 截断）
///
/// ★ 第 ① 跳的 `lt`/`reqId` 就靠它从 `Location` 里抠出来。
///   参考实现用的是正则 `lt=(\d+)` / `reqId=([\w]+)`（§4.1-C 注），
///   这里改成**按参数解析**：不把"值必须全数字/全字母"这个偶然性质写进实现
///   （真机要是给了带 `-` 的 reqId，正则版会静默取到空）。
fn query_param(s: &str, key: &str) -> Option<String> {
    let q = match s.split_once('?') {
        Some((_, rest)) => rest,
        None => s,
    };
    for part in q.split(|c| c == '&' || c == '#') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        let (k, v) = match part.split_once('=') {
            Some(kv) => kv,
            None => continue,
        };
        if k.trim() == key {
            let v = v.trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

/// 从响应体里取一个字段（**容错扫描**，不要求整条是合法 JSON）
///
/// # 为什么不用 `serde_json::from_str`
/// ```text
/// 取证里四个字段全是用**正则**取的（`"reqId":"(.+?)"`、`"status":(.+?),`、
/// `"encodeuuid":"(.+?)"`）—— 那说明参考实现自己都不敢假设这四跳是纯 JSON
/// （logbox 的响应历史上混过 HTML 片段/多余逗号）。
/// ⇒ 这里做同一件事：找到 `"key"` 后面跟 `:`，再按"带引号 / 裸值"取。
///   比 `from_str` 宽容，但**缺失时仍然返回 None**（由调用方报 Err，绝不猜默认值）。
/// ```
fn json_field(body: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\"");
    let mut from = 0usize;
    while let Some(pos) = body[from..].find(&pat) {
        let after = from + pos + pat.len();
        let rest = body[after..].trim_start();
        if let Some(r) = rest.strip_prefix(':') {
            let r = r.trim_start();
            if let Some(r) = r.strip_prefix('"') {
                // 带引号：到下一个引号为止
                return r.find('"').map(|end| r[..end].to_string());
            }
            // 裸值（数字 / true / false）：到 , } ] 或换行为止
            let end = r
                .find(|c: char| c == ',' || c == '}' || c == ']' || c == '\n' || c == '\r')
                .unwrap_or(r.len());
            let v = r[..end].trim();
            if v.is_empty() {
                return None;
            }
            return Some(v.to_string());
        }
        from = after;
    }
    None
}

/// 取**必需**字段：缺失与"空串"都报可读 Err（带响应摘要）
///
/// ★ 反空真：`Some("")` 与 `None` 是两件事 —— 空串冒充"找到了"会让后续请求
///   带一个空 `paramId` 出去，服务端回 200 + status 非 0，看起来像"用户还没扫"。
fn required_field(body: &str, key: &str, step: &str) -> Result<String, String> {
    match json_field(body, key).map(|s| s.trim().to_string()) {
        Some(v) if !v.is_empty() => Ok(v),
        Some(_) => Err(format!(
            "天翼 {step} 响应里的 {key} 是**空串**（协议可能变了）：{}",
            tail(body)
        )),
        None => Err(format!(
            "天翼 {step} 响应里没有 {key}（协议可能变了）：{}",
            tail(body)
        )),
    }
}

/// 业务码检查：`"result":(.+?),` 必须等于 `0`（§4.1-C 的"判定"行）
///
/// # ★ 为什么"缺 result"**不**算失败（与其它必需字段不同）
/// ```text
/// dex 只在 `l.k()` 的判定行上取了一次 result，而三跳是两个不同端点。
/// 取证**没有**说"每一跳都带 result" ⇒ 缺这个字段时不下结论（继续），
/// 但**有非 0 值就一定是失败**（那是逐字证据：`.equals("0")`）。
/// ⇒ 这是"证据支持到什么程度就做到什么程度"：多报一个失败会打断一次本来能成的登录。
/// ```
fn check_result(body: &str, step: &str) -> Result<(), String> {
    match json_field(body, "result") {
        Some(r) if r.trim() != "0" => {
            let msg = json_field(body, "msg").unwrap_or_default();
            let hint = if msg.trim().is_empty() {
                String::new()
            } else {
                format!("，msg={}", msg.trim())
            };
            Err(format!(
                "天翼 {step} 业务失败（result={}{hint}）：{}",
                r.trim(),
                tail(body)
            ))
        }
        _ => Ok(()),
    }
}

/// 第 ① 跳的产出：`lt` / `reqId`（都在 `Location` 里）
#[derive(Debug, Clone, PartialEq, Eq)]
struct LoginLocation {
    lt: String,
    req_id: String,
}

/// 从 `Location` 头里解析 `lt` / `reqId`（**纯函数**）
///
/// ★ 传空串 = "没拿到 Location 头" ⇒ 报的错要**点名重定向**，
///   因为那是这条链路上最容易犯、且最不报错的错（见 [`client_no_redirect`]）。
fn login_location_params(location: &str) -> Result<LoginLocation, String> {
    // `&amp;` 兜底：HTTP 头里正常不会出现，但解析器换成 HTML 转义串时就会（便宜且无害）
    let loc = location.replace("&amp;", "&");
    if loc.trim().is_empty() {
        return Err(
            "天翼 loginUrl.action 没有返回 Location 头 ⇒ 拿不到 lt/reqId。\
             ★ 这条几乎总是意味着**重定向被跟随了**：reqwest 默认会跟，跟完拿到的是\
             登录页 HTML，而 lt/reqId 只在 302 的 Location 里 ⇒ 后续请求全 401 且不报错。"
                .to_string(),
        );
    }
    let lt = query_param(&loc, "lt");
    let req_id = query_param(&loc, "reqId");
    match (lt, req_id) {
        (Some(lt), Some(req_id)) => Ok(LoginLocation { lt, req_id }),
        (None, _) => Err(format!(
            "天翼 Location 里没有 lt 参数（协议可能变了）：{}",
            tail(&loc)
        )),
        (_, None) => Err(format!(
            "天翼 Location 里没有 reqId 参数（协议可能变了）：{}",
            tail(&loc)
        )),
    }
}

/// 第 ② 跳的产出：`reqId`（写进 `l.c`，后面当轮询的 `reqid` 头）+ `paramId`
#[derive(Debug, Clone, PartialEq, Eq)]
struct AppConf {
    req_id: String,
    param_id: String,
}

fn appconf_params(body: &str) -> Result<AppConf, String> {
    Ok(AppConf {
        req_id: required_field(body, "reqId", "appConf.do")?,
        param_id: required_field(body, "paramId", "appConf.do")?,
    })
}

/// 第 ③ 跳的产出：`uuid` / `encryuuid` / `encodeuuid`（原样，未解码）
#[derive(Debug, Clone, PartialEq, Eq)]
struct UuidInfo {
    uuid: String,
    encryuuid: String,
    /// ⚠️ **未解码**的原始值；二维码内容要过 [`url_decode`]
    encodeuuid: String,
}

fn getuuid_params(body: &str) -> Result<UuidInfo, String> {
    Ok(UuidInfo {
        uuid: required_field(body, "uuid", "getUUID.do")?,
        encryuuid: required_field(body, "encryuuid", "getUUID.do")?,
        encodeuuid: required_field(body, "encodeuuid", "getUUID.do")?,
    })
}

/// 二维码内容 = `URLDecoder.decode(encodeuuid, "UTF-8")`（§4.1-B，逐字证据）
///
/// ★ 这是"能不能出码"的关键那一步：别人都是"服务端给 QR"，天翼是**本机解码**。
///   解码错的表现是：二维码能画出来、能扫、扫完 App 说"无效的二维码"。
fn qr_content_of(encodeuuid: &str) -> String {
    url_decode(encodeuuid)
}

/// 第 ④ 步的判定结果
#[derive(Debug, Clone, PartialEq, Eq)]
enum PollVerdict {
    /// **唯一**的"可以拿凭据"分支：`status == 0 && redirectUrl` 非空
    Confirmed(String),
    /// 其余一律继续等（★ 推断：dex 没有 status 非 0 的语义映射）
    Wait {
        status: i64,
        /// 用于日志：0 但没 redirectUrl 是"异常形状"，不是"用户已确认"
        redirect_present: bool,
    },
}

/// 轮询响应的判定（**纯函数**，可离线断言）
///
/// # 判定顺序（顺序本身就是纪律，见 §4.1-D 0x0095/0x00ab）
/// ```text
/// ① 没有 status 字段 / 不是整数 ⇒ Err（协议变了，带摘要）
/// ② status == 0 **且** redirectUrl 非空 ⇒ Confirmed(redirectUrl)   ← 唯一成功分支
/// ③ status == 0 但 redirectUrl 空/缺 ⇒ Wait（**不许**当成功：
///    没有 redirectUrl 就没有那跳回调，也就不会有 cookie ⇒ "登录成功但没有凭据"）
/// ④ status != 0 ⇒ Wait（★ 推断：dex 只确证 ==0 是成功；待扫/已扫/过期无映射）
/// ```
fn tianyi_poll_verdict(body: &str) -> Result<PollVerdict, String> {
    let raw = json_field(body, "status")
        .ok_or_else(|| format!("天翼轮询响应里没有 status 字段（协议可能变了）：{}", tail(body)))?;
    let status: i64 = raw.trim().parse().map_err(|_| {
        format!(
            "天翼轮询响应的 status 不是整数（读到 {:?}）：{}",
            raw.trim(),
            tail(body)
        )
    })?;
    let redirect = json_field(body, "redirectUrl")
        .unwrap_or_default()
        .trim()
        .to_string();
    if status == 0 && !redirect.is_empty() {
        Ok(PollVerdict::Confirmed(redirect))
    } else {
        Ok(PollVerdict::Wait {
            status,
            redirect_present: !redirect.is_empty(),
        })
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  重定向链（回调那跳要"跟随"，且逐跳收 Set-Cookie）
// ═══════════════════════════════════════════════════════════════════════

/// 最多走几跳（防御：服务端要是给了环，不能把我们转死）
const MAX_REDIRECT_HOPS: usize = 8;

/// 这个状态码是不是重定向
fn is_redirect_status(code: u16) -> bool {
    (300..400).contains(&code)
}

/// 解析 `Location` 的跳转目标（**纯函数**：绝对 / 协议相对 / 站点相对 / 路径相对）
///
/// # 为什么必须自己解析
/// ```text
/// reqwest 跟随重定向时会自己算，但我们是**手动**走跳数（理由见
/// [`follow_get_collecting_cookies`]），所以这一步得自己做。
/// 相对路径少写一条 case 的后果：GET 到 `/web/redirect.html` 这种**非绝对 URL**，
/// reqwest 直接报 builder 错 ⇒ 一次成功扫码变成"登录失败"。
/// ```
fn resolve_location(base: &str, loc: &str) -> String {
    let loc = loc.trim();
    if loc.starts_with("http://") || loc.starts_with("https://") {
        return loc.to_string();
    }
    let scheme = if base.starts_with("https://") {
        "https"
    } else {
        "http"
    };
    // 协议相对：`//host/path`
    if let Some(rest) = loc.strip_prefix("//") {
        return format!("{scheme}://{rest}");
    }
    // 站点相对：`/path`
    if loc.starts_with('/') {
        let host = base
            .split_once("://")
            .map(|(_, r)| r.split('/').next().unwrap_or(""))
            .unwrap_or("");
        return format!("{scheme}://{host}{loc}");
    }
    // 路径相对：拼到 base 的最后一个 '/' 之后
    match base.rfind('/') {
        Some(i) if i > scheme.len() + 2 => format!("{}{}", &base[..=i], loc),
        _ => format!("{scheme}://{loc}"),
    }
}

/// 跟随重定向并**逐跳**收集 `Set-Cookie` 的结果
struct Followed {
    /// 合并后的 cookie（可能为空 —— 由调用方判"拿不到登录态"）
    cookie: String,
    /// 最后一跳的实际 URL（现场排查用）
    final_url: String,
    /// 最后一跳的 HTTP 码
    status: u16,
}

/// GET 一个 URL 并**跟随**重定向，每一跳都把 `Set-Cookie` 收进同一个 cookie 串
///
/// # ★ 为什么不用 reqwest 的默认跟随（也不开 `cookie_store`）
/// ```text
/// ① 本仓 Cargo.toml 没开 `cookie_store`（本次协作**不许改** Cargo.toml）
///    ⇒ 让 reqwest 内部跟随，我们只看得到**最后一跳**的响应头，
///      前面几跳的 Set-Cookie 会被直接丢掉 ⇒ "扫码确认了，但登录态只有一半"。
/// ② 天翼的回调（callbackUnify.action）就是这种多跳形状：登录态 cookie 在**第一跳**下发，
///    后面几跳往里补/刷。
/// ⇒ 只能用**不跟随**的 client 手动走，每跳自己收（与被禁用的 Policy 组合起来正好）。
/// ```
async fn follow_get_collecting_cookies(
    c: &reqwest::Client,
    start: &str,
    referer: &str,
    initial_cookie: &str,
) -> Result<Followed, String> {
    let mut cookie = initial_cookie.trim().to_string();
    let mut url = start.trim().to_string();
    if url.is_empty() {
        return Err("天翼回调 URL 为空 —— 拿不到登录态".to_string());
    }

    for _hop in 0..=MAX_REDIRECT_HOPS {
        let mut req = c.get(&url).header("Referer", referer);
        if !cookie.is_empty() {
            req = req.header("Cookie", cookie.clone());
        }
        let resp = req
            .send()
            .await
            .map_err(|e| format!("请求天翼回调地址失败（{url}）：{e}"))?;
        let status = resp.status().as_u16();
        cookie = merge_cookie_pairs(&cookie, &collect_set_cookie(&resp));

        // 只有 3xx 才继续走；其余（含 200/4xx）都是终点
        if !is_redirect_status(status) {
            return Ok(Followed {
                cookie,
                final_url: url,
                status,
            });
        }
        let next = resp
            .headers()
            .get(reqwest::header::LOCATION)
            .and_then(|v| v.to_str().ok())
            .map(|s| resolve_location(&url, s))
            .unwrap_or_default();
        if next.is_empty() {
            // 3xx 但没有 Location ⇒ 到头了（如实把当前 cookie 交回去，由调用方判空）
            return Ok(Followed {
                cookie,
                final_url: url,
                status,
            });
        }
        url = next;
    }

    Err(format!(
        "天翼回调重定向超过 {MAX_REDIRECT_HOPS} 跳（疑似环）：起点 {start}"
    ))
}

// ═══════════════════════════════════════════════════════════════════════
//  会话表（**本文件私有**，不碰 `pan_login::SESSIONS`）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须自己一张表
// ```text
// 纪律：不许改 `pan_login`（那是 Lead 的文件）⇒ 它的 `SESSIONS` 是私有的、也进不去。
// 而且天翼的会话里要存的中间件比别家多（lt / reqId / paramId / uuid / encryuuid），
// 塞进那边只存 `token` 一个字段的表里装不下。
// ```

/// `key`（= `uuid`）→ 进行中的扫码会话
static SESSIONS: OnceLock<Mutex<HashMap<String, TianyiSession>>> = OnceLock::new();

struct TianyiSession {
    /// 第 ② 跳的 `reqId`（`l.c`；轮询的 `reqid` 头用它）
    ///
    /// ★ 为什么只存这一个 reqId：出码时有两个 reqId ——
    ///   ① 跳 `Location` 里那个只给 ②③ 两跳当请求头用，**轮询用不到**；
    ///   ② 跳返回的这个（dex 的 `l.c`）才是轮询要带回去的。
    ///   两个都存进表里会让"哪个在用"变成靠猜（而 ① 那个进了表就永远不会被读）。
    req_id: String,
    /// 第 ② 跳的 `paramId`（轮询表单）
    param_id: String,
    /// 第 ③ 跳的 `uuid`（轮询表单；也是本会话的 key）
    uuid: String,
    /// 第 ③ 跳的 `encryuuid`（轮询表单）
    encryuuid: String,
    /// 发起时刻（本地 TTL 判定）
    created_at: i64,
}

fn sessions() -> &'static Mutex<HashMap<String, TianyiSession>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 会话有效期：超过它就让用户重新 start
///
/// ★ 天翼的二维码有效期**没有取证**（§4.2：有 `date`/`timeStamp` 但无 TTL 常量；
///   `expiresIn` 只用于 token）⇒ 沿用本仓其它家的 5 分钟本地兜底。
///   （`pan_login::SESSION_TTL_SECS` 是私有的 ⇒ 这里必须再写一份，值保持相同。）
const SESSION_TTL_SECS: i64 = 300;

fn kind_key(kind: PanKind, key: &str) -> String {
    format!("{}:{}", kind.code(), key)
}

/// 看一眼会话还在不在（在 ⇒ 回一份快照）
///
/// ★ 为什么是 `get` 而不是 `remove`：**轮询要能被重复调用**。
///   写成 `remove` 的后果是"一次 Pending 之后会话就没了 ⇒ 第二次轮询报『会话不在』
///   ⇒ 用户永远看不到自己确认后的结果"（`pan_login_device.rs:470` 记了同一个坑）。
/// ⇒ 只有过期项和"已产出凭据"的项才删。
fn peek_session(key: &str) -> Option<TianyiSession> {
    let mut map = sessions().lock().unwrap_or_else(|e| e.into_inner());
    let k = kind_key(PanKind::Tianyi, key);
    let expired = matches!(map.get(&k), Some(rec) if now() - rec.created_at > SESSION_TTL_SECS);
    if expired {
        map.remove(&k);
        return None;
    }
    map.get(&k).map(|rec| TianyiSession {
        req_id: rec.req_id.clone(),
        param_id: rec.param_id.clone(),
        uuid: rec.uuid.clone(),
        encryuuid: rec.encryuuid.clone(),
        created_at: rec.created_at,
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  出码：① → ② → ③ → 本地解出二维码内容
// ═══════════════════════════════════════════════════════════════════════

/// 天翼：准备会话并出码
///
/// # 三跳的失败模式（每一跳都单独报清，别让用户看到"登录失败"四个字）
/// ```text
/// ① 拿不到 Location      ⇒ 报"重定向被跟随了"（几乎必然是配置错，不是网络错）
/// ① 拿不到 lt/reqId      ⇒ 报 Location 摘要（协议变了）
/// ②③ HTTP 非 2xx         ⇒ 报 HTTP 码 + 响应摘要
/// ②③ result 非 0         ⇒ 报 result + msg
/// ②③ 缺 reqId/paramId/…  ⇒ 报缺哪个字段 + 响应摘要
/// ```
pub async fn tianyi_start() -> Result<QrSession, String> {
    let c = client_no_redirect(UA_TIANYI)?;

    // ── ① 准备扫码会话：GET，**必须关闭重定向**，lt/reqId 只在 Location 里 ──
    let resp = c
        .get(tianyi_login_url())
        .header(
            "Accept",
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        )
        .header("Referer", REFERER_LOGIN)
        .send()
        .await
        .map_err(|e| format!("请求天翼 loginUrl.action 失败：{e}"))?;

    let http = resp.status();
    // ★ 先取 Location 再消费 body（headers 的借用要在 text() 之前结束）
    let location = resp
        .headers()
        .get(reqwest::header::LOCATION)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let body = resp.text().await.unwrap_or_default();

    if http.is_client_error() || http.is_server_error() {
        write_log(&format!(
            "天翼出码失败 step=loginUrl HTTP {http} body={}",
            tail(&body)
        ));
        return Err(format!(
            "天翼 loginUrl.action 返回 HTTP {http}：{}",
            tail(&body)
        ));
    }
    let LoginLocation { lt, req_id } = login_location_params(&location).map_err(|e| {
        // ★ 现场最需要看的就是这一条：Location 到底有没有、HTTP 是多少
        write_log(&format!(
            "天翼出码失败 step=loginUrl HTTP {http} location_len={} body={}",
            location.len(),
            tail(&body)
        ));
        format!("{e}（HTTP {http}，Location 长度 {}）", location.len())
    })?;
    write_log(&format!(
        "天翼出码 step=loginUrl HTTP {http} lt_len={} reqId_len={}",
        lt.len(),
        req_id.len()
    ));

    // ── ② appConf.do：拿 reqId（l.c）与 paramId（l.d） ──
    let resp = c
        .post(tianyi_appconf_url())
        .header("Referer", REFERER_LOGIN) // 推断待确认 ④
        .header("lt", lt.clone())
        .header("reqId", req_id.clone())
        .form(&tianyi_appconf_form())
        .send()
        .await
        .map_err(|e| format!("请求天翼 appConf.do 失败：{e}"))?;
    let http = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读天翼 appConf.do 响应失败：{e}"))?;
    if !http.is_success() {
        write_log(&format!(
            "天翼出码失败 step=appConf HTTP {http} body={}",
            tail(&body)
        ));
        return Err(format!("天翼 appConf.do 返回 HTTP {http}：{}", tail(&body)));
    }
    check_result(&body, "appConf.do")?;
    let conf = appconf_params(&body)?;
    write_log(&format!(
        "天翼出码 step=appConf HTTP {http} reqId_len={} paramId_len={}",
        conf.req_id.len(),
        conf.param_id.len()
    ));

    // ── ③ getUUID.do：同参同头，拿 uuid / encryuuid / encodeuuid ──
    let resp = c
        .post(tianyi_getuuid_url())
        .header("Referer", REFERER_LOGIN) // 推断待确认 ④
        .header("lt", lt.clone())
        .header("reqId", req_id.clone())
        .form(&tianyi_appconf_form())
        .send()
        .await
        .map_err(|e| format!("请求天翼 getUUID.do 失败：{e}"))?;
    let http = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读天翼 getUUID.do 响应失败：{e}"))?;
    if !http.is_success() {
        write_log(&format!(
            "天翼出码失败 step=getUUID HTTP {http} body={}",
            tail(&body)
        ));
        return Err(format!("天翼 getUUID.do 返回 HTTP {http}：{}", tail(&body)));
    }
    check_result(&body, "getUUID.do")?;
    let info = getuuid_params(&body)?;

    // ── 二维码内容 = URLDecoder.decode(encodeuuid, "UTF-8")（§4.1-B）──
    let qr = qr_content_of(&info.encodeuuid);
    if qr.trim().is_empty() {
        // 理论上 required_field 已经挡了空 encodeuuid；这里是"解码后变空"的兜底
        // （例如 encodeuuid 全是非法百分号序列）——空二维码比报错更难查
        return Err(format!(
            "天翼 getUUID.do 的 encodeuuid 解码后为空（原值 {} 字节）：{}",
            info.encodeuuid.len(),
            tail(&body)
        ));
    }
    let svg = crate::remote::qr_svg_for(&qr).unwrap_or_default();

    let created_at = now();
    write_log(&format!(
        "天翼出码成功 kind={} uuid_len={} encryuuid_len={} encodeuuid_len={} qr_len={} svg_len={}",
        PanKind::Tianyi.code(),
        info.uuid.len(),
        info.encryuuid.len(),
        info.encodeuuid.len(),
        qr.len(),
        svg.len()
    ));

    // 会话 key = `uuid`（它就是这次码的身份；轮询表单要原样带回去）
    sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(
            kind_key(PanKind::Tianyi, &info.uuid),
            TianyiSession {
                req_id: conf.req_id,
                param_id: conf.param_id,
                uuid: info.uuid.clone(),
                encryuuid: info.encryuuid,
                created_at,
            },
        );

    Ok(QrSession {
        key: info.uuid,
        url: qr,
        svg,
        // ★ 提示要与别家区分：天翼的码只能用**天翼云盘 App**扫（用浏览器扫没有登录态）
        hint: "用天翼云盘 App 扫这个码（浏览器扫码不会登录）".to_string(),
        created_at,
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  轮询 + 换登录态：④ → ⑤
// ═══════════════════════════════════════════════════════════════════════

/// 天翼：轮询一次；确认后走回调拿 cookie 并产出凭据
///
/// # 两条纪律
/// ```text
/// ① **未确认一律 Pending**：只有 `status == 0 && redirectUrl 非空` 才往下走；
///    其余（含 status 非 0）全是 Pending —— dex 没有那些值的语义映射（推断待确认 ②）。
/// ② 失败/缺字段/HTTP 非 2xx ⇒ 可读 Err（带 HTTP 码 + 响应摘要）。
/// ```
pub async fn tianyi_poll(key: &str) -> Result<PollOutcome, String> {
    let key = key.trim();
    if key.is_empty() {
        return Err("天翼扫码会话 key 为空 —— 请重新获取二维码".to_string());
    }

    // 会话检查（本地，先于任何网络请求 —— 否则一个不存在的 key 也会打一次服务端）
    let Some(sess) = peek_session(key) else {
        write_log(&format!(
            "轮询 kind=tianyi 会话不在或已超时 key_len={}",
            key.len()
        ));
        return Ok(PollOutcome {
            status: QrStatus::Expired,
            message: "这个二维码已失效（会话不在或已超时），请重新获取".to_string(),
            credential: None,
        });
    };

    // ── ④ qrcodeLoginState.do（11 个表单参数，逐字见 [`tianyi_poll_form`]）──
    let c = client_no_redirect(UA_TIANYI)?;
    let form = tianyi_poll_form(
        &sess.param_id,
        &sess.uuid,
        &sess.encryuuid,
        &now_date_string(),
        now_millis(),
    );
    let resp = c
        .post(tianyi_poll_url())
        .header("Referer", REFERER_LOGBOX)
        .header("reqid", sess.req_id.clone())
        .form(&form)
        .send()
        .await
        .map_err(|e| format!("轮询天翼扫码状态失败：{e}"))?;
    let http = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读天翼轮询响应失败：{e}"))?;
    if !http.is_success() {
        write_log(&format!(
            "轮询 kind=tianyi HTTP {http} body={}",
            tail(&body)
        ));
        return Err(format!(
            "天翼 qrcodeLoginState.do 返回 HTTP {http}：{}",
            tail(&body)
        ));
    }

    let verdict = tianyi_poll_verdict(&body).map_err(|e| {
        write_log(&format!("轮询 kind=tianyi 判据失败 err={e}"));
        e
    })?;
    write_log(&format!(
        "轮询 kind=tianyi HTTP {http} verdict={} body={}",
        match &verdict {
            PollVerdict::Confirmed(_) => "confirmed",
            PollVerdict::Wait { .. } => "wait",
        },
        tail(&body)
    ));

    let redirect_url = match verdict {
        PollVerdict::Wait {
            status,
            redirect_present,
        } => {
            // ★ 未确认一律 Pending（把 status 写进 message：现场能一眼看出服务端到底在说什么）
            return Ok(PollOutcome {
                status: QrStatus::Pending,
                message: if status == 0 && !redirect_present {
                    // 异常形状：dex 里 0 必定带 redirectUrl ⇒ 如实写出来，别装成"正常等待"
                    "等待扫码…（服务端 status=0 但没给 redirectUrl，待真机确认）".to_string()
                } else {
                    format!("等待扫码…（status={status}）")
                },
                credential: None,
            });
        }
        PollVerdict::Confirmed(u) => u,
    };

    // ── ⑤ GET redirectUrl（**跟随**，逐跳收 Set-Cookie）⇒ 登录态 cookie ──
    //   ★ 与第 ① 跳正好相反：那一跳不许跟（要 Location），这一跳必须跟（要 cookie）。
    let followed =
        follow_get_collecting_cookies(&c, &redirect_url, REFERER_LOGIN, "").await.map_err(|e| {
            write_log(&format!("天翼回调失败 kind=tianyi err={e}"));
            e
        })?;
    if followed.cookie.trim().is_empty() {
        write_log(&format!(
            "天翼回调没有 Set-Cookie kind=tianyi HTTP {} final={}",
            followed.status, followed.final_url
        ));
        return Err(format!(
            "天翼已确认扫码，但回调链里没有任何 Set-Cookie（HTTP {}，终点 {}）\
             ⇒ 拿不到登录态（协议可能变了）",
            followed.status, followed.final_url
        ));
    }
    write_log(&format!(
        "天翼回调成功 kind=tianyi HTTP {} hops_final={} cookie={}",
        followed.status,
        followed.final_url,
        cookie_digest(&followed.cookie)
    ));

    // 昵称（**纯显示用**：取不到就用盘名，绝不影响登录结果）
    let cookie = followed.cookie;
    let account = match client(UA_TIANYI) {
        Ok(cn) => match tianyi_nickname(&cn, &cookie).await {
            Some(n) => n,
            None => "天翼云盘".to_string(),
        },
        Err(e) => {
            // 连客户端都建不起来 ⇒ 只是显示名拿不到，登录结果照旧
            write_log(&format!("天翼取昵称跳过（建客户端失败：{e}）"));
            "天翼云盘".to_string()
        }
    };

    // TODO（本轮不做，见文件头）：`getAccessTokenBySsKey.action?sessionKey=<sk>`
    //   头 `appkey:600100422` / `timestamp` / `sign-type:1` / `Cookie`，
    //   待签串 `AppKey=600100422&Timestamp=<ts>&sessionKey=<sk>` + `signature`。
    //   ★ **签名算法未取证**（§8 自评表标"中"）⇒ 不猜、不编。
    //   真机补齐算法后在这里接：拿到 accessToken 再写成
    //   `access_token=<…>; expiresIn=<…>` 的 token 型凭据（那时 cookie 也一起留着）。

    // 会话用完即弃（凭据已拿到；再轮询同一 key 会再走一次回调）
    sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&kind_key(PanKind::Tianyi, key));

    Ok(PollOutcome {
        status: QrStatus::Confirmed,
        message: format!("登录成功：{account}"),
        credential: Some(PanCredential {
            kind: PanKind::Tianyi,
            account,
            cookie,
            saved_at: now(),
            // 天翼 cookie 的有效期未取证 ⇒ 如实留 None（不编一个"30 天"）
            expires_at: None,
        }),
    })
}

/// 取显示名（`getUserBriefInfo.action` 的 `nickname`，退回 `userAccount`）
///
/// ★ 失败一律 `None`：**登录结果是靠 cookie 判的，不是靠这个接口**。
///   为了一个显示名把整次登录判失败，是"过度依赖非关键路径"的典型错误。
async fn tianyi_nickname(c: &reqwest::Client, cookie: &str) -> Option<String> {
    let resp = c
        .get(tianyi_userinfo_url())
        .header("Referer", "https://cloud.189.cn/") // 推断待确认 ⑥
        .header("Cookie", cookie) // 推断待确认 ⑥：鉴权方式未逐字取证
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        write_log(&format!(
            "天翼取昵称失败 HTTP {}（不影响登录）",
            resp.status()
        ));
        return None;
    }
    let body = resp.text().await.ok()?;
    for k in ["nickname", "userAccount"] {
        if let Some(v) = json_field(&body, k) {
            let v = v.trim().to_string();
            if !v.is_empty() {
                return Some(v);
            }
        }
    }
    write_log(&format!(
        "天翼取昵称：响应里没有 nickname/userAccount（不影响登录）body={}",
        tail(&body)
    ));
    None
}

// ═══════════════════════════════════════════════════════════════════════
//  门禁（每条都钉住一个"写错不报错、只静默跑偏"的值；注入方式写在各自的注释里）
//  ★ 本轮**实跑**了两条注入（`clientType`、`redirectUrl` 判据），读数见汇报；
//    其余各条注明了注入方式，都是"改这一处 ⇒ 这条红"的形状（未逐条实跑，照实标注）。
// ═══════════════════════════════════════════════════════════════════════
#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    /// 表单 → 有序 map（**顺序无关**比较用：表单语义上顺序无语义）
    fn form_map(pairs: Vec<(&str, String)>) -> BTreeMap<String, String> {
        pairs
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect()
    }

    // ── URL / 常量：逐字钉住（写错不报错、只"扫了没反应"的那一类）──

    /// ★★★ 五个端点 + browserId + returnUrl 逐字对齐取证
    ///
    /// ```text
    /// 注入方式：把 loginUrl.action 里的 `defaultSaveNameCheck=uncheck`
    ///   改成 `check` ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn tianyi_urls_match_the_documented_flow() {
        assert_eq!(
            tianyi_login_url(),
            "https://cloud.189.cn/api/portal/loginUrl.action\
             ?redirectURL=https%3A%2F%2Fcloud.189.cn%2Fweb%2Fredirect.html\
             &defaultSaveName=3&defaultSaveNameCheck=uncheck\
             &browserId=be49bf790869632e336aac2d9c7877b8",
            "★ 取证 .probe/r3-t20-strpool-urls.txt:258（§4.1-C ①）"
        );
        assert_eq!(
            tianyi_appconf_url(),
            "https://open.e.189.cn/api/logbox/oauth2/appConf.do",
            "★ strpool:405 / §4.1-C ②"
        );
        assert_eq!(
            tianyi_getuuid_url(),
            "https://open.e.189.cn/api/logbox/oauth2/getUUID.do",
            "★ strpool:406 / §4.1-C ③"
        );
        assert_eq!(
            tianyi_poll_url(),
            "https://open.e.189.cn/api/logbox/oauth2/qrcodeLoginState.do",
            "★ strpool:408 / §4.1-D 0x0080"
        );
        assert_eq!(
            tianyi_userinfo_url(),
            "https://cloud.189.cn/api/portal/v2/getUserBriefInfo.action",
            "★ strpool:259 / §4.1-E"
        );

        // browserId 是硬编码常量，三处必须一字不差
        assert_eq!(BROWSER_ID, "be49bf790869632e336aac2d9c7877b8");
        assert!(
            tianyi_login_url().contains(BROWSER_ID),
            "loginUrl 里的 browserId 与常量必须是同一个"
        );
        assert!(
            tianyi_return_url().contains(BROWSER_ID),
            "returnUrl 里的 browserId 与常量必须是同一个"
        );

        assert_eq!(
            tianyi_return_url(),
            "https://cloud.189.cn/api/portal/callbackUnify.action\
             ?browserId=be49bf790869632e336aac2d9c7877b8\
             &redirectURL=https%3A%2F%2Fcloud.189.cn%2Fweb%2Fredirect.html",
            "★ 取证 strpool:256（§4.1-D 的 returnUrl，逐字）"
        );

        // referer 两个值都要在（轮询用 logbox 域，不是 cloud 域）
        assert_eq!(REFERER_LOGIN, "https://cloud.189.cn/web/login.html");
        assert_eq!(REFERER_LOGBOX, "https://open.e.189.cn");
        // UA 必须是桌面 Chrome/151（dex 逐字）
        assert!(UA_TIANYI.contains("Chrome/151.0.0.0"), "{UA_TIANYI}");
    }

    /// ★★ ②③ 两跳的表单逐字（键名 + 值）
    ///
    /// ```text
    /// 注入验证：把 `version` 的 "2.0" 改成 "2" ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn appconf_form_is_verbatim() {
        let m: BTreeMap<&str, &str> = tianyi_appconf_form().into_iter().collect();
        assert_eq!(m.len(), 2);
        assert_eq!(m.get("appKey"), Some(&"cloud"));
        assert_eq!(m.get("version"), Some(&"2.0"));
    }

    /// ★★★ 轮询表单：11 个键 + 值逐字（顺序无关，但**一个都不能少**）
    ///
    /// ```text
    /// 注入验证（已实测）：把 `clientType` 的值从 "appId" 改成 "1"
    ///   ⇒ 本条 FAILED（逐字证据被"猜的正确值"覆盖了）。
    /// ★ clientType=appId 是 dex 原文（推断待确认 ③）：要改它必须先在真机拿到 400 的读数。
    /// ```
    #[test]
    fn poll_form_has_eleven_verbatim_fields() {
        let date = "2026-10-28 19:48:14.123";
        let ts = 1_761_700_094_123i64;
        let pairs = tianyi_poll_form("PID", "UID", "ENC", date, ts);
        assert_eq!(pairs.len(), 11, "★ 取证是 11 个参数，少一个服务端就不认");

        let m = form_map(pairs);
        let mut want: BTreeMap<String, String> = BTreeMap::new();
        want.insert("date".into(), date.into());
        want.insert("timeStamp".into(), ts.to_string());
        want.insert("isOauth2".into(), "false".into());
        want.insert("clientType".into(), "appId".into()); // ★ 逐字，见上
        want.insert("appId".into(), "cloud".into());
        want.insert("cb_SaveName".into(), "3".into());
        want.insert("state".into(), String::new()); // 空串但键必须在
        want.insert(
            "returnUrl".into(),
            "https://cloud.189.cn/api/portal/callbackUnify.action\
             ?browserId=be49bf790869632e336aac2d9c7877b8\
             &redirectURL=https%3A%2F%2Fcloud.189.cn%2Fweb%2Fredirect.html"
                .into(),
        );
        want.insert("paramId".into(), "PID".into());
        want.insert("uuid".into(), "UID".into());
        want.insert("encryuuid".into(), "ENC".into());
        assert_eq!(m, want, "轮询表单的键名/值必须与 §4.1-D 逐字一致");

        // 显式再钉一次那几个"最容易被好心改掉"的值
        assert_eq!(m.get("clientType").map(String::as_str), Some("appId"));
        assert_eq!(m.get("isOauth2").map(String::as_str), Some("false"));
        assert_eq!(m.get("state").map(String::as_str), Some(""));
        assert!(
            m.get("returnUrl").unwrap().contains("%3A%2F%2F"),
            "returnUrl 里的 redirectURL 必须保持百分号编码（解码后才是 URL）"
        );
    }

    /// ★★★ `date` 必须是 `yyyy-MM-dd HH:mm:ss.SSS` 形状（dex 逐字的 SimpleDateFormat）
    ///
    /// ```text
    /// 注入验证：把格式改成 "%Y-%m-%d %H:%M:%S"（丢毫秒）⇒ 本条 FAILED。
    /// ```
    #[test]
    fn now_date_string_has_millisecond_shape() {
        let s = now_date_string();
        assert_eq!(s.len(), 23, "形状必须是 19+4：`YYYY-MM-DD HH:MM:SS.mmm`，实得 {s:?}");
        let b = s.as_bytes();
        assert_eq!(b[4], b'-');
        assert_eq!(b[7], b'-');
        assert_eq!(b[10], b' ');
        assert_eq!(b[13], b':');
        assert_eq!(b[16], b':');
        assert_eq!(b[19], b'.');
        assert!(
            b[20..].iter().all(|c| c.is_ascii_digit()),
            "毫秒必须 3 位数字：{s:?}"
        );
    }

    // ── 解码（★ 这一段是"能不能出码"的关键）──

    /// ★★★ `url_decode` 的两条规则 + 不完整输入
    ///
    /// ```text
    /// 注入方式：把 `b'+' => push(b' ')` 这段删掉（不再把 + 当空格）
    ///   ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn url_decode_handles_percent_and_plus() {
        // ① UTF-8 中文：三个 %XX 拼一个字符（按字节拼，不是每 %XX 一个 char）
        assert_eq!(url_decode("%E4%B8%AD%E6%96%87"), "中文");
        // ② 小写十六进制等价
        assert_eq!(url_decode("%e4%b8%ad"), "中");
        // ③ `+` = 空格
        assert_eq!(url_decode("a+b+c"), "a b c");
        // ④ `%2B` 是**字面加号**，不是空格（两条规则不能互相污染）
        assert_eq!(url_decode("%2B"), "+");
        // ⑤ 不完整 / 非法：原样保留，不 panic、不丢字符
        assert_eq!(url_decode("%4"), "%4");
        assert_eq!(url_decode("100%"), "100%");
        assert_eq!(url_decode("%ZZ"), "%ZZ");
        assert_eq!(url_decode(""), "");
        // ⑥ 混合
        assert_eq!(url_decode("%25+%25"), "% %");
    }

    /// ★★★ 二维码内容 = 解码后的 encodeuuid（§4.1-B 的逐字结论）
    ///
    /// ```text
    /// 注入验证：把 `qr_content_of` 改成原样返回（不解码）⇒ 本条 FAILED
    ///   ⇒ 二维码里装的是 `https%3A%2F%2F…`，App 扫出来是无效码。
    /// ```
    #[test]
    fn qr_content_is_decoded_encodeuuid() {
        let enc = "https%3A%2F%2Fopen.e.189.cn%2Fapi%2Flogbox%2Foauth2%2FqrcodeLogin.do\
                   %3FparamId%3D123%26uuid%3Dabc%26encryuuid%3Ddef";
        let qr = qr_content_of(enc);
        assert_eq!(
            qr,
            "https://open.e.189.cn/api/logbox/oauth2/qrcodeLogin.do?paramId=123&uuid=abc&encryuuid=def"
        );
        assert!(!qr.contains('%'), "★ 解码后不该还剩 %XX：{qr}");
        // 已经是明文时不许二次破坏（幂等性只对"无 % 无 +"的输入成立）
        assert_eq!(qr_content_of("U1"), "U1");
    }

    // ── 第 ① 跳的 Location 解析（关重定向那件事的门禁）──

    /// ★★★ `lt` / `reqId` 从 Location 抠出来
    ///
    /// ```text
    /// 注入验证：把 `query_param` 里 `k.trim() == key` 改成 `k.contains(key)`
    ///   ⇒ 本条 FAILED（会命中 `myreqId` 这种键）。
    /// ```
    #[test]
    fn login_location_yields_lt_and_req_id() {
        let loc = "https://open.e.189.cn/api/logbox/oauth2/loginPage.do\
                   ?appKey=cloud&lt=1698450000000&reqId=ABCDEF123&version=2.0";
        let p = login_location_params(loc).expect("Location 里两个参数都在");
        assert_eq!(p.lt, "1698450000000");
        assert_eq!(p.req_id, "ABCDEF123");

        // HTML 转义过的 `&amp;` 也要能解析（便宜且无害的兜底）
        let amp = "https://x/y?lt=1&amp;reqId=R2";
        let p2 = login_location_params(amp).expect("&amp; 必须能解析");
        assert_eq!(p2.lt, "1");
        assert_eq!(p2.req_id, "R2");

        // 键名必须**整字匹配**：myreqId 不是 reqId
        let e3 = login_location_params("https://x/y?lt=1&myreqId=R").expect_err("myreqId 不算 reqId");
        assert!(e3.contains("没有 reqId"), "{e3}");
        assert!(!e3.contains("没有 lt"), "lt 是有的，别把两件事混起来：{e3}");
    }

    /// ★★★ 没拿到 Location = **大声报错**，而且文案必须点名"重定向被跟随了"
    ///
    /// ```text
    /// 注入验证：把 `client_no_redirect` 的 `.redirect(Policy::none())` 删掉，
    ///   真机上就会走进这个分支（拿到 200 + 登录页 HTML，没有 Location）
    ///   ⇒ 这条门禁保证那时是**可读错误**，而不是"后续全 401 且不报错"。
    /// ```
    #[test]
    fn missing_location_is_a_loud_error() {
        let e = login_location_params("").expect_err("空 Location 必须报错");
        assert!(e.contains("没有返回 Location"), "{e}");
        assert!(
            e.contains("重定向被跟随"),
            "★ 文案必须让下一个人立刻想到「关掉重定向」：{e}"
        );
        // 只有 lt 没有 reqId ⇒ 点名缺的那个
        let e2 = login_location_params("https://x/y?lt=1").expect_err("缺 reqId 必须报错");
        assert!(e2.contains("reqId"), "{e2}");
    }

    // ── ②③ 的字段解析 ──

    /// ★★ 容错扫描：带引号 / 裸数字 / 键名后缀不同 都要对上
    ///
    /// ```text
    /// 注入验证：把 `json_field` 里 `strip_prefix(':')` 的失败分支改成
    ///   `return Some(String::new())` ⇒ `required_field` 那条 FAILED（空串冒充找到了）。
    /// ```
    #[test]
    fn json_field_scans_tolerant_shapes() {
        assert_eq!(json_field(r#"{"reqId":"R1"}"#, "reqId").as_deref(), Some("R1"));
        // 空格
        assert_eq!(
            json_field(r#"{"paramId" :  "P1"}"#, "paramId").as_deref(),
            Some("P1")
        );
        // 裸数字（status 是 getInt，取出来就是数字）
        assert_eq!(json_field(r#"{"status":0,"x":1}"#, "status").as_deref(), Some("0"));
        // 结尾是 } 而不是 ,
        assert_eq!(json_field(r#"{"result":0}"#, "result").as_deref(), Some("0"));
        // 缺失 ⇒ None（绝不猜默认值）
        assert_eq!(json_field(r#"{"a":1}"#, "reqId"), None);
        assert_eq!(json_field("", "reqId"), None);
        // 键名只出现在**值**里时不许命中（`"nickname":"reqId"` 这种）
        assert_eq!(json_field(r#"{"nickname":"reqId"}"#, "reqId"), None);
    }

    /// ★★★ 必需字段缺失/空串 ⇒ 可读 Err（带字段名 + 摘要）
    ///
    /// ```text
    /// 注入验证：把 `required_field` 的 `Some(_)` 分支改成 `Ok(String::new())`
    ///   ⇒ 本条 FAILED（空 paramId 会被当成"拿到了"）。
    /// ```
    #[test]
    fn missing_required_fields_are_errors() {
        let e = getuuid_params(r#"{"uuid":"U1","encryuuid":"E1"}"#).expect_err("缺 encodeuuid");
        assert!(e.contains("encodeuuid"), "{e}");
        assert!(e.contains("getUUID.do"), "文案要点名是哪一步：{e}");

        let e2 = required_field(r#"{"uuid":""}"#, "uuid", "getUUID.do").expect_err("空串也是错");
        assert!(e2.contains("空串"), "{e2}");

        let ok = getuuid_params(r#"{"uuid":"U1","encryuuid":"E1","encodeuuid":"Q1"}"#).unwrap();
        assert_eq!(ok.uuid, "U1");
        assert_eq!(ok.encryuuid, "E1");
        assert_eq!(ok.encodeuuid, "Q1", "★ 这里必须存**未解码**的原始值");

        let conf = appconf_params(r#"{"result":0,"reqId":"R1","paramId":"P1"}"#).unwrap();
        assert_eq!(conf.req_id, "R1");
        assert_eq!(conf.param_id, "P1");
    }

    /// ★★ result：非 0 = 失败；**缺失** = 不下结论（证据支持到哪做到哪）
    ///
    /// ```text
    /// 注入验证：把 `check_result` 的 `!= "0"` 改成 `== "9"` ⇒ 第一条断言 FAILED。
    /// ```
    #[test]
    fn result_nonzero_fails_but_missing_is_tolerated() {
        let e = check_result(r#"{"result":1,"msg":"invalid appKey"}"#, "appConf.do")
            .expect_err("result 非 0 必须报错");
        assert!(e.contains("result=1"), "{e}");
        assert!(e.contains("invalid appKey"), "错误里要带上服务端 msg：{e}");
        // 缺失 ⇒ Ok（dex 只在一条上判 result，取证没说三跳都带）
        assert!(check_result(r#"{"reqId":"R1"}"#, "appConf.do").is_ok());
        assert!(check_result(r#"{"result":0}"#, "appConf.do").is_ok());
    }

    // ── 第 ④ 步的判据（★ 只有一条路能确认）──

    /// ★★★ 只有 `status==0 && redirectUrl 非空` 才是 Confirmed
    ///
    /// ```text
    /// 注入验证（实测）：把判据里的 `&& !redirect.is_empty()` 删掉
    ///   ⇒ 本条仍然绿（本条的 Wait 用例 status 都不是 0），
    ///   但 `status_zero_without_redirect_is_wait` **FAILED**
    ///   （读数：`left: Confirmed("")`）—— 那条就是守这一半的门禁。
    /// ```
    #[test]
    fn poll_verdict_confirms_only_on_zero_plus_redirect() {
        let v = tianyi_poll_verdict(
            r#"{"status":0,"redirectUrl":"https://cloud.189.cn/api/portal/callbackUnify.action?x=1"}"#,
        )
        .unwrap();
        assert_eq!(
            v,
            PollVerdict::Confirmed(
                "https://cloud.189.cn/api/portal/callbackUnify.action?x=1".to_string()
            )
        );

        // 非 0 一律"继续等"（★ 推断：dex 没有语义映射，不许猜成 Scanned/Expired）
        assert_eq!(
            tianyi_poll_verdict(r#"{"status":1}"#).unwrap(),
            PollVerdict::Wait {
                status: 1,
                redirect_present: false
            }
        );
        // 2/3/… 同样是 Wait
        for st in [2i64, 3, 4, 99, -1] {
            let body = format!(r#"{{"status":{st}}}"#);
            match tianyi_poll_verdict(&body).unwrap() {
                PollVerdict::Wait { status, .. } => assert_eq!(status, st),
                other => panic!("status={st} 不该被当成确认：{other:?}"),
            }
        }
    }

    /// ★★★ `status==0` 但没有 redirectUrl ⇒ **等待**，不许当成功
    ///
    /// ```text
    /// 为什么单独一条：这是"登录成功但没有凭据"的唯一入口。
    /// 判成 Confirmed ⇒ 后面拿空 URL 去请求 ⇒ 行为不可预测（我们在这里就断了它）。
    /// 注入验证（已实测）：删掉判据里的 `&& !redirect.is_empty()` ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn status_zero_without_redirect_is_wait() {
        for body in [r#"{"status":0}"#, r#"{"status":0,"redirectUrl":""}"#] {
            assert_eq!(
                tianyi_poll_verdict(body).unwrap(),
                PollVerdict::Wait {
                    status: 0,
                    redirect_present: false
                },
                "body={body}"
            );
        }
        // 有 redirectUrl 但 status 非 0 ⇒ 还是等待（判据是"且"，不是"或"）
        assert_eq!(
            tianyi_poll_verdict(r#"{"status":5,"redirectUrl":"https://x"}"#).unwrap(),
            PollVerdict::Wait {
                status: 5,
                redirect_present: true
            }
        );
    }

    /// ★★ 没有 status / status 不是整数 ⇒ Err（带摘要），不许默默当 Pending
    ///
    /// ```text
    /// 注入验证：把 `ok_or_else` 换成 `unwrap_or_default()`（status 默认 0）
    ///   ⇒ 本条 FAILED，而且线上会变成"空的响应也被当成确认"。
    /// ```
    #[test]
    fn poll_response_without_status_is_an_error() {
        let e = tianyi_poll_verdict("<html>502 Bad Gateway</html>").expect_err("没有 status 必须报错");
        assert!(e.contains("没有 status"), "{e}");
        assert!(e.contains("502 Bad Gateway"), "错误里要有响应摘要：{e}");

        let e2 = tianyi_poll_verdict(r#"{"status":"abc"}"#).expect_err("非整数必须报错");
        assert!(e2.contains("不是整数"), "{e2}");
    }

    // ── 回调链（跟随重定向 + 逐跳 cookie）──

    /// ★★ `Location` 的四种形态都要能拼成绝对 URL
    ///
    /// ```text
    /// 注入验证：删掉"站点相对（/path）"那条分支 ⇒ 第三条断言 FAILED。
    /// ```
    #[test]
    fn resolve_location_handles_all_shapes() {
        let base = "https://cloud.189.cn/api/portal/callbackUnify.action?a=1";
        assert_eq!(
            resolve_location(base, "https://cloud.189.cn/web/redirect.html"),
            "https://cloud.189.cn/web/redirect.html",
            "绝对地址原样用"
        );
        assert_eq!(
            resolve_location(base, "//cloud.189.cn/web/x"),
            "https://cloud.189.cn/web/x",
            "协议相对要补 scheme"
        );
        assert_eq!(
            resolve_location(base, "/web/redirect.html"),
            "https://cloud.189.cn/web/redirect.html",
            "站点相对要补 host"
        );
        assert_eq!(
            resolve_location(base, "next.html"),
            "https://cloud.189.cn/api/portal/next.html",
            "路径相对要拼到最后一个 / 之后"
        );
    }

    /// ★★ 3xx 才继续走；200/4xx 是终点
    #[test]
    fn is_redirect_status_covers_3xx_only() {
        for c in [300u16, 301, 302, 303, 307, 308] {
            assert!(is_redirect_status(c), "{c} 是重定向");
        }
        for c in [200u16, 204, 400, 401, 403, 500] {
            assert!(!is_redirect_status(c), "{c} 不是重定向");
        }
    }

    /// ★★★ cookie 合并：**同名键后者覆盖前者**（否则用的是旧值）
    ///
    /// ```text
    /// 注入验证：把 `slot.1 = v` 改成 `pairs.push(...)`（不去重）
    ///   ⇒ 本条 FAILED（会出现两个 JSESSIONID）。
    /// ```
    #[test]
    fn merge_cookie_pairs_keeps_the_later_value() {
        assert_eq!(merge_cookie_pairs("a=1; b=2", "b=3; c=4"), "a=1; b=3; c=4");
        assert_eq!(merge_cookie_pairs("", "x=1"), "x=1");
        assert_eq!(merge_cookie_pairs("x=1", ""), "x=1");
        // 顺序保持首次出现的位置（后面只换值）
        assert_eq!(merge_cookie_pairs("k=old; m=2", "k=new"), "k=new; m=2");
        // 空段 / 无等号段不许 panic
        assert_eq!(merge_cookie_pairs(" ; a=1 ;; ", ""), "a=1");
    }

    /// ★ 现场摘要不许把 cookie 的值写出去（只看键名与长度）
    #[test]
    fn cookie_digest_does_not_leak_values() {
        let d = cookie_digest("COOKIE_LOGIN_USER=SECRET; JSESSIONID=ALSOSECRET");
        assert!(d.contains("2 个键"), "{d}");
        assert!(d.contains("COOKIE_LOGIN_USER"), "{d}");
        assert!(!d.contains("SECRET"), "★ cookie 值不许进摘要：{d}");
    }

    // ── 会话表 ──

    /// ★★ 会话 key 只有天翼一个盘走这条路（给 dispatch 分流用）
    ///
    /// ```text
    /// 注入验证：把 `matches!` 改成 `matches!(kind, PanKind::Tianyi | PanKind::Quark)`
    ///   ⇒ 本条 FAILED（夸克会误进本模块的 poll，key 永远不在本表里）。
    /// ```
    #[test]
    fn is_tianyi_login_is_exactly_one_kind() {
        assert!(is_tianyi_login(PanKind::Tianyi));
        for k in [
            PanKind::Quark,
            PanKind::Uc,
            PanKind::Baidu,
            PanKind::Pan115,
            PanKind::Aliyun,
            PanKind::Guangya,
            PanKind::Xunlei,
            PanKind::Pan123,
        ] {
            assert!(!is_tianyi_login(k), "{} 不该进天翼模块", k.code());
        }
    }

    /// ★★ 会话：活着能取到、超时会被清掉（**纯本地**，不打网络）
    ///
    /// ```text
    /// 注入方式：把 TTL 判定改成 `now() - rec.created_at > SESSION_TTL_SECS * 100`
    ///   ⇒ 本条第二条断言 FAILED
    ///   （过期会话永远不会被清 ⇒ UI 一直说"正在等待"，而服务端早就没这个码了）。
    /// ```
    #[test]
    fn session_peek_keeps_live_and_drops_expired() {
        let live = "test-uuid-live";
        let dead = "test-uuid-dead";
        let mk = |uuid: &str, created_at: i64| TianyiSession {
            req_id: "R2".into(),
            param_id: "P".into(),
            uuid: uuid.to_string(),
            encryuuid: "E".into(),
            created_at,
        };
        sessions()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(kind_key(PanKind::Tianyi, live), mk(live, now()));
        sessions()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(kind_key(PanKind::Tianyi, dead), mk(dead, now() - SESSION_TTL_SECS - 5));

        let got = peek_session(live).expect("未超时的会话必须还在");
        assert_eq!(got.param_id, "P");
        assert_eq!(got.uuid, live);

        assert!(peek_session(dead).is_none(), "★ 超时必须判为不在");
        assert!(
            !sessions()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .contains_key(&kind_key(PanKind::Tianyi, dead)),
            "过期项要被真的删掉（否则表会越积越多）"
        );
        assert!(peek_session("从没见过的-key").is_none());
        // 清理，别把状态漏给同进程的其它门禁
        sessions()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&kind_key(PanKind::Tianyi, live));
    }

    /// ★ 摘要不许在多字节边界上切（否则日志本身变乱码）
    #[test]
    fn tail_never_panics_on_multibyte() {
        assert!(tail("").contains("0 字节"));
        let s = "天".repeat(300);
        assert!(tail(&s).contains("共"));
    }
}
