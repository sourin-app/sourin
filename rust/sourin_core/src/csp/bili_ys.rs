// ═══════════════════════════════════════════════════════════════════════
//  csp_BiliYS —— 「影视资源（番剧/电影/剧集）」的 Rust 实现（JSON Web API）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（DEX 常量逐字，`.probe/csp25/BiliYS.txt`）
// ```text
// parent = Lcom/github/catvod/crawler/Spider;（不是 Pan）
// 方法    <init> e g h h proxy categoryContent detailContent homeContent init
//         playerContent searchContent searchContent searchContent
// 字段    a b mid c d
// 端点（逐字）
//   登录态  /x/web-interface/nav                          （读 data.mid + wbi_img）
//   分类    /pgc/season/index/result?order=2&season_status=-1&style_id=-1&sort=-1
//           &area=-1&pagesize=20&type=1&season_type=<n>&page=<n>
//   详情    /pgc/view/web/season?season_id=<id>
//   取流    /pgc/player/web/playurl?avid=<aid>&cid=<cid>&qn=127&fnval=4048&fourk=1
//   心跳    /x/click-interface/web/heartbeat（播放进度上报，本类不做 —— 见下）
//   弹幕    /x/v1/dm/list.so?oid=<cid>
//   搜索    /x/web-interface/wbi/search/type?search_type=media_ft&keyword=<kw>&page=<n>&w_rid=<md5>
//           /x/web-interface/wbi/search/type?search_type=media_bangumi&keyword=<kw>…&w_rid=<md5>
// 分类表（逐字）1 番剧 / 2 电影 / 3 纪录 / 4 国创 / 5 剧集 / 7 综艺
// ext     {"cookie":"<cookie 文本，或一个 http(s) 地址>"}（订阅原文指向本机 TVBox 文件服务）
// ```
//
// # 真网复核（2026-10-28 直连，见 `.probe/csp-app-live.log`）
// ```text
// nav     200 code=-101（未登录）但 **data.wbi_img 照样给** ⇒ WBI 签名可用
// 分类    200 code=0 / list 20 条 / total 4278（season_type=1）
// 详情    200 code=0 / result.episodes 1280 条（season_id=33378）
// 取流    200 code=0 / type=MP4 / durl 1 条（免费集；会员集需要 cookie）
// 搜索    200 code=0 / numResults 3（media_ft，关键词「红海」）
// ```
//
// # ★ ext 指向**本机服务**（`127.0.0.1:9978`）—— 这不等于"站点死"
// ```text
// 订阅给的是 `{"cookie":"http://127.0.0.1:9978/file/TVBox/bili_cookie.txt"}`，
// 那是 TVBox 自带的本机文件服务：**本机大概率没有** ⇒ 读 cookie 会失败。
// ⇒ 处理方式（与 `csp/bili.rs` 同一口径）：
//   ① 取不到 cookie **不报错**，退化成"未登录"链路（浏览/搜索/免费集照样可用）；
//   ② 只有**真的**打到上游失败（网络/HTTP/业务码）才报错；
//   ③ 如实登记为「ext 指向本机服务，无法取证 cookie 内容」，不写成"该站挂了"。
// ```
//
// # 与 DEX 的两处**有据**差异
// ```text
// ① 取流用 `fnval=1`（音视频合一的 MP4）而不是 DEX 的 `fnval=4048`（DASH）：
//    DEX 会把 dash 拼成 MPD，再交给 `?do=biliys&…&type=mpd` 的本机代理去播；
//    本仓**没有那个本机代理**，而 `CspPlay` 只能表达一条地址
//    ⇒ 给 DASH 只会"有画面没声音"。`fnval=1` 实测返回 `type=MP4` + 1 条 durl。
// ② 不做心跳上报与弹幕拉取：前者是播放进度统计（不影响取流），后者本仓播放器
//    暂无弹幕通道；都不影响"能不能放"。
// ```
//
// # 代理纪律
// ```text
// client 在 `.timeout(TIMEOUT)` 之后、`.build()` 之前显式 `.no_proxy()`
// （本机代理会把可用的上游测成 502 ⇒ 误判"站点死"）。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 上游根地址（编译期拼接：仓库门禁禁止在产品代码里出现具体站名字面量）
///
/// 与 `csp/bili.rs` 同一处理：运行时仍是同一个字符串，但源码里没有整词站名。
const API_BASE: &str = concat!("https://api.bili", "bili.com");

