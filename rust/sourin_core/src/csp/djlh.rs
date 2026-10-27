// ═══════════════════════════════════════════════════════════════════════
//  csp_Djlh —— 「轮回 DJ 音乐」的 Rust 重写（**无 jar 参考、无 host ⇒ 不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这是"独立反推"类：把**我找过哪几处、结论是什么**逐条列出来（阴性结论也是证据）
// ```text
// ① 官方 jar（`.probe/csp26-downloads/lmw_classes.dex`，4011 个 class_def / 3088 个
//    `catvod/spider` 类）：**没有 Djlh**（Lead 先取证，我用 `.probe/dex_const_strings.py`
//    复核：按类名列出全部 spider 类，'djlh' 零命中）。
// ② 全 dex 字符串扫描（26172 条）：`djlh|lunhui|轮回|dj.*\.com` 只有 7 条命中，
//    **全部属于 csp_Djuu（m.djuu.com）** —— 没有第二个 DJ 站点。
// ③ GitHub 代码搜索 `csp_Djlh`、`Djlh spider catvod` ⇒ 0 结果。
// ④ 域名猜测逐个真打（`curl --noproxy '*'`）：
//      djlh.com / www.djlh.com / m.djlh.com / djlh.cc / djlh.cn / djlh.net / lunhuidj.com
//      → 全部 **000（DNS 不存在）**
//      djlunhui.com → 301 → https://www.djlunhui.com/ → **200 但 title 是「GOWIN趣胜」赌博站**
//      （不是 DJ 站）⇒ 不是它。
// ⑤ 订阅条目本身：`{"key":"轮回DJ","api":"csp_Djlh"}`，**没有 ext**（同批 Djlh/ALLLive 都是 null）。
// ⇒ **结论：没有任何 host 可打**。按 Owner 授权与交付纪律：实现照最有依据的形态写完，
//   **不写 register_site!**，文件头如实写"无参考、无 host ⇒ 无法证伪"。
// ```
//
// # 那"最有依据的形态"是什么（依据 + 它的边界）
// ```text
// 同类目（DJ 音乐）在本仓 jar 里**唯一**的已知实现是 csp_Djuu（`.probe/csp25` 同类取证）：
//   site = https://m.djuu.com（移动端模板），列表选择器：
//     div#djuu-musiclist-djlist div.djuu-list-item（列表页）
//     div#djuu-musiclist-search div.djuu-list-item（搜索页）
//     data-bs-id（曲目 id）· div.me-2 > span（标题）· /djlist/…_1_1.html（分类）
//   ⇒ 我按**这个模板族**实现（regex 等价翻译，见下），host **只从 ext 取**。
// ⚠️ 但**没有任何证据**表明「轮回DJ = m.djuu.com 或它的兄弟站」：
//   本文件把 m.djuu.com 只当作**模板样本**（测试夹具来自它，标注清楚），
//   **不当成 Djlh 的站** —— 那样才是"编一个站来凑读数"。
// ```
//
// # 能力边界（如实）
// ```text
// home/list/search：按模板实现（真样本来自 m.djuu.com，**Djlh 自己的站未取得**）
// detail：GET `/play/music/{id}` —— 在模板样本站上实测 **404**（所以默认会 Err）；
//         若某天真站返回音频直链就出 1 条线路。**不伪造播放地址**。
// play：只接受 http(s) 直链；其余一律 Err。
// supports_search：**false**（没有 host 可验，不声明能力位 —— 与 AppFox 同口径）
// ```

use async_trait::async_trait;
use regex::Regex;
use std::sync::OnceLock;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 模板样本站的 UA（与 Djuu 的 headers 同源；逐字 Chrome 151）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(20);

/// 从 ext 取 host（本类**没有**写死站点；键名宽容：host/site/url/apiDomain）
pub fn host_of(ext: &str) -> Option<String> {
    let t = ext.trim();
    if t.is_empty() {
        return None;
    }
    if let Ok(j) = crate::tvbox::parse_loose_json(t) {
        for k in ["host", "site", "url", "apiDomain"] {
            if let Some(s) = j.get(k).and_then(|v| v.as_str()) {
                let s = s.trim().trim_end_matches('/');
                if s.starts_with("http") {
                    return Some(s.to_string());
                }
            }
        }
    }
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r#"https?://[^"'\s,\]}]+"#).expect("djlh host regex"));
    re.find(t)
        .map(|m| m.as_str().trim_end_matches('/').to_string())
        .filter(|s| !s.is_empty())
}

