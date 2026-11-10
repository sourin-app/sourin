// ═══════════════════════════════════════════════════════════════════════
//  csp_QingtingFM —— 蜻蜓FM（**音频站**：一"集"＝一条电台/音频，play 给音频流）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅（`.probe/ref-subscription.json` 逐字）：
//   {"type":3, "api":"csp_QingtingFM", "key":"蜻蜓FM", "name":"📻蜻蜓｜FM频道", "ext": null}
// ⇒ ext 为 null ⇒ **host 只能写死**（DEX 常量逐字给出 4 个域名，见下）。
// ```
//
// # 协议取证（`.probe/csp26-downloads/lmw_classes.dex` 直读，**未起 jadx**）
//
// 类 `com.github.catvod.spider.QingtingFM`，父类 `crawler.Spider`，9 个方法。
// 常量来源：`.probe/csp24-dex-QingtingFM.txt` + `r3_disasm_v2.py` 的逐方法反汇编。
//
// ```text
// 域名（DEX 逐字，4 个**不同**的子域，别"顺手统一"）
//   https://www.qtfm.cn                        ← Referer / 站点根（<init> 里的字段 a）
//   https://webbff.qtfm.cn/www                 ← **GraphQL 网关**（home/search 都打这里，POST）
//   https://webapi.qtfm.cn/api/pc/radio/<id>   ← 详情（GET，返回 {album:{…}}）
//   https://lhttp-hw.qtfm.cn/live/<id>/64k.mp3 ← 取流（**音频流**，不是剧集）
//
// 请求头（DEX `b()` 逐字，只有两个）
//   User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) … Chrome/151.0.0.0 Safari/537.36
//   Referer   : https://www.qtfm.cn
//
// 三个接口
//   home/list  POST https://webbff.qtfm.cn/www
//              body {"query":"{\n    radioPage(cid:<cateId>, page:<page>){\n      contents\n    }\n  }"}
//              → data.radioPage.contents.items[] {id, imgUrl, title, desc}
//   detail     GET  https://webapi.qtfm.cn/api/pc/radio/<id>
//              → album {id, title, cover, description}
//   search     POST https://webbff.qtfm.cn/www
//              body {"query":"… searchResultsPage(keyword:\"<kw>\", page:<n>, include:\"channel_live\" ) …"}
//              → data.searchResultsPage.searchData[] {id, cover, title, description}
//   play       https://lhttp-hw.qtfm.cn/live/<id>/64k.mp3
// ```
//
// ★ **GraphQL 不是可选装饰**：`/www` 只认 `{"query": …}` 这个形状；把 `cid/page`
//   当查询串拼上去（REST 直觉）拿不到数据。DEX 里 query 字符串的**空白与换行**是逐字的，
//   本实现照抄（服务端对空白不敏感，但照抄可以少一个变量）。
//
// ★ **音频站的"集"语义**（与剧集类不同，别照搬模板）
// ```text
// 电台 = 一个持续直播流 ⇒ detail 返回 **1 条** "集"（id = 电台 id，标题 = 电台名），
// play 直接拼 64k.mp3 直播地址。**不做"多集/选集"**：DEX 里 detailContent 的
// vod_play_url 也只有一条（`album.title + "$" + album.id`）。
// ```
//
// # 真网络读数（2026-10-27 实测，直连 `.no_proxy()`；原始行见 `.probe/csp-short-live.log`）
//
// ```text
// POST /www radioPage(cid:436,page:1) → 200 · 832 B · items=5  · items[0]=潮州戏曲广播
// POST /www radioPage(cid:3,  page:1) → 200 · items=10 · items[0]=北京新闻广播  ⇒ 3=北京 ✅
// POST /www radioPage(cid:429,page:1) → 200 · items=12 · items[0]=北京交通广播  ⇒ 429=交通 ✅
// POST /www radioPage(cid:436,page:2) → 200 · items=0（真没有第二页，不是解析失败）
// GET  /api/pc/radio/20500164        → 200 · album.title=泊头人民广播电台
// POST /www searchResultsPage("相声") → 200 · 5477 B · searchData[0].id=20500164
// GET  lhttp-hw…/live/4595/64k.mp3   → 200 · audio/mpeg（真音频流；00:07 那一轮）
// ```
//
// ★★ 取流侧两条实测（**可变上游**，别把"台停播"读成"我们拼错"）
// ```text
// ① CDN **不支持 HEAD**：HEAD 同 URL → 400 text/html；GET(+Range) → 200 audio/mpeg
//    ⇒ 判活必须 GET。用 HEAD 会把真音频流测成 400（"我打错被读成上游坏"那一型）。
// ② 单个台**会变**：/live/4595/64k.mp3 00:07 是 200 audio/mpeg、00:58 变 404 text/html；
//    同一时刻 /live/269、/live/1952、/live/20211622、/live/20500178 仍是 200 audio/mpeg
//    ⇒ 是台停了/换流，不是地址形状错。live 用例因此测"前 5 个台里至少一个出音频"。
// ```
// 分类表 44 项里 **3 个已实测对上**（436=曲艺 / 3=北京 / 429=交通）；其余 41 项是
// DEX 两个数组**按下标配对**的结果，未逐项实测 —— 这一条如实登记在下面 `CATS` 的注释里。
//
// # 契约边界（本仓纪律）
// ```text
// · 空结果：list 第 1 页 0 条 ⇒ Err（可能改版/风控壳页）；第 2 页起 0 条 ⇒ Ok（真没有更多）
//   —— 与 `app_fox.rs` 同一条口径。
// · 代理：忽略环境代理，由 CspHttpContext 应用当前应用代理策略。
// · 不新增依赖：只用 serde_json / reqwest（Cargo.toml 零 diff）。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::{pick_arr, pick_id_str, pick_str};

