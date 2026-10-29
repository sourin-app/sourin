//! 123 云盘（`PanKind::Pan123`）—— **账号密码**登录
//!
//! # 为什么单独开一个文件（而不是塞进 `pan_login` / `pan_login_device`）
//!
//! ```text
//! `pan_login` 五家（夸克/UC/百度/115/阿里）的形状是「出码 → 轮询 → 换 cookie」；
//! `pan_login_device`（光鸭/迅雷）与 `pan_login_tianyi` 是设备码 / logbox uuid 扫码。
//! 123 不一样，而且是被取证否掉的那一类：
//!   · **没有扫码**（`login.123pan.com` 下只有 `api/user/sign_in` 一条；
//!     全池 qrcode 命中 22 条逐条核对，没有一条属于 123 ——
//!     `.probe/pan-login-evidence-remaining.md` §5.3）；
//!   · 官方只有**账号密码**这一条人路（另加 open-api 开发者令牌，那是用户自己申请的）。
//! ⇒ 它的"会话"不是二维码状态机，而是一次表单 POST + 一次判定。硬塞进扫码那套
//!   只会让两边都变成 if/else（与 `pan_login_tianyi` 分开的理由同一句话）。
//! ```
//!
//! # 报文取证（唯一权威：`.probe/pan-login-evidence-remaining.md` §5.2 / §5.4）
//!
//! ```text
//! 端点（两套共用）：POST https://login.123pan.com/api/user/sign_in
//! 头（逐字）：referer: https://www.123pan.com ; origin: https://www.123pan.com ;
//!             platform: web ; user-agent: Dart/2.19(dart:io) ; app-version: 3
//! 变体①：{"passport":"<账号>","password":"<密码>","remember":true}
//!        判定：message == "success"            token 在 data.token
//! 变体②：{"mail":"<账号>","password":"<密码>","type":<int>}
//!        判定：code == 200                     token 在 data.token
//! 校验端点：GET https://open-api.123pan.com/api/v1/user/info  （Authorization: Bearer <token>）
//!        判定：message == "ok"
//! ```
//!
//! ★ **两套都试**，因为 dex 里两套**同时存在**、端点相同、**判定字段不同**，
//!   而"哪套是现行"在字符串层面**判不出来**（§5.2 明确标 🟡）⇒ 先①后②，
//!   两次都失败就把两段原文都放进错误里 —— 让现场一次就能看出是哪一步不对。
//!
//! # ⚠️ 推断项（**不许在读代码时当成已验证**）
//!
//! ```text
//! ① 变体② 的 `type` 具体整数：dex 里是 `Integer.valueOf(<某 int>)`，
//!    数字**未逐条反汇编确认**（§5.2 🟡）⇒ 这里给常量 [`MAIL_LOGIN_TYPE`]，
//!    门禁钉的是"形状"（`"type":<同一个数>`），不是"这个数一定对"。
//! ② 是否需要验证码/滑块：dex 的 `sign_in` 流程里**没有任何 captcha 串**
//!    ⇒ 本文件不处理验证码；真机上若被要求，错误里会带出服务端原话。
//! ③ 校验端点（`user/info`）**不作为登录前提**：
//!    web 会话 token 是否被 open-api 接受**无证据**，拿它当闸门会把
//!    "其实登上了"判成失败。⇒ 只提供纯判定 [`user_info_ok`]，不串进登录链。
//! ```
//!
//! # 密码纪律（一条硬线）
//!
//! ```text
//! 密码**不进日志、不进错误文案、不进凭据**。
//! · 本文件**没有** `write_log`（不留任何可疑入口）；
//! · 所有对外文案最后都过一遍 [`redact`]（服务端若把密码回显在 message 里，
//!   一样会被抹成 `***`）；
//! · 落盘的只有 `cookie = "access_token=<token>"`（与全仓 token 型网盘的约定键一致）。
//! ```

use std::time::Duration;

use crate::pan::PanKind;
use crate::pan_auth::PanCredential;

// ═══════════════════════════════════════════════════════════════════════
//  逐字常量（改一个字节就是改协议契约；每条都标了出处）
// ═══════════════════════════════════════════════════════════════════════

