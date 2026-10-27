// ═══════════════════════════════════════════════════════════════════════
//  csp_Juying —— 「聚影网盘资源站」的 Rust 实现（JSON App API + 登录门槛）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（DEX 常量逐字，`.probe/csp25/Juying.txt`）
// ```text
// parent = Lcom/github/catvod/spider/Pan;
// 方法    init / homeContent / categoryContent / detailContent / playerContent
//         searchContent / quickSearchContent / login / logout / loadToken
//         currentUser / getAuth / postAuth / resources / linkDetail
// 字段    SITE / TYPES / YEARS / token / tokenUser
//         CATE_MOVIE CATE_TV CATE_ANIME CATE_DOC CATE_VARIETY
//         PIC_QUARK PIC_BAIDU PIC_ALI PIC_XUNLEI PIC_UC PIC_189 PIC_123 PIC_139
//         PIC_GUANGYA PIC_MAGNET
// 主机（逐字）  https://www.jying.top
// 端点（逐字）
//   列表  /api/app/movies/?type=<movie|tv|anime|doc|variety>&page=<n>&page_size=24
//         [+ &category=<slug>][+ &year=<yyyy>]
//   搜索  /api/app/movies/?q=<kw>&page=<n>&page_size=24&fuzzy=true
//   详情  /api/app/movie/<id>/detail/
//   资源  /api/app/movie/<id>/resources/        ← ★ 需要登录（X-App-User-Token）
//   登录  /api/app/login/                        （username / password）
//   令牌  juying_token.json                      （token / user）
//   分类  /api/app/categories/                   （真站，未在 DEX 里，本类不用）
// 字段映射（逐字）
//   results[] : id / title / cover / backdrop_url / release_year / resource_count
//   data      : id / title / description / cover / backdrop_url / directors / actors
//   resources : resource_type / description / title / resolution_display / source_display
// ```
//
// # 真网复核（2026-10-28 直连 `https://www.jying.top`，见 `.probe/csp-app-live.log`）
// ```text
// list   200 {"status":"success","total_pages":1618,"total_count":38832,"results":[…24]}
// search 200 {"status":"success","total_count":10,"results":[{"id":52826,"title":"红海",…}]}
// detail 200 {"status":"success","data":{"id":52826,"title":"红海",…}}
// 资源   401 {"status":"error","message":"未登录，请先登录"}   ← ★ 登录门槛（不是站点死）
// ```
//
// # `ext` 与登录（这决定"能用到哪一步"）
// ```text
// 订阅里 `csp_Juying` 的 ext = null ⇒ **没有 token**。
// ① 浏览链路（home/list/search/detail 元数据）不需要登录 —— 真网已取证可用。
// ② 资源列表（/resources/）**必须登录**。没有 token 时：
//    · **不**把 401 说成"站点挂了"或"没有内容"；
//    · 详情仍然返回可读元数据，但剧集里放**一条明确标注"不可播"的状态行**
//      （id 前缀 `juying-need-login|`），`play` 对它会给出"去登录"的可读错误。
//      这与 DEX 的 `未登录：请到配置中心-其他-聚影登录` 占位行同一语义，
//      ★ 区别是：我们**不伪造播放地址**，也不假装那是一集正片。
// ③ 若 ext 给了 `{"token":"…"}` ⇒ 带 `X-App-User-Token` 头，资源链路即可用。
// ```
//
// # 代理纪律
// ```text
// client 在 `.timeout(TIMEOUT)` 之后、`.build()` 之前显式 `.no_proxy()`
// （本机 HTTP_PROXY 会让 200 变成 502，把"站点可用"误判成"站点死"）。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `SITE` 逐字（订阅 ext 为 null ⇒ 用它当默认 host）
const DEFAULT_HOST: &str = "https://www.jying.top";

/// DEX `UA` 逐字（Chrome/151）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(15);

/// 每页条数（DEX 逐字 `page_size=24`）
const PAGE_SIZE: u32 = 24;

