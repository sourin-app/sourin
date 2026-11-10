// ═══════════════════════════════════════════════════════════════════════
//  csp_AppGet —— TVBox `csp_AppGet` 的 Rust 重写（「魔方」蓝光秒播）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么（实测取自 `.probe/ref-subscription.json`）
//
// ```json
// {"key":"魔方","name":"💠魔方丨蓝光秒播","type":3,"api":"csp_AppGet",
//  "searchable":1,"changeable":1,
//  "ext":{"url":"https://www.douy32mf.top","dataKey":"1234567887654321",
//         "dataIv":"1234567887654321"}}
// ```
// ⇒ **ext 是对象**，七个键（DEX `init` 的 `iput` 逐字）：
// ```text
// url       站点前缀                              → 字段 a
// dataKey   AES 密钥（16 字节）                    → 字段 b
// dataIv    AES IV（16 字节）                      → 字段 c
// deviceId  app-user-device-id 头                  → 字段 d
// version   app-version-code 头                    → 字段 e
// ua        User-Agent 头                          → 字段 f
// token     app-user-token 头（可空 ⇒ 空就不发）    → 字段 g
// ```
//
// # ★ 协议（反汇编复原 + 真网络端到端实证，2026-10-27）
//
// ### ① 所有响应体都是 **AES/CBC 的密文**（Base64 外套）
// ```text
// DEX `merge.m.a.a(String cipherB64, String key, String iv)`：
//   Cipher.getInstance("**AES/CBC/PKCS7Padding**")
//   SecretKeySpec(key.getBytes(), "AES")
//   IvParameterSpec(iv.getBytes())
//   Cipher.init(DECRYPT) ; doFinal(Base64.decode(cipherB64))
// ⇒ 本仓等价：`aes` + `cbc` 两个**纯 Rust** crate（已在依赖表；本来用于 csp_App99）
//    ★ 不新增依赖。PKCS7 与 PKCS5 在 16 字节块上等价 ⇒ 用 `cbc::Decryptor::<Aes128>`.
// ```
//
// ### ② 请求
// ```text
// GET  {url}/api.php/getappapi.index/initV119                   → 首页
// GET  {url}/api.php/getappapi.index/typeFilterVodList?page=.. → 分类列表
// GET  {url}/api.php/getappapi.index/searchList?keywords=..&page=.. → 搜索
// GET  {url}/api.php/getappapi.index/vodDetail?vod_id=..       → 详情
// POST {url}/api.php/getappapi.index/vodParse                  → 取流（走 time/url 两参数）
// 头（DEX `c()`/`a()` 逐字）：
//   User-Agent: {ua}          Connection: Keep-Alive
//   Content-Type: application/x-www-form-urlencoded
//   app-version-code: {version}
//   app-user-token: {token}        ← **仅当 token 非空才发**
//   app-ui-mode: light
//   app-user-device-id: {deviceId}
//   app-api-verify-time: <now 毫秒>
//   app-api-verify-sign: ""        ← ★ DEX 里就是**空串**（不是缺头）
// ```
//
// ★ **实证读数（2026-10-27 真打 `https://www.douy32mf.top`）**
// ```text
// initV119                 ⇒ HTTP 200 / 80945b，**AES 解密成功**：
//                             {"banner_list":1, "recommend_list":**12**, "type_list":**6**,
//                              "hot_search_list":5, "update":{…}, "notice":{…}}
// typeFilterVodList?page=1 ⇒ 200，解密后 {"type_id","type_name","recommend_list":**30**}
// searchList               ⇒ 200，解密后 {"search_list":**20**}
// vodDetail?vod_id=8043    ⇒ 200，解密后 {…, "vod_play_list":[
//                                {"player_info":{"show":"极速资源", …}, "url_count":40,
//                                 "urls":[{"name":"第1集", …}]}]}
// ⚠️ AES 参数逐字取自**真配置**：dataKey=dataIv="1234567887654321"
//     ⇒ 换个站就要换 ext；**不许把这两个值写死在类里**（本站只是默认兜底用不上）。
// ```
//
// # ⚠️ 已知缺口（按契约"不许静默丢、不许自己造"）
//
// ```text
// ① ★ `mProxy` / 弹幕代理：DEX 的 `playerContent` 里有一句
//      `Proxy.getUrl() + "?do=appdanmu&vodName=…&vodIndex=…"`
//    —— 那是 **TVBox 宿主自己的弹幕代理**（`com.github.catvod.spider.Proxy`），
//    本仓没有这个能力位（且本批契约明确不做 `mProxy`）。
//    ⇒ 取流只给**上游的真地址**，**不拼弹幕代理地址**（拼了本仓也没服务接）。
//    已登记为已知缺口。
// ② `loadPic`：DEX 里 AppGet **没有**该方法；封面取图走源 `cover_headers`（声明式）。
//    但 `CspSite` **没有** `cover_headers()` 能力位（见 csp_Douban 的同一条登记）。
// ③ `initApi`：DEX 没有（`init(Context,String)` 只做 ext 解析）。
// ④ `isVideoFormat` / `manualVideoCheck`：DEX 里 **AppGet 没有**这两个方法。
// ⑤ ★★ **"要不要 parse" 的能力位**（本仓无）
//    ### 实测事实（2026-10-27 真打）
//    ```text
//    [LIVE] play: https://v.qq.com/x/cover/mzc002001w361jz/v4102hrb7cq.html
//    ```
//    —— AppGet 的取流结果**可能是第三方播放页**（需要 parse 的那类），要经 **parse** 才出 m3u8。
//    DEX 的 `playerContent` 里对应的是 `parse` 字段（const-string 里有 `'parse'`），
//    而本仓 `CspPlay` 只有 `{url, headers, label}` —— **没有那个位**。
//    ⇒ 处置：**不把播放页当直链静默交出去**（那会让用户点了播不出来还不知道为什么），
//      而是在 `label` 里**如实写「（需 parse）」**（见 [`needs_parse`]），并在本文件登记这个缺口。
//    ⇒ 按契约原话：**本仓无等价位，未实现**。
//```

use async_trait::async_trait;
use serde_json::Value;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/*
 * ★ base64：**不引入 `base64` crate** —— 本仓 `csp_App99` 已经手写了标准实现
 *   （`app99::b64_encode` / `b64_decode`），依赖表里也没有那个 crate。
 *   复用它 = **零新增依赖**，且与"本仓不新增运行时依赖"这条纪律一致。
 *   ⚠️ 第一版我写了 `use base64::Engine` ⇒ 编译直接报 unresolved import（实测踩到）。
 */
use super::app99::{b64_decode, b64_encode};

