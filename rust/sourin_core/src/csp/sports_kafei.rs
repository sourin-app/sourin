// ═══════════════════════════════════════════════════════════════════════
//  csp_SportsKafei —— TVBox `csp_SportsKafei` 的 Rust 重写（纯 HTTP-JSON）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅 8815.kstore.vip/tvbox/wmz 的 ⚽咖啡丨体育直播：
//   {"type":3, "api":"csp_SportsKafei", "ext": null}
// ⇒ **ext 为 null**，所以 base 必须写死（本站只有一个域）。
// ```
//
// # 协议取证（`.probe/decompiled/classes.dex` 直读，**未起 jadx**）
//
// 依据：`.probe/r3-c-strings.json` 里 `SportsKafei` 的 80 条 const-string
// （由 `.probe/r3_dexdump.py` 读 `string_ids` 解析，方法体内扫 `const-string` 指令；
//   **不是**读源码、**不是**反编译产物）。
//
// ```text
// 类       Lcom/github/catvod/spider/SportsKafei;  父类 crawler/Spider
// 成员     6 方法（全部 override API）+ 0 字段
// 端点     ① https://kafeizhibo.cc/api/v1/schedule?type= &page= &size=30   ← 列表
//          ② https://kafeizhibo.cc/api/v1/room/                            ← 详情
// 分类     常量里成对给出 type_id / type_name：  "hot"→热门 · "1"→足球 · "2"→篮球
//          （另有 "class"/"filters"/"url"/"parse"/"header" 这套 TVBox 分类外围字段）
// 请求头   属性逐字： User-Agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
//                    Accept     = "application/json"
// 列表映射 输出 vod_id ← data[].id ／ room_id ← data[].room_id
//          vod_name ← home_team + " VS " + away_team
//          vod_pic  ← home_team_logo
//          vod_remarks ← league_name
//          分页：list / page / pagecount / limit / total
// 详情映射 输入 data.room_info / data.signals
//          vod_name ← room_info.title ／ vod_content ← room_info.league
//          vod_play_url ← signals[].name + "$" + signals[].stream_url，多条用 "#" 连
// 取流模板 {"parse":0,"url":"","header":{}}   ← ★ 原版就是 **parse:0 + 直链**，不经解析器
// ```
//
// # 真网络读数（2026-10-27 15:0x 实测；见 `.probe/r3-g-tier1-evidence.log`）
//
// ```text
// GET /api/v1/schedule?type=1&page=1&size=30     HTTP 200  len=36979  items=30
// GET /api/v1/schedule?type=2&page=1&size=30     HTTP 200  len=36808  items=30
// GET /api/v1/schedule?type=hot&page=1&size=30   HTTP 200  len=36493  items=30
// GET /api/v1/schedule?type=3&page=1&size=30     HTTP 200  len=77     items=0    ← type=3 空
// GET /api/v1/room/42758                         HTTP 200  len=1797
//   room_info.title = "印班超 阿格尼普拉 vs 特克尼克"
//   signals[0].name = "直播1"
//   signals[0].stream_url = "https://hello.ooo0ooo.top/live/4660348.m3u8"   ← 真拿到 m3u8
// ```
//
// ⚠️ **根路径陷阱**（方法学，别踩）：`GET https://kafeizhibo.cc/` 返回 **000**（超时），
//    而 `/api/v1/schedule?type=1` 是 **200**。⇒ 判"上游死活"必须打**真端点**。
//
// # 契约边界（Lead 已裁定）
//
// ```text
// · loadPic ⇒ 本类无取图需求（封面是公开 CDN 的 png，不需额外头）⇒ 不写 cover_headers
// · mProxy  ⇒ ★ 原版有 mProxy（DEX 常量里有 "parse"/"header" 那套），**本批不做**：
//             **已知缺口** —— 部分线路的 CDN 会校验 Referer/UA，需要代理转发才通。
//             当前实现真实反映"不代理"的结果（能直连的线路照常返回）。
// · initApi ⇒ 本仓无该 API；等价物是 `ext` 透传（本类 ext 为 null，不影响）
// · isVideoFormat / manualVideoCheck
//           ⇒ ★ DEX 里 SportsKafei **没有** override 这两个（只有 6 个方法：
//             categoryContent / detailContent / homeContent / init / playerContent
//             + <init>）⇒ **本仓无等价位，未实现**（如实登记，不臆造）
// ```
//
// # 与已实现类的差异（为什么不是"抄一个模板"）
//
// ```text
// · SportsKafei 是**纯 JSON API**（不是 HTML 抓取）⇒ 不需要 regex 解析结构
// · 它是**体育直播**语义：一个"条目"= 一场比赛，"线路"= 各路主播房
//   ⇒ detail() 返回的 episodes 是 `signals`，每条 signal 就是一个直播源
// · 取流是**直链 m3u8**（parse:0）⇒ play() 真的能给出可播地址
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 站点唯一域名。
///
/// DEX 常量里就是这一个（`sub.sites[].ext` 为 null ⇒ 没有多域可轮换）。
const BASE: &str = "https://kafeizhibo.cc";