/// 状态行 id 前缀：`juying-need-login|<movie id>`（**不可播**，只为把原因带到 UI）
pub const NEED_LOGIN_PREFIX: &str = "juying-need-login|";

/// DEX 的五个一级分类（顺序即首页顺序）
const TYPES: &[(&str, &str)] = &[
    ("movie", "电影"),
    ("tv", "电视剧"),
    ("anime", "动漫"),
    ("doc", "纪录片"),
    ("variety", "综艺"),
];

pub struct Juying {
    client: reqwest::Client,
}

impl Juying {
    pub const CLASS: &'static str = "Juying";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // ★ 直连（顺序有门禁扫：timeout → no_proxy → build）
            .no_proxy()
            .build()
            .expect("build juying http client");
        Self { client }
    }

    /// host：ext `site`/`host` 优先，否则 DEX 的 `SITE`
    pub fn host_of(ext: &str) -> String {
        if let Ok(v) = serde_json::from_str::<Value>(ext) {
            for key in ["site", "host"] {
                if let Some(arr) = v.get(key).and_then(|x| x.as_array()) {
                    if let Some(u) = arr.iter().filter_map(|x| x.as_str()).next() {
                        return u.trim().trim_end_matches('/').to_string();
                    }
                }
                if let Some(u) = v.get(key).and_then(|x| x.as_str()) {
                    let u = u.trim().trim_end_matches('/');
                    if u.starts_with("http") {
                        return u.to_string();
                    }
                }
            }
        }
        DEFAULT_HOST.to_string()
    }

    /// token：ext `{"token":"…"}`（订阅里是 null ⇒ None）
    pub fn token_of(ext: &str) -> Option<String> {
        let v = serde_json::from_str::<Value>(ext).ok()?;
        v.get("token")
            .and_then(|x| x.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    async fn get_json(&self, url: &str, token: Option<&str>) -> Result<Value, String> {
        let mut req = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "application/json")
            .header(reqwest::header::REFERER, format!("{DEFAULT_HOST}/"));
        if let Some(t) = token {
            req = req.header("X-App-User-Token", t);
        }
        let resp = req.send().await.map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {}（{url}）：{}", status.as_u16(), head(&text)));
        }
        crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 120 字：{}）", head(&text)))
    }
}

impl Default for Juying {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(140).collect::<String>().replace('\n', " ")
}

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

// ═══════════════════════════════════════════════════════════════════════
//  JSON → 数据契约（纯函数）
// ═══════════════════════════════════════════════════════════════════════

/// `results[]` 里的一条 → [`CspItem`]（真响应字段：id/title/cover/backdrop_url/release_year/resource_count）
pub fn item_of(v: &Value) -> Option<CspItem> {
    let id = match v.get("id") {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Number(n)) => n.to_string(),
        _ => return None,
    };
    let title = str_of(v, "title");
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let cover = nonempty(str_of(v, "cover")).or_else(|| nonempty(str_of(v, "backdrop_url")));
    let year = str_of(v, "release_year");
    let count = v
        .get("resource_count")
        .and_then(|x| x.as_u64())
        .unwrap_or(0);
    let mut subtitle = year;
    if count > 0 {
        let c = format!("{count} 个资源");
        subtitle = if subtitle.is_empty() { c } else { format!("{subtitle} · {c}") };
    }
    Some(CspItem {
        id,
        title,
        cover,
        subtitle: nonempty(subtitle),
    })
}