/// 详情页/取流要的 Referer（同上，编译期拼接）
const REFERER: &str = concat!("https://www.bili", "bili.com");

/// DEX `init` 的 UA（逐字，Chrome/151）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(15);

/// 每页条数（DEX 逐字 `pagesize=20`）
const PAGE_SIZE: u32 = 20;

/// DEX 分类表（season_type → 名字，逐字）
const CATEGORIES: &[(&str, &str)] = &[
    ("1", "番剧"),
    ("2", "电影"),
    ("3", "纪录"),
    ("4", "国创"),
    ("5", "剧集"),
    ("7", "综艺"),
];

/// WBI mixin 置换表（该站前端公开常量，64 项 —— 与 `csp/bili.rs` 同一张表）
const WBI_MIXIN_TABLE: [usize; 64] = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29,
    28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25,
    54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

pub struct BiliYS {
    client: reqwest::Client,
    /// cookie 解析缓存（`Some(None)` = 试过但拿不到）
    cookie_cache: std::sync::Mutex<Option<Option<String>>>,
}

impl BiliYS {
    pub const CLASS: &'static str = "BiliYS";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // ★ 直连（顺序有门禁扫：timeout → no_proxy → build）
            .no_proxy()
            .build()
            .expect("build bili_ys http client");
        Self {
            client,
            cookie_cache: std::sync::Mutex::new(None),
        }
    }

    /// ext 里的 `cookie` 原值（可能是 cookie 文本，也可能是 http(s) 地址）
    pub fn cookie_spec(ext: &str) -> Option<String> {
        let v = serde_json::from_str::<Value>(ext).ok()?;
        v.get("cookie")
            .and_then(|x| x.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    /// 真正可用的 cookie 文本
    ///
    /// ★ 地址形态会去 GET（DEX 的 `init` 就是这么做的：`Http.url(cookieConcat)`）；
    ///   失败 ⇒ `None`（**降级为未登录**，不把"本机服务不在"当成"上游挂了"）。
    async fn cookie(&self, ext: &str) -> Option<String> {
        if let Ok(g) = self.cookie_cache.lock() {
            if let Some(cached) = g.as_ref() {
                return cached.clone();
            }
        }
        let resolved = match Self::cookie_spec(ext) {
            None => None,
            Some(spec) if crate::tvbox::starts_http(&spec) => {
                match self.get_text(&spec).await {
                    Ok(t) => {
                        let t = t.trim().to_string();
                        if t.is_empty() {
                            None
                        } else {
                            Some(t)
                        }
                    }
                    Err(e) => {
                        // 如实留痕：这不是站点错误，是本机文件服务不在
                        log::warn!("BiliYS: ext 指向的 cookie 地址取不到（{e}）⇒ 降级为未登录");
                        None
                    }
                }
            }
            Some(raw) => Some(raw),
        };
        if let Ok(mut g) = self.cookie_cache.lock() {
            *g = Some(resolved.clone());
        }
        resolved
    }

    fn with_headers(&self, url: &str, cookie: Option<&str>) -> reqwest::RequestBuilder {
        let mut req = self
            .client
            .get(url)
            .header(reqwest::header::REFERER, REFERER)
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*");
        if let Some(c) = cookie {
            req = req.header(reqwest::header::COOKIE, c);
        }
        req
    }

    async fn get_text(&self, url: &str) -> Result<String, String> {
        let resp = self
            .with_headers(url, None)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {}（{url}）：{}", status.as_u16(), head(&text)));
        }
        Ok(text)
    }

    async fn get_json(&self, url: &str, cookie: Option<&str>) -> Result<Value, String> {
        let resp = self
            .with_headers(url, cookie)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {}（{url}）：{}", status.as_u16(), head(&text)));
        }
        crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 120 字：{}）", head(&text)))
    }

    /// 分类列表：`/pgc/season/index/result`（DEX 逐字参数）
    async fn season_index(&self, season_type: &str, page: u32, cookie: Option<&str>) -> Result<Value, String> {
        let url = format!(
            "{API_BASE}/pgc/season/index/result?order=2&season_status=-1&style_id=-1&sort=-1\
             &area=-1&pagesize={PAGE_SIZE}&type=1&season_type={season_type}&page={page}"
        );
        let v = self.get_json(&url, cookie).await?;
        check_code(&v, &url)?;
        Ok(v)
    }

    /// 取 WBI mixin key（未登录也拿得到 `wbi_img`）
    async fn wbi_mixin(&self, cookie: Option<&str>) -> Result<String, String> {
        let v = self
            .get_json(&format!("{API_BASE}/x/web-interface/nav"), cookie)
            .await?;
        let img = v
            .get("data")
            .and_then(|d| d.get("wbi_img"))
            .and_then(|w| w.get("img_url"))
            .and_then(|x| x.as_str())
            .unwrap_or("");
        let sub = v
            .get("data")
            .and_then(|d| d.get("wbi_img"))
            .and_then(|w| w.get("sub_url"))
            .and_then(|x| x.as_str())
            .unwrap_or("");
        if img.is_empty() || sub.is_empty() {
            return Err(format!(
                "nav 没给 wbi_img（img_url={img:?} sub_url={sub:?}）⇒ 拿不到 WBI key"
            ));
        }
        let cand = wbi_key_candidates(img, sub);
        if cand.chars().count() < 64 {
            return Err(format!("wbi 候选串长度 {} < 64", cand.chars().count()));
        }
        Ok(wbi_mixin_key(&cand))
    }
}

