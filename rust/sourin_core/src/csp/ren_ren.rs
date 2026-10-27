// ═══════════════════════════════════════════════════════════════════════
//  csp_RenRen —— 「人人电影网」的 Rust 重写（纯 HTML 抓取，**本批注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 参考（`.probe/csp25/RenRen.txt`：DEX 类 `com.github.catvod.spider.RenRen` 的字面量）
// ```text
// site   = "https://www.rrdynb.com/"
// list   = movie/list_2_ · dianshiju/list_6_ · zongyi/list_10_ · dongman/list_13_
// 列表选择器（JSOUP，逐条翻译见下）：#movielist li.pure-g.shadow
//        → a[href] · img[data-original] · h2 > a（title 属性）
// 详情：div.movie-des.shadow > h1 → 《(.*?)》；
//       div.movie-txt img；div.movie-txt 文本里取「制片国家/地区:」「剧情简介：」；
//       去 <[^>]+> / &nbsp;；正文里的 pan.baidu.com / pan.quark.cn 链接
// search = https://www.rrdynb.com/plus/search.php?q=<kw>
// ```
//
// # JSOUP 选择器 → regex 的逐条翻译（本文件只用本仓已有的 `regex`，不引 DOM 库）
// ```text
// #movielist li.pure-g.shadow
//   → `(?s)<li class="pure-g shadow">(.*?)</li>`（每条一块，块内再抽字段）
// a[href]                 → `<a[^>]+href="(/plus/view\.php\?aid=\d+)"`
// img[data-original]      → `<img[^>]+data-original="([^"]+)"`（懒加载图，不是 src）
// h2 > a（title）          → `<h2>\s*<a[^>]*title="([^"]*)"`
// div.movie-des.shadow > h1 → `<div class="movie-des shadow">\s*<h1>(.*?)</h1>`
// 标题里的《》               → `《(.*?)》`（有书名号就用，没有就用整段）
// div.movie-txt img        → `<div class="movie-txt">.*?<img[^>]+src="([^"]+)"`
// 正文去标签                → `<[^>]+>` + `&nbsp;`（上游就是这么剥的）
// 网盘链接                  → `href="(https?://[^"]*(?:pan\.baidu\.com|pan\.quark\.cn)[^"]*)"`
// ⚠️ 局限：不做 DOM 树，嵌套同名标签/属性顺序变化靠正则容错；结构一变 ⇒ **报错**（不返回空）
// ```
//
// # ★ 2026-10-28 真网实测（不是推测；读数见 `.probe/csp-live-live.log`）
// ```text
// $ curl --noproxy '*' -A <Chrome> https://www.rrdynb.com/movie/          200 · 182459 B
//   `id="movielist"` 命中 · `li class="pure-g shadow"` × 10（每页 10 条）
// $ …/movie/list_2_1.html     200 · 10 条；…/movie/list_2_2.html 200 · 10 条（翻页有效）
// $ …/zongyi/list_10_2.html   200 · 10 条
// $ …/plus/search.php?q=仙逆   200 · 33687 B · 4 条
//   ★ `&page=2` **返回同一页**（字节数一模一样 33687）⇒ 该站搜索**不支持翻页参数**
// $ …/plus/view.php?aid=62094 200 · 9728 B · h1 标题在（公开），
//   但正文被替换成「<!-- 权限限制 --> … 这篇文档需要 注册会员 才能访问，你目前是：游客或没权限会员」
//   ⇒ **网盘链接对游客不可见**（取流必须注册登录）
// ```
//
// # 与 DEX 的一处**如实偏差**
// ```text
// DEX 的 homeContent 用 `#movielist li.pure-g.shadow` 抓**首页**；
// 但 2026-10-28 的首页已换成 stui 模板（80 个 `stui-vodlist__box`），`#movielist` 只在**分类页**命中。
// ⇒ 本实现的 home 抓 `/movie/list_2_1.html`（同一选择器、真网 10 条），
//   而不是"按 DEX 打首页然后假装解析出 0 条"。分类表仍是 DEX 的 4 个。
// ```
//
// # 空结果纪律
// ```text
// home/list/search 解析出 0 条 ⇒ Err（模板改版/风控壳页）。
// detail：无标题 ⇒ Err；有标题但被权限墙挡住 ⇒ 返回**一条提示集**（id=`rr|login`），
//         play() 对该 id **明确 Err**；既无链接也无权限墙 ⇒ Err。
// ```

