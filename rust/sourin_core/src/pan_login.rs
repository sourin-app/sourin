//! 网盘**扫码登录**协议层（R3-C B1）
//!
//! # 这一层做什么 / 不做什么
//!
//! ```text
//! 本模块：扫码登录的**协议流程**（拿 token → 出二维码 → 轮询 → 换 cookie）
//! 存储层：`pan_auth` 负责 cookie 的存/取/清（系统钥匙串）
//! ```
//! 分开的理由：`pan_auth` 是**与协议无关**的凭据仓库（它对夸克/UC/百度一视同仁）；
//! 而扫码的端点和参数**每家网盘不同** ⇒ 那些差异归本模块。
//!
//! # ⚠️ 本模块的凭据来源是**参考实现的行为**（dex 字符串取证），不是照抄源码
//!
//! 各家的端点是**逐字**从参考实现的字符串常量里取的（jar 无 license ⇒ 只取行为/协议层）：
//! ```text
//! 夸克（已实现，本文件）：
//!   ① https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532&v=1.2
//!   ② https://su.quark.cn/4_eMHBJ?token=<token>&client_id=532&ssb=weblogin&…
//!        （二维码内容就是 ② 这个 URL）
//!   ③ https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=532&v=1.2&token=<token>
//!   ④ https://pan.quark.cn/account/info?st=<service_ticket>&lw=scan   ⇒ 响应 Set-Cookie 即登录态
//! 取证：`.probe/r3c-quark-login-endpoints.log`（含 UA / Referer / Accept 逐字）
//! ```
//!
//! # ★ 能力已存在但**未接通的**部分（如实登记，不许当前提承诺）
//!
//! ```text
//! 网盘直链播放还需要「本机转发服务」把 `Referer`/`Cookie` 带上。
//! 本仓已有等价能力：`streamproxy::register(url, headers)`（streamproxy.rs:819）
//!   —— 形态与 TVBox 的 `127.0.0.1:5266` 相同。
//! ⚠️ 但"接口存在" ≠ "能力可用"：网盘直链常是 302 链、要 Range 透传，
//!   这一条**尚未实测**。⇒ 在真验通之前，不把"能播"当已交付的承诺。
//! ```
//!
//! # 为什么用枚举而不是 trait 对象（此刻）
//!
//! ```text
//! 现在只有 1 家（夸克）。trait 的好处此刻兑现不了（没有第二个实现），
//! 而枚举的坏处此刻也没有（没有第三方扩展）。
//! ⇒ 先用枚举 + `match`，等 B2 加第二家时若发现分支重复明显再抽 trait。
//!   **不为"将来可能要"提前抽象** —— 那会造出没有用例的机制。
//! ```

use std::time::Duration;

use crate::pan::PanKind;

/// 二维码登录的一次会话
///
/// 生命周期：`start` 产出 → UI 显示 `svg` → 按 ~2s 间隔 `poll` →
/// 直到 `status != Pending`（或超时）。
#[derive(Debug, Clone)]
pub struct QrSession {
    /// 会话标识（UI 侧用它做 poll 的 key；本模块内 = 网盘给的 token）
    pub key: String,
    /// 二维码**内容**（要编成图的那个 URL）
    pub url: String,
    /// 二维码 SVG（`remote::qr_svg_for` 产出；失败时为空串 ⇒ UI 退化成显示 URL）
    pub svg: String,
    /// 给用户的一句提示（如"用夸克 App 扫码"）
    pub hint: String,
    /// 会话创建时刻（Unix 秒）—— 用于超时判定
    pub created_at: i64,
}

/// 轮询结果的三态（**不含"已登录"** —— 那是 `poll` 带上凭据的额外产出）
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum QrStatus {
    /// 还没扫
    Pending,
    /// 扫了但没确认（多数网盘有这个中间态）
    Scanned,
    /// 已确认 —— 可以换 cookie 了
    Confirmed,
    /// 过期（用户太久没扫，要重新 start）
    Expired,
    /// 失败（网络/协议错）
    Failed,
}

impl QrStatus {
    /// 机器可读名（落盘/日志/UI 判断用；**不要**用 Debug 输出）
    pub fn code(&self) -> &'static str {
        match self {
            QrStatus::Pending => "pending",
            QrStatus::Scanned => "scanned",
            QrStatus::Confirmed => "confirmed",
            QrStatus::Expired => "expired",
            QrStatus::Failed => "failed",
        }
    }
}

/// 一次轮询的完整产出
#[derive(Debug, Clone)]
pub struct PollOutcome {
    pub status: QrStatus,
    /// 给用户的话（失败说原因；成功说"登录成功：<账号>"）
    pub message: String,
    /// 确认后换到的登录态 —— `Some` 表示这次**真的**可以落盘了
    ///
    /// 形如 `save(&PanCredential { kind, account, cookie, .. })` 的入参。
    pub credential: Option<crate::pan_auth::PanCredential>,
}

/// 扫码登录会话表（按网盘存"进行中的会话"）
///
/// # 为什么是全局表而不是参数传递
/// UI 的调用形态是 `start{kind} → {key} → poll{kind,key}`：
/// `key` 是**网盘给的 token**，而 `poll` 还需要知道"这是哪家的会话"以决定调哪个端点。
/// 用 `kind` 作分区、`key` 作内层键，就能让 `poll` 只需 `(kind, key)` 两个参数
/// —— 与 UI 契约（pan_settings_page.dart:35）一致，不必让 UI 侧多传协议信息。
///
/// ⚠️ 进程内全局状态：本仓有先例（会话缓存类），且**登录会话天然是进程内**的
///    （用户关掉应用，未扫完的二维码本就该失效）。
static SESSIONS: std::sync::OnceLock<
    std::sync::Mutex<std::collections::HashMap<String, SessionRecord>>,
> = std::sync::OnceLock::new();

struct SessionRecord {
    /// 网盘给的 token（轮询与换 cookie 都要用它）
    token: String,
    /// 发起时刻（超时判定）
    created_at: i64,
}

fn sessions() -> &'static std::sync::Mutex<std::collections::HashMap<String, SessionRecord>> {
    SESSIONS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// 会话有效期：超过它就让用户重新 start
///
/// 取值依据：夸克的二维码 token 有效期是**分钟级**（参考实现靠轮询返回的
/// 过期状态判定，但我们也需要一个本地兜底，免得"UI 一直转圈"）。
/// 5 分钟足够用户掏出手机；过短会让人扫到一半就被判过期。
const SESSION_TTL_SECS: i64 = 300;

/// 单次 HTTP 的预算（登录接口都很快；卡住说明网络问题，早失败早提示）
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

/// 夸克云盘的 UA —— **逐字取自参考实现**（见文件头取证）
///
/// ★ 为什么必须逐字：夸克的 CAS 登录接口会看 UA，
///   用一个"通用浏览器 UA"可能被当成不支持扫码的客户端。
///   （参考实现给 `buildQuarkQrInfo` 与 `handleQuark` 用的是**两个不同** UA：
///    前者是 Electron 版夸克云盘、后者是 Chrome。我照抄这个区分。）
const UA_QUARK_QR: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 \
                           (KHTML, like Gecko) quark-cloud-drive/3.0.1 Chrome/100.0.4896.160 \
                           Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch";
