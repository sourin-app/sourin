// ═══════════════════════════════════════════════════════════════════════
//  csp_Sou4K —— TVBox `csp_Sou4K` 的 Rust 重写（纯 HTTP-JSON）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅 8815.kstore.vip/tvbox/wmz 的 💯搜4K丨网盘资源：
//   {"type":3, "api":"csp_Sou4K", "ext": null}
// ⇒ ext 为 null ⇒ base 写死（DEX 常量逐字：`https://sou4k.com`）。
// ```
//
// # 协议取证（`.probe/decompiled/classes.dex` 直读，**未起 jadx**）
//
// 依据：`.probe/r3-c-strings.json` 里 `Sou4K` 的 129 条 const-string。
// 类：`com.github.catvod.spider.Sou4K`，父类 `spider.Pan`，20 方法 4 字段。
//
// ```text
// 请求头（DEX 逐字，head() 里的三条）
//   User-Agent: Mozilla/5.0 … Chrome/151.0.0.0 Safari/537.36
//   Referer   : https://sou4k.com/
//   Accept    : application/json, text/plain, */*
// 搜索     https://sou4k.com/api/search?q=<kw>&page=1&page_size=100&_t=
//          响应 success / data.total / data.page / data.page_size / data.results[]
//          项内：title · type(cloud|magnet) · size · source · disk_type · share_url · pwd
//          ★ `share_url` 是**加密串**（不是真链接）
// 解析     https://sou4k.com/api/check-links   (POST, application/json)
//          请求体 {"items":[{"share_url":…,"disk_type":…,"pwd":…}]}
//          响应 success / enabled / results[] / error
//          项内：disk_type · url · normalized_url · state · summary · enc_share_url
//          ★ `url` 是**解出来的真网盘分享链接**（见下真读数）
// 排行     /api/recommend/high_score|classic_tv|short
//          DEX 常量成对给出：high_score→"电影排行" · classic_tv→"剧集排行" · short→"短剧排行"
//          响应 success / data[]
// 图标     icon() 按 disk_type 映射 8 张图（aliyun/quark/uc/baidu/xunlei/tianyi/123/mobile）
//          分别对应 51shazhu / pic7.fukit 图床
// ```
//
// # ★★ 四处"DEX 常量 ≠ 真站点"（**实测校正，全部有读数**）
//
// ```text
// ① 分类名：DEX 常量只有 3 个排行 key（high_score/classic_tv/short）
//    【实测】它们是**可用的分类 id**，返回**榜单数据**而不是搜索结果：
//      /api/recommend/high_score  → 200 · 1149442 B · data[]（tmdb_id/title/original_title/overview…）
//      /api/recommend/classic_tv  → 200 ·  209357 B · data[]（douban_id/title/media_type/category…）
//      /api/recommend/short       → 200 ·  108194 B · data[]（title/share_url/poster_url…）
//    ⇒ 三个都**真能出数据**，所以首页分类就用它们（名字取自 DEX 常量）。
//
// ② 请求字段名：DEX 常量里写 `items` + `enc_share_url`
//    【实测】`enc_share_url` 当**请求**字段时返回空 results；
//      真正被接受的是 **`share_url`**：
//        {"items":[{"enc_share_url":…}]} → 200 · {"success":true,"enabled":true,"results":[]}  ← 空
//        {"items":[{"share_url":…}]}     → 200 · results[] **有数据**                        ← 真形态
//      （`enc_share_url` 是**响应**里的字段名 —— 同一个键在两个方向名字不同，很易踩）
//      ★ 另外 {"items":["<串>"]}（纯字符串数组）会 **422 Unprocessable Entity** ⇒ 必须对象数组。
//
// ③ 加密/解密是**服务端**做的：`share_url`（加密）→ POST check-links → `url`（真链接）
//    实测：
//      入 {"share_url":"YgnciU9NhbqNUW3Kc_wDCOE-g4IiOhNm5WPGGqmjD_5sG5k=","disk_type":"quark"}
//      出 {"disk_type":"quark","url":"https://pan.quark.cn/s/57cb167ddff1",
//          "normalized_url":"https://pan.quark.cn/s/57cb167ddff1","state":"ok",
//          "summary":"链接有效","enc_share_url":"YgnciU9NhbqNUW3Kc_wDCOE-g4IiOhNm5WPGGqmjD_5sG5k="}
//      百度那条：{"disk_type":"baidu","url":"https://pan.baidu.com/s/1Njb1UGSd1T06255cmc37aA?pwd=8888",
//                 "state":"uncertain"}
//    ⇒ **必须走这个 POST 才能拿到可点链接**；直接把 `share_url` 当链接用是错的。
//
// ④ 搜索分页：DEX 模板 `&page=1&page_size=100&_t=`（写死 page=1）
//    【实测】`&page=2` 真能翻页：data.total=470，page=2 返回 100 条且**首条与第 1 页不同**
//    ⇒ 本实现**用 page 参数**（DEX 写死 1 是它的选择，我们按真站点能力做）。
// ```
//
// # 真网络读数（2026-10-27 实测）
//
// ```text
// GET  /api/search?q=红&page=1&page_size=100&_t=1  → 200 · 26191 B · data.total=470 · results 100 条
//      types 分布：cloud 99 / magnet 1          ← ★ 结果里**混磁力链接**（DEX 里也有 `magnet` 语义）
//      r0 = {"title":"红皇后","type":"cloud","disk_type":"uc","share_url":"YgnciU9Nhbq…","pwd":""}
// GET  /api/search?q=红&page=2&…                   → 200 · 59817 B · 首条"小城良方 (2026)…"（≠ 第 1 页首条）
// POST /api/check-links {"items":[{"share_url":…,"disk_type":"quark"}]}
//      → 200 · results[0].url = https://pan.quark.cn/s/57cb167ddff1 · state=ok · summary="链接有效"
// POST /api/check-links 百度那条 → url = https://pan.baidu.com/s/1Njb1UGSd1T06255cmc37aA?pwd=8888 · state=uncertain
// GET  /api/recommend/high_score  → 200 · 1149442 B · data[]  (电影排行)
// GET  /api/recommend/classic_tv  → 200 ·  209357 B · data[]  (剧集排行)
// GET  /api/recommend/short       → 200 ·  108194 B · data[]  (短剧排行)
// ```
//
// # ★ 关于 `state` 字段（如实处理，不许一律当成功）
//
// ```text
// 实测见到 `state` 至少两种值：`ok`（"链接有效"）与 `uncertain`（不确定）。
// ⇒ 本实现**原样保留**这个状态并放进线路名（如"夸克网盘·链接有效" /
//   "百度网盘·uncertain"），**不把 uncertain 谎报成有效**。
// ```
//
// # 契约边界（Lead 已裁定）
//
// ```text
// · loadPic   ⇒ 本类封面走图床（51shazhu/fukit），不需额外头 ⇒ 不写 cover_headers
// · mProxy    ⇒ ★ **已知缺口**：原版有代理能力，本批不做。
// · initApi   ⇒ 本仓无该 API；等价物是 `ext`（本类 ext 为 null，不影响）
// · isVideoFormat / manualVideoCheck
//             ⇒ ★ DEX 里 Sou4K **没有** override 这两个（20 个方法里没有）
//                ⇒ **本仓无等价位，未实现**（如实登记，不臆造）
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 站点唯一域名（DEX 常量逐字）
pub const BASE: &str = "https://sou4k.com";

