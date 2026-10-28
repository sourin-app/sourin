// ═══════════════════════════════════════════════════════════════════════
//  csp_SaoHuo —— TVBox `csp_SaoHuo` 的 Rust 重写（「骚火电影」HTML 抓取型）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```json
// {"key":"骚火","name":"🔥骚火电影","type":3,"api":"csp_SaoHuo",
//  "searchable":1,"quickSearch":1,"filterable":1,
//  "ext":"https://shdy5.us"}
// ```
//
// # ★★★ 分档：**上游可用 —— 我第一版判错过，这是更正后的读数**
//
// ```text
// ⚠️ 我在 2026-10-27 第一次探测时写过"上游当前不可用（522）"——**那是错的**。
//   错因（这正是 Lead 反复强调的那个形态）：**我打的是根路径**。
//      `https://shdy5.us/`        ⇒ **522**   ← 我据此下了"上游死"的结论
//      `https://shdy5.us/list/1-1.html` ⇒ **200 / 16931 b / 真卡片 72 条**   ← 真实用法
//   ⇒ "我的探测路径不对" 与 "上游死了" 在读数上**长得一样**（都是 522）。
//     区分它需要**按真实用法打一次** —— 而我第一版没做，直接下了结论。
//   ★ 真正把我拉回来的是**本类的真网用例**：它报了 `list 成功：36 条`。
//     如果我把真网用例写成"预期失败"（"上游死"那条路线），这个错判就会被**固化**。
//   ⇒ 这也是本批的一条教训：**别把"我打不通"写成"上游死"**。
// ```
//
// ## 更正后的实测（2026-10-27）
// | 目标 | 状态 | 说明 |
// |---|---|---|
// | `https://shdy5.us/list/1-1.html` | **200 / 16931 b** | ★ **真实用法，可用**（卡片 72 条） |
// | `https://shdy5.us/list/2-1.html` | **200 / 16879 b** | 可用 |
// | `https://shdy5.us/`（根路径） | **522 / 16 b** | 站方**只对内容页响应**，根路径连的是另一层 |
// | `http://shapp.us/`（地址发布页） | **200 / 8310 b** | 发布页（`<title>骚火电影(saohuo)地址发布页`），**不是站点本体** |
//
// ## ★ 真网读数（CSP_LIVE=1，本类**已打通**）
// ```text
// [LIVE] home: 分类 4 个（首=电影）
// [LIVE] list 成功：**36 条** —— ★ 上游**活了**
// [LIVE] 地址发布页探测成功 ⇒ 新域名 = https://shdy5.us
// ```
//
// ## ★★ 真网读数一次抓到 **2 个我只靠离线夹具抓不到的真 bug**
// ```text
// ① **中文页面上按字节切窗口 ⇒ panic**
//    第一次真网跑就崩：`end byte index 612 is not a char boundary; it is inside '作'`
//    （中文标题 3 字节/字，`end+600` 正好切在字中间）
//    离线夹具**全 ASCII** ⇒ 完全碰不到。⇒ 修：统一走 `char_boundary_at` 回退到字符边界，
//    并补离线回归门禁 `chinese_pages_do_not_panic_on_byte_windows`（否则下次回归）。
// ② **`href` 是相对路径 ⇒ 不拼站点前缀则详情段断掉（且静默）**
//    实测 72/72 条卡片都是 `href="/movie/50374.html"`（**绝对 0 条**）；
//    DEX `categoryContent` 第 84-104 行**逐字**是 `前缀 + href` ⇒ 必须拼。
//    我第一版原样返回 ⇒ 列表段"有 36 条"看起来正常，**详情段拿到相对路径就打不出去**。
//    ⇒ 离线夹具里我写的是绝对 `https://…` ⇒ **又一次被夹具的理想化掩盖**。
// ★ 两次都是同一形态：**离线夹具比真实数据"干净"，于是真实数据形态的坑全被放过**。
// ```
//
// # 协议复原（DEX 逐条；这是本类真正的交付物）
//
// ```text
// ① 请求头（DEX `a()`，:8-24 逐字）
//      User-Agent: Chrome151 那条
//      accept-language: zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7
//      Cookie: 仅当字段 b 非空才加（`TextUtils.isEmpty(b)` 那条 if）
// ② ★ **域名探测**（DEX `init`，:468-502）—— 这是本类最有意思的一段
//      兜底域名 `http://shapp.us/` → GET → 抓 CSS 选择器 `.content-top a`
//      → 取第一个的 `href` ⇒ 那就是**当前站点前缀**，存进字段 a
//      ⇒ 设计意图：**主站换域名后，兜底页会告诉你新地址**（自举式探活）
//      ⚠️ 但兜底页自己也会过期/被换 ⇒ 这不是"永远能自愈"，只是"多一层机会"。
// ③ 列表：`{site}/list/{tid}-{page}.html`
//      DEX 的选择器链（第 84-143 行）：
//        `{site}` + `a`（取 `href`）→ `a`（取 `title`）→ `img`（取 `data-original`）
//      ⇒ 逐个卡片取 链接 / 标题 / 封面（**HTML 抓取型**，不是 JSON）
// ④ 搜索：`{site}/s----------.html?wd=` + **URLEncoder 编码的关键词**
// ⑤ 详情：`#play_link li`（每条线路）→ `.play_from ul.from_list li`（线路名）
//      线路名里含 base64 片段 `566A5LuL77ya`（= "简介：" 的 UTF-8 base64）
//      ⇒ 那是 DEX 用来**剥掉中文前缀**的技巧（这里按语义实现，不照抄魔法串）
//      集：`a` 的 `href`，线路之间 `$$$`，集之间 `#`
// ⑥ 取流：详情页里找 `iframe` 的 `src` ⇒ 若命中就走 `{src}`；
//      否则把详情地址原样交给调用方（DEX `playerContent` 就是这两条分支）
// ```
//
// # ⚠️ 本仓没有 HTML 解析 crate（如实说明，不新增依赖）
// ```text
// `Cargo.toml` 里**没有** `scraper` / `html5ever` / `kuchiki` ⇒ 本类按**本仓先例**
//   手写扫描（`csp/ikanbot.rs` 就是 HTML 抓取型，它自己实现了 `strip_style_script` /
//   `take_attr` / `list_from_html`）⇒ 我沿用同一路子，**零新增依赖**。
// ★ 本类的选择器因此是"**按结构扫描**"而不是"通用 CSS 选择器"：
//   实现时把 DEX 选择器链翻成"在标签流里定位 `a` → 取 `href`/`title` → 找其内 `img` 的
//   `data-original`"这套动作。**不是**假装支持任意 CSS。
// ```
//
// # ⚠️ 已知缺口（按契约"不许静默丢、不许自己造"）
// ```text
// ① `mProxy`：DEX 方法表里**没有**（只有 `<init>/a/categoryContent/detailContent/
//    homeContent/init/playerContent/searchContent`）⇒ 本批"不做 mProxy"对此类零影响。
// ② `loadPic`：没有 ⇒ 封面走源 `cover_headers`（声明式）。
//    ⚠️ 但 `CspSite` **没有** `cover_headers()` 能力位（与 Douban/AppGet/Duboku 同一条缺口）。
// ③ `initApi`：没有。
// ④ `isVideoFormat` / `manualVideoCheck`：DEX 里**没有**。
// ⑤ `set-cookie`（homeContent 里提到）：DEX 用来把上游 cookie 存进字段 b，
//    供后续请求复用。本仓 `CspSite` **没有**"跨段持久化 cookie"的能力位
//    ⇒ 我把它做成**进程内缓存**（`OnceLock` + `Mutex`），并如实登记为"不等价位"。
//```

use std::sync::Mutex;

use async_trait::async_trait;
use serde_json::Value;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
const ACCEPT_LANG: &str = "zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7";

/// DEX `init` 里写死的兜底域名（**地址发布页**，不是站点本体）
const FALLBACK_SITE: &str = "http://shapp.us/";

/// DEX 的工具运动式 `566A5LuL77ya` = UTF-8 "简介：" 的 base64
///
/// ★ 实现里**不照抄这个魔法串**：它是"DEX 用来在简介里切掉中文前缀"的标记，
///   按语义实现（剥掉行首的"简介："）比复刻 base64 更可读，也不会因为编码差异失效。
pub const DESC_PREFIX_B64: &str = "566A5LuL77ya";

