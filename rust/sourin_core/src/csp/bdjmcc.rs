// ═══════════════════════════════════════════════════════════════════════
//  csp_Bdjmcc —— 「图片卡片式影视站」的 Rust 实现（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ 为什么**没有** `register_site!`（三条判据逐条对照）
// ```text
// ① 订阅（100 站）里 `csp_Bdjmcc` = **1 站**（🛸北斗丨蓝光秒播，searchable=0/quickSearch=0）✅
// ② host：**拿不到**
//    · 订阅里 ext = **null**
//    · DEX（`.probe/csp26-downloads/lmw_classes.dex`，class_def #169）里
//      逐方法 dump 了全部 const-string（`<clinit>` / `<init>` / abs / buildFilters /
//      empty / head / parseVCards / untag / categoryContent / detailContent /
//      homeContent / playerContent / searchContent / searchContent）
//      ⇒ **没有任何站点地址/域名常量**：`SITE` 字段存在，但全类没有一条字符串赋给它
//        （`__<clinit>__` 只有 8 条正则；`<init>` 一条常量都没有）
//    ⇒ 字段 `SITE` 只能来自 `ext`（父类 `Pan.init`）——而订阅里 ext = null
// ③ 真网取数：无 host ⇒ **无可打的地址** ⇒ 无法取证
// ⇒ **做实现、不注册**（注册 = 交付"看起来支持但无法验证"的类）
// ```
// ★ 我**没有**把"猜的域名"写进代码：候选域名（bdjm.cc / bdjmcc.com / bdjm.tv …）
//   全部 DNS 不解析（2026-10-28 实测），把其中一个写死只会制造"能注册"的假象。
//
// # ★★ 2026-10-29 host 追猎（**四路全空**，如实登记；脚本与输出在 `.probe/`）
// ```text
// ① 订阅原文（`https://8815.kstore.vip/tvbox/wmz`，base64 解出，`.probe/bdjmcc-sub.dec.json`）：
//    {"key":"北斗","name":"🛸北斗丨蓝光秒播","api":"csp_Bdjmcc","type":3,
//     "searchable":0,"quickSearch":0,"filterable":1}      ← **没有 ext 字段**
// ② spider jar（订阅里的 `261028.jar`，2.4MB，`.probe/bdjmcc-spider.jar`）：
//    Bdjmcc 的 16 个字段里 `SITE` 的**字段值 = null**（`.probe/bdjmcc-dexscan.out.txt`、
//    `.probe/decompiled/r3dex-spider.json` 的 `"values": ["null", …]`）；
//    `<clinit>` 只有 8 条正则、`<init>` 一条常量都没有 ⇒ 无站点常量
// ③ 模板指纹扫全网候选（Bdjmcc 四个一级分类 code 或 `a.picture[href=/v/…]` 任一命中）：
//    · jar 里 594 条 URL → **247 台主机**全打 `/` ⇒ **0 命中**（`.probe/bdjmcc-hunt.out.txt`）
//    · 订阅里 69 台 ext 主机同样扫 ⇒ **0 命中**（`.probe/bdjmcc-hunt2.out.txt`）
// ④ 域名侧：`bdjm.cc/bdjm.tv/bdjm.top/bdjm.vip/bdjm.app/bdjm.club/bdjm.fun` **NXDOMAIN**；
//    `bdjmcc.com` / `bdjm.net` TLS 握手失败（停放）；`bdjm.xyz` = **停放跳转页**
//    （`<script>window.location.href="/lander"</script>`，114 字节，`.probe/bdjmcc-bdjm-xyz.txt`）
// ⑤ 参考 APK（139MB）的 3 个 dex + **全部 zip 条目**里没有 `csp_Bdjmcc` / `北斗` / `bdjm`
//    ⇒ 客户端不内置站点表（`.probe/bdjmcc-apk-scan.py`）
// ⇒ 结论：**该类的 host 在任何可得产物里都不存在**（原配置作者漏了 ext）⇒ 仍**不注册**。
//    一旦拿到 host（例如 lead 从别处补 `{"url":"https://…"}`），本实现即可用；
//    真网联调用例 `bdjmcc_live_segments_if_host_given` 用环境变量 `BDJMCC_HOST` 直接验。
// ```
//
// # 协议（DEX 常量逐字还原，按行为重写）
// ```text
// 形态：**图片卡片站**（不是 AppleCMS：路径 /v/<slug>.html、/p/<code>/<n>/<m>.html）
//
// home    GET {host}/
//         → <a class="…picture…" href="/v/<slug>.html" title="<片名>">…</a>
//         分类（buildFilters 逐字，四类）：
//           连续剧 A051pCM47kBg2 / 电影 A1sQHJp3ggh3P
//           动漫   A2yIcGx03608i / 综艺 A1U43X24bwf2t
//         （每个分类还有二级 type 码：A0hLbxS3mdi9Z 国产剧 …，见 .probe/csp25/Bdjmcc.txt）
// list    GET {host}/list/<code>/<page>.html
//         → 卡片 parseVCards：vod_id / vod_name / vod_remarks / vod_pic
//         （封面 data-original="…"，备注 <span class="…">2~20 字</span>）
// detail  GET {host}/v/<slug>.html
//         → <h1 class="title">…</h1>
//           `thumbnailUrl":["…"]`
//           playlist-group-btn > <线路名>
//           href="(/p/<code>/<n>/<m>.html)" > <集名>
// play    ★ GET {host}/p/<code>/<n>/<m>.html → <iframe src="…">
//           再从 iframe src 里取 `v=<id>` 或 `?url=<url>`，交给**站点下发的解析接口**
//         ⚠️ 解析接口地址**不在 DEX 常量里**（`searchvodname` 只是参数名）
//            ⇒ 本实现**拒绝伪造**：没有解析配置就如实报错（见 `play`）。
// search  DEX 的 searchContent 只出现参数名 `searchvodname`（无路径常量）
//         ⇒ 路径**未取证**；`supports_search()` 声明 false，`search()` 手写可读 Err。
// ```
//
// # 代理纪律
// ```text
// client 在 `.timeout(TIMEOUT)` 之后、`.build()` 之前显式 `.no_proxy()`
// （本机代理的 502 会把"站点可用"测成"站点死"；诚实契约第 3 条）。
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `UA` 字段逐字（Android Chrome/120）
const UA: &str = "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(15);
const MAX_ITEMS: usize = 120;