/// DEX 属性里逐字给出的 UA（**不是**本仓其它类的 Chrome/151 长串）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";

/// 每页条数：DEX 模板 `&size=30` 写死
const PAGE_SIZE: u32 = 30;

const GET_TIMEOUT: Duration = Duration::from_secs(15);

pub struct SportsKafei {
    client: reqwest::Client,
}

impl SportsKafei {
    pub const CLASS: &'static str = "SportsKafei";

    /// 首页分类 —— **逐对来自 DEX 常量**（type_id / type_name）
    ///
    /// # 为什么只有三条
    /// ```text
    /// 常量里成对出现的 type_id/type_name 只有这三组：
    ///   "hot"/"热门" · "1"/"足球" · "2"/"篮球"
    /// ⇒ **不臆造**第四条。真站点对空 type 也回数据（实测 200/30 条），
    ///   但空 type 不是一个"分类名"，所以不列进分类条。
    /// ```
    pub const CATEGORIES: &'static [(&'static str, &'static str)] =
        &[("hot", "热门"), ("1", "足球"), ("2", "篮球")];

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            // DEX 里逐字给出的 Accept
            .default_headers({
                let mut h = reqwest::header::HeaderMap::new();
                h.insert(
                    reqwest::header::ACCEPT,
                    reqwest::header::HeaderValue::from_static("application/json"),
                );
                h
            })
            .timeout(GET_TIMEOUT)
            // 与本仓 csp 既定惯例一致 —— **不读系统代理**
            // ```text
            // 代理会把"站点可用"测成"全宕"（见 `app99.rs:342` 同一条纪律）。
            // ★ 实测依据（Lead 跨批一致性审计发现，我复现并扩面 7/8 类）：
            //   本机装了代理（127.0.0.1:7890）时 `reqwest` 会**默认读系统代理**；
            //   把代理指向死端口 `:9` ⇒ 本类 live **FAILED**
            //   （`home 必须真取到数据`：`error sending request for url …`）；
            //   而同条件下**有** `.no_proxy()` 的类（app99 / app_drama）**仍 ok**。
            //   ⇒ 行为差异被对照实验证实，不能靠"本机代理恰好可用"掩盖。
            // ```
            .no_proxy()
            .build()
            .expect("build SportsKafei http client");
        Self { client }
    }

    async fn get_json(&self, url: &str) -> Result<serde_json::Value, String> {
        let resp = self
            .client
            .get(url)
            .send()
            .await
            .map_err(|e| format!("请求 {url} 失败：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取 {url} 响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "{url} 返回 HTTP {status}（上游拒绝或限流）；响应前 200 字节：{}",
                truncate(&body, 200)
            ));
        }
        serde_json::from_str(&body)
            .map_err(|e| format!("{url} 不是合法 JSON：{e}；响应前 200 字节：{}", truncate(&body, 200)))
    }

    /// 列表：`/api/v1/schedule?type=<t>&page=<n>&size=30`
    async fn fetch_schedule(&self, type_id: &str, page: u32) -> Result<serde_json::Value, String> {
        let page = if page == 0 { 1 } else { page };
        let url = format!(
            "{BASE}/api/v1/schedule?type={type_id}&page={page}&size={PAGE_SIZE}"
        );
        let v = self.get_json(&url).await?;
        check_code(&v, &url)?;
        Ok(v)
    }

    /// 详情：`/api/v1/room/<id>`
    async fn fetch_room(&self, id: &str) -> Result<serde_json::Value, String> {
        let url = format!("{BASE}/api/v1/room/{id}");
        let v = self.get_json(&url).await?;
        check_code(&v, &url)?;
        Ok(v)
    }
}

