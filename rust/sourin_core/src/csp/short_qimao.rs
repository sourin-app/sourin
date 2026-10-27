// ═══════════════════════════════════════════════════════════════════════
//  csp_ShortQimao —— 七猫短剧（**本批不注册**：验签方案未复现，真网取不到数据）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅（`.probe/ref-subscription.json` 逐字）：
//   {"type":3, "api":"csp_ShortQimao", "key":"七猫短剧", "name":"🐱七猫丨短剧爽看", "ext": null}
// ⇒ ext 为 null ⇒ host 只能写死。
// ```
//
// # ★ 为什么**没有** `register_site!`（三条判据缺第 ③ 条）
//
// ```text
// ① 订阅里这 1 站                ✅
// ② 有可用 host                  ✅（api-store / api-read 都是 DEX 常量，另有 neptune 域名表）
// ③ 真网**真的取到数据**          ❌ —— 端点活着，但服务端回**验签失败**（见读数）
// ```
//
// # 协议取证（`.probe/csp26-downloads/lmw_classes.dex` 直读，**未起 jadx**）
//
// 常量：`.probe/csp25/ShortQimao.txt`（129 条）+ `r3_disasm_v2.py` 的逐方法反汇编。
//
// ```text
// 两个 base（`<init>` 逐字）
//   a = https://api-store.qmplaylet.com     ← 内容接口（index / search）
//   b = https://api-read.qmplaylet.com      ← 阅读侧（本类主要用不到；实测它没有这些路径）
// 另有域名表 https://neptune.qmplaylet.com/playlet-domain-android.json
//   → {"data":{"main":"https://api.qmplaylet.com","ks":"https://api-read.qmplaylet.com",…}}
//   （实测 200 · 587 B；本实现只用 DEX 里写死的 a，域名表仅作排障线索）
//
// qm-params（`a()` 逐字，这是最"怪"的一处）
//   device 18 键 {static_score,uuid,device-id,mac,sourceuid,refresh-type,model,wlb-imei,
//                 AUTHORIZATION,brand,oaid,oaid-no-cache,sys-ver,trusted-id,phone-level,
//                 imei,wlb-uid,session-id}
//   → Gson 序列化 → Base64 → **按自定义字母表逐字符替换**：
//       '+'→'P'  '/'→'X'
//       数字 0-9 → "MUlErYWbdJ"
//       A-Z     → "9saI0oy_HGitgNA8Fk3hfRqC4p"
//       a-z     → "mBOuc6Kx5T-2zSZ1VvjQ7DwnLe"
//   这就是 header `qm-params` 的值（**不是**标准 base64，别直接 base64 出去）
//
// 头（`a()` 逐字 11 项）
//   authorization=6bcc46919d10d06a  reg=''  is-white=''  user-agent=webviewversion/0
//   net-env=1  channel=va-vivo_lf  platform=android  application-id=com.duoduo.read
//   app-version=10001  qm-params=<上面那串>  no-permiss=3
//   另有 sign：md5(参数按 key 排序后拼 "k=v" + 密钥 "d3dGiJc651gSQ8w1")
//
// 端点
//   list/home  GET {a}/api/v1/playlet/index        参数 tag_id / next_id / sign
//   detail     GET {a}/player/api/v1/playlet/info  参数 playlet_id / sign
//   search     GET {a}/api/v1/playlet/search       参数 wd / page / read_preference / sign
// ```
//
// # 真网读数（2026-10-27 实测，直连；原始行见 `.probe/csp-short-live.log`）
//
// ```text
// GET https://api-store.qmplaylet.com/api/v1/playlet/index
//     （无签名）→ 200 · 131 B · {"errors":{"code":"44010120","title":"验签失败","details":"验签失败"}}
// GET https://api-read.qmplaylet.com/api/v1/playlet/index
//     → **404** · 18 B · "404 page not found"（读侧没有这个路径 —— 说明 a/b 分工是真的）
// GET https://neptune.qmplaylet.com/playlet-domain-android.json → 200 · 587 B · 域名表可用
// 试了 8 种签名/头部组合（含 qm-params scramble + sign 查询串 + AUTHORIZATION=md5(标准串)）
//     → **全部仍是 44010120 验签失败**
// ```
//
// ★ 这条**不是**"站点挂了"：它给的是**结构化业务错误**（44010120 + title/details），
//   而 404 只出现在"读侧 + store 路径"这种**我打错**的组合上。结论：签名方案没复现，
//   缺的很可能是一个**服务端下发的 app 密钥**（DEX 里只有 `6bcc46919d10d06a` 与
//   `d3dGiJc651gSQ8w1` 两个常量）。⇒ 如实不注册，不把"我打错"写成"站点死"。
//
// # 契约边界
// ```text
// · 空 ⇒ Err（文案含"可能模板改版/风控壳页"）
// · `.timeout()` 之后、`.build()` 之前必须 `.no_proxy()`
// · 不新增依赖（md5 用 shared::md5_hex，base64 用 shared::b64_encode）
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::{b64_encode, md5_hex, pick_arr, pick_id_str, pick_str};
use crate::tvbox::parse_loose_json;

