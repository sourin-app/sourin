// ═══════════════════════════════════════════════════════════════════════
//  csp_TingJinxia —— 「堇夏听书」（m.ting15.com）的 Rust 重写（**本批注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么**有** `register_site!`（三条判据同时成立，逐条给证据）
// ```text
// ① 订阅里 1 站：`.probe/ref-subscription.json` → sites[] api=csp_TingJinxia
//    （`searchable: 1`，且这是本批 5 类里**唯一**给 ext 的：`"https://m.ting15.com"`）
// ② 有可用 host：ext 直接给了裸 URL（不是 JSON）—— 所以 `host_of` 必须**两种都收**
// ③ 真网取到数据（2026-10-28 00:0x 直连 `--noproxy '*'`，读数见 `.probe/csp-sports-live.log`）：
//    home 1 页（9 分类 + 8 条推荐）· 分类页 1 页 60 条 · 详情 1 本（3977 集）
//    · 搜索「无敌剑域」1 条 · 取流真拿到 m4a：`https://oss-links.guoguo.org.cn/…/0001.m4a`
// ```
//
// # 协议（DEX 常量 + 站点 JS 逐字还原，**不是猜**）
// ```text
// 站型：m.ting15.com 是**移动版**（`m.` + `/lianting/m/*.js`），桌面版 www 的路径不同
//
// home    GET  {host}/                                  → `nav.nav a[href]` 分类 + `section.tuijian .tlist a` 推荐
// list    GET  {host}/{slug}/            （第 1 页）
//              {host}/{slug}/index{N}.html（N≥2；`-order-addtime` 是"按时间排"，本实现不接）
//         → `.clist a > dl`：`dt img[src]` / `dd h3` / `dd p`（类别/作者/播音/时间）
//         页码：`.cpage` 里 `页次<span>1/34</span>`
// detail  GET  {host}{item_href}                        → `.binfo h1` 标题 / `.bimg img[src]` 封面
//                                                          `.intro p` 简介 / `.plist a.f` 分集
// search  GET  {host}/?s=ting-search-wd-{kw}            → 与分类页同一种 `.clist` 片段
// play    ★ 分集页**没有** `<audio src>`（`<audio id="player"></audio>` 是空的）——
//         地址由 `n2.js` 用 **POST** 换回来：
//           POST {host}/?s=api-getneoplay
//                header `xt: <meta name="_c">`      ← ★ 缺这个头就只回 `{"url":null,"status":1}`
//                form   bookId=<meta _b>&isPay=<meta _p>&page=<meta _cp>
//           → {url, ourl, status}；`ourl` 非空取 ourl，否则取 url
//         ★ 这一步**实测成功**（真拿到 m4a），不是"照文档猜一个能跑的形状"
// ```
//
// # 改前错在哪（本文件写之前，同一批的通用错法）
// ```text
// · 把 `${host}/?s=api-getneoplay` 当 GET 取：站点回 `{"url":null,"status":1}`，
//   看着"有 JSON"就当成"可播但没地址" ⇒ 会把**能用**的源误判成不可用。
//   真的是 **POST + `xt` 头**；`xt` 来自分集页的 `<meta name="_c">`（每集不同）。
// · 把 `.cpage` 的 `1/34` 当"共 34 页"以外的字段读（如从 `next` 链接里数）：
//   末页没有 `next` ⇒ 数字会少 1。直接读 `页次` 才是准的。
// · 用 www.ting15.com：那是另一个站型（`/?s=map-show-id-…`），移动端的 `.clist` 结构在那边对不上。
// ```
//
// ⚠️ 局限（如实登记，不粉饰）：解析用本仓已有的 `regex`，**不建 DOM 树**；
//    HTML 里标签换行/属性顺序变化靠"宽松模式"扛，真改版时会在**空结果 ⇒ Err** 上响。

use async_trait::async_trait;
use regex::Regex;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `init()` 的 UA（逐字；站点按 UA 分移动/桌面两套模板）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// DEX 里 `play` 的固定头模板：`@Referer=https://m.ting15.com/@User-Agent=…`
/// （音频 CDN 认 Referer，缺了会 403 —— 与 `CspPlay::headers` 的注释同一件事）
pub const PLAY_REFERER: &str = "https://m.ting15.com/";

const TIMEOUT: Duration = Duration::from_secs(20);

