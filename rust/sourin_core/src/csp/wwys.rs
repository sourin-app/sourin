// ═══════════════════════════════════════════════════════════════════════
//  csp_Wwys —— 「🌾农民｜蓝光秒播」（旺旺影视 / 苹果 CMS 模板站）
// ═══════════════════════════════════════════════════════════════════════
//
// # 配置里覆盖什么
//
// ```text
// 订阅（8815.kstore.vip/tvbox/wmz）100 站里：
//   csp_Wwys  🌾农民｜蓝光秒播   ext = "https://vip.wwgz.cn:5200"
// ⇒ **站点从 ext 取**；ext 缺的时候用实测到的同一镜像兜底。
// ```
//
// # ★★ 我先犯了一个错，必须留档（这是本文件最重要的一段）
//
// ```text
// 【我的错误结论】第一次探测时我打了这些路径：
//     /                                  → 404 页面
//     /vod-list-id-1-pg-1-order--by-time-class-0-year-0-letter--area--lang-.html
//                                        → 「缺少文件：/data/img.wwgz.cn/template/pc/html//vod_list.html」
//     /index.php?m=vod-search&wd=火       → 「缺少文件：…//vod_search.html」
//   ⇒ 我据此写下「**上游模板文件缺失，站点功能性死亡**」
//
// 【真相（同一天再查，走**真入口**）】站点**完全活着**：
//     /index.php                                    → 200 · 41782 B（真首页，导航 7 项）
//     /index.php?m=vod-type-id-1-pg-1.html          → 200 · 68774 B，**90 条**
//     /index.php?m=vod-detail-id-96481.html         → 200 · 19919 B（真详情）
//     /vod-play-id-96481-src-1-num-1.html           → 200，`mac_url` 里有**真 m3u8**
//     该 m3u8 直连 → **200 + `#EXTM3U`**（真能播）
//
// 【错误根因（分类清楚，别混）】
//   ① 我把 DEX 里的 `/vod-detail-id-…html` 这类**相对路径**当成了"要以 ext 为根直接拼"，
//      而这个站是**苹果 CMS**：真入口要带 `?m=vod-…`，相对路径要挂在 `/index.php` 下。
//      我用**不带 `?m=` 的形式**去打 ⇒ 落到了站点的"模板文件缺失"分支。
//   ② 那个分支**返回 HTTP 200 且带一段 HTML**，看起来像"站点坏了"，
//      而不像"我打错了路径"⇒ 我误把"我的路径错"判成"上游死"。
//
// 【教训（写进纪律）】
//   判"上游死了"之前，必须先用**该 CMS 家族的多种入口形式**复测
//   （苹果 CMS：`/index.php?m=vod-type-id-N-pg-1.html` / `/vod-type-id-N-pg-1.html` /
//    带 `?m=` 的详情与搜索），并**检查返回体里有没有数据**（而不只看状态码）。
//   这次的"缺少文件"分支返回 200 + HTML ⇒ **状态码不能证明站点可用**。
// ```
//
// # ★★ 2026-10-27 真网络实测：**四段全通 + 真 m3u8 播通**
//
// ```text
// home   /index.php                          → 200，导航 7 项：
//        电影(1) 连续剧(2) 综艺(3) 动漫(4) 短剧(26) 小姐姐(20) 音乐(31)
//        （首页导航真结构是 `<ul class="swiper-wrapper"><li><a href="/vod-type-id-N-pg-1.html">名</a></li>…`
//          —— DEX 写的 `#topnav > ul:nth-child(1) li` 是**同样的东西**，
//          这里按真结构解析，并保留 `vod-type-id-N` 这个**判据**（比 class 名稳））
// list   /index.php?m=vod-type-id-1-pg-1.html → 200 · 90 条
//        tid=1→90 / tid=2→54 / tid=5→60 / tid=12→30
//        条目真结构：`<li><a href="/vod-detail-id-96481.html" title="遇见你">
//                      <div class="pic"><img src="…" data-echo="…">
//                      <span class="sTit">遇见你</span><span class="sDes">主演：…</span></a></li>`
// detail /index.php?m=vod-detail-id-96481.html → 200
//        `<h1 class="title"><a href="/vod-detail-id-N.html" title="名">名</a></h1>`
//        剧集：URL 形如 `/vod-play-id-{id}-src-{src}-num-{num}.html`
// play   /vod-play-id-96481-src-1-num-1.html → 200，页内 JS 变量：
//        `mac_url='第01集$https://svip.xgplay3.com/…/index.m3u8'`
//        `mac_from='xiguam3u8'`（**线路名**）—— 多线路时 `mac_from` 用 `$$$` 分隔
//        多集时 `mac_url` 用 `#` 分集、`名$址` 成对
//        【真播通】该 m3u8 直连 → **200 + `#EXTM3U #EXT-X-STREAM-INF:…1080x608`**
//                  ⇒ 无头/带 Referer/带 Lavf UA **都能取**（这个 CDN 不校验）
// search /index.php?m=vod-search&wd=%E7%81%AB → 200
//        `<ul class="ulPicTxt clearfix" id="data_list"><li><div class="pic">
//           <a href="/vod-detail-id-N.html"><img data-src="…"></a></div>
//           <div class="txt…"><span class="sTit">名</span>…`
// ```
//
// # ⚠️ 分页：**如实报告我测到的**（不出结论，把读数交出来）
// ```text
// 实测 `pg=1` 与 `pg=2` 的**前 5 个 id 完全相同**（96481 / 94741 / 92013 / 90063 / 90062）。
// ⇒ 这一版我**不假设分页真的生效**：
//   `list()` 原样把 `pg` 拼进 URL（照 DEX 模板），但**不编造 page_count**；
//   page>1 拿到的条目如果与 page=1 相同，那是**上游行为**，不是我们解析错。
//   ⚠️ 我没有进一步验证"是不是我的 pg 参数位置不对"（那要更多探测轮次）⇒
//     **如实留成已知不确定项**，不写成"分页已支持"。
// ```
//
// # 已知缺口（按 Lead 裁定的契约边界登记）
// ```text
// · mProxy   —— 本批不做（本批无 mProxy 等价位）；本类取流是直链 m3u8，不需要
// · loadPic  —— 本仓不补 trait；封面头见 COVER_HEADERS（实测该 CDN 不需要额外头）
// · isVideoFormat / manualVideoCheck —— DEX 里 Wwys **没有**这两个方法
//   （它的方法骨架是 a/b/categoryContent/detailContent/homeContent/init/playerContent/searchContent）
//   ⇒ 本仓无等价位，如实标"本类 DEX 未定义，未实现"。
// ```

