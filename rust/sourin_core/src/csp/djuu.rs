// ═══════════════════════════════════════════════════════════════════════
//  csp_Djuu —— TVBox `csp_Djuu` 的 Rust 重写（HTML 抓取 + 一个 JSON 取流接口）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅 8815.kstore.vip/tvbox/wmz 的 🎶呦呦｜DJ音乐：
//   {"type":3, "api":"csp_Djuu", "ext": null}
// ⇒ ext 为 null ⇒ base 写死（`https://m.djuu.com`，DEX 常量也逐字如此）。
// ```
//
// # 协议取证（`.probe/decompiled/classes.dex` 直读，**未起 jadx**）
//
// 依据：`.probe/r3-c-strings.json` 里 `Djuu` 的 104 条 const-string。
//
// ```text
// 类        Lcom/github/catvod/spider/Djuu;  父类 crawler/Spider
// 成员      12 方法（6 个 override API + <init> + 自有）
// base      https://m.djuu.com
// 请求头     UA = Chrome/151 长串；Referer = https://m.djuu.com/  （**两个属性都逐字给出**）
// 列表选择器 div#djuu-musiclist-djlist div.djuu-list-item   ← DEX 逐字
//           div.me-2 > span（标题）/ img / onclick 里 \('…'\) / data-bs-id
//           占位图 /static/mobile/images/play/logo.png
//           vod_tag：folder | file
// 搜索      https://m.djuu.com/search?musicname=<kw>&page=<n>
//           选择器 div#djuu-musiclist-search div.djuu-list-item
// 详情      vod_play_from = "DJ呦呦网"；vod_play_url 用 `#` 分集、`$` 分名址
// 取流      https://m.djuu.com/play/music?id=<id> → data.playUrl
// ```
//
// # ★★ 三处"DEX 模板 ≠ 真站点"（**实测校正，不是照抄常量**）
//
// 本类是本批**踩坑最多**的一个。三处都按"按行为重写"改正，并留档：
//
// ```text
// ① 列表路径：DEX 常量给 `/1_1.html`、`/1_{pg}.html`
//    【实测】GET /1_1.html → **404**（len=25，HTTP Error 404）
//    真路径：`/djlist/<分类id>_0_1_<页码>.html`
//      GET /djlist/115_0_1_1.html → 200 · 82454 B · 30 个 div.djuu-list-item · 60 个 data-bs-id
//    ★ 页码位是**第 4 段**（`_0_1_<pg>.html`）：
//      115_0_1_1 → 首 id 327745
//      115_0_1_2 → 首 id 327615
//      115_0_1_3 → 首 id 327292   ⇒ 确认第 4 段才是页码
//      （验证过 `115_0_2_1` 与 `115_0_1_1` 长度完全相同 ⇒ 第 3 段不是页码）
//
// ② 详情路径：DEX 常量给 `/play/music?id=<id>`（带查询串的"接口式"路径）
//    【实测】GET /play/music?id=327745 → **404**
//    真页面：`GET /play/<id>.html` → 200 · 8409 B（页面里有 onclick="music.playone('327745')"）
//    ★ 而 `/play/music` **是**真端点 —— 但它只认 **POST 且带表单参数 `id`**：
//      POST /play/music {id:327745} → 200 · 608 B · {"code":0,…,"data":{"url":"…m4a"}}
//      （静态分析 common.min.js 得到：`http("/play/music",{id:t},…,"POST","json")`）
//      ⇒ DEX 常量把"POST 表单参数"误当成"GET 查询串"了。
//
// ③ 取流结果字段：DEX 常量里写 `data.playUrl`
//    【实测】响应 `data` 里的键是 **`url`**（同时还有 img/id/title/user_id/musicsize/album…）
//      ⇒ DEX 的 `playUrl` 是**内部变量名**，不是响应字段名。
//      真响应：{"code":0,"data":{"id":327745,"title":"…","url":"https://mp4.djuu.com/c115/…/4e631263bc875fcd.m4a", …}}
// ```
//
// ★ 另外这些键名也在 DEX 常量里，但**实测响应里没有**：
//   `data.parse`（取流模板 `{"parse":…,"url":…,"header":…}`）——
//   本实现**不臆造** `parse`，直接返回 url（见 play()）。
//
// # 真网络读数（2026-10-27 实测）
//
// ```text
// GET  https://m.djuu.com/                                 200 · 160727 B · 80 个 djuu-list-item
// GET  https://m.djuu.com/search?musicname=红              200 ·  78904 B · 30 个 djuu-list-item
// GET  https://m.djuu.com/djlist/115_0_1_1.html            200 ·  82454 B · 30 项 / 60 个 data-bs-id
// GET  https://m.djuu.com/play/327745.html                 200 ·   8409 B
// POST https://m.djuu.com/play/music  {id:327745}          200 ·    608 B
//      → data.url = https://mp4.djuu.com/c115/9419/116/2026/4e631263bc875fcd.m4a  ← **可播 m4a**
//      → data.musicsize = 14.69 (MB) · data.album.title = "DJ阿宽"
// ```
//
// # 契约边界（Lead 已裁定）
//
// ```text
// · loadPic   ⇒ 封面是公开图床（img.djuu.com / mp4.djuu.com），不需额外头 ⇒ 不写 cover_headers
// · mProxy    ⇒ ★ **已知缺口**：原版有代理能力；本批不做。部分音频 CDN 可能校验 Referer/UA
//                （实测取到的 m4a 直链本身可直接播）。
// · initApi   ⇒ 本仓无该 API；等价物是 `ext`（本类 ext 为 null，不影响）
// · isVideoFormat / manualVideoCheck
//             ⇒ ★ DEX 里 Djuu **没有** override 这两个（12 个方法里没有）
//                ⇒ **本仓无等价位，未实现**（如实登记，不臆造）
//
// # ⚠️ 一个"选择器常量"的用法说明（避免后来人误解）
// ```text
// DEX 常量给了 `div#djuu-musiclist-djlist div.djuu-list-item` 这个**整串**选择器。
// 本仓不引 HTML 解析库（不新增运行时依赖）。
// ⇒ 我们的取法：以 `class="… djuu-list-item …"` 作**块边界**切块，
//    再从每块里取 `data-bs-id`（id）+ `onclick="music.playlist(this)"` 后紧邻的 `<span>`（标题）。
//    ★ 这与"解释 CSS 选择器"**不是同一件事** —— 我如实标注为"按块边界抽取的近似"，
//      而不是假装实现了 CSS 选择器引擎。
//    ★ 结构一变（块数骤降）**必须报错**，不许静默返回空 —— 见 score 判定。
// ```
//
// # 与已实现类的差异
// ```text
// · 它是**音乐类**（单曲，不是剧集）⇒ 详情无"集"，只有 1 条播放线路
// · 取流要**第二跳 POST**（列表/详情都是 GET，只有取流是 POST）—— 与本批其它类不同
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 站点唯一域名（DEX 常量逐字：`https://m.djuu.com`）
pub const BASE: &str = "https://m.djuu.com";