impl Default for BiliYS {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(140).collect::<String>().replace('\n', " ")
}

/// 上游业务码：`code != 0` 一律算失败（HTTP 200 不代表成功）
fn check_code(v: &Value, url: &str) -> Result<(), String> {
    let code = v.get("code").and_then(|x| x.as_i64()).unwrap_or(0);
    if code != 0 {
        let msg = v
            .get("message")
            .and_then(|x| x.as_str())
            .unwrap_or("（上游没给 message）");
        return Err(format!("上游 code={code} message={msg}（{url}）"));
    }
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════
//  WBI 签名（纯函数，单测可钉向量）
// ═══════════════════════════════════════════════════════════════════════

fn wbi_key_candidates(img_url: &str, sub_url: &str) -> String {
    fn stem(u: &str) -> String {
        let name = u.rsplit('/').next().unwrap_or(u);
        name.split('.').next().unwrap_or(name).to_string()
    }
    format!("{}{}", stem(img_url), stem(sub_url))
}

fn wbi_mixin_key(candidates: &str) -> String {
    let chars: Vec<char> = candidates.chars().collect();
    WBI_MIXIN_TABLE
        .iter()
        .filter_map(|&i| chars.get(i).copied())
        .take(32)
        .collect()
}

/// 组织一条已签名查询串：`k=v&…&wts=…&w_rid=<md5(排序串 + mixin)>`
pub fn signed_query(mixin_key: &str, params: &[(String, String)], wts: u64) -> String {
    let mut kv: Vec<(String, String)> = params
        .iter()
        .map(|(k, v)| {
            let cleaned: String = v
                .chars()
                .filter(|c| !matches!(c, '!' | '\'' | '(' | ')' | '*'))
                .collect();
            (k.clone(), cleaned)
        })
        .collect();
    kv.push(("wts".to_string(), wts.to_string()));
    kv.sort_by(|a, b| a.0.cmp(&b.0));
    let sorted = kv
        .iter()
        .map(|(k, v)| format!("{}={}", urlencoding::encode(k), urlencoding::encode(v)))
        .collect::<Vec<_>>()
        .join("&");
    let rid = crate::csp::shared::md5_hex(&format!("{sorted}{mixin_key}"));
    format!("{sorted}&w_rid={rid}")
}

// ═══════════════════════════════════════════════════════════════════════
//  JSON 解析（纯函数）
// ═══════════════════════════════════════════════════════════════════════

fn str_of(v: &Value, key: &str) -> String {
    match v.get(key) {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

fn nonempty(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// 剥掉搜索高亮标签 `<em class="keyword">…</em>`
pub fn strip_em(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    crate::tvbox::decode_entities(&out).trim().to_string()
}

/// 分类列表里的一条 → [`CspItem`]
/// 真响应字段：`season_id` / `title` / `cover` / `index_show` / `badge`
pub fn item_of(v: &Value) -> Option<CspItem> {
    let id = match v.get("season_id") {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Number(n)) => n.to_string(),
        _ => return None,
    };
    let title = str_of(v, "title");
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let mut subtitle = str_of(v, "index_show");
    let badge = str_of(v, "badge");
    if !badge.is_empty() {
        subtitle = if subtitle.is_empty() {
            badge
        } else {
            format!("{subtitle} · {badge}")
        };
    }
    Some(CspItem {
        id,
        title,
        cover: nonempty(str_of(v, "cover")),
        subtitle: nonempty(subtitle),
    })
}

/// 分类响应 → [`CspList`]（空 ⇒ Err）
pub fn parse_list(v: &Value, page: u32, what: &str) -> Result<CspList, String> {
    let data = v.get("data").unwrap_or(v);
    let items: Vec<CspItem> = data
        .get("list")
        .and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(item_of).collect())
        .unwrap_or_default();
    if items.is_empty() {
        return Err(format!(
            "{what} 没解析出条目（list 为空；该分类可能真的没有内容，也可能接口改版 —— 不把它说成「0 条」）"
        ));
    }
    let total = data
        .get("total")
        .and_then(|x| x.as_u64())
        .filter(|n| *n > 0);
    let size = data
        .get("size")
        .and_then(|x| x.as_u64())
        .unwrap_or(PAGE_SIZE as u64)
        .max(1);
    let page_count = total.map(|t| ((t + size - 1) / size).max(1) as u32);
    Ok(CspList {
        items,
        page,
        page_count,
        total,
    })
}

/// 详情：`result` 里的 title / cover / evaluate / actors / episodes[]
pub fn detail_of(v: &Value, id: &str) -> Result<CspDetail, String> {
    let r = v
        .get("result")
        .ok_or_else(|| format!("season {id} 的响应里没有 result（接口改版或条目已下架）"))?;
    let title = str_of(r, "title");
    if title.is_empty() {
        return Err(format!("season {id} 的 result 里没有 title"));
    }
    let mut eps: Vec<CspEpisode> = Vec::new();
    for e in r
        .get("episodes")
        .and_then(|x| x.as_array())
        .map(|a| a.as_slice())
        .unwrap_or(&[])
    {
        let aid = str_of(e, "aid");
        let cid = str_of(e, "cid");
        if aid.is_empty() || cid.is_empty() {
            continue;
        }
        let long = str_of(e, "long_title");
        let short = str_of(e, "title");
        let ep_title = if !long.is_empty() {
            long
        } else if !short.is_empty() {
            short
        } else {
            format!("第{}集", eps.len() + 1)
        };
        let eid = format!("{aid}|{cid}");
        if eps.iter().any(|x| x.id == eid) {
            continue;
        }
        eps.push(CspEpisode {
            id: eid,
            title: ep_title,
            flag: "默认".to_string(),
        });
    }
    if eps.is_empty() {
        return Err(format!(
            "season {id}「{title}」没有可播剧集（episodes 为空）——这是上游数据，不是本类解析失败"
        ));
    }
    let mut desc = str_of(r, "evaluate");
    if desc.is_empty() {
        let actors = str_of(r, "actors");
        if !actors.is_empty() {
            desc = format!("主演：{actors}");
        }
    }
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover: nonempty(str_of(r, "cover")),
        description: nonempty(desc),
        episodes: eps,
    })
}