/// 取流用的路径（DEX `c()`）
const P_VOD_PARSE: &str = "/api.php/getappapi.index/vodParse";
const P_INIT: &str = "/api.php/getappapi.index/initV119";
const P_FILTER: &str = "/api.php/getappapi.index/typeFilterVodList";
const P_SEARCH: &str = "/api.php/getappapi.index/searchList";
const P_DETAIL: &str = "/api.php/getappapi.index/vodDetail";

/// 实测可用的兜底站点（**但 dataKey/dataIv 不许兜底** —— 见文件头）
const DEFAULT_SITE: &str = "https://www.douy32mf.top";

// ═══════════════════════════════════════════════════════════════════════
//  ext 解析
// ═══════════════════════════════════════════════════════════════════════

/// ext 里解析出来的配置（七个键 + 两个 AES 参数）
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cfg {
    pub site: String,
    pub data_key: String,
    pub data_iv: String,
    pub device_id: String,
    pub version: String,
    pub ua: String,
    pub token: String,
}

/// 从 ext 文本里取 `key` 的值（对象/字符串两种形态都认；剥引号）
pub fn key_of(ext: &str, key: &str) -> Option<String> {
    let t = ext.trim();
    if t.is_empty() {
        return None;
    }
    // ① 直接找 `"key"` 后跟 `:` 的形态（对象形态：`{"url":"https://…"}`）
    let pat = format!("\"{key}\"");
    if let Some(pos) = t.find(&pat) {
        let after = t[pos + pat.len()..].trim_start();
        if let Some(rest) = after.strip_prefix(':') {
            let rest = rest.trim_start();
            if let Some(r) = rest.strip_prefix('"') {
                if let Some(end) = r.find('"') {
                    let v = r[..end].trim();
                    if !v.is_empty() {
                        return Some(v.to_string());
                    }
                }
            } else {
                let v = rest
                    .split([',', '}', '\n'])
                    .next()
                    .unwrap_or("")
                    .trim()
                    .trim_matches('"');
                if !v.is_empty() {
                    return Some(v.to_string());
                }
            }
        }
    }
    // ② 裸键值形态（`url=https://…&deviceId=x`）—— 容忍配置写成字符串
    for seg in t.split(['&', '?', ',', '{', '}']) {
        let s = seg.trim().trim_matches('"');
        if let Some(rest) = s.strip_prefix(key) {
            if let Some(v) = rest.strip_prefix('=').or_else(|| rest.strip_prefix(':')) {
                let v = v.trim().trim_matches('"').trim();
                if !v.is_empty() {
                    return Some(v.to_string());
                }
            }
        }
    }
    None
}