/// 登录端点（两套报文共用）—— dex 串 `https://login.123pan.com/api/user/sign_in`
pub const LOGIN_URL: &str = "https://login.123pan.com/api/user/sign_in";

/// 校验端点（**不串进登录链**，理由见文件头 ③）
pub const USER_INFO_URL: &str = "https://open-api.123pan.com/api/v1/user/info";

/// UA —— 取证逐字：`Dart/2.19(dart:io)`（参考实现就是 Dart 写的，服务端照收）
pub const UA: &str = "Dart/2.19(dart:io)";
pub const REFERER: &str = "https://www.123pan.com";
pub const ORIGIN: &str = "https://www.123pan.com";
pub const PLATFORM: &str = "web";
pub const APP_VERSION: &str = "3";

/// 凭据里 token 的约定键名（全仓统一：`access_token=<token>`）
pub const ACCESS_TOKEN_PREFIX: &str = "access_token=";

/// 变体② 的 `type` 整数
///
/// 🟡 **取值未取证**（dex 里是 `Integer.valueOf(<某 int>)`，§5.2）——
/// 这里放 1 作为**可改的常量**：门禁钉"这个常量真的被用在报文里且形状逐字"，
/// 不钉"1 就是对的"。真机换成别的数只需改这一处 + 门禁里的期望值。
pub const MAIL_LOGIN_TYPE: i64 = 1;

/// 单次 HTTP 预算（登录接口都很快；卡住 = 网络问题，早失败早提示）
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

/// 错误文案里响应摘要的最大长度（够看清是哪一步，又不至于把错误撑爆）
const SUMMARY_LIMIT: usize = 300;

// ═══════════════════════════════════════════════════════════════════════
//  两套报文 —— 变体是**数据类型**，不是散落的 if
// ═══════════════════════════════════════════════════════════════════════

/// 登录报文的两个变体（顺序即尝试顺序：**先①后②**）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoginVariant {
    /// 变体①：`passport` + `password` + `remember:true`，判 `message == "success"`
    Passport,
    /// 变体②：`mail` + `password` + `type:<int>`，判 `code == 200`
    Mail,
}

/// 尝试顺序（**先①后②**；改顺序就是改行为，门禁会红）
pub const LOGIN_VARIANTS: [LoginVariant; 2] = [LoginVariant::Passport, LoginVariant::Mail];

impl LoginVariant {
    /// 机器可读名（进错误文案与日志；**不要**用 Debug 输出）
    pub fn code(self) -> &'static str {
        match self {
            LoginVariant::Passport => "passport",
            LoginVariant::Mail => "mail",
        }
    }

    /// 这套报文的**判定字段**用一句话写出来（错误文案里要指名道姓）
    pub fn judge_text(self) -> &'static str {
        match self {
            LoginVariant::Passport => "message == \"success\"",
            LoginVariant::Mail => "code == 200",
        }
    }
}