/// 内容侧 base（DEX `<init>` 字段 `a`）
pub const BASE_STORE: &str = "https://api-store.qmplaylet.com";
/// 阅读侧 base（DEX `<init>` 字段 `b`；实测该 base 上没有 index 路径 ⇒ 本类不用它取内容）
pub const BASE_READ: &str = "https://api-read.qmplaylet.com";
/// 域名表（排障线索，不在主链路）
pub const DOMAIN_TABLE: &str = "https://neptune.qmplaylet.com/playlet-domain-android.json";

pub const API_INDEX: &str = "/api/v1/playlet/index";
pub const API_INFO: &str = "/player/api/v1/playlet/info";
pub const API_SEARCH: &str = "/api/v1/playlet/search";

/// 签名密钥（DEX 逐字）
pub const SIGN_KEY: &str = "d3dGiJc651gSQ8w1";
/// 固定 authorization 值（DEX 逐字）
pub const AUTH: &str = "6bcc46919d10d06a";

/// qm-params 的字母表（DEX 逐字，三张表 + 两个单字符替换）
pub const MAP_DIGIT: &str = "MUlErYWbdJ";
pub const MAP_UPPER: &str = "9saI0oy_HGitgNA8Fk3hfRqC4p";
pub const MAP_LOWER: &str = "mBOuc6Kx5T-2zSZ1VvjQ7DwnLe";

const UA_HDR: &str = "webviewversion/0";
const TIMEOUT: Duration = Duration::from_secs(20);

pub struct ShortQimao {
    client: reqwest::Client,
}

impl ShortQimao {
    pub const CLASS: &'static str = "ShortQimao";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA_HDR)
            .timeout(TIMEOUT)
            // ★ 不读系统代理（全仓判据会扫这一行）：代理会把"站点可用"测成"全宕"。
            .no_proxy()
            .build()
            .expect("build short_qimao http client");
        Self { client }
    }

    /// 一次 GET（带 sign 参数 + 11 个头）
    async fn get(&self, url: &str, params: &[(String, String)]) -> Result<Value, String> {
        let sign = sign_of(params);
        let qm = qm_params(now_millis());
        let mut req = self
            .client
            .get(url)
            .header("authorization", AUTH)
            .header("reg", "")
            .header("is-white", "")
            .header("user-agent", UA_HDR)
            .header("net-env", "1")
            .header("channel", "va-vivo_lf")
            .header("platform", "android")
            .header("application-id", "com.duoduo.read")
            .header("app-version", "10001")
            .header("qm-params", qm)
            .header("no-permiss", "3")
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*");
        for (k, v) in params {
            req = req.query(&[(k.as_str(), v.as_str())]);
        }
        req = req.query(&[("sign", sign.as_str())]);
        let resp = req
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
        require_no_errors(&v, url)?;
        Ok(v)
    }
}