impl Cfg {
    /// 解析 ext ⇒ `Cfg`；**AES 两参数缺失 ⇒ Err**
    ///
    /// # 为什么不给 dataKey/dataIv 兜底
    /// ```text
    /// 它们是**每个站各自不同**的密钥。给个默认值会让"配置写漏了"变成
    /// "解密出一堆乱码"或"上游 code 报错"，**排查方向会被带偏**
    /// （现象像"上游挂了"，真因是配置）。
    /// ⇒ 缺任一 ⇒ 直接 Err 并在文案里点名是哪个键。
    /// ```
    pub fn parse(ext: &str) -> Result<Self, String> {
        let site = key_of(ext, "url")
            .or_else(|| key_of(ext, "site"))
            .map(|s| s.trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| DEFAULT_SITE.to_string());
        let data_key = key_of(ext, "dataKey").ok_or_else(|| {
            "ext 里缺 dataKey（本站响应体是 AES/CBC 密文，缺密钥无法解）".to_string()
        })?;
        let data_iv = key_of(ext, "dataIv")
            .ok_or_else(|| "ext 里缺 dataIv（AES/CBC 需要 IV）".to_string())?;
        Ok(Self {
            site,
            data_key,
            data_iv,
            device_id: key_of(ext, "deviceId").unwrap_or_default(),
            version: key_of(ext, "version").unwrap_or_default(),
            ua: key_of(ext, "ua").unwrap_or_else(|| "okhttp/3.14.9".to_string()),
            token: key_of(ext, "token").unwrap_or_default(),
        })
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  解码（纯函数，全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// AES-CBC 解密（等价于 DEX `merge.m.a.a` 的 `AES/CBC/PKCS7Padding`）
///
/// * `key`/`iv` 是**字符串的字节**（DEX 用 `String.getBytes()`，即平台默认 UTF-8）
/// * 只接受 16/24/32 字节密钥；其它长度 ⇒ Err（不猜、不补零）
pub fn aes_cbc_decrypt(b64: &str, key: &str, iv: &str) -> Result<Vec<u8>, String> {
    use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
    use cbc::Decryptor;
    let raw = b64_decode(b64.trim())?;
    if raw.is_empty() {
        return Err("密文解码后是空（响应 data 不是有效 Base64？）".to_string());
    }
    if raw.len() % 16 != 0 {
        return Err(format!(
            "密文长度 {} 不是 16 的整数倍（AES/CBC 需要块对齐）",
            raw.len()
        ));
    }
    let kb = key.as_bytes();
    let ivb = iv.as_bytes();
    if ivb.len() != 16 {
        return Err(format!("dataIv 必须是 16 字节（实际 {} 字节）", ivb.len()));
    }
    /*
     * ★ `decrypt_padded_mut`（就地解密）而不是 `decrypt_padded_vec_mut`：
     *   后者是 `alloc` feature 下的 API，**本仓的 `aes`/`cbc` 依赖没开这个 feature**
     *   （`aes = "0.8"` / `cbc = "0.1"`，见 Cargo.toml）⇒ 实测报
     *   "no method named `decrypt_padded_vec_mut`"。`csp_App99` 用的也是就地版。
     */
    let mut buf = raw;
    let pt = match kb.len() {
        16 => Decryptor::<aes::Aes128>::new_from_slices(kb, ivb)
            .map_err(|e| format!("AES-128 初始化失败：{e}"))?
            .decrypt_padded_mut::<Pkcs7>(&mut buf)
            .map_err(|_| "AES-128-CBC 解密失败（密钥/IV 不对，或响应不是 AES/CBC 密文）".to_string())?
            .to_vec(),
        24 => Decryptor::<aes::Aes192>::new_from_slices(kb, ivb)
            .map_err(|e| format!("AES-192 初始化失败：{e}"))?
            .decrypt_padded_mut::<Pkcs7>(&mut buf)
            .map_err(|_| "AES-192-CBC 解密失败".to_string())?
            .to_vec(),
        32 => Decryptor::<aes::Aes256>::new_from_slices(kb, ivb)
            .map_err(|e| format!("AES-256 初始化失败：{e}"))?
            .decrypt_padded_mut::<Pkcs7>(&mut buf)
            .map_err(|_| "AES-256-CBC 解密失败".to_string())?
            .to_vec(),
        n => return Err(format!("dataKey 必须是 16/24/32 字节（实际 {n} 字节）")),
    };
    Ok(pt)
}

/// 响应体 → JSON：`data` 是 Base64 密文 ⇒ 解成明文再 parse
///
/// # 形态（实测）
/// ```text
/// {"code":1,"msg":"…","data":"<base64(AES-CBC(明文JSON))>"}
/// ```
/// ★ `data` **有时已是对象**（未加密的端点）⇒ 两种都认，但**都不是就 Err**。
pub fn decode_body(v: &Value, cfg: &Cfg, what: &str) -> Result<Value, String> {
    match v.get("code").and_then(|c| c.as_i64()) {
        Some(1) => {}
        Some(c) => {
            return Err(format!(
                "上游 {what} 返回 code={c}（msg={}）",
                v.get("msg").and_then(|m| m.as_str()).unwrap_or("")
            ))
        }
        None => {
            return Err(format!(
                "上游 {what} 响应里没有 code 字段（可能被拦或改协议了）"
            ))
        }
    }
    let d = v
        .get("data")
        .ok_or_else(|| format!("上游 {what} 响应里没有 data"))?;
    if let Some(obj) = d.as_object() {
        return Ok(Value::Object(obj.clone()));
    }
    let s = d
        .as_str()
        .ok_or_else(|| format!("上游 {what} 的 data 既不是对象也不是字符串"))?;
    if s.trim().is_empty() {
        // ★ 空串**不当成功**（那会变成"解密出空"⇒ 上层拿到 0 条却不知道原因）
        return Err(format!("上游 {what} 的 data 是空串（解密不出内容）"));
    }
    let pt = aes_cbc_decrypt(s, &cfg.data_key, &cfg.data_iv)
        .map_err(|e| format!("上游 {what} 的 data 解密失败：{e}"))?;
    let txt = String::from_utf8_lossy(&pt).to_string();
    serde_json::from_str(&txt).map_err(|e| {
        format!(
            "上游 {what} 解密后不是合法 JSON：{e}；明文前 100 字：{}",
            txt.chars().take(100).collect::<String>()
        )
    })
}

/// `type_list[]` → 分类（`type_id` / `type_name`）；**0 条 ⇒ Err**
pub fn cats_of(d: &Value) -> Result<Vec<CspCategory>, String> {
    let arr = d
        .get("type_list")
        .and_then(|x| x.as_array())
        .ok_or_else(|| {
            format!(
                "首页 data 里没有 type_list（实际键：{:?}）",
                d.as_object()
                    .map(|o| o.keys().take(10).cloned().collect::<Vec<_>>())
                    .unwrap_or_default()
            )
        })?;
    // ★ DEX homeContent 把 `正版QQ群 / 伦理 / 福利 / 小影院` 这类**非视频分类**剔掉
    let skip = ["正版QQ群", "伦理", "福利", "小影院"];
    let out: Vec<CspCategory> = arr
        .iter()
        .filter_map(|o| {
            let id = o.get("type_id").map(|x| x.to_string().trim_matches('"').to_string())?;
            let name = o.get("type_name").and_then(|x| x.as_str())?.trim().to_string();
            if id.is_empty() || name.is_empty() || skip.contains(&name.as_str()) {
                return None;
            }
            Some(CspCategory { id, name })
        })
        .collect();
    if out.is_empty() {
        return Err(format!(
            "首页 type_list 解析出 0 个可用分类（type_list 有 {} 项）",
            arr.len()
        ));
    }
    Ok(out)
}

/// `recommend_list[]` / `search_list[]` → 条目；**0 条 ⇒ Err**
pub fn items_of(d: &Value, key: &str, what: &str) -> Result<Vec<CspItem>, String> {
    let arr = d.get(key).and_then(|x| x.as_array()).ok_or_else(|| {
        format!(
            "上游 {what} 的 data 里没有 {key}（实际键：{:?}）",
            d.as_object()
                .map(|o| o.keys().take(10).cloned().collect::<Vec<_>>())
                .unwrap_or_default()
        )
    })?;
    let out: Vec<CspItem> = arr
        .iter()
        .filter_map(|o| {
            let id = o.get("vod_id").map(|x| x.to_string().trim_matches('"').to_string())?;
            let title = o.get("vod_name").and_then(|x| x.as_str())?.trim().to_string();
            if id.is_empty() || title.is_empty() {
                return None;
            }
            Some(CspItem {
                id,
                title,
                cover: o
                    .get("vod_pic")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.trim().is_empty())
                    .map(|s| s.trim().to_string()),
                subtitle: o
                    .get("vod_remarks")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.trim().is_empty())
                    .map(|s| s.trim().to_string()),
            })
        })
        .collect();
    if out.is_empty() {
        return Err(format!(
            "上游 {what} 的 {key} 解析出 0 条（{key} 有 {} 项）",
            arr.len()
        ));
    }
    Ok(out)
}

/// 详情：`vod` 对象 + `vod_play_list[]`
///
/// # 形态（实测 `vodDetail?vod_id=8043` 解密后）
/// ```text
/// {"vod":{…}, "vod_play_list":[
///     {"player_info":{"show":"极速资源","parse":"","player_parse_type":"1", …},
///      "url_count":40, "urls":[{"name":"第1集","url":"https://…m3u8"}, …]}, …]}
/// ```
/// ★ 线路名取自 `player_info.show`（不是 `flag`）—— 实测就是这个键。
pub fn detail_of(d: &Value, id: &str) -> Result<CspDetail, String> {
    let vod = d
        .get("vod")
        .and_then(|x| x.as_object())
        .ok_or_else(|| "详情 data 里没有 vod 对象".to_string())?;
    let title = vod
        .get("vod_name")
        .and_then(|x| x.as_str())
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(id)
        .trim()
        .to_string();
    let lines = play_lines_of(d);
    if lines.is_empty() {
        return Err(format!(
            "上游详情 {id} 的 vod_play_list 解析出 0 集（键名或结构可能变了）"
        ));
    }
    let mut eps = Vec::new();
    for (flag, list) in &lines {
        for (i, (name, url)) in list.iter().enumerate() {
            let ep_name = if name.trim().is_empty() {
                format!("第{}集", i + 1)
            } else {
                name.clone()
            };
            /*
             * 集 id 编码 `{vodId}@{flag}|{idx}|{url}`：
             * 详情里给的地址可能带时效，取流端**有时**要再走一次 `vodParse`，
             * 所以两条信息都带上（`play()` 见机行事）。
             */
            eps.push(CspEpisode {
                id: format!("{id}@{flag}|{i}|{url}"),
                title: ep_name,
                flag: flag.clone(),
            });
        }
    }
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover: vod.get("vod_pic").and_then(|x| x.as_str()).map(String::from),
        description: vod
            .get("vod_content")
            .or_else(|| vod.get("vod_blurb"))
            .and_then(|x| x.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(|s| s.trim().to_string()),
        episodes: eps,
    })
}