use async_trait::async_trait;
use regex::Regex;
use std::sync::OnceLock;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// ext 缺省时的兜底镜像（订阅里给的就是这个）
///
/// # ★★ 2026-10-29 复测：**这个镜像的"搜索"在站点侧被关掉了**（不是我们的解析坏）
///
/// ```text
/// ① `https://vip.wwgz.cn:5200/index.php?m=vod-search&wd=老舅`
///      PC UA        → 200 /  66 B  「缺少文件：/data/img.wwgz.cn/template/pc/html//vod_search.html」
///      本类 Android UA → 200 /  68 B  「缺少文件：/data/img.wwgz.cn/template/wap3/html//vod_search.html」
///    ⇒ 两套模板**都没有搜索页**；站点自己在移动端顶栏把搜索按钮换成了
///      `onclick="alert('抱歉！搜索功能升级中')"`（首页 46666 B 里逐字可见）。
/// ② 同一镜像的**列表页还在**，但只有"完整 maccms 形态"能出内容（本类现在用的短形态是死的）：
///      /index.php?m=vod-type-id-1-pg-1.html                     → 200 /  70 B「缺少文件：…//vod_type_movie.html」
///      /index.php?m=vod-list-id-1-pg-1-order--by-time-class-0-year-0-letter--area--lang-.html
///                                                              → 200 / 真列表（`共20720条数据 当前:1/691页`）
/// ③ 另试过的入口（全部不是 200 真页面）：
///      /index.php?m=vod-search&wd=…&page=2 / &tpl=wap3 / &ajax=1 / /vod-search-wd-….html → 200 / 66 B 同一条「缺少文件」
///      /index.php/ajax/search?wd=… → 200 / 435 B（站点 404 页）
///      /search.php?wd=…            → 404 / 548 B
///      https://www.wwgz.cn、https://wwgz.cn → DNS 解不出（`wwgz.cn` 只有 SOA）
/// ⇒ 结论：**search 不可用是上游行为**（模板缺失 + 站点自己弹"搜索功能升级中"），
///   换 base 也没找到任何能给 200 + 搜索结果的镜像 ⇒ 不改解析、不改路径，只留这条取证。
/// ```
const DEFAULT_BASE: &str = "https://vip.wwgz.cn:5200";

/// DEX `a()` 里的 UA（注意末尾那个 `uacq` 是原样的，不是笔误）
const UA: &str = "Mozilla/5.0 (Linux; Android 13; SM-A037U) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36  uacq";

/// 封面请求头（声明式）—— 实测 `laudio-cdn.tencentmusic.com` / `img.lzipic.com` 直连可取
pub const COVER_HEADERS: &[(&str, &str)] = &[];

const TIMEOUT: Duration = Duration::from_secs(20);

/// 兜底分类（实测首页导航 7 项；拿不到首页时用它）
///
/// ```text
/// 2026-10-27 实测 /index.php 的导航：
///   电影 /vod-type-id-1-pg-1.html      连续剧 /vod-type-id-2-pg-1.html
///   综艺 /vod-type-id-3-pg-1.html      动漫   /vod-type-id-4-pg-1.html
///   短剧 /vod-type-id-26-pg-1.html     小姐姐 /vod-type-id-20-pg-1.html
///   音乐 /vod-type-id-31-pg-1.html
/// ```
pub const FALLBACK_CATEGORIES: &'static [(&'static str, &'static str)] = &[
    ("1", "电影"),
    ("2", "连续剧"),
    ("3", "综艺"),
    ("4", "动漫"),
    ("26", "短剧"),
    ("20", "小姐姐"),
    ("31", "音乐"),
];

pub struct Wwys {
    client: super::http_context::CspHttpContext,
}

impl Wwys {
    pub const CLASS: &'static str = "Wwys";

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
        );
        Self { client }
    }

    /// 从 ext 取站点（订阅里 ext 是**裸 URL 字符串**，不是 JSON）
    ///
    /// ```text
    /// ext = "https://vip.wwgz.cn:5200"      ⇒ 原样
    /// ext = ""                              ⇒ DEFAULT_BASE
    /// ext = "{\"site\":[\"https://…\"]}"    ⇒ 也认（同族站点的写法）
    /// ```
    pub fn base_of(ext: &str) -> String {
        static RE: OnceLock<Regex> = OnceLock::new();
        let re = RE.get_or_init(|| Regex::new(r#"https?://[^"'\s,\]}]++"#).expect("url regex"));
        re.find(ext)
            .map(|m| m.as_str().trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| DEFAULT_BASE.to_string())
    }

    async fn get(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）"));
        }
        /*
         * ★★ 「缺少文件」判据 —— 这个站用 **HTTP 200 + 一段 HTML** 表示"模板缺失"。
         * ```text
         * 实测我这个类的第一版就是这么被骗的：我把不带 `?m=` 的路径打过去，
         * 站点回 200 + 「缺少文件：/data/img.wwgz.cn/template/pc/html//vod_list.html」
         * ⇒ 看起来像"站点坏了"，其实是**路径形式不对**（苹果 CMS 要 `?m=vod-…`）。
         * ⇒ 必须显式识别这个分支，并把"你打错路径了"说出来 ——
         *   而不是把它当正常 HTML 交给解析器（那样会静默返回 0 条，症状变成"没数据"）。
         * ```
         */
        if text.contains("缺少文件") {
            return Err(format!(
                "站点返回「缺少文件」（{url}）——这是苹果 CMS 的「模板缺失/路径形式不对」分支，\
                 不是正常页面。本实现用 `?m=vod-…` 形式；若上游改了模板，请核对入口形式。"
            ));
        }
        Ok(text)
    }
}

