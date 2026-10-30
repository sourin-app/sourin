// ═══════════════════════════════════════════════════════════════════════
//  天翼云盘（PanKind::Tianyi）—— 扫码链路：**只做到出码，做不完回调**
// ═══════════════════════════════════════════════════════════════════════
//
// # 真实网络读数（2026-10-29 现场 curl，逐字）
//
// ```text
// ① GET cloud.189.cn/api/portal/loginUrl.action?…（关闭重定向）
//    → 302，Location = open.e.189.cn/api/logbox/oauth2/separate/auth/unifyAccountLogin.do
//                       ?appId=cloud&version=v1.1&clientType=1&format=redirect&paras=<长串>&sign=<串>
//    ⇒ **没有** 参考实现里那两个 `lt` / `reqId`（位置还在，但改版后不再带）。
// ② POST open.e.189.cn/api/logbox/oauth2/appConf.do  (appKey=cloud&version=2.0)
//    → {"result":22001,"msg":"非正确来源"}      ⇒ 缺 lt/reqId 就不让过。
// ③ POST open.e.189.cn/api/logbox/oauth2/getUUID.do (appKey=cloud&version=2.0)
//    → {"result":0,"uuid":"…qrClinentLogin.do?paras=new_uuid%3D…",
//       "encryuuid":"…","encodeuuid":"https%3A%2F%2F…qrClinentLogin.do%3Fparas%3Dnew_uuid%253D…"}
//    ⇒ **这一跳单独就能通**：二维码内容 = URLDecode(encodeuuid)。
// ④ POST …/qrcodeLoginState.do（带 uuid/encryuuid，其余参数尽力补）
//    → {"result":-20099,"msg":"页面已过期，刷新页面后重试"}
//    ⇒ 轮询依赖 ② 那次会话产出的 `paramId`/`reqId`，而它们现在拿不到。
// ```
//
// # 因此这里的结论（不是"没做"，是"做不完整"）
//
// ```text
// 能出码（③ 真通），但**扫完没有可用的轮询**（④ 恒 -20099）⇒ 给用户一个扫了也没结果的码，
// 比明说更糟 —— 所以 `tianyi_start` 直接如实报错，并说清缺的是哪一样。
// 出码能力保留在 [`tianyi_qr_from_getuuid_body`]，等 logbox 会话参数拿到后接上就能用。
// ```
//
// # 何时该翻案
// ```text
// 拿到带 lt/reqId 的 loginUrl 响应（旧版格式/旧客户端 UA），或抓到网页端登录时的
// paramId 来源后：把 ② 接上，`tianyi_start` 改成真出码，`tianyi_poll` 用 ④ 轮询。
// ```

use crate::pan::PanKind;

use super::pan_login::{PollOutcome, QrSession};

/// 天翼的这一族判别（`pan_login::qr_login_poll` 用它分流；目前只有天翼自己）
pub fn is_tianyi_login(kind: PanKind) -> bool {
    matches!(kind, PanKind::Tianyi)
}

/// 天翼出码的失败文案（**唯一一处**，`start` 与测试共用同一句判据）
pub const TIANYI_UNSUPPORTED: &str = "天翼云盘的扫码登录做不完整：出码那一跳（getUUID.do）能通，\
     但轮询（qrcodeLoginState.do）依赖 logbox 会话里的 `paramId/reqId`，\
     而 `loginUrl.action` 改版后只给 `paras/sign`（appConf.do 直接回 22001 非正确来源，\
     qrcodeLoginState.do 回 -20099 页面已过期）⇒ 给一个扫了也没结果的码没有意义。\
     需要天翼支持时请先在网页端登录。";

