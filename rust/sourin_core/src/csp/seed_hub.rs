// ═══════════════════════════════════════════════════════════════════════
//  csp_SeedHub —— 「影视/动漫分享站 + 网盘分享页」的 Rust 重写（HTML 抓取）
// ═══════════════════════════════════════════════════════════════════════
//
// # 订阅里这 **1** 站（逐字，`.probe/ref-subscription.json`）
// ```json
// {"key":"SeedHub","name":"💯Seed丨网盘资源","api":"csp_SeedHub",
//  "ext":{"site":["https://sidhub.cc","https://seeduck.cc","https://hubdog.cc"]}}
// ```
// ⇒ 三条判据：① 订阅有 1 站 ✓ ② host 在 `ext.site`（三镜像）✓
//   ③ **Rust 客户端真的取到数据 ✗**（Cloudflare 挑战 rustls，详见文件尾"没有 register_site!"）
//   ⇒ 本类为「做实现、**不注册**」状态。
//
// # ★★ 2026-10-29 客户端矩阵（"不注册"的硬证据；别再为它换 TLS 栈重走一遍）
// ```text
// 同一分钟 / 同一出口 IP / 同一 URL（https://seeduck.cc/）：
//   curl 8.13 (Schannel, 协商到 TLS1.2)   → 200 / 42104 B  ✔
//   python3  (OpenSSL 3.x, TLS1.3/AES256) → 200 / 42104 B  ✔
//   .NET HttpClient (Schannel, TLS1.3)    → 403 "Just a moment..."  ✗
//   reqwest/rustls (本仓唯一栈, TLS1.3)    → 403 "Just a moment..."  ✗
// ⇒ 卡的是 **Cloudflare 的 JA3/JA4 + TLS 版本**（OpenSSL 指纹、或 Schannel@1.2 才放行），
//   不是缺头、不是缺 cookie、不是站点死：三个镜像 + seedog.cc 的页面用 curl/python 全 200。
//   已排除的无效改法（都实测过）：强制 HTTP/1.1、补全 Sec-Fetch-*/sec-ch-ua/Referer 头。
//
// ★ Rust 侧**无法钉 TLS1.2**（这是本批最贵的一条教训，别重试）：
//   · `native-tls 0.2.18` 的 `TlsConnectorBuilder` **没有** min_proto_version /
//     max_proto_version（只有 danger_accept_invalid_*）⇒ Schannel 会自己谈 1.3 ⇒ 同样 403；
//   · `reqwest::use_preconfigured_tls` 只接受 `native_tls::TlsConnector`（不是 rustls 配置）
//     ⇒ 换后端也钉不住版本。
//   ⇒ 要过只能上 **vendored OpenSSL**（OpenSSL 指纹）。已评估：为一个源把全局 TLS 栈换成
//     需要编译 openssl 的方案，构建代价 + 回归风险不值 ⇒ **决定不做**。
//   ⇒ 该尝试已回滚（`Cargo.toml` 里 native-tls 出现次数 = 0，临时模块 http_tls.rs 已删）。
// ```
//
// # 抓取形态（2026-10-27 直连实测，`curl --noproxy '*'`，不是推测）
// ```text
// home      GET {mirror}/
//           200 · 41909 bytes · <title>SeedHub | 影视&动漫分享</title>
//           class="cover" ×20（三个镜像同尺寸 ⇒ 同一套站点的三个域名）
// list      GET {mirror}/categories/{cid}/movies/?page={n}
//           200 · 38067 bytes · 20 项 · 分页末页 ?page=1407（在 .page-nav 里）
//           ★ DEX 的形状是 %s/categories/%s%s/movies/?page=%s —— 第二个 %s 是标签路径
//             （/types/7、/tags/9933），所以 tid 允许 "1" 也允许 "1/types/7"
// search    GET {mirror}/s/{kw}/?page={n}
//           200 · 23523 bytes · 20 项；无结果时页面**仍 200**（20309 bytes）但 0 个 cover
// detail    GET {mirror}/movies/{id}/
//           200 · 25042 bytes · <h1 id="cover"> 标题 / .cover-container img 海报 /
//           <h2 id="description"> 后的 <p> 简介 / ul.pan-links + ul.seeds 两组链接
// play      GET {mirror}/link_start/?redirect_to=pan_id_N
//           → 302 Location: https://seedog.cc/link_start/?…  → 200 · 15666
//           正文里 <a class="direct-pan" href="https://pan.baidu.com/s/1ROt…?pwd=i5e4">
//           ⇒ 真分享地址**必须跟完跳转**才看得到（页面挂的是站内 302，不是分享页）
// ```
//
// # 三条纪律（与 `2026-10-26-csp-honest-contract.md` 同一口径）
// ```text
// ① home/list/detail 解析出 0 条 ⇒ **Err**（写明"可能模板改版/风控壳页"），
//    不许 Ok(vec![]) 把"我没解析到"渲染成"这个源没片子"。
//    ★ 唯一例外是 search：该站"真的没有结果"也是 200 + 空容器（实测 20309 bytes），
//      所以 search 的空结果分两种，靠**容器在不在**区分：
//        · 有 <div class="cover-container"> 但 0 个 cover ⇒ 真·无结果 ⇒ Ok(空)
//        · 连容器都没有                          ⇒ 页面结构变了  ⇒ Err
// ② 镜像回退要自证：顺序试 ext.site 里的镜像，首个成功即用；
//    全失败时**汇总前 3 条 + 总条数**（只回最后一个会把"3 个里 2 个超时"说成 1 个错误）。
// ③ 判活必须直连：本机系统代理会把"站点可用"测成"全宕"（见 pan_web_share 的取证）。
//    client 链上 `.timeout(…)` 之后 `.no_proxy()`，位置**不许**动
//    （`tests/zz_r3i_no_proxy_consistency.rs` 会扫）。
// ```
//
// # HTML 解析为什么只用 `regex`（局限写在这里，别当它是 DOM 树）
// ```text
// 本仓依赖表里没有 scraper/html5ever，而"不新增运行时"是硬约束
// ⇒ 只做三处最小抽取：cover 块边界 / pan-links 与 seeds 两组 <a> / 分页页码。
// ⚠️ 局限（如实）：不做 DOM 树 ⇒ 嵌套同名标签、属性顺序变化、HTML 实体都要靠
//    正则容错；站点换主题时这里会**红**（报"可能模板改版"）而不是静默返回空。
//    属性顺序按**实测顺序**写（title 在 class="image" 之前；data-link 在 href 之前）：
//    顺序变了会解析不到 ⇒ 落进上面的 Err 分支，不会假装成功。
// ```