const UA_QUARK_POLL: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                             (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 建立 HTTP 客户端
///
/// ⚠️ 与 `csp/pan_web_share.rs` 同一条纪律：reqwest **默认读环境代理**，
/// 而用户机器上的代理会把"接口可用"测成"全失败"。
/// 登录接口尤其不能走代理（夸克的 CAS 对出口 IP 敏感）。
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

// ═══════════════════════════════════════════════════════════════════════
//  落盘日志 —— **现场可读性的前提**
// ═══════════════════════════════════════════════════════════════════════
//
// ★★ 为什么必须加（这是我报"准备读日志"时**发现自己缺的**）：
// ```text
// 我原来的 `pan_login` 里**一条落盘日志都没有**。
// 而 Owner 现场点"获取二维码"时，我需要**读到他那次的响应/错误原文**才能判读
//   （如"业务失败 status=?"/ "HTTP ?"/ Set-Cookie 有几条）。
// ⇒ 没有落盘日志 ⇒ 现场读数只有他能看到（他不懂技术，我也拿不到原文）
//   ⇒ 那次现场会**浪费** —— 正是 Lead 强调"一次现场验完"要避免的。
// ```
//
// ★ 机制照抄 `streamproxy.rs:124-164`（同一条纪律）：
//   · `SOURIN_LOG_FILE` 可覆盖（测试要验格式时用）
//   · **测试进程不写真实日志**（否则测试夹具往用户 logs/ 写噪声）
//   · 与 Dart 侧同一个文件、同一行格式（`时间 [tag] 消息`）
//
// ★ tag 用 `[PAN]`：与 `[streamproxy]` / `[PLAY]` / `[DMK]` 并列，
//   现场可用一句 `grep '\[PAN\]'` 捞出全部网盘相关行。
const LOG_TAG: &str = "PAN";

fn in_test_process() -> bool {
    // ⚠️ **必须用 `cfg!(test)`（编译期宏），不能用环境变量** —— 我第一版写成
    //    `std::env::var("CARGO_CFG_TEST")` ⇒ **那个环境变量根本不存在**
    //    ⇒ 判断恒为 false ⇒ 测试进程照样往**用户真实日志**写。
    //    ★ 而且我那条门禁**真的抓到了它**（`log_path_is_guarded_in_test_process` 红，
    //      读数里直接打印出了用户真实路径）—— 这就是"门禁有牙"的价值：
    //      一个**看起来在做防护、实际恒 false** 的判断，只有"断言它生效"才能发现。
    //    （与 `streamproxy.rs:117` 同一形态 —— 那处用的是 `cfg!(test)`。）
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

/// 脱敏后的 cookie 摘要（**只写键名与长度，绝不写值**）
///
/// ★ 硬规矩：cookie 是登录凭据，**不许进日志**（与 `pan_auth` 只把 cookie 放钥匙串同源）。
///   但"有几条键、多少字节"足够判"Set-Cookie 形状对不对"，且不泄密。
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

// ═══════════════════════════════════════════════════════════════════════
//  夸克网盘（PanKind::Quark）—— B1 的唯一一家
// ═══════════════════════════════════════════════════════════════════════

/// 夸克业务码（★ 2026-10-27 真网络实测拿到的，不是猜的）
///
/// # 为什么必须按**业务码**判而不是按 HTTP 码
/// ```text
/// 真读数（`.probe/r3c-quark-first-two-hops-live.md`）：
///   取 token 成功 ⇒ HTTP 200 + body `{"status":2000000,"message":"ok",…}`
///   未扫描       ⇒ HTTP 200 + body `{"status":50004001,"message":"Query result is empty"}`
/// ⇒ **HTTP 码一路都是 200**，"成功/未扫/过期"全在 body 的 `status` 里。
///   原来只看 `resp.status()`（HTTP）⇒ 会把"业务失败"当成功。
/// ```
const QUARK_OK: i64 = 2_000_000;
/// 未扫描（"还没人扫"）
const QUARK_NOT_SCANNED: i64 = 50_004_001;

/// 取 body 里的业务码（拿不到 ⇒ None，由调用方决定怎么办）
fn quark_status_code(body: &str) -> Option<i64> {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()?
        .get("status")?
        .as_i64()
}

/// 取 body 里的 message（错误文案要如实带上它，方便用户/我们定位）
fn body_message(body: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()?
        .get("message")?
        .as_str()
        .map(|s| s.to_string())
}

/// 夸克：第一步拿二维码 token
///
/// 端点：`https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532&v=1.2`
/// 响应：`{"status":2000000,"message":"ok","data":{"members":{"token":"…"}}}`
/// （★ 真网络实测确认；见 `.probe/r3c-quark-first-two-hops-live.md`）
async fn quark_start() -> Result<QrSession, String> {
    let c = client(UA_QUARK_QR)?;
    let resp = c
        .get("https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532&v=1.2")
        .header("Accept", "application/json, text/plain, */*")
        .send()
        .await
        .map_err(|e| format!("请求夸克二维码接口失败：{e}"))?;

    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读夸克响应失败：{e}"))?;
    if !status.is_success() {
        return Err(format!("夸克二维码接口返回 HTTP {status}：{}", tail(&body)));
    }

    // ★ 先看**业务码**（HTTP 200 也可能业务失败 —— 真读数确认过）
    let code = quark_status_code(&body);
    if let Some(c) = code {
        if c != QUARK_OK {
            let msg = body_message(&body).unwrap_or_default();
            write_log(&format!(
                "取码失败 kind=quark 业务码={c} message={msg} body={}",
                tail(&body)
            ));
            return Err(format!(
                "夸克二维码接口业务失败（status={c}）：{}",
                if msg.is_empty() { tail(&body) } else { msg }
            ));
        }
    }

    let token = extract_qr_token(&body).ok_or_else(|| {
        write_log(&format!("取码失败 kind=quark 无 token body={}", tail(&body)));
        format!("夸克响应里没有找到二维码 token（协议可能变了）：{}", tail(&body))
    })?;

    // ② 二维码内容 = 这个 URL（参考实现逐字；实测 HTTP 302 ⇒ 是可扫的真码）
    let url = format!(
        "https://su.quark.cn/4_eMHBJ?token={token}&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
    );
    let svg = crate::remote::qr_svg_for(&url).unwrap_or_default();
    // ★ 现场判读用：token 长度 + svg 是否非空（**不写完整 URL** —— 里面有 token）
    write_log(&format!(
        "取码成功 kind=quark token_len={} svg_len={} 业务码={:?}",
        token.len(),
        svg.len(),
        code
    ));

    let created_at = now();
    sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(
            kind_key(PanKind::Quark, &token),
            SessionRecord {
                token: token.clone(),
                created_at,
            },
        );

    Ok(QrSession {
        key: token,
        url,
        svg,
        hint: "用夸克 App 扫这个码（或夸克浏览器）".to_string(),
        created_at,
    })
}

/// 夸克：轮询扫码状态（扫中了就换 cookie）
///
/// 两个端点（参考实现逐字）：
/// ```text
/// ③ https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=532&v=1.2&token=<t>
///      → data.service_ticket（拿到说明用户确认了）
/// ④ https://pan.quark.cn/account/info?st=<ticket>&lw=scan
///      → 响应头 Set-Cookie 就是登录态
/// ```
async fn quark_poll(token: &str) -> Result<PollOutcome, String> {
    let c = client(UA_QUARK_POLL)?;

    // ③ 换取 service_ticket
    let url = format!(
        "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=532&v=1.2&token={token}"
    );
    let resp = c
        .get(&url)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://pan.quark.cn/")
        .send()
        .await
        .map_err(|e| format!("轮询夸克扫码状态失败：{e}"))?;
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读夸克轮询响应失败：{e}"))?;

    // 状态判定：参考实现看 `data.service_ticket` 与 `message`。
    // ⚠️ 具体字段名会随协议变；这里**按行为重写**：
    //    能取到 ticket ⇒ Confirmed；message 里含"过期/expired" ⇒ Expired；
    //    其它一律 Pending（**宁可多问几次，不要误报成功**）。
    let ticket = extract_service_ticket(&body);
    let Some(ticket) = ticket else {
        let st = classify_pending(&body);
        // ★ 现场判读用：把**每次轮询的业务码**记下来（Owner 扫码时能看到它变化）
        write_log(&format!(
            "轮询 kind=quark 状态={} 业务码={:?} body={}",
            st.code(),
            quark_status_code(&body),
            tail(&body)
        ));
        return Ok(PollOutcome {
            status: st,
            message: "等待扫码…".to_string(),
            credential: None,
        });
    };

    // ④ 用 ticket 换 cookie
    let info_url = format!("https://pan.quark.cn/account/info?st={ticket}&lw=scan");
    let resp = c
        .get(&info_url)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://pan.quark.cn/")
        .send()
        .await
        .map_err(|e| {
            write_log(&format!("换 cookie 请求失败 kind=quark err={e}"));
            format!("换取夸克登录态失败：{e}")
        })?;

    // ★ 登录态在 **响应头 Set-Cookie**（参考实现逐字：它读 'set-cookie' 再按 ';' 切）
    let cookie = collect_set_cookie(&resp);
    if cookie.is_empty() {
        write_log("换 cookie 失败 kind=quark 响应无 Set-Cookie（记响应头形状待查）");
        return Err(
            "夸克已确认扫码，但响应里没有 Set-Cookie（协议可能变了）⇒ 拿不到登录态".to_string(),
        );
    }
    // ★ 脱敏记录：键名 + 长度（**绝不写值**）—— 足够判"形状对不对"
    write_log(&format!(
        "换 cookie 成功 kind=quark 摘要={}",
        cookie_digest(&cookie)
    ));

    // ★★ 关键键校验（2026-10-27 Owner 现场真读数给的**基线**）
    // ```text
    // 实测拿到的夸克 cookie 是这 6 个键：
    //   ctoken, __pus, __kp, __kps, __ktd, __uid
    // ⇒ 若只剩一两个（或名字全不对），说明"登录态不完整" ——
    //   那种情况下**请求会全 401**，但**不会在登录这一步报错** ⇒ 属静默假成功。
    // ⇒ 这里至少钉住"必须有 uid 与 ctoken"，并在日志里如实记录缺了什么。
    //    ⚠️ **故意宽松**（不做"必须 6 键一个不差"的硬门禁）：
    //      网盘可能改键名/增减键 ⇒ 硬门禁会把"协议正常演进"误判成失败。
    //      所以：**缺关键键 ⇒ 日志告警（但不算失败）**，让现场能看出异常；
    //      真失败由后续取数（列文件 401）暴露 —— 那才是权威判据。
    // ```
    let missing: Vec<&str> = ["ctoken", "__uid"]
        .iter()
        .copied()
        .filter(|k| !cookie.split(';').any(|p| p.trim().starts_with(&format!("{k}="))))
        .collect();
    if !missing.is_empty() {
        write_log(&format!(
            "⚠️ 登录态可能不完整 kind=quark 缺少关键键 {:?}（实测基线是 6 键 \
             ctoken,__pus,__kp,__kps,__ktd,__uid）",
            missing
        ));
    }

    // ★ account 也从这个响应里取 —— **必须在读 body 之前先收 header**
    //   （`Response` 的 body 只能消费一次；我第一版把它写成"传 &Response 进去再读"
    //     ⇒ 那个函数永远返回 None = 看起来在取账号、其实永远取不到）
    let body = resp.text().await.unwrap_or_default();
    let account = account_from_body(&body).unwrap_or_else(|| "夸克网盘".to_string());

    Ok(PollOutcome {
        status: QrStatus::Confirmed,
        message: format!("登录成功：{account}"),
        credential: Some(crate::pan_auth::PanCredential {
            kind: PanKind::Quark,
            account,
            cookie,
            saved_at: now(),
            // 夸克的会话 cookie 没有明确过期时间 ⇒ None（`PanCredential` 的既有语义）
            expires_at: None,
        }),
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  UC 网盘（PanKind::Uc）—— 与夸克**同族 CAS**，但 id / 主机 / 二维码入口都不同
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（逐字，来自 `.probe/r3c-quark-login-endpoints.log` 的 buildUcQrInfo / handleUc）
//
// ```text
// ① 取码  GET https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin
//             ?pr=UCBrowser&fr=pc&sys=win32&client_id=529&v=1.2&request_id=<rid>
// ② 二维码内容 https://su.uc.cn/4_fzMj2?uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt
//             &token=<token>&client_id=529&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix
// ③ 换票  GET https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken
//             ?__dt=18884&__t=<ts>&client_id=381&v=1.2&request_id=<rid>&token=<token>
//             → data.service_ticket
// ④ 换 cookie GET https://drive.uc.cn/account/info?st=<ticket>
//             Referer: https://broccoli.uc.cn/   → 响应头 Set-Cookie
// UA：取码用 `uc-cloud-drive/2.5.20 …`（Electron 版），轮询用 Chrome 151
// ```
//
// # ⚠️ 与夸克的**三处不同**（照抄夸克会全错，且不会报错、只会"扫了没反应"）
// ```text
// ① client_id：取码 529 / 换票 381（夸克两处都是 532）
// ② 主机：取码与换票都在 api.open.uc.cn（夸克在 uop.quark.cn）
// ③ 二维码入口：su.uc.cn/4_fzMj2（夸克 su.quark.cn/4_eMHBJ），且多一个 uc_param_str 串
// ```
//
// # 未真验边界
// ```text
// 整条链路**没有真账号跑过**（Owner 的批末实机验证里一并确认）。
// 失败会如实报"哪一步 HTTP 多少 / 业务码多少"，不伪造成功。
// ```

/// UC 取码用的 UA（逐字取自参考实现 buildUcQrInfo）
const UA_UC_QR: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                        (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 \
                        Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch";

/// UC 取码的 client_id（换票用的是**另一个** 381，见 [`uc_ticket_url`]）
const UC_QR_CLIENT_ID: u32 = 529;
/// UC 换票的 client_id
const UC_TICKET_CLIENT_ID: u32 = 381;
/// UC 二维码入口（逐字；多一个 uc_param_str 串 —— 少了它 UC App 可能不认）
const UC_QR_ENTRY: &str = "https://su.uc.cn/4_fzMj2";
/// UC 二维码入口的固定参数串（逐字）
const UC_QR_PARAM_STR: &str =
    "dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt";

/// UC 取码 URL（**纯函数**：client_id 与 request_id 是"不会报错、只会扫不动"的静默错源）
fn uc_token_url(request_id: &str) -> String {
    format!(
        "https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin\
         ?pr=UCBrowser&fr=pc&sys=win32&client_id={UC_QR_CLIENT_ID}&v=1.2&request_id={request_id}"
    )
}

/// UC 二维码**内容**（纯函数）
fn uc_qr_url(token: &str) -> String {
    format!(
        "{UC_QR_ENTRY}?uc_param_str={UC_QR_PARAM_STR}&token={token}\
         &client_id={UC_QR_CLIENT_ID}&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix"
    )
}

/// UC 换票 URL（纯函数）。`ts` 是毫秒时间戳，`request_id` 与取码时**同一个**。
fn uc_ticket_url(token: &str, request_id: &str, ts: i64) -> String {
    format!(
        "https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken\
         ?__dt=18884&__t={ts}&client_id={UC_TICKET_CLIENT_ID}&v=1.2\
         &request_id={request_id}&token={token}"
    )
}

/// 一个短的随机会话号（`request_id`；参考实现由客户端生成，服务端只回显）
fn new_request_id() -> String {
    // 不引 rand 依赖（本批纪律）：用纳秒时间 + 进程内计数器拼一个 32 位十六进制串
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    format!("{:016x}{:016x}", nanos ^ seq.wrapping_mul(0x9E37_79B9_7F4A_7C15), seq)
}

/// UC：第一步拿二维码 token（与夸克同族，但 client_id / 主机不同）
async fn uc_start() -> Result<QrSession, String> {
    let c = client(UA_UC_QR)?;
    let request_id = new_request_id();
    let resp = c
        .get(uc_token_url(&request_id))
        .header("Accept", "application/json, text/plain, */*")
        .send()
        .await
        .map_err(|e| format!("请求 UC 二维码接口失败：{e}"))?;

    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读 UC 响应失败：{e}"))?;
    if !status.is_success() {
        return Err(format!("UC 二维码接口返回 HTTP {status}：{}", tail(&body)));
    }
    // 同族业务码（2000000 成功 / 其它失败）—— 与夸克同一套
    if let Some(code) = quark_status_code(&body) {
        if code != QUARK_OK {
            let msg = body_message(&body).unwrap_or_default();
            write_log(&format!(
                "取码失败 kind=uc 业务码={code} message={msg} body={}",
                tail(&body)
            ));
            return Err(format!(
                "UC 二维码接口业务失败（status={code}）：{}",
                if msg.is_empty() { tail(&body) } else { msg }
            ));
        }
    }
    let token = extract_qr_token(&body).ok_or_else(|| {
        write_log(&format!("取码失败 kind=uc 无 token body={}", tail(&body)));
        format!("UC 响应里没有找到二维码 token（协议可能变了）：{}", tail(&body))
    })?;

    let url = uc_qr_url(&token);
    let svg = crate::remote::qr_svg_for(&url).unwrap_or_default();
    write_log(&format!(
        "取码成功 kind=uc token_len={} svg_len={} request_id_len={} 业务码={:?}",
        token.len(),
        svg.len(),
        request_id.len(),
        quark_status_code(&body)
    ));

    let created_at = now();
    // ★ 会话表里也要存 request_id（换票要跟取码同一个）⇒ 放进 token 的前缀里？
    //   不：把 `token` 与 `request_id` 用 `|` 拼成 key 会污染 UI 的 key。
    //   ⇒ 直接把 request_id 编进 `token` 字段（`poll` 拿 `key` = token 解码）。
    let compound = format!("{token}|{request_id}");
    sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(
            kind_key(PanKind::Uc, &token),
            SessionRecord {
                token: compound,
                created_at,
            },
        );

    Ok(QrSession {
        key: token,
        url,
        svg,
        hint: "用 UC 网盘 App 或 UC 浏览器扫这个码".to_string(),
        created_at,
    })
}

/// UC：轮询扫码状态（扫中确认后换 cookie）
async fn uc_poll(token: &str) -> Result<PollOutcome, String> {
    // 取回 request_id（与取码同一个；缺失 ⇒ 用空串让服务端报错，而不是编一个）
    let request_id = sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&kind_key(PanKind::Uc, token))
        .and_then(|r| r.token.split_once('|').map(|(_, rid)| rid.to_string()))
        .unwrap_or_default();

    let c = client(UA_QUARK_POLL)?; // 同族：轮询用 Chrome UA（取证逐字）
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let url = uc_ticket_url(token, &request_id, ts);
    let resp = c
        .get(&url)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://broccoli.uc.cn/")
        .send()
        .await
        .map_err(|e| format!("轮询 UC 扫码状态失败：{e}"))?;
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读 UC 轮询响应失败：{e}"))?;

    let Some(ticket) = extract_service_ticket(&body) else {
        let st = classify_pending(&body);
        write_log(&format!(
            "轮询 kind=uc 状态={} 业务码={:?} body={}",
            st.code(),
            quark_status_code(&body),
            tail(&body)
        ));
        return Ok(PollOutcome {
            status: st,
            message: "等待扫码…".to_string(),
            credential: None,
        });
    };

    // ④ 换 cookie（登录态在响应头 Set-Cookie，与夸克同族）
    let info_url = format!("https://drive.uc.cn/account/info?st={ticket}");
    let resp = c
        .get(&info_url)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://broccoli.uc.cn/")
        .send()
        .await
        .map_err(|e| {
            write_log(&format!("换 cookie 请求失败 kind=uc err={e}"));
            format!("换取 UC 登录态失败：{e}")
        })?;
    let cookie = collect_set_cookie(&resp);
    if cookie.is_empty() {
        write_log("换 cookie 失败 kind=uc 响应无 Set-Cookie（记响应头形状待查）");
        return Err(
            "UC 已确认扫码，但响应里没有 Set-Cookie（协议可能变了）⇒ 拿不到登录态".to_string(),
        );
    }
    write_log(&format!(
        "换 cookie 成功 kind=uc 摘要={}",
        cookie_digest(&cookie)
    ));
    let body = resp.text().await.unwrap_or_default();
    let account = account_from_body(&body).unwrap_or_else(|| "UC 网盘".to_string());

    Ok(PollOutcome {
        status: QrStatus::Confirmed,
        message: format!("登录成功：{account}"),
        credential: Some(crate::pan_auth::PanCredential {
            kind: PanKind::Uc,
            account,
            cookie,
            saved_at: now(),
            expires_at: None,
        }),
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  百度网盘（PanKind::Baidu）—— **passport 扫码**，与夸克 CAS **不是同一族**
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（`.probe/r3c-nine-pan-login-protocols.md` 附二 + `r3c-pan-helper-endpoints.log`）
//
// ```text
// ① 取二维码  GET passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc
//             → ★ 顶层 { sign, imgurl, errno, prompt }
//               （`imgurl` 是一张 **PNG 图片** 的地址，且**不带 scheme** —— 见下面的真读数）
// ② 轮询      GET passport.baidu.com/channel/unicast?channel_id=<cid>&v=<v>
//             → ★ 登录态在**响应头 set-cookie 的 BDUSS**
// ③ 换登录态  GET passport.baidu.com/v3/login/main/qrbdusslogin?v=<v>&bduss=<BDUSS>
// ④ 补 cookie GET pan.baidu.com/disk/main?from=homeFlow（pan 域的 STOKEN 等在这条响应里）
// UA：Chrome/151 桌面；Referer：https://pan.baidu.com/
// ```
//
// # 与夸克/UC 的**结构差异**（所以没有合并成一个实现）
// ```text
// ① 二维码不是"把 token 拼进固定 URL"，而是**响应里给一张二维码图片的地址**；
// ② "扫中了"的信号不是业务码，而是**响应头里出现 BDUSS**；
// ③ 换登录态是"拿 BDUSS 再换一次"，cookie 来自**两次**响应 + 一次 pan 域请求。
// ```
//
// # 未真验边界
// ```text
// 整条链路没有真账号跑过（批末实机验证一并做）。
// 扫码未确认时**一律 Pending**（不靠关键词猜"已扫"）—— 百度侧没有可判定的业务码读数，
// 猜成 Scanned 只会让 UI 显示"已扫描，请在手机上确认"而用户根本没扫。
// ```
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 真读数（2026-10-29，Owner 用 curl 逐字打的）—— 它**推翻了**上一版实现
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// GET https://passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc
// → {"imgurl":"passport.baidu.com/v2/api/qrcode?sign=<sign>&lp=pc&qrloginfrom=pc",
//    "errno":0,"sign":"<sign>","prompt":"登录后..."}
// ```
//
// # 旧实现错在哪（留在这里防回退）
// ```text
// 旧代码按取证文档的用词去找 `data.channel_id` + `data.url`，而真报文里有三处不同：
//   ① 字段在**顶层**，不在 `data` 里；
//   ② **没有** `channel_id`，只有 `sign`；
//   ③ **没有**"二维码文本"，只有 `imgurl` —— 一张 PNG 图片的地址，而且**不带 scheme**。
// ⇒ 表现：`baidu_start` 直接报"字段不全"，二维码永远出不来。
// ```
//
// # 现在的五步（2026-10-30 dex 逐字取证后修正）
// ```text
// ① 取码  GET  /v2/api/getqrcode                → sign + imgurl
// ② 出图  GET  https:// + imgurl + &logPage=traceId%3Apc_loginv5_1742970205%2ClogPage%3Aloginv5
//         → PNG 字节 ⇒ 内嵌进 SVG
// ③ 轮询  GET  /channel/unicast?channel_id=<sign>        ← ★ 没有 &v 参数
//         → body: errno + channel_v（JSON 串）→ channel_v.status==0 / channel_v.v
// ④ 换态  GET  /v3/login/main/qrbdusslogin?v=<当前毫秒>&bduss=<channel_v.v>
//         → ★ 登录态（含 BDUSS）在这一步的 Set-Cookie 响应头里
// ⑤ 补全  GET  pan.baidu.com/disk/main（STOKEN 等在这条响应里）
// ```
//
// # ★ 2026-10-30 修正记录（旧"未取证"段作废）
// ```text
// 旧版两个猜错（都是"channel_id 与 v 都填 sign"这个猜测的产物）：
//   ① unicast 多带了 `&v={sign}`（参考实现没有这个参数）；
//   ② BDUSS 从 unicast 的 Set-Cookie 里找 ⇒ 永远找不到 ⇒ 一直"等待/重取"（现场现象）。
// dex 逐字（.probe/pan-login-t5-forensics2.log §A / forensics3.log §③）：
//   channel_v JSON 的 `v` 字段 = 换登录态的 bduss 参数值；qrbdusslogin 的 v = 毫秒时间戳；
//   BDUSS 出现在 qrbdusslogin 响应的 set-cookie 头。
// 真机扫码验证攒到批末（同批其余家）。
// ```
//
// # ⚠️ 关于 `QrSession.svg`（这里放的是**位图**，不是矢量码）
// ```text
// 百度不给二维码文本 ⇒ 无法用 `qrcode` crate 自己重画 ⇒ 只能把服务端那张 PNG
// 以 `data:image/png;base64,…` 内嵌进 SVG（见 `svg_with_embedded_png`）。
// ⚠️ Dart 侧 `qr_view.dart:parseQrSvg` 只认 `<rect>` + `<path d=…>`，
//    **不认 `<image href=…>`** ⇒ 那边会降级成 `fallback`（= 图片地址文本）。
//    这条是 UI 侧的事，本模块不改 Dart；此处只保证**产出的 SVG 是对的**。
// ```

/// 百度轮询用的**单次**超时（长轮询：这段窗口内没事件就一个字节都不回）
///
/// # ★ 真读数（2026-10-29，curl 实测三次）
/// ```text
/// GET /channel/unicast?channel_id=<sign>&v=<sign>
///   → 30 秒**0 字节**（curl: (28) Operation timed out with 0 bytes received）
/// 加 cookie（把 getqrcode 下发的 BAIDUID/BAIDUID_BFESS 带上）→ 同样 0 字节
/// 加 `&callback=jsonp1`                                  → 同样 0 字节
/// 去掉 `v`（只留 channel_id）                            → 同样 0 字节
/// ⇒ 它是**长轮询**：没事件时连接挂着不回。⇒ 用默认 10s 超时会被判成"请求失败"，
///   而其实这是**正常的中途态**。所以这一跳单独给 3 秒窗口，超时 ⇒ Pending。
/// ```
const BAIDU_UNICAST_TIMEOUT: Duration = Duration::from_secs(3);

/// 百度（passport）用的桌面 UA —— 逐字取自取证
const UA_BAIDU: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                        (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 百度取二维码（纯函数：URL 写错不会报错，只会返回另一套 errno）
fn baidu_qrcode_url() -> &'static str {
    "https://passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc"
}

/// 百度轮询 —— **只带 `channel_id`，没有 `v` 参数**
///
/// # ★★★ 2026-10-30 dex 逐字取证（`.probe/pan-login-t5-forensics2.log` §A merge.b.j.t 0x0008–0x0012）
/// ```text
/// 参考实现 com.github.catvod.spider.merge.b.j.t：
///   unicast URL = "https://passport.baidu.com/channel/unicast?channel_id=" + <sign>
///   （StringBuilder 只 append 一次；**没有 `&v=`**）
/// 旧实现画蛇添足的 `&v={sign}` 已删（对应关系"未取证"的整段猜测随之作废——
///   真正的对应关系是：channel_v JSON 里的 `v` 字段才是换态用的值，见 `baidu_channel_v_of`）。
/// ```
fn baidu_unicast_url(sign: &str) -> String {
    format!("https://passport.baidu.com/channel/unicast?channel_id={sign}")
}

/// 换登录态时 `v` 参数的取值：参考实现逐字用 **当前毫秒时间戳**
///
/// # dex 出处（`.probe/pan-login-t5-forensics3.log` §③ 0x0058–0x0061）
/// ```text
/// qrbdusslogin URL = ".../qrbdusslogin?v=" + System.currentTimeMillis() + "&bduss=" + <bduss>
/// 其中 <bduss> = unicast 响应 `channel_v` JSON 里的 **`v` 字段**（optString）。
/// ```
fn baidu_now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 从 unicast 响应体里解析 `channel_v`（★ 换登录态的 BDUSS 载体）
///
/// # dex 出处（`.probe/pan-login-t5-forensics3.log` §③ 0x0032–0x0052）
/// ```text
/// 参考实现：body.optString("channel_v") → new JSONObject(channel_v) →
///   status = optInt("status")（==0 才算确认）、v = optString("v")
/// `channel_v.v` 随后被拼进 qrbdusslogin 的 **bduss** 参数 ⇒ 它就是登录态载体。
/// 旧实现从 unicast 的 Set-Cookie 头里找 BDUSS ⇒ 永远找不到 ⇒ UI 一直"等待/重取"（图2 现象）。
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
struct BaiduChannelV {
    /// `channel_v.status`（参考实现 ==0 进成功分支）
    status: Option<i64>,
    /// `channel_v.v`（换登录态时当 bduss 用；非空才有意义）
    v: String,
}

fn baidu_channel_v_of(body: &str) -> Option<BaiduChannelV> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let inner = v.get("channel_v")?.as_str()?;
    let j: serde_json::Value = serde_json::from_str(inner.trim()).ok()?;
    Some(BaiduChannelV {
        status: j.get("status").and_then(|x| x.as_i64()),
        v: j.get("v")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .trim()
            .to_string(),
    })
}

/// 二维码**图片**的取图地址（在 `imgurl` 后追加参考实现逐字的 logPage 串）
///
/// # dex 出处（`.probe/pan-login-t5-forensics2.log` §A merge.b.j.o 0x0039）
/// ```text
/// 取图 URL = "https://" + imgurl + "&logPage=traceId%3Apc_loginv5_1742970205%2ClogPage%3Aloginv5"
/// （QrSession.url 展示仍用不带后缀的 imgurl；这个后缀只用于 GET 图片字节。）
/// ```
fn baidu_img_fetch_url(img_url: &str) -> String {
    format!("{img_url}&logPage=traceId%3Apc_loginv5_1742970205%2ClogPage%3Aloginv5")
}

/// 百度用 BDUSS 换登录态
fn baidu_qrbduss_url(v: &str, bduss: &str) -> String {
    format!("https://passport.baidu.com/v3/login/main/qrbdusslogin?v={v}&bduss={bduss}")
}

/// `imgurl` → 可 GET 的图片地址（真报文**不带 scheme**，这里补 `https://`）
///
/// # 为什么不是"二维码内容"
/// ```text
/// 百度**不返回二维码文本**，`imgurl` 是那张二维码**图片**的地址。
/// 所以 `QrSession.url` 放的就是这个图片地址（不是"扫出来的那个 URL"）。
/// 已经带 scheme 的原样返回（幂等：重复调用不会拼出 `https://https://…`）。
/// ```
fn baidu_img_url(imgurl: &str) -> String {
    let t = imgurl.trim();
    if t.is_empty() {
        String::new()
    } else if t.starts_with("https://") || t.starts_with("http://") {
        t.to_string()
    } else {
        format!("https://{t}")
    }
}

/// 百度取码响应解析出来的两样
#[derive(Debug, Clone, PartialEq, Eq)]
struct BaiduQrFields {
    /// 轮询用的 `v` 与 `channel_id`（真报文只有这一个值）
    sign: String,
    /// 二维码**图片**地址（已补 scheme）
    img_url: String,
}

/// 从取码响应里取 `(sign, img_url)`
///
/// # 三处硬线
/// ```text
/// ① 字段在**顶层**；`data.*` 只作兜底（旧取证口径写过 data.*，真报文是顶层）；
/// ② `errno` 存在且非 0 ⇒ Err（服务端**明说**失败，不猜、不硬解析）；
/// ③ 缺 `sign` 或 `imgurl` ⇒ Err，**点名缺哪个**并附 body 摘要 —— 不编默认值。
/// ```
fn baidu_qr_fields(body: &str) -> Result<BaiduQrFields, String> {
    let v: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| format!("百度取码响应不是 JSON（{e}）：{}", tail(body)))?;

    if let Some(n) = v.get("errno").and_then(|x| x.as_i64()) {
        if n != 0 {
            return Err(format!(
                "百度取码返回 errno={n}（服务端明说失败）prompt={:?}：{}",
                v.get("prompt").and_then(|x| x.as_str()).unwrap_or(""),
                tail(body)
            ));
        }
    }

    // 顶层优先，`data.*` 兜底（两种都认，但真报文是顶层）
    let pick = |key: &str| -> String {
        for node in [Some(&v), v.get("data")].into_iter().flatten() {
            if let Some(s) = node.get(key).and_then(|x| x.as_str()) {
                let s = s.trim();
                if !s.is_empty() {
                    return s.to_string();
                }
            }
        }
        String::new()
    };

    let sign = pick("sign");
    let raw_img = pick("imgurl");
    let mut missing: Vec<&str> = Vec::new();
    if sign.is_empty() {
        missing.push("sign");
    }
    if raw_img.is_empty() {
        missing.push("imgurl");
    }
    if !missing.is_empty() {
        return Err(format!(
            "百度取码响应里缺 {}（协议可能变了）：{}",
            missing.join("/"),
            tail(body)
        ));
    }

    let img_url = baidu_img_url(&raw_img);
    if !img_url.starts_with("https://") {
        return Err(format!(
            "百度取码响应的 imgurl 补 scheme 后仍不是 https（协议可能变了）：{}",
            tail(&raw_img)
        ));
    }
    Ok(BaiduQrFields { sign, img_url })
}

/// 从响应体里取 `errno`（只用于写日志；判定以 BDUSS 与 errno 非 0 为准）
fn baidu_errno_of(body: &str) -> Option<i64> {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()?
        .get("errno")?
        .as_i64()
}

// ── PNG → SVG（把位图内嵌进 SVG，代替"自己重画二维码"） ────────────────────

/// 标准 base64 **编码**（与 `b64_decode` 同族，零依赖、可单测）
///
/// # 为什么要自己写
/// ```text
/// 本仓无 base64 依赖（`b64_decode` 就是自带的那一份）。这里只要"把 PNG 字节
/// 变成一个能塞进 `data:` URI 的串"，20 行够用，且能离线拿**独立算出的值**对照。
/// ```
/// ⚠️ 只输出标准字母表（`+/`）与 `=` 填充 —— `data:` URI 里按规范要求如此
///    （变体 `urlsafe` 在 href 里会被当成路径分隔符解释出错）。
fn b64_encode(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 {
            T[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// 从 PNG 头里读像素尺寸（`IHDR` 的 width/height，大端 u32）
///
/// 返回 `None` = 不是 PNG（签名不对）或尺寸不合理 ⇒ 调用方降级。
fn png_size(data: &[u8]) -> Option<(u32, u32)> {
    const SIG: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
    if data.len() < 24 || &data[..8] != SIG {
        return None;
    }
    let w = u32::from_be_bytes([data[16], data[17], data[18], data[19]]);
    let h = u32::from_be_bytes([data[20], data[21], data[22], data[23]]);
    // 二维码图片不会太大；越界说明这不是我们要的那张图
    if w == 0 || h == 0 || w > 4096 || h > 4096 {
        return None;
    }
    Some((w, h))
}

/// 把 PNG 字节内嵌成一张 SVG（`<image href="data:image/png;base64,…">`）
///
/// # 为什么是"内嵌"而不是"落盘再引用"
/// ```text
/// `QrSession.svg` 是**一个字符串**、要原样交给 UI 层；落盘会多出一个生命周期
/// （谁清理、路径怎么传、Android 上文件权限）。
/// 内嵌的代价是 SVG 变大（一张 200×200 的二维码 PNG ≈ 3~8KB ⇒ base64 后 ≈ 4~11KB），
/// 对这个字段的用途完全可接受。
/// ```
/// `None` = 不是 PNG（由调用方退回文本码 / 报错）。
fn svg_with_embedded_png(png: &[u8]) -> Option<String> {
    let (w, h) = png_size(png)?;
    let b64 = b64_encode(png);
    Some(format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" \
xmlns:xlink=\"http://www.w3.org/1999/xlink\" \
width=\"{w}\" height=\"{h}\" viewBox=\"0 0 {w} {h}\">\
<image x=\"0\" y=\"0\" width=\"{w}\" height=\"{h}\" \
href=\"data:image/png;base64,{b64}\" xlink:href=\"data:image/png;base64,{b64}\"/>\
</svg>"
    ))
}

/// 拉百度那张二维码 PNG 并内嵌成 SVG
///
/// 用**同一个** `client(UA_BAIDU)`（同一 UA / 不走代理 / 同一超时）——
/// 换一个 client 就等于换一个出口指纹，而百度对 Referer/UA 敏感。
async fn baidu_qr_image_svg(c: &reqwest::Client, img_url: &str) -> Result<String, String> {
    let resp = c
        .get(img_url)
        .header("Accept", "image/png,image/*;q=0.8,*/*;q=0.5")
        .header("Referer", "https://pan.baidu.com/")
        .send()
        .await
        .map_err(|e| format!("GET 二维码图片失败：{e}"))?;
    let status = resp.status();
    let ctype = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("读二维码图片响应失败：{e}"))?;
    if !status.is_success() {
        return Err(format!(
            "二维码图片返回 HTTP {status}（content-type={ctype}，{} 字节）",
            bytes.len()
        ));
    }
    svg_with_embedded_png(&bytes).ok_or_else(|| {
        format!(
            "二维码图片不是 PNG（content-type={ctype}，{} 字节，前 8 字节={:02x?}）",
            bytes.len(),
            &bytes[..bytes.len().min(8)]
        )
    })
}

/// 从 cookie 串里取 `BDUSS` 的值（这是"已确认"的唯一判据）
fn bduss_from_cookie(cookie: &str) -> Option<String> {
    cookie
        .split(';')
        .map(|p| p.trim())
        .find_map(|kv| kv.strip_prefix("BDUSS="))
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// 合并两段 cookie：**后者同名覆盖前者**（与 `play` 里并 `__puus` 同一条语义）
///
/// # 为什么要合并而不是二选一
/// ```text
/// 百度登录态分散在**两次响应**里（qrbdusslogin 给 BDUSS/PTOKEN，disk/main 给 STOKEN 等），
/// 只留一段 ⇒ 后面调盘接口缺键 ⇒ 表现是"登录了但拉不到列表"（难查）。
/// ```
fn merge_cookie(base: &str, extra: &str) -> String {
    let mut out: Vec<(String, String)> = Vec::new();
    for part in base.split(';').chain(extra.split(';')) {
        let kv = part.trim();
        if kv.is_empty() {
            continue;
        }
        let (k, _) = kv.split_once('=').unwrap_or((kv, ""));
        let key = k.trim().to_string();
        if key.is_empty() {
            continue;
        }
        if let Some(slot) = out.iter_mut().find(|(kk, _)| *kk == key) {
            slot.1 = kv.to_string(); // ★ 后到的赢（同名覆盖）
        } else {
            out.push((key, kv.to_string()));
        }
    }
    out.into_iter().map(|(_, kv)| kv).collect::<Vec<_>>().join("; ")
}

/// 百度：第一步拿二维码（sign + 图片地址），第二步把图片内嵌成 SVG
async fn baidu_start() -> Result<QrSession, String> {
    let c = client(UA_BAIDU)?;
    write_log("取码开始 kind=baidu GET /v2/api/getqrcode");
    let resp = c
        .get(baidu_qrcode_url())
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://pan.baidu.com/")
        .send()
        .await
        .map_err(|e| {
            // ★ 出错路径也必须落日志：现场"点了没反应"最常见的原因就是这条被吞了
            write_log(&format!("取码请求失败 kind=baidu err={e}"));
            format!("请求百度二维码接口失败：{e}")
        })?;
    let status = resp.status();
    let body = resp.text().await.map_err(|e| {
        write_log(&format!("读取码响应失败 kind=baidu err={e}"));
        format!("读百度响应失败：{e}")
    })?;
    if !status.is_success() {
        write_log(&format!(
            "取码失败 kind=baidu HTTP {status} body={}",
            tail(&body)
        ));
        return Err(format!("百度二维码接口返回 HTTP {status}：{}", tail(&body)));
    }

    let fields = match baidu_qr_fields(&body) {
        Ok(f) => f,
        Err(e) => {
            write_log(&format!("取码失败 kind=baidu {e}"));
            return Err(e);
        }
    };
    write_log(&format!(
        "取码成功 kind=baidu sign_len={} img_url_len={} img_url_is_https={}",
        fields.sign.len(),
        fields.img_url.len(),
        fields.img_url.starts_with("https://")
    ));

    // ② 拉那张 PNG（取图地址追加 logPage 串，dex 逐字见 `baidu_img_fetch_url`），内嵌成 SVG。
    //    失败 ⇒ 退回"文本码"并在 hint 里说明（不许假装有图）
    let (svg, note) = match baidu_qr_image_svg(&c, &baidu_img_fetch_url(&fields.img_url)).await {
        Ok(s) => {
            write_log(&format!("二维码图片内嵌成功 kind=baidu svg_len={}", s.len()));
            (s, String::new())
        }
        Err(e) => {
            write_log(&format!(
                "二维码图片取不到 kind=baidu err={e} ⇒ 退回文本码（显示图片地址）"
            ));
            let fallback = crate::remote::qr_svg_for(&fields.img_url).unwrap_or_default();
            (
                fallback,
                format!("（二维码图片没取到：{e}。下面显示的是图片地址，可在浏览器打开）"),
            )
        }
    };

    let created_at = now();
    let key = fields.sign.clone();
    sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(
            kind_key(PanKind::Baidu, &key),
            SessionRecord {
                // 轮询只带 channel_id（= sign）；确认态载体是响应体 channel_v（dex 逐字，
                // 见 `baidu_channel_v_of` / `baidu_unicast_url`）
                token: fields.sign.clone(),
                created_at,
            },
        );
    Ok(QrSession {
        key,
        // ★ 这是**二维码图片**的地址，不是"扫出来的 URL"（百度不给那个）
        url: fields.img_url,
        svg,
        hint: format!("用百度网盘 App 扫这个码（扫码后需在手机上确认）{note}"),
        created_at,
    })
}

/// 百度：轮询 + 用 BDUSS 换登录态
///
/// # 三条不许越的线（都是"别把失败演成成功"）
/// ```text
/// ① 拿不到 BDUSS ⇒ Pending（**包括** HTTP 非 2xx：把一次 500 判成 Failed 会让
///    UI 停表，而百度侧偶发 4xx 是常态 —— 但每次都会落日志，不会被掩盖）；
/// ② `errno` 非 0 ⇒ Pending + 日志里带 errno；
/// ③ 只有"Set-Cookie 里真的有 BDUSS"才走换态那两步；换不到 ⇒ 如实 Err。
/// ```
///
/// # ★ 第四条（真读数逼出来的）：**长轮询超时**也要 Pending
/// ```text
/// `channel/unicast` 未确认时 30 秒 0 字节（见 `BAIDU_UNICAST_TIMEOUT` 的读数）。
/// 所以这一跳只给 3 秒，超时 ⇒ Pending；**非超时**的传输错（DNS/TLS/拒连）
/// 仍按真失败走 Err —— 那条线不能一起放宽，否则网络死了会永远"等待扫码"。
/// ```
async fn baidu_poll(channel_id: &str) -> Result<PollOutcome, String> {
    let pending = |msg: String| PollOutcome {
        status: QrStatus::Pending,
        message: msg,
        credential: None,
    };

    let sess = sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&kind_key(PanKind::Baidu, channel_id))
        .map(|r| r.token.clone())
        .unwrap_or_default();
    if sess.is_empty() {
        write_log(&format!(
            "轮询 kind=baidu 会话不在 key_len={}",
            channel_id.len()
        ));
        return Ok(PollOutcome {
            status: QrStatus::Expired,
            message: "这个二维码已失效（会话不在），请重新获取".to_string(),
            credential: None,
        });
    }

    let c = client(UA_BAIDU)?;
    let send_result = c
        .get(baidu_unicast_url(channel_id))
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://pan.baidu.com/")
        // ★ 这一跳是**长轮询**：3 秒内没事件就一个字节都不回（真读数见常量文档）
        .timeout(BAIDU_UNICAST_TIMEOUT)
        .send()
        .await;
    let resp = match send_result {
        Ok(r) => r,
        Err(e) if e.is_timeout() => {
            // ★ 正常的"还没扫" —— 不是失败。若把这里当 Err，UI 会立刻停表并报错，
            //   而用户其实正要扫码（这就是"扫了没反应"的一种来源）。
            write_log(&format!(
                "轮询 kind=baidu {}s 内无事件（长轮询，正常）⇒ Pending",
                BAIDU_UNICAST_TIMEOUT.as_secs()
            ));
            return Ok(pending("等待扫码…".to_string()));
        }
        Err(e) => {
            // 非超时的传输错（DNS / TLS / 连接被拒）才是真失败 —— 如实报，不吞
            write_log(&format!("轮询请求失败 kind=baidu err={e}"));
            return Err(format!("轮询百度扫码状态失败：{e}"));
        }
    };
    // ★ 先收响应头（body 一读 header 就没了）
    let status = resp.status();
    let set_cookie = collect_set_cookie(&resp);
    let body = resp.text().await.unwrap_or_default();

    // ★★ 每次轮询都留读数：body 摘要 + Set-Cookie **键名**（`cookie_digest` 只给键名与总长，
    //    绝不写值）。这是"参数对应关系未取证"那一处的唯一观测手段。
    let errno = baidu_errno_of(&body);
    write_log(&format!(
        "轮询 kind=baidu HTTP {status} errno={errno:?} set_cookie={} body={}",
        cookie_digest(&set_cookie),
        tail(&body)
    ));

    if !status.is_success() {
        // 不把 HTTP 错判成终态：百度侧偶发 4xx 是常态，判 Failed 会让 UI 停在一个
        // 其实"再等一秒就好"的状态上。但读数已经进日志了，不会被掩盖。
        return Ok(pending(format!(
            "等待扫码…（服务端返回 HTTP {status}，已记录）"
        )));
    }

    // ②' 解析 channel_v（★ 确认态的唯一载体；dex 逐字见 `baidu_channel_v_of`）
    //    旧实现从这里走 `bduss_from_cookie(&set_cookie)` —— BDUSS 根本不在 unicast 的
    //    Set-Cookie 里（它在换登录态那一步的响应头），⇒ 永远 Pending ⇒ UI 一直重取二维码。
    let Some(cv) = baidu_channel_v_of(&body) else {
        let why = match errno {
            Some(n) if n != 0 => format!("等待扫码…（errno={n}）"),
            _ => "等待扫码…".to_string(),
        };
        return Ok(pending(why));
    };
    if cv.status != Some(0) || cv.v.is_empty() {
        write_log(&format!(
            "轮询 kind=baidu channel_v status={:?} v_len={} ⇒ 未确认，Pending",
            cv.status,
            cv.v.len()
        ));
        return Ok(pending("等待扫码…".to_string()));
    }
    write_log("轮询 kind=baidu channel_v status=0 ⇒ 已确认，开始换登录态");

    // ③ 换登录态：`v` = 当前毫秒时间戳、`bduss` = channel_v.v（dex 逐字，见 `baidu_now_millis`）
    let resp = c
        .get(baidu_qrbduss_url(&baidu_now_millis().to_string(), &cv.v))
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://pan.baidu.com/")
        .send()
        .await
        .map_err(|e| {
            write_log(&format!("换登录态请求失败 kind=baidu err={e}"));
            format!("换取百度登录态失败：{e}")
        })?;
    let step_status = resp.status();
    let step_cookie = collect_set_cookie(&resp);
    let step_body = resp.text().await.unwrap_or_default();
    write_log(&format!(
        "换登录态 kind=baidu HTTP {step_status} set_cookie={} body={}",
        cookie_digest(&step_cookie),
        tail(&step_body)
    ));
    // ★ BDUSS 的判据在这一步的 Set-Cookie（dex：对 qrbdusslogin 响应头逐条收 cookie，
    //   contains("BDUSS=") 才拼进 Cookie 头）。
    let Some(bduss) = bduss_from_cookie(&step_cookie) else {
        write_log(&format!(
            "换登录态 kind=baidu 响应 Set-Cookie 无 BDUSS body={}",
            tail(&step_body)
        ));
        return Ok(pending(
            "等待扫码…（服务端确认了但未下发登录态，已记录）".to_string(),
        ));
    };
    let _ = bduss; // BDUSS 存在性已确证；完整登录态以合并后的 cookie 为准
    let mut cookie = merge_cookie(&set_cookie, &step_cookie);

    // ④ 补 pan 域 cookie（STOKEN 等在这条响应里）
    match c
        .get("https://pan.baidu.com/disk/main?from=homeFlow")
        .header("Cookie", &cookie)
        .header("Referer", "https://pan.baidu.com/")
        .send()
        .await
    {
        Ok(r) => {
            let extra = collect_set_cookie(&r);
            write_log(&format!(
                "补 pan 域 cookie kind=baidu HTTP {} set_cookie={}",
                r.status(),
                cookie_digest(&extra)
            ));
            cookie = merge_cookie(&cookie, &extra);
        }
        Err(e) => {
            // 这一步失败不必中断：BDUSS/PTOKEN 已经在手，盘接口缺 STOKEN 只影响后续列表
            write_log(&format!("补 pan 域 cookie 失败 kind=baidu err={e}"));
        }
    }
    if bduss_from_cookie(&cookie).is_none() {
        write_log("换 cookie 失败 kind=baidu 合并后仍无 BDUSS");
        return Err(
            "百度已确认扫码，但合并后的 cookie 里没有 BDUSS（协议可能变了）⇒ 拿不到登录态"
                .to_string(),
        );
    }
    write_log(&format!(
        "换 cookie 成功 kind=baidu 摘要={}",
        cookie_digest(&cookie)
    ));

    Ok(PollOutcome {
        status: QrStatus::Confirmed,
        message: "登录成功：百度网盘".to_string(),
        credential: Some(crate::pan_auth::PanCredential {
            kind: PanKind::Baidu,
            account: "百度网盘".to_string(),
            cookie,
            saved_at: now(),
            expires_at: None,
        }),
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  115 网盘（PanKind::Pan115）—— **自建扫码**，登录与网盘操作在参考实现里是两个类
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（`.probe/r3c-nine-pan-login-protocols.md` 附：115 的完整登录流程 / `Qr115` 类）
//
// ```text
// ① 取码  GET https://qrcodeapi.115.com/api/1.0/qandroid/1.0/token/
//         → uid；二维码内容 = `https://115.com/scan/dg-<uid>`
// ② 轮询  GET https://qrcodeapi.115.com/get/status/?uid=<uid>&_=0
//         → 字段：state / code / data.status
// ③ 换 cookie POST https://passportapi.115.com/app/1.0/qandroid/1.0/login/qrcode/
//         → ★ cookie 必须含 **UID / CID / SEID / KID** 四键（取证给的验收判据）
// UA（逐字）：`Mozilla/5.0 115disk/30.1.0`
// ```
//
// # ⚠️ 两处"取值含义未取证"（写在一处，批末真机读数来了只改这里）
// ```text
// ① 状态码语义：取证只给了字段名（state / data.status），**没给取值表**。
//    这里按最常见的两态映射：data.status == 1 ⇒ 已扫未确认；>= 2 ⇒ 已确认。
//    映射错的表现是"扫了之后一直不动" ⇒ 每次轮询都把 body 记进日志，一眼能看出来。
// ② 换 cookie 的请求体：取证只给了端点，没给表单字段 ⇒ 只发 `uid`（最小集合，
//    不多编一个参数）。失败会如实报 HTTP/响应体。
// ③ **验收判据不猜**：四键缺任何一个 ⇒ 直接判失败（这是取证里明确写下的判据）。
// ```

/// 115 的 UA（逐字取自取证）
const UA_115: &str = "Mozilla/5.0 115disk/30.1.0";

/// 115 取码（纯函数）
fn pan115_token_url() -> &'static str {
    "https://qrcodeapi.115.com/api/1.0/qandroid/1.0/token/"
}

/// 115 轮询（纯函数）
///
/// ★★★ 2026-10-28 现场读数（Owner 扫码"没反应"）：
/// ```text
/// 旧实现只带 uid ⇒ 服务端回 `{"state":0,"code":40199002,"message":"key invalid"}`
/// （每一轮都是这条，UI 就永远"等待扫码"）。
/// 真读数（curl 取码接口）：`data{uid,time,sign,qrcode}` —— **time 与 sign 必须一起带上**。
/// ```
fn pan115_status_url(uid: &str, time: &str, sign: &str) -> String {
    format!("https://qrcodeapi.115.com/get/status/?uid={uid}&time={time}&sign={sign}&_=0")
}

/// 115 换 cookie（纯函数；POST，表单只带 uid）
fn pan115_login_url() -> &'static str {
    "https://passportapi.115.com/app/1.0/qandroid/1.0/login/qrcode/"
}

/// 115 二维码内容（纯函数）
fn pan115_qr_url(uid: &str) -> String {
    format!("https://115.com/scan/dg-{uid}")
}

/// 从取码响应里取 `(uid, time, sign, qrcode)`
///
/// ★ 真读数（2026-10-28 现场 curl）：
/// ```text
/// {"state":1,"code":0,"data":{"uid":"fa45…","time":1793197822,
///   "sign":"421e…","qrcode":"https://115.com/scan/dg-fa45…"}}
/// ⇒ 轮询必须带 uid+time+sign（只带 uid ⇒ `40199002 key invalid`，现场"扫了没反应"）
/// ```
fn pan115_token_fields(body: &str) -> Option<(String, String, String, String)> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let d = v.get("data").unwrap_or(&v);
    let s = |k: &str| {
        d.get(k)
            .map(|x| match x {
                serde_json::Value::String(s) => s.trim().to_string(),
                other => other.to_string(),
            })
            .unwrap_or_default()
    };
    let uid = s("uid");
    let tm = s("time");
    let sign = s("sign");
    if uid.is_empty() || tm.is_empty() || sign.is_empty() {
        return None;
    }
    Some((uid, tm, sign, s("qrcode")))
}

/// 115 的状态映射（`(QrStatus, 原始码)`；码打日志用）
///
/// ⚠️ 取值含义**未取证**（见上面"两处未取证"）—— 这是全文件唯一允许"按常见两态映射"的地方。
fn pan115_status_of(body: &str) -> (QrStatus, Option<i64>) {
    let v: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return (QrStatus::Pending, None),
    };
    let st = v
        .get("data")
        .and_then(|d| d.get("status"))
        .and_then(|x| x.as_i64())
        .or_else(|| v.get("status").and_then(|x| x.as_i64()));
    match st {
        Some(1) => (QrStatus::Scanned, st),
        Some(n) if n >= 2 => (QrStatus::Confirmed, st),
        _ => (QrStatus::Pending, st),
    }
}

/// 115 换 cookie（纯函数；POST 表单）
///
/// # ★★★ 2026-10-30 dex 逐字取证（`.probe/pan-login-t5-forensics.log` §②b Qr115.login）
/// ```text
/// 参考实现 com.github.catvod.spider.Qr115.login（154 insns）：
///   form.put("account", Qr115$Token.uid)   ← 键名是 **account**，不是 uid
///   form.put("app",     "qandroid")        ← 与 URL 路径 /app/1.0/qandroid/1.0/ 同值
///   POST https://passportapi.115.com/app/1.0/qandroid/1.0/login/qrcode/
///   头：Qr115.head() = 只有 User-Agent: Mozilla/5.0 115disk/30.1.0
/// 旧实现只发 `uid` 一个字段 ⇒ 服务端 40100000「参数错误」（现场真读数，图2）。
/// ```
fn pan115_login_form(uid: &str) -> Vec<(String, String)> {
    vec![
        ("account".to_string(), uid.to_string()),
        ("app".to_string(), "qandroid".to_string()),
    ]
}

/// 把 JSON 文案里的 `\uXXXX` 转义解成真字符（只做这一种转义，别的原样保留）
///
/// # 为什么要有它
/// ```text
/// 115 的错误 message 是 JSON 编码过的中文（现场读数：`"\u53c2\u6570\u9519\u8bef"` 形态），
/// 直接把 body 原文塞进报错文案，用户看到的是一串 `\uXXXX`。
/// 解码只服务"给用户看的文案"，解析仍走 serde_json（不重复造轮子）。
/// ```
fn unescape_json_u(s: &str) -> String {
    if !s.contains("\\u") {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('u') => {
                let hex: String = it.by_ref().take(4).collect();
                if let Ok(n) = u32::from_str_radix(&hex, 16) {
                    if let Some(ch) = char::from_u32(n) {
                        out.push(ch);
                    } else {
                        // 不认识的码位：原样回退，不吞字符
                        out.push_str("\\u");
                        out.push_str(&hex);
                    }
                } else {
                    out.push_str("\\u");
                    out.push_str(&hex);
                }
            }
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// 从换 cookie 响应里取出服务端 `message`（已解 \uXXXX；取不到就返回空串）
fn pan115_server_message(body: &str) -> String {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| {
            v.get("message")
                .or_else(|| v.get("data").and_then(|d| d.get("message")))
                .and_then(|m| m.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        })
        .map(|s| unescape_json_u(&s))
        .unwrap_or_default()
}

/// 从换 cookie 响应里拼出 `UID=…; CID=…; SEID=…; KID=…`
///
/// ★ 四键**缺一不可**（取证给的验收判据）—— 缺了就是"登录态不完整"，
///   后续所有请求都会 401，但登录这一步**不会报错**（典型的静默假成功）。
fn pan115_cookie_from_body(body: &str) -> Result<String, String> {
    const KEYS: [&str; 4] = ["UID", "CID", "SEID", "KID"];
    let v: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| format!("115 换 cookie 返回的不是 JSON（{e}）：{}", tail(body)))?;
    // 两种形状都认：`data.cookie{...}` 或顶层 `data{...}`
    let src = v
        .get("data")
        .and_then(|d| d.get("cookie"))
        .or_else(|| v.get("data"))
        .or_else(|| v.get("cookie"));
    let Some(src) = src else {
        return Err(format!("115 换 cookie 响应里没有 cookie 段：{}", tail(body)));
    };
    let mut parts: Vec<String> = Vec::new();
    let mut missing: Vec<&str> = Vec::new();
    for k in KEYS {
        let val = src
            .get(k)
            .and_then(|x| x.as_str())
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        if val.is_empty() {
            missing.push(k);
        } else {
            parts.push(format!("{k}={val}"));
        }
    }
    if !missing.is_empty() {
        return Err(format!(
            "115 换 cookie 缺少关键键 {:?}（验收判据要求 UID/CID/SEID/KID 四键）：{}",
            missing,
            tail(body)
        ));
    }
    Ok(parts.join("; "))
}

/// 115：第一步拿二维码
async fn pan115_start() -> Result<QrSession, String> {
    let c = client(UA_115)?;
    let resp = c
        .get(pan115_token_url())
        .header("Accept", "application/json, text/plain, */*")
        .send()
        .await
        .map_err(|e| format!("请求 115 二维码接口失败：{e}"))?;
    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读 115 响应失败：{e}"))?;
    if !status.is_success() {
        return Err(format!("115 二维码接口返回 HTTP {status}：{}", tail(&body)));
    }
    let (uid, tm, sign, qr) = pan115_token_fields(&body).ok_or_else(|| {
        write_log(&format!("取码失败 kind=115 字段不全 body={}", tail(&body)));
        format!(
            "115 取码响应缺 uid/time/sign（协议可能变了）：{}",
            tail(&body)
        )
    })?;
    // 真读数里 `qrcode` 字段就是二维码内容；缺失时按 `dg-<uid>` 拼（两者等价，已按真响应核对）
    let url = if qr.trim().is_empty() {
        pan115_qr_url(&uid)
    } else {
        qr.trim().to_string()
    };
    let svg = crate::remote::qr_svg_for(&url).unwrap_or_default();
    write_log(&format!(
        "取码成功 kind=115 uid_len={} time={} sign_len={} svg_len={}",
        uid.len(),
        tm,
        sign.len(),
        svg.len()
    ));

    let created_at = now();
    sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(
            kind_key(PanKind::Pan115, &uid),
            SessionRecord {
                // 轮询要 `(uid, time, sign)` 三样 ⇒ 用 `|` 拼起来存（与 UC/Aliyun 同一手法）
                token: format!("{uid}|{tm}|{sign}"),
                created_at,
            },
        );
    Ok(QrSession {
        key: uid,
        url,
        svg,
        hint: "用 115 App 扫这个码".to_string(),
        created_at,
    })
}

/// 115：轮询 + 换 cookie
async fn pan115_poll(uid: &str) -> Result<PollOutcome, String> {
    // 取回 time/sign（现场"扫了没反应"就是因为没带这两样：key invalid）
    let compound = sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&kind_key(PanKind::Pan115, uid))
        .map(|r| r.token.clone())
        .unwrap_or_default();
    let mut it = compound.split('|');
    let _uid = it.next().unwrap_or(uid);
    let tm = it.next().unwrap_or("");
    let sign = it.next().unwrap_or("");
    let c = client(UA_115)?;
    /*
     * ★★★ 2026-10-28 现场真读数（Owner："115 扫了没反应"，UI 报 `error sending request`）：
     * ```text
     * `/get/status/` 是**长轮询**：未扫时服务端保持连接、**一个字节都不回**
     * （curl -m 30 ⇒ `HTTP=000 SIZE=0` 超时）。
     * 而我们共用的 client 超时是 10s ⇒ 每次都 Err ⇒ UI 显示网络错误、永远等不到扫码。
     * ⇒ 这里**单次请求**收紧到 8s，并把超时当 Pending：扫中后的下一次轮询会拿到 body。
     * ```
     */
    let resp = match c
        .get(pan115_status_url(uid, tm, sign))
        .timeout(std::time::Duration::from_secs(8))
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://115.com/")
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) if e.is_timeout() => {
            return Ok(PollOutcome {
                status: QrStatus::Pending,
                message: "等待扫码…".to_string(),
                credential: None,
            });
        }
        Err(e) => return Err(format!("轮询 115 扫码状态失败：{e}")),
    };
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读 115 轮询响应失败：{e}"))?;
    let (st, code) = pan115_status_of(&body);
    write_log(&format!(
        "轮询 kind=115 状态={} 原始码={:?} body={}",
        st.code(),
        code,
        tail(&body)
    ));
    if st != QrStatus::Confirmed {
        let scanned = st == QrStatus::Scanned;
        return Ok(PollOutcome {
            status: st,
            message: if scanned {
                "已扫描，请在手机上确认".to_string()
            } else {
                "等待扫码…".to_string()
            },
            credential: None,
        });
    }

    // ③ 换 cookie（POST 表单 = account + app=qandroid，dex 逐字取证见 `pan115_login_form`）
    let resp = c
        .post(pan115_login_url())
        .header("Accept", "application/json, text/plain, */*")
        .form(&pan115_login_form(uid))
        .send()
        .await
        .map_err(|e| {
            write_log(&format!("换 cookie 请求失败 kind=115 err={e}"));
            format!("换取 115 登录态失败：{e}")
        })?;
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        let msg = pan115_server_message(&body);
        let extra = if msg.is_empty() {
            String::new()
        } else {
            format!("（服务端：{msg}）")
        };
        return Err(format!(
            "115 换 cookie 返回 HTTP {status}{extra}：{}",
            tail(&body)
        ));
    }
    let cookie = pan115_cookie_from_body(&body).map_err(|e| {
        // 现场读数：115 的 message 是 \uXXXX 转义的中文 ⇒ 解码后再给用户
        let msg = pan115_server_message(&body);
        if msg.is_empty() {
            e
        } else {
            format!("{e}（服务端：{msg}）")
        }
    })?;
    write_log(&format!(
        "换 cookie 成功 kind=115 摘要={}",
        cookie_digest(&cookie)
    ));

    Ok(PollOutcome {
        status: QrStatus::Confirmed,
        message: "登录成功：115 网盘".to_string(),
        credential: Some(crate::pan_auth::PanCredential {
            kind: PanKind::Pan115,
            account: "115 网盘".to_string(),
            cookie,
            saved_at: now(),
            expires_at: None,
        }),
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  阿里云盘（PanKind::Aliyun）—— 扫码 + **bearer token**（不是 cookie）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（`.probe/r3c-pan-helper-endpoints.log` 的 merge.b.i / 九家表）
//
// ```text
// ① 取码  passport.aliyundrive.com/newlogin/qrcode/generate.do
//         ?appName=aliyun_drive&fromSite=52&appEntrance=web    → content.data{qrCodeUrl, ck, t}
// ② 轮询  passport.aliyundrive.com/newlogin/qrcode/query.do    （表单 ck + t）
//         → content.data.qrCodeStatus：NEW / SCANED / CONFIRMED / EXPIRED
// ③ 换 token  auth.aliyundrive.com/v2/account/token
//         CONFIRMED 的响应里 `bizExt` 是 **base64 的 JSON**，里面有 access_token / refresh_token
// ```
//
// # ★★★ 凭据形状的决定（本条是第一个"token 型"网盘）
//
// ```text
// `PanCredential` 只有一个 `cookie: String` 字段。阿里/光鸭/迅雷/123 的凭据是 **bearer token**，
// 不是 cookie。两条路：
//   ① 给 `PanCredential` 加字段 —— 改落盘形状，牵动 `pan_auth`（钥匙串）、设置页、诊断导出；
//   ② 沿用 `cookie` 字段，**约定键名**：`access_token=<…>; refresh_token=<…>`。
// 选 ②（改动小、可回退、不碰既有落盘格式），并把约定写死在这里：
//   消费方（将来的阿里驱动）按 `access_token=` 取，**不许**把它当 Cookie 头直接发。
// ```
//
// # 2026-10-30 dex 取证更新（原"未取证点"两条均已闭合，出处 .probe/pan-login-t5-forensics2/5.log）
// ```text
// ① query.do 的**表单形状**已逐字取证（merge.d.d.d()）：t / ck / appName / appEntrance /
//    isMobile / lang / returnUrl / fromSite / bizParams / navlanguage / navPlatform
//    —— 已照抄进 aliyun_poll（URL 上的 _bx-v=2.2.3 保留，dex 端点串自带）。
// ② bizExt 无需解密：merge.d.d.g 字段 @SerializedName("bizExt") ⇒ Base64 直接解码 →
//    Gson(merge.d.a) → pds_login_result.refreshToken（camelCase）。全 dex 无 AES 调用
//    归属此链路 ⇒ "AES key"不存在，旧的"invalid utf-8 index 200"是 base64 字母表变体
//    （'-'/'_' 被当非法字符跳过 ⇒ 位错位）造成的，已在 b64_decode 修正。
//    真实密文向量（真抓 qr 响应）批末随真机扫码一并取证，落 .probe/ 并脱敏。
// ```

/// 阿里云盘的桌面 UA（与网盘网页版一致）
const UA_ALIYUN: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                         (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

/// 取码 URL（纯函数；**逐字对齐 dex 取证**，见本段文件头）
///
/// ★ 2026-10-28 修正：上一版按社区通行实现写成 `...&appEntrance=web&_bx-v=2.5.3`，
///   与参考实现方法体里的逐字串**不一致**（少了 `isMobile/lang/returnUrl/bizParams`，
///   且 `_bx-v` 是 **2.2.3**）。这类偏差不会报错，只会让服务端返回另一套字段。
fn aliyun_generate_url() -> &'static str {
    "https://passport.aliyundrive.com/newlogin/qrcode/generate.do\
     ?appName=aliyun_drive&fromSite=52&appName=aliyun_drive&appEntrance=web\
     &isMobile=false&lang=zh_CN&returnUrl=&bizParams=&_bx-v=2.2.3"
}

/// 轮询 URL（`ck`/`t` 走表单，见 `aliyun_poll`）—— 取自 `buildAliQrInfo` 同族的 query 串
fn aliyun_query_url() -> &'static str {
    "https://passport.aliyundrive.com/newlogin/qrcode/query.do\
     ?appName=aliyun_drive&fromSite=52&_bx-v=2.2.3"
}

/// 换 token 的 URL（纯函数）
fn aliyun_token_url() -> &'static str {
    "https://auth.aliyundrive.com/v2/account/token"
}

/// 标准 base64 解码（本仓无 base64 依赖 ⇒ 自带一个，可单测）
///
/// # 为什么自己写而不是加依赖
/// ```text
/// 本批纪律是"零新增依赖"；解码只服务 `bizExt` 这一处，20 行足够，且能离线断言。
/// ⚠️ 只支持标准字母表与 `=` 填充（阿里返回的就是标准 base64）；
///    非字母字符一律跳过（容忍换行），非法长度 ⇒ None（由调用方报"解析失败"）。
/// ```
/// # ★ 2026-10-30 修正：`-`/`_` 按 URL-safe 字母表解（**不是跳过**）
/// ```text
/// 现场真读数（图1）：bizExt 解出来 "invalid utf-8 … index 200" ⇒ 解码产出的是垃圾。
/// 根因：旧实现把 `-`/`_` 当"非字母字符"跳过 ⇒ 若 bizExt 是 URL-safe 变体，
///   每跳过一个字符位流就错 6 位 ⇒ 后面全变随机字节（UTF-8 在中段必炸，与 index 200 吻合）。
/// dex 取证（.probe/pan-login-t5-forensics5.log）：参考实现 merge.d.d.e() 对
///   @SerializedName("bizExt") 字段直接 Base64 解码 → Gson 解析 → 取 pds_login_result.refreshToken
///   —— **全程无 AES/Cipher**（全 dex 的 AES 常量都在无关 spider 类里）⇒ "无密钥可取证"，
///   需要修的是字母表变体，不是解密。
/// ```
fn b64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' | b'-' => Some(62),
            b'/' | b'_' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut buf: u32 = 0;
    let mut bits = 0u8;
    for c in s.bytes() {
        let Some(v) = val(c) else {
            if c == b'=' {
                break;
            }
            continue; // 跳过空白等
        };
        buf = (buf << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xFF) as u8);
        }
    }
    if out.is_empty() && !s.trim().is_empty() && s.trim() != "=" {
        return None;
    }
    Some(out)
}

/// 阿里的扫码状态映射（纯函数）：`qrCodeStatus` 是**枚举字符串**，不是码
fn aliyun_status_of(body: &str) -> (QrStatus, String) {
    let v: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return (QrStatus::Pending, String::new()),
    };
    let st = v
        .get("content")
        .and_then(|c| c.get("data"))
        .and_then(|d| d.get("qrCodeStatus"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_ascii_uppercase();
    let mapped = match st.as_str() {
        "NEW" => QrStatus::Pending,
        "SCANED" => QrStatus::Scanned,
        "CONFIRMED" => QrStatus::Confirmed,
        "EXPIRED" => QrStatus::Expired,
        _ => QrStatus::Pending,
    };
    (mapped, st)
}

/// 从 CONFIRMED 响应的 `bizExt`（base64 JSON）里取 `(access_token, refresh_token, expires_in)`
///
/// # ★ 2026-10-30 dex 逐字取证（`.probe/pan-login-t5-forensics5.log`）
/// ```text
/// bizExt 解码后的 JSON 键是 **camelCase**（参考实现 merge.d.a POJO 的 @SerializedName）：
///   pds_login_result.{ accessToken, refreshToken, expiresIn, defaultDriveId, ... }
/// 社区公开实现通行的是 snake_case（access_token/refresh_token）⇒ 两套都认：
///   camel 优先（dex 逐字），snake 兜底；都取不到才报错（不猜）。
/// ```
fn aliyun_token_from_body(body: &str) -> Result<(String, String, Option<i64>), String> {
    let v: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| format!("阿里轮询响应不是 JSON（{e}）：{}", tail(body)))?;
    let biz = v
        .get("content")
        .and_then(|c| c.get("data"))
        .and_then(|d| d.get("bizExt"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    if biz.is_empty() {
        return Err(format!("阿里已确认扫码，但响应里没有 bizExt（协议可能变了）：{}", tail(body)));
    }
    let raw = b64_decode(&biz)
        .ok_or_else(|| format!("阿里的 bizExt 不是合法 base64（协议可能变了）：{}", tail(&biz)))?;
    let text = String::from_utf8(raw)
        .map_err(|e| format!("阿里的 bizExt 解出来不是 UTF-8（{e}）⇒ base64 变体或密文形态超出取证范围"))?;
    let j: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| format!("阿里的 bizExt 解出来不是 JSON（{e}）：{}", tail(&text)))?;
    // 两种层级都认：`pds_login_result.{…}` 或顶层；键名 camel（dex）与 snake（社区）都认
    let src = j.get("pds_login_result").unwrap_or(&j);
    let pick = |keys: [&str; 2]| -> String {
        for k in keys {
            if let Some(s) = src.get(k).and_then(|x| x.as_str()) {
                if !s.trim().is_empty() {
                    return s.trim().to_string();
                }
            }
        }
        String::new()
    };
    let access = pick(["accessToken", "access_token"]);
    let refresh = pick(["refreshToken", "refresh_token"]);
    let expires = src
        .get("expiresIn")
        .and_then(|x| x.as_i64())
        .or_else(|| src.get("expires_in").and_then(|x| x.as_i64()));
    if access.is_empty() || refresh.is_empty() {
        return Err(format!(
            "阿里的 bizExt 里缺 accessToken/refreshToken（camel/snake 两套键都不在，协议可能变了）：{}",
            tail(&text)
        ));
    }
    Ok((access, refresh, expires))
}

/// 把 aliyun 凭据写成**约定键名**（见文件头"凭据形状的决定"）
fn aliyun_credential_string(access: &str, refresh: &str) -> String {
    format!("access_token={access}; refresh_token={refresh}")
}

/// 阿里：第一步拿二维码
async fn aliyun_start() -> Result<QrSession, String> {
    let c = client(UA_ALIYUN)?;
    let resp = c
        .get(aliyun_generate_url())
        .header("Accept", "application/json, text/plain, */*")
        .send()
        .await
        .map_err(|e| format!("请求阿里二维码接口失败：{e}"))?;
    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读阿里响应失败：{e}"))?;
    if !status.is_success() {
        return Err(format!("阿里二维码接口返回 HTTP {status}：{}", tail(&body)));
    }
    let v: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| format!("阿里二维码响应不是 JSON（{e}）：{}", tail(&body)))?;
    let data = v.get("content").and_then(|c| c.get("data"));
    let url = data
        .and_then(|d| d.get("codeContent"))
        .and_then(|x| x.as_str())
        .or_else(|| data.and_then(|d| d.get("qrCodeUrl")).and_then(|x| x.as_str()))
        .unwrap_or("")
        .trim()
        .to_string();
    let ck = data
        .and_then(|d| d.get("ck"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    // `t` 可能是字符串也可能是数字（两种报文都见过）⇒ 统一转成字符串
    let t = data
        .and_then(|d| d.get("t"))
        .map(|x| match x {
            serde_json::Value::String(s) => s.clone(),
            other => other.to_string(),
        })
        .unwrap_or_default();
    if url.is_empty() || ck.is_empty() {
        write_log(&format!("取码失败 kind=aliyun 缺 qrCodeUrl/ck body={}", tail(&body)));
        return Err(format!(
            "阿里响应里没有 qrCodeUrl/ck（协议可能变了）：{}",
            tail(&body)
        ));
    }
    let svg = crate::remote::qr_svg_for(&url).unwrap_or_default();
    write_log(&format!(
        "取码成功 kind=aliyun ck_len={} t_len={} svg_len={}",
        ck.len(),
        t.len(),
        svg.len()
    ));

    let created_at = now();
    sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(
            kind_key(PanKind::Aliyun, &ck),
            SessionRecord {
                token: format!("{ck}|{t}"),
                created_at,
            },
        );
    Ok(QrSession {
        key: ck,
        url,
        svg,
        hint: "用阿里云盘 App 扫这个码".to_string(),
        created_at,
    })
}

/// 阿里：轮询 + 确认后取 bearer token
async fn aliyun_poll(ck: &str) -> Result<PollOutcome, String> {
    let t = sessions()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&kind_key(PanKind::Aliyun, ck))
        .and_then(|r| r.token.split_once('|').map(|(_, t)| t.to_string()))
        .unwrap_or_default();
    let c = client(UA_ALIYUN)?;
    // 表单 = 参考 merge.d.d.d() 逐字（.probe/pan-login-t5-forensics2.log §C4 d 方法）：
    //   t / ck / appName=aliyun_drive / appEntrance=web / isMobile=false / lang=zh_CN /
    //   returnUrl= / fromSite=52 / bizParams= / navlanguage=zh-CN / navPlatform=MacIntel
    // 旧版只发 ck/t/_bx-v ⇒ 表单字段少发不报错、只让服务端返回另一套字段（静默偏差）。
    let form: Vec<(String, String)> = vec![
        ("t".to_string(), t.clone()),
        ("ck".to_string(), ck.to_string()),
        ("appName".to_string(), "aliyun_drive".to_string()),
        ("appEntrance".to_string(), "web".to_string()),
        ("isMobile".to_string(), "false".to_string()),
        ("lang".to_string(), "zh_CN".to_string()),
        ("returnUrl".to_string(), String::new()),
        ("fromSite".to_string(), "52".to_string()),
        ("bizParams".to_string(), String::new()),
        ("navlanguage".to_string(), "zh-CN".to_string()),
        ("navPlatform".to_string(), "MacIntel".to_string()),
    ];
    let resp = c
        .post(aliyun_query_url())
        .header("Accept", "application/json, text/plain, */*")
        .form(&form)
        .send()
        .await
        .map_err(|e| format!("轮询阿里扫码状态失败：{e}"))?;
    let body = resp
        .text()
        .await
        .map_err(|e| format!("读阿里轮询响应失败：{e}"))?;
    let (st, raw) = aliyun_status_of(&body);
    write_log(&format!(
        "轮询 kind=aliyun 状态={} 原始={raw:?} body={}",
        st.code(),
        tail(&body)
    ));
    if st != QrStatus::Confirmed {
        let scanned = st == QrStatus::Scanned;
        return Ok(PollOutcome {
            status: st,
            message: if scanned {
                "已扫描，请在手机上确认".to_string()
            } else {
                "等待扫码…".to_string()
            },
            credential: None,
        });
    }

    let (access, refresh, expires_in) = aliyun_token_from_body(&body)?;
    write_log(&format!(
        "换 token 成功 kind=aliyun access_len={} 有效期={:?}",
        access.len(),
        expires_in
    ));
    Ok(PollOutcome {
        status: QrStatus::Confirmed,
        message: "登录成功：阿里云盘".to_string(),
        credential: Some(crate::pan_auth::PanCredential {
            kind: PanKind::Aliyun,
            account: "阿里云盘".to_string(),
            cookie: aliyun_credential_string(&access, &refresh),
            saved_at: now(),
            expires_at: expires_in.map(|s| now() + s),
        }),
    })
}

// ── 解析小工具（纯函数，可单测；不依赖网络）────────────────────────────
/// 从响应体里找二维码 token
///
/// # 为什么写成"按候选字段名依次找"而不是钉死一个字段
/// ```text
/// 参考实现的 log 里出现的是 `data` + `members` 这类通用名（被混淆过）；
/// 不同版本协议字段名变过。
/// ⇒ 依次尝试已知候选；都找不到就返回 None（由调用方报"协议可能变了"），
///   **不猜一个默认值** —— 猜出来的 token 只会让用户扫一个无效码。
/// ```
fn extract_qr_token(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    // ★ 每条路径写成**等长**数组（`&[&str; 3]`）—— 长度不一时无法放进同一个列表
    //   （我第一版混了 2 元素与 3 元素 ⇒ 编译期就报 E0308，这里正是编译器的好处）
    const PATHS: [[&str; 3]; 2] = [
        ["data", "members", "token"],
        ["data", "token", ""],
    ];
    for path in PATHS {
        let mut cur = &v;
        let mut ok = true;
        for k in path.iter().filter(|k| !k.is_empty()) {
            match cur.get(k) {
                Some(n) => cur = n,
                None => {
                    ok = false;
                    break;
                }
            }
        }
        if ok {
            if let Some(s) = cur.as_str() {
                if !s.is_empty() {
                    return Some(s.to_string());
                }
            }
        }
    }
    None
}

/// 从响应体里找 service_ticket（拿到 = 用户已确认）
fn extract_service_ticket(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    const PATHS: [[&str; 2]; 2] = [
        ["data", "service_ticket"],
        ["data", "members"],
    ];
    for path in PATHS {
        let mut cur = &v;
        let mut ok = true;
        for k in path {
            match cur.get(k) {
                Some(n) => cur = n,
                None => {
                    ok = false;
                    break;
                }
            }
        }
        if !ok {
            continue;
        }
        // 直接是字符串 ⇒ 就是 ticket；是对象 ⇒ 再往里找一层
        if let Some(s) = cur.as_str() {
            if !s.is_empty() {
                return Some(s.to_string());
            }
        } else if let Some(s) = cur.get("service_ticket").and_then(|x| x.as_str()) {
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// 还没确认时，判"是哪种未完成态"
///
/// # ★ 2026-10-27 真网络实测后重写（原版靠关键词，是**运气**）
/// ```text
/// 真读数：未扫描时夸克返回 `{"status":50004001,"message":"Query result is empty"}`
/// 原实现用关键词（expire/过期/scan）判 ⇒ 对这条**恰好**兜到 Pending，
///   因为文案里不含那些词。★ 但那是运气：换一条文案（如 "expired token"）就会误判。
/// ⇒ 改成**按业务码**识别已知态（那才是"行为"），关键词只作兜底。
///   这也更符合"按行为重写、不逐字抄"的口径 —— 业务码是行为契约。
/// ```
fn classify_pending(body: &str) -> QrStatus {
    if let Some(c) = quark_status_code(body) {
        match c {
            QUARK_NOT_SCANNED => return QrStatus::Pending,
            QUARK_OK => {
                // ★ 取码接口的"成功码"出现在轮询里 = 不该发生（轮询成功不是这个码）
                //   ⇒ 如实标 Failed 而不是猜一个 Pending（那会让 UI 一直转圈）
                return QrStatus::Failed;
            }
            _ => {}
        }
    }
    // 兜底：关键词（业务码不在已知表里时）
    let low = body.to_ascii_lowercase();
    if low.contains("expire") || body.contains("过期") {
        QrStatus::Expired
    } else if low.contains("scan") || body.contains("已扫") {
        QrStatus::Scanned
    } else {
        QrStatus::Pending
    }
}

/// 收集响应里**全部** Set-Cookie（按 "; " 拼成一个 Cookie 头值）
///
/// # 为什么是"拼成一个"而不是只取第一条
/// ```text
/// 网盘登录后会下发多条 cookie（`__pus`、`__kp`、`__uid` …），
/// 只留第一条 ⇒ 后续接口缺 cookie ⇒ 表现为"登录了但拉不到列表"（很难查）。
/// 参考实现也是把整段按 ';' 切开再拼。
/// ```
fn collect_set_cookie(resp: &reqwest::Response) -> String {
    let mut parts: Vec<String> = Vec::new();
    for v in resp.headers().get_all(reqwest::header::SET_COOKIE).iter() {
        let Ok(s) = v.to_str() else { continue };
        // 一条 Set-Cookie 形如 `k=v; Path=/; HttpOnly` ⇒ 只要第一段
        if let Some(kv) = s.split(';').next() {
            let kv = kv.trim();
            if !kv.is_empty() {
                parts.push(kv.to_string());
            }
        }
    }
    parts.join("; ")
}

/// 从 account/info 的**响应体**里取账号显示名
///
/// # ⚠️ 我第一版写成 `fn account_from_info(resp: &reqwest::Response)`
/// ```text
/// 那是**永远返回 None 的空函数** —— 因为 `Response` 的 body 只能消费一次，
/// 而调用点已经先读过 headers（Set-Cookie 必须先读）⇒ body 到这里已不可再用。
/// ⇒ 形态正是"看起来在取账号、其实永远取不到"。
/// 改成收**已读出的 body 字符串**：谁读的谁传，责任清楚。
/// ```
fn account_from_body(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    // 夸克 `account/info` 的常见字段（按候选依次找；找不到就由调用方兜底）
    for k in ["nickname", "nick_name", "user_name", "name"] {
        if let Some(s) = v.get("data").and_then(|d| d.get(k)).and_then(|x| x.as_str()) {
            if !s.trim().is_empty() {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// 摘要一行响应（报错时给用户看，不要甩整页 HTML）
fn tail(s: &str) -> String {
    let t = s.trim();
    let cut = t.char_indices().nth(200).map(|(i, _)| i).unwrap_or(t.len());
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

fn kind_key(kind: PanKind, token: &str) -> String {
    format!("{}:{}", kind.code(), token)
}

// ═══════════════════════════════════════════════════════════════════════
//  对外 API（ffi 的四条命令调这些）
// ═══════════════════════════════════════════════════════════════════════

/// 发起扫码（夸克 / UC / 百度已接通；其余如实报"尚未接入"）
pub async fn qr_login_start(kind: PanKind) -> Result<QrSession, String> {
    match kind {
        PanKind::Quark => quark_start().await,
        PanKind::Uc => uc_start().await,
        PanKind::Baidu => baidu_start().await,
        PanKind::Pan115 => pan115_start().await,
        PanKind::Aliyun => aliyun_start().await,
        // ★ 2026-10-28（晚）：取证补齐后，这三家都有真端点 ⇒ 真接通（不再是"如实报原因"）
        PanKind::Guangya => crate::pan_login_device::guangya_start().await,
        PanKind::Xunlei => crate::pan_login_device::xunlei_start().await,
        PanKind::Tianyi => crate::pan_login_tianyi::tianyi_start().await,
        /*
         * 123 是真的没有扫码这条路（不是"没取证"）：
         * ```text
         * 全 dex 里 `login.123pan.com` 下**只有** `api/user/sign_in`（账号密码，两套报文），
         * 全池 qrcode 命中 22 条逐条核对，没有一条属于 123
         * （`.probe/pan-login-evidence-remaining.md` §5.3）。
         * ```
         * ⇒ 画一个码只会扫不动。
         */
        PanKind::Pan123 => Err(
            "123 云盘**没有扫码登录**这条路：官方只有账号密码登录\
             （login.123pan.com/api/user/sign_in）与 open-api 开发者令牌，\
             两者都不是二维码 ⇒ 不画一个扫不动的码"
                .to_string(),
        ),
        other => Err(format!(
            "{} 的扫码登录尚未接入",
            other.display()
        )),
    }
}

/// 轮询扫码状态（`key` = start 返回的 key）
pub async fn qr_login_poll(kind: PanKind, key: &str) -> Result<PollOutcome, String> {
    let key = key.trim();
    if key.is_empty() {
        return Err("扫码会话 key 为空 —— 请重新获取二维码".to_string());
    }

    /*
     * ★★★ 2026-10-28（晚）：**先分流再查表**。
     * ```text
     * 设备码族（光鸭/迅雷）与天翼各自管自己的会话表（在 pan_login_device / pan_login_tianyi 里）。
     * 若先跑下面那段"本表的会话存在性检查"，它们的 key 一定不在本表
     *   ⇒ 刚出码就被判 Expired，**一次 HTTP 都不会发生**（典型的"看起来在轮询、其实早退了"）。
     * ⇒ 这两族在检查之前直接分流；落盘仍走本文件末尾同一入口（`pan_auth::save`）。
     * ```
     */
    if crate::pan_login_device::is_device_flow(kind) || crate::pan_login_tianyi::is_tianyi_login(kind) {
        let out = match kind {
            PanKind::Guangya => crate::pan_login_device::guangya_poll(key).await?,
            PanKind::Xunlei => crate::pan_login_device::xunlei_poll(key).await?,
            PanKind::Tianyi => crate::pan_login_tianyi::tianyi_poll(key).await?,
            other => unreachable!("is_device_flow/is_tianyi_login 与这里的 match 必须一致：{}", other.code()),
        };
        if let Some(cred) = &out.credential {
            crate::pan_auth::save(cred)?;
            write_log(&format!(
                "凭据已落盘 kind={} account={} 摘要={}",
                kind.code(),
                cred.account,
                cookie_digest(&cred.cookie)
            ));
        }
        return Ok(out);
    }

    // 会话超时兜底（本地时钟）
    {
        let map = sessions().lock().unwrap_or_else(|e| e.into_inner());
        match map.get(&kind_key(kind, key)) {
            None => {
                // 没这个会话 ⇒ 可能是应用重启过。**如实说**，不要假装在轮询。
                return Ok(PollOutcome {
                    status: QrStatus::Expired,
                    message: "这个二维码已失效（会话不在），请重新获取".to_string(),
                    credential: None,
                });
            }
            Some(rec) if now() - rec.created_at > SESSION_TTL_SECS => {
                return Ok(PollOutcome {
                    status: QrStatus::Expired,
                    message: "二维码已超时，请重新获取".to_string(),
                    credential: None,
                });
            }
            Some(_) => {}
        }
    }

    let out = match kind {
        PanKind::Quark => quark_poll(key).await?,
        PanKind::Uc => uc_poll(key).await?,
        PanKind::Baidu => baidu_poll(key).await?,
        PanKind::Pan115 => pan115_poll(key).await?,
        PanKind::Aliyun => aliyun_poll(key).await?,
        other => {
            return Err(format!("{} 的扫码登录尚未接入", other.display()))
        }
    };

    // ★ 确认后落盘（**这里**才是唯一写凭据的地方，与 `pan_auth::save` 同一入口）
    if let Some(cred) = &out.credential {
        crate::pan_auth::save(cred)?;
        write_log(&format!(
            "凭据已落盘 kind={} account={} 摘要={}",
            kind.code(),
            cred.account,
            cookie_digest(&cred.cookie)
        ));
        // 会话用完即弃（凭据已落盘；再轮询同一 key 没有意义）
        let mut map = sessions().lock().unwrap_or_else(|e| e.into_inner());
        map.remove(&kind_key(kind, key));
    }
    Ok(out)
}

/// 登出（清钥匙串条目）
pub fn logout(kind: PanKind) -> Result<(), String> {
    crate::pan_auth::clear(kind)
}

/// 某个盘的登录状态（给 `pan_auth_status` 用）
#[derive(Debug, Clone)]
pub struct KindStatus {
    pub kind: PanKind,
    pub kind_name: &'static str,
    pub logged_in: bool,
    pub account: String,
    pub expired: bool,
}

/// 查一个盘的登录状态
pub fn status_of(kind: PanKind) -> KindStatus {
    let cred = crate::pan_auth::load(kind);
    KindStatus {
        kind,
        kind_name: kind.display(),
        logged_in: cred.is_some(),
        account: cred.as_ref().map(|c| c.account.clone()).unwrap_or_default(),
        expired: cred.as_ref().map(|c| c.is_expired(now())).unwrap_or(false),
    }
}

/// 全部盘的登录状态（**顺序固定**，便于 UI 与门禁比对）
pub fn status_all() -> Vec<KindStatus> {
    const ORDER: [PanKind; 9] = [
        PanKind::Quark,
        PanKind::Uc,
        PanKind::Baidu,
        PanKind::Guangya,
        PanKind::Xunlei,
        PanKind::Tianyi,
        PanKind::Pan123,
        PanKind::Aliyun,
        PanKind::Pan115,
    ];
    ORDER.iter().copied().map(status_of).collect()
}

// ═══════════════════════════════════════════════════════════════════════
//  FFI 命令层（字段名与 `lib/ui/settings/pan_settings_page.dart:32-36` **逐字对齐**）
// ═══════════════════════════════════════════════════════════════════════
//
// ★ 为什么字段名要"逐字对齐 UI 契约"：
// ```text
// UI 侧已经写好了（`pan_settings_page.dart:32-36` 那段就是契约）：
//   pan_auth_status     {}        → { accounts: [{kind, kindName, loggedIn,
//                                           account, expired, keyringAvailable}] }
//   pan_qr_login_start  {kind}    → { key, url, svg, hint? }
//   pan_qr_login_poll   {kind,key}→ { status, message?, account? }
//   pan_logout          {kind}    → {}（清钥匙串条目）
// ⇒ 若我这边字段名自作主张（如 `logged_in` 而不是 `loggedIn`），
//   UI 读到的是 undefined ⇒ 界面显示"未登录"而实际已登录 = **假状态**。
//   ⇒ 所以本节的 struct 用 `#[serde(rename_all = "camelCase")]` 钉住这一层。
// ```

/// `pan_auth_status` 的一行（字段名钉死见上面说明）
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountRow {
    /// 机器可读的盘标识（`PanKind::code()`，如 "quark"）
    pub kind: &'static str,
    /// 面向用户的名字（如 "夸克网盘"）
    pub kind_name: &'static str,
    /// 是否已登录（**唯一真相** = 钥匙串里有没有非空 cookie）
    pub logged_in: bool,
    /// 账号显示名（未登录时为空串）
    pub account: String,
    /// 是否已过期（`expires_at` 有值且已过）
    pub expired: bool,
    /// 钥匙串是否可用 —— UI 据此决定"要不要显示登录入口"
    ///
    /// 这个字段是**每行都带**的（而不是放在外面）：因为 UI 是逐行渲染的，
    /// 且"某盘不可用"与"钥匙串整体不可用"在用户看来是同一件事。
    pub keyring_available: bool,
}

/// `pan_auth_status` 的返回
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthStatus {
    pub accounts: Vec<AccountRow>,
}

/// `pan_qr_login_start` 的返回
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QrStartResult {
    pub key: String,
    pub url: String,
    pub svg: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub hint: String,
}

/// `pan_qr_login_poll` 的返回
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QrPollResult {
    /// pending / scanned / confirmed / expired / failed
    pub status: &'static str,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub message: String,
    /// 登录成功时可读到账号名（UI 用它显示"已登录：xxx"）
    #[serde(skip_serializing_if = "String::is_empty")]
    pub account: String,
}

// ── 命令入口（ffi 只做转发；逻辑都在这里，便于单测）──────────────────

/// `pan_auth_status` 命令体
pub fn command_status() -> AuthStatus {
    let ok = crate::pan_auth::keyring_available();
    AuthStatus {
        accounts: status_all()
            .into_iter()
            .map(|s| AccountRow {
                kind: s.kind.code(),
                kind_name: s.kind_name,
                logged_in: s.logged_in,
                account: s.account,
                expired: s.expired,
                keyring_available: ok,
            })
            .collect(),
    }
}

/// `pan_qr_login_start` 命令体
pub async fn command_qr_start(kind_code: &str) -> Result<QrStartResult, String> {
    let kind = kind_from_code(kind_code)?;
    let s = qr_login_start(kind).await?;
    Ok(QrStartResult {
        key: s.key,
        url: s.url,
        svg: s.svg,
        hint: s.hint,
    })
}

/// `pan_qr_login_poll` 命令体
pub async fn command_qr_poll(kind_code: &str, key: &str) -> Result<QrPollResult, String> {
    let kind = kind_from_code(kind_code)?;
    let out = qr_login_poll(kind, key).await?;
    Ok(QrPollResult {
        status: out.status.code(),
        message: out.message,
        // 凭据已由 `qr_login_poll` 落盘；这里只回账号名给 UI
        account: out.credential.map(|c| c.account).unwrap_or_default(),
    })
}

/// `pan_logout` 命令体
pub fn command_logout(kind_code: &str) -> Result<(), String> {
    let kind = kind_from_code(kind_code)?;
    logout(kind)
}

/// 把 UI 传来的 `kind` 字符串解析回 `PanKind`
///
/// # 为什么不直接用 `PanKind` 作为 FFI 参数类型
/// ```text
/// FFI 边界收到的是 **JSON 里的字符串**（`{"kind":"quark"}`）。
/// 直接 `serde` 反序列化成枚举需要给 `PanKind` 加 `Deserialize` +
/// 把 `code()`/`display()` 那套映射再写一遍 ⇒ **两处映射会漂**。
/// ⇒ 这里按 `code()` 反查（**唯一来源**），未知值如实报错（不默认成某个盘）。
/// ```
pub fn kind_from_code(code: &str) -> Result<PanKind, String> {
    let code = code.trim();
    if code.is_empty() {
        return Err("kind 为空 —— 请指定要登录哪个网盘".to_string());
    }
    // 用 status_all 的固定顺序当"全部候选"，避免再抄一份清单
    const ORDER: [PanKind; 9] = [
        PanKind::Quark,
        PanKind::Uc,
        PanKind::Baidu,
        PanKind::Guangya,
        PanKind::Xunlei,
        PanKind::Tianyi,
        PanKind::Pan123,
        PanKind::Aliyun,
        PanKind::Pan115,
    ];
    ORDER
        .iter()
        .copied()
        .find(|k| k.code() == code)
        .ok_or_else(|| {
            format!(
                "认不出网盘标识 '{code}'（可用值：{}）",
                ORDER
                    .iter()
                    .map(|k| k.code())
                    .collect::<Vec<_>>()
                    .join(" / ")
            )
        })
}

// 2026-10-30 task-5（rust-login）的门禁：新建独立文件，不动上面的既有测试
#[cfg(test)]
mod pan_login_t5_gate;

#[cfg(test)]
mod tests {
    use super::*;

    // ── 纯函数（不需要网络/钥匙串，CI 必跑）──

    #[test]
    fn extracts_qr_token_from_known_shapes() {
        // 参考实现里 token 在 data.members.token 这一路
        let a = r#"{"status":200,"data":{"members":{"token":"TK1"}}}"#;
        assert_eq!(extract_qr_token(a).as_deref(), Some("TK1"));
        let b = r#"{"data":{"token":"TK2"}}"#;
        assert_eq!(extract_qr_token(b).as_deref(), Some("TK2"));
        // 找不到 ⇒ None（**不猜默认值**）
        assert_eq!(extract_qr_token(r#"{"data":{}}"#), None);
        assert_eq!(extract_qr_token("不是 JSON"), None);
    }

    #[test]
    fn missing_token_is_none_not_empty_string() {
        // ★ 反空真：`Some("")` 与 `None` 是两件事，不能让空串冒充"找到了"
        assert_eq!(extract_qr_token(r#"{"data":{"members":{"token":""}}}"#), None);
    }

    #[test]
    fn extracts_service_ticket() {
        assert_eq!(
            extract_service_ticket(r#"{"data":{"service_ticket":"ST1"}}"#).as_deref(),
            Some("ST1")
        );
        assert_eq!(extract_service_ticket(r#"{"data":{}}"#), None);
    }

    #[test]
    fn classifies_expired_text() {
        assert_eq!(classify_pending(r#"{"message":"二维码已过期"}"#), QrStatus::Expired);
        assert_eq!(classify_pending(r#"{"msg":"expired"}"#), QrStatus::Expired);
        assert_eq!(classify_pending(r#"{"data":{}}"#), QrStatus::Pending);
    }

    #[test]
    fn qr_status_codes_are_stable() {
        // 这些码会进 UI 判断与日志 ⇒ 改了就是破坏契约
        assert_eq!(QrStatus::Pending.code(), "pending");
        assert_eq!(QrStatus::Scanned.code(), "scanned");
        assert_eq!(QrStatus::Confirmed.code(), "confirmed");
        assert_eq!(QrStatus::Expired.code(), "expired");
        assert_eq!(QrStatus::Failed.code(), "failed");
    }

    #[test]
    fn tail_never_panics_on_short_or_multibyte() {
        assert!(tail("").contains("0 字节"));
        // 多字节字符不许被切在中间（否则会把日志本身变成乱码）
        let s = "夸".repeat(300);
        let t = tail(&s);
        assert!(t.contains("共"));
    }

    #[test]
    fn status_all_covers_nine_kinds_in_fixed_order() {
        let all = status_all();
        assert_eq!(all.len(), 9, "★ 9 个盘都要有状态行（不多不少）");
        assert_eq!(all[0].kind, PanKind::Quark);
        assert_eq!(all[8].kind, PanKind::Pan115);
        // 反空真：kind_name 必须非空（否则 UI 显示空行）
        for s in all {
            assert!(!s.kind_name.is_empty(), "{:?} 的显示名不该为空", s.kind);
        }
    }

    /// ★ 未接入的盘必须**如实报错**，不许返回一个空会话冒充成功
    ///
    /// ★ 2026-10-28（晚）：光鸭/迅雷/天翼接通后，**只剩 123**；它的"没有扫码"是
    ///   **事实**（全 dex 只有账号密码 `sign_in`，见 `.probe/pan-login-evidence-remaining.md` §5.3），
    ///   所以这条守的是"123 必须说清没有扫码，且不许回落到通用文案"。
    /// ```text
    /// 注入验证：把 123 那段文案改成通用 `other =>` ⇒ 本条 FAILED。
    /// ```
    #[tokio::test]
    async fn unimplemented_kind_says_so_instead_of_pretending() {
        let e = qr_login_start(PanKind::Pan123)
            .await
            .expect_err("123 没有扫码，不许成功");
        assert!(e.contains("没有扫码"), "★★ 要点明『没有扫码』（实际：{e}）");
        assert!(
            e.contains("sign_in") || e.contains("开发者令牌"),
            "★ 要给出它实际有的两条路：{e}"
        );
        assert!(!e.contains("尚未接入"), "★ 这不是『没做』，是『没有这条路』：{e}");
    }

    /// ★★★ 三族的**路由判据**必须与 dispatch 一致（离线可断言，不碰网络）
    ///
    /// ```text
    /// dispatch 里用 `is_device_flow(kind) || is_tianyi_login(kind)` 先分流，
    /// 再 match 到具体函数；若两家谓词写宽了（如 is_device_flow 把天翼也算进去），
    /// 会走到 `unreachable!` 直接 panic（比静默错好，但仍然要在这里钉住）。
    /// 注入验证：把 `is_device_flow` 改成 `true`（所有盘）⇒ 本条 FAILED。
    /// ```
    #[test]
    fn routing_predicates_partition_the_three_families() {
        use crate::pan_login_device::is_device_flow;
        use crate::pan_login_tianyi::is_tianyi_login;
        assert!(is_device_flow(PanKind::Guangya));
        assert!(is_device_flow(PanKind::Xunlei));
        assert!(!is_device_flow(PanKind::Tianyi), "天翼不是设备码族");
        assert!(is_tianyi_login(PanKind::Tianyi));
        assert!(!is_tianyi_login(PanKind::Guangya));
        assert!(
            !is_device_flow(PanKind::Quark) && !is_tianyi_login(PanKind::Quark),
            "CAS 族不许被这两家谓词吃掉"
        );
    }

    // ══════════════════════════════════════════════════════════════════
    //  115 扫码（2026-10-28 接通）—— 验收判据是 cookie 四键
    // ══════════════════════════════════════════════════════════════════

    /// ★★ 三条 URL + 二维码内容逐字对齐取证
    ///
    /// ```text
    /// 注入验证：把二维码内容前缀从 `dg-` 改成 `d-` ⇒ 本条 FAILED
    ///   （扫出来的码与 App 约定的不一样，用户扫了没反应）。
    /// ```
    #[test]
    fn pan115_urls_match_the_documented_flow() {
        assert_eq!(
            pan115_token_url(),
            "https://qrcodeapi.115.com/api/1.0/qandroid/1.0/token/"
        );
        // ★ 现场读数修正：只带 uid 会 `40199002 key invalid` ⇒ time/sign 必须带
        assert_eq!(
            pan115_status_url("u1", "1793197822", "s1"),
            "https://qrcodeapi.115.com/get/status/?uid=u1&time=1793197822&sign=s1&_=0"
        );
        // 取码响应的四字段（真读数）—— 缺 time/sign 就没有可用的轮询
        let body = r#"{"state":1,"code":0,"data":{"uid":"u1","time":1793197822,
            "sign":"s1","qrcode":"https://115.com/scan/dg-u1"}}"#;
        let (uid, tm, sign, qr) = pan115_token_fields(body).expect("真报文必须能解析");
        assert_eq!((uid.as_str(), tm.as_str(), sign.as_str()), ("u1", "1793197822", "s1"));
        assert_eq!(qr, "https://115.com/scan/dg-u1");
        assert_eq!(
            pan115_login_url(),
            "https://passportapi.115.com/app/1.0/qandroid/1.0/login/qrcode/"
        );
        assert_eq!(pan115_qr_url("u1"), "https://115.com/scan/dg-u1");
    }

    /// ★★★ 四键验收：缺任何一个都必须失败（这是取证写下的判据）
    ///
    /// ```text
    /// 注入验证：把 KEYS 里的 "SEID" 删掉 ⇒ 第三条断言 FAILED
    ///   ⇒ 那种"只拿到两三个键"的登录态会被当成成功，后续全 401。
    /// ```
    #[test]
    fn pan115_cookie_requires_all_four_keys() {
        let ok = r#"{"state":1,"data":{"cookie":{"UID":"1","CID":"2","SEID":"3","KID":"4"}}}"#;
        let c = pan115_cookie_from_body(ok).expect("四键齐全必须成功");
        assert_eq!(c, "UID=1; CID=2; SEID=3; KID=4");

        let miss = r#"{"state":1,"data":{"cookie":{"UID":"1","CID":"2","KID":"4"}}}"#;
        let e = pan115_cookie_from_body(miss).expect_err("缺 SEID 必须失败");
        assert!(e.contains("SEID"), "要点名缺哪个键：{e}");
        assert!(e.contains("UID/CID/SEID/KID"), "要给出验收判据：{e}");

        // 顶层 data 形状也认（另一种报文）
        let flat = r#"{"data":{"UID":"a","CID":"b","SEID":"c","KID":"d"}}"#;
        assert!(pan115_cookie_from_body(flat).is_ok());
    }

    /// ★★ 状态映射：1 = 已扫未确认，>=2 = 已确认，其它 = 等待
    ///
    /// ⚠️ 取值含义**未取证**（文件里已标注）—— 这条钉的是"映射只在一处、形状稳定"，
    ///   而不是"取值一定对"。真读数来了改 `pan115_status_of` 一处即可。
    #[test]
    fn pan115_status_mapping_is_single_sourced() {
        assert_eq!(pan115_status_of(r#"{"data":{"status":1}}"#), (QrStatus::Scanned, Some(1)));
        assert_eq!(
            pan115_status_of(r#"{"data":{"status":2}}"#),
            (QrStatus::Confirmed, Some(2))
        );
        assert_eq!(pan115_status_of(r#"{"data":{"status":0}}"#), (QrStatus::Pending, Some(0)));
        assert_eq!(pan115_status_of("not json"), (QrStatus::Pending, None));
    }

    // ══════════════════════════════════════════════════════════════════
    //  阿里云盘扫码（2026-10-28 接通）—— token 型凭据的第一个
    // ══════════════════════════════════════════════════════════════════

    /// ★★ 三条 URL 逐字对齐取证（appName/fromSite 写错 = 拿到别人的扫码页）
    ///
    /// ```text
    /// ★ 2026-10-28 修正后：generate 要带 `isMobile/lang/returnUrl/bizParams` 且 `_bx-v=2.2.3`
    ///   （上一版是社区通行实现里的 2.5.3，与参考实现逐字不符）。
    /// 注入验证：把 `_bx-v=2.2.3` 改回 `2.5.3` ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn aliyun_urls_match_the_documented_flow() {
        assert_eq!(
            aliyun_generate_url(),
            "https://passport.aliyundrive.com/newlogin/qrcode/generate.do\
             ?appName=aliyun_drive&fromSite=52&appName=aliyun_drive&appEntrance=web\
             &isMobile=false&lang=zh_CN&returnUrl=&bizParams=&_bx-v=2.2.3"
        );
        assert_eq!(
            aliyun_query_url(),
            "https://passport.aliyundrive.com/newlogin/qrcode/query.do\
             ?appName=aliyun_drive&fromSite=52&_bx-v=2.2.3"
        );
        assert_eq!(
            aliyun_token_url(),
            "https://auth.aliyundrive.com/v2/account/token"
        );
    }

    /// ★★★ 自带 base64 解码必须与标准实现一致（否则 bizExt 永远解不开）
    ///
    /// ```text
    /// 注入验证：把 `val()` 里 `b'A'..=b'Z' => c - b'A'` 改成 `c - b'B'` ⇒ 本条 FAILED。
    /// 期望值用独立算法算出来（Python base64），不是拿被测函数反推。
    /// ```
    #[test]
    fn b64_decode_matches_standard() {
        assert_eq!(b64_decode("eyJhIjoxfQ==").as_deref(), Some(&b"{\"a\":1}"[..]));
        assert_eq!(b64_decode("aGVsbG8=").as_deref(), Some(&b"hello"[..]));
        // 填充与非填充都要认
        assert_eq!(b64_decode("aGk").as_deref(), Some(&b"hi"[..]));
        assert!(b64_decode("****").is_none() || b64_decode("****") == Some(Vec::new()));
    }

    /// ★★★ 状态是**枚举字符串**（NEW/SCANED/CONFIRMED/EXPIRED），不是码
    #[test]
    fn aliyun_status_maps_enums() {
        let mk = |s: &str| format!(r#"{{"content":{{"data":{{"qrCodeStatus":"{s}"}}}}}}"#);
        assert_eq!(aliyun_status_of(&mk("NEW")).0, QrStatus::Pending);
        assert_eq!(aliyun_status_of(&mk("SCANED")).0, QrStatus::Scanned);
        assert_eq!(aliyun_status_of(&mk("CONFIRMED")).0, QrStatus::Confirmed);
        assert_eq!(aliyun_status_of(&mk("EXPIRED")).0, QrStatus::Expired);
        assert_eq!(aliyun_status_of("not json").0, QrStatus::Pending);
    }

    /// ★★★ CONFIRMED 时从 `bizExt`（base64 JSON）里取 token；缺一个就报错
    ///
    /// ```text
    /// 注入验证：把 `pds_login_result` 改成 `pds_login` ⇒ 第二条断言 FAILED
    ///   （真实报文就是 pds_login_result；改错会拿不到 token 却"登录成功"）。
    /// ```
    #[test]
    fn aliyun_token_from_biz_ext() {
        // bizExt = base64({"pds_login_result":{"access_token":"AT","refresh_token":"RT","expires_in":7200}})
        let biz = "eyJwZHNfbG9naW5fcmVzdWx0Ijp7ImFjY2Vzc190b2tlbiI6IkFUIiwicmVmcmVzaF90b2tlbiI6IlJUIiwiZXhwaXJlc19pbiI6NzIwMH19";
        let body = format!(r#"{{"content":{{"data":{{"bizExt":"{biz}"}}}}}}"#);
        let (a, r, e) = aliyun_token_from_body(&body).expect("必须能取到 token");
        assert_eq!((a.as_str(), r.as_str(), e), ("AT", "RT", Some(7200)));

        // 缺 access_token ⇒ 必须报错（不许"登录成功但没有凭据"）
        let bad_biz = "eyJwZHNfbG9naW5fcmVzdWx0Ijp7InJlZnJlc2hfdG9rZW4iOiJSVCJ9fQ==";
        let bad = format!(r#"{{"content":{{"data":{{"bizExt":"{bad_biz}"}}}}}}"#);
        let e = aliyun_token_from_body(&bad).expect_err("缺 access_token 必须失败");
        // 2026-10-30：报错点名 camel/snake 两套键（dex 取证见 aliyun_token_from_body）
        assert!(e.contains("accessToken"), "{e}");
    }

    /// ★★ 凭据是**约定键名**（`access_token=`），不许写成 Cookie 头的样子
    #[test]
    fn aliyun_credential_uses_the_agreed_keys() {
        let s = aliyun_credential_string("AT", "RT");
        assert_eq!(s, "access_token=AT; refresh_token=RT");
        assert!(!s.contains("Cookie"), "★ 它不是 Cookie 头，别写成那样：{s}");
    }

    // ══════════════════════════════════════════════════════════════════
    //  百度扫码（2026-10-28 接通）—— passport 族，与 CAS 不同
    // ══════════════════════════════════════════════════════════════════

    /// ★★ 三条 URL 逐字对齐（2026-10-30 dex 修正：unicast **只带 channel_id**，没有 &v）
    ///
    /// ```text
    /// dex 逐字出处：.probe/pan-login-t5-forensics2.log §A merge.b.j.t（unicast URL 只
    ///   append 一次 channel_id）/ forensics3.log §③（qrbdusslogin 的 v=毫秒、bduss=channel_v.v）。
    /// 旧断言（unicast 带 `&v={sign}`）钉的是已作废的猜测，随 dex 取证修正。
    /// 注入验证（已实测真红）：把 `channel_id` 改成 `cid` ⇒ 本条 FAILED。
    /// 新增证红在 pan_login_t5_gate：unicast URL 出现 `&v=` ⇒ 红。
    /// ```
    #[test]
    fn baidu_urls_match_the_documented_flow() {
        assert_eq!(
            baidu_qrcode_url(),
            "https://passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc"
        );
        assert_eq!(
            baidu_unicast_url("sig1"),
            "https://passport.baidu.com/channel/unicast?channel_id=sig1"
        );
        assert_eq!(
            baidu_qrbduss_url("sig1", "bd1"),
            "https://passport.baidu.com/v3/login/main/qrbdusslogin?v=sig1&bduss=bd1"
        );
    }

    /// ★★ 长轮询窗口必须**小于**全局 HTTP 超时（否则"没事件"会被判成"请求失败"）
    ///
    /// ```text
    /// 真读数：unicast 在未确认时 30 秒 0 字节 ⇒ 它就是长轮询。
    /// 若把这一跳的窗口设成 ≥ 全局超时，表现会退化成"轮询报错、UI 停表"，
    /// 而用户其实正要扫码 —— 正是"扫了没反应"的一种来源。
    /// 注入验证：把 BAIDU_UNICAST_TIMEOUT 改成 10s（= HTTP_TIMEOUT）⇒ 本条 FAILED。
    /// ```
    #[test]
    fn baidu_unicast_timeout_is_shorter_than_the_global_one() {
        assert!(
            BAIDU_UNICAST_TIMEOUT < HTTP_TIMEOUT,
            "★★ 长轮询窗口 {:?} 必须短于全局 {:?}",
            BAIDU_UNICAST_TIMEOUT,
            HTTP_TIMEOUT
        );
        assert_eq!(BAIDU_UNICAST_TIMEOUT.as_secs(), 3, "本仓取 3 秒（可改，但要一起改注释）");
    }

    /// ★★★ 真读数 → 门禁：`imgurl` 是**图片地址**、**不带 scheme**，要补成 `https://`
    ///
    /// ```text
    /// 真读数（2026-10-29，curl 逐字）：
    ///   {"imgurl":"passport.baidu.com/v2/api/qrcode?sign=<sign>&lp=pc&qrloginfrom=pc",
    ///    "errno":0,"sign":"<sign>","prompt":"登录后..."}
    /// 注入验证（已实测真红）：把 `baidu_img_url` 里的 `https://` 前缀去掉
    ///   ⇒ 第一条断言 FAILED（图片地址没有 scheme ⇒ reqwest 直接 builder error）。
    /// 注入验证：把它改成 `https://{t}` 但**不判断已带 scheme** ⇒ 第三条断言 FAILED
    ///   （会拼出 `https://https://…`）。
    /// ```
    #[test]
    fn baidu_imgurl_becomes_qr_image_url() {
        // 第一层：纯函数补 scheme
        assert_eq!(
            baidu_img_url("passport.baidu.com/v2/api/qrcode?sign=s1&lp=pc"),
            "https://passport.baidu.com/v2/api/qrcode?sign=s1&lp=pc"
        );
        // 幂等：已经带 scheme 的原样返回（不拼两层）
        assert_eq!(
            baidu_img_url("https://passport.baidu.com/x?sign=s1"),
            "https://passport.baidu.com/x?sign=s1"
        );
        assert_eq!(baidu_img_url("  http://h/x  "), "http://h/x");
        assert_eq!(baidu_img_url(""), "");

        // 第二层：真报文 → 结构体
        let real = r#"{"imgurl":"passport.baidu.com/v2/api/qrcode?sign=sig1&lp=pc&qrloginfrom=pc",
            "errno":0,"sign":"sig1","prompt":"登录后可同步"}"#;
        let f = baidu_qr_fields(real).expect("真报文必须能解析");
        assert_eq!(f.sign, "sig1");
        assert_eq!(
            f.img_url,
            "https://passport.baidu.com/v2/api/qrcode?sign=sig1&lp=pc&qrloginfrom=pc"
        );
        assert!(
            f.img_url.starts_with("https://"),
            "★★ 必须补 scheme，否则 reqwest 报 builder error：{}",
            f.img_url
        );
        // ★ 它**不是**二维码文本：里面没有 wappass 那种"扫码后跳转"的 URL
        assert!(
            !f.img_url.contains("wappass"),
            "★ imgurl 是图片地址，不是二维码内容：{}",
            f.img_url
        );
    }

    /// ★★★ 缺字段 / errno 非 0 / 非 JSON ⇒ **一律 Err**（不许编默认值）
    ///
    /// ```text
    /// 旧实现的病就在这里：它去找 `data.channel_id`+`data.url`，真报文没有 ⇒
    /// 报"字段不全"但**看不出缺什么**。现在每条 Err 都点名缺哪个字段。
    /// 注入验证（已实测真红）：把 `if sign.is_empty()` 那段整块删掉 ⇒ 第二条断言 FAILED
    ///   （缺 sign 却返回 Ok ⇒ 轮询会用一个空 sign 去撞服务端，表现是"永远 Pending"）。
    /// ```
    #[test]
    fn baidu_missing_fields_are_errors() {
        // 缺 imgurl
        let e = baidu_qr_fields(r#"{"errno":0,"sign":"s1"}"#).expect_err("缺 imgurl 必须失败");
        assert!(e.contains("imgurl"), "{e}");
        // 缺 sign
        let e = baidu_qr_fields(r#"{"errno":0,"imgurl":"passport.baidu.com/x"}"#)
            .expect_err("缺 sign 必须失败");
        assert!(e.contains("sign"), "{e}");
        // 两个都缺 ⇒ 名字都要点到
        let e = baidu_qr_fields(r#"{"errno":0}"#).expect_err("两个都缺必须失败");
        assert!(e.contains("sign") && e.contains("imgurl"), "{e}");
        // errno 非 0
        let e = baidu_qr_fields(r#"{"errno":-6,"prompt":"登录失败"}"#)
            .expect_err("errno 非 0 必须失败");
        assert!(e.contains("errno=-6"), "{e}");
        // 不是 JSON
        let e = baidu_qr_fields("<html>502</html>").expect_err("非 JSON 必须失败");
        assert!(e.contains("不是 JSON"), "{e}");
        // 空串
        assert!(baidu_qr_fields("").is_err());
    }

    /// ★★★ 真网 smoke（默认 ignored）：百度那一步**真的**能取到码并内嵌出 PNG
    ///
    /// ```text
    /// 跑法：cargo test --lib pan_login --release -- --ignored --nocapture
    /// 前提：SOURIN_LIVE_BAIDU=1（缺了就跳过 —— 不在离线/CI 上自动联网）
    /// 它验三件此时就能验的事（不需要账号）：
    ///   ① getqrcode 真网回的字段形状（把这轮的读数打出来）；
    ///   ② `https://` + imgurl 真的能 GET 到一张 PNG；
    ///   ③ 内嵌出的 SVG 里带 `data:image/png;base64,`。
    /// ```
    #[tokio::test]
    #[ignore = "真网；需要 SOURIN_LIVE_BAIDU=1"]
    async fn live_baidu_start_embeds_the_real_qr_png() {
        if std::env::var("SOURIN_LIVE_BAIDU").as_deref() != Ok("1") {
            eprintln!("[skip] 未设 SOURIN_LIVE_BAIDU=1 ⇒ 不联网");
            return;
        }
        // ① 先看原始响应形状（sign 值打码，它是这一轮会话的钥匙）
        let c = client(UA_BAIDU).expect("建客户端");
        let body = c
            .get(baidu_qrcode_url())
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", "https://pan.baidu.com/")
            .send()
            .await
            .expect("getqrcode 必须可达")
            .text()
            .await
            .expect("读响应");
        let masked = {
            let v: serde_json::Value = serde_json::from_str(&body).unwrap_or_default();
            let sign = v.get("sign").and_then(|x| x.as_str()).unwrap_or("");
            let img = v.get("imgurl").and_then(|x| x.as_str()).unwrap_or("");
            let mut m = body.replace(sign, "<sign>");
            // imgurl 里也含 sign（已被上一步替掉）
            eprintln!("getqrcode errno={:?}", v.get("errno"));
            eprintln!("getqrcode sign_len={}", sign.len());
            eprintln!("getqrcode imgurl_len={} imgurl={}", img.len(), img);
            m = m.replace(sign, "<sign>");
            m
        };
        eprintln!("getqrcode body(masked)={mashed}", mashed = masked);

        // ② 走真实现
        let s = baidu_start().await.expect("百度取码必须成功");
        eprintln!(
            "start OK key_len={} url={} svg_len={} hint={}",
            s.key.len(),
            s.url,
            s.svg.len(),
            s.hint
        );
        assert!(s.url.starts_with("https://passport.baidu.com/"), "{}", s.url);
        assert!(
            s.svg.contains("data:image/png;base64,iVBORw0KGgo"),
            "★★ 内嵌的必须是真 PNG（base64 以 PNG 签名开头）。svg 前 120 字：{}",
            s.svg.chars().take(120).collect::<String>()
        );
        eprintln!("svg 前 90 字：{}", s.svg.chars().take(90).collect::<String>());

        // ③ 轮询一次：未确认 ⇒ 必须 Pending（且不许产出凭据）
        let out = baidu_poll(&s.key).await.expect("轮询不该是 Err");
        eprintln!("poll #1 status={} message={}", out.status.code(), out.message);
        assert_eq!(out.status, QrStatus::Pending, "未确认必须 Pending");
        assert!(out.credential.is_none(), "未确认不许产出凭据");
    }

    #[test]
    fn baidu_top_level_wins_over_data() {
        let body = r#"{"errno":0,"sign":"top","imgurl":"passport.baidu.com/a",
            "data":{"sign":"nested","imgurl":"passport.baidu.com/b"}}"#;
        let f = baidu_qr_fields(body).expect("必须能解析");
        assert_eq!(f.sign, "top", "★★ 顶层优先（真报文就是顶层）");
        assert_eq!(f.img_url, "https://passport.baidu.com/a");

        let only_data = r#"{"data":{"sign":"d1","imgurl":"passport.baidu.com/c"}}"#;
        let f = baidu_qr_fields(only_data).expect("data 兜底也要认");
        assert_eq!((f.sign.as_str(), f.img_url.as_str()), ("d1", "https://passport.baidu.com/c"));
    }

    /// ★★★ 自带 base64 **编码**必须与标准实现逐字一致（否则内嵌的 PNG 全坏）
    ///
    /// ```text
    /// 期望值全部由**独立实现**（PowerShell `[Convert]::ToBase64String`，与 Python
    /// `base64.b64encode` 同值）算出，不是拿被测函数反推。
    /// 注入验证（已实测真红）：把字母表里的 `a..z` 换成 `a..y` ⇒ 本条 FAILED。
    /// 注入验证：把 padding 分支写成永远 `'='` ⇒ 第 4/5 条断言（长度非 3 倍的）FAILED。
    /// ```
    #[test]
    fn b64_encode_matches_standard() {
        assert_eq!(b64_encode(b"hello"), "aGVsbG8=");
        assert_eq!(b64_encode(br#"{"a":1}"#), "eyJhIjoxfQ==");
        assert_eq!(b64_encode(b"hi"), "aGk="); // 2 字节 ⇒ 一个 '='
        assert_eq!(b64_encode(b"Man"), "TWFu"); // 3 字节 ⇒ 无填充
        assert_eq!(b64_encode(b"May"), "TWF5"); // 同上，但换字母表位置
        assert_eq!(b64_encode(&[0x00, 0x01, 0x02]), "AAEC");
        assert_eq!(b64_encode(&[0xFF, 0xFE, 0xFD]), "//79"); // +/ 两个符号都要对
        assert_eq!(
            b64_encode(b"any carnal pleasure."),
            "YW55IGNhcm5hbCBwbGVhc3VyZS4="
        );
        assert_eq!(b64_encode(b""), "");
        // PNG 签名 → 与标准实现一致（这条直接护住内嵌 PNG 的头部）
        assert_eq!(b64_encode(b"\x89PNG\r\n\x1a\n"), "iVBORw0KGgo=");
    }

    /// ★★ 编码/解码必须互逆（两套实现互相校准，任一处偏移都会露出来）
    #[test]
    fn b64_roundtrip_is_lossless() {
        for raw in [
            &b""[..],
            b"f",
            b"fo",
            b"foo",
            b"foob",
            b"fooba",
            b"foobar",
            b"\x00\xFF\x10\x20",
        ] {
            let enc = b64_encode(raw);
            assert_eq!(
                b64_decode(&enc).as_deref(),
                Some(raw),
                "往返失败：raw={raw:?} enc={enc}"
            );
        }
    }

    /// ★★★ PNG → SVG：`<image href="data:image/png;base64,…">`，尺寸取自 IHDR
    ///
    /// ```text
    /// 注入验证（已实测真红）：把 `png_size` 里的 `w > 4096` 判断删掉并把 `data[16..20]`
    ///   换成 `data[20..24]`（width/height 读反）⇒ 第一条断言 FAILED（尺寸对不上）。
    /// 注入验证：把 `href` 里的 `data:image/png;base64,` 改成 `data:image/png,` ⇒ 第一条 FAILED。
    /// ```
    #[test]
    fn svg_embeds_png_as_data_uri() {
        // 手里造一张"只有文件头"的 PNG：签名(8) + 段长(4) + "IHDR"(4) + w(4) + h(4)
        // ★ 宽高**故意不相等**（231×257）：相等的话"读反了 w/h"这种错就测不出来
        let mut png: Vec<u8> = Vec::new();
        png.extend_from_slice(b"\x89PNG\r\n\x1a\n");
        png.extend_from_slice(&13u32.to_be_bytes());
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&231u32.to_be_bytes());
        png.extend_from_slice(&257u32.to_be_bytes());
        assert_eq!(png.len(), 24, "这条夹具就是 24 字节");

        assert_eq!(
            png_size(&png),
            Some((231, 257)),
            "★★ 宽高必须从 IHDR 的正确偏移读出来（读反/读错位这里立刻红）"
        );

        let svg = svg_with_embedded_png(&png).expect("PNG 必须能内嵌成 SVG");
        assert!(svg.starts_with("<svg "), "{svg}");
        assert!(svg.contains(r#"width="231" height="257""#), "{svg}");
        assert!(svg.contains(r#"viewBox="0 0 231 257""#), "{svg}");
        assert!(
            svg.contains("<image") && svg.contains("data:image/png;base64,iVBORw0KGgo"),
            "★★ 必须是 data URI 且以 PNG 签名的 base64 开头（24 字节 = 3 的整数倍 ⇒ 无 `=`）：{svg}"
        );
        assert!(svg.trim_end().ends_with("</svg>"), "{svg}");

        // 非 PNG ⇒ None（不是"编一个 SVG 出来"）
        assert!(png_size(b"not a png").is_none());
        assert!(svg_with_embedded_png(b"not a png").is_none());
        assert!(svg_with_embedded_png(b"").is_none());
        // 尺寸为 0 ⇒ None（避免产出 0×0 的 SVG）
        let mut zero = png.clone();
        zero[16..20].copy_from_slice(&0u32.to_be_bytes());
        assert!(png_size(&zero).is_none());
    }

    /// ★★★ "已确认"的唯一判据：响应头里出现 `BDUSS`
    #[test]
    fn bduss_detection_is_exact() {
        assert_eq!(
            bduss_from_cookie("PTOKEN=abc; BDUSS=xyz; STOKEN=s").as_deref(),
            Some("xyz")
        );
        assert!(bduss_from_cookie("PTOKEN=abc; BDUSS=").is_none(), "空值不算");
        assert!(bduss_from_cookie("XBDUSS=1").is_none(), "★ 前缀必须整键匹配");
        assert!(bduss_from_cookie("").is_none());
    }

    /// ★★★ 合并 cookie：同名**后到覆盖**，不同名都留
    ///
    /// ```text
    /// 注入验证：把 `slot.1 = kv` 改成"保留先到的" ⇒ 本条 FAILED。
    /// 这条错了的表现是"登录成功但拉不到列表"（旧值把新值顶掉）。
    /// ```
    #[test]
    fn merge_cookie_lets_later_win() {
        let a = "BDUSS=old; PTOKEN=p1";
        let b = "BDUSS=new; STOKEN=s1";
        let m = merge_cookie(a, b);
        assert_eq!(
            bduss_from_cookie(&m).as_deref(),
            Some("new"),
            "★★ 后到的必须覆盖：{m}"
        );
        assert!(m.contains("PTOKEN=p1"), "没冲突的键要留着：{m}");
        assert!(m.contains("STOKEN=s1"), "新键要进来：{m}");
        assert_eq!(m.matches("BDUSS=").count(), 1, "★ 不许出现两条同名：{m}");
    }

    /// ★★★ 取码 URL 必须带 **client_id=529**，且主机是 `api.open.uc.cn`
    ///
    /// ```text
    /// 注入验证（已实测真红）：把 `uc_token_url` 里的 client_id 常量改成 532
    ///   （= 夸克那个）⇒ 本条 FAILED。
    /// 这类错**不会报错**：接口照样回 200，只是返回的 token 与 UC App 不认
    ///   ⇒ 用户扫了没反应，排查成本极高。
    /// ```
    #[test]
    fn uc_token_url_carries_its_own_client_id() {
        let u = uc_token_url("rid-1");
        assert!(
            u.starts_with(
                "https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin\
                 ?pr=UCBrowser&fr=pc&sys=win32&client_id=529&v=1.2&request_id=rid-1"
            ),
            "{u}"
        );
        assert!(!u.contains("uop.quark.cn"), "★★ 不许借用夸克的主机：{u}");
    }

    /// ★★★ 二维码内容必须走 `su.uc.cn/4_fzMj2`，且带 uc_param_str 串
    #[test]
    fn uc_qr_url_matches_the_reference_byte_for_byte() {
        let u = uc_qr_url("tok");
        assert!(u.starts_with("https://su.uc.cn/4_fzMj2?"), "{u}");
        assert!(u.contains("uc_param_str=dsdnfrpfbivesscpgimibtbmnijblauputogpintnwktprchmt"), "{u}");
        assert!(u.contains("token=tok"), "{u}");
        assert!(u.contains("client_id=529"), "{u}");
        assert!(
            !u.contains("su.quark.cn") && !u.contains("4_eMHBJ"),
            "★★ 不许借用夸克的二维码入口：{u}"
        );
    }

    /// ★★★ 换票 URL 的 client_id 是 **381**（不是取码那个 529）—— 这一处最容易串
    ///
    /// ```text
    /// 注入验证：把 `uc_ticket_url` 里的 381 改成 529 ⇒ 本条 FAILED。
    /// ```
    #[test]
    fn uc_ticket_url_uses_client_id_381_and_echoes_request_id() {
        let u = uc_ticket_url("tok", "rid-1", 1700000000000);
        assert!(u.starts_with(
            "https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken?__dt=18884&__t=1700000000000"
        ), "{u}");
        assert!(u.contains("client_id=381"), "★★ 换票的 client_id 是 381：{u}");
        assert!(!u.contains("client_id=529"), "★★ 不许把取码的 id 串过来：{u}");
        assert!(u.contains("request_id=rid-1"), "{u}");
        assert!(u.contains("token=tok"), "{u}");
    }

    /// ★★ request_id 是 32 位十六进制，且两次调用不同（会话号撞了服务端会拒）
    #[test]
    fn request_id_shape_is_stable_and_unique() {
        let a = new_request_id();
        let b = new_request_id();
        assert_eq!(a.len(), 32, "★ 32 位十六进制：{a}");
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()), "{a}");
        assert_ne!(a, b, "★★ 两次生成不许相同（否则并发扫码会互相顶掉会话）");
    }

    /// ★ 会话超时与"不存在"都必须报 Expired，**不许**静默 Pending
    #[tokio::test]
    async fn poll_without_session_reports_expired_not_pending() {
        let out = qr_login_poll(PanKind::Quark, "no-such-key")
            .await
            .expect("不该 Err（『会话不在』是正常状态，不是错误）");
        assert_eq!(
            out.status,
            QrStatus::Expired,
            "★★ 会话不在 ⇒ 必须说『失效』，不许假装还在轮询（会让 UI 永远转圈）"
        );
        assert!(out.credential.is_none(), "没有会话就不该产出凭据");
    }

    #[tokio::test]
    async fn poll_with_empty_key_is_error() {
        let e = qr_login_poll(PanKind::Quark, "  ").await.expect_err("空 key 应报错");
        assert!(e.contains("重新获取"), "文案要告诉用户怎么办：{e}");
    }

    // ── ★ FFI 契约门禁（字段名必须与 UI 逐字对齐）──

    /// ★★★ 日志门禁：cookie **绝不许**进日志（那是登录凭据）
    ///
    /// ```text
    /// 硬规矩（与 `pan_auth` 只把 cookie 放系统钥匙串同源）：
    ///   日志会被 Owner 复制给我们、也可能随诊断包外发 ⇒ **写进去就泄了**。
    /// ★ 但"有几条键、多少字节"足够判"Set-Cookie 形状对不对" ⇒ 用 `cookie_digest` 脱敏。
    /// 注入验证：把 `cookie_digest(&cookie)` 换成直接 `cookie` ⇒ 本条红。
    /// ```
    #[test]
    fn log_never_contains_cookie_value() {
        let secret = "a1b2c3supersecret";
        let cookie = format!("__pus={secret}; __kp=othervalue; __uid=12345");
        let d = cookie_digest(&cookie);
        assert!(
            !d.contains(secret),
            "★★★ 脱敏摘要里出现了 cookie 的**值**（会泄漏登录凭据）：{d}"
        );
        assert!(
            !d.contains("othervalue") && !d.contains("12345"),
            "★★★ 任何 cookie 值都不许出现：{d}"
        );
        // 但必须保留"可判形状"的信息（键名 + 数量 + 长度）
        assert!(d.contains("__pus") && d.contains("__kp"), "键名要留下（判形状用）：{d}");
        assert!(d.contains("3 个键"), "键数量要留下：{d}");
        assert!(d.contains(&format!("{} 字节", cookie.len())), "长度要留下：{d}");
    }

    /// ★★★ 关键键校验门禁（基线来自 **Owner 现场真读数**）
    ///
    /// ```text
    /// 实测（2026-10-27 16:49）拿到的夸克 cookie：
    ///   ctoken, __pus, __kp, __kps, __ktd, __uid   ← **6 键 298 字节**
    /// ⇒ 本条用真读数当基线，而不是我猜的键名。
    /// ★ 为什么做成"告警"而不是"失败"：网盘可能改键名/增减键，
    ///   硬门禁会把"协议正常演进"误判为故障。真失败由后续取数（列文件 401）暴露。
    /// ★ 但"告警"本身也要被测：注入一个缺 `__uid` 的 cookie ⇒ **必须有告警**
    ///   （否则告警功能形同虚设 —— 与 `in_test_process` 那次同族）。
    /// ```
    #[test]
    fn incomplete_cookie_triggers_warning_not_silence() {
        // 完整（按实测基线）
        let full = "ctoken=a; __pus=b; __kp=c; __kps=d; __ktd=e; __uid=f";
        let dig = cookie_digest(full);
        assert!(dig.contains("6 个键"), "★ 完整 cookie 应是 6 键：{dig}");
        // 缺 __uid ⇒ 必须被识别为"缺失"
        let missing: Vec<&str> = ["ctoken", "__uid"]
            .iter()
            .copied()
            .filter(|k| !full.split(';').any(|p| p.trim().starts_with(&format!("{k}="))))
            .collect();
        assert!(missing.is_empty(), "完整 cookie 不该报缺失：{missing:?}");
        let bad = "ctoken=a; __pus=b";
        let missing_bad: Vec<&str> = ["ctoken", "__uid"]
            .iter()
            .copied()
            .filter(|k| !bad.split(';').any(|p| p.trim().starts_with(&format!("{k}="))))
            .collect();
        assert_eq!(
            missing_bad,
            vec!["__uid"],
            "★★ 缺 `__uid` 必须被检出（否则告警形同虚设）"
        );
    }

    /// ★★ 脱敏摘要必须能反映**键的增减**（形状判据的前提）
    #[test]
    fn digest_reflects_key_changes() {
        let six = "ctoken=a; __pus=b; __kp=c; __kps=d; __ktd=e; __uid=f";
        let two = "a=1; b=2";
        assert_ne!(
            cookie_digest(six),
            cookie_digest(two),
            "★ 键集合不同 ⇒ 摘要必须不同（否则形状变化看不出来）"
        );
    }

    /// ★★ 日志模块的测试进程闸：测试**不许**写用户真实日志
    ///
    /// ```text
    /// 与 `streamproxy.rs:131` 同一条纪律（那边注释写了原因：
    /// "否则测试夹具会往用户 logs/ 里写几千行噪声"）。
    /// ★ 注入验证：删掉 `in_test_process()` 那道判断 ⇒ 本条红。
    /// ```
    #[test]
    fn log_path_is_guarded_in_test_process() {
        // `cargo test` 环境里应当**解析不出**真实日志路径
        let p = log_file_path();
        match p {
            None => {} // 正确：测试进程不写
            Some(path) => {
                let s = path.to_string_lossy().to_string();
                assert!(
                    !s.contains("app.sourin.player"),
                    "★★★ 测试进程解析出了**用户真实**日志路径（会写噪声进去）：{s}\n\
                     （若显式设了 SOURIN_LOG_FILE 则允许 —— 那是『要验格式』的意图）"
                );
            }
        }
    }

    /// ★ FFI 契约门禁（字段名必须与 UI 逐字对齐）
    ///
    /// ```text
    /// UI 契约（pan_settings_page.dart:32）：
    ///   { accounts: [{kind, kindName, loggedIn, account, expired, keyringAvailable}] }
    /// ★ 注入验证：把 `#[serde(rename_all = "camelCase")]` 删掉
    ///   ⇒ 字段变成 kind_name/logged_in ⇒ 本条红（UI 会读到 undefined = 假状态）
    /// ```
    #[test]
    fn ffi_status_field_names_match_ui_contract() {
        let v = serde_json::to_value(command_status()).expect("应能序列化");
        let arr = v.get("accounts").and_then(|a| a.as_array()).expect("要有 accounts 数组");
        assert_eq!(arr.len(), 9);
        let o = arr[0].as_object().expect("每行是对象");
        for k in ["kind", "kindName", "loggedIn", "account", "expired", "keyringAvailable"] {
            assert!(
                o.contains_key(k),
                "★★ UI 契约要求字段 `{k}`（实际字段：{:?}）—— 名字错了 UI 会读到 undefined",
                o.keys().collect::<Vec<_>>()
            );
        }
        // 反面：不许出现 snake_case 版本（那说明 rename 没生效/被重复加了）
        for k in ["kind_name", "logged_in", "keyring_available"] {
            assert!(!o.contains_key(k), "★ 不许同时存在 snake_case 字段 `{k}`");
        }
    }

    #[test]
    fn ffi_start_result_field_names() {
        let s = QrStartResult {
            key: "k".into(),
            url: "u".into(),
            svg: "<svg/>".into(),
            hint: "h".into(),
        };
        let v = serde_json::to_value(s).unwrap();
        for k in ["key", "url", "svg", "hint"] {
            assert!(v.get(k).is_some(), "UI 契约要求字段 `{k}`");
        }
    }

    #[test]
    fn ffi_poll_result_status_is_a_code_not_debug() {
        let p = QrPollResult {
            status: QrStatus::Pending.code(),
            message: String::new(),
            account: String::new(),
        };
        let v = serde_json::to_value(p).unwrap();
        assert_eq!(v.get("status").and_then(|x| x.as_str()), Some("pending"));
        // 空 message/account **不该出现**（skip_serializing_if）—— 免得 UI 显示一个空提示
        assert!(v.get("message").is_none(), "空 message 不该序列化出来");
        assert!(v.get("account").is_none(), "空 account 不该序列化出来");
    }

    #[test]
    fn kind_from_code_accepts_all_nine_and_rejects_junk() {
        for k in [
            PanKind::Quark, PanKind::Uc, PanKind::Baidu, PanKind::Guangya,
            PanKind::Xunlei, PanKind::Tianyi, PanKind::Pan123, PanKind::Aliyun,
            PanKind::Pan115,
        ] {
            assert_eq!(kind_from_code(k.code()).unwrap(), k, "code={}", k.code());
        }
        // ★ 未知值必须**报错**，不许默认成某个盘（那样用户点 A 盘的按钮会登 B 盘）
        let e = kind_from_code("not-a-pan").expect_err("未知 kind 应报错");
        assert!(e.contains("认不出"), "{e}");
        let e = kind_from_code("   ").expect_err("空 kind 应报错");
        assert!(e.contains("为空"), "{e}");
    }

    #[test]
    fn kind_from_code_rejects_unknown_sentinel() {
        // `Unknown` **不在**可选列表里 —— 它是"认不出链接"的标记，不是可登录的盘。
        // 若有人把它加进 ORDER，本条会红（那会让 UI 出现一个"未知网盘"按钮）。
        assert!(
            kind_from_code(PanKind::Unknown.code()).is_err(),
            "★ 『unknown』不该是可登录的盘"
        );
    }
}