/// DEX 里逐字给出的 UA（Chrome/151 长串）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
/// DEX 里逐字给出的 Referer
const REFERER: &str = "https://m.djuu.com/";

const GET_TIMEOUT: Duration = Duration::from_secs(15);

pub struct Djuu {
    client: super::http_context::CspHttpContext,
}

impl Djuu {
    pub const CLASS: &'static str = "Djuu";

    /// 首页分类 —— **从真实首页导航抽取所得**（不是 DEX 常量）
    ///
    /// # 为什么这里的分类与 TingBokan 的凭证等级不同（**如实标**）
    /// ```text
    /// TingBokan：DEX 常量里 18 组"名↔id"**成对**给出 ⇒ 高置信。
    /// Djuu    ：DEX 常量**没有**给出分类表；真站点的分类在首页的
    ///           `onclick="djuuSwitch.djlist('/djlist/<id>_0_1_1.html')"` 里。
    /// ⇒ 下面这份是**实测抓下来的**（2026-10-27），属"站点导航快照"，
    ///   站点改版后可能过时 —— 但**路径模板**（`/djlist/<id>_0_1_<pg>.html`）是稳的。
    /// ```
    /// ⚠️ 只取前 12 个（首页导航有 100+ 条，全塞进分类条会让 UI 不可用）；
    ///    其余分类仍可通过 `list("<id>", …)` 直接用 id 访问（模板已验证）。
    pub const CATEGORIES: &'static [(&'static str, &'static str)] = &[
        ("115", "独家舞曲"),
        ("116", "Y鼓(Electro)"),
        ("117", "福鼓(ProgHouse)"),
        ("118", "咚鼓(FunkyHouse)"),
        ("119", "外文"),
        ("122", "越南鼓(Vina/Lak)"),
        ("120", "CLUB"),
        ("123", "棒丝(Mel/Bounce)"),
        ("121", "DISCO"),
        ("125", "BreakBeat / RnB"),
        ("1", "迪高串烧"),
        ("13", "中文串烧"),
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