use async_trait::async_trait;
use regex::Regex;
use std::sync::OnceLock;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX 的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// DEX 的站点（逐字）
pub const SITE: &str = "https://www.rrdynb.com";

const TIMEOUT: Duration = Duration::from_secs(25);

/// DEX 的 4 个分类（kind, list 编号, 名字）
pub const CATS: &[(&str, &str, &str)] = &[
    ("movie", "2", "电影"),
    ("dianshiju", "6", "电视剧"),
    ("zongyi", "10", "综艺"),
    ("dongman", "13", "动漫"),
];

/// 权限墙提示集的 id / 文案
pub const TIP_ID: &str = "rr|login";
pub const WALL_TIP: &str = "需要注册会员才能看网盘链接（游客被权限墙挡住，星标提示）";

pub struct RenRen {
    client: reqwest::Client,
}

impl RenRen {
    pub const CLASS: &'static str = "RenRen";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // 本仓既定惯例：不读系统代理（否则「站点可用」会被测成「全宕」）
            .no_proxy()
            .build()
            .expect("build renren http client");
        Self { client }
    }

    async fn get(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .header(reqwest::header::REFERER, format!("{SITE}/"))
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）· 前 120 字：{}", head(&text)));
        }
        Ok(text)
    }
}

impl Default for RenRen {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  解析（纯函数；fixture 是真响应片段）
// ═══════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawItem {
    pub id: String,
    pub title: String,
    pub cover: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedDetail {
    pub title: String,
    pub cover: Option<String>,
    pub description: Option<String>,
    /// 权限墙（页面原文「这篇文档需要 注册会员 才能访问」）
    pub wall: bool,
    /// 正文里的网盘链接（登录态才会有）
    pub pan_links: Vec<String>,
}

fn re_li() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"(?s)<li class="pure-g shadow">(.*?)</li>"#).expect("rr li"))
}

fn re_aid() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    // ★ 实测两种条目链接形态（都在 `li.pure-g.shadow` 里，DEX 直接拿 `href` 当 id）：
    //   ・分类页：`/plus/view.php?aid=62094`（aid 形态）
    //   ・搜索页：`/dongman/2026/0506/58995.html`（栏目/日期形态）
    //   ⇒ 只认 aid 形态时，**搜索页会解析出 0 条**（真红过一次）
    RE.get_or_init(|| {
        Regex::new(
            r#"href="(/plus/view\.php\?aid=\d+|/[a-z]+/\d{4}/\d{4}/\d+\.html)""#,
        )
        .expect("rr href regex")
    })
}

fn re_cover() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"data-original="([^"]+)""#).expect("rr cover regex"))
}

fn re_h2_title() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"(?s)<h2>\s*<a[^>]*title="([^"]*)""#).expect("rr h2 title"))
}

fn re_h2_text() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"(?s)<h2>\s*<a[^>]*>(.*?)</a>"#).expect("rr h2 text"))
}

fn re_i_tag() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?s)<i>.*?</i>").expect("rr i tag"))
}

fn re_strip() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<[^>]+>").expect("rr strip regex"))
}

fn re_detail_h1() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"(?s)<div class="movie-des shadow">\s*<h1>(.*?)</h1>"#).expect("rr detail h1")
    })
}

fn re_book_title() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"《(.*?)》").expect("rr book title"))
}

fn re_movie_txt_img() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"(?s)<div class="movie-txt">.*?<img[^>]+src="([^"]+)""#)
            .expect("rr movie-txt img")
    })
}