/// DEX 里逐字给出的 UA
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
/// DEX 里逐字给出的 Referer
const REFERER: &str = "https://sou4k.com/";
/// DEX 里逐字给出的 Accept
const ACCEPT: &str = "application/json, text/plain, */*";

/// 搜索每页条数（DEX 模板 `&page_size=100`）
pub const SEARCH_PAGE_SIZE: u32 = 100;

const GET_TIMEOUT: Duration = Duration::from_secs(20);

pub struct Sou4K {
    client: super::http_context::CspHttpContext,
}

impl Sou4K {
    pub const CLASS: &'static str = "Sou4K";

    /// 首页分类 —— 3 个排行 key 与名**成对来自 DEX 常量**（且实测都真出数据）
    ///
    /// ```text
    /// DEX 常量：'high_score' 'classic_tv' 'short' '电影排行' '剧集排行' '短剧排行'
    /// 实测三端点均 200 且 data[] 非空 ⇒ 这是**当前可用**的 3 个分类。
    /// ```
    /// ⚠️ 真站点还有**搜索**能力（`/api/search`），但搜索不是"分类"⇒ 不列进分类条。
    pub const CATEGORIES: &'static [(&'static str, &'static str)] = &[
        ("high_score", "电影排行"),
        ("classic_tv", "剧集排行"),
        ("short", "短剧排行"),
    ];

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| reqwest::Client::builder()
            .user_agent(UA)
            .timeout(GET_TIMEOUT)
            // Unbound sites remain direct; the context applies the current app policy.
            .no_proxy()
        );
        Self { client }
    }

    async fn get_json(&self, url: &str) -> Result<serde_json::Value, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header(reqwest::header::REFERER, REFERER)
            .header(reqwest::header::ACCEPT, ACCEPT)
            .send()
            .await
            .map_err(|e| format!("请求 {url} 失败：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取 {url} 响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "{url} 返回 HTTP {status}；响应前 200 字节：{}",
                truncate(&body, 200)
            ));
        }
        serde_json::from_str(&body).map_err(|e| {
            format!(
                "{url} 不是合法 JSON：{e}；响应前 200 字节：{}",
                truncate(&body, 200)
            )
        })
    }

    /// POST `/api/check-links`：把加密的 `share_url` 解成真链接
    ///
    /// ★ 请求字段名是 `share_url`（**实测**），不是 DEX 常量里那个 `enc_share_url`（见文件头②）
    async fn post_check_links(
        &self,
        items: &[(String, String, String)],
    ) -> Result<serde_json::Value, String> {
        let url = format!("{BASE}/api/check-links");
        self.post_check_links_url(&url, items).await
    }

    async fn post_check_links_url(
        &self,
        url: &str,
        items: &[(String, String, String)],
    ) -> Result<serde_json::Value, String> {
        let body = serde_json::json!({
            "items": items
                .iter()
                .map(|(share_url, disk_type, pwd)| serde_json::json!({
                    "share_url": share_url,
                    "disk_type": disk_type,
                    "pwd": pwd,
                }))
                .collect::<Vec<_>>()
        });
        let resp = self
            .client
            .client()?
            .post(url)
            .header(reqwest::header::REFERER, REFERER)
            .header(reqwest::header::ACCEPT, ACCEPT)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(body.to_string())
            .send()
            .await
            .map_err(|e| format!("POST {url} 失败：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取 POST {url} 响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "POST {url} 返回 HTTP {status}；响应前 200 字节：{}",
                truncate(&text, 200)
            ));
        }
        serde_json::from_str(&text).map_err(|e| {
            format!(
                "POST {url} 不是合法 JSON：{e}；响应前 200 字节：{}",
                truncate(&text, 200)
            )
        })
    }
}