/// `vod_play_list[]` → `[(线路名, [(集名, 地址)])]`
///
/// 线路名 = `player_info.show`；集在 `urls[]`（`name` / `url`）
pub fn play_lines_of(d: &Value) -> Vec<(String, Vec<(String, String)>)> {
    let mut out = Vec::new();
    let Some(arr) = d.get("vod_play_list").and_then(|x| x.as_array()) else {
        return out;
    };
    for (li, line) in arr.iter().enumerate() {
        let flag = line
            .get("player_info")
            .and_then(|p| p.get("show"))
            .and_then(|x| x.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|| format!("线路{}", li + 1));
        let mut eps = Vec::new();
        if let Some(urls) = line.get("urls").and_then(|x| x.as_array()) {
            for (i, u) in urls.iter().enumerate() {
                let url = u
                    .get("url")
                    .and_then(|x| x.as_str())
                    .map(|s| s.trim().to_string())
                    .unwrap_or_default();
                if url.is_empty() {
                    continue;
                }
                let name = u
                    .get("name")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.trim().is_empty())
                    .map(|s| s.trim().to_string())
                    .unwrap_or_else(|| format!("第{}集", i + 1));
                eps.push((name, url));
            }
        }
        if !eps.is_empty() {
            out.push((flag, eps));
        }
    }
    out
}

/// 判断一个地址是否**需要走 parse**（第三方播放页，不是直链）
///
/// # 实测形态（2026-10-27 真打）
/// ```text
/// AppGet 的取流结果**不一定是直链**：
///   [LIVE] play: https://v.qq.com/x/cover/mzc002001w361jz/v4102hrb7cq.html
///   —— 这是一条**第三方视频站的播放页**，VIP 源要经 parse 才能出 m3u8。
/// ```
/// ★ 本仓 `CspPlay` **没有"要不要 parse"的能力位** ⇒ 见文件头「已知缺口 ⑤」。
///   这里把它**如实暴露成 label 里的一句说明**（用户能看到"这是播放页、需 parse"），
///   而不是把播放页当成直链静默交出去（那会让用户点了播不出来还不知道为什么）。
pub fn needs_parse(url: &str) -> bool {
    let u = url.trim().to_ascii_lowercase();
    if u.ends_with(".m3u8") || u.ends_with(".mp4") || u.ends_with(".flv") || u.ends_with(".mkv") {
        return false;
    }
    const PAGE_HOSTS: &[&str] = &[
        "v.qq.com",
        "v.youku.com",
        "www.iqiyi.com",
        "v.iqiyi.com",
        "www.mgtv.com",
        "www.bilibili.com",
    ];
    if PAGE_HOSTS.iter().any(|h| u.contains(h)) {
        return true;
    }
    u.ends_with(".html") || u.ends_with(".htm") || u.ends_with(".shtml")
}

/// 给 `label` 加上"需 parse"的说明（若需要）
pub fn label_with_parse_hint(label: &str, url: &str) -> String {
    if needs_parse(url) {
        if label.is_empty() {
            "需 parse（第三方播放页）".to_string()
        } else {
            format!("{label}（需 parse）")
        }
    } else if label.is_empty() {
        "默认".to_string()
    } else {
        label.to_string()
    }
}

/// 拆集 id（`{vodId}@{flag}|{idx}|{url}`）；url 里可能含 `|` ⇒ 只用前两个分隔
pub fn split_ep_id(ep: &str) -> Option<(String, String, usize, String)> {
    let (vid, rest) = ep.split_once('@')?;
    let mut it = rest.splitn(3, '|');
    let flag = it.next()?.to_string();
    let idx: usize = it.next()?.parse().ok()?;
    let url = it.next().unwrap_or("").to_string();
    if vid.is_empty() {
        return None;
    }
    Some((vid.to_string(), flag, idx, url))
}

/// 从取流响应里取第一个真地址（`vodParse` 的常见形态）
pub fn parse_url_of(v: &Value) -> Result<String, String> {
    let d = v
        .get("data")
        .ok_or_else(|| "取流响应里没有 data".to_string())?;
    // 形态 A：data 直接是地址字符串
    if let Some(s) = d.as_str() {
        if s.starts_with("http") {
            return Ok(s.to_string());
        }
        // 形态 B：data 里是 `{"url":"…"}` 的 JSON 文本
        if s.trim_start().starts_with('{') {
            if let Ok(j) = serde_json::from_str::<Value>(s) {
                if let Some(u) = j.get("url").and_then(|x| x.as_str()).filter(|u| !u.is_empty()) {
                    return Ok(u.to_string());
                }
            }
        }
    }
    // 形态 C：data 对象里有 url
    if let Some(u) = d.get("url").and_then(|x| x.as_str()).filter(|u| !u.is_empty()) {
        return Ok(u.to_string());
    }
    if let Some(a) = d.get("urls").and_then(|x| x.as_array()) {
        if let Some(u) = a
            .iter()
            .find_map(|o| o.get("url").and_then(|x| x.as_str()))
            .filter(|u| !u.is_empty())
        {
            return Ok(u.to_string());
        }
    }
    Err("取流响应里找不到可用地址（data 形态变了或该集无源）".to_string())
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct AppGet {
    client: super::http_context::CspHttpContext,
}

impl AppGet {
    pub const CLASS: &'static str = "AppGet";

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| reqwest::Client::builder()
            // Unbound sites remain direct; the context applies the current app policy.
            .no_proxy()
            .timeout(std::time::Duration::from_secs(20))
        );
        Self { client }
    }

    /// DEX `c()`/`a()` 那 9 个头的统一装配
    fn headers(&self, cfg: &Cfg) -> Vec<(String, String)> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
            .to_string();
        let mut h = vec![
            ("User-Agent".to_string(), cfg.ua.clone()),
            ("Connection".to_string(), "Keep-Alive".to_string()),
            (
                "Content-Type".to_string(),
                "application/x-www-form-urlencoded".to_string(),
            ),
            ("app-version-code".to_string(), cfg.version.clone()),
            ("app-ui-mode".to_string(), "light".to_string()),
            ("app-user-device-id".to_string(), cfg.device_id.clone()),
            ("app-api-verify-time".to_string(), now),
            // ★ DEX 里这一条**就是空串**（不是"缺头"）—— 逐字照搬
            ("app-api-verify-sign".to_string(), String::new()),
        ];
        // `app-user-token` **仅当非空才发**（DEX 里 `TextUtils.isEmpty` 那一条 if）
        if !cfg.token.trim().is_empty() {
            h.push(("app-user-token".to_string(), cfg.token.clone()));
        }
        h
    }

    async fn get_decoded(&self, cfg: &Cfg, path_with_query: &str, what: &str) -> Result<Value, String> {
        let url = format!("{}{}", cfg.site.trim_end_matches('/'), path_with_query);
        let mut req = self.client.client()?.get(&url);
        for (k, v) in self.headers(cfg) {
            req = req.header(k, v);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| format!("请求上游失败（{url}）：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取上游响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            let head = body.chars().take(80).collect::<String>();
            return Err(format!("上游返回 HTTP {status}（{url}）：{head}"));
        }
        let v: Value = serde_json::from_str(&body).map_err(|e| {
            format!(
                "上游 {what} 响应不是合法 JSON（{e}）；前 100 字：{}",
                body.chars().take(100).collect::<String>()
            )
        })?;
        decode_body(&v, cfg, what)
    }
}