/// DEX `b()` 里的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 站点根（DEX `<init>` 里字段 `a` 的值，同时是 Referer）
pub const BASE: &str = "https://www.qtfm.cn";
/// GraphQL 网关（home + search）
const BFF: &str = "https://webbff.qtfm.cn/www";
/// 详情前缀（GET 时**直接拼 id**，没有 `?id=` 这种形状）
const RADIO_API: &str = "https://webapi.qtfm.cn/api/pc/radio/";
/// 直播流前缀（**音频**，不是 m3u8）
const LIVE: &str = "https://lhttp-hw.qtfm.cn/live/";

/// 一页几条：DEX 用 `items.size() < 12` 判"没有下一页"，所以这个数字决定分页语义
pub const PAGE_SIZE: usize = 12;

const TIMEOUT: Duration = Duration::from_secs(20);

/// 分类表：DEX `homeContent` 里**两个等长数组按下标配对**
///
/// # 为什么不做成"从接口拉"
/// 蜻蜓FM 的 GraphQL 没有 `categories` 字段（DEX 里也没有这个查询），44 个 cid 是
/// **写死在类里的**。照抄即可。
///
/// # 实测覆盖（如实）
/// ```text
/// 436 → 曲艺 ✅（返回潮州/上海/安徽戏曲广播）
/// 3   → 北京 ✅（返回北京新闻广播）
/// 429 → 交通 ✅（返回北京交通广播）
/// 其余 41 项：**只做了下标配对**，没有逐项打请求验证（44 次请求的收益不成比例）。
/// 若某几项错位，表现为"点进去是别的方言区"，不是崩溃。
/// ```
pub const CATS: &[(&str, &str)] = &[
    ("436", "曲艺"),
    ("434", "方言"),
    ("217", "广东"),
    ("99", "浙江"),
    ("3", "北京"),
    ("5", "天津"),
    ("7", "河北"),
    ("83", "上海"),
    ("19", "山西"),
    ("31", "内蒙古"),
    ("44", "辽宁"),
    ("59", "吉林"),
    ("69", "黑龙江"),
    ("85", "江苏"),
    ("111", "安徽"),
    ("129", "福建"),
    ("139", "江西"),
    ("151", "山东"),
    ("169", "河南"),
    ("187", "湖北"),
    ("202", "湖南"),
    ("239", "广西"),
    ("254", "海南"),
    ("257", "重庆"),
    ("259", "四川"),
    ("281", "贵州"),
    ("291", "云南"),
    ("316", "陕西"),
    ("327", "甘肃"),
    ("351", "宁夏"),
    ("357", "新疆"),
    ("308", "西藏"),
    ("342", "青海"),
    ("433", "资讯"),
    ("442", "音乐"),
    ("429", "交通"),
    ("439", "经济"),
    ("432", "文艺"),
    ("441", "都市"),
    ("430", "体育"),
    ("431", "双语"),
    ("440", "综合"),
    ("438", "生活"),
    ("435", "旅游"),
];

