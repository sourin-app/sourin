// ═══════════════════════════════════════════════════════════════════════
//  csp_Wogg —— 「玩偶系网盘分享站」的 Rust 实现（HTML 解析，Pan 族）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（DEX 常量逐字，`.probe/csp25/Wogg.txt` + `.probe/dex_const_strings.py`）
// ```text
// parent  = Lcom/github/catvod/spider/Pan;
// 方法     <clinit> <init> d g h j categoryContent detailContent homeContent
//          init parseVodList searchContent searchContent
// 字段     f
// 关键选择器（逐字）
//   .module-item / .module-item-text / .module-item-pic > img[data-src]
//   .module-item-titlebox >a[href][title]              ← 列表项
//   .module-search-item / .video-serial                ← 搜索结果
//   .video-info-header > .page-title                   ← 详情标题
//   .video-info-header a.tag-link / div.tag-link a
//   p.sqjj_a                                           ← 简介
//   .module-row-text[data-clipboard-text]              ← ★ 网盘分享链接就在这个属性上
// 路径（逐字）
//   搜索 /index.php/vodsearch/%s----------%s---.html
//   列表 /vodshow/%s-%s-%s-%s-----%s---%s.html
//          = /vodshow/<tid>--------<page>---.html（class/area/year/by 留空时）
// ```
// ★ 以上**路径格式全部真网复核过**（2026-10-28，直连；见 `.probe/csp-app-live.log`）：
//   `http://www.wogg.live/vodshow/1--------1---.html` → 200 / 70 条目；
//   `/index.php/vodsearch/玩偶----------1---.html` → 200 / 13 条；
//   `/voddetail/133277.html` → 200 / 夸克+百度两条分享。
//
// # 与 DEX 的两处**有据**差异
// ```text
// ① 详情路径：DEX 常量里没有详情路径，真站给的是 `/voddetail/<id>.html`
//    （不是 MacCMS 的 `/index.php/vod/detail/id/<id>.html`）⇒ 按真站来。
// ② 取流：DEX 的父类 `Pan` 把分享链接接到 `http://127.0.0.1:5266`（TVBox 自带
//    的本机转发服务）再由它换直链。★ 2026-10-31（T1a）改判：夸克/UC 族改走
//    本仓原生的 `PanDrive::resolve_share_play`（转存→直链，4kzhinan 等已真机
//    验证）—— 见 `play`；其它网盘族维持如实拒绝（T1b 取证后另接）。
// ```
//
// # 镜像回退（契约第 2 条）
// ```text
// ext.site 里给了 4 个镜像（订阅原文）：
//   https://wogg.xxooo.cf / http://www.wogg.live / https://www.wogg.net / https://woggpan.xxooo.cf
// 顺序试、首个成功即用（成功过的置顶 sticky）；全失败时汇总**前 N 条 + 总条数**，
// 不是只回最后一个错误 —— 否则 3 个 DNS 失败 + 1 个超时会被压成一句"超时"。
// ★ 直连（`no_proxy()`）：本机系统代理会把"站点可用"测成"全宕"（见诚实契约第 3 条）。
// ```
//
// # 注：本文件里的站名只出现在**配置示例/镜像主机**里（ext 传入），不写死真实站名。

use async_trait::async_trait;
use std::time::Duration;

use super::pan_web_share::UrlPanKind;
use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `init` 的 UA（逐字，Chrome/151）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 单请求上限：镜像有 4 个，20s×4 会把"某个镜像慢"放大成"整类不可用"
const TIMEOUT: Duration = Duration::from_secs(12);

/// 一次取数的总预算（4 镜像串行 + 首屏 HTML 630KB）
const FETCH_BUDGET: Duration = Duration::from_secs(30);

/// 失败摘要里最多列几个镜像
const MAX_FAIL_DETAILS: usize = 3;

/// 一页最多收多少条（真站首页 255 个 `module-item`，去重后 70 条/页）
const MAX_ITEMS: usize = 120;

pub struct Wogg {
    client: reqwest::Client,
    /// 成功过的镜像置顶（避免每次请求都从死镜像开始重试）
    sticky: std::sync::Mutex<Option<String>>,
}