/// 把一段字符串编码成 JSON 字符串字面量（含引号）
///
/// 为什么用 `serde_json` 而不是 `format!("\"{}\"", s)`：账号里可能有 `"`、`\\`、
/// 控制字符；手拼会让**报文本身**变成非法 JSON ⇒ 服务端只回一句"参数错误"，
/// 而现场根本看不出是自己拼坏了。
fn q(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

/// 变体① 的报文 —— **逐字**：`{"passport":"<账号>","password":"<密码>","remember":true}`
pub fn body_passport(account: &str, password: &str) -> String {
    format!(
        r#"{{"passport":{},"password":{},"remember":true}}"#,
        q(account),
        q(password)
    )
}

/// 变体② 的报文 —— **逐字**：`{"mail":"<账号>","password":"<密码>","type":<int>}`
pub fn body_mail(account: &str, password: &str, type_int: i64) -> String {
    format!(
        r#"{{"mail":{},"password":{},"type":{}}}"#,
        q(account),
        q(password),
        type_int
    )
}

/// 按变体取报文（`type` 用 [`MAIL_LOGIN_TYPE`]）
pub fn request_body(variant: LoginVariant, account: &str, password: &str) -> String {
    match variant {
        LoginVariant::Passport => body_passport(account, password),
        LoginVariant::Mail => body_mail(account, password, MAIL_LOGIN_TYPE),
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  判定 + 取 token（**两件事绑在一起**，因为它们的形状在两套报文里不同）
// ═══════════════════════════════════════════════════════════════════════

/// 从 `data.token` 取 token（**空串不算拿到**，理由同 `pan_login::extract_qr_token`）
pub fn token_of(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let t = v.get("data")?.get("token")?.as_str()?.trim();
    if t.is_empty() {
        return None;
    }
    Some(t.to_string())
}

/// 变体① 的判定：`message == "success"` **且** 拿得到 token
///
/// ★ 只判 `message`（不判 `code`）：这套报文的判定字段就是 `message`，
///   把它写成 `code == 200` 会让**两套判定互相冒充**（§5.2 的坑）。
pub fn token_passport(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let msg = v.get("message")?.as_str()?.trim();
    if msg != "success" {
        return None;
    }
    token_of(body)
}

/// 变体② 的判定：`code == 200` **且** 拿得到 token
///
/// ★ 只判 JSON 里的 `code`（不是 HTTP 状态码）：这条链路上 HTTP 很可能就是 200，
///   而业务码才是"成没成"的真相（dex 里判的就是 `code`）。
pub fn token_mail(body: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let code = v.get("code")?.as_i64()?;
    if code != 200 {
        return None;
    }
    token_of(body)
}

/// 按变体判定并取 token
pub fn token_from(variant: LoginVariant, body: &str) -> Option<String> {
    match variant {
        LoginVariant::Passport => token_passport(body),
        LoginVariant::Mail => token_mail(body),
    }
}

/// 校验端点的纯判定：`message == "ok"`（**不串进登录链**，见文件头 ③）
pub fn user_info_ok(body: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| {
            v.get("message")
                .and_then(|m| m.as_str())
                .map(|m| m.trim() == "ok")
        })
        .unwrap_or(false)
}

// ═══════════════════════════════════════════════════════════════════════
//  凭据与错误文案（**纯函数**，门禁全在这两段上）
// ═══════════════════════════════════════════════════════════════════════

/// 凭据的 cookie 段：`access_token=<token>`（全仓 token 型网盘的**约定键**）
pub fn cookie_of(token: &str) -> String {
    format!("{ACCESS_TOKEN_PREFIX}{token}")
}

/// 组装凭据（`expires_at: None` —— 123 没给过期时间，见 `PanCredential::is_expired` 的口径）
pub fn credential(account: &str, token: &str, saved_at: i64) -> PanCredential {
    PanCredential {
        kind: PanKind::Pan123,
        account: account.to_string(),
        cookie: cookie_of(token),
        saved_at,
        expires_at: None,
    }
}

/// 把密码从任意文案里抹掉（服务端若回显密码，这里兜住）
pub fn redact(text: &str, password: &str) -> String {
    if password.is_empty() {
        return text.to_string();
    }
    text.replace(password, "***")
}

/// 响应摘要：压平空白 + 截断（错误文案的可读性靠它，不靠把整段 HTML 塞进去）
pub fn summarize(body: &str) -> String {
    let flat = body.split_whitespace().collect::<Vec<_>>().join(" ");
    let n = flat.chars().count();
    if n <= SUMMARY_LIMIT {
        return flat;
    }
    let head: String = flat.chars().take(SUMMARY_LIMIT).collect();
    format!("{head}…（共 {n} 字符）")
}

/// 一次失败的尝试（进错误文案）
#[derive(Debug, Clone)]
pub struct Attempt {
    pub variant: LoginVariant,
    pub status: u16,
    pub body: String,
}

impl Attempt {
    pub fn new(variant: LoginVariant, status: u16, body: &str) -> Self {
        Attempt {
            variant,
            status,
            body: body.to_string(),
        }
    }
}

/// 两套都失败时的错误文案 —— **带 HTTP 码 + 两段响应原文**，且**不带密码**
///
/// ```text
/// 123 云盘账号密码登录没成功（两套报文都试过了）
/// ① passport（判定 message == "success"）：HTTP 401，响应：{...}
/// ② mail（判定 code == 200）：HTTP 200，响应：{...}
/// ```
pub fn failure_text(attempts: &[Attempt], password: &str) -> String {
    let mut out = String::from("123 云盘账号密码登录没成功（两套报文都试过了）");
    for (i, a) in attempts.iter().enumerate() {
        out.push_str(&format!(
            "\n{} {}（判定 {}）：HTTP {}，响应：{}",
            match i {
                0 => "①",
                1 => "②",
                _ => "·",
            },
            a.variant.code(),
            a.variant.judge_text(),
            a.status,
            summarize(&a.body),
        ));
    }
    redact(&out, password)
}

// ═══════════════════════════════════════════════════════════════════════
//  网络层
// ═══════════════════════════════════════════════════════════════════════

fn client() -> Result<reqwest::Client, String> {
    // 与 `pan_login::client` 同一条纪律：**不走环境代理**（登录接口对出口 IP 敏感）
    reqwest::Client::builder()
        .user_agent(UA)
        .timeout(HTTP_TIMEOUT)
        .no_proxy()
        .build()
        .map_err(|e| format!("建 HTTP 客户端失败：{e}"))
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 这家盘支持不支持账号密码登录（**只有 123**）
pub fn supports(kind: PanKind) -> bool {
    matches!(kind, PanKind::Pan123)
}

/// 123 云盘的账号密码登录
///
/// # 流程
/// ```text
/// ① 校验 kind / 账号 / 密码（非 123 直接回"这家不支持账号密码登录"）
/// ② 变体① passport → 判 message == "success" → data.token
/// ③ 变体② mail     → 判 code == 200          → data.token
/// ④ 任一成功 ⇒ 落盘（`pan_auth::save`）后把凭据返回
/// ⑤ 都失败   ⇒ 可读 Err（HTTP 码 + 两段响应摘要）
/// ```
///
/// # 为什么落盘在**本函数里**
/// `pan_login::qr_login_poll` 那条路是"UI 轮询到 confirmed 才落盘"；本函数没有轮询，
/// 一次调用就是一次完整登录 ⇒ 落盘归它。**入口仍然只有一个**：`crate::pan_auth::save`。
pub async fn password_login(
    kind: PanKind,
    account: &str,
    password: &str,
) -> Result<PanCredential, String> {
    if !supports(kind) {
        return Err(format!(
            "这家不支持账号密码登录：{} 的登录方式不是账号密码表单（只有 123 云盘有）",
            kind.display()
        ));
    }

    let account = account.trim();
    let password = password.trim();
    if account.is_empty() {
        return Err("请先填 123 云盘的账号（手机号或邮箱）".to_string());
    }
    if password.is_empty() {
        return Err("请先填 123 云盘的密码".to_string());
    }

    let c = client()?;
    let mut attempts: Vec<Attempt> = Vec::with_capacity(LOGIN_VARIANTS.len());

    for variant in LOGIN_VARIANTS {
        let body = request_body(variant, account, password);
        let resp = c
            .post(LOGIN_URL)
            .header("referer", REFERER)
            .header("origin", ORIGIN)
            .header("platform", PLATFORM)
            .header("app-version", APP_VERSION)
            .header("content-type", "application/json")
            .body(body)
            .send()
            .await
            .map_err(|e| {
                // 网络层错误没有响应体 ⇒ 也要保证不带密码
                format!(
                    "123 云盘登录请求没发出去（{}）：{}",
                    variant.code(),
                    redact(&e.to_string(), password)
                )
            })?;

        let status = resp.status().as_u16();
        let text = resp.text().await.unwrap_or_default();

        if let Some(token) = token_from(variant, &text) {
            let cred = credential(account, &token, now());
            // ★ 这里落盘（唯一入口 `pan_auth::save`）
            crate::pan_auth::save(&cred)?;
            return Ok(cred);
        }

        attempts.push(Attempt::new(variant, status, &text));
    }

    Err(failure_text(&attempts, password))
}

// ═══════════════════════════════════════════════════════════════════════
//  FFI 命令体（ffi.rs 只做参数取值 + 转发；逻辑在这里，便于单测）
// ═══════════════════════════════════════════════════════════════════════

/// `pan_password_login` 命令体
///
/// 返回 `{"ok":true,"account":"…"}`（成功时凭据已落盘，UI 只需拿账号名刷新）。
pub async fn command_password_login(
    kind_code: &str,
    account: &str,
    password: &str,
) -> Result<serde_json::Value, String> {
    // 复用 `pan_login::kind_from_code`（**唯一**的 kind 映射来源，不另抄一份）
    let kind = crate::pan_login::kind_from_code(kind_code)?;
    let cred = password_login(kind, account, password).await?;
    Ok(serde_json::json!({
        "ok": true,
        "account": cred.account,
    }))
}

// ═══════════════════════════════════════════════════════════════════════
//  门禁（纯函数；不需要网络/钥匙串）
// ═══════════════════════════════════════════════════════════════════════
#[cfg(test)]
mod tests {
    use super::*;

    // ── ① 报文逐字 ────────────────────────────────────────────────────

    /// ★★★ 变体① 的报文必须**逐字**：字段名、字段顺序、`remember` 是 `true` 不是 `1`
    ///
    /// ```text
    /// 注入验证：把 `remember":true` 改成 `"remember":1`（或把 passport 换成 phone）
    ///   ⇒ 本条 FAILED，并在断言里打印实际报文。
    /// ```
    #[test]
    fn body_passport_is_verbatim() {
        let b = body_passport("13800000000", "hunter2");
        assert_eq!(
            b,
            r#"{"passport":"13800000000","password":"hunter2","remember":true}"#,
            "★ 变体① 报文必须逐字（含字段顺序与 true 字面量），实际：{b}"
        );
        // 反面：不许出现变体② 的字段名（两套报文**共用端点**，混了就两边都不对）
        assert!(!b.contains("\"mail\""), "变体① 里不该出现 mail：{b}");
        assert!(!b.contains("\"type\""), "变体① 里不该出现 type：{b}");
    }

    /// ★★★ 变体② 的报文必须**逐字**，且 `type` 来自常量（不是硬编码在 format 里）
    #[test]
    fn body_mail_is_verbatim() {
        let b = request_body(LoginVariant::Mail, "a@b.com", "pw");
        assert_eq!(
            b,
            format!(
                r#"{{"mail":"a@b.com","password":"pw","type":{}}}"#,
                MAIL_LOGIN_TYPE
            ),
            "★ 变体② 报文必须逐字，实际：{b}"
        );
        assert!(!b.contains("\"passport\""), "变体② 里不该出现 passport：{b}");
        assert!(!b.contains("\"remember\""), "变体② 里不该出现 remember：{b}");
        // `type` 必须是**数字**（带引号的 "1" 会被服务端当字符串）
        assert!(
            b.contains(r#""type":1"#) || b.contains(&format!(r#""type":{}"#, MAIL_LOGIN_TYPE)),
            "type 必须是裸数字：{b}"
        );
    }

    /// 账号里有引号/反斜杠时，报文仍是合法 JSON（否则服务端只回一句"参数错误"）
    #[test]
    fn body_escapes_quotes_so_json_stays_valid() {
        let b = body_passport(r#"a"b\c"#, "p\tw");
        assert!(
            serde_json::from_str::<serde_json::Value>(&b).is_ok(),
            "拼出来的必须是合法 JSON，实际：{b}"
        );
        let v: serde_json::Value = serde_json::from_str(&b).unwrap();
        assert_eq!(v["passport"], r#"a"b\c"#, "转义后逐字还原");
        assert_eq!(v["password"], "p\tw");
    }

    // ── ② 判定字段（两套**不同**，不许互相冒充）────────────────────────

    /// ★★★ 变体① 只认 `message == "success"`；`code == 200` 在这里**不算成功**
    #[test]
    fn verdict_passport_requires_message_success() {
        assert_eq!(
            token_passport(r#"{"message":"success","data":{"token":"TK1"}}"#).as_deref(),
            Some("TK1")
        );
        // 反空真：`success` 但没 token ≠ 成功
        assert_eq!(token_passport(r#"{"message":"success","data":{}}"#), None);
        assert_eq!(
            token_passport(r#"{"message":"success","data":{"token":""}}"#),
            None,
            "★ 空串不许冒充拿到 token"
        );
        // ★ 关键：`code == 200` 不是变体① 的判据
        assert_eq!(
            token_passport(r#"{"code":200,"data":{"token":"TK1"}}"#),
            None,
            "★★ 变体① 判的是 message，不是 code —— 这里必须 None"
        );
        assert_eq!(
            token_passport(r#"{"message":"password error","code":200,"data":{"token":"TK1"}}"#),
            None,
            "★★ message 不对就是失败（哪怕 code=200、哪怕有 token）"
        );
    }

    /// ★★★ 变体② 只认 `code == 200`；`message == "success"` 在这里**不算成功**
    #[test]
    fn verdict_mail_requires_code_200() {
        assert_eq!(
            token_mail(r#"{"code":200,"data":{"token":"TK2"}}"#).as_deref(),
            Some("TK2")
        );
        assert_eq!(
            token_mail(r#"{"code":400,"data":{"token":"TK2"}}"#),
            None,
            "★ 业务码不是 200 就是失败（哪怕带了 token）"
        );
        // ★ 关键：`message == "success"` 不是变体② 的判据
        assert_eq!(
            token_mail(r#"{"message":"success","data":{"token":"TK2"}}"#),
            None,
            "★★ 变体② 判的是 code，不是 message —— 这里必须 None"
        );
        // 非 JSON / 非数字 code 一律不认
        assert_eq!(token_mail("<html>502</html>"), None);
        assert_eq!(token_mail(r#"{"code":"200","data":{"token":"T"}}"#), None);
    }

    /// 校验端点的判定（`message == "ok"`）—— 与登录判据**分开**，不许混用
    #[test]
    fn user_info_verdict_is_its_own_field() {
        assert!(user_info_ok(r#"{"message":"ok","data":{"uid":1}}"#));
        assert!(!user_info_ok(r#"{"message":"success","data":{}}"#));
        assert!(!user_info_ok(r#"{"code":200,"data":{}}"#));
    }

    /// 尝试顺序 = 先①后②（UI 侧只有一次"登录"，顺序错了就是另一种行为）
    #[test]
    fn variant_order_is_passport_then_mail() {
        assert_eq!(LOGIN_VARIANTS, [LoginVariant::Passport, LoginVariant::Mail]);
        assert_eq!(LoginVariant::Passport.code(), "passport");
        assert_eq!(LoginVariant::Mail.code(), "mail");
    }

    // ── ③ 凭据形状 ────────────────────────────────────────────────────

    /// ★★ 凭据的 cookie 必须是 `access_token=<token>` 这一约定键
    #[test]
    fn credential_uses_access_token_convention_key() {
        let c = credential("13800000000", "TK", 1_700_000_000);
        assert_eq!(c.kind, PanKind::Pan123, "★ 只写 123 的键位");
        assert_eq!(c.account, "13800000000");
        assert_eq!(c.cookie, "access_token=TK");
        assert!(c.cookie.starts_with(ACCESS_TOKEN_PREFIX));
        assert_eq!(c.saved_at, 1_700_000_000);
        assert_eq!(c.expires_at, None, "★ 123 没给过期时间 ⇒ None（视为不过期）");
        assert!(!c.is_expired(now()), "None 的 expires_at 必须判成未过期");
    }

    // ── ④ 错误文案：带 HTTP 码 + 响应摘要，**不带密码** ─────────────────

    /// ★★★ 两段原文都要在里面；密码一个字符都不许出现（哪怕服务端回显了它）
    ///
    /// ```text
    /// 注入验证：把 `failure_text` 里的 `redact(...)` 去掉
    ///   ⇒ 本条 FAILED，读数里会直接出现 `SUPER-SECRET-PW`。
    /// ```
    #[test]
    fn failure_text_quotes_both_bodies_but_never_the_password() {
        const PW: &str = "SUPER-SECRET-PW";
        let attempts = vec![
            Attempt::new(
                LoginVariant::Passport,
                401,
                r#"{"code":401,"message":"账号或密码错误 SUPER-SECRET-PW"}"#,
            ),
            Attempt::new(
                LoginVariant::Mail,
                200,
                r#"{"code":1001,"message":"mail not found","data":null}"#,
            ),
        ];
        let msg = failure_text(&attempts, PW);

        // 两个 HTTP 码 + 两段判定字段
        assert!(msg.contains("HTTP 401"), "①的 HTTP 码要在：{msg}");
        assert!(msg.contains("HTTP 200"), "②的 HTTP 码要在：{msg}");
        assert!(msg.contains("message == \"success\""), "①的判据要点名：{msg}");
        assert!(msg.contains("code == 200"), "②的判据要点名：{msg}");
        // 两段响应原文（摘要）都要在
        assert!(msg.contains("账号或密码错误"), "①的响应要点出来：{msg}");
        assert!(msg.contains("mail not found"), "②的响应要点出来：{msg}");
        // ★ 密码一个字符都不许留
        assert!(!msg.contains(PW), "★★★ 错误文案里出现了密码：{msg}");
        assert!(msg.contains("***"), "★ 被抹掉的位置要留下痕迹：{msg}");
    }

    /// 摘要要压平空白并截断（否则一段 HTML 能把错误框撑爆）
    #[test]
    fn summarize_collapses_whitespace_and_truncates() {
        assert_eq!(summarize("a\n\t b   c"), "a b c");
        let long = "x".repeat(SUMMARY_LIMIT + 50);
        let s = summarize(&long);
        assert!(s.ends_with(&format!("…（共 {} 字符）", SUMMARY_LIMIT + 50)), "{s}");
        assert!(s.chars().count() <= SUMMARY_LIMIT + 20, "截断后不该更长：{s}");
    }

    // ── ⑤ 只支持 123（其余 kind 必须在**任何网络请求之前**被拒）──────────

    /// ★★★ 非 123 的盘直接 Err（不变量：这条路径不会出网）
    ///
    /// ```text
    /// 注入验证：把 `supports` 写成 `true`（所有盘都收）
    ///   ⇒ 本条 FAILED（会真的去打 network，或返回网络类错误而不是"这家不支持"）。
    /// ```
    #[tokio::test]
    async fn other_kinds_are_rejected_before_any_http() {
        for k in [PanKind::Quark, PanKind::Tianyi, PanKind::Pan115, PanKind::Unknown] {
            let e = password_login(k, "acct", "pw").await.expect_err("不许成功");
            assert!(
                e.contains("这家不支持账号密码登录"),
                "{} 必须明说『这家不支持账号密码登录』，实际：{e}",
                k.display()
            );
            assert!(
                e.contains(k.display()),
                "★ 要点名是哪一家（否则用户以为整个功能坏了）：{e}"
            );
            assert!(!e.contains("pw"), "★ 错误文案里不许出现密码：{e}");
        }
    }

    /// 空账号/空密码在任何网络之前就报清楚（同样不出网）
    #[tokio::test]
    async fn empty_fields_are_rejected_before_any_http() {
        let e1 = password_login(PanKind::Pan123, "   ", "pw").await.expect_err("空账号");
        assert!(e1.contains("账号"), "{e1}");
        let e2 = password_login(PanKind::Pan123, "acct", "  ").await.expect_err("空密码");
        assert!(e2.contains("密码"), "{e2}");
        assert!(!e2.contains("  \n"), "文案别带原始空白");
    }

    /// 源码锚点：命令名与参数名必须与 ff i 层/Dart 侧**逐字一致**
    ///
    /// 为什么用源码锚点：`dispatch` 在 test 环境会被"核心未启动"前置闸拦住
    /// ⇒ 只能钉"命令名这个串真的出现在 ffi.rs 的分派表里"。
    #[test]
    fn ffi_command_name_is_wired_in_dispatch_table() {
        let ffi = include_str!("ffi.rs");
        assert!(
            ffi.contains(r#""pan_password_login" =>"#),
            "★ ffi.rs 的分派表里必须有 pan_password_login 分支"
        );
        for p in ["\"kind\"", "\"account\"", "\"password\""] {
            assert!(ffi.contains(p), "★ ffi 层必须取参数 {p}");
        }
        assert!(
            ffi.contains("crate::pan_login_123::command_password_login"),
            "★ ffi 层必须转发到本模块（不在 ffi 里写业务）"
        );
    }
}
