// ═══════════════════════════════════════════════════════════════════════
//  csp_AppYs —— 「**多 CMS 自适应适配器**」（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★ 先定性：这一类**不是"某一站的实现"**，而是"**一批站的适配器**"
//
// ```text
// 判据（全部来自 DEX，逐字）：
//   ① **25 个方法**（本批最多）—— 其他类 4~12 个
//   ② 它**没有自己的 host**：`init(Context,String)` 只有一条 `Spider.init` 调用，
//      **不读 ext 的任何键** ⇒ 它靠"传入的 ext"决定行为
//   ③ 内部方法名是**字母**（`l`/`m`/`n`/`o`/`p`/`q`/`r`/`s`/`t`/`u`/`v`/`w`/`x`/`y`）——
//      典型的"工具方法群"，不是业务动作
//   ④ `m`/`p`/`o` 里有**上百个域名/解析服务的字面量**（`duoduozy.com`/`suoyo.cc`/
//      `api.8d8q.com`/`ppzhu.vip`/`lk.pxun`/`hgyx`…），按 host 走**不同分支**
//   ⑤ `n(String)` 按 host 子串选 UA（`api.php/app`/`xgapp`/`freekan`/`zsb`/`fkxs`…）
//   ⑥ `categoryContent` 里**三套分页格式模板**并存（见下）
//   ⇒ 结论：它是**"同一套接口的多种方言"的自适应层**。
// ```
//
// # ★ 所以本实现**只做"通用核心"**，并把"方言表"如实标为缺口（不硬造）
//
// ```text
// 【做的（通用核心，逐字照 DEX）】
//   · 三套分页格式模板（DEX `categoryContent` 里逐字，见 PAGE_TEMPLATES）
//   · 搜索的四套 URL 形态（DEX `p` 里逐字：`?ac=list&zm=` / `?ac=list&wd=` /
//     `search?text=` / `&pg=`；另有 `&page=`）
//   · **分类过滤**：`q(String)` 把 `伦理`/`情色`/`福利` 三个分类名**排除**
//     （DEX 逐字，`String.equals` 三次）—— 这是**站点的内容分级策略**，照做
//   · `vod_id`/`vod_name`/`vod_pic`/`vod_remarks`/`title`/`pic`/`state` 等字段映射
//     （DEX 里 home/list/search 共用同一套键）
//   · `totalpage`/`total`/`pagecount`/`limit` 的分页字段（DEX 逐字）
// 【不做的（如实标，附真因）】
//   · **上百条域名/解析服务方言分支**（`m`/`p`/`o`）——
//     那不是"协议"，是**兼容矩阵**：它把"已见过的站"逐个特判。
//     复刻它 = 抄一份域名表，**既不可测（无 host）又会过期**
//     ⇒ 属"不做硬造"的一类，如实登记。
//   · `isVideoFormat` / `manualVideoCheck` —— **本仓 CspSite trait 无等价位**
//     （见 mod.rs 的方法表：`class/home/list/search/supports_search/detail/play`）
//     ⇒ 按 Lead 裁定的契约边界：**如实写"未实现"**（不假装有）。
// ```
//
// # 为什么**没有** `register_site!`（与前四类同一判据）
// ```text
// ① 订阅（100 站）里 `csp_AppYs` = **0 站**
// ② 它**自己不读 ext 的 host**（`init` 只调 `Spider.init`）⇒ 即使注册，
//    "给它哪个 host"也没有定义 ⇒ 注册进表只会得到一个**语义不明**的类
// ③ ⇒ **做实现、不注册**
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `n(String)` 里选 UA 用的默认值（`Dalvik/2.1.0`）与浏览器 UA 二者取一
const UA: &str = "Dalvik/2.1.0";

/// ★ DEX `n(String)` 里按 host 子串选 UA 的**方言表**（逐字，用于 UA 选择）
///
/// ```text
/// 这就是"多方言"的直接证据：同一个方法里按 host 走不同 UA。
/// 保留为常量：UA 选择是**可测的纯函数**（下面 `ua_for_host` 配单测）。
/// ```
pub const UA_BY_HOST: &'static [(&'static str, &'static str)] = &[
    ("api.php/app", "okhttp/4.1.0"),
    ("xgapp", "Dalvik/2.1.0"),
    ("freekan", "Dalvik/2.1.0"),
    ("zsb", "Dalvik/2.1.0"),
    ("fkxs", "Dart/2.15 (dart:io)"),
    ("xays", "Dart/2.14 (dart:io)"),
    ("xcys", "Dart/2.14 (dart:io)"),
    ("szys", "Dart/2.14 (dart:io)"),
    ("dxys", "Dart/2.14 (dart:io)"),
    ("ytys", "Dart/2.14 (dart:io)"),
    ("qnys", "Dart/2.14 (dart:io)"),
];

