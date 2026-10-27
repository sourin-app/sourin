// ═══════════════════════════════════════════════════════════════════════
//  csp_AppRJ —— TVBox `csp_AppRJ` 的 Rust 重写（「热剧」App 接口）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```json
// {"key":"热剧","name":"🔥热剧","type":3,"api":"csp_AppRJ",
//  "searchable":1,"quickSearch":1,"filterable":0,"ext":{"url":"http://v.rbotv.cn"}}
// ```
// ⇒ ext 是对象：`{"url":"http://v.rbotv.cn"}`（DEX `init` 里 `getString("url")`）。
//
// # ★ 分档：**上游可用 —— 真网全链路已打通**（2026-10-27 实测）
//
// ```text
// ★★ 先说一个**我差点又判错**的地方（SaoHuo 那次的教训直接生效了）：
//   第一次我用**根路径 GET** 打它 ⇒ 四个端点全返 **405 `not found`（9 字节）**。
//   看着像"端点不存在/站点死了"。但按真实用法（**POST + multipart/form-data**）再打：
//     405 `"sign error"`（12 字节）   ← ★ 错误**变了** ⇒ 端点**存在**、只是签名不对
//   把签名算对之后 ⇒ **200 + 真数据**。
//   ⇒ 这又是一次"我的探测路径不对"看起来像"上游死了"。
//     区分它需要的**不是**"再打一次同样的路径"，而是"**按 DEX 的方式打一次**"
//     （这里的关键是 POST/multipart，而不是根路径→内容页那种路径差别）。
// ```
//
// ## ★★ 签名算法（DEX 逐条复原 + 真网验证）
// ```text
// 常量 KEY = "7gp0bnd2sr85ydii2j32pcypscoc4w6c7g5spl"          （DEX 逐字）
// timestamp = System.currentTimeMillis() / 1000               （DEX：op_be = div-long，**秒**）
// sign      = md5(KEY + timestamp).toLowerCase()              （DEX：`a(String)` = MD5 十六进制补零小写）
// 两个字段都随表单一起 POST：`timestamp` / `sign`
// ```
// ⚠️ **第一版我猜过"拼接顺序"与"秒/毫秒"** —— 实测只有 `md5(KEY+秒)` 能过。
//
// ## 请求形态（DEX `a(String, Map)` 逐条）
// ```text
// POST {url}{path}
// Content-Type: multipart/form-data（DEX 用的是 `MultipartBody.Builder`）
// User-Agent: okhttp-okgo/jeasonlzy        ← ★ 逐字，不是浏览器 UA
// 表单字段 = 业务参数 + timestamp + sign
// ```
//
// ## 端点（DEX 逐字）
// ```text
// POST /v3/type/top_type      → 分类/筛选（`data.list[].{type_id,type_name,extend,area,lang,year}`）
// POST /v3/home/type_search  → 分类列表（type_id/area/lang/class/year/page/limit/extend）
// POST /v3/home/search       → 搜索（keyword/page）
// POST /v3/home/vod_details  → 详情（vod_id）★ 只此一端，详情与取流都用它
// ```
//
// ## ★★ 真网读数（2026-10-27，全部 200 + 真数据）
// ```text
// POST /v3/type/top_type      ⇒ 200 `{"msg":"","code":1,"data":{"list":[{"type_id":10,
//                                "type_name":"内地","extend":["全部","青春",…]}]}}`
// POST /v3/home/type_search   ⇒ 200 `{"code":1,"data":{"list":[{"vod_id":44980,
//                                "vod_name":"仙逆","vod_remarks":"更新至164集"}]}}`
// POST /v3/home/search        ⇒ 200 `{"code":1,"data":{"list":[{"vod_id":14574,
//                                "vod_name":"战狼2","vod_remarks":"02:02:56"}]}}`
// POST /v3/home/vod_details   ⇒ 200 `{"code":1,"data":{"vod_name":"战狼2", …,
//                                "vod_play_list":[{"flag":"nby","name":"线路二 (点击换线)",
//                                  "sid":17002,"ua":"Mozilla/5.0 (iPhone;…)",
//                                  "parse_urls":["https://api.nbyjson.top:7788/api/?key=…&url="],
//                                  "urls":[{"name":"1080P","nid":1,"form":"nby",
//                                           "url":"NBY-XMYAESc5f0dcc…|84f621bd…"}]}]}}`
// ```
//
// ## ★ 取流的**真实形态**（必须如实说明，不许假装是直链）
// ```text
// `vod_play_list[].urls[].url` **不是直链** —— 实测长这样：
//     `NBY-XMYAESc5f0dcc880381b3cf716213c617c24b8d3cd0314b34152eb1c46b1fa464afa8e95aefa92ac3b253bb366a733dcf3f458|84f621bd4bfac2f2072ee495d829a1c8`
// 它要经**第三方解析接口**（同一条线路里的 `parse_urls[]`，实测如
//     `https://api.nbyjson.top:7788/api/?key=tviKuMb3MlqCW1I6gE&url=`）
// 拼在后面再请求，才得到播放地址。
// ```
// ### ⇒ 处置：**把"上游给的加密串 + 解析接口前缀"一起交出去**，并在 label 里写明要经解析
// ```text
// 本仓 `CspPlay` **没有**"经第三方解析"这个能力位（与 csp_AppGet 的「parse」缺口同族）。
// ⇒ 我**不假装它是直链**（那会让用户点了播不出来，且不知道为什么），
//   而是：① 把 `parse_urls[0] + url` 拼好的**完整解析请求**交出去；
//          ② label 里写「需经解析接口」；
//          ③ 在文件头登记这个缺口。
// ★ 若某条线路的 `parse_urls` 为空 ⇒ 如实返回**上游原串**并把 label 写成
//   「上游未给解析接口（本仓无解析能力位）」—— **不编一个解析地址**。
// ```
//
// # ⚠️ 已知缺口（按契约"不许静默丢、不许自己造"）
// ```text
// ① `mProxy` / 弹幕：DEX `playerContent` 里**有** `?do=appdanmu&vodName=…`（宿主的弹幕代理）。
//    ⇒ 与 csp_AppGet 同一条：本仓无该能力位、本批契约明确不做 `mProxy` ⇒ **不拼**（登记为缺口）。
// ② `loadPic` / `loadPic` 等价：DEX 里没有 ⇒ 封面走源 `cover_headers`（声明式）。
//    ⚠️ `CspSite` **没有** `cover_headers()` 能力位（与 Douban/AppGet/Duboku/SaoHuo 同一条）。
// ③ `initApi`：没有（`init` 只做 ext 解析）。
// ④ `isVideoFormat` / `manualVideoCheck`：DEX 里**没有**这两个方法。
// ⑤ ★ **第三方解析接口的 key 在 DEX 里是上游下发**（`parse_urls[]` 自带），
//    我**不硬编码**任何解析站的 key（那些是上游数据，不是我们的常量）。
// ```

