// ═══════════════════════════════════════════════════════════════════════
//  csp_ShortXingya —— 星芽短剧（**本批不注册**：登录不发 token，真网取不到数据）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅（`.probe/ref-subscription.json` 逐字）：
//   {"type":3, "api":"csp_ShortXingya", "key":"星芽短剧", "name":"🌱星芽丨短剧爽看", "ext": null}
// ⇒ ext 为 null ⇒ host 只能写死。
// ```
//
// # ★ 为什么**没有** `register_site!`（三条判据缺第 ③ 条）
//
// ```text
// ① 订阅里这 1 站            ✅
// ② 有可用 host              ✅（u.shytkjgs.com 登录 + app.whjzjx.cn 内容，都是 DEX 常量）
// ③ 真网**真的取到数据**      ❌ —— 登录接口回 200 `{"code":"ok","data":null}`（**不发 token**），
//                              内容接口随后 401 `token check fail`（见读数）
// ```
//
// # 协议取证（`.probe/csp26-downloads/lmw_classes.dex` 直读，**未起 jadx**）
//
// 常量：`.probe/csp25/ShortXingya.txt`（86 条）+ `r3_disasm_v2.py` 的逐方法反汇编。
//
// ```text
// 第一段：登录（`a()` 逐字）
//   POST https://u.shytkjgs.com/user/v3/account/login
//   body = base64( AES/ECB/PKCS5Padding( device JSON ) )     ← **body 是密文，不是 JSON**
//   key  = "B@ecf920Od8A4df7"（16 B，AES-128）
//   device JSON = {device, package_name:"com.jz.xydj", android_id:"ec1280db12795506",
//                  install_first_open:true, first_install_time, last_update_time,
//                  report_link_url:"", timestamp}
//   头 = {user_agent: <Android WebView UA>, content-type: application/json; charset=utf-8}
//   → data.token（**空 ⇒ 后面全 401**）
// 第二段：内容（`b()` 逐字）
//   GET https://app.whjzjx.cn + path，头 {authorization:<token>, platform:"1", version_name:"3.8.3.1"}
//   list   /v1/theater/home_page?theater_class_id=<tid>&class2_id=4&page_num=<n>&page_size=24
//          → data.list[] 每项 {theater:{id,title,cover_url,play_amount_str}}
//   detail /v2/theater_parent/detail?theater_parent_id=<id>
//          → data{introduction,desc_tags,filing,theaters[]}（theaters 里是 son_video_url/video_url）
//   search POST /v3/search  {"text":"<kw>"} → data.search_data[]
// ```
//
// # 真网读数（2026-10-27 实测，直连；原始行见 `.probe/csp-short-live.log`）
//
// ```text
// POST https://u.shytkjgs.com/user/v3/account/login  （真 AES-ECB 体）
//      → 200 · 34 B · {"code":"ok","data":null,"msg":""}      ← ★ 登录"成功"但**没有 token**
// GET  https://app.whjzjx.cn/v1/theater/home_page?…&authorization=（空）
//      → 401 · {"code":"1040401","data":null,"msg":"token check fail","status":401}
// GET  同上、但**一个头都不带**
//      → 200 · {"code":"Unauthorized","data":null,"msg":"签名失败","status":200}
// ```
//
// ★ 两条否证（"我打错" vs "站点死"）：
// ```text
// · 401 的文案是 `token check fail` —— 它读到了我们的头、只是 token 为空 ⇒ **端点活着**。
// · 不带头时变 `签名失败` —— 说明还有一层签名校验；两层都不是"站点挂了"。
// ⇒ 结论：登录没发 token（很可能要真机 device 指纹/额外签名）。如实不注册。
// ```
//
// # 契约边界
// ```text
// · 空 ⇒ Err，文案写明"可能模板改版/风控壳页"
// · `.timeout()` 之后、`.build()` 之前必须 `.no_proxy()`
// · 不新增依赖：AES-ECB 用仓里已有的 `aes`（Cargo.toml 零 diff），base64 用 shared
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use aes::cipher::{BlockEncrypt, KeyInit};

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::{b64_encode, pick_arr, pick_id_str, pick_str};
use crate::tvbox::parse_loose_json;

