// ═══════════════════════════════════════════════════════════════════════
//  csp_WebDAV —— 「把 WebDAV 挂成片源」的 Rust 实现（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（DEX 常量逐字，`.probe/csp-parity/WebDAV.txt` + `dex_const_strings.py`）
// ```text
// parent  = Lcom/github/catvod/crawler/Spider;
// 方法     init / load / ls / byName / ensureSlash / userFileMtime
//          homeContent / categoryContent / detailContent / playerContent
// 字段     FILE_PIC ext loaded servers userMtime vodPic
//
// load（逐字）：
//   "{" / "drives" / "server" / "user" / "pass" / "name" / "Basic " / "UTF-8"
//   "/" / "http" / "vodPic" / "webdav_user.json"
// ls（逐字）："" / "/" / "//"
// categoryContent（逐字）：
//   vod_id / vod_name / vod_pic / vod_tag(folder|file) / vod_remarks
//   page / pagecount / limit / total / list
// detailContent（逐字）：
//   "." / "" / "//" / vod_id / vod_name / vod_play_from = 「WebDAV」/
//   type_name = 「文件夹」/ `$` / `#` / vod_play_url / list
// playerContent（逐字）：url
// ```
// ★ `load` 的键序还原出 ext 形状：`{"drives":[{"name":…,"server":…,"user":…,"pass":…}]}`，
//   认证头是 `Basic ` + base64(`user:pass`)；`webdav_user.json` 是原版的本机凭据缓存
//   （本实现不落盘密码 —— 凭据只从 ext 读，见下）。
//
// # ★ 为什么**没有** `register_site!`（三条判据逐条对照）
// ```text
// ① 订阅（100 站）里 `csp_WebDAV` = **0 站**（私人网盘不可能写进公共订阅）❌
// ② host/账号：**只能来自 ext** —— DEX 的 `load` 只从 ext（或本机缓存文件）取
//    server/user/pass，没有任何默认地址 ❌
// ③ 真网读数：无账号 ⇒ 无法取证（本轮如实登记）❌
// ⇒ **做实现、不注册**（注册 = state.rs 里多一条点进去只会说「请填地址」的空源）
// ```
//
// # ext 的两种形态
// ```text
// ① 多盘：{"drives":[{"name":"我的盘","server":"https://dav.example/dav","user":"u","pass":"p"}]}
// ② 单盘：{"server":"https://dav.example/dav","user":"u","pass":"p","name":"我的盘"}
//    ★ 也接受 {"site":["https://dav.example/dav"]}（匿名 DAV；没有账号时仍可读公开目录）
// ```
//
// # 与 DEX 的两处**有据**差异
// ```text
// ① **不写** `webdav_user.json`：把账号密码落盘是原版的历史做法，本仓不新增凭据文件
//    （凭据只从 ext 读；用户要改就改配置）。
// ② 不引用 DEX 的远程默认封面（第三方图床 URL）：离线/私网源不该依赖外网。
// ```
//
// # 代理纪律
// ```text
// client 在 `.timeout(TIMEOUT)` 之后、`.build()` 之前显式 `.no_proxy()`
// （本机系统代理会把内网/公网 DAV 的 207 变成 502，从而误判「站点死」）。
// ```
//
// # 真网读数（如实）
// ```text
// 无任何 WebDAV 账号 ⇒ **未取真网读数**（0 次对外请求）。
// 本文件的测试用**本机 stub** 跑真实 HTTP 往返（PROPFIND + 207 + 多状态 XML），
// 证明「请求头（Depth/Authorization/Body）→ 解析 → 条目/取流」这条链是真的；
// 但它不冒充「某个真实 DAV 服务可用」。
// ```

use async_trait::async_trait;
use std::time::Duration;

use crate::csp::shared::b64_encode;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// UA（与 DEX 的 `init` 同风格；DAV 服务不看 UA，但有些反代看）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(20);

/// 一页多少条（DEX 有 limit/total 分页）
const PAGE_SIZE: usize = 100;

/// PROPFIND 请求体（只取三样：类型/大小/修改时间）
const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:getcontentlength/>
    <D:getlastmodified/>
  </D:prop>
</D:propfind>"#;

/// 扩展名（与 LocalFile 的 DEX `checkstring` 同源；这里独立一份，避免两个类互相依赖）
const MEDIA_EXTS: &[&str] = &[
    ".flac", ".ape", ".avi", ".wmv", ".rm", ".3gp", ".mov", ".mp", ".m4", ".vob", ".ts", ".webm",
    ".dat", ".m3u", ".mkv", ".flv", ".aac", ".wma",
];