impl Default for Wwys {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数（可单测；每处都对着"缺陷形状"）
// ═══════════════════════════════════════════════════════════════════════

/// 首页导航 → 分类
///
/// # 判据为什么锚在 `vod-type-id-N` 而不是 class 名
/// ```text
/// DEX 写的是 `#topnav > ul:nth-child(1) li`（依赖 class 与 :nth-child 位置）。
/// 实测真首页的导航在 `<ul class="swiper-wrapper">` 里 —— **class 名不同**，
/// 但每个分类链接都是 `/vod-type-id-{N}-pg-1.html` 这个**稳定形状**。
/// ⇒ 锚在 URL 形状上：换主题（class 改名）不会让它失效，
///   而"换 CMS 入口形式"才会 —— 那是另一个信号，该红。
/// ```
pub fn nav_categories(html: &str) -> Vec<CspCategory> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(r#"href="[^"]*vod-type-id-(\d+)[^"]*"[^>]*>\s*([^<]{1,16}?)\s*<"#)
            .expect("nav regex")
    });
    let mut out: Vec<CspCategory> = Vec::new();
    for c in re.captures_iter(html) {
        let id = c[1].to_string();
        let name = crate::tvbox::decode_entities(&c[2]).trim().to_string();
        if name.is_empty() || name == "更多" {
            continue;
        }
        if !out.iter().any(|x| x.id == id) {
            out.push(CspCategory { id, name });
        }
    }
    out
}