/// 列表/搜索响应 → [`CspList`]
///
/// ★ 空 results ⇒ 调用点必须 Err（契约第 1 条；本函数的 `Err` 由 [`parse_list`] 给）。
pub fn parse_list(v: &Value, page: u32, what: &str) -> Result<CspList, String> {
    let status = str_of(v, "status");
    if !status.is_empty() && status != "success" {
        let msg = str_of(v, "message");
        return Err(format!(
            "{what} 返回 status={status}{}（上游业务失败，不是「没有内容」）",
            if msg.is_empty() { String::new() } else { format!(" message={msg}") }
        ));
    }
    let items: Vec<CspItem> = v
        .get("results")
        .and_then(|x| x.as_array())
        .map(|a| a.iter().filter_map(item_of).collect())
        .unwrap_or_default();
    if items.is_empty() {
        return Err(format!(
            "{what} 没解析出条目（results 为空；可能真的没有结果，也可能接口改版 —— 不把它说成「0 条」）"
        ));
    }
    let page_count = v
        .get("total_pages")
        .and_then(|x| x.as_u64())
        .map(|n| n as u32)
        .filter(|n| *n > 0);
    let total = v
        .get("total_count")
        .and_then(|x| x.as_u64())
        .filter(|n| *n > 0);
    Ok(CspList {
        items,
        page,
        page_count,
        total,
    })
}

/// 详情元数据（`data` 里 title/description/cover）
pub fn detail_of(v: &Value, id: &str) -> Result<CspDetail, String> {
    let data = v.get("data").unwrap_or(v);
    let title = str_of(data, "title");
    if title.is_empty() {
        return Err(format!("条目 {id} 的详情里没有 title（接口改版或条目已下架）"));
    }
    let mut desc = str_of(data, "description");
    if desc.is_empty() {
        let actors = str_of(data, "actors");
        if !actors.is_empty() {
            desc = format!("主演：{actors}");
        }
    }
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover: nonempty(str_of(data, "cover")).or_else(|| nonempty(str_of(data, "backdrop_url"))),
        description: nonempty(desc),
        episodes: Vec::new(),
    })
}

/// 资源列表 → 剧集
///
/// 真站 200 时的字段在 DEX 里是：
/// `resource_type` / `description` / `title` / `resolution_display` / `source_display`，
/// 链接相关：`url` / `access_endpoint` / `target` / `access_ticket` / `extraction_code`。
/// ⚠️ 本仓**没有登录 token ⇒ 见不到 200 的响应**，所以这里只做"能识别就取"的防御式解析，
///    并在 `.probe/csp-app-live.log` 如实登记"未取证 200 形态"。
pub fn parse_resources(v: &Value) -> Vec<CspEpisode> {
    let root = v.get("data").unwrap_or(v);
    let arr = root
        .get("resources")
        .and_then(|x| x.as_array())
        .or_else(|| root.get("list").and_then(|x| x.as_array()))
        .or_else(|| root.as_array());
    let Some(arr) = arr else { return Vec::new() };
    let mut out: Vec<CspEpisode> = Vec::new();
    for r in arr {
        let url = ["url", "access_endpoint", "target", "link", "share_url"]
            .iter()
            .map(|k| str_of(r, k))
            .find(|s| !s.is_empty())
            .unwrap_or_default();
        if !crate::tvbox::starts_http(&url) && !url.starts_with("magnet:") {
            continue;
        }
        let mut title = str_of(r, "title");
        if title.is_empty() {
            title = str_of(r, "description");
        }
        if title.is_empty() {
            title = str_of(r, "resource_description");
        }
        let mut extra: Vec<String> = Vec::new();
        for k in ["resolution_display", "source_display", "resource_type"] {
            let s = str_of(r, k);
            if !s.is_empty() {
                extra.push(s);
            }
        }
        if !extra.is_empty() {
            let suffix = extra.join(" · ");
            title = if title.is_empty() { suffix } else { format!("{title} · {suffix}") };
        }
        if title.is_empty() {
            title = format!("资源 {}", out.len() + 1);
        }
        let id = format!("res|{url}");
        if out.iter().any(|e| e.id == id) {
            continue;
        }
        out.push(CspEpisode {
            id,
            title,
            flag: "资源".to_string(),
        });
        if out.len() >= 200 {
            break;
        }
    }
    out
}

