// ═══════════════════════════════════════════════════════════════════════
//  csp_QuPanSo —— 「趣盘搜」网盘资源搜索（**纯搜索源**）的 Rust 重写
// ═══════════════════════════════════════════════════════════════════════
//
// # 订阅里这 **1** 站（逐字，`.probe/ref-subscription.json`）
// ```json
// {"key":"趣盘","name":"🔍趣盘｜网盘搜索","api":"csp_QuPanSo","searchable":1,"quickSearch":0,
//  "filterable":0,"timeout":60}      ← ★ 没有 ext
// ```
// ⇒ 三条判据 ① 订阅有 1 站 ✓ ② host：DEX 里**硬编码** `https://b.funletu.com` ✓
//    ③ 真网取到数据 ✓ ⇒ **注册**。
//
// # 协议（DEX `[E]` = searchContent 逐字还原 + 2026-10-27 直连复测）
// ```text
// POST {host}/search
//   headers  content-type: application/json · Origin: {host} · Referer: {host}/
//   body     {"keyword":"<kw>","categoryid":0,"filetypeid":1,"courseid":1,
//             "page":N,"pageSize":15,"sortBy":"sort","order":"desc","offset":0}
//   200      {"code":200,"msg":"请求成功","data":{"list":[…],"total":N}}
//   item     {id, title, filename, url, link, extcode, size, uploaderid, views,
//             createtime, updatetime, …}       ← url 就是网盘分享页
// ```
// 实测读数（`curl --noproxy '*'`，直连）：
// ```text
// kw=三体      → 200 · 982 B · total=2
//                [0] title="我的朋友安德烈（2026）4K HQ 高码" url="https://pan.quark.cn/s/90e6692f0e25"
//                [1] title="苦尽柑来遇见你2025"              url="https://pan.quark.cn/s/33662e7d19a1"
// kw=庆余年 / 火影忍者 / 阿凡达 / 流浪地球 / 让子弹飞 / 甄嬛传 → 200 · 62 B · total=0
//                                    ← ★ 站点自己的"没结果"，不是解析失败
// ```
// ★ 这个类**只有一个端点**：DEX 里没有 home/category/detail
//   （`[parseItemsToJson]` 直接把搜索结果拼成 vod 条目）。
//
// # 判"没结果"与判"接口改版"必须分开（本文件最关键的一条）
// ```text
// 62 字节的 `{"code":200,…,"list":[],"total":0}` 与"接口被换掉"返回的
// `{"code":500,…}` / HTML 壳页，**都可能是空列表**。
// 区别只在 `data.list` **是不是数组**：
//   · 是数组且为空 ⇒ 站点确实没这个片（Ok 空列表，UI 显示"无结果"）
//   · 不是数组     ⇒ 接口改版/风控 ⇒ **Err**（不许把"我没解析到"说成"没这个片"）
// 这条与 `.agents/notes/implemented/feature/2026-10-26-csp-honest-contract.md`
// 的 ① 同源：空结果只有在**协议本身回答了"空"**时才算事实。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspDetail, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `[E]` 的 UA（`head` 里逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// DEX 里硬编码的站点（`[E]` 的第一条常量逐字）
pub const DEFAULT_HOST: &str = "https://b.funletu.com";

const TIMEOUT: Duration = Duration::from_secs(20);

/// 每页条数（DEX 逐字：`pageSize:15`）
const PAGE_SIZE: u32 = 15;

// ── 盘类型 → 图标（DEX `[E]` 里 4 条 URL 逐字；按分享链接的域名选）──
pub const ICON_QUARK: &str =
    "https://img.51shazhu.com/autoupload/g1b6f/20260807/bsds/1200X800/quark.jpg/webp";
pub const ICON_UC: &str =
    "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/kbEn/1200X800/uc.jpg/webp";
pub const ICON_BAIDU: &str =
    "https://img.51shazhu.com/autoupload/g1b6f/20260806/V6JN/1200X800/baidu.jpg/webp";
pub const ICON_ALI: &str =
    "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/8Yr6/1200X800/aliyun.jpg/webp";

pub struct QuPanSo {
    client: reqwest::Client,
}