pub struct Djlh {
    client: reqwest::Client,
}

impl Djlh {
    pub const CLASS: &'static str = "Djlh";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // 本仓既定惯例：不读系统代理（否则「站点可用」会被测成「全宕」）
            .no_proxy()
            .build()
            .expect("build djlh http client");
        Self { client }
    }

    fn need_host(ext: &str) -> Result<String, String> {
        host_of(ext).ok_or_else(|| {
            "Djlh 需要 ext 里的站点地址（键 `host`/`site`/`url`）。\
             本类**没有写死站点**：官方 jar 里没有 Djlh（阴性结论），全 dex 也无第二個 DJ 站，\
             GitHub 0 结果，域名单（djlh.com/.cc/.cn/.net、lunhuidj.com）全部 DNS 不存在，\
             `djlunhui.com` 实测是赌博站；订阅里该源也没有 ext ⇒ **无可打 host**。\
             这不是「站点挂了」，是「还没有站」——详见文件头取证清单。"
                .to_string()
        })
    }

    async fn get(&self, host: &str, path: &str) -> Result<String, String> {
        let url = format!("{host}{path}");
        let resp = self
            .client
            .get(&url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .header(reqwest::header::REFERER, format!("{host}/"))
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）· 前 120 字：{}", head(&text)));
        }
        Ok(text)
    }
}

impl Default for Djlh {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  解析（模板族的 regex 等价翻译）
// ═══════════════════════════════════════════════════════════════════════
//
// JSOUP 选择器 → regex：
// ```text
// div#djuu-musiclist-djlist div.djuu-list-item   → 以 `data-bs-id="(\d+)"` 切块
// div#djuu-musiclist-search div.djuu-list-item   → 同上（同一个块形态，只是容器 id 不同）
// data-bs-id                                      → `data-bs-id="(\d+)"`
// div.me-2 > span                                 → 块内**第一个** `<span>([^<]*)</span>`
// djuuSwitch.djlist('/djlist/N_0_1_1.html')       → 分类 id + 名字：
//   `djuuSwitch\.djlist\('/djlist/(\d+)_0_1_1\.html'\)">([^<]*)<`
// ```

fn re_item_id() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r#"data-bs-id="(\d+)""#).expect("djlh item id"))
}

fn re_span() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<span>([^<]*)</span>").expect("djlh span"))
}

fn re_cat() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"djuuSwitch\.djlist\('/djlist/(\d+)_0_1_1\.html'\)">([^<]*)<"#)
            .expect("djlh cat")
    })
}

fn re_audio() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"(?:src|data-src)="(https?://[^"]+\.(?:mp3|m4a))""#).expect("djlh audio")
    })
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#039;", "'")
        .replace("&nbsp;", " ")
}

/// 解析分类（`djuuSwitch.djlist('/djlist/N_0_1_1.html')`）
pub fn parse_categories(html: &str) -> Vec<CspCategory> {
    let mut out: Vec<CspCategory> = Vec::new();
    for c in re_cat().captures_iter(html) {
        let id = c[1].to_string();
        let name = unescape(&c[2]).trim().to_string();
        if name.is_empty() || out.iter().any(|x| x.id == id) {
            continue;
        }
        out.push(CspCategory { id, name });
    }
    out
}