/// DEX `buildFilters` 的一级分类（type 码逐字）
const CATEGORIES: &[(&str, &str)] = &[
    ("A051pCM47kBg2", "连续剧"),
    ("A1sQHJp3ggh3P", "电影"),
    ("A2yIcGx03608i", "动漫"),
    ("A1U43X24bwf2t", "综艺"),
];

pub struct Bdjmcc {
    client: reqwest::Client,
}

impl Bdjmcc {
    pub const CLASS: &'static str = "Bdjmcc";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // ★ 直连（顺序有门禁扫：timeout → no_proxy → build）
            .no_proxy()
            .build()
            .expect("build bdjmcc http client");
        Self { client }
    }

    /// 从 ext 取 host（`site` 数组 / `host` / `url` / 任意含 http 的字符串 / 裸字符串）
    ///
    /// ★ 本类是「**做实现、不注册**」：订阅里 ext 为 null，DEX 里也没有站点常量。
    ///   一旦某份配置给了 `{"site":["https://…"]}`，本实现就能直接用。
    ///
    /// # 2026-10-29 扩展：真实订阅里 ext 的三种写法都要认
    /// ```text
    /// {"site":["https://x"]}    ← TVBox csp 常见
    /// {"host":"https://x"}
    /// {"url":"http://x"}        ← 本仓参考订阅里 AppRJ 就是这个形状
    /// "https://x"               ← 裸字符串
    /// ```
    /// 实现：**递归收集 JSON 里的所有字符串**，返回第一条 `http(s)://…`；
    /// JSON 解不出就退回"按分隔符切、找 http 片段"（容错手写配置）。
    ///
    /// ⚠️ 两条路径**互斥**（JSON 解析成功就只走递归）—— 这条纪律是门禁逼出来的：
    ///    若 JSON 分支之后**再**做字符串切分兜底，那"删掉对象分支"这种注入不会让门禁变红
    ///    （切分也能从 `{"url":"http://x"}` 里切出 URL）⇒ 判据就成了假绿。
    pub fn host_of(ext: &str) -> Option<String> {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(ext) {
            let mut found: Option<String> = None;
            collect_host(&v, &mut found);
            return found;
        }
        for piece in ext.split(|c: char| c == '"' || c == '\'' || c == ',' || c == ' ') {
            if let Some(h) = norm(piece) {
                return Some(h);
            }
        }
        None
    }

    fn need_host(ext: &str) -> Result<String, String> {
        Self::host_of(ext).ok_or_else(|| {
            "Bdjmcc 需要 ext 里的站点地址（键 `site` 或 `host`）——订阅里本类 ext=null，\
             且 DEX 里全类「没有」站点常量（`SITE` 字段从未被赋字符串）⇒ 当前真网络无可打的地址。\
             该类为「做实现、不注册」状态（见文件头三条判据）"
                .to_string()
        })
    }

    async fn get_html(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml,application/json")
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {}（{url}）：{}", status.as_u16(), head(&text)));
        }
        Ok(text)
    }
}

