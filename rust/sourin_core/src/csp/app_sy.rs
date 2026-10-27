// ═══════════════════════════════════════════════════════════════════════
//  csp_AppSy —— 「AppleCMS-v1 接口族」的 Rust 重写（**本批不注册**，理由见下）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★ 为什么这个文件**没有** `register_site!`（这是本文件最重要的一段）
//
// ```text
// 【判据一：订阅里 0 站引用】
//   `.probe/ref-subscription.json`（100 站）逐字比对：
//     csp_AppYQK=1  csp_Hxq=1  csp_Wwys=1  csp_Czsapp=1  csp_YunDuo=1  csp_SouJu=1
//     csp_AppSy=0   csp_App3Q=0 csp_AppFox=0 csp_AppQi=0 csp_AppYs=0      ← **0 站**
//
// 【判据二：host 只能从 ext 拿，而订阅里没有它的站】
//   `init(Context, String)` 读的键（DEX 常量，逐字）：
//     `url` / `siteKey` / `listKey` / `parsesKey` / `site`
//   ⇒ 没有 ext 就**没有 host** ⇒ 真网络**无可打**（不是"上游死"，是"没有目标"）
//   ⇒ 实现出来**永不路由到**（注册表里没有站会命中它）
//
// 【所以本批的处置（Lead 裁定）】
//   **做实现、不注册**：协议照 DEX 写全，留文件；
//   将来别的订阅带上 `csp_AppSy` 时，**加一行注册**即可（不必重写协议）。
//   ⚠️ 一旦注册，`build_registry_from_inventory()` 会把它收进注册表 ——
//      而它**无法实网验证**（无 host）⇒ 现在注册等于交付一个"看起来支持但无法验证"的类。
//      ⇒ **不注册是诚实的选择**，不是遗漏。
// ```
//
// # 协议（从 DEX 常量逐字还原，**不逐字抄 Java**，按行为重写）
//
// ```text
// 形态：**AppleCMS 变体**（`api.php/v1.*` 路径风格，与常见 `api.php/provide/vod` 不同）
//
// home   GET {host}/api.php/v1.home/types           → data.types[]  {type_id, type_name}
//        GET {host}/api.php/v1.home/data?type_id=N  → data.banners[] {vod_id,vod_name,vod_pic,
//                                                                    vod_remarks, vod_score}
//        ★ 副标题拼法（DEX）：`vod_remarks + "|" + vod_score`
// list   GET {host}/api.php/v1.classify/content?page=N&type_id=…
//        → data.video_list[] {vod_id, vod_name, vod_pic, vod_remarks, vod_score}
//        ★ 可带筛选项（DEX 里有 area/rank/type/year 四组）：
//             area 默认 ''、rank 默认 '按上新'、type 默认 ''、year 默认 ''
// detail GET {host}/api.php/v1.player/details?vod_id=N
//        → data.detail {vod_name, vod_pic, vod_remarks, vod_content, vod_actor,
//                       vod_director, vod_class, play_url_list[]}
//        ★ play_url_list[] 每条有 `from` / `show` / `urls[]`（urls 的 name 被 `(…)` 洗过）
//        ★ 拼装：`$$$` 分线、`#` 分集、`$` 分名址（DEX 里就是这三层）
// search GET {host}/api.php/v1.search/data?wd=…&type_id=0&page=1
// play   ★ **不直连**：走 `{host}/shark/api.php?action=parsevod`（**另一个服务**）
//        POST/GET 带 `url`，响应里有 `url` / `matching`
//        （`?do=appdanmu` 是弹幕入口 —— 本仓无弹幕契约，如实不做）
// ```
//
// # 能力边界（如实）
// ```text
// · play 走 `shark/api.php`（**站点自己的解析服务**），不是直链 ⇒
//   本仓无 host 也无可验证目标，这条**未实测**（如实标，不假装通）
// · `?do=appdanmu` 弹幕 —— 本仓无弹幕等价位 ⇒ 未实现（不是"忘了"）
// · mProxy / loadPic —— 按 Lead 裁定：不做 / 写声明式 cover_headers
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::{pick_arr, pick_id_str, pick_str, split_lines};