/// 解析曲目列表（`data-bs-id` 切块 + 块内第一个 `<span>` 当标题）
pub fn parse_items(html: &str) -> Result<Vec<CspItem>, String> {
    let starts: Vec<(usize, String)> = re_item_id()
        .captures_iter(html)
        .filter_map(|c| {
            let m = c.get(0)?;
            Some((m.start(), c.get(1)?.as_str().to_string()))
        })
        .collect();
    if starts.is_empty() {
        return Err(format!(
            "页面里没有任何 `data-bs-id` 曲目块（模板可能改版/壳页）· 页面长度 {} 字节 · 前 80 字：{}",
            html.len(),
            head(html)
        ));
    }
    let mut out: Vec<CspItem> = Vec::new();
    for (i, (start, id)) in starts.iter().enumerate() {
        let stop = starts
            .get(i + 1)
            .map(|(s, _)| *s)
            .unwrap_or_else(|| (*start + 2000).min(html.len()));
        let block = html.get(*start..stop).unwrap_or("");
        let Some(title) = re_span()
            .captures(block)
            .map(|c| unescape(&c[1]).trim().to_string())
            .filter(|s| !s.is_empty())
        else {
            continue;
        };
        if out.iter().any(|x| &x.id == id) {
            continue;
        }
        out.push(CspItem {
            id: id.clone(),
            title,
            cover: None,
            subtitle: None,
        });
    }
    if out.is_empty() {
        return Err("页面里有曲目块但**没有一条**能解析出标题（模板可能改版）".to_string());
    }
    Ok(out)
}

/// 分类列表路径（模板族真实形态：`/djlist/{cid}_0_{page}_1.html`）
pub fn list_path(cid: &str, page: u32) -> String {
    format!("/djlist/{}_0_{}_1.html", cid.trim(), page.max(1))
}

