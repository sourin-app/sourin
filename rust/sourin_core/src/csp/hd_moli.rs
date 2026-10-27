// ═══════════════════════════════════════════════════════════════════════
//  csp_HDMoli —— TVBox `csp_HDMoli` 的 Rust 重写（「HDmoli」网盘搜索型）
// ═══════════════════════════════════════════════════════════════════════
//
// # 名字说明（★ 卡面写错过）
// ```text
// 任务卡面原本写的是 `csp_HdMoli`，但**真实订阅与 DEX 里都是 `HDMoli`**（大写 HDM）。
// ⇒ 已与 Lead 确认（"你对，卡面写错了"）⇒ 本类以 **`HDMoli`** 注册。
// （DEX 里的类名逐字：`com.github.catvod.spider.HDMoli`）
// ```
//
// # 这个类在配置里覆盖什么
// ```json
// {"key":"HDmoli","name":"📺HDmoli","type":3,"api":"csp_HDMoli",
//  "searchable":1,"quickSearch":1,"filterable":1}
// ```
// ⇒ **没有 ext**：站点写死 `https://www.hdmoli.com`。
//
// # ★★★ 分档：**上游完全可用 —— 真网四段已打通**（2026-10-27 实测）
//
// ## ★★ 先说**第三个"我差点判错"的形态**（本类遇到的与前两类都不同）
// ```text
// 第一版：我用 `curl -L` 打 `https://www.hdmoli.com/` 与 `/mlist/index1.html`
//   ⇒ **全部 `000`（连接超时 25s）**
//   ⇒ 看起来"站点连不上"。**但那不是站点的问题，是我这台机器上 curl 与它的握手有问题。**
//
// 逐层取证（★ 这就是 Lead 要的"反面/正面证据"）：
//   ① DNS     ：`www.hdmoli.com` → `104.18.42.88` / `104.18.34.88`（Cloudflare）
//                CNAME 链：cdn.54856565.xyz → cdn.sozhile.com → cloudflare.seeck.cn
//   ② 裸 TCP  ：`/dev/tcp/104.18.42.88/443` ⇒ **通**     ← 不是"端口不通"
//   ③ TLS     ：`openssl s_client -servername www.hdmoli.com` ⇒
//                **TLSv1.3 握手成功**、证书 `CN=www.hdmoli.com`、`Verification: OK`
//                （不带 SNI ⇒ `handshake failure (alert 40)` ⇒ 说明 CF 按 SNI 分流，正常行为）
//   ④ HTTP    ：用 **openssl 手工发 HTTP 请求** ⇒ **`HTTP/1.1 200 OK`**
//                真实页面 32722 字符、站点自己的正则命中 **40 张卡片**
//   ⇒ ★ **结论：上游完全可用**；`curl` 的 000 是**我这台机器上 curl 与它的连接复用/超时判定**问题。
//
// ## ⇒ 这构成本批**第三条**"区分'我打错'与'上游死'"的形态
// ```text
// · SaoHuo：**路径**打错（根路径 vs 内容页）        ⇒ 522 被误读成"站死"
// · AppRJ ：**方法/编码**打错（GET vs POST/multipart）⇒ 405 被误读成"端点不存在"
// · HDMoli：**客户端工具**不对（curl 卡住，openssl 通）⇒ 000 被误读成"连不上"
// ★ 三条的共同点：**"上游不可用"是强断言，而失败读数的成因远不止"上游"一种。**
//   本类给出的**正面证据**是：TLS 握手成功 + 证书域名正确 + **手工 HTTP 拿到 200 与真内容**。
//   ⇒ 有正面证据 ⇒ 判"可用"；**不**判"上游死"。
// ```
//
// # 协议（DEX 逐字：**正则 HTML 抓取型**）
// ```text
// 站点前缀：`https://www.hdmoli.com`（DEX `get()` 里拼死的）
// 头：User-Agent = Chrome151 那条；Referer = `https://www.hdmoli.com/`
//
// 列表：`/mlist/index{page}.html`（DEX 里 `&jq=&area=&year=&order=&state=` 是筛选项拼尾）
// 搜索：`/search.php?searchtype=5&tid=` + URLEncoder(kw)
//       （另有 `/search.php?searchkey=` 形态，见 DEX 两条模板）
// 详情：`/movie/index{id}.html`
//
// ★ DEX 逐字给出的**站点自己的正则**（我照抄，因为它们就是协议的一部分）：
//   · 卡片：`<a[^>]*href="(/movie/index(\d+)\.html)"[^>]*title="([^"]*)"[^>]*>\s*<img[^>]*class="vod-poster"[^>]*src="([^"]*)"`
//   · 标题：`<h1[^>]*>([^<]*)</h1>`
//   · 简介：`<meta name="description" content="([^"]*)"`
//   · 字段：`<span class="text-muted">(导演|主演|类型|地区|年份|状态)[：:]</span>([^<]*)`
//   · 网盘：`data-name="([^"]*)" data-url="([^"]*)"`
// ```
//
// ## ★★ 真网读数（逐字，2026-10-27）
// ```text
// GET /mlist/index1.html      ⇒ **200**，HTML **32722** 字符
//   站点正则命中卡片 **40** 条，例：
//     `/movie/index3653.html` title=「末世行者」
//     `/movie/index3652.html` title=「…」
//   vod-poster 封面 **20** 条，例：
//     `https://tc-new.z.wiki/autoupload/ihkph/20261027/UYTM/400X600/p2931652234_cover.jpg/webp`
// GET /movie/index3653.html   ⇒ **200**，HTML **29091** 字符
//   h1 = 「末世行者」
//   meta desc = 「《末世行者》是2026年美国惊悚,冒险,科幻剧，由雷德利·斯科特执导…」
//   字段 = 年份 2026 / 地区 美国 / 导演 …（命中 3 个）
//   **网盘 data-name/data-url 3 条**：
//     夸克网盘  https://pan.quark.cn/s/1fe0f86a5098
//     百度网盘  https://pan.baidu.com/s/1OzSgw06Y9icjoR8wMmtIOA?pwd=moil
//     PikPak    （该条目这家为空）
// GET /search.php?searchtype=5&tid=1 ⇒ **200**，HTML **34631** 字符，poster 20 条
// ★ 结论：**这是本站的"网盘资源"型协议** —— 详情页给的是**网盘分享链接**，
//   不是直链（与 csp_GuiGui 同族）⇒ 取流必须如实说明"需网盘链路"，**不许当直链交出去**。
// ```
//
// # ⚠️ 已知缺口（按契约"不许静默丢、不许自己造"）
// ```text
// ① ★ **网盘链路**（同 csp_GuiGui）：详情给的 `data-url` 是**网盘分享页**。
//    DEX 里 `detailContent` 把它们拼成 `'暂无网盘资源$hd'` 这样的线路/集名，
//    `playerContent` 则走 Pan 那条工具链。⇒ 本批契约**明确不做 `mProxy`** ⇒
//    本类取流**如实**交回**网盘分享页**并在 label 里写明「网盘分享页（需网盘链路）」，
//    **不假装是直链**（那会让用户点了播不出来还不知道为什么）。
// ② `mProxy`：DEX 里没有（方法表见下）⇒ 本批"不做 mProxy"对此类零影响。
// ③ `loadPic`：DEX 里没有独立实现 ⇒ 封面走源 `cover_headers`（声明式）。
//    ⚠️ `CspSite` **没有** `cover_headers()` 能力位（与 Douban/AppGet/Duboku/SaoHuo/AppRJ 同一条）。
// ④ `initApi`：没有。
// ⑤ `isVideoFormat` / `manualVideoCheck`：DEX 里**没有**这两个方法。
// ⑥ ★ `quickSearchContent`：DEX 里有这个方法（`HDMoli.quickSearchContent`），
//    但本仓 `CspSite` **没有"快速搜索"能力位** ⇒ 如实登记，不硬造。
// ```