const DEFAULT_HOST: &str = "https://m.ting15.com";

/// DEX `homeContent` 里 9 组 slug/name（逐字，**含顺序**）
///
/// # 为什么写死成常量而不是只依赖 live nav
/// nav 里有 3 项是 `style="display:none"`（曲艺戏曲/相声小品/助眠音频），
/// 只按"可见"解析会少 3 个分类；DEX 给的这 9 组才是站点自己的分类表。
/// live nav 仍然照解析（站点加分类时能跟上），两边按 slug 去重合并。
pub const DEX_CATS: &[(&str, &str)] = &[
    ("wuxiaxuanhuan", "武侠玄幻"),
    ("kongbulingyi", "恐怖灵异"),
    ("tuilixuanyi", "推理悬疑"),
    ("dushiyanqing", "都市言情"),
    ("jiatinglunli", "家庭伦理"),
    ("wenxuemingzhu", "文学名著"),
    ("jingdianpingshu", "经典评书"),
    ("quyixiqu", "曲艺戏曲"),
    ("xiangshengxiaopin", "相声小品"),
];

/// DEX 里补的"全部"分类（首项）
pub const ALL_CAT: &str = "全部";

/// ext → host
///
/// # 两种形态都要收（这是本类的**硬约束**，不是宽容）
/// ```text
/// 订阅里写的是裸字符串：  "https://m.ting15.com"
/// 但 ext 的通用语义是"一段文本"，别的配置可能给对象：{"host":"https://…"}
/// ⇒ 先试"整段就是 URL"，再试取 JSON 键。少收一种，站点就会静默变成"无 host"。
/// ```
pub fn host_of(ext: &str) -> Option<String> {
    let t = ext.trim();
    if t.is_empty() {
        return Some(DEFAULT_HOST.to_string());
    }
    if t.starts_with("http://") || t.starts_with("https://") {
        return Some(t.trim_end_matches('/').to_string());
    }
    let j = crate::tvbox::parse_loose_json(t).ok()?;
    let pick = |k: &str| -> Option<String> {
        j.get(k)
            .and_then(|v| v.as_str())
            .map(|s| s.trim().trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
    };
    pick("host")
        .or_else(|| pick("site"))
        .or_else(|| pick("base"))
        .or(Some(DEFAULT_HOST.to_string()))
}

pub struct TingJinxia {
    client: reqwest::Client,
}

impl TingJinxia {
    pub const CLASS: &'static str = "TingJinxia";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build ting_jinxia http client");
        Self { client }
    }

    async fn get_text(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(
                reqwest::header::ACCEPT,
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            )
            .header(reqwest::header::REFERER, PLAY_REFERER)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）：{}", head(&text)));
        }
        Ok(text)
    }
}