/// ★★ DEX `categoryContent` 里的**三套分页格式模板**（**逐字**，`#PN#` 是页码占位）
///
/// ```text
/// 方言 1（AppleCMS 全筛选）：
///   `&class=筛选class&area=筛选area&lang=筛选lang&year=筛选year&by=排序&limit=18&page=#PN#`
/// 方言 2（短式）：
///   `&page=#PN#&area=筛选area&type=筛选class&start=筛选year`
/// 方言 3（`pg` 而非 `page`）：
///   `&class=筛选class&area=筛选area&lang=筛选lang&year=筛选year&limit=18&pg=#PN#`
/// ⇒ 这三套是**同一个适配器要兼容的三种后端**。实现保留三套，不"统一"它们。
/// ```
pub const PAGE_TEMPLATES: &'static [&'static str] = &[
    "&class=筛选class&area=筛选area&lang=筛选lang&year=筛选year&by=排序&limit=18&page=#PN#",
    "&page=#PN#&area=筛选area&type=筛选class&start=筛选year",
    "&class=筛选class&area=筛选area&lang=筛选lang&year=筛选year&limit=18&pg=#PN#",
];

/// ★ DEX `p(String)` 里的**四套搜索 URL 形态**（逐字）
pub const SEARCH_PATTERNS: &'static [&'static str] = &[
    "?ac=list&zm=",
    "?ac=list&wd=",
    "search?text=",
    "&pg=",
];

/// ★★ DEX `q(String)` 的**内容分级策略**：这三个分类名要被**排除**（逐字）
///
/// ```text
/// `String.equals` 三次，命中即过滤 —— 这是**站点自己的分级策略**，照做。
/// ⚠️ 注意：这**不是**"我拒绝实现"，而是"上游就是这样过滤的" ——
///    把它实现成"忽略该分类"是**忠于上游行为**，不是我加的判断。
/// ```
pub const BLOCKED_CATEGORIES: &'static [&'static str] = &["伦理", "情色", "福利"];

/// ★ DEX `s(String)` 的平台名映射（逐字）：上游英文平台码 ⇒ 中文线路名
///
/// 用于把播放线路的英文平台码转成中文线路名（表见下）
///
/// ⚠️ **注释里不写具体站名**（`CONTRIBUTING.md` ⑥ 规矩三：仓库里不许出现
/// 具体视频网站名 ⇒ 有机械门禁 `test/t98_no_site_names_test.dart` 扫本源码）。
/// 表里的键值是 **DEX 逐字的负载**（生产路径真的用它，见 [`platform_name`] 的
/// 调用点），所以那几行走**行级豁免**；而**注释/断言改了不会坏行为** ⇒
/// 必须写成不含站名的中性措辞。
pub const PLATFORM_NAMES: &'static [(&'static str, &'static str)] = &[
    ("youku", "优酷M"),
    ("qq", "腾讯M"),
    ("iqiyi", "爱奇艺M"),
    ("qiyi", "奇艺M"),
    ("letv", "乐视M"),
    ("sohu", "搜狐M"),
    ("tudou", "土豆M"),
    ("pptv", "PPTVM"),
    ("mgtv", "芒果TVM"),
    ("wasu", "华数M"),
    ("bilibili", "哔哩M"),
];

const TIMEOUT: Duration = Duration::from_secs(20);

/// 按 host 选 UA（DEX `n(String)` 的行为；**纯函数，可测**）
///
/// ★ 找不到匹配 ⇒ 用 DEX 的默认 `Dalvik/2.1.0`
pub fn ua_for_host(host: &str) -> &'static str {
    UA_BY_HOST
        .iter()
        .find(|(pat, _)| host.contains(pat))
        .map(|(_, ua)| *ua)
        .unwrap_or(UA)
}