use async_trait::async_trait;
use regex::Regex;
use serde_json::Value;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
/// DEX `get()` 里拼死的站点前缀
pub const SITE: &str = "https://www.hdmoli.com";

/// 「网盘链路」的统一文案（与 csp_GuiGui **逐字同一条**，Lead 裁定的口径）
pub const PAN_CHAIN_REASON: &str =
    "该链路依赖 Pan 基类的网盘工具链（本批契约明确不做 mProxy）";

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（DEX 正则的等价实现；全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// URL 模板（DEX 逐字）
pub fn list_url(page: u32) -> String {
    format!("{SITE}/mlist/index{page}.html")
}
/// 搜索（DEX 两条模板；这里用 `searchtype=5&tid=` 那条，关键词走 `searchkey`）
///
/// ★ DEX 里两条都在：`/search.php?searchtype=5&tid=` 与 `/search.php?searchkey=`。
///   实测后者可用（前者是"按分类搜"）⇒ 这里用 `searchkey`（关键词搜索的正确形态）。
pub fn search_url(kw: &str) -> String {
    format!("{SITE}/search.php?searchkey={}", urlencoding::encode(kw))
}
/// 分类列表（**DEX `categoryContent` 逐字**：`/search.php?searchtype=5&tid=` + 筛选串）
///
/// # ★★ 我第一版写错了（真网抓到的真 bug）
/// ```text
/// 第一版我用了 `/mlist/index{page}.html` + 筛选串 ⇒ 拼出
///   `https://www.hdmoli.com/mlist/index?&jq=&area=&year=&order=&state=&page=1`
///   两个错：① 路径丢了 `indexN.html` ② `?` 后紧跟 `&`（双符号）
/// 真网读数：**请求直接失败**（`error sending request`）。
/// ★ DEX `categoryContent` 用的是 `/search.php?searchtype=5&tid={tid}`。
///   `/mlist/index{page}.html` 是**首页/列表页**的形态（我实测它可用，40 条卡片），
///   但**分类**要走 `search.php` —— 两者用途不同，我混用了。
/// ```
pub fn category_url(tid: &str, page: u32) -> String {
    // DEX：`/search.php?searchtype=5&tid=` + tid；筛选串（jq/area/year/order/state）拼尾
    let base = format!("{SITE}/search.php?searchtype=5&tid={}", urlencoding::encode(tid.trim()));
    let f = filters_of(tid);
    if f.is_empty() {
        format!("{base}&page={page}")
    } else {
        format!("{base}{f}&page={page}")
    }
}

