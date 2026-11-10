// ═══════════════════════════════════════════════════════════════════════
//  csp_Wn4k —— 「蜗牛 4K 网盘站」的 Rust 重写（**本批注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 参考（DEX 逐字，`.probe/csp25/Wn4k.txt`）
// ```text
// fq=com.github.catvod.spider.Wn4k  parent=Lcom/github/catvod/spider/Pan;
// SITE = "https://wn4k.com"（常量，不从 ext 取）
// TYPES = rec/推荐 · 1/电影 · 2/连续剧 · 3/综艺 · 4/动漫
// 列表选择器（DEX 里就是 regex，不是 JSOUP）：
//   <a href="/voddetail/(\d+)/" class="video-card" title="([^"]*)"[^>]*>
//     .*?<img src="([^"]*)"[^>]*>.*?<div class="video-episode">([^<]*)</div>
// 详情：<h1 class="premium-title[^"]*"> · <span class="p-tag"> ·
//       <img src="(/upload/vod/[^"]*)" · detailDescText"> ·
//       pan-group-title"> · pan-link-title">…</div><div class="pan-link-meta">
// 站内登录：/user/login/（表单 user_name/user_pwd）
// ```
//
// # ★ 2026-10-28 真网实测（不是推测；读数见 `.probe/csp-live-live.log`）
// ```text
// $ curl --noproxy '*' -A <Chrome> https://wn4k.com/
//   HTTP 200 · 35185 B · <title>蜗牛 I 4K - 蜗牛 I 4K</title> · video-card × 60
// $ …/vodtype/1/           200 · 36 张卡（第 2 页 /vodtype/1/page/2/ 也是 36 张）
// $ …/vodsearch/-------------/?wd=仙逆   200 · 11 张卡（**必须 `wd=`**；
//    路径式 `/vodsearch/-------------/仙逆` 也 200 但返回的是「全量 24 条」= 关键词被忽略）
// $ …/voddetail/35206/     200 · 标题/封面/标签/简介都在
//   ★ 但网盘区对游客是**锁死的**：页面写着「网盘资源已锁定 / 登录后可查看完整网盘链接」，
//     每条的 meta 都是 `https://******（登录后可见）` ⇒ **取流必须登录**（DEX 里 login()/cookie 文件印证）
// ```
//
// # 本实现的能力边界（如实写，不许美化）
// ```text
// ✅ home / list / search：游客可用（真网取到数据）
// ✅ detail：标题/封面/标签/简介（游客可用）
//    · 有真网盘链接（登录态）⇒ 每条链接一集（分享页，与 Zhinan 同口径）
//    · 只有锁定标记 ⇒ 返回**一条提示集**（id=`wnt|`，文案照 DEX 常量），
//      而不是伪造 `https://******` 当播放地址 —— 这条提示集在 play() 里**明确 Err**
// ✅ play：未锁的网盘分享页原样返回（Referer 带站点），锁定的/提示的 ⇒ Err
// ```
//
// # 空结果纪律（诚实契约第 1 条）
// ```text
// home/list/search/detail 解析出 0 条 ⇒ **Err**，并写明「模板改版/风控壳页」。
// 只有 detail 的「登录墙」是**可识别的非空形态**（页面有 pan-lock-box 或锁定 meta）⇒
//   给提示集；两者都没有（既无链接也无登录提示）⇒ 仍然 Err。
// ```

use async_trait::async_trait;
use regex::Regex;
use std::sync::OnceLock;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `UA`（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// DEX `SITE`（逐字）—— 本类的站是**写死**的，不从 ext 取
pub const SITE: &str = "https://wn4k.com";

const TIMEOUT: Duration = Duration::from_secs(20);

/// DEX 的五个分类（逐字：rec/推荐 · 1/电影 · 2/连续剧 · 3/综艺 · 4/动漫）
pub const TYPES: &[(&str, &str)] = &[
    ("rec", "推荐"),
    ("1", "电影"),
    ("2", "连续剧"),
    ("3", "综艺"),
    ("4", "动漫"),
];

