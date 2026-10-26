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
    client: reqwest::Client,
}

impl Zhinan {
    pub const CLASS: &'static str = "4KZhinan";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
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

fn strip_tags(s: &str) -> String {
    let t = re_tag().replace_all(s, " ");
    let t = t.replace("&amp;", "&").replace("&nbsp;", " ").replace("&quot;", "\"");
    t.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 解析一页 HTML 里的列表项
///
/// ⚠️ 返回 `Err` 的条件是"一页里连一个 article 都没有" —— 那是**页面结构变了**
///    或**被反爬挡了**，必须如实报错（返回空列表会让用户以为"这个分类没内容"）。
pub fn parse_list(html: &str) -> Result<Vec<RawItem>, String> {
    let mut out = Vec::new();
    for cap in re_item().captures_iter(html) {
        let block = &cap[1];
        let Some(idc) = re_book_id().captures(block) else {
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
        return Err("页面里没有任何列表项（站点结构可能变了，或被反爬挡了）".to_string());
    }
    Ok(out)
}

/// 解析导航里的分类（`/books/x`、`/favorites/x`）
pub fn parse_categories(html: &str) -> Vec<CspCategory> {
    let mut out: Vec<CspCategory> = Vec::new();
    for cap in re_nav().captures_iter(html) {
        let kind = &cap[1];
        let slug = &cap[2];
        let name = strip_tags(&cap[3]);
        if name.is_empty() || name.chars().count() > 12 {
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

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("4KZhinan 不支持搜索（该类的搜索是 HTML（?post_type=book&s=），尚未实现）".to_string())
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
        assert!(cats.iter().any(|c| c.id.starts_with("favorites:")));
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
}
