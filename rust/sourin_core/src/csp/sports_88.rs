// ═══════════════════════════════════════════════════════════════════════
//  csp_Sports88 —— 「88 看球」（www.88kanqiu.la）的 Rust 重写（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ 为什么**没有** `register_site!`（三条判据里第 ③ 条不成立）
// ```text
// ① 订阅里 1 站：`.probe/ref-subscription.json` → api=csp_Sports88（ext 为 null）     ✅
// ② 有可用 host：DEX 常量 `http://www.88kanqiu.la`（今天仍 301 → https，200 / 147KB）  ✅
// ③ **真网真的取到数据**：home/list **有**（60 场，字段齐），但 **detail/play 取不到**
//    —— 见下面"取证"，线路是**混淆脚本渲染**的，静态 HTML 里没有 ✅❌
// ⇒ 按纪律：缺任一条**不注册**；实现照写、按真实形状写，失败时给可读 Err。
// ```
//
// # 取证（2026-10-28 00:0x，全部 `--noproxy '*'` 直连；原始行在 `.probe/csp-sports-live.log`）
// ```text
// · GET /                              → 200 · 147066 B · 60 个 `.group-game-item`
//   其中 1 场是**直播中**（`<a class="btn btn-primary" href='/live/130323/play'>直播中`）
// · GET /live/130323/play              → 200 · 25178 B
//   ★ 页面里 `#livePlaySource` 是**空的**：`<div id="livePlaySource" class="list-group"></div>`
//   ★ 全页 **0 处 `m3u8`**、**0 处 `.btn.btn-primary`**（直播中的那场也没有）
//   ⇒ 线路由页面底部那段 **jsjiami.com.v7 混淆脚本**在浏览器里渲染；
//     一个不执行 JS 的 Spider **拿不到**（这正是 DEX 里 `.btn.btn-primary` 选择器现在失效的原因：
//     站点改版了 —— 旧版是服务端直出按钮，现在是 SPA 式渲染）
// · 试过的取数端点（全 404，不是"我打错了"：路径是照页面/JS 里出现过的形状拼的）
//     /api/live/130323/play · /api/live/130323 · /api/match/130323/lines
//     /live/130323/lines · /api/v1/live/130323 · /live/130323/play?format=json(200 但仍是 HTML)
// ```
//
// # 协议（DEX 常量逐字；home/list 已实测，detail/play 按 DEX 选择器写但**当前站点取不到**）
// ```text
// home    GET {host}/                       → `.category-nav a[href='/match/<id>/live']` 分类
//                                             `.list-group-item.group-game-item` 条目
// list    GET {host}/match/{cateId}/live     （DEX 的 `/match/%s/live`）
// detail  GET {host}/live/{mid}/play         → 标题/队伍/状态（**能取到**）
//                                             `.btn.btn-primary` 的 href（**当前站点没有**）
// play    把 href 当线路地址返回（**当前站点取不到 href ⇒ 走 Err**）
// ```
//
// # 改前错在哪
// ```text
// · 只看首页 http=200 就判"站点活着、类可用" ⇒ 假活：首页是服务端渲染的（有 60 场），
//   而**详情页是 JS 渲染的**。两个页面的可用性根本不是一回事。
// · 把 `/live/{mid}/play` 这个**页面 URL** 当"可播地址"返回 ⇒ 用户拿到的是 HTML 页，
//   播放器只会报"格式不支持"（典型的"假通"）。本实现明确拒绝。
// ```

use async_trait::async_trait;
use regex::Regex;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `init()` 的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// DEX 常量里的 host（逐字，`http://`；今天 301 到 https，客户端跟随即可）
pub const DEFAULT_HOST: &str = "http://www.88kanqiu.la";

/// DEX 里 play 前的判断文案（逐字）：这一场没开始/没线路
pub const NOT_STARTED: &str = "比赛尚未开始";

const TIMEOUT: Duration = Duration::from_secs(25);

/// DEX 的 4 个固定分类（id, 名字）：`4`/`23`/`21` 与"全部"
///
/// ⚠️ 与 live 导航**并存**：live 导航里每个联赛都有自己的 cateId（1=NBA、8=英超…），
/// DEX 这 4 个是旧版的粗分类。本实现以 live 导航为准，DEX 这 4 个只在导航解析失败时兜底。
pub const DEX_CATS: &[(&str, &str)] =
    &[("", "全部直播"), ("23", "篮球直播"), ("21", "足球直播"), ("4", "其他直播")];