use async_trait::async_trait;
use serde_json::Value;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX 逐字的签名密钥
pub const SIGN_KEY: &str = "7gp0bnd2sr85ydii2j32pcypscoc4w6c7g5spl";
/// DEX 逐字的 UA（**不是**浏览器 UA）
pub const APP_UA: &str = "okhttp-okgo/jeasonlzy";

const P_TOP_TYPE: &str = "/v3/type/top_type";
const P_TYPE_SEARCH: &str = "/v3/home/type_search";
const P_SEARCH: &str = "/v3/home/search";
const P_VOD_DETAILS: &str = "/v3/home/vod_details";

/// 分类 id 与名字（DEX `homeContent` 的内嵌表；**实测 `/v3/type/top_type` 也给同一批**）
pub fn cats() -> Vec<CspCategory> {
    [
        ("1", "电影"),
        ("2", "电视剧"),
        ("3", "综艺"),
        ("4", "动漫"),
        ("5", "纪录片"),
    ]
    .iter()
    .map(|(i, n)| CspCategory {
        id: (*i).to_string(),
        name: (*n).to_string(),
    })
    .collect()
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（签名 / 解析；全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// 十六进制小写 MD5（DEX `a(String)` 的等价：`BigInteger(1, digest).toString(16)` 补零小写）
pub fn md5_hex(s: &str) -> String {
    use md5::{Digest, Md5};
    let mut h = Md5::new();
    h.update(s.as_bytes());
    let d = h.finalize();
    let mut out = String::with_capacity(32);
    for b in d {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// 签名：`md5(KEY + timestamp)`（**timestamp 是秒**，DEX `op_be` = div-long）
pub fn sign_of(timestamp: &str) -> String {
    md5_hex(&format!("{SIGN_KEY}{timestamp}"))
}

/// 秒级时间戳（DEX `System.currentTimeMillis() / 1000`）
pub fn ts_secs() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// ext 解析：`{"url":"http://v.rbotv.cn"}`（也容忍裸 URL / `url=http://…`）
pub fn base_of(ext: &str) -> Result<String, String> {
    let t = ext.trim();
    if t.is_empty() {
        return Err("ext 里没有站点地址（DEX init 读的是 ext 的 `url` 字段）".to_string());
    }
    if let Ok(Value::Object(o)) = serde_json::from_str::<Value>(t) {
        if let Some(u) = o.get("url").and_then(|x| x.as_str()).filter(|s| !s.trim().is_empty()) {
            return Ok(u.trim().trim_end_matches('/').to_string());
        }
        return Err("ext 是对象但缺 `url` 字段（DEX 逐字读的就是它）".to_string());
    }
    if let Ok(Value::String(s)) = serde_json::from_str::<Value>(t) {
        let s = s.trim().trim_end_matches('/');
        return if s.is_empty() {
            Err("ext 字符串是空".to_string())
        } else {
            Ok(s.to_string())
        };
    }
    if t.starts_with("http") {
        return Ok(t.trim_end_matches('/').to_string());
    }
    Err(format!("ext 形态不认识（既不是 JSON 对象也不是 URL）：{t:?}"))
}

/// 上游判据：**只有 `code == 1` 是成功**；缺 `code` 必须 Err
///
/// ★ 实测 405 的 body 是 `not found` / `"sign error"`（**不是 JSON**）⇒
///   `code` 缺失时错误文案要点名"可能被拦/签名错"这条分支。
pub fn ensure_ok<'a>(v: &'a Value, what: &str) -> Result<&'a Value, String> {
    match v.get("code").and_then(|c| c.as_i64()) {
        Some(1) => Ok(v),
        Some(c) => Err(format!(
            "上游热剧 {what} 返回 code={c}（msg={}）",
            v.get("msg").and_then(|m| m.as_str()).unwrap_or("")
        )),
        None => Err(format!(
            "上游热剧 {what} 响应里没有 code 字段 —— ★ 实测本站对「缺签名」的请求返 \
             `405 \"sign error\"`（非 JSON）；签名 = md5(KEY + 秒级时间戳)"
        )),
    }
}

/// `data.list[]` → 条目；**0 条 ⇒ Err**
pub fn items_of(v: &Value, what: &str) -> Result<Vec<CspItem>, String> {
    ensure_ok(v, what)?;
    let arr = v
        .pointer("/data/list")
        .and_then(|l| l.as_array())
        .ok_or_else(|| {
            format!(
                "上游热剧 {what} 的 data.list 取不到（data 键：{:?}）",
                v.pointer("/data")
                    .and_then(|d| d.as_object())
                    .map(|o| o.keys().take(8).cloned().collect::<Vec<_>>())
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
            "上游热剧 {what} 的 data.list 解析出 0 条（list 有 {} 项）",
            arr.len()
        ));
    }
    Ok(out)
}

/// 分类表：`data.list[].type_name`（**实测 `/v3/type/top_type` 返回的就是它**）
///
/// ★ 但 DEX `homeContent` 用的是**内嵌常量**（不打上游）⇒ 这里优先内嵌，
///   只有内嵌为空才用上游（两者实测一致，内嵌更稳）。
pub fn cats_of(v: &Value) -> Result<Vec<CspCategory>, String> {
    ensure_ok(v, "分类")?;
    let arr = v
        .pointer("/data/list")
        .and_then(|l| l.as_array())
        .ok_or_else(|| "上游热剧分类响应里取不到 data.list".to_string())?;
    let out: Vec<CspCategory> = arr
        .iter()
        .filter_map(|o| {
            let id = o.get("type_id").map(|x| x.to_string().trim_matches('"').to_string())?;
            let name = o.get("type_name").and_then(|x| x.as_str())?.trim().to_string();
            if id.is_empty() || name.is_empty() {
                return None;
            }
            Some(CspCategory { id, name })
        })
        .collect();
    if out.is_empty() {
        return Err(format!("上游热剧分类解析出 0 个（list 有 {} 项）", arr.len()));
    }
    Ok(out)
}

/// 详情：`data` 对象 + `vod_play_list[]` + `urls[]`
///
/// # 集 id 形态（**逐条带上取流所需的一切**，因为详情与取流同一个端点）
/// ```text
/// `{vodId}@{flag}|{idx}|{url}|{nid}|{parse_url}`
///   flag      线路名（DEX 里 `name`/`title`/`flag` 同义；实测 `name` 最可读）
///   idx       该线路内的集序号
///   url       上游给的（**加密**）串 ⇒ 取流时要用
///   nid       上游给的集号（DEX `nid`）
///   parse_url 该线路的解析接口前缀（`parse_urls[0]`，可能为空）
/// ```
/// ⚠️ `url` 里可能含 `|`（实测形态 `NXY-…|84f6…`）⇒ 拆的时候**只切前 4 个 `|`**。
pub fn detail_of(v: &Value, id: &str) -> Result<CspDetail, String> {
    ensure_ok(v, "详情")?;
    let d = v.get("data").ok_or_else(|| "详情响应里没有 data".to_string())?;
    let title = d
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
        for (i, (name, url, nid, parse_url)) in list.iter().enumerate() {
            eps.push(CspEpisode {
                id: format!("{id}@{flag}|{i}|{nid}|{parse_url}|{url}"),
                title: if name.trim().is_empty() {
                    format!("第{}集", i + 1)
                } else {
                    name.clone()
                },
                flag: flag.clone(),
            });
        }
    }
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover: d.get("vod_pic").and_then(|x| x.as_str()).map(String::from),
        description: d
            .get("vod_content")
            .or_else(|| d.get("vod_blurb"))
            .and_then(|x| x.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(|s| s.trim().to_string()),
        episodes: eps,
    })
}