/// 一个 WebDAV 盘（DEX `servers` 里的一项）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DavServer {
    pub name: String,
    /// 站点根（可带路径前缀，如 `https://host/dav`）
    pub server: String,
    pub user: String,
    pub pass: String,
}

pub struct WebDAV {
    client: reqwest::Client,
}

impl WebDAV {
    pub const CLASS: &'static str = "WebDAV";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // ★ 直连（真发 HTTP 的类必须关代理；判据会按 Client::builder() 扫）
            .no_proxy()
            .build()
            .expect("build webdav http client");
        Self { client }
    }

    /// ext → 盘列表（drives 数组 / 单盘对象 / site 数组）
    pub fn servers_of(ext: &str) -> Vec<DavServer> {
        let mut out: Vec<DavServer> = Vec::new();
        let Ok(v) = serde_json::from_str::<serde_json::Value>(ext.trim()) else {
            return out;
        };
        if let Some(arr) = v.get("drives").and_then(|x| x.as_array()) {
            for d in arr {
                if let Some(s) = server_of_value(d) {
                    out.push(s);
                }
            }
        }
        if out.is_empty() {
            if let Some(s) = server_of_value(&v) {
                out.push(s);
            }
        }
        if out.is_empty() {
            if let Some(arr) = v.get("site").and_then(|x| x.as_array()) {
                for (i, u) in arr.iter().filter_map(|x| x.as_str()).enumerate() {
                    let server = u.trim().trim_end_matches('/').to_string();
                    if server.starts_with("http") {
                        out.push(DavServer {
                            name: format!("网盘{}", i + 1),
                            server,
                            user: String::new(),
                            pass: String::new(),
                        });
                    }
                }
            }
        }
        out
    }

    fn need_servers(ext: &str) -> Result<Vec<DavServer>, String> {
        let list = Self::servers_of(ext);
        if list.is_empty() {
            return Err("WebDAV 需要 ext 里的服务地址与账号（形如 \
                        {\"drives\":[{\"name\":\"我的盘\",\"server\":\"https://dav.example/dav\",\
                        \"user\":\"…\",\"pass\":\"…\"}]}）——当前配置没给，无法列目录"
                .to_string());
        }
        Ok(list)
    }

    /// 认证头（`Basic base64(user:pass)`；账号密码都空 ⇒ 不带）
    pub fn auth_header(srv: &DavServer) -> Option<String> {
        if srv.user.is_empty() && srv.pass.is_empty() {
            return None;
        }
        let raw = format!("{}:{}", srv.user, srv.pass);
        Some(format!("Basic {}", b64_encode(raw.as_bytes())))
    }

    /// `https://host:8443/dav/` → `https://host:8443`（拼 XML 里的 href 用）
    pub fn origin(server: &str) -> String {
        let s = server.trim().trim_end_matches('/');
        match s.find("://") {
            Some(i) => match s[i + 3..].find('/') {
                Some(j) => s[..i + 3 + j].to_string(),
                None => s.to_string(),
            },
            None => s.to_string(),
        }
    }

    /// 服务根 + href → 可请求的 URL
    pub fn url_of(server: &str, href: &str) -> String {
        let h = href.trim();
        if h.starts_with("http://") || h.starts_with("https://") {
            return h.to_string();
        }
        let origin = Self::origin(server);
        if h.starts_with('/') {
            format!("{origin}{h}")
        } else {
            format!("{origin}/{h}")
        }
    }

    fn make_tid(idx: usize, path: &str) -> String {
        format!("{idx}|{path}")
    }

    /// tid：`N`（盘根）或 `N|/href/path`
    pub fn parse_tid(tid: &str) -> Result<(usize, String), String> {
        let t = tid.trim();
        if t.is_empty() {
            return Err("分类 id 为空（首页没给出盘）".to_string());
        }
        match t.split_once('|') {
            None => {
                let idx = t
                    .parse::<usize>()
                    .map_err(|_| format!("分类 id 不是「盘序号」形态：{tid}"))?;
                Ok((idx, "/".to_string()))
            }
            Some((a, p)) => {
                let idx = a
                    .trim()
                    .parse::<usize>()
                    .map_err(|_| format!("分类 id 不是「盘序号|路径」形态：{tid}"))?;
                let path = if p.trim().is_empty() {
                    "/".to_string()
                } else {
                    p.trim().to_string()
                };
                Ok((idx, path))
            }
        }
    }

    async fn propfind(&self, srv: &DavServer, path: &str) -> Result<String, String> {
        let url = Self::url_of(&srv.server, path);
        let mut req = self
            .client
            .request(reqwest::Method::from_bytes(b"PROPFIND").expect("PROPFIND 是合法方法名"), &url)
            // ★ `reqwest::header` 没有 DEPTH 常量（DAV 的自定义头不在那套表里）；
            //   用**小写字面量**：http 的 HeaderName::from_static 要求小写，否则运行期 panic。
            .header("depth", "1")
            .header(reqwest::header::CONTENT_TYPE, "application/xml; charset=utf-8")
            .header(reqwest::header::ACCEPT, "application/xml, text/xml, */*")
            .body(PROPFIND_BODY);
        if let Some(a) = Self::auth_header(srv) {
            req = req.header(reqwest::header::AUTHORIZATION, a);
        }
        let resp = req.send().await.map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if status.as_u16() == 401 || status.as_u16() == 403 {
            return Err(format!(
                "HTTP {}（{url}）：账号/密码不对，或该盘不允许这个账号读目录",
                status.as_u16()
            ));
        }
        if !status.is_success() {
            return Err(format!(
                "HTTP {}（{url}）：{}",
                status.as_u16(),
                text.chars().take(140).collect::<String>().replace('\n', " ")
            ));
        }
        Ok(text)
    }

    async fn listing(&self, srv: &DavServer, idx: usize, path: &str) -> Result<DavListing, String> {
        let xml = self.propfind(srv, path).await?;
        let (self_is_dir, items) = parse_multistatus(&xml, path);
        let items: Vec<CspItem> = items
            .into_iter()
            .map(|mut it| {
                it.id = Self::make_tid(idx, &it.id);
                it
            })
            .collect();
        Ok(DavListing {
            self_is_dir,
            items,
        })
    }
}