/// 详情（DEX 逐字 `/movie/index{id}.html`）
pub fn detail_url(id: &str) -> String {
    format!("{SITE}/movie/index{}.html", id.trim().trim_end_matches(".html"))
}

/// 列表 HTML → 卡片（**DEX 正则的等价**）
///
/// ```text
/// DEX：`<a[^>]*href="(/movie/index(\d+)\.html)"[^>]*title="([^"]*)"[^>]*>\s*<img[^>]*class="vod-poster"[^>]*src="([^"]*)"`
/// ⇒ 组：① href ② 数字 id ③ title ④ 封面
/// ```
/// **0 条 ⇒ Err**（反空真）
pub fn cards_from(html: &str, what: &str) -> Result<Vec<CspItem>, String> {
    // ★ 与 DEX 的差别（如实说明）：DEX 的正则**要求** `a` 紧接着 `img.vod-poster`；
    //   实测页面里卡片与封面之间还有 `<div>`（我抓到 40 条 href/title、20 张 poster）
    //   ⇒ 拆成**两步**（先抓 a 的 href/title，再在附近找 poster）比照抄一个
    //     "必须紧邻"的正则更鲁棒，且**不丢卡片**（不会因为多一个 div 就整条匹配失败）。
    let re_a = re(r#"<a[^>]*href="(/movie/index(\d+)\.html)"[^>]*title="([^"]*)""#);
    let re_poster = re(r#"class="vod-poster"[^>]*src="([^"]*)""#);
    let posters: Vec<String> = re_poster
        .captures_iter(html)
        .filter_map(|c| c.get(1).map(|m| m.as_str().to_string()))
        .collect();
    let mut out: Vec<CspItem> = Vec::new();
    for c in re_a.captures_iter(html) {
        let id = c.get(2).map(|m| m.as_str()).unwrap_or("");
        let title = c.get(3).map(|m| m.as_str()).unwrap_or("").trim();
        if id.is_empty() || title.is_empty() {
            continue;
        }
        if out.iter().any(|i| i.id == id) {
            continue; // 同一条目在页里出现两次（卡片区 + 标题区）
        }
        let cover = posters.get(out.len()).cloned();
        out.push(CspItem {
            id: id.to_string(),
            title: title.to_string(),
            cover,
            subtitle: None,
        });
    }
    if out.is_empty() {
        return Err(format!(
            "上游 {what} 的 HTML 里没抓到卡片（页面 {} 字符；\
             站点自己的正则可能改版了）",
            html.chars().count()
        ));
    }
    Ok(out)
}

/// 详情 HTML → `CspDetail`（h1 / meta 简介 / 字段 / 网盘链接）
///
/// **解析不出标题 ⇒ Err**（不静默给一个用 id 冒充的标题）
pub fn detail_of(html: &str, id: &str) -> Result<CspDetail, String> {
    let title = re(r"<h1[^>]*>([^<]*)</h1>")
        .captures(html)
        .and_then(|c| c.get(1).map(|m| m.as_str().trim().to_string()))
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            format!(
                "上游详情 {id} 的 HTML 里取不到 `<h1>`（页面 {} 字符；可能改版或被拦）",
                html.chars().count()
            )
        })?;
    let desc = re(r#"<meta name="description" content="([^"]*)""#)
        .captures(html)
        .and_then(|c| c.get(1).map(|m| m.as_str().trim().to_string()))
        .filter(|s| !s.is_empty());
    // 字段（导演/主演/类型/地区/年份/状态）—— 拼进简介（DEX 同形：这些是详情页的字段行）
    let fields: Vec<(String, String)> = re(
        r#"<span class="text-muted">(导演|主演|类型|地区|年份|状态)[：:]</span>([^<]*)"#,
    )
    .captures_iter(html)
    .filter_map(|c| {
        let k = c.get(1)?.as_str().to_string();
        let v = c.get(2)?.as_str().trim().to_string();
        if v.is_empty() {
            None
        } else {
            Some((k, v))
        }
    })
    .collect();
    let field_line = fields
        .iter()
        .map(|(k, v)| format!("{k}：{v}"))
        .collect::<Vec<_>>()
        .join(" / ");
    let description = match (desc, field_line.is_empty()) {
        (Some(d), false) => Some(format!("{d}\n{field_line}")),
        (Some(d), true) => Some(d),
        (None, false) => Some(field_line),
        (None, true) => None,
    };
    let cover = re(r#"class="vod-poster"[^>]*src="([^"]*)""#)
        .captures(html)
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()))
        .filter(|s| !s.is_empty());

    let pans = pan_links_of(html);
    if pans.is_empty() {
        return Err(format!(
            "上游详情 {id} 的 HTML 里没抓到网盘链接（`data-name`/`data-url` 可能改版）；\
             ★ 本类是网盘资源型，没有网盘链接就等于没有可播放内容"
        ));
    }
    let episodes: Vec<CspEpisode> = pans
        .iter()
        .enumerate()
        .map(|(i, (name, url))| CspEpisode {
            // ★ 集 id 带上分享页地址（`play` 要用），用 `\u{1}` 分隔（不会与 URL 冲突）
            id: format!("{id}\u{1}{url}"),
            title: name.clone(),
            flag: "网盘".to_string(),
        })
        .collect();
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover,
        description,
        episodes,
    })
}