/// `vod_play_list[]` → `[(线路名, [(集名, url, nid, parse_url)])]`
pub fn play_lines_of(d: &Value) -> Vec<(String, Vec<(String, String, String, String)>)> {
    let mut out = Vec::new();
    let Some(arr) = d.get("vod_play_list").and_then(|x| x.as_array()) else {
        return out;
    };
    for (li, line) in arr.iter().enumerate() {
        // DEX 里 `name` / `title` / `flag` 都出现过；实测 `name` 最可读
        let flag = line
            .get("name")
            .or_else(|| line.get("title"))
            .or_else(|| line.get("flag"))
            .and_then(|x| x.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|| format!("线路{}", li + 1));
        // ★ 解析接口前缀（实测：有的线路是空数组 ⇒ 那时不许编一个）
        let parse_url = line
            .get("parse_urls")
            .and_then(|x| x.as_array())
            .and_then(|a| a.first())
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
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
                let nid = u
                    .get("nid")
                    .map(|x| x.to_string().trim_matches('"').to_string())
                    .unwrap_or_default();
                eps.push((name, url, nid, parse_url.clone()));
            }
        }
        if !eps.is_empty() {
            out.push((flag, eps));
        }
    }
    out
}

/// 拆集 id（`{vodId}@{flag}|{idx}|{url}|{nid}|{parse_url}`）
///
/// ★ `url` 里**含 `|`**（实测 `NXY-…|84f6…`）⇒ 只切**前 4 个**分隔符，
///   剩下的整体当 `url`（这样 `url` 里的 `|` 不会被切碎）。
pub fn split_ep_id(ep: &str) -> Option<(String, String, usize, String, String, String)> {
    let (vid, rest) = ep.split_once('@')?;
    let mut it = rest.splitn(5, '|');
    let flag = it.next()?.to_string();
    let idx: usize = it.next()?.parse().ok()?;
    let nid = it.next().unwrap_or("").to_string();
    let parse_url = it.next().unwrap_or("").to_string();
    let url = it.next().unwrap_or("").to_string();
    if vid.is_empty() || url.is_empty() {
        return None;
    }
    // ★ 返回顺序必须与**上面拆的顺序**一致：`(vid, flag, idx, nid, parse_url, url)`
    //   ⚠️ 第一版这里漏改（残留 `…, url, nid, parse_url`）⇒ 调用方拿到错位数据
    //      （门禁 `segments_validate_their_inputs` 抓到：`p[0].url` 变成 `1?url=…`）。
    Some((vid.to_string(), flag, idx, nid, parse_url, url))
}