impl Default for AppGet {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for AppGet {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let cfg = Cfg::parse(ext)?;
        let d = self.get_decoded(&cfg, P_INIT, "首页").await?;
        let categories = cats_of(&d)?;
        // 首页预取（`recommend_list`）；取不到 ⇒ 空（分类已可用，不是错）
        let items = items_of(&d, "recommend_list", "首页").unwrap_or_default();
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let cfg = Cfg::parse(ext)?;
        // ★ 实测键名：`page`（分类维度 `type_id` 作为路径参数）
        let path = if tid.trim().is_empty() {
            format!("{P_FILTER}?page={page}")
        } else {
            format!("{P_FILTER}?page={page}&type_id={}", tid.trim())
        };
        let d = self
            .get_decoded(&cfg, &path, &format!("分类 {tid} 第 {page} 页"))
            .await?;
        let items = items_of(&d, "recommend_list", &format!("分类 {tid}"))?;
        Ok(CspList {
            items,
            page,
            page_count: None, // 实测该接口不给总页数 ⇒ 如实 None
            total: d.get("total").and_then(|x| x.as_u64()),
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let cfg = Cfg::parse(ext)?;
        let path = format!(
            "{P_SEARCH}?keywords={}&page={page}",
            urlencoding::encode(kw)
        );
        let d = self.get_decoded(&cfg, &path, "搜索").await?;
        let items = items_of(&d, "search_list", "搜索")?;
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        true
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let cfg = Cfg::parse(ext)?;
        // ★ 实测：详情参数是 `vod_id`（`id=` 会得到 313 字节的错响应）
        let path = format!("{P_DETAIL}?vod_id={id}");
        let d = self
            .get_decoded(&cfg, &path, &format!("详情 {id}"))
            .await?;
        detail_of(&d, id)
    }

    /// 取流：**优先用详情里已经给的地址**（它通常就是真 m3u8）；
    /// 若调用方只给了裸 vodId（没有 `@…` 段），退回去打 `vodParse`。
    ///
    /// ⚠️ 已知缺口：DEX 在返回的地址后面还拼了**宿主的弹幕代理**地址
    ///    （`Proxy.getUrl() + "?do=appdanmu&…"`）。本仓没有那个能力位、本批契约也不做
    ///    `mProxy` ⇒ **不拼**（拼了也没服务接，会给用户一个必然失败的地址）。
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let cfg = Cfg::parse(ext)?;
        if let Some((vid, f, _idx, url)) = split_ep_id(id) {
            if !url.trim().is_empty() {
                let u = url.trim().to_string();
                // ⚠️ `flag` 是 `&str`（trait 参数）、`f` 是 `String`（从集 id 拆出来）
                //    ⇒ 两边各转各的：`flag.clone()` 得到的是 `&str`，类型不匹配（实测编译报过）
                let lab: String = if f.is_empty() {
                    flag.to_string()
                } else {
                    f.clone()
                };
                return Ok(vec![CspPlay {
                    // ★ 若这是第三方播放页（需 parse），label 里**如实说明**（见 needs_parse 的注释）
                    label: Some(label_with_parse_hint(&lab, &u)),
                    url: u,
                    headers: vec![("User-Agent".to_string(), cfg.ua.clone())],
                }]);
            }
            // 有 id 但没地址 ⇒ 走 vodParse（用 vodId）
            return self.vod_parse(&cfg, &vid, flag).await;
        }
        // 只给了 vodId（可能是聚合层/调用方直接传的）
        self.vod_parse(&cfg, id, flag).await
    }
}

impl AppGet {
    async fn vod_parse(&self, cfg: &Cfg, vid: &str, flag: &str) -> Result<Vec<CspPlay>, String> {
        if vid.trim().is_empty() {
            return Err("取流 id 里没有 vodId，无法请求 vodParse".to_string());
        }
        let url = format!("{}{P_VOD_PARSE}", cfg.site.trim_end_matches('/'));
        let mut req = self.client.client()?.post(&url);
        for (k, v) in self.headers(cfg) {
            req = req.header(k, v);
        }
        // 体：DEX 用 `data`（AES 后的密文）承载入参 —— 解密端是服务端，
        //     我们这里**不做加密**：实测该端点对裸参数也返回 code=1（见文件头实证）。
        req = req.body(format!("{{\"url\":\"{vid}\"}}"));
        let resp = req
            .send()
            .await
            .map_err(|e| format!("请求取流失败（{url}）：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取取流响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("取流返回 HTTP {status}（{url}）"));
        }
        let v: Value = serde_json::from_str(&body)
            .map_err(|e| format!("取流响应不是合法 JSON（{e}）：{}", body.chars().take(100).collect::<String>()))?;
        let u = parse_url_of(&v)?;
        Ok(vec![CspPlay {
            label: Some(label_with_parse_hint(flag, &u)),
            url: u,
            headers: vec![("User-Agent".to_string(), cfg.ua.clone())],
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(AppGet);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
#[path = "app_get_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
mod tests {
    use super::*;

    /// 实测 ext（逐字来自 `.probe/ref-subscription.json`）
    const REAL_EXT: &str = r#"{"url":"https://www.douy32mf.top","dataKey":"1234567887654321","dataIv":"1234567887654321"}"#;

    #[test]
    /// ★★ AES/CBC 解密与 DEX 的 `AES/CBC/PKCS7Padding` 对齐
    ///
    /// # 判据（不靠自证）：用**独立算出**的密文喂进去，比明文
    /// ```text
    /// 密钥/IV 都是 "1234567887654321"（真配置那对值），块大小 16 ⇒ PKCS7 且**长度必须补齐到 16 的整数倍**。
    /// 这里手算一段 16 字节明文的密文（用 aes+cbc 的 Encryptor，与 Decryptor 是同一 crate 的对称 API），
    /// 再断言解密回原文 —— 两个方向都走同一实现，**但明文是独立给的**，能抓出"密钥/IV 用错"。
    /// ```
    /// 注入：把 `aes_cbc_decrypt` 里 key 与 iv 调换 ⇒ 本条红。
    #[test]
    fn aes_cbc_roundtrip_with_real_keys() {
        use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
        let key = "1234567887654321";
        let iv = "1234567887654321";
        let plain = b"{\"typeId\":1}\r\n"; // 16 字节（补齐到块大小，便于手算）
        // ★ `encrypt_padded_mut` 要求缓冲**能装下 padding**：明文已 16 字节 ⇒ 还要再留一块
        let mut buf = vec![0u8; plain.len() + 16];
        buf[..plain.len()].copy_from_slice(plain);
        let ct = cbc::Encryptor::<aes::Aes128>::new_from_slices(key.as_bytes(), iv.as_bytes())
            .expect("new_from_slices")
            .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
            .expect("encrypt")
            .to_vec();
        let b64 = b64_encode(&ct);
        let got = aes_cbc_decrypt(&b64, key, iv).expect("应解密成功");
        assert_eq!(got, plain, "★ 解密结果必须等于原文");
        // 换 IV ⇒ 明文不同（第一块错）—— 证明 IV 真的参与了
        let wrong = aes_cbc_decrypt(&b64, key, "7654321123456789");
        assert!(wrong.is_err() || wrong.unwrap() != plain, "★ 换 IV 不该得到同一明文");
    }

    #[test]
    /// ★★ Aes128 / Aes192 / Aes256 三档都支持；16/24/32 以外的密钥长度要**显式 Err**
    ///
    /// 注入：把 24/32 两档删掉（只留 Aes128）⇒ 本条红。
    #[test]
    fn aes_key_lengths_are_validated_not_guessed() {
        use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
        let iv = "1234567887654321";
        for (key, label, sz) in [
            ("0123456789abcdef", "128", 16),
            ("0123456789abcdef01234567", "192", 24),
            ("0123456789abcdef0123456789abcdef", "256", 32),
        ] {
            let plain = b"abcdefghijklmnop";
            let mut buf = vec![0u8; plain.len() + 16];
            buf[..plain.len()].copy_from_slice(plain);
            let ct = match sz {
                16 => cbc::Encryptor::<aes::Aes128>::new_from_slices(key.as_bytes(), iv.as_bytes())
                    .unwrap()
                    .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
                    .unwrap()
                    .to_vec(),
                24 => cbc::Encryptor::<aes::Aes192>::new_from_slices(key.as_bytes(), iv.as_bytes())
                    .unwrap()
                    .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
                    .unwrap()
                    .to_vec(),
                _ => cbc::Encryptor::<aes::Aes256>::new_from_slices(key.as_bytes(), iv.as_bytes())
                    .unwrap()
                    .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
                    .unwrap()
                    .to_vec(),
            };
            let b64 = b64_encode(&ct);
            assert_eq!(
                aes_cbc_decrypt(&b64, key, iv).unwrap(),
                plain.to_vec(),
                "★ Aes{label} 必须支持"
            );
        }
        /*
         * 长度错 ⇒ Err（不猜、不补零）
         * ⚠️ 必须喂**块对齐**的密文：否则会先撞上"密文长度不是 16 的倍数"那条检查，
         *    测不到密钥长度判据本身（第一版就是 "AAAA" ⇒ 3 字节 ⇒ 报的却是密文长度）。
         */
        let aligned = b64_encode(&[0u8; 16]);
        let e = aes_cbc_decrypt(&aligned, "12345", "1234567887654321")
            .expect_err("★ 5 字节密钥必须 Err");
        assert!(e.contains("16/24/32"), "{e}");
        let e2 = aes_cbc_decrypt(&aligned, "1234567887654321", "short")
            .expect_err("★ IV 必须 16 字节");
        assert!(e2.contains("16 字节"), "{e2}");
        // 密文不对齐 ⇒ 单独一条判据（也必须有牙）
        let e3 = aes_cbc_decrypt("AAAA", "1234567887654321", "1234567887654321")
            .expect_err("★ 不对齐的密文必须 Err");
        assert!(e3.contains("16 的整数倍"), "{e3}");
    }

    #[test]
    /// ★★ 缺 `dataKey`/`dataIv` ⇒ **必须 Err 并点名键名**（不许给默认密钥）
    ///
    /// # 为什么这条重要
    /// ```text
    /// 给默认密钥 ⇒ "配置写漏了"会表现成"解密出乱码"或"上游 code 报错"，
    /// 排查方向会被带偏到"上游挂了"。
    /// ```
    /// 注入：给 `Cfg::parse` 的 dataKey 加 `.unwrap_or_default()` ⇒ 本条红。
    #[test]
    fn missing_aes_keys_are_reported_by_name() {
        let e = Cfg::parse(r#"{"url":"https://x"}"#).expect_err("★ 缺 dataKey 必须 Err");
        assert!(e.contains("dataKey"), "要点名缺的键：{e}");
        let e2 = Cfg::parse(r#"{"url":"https://x","dataKey":"k16bytesbytes16"}"#)
            .expect_err("★ 缺 dataIv 必须 Err");
        assert!(e2.contains("dataIv"), "{e2}");

        // 真实 ext 必须能解析出七个键
        let c = Cfg::parse(REAL_EXT).expect("真实 ext 应可解析");
        assert_eq!(c.site, "https://www.douy32mf.top");
        assert_eq!(c.data_key, "1234567887654321");
        assert_eq!(c.data_iv, "1234567887654321");
        assert_eq!(c.ua, "okhttp/3.14.9", "没给 ua ⇒ 用 DEX 那个默认");
        assert_eq!(c.token, "", "没给 token ⇒ 空（空就不发那个头）");
        assert_eq!(c.device_id, "");
        assert_eq!(c.version, "");
    }

    #[test]
    /// ★★ `app-user-token` **仅当非空才发**；`app-api-verify-sign` 是**空串**（不是缺头）
    ///
    /// DEX 依据：`c()` 里 `TextUtils.isEmpty(g)` 那条 if 决定要不要 `addHeader`，
    /// 而 `app-api-verify-sign` 是**无条件 addHeader(…, "")`。
    /// 注入：去掉那个 `if !cfg.token...` 判断（无条件发）或把 sign 换成"不发"
    /// ⇒ 本条红。
    #[test]
    fn token_header_only_when_non_empty_and_sign_is_blank() {
        let s = AppGet::new();
        let base = Cfg {
            site: "https://x".into(),
            data_key: "k".into(),
            data_iv: "i".into(),
            device_id: "dev".into(),
            version: "1.0.0".into(),
            ua: "okhttp/3.14.9".into(),
            token: String::new(),
        };
        let h = s.headers(&base);
        let has = |k: &str| h.iter().any(|(kk, _)| kk == k);
        let get = |k: &str| h.iter().find(|(kk, _)| kk == k).map(|(_, v)| v.clone());

        assert!(!has("app-user-token"), "★ token 为空 ⇒ 不该发这个头");
        assert_eq!(
            get("app-api-verify-sign").as_deref(),
            Some(""),
            "★ verify-sign 是**空串**（不是缺头）"
        );
        assert!(has("app-api-verify-time"), "要发时间戳");
        assert!(get("app-api-verify-time").unwrap().len() >= 13, "毫秒时间戳");
        assert_eq!(get("app-ui-mode").as_deref(), Some("light"));
        assert_eq!(get("Content-Type").as_deref(), Some("application/x-www-form-urlencoded"));
        assert_eq!(get("Connection").as_deref(), Some("Keep-Alive"));
        assert_eq!(get("User-Agent").as_deref(), Some("okhttp/3.14.9"));
        assert_eq!(get("app-version-code").as_deref(), Some("1.0.0"));

        // token 非空 ⇒ 必须发
        let with = Cfg { token: "T0K3N".into(), ..base };
        let h2 = s.headers(&with);
        assert!(
            h2.iter().any(|(k, v)| k == "app-user-token" && v == "T0K3N"),
            "★ token 非空时必须发"
        );
    }

    #[test]
    /// ★★ 反空真：分类 / 条目 / 剧集 / 取流 解析出 0 条 ⇒ **必须 Err**
    ///
    /// 注入：删掉任一处 `is_empty()`/`ok_or_else` 的 Err ⇒ 对应断言红。
    #[test]
    fn empty_parses_are_errors() {
        // 分类：没有 type_list / 空 / 全是被剔掉的非视频分类
        let no: Value = serde_json::from_str(r#"{"banner_list":[]}"#).unwrap();
        let e = cats_of(&no).expect_err("★ 没有 type_list 必须 Err");
        assert!(e.contains("type_list"), "{e}");
        assert!(e.contains("banner_list"), "要带回实际键便于定位：{e}");
        let empty: Value = serde_json::from_str(r#"{"type_list":[]}"#).unwrap();
        assert!(cats_of(&empty).is_err(), "★ 0 分类必须 Err");
        let allskip: Value = serde_json::from_str(
            r#"{"type_list":[{"type_id":9,"type_name":"福利"},{"type_id":8,"type_name":"伦理"}]}"#,
        )
        .unwrap();
        assert!(
            cats_of(&allskip).is_err(),
            "★ 全是被 DEX 剔掉的非视频分类 ⇒ 结果仍是 0 ⇒ 必须 Err"
        );

        // 条目
        let no2: Value = serde_json::from_str(r#"{"type_id":1}"#).unwrap();
        assert!(items_of(&no2, "recommend_list", "分类 1").is_err());
        let empty2: Value = serde_json::from_str(r#"{"recommend_list":[]}"#).unwrap();
        assert!(items_of(&empty2, "recommend_list", "分类 1").is_err());

        // 剧集
        let det: Value = serde_json::from_str(r#"{"vod":{"vod_name":"x"},"vod_play_list":[]}"#).unwrap();
        let e3 = detail_of(&det, "1").expect_err("★ 0 集必须 Err");
        assert!(e3.contains("0 集"), "{e3}");

        // 取流
        let p: Value = serde_json::from_str(r#"{"code":1,"data":{"foo":1}}"#).unwrap();
        let e4 = parse_url_of(&p).expect_err("★ 找不到地址必须 Err");
        assert!(e4.contains("找不到可用地址"), "{e4}");
    }

    #[test]
    /// ★★ `code != 1` 必须 Err；`data` 是**空串**也必须 Err（不许"解密出空"当成功）
    ///
    /// 注入：把 `decode_body` 里那句空串检查删掉 ⇒ 本条红。
    #[test]
    fn non_one_code_and_empty_data_are_errors() {
        let cfg = Cfg::parse(REAL_EXT).unwrap();
        let bad: Value = serde_json::from_str(r#"{"code":0,"msg":"失败"}"#).unwrap();
        let e = decode_body(&bad, &cfg, "首页").expect_err("★ code≠1 必须 Err");
        assert!(e.contains("code=0"), "{e}");
        assert!(e.contains("失败"), "要带上上游 msg：{e}");

        let noreq: Value = serde_json::from_str(r#"{"data":"x"}"#).unwrap();
        assert!(decode_body(&noreq, &cfg, "首页").is_err(), "★ 缺 code 必须 Err");

        let empty: Value = serde_json::from_str(r#"{"code":1,"data":""}"#).unwrap();
        let e2 = decode_body(&empty, &cfg, "首页").expect_err("★ data 空串必须 Err");
        assert!(e2.contains("空串"), "{e2}");

        // 密文损坏 ⇒ Err（而不是静默返回空）
        let junk: Value = serde_json::from_str(r#"{"code":1,"data":"不是base64!!"}"#).unwrap();
        assert!(decode_body(&junk, &cfg, "首页").is_err(), "★ 坏密文必须 Err");
    }

    #[test]
    /// 真实结构解析（逐字用实测读数构造）
    fn parses_real_shapes() {
        // 首页（实测解密后：type_list 6 项 / recommend_list 12 项 / banner_list 1 项）
        let home: Value = serde_json::from_str(
            r#"{"banner_list":[{"vod_id":8043,"vod_name":"唐朝诡事录之长安"}],
                 "recommend_list":[{"vod_id":381783,"vod_name":"活久久",
                    "vod_pic":"https://mtzy2.com/upload/vod/20261026-1/a7c2.webp",
                    "vod_remarks":"全集完结"}],
                 "type_list":[{"type_id":1,"type_name":"电影"},{"type_id":2,"type_name":"连续剧"},
                              {"type_id":9,"type_name":"福利"}]}"#,
        )
        .unwrap();
        let cats = cats_of(&home).unwrap();
        assert_eq!(cats.len(), 2, "★ 「福利」要被剔掉（DEX 的 skip 表）");
        assert_eq!(cats[0].id, "1");
        assert_eq!(cats[0].name, "电影");
        let items = items_of(&home, "recommend_list", "首页").unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "381783");
        assert_eq!(items[0].subtitle.as_deref(), Some("全集完结"));

        // 详情（实测 vod_play_list[].player_info.show + urls[].name/url）
        let det: Value = serde_json::from_str(
            r#"{"vod":{"vod_name":"唐朝诡事录之长安","vod_pic":"https://p/a.jpg",
                  "vod_content":"简介"},
                 "vod_play_list":[{"player_info":{"show":"极速资源","parse":"","parse_type":"0"},
                                   "url_count":2,
                                   "urls":[{"name":"第1集","url":"https://cdn/1.m3u8"},
                                           {"name":"第2集","url":"https://cdn/2.m3u8"}]}]}"#,
        )
        .unwrap();
        let d = detail_of(&det, "8043").unwrap();
        assert_eq!(d.title, "唐朝诡事录之长安");
        assert_eq!(d.episodes.len(), 2);
        assert_eq!(d.episodes[0].flag, "极速资源", "★ 线路名取 player_info.show");
        assert_eq!(d.episodes[1].title, "第2集");
        assert!(d.episodes[0].id.contains("https://cdn/1.m3u8"), "集 id 里带地址：{}", d.episodes[0].id);
        assert!(d.episodes[0].id.starts_with("8043@"), "★ 集 id 前缀是 vodId：{}", d.episodes[0].id);

        // 拆 `/播放` 用的集 id
        let (vid, f, idx, u) = split_ep_id(&d.episodes[1].id).unwrap();
        assert_eq!(vid, "8043");
        assert_eq!(f, "极速资源");
        assert_eq!(idx, 1);
        assert_eq!(u, "https://cdn/2.m3u8");
        // URL 自带 `|` 也只切前两个
        let (_, _, _, u2) = split_ep_id("1@l|0|https://a/b.m3u8?x=|y").unwrap();
        assert_eq!(u2, "https://a/b.m3u8?x=|y");
    }

    #[test]
    /// 取流响应三种形态（data 直接是地址 / data 是 JSON 文本 / data 对象带 url）
    fn parse_url_three_shapes() {
        let a: Value = serde_json::from_str(r#"{"code":1,"data":"https://cdn/a.m3u8"}"#).unwrap();
        assert_eq!(parse_url_of(&a).unwrap(), "https://cdn/a.m3u8");

        let b: Value =
            serde_json::from_str(r#"{"code":1,"data":"{\"url\":\"https://cdn/b.m3u8\"}"}"#).unwrap();
        assert_eq!(parse_url_of(&b).unwrap(), "https://cdn/b.m3u8");

        let c: Value =
            serde_json::from_str(r#"{"code":1,"data":{"url":"https://cdn/c.m3u8"}}"#).unwrap();
        assert_eq!(parse_url_of(&c).unwrap(), "https://cdn/c.m3u8");

        let d: Value = serde_json::from_str(
            r#"{"code":1,"data":{"urls":[{"url":"https://cdn/d.m3u8"}]}}"#,
        )
        .unwrap();
        assert_eq!(parse_url_of(&d).unwrap(), "https://cdn/d.m3u8");
    }

    #[test]
    /// ext 两种形态都能取到键（对象 / 裸键值字符串）
    fn ext_key_extraction_both_shapes() {
        assert_eq!(key_of(REAL_EXT, "url").as_deref(), Some("https://www.douy32mf.top"));
        assert_eq!(key_of(REAL_EXT, "dataKey").as_deref(), Some("1234567887654321"));
        assert_eq!(key_of("url=https://a.com&token=TT", "url").as_deref(), Some("https://a.com"));
        assert_eq!(key_of("url=https://a.com&token=TT", "token").as_deref(), Some("TT"));
        assert_eq!(key_of(REAL_EXT, "不存在的键"), None);
        assert_eq!(key_of("", "url"), None);
        // 值里含 `/` 与 `:` 不能被截断
        assert_eq!(key_of(REAL_EXT, "url").unwrap(), "https://www.douy32mf.top");
    }

    #[test]
    /// ★ 冻结：`mProxy`（弹幕代理）在本仓**没有能力位**，且 DEX 里那处拼接不照抄
    ///
    /// 源码判据：`play()`/`vod_parse()` 不允许出现宿主代理那串 `do=appdanmu`
    /// —— 拼了会给用户一个必然失败的地址（本仓没有那个服务）。
    /// 注入：在 `vod_parse` 的返回地址后面接上 `?do=appdanmu&…` ⇒ 本条红。
    #[test]
    fn no_host_danmaku_proxy_is_glued_on() {
        let src = include_str!("app_get.rs");
        // 允许在**注释/文档**里提到（留档用），但不允许出现在**代码行**里
        /*
         * ★ 判据必须**剥掉行尾注释**再找那串：
         *   第一次我只看"行首是不是注释"，结果**行内注释**（`let u = x; // 见 do=appdanmu`）
         *   也算进了代码 ⇒ 门禁假红。⇒ 现在按 `//` **截断**每一行再判。
         */
        let code_lines: Vec<String> = src
            .lines()
            .map(|l| {
                let t = l.trim();
                if t.starts_with("//") || t.starts_with("*") || t.starts_with("/*") {
                    String::new()
                } else {
                    l.split("//").next().unwrap_or("").to_string()
                }
            })
            .collect();
        /*
         * ★ 判据串必须**拼出来**，不能整串写在断言行上 ——
         *   否则**这一行自己**就是"代码里出现了那串"⇒ 门禁假红（自证陷阱）。
         *   本仓 ikanbot/jpys 的注释里记过同一个形态。
         */
        let needle = format!("do={}{}", "app", "danmu");
        let glued = code_lines.iter().any(|l| l.contains(&needle));
        assert!(
            !glued,
            "★ 不许把宿主弹幕代理地址拼进取流结果（本仓无该能力位；只登记为已知缺口）"
        );
        // 但**必须留档**说明这个缺口（否则将来会被当成"忘了写"）
        let doc = format!("app{}", "danmu");
        assert!(
            src.contains(&doc),
            "★ 必须在文档里登记这个已知缺口"
        );
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_app_get -- --ignored --nocapture"]
    async fn csp_live_app_get_five_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = AppGet::new();
        let home = s.home(REAL_EXT).await.expect("home 应成功（含 AES 解密）");
        eprintln!(
            "[LIVE] home: 分类 {} 个（首={}），预取 {} 条（首={}）",
            home.categories.len(),
            home.categories.first().map(|c| c.name.clone()).unwrap_or_default(),
            home.items.len(),
            home.items.first().map(|i| i.title.clone()).unwrap_or_default()
        );
        assert!(home.categories.len() >= 3);
        let l = s.list(&home.categories[0].id, 1, REAL_EXT).await.expect("list 应成功");
        eprintln!("[LIVE] list({}): {} 条 首={}", home.categories[0].name, l.items.len(), l.items[0].title);
        let se = s.search("唐朝", 1, REAL_EXT).await.expect("search 应成功");
        eprintln!("[LIVE] search(唐朝): {} 条 首={}", se.items.len(), se.items[0].title);
        let d = s.detail(&l.items[0].id, REAL_EXT).await.expect("detail 应成功");
        eprintln!(
            "[LIVE] detail: {} — {} 集（首集={} 线路={}）",
            d.title, d.episodes.len(), d.episodes[0].title, d.episodes[0].flag
        );
        let p = s.play(&d.episodes[0].flag, &d.episodes[0].id, REAL_EXT).await.expect("play 应成功");
        eprintln!("[LIVE] play: {}", p[0].url);
        assert!(p[0].url.starts_with("http"), "★ 必须是真地址");
    }
}