/// 登录接口（DEX 逐字）
pub const LOGIN_URL: &str = "https://u.shytkjgs.com/user/v3/account/login";
/// 内容 base（DEX 逐字）
pub const BASE: &str = "https://app.whjzjx.cn";
/// AES/ECB 的 key（DEX 逐字，16 B ⇒ AES-128）
pub const AES_KEY: &[u8; 16] = b"B@ecf920Od8A4df7";

pub const PATH_LIST: &str = "/v1/theater/home_page";
pub const PATH_DETAIL: &str = "/v2/theater_parent/detail";
pub const PATH_SEARCH: &str = "/v3/search";

/// 每页 24 条（DEX 里 page_size=24）
pub const PAGE_SIZE: u32 = 24;

/// 登录 UA（DEX 逐字：**Android WebView**，不是桌面浏览器）
const UA: &str = "Mozilla/5.0 (Linux; Android 9; V1938T Build/PQ3A.190705.08211809; wv) \
AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36";

/// 设备指纹常量（DEX 逐字）
const DEVICE: &str = "2a50580e69d38388c94c93605241fb306";
const PACKAGE_NAME: &str = "com.jz.xydj";
const ANDROID_ID: &str = "ec1280db12795506";
const VERSION_NAME: &str = "3.8.3.1";

const TIMEOUT: Duration = Duration::from_secs(20);

/// 分类：DEX 里 5 组 `id/name`（**下标配对**，未逐项实测 —— 被登录挡住）
pub const CATS: &[(&str, &str)] = &[
    ("1", "剧场"),
    ("3", "新剧"),
    ("2", "热播"),
    ("7", "星选"),
    ("5", "阳光"),
];

pub struct ShortXingya {
    client: reqwest::Client,
    /// 登录拿到的 token（`None` ⇒ 还没登录；空串 ⇒ 登录了但服务端没给）
    token: std::sync::Mutex<Option<String>>,
}

impl ShortXingya {
    pub const CLASS: &'static str = "ShortXingya";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // ★ 不读系统代理（全仓判据会扫这一行）：代理会把"站点可用"测成"全宕"。
            .no_proxy()
            .build()
            .expect("build short_xingya http client");
        Self {
            client,
            token: std::sync::Mutex::new(None),
        }
    }

    /// 登录：body 是 **AES/ECB 密文的 base64**，不是明文 JSON
    async fn login(&self) -> Result<String, String> {
        let body = device_json(now_millis());
        let enc = ecb_encrypt_b64(&body.to_string())?;
        let resp = self
            .client
            .post(LOGIN_URL)
            .header("user_agent", UA)
            .header(reqwest::header::CONTENT_TYPE, "application/json; charset=utf-8")
            .body(enc)
            .send()
            .await
            .map_err(|e| format!("登录请求失败（{LOGIN_URL}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("登录读取失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("登录 HTTP {status}（{LOGIN_URL}）：{}", head(&text)));
        }
        let v = parse_loose_json(&text)
            .map_err(|e| format!("登录响应不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
        // DEX 直取 `data.token`；data 为 null 时它自己会抛（"星芽登录失败"）。
        // 这里把"没给 token"讲清楚，不让它变成一句含糊的网络错误。
        let token = v
            .get("data")
            .and_then(|d| d.get("token"))
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        if token.is_empty() {
            let code = pick_str(&v, &["code"]).unwrap_or("");
            let msg = pick_str(&v, &["msg"]).unwrap_or("");
            return Err(format!(
                "星芽登录没发 token（code={code} msg={msg} data=null）：\
                 服务端要真机指纹/额外签名，本仓复现不出来 ⇒ 后续接口一律 401 token check fail"
            ));
        }
        *self.token.lock().map_err(|_| "token 锁坏了".to_string())? = Some(token.clone());
        Ok(token)
    }

    /// 拿 token（首次调用才登录）
    async fn need_token(&self) -> Result<String, String> {
        if let Some(t) = self
            .token
            .lock()
            .map_err(|_| "token 锁坏了".to_string())?
            .as_ref()
            .filter(|t| !t.trim().is_empty())
        {
            return Ok(t.clone());
        }
        self.login().await
    }

    /// 内容侧 GET（带 3 个头）
    async fn get(&self, path_query: &str) -> Result<Value, String> {
        let token = self.need_token().await?;
        let url = format!("{BASE}{path_query}");
        let resp = self
            .client
            .get(&url)
            .header("authorization", token)
            .header("platform", "1")
            .header("version_name", VERSION_NAME)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）：{}", head(&text)));
        }
        let v = parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 160 字：{}）", head(&text)))?;
        require_ok(&v, &url)?;
        Ok(v)
    }
}