impl Default for Bdjmcc {
    fn default() -> Self {
        Self::new()
    }
}

fn norm(raw: &str) -> Option<String> {
    let u = raw.trim().trim_end_matches('/');
    if u.starts_with("http") && u.len() > 7 {
        Some(u.to_string())
    } else {
        None
    }
}

/// 递归收集 JSON 里的 URL 字符串（优先 `site` / `host` / `url` 三个键）
///
/// 判据：`host_of_accepts_common_ext_shapes`（四种真实 ext 形状逐条）。
fn collect_host(v: &serde_json::Value, out: &mut Option<String>) {
    if out.is_some() {
        return;
    }
    match v {
        serde_json::Value::String(s) => {
            if let Some(h) = norm(s) {
                *out = Some(h);
            }
        }
        serde_json::Value::Array(a) => {
            for x in a {
                collect_host(x, out);
            }
        }
        serde_json::Value::Object(o) => {
            for k in ["site", "host", "url"] {
                if let Some(x) = o.get(k) {
                    collect_host(x, out);
                }
            }
            for (_, x) in o {
                collect_host(x, out);
            }
        }
        _ => {}
    }
}

/// 分类页路径（DEX：`/list/` + code + `/` + page + `.html`）
pub fn list_path(code: &str, page: u32) -> String {
    format!("/list/{}/{}.html", code.trim(), page.max(1))
}

/// 详情页路径（DEX：`/v/<slug>.html`；列表给的是完整 `/v/…` 就原样用）
pub fn detail_path(id: &str) -> String {
    let id = id.trim();
    if id.starts_with('/') {
        id.to_string()
    } else {
        format!("/v/{id}.html")
    }
}

/// 播放页路径（DEX：`/p/<code>/<n>/<m>.html`；详情给的是完整 `/p/…` 就原样用）
pub fn play_path(id: &str) -> String {
    let id = id.trim();
    if id.starts_with('/') {
        id.to_string()
    } else {
        format!("/p/{id}")
    }
}