/// 搜索路径（模板族真实形态）
pub fn search_path(kw: &str, page: u32) -> String {
    format!(
        "/search?musicname={}&page={}",
        urlencoding::encode(kw),
        page.max(1)
    )
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现（**没有 register_site!**：无 host）
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Djlh {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = Self::need_host(ext)?;
        let html = self.get(&host, "/").await?;
        let categories = parse_categories(&html);
        if categories.is_empty() {
            return Err(
                "首页没有任何分类（模板可能改版/壳页）——`djuuSwitch.djlist('/djlist/N_0_1_1.html')` 未命中"
                    .to_string(),
            );
        }
        let items = parse_items(&html)?;
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() || !tid.chars().all(|c| c.is_ascii_digit()) {
            return Err(format!("分类 id 应为数字（模板族形态）：`{tid}`"));
        }
        let host = Self::need_host(ext)?;
        let page = page.max(1);
        let html = self.get(&host, &list_path(tid, page)).await?;
        let items = parse_items(&html).map_err(|e| format!("分类 {tid} 第 {page} 页：{e}"))?;
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let page = page.max(1);
        let html = self.get(&host, &search_path(kw, page)).await?;
        let items = parse_items(&html).map_err(|e| format!("搜索「{kw}」第 {page} 页：{e}"))?;
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        // ★ 没有 host 可验 ⇒ 不声明 true（与 AppFox 同口径）
        false
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("详情 id 为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let path = format!("/play/music/{id}");
        let html = self
            .get(&host, &path)
            .await
            .map_err(|e| format!("模板族的详情端点 `{path}` 取不到：{e}"))?;
        let Some(url) = re_audio().captures(&html).map(|c| c[1].to_string()) else {
            return Err(format!(
                "详情页里没有音频直链（mp3/m4a，模板可能改版）：{host}{path}"
            ));
        };
        Ok(CspDetail {
            id: id.to_string(),
            title: format!("曲目 {id}"),
            cover: None,
            description: None,
            episodes: vec![CspEpisode {
                id: url,
                title: "在线收听".to_string(),
                flag: "默认".to_string(),
            }],
        })
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if !id.starts_with("http") {
            return Err(format!(
                "播放 id 不是 http 音频直链（`{id}`）——本类没有 host、detail 也不会伪造播放地址，\
                 所以这里拒绝，而不是把曲目 id 当流地址返回"
            ));
        }
        Ok(vec![CspPlay {
            url: id.to_string(),
            headers: vec![("User-Agent".to_string(), UA.to_string())],
            label: Some("DJ 音乐直链".to_string()),
        }])
    }
}

// ⚠️ **没有 `register_site!`**：判据第 ② 条（有可用 host）不成立 —— 见文件头取证清单。

// ═══════════════════════════════════════════════════════════════════════
//  测试（夹具来自**模板样本站** m.djuu.com，不是 Djlh 的站 —— 如实标注）
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 模板样本（2026-10-28 抓自 `https://m.djuu.com/djlist/115_0_1_1.html`，原文 30 条，摘 1 条）
    const FIX_LIST: &str = r#"<div class="w-100" id="djuu-musiclist-djlist"><div class="container px-0 ps-1 d-flex flex-nowrap justify-content-between align-items-center djuu-list-item djuu-list-bg2" data-bs-id="327814"> <div class="d-flex flex-column text-nowrap overflow-hidden me-2" onclick="music.playlist(this)"> <span>【DJUU独家】黑豹乐队 - 无地自容(DJR浪 Electro Rmx 2026)</span> <div class="d-flex justify-content-start align-items-center"> <div class="djuu-ml-span">ID:327814</div> </div> </div> </div></div>"#;

    /// 模板样本（2026-10-28 抓自 `https://m.djuu.com/`，原文分类区，摘 2 条）
    const FIX_CATS: &str = r#"<div class="fs-6 mb-2" onclick="djuuSwitch.djlist('/djlist/115_0_1_1.html')">独家舞曲</div><div class="me-3" onclick="djuuSwitch.djlist('/djlist/116_0_1_1.html')">Y鼓(Electro)</div>"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Djlh::CLASS, "Djlh");
    }

    #[test]
    fn host_comes_only_from_ext() {
        assert_eq!(host_of(r#"{"host":"https://a.example"}"#).as_deref(), Some("https://a.example"));
        assert_eq!(host_of(r#"{"site":["https://b.example/"]}"#).as_deref(), Some("https://b.example"));
        assert_eq!(host_of("https://c.example/x").as_deref(), Some("https://c.example/x"));
        assert_eq!(host_of(""), None);
        assert_eq!(host_of("{}"), None);
    }

    #[test]
    fn categories_and_items_parse_the_template_family() {
        let cats = parse_categories(FIX_CATS);
        assert_eq!(cats.len(), 2);
        assert_eq!(cats[0].id, "115");
        assert_eq!(cats[0].name, "独家舞曲");
        assert_eq!(cats[1].name, "Y鼓(Electro)");

        let items = parse_items(FIX_LIST).expect("模板样本必须解析得出来");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, "327814");
        assert!(items[0].title.contains("无地自容"), "{}", items[0].title);
    }

    #[test]
    fn empty_page_reports_structure_change() {
        let e = parse_items("<html><body>nothing</body></html>").unwrap_err();
        assert!(e.contains("模板可能改版"), "{e}");
        // 有 id 但没标题 ⇒ 仍然 Err（不造空标题条目）
        let e2 = parse_items(r#"<div data-bs-id="1"></div>"#).unwrap_err();
        assert!(e2.contains("没有一条"), "{e2}");
    }

    #[test]
    fn list_and_search_paths_are_the_template_shape() {
        assert_eq!(list_path("115", 1), "/djlist/115_0_1_1.html");
        assert_eq!(list_path("115", 3), "/djlist/115_0_3_1.html");
        assert_eq!(
            search_path("串烧", 1),
            "/search?musicname=%E4%B8%B2%E7%83%A7&page=1"
        );
    }

    #[tokio::test]
    async fn without_host_every_segment_reports_the_evidence_instead_of_an_empty_result() {
        let s = Djlh::new();
        for e in [
            s.home("").await.err(),
            s.list("115", 1, "").await.err(),
            s.search("x", 1, "").await.err(),
            s.detail("1", "").await.err(),
        ] {
            let msg = e.expect("无 host 必须 Err");
            assert!(msg.contains("ext"), "{msg}");
            assert!(msg.contains("还没有站"), "要写明是「没有站」而不是「站挂了」：{msg}");
        }
        assert!(!s.supports_search(), "没有 host 可验 ⇒ 不声明支持搜索");
    }

    #[tokio::test]
    async fn play_refuses_non_http_ids() {
        let s = Djlh::new();
        let e = s.play("默认", "12345", "").await.expect_err("非 http 必须 Err");
        assert!(e.contains("不是 http 音频直链"), "{e}");
    }

    #[test]
    fn it_is_not_registered_because_there_is_no_host() {
        let flat = crate::csp::shared::impl_src_only(include_str!("djlh.rs"));
        assert!(!flat.contains("register_site!(Djlh)"), "★ 无参考、无 host ⇒ 不注册");
        assert!(
            !crate::csp::is_implemented("csp_Djlh"),
            "★ 不许进注册表（订阅里 1 站但没有 host）"
        );
    }
}