impl Default for ShortXingya {
    fn default() -> Self {
        Self::new()
    }
}

fn now_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（离线可测：AES-ECB / 设备体 / 解析）
// ═══════════════════════════════════════════════════════════════════════

/// AES-128/ECB/PKCS5 → base64（DEX `a()` 逐字；ECB 无 IV，所以结果确定）
///
/// ★ 为什么不引 `ecb` crate：仓里只声明了 `aes` + `cbc`（Cargo.toml 零 diff 是硬约束），
///   而 ECB 就是"每块独立调一次 encrypt_block"，自己拼 10 行比加一个依赖干净。
pub fn ecb_encrypt_b64(plain: &str) -> Result<String, String> {
    let cipher = aes::Aes128::new_from_slice(AES_KEY)
        .map_err(|e| format!("AES-128 初始化失败：{e}"))?;
    let mut buf = plain.as_bytes().to_vec();
    let pad = 16 - (buf.len() % 16);
    buf.extend(std::iter::repeat(pad as u8).take(pad)); // PKCS5/PKCS7 填充
    for chunk in buf.chunks_mut(16) {
        let block = aes::cipher::generic_array::GenericArray::from_mut_slice(chunk);
        cipher.encrypt_block(block);
    }
    Ok(b64_encode(&buf).trim().to_string())
}

/// 设备体（DEX `a()` 逐字字段）
pub fn device_json(millis: u128) -> Value {
    serde_json::json!({
        "device": DEVICE,
        "package_name": PACKAGE_NAME,
        "android_id": ANDROID_ID,
        "install_first_open": true,
        "first_install_time": millis,
        "last_update_time": millis,
        "report_link_url": "",
        "timestamp": millis,
    })
}

/// 业务码：`code != "ok"` ⇒ Err（带 code/msg）
///
/// 实测非 ok 的两种：`1040401 token check fail`（401）与 `Unauthorized 签名失败`（200）。
pub fn require_ok(v: &Value, url: &str) -> Result<(), String> {
    let code = pick_str(v, &["code"]).unwrap_or("");
    if code == "ok" || code == "0" {
        return Ok(());
    }
    let msg = pick_str(v, &["msg"]).unwrap_or("");
    Err(format!("星芽接口 {url} code={code} msg={msg}"))
}

/// 列表：`data.list[]` → 每项 `theater{id,title,cover_url,play_amount_str}`
pub fn items_of(v: &Value) -> Vec<CspItem> {
    pick_arr(v, &["data", "list"])
        .map(|a| a.iter().filter_map(item_of).collect())
        .unwrap_or_default()
}

fn item_of(row: &Value) -> Option<CspItem> {
    // DEX：外层对象里取 `theater`，字段都在它里面
    let t = row.get("theater").filter(|t| t.is_object()).unwrap_or(row);
    let id = pick_id_str(t, &["id"])?;
    let title = pick_str(t, &["title"]).unwrap_or("").trim().to_string();
    if title.is_empty() {
        return None;
    }
    Some(CspItem {
        id,
        title,
        cover: pick_str(t, &["cover_url"])
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        subtitle: pick_str(t, &["play_amount_str"])
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
    })
}

