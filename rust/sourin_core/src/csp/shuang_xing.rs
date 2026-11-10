// ═══════════════════════════════════════════════════════════════════════
//  csp_ShuangXing —— TVBox `csp_ShuangXing` 的 Rust 重写（纯 HTML 抓取）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅 8815.kstore.vip/tvbox/wmz 的 🌐双星｜4K网盘：
//   {"type":3, "api":"csp_ShuangXing", "ext": null}
// ⇒ ext 为 null ⇒ base 写死（`https://1.star2.cn`，DEX 常量逐字如此）。
// ```
//
// # 协议取证（`.probe/decompiled/classes.dex` 直读，**未起 jadx**）
//
// 依据：`.probe/r3-c-strings.json` 里 `ShuangXing` 的 115 条 const-string。
// 类：`com.github.catvod.spider.ShuangXing`，父类 `spider.Pan`，**7 方法 1 字段**
// （Pan 族里**最薄**的一个 —— 只有 1 个字段）。
//
// ```text
// base      https://1.star2.cn
// 请求头     User-Agent = Chrome/151 长串 · Referer = https://1.star2.cn · Cookie
// 列表选择器 <ul class="erx-list"> 块内 <li class="item">
//            <a href="…"> 标题（用 【 】 包住分类名）· <span class="erx-num-font time"> 日期
//            输出 vod_id / vod_name / vod_pic / vod_remarks
// 详情       "获取详情页失败"（错误文案）· <h1 …></h1> 取 vod_name
//            a.dlipp-dl-btn 的 href = 网盘分享链接
//            vod_play_from / vod_play_url
// 分类 id    dj=短剧 ju=国剧 zy=综艺 mv=电影 rh=韩日 ym=英美 wj=外剧 dm=动漫
//            （另有 `qt` 在真站点上存在，但 DEX 常量里**没有** ⇒ 见下"分类表"说明）
// 搜索      https://1.star2.cn/search/?keyword=<kw>（+ "UTF-8" ⇒ 按 UTF-8 编码）
// 分页       ★ DEX 常量只给了 `page` 这个**键名**（与 list/pagecount/limit/total 并列）
//             ⇒ 没给出**用法**；真形态见下"实测校正"
// ```
//
// # ★ 一处"DEX 模板 ≠ 真站点"（实测校正）
//
// ```text
// DEX 常量把 `page` / `pagecount` / `limit` / `total` 当 **JSON 键**用
//   （它们出现在 `{"list":[]}` 这串模板旁边，看着像"返回给宿主的分页字段"）。
// 【实测】真站点的分页是**查询串**：`/ju/?page=2`
//   GET /ju/             → 200 · 10198 B · 首三条 11799 / 11721 / 11783
//   GET /ju/?page=2      → 200 · 10201 B · 首三条 11472 / 11444 / 11413   ← 与第 1 页**不同**
//   （试过的错形态：`/ju/index_2.html` 404 · `/ju/2.html` 404 ·
//     `/ju/list_2.html` 404 · `/ju/page/2` 404 · `/ju/page_2.html` 404）
// ⇒ 本实现用 `?page=N`，并把这个"实测值"钉进门禁（`list_url_uses_measured_page_query`）。
// ```
//
// # ★ 另一处：分类表是**实测快照**，不是 DEX 常量（凭证分级，如实标）
//
// ```text
// 与 Djuu 同理：DEX 常量**没有**给出"分类名↔id"成对表，只给了 8 个 id 串
//   （dj ju zy mv rh ym wj dm）+ 8 个中文名（短剧 国剧 综艺 电影 韩日 英美 外剧 动漫）。
// ★ 这 8 组**恰好一一对应且顺序一致** ⇒ 我按"成对"归并（这是有依据的推断，不是猜），
//   并在门禁里钉住"id 与名的对应关系"。
// ⚠️ 但真站点导航里还多一个 `/qt/ 其 他`，DEX 常量里没有 ⇒ **本实现不列入**
//    （宁可少一个分类，也不臆造 DEX 里不存在的项）。它会以"未知分类 id"的形式
//    在 list("qt") 时正常工作（模板 `/{tid}/` 是通用的）。
// ```
//
// # 真网络读数（2026-10-27 实测）
//
// ```text
// GET https://1.star2.cn/                        200 · 121079 B
// GET https://1.star2.cn/ju/                     200 ·  10198 B · 15 个 <li class="item">
// GET https://1.star2.cn/ju/?page=2              200 ·  10201 B · 首条 11472（与第 1 页不同）
// GET https://1.star2.cn/search/?keyword=红       200 ·  10432 B · 15 个 <li class="item">
// GET https://1.star2.cn/ju/11721.html           200 ·   8783 B
//     <h1>【国剧】美人余.全集</h1>
//     a.dlipp-dl-btn ×2 → href = https://pan.quark.cn/s/bec279a3a6ef 等（**网盘分享页**）
//     ★ 注意：404 时返回的是 "HTTP Error 404: Not Found"（len=25）
// ```
//
// # 播放能力边界（**与 PanWebShare / zhinan 同款，如实**）
//
// ```text
// 这个站的"播放"就是**网盘分享页**（夸克/百度/UC/迅雷…）；
// ⇒ play() 返回分享页 URL，**不伪造** m3u8/mp4 直链（伪造只会让人点进去看到 404）。
//    把分享页解析成直链是网盘模块的事（本批不做，见文件头 mProxy 缺口）。
// ```
//
// # 契约边界（Lead 已裁定）
//
// ```text
// · loadPic   ⇒ 本站封面需要 Referer（DEX 里既给了 Referer 又给了 Cookie）
//                ⇒ ★ 按裁定"写进该源的 cover_headers（声明式）" —— 见 [`COVER_HEADERS`]。
// · mProxy    ⇒ ★ **已知缺口**：原版有代理能力，本批不做。
// · initApi   ⇒ 本仓无该 API；等价物是 `ext`（本类 ext 为 null，不影响）
// · isVideoFormat / manualVideoCheck
//             ⇒ ★ DEX 里 ShuangXing **没有** override 这两个（7 个方法里没有）
//                ⇒ **本仓无等价位，未实现**（如实登记，不臆造）
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 站点唯一域名（DEX 常量逐字：`https://1.star2.cn`）
pub const BASE: &str = "https://1.star2.cn";