/// 一次 PROPFIND 的结果
struct DavListing {
    /// 被请求的这条自身是不是集合（文件夹）
    self_is_dir: bool,
    /// 子项（已去掉自身）
    items: Vec<CspItem>,
}

impl Default for WebDAV {
    fn default() -> Self {
        Self::new()
    }
}

fn server_of_value(v: &serde_json::Value) -> Option<DavServer> {
    let server = v
        .get("server")
        .and_then(|x| x.as_str())
        .map(|s| s.trim().trim_end_matches('/').to_string())
        .filter(|s| s.starts_with("http"))?;
    let name = v
        .get("name")
        .and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| WebDAV::origin(&server));
    Some(DavServer {
        name,
        server,
        user: v.get("user").and_then(|x| x.as_str()).unwrap_or("").trim().to_string(),
        pass: v.get("pass").and_then(|x| x.as_str()).unwrap_or("").to_string(),
    })
}

/// 多状态 XML → (自身是否文件夹, 子项)
///
/// # 为什么用正则切 `<…:response` 而不是 XML 解析器
/// ```text
/// 本仓不新增运行时依赖（诚实契约第 4 条），而 PROPFIND 的响应形状非常固定：
/// 每个条目都在一个 `<前缀:response>` 里，含 `<前缀:href>`、可选 `<前缀:collection/>`、
/// `<前缀:getcontentlength>`、`<前缀:getlastmodified>`。
/// ⇒ 按前缀**通配**（`[A-Za-z0-9]+`）切块，避免绑定 `D:` / `d:` / `lp1:` 某一种前缀。
/// ```
pub fn parse_multistatus(xml: &str, requested_path: &str) -> (bool, Vec<CspItem>) {
    let re_start = regex::Regex::new(r"(?is)<[a-z0-9]+:response\b").expect("dav response");
    let re_href = regex::Regex::new(r"(?is)<[a-z0-9]+:href[^>]*>([^<]*)<").expect("dav href");
    let re_coll =
        regex::Regex::new(r"(?is)<[a-z0-9]+:resourcetype[^>]*>\s*<[a-z0-9]+:collection")
            .expect("dav collection");
    let re_len = regex::Regex::new(r"(?is)<[a-z0-9]+:getcontentlength[^>]*>(\d+)<")
        .expect("dav len");
    let re_time = regex::Regex::new(r"(?is)<[a-z0-9]+:getlastmodified[^>]*>([^<]*)<")
        .expect("dav time");

    let starts: Vec<usize> = re_start.find_iter(xml).map(|m| m.start()).collect();
    let norm = |p: &str| p.trim().trim_end_matches('/').to_string();
    let want = norm(requested_path);

    let mut self_is_dir = false;
    let mut items: Vec<CspItem> = Vec::new();
    for (i, &start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(xml.len());
        let seg = &xml[start..end.min(xml.len())];
        let Some(href) = re_href.captures(seg).map(|c| c[1].trim().to_string()) else {
            continue;
        };
        let is_dir = re_coll.is_match(seg);
        /*
         * ★ 自身条目的两种形态：
         *   ① href 与请求路径逐字相同（子目录/文件）；
         *   ② 请求的是盘根（`/`）—— 此时服务端回的 href 是**服务自身的路径前缀**
         *      （如 `/dav/`），与我们请求的 `/` 不同 ⇒ 若只按字符串比，会把根目录自己
         *      当成一个名为 `dav` 的子文件夹列出来（真缺陷，空目录因此变成"1 条"）。
         * ⇒ 根请求时**第一条必是自身**（DAV 规范：multistatus 的第一条就是请求的资源）。
         */
        if norm(&href) == want || (want.is_empty() && i == 0) {
            self_is_dir = is_dir;
            continue;
        }
        let name = href
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .map(|s| urlencoding::decode(s).map(|c| c.into_owned()).unwrap_or_else(|_| s.to_string()))
            .unwrap_or_default();
        if name.is_empty() || name.starts_with('.') {
            continue;
        }
        if !is_dir && !is_media_name(&name) {
            // 非媒体的普通文件（字幕/封面/nfo）不列 —— 点了也放不了
            continue;
        }
        let subtitle = if is_dir {
            "文件夹".to_string()
        } else {
            let size = re_len
                .captures(seg)
                .and_then(|c| c[1].parse::<u64>().ok())
                .map(human_size)
                .unwrap_or_else(|| "文件".to_string());
            let when = re_time
                .captures(seg)
                .map(|c| c[1].trim().to_string())
                .unwrap_or_default();
            if when.is_empty() {
                size
            } else {
                format!("{size} · {when}")
            }
        };
        items.push(CspItem {
            id: href,
            title: name,
            cover: None,
            subtitle: Some(subtitle),
        });
        if items.len() >= 500 {
            break;
        }
    }
    // 文件夹在前，同类按名字
    items.sort_by(|a, b| {
        let af = a.subtitle.as_deref().unwrap_or("").starts_with("文件夹");
        let bf = b.subtitle.as_deref().unwrap_or("").starts_with("文件夹");
        bf.cmp(&af)
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    (self_is_dir, items)
}

/// 媒体扩展名（与 LocalFile 的 DEX 列表同源，独立一份避免跨类依赖）
pub fn is_media_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    MEDIA_EXTS.iter().any(|e| lower.ends_with(e))
        || lower.ends_with(".mp4")
        || lower.ends_with(".m4v")
}

fn human_size(n: u64) -> String {
    const KB: f64 = 1024.0;
    let f = n as f64;
    if f >= KB * KB * KB {
        format!("{:.1} GB", f / (KB * KB * KB))
    } else if f >= KB * KB {
        format!("{:.1} MB", f / (KB * KB))
    } else if f >= KB {
        format!("{:.0} KB", f / KB)
    } else {
        format!("{n} B")
    }
}

// ══ ⚠️ **没有 `register_site!`**（原因见文件头：缺 ①②③）══

#[async_trait]
impl CspSite for WebDAV {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let servers = Self::need_servers(ext)?;
        let categories: Vec<CspCategory> = servers
            .iter()
            .enumerate()
            .map(|(i, s)| CspCategory {
                id: i.to_string(),
                name: s.name.clone(),
            })
            .collect();
        // 首屏：第一个盘的根目录（取不到就 Err，而不是「盘在、内容空」）
        let l = self.listing(&servers[0], 0, "/").await?;
        if l.items.is_empty() {
            return Err(format!(
                "WebDAV 盘「{}」的根目录能打开，但里面没有可列出的文件夹或媒体文件",
                servers[0].name
            ));
        }
        Ok(CspHome {
            categories,
            items: l.items,
        })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let servers = Self::need_servers(ext)?;
        let (idx, path) = Self::parse_tid(tid)?;
        let srv = servers
            .get(idx)
            .ok_or_else(|| format!("盘序号 {idx} 超出范围（共 {} 个盘）", servers.len()))?;
        let l = self.listing(srv, idx, &path).await?;
        if l.items.is_empty() {
            return Err(format!(
                "WebDAV 路径「{path}」能打开，但没列出任何文件夹或媒体文件（空目录，或该账号没有读权限）"
            ));
        }
        let page = if page == 0 { 1 } else { page };
        let start = ((page as usize) - 1) * PAGE_SIZE;
        if start >= l.items.len() {
            if page > 1 {
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total: Some(l.items.len() as u64),
                });
            }
            return Err(format!("WebDAV 路径「{path}」里没有可列出的条目"));
        }
        let items: Vec<CspItem> = l.items.iter().skip(start).take(PAGE_SIZE).cloned().collect();
        let page_count = ((l.items.len() + PAGE_SIZE - 1) / PAGE_SIZE).max(1) as u32;
        Ok(CspList {
            items,
            page,
            page_count: Some(page_count),
            total: Some(l.items.len() as u64),
        })
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let servers = Self::need_servers(ext)?;
        let (idx, path) = Self::parse_tid(id)?;
        let srv = servers
            .get(idx)
            .ok_or_else(|| format!("盘序号 {idx} 超出范围（共 {} 个盘）", servers.len()))?;
        let l = self.listing(srv, idx, &path).await?;
        let name = path
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .map(|s| urlencoding::decode(s).map(|c| c.into_owned()).unwrap_or_else(|_| s.to_string()))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| srv.name.clone());

        if l.self_is_dir {
            let episodes: Vec<CspEpisode> = l
                .items
                .iter()
                .filter(|it| it.subtitle.as_deref().unwrap_or("").starts_with("文件夹") == false)
                .map(|it| CspEpisode {
                    id: it.id.clone(),
                    title: it.title.clone(),
                    flag: "WebDAV".to_string(),
                })
                .collect();
            if episodes.is_empty() {
                return Err(format!("文件夹「{name}」里没有可播放的媒体文件"));
            }
            return Ok(CspDetail {
                id: id.to_string(),
                title: name,
                cover: None,
                description: Some(format!("WebDAV 文件夹，共 {} 个媒体文件", episodes.len())),
                episodes,
            });
        }

        // 单文件：PROPFIND 的自身条目就是它
        if !is_media_name(&name) {
            return Err(format!("「{name}」不是可播放的媒体文件"));
        }
        Ok(CspDetail {
            id: id.to_string(),
            title: name.clone(),
            cover: None,
            description: None,
            episodes: vec![CspEpisode {
                id: id.to_string(),
                title: name,
                flag: "WebDAV".to_string(),
            }],
        })
    }

    /// 搜索：DAV 没有统一的搜索协议 ⇒ 明确不支持（DEX 也没有 searchContent）
    fn supports_search(&self) -> bool {
        false
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("WebDAV 不支持搜索：DAV 协议没有统一的全文检索，请在分类里逐级浏览".to_string())
    }

    /// 取流：媒体文件 → 直链 + `Authorization: Basic …`
    ///
    /// ★ 这不是「分享页当直链」：WebDAV 的文件 URL 本身就是可播的媒体所在，
    ///   认证走请求头（`CspPlay.headers` 会被 provider 带进播放器）。
    async fn play(&self, _flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let servers = Self::need_servers(ext)?;
        let (idx, path) = Self::parse_tid(id)?;
        let srv = servers
            .get(idx)
            .ok_or_else(|| format!("盘序号 {idx} 超出范围（共 {} 个盘）", servers.len()))?;
        let name = path
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .map(|s| urlencoding::decode(s).map(|c| c.into_owned()).unwrap_or_else(|_| s.to_string()))
            .unwrap_or_default();
        if path.ends_with('/') || name.is_empty() {
            return Err(format!("「{path}」是文件夹，不是可播放文件（请先进入文件夹选一集）"));
        }
        if !is_media_name(&name) {
            return Err(format!("「{name}」不是可识别的媒体文件（按扩展名判断）"));
        }
        let url = Self::url_of(&srv.server, &path);
        let mut headers: Vec<(String, String)> = vec![("User-Agent".to_string(), UA.to_string())];
        if let Some(a) = Self::auth_header(srv) {
            headers.push(("Authorization".to_string(), a));
        }
        Ok(vec![CspPlay {
            url,
            headers,
            label: Some("WebDAV".to_string()),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试（本机 stub：真实 HTTP 往返 + 真多状态 XML；不发外网）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    /// 根目录的多状态响应（真协议形状：D: 前缀 + collection + 长度）
    const ROOT_XML: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/%E7%94%B5%E5%BD%B1/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>
      <D:getlastmodified>Mon, 27 Oct 2026 10:00:00 GMT</D:getlastmodified></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/a.mp4</D:href>
    <D:propstat><D:prop><D:resourcetype/>
      <D:getcontentlength>2048</D:getcontentlength>
      <D:getlastmodified>Mon, 27 Oct 2026 11:00:00 GMT</D:getlastmodified></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/b.srt</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>10</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>"#;

    /// 文件夹的多状态响应
    const FOLDER_XML: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/dav/%E7%94%B5%E5%BD%B1/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/dav/%E7%94%B5%E5%BD%B1/01.mp4</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1024</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/dav/%E7%94%B5%E5%BD%B1/02.mkv</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>2048</D:getcontentlength></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>"#;

    const EMPTY_XML: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/dav/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
      <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>"#;

    #[derive(Debug, Clone)]
    struct Hit {
        method: String,
        target: String,
        depth: String,
        auth: String,
        body: String,
    }

    struct Stub {
        port: u16,
        hits: Arc<Mutex<Vec<Hit>>>,
    }

    impl Stub {
        fn ext(&self) -> String {
            format!(
                r#"{{"drives":[{{"name":"测试盘","server":"http://127.0.0.1:{}/dav","user":"u","pass":"p"}}]}}"#,
                self.port
            )
        }
        fn hits(&self) -> Vec<Hit> {
            self.hits.lock().map(|g| g.clone()).unwrap_or_default()
        }
    }

    /// 起一个一次性 PROPFIND 服务：`body_for(target)` 决定回什么
    fn start_stub(body_for: fn(&str) -> (u16, String)) -> Stub {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定本地端口失败");
        let port = listener.local_addr().expect("取本地端口").port();
        let hits: Arc<Mutex<Vec<Hit>>> = Arc::new(Mutex::new(Vec::new()));
        let hits2 = hits.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { break };
                let mut reader = BufReader::new(stream.try_clone().expect("clone stream"));
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    continue;
                }
                let mut depth = String::new();
                let mut auth = String::new();
                let mut len = 0usize;
                loop {
                    let mut h = String::new();
                    match reader.read_line(&mut h) {
                        Ok(0) => break,
                        Ok(_) => {
                            if h == "\r\n" || h == "\n" {
                                break;
                            }
                            // ★ 头名大小写不敏感，但**值区分大小写**（base64）⇒
                            //   用小写副本判"是哪个头"，从**原始行**取值。
                            let lower = h.to_ascii_lowercase();
                            if lower.starts_with("depth:") {
                                depth = h[6..].trim().to_string();
                            } else if lower.starts_with("authorization:") {
                                auth = h[14..].trim().to_string();
                            } else if lower.starts_with("content-length:") {
                                len = h[15..].trim().parse().unwrap_or(0);
                            }
                        }
                        Err(_) => break,
                    }
                }
                let mut body = vec![0u8; len];
                if len > 0 {
                    let _ = reader.read_exact(&mut body);
                }
                let method = line.split_whitespace().next().unwrap_or("").to_string();
                let target = line.split_whitespace().nth(1).unwrap_or("").to_string();
                if let Ok(mut g) = hits2.lock() {
                    g.push(Hit {
                        method,
                        target: target.clone(),
                        depth,
                        auth,
                        body: String::from_utf8_lossy(&body).to_string(),
                    });
                }
                let (status, body) = body_for(&target);
                let resp = format!(
                    "HTTP/1.1 {status} {}\r\nContent-Type: application/xml; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    if status == 207 { "Multi-Status" } else { "ERR" },
                    body.len(),
                    body
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.flush();
            }
        });
        Stub { port, hits }
    }

    fn body_for(target: &str) -> (u16, String) {
        if target.contains("%E7%94%B5%E5%BD%B1") {
            (207, FOLDER_XML.to_string())
        } else {
            (207, ROOT_XML.to_string())
        }
    }

    #[test]
    fn class_name_is_exact() {
        assert_eq!(WebDAV::CLASS, "WebDAV");
    }

    /// 大小格式化（独立向量，避免"解析器改了单位"被一条集成断言悄悄放过）
    #[test]
    fn human_size_units_are_pinned() {
        assert_eq!(human_size(512), "512 B");
        assert_eq!(human_size(1024), "1 KB");
        assert_eq!(human_size(2048), "2 KB");
        assert_eq!(human_size(1024 * 1024), "1.0 MB");
        assert_eq!(human_size(3 * 1024 * 1024 * 1024), "3.0 GB");
    }

    #[test]
    fn servers_of_reads_drives_single_and_site_forms() {
        let a = WebDAV::servers_of(
            r#"{"drives":[{"name":"甲","server":"https://d.example/dav/","user":"u","pass":"p"}]}"#,
        );
        assert_eq!(a.len(), 1);
        assert_eq!(a[0].name, "甲");
        assert_eq!(a[0].server, "https://d.example/dav");
        assert_eq!(a[0].user, "u");
        let b = WebDAV::servers_of(r#"{"server":"https://d2.example","user":"x"}"#);
        assert_eq!(b[0].server, "https://d2.example");
        assert_eq!(b[0].name, "https://d2.example", "没给 name 时用 origin 兜底");
        let c = WebDAV::servers_of(r#"{"site":["https://d3.example/dav"]}"#);
        assert_eq!(c[0].name, "网盘1");
        assert!(WebDAV::servers_of("").is_empty());
        assert!(WebDAV::servers_of("null").is_empty());
    }

    #[test]
    fn auth_header_is_basic_base64() {
        let s = DavServer {
            name: "x".into(),
            server: "https://d".into(),
            user: "user".into(),
            pass: "pass".into(),
        };
        // base64("user:pass") = dXNlcjpwYXNz
        assert_eq!(WebDAV::auth_header(&s).as_deref(), Some("Basic dXNlcjpwYXNz"));
        let anon = DavServer {
            name: "x".into(),
            server: "https://d".into(),
            user: String::new(),
            pass: String::new(),
        };
        assert_eq!(WebDAV::auth_header(&anon), None);
    }

    #[test]
    fn origin_and_url_join_keep_the_server_path_prefix() {
        assert_eq!(WebDAV::origin("https://h:8443/dav/"), "https://h:8443");
        assert_eq!(WebDAV::origin("https://h"), "https://h");
        assert_eq!(WebDAV::url_of("https://h/dav", "/dav/a.mp4"), "https://h/dav/a.mp4");
        assert_eq!(WebDAV::url_of("https://h/dav", "dav/a.mp4"), "https://h/dav/a.mp4");
        assert_eq!(WebDAV::url_of("https://h/dav", "https://x/y"), "https://x/y");
    }

    #[test]
    fn parse_tid_accepts_index_and_index_path() {
        assert_eq!(WebDAV::parse_tid("0").unwrap(), (0, "/".to_string()));
        assert_eq!(WebDAV::parse_tid("1|/dav/a/").unwrap(), (1, "/dav/a/".to_string()));
        assert!(WebDAV::parse_tid("").is_err());
        assert!(WebDAV::parse_tid("x|/a").is_err());
    }

    /// ★ 核心：真 HTTP 往返（PROPFIND + 207 + 多状态解析）
    #[tokio::test]
    async fn list_really_does_propfind_and_parses_multistatus() {
        let stub = start_stub(body_for);
        let ext = stub.ext();
        let l = WebDAV::new().list("0", 1, &ext).await.expect("列表应成功");
        let hits = stub.hits();
        assert_eq!(hits.len(), 1, "必须真发一次 PROPFIND：{hits:?}");
        assert_eq!(hits[0].method, "PROPFIND", "★ 方法必须是 PROPFIND");
        assert_eq!(hits[0].depth, "1", "★ 必须 Depth: 1");
        // ★ 请求头名会被 HTTP 栈小写化；认证值本身必须逐字（u:p）
        // ★ 头名会被 HTTP 栈小写化，但**认证值区分大小写**（base64）⇒ 原样比对
        assert_eq!(hits[0].auth, format!("Basic {}", b64_encode(b"u:p")), "★ 必须带 Basic 认证");
        assert!(hits[0].body.contains("getcontentlength"), "请求体要取长度：{}", hits[0].body);

        assert_eq!(l.items.len(), 2, "文件夹 + mp4（srt 被跳过）：{:?}", l.items);
        assert_eq!(l.items[0].title, "电影");
        assert_eq!(l.items[0].subtitle.as_deref(), Some("文件夹"));
        assert_eq!(l.items[1].title, "a.mp4");
        // 2048 B ⇒ 「2 KB」（KB 档取整）；同时钉住 getlastmodified 也被解析进来了
        assert_eq!(
            l.items[1].subtitle.as_deref(),
            Some("2 KB · Mon, 27 Oct 2026 11:00:00 GMT"),
            "★ 第二个条目的 size 与修改时间都必须解析进副标题：{:?}",
            l.items[1].subtitle
        );
        assert_eq!(l.total, Some(2));
    }

    #[tokio::test]
    async fn detail_folder_lists_media_and_file_is_single() {
        let stub = start_stub(body_for);
        let ext = stub.ext();
        let folder = WebDAV::new()
            .detail("0|/dav/%E7%94%B5%E5%BD%B1/", &ext)
            .await
            .expect("文件夹详情应成功");
        assert_eq!(folder.title, "电影");
        assert_eq!(folder.episodes.len(), 2, "{:?}", folder.episodes);
        assert_eq!(folder.episodes[0].flag, "WebDAV");

        let file = WebDAV::new()
            .detail("0|/dav/a.mp4", &ext)
            .await
            .expect("单文件详情应成功");
        assert_eq!(file.episodes.len(), 1);
        assert_eq!(file.episodes[0].title, "a.mp4");
    }

    #[tokio::test]
    async fn play_returns_direct_url_with_authorization_header() {
        let stub = start_stub(body_for);
        let run = |port: u16| async move {
            let ext = format!(
                r#"{{"drives":[{{"name":"测试盘","server":"http://127.0.0.1:{port}/dav","user":"u","pass":"p"}}]}}"#
            );
            WebDAV::new().play("WebDAV", "0|/dav/a.mp4", &ext).await
        };
        let got = run(stub.port).await.expect("取流应成功");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].url, format!("http://127.0.0.1:{}/dav/a.mp4", stub.port));
        assert_eq!(got[0].label.as_deref(), Some("WebDAV"));
        assert!(
            got[0]
                .headers
                .iter()
                .any(|(k, v)| k == "Authorization" && *v == format!("Basic {}", b64_encode(b"u:p"))),
            "★ 必须带 Basic 认证头：{:?}",
            got[0].headers
        );
        // 文件夹不可播
        let dir = WebDAV::new()
            .play("WebDAV", "0|/dav/%E7%94%B5%E5%BD%B1/", &stub.ext())
            .await
            .expect_err("文件夹不可播");
        assert!(dir.contains("文件夹"), "{dir}");
    }

    #[tokio::test]
    async fn empty_listing_is_error_not_empty_home() {
        let stub = start_stub(|_| (207, EMPTY_XML.to_string()));
        let e = WebDAV::new().home(&stub.ext()).await.expect_err("空根目录必须 Err");
        assert!(e.contains("没有可列出的文件夹或媒体文件"), "{e}");
    }

    #[tokio::test]
    async fn unauthorized_is_reported_as_account_problem_not_empty_content() {
        let stub = start_stub(|_| (401, "Unauthorized".to_string()));
        let e = WebDAV::new()
            .list("0", 1, &stub.ext())
            .await
            .expect_err("401 必须 Err");
        assert!(e.contains("401"), "{e}");
        assert!(e.contains("账号/密码不对"), "{e}");
    }

    #[tokio::test]
    async fn missing_ext_is_a_readable_error() {
        let e = WebDAV::new().home("").await.expect_err("无 ext 必须 Err");
        assert!(e.contains("ext"), "{e}");
        assert!(e.contains("drives"), "{e}");
        // 有 ext 但一个盘都没有
        let e2 = WebDAV::new().list("0", 1, "{}").await.expect_err("空对象必须 Err");
        assert!(e2.contains("ext"), "{e2}");
    }

    /// ★ 判据三条缺 ①②③ ⇒ 必须**不注册**
    #[test]
    fn webdav_must_not_be_registered_without_ext() {
        let flat = crate::csp::shared::impl_src_only(include_str!("webdav.rs"));
        assert!(!flat.contains("register_site!(WebDAV)"), "★ 无 ext 不许注册");
        assert!(
            !crate::csp::is_implemented("csp_WebDAV"),
            "★ 不许进注册表（否则会暴露一条只有「请填地址」的空源）"
        );
        assert!(!WebDAV::new().supports_search(), "★ DAV 无统一搜索 ⇒ 不许假能力位");
    }

    #[test]
    fn http_client_disables_proxy_after_timeout() {
        let flat = crate::csp::shared::impl_src_only(include_str!("webdav.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("timeout");
        let p = flat.find(".no_proxy()").expect("★ no_proxy 必须存在");
        let b = flat.find(".build()").expect("build");
        assert!(t < p && p < b, "timeout → no_proxy → build");
    }
}
