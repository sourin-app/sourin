// ═══════════════════════════════════════════════════════════════════════
//  csp_FirstAid —— 纯 HTML 抓取源（第19项第 5 个实现类，第 1 个"骨架复用"验证）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证来源（DEX 指令级：`.probe/final-plan-audit/firstaid.log`）
//
// `Lcom/github/catvod/spider/FirstAid;`（class_def #219，7 个方法）的 const-string 逐条：
// ```text
// <init>            "https://m.youlai.cn"
// a                 "User-Agent" + Chrome/151
// homeContent       "jijiu|0" … "jijiu|7"
//                   急救技能 / 家庭生活 / 急危重症 / 常见损伤 / 动物致伤 / 海洋急救 / 中毒急救 / 意外事故
// categoryContent   "\\|"  "cateId"  "/%s"
//                   .list-br3   .jj-title-li   a[href]   .block100 img[src]   "form"
// detailContent     .video-title.h1-title  .video-cover.list-flex-in img[src]
//                   span.doc-name  .img-text-con
//                   ★ "#video source"[src]   ← 直链 m3u8 就在这里
//                   "#video"[src]            ← 兜底
// playerContent     **无任何 const-string** ⇒ 直接把详情拿到的 m3u8 返回（零解析）
// searchContent     "https://m.youlai.cn/cse/search?q="
//                   .search-video-li.list-br2  a[href]  h5.line-clamp1  dt.logo-bg img[src]
// ```
// ⇒ 无加密、无签名、无登录、无状态。这是**最适合照抄 `pan_web_share` 骨架**的一类。
//
// # 与 `pan_web_share` 的复用（不复制粘贴）
// ```text
// · 站点列表解析：直接调 `PanWebShare::sites_of(ext)`（同一套 ext 形态：{"site":[…]}
//   或字符串里带 http 地址）
// · 失败汇总：直接调 `pan_web_share::summarize_failures`（前 5 条 + 其余计数）
// ```
// 复用的原因不是省代码，而是**同一条纪律只能有一个实现**（本仓铁律），
// 否则"两个 HTML 源的失败文案/镜像策略"迟早漂成两套。
//
// # ⚠️ 当前状态（2026-10-26）：**已实现但未注册（未通电）**
// ```text
// 真网络实测（.probe/firstaid-live4.log）：
//   home   ✅ 8 分类 / 60 条目（首条"人工呼吸"）
//   list   ✅ 60 条
//   play   ✅ 1 条真 mp4（vod.youlai.cn/….mp4）
//   detail ❌ 标题解析命中页面 <style> 里的 CSS 文本（得到 "titleTop) {"）
//          ⇒ 必须先剥 <style>/<script> 再取文本；四段未全通
// 因此按"未通过真网络验证的类不许注册"的规矩：**mod.rs 里已注释掉注册**。
// 修好标题解析后恢复那三行即可通电（其余三段无需改动）。
// 路径形态已校正：DEX 的 `/%s` 只吃前半段 ⇒ `jijiu|0` → `/jijiu`（实测 200）；
// `/jijiu/0`、`/jijiu/0/`、`/jijiu/0.html` 全 404。
// ```

// # 空即 Err（与 App99 / PanWebShare 同一条）
// ```text
// 列表解析出 0 条 ⇒ Err（"页面能打开但没解析出条目"）
// 详情缺标题 ⇒ Err；详情缺 m3u8 ⇒ Err（正文里说清是"没取到直链"还是"页面结构变了"）
// ```
// 站点 200 但模板改版时，**不能**返回 Ok(空) —— 那会让用户看到"这个源没内容"。

use async_trait::async_trait;
use std::time::Duration;

