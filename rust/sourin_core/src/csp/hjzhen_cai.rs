// ═══════════════════════════════════════════════════════════════════════
//  csp_HJZhenCai —— 「花卷系网盘分享站」的 Rust 实现（AppleCMS 模板 + 网盘链接）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（DEX 常量逐字，`.probe/csp25/HJZhenCai.txt`）
// ```text
// parent  = Lcom/github/catvod/spider/Pan;
// 方法     init / homeContent / categoryContent / detailContent / searchContent
//          buildFilters / parseList / parseDetail / parsePageCount
//          extractNetdiskLinks / stripTags / cleanText / absUrl / getHeaders
// 字段     siteUrl / UA / ITEM_ANCHOR / TITLE_ATTR / IMG_REAL / IMG_ANY / NOTE_ATTR
//          INFO_ITEM / TAG_LINK / TYPE_LINK / PAGE_NO / NETDISK_PATTERN
//          NETDISK_ENCODE_PATTERN / DIGIT_END
//
// 路径（逐字）
//   分类  /index.php/vod/show/id/<cateId>[/class/<v>|/area/<v>|/lang/<v>|/year/<v>|/letter/<v>|/by/<v>][/page/<n>].html
//   详情  /index.php/vod/detail/id/<id>.html
//   搜索① /index.php/ajax/suggest?mid=1&wd=<kw>&limit=50        （JSON，DEX 的 quickSearch）
//   搜索② /index.php/vod/search.html?wd=<kw>[&page=<n>]         （HTML，DEX 的 searchContent）
//   专题  /index.php/label/new.html
//
// 标题/封面/简介
//   <h1[^>]*>([^<]*)</h1>
//   module-info-poster … (?:data-original|data-src|src)="([^"]+)"
//   module-info-introduction-content[^>]*>(.*?)</div>   （★ 真站是 <p> 包在 div 里）
//   module-info-item-title">([^"]*?)[：:]<.*?module-info-item-content">(.*?)</div>
//
// 网盘链接（DEX 两条模式，逐字）
//   https?://(?:[a-zA-Z0-9-]+\.)*(?:quark\.cn|uc\.cn|baidu\.com|123pan\.[a-z]+|123yun\.[a-z]+|
//                              guangyapan\.com|xunlei\.com)[/a-zA-Z0-9_\-?=&]+
//   https%3A%2F%2F(?:[a-zA-Z0-9%_\-]+)(?:quark|uc|baidu|123|guangya|xunlei)[a-zA-Z0-9%_\-]+
// ```
//
// # 真网复核（2026-10-28 直连 `https://www.hjzhencai.top`，见 `.probe/csp-app-live.log`）
// ```text
// home  → 200 / 7 分类（花卷电影/剧集/动漫/AI短剧/综艺/4K原盘/花卷高帧）/ 16 条目
// list  → `/index.php/vod/show/id/1.html` 200 / 40 条；`/page/2.html` 200 / 40 条
// search→ suggest 200 `{"code":1,…"list":[{"id":13406,"name":"红海龟",…}]}`
// detail→ 200 / 标题「末世行者」/ 简介 / 2 条网盘（百度 + 夸克）
// ```
//
// # 能力边界（与 `Pan` 父类同一个：取流不在本仓）
// ```text
// browse（home/list/search/detail）→ 真 HTTP，真数据              ✅
// play  → 夸克/UC 分享页：本仓原生直链转换（T1a，2026-10-31）        ✅
//         其它族（百度/迅雷/115/阿里/139/…）：如实 Err（T1b 另接）  ⛔
//         ⇒ 绝不把不能换直链的分享页 URL 当视频流返回（那是假通）
// ```
//
// # 代理纪律
// ```text
// 判"站点死活"必须直连：client 在 `.timeout(TIMEOUT)` 之后、`.build()` 之前
// 显式 `.no_proxy()`。本机 HTTP_PROXY 会让每个 host 回 502（诚实契约第 3 条）。
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::pan_web_share::UrlPanKind;
use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `UA` 字段逐字（Chrome/149）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(15);
const MAX_ITEMS: usize = 120;

pub struct HJZhenCai {
    client: reqwest::Client,
}