impl Default for SportsKafei {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数（可 hermetically 单测；网络部分只负责取回 JSON）
// ═══════════════════════════════════════════════════════════════════════

fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// 上游统一信封 `{"code":200,"message":"…","data":…}`
///
/// # 为什么必须查 `code`
/// ```text
/// 实测 HTTP 200 时 code 也是 200；但上游可能用 `{"code":500,"message":"…"}` 配 HTTP 200
/// ⇒ 只看 HTTP 状态会把"业务失败"当成成功 ⇒ 返回空列表 ⇒ **假成功**（本仓明令禁止）。
/// ```
fn check_code(v: &serde_json::Value, url: &str) -> Result<(), String> {
    let code = v.get("code").and_then(|c| c.as_i64());
    match code {
        Some(200) => Ok(()),
        Some(other) => Err(format!(
            "{url} 业务码非 200：code={other}, message={}",
            v.get("message").and_then(|m| m.as_str()).unwrap_or("(无)")
        )),
        None => Err(format!("{url} 响应缺少 code 字段：{}", truncate(&v.to_string(), 200))),
    }
}

/// 列表 JSON → `CspList`
///
/// 字段映射**逐条来自 DEX 常量**（见文件头）。`page_count`/`total` 取自
/// `pagecount`/`total`（上游给的是这两个键）。
pub fn parse_schedule(v: &serde_json::Value, page: u32) -> Result<CspList, String> {
    let data = v
        .get("data")
        .and_then(|d| d.as_array())
        .ok_or_else(|| format!("列表响应没有 data 数组：{}", truncate(&v.to_string(), 200)))?;

    let mut items = Vec::with_capacity(data.len());
    for row in data {
        let id = as_string(row.get("id"))
            .or_else(|| as_string(row.get("room_id")))
            .unwrap_or_default();
        if id.is_empty() {
            continue; // 没有 id 的条目无法进详情 ⇒ 丢掉而不是塞一个假 id
        }
        let home = as_string(row.get("home_team")).unwrap_or_default();
        let away = as_string(row.get("away_team")).unwrap_or_default();
        let title = if home.is_empty() && away.is_empty() {
            // 上游偶尔只给 league_name；宁可退回联盟名也不给空标题
            as_string(row.get("league_name")).unwrap_or_else(|| format!("赛事 {id}"))
        } else {
            format!("{home} VS {away}")
        };
        items.push(CspItem {
            id,
            title,
            cover: as_string(row.get("home_team_logo")).filter(|s| !s.is_empty()),
            subtitle: as_string(row.get("league_name")).filter(|s| !s.is_empty()),
        });
    }

    // ★ 反空真（铁律 149）：候选集为空时"全称断言"恒真 ⇒ 这里显式分两手。
    //   data 非空却一条都映射不出 ⇒ 是**结构变了**（我们的问题），必须报错；
    //   data 本来就是空数组 ⇒ 是**上游这个分类当前没有排期**（正常，返回空）。
    if items.is_empty() && !data.is_empty() {
        return Err(format!(
            "列表有 {} 条数据但一条都映射不出 id ⇒ 上游字段结构可能变了：{}",
            data.len(),
            truncate(&data[0].to_string(), 200)
        ));
    }

    Ok(CspList {
        items,
        page,
        // 上游把分页字段放在**响应顶层**（DEX 常量里 page/pagecount/limit/total
        // 与 list 并列）⇒ 只查顶层，查不到返回 None（**绝不猜**）。
        page_count: v
            .get("pagecount")
            .and_then(|p| p.as_u64())
            .map(|p| p as u32),
        total: v.get("total").and_then(|t| t.as_u64()),
    })
}

/// 详情 JSON → `CspDetail`
///
/// `signals[]` 的每条 = 一条线路；`name` 做线路名、`stream_url` 做地址。
/// 这正对应 DEX 常量里的 `name` / `stream_url` / `#` / `$` 三个拼装常量
/// （`vod_play_url` = `名$址#名$址…`）。
pub fn parse_room(v: &serde_json::Value) -> Result<CspDetail, String> {
    let data = v
        .get("data")
        .ok_or_else(|| format!("详情响应没有 data：{}", truncate(&v.to_string(), 200)))?;
    let info = data.get("room_info").ok_or_else(|| {
        format!("详情响应没有 data.room_info：{}", truncate(&data.to_string(), 200))
    })?;

    let title = as_string(info.get("title"))
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "room_info 里没有 title".to_string())?;

