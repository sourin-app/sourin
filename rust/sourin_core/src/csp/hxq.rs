// Native catalog adapter with an anonymous client session for media resolution.
// 2026-11-10: playback supplies the public client headers, decrypts the episode
// envelope and signs rslvV4 for the exact selected pid. Source permission and
// rate-limit responses remain failures; no alternative pid is substituted.

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::{pick_arr, pick_id_str, pick_str};

#[path = "hxq_playback.rs"]
mod playback;

/// 硬编码 API 根（DEX 常量 `Lcom/github/catvod/spider/Hxq;` 的 `<init>`）
const BASE: &str = "https://hxqapi.hiyun.tv";

/// Public client's default episode-detail refer value; it is not a signing secret.
pub const CANDIDATE_SECRET: &str = "rSwCIIUMYCiHZXIVfgxlxylE9eGqfmwMg5V8mRSBB55vN8P3bNpXkUrv9MFhYOvm";

/// 站点 UA（DEX `d()` 里写的是 `hj` 这个 app 标识 + 移动 UA）
const APP_ID: &str = "hj";
const UA: &str = "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";

/// 封面请求头（声明式）—— 实测 `hqres.51touxiang.com` 的图直连可取，无需额外头
pub const COVER_HEADERS: &[(&str, &str)] = &[];

const TIMEOUT: Duration = Duration::from_secs(20);

/// 分类（`stype`）—— 实测哪些**真的有内容**
///
/// ```text
/// 2026-10-27 实测：stype=1 → 22 条 / stype=2 → 29 条 / stype=3 → 20 条
///                 stype=4,5,6 → **0 条**（上游空）
/// ⇒ 只列**实测有内容**的三个，不列那三个空的 ——
///   列了会让用户点进一个永远为空的分类（本仓最忌讳的"看起来支持"）。
/// ```
pub const CATEGORIES: &'static [(u32, &'static str)] = &[
    (1, "剧集"),
    (2, "综艺"),
    (3, "电影"),
];

/// 排序（实测有效值；DEX 写的 `vod_hits_week` 真站已不支持）
pub const SORTS: &'static [(&'static str, &'static str)] =
    &[("new", "最新"), ("hot", "最热"), ("score", "评分")];

pub struct Hxq {
    client: super::http_context::CspHttpContext,
    playback_session: std::sync::OnceLock<Result<playback::Session, String>>,
}