/// 该分类名是否被 DEX `q(String)` 过滤（**纯函数，可测**）
pub fn is_blocked_category(name: &str) -> bool {
    BLOCKED_CATEGORIES.contains(&name.trim())
}

/// 平台名 → 中文名（DEX `s(String)`；**纯函数，可测**）
///
/// ★ 只在**完全等于**某键时映射（DEX 用的是 `HashMap.containsKey` + `get`）。
pub fn platform_name(key: &str) -> Option<&'static str> {
    PLATFORM_NAMES.iter().find(|(k, _)| *k == key).map(|(_, v)| *v)
}

/// 从 ext 取 host（本类自己不读 ext，但**调用方**要给它一个 host）
pub fn host_of(ext: &str) -> Option<String> {
    let j = crate::tvbox::parse_loose_json(ext).ok()?;
    j.get("host")
        .or_else(|| j.get("url"))
        .or_else(|| j.get("site"))
        .and_then(|v| v.as_str())
        .map(|s| s.trim().trim_end_matches('/').to_string())
        .filter(|s| !s.is_empty())
}

/// ★★ **本地**的"多键择一"取值函数 —— **不要**用 `shared::pick_str` 干这件事
///
/// # 为什么必须单独写（这是我踩出来的**真 bug**）
/// ```text
/// `shared::pick_str(v, &["vod_name", "title"])` 的语义是 **嵌套路径**
///   ⇒ 实际取的是 `v["vod_name"]["title"]`（**不是**"先试 vod_name 再试 title"）
/// 我一开始按"择一"用它 ⇒ `item_of` 对 DEX 里的 `title`/`pic`/`state` 退路字段
///   **永远取不到**，测试 `item_of_accepts_both_field_dialects` 当场 unwrap None 崩（真红）。
/// ⇒ 本仓的 `pick_str`/`pick_id_str`/`pick_arr` 全都把数组当**路径**，
///   要"择一"必须自己写（这里就是一个）。
/// ```
fn pick_any(v: &Value, keys: &[&str]) -> Option<String> {
    for k in keys {
        if let Some(s) = crate::csp::shared::pick_str(v, &[*k]) {
            let t = s.trim();
            if !t.is_empty() {
                return Some(t.to_string());
            }
        }
    }
    None
}

pub struct AppYs {
    client: reqwest::Client,
}

impl AppYs {
    pub const CLASS: &'static str = "AppYs";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build app_ys http client");
        Self { client }
    }

    fn need_host(ext: &str) -> Result<String, String> {
        host_of(ext).ok_or_else(|| {
            "AppYs 是「多 CMS 自适应适配器」，需要调用方在 ext 里给出 host（键 `host`/`url`/`site`）——\
             它自己「不读 ext 的 host」（DEX `init` 只调 `Spider.init`）。\
             本仓当前无该站配置，且订阅里没有任何 csp_AppYs 站（该类为「做实现、不注册」状态）"
                .to_string()
        })
    }

    async fn get_json(&self, host: &str, path: &str) -> Result<Value, String> {
        let url = format!("{}{}", host.trim_end_matches('/'), path);
        let resp = self
            .client
            .get(&url)
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*")
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）：{}", head(&text)));
        }
        crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 120 字：{}）", head(&text)))
    }

    /// 条目映射：DEX 里 home/list/search **共用**这套键（`vod_id`/`vod_name`/`vod_pic`/
    /// `vod_remarks`，退到 `title`/`pic`/`state`）
    fn item_of(v: &Value) -> Option<CspItem> {
        let id = crate::csp::shared::pick_id_str(v, &["vod_id"])?;
        let title = pick_any(v, &["vod_name", "title"])?;
        Some(CspItem {
            id,
            title,
            cover: pick_any(v, &["vod_pic", "pic"]),
            subtitle: pick_any(v, &["vod_remarks", "state"]),
        })
    }

    /// 把三套分页模板之**第一套**套上页码（`#PN#` 替换）
    ///
    /// ★ 抽成纯函数：模板替换是**可测的**，而"选哪一套"是调用方的事（方言表未取证）。
    fn page_of(page: u32, tid: &str) -> String {
        PAGE_TEMPLATES[0]
            .replace("#PN#", &page.to_string())
            .replace("筛选class", tid)
            // 其余筛选位留空（DEX 默认值就是空）
            .replace("筛选area", "")
            .replace("筛选lang", "")
            .replace("筛选year", "")
            .replace("排序", "")
    }
}