impl Default for Sou4K {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数（hermetic 可测）
// ═══════════════════════════════════════════════════════════════════════

fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// 搜索 URL（**实测**：page 可翻页；DEX 模板把 page 写死成 1）
pub fn search_url(base: &str, kw: &str, page: u32) -> String {
    let page = if page == 0 { 1 } else { page };
    format!(
        "{base}/api/search?q={}&page={page}&page_size={SEARCH_PAGE_SIZE}&_t=1",
        urlencode(kw)
    )
}

/// 排行 URL（DEX 常量成对给出的三个 key）
pub fn recommend_url(base: &str, key: &str, page: u32) -> String {
    let page = if page == 0 { 1 } else { page };
    format!("{base}/api/recommend/{key}?page={page}&page_size=20")
}

/// 最小百分号编码（本仓"不新增运行时依赖"）
pub fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 搜索结果项（保留加密的 share_url，供后续 check-links）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sou4KRow {
    pub title: String,
    pub share_url: String,
    pub disk_type: String,
    pub pwd: String,
    pub kind: String,
}

/// 解析 `/api/search` 响应
///
/// # 为什么保留 `type`（cloud / magnet）
/// ```text
/// 实测 100 条里 99 条 `cloud` + **1 条 `magnet`** ⇒ 结果集是**混合**的。
/// 磁力链接的 `share_url` **本身就是可用地址**（`magnet:?xt=…`），
/// 不能送去 check-links（那是网盘链接解析器）⇒ 必须分流。
/// ```
pub fn parse_search(v: &serde_json::Value, page: u32) -> Result<CspList, String> {
    if v.get("success").and_then(|s| s.as_bool()) != Some(true) {
        return Err(format!(
            "搜索响应 success 不是 true：{}",
            truncate(&v.to_string(), 200)
        ));
    }
    let data = v
        .get("data")
        .ok_or_else(|| format!("搜索响应没有 data：{}", truncate(&v.to_string(), 200)))?;
    let results = data
        .get("results")
        .and_then(|r| r.as_array())
        .ok_or_else(|| format!("data 里没有 results 数组：{}", truncate(&data.to_string(), 200)))?;

    let mut items = Vec::with_capacity(results.len());
    for row in results {
        let Some(share) = row.get("share_url").and_then(|s| s.as_str()) else {
            continue;
        };
        if share.is_empty() {
            continue;
        }
        let title = row
            .get("title")
            .and_then(|t| t.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("（上游未给标题）")
            .to_string();
        let disk = row
            .get("disk_type")
            .and_then(|d| d.as_str())
            .unwrap_or("")
            .to_string();
        let source = row.get("source").and_then(|s| s.as_str()).unwrap_or("");
        let kind = row.get("type").and_then(|t| t.as_str()).unwrap_or("cloud");
        // id 用 `disk_type + \u{1} + share_url` 两段拼 —— 后续 detail 要按类型分流
        items.push(CspItem {
            id: format!("{kind}\u{1}{disk}\u{1}{share}"),
            title,
            cover: None,
            subtitle: if source.is_empty() {
                None
            } else {
                Some(source.to_string())
            },
        });
    }

    // ★ 反空真（铁律 149）：results 非空却一条都映射不出 ⇒ 结构变了
    if items.is_empty() && !results.is_empty() {
        return Err(format!(
            "results 有 {} 条但都取不到 share_url ⇒ 上游字段结构可能变了：{}",
            results.len(),
            truncate(&results[0].to_string(), 200)
        ));
    }

    Ok(CspList {
        items,
        page,
        // 上游给 total / page_size，但**没给总页数** ⇒ 按总数与页大小算（可算得出，不算猜）
        page_count: match (
            data.get("total").and_then(|t| t.as_u64()),
            data.get("page_size").and_then(|p| p.as_u64()),
        ) {
            (Some(total), Some(ps)) if ps > 0 => {
                Some(((total + ps - 1) / ps).min(u32::MAX as u64) as u32)
            }
            _ => None,
        },
        total: data.get("total").and_then(|t| t.as_u64()),
    })
}

/// 解析 `/api/recommend/<key>` 响应（榜单）
///
/// # 榜单项的字段与搜索**不同**（实测）
/// ```text
/// high_score : tmdb_id / title / original_title / overview / …
/// classic_tv : douban_id / title / media_type / category / …
/// short      : title / share_url / poster_url / …
/// ⇒ **没有统一的 id 字段**。这里用"第一个存在的 id 类字段"（tmdb_id/douban_id/id）
///   作为条目 id；`short` 那类直接带 `share_url`（**是明文链接**，不是加密串）⇒ 用它当 id。
/// ★ 若某个榜单项**两种都没有** ⇒ 跳过该条（不塞假 id），并在整批都取不到时报结构问题。
/// ```
pub fn parse_recommend(v: &serde_json::Value, page: u32) -> Result<CspList, String> {
    if v.get("success").and_then(|s| s.as_bool()) != Some(true) {
        return Err(format!(
            "榜单响应 success 不是 true：{}",
            truncate(&v.to_string(), 200)
        ));
    }
    let data = v
        .get("data")
        .and_then(|d| d.as_array())
        .ok_or_else(|| format!("榜单响应没有 data 数组：{}", truncate(&v.to_string(), 200)))?;

    let mut items = Vec::with_capacity(data.len());
    for row in data {
        let title = row
            .get("title")
            .and_then(|t| t.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("")
            .to_string();
        if title.is_empty() {
            continue;
        }
        // 优先取明文 share_url（short 榜单形态），否则取数字 id
        let id = if let Some(su) = row
            .get("share_url")
            .and_then(|s| s.as_str())
            .filter(|s| s.starts_with("http"))
        {
            format!("link\u{1}{su}")
        } else if let Some(n) = ["tmdb_id", "douban_id", "id"]
            .iter()
            .find_map(|k| row.get(*k))
            .and_then(|n| n.as_str().map(|s| s.to_string()).or_else(|| n.as_u64().map(|u| u.to_string())))
        {
            format!("meta\u{1}{n}")
        } else {
            continue; // 没有可用 id ⇒ 跳过（不塞假 id）
        };
        let cover = row
            .get("poster_url")
            .or_else(|| row.get("cover"))
            .or_else(|| row.get("poster"))
            .and_then(|c| c.as_str())
            .filter(|s| !s.is_empty() && s.starts_with("http"))
            .map(|s| s.to_string());
        let subtitle = row
            .get("category")
            .or_else(|| row.get("media_type"))
            .or_else(|| row.get("original_title"))
            .and_then(|x| x.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string());
        items.push(CspItem {
            id,
            title,
            cover,
            subtitle,
        });
    }

    // ★ 反空真：data 非空却一条都建不出来 ⇒ 结构变了
    if items.is_empty() && !data.is_empty() {
        return Err(format!(
            "榜单 data 有 {} 条但都取不到 id/标题 ⇒ 上游字段结构可能变了：{}",
            data.len(),
            truncate(&data[0].to_string(), 200)
        ));
    }

    Ok(CspList {
        items,
        page,
        page_count: None,
        total: None,
    })
}

/// 解析 `/api/check-links` 响应 → 可点线路
///
/// # `state` 必须**原样保留**（见文件头"关于 state 字段"）
/// ```text
/// 实测 state ∈ {ok, uncertain}。
/// ⇒ 线路名里带上它（如"夸克网盘·链接有效" / "百度网盘·uncertain"），
///   **不把 uncertain 谎报成有效**。
/// ```
pub fn parse_check_links(v: &serde_json::Value) -> Result<Vec<CspPlay>, String> {
    if v.get("success").and_then(|s| s.as_bool()) != Some(true) {
        return Err(format!(
            "check-links 响应 success 不是 true：{}",
            truncate(&v.to_string(), 200)
        ));
    }
    let results = v
        .get("results")
        .and_then(|r| r.as_array())
        .ok_or_else(|| format!("check-links 响应没有 results：{}", truncate(&v.to_string(), 200)))?;

    let mut plays = Vec::new();
    for row in results {
        let Some(url) = row.get("url").and_then(|u| u.as_str()).filter(|s| !s.is_empty()) else {
            continue; // 没有解出 url ⇒ 这条不可点（不塞假链接）
        };
        let disk = row.get("disk_type").and_then(|d| d.as_str()).unwrap_or("网盘");
        let label_name = disk_label(disk);
        let state = row.get("state").and_then(|s| s.as_str()).unwrap_or("");
        let summary = row.get("summary").and_then(|s| s.as_str()).unwrap_or("");
        // ★ 状态如实进线路名（ok→"链接有效"是上游文案；uncertain→原样标出）
        let label = match (state, summary.is_empty()) {
            ("ok", false) => format!("{label_name}·{summary}"),
            ("ok", true) => format!("{label_name}·链接有效"),
            ("", _) => format!("{label_name}·{summary}"),
            (other, _) => format!("{label_name}·{other}"),
        };
        plays.push(CspPlay {
            url: url.to_string(),
            headers: Vec::new(),
            label: Some(label),
        });
    }

    /*
     * ★ 反空真 ①：**results 非空但一条 url 都没有** ⇒ 结构变了（我们的问题）
     * ★ 与"results 本来就是空"区分开：后者是**上游没解出**（合法结果，
     *   例如它也可能因为缓存冷/链接被删而给空）—— 那种情况返回 Err 也不合适，
     *   但**静默给空线路**同样不行 ⇒ 交给调用方按"空线路"处理。
     */
    if plays.is_empty() && !results.is_empty() {
        return Err(format!(
            "check-links 有 {} 条结果但都缺 url ⇒ 上游字段结构可能变了：{}",
            results.len(),
            truncate(&results[0].to_string(), 200)
        ));
    }
    Ok(plays)
}

/// disk_type → 中文名（**取自 DEX 的 icon() 映射键**）
pub fn disk_label(disk_type: &str) -> &'static str {
    match disk_type {
        "quark" => "夸克网盘",
        "uc" => "UC网盘",
        "baidu" => "百度网盘",
        "aliyun" => "阿里云盘",
        "xunlei" => "迅雷云盘",
        "tianyi" => "天翼云盘",
        "123" => "123网盘",
        "mobile" => "移动云盘",
        _ => "网盘",
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Sou4K {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let categories = Self::CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        let first = Self::CATEGORIES[0].0;
        let v = self.get_json(&recommend_url(BASE, first, 1)).await?;
        let items = parse_recommend(&v, 1)?.items;
        Ok(CspHome { categories, items })
    }

    /// 分类列表：`tid` 是排行 key（high_score / classic_tv / short）
    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        // 只放行 DEX 常量里给出的三个 key（显式拒绝拼进 URL 的任意串）
        if !Self::CATEGORIES.iter().any(|(k, _)| *k == tid) {
            return Err(format!(
                "未知分类 id：{tid}（DEX 常量只有 high_score / classic_tv / short）"
            ));
        }
        let page = if page == 0 { 1 } else { page };
        let v = self.get_json(&recommend_url(BASE, tid, page)).await?;
        parse_recommend(&v, page)
    }

    /// 详情：把列表项带的加密 `share_url` 送去 check-links 解成真链接
    ///
    /// # id 编码（见 `parse_search` / `parse_recommend`）
    /// ```text
    /// · 搜索来的：`<kind>\u{1}<disk>\u{1}<share_url>`   → 走 check-links
    /// · 榜单来的：`<"link">\u{1}<明文 http 链接>`        → 直接就是分享页
    ///             `<"meta">\u{1}<tmdb/douban id>`         → ★ 只有元数据 id，
    ///                 **没有可点链接** ⇒ 如实报错（不伪造）
    /// · 磁力：kind=magnet 且 share_url 本身是 `magnet:` ⇒ 直接可用
    /// ```
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let mut parts = id.split('\u{1}');
        let kind = parts.next().unwrap_or("");

        match kind {
            // ── 榜单的明文链接 ──
            "link" => {
                let url = parts.next().unwrap_or("");
                if !url.starts_with("http") {
                    return Err(format!("榜单链接 id 形态不对：{}", truncate(id, 120)));
                }
                Ok(CspDetail {
                    id: id.to_string(),
                    title: "（榜单条目）".to_string(),
                    cover: None,
                    description: None,
                    episodes: vec![CspEpisode {
                        id: url.to_string(),
                        title: "分享页".to_string(),
                        flag: "网盘".to_string(),
                    }],
                })
            }
            // ── 榜单只有元数据 id：没有可点链接 ⇒ 如实报错 ──
            "meta" => Err(format!(
                "这是榜单条目（元数据 id={}），上游未提供可点网盘链接 ⇒ 请改用搜索找该片",
                truncate(parts.next().unwrap_or(""), 60)
            )),
            // ── 磁力：share_url 本身就是可用地址 ──
            "magnet" => {
                let share = parts.next().unwrap_or("");
                let link = parts.next().unwrap_or("");
                let url = if link.starts_with("magnet:") {
                    link
                } else if share.starts_with("magnet:") {
                    share
                } else {
                    return Err("磁力条目的 share_url 不是 magnet: 开头".to_string());
                };
                Ok(CspDetail {
                    id: id.to_string(),
                    title: "（磁力）".to_string(),
                    cover: None,
                    description: None,
                    episodes: vec![CspEpisode {
                        id: url.to_string(),
                        title: "磁力链接".to_string(),
                        flag: "磁力".to_string(),
                    }],
                })
            }
            // ── 网盘（cloud）：走 check-links ──
            _ => {
                let disk = parts.next().unwrap_or("");
                let share = parts.next().unwrap_or("");
                if share.is_empty() {
                    return Err(format!("条目 id 里没有 share_url：{}", truncate(id, 120)));
                }
                let v = self
                    .post_check_links(&[(
                        share.to_string(),
                        disk.to_string(),
                        String::new(),
                    )])
                    .await?;
                let plays = parse_check_links(&v)?;
                if plays.is_empty() {
                    return Err(format!(
                        "上游 check-links 没解出可点链接（share_url={}）⇒ 可能已失效",
                        truncate(share, 60)
                    ));
                }
                Ok(CspDetail {
                    id: id.to_string(),
                    title: "（网盘资源）".to_string(),
                    cover: None,
                    description: Some(format!("来源：{}", disk_label(disk))),
                    episodes: plays
                        .into_iter()
                        .map(|p| CspEpisode {
                            id: p.url,
                            title: p.label.unwrap_or_else(|| "分享页".to_string()),
                            flag: "网盘".to_string(),
                        })
                        .collect(),
                })
            }
        }
    }

    /// 取流：本站是**网盘分享页 / 磁力链接**，如实返回并标注
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if id.starts_with("magnet:") {
            return Ok(vec![CspPlay {
                url: id.to_string(),
                headers: Vec::new(),
                label: Some("磁力链接（需下载器）".to_string()),
            }]);
        }
        if !(id.starts_with("http://") || id.starts_with("https://")) {
            return Err(format!("播放 id 不是 http(s)/magnet: 地址：{}", truncate(id, 120)));
        }
        Ok(vec![CspPlay {
            url: id.to_string(),
            headers: Vec::new(),
            label: Some("分享页（需网盘客户端/转发服务取直链）".to_string()),
        }])
    }