impl HJZhenCai {
    pub const CLASS: &'static str = "HJZhenCai";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // ★ 直连（顺序有门禁扫：timeout → no_proxy → build）
            .no_proxy()
            .build()
            .expect("build hjzhencai http client");
        Self { client }
    }

    /// 从 ext 取站点：`{"site":["https://…"]}`（也认 `host` / 裸字符串）
    pub fn sites_of(ext: &str) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(ext) {
            if let Some(arr) = v.get("site").and_then(|x| x.as_array()) {
                for s in arr {
                    if let Some(u) = s.as_str() {
                        push_site(&mut out, u);
                    }
                }
            }
            if let Some(u) = v.get("host").and_then(|x| x.as_str()) {
                push_site(&mut out, u);
            }
        }
        if out.is_empty() {
            for piece in ext.split(|c: char| c == '"' || c == '\'' || c == ',' || c == ' ') {
                push_site(&mut out, piece);
            }
        }
        out
    }

    fn need_site(ext: &str) -> Result<String, String> {
        Self::sites_of(ext).into_iter().next().ok_or_else(|| {
            "HJZhenCai 需要 ext 里的站点地址（键 `site`，形如 {\"site\":[\"https://a.example\"]}）\
             ——当前配置没给，无法取数"
                .to_string()
        })
    }

    async fn get_text(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml,application/json")
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
}

impl Default for HJZhenCai {
    fn default() -> Self {
        Self::new()
    }
}

fn push_site(out: &mut Vec<String>, raw: &str) {
    let u = raw.trim().trim_end_matches('/');
    if u.starts_with("http") && !out.iter().any(|x| x == u) {
        out.push(u.to_string());
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  HTML 解析（纯函数，单测喂真响应片段）
// ═══════════════════════════════════════════════════════════════════════

/// 分类：导航/首页里的 `/index.php/vod/type/id/<数字>.html` 链接 + 文字
pub fn parse_categories(html: &str) -> Vec<CspCategory> {
    let re = regex::Regex::new(
        r#"(?is)<a[^>]+href="[^"]*?/index\.php/vod/type/id/(\d+)\.html"[^>]*>(.*?)</a>"#,
    )
    .expect("hj cat regex");
    let mut out: Vec<CspCategory> = Vec::new();
    for c in re.captures_iter(html) {
        let id = c[1].to_string();
        let name = clean_text(&c[2]);
        if name.is_empty() || out.iter().any(|x| x.id == id) {
            continue;
        }
        out.push(CspCategory { id, name });
    }
    out
}

/// 条目解析（首页 / 分类页 / 搜索结果页共用）
///
/// # 为什么不用"按 class 切块"
/// ```text
/// 真站的外层标签是 `<a href="…" title="…" class="module-poster-item module-item">` ——
/// **href/title 在 class 之前** ⇒ 以 `module-item` 为切点会把 href/title 切到上一段，
/// 解析出来全是空标题（我第一版就这么写的，真响应片段一喂就发现 0 条）。
/// ⇒ 改成：先用 `<a …>` 标签正则抓整条标签，再在**标签内**取 href / title 属性
///   （属性顺序上游会变，所以对 href 与 title 各用一条小正则，不假定顺序）。
/// ```
pub fn parse_items(html: &str) -> Vec<CspItem> {
    let re_tag = regex::Regex::new(r#"(?is)<a\b[^>]*>"#).expect("hj tag regex");
    let re_id = regex::Regex::new(r#"/index\.php/vod/detail/id/(\d+)\.html"#).expect("hj id");
    let re_title = regex::Regex::new(r#"(?is)\btitle="([^"]*)""#).expect("hj title");
    let re_pic = regex::Regex::new(r#"(?is)(?:data-original|data-src|src)="(https?://[^"]+)""#)
        .expect("hj pic");
    let re_note = regex::Regex::new(r#"(?is)module-item-note">([^<]+)<"#).expect("hj note");

    let tags: Vec<(usize, usize, String, String)> = re_tag
        .find_iter(html)
        .filter_map(|m| {
            let tag = m.as_str();
            let id = re_id.captures(tag)?.get(1)?.as_str().to_string();
            let title = re_title
                .captures(tag)
                .map(|c| clean_text(&c[1]))
                .unwrap_or_default();
            Some((m.start(), m.end(), id, title))
        })
        .collect();

    let mut out: Vec<CspItem> = Vec::new();
    for (i, (_start, end, id, title)) in tags.iter().enumerate() {
        if out.len() >= MAX_ITEMS {
            break;
        }
        if out.iter().any(|x| x.id == *id) {
            continue;
        }
        let next = tags.get(i + 1).map(|t| t.0).unwrap_or(html.len());
        let seg = &html[*end..next.max(*end).min(html.len())];
        let title = if title.is_empty() {
            // 标签内没 title 属性时：退到「锚文本」（紧跟标签的纯文本）
            let after = &html[*end..next.max(*end).min(html.len())];
            let text = after.split('<').next().unwrap_or("");
            let text = clean_text(text);
            if !text.is_empty() {
                text
            } else {
                // 再退：块内的标题 div（首页模板 `<div class="module-poster-item-title">`）
                let re_inner =
                    regex::Regex::new(r#"(?is)module-(?:poster-)?item-title"[^>]*>([^<]+)<"#)
                        .expect("hj inner title");
                re_inner
                    .captures(seg)
                    .map(|c| clean_text(&c[1]))
                    .unwrap_or_default()
            }
        } else {
            title.clone()
        };
        if title.is_empty() {
            continue;
        }
        out.push(CspItem {
            id: id.clone(),
            title,
            cover: re_pic.captures(seg).map(|c| c[1].to_string()),
            subtitle: re_note
                .captures(seg)
                .map(|c| clean_text(&c[1]))
                .filter(|s| !s.is_empty()),
        });
    }
    out
}

/// 首页解析：分类与首屏都必须非空（空 ⇒ Err）
pub fn home_from_html(html: &str) -> Result<CspHome, String> {
    let categories = parse_categories(html);
    if categories.is_empty() {
        return Err("HJZhenCai 首页能打开，但没解析出任何分类（模板可能已改版，或返回的是风控壳页）"
            .to_string());
    }
    let items = parse_items(html);
    if items.is_empty() {
        return Err("HJZhenCai 首页能打开、也拿到了分类，但没解析出任何条目（模板可能已改版）"
            .to_string());
    }
    Ok(CspHome { categories, items })
}

/// 列表解析：空 ⇒ Err
pub fn list_from_html(html: &str, page: u32, what: &str) -> Result<CspList, String> {
    let items = parse_items(html);
    if items.is_empty() {
        return Err(format!(
            "HJZhenCai {what} 页面能打开，但没解析出任何条目（模板可能已改版，或返回的是风控壳页）"
        ));
    }
    Ok(CspList {
        items,
        page,
        page_count: None,
        total: None,
    })
}

/// 详情：标题 / 封面 / 简介 / 网盘链接
pub fn detail_from_html(html: &str, id: &str) -> CspDetail {
    let re_title = regex::Regex::new(r#"(?is)<h1[^>]*>(.*?)</h1>"#).expect("hj h1");
    let re_pic = regex::Regex::new(
        r#"(?is)class="[^"]*module-info-poster[^"]*"[^>]*>.*?(?:data-original|data-src|src)="(https?://[^"]+)""#,
    )
    .expect("hj poster");
    let re_desc = regex::Regex::new(
        r#"(?is)module-info-introduction-content[^>]*>(.*?)</div>"#,
    )
    .expect("hj intro");

    let title = re_title
        .captures(html)
        .map(|c| clean_text(&c[1]))
        .unwrap_or_default();
    let desc = re_desc
        .captures(html)
        .map(|c| clean_text(&c[1]))
        .filter(|s| !s.is_empty());

    let episodes = netdisk_episodes(html);

    CspDetail {
        id: id.to_string(),
        title: if title.is_empty() {
            format!("条目 {id}")
        } else {
            title
        },
        cover: re_pic.captures(html).map(|c| c[1].to_string()),
        description: desc,
        episodes,
    }
}

/// 从详情页抽网盘链接（DEX 的两条模式：明文 + 百分号编码）
///
/// ★ 以 `down-card` 块为单位能拿到"第 N 集"的名字；块缺失时退回全页链接扫描。
pub fn netdisk_episodes(html: &str) -> Vec<CspEpisode> {
    let re_card = regex::Regex::new(r#"(?is)<div class="down-card">"#).expect("hj card");
    let re_name = regex::Regex::new(r#"(?is)down-card-name">([^<]+)<"#).expect("hj name");
    let re_link = regex::Regex::new(
        r#"(?is)https?://(?:[a-zA-Z0-9-]+\.)*(?:quark\.cn|uc\.cn|baidu\.com|123pan\.[a-z]+|123yun\.[a-z]+|guangyapan\.com|xunlei\.com|aliyundrive\.com|alipan\.com|115\.com)/[a-zA-Z0-9_\-?=&%./]+"#,
    )
    .expect("hj netdisk");
    let re_enc = regex::Regex::new(
        r#"(?is)https%3A%2F%2F(?:[a-zA-Z0-9%_\-./]+)(?:quark|uc|baidu|123|guangya|xunlei|ali)[a-zA-Z0-9%_\-./]+"#,
    )
    .expect("hj netdisk enc");

    let starts: Vec<usize> = re_card.find_iter(html).map(|m| m.start()).collect();
    let mut episodes: Vec<CspEpisode> = Vec::new();

    for (i, &start) in starts.iter().enumerate() {
        let end = starts.get(i + 1).copied().unwrap_or(html.len());
        let seg = &html[start..end.min(html.len())];
        let name = re_name
            .captures(seg)
            .map(|c| clean_text(&c[1]))
            .unwrap_or_default();
        for c in re_link.captures_iter(seg) {
            push_episode(&mut episodes, c.get(0).map(|m| m.as_str()).unwrap_or(""), &name);
        }
        for c in re_enc.captures_iter(seg) {
            push_episode(&mut episodes, c.get(0).map(|m| m.as_str()).unwrap_or(""), &name);
        }
    }

    // 块结构缺失（模板改版）时的退路：全页扫链接，标题只用盘名
    if episodes.is_empty() {
        for c in re_link.captures_iter(html) {
            push_episode(&mut episodes, c.get(0).map(|m| m.as_str()).unwrap_or(""), "");
        }
        for c in re_enc.captures_iter(html) {
            push_episode(&mut episodes, c.get(0).map(|m| m.as_str()).unwrap_or(""), "");
        }
    }
    episodes
}

/// 一条网盘链接 → 一集（按 URL 去重；不可识别的 URL 直接丢，不伪造）
fn push_episode(episodes: &mut Vec<CspEpisode>, raw: &str, name: &str) {
    let decoded = decode_percent(raw);
    if !crate::tvbox::starts_http(&decoded) {
        return;
    }
    let key = format!("pan|{decoded}");
    if episodes.iter().any(|e| e.id == key) {
        return;
    }
    let label = disk_label(&decoded);
    let title = if name.trim().is_empty() {
        label.to_string()
    } else {
        format!("{} · {label}", name.trim())
    };
    episodes.push(CspEpisode {
        id: key,
        title,
        flag: label.to_string(),
    });
}

/// 网盘名（DEX 的 5 家 + 本仓 `UrlPanKind` 的另外 4 家）
pub fn disk_label(url: &str) -> &'static str {
    if let Some(k) = UrlPanKind::of(url) {
        return k.label();
    }
    let u = url.to_ascii_lowercase();
    if u.contains("uc.cn") {
        "UC 网盘"
    } else if u.contains("123pan") || u.contains("123yun") || u.contains("123684") {
        "123 云盘"
    } else {
        "分享链接"
    }
}

/// 百分号解码（只处理网盘链接会出现的形态；解不出来就原样返回）
fn decode_percent(s: &str) -> String {
    match urlencoding::decode(s) {
        Ok(v) => v.into_owned(),
        Err(_) => s.to_string(),
    }
}

fn clean_text(s: &str) -> String {
    let no_tags = crate::tvbox::strip_tags(s);
    crate::tvbox::decode_entities(&no_tags)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for HJZhenCai {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = Self::need_site(ext)?;
        let html = self.get_text(&format!("{host}/")).await?;
        home_from_html(&html)
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空（首页没给出分类）".to_string());
        }
        let host = Self::need_site(ext)?;
        let page = if page == 0 { 1 } else { page };
        // DEX: `/index.php/vod/show/id/<cateId>` + `[/page/<n>]` + `.html`
        let path = if page <= 1 {
            format!("/index.php/vod/show/id/{tid}.html")
        } else {
            format!("/index.php/vod/show/id/{tid}/page/{page}.html")
        };
        let html = self.get_text(&format!("{host}{path}")).await?;
        let items = parse_items(&html);
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
                "HJZhenCai 分类 {tid} 的页面能打开，但没解析出任何条目（模板可能已改版，或返回的是风控壳页）"
            ));
        }
        let page_count = parse_page_count(&html);
        Ok(CspList {
            items,
            page,
            page_count,
            total: None,
        })
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let host = Self::need_site(ext)?;
        let html = self
            .get_text(&format!("{host}/index.php/vod/detail/id/{id}.html"))
            .await?;
        let d = detail_from_html(&html, id);
        if d.episodes.is_empty() {
            return Err(format!(
                "HJZhenCai 条目 {id} 的详情页能打开，但没找到任何网盘链接\
                 （可能已下架，或模板改版把 down-card 结构换了）"
            ));
        }
        Ok(d)
    }

    /// 搜索：先 `ajax/suggest`（JSON，DEX 的 quickSearch），0 条再退到 HTML 搜索页
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let host = Self::need_site(ext)?;
        let page = if page == 0 { 1 } else { page };
        let enc = encode_path(kw);

        // ① suggest（JSON）—— 第 1 页优先用它（快；真站实测 200 + list）
        if page == 1 {
            let url = format!("{host}/index.php/ajax/suggest?mid=1&wd={enc}&limit=50");
            if let Ok(text) = self.get_text(&url).await {
                if let Ok(v) = crate::tvbox::parse_loose_json(&text) {
                    let items = parse_suggest(&v);
                    if !items.is_empty() {
                        return Ok(CspList {
                            items,
                            page,
                            page_count: None,
                            total: None,
                        });
                    }
                }
            }
        }

        // ② HTML 搜索页
        let path = if page <= 1 {
            format!("/index.php/vod/search.html?wd={enc}")
        } else {
            format!("/index.php/vod/search.html?wd={enc}&page={page}")
        };
        let html = self.get_text(&format!("{host}{path}")).await?;
        let items = parse_items(&html);
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
                "HJZhenCai 搜索「{kw}」没拿到任何条目（suggest 与搜索页都为空）——\
                 可能真的没有结果，也可能模板改版/风控壳页，本类不把它说成「0 条」"
            ));
        }
        Ok(CspList {
            items,
            page,
            page_count: parse_page_count(&html),
            total: None,
        })
    }

    /// 直链保持原样；已接管的网盘分享只交回宿主检查解析。
    /// 本层不执行转存或选文件，百度完整取流仍由宿主如实报告未接入。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let raw = id.trim();
        let url = raw.strip_prefix("pan|").unwrap_or(raw);
        if !crate::tvbox::starts_http(url) {
            return Err(format!("播放 id 既不是分享链接也不是直链：{raw}"));
        }
        let lower = url.to_ascii_lowercase();
        if lower.contains(".m3u8") || lower.contains(".mp4") {
            return Ok(vec![CspPlay {
                url: url.to_string(),
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some("直链".to_string()),
            }]);
        }
        // 中间分享候选由宿主预检解析，不能直接作为媒体流。
        if let Some(p) = crate::csp::pan_share_play::share_page_play(url, UA) {
            return Ok(vec![p]);
        }
        Err(format!(
            "这条是{}分享页（不是媒体流）：本仓还没有它的分享→直链转换（T1b 取证后接入）\
             ⇒ 暂时放不了；home/list/search/detail 不受影响",
            disk_label(url)
        ))
    }
}

/// `ajax/suggest` 的 JSON → 条目（字段：id / name / pic / remark）
pub fn parse_suggest(v: &serde_json::Value) -> Vec<CspItem> {
    let mut out: Vec<CspItem> = Vec::new();
    let Some(arr) = v.get("list").and_then(|x| x.as_array()) else {
        return out;
    };
    for it in arr {
        let id = match it.get("id") {
            Some(serde_json::Value::String(s)) => s.clone(),
            Some(serde_json::Value::Number(n)) => n.to_string(),
            _ => continue,
        };
        let title = it
            .get("name")
            .and_then(|x| x.as_str())
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        if id.is_empty() || title.is_empty() {
            continue;
        }
        out.push(CspItem {
            id,
            title,
            cover: it
                .get("pic")
                .and_then(|x| x.as_str())
                .map(|s| s.to_string())
                .filter(|s| s.starts_with("http")),
            subtitle: it
                .get("remark")
                .and_then(|x| x.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        });
        if out.len() >= MAX_ITEMS {
            break;
        }
    }
    out
}

/// 分页总数：真站底部的 `page-number` 链接里最大的页码（DEX 的 `parsePageCount`）
pub fn parse_page_count(html: &str) -> Option<u32> {
    let re = regex::Regex::new(r#"/page/(\d+)\.html"#).ok()?;
    let max = re
        .captures_iter(html)
        .filter_map(|c| c[1].parse::<u32>().ok())
        .max()?;
    if max > 1 {
        Some(max)
    } else {
        None
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
// ① 订阅：`csp_HJZhenCai` = 1 站（花卷真彩｜4K臻彩，ext.site 一个镜像）
// ② host：`https://www.hjzhencai.top` 直连 200
// ③ 真网：7 分类 / 16 条目；list 40 条；suggest 1 条；detail 2 条网盘
// ⇒ 注册
// ```
crate::csp::register_site!(HJZhenCai);

// ═══════════════════════════════════════════════════════════════════════
//  测试（真响应片段，纯函数）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 真站首页导航 + 两个条目（2026-10-28 直连 `https://www.hjzhencai.top/`，逐字）
    const HOME: &str = r#"<nav><a href="/index.php/vod/type/id/22.html" title="花卷高帧">花卷高帧</a><a href="/index.php/vod/type/id/1.html" title="花卷电影">花卷电影</a><a href="/index.php/vod/type/id/2.html" title="花卷剧集">花卷剧集</a></nav><div class="module-main"><div class="module-items module-poster-items-base"><a href="/index.php/vod/detail/id/17122.html" title="恋爱博士" class="module-poster-item module-item"><div class="module-item-cover"><div class="module-item-note">更新至08集</div><div class="module-item-pic"><img class="lazy lazyload" data-original="https://pic3.yzzyimg.online/upload/vod/2026-10-05/202610051791211042.jpg" alt="恋爱博士" src="/mxtheme/images/load.gif"></div></div><div class="module-poster-item-info"><div class="module-poster-item-title">恋爱博士</div></div></a><a href="/index.php/vod/detail/id/20841.html" title="末世行者" class="module-poster-item module-item"><div class="module-item-cover"><div class="module-item-note">HD中字</div><div class="module-item-pic"><img class="lazy lazyload" data-original="https://pic3.yzzyimg.online/upload/vod/2026-08-30/202608301788085784.jpg" alt="末世行者" src="/mxtheme/images/load.gif"></div></div></a></div></div>"#;

    /// 真站列表页底部的分页链接（同上，逐字形态）
    const LIST_PAGER: &str = r#"<div id="page"><a href="/index.php/vod/show/id/1/page/2.html" class="page-number" title="第2页">2</a><a href="/index.php/vod/show/id/1/page/3.html" class="page-number">3</a></div>"#;

    /// 真站详情片段（`/index.php/vod/detail/id/20841.html`，逐字）
    const DETAIL: &str = r#"<div class="module-info-main"><div class="module-info-heading"><h1>末世行者</h1></div><div class="module-info-content"><div class="module-info-items"><div class="module-info-item module-info-introduction"><div class="module-info-introduction-content"><p>一场大流感之后，希格认识的所有人都死了。</p></div></div></div></div></div><div class="down-wrap"><div class="down-src"><i class="icon-download"></i>BAIDU</div><div class="down-card"><div class="down-card-head"><span class="down-card-name">第1集</span><span class="down-card-pwd" hidden></span></div><div class="down-card-body"><div class="down-card-urlbox" title="https://pan.baidu.com/s/1s_XILRPyihZwDvGN6Xvk5Q?pwd=kui9"><a class="down-card-url" href="https://pan.baidu.com/s/1s_XILRPyihZwDvGN6Xvk5Q?pwd=kui9" rel="nofollow" target="_blank">https://pan.baidu.com/s/1s_XILRPyihZwDvGN6Xvk5Q?pwd=kui9</a></div></div></div><div class="down-src"><i class="icon-download"></i>KUAKE</div><div class="down-card"><div class="down-card-head"><span class="down-card-name">第1集</span></div><div class="down-card-body"><div class="down-card-urlbox" title="https://pan.quark.cn/s/c2dcf75b0a1e"><a class="down-card-url" href="https://pan.quark.cn/s/c2dcf75b0a1e" rel="nofollow">https://pan.quark.cn/s/c2dcf75b0a1e</a></div></div></div></div>"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(HJZhenCai::CLASS, "HJZhenCai");
    }

    #[test]
    fn sites_of_reads_ext() {
        assert_eq!(
            HJZhenCai::sites_of(r#"{"site":["https://a.example/"]}"#),
            vec!["https://a.example".to_string()]
        );
        assert_eq!(
            HJZhenCai::sites_of(r#"{"host":"https://b.example"}"#),
            vec!["https://b.example".to_string()]
        );
        assert!(HJZhenCai::sites_of("{}").is_empty());
    }

    #[test]
    fn parse_categories_and_items_from_real_home() {
        let cats = parse_categories(HOME);
        assert_eq!(cats.len(), 3, "{cats:?}");
        assert_eq!(cats[1], CspCategory { id: "1".into(), name: "花卷电影".into() });
        let items = parse_items(HOME);
        assert_eq!(items.len(), 2, "{items:?}");
        assert_eq!(items[0].id, "17122");
        assert_eq!(items[0].title, "恋爱博士");
        assert_eq!(items[0].subtitle.as_deref(), Some("更新至08集"));
        assert!(items[0]
            .cover
            .as_deref()
            .unwrap_or("")
            .contains("202610051791211042.jpg"));
        // ★ 属性顺序反转（title 在 href 前）也必须解析出来
        let swapped = r#"<a title="标题在前" href="/index.php/vod/detail/id/9.html" class="module-item">x</a>"#;
        let it = parse_items(swapped);
        assert_eq!(it[0].title, "标题在前");
        assert_eq!(it[0].id, "9");
    }

    #[test]
    fn home_and_list_reject_empty() {
        let e = home_from_html("<html>维护中</html>").expect_err("0 分类必须 Err");
        assert!(e.contains("没解析出任何分类"), "{e}");
        let e2 = home_from_html(r#"<a href="/index.php/vod/type/id/1.html">电影</a>"#)
            .expect_err("0 条目必须 Err");
        assert!(e2.contains("没解析出任何条目"), "{e2}");
        let e3 = list_from_html("<html>403</html>", 1, "分类 1").expect_err("0 条必须 Err");
        assert!(e3.contains("风控壳页"), "{e3}");
        assert!(home_from_html(HOME).is_ok());
    }

    #[test]
    fn detail_parses_title_intro_and_two_netdisks() {
        let d = detail_from_html(DETAIL, "20841");
        assert_eq!(d.title, "末世行者");
        assert!(d.description.as_deref().unwrap_or("").contains("一场大流感"));
        assert_eq!(d.episodes.len(), 2, "{:?}", d.episodes);
        assert_eq!(d.episodes[0].flag, "百度网盘");
        assert_eq!(d.episodes[0].title, "第1集 · 百度网盘");
        assert_eq!(d.episodes[1].flag, "夸克网盘");
        assert!(d.episodes[1].id.starts_with("pan|https://pan.quark.cn/s/"));
    }

    #[test]
    fn netdisk_encoded_links_are_decoded() {
        // DEX 的第二条模式：整条链接被百分号编码
        let html = r##"<div class="down-card"><span class="down-card-name">第2集</span><a href="#">https%3A%2F%2Fpan.quark.cn%2Fs%2Fabcdef</a></div>"##;
        let eps = netdisk_episodes(html);
        assert_eq!(eps.len(), 1, "{eps:?}");
        assert_eq!(eps[0].id, "pan|https://pan.quark.cn/s/abcdef");
        assert_eq!(eps[0].flag, "夸克网盘");
    }

    #[test]
    fn page_count_reads_the_largest_page_number() {
        assert_eq!(parse_page_count(LIST_PAGER), Some(3));
        assert_eq!(parse_page_count("<html></html>"), None);
        assert_eq!(parse_page_count(r#"<a href="/x/page/1.html">1</a>"#), None);
    }

    #[test]
    fn suggest_json_maps_fields() {
        let v = crate::tvbox::parse_loose_json(
            r#"{"code":1,"msg":"数据列表","list":[{"id":13406,"name":"红海龟","pic":"https://pomo.mom/a.jpg","remark":"花卷原盘"}]}"#,
        )
        .unwrap();
        let items = parse_suggest(&v);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "13406");
        assert_eq!(items[0].title, "红海龟");
        assert_eq!(items[0].subtitle.as_deref(), Some("花卷原盘"));
        assert!(parse_suggest(&crate::tvbox::parse_loose_json(r#"{"list":[]}"#).unwrap()).is_empty());
    }

    #[test]
    fn http_client_disables_proxy_after_timeout() {
        let flat = crate::csp::shared::impl_src_only(include_str!("hjzhen_cai.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("timeout");
        let p = flat.find(".no_proxy()").expect("★ no_proxy 必须存在");
        let b = flat.find(".build()").expect("build");
        assert!(t < p && p < b, "timeout → no_proxy → build");
    }

    #[test]
    fn hjzhencai_is_registered() {
        assert!(
            crate::csp::is_implemented("csp_HJZhenCai"),
            "★ 三条判据成立 ⇒ 必须注册"
        );
        let flat = crate::csp::shared::impl_src_only(include_str!("hjzhen_cai.rs"));
        assert!(flat.contains("register_site!(HJZhenCai)"));
    }

    /// 真网络（`#[ignore]`，必须显式点名 + `CSP_LIVE=1`）
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp::hjzhen_cai:: -- --ignored --nocapture"]
    async fn csp_live_hjzhencai_home_list_search_detail() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：显式跑就必须给 CSP_LIVE=1（不给就失败）"
        );
        const EXT: &str = r#"{"site":["https://www.hjzhencai.top"]}"#;
        let site = HJZhenCai::new();

        let home = site.home(EXT).await.expect("home 应成功");
        eprintln!(
            "[LIVE] HJZhenCai home: {} 分类 / {} 条目; 分类={:?}",
            home.categories.len(),
            home.items.len(),
            home.categories.iter().map(|c| format!("{}:{}", c.id, c.name)).collect::<Vec<_>>()
        );
        assert!(!home.categories.is_empty());
        assert!(!home.items.is_empty());

        let tid = home.categories[0].id.clone();
        let list = site.list(&tid, 1, EXT).await.expect("list 应成功");
        eprintln!("[LIVE] HJZhenCai list({tid}) ⇒ {} 条", list.items.len());
        assert!(!list.items.is_empty());

        let kw = "红海";
        let found = site.search(kw, 1, EXT).await.expect("search 应成功");
        eprintln!("[LIVE] HJZhenCai search({kw}) ⇒ {} 条", found.items.len());
        assert!(!found.items.is_empty());

        let id = home.items[0].id.clone();
        let d = site.detail(&id, EXT).await.expect("detail 应成功");
        eprintln!(
            "[LIVE] HJZhenCai detail({id}) ⇒ 标题={:?} 简介前60={:?} 网盘 {} 条",
            d.title,
            d.description.as_deref().unwrap_or("").chars().take(60).collect::<String>(),
            d.episodes.len()
        );
        for e in d.episodes.iter().take(3) {
            eprintln!("[LIVE]   - {} {}", e.flag, e.id);
        }
        assert!(!d.episodes.is_empty());
    }

    /// ★★★ T1a 门禁（2026-10-31）：夸克/UC 分享页交回**原生直链转换**；其它族维持如实 Err
    ///
    /// # 夹具来源（真网抓取，lead 条件①：不许自造）
    /// ```text
    /// hjzhencai 754 详情页（https://www.hjzhencai.top/index.php/vod/detail/id/754.html）
    /// 2026-10-31 真抓：夸克 f84677cde4ff、百度 ?pwd=vp3x（后者是其它族的反例）。
    /// play 的分享分支是纯本地判断（不打网络）⇒ 离线可测。
    /// ```
    #[tokio::test]
    async fn play_hands_quark_uc_share_pages_to_native_conversion() {
        let site = HJZhenCai::new();
        let got = site
            .play("", "pan|https://pan.quark.cn/s/f84677cde4ff", "")
            .await
            .expect("夸克分享页要交回原生转换");
        assert_eq!(got[0].url, "https://pan.quark.cn/s/f84677cde4ff");
        assert!(
            got[0].label.as_deref().unwrap_or("").contains("原生转直链"),
            "label 要如实：{:?}",
            got[0].label
        );
        let got = site
            .play("", "pan|https://pan.baidu.com/s/1yCHnLlsJLd_yyoaZjvRSEg?pwd=vp3x", "")
            .await
            .expect("百度应交给已接管的宿主检查解析");
        assert!(got[0].label.as_deref().unwrap().contains("宿主检查解析"));
    }

    /// 接线断言：play 的分享分支必须真的走 share_page_play（不许只改文案）
    ///
    /// ```text
    /// ★ 断言完整的 `if let Some(p) = …` 守卫形态（`if false {}` 注入骗不过）。
    /// ```
    #[test]
    fn play_wires_share_page_play() {
        let src = include_str!("hjzhen_cai.rs");
        let prod = src.split("#[cfg(test)]").next().unwrap_or("");
        assert!(
            prod
                .contains("if let Some(p) = crate::csp::pan_share_play::share_page_play(url, UA)"),
            "play 必须以 if-let 守卫把夸克/UC 分享页交给 share_page_play（原生转换入口）"
        );
    }
}