impl Default for ShortQimao {
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
//  纯函数层（离线可测：qm-params / sign / 解析）
// ═══════════════════════════════════════════════════════════════════════

/// 设备体（DEX `a()` 逐字 18 键；`session-id` 是毫秒时间戳）
pub fn device_json(millis: u128) -> Value {
    serde_json::json!({
        "static_score": "0.8",
        "uuid": "00000000-6f7c-e347-0000-000000000000",
        "device-id": "202504012213236fa2ed536aed584e0cc8a6a09fe2f2d4016cdc5bc74f2d5f",
        "mac": "",
        "sourceuid": "9494817a02a93435",
        "refresh-type": "0",
        "model": "M2012K10C",
        "wlb-imei": "",
        "AUTHORIZATION": AUTH,
        "brand": "Redmi",
        "oaid": "",
        "oaid-no-cache": "",
        "sys-ver": "11",
        "trusted-id": "",
        "phone-level": "H",
        "imei": "",
        "wlb-uid": "",
        "session-id": millis.to_string(),
    })
}

/// 自定义 base64 变体（DEX `a()` 里那段逐字符替换）
pub fn scramble(b64: &str) -> String {
    let mut out = String::with_capacity(b64.len());
    for c in b64.chars() {
        match c {
            '+' => out.push('P'),
            '/' => out.push('X'),
            '0'..='9' => {
                let i = (c as u8 - b'0') as usize;
                out.push(MAP_DIGIT.as_bytes()[i] as char);
            }
            'A'..='Z' => {
                let i = (c as u8 - b'A') as usize;
                out.push(MAP_UPPER.as_bytes()[i] as char);
            }
            'a'..='z' => {
                let i = (c as u8 - b'a') as usize;
                out.push(MAP_LOWER.as_bytes()[i] as char);
            }
            other => out.push(other),
        }
    }
    out
}

/// header `qm-params` 的值：紧凑 JSON → base64 → scramble
pub fn qm_params(millis: u128) -> String {
    let body = serde_json::to_string(&device_json(millis)).unwrap_or_default();
    scramble(&b64_encode(body.as_bytes()))
}

/// sign：**按 key 排序**后拼 `k=v`（无分隔符），末尾接密钥，再 md5
///
/// ★ 这是我从 DEX 读出的形状（TreeMap + `key` `'='` `value` + 常量密钥 + `J.e.a`=MD5）。
///   真站点**没认**（见文件头读数）—— 说明还缺一个服务端侧的密钥/时间窗。
pub fn sign_of(params: &[(String, String)]) -> String {
    let mut sorted: Vec<&(String, String)> = params.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));
    let mut s = String::new();
    for (k, v) in sorted {
        s.push_str(k);
        s.push('=');
        s.push_str(v);
    }
    s.push_str(SIGN_KEY);
    md5_hex(&s)
}

/// 业务错误封套：`errors` 存在 ⇒ Err（带 code/title/details）
///
/// 实测原文：`{"errors":{"id":"0","code":"44010120","level":"1","status":"200","title":"验签失败",…}}`
pub fn require_no_errors(v: &Value, url: &str) -> Result<(), String> {
    if let Some(e) = v.get("errors").filter(|e| e.is_object()) {
        let code = pick_str(e, &["code"]).unwrap_or("");
        let title = pick_str(e, &["title"]).unwrap_or("");
        let details = pick_str(e, &["details"]).unwrap_or("");
        return Err(format!(
            "七猫接口 {url} 返回业务错误 code={code} title={title} details={details}\
             （不是站点死：这是结构化验签失败，说明缺服务端密钥/时间窗）"
        ));
    }
    Ok(())
}

/// 分类：`data.tag_items[]` {tag_id, tag_name}
pub fn categories_of(v: &Value) -> Vec<CspCategory> {
    pick_arr(v, &["data", "tag_items"])
        .map(|a| {
            a.iter()
                .filter_map(|t| {
                    let id = pick_id_str(t, &["tag_id"])?;
                    let name = pick_str(t, &["tag_name"]).unwrap_or("").trim().to_string();
                    if name.is_empty() {
                        None
                    } else {
                        Some(CspCategory { id, name })
                    }
                })
                .collect()
        })
        .unwrap_or_default()
}

/// `data.list[]` → CspItem（DEX：playlet_id + 去标签的 title + image 五选一 + total_num/sub_title）
pub fn items_of(v: &Value) -> Vec<CspItem> {
    pick_arr(v, &["data", "list"])
        .map(|a| a.iter().filter_map(item_of).collect())
        .unwrap_or_default()
}

fn item_of(row: &Value) -> Option<CspItem> {
    let id = pick_id_str(row, &["playlet_id"]).or_else(|| pick_id_str(row, &["id"]))?;
    let title = strip_tags(pick_str(row, &["title"]).unwrap_or(""));
    if title.is_empty() {
        return None;
    }
    let cover = ["image_link", "image", "cover", "vertical_cover", "playlet_cover"]
        .iter()
        .filter_map(|k| pick_str(row, &[k]))
        .map(|s| s.trim().to_string())
        .find(|s| !s.is_empty());
    let sub = ["total_num", "sub_title"]
        .iter()
        .filter_map(|k| pick_str(row, &[k]))
        .map(|s| s.trim().to_string())
        .find(|s| !s.is_empty());
    Some(CspItem {
        id,
        title,
        cover,
        subtitle: sub,
    })
}