    let league = as_string(info.get("league")).unwrap_or_default();
    let home = as_string(info.get("home_team")).unwrap_or_default();
    let away = as_string(info.get("away_team")).unwrap_or_default();
    let mut description = String::new();
    if !home.is_empty() || !away.is_empty() {
        description.push_str(&format!("{home} VS {away}"));
    }
    if !league.is_empty() {
        if !description.is_empty() {
            description.push_str(" · ");
        }
        description.push_str(&league);
    }
    for (k, label) in [("status", "状态"), ("notice", "公告")] {
        if let Some(val) = as_string(info.get(k)).filter(|s| !s.is_empty()) {
            if !description.is_empty() {
                description.push_str(" · ");
            }
            description.push_str(&format!("{label}：{val}"));
        }
    }

    let mut episodes = Vec::new();
    if let Some(signals) = data.get("signals").and_then(|s| s.as_array()) {
        for (i, sig) in signals.iter().enumerate() {
            let Some(url) = as_string(sig.get("stream_url")).filter(|s| !s.is_empty()) else {
                continue; // 没有 stream_url 的 signal 播不了 ⇒ 不列假线路
            };
            let name = as_string(sig.get("name"))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| format!("线路{}", i + 1));
            episodes.push(CspEpisode {
                id: url,
                title: name,
                // 单线路源填 "默认"；这里是多线路 ⇒ 用上游线路名当 flag，
                // UI 与 play() 都按它取（`CspEpisode.flag` 的用途见 csp/mod.rs）
                flag: "直播".to_string(),
            });
        }
    }

    // ★ 反空真：有 signals 却一条都没 stream_url ⇒ 结构变了（不是"这场没得看"）
    let signal_count = data
        .get("signals")
        .and_then(|s| s.as_array())
        .map(|a| a.len())
        .unwrap_or(0);
    if episodes.is_empty() && signal_count > 0 {
        return Err(format!(
            "有 {signal_count} 条 signals 但都缺 stream_url ⇒ 上游字段结构可能变了：{}",
            truncate(&data.to_string(), 200)
        ));
    }

    Ok(CspDetail {
        id: String::new(),
        title,
        cover: as_string(info.get("avatar"))
            .or_else(|| as_string(info.get("home_team_logo")))
            .filter(|s| !s.is_empty()),
        description: if description.is_empty() { None } else { Some(description) },
        episodes,
    })
}