pub fn host_of(ext: &str) -> String {
    let t = ext.trim();
    if t.starts_with("http://") || t.starts_with("https://") {
        return t.trim_end_matches('/').to_string();
    }
    if let Ok(j) = crate::tvbox::parse_loose_json(t) {
        for k in ["host", "site", "base"] {
            if let Some(s) = j.get(k).and_then(|v| v.as_str()) {
                let s = s.trim().trim_end_matches('/');
                if !s.is_empty() {
                    return s.to_string();
                }
            }
        }
    }
    DEFAULT_HOST.to_string()
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

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

/// 分类：live 导航（`/match/<id>/live`）+ 首项"全部直播"
pub fn parse_categories(html: &str) -> Vec<CspCategory> {
    let mut cats: Vec<CspCategory> =
        vec![CspCategory { id: String::new(), name: "全部直播".to_string() }];
    let re = Regex::new(
        r#"(?s)href='/match/(\d+)/live'[^>]*>\s*(?:<img[^>]*>\s*)?([^<]{1,40})"#,
    )
    .unwrap();
    for c in re.captures_iter(html) {
        let id = c.get(1).map(|m| m.as_str()).unwrap_or("");
        let name = c.get(2).map(|m| unescape(m.as_str())).unwrap_or_default();
        if id.is_empty() || name.is_empty() {
            continue;
        }
        if cats.iter().any(|x| x.id == id) {
            continue;
        }
        cats.push(CspCategory { id: id.to_string(), name });
    }
    if cats.len() <= 1 {
        // 导航解析失败 ⇒ 用 DEX 的 4 个固定分类兜底（至少不是"零分类"）
        return DEX_CATS
            .iter()
            .map(|(id, n)| CspCategory { id: (*id).to_string(), name: (*n).to_string() })
            .collect();
    }
    cats
}

/// 直播条目：`li.group-game-item`（**跳过**分隔用的 `live-list-group-time` 日期行）
pub fn parse_items(html: &str, where_: &str) -> Result<Vec<CspItem>, String> {
    let block = Regex::new(r#"(?s)<li class="list-group-item group-game-item">(.*?)</li>"#).unwrap();
    let teams = Regex::new(r#"(?s)class="team-name"[^>]*title="([^"]*)""#).unwrap();
    // ★ 真实标记是 `class="col-md-1 category-game-time"` —— **不是** `class="category-game-time"`。
    //   按整段 class 匹配会一条都取不到（而条目本身仍然解析出来 ⇒ 看起来"只有时间缺失"的静默错）。
    let time = Regex::new(r#"(?s)class="[^"]*\bcategory-game-time\b[^"]*">\s*([0-9:]{0,8})"#).unwrap();
    let league = Regex::new(r#"(?s)class="game-type">([^<]*)</span>"#).unwrap();
    let play = Regex::new(r#"(?s)href='(/live/(\d+)/play)'"#).unwrap();
    let btn = Regex::new(r#"(?s)<a[^>]*class="btn ([^"]*)"[^>]*>\s*([^<]*)"#).unwrap();
    let mut items = Vec::new();
    for c in block.captures_iter(html) {
        let body = c.get(1).map(|m| m.as_str()).unwrap_or("");
        let names: Vec<String> =
            teams.captures_iter(body).map(|m| unescape(&m[1])).filter(|s| !s.is_empty()).collect();
        let mid = play
            .captures(body)
            .and_then(|m| m.get(2))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default();
        if mid.is_empty() || names.is_empty() {
            continue;
        }
        let title = if names.len() >= 2 {
            format!("{} vs {}", names[0], names[1])
        } else {
            names[0].clone()
        };
        let mut sub = String::new();
        if let Some(t) = time.captures(body).and_then(|m| m.get(1)).map(|m| m.as_str().trim().to_string()) {
            if !t.is_empty() {
                sub.push_str(&t);
            }
        }
        if let Some(l) = league.captures(body).and_then(|m| m.get(1)) {
            if !sub.is_empty() {
                sub.push(' ');
            }
            sub.push_str(unescape(l.as_str()).trim());
        }
        // 按钮文案就是状态（"直播中" / "暂无"）—— DEX 的 `.btn.btn-primary` 只标"能点"
        if let Some(b) = btn.captures(body) {
            let cls = b.get(1).map(|m| m.as_str()).unwrap_or("");
            let text = b.get(2).map(|m| m.as_str().trim().to_string()).unwrap_or_default();
            if !text.is_empty() {
                if !sub.is_empty() {
                    sub.push(' ');
                }
                sub.push_str(&text);
            }
            if cls.contains("btn-primary") && !sub.ends_with("直播中") {
                sub.push_str(" 直播中");
            }
        }
        items.push(CspItem {
            id: mid,
            title,
            cover: None,
            subtitle: if sub.trim().is_empty() { None } else { Some(sub.trim().to_string()) },
        });
    }
    if items.is_empty() {
        return Err(format!(
            "{where_} 没解析出比赛（页面 {} 字节）——可能站点改版/风控壳页：\
             `li.list-group-item.group-game-item` 里一个 `href='/live/<id>/play'` 都没有",
            html.len()
        ));
    }
    Ok(items)
}

/// 详情页能拿到的部分（标题/队伍/状态）+ 线路（`.btn.btn-primary`）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetailPage {
    pub title: String,
    pub status: Option<String>,
    pub lines: Vec<String>,
}

pub fn parse_detail_page(html: &str) -> Result<DetailPage, String> {
    let title = Regex::new(r"(?s)<title>\s*([^<_]{1,80}?)\s*_")
        .unwrap()
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unescape(m.as_str()))
        .unwrap_or_default();
    let status = Regex::new(r#"(?s)<p class="lred">\s*([^<]*)"#)
        .unwrap()
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|m| unescape(m.as_str()))
        .filter(|s| !s.is_empty());
    let line_re =
        Regex::new(r#"(?s)<a[^>]*class="btn btn-primary"[^>]*href=['"]([^'"]+)['"]"#).unwrap();
    let mut lines: Vec<String> = Vec::new();
    for c in line_re.captures_iter(html) {
        let href = c.get(1).map(|m| m.as_str().trim().to_string()).unwrap_or_default();
        if href.is_empty() || lines.iter().any(|l| *l == href) {
            continue;
        }
        lines.push(href);
    }
    if title.is_empty() {
        return Err(format!(
            "详情页没有 <title>（页面 {} 字节）——可能站点改版/风控壳页",
            html.len()
        ));
    }
    Ok(DetailPage { title, status, lines })
}

// ══ ⚠️ **没有 `register_site!`**（判据③不成立，见文件头取证）══

pub struct Sports88 {
    client: reqwest::Client,
}

impl Sports88 {
    pub const CLASS: &'static str = "Sports88";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build sports_88 http client");
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

impl Default for Sports88 {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for Sports88 {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = host_of(ext);
        let html = self.get_text(&format!("{host}/")).await?;
        let categories = parse_categories(&html);
        let items = parse_items(&html, "首页直播列表")?;
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let cate = tid.trim();
        let host = host_of(ext);
        let page = if page == 0 { 1 } else { page };
        if page > 1 {
            // DEX 的路径模板没有页码位；页面按日期分组，没有 page 参数
            return Err(format!("Sports88 不支持翻页（路径模板 `/match/%s/live` 无页码位，请求的是第 {page} 页）"));
        }
        let url = if cate.is_empty() {
            format!("{host}/")
        } else {
            format!("{host}/match/{cate}/live")
        };
        let html = self.get_text(&url).await?;
        let items = parse_items(&html, &format!("分类 {cate} 第 1 页"))?;
        Ok(CspList { items, page: 1, page_count: None, total: None })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let _ = (kw, page, ext);
        Err("Sports88 不支持搜索（DEX 里 8 个方法没有 searchContent；站点也没有搜索入口）"
            .to_string())
    }

    fn supports_search(&self) -> bool {
        false
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let mid = id.trim();
        if mid.is_empty() {
            return Err("Sports88 detail 的 id（mid）为空".to_string());
        }
        let host = host_of(ext);
        let html = self.get_text(&format!("{host}/live/{mid}/play")).await?;
        let p = parse_detail_page(&html)?;
        if p.lines.is_empty() {
            // ★ 这就是本类**不注册**的那条证据：详情页拿得到标题，但拿不到线路
            return Err(format!(
                "「{}」没有可播线路（{}）：线路由页面里的 jsjiami 混淆脚本在浏览器里渲染，\
                 静态 HTML 里 `.btn.btn-primary` 与 `m3u8` 都是 0 处（{} 字节）⇒ 不伪造剧集",
                p.title,
                p.status.clone().unwrap_or_else(|| NOT_STARTED.to_string()),
                html.len()
            ));
        }
        let episodes: Vec<CspEpisode> = p
            .lines
            .iter()
            .enumerate()
            .map(|(i, href)| CspEpisode {
                id: href.clone(),
                title: format!("线路{}", i + 1),
                flag: "直播".to_string(),
            })
            .collect();
        Ok(CspDetail {
            id: mid.to_string(),
            title: p.title,
            cover: None,
            description: p.status,
            episodes,
        })
    }

    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let host = host_of(ext);
        let raw = id.trim();
        if raw.is_empty() {
            return Err("Sports88 play 的 id 为空".to_string());
        }
        let url = if raw.starts_with("http") {
            raw.to_string()
        } else if raw.starts_with('/') {
            format!("{host}{raw}")
        } else {
            return Err(format!("Sports88 play 的 id 既不是 URL 也不是站点路径：{}", head(raw)));
        };
        // ★ 拒绝把"播放页"当"流地址"：那是假通（用户拿到 HTML，播放器只会报格式不支持）
        let lower = url.to_lowercase();
        if lower.ends_with("/play") || !(lower.contains(".m3u8") || lower.contains(".mp4")) {
            return Err(format!(
                "Sports88 这条线路不是媒体地址（{}）——站点现在只给播放页/由 JS 渲染的地址，\
                 本实现不把页面 URL 当流地址（假通）",
                head(&url)
            ));
        }
        Ok(vec![CspPlay {
            url,
            headers: vec![("Referer".to_string(), format!("{host}/"))],
            label: Some(if flag.trim().is_empty() { "直播".to_string() } else { flag.to_string() }),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实首页片段（2026-10-28 00:0x 直连抓的：live 导航两项 + 两场比赛，
    /// 其中第二场是"直播中"；换行与属性顺序**原样**）
    const REAL_HOME: &str = r#"<ul class="category-nav nav nav-pills nav-stacked live-nav-pills">
    <li class="active">
        <a class="all" href="/">全部直播</a>
    </li>
    <li class="">
        <a style="padding: 0 15px;" href='/match/1/live'>
            <img class="lazyload" src="/static/img/default.png" alt="NBA"
                 referrerPolicy="no-referrer" width="45px"
                 data-src="https://mat1.gtimg.com/sports/sportapp/liansai_logo/NBA.png">NBA
        </a>
    </li>
</ul>
<ul class="list-group">
    <li class="list-group-item live-list-group-time">
        <span class="date"></span>
        2026-10-28
    </li>
    <li class="list-group-item group-game-item">
        <div style="padding:0 17px" class="row">
            <div class="row d-none d-lg-flex">
                <div class="col-md-1 category-game-time">00:00
                </div>
                <div class="col-md-3">
                    <div class=""><span class="game-type">亚冠联2</span></div>
                </div>
                <div class="col-md-4 text-right">
                    <span class="team-name" title="锡卜">锡卜</span>
                </div>
                <div class="col-md-1 text-center">VS</div>
                <div class="col-md-3 text-left">
                    <span class="team-name" title="东孟加拉">东孟加拉</span>
                </div>
                <div data-id="130322" class="col-md-3 pay-btn text-right">
                    <a class="btn btn-default btn-disabled " href='/live/130322/play' role="button">暂无</a>
                </div>
            </div>
        </div>
    </li>
    <li class="list-group-item group-game-item">
        <div style="padding:0 17px" class="row">
            <div class="row d-none d-lg-flex">
                <div class="col-md-1 category-game-time">23:30
                </div>
                <div class="col-md-3"><div class=""><span class="game-type">伊朗超</span></div></div>
                <div class="col-md-4 text-right"><span class="team-name" title="德黑兰独立">德黑兰独立</span></div>
                <div class="col-md-1 text-center">VS</div>
                <div class="col-md-3 text-left"><span class="team-name" title="塞帕汉">塞帕汉</span></div>
                <div data-id="130323" class="col-md-3 pay-btn text-right">
                    <a target="_blank" class="btn btn-primary" href='/live/130323/play' role="button">直播中<i class="glyphicon glyphicon-play"></i></a>
                </div>
            </div>
        </div>
    </li>
</ul>"#;

    /// 真实详情页（直播中的那场）里的 `<title>` 与 `#livePlaySource`（**空的**，这是关键证据）
    const REAL_DETAIL: &str = r#"<!DOCTYPE html>
<html><head>
    <title>锡卜 vs 东孟加拉_视频直播_亚冠直播</title>
</head><body>
    <div class="game-videos-btn-container">
        <div>
            <div id="livePlaySource" class="list-group" role="group" aria-label="...">
            </div>
        </div>
    </div>
    <input type="hidden" id="gameId" value="130322">
</body></html>"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Sports88::CLASS, "Sports88");
    }

    /// ★ 本批**不注册**（判据③不成立），把这条做成断言，防止下一个人"顺手注册"
    #[test]
    fn must_not_be_registered_this_batch() {
        assert!(
            !crate::csp::is_implemented("csp_Sports88"),
            "★ 详情/取流取不到（线路由混淆 JS 渲染）⇒ 不许进注册表"
        );
        let flat = crate::csp::shared::impl_src_only(include_str!("sports_88.rs"));
        assert!(!flat.contains("register_site!(Sports88)"), "★ 本批 Sports88 不注册");
    }

    #[test]
    fn home_fragment_parses_real_response() {
        let cats = parse_categories(REAL_HOME);
        assert_eq!(cats[0].name, "全部直播");
        assert!(cats.iter().any(|c| c.id == "1" && c.name == "NBA"), "live 导航要解析出联赛");

        let items = parse_items(REAL_HOME, "test").expect("真实片段必须能解析");
        assert_eq!(items.len(), 2, "日期分隔行不算条目");
        assert_eq!(items[0].id, "130322");
        assert_eq!(items[0].title, "锡卜 vs 东孟加拉");
        assert!(items[0].subtitle.as_deref().unwrap_or("").contains("00:00"));
        assert!(items[0].subtitle.as_deref().unwrap_or("").contains("亚冠联2"));
        assert!(items[1].subtitle.as_deref().unwrap_or("").contains("直播中"), "{:?}", items[1].subtitle);
    }

    /// ★ 空结果必须 Err（诚实契约第 1 条）
    #[test]
    fn shell_page_is_an_error_not_an_empty_list() {
        let shell = "<html><body><ul class=\"list-group\"><li class=\"list-group-item live-list-group-time\">2026-10-28</li></ul>风控</body></html>";
        let e = parse_items(shell, "分类 1 第 1 页").expect_err("★ 0 场必须 Err");
        assert!(e.contains("风控壳页"), "{e}");
        assert!(parse_items(REAL_HOME, "ok").is_ok(), "反面：真片段不许被判空");
    }

    /// ★ 详情页的现实：标题拿得到、线路**没有**（这就是判据③不成立的原样证据）
    #[test]
    fn detail_page_has_title_but_no_lines() {
        let p = parse_detail_page(REAL_DETAIL).expect("真实详情必须能解析出标题");
        assert!(p.title.starts_with("锡卜 vs 东孟加拉"), "{}", p.title);
        assert!(p.lines.is_empty(), "★ 当前站点详情页没有 .btn.btn-primary（线路由混淆 JS 渲染）");
        // 反面：放一个旧版形态进去，解析器要认（证明"线路 0 条"不是我正则写错导致的恒空）
        let old = REAL_DETAIL.replace(
            r#"<div id="livePlaySource" class="list-group" role="group" aria-label="...">
            </div>"#,
            r#"<a class="btn btn-primary" href="https://live.example/x.m3u8">线路1</a>"#,
        );
        let p2 = parse_detail_page(&old).expect("旧版形态要能解析");
        assert_eq!(p2.lines, vec!["https://live.example/x.m3u8".to_string()]);
    }

    #[test]
    fn play_refuses_a_page_url_instead_of_pretending() {
        let s = Sports88::new();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let e = rt
            .block_on(s.play("直播", "/live/130322/play", ""))
            .expect_err("★ 页面 URL 必须 Err（假通）");
        assert!(e.contains("不是媒体地址"), "{e}");
        // 真流地址则放行
        let ok = rt.block_on(s.play("直播", "https://cdn.example/a.m3u8", "")).expect("m3u8 要放行");
        assert_eq!(ok[0].url, "https://cdn.example/a.m3u8");
        assert!(ok[0].headers.iter().any(|(k, _)| k == "Referer"));
    }

    /// ★ 真网络（默认 ignore）：读数只作取证，不影响"不注册"的结论
    #[tokio::test]
    #[ignore = "真网络：直连 www.88kanqiu.la（不走系统代理），人工触发"]
    async fn live_home_list_and_detail_evidence() {
        let s = Sports88::new();
        let home = s.home("").await.expect("★ live: home 必须取到条目（首页是服务端渲染的）");
        println!(
            "LIVE Sports88 home cats={} items={} first={}",
            home.categories.len(),
            home.items.len(),
            home.items[0].title
        );
        let list = s.list("1", 1, "").await.expect("★ live: NBA 分类页");
        println!("LIVE Sports88 list cat=1 n={} first={}", list.items.len(), list.items[0].title);
        let d = s.detail(&home.items[0].id, "").await;
        match d {
            Ok(d) => println!("LIVE Sports88 detail title={} eps={}", d.title, d.episodes.len()),
            Err(e) => println!("LIVE Sports88 detail Err(如实): {e}"),
        }
    }
}