/// DEX `<clinit>` 的 `Pattern.compile("<[^>]+>")` 等价物（去 HTML 标签）
///
/// ★ 为什么不用 regex：本类只需要"去掉尖括号标签"，逐字符扫足够，且不引依赖。
pub fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut depth = 0usize;
    for c in s.chars() {
        match c {
            '<' => depth += 1,
            '>' if depth > 0 => depth -= 1,
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out.trim().to_string()
}

/// 详情：`data{title,image_link/intro,play_list[{sort,video_url}]}`
pub fn detail_of(v: &Value, id: &str) -> Result<CspDetail, String> {
    let d = v
        .get("data")
        .filter(|d| d.is_object())
        .ok_or_else(|| format!("详情没有 data（id={id}，可能改版/风控壳页）"))?;
    let title = strip_tags(pick_str(d, &["title"]).unwrap_or(""));
    if title.is_empty() {
        return Err(format!("详情 title 为空（id={id}）"));
    }
    let mut eps: Vec<CspEpisode> = Vec::new();
    for row in pick_arr(d, &["play_list"]).map(|a| a.as_slice()).unwrap_or(&[]) {
        let url = pick_str(row, &["video_url"]).unwrap_or("").trim().to_string();
        if url.is_empty() {
            continue;
        }
        let sort = pick_id_str(row, &["sort"]).unwrap_or_default();
        eps.push(CspEpisode {
            id: url,
            title: if sort.is_empty() {
                "正片".to_string()
            } else {
                format!("第{sort}集")
            },
            flag: "七猫".to_string(),
        });
    }
    if eps.is_empty() {
        return Err(format!("「{title}」没有可播剧集（play_list 为空）"));
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
        cover: ["image_link", "cover", "image"]
            .iter()
            .filter_map(|k| pick_str(d, &[k]))
            .map(|s| s.trim().to_string())
            .find(|s| !s.is_empty()),
        description: pick_str(d, &["intro"])
            .map(strip_tags)
            .filter(|s| !s.is_empty()),
        episodes: eps,
    })
}

// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for ShortQimao {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let url = format!("{BASE_STORE}{API_INDEX}");
        let v = self
            .get(
                &url,
                &[("tag_id".into(), "0".into()), ("next_id".into(), "0".into())],
            )
            .await?;
        let categories = categories_of(&v);
        if categories.is_empty() {
            return Err("七猫首页没有 data.tag_items（可能模板改版/风控壳页）".to_string());
        }
        Ok(CspHome {
            categories,
            items: items_of(&v),
        })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tag = tid.trim();
        if tag.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let page = page.max(1);
        // DEX：第一页 next_id=0，之后用上一页返回的 next_id（本仓没有跨页游标 ⇒ 按 page-1 近似）
        let next = if page <= 1 {
            "0".to_string()
        } else {
            (page - 1).to_string()
        };
        let url = format!("{BASE_STORE}{API_INDEX}");
        let v = self
            .get(
                &url,
                &[("tag_id".into(), tag.to_string()), ("next_id".into(), next)],
            )
            .await?;
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
                "分类 {tag} 第 1 页没解析出条目（可能模板改版/风控壳页）"
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
            return Err("playlet_id 为空".to_string());
        }
        let url = format!("{BASE_STORE}{API_INFO}");
        let v = self
            .get(&url, &[("playlet_id".into(), pid.to_string())])
            .await?;
        detail_of(&v, pid)
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let page = page.max(1);
        let url = format!("{BASE_STORE}{API_SEARCH}");
        let v = self
            .get(
                &url,
                &[
                    ("wd".into(), kw.to_string()),
                    ("page".into(), page.to_string()),
                    ("read_preference".into(), "0".into()),
                ],
            )
            .await?;
        let items = items_of(&v);
        if items.is_empty() {
            return Err(format!(
                "搜索「{kw}」没解析出条目（可能模板改版/风控壳页）"
            ));
        }
        Ok(CspList {
            items,
            page,
            page_count: Some(page + 1),
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        // ★ 未实测成功（验签挡住）⇒ 不声明 true（否则 registry 会把这个源拉进搜索，每次 Err）
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
            headers: vec![("User-Agent".to_string(), UA_HDR.to_string())],
            label: Some("七猫".to_string()),
        }])
    }
}