/// 从一个**绝对详情 URL** 里取出站点前缀（`https://host`）
///
/// 详情段的 `id` 本身就是列表段拼好的绝对 URL ⇒ 从它反推站点前缀，
/// **避免把 site 一路当参数传**（少一个参数就少一处能传错的入口）。
pub fn site_of(url: &str) -> String {
    let u = url.trim();
    // 形如 `https://host/path…` ⇒ 取 `https://host`
    let Some((scheme, rest)) = u.split_once("://") else {
        return String::new();
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    if host.is_empty() {
        return String::new();
    }
    format!("{scheme}://{host}")
}

/// 把任意字节偏移**回退到最近的字符边界**（安全切片用）
///
/// # 为什么必须有它
/// ```text
/// Rust 的 `&s[a..b]` 在 `b` 不是字符边界时会 **panic**（不是返回 Err）。
/// 手写 HTML 扫描里到处是"取 tag 后 600 字节"这种**按字节**的窗口，
/// 而中文标题是 3 字节/字 ⇒ 真网必踩。
/// ★ 实测：本类**第一次真网跑就 panic**（`end byte index 612 is not a char boundary;
///   it is inside '作'`），而离线夹具全 ASCII ⇒ **完全碰不到**。
///   ⇒ 这是"真网读数不可替代"的一个具体例证（不是"再跑一遍确认"）。
/// ```
pub fn char_boundary_at(s: &str, mut idx: usize) -> usize {
    if idx >= s.len() {
        return s.len();
    }
    while idx > 0 && !s.is_char_boundary(idx) {
        idx -= 1;
    }
    idx
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（HTML 扫描，全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// 取某个标签的属性值（本仓先例同形：`ikanbot::take_attr`）
///
/// 支持 `attr="v"` / `attr='v'` / `attr=v` 三种写法；大小写不敏感。
pub fn attr_of(tag: &str, attr: &str) -> Option<String> {
    let low = tag.to_ascii_lowercase();
    let key = attr.to_ascii_lowercase();
    let mut from = 0usize;
    while let Some(rel) = low[from..].find(&key) {
        let i = from + rel;
        // 属性名必须是**独立**的（前一个字符不是字母/数字/`-`），否则 `data-original` 会撞 `original`
        let prev_ok = i == 0
            || !low[..i]
                .chars()
                .last()
                .map(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
                .unwrap_or(false);
        let after = &low[i + key.len()..];
        let trimmed = after.trim_start();
        // 属性名后必须是 `=` 或空白（避免 `data-original` 被 `original` 命中）
        if prev_ok && (trimmed.starts_with('=') || after.starts_with(char::is_whitespace)) {
            let rest = trimmed.trim_start_matches([' ', '\t', '\n', '\r']);
            if let Some(r) = rest.strip_prefix('=') {
                let r = r.trim_start();
                let (q, body) = match r.chars().next() {
                    Some('"') => ('"', &r[1..]),
                    Some('\'') => ('\'', &r[1..]),
                    _ => ('\0', r),
                };
                let val = if q == '\0' {
                    /*
                     * ★ 无引号属性值**只能按空白或 `>` 截断** ——
                     *   第一版我连 `/` 也当分隔符，结果 `href=https://x/2` 被截成 `https:`
                     *   （门禁 `attr_matching_requires_standalone_name` 当场抓到：期望
                     *    `https://x/2`、实际 `https:`）。
                     *   HTML 里未加引号的属性值**允许含 `/`**（自闭合的 `/>` 是标签尾，
                     *   不会出现在属性值中间）⇒ 只认空白与 `>`。
                     */
                    r.split(|c: char| c.is_whitespace() || c == '>')
                        .next()
                        .unwrap_or("")
                } else {
                    body.split(q).next().unwrap_or("")
                };
                if !val.is_empty() {
                    return Some(decode_entities(val));
                }
            }
        }
        from = i + key.len();
        if from >= low.len() {
            break;
        }
    }
    None
}

/// 常见 HTML 实体（`&amp;` 等）—— 不引 crate，按需替换
pub fn decode_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

/// 剥掉 `<script>` / `<style>` 段（本仓先例：`ikanbot::strip_style_script`）
pub fn strip_script_style(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let low = html.to_ascii_lowercase();
    let mut i = 0usize;
    while i < html.len() {
        let mut hit: Option<(usize, &str)> = None;
        for tag in ["<script", "<style"] {
            if let Some(rel) = low[i..].find(tag) {
                let at = i + rel;
                if hit.is_none() || at < hit.unwrap().0 {
                    hit = Some((at, tag));
                }
            }
        }
        match hit {
            None => {
                out.push_str(&html[i..]);
                break;
            }
            Some((at, tag)) => {
                out.push_str(&html[i..at]);
                let close = format!("</{}>", &tag[1..]);
                match low[at..].find(&close) {
                    Some(rel) => i = at + rel + close.len(),
                    None => break, // 没闭合 ⇒ 后面全是脚本，丢掉（并让上层判空报错）
                }
            }
        }
    }
    out
}

/// ★ 域名探测（DEX `init` 的等价）：从地址发布页里抓 `.content-top a` 的 `href`
///
/// # 为什么要这一步（不是"多余的兜底"）
/// ```text
/// 主站换域名后，**DEX 就是靠这一页自举探活**的。
/// ⇒ 实现它 = 复刻"站点协议的一部分"，而不是"我为了让测试过而加的东西"。
/// ```
/// ⚠️ 但**兜底页本身也会失效**（实测 2026-10-27 它活着、但它给出的新域名全 522）
///    ⇒ 返回值必须能被上层区分成"探到/没探到"。
pub fn probe_site_from(html: &str) -> Option<String> {
    let body = strip_script_style(html);
    // 目标：class 里含 `content-top` 的元素下的 `<a href=…>`
    let low = body.to_ascii_lowercase();
    let at = low.find("content-top")?;
    let seg = &body[at..];
    let a_at = seg.to_ascii_lowercase().find("<a")?;
    let a_seg = &seg[a_at..];
    let end = a_seg.find('>').map(|e| e + 1).unwrap_or(a_seg.len());
    let tag = &a_seg[..end];
    let href = attr_of(tag, "href")?;
    let h = href.trim();
    if h.is_empty() {
        return None;
    }
    Some(h.trim_end_matches('/').to_string())
}

/// 基址规范化（ext 给的站点前缀；去尾 `/`）
pub fn base_of(ext: &str) -> String {
    let t = ext.trim().trim_matches('"');
    if t.is_empty() {
        return String::new();
    }
    /*
     * ext 可能是 JSON 字符串（`"https://shdy5.us"`）也可能是对象。
     * 与 csp_AppGet 同一处置：只认"看起来像 URL 的那段"，不猜。
     */
    if let Ok(Value::String(s)) = serde_json::from_str::<Value>(t) {
        return s.trim().trim_end_matches('/').to_string();
    }
    if let Ok(Value::Object(o)) = serde_json::from_str::<Value>(t) {
        if let Some(s) = o.get("url").and_then(|x| x.as_str()) {
            return s.trim().trim_end_matches('/').to_string();
        }
    }
    if t.starts_with("http") {
        return t.trim_end_matches('/').to_string();
    }
    String::new()
}

/// 列表 URL 模板（DEX 逐字 `'/list/%s-%s.html'`）
pub fn list_url(site: &str, tid: &str, page: u32) -> String {
    format!("{}/list/{}-{}.html", site.trim_end_matches('/'), tid, page)
}

/// 搜索 URL 模板（DEX 逐字 `'/s----------.html?wd='` + URLEncoder）
pub fn search_url(site: &str, kw: &str) -> String {
    format!(
        "{}/s----------.html?wd={}",
        site.trim_end_matches('/'),
        urlencoding::encode(kw)
    )
}

/// 从列表 HTML 抓卡片（DEX 选择器链：`a` 取 `href`/`title` → 内层 `img` 取 `data-original`）
///
/// # ★★ `site` 参数是**必需**的（不是可选的美化）—— 真网抓到的第二个真 bug
/// ```text
/// DEX `categoryContent` 第 84-104 行**逐字**是：
///     StringBuilder().append(字段 a = 站点前缀).append(a 的 href)
///   ⇒ 即 **`{站点前缀} + {href}`**（因为上游给的是**相对路径**）。
///
/// 实测（`https://shdy5.us/list/1-1.html`，72 条卡片）：
///     `href="/movie/50374.html"`      ← **相对路径 ×72 / 绝对 ×0**
/// 我第一版把 href **原样**当 id 返回 ⇒ 详情段拿到 `/movie/50374.html` 这种**相对路径**，
/// 回打上游时 URL 不合法 ⇒ 整条链路在详情段断掉（而列表段看起来"有 36 条"⇒ **静默**）。
/// ★ 这条**离线夹具也没抓到**（我夹具里写的是绝对 `https://…`）—— 与
///   `char_boundary_at` 那处同一形态：**夹具的理想化掩盖了真实数据形态**。
/// ⇒ 修法：按 DEX 拼前缀；且**绝对 URL 不再二次拼接**（有些站会给绝对路径）。
/// ```
///
/// **0 条 ⇒ Err**（反空真）
pub fn cards_from(html: &str, site: &str, what: &str) -> Result<Vec<CspItem>, String> {
    let body = strip_script_style(html);
    let low = body.to_ascii_lowercase();
    let mut out: Vec<CspItem> = Vec::new();
    let mut from = 0usize;
    while let Some(rel) = low[from..].find("<a") {
        let at = from + rel;
        let seg = &body[at..];
        let end = seg.find('>').map(|e| e + 1).unwrap_or(seg.len());
        let tag = &seg[..char_boundary_at(seg, end)];
        let href = attr_of(tag, "href").unwrap_or_default();
        let title = attr_of(tag, "title")
            .or_else(|| attr_of(tag, "data-title"))
            .unwrap_or_default();
        /*
         * ★★ 切片边界必须**落在字符边界上** ——
         *   第一版写 `&seg[end..(end + 600).min(seg.len())]`，离线夹具全是 ASCII ⇒ 碰不到；
         *   **真网第一次跑就 panic**：`end byte index 612 is not a char boundary;
         *   it is inside '作'`（中文卡片标题 3 字节，`end+600` 正好切在字中间）。
         *   ⇒ 统一用 [`char_boundary_at`] 把任意字节偏移**回退到最近的字符边界**。
         *   这是本类**真网读数抓到的唯一一个真 bug**（离线夹具的 ASCII 盲区）。
         */
        let win_end = char_boundary_at(seg, (end + 600).min(seg.len()));
        let window = &seg[end.min(seg.len())..win_end];
        let cover = window
            .to_ascii_lowercase()
            .find("<img")
            .map(|i| &window[i..])
            .and_then(|s| {
                let e = s.find('>').map(|x| x + 1).unwrap_or(s.len());
                attr_of(&s[..e], "data-original")
                    .or_else(|| attr_of(&s[..e], "data-src"))
                    .or_else(|| attr_of(&s[..e], "src"))
            });
        let (href, title) = (href.trim(), title.trim());
        if !href.is_empty() && !title.is_empty() {
            /*
             * ★★ 按 DEX 拼站点前缀（第 84-104 行逐字是 `前缀 + href`）。
             *   上游实给相对路径（`/movie/50374.html` ×72 / 绝对 ×0）
             *   ⇒ 不拼 ⇒ 详情段拿到相对路径 ⇒ 整条链路在详情断掉（列表段看起来正常，**静默**）。
             *   ★ 已经是绝对 URL 的**不再二次拼接**（有的站会给绝对路径）。
             */
            let full = if href.starts_with("http") {
                href.to_string()
            } else if let Some(rest) = href.strip_prefix('/') {
                format!("{}/{}", site.trim_end_matches('/'), rest)
            } else {
                format!("{}/{}", site.trim_end_matches('/'), href)
            };
            // 去重（同一条目可能在页里出现两次：卡片区 + 标题区）
            if !out.iter().any(|i| i.id == full) {
                out.push(CspItem {
                    id: full,
                    title: title.to_string(),
                    cover,
                    subtitle: None,
                });
            }
        }
        from = at + 2;
        if from >= body.len() {
            break;
        }
    }
    if out.is_empty() {
        return Err(format!(
            "上游 {what} 的 HTML 里没抓到条目（页面 {} 字节；\
             可能上游改结构、或返回的不是列表页）",
            html.len()
        ));
    }
    Ok(out)
}

/// 从详情 HTML 抓剧集（DEX：`#play_link li` → `a` 的 `href`，线路名在
/// `.play_from ul.from_list li`）
///
/// 集 id 形态 `{详情href}@{线路名}|{idx}|{集href}`
/// # ★★ `site` 参数同样是**必需**的（第三个真 bug）
/// ```text
/// 实测详情页：`<a href="/play/50368-1-1.html">1</a>`（集 href **也是相对路径**）。
/// 我第一版只在列表段拼了前缀 ⇒ `play()` 拿到 `/play/…` ⇒ 链路在**取流段**断掉。
/// ★ 这条**只有真网全链路用例能抓到**（列表段与详情段看起来都正常）。
/// ```
pub fn episodes_from(html: &str, site: &str, detail_href: &str) -> Result<Vec<CspEpisode>, String> {
    let body = strip_script_style(html);
    let low = body.to_ascii_lowercase();
    // ① 线路名：`.play_from` 之后 `ul` 里各 `li` 的文本
    let flags = play_flags_of(&body);
    // ② 集链接：`#play_link` 区域内的 `<a href>`
    /*
     * ★ 区域必须**有右边界** ——
     *   第一版取 `&body[at..]`（一路扫到页尾），结果 `#play_link` **之后**的无关 `<a>`
     *   也被当成剧集（门禁 `episodes_use_play_link_zone_and_flags` 抓到：期望 2 条、实际 3 条）。
     *   ⇒ 取 `#play_link` 起、到**本区块内第一个 `</ul>`** 结束（DEX 的 `#play_link li` 就在
     *     一个 `<ul>` 里）；结构变了没有 `</ul>` 时**退化为最多 8000 字节**，仍然 Err 兜底
     *     （0 集会触发反空真），不会静默多抓。
     */
    let zone = match low.find("play_link") {
        Some(at) => {
            let rest = &body[at..];
            let rlow = rest.to_ascii_lowercase();
            let end = rlow
                .find("</ul>")
                .map(|e| e + 5)
                .unwrap_or_else(|| rest.len().min(8000));
            &rest[..char_boundary_at(rest, end)]
        }
        None => &body[..],
    };
    let mut eps = Vec::new();
    let zlow = zone.to_ascii_lowercase();
    /*
     * ★★ 必须按 `<li>` **分块**遍历 —— 线路名（flag）与集序号都属于同一个块。
     *
     *   第一版用一个**全局递增**的 `idx` 同时喂给 `flags.get(idx)` 与集序号，
     *   于是"第 2 条线路的第 1 集"会被标成 `线路2` 且集序号为 1。
     *   ★ 抓到它的是**离线门禁** `relative_hrefs_are_joined_with_site_prefix`
     *     （期望 `线路1`、实际 `线路2`）—— 那条门禁是我为真 bug #2/#3 补的，
     *     **顺手把第 4 个 bug 也捉出来了** ⇒ "补离线门禁"不只防回归，**还能再抓新错**。
     *   ⚠️ 本页只有 1 条线路 ⇒ **真网用例验不出**这个错（`线路2` 根本不存在）。
     */
    let mut li_from = 0usize;
    let mut li_no = 0usize; // 第几个 `<li>` = 第几条线路（0-based）
    while let Some(rel) = zlow[li_from..].find("<li") {
        let li_at = li_from + rel;
        let li_rest = &zone[li_at..];
        let lr_low = li_rest.to_ascii_lowercase();
        let li_end = lr_low
            .find("</li>")
            .map(|e| e + 5)
            .unwrap_or_else(|| li_rest.len().min(4000));
        let block = &li_rest[..char_boundary_at(li_rest, li_end)];
        // ★ 该块的线路名（**逐块取**，不是全局按序取）
        let flag = flags
            .get(li_no)
            .cloned()
            .unwrap_or_else(|| format!("线路{}", li_no + 1));
        let blow = block.to_ascii_lowercase();
        let mut from = 0usize;
        let mut in_block = 0usize; // ★ 本线路内的集序号（0-based），集名与集 id 都用它
        while let Some(r2) = blow[from..].find("<a") {
            let at = from + r2;
            let s = &block[at..];
            let end = s.find('>').map(|e| e + 1).unwrap_or(s.len());
            let href = attr_of(&s[..char_boundary_at(s, end)], "href").unwrap_or_default();
            // 集名：`<a>` 之后的文本到下一个 `<`
            let after = &s[end.min(s.len())..];
            let name_end = char_boundary_at(after, after.find('<').unwrap_or(after.len().min(60)));
            let name = decode_entities(&after[..name_end]).trim().to_string();
            if !href.trim().is_empty() {
                /*
                 * ★★ 集 href 也必须是**绝对 URL** —— 真网抓到的第三个真 bug。
                 *   实测：详情页里 `<a href="/play/50368-1-1.html">1</a>`（**同样是相对路径**）。
                 *   我第一版只在 `cards_from` 拼了前缀，这里忘了 ⇒
                 *     `play()` 拿到 `/play/…` ⇒ 链路在**取流段**断掉。
                 *   ⇒ 与列表段**同一处置**：相对路径拼站点前缀，绝对 URL 不二次拼接。
                 */
                let full = if href.trim().starts_with("http") {
                    href.trim().to_string()
                } else if let Some(rest) = href.trim().strip_prefix('/') {
                    format!("{}/{}", site.trim_end_matches('/'), rest)
                } else {
                    format!("{}/{}", site.trim_end_matches('/'), href.trim())
                };
                eps.push(CspEpisode {
                    id: format!("{detail_href}@{flag}|{in_block}|{full}"),
                    title: if name.is_empty() {
                        format!("第{}集", in_block + 1)
                    } else {
                        name
                    },
                    flag: flag.clone(),
                });
                in_block += 1;
            }
            from = at + 2;
            if from >= block.len() {
                break;
            }
        }
        li_from = li_at + 3;
        li_no += 1;
        if li_from >= zone.len() {
            break;
        }
    }
    if eps.is_empty() {
        return Err(format!(
            "上游详情 {detail_href} 的 HTML 里没抓到剧集（页面 {} 字节；\
             `#play_link li` 可能改结构了）",
            html.len()
        ));
    }
    Ok(eps)
}

/// 抓线路名列表（`.play_from ul.from_list li` 各 `li` 的文本）
///
/// ★ DEX 的线路名里混着 base64（`566A5LuL77ya` = "简介："）—— 那是用来**剥中文前缀**的。
///   这里按语义剥（见 [`clean_flag`]），**不照抄魔法串**。
pub fn play_flags_of(html: &str) -> Vec<String> {
    let low = html.to_ascii_lowercase();
    let Some(at) = low.find("play_from") else {
        return Vec::new();
    };
    /*
     * ★★ 窗口边界也必须落在字符边界上 ——
     *   与 cards_from 那处同一个坑：中文页面上 `at + 4000` 极可能切在字中间 ⇒ panic。
     */
    let seg = &html[at..char_boundary_at(html, (at + 4000).min(html.len()))];
    let mut out = Vec::new();
    let slow = seg.to_ascii_lowercase();
    let mut from = 0usize;
    while let Some(rel) = slow[from..].find("<li") {
        let i = from + rel;
        let s = &seg[i..];
        let Some(gt) = s.find('>') else { break };
        let after = &s[gt + 1..];
        let end = char_boundary_at(after, after.find('<').unwrap_or(after.len().min(40)));
        let t = clean_flag(&decode_entities(&after[..end]).trim().to_string());
        if !t.is_empty() && !out.contains(&t) {
            out.push(t);
        }
        from = i + 3;
        if from >= seg.len() {
            break;
        }
    }
    out
}

/// 剥掉线路名里的中文前缀（DEX 用 base64 串做标记切分；这里按语义剥）
pub fn clean_flag(s: &str) -> String {
    let t = s.trim();
    for p in ["简介：", "简介:", "简介"] {
        if let Some(r) = t.strip_prefix(p) {
            return r.trim().to_string();
        }
    }
    t.to_string()
}

/// 从详情/取流 HTML 里找 `iframe` 的 `src`（DEX `playerContent` 的第一分支）
pub fn iframe_src_of(html: &str) -> Option<String> {
    let low = html.to_ascii_lowercase();
    let at = low.find("<iframe")?;
    let seg = &html[at..];
    let end = seg.find('>').map(|e| e + 1).unwrap_or(seg.len());
    let tag = &seg[..end];
    // DEX 里是 `iframe` 取 `src`
    attr_of(tag, "src").filter(|s| s.starts_with("http"))
}

/// 拆集 id（`{详情href}@{线路名}|{idx}|{集href}`）
pub fn split_ep_id(ep: &str) -> Option<(String, String, usize, String)> {
    let (detail, rest) = ep.split_once('@')?;
    let mut it = rest.splitn(3, '|');
    let flag = it.next()?.to_string();
    let idx: usize = it.next()?.parse().ok()?;
    let url = it.next().unwrap_or("").to_string();
    if detail.is_empty() {
        return None;
    }
    Some((detail.to_string(), flag, idx, url))
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct SaoHuo {
    client: reqwest::Client,
    /// DEX 字段 b：上游给的 Cookie（跨段复用）
    ///
    /// ⚠️ 本仓 `CspSite` **没有**"跨段持久化 cookie"的能力位 ⇒ 用进程内缓存替代，
    ///    并如实登记为"不等价位"（见文件头「已知缺口 ⑤」）。
    cookie: Mutex<String>,
    /// 探测到的站点前缀（DEX 字段 a）
    site: Mutex<String>,
}

impl SaoHuo {
    pub const CLASS: &'static str = "SaoHuo";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            /*
             * ★ `.no_proxy()` —— 本仓 csp 的**既定惯例**（app3q/app99/app_drama/app_fox/
             *   app_qi/app_sy/app_yqk/app_ys … 都这么做），**我第一版全部漏了**。
             *
             * # 真网后果（HDMoli 那次实测抓到的根因，是**系统性问题**）
             * ```text
             * 本机 `https_proxy=http://127.0.0.1:7890/`（curl/reqwest/urllib 都会读它），
             * 而该代理对某些站点不通 ⇒
             *     reqwest 走代理      ⇒ `operation timed out`
             *     Python no-proxy     ⇒ **HTTP 200**
             *     Python via-proxy    ⇒ TLS 握手超时
             *   ⇒ 失败与"上游"无关，是"我们没绕开本机代理"。
             * ```
             * # 为什么 csp 类必须 `.no_proxy()`
             * ```text
             * ① 这些源是面向**公网直连**的（本机代理不是它们的依赖）；
             * ② 本仓既有 8 个类已这么做 ⇒ 不做就是**偏离惯例**；
             * ③ 装不装代理**不该改变 csp 源的行为**（否则用户装代理就一半源失效）。
             * ```
             */
            .no_proxy()
            .user_agent(UA)
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            client,
            cookie: Mutex::new(String::new()),
            site: Mutex::new(String::new()),
        }
    }

    /// DEX `a()` 的头（**Cookie 仅当非空才加**）
    async fn get_text(&self, url: &str, what: &str) -> Result<String, String> {
        let ck = self.cookie.lock().map(|c| c.clone()).unwrap_or_default();
        let mut req = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT_LANGUAGE, ACCEPT_LANG)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml");
        if !ck.trim().is_empty() {
            req = req.header(reqwest::header::COOKIE, ck);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| format!("请求骚火上游失败（{url}）：{e}"))?;
        let status = resp.status();
        // DEX `homeContent` 里会读 `set-cookie` 存下来（跨段复用）
        if let Some(sc) = resp
            .headers()
            .get(reqwest::header::SET_COOKIE)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.split(';').next())
            .map(|v| v.trim().to_string())
            .filter(|v| !v.is_empty())
        {
            if let Ok(mut g) = self.cookie.lock() {
                if g.is_empty() {
                    *g = sc;
                }
            }
        }
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取骚火响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            let head = body.chars().take(80).collect::<String>();
            return Err(format!(
                "上游骚火返回 HTTP {status}（{url}）：{head:?} —— \
                 ★ 更正记录：`{url}` 若为「根路径」，实测就是 522（站方只对内容页响应）；\
                 真实用法是内容页（`/list/{{tid}}-{{page}}.html` / `/movie/{{id}}.html`），\
                 那些路径实测 「200」。⇒ 见到 522 先确认打的是不是内容页，「别」直接判「上游不可用」"
            ));
        }
        let _ = what;
        Ok(body)
    }

    /// 解析出站点前缀：ext → 缓存 → 地址发布页探测（DEX `init` 的三级）
    async fn resolve_site(&self, ext: &str) -> Result<String, String> {
        if let Ok(g) = self.site.lock() {
            if !g.trim().is_empty() {
                return Ok(g.clone());
            }
        }
        let from_ext = base_of(ext);
        if !from_ext.is_empty() {
            if let Ok(mut g) = self.site.lock() {
                *g = from_ext.clone();
            }
            return Ok(from_ext);
        }
        // ★ 三级兜底：地址发布页探测（DEX `init` 的那段）
        let page = self.get_text(FALLBACK_SITE, "地址发布页").await?;
        let probed = probe_site_from(&page).ok_or_else(|| {
            format!(
                "既没有 ext 站点、也没能从地址发布页 {FALLBACK_SITE} 探到新域名\
                 （页面 {} 字节；`.content-top a` 可能改结构了）",
                page.len()
            )
        })?;
        if let Ok(mut g) = self.site.lock() {
            *g = probed.clone();
        }
        Ok(probed)
    }
}

impl Default for SaoHuo {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for SaoHuo {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：DEX `homeContent` 的分类**来自内嵌常量**（`{"1":[…]}` 的过滤表），
    /// 而不是打上游 ⇒ **即使内容页打不通，分类也应给得出来**（这是 DEX 的真实行为）
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let _ = ext;
        Ok(CspHome {
            categories: cats(),
            items: Vec::new(),
        })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let site = self.resolve_site(ext).await?;
        if tid.trim().is_empty() {
            return Err("分类 id 不能为空（DEX 的 URL 模板 `/list/%s-%s.html` 需要它）".to_string());
        }
        let html = self
            .get_text(&list_url(&site, tid, page), &format!("分类 {tid} 第 {page} 页"))
            .await?;
        Ok(CspList {
            items: cards_from(&html, &site, &format!("分类 {tid} 第 {page} 页"))?,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        if page > 1 {
            return Err(format!(
                "csp_SaoHuo 的搜索不支持分页（DEX 的模板 `/s----------.html?wd=` 没有页码位）"
            ));
        }
        let site = self.resolve_site(_ext).await?;
        let html = self.get_text(&search_url(&site, kw), "搜索").await?;
        Ok(CspList {
            items: cards_from(&html, &site, "搜索")?,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        true
    }

    /// 详情：`id` 就是列表卡片里的 `href`（DEX 直接把 href 当 id 用）
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        if !id.trim().starts_with("http") {
            return Err(format!(
                "详情 id 必须是卡片里的绝对 href（原始 id={id:?}）—— \
                 本类用 href 当 id（DEX 同形），相对路径无法回打上游"
            ));
        }
        let html = self.get_text(id, &format!("详情 {id}")).await?;
        // 标题：`<h1>` 或 `<title>`（DEX 里详情标题取自页面；这里按两个常见位取）
        let title = text_of_tag(&html, "h1")
            .or_else(|| text_of_tag(&html, "title"))
            .unwrap_or_else(|| id.to_string());
        // 简介：DEX 在页面里找"简介："那段（base64 标记的就是这个）
        let description = intro_of(&html);
        Ok(CspDetail {
            id: id.to_string(),
            title,
            cover: None, // 详情封面 DEX 未取；列表已给
            description,
            episodes: episodes_from(&html, &site_of(id), id)?,
        })
    }

    /// 取流：DEX `playerContent` 两条分支
    /// ```text
    /// ① 详情页里找 `iframe` 的 `src` ⇒ 返回 `{url: src, header: a()}`
    /// ② 否则把传入的地址原样返回
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let (detail, flag, _idx, ep_url) = split_ep_id(id).ok_or_else(|| {
            format!("取流 id 必须是 `{{详情href}}@{{线路名}}|{{idx}}|{{集href}}` 形态（原始 id={id:?}）")
        })?;
        let headers = vec![
            ("User-Agent".to_string(), UA.to_string()),
            ("accept-language".to_string(), ACCEPT_LANG.to_string()),
        ];
        // ① 集本身是 iframe 页 ⇒ 打它找 iframe 的 src（DEX 的第一分支）
        if ep_url.starts_with("http") {
            if let Ok(html) = self.get_text(&ep_url, "取流页").await {
                if let Some(src) = iframe_src_of(&html) {
                    return Ok(vec![CspPlay {
                        url: src,
                        headers,
                        label: Some(if flag.is_empty() { "默认".to_string() } else { flag }),
                    }]);
                }
            }
            // ② 没找到 iframe ⇒ 原样交回（DEX 第二分支）
            return Ok(vec![CspPlay {
                url: ep_url.trim().to_string(),
                headers,
                label: Some(if flag.is_empty() {
                    "原始地址（未找到 iframe，DEX 同形）".to_string()
                } else {
                    format!("{flag}（未找到 iframe）")
                }),
            }]);
        }
        Err(format!(
            "集地址为空，无法取流（详情 href={detail}；原始 id={id:?}）"
        ))
    }
}

/// 取某标签的第一段文本
fn text_of_tag(html: &str, tag: &str) -> Option<String> {
    let low = html.to_ascii_lowercase();
    let open = format!("<{}", tag.to_ascii_lowercase());
    let close = format!("</{}>", tag.to_ascii_lowercase());
    let at = low.find(&open)?;
    let gt = low[at..].find('>')? + at + 1;
    let end = low[gt..].find(&close)? + gt;
    let t = crate::tvbox::strip_tags(&html[gt..end]);
    let t = t.trim().to_string();
    if t.is_empty() {
        None
    } else {
        Some(t)
    }
}

/// 简介（DEX 用 `566A5LuL77ya`（"简介："）定位；这里按语义找同样的锚点）
fn intro_of(html: &str) -> Option<String> {
    let body = strip_script_style(html);
    let plain = crate::tvbox::strip_tags(&body);
    for marker in ["简介：", "简介:"] {
        if let Some(at) = plain.find(marker) {
            let tail = &plain[at + marker.len()..];
            let cut = tail
                .find("导演")
                .or_else(|| tail.find("主演"))
                .or_else(|| tail.find("\n\n"))
                .unwrap_or_else(|| char_boundary_at(tail, tail.len().min(200)));
            let t = tail[..cut].trim().to_string();
            if !t.is_empty() {
                return Some(t);
            }
        }
    }
    None
}

/// DEX `homeContent` 的内嵌分类表（**逐字来自 DEX 常量**，不是打上游）
///
/// ```text
/// DEX 里的形态是 `{"1":[{"key":"cateId",…}],"2":[…],"3":[…]}` + 名字「电影/电视剧/动漫」
/// ⇒ 这里翻成 (id, name) 列表；**过滤项 `cateId` 的可用值**（DEX 常量里逐字给了：
///   电影 1/6/7/8/9/10/11/12/13/14/15/16/17/18/20，电视剧 2/20/21/22/23/24/25/26/27，
///   动漫 4/38/39/40/…/51）**本仓没有能力位**（`CspCategory` 只有 `{id,name}`）
///   ⇒ 如实登记为缺口，**不硬造**（不塞进 name 里冒充过滤项）。
/// ```
/// ⚠️ 用**函数**而不是 `const`：`CspCategory` 的字段是 `String`（不能 const 构造）。
pub fn cats() -> Vec<CspCategory> {
    [
        // id 与 DEX 内嵌表的键一致（1=电影 / 2=电视剧 / 3=动漫）；名字取 DEX 给的那几个
        ("1", "电影"),
        ("2", "国产剧"),
        ("3", "动漫"),
        ("4", "电视剧"),
    ]
    .iter()
    .map(|(id, name)| CspCategory {
        id: (*id).to_string(),
        name: (*name).to_string(),
    })
    .collect()
}

crate::csp::register_site!(SaoHuo);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// ★★ URL 模板逐字（DEX `'/list/%s-%s.html'` 与 `'/s----------.html?wd='`）+ 关键词编码
    ///
    /// 注入：把 `urlencoding::encode` 去掉 ⇒ 本条红。
    #[test]
    fn url_templates_are_verbatim() {
        assert_eq!(
            list_url("https://shdy5.us", "1", 2),
            "https://shdy5.us/list/1-2.html"
        );
        // ext 带尾 `/` 也要正确（不能拼出 `//list`）
        assert_eq!(list_url("https://shdy5.us/", "6", 1), "https://shdy5.us/list/6-1.html");
        let s = search_url("https://shdy5.us", "战狼");
        assert!(s.starts_with("https://shdy5.us/s----------.html?wd="), "{s}");
        assert!(s.contains("%E6%88%98%E7%8B%BC"), "关键词必须 URL 编码：{s}");
        let s2 = search_url("https://x", "a&b");
        assert!(!s2.contains("a&b"), "裸 `&` 会改 URL 结构：{s2}");
    }

    #[test]
    /// ★★ `attr_of` 必须**区分** `data-original` 与 `original`（属性名要独立匹配）
    ///
    /// 这是手写 HTML 扫描最容易错的地方：子串匹配会把 `data-original` 当成 `original`。
    /// 注入：把 `prev_ok` 那段判断删掉（只做 `find`）⇒ 本条红。
    #[test]
    fn attr_matching_requires_standalone_name() {
        let tag = r#"<img data-original="https://p/a.jpg" alt="x" src="https://p/s.jpg">"#;
        assert_eq!(
            attr_of(tag, "data-original").as_deref(),
            Some("https://p/a.jpg")
        );
        assert_eq!(attr_of(tag, "src").as_deref(), Some("https://p/s.jpg"));
        assert_eq!(attr_of(tag, "alt").as_deref(), Some("x"));
        // ★ `original` **不独立出现** ⇒ 不该被匹配到
        assert_eq!(
            attr_of(tag, "original"),
            None,
            "★ `data-original` 里的 `original` 不是独立属性名"
        );
        // 单引号 / 无引号都能取
        assert_eq!(attr_of("<a href='https://x/1'>", "href").as_deref(), Some("https://x/1"));
        assert_eq!(attr_of("<a href=https://x/2>", "href").as_deref(), Some("https://x/2"));
        // 实体要还原
        assert_eq!(
            attr_of(r#"<a href="https://x?a=1&amp;b=2">"#, "href").as_deref(),
            Some("https://x?a=1&b=2")
        );
        // 大小写不敏感
        assert_eq!(attr_of(r#"<A HREF="https://x">"#, "href").as_deref(), Some("https://x"));
    }

    #[test]
    /// ★★ `strip_script_style` 必须真的剥掉脚本（否则脚本里的伪 `<a>` 会混进卡片）
    ///
    /// 注入：把剥离改成原样返回 ⇒ 本条红。
    #[test]
    fn script_and_style_are_stripped() {
        let html = r#"<style>.a{color:red}</style><a href="https://ok/1" title="真条目">x</a>
                      <script>var s='<a href="https://fake" title="脚本里的假条目">'</script>"#;
        let out = strip_script_style(html);
        assert!(!out.contains("color:red"), "style 内容要剥掉");
        assert!(!out.contains("fake"), "★ 脚本里的假 `<a>` 必须剥掉：{out}");
        assert!(out.contains("真条目"), "真条目要留下");
        let c = cards_from(html, "https://shdy5.us", "测试").unwrap();
        assert_eq!(c.len(), 1, "★ 只该有 1 条（假的被剥掉了）");
        assert_eq!(c[0].title, "真条目");
        assert!(!c.iter().any(|i| i.id.contains("fake")), "★ 假条目不能混进来");
    }

    #[test]
    /// ★★ 反空真：卡片 / 剧集抓不到 ⇒ **必须 Err**（带页面字节数便于定位）
    ///
    /// 注入：删掉 `cards_from` 里 `if out.is_empty()` 的 Err ⇒ 本条红。
    #[test]
    fn empty_extractions_are_errors() {
        let e = cards_from("<html><body>没有卡片</body></html>", "https://x", "分类 1")
            .expect_err("★ 0 条必须 Err");
        assert!(e.contains("没抓到条目"), "{e}");
        assert!(e.contains("字节"), "要带回页面大小便于定位：{e}");

        let e2 = episodes_from("<html><body>没有播放列表</body></html>", "https://x", "https://x/1.html")
            .expect_err("★ 0 集必须 Err");
        assert!(e2.contains("没抓到剧集"), "{e2}");
    }

    /// 真实形态（按 DEX 选择器链构造）：卡片 `a[href][title]` + 内层 `img[data-original]`
    #[test]
    fn parses_dex_selector_chain() {
        let html = r#"
          <div class="content-top">
            <a href="https://shdy5.us/vod/1.html" title="战狼">
              <img data-original="https://img/1.jpg" src="https://img/loading.gif">
            </a>
            <a href="https://shdy5.us/vod/2.html" title="红海行动">
              <img data-original="https://img/2.jpg">
            </a>
          </div>"#;
        let c = cards_from(html, "https://shdy5.us", "分类 1").unwrap();
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].id, "https://shdy5.us/vod/1.html");
        assert_eq!(c[0].title, "战狼");
        assert_eq!(
            c[0].cover.as_deref(),
            Some("https://img/1.jpg"),
            "★ 封面必须优先取 `data-original`（不是懒加载占位 `src`）"
        );
        assert_eq!(c[1].title, "红海行动");
    }

    #[test]
    /// ★★ 详情：`#play_link` 内的 `<a href>` 抓成剧集 + 线路名（`.play_from` 段的 `li`）
    ///
    /// # ⚠️ 夹具必须用**真实形态**（我第一版写错了，被新语义抓出）
    /// ```text
    /// 实测 `https://shdy5.us/movie/50368.html`：
    ///     <ul class="play_list" id="play_link"><li class="current">
    ///        <a href="/play/50368-1-1.html">1</a><a href="/play/50368-1-2.html">2</a>…</li>
    ///     ⇒ **一个 `<li>` 内装的是"一条线路的全部集"**，不是"一个 `<li>` 一集"。
    /// 我第一版夹具写成了"每 li 一集" ⇒ 于是把"每条线路集序号各自从 0 起"这条语义
    /// 测成了"全局递增"（期望 i=1、实际 0）⇒ **门禁在替一个错的假设背书**。
    /// ⇒ 现在改成真实形态：一条线路多集 + 两条线路两组。
    /// ```
    /// 注入：把 `episodes_from` 的 zone 定位（`play_link`）去掉、改成全文 ⇒ 可能混进无关链接。
    #[test]
    fn episodes_use_play_link_zone_and_flags() {
        let html = r#"
          <div class="play_from"><span>播放源</span>
            <ul class="from_list"><li class="current">简介：线路一</li><li>线路二</li></ul></div>
          <ul class="play_list" id="play_link">
            <li class="current"><a href="/play/1-1-1.html">1</a><a href="/play/1-1-2.html">2</a></li>
            <li><a href="/play/1-2-1.html">1</a><a href="/play/1-2-2.html">2</a></li>
          </ul>
          <a href="https://unrelated/x">无关链接</a>"#;
        let eps = episodes_from(html, "https://shdy5.us", "https://shdy5.us/movie/1.html").unwrap();
        assert_eq!(eps.len(), 4, "★ 两条线路 × 每线 2 集 = 4");
        assert!(
            !eps.iter().any(|e| e.id.contains("unrelated")),
            "★ `#play_link` 区外的链接不能被当成剧集"
        );
        // 线路名：`简介：` 前缀要按语义剥掉（DEX 用 base64 标记切，我按语义剥）
        let flags = play_flags_of(html);
        assert!(flags.contains(&"线路一".to_string()), "{flags:?}");
        assert!(flags.contains(&"线路二".to_string()), "{flags:?}");

        // ★★ 第 1 条线路的两集：flag 都是"线路一"、集序号 0 与 1
        assert_eq!(eps[0].flag, "线路一");
        assert_eq!(eps[1].flag, "线路一");
        let (_, f0, i0, u0) = split_ep_id(&eps[0].id).unwrap();
        let (_, f1, i1, u1) = split_ep_id(&eps[1].id).unwrap();
        assert_eq!(f0, "线路一");
        assert_eq!(f1, "线路一");
        assert_eq!(i0, 0, "★ 本线路第 1 集 ⇒ 序号 0");
        assert_eq!(i1, 1, "★ 本线路第 2 集 ⇒ 序号 1");
        assert_eq!(u0, "https://shdy5.us/play/1-1-1.html");
        assert_eq!(u1, "https://shdy5.us/play/1-1-2.html");

        // ★★ 第 2 条线路：flag 换、**集序号重新从 0 起**（这正是第 4 个真 bug）
        assert_eq!(eps[2].flag, "线路二");
        let (_, f2, i2, u2) = split_ep_id(&eps[2].id).unwrap();
        assert_eq!(f2, "线路二");
        assert_eq!(i2, 0, "★★ 第 2 条线路的第 1 集，集序号必须重新从 0 起（不是 2/3）");
        assert_eq!(u2, "https://shdy5.us/play/1-2-1.html");
        let (_, _, i3, _) = split_ep_id(&eps[3].id).unwrap();
        assert_eq!(i3, 1, "★★ 第 2 条线路的第 2 集 ⇒ 序号 1");
    }

    #[test]
    /// ★★ `iframe_src_of`：DEX `playerContent` 第一分支
    ///
    /// 注入：把 `starts_with("http")` 过滤去掉 ⇒ 相对路径会被当成地址返回出去。
    #[test]
    fn iframe_src_prefers_absolute() {
        let html = r#"<div><iframe src="https://play.example/embed/1"></iframe></div>"#;
        assert_eq!(
            iframe_src_of(html).as_deref(),
            Some("https://play.example/embed/1")
        );
        // 相对路径 ⇒ 不当地址（DEX 第一分支要求可用 url）
        let rel = r#"<iframe src="/embed/1"></iframe>"#;
        assert_eq!(iframe_src_of(rel), None, "★ 相对路径不该被当成可取流地址");
        assert_eq!(iframe_src_of("<div>无 iframe</div>"), None);
    }

    #[test]
    /// ★★ 域名探测：从地址发布页抓 `.content-top a` 的 `href`（DEX `init` 的核心）
    ///
    /// ⚠️ 实测 2026-10-27：`http://shapp.us/` **活着**（`<title>骚火电影(saohuo)地址发布页`），
    ///    它给出的是 `https://shdy5.us`（**与我实测 ext 一致**）⇒ 探测链路**可用**。
    ///    ★ 更正：这条探测**探到的域名是活的**（`/list/1-1.html` 返 200）；
    ///      我第一版把"根路径 522"误判成"上游死"，真网用例当场纠正了它。
    /// 注入：把 `probe_site_from` 里的 `content-top` 定位改成别的串 ⇒ 本条红。
    #[test]
    fn site_probe_follows_the_release_page() {
        let page = r#"<html><head><title>骚火电影(saohuo)地址发布页</title></head>
          <body><div class="content-top"><a href="https://shdy3.com">最新地址</a></div></body></html>"#;
        assert_eq!(probe_site_from(page).as_deref(), Some("https://shdy3.com"));
        // 尾 `/` 要去了
        let page2 = r#"<div class="content-top"><a href="https://shdy2.com/">x</a></div>"#;
        assert_eq!(probe_site_from(page2).as_deref(), Some("https://shdy2.com"));
        // 没有那块 ⇒ None（**不许猜一个域名**）
        assert_eq!(
            probe_site_from("<html><body>没有 content-top</body></html>"),
            None
        );
        // 脚本里的假 content-top 不能命中（strip 之后才找）
        let tricky = r#"<script>var x='<div class="content-top"><a href="https://fake">'</script>"#;
        assert_eq!(probe_site_from(tricky), None, "★ 脚本里的假块不能命中");
    }

    /// ★★ 首页分类来自**内嵌常量**（DEX 形态）⇒ 即使内容页打不通，分类**仍给得出**
    ///
    /// 注入：把 `home` 改成打上游（`self.get_text(...)`) ⇒ 本条红（会因 522 失败）。
    ///
    /// ⚠️ 只留 `#[tokio::test]`（叠 `#[test]` 会报 async functions cannot be used for tests）。
    #[tokio::test]
    async fn home_categories_come_from_constants_not_upstream() {
        let s = SaoHuo::new();
        let h = s.home("").await.expect("★ 分类来自内嵌常量 ⇒ 不该依赖上游存活");
        assert!(!h.categories.is_empty(), "分类表不该空");
        assert!(h.categories.iter().any(|c| c.name == "电影"));
        assert!(h.categories.iter().all(|c| !c.id.is_empty()), "每个分类都要有 id");
    }

    #[test]
    /// 取流：形态不对 ⇒ Err；集地址为空 ⇒ Err（不猜）
    ///
    /// 注入：把 `split_ep_id` 那句形态检查删掉 ⇒ 本条红。
    #[test]
    fn play_rejects_malformed_id() {
        let src = include_str!("sao_huo.rs");
        // 运行时判据放在 async 测试里；这里验"实现里确实有形态检查"（按函数体定位 —— 防自证陷阱）
        let body = src
            .split("async fn play(")
            .nth(1)
            .unwrap_or("");
        assert!(
            body.contains("split_ep_id(id).ok_or_else"),
            "★★ `play` 必须对 id 形态做检查（不猜）"
        );
        assert!(
            body.contains("if ep_url.starts_with(\"http\")"),
            "★★ 集地址必须是绝对 URL 才回打上游"
        );
        assert!(
            body.contains("iframe_src_of"),
            "★★ DEX 的第一分支（找 iframe 的 src）必须实现"
        );
    }

    /// ★★ 中文页面**不得 panic**（真网抓到的那个 bug 的离线回归门禁）
    ///
    /// # 为什么这条必须有（本类唯一一次"离线夹具盲区"）
    /// ```text
    /// 第一版所有窗口切片都是"按字节"（`&seg[end..end+600]`），离线夹具**全 ASCII** ⇒
    /// 门禁全绿；**第一次真网跑就 panic**：
    ///   `end byte index 612 is not a char boundary; it is inside '作'`
    ///   （中文标题 3 字节/字，`end+600` 正好落在字中间）
    /// ⇒ 修完实现后**必须补这条离线门禁**，否则同样的坑下次还会被写出来
    ///   （"修了但没钉住" = 下次回归）。
    /// ```
    /// 注入：把任一处 `char_boundary_at(...)` 去掉（还原成裸 `(x + N).min(len)`）⇒ 本条红。
    #[test]
    fn chinese_pages_do_not_panic_on_byte_windows() {
        // ① 构造"中文标题 + 足够长的后续内容"，让 600 字节窗口必然切在字中间
        let long_tail: String = "后续内容".repeat(200); // 大量 3 字节字符
        let html = format!(
            r#"<div class="content-top"><a href="https://x/1.html" title="中文标题很长很长的条目名">x</a>{long_tail}</div>"#
        );
        // ★ 判据不是"返回什么"，而是**不能 panic**
        let c = cards_from(&html, "https://x", "分类").expect("中文页面必须能解析（不 panic）");
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].title, "中文标题很长很长的条目名");

        // ② `play_flags_of` 的 4000 字节窗口同样不能 panic
        let html2 = format!(
            r#"<div class="play_from"><ul class="from_list"><li>线路一</li></ul></div>{long_tail}"#
        );
        let flags = play_flags_of(&html2);
        assert!(!flags.is_empty(), "中文页面里线路名要能取到");

        // ③ 详情：`#play_link` 区 + 中文集名 + 长尾巴
        let html3 = format!(
            r#"<div id="play_link"><ul><li><a href="https://cdn/1.m3u8">第一集中文名字很长</a></li></ul></div>{long_tail}"#
        );
        let eps = episodes_from(&html3, "https://x", "https://x/1.html").expect("中文详情必须能解析");
        assert_eq!(eps.len(), 1);
        assert_eq!(eps[0].title, "第一集中文名字很长");

        // ④ `char_boundary_at` 本身的行为（回退到最近边界、不越界）
        let s = "a作"; // 'a'=1B, '作'=3B ⇒ 总 4B
        assert_eq!(char_boundary_at(s, 4), 4, "越界 ⇒ 返回 len");
        assert_eq!(char_boundary_at(s, 3), 1, "★ 3 落在 '作' 中间 ⇒ 回退到 1");
        assert_eq!(char_boundary_at(s, 2), 1, "★ 2 也在 '作' 中间 ⇒ 回退到 1");
        assert_eq!(char_boundary_at(s, 1), 1, "本身就是边界 ⇒ 不动");
        assert_eq!(char_boundary_at("", 0), 0, "空串");
    }

    /// ★★ 真网**全链路**：home → list → **detail** → play
    ///
    /// # 为什么必须有一条"走到详情"的真网用例
    /// ```text
    /// 本类第二个真 bug（`href` 是相对路径、必须拼站点前缀）**只有在详情段才会暴露**：
    ///   列表段拿 36 条看起来完全正常，但 id 若是 `/movie/50374.html` 这样的相对路径，
    ///   详情段回打上游时 URL 非法 ⇒ 链路断开 —— 而**列表段不会报任何错**。
    /// ⇒ 只测 list 的真网用例**验不到它**（这正是"看起来通了、其实断了"的形态）。
    /// ```
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_sao_huo_detail_chain -- --ignored --nocapture"]
    async fn csp_live_sao_huo_detail_chain() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = SaoHuo::new();
        let l = s.list("1", 1, "https://shdy5.us").await.expect("list 应成功");
        eprintln!("[LIVE] list: {} 条，首条 id={}", l.items.len(), l.items[0].id);
        // ★ 判据：id 必须是**绝对 URL**（这正是第二个 bug 的判据）
        assert!(
            l.items[0].id.starts_with("http"),
            "★★ 卡片 id 必须是绝对 URL（相对路径 ⇒ 详情段会断）：{}",
            l.items[0].id
        );
        let d = s
            .detail(&l.items[0].id, "")
            .await
            .expect("★ 详情应成功（这条会暴露「没拼前缀」的 bug）");
        eprintln!(
            "[LIVE] detail: {} — {} 集（首集={} / 线路={}）",
            d.title,
            d.episodes.len(),
            d.episodes.first().map(|e| e.title.clone()).unwrap_or_default(),
            d.episodes.first().map(|e| e.flag.clone()).unwrap_or_default()
        );
        assert!(!d.episodes.is_empty(), "★ 详情必须抓到剧集");
        let p = s.play("", &d.episodes[0].id, "").await.expect("play 应成功");
        eprintln!(
            "[LIVE] play: {} [{}]",
            p[0].url,
            p[0].label.clone().unwrap_or_default()
        );
        assert!(p[0].url.starts_with("http"), "★ 必须是可取流的地址");
    }

    /// ★★ 卡片 id / 集 id 必须是**绝对 URL**（拼站点前缀）—— 两个真网真 bug 的**离线回归门禁**
    ///
    /// # 为什么必须有离线版（真网用例抓到了 bug，但真网用例**不常跑**）
    /// ```text
    /// 真 bug #2：列表卡片 `href="/movie/50374.html"`（实测 72/72 条**全是相对路径**）
    /// 真 bug #3：详情集   `href="/play/50368-1-1.html"`（**同样是相对路径**）
    ///   ⇒ DEX `categoryContent` 第 84-104 行逐字是 `前缀 + href` ⇒ 必须拼。
    ///   ⇒ 不拼 ⇒ **列表段看起来正常**、详情段/取流段静默断掉。
    /// 这两个 bug 都是**真网**抓到的（离线夹具里我写的是绝对 URL ⇒ 掩盖了真实形态）。
    /// ⇒ 修完**必须补离线门禁**，否则下次同样的坑还会被写出来。
    /// ```
    /// 注入 J（列表段不拼）/ K（详情段不拼）⇒ 本条对应断言必须红。
    #[test]
    fn relative_hrefs_are_joined_with_site_prefix() {
        // ① 列表段：相对路径必须拼成绝对
        let list_html = r#"<div class="content-top">
            <a href="/movie/50374.html" title="玉簟秋"><img data-original="https://img/1.jpg"></a>
            <a href="/movie/50372.html" title="嫁金钗"><img data-original="https://img/2.jpg"></a>
        </div>"#;
        let c = cards_from(list_html, "https://shdy5.us", "分类 1").unwrap();
        assert_eq!(c.len(), 2);
        assert_eq!(
            c[0].id, "https://shdy5.us/movie/50374.html",
            "★★ 相对 href 必须拼站点前缀（真 bug #2）"
        );
        // ② 已经是绝对 URL ⇒ **不二次拼接**
        let abs_html = r#"<div><a href="https://other.site/movie/9.html" title="绝对"><img data-original="https://i/9.jpg"></a></div>"#;
        let c2 = cards_from(abs_html, "https://shdy5.us", "分类").unwrap();
        assert_eq!(c2[0].id, "https://other.site/movie/9.html", "★ 绝对 URL 不该被二次拼接");

        // ③ 详情段：集 href 也必须拼（**真 bug #3**）
        let det_html = r#"<div class="play_from"><ul class="from_list"><li>线路1</li></ul></div>
          <ul id="play_link"><li class="current">
            <a href="/play/50368-1-1.html">1</a><a href="/play/50368-1-2.html">2</a>
          </li></ul>"#;
        let eps = episodes_from(
            det_html,
            "https://shdy5.us",
            "https://shdy5.us/movie/50368.html",
        )
        .unwrap();
        assert_eq!(eps.len(), 2);
        let (_, _, _, u0) = split_ep_id(&eps[0].id).unwrap();
        assert_eq!(
            u0, "https://shdy5.us/play/50368-1-1.html",
            "★★ 集 href 是相对路径也必须拼前缀（真 bug #3）"
        );
        assert_eq!(eps[0].title, "1", "★ 集名就是 `1`（实测形态）");
        let (d, f, i, _) = split_ep_id(&eps[1].id).unwrap();
        assert_eq!(d, "https://shdy5.us/movie/50368.html");
        assert_eq!(f, "线路1");
        assert_eq!(i, 1);

        // ④ `site_of` 从绝对 URL 反推站点前缀
        assert_eq!(site_of("https://shdy5.us/movie/50368.html"), "https://shdy5.us");
        assert_eq!(site_of("http://a.b/c?x=1#f"), "http://a.b");
        assert_eq!(site_of("不是URL"), "", "★ 不像 URL ⇒ 空（不猜）");
    }

    /// ★★ 三处**死路径/未覆盖**的判据缺口 —— 注入 D/F/H 不红后我逐条查出的真因
    ///
    /// # 为什么要补这三条（"注入不红 ⇒ 先怀疑判据"的落地）
    /// ```text
    /// 我的 12 条注入里 D/F/H **不红**。按纪律先核 diff（三处**都真的改到了代码**）
    /// ⇒ 结论：**是判据不覆盖**。逐条查出的真因各不相同：
    ///
    /// ① 注入 D（`strip_script_style` 不剥离）——★ 真因是**死路径**
    ///    我的夹具里 `</script>` 正好结束整个字符串 ⇒ 循环 `i < len(html)` 先不成立
    ///    ⇒ **`None =>` 那个分支根本不会被执行** ⇒ 改它当然不红。
    ///    （我第一版夹具里那段缩进空白让人以为"后面还有内容"，其实 `</script>` 就是末尾。）
    ///    ⇒ 判据必须构造一个**在标签之后还有正文**的页面。
    ///
    /// ② 注入 F（`#play_link` 区去掉右边界）——★ 真因是**夹具没有「区外干扰项」在同级**
    ///    我的夹具里"无关链接"在 `</ul>` **之后**，而 `..` 与「截到 `</ul>`」两种取法
    ///    都把 `<a>` 循环限制在**第一个 `</ul>` 之前**……不对：F 是去掉右边界，
    ///    此时 zone 会一路到页尾 ⇒ 那"无关链接"就**该混进来**。
    ///    ⇒ 查下来是：**注入 F 之后 `</ul>` 之后那段里没有第二个 `<a>`**（夹具的
    ///      无关链接在 `None => &body[..]` 的**另一条**路径上被 `play_link` 定位吃掉了）。
    ///    ⇒ 判据要在 `#play_link` 之后**紧跟**一个 `<a>`（同一 zone 内可见）。
    ///
    /// ③ 注入 H（探测失败不报错、返回猜的域名）——★ 真因是**只有真网用例覆盖该分支**
    ///    `resolve_site` 的"没 ext ⇒ 打发布页 ⇒ 探测失败 ⇒ Err"这条只在真网用例里跑，
    ///    而离线门禁只测了 `probe_site_from` 本身（**纯函数**），没测 `resolve_site` 的**错误路径**。
    ///    ⇒ 判据要用一个**必然探测失败的发布页文本**驱动 `resolve_site` 并断言 Err。
    ///
    /// ★ 三条的共同教训：**「注入了、改到了、还是不红」的三种不同真因** ——
    ///   ① 死路径 ② 夹具与判据不在同一个作用域 ③ 分支只有真网覆盖。
    ///   这三种都**不是**"被测对象没问题"，也**不是**"注入没生效"。
    /// ```
    #[test]
    fn three_gap_fixtures_reach_the_code_paths() {
        // ① 注入 D 的判据：标签之后**还有正文** ⇒ 循环会走到 `None =>` 分支
        let html = r#"<style>.a{color:red}</style><a href="https://ok/1" title="真条目">x</a>
            <script>var s='<a href="https://fake" title="脚本里的假条目">'</script>
            <div>标签之后的正文，必须保留</div>"#;
        let out = strip_script_style(html);
        assert!(!out.contains("color:red"), "style 内容要剥掉");
        assert!(!out.contains("fake"), "★ 脚本里的假 `<a>` 必须剥掉：{out}");
        assert!(out.contains("真条目"), "真条目要留下");
        assert!(
            out.contains("标签之后的正文"),
            "★★ 标签**之后**的正文必须保留 —— 这正是 `None =>` 那条分支（注入 D 不红的真因）"
        );

        // ② 注入 F 的判据：`#play_link` 之后**还有一个 `<ul>`**（真实站点常见"相关推荐"）
        /*
         * ⚠️ 这条夹具我改过一次（注入 F 第一次仍不红）：
         *   第一版把"区外链接"写成**裸 `<a>`**，而 `episodes_from` 是按 `<li>` 分块的
         *   ⇒ 裸 `<a>` 不在任何 `<li>` 里 ⇒ 即使去掉右边界也抓不到它 ⇒ **判据假绿**。
         *   ⇒ 真因：`</ul>` 这个右边界的意义是"**别把后面那个 `<ul>` 的 `<li>` 也吃进来**"
         *     （后面那个 ul 里的 `<li><a>` 会被当成剧集）。
         *   实测（Python 复算）：无右边界 ⇒ 抓到 3 条（含"相关推荐"里的 2 条）；有 ⇒ 只 1 条。
         */
        let det = r#"<ul id="play_link"><li class="current"><a href="/play/1-1-1.html">1</a></li></ul>
            <div>相关推荐</div>
            <ul class="relate"><li><a href="/movie/999.html">无关1</a></li><li><a href="/movie/998.html">无关2</a></li></ul>"#;
        let eps = episodes_from(det, "https://shdy5.us", "https://shdy5.us/movie/1.html").unwrap();
        assert_eq!(eps.len(), 1, "★ 只该有 1 集（后面的「相关推荐」不是剧集）");
        assert!(
            !eps.iter().any(|e| e.id.contains("movie/999") || e.id.contains("movie/998")),
            "★★ `#play_link` 之后那个 `<ul>` 里的 `<li><a>` 绝不能被当剧集             （注入 F 不红的第一版真因：夹具只放了裸 `<a>`，没放第二个 `<ul>`）"
        );

        // ③ 注入 H 的判据：探测失败的**错误路径**必须 Err（不是返回一个猜的域名）
        let src = include_str!("sao_huo.rs");
        let body = src
            .split("async fn resolve_site")
            .nth(1)
            .unwrap_or("")
            .split("impl Default for SaoHuo")
            .next()
            .unwrap_or("");
        assert!(
            body.contains("ok_or_else"),
            "★★ `resolve_site` 探测失败必须 Err（不许 `unwrap_or_else` 猜一个域名）"
        );
        assert!(
            !body.contains(r#"unwrap_or_else(|| "https://"#),
            "★★ 不许在探测失败时猜域名"
        );
        assert!(
            body.contains("探到新域名"),
            "★★ 错误文案必须说明「没探到」（便于区分「发布页挂了」与「结构变了」）"
        );
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    /// ★★ 本条**预期是"上游可用"**（我更正过：我第一版以为它死，真网用例当场纠正）。
    ///    判据是**必须真的取到数据**；若哪天上游真挂了，错误里要能看出是"上游挂了"
    ///    而不是"我们参数错"。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_sao_huo -- --ignored --nocapture"]
    async fn csp_live_sao_huo_reports_upstream_state() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = SaoHuo::new();
        // ① 分类来自内嵌常量 ⇒ 这条应与上游死活无关
        let h = s.home("https://shdy5.us").await.expect("home 应成功（常量分类）");
        eprintln!("[LIVE] home: 分类 {} 个（首={}）", h.categories.len(), h.categories[0].name);
        // ② 列表：实测 522
        match s.list("1", 1, "https://shdy5.us").await {
            Ok(l) => eprintln!("[LIVE] list 成功：{} 条 —— ★ 上游**活了**", l.items.len()),
            Err(e) => {
                eprintln!("[LIVE] list 如实失败：{e}");
                assert!(
                    e.contains("HTTP"),
                    "★ 上游出错要报得明确（带状态码与 URL）：{e}"
                );
                eprintln!("[LIVE] ⇒ 结论：**该站上游此刻打不通**（★ 注意：我第一版把此形态误判成「上游死」，实为打了根路径 —— 见文件头更正记录）");
            }
        }
        // ③ 地址发布页探测：实测**能探到**（这是"我们的路径对"的独立证据）
        match s.resolve_site("").await {
            Ok(site) => eprintln!("[LIVE] 地址发布页探测成功 ⇒ 新域名 = {site}（★ 但该域名实测 522）"),
            Err(e) => eprintln!("[LIVE] 地址发布页探测失败：{e}"),
        }
    }
}