/// DEX 里逐字给出的 UA
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// ★ 声明式封面头（Lead 裁定：`loadPic` 不补进 trait，改写 `cover_headers`）
///
/// # 为什么需要它
/// ```text
/// 本站的图（`/skin/images/*.png` 与详情页封面）在带 Referer 时才稳；
/// DEX 里 `loadPic` 相关的请求头被逐字给出（Referer + Cookie 两行）。
/// ⇒ 宿主 `home.rs:147 proxy_covers` 会拿这个声明统一代取封面。
/// ```
pub const COVER_HEADERS: &'static [(&'static str, &'static str)] =
    &[("User-Agent", UA), ("Referer", BASE)];

const GET_TIMEOUT: Duration = Duration::from_secs(15);

pub struct ShuangXing {
    client: super::http_context::CspHttpContext,
}

impl ShuangXing {
    pub const CLASS: &'static str = "ShuangXing";

    /// 首页分类 —— **DEX 常量里 8 个 id 与 8 个中文名同序成对**（见文件头"凭证分级"）
    ///
    /// ⚠️ 真站点导航另有 `/qt/ 其 他`，DEX 常量里**没有** ⇒ 不列入（不臆造）。
    pub const CATEGORIES: &'static [(&'static str, &'static str)] = &[
        ("dj", "短剧"),
        ("ju", "国剧"),
        ("zy", "综艺"),
        ("mv", "电影"),
        ("rh", "韩日"),
        ("ym", "英美"),
        ("wj", "外剧"),
        ("dm", "动漫"),
    ];

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| {
            reqwest::Client::builder()
                .user_agent(UA)
                .timeout(GET_TIMEOUT)
                // Ignore environment proxies; CspHttpContext applies app policy.
                .no_proxy()
        });
        Self { client }
    }

    async fn get_html(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header(reqwest::header::REFERER, format!("{BASE}/"))
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
                "{url} 返回 HTTP {status}；响应前 160 字节：{}",
                truncate(&body, 160)
            ));
        }
        Ok(body)
    }
}