/// DEX 里「未登录」提示集的 vod_id 前缀（逐字 `wnt|`）与文案（逐字）
pub const TIP_ID: &str = "wnt|";
pub const LOGIN_TIP: &str = "未登录：请到配置中心-其他-蜗牛登录";

/// 锁定标记（页面里对游客显示 `https://******（登录后可见）`）
const LOCK_MARK: &str = "******";

pub struct Wn4k {
    client: super::http_context::CspHttpContext,
}

impl Wn4k {
    pub const CLASS: &'static str = "Wn4k";

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| {
            reqwest::Client::builder()
                .user_agent(UA)
                .timeout(TIMEOUT)
                // Ignore environment proxies; CspHttpContext applies app policy.
                .no_proxy()
        });
        Self { client }
    }

    async fn get(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .header(reqwest::header::REFERER, format!("{SITE}/"))
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）· 前 120 字：{}", head(&text)));
        }
        Ok(text)
    }
}

impl Default for Wn4k {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  解析（纯函数，全部可离线测；fixture 是**真响应片段**）
// ═══════════════════════════════════════════════════════════════════════

/// 一条列表项
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawItem {
    pub id: String,
    pub title: String,
    pub cover: Option<String>,
    pub episode: Option<String>,
}

/// 详情页里的一条网盘链接
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanLink {
    pub group: String,
    pub title: String,
    pub url: String,
    /// 是否被登录墙遮住（meta 里是 `https://******`）
    pub locked: bool,
}

/// 详情页解析结果
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ParsedDetail {
    pub title: String,
    pub cover: Option<String>,
    pub tags: Vec<String>,
    pub description: Option<String>,
    pub links: Vec<PanLink>,
    /// 页面明确是「登录墙」（pan-lock-box / 登录后可见 / 锁定 meta）
    pub login_wall: bool,
}

fn re_card() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"<a href="/voddetail/(\d+)/" class="video-card" title="([^"]*)""#)
            .expect("wn4k card regex")
    })
}

fn re_img() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"<img src="([^"]+)""#).expect("wn4k img regex"))
}

fn re_episode() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"<div class="video-episode">([^<]*)</div>"#).expect("wn4k episode regex")
    })
}

fn re_title() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"<h1 class="premium-title[^"]*">([^<]*)</h1>"#).expect("wn4k title regex")
    })
}

fn re_title_mobile() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"<h1 class="mobile-detail-title">([^<]*)</h1>"#)
            .expect("wn4k mobile title regex")
    })
}

fn re_cover() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"<img src="(/upload/vod/[^"]+)""#).expect("wn4k cover regex")
    })
}

fn re_tag() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"<span class="p-tag[^"]*">([^<]*)</span>"#).expect("wn4k tag regex")
    })
}

fn re_desc() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"(?s)id="detailDescText"[^>]*>(.*?)</div>"#).expect("wn4k desc regex")
    })
}

/// `pan-group-title">…<` 与 `pan-link-title">…</div><div class="pan-link-meta">…</div>`
///
/// DEX 里是两条 regex：`pan-group-title">([^<]*)<` 与
/// `<div class="pan-link-title">([^<]*)</div><div class="pan-link-meta">([^<]*)</div>`
/// —— 这里**保留原口径**，并用**出现位置**把链接归到它前面最近的分组（DEX 的
/// `parseGroups` 也是先切分组再逐组抽链接）。
fn re_group() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"pan-group-title">([^<]*)<"#).expect("wn4k group regex"))
}

fn re_pan_link() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"<div class="pan-link-title">([^<]*)</div><div class="pan-link-meta">([^<]*)</div>"#,
        )
        .expect("wn4k pan link regex")
    })
}

fn re_strip_tags() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<[^>]+>").expect("wn4k strip regex"))
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#039;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

fn strip_tags(s: &str) -> String {
    let t = re_strip_tags().replace_all(s, " ");
    unescape(&t).split_whitespace().collect::<Vec<_>>().join(" ")
}

fn abs_cover(path: &str) -> String {
    let p = path.trim();
    if p.starts_with("http://") || p.starts_with("https://") {
        p.to_string()
    } else if p.starts_with('/') {
        format!("{SITE}{p}")
    } else {
        format!("{SITE}/{p}")
    }
}