use async_trait::async_trait;
use regex::Regex;
use std::sync::OnceLock;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `[d]` 里的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(20);

/// 一页最多收多少条（实测一页 20；留余量防"某天站点把一页调大"撑爆内存）
const MAX_ITEMS: usize = 120;

pub struct SeedHub {
    client: reqwest::Client,
}

impl SeedHub {
    pub const CLASS: &'static str = "SeedHub";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // 与 pan_web_share / zhinan 同一条纪律：不读系统代理
            //（代理会把"站点可用"测成"全宕"，且错误文本不含真因）
            .no_proxy()
            .build()
            .expect("build seed_hub http client");
        Self { client }
    }

    /// 从 `ext` 取镜像（`{"site":["https://sidhub.cc", …]}`，也接受单个字符串）
    ///
    /// # 为什么**不给**默认站点
    /// ```text
    /// 这个类的站点**全在 ext 里**（订阅三条都与 DEX 无关），写死一个兜底 =
    /// "配置没写"和"配置写了这个站"变得不可区分 —— 而镜像是会漂的（`sd.sduc.site`
    /// 稳定 522、兄弟镜像 `shandian.blog` 稳定 200 就是先例）。
    /// ⇒ 没有 ext ⇒ 直接报"缺配置"，让用户看见事实。
    /// ```
    pub fn mirrors_of(ext: &str) -> Vec<String> {
        let Ok(j) = crate::tvbox::parse_loose_json(ext) else {
            return Vec::new();
        };
        let mut out: Vec<String> = Vec::new();
        let mut push = |s: &str| {
            let s = s.trim().trim_end_matches('/');
            if s.starts_with("http") && !out.iter().any(|x| x == s) {
                out.push(s.to_string());
            }
        };
        match j.get("site") {
            Some(serde_json::Value::Array(a)) => {
                for v in a {
                    if let Some(s) = v.as_str() {
                        push(s);
                    }
                }
            }
            Some(serde_json::Value::String(s)) => push(s),
            _ => {}
        }
        out
    }

    fn need_mirrors(ext: &str) -> Result<Vec<String>, String> {
        let m = Self::mirrors_of(ext);
        if m.is_empty() {
            return Err("SeedHub 需要 ext 里的镜像列表（键 `site`，形如 \
                 {\"site\":[\"https://sidhub.cc\"]}）—— 本类不内置默认站点：\
                 镜像会漂，写死一个会把『配置没写』伪装成『站点就是这样』"
                .to_string());
        }
        Ok(m)
    }

    /// 单次 GET（返回 body；非 2xx / 空 body 都算失败，且**带 body 前 120 字**）
    ///
    /// # 为什么不只看状态码
    /// ```text
    /// 本仓纪律：200 也不足以判活。这里把 body 一起拿回来，是因为：
    ///   · 非 2xx 时 body 常常写着真因（Cloudflare 的 "Just a moment…"、站点的维护页）；
    ///   · 2xx 但 body 为空 ⇒ 同样不能用（下面 search 的"容器判据"依赖 body 内容）。
    /// ```
    async fn get(&self, url: &str, referer: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(
                reqwest::header::ACCEPT,
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            )
            .header(reqwest::header::REFERER, format!("{referer}/"))
            .send()
            .await
            .map_err(|e| format!("请求失败：{e}"))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| format!("读取失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（body 前 120 字：{}）", head(&body)));
        }
        if body.trim().is_empty() {
            return Err("HTTP 2xx 但 body 为空（不能当成功）".to_string());
        }
        Ok(body)
    }

    /// 按 `ext.site` 顺序试镜像，首个成功即用；全失败时**汇总**前 3 条 + 总数
    async fn fetch_first(&self, mirrors: &[String], path: &str) -> Result<String, String> {
        let mut fails: Vec<String> = Vec::new();
        for m in mirrors {
            let url = format!("{m}{path}");
            match self.get(&url, m).await {
                Ok(body) => return Ok(body),
                Err(e) => fails.push(format!("{m} → {e}")),
            }
        }
        Err(format!(
            "{} 个镜像全部失败（路径 {path}）：前 {} 条 —— {}",
            mirrors.len(),
            fails.len().min(3),
            fails
                .iter()
                .take(3)
                .cloned()
                .collect::<Vec<_>>()
                .join("；")
        ))
    }
}

impl Default for SeedHub {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

/// 去掉标签 + 解常见实体 + 压空白（`regex` 版的"取文本"）
pub fn strip_tags(s: &str) -> String {
    static TAGS: OnceLock<Regex> = OnceLock::new();
    let tags = TAGS.get_or_init(|| Regex::new(r"(?s)<[^>]*>").unwrap());
    let t = tags.replace_all(s, " ");
    let t = html_unescape(&t);
    t.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 只解站内真出现的那几个实体（`&#039;` / `&amp;` / `&#9749;` 这类数字实体也解）
fn html_unescape(s: &str) -> String {
    static NUM: OnceLock<Regex> = OnceLock::new();
    let num = NUM.get_or_init(|| Regex::new(r"&#(\d{1,6});").unwrap());
    let mut out = s
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">");
    out = num
        .replace_all(&out, |c: &regex::Captures| {
            c[1]
                .parse::<u32>()
                .ok()
                .and_then(char::from_u32)
                .map(|ch| ch.to_string())
                .unwrap_or_default()
        })
        .into_owned();
    out
}

/// 首页/列表/搜索页的**分类表**（侧栏 `/categories/N/movies/` 那三个组）
pub fn parse_categories(html: &str) -> Vec<CspCategory> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(r#"href="/categories/(\d{1,4})/movies/"[^>]*>([^<]{1,40})</a>"#).unwrap()
    });
    let mut out: Vec<CspCategory> = Vec::new();
    for c in re.captures_iter(html) {
        let id = c[1].to_string();
        let name = strip_tags(&c[2]);
        if name.is_empty() {
            continue;
        }
        if !out.iter().any(|x| x.id == id) {
            out.push(CspCategory { id, name });
        }
    }
    out
}