impl Default for ShuangXing {
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

/// 列表 URL（**实测校正**：分页是查询串 `?page=N`，不是 DEX 常量暗示的 JSON 字段）
pub fn list_url(base: &str, tid: &str, page: u32) -> String {
    let page = if page == 0 { 1 } else { page };
    if page <= 1 {
        format!("{base}/{tid}/")
    } else {
        format!("{base}/{tid}/?page={page}")
    }
}

/// 搜索 URL（DEX 常量逐字：`https://1.star2.cn/search/?keyword=`，按 UTF-8 编码）
pub fn search_url(base: &str, kw: &str) -> String {
    format!("{base}/search/?keyword={}", urlencode(kw))
}

/// 详情 URL（实测形态：`/<分类>/<数字>.html`）
pub fn detail_url(base: &str, id: &str) -> String {
    // id 可能已经是完整 URL / 或 "ju/11721" / 或纯数字（列表给的是 `ju/11721`）
    if id.starts_with("http://") || id.starts_with("https://") {
        id.to_string()
    } else if id.contains('/') {
        format!("{base}/{id}.html")
    } else {
        // 只有数字 ⇒ 无法知道分类 ⇒ 由调用方保证给了分类前缀（见 detail()）
        format!("{base}/{id}.html")
    }
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

/// 从列表页 HTML 抽取条目（`<ul class="erx-list">` 里的 `<li class="item">`）
///
/// # 取法（**不是** CSS 选择器引擎 —— 如实标注）
/// ```text
/// ① 以内层 `<li class="item">` 作块边界切块
/// ② 块内 `<a href="/ju/11799.html">标题</a>` ⇒ id = `ju/11799`（**保留分类前缀**，
///    因为详情 URL 需要它；实测详情形态是 `/{分类}/{数字}.html`）
/// ③ 块内 `<span class="erx-num-font time">2026-10-16</span>` ⇒ 副标题（日期）
/// ```
pub fn parse_items(html: &str, expect_items: bool) -> Result<Vec<CspItem>, String> {
    const MARKER: &str = "<li class=\"item\">";
    let mut items: Vec<CspItem> = Vec::new();
    let mut rest = html;

    while let Some(pos) = rest.find(MARKER) {
        let after = &rest[pos + MARKER.len()..];
        let end = after.find("</li>").unwrap_or(after.len());
        let block = &after[..end];

        if let Some(href) = extract_attr(block, "href") {
            if let Some(id) = normalize_list_id(&href) {
                let title = extract_anchor_text(block).unwrap_or_else(|| format!("条目 {id}"));
                /*
                 * ⚠️ 日期要**定向取 `erx-num-font`**，不能用"块内第一个 span"。
                 *   真站点块结构是：
                 *     <a …>标题</a><span class="tags"></span>     ← ★ 第一个 span 是**空的** tags
                 *     <div class="i"><span class="erx-num-font time">2026-10-16</span></div>
                 *   第一版 `extract_first_span_text(block)` 取到空的 `tags`（⇒ None），
                 *   门禁 `items_parse_real_markup` 当场抓住（期望 Some("2026-10-16")、实际 None）。
                 *   ⇒ 改为按 class 名定位（DEX 常量逐字给的就是 `erx-num-font time`）。
                 */
                let date = extract_span_text_by_class(block, "erx-num-font");
                items.push(CspItem {
                    id,
                    title,
                    // ★ 列表页**不给封面**（实测 `<li class="item">` 里没有 img）
                    //   ⇒ 如实 None，不从别处猜
                    cover: None,
                    subtitle: date,
                });
            }
        }
        rest = &after[end..];
        if rest.is_empty() {
            break;
        }
    }

    // ★ 反空真（铁律 149）：本该有条目却切出 0 块 ⇒ 结构变了
    if expect_items && items.is_empty() {
        return Err(format!(
            "页面里找不到 <li class=\"item\"> 块（本该有条目）⇒ 站点结构可能变了；页面长度 {} 字符",
            html.len()
        ));
    }
    Ok(items)
}

/// 把列表里的 href 归一成 id：`/ju/11799.html` → `ju/11799`
///
/// # ⚠️ 后缀 `.html` 是**要求**的（不是"有就剥、没有就算"）
/// ```text
/// 第一版写成 `strip_suffix(".html")` —— 该函数在**没有**后缀时原样返回，
/// 于是 `/ju/11799`（无扩展名）也被当成合法列表 id ⇒ 判据过宽。
/// ⇒ 门禁 `normalize_list_id_forms` 当场抓住（期望 None、实际 Some("ju/11799")）。
///
/// 【为什么选"收紧"而不是"放宽判据"】
/// 本仓纪律是"站点结构变了要**早报**，不许静默换一种解析"。
/// 真站点的条目链接**一律**带 `.html`（实测 `href="/ju/11799.html"`）；
/// 若某天变了形态，我宁可这里返回 None（⇒ 该条被跳过、且 `expect_items` 会在
/// 整页都取不到时明确报错），也不要悄悄接受一个形态不明的 href。
/// ```
pub fn normalize_list_id(href: &str) -> Option<String> {
    let h = href.trim().strip_prefix(BASE).unwrap_or(href.trim());
    let h = h.strip_prefix('/').unwrap_or(h);
    // 必须显式带 .html（见上面留档：不许宽松放行）
    let h = h.strip_suffix(".html")?;
    let parts: Vec<&str> = h.split('/').filter(|s| !s.is_empty()).collect();
    match parts.as_slice() {
        [cat, num] if !cat.is_empty() && num.chars().all(|c| c.is_ascii_digit()) => {
            Some(format!("{cat}/{num}"))
        }
        _ => None,
    }
}

/// 详情页解析：标题 + 网盘分享链接
///
/// 选择器逐条来自 DEX 常量：`<h1…></h1>` 取标题·`a.dlipp-dl-btn` 取分享链接。
pub fn parse_detail(html: &str, id: &str) -> Result<CspDetail, String> {
    let title = extract_between(html, "<h1", "</h1>")
        .map(|s| strip_tags(&s))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "详情页找不到 <h1> 标题 ⇒ 站点结构可能变了".to_string())?;

    let mut episodes: Vec<CspEpisode> = Vec::new();
    let mut rest = html;
    while let Some(pos) = rest.find("dlipp-dl-btn") {
        let after = &rest[pos..];
        if let Some(href) = extract_attr(after, "href") {
            if href.starts_with("http://") || href.starts_with("https://") {
                if !episodes.iter().any(|e| e.id == href) {
                    let label = extract_first_span_text(after)
                        .unwrap_or_else(|| "网盘".to_string());
                    episodes.push(CspEpisode {
                        id: href,
                        title: label,
                        flag: "网盘".to_string(),
                    });
                }
            }
        }
        rest = &after["dlipp-dl-btn".len()..];
        if rest.is_empty() {
            break;
        }
    }

    // ★ 反空真：页面有 h1（说明确实是详情页）却一个分享链接都没有
    //   ⇒ 要么条目下架、要么链接容器改名 —— 两者都**不许**静默返回空线路
    if episodes.is_empty() {
        return Err(
            "详情页上没有找到任何网盘分享链接（dlipp-dl-btn）⇒ 条目可能已下架，或站点结构变了"
                .to_string(),
        );
    }

    Ok(CspDetail {
        id: id.to_string(),
        title,
        // 详情页不给封面（实测 h1 区没有 img）⇒ 如实 None
        cover: None,
        description: None,
        episodes,
    })
}

/// 取 `start_tag_prefix … >` 与 `end_tag` 之间的内容（最小实现）
fn extract_between(s: &str, start_tag: &str, end_tag: &str) -> Option<String> {
    let p = s.find(start_tag)?;
    let gt = s[p..].find('>')? + p + 1;
    let e = s[gt..].find(end_tag)? + gt;
    Some(s[gt..e].to_string())
}

fn extract_attr(block: &str, attr: &str) -> Option<String> {
    for (open, close) in [('"', '"'), ('\'', '\'')] {
        let needle = format!("{attr}={open}");
        if let Some(p) = block.find(&needle) {
            let start = p + needle.len();
            if let Some(end_rel) = block[start..].find(close) {
                return Some(block[start..start + end_rel].to_string());
            }
        }
    }
    None
}

/// 取第一个 `<a …>文本</a>` 的文本
fn extract_anchor_text(block: &str) -> Option<String> {
    let p = block.find("<a ")?;
    let gt = block[p..].find('>')? + p + 1;
    let e = block[gt..].find("</a>")? + gt;
    let t = strip_tags(&block[gt..e]).trim().to_string();
    if t.is_empty() {
        None
    } else {
        Some(t)
    }
}

fn extract_first_span_text(s: &str) -> Option<String> {
    let p = s.find("<span")?;
    let gt = s[p..].find('>')? + p + 1;
    let e = s[gt..].find("</span>")? + gt;
    let t = strip_tags(&s[gt..e]).trim().to_string();
    if t.is_empty() {
        None
    } else {
        Some(t)
    }
}

/// 按 **class 名**定位 span 并取文本（`erx-num-font` 这种）
///
/// # 为什么需要它（见 `parse_items` 里的留档）
/// 真站点块内**第一个 span 是空的 `<span class="tags"></span>`**，
/// 光靠"第一个 span"会取到空值 ⇒ 必须按 class 名定向取。
pub fn extract_span_text_by_class(s: &str, class_name: &str) -> Option<String> {
    let mut cursor = s;
    while let Some(p) = cursor.find("<span") {
        let gt = cursor[p..].find('>')? + p;
        let open_tag = &cursor[p..gt];
        if open_tag.contains(class_name) {
            let text_start = gt + 1;
            let e = cursor[text_start..].find("</span>")? + text_start;
            let t = strip_tags(&cursor[text_start..e]).trim().to_string();
            if !t.is_empty() {
                return Some(t);
            }
        }
        if gt + 1 >= cursor.len() {
            break;
        }
        cursor = &cursor[gt + 1..];
    }
    None
}

fn strip_tags(s: &str) -> String {
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
    out
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for ShuangXing {
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
        let html = self.get_html(&list_url(BASE, first, 1)).await?;
        let items = parse_items(&html, true)?;
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        // 分类 id 形如 `ju`（字母）；显式拒绝含 `/`、`?` 等会破坏模板的输入
        if !tid.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(format!("分类 id 只允许字母数字（实测模板 `/<tid>/`）：{tid}"));
        }
        let page = if page == 0 { 1 } else { page };
        let html = self.get_html(&list_url(BASE, tid, page)).await?;
        let items = parse_items(&html, true)?;
        Ok(CspList {
            items,
            page,
            // ★ 上游**没有**给出总页数/总数（列表页纯 HTML，页脚也无分页数字）
            //   ⇒ 如实 None，**不猜**
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let html = self.get_html(&detail_url(BASE, id)).await?;
        parse_detail(&html, id)
    }

    /// 取流：本站是**网盘分享页**，如实返回分享页并标注"分享页"
    ///
    /// # 为什么不伪造直链
    /// ```text
    /// 上游 APK 也是把分享链接塞进 vod_play_url（`dlipp-dl-btn` 的 href 就是分享链接）。
    /// 伪造一个 m3u8 只会让用户点进去看到 404 ⇒ 本仓明令禁止。
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if !(id.starts_with("http://") || id.starts_with("https://")) {
            return Err(format!("播放 id 不是 http(s) 地址：{}", truncate(id, 120)));
        }
        Ok(vec![CspPlay {
            url: id.to_string(),
            headers: Vec::new(),
            label: Some("分享页（需网盘客户端/转发服务取直链）".to_string()),
        }])
    }

    /// DEX 里 ShuangXing **有** searchContent（7 个方法里有它）⇒ 真支持搜索
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索词为空".to_string());
        }
        let html = self.get_html(&search_url(BASE, kw)).await?;
        let items = parse_items(&html, true)?;
        Ok(CspList {
            items,
            page: 1,
            // ★ 搜索页也没有分页（实测只有一页结果）⇒ 如实 None
            page_count: None,
            total: None,
        })
    }
}

// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
//
// # 这个类的事实（别丢）
// ```text
// csp_ShuangXing（🌐双星｜4K网盘）：Pan 族最薄（7 方法 1 字段）
//   列表 /<分类>/            → 200 · 15 项（ju=国剧 / mv=电影 / dj=短剧 …共 8 类）
//   分页 ★ DEX 常量只给了 `page` 键名；**实测真形态是查询串** `/<分类>/?page=N`
//        （`/ju/?page=2` 200 · 首条 11472 ≠ 第 1 页首条 11799）
//   详情 /<分类>/<数字>.html → 200 · <h1>标题</h1> + a.dlipp-dl-btn 的 href = 网盘分享链接
//   搜索 /search/?keyword=<kw> → 200 · 15 项
// ★ 分类表来自 DEX 常量的"8 id ↔ 8 名 同序成对"（有依据的归并，非猜）
//   真站点另有 /qt/ 其他，**DEX 里没有** ⇒ 不列入（不臆造）
// ★ cover_headers 已按裁定写成声明式（Referer + UA），供宿主统一代取封面
// ⚠️ 已知缺口：原版有 mProxy，本批不做；本站播放是**网盘分享页**（不伪造直链）
// ```
crate::csp::register_site!(ShuangXing);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实列表片段（2026-10-27 实测抓下后裁剪）
    const FIX_LIST: &str = r#"