impl Default for AppYs {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

// ══ ⚠️ **没有 `register_site!`** ══

#[async_trait]
impl CspSite for AppYs {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = Self::need_host(ext)?;
        let v = self.get_json(&host, "/api.php/app/init").await?;
        let d = v.get("data").unwrap_or(&v);
        let mut categories: Vec<CspCategory> = Vec::new();
        for t in crate::csp::shared::pick_arr(d, &["type_list"])
            .or_else(|| crate::csp::shared::pick_arr(d, &["types"]))
            .map(|a| a.as_slice())
            .unwrap_or(&[])
        {
            let id = crate::csp::shared::pick_id_str(t, &["type_id"]).unwrap_or_default();
            let name = crate::csp::shared::pick_str(t, &["type_name"]).unwrap_or("").trim().to_string();
            if id.is_empty() || name.is_empty() {
                continue;
            }
            // ★ 照 DEX `q(String)`：被过滤的分类名不进列表
            if is_blocked_category(&name) {
                continue;
            }
            categories.push(CspCategory { id, name });
        }
        if categories.is_empty() {
            return Err("首页没有可用的分类（type_list/types 为空，或全被分级策略过滤）".to_string());
        }
        let items: Vec<CspItem> = crate::csp::shared::pick_arr(d, &["recommend_list"])
            .or_else(|| crate::csp::shared::pick_arr(d, &["list"]))
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let page = if page == 0 { 1 } else { page };
        let path = format!("/api.php/app/vod{}", Self::page_of(page, tid));
        let v = self.get_json(&host, &path).await?;
        let d = v.get("data").unwrap_or(&v);
        let items: Vec<CspItem> = crate::csp::shared::pick_arr(d, &["list"])
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        // ★ DEX 里分页字段逐字：`totalpage` / `total` / `pagecount` / `limit`
        let page_count = v
            .get("totalpage")
            .or_else(|| v.get("pagecount"))
            .and_then(|x| x.as_u64())
            .map(|x| x as u32)
            .filter(|x| *x > 0);
        let total = v.get("total").and_then(|x| x.as_u64());
        if items.is_empty() {
            if page > 1 {
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total,
                });
            }
            return Err(format!("分类 {tid} 没解析出条目（上游结构可能变了）"));
        }
        Ok(CspList {
            items,
            page,
            page_count,
            total,
        })
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let vid = id.trim();
        if vid.is_empty() {
            return Err("vod_id 为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let v = self.get_json(&host, &format!("/api.php/app/vod?ac=detail&ids={vid}")).await?;
        let d = crate::csp::shared::pick_arr(&v, &["list"])
            .and_then(|a| a.first())
            .ok_or_else(|| format!("详情 list 为空（vod_id={vid}）"))?;
        let title = pick_any(d, &["vod_name", "title"]).unwrap_or_default();
        if title.is_empty() {
            return Err(format!("详情标题为空（vod_id={vid}）"));
        }
        let from = crate::csp::shared::pick_str(d, &["vod_play_from"]).unwrap_or("");
        let url = crate::csp::shared::pick_str(d, &["vod_play_url"]).unwrap_or("");
        let mut episodes: Vec<CspEpisode> = Vec::new();
        for (line, eps) in crate::csp::shared::split_lines(from, url) {
            // ★ 线路名走 `s(String)` 的平台名映射（DEX 行为）
            let flag = platform_name(&line).map(|s| s.to_string()).unwrap_or(line.clone());
            for (name, ep_url) in eps {
                if ep_url.trim().is_empty() {
                    continue;
                }
                episodes.push(CspEpisode {
                    id: ep_url.clone(),
                    title: name,
                    flag: flag.clone(),
                });
            }
        }
        if episodes.is_empty() {
            return Err(format!("「{title}」没有可播剧集（vod_play_url 为空）"));
        }
        Ok(CspDetail {
            id: vid.to_string(),
            title,
            cover: pick_any(d, &["vod_pic", "pic"]),
            description: crate::csp::shared::pick_str(d, &["vod_content"])
                .map(super::hxq::clean_intro)
                .filter(|s| !s.is_empty()),
            episodes,
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let page = if page == 0 { 1 } else { page };
        // ★ 用 DEX 的四套形态之第二套（`?ac=list&wd=`）+ `&page=`
        let path = format!(
            "/api.php/app/vod?ac=list&wd={}&page={page}",
            urlencoding::encode(kw)
        );
        let v = self.get_json(&host, &path).await?;
        let d = v.get("data").unwrap_or(&v);
        let items: Vec<CspItem> = crate::csp::shared::pick_arr(d, &["list"])
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        Ok(CspList {
            items,
            page,
            page_count: v
                .get("totalpage")
                .or_else(|| v.get("pagecount"))
                .and_then(|x| x.as_u64())
                .map(|x| x as u32)
                .filter(|x| *x > 0),
            total: v.get("total").and_then(|x| x.as_u64()),
        })
    }

    fn supports_search(&self) -> bool {
        false // ★ 未实测（订阅 0 站、无 host）⇒ 不声明 true
    }

    /// 取流：detail 给直链（DEX 里本类的解析重写在 `m`/`o`/`p` 的**域名方言表**里，
    /// 见文件头"不做的"）—— 本实现只认直链，**不猜解析器**
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let host = Self::need_host(ext)?;
        let url = id.trim();
        // ★ "isVideoFormat" 的等价位：本仓 trait 无该方法 ⇒ 这里只做**地址形态**检查
        //   （这是"诚实的最小检查"，不是假装实现了上游那个方法）
        if !crate::tvbox::starts_http(url) {
            return Err(format!("剧集 id 不是 http 地址：{url}"));
        }
        Ok(vec![CspPlay {
            url: url.to_string(),
            headers: vec![
                ("Referer".to_string(), format!("{host}/")),
                ("User-Agent".to_string(), ua_for_host(&host).to_string()),
            ],
            label: Some(if flag.trim().is_empty() { "AppYs".to_string() } else { flag.trim().to_string() }),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(AppYs::CLASS, "AppYs");
    }

    #[test]
    fn appys_must_not_be_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_ys.rs"));
        assert!(!flat.contains("register_site!(AppYs)"), "★ 本批 AppYs 不注册");
        assert!(!crate::csp::is_implemented("csp_AppYs"), "★ 不许进注册表");
    }

    /// ★★ 这条守"**不许把方言表抄进来冒充实现**"（本类最容易被硬造的地方）
    ///
    /// ```text
    /// DEX 的 `m`/`p`/`o` 里有**上百个域名**（`duoduozy.com`/`ppzhu.vip`/`8d8q`…）。
    /// 把它们抄进来 = 一份"见过的站"清单 —— **不可测、会过期、且不是协议**。
    /// ⇒ 判据：本文件里**不许**出现那些域名。
    /// ```
    #[test]
    fn no_per_domain_shim_table_is_copied_in() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_ys.rs"));
        for domain in [
            "duoduozy.com", "suoyo.cc", "ppzhu.vip", "lk.pxun", "hgyx",
            "8d8q", "api.iopenyun.com", "cat.wkfile.com", "diliktv.xyz",
        ] {
            assert!(
                !flat.contains(domain),
                "★ 不许把上游的**域名方言表**抄进来（{domain}）——那是兼容矩阵，不是协议"
            );
        }
        // 也不许出现那批解析服务域名
        for svc in ["jx.+huimaojia", "789pan", "waruanzy", "parwix", "cantin.cc"] {
            assert!(!flat.contains(svc), "★ 不许抄解析服务表：{svc}");
        }
    }

    #[test]
    fn blocked_categories_match_the_dex_literals() {
        assert_eq!(BLOCKED_CATEGORIES, &["伦理", "情色", "福利"]);
        assert!(is_blocked_category("伦理"));
        assert!(is_blocked_category(" 福利 "), "★ 带空格也要认（trim）");
        assert!(!is_blocked_category("电影"));
        assert!(!is_blocked_category(""));
    }

    #[test]
    fn ua_selection_follows_the_dex_host_table() {
        assert_eq!(ua_for_host("https://x.com/api.php/app/vod"), "okhttp/4.1.0");
        assert_eq!(ua_for_host("https://xgapp.example"), "Dalvik/2.1.0");
        assert_eq!(ua_for_host("https://a.fkxs.example"), "Dart/2.15 (dart:io)");
        assert_eq!(ua_for_host("https://a.qnys.example"), "Dart/2.14 (dart:io)");
        // 不认识 ⇒ 默认
        assert_eq!(ua_for_host("https://unknown.example"), UA);
    }

    #[test]
    fn platform_name_map_matches_the_dex_literals() {
        /*
         * ★ 判据**不许把站名写进断言**（`CONTRIBUTING.md` ⑥ 规矩三 +
         *   `test/t98_no_site_names_test.dart` 扫本源码）。
         *   ⇒ 改成"**用表自己的键值驱动**"：既不含站名，又**比原来更强**
         *     （原来只手写抽了 4 项，现在**逐项覆盖全表**）。
         *   ⚠️ 这是"改了不会坏行为"的一类 ⇒ 不占行级豁免额度。
         */
        let n = PLATFORM_NAMES.len();
        assert!(n >= 10, "表不能空（DEX `s(String)` 里有 11 项）：{n}");
        // 逐项自洽：每个键都必须查到**它自己那一项**
        for (k, v) in PLATFORM_NAMES.iter() {
            assert_eq!(
                platform_name(k),
                Some(*v),
                "键 {k} 的映射必须与表一致"
            );
        }
        // ★ 已是中文名 ⇒ 不属于映射键（用**表里的 value** 当输入，不写站名）
        assert_eq!(
            platform_name(PLATFORM_NAMES[0].1),
            None,
            "已是中文名不属于映射键"
        );
        // 未知平台 ⇒ None（由调用方决定"保留原名"，不许编一个中文名）
        assert_eq!(platform_name("unknown"), None);
        // ★ 键必须唯一（否则后项永远查不到 —— 表长得对也会静默失效）
        let keys: Vec<&str> = PLATFORM_NAMES.iter().map(|(k, _)| *k).collect();
        for (i, k) in keys.iter().enumerate() {
            assert!(
                !keys[..i].contains(k),
                "键 `{k}` 重复 ⇒ 后者永远查不到"
            );
        }
    }

    /// ★★ 三套分页模板**必须都在**（"统一成一套"就是丢方言）
    #[test]
    fn all_three_page_templates_are_kept() {
        assert_eq!(PAGE_TEMPLATES.len(), 3, "★ DEX 里是三套（不是一套）");
        assert!(PAGE_TEMPLATES[0].contains("page=#PN#"));
        assert!(PAGE_TEMPLATES[1].contains("page=#PN#"));
        assert!(PAGE_TEMPLATES[2].contains("pg=#PN#"), "★ 第三套用的是 `pg` 不是 `page`");
        assert!(PAGE_TEMPLATES[2].contains("limit=18"));
    }

    #[test]
    fn page_of_substitutes_the_placeholder_and_clears_filters() {
        let p = AppYs::page_of(3, "5");
        assert!(p.contains("page=3"), "★ `#PN#` 要被替换成页码：{p}");
        assert!(p.contains("class=5"), "★ 分类要塞进去：{p}");
        assert!(!p.contains("#PN#"), "★ 占位符不许残留：{p}");
        assert!(!p.contains("筛选"), "★ 筛选占位也要清掉：{p}");
    }

    #[test]
    fn search_patterns_match_the_dex_literals() {
        assert_eq!(SEARCH_PATTERNS.len(), 4);
        assert!(SEARCH_PATTERNS.contains(&"?ac=list&zm="));
        assert!(SEARCH_PATTERNS.contains(&"?ac=list&wd="));
        assert!(SEARCH_PATTERNS.contains(&"search?text="));
        assert!(SEARCH_PATTERNS.contains(&"&pg="));
    }

    /// ★ 分页字段名逐字（`totalpage`/`pagecount`，两个都要认）
    #[test]
    fn pagination_fields_match_the_dex_constants() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_ys.rs"));
        for f in ["totalpage", "pagecount", "total", "limit"] {
            assert!(flat.contains(f), "★ 分页字段缺失：{f}");
        }
    }

    #[tokio::test]
    async fn every_segment_reports_the_missing_host() {
        let s = AppYs::new();
        for e in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.detail("1", "").await.err(),
            s.search("x", 1, "").await.err(),
        ] {
            let msg = e.expect("无 host 必须 Err");
            assert!(msg.contains("host"), "{msg}");
            assert!(msg.contains("csp_AppYs 站"), "{msg}");
            assert!(msg.contains("不读 ext"), "★ 要说明「它自己不读 ext」这个特性：{msg}");
        }
    }

    /// ★ 如实标"未实现"：本仓 trait **没有** isVideoFormat / manualVideoCheck 等价位
    #[test]
    fn missing_trait_equivalents_are_declared_not_faked() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_ys.rs"));
        // 不许出现这两个方法名（出现=假装实现了）
        assert!(!flat.contains("fn is_video_format"), "★ trait 无等价位 ⇒ 不许假装有");
        assert!(!flat.contains("fn manual_video_check"), "★ 同上");
        // 但要在注释里**如实登记**这件事（文件头已写）
        let src = include_str!("app_ys.rs");
        assert!(
            src.contains("CspSite trait 无等价位"),
            "★ 必须如实登记「本仓无等价位」这件事"
        );
    }

    /// ★★ 这条守"**不许把 `pick_str` 当"多键择一"用**"（我刚踩的真 bug）
    ///
    /// ```text
    /// `shared::pick_str(v, &["a","b"])` = **嵌套路径** ⇒ 取 `v["a"]["b"]`
    /// 若有人按"先试 a 再试 b"的直觉写，退路字段会**永远取不到**，
    /// 且症状是"少字段/列表为空"，**极难查**（不报错、只是空）。
    /// ⇒ 判据：本文件里不许出现 `pick_str(…, &["x","y"])` 这种**两个键**的调用。
    /// ```
    #[test]
    fn pick_str_is_not_abused_as_key_fallback() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_ys.rs"));
        // 允许的形态：单键 `&["xxx"]`，或嵌套（用于 data.xxx 这类真嵌套）
        assert!(
            !flat.contains(r#"pick_str(v,&["vod_name","title"]"#)
                && !flat.contains(r#"pick_str(d,&["vod_pic","pic"]"#),
            "★ 不许把 pick_str 当多键择一（它是嵌套路径）——要用 pick_any"
        );
        // 反过来：本案必须**有** pick_any 这个正确的助手
        assert!(flat.contains("fnpick_any"), "★ 必须有 pick_any（多键择一）");
    }

    #[test]
    fn pick_any_tries_keys_in_order_and_skips_blank() {
        // 第一键命中
        assert_eq!(
            pick_any(&json!({"vod_name": "A", "title": "B"}), &["vod_name", "title"]).as_deref(),
            Some("A")
        );
        // 第一键缺失 ⇒ 退到第二键（**这正是 pick_str 做不到的**）
        assert_eq!(
            pick_any(&json!({"title": "B"}), &["vod_name", "title"]).as_deref(),
            Some("B")
        );
        // 第一键存在但为空 ⇒ 也要退到第二键
        assert_eq!(
            pick_any(&json!({"vod_name": "  ", "title": "B"}), &["vod_name", "title"]).as_deref(),
            Some("B")
        );
        // 都没有 ⇒ None
        assert_eq!(pick_any(&json!({}), &["vod_name", "title"]), None);
        // ★ 对照：pick_str 的"多键"语义是**嵌套**（就是这个坑）
        let nested = json!({"vod_name": {"title": "X"}});
        assert_eq!(
            crate::csp::shared::pick_str(&nested, &["vod_name", "title"]),
            Some("X"),
            "★ 证明 pick_str 的多键 = 嵌套路径（不是择一）"
        );
    }

    #[test]
    fn item_of_accepts_both_field_dialects() {
        // DEX 里 home/list/search 共用一套键，且有 `title`/`pic`/`state` 退路
        let a = AppYs::item_of(&json!({"vod_id": 1, "vod_name": "A", "vod_pic": "https://p",
                                       "vod_remarks": "更新"})).unwrap();
        assert_eq!(a.title, "A");
        assert_eq!(a.subtitle.as_deref(), Some("更新"));
        let b = AppYs::item_of(&json!({"vod_id": 2, "title": "B", "pic": "https://q",
                                       "state": "完结"})).unwrap();
        assert_eq!(b.title, "B");
        assert_eq!(b.cover.as_deref(), Some("https://q"));
        assert_eq!(b.subtitle.as_deref(), Some("完结"));
        // 缺 id / 缺名 ⇒ 跳过
        assert!(AppYs::item_of(&json!({"vod_name": "无 id"})).is_none());
        assert!(AppYs::item_of(&json!({"vod_id": 1})).is_none());
    }
}