// ══ ⚠️ **没有 `register_site!`** ══
//
// 缺第 ③ 条：真网回 `44010120 验签失败`（结构化业务错误，端点活着）。

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── ① 真实响应片段（2026-10-27 实测原文）──

    const REAL_SIGN_FAIL: &str = r#"{"errors":{"id":"0","code":"44010120","level":"1","status":"200","title":"验签失败","popup_title":"","details":"验签失败"}}"#;

    #[test]
    fn real_sign_failure_is_an_error_with_code() {
        let v = parse_loose_json(REAL_SIGN_FAIL).expect("真实响应必须是合法 JSON");
        let e = require_no_errors(&v, API_INDEX).expect_err("★ 验签失败必须 Err");
        assert!(e.contains("44010120"), "{e}");
        assert!(e.contains("验签失败"), "{e}");
        assert!(e.contains("不是站点死"), "要写清这是业务错误而不是死站：{e}");
    }

    #[test]
    fn success_shaped_payload_parses() {
        // 成功形态**未实测**（验签挡住），按 DEX 字段构造
        let v = json!({"data":{
            "tag_items":[{"tag_id":1,"tag_name":"热播"},{"tag_id":2,"tag_name":"新剧"}],
            "list":[{"playlet_id":"9175494588921467958","title":"<b>剧一</b>","image_link":"https://p/1.jpg","total_num":"80"}]}});
        let cats = categories_of(&v);
        assert_eq!(cats.len(), 2);
        assert_eq!(cats[0].id, "1");
        assert_eq!(cats[0].name, "热播");
        let items = items_of(&v);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "9175494588921467958");
        assert_eq!(items[0].title, "剧一", "★ 标题里的 HTML 标签必须去掉");
        assert_eq!(items[0].subtitle.as_deref(), Some("80"));
    }

    #[test]
    fn detail_parses_play_list_and_sorts() {
        let v = json!({"data":{"title":"剧一","intro":"<p>简介</p>",
            "play_list":[{"sort":"2","video_url":"https://c/2.mp4"},{"sort":"1","video_url":"https://c/1.mp4"}]}});
        let d = detail_of(&v, "p1").expect("真实结构必须能解析");
        assert_eq!(d.description.as_deref(), Some("简介"));
        assert_eq!(d.episodes.len(), 2);
        assert_eq!(d.episodes[0].title, "第1集", "★ 必须按 sort 排好");
        assert_eq!(d.episodes[0].id, "https://c/1.mp4");
    }

    #[test]
    fn empty_or_broken_detail_is_error() {
        assert!(detail_of(&json!({}), "1").unwrap_err().contains("data"));
        let e = detail_of(&json!({"data":{"title":"空"}}), "1").unwrap_err();
        assert!(e.contains("play_list"), "{e}");
    }

    // ── ② qm-params / sign 的形态（"验签"的核心，逐字钉住）──

    #[test]
    fn scramble_replaces_per_the_dex_alphabets() {
        // ★ 断言里写**字面量**，不写常量名 —— 改前错在哪：用 `assert_eq!(scramble("0123456789"), MAP_DIGIT)`
        //   时，把 MAP_DIGIT 改一个字符，左式和右式**一起变** ⇒ 注入不红（判据自己喂饱自己）。
        //   这是"判据不能引用被测对象"那一型，本批实测撞到，已改成字面量。
        assert_eq!(scramble("+/"), "PX");
        assert_eq!(scramble("0123456789"), "MUlErYWbdJ");
        assert_eq!(scramble("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), "9saI0oy_HGitgNA8Fk3hfRqC4p");
        assert_eq!(scramble("abcdefghijklmnopqrstuvwxyz"), "mBOuc6Kx5T-2zSZ1VvjQ7DwnLe");
        assert_eq!(scramble("=="), "==", "填充符不动");
        // 三张表必须**恰好** 10/26/26 个字符，否则按下标取值会 panic 或错位
        assert_eq!(MAP_DIGIT.chars().count(), 10);
        assert_eq!(MAP_UPPER.chars().count(), 26);
        assert_eq!(MAP_LOWER.chars().count(), 26);
        // 且内容**逐字**等于 DEX（长度对了内容也可能错）
        assert_eq!(MAP_DIGIT, "MUlErYWbdJ");
        assert_eq!(MAP_UPPER, "9saI0oy_HGitgNA8Fk3hfRqC4p");
        assert_eq!(MAP_LOWER, "mBOuc6Kx5T-2zSZ1VvjQ7DwnLe");
    }

    #[test]
    fn qm_params_is_scrambled_base64_of_the_device_json() {
        let qm = qm_params(1793116874758);
        // 逆变换不存在，但可以确认：没有 '+' '/'，且长度与 base64 一致（含 '=' 填充）
        assert!(!qm.contains('+') && !qm.contains('/'), "{qm}");
        assert!(qm.ends_with('='), "base64 带填充：{qm}");
        let raw = serde_json::to_string(&device_json(1793116874758)).unwrap();
        assert_eq!(qm.len(), b64_encode(raw.as_bytes()).len());
    }

    #[test]
    fn device_json_has_session_id_as_millis() {
        let j = device_json(1793116874758);
        assert_eq!(j["session-id"], json!("1793116874758"));
        assert_eq!(j["AUTHORIZATION"], json!(AUTH));
        // 设备号是 DEX 里的**逐字**常量（62 位 hex/数字混合，不是标准 UUID）——按字面钉死，
        // 免得"看起来合理"的改写（比如顺手改成 64 位）悄悄改变 qm-params
        assert_eq!(
            j["device-id"],
            json!("202504012213236fa2ed536aed584e0cc8a6a09fe2f2d4016cdc5bc74f2d5f")
        );
        assert_eq!(j["uuid"], json!("00000000-6f7c-e347-0000-000000000000"));
    }

    #[test]
    fn sign_is_md5_over_sorted_pairs_plus_key() {
        let p = vec![
            ("tag_id".to_string(), "1".to_string()),
            ("next_id".to_string(), "0".to_string()),
        ];
        let s = sign_of(&p);
        assert_eq!(s, md5_hex(&format!("next_id=0tag_id=1{SIGN_KEY}")));
        // 顺序无关（TreeMap 语义）
        let mut rev = p.clone();
        rev.reverse();
        assert_eq!(sign_of(&rev), s);
        // 值变 ⇒ 签名变
        let mut other = p.clone();
        other[0].1 = "2".to_string();
        assert_ne!(sign_of(&other), s);
    }

    #[test]
    fn strip_tags_matches_the_dex_pattern() {
        assert_eq!(strip_tags("<b>剧一</b>"), "剧一");
        assert_eq!(strip_tags("  <p>a</p><i>b</i> "), "ab");
        assert_eq!(strip_tags("no tags"), "no tags");
    }

    #[test]
    fn split_hosts_are_different_by_design() {
        // 实测：读侧没有 index 路径（404）⇒ 这两个 base 不能互换
        assert_ne!(BASE_STORE, BASE_READ);
        assert!(DOMAIN_TABLE.contains("neptune.qmplaylet.com"));
    }

    // ── ③ **不注册** + 契约形态 ──

    #[test]
    fn must_not_register_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("short_qimao.rs"));
        assert!(!flat.contains("register_site!(ShortQimao)"), "★ 验签挡住 ⇒ 不注册");
        assert!(!crate::csp::is_implemented("csp_ShortQimao"), "★ 不许进注册表");
    }

    #[test]
    fn class_name_is_exact() {
        assert_eq!(ShortQimao::CLASS, "ShortQimao");
    }

    #[test]
    fn client_builder_turns_off_proxy() {
        let src = crate::csp::shared::impl_src_only(include_str!("short_qimao.rs"));
        let t = src.find(".timeout(TIMEOUT)").expect("必须有 timeout");
        let n = src.find(".no_proxy()").expect("★ 必须有 .no_proxy()");
        let b = src.find(".build()").expect("必须有 build");
        assert!(t < n && n < b, "★ .no_proxy() 必须在 timeout 之后、build 之前");
    }

    #[test]
    fn search_is_declared_unsupported_because_never_verified() {
        assert!(!ShortQimao::new().supports_search());
    }

    #[tokio::test]
    async fn empty_inputs_are_rejected_before_network() {
        let s = ShortQimao::new();
        assert!(s.detail(" ", "").await.is_err());
        assert!(s.search("  ", 1, "").await.is_err());
        assert!(s.play("", "not-a-url", "").await.is_err());
        assert!(s.list("", 1, "").await.is_err());
    }
}