<div class="erx-list-box">
  <ul class="erx-list">
    <li class="item">
      <div class="a"><a href="/ju/11799.html" class="main">【国剧】醉梦.全集【刘诗诗】</a><span class="tags"></span></div>
      <div class="i"><span class="erx-num-font time">2026-10-16</span></div>
    </li>
    <li class="item">
      <div class="a"><a href="/ju/11721.html" class="main">【国剧】美人余.全集</a><span class="tags"></span></div>
      <div class="i"><span class="erx-num-font time">2026-10-09</span></div>
    </li>
  </ul>
</div>"#;

    /// 真实详情片段（含两条网盘分享链接，实测抓下后裁剪）
    const FIX_DETAIL: &str = r#"
<div class="erx-detail">
  <h1 class="erx-title">【国剧】美人余.全集</h1>
  <div class="dlipp-cont-bd">
    <a class="dlipp-dl-btn j-wbdlbtn-dlipp" href="https://pan.quark.cn/s/bec279a3a6ef" target="_blank">
      <img src="/skin/images/kk.png" alt="夸克网盘"><span>夸克网盘</span>
    </a>
    <a class="dlipp-dl-btn j-wbdlbtn-dlipp" href="https://pan.baidu.com/s/1abcdEFGH" target="_blank">
      <img src="/skin/images/bd.png" alt="百度网盘"><span>百度网盘</span>
    </a>
  </div>
