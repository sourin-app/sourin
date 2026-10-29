//! task-5（rust-login，2026-10-30）的独立门禁：4.1 阿里 bizExt / 4.2 115 换 cookie / 4.3 百度 unicast
//!
//! # 为什么是独立文件
//! 纪律要求"测试写新建独立测试文件，不动既有共享测试文件"。本文件以
//! `#[cfg(test)] mod pan_login_t5_gate;` 挂在 `pan_login.rs` 里（子模块可读父模块私有
//! 纯函数，`cargo test --lib <过滤>` 直达），既有 `mod tests` 一行未动。
//!
//! # 证红清单（禁止假绿门禁）
//! ```text
//! · 4.1：篡改一位的 bizExt ⇒ Err；camel/snake 两套键都缺 ⇒ Err；
//!        "URL-safe 映射是否承重"用新旧两种解码路径的结果差断言（映射被回退 ⇒ 本文件红）。
//! · 4.2：四键缺一 ⇒ Err；\u 转义文案未解码 ⇒ 精确断言失败（含坏转义回退）。
//! · 4.3：unicast URL 多一个 `&v=` ⇒ 红；channel_v 坏 JSON/缺 v ⇒ None（调用点判 Pending）。
//! 真实密文向量：批末真机扫码后落 .probe/（脱敏），届时补"真向量进、真 token 出"的用例。
//! ```

use super::*;

// ═══════════════ 4.1 阿里 bizExt ═══════════════

/// 测试自算的 URL-safe 编码器（独立于被测代码：标准 base64 后做字母表替换、去填充）
fn urlsafe_of_std(std: &str) -> String {
    std.trim_end_matches('=')
        .replace('+', "-")
        .replace('/', "_")
}

#[test]
fn b64_decode_treats_urlsafe_chars_as_alphabet() {
    // 同一段字节，标准字母表与 URL-safe 字母表必须解出**同一样东西**
    let raw = b"{\"pds_login_result\":{\"refreshToken\":\"RT-1\",\"accessToken\":\"AT-1\"}}";
    let std = b64_encode(raw);
    let url = urlsafe_of_std(&std);
    assert_ne!(std, url, "向量本身必须真的用到 -/_（否则测了个寂寞）");
    assert_eq!(b64_decode(&std), b64_decode(&url));
}

#[test]
fn b64_decode_urlsafe_mapping_is_load_bearing() {
    // ★ 注入证红：模拟旧实现（把 -/_ 当非法字符跳过）的解码路径，断言结果**不同**。
    //   若有人把 '-'/'_' 的映射改回"跳过"，本条 + 上一条同时红。
    let url = "Q-pQ_Q"; // 含 - 与 _
    let old_skip_decode = |s: &str| -> Option<Vec<u8>> {
        let cleaned: String = s
            .chars()
            .filter(|c| !c.is_whitespace() && *c != '=' && *c != '-' && *c != '_')
            .collect();
        b64_decode(&cleaned)
    };
    let fixed = b64_decode(url).unwrap();
    let old = old_skip_decode(url).unwrap();
    assert_ne!(
        fixed, old,
        "URL-safe 映射必须是承重的：跳过路径应产出不同字节（现场 index 200 UTF-8 垃圾的根因）"
    );
}