/// 列表条目：按 `class="cover"` 块切，块内取 id/title/img/meta
///
/// # 为什么按 `<div class="cover">` 切而不是按 `<a href="/movies/…">`
/// ```text
/// 详情页里也有 `href="/movies/…"`（推荐区），按链接切会把"推荐"混进列表。
/// `class="cover"` 是列表页**特有**的条目外壳（实测：首页 20、分类页 20、搜索页 20，
/// 而 0 结果的搜索页是 0）⇒ 它同时是"有没有结果"的判据。
/// ```
pub fn parse_items(html: &str) -> Vec<CspItem> {
    static ID: OnceLock<Regex> = OnceLock::new();
    static TITLE: OnceLock<Regex> = OnceLock::new();
    static IMG: OnceLock<Regex> = OnceLock::new();
    static META: OnceLock<Regex> = OnceLock::new();
    let id_re = ID.get_or_init(|| Regex::new(r#"href="/movies/(\d{1,9})/""#).unwrap());
    let title_re = TITLE.get_or_init(|| Regex::new(r#"title="([^"]*)""#).unwrap());
    let img_re = IMG.get_or_init(|| Regex::new(r#"<img src="([^"]+)""#).unwrap());
    // 「2024 / 剧集 / 美国 中国大陆 英国 / 英语 … / 演员」
    let meta_re = META.get_or_init(|| Regex::new(r"<li>(\d{4}[^<]{0,240})</li>").unwrap());
    let mut out: Vec<CspItem> = Vec::new();
    for block in html.split(r#"<div class="cover">"#).skip(1) {
        let Some(idc) = id_re.captures(block) else { continue };
        let id = idc[1].to_string();
        // 标题优先取 `<a … title="…">`（实测在 class="image" 之前），退到空
        let title = title_re
            .captures(block)
            .map(|c| strip_tags(&c[1]))
            .filter(|s| !s.is_empty())
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let cover = img_re
            .captures(block)
            .map(|c| c[1].to_string())
            .filter(|s| s.starts_with("http"));
        let subtitle = meta_re
            .captures(block)
            .map(|c| strip_tags(&c[1]))
            .filter(|s| !s.is_empty());
        if out.len() >= MAX_ITEMS {
            break;
        }
        out.push(CspItem {
            id,
            title,
            cover,
            subtitle,
        });
    }
    out
}

/// 分页末页号：`.page-nav` 里出现的最大 `?page=N`
pub fn parse_page_count(html: &str) -> Option<u32> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r#"\?page=(\d{1,6})"#).unwrap());
    let start = html.find(r#"class="page-nav""#)?;
    let seg = &html[start..];
    // 只扫分页块附近一小段（分页块很短），避免吃进页面别处的 `?page=`
    let seg = &seg[..seg.len().min(4000)];
    re.captures_iter(seg)
        .filter_map(|c| c[1].parse::<u32>().ok())
        .max()
}

/// 页面里有没有"结果容器"（区分「真·无结果」与「模板改版」）
pub fn has_result_container(html: &str) -> bool {
    html.contains(r#"<div class="cover-container">"#)
}

/// 详情页解析（id 为 `/movies/{id}/` 里的数字）
pub fn parse_detail(html: &str, id: &str, host: &str) -> Result<CspDetail, String> {
    static H1: OnceLock<Regex> = OnceLock::new();
    static IMG: OnceLock<Regex> = OnceLock::new();
    static DESC: OnceLock<Regex> = OnceLock::new();
    let title_re = H1.get_or_init(|| Regex::new(r#"(?s)<h1 id="cover">(.*?)</h1>"#).unwrap());
    let img_re = IMG.get_or_init(|| Regex::new(r#"<img src="([^"]+)""#).unwrap());
    let desc_re = DESC
        .get_or_init(|| Regex::new(r#"(?s)<h2 id="description">.*?</h2>\s*<p>(.*?)</p>"#).unwrap());

    let title = title_re
        .captures(html)
        .map(|c| strip_tags(&c[1]).trim_start_matches('#').trim().to_string())
        .unwrap_or_default();
    if title.is_empty() {
        return Err(format!(
            "详情页没解析出标题（id={id}）—— 可能模板改版/风控壳页"
        ));
    }
    let cover = html
        .find(r#"<div class="cover-container">"#)
        .and_then(|i| img_re.captures(&html[i..]))
        .map(|c| c[1].to_string())
        .filter(|s| s.starts_with("http"));
    let description = desc_re
        .captures(html)
        .map(|c| strip_tags(&c[1]))
        .filter(|s| !s.is_empty());

    let mut episodes: Vec<CspEpisode> = Vec::new();
    // ① 网盘组（ul.pan-links）：data-link 是盘类型，href 是站内 302 入口
    for (flag, href, text) in pan_links(html) {
        episodes.push(CspEpisode {
            id: absolutize(&href, host),
            title: text,
            flag,
        });
    }
    // ② 磁力组（ul.seeds）：同一个 /link_start/，但走 seed_id
    for (href, text) in seed_links(html) {
        episodes.push(CspEpisode {
            id: absolutize(&href, host),
            title: text,
            flag: "磁力".to_string(),
        });
    }
    if episodes.is_empty() {
        return Err(format!(
            "「{title}」没有任何网盘/磁力链接（ul.pan-links 与 ul.seeds 都空）—— \
             可能模板改版/风控壳页"
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

fn absolutize(href: &str, host: &str) -> String {
    if href.starts_with("http") {
        href.to_string()
    } else if href.starts_with('/') {
        format!("{host}{href}")
    } else {
        format!("{host}/{href}")
    }
}

/// `ul.pan-links` 里的 `(盘标签, href, 文本)` 三件套
fn pan_links(html: &str) -> Vec<(String, String, String)> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(r#"(?s)<a[^>]*?data-link="([^"]*)"[^>]*?href="([^"]+)"[^>]*?>(.*?)</a>"#)
            .unwrap()
    });
    let Some(seg) = segment(html, r#"class="pan-links""#) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for c in re.captures_iter(seg) {
        let text = strip_tags(&c[3]);
        if text.is_empty() {
            continue;
        }
        out.push((cloud_label(&c[1]), c[2].to_string(), clip(&text, 80)));
        if out.len() >= MAX_ITEMS {
            break;
        }
    }
    out
}

/// `ul.seeds` 里的 `(href, 文本)`
fn seed_links(html: &str) -> Vec<(String, String)> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(
            r#"(?s)<a[^>]*?title="([^"]*)"[^>]*?href="(/link_start/\?seed_id=[^"]+)"[^>]*>(.*?)</a>"#,
        )
        .unwrap()
    });
    let Some(seg) = segment(html, r#"class="seeds""#) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for c in re.captures_iter(seg) {
        // 标题优先用 `title=`（列表里的正文会被站点截成 "…"）
        let text = strip_tags(&c[1]);
        let text = if text.is_empty() { strip_tags(&c[3]) } else { text };
        if text.is_empty() {
            continue;
        }
        out.push((c[2].to_string(), clip(&text, 80)));
        if out.len() >= MAX_ITEMS {
            break;
        }
    }
    out
}

/// 从 `needle` 处切到下一个 `</ul>`（块都很短；找不到就整段不认）
fn segment<'a>(html: &'a str, needle: &str) -> Option<&'a str> {
    let i = html.find(needle)?;
    let rest = &html[i..];
    let end = rest.find("</ul>").map(|e| e + 5).unwrap_or(rest.len());
    Some(&rest[..end.min(rest.len())])
}

fn clip(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    s.chars().take(n).collect::<String>() + "…"
}

/// `data-link`（`pan.baidu.com` 这种）→ 用户可读的盘名（DEX `[h]` 的三项 + 其余兜底）
pub fn cloud_label(data_link: &str) -> String {
    let l = data_link.to_ascii_lowercase();
    let name = if l.contains("baidu") {
        "百度"
    } else if l.contains("quark") {
        "夸克"
    } else if l.contains("uc") {
        "UC"
    } else if l.contains("xunlei") {
        "迅雷"
    } else if l.contains("ali") {
        "阿里"
    } else if l.contains("115") {
        "115"
    } else if l.contains("123") {
        "123"
    } else if l.contains("189") || l.contains("tianyi") {
        "天翼"
    } else if l.contains("guangya") {
        "光鸭"
    } else {
        return data_link.trim().to_string();
    };
    name.to_string()
}

/// 是不是**网盘分享页**（不是直链）：用于 play 的自证与拒绝
pub fn is_pan_share(url: &str) -> bool {
    const HOSTS: &[&str] = &[
        "pan.quark.cn",
        "pan.baidu.com",
        "drive.uc.cn",
        "aliyundrive.com",
        "alipan.com",
        "cloud.189.cn",
        "cloud.189.com",
        "115.com",
        "115cdn.com",
        "anxia.com",
        "guangyapan.com",
        "pan.xunlei.com",
        "123pan.com",
        "123684.com",
        "123865.com",
    ];
    HOSTS.iter().any(|h| url.contains(h))
}

/// 从 `/link_start/` 的落地页里取真正的分享地址（`a.direct-pan` 的 href）
pub fn parse_direct_pan(body: &str) -> Option<String> {
    static RE: OnceLock<Regex> = OnceLock::new();
    static FALLBACK: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r#"(?s)class="direct-pan"[^>]*?href="([^"]+)""#).unwrap());
    if let Some(c) = re.captures(body) {
        let u = html_unescape(&c[1]);
        if is_pan_share(&u) {
            return Some(u);
        }
    }
    // 兜底：任何一处网盘分享链接（实测落地页正文里只会出现一条）
    let fb = FALLBACK.get_or_init(|| {
        Regex::new(
            r#"https://[a-zA-Z0-9.-]*(?:quark\.cn|baidu\.com|uc\.cn|189\.cn|115\.com|xunlei\.com|alipan\.com|aliyundrive\.com)[^"'\s<>]*"#,
        )
        .unwrap()
    });
    fb.find(body).map(|m| html_unescape(m.as_str()))
}

// ══ ⚠️ **没有 `register_site!`**：三条判据缺第 ③（Rust 客户端取不到数据）══
//
// 2026-10-27 实测矩阵（同一分钟、同一 IP、同一 UA）：
// ```text
// curl（OpenSSL）  https://sidhub.cc/  → 302 → https://seedog.cc/  → 200 · 41909 bytes
//                  seeduck.cc / hubdog.cc 同样 302 → seedog.cc → 200 · 41909 bytes
// reqwest(rustls)  https://sidhub.cc/  → 302 → seedog.cc → **403**
//                  body = <title>Just a moment...</title>   ← Cloudflare 挑战页（不是 5xx、不是超时）
// 变量排查（逐项只改一处，全部仍 403）：
//   ① 原样头（UA + Accept + Referer）                     → 403
//   ② 只留 UA                                            → 403
//   ③ `.http1_only()`（排除 HTTP/2 指纹）                 → 403
//   ④ 补 Chrome 全套（Accept-Language / sec-ch-ua / sec-fetch-*）→ 403
// ⇒ 头部与 HTTP 版本都不是变量 ⇒ 剩下 **TLS 指纹（JA3/JA4）**：Cloudflare 对 rustls 的
//   握手特征直接发挑战，而 curl/OpenSSL 的特征是放行的。
// ⇒ 本仓 `Cargo.toml` 零 diff（不许新增依赖 / 不许换 TLS 后端）⇒ **这一层绕不过去**。
// ⇒ 按纪律：**做实现、不注册**；一旦某镜像不再挑战 rustls（或将来允许换后端），
//   只需补回 `crate::csp::register_site!(SeedHub);` 这一行，其余代码不用动。
// ```

#[async_trait]
impl CspSite for SeedHub {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let mirrors = Self::need_mirrors(ext)?;
        let html = self.fetch_first(&mirrors, "/").await?;
        let categories = parse_categories(&html);
        if categories.is_empty() {
            return Err("首页没解析出分类（侧栏 `/categories/N/movies/` 链接为空）—— \
                 可能模板改版/风控壳页"
                .to_string());
        }
        let items = parse_items(&html);
        if items.is_empty() {
            return Err("首页没解析出条目（`class=\"cover\"` 块为 0）—— \
                 可能模板改版/风控壳页"
                .to_string());
        }
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim().trim_matches('/');
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        // tid 允许 "1" 与 "1/types/7"（/tags/9933）；只放行数字与斜杠，别把路径拼歪
        let ok_shape = tid.chars().all(|c| c.is_ascii_digit() || c == '/')
            && tid.starts_with(|c: char| c.is_ascii_digit());
        if !ok_shape {
            return Err(format!("分类 id 形状不对：{tid}（应为 1 或 1/types/7）"));
        }
        let page = if page == 0 { 1 } else { page };
        let mirrors = Self::need_mirrors(ext)?;
        let path = format!("/categories/{tid}/movies/?page={page}");
        let html = self.fetch_first(&mirrors, &path).await?;
        let items = parse_items(&html);
        if items.is_empty() {
            return Err(format!(
                "分类 {tid} 第 {page} 页没解析出条目（`class=\"cover\"` 块为 0）—— \
                 可能模板改版/风控壳页，或页码超出末页"
            ));
        }
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
            return Err("搜索关键词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let mirrors = Self::need_mirrors(ext)?;
        let path = format!("/s/{}/?page={page}", urlencoding::encode(kw));
        let html = self.fetch_first(&mirrors, &path).await?;
        if !has_result_container(&html) {
            return Err(format!(
                "搜索页没有结果容器（`div.cover-container` 缺失，kw={kw}）—— \
                 可能模板改版/风控壳页"
            ));
        }
        // ★ 容器在、条目为 0 ⇒ 站点**真的**没有这个片（实测：无结果页 200/20309 bytes）
        let items = parse_items(&html);
        Ok(CspList {
            items,
            page,
            page_count: parse_page_count(&html),
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        true // 真实现且真网验证过（`/s/{kw}/?page=N` → 20 条）
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let id = id.trim().trim_matches('/');
        if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
            return Err(format!("详情 id 应为 /movies/ 后的数字，实际：{id}"));
        }
        let mirrors = Self::need_mirrors(ext)?;
        let html = self
            .fetch_first(&mirrors, &format!("/movies/{id}/"))
            .await?;
        parse_detail(&html, id, &mirrors[0])
    }

    /// 取"流"：**网盘分享页**（不是直链）
    ///
    /// # 为什么不返回 `vod_play_url` 里的站内 302 链接就完事
    /// ```text
    /// `/link_start/?redirect_to=pan_id_N` 是**站内跳转入口**（实测还会 302 到兄弟域名
    /// seedog.cc 再给落地页），直接把入口当播放地址 ⇒ 播放器拿到一个 HTML 页面。
    /// ⇒ 这里跟完跳转、从落地页取 `a.direct-pan` 的真实分享地址，label 写明"（分享页）"。
    /// 把分享页解成直链属网盘模块（第 20 项），本类**不伪造** m3u8/mp4。
    /// ```
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let mirrors = Self::need_mirrors(ext)?;
        let host = mirrors[0].clone();
        let url = absolutize(id.trim(), &host);
        if !url.contains("/link_start/") && !is_pan_share(&url) {
            return Err(format!(
                "SeedHub 的剧集 id 应是站内 /link_start/ 入口或网盘分享页，实际：{url}"
            ));
        }
        // 已经是分享页 ⇒ 不必再请求（省一次网络，也避免"分享页被墙"时的假失败）
        if is_pan_share(&url) {
            return Ok(vec![share_play(url, flag, &host)]);
        }
        let body = self
            .get(&url, &host)
            .await
            .map_err(|e| format!("取分享页失败（{flag} / {url}）：{e}"))?;
        let pan = parse_direct_pan(&body).ok_or_else(|| {
            format!(
                "跳转落地页里没有网盘分享链接（{flag} / {url}）—— 可能链接失效/风控壳页\
                 （body 前 120 字：{}）",
                head(&body)
            )
        })?;
        Ok(vec![share_play(pan, flag, &host)])
    }
}

fn share_play(url: String, flag: &str, host: &str) -> CspPlay {
    CspPlay {
        url,
        headers: vec![("Referer".to_string(), format!("{host}/"))],
        label: Some(format!("{flag}（分享页）")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── 真实响应片段（2026-10-27 直连抓的 https://sidhub.cc/ ，只截结构）──
    const HOME_FRAGMENT: &str = r#"
<div class="sidebar-group first">
  <p class="sidebar-heading open"><span><a href="/categories/2/movies/">动漫</a></span></p>
  <p class="sidebar-heading open"><span><a href="/categories/3/movies/">剧集</a></span></p>
  <p class="sidebar-heading open"><span><a href="/categories/1/movies/">电影</a></span></p>
  <ul class="sidebar-sub-headers">
    <li class="sidebar-sub-header"><a href="/categories/1/types/7/movies/" class="sidebar-link">剧情</a></li>
  </ul>
</div>
<div class="cover-container">
  <div class="cover">
    <a target="_blank" rel="noopener noreferrer" title="生化危机：爆发夜 Resident Evil" class="image" href="/movies/130096/"><img src="https://sh1.pcie.pppoe.top/static/pics/p178996646087366990.webp" alt="生化危机：爆发夜 Resident Evil" ></a>
    <ul>
      <li><h2><a target="_blank" rel="noopener noreferrer" href="/movies/130096/" aria-hidden="true" class="header-anchor">#</a> 生化危机：爆发夜</h2></li>
      <li>2026 / 电影 / 动作 / 英语 / 扎克·克雷格 奥斯汀·艾布拉姆斯 </li>
      <li>标签: <a target="_blank" title="惊悚" href="/categories/1/types/3/movies/">惊悚</a></li>
    </ul>
  </div>
  <div class="cover">
    <a target="_blank" rel="noopener noreferrer" title="蜘蛛侠：崭新之日 Spider-Man" class="image" href="/movies/119946/"><img src="https://sh1.pcie.pppoe.top/static/pics/p178514473131709862.webp" alt="蜘蛛侠：崭新之日 Spider-Man" ></a>
    <ul>
      <li><h2><a href="/movies/119946/" class="header-anchor">#</a> 蜘蛛侠：崭新之日</h2></li>
      <li>2026 / 电影 / 科幻 / 英语 / 汤姆·霍兰德 </li>
    </ul>
  </div>
</div>
"#;

    // 真实分页片段（/categories/1/movies/?page=1 的 .page-nav）
    const PAGENAV_FRAGMENT: &str = r#"
  <div class="page-nav">
    <p class="inner">
      <span class="prev"><a class="router-link-active" disabled> 上一页 </a></span>
      <span class="page active"><span>1 <span class="sr-only"></span></span></span>
      <span class="page"><a href="?page=2">2</a></span>
      <span class="page"><a href="?page=3">3</a></span>
      <span class="page"><a href="?page=1407">1407</a></span>
      <span class="next"><a title="下一页" href="?page=2"> 下一页 </a></span>
    </p>
  </div>
"#;

    // 真实详情页片段（/movies/130096/），只留标题/海报/简介/两组链接
    // ⚠️ 用 `r##"…"##`：片段里有 `href="#cover"`，`"#` 会提前终止 `r#"…"#`
    const DETAIL_FRAGMENT: &str = r##"
<div class="content">
  <h1 id="cover"><a href="#cover" aria-hidden="true" class="header-anchor">#</a> 生化危机：爆发夜 Resident Evil</h1>
  <div class="cover-container">
    <img src="https://sh1.pcie.pppoe.top/static/pics/p178996646087366990.webp" title="点击查看海报" alt="生化危机：爆发夜 Resident Evil" onclick="window.open(this.src)">
    <ul>
      <li>导演: <a href="https://movie.douban.com/subject_search?search_text=x">扎克·克雷格</a></li>
      <li>主演: <a href="https://movie.douban.com/subject_search?search_text=y">奥斯汀·艾布拉姆斯</a> / ......</li>
    </ul>
  </div>
  <h2 id="description"><a rel="nofollow" href="#description" aria-hidden="true" class="header-anchor">#</a> 生化危机：爆发夜的简介 </h2>
  <p>故事聚焦奉命奔赴浣熊市的医疗速递员布莱恩，意外深陷全城失控的病毒浩劫。</p>
  <ul class="seeds" style="margin: 30px 0;">
    <li>
      <a target="_blank" rel="nofollow" title="Rezident Evil (2026)[1080p][2.78G]" href="/link_start/?seed_id=757834&movie_title=x">Rezident Evil (2026)[1080p][2.78G]</a> / <code class="size">2.78G</code>
    </li>
  </ul>
  <ul class="pan-links" style="margin: 30px 0;display:none;">
    <li>
      <a target="_blank" rel="nofollow" title="【生化危机：爆发夜】【1080P/超清】" class="p-first" data-link="pan.baidu.com" href="/link_start/?redirect_to=pan_id_845923&movie_title=x">【生化危机：爆发夜】【1080P/超清】</a>
    </li>
    <li>
      <a target="_blank" rel="nofollow" data-link="pan.quark.cn" href="/link_start/?redirect_to=pan_id_845800&movie_title=y">纯净分享 夸克</a>
    </li>
  </ul>
</div>
"##;

    // 真实「无结果」搜索页的特征（200，有容器，0 个 cover）
    const NO_RESULT_FRAGMENT: &str =
        r#"<div class="content"><div class="cover-container"></div></div>"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(SeedHub::CLASS, "SeedHub");
    }

    #[test]
    fn must_not_be_registered_because_rustls_gets_challenged() {
        // ① 订阅 1 站 ✓ ② ext.site 三镜像 ✓ ③ Rust 客户端取到数据 ✗（Cloudflare 挑战 rustls）
        let flat = crate::csp::shared::impl_src_only(include_str!("seed_hub.rs"));
        assert!(
            !flat.contains("register_site!(SeedHub)"),
            "★ ③ 不成立（reqwest/rustls 被 Cloudflare 403 挑战）⇒ 本批不许注册"
        );
        assert!(
            !crate::csp::is_implemented("csp_SeedHub"),
            "★ 不许进注册表：注册 = 交付『看起来支持但取不到数据』的类"
        );
    }

    #[test]
    fn mirrors_come_from_ext_and_never_from_a_builtin_default() {
        let ext = r#"{"site":["https://sidhub.cc","https://seeduck.cc","https://hubdog.cc"]}"#;
        assert_eq!(
            SeedHub::mirrors_of(ext),
            vec![
                "https://sidhub.cc".to_string(),
                "https://seeduck.cc".to_string(),
                "https://hubdog.cc".to_string()
            ]
        );
        // 单个字符串形态也认
        assert_eq!(
            SeedHub::mirrors_of(r#"{"site":"https://sidhub.cc/"}"#),
            vec!["https://sidhub.cc".to_string()]
        );
        // ★ 没有 ext ⇒ 空（绝不内置默认站点）
        assert!(SeedHub::mirrors_of("").is_empty());
        assert!(SeedHub::mirrors_of("{}").is_empty());
        // 去重 + 只留 http
        assert_eq!(
            SeedHub::mirrors_of(r#"{"site":["https://a.test","https://a.test/","nope"]}"#),
            vec!["https://a.test".to_string()]
        );
    }

    #[tokio::test]
    async fn every_segment_reports_missing_ext() {
        let s = SeedHub::new();
        for e in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.search("三体", 1, "").await.err(),
            s.detail("130096", "").await.err(),
            s.play("百度", "/link_start/?redirect_to=pan_id_1", "")
                .await
                .err(),
        ] {
            let msg = e.expect("无 ext 必须 Err");
            assert!(msg.contains("ext"), "{msg}");
            assert!(msg.contains("site"), "{msg}");
        }
    }

    #[test]
    fn categories_are_read_from_the_sidebar() {
        let cats = parse_categories(HOME_FRAGMENT);
        assert_eq!(
            cats,
            vec![
                CspCategory {
                    id: "2".into(),
                    name: "动漫".into()
                },
                CspCategory {
                    id: "3".into(),
                    name: "剧集".into()
                },
                CspCategory {
                    id: "1".into(),
                    name: "电影".into()
                },
            ],
            "★ 侧栏三组（DEX 里 1=电影 3=剧集 2=动漫）"
        );
        // 标签子链接（/types/7）不许被当成分类
        assert!(!cats.iter().any(|c| c.id == "7"));
    }

    #[test]
    fn items_are_parsed_from_real_cover_blocks() {
        let items = parse_items(HOME_FRAGMENT);
        assert_eq!(items.len(), 2, "★ 两个 cover 块 ⇒ 两条");
        assert_eq!(items[0].id, "130096");
        assert_eq!(items[0].title, "生化危机：爆发夜 Resident Evil");
        assert_eq!(
            items[0].cover.as_deref(),
            Some("https://sh1.pcie.pppoe.top/static/pics/p178996646087366990.webp")
        );
        assert_eq!(
            items[0].subtitle.as_deref(),
            Some("2026 / 电影 / 动作 / 英语 / 扎克·克雷格 奥斯汀·艾布拉姆斯"),
            "★ 副标题就是列表里那行「年份 / 类型 / …」"
        );
        assert_eq!(items[1].id, "119946");
    }

    #[test]
    fn page_count_is_the_max_page_number() {
        assert_eq!(parse_page_count(PAGENAV_FRAGMENT), Some(1407));
        assert_eq!(
            parse_page_count("<html></html>"),
            None,
            "没有 page-nav ⇒ None"
        );
    }

    #[test]
    fn detail_keeps_pan_and_magnet_links_with_absolute_ids() {
        let d = parse_detail(DETAIL_FRAGMENT, "130096", "https://sidhub.cc").unwrap();
        assert_eq!(d.title, "生化危机：爆发夜 Resident Evil");
        assert_eq!(
            d.cover.as_deref(),
            Some("https://sh1.pcie.pppoe.top/static/pics/p178996646087366990.webp")
        );
        assert!(d
            .description
            .as_deref()
            .unwrap_or_default()
            .contains("浣熊市"));
        assert_eq!(d.episodes.len(), 3, "2 条网盘 + 1 条磁力");
        // 网盘线：flag 是盘名（用户可读），id 是**绝对**的站内 302 入口
        assert_eq!(d.episodes[0].flag, "百度");
        assert_eq!(
            d.episodes[0].id,
            "https://sidhub.cc/link_start/?redirect_to=pan_id_845923&movie_title=x"
        );
        assert_eq!(d.episodes[1].flag, "夸克");
        // 磁力线
        assert_eq!(d.episodes[2].flag, "磁力");
        assert!(d.episodes[2].id.contains("seed_id=757834"));
        assert_eq!(d.episodes[2].title, "Rezident Evil (2026)[1080p][2.78G]");
    }

    #[test]
    fn detail_without_any_link_is_an_error_not_an_empty_detail() {
        let html = r#"<div class="content"><h1 id="cover"><a class="header-anchor">#</a> 某片</h1>
            <ul class="pan-links"></ul><ul class="seeds"></ul></div>"#;
        let e = parse_detail(html, "1", "https://sidhub.cc").expect_err("★ 0 条必须 Err");
        assert!(e.contains("可能模板改版/风控壳页"), "{e}");
    }

    #[test]
    fn detail_without_title_is_an_error() {
        let broken = DETAIL_FRAGMENT.replace(r#"<h1 id="cover">"#, r#"<h1 id="nope">"#);
        let e = parse_detail(&broken, "1", "https://sidhub.cc").expect_err("没标题必须 Err");
        assert!(e.contains("模板改版"), "{e}");
    }

    #[test]
    fn zero_result_search_page_is_distinguishable_from_a_broken_template() {
        // 真·无结果：有容器、0 个 cover
        assert!(has_result_container(NO_RESULT_FRAGMENT));
        assert!(parse_items(NO_RESULT_FRAGMENT).is_empty());
        // 风控壳页/改版：连容器都没有
        assert!(!has_result_container(
            "<html><body>Just a moment…</body></html>"
        ));
    }

    #[test]
    fn direct_pan_comes_from_the_landing_page() {
        let body = r#"<p class="link-start" ><a class="direct-pan" target="_blank" rel="nofollow" href="https://pan.baidu.com/s/1ROthCWgXlaMvGQeb_EmPBA?pwd=i5e4">→ 前往网盘转存</a></p>"#;
        assert_eq!(
            parse_direct_pan(body).as_deref(),
            Some("https://pan.baidu.com/s/1ROthCWgXlaMvGQeb_EmPBA?pwd=i5e4")
        );
        // 没有 direct-pan 时退到"任何一处网盘分享链接"
        let body2 = r#"<meta http-equiv="refresh" content="0;url=https://pan.quark.cn/s/abc123">"#;
        assert_eq!(
            parse_direct_pan(body2).as_deref(),
            Some("https://pan.quark.cn/s/abc123")
        );
        // 风控壳页：什么也没有 ⇒ None（调用方会 Err，不许假装成功）
        assert_eq!(parse_direct_pan("<html>Just a moment…</html>"), None);
    }

    #[test]
    fn pan_share_detection_covers_the_nine_clouds() {
        for u in [
            "https://pan.quark.cn/s/90e6692f0e25",
            "https://pan.baidu.com/s/1abc",
            "https://drive.uc.cn/s/abc",
            "https://www.aliyundrive.com/s/abc",
            "https://www.alipan.com/s/abc",
            "https://cloud.189.cn/t/abc",
            "https://115.com/s/abc",
            "https://pan.xunlei.com/s/abc",
        ] {
            assert!(is_pan_share(u), "{u} 应判为分享页");
        }
        assert!(!is_pan_share(
            "https://sidhub.cc/link_start/?redirect_to=pan_id_1"
        ));
        assert!(!is_pan_share("https://example.com/a.m3u8"));
    }

    #[test]
    fn cloud_label_maps_data_link_to_readable_name() {
        assert_eq!(cloud_label("pan.baidu.com"), "百度");
        assert_eq!(cloud_label("pan.quark.cn"), "夸克");
        assert_eq!(cloud_label("drive.uc.cn"), "UC");
        assert_eq!(cloud_label("pan.xunlei.com"), "迅雷");
        assert_eq!(cloud_label("www.aliyundrive.com"), "阿里");
        assert_eq!(cloud_label(""), "");
    }

    /// ★ 结构性判据：`.no_proxy()` 必须在 `.timeout(…)` 之后、`.build()` 之前
    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("seed_hub.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("必须有 .timeout");
        let n = flat.find(".no_proxy()").expect("★ 必须 .no_proxy()");
        let b = flat.find(".build()").expect("必须有 .build()");
        assert!(t < n && n < b, "★ 位置必须是 timeout → no_proxy → build");
    }

    // ══════════════════════════════════════════════════════════════════
    //  真网络（`#[ignore]`）：不给 `CSP_LIVE=1` 就**断言失败**，
    //  不做"没变量就 return"的假绿（照 zhinan.rs 的口径）
    // ══════════════════════════════════════════════════════════════════
    const LIVE_EXT: &str =
        r#"{"site":["https://sidhub.cc","https://seeduck.cc","https://hubdog.cc"]}"#;

    fn need_live() {
        assert_eq!(
            std::env::var("CSP_LIVE").as_deref(),
            Ok("1"),
            "真网络用例：必须 `CSP_LIVE=1 cargo test --lib csp::seed_hub:: -- --ignored` 才跑"
        );
    }

    /// 真网读数（**两种结局都算过**，但都必须"可读"）
    ///
    /// ```text
    /// 2026-10-27 现状：reqwest(rustls) → 403 Cloudflare 挑战 ⇒ Err 分支
    ///   （curl/OpenSSL 同一分钟同一 IP 是 200/41909 bytes —— 差值在 TLS 指纹）
    /// ⇒ 这条用例今天走 Err 分支，断言"错误里必须写明 3 个镜像全失败 + 403 + 挑战页"，
    ///   而不是"静默返回空数据"。
    ///   哪天线开了（换后端 / 镜像不挑战），它会走 Ok 分支并把真实条目数打出来。
    /// ```
    #[tokio::test]
    #[ignore]
    async fn live_mirrors_record_what_the_rust_client_can_actually_get() {
        need_live();
        let s = SeedHub::new();

        let home = match s.home(LIVE_EXT).await {
            Ok(h) => h,
            Err(e) => {
                println!("LIVE seed_hub home: ERR {e}");
                // ★ 失败也必须可读：镜像数 + 403 + 挑战页特征，缺一条就是"不可读的失败"
                assert!(e.contains("个镜像全部失败"), "错误必须汇总镜像数：{e}");
                assert!(e.contains("403"), "错误必须带状态码：{e}");
                assert!(
                    e.contains("Just a moment") || e.contains("挑战"),
                    "错误必须带 body 特征（挑战页）：{e}"
                );
                return;
            }
        };
        println!(
            "LIVE seed_hub home: 分类 {} 个（{:?}）· 条目 {} 条",
            home.categories.len(),
            home.categories
                .iter()
                .map(|c| format!("{}={}", c.id, c.name))
                .collect::<Vec<_>>(),
            home.items.len()
        );
        assert!(home.categories.len() >= 3, "侧栏应至少 3 个分类");
        assert!(home.items.len() >= 10, "首页应至少 10 条");

        let list = s.list("1", 1, LIVE_EXT).await.expect("分类 1 第 1 页");
        println!(
            "LIVE seed_hub list(1,p1): {} 条 · page_count={:?} · 首条={}",
            list.items.len(),
            list.page_count,
            list.items[0].title
        );
        assert!(list.items.len() >= 10);
        assert!(list.page_count.unwrap_or(0) > 1, "分类 1 应有分页");

        let sr = s.search("三体", 1, LIVE_EXT).await.expect("搜索 三体");
        println!(
            "LIVE seed_hub search(三体): {} 条 · 首条={}",
            sr.items.len(),
            sr.items[0].title
        );
        assert!(!sr.items.is_empty(), "三体 应有结果");

        let d = s
            .detail(&list.items[0].id, LIVE_EXT)
            .await
            .expect("详情");
        println!(
            "LIVE seed_hub detail({}): 「{}」· 剧集 {} 条 · 首条 flag={} id={}",
            list.items[0].id,
            d.title,
            d.episodes.len(),
            d.episodes[0].flag,
            d.episodes[0].id
        );
        assert!(!d.episodes.is_empty());

        let p = s
            .play(&d.episodes[0].flag, &d.episodes[0].id, LIVE_EXT)
            .await
            .expect("play 应能跟到分享页");
        println!("LIVE seed_hub play: {} · label={:?}", p[0].url, p[0].label);
        assert!(is_pan_share(&p[0].url), "play 落点必须是网盘分享页");
    }

    // ══════════════════════════════════════════════════════════════════
    //  ★ 2026-10-29 真页面片段（`curl --noproxy '*'` 直连抓的，逐字截取）
    //    判据来源：`.probe/hf-sh-s_%E8%80%81%E8%88%85.html`（搜索「老舅」→ 200/21179 B）
    // ══════════════════════════════════════════════════════════════════
    const SEARCH_LAODJU_FRAGMENT: &str = r#"
  <div class="cover-container">
    <div class="cover">
      <a target="_blank" rel="noopener noreferrer" title="老舅" class="image" href="/movies/126348/"><img src="https://sh1.pcie.pppoe.top/static/pics/p1766077407771394767.jpg" alt="老舅" ></a>
      <ul>
        <li><h2><a target="_blank" rel="noopener noreferrer" href="/movies/126348/" aria-hidden="true" class="header-anchor">#</a> 老舅</h2></li>

        <li>2025 / 剧集 / 中国大陆 / 汉语普通话 / 郭京飞 王佳佳 </li>
        <li>类型: <a target="_blank" title="喜剧" href="/categories/3/types/39/movies/">喜剧</a> / <a target="_blank" title="剧情" href="/categories/3/types/33/movies/">剧情</a></li>
        <li>豆瓣评分: <a target="_blank" rel="noopener noreferrer nofollow" href="https://movie.douban.com/subject/36638134/">7.6</a></li>
      </ul>
    </div>
  </div>
"#;

    /// 真片段 ⇒ 1 条，id 就是 `/movies/126348/`，标题「老舅」
    #[test]
    fn live_2026_10_29_search_fragment_yields_the_one_real_item() {
        assert!(has_result_container(SEARCH_LAODJU_FRAGMENT), "真搜索页必须有 cover-container");
        let items = parse_items(SEARCH_LAODJU_FRAGMENT);
        assert_eq!(items.len(), 1, "「老舅」真搜索页只有 1 条：{items:?}");
        assert_eq!(items[0].id, "126348");
        assert_eq!(items[0].title, "老舅");
        assert!(items[0]
            .cover
            .as_deref()
            .unwrap_or("")
            .starts_with("https://sh1.pcie.pppoe.top/"));
    }

    /// ★ 故障注入（红）：把条目外壳 `<div class="cover">` 改名 ⇒ 同一份真页面必须掉到 0 条
    ///
    /// ```text
    /// 这条证明 `parse_items` 的切分判据是**承重**的（不是"恰好有链接就能出"）：
    /// 真实文件上 items=1，改坏外壳后 items=0；而 `cover-container` 仍在 ⇒
    /// 还能区分"整页改版（容器也没了）"和"条目外壳改版（容器在、条目为 0）"。
    /// ```
    #[test]
    fn injection_broken_item_shell_must_yield_zero() {
        let broken = SEARCH_LAODJU_FRAGMENT.replace(r#"<div class="cover">"#, r#"<div class="coverXX">"#);
        assert_eq!(
            parse_items(&broken).len(),
            0,
            "★ 注入后仍解析出条目 ⇒ 门禁是假绿（判据没有承重）"
        );
        assert!(
            has_result_container(&broken),
            "只改条目外壳时容器应仍在（这正是两种失败的分界）"
        );
    }

    /// ★ 故障注入（红）②：把详情页 `class="pan-links"` 改名 ⇒ 夸克/百度那组网盘条目必须消失
    #[test]
    fn injection_broken_pan_links_loses_the_pan_episodes() {
        let html = format!("{HOME_FRAGMENT}{DETAIL_FRAGMENT}");
        let base = parse_detail(&html, "1", "https://sidhub.cc").expect("真片段应解析得出来");
        let broken = html.replace(r#"class="pan-links""#, r#"class="pan-linksXX""#);
        let after = parse_detail(&broken, "1", "https://sidhub.cc")
            .map(|d| d.episodes.len())
            .unwrap_or(0);
        assert!(
            after < base.episodes.len(),
            "★ 改坏 pan-links 后集数应减少：改前 {} → 改后 {after}",
            base.episodes.len()
        );
    }
}