/// 未登录时的**状态行**（不可播）：把原因带到 UI，而不是伪造一集正片
pub fn need_login_episode(id: &str) -> CspEpisode {
    CspEpisode {
        id: format!("{NEED_LOGIN_PREFIX}{id}"),
        title: "未登录：资源列表需登录后获取（此条不可播）".to_string(),
        flag: "登录".to_string(),
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Juying {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = Self::host_of(ext);
        let token = Self::token_of(ext);
        let categories: Vec<CspCategory> = TYPES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        // 首屏：电影第一页（真数据；取不到就 Err，而不是"分类在、内容空"）
        let url = format!("{host}/api/app/movies/?type=movie&page=1&page_size={PAGE_SIZE}");
        let v = self.get_json(&url, token.as_deref()).await?;
        let list = parse_list(&v, 1, "Juying 首页（电影）")?;
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
        let host = Self::host_of(ext);
        let token = Self::token_of(ext);
        let page = if page == 0 { 1 } else { page };
        // tid 支持 `type|category|year` 三段（DEX 的筛选维度），也兼容只给 type
        let mut parts = tid.split('|');
        let ty = parts.next().unwrap_or("").trim();
        if ty.is_empty() {
            return Err(format!("分类 id 不是 `type[|category|year]` 形态：{tid}"));
        }
        let mut url = format!("{host}/api/app/movies/?type={ty}&page={page}&page_size={PAGE_SIZE}");
        if let Some(cat) = parts.next().map(str::trim).filter(|s| !s.is_empty()) {
            url.push_str(&format!("&category={}", encode_path(cat)));
        }
        if let Some(year) = parts.next().map(str::trim).filter(|s| !s.is_empty()) {
            url.push_str(&format!("&year={}", encode_path(year)));
        }
        let v = self.get_json(&url, token.as_deref()).await?;
        parse_list(&v, page, &format!("Juying 分类 {tid}"))
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let host = Self::host_of(ext);
        let token = Self::token_of(ext);
        let v = self
            .get_json(&format!("{host}/api/app/movie/{id}/detail/"), token.as_deref())
            .await?;
        let mut d = detail_of(&v, id)?;

        // 资源列表：需要登录。401 是**已知门槛**（真站实测），不是"站点挂了"
        let res_url = format!("{host}/api/app/movie/{id}/resources/");
        match self.get_json(&res_url, token.as_deref()).await {
            Ok(rv) => {
                d.episodes = parse_resources(&rv);
                if d.episodes.is_empty() {
                    return Err(format!(
                        "条目 {id} 的资源列表能取到，但没解析出任何链接（接口可能改版）——\
                         不返回「0 集」的假成功"
                    ));
                }
            }
            Err(e) if e.contains("HTTP 401") => {
                d.episodes = vec![need_login_episode(id)];
            }
            Err(e) => {
                return Err(format!(
                    "条目 {id} 的详情可读，但资源列表取不到：{e}\
                     （若是登录门槛请配置 token；本类不伪造占位集之外的任何链接）"
                ));
            }
        }
        Ok(d)
    }

    /// 搜索：`/api/app/movies/?q=<kw>&page=<n>&page_size=24&fuzzy=true`（DEX 逐字）
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let host = Self::host_of(ext);
        let token = Self::token_of(ext);
        let page = if page == 0 { 1 } else { page };
        let url = format!(
            "{host}/api/app/movies/?q={}&page={page}&page_size={PAGE_SIZE}&fuzzy=true",
            encode_path(kw)
        );
        let v = self.get_json(&url, token.as_deref()).await?;
        parse_list(&v, page, &format!("Juying 搜索「{kw}」"))
    }

    /// 取流
    ///
    /// ```text
    /// · `juying-need-login|id` → 明确说"要登录"，不伪造地址
    /// · 资源行 `res|<url>`     → 直链媒体才放行；网盘/磁力页需要账号+转发 ⇒ 如实拒绝
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let raw = id.trim();
        if let Some(movie) = raw.strip_prefix(NEED_LOGIN_PREFIX) {
            return Err(format!(
                "条目 {movie} 的资源列表需要登录才能取（配置中心-其他-聚影登录，或在 ext 里给 token）；\
                 未登录时本类不返回任何播放地址"
            ));
        }
        let url = raw.strip_prefix("res|").unwrap_or(raw);
        if !crate::tvbox::starts_http(url) {
            return Err(format!(
                "播放 id 不是可识别的资源链接（{raw}）——磁力/网盘分享页需要账号与转发服务，本仓不伪造直链"
            ));
        }
        let lower = url.to_ascii_lowercase();
        if lower.contains(".m3u8") || lower.contains(".mp4") {
            return Ok(vec![CspPlay {
                url: url.to_string(),
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some("直链".to_string()),
            }]);
        }
        Err(format!(
            "这条资源链接不是直链媒体（{url}）：转直链需要登录网盘账号 + 本机转发服务，本仓两者都没有 ⇒ 不伪造地址"
        ))
    }
}