#[test]
fn aliyun_bizext_camelcase_keys_decode() {
    // dex 逐字：bizExt 解码后是 pds_login_result.{accessToken, refreshToken, expiresIn}
    // （merge.d.a POJO 的 @SerializedName，.probe/pan-login-t5-forensics5.log）
    let inner = r#"{"pds_login_result":{"accessToken":"AT-C1","refreshToken":"RT-C1","expiresIn":7201}}"#;
    let biz = urlsafe_of_std(&b64_encode(inner.as_bytes()));
    let body = format!(r#"{{"content":{{"data":{{"qrCodeStatus":"CONFIRMED","bizExt":"{biz}"}}}}}}"#);
    let (access, refresh, expires) = aliyun_token_from_body(&body).unwrap();
    assert_eq!(access, "AT-C1");
    assert_eq!(refresh, "RT-C1");
    assert_eq!(expires, Some(7201));
}

#[test]
fn aliyun_bizext_snakecase_keys_still_decode() {
    // 社区公开实现通行 snake_case ⇒ 兜底路径必须保住（旧行为不回退）
    let inner = r#"{"pds_login_result":{"access_token":"AT-S","refresh_token":"RT-S","expires_in":7200}}"#;
    let biz = b64_encode(inner.as_bytes());
    let body = format!(r#"{{"content":{{"data":{{"bizExt":"{biz}"}}}}}}"#);
    let (access, refresh, _) = aliyun_token_from_body(&body).unwrap();
    assert_eq!(access, "AT-S");
    assert_eq!(refresh, "RT-S");
}

#[test]
fn aliyun_bizext_corrupted_bitstream_is_red() {
    // ★ 坏数据必红：bizExt 中段被改 ⇒ 要么 base64/UTF-8 炸、要么 JSON 炸，总之 Err
    let inner = r#"{"pds_login_result":{"accessToken":"AT","refreshToken":"RT"}}"#;
    let biz = b64_encode(inner.as_bytes());
    let mut chars: Vec<char> = biz.chars().collect();
    let mid = chars.len() / 2;
    chars[mid] = if chars[mid] == 'A' { 'B' } else { 'A' };
    let bad: String = chars.into_iter().collect();
    let body = format!(r#"{{"content":{{"data":{{"bizExt":"{bad}"}}}}}}"#);
    assert!(
        aliyun_token_from_body(&body).is_err(),
        "篡改后的 bizExt 必须报错（不许静默出假 token）"
    );
}

#[test]
fn aliyun_bizext_missing_both_key_sets_is_red() {
    let inner = r#"{"pds_login_result":{"nickName":"x"}}"#;
    let biz = urlsafe_of_std(&b64_encode(inner.as_bytes()));
    let body = format!(r#"{{"content":{{"data":{{"bizExt":"{biz}"}}}}}}"#);
    let err = aliyun_token_from_body(&body).unwrap_err();
    assert!(err.contains("accessToken"), "报错要点名缺什么：{err}");
}

// ═══════════════ 4.2 115 换 cookie ═══════════════

#[test]
fn pan115_login_form_is_dex_verbatim() {
    // dex 逐字（Qr115.login）：form = {account: <uid>, app: "qandroid"}
    // （.probe/pan-login-t5-forensics.log §②b；旧版只发 uid ⇒ 40100000 参数错误）
    let form = pan115_login_form("UID1");
    assert_eq!(form[0], ("account".to_string(), "UID1".to_string()));
    assert_eq!(form[1], ("app".to_string(), "qandroid".to_string()));
    assert_eq!(form.len(), 2);
}

#[test]
fn unescape_json_u_decodes_cjk_escapes() {
    assert_eq!(unescape_json_u(r"\u53c2\u6570\u9519\u8bef"), "参数错误");
    assert_eq!(unescape_json_u("纯中文无转义"), "纯中文无转义");
    assert_eq!(unescape_json_u(r"a\u0041b"), "aAb");
    // 坏转义原样回退（不吞字符）
    assert_eq!(unescape_json_u(r"\uZZ"), r"\uZZ");
    assert_eq!(unescape_json_u(r"尾随\"), r"尾随\");
}

#[test]
fn pan115_server_message_reads_and_unescapes() {
    let body = r#"{"state":0,"code":40100000,"message":"\u53c2\u6570\u9519\u8bef"}"#;
    assert_eq!(pan115_server_message(body), "参数错误");
    // 没有 message ⇒ 空串（调用点据此省略文案）
    assert_eq!(pan115_server_message(r#"{"state":0}"#), "");
}

#[test]
fn pan115_cookie_missing_any_of_four_keys_is_red() {
    // 取证给的验收判据：UID/CID/SEID/KID 四键缺一不可（缺 KID ⇒ Err）
    let body = r#"{"data":{"cookie":{"UID":"u","CID":"c","SEID":"s"}}}"#;
    let err = pan115_cookie_from_body(body).unwrap_err();
    assert!(err.contains("KID"), "报错要点名缺的键：{err}");
    // 完整四键 ⇒ 拼出 Cookie
    let ok = r#"{"data":{"cookie":{"UID":"u","CID":"c","SEID":"s","KID":"k"}}}"#;
    assert_eq!(pan115_cookie_from_body(ok).unwrap(), "UID=u; CID=c; SEID=s; KID=k");
}

// ═══════════════ 4.3 百度 unicast / channel_v ═══════════════

#[test]
fn baidu_unicast_url_has_no_v_param() {
    // dex 逐字（merge.b.j.t）：unicast 只有 channel_id，没有 &v（旧实现多带的已删）
    assert_eq!(
        baidu_unicast_url("sig1"),
        "https://passport.baidu.com/channel/unicast?channel_id=sig1"
    );
    assert!(
        !baidu_unicast_url("sig1").contains("&v="),
        "★ 注入证红：若 &v= 回来了（旧猜测），本条红"
    );
}

#[test]
fn baidu_channel_v_extracts_status_and_v() {
    // 真形状：channel_v 是个 JSON **字符串**，里面才有 status / v
    let body = r#"{"errno":0,"channel_v":"{\"status\":0,\"v\":\"BDUSS-TOKEN\"}"}"#;
    let cv = baidu_channel_v_of(body).unwrap();
    assert_eq!(cv.status, Some(0));
    assert_eq!(cv.v, "BDUSS-TOKEN");

    // 未确认（status 非 0 / 无 channel_v）⇒ None（调用点判 Pending，不猜 Confirmed）
    let notyet = r#"{"errno":0,"channel_v":"{\"status\":2,\"v\":\"\"}"}"#;
    assert_eq!(baidu_channel_v_of(notyet).unwrap().status, Some(2));
    assert_eq!(baidu_channel_v_of(r#"{"errno":0}"#), None);
    // ★ 坏数据必红：channel_v 不是 JSON ⇒ None（绝不能当成已确认）
    assert_eq!(
        baidu_channel_v_of(r#"{"errno":0,"channel_v":"不是JSON"}"#),
        None
    );
}

#[test]
fn baidu_img_fetch_url_appends_dex_logpage() {
    assert_eq!(
        baidu_img_fetch_url("https://passport.baidu.com/v2/api/qrcode?sign=s1&lp=pc&qrloginfrom=pc"),
        "https://passport.baidu.com/v2/api/qrcode?sign=s1&lp=pc&qrloginfrom=pc\
         &logPage=traceId%3Apc_loginv5_1742970205%2ClogPage%3Aloginv5"
    );
}

#[test]
fn baidu_qrbduss_url_uses_millis_as_v() {
    // dex 逐字：v=System.currentTimeMillis()，bduss=channel_v.v
    assert_eq!(
        baidu_qrbduss_url("1790000000000", "BD1"),
        "https://passport.baidu.com/v3/login/main/qrbdusslogin?v=1790000000000&bduss=BD1"
    );
}