/// DEX `init()` 的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 封面请求头（声明式；本类未实测 ⇒ 留空，不编）
pub const COVER_HEADERS: &[(&str, &str)] = &[];

const TIMEOUT: Duration = Duration::from_secs(20);

/// 分类筛选项的 DEX 默认值（`categoryContent` 里逐字）
///
/// ```text
/// area='' / rank='按上新' / type='' / year=''
/// ⇒ 只作参考常量放在这里（**未实测**，因为本类无 host 可打）
/// ```
pub const FILTER_DEFAULTS: &'static [(&'static str, &'static str)] = &[
    ("area", ""),
    ("rank", "按上新"),
    ("type", ""),
    ("year", ""),
];

/// 从 ext 里取 host（DEX `init` 读 `url` / `site` 两个键）
///
/// ★ **抽成纯函数**：本类没有真网络可打 ⇒ 门禁必须靠"纯函数 + 契约断言"，
///   否则它是一条**永远绿**的类（没有任何可验的东西）。
pub fn host_of(ext: &str) -> Option<String> {
    let j = crate::tvbox::parse_loose_json(ext).ok()?;
    let pick = |k: &str| -> Option<String> {
        j.get(k)
            .and_then(|v| v.as_str())
            .map(|s| s.trim().trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
    };
    pick("url").or_else(|| pick("site"))
}

pub struct AppSy {
    client: reqwest::Client,
}

impl AppSy {
    pub const CLASS: &'static str = "AppSy";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build app_sy http client");
        Self { client }
    }

    /// host 缺失时的**统一文案**（三处共用，避免措辞漂）
    ///
    /// ★ 这条文案本身就是"本类为什么不注册"的用户可见版本 ——
    ///   点进去必须能看见"缺 ext.url"，而不是一个空列表。
    fn need_host(ext: &str) -> Result<String, String> {
        host_of(ext).ok_or_else(|| {
            "AppSy 需要 ext 里的站点地址（键 `url` 或 `site`）——本仓当前无该站配置，\
             且订阅里没有任何 csp_AppSy 站（该类为「做实现、不注册」状态）"
                .to_string()
        })
    }

    async fn get_json(&self, url: &str) -> Result<Value, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
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

    /// `vod_remarks|vod_score` 形式的副标题（DEX 逐字：两字段用 `|` 拼）
    fn sub_of(v: &Value) -> Option<String> {
        let remark = pick_str(v, &["vod_remarks"]).unwrap_or("").trim();
        let score = pick_str(v, &["vod_score"]).unwrap_or("").trim();
        let joined = match (remark.is_empty(), score.is_empty()) {
            (true, true) => String::new(),
            (false, true) => remark.to_string(),
            (true, false) => score.to_string(),
            (false, false) => format!("{remark}|{score}"),
        };
        if joined.is_empty() {
            None
        } else {
            Some(joined)
        }
    }

    fn item_of(v: &Value) -> Option<CspItem> {
        let id = pick_id_str(v, &["vod_id"])?;
        let title = pick_str(v, &["vod_name"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return None;
        }
        Some(CspItem {
            id,
            title,
            cover: pick_str(v, &["vod_pic"]).map(|s| s.to_string()),
            subtitle: Self::sub_of(v),
        })
    }
}

impl Default for AppSy {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  ⚠️ **没有 `register_site!`** —— 见文件头"为什么这个文件没有注册"
//
//  将来别的订阅带上 `csp_AppSy` 时，在这里加一行即可：
//      crate::csp::register_site!(AppSy);
//  （**并同时把"订阅里有 0 站"那条注释一起删掉**，否则注释会与代码矛盾。）
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for AppSy {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = Self::need_host(ext)?;
        let v = self.get_json(&format!("{host}/api.php/v1.home/types")).await?;
        let mut categories: Vec<CspCategory> = Vec::new();
        for t in pick_arr(&v, &["data", "types"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            let id = pick_id_str(t, &["type_id"]).unwrap_or_default();
            let name = pick_str(t, &["type_name"]).unwrap_or("").trim().to_string();
            if !id.is_empty() && !name.is_empty() {
                categories.push(CspCategory { id, name });
            }
        }
        if categories.is_empty() {
            return Err("首页没有 data.types（上游结构可能变了）".to_string());
        }
        /*
         * 首屏：DEX 里**另打一次** `/api.php/v1.home/data?type_id=N`（拿 banners）。
         *
         * ⚠️ 我第一版**漏了这一步**（直接读了 `v1.home/types` 的 banners）——
         *   而 DEX 常量里明确有 `'/api.php/v1.home/data?type_id='` 这个端点。
         *   门禁 `upstream_endpoints_match_the_dex_constants` 当场抓红（真红）。
         * ⇒ 现在按 DEX 语义：用**第一个分类**去问 home/data，读 `data.banners[]`。
         *   失败**不阻断**首页（banners 只是首屏推荐；拿不到就空，不编）。
         */
        let mut items: Vec<CspItem> = Vec::new();
        if let Some(first) = categories.first() {
            let url = format!(
                "{host}/api.php/v1.home/data?type_id={}",
                urlencoding::encode(&first.id)
            );
            if let Ok(v2) = self.get_json(&url).await {
                items = pick_arr(&v2, &["data", "banners"])
                    .map(|a| a.iter().filter_map(Self::item_of).collect())
                    .unwrap_or_default();
            }
        }
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let page = if page == 0 { 1 } else { page };
        // DEX 的模板：`/api.php/v1.classify/content?page=`（type_id 与筛选项同送）
        let url = format!(
            "{host}/api.php/v1.classify/content?page={page}&type_id={}",
            urlencoding::encode(tid)
        );
        let v = self.get_json(&url).await?;
        let items: Vec<CspItem> = pick_arr(&v, &["data", "video_list"])
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        if items.is_empty() {
            if page > 1 {
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total: None,
                });
            }
            return Err(format!("分类 {tid} 没解析出条目（上游结构可能变了）"));
        }
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let vid = id.trim();
        if vid.is_empty() {
            return Err("vod_id 为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let v = self
            .get_json(&format!("{host}/api.php/v1.player/details?vod_id={vid}"))
            .await?;
        let d = v
            .get("data")
            .and_then(|x| x.get("detail"))
            .ok_or_else(|| "详情响应没有 data.detail（结构变了）".to_string())?;
        let title = pick_str(d, &["vod_name"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return Err(format!("详情 vod_name 为空（vod_id={vid}）"));
        }

        /*
         * 剧集：`play_url_list[]` 每条有 `from`（线路名）/ `show` / `urls[]`
         * ★ DEX 里对 `show`/`name` 做了 `\(.*?\)|（.*?）` 的**括号清洗**
         *   （把"第1集(高清)"这类后缀去掉）—— 本实现照做（下面 `strip_paren`）。
         */
        let mut episodes: Vec<CspEpisode> = Vec::new();
        for p in pick_arr(d, &["play_url_list"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            let flag = pick_str(p, &["from"])
                .or_else(|| pick_str(p, &["show"]))
                .unwrap_or("默认")
                .trim()
                .to_string();
            for u in pick_arr(p, &["urls"]).map(|a| a.as_slice()).unwrap_or(&[]) {
                let ep_url = pick_str(u, &["url"]).unwrap_or("").trim().to_string();
                if ep_url.is_empty() {
                    continue;
                }
                let name = strip_paren(pick_str(u, &["name"]).unwrap_or("").trim());
                episodes.push(CspEpisode {
                    // id 编码线路 + 地址（play 需要线路名做 label）
                    id: format!("{flag}|{ep_url}"),
                    title: if name.is_empty() {
                        ep_url.clone()
                    } else {
                        name
                    },
                    flag: flag.clone(),
                });
            }
        }
        if episodes.is_empty() {
            return Err(format!("「{title}」没有可播剧集（play_url_list 为空）"));
        }
        Ok(CspDetail {
            id: vid.to_string(),
            title,
            cover: pick_str(d, &["vod_pic"]).map(|s| s.to_string()),
            description: {
                let content = pick_str(d, &["vod_content"])
                    .map(super::hxq::clean_intro)
                    .unwrap_or_default();
                let actor = pick_str(d, &["vod_actor"]).unwrap_or("").trim();
                let director = pick_str(d, &["vod_director"]).unwrap_or("").trim();
                let class = pick_str(d, &["vod_class"]).unwrap_or("").trim();
                let mut parts: Vec<String> = Vec::new();
                if !content.is_empty() {
                    parts.push(content);
                }
                if !class.is_empty() {
                    parts.push(format!("类型：{class}"));
                }
                if !actor.is_empty() {
                    parts.push(format!("主演：{actor}"));
                }
                if !director.is_empty() {
                    parts.push(format!("导演：{director}"));
                }
                if parts.is_empty() {
                    None
                } else {
                    Some(parts.join("\n"))
                }
            },
            episodes,
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let _ = page; // DEX 里搜索固定 `&type_id=0&page=1`
        let url = format!(
            "{host}/api.php/v1.search/data?wd={}&type_id=0&page=1",
            urlencoding::encode(kw)
        );
        let v = self.get_json(&url).await?;
        let items: Vec<CspItem> = pick_arr(&v, &["data", "video_list"])
            .or_else(|| pick_arr(&v, &["data", "list"]))
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        Ok(CspList {
            items,
            page: 1,
            page_count: None,
            total: None,
        })
    }

    /// ★ 未实测（无 host）⇒ 不能声明 true（声明了会让 registry 纳入并恒返回空）
    fn supports_search(&self) -> bool {
        false
    }

    /// 取流：走站点自己的 `shark/api.php?action=parsevod`（**未实测**）
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let host = Self::need_host(ext)?;
        let (line, url) = split_ep_id(id)
            .ok_or_else(|| format!("剧集 id 形态不对（应为 `线路|地址`）：{id}"))?;
        let req_url = format!(
            "{host}/shark/api.php?action=parsevod&url={}",
            urlencoding::encode(&url)
        );
        let v = self.get_json(&req_url).await?;
        let parsed = pick_str(&v, &["url"]).unwrap_or("").trim().to_string();
        if parsed.is_empty() {
            // DEX 里的失败文案是 `解析失败` —— 如实透出，不编地址
            return Err(format!(
                "解析失败（{req_url}）：站点解析服务没给 url（响应前 120 字：{}）",
                head(&v.to_string())
            ));
        }
        if !crate::tvbox::starts_http(&parsed) {
            return Err(format!("解析服务给的地址不是 http：{parsed}"));
        }
        Ok(vec![CspPlay {
            url: parsed,
            headers: vec![
                ("Referer".to_string(), format!("{host}/")),
                ("User-Agent".to_string(), UA.to_string()),
            ],
            label: Some(if line.is_empty() { flag.to_string() } else { line }),
        }])
    }
}

/// 从剧集 id（`线路|地址`）拆出两段
///
/// ★ `splitn(2, '|')`：地址里可能含其他字符，第 2 段**整段**是地址
pub fn split_ep_id(id: &str) -> Option<(String, String)> {
    let mut it = id.splitn(2, '|');
    let line = it.next()?.trim().to_string();
    let url = it.next()?.trim().to_string();
    if url.is_empty() {
        return None;
    }
    Some((line, url))
}

/// 洗掉 `第1集(高清)` 这类**括号后缀**（DEX 里就是 `\(.*?\)|（.*?）`）
///
/// # ★ 语义必须与 DEX 那条正则**一致**（这条我第一版写错了，留档）
/// ```text
/// DEX：`\(.*?\)|（.*?）` —— 非贪婪，**只匹配成对的括号**。
/// 我第一版写的是"遇到 `(` 就 depth+=1，之后的内容全丢"：
///   ⇒ 输入 `书名号(未闭合`（没有右括号）会被洗成 `书名号` —— **多洗了**。
///   而 DEX 的正则对它是**不匹配**的（正则要求有成对的 `)`）⇒ 应该**原样保留**。
///   ⇒ 门禁 `strip_paren_removes_paired_brackets_only` 当场抓红（真红）。
/// ⇒ 修法：**先找最近的配对的 `)`**；找不到 ⇒ **整段原样保留**（连 `(` 一起）。
///   这与 `.*?` 的"非贪婪 = 取最近的那个 `)`"一致。
/// ```
pub fn strip_paren(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0usize;
    while i < chars.len() {
        let c = chars[i];
        if c == '(' || c == '（' {
            let close = if c == '(' { ')' } else { '）' };
            // 找**最近**的同种右括号（= `.*?` 的非贪婪语义）
            match chars[i + 1..].iter().position(|&x| x == close) {
                Some(off) => {
                    // 成对 ⇒ 连同括号一起丢掉，从右括号之后继续
                    i = i + 1 + off + 1;
                }
                None => {
                    // ★ 不成对 ⇒ 原样保留这个左括号（不许"多洗"）
                    out.push(c);
                    i += 1;
                }
            }
        } else {
            out.push(c);
            i += 1;
        }
    }
    out.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(AppSy::CLASS, "AppSy");
        assert_eq!(AppSy::new().class(), "AppSy");
    }

    /// ★★ 这条是**本类唯一的"存在性"门禁**：`AppSy` **不许**被注册
    ///
    /// # 为什么必须有（本类没有真网络可打）
    /// ```text
    /// 本类 host 只能从 ext 拿，而订阅里 **0 站** ⇒ 无法实网验证。
    /// 若有人"顺手"加了 `register_site!(AppSy)` ⇒ 注册表里会多一个
    /// **看起来支持但无法验证**的类（本仓最忌讳）。
    /// ⇒ 判据：本文件**不许**出现 `register_site!`；
    ///   一旦哪天订阅带上了它、真要注册，这条会**红**并提示"该更新说明了"。
    /// ```
    #[test]
    fn app_sy_must_not_be_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_sy.rs"));
        assert!(
            !flat.contains("register_site!(AppSy)"),
            "★ 本批 AppSy 是「做实现、不注册」（订阅里 0 站、无 host 可打）——\
             要注册请连同「订阅里已有该站」的证据一起改这条门禁"
        );
        // 并确认它**真的**不在注册表里（防止别处偷偷注册）
        assert!(
            !crate::csp::is_implemented("csp_AppSy"),
            "★ csp_AppSy 本批不许出现在注册表里"
        );
    }

    #[test]
    fn host_comes_from_ext_url_or_site() {
        // DEX `init` 读 `url` 与 `site` 两个键
        assert_eq!(host_of(r#"{"url":"https://a.example"}"#).as_deref(), Some("https://a.example"));
        assert_eq!(host_of(r#"{"site":"https://b.example/"}"#).as_deref(), Some("https://b.example"));
        // `url` 优先（DEX 里它先读 url）
        assert_eq!(
            host_of(r#"{"url":"https://u.example","site":"https://s.example"}"#).as_deref(),
            Some("https://u.example")
        );
        // 都缺 ⇒ None（由 need_host 报错，不猜一个 host）
        assert_eq!(host_of("{}"), None);
        assert_eq!(host_of(""), None);
        assert_eq!(host_of(r#"{"url":"  "}"#), None);
    }

    #[tokio::test]
    async fn every_segment_reports_the_missing_host_instead_of_guessing() {
        // ★ 无 ext ⇒ 四个方法都必须报"缺 host"，**不许**编一个地址出去
        let s = AppSy::new();
        for r in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.detail("1", "").await.err(),
            s.search("x", 1, "").await.err(),
        ] {
            let e = r.expect("无 host 必须 Err");
            assert!(e.contains("ext"), "要点名缺 ext：{e}");
            assert!(e.contains("csp_AppSy 站"), "要说明订阅里没有该站：{e}");
        }
        let pe = s.play("L", "L|https://x/1.m3u8", "").await.expect_err("也要 Err");
        assert!(pe.contains("ext"), "{pe}");
    }

    #[test]
    fn subtitle_joins_remarks_and_score_with_pipe() {
        // DEX 逐字：`vod_remarks` + `|` + `vod_score`
        let it = AppSy::item_of(&json!({"vod_id": 1, "vod_name": "T",
            "vod_remarks": "更新至12集", "vod_score": "8.5"})).unwrap();
        assert_eq!(it.subtitle.as_deref(), Some("更新至12集|8.5"));
        // 只有一边 ⇒ 不留多余的分隔符
        let a = AppSy::item_of(&json!({"vod_id": 1, "vod_name": "T", "vod_remarks": "更新至12集"})).unwrap();
        assert_eq!(a.subtitle.as_deref(), Some("更新至12集"));
        let b = AppSy::item_of(&json!({"vod_id": 1, "vod_name": "T", "vod_score": "8.5"})).unwrap();
        assert_eq!(b.subtitle.as_deref(), Some("8.5"));
        // 都没有 ⇒ None（不是空串）
        let c = AppSy::item_of(&json!({"vod_id": 1, "vod_name": "T"})).unwrap();
        assert_eq!(c.subtitle, None);
    }

    #[test]
    fn strip_paren_removes_paired_brackets_only() {
        // DEX 的正则 `\(.*?\)|（.*?）` 的效果
        assert_eq!(strip_paren("第1集(高清)"), "第1集");
        assert_eq!(strip_paren("第1集（超清）"), "第1集");
        assert_eq!(strip_paren("正片 (HD)"), "正片");
        // ★ 不成对的括号**不许**被吃掉（否则会误伤正常剧名）
        assert_eq!(strip_paren("书名号(未闭合"), "书名号(未闭合");
        assert_eq!(strip_paren("剧名)异常"), "剧名)异常");
        // 没括号 ⇒ 原样
        assert_eq!(strip_paren("第01集"), "第01集");
    }

    #[test]
    fn split_ep_id_keeps_the_whole_url() {
        let (l, u) = split_ep_id("线路A|https://cdn.example/a.m3u8?x=1&y=2").unwrap();
        assert_eq!(l, "线路A");
        assert_eq!(u, "https://cdn.example/a.m3u8?x=1&y=2", "★ 地址整段保留");
        // 地址里含 `|` 也要保住后半（splitn(2) 语义）
        let (_, u2) = split_ep_id("L|https://x/a|b").unwrap();
        assert_eq!(u2, "https://x/a|b");
        assert!(split_ep_id("没有分隔符").is_none());
        assert!(split_ep_id("L|").is_none(), "空地址 ⇒ None");
    }

    #[test]
    fn filter_defaults_match_the_dex_constants() {
        assert_eq!(FILTER_DEFAULTS.len(), 4);
        assert!(FILTER_DEFAULTS.contains(&("rank", "按上新")));
        assert!(FILTER_DEFAULTS.contains(&("area", "")));
    }

    #[test]
    fn upstream_endpoints_match_the_dex_constants() {
        // ★ 端点必须与 DEX 常量逐字一致（写错就永远 404）
        let flat = crate::csp::shared::impl_src_only(include_str!("app_sy.rs"));
        for ep in [
            "/api.php/v1.home/types",
            "/api.php/v1.home/data?type_id=",
            "/api.php/v1.classify/content?page=",
            "/api.php/v1.player/details?vod_id=",
            "/api.php/v1.search/data?wd=",
            "/shark/api.php?action=parsevod",
        ] {
            assert!(flat.contains(ep), "★ 端点缺失/写错：{ep}");
        }
    }
}