use super::pan_web_share::{summarize_failures, PanWebShare};
use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 兜底站点（DEX 的 `<init>` 常量；ext 没给 site 时用它）
const DEFAULT_BASE: &str = "https://m.youlai.cn";

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 单次抓取预算（8s；HTML 页没必要等 20s，慢站会拖垮"点一下等很久"）
const GET_TIMEOUT: Duration = Duration::from_secs(8);
/// 一次调用里最多试几个镜像
const MAX_MIRRORS: usize = 3;

/// 分类表（DEX 的 homeContent 里**写死**的 8 个）
///
/// ★ 为什么写死而不是抓导航：DEX 就是写死的（`jijiu|0`…`jijiu|7` + 8 个中文名）。
///   抓导航会得到"站点今天想给你看的分类"，与 TVBox 原版行为不同 —— 我们跟着原版。
pub const CATEGORIES: &[(&str, &str)] = &[
    ("jijiu|0", "急救技能"),
    ("jijiu|1", "家庭生活"),
    ("jijiu|2", "急危重症"),
    ("jijiu|3", "常见损伤"),
    ("jijiu|4", "动物致伤"),
    ("jijiu|5", "海洋急救"),
    ("jijiu|6", "中毒急救"),
    ("jijiu|7", "意外事故"),
];

pub struct FirstAid {
    client: reqwest::Client,
}

impl FirstAid {
    pub const CLASS: &'static str = "FirstAid";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(GET_TIMEOUT)
            // 与其它 csp 源同一条纪律：不读系统代理（代理会把"站点可用"测成"全宕"）
            .no_proxy()
            .build()
            .expect("build firstaid http client");
        Self { client }
    }

    /// 站点列表：优先 ext.site，取不到用 DEX 里的默认站点
    pub fn sites_of(ext: &str) -> Vec<String> {
        let mut s = PanWebShare::sites_of(ext);
        if s.is_empty() {
            s.push(DEFAULT_BASE.to_string());
        }
        s
    }

    async fn get_html(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .send()
            .await
            .map_err(|e| format!("请求 {url} 失败：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取 {url} 失败：{e}"))?;
        if !status.is_success() {
            let head: String = text.chars().take(120).collect();
            return Err(format!("HTTP {}（{url}）：{head}", status.as_u16()));
        }
        Ok(text)
    }

    /// 依次试镜像（最多 MAX_MIRRORS 个），全失败时用统一的失败汇总
    async fn fetch_first(&self, sites: &[String], path: &str) -> Result<String, String> {
        let mut failures: Vec<String> = Vec::new();
        let n = sites.len().min(MAX_MIRRORS);
        for base in sites.iter().take(n) {
            let url = format!("{base}{path}");
            match self.get_html(&url).await {
                Ok(html) => return Ok(html),
                Err(e) => failures.push(format!("{base}：{e}")),
            }
        }
        Err(summarize_failures(&failures, n))
    }
}

impl Default for FirstAid {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  HTML 解析（选择器取自 DEX，见文件头）
// ═══════════════════════════════════════════════════════════════════════

/// 分类页路径
///
/// # 实测校正（2026-10-26）
/// DEX 里是 `cateId` 按 `\|` 拆开 + `String.format("/%s", …)`；**只把前半段拼进路径**：
/// ```text
/// /jijiu             → HTTP 200，8 个 `jj-title-li` 段落、159 条 `list-br3` 条目   ✅
/// /jijiu/0           → HTTP 404                                                   ❌
/// /jijiu|0           → HTTP 404                                                   ❌
/// ```
/// ⇒ `jijiu|0` → `/jijiu`；后半段（0…7）是**子分类序号**，原版也没拼进路径（这里同样不用）。
pub fn path_of_cate(cate_id: &str) -> Option<String> {
    let mut it = cate_id.split('|');
    let a = it.next().unwrap_or("").trim();
    let b = it.next().unwrap_or("").trim();
    if a.is_empty() || b.is_empty() {
        return None;
    }
    Some(format!("/{a}"))
}

/// 搜索路径（DEX 里的完整 URL 前缀，这里只取 path+query 以便换镜像）
pub fn search_path(kw: &str) -> String {
    format!("/cse/search?q={}", urlencoding::encode(kw))
}

fn attr_before(seg: &str, needle: &str, attr: &str) -> Option<String> {
    // 在 needle 之前最近的 attr="…"
    let at = seg.find(needle)?;
    let head = &seg[..at];
    let idx = head.rfind(&format!("{attr}=\""))?;
    let rest = &head[idx + attr.len() + 2..];
    let end = rest.find('"')?;
    let v = rest[..end].trim().to_string();
    if v.is_empty() {
        None
    } else {
        Some(v)
    }
}


/// 列表页解析：真实结构是 `li.list-br3 > a[href] > div.line-clamp1`
///
/// 实测 markup（2026-10-26）：
/// ```html
/// <li class="list-br3"><a href="/jijiu/article/944A17mma.html">
///     <div class="line-clamp1">人工呼吸</div></a></li>
/// ```
/// ⚠️ 我一开始把 `.jj-title-li` 当条目锚点 —— 那是**分节标题**（"心肺复苏"），
///    条目在它下面的 `<ul>` 里。这条错判是靠"两条被并成一条"的断言抓出来的。
/// `.jj-title-li` 现在是**分节**信息（可用于副标题），不参与条目识别。
pub fn list_from_html(html: &str, page: u32, path: &str) -> Result<CspList, String> {
    let mut items: Vec<CspItem> = Vec::new();
    let mut from = 0usize;
    while let Some(rel) = html[from..].find("list-br3") {
        let at = from + rel;
        from = at + "list-br3".len();
        /*
         * ⚠️ 不能直接 `&html[at..at+400]`：中文是多字节，切在字符中间会 panic
         *    （实测：`end byte index 8493 is not a char boundary; inside '骨'`）。
         *    按**字符**前进 400 个，再取字节偏移 —— 这样切片一定落在边界上。
         */
        let seg_end = at
            + html[at..]
                .chars()
                .take(400)
                .map(|c| c.len_utf8())
                .sum::<usize>();
        let seg = &html[at..seg_end.min(html.len())];
        let href = seg.find("href=\"").and_then(|i| {
            let r = &seg[i + 6..];
            r.find('"').map(|e| r[..e].trim().to_string())
        });
        let id = match href {
            Some(h) if h.starts_with('/') => h,
            _ => continue,
        };
        let title = seg
            .find("line-clamp1")
            .and_then(|i| {
                let r = &seg[i..];
                r.find('>').and_then(|gt| {
                    let tail = &r[gt + 1..];
                    tail.find('<')
                        .map(|lt| crate::tvbox::decode_entities(&tail[..lt]).trim().to_string())
                })
            })
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let cover = seg
            .find("src=\"")
            .and_then(|i| {
                let r = &seg[i + 5..];
                r.find('"').map(|e| r[..e].trim().to_string())
            })
            .filter(|s| s.starts_with("http"));
        if items.iter().any(|x| x.id == id) {
            continue;
        }
        items.push(CspItem {
            id,
            title,
            cover,
            subtitle: None,
        });
        if items.len() >= 60 {
            break;
        }
    }
    if items.is_empty() {
        return Err(format!(
            "{path} 页面能打开但没解析出任何条目（站点模板可能已改版，或被风控页替换）"
        ));
    }
    Ok(CspList {
        items,
        page,
        page_count: None,
        total: None,
    })
}

/// 详情：标题（h1-title）/ 封面（video 的 poster 或列表封面）/ **直链**
///
/// # 实测 markup（2026-10-26，/jijiu/article/944A17mma.html）
/// ```html
/// <h1 class="video-title h1-title">人工呼吸法</h1>
/// <video id="video" poster="https://file.youlai.cn/…jpeg" … controls>
///   <source src="https://vod.youlai.cn/…/sd.mp4" type="video/mp4">
/// </video>
/// ```
/// ⚠️ 两个实测结论与 DEX 字面不同：
/// ```text
/// ① 真站点给的是 **mp4**（`vod.youlai.cn/….mp4`），不是 m3u8 ⇒ play 必须两种都收
/// ② `.img-text-con` 在真页面里命中 `<style>` 里的 CSS 文本（不是简介）
///    ⇒ 我们不拿它当简介（宁可不给简介，也不把 CSS 当文案）
/// ```
pub fn detail_from_html(html: &str, id: &str) -> Result<CspDetail, String> {
    let text_after = |marker: &str| -> Option<String> {
        let at = html.find(marker)?;
        let after = &html[at + marker.len()..];
        let gt = after.find('>')?;
        let tail = &after[gt + 1..];
        let lt = tail.find('<')?;
        let t = crate::tvbox::decode_entities(&tail[..lt]).trim().to_string();
        if t.is_empty() {
            None
        } else {
            Some(t)
        }
    };
    let title = text_after("h1-title")
        .or_else(|| text_after("video-title"))
        .ok_or_else(|| "详情页没解析出标题（模板可能改版）".to_string())?;

    // 封面：优先 video 的 poster，其次 <img src>（列表封面形态）
    let cover = html
        .find("poster=\"")
        .and_then(|i| {
            let r = &html[i + 8..];
            r.find('"').map(|e| r[..e].trim().to_string())
        })
        .filter(|s| s.starts_with("http"));

    let src = find_video_source(html)
        .ok_or_else(|| format!("详情页没找到直链（#video source / #video 两级都没命中；id={id}）"))?;

    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover,
        description: None,
        episodes: vec![CspEpisode {
            id: src,
            title: "正片".to_string(),
            flag: "默认".to_string(),
        }],
    })
}

/// 从 HTML 里取视频直链
///
/// 两级选择器（DEX 就是这两级）：
/// ```text
/// ① <video id="video" …><source src="…m3u8" …></video>
/// ② <video id="video" src="…m3u8" …>
/// ```
pub fn find_video_source(html: &str) -> Option<String> {
    // ① source 标签
    if let Some(vpos) = html.find("id=\"video\"") {
        let rest = &html[vpos..];
        if let Some(spos) = rest.find("<source") {
            let seg = &rest[spos..];
            if let Some(s) = seg.find("src=\"") {
                let r2 = &seg[s + 5..];
                if let Some(e) = r2.find('"') {
                    let u = r2[..e].trim().to_string();
                    if u.starts_with("http") {
                        return Some(u);
                    }
                }
            }
        }
        // ② video 标签自己的 src
        if let Some(s) = rest.find("src=\"") {
            let r2 = &rest[s + 5..];
            if let Some(e) = r2.find('"') {
                let u = r2[..e].trim().to_string();
                if u.starts_with("http") {
                    return Some(u);
                }
            }
        }
    }
    None
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for FirstAid {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：分类写死 8 个（DEX 行为），首屏条目真抓第一个分类
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let sites = Self::sites_of(ext);
        let categories: Vec<CspCategory> = CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        let path = path_of_cate(&categories[0].id)
            .ok_or_else(|| "内置分类表里的 id 形态不对（应有 '|'）".to_string())?;
        let html = self.fetch_first(&sites, &path).await?;
        let first = list_from_html(&html, 1, &path)?;
        Ok(CspHome {
            categories,
            items: first.items,
        })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let path = path_of_cate(tid)
            .ok_or_else(|| format!("分类 id 形态不对（应为 '名字|序号'）：{tid}"))?;
        let sites = Self::sites_of(ext);
        let html = self.fetch_first(&sites, &path).await?;
        list_from_html(&html, if page == 0 { 1 } else { page }, &path)
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let sites = Self::sites_of(ext);
        let html = self.fetch_first(&sites, id).await?;
        detail_from_html(&html, id)
    }

    /// 取流：**零解析** —— 详情里拿到的 m3u8 就是播放地址（DEX 的 playerContent 无常量）
    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("FirstAid 不支持搜索（该类目前是撤注册状态（未通电），搜索一并未验）".to_string())
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let url = id.trim();
        if !crate::tvbox::starts_http(url) {
            return Err(format!("播放 id 不是 http 地址：{url}"));
        }
        if !url.to_ascii_lowercase().contains(".m3u8") && !url.to_ascii_lowercase().contains(".mp4") {
            return Err(format!(
                "这条不是可直接播放的媒体地址（详情页可能给了网页地址）：{url}"
            ));
        }
        Ok(vec![CspPlay {
            url: url.to_string(),
            headers: vec![("User-Agent".to_string(), UA.to_string())],
            label: Some("直链".to_string()),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    // 真实结构（取自 2026-10-26 抓到的 /jijiu 页面）：
    // <li class="list-br3"><a href="/jijiu/article/…html"><div class="line-clamp1">标题</div></a></li>
    const LIST_HTML: &str = r#"
      <div class="jj-title-li"><dl><dt><h5>心肺复苏</h5></dt></dl></div>
      <ul class="list-flex-br">
        <li class="list-br3"><a href="/jijiu/article/944A17mma.html">
            <div class="line-clamp1">人工呼吸</div></a></li>
        <li class="list-br3"><a href="/jijiu/article/A330E95l.html">
            <div class="line-clamp1">婴儿心脏骤停</div></a></li>
      </ul>"#;

    const DETAIL_HTML: &str = r#"
      <h1 class="video-title h1-title">人工呼吸法</h1>
      <video id="video" poster="https://file.example/poster.jpeg" width="100%" controls>
        <source src="https://vod.example/abc/sd.mp4" type="video/mp4">
      </video>"#;

    #[test]
    fn categories_match_dex_table() {
        assert_eq!(CATEGORIES.len(), 8, "DEX 里就是 8 个");
        assert_eq!(CATEGORIES[0], ("jijiu|0", "急救技能"));
        assert_eq!(CATEGORIES[7], ("jijiu|7", "意外事故"));
    }

    #[test]
    fn path_of_cate_splits_on_pipe() {
        // 实测：/jijiu 200、/jijiu/0 404 ⇒ **只拼前半段**
        assert_eq!(path_of_cate("jijiu|0").as_deref(), Some("/jijiu"));
        assert_eq!(path_of_cate("jijiu|7").as_deref(), Some("/jijiu"));
        assert_eq!(path_of_cate("a|7").as_deref(), Some("/a"));
        assert!(path_of_cate("jijiu").is_none(), "没有 | 必须 None（不猜）");
        assert!(path_of_cate("jijiu|").is_none());
    }

    #[test]
    fn sites_fall_back_to_default() {
        assert_eq!(FirstAid::sites_of(""), vec![DEFAULT_BASE.to_string()]);
        assert_eq!(
            FirstAid::sites_of(r#"{"site":["https://x.example"]}"#),
            vec!["https://x.example".to_string()]
        );
    }

    #[test]
    fn list_parses_items_and_errs_when_empty() {
        let l = list_from_html(LIST_HTML, 1, "/jijiu/0").expect("正常页应解析成功");
        assert_eq!(l.items.len(), 2, "两条，实际 {:?}", l.items);
        assert_eq!(l.items[0].id, "/jijiu/article/944A17mma.html");
        assert_eq!(l.items[0].title, "人工呼吸");
        assert_eq!(l.items[1].title, "婴儿心脏骤停");
        assert!(l.items[0].cover.is_none(), "这条样本里没有图，不许编封面");

        // ★ 空即 Err：站点 200 但模板改版
        let shell = "<html><body><div id=app></div></body></html>";
        let err = list_from_html(shell, 2, "/jijiu/0").expect_err("0 条目必须 Err");
        assert!(err.contains("没解析出任何条目"), "{err}");
        assert!(err.contains("/jijiu/0"), "错误里要带上是哪一页：{err}");
    }

    #[test]
    fn detail_extracts_m3u8_from_video_source() {
        let d = detail_from_html(DETAIL_HTML, "x1").expect("应解析成功");
        assert_eq!(d.title, "人工呼吸法");
        assert_eq!(d.cover.as_deref(), Some("https://file.example/poster.jpeg"));
        assert_eq!(d.description, None, "真页面里 img-text-con 命中 CSS ⇒ 宁可不给简介");
        assert_eq!(d.episodes.len(), 1);
        assert_eq!(d.episodes[0].id, "https://vod.example/abc/sd.mp4", "真站点给的是 mp4");
    }

    #[test]
    fn detail_falls_back_to_video_src() {
        let html = r#"<h1 class="h1-title">标题</h1>
                      <video id="video" src="https://cdn.example/x.m3u8"></video>"#;
        let d = detail_from_html(html, "x2").expect("二级兜底应命中");
        assert_eq!(d.episodes[0].id, "https://cdn.example/x.m3u8");
    }

    #[test]
    fn detail_errs_on_missing_title_or_m3u8() {
        let no_title = r#"<video id="video"><source src="https://cdn.example/a.m3u8"></video>"#;
        let e1 = detail_from_html(no_title, "x").expect_err("缺标题必须 Err");
        assert!(e1.contains("没解析出标题"), "{e1}");

        let no_src = r#"<h1 class="h1-title">标题</h1><div>没有视频标签</div>"#;
        let e2 = detail_from_html(no_src, "x").expect_err("缺 m3u8 必须 Err");
        assert!(e2.contains("没找到直链"), "{e2}");
        assert!(e2.contains("id=x"), "错误里要带上 id：{e2}");
    }

    #[tokio::test]
    async fn play_returns_m3u8_and_rejects_non_media() {
        let s = FirstAid::new();
        let ok = s
            .play("", "https://cdn.example/a.m3u8", "")
            .await
            .expect("m3u8 应直接可用");
        assert_eq!(ok[0].url, "https://cdn.example/a.m3u8");
        let err = s.play("", "https://m.youlai.cn/jijiu/0/1.html", "").await.expect_err("网页地址不该当直链");
        assert!(err.contains("不是可直接播放"), "{err}");
        let err2 = s.play("", "/jijiu/0/1.html", "").await.expect_err("相对路径不该当直链");
        assert!(err2.contains("不是 http"), "{err2}");
    }

    // ── 真网络（CSP_LIVE=1 + --ignored 才跑；B10 纪律：不给环境变量就 fail）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib first_aid --release -- --ignored --nocapture"]
    async fn csp_live_firstaid_four_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 这条要真网络：显式跑就必须给 CSP_LIVE=1（不给就失败，不许记成 ok）"
        );
        let s = FirstAid::new();
        let ext = "";

        let home = s.home(ext).await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {} 个，首屏条目 {} 个；首条 = {}",
            home.categories.len(),
            home.items.len(),
            home.items.first().map(|i| i.title.clone()).unwrap_or_default()
        );

        let list = s.list("jijiu|0", 1, ext).await.expect("list 应成功");
        eprintln!("[LIVE] list(jijiu|0): {} 条", list.items.len());
        assert!(!list.items.is_empty());

        let id = list.items[0].id.clone();
        let det = s.detail(&id, ext).await.expect("detail 应成功");
        eprintln!(
            "[LIVE] detail({id}): 标题={} 集数={} 直链={}",
            det.title,
            det.episodes.len(),
            det.episodes.first().map(|e| e.id.clone()).unwrap_or_default()
        );

        let ep = det.episodes[0].id.clone();
        let plays = s.play("", &ep, ext).await.expect("play 应成功");
        eprintln!("[LIVE] play: {} 条，首条={}", plays.len(), plays[0].url);
        assert!(plays[0].url.starts_with("http"));
    }
}