impl Wogg {
    pub const CLASS: &'static str = "Wogg";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // ★ 必须在 `.timeout(..)` 之后、`.build()` 之前：不读系统代理，
            //   否则本机代理的 502 会把 4 个镜像全判死（诚实契约第 3 条）。
            .no_proxy()
            .build()
            .expect("build wogg http client");
        Self {
            client,
            sticky: std::sync::Mutex::new(None),
        }
    }

    /// 从 ext 取镜像列表：`{"site":["https://a","https://b"]}`
    ///
    /// ★ ext 也可能是**字符串形态**（TVBox 允许两种）⇒ 解析失败就退回
    ///   "整段里抓 http(s) 地址"，与本仓 `pan_web_share::sites_of` 同一口径。
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

    fn need_sites(ext: &str) -> Result<Vec<String>, String> {
        let sites = Self::sites_of(ext);
        if sites.is_empty() {
            return Err("Wogg 需要 ext 里的镜像列表（键 `site`，形如 \
                        {\"site\":[\"https://a.example\",\"https://b.example\"]}）——\
                        当前配置没给，无法取数"
                .to_string());
        }
        Ok(sites)
    }

    async fn get_html(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .send()
            .await
            .map_err(|e| format!("请求失败：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {}：{}", status.as_u16(), head(&text)));
        }
        Ok(text)
    }

    /// 依次尝试镜像，返回第一个成功的 HTML（含它用的 base）
    async fn fetch_first(&self, sites: &[String], path: &str) -> Result<(String, String), String> {
        let started = std::time::Instant::now();
        let sticky = self.sticky.lock().ok().and_then(|g| g.clone());
        let mut order: Vec<String> = Vec::with_capacity(sites.len());
        if let Some(hit) = &sticky {
            if sites.iter().any(|s| s == hit) {
                order.push(hit.clone());
            }
        }
        for s in sites {
            if Some(s) != sticky.as_ref() {
                order.push(s.clone());
            }
        }

        let mut failures: Vec<String> = Vec::new();
        for base in &order {
            let left = FETCH_BUDGET.saturating_sub(started.elapsed());
            if left.is_zero() {
                failures.push(format!("总耗时已达 {}s 预算，停止重试", FETCH_BUDGET.as_secs()));
                break;
            }
            let url = format!("{base}{path}");
            match tokio::time::timeout(left, self.get_html(&url)).await {
                Ok(Ok(html)) => {
                    if let Ok(mut g) = self.sticky.lock() {
                        *g = Some(base.clone());
                    }
                    return Ok((base.clone(), html));
                }
                Ok(Err(e)) => failures.push(format!("{base}：{e}")),
                Err(_) => failures.push(format!("{base}：超时（剩余预算 {}s）", left.as_secs())),
            }
        }
        Err(summarize_failures(&failures, order.len()))
    }
}