/// 网盘链接（DEX 逐字：`data-name="([^"]*)" data-url="([^"]*)"`）
pub fn pan_links_of(html: &str) -> Vec<(String, String)> {
    re(r#"data-name="([^"]*)" data-url="([^"]*)""#)
        .captures_iter(html)
        .filter_map(|c| {
            let n = c.get(1)?.as_str().trim().to_string();
            let u = c.get(2)?.as_str().trim().to_string();
            // ★ 空 url 要丢掉（实测 PikPak 那家就是空）——否则会造出一个"点了没用的集"
            if u.is_empty() {
                None
            } else {
                Some((if n.is_empty() { "网盘".to_string() } else { n }, u))
            }
        })
        .collect()
}

/// 从集 id 拆出 `(条目id, 分享页url)`（`\u{1}` 分隔）
pub fn split_ep_id(ep: &str) -> Option<(String, String)> {
    let (id, url) = ep.split_once('\u{1}')?;
    if id.is_empty() || url.trim().is_empty() {
        return None;
    }
    Some((id.to_string(), url.trim().to_string()))
}

/// 正则缓存（每次编译很贵；本仓已用 `regex` crate ⇒ `OnceLock` 缓存）
fn re(pat: &str) -> Regex {
    use std::collections::HashMap;
    use std::sync::{Mutex, OnceLock};
    static CACHE: OnceLock<Mutex<HashMap<String, Regex>>> = OnceLock::new();
    let m = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut g = m.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(r) = g.get(pat) {
        return r.clone();
    }
    let r = Regex::new(pat).unwrap_or_else(|e| panic!("正则写错了：{pat} → {e}"));
    g.insert(pat.to_string(), r.clone());
    r
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct HDMoli {
    client: reqwest::Client,
}

impl HDMoli {
    pub const CLASS: &'static str = "HDMoli";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            /*
             * ★★★ `.no_proxy()` —— **本仓 csp 的既定惯例**（`app3q/app99/app_drama/app_fox/
             *   app_qi/app_sy/app_yqk/app_ys` … 都有），**而我第一版漏了它**。
             *
             * # 这个漏项的真网后果（本类实测抓到的根因）
             * ```text
             * 本机环境：`https_proxy=http://127.0.0.1:7890/`（curl/reqwest/urllib **都会读它**）。
             * 而那个代理**对本站连接不通** ⇒
             *     reqwest 走代理      ⇒ `error sending request ← operation timed out`
             *     curl 走代理        ⇒ `(28) Connection timed out`
             *     手工 openssl 直连   ⇒ **HTTP 200 / 36173 字节** ← 不走代理
             *     Python `no-proxy`  ⇒ **HTTP 200 / 36173 字节**
             *     Python `via-proxy` ⇒ `TLS 握手超时`
             *   ⇒ ★ **失败与"上游"无关，是"我们没绕开本机代理"。**
             * ```
             * # 为什么 csp 类必须 `.no_proxy()`
             * ```text
             * ① 这些源是**面向公网直连**的（本机代理是给浏览器/开发用的，不是它们的依赖）；
             * ② 本仓既有 8 个类已经这么做了 ⇒ **不这么做就是偏离惯例**（也会造成
             *    "有的源能通、有的源不通"这种极难定位的现象）；
             * ③ 代理的存在与否**不该改变 csp 源的行为**（否则用户装了个代理就有一半源失效）。
             * ```
             */
            .no_proxy()
            .timeout(std::time::Duration::from_secs(25))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self { client }
    }

    /// DEX `get()` 的头（UA + Referer）
    async fn get_text(&self, url: &str, what: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::REFERER, format!("{SITE}/"))
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .header(reqwest::header::ACCEPT_LANGUAGE, "zh-CN,zh;q=0.9")
            .send()
            .await
            .map_err(|e| format!("请求 HDmoli 上游失败（{url}）：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取 HDmoli 响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            let head = body.chars().take(80).collect::<String>();
            return Err(format!(
                "上游 HDmoli 返回 HTTP {status}（{url}）：{head:?}"
            ));
        }
        let _ = what;
        Ok(body)
    }
}

impl Default for HDMoli {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for HDMoli {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页分类（DEX `homeContent` 给的筛选表）—— **内嵌常量**（不打上游）
    ///
    /// ★ 拆成两半（**为了让离线门禁不碰网络** —— 见 [`home_of`]）：
    ///   分类来自常量；预取失败**不影响**分类（与 DEX 的内嵌表语义一致）。
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let prefetch = self.get_text(&list_url(1), "首页").await;
        Ok(home_of(prefetch))
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        // DEX 里面板是 `/mlist/index{page}.html` + 筛选串；tid 是内嵌分类的 key。
        // 基路径仍走 `/mlist/index{page}.html`（实测可用）；若有筛选键则拼尾。
        // ★ 用 DEX 逐字的 `search.php?searchtype=5&tid=` 形态（不是我第一版那个 `/mlist/index?`）
        let url = category_url(tid, page);
        let html = self.get_text(&url, &format!("分类 {tid} 第 {page} 页")).await?;
        Ok(CspList {
            items: cards_from(&html, &format!("分类 {tid} 第 {page} 页"))?,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        if page > 1 {
            return Err(format!(
                "csp_HDMoli 的搜索不支持分页（DEX 的 `/search.php?searchkey=` 模板没有页码位）"
            ));
        }
        let html = self.get_text(&search_url(kw), "搜索").await?;
        Ok(CspList {
            items: cards_from(&html, "搜索")?,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        true
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let html = self
            .get_text(&detail_url(id), &format!("详情 {id}"))
            .await?;
        detail_of(&html, id.trim())
    }

    /// 取流：详情给的是**网盘分享页** ⇒ 如实交回 + label 写明需网盘链路
    ///
    /// ⚠️ 与 csp_GuiGui **同一处置**（同类协议）：**不假装是直链**。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let (_vid, url) = split_ep_id(id).ok_or_else(|| {
            format!(
                "取流 id 必须是 `{{详情id}}\\u{{1}}{{网盘分享页}}` 形态（原始 id={id:?}）"
            )
        })?;
        Ok(vec![CspPlay {
            url,
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                ("Referer".to_string(), format!("{SITE}/")),
            ],
            label: Some(format!("网盘分享页（{PAN_CHAIN_REASON}）")),
        }])
    }
}

/// 首页的**纯**组装（把网络取值的结果当参数传进来 ⇒ 离线可确定性测试）
///
/// # 为什么必须拆出来（实测踩到）
/// ```text
/// 第一版 `home()` 里直接 `get_text()` ⇒ 那条离线门禁**每次跑都要打真网络**，
/// 结果：`test result: ok` 但要 **25 秒**（超时窗口），且**没网时行为不确定**。
/// ★ 判据：**离线门禁必须确定性**（不许依赖网络、不许因网络快慢而变读数）。
/// ```
pub fn home_of(prefetch: Result<String, String>) -> CspHome {
    let items = match prefetch {
        Ok(html) => cards_from(&html, "首页").unwrap_or_default(),
        // ★ 预取失败**不报错**：分类是常量，上游挂了 UI 也该有分类可点
        Err(_) => Vec::new(),
    };
    CspHome {
        categories: cats(),
        items,
    }
}

/// DEX `homeContent` 的内嵌分类表
pub fn cats() -> Vec<CspCategory> {
    [
        ("1", "电影"),
        ("2", "连续剧"),
        ("3", "综艺"),
        ("4", "动漫"),
        ("5", "纪录片"),
        ("41", "短剧"),
    ]
    .iter()
    .map(|(i, n)| CspCategory {
        id: (*i).to_string(),
        name: (*n).to_string(),
    })
    .collect()
}

/// 分类 id → DEX 里的筛选串（`jq/area/year/order/state`；没有则空）
///
/// ★ 本仓 `CspCategory` **没有筛选项能力位** ⇒ 只有"分类"这一维，
///   筛选串由 `tid` 直接映射（能映射的才拼，不能映射的走基路径）。
pub fn filters_of(tid: &str) -> String {
    match tid.trim() {
        "1" => "&jq=&area=&year=&order=&state=".to_string(),
        "2" => "&jq=&area=&year=&order=&state=".to_string(),
        "41" => "&jq=&area=&year=&order=&state=".to_string(),
        _ => String::new(),
    }
}

crate::csp::register_site!(HDMoli);

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★ URL 模板逐字（DEX `get()` 拼死的站点前缀 + 三条模板）
    ///
    /// 注入：把 `SITE` 改成别的域名 ⇒ 本条红。
    #[test]
    fn url_templates_are_verbatim() {
        assert_eq!(SITE, "https://www.hdmoli.com");
        assert_eq!(list_url(1), "https://www.hdmoli.com/mlist/index1.html");
        assert_eq!(list_url(12), "https://www.hdmoli.com/mlist/index12.html");
        assert_eq!(detail_url("3653"), "https://www.hdmoli.com/movie/index3653.html");
        // 已经带 `.html` 的 id 不该拼出 `…3653.html.html`
        assert_eq!(detail_url("3653.html"), "https://www.hdmoli.com/movie/index3653.html");
        // 搜索要编码
        let s = search_url("末世行者");
        assert!(s.starts_with("https://www.hdmoli.com/search.php?searchkey="), "{s}");
        assert!(s.contains("%E6%9C%AB%E4%B8%96"), "关键词必须 URL 编码：{s}");
        let s2 = search_url("a&b");
        assert!(!s2.contains("a&b"), "裸 `&` 会改 URL 结构：{s2}");

        /*
         * ★★ 分类 URL —— **真网抓到的真 bug 的回归门禁**
         *
         * 第一版我用了 `/mlist/index{page}.html` 拼筛选串 ⇒ 产出
         *   `https://www.hdmoli.com/mlist/index?&jq=&area=&year=&order=&state=&page=1`
         * 两个错：① 路径丢了 `indexN.html` ② `?` 后紧跟 `&`（双符号）⇒ 真网请求**直接失败**。
         * DEX `categoryContent` 用的是 `/search.php?searchtype=5&tid={tid}`。
         * 注入：把 `category_url` 改回 `/mlist/index?{f}&page=` 形态 ⇒ 本条红。
         */
        let c = category_url("1", 1);
        assert_eq!(
            c, "https://www.hdmoli.com/search.php?searchtype=5&tid=1&jq=&area=&year=&order=&state=&page=1",
            "★★ 分类 URL 必须走 DEX 的 search.php 形态"
        );
        assert!(!c.contains("list/index?"), "★★ 不许用 `/mlist/index?`（那是我第一版的错法）");
        assert!(!c.contains("?&"), "★★ 不许出现 `?&` 双符号");
        // 没有筛选串的分支也要合法（`&page=` 直接跟在 `tid=` 之后）
        let c2 = category_url("99", 3);
        assert_eq!(c2, "https://www.hdmoli.com/search.php?searchtype=5&tid=99&page=3");
        assert!(!c2.contains("&page=3&"), "★ 结尾不该多 `&`");
        // tid 要编码（分类 key 一般是数字，但别假设）
        let c3 = category_url("a b", 1);
        assert!(c3.contains("tid=a%20b"), "{c3}");
    }

    #[test]
    /// ★★ 卡片解析：**逐字用真网读数构造**（站点自己的正则）
    ///
    /// # 实测依据
    /// ```text
    /// GET /mlist/index1.html ⇒ 200 / 32722 字符
    ///   站点正则命中卡片 **40** 条、vod-poster 封面 **20** 张
    ///   （⇒ 卡片数 ≠ 封面数，因为同一条目在"卡片区 + 标题区"各出现一次）
    /// ```
    /// 注入：把 `re_a` 的正则改坏（如去掉 `/movie/` 前缀）⇒ 本条红。
    #[test]
    fn parses_real_cards_shape() {
        let html = r#"
          <div class="col-6">
            <a href="/movie/index3653.html" title="末世行者" class="v-item">
              <img class="vod-poster" src="https://tc-new.z.wiki/autoupload/20261027/UYTM/400X600/p2931652234_cover.jpg/webp">
            </a>
          </div>
          <p class="v-title"><a href="/movie/index3653.html" title="末世行者">末世行者</a></p>
          <div class="col-6">
            <a href="/movie/index3652.html" title="另一部" class="v-item">
              <img class="vod-poster" src="https://tc-new.z.wiki/autoupload/20261026/Blx8/400X600/p2930621049_cover.jpg/webp">
            </a>
          </div>"#;
        let c = cards_from(html, "列表").unwrap();
        assert_eq!(c.len(), 2, "★ 同一条目出现两次 ⇒ 要去重（实测形态）");
        assert_eq!(c[0].id, "3653", "★ id 是正则第 2 组（数字）");
        assert_eq!(c[0].title, "末世行者");
        assert!(
            c[0].cover.as_deref().unwrap_or("").contains("p2931652234_cover"),
            "封面要取到：{:?}",
            c[0].cover
        );
        assert_eq!(c[1].id, "3652");
    }

    #[test]
    /// ★★ 反空真：卡片 / 网盘 抓不到 ⇒ **必须 Err**（带页面字符数便于定位）
    ///
    /// 注入：删掉 `cards_from` 里 `if out.is_empty()` 的 Err ⇒ 本条红。
    #[test]
    fn empty_extractions_are_errors() {
        let e = cards_from("<html><body>没有卡片</body></html>", "列表").expect_err("★ 0 条必须 Err");
        assert!(e.contains("没抓到卡片"), "{e}");
        assert!(e.contains("字符"), "要带回页面大小便于定位：{e}");

        let e2 = detail_of("<html><h1>有标题</h1></html>", "1").expect_err("★ 无网盘必须 Err");
        assert!(e2.contains("网盘"), "{e2}");
        // 连 h1 都没有 ⇒ Err（不许静默用 id 冒充标题）
        let e3 = detail_of("<html></html>", "1").expect_err("★ 无 h1 必须 Err");
        assert!(e3.contains("h1"), "{e3}");
    }

    #[test]
    /// ★★ 详情解析（逐字用真网读数构造：h1 / meta / 字段 / 网盘）
    ///
    /// 注入：把 `data-name/data-url` 的正则改掉 ⇒ 本条红。
    #[test]
    fn parses_real_detail_shape() {
        let html = r#"
          <h1 class="text-2xl">末世行者</h1>
          <meta name="description" content="《末世行者》是2026年美国惊悚,冒险,科幻剧">
          <span class="text-muted">年份：</span>2026
          <span class="text-muted">地区：</span>美国
          <a data-name="夸克网盘" data-url="https://pan.quark.cn/s/1fe0f86a5098">夸克网盘</a>
          <a data-name="百度网盘" data-url="https://pan.baidu.com/s/1OzSgw06Y9icjoR8wMmtIOA?pwd=moil">百度</a>
          <a data-name="PikPak" data-url="">PikPak</a>"#;
        let d = detail_of(html, "3653").unwrap();
        assert_eq!(d.title, "末世行者");
        assert!(d.description.as_deref().unwrap_or("").contains("美国惊悚"), "{:?}", d.description);
        assert!(d.description.as_deref().unwrap_or("").contains("年份：2026"), "字段要拼进去");
        assert_eq!(d.episodes.len(), 2, "★★ **空 url 的网盘要丢掉**（实测 PikPak 那家为空）");
        assert_eq!(d.episodes[0].title, "夸克网盘");
        assert_eq!(d.episodes[1].title, "百度网盘");
        // 集 id 要能完整拆回
        let (id, url) = split_ep_id(&d.episodes[0].id).unwrap();
        assert_eq!(id, "3653");
        assert_eq!(url, "https://pan.quark.cn/s/1fe0f86a5098");
        // ★ 含 `?pwd=` 的地址不能被切坏
        let (_, u2) = split_ep_id(&d.episodes[1].id).unwrap();
        assert_eq!(u2, "https://pan.baidu.com/s/1OzSgw06Y9icjoR8wMmtIOA?pwd=moil");
    }

    #[test]
    /// ★★ `pan_links_of`：空 `data-url` 必须丢掉（否则造出"点了没用的集"）
    ///
    /// 注入：把 `if u.is_empty() { None }` 改成 `Some(...)` ⇒ 本条红。
    #[test]
    fn empty_pan_urls_are_dropped() {
        let html = r#"<a data-name="有" data-url="https://x/1">有</a>
                      <a data-name="空" data-url="">空</a>
                      <a data-name="" data-url="https://y/2">无名</a>"#;
        let p = pan_links_of(html);
        assert_eq!(p.len(), 2, "★ 空 url 那条要丢：{p:?}");
        assert_eq!(p[0].0, "有");
        assert_eq!(p[1].0, "网盘", "★ 无名时给个中性默认（不是空串）");
        assert!(!p.iter().any(|(_, u)| u.is_empty()));
    }

    /// ★★ 四段行为 + `CSP_LIVE=1` 闸门形态（离线部分）
    ///
    /// 注入：把 `play` 的形态检查删掉 ⇒ 本条红。
    ///
    /// ⚠️ 只留 `#[tokio::test]`（叠 `#[test]` ⇒ "async functions cannot be used for tests"）。
    #[tokio::test]
    async fn segments_behave_and_play_is_honest() {
        let s = HDMoli::new();
        assert!(s.supports_search());
        /*
         * ★ 分类来自内嵌常量 ⇒ 走**纯函数**（不打网络 ⇒ 确定性、秒级返回）。
         * ⚠️ 第一版这里调 `s.home("")` ⇒ 触发真网络预取 ⇒ 离线门禁跑 25 秒
         *   且"有没有网"会影响读数（**离线门禁不许这样**）。已拆出 `home_of`。
         */
        let h = home_of(Err("离线门禁不打网络".to_string()));
        assert!(!h.categories.is_empty());
        assert!(h.categories.iter().any(|c| c.name == "电影"));
        assert!(h.items.is_empty(), "★ 预取失败 ⇒ 条目为空，但分类仍在");
        // 反面：预取成功时条目要真的填进去（用一段真形态 HTML）
        let ok = home_of(Ok(r#"<a href="/movie/index1.html" title="X"><img class="vod-poster" src="https://p/1.jpg"></a>"#.to_string()));
        assert_eq!(ok.items.len(), 1, "★ 预取成功 ⇒ 条目要填进首页");
        assert_eq!(ok.items[0].id, "1");
        // 第 2 页 ⇒ 如实报"不支持分页"
        let e = s.search("x", 2, "").await.expect_err("★ 第 2 页必须 Err");
        assert!(e.contains("不支持分页"), "{e}");
        // play：形态不对 ⇒ Err
        let e2 = s.play("网盘", "3653", "").await.expect_err("★ 裸 id 必须 Err");
        assert!(e2.contains("形态"), "{e2}");
        // play：正常形态 ⇒ 交回分享页 + 诚实 label（**不假装是直链**）
        let p = s
            .play("网盘", "3653\u{1}https://pan.quark.cn/s/1fe0f86a5098", "")
            .await
            .unwrap();
        assert_eq!(p[0].url, "https://pan.quark.cn/s/1fe0f86a5098");
        let lab = p[0].label.clone().unwrap_or_default();
        assert!(lab.contains("网盘分享页"), "★ 必须写清是分享页：{lab}");
        assert!(lab.contains(PAN_CHAIN_REASON), "要带上裁定文案：{lab}");
    }

    #[test]
    /// ★ 冻结：`PAN_CHAIN_REASON` 逐字（与 GuiGui 同一条口径）+ 不拼弹幕代理
    ///
    /// 注入：把文案改成"本仓没有转发服务"⇒ 本条红。
    #[test]
    fn pan_reason_is_verbatim_and_no_danmaku_proxy() {
        assert_eq!(
            PAN_CHAIN_REASON,
            "该链路依赖 Pan 基类的网盘工具链（本批契约明确不做 mProxy）"
        );
        assert!(!PAN_CHAIN_REASON.contains("没有转发服务"), "★ 不许把事实说错");
        let src = include_str!("hd_moli.rs");
        let code: Vec<String> = src
            .lines()
            .map(|l| {
                let t = l.trim();
                if t.starts_with("//") || t.starts_with('*') || t.starts_with("/*") {
                    String::new()
                } else {
                    l.split("//").next().unwrap_or("").to_string()
                }
            })
            .collect();
        let needle = format!("do={}{}", "app", "danmu");
        assert!(!code.iter().any(|l| l.contains(&needle)), "★ 不许拼弹幕代理");
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    /// ★★ 真网四段。**这条的判据是"必须拿到真数据"** ——
    ///    它也是"我第一版把 curl 的 000 误读成'连不上'"的**纠正者**。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_hd_moli -- --ignored --nocapture"]
    async fn csp_live_hd_moli_four_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = HDMoli::new();
        let h = s.home("").await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {} 个（首={}），预取 {} 条",
            h.categories.len(),
            h.categories[0].name,
            h.items.len()
        );
        let l = s.list("1", 1, "").await.expect("list 应成功");
        eprintln!("[LIVE] list: {} 条 首={}（id={}）", l.items.len(), l.items[0].title, l.items[0].id);
        assert!(!l.items.is_empty());
        let se = s.search("末", 1, "").await.expect("search 应成功");
        eprintln!("[LIVE] search(末): {} 条 首={}", se.items.len(), se.items[0].title);
        let d = s.detail(&l.items[0].id, "").await.expect("detail 应成功");
        eprintln!(
            "[LIVE] detail: {} — {} 个网盘（首={}）| 简介={:?}",
            d.title,
            d.episodes.len(),
            d.episodes[0].title,
            d.description.as_deref().map(|x| x.chars().take(40).collect::<String>())
        );
        let p = s.play("网盘", &d.episodes[0].id, "").await.expect("play 应成功");
        eprintln!("[LIVE] play: {} [{}]", p[0].url, p[0].label.clone().unwrap_or_default());
        assert!(p[0].url.starts_with("http"), "★ 必须拿到真地址（网盘分享页）");
    }
}