impl Default for TingJinxia {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

/// 去掉行首 BOM（站点回的是 `﻿<!DOCTYPE`，不去会让 `<!DOCTYPE` 判断失效）
fn no_bom(s: &str) -> &str {
    s.trim_start_matches('\u{feff}')
}

/// 极简实体还原（只处理站点实际出现的几个；不做通用 HTML 解码）
fn unescape(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .trim()
        .to_string()
}

/// 分类：DEX 的 9 组 + live nav 里多出来的（按 slug 去重），首项补"全部"
pub fn parse_categories(html: &str) -> Vec<CspCategory> {
    let h = no_bom(html);
    let mut extra: Vec<CspCategory> = Vec::new();
    // live nav：`<a href="/wuxiaxuanhuan/" title="武侠玄幻" class="c2">`
    let nav = Regex::new(r#"(?s)<a\s+href="/([a-z0-9_]+)/"(?:\s+title="([^"]*)")?[^>]*>"#).unwrap();
    for c in nav.captures_iter(h) {
        let slug = c.get(1).map(|m| m.as_str()).unwrap_or("");
        if slug.is_empty() {
            continue;
        }
        // 只认导航区里的（`<nav …>` 到 `</nav>`），否则正文里的分类链接会混进来
        let at = c.get(0).map(|m| m.start()).unwrap_or(0);
        if !in_nav(h, at) {
            continue;
        }
        let name = c.get(2).map(|m| unescape(m.as_str())).unwrap_or_default();
        if name.is_empty() {
            continue;
        }
        if DEX_CATS.iter().any(|(s, _)| *s == slug) || extra.iter().any(|c| c.id == slug) {
            continue;
        }
        extra.push(CspCategory { id: slug.to_string(), name });
    }
    let mut cats: Vec<CspCategory> = DEX_CATS
        .iter()
        .map(|(s, n)| CspCategory { id: (*s).to_string(), name: (*n).to_string() })
        .collect();
    cats.append(&mut extra);
    cats.insert(0, CspCategory { id: String::new(), name: ALL_CAT.to_string() });
    cats
}

/// 位置 `at` 是否落在 `<nav …>` 与 `</nav>` 之间
fn in_nav(html: &str, at: usize) -> bool {
    let end = at.min(html.len());
    match (html[..end].rfind("<nav"), html[..end].rfind("</nav>")) {
        (Some(o), Some(c)) => o > c,
        (Some(_), None) => true,
        _ => false,
    }
}

/// 解析一页 `.clist` 条目（分类页 / 搜索页 / 首页推荐共用同一种 `<dl>` 结构）
///
/// # 为什么返回 `Result` 而不是空 Vec（本类的核心纪律）
/// ```text
/// 0 条 ⇒ 站点**改版**或给了**风控壳页**（200 但内容不是书目）。
/// 这时候回 `Ok(vec![])` 会让上层显示"这个源没内容"，把判断权从用户手里拿走。
/// ```
pub fn parse_items(html: &str, where_: &str) -> Result<Vec<CspItem>, String> {
    let h = no_bom(html);
    let block = Regex::new(r#"(?s)<a\s+href="([^"]+\.html)"[^>]*>\s*<dl>(.*?)</dl>"#).unwrap();
    let h3 = Regex::new(r"(?s)<h3[^>]*>(.*?)</h3>").unwrap();
    let img = Regex::new(r#"(?s)<img[^>]*src="([^"]+)""#).unwrap();
    let desc = Regex::new(r#"(?s)<p class="desc">(.*?)</p>"#).unwrap();
    let author = Regex::new(r"(?s)作者：([^<]*)").unwrap();
    let mut items = Vec::new();
    for c in block.captures_iter(h) {
        let href = c.get(1).map(|m| m.as_str()).unwrap_or("").trim().to_string();
        let body = c.get(2).map(|m| m.as_str()).unwrap_or("");
        let title = h3
            .captures(body)
            .and_then(|m| m.get(1))
            .map(|m| unescape(m.as_str()))
            .unwrap_or_default();
        if href.is_empty() || title.is_empty() {
            continue; // 广告位/推荐位的空 `<dl>` 不算条目
        }
        let cover = img
            .captures(body)
            .and_then(|m| m.get(1))
            .map(|m| m.as_str().to_string())
            .filter(|s| s.starts_with("http"));
        let sub = author
            .captures(body)
            .and_then(|m| m.get(1))
            .map(|m| unescape(m.as_str()))
            .filter(|s| !s.is_empty())
            .or_else(|| {
                desc.captures(body)
                    .and_then(|m| m.get(1))
                    .map(|m| unescape(m.as_str()))
                    .filter(|s| !s.is_empty())
            });
        items.push(CspItem { id: href, title, cover, subtitle: sub });
    }
    // ★ 2026-10-29 真网复测（别把这个 Err 当成"站点改版"的判据）：
    //   `https://m.ting15.com/?s=ting-search-wd-老舅` → **200 / 3227 B**，
    //     页里逐字 `<h1>搜索“老舅”结果</h1>` + `<div class="clist">` **空** +
    //     `页次<span>1/1</span>`，`a[href$=.html]` 一个都没有 ⇒ 走下面这个 Err。
    //   同一模板换有内容的词：`?s=ting-search-wd-无敌剑域` → **200 / 3795 B**，
    //     `.clist a > dl > h3` 里 1 条（`<a href="/wuxiaxuanhuan/2117.html">…<h3>无敌剑域</h3>`）。
    //   ⇒ 判据：**这个词本来就没有**；解析器没坏（换词能出就是硬证据）。
    if items.is_empty() {
        return Err(format!(
            "{where_} 没解析出条目（页面 {} 字节）——可能是站点真的没有这个词，\
             也可能是站点改版/风控壳页：`.clist a > dl > h3` 里一个书名都没有。\
             已实现的判据：`a[href$=.html]` 内的 `<h3>` 标题。",
            h.len()
        ));
    }
    Ok(items)
}

/// `.cpage` 的 `页次<span>1/34</span>` → 34
pub fn parse_page_count(html: &str) -> Option<u32> {
    let re = Regex::new(r"页次\s*<span>\s*\d+\s*/\s*(\d+)\s*</span>").unwrap();
    re.captures(html)
        .and_then(|c| c.get(1))
        .and_then(|m| m.as_str().parse::<u32>().ok())
        .filter(|n| *n > 0)
}

/// 详情页 → `CspDetail`（0 集 ⇒ Err：**没有分集的听书页**等于没取到东西）
pub fn parse_detail_page(html: &str, id: &str) -> Result<CspDetail, String> {
    let h = no_bom(html);
    let title = Regex::new(r#"(?s)<div class="binfo">\s*<h1[^>]*>(.*?)</h1>"#)
        .unwrap()
        .captures(h)
        .and_then(|c| c.get(1))
        .map(|m| unescape(m.as_str()))
        .unwrap_or_default();
    if title.is_empty() {
        return Err(format!(
            "详情页 {id} 没有 `.binfo h1` 标题（页面 {} 字节）——可能站点改版/风控壳页",
            h.len()
        ));
    }
    let cover = Regex::new(r#"(?s)<div class="bimg">\s*<img[^>]*src="([^"]+)""#)
        .unwrap()
        .captures(h)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .filter(|s| s.starts_with("http"));
    // 简介：`<div class="intro">` 里第一个 `<p>`（带 style 的那个 intro 是"下载 APP"广告）
    let description = Regex::new(r#"(?s)<div class="intro">\s*<p[^>]*>(.*?)</p>"#)
        .unwrap()
        .captures(h)
        .and_then(|c| c.get(1))
        .map(|m| super::hxq::clean_intro(m.as_str()))
        .filter(|s| !s.is_empty());
    let ep_re = Regex::new(r#"(?s)<a class="f" href="([^"]+)"[^>]*>(.*?)</a>"#).unwrap();
    let mut episodes: Vec<CspEpisode> = Vec::new();
    for c in ep_re.captures_iter(h) {
        let href = c.get(1).map(|m| m.as_str()).unwrap_or("").trim().to_string();
        let name = c.get(2).map(|m| unescape(m.as_str())).unwrap_or_default();
        if href.is_empty() {
            continue;
        }
        episodes.push(CspEpisode {
            id: href,
            title: if name.is_empty() { "分集".to_string() } else { name },
            flag: "音频".to_string(),
        });
    }
    if episodes.is_empty() {
        return Err(format!(
            "「{title}」没有可播分集（`.plist a.f` 为空，详情页 {} 字节）——可能站点改版/风控壳页",
            h.len()
        ));
    }
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover,
        description,
        episodes,
    })
}

/// 分集页里的 `<meta>`（`api-getneoplay` 要的三个值 + 播放格式）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EpisodeMeta {
    pub book_id: String,
    pub is_pay: String,
    /// 分集序号（站点叫 `page`，不是分页）
    pub page: String,
    /// `_c`：**必须**放进 `xt` 请求头，否则服务端只回 `{"url":null,"status":1}`
    pub xt: String,
    pub fmt: String,
}

fn meta(h: &str, name: &str) -> Option<String> {
    let re = Regex::new(&format!(r#"<meta name="{}" content="([^"]*)""#, regex::escape(name))).unwrap();
    re.captures(h)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .filter(|s| !s.is_empty())
}

pub fn parse_episode_meta(html: &str) -> Result<EpisodeMeta, String> {
    let h = no_bom(html);
    let book_id = meta(h, "_b")
        .ok_or_else(|| "分集页缺少 `<meta name=\"_b\">`（书号）——可能站点改版".to_string())?;
    let xt = meta(h, "_c").ok_or_else(|| {
        "分集页缺少 `<meta name=\"_c\">`（`xt` 头）——缺它 api-getneoplay 只会回 url:null".to_string()
    })?;
    Ok(EpisodeMeta {
        book_id,
        is_pay: meta(h, "_p").unwrap_or_else(|| "0".to_string()),
        page: meta(h, "_cp").unwrap_or_else(|| "1".to_string()),
        xt,
        fmt: meta(h, "_f").unwrap_or_else(|| "m4a".to_string()),
    })
}

/// `api-getneoplay` 的响应 → 真正地址（`ourl` 优先，其次 `url`）
///
/// # 为什么 `status != 1` 不直接判错
/// ```text
/// 站点对"收费集"回 `status: -1` 且 url/ourl 都空 —— 那不是协议错，是**这一集要付费**。
/// 但本实现只报"没有地址"，不替用户猜"是不是收费"（页面上那句提示在 JS 里，不在这份 JSON 里）。
/// ```
pub fn parse_play_json(text: &str) -> Result<String, String> {
    let t = no_bom(text).trim();
    let v: Value = crate::tvbox::parse_loose_json(t)
        .map_err(|e| format!("api-getneoplay 不是 JSON：{e}（前 120 字：{}）", head(t)))?;
    let pick = |k: &str| {
        v.get(k)
            .and_then(|x| x.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    };
    if let Some(u) = pick("ourl").or_else(|| pick("url")) {
        return Ok(u);
    }
    Err(format!(
        "api-getneoplay 没有地址（status={}，键 url/ourl 都空或为 null）——\
         常见原因：① 缺 `xt` 头 ② 该集收费 ③ 该集已下架",
        v.get("status").map(|s| s.to_string()).unwrap_or_else(|| "?".to_string())
    ))
}

// ══ 类自注册（三条判据都成立，见文件头）══
crate::csp::register_site!(TingJinxia);

#[async_trait]
impl CspSite for TingJinxia {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = host_of(ext).ok_or_else(|| "TingJinxia 无法从 ext 得到 host".to_string())?;
        let html = self.get_text(&format!("{host}/")).await?;
        let categories = parse_categories(&html);
        if categories.len() <= 1 {
            return Err(format!(
                "{host} 首页没有解析出分类（只有「全部」）——可能站点改版/风控壳页"
            ));
        }
        // 首屏：`section.tuijian .tlist a`（与分类页同一种 `<dl>`，复用 parse_items）
        let items = parse_items(&html, "首页推荐位").unwrap_or_default();
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let host = host_of(ext).ok_or_else(|| "TingJinxia 无法从 ext 得到 host".to_string())?;
        let page = if page == 0 { 1 } else { page };
        let slug = tid.trim();
        if slug.is_empty() {
            return Err(
                "TingJinxia 分类 id 为空（「全部」没有对应的列表页 —— 站点没有全站列表）".to_string()
            );
        }
        // ★ 第 1 页是 `/{slug}/`，第 N 页是 `/{slug}/index{N}.html`（站点真实路径，别自作主张拼 index1）
        let url = if page == 1 {
            format!("{host}/{slug}/")
        } else {
            format!("{host}/{slug}/index{page}.html")
        };
        let html = self.get_text(&url).await?;
        let items = parse_items(&html, &format!("分类 {slug} 第 {page} 页"))?;
        Ok(CspList {
            items,
            page,
            page_count: parse_page_count(&html),
            total: None,
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("TingJinxia 搜索关键词为空".to_string());
        }
        let host = host_of(ext).ok_or_else(|| "TingJinxia 无法从 ext 得到 host".to_string())?;
        if page > 1 {
            // 站点搜索结果页没有分页参数（`ting-search-wd-<kw>` 只出第 1 页）
            return Err(format!("TingJinxia 搜索不分页（站点只提供第 1 页，请求的是第 {page} 页）"));
        }
        let url = format!("{host}/?s=ting-search-wd-{}", urlencoding::encode(kw));
        let html = self.get_text(&url).await?;
        let items = parse_items(&html, &format!("搜索「{kw}」"))?;
        Ok(CspList { items, page: 1, page_count: None, total: None })
    }

    fn supports_search(&self) -> bool {
        true // 已实测：`?s=ting-search-wd-无敌剑域` 回 1 条（站点自己的搜索路由）
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let host = host_of(ext).ok_or_else(|| "TingJinxia 无法从 ext 得到 host".to_string())?;
        let path = id.trim();
        if path.is_empty() {
            return Err("TingJinxia detail 的 id 为空".to_string());
        }
        let url = if path.starts_with("http") { path.to_string() } else { format!("{host}{path}") };
        let html = self.get_text(&url).await?;
        parse_detail_page(&html, path)
    }

    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let host = host_of(ext).ok_or_else(|| "TingJinxia 无法从 ext 得到 host".to_string())?;
        let path = id.trim();
        if path.is_empty() {
            return Err("TingJinxia play 的 id 为空".to_string());
        }
        let ep_url = if path.starts_with("http") { path.to_string() } else { format!("{host}{path}") };
        let html = self.get_text(&ep_url).await?;
        let m = parse_episode_meta(&html)?;
        // ★ POST + `xt` 头（GET 或不带 xt 都只会拿到 `{"url":null,"status":1}`）
        let resp = self
            .client
            .post(format!("{host}/?s=api-getneoplay"))
            .header("xt", &m.xt)
            .header(reqwest::header::REFERER, ep_url.clone())
            .header(reqwest::header::ACCEPT, "application/json, text/javascript, */*; q=0.01")
            .header(
                reqwest::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded; charset=UTF-8",
            )
            .form(&[
                ("bookId", m.book_id.as_str()),
                ("isPay", m.is_pay.as_str()),
                ("page", m.page.as_str()),
            ])
            .send()
            .await
            .map_err(|e| format!("取流请求失败（{ep_url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("取流响应读取失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("取流 HTTP {status}：{}", head(&text)));
        }
        let url = parse_play_json(&text)?;
        Ok(vec![CspPlay {
            url,
            headers: vec![
                ("Referer".to_string(), PLAY_REFERER.to_string()),
                ("User-Agent".to_string(), UA.to_string()),
            ],
            label: Some(if flag.trim().is_empty() {
                m.fmt
            } else {
                format!("{flag}（{}）", m.fmt)
            }),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实响应片段（2026-10-28 00:0x 直连 `--noproxy '*'` 抓的 `/wuxiaxuanhuan/` 前两条，
    /// 属性顺序/换行**原样保留**）—— **不是 mock**，是站点当时吐的字节
    const REAL_LIST: &str = r#"<div class="clist">
	   <a href="/wuxiaxuanhuan/2117.html">
      <dl>
       <dt>
        <img src="https://img-book-oss.guoguo.org.cn/Upload/ting/20260720161400.jpg" alt="无敌剑域" width="75" height="100" />
       </dt>
       <dd>
        <h3>无敌剑域</h3>
           <p>类别：武侠玄幻</p>
          <p>作者：青鸾峰上</p>
          <p>播音：有声的紫襟</p>
          <p>时间：2026-07-20 16:17:16</p>
       </dd>
      </dl></a><a href="/wuxiaxuanhuan/2114.html">
      <dl>
       <dt>
        <img src="https://img-book-oss.guoguo.org.cn/Upload/ting/20260720095940.jpg" alt="我身上有条龙" width="75" height="100" />
       </dt>
       <dd>
        <h3>我身上有条龙</h3>
           <p>类别：武侠玄幻</p>
          <p>作者：香辣小龙虾</p>
          <p>播音：一种侃侃</p>
          <p>时间：2026-07-20 10:02:21</p>
       </dd>
      </dl></a>    </div>
    <div class="cpage">
     <span class="prev disabled">上一页</span><a href="/wuxiaxuanhuan/index2.html" class="next pagegbk" data="p-2">下一页</a>&nbsp;页次<span>1/34</span>    </div>"#;

    /// 真实详情页片段（同一本书；分集只留前 3 条）
    const REAL_DETAIL: &str = r#"<div class="book">
     <div class="bimg">
      <img width="120" height="160" src="https://img-book-oss.guoguo.org.cn/Upload/ting/20260720161400.jpg" alt="无敌剑域有声小说" />
     </div>
     <div class="binfo">
      <h1>无敌剑域</h1>
      <p>播音：有声的紫襟</p>
      <p>作者：青鸾峰上</p>
      <p>状态：完本</p>
     </div>
    </div>
    <div class="intro">
     <p>如果杀人不是为了装X，那将毫无意义。</p>
    </div>
    <div class="playlist">
     <h2>分集收听(共3977集)</h2>
     <div class="plist">
     	<a class="f" href="/wuxiaxuanhuan/2117/0-1.html">1</a>
                 <a class="f" href="/wuxiaxuanhuan/2117/0-2.html">2</a>
                 <a class="f" href="/wuxiaxuanhuan/2117/0-3.html">3</a>"#;

    /// 真实分集页的 `<meta>` 区（`_c` 是那一集的 xt）
    const REAL_EP_META: &str = r#"  <meta name="_c" content="94b982cb2394023dd698088b615eccc8" />
  <meta name="_b" content="2117" />
  <meta name="_h" content="1" />
  <meta name="_cp" content="1" />
  <meta name="_m" content="3977" />
  <meta name="_p" content="11" />"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(TingJinxia::CLASS, "TingJinxia");
    }

    #[test]
    fn must_be_registered_this_batch() {
        assert!(
            crate::csp::is_implemented("csp_TingJinxia"),
            "★ 三条判据成立（订阅 1 站 / ext 给了 host / 真网取到数据）⇒ 必须注册"
        );
        let flat = crate::csp::shared::impl_src_only(include_str!("ting_jinxia.rs"));
        assert!(flat.contains("register_site!(TingJinxia)"), "★ 类要自注册");
    }

    #[test]
    fn host_accepts_bare_url_and_json() {
        // 订阅里就是这一串裸 URL
        assert_eq!(host_of("https://m.ting15.com").as_deref(), Some("https://m.ting15.com"));
        assert_eq!(host_of(" https://m.ting15.com/ ").as_deref(), Some("https://m.ting15.com"));
        assert_eq!(host_of(r#"{"host":"https://x.example/"}"#).as_deref(), Some("https://x.example"));
        // 空 ext：**不是**"没 host"，而是站点默认域（订阅里 ext 就是它）
        assert_eq!(host_of("").as_deref(), Some(DEFAULT_HOST));
    }

    #[test]
    fn list_fragment_parses_real_response() {
        let items = parse_items(REAL_LIST, "test").expect("真实片段必须能解析");
        assert_eq!(items.len(), 2, "两条 `<dl>`");
        assert_eq!(items[0].id, "/wuxiaxuanhuan/2117.html");
        assert_eq!(items[0].title, "无敌剑域");
        assert_eq!(items[0].subtitle.as_deref(), Some("青鸾峰上"));
        assert!(items[0].cover.as_deref().unwrap_or("").starts_with("https://img-book-oss"));
        assert_eq!(parse_page_count(REAL_LIST), Some(34), "页次 1/34 ⇒ 34 页");
    }

    /// ★ 空结果必须 Err（不许 `Ok(vec![])`）—— 这是本仓的诚实契约第 1 条
    #[test]
    fn shell_page_is_an_error_not_an_empty_list() {
        let shell = "<html><body><div class=\"clist\"></div>风控校验中…</body></html>";
        let e = parse_items(shell, "分类 x 第 1 页").expect_err("★ 0 条必须 Err");
        assert!(e.contains("风控壳页"), "{e}");
        assert!(e.contains("分类 x 第 1 页"), "报错要点名是哪一页：{e}");
        // 反面：真片段不许被判成空（否则上面那条可能只是"永远失败"）
        assert!(parse_items(REAL_LIST, "ok").is_ok());
    }

    #[test]
    fn detail_fragment_parses_real_response() {
        let d = parse_detail_page(REAL_DETAIL, "/wuxiaxuanhuan/2117.html").expect("真实详情必须能解析");
        assert_eq!(d.title, "无敌剑域");
        assert_eq!(d.episodes.len(), 3);
        assert_eq!(d.episodes[0].id, "/wuxiaxuanhuan/2117/0-1.html");
        assert_eq!(d.episodes[0].title, "1");
        assert_eq!(d.episodes[0].flag, "音频");
        assert!(d.cover.as_deref().unwrap_or("").starts_with("https://"));
        assert!(d.description.as_deref().unwrap_or("").contains("装X"));
    }

    #[test]
    fn detail_without_episodes_is_an_error() {
        let page = r#"<div class="binfo"><h1>某书</h1></div><div class="intro"><p>简介</p></div>"#;
        let e = parse_detail_page(page, "/x/1.html").expect_err("★ 0 集必须 Err");
        assert!(e.contains("没有可播分集"), "{e}");
    }

    #[test]
    fn episode_meta_and_play_json() {
        let m = parse_episode_meta(REAL_EP_META).expect("真实 meta 必须能解析");
        assert_eq!(m.book_id, "2117");
        assert_eq!(m.xt, "94b982cb2394023dd698088b615eccc8");
        assert_eq!(m.page, "1");
        assert_eq!(m.is_pay, "11");

        // 真实响应（带 BOM）：`{"url":"...m4a","status":1,"ourl":"","plink":""}`
        let ok = "\u{feff}{\"url\":\"https:\\/\\/oss-links.guoguo.org.cn\\/uploads\\/t010\\/15-\\u65e0\\u654c\\u5251\\u57df\\/0001.m4a\",\"status\":1,\"ourl\":\"\",\"plink\":\"\"}";
        let u = parse_play_json(ok).expect("真实响应必须能取出地址");
        assert!(u.ends_with("0001.m4a"), "{u}");
        // 缺 xt / 收费集的形状：url:null ⇒ Err（不许把 null 当空串地址返回）
        let e = parse_play_json("{\"url\":null,\"status\":1,\"ourl\":\"\"}").expect_err("★ null 必须 Err");
        assert!(e.contains("xt"), "{e}");
        // ourl 优先
        assert_eq!(parse_play_json("{\"url\":\"a\",\"ourl\":\"b\"}").unwrap(), "b");
    }

    /// ★ 真网络（默认 `#[ignore]`，人工触发）：
    /// `cargo test --lib csp::ting_jinxia::tests::live_ -- --ignored --nocapture`
    ///
    /// # 为什么放在类文件里而不是 `tests/`
    /// ```text
    /// 本仓纪律：`rust/sourin_core/tests/**` 是 Lead 独占；类自己的真网络读数
    /// 就该和类放在一起（同一份 `include_str!` 的判据也在这里）。
    /// ★ 不给 `#[ignore]` 的话，`cargo test --lib` 会去连站点 ⇒ 离线机器必红；
    ///   忽略它，但**保留在文件里**，读数是可复跑的，不是一次性截图。
    /// ```
    #[tokio::test]
    #[ignore = "真网络：直连 m.ting15.com（不走系统代理），人工触发"]
    async fn live_chain_home_list_detail_play() {
        let s = TingJinxia::new();
        let ext = "https://m.ting15.com";
        let home = s.home(ext).await.expect("★ live: home 必须取到分类");
        println!("LIVE TingJinxia home cats={} items={}", home.categories.len(), home.items.len());
        let cat = home
            .categories
            .iter()
            .find(|c| !c.id.is_empty())
            .expect("至少一个真分类");
        let list = s.list(&cat.id, 1, ext).await.expect("★ live: list 必须取到条目");
        println!(
            "LIVE TingJinxia list cat={} n={} page_count={:?} first={}",
            cat.id,
            list.items.len(),
            list.page_count,
            list.items[0].title
        );
        let d = s.detail(&list.items[0].id, ext).await.expect("★ live: detail 必须取到分集");
        println!("LIVE TingJinxia detail title={} eps={}", d.title, d.episodes.len());
        let plays = s
            .play(&d.episodes[0].flag, &d.episodes[0].id, ext)
            .await
            .expect("★ live: play 必须取到地址");
        println!("LIVE TingJinxia play url={}", plays[0].url);
    }

    #[test]
    fn categories_merge_dex_table_with_live_nav() {
        let html = r#"<nav class="nav clear">
     <a href="/" class="h">首页</a>
	 <a href="/wuxiaxuanhuan/" title="武侠玄幻" class="c2">武侠玄幻</a>
	 <a href="/yinyue/" title="助眠音频" class="c10" style="display:none">助眠音频</a>
     <a href="javascript:;" class="more" onclick="more(this)">更多↓</a>
    </nav>"#;
        let cats = parse_categories(html);
        assert_eq!(cats[0].id, "", "首项是「全部」");
        assert_eq!(cats[0].name, ALL_CAT);
        // DEX 的 9 组都在
        for (slug, name) in DEX_CATS {
            assert!(
                cats.iter().any(|c| c.id == *slug && c.name == *name),
                "缺分类 {slug}/{name}"
            );
        }
        // nav 里多出来的（不在 DEX 表里的）要被收进来
        assert!(cats.iter().any(|c| c.name == "助眠音频"), "live nav 的新分类要跟上");
        assert_eq!(cats.iter().filter(|c| c.name == "武侠玄幻").count(), 1, "不许重复");
    }
}