fn encode_path(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.as_bytes() {
        match *b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

// ═══════════════════════════════════════════════════════════════════════
//  ★ 自注册（三条判据：①订阅 1 站 ②host 可用 ③真网取到数据）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// ① 订阅：`csp_Juying` = 1 站（聚影丨4K网盘，ext=null）
// ② host：DEX `SITE` = https://www.jying.top，直连 200
// ③ 真网：list 24 条（total 38832）/ search 10 条 / detail 「红海」；
//    资源列表 401（登录门槛，已登记，不据此判"站点死"）
// ⇒ 注册
// ```
crate::csp::register_site!(Juying);

// ═══════════════════════════════════════════════════════════════════════
//  测试（真响应片段；纯函数）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 真站列表片段（2026-10-28 直连 `/api/app/movies/?type=movie&page=1&page_size=24`，
    /// 只截取 2 条 `results` 的字段，值逐字）
    const LIST: &str = r#"{
      "status": "success", "page": 1, "page_size": 24,
      "total_pages": 1618, "total_count": 38832, "count": 38832,
      "has_more": true, "next_cursor": "118784",
      "results": [
        {"id": 118814, "title": "克拉姆一家", "description": "克拉姆是一个非常普通的家庭…",
         "cover": "https://www.jying.top/media/covers/2026/10/a.jpg",
         "backdrop_url": "https://image.tmdb.org/t/p/w1280/b.jpg",
         "release_year": 2016, "resource_count": 13},
        {"id": 52826, "title": "红海", "cover": "https://www.jying.top/media/covers/2026/08/c.jpg",
         "backdrop_url": "https://image.tmdb.org/t/p/w1280/d.jpg",
         "release_year": 2016, "resource_count": 13}
      ]
    }"#;

    /// 真站详情片段（`/api/app/movie/52826/detail/`，字段与值逐字，描述截断）
    const DETAIL: &str = r#"{"status":"success","data":{
      "id":52826,"title":"红海",
      "description":"生命起源于水中，随后登陆陆地。它征服了我们的星球。",
      "cover":"https://www.jying.top/media/covers/2026/08/%E7%BA%A2%E6%B5%B7_97d01a26.jpg",
      "backdrop_url":"https://image.tmdb.org/t/p/w1280/dotEMpAXmAp6lAYulMVK4lqKFiX.jpg",
      "release_year":2016,"resource_count":13
    }}"#;

    /// 真站的 401（`/api/app/movie/52826/resources/`，逐字）
    const UNAUTH: &str = r#"{"status":"error","message":"\u672a\u767b\u5f55\uff0c\u8bf7\u5148\u767b\u5f55"}"#;

    fn j(s: &str) -> serde_json::Value {
        crate::tvbox::parse_loose_json(s).expect("fixture 必须是合法 JSON")
    }

    #[test]
    fn class_name_and_host_and_token() {
        assert_eq!(Juying::CLASS, "Juying");
        assert_eq!(Juying::host_of(""), DEFAULT_HOST);
        assert_eq!(Juying::host_of("null"), DEFAULT_HOST);
        assert_eq!(Juying::host_of(r#"{"site":["https://h.example/"]}"#), "https://h.example");
        assert_eq!(Juying::host_of(r#"{"host":"https://h2.example"}"#), "https://h2.example");
        assert_eq!(Juying::token_of(r#"{"token":"abc"}"#).as_deref(), Some("abc"));
        assert_eq!(Juying::token_of("null"), None);
    }

    #[test]
    fn list_parses_real_fields() {
        let l = parse_list(&j(LIST), 1, "Juying 分类 movie").expect("真响应应能解析");
        assert_eq!(l.items.len(), 2);
        assert_eq!(l.items[0].id, "118814");
        assert_eq!(l.items[0].title, "克拉姆一家");
        assert_eq!(l.items[0].subtitle.as_deref(), Some("2016 · 13 个资源"));
        assert!(l.items[1].cover.as_deref().unwrap_or("").contains("/media/covers/"));
        assert_eq!(l.page_count, Some(1618));
        assert_eq!(l.total, Some(38832));
    }

    /// ★ 契约第 1 条：results 为空 ⇒ Err（不是 Ok(空列表)）
    #[test]
    fn empty_results_is_error_not_empty_list() {
        let v = j(r#"{"status":"success","page":1,"total_pages":0,"results":[]}"#);
        let e = parse_list(&v, 1, "Juying 搜索「zzz」").expect_err("空 results 必须 Err");
        assert!(e.contains("没解析出条目"), "{e}");
        // 上游业务失败（status != success）也要原样带出 message
        let e2 = parse_list(&j(UNAUTH), 1, "Juying 列表").expect_err("status=error 必须 Err");
        assert!(e2.contains("status=error"), "{e2}");
        assert!(e2.contains("未登录"), "{e2}");
    }

    #[test]
    fn detail_parses_title_and_description() {
        let d = detail_of(&j(DETAIL), "52826").expect("详情应能解析");
        assert_eq!(d.id, "52826");
        assert_eq!(d.title, "红海");
        assert!(d.description.as_deref().unwrap_or("").contains("生命起源于水中"));
        assert!(d.cover.as_deref().unwrap_or("").contains("covers"));
        // 没有 title ⇒ Err（不返回"标题为空"的详情）
        assert!(detail_of(&j(r#"{"status":"success","data":{"id":1}}"#), "1").is_err());
    }

    /// ★★ 未登录：**一条明确不可播的状态行**，而不是"0 集"或伪造链接
    #[test]
    fn need_login_row_is_explicitly_unplayable() {
        let ep = need_login_episode("52826");
        assert_eq!(ep.id, "juying-need-login|52826");
        assert!(ep.title.contains("不可播"), "{}", ep.title);
        assert!(ep.title.contains("未登录"), "{}", ep.title);
        assert_eq!(ep.flag, "登录");
        // 401 必须能被 `detail` 的那条 `HTTP 401` 分支识别
        let flat = crate::csp::shared::impl_src_only(include_str!("juying.rs"));
        // ⚠️ `impl_src_only` 会把**字符串字面量里的空白也去掉** ⇒ 断言里写 `HTTP401`
        assert!(flat.contains(r#"e.contains("HTTP401")"#), "★ 401 必须单独分流");
    }

    #[test]
    fn resources_parse_defensively() {
        let v = j(r#"{"status":"success","data":{"resources":[
          {"title":"4K 原盘","resolution_display":"2160P","source_display":"夸克",
           "url":"https://pan.quark.cn/s/abc"},
          {"description":"1080P","access_endpoint":"https://example.com/x.m3u8"},
          {"title":"没有链接"}
        ]}}"#);
        let eps = parse_resources(&v);
        assert_eq!(eps.len(), 2, "{eps:?}");
        assert_eq!(eps[0].flag, "资源");
        assert!(eps[0].title.contains("4K 原盘"));
        assert!(eps[0].title.contains("2160P"));
        assert_eq!(eps[1].id, "res|https://example.com/x.m3u8");
        assert!(parse_resources(&j(r#"{"data":[]}"#)).is_empty());
    }

    #[test]
    fn play_refuses_login_status_and_netdisk_links() {
        let flat = crate::csp::shared::impl_src_only(include_str!("juying.rs"));
        assert!(flat.contains("NEED_LOGIN_PREFIX"), "★ 必须先拦状态行");
        assert!(flat.contains("不伪造地址") || flat.contains("不返回任何播放地址"));
    }

    #[test]
    fn http_client_disables_proxy_after_timeout() {
        let flat = crate::csp::shared::impl_src_only(include_str!("juying.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("timeout");
        let p = flat.find(".no_proxy()").expect("★ no_proxy 必须存在");
        let b = flat.find(".build()").expect("build");
        assert!(t < p && p < b, "timeout → no_proxy → build");
    }

    #[test]
    fn juying_is_registered() {
        assert!(crate::csp::is_implemented("csp_Juying"), "★ 三条判据成立 ⇒ 必须注册");
        let flat = crate::csp::shared::impl_src_only(include_str!("juying.rs"));
        assert!(flat.contains("register_site!(Juying)"));
    }

    /// 真网络（`#[ignore]`，必须显式点名 + `CSP_LIVE=1`）
    ///
    /// ★ 会**有意**走到 401：资源列表需要登录。这里断言的不是"能播"，
    ///   而是"401 被当成登录门槛记下来，且详情仍有可读元数据"。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp::juying:: -- --ignored --nocapture"]
    async fn csp_live_juying_home_list_search_detail() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：显式跑就必须给 CSP_LIVE=1（不给就失败）"
        );
        let site = Juying::new();
        // 订阅里 ext = null ⇒ 走 DEX 的 SITE
        let ext = "";

        let home = site.home(ext).await.expect("home 应成功");
        eprintln!(
            "[LIVE] Juying home: {} 分类 / {} 条目; 分类={:?}",
            home.categories.len(),
            home.items.len(),
            home.categories.iter().map(|c| format!("{}:{}", c.id, c.name)).collect::<Vec<_>>()
        );
        assert_eq!(home.categories.len(), 5);
        assert!(!home.items.is_empty());

        let list = site.list("tv", 1, ext).await.expect("list(tv) 应成功");
        eprintln!("[LIVE] Juying list(tv) ⇒ {} 条 / total={:?}", list.items.len(), list.total);
        assert!(!list.items.is_empty());

        let kw = "红海";
        let found = site.search(kw, 1, ext).await.expect("search 应成功");
        eprintln!("[LIVE] Juying search({kw}) ⇒ {} 条; 首条={:?}", found.items.len(), found.items[0].title);
        assert!(!found.items.is_empty());

        let id = found.items[0].id.clone();
        match site.detail(&id, ext).await {
            Ok(d) => {
                eprintln!(
                    "[LIVE] Juying detail({id}) ⇒ 标题={:?} 集数={} （未登录 ⇒ 应是 1 条状态行）",
                    d.title,
                    d.episodes.len()
                );
                for e in d.episodes.iter().take(3) {
                    eprintln!("[LIVE]   - {} {} {}", e.flag, e.title, e.id);
                }
                assert_eq!(d.episodes.len(), 1, "未登录时应恰好是 1 条状态行");
                assert!(d.episodes[0].id.starts_with(NEED_LOGIN_PREFIX));
            }
            Err(e) => {
                // 若上游把 401 换成别的形态，如实打印（不把失败硬说成通过）
                eprintln!("[LIVE] Juying detail({id}) 失败：{e}");
                panic!("detail 不应失败：{:?}", e);
            }
        }
    }
}