pub struct QingtingFM {
    client: super::http_context::CspHttpContext,
}

impl QingtingFM {
    pub const CLASS: &'static str = "QingtingFM";

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

    /// GraphQL POST（home / search 共用）
    ///
    /// ★ 只发 `{"query": …}`：这个网关是 GraphQL，不是 REST。
    async fn graphql(&self, query: &str) -> Result<Value, String> {
        self.graphql_url(BFF, query).await
    }

    async fn graphql_url(&self, url: &str, query: &str) -> Result<Value, String> {
        let body = serde_json::json!({ "query": query }).to_string();
        let resp = self
            .client
            .client()?
            .post(url)
            .header(reqwest::header::REFERER, BASE)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*")
            .body(body)
            .send()
            .await
            .map_err(|e| format!("请求失败（{BFF}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{BFF}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{BFF}）：{}", head(&text)));
        }
        crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("{BFF} 不是 JSON：{e}（前 120 字：{}）", head(&text)))
    }

    async fn detail_url(&self, url: &str, rid: &str) -> Result<CspDetail, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header(reqwest::header::REFERER, BASE)
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
        detail_of(&v, rid)
    }
}

impl Default for QingtingFM {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（离线可测：拼 query / 解析响应）
// ═══════════════════════════════════════════════════════════════════════

/// 拼 `radioPage` 查询（DEX 里的换行/缩进逐字照抄）
pub fn radio_query(cid: &str, page: u32) -> String {
    format!("{{\n    radioPage(cid:{cid}, page:{page}){{\n      contents\n    }}\n  }}")
}

/// 拼 `searchResultsPage` 查询（DEX 逐字；`include:"channel_live"` 不能省）
pub fn search_query(kw: &str, page: u32) -> String {
    // 关键词里的 `"` 与 `\` 必须转义，否则 GraphQL 语法坏掉（这是"我打错"而不是"站点挂"）
    let kw = kw.replace('\\', "\\\\").replace('"', "\\\"");
    format!(
        "{{\n        searchResultsPage(keyword:\"{kw}\", page:{page}, include:\"channel_live\" ) {{\n          tdk,\n          searchData,\n          numFound\n        }}\n      }}"
    )
}

/// 封面：把上游给的地址补成可加载的绝对地址
///
/// # 为什么不是照抄 DEX 的 `contains("https")`
/// ```text
/// DEX 的 `categoryContent` 写的是 `if (!imgUrl.contains("https")) imgUrl = "https:" + imgUrl;`
/// 那条判断只对**列表**里的 `imgUrl`（实测恒为 `//pic.qtfm.cn/…`）安全；
/// 但**详情**里的 `cover` 实测是 `http://pic.qtfm.cn/…` —— 用 `contains("https")` 会把它
/// 拼成 `https:http://…`（明明是能加载的地址，被我们改坏）。
/// ⇒ 这里按"协议相对 / 已有 scheme / 裸串"三分支，语义等价、且对两种输入都不出错。
/// ```
pub fn cover_of(raw: &str) -> String {
    let s = raw.trim();
    if s.is_empty() {
        return String::new();
    }
    if s.starts_with("//") {
        return format!("https:{s}");
    }
    if s.starts_with("http://") || s.starts_with("https://") {
        return s.to_string();
    }
    // 裸串（无 scheme 也无 `//`）：按 DEX 的兜底补 `https:`
    format!("https:{s}")
}

/// `data.radioPage.contents.items[]` → CspItem
pub fn items_of(v: &Value) -> Vec<CspItem> {
    let arr = pick_arr(v, &["data", "radioPage", "contents", "items"]);
    arr.map(|a| a.iter().filter_map(item_of).collect())
        .unwrap_or_default()
}

/// `data.searchResultsPage.searchData[]` → CspItem
pub fn search_items_of(v: &Value) -> Vec<CspItem> {
    let arr = pick_arr(v, &["data", "searchResultsPage", "searchData"]);
    arr.map(|a| a.iter().filter_map(item_of).collect())
        .unwrap_or_default()
}

/// 一行 → CspItem（id + 标题是硬要求；没有就跳过，不编造）
fn item_of(v: &Value) -> Option<CspItem> {
    let id = pick_id_str(v, &["id"])?;
    let title = pick_str(v, &["title"]).unwrap_or("").trim().to_string();
    if title.is_empty() {
        return None;
    }
    let cover = pick_str(v, &["imgUrl"])
        .or_else(|| pick_str(v, &["cover"]))
        .map(cover_of)
        .filter(|s| !s.is_empty());
    let desc = pick_str(v, &["desc"])
        .or_else(|| pick_str(v, &["description"]))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    Some(CspItem {
        id,
        title,
        cover,
        subtitle: desc,
    })
}

/// 详情：`{album:{id,title,cover,description}}` → CspDetail（**1 条"集"**＝一条音频）
pub fn detail_of(v: &Value, id: &str) -> Result<CspDetail, String> {
    let album = v
        .get("album")
        .filter(|a| a.is_object())
        .ok_or_else(|| format!("详情里没有 album（id={id}，可能改版/风控壳页）"))?;
    let title = pick_str(album, &["title"]).unwrap_or("").trim().to_string();
    if title.is_empty() {
        return Err(format!("详情 album.title 为空（id={id}）"));
    }
    let audio_id = pick_id_str(album, &["id"]).unwrap_or_else(|| id.to_string());
    Ok(CspDetail {
        id: audio_id.clone(),
        title: title.clone(),
        cover: pick_str(album, &["cover"])
            .map(cover_of)
            .filter(|s| !s.is_empty()),
        description: pick_str(album, &["description"])
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        // ★ 音频站：一集＝一条音频流。标题就是电台名（DEX 里 vod_play_url 也是 `title$id`）
        episodes: vec![CspEpisode {
            id: audio_id,
            title,
            flag: "蜻蜓FM".to_string(),
        }],
    })
}

/// 取流地址（纯函数，可单独测）
pub fn live_url(id: &str) -> String {
    format!("{LIVE}{}/64k.mp3", id.trim())
}

// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for QingtingFM {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：**只给分类表**（DEX `homeContent` 返回 `{"class":[…],"filters":{}}`，不预取条目）
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let categories: Vec<CspCategory> = CATS
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        if categories.is_empty() {
            return Err("蜻蜓FM 分类表为空（内置常量被清空了？）".to_string());
        }
        Ok(CspHome {
            categories,
            items: Vec::new(),
        })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        // DEX 里 cateId 来自 `extend.get("cateId")`；本仓的 ext 是配置原文（可能为 null 文本）
        let cid = cate_of(ext).unwrap_or_else(|| tid.trim().to_string());
        if cid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let v = self.graphql(&radio_query(&cid, page)).await?;
        let items = items_of(&v);
        if items.is_empty() {
            if page > 1 {
                // 真的没有更多页（实测 cid=436 第 2 页就是 0 条）⇒ 不是缺陷
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total: None,
                });
            }
            return Err(format!(
                "分类 {cid} 第 1 页没解析出条目（可能模板改版/风控壳页）"
            ));
        }
        // DEX：`items.size() < 12 ⇒ 没有下一页`
        let page_count = if items.len() < PAGE_SIZE {
            Some(page)
        } else {
            Some(page + 1)
        };
        Ok(CspList {
            items,
            page,
            page_count,
            total: None,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let rid = id.trim();
        if rid.is_empty() {
            return Err("音频 id 为空".to_string());
        }
        let url = format!("{RADIO_API}{rid}");
        self.detail_url(&url, rid).await
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let v = self.graphql(&search_query(kw, page)).await?;
        let items = search_items_of(&v);
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
                "搜索「{kw}」没解析出条目（可能模板改版/风控壳页）"
            ));
        }
        let total = pick_str(&v, &["data", "searchResultsPage", "numFound"])
            .and_then(|s| s.trim().parse::<u64>().ok());
        Ok(CspList {
            items,
            page,
            page_count: Some(page + 1),
            total,
        })
    }

    fn supports_search(&self) -> bool {
        // ★ true 的理由：**真网实测**过 searchResultsPage 返回 5477 B / searchData[0].id=20500164
        true
    }

    /// 取流：直播 64k.mp3（DEX `playerContent` 逐字拼串）
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let raw = id.trim();
        if raw.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        // 有的源会把完整 URL 当 id 传进来 ⇒ 已经带 http 就原样用（不重复拼前缀）
        let url = if raw.starts_with("http") {
            raw.to_string()
        } else {
            live_url(raw)
        };
        Ok(vec![CspPlay {
            url,
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                ("Referer".to_string(), BASE.to_string()),
            ],
            label: Some("蜻蜓FM 直播 64k".to_string()),
        }])
    }
}