impl Default for Wogg {
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

/// 多镜像失败压成一句可读原因（前 N 条 + 总条数）
pub fn summarize_failures(failures: &[String], total: usize) -> String {
    let head: Vec<String> = failures
        .iter()
        .take(MAX_FAIL_DETAILS)
        .map(|e| e.trim().to_string())
        .collect();
    let mut out = format!("Wogg 试了 {total} 个镜像都没打开。");
    if head.is_empty() {
        return format!("{out}（没有任何失败明细 —— 这本身异常，请连同日志反馈）");
    }
    out.push_str(&format!("前 {} 条失败：", head.len()));
    out.push_str(&head.join("；"));
    if failures.len() > head.len() {
        out.push_str(&format!("；另有 {} 条同因失败", failures.len() - head.len()));
    }
    out
}

// ═══════════════════════════════════════════════════════════════════════
//  HTML 解析（纯函数 —— 单测直接喂真响应片段，禁 mock 网络）
// ═══════════════════════════════════════════════════════════════════════

/// 分类：导航 `/vodtype/<id>.html`（DEX 里首项也是"全部"，但真站导航没有"全部"）
///
/// 退路：首页 tab 条 `<span class="module-tab-item tab-item" data-id="1" data-name="玩偶电影">`
/// （DEX 里读的就是 `data-id` / `data-name`）。
pub fn parse_categories(html: &str) -> Vec<CspCategory> {
    let re_nav = regex::Regex::new(
        r#"(?is)<a[^>]+class="[^"]*nav-link[^"]*"[^>]*href="(/vodtype/(\d+)\.html)"[^>]*>(.*?)</a>"#,
    )
    .expect("wogg nav regex");
    let mut out: Vec<CspCategory> = Vec::new();
    for c in re_nav.captures_iter(html) {
        let id = c[2].to_string();
        let name = clean_text(&c[3]);
        if name.is_empty() || out.iter().any(|x| x.id == id) {
            continue;
        }
        out.push(CspCategory { id, name });
    }
    if !out.is_empty() {
        return out;
    }
    let re_tab = regex::Regex::new(
        r#"(?is)class="[^"]*module-tab-item[^"]*"[^>]*data-id="(\d+)"[^>]*data-name="([^"]+)""#,
    )
    .expect("wogg tab regex");
    for c in re_tab.captures_iter(html) {
        let id = c[1].to_string();
        let name = clean_text(&c[2]);
        if name.is_empty() || out.iter().any(|x| x.id == id) {
            continue;
        }
        out.push(CspCategory { id, name });
    }
    out
}

/// 列表/搜索/首页共用的条目解析
///
/// # 为什么按 `module-item` 切块（而不是一条大正则）
/// ```text
/// 真站三种页面（首页 / 分类页 / 搜索页）的**外层 class 不同**
/// （`module-item` / `module-item` / `module-search-item`），但块内结构一致：
///   详情链接 `href="/voddetail/<数字>.html"` + `title="<片名>"` + `data-src="<封面>"`。
/// ⇒ 用 `module-item` 当**标记点**切段（regex crate 不支持 lookaround），
///   每段取"第一处"三件套；内层 `module-item-pic` 等也会切段，但按 id 去重即可。
/// ```
pub fn parse_items(html: &str) -> Vec<CspItem> {
    let re_id = regex::Regex::new(r#"/voddetail/(\d+)\.html"#).expect("id");
    let re_title = regex::Regex::new(r#"(?is)title="([^"]*)""#).expect("title");
    let re_pic = regex::Regex::new(r#"(?is)(?:data-src|data-original)="(https?://[^"]+)""#)
        .expect("pic");
    let starts: Vec<usize> = html.match_indices("module-item").map(|(i, _)| i).collect();
    let mut out: Vec<CspItem> = Vec::new();
    for (i, &start) in starts.iter().enumerate() {
        if out.len() >= MAX_ITEMS {
            break;
        }
        let end = starts.get(i + 1).copied().unwrap_or(html.len());
        let seg = &html[start..end.min(html.len())];
        let Some(id) = re_id.captures(seg).map(|c| c[1].to_string()) else {
            continue;
        };
        if out.iter().any(|x| x.id == id) {
            continue;
        }
        let title = re_title
            .captures(seg)
            .map(|c| clean_text(&c[1]))
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        out.push(CspItem {
            id,
            title,
            cover: re_pic.captures(seg).map(|c| c[1].to_string()),
            subtitle: None,
        });
    }
    out
}

/// 首页解析：分类与首屏**都必须非空**（空 ⇒ Err，交给用户判断是否改版/风控）
pub fn home_from_html(html: &str) -> Result<CspHome, String> {
    let categories = parse_categories(html);
    if categories.is_empty() {
        return Err("Wogg 首页能打开，但没解析出任何分类（模板可能已改版，或返回的是风控/维护壳页）"
            .to_string());
    }
    let items = parse_items(html);
    if items.is_empty() {
        return Err("Wogg 首页能打开、也拿到了分类，但没解析出任何条目（模板可能已改版，或首屏异步加载）"
            .to_string());
    }
    Ok(CspHome { categories, items })
}

/// 列表解析：空 ⇒ Err（`page > 1` 的空页是"真的没有更多"，见调用点）
pub fn list_from_html(html: &str, page: u32, what: &str) -> Result<CspList, String> {
    let items = parse_items(html);
    if items.is_empty() {
        return Err(format!(
            "Wogg {what} 页面能打开，但没解析出任何条目（模板可能已改版，或返回的是风控壳页）"
        ));
    }
    Ok(CspList {
        items,
        page,
        page_count: None,
        total: None,
    })
}

/// 详情页：标题 / 封面 / 简介 / 网盘分享链接
///
/// ★ 分享链接挂在 `data-clipboard-text`（DEX 的 `.module-row-text` 就是它）；
///   同一个链接在"复制"按钮上会重复出现 ⇒ 必须按 URL 去重。
pub fn detail_from_html(html: &str, id: &str) -> CspDetail {
    let re_title = regex::Regex::new(r#"(?is)<h1[^>]*class="[^"]*page-title[^"]*"[^>]*>(.*?)</h1>"#)
        .expect("d title");
    let re_pic = regex::Regex::new(r#"(?is)(?:data-src|data-original)="(https?://[^"]+)""#)
        .expect("d pic");
    let re_desc = regex::Regex::new(r#"(?is)<p[^>]*class="[^"]*sqjj_a[^"]*"[^>]*>(.*?)</p>"#)
        .expect("d desc");
    let re_share = regex::Regex::new(r#"(?is)data-clipboard-text="(https?://[^"]+)""#)
        .expect("d share");

    let title = re_title
        .captures(html)
        .map(|c| clean_text(&c[1]))
        .unwrap_or_default();
    let desc = re_desc
        .captures(html)
        .map(|c| clean_text(&c[1]))
        .filter(|s| !s.is_empty());

    let mut episodes: Vec<CspEpisode> = Vec::new();
    for c in re_share.captures_iter(html) {
        let url = c[1].trim().to_string();
        if episodes.iter().any(|e| e.id == format!("pan|{url}")) {
            continue;
        }
        let label = UrlPanKind::of(&url)
            .map(|k| k.label().to_string())
            .unwrap_or_else(|| "分享链接".to_string());
        episodes.push(CspEpisode {
            id: format!("pan|{url}"),
            title: label.clone(),
            flag: label,
        });
        if episodes.len() >= 200 {
            break;
        }
    }

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
impl CspSite for Wogg {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let sites = Self::need_sites(ext)?;
        let (_base, html) = self.fetch_first(&sites, "/").await?;
        home_from_html(&html)
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空（首页没给出分类）".to_string());
        }
        let sites = Self::need_sites(ext)?;
        let page = if page == 0 { 1 } else { page };
        // DEX: `/vodshow/%s-%s-%s-%s-----%s---%s.html`（class/area/year/by 留空）
        //      ⇒ `/vodshow/<tid>--------<page>---.html`
        let path = format!("/vodshow/{tid}--------{page}---.html");
        let (_base, html) = self.fetch_first(&sites, &path).await?;
        let items = parse_items(&html);
        if items.is_empty() {
            if page > 1 {
                // ★ 越界页：站点就是 200 + 空列表（不是解析失败）⇒ 如实回"没有更多"
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total: None,
                });
            }
            return Err(format!(
                "Wogg 分类 {tid} 的页面能打开，但没解析出任何条目（模板可能已改版，或返回的是风控壳页）"
            ));
        }
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let sites = Self::need_sites(ext)?;
        // ★ 真站详情是 `/voddetail/<id>.html`（不是 `/index.php/vod/detail/id/…`）
        let path = format!("/voddetail/{id}.html");
        let (_base, html) = self.fetch_first(&sites, &path).await?;
        let d = detail_from_html(&html, id);
        if d.episodes.is_empty() {
            return Err(format!(
                "Wogg 条目 {id} 的详情页能打开，但没找到任何网盘分享链接\
                 （可能已下架，或模板改版把 data-clipboard-text 换了位置）"
            ));
        }
        Ok(d)
    }

    /// 搜索：`/index.php/vodsearch/<kw>----------<page>---.html`（DEX 逐字）
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let sites = Self::need_sites(ext)?;
        let page = if page == 0 { 1 } else { page };
        let enc = encode_path(kw);
        let path = format!("/index.php/vodsearch/{enc}----------{page}---.html");
        let (_base, html) = self.fetch_first(&sites, &path).await?;
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
                "Wogg 搜索「{kw}」的页面能打开，但没解析出条目\
                 （可能真的没有结果，也可能模板改版/风控壳页 —— 本类不把这种情况说成「0 条」）"
            ));
        }
        Ok(CspList {
            items,
            page,
            page_count: None,
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
        Err(match UrlPanKind::of(url) {
            Some(kind) => format!(
                "这条是{}分享页（不是媒体流）：本仓还没有它的分享→直链转换（T1b 取证后接入）\
                 ⇒ 暂时放不了；浏览与搜索不受影响",
                kind.label()
            ),
            None => format!(
                "这条分享链接认不出是哪家网盘（{url}），本仓无法在无账号的情况下转直链 ⇒ 不伪造播放地址"
            ),
        })
    }
}

/// 把关键词编码成**路径段**（与 `pan_web_share::encode_path` 同一口径，不引新依赖）
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
//  ★ 自注册（判据三条同时成立：①订阅 1 站 ②host 可用 ③真网取到数据）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// ① 订阅：`csp_Wogg` = 1 站（`.probe/ref-subscription.json`：玩耦｜4K臻享）
// ② host：ext.site 给了 4 个镜像，其中 2 个真连上（wogg.live / wogg.net）
// ③ 真网：home 8 分类 + 70 条目；list 70 条；search 13 条；detail 2 条网盘分享
// ⇒ 注册
// ```
crate::csp::register_site!(Wogg);

// ═══════════════════════════════════════════════════════════════════════
//  测试（纯函数喂**真响应片段**，不发网络）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 真站首页导航片段（2026-10-28 直连 `http://www.wogg.live/` 抓取，逐字）
    const HOME_NAV: &str = r#"<ul class="nav-menu-items"><li class="nav-menu-item selected"><a href="/" class="black" title="首页"><i class="icon-home"></i>首页</a></li><li class="nav-menu-item"><a class="nav-link black" href="/vodtype/1.html"><i class="icon-cate-dy"></i>玩偶电影</a></li><li class="nav-menu-item"><a class="nav-link black" href="/vodtype/2.html"><i class="icon-cate-ds"></i>玩偶剧集</a></li><li class="nav-menu-item"><a class="nav-link black" href="/vodtype/44.html"><i class="icon-cate-dy"></i>臻彩视界</a></li><li class="nav-menu-item"><a class="nav-link black" href="/vodtype/6.html"><i class="icon-cate-ds"></i>短漫剧</a></li></ul>"#;

    /// 真站首页条目片段（同上，逐字）
    const HOME_ITEM: &str = r#"<div class="module-item"><div class="module-item-cover"><div class="module-item-pic"><a href="/voddetail/133274.html" title="坏爸爸" ><i class="icon-play"></i></a><img class="lazy lazyloaded" data-src="https://gimg0.baidu.com/gimg/app=2001&amp;n=0&amp;g=0n&amp;fmt=jpeg&amp;src=p.bfvp26.com/upload/vod/20261027-1/e10b79f7072686d7c6.jpg"></div></div><div class="module-item-titlebox"><a href="/voddetail/133274.html" class="module-item-title" title="坏爸爸">坏爸爸</a></div><div class="module-item-text">更新至HD</div></div>"#;

    /// 真站详情片段（`http://www.wogg.live/voddetail/133277.html`，逐字）
    ///
    /// ★ 真页面上**每个分享链接会出现两次**（行内"复制" + 右下"复制链接"），
    ///   两条都是 `data-clipboard-text` —— 这里保留两次，正是为了钉住"按 URL 去重"。
    const DETAIL: &str = r#"<div class="video-info"><div class="video-info-header"><h1 class="page-title">马修·派瑞：老友最后的传记</h1><h2 class="video-subtitle" title="maxiupairui">maxiupairui</h2></div></div><p class="sqjj_a" style="display: none;">纪录片主要聚焦于亲友的私密讲述。</p><div class="module-list module-player-list sort-list module-downlist selected"><div class="module-row-one"><div class="module-row-info"><a class="module-row-text copy" href="javascript:;" data-clipboard-text="https://pan.quark.cn/s/51880600c229"><div class="module-row-title"><h4>马修·派瑞 - 玩偶哥哥</h4></div></a><a class="btn-copyurl copy" href="javascript:;" data-clipboard-text="https://pan.quark.cn/s/51880600c229"><span>复制链接</span></a><a class="btn-pc btn-down fzlj" href="https://pan.baidu.com/s/1scKULHdo1ewUUu4QVZBgZQ?pwd=wogg" data-clipboard-text="https://pan.baidu.com/s/1scKULHdo1ewUUu4QVZBgZQ?pwd=wogg" title="打开"><span>打开</span></a><a class="btn-copyurl copy" href="javascript:;" data-clipboard-text="https://pan.baidu.com/s/1scKULHdo1ewUUu4QVZBgZQ?pwd=wogg"><span>复制链接</span></a></div></div></div>"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Wogg::CLASS, "Wogg");
    }

    #[test]
    fn sites_of_reads_site_array_and_string_form() {
        let a = Wogg::sites_of(
            r#"{"site":["https://a.example","http://b.example/","https://a.example"]}"#,
        );
        assert_eq!(a, vec!["https://a.example".to_string(), "http://b.example".to_string()]);
        let b = Wogg::sites_of(r#"{"site":"https://c.example"}"#);
        assert_eq!(b, vec!["https://c.example".to_string()]);
        // 字符串形态（非 JSON）
        let c = Wogg::sites_of("https://d.example, https://e.example");
        assert_eq!(c, vec!["https://d.example".to_string(), "https://e.example".to_string()]);
        assert!(Wogg::sites_of("").is_empty());
    }

    #[test]
    fn parse_categories_from_real_home_fragment() {
        let cats = parse_categories(HOME_NAV);
        assert_eq!(cats.len(), 4, "真站导航 4 个分类：{cats:?}");
        assert_eq!(cats[0], CspCategory { id: "1".into(), name: "玩偶电影".into() });
        assert_eq!(cats[2].id, "44");
        assert_eq!(cats[2].name, "臻彩视界");
        // 退路：nav 缺失时读 tab 的 data-id/data-name（DEX 就是这么读的）
        let tab = r#"<span class="module-tab-item tab-item" data-id="6" data-name="短漫剧">短漫剧</span>"#;
        assert_eq!(parse_categories(tab)[0].id, "6");
        assert!(parse_categories("<html></html>").is_empty());
    }

    #[test]
    fn parse_items_from_real_fragment_dedupes_by_id() {
        let items = parse_items(&format!("{HOME_ITEM}{HOME_ITEM}"));
        assert_eq!(items.len(), 1, "同一 id 只出一条：{items:?}");
        assert_eq!(items[0].id, "133274");
        assert_eq!(items[0].title, "坏爸爸");
        assert!(items[0]
            .cover
            .as_deref()
            .unwrap_or("")
            .starts_with("https://gimg0.baidu.com"));
        assert!(parse_items("<html></html>").is_empty());
    }

    /// ★ 契约第 1 条：首页解析出 0 条 ⇒ Err（不许 Ok(空)）
    #[test]
    fn home_with_zero_parsed_is_error() {
        let e = home_from_html("<html><body>维护中</body></html>").expect_err("0 分类必须 Err");
        assert!(e.contains("没解析出任何分类"), "{e}");
        // 只有分类、没有条目 ⇒ 也要 Err（首屏不能静默空着）
        let e2 = home_from_html(HOME_NAV).expect_err("0 条目必须 Err");
        assert!(e2.contains("没解析出任何条目"), "{e2}");
        // 齐全 ⇒ Ok
        let ok = home_from_html(&format!("{HOME_NAV}{HOME_ITEM}")).expect("分类+条目都有");
        assert_eq!(ok.categories.len(), 4);
        assert_eq!(ok.items.len(), 1);
    }

    #[test]
    fn list_with_zero_items_is_error() {
        let e = list_from_html("<html>403</html>", 1, "分类 1").expect_err("0 条必须 Err");
        assert!(e.contains("风控壳页") || e.contains("模板可能已改版"), "{e}");
        let ok = list_from_html(HOME_ITEM, 2, "分类 1").expect("有条目");
        assert_eq!(ok.page, 2);
        assert_eq!(ok.items.len(), 1);
    }

    #[test]
    fn detail_parses_title_cover_and_share_links() {
        let d = detail_from_html(DETAIL, "133277");
        assert_eq!(d.title, "马修·派瑞：老友最后的传记");
        assert!(d.description.as_deref().unwrap_or("").contains("纪录片主要聚焦"));
        // 同一个夸克链接出现 2 次 ⇒ 去重后 1 条；百度链接 1 条 ⇒ 共 2 条
        assert_eq!(d.episodes.len(), 2, "{:?}", d.episodes);
        assert_eq!(d.episodes[0].id, "pan|https://pan.quark.cn/s/51880600c229");
        assert_eq!(d.episodes[0].title, "夸克网盘");
        assert_eq!(d.episodes[1].title, "百度网盘");
        assert_eq!(d.episodes[1].flag, "百度网盘");
    }

    #[test]
    fn detail_without_share_links_is_reported_by_caller() {
        // 纯函数不报错；**调用点**按契约把"0 集"变成 Err（见 CspSite::detail）
        let d = detail_from_html("<html><h1 class=\"page-title\">x</h1></html>", "1");
        assert!(d.episodes.is_empty());
        let flat = crate::csp::shared::impl_src_only(include_str!("wogg.rs"));
        assert!(flat.contains("d.episodes.is_empty()"), "★ 详情 0 集必须在调用点 Err");
    }

    #[test]
    fn summarize_failures_keeps_head_and_total() {
        let fails: Vec<String> = (0..5).map(|i| format!("https://m{i}：connect refused")).collect();
        let s = summarize_failures(&fails, 5);
        assert!(s.contains("试了 5 个镜像"), "{s}");
        assert!(s.contains("https://m0"), "★ 必须列前 N 条，不能只留最后一条：{s}");
        assert!(s.contains("另有 2 条同因失败"), "{s}");
        assert!(!s.contains("https://m4"), "第 4 条之后只报数量：{s}");
    }

    #[test]
    fn http_client_disables_proxy_after_timeout() {
        let flat = crate::csp::shared::impl_src_only(include_str!("wogg.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("必须设 timeout");
        let p = flat.find(".no_proxy()").expect("★ 必须 .no_proxy()");
        let b = flat.find(".build()").expect("必须 build");
        assert!(t < p && p < b, "★ 顺序必须是 timeout → no_proxy → build");
    }

    #[test]
    fn wogg_is_registered() {
        assert!(
            crate::csp::is_implemented("csp_Wogg"),
            "★ 判据三条都成立（订阅 1 站 / host 可用 / 真网有数据）⇒ 必须注册"
        );
        let flat = crate::csp::shared::impl_src_only(include_str!("wogg.rs"));
        assert!(flat.contains("register_site!(Wogg)"));
    }

    /// ★★★ T1a 门禁（2026-10-31）：夸克/UC 分享页交回**原生直链转换**；其它族维持如实 Err
    ///
    /// # 夹具来源（真网抓取，lead 条件①：不许自造）
    /// ```text
    /// wogg 114504「老舅（臻彩）」详情页（https://www.wogg.net/voddetail/114504.html）
    /// 2026-10-31 真抓：UC 带 ?public=1（audit n=115 的实际族）、夸克、百度 ?pwd=wogg。
    /// play 的分享分支是纯本地判断（不打网络）⇒ 离线可测。
    /// ```
    #[tokio::test]
    async fn play_hands_quark_uc_share_pages_to_native_conversion() {
        let site = Wogg::new();
        let got = site
            .play("", "pan|https://drive.uc.cn/s/8e1d7a0ade134?public=1", "")
            .await
            .expect("UC 分享页要交回原生转换");
        assert_eq!(got[0].url, "https://drive.uc.cn/s/8e1d7a0ade134?public=1");
        let got = site
            .play("", "pan|https://pan.quark.cn/s/384ca6d78a7b", "")
            .await
            .expect("夸克分享页要交回原生转换");
        assert_eq!(got[0].url, "https://pan.quark.cn/s/384ca6d78a7b");
        let got = site
            .play("", "pan|https://pan.baidu.com/s/1iLOQ464Uz5Q3MYQ3Qu0y9w?pwd=wogg", "")
            .await
            .expect("百度应交给已接管的宿主检查解析");
        assert!(got[0].label.as_deref().unwrap().contains("宿主检查解析"));
    }

    /// 接线断言：play 的分享分支必须真的走 share_page_play（不许只改文案）
    ///
    /// ```text
    /// ★ 断言完整的 `if let Some(p) = …` 守卫形态 —— 只 contains 调用串的话，
    ///   把调用包进 `if false {}` 注入也能骗过（T1a 证红实测抓到的假绿）。
    /// ```
    #[test]
    fn play_wires_share_page_play() {
        let src = include_str!("wogg.rs");
        let prod = src.split("#[cfg(test)]").next().unwrap_or("");
        assert!(
            prod
                .contains("if let Some(p) = crate::csp::pan_share_play::share_page_play(url, UA)"),
            "play 必须以 if-let 守卫把夸克/UC 分享页交给 share_page_play（原生转换入口）"
        );
    }

    /// 真网络（`#[ignore]`，必须显式点名 + `CSP_LIVE=1`；不设变量就 assert 失败）
    ///
    /// ```text
    /// CSP_LIVE=1 cargo test --lib csp::wogg:: -- --ignored --nocapture
    /// ```
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp::wogg:: -- --ignored --nocapture"]
    async fn csp_live_wogg_home_list_search_detail() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：显式跑就必须给 CSP_LIVE=1（不给就失败，不许记成 ok）"
        );
        // 订阅原文的 ext（4 镜像）
        const EXT: &str = r#"{"site":["https://wogg.xxooo.cf","http://www.wogg.live","https://www.wogg.net","https://woggpan.xxooo.cf"]}"#;
        let site = Wogg::new();

        let home = site.home(EXT).await.expect("home 应成功（至少一个镜像可用）");
        eprintln!(
            "[LIVE] Wogg home: {} 分类 / {} 条目; 前3分类={:?}",
            home.categories.len(),
            home.items.len(),
            home.categories.iter().take(3).map(|c| format!("{}:{}", c.id, c.name)).collect::<Vec<_>>()
        );
        assert!(!home.categories.is_empty());
        assert!(!home.items.is_empty());

        let tid = home.categories[0].id.clone();
        let list = site.list(&tid, 1, EXT).await.expect("list 应成功");
        eprintln!("[LIVE] Wogg list({tid}) ⇒ {} 条", list.items.len());
        assert!(!list.items.is_empty());

        let kw = "玩偶";
        let found = site.search(kw, 1, EXT).await.expect("search 应成功");
        eprintln!("[LIVE] Wogg search({kw}) ⇒ {} 条", found.items.len());
        assert!(!found.items.is_empty());

        let id = home.items[0].id.clone();
        let d = site.detail(&id, EXT).await.expect("detail 应成功");
        eprintln!(
            "[LIVE] Wogg detail({id}) ⇒ 标题={:?} 简介前60={:?} 分享 {} 条",
            d.title,
            d.description.as_deref().unwrap_or("").chars().take(60).collect::<String>(),
            d.episodes.len()
        );
        for e in d.episodes.iter().take(3) {
            eprintln!("[LIVE]   - {} {}", e.flag, e.id);
        }
        assert!(!d.episodes.is_empty());
    }
}