    async fn get_html(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header(reqwest::header::REFERER, REFERER)
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

    /// 取流第二跳：**POST** `/play/music`，表单参数 `id`
    ///
    /// 依据不是 DEX 常量（常量写的是 GET 查询串形态，实测 404），
    /// 而是站点自己的 `common.min.js`：`http("/play/music",{id:t},…,"POST","json")`。
    async fn post_play(&self, id: &str) -> Result<serde_json::Value, String> {
        let url = format!("{BASE}/play/music");
        self.post_play_url(&url, id).await
    }

    async fn post_play_url(&self, url: &str, id: &str) -> Result<serde_json::Value, String> {
        let resp = self
            .client
            .client()?
            .post(url)
            .header(reqwest::header::REFERER, format!("{BASE}/play/{id}.html"))
            .header(reqwest::header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .form(&[("id", id)])
            .send()
            .await
            .map_err(|e| format!("POST {url} 失败：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取 POST {url} 响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "POST {url} 返回 HTTP {status}；响应前 160 字节：{}",
                truncate(&body, 160)
            ));
        }
        serde_json::from_str(&body).map_err(|e| {
            format!(
                "POST {url} 不是合法 JSON：{e}；响应前 160 字节：{}",
                truncate(&body, 160)
            )
        })
    }
}

impl Default for Djuu {
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

/// 列表页 URL 模板（**实测校正后**的形态）
///
/// `/djlist/<分类id>_0_1_<页码>.html`（第 4 段是页码，已实测三页确认）
pub fn list_url(base: &str, category_id: &str, page: u32) -> String {
    let page = if page == 0 { 1 } else { page };
    format!("{base}/djlist/{category_id}_0_1_{page}.html")
}

/// 搜索 URL
pub fn search_url(base: &str, kw: &str, page: u32) -> String {
    let page = if page == 0 { 1 } else { page };
    format!("{base}/search?musicname={}&page={page}", urlencode(kw))
}

/// 播放页 URL（**实测**：带 `.html`，不是 DEX 常量的 `?id=` 形态）
pub fn play_page_url(base: &str, id: &str) -> String {
    format!("{base}/play/{id}.html")
}

/// 详情页 URL（同上；本实现 detail 用取流接口一并拿到元数据，这个函数留给探针/复核用）
pub fn detail_page_url(base: &str, id: &str) -> String {
    play_page_url(base, id)
}

/// 最小百分号编码（本仓"不新增运行时依赖"；只覆盖 keyword 用途）
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

/// 从 HTML 里按 `djuu-list-item` 块边界抽取条目
///
/// # 取法（**不是** CSS 选择器引擎 —— 如实标注）
/// ```text
/// ① 以 `class="…"` 里含 `djuu-list-item` 的容器标签作**块首**
/// ② 块首里取 `data-bs-id="<数字>"` 作条目 id
/// ③ 块内第一个 `onclick="music.playlist(this)"` 之后紧邻的 `<span>…</span>` 作标题
/// ④ 块内第一个 `<img … src="…">` 作封面（跳过 DEX 里的占位图 logo.png）
/// ⑤ 块内 `<span>` 里的 `ID:` 旁的数字可校验（本实现只用 data-bs-id，不解析文本）
/// ```
///
/// # ⚠️ 块搜索**必须从"当前标记本身之后"开始**（这条踩过坑，留档）
/// ```text
/// 第一版写 `find_next_list_item_marker(&after[1..])` —— 看似"跳过 1 字节"，
/// 但 `djuu-list-item` 在本块标签里出现的位置**远大于 1**（约 100 字节处），
/// ⇒ `after[1..]` 里第一次命中仍是**自己** ⇒ 块边界退化成"标签内某处"
///   ⇒ 只切出 1 块（真页面有 30/80 块）。
/// 门禁 `items_parse_by_block_boundary` 当场抓住（2 块断言 → 实际 1）。
/// ⇒ 正确做法：从 `after` 里**本标记结束之后**开始找（见下面 `search_from`）。
/// ```
///
/// # 为什么"块数骤降"必须报错
/// ```text
/// 站点换版后 `djuu-list-item` 可能改名 ⇒ 我们会切出 0 块。
/// 若静默返回空列表，上层看到的是"这个分类没内容"（假成功）。
/// ⇒ 这里做**合理性判定**：首页/列表页本该有几十条，切出 0 块就报"结构可能变了"。
/// ```
pub const MIN_ITEMS_PER_PAGE: usize = 5;

/// 标记串（同时用于"块首定位"与"跳过当前标记"）
const LIST_ITEM_TAG: &str = "djuu-list-item";

pub fn parse_items(html: &str, expect_items: bool) -> Result<Vec<CspItem>, String> {
    let mut items: Vec<CspItem> = Vec::new();
    let mut rest = html;

    while let Some(pos) = find_list_item_marker(rest) {
        let after = &rest[pos..];

        // ★ 从**本标记结束之后**开始找下一个块（不能只 +1，见上面留档）
        let self_end = after
            .find(LIST_ITEM_TAG)
            .map(|e| e + LIST_ITEM_TAG.len())
            .unwrap_or(0);
        let block_end = match find_next_list_item_marker(&after[self_end..]) {
            Some(next) => self_end + next,
            None => after.len(),
        };
        let block = &after[..block_end];

        if let Some(id) = extract_attr(block, "data-bs-id") {
            if !id.is_empty() {
                let title = extract_playlist_title(block)
                    .or_else(|| extract_first_span_text(block))
                    .unwrap_or_else(|| format!("曲目 {id}"));
                let cover = extract_first_img_src(block).filter(|s| !is_placeholder(s));
                items.push(CspItem {
                    id,
                    title,
                    cover,
                    subtitle: None,
                });
            }
        }
        // 推进到本块之后（block_end 至少为 1，保证前进）
        rest = &after[block_end.max(1)..];
    }

    // ★ 反空真（铁律 149）：页面"本该有条目"却切出 0 块 ⇒ 结构变了，不许静默空
    if expect_items && items.is_empty() {
        return Err(format!(
            "页面里找不到 djuu-list-item 块（本该有条目）⇒ 站点结构可能变了；页面长度 {} 字符",
            html.len()
        ));
    }
    Ok(items)
}

/// 找 `djuu-list-item` 标记所在位置（返回该位置前最近的 `<`，即标签起点）
///
/// ⚠️ 回退到 `<` 是**必须的**：`djuu-list-item` 前面还有别的 class 名
///   （`class="container … djuu-list-item djuu-list-bg2"`），
///   若不回退，块首会从 class 名中间开始、把 `data-bs-id` 留在块外。
fn find_list_item_marker(s: &str) -> Option<usize> {
    let pos = s.find("djuu-list-item")?;
    // 回退到标签起点：避免把 `djuu-list-item` 前面的 class 名截断
    let lt = s[..pos].rfind('<')?;
    Some(lt)
}

fn find_next_list_item_marker(s: &str) -> Option<usize> {
    find_list_item_marker(s)
}

/// 从一段 HTML 里取 `attr="value"`（也兼容 `attr='value'`）
pub fn extract_attr(block: &str, attr: &str) -> Option<String> {
    for (open, close) in [('"', '"'), ('\'', '\'')] {
        let needle = format!("{attr}={open}");
        if let Some(p) = block.find(&needle) {
            let start = p + needle.len();
            if let Some(end_rel) = block[start..].find(close) {
                let v = &block[start..start + end_rel];
                return Some(v.to_string());
            }
        }
    }
    None
}

/// 取 `onclick="music.playlist(this)"` 所在位置之后第一个 `<span>…</span>` 的文本
fn extract_playlist_title(block: &str) -> Option<String> {
    let p = block.find("music.playlist(this)")?;
    let after = &block[p..];
    extract_first_span_text(after)
}

/// 取第一个 `<span>…</span>` 的纯文本（剥掉内部标签与首尾空白）
pub fn extract_first_span_text(s: &str) -> Option<String> {
    let start_tag = s.find("<span>")?;
    let start = start_tag + "<span>".len();
    let end_rel = s[start..].find("</span>")?;
    let raw = &s[start..start + end_rel];
    let cleaned = strip_tags(raw);
    if cleaned.trim().is_empty() {
        None
    } else {
        Some(cleaned.trim().to_string())
    }
}

/// 取第一个 `<img … src="…">` 的 src
pub fn extract_first_img_src(s: &str) -> Option<String> {
    let p = s.find("<img ")?;
    let after = &s[p..];
    extract_attr(after, "src")
}

/// DEX 常量里的占位图 —— 它不是真封面，**不许当封面返回**
pub const PLACEHOLDER_COVER: &str = "/static/mobile/images/play/logo.png";

pub fn is_placeholder(src: &str) -> bool {
    src.contains(PLACEHOLDER_COVER)
}

/// 去标签（最小实现，够用于 span 内文本）
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

/// 取流响应 → 可播地址
///
/// # ★ 依据是**实测响应**（`data.url`），不是 DEX 常量的 `data.playUrl`
/// ```text
/// DEX 常量里的 `playUrl` 是**站点 JS 的内部变量名**（`playurl="/play/"+t.id+".html"`），
/// 不是响应字段名。真响应 `data` 里的键是 **`url`**。
/// ⇒ 本实现读 `url`。若读 `playUrl` 会永远取不到（**这就是照抄常量会掉的坑**）。
/// ```
pub fn parse_play(v: &serde_json::Value, id: &str) -> Result<Vec<CspPlay>, String> {
    let code = v.get("code").and_then(|c| c.as_i64());
    match code {
        Some(0) => {}
        Some(other) => {
            return Err(format!(
                "取流接口业务码非 0：code={other}, msg={}",
                v.get("msg").and_then(|m| m.as_str()).unwrap_or("(无)")
            ))
        }
        None => {
            return Err(format!(
                "取流响应缺少 code：{}",
                truncate(&v.to_string(), 200)
            ))
        }
    }

    let data = v
        .get("data")
        .ok_or_else(|| format!("取流响应没有 data：{}", truncate(&v.to_string(), 200)))?;
    let url = data
        .get("url")
        .and_then(|u| u.as_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            format!(
                "取流响应 data 里没有 url（curve：DEX 常量写的是 playUrl，实测字段名是 url）\
                 ⇒ 上游结构可能变了：{}",
                truncate(&data.to_string(), 260)
            )
        })?;

    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err(format!("取流返回的 url 不是 http(s)：{}", truncate(url, 120)));
    }