impl Hxq {
    pub const CLASS: &'static str = "Hxq";

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| {
            reqwest::Client::builder()
                .user_agent(UA)
                .timeout(TIMEOUT)
                // Ignore environment proxies; CspHttpContext applies app policy.
                .no_proxy()
        });
        Self { client, playback_session: std::sync::OnceLock::new() }
    }

    /// 带站点标识的 GET（DEX 的 `d()` 里那几个头）
    async fn get_json(&self, path: &str) -> Result<Value, String> {
        let url = format!("{BASE}{path}");
        self.get_json_url(&url, path).await
    }

    async fn get_json_url(&self, url: &str, path: &str) -> Result<Value, String> {
        let resp = self
            .client
            .client()?
            .get(url)
            .header("app", APP_ID)
            .header(reqwest::header::ACCEPT, "*/*")
            .send()
            .await
            .map_err(|e| format!("请求 {path} 失败：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取 {path} 响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "{path} 返回 HTTP {status}：{}",
                text.chars().take(160).collect::<String>()
            ));
        }
        let v: Value = crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("{path} 不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
        /*
         * ★ 上游业务码：`rescode` 0 = 成功。
         *
         * ⚠️ 但**不能只看 rescode**：
         *   实测 `/api/series2/episodes`、`/api/series2/detail/normal`、`/api/search/s5`
         *   都回 `{"rescode":0,"ts":…}` —— **业务码说成功，但 body 里什么都没有**。
         *   ⇒ 所以"成功"的判据必须是 `rescode==0` **且**调用方要的那个键真的存在。
         *   ⇒ 本函数只做 rescode 校验；"要的键在不在"由各调用点自己判（它们知道要什么）。
         */
        match v.get("rescode").and_then(|r| r.as_i64()) {
            Some(0) => Ok(v),
            Some(code) => Err(format!(
                "{path} 上游 rescode={code}：{}",
                v.get("errmsg").and_then(|m| m.as_str()).unwrap_or("（无 errmsg）")
            )),
            None => Err(format!("{path} 响应没有 rescode 字段（形状变了）")),
        }
    }

    /// `seriesList[]` 里的一条 → [`CspItem`]
    ///
    /// 字段映射（实测 `seriesList[]` 的真实键）：
    /// ```text
    /// sid      → id            ← ★ 不是 vod_id，这个站用 sid
    /// name     → title
    /// thumb    → cover
    /// 更新状态 → subtitle（isFinished ? 完结 : 连载中 + 集数）
    /// ```
    fn item_of(s: &Value) -> Option<CspItem> {
        let sid = pick_str(s, &["sid"])?.trim().to_string();
        let name = pick_str(s, &["name"]).unwrap_or("").trim().to_string();
        if sid.is_empty() || name.is_empty() {
            return None;
        }
        // 副标题：完结/集数（实测 `isFinished` + `count`）
        let finished = s.get("isFinished").and_then(|b| b.as_bool()).unwrap_or(false);
        let count = s.get("count").and_then(|c| c.as_i64()).unwrap_or(0);
        let sub = match (finished, count) {
            (true, n) if n > 0 => format!("已完结 · 共{n}集"),
            (true, _) => "已完结".to_string(),
            (false, n) if n > 0 => format!("更新至{n}集"),
            (false, _) => String::new(),
        };
        Some(CspItem {
            id: sid,
            title: name,
            cover: pick_str(s, &["thumb"]).map(|t| t.to_string()),
            subtitle: if sub.is_empty() { None } else { Some(sub) },
        })
    }

    /// 从任意 `seriesList` 形态的响应里抽出条目（列表/榜单/搜索**共用**，避免三份映射漂移）
    fn items_from(v: &Value) -> Vec<CspItem> {
        pick_arr(v, &["seriesList"])
            .map(|a| a.as_slice())
            .unwrap_or(&[])
            .iter()
            .filter_map(Self::item_of)
            .collect()
    }

    /// 把"条目列表 + 页码"折成 [`CspList`] —— **抽成纯函数以便门禁能驱动**
    ///
    /// # ★ 为什么必须抽出来（这是被注入验证逼出来的）
    /// ```text
    /// 我第一版把这段逻辑**内联在 `list()` 里**。做注入验证 I4
    /// （把"空响应"改成"永远 Ok(空)"）时发现：**没有任何测试红**。
    /// 根因：`list()` 是 async 且要发网络 ⇒ 那段分支**不可测** ⇒ 也就**没有门禁**。
    /// ⇒ 抽成纯函数后能被直接断言，I4 才能真红（已实测）。
    /// ⇒ 教训：**"不可测的分支"等于"没有门禁的分支"**，
    ///    遇到这种情况要把判据抽成纯函数，而不是给它写一句"看起来在测"的注释。
    /// ```
    ///
    /// # 判据（空列表要**说清是哪一种空**）
    /// ```text
    /// · 有内容              ⇒ 正常页
    /// · 空 + page > 1       ⇒ 正常到末尾 ⇒ Ok(空页)，page_count 给 page-1
    /// · 空 + page == 1      ⇒ **上游这个分类确实没内容** ⇒ Err 说清楚
    ///   （实测 stype=4/5/6 恒空 —— 报 Err 比"空页"更准：用户能区分
    ///     "这个分类本来就没有" 与 "加载失败"）
    /// ```
    fn page_of(stype: &str, page: u32, items: Vec<CspItem>) -> Result<CspList, String> {
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
                "分类 {stype} 上游返回 0 条（实测 stype=4/5/6 恒空；stype=1/2/3 应有内容）"
            ));
        }
        Ok(CspList {
            items,
            page,
            // 上游不给总数/总页数 ⇒ 如实 None（不许编一个 page_count）
            page_count: None,
            total: None,
        })
    }
}