/// 解析段落 → CspDetail
///
/// `theaters[]` 每项含 `num`（第几集）与 `son_video_url`/`video_url`（真媒体地址）。
pub fn detail_of(v: &Value, id: &str) -> Result<CspDetail, String> {
    let d = v
        .get("data")
        .filter(|d| d.is_object())
        .ok_or_else(|| format!("详情没有 data（id={id}，可能改版/风控壳页）"))?;
    let title = pick_str(d, &["title"])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| format!("星芽 {id}"));
    let mut eps: Vec<CspEpisode> = Vec::new();
    for (i, row) in pick_arr(d, &["theaters"])
        .map(|a| a.as_slice())
        .unwrap_or(&[])
        .iter()
        .enumerate()
    {
        let url = pick_str(row, &["son_video_url"])
            .or_else(|| pick_str(row, &["video_url"]))
            .unwrap_or("")
            .trim()
            .to_string();
        if url.is_empty() {
            continue;
        }
        let num = pick_id_str(row, &["num"]).unwrap_or_else(|| (i + 1).to_string());
        eps.push(CspEpisode {
            id: url,
            title: format!("第{num}集"),
            flag: "星芽".to_string(),
        });
    }
    if eps.is_empty() {
        return Err(format!("「{title}」没有可播剧集（theaters 为空）"));
    }
    eps.sort_by_key(|e| {
        e.title
            .trim_start_matches('第')
            .trim_end_matches('集')
            .parse::<u32>()
            .unwrap_or(u32::MAX)
    });
    Ok(CspDetail {
        id: id.trim().to_string(),
        title,
        cover: pick_str(d, &["cover_url"])
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        description: pick_str(d, &["introduction"])
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        episodes: eps,
    })
}

// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for ShortXingya {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let categories: Vec<CspCategory> = CATS
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        if categories.is_empty() {
            return Err("星芽分类表为空（内置常量被清空了？）".to_string());
        }
        // DEX 的 homeContent 只给分类（首屏条目走 categoryContent）
        Ok(CspHome {
            categories,
            items: Vec::new(),
        })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let class_id = tid.trim();
        if class_id.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let page = page.max(1);
        // DEX 里首屏固定带 `class2_id=4`（二级筛选默认值），照抄
        let q = format!(
            "{PATH_LIST}?theater_class_id={class_id}&class2_id=4&page_num={page}&page_size={PAGE_SIZE}"
        );
        let v = self.get(&q).await?;
        let items = items_of(&v);
        if items.is_empty() {
            if page > 1 {
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total: None,
                });
            }
            return Err(format!(
                "分类 {class_id} 第 1 页没解析出条目（可能模板改版/风控壳页）"
            ));
        }
        Ok(CspList {
            items,
            page,
            page_count: Some(page + 1),
            total: None,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let pid = id.trim();
        if pid.is_empty() {
            return Err("theater_parent_id 为空".to_string());
        }
        let q = format!("{PATH_DETAIL}?theater_parent_id={pid}");
        let v = self.get(&q).await?;
        detail_of(&v, pid)
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let _ = page; // DEX 的 searchContent 没有分页参数
        let token = self.need_token().await?;
        let url = format!("{BASE}{PATH_SEARCH}");
        let body = serde_json::json!({ "text": kw }).to_string();
        let resp = self
            .client
            .post(&url)
            .header("authorization", token)
            .header("platform", "1")
            .header("version_name", VERSION_NAME)
            .header(reqwest::header::CONTENT_TYPE, "application/json; charset=utf-8")
            .body(body)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）：{}", head(&text)));
        }
        let v = parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 160 字：{}）", head(&text)))?;
        require_ok(&v, &url)?;
        // DEX 读 `data.theater.search_data[]`
        let mut items: Vec<CspItem> = pick_arr(&v, &["data", "theater", "search_data"])
            .or_else(|| pick_arr(&v, &["data", "search_data"]))
            .map(|a| a.iter().filter_map(item_of).collect())
            .unwrap_or_default();
        if items.is_empty() {
            return Err(format!(
                "搜索「{kw}」没解析出条目（可能模板改版/风控壳页）"
            ));
        }
        items.shrink_to_fit();
        Ok(CspList {
            items,
            page: 1,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        // ★ 未实测成功（登录不发 token）⇒ 不声明 true
        false
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let raw = id.trim();
        if raw.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if !crate::tvbox::starts_http(raw) {
            return Err(format!("播放 id 不是 http 地址：{raw}"));
        }
        Ok(vec![CspPlay {
            url: raw.to_string(),
            headers: vec![("User-Agent".to_string(), UA.to_string())],
            label: Some("星芽".to_string()),
        }])
    }
}

// ══ ⚠️ **没有 `register_site!`** ══
//
// 缺第 ③ 条：登录 `data:null`（不发 token）⇒ 内容接口一律 401 token check fail。

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── ① AES-ECB：真站点就是用这把 key（形状必须与 Java 一侧逐字一致）──

    #[test]
    fn ecb_is_deterministic_and_padded_to_16() {
        let a = ecb_encrypt_b64("{\"a\":1}").unwrap();
        let b = ecb_encrypt_b64("{\"a\":1}").unwrap();
        assert_eq!(a, b, "ECB 无随机 IV ⇒ 同一明文必得同一密文");
        let raw = crate::csp::shared::b64_decode(&a).unwrap();
        assert_eq!(raw.len() % 16, 0, "PKCS5 必须补齐到 16 的倍数");
        // 8 字节明文 → 一整块（16B）；16 字节明文 → 两块（32B）
        assert_eq!(crate::csp::shared::b64_decode(&ecb_encrypt_b64("12345678").unwrap()).unwrap().len(), 16);
        assert_eq!(
            crate::csp::shared::b64_decode(&ecb_encrypt_b64("1234567890123456").unwrap()).unwrap().len(),
            32
        );
    }

    #[test]
    fn ecb_key_is_the_dex_literal() {
        assert_eq!(AES_KEY, b"B@ecf920Od8A4df7");
        assert_eq!(AES_KEY.len(), 16, "16 字节 ⇒ AES-128（不是 256）");
    }

    #[test]
    fn device_body_keeps_the_dex_fields() {
        let j = device_json(1793116874758);
        for k in [
            "device",
            "package_name",
            "android_id",
            "install_first_open",
            "first_install_time",
            "last_update_time",
            "report_link_url",
            "timestamp",
        ] {
            assert!(j.get(k).is_some(), "设备体缺字段：{k}");
        }
        assert_eq!(j["device"], json!(DEVICE));
        assert_eq!(j["package_name"], json!("com.jz.xydj"));
        assert_eq!(j["timestamp"], json!(1793116874758u64));
    }

    // ── ② 真实响应片段（2026-10-27 实测原文）──

    #[test]
    fn real_login_success_without_token_is_an_error() {
        // ★ 实测原文：登录 200 但 data 是 null
        let raw = r#"{"code":"ok","data":null,"msg":""}"#;
        let v = parse_loose_json(raw).expect("真实响应必须是合法 JSON");
        assert!(require_ok(&v, LOGIN_URL).is_ok(), "登录本身 code=ok");
        let token = v
            .get("data")
            .and_then(|d| d.get("token"))
            .and_then(|t| t.as_str())
            .unwrap_or("");
        assert!(token.is_empty(), "★ 实测就是没有 token —— 这是不注册的原因");
    }

    #[test]
    fn real_token_check_fail_is_error() {
        let raw = r#"{"code":"1040401","data":null,"msg":"token check fail","status":401}"#;
        let v = parse_loose_json(raw).unwrap();
        let e = require_ok(&v, PATH_LIST).expect_err("★ 401 必须 Err");
        assert!(e.contains("1040401"), "{e}");
        assert!(e.contains("token check fail"), "{e}");
    }

    #[test]
    fn real_signature_fail_is_error() {
        let raw = r#"{"code":"Unauthorized","data":null,"msg":"签名失败","status":200}"#;
        let v = parse_loose_json(raw).unwrap();
        let e = require_ok(&v, PATH_LIST).expect_err("★ 200 也要看 code");
        assert!(e.contains("签名失败"), "{e}");
    }

    #[test]
    fn items_come_from_data_list_theater_objects() {
        let v = json!({"code":"ok","data":{"list":[
            {"theater":{"id":101,"title":"剧一","cover_url":"https://c/1.jpg","play_amount_str":"1.2亿播放"}},
            {"theater":{"id":102,"title":"剧二","cover_url":"https://c/2.jpg"}}
        ]}});
        let items = items_of(&v);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "101");
        assert_eq!(items[0].subtitle.as_deref(), Some("1.2亿播放"));
        assert!(items[1].subtitle.is_none());
    }

    #[test]
    fn detail_builds_sorted_episodes() {
        let v = json!({"code":"ok","data":{"title":"剧一","introduction":"简介","cover_url":"https://c/1.jpg",
            "theaters":[{"num":"2","son_video_url":"https://v/2.mp4"},{"num":"1","video_url":"https://v/1.mp4"}]}});
        let d = detail_of(&v, "101").expect("真实结构必须能解析");
        assert_eq!(d.title, "剧一");
        assert_eq!(d.episodes.len(), 2);
        assert_eq!(d.episodes[0].title, "第1集", "★ 必须按 num 排好");
        assert_eq!(d.episodes[0].id, "https://v/1.mp4");
        assert_eq!(d.episodes[1].id, "https://v/2.mp4");
    }

    #[test]
    fn empty_detail_is_error() {
        let e = detail_of(&json!({"code":"ok","data":{"title":"空"}}), "1").unwrap_err();
        assert!(e.contains("theaters"), "{e}");
        assert!(detail_of(&json!({}), "1").unwrap_err().contains("data"));
    }

    #[test]
    fn categories_are_the_dex_five() {
        assert_eq!(CATS.len(), 5);
        assert_eq!(CATS[0], ("1", "剧场"));
        assert_eq!(CATS[4], ("5", "阳光"));
    }

    // ── ③ **不注册** + 契约形态 ──

    #[test]
    fn must_not_register_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("short_xingya.rs"));
        assert!(!flat.contains("register_site!(ShortXingya)"), "★ 登录不发 token ⇒ 不注册");
        assert!(!crate::csp::is_implemented("csp_ShortXingya"), "★ 不许进注册表");
    }

    #[test]
    fn class_name_is_exact() {
        assert_eq!(ShortXingya::CLASS, "ShortXingya");
    }

    #[test]
    fn client_builder_turns_off_proxy() {
        let src = crate::csp::shared::impl_src_only(include_str!("short_xingya.rs"));
        let t = src.find(".timeout(TIMEOUT)").expect("必须有 timeout");
        let n = src.find(".no_proxy()").expect("★ 必须有 .no_proxy()");
        let b = src.find(".build()").expect("必须有 build");
        assert!(t < n && n < b, "★ .no_proxy() 必须在 timeout 之后、build 之前");
    }

    #[test]
    fn search_is_declared_unsupported_because_never_verified() {
        assert!(!ShortXingya::new().supports_search());
    }

    #[tokio::test]
    async fn empty_inputs_are_rejected_before_network() {
        let s = ShortXingya::new();
        assert!(s.detail(" ", "").await.is_err());
        assert!(s.search("  ", 1, "").await.is_err());
        assert!(s.play("", "not-a-url", "").await.is_err());
        assert!(s.list("", 1, "").await.is_err());
    }

    #[tokio::test]
    async fn home_returns_five_categories_without_network() {
        let s = ShortXingya::new();
        let h = s.home("").await.expect("分类是内置常量");
        assert_eq!(h.categories.len(), 5);
        assert!(h.items.is_empty());
    }
}