/// 从 `getUUID.do` 的响应里取 `(二维码内容, uuid, encryuuid)`
///
/// # 为什么保留它
/// ```text
/// 这一跳**真网验通了**（2026-10-29）：encodeuuid 解码后就是
/// `https://open.e.189.cn/api/account/qrClinentLogin.do?paras=new_uuid=…`。
/// 等轮询能用时直接接上即可，不必重新取证。
/// ```
pub fn tianyi_qr_from_getuuid_body(body: &str) -> Option<(String, String, String)> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    let enc = v.get("encryuuid")?.as_str()?.trim().to_string();
    if enc.is_empty() {
        return None;
    }
    // `encodeuuid` 是**两层编码**（真读数里是 `%253D`）⇒ 解两次才是可扫的 URL
    let once = url_decode(v.get("encodeuuid")?.as_str()?);
    let decoded = if once.contains('%') { url_decode(&once) } else { once };
    if decoded.is_empty() {
        return None;
    }
    // `uuid` 字段里带 `new_uuid%3D…`（编码过）⇒ 先解码再取
    let raw_uuid = url_decode(v.get("uuid").and_then(|x| x.as_str()).unwrap_or("").trim());
    let uuid = raw_uuid
        .split("new_uuid=")
        .nth(1)
        .unwrap_or(&raw_uuid)
        .split('&')
        .next()
        .unwrap_or("")
        .to_string();
    Some((decoded, uuid, enc))
}

/// 最小 URL 解码（`%XX` + `+`；`%` 后不完整就原样保留）
fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => {
                let hex = std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("");
                match u8::from_str_radix(hex, 16) {
                    Ok(v) => {
                        out.push(v);
                        i += 3;
                    }
                    Err(_) => {
                        out.push(b[i]);
                        i += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

/// 天翼：**如实报"做不完整"**（理由见文件头三条真读数）
pub async fn tianyi_start() -> Result<QrSession, String> {
    Err(TIANYI_UNSUPPORTED.to_string())
}

/// 天翼：轮询同样如实报（没有可用的会话）
pub async fn tianyi_poll(_key: &str) -> Result<PollOutcome, String> {
    Err(TIANYI_UNSUPPORTED.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★ 出码那一跳的解析（真报文逐字；等轮询能用时直接复用）
    ///
    /// ```text
    /// 注入验证：把 `new_uuid=` 的截取去掉 ⇒ 第二条断言 FAILED。
    /// ```
    #[test]
    fn getuuid_body_yields_qr_content() {
        let body = r#"{"result":0,"msg":"操作成功",
            "uuid":"https://open.e.189.cn/api/account/qrClinentLogin.do?paras=new_uuid%3D93vss0mgrm8g9k78",
            "encryuuid":"B8151BCF6E53","encodeuuid":"https%3A%2F%2Fopen.e.189.cn%2Fapi%2Faccount%2FqrClinentLogin.do%3Fparas%3Dnew_uuid%253D93vss0mgrm8g9k78"}"#;
        let (qr, uuid, enc) = tianyi_qr_from_getuuid_body(body).expect("真报文必须能解析");
        assert!(
            qr.starts_with("https://open.e.189.cn/api/account/qrClinentLogin.do?paras=new_uuid="),
            "{qr}"
        );
        assert_eq!(uuid, "93vss0mgrm8g9k78", "★ uuid 要从 URL 里取出来");
        assert_eq!(enc, "B8151BCF6E53");
    }

    /// ★★★ 现状：start/poll 必须**如实报**"做不完整"，不许返回空会话/假二维码
    ///
    /// ```text
    /// 注入验证：把 `TIANYI_UNSUPPORTED` 换成空串 ⇒ 本条 FAILED。
    /// ```
    #[tokio::test]
    async fn tianyi_says_it_cannot_complete_instead_of_faking() {
        let e = tianyi_start().await.expect_err("必须 Err");
        assert!(e.contains("做不完整"), "{e}");
        assert!(e.contains("22001") || e.contains("-20099"), "要带真读数：{e}");
        let e2 = tianyi_poll("k").await.expect_err("必须 Err");
        assert_eq!(e2, e);
    }

    /// ★★ 门户判别：只认天翼一家（`pan_login::qr_login_poll` 靠它分流）
    #[test]
    fn is_tianyi_login_is_exactly_one_kind() {
        assert!(is_tianyi_login(PanKind::Tianyi));
        for k in [PanKind::Quark, PanKind::Uc, PanKind::Guangya, PanKind::Xunlei] {
            assert!(!is_tianyi_login(k));
        }
    }

    #[test]
    fn url_decode_handles_percent_and_plus() {
        assert_eq!(url_decode("a%20b+c"), "a b c");
        assert_eq!(url_decode("%E4%B8%AD"), "中");
        assert_eq!(url_decode("%4"), "%4", "不完整就原样保留");
    }
}