fn re_pan_href() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"href="(https?://[^"]*(?:pan\.baidu\.com|pan\.quark\.cn)[^"]*)""#,
        )
        .expect("rr pan href")
    })
}

fn re_pan_bare() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"https?://(?:pan\.baidu\.com|pan\.quark\.cn)/[A-Za-z0-9/_\-\?=&%.]+"#,
        )
        .expect("rr pan bare")
    })
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#039;", "'")
        .replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

fn text_of(s: &str) -> String {
    unescape(&re_strip().replace_all(s, " "))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn abs(url: &str) -> String {
    let u = url.trim();
    if u.starts_with("http") {
        u.to_string()
    } else if u.starts_with('/') {
        format!("{SITE}{u}")
    } else {
        format!("{SITE}/{u}")
    }
}

/// 列表页路径（DEX：`movie/list_2_` + 页码 + `.html`）
pub fn category_path(kind: &str, code: &str, page: u32) -> String {
    format!("/{kind}/list_{code}_{}.html", page.max(1))
}

/// 搜索路径（DEX：`/plus/search.php?q=`）
///
/// ★ 实测：`&page=2` 返回**同一页**（字节数 33687 完全一致）⇒ 该站搜索不支持翻页参数，
///   所以 `page > 1` 在 `search()` 里**直接 Err**（不假装翻页成功）。
pub fn search_path(kw: &str, page: u32) -> String {
    format!(
        "/plus/search.php?q={}&page={}",
        urlencoding::encode(kw),
        page.max(1)
    )
}

/// 解析列表（`#movielist li.pure-g.shadow` → 每条一块）
pub fn parse_list(html: &str) -> Result<Vec<RawItem>, String> {
    let blocks: Vec<&str> = re_li()
        .captures_iter(html)
        .filter_map(|c| c.get(1).map(|m| m.as_str()))
        .collect();
    if blocks.is_empty() {
        return Err(format!(
            "页面里没有任何 `li.pure-g.shadow` 条目（模板可能改版/风控壳页）· 页面长度 {} 字节 · 前 80 字：{}",
            html.len(),
            head(html)
        ));
    }
    let mut out: Vec<RawItem> = Vec::new();
    for b in blocks {
        let Some(id) = re_aid().captures(b).map(|c| c[1].to_string()) else {
            continue;
        };        let cover = re_cover().captures(b).map(|c| abs(&c[1]));
        let title = re_h2_title()
            .captures(b)
            .map(|c| text_of(&c[1]))
            .or_else(|| {
                re_h2_text()
                    .captures(b)
                    .map(|c| text_of(&re_i_tag().replace_all(&c[1], "")))
            })
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let Some(title) = title else { continue };
        out.push(RawItem { id, title, cover });
    }
    if out.is_empty() {
        return Err("页面里有列表块但**没有一条**能解析出 aid/标题（模板可能改版）".to_string());
    }
    Ok(out)
}

/// 解析详情页
pub fn parse_detail(html: &str) -> Result<ParsedDetail, String> {
    let h1 = re_detail_h1()
        .captures(html)
        .map(|c| text_of(&c[1]))
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            format!(
                "详情页里找不到标题（模板可能改版/风控壳页）· 页面长度 {} 字节 · 前 80 字：{}",
                html.len(),
                head(html)
            )
        })?;
    let title = re_book_title()
        .captures(&h1)
        .map(|c| c[1].trim().to_string())
        .unwrap_or(h1);

    let wall = html.contains("权限限制")
        || html.contains("这篇文档需要")
        || html.contains("才能访问");

    let cover = re_movie_txt_img().captures(html).map(|c| abs(&c[1]));

    let description = html
        .split("剧情简介：")
        .nth(1)
        .map(|tail| {
            let stop = tail
                .find("</div>")
                .or_else(|| tail.find("<div"))
                .unwrap_or_else(|| tail.len().min(600));
            text_of(&tail[..stop])
        })
        .filter(|s| !s.is_empty());

    let mut pan_links: Vec<String> = Vec::new();
    for c in re_pan_href().captures_iter(html) {
        let u = unescape(&c[1]);
        if !pan_links.contains(&u) {
            pan_links.push(u);
        }
    }
    for m in re_pan_bare().find_iter(html) {
        let u = m.as_str().to_string();
        if !pan_links.contains(&u) {
            pan_links.push(u);
        }
    }

    if pan_links.is_empty() && !wall {
        return Err("详情页里既没有网盘链接、也没有权限提示（模板可能改版/风控壳页）——不能返回空详情"
            .to_string());
    }

    Ok(ParsedDetail {
        title,
        cover,
        description,
        wall,
        pan_links,
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for RenRen {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        // 见文件头「与 DEX 的一处如实偏差」：首页已换模板，`#movielist` 只在分类页命中
        let html = self
            .get(&format!("{SITE}{}", category_path("movie", "2", 1)))
            .await?;
        let categories: Vec<CspCategory> = CATS
            .iter()
            .map(|(kind, code, name)| CspCategory {
                id: format!("{kind}:{code}"),
                name: (*name).to_string(),
            })
            .collect();
        let items: Vec<CspItem> = parse_list(&html)?
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

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        let (kind, code) = tid
            .split_once(':')
            .ok_or_else(|| format!("分类 id 形态不对（应为 kind:code，如 movie:2）：`{tid}`"))?;
        if !CATS.iter().any(|(k, c, _)| *k == kind && *c == code) {
            return Err(format!("未知分类 `{tid}`（本类只有 movie:2 / dianshiju:6 / zongyi:10 / dongman:13）"));
        }
        let page = page.max(1);
        let html = self
            .get(&format!("{SITE}{}", category_path(kind, code, page)))
            .await?;
        let raw = parse_list(&html).map_err(|e| format!("分类 {tid} 第 {page} 页：{e}"))?;
        Ok(CspList {
            page,
            page_count: None,
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

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        if page > 1 {
            // ★ 实测 `&page=2` 返回同一页（字节数相同）⇒ 不假装翻页
            return Err(format!(
                "人人电影网的搜索页**不支持翻页参数**（实测 `&page=2` 与第 1 页响应字节数完全一致）\
                 ⇒ 只能取第 1 页（请求的是第 {page} 页）"
            ));
        }
        let html = self.get(&format!("{SITE}{}", search_path(kw, 1))).await?;
        let raw = parse_list(&html).map_err(|e| format!("搜索「{kw}」：{e}"))?;
        Ok(CspList {
            page: 1,
            page_count: Some(1),
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

    fn supports_search(&self) -> bool {
        // 真网实测 `?q=仙逆` 返回 4 条 ⇒ 支持（但**只有第 1 页**，见 search 的 Err 文案）
        true
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        // id 是列表里的 `href`（DEX 口径）；也接受纯数字（兼容旧调用：走 plus/view.php?aid=）
        let url = if id.starts_with('/') {
            format!("{SITE}{id}")
        } else if !id.is_empty() && id.chars().all(|c| c.is_ascii_digit()) {
            format!("{SITE}/plus/view.php?aid={id}")
        } else {
            return Err(format!("详情 id 形态不对（应为列表 href 或数字 aid）：`{id}`"));
        };
        let html = self.get(&url).await?;
        let d = parse_detail(&html)?;

        let mut episodes: Vec<CspEpisode> = d
            .pan_links
            .iter()
            .enumerate()
            .map(|(i, url)| CspEpisode {
                id: url.clone(),
                title: format!("网盘 {}", i + 1),
                flag: pan_flag(url).to_string(),
            })
            .collect();

        if episodes.is_empty() {
            if !d.wall {
                return Err(format!("「{}」没有可播剧集（页面里没有网盘链接）", d.title));
            }
            // 权限墙是**上游真实形态**（页面原文「这篇文档需要 注册会员 才能访问」）
            // ⇒ 一条提示集；play() 对它明确 Err，不伪造链接
            episodes.push(CspEpisode {
                id: TIP_ID.to_string(),
                title: WALL_TIP.to_string(),
                flag: "提示".to_string(),
            });
        }

        Ok(CspDetail {
            id: id.to_string(),
            title: d.title,
            cover: d.cover,
            description: d.description,
            episodes,
        })
    }

    async fn play(&self, flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if id == TIP_ID {
            return Err(format!(
                "「{WALL_TIP}」：真网实测详情页正文写着「这篇文档需要 注册会员 才能访问，\
                 你目前是：游客或没权限会员」⇒ 游客拿不到网盘链接（DEX 里也是靠登录态）。\
                 本仓没有该站账号，不做假通。"
            ));
        }
        if !id.starts_with("http") {
            return Err(format!("播放 id 不是 http 地址：{id}"));
        }
        Ok(vec![CspPlay {
            url: id.to_string(),
            headers: vec![
                ("Referer".to_string(), format!("{SITE}/")),
                ("User-Agent".to_string(), UA.to_string()),
            ],
            label: Some(format!("{}（网盘分享页）", if flag.is_empty() { pan_flag(id) } else { flag })),
        }])
    }
}

fn pan_flag(url: &str) -> &'static str {
    if url.contains("pan.baidu.com") {
        "百度网盘"
    } else if url.contains("pan.quark.cn") {
        "夸克网盘"
    } else {
        "网盘"
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  自注册（① 订阅里 1 站 csp_RenRen；② host 写死 rrdynb.com 且真网 200；
//  ③ 真网取到数据 —— home 10 条 / list 10 条 / search 4 条 / detail 标题）
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(RenRen);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// ★ 真响应片段（2026-10-28 抓自 `https://www.rrdynb.com/movie/`，原文 10 条，摘前 2 条）
    const FIX_LIST: &str = r#"
<ul id="movielist">
<li class="pure-g shadow"> <div class="pure-u-5-24"> <a class="movie-thumbnails" target="_blank" href="/plus/view.php?aid=62094"> <img class="pure-img" src="/static/picture/grey.gif" data-original="https://p0.pipi.cn/mediaplus/bigdata_mmdb_mmdbtask/e42958bf14d6e3a219bd6df47769f5cd01adf.png?imageView2/1/w/464/h/677" alt="不存在的罪人 Verity (2026)" /></a> </div> <div class="pure-u-19-24"> <div class="intro"> <h2> <a target="_blank" title="不存在的罪人 Verity (2026)" href="/plus/view.php?aid=62094">不存在的罪人 Verity (2026) <i>免费电影下载</i> </a> </h2> </div> </div> </li>
<li class="pure-g shadow"> <div class="pure-u-5-24"> <a class="movie-thumbnails" target="_blank" href="/plus/view.php?aid=62091"> <img class="pure-img" src="/static/picture/grey.gif" data-original="https://q6.itc.cn/q_70/images03/20260826/8798af24d88447c3b05b2f31e89da672.png" alt="末世行者 The Dog Stars (2026)" /></a> </div> <div class="pure-u-19-24"> <div class="intro"> <h2> <a target="_blank" title="末世行者 The Dog Stars (2026)" href="/plus/view.php?aid=62091">末世行者 The Dog Stars (2026) <i>免费电影下载</i> </a> </h2> </div> </div> </li>
</ul>"#;

    /// ★ 真响应片段（2026-10-28 抓自 `https://www.rrdynb.com/plus/view.php?aid=62094`）
    ///
    /// ⚠️ 用 `r##"…"##`：正文里有 `bgcolor="#DDEAC8"`，`"#` 会截断 `r#"…"#`（编译期就炸，不是运行期）。
    const FIX_DETAIL_WALL: &str = r##"
<div class="movie-des shadow"> <h1><a href="/plus/view.php?aid=62094"><u>不存在的罪人 Verity (2026)</u></a></h1>
<div class="movie-txt"> <!-- 权限限制 --> <div class="w960 clear center mt1 cmt-box"> <div class="formbox"> <table width="100%" border="0" cellpadding="3" cellspacing="1" bgcolor="#DDEAC8"> <tr bgcolor="#FFFFFF"> <td height="60" colspan="2" align="center"> 这篇文档需要 <font color='red'>注册会员</font> 才能访问，你目前是：<font color='red'>游客或没权限会员</font> ！ </td> </tr> </table> </div> </div> <!-- 权限限制--end --> </div> </div>"##;

    /// 登录态才会出现的形态（结构照 DEX 的 `div.movie-txt` + 网盘链接口径拼装；**未取得登录态真样本**）
    const FIX_DETAIL_MEMBER: &str = r#"
<div class="movie-des shadow"><h1><a href="x"><u>《示例片》</u></a></h1>
<div class="movie-txt"><div>制片国家/地区: 美国</div><div>剧情简介：一个示例简介文本。</div>
<a href="https://pan.quark.cn/s/abc123">夸克网盘</a></div></div>"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(RenRen::CLASS, "RenRen");
    }

    #[test]
    fn list_parses_real_markup() {
        let items = parse_list(FIX_LIST).expect("真站点片段必须解析得出来");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "/plus/view.php?aid=62094", "id 就是列表 href（DEX 口径）");
        assert_eq!(items[0].title, "不存在的罪人 Verity (2026)");
        assert_eq!(
            items[0].cover.as_deref(),
            Some("https://p0.pipi.cn/mediaplus/bigdata_mmdb_mmdbtask/e42958bf14d6e3a219bd6df47769f5cd01adf.png?imageView2/1/w/464/h/677"),
            "★ 封面是 data-original（懒加载），不是 src"
        );
        assert_eq!(items[1].id, "/plus/view.php?aid=62091");
    }

    /// ★ 真缺陷回归：搜索结果的条目链接是 **`/栏目/年/月日/aid.html`**，不是 `plus/view.php?aid=`
    ///
    /// ```text
    /// 我第一版只认 aid 形态 ⇒ 真网 `search("仙逆")` **解析出 0 条**（真红，已修）。
    /// 夹具是 2026-10-28 真搜索页片段（原文 4 条，摘 1 条）。
    /// ```
    const FIX_SEARCH: &str = r#"
<li class="pure-g shadow"> <div class="pure-u-5-24"> <a class="movie-thumbnails" target="_blank" href="/dongman/2026/0506/58995.html"> <img class="pure-img" src="/static/picture/grey.gif" data-original="https://pub-97227ae664d641529316b62be989aeb7.r2.dev/001/1/p2931671694%20(1).jpg" alt="《仙逆 年番3》" /></a> </div> <div class="pure-u-19-24"> <div class="intro"> <h2> <a target="_blank" title="《仙逆 年番3》百度云网盘夸克下载" href="/dongman/2026/0506/58995.html">《仙逆 年番3》百度云网盘夸克下载 <i>免费电影下载</i> </a> </h2> </div> </div> </li>"#;

    #[test]
    fn search_results_parse_the_category_date_link_shape() {
        let items = parse_list(FIX_SEARCH).expect("搜索页形态必须解析得出来（否则搜索恒 Err）");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "/dongman/2026/0506/58995.html");
        assert!(items[0].title.contains("仙逆 年番3"), "{}", items[0].title);
    }

    #[test]
    fn empty_list_reports_structure_change() {
        let err = parse_list("<html><body>nothing</body></html>").unwrap_err();
        assert!(
            err.contains("模板可能改版") && err.contains("风控壳页"),
            "空结果必须 Err：{err}"
        );
    }

    #[test]
    fn detail_wall_is_a_real_shape_not_an_empty_detail() {
        let d = parse_detail(FIX_DETAIL_WALL).expect("权限墙是可识别形态");
        assert_eq!(d.title, "不存在的罪人 Verity (2026)");
        assert!(d.wall, "★ 必须识别「这篇文档需要 注册会员 才能访问」");
        assert!(d.pan_links.is_empty(), "游客页没有网盘链接");
        assert!(d.description.is_none());
    }

    #[test]
    fn member_detail_extracts_book_title_and_pan() {
        let d = parse_detail(FIX_DETAIL_MEMBER).expect("登录态形态要能解析");
        assert_eq!(d.title, "示例片", "有《》就取书名号里的");
        assert!(!d.wall);
        assert_eq!(d.pan_links, vec!["https://pan.quark.cn/s/abc123".to_string()]);
        assert!(d.description.as_deref().unwrap_or("").contains("示例简介"));
    }

    #[test]
    fn detail_without_wall_or_links_reports_reason() {
        let err = parse_detail("<html><body>nothing</body></html>").unwrap_err();
        assert!(err.contains("找不到标题"), "{err}");
        let err2 = parse_detail(r#"<div class="movie-des shadow"><h1><u>T</u></h1></div>"#)
            .unwrap_err();
        assert!(err2.contains("既没有网盘链接"), "{err2}");
    }

    #[test]
    fn category_paths_match_the_live_site() {
        assert_eq!(category_path("movie", "2", 1), "/movie/list_2_1.html");
        assert_eq!(category_path("movie", "2", 2), "/movie/list_2_2.html");
        assert_eq!(category_path("zongyi", "10", 2), "/zongyi/list_10_2.html");
        assert_eq!(search_path("仙逆", 1), "/plus/search.php?q=%E4%BB%99%E9%80%86&page=1");
    }

    #[tokio::test]
    async fn search_page_two_refuses_without_touching_the_network() {
        // 实测 `&page=2` 与第 1 页响应字节数相同 ⇒ 必须明确 Err（不许假装翻页）
        let s = RenRen::new();
        let err = s.search("仙逆", 2, "").await.expect_err("第 2 页必须 Err");
        assert!(err.contains("不支持翻页"), "{err}");
        assert!(err.contains("字节数"), "要给实测依据：{err}");
    }

    #[tokio::test]
    async fn play_refuses_the_wall_tip_and_labels_real_links() {
        let s = RenRen::new();
        let e = s.play("提示", TIP_ID, "").await.expect_err("提示集必须 Err");
        assert!(e.contains("注册会员") && e.contains("不做假通"), "{e}");
        let ok = s
            .play("夸克网盘", "https://pan.quark.cn/s/abc123", "")
            .await
            .expect("真链接要能返回");
        assert_eq!(ok.len(), 1);
        assert!(ok[0].label.as_deref().unwrap_or("").contains("分享页"));
    }

    #[test]
    fn it_is_registered() {
        assert!(
            crate::csp::is_implemented("csp_RenRen"),
            "★ csp_RenRen 必须已注册（订阅 1 站 + host 可用 + 真网有数据）"
        );
        assert_eq!(
            crate::csp::route("csp_RenRen").expect("route").class(),
            "RenRen"
        );
    }

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp::ren_ren::tests::renren_live -- --ignored --nocapture"]
    async fn renren_live() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = RenRen::new();
        let home = s.home("").await.expect("home 必须取到数据");
        println!(
            "LIVE|renren|home|分类={} 条目={}",
            home.categories.len(),
            home.items.len()
        );
        assert_eq!(home.categories.len(), 4);
        assert!(!home.items.is_empty());
        let l2 = s.list("movie:2", 2, "").await.expect("list 第 2 页必须取到数据");
        println!("LIVE|renren|list2|条目={} 首个={:?}", l2.items.len(), l2.items.first());
        assert!(!l2.items.is_empty());
        let sr = s.search("仙逆", 1, "").await.expect("search 必须取到数据");
        println!("LIVE|renren|search|条目={} 首个={:?}", sr.items.len(), sr.items.first());
        assert!(!sr.items.is_empty());
        let first = home.items.first().unwrap().id.clone();
        let d = s.detail(&first, "").await.expect("detail 必须取到数据");
        println!(
            "LIVE|renren|detail|id={first}|标题={} 剧集={} 首个={:?}",
            d.title,
            d.episodes.len(),
            d.episodes.first()
        );
        assert!(!d.title.is_empty());
    }
}