fn head(s: &str) -> String {
    s.chars().take(140).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  HTML 解析（纯函数）
// ═══════════════════════════════════════════════════════════════════════

/// 列表/首页条目：DEX 的 `P_VCARD` / `P_WRAP` / `P_IMG` / `P_REMARK`
///
/// ```text
/// <a class="…picture…" href="/v/<slug>.html" title="<片名>">
///   … <img data-original="<封面>"> … <span class="…">2~20 字备注</span> …
/// </a>
/// ```
pub fn parse_cards(html: &str) -> Vec<CspItem> {
    let re_a = regex::Regex::new(
        r#"(?is)<a[^>]+class="[^"]*picture[^"]*"[^>]*href="(/v/[^"]+\.html)"[^>]*title="([^"]*)""#,
    )
    .expect("bd picture");
    let re_pic = regex::Regex::new(r#"(?is)data-original="([^"]+)""#).expect("bd pic");
    let re_remark = regex::Regex::new(r#"(?is)<span class="[^"]*"[^>]*>([^<]{2,20})</span>"#)
        .expect("bd remark");
    let anchors: Vec<(usize, usize, String, String)> = re_a
        .captures_iter(html)
        .filter_map(|c| {
            let m = c.get(0)?;
            Some((
                m.start(),
                m.end(),
                c.get(1)?.as_str().to_string(),
                clean_text(c.get(2)?.as_str()),
            ))
        })
        .collect();

    let mut out: Vec<CspItem> = Vec::new();
    for (i, (_, end, href, title)) in anchors.iter().enumerate() {
        if out.len() >= MAX_ITEMS {
            break;
        }
        let next = anchors.get(i + 1).map(|a| a.0).unwrap_or(html.len());
        let seg = &html[*end..next.max(*end).min(html.len())];
        if title.is_empty() || out.iter().any(|x| x.id == *href) {
            continue;
        }
        out.push(CspItem {
            id: href.clone(),
            title: title.clone(),
            cover: re_pic.captures(seg).map(|c| c[1].to_string()),
            subtitle: re_remark
                .captures(seg)
                .map(|c| clean_text(&c[1]))
                .filter(|s| !s.is_empty()),
        });
    }
    out
}

/// 列表页（`/list/<code>/<page>.html`）
pub fn list_from_html(html: &str, page: u32, what: &str) -> Result<CspList, String> {
    let items = parse_cards(html);
    if items.is_empty() {
        return Err(format!(
            "Bdjmcc {what} 页面能打开，但没解析出任何条目（模板可能已改版，或返回的是风控壳页）"
        ));
    }
    Ok(CspList {
        items,
        page,
        page_count: None,
        total: None,
    })
}

/// 首页：分类（DEX buildFilters 的一级表）+ 首屏卡片
pub fn home_from_html(html: &str) -> Result<CspHome, String> {
    let categories: Vec<CspCategory> = CATEGORIES
        .iter()
        .map(|(id, name)| CspCategory {
            id: (*id).to_string(),
            name: (*name).to_string(),
        })
        .collect();
    let items = parse_cards(html);
    if items.is_empty() {
        return Err(
            "Bdjmcc 首页能打开，但没解析出任何卡片（选择器 `a.picture[href=/v/…]` 可能已改版，\
             或返回的是风控壳页）"
                .to_string(),
        );
    }
    Ok(CspHome { categories, items })
}

/// 详情页：标题 / 封面 / 线路（playlist-group-btn）/ 集（`/p/<code>/<n>/<m>.html`）
pub fn detail_from_html(html: &str, id: &str) -> CspDetail {
    let re_title = regex::Regex::new(r#"(?is)<h1 class="title">([^<]*)</h1>"#).expect("bd title");
    let re_thumb =
        regex::Regex::new(r#"(?is)thumbnailUrl":\["([^"]+)""#).expect("bd thumb");
    let re_ep = regex::Regex::new(r#"(?is)href="(/p/[^"]+\.html)"[^>]*>([^<]+)<"#).expect("bd ep");
    let re_line = regex::Regex::new(r#"(?is)playlist-group-btn[^>]*>([^<]+)<"#).expect("bd line");

    let title = re_title
        .captures(html)
        .map(|c| clean_text(&c[1]))
        .unwrap_or_default();
    let mut episodes: Vec<CspEpisode> = Vec::new();
    let line = re_line
        .captures(html)
        .map(|c| clean_text(&c[1]))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "默认".to_string());
    for c in re_ep.captures_iter(html) {
        let href = c[1].trim().to_string();
        let name = clean_text(&c[2]);
        if episodes.iter().any(|e| e.id == href) {
            continue;
        }
        episodes.push(CspEpisode {
            id: href,
            title: if name.is_empty() {
                format!("第{}集", episodes.len() + 1)
            } else {
                name
            },
            flag: line.clone(),
        });
        if episodes.len() >= 500 {
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
        cover: re_thumb.captures(html).map(|c| c[1].to_string()),
        description: None,
        episodes,
    }
}

/// 播放页 → iframe 的 `src`
pub fn iframe_src(html: &str) -> Option<String> {
    let re = regex::Regex::new(r#"(?is)<iframe[^>]*src="([^"]+)""#).expect("bd iframe");
    re.captures(html).map(|c| c[1].trim().to_string())
}

/// iframe src → 站点解析参数（DEX：`v=([A-Za-z0-9]+)` 与 `\?url=([^"'\s]+)`）
pub fn parse_token(src: &str) -> Option<String> {
    let re_v = regex::Regex::new(r#"v=([A-Za-z0-9]+)"#).expect("bd v");
    if let Some(c) = re_v.captures(src) {
        return Some(c[1].to_string());
    }
    let re_url = regex::Regex::new(r#"\?url=([^"'\s]+)"#).expect("bd url");
    re_url.captures(src).map(|c| c[1].to_string())
}

fn clean_text(s: &str) -> String {
    let no_tags = crate::tvbox::strip_tags(s);
    crate::tvbox::decode_entities(&no_tags)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

// ══ ⚠️ **没有 `register_site!`**（原因见文件头）══

#[async_trait]
impl CspSite for Bdjmcc {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = Self::need_host(ext)?;
        let html = self.get_html(&format!("{host}/")).await?;
        home_from_html(&html)
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空（首页没给出分类）".to_string());
        }
        let host = Self::need_host(ext)?;
        let page = if page == 0 { 1 } else { page };
        let html = self
            .get_html(&format!("{host}{}", list_path(tid, page)))
            .await?;
        let items = parse_cards(&html);
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
                "Bdjmcc 分类 {tid} 的页面能打开，但没解析出任何卡片（模板可能已改版，或风控壳页）"
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
        let host = Self::need_host(ext)?;
        // id 可能是列表给的完整路径（`/v/<slug>.html`），也可能只是 slug
        let path = detail_path(id);
        let html = self.get_html(&format!("{host}{path}")).await?;
        let d = detail_from_html(&html, id);
        if d.episodes.is_empty() {
            return Err(format!(
                "Bdjmcc 条目 {id} 的详情页能打开，但没找到任何 `/p/…html` 播放页链接（模板可能已改版）"
            ));
        }
        Ok(d)
    }

    /// ★ 未取证：DEX 只给了参数名 `searchvodname`，**没有路径常量**
    fn supports_search(&self) -> bool {
        false
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        // 不写一个"看起来能搜"的猜测路径：路径没取证，猜错会把 404 说成"没结果"
        Err("Bdjmcc 不支持搜索：DEX 的 searchContent 只有参数名 `searchvodname`、\
             没有路径常量，且本类当前无 host 可验证 ⇒ 不声明假能力（`supports_search` = false）"
            .to_string())
    }

    /// 取流：播放页 → iframe → 解析参数；**解析接口地址未取证** ⇒ 如实拒绝
    async fn play(&self, _flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let host = Self::need_host(ext)?;
        let path = play_path(id);
        let html = self.get_html(&format!("{host}{path}")).await?;
        let src = iframe_src(&html).ok_or_else(|| {
            format!("Bdjmcc 播放页 {path} 里没有 iframe src（页面结构可能改版，或该播放页已失效）")
        })?;
        let token = parse_token(&src).unwrap_or_else(|| src.clone());
        // 直链媒体：原样给（真地址，不编造）
        let lower = src.to_ascii_lowercase();
        if lower.contains(".m3u8") || lower.contains(".mp4") {
            return Ok(vec![CspPlay {
                url: src,
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some("直链".to_string()),
            }]);
        }
        Err(format!(
            "Bdjmcc 取流依赖站点下发的「解析接口」（iframe 里只有解析参数 `{token}`，\
             接口地址不在 DEX 常量里、本类也无 host 可验证）⇒ 不做假通；\
             已实现的链路：home → list → detail（未取证 search / play）"
        ))
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════
//
// ⚠️ 本类是**无 host 类**：真网没有可打的地址 ⇒ 这里**没有**真响应片段可喂。
//    下面的样本按 DEX 常量（选择器逐个逐字）**手工构造**，只证明"解析算法与 DEX 选择器
//    对得上"，不冒充"真站响应"——这一点必须在报告里如实说明。

#[cfg(test)]
mod tests {
    use super::*;

    /// 按 DEX `P_VCARD` / `P_IMG` / `P_REMARK` 构造的卡片块（**非真响应**）
    const CARDS: &str = r#"<div class="row"><a class="picture" href="/v/ab12cd.html" title="示例剧集"><img class="lazy" data-original="https://img.example/a.jpg"><span class="remark">更新至08集</span></a><a class="picture" href="/v/zz99yy.html" title="示例电影"><img data-original="https://img.example/b.jpg"><span class="remark">HD</span></a></div>"#;

    /// 按 DEX 选择器构造的详情块（**非真响应**）
    const DETAIL: &str = r#"<h1 class="title">示例剧集</h1><script>{"thumbnailUrl":["https://img.example/a.jpg"]}</script><div class="playlist-group-btn" data-id="1">线路一</div><a href="/p/ab12cd/1/1.html">第01集</a><a href="/p/ab12cd/1/2.html">第02集</a>"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Bdjmcc::CLASS, "Bdjmcc");
    }

    #[test]
    fn host_only_from_ext_and_absent_everywhere_else() {
        assert_eq!(Bdjmcc::host_of(r#"{"site":["https://h.example/"]}"#).as_deref(), Some("https://h.example"));
        assert_eq!(Bdjmcc::host_of(r#"{"host":"https://h2.example"}"#).as_deref(), Some("https://h2.example"));
        assert_eq!(Bdjmcc::host_of("https://h3.example").as_deref(), Some("https://h3.example"));
        // 订阅里就是 null ⇒ None（这正是判据 ② 不成立的原因）
        assert_eq!(Bdjmcc::host_of("null"), None);
        assert_eq!(Bdjmcc::host_of(""), None);
        // ★ 源码里不许出现任何"猜的域名"
        let flat = crate::csp::shared::impl_src_only(include_str!("bdjmcc.rs"));
        assert!(!flat.contains("bdjm.cc"), "★ 不许写死猜测的域名");
        assert!(!flat.contains("https://www."), "★ 无 host 类不许写死站点");
    }

    #[test]
    fn cards_parse_title_cover_remark_and_id() {
        let items = parse_cards(CARDS);
        assert_eq!(items.len(), 2, "{items:?}");
        assert_eq!(items[0].id, "/v/ab12cd.html");
        assert_eq!(items[0].title, "示例剧集");
        assert_eq!(items[0].cover.as_deref(), Some("https://img.example/a.jpg"));
        assert_eq!(items[0].subtitle.as_deref(), Some("更新至08集"));
        assert_eq!(items[1].title, "示例电影");
        assert!(parse_cards("<html></html>").is_empty());
    }

    #[test]
    fn home_and_list_reject_zero_parsed() {
        let e = home_from_html("<html>维护中</html>").expect_err("0 卡片必须 Err");
        assert!(e.contains("没解析出任何卡片"), "{e}");
        let e2 = list_from_html("<html>403</html>", 1, "分类 1").expect_err("0 条必须 Err");
        assert!(e2.contains("风控壳页"), "{e2}");
        let ok = list_from_html(CARDS, 1, "分类 1").expect("有卡片");
        assert_eq!(ok.items.len(), 2);
        // home 即使没有 CSS 导航也能给出 DEX 的四个一级分类
        let h = home_from_html(CARDS).expect("有卡片");
        assert_eq!(h.categories.len(), 4);
        assert_eq!(h.categories[0].id, "A051pCM47kBg2");
        assert_eq!(h.categories[1].name, "电影");
    }

    #[test]
    fn detail_parses_title_cover_line_and_episodes() {
        let d = detail_from_html(DETAIL, "/v/ab12cd.html");
        assert_eq!(d.title, "示例剧集");
        assert_eq!(d.cover.as_deref(), Some("https://img.example/a.jpg"));
        assert_eq!(d.episodes.len(), 2, "{:?}", d.episodes);
        assert_eq!(d.episodes[0].id, "/p/ab12cd/1/1.html");
        assert_eq!(d.episodes[0].title, "第01集");
        assert_eq!(d.episodes[0].flag, "线路一");
    }

    #[test]
    fn iframe_token_extraction_matches_the_dex_patterns() {
        assert_eq!(
            parse_token("https://player.example/x?v=AbC123&auto=1").as_deref(),
            Some("AbC123"),
            "v= 优先级最高（DEX 里是 Pattern `v=([A-Za-z0-9]+)`）"
        );
        assert_eq!(
            parse_token("https://player.example/?url=https%3A%2F%2Fa.example%2Fx.m3u8").as_deref(),
            Some("https%3A%2F%2Fa.example%2Fx.m3u8")
        );
        assert_eq!(
            iframe_src(r#"<iframe src="https://p.example/x"></iframe>"#).as_deref(),
            Some("https://p.example/x")
        );
        assert!(iframe_src("<div></div>").is_none());
    }

    /// ★ 三条判据缺 ②③ ⇒ 必须**不注册**
    #[test]
    fn bdjmcc_must_not_be_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("bdjmcc.rs"));
        assert!(!flat.contains("register_site!(Bdjmcc)"), "★ 本批 Bdjmcc 不注册");
        assert!(
            !crate::csp::is_implemented("csp_Bdjmcc"),
            "★ 不许进注册表（无 host ⇒ 无法验证）"
        );
        assert_eq!(Bdjmcc::new().supports_search(), false, "★ 未取证 ⇒ 不声明搜索能力");
    }

    #[tokio::test]
    async fn every_segment_reports_the_missing_host() {
        let s = Bdjmcc::new();
        for e in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.detail("/v/x.html", "").await.err(),
            s.play("", "/p/x/1/1.html", "").await.err(),
        ] {
            let msg = e.expect("无 host 必须 Err");
            assert!(msg.contains("ext"), "{msg}");
            assert!(msg.contains("不注册"), "{msg}");
        }
    }

    #[test]
    fn http_client_disables_proxy_after_timeout() {
        let flat = crate::csp::shared::impl_src_only(include_str!("bdjmcc.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("timeout");
        let p = flat.find(".no_proxy()").expect("★ no_proxy 必须存在");
        let b = flat.find(".build()").expect("build");
        assert!(t < p && p < b, "timeout → no_proxy → build");
    }

    #[test]
    /// ★★ ext 的四种真实形状都要认（2026-10-29 扩了递归收集）
    ///
    /// 判据来源：参考订阅里 `csp_AppRJ` 的 ext 就是 `{"url":"http://v.rbotv.cn"}`；
    /// TVBox 的 csp 约定是 `{"site":["…"]}`。只认 `site`/`host` 会在别的源上直接失效。
    /// 注入：把 `collect_host` 的对象分支删掉（只留 Array/String）⇒ 本条红。
    fn host_of_accepts_common_ext_shapes() {
        let cases = [
            (r#"{"site":["https://a.example/"]}"#, Some("https://a.example")),
            (r#"{"host":"https://b.example"}"#, Some("https://b.example")),
            (r#"{"url":"http://c.example"}"#, Some("http://c.example")),
            (r#"{"url":"http://c.example","other":1}"#, Some("http://c.example")),
            (r#"["https://d.example"]"#, Some("https://d.example")),
            ("https://e.example", Some("https://e.example")),
            ("null", None),
            ("", None),
            ("{}", None),
            (r#"{"site":[]}"#, None),
        ];
        for (raw, want) in cases {
            assert_eq!(
                Bdjmcc::host_of(raw).as_deref(),
                want,
                "★ ext={raw} 应解出 {want:?}"
            );
        }
        // 尾巴斜杠要去掉（后面统一拼 `{host}/…`）
        assert_eq!(
            Bdjmcc::host_of(r#"{"site":["https://f.example///"]}"#).as_deref(),
            Some("https://f.example")
        );
    }

    #[test]
    /// ★★ 三个路径形态逐字对 DEX（`/list/<code>/<page>.html`、`/v/<slug>.html`、`/p/<code>/<n>/<m>.html`）
    ///
    /// DEX 常量：`'/list/'` + `'/'` + `'.html'`；详情 `'/v/'`；播放 `'/p/'`。
    /// 注入：把 `list_path` 的 `.html` 去掉 ⇒ 本条红。
    fn paths_match_dex_shapes() {
        assert_eq!(list_path("A051pCM47kBg2", 1), "/list/A051pCM47kBg2/1.html");
        assert_eq!(list_path(" A051pCM47kBg2 ", 0), "/list/A051pCM47kBg2/1.html");
        assert_eq!(detail_path("/v/ab12cd.html"), "/v/ab12cd.html");
        assert_eq!(detail_path("ab12cd"), "/v/ab12cd.html");
        assert_eq!(play_path("/p/ab12cd/1/2.html"), "/p/ab12cd/1/2.html");
        assert_eq!(play_path("ab12cd/1/2.html"), "/p/ab12cd/1/2.html");
    }

    /// ★★ 真网络联调（`BDJMCC_HOST` 给了才跑）：一旦有 host，一条命令就能验证全链路
    ///
    /// 判据（不做假成功）：
    /// ```text
    /// ① 没给 BDJMCC_HOST ⇒ 打印"该类当前无 host"并 return（不给假绿）
    /// ② 给了 host ⇒ home 必须能解析出卡片或**明确报错**；list 同；detail 同
    ///    （报错必须带状态码/原因，不许含糊）
    /// ```
    #[tokio::test]
    #[ignore = "真网络：BDJMCC_HOST=https://… cargo test --lib bdjmcc_live -- --ignored --nocapture"]
    async fn bdjmcc_live_segments_if_host_given() {
        let host = match std::env::var("BDJMCC_HOST") {
            Ok(h) if !h.trim().is_empty() => h,
            _ => {
                eprintln!(
                    "[LIVE] BDJMCC_HOST 未设置 ⇒ 该类 2026-10-29 仍无 host（四路追猎全空，见文件头）"
                );
                return;
            }
        };
        let ext = format!("{{\"url\":\"{}\"}}", host.trim());
        eprintln!("[LIVE] ext = {ext}");
        let s = Bdjmcc::new();
        match s.home(&ext).await {
            Ok(h) => eprintln!("[LIVE] home: 分类 {} 个，卡片 {} 条", h.categories.len(), h.items.len()),
            Err(e) => eprintln!("[LIVE] home 如实失败：{e}"),
        }
        let code = CATEGORIES[0].0;
        match s.list(code, 1, &ext).await {
            Ok(l) => eprintln!("[LIVE] list({code}): {} 条", l.items.len()),
            Err(e) => eprintln!("[LIVE] list 如实失败：{e}"),
        }
    }
}