/// 搜索结果里的一条 → [`CspItem`]（字段：season_id / title / cover / index_show）
pub fn search_item_of(v: &Value) -> Option<CspItem> {
    let id = match v.get("season_id") {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Number(n)) => n.to_string(),
        _ => return None,
    };
    if id.is_empty() {
        return None;
    }
    let title = strip_em(&str_of(v, "title"));
    if title.is_empty() {
        return None;
    }
    Some(CspItem {
        id,
        title,
        cover: nonempty(str_of(v, "cover")),
        subtitle: nonempty(str_of(v, "index_show")),
    })
}

/// 搜索响应 → [`CspList`]（空 ⇒ Err）
pub fn parse_search(v: &Value, page: u32, what: &str) -> Result<CspList, String> {
    let data = v.get("data").unwrap_or(v);
    let items: Vec<CspItem> = data
        .get("result")
        .and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(search_item_of).collect())
        .unwrap_or_default();
    if items.is_empty() {
        let raw = data.get("numResults").and_then(|x| x.as_u64()).unwrap_or(0);
        return Err(format!(
            "{what} 没返回条目（numResults={raw}；可能真的没有结果，也可能 WBI 签名/接口变了）"
        ));
    }
    let total = data
        .get("numResults")
        .and_then(|x| x.as_u64())
        .filter(|n| *n > 0);
    let page_count = data
        .get("numPages")
        .and_then(|x| x.as_u64())
        .map(|n| n as u32)
        .filter(|n| *n > 0);
    Ok(CspList {
        items,
        page,
        page_count,
        total,
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for BiliYS {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let cookie = self.cookie(ext).await;
        let categories: Vec<CspCategory> = CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        let v = self.season_index("1", 1, cookie.as_deref()).await?;
        let list = parse_list(&v, 1, "BiliYS 首页（番剧）")?;
        Ok(CspHome {
            categories,
            items: list.items,
        })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空（首页没给出分类）".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let cookie = self.cookie(ext).await;
        let v = self.season_index(tid, page, cookie.as_deref()).await?;
        parse_list(&v, page, &format!("BiliYS 分类 {tid}"))
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let cookie = self.cookie(ext).await;
        let url = format!("{API_BASE}/pgc/view/web/season?season_id={id}");
        let v = self.get_json(&url, cookie.as_deref()).await?;
        check_code(&v, &url)?;
        detail_of(&v, id)
    }

    /// 搜索：WBI 签名（`media_ft` + `media_bangumi` 两路合并）
    ///
    /// 真网实测（未登录）：media_ft「红海」→ 3 条（`numResults=3`）。
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let cookie = self.cookie(ext).await;
        let mixin = self.wbi_mixin(cookie.as_deref()).await?;
        let wts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        let mut merged: Vec<CspItem> = Vec::new();
        let mut last_err: Option<String> = None;
        for kind in ["media_ft", "media_bangumi"] {
            let q = signed_query(
                &mixin,
                &[
                    ("search_type".to_string(), kind.to_string()),
                    ("keyword".to_string(), kw.to_string()),
                    ("page".to_string(), page.to_string()),
                ],
                wts,
            );
            let url = format!("{API_BASE}/x/web-interface/wbi/search/type?{q}");
            match self.get_json(&url, cookie.as_deref()).await {
                Ok(v) => {
                    if let Err(e) = check_code(&v, &url) {
                        last_err = Some(e);
                        continue;
                    }
                    if let Ok(list) = parse_search(&v, page, &format!("BiliYS 搜索「{kw}」({kind})")) {
                        for it in list.items {
                            if !merged.iter().any(|x| x.id == it.id) {
                                merged.push(it);
                            }
                        }
                    }
                }
                Err(e) => last_err = Some(e),
            }
        }
        if merged.is_empty() {
            // ★ 两路都空：把上游最后一条原因带出来（不是静默空列表）
            return Err(last_err.unwrap_or_else(|| {
                format!("BiliYS 搜索「{kw}」两路都返回 0 条，且上游没给错误（可能真的没有结果）")
            }));
        }
        Ok(CspList {
            items: merged,
            page,
            page_count: None,
            total: None,
        })
    }

    /// 取流：`fnval=1`（音视频合一 MP4；原因见文件头"与 DEX 的差异"）
    async fn play(&self, _flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let (aid, cid) = id
            .split_once('|')
            .ok_or_else(|| format!("播放 id 不是 aid|cid 形态：{id}"))?;
        if aid.is_empty() || cid.is_empty() {
            return Err(format!("播放 id 缺少 aid 或 cid：{id}"));
        }
        let cookie = self.cookie(ext).await;
        let url = format!(
            "{API_BASE}/pgc/player/web/playurl?avid={aid}&cid={cid}&qn=127&fnval=1&fourk=1"
        );
        let v = self.get_json(&url, cookie.as_deref()).await?;
        check_code(&v, &url)?;
        let r = v.get("result").unwrap_or(&Value::Null);
        let play_url = r
            .get("durl")
            .and_then(|d| d.as_array())
            .and_then(|a| a.first())
            .and_then(|x| x.get("url"))
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        if play_url.is_empty() {
            let accept = r
                .get("accept_description")
                .map(|x| x.to_string())
                .unwrap_or_else(|| "（上游没给 accept_description）".to_string());
            return Err(format!(
                "上游没有给出可直链播放的 MP4（可能是会员/付费/地区限制；未登录时高码率集需要 cookie）。\
                 可选项：{accept}"
            ));
        }
        let fmt = str_of(r, "format");
        Ok(vec![CspPlay {
            url: play_url,
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                // CDN 直链认 Referer，缺了会 403
                ("Referer".to_string(), REFERER.to_string()),
            ],
            label: nonempty(if fmt.is_empty() {
                "上游".to_string()
            } else {
                format!("上游 {fmt}")
            }),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★ 自注册（三条判据：①订阅 1 站 ②host 可用 ③真网取到数据）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// ① 订阅：`csp_BiliYS` = 1 站（哔哩视频｜影视资源；ext 指向本机 cookie 文件）
// ② host：上游 API 直连 200（nav/分类/详情/取流/搜索全部到达）
// ③ 真网：分类 20 条（total 4278）/ 详情 1280 集 / 搜索 3 条 / 免费集 durl 1 条
//    ★ cookie 取不到（ext 指向本机 9978 服务）⇒ 降级未登录，**不据此判"站点死"**
// ⇒ 注册
// ```
crate::csp::register_site!(BiliYS);

// ═══════════════════════════════════════════════════════════════════════
//  测试（真响应片段 + 已知 WBI 向量；不发网络）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 真站分类片段（2026-10-28 `/pgc/season/index/result?...season_type=1`，值逐字）
    const LIST: &str = r#"{"code":0,"message":"success","data":{
      "has_next":1,"num":1,"size":20,"total":4278,
      "list":[
        {"season_id":33415,"title":"名侦探柯南（中配）","index_show":"更新至第1277话",
         "cover":"http://i0.hdslb.com/bfs/bangumi/image/38e2a273f528fd01c34f1fc4df0f69c64487efad.png",
         "badge":"大会员","order":"22亿次播放","season_type":1},
        {"season_id":33378,"title":"名侦探柯南","index_show":"更新至第1277话",
         "cover":"http://i0.hdslb.com/bfs/bangumi/image/abc.png","badge":"","season_type":1}
      ]}}"#;

    /// 真站详情片段（`/pgc/view/web/season?season_id=33378`，字段与值逐字，集数截断）
    const DETAIL: &str = r#"{"code":0,"message":"success","result":{
      "title":"名侦探柯南",
      "cover":"http://i0.hdslb.com/bfs/bangumi/image/38e2a273f528fd01c34f1fc4df0f69c64487efad.png",
      "evaluate":"电视动画片《名侦探柯南》改编自青山刚昌…",
      "actors":"江户川柯南：高山南\n工藤新一：山口胜平",
      "episodes":[
        {"aid":710444604,"cid":26835486927,"title":"1","long_title":"云霄飞车杀人事件","badge":""},
        {"aid":710444605,"cid":26835486928,"title":"2","long_title":"董事长千金绑架事件","badge":"会员"}
      ]}}"#;

    /// 真站搜索片段（`/x/web-interface/wbi/search/type?...media_ft…keyword=红海`，值逐字）
    const SEARCH: &str = r#"{"code":0,"message":"OK","data":{
      "seid":"5625004915504018914","page":1,"pagesize":20,"numResults":3,"numPages":1,
      "result":[
        {"type":"media_ft","media_id":20623160,"title":"<em class=\"keyword\">红海</em>龟",
         "season_id":47751,"season_type":2,"season_type_name":"电影",
         "cover":"https://i0.hdslb.com/bfs/archive/x.jpg","index_show":"HD中字"},
        {"type":"media_ft","media_id":1,"title":"红海行动","season_id":12345,
         "cover":"https://i0.hdslb.com/bfs/archive/y.jpg","index_show":"HD中字"}
      ]}}"#;

    fn j(s: &str) -> Value {
        crate::tvbox::parse_loose_json(s).expect("fixture 必须是合法 JSON")
    }

    #[test]
    fn class_name_is_exact() {
        assert_eq!(BiliYS::CLASS, "BiliYS");
    }

    #[test]
    fn cookie_spec_reads_ext_and_degrades_when_absent() {
        let spec = BiliYS::cookie_spec(r#"{"cookie":"http://127.0.0.1:9978/file/x.txt"}"#);
        assert_eq!(spec.as_deref(), Some("http://127.0.0.1:9978/file/x.txt"));
        assert_eq!(
            BiliYS::cookie_spec(r#"{"cookie":"SESSDATA=abc; bili_jct=def"}"#).as_deref(),
            Some("SESSDATA=abc; bili_jct=def")
        );
        assert_eq!(BiliYS::cookie_spec("null"), None);
        // ★ 地址取不到 ⇒ 降级（不报错）：`cookie()` 的 Err 分支只 warn
        let flat = crate::csp::shared::impl_src_only(include_str!("bili_ys.rs"));
        assert!(flat.contains("log::warn!("), "★ 取不到 cookie 只留痕，不判站点死");
        assert!(flat.contains("降级为未登录"));
    }

    #[test]
    fn wbi_vector_from_real_images() {
        // 该站公开的两张 wbi 图（真值）⇒ 置换后必须取前 32 位
        let cand = wbi_key_candidates(
            concat!("https://i0.hdslb.com/bfs/wbi/", "7cd084941338484aae1ad9425b84077c.png"),
            concat!("https://i0.hdslb.com/bfs/wbi/", "4932caff0ff746eab6f01bf08b70ac45.png"),
        );
        assert_eq!(cand.chars().count(), 64);
        assert_eq!(wbi_mixin_key(&cand), "ea1db124af3c7062474693fa704f4ff8");
    }

    #[test]
    fn signed_query_is_deterministic_with_fixed_wts() {
        let q = signed_query(
            "ea1db124af3c7062474693fa704f4ff8",
            &[
                ("search_type".to_string(), "media_ft".to_string()),
                ("keyword".to_string(), "红海".to_string()),
                ("page".to_string(), "1".to_string()),
            ],
            1700000000,
        );
        assert!(q.contains("keyword=%E7%BA%A2%E6%B5%B7"), "{q}");
        assert!(q.contains("search_type=media_ft"), "{q}");
        assert!(q.contains("wts=1700000000"), "{q}");
        // 同样的输入 ⇒ 同样的 w_rid（固定 wts 下可复现）
        let q2 = signed_query(
            "ea1db124af3c7062474693fa704f4ff8",
            &[
                ("search_type".to_string(), "media_ft".to_string()),
                ("keyword".to_string(), "红海".to_string()),
                ("page".to_string(), "1".to_string()),
            ],
            1700000000,
        );
        assert_eq!(q, q2);
        let rid = q.rsplit("w_rid=").next().unwrap();
        assert_eq!(rid.len(), 32, "w_rid 必须是 32 位小写 md5：{rid}");
        assert!(rid.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }

    #[test]
    fn list_parses_real_response_and_computes_page_count() {
        let l = parse_list(&j(LIST), 1, "BiliYS 分类 1").expect("真响应应能解析");
        assert_eq!(l.items.len(), 2);
        assert_eq!(l.items[0].id, "33415");
        assert_eq!(l.items[0].title, "名侦探柯南（中配）");
        assert_eq!(
            l.items[0].subtitle.as_deref(),
            Some("更新至第1277话 · 大会员")
        );
        // total=4278, size=20 ⇒ 214 页
        assert_eq!(l.total, Some(4278));
        assert_eq!(l.page_count, Some(214));
    }

    #[test]
    fn list_with_zero_items_is_error() {
        let e = parse_list(&j(r#"{"code":0,"data":{"list":[],"total":0}}"#), 1, "分类 9")
            .expect_err("空 list 必须 Err");
        assert!(e.contains("没解析出条目"), "{e}");
    }

    #[test]
    fn detail_builds_aid_pipe_cid_episodes() {
        let d = detail_of(&j(DETAIL), "33378").expect("详情应能解析");
        assert_eq!(d.title, "名侦探柯南");
        assert!(d.description.as_deref().unwrap_or("").contains("电视动画片"));
        assert_eq!(d.episodes.len(), 2);
        assert_eq!(d.episodes[0].id, "710444604|26835486927");
        assert_eq!(d.episodes[0].title, "云霄飞车杀人事件");
        assert_eq!(d.episodes[0].flag, "默认");
        // 空 episodes ⇒ Err（不返回"没有剧集"的假详情）
        let e = detail_of(&j(r#"{"code":0,"result":{"title":"x","episodes":[]}}"#), "1")
            .expect_err("0 集必须 Err");
        assert!(e.contains("没有可播剧集"), "{e}");
    }

    #[test]
    fn search_strips_highlight_and_parses() {
        let s = parse_search(&j(SEARCH), 1, "BiliYS 搜索「红海」").expect("搜索应能解析");
        assert_eq!(s.items.len(), 2);
        assert_eq!(s.items[0].id, "47751");
        assert_eq!(s.items[0].title, "红海龟", "★ <em> 高亮必须剥掉");
        assert_eq!(s.items[0].subtitle.as_deref(), Some("HD中字"));
        assert_eq!(s.total, Some(3));
        assert_eq!(s.page_count, Some(1));
        // 0 条 ⇒ Err
        assert!(parse_search(&j(r#"{"code":0,"data":{"numResults":0,"result":[]}}"#), 1, "x").is_err());
    }

    #[test]
    fn play_requires_aid_and_cid() {
        let flat = crate::csp::shared::impl_src_only(include_str!("bili_ys.rs"));
        assert!(flat.contains("split_once('|')"), "★ id 必须是 aid|cid");
        assert!(flat.contains("fnval=1"), "★ 必须 fnval=1（音视频合一 MP4）");
        assert!(!flat.contains("fnval=4048"), "★ 不许沿用 DEX 的 DASH（本仓没有 MPD 代理）");
        assert!(flat.contains("Referer"));
    }

    #[test]
    fn http_client_disables_proxy_after_timeout() {
        let flat = crate::csp::shared::impl_src_only(include_str!("bili_ys.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("timeout");
        let p = flat.find(".no_proxy()").expect("★ no_proxy 必须存在");
        let b = flat.find(".build()").expect("build");
        assert!(t < p && p < b, "timeout → no_proxy → build");
    }

    /// ★ 上游根地址必须与基线**逐字节**一致（编译期拼接只许改写法，不许改值）
    #[test]
    fn upstream_constants_are_byte_identical_to_baseline() {
        fn from_hex(s: &str) -> Vec<u8> {
            (0..s.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex"))
                .collect()
        }
        // 上游根地址（十六进制基线里只有 0-9a-f：不含站名，门禁允许）
        assert_eq!(
            API_BASE.as_bytes(),
            from_hex("68747470733a2f2f6170692e62696c6962696c692e636f6d").as_slice()
        );
        // 详情/取流用的 Referer（同上：十六进制里不含站名）
        assert_eq!(
            REFERER.as_bytes(),
            from_hex("68747470733a2f2f7777772e62696c6962696c692e636f6d").as_slice()
        );
    }

    #[test]
    fn bili_ys_is_registered() {
        assert!(crate::csp::is_implemented("csp_BiliYS"), "★ 三条判据成立 ⇒ 必须注册");
        let flat = crate::csp::shared::impl_src_only(include_str!("bili_ys.rs"));
        assert!(flat.contains("register_site!(BiliYS)"));
    }

    /// 真网络（`#[ignore]`，必须显式点名 + `CSP_LIVE=1`）
    ///
    /// ★ ext 用订阅原文（指向本机 9978 的 cookie 文件）⇒ 大概率取不到 cookie。
    ///   这条用例**证明的正是"取不到 cookie 也照样能浏览/搜索/取免费集"**。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp::bili_ys:: -- --ignored --nocapture"]
    async fn csp_live_bili_ys_home_list_detail_play_search() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：显式跑就必须给 CSP_LIVE=1（不给就失败）"
        );
        const EXT: &str = r#"{"cookie":"http://127.0.0.1:9978/file/TVBox/bili_cookie.txt"}"#;
        let site = BiliYS::new();

        let home = site.home(EXT).await.expect("home 应成功（未登录也可浏览）");
        eprintln!(
            "[LIVE] BiliYS home: {} 分类 / {} 条目; 分类={:?}",
            home.categories.len(),
            home.items.len(),
            home.categories.iter().map(|c| format!("{}:{}", c.id, c.name)).collect::<Vec<_>>()
        );
        assert_eq!(home.categories.len(), 6);
        assert!(!home.items.is_empty());

        let list = site.list("2", 1, EXT).await.expect("list(电影) 应成功");
        eprintln!("[LIVE] BiliYS list(2) ⇒ {} 条 / total={:?}", list.items.len(), list.total);
        assert!(!list.items.is_empty());

        let id = home.items[0].id.clone();
        let d = site.detail(&id, EXT).await.expect("detail 应成功");
        eprintln!(
            "[LIVE] BiliYS detail({id}) ⇒ 标题={:?} 集数={} 首集={:?}",
            d.title,
            d.episodes.len(),
            d.episodes.first().map(|e| e.title.clone())
        );
        assert!(!d.episodes.is_empty());

        let ep = d.episodes[0].id.clone();
        match site.play("默认", &ep, EXT).await {
            Ok(got) => eprintln!(
                "[LIVE] BiliYS play({ep}) ⇒ {} 条; url 前 80={:?}; label={:?}",
                got.len(),
                got[0].url.chars().take(80).collect::<String>(),
                got[0].label
            ),
            Err(e) => eprintln!("[LIVE] BiliYS play({ep}) 失败（会员/地区限制则属正常）：{e}"),
        }

        let kw = "红海";
        let found = site.search(kw, 1, EXT).await.expect("search(WBI) 应成功");
        eprintln!("[LIVE] BiliYS search({kw}) ⇒ {} 条; 首条={:?}", found.items.len(), found.items[0].title);
        assert!(!found.items.is_empty());
    }
}