    let title = data.get("title").and_then(|t| t.as_str()).unwrap_or(id);
    Ok(vec![CspPlay {
        url: url.to_string(),
        // DEX 里详情/取流都带 User-Agent + Referer ⇒ 原样给出（CDN 可能校验）
        headers: vec![
            ("User-Agent".to_string(), UA.to_string()),
            ("Referer".to_string(), REFERER.to_string()),
        ],
        label: Some(format!("DJ呦呦网：{}", truncate(title, 40))),
    }])
}

/// 取流响应 → `CspDetail`（本类的"详情"= 单曲信息，无集）
///
/// # 为什么详情也走同一个 POST 接口
/// ```text
/// 真站点的详情页 `/play/<id>.html` **是服务端渲染的壳**（8409 B），
/// 真正的曲目元数据（title/img/url/album）由页面里的 JS
/// `music.playone(id)` → POST /play/music 取回。
/// ⇒ 我们直接调那个接口，**不解析页面壳**（壳里没有元数据可解析）。
/// ```
pub fn parse_detail(v: &serde_json::Value, id: &str) -> Result<CspDetail, String> {
    let plays = parse_play(v, id)?;
    let data = v.get("data").cloned().unwrap_or(serde_json::Value::Null);

    let title = data
        .get("title")
        .and_then(|t| t.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .ok_or_else(|| {
            format!(
                "取流响应 data 里没有 title ⇒ 结构可能变了：{}",
                truncate(&data.to_string(), 200)
            )
        })?;

    let cover = data
        .get("img")
        .and_then(|i| i.as_str())
        .filter(|s| !s.is_empty() && !is_placeholder(s))
        .map(|s| s.to_string());

    // 描述：把上游真实给出的元数据拼起来（**只用响应里真有的字段**）
    let mut parts: Vec<String> = Vec::new();
    if let Some(album) = data
        .pointer("/album/title")
        .and_then(|t| t.as_str())
        .filter(|s| !s.is_empty())
    {
        parts.push(format!("专辑：{album}"));
    }
    if let Some(ms) = data.get("musicsize").and_then(|v| v.as_f64()) {
        parts.push(format!("大小：{ms} MB"));
    }
    if let Some(t) = data.get("time").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
        parts.push(format!("发布：{t}"));
    }
    if let Some(h) = data.get("hits_num").and_then(|v| v.as_u64()) {
        parts.push(format!("热度：{h}"));
    }
    let description = if parts.is_empty() {
        None
    } else {
        Some(parts.join(" · "))
    };

    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover,
        description,
        // 音乐类：1 首 = 1 条线路（DEX 常量 vod_play_from 只有 "DJ呦呦网" 一段）
        episodes: plays
            .into_iter()
            .map(|p| CspEpisode {
                id: p.url.clone(),
                title: "播放".to_string(),
                flag: "DJ呦呦网".to_string(),
            })
            .collect(),
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Djuu {
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
        // 首屏取第一个分类
        let first = Self::CATEGORIES[0].0;
        let url = list_url(BASE, first, 1);
        let html = self.get_html(&url).await?;
        let items = parse_items(&html, true)?;
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        // 分类 id 必须是**纯数字**（模板 `_0_1_<pg>.html` 的形态要求）
        if !tid.chars().all(|c| c.is_ascii_digit()) {
            return Err(format!("分类 id 必须是数字（实测路径模板如此）：{tid}"));
        }
        let page = if page == 0 { 1 } else { page };
        let url = list_url(BASE, tid, page);
        let html = self.get_html(&url).await?;
        let items = parse_items(&html, true)?;
        Ok(CspList {
            items,
            page,
            // ★ 上游**没有**给出总页数/总数（列表页是纯 HTML，分页控件里也没数字）
            //   ⇒ 如实给 None，**不猜**
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("曲目 id 为空".to_string());
        }
        if !id.chars().all(|c| c.is_ascii_digit()) {
            return Err(format!("曲目 id 必须是数字：{id}"));
        }
        let v = self.post_play(id).await?;
        parse_detail(&v, id)
    }

    /// 取流：**已在 detail 里取到**（同一 POST 接口），这里原样返回
    ///
    /// # 为什么允许"不联网"
    /// ```text
    /// detail() 拿到的 `data.url` 就是可播直链，已塞进 `CspEpisode.id`。
    /// play() 收到的 `id` 就是那个直链 ⇒ 校验后原样返回。
    /// ★ 这也让"详情已看过 ⇒ 起播零额外请求"成为可能（对 UI 友好）。
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if !(id.starts_with("http://") || id.starts_with("https://")) {
            // 兼容"直接拿曲目数字 id 来取流"的调用方：真发一次第二跳
            if id.chars().all(|c| c.is_ascii_digit()) {
                let v = self.post_play(id).await?;
                return parse_play(&v, id);
            }
            return Err(format!("播放 id 既不是 http(s) 地址也不是曲目数字 id：{}", truncate(id, 120)));
        }
        Ok(vec![CspPlay {
            url: id.to_string(),
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                ("Referer".to_string(), REFERER.to_string()),
            ],
            label: Some("DJ呦呦网".to_string()),
        }])
    }

    /// DEX 里 Djuu **有** searchContent（12 个方法里有它）⇒ 真支持搜索
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let url = search_url(BASE, kw, page);
        let html = self.get_html(&url).await?;
        let items = parse_items(&html, true)?;
        Ok(CspList {
            items,
            page,
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
// csp_Djuu（🎶呦呦｜DJ音乐）：★ 三处"DEX 模板 ≠ 真站点"，都按实测校正
//   ① 列表 DEX 给 /1_1.html → **实测 404**；真路径 /djlist/<分类id>_0_1_<页码>.html
//   ② 详情 DEX 给 /play/music?id= → **实测 404**；真页面 /play/<id>.html，
//      而 /play/music **只认 POST + 表单 id**
//   ③ 取流字段 DEX 写 data.playUrl → 实测是 **data.url**
//   实测全链：列表 200/30 项 · 取流 200 → https://mp4.djuu.com/…/4e631263bc875fcd.m4a（可播 m4a）
// ⚠️ 已知缺口：原版有 mProxy，本批不做（见文件头）。
// ⚠️ 分类表是**导航快照**（非 DEX 常量）—— 与 TingBokan 的凭证等级不同，已在代码里标明。
// ```
crate::csp::register_site!(Djuu);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
#[path = "djuu_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实列表页片段（2026-10-27 实测抓下后裁剪）
    const FIX_LIST: &str = r#"
<div class="container px-0 ps-1 d-flex flex-nowrap justify-content-between align-items-center djuu-list-item djuu-list-bg2"
     data-bs-id="327664">
  <div class="d-flex flex-column text-nowrap overflow-hidden me-2" onclick="music.playlist(this)">
    <span>DJ傑少-国粤语Electro音打造2026年10月超爽HIFI慢摇串烧</span>
    <div class="d-flex justify-content-start align-items-center">
      <div class="djuu-ml-span">ID:327664</div>
      <div class="djuu-ml-span">HIT:2.7℃</div>
      <div class="djuu-ml-span">TIME:2026/10/27</div>
    </div>
  </div>
</div>
<div class="container px-0 ps-1 d-flex flex-nowrap justify-content-between align-items-center djuu-list-item djuu-list-bg2"
     data-bs-id="327745">
  <div class="d-flex flex-column text-nowrap overflow-hidden me-2" onclick="music.playlist(this)">
    <span>【DJUU私货】烟嗓船长 - 没有你陪伴真的好孤单(Dj阿宽 Electro Rmx 2026)</span>
    <img src="/static/mobile/images/play/logo.png" alt="">
  </div>
</div>"#;

    /// 真实取流响应（2026-10-27 实测，裁剪掉 album 细节）
    const FIX_PLAY: &str = r#"{
      "code": 0, "msg": "",
      "data": {"img": "https://img.djuu.com/public/storage/cover/20231001/122c745a_big.jpg",
               "id": 327745,
               "title": "【DJUU私货】烟嗓船长 - 没有你陪伴真的好孤单(Dj阿宽 Electro Rmx 2026)",
               "url": "https://mp4.djuu.com/c115/9419/116/2026/4e631263bc875fcd.m4a",
               "user_id": 9419, "time": "2026/10/27", "hits_num": 44,
               "musicsize": 14.69, "categorie_id": 116,
               "album": {"id": 9419, "title": "DJ阿宽"}},
      "count": 0
    }"#;

    fn j(s: &str) -> serde_json::Value {
        serde_json::from_str(s).expect("夹具必须是合法 JSON")
    }

    // ── ★ 三处"模板 ≠ 真站点"的路径形态（判据钉住实测值）──

    #[test]
    /// ★ 列表路径：DEX 常量是 `/1_1.html`（**实测 404**），真路径是 `/djlist/<id>_0_1_<pg>.html`
    ///
    /// 注入：把 `list_url` 改回 DEX 模板 `format!("{base}/{cid}_{page}.html")` ⇒ 本条红。
    fn list_url_is_the_measured_path_not_the_dex_template() {
        assert_eq!(
            list_url(BASE, "115", 1),
            "https://m.djuu.com/djlist/115_0_1_1.html",
            "★ 实测路径（DEX 模板 /115_1.html 是 404）"
        );
        // 页码位在**第 4 段**：三页实测确认过
        assert_eq!(list_url(BASE, "115", 3), "https://m.djuu.com/djlist/115_0_1_3.html");
        // page=0 归一成 1（不许发出 `_0` 页）
        assert_eq!(list_url(BASE, "115", 0), "https://m.djuu.com/djlist/115_0_1_1.html");
    }

    #[test]
    /// ★ 播放页：DEX 常量是 `/play/music?id=`（**实测 404**），真页面是 `/play/<id>.html`
    fn play_page_url_is_the_measured_html_form() {
        assert_eq!(play_page_url(BASE, "327745"), "https://m.djuu.com/play/327745.html");
    }

    #[test]
    /// ★ 取流字段：DEX 常量写 `playUrl`，实测响应字段是 `url`
    ///
    /// 注入：`parse_play` 里把 `data.get("url")` 改成 `data.get("playUrl")` ⇒ 本条与
    ///       live 断言一起红（拿不到地址）。
    fn play_response_field_is_url_not_playurl() {
        let plays = parse_play(&j(FIX_PLAY), "327745").expect("真响应必须解析得出来");
        assert_eq!(plays.len(), 1);
        assert_eq!(
            plays[0].url,
            "https://mp4.djuu.com/c115/9419/116/2026/4e631263bc875fcd.m4a",
            "★ 字段名是 url"
        );
    }

    #[test]
    /// 取流返回的 headers 必须带 UA + Referer（DEX 两处都给了）
    fn play_carries_ua_and_referer() {
        let plays = parse_play(&j(FIX_PLAY), "327745").unwrap();
        let names: Vec<&str> = plays[0].headers.iter().map(|(k, _)| k.as_str()).collect();
        assert!(names.contains(&"User-Agent"), "{names:?}");
        assert!(names.contains(&"Referer"), "{names:?}");
    }

    // ── parse_items ───────────────────────────────────────────────

    #[test]
    fn items_parse_by_block_boundary() {
        let items = parse_items(FIX_LIST, true).expect("真页面片段必须解析得出来");
        assert_eq!(items.len(), 2, "两个 djuu-list-item 块");
        assert_eq!(items[0].id, "327664");
        assert!(
            items[0].title.starts_with("DJ傑少-国粤语Electro"),
            "标题来自 onclick=music.playlist 后的第一个 span：{}",
            items[0].title
        );
        assert_eq!(items[1].id, "327745");
        assert!(
            items[1].title.starts_with("【DJUU私货】烟嗓船长"),
            "{}",
            items[1].title
        );
    }

    #[test]
    /// ★ 占位图**不许**当封面返回（DEX 常量里那个 logo.png）
    fn placeholder_cover_is_dropped() {
        let items = parse_items(FIX_LIST, true).unwrap();
        assert_eq!(items[1].cover, None, "logo.png 是占位图，不许当封面");
    }

    #[test]
    /// ★ 反空真 ①：**本该有条目却切出 0 块** ⇒ 报错（结构变了）
    ///
    /// 注入：删掉 `parse_items` 里那段 `expect_items && items.is_empty()` ⇒ 本条红。
    fn empty_extraction_on_expected_page_is_error() {
        let broken = "<html><body><div class=\"card\"><a href=\"/x\">标题</a></div></body></html>";
        let err = parse_items(broken, true).unwrap_err();
        assert!(err.contains("结构可能变了"), "结构变了必须报明确原因：{err}");
    }

    #[test]
    /// ★ 反空真 ②（成对）：**明确不期望条目**时，空列表是正常的（不报错）
    ///
    /// 这条与上一条成对，证明两者被区分开了（不是"一律报错"）。
    fn empty_extraction_when_not_expected_is_ok() {
        let broken = "<html><body>no items</body></html>";
        let items = parse_items(broken, false).expect("不期望条目时，空就是空");
        assert!(items.is_empty());
    }

    // ── parse_detail ──────────────────────────────────────────────

    #[test]
    fn detail_maps_real_fields_only() {
        let d = parse_detail(&j(FIX_PLAY), "327745").expect("真响应必须解析得出来");
        assert!(d.title.starts_with("【DJUU私货】"));
        assert_eq!(
            d.cover.as_deref(),
            Some("https://img.djuu.com/public/storage/cover/20231001/122c745a_big.jpg")
        );
        assert_eq!(d.episodes.len(), 1, "音乐类：1 首 = 1 条线路");
        assert_eq!(d.episodes[0].flag, "DJ呦呦网", "DEX 的 vod_play_from 只有这一段");
        assert_eq!(
            d.episodes[0].id,
            "https://mp4.djuu.com/c115/9419/116/2026/4e631263bc875fcd.m4a"
        );
        let desc = d.description.clone().unwrap_or_default();
        assert!(desc.contains("专辑：DJ阿宽"), "描述用响应里真有的字段：{desc}");
        assert!(desc.contains("大小：14.69 MB"), "{desc}");
    }

    #[test]
    /// ★ 反空真 ③：取流成功但**没有 url** ⇒ 报错（并点名 DEX 字段名的坑）
    fn play_without_url_is_error() {
        let bad = j(r#"{"code":0,"data":{"id":1,"title":"某曲"}}"#);
        let err = parse_play(&bad, "1").unwrap_err();
        assert!(err.contains("没有 url"), "{err}");
        assert!(err.contains("playUrl"), "错误信息要点出 DEX 字段名的坑：{err}");
    }

    #[test]
    fn play_with_non_zero_code_is_error() {
        let bad = j(r#"{"code":1,"msg":"什么错","data":{}}"#);
        let err = parse_play(&bad, "1").unwrap_err();
        assert!(err.contains("业务码非 0"), "{err}");
    }

    #[test]
    fn play_with_non_http_url_is_error() {
        let bad = j(r#"{"code":0,"data":{"url":"/c115/x.m4a"}}"#);
        let err = parse_play(&bad, "1").unwrap_err();
        assert!(err.contains("不是 http(s)"), "{err}");
    }

    #[test]
    fn detail_without_title_is_error() {
        let bad = j(r#"{"code":0,"data":{"url":"https://x/y.m4a"}}"#);
        let err = parse_detail(&bad, "1").unwrap_err();
        assert!(err.contains("没有 title") || err.contains("结构可能变了"), "{err}");
    }

    // ── 边界 / 能力位 ─────────────────────────────────────────────

    #[test]
    fn urlencode_matches_utf8() {
        assert_eq!(urlencode("红"), "%E7%BA%A2");
        assert_eq!(urlencode("abc"), "abc");
    }

    #[test]
    fn search_is_declared_supported() {
        assert!(Djuu::new().supports_search(), "★ DEX 里 Djuu 有 searchContent");
    }

    #[tokio::test]
    async fn empty_kw_fails_instead_of_silent_all() {
        let err = Djuu::new().search("  ", 1, "").await.unwrap_err();
        assert!(err.contains("搜索词为空"), "{err}");
    }

    #[tokio::test]
    /// ★ 非纯数字的分类 id **显式失败**（不许拼进模板发出乱 URL）
    async fn non_numeric_category_fails() {
        let err = Djuu::new().list("abc", 1, "").await.unwrap_err();
        assert!(err.contains("必须是数字"), "{err}");
    }

    #[tokio::test]
    async fn empty_tid_fails() {
        let err = Djuu::new().list("  ", 1, "").await.unwrap_err();
        assert!(err.contains("分类 id 为空"), "{err}");
    }

    #[tokio::test]
    async fn play_returns_direct_url_as_is() {
        let url = "https://mp4.djuu.com/c115/9419/116/2026/4e631263bc875fcd.m4a";
        let plays = Djuu::new().play("DJ呦呦网", url, "").await.expect("直链原样返回");
        assert_eq!(plays[0].url, url);
    }

    #[tokio::test]
    async fn play_rejects_garbage_id() {
        let err = Djuu::new().play("DJ呦呦网", "not-an-id", "").await.unwrap_err();
        assert!(err.contains("既不是 http(s) 地址也不是曲目数字 id"), "{err}");
    }

    // ── 真网络（默认不跑；显式跑必须给 CSP_LIVE=1）──

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib djuu_live -- --ignored --nocapture"]
    async fn djuu_live_home_list_detail_play_search() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = Djuu::new();

        let home = s.home("").await.expect("home 必须真取到数据");
        assert_eq!(home.categories.len(), 12);
        assert!(!home.items.is_empty(), "★ 反空真：首屏必须有真条目");
        println!("LIVE home：分类 {} 个，首屏 {} 条", home.categories.len(), home.items.len());

        let list = s.list("115", 1, "").await.expect("独家舞曲分类必须真取到数据");
        assert!(!list.items.is_empty(), "★ 反空真");
        println!("LIVE list 独家舞曲：{} 条", list.items.len());

        // ★ 分页：第 2 页首条应与第 1 页不同（证明真是不同页，不是同页复读）
        let list2 = s.list("115", 2, "").await.expect("第 2 页必须真取到数据");
        assert!(!list2.items.is_empty(), "★ 反空真：第 2 页不能空");
        assert_ne!(
            list2.items[0].id, list.items[0].id,
            "★ 第 2 页首条必须与第 1 页不同（否则说明页码位没生效）"
        );
        println!(
            "LIVE 分页对照：p1 首条={} p2 首条={}",
            list.items[0].id, list2.items[0].id
        );

        let id = list.items[0].id.clone();
        let d = s.detail(&id, "").await.expect("详情必须真取到数据");
        assert!(!d.title.is_empty(), "★ 反空真：详情必须有标题");
        println!("LIVE detail {id}：title={} 线路={}", d.title, d.episodes.len());

        let ep = d.episodes.first().expect("已断言非空");
        let plays = s.play(&ep.flag, &ep.id, "").await.expect("直链必须返回");
        assert!(
            plays[0].url.starts_with("http"),
            "★ 反空真：必须是真地址（实测形如 https://mp4.djuu.com/…/xxx.m4a）"
        );
        println!("LIVE play：{}", plays[0].url);

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
        let src = crate::csp::shared::impl_src_only(include_str!("djuu.rs"));
        assert!(
            src.contains(".no_proxy()"),
            "★ Client 构造链必须含 `.no_proxy()`（不读系统代理）；             否则装了代理的机器上会把'站点可用'测成'全宕'"
        );
    }
}