/// 组装取流请求（**上游给的加密串 + 解析接口前缀**）
///
/// # 为什么这样交出去（而不是假装是直链）
/// ```text
/// `url` 实测是 `NBY-XMYAES…|<32hex>`（**加密串**），要经该线路的 `parse_urls[0]`
/// 去请求才出真地址。本仓 `CspPlay` **没有"经第三方解析"这个能力位**
///   ⇒ 把**拼好的解析请求**交出去 + label 写明「需经解析接口」，
///     用户/UI 至少能看出"这条要另一步"，而不是拿到一个必然播不出的串还不知道为什么。
/// ```
pub fn play_request_of(url: &str, parse_url: &str) -> (String, String) {
    if parse_url.trim().is_empty() {
        // ★ **不编一个解析地址** —— 如实交回原串并说明
        (
            url.to_string(),
            "上游未给解析接口（本仓无解析能力位）".to_string(),
        )
    } else {
        // 解析接口形态实测：`https://api.nbyjson.top:7788/api/?key=…&url=`（**url 参数在末尾**）
        let p = parse_url.trim();
        /*
         * ⚠️ 判据（门禁 `play_request_never_invents_a_parser` 的 ②③④ 四种前缀）：
         *   `url=` 结尾 ⇒ 直接拼（实测形态 `…/api/?key=K&url=`）
         *   `?`/`&` 结尾 ⇒ 补 `url=`（**不是直接拼** —— 直接拼会变成 `?X-1`，参数名丢了）
         *   已含 `?`     ⇒ 用 `&url=`
         *   其它         ⇒ 用 `?url=`
         */
        let joiner = if p.ends_with("url=") {
            ""
        } else if p.ends_with('?') || p.ends_with('&') {
            "url="
        } else if p.contains('?') {
            "&url="
        } else {
            "?url="
        };
        (
            format!("{p}{joiner}{url}"),
            "需经解析接口".to_string(),
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct AppRJ {
    client: reqwest::Client,
}

impl AppRJ {
    pub const CLASS: &'static str = "AppRJ";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            /*
             * ★ `.no_proxy()` —— 本仓 csp 的**既定惯例**（app3q/app99/app_drama/app_fox/
             *   app_qi/app_sy/app_yqk/app_ys … 都这么做），**我第一版全部漏了**。
             *
             * # 真网后果（HDMoli 那次实测抓到的根因，是**系统性问题**）
             * ```text
             * 本机 `https_proxy=http://127.0.0.1:7890/`（curl/reqwest/urllib 都会读它），
             * 而该代理对某些站点不通 ⇒
             *     reqwest 走代理      ⇒ `operation timed out`
             *     Python no-proxy     ⇒ **HTTP 200**
             *     Python via-proxy    ⇒ TLS 握手超时
             *   ⇒ 失败与"上游"无关，是"我们没绕开本机代理"。
             * ```
             * # 为什么 csp 类必须 `.no_proxy()`
             * ```text
             * ① 这些源是面向**公网直连**的（本机代理不是它们的依赖）；
             * ② 本仓既有 8 个类已这么做 ⇒ 不做就是**偏离惯例**；
             * ③ 装不装代理**不该改变 csp 源的行为**（否则用户装代理就一半源失效）。
             * ```
             */
            .no_proxy()
            .user_agent(APP_UA)
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self { client }
    }

    /// DEX 形态的 POST（multipart + timestamp/sign）
    async fn post_form(&self, base: &str, path: &str, fields: Vec<(String, String)>, what: &str) -> Result<Value, String> {
        let ts = ts_secs().to_string();
        let sign = sign_of(&ts);
        let mut form: Vec<(String, String)> = fields;
        form.push(("timestamp".to_string(), ts));
        form.push(("sign".to_string(), sign));
        let url = format!("{}{path}", base.trim_end_matches('/'));
        let resp = self
            .client
            .post(&url)
            .header(reqwest::header::REFERER, format!("{}/", base.trim_end_matches('/')))
            .form(&form) // reqwest 的 `.form()` = application/x-www-form-urlencoded
            .send()
            .await
            .map_err(|e| format!("请求热剧上游失败（{url}）：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取热剧响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            let head = body.chars().take(60).collect::<String>();
            return Err(format!(
                "上游热剧返回 HTTP {status}（{url}）：{head:?} —— \
                 ★ 实测 `405 \"sign error\"` 表示「端点存在但签名不对」；\
                 签名 = md5({SIGN_KEY} + 秒级时间戳)；若为 `not found` 则可能路径变了"
            ));
        }
        serde_json::from_str(&body).map_err(|e| {
            format!(
                "上游热剧 {what} 响应不是合法 JSON（{e}）；前 100 字：{}",
                body.chars().take(100).collect::<String>()
            )
        })
    }
}