/// 解析一页列表 HTML
///
/// ⚠️ 0 条 ⇒ Err：绝不返回 `Ok(vec![])`（否则模板改版会被渲染成「这个源没内容」）。
pub fn parse_list(html: &str) -> Result<Vec<RawItem>, String> {
    let starts: Vec<(usize, usize, String, String)> = re_card()
        .captures_iter(html)
        .filter_map(|c| {
            let m = c.get(0)?;
            Some((
                m.start(),
                m.end(),
                c.get(1)?.as_str().to_string(),
                c.get(2)?.as_str().to_string(),
            ))
        })
        .collect();
    if starts.is_empty() {
        return Err(format!(
            "页面里没有任何 `video-card` 条目（模板可能改版/风控壳页）· 页面长度 {} 字节 · 前 80 字：{}",
            html.len(),
            head(html)
        ));
    }
    let mut out: Vec<RawItem> = Vec::with_capacity(starts.len());
    for (i, (start, end, id, title)) in starts.iter().enumerate() {
        // 一张卡的正文：从 `<a …>` 到下一张卡的起点（末张 ⇒ 取后 4096 字节）
        let stop = starts
            .get(i + 1)
            .map(|(s, _, _, _)| *s)
            .unwrap_or_else(|| (*start + 4096).min(html.len()));
        let block = html.get(*end..stop).unwrap_or("");
        let cover = re_img()
            .captures(block)
            .map(|c| abs_cover(c.get(1).map(|m| m.as_str()).unwrap_or("")))
            .filter(|s| !s.starts_with("data:"));
        let episode = re_episode()
            .captures(block)
            .map(|c| unescape(c.get(1).map(|m| m.as_str()).unwrap_or("")).trim().to_string())
            .filter(|s| !s.is_empty());
        let title = unescape(title).trim().to_string();
        if title.is_empty() {
            continue;
        }
        out.push(RawItem {
            id: id.clone(),
            title,
            cover,
            episode,
        });
    }
    if out.is_empty() {
        return Err("页面里有 `video-card` 标记但「没有一条」能解析出标题（模板可能改版）".to_string());
    }
    Ok(out)
}

/// 解析详情页
///
/// 结尾的「既没有链接也没有登录墙」⇒ Err：这是**模板改版**的形态，
/// 不能悄悄返回一个空详情。
pub fn parse_detail(html: &str) -> Result<ParsedDetail, String> {
    let title = re_title()
        .captures(html)
        .or_else(|| re_title_mobile().captures(html))
        .map(|c| unescape(c.get(1).map(|m| m.as_str()).unwrap_or("")).trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            format!(
                "详情页里找不到标题（模板可能改版/风控壳页）· 页面长度 {} 字节 · 前 80 字：{}",
                html.len(),
                head(html)
            )
        })?;

    let cover = re_cover()
        .captures(html)
        .map(|c| abs_cover(c.get(1).map(|m| m.as_str()).unwrap_or("")));

    let mut tags: Vec<String> = Vec::new();
    for c in re_tag().captures_iter(html) {
        let t = unescape(c.get(1).map(|m| m.as_str()).unwrap_or("")).trim().to_string();
        if !t.is_empty() && !tags.contains(&t) {
            tags.push(t);
        }
    }

    let description = re_desc()
        .captures(html)
        .map(|c| strip_tags(c.get(1).map(|m| m.as_str()).unwrap_or("")))
        .filter(|s| !s.is_empty());

    // 分组起点（按出现位置归组）
    let groups: Vec<(usize, String)> = re_group()
        .captures_iter(html)
        .filter_map(|c| {
            let m = c.get(0)?;
            Some((m.start(), c.get(1)?.as_str().trim().to_string()))
        })
        .collect();

    let mut links: Vec<PanLink> = Vec::new();
    let mut locked_seen = false;
    for c in re_pan_link().captures_iter(html) {
        let Some(m) = c.get(0) else { continue };
        let title = unescape(c.get(1).map(|x| x.as_str()).unwrap_or("")).trim().to_string();
        let meta = unescape(c.get(2).map(|x| x.as_str()).unwrap_or("")).trim().to_string();
        let locked = meta.contains(LOCK_MARK) || !meta.starts_with("http");
        if locked {
            locked_seen = true;
        }
        let group = groups
            .iter()
            .filter(|(pos, _)| *pos < m.start())
            .last()
            .map(|(_, g)| g.clone())
            .unwrap_or_else(|| "网盘".to_string());
        links.push(PanLink {
            group,
            title,
            url: meta,
            locked,
        });
    }

    let login_wall = locked_seen
        || html.contains("pan-lock-box")
        || html.contains("登录后可查看完整网盘链接")
        || html.contains("网盘资源已锁定");

    if links.is_empty() && !login_wall {
        return Err(
            "详情页里既没有网盘链接、也没有登录提示（模板可能改版/风控壳页）—— \
             已解析到标题但资源区不可识别，不能返回空详情"
                .to_string(),
        );
    }

    Ok(ParsedDetail {
        title,
        cover,
        tags,
        description,
        links,
        login_wall,
    })
}