impl Default for Hxq {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

/// 把上游 `intro` 里的 HTML 洗成可读文本（DEX 的 `Hxq.f0` 就是做这个的）
///
/// # 为什么要在这里做（而不是交给 UI）
/// ```text
/// 实测 `series.intro` 是**带标签的 HTML**：
///   "<p>本剧改编自…</p>\n\n<p>导演:&nbsp;李廷林<br />\n编剧:…</p>"
/// 直接透给 UI 会把标签当正文显示。
/// ⇒ 剥标签 + 解 `&nbsp;` 这类实体（本仓已有 `crate::tvbox::strip_tags` / `decode_entities`，
///   **不新增依赖**）。
/// ```
pub fn clean_intro(html: &str) -> String {
    let stripped = crate::tvbox::strip_tags(html);
    let decoded = crate::tvbox::decode_entities(&stripped);
    // 压掉 HTML 剥完后留下的连续空白（实测 intro 里有 "&nbsp;" → 多个空格）
    decoded
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_string()
}

#[async_trait]
impl CspSite for Hxq {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：分类表（写死实测有内容的三个）+ 首屏（`/api/series/rank`）
    ///
    /// # 为什么分类写死而不是问服务端
    /// ```text
    /// DEX 的 `homeContent` 用 `Hxq.Q()`（榜单列表）当 filter、用 `Hxq.D()` 当筛选。
    /// 而实测 `stype` 1/2/3 有内容、4/5/6 恒空 ⇒ 只有这三个是**有效分类**。
    /// ⇒ 写死这三个（它们是该 App 的内置类目，不随内容变），
    ///   并把**榜单**作为首屏内容（那是这个站真实的首页形态）。
    /// ```
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let _ = ext; // ext=null：base 硬编码
        let categories: Vec<CspCategory> = CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: id.to_string(),
                name: (*name).to_string(),
            })
            .collect();

        // 首屏：榜单（真数据；拿不到就空 —— 不编）
        let items = match self.get_json("/api/series/rank").await {
            Ok(v) => Self::items_from(&v),
            Err(_) => Vec::new(),
        };
        Ok(CspHome { categories, items })
    }

    /// 分类列表：`/api/series/cate?stype=&sort=new&page=`
    ///
    /// # 分页语义（实测）
    /// ```text
    /// `page=` 有效：page=1 与 page=2 返回**不同**的 seriesList。
    /// ⇒ 真分页。page_count 上游**不给**（没有 total 字段）⇒ 如实留 None。
    /// ```
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let _ = ext;
        let stype = tid.trim();
        if stype.is_empty() {
            return Err("分类 id（stype）为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let path = format!("/api/series/cate?stype={stype}&sort=new&page={page}");
        let v = self.get_json(&path).await?;
        let items = Self::items_from(&v);
        Self::page_of(stype, page, items)
    }

    /// 详情：`/api/series/detail?sid=` → `series{}` + **顶层内嵌 `playItems[]`**
    ///
    /// # ★ 本次探明的关键（少打一次上游）
    /// ```text
    /// 我一开始按 DEX 的 `Hxq.n(String, JSONObject[])` 去找 `/api/series2/episodes`，
    /// 结果它恒回 `{"rescode":0}` 空 —— 看起来像"上游坏了"。
    /// 但抓全文后发现：**`/api/series/detail` 的响应在顶层就带 `playItems[]`**
    ///   （6 条，含真 `pid`/`serialNo`/`title`/`duration`）。
    /// ⇒ 我把层级读错了（第一版在 `series{}` 里找 playItems ⇒ 找不到，
    ///   于是误判"没有剧集"）。修正后一次请求就拿到全部剧集。
    /// ```
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let _ = ext;
        let sid = id.trim();
        if sid.is_empty() {
            return Err("sid 为空".to_string());
        }
        let v = self.get_json(&format!("/api/series/detail?sid={sid}")).await?;
        let s = v
            .get("series")
            .ok_or_else(|| "详情响应没有 series 对象（形状变了）".to_string())?;

        let name = pick_str(s, &["name"]).unwrap_or("").trim().to_string();
        if name.is_empty() {
            return Err(format!("详情响应里 series.name 为空（sid={sid}）"));
        }

        // 剧集：顶层 playItems[]（不是 series 里 —— 见上面注释里我踩的那个坑）
        let mut episodes: Vec<CspEpisode> = Vec::new();
        for pi in pick_arr(&v, &["playItems"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            let pid = pick_str(pi, &["pid"]).unwrap_or("").trim().to_string();
            if pid.is_empty() {
                continue;
            }
            let serial = pi.get("serialNo").and_then(|n| n.as_i64()).unwrap_or(0);
            let title = pick_str(pi, &["title"]).unwrap_or("").trim().to_string();
            // ⚠️ 先算好 title，再**最后**移动 `pid`（否则 pid 被 move 后不能再 clone）
            let ep_title = if title.is_empty() {
                // 上游没给名字 ⇒ 用"第N集"，N 来自 serialNo；两个都没有才用 pid
                if serial > 0 {
                    format!("第{serial}集")
                } else {
                    pid.clone()
                }
            } else {
                title
            };
            episodes.push(CspEpisode {
                id: pid,
                title: ep_title,
                // 单线路源：flag 固定（这段剧里没有多线路维度）
                flag: "韩圈".to_string(),
            });
        }
        if episodes.is_empty() {
            return Err(format!(
                "「{name}」的 playItems 为空（sid={sid}）—— 上游对该条可能已下架"
            ));
        }

        Ok(CspDetail {
            id: sid.to_string(),
            title: name,
            cover: pick_str(s, &["thumb"]).or_else(|| pick_str(s, &["poster"])).map(|t| t.to_string()),
            description: {
                // intro 是 HTML（实测），必须洗过；shorthand 是短句，拼在后面
                let intro = pick_str(s, &["intro"]).map(clean_intro).unwrap_or_default();
                let short = pick_str(s, &["shorthand"]).unwrap_or("").trim().to_string();
                let crew = pick_str(s, &["crew"]).unwrap_or("").trim().to_string();
                let mut parts: Vec<String> = Vec::new();
                if !short.is_empty() {
                    parts.push(short);
                }
                if !intro.is_empty() {
                    parts.push(intro);
                }
                if !crew.is_empty() {
                    parts.push(crew);
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

    /// 搜索：**上游返回空** ⇒ 如实 Err（`supports_search()` 也是 false）
    ///
    /// # 我做过什么（留档，别重做）
    /// ```text
    /// 带 srefer（必需，缺了 500）后 `{"rescode":0}` 空；换 srefer 为
    /// 搜索模板 URL、其 hash、空、'hj' 都空；换 k/keyword 都空。
    /// ⇒ `srefer` 的真值应由服务端下发（`/api/common/configs` 的 `search_tpl_v2`
    ///   那个模板 URL 的**内容**才是 srefer）⇒ 本仓缺这一步的取数。
    /// ```
    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("Hxq 不支持搜索（上游 /api/search/s5 需要服务端下发的 srefer，\
             本仓缺该值：带 srefer 后上游返回 {\"rescode\":0} 空体）"
            .to_string())
    }

    fn supports_search(&self) -> bool {
        // ★ 必须 false：声明 true 会让 registry 把它纳入聚合搜索并**恒返回空**
        //   （provider.rs 的 capabilities.search 直接用这个值）
        false
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        self.anonymous_play(id).await
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册（R3-D，2026-10-27）
// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
//
// # 这个类的事实（从文件头的长注释搬过来，别丢）
// ```text
// csp_Hxq（🌼韩圈｜蓝光韩剧）：**home / list / detail 三段真网络通**（2026-10-27）
//   home   /api/common/configs 200
//   list   /api/series/cate?stype=1 → 22 条（stype=2 → 29 / stype=3 → 20；4/5/6 上游空）
//   detail /api/series/detail?sid= → series{} + **顶层 playItems[6]**（真 pid/serialNo/title）
//   play   anonymous headers + AES envelope + selected-pid rslvV4 resolution
//   search ⛔ 上游 /api/search/s5 回空 ⇒ supports_search=false
// ⚠️ 探明的一个坑（留档）：playItems 在**顶层**不在 series{} 里 ——
//    第一版我在 series 里找 ⇒ 误判"没有剧集"。
// ```
crate::csp::register_site!(Hxq);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn class_is_registered_under_exact_name() {
        assert_eq!(Hxq::CLASS, "Hxq");
        assert_eq!(Hxq::new().class(), "Hxq");
    }

    #[test]
    fn base_is_the_hardcoded_dex_constant() {
        // ext=null ⇒ 这是**唯一**来源，改错 = 这个类完全不可用
        assert_eq!(BASE, "https://hxqapi.hiyun.tv");
        assert_eq!(APP_ID, "hj");
    }

    // ── ★ 条目映射（对着实测的真字段） ────────────────────────────────
    #[test]
    fn item_of_maps_real_serieslist_fields() {
        // 实测 /api/series/rank 的一条（截关键字段）
        let s = json!({
            "sid": "Qsvt16e_nETeSuxWCUzU",
            "name": "Doctor X:白色黑手党时代",
            "rank": 84, "isFinished": false,
            "thumb": "https://hqres.51touxiang.com/hj_res/x.png",
            "count": 6
        });
        let it = Hxq::item_of(&s).expect("应能映射");
        assert_eq!(it.id, "Qsvt16e_nETeSuxWCUzU", "★ 这个站的 id 是 sid，不是 vod_id");
        assert_eq!(it.title, "Doctor X:白色黑手党时代");
        assert!(it.cover.unwrap().starts_with("https://hqres."));
        assert_eq!(it.subtitle.as_deref(), Some("更新至6集"), "未完结 + count=6");
    }

    #[test]
    fn item_of_reports_finished_state_honestly() {
        let done = json!({"sid": "s1", "name": "x", "isFinished": true, "count": 20});
        assert_eq!(Hxq::item_of(&done).unwrap().subtitle.as_deref(), Some("已完结 · 共20集"));
        // 完结但没给集数 ⇒ 只说"已完结"，**不编一个集数**
        let done2 = json!({"sid": "s2", "name": "x", "isFinished": true});
        assert_eq!(Hxq::item_of(&done2).unwrap().subtitle.as_deref(), Some("已完结"));
        // 连载中且没集数 ⇒ 副标题为 None（不是空字符串，别让 UI 显示空标签）
        let live = json!({"sid": "s3", "name": "x", "isFinished": false});
        assert_eq!(Hxq::item_of(&live).unwrap().subtitle, None);
    }

    #[test]
    fn item_of_skips_entries_without_sid_or_name() {
        assert!(Hxq::item_of(&json!({"name": "有名字没 sid"})).is_none(), "没 sid 无法进详情");
        assert!(Hxq::item_of(&json!({"sid": "s"})).is_none(), "没名字的条目对 UI 没意义");
        assert!(Hxq::item_of(&json!({"sid": "  ", "name": "  "})).is_none(), "空白也算没有");
    }

    #[test]
    fn items_from_reads_series_list_only() {
        let v = json!({"rescode": 0, "seriesList": [
            {"sid": "a", "name": "A"}, {"sid": "b", "name": "B"}
        ], "other": [{"sid": "c", "name": "C"}]});
        let got = Hxq::items_from(&v);
        assert_eq!(got.len(), 2, "★ 只认 seriesList（别把别的数组也当条目）");
        assert_eq!(got[0].id, "a");
        // 没有 seriesList ⇒ 空（由调用方决定报错还是空页）
        assert!(Hxq::items_from(&json!({"rescode": 0})).is_empty());
    }

    // ── ★ intro 是 HTML（实测），必须洗 ────────────────────────────────
    #[test]
    fn clean_intro_strips_html_and_entities() {
        // 实测原样（截取）：带 <p>/<br>/&nbsp;/<a data="star:188">
        let raw = "<p>本剧改编自经典日剧《派遣女医X》。</p>\n\n\
                   <p>导演:&nbsp;李廷林<br />\n编剧:&nbsp;边成根<br />\
                   主演:&nbsp;<a data=\"star:188\">金智媛 </a></p>";
        let got = clean_intro(raw);
        assert!(!got.contains('<'), "标签必须剥掉：{got}");
        assert!(!got.contains("&nbsp;"), "实体必须解掉：{got}");
        assert!(got.contains("本剧改编自经典日剧"), "{got}");
        assert!(got.contains("导演: 李廷林"), "nbsp 应变成正常空格：{got}");
        assert!(got.contains("金智媛"), "链接文本要留下（它是主演名）：{got}");
        // 连续空白要压成一个（实测 intro 里 &nbsp; 会产生多个空格）
        assert!(!got.contains("  "), "连续空格要压掉：{got}");
    }

    // ── ★ 能力位（对着"声明了就得真能搜"这条） ────────────────────────
    #[test]
    fn search_is_declared_unsupported_matching_the_live_reading() {
        let s = Hxq::new();
        // ★ 实测 /api/search/s5 回空 ⇒ 必须声明 false，
        //   否则 registry 会把它纳入聚合搜索并**恒返回空**（假能力位）
        assert!(!s.supports_search(), "★ 本类搜不到，能力位必须是 false");
    }

    #[tokio::test]
    async fn search_errs_with_the_real_reason_not_a_placeholder() {
        let s = Hxq::new();
        let e = s.search("韩", 1, "").await.expect_err("★ 必须 Err，不许 Ok(空)");
        assert!(e.contains("srefer"), "错误要点名真因（缺 srefer）：{e}");
        assert!(e.contains("不支持搜索"), "{e}");
    }

    #[tokio::test]
    async fn play_rejects_invalid_episode_identity_privately() {
        let error = Hxq::new().play("line", "pid?token=private", "").await.unwrap_err();
        assert!(error.contains("标识无效"));
        assert!(!error.contains("private"));
    }

    // ── ★ 结构判据：playItems 必须从**顶层**读（我读错层级踩过） ────────
    #[test]
    fn detail_reads_playitems_from_the_top_level_not_inside_series() {
        /*
         * ★ 这条钉的是**我踩过的那个坑**：
         *   第一版我写 `pick_arr(s, &["playItems"])`（s = series 对象）⇒ 永远取不到
         *   ⇒ 误判"没有剧集"⇒ 以为要调 /api/series2/episodes（那端点是空壳）。
         *   真位置是**响应顶层**：`pick_arr(&v, &["playItems"])`。
         * ⚠️ 用 `impl_src_only` 剥测试段（否则断言字面量会把自己喂成假绿）。
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("hxq.rs"));
        assert!(
            flat.contains(r#"pick_arr(&v,&["playItems"])"#),
            "★ playItems 必须从**响应顶层**读（不是 series 里）"
        );
        assert!(
            !flat.contains(r#"pick_arr(s,&["playItems"])"#),
            "★ 不许再从 series 对象里读 playItems（那是取不到的老写法）"
        );
    }

    /// ★ 空列表必须**区分三种情况**（这条是注入验证 I4 逼出来的）
    ///
    /// # 为什么这条门禁曾经不存在
    /// ```text
    /// 这段逻辑原先内联在 async 的 `list()` 里 ⇒ **不可测** ⇒ 我给它写注释以为"判据有了"，
    /// 实际做注入 I4（把空响应改成永远 Ok(空)）时**一条测试都没红**。
    /// ⇒ 抽成 `page_of` 纯函数后才有了真门禁。
    /// ```
    #[test]
    fn page_of_distinguishes_upstream_empty_from_page_end() {
        // ① 有内容 ⇒ 正常页
        let one = vec![CspItem {
            id: "s".into(), title: "T".into(), cover: None, subtitle: None,
        }];
        let ok = Hxq::page_of("1", 1, one).expect("有内容必须 Ok");
        assert_eq!(ok.items.len(), 1);
        assert_eq!(ok.page, 1);
        assert_eq!(ok.page_count, None, "上游不给总页数 ⇒ 如实 None（不许编）");

        // ② 空 + page>1 ⇒ **正常到末尾**（不是错误）
        let end = Hxq::page_of("1", 3, Vec::new()).expect("翻到末尾是正常结果，不许 Err");
        assert!(end.items.is_empty());
        assert_eq!(end.page, 3);
        assert_eq!(end.page_count, Some(2), "到末尾 ⇒ 上一页就是最后一页");

        // ③ ★ 空 + page==1 ⇒ **上游这个分类确实没内容** ⇒ Err
        //    （实测 stype=4/5/6；报 Err 才能让用户区分"本来就没有"与"加载失败"）
        let e = Hxq::page_of("4", 1, Vec::new()).expect_err("第一页就空 ⇒ 必须报出来");
        assert!(e.contains("0 条"), "要说清是 0 条：{e}");
        assert!(e.contains("stype=4"), "要点名分类便于定位：{e}");
        assert!(e.contains("恒空"), "要说清这个分类上游本来就空：{e}");
    }

    #[test]
    fn categories_only_list_ones_verified_to_have_content() {
        // ★ 实测 stype=4/5/6 恒空 ⇒ 列了就是"看起来支持"
        let ids: Vec<u32> = CATEGORIES.iter().map(|(i, _)| *i).collect();
        assert_eq!(ids, vec![1, 2, 3], "只列实测有内容的三个分类");
        assert!(
            !CATEGORIES.iter().any(|(id, _)| *id >= 4),
            "★ 不许列实测恒空的 stype=4/5/6"
        );
        // 排序同理：DEX 写的 vod_hits_week 真站已不支持（实测 0 条）
        let sorts: Vec<&str> = SORTS.iter().map(|(s, _)| *s).collect();
        assert_eq!(sorts, vec!["new", "hot", "score"]);
        assert!(!sorts.contains(&"hits"), "★ 不许列实测 0 条的 sort=hits");
    }

    #[test]
    fn supports_search_false_is_consistent_with_the_shared_map() {
        // provider.rs 直接用 supports_search() 当 capabilities.search
        // ⇒ 这条保证"能力位"与"实际能不能搜"一致
        assert_eq!(
            Hxq::new().supports_search(),
            false,
            "declared capability must equal actual ability"
        );
    }

    // ── 真网络（显式开关 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_hxq --release -- --ignored --nocapture"]
    async fn csp_live_hxq_home_list_detail() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Hxq::new();
        let home = s.home("").await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {:?}，首屏(榜单) {} 条",
            home.categories.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
            home.items.len()
        );
        let by_id = s.list("1", 1, "").await.expect("list(stype=1) 应成功");
        eprintln!("[LIVE] list(stype=1 剧集): {} 条，首条={}", by_id.items.len(),
            by_id.items.first().map(|i| i.title.clone()).unwrap_or_default());
        let sid = by_id.items[0].id.clone();
        let d = s.detail(&sid, "").await.expect("detail 应成功");
        eprintln!("[LIVE] detail({sid}): 标题={} 集={} 首集={:?} 描述前 40 字={}",
            d.title, d.episodes.len(),
            d.episodes.first().map(|e| e.title.clone()),
            d.description.as_deref().unwrap_or("").chars().take(40).collect::<String>());
        // Optional live probe observes actual media resolution, not player frames.
        let pe = s.play(&d.episodes[0].flag, &d.episodes[0].id, "").await;
        eprintln!("[LIVE] play 实测: {}", match &pe {
            Ok(v) => format!("解析返回 {} 条媒体候选（未验证首帧）", v.len()),
            Err(e) => format!("如实 Err：{}", e.chars().take(90).collect::<String>()),
        });
    }
}

#[cfg(test)]
#[path = "hxq_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
#[path = "anonymous_decode_live_tests.rs"]
mod anonymous_decode_live_tests;