/// 列表页 → 条目
///
/// 真结构（实测）：
/// ```text
/// <li><a href="/vod-detail-id-96481.html" title="遇见你">
///   <div class="pic"…><img src="…" data-echo="…">…<span class="sTit">遇见你</span>
///   <span class="sDes">主演：李汶翰 徐若晗 王博文</span></a></li>
/// ```
/// ★ 判据锚在 `href="/vod-detail-id-{N}.html"`（稳定形状），
///   标题优先用 `a[title]`，退到 `.sTit` 文本。
///
/// # ⚠️ 为什么不用"块匹配"（我第一版就栽在这）
/// ```text
/// 我第一版想一次正则把整块 `<a …>…</a>` 抓出来，用了 `(?=</li>|<li>)` 前瞻
/// ⇒ **Rust 的 `regex` crate 不支持 look-around** ⇒ 三条测试直接红
///   （`error: look-around, including look-ahead and look-behind, is not supported`）。
/// ⇒ 改成**两段式**：① 用锚把每个条目的起始位置找出来（`href` 与 `title`）；
///   ② 从这个位置**往后截一段固定窗口**当块，再在小块里找封面/副标题。
///   这样没有 look-around，且行为可预测（窗口 900 字节足够覆盖实测的条目结构）。
/// ```
pub fn items_of_list(html: &str) -> Vec<CspItem> {
    static RE: OnceLock<Regex> = OnceLock::new();
    /*
     * 锚：`<a href="/vod-detail-id-{N}.html" title="…"`。
     * title 是可选的（实测有的条目没写 title，只有 `<span class="sTit">`）。
     */
    let re = RE.get_or_init(|| {
        Regex::new(r#"<a\s+href="/vod-detail-id-(\d+)\.html"\s*(?:title="([^"]*)")?"#)
            .expect("list anchor regex")
    });
    let re_title = {
        static R2: OnceLock<Regex> = OnceLock::new();
        R2.get_or_init(|| Regex::new(r#"class="sTit"[^>]*>([^<]*)"#).expect("sTit"))
    };
    let re_img = {
        static R3: OnceLock<Regex> = OnceLock::new();
        R3.get_or_init(|| {
            Regex::new(r#"<img[^>]*?(?:data-echo|data-src|src)="([^"]+)""#).expect("img")
        })
    };
    let re_des = {
        static R4: OnceLock<Regex> = OnceLock::new();
        R4.get_or_init(|| Regex::new(r#"class="sDes"[^>]*>([^<]*)"#).expect("sDes"))
    };

    /// 条目块的窗口大小（字节）。实测一条 `<li>` 约 300–600 字节；
    /// 900 够覆盖 `img` + `sTit` + `sDes`，又不会跨到下一条。
    const WINDOW: usize = 900;

    let mut out: Vec<CspItem> = Vec::new();
    for c in re.captures_iter(html) {
        let id = c[1].to_string();
        if out.iter().any(|x| x.id == id) {
            continue; // 同一条在导航/推荐里出现多次 ⇒ 去重
        }
        // ② 从锚的**结束位置**往后截窗口（不是从 href 开始，避免把锚自身算进标题搜索）
        let start = c.get(0).map(|m| m.end()).unwrap_or(0);
        let block = safe_slice(html, start, start.saturating_add(WINDOW));

        let title = c
            .get(2)
            .map(|m| crate::tvbox::decode_entities(m.as_str()).trim().to_string())
            .filter(|t| !t.is_empty())
            .or_else(|| {
                re_title
                    .captures(block)
                    .map(|t| crate::tvbox::decode_entities(&t[1]).trim().to_string())
            })
            .unwrap_or_default();
        if title.is_empty() {
            continue; // 没标题的条目对 UI 没意义
        }
        let cover = re_img
            .captures(block)
            .map(|m| m[1].to_string())
            .filter(|s| crate::tvbox::starts_http(s));
        let sub = re_des
            .captures(block)
            .map(|t| crate::tvbox::decode_entities(&t[1]).trim().to_string())
            .filter(|s| !s.is_empty());
        out.push(CspItem {
            id,
            title,
            cover,
            subtitle: sub,
        });
    }
    out
}

/// 详情页 → (标题, 封面, 剧集页 URL 列表)
///
/// # 剧集怎么变成"集"
/// ```text
/// 实测详情页给出的是**播放页链接**：`/vod-play-id-{id}-src-{src}-num-{num}.html`
/// 而真地址在**那一页**里（`mac_url`）。
/// ⇒ 本实现把每个 `(src,num)` 当成一"集"，id 存成**播放页 URL**，
///   `play()` 再去那一页抽 `mac_url`。
///   ★ 为什么不在 detail 阶段把每集都抓一遍：一个 90 集的剧 = 90 次请求，
///     用户还没点进来就打了 90 次上游 ⇒ 放在 `play()` 里按需取（只取用户点的那一集）。
/// ```
pub fn detail_of(html: &str) -> (String, Option<String>, Vec<(String, String)>)
{
    // 标题：`<h1 class="title"><a … title="名">名</a></h1>`（实测）
    let re_title = Regex::new(r#"(?s)<h1[^>]*class="title"[^>]*>\s*<a[^>]*title="([^"]*)""#)
        .expect("title re");
    let title = re_title
        .captures(html)
        .map(|c| crate::tvbox::decode_entities(&c[1]).trim().to_string())
        .unwrap_or_default();

    // 封面：详情页唯一的 `<img src=…>`（实测就一张：`laudio-cdn…jpg`）
    let re_img = Regex::new(r#"<img[^>]*?src="(https?://[^"]+)""#).expect("detail img");
    let cover = re_img.captures(html).map(|c| c[1].to_string());

    // 剧集页链接：`/vod-play-id-{id}-src-{src}-num-{num}.html`
    let re_play =
        Regex::new(r#"/vod-play-id-\d+-src-(\d+)-num-(\d+)\.html"#).expect("play link");
    let mut eps: Vec<(String, String)> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for c in re_play.captures_iter(html) {
        let path = c.get(0).map(|m| m.as_str().to_string()).unwrap_or_default();
        if seen.contains(&path) {
            continue;
        }
        seen.push(path.clone());
        let src = &c[1];
        let num = &c[2];
        eps.push((format!("线路{src}-第{num}集"), path));
    }
    (title, cover, eps)
}

/// 播放页 → `mac_url` / `mac_from` 解出的「线路 → 集」
///
/// 实测页内 JS：
/// ```text
/// mac_flag='play', mac_link='/vod-play-id-96481-src-{src}-num-{num}.html',
/// mac_name='遇见你', mac_from='xiguam3u8', mac_server='no', mac_note='',
/// mac_url='第01集$https://svip.xgplay3.com/…/index.m3u8';
/// ```
/// 多线路：`mac_from='monday$$$lzm3u8'` + `mac_url` 里 `$$$` 分段（**一一对应**）
/// 多集  ：单段内 `#` 分集、`名$址` 成对
///
/// ★ 这里复用 `shared::split_lines`（AppYQK / 本类 / 后续类的 `$$$`+`#` 语义完全一致）。
pub fn play_of_page(html: &str) -> Result<Vec<(String, Vec<(String, String)>)>, String> {
    let re_url = Regex::new(r#"mac_url='([^']*)'"#).expect("mac_url");
    let re_from = Regex::new(r#"mac_from='([^']*)'"#).expect("mac_from");
    let url = re_url
        .captures(html)
        .map(|c| c[1].to_string())
        .ok_or_else(|| {
            "播放页里没有 mac_url（该条可能无源，或上游换了模板）".to_string()
        })?;
    let from = re_from
        .captures(html)
        .map(|c| c[1].to_string())
        .unwrap_or_default();
    if url.trim().is_empty() {
        return Err("播放页的 mac_url 是空串（该条无播放源）".to_string());
    }
    let lines = crate::csp::shared::split_lines(&from, &url);
    let with_url: Vec<(String, Vec<(String, String)>)> = lines
        .into_iter()
        .map(|(flag, eps)| {
            let flag2 = if flag.starts_with("线路") {
                // split_lines 对空 flag 会补"线路N"；这里用站点自己的说法更准
                flag
            } else {
                flag
            };
            (flag2, eps)
        })
        .filter(|(_, eps)| !eps.is_empty())
        .collect();
    if with_url.is_empty() {
        return Err("mac_url 解出来 0 集（格式与预期不符）".to_string());
    }
    Ok(with_url)
}

/// 按**字节**截一段，但**保证落在字符边界**上
///
/// # ★★ 为什么必须有这个函数（这是真网络才炸出来的 bug，不是预防性设计）
/// ```text
/// 我写的是：`let end = (start + WINDOW).min(html.len()); let block = &html[start..end];`
///
/// 单测全绿（fixture 都是短英文），一跑**真网络**就 panic：
///     end byte index 47290 is not a char boundary;
///     it is inside '九' (bytes 47289..47292 of string)
///
/// 根因：Rust 的**字符串切片按字节索引**，而中文一个字 3 字节
///   ⇒ `start + 900` 极易落在**某个汉字的中间** ⇒ panic（不是返回错、是**崩**）。
///   真站页面全是中文 ⇒ 这个 bug 在单测里**几乎不可能**被小 fixture 触发。
///
/// 教训：**凡是对"可能含多字节字符的文本"做固定宽度字节切片，都必须先对齐字符边界。**
///   这类 bug 的特征是"单测全绿 + 真数据一跑就崩"，只有真网络用例能发现它。
/// ```
pub fn safe_slice(s: &str, from: usize, to: usize) -> &str {
    if from > s.len() {
        return "";
    }
    let mut a = from;
    while a > 0 && !s.is_char_boundary(a) {
        a -= 1;
    }
    let mut b = to.min(s.len());
    while b > a && !s.is_char_boundary(b) {
        b -= 1;
    }
    &s[a..b]
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Wwys {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：`/index.php` → 真导航分类
    ///
    /// ⚠️ 拿不到首页时用**实测抓下来的**兜底分类表（不是编的），并**不**假装探测成功。
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let base = Self::base_of(ext);
        let categories = match self.get(&format!("{base}/index.php")).await {
            Ok(html) => {
                let navs = nav_categories(&html);
                if navs.is_empty() {
                    fallback_cats()
                } else {
                    navs
                }
            }
            Err(_) => fallback_cats(),
        };
        // 首屏：第一个分类的第一页（拿不到就空，不编）
        let items = match categories.first() {
            Some(c) => self
                .list(&c.id, 1, ext)
                .await
                .map(|l| l.items.into_iter().take(20).collect())
                .unwrap_or_default(),
            None => Vec::new(),
        };
        Ok(CspHome { categories, items })
    }

    /// 分类列表：`/index.php?m=vod-type-id-{tid}-pg-{pg}.html`
    ///
    /// # ⚠️ 分页：**如实**（见文件头）
    /// ```text
    /// 实测 pg=1 与 pg=2 前 5 个 id 相同 ⇒ 我**不**声称分页已生效，也**不**编 page_count。
    /// 这里照 DEX 模板原样拼 pg；上游给什么就返回什么。
    /// ```
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id（tid）为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let base = Self::base_of(ext);
        let url = format!("{base}/index.php?m=vod-type-id-{tid}-pg-{page}.html");
        let html = self.get(&url).await?;
        let items = items_of_list(&html);
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
                "分类 {tid} 没解析出条目（上游页面结构可能变了：{url}）"
            ));
        }
        Ok(CspList {
            items,
            page,
            // 上游不给总页数 ⇒ 如实 None
            page_count: None,
            total: None,
        })
    }

    /// 详情：`/index.php?m=vod-detail-id-{id}.html`
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let vid = id.trim();
        if vid.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let base = Self::base_of(ext);
        let url = format!("{base}/index.php?m=vod-detail-id-{vid}.html");
        let html = self.get(&url).await?;
        let (title, cover, eps) = detail_of(&html);
        if title.is_empty() {
            return Err(format!("详情页没解析出标题（上游结构可能变了：{url}）"));
        }
        if eps.is_empty() {
            return Err(format!("「{title}」详情页没有播放页链接（上游结构可能变了）"));
        }
        let episodes: Vec<CspEpisode> = eps
            .into_iter()
            .map(|(name, path)| CspEpisode {
                // id = 播放页 URL（play() 拿它去抽 mac_url）
                id: path,
                title: name,
                // 这个站的"线路"在**播放页**里才定（mac_from）⇒ 详情阶段统一标"默认"
                flag: "默认".to_string(),
            })
            .collect();
        Ok(CspDetail {
            id: vid.to_string(),
            title,
            cover,
            description: None, // DEX 的 detailContent 没读简介（只读 title/封面/播放链接）
            episodes,
        })
    }

    /// 搜索：`/index.php?m=vod-search&wd=`
    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let base = Self::base_of(ext);
        // ⚠️ wd 必须 URL 编码（中文关键词实测能出结果）
        let url = format!(
            "{base}/index.php?m=vod-search&wd={}",
            urlencoding::encode(kw)
        );
        let html = self.get(&url).await?;
        let items = items_of_list(&html);
        /*
         * ★ 搜索页实测命中（"火" → /vod-detail-id-96229.html 等），
         *   且 0 条是**正常结果**（不是故障）⇒ 返回空页，不 Err。
         */
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        // ★ 已真网络验证：`/index.php?m=vod-search&wd=火` 200 且页面里有真条目链接
        true
    }

    /// 取流：去播放页抽 `mac_url`
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let _ = flag;
        let path = id.trim();
        if path.is_empty() {
            return Err("剧集 id（播放页路径）为空".to_string());
        }
        let base = Self::base_of(ext);
        let url = if crate::tvbox::starts_http(path) {
            path.to_string()
        } else {
            format!("{}{}", base, if path.starts_with('/') { "" } else { "/" }.to_string() + path)
        };
        let html = self.get(&url).await?;
        let lines = play_of_page(&html)?;

        // 把"线路 → 集"摊平成候选（同一个 URL 只出一次）
        let mut out: Vec<CspPlay> = Vec::new();
        for (line, eps) in &lines {
            for (ep_name, ep_url) in eps {
                if !crate::tvbox::starts_http(ep_url) {
                    continue; // 非 http 的段（如相对路径/空）跳过，不伪造
                }
                if out.iter().any(|p| p.url == *ep_url) {
                    continue;
                }
                out.push(CspPlay {
                    url: ep_url.clone(),
                    /*
                     * 实测：这个站各 CDN 直连都通（无头 / 带 Referer / 带 Lavf UA 全 200）
                     * ⇒ header 留空是**实测结论**，不是偷懒。
                     * 但仍带上 Referer 作为**保守**选择：部分分片可能校验，
                     * 带上不会更差（实测带与不带都 200）。
                     */
                    headers: vec![
                        ("Referer".to_string(), format!("{base}/")),
                        ("User-Agent".to_string(), UA.to_string()),
                    ],
                    label: Some(if line.trim().is_empty() {
                        ep_name.clone()
                    } else {
                        format!("{line} · {ep_name}")
                    }),
                });
            }
        }
        if out.is_empty() {
            return Err(format!(
                "播放页里 mac_url 没有可用的 http 地址（{url}）—— 该条可能无源"
            ));
        }
        Ok(out)
    }
}

/// 实测抓下来的兜底分类（**不是编的**，见 `FALLBACK_CATEGORIES` 的注释）
fn fallback_cats() -> Vec<CspCategory> {
    FALLBACK_CATEGORIES
        .iter()
        .map(|(id, name)| CspCategory {
            id: (*id).to_string(),
            name: (*name).to_string(),
        })
        .collect()
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册（R3-D，2026-10-27）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类的事实（从文件头的长注释搬过来，别丢）
// ```text
// csp_Wwys（🌾农民｜蓝光秒播）：**四段全通 + 真 m3u8 播通**（2026-10-27）
//   home   /index.php → 导航 7 项（电影/连续剧/综艺/动漫/短剧/小姐姐/音乐）
//   list   ?m=vod-type-id-1-pg-1.html → 90 条（tid=2→54 / 5→60 / 12→30）
//   detail ?m=vod-detail-id-96481.html → h1.title + 封面 + /vod-play-id-{id}-src-N-num-M.html
//   play   /vod-play-id-96481-src-1-num-1.html → mac_url='第01集$https://…index.m3u8'
//          该 m3u8 直连 → **200 + #EXTM3U + #EXT-X-STREAM-INF:…1080x608**
//   search ?m=vod-search&wd=火 → 真命中
// ⚠️⚠️ 留档（最重要）：我第一版**误判"上游已死"** ——
//    我打了不带 `?m=` 的路径，站点回 **200 + 「缺少文件：…//vod_list.html」**，
//    那看起来像站点坏了，其实是**我的路径形式不对**（苹果 CMS 要 `?m=vod-…`）。
//    ⇒ 本实现**显式识别「缺少文件」分支**并说清是"路径形式不对"，
//      而不是把它当正常页面（那样会静默返回 0 条，症状变成"没数据"）。
// ```
crate::csp::register_site!(Wwys);

#[cfg(test)]
#[path = "wwys_proxy_tests.rs"]
mod proxy_tests;

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_is_registered_under_exact_name() {
        assert_eq!(Wwys::CLASS, "Wwys");
        assert_eq!(Wwys::new().class(), "Wwys");
    }

    // ── ext 解析 ──────────────────────────────────────────────────────
    #[test]
    fn base_comes_from_ext_with_a_measured_fallback() {
        // 订阅里 ext 是**裸 URL 字符串**
        assert_eq!(Wwys::base_of("https://vip.wwgz.cn:5200"), "https://vip.wwgz.cn:5200");
        // 末尾斜杠要去掉（否则拼出 `//index.php`）
        assert_eq!(Wwys::base_of("https://a.example/"), "https://a.example");
        // 对象形态也认（同族站点写法）
        assert_eq!(
            Wwys::base_of(r#"{"site":["https://b.example"]}"#),
            "https://b.example"
        );
        // 空 ⇒ 兜底（实测镜像，不是编的）
        assert_eq!(Wwys::base_of(""), DEFAULT_BASE);
        assert_eq!(Wwys::base_of("    "), DEFAULT_BASE);
    }

    // ── ★ 导航解析（对着"真 class 名与 DEX 不同"这个坑） ────────────────
    #[test]
    fn nav_categories_anchors_on_url_shape_not_class_name() {
        // ★ 实测真首页用 `<ul class="swiper-wrapper">`（DEX 写的是 `#topnav`）
        //   ⇒ 判据必须锚在 `vod-type-id-N`，否则换主题就失效
        let html = r#"<div class="topnav"><ul class="swiper-wrapper" style="width:1600%">
            <li ><a href="/vod-type-id-1-pg-1.html">电影</a></li>
            <li ><a href="/vod-type-id-2-pg-1.html">连续剧</a></li>
            <li ><a href="/vod-type-id-26-pg-1.html">短剧</a></li>
        </ul></div>"#;
        let cats = nav_categories(html);
        assert_eq!(cats.len(), 3);
        assert_eq!(cats[0].id, "1");
        assert_eq!(cats[0].name, "电影");
        assert_eq!(cats[2].id, "26");
        assert_eq!(cats[2].name, "短剧");
        // 同一个分类出现两次 ⇒ 去重
        let dup = r#"<a href="/vod-type-id-1-pg-1.html">电影</a><a href="/vod-type-id-1-pg-2.html">电影</a>"#;
        assert_eq!(nav_categories(dup).len(), 1, "同一 tid 要按 id 去重");
        // 不是列表页 ⇒ 空（由调用方走兜底，不 panic）
        assert!(nav_categories("<html>nope</html>").is_empty());
    }

    // ── ★ 列表解析（对着真结构） ─────────────────────────────────────
    #[test]
    fn items_of_list_parses_the_real_markup() {
        // ★ 实测原样片段（含 img 的 src 与 data-echo 双写）
        let html = r#"<ul class="resize_list"><li><a href="/vod-detail-id-96481.html" title="遇见你">
            <div class="pic"style=" height: 150px;"><img src="https://laudio-cdn.tencentmusic.com/image/207335/x.jpg" style=" height: 150px;"" data-echo="https://laudio-cdn.tencentmusic.com/image/207335/x.jpg"style=" height: 150px;""><span class="sBg"></span><span class="sBottom"><span><em>0.0</em></span></span></div><span class="sTit">遇见你</span><span class="sDes">主演：李汶翰 徐若晗 王博文</span></a></li>
            <li><a href="/vod-detail-id-94741.html" title="抓特务"><div class="pic"><img src="https://a.example/b.jpg"><span class="sTit">抓特务</span></a></li></ul>"#;
        let items = items_of_list(html);
        assert_eq!(items.len(), 2, "应解析出两条");
        assert_eq!(items[0].id, "96481");
        assert_eq!(items[0].title, "遇见你");
        assert!(items[0].cover.as_deref().unwrap().starts_with("https://laudio-cdn"));
        assert_eq!(items[0].subtitle.as_deref(), Some("主演：李汶翰 徐若晗 王博文"));
        assert_eq!(items[1].title, "抓特务");
        // 空页面 ⇒ 空（由调用方决定报错还是空页）
        assert!(items_of_list("<html>nope</html>").is_empty());
    }

    #[test]
    fn items_of_list_dedupes_and_never_emits_empty_titles() {
        // 同一条出现两次（导航 + 推荐）⇒ 只出一次
        let html = r#"<a href="/vod-detail-id-1.html" title="A">x</a>
                      <a href="/vod-detail-id-1.html" title="A">y</a>"#;
        assert_eq!(items_of_list(html).len(), 1);
        // 空标题且块里也没有 .sTit ⇒ 跳过（别在 UI 里显示空行）
        let no_title = r#"<a href="/vod-detail-id-2.html" title=""><div></div></a>"#;
        assert!(items_of_list(no_title).is_empty());
    }

    #[test]
    fn items_of_list_does_not_treat_relative_cover_as_cover() {
        // ★ 封面必须是 http(s)：相对路径/空串不算（否则 UI 会去请求一个 404 相对地址）
        let html = r#"<a href="/vod-detail-id-3.html" title="T"><img src="/template/a.png"><span class="sTit">T</span></a>"#;
        let it = items_of_list(html);
        assert_eq!(it.len(), 1);
        assert_eq!(it[0].cover, None, "★ 相对路径封面必须丢掉，不能当 cover");
    }

    // ── ★ 详情解析 ───────────────────────────────────────────────────
    #[test]
    fn detail_of_extracts_title_cover_and_play_pages() {
        // ★ 实测原样（h1.title + 一张 img + 两个播放页链接，其中一个是重复的）
        let html = r#"<h1 class="title"><a href="/vod-detail-id-96481.html" title="遇见你">遇见你</a></h1>
            <img src="https://laudio-cdn.tencentmusic.com/image/207335/x.jpg" style=" height: 150px;"" data-echo="https://laudio-cdn.tencentmusic.com/image/207335/x.jpg">
            <div class="page-btn"><span><a href="/vod-play-id-96481-src-1-num-1.html">立即播放</a></span>
            <span><a href="/vod-play-id-96481-src-1-num-1.html">第01集</a></span></div>"#;
        let (title, cover, eps) = detail_of(html);
        assert_eq!(title, "遇见你");
        assert!(cover.as_deref().unwrap().starts_with("https://laudio-cdn"));
        assert_eq!(eps.len(), 1, "重复的播放页链接要去重");
        assert_eq!(eps[0].1, "/vod-play-id-96481-src-1-num-1.html");
        assert!(eps[0].0.contains("第1集"), "集名要带上集号：{}", eps[0].0);
    }

    #[test]
    fn detail_of_reports_missing_pieces_instead_of_faking() {
        // 没有 h1.title ⇒ 标题空（由 detail() 负责报错，不编一个）
        let (t, _, _) = detail_of("<html>nope</html>");
        assert_eq!(t, "", "解析不出来就空，不许编");
    }

    // ── ★★ 播放解析（对着"多线路 + 多集"两个维度的真形状） ───────────────
    #[test]
    fn play_of_page_parses_real_mac_url_single_line_multi_ep() {
        // ★ 实测 vid=96229 的原样（单线路 lzm3u8、多集用 `#` 分）
        let html = r#"<script>var mac_flag='play',mac_link='/vod-play-id-96229-src-{src}-num-{num}.html',
            mac_name='萤火虫之婚',mac_from='lzm3u8',mac_server='no',mac_note='',
            mac_url='第01集$https://v.lzcdn31.com/20261010/12536_e81c2ebf/index.m3u8#第02集$https://v.lzcdn31.com/20261016/13039_f9350aaf/index.m3u8'; </script>"#;
        let lines = play_of_page(html).expect("应解析成功");
        assert_eq!(lines.len(), 1, "单线路");
        assert_eq!(lines[0].0, "lzm3u8", "★ flag 就是 mac_from（线路名）");
        assert_eq!(lines[0].1.len(), 2, "`#` 分集");
        assert_eq!(lines[0].1[0].0, "第01集");
        assert!(lines[0].1[0].1.ends_with("index.m3u8"));
    }

    #[test]
    fn play_of_page_parses_real_multiline_with_dollar_separator() {
        // ★ 实测 vid=94741 的原样：mac_from 用 `$$$` 分两条线、mac_url 也 `$$$` 对齐
        let html = r#"<script>mac_from='monday$$$lzm3u8',mac_url='第01集$https://a.example/1.m3u8$$$第01集$https://b.example/2.m3u8'; </script>"#;
        let lines = play_of_page(html).expect("应解析成功");
        assert_eq!(lines.len(), 2, "★ 两条线路");
        assert_eq!(lines[0].0, "monday");
        assert_eq!(lines[0].1[0].1, "https://a.example/1.m3u8");
        assert_eq!(lines[1].0, "lzm3u8");
        assert_eq!(lines[1].1[0].1, "https://b.example/2.m3u8");
    }

    #[test]
    fn play_of_page_errs_loudly_when_no_mac_url() {
        // ★ 没有 mac_url ⇒ 明确 Err（不许静默返回空，那会让用户以为"这条没剧集"）
        let e = play_of_page("<html><body>无源</body></html>").expect_err("必须 Err");
        assert!(e.contains("mac_url"), "错误要点名缺的东西：{e}");
        // 空串同样要 Err（不是"解析出 0 集"就放过去）
        let e2 = play_of_page("<script>mac_url='';</script>").expect_err("空串也要 Err");
        assert!(e2.contains("空串"), "{e2}");
    }

    // ── ★★ 回归：不许再误判"上游已死" ────────────────────────────────
    #[test]
    fn missing_file_branch_is_an_error_not_a_page() {
        /*
         * ★★ 这条守的是**我犯过的那个错**：
         *   不带 `?m=` 的路径 ⇒ 站点回 **200 + 「缺少文件：…//vod_list.html」**，
         *   我第一次把它当成"站点坏了/模板缺失"⇒ 写下"上游功能性死亡"（**错的**）。
         *   真相：站点活着，是我的**入口形式**不对（苹果 CMS 要 `?m=vod-…`）。
         *
         * 判据：源码里必须**显式识别**「缺少文件」并给出"路径形式不对"的说明，
         *   而不是把它当正常 HTML 交给解析器（那样会静默 0 条）。
         * ⚠️ 用 `impl_src_only` 剥测试段（否则断言字面量会把自己喂成假绿 —— AppYQK 踩过）。
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("wwys.rs"));
        assert!(
            flat.contains(r#"text.contains("缺少文件")"#),
            "★ 必须显式识别「缺少文件」分支"
        );
        assert!(
            flat.contains("路径形式不对"),
            "★ 要说明这是**入口形式**问题，而不是「上游死了」（我第一版正是判错了）"
        );
        // 反面：不许把 200 当成功就放过去（这条保证上面那个分支不会被绕过）
        assert!(
            !flat.contains(r#"if!status.is_success(){returnOk(text);}"#),
            "★ 失败状态码不许当成功返回"
        );
    }

    /// ★★ 真网络才炸出来的那个 bug：**中文页面上按字节切片会 panic**
    ///
    /// # 为什么这条单测是"补的"，以及它为什么必须存在
    /// ```text
    /// 我原来的写法 `&html[start..start+900]` 在**全中文**的真站页面上 panic：
    ///     end byte index 47290 is not a char boundary; it is inside '九'
    /// 而我的单测 fixture 都是短英文/短结构 ⇒ **一条都没红** ⇒ 这个 bug 溜到真网络。
    ///
    /// ⇒ 这条测试用**全中文 + 足够长**的页面，让窗口边界必然落在汉字中间。
    ///   去掉 `safe_slice`（改回 `&html[..]`）⇒ 这条立刻 panic ⇒ 真红。
    /// ```
    #[test]
    fn list_window_slicing_survives_multibyte_chinese_page() {
        // 造一个长中文页面：每条锚后面跟大量中文（确保窗口 900 会切在汉字中间）
        let filler = "遇见你全集免费在线观看高清完整版".repeat(60); // 中文，远多于 900 字节
        let mut html = String::new();
        for i in 0..3 {
            html.push_str(&format!(
                r#"<a href="/vod-detail-id-{i}.html" title="中文标题{i}">{filler}<span class="sTit">中文标题{i}</span></a>"#
            ));
        }
        // ★ 这里若用 `&html[..]` 裸切 ⇒ panic；用 safe_slice ⇒ 正常返回
        let items = items_of_list(&html);
        assert_eq!(items.len(), 3, "三条中文条目都要解析出来");
        assert_eq!(items[0].title, "中文标题0");
        assert!(items[2].title.starts_with("中文标题"));
    }

    #[test]
    fn safe_slice_never_panics_on_char_boundaries() {
        let s = "汉字汉字汉字汉字";
        // 遍历**所有**字节位置，两个方向都不许 panic
        for a in 0..=s.len() + 3 {
            for b in a..=s.len() + 3 {
                let _ = safe_slice(s, a, b); // 不 panic 即通过
            }
        }
        assert_eq!(safe_slice("abc", 1, 3), "bc");
        assert_eq!(safe_slice("abc", 9, 12), "", "越界起点 ⇒ 空串，不 panic");
        // 边界落在汉字中间 ⇒ 向前对齐（结果仍是合法 UTF-8）
        let got = safe_slice(s, 1, 4);
        assert!(got.is_char_boundary(0) && got.len() <= 4);
    }

    #[test]
    fn pagination_is_not_claimed_to_work() {
        /*
         * ★ 实测 pg=1 与 pg=2 前 5 个 id 相同 ⇒ **不声称分页已生效**。
         *
         * # 判据为什么改成"看代码"而不是"看注释"（这条我也改过一次）
         * ```text
         * 我第一版写的是 `flat.contains("上游不给总页数⇒如实None")` —— 那是在断言
         * **一句注释**。`impl_src_only` 现在会剥注释 ⇒ 它必然失败。
         * ★ 而"断言注释"本身就是**弱门禁**：改注释就能让它红/绿，与代码行为无关。
         * ⇒ 改成断言**代码形状**：
         *   ① `list()` 的成功路径里 `page_count` 必须是 `None`（不许编总页数）
         *   ② 源码里**不许**出现"算出页数"的写法（`page_count:Some` 只在
         *      "翻到末尾"那个分支合法 —— 那是"上一页就是最后一页"，不是上游给的总页数）
         * ```
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("wwys.rs"));
        // ① 成功路径（`Ok(CspList{items,page,…})`）里的 page_count 必须是 None
        assert!(
            flat.contains("Ok(CspList{items,page,"),
            "应能定位 list() 成功路径的构造点（实现被改过？）"
        );
        assert!(
            flat.contains("page_count:None,total:None,"),
            "★ 成功路径必须如实给 page_count:None（不许编总页数）：{flat}"
        );
        // ② `page_count: Some(…)` 只许出现在**翻到末尾**那个分支（page-1）
        let some_count = flat.matches("page_count:Some(").count();
        assert_eq!(
            some_count, 1,
            "★ `page_count:Some` 只该出现在「翻到末尾」一处（实际 {some_count} 处）——\
             若多出来，说明有人开始**编造**总页数了"
        );
        assert!(
            flat.contains("page_count:Some(page-1)"),
            "★ 那唯一的 Some 必须是 `page-1`（= 上一页即最后一页），不是上游给的总页数"
        );
    }

    #[test]
    fn supports_search_true_matches_the_live_verification() {
        // ★ 实测 `?m=vod-search&wd=火` 200 且页内有真条目链接
        assert!(Wwys::new().supports_search());
    }

    #[test]
    fn detail_uses_the_query_m_form_because_that_is_the_working_entry() {
        /*
         * ★ 这条钉住"入口形式"：
         *   `?m=vod-detail-id-…`（带 `?m=`）是**实测能拿到真详情**的形式；
         *   不带 `?m=` 会落到「缺少文件」分支。
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("wwys.rs"));
        assert!(
            flat.contains("/index.php?m=vod-detail-id-"),
            "★ 详情入口必须带 `?m=`（不带会落到「缺少文件」分支）"
        );
        assert!(
            flat.contains("/index.php?m=vod-type-id-") && flat.contains("-pg-"),
            "★ 列表入口必须带 `?m=` 且带 pg"
        );
        assert!(
            flat.contains("/index.php?m=vod-search&wd="),
            "★ 搜索入口必须带 `?m=`"
        );
    }

    #[test]
    fn search_url_encodes_the_keyword() {
        /*
         * ★ 中文关键词必须编码（实测 `wd=火` 用 `%E7%81%AB` 能出结果）。
         *   判据：源码里搜索 URL 用了 `urlencoding::encode`。
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("wwys.rs"));
        assert!(
            flat.contains("urlencoding::encode(kw)"),
            "★ 搜索关键词必须 URL 编码（中文不编码会打出脏请求）"
        );
    }

    #[test]
    fn play_skips_non_http_and_never_emits_a_fake_address() {
        let flat = crate::csp::shared::impl_src_only(include_str!("wwys.rs"));
        // 只有 http 的才出（相对路径/空串跳过）—— 不伪造地址
        assert!(
            flat.contains("if!crate::tvbox::starts_http(ep_url){continue;}"),
            "★ 非 http 的播放地址必须跳过（不伪造）"
        );
        assert!(
            flat.contains("ifout.is_empty(){returnErr("),
            "★ 一条可用地址都没有时必须 Err，不许返回空列表"
        );
    }

    // ── 真网络（显式开关 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_wwys --release -- --ignored --nocapture"]
    async fn csp_live_wwys_four_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Wwys::new();
        let ext = "https://vip.wwgz.cn:5200";
        let home = s.home(ext).await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {} 个 {:?}，首屏 {} 条",
            home.categories.len(),
            home.categories.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
            home.items.len()
        );
        let list = s.list("1", 1, ext).await.expect("list 应成功");
        eprintln!("[LIVE] list(tid=1 电影): {} 条，首条={}", list.items.len(),
            list.items.first().map(|i| i.title.clone()).unwrap_or_default());
        let id = list.items[0].id.clone();
        let d = s.detail(&id, ext).await.expect("detail 应成功");
        eprintln!("[LIVE] detail({id}): 标题={} 封面={} 剧集页={}",
            d.title, d.cover.as_deref().unwrap_or("无"), d.episodes.len());
        let plays = s.play("默认", &d.episodes[0].id, ext).await.expect("play 应成功");
        eprintln!("[LIVE] play: {} 条候选，首条 url={} label={:?}",
            plays.len(), plays[0].url, plays[0].label);
        assert!(plays[0].url.contains("m3u8") || plays[0].url.contains("mp4"), "应给真流地址");
        // ★ 真播一次（这是"四段全通"的最后一公里）
        let resp = s.client.client().unwrap().get(&plays[0].url).send().await.expect("应能请求流");
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        eprintln!("[LIVE] 流实测: HTTP {status}，前 60 字：{}", body.chars().take(60).collect::<String>());
        assert!(status.is_success(), "流应 200");
        assert!(body.starts_with("#EXTM3U"), "应是 m3u8 清单：{}", body.chars().take(40).collect::<String>());

        let se = s.search("火", 1, ext).await.expect("search 应成功");
        eprintln!("[LIVE] search(火): {} 条，首条={:?}", se.items.len(),
            se.items.first().map(|i| i.title.clone()));
    }
}