/// 分类列表路径（DEX：`/vodtype/` + tid + `/`，翻页 `page/N/`；`rec` 走首页）
pub fn list_path(tid: &str, page: u32) -> String {
    let tid = tid.trim();
    let page = page.max(1);
    if tid.is_empty() || tid == "rec" {
        return "/".to_string();
    }
    if page == 1 {
        format!("/vodtype/{tid}/")
    } else {
        format!("/vodtype/{tid}/page/{page}/")
    }
}

/// 搜索路径（DEX：`/vodsearch/-------------/`，关键词是 **`?wd=`**）
///
/// ★ 实测：`/vodsearch/-------------/仙逆`（路径式）返回 200 但**忽略关键词**（24 条全量），
///   而 `/vodsearch/-------------/?wd=仙逆` 才是 11 条真结果 —— 写成路径式会「看起来能用」。
pub fn search_path(kw: &str, page: u32) -> String {
    let page = page.max(1);
    let wd = urlencoding::encode(kw);
    if page == 1 {
        format!("/vodsearch/-------------/?wd={wd}")
    } else {
        format!("/vodsearch/-------------/page/{page}/?wd={wd}")
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Wn4k {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let html = self.get(&format!("{SITE}/")).await?;
        let categories: Vec<CspCategory> = TYPES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        let items: Vec<CspItem> = parse_list(&html)?
            .into_iter()
            .map(|r| CspItem {
                id: r.id,
                title: r.title,
                cover: r.cover,
                subtitle: r.episode,
            })
            .collect();
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let page = page.max(1);
        let path = list_path(tid, page);
        let html = self.get(&format!("{SITE}{path}")).await?;
        let raw = parse_list(&html).map_err(|e| {
            format!(
                "分类 {} 第 {page} 页：{e}",
                if tid.trim().is_empty() { "rec" } else { tid }
            )
        })?;
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
                    subtitle: r.episode,
                })
                .collect(),
        })
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let page = page.max(1);
        let html = self.get(&format!("{SITE}{}", search_path(kw, page))).await?;
        let raw = parse_list(&html).map_err(|e| format!("搜索「{kw}」第 {page} 页：{e}"))?;
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
                    subtitle: r.episode,
                })
                .collect(),
        })
    }

    fn supports_search(&self) -> bool {
        // 真网实测：`?wd=仙逆` 返回 11 条（见文件头）⇒ 真的支持
        true
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
            return Err(format!("详情 id 形态不对（应为数字 vod_id）：`{id}`"));
        }
        let html = self.get(&format!("{SITE}/voddetail/{id}/")).await?;
        let d = parse_detail(&html)?;

        let mut episodes: Vec<CspEpisode> = d
            .links
            .iter()
            .filter(|l| !l.locked && l.url.starts_with("http"))
            .map(|l| CspEpisode {
                id: l.url.clone(),
                title: if l.title.is_empty() {
                    l.url.clone()
                } else {
                    l.title.clone()
                },
                flag: l.group.clone(),
            })
            .collect();

        // 登录墙（**上游真实形态**：DEX 里 detail 也会返回 `wnt|` 提示集）⇒ 给一条提示集，
        // 而不是伪造 `https://******`。play() 对这条**明确 Err**。
        if episodes.is_empty() {
            if !d.login_wall {
                return Err(format!("「{}」没有可播剧集（页面里没有网盘链接）", d.title));
            }
            episodes.push(CspEpisode {
                id: TIP_ID.to_string(),
                title: LOGIN_TIP.to_string(),
                flag: "提示".to_string(),
            });
        }

        Ok(CspDetail {
            id: id.to_string(),
            title: d.title,
            cover: d.cover,
            description: d.description.or_else(|| {
                if d.tags.is_empty() {
                    None
                } else {
                    Some(d.tags.join(" · "))
                }
            }),
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
                "「{LOGIN_TIP}」：本源的网盘链接对「游客锁定」（真网实测 detail 页 meta 为 \
                 `https://（登录后可见）`）⇒ 没有可播地址。\
                 上游 DEX 同样要求登录（`/user/login/` + cookie 文件 wn4k_cookie.json），\
                 本仓当前没有该站账号，因此不做假通。"
            ));
        }
        if id.contains(LOCK_MARK) {
            return Err(format!("这条是锁定占位地址（{id}），不是真链接 —— 不做假通"));
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
            label: Some(format!("{flag}（网盘分享页）")),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  自注册（判据三条同时成立：① 订阅里 1 站 csp_Wn4k；② host 写死在 DEX（wn4k.com）
//  且真网 200；③ 真网取到数据 —— home 60 条 / list 36 条 / search 11 条 / detail 元数据）
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(Wn4k);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// ★ 真响应片段（2026-10-28 抓自 `https://wn4k.com/`，原文 60 条，这里摘前 2 条）
    const FIX_LIST: &str = r#"
<main class="main"><section class="video-section"><div class="video-grid"><a href="/voddetail/35206/" class="video-card" title="仙逆 年番3"><div class="video-poster"><img src="/upload/vod/d47dd8608d26bb32a7d8fbf68c00f538.jpg" alt="仙逆 年番3" referrerpolicy="no-referrer" loading="lazy"><div class="video-score">5.0</div><div class="video-episode">4K</div></div><div class="video-info"><div class="video-title">仙逆 年番3</div><div class="video-meta"> 2026 · 中国大陆 · 动漫 </div></div></a><a href="/voddetail/16609/" class="video-card" title="灵武大陆"><div class="video-poster"><img src="/upload/vod/20260622-5/627f4e29843fff1286d6fb5506f251c9.jpg" alt="灵武大陆" loading="lazy"><div class="video-episode">4K</div></div></a></div></section></main>"#;

    /// ★ 真响应片段（2026-10-28 抓自 `https://wn4k.com/voddetail/35206/`，摘关键区）
    const FIX_DETAIL_LOCKED: &str = r#"
<section class="detail-header-premium"><div class="detail-poster-wrapper"><div class="premium-poster"><img src="/upload/vod/d47dd8608d26bb32a7d8fbf68c00f538.jpg" alt="仙逆 年番3"></div></div><div class="detail-info-premium"><div class="premium-title-wrapper"><h1 class="premium-title desktop-detail-title">仙逆 年番3</h1><div class="premium-tags-top"><span class="p-tag score">★ 5.0</span><span class="p-tag">2026</span><span class="p-tag">中国大陆</span><span class="p-tag">动漫</span><span class="p-tag">4K</span></div></div></div></section>
<section class="detail-panel"><div class="detail-panel-body"><div class="pan-lock-box"><h3 class="pan-lock-title">网盘资源已锁定</h3><p class="pan-lock-desc">游客可浏览影片信息，登录后可查看完整网盘链接。</p><div class="pan-lock-preview" aria-hidden="true"><div class="pan-group"><div class="pan-group-title">百度资源</div><div class="pan-link-list"><div class="pan-link-item is-locked"><div class="pan-link-info"><div class="pan-link-title">仙逆 年番3 4K 更新至164集 1GB/集</div><div class="pan-link-meta">https://******（登录后可见）</div></div></div><div class="pan-link-item is-locked"><div class="pan-link-info"><div class="pan-link-title">仙逆 年番 第三季 4K 1.5G/集</div><div class="pan-link-meta">https://******（登录后可见）</div></div></div><div class="pan-link-item is-locked"><div class="pan-link-info"><div class="pan-link-title">仙逆 年番3(2026)【更162集】</div><div class="pan-link-meta">https://******（登录后可见）</div></div></div></div></div></div></div></section>"#;

    /// 登录态才会出现的形态（结构照 DEX 的两条 regex 拼装；**未取得登录态真样本**，如实标注）
    const FIX_DETAIL_UNLOCKED: &str = r#"
<h1 class="premium-title desktop-detail-title">示例片名</h1><img src="/upload/vod/x.jpg">
<div class="pan-group-title">百度资源</div><div class="pan-link-list"><div class="pan-link-title">示例片 4K 全 12 集</div><div class="pan-link-meta">https://pan.baidu.com/s/1AbCdEf?pwd=1234</div></div>"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Wn4k::CLASS, "Wn4k");
    }

    #[test]
    fn list_parses_real_markup() {
        let items = parse_list(FIX_LIST).expect("真站点片段必须解析得出来");
        assert_eq!(items.len(), 2, "两张 video-card 都要出来：{items:?}");
        assert_eq!(items[0].id, "35206");
        assert_eq!(items[0].title, "仙逆 年番3");
        assert_eq!(
            items[0].cover.as_deref(),
            Some("https://wn4k.com/upload/vod/d47dd8608d26bb32a7d8fbf68c00f538.jpg"),
            "相对封面要补成绝对地址"
        );
        assert_eq!(items[0].episode.as_deref(), Some("4K"));
        assert_eq!(items[1].id, "16609");
        assert_eq!(items[1].title, "灵武大陆");
    }

    #[test]
    fn empty_list_reports_structure_change_instead_of_empty_vec() {
        // 坏样本：站点换模板 / 风控壳页
        let broken = "<html><body><div class=\"card\">请稍候…</div></body></html>";
        let err = parse_list(broken).unwrap_err();
        assert!(
            err.contains("模板可能改版") && err.contains("风控壳页"),
            "空结果必须 Err 且写明可能原因（不许 Ok(vec![])）：{err}"
        );
    }

    #[test]
    fn detail_login_wall_is_parsed_as_a_real_shape() {
        let d = parse_detail(FIX_DETAIL_LOCKED).expect("锁定页也是可识别形态");
        assert_eq!(d.title, "仙逆 年番3");
        assert!(d.login_wall, "★ 必须识别出登录墙");
        assert_eq!(d.links.len(), 3, "三条锁定链接（原文 6 条，夹具摘 3 条）");
        assert!(d.links.iter().all(|l| l.locked), "全部是锁定占位");
        assert!(
            d.links.iter().all(|l| l.group == "百度资源"),
            "分组要归到「百度资源」"
        );
        assert!(d.description.is_none(), "这段夹具没有简介（只有标签）");
        assert!(d.tags.contains(&"动漫".to_string()));
        assert_eq!(
            d.cover.as_deref(),
            Some("https://wn4k.com/upload/vod/d47dd8608d26bb32a7d8fbf68c00f538.jpg")
        );
    }

    #[test]
    fn detail_without_title_or_links_reports_reason() {
        let err = parse_detail("<html><body>nothing here</body></html>").unwrap_err();
        assert!(err.contains("找不到标题"), "缺标题要报明确原因：{err}");
        // 有标题但既无链接也无登录墙 = 模板改版
        let err2 = parse_detail("<h1 class=\"premium-title\">X</h1>").unwrap_err();
        assert!(
            err2.contains("既没有网盘链接") && err2.contains("不能返回空详情"),
            "不许空详情：{err2}"
        );
    }

    #[test]
    fn unlocked_links_become_episodes_with_group_and_url() {
        let d = parse_detail(FIX_DETAIL_UNLOCKED).expect("解锁形态要能解析");
        assert_eq!(d.links.len(), 1);
        assert!(!d.links[0].locked);
        assert_eq!(d.links[0].url, "https://pan.baidu.com/s/1AbCdEf?pwd=1234");
        assert_eq!(d.links[0].group, "百度资源");
    }

    #[test]
    fn list_and_search_paths_match_the_live_site() {
        assert_eq!(list_path("rec", 1), "/");
        assert_eq!(list_path("1", 1), "/vodtype/1/");
        assert_eq!(
            list_path("1", 2),
            "/vodtype/1/page/2/",
            "翻页是 page/N/（真网 200）"
        );
        let s1 = search_path("仙逆", 1);
        assert_eq!(s1, "/vodsearch/-------------/?wd=%E4%BB%99%E9%80%86");
        assert!(
            s1.contains("?wd="),
            "★ 关键词必须走 `wd=`（路径式会被站点忽略）"
        );
        assert!(search_path("仙逆", 2).contains("/page/2/?wd="));
    }

    #[tokio::test]
    async fn play_refuses_the_login_tip_instead_of_faking_a_stream() {
        let s = Wn4k::new();
        let err = s.play("提示", TIP_ID, "").await.expect_err("提示集必须 Err");
        assert!(err.contains("锁定") && err.contains("不做假通"), "{err}");
        // 锁定占位地址同样不许当流
        let e2 = s
            .play("百度资源", "https://******（登录后可见）", "")
            .await
            .expect_err("锁定占位必须 Err");
        assert!(e2.contains("锁定占位"), "{e2}");
    }

    #[tokio::test]
    async fn play_returns_a_share_page_for_a_real_url() {
        let s = Wn4k::new();
        let v = s
            .play("百度资源", "https://pan.baidu.com/s/1AbCdEf?pwd=1234", "")
            .await
            .expect("真链接要能返回");
        assert_eq!(v.len(), 1);
        assert!(v[0].label.as_deref().unwrap_or("").contains("分享页"));
        assert!(v[0].headers.iter().any(|(k, _)| k == "Referer"));
    }

    #[test]
    fn it_is_registered() {
        // 三条判据都成立 ⇒ 必须真的进注册表（不是只写一行宏）
        assert!(
            crate::csp::is_implemented("csp_Wn4k"),
            "★ csp_Wn4k 必须已注册（订阅 1 站 + host 可用 + 真网有数据）"
        );
        let site = crate::csp::route("csp_Wn4k").expect("route 要能拿到实例");
        assert_eq!(site.class(), "Wn4k");
    }

    /// 真网络（默认不跑；显式跑必须 `CSP_LIVE=1`，否则**失败**而不是静默通过）
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp::wn4k::tests::wn4k_live -- --ignored --nocapture"]
    async fn wn4k_live() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = Wn4k::new();
        let home = s.home("").await.expect("home 必须取到数据");
        println!(
            "LIVE|wn4k|home|分类={} 条目={}",
            home.categories.len(),
            home.items.len()
        );
        assert!(!home.items.is_empty());
        let l2 = s.list("1", 2, "").await.expect("list 第 2 页必须取到数据");
        println!(
            "LIVE|wn4k|list2|条目={} 首个={:?}",
            l2.items.len(),
            l2.items.first()
        );
        assert!(!l2.items.is_empty());
        let sr = s.search("仙逆", 1, "").await.expect("search 必须取到数据");
        println!(
            "LIVE|wn4k|search|条目={} 首个={:?}",
            sr.items.len(),
            sr.items.first()
        );
        assert!(!sr.items.is_empty());
        let first = home.items.first().unwrap().id.clone();
        let d = s.detail(&first, "").await.expect("detail 必须取到数据");
        println!(
            "LIVE|wn4k|detail|id={first}|标题={} 剧集={} 首个={:?}",
            d.title,
            d.episodes.len(),
            d.episodes.first()
        );
        assert!(!d.title.is_empty());
    }
}

#[cfg(test)]
#[path = "wn4k_proxy_tests.rs"]
mod proxy_tests;