    /// DEX 里 Sou4K **有** searchContent（20 个方法里有它）⇒ 真支持搜索
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let v = self.get_json(&search_url(BASE, kw, page)).await?;
        parse_search(&v, page)
    }
}

// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
//
// # 这个类的事实（别丢）
// ```text
// csp_Sou4K（💯搜4K丨网盘资源）：★ 四处"常量 ≠ 真站点"
//   ① 三个排行 key 实测**真出数据**（high_score 1.1MB / classic_tv 209KB / short 108KB）
//   ② ★ 请求字段是 **share_url**，DEX 常量写的是 `enc_share_url`（那是**响应**字段名）
//        {"items":[{"enc_share_url":…}]} → results **空**
//        {"items":[{"share_url":…}]}     → results **有数据**
//        纯字符串数组 {"items":["<串>"]} → **422**
//   ③ 加密串→真链接**必须走 POST /api/check-links**（服务端解密）
//        实测 → https://pan.quark.cn/s/57cb167ddff1（state=ok）/
//               https://pan.baidu.com/s/1Njb1UGSd1T06255cmc37aA?pwd=8888（state=uncertain）
//   ④ 搜索分页真能翻页（total=470，page=2 首条 ≠ page=1 首条）
// ★ 结果集是**混合**的：99 cloud + 1 magnet（实测）⇒ 已按 kind 分流处理
// ★ `state` 原样进线路名（ok/uncertain 都如实），不把 uncertain 谎报成有效
// ⚠️ 已知缺口：原版有 mProxy，本批不做
// ⚠️ 榜单项若只有 tmdb_id/douban_id（无可点链接）⇒ detail **如实报错**，不伪造
// ```
crate::csp::register_site!(Sou4K);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
#[path = "sou4k_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实搜索响应片段（2026-10-27 实测，裁剪）
    const FIX_SEARCH: &str = r#"{
      "success": true,
      "data": {"total": 470, "page": 1, "page_size": 100,
        "results": [
          {"title": "红皇后", "type": "cloud", "size": "", "source": "UC 网盘",
           "disk_type": "uc", "share_url": "YgnciU9NhbqZQmqSZ6cXGaRzjsN-ZgVn5THFGf2tCv47SpzGTALI-ZRTPtU=", "pwd": ""},
          {"title": "[DBD-Raws][红战士…][01-12TV全集][1080P]", "type": "magnet", "size": "",
           "source": "磁力链接",
           "share_url": "magnet:?xt=urn:btih:49d6ed8a7c7939e40eab4429421bf5c8d6b77d47&dn=%5BDBD-Raws%5D"}
        ]},
      "cached": false
    }"#;

    /// 真实 check-links 响应片段（2026-10-27 实测，裁剪）
    const FIX_CHECK: &str = r#"{
      "success": true, "enabled": true,
      "results": [
        {"disk_type": "quark", "url": "https://pan.quark.cn/s/57cb167ddff1",
         "normalized_url": "https://pan.quark.cn/s/57cb167ddff1", "state": "ok",
         "cache_hit": false, "summary": "链接有效",
         "enc_share_url": "YgnciU9NhbqNUW3Kc_wDCOE-g4IiOhNm5WPGGqmjD_5sG5k="},
        {"disk_type": "baidu", "url": "https://pan.baidu.com/s/1Njb1UGSd1T06255cmc37aA?pwd=8888",
         "normalized_url": "https://pan.baidu.com/s/1Njb1UGSd1T06255cmc37aA?pwd=8888",
         "state": "uncertain", "cache_hit": false, "summary": ""}
      ]
    }"#;

    /// 真实榜单响应片段（短剧：带明文 share_url）
    const FIX_SHORT: &str = r#"{
      "success": true,
      "data": [
        {"title": "天归", "share_url": "https://hongguoduanju.com/detail?series_id=7409955156487310398",
         "poster_url": "https://img.example/tg.jpg"}
      ]
    }"#;

    /// 真实榜单响应片段（电影：只有 tmdb_id）
    const FIX_HIGH: &str = r#"{
      "success": true,
      "data": [
        {"tmdb_id": "1437696", "title": "故土", "original_title": "Ojczyzna",
         "overview": "改编灵感涉及…"}
      ]
    }"#;

    fn j(s: &str) -> serde_json::Value {
        serde_json::from_str(s).expect("夹具必须是合法 JSON")
    }

    // ── ★ 四处实测校正（判据钉住实测值）──

    #[test]
    /// ★ 排行榜 key 与名**成对来自 DEX 常量**
    fn categories_pair_keys_and_names_from_dex_constants() {
        assert_eq!(Sou4K::CATEGORIES.len(), 3);
        assert_eq!(Sou4K::CATEGORIES[0], ("high_score", "电影排行"));
        assert_eq!(Sou4K::CATEGORIES[1], ("classic_tv", "剧集排行"));
        assert_eq!(Sou4K::CATEGORIES[2], ("short", "短剧排行"));
    }

    #[test]
    /// ★ 搜索分页用 `page` 参数（DEX 模板写死 1；实测真能翻页）
    ///
    /// 注入：把 `search_url` 里的 `page` 写死成 1 ⇒ 本条红。
    fn search_url_uses_real_page_param() {
        assert!(search_url(BASE, "红", 1).contains("&page=1&"));
        assert!(search_url(BASE, "红", 2).contains("&page=2&"), "★ 实测 page=2 真能翻页");
        assert_eq!(search_url(BASE, "红", 0), search_url(BASE, "红", 1), "page=0 归一成 1");
    }

    #[test]
    /// ★★ 请求字段必须是 `share_url`（不是 DEX 常量写的 `enc_share_url`）
    ///
    /// 这条用**夹具**证明字段名敏感：只有 `share_url` 才被解析出来。
    /// 注入：把 `parse_search` 读的键改成 `enc_share_url` ⇒ 本条红。
    fn search_reads_share_url_field() {
        let l = parse_search(&j(FIX_SEARCH), 1).expect("真响应必须解析得出来");
        let id = &l.items[0].id;
        assert!(
            id.contains("YgnciU9NhbqZQmqSZ6cXGaRzjsN-ZgVn5THFGf2tCv47SpzGTALI-ZRTPtU="),
            "★ 必须从 share_url 取值（enc_share_url 是响应字段名，不是请求字段名）：{id}"
        );
    }

    #[test]
    /// ★ 结果集是混合的（cloud + magnet）⇒ 分流处理，不混为一谈
    fn search_separates_cloud_and_magnet() {
        let l = parse_search(&j(FIX_SEARCH), 1).unwrap();
        assert_eq!(l.items.len(), 2);
        assert!(l.items[0].id.starts_with("cloud\u{1}uc\u{1}"), "{:?}", l.items[0].id);
        assert!(
            l.items[1].id.starts_with("magnet\u{1}"),
            "★ 磁力条目的 kind 必须是 magnet（后面 detail 要分流）：{:?}",
            l.items[1].id
        );
    }

    #[test]
    fn search_total_and_computed_page_count() {
        let l = parse_search(&j(FIX_SEARCH), 1).unwrap();
        assert_eq!(l.total, Some(470));
        // 470 条 / 每页 100 ⇒ 5 页（这是**算出来的**，不是猜的：上游给了 total+page_size）
        assert_eq!(l.page_count, Some(5), "470/100 向上取整 = 5");
    }

    // ── parse_search 反空真 ──────────────────────────────────────

    #[test]
    /// ★ 反空真 ①：results 非空却都取不到 share_url ⇒ 报错
    ///
    /// 注入：删掉 `parse_search` 里那个 `items.is_empty() && !results.is_empty()` ⇒ 本条红。
    fn search_with_unmappable_rows_is_error() {
        let bad = j(r#"{"success":true,"data":{"total":1,"page":1,"page_size":100,
            "results":[{"title":"无 share_url 的条目"}]}}"#);
        let err = parse_search(&bad, 1).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// ★ 反空真 ②（成对）：results **本来就是空数组** ⇒ 正常（没搜到）
    fn search_with_genuinely_empty_results_is_ok_empty() {
        let v = j(r#"{"success":true,"data":{"total":0,"page":1,"page_size":100,"results":[]}}"#);
        let l = parse_search(&v, 1).expect("真·没搜到不是错误");
        assert!(l.items.is_empty());
        assert_eq!(l.total, Some(0));
    }

    #[test]
    fn search_with_success_false_is_error() {
        let err = parse_search(&j(r#"{"success":false,"data":{}}"#), 1).unwrap_err();
        assert!(err.contains("success 不是 true"), "{err}");
    }

    #[test]
    fn search_without_results_is_error() {
        let err = parse_search(&j(r#"{"success":true,"data":{"total":0}}"#), 1).unwrap_err();
        assert!(err.contains("没有 results"), "{err}");
    }

    // ── parse_check_links ────────────────────────────────────────

    #[test]
    /// ★ 真链接来自 `url` 字段，且 `state` 原样保留
    fn check_links_maps_url_and_keeps_state() {
        let plays = parse_check_links(&j(FIX_CHECK)).expect("真响应必须解析得出来");
        assert_eq!(plays.len(), 2);
        assert_eq!(plays[0].url, "https://pan.quark.cn/s/57cb167ddff1");
        assert_eq!(
            plays[0].label.as_deref(),
            Some("夸克网盘·链接有效"),
            "ok 状态 + summary 都要进线路名"
        );
        assert_eq!(plays[1].url, "https://pan.baidu.com/s/1Njb1UGSd1T06255cmc37aA?pwd=8888");
        let l1 = plays[1].label.clone().unwrap_or_default();
        assert!(
            l1.contains("uncertain"),
            "★ uncertain 必须如实标出，不许谎报成有效：{l1}"
        );
    }

    #[test]
    /// ★ 反空真 ③：results 非空却都缺 url ⇒ 报错
    fn check_links_with_results_but_no_url_is_error() {
        let bad = j(r#"{"success":true,"results":[{"disk_type":"quark","state":"ok"}]}"#);
        let err = parse_check_links(&bad).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// ★ 反空真 ④（成对）：results **本来就是空** ⇒ 正常返回空线路（上游没解出）
    fn check_links_with_empty_results_is_ok_empty() {
        let v = j(r#"{"success":true,"enabled":true,"results":[]}"#);
        let plays = parse_check_links(&v).expect("上游没解出不等于结构变了");
        assert!(plays.is_empty());
    }

    // ── parse_recommend ──────────────────────────────────────────

    #[test]
    fn recommend_short_uses_plain_share_url() {
        let l = parse_recommend(&j(FIX_SHORT), 1).expect("真响应必须解析得出来");
        assert_eq!(l.items.len(), 1);
        assert!(l.items[0].id.starts_with("link\u{1}https://"), "{:?}", l.items[0].id);
        assert_eq!(l.items[0].title, "天归");
    }

    #[test]
    fn recommend_high_score_uses_tmdb_id() {
        let l = parse_recommend(&j(FIX_HIGH), 1).unwrap();
        assert_eq!(l.items.len(), 1);
        assert_eq!(l.items[0].id, "meta\u{1}1437696");
        assert_eq!(l.items[0].title, "故土");
        assert_eq!(l.items[0].subtitle.as_deref(), Some("Ojczyzna"));
    }

    #[test]
    /// ★ 反空真 ⑤：榜单 data 非空却既无 share_url 又无 id ⇒ 报错
    fn recommend_with_unmappable_rows_is_error() {
        let bad = j(r#"{"success":true,"data":[{"title":"某片"}]}"#);
        let err = parse_recommend(&bad, 1).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// ★ 反空真 ⑥（成对）：榜单 data 真空 ⇒ 正常空
    fn recommend_with_genuinely_empty_data_is_ok_empty() {
        let v = j(r#"{"success":true,"data":[]}"#);
        let l = parse_recommend(&v, 1).expect("真·空榜单不是错误");
        assert!(l.items.is_empty());
    }

    // ── disk_label ───────────────────────────────────────────────

    #[test]
    /// 8 个 disk_type 映射**来自 DEX 的 icon() 键**
    fn disk_labels_cover_dex_icon_keys() {
        for (k, want) in [
            ("quark", "夸克网盘"),
            ("uc", "UC网盘"),
            ("baidu", "百度网盘"),
            ("aliyun", "阿里云盘"),
            ("xunlei", "迅雷云盘"),
            ("tianyi", "天翼云盘"),
            ("123", "123网盘"),
            ("mobile", "移动云盘"),
        ] {
            assert_eq!(disk_label(k), want, "disk_type={k}");
        }
        assert_eq!(disk_label("unknown"), "网盘", "未知类型要有兜底名");
    }

    // ── detail 分流 ──────────────────────────────────────────────

    #[tokio::test]
    /// ★ 榜单 `meta` 条目**如实报错**（无可用链接，不伪造）
    async fn detail_meta_only_reports_honestly() {
        let err = Sou4K::new().detail("meta\u{1}1437696", "").await.unwrap_err();
        assert!(err.contains("未提供可点网盘链接"), "{err}");
    }

    #[tokio::test]
    /// ★ 磁力条目直接用 `magnet:`（不送 check-links）
    async fn detail_magnet_uses_link_directly() {
        let d = Sou4K::new()
            .detail("magnet\u{1}\u{1}magnet:?xt=urn:btih:abc", "")
            .await
            .expect("磁力必须可用");
        assert_eq!(d.episodes.len(), 1);
        assert!(d.episodes[0].id.starts_with("magnet:"), "{:?}", d.episodes[0].id);
        assert_eq!(d.episodes[0].flag, "磁力");
    }

    #[tokio::test]
    async fn detail_link_kind_uses_plain_url() {
        let d = Sou4K::new()
            .detail("link\u{1}https://hongguoduanju.com/detail?series_id=1", "")
            .await
            .expect("榜单链接必须可用");
        assert_eq!(d.episodes[0].id, "https://hongguoduanju.com/detail?series_id=1");
    }

    #[tokio::test]
    async fn empty_id_fails() {
        let err = Sou4K::new().detail("   ", "").await.unwrap_err();
        assert!(err.contains("条目 id 为空"), "{err}");
    }

    // ── 边界 / 能力位 ─────────────────────────────────────────────

    #[test]
    fn search_is_declared_supported() {
        assert!(Sou4K::new().supports_search(), "★ DEX 里 Sou4K 有 searchContent");
    }

    #[tokio::test]
    async fn empty_kw_fails_instead_of_silent_all() {
        let err = Sou4K::new().search("  ", 1, "").await.unwrap_err();
        assert!(err.contains("搜索词为空"), "{err}");
    }

    #[tokio::test]
    /// ★ 未知分类 id 显式拒绝（不许拼进 URL）
    async fn unknown_category_is_rejected() {
        let err = Sou4K::new().list("../../etc", 1, "").await.unwrap_err();
        assert!(err.contains("未知分类 id"), "{err}");
    }

    #[tokio::test]
    async fn play_returns_share_page_with_honest_label() {
        let url = "https://pan.quark.cn/s/57cb167ddff1";
        let plays = Sou4K::new().play("网盘", url, "").await.expect("分享页必须返回");
        assert_eq!(plays[0].url, url);
        assert!(plays[0].label.as_deref().unwrap_or("").contains("分享页"));
    }

    #[tokio::test]
    async fn play_handles_magnet() {
        let plays = Sou4K::new()
            .play("磁力", "magnet:?xt=urn:btih:abc", "")
            .await
            .expect("磁力必须返回");
        assert!(plays[0].label.as_deref().unwrap_or("").contains("磁力"));
    }

    #[tokio::test]
    async fn play_rejects_garbage() {
        let err = Sou4K::new().play("网盘", "not-a-url", "").await.unwrap_err();
        assert!(err.contains("不是 http(s)/magnet:"), "{err}");
    }

    // ── 真网络（默认不跑；显式跑必须给 CSP_LIVE=1）──

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib sou4k_live -- --ignored --nocapture"]
    async fn sou4k_live_home_list_search_detail_play() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = Sou4K::new();

        let home = s.home("").await.expect("home 必须真取到数据");
        assert_eq!(home.categories.len(), 3);
        assert!(!home.items.is_empty(), "★ 反空真：首屏必须有真条目");
        println!("LIVE home：分类 {} 个，首屏 {} 条", home.categories.len(), home.items.len());

        let list = s.list("short", 1, "").await.expect("短剧排行必须真取到数据");
        assert!(!list.items.is_empty(), "★ 反空真");
        println!("LIVE list 短剧排行：{} 条，首条={}", list.items.len(), list.items[0].title);

        let sr = s.search("红", 1, "").await.expect("搜索必须真取到数据");
        assert!(!sr.items.is_empty(), "★ 反空真：搜索结果不能空");
        println!(
            "LIVE search 红：{} 条（total={:?} 页数={:?}），首条={}",
            sr.items.len(),
            sr.total,
            sr.page_count,
            sr.items[0].title
        );

        // ★ 分页对照：第 2 页首条必须与第 1 页不同
        let sr2 = s.search("红", 2, "").await.expect("第 2 页必须真取到数据");
        assert!(!sr2.items.is_empty(), "★ 反空真：第 2 页不能空");
        assert_ne!(
            sr2.items[0].id, sr.items[0].id,
            "★ 第 2 页首条必须与第 1 页不同（否则 page 参数没生效）"
        );
        println!("LIVE 分页对照：p1 首条={} p2 首条={}", sr.items[0].title, sr2.items[0].title);

        // ★ 走 check-links 取真链接（这是"真能用"的证据，不是"接口能返回"）
        let cloud = sr
            .items
            .iter()
            .find(|i| i.id.starts_with("cloud"))
            .expect("★ 反空真：搜索结果里应当有 cloud 条目");
        let d = s.detail(&cloud.id, "").await.expect("网盘条目必须解出链接");
        assert!(!d.episodes.is_empty(), "★ 反空真：必须解出线路");
        println!("LIVE detail：{} ｜ 线路 {} 条", cloud.title, d.episodes.len());
        for ep in d.episodes.iter().take(3) {
            println!("    - {}：{}", ep.title, ep.id);
        }
        let ep = d.episodes.first().unwrap();
        let plays = s.play(&ep.flag, &ep.id, "").await.expect("链接必须返回");
        assert!(plays[0].url.starts_with("http"), "★ 反空真：必须是真地址");
    }

    #[test]
    /// ★★ 不读系统代理（**跨批一致性**：本仓 csp 既定惯例，见 `app99.rs:342`）
    ///
    /// 断言的**对象是源码形态**（构造链里有没有 `.no_proxy()`），**不依赖网络**。
    /// 注入：删掉那条 `.no_proxy()` ⇒ 本条 FAILED。
    /// ★ 用 `impl_src_only` 先剥测试段，防"本函数自己的字面量喂饱门禁 ⇒ 假绿"。
    fn client_does_not_read_system_proxy() {
        let src = crate::csp::shared::impl_src_only(include_str!("sou4k.rs"));
        assert!(
            src.contains(".no_proxy()"),
            "★ Client 构造链必须含 `.no_proxy()`（不读系统代理）；             否则装了代理的机器上会把'站点可用'测成'全宕'"
        );
    }
}