/// 从 ext 里取 `cateId`（DEX 读的就是这个键）；ext 为 null/空 ⇒ None
fn cate_of(ext: &str) -> Option<String> {
    let t = ext.trim();
    if t.is_empty() || t == "null" {
        return None;
    }
    let j = crate::tvbox::parse_loose_json(t).ok()?;
    pick_id_str(&j, &["cateId"]).filter(|s| !s.trim().is_empty())
}

// ══ 自注册 ══
//
// 三条判据同时成立（本批纪律）：
// ① 订阅里这 1 站 ② 有可用 host（4 个域名都是 DEX 常量，不需要 ext）
// ③ **真网真的取到数据**：home/list/detail/search/play 全部实测见文件头。
crate::csp::register_site!(QingtingFM);

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── ① 解析纯函数：用**真实响应片段**当 fixture（禁 mock 网络）──

    /// 实测片段（`POST /www radioPage(cid:436,page:1)` 的真实响应，2026-10-27）
    const REAL_RADIO: &str = r#"{"data":{"radioPage":{"contents":{"items":[
        {"id":4595,"imgUrl":"//pic.qtfm.cn/2015/0427/20150427150246450.jpg","title":"潮州戏曲广播","clout":3329,"playcount":142795},
        {"id":269,"imgUrl":"//pic.qtfm.cn/sso/48/1641437758835_67As1roa7.jpeg","title":"上海戏曲广播","clout":3213,"playcount":106895,"desc":"正在直播： 停机检修"}
    ]}}}}"#;

    /// 实测片段（`GET /api/pc/radio/4595` 的真实响应，已截断）
    const REAL_DETAIL: &str = r#"{"album":{"id":4595,"title":"潮州戏曲广播","cover":"http://pic.qtfm.cn/2015/0427/20150427150246450.jpg","description":"FM103.1兆赫的潮州人民广播电台戏曲之声正式开播于2004年10月1日。","cms_category_id":5,"content_type":"channel","channel_type":1,"audience_count":142795}}"#;

    /// 实测片段（`searchResultsPage` 的真实响应，已截断）
    const REAL_SEARCH: &str = r#"{"data":{"searchResultsPage":{"tdk":{"title":"相声电台"},"searchData":[
        {"id":20500164,"id_str":"20500164","title":"泊头人民广播电台","type":"channel_live","cover":"http://pic.qtfm.cn/x.jpg"},
        {"id":20500165,"title":"沧州新闻广播","type":"channel_live","cover":"http://pic.qtfm.cn/y.jpg"}
    ],"numFound":"2"}}}"#;

    #[test]
    fn real_radio_page_parses() {
        let v = crate::tvbox::parse_loose_json(REAL_RADIO).expect("真实响应必须是合法 JSON");
        let items = items_of(&v);
        assert_eq!(items.len(), 2, "真实片段里就是 2 条");
        assert_eq!(items[0].id, "4595");
        assert_eq!(items[0].title, "潮州戏曲广播");
        // ★ `//pic.qtfm.cn/…` 必须补成 `https://…`（DEX 里就是这段逻辑）
        assert_eq!(
            items[0].cover.as_deref(),
            Some("https://pic.qtfm.cn/2015/0427/20150427150246450.jpg")
        );
        assert!(items[0].subtitle.is_none(), "没有 desc 就没有副标题（不编造）");
        assert_eq!(items[1].subtitle.as_deref(), Some("正在直播： 停机检修"));
    }

    #[test]
    fn real_search_page_parses() {
        let v = crate::tvbox::parse_loose_json(REAL_SEARCH).expect("真实响应必须是合法 JSON");
        let items = search_items_of(&v);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "20500164");
        assert_eq!(items[0].title, "泊头人民广播电台");
        assert_eq!(
            pick_str(&v, &["data", "searchResultsPage", "numFound"]),
            Some("2")
        );
    }

    #[test]
    fn real_detail_parses_to_exactly_one_audio_episode() {
        let v = crate::tvbox::parse_loose_json(REAL_DETAIL).expect("真实响应必须是合法 JSON");
        let d = detail_of(&v, "4595").expect("真实详情必须能解析");
        assert_eq!(d.title, "潮州戏曲广播");
        assert!(d.description.as_deref().unwrap_or("").contains("潮州"));
        assert_eq!(d.episodes.len(), 1, "★ 音频站：一集＝一条音频，不做多集");
        assert_eq!(d.episodes[0].id, "4595");
        assert_eq!(d.episodes[0].flag, "蜻蜓FM");
        assert_eq!(
            live_url(&d.episodes[0].id),
            "https://lhttp-hw.qtfm.cn/live/4595/64k.mp3"
        );
    }

    // ── ② 空/坏 ⇒ 必须 Err（不许伪装成"这个源没内容"）──

    #[test]
    fn empty_or_missing_items_yield_nothing() {
        let empty = json!({"data":{"radioPage":{"contents":{"items":[]}}}});
        assert!(items_of(&empty).is_empty());
        // 连结构都没有（改版/壳页）⇒ 也是"解析不出东西"，交给上层报 Err
        assert!(items_of(&json!({})).is_empty());
        assert!(items_of(&json!({"data":{"radioPage":null}})).is_empty());
    }

    #[test]
    fn detail_without_album_is_error() {
        let e = detail_of(&json!({"data":{}}), "1").expect_err("没有 album 必须 Err");
        assert!(e.contains("album"), "{e}");
        let e2 = detail_of(&json!({"album":{"id":1}}), "1").expect_err("标题空必须 Err");
        assert!(e2.contains("title"), "{e2}");
    }

    #[test]
    fn query_strings_keep_the_dex_shape() {
        assert_eq!(
            radio_query("436", 1),
            "{\n    radioPage(cid:436, page:1){\n      contents\n    }\n  }"
        );
        let q = search_query("相声", 2);
        assert!(q.contains("searchResultsPage(keyword:\"相声\", page:2"), "{q}");
        assert!(q.contains("include:\"channel_live\""), "include 不能省：{q}");
        // 关键词里的引号必须转义，否则 GraphQL 语法坏掉（那是"我打错"，不是站点挂）
        assert!(search_query("a\"b", 1).contains("keyword:\"a\\\"b\""));
    }

    #[test]
    fn categories_are_44_and_the_three_verified_ones_are_right() {
        assert_eq!(CATS.len(), 44, "DEX 里两个数组都是 44 项");
        let get = |id: &str| CATS.iter().find(|(i, _)| *i == id).map(|(_, n)| *n);
        // 三项**真网实测**对上（见文件头读数）
        assert_eq!(get("436"), Some("曲艺"));
        assert_eq!(get("3"), Some("北京"));
        assert_eq!(get("429"), Some("交通"));
        // id 不重复（重复会让 UI 出现两个同名分类）
        let mut ids: Vec<&str> = CATS.iter().map(|(i, _)| *i).collect();
        ids.sort_unstable();
        let n = ids.len();
        ids.dedup();
        assert_eq!(ids.len(), n, "分类 id 有重复");
    }

    #[test]
    fn cover_prefix_is_added_only_when_missing() {
        assert_eq!(cover_of("//pic.qtfm.cn/a.jpg"), "https://pic.qtfm.cn/a.jpg");
        assert_eq!(cover_of("http://pic.qtfm.cn/a.jpg"), "http://pic.qtfm.cn/a.jpg");
        assert_eq!(cover_of("https://pic.qtfm.cn/a.jpg"), "https://pic.qtfm.cn/a.jpg");
        assert_eq!(cover_of("  "), "");
    }

    // ── ③ 注册项存在（问**运行时**注册表，不是读源码里有没有那行）──

    #[test]
    fn class_name_is_exact() {
        assert_eq!(QingtingFM::CLASS, "QingtingFM");
    }

    #[test]
    fn registered_in_runtime_registry() {
        assert!(
            crate::csp::is_implemented("csp_QingtingFM"),
            "★ 三条判据都成立 ⇒ 必须真的在注册表里（问运行时，不读源码）"
        );
        assert_eq!(
            crate::csp::route("csp_QingtingFM").map(|s| s.class()),
            Some("QingtingFM")
        );
    }

    #[tokio::test]
    async fn empty_id_is_rejected_before_any_request() {
        let s = QingtingFM::new();
        assert!(s.detail("  ", "").await.is_err());
        assert!(s.play("", " ", "").await.is_err());
        assert!(s.search("  ", 1, "").await.is_err());
        assert!(s.list("", 1, "").await.is_err());
    }

    #[tokio::test]
    async fn home_returns_44_categories_without_network() {
        let s = QingtingFM::new();
        let h = s.home("").await.expect("分类表是内置常量，不该失败");
        assert_eq!(h.categories.len(), 44);
        assert!(h.items.is_empty(), "DEX 的 homeContent 不预取条目");
    }

    // ── ④ 真网络（`#[ignore]`，**走 Rust 代码**再取一遍数：判据是"我们的实现能不能拿到数据"）──

    /// ★ 真网络用例：**不给 `CSP_LIVE=1` 就 assert 失败** —— 不做"没变量就 return"的假绿。
    ///
    /// 跑法：
    /// ```text
    /// CSP_LIVE=1 cargo test --lib csp::qingting_fm::tests::live_qingting -- --ignored --nocapture
    /// ```
    /// 它同时是"直连"的**行为证据**：client 构造链带 `.no_proxy()`，本机有系统代理时也能通。
    #[tokio::test]
    #[ignore]
    async fn live_qingting_fm_4_segments() {
        assert!(
            std::env::var("CSP_LIVE").ok().as_deref() == Some("1"),
            "★ 这是真网络用例：必须显式给 CSP_LIVE=1（不给就红，别让空跑变假绿）"
        );
        let s = QingtingFM::new();

        // ① 列表：436=曲艺（实测返回潮州/上海戏曲广播）
        let l = s.list("436", 1, "").await.expect("live list(436) 必须成功");
        println!(
            "QingtingFM.list(cid=436,page=1) → {} 条 · items[0]={{id:{},title:{}}}",
            l.items.len(),
            l.items[0].id,
            l.items[0].title
        );
        assert!(!l.items.is_empty());
        assert_eq!(l.items[0].id, "4595", "实测首条就是潮州戏曲广播(id=4595)");
        assert!(l.items[0]
            .cover
            .as_deref()
            .unwrap_or("")
            .starts_with("https://"));

        // ② 详情：一条音频＝一集
        let d = s.detail("4595", "").await.expect("live detail(4595) 必须成功");
        println!(
            "QingtingFM.detail(4595) → title={} · episodes={} · 集[0].id={}",
            d.title,
            d.episodes.len(),
            d.episodes[0].id
        );
        assert_eq!(d.episodes.len(), 1, "★ 音频站：一集就是一条音频");
        assert_eq!(d.episodes[0].id, "4595");

        // ③ 搜索
        let r = s.search("相声", 1, "").await.expect("live search 必须成功");
        println!(
            "QingtingFM.search(相声) → {} 条 · items[0]={{id:{},title:{}}}",
            r.items.len(),
            r.items[0].id,
            r.items[0].title
        );
        assert!(!r.items.is_empty());

        // ④ 取流：真音频流（只取前 1KB，不把 64k mp3 整段拉下来）
        //
        // ★ 为什么**不能只测一个台**（本批实测撞到三次，形态每次都不一样）：
        //   · 这个 CDN **不支持 HEAD**（HEAD → 400 text/html）⇒ 必须 GET + Range；
        //   · 单个台的 64k 流**会变**：id=4595 在 00:07 是 200 audio/mpeg，00:58 变 404 text/html；
        //   · **单次请求也会超时**：10:1x 复跑时 4595 直接 `TimedOut`（同一 URL 稍后又 200）。
        //   ⇒ 判据写成"前 5 个台里**至少一个**真出音频"，并**逐个打印**每台读数（含超时）。
        //   ⚠️ 早先这里写的是 `.expect("live GET 必须成功")` ⇒ 一次网络抖动就让整条 live 变红，
        //      而它红的信息量是"网抖了"，不是"实现坏了"。已改成把每台的失败**记下来继续**。
        let probe = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(12))
            .no_proxy()
            .build()
            .expect("build live probe client");
        let mut ok_ids: Vec<String> = Vec::new();
        let mut bad: Vec<String> = Vec::new();
        for it in l.items.iter().take(5) {
            let plays = s.play("蜻蜓FM", &it.id, "").await.expect("play 必须给地址");
            let resp = probe
                .get(&plays[0].url)
                .header(reqwest::header::USER_AGENT, UA)
                .header(reqwest::header::RANGE, "bytes=0-1023")
                .send()
                .await;
            let mut resp = match resp {
                Ok(r) => r,
                Err(e) => {
                    println!("QingtingFM.play GET(Range) id={} → ERR {e}", it.id);
                    bad.push(it.id.clone());
                    continue;
                }
            };
            let status = resp.status();
            let ct = resp
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let is_audio = ct.contains("audio") || ct.contains("mpeg");
            println!(
                "QingtingFM.play GET(Range) id={} → {} · content-type={}",
                it.id, status, ct
            );
            if status.is_success() && is_audio {
                // 读前 8 字节：MP3 帧同步头足以证明"这是音频流，不是 HTML 壳页"
                let mut first = [0u8; 8];
                let mut got = 0usize;
                while got < first.len() {
                    match resp.chunk().await {
                        Ok(Some(chunk)) => {
                            let take = (first.len() - got).min(chunk.len());
                            first[got..got + take].copy_from_slice(&chunk[..take]);
                            got += take;
                        }
                        Ok(None) => break,
                        Err(e) => {
                            println!("    ↳ 读流中断：{e}");
                            break;
                        }
                    }
                }
                println!("    ↳ 首{}字节 = {:02x?}（音频帧）", got, &first[..got]);
                assert!(got > 0, "audio 响应必须真的带字节（空体 = 壳页）");
                ok_ids.push(it.id.clone());
            } else {
                bad.push(it.id.clone());
            }
        }
        println!("QingtingFM 取流：可用={ok_ids:?} 未给音频={bad:?}（各取前 5 个里的）");
        assert!(
            !ok_ids.is_empty(),
            "★ 前 5 个台里一个音频流都拿不到（bad={bad:?}）⇒ 取流链路有问题（不是单台停播）"
        );
    }
}

// Replaces the old builder-source assertion with actual direct/proxy requests
// through both GraphQL and detail helpers.
#[cfg(test)]
#[path = "qingting_fm_proxy_tests.rs"]
mod proxy_tests;