</div>"#;

    // ── ★ 两处实测校正（判据钉住实测值）──

    #[test]
    /// ★ 分页：DEX 常量只给了 `page` **键名**；实测真形态是**查询串**
    ///
    /// 注入：把 `list_url` 改成 DEX 暗示的 JSON 式/其它猜测形态 ⇒ 本条红。
    fn list_url_uses_measured_page_query() {
        assert_eq!(list_url(BASE, "ju", 1), "https://1.star2.cn/ju/", "第 1 页不带参数");
        assert_eq!(list_url(BASE, "ju", 2), "https://1.star2.cn/ju/?page=2", "★ 实测形态");
        assert_eq!(list_url(BASE, "ju", 0), "https://1.star2.cn/ju/", "page=0 归一成 1");
    }

    #[test]
    /// ★ 分类表：DEX 常量的 8 id ↔ 8 名**同序成对**
    fn categories_pair_ids_and_names_from_dex_constants() {
        assert_eq!(ShuangXing::CATEGORIES.len(), 8);
        assert_eq!(ShuangXing::CATEGORIES[0], ("dj", "短剧"));
        assert_eq!(ShuangXing::CATEGORIES[1], ("ju", "国剧"));
        assert_eq!(ShuangXing::CATEGORIES[6], ("wj", "外剧"));
        assert_eq!(ShuangXing::CATEGORIES[7], ("dm", "动漫"));
        // ★ 真站点有 /qt/，但 DEX 常量**没有** ⇒ 不许混进来
        assert!(
            !ShuangXing::CATEGORIES.iter().any(|(id, _)| *id == "qt"),
            "★ DEX 常量里没有 qt ⇒ 不许臆造（可以在 list(\"qt\") 时按通用模板工作）"
        );
    }

    #[test]
    /// 搜索 URL 逐字来自 DEX 常量
    fn search_url_matches_dex_constant() {
        assert_eq!(
            search_url(BASE, "红"),
            "https://1.star2.cn/search/?keyword=%E7%BA%A2"
        );
    }

    #[test]
    /// ★ cover_headers 是**声明式**的（Lead 裁定）：Referer + UA 两条
    fn cover_headers_are_declared() {
        assert_eq!(COVER_HEADERS.len(), 2);
        let names: Vec<&str> = COVER_HEADERS.iter().map(|(k, _)| *k).collect();
        assert!(names.contains(&"Referer"), "{names:?}");
        assert!(names.contains(&"User-Agent"), "{names:?}");
    }

    // ── parse_items ───────────────────────────────────────────────

    #[test]
    fn items_parse_real_markup() {
        let items = parse_items(FIX_LIST, true).expect("真页面片段必须解析得出来");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "ju/11799", "★ id 保留分类前缀（详情 URL 需要它）");
        assert_eq!(items[0].title, "【国剧】醉梦.全集【刘诗诗】");
        assert_eq!(items[0].subtitle.as_deref(), Some("2026-10-16"), "副标题 = 日期");
        assert_eq!(items[1].id, "ju/11721");
        // 列表页不给封面 ⇒ 如实 None
        assert_eq!(items[0].cover, None, "列表页没有 img ⇒ 不许编一个封面");
    }

    #[test]
    /// ★ 反空真 ①：本该有条目却切出 0 块 ⇒ 报错
    ///
    /// 注入：删掉 `parse_items` 里 `expect_items && items.is_empty()` 那段 ⇒ 本条红。
    fn empty_extraction_on_expected_page_is_error() {
        let broken = "<html><body><div class=\"card\">没有 item 块</div></body></html>";
        let err = parse_items(broken, true).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// ★ 反空真 ②（成对）：不期望条目时，空列表正常
    fn empty_extraction_when_not_expected_is_ok() {
        let items = parse_items("<html>no items</html>", false).expect("不期望条目时空就是空");
        assert!(items.is_empty());
    }

    #[test]
    /// `normalize_list_id` 各种形态
    fn normalize_list_id_forms() {
        assert_eq!(normalize_list_id("/ju/11799.html").as_deref(), Some("ju/11799"));
        assert_eq!(
            normalize_list_id("https://1.star2.cn/mv/11517.html").as_deref(),
            Some("mv/11517")
        );
        assert_eq!(normalize_list_id("/search/?keyword=x"), None, "非条目链接要拒绝");
        assert_eq!(normalize_list_id("/ju/11799"), None, "缺 .html 不是列表 id 形态");
    }

    // ── parse_detail ──────────────────────────────────────────────

    #[test]
    fn detail_parses_title_and_pan_links() {
        let d = parse_detail(FIX_DETAIL, "ju/11721").expect("真页面片段必须解析得出来");
        assert_eq!(d.title, "【国剧】美人余.全集");
        assert_eq!(d.episodes.len(), 2, "两个网盘分享链接 = 两条线路");
        assert_eq!(d.episodes[0].id, "https://pan.quark.cn/s/bec279a3a6ef");
        assert_eq!(d.episodes[0].title, "夸克网盘");
        assert_eq!(d.episodes[1].id, "https://pan.baidu.com/s/1abcdEFGH");
        assert_eq!(d.episodes[0].flag, "网盘");
    }

    #[test]
    /// ★ 反空真 ③：有 h1（确是详情页）却**零分享链接** ⇒ 必须报错，不许给空线路
    ///
    /// 这正是本仓禁止的"占位返回空冒充成功"。
    fn detail_with_title_but_no_links_is_error() {
        let bad = r#"<div><h1 class="erx-title">【国剧】某片</h1><p>没有链接</p></div>"#;
        let err = parse_detail(bad, "ju/1").unwrap_err();
        assert!(err.contains("没有找到任何网盘分享链接"), "{err}");
    }

    #[test]
    fn detail_without_title_is_error() {
        let err = parse_detail("<html><body>nothing</body></html>", "ju/1").unwrap_err();
        assert!(err.contains("找不到"), "{err}");
    }

    #[test]
    /// 分享链接必须**去重**（同一 href 出现两次只算一条线路）
    fn detail_dedupes_repeated_links() {
        let dup = r#"<h1>标题</h1>
            <a class="dlipp-dl-btn" href="https://pan.quark.cn/s/x"><span>夸克</span></a>
            <a class="dlipp-dl-btn" href="https://pan.quark.cn/s/x"><span>夸克</span></a>"#;
        let d = parse_detail(dup, "ju/1").unwrap();
        assert_eq!(d.episodes.len(), 1, "同 href 只算一条");
    }

    // ── 边界 / 能力位 ─────────────────────────────────────────────

    #[test]
    fn search_is_declared_supported() {
        assert!(ShuangXing::new().supports_search(), "★ DEX 里 ShuangXing 有 searchContent");
    }

    #[tokio::test]
    async fn empty_kw_fails_instead_of_silent_all() {
        let err = ShuangXing::new().search("  ", 1, "").await.unwrap_err();
        assert!(err.contains("搜索词为空"), "{err}");
    }

    #[tokio::test]
    async fn empty_tid_fails() {
        let err = ShuangXing::new().list("", 1, "").await.unwrap_err();
        assert!(err.contains("分类 id 为空"), "{err}");
    }

    #[tokio::test]
    /// ★ 形如 `ju/../x` 的分类 id 必须被拒（模板拼接注入）
    async fn tid_with_slash_is_rejected() {
        let err = ShuangXing::new().list("ju/../etc", 1, "").await.unwrap_err();
        assert!(err.contains("只允许字母数字"), "{err}");
    }

    #[tokio::test]
    async fn play_returns_share_page_with_honest_label() {
        let url = "https://pan.quark.cn/s/bec279a3a6ef";
        let plays = ShuangXing::new().play("网盘", url, "").await.expect("分享页必须返回");
        assert_eq!(plays[0].url, url);
        assert!(
            plays[0].label.as_deref().unwrap_or("").contains("分享页"),
            "★ 线路名必须说明这是分享页而不是直链：{:?}",
            plays[0].label
        );
    }

    #[tokio::test]
    async fn play_rejects_non_http_id() {
        let err = ShuangXing::new().play("网盘", "ju/11721", "").await.unwrap_err();
        assert!(err.contains("不是 http(s) 地址"), "{err}");
    }

    // ── 真网络（默认不跑；显式跑必须给 CSP_LIVE=1）──

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib shuang_xing_live -- --ignored --nocapture"]
    async fn shuang_xing_live_home_list_detail_search() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = ShuangXing::new();

        let home = s.home("").await.expect("home 必须真取到数据");
        assert_eq!(home.categories.len(), 8);
        assert!(!home.items.is_empty(), "★ 反空真：首屏必须有真条目");
        println!("LIVE home：分类 {} 个，首屏 {} 条", home.categories.len(), home.items.len());

        let list = s.list("ju", 1, "").await.expect("国剧分类必须真取到数据");
        assert!(!list.items.is_empty(), "★ 反空真");
        println!("LIVE list 国剧：{} 条，首条={}", list.items.len(), list.items[0].title);

        // ★ 分页：第 2 页首条必须与第 1 页不同（证明 ?page=N 真生效）
        let list2 = s.list("ju", 2, "").await.expect("第 2 页必须真取到数据");
        assert!(!list2.items.is_empty(), "★ 反空真：第 2 页不能空");
        assert_ne!(
            list2.items[0].id, list.items[0].id,
            "★ 第 2 页首条必须与第 1 页不同（否则分页形态没生效）"
        );
        println!(
            "LIVE 分页对照：p1={} p2={}",
            list.items[0].id, list2.items[0].id
        );

        let id = list.items[0].id.clone();
        let d = s.detail(&id, "").await.expect("详情必须真取到数据");
        assert!(!d.title.is_empty(), "★ 反空真：详情必须有标题");
        assert!(!d.episodes.is_empty(), "★ 反空真：详情必须有网盘分享链接");
        println!("LIVE detail {id}：{} ｜ 链接 {} 条", d.title, d.episodes.len());
        for ep in d.episodes.iter().take(3) {
            println!("    - {}：{}", ep.title, ep.id);
        }

        let sr = s.search("红", 1, "").await.expect("搜索必须真取到数据");
        assert!(!sr.items.is_empty(), "★ 反空真：搜索结果不能空");
        println!("LIVE search 红：{} 条，首条={}", sr.items.len(), sr.items[0].title);
    }

    #[test]
    /// ★★ 不读系统代理（**跨批一致性**：本仓 csp 既定惯例，见 `app99.rs:342`）
    ///
    /// 断言的**对象是源码形态**（构造链里有没有 `.no_proxy()`），**不依赖网络**。
    /// 注入：删掉那条 `.no_proxy()` ⇒ 本条 FAILED。
    /// ★ 用 `impl_src_only` 先剥测试段，防"本函数自己的字面量喂饱门禁 ⇒ 假绿"。
    fn client_does_not_read_system_proxy() {
        let src = crate::csp::shared::impl_src_only(include_str!("shuang_xing.rs"));
        assert!(
            src.contains(".no_proxy()"),
            "★ Client 构造链必须含 `.no_proxy()`（不读系统代理）；             否则装了代理的机器上会把'站点可用'测成'全宕'"
        );
    }
}

#[cfg(test)]
#[path = "shuang_xing_proxy_tests.rs"]
mod proxy_tests;