/// 宽松取值：数字 / 字符串都收（上游对同一字段时而给 `42758`、时而给 `"42758"`）
fn as_string(v: Option<&serde_json::Value>) -> Option<String> {
    match v? {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for SportsKafei {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：分类表（写自 DEX 常量）+ 首屏热门 30 条
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let categories = Self::CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();

        // 首屏取默认（type 空 ⇒ 上游实测回 30 条，与 hot 同量级）
        let v = self.fetch_schedule("hot", 1).await?;
        let items = parse_schedule(&v, 1)?.items;

        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        // ★ 空 tid 显式失败：不把空字符串当"某个默认分类"静默吞掉
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let v = self.fetch_schedule(tid, page).await?;
        let l = parse_schedule(&v, page)?;

        // ★ 反空真：第 1 页一条都没有 ⇒ 这个分类当前真的空（实测 type=3 就是这样）
        //   —— 这**不是**错误，但 catalog 层需要能区分"空分类"与"取数失败"。
        //   这里如实返回空列表，由上层决定（`CspList.items` 为空本身即信号）。
        Ok(l)
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        // id 来自列表项的 `data[].id`（实测 room/42758 就是用这个值命中的）
        let v = self.fetch_room(id).await?;
        let mut d = parse_room(&v)?;
        d.id = id.to_string();
        Ok(d)
    }

    /// 取流
    ///
    /// # 为什么这里能真给出地址（与网盘类的关键差异）
    /// ```text
    /// DEX 常量里取流模板逐字是 `{"parse":0,"url":"…","header":{}}`
    /// ⇒ 原版就是 **parse:0 + 直链**（不经解析器）。实测 signals[].stream_url
    ///   直接就是 `https://hello.ooo0ooo.top/live/<n>.m3u8` ⇒ 我们原样返回。
    /// ```
    /// `id` 就是详情里塞进 `CspEpisode.id` 的那个 stream_url。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if !(id.starts_with("http://") || id.starts_with("https://")) {
            return Err(format!("播放 id 不是 http(s) 地址：{}", truncate(id, 120)));
        }
        // 直链：不需要额外请求头（DEX 的 header 是空对象 `{}`）
        Ok(vec![CspPlay {
            url: id.to_string(),
            headers: Vec::new(),
            label: Some("直播".to_string()),
        }])
    }

    /// DEX 里 SportsKafei **没有** override searchContent（6 个方法里没有它）
    /// ⇒ 如实声明**不支持搜索**（而不是实现一个假的搜索）。
    fn supports_search(&self) -> bool {
        false
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("SportsKafei 不支持搜索（原版 SportsKafei 无 searchContent 实现）".to_string())
    }
}

// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
//
// # 这个类的事实（别丢）
// ```text
// csp_SportsKafei（⚽咖啡丨体育直播）：协议 100% 有依据 + 上游活 + 真拿到 m3u8
//   列表 /api/v1/schedule?type={1|2|hot}&page=N&size=30   HTTP 200 / 30 条
//   详情 /api/v1/room/{id}                                HTTP 200
//   取流 signals[].stream_url = https://hello.ooo0ooo.top/live/4660348.m3u8
// ⚠️ 根路径 kafeizhibo.cc/ = 000（超时），端点才是 200 —— 判死活必须打端点。
// ⚠️ 已知缺口：原版有 mProxy，本批不做（见文件头）⇒ 需代理的线路可能不通。
// ```
crate::csp::register_site!(SportsKafei);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★ 不读系统代理（**跨批一致性**：本仓 csp 既定惯例，见 `app99.rs:342`）
    ///
    /// # 为什么这条必须在"离线门禁"里（而不是 live 里）
    /// ```text
    /// 这条断言的**对象是源码形态**（Client 构造链里有没有 `.no_proxy()`），
    /// 而不是网络结果 ⇒ **不依赖网络、不随上游抖动**。
    ///
    /// ★ 实测背景（Lead 的跨批一致性审计 → 我复现并扩面）：
    ///   · 本机装了代理（`127.0.0.1:7890`，系统代理 Enable=0x1）时，
    ///     `reqwest` 会**默认读系统代理** ⇒ 代理对该站不可用时
    ///     报含糊的 `error sending request for url …`
    ///   · **死代理 `:9` 实测**：本类 live **FAILED**（`home 必须真取到数据` 失败）
    ///     而同期有 `.no_proxy()` 的类（app99 / app_drama）**仍 ok**
    ///     ⇒ 8 类里 **7 例实测坏** + 1 例特殊（`ting_shijie` 的 live 是三态设计、只打印不断言）
    ///   ★ 后一例说明：**这类"环境缺陷"离线门禁是唯一能覆盖的地方**
    ///     （live 只打印读数 ⇒ 既不抓"我们写错"、也不抓"环境坏了"）。
    /// ```
    ///
    /// # 注入（证明本条有牙）
    /// ```text
    /// 删掉 `Client::builder()` 链上的 `.no_proxy()` ⇒ 本条 FAILED。
    /// ★ 注意：断言用的是 `impl_src_only(include_str!(…))` —— **必须先剥掉测试段**，
    ///   否则**本函数自己的字面量**（`".no_proxy()"`）会把门禁自己喂饱 ⇒ **假绿**。
    ///   本仓 `app_yqk.rs` 与 `shared.rs:255` 都踩过这个坑并留档。
    /// ```
    #[test]
    fn client_does_not_read_system_proxy() {
        let src = crate::csp::shared::impl_src_only(include_str!("sports_kafei.rs"));
        assert!(
            src.contains(".no_proxy()"),
            "★ Client 构造链必须含 `.no_proxy()`（不读系统代理）；\
             否则装了代理的机器上会把'站点可用'测成'全宕'"
        );
    }

    /// 真实响应片段（2026-10-27 实测抓下后裁掉无关部分）
    const FIX_SCHEDULE: &str = r#"{
      "code": 200,
      "message": "success",
      "data": [
        {"id": 42758, "match_id": 42758, "league_name": "印班超",
         "home_team": "阿格尼普拉", "away_team": "特克尼克",
         "home_team_logo": "https://cdn.sportnanoapi.com/football/team/e29b3acb.png"}
      ],
      "page": 1, "pagecount": 3, "limit": 30, "total": 61
    }"#;

    const FIX_ROOM: &str = r#"{
      "code": 200, "message": "success",
      "data": {
        "room_info": {"title": "印班超 阿格尼普拉 vs 特克尼克", "league": "印班超",
                      "status": "finished", "home_team": "阿格尼普拉",
                      "away_team": "特克尼克", "notice": "看球收藏 kfzhibo.com 不失联"},
        "signals": [
          {"id": 1, "name": "直播1", "room_id": "1001", "status": "online",
           "stream_url": "https://hello.ooo0ooo.top/live/4660348.m3u8"},
          {"id": 2, "name": "直播2", "room_id": "1002", "status": "online",
           "stream_url": "https://hello.ooo0ooo.top/live/4660349.m3u8"}
        ],
        "external_signals": []
      }
    }"#;

    fn j(s: &str) -> serde_json::Value {
        serde_json::from_str(s).expect("夹具必须是合法 JSON")
    }

    // ── 分类表（判据：逐对来自 DEX 常量）────────────────────────────

    #[test]
    fn categories_come_from_dex_constants() {
        let ids: Vec<&str> = SportsKafei::CATEGORIES.iter().map(|c| c.0).collect();
        assert_eq!(ids, vec!["hot", "1", "2"], "DEX 常量里只有这三组 type_id");
        let names: Vec<&str> = SportsKafei::CATEGORIES.iter().map(|c| c.1).collect();
        assert_eq!(names, vec!["热门", "足球", "篮球"]);
    }

    // ── parse_schedule ────────────────────────────────────────────

    #[test]
    fn schedule_maps_dex_field_names() {
        let l = parse_schedule(&j(FIX_SCHEDULE), 1).expect("真响应片段必须解析得出来");
        assert_eq!(l.items.len(), 1);
        assert_eq!(l.items[0].id, "42758", "数字 id 要收成字符串");
        assert_eq!(l.items[0].title, "阿格尼普拉 VS 特克尼克", "标题 = home VS away");
        assert_eq!(
            l.items[0].cover.as_deref(),
            Some("https://cdn.sportnanoapi.com/football/team/e29b3acb.png")
        );
        assert_eq!(l.items[0].subtitle.as_deref(), Some("印班超"));
        assert_eq!(l.page_count, Some(3), "pagecount 来自上游顶层");
        assert_eq!(l.total, Some(61), "total 来自上游顶层");
    }

    #[test]
    /// ★ 反空真（铁律 149）①：**data 非空但一条都映射不出** ⇒ 必须报错
    ///
    /// 注入：把 `parse_schedule` 里 `items.is_empty() && !data.is_empty()` 那个
    ///       Err 分支删掉 ⇒ 本条立刻红（会得到 Ok(空列表)）。
    fn schedule_with_unmappable_rows_is_error_not_empty_ok() {
        let bad = j(r#"{"code":200,"data":[{"home_team":"甲","away_team":"乙"}]}"#);
        let err = parse_schedule(&bad, 1).unwrap_err();
        assert!(
            err.contains("结构可能变了"),
            "有数据却映射不出 ⇒ 必须报结构问题，不能静默返回空：{err}"
        );
    }

    #[test]
    /// ★ 反空真 ②：**data 本来就是空数组** ⇒ 是"这个分类当前没排期"（正常），返回空
    ///
    /// 这条与上一条**成对**，证明两者被区分开了。
    fn schedule_with_genuinely_empty_data_is_ok_empty() {
        let v = j(r#"{"code":200,"message":"success","data":[]}"#);
        let l = parse_schedule(&v, 1).expect("真·空分类不是错误");
        assert!(l.items.is_empty());
        assert_eq!(l.page, 1);
    }

    #[test]
    /// 上游业务码非 200（HTTP 却是 200）⇒ 必须**显式失败**，不许当成功
    ///
    /// 注入：把 `check_code` 改成恒 `Ok(())` ⇒ 本条红。
    fn business_code_non_200_fails_even_on_http_200() {
        let v = j(r#"{"code":500,"message":"server busy","data":[]}"#);
        let err = check_code(&v, "https://x/y").unwrap_err();
        assert!(err.contains("业务码非 200"), "必须报业务码问题：{err}");
    }

    #[test]
    fn missing_code_field_is_error() {
        let v = j(r#"{"message":"ok","data":[]}"#);
        let err = check_code(&v, "https://x/y").unwrap_err();
        assert!(err.contains("缺少 code"), "缺 code 要报明确原因：{err}");
    }

    #[test]
    fn schedule_without_data_array_is_error() {
        let err = parse_schedule(&j(r#"{"code":200}"#), 1).unwrap_err();
        assert!(err.contains("没有 data 数组"), "{err}");
    }

    // ── parse_room ────────────────────────────────────────────────

    #[test]
    fn room_maps_signals_to_episodes() {
        let d = parse_room(&j(FIX_ROOM)).expect("真响应片段必须解析得出来");
        assert_eq!(d.title, "印班超 阿格尼普拉 vs 特克尼克");
        assert_eq!(d.episodes.len(), 2, "两条 signals = 两条线路");
        assert_eq!(
            d.episodes[0].id,
            "https://hello.ooo0ooo.top/live/4660348.m3u8",
            "★ 关键：stream_url 直接就是可播的 m3u8（parse:0 直链）"
        );
        assert_eq!(d.episodes[0].title, "直播1");
        assert_eq!(d.episodes[1].id, "https://hello.ooo0ooo.top/live/4660349.m3u8");
        let desc = d.description.clone().unwrap_or_default();
        assert!(desc.contains("阿格尼普拉 VS 特克尼克"), "描述要含对阵：{desc}");
        assert!(desc.contains("印班超"), "描述要含联赛：{desc}");
        assert!(desc.contains("看球收藏"), "notice 也要进来：{desc}");
    }

    #[test]
    /// ★ 反空真 ③：**有 signals 但都缺 stream_url** ⇒ 报结构问题，不返回空线路
    ///
    /// 注入：删掉 `episodes.is_empty() && signal_count > 0` 那个 Err ⇒ 本条红。
    fn room_with_signals_but_no_stream_url_is_error() {
        let bad = j(
            r#"{"code":200,"data":{"room_info":{"title":"某场"},
                "signals":[{"id":1,"name":"直播1"}]}}"#,
        );
        let err = parse_room(&bad).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// signals 真为空（还没开播 / 已结束无源）⇒ **不是错误**，返回空线路
    fn room_with_empty_signals_is_ok_empty() {
        let v = j(r#"{"code":200,"data":{"room_info":{"title":"某场"},"signals":[]}}"#);
        let d = parse_room(&v).expect("真·无线路不是错误");
        assert!(d.episodes.is_empty());
        assert_eq!(d.title, "某场");
    }

    #[test]
    fn room_without_title_reports_reason() {
        let bad = j(r#"{"code":200,"data":{"room_info":{"league":"某联赛"},"signals":[]}}"#);
        let err = parse_room(&bad).unwrap_err();
        assert!(err.contains("没有 title"), "{err}");
    }

    #[test]
    fn room_without_room_info_reports_reason() {
        let bad = j(r#"{"code":200,"data":{"signals":[]}}"#);
        let err = parse_room(&bad).unwrap_err();
        assert!(err.contains("room_info"), "{err}");
    }

    // ── 能力位 ────────────────────────────────────────────────────

    #[test]
    fn search_is_declared_unsupported() {
        let s = SportsKafei::new();
        assert!(
            !s.supports_search(),
            "★ DEX 里 SportsKafei 没有 searchContent ⇒ 必须声明 false，不许给假能力位"
        );
    }

    #[tokio::test]
    async fn search_returns_honest_error() {
        let s = SportsKafei::new();
        let err = s.search("足球", 1, "").await.unwrap_err();
        assert!(err.contains("不支持搜索"), "{err}");
    }

    #[tokio::test]
    async fn empty_tid_fails_instead_of_silent_default() {
        let s = SportsKafei::new();
        let err = s.list("  ", 1, "").await.unwrap_err();
        assert!(err.contains("分类 id 为空"), "{err}");
    }

    // ── play（纯函数路径，不联网）────────────────────────────────

    #[tokio::test]
    async fn play_returns_direct_m3u8_as_is() {
        let s = SportsKafei::new();
        let url = "https://hello.ooo0ooo.top/live/4660348.m3u8";
        let plays = s.play("直播", url, "").await.expect("直链必须原样返回");
        assert_eq!(plays.len(), 1);
        assert_eq!(plays[0].url, url, "★ 不许改写直链");
        assert!(plays[0].headers.is_empty(), "DEX 的 header 是空对象");
    }

    #[tokio::test]
    async fn play_rejects_non_http_id() {
        let s = SportsKafei::new();
        let err = s.play("直播", "42758", "").await.unwrap_err();
        assert!(err.contains("不是 http(s) 地址"), "{err}");
    }

    #[tokio::test]
    async fn play_rejects_empty_id() {
        let s = SportsKafei::new();
        let err = s.play("直播", "   ", "").await.unwrap_err();
        assert!(err.contains("播放 id 为空"), "{err}");
    }

    // ── 真网络（默认不跑；显式跑必须给 CSP_LIVE=1，否则**失败**而不是静默通过）──

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib sports_kafei_live --release -- --ignored --nocapture"]
    async fn sports_kafei_live_home_list_detail_play() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = SportsKafei::new();

        let home = s.home("").await.expect("home 必须真取到数据");
        assert_eq!(home.categories.len(), 3);
        assert!(!home.items.is_empty(), "★ 反空真：首屏必须有真条目");

        let list = s.list("1", 1, "").await.expect("足球分类必须真取到数据");
        assert!(!list.items.is_empty(), "★ 反空真：足球分类必须有真条目");
        println!(
            "LIVE list 足球：{} 条，page_count={:?} total={:?}",
            list.items.len(),
            list.page_count,
            list.total
        );

        let id = list.items[0].id.clone();
        let d = s.detail(&id, "").await.expect("详情必须真取到数据");
        assert!(!d.title.is_empty(), "★ 反空真：详情必须有标题");
        println!("LIVE detail {}：title={} 线路={}", id, d.title, d.episodes.len());

        // 有线路 ⇒ 真取一条直链回来（★ 这是"真能播"的证据，不是"接口能返回"）
        if let Some(ep) = d.episodes.first() {
            let plays = s.play(&ep.flag, &ep.id, "").await.expect("直链必须返回");
            assert!(plays[0].url.starts_with("http"), "★ 反空真：必须是真地址");
            println!("LIVE play：{}（线路 {}）", plays[0].url, ep.title);
        } else {
            println!("⚠️ 这一场当前没有 signals（已结束/未开播）—— 如实记录，不算假绿");
        }
    }
}