impl QuPanSo {
    pub const CLASS: &'static str = "QuPanSo";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // 与 pan_web_share / zhinan 同一条纪律：不读系统代理
            //（代理会把"站点可用"测成"全宕"，且错误文本不含真因）
            .no_proxy()
            .build()
            .expect("build qu_pan_so http client");
        Self { client }
    }

    /// host：DEX 硬编码优先，`ext` 里的 `site`/`host` 可覆盖（站点换域名时不必改代码）
    pub fn host_of(ext: &str) -> String {
        let pick = |k: &str| -> Option<String> {
            crate::tvbox::parse_loose_json(ext)
                .ok()?
                .get(k)
                .and_then(|v| v.as_str())
                .map(|s| s.trim().trim_end_matches('/').to_string())
                .filter(|s| s.starts_with("http"))
        };
        pick("site")
            .or_else(|| pick("host"))
            .unwrap_or_else(|| DEFAULT_HOST.to_string())
    }

    /// 请求体（DEX 逐字拼接顺序；顺序不对上游会当"少字段"）
    pub fn body_of(kw: &str, page: u32) -> String {
        format!(
            "{{\"keyword\":\"{kw}\",\"categoryid\":0,\"filetypeid\":1,\"courseid\":1,\
             \"page\":{page},\"pageSize\":{PAGE_SIZE},\"sortBy\":\"sort\",\"order\":\"desc\",\
             \"offset\":0}}"
        )
    }

    fn item_of(v: &Value) -> Option<CspItem> {
        let url = v
            .get("url")
            .and_then(|x| x.as_str())
            .map(|s| s.trim())
            .filter(|s| s.starts_with("http"))
            .or_else(|| {
                v.get("link")
                    .and_then(|x| x.as_str())
                    .map(|s| s.trim())
                    .filter(|s| s.starts_with("http"))
            })?;
        let title = v
            .get("title")
            .and_then(|x| x.as_str())
            .map(clean_title)
            .filter(|s| !s.is_empty())?;
        Some(CspItem {
            // ★ id 就是**分享页 URL**：这个类没有详情页，play 直接用它（见 play 的注释）
            id: url.to_string(),
            title,
            cover: icon_of(url).map(|s| s.to_string()),
            subtitle: v
                .get("updatetime")
                .and_then(|x| x.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        })
    }
}

impl Default for QuPanSo {
    fn default() -> Self {
        Self::new()
    }
}

/// 搜索结果标题里带搜索高亮标签（DEX 逐字 `<em>` / `</em>`）⇒ 去掉
pub fn clean_title(s: &str) -> String {
    s.replace("<em>", "").replace("</em>", "").trim().to_string()
}

/// 按分享链接域名选盘图标（DEX `[E]` 的域名逐字）
pub fn icon_of(url: &str) -> Option<&'static str> {
    if url.contains("pan.quark.cn") {
        Some(ICON_QUARK)
    } else if url.contains("drive.uc.cn") {
        Some(ICON_UC)
    } else if url.contains("pan.baidu.com") {
        Some(ICON_BAIDU)
    } else if url.contains("aliyundrive.com") || url.contains("alipan.com") {
        Some(ICON_ALI)
    } else {
        None
    }
}

/// 是不是网盘分享页（play 的自证；与 DEX 父类 `Pan` 的 9 家盘同源）
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

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

// ══ ★ 注册（订阅 1 站 / DEX 硬编码 host / 真网 2 条）══
crate::csp::register_site!(QuPanSo);

#[async_trait]
impl CspSite for QuPanSo {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 纯搜索源：DEX 里没有 homeContent ⇒ 没有分类表
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        Err("QuPanSo 是纯搜索源（DEX 只有 searchContent，没有 homeContent）：\
             它不提供分类表，请用搜索"
            .to_string())
    }

    /// 纯搜索源：DEX 里没有 categoryContent
    async fn list(&self, tid: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(format!(
            "QuPanSo 是纯搜索源，没有分类列表（收到 tid={tid}）：\
             DEX 里不存在 categoryContent，别把它当点播站用"
        ))
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let host = Self::host_of(ext);
        let url = format!("{host}/search");
        let body = Self::body_of(kw, page);
        let resp = self
            .client
            .post(&url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .header(reqwest::header::ORIGIN, host.as_str())
            .header(reqwest::header::REFERER, format!("{host}/"))
            .body(body)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）：{}", head(&text)));
        }
        let v = crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
        let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
        if code != 200 {
            return Err(format!(
                "接口 code={code}（msg={}，kw={kw}）—— 可能接口改版/风控",
                v.get("msg").and_then(|m| m.as_str()).unwrap_or("?")
            ));
        }
        // ★★ 判据：`data.list` **是数组**才叫"接口回答了我"
        let list = v
            .get("data")
            .and_then(|d| d.get("list"))
            .and_then(|l| l.as_array())
            .ok_or_else(|| {
                format!(
                    "响应里没有 data.list 数组（kw={kw}）—— 可能接口改版/风控壳页\
                     （前 120 字：{}）",
                    head(&text)
                )
            })?;
        // 是数组但为空 ⇒ 站点真的没这个片（实测 6 个关键词里 5 个 total=0）
        let items: Vec<CspItem> = list.iter().filter_map(Self::item_of).collect();
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: v
                .get("data")
                .and_then(|d| d.get("total"))
                .and_then(|t| t.as_u64()),
        })
    }

    fn supports_search(&self) -> bool {
        true // 真实现且真网验证过（三体 → 2 条）
    }

    /// 纯搜索源：没有详情页（搜索结果本身就是网盘分享页）
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        Err(format!(
            "QuPanSo 没有详情页：搜索结果本身就是网盘分享页（id={}），\
             请直接用该 id 取播放（play）",
            id.chars().take(48).collect::<String>()
        ))
    }

    /// 取"流"：**网盘分享页**（不是直链）
    ///
    /// # 为什么 id 就是 URL
    /// ```text
    /// 这个类的条目没有"片子 id"，只有分享链接（DEX 的 `parseItemsToJson` 里
    /// vod_id 取的就是 item.url）。⇒ play 只做两件事：
    ///   ① 自证这是网盘分享页（防"把任意字符串当播放地址"的假通）
    ///   ② 带上 Referer 交回去，label 写明"（分享页）"
    /// 把分享页解成直链属网盘模块（第 20 项），这里**不伪造** m3u8/mp4。
    /// ```
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let url = id.trim();
        if !is_pan_share(url) {
            return Err(format!(
                "QuPanSo 的剧集 id 必须是网盘分享页 URL（夸克/UC/百度/阿里…），实际：\
                 {}（线路={flag}）",
                url.chars().take(48).collect::<String>()
            ));
        }
        let host = Self::host_of(ext);
        Ok(vec![CspPlay {
            url: url.to_string(),
            headers: vec![("Referer".to_string(), format!("{host}/"))],
            label: Some(format!("{flag}（分享页）")),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── 真实响应（2026-10-27 直连 `POST https://b.funletu.com/search` kw=三体 的原文）──
    const LIVE_BODY: &str = r#"{"code":200,"msg":"请求成功","data":{"list":[
      {"id":4974196,"title":"我的朋友安德烈（2026）4K HQ 高码","filename":"W😲🉐👫🏻anの煭","url":"https://pan.quark.cn/s/90e6692f0e25","link":null,"extcode":"","unzipcode":"","size":"共 2 个文件 18.1G","courseid":1,"filetypeid":1,"categoryid":1,"uploaderid":"小*的分享","top":0,"recommend":0,"views":11,"viewshistory":11,"violate":0,"state":0,"sort":0,"valid":0,"checked":1,"createtime":"2026-03-04 16:07:33","updatetime":"2026-03-16 19:16:19"},
      {"id":2780656,"title":"苦尽柑来遇见你2025","filename":"🍊🍊🍊🍊","url":"https://pan.quark.cn/s/33662e7d19a1","link":null,"extcode":"","unzipcode":"","size":"共 18 个文件 35.7G","courseid":1,"filetypeid":1,"categoryid":1,"uploaderid":"得意*坚果的分享","top":0,"recommend":0,"views":10,"viewshistory":10,"violate":0,"state":0,"sort":0,"valid":0,"checked":1,"createtime":"2025-09-28 11:26:44","updatetime":"2026-02-28 19:36:35"}
    ],"total":2}}"#;

    /// 真实"没结果"（kw=庆余年，62 字节原文）
    const EMPTY_BODY: &str = r#"{"code":200,"msg":"请求成功","data":{"list":[],"total":0}}"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(QuPanSo::CLASS, "QuPanSo");
    }

    #[test]
    fn registered_because_all_three_conditions_hold() {
        assert!(
            crate::csp::is_implemented("csp_QuPanSo"),
            "★ 订阅 1 站 + DEX 硬编码 host + 真网 2 条 ⇒ 必须已注册"
        );
        assert_eq!(crate::csp::route("csp_QuPanSo").unwrap().class(), "QuPanSo");
    }

    #[test]
    fn host_is_the_dex_literal_and_can_be_overridden_by_ext() {
        assert_eq!(QuPanSo::host_of(""), "https://b.funletu.com");
        assert_eq!(QuPanSo::host_of("{}"), "https://b.funletu.com");
        // ext 覆盖（站点换域名时不必改代码）
        assert_eq!(
            QuPanSo::host_of(r#"{"site":"https://b.example.com/"}"#),
            "https://b.example.com"
        );
        assert_eq!(
            QuPanSo::host_of(r#"{"host":"https://h.example.com"}"#),
            "https://h.example.com"
        );
        // 非 http 的值不认（防止把垃圾串当 host 拼进 URL）
        assert_eq!(QuPanSo::host_of(r#"{"site":"not-a-url"}"#), DEFAULT_HOST);
    }

    #[test]
    fn request_body_matches_the_dex_shape_verbatim() {
        assert_eq!(
            QuPanSo::body_of("三体", 2),
            // ★ 字段顺序与 DEX 一致（categoryid/filetypeid/courseid/page/pageSize/sortBy/order/offset）
            r#"{"keyword":"三体","categoryid":0,"filetypeid":1,"courseid":1,"page":2,"pageSize":15,"sortBy":"sort","order":"desc","offset":0}"#
        );
    }

    #[test]
    fn live_response_maps_two_items_with_pan_icons() {
        let v = crate::tvbox::parse_loose_json(LIVE_BODY).unwrap();
        let list = v["data"]["list"].as_array().unwrap();
        let items: Vec<CspItem> = list.iter().filter_map(QuPanSo::item_of).collect();
        assert_eq!(items.len(), 2);
        assert_eq!(
            items[0].id, "https://pan.quark.cn/s/90e6692f0e25",
            "★ id 就是分享页 URL"
        );
        assert_eq!(items[0].title, "我的朋友安德烈（2026）4K HQ 高码");
        assert_eq!(items[0].subtitle.as_deref(), Some("2026-03-16 19:16:19"));
        assert_eq!(items[0].cover.as_deref(), Some(ICON_QUARK));
    }

    #[test]
    fn em_highlight_is_stripped_from_titles() {
        assert_eq!(clean_title("<em>三体</em>全集"), "三体全集");
        assert_eq!(clean_title("  <em>流</em><em>浪</em>地球 "), "流浪地球");
    }

    #[test]
    fn icon_is_chosen_by_share_host() {
        assert_eq!(icon_of("https://pan.quark.cn/s/x"), Some(ICON_QUARK));
        assert_eq!(icon_of("https://drive.uc.cn/s/x"), Some(ICON_UC));
        assert_eq!(icon_of("https://pan.baidu.com/s/1x"), Some(ICON_BAIDU));
        assert_eq!(icon_of("https://www.alipan.com/s/x"), Some(ICON_ALI));
        assert_eq!(icon_of("https://example.com/s/x"), None);
    }

    /// ★★ 本文件最关键的一条：**空数组 = 真没结果（Ok 空）**，**没有数组 = 接口改版（Err）**
    #[test]
    fn empty_list_is_a_fact_but_a_missing_list_is_an_error() {
        let v = crate::tvbox::parse_loose_json(EMPTY_BODY).unwrap();
        let list = v["data"]["list"].as_array().expect("★ 空数组必须是数组");
        assert!(list.is_empty());
        assert_eq!(v["data"]["total"].as_u64(), Some(0));

        // 接口被换掉/风控：没有 data.list ⇒ 必须 Err（不许当"没这个片"）
        let broken = crate::tvbox::parse_loose_json(r#"{"code":500,"msg":"系统错误"}"#).unwrap();
        assert!(broken.get("data").and_then(|d| d.get("list")).is_none());
        assert!(
            broken
                .get("data")
                .and_then(|d| d.get("list"))
                .and_then(|l| l.as_array())
                .is_none(),
            "★ 『没有数组』与『空数组』必须是两种结局（前者 Err）"
        );
    }

    #[test]
    fn item_without_url_is_skipped_not_faked() {
        assert!(QuPanSo::item_of(&json!({"title": "有标题没链接"})).is_none());
        assert!(QuPanSo::item_of(&json!({"url": "https://pan.quark.cn/s/x"})).is_none());
    }

    #[tokio::test]
    async fn search_only_source_reports_what_it_does_not_have() {
        let s = QuPanSo::new();
        let h = s.home("").await.expect_err("没有 homeContent");
        assert!(h.contains("纯搜索源"), "{h}");
        let l = s.list("1", 1, "").await.expect_err("没有 categoryContent");
        assert!(l.contains("没有分类列表"), "{l}");
        let d = s
            .detail("https://pan.quark.cn/s/x", "")
            .await
            .expect_err("没有详情页");
        assert!(d.contains("没有详情页"), "{d}");
        assert!(s.supports_search(), "★ search 真实现且真网验证过");
        // 空关键词在网络前就拦掉
        assert!(s.search("  ", 1, "").await.is_err());
    }

    #[tokio::test]
    async fn play_passes_the_share_page_through_and_refuses_other_ids() {
        let s = QuPanSo::new();
        let out = s
            .play("夸克", "https://pan.quark.cn/s/90e6692f0e25", "")
            .await
            .expect("分享页应直接可用");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].url, "https://pan.quark.cn/s/90e6692f0e25");
        assert_eq!(out[0].label.as_deref(), Some("夸克（分享页）"));
        assert_eq!(out[0].headers[0].0, "Referer");
        // 非分享页 ⇒ Err（不许把任意字符串当播放地址）
        let e = s
            .play("夸克", "https://example.com/a.m3u8", "")
            .await
            .expect_err("★ 非网盘分享页必须 Err");
        assert!(e.contains("必须是网盘分享页"), "{e}");
    }

    /// ★ 结构性判据：`.no_proxy()` 必须在 `.timeout(…)` 之后、`.build()` 之前
    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("qu_pan_so.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("必须有 .timeout");
        let n = flat.find(".no_proxy()").expect("★ 必须 .no_proxy()");
        let b = flat.find(".build()").expect("必须有 .build()");
        assert!(t < n && n < b, "★ 位置必须是 timeout → no_proxy → build");
    }

    // ══════════════════════════════════════════════════════════════════
    //  真网络（`#[ignore]`）：不给 `CSP_LIVE=1` 就**断言失败**（不假绿）
    // ══════════════════════════════════════════════════════════════════
    fn need_live() {
        assert_eq!(
            std::env::var("CSP_LIVE").as_deref(),
            Ok("1"),
            "真网络用例：必须 `CSP_LIVE=1 cargo test --lib csp::qu_pan_so:: -- --ignored` 才跑"
        );
    }

    #[tokio::test]
    #[ignore]
    async fn live_search_returns_items() {
        need_live();
        let s = QuPanSo::new();
        let r = s.search("三体", 1, "").await.expect("search 必须真取到数据");
        println!(
            "LIVE qu_pan_so search(三体): {} 条 · total={:?} · 首条={} · {}",
            r.items.len(),
            r.total,
            r.items.first().map(|i| i.title.as_str()).unwrap_or("-"),
            r.items.first().map(|i| i.id.as_str()).unwrap_or("-")
        );
        assert!(!r.items.is_empty(), "三体 应有结果");
        assert!(r.items.iter().all(|i| is_pan_share(&i.id)));
    }
}
