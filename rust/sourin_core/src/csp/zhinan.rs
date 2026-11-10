// ═══════════════════════════════════════════════════════════════════════
//  csp_4KZhinan —— TVBox `csp_4KZhinan` 的 Rust 重写（纯 HTML 抓取）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 指南    ext = {"site": ["https://4kzn.cc"]}
// 小丑    ext = {"site": ["https://4kxc.com"]}
// ```
// ⇒ **站点从 ext 取**，不写死；同一个类换 ext 就是另一个站。
//
// # 抓取形态（2026-10-26 实测，不是推测）
//
// ```text
// $ curl -A <Chrome UA> -L https://4kzn.cc/
//   HTTP 200 · 122413 bytes · <title>4K指南 | 专注4K蓝光超清电影资源分享</title>
//   列表项 82 处 <article class="posts-item book-item d-flex style-book-v post-21156 ajax-item">
// $ curl -L https://4kzn.cc/books/zuixin           → 200 · 50 项
// $ curl -L https://4kzn.cc/books/zuixin/page/2/   → 200 · 50 项   ← 分页就是 /page/N/
// $ curl -L https://4kzn.cc/book/21156.html        → 200 · 50373 bytes
//   详情选择器 site-name-box / site-content / site-go / 制片国家 / IMDb 全部命中
//   正文里有网盘分享页：https://pan.quark.cn/s/d326365be5e5
// ```
//
// 站点是 **OneNav / WordPress 主题**：列表项是一段结构固定的 `<article>`，
// 详情页的站点信息在 `site-name-box` 里，正文在 `site-content` 里。
//
// # 为什么不引入 HTML 选择器库
//
// ```text
// 本仓依赖表里没有 scraper/html5ever，而"不新增运行时依赖"是硬约束
// （第 19 项的立身之本就是不嵌额外运行时）。
// ⇒ 用 `regex`（本仓已有）做**最小、可测**的抽取：
//     · 只依赖 article 边界 + data-src + h3>a 文本 + 网盘链接这几处
//     · 每处都配一个"页面结构变了"的坏样本，结构一变立刻报错而不是静默返回空
// ⚠️ 局限（如实写）：不做完整 DOM 树，嵌套同名标签、属性顺序变化、HTML 实体
//    都靠正则的容错性；一旦站点换主题，这里会红（而不是悄悄返回空列表）。
// ```
//
// # 播放（play）的真实能力边界
//
// ```text
// 这个站的"播放"就是**网盘分享页**（夸克/百度/UC/迅雷/189/123/115/阿里云盘），
// 上游 APK 也是把分享链接塞进 vod_play_url 的。
// ⇒ play() 返回**分享页 URL**（不是直链），并在 label 里写明"分享页"。
//    把分享页解析成直链是网盘模块的事（第 20 项，目前仍阻塞），
//    这里**不伪造** m3u8/mp4 地址。
// ```

use async_trait::async_trait;
use regex::Regex;
use std::sync::OnceLock;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 浏览器 UA：站点对默认 reqwest UA 会直接 403（实测必要时带）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 没给 ext 时的兜底站点（配置里两个源都在 ext 里显式给了 site）
const DEFAULT_SITE: &str = "https://4kzn.cc";

/// 默认分类（首页导航里第一个就叫「最新」）
const DEFAULT_TID: &str = "books:zuixin";

pub struct Zhinan {
    client: super::http_context::CspHttpContext,
}

impl Zhinan {
    pub const CLASS: &'static str = "4KZhinan";

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| reqwest::Client::builder()
            .user_agent(UA)
            .timeout(std::time::Duration::from_secs(20))
            // Ignore environment proxies; an injected context applies the app's policy.
            .no_proxy()
        );
        Self { client }
    }

    /// 从 ext 里取站点（`{"site":["https://4kzn.cc"]}`），取不到就用兜底
    ///
    /// ⚠️ 刻意**不解析整个 ext JSON**：这个类的 ext 只有一句"站点在哪"，
    ///    用整段 JSON 解析会把"ext 里多一个字段"变成硬失败（上游加字段很常见）。
    pub fn site_of(ext: &str) -> String {
        static RE: OnceLock<Regex> = OnceLock::new();
        let re = RE.get_or_init(|| Regex::new(r#"https?://[^"'\s,\]}]+"#).expect("site regex"));
        re.find(ext)
            .map(|m| m.as_str().trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| DEFAULT_SITE.to_string())
    }

    fn url_of(&self, base: &str, path: &str) -> String {
        format!("{}{}", base.trim_end_matches('/'), path)
    }

    async fn get(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .send()
            .await
            .map_err(|e| format!("请求站点失败（{url}）：{e}"))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(format!("站点返回 HTTP {status}（{url}）"));
        }
        resp.text()
            .await
            .map_err(|e| format!("读取站点页面失败（{url}）：{e}"))
    }
}

impl Default for Zhinan {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  解析（纯函数，全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// 一条列表项（解析结果）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawItem {
    pub id: String,
    pub title: String,
    pub cover: Option<String>,
}

fn re_item() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    // article 边界：OneNav 主题的固定 class
    RE.get_or_init(|| Regex::new(r#"(?s)<article\s+class="posts-item[^"]*"[^>]*>(.*?)</article>"#).expect("item regex"))
}

fn re_book_id() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"/book/(\d+)\.html"#).expect("book id regex"))
}

fn re_title() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"(?s)<h3[^>]*>\s*<a[^>]*>(.*?)</a>"#).expect("title regex"))
}

fn re_data_src() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"data-src="([^"]+)""#).expect("data-src regex"))
}

/// 分类导航：`/books/<slug>` 与 `/favorites/<slug>`，取链接文字作分类名
fn re_nav() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"(?s)<a[^>]+href="[^"]*/(books|favorites)/([^"/]+)/?"[^>]*>(.*?)</a>"#)
            .expect("nav regex")
    })
}

fn re_tag() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<[^>]+>").expect("tag regex"))
}

/// 网盘分享链接（与上游 `extractQuarkLinks` 的域名集合一致）
fn re_pan() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"https?://(?:pan\.quark\.cn/s/[A-Za-z0-9]+|pan\.baidu\.com/s/[A-Za-z0-9_-]+(?:\?pwd=[A-Za-z0-9]+)?|drive\.uc\.cn/s/[A-Za-z0-9]+(?:\?pwd=[A-Za-z0-9]+)?|pan\.xunlei\.com/s/[A-Za-z0-9_-]+|cloud\.189\.cn/[A-Za-z]+/[A-Za-z0-9]+|(?:www\.)?115\.com/s/[A-Za-z0-9]+|(?:www\.)?123pan\.com/s/[A-Za-z0-9_-]+|(?:www\.)?guangyapan\.com/s/[A-Za-z0-9_-]+|(?:www\.)?(?:ali)?pan\.com/s/[A-Za-z0-9]+|(?:www\.)?aliyundrive\.com/s/[A-Za-z0-9]+)",
        )
        .expect("pan regex")
    })
}

/// 最小百分号编码（只保留 RFC3986 unreserved）
///
/// ⚠️ 不引入 url 库：本仓依赖表里没有它，而搜索词只需要这一件事。
fn urlencode(s: &str) -> String {
    let mut out = String::new();
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

/// 搜索路径（WordPress 的 `?post_type=book&s=<kw>`；第 2 页起走 `/page/N/`）
///
/// ⚠️ 参数名就是 `s`（搜索）—— 写成 `q`/`keyword` 站点不认，会返回
///    **正常的 0 结果页**（HTTP 200），我们这边表现为"没解析出条目"。
fn search_path(kw: &str, page: u32) -> String {
    let page = page.max(1);
    if page == 1 {
        format!("/?post_type=book&s={}", urlencode(kw))
    } else {
        format!("/page/{page}/?post_type=book&s={}", urlencode(kw))
    }
}

fn strip_tags(s: &str) -> String {
    let t = re_tag().replace_all(s, " ");
    let t = t.replace("&amp;", "&").replace("&nbsp;", " ").replace("&quot;", "\"");
    t.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 解析一页 HTML 里的列表项
///
/// ⚠️ 返回 `Err` 的条件是"一页里连一个**可解析**的条目都没有"，必须如实报错
///    （返回空列表会让用户以为"这个分类没内容"）。
///
/// # ★★ 2026-10-27（R3 复核）：报错文案**必须把"我们能解析什么"写出来**
///
/// ```text
/// 改前：`页面里没有任何列表项（站点结构可能变了，或被反爬挡了）`
/// ★ 这句**骗过人**：`favorites/技巧` 页**明明有 6 个 <article>**，
///   只是它们是 `sites-item` 形态（本站的"资源导航/WP 站点条目"），
///   而这个解析器只认 `book-item`。
///   ⇒ 报错说"结构变了/被反爬"，把人往**错误方向**带（我当时就去查站点是不是挂了）。
/// 改后：把实际形态与我们的支持面**都写进去** —— 下次一眼看穿。
/// ```
pub fn parse_list(html: &str) -> Result<Vec<RawItem>, String> {
    let mut out = Vec::new();
    // ★ 记住"页面里到底出现了哪些形态"，用于报错时如实说（不是猜）
    let mut seen_sites_only = 0usize;
    for cap in re_item().captures_iter(html) {
        let block = &cap[1];
        let Some(idc) = re_book_id().captures(block) else {
            // 认得出它是不是"本站另一种形态"，只为把报错说准
            if re_sites_body().is_match(block) {
                seen_sites_only += 1;
            }
            continue;
        };
        let id = idc[1].to_string();
        let title = re_title()
            .captures(block)
            .map(|c| strip_tags(&c[1]))
            .filter(|s| !s.is_empty());
        let Some(title) = title else { continue };
        let cover = re_data_src()
            .captures(block)
            .map(|c| c[1].to_string())
            .filter(|s| !s.starts_with("data:"));
        out.push(RawItem { id, title, cover });
    }
    if out.is_empty() {
        return Err(empty_page_reason(html, seen_sites_only));
    }
    Ok(out)
}

/// 一页"解析不出条目"时，**如实**说明为什么（基于我们实际看到的东西）
///
/// # 为什么做成独立函数
/// ```text
/// 报错文案是**给人看的判断依据** —— 它必须能被单独测（见本文件测试组），
/// 而不是埋在 `parse_list` 里靠"跑一遍看输出了啥"来验。
/// ```
fn empty_page_reason(html: &str, sites_only: usize) -> String {
    // ★ 2026-10-29 真网复测（同一模板、只换搜索词，别再把这个 Err 读成"站点改版"）：
    //   `https://4kzn.cc/?post_type=book&s=老舅` → **200 / 19063 B**，
    //     `<body class="search search-no-results wp-theme-onenav …">`、`<article>` 计数 **0**
    //     ⇒ WordPress 自己判的"没搜到"（这个 class 就是站点给的判据）。
    //   `https://4kzn.cc/?post_type=book&s=龙珠` → **200 / 28680 B**、`<article>` **10 个**，
    //     逐字 `<article class="posts-item book-item d-flex style-book-v post-21146">`
    //     + `<h3 class="item-title line1"><a …>七龙珠</a></h3>` ⇒ `parse_list` 能出 10 条。
    //   ⇒ 判据：**换词能出 = 解析器没坏**；老舅这一页是"真的没内容"，不是改版。
    // 页面里到底有几个 <article>（区分"一个都没有"和"有但不认"）
    let total_articles = re_item().captures_iter(html).count();
    if total_articles == 0 {
        return "页面里没有任何 <article> 条目（站点结构可能变了，或真的没内容）".to_string();
    }
    if sites_only > 0 && sites_only == total_articles {
        return format!(
            "页面里没有任何「可解析」的列表项：{total_articles} 个 <article> 全是 \
sites-item 形态（本站的「资源/站点导航」条目，不是影视条目）；\
当前解析器只支持 book-item 形态"
        );
    }
    format!(
        "页面里没有任何「可解析」的列表项：{total_articles} 个 <article> 中 \
{sites_only} 个是 sites-item、其余不符合 book-item 形态（缺 /book/N.html 或标题）"
    )
}

/// ★ 认「站点导航条目」形态（`sites-item`）：只为「把报错说准」，不参与出条目
///
/// # 为什么不拿它出条目（裁定的 (A) 形态）
/// ```text
/// 实测 `favorites/技巧` 那 6 条全是「免费领取夸克网盘1TB空间，夸克每天领取容量教程」
/// 这类「领网盘空间的教程/导航站条目」 —— 不是影视内容。
/// ⇒ 塞进"影视列表"是「把内容性质搞错」（产品缺陷，不是解析缺陷）。
/// ⇒ 见 `INCLUDE_NAV_SECTIONS`（Owner 待定项）：
///    现在「默认不列出」 favorites 分类，也不拿它出条目。
/// ```
fn re_sites_body() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"class="[^"]*sites-body"#).expect("sites-body regex"))
}

/// 站点导航条目的 id（`/18433.html` —— **没有** `/book/` 前缀）
///
/// ⚠️ 当前**不使用**，保留为 Owner 选 (B) 时的接入点（见 `INCLUDE_NAV_SECTIONS`）。
#[allow(dead_code)]
fn re_sites_id() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"/(\d+)\.html""#).expect("sites id regex"))
}

/// 站点导航条目的标题（`<h3 class="item-title line1"><b>…</b></h3>` —— **没有** `<a>`）
///
/// ⚠️ 当前**不使用**（同上，Owner 选 (B) 时的接入点）。
#[allow(dead_code)]
fn re_sites_title() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"(?s)<h3[^>]*class="[^"]*item-title[^"]*"[^>]*>\s*<b>(.*?)</b>"#)
            .expect("sites title regex")
    })
}

/// ★★★ Owner 待定项：要不要列出「站点导航」类分类（`favorites/*`）
///
/// ```text
/// 背景（2026-10-27 实测）：站点导航里有 `/books/*`（8 个，全是影视分类）
/// 和 `/favorites/*`（1 个，导航显示名「更多资源+」，实质是"必看"Tab）。
/// `favorites/技巧` 里 6 条**全是**「领夸克网盘空间教程」这类**导航/tips 条目**。
///
/// 裁定（Lead 2026-10-27）：选 **③ 分派**，并**先做 (A) 形态**（更保守：
///   不会把非影视内容混进影视列表），同时**留出 (B) 的接入点**。
///
/// (A) `false`（当前）：favorites 分类**整类不列**（导航里也不显示）
/// (B) `true`          ：favorites 分类**列出**，但条目按"非影视"另行呈现
///
/// ⇒ Owner 选 (B) 时：把此常量改 `true`，并在 `parse_categories` 里放开过滤、
///   在 `list()` 里按 `kind` 分派到 `parse_sites_list`（上面两条 re_sites_* 已备好）。
/// ```
const INCLUDE_NAV_SECTIONS: bool = false;

/// 解析导航里的分类（`/books/x`、`/favorites/x`）
///
/// ⚠️ `favorites/*` 默认被**过滤掉**（见 `INCLUDE_NAV_SECTIONS` 的说明）：
///    它不是影视分类，列出来会让用户"点了发现没有影视"。
pub fn parse_categories(html: &str) -> Vec<CspCategory> {
    let mut out: Vec<CspCategory> = Vec::new();
    for cap in re_nav().captures_iter(html) {
        let kind = &cap[1];
        let slug = &cap[2];
        let name = strip_tags(&cap[3]);
        if name.is_empty() || name.chars().count() > 12 {
            continue;
        }
        // ★ 「站点导航」类分类：默认不收（Owner 待定，见 INCLUDE_NAV_SECTIONS）
        if kind == "favorites" && !INCLUDE_NAV_SECTIONS {
            continue;
        }
        let id = format!("{kind}:{slug}");
        if out.iter().any(|c| c.id == id) {
            continue;
        }
        out.push(CspCategory { id, name });
    }
    out
}

/// 解析详情页：标题 / 封面 / 简介 / 剧集（= 网盘分享页，每条算一集）
pub fn parse_detail(html: &str) -> Result<CspDetail, String> {
    static RE_H1: OnceLock<Regex> = OnceLock::new();
    let re_h1 = RE_H1.get_or_init(|| {
        Regex::new(r#"(?s)site-name-box[^>]*>\s*<h1[^>]*>(.*?)</h1>"#).expect("h1 regex")
    });
    static RE_COVER: OnceLock<Regex> = OnceLock::new();
    let re_cover = RE_COVER.get_or_init(|| {
        Regex::new(r#"(?s)book-cover[^>]*>\s*<img[^>]*?(?:data-src|src)="([^"]+)""#)
            .expect("cover regex")
    });
    static RE_P: OnceLock<Regex> = OnceLock::new();
    let re_p = RE_P.get_or_init(|| {
        Regex::new(r#"(?s)site-content[^>]*>(.*?)</p>"#).expect("desc regex")
    });

    let title = re_h1
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "详情页里找不到标题（站点结构可能变了）".to_string())?;
    let cover = re_cover.captures(html).map(|c| c[1].to_string());
    let description = re_p
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .filter(|s| !s.is_empty());

    let mut episodes: Vec<CspEpisode> = Vec::new();
    for m in re_pan().find_iter(html) {
        let url = m.as_str().to_string();
        if episodes.iter().any(|e| e.id == url) {
            continue;
        }
        episodes.push(CspEpisode {
            title: pan_label(&url),
            flag: "默认".to_string(),
            id: url,
        });
    }
    Ok(CspDetail {
        id: String::new(),
        title,
        cover,
        description,
        episodes,
    })
}

/// 网盘分享页 → 线路名（给用户看的，必须说明这是分享页而不是直链）
pub fn pan_label(url: &str) -> String {
    if url.contains("quark.cn") {
        "夸克网盘（分享页）".to_string()
    } else if url.contains("baidu.com") {
        "百度网盘（分享页）".to_string()
    } else if url.contains("uc.cn") {
        "UC 网盘（分享页）".to_string()
    } else if url.contains("xunlei.com") {
        "迅雷云盘（分享页）".to_string()
    } else if url.contains("189.cn") {
        "天翼云盘（分享页）".to_string()
    } else if url.contains("115.com") {
        "115 网盘（分享页）".to_string()
    } else if url.contains("123pan.com") {
        "123 云盘（分享页）".to_string()
    } else if url.contains("guangyapan.com") {
        "光雅网盘（分享页）".to_string()
    } else if url.contains("aliyundrive.com") || url.contains("alipan.com") {
        "阿里云盘（分享页）".to_string()
    } else {
        "网盘分享页".to_string()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Zhinan {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let base = Self::site_of(ext);
        let html = self.get(&self.url_of(&base, "/")).await?;
        let mut categories = parse_categories(&html);
        if categories.is_empty() {
            // 首页导航换了版式也**不能**没有分类：退回默认分类并如实标注来源
            categories.push(CspCategory {
                id: DEFAULT_TID.to_string(),
                name: "最新".to_string(),
            });
        }
        let items = parse_list(&html)?
            .into_iter()
            .map(|r| CspItem {
                id: r.id,
                title: r.title,
                cover: r.cover,
                subtitle: None,
            })
            .collect();
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let base = Self::site_of(ext);
        let tid = if tid.trim().is_empty() { DEFAULT_TID } else { tid.trim() };
        let (kind, slug) = tid
            .split_once(':')
            .ok_or_else(|| format!("分类 id 形态不对（应为 kind:slug）：{tid}"))?;
        let page = page.max(1);
        let path = if page == 1 {
            format!("/{kind}/{slug}/")
        } else {
            format!("/{kind}/{slug}/page/{page}/")
        };
        let html = self.get(&self.url_of(&base, &path)).await?;
        let raw = parse_list(&html)?;
        // 分页上限：页面里出现 "page/(N+1)/" 就说明还有下一页
        let next = format!("/page/{}/", page + 1);
        let has_next = html.contains(&next);
        Ok(CspList {
            page,
            page_count: if has_next { None } else { Some(page) },
            total: None,
            items: raw
                .into_iter()
                .map(|r| CspItem {
                    id: r.id,
                    title: r.title,
                    cover: r.cover,
                    subtitle: None,
                })
                .collect(),
        })
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let base = Self::site_of(ext);
        let id = id.trim();
        if id.is_empty() {
            return Err("详情 id 为空".to_string());
        }
        let path = format!("/book/{id}.html");
        let html = self.get(&self.url_of(&base, &path)).await?;
        let mut d = parse_detail(&html)?;
        d.id = id.to_string();
        Ok(d)
    }

    /// 搜索：WordPress 的 `?post_type=book&s=<kw>`（第 2 页起加 `&paged=N`）
    ///
    /// 解析**复用列表那套**（`parse_list`）—— 搜索结果页与分类页是同一个
    /// 列表模板（`.posts-item.book-item`），只是查询入口不同。
    /// ★ 搜索能力声明（`capabilities.search` 直接用它的值）
    ///
    /// `HTML 搜索（?post_type=book&s=）已实现，但**未做真网络验证**`
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索词为空".to_string());
        }
        let base = Self::site_of(ext);
        let path = search_path(kw, page);
        let html = self.get(&self.url_of(&base, &path)).await?;
        let raw = parse_list(&html)?;
        Ok(CspList {
            page,
            page_count: None,
            total: None,
            items: raw
                .into_iter()
                .map(|r| CspItem { id: r.id, title: r.title, cover: r.cover, subtitle: None })
                .collect(),
        })
    }

    async fn play(&self, _flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let share = id.trim();
        if share.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if !re_pan().is_match(share) {
            // 明确说清"为什么不能播"，而不是给一个空列表
            return Err(format!(
                "这条不是网盘分享页，无法播放：{share}（本源的播放全部是网盘分享页）"
            ));
        }
        // Referer 用站点自身：个别网盘会看来源页
        let base = Self::site_of(ext);
        Ok(vec![CspPlay {
            url: share.to_string(),
            headers: vec![("Referer".to_string(), format!("{base}/"))],
            label: Some(pan_label(share)),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册（R3-D，2026-10-27）
// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
// 改前这一行写死在 `csp/mod.rs` 的 `build_registry()` 里。
//
// # 这个类的事实（从核心文件头搬过来，别丢）
// ```text
// csp_4KZhinan：配置里覆盖 **2 个源**（指南 / 小丑）。**纯 HTML 抓取**，
//   站点从 `ext.site` 取；播放是网盘分享页（见本文件头的能力边界）。
// ★ 解析只用本仓已有的 `regex`（**不新增运行时** —— 诚实契约第 4 条），
//   局限（不做 DOM 树）写在本文件头注释里。
// ```
crate::csp::register_site!(Zhinan);

#[cfg(test)]
#[path = "zhinan_proxy_tests.rs"]
mod proxy_tests;

// ═══════════════════════════════════════════════════════════════════════
//  测试：一半是**假 HTML**（hermetic），一半是**真网络**（CSP_LIVE=1 + #[ignore]）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实站点的一段（2026-10-26 实测抓下来后裁掉无关部分）
    const FIX_LIST: &str = r#"
<div class="posts-row"><article class="posts-item book-item d-flex style-book-v post-21156 ajax-item">
 <div class="item-header"><div class="item-media">
  <a class="item-image" href="https://4kzn.cc/book/21156.html" target="_blank">
   <img class="fill-cover lazy" src="https://4kzn.cc/t1.svg" data-src="https://img.example/a.png" alt="初恋这首情歌">
  </a></div></div>
 <div class="item-body flex-fill"><h3 class="item-title line1">
  <a href="https://4kzn.cc/book/21156.html" target="_blank">初恋这首情歌</a></h3></div>
</article><article class="posts-item book-item d-flex style-book-v post-21152 ajax-item">
 <div class="item-header"><div class="item-media">
  <a class="item-image" href="https://4kzn.cc/book/21152.html"><img data-src="https://img.example/b.png"></a>
 </div></div>
 <div class="item-body"><h3><a href="https://4kzn.cc/book/21152.html">梅格雷的亡者</a></h3></div>
</article></div>"#;

    const FIX_DETAIL: &str = r#"
<div class="d-flex flex-wrap mb-4"><div class="site-name-box flex-fill mb-3"><h1>初恋这首情歌</h1></div></div>
<div class="book-cover text-center"><img data-src="https://img.example/a.png"></div>
<div class="panel site-content card"><div><p>制片国家/地区: 爱尔兰</p><p>IMDb: tt3704428</p>
<p>下载：<a href="https://pan.quark.cn/s/d326365be5e5">夸克</a></p></div></div>"#;

    #[test]
    fn list_parses_real_markup() {
        let items = parse_list(FIX_LIST).expect("真站点片段必须解析得出来");
        assert_eq!(items.len(), 2, "两条 article 都要出来");
        assert_eq!(items[0].id, "21156");
        assert_eq!(items[0].title, "初恋这首情歌");
        assert_eq!(items[0].cover.as_deref(), Some("https://img.example/a.png"));
        assert_eq!(items[1].id, "21152");
        assert_eq!(items[1].title, "梅格雷的亡者");
    }

    #[test]
    fn list_reports_structure_change_instead_of_empty() {
        // 坏样本：站点换主题后 class 变了
        let broken = r#"<div class="card"><a href="/book/1.html">标题</a></div>"#;
        let err = parse_list(broken).unwrap_err();
        assert!(
            err.contains("结构可能变了"),
            "结构变了必须报明确原因，不能返回空列表：{err}"
        );
    }

    #[test]
    fn detail_parses_title_cover_and_pan_episodes() {
        let d = parse_detail(FIX_DETAIL).expect("详情片段必须解析得出来");
        assert_eq!(d.title, "初恋这首情歌");
        assert_eq!(d.cover.as_deref(), Some("https://img.example/a.png"));
        assert!(d.description.as_deref().unwrap_or("").contains("爱尔兰"));
        assert_eq!(d.episodes.len(), 1, "一个网盘链接 = 一条线路");
        assert_eq!(d.episodes[0].id, "https://pan.quark.cn/s/d326365be5e5");
        assert!(d.episodes[0].title.contains("夸克"), "线路名要说明是哪家网盘");
        assert!(
            d.episodes[0].title.contains("分享页"),
            "线路名必须说明这是分享页而不是直链"
        );
    }

    #[test]
    fn detail_without_title_reports_reason() {
        let err = parse_detail("<html><body>nothing</body></html>").unwrap_err();
        assert!(err.contains("找不到标题"), "缺标题要报明确原因：{err}");
    }

    #[test]
    fn categories_come_from_nav() {
        let html = r#"<a href="https://4kzn.cc/books/zuixin">最新</a>
                      <a href="https://4kzn.cc/books/hanniba">汉尼拔合集</a>
                      <a href="https://4kzn.cc/favorites/%e6%8a%80%e5%b7%a7">更多资源+</a>"#;
        let cats = parse_categories(html);
        assert_eq!(cats[0].id, "books:zuixin");
        assert_eq!(cats[0].name, "最新");
        // ★ 2026-10-27 R3 复核：`favorites/*` 是**站点导航**类分类（不是影视分类）
        //   ⇒ 默认**不收**（Owner 待定项，见 INCLUDE_NAV_SECTIONS 的长注释）
        assert!(
            !cats.iter().any(|c| c.id.starts_with("favorites:")),
            "favorites 是站点导航分类，默认不许混进影视分类表：{cats:?}"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  ★★★ 2026-10-27 R3 复核：`favorites`（sites-item）那一处
    // ═══════════════════════════════════════════════════════════════

    /// `favorites/技巧` 的真实片段（站点导航条目：**没有** /book/、标题在 <b> 里）
    ///
    /// ⚠️ 这不是"编的坏样本"，是 **2026-10-27 真网络取回**的真实 markup 摘要
    ///    （`.probe/r3-4kzhinan-review.log`；那页 6 个 article **全是**这个形态）。
    const FIX_SITES_ITEM: &str = r#"
<article class="posts-item sites-item d-flex style-sites-max post-19420 ajax-item" >
  <a href="https://4kxc.com/18433.html" class="sites-body is-views" title="免费领取夸克网盘1TB空间">
    <div class="item-image"><img class="fill-cover sites-icon lazy" data-src="https://t1.gstatic.cn/faviconV2?x=1" /></div>
  </a>
  <div class="item-body"><h3 class="item-title line1"><b>免费领取夸克网盘1TB空间，夸克每天领取容量教程</b></h3></div>
</article>"#;

    #[test]
    fn sites_item_page_reports_real_reason_not_misleading() {
        // ★ 这条守的正是 Lead 裁定的"报错文案必须能分辨形态"：
        //   改前它说"结构可能变了/被反爬" —— **骗人**（页面明明有 6 个 article）
        let err = parse_list(FIX_SITES_ITEM).unwrap_err();
        assert!(
            err.contains("sites-item"),
            "★ 报错必须点名**实际形态**（sites-item），否则又会把人往'站点挂了'带：{err}"
        );
        assert!(
            err.contains("可解析"),
            "★ 报错必须说明是「我们解析不了」而不是「页面没内容」：{err}"
        );
        assert!(
            !err.contains("被反爬"),
            "★ 不许再出现'被反爬'这种**未经证实**的归因（实测那页绕代理 8/8 都 200）：{err}"
        );
    }

    #[test]
    fn sites_item_is_never_mixed_into_video_list() {
        // ★ 反空真（铁律 149）：先证明"候选集非空"，否则下面的全称断言恒真
        assert!(
            re_item().captures_iter(FIX_SITES_ITEM).count() == 1,
            "★ 前置：这页必须有 1 个 <article> 被 re_item 匹配到（否则本测试是空转）"
        );
        // 然后：它**不许**变成影视条目
        let err = parse_list(FIX_SITES_ITEM).unwrap_err();
        assert!(
            err.contains("没有任何"),
            "sites-item 不许产出影视条目（它会被当'领网盘空间教程'混进影视列表）"
        );
    }

    #[test]
    fn empty_page_reason_distinguishes_three_cases() {
        // ① 一个 article 都没有 = 可能真没内容/结构变了
        let e1 = parse_list("<html><body>nothing</body></html>").unwrap_err();
        assert!(e1.contains("没有任何 <article>"), "① {e1}");
        // ② 有 article 但全是 sites-item
        let e2 = parse_list(FIX_SITES_ITEM).unwrap_err();
        assert!(e2.contains("sites-item") && e2.contains("全是"), "② {e2}");
        // ③ 有 article、既不是 book 也不是 sites = 结构真变了
        let e3 = parse_list(r#"<article class="posts-item book-item post-1"><div>x</div></article>"#)
            .unwrap_err();
        assert!(e3.contains("不符合 book-item 形态"), "③ {e3}");
    }

    #[test]
    fn books_pages_still_parse_normally() {
        // ★ 基线不能被我改坏：8 个 books 分类实测 8/8 全通（真网络读数见交付说明）
        let items = parse_list(FIX_LIST).expect("books 形态必须照常解析");
        assert_eq!(items.len(), 2);
    }

    #[test]
    fn nav_sections_switch_is_owner_pending() {
        // ★ 这个开关就是"Owner 选 (B)"的接入点：默认 (A) 不收
        //   ⇒ 谁把它改成 true 而不接 parse_sites_list，本测试会提醒
        assert!(
            !INCLUDE_NAV_SECTIONS,
            "默认必须是 (A)（不列 favorites）；改 true 前先接上 sites 条目的呈现"
        );
    }

    #[test]
    fn site_comes_from_ext_not_hardcoded() {
        assert_eq!(
            Zhinan::site_of(r#"{"site": ["https://4kxc.com"]}"#),
            "https://4kxc.com"
        );
        assert_eq!(Zhinan::site_of(""), DEFAULT_SITE, "没给 ext 才用兜底");
    }

    #[test]
    fn play_rejects_non_pan_and_labels_pan() {
        let z = Zhinan::new();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("rt");
        let bad = rt.block_on(z.play("", "https://example.com/x.m3u8", ""));
        assert!(bad.is_err(), "不是网盘分享页必须报错，不能假装能播");
        let err = bad.unwrap_err();
        assert!(err.contains("不是网盘分享页"), "原因要写清：{err}");

        let ok = rt
            .block_on(z.play("", "https://pan.quark.cn/s/d326365be5e5", ""))
            .expect("网盘分享页要能返回线路");
        assert_eq!(ok.len(), 1);
        assert!(ok[0].url.starts_with("https://pan.quark.cn/s/"));
        assert!(
            ok[0].label.as_deref().unwrap_or("").contains("分享页"),
            "label 必须说明这是分享页"
        );
        assert!(ok[0].headers.iter().any(|(k, _)| k == "Referer"));
    }

    // ── 真网络（默认不跑；显式跑必须给 CSP_LIVE=1，否则失败而不是静默通过）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib zhinan_live --release -- --ignored --nocapture"]
    async fn zhinan_live_home_list_detail_play() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let z = Zhinan::new();
        let ext = r#"{"site": ["https://4kzn.cc"]}"#;
        let home = z.home(ext).await.expect("首页要抓得到");
        assert!(!home.categories.is_empty(), "首页必须有分类");
        assert!(!home.items.is_empty(), "首页必须有条目");
        println!(
            "LIVE|home|分类={} 条目={} 第一个分类={:?}",
            home.categories.len(),
            home.items.len(),
            home.categories.first()
        );

        let list = z.list(&home.categories[0].id, 2, ext).await.expect("第 2 页要抓得到");
        assert!(!list.items.is_empty(), "第 2 页必须有条目");
        println!("LIVE|list2|条目={} 首个={:?}", list.items.len(), list.items.first());

        let first = home.items.first().unwrap().id.clone();
        let detail = z.detail(&first, ext).await.expect("详情要抓得到");
        assert!(!detail.title.is_empty());
        println!(
            "LIVE|detail|{first}|标题={} 剧集={} 首个线路={:?}",
            detail.title,
            detail.episodes.len(),
            detail.episodes.first()
        );
        if let Some(ep) = detail.episodes.first() {
            let play = z.play("", &ep.id, ext).await.expect("网盘分享页要能出线路");
            assert!(!play.is_empty());
            println!("LIVE|play|{}", play[0].url);
        }
    }

    /// ★★★ R3 复核（2026-10-27）：**逐分类覆盖读数** —— 哪些分类能出内容、哪些不能
    ///
    /// # 为什么单独一条（Lead 裁定 ⑤ 的硬要求）
    /// ```text
    /// 交付里必须**明确写出**该站哪些分类能出内容、哪些不能（如实，不许只写"修好了"）。
    /// ⇒ 把这条做成**可复跑的探针**，而不是"我跑过一次所以我知道"。
    /// ```
    ///
    /// # 跑法
    /// ```text
    /// CSP_LIVE=1 cargo test --lib zhinan_live_category_coverage --release \
    ///   -- --ignored --nocapture
    /// ```
    /// ⚠️ 输出里每条分类一行 `LIVE|cat|<slug>|条目=N|OK|/|ERR|<原因>`
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib zhinan_live_category_coverage --release -- --ignored --nocapture"]
    async fn zhinan_live_category_coverage() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        // 两个站都测（指南 4kzn.cc / 小丑 4kxc.com）
        for (name, site) in [("指南", "https://4kzn.cc"), ("小丑", "https://4kxc.com")] {
            let ext = format!(r#"{{"site": ["{site}"]}}"#);
            let z = Zhinan::new();
            let home = match z.home(&ext).await {
                Ok(h) => h,
                Err(e) => {
                    println!("LIVE|site|{name}|HOMEFAIL|{e}");
                    continue;
                }
            };
            println!(
                "LIVE|site|{name}|分类={} 首页条目={}",
                home.categories.len(),
                home.items.len()
            );
            let mut ok_count = 0usize;
            for c in &home.categories {
                match z.list(&c.id, 1, &ext).await {
                    Ok(l) if !l.items.is_empty() => {
                        ok_count += 1;
                        println!("LIVE|cat|{}|{}|条目={}|OK", name, c.id, l.items.len());
                    }
                    Ok(_) => println!("LIVE|cat|{}|{}|条目=0|EMPTY", name, c.id),
                    Err(e) => println!("LIVE|cat|{}|{}|ERR|{e}", name, c.id),
                }
            }
            println!(
                "LIVE|sum|{name}|可出内容={}/{}",
                ok_count,
                home.categories.len()
            );
        }
    }

    /// 真搜索页片段（2026-10-26 抓自 `https://4kzn.cc/?post_type=book&s=龙珠`，
    /// 原文 10 条，这里摘前两条；`posts-item book-item` 就是搜索结果的真实模板）
    const REAL_SEARCH_HTML: &str = r#"
<article class="posts-item book-item d-flex style-book-v post-21156">
 <div class="item-header"><div class="item-media">
  <a class="item-image" href="https://4kzn.cc/book/21156.html" target="_blank">
   <img class="fill-cover lazy" src="https://4kzn.cc/t1.svg" data-src="https://img.alicdn.com/x.png" alt="初恋"></a>
 </div></div>
 <div class="item-body flex-fill"><h3 class="item-title line1">
  <a href="https://4kzn.cc/book/21156.html" target="_blank">初恋这首情歌</a></h3></div>
</article>
<article class="posts-item book-item d-flex style-book-v post-21146">
 <div class="item-header"><div class="item-media">
  <a class="item-image" href="https://4kzn.cc/book/21146.html"><img data-src="https://img.alicdn.com/y.png"></a>
 </div></div>
 <div class="item-body"><h3><a href="https://4kzn.cc/book/21146.html">七龙珠</a></h3></div>
</article>"#;

    #[test]
    fn search_path_keeps_post_type_and_s() {
        let p1 = search_path("龙珠", 1);
        assert!(p1.contains("post_type=book"), "要按书籍类型搜：{p1}");
        assert!(p1.contains("&s="), "★ 参数名必须是 WordPress 的 `s`：{p1}");
        assert!(p1.contains("%E9%BE%99%E7%8F%A0"), "搜索词要编码：{p1}");
        let p2 = search_path("龙珠", 2);
        assert!(p2.starts_with("/page/2/"), "第 2 页走分页路径：{p2}");
        assert!(p2.contains("&s="));
    }

    #[test]
    fn parse_real_search_page_yields_items() {
        // 用**真搜索页**做夹具：不依赖网络也能证明解析口径对
        let items = parse_list(REAL_SEARCH_HTML).expect("真搜索页片段必须解析得出来");
        assert_eq!(items.len(), 2, "两条 article 都要出来：{items:?}");
        assert_eq!(items[0].id, "21156");
        assert_eq!(items[0].title, "初恋这首情歌");
        assert_eq!(items[1].id, "21146");
    }

    // ── 真网络：search（CSP_LIVE=1 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_search_zhinan --release --offline -- --ignored --nocapture"]
    async fn csp_live_search_zhinan() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 显式跑就必须给 CSP_LIVE=1（不给就失败，不许记成 ok）"
        );
        let ext = r#"{"site": ["https://4kzn.cc"]}"#;
        let site = Zhinan::new();
        /*
         * ⚠️ 关键词用「龙珠」不用「兰香如故」：实测 4kzn.cc 对「兰香如故」
         *    返回的是**0 结果的搜索页**（HTTP 200、页面里 /book/ 链接 0 个）——
         *    那是站点侧没有这个片，不是我们解析失败。用站内确实有的词才能验解析。
         */
        match site.search("龙珠", 1, ext).await {
            Ok(list) => {
                assert!(!list.items.is_empty(), "★ 搜索必须返回条目");
                eprintln!("[LIVE] 4KZhinan search: {} 条", list.items.len());
                for it in list.items.iter().take(3) {
                    eprintln!("  · id={} title={}", it.id, it.title);
                }
            }
            Err(e) => panic!("[LIVE] 4KZhinan search 失败（如实记录）：{e}"),
        }
    }
}