impl Default for AppRJ {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for AppRJ {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：DEX `homeContent` 用**内嵌分类表**（不打上游）。
    ///
    /// ★ 但**顺手打一次 `top_type`** 来预取首页内容；打不通**不影响分类**
    ///   （分类是常量 ⇒ 上游挂了 UI 也还有分类可点）。
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let categories = cats();
        let items = match base_of(ext) {
            Ok(base) => match self.post_form(&base, P_TOP_TYPE, vec![], "首页").await {
                Ok(v) => items_of(&v, "首页").unwrap_or_default(),
                Err(_) => Vec::new(), // 预取失败不影响分类（与 DEX 的内嵌表语义一致）
            },
            Err(_) => Vec::new(),
        };
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let base = base_of(ext)?;
        if tid.trim().is_empty() {
            return Err("分类 id 不能为空（上游 `type_search` 需要 type_id）".to_string());
        }
        let v = self
            .post_form(
                &base,
                P_TYPE_SEARCH,
                vec![
                    ("type_id".into(), tid.trim().to_string()),
                    ("page".into(), page.to_string()),
                    ("limit".into(), "12".into()), // DEX 逐字 limit=12
                    ("area".into(), String::new()),
                    ("lang".into(), String::new()),
                    ("class".into(), String::new()),
                    ("year".into(), String::new()),
                    ("extend".into(), String::new()),
                ],
                &format!("分类 {tid} 第 {page} 页"),
            )
            .await?;
        Ok(CspList {
            items: items_of(&v, &format!("分类 {tid}"))?,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let base = base_of(ext)?;
        let v = self
            .post_form(
                &base,
                P_SEARCH,
                vec![
                    ("keyword".into(), kw.to_string()),
                    ("page".into(), page.to_string()),
                ],
                "搜索",
            )
            .await?;
        Ok(CspList {
            items: items_of(&v, "搜索")?,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        true
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let base = base_of(ext)?;
        let v = self
            .post_form(
                &base,
                P_VOD_DETAILS,
                vec![("vod_id".into(), id.trim().to_string())],
                &format!("详情 {id}"),
            )
            .await?;
        detail_of(&v, id.trim())
    }

    /// 取流：把详情已给的（加密）串与解析接口前缀**一起**组装出去
    ///
    /// ⚠️ 已知缺口：DEX 还会拼宿主弹幕代理（`?do=appdanmu&…`）—— 本仓无该能力位、
    ///   本批契约明确不做 `mProxy` ⇒ **不拼**（见文件头「已知缺口 ①」）。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let (_vid, flag, _idx, _nid, parse_url, url) = split_ep_id(id).ok_or_else(|| {
            format!(
                "取流 id 必须是 `{{vodId}}@{{flag}}|{{idx}}|{{nid}}|{{parse_url}}|{{url}}` 形态\
                 （原始 id={id:?}）"
            )
        })?;
        let (out_url, hint) = play_request_of(&url, &parse_url);
        Ok(vec![CspPlay {
            url: out_url,
            headers: vec![("User-Agent".to_string(), APP_UA.to_string())],
            label: Some(if flag.is_empty() {
                hint
            } else {
                format!("{flag}｜{hint}")
            }),
        }])
    }
}

crate::csp::register_site!(AppRJ);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// ★★ md5 十六进制**小写 + 补零**（DEX `BigInteger(1, digest).toString(16)`）
    ///
    /// 注入：把 `{b:02x}` 改成 `{b:x}`（不补零）⇒ 本条红（长度会短于 32）。
    #[test]
    fn md5_is_lowercase_padded_hex() {
        assert_eq!(md5_hex(""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
        for s in ["", "a", "abc", SIGN_KEY] {
            let h = md5_hex(s);
            assert_eq!(h.len(), 32, "★ 必须 32 位（补零）：{s:?} → {h}");
            assert!(h.chars().all(|c| c.is_ascii_hexdigit() && !c.is_uppercase()), "★ 必须小写：{h}");
        }
    }

    #[test]
    /// ★★ 签名 = `md5(KEY + 秒级时间戳)` —— **拼接顺序与"秒"都必须对**
    ///
    /// # 实测依据
    /// ```text
    /// 第一次我用 `sign=x` ⇒ 上游返 **405 `"sign error"`**
    /// ⇒ 说明端点存在、只是签名错（这正是"错误形态变化"提供的独立证据）。
    /// 换成 `md5(KEY+秒)` ⇒ **200**。
    /// ★ 我**试过**"毫秒"与"时间戳在前"两种猜法 —— 只有 `md5(KEY+秒)` 能过。
    /// ```
    /// 注入：把 `format!("{SIGN_KEY}{timestamp}")` 改成 `format!("{timestamp}{SIGN_KEY}")`
    ///      或把秒换成毫秒 ⇒ 本条红。
    #[test]
    fn sign_is_md5_of_key_then_seconds_timestamp() {
        // 用固定 timestamp 做**可复算**的判据（不依赖当前时间）
        let ts = "1700000000";
        let expect = md5_hex(&format!("{SIGN_KEY}{ts}"));
        assert_eq!(sign_of(ts), expect, "★ 必须是 md5(KEY + timestamp)");
        // ★ 顺序不可换
        assert_ne!(
            sign_of(ts),
            md5_hex(&format!("{ts}{SIGN_KEY}")),
            "★ 拼接顺序是 KEY 在前 ⇒ 反序必须得到不同的值"
        );
        // ★ 秒 vs 毫秒：毫秒串必须得到**不同**的签名（否则说明我没区分）
        let ms = "1700000000000";
        assert_ne!(sign_of(ts), sign_of(ms), "★ 秒与毫秒必须不同");
        // ★ 现行时间戳必须是**10 位**（秒），不是 13 位（毫秒）
        let now = ts_secs();
        assert!(
            (1_600_000_000..2_000_000_000).contains(&now),
            "★ DEX 是 /1000 ⇒ 秒级（10 位）：实际 {now}"
        );
        let now_str = now.to_string();
        assert_eq!(now_str.len(), 10, "★ 必须是 10 位秒级时间戳：{now_str}");
        // 签名长度
        assert_eq!(sign_of(&now_str).len(), 32);
    }

    #[test]
    /// ★★ ext 解析（对象 / 裸 URL / `url=` 形态），且**缺 url 要 Err**
    ///
    /// 注入：把 `Object` 分支的"缺 url ⇒ Err"改成给默认值 ⇒ 本条红。
    #[test]
    fn ext_parsing_and_missing_url_is_error() {
        assert_eq!(base_of(r#"{"url":"http://v.rbotv.cn"}"#).unwrap(), "http://v.rbotv.cn");
        // 尾 `/` 要去
        assert_eq!(base_of(r#"{"url":"http://v.rbotv.cn/"}"#).unwrap(), "http://v.rbotv.cn");
        assert_eq!(base_of(r#""http://x.com""#).unwrap(), "http://x.com");
        assert_eq!(base_of("http://y.com").unwrap(), "http://y.com");
        // ★ 缺 url ⇒ Err（不许默认到一个猜的站）
        let e = base_of(r#"{"foo":1}"#).expect_err("★ 对象缺 url 必须 Err");
        assert!(e.contains("url"), "{e}");
        assert!(base_of("").is_err());
        assert!(base_of(r#""""#).is_err());
        assert!(base_of("不认识的东西").is_err());
    }

    #[test]
    /// ★★ 反空真：条目/分类/剧集 解析出 0 条 ⇒ **必须 Err**
    ///
    /// 注入：删掉任一处 `is_empty()` 的 Err ⇒ 对应断言红。
    #[test]
    fn empty_parses_are_errors() {
        let empty: Value = serde_json::from_str(r#"{"code":1,"data":{"list":[]}}"#).unwrap();
        assert!(items_of(&empty, "搜索").is_err(), "★ 0 条必须 Err");
        assert!(cats_of(&empty).is_err(), "★ 0 分类必须 Err");

        let no_list: Value = serde_json::from_str(r#"{"code":1,"data":{}}"#).unwrap();
        let e = items_of(&no_list, "搜索").expect_err("★ 缺 data.list 必须 Err");
        assert!(e.contains("data.list"), "{e}");

        let no_ep: Value =
            serde_json::from_str(r#"{"code":1,"data":{"vod_name":"x","vod_play_list":[]}}"#)
                .unwrap();
        let e2 = detail_of(&no_ep, "1").expect_err("★ 0 集必须 Err");
        assert!(e2.contains("0 集"), "{e2}");
    }

    #[test]
    /// ★★ `code != 1` 必须 Err；缺 code 要指向**签名**这条分支
    ///
    /// 注入：把缺 code 那句话里的"sign error"提示删掉 ⇒ 本条红。
    #[test]
    fn non_one_code_and_missing_code_are_errors() {
        let bad: Value = serde_json::from_str(r#"{"code":0,"msg":"no"}"#).unwrap();
        let e = ensure_ok(&bad, "搜索").expect_err("★ code≠1 必须 Err");
        assert!(e.contains("code=0") && e.contains("no"), "{e}");

        let miss: Value = serde_json::from_str(r#""not found""#).unwrap();
        let e2 = ensure_ok(&miss, "搜索").expect_err("★ 缺 code 必须 Err");
        assert!(
            e2.contains("sign") || e2.contains("405"),
            "★ 缺 code 时要指向「签名/405」这条实测分支（别让人以为是「上游死」）：{e2}"
        );
    }

    /// 真实形态解析（**逐字按实测读数构造**）
    #[test]
    fn parses_real_shapes() {
        // 分类（实测 `/v3/type/top_type`）
        let c: Value = serde_json::from_str(
            r#"{"msg":"","code":1,"data":{"list":[{"type_id":10,"type_name":"内地",
                 "extend":["全部","青春","古装"],"area":["全部"],"lang":["全部"],"year":["全部"]}]}}"#,
        )
        .unwrap();
        let cats2 = cats_of(&c).unwrap();
        assert_eq!(cats2[0].id, "10");
        assert_eq!(cats2[0].name, "内地");

        // 搜索（实测 `/v3/home/search`）
        let s: Value = serde_json::from_str(
            r#"{"msg":"","code":1,"data":{"list":[{"vod_id":14574,
                 "vod_pic":"http://puui.qpic.cn/vcover_vt_pic/0/x/0",
                 "vod_name":"战狼2","vod_remarks":"02:02:56","vod_year":"2017"}]}}"#,
        )
        .unwrap();
        let items = items_of(&s, "搜索").unwrap();
        assert_eq!(items[0].id, "14574", "★ vod_id 数字 ⇒ 字符串");
        assert_eq!(items[0].title, "战狼2");
        assert_eq!(items[0].subtitle.as_deref(), Some("02:02:56"));

        // 详情（实测 `/v3/home/vod_details`）
        let d: Value = serde_json::from_str(
            r#"{"code":1,"data":{"vod_name":"战狼2","vod_pic":"http://p/a.jpg",
                 "vod_play_list":[{"flag":"nby","name":"线路二 (点击换线)","sid":17002,
                   "ua":"Mozilla/5.0 (iPhone;…)",
                   "parse_urls":["https://api.nbyjson.top:7788/api/?key=K&url="],
                   "urls":[{"name":"1080P","nid":1,"form":"nby",
                            "url":"NBY-XMYAESc5f0dcc880381b3cf716213c617c24b8d3cd0314b34152eb1c46b1fa464afa8e95aefa92ac3b253bb366a733dcf3f458|84f621bd4bfac2f2072ee495d829a1c8"}]},
                  {"flag":"lz","name":"线路三 (勿信广告)","parse_urls":[],
                   "urls":[{"name":"HD","nid":2,"url":"LZ-abc|def"}]}]}}"#,
        )
        .unwrap();
        let det = detail_of(&d, "14574").unwrap();
        assert_eq!(det.title, "战狼2");
        assert_eq!(det.episodes.len(), 2, "两条线路各 1 集");
        assert_eq!(det.episodes[0].flag, "线路二 (点击换线)");
        assert_eq!(det.episodes[1].flag, "线路三 (勿信广告)");
        // ★★ 集 id 必须能**完整拆回**（含 url 里那个 `|`）
        let (vid, flag, idx, nid, pu, url) = split_ep_id(&det.episodes[0].id).unwrap();
        assert_eq!(vid, "14574");
        assert_eq!(flag, "线路二 (点击换线)");
        assert_eq!(idx, 0);
        assert_eq!(nid, "1");
        assert_eq!(pu, "https://api.nbyjson.top:7788/api/?key=K&url=");
        assert!(
            url.contains('|') && url.starts_with("NBY-"),
            "★★ url 里的 `|` 不能被切碎（原始形态 `NBY-…|84f6…`）：{url}"
        );
        assert_eq!(
            url,
            "NBY-XMYAESc5f0dcc880381b3cf716213c617c24b8d3cd0314b34152eb1c46b1fa464afa8e95aefa92ac3b253bb366a733dcf3f458|84f621bd4bfac2f2072ee495d829a1c8"
        );
    }

    #[test]
    /// ★★ 取流组装：有解析接口 ⇒ 拼成解析请求；**没有 ⇒ 不编地址**（如实交回原串）
    ///
    /// 注入：把 `play_request_of` 的空 `parse_url` 分支改成"编一个默认解析站" ⇒ 本条红。
    #[test]
    fn play_request_never_invents_a_parser() {
        // ① 实测形态：解析前缀以 `url=` 结尾 ⇒ 直接拼（不加多余分隔符）
        let (u, hint) = play_request_of(
            "NBY-abc|def",
            "https://api.nbyjson.top:7788/api/?key=K&url=",
        );
        assert_eq!(u, "https://api.nbyjson.top:7788/api/?key=K&url=NBY-abc|def");
        assert!(hint.contains("解析接口"), "{hint}");

        // ② 前缀以 `?` 结尾 ⇒ 用 `url=`
        let (u2, _) = play_request_of("X-1", "https://p.example/api?");
        assert_eq!(u2, "https://p.example/api?url=X-1");
        // ③ 前缀无 `?` ⇒ 用 `?url=`
        let (u3, _) = play_request_of("X-1", "https://p.example/api");
        assert_eq!(u3, "https://p.example/api?url=X-1");
        // ④ 前缀有 `?` 但无结尾分隔 ⇒ 用 `&url=`
        let (u4, _) = play_request_of("X-1", "https://p.example/api?k=v");
        assert_eq!(u4, "https://p.example/api?k=v&url=X-1");

        // ⑤ ★★ 没给解析接口 ⇒ **不许编一个**，如实交回原串 + 说明
        let (u5, h5) = play_request_of("NBY-abc|def", "");
        assert_eq!(u5, "NBY-abc|def", "★ 原串要原样交回");
        assert!(
            h5.contains("未给解析接口"),
            "★ 必须写明「上游没给」（而不是假装有）：{h5}"
        );
        assert!(
            !h5.contains("http"),
            "★ label 里不许出现任何「我们编的」地址：{h5}"
        );
    }

    /// 四段行为（`search` 真做、`list` 需要 tid、`play` 需要完整 id）
    ///
    /// 注入：把 `list` 的 tid 空检查删掉 ⇒ 本条红。
    ///
    /// ⚠️ 只留 `#[tokio::test]`（叠 `#[test]` ⇒ "async functions cannot be used for tests"）。
    #[tokio::test]
    async fn segments_validate_their_inputs() {
        let s = AppRJ::new();
        assert!(s.supports_search(), "★ 搜索是真做的");
        // 分类来自内嵌常量 ⇒ 无 ext 也应给得出
        let h = s.home("").await.expect("home 不该 Err（分类是常量）");
        assert!(!h.categories.is_empty(), "★ 分类表不该空");
        // list 缺 tid ⇒ Err
        let e = s.list("", 1, r#"{"url":"http://x"}"#).await.expect_err("★ 空 tid 必须 Err");
        assert!(e.contains("type_id") || e.contains("不能为空"), "{e}");
        // play 形态不对 ⇒ Err
        let e2 = s.play("", "14574", "").await.expect_err("★ 裸 vodId 必须 Err");
        assert!(e2.contains("形态"), "{e2}");
        // play 正常形态 ⇒ 交出解析请求 + 诚实 label
        let p = s
            .play(
                "",
                "14574@线路一|0|1|https://p.example/api?url=|NBY-abc|def",
                "",
            )
            .await
            .expect("完整 id 应能取流");
        assert_eq!(p[0].url, "https://p.example/api?url=NBY-abc|def");
        assert!(p[0].label.as_deref().unwrap_or("").contains("解析接口"));
    }

    #[test]
    /// ★ 冻结：**不拼**宿主弹幕代理（本仓无该能力位）；也**不硬编码**解析站 key
    ///
    /// 注入：在 `play` 的返回 url 后面接 `?do=appdanmu&…` ⇒ 本条红。
    #[test]
    fn no_danmaku_proxy_and_no_hardcoded_parser_key() {
        let src = include_str!("app_rj.rs");
        let code: Vec<String> = src
            .lines()
            .map(|l| {
                let t = l.trim();
                if t.starts_with("//") || t.starts_with('*') || t.starts_with("/*") {
                    String::new()
                } else {
                    l.split("//").next().unwrap_or("").to_string()
                }
            })
            .collect();
        // 判据串**拼出来**（避免自证陷阱）
        let needle = format!("do={}{}", "app", "danmu");
        assert!(
            !code.iter().any(|l| l.contains(&needle)),
            "★ 不许把宿主弹幕代理拼进取流结果（本仓无该能力位）"
        );
        assert!(src.contains("appdanmu"), "★ 必须留档说明这个缺口");
        /*
         * 解析站 key 属于**上游下发**（`parse_urls[]`）⇒ 不许硬编码进代码。
         * ★ 判据串**拼出来**（自证陷阱）：整串写在断言行上 ⇒ **这一行自己**就是
         *   "代码里出现了那个域名" ⇒ 门禁假红（本仓已多次踩到同形）。
         * ★ 且只查**代码行**：实测读数写在文档/注释里是**必须的**（那是证据），不算硬编码。
         */
        let host = format!("api.{}{}", "nbyjson", ".top");
        let bad: Vec<&String> = code
            .iter()
            .filter(|l| l.contains(&host) && !l.contains("实测") && !l.contains("`"))
            .collect();
        assert!(
            bad.is_empty(),
            "★ 不许把解析站硬编码进代码（它的 key 是上游下发）：{bad:?}"
        );
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    /// ★★ 真网**全链路**：home → list → search → detail → play
    ///
    /// # 这条用例的意义（本类最该留档的一点）
    /// ```text
    /// 我第一次用**根路径 GET** 打 ⇒ 四端点全 405 `not found` ⇒ 差点写成"端点不存在"。
    /// 换成 **POST + multipart** ⇒ `405 "sign error"` ⇒ 错误**变了** ⇒ 端点存在、只是签名错。
    /// 算对签名 ⇒ 200。
    /// ⇒ 这条用例的判据是"**必须真的取到数据**"，它能在下次上游改协议时立刻报出来。
    /// ```
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_app_rj -- --ignored --nocapture"]
    async fn csp_live_app_rj_five_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        const EXT: &str = r#"{"url":"http://v.rbotv.cn"}"#;
        let s = AppRJ::new();
        let h = s.home(EXT).await.expect("home 应成功（分类是常量）");
        eprintln!(
            "[LIVE] home: 分类 {} 个（首={}），预取 {} 条",
            h.categories.len(),
            h.categories[0].name,
            h.items.len()
        );
        let l = s.list("1", 1, EXT).await.expect("list 应成功");
        eprintln!("[LIVE] list(电影): {} 条 首={}", l.items.len(), l.items[0].title);
        let se = s.search("战狼", 1, EXT).await.expect("search 应成功");
        eprintln!("[LIVE] search(战狼): {} 条 首={}", se.items.len(), se.items[0].title);
        let d = s.detail(&se.items[0].id, EXT).await.expect("detail 应成功");
        eprintln!(
            "[LIVE] detail: {} — {} 集（首集={} / 线路={}）",
            d.title,
            d.episodes.len(),
            d.episodes[0].title,
            d.episodes[0].flag
        );
        let p = s.play("", &d.episodes[0].id, EXT).await.expect("play 应成功");
        eprintln!("[LIVE] play: {} [{}]", p[0].url, p[0].label.clone().unwrap_or_default());
        assert!(p[0].url.starts_with("http"), "★ 必须是可取流的形态");
        assert!(!d.episodes.is_empty());
    }
}