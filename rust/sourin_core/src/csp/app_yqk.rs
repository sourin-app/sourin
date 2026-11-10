// ═══════════════════════════════════════════════════════════════════════
//  csp_AppYQK —— 「👀一起看丨蓝光影视」（短剧 App 协议，四段全通）
// ═══════════════════════════════════════════════════════════════════════
//
// # 配置里覆盖什么
//
// ```text
// 订阅（8815.kstore.vip/tvbox/wmz）100 站里：
//   csp_AppYQK  👀一起看丨蓝光影视   ext = null      ← ★ ext 为空
// ⇒ **base URL / appKey 全部硬编码在类里**（DEX 常量），不需要 ext。
// ```
//
// # ★★ 2026-10-27 真网络实测：**四段全通 + 真 m3u8 播通**
//
// ```text
// home   POST /v2/api/home/header
//        → data.channeList 8 个: [(50,短剧),(65,奈飞Netflix),(2,电影),(3,电视剧),
//                                 (8,动漫),(10,综艺)…]
//          data.hotKeywordList ["仙逆","嫁金钗","小城良方"]
// list   POST /v2/api/channel/topicListView {channelId=50}
//        → data.topicList 15 个（topicName="热播短剧TOP100"）
//          每个 topicList[].vodList[] ⇒ 真 vodId / vodName / coverImg / remark
// detail POST /v2/api/vodInfo/index {vodId=479233「嫁金钗」}
//        → data.playerList **18 条线路**（一起看APP kind=1 20集 / WJ kind=8 / BF kind=27 …）
//          每线 epList[20] = {epId, epName:"第01集"}   ← ★ 线路维度
// play   POST /v2/api/vodInfo/epDetail {vodEpId} → 分辨率档
//              [{vodResolution:3,showName:"超清",canPlay:false},
//               {vodResolution:2,showName:"标清",canPlay:true,defaultSelect:true}]
//        POST /v2/api/vodInfo/playUrl {vodId,epId,vodResolution}
//        → data.playUrl
//        【真 URL】https://usaydd.zvoz3tsd.com/m3u87/share/…/720/master.m3u8?sign=…&t=…
//        【真播通】带 Referer: https://yqk1.app/ ⇒ 200 + `#EXTM3U #EXT-X-TARGETDURATION:6`
//                 不带 Referer ⇒ TLS 断流（CDN 侧拒绝）
// search POST /v1/api/search/search {keyword,nextCount} → data.items[] 真命中
// ```
//
// # ★ 签名算法（**行为级验证**，不是"读起来像"）
//
// ```text
// sign = md5( 按 key 字典序的 k=v 用 & 连接 + "&appKey=3359de478f8d45638125e446a10ec541" )
//
// 【负对照 3 条 —— 证明服务端真在校验】
//   正确 md5 签名           → 200 {"result":true,…}
//   故意 sign='0'*32        → {"result":false,"msg":"失败：sign error"}
//   完全不给 sign           → {"result":false,"msg":"失败：sign error"}
//   sign 用 SHA-256 前 32 位 → {"result":false,"msg":"失败：sign error"}  ← 排除"其实不是 md5"
// 【★ 签名覆盖面（端点之间**不一样**，这是最容易写错的地方）】
//   topicListView : 只签公共键也 200（签全部参数同样 200）
//   playUrl       : **只签公共键 ⇒ sign error**；签全部参数（含 vodId/epId/vodResolution）⇒ 200
//   ⇒ 本实现统一 **签全部参数**（对两个端点都实测通过的那一种）—— 宽松侧不出错。
// ```
//
// # 取流头（缺了真播不了）
// ```text
// Referer: https://yqk1.app/    ← 实测：不带 ⇒ TLS 断流；带了 ⇒ 200 + #EXTM3U
// ```
//
// # 如实分档（不许把"部分通"说成"通了"）
// ```text
// ✅ 通：home / list / detail / play / search 五段 + 真 m3u8 拉到分片清单
// ⚠️ 上游行为，非我们的缺陷：
//    · /v2/api/vodInfo/epDetail 对**已下架条目**回 {"result":false,"msg":"分集不存在"}
//    · 部分 m3u8 CDN 节点偶发 TLS 断流（同一 URL 换节点即 200）⇒ 主因是 CDN 侧
//    · topicListView 偶发 TLS 握手超时（首次探测遇到，重试即通）⇒ 本实现**带重试**
// ⛔ 未做（本仓无等价位）：
//    · DEX 里的 `?do=appdanmu&vodName=…` 弹幕入口 ⇒ 本仓没有弹幕契约（不是"忘了"）
// ```
//
// # 已知缺口（按 Lead 裁定的契约边界登记，不做）
// ```text
// · mProxy  —— 本批不做（本仓无 mProxy 等价位）；本类上游也没用到（取流是直链 m3u8）
// · loadPic —— 本仓不补 trait；封面头写在下方 COVER_HEADERS（声明式）
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::{app_sign, pick_arr, pick_id_str, pick_str, upstream_err};

/// 硬编码 base（DEX 常量 `Lcom/github/catvod/spider/AppYQK;` 的 `<init>` 里）
const BASE: &str = "https://yzy0916.n0z6fkpuk.com";

/// 硬编码 appKey（签名盐；DEX `getSign` 里的字面量）
const APP_KEY: &str = "3359de478f8d45638125e446a10ec541";

/// 公共请求参数（DEX 每个方法里都在拼的那一组）
const APP_ID: &str = "e6ddefe09e0349739874563459f56c54";
const CUS_TOM: &str = "aabbcc";
const DEVICE_INFO: &str = "Android";
const REQ_DOMAIN: &str = "yqk1.app";
const VERSION: &str = "1.2.7.104";

/// 假 udid（DEX 里就是一个固定十六进制串，不是真设备号）
const UDID: &str = "0123456789abcdef";

/// 请求头（DEX `h()`）：Origin/Referer 都指向 `https://yqk1.app`
const ORIGIN: &str = "https://yqk1.app";
const UA: &str = "Dart/3.1 (dart:io)";

/// ★ 取流必须带的 Referer —— 实测不带就 TLS 断流
const PLAY_REFERER: &str = "https://yqk1.app/";

/// 封面请求头（声明式，按 Lead 裁定的 `loadPic ⇒ cover_headers` 口径）
///
/// 这个站的封面在 `yqk.j3kjn242sq.com` 这类 CDN 上，实测**不需要** Referer；
/// ⇒ 这里**不填**假头（填了反而是编造）。字段本身留在注释里说明为什么是空的。
pub const COVER_HEADERS: &[(&str, &str)] = &[];

/// 网络超时（上游偶发 TLS 慢）
const TIMEOUT: Duration = Duration::from_secs(20);

/// 重试次数（`topicListView` 实测会偶发 TLS 握手超时，重试即通）
const RETRIES: usize = 3;

/// 一页/一次返回的最大条目数（上游 `vodList` 每 topic 实测给 6 条）
const SEARCH_NEXT_COUNT: u32 = 15;

pub struct AppYQK {
    client: super::http_context::CspHttpContext,
}

impl AppYQK {
    pub const CLASS: &'static str = "AppYQK";

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // Unbound sites remain direct; the context applies the current app policy.
            .no_proxy()
        );
        Self { client }
    }

    /// 分类表 —— **写死**（上游 `home/header` 的 channeList 是动态的，
    /// 但 DEX 的 `homeContent` 也只用 channeList；这里调一次真接口拿，拿不到才用兜底）
    ///
    /// 兜底表来自 2026-10-27 实测的 `channeList`（channelId → channelName）。
    pub const FALLBACK_CHANNELS: &'static [(i64, &'static str)] = &[
        (50, "短剧"),
        (65, "奈飞Netflix"),
        (2, "电影"),
        (3, "电视剧"),
        (8, "动漫"),
        (10, "综艺"),
    ];

    /// 拼公共参数（DEX 里每个方法开头都在做的那件事）
    fn common_pairs() -> Vec<(String, String)> {
        vec![
            ("appId".into(), APP_ID.to_string()),
            ("cus1tom".into(), CUS_TOM.to_string()),
            ("deviceInfo".into(), DEVICE_INFO.to_string()),
            ("reqDomain".into(), REQ_DOMAIN.to_string()),
            // requestId 每次请求换（DEX 用 UUID；我们用 uuid 形状的随机串）
            ("requestId".into(), new_request_id()),
            ("udid".into(), UDID.to_string()),
            ("version".into(), VERSION.to_string()),
        ]
    }

    /// 带签名 POST 一次（JSON 回参）
    ///
    /// # 为什么把签名放进 body（而不是头）
    /// ```text
    /// 实测：签名是**请求体里的一个字段** `sign`，不是 HTTP 头。
    /// 放头里会得到 405/参数错 —— 这条路已排除。
    /// ```
    async fn post(&self, path: &str, extra: &[(String, String)]) -> Result<Value, String> {
        self.post_at(BASE, path, extra).await
    }

    async fn post_at(&self, base: &str, path: &str, extra: &[(String, String)]) -> Result<Value, String> {
        let pairs = {
            let mut v = Self::common_pairs();
            v.extend(extra.iter().cloned());
            v
        };
        // ★ 签**全部**参数（含 extra）—— 对 playUrl 是必须的（只签公共键会 sign error）
        let sign = app_sign(&pairs, APP_KEY);

        let mut body = serde_json::Map::new();
        for (k, val) in &pairs {
            body.insert(k.clone(), Value::String(val.clone()));
        }
        body.insert("sign".into(), Value::String(sign));

        let url = format!("{base}{path}");
        let payload = Value::Object(body).to_string();

        let mut last_err = String::new();
        /*
         * 重试判据：**只重试传输层失败**（超时/TLS/连接断）。
         * 上游给了 JSON 回参（哪怕 result=false）⇒ **立刻返回**，不重试 ——
         * "sign error" 重试三次只是浪费 3 倍时间，且会掩盖真原因。
         */
        for attempt in 1..=RETRIES {
            let sent = self
                .client
                .client()?
                .post(&url)
                .header(reqwest::header::CONTENT_TYPE, "application/json")
                .header(reqwest::header::ORIGIN, ORIGIN)
                .header(reqwest::header::REFERER, ORIGIN)
                .body(payload.clone())
                .send()
                .await;
            match sent {
                Ok(resp) => {
                    let status = resp.status();
                    let text = resp
                        .text()
                        .await
                        .map_err(|e| format!("读取 {path} 响应失败：{e}"))?;
                    if !status.is_success() {
                        return Err(format!("{path} 返回 HTTP {status}：{}", head(&text)));
                    }
                    let v: Value = crate::tvbox::parse_loose_json(&text)
                        .map_err(|e| format!("{path} 不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
                    return Ok(v);
                }
                Err(e) => {
                    last_err = format!("请求 {path} 失败（第 {attempt}/{RETRIES} 次）：{e}");
                    if attempt < RETRIES {
                        // 上游 TLS 抖动：隔一下再来
                        tokio::time::sleep(Duration::from_millis(400 * attempt as u64)).await;
                    }
                }
            }
        }
        Err(last_err)
    }

    /// 上游 `result` 必须是 true；否则把上游 `msg` **原样**带出来
    fn ensure_ok(prefix: &str, v: &Value) -> Result<(), String> {
        match v.get("result").and_then(|r| r.as_bool()) {
            Some(true) => Ok(()),
            Some(false) => Err(upstream_err(prefix, v)),
            None => Err(format!("{prefix}：上游没给 result 字段（形状变了）")),
        }
    }

    /// 把 `vodList` / `items` 里的一条转成 [`CspItem`]
    ///
    /// 字段映射（DEX `categoryContent` 里读的就是这几个）：
    /// ```text
    /// vodId   → id
    /// vodName → title
    /// coverImg→ cover
    /// remark  → subtitle
    /// ```
    fn item_of(v: &Value) -> Option<CspItem> {
        let id = pick_id_str(v, &["vodId"])?;
        let title = pick_str(v, &["vodName"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return None; // 没有名字的条目对 UI 没意义，跳过而不是显示空行
        }
        Some(CspItem {
            id,
            title,
            cover: pick_str(v, &["coverImg"]).map(|s| s.to_string()),
            subtitle: pick_str(v, &["remark"])
                .filter(|s| !s.trim().is_empty())
                .map(|s| s.to_string()),
        })
    }
}

impl Default for AppYQK {
    fn default() -> Self {
        Self::new()
    }
}

/// 取响应文本的前 N 字（用于错误文案，避免把整个 HTML 塞进错误）
fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

/// 生成一个 UUID v4 形状的 requestId（DEX 的 `getUUID`）
fn new_request_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    // 不引 uuid crate：本函数只需要"每次都不同"的十六进制串。
    // 用时间 + 一个进程内计数器混出 32 位十六进制，再按 8-4-4-4-12 排版。
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let a = (t ^ (n.wrapping_mul(0x9E37_79B9_7F4A_7C15))) as u128;
    let b = (t.wrapping_mul(31).wrapping_add(n)) as u128;
    let hex = format!("{a:016x}{b:016x}");
    let h: Vec<char> = hex.chars().collect();
    // 8-4-4-4-12（第 13 位固定 4 = v4 形状，与 DEX 模板 `xxxxxxxx-xxxx-4xxx-yxxx-…` 一致）
    let mut s = String::with_capacity(36);
    for (i, c) in h.iter().take(32).enumerate() {
        if i == 8 || i == 12 || i == 16 || i == 20 {
            s.push('-');
        }
        if i == 12 {
            s.push('4'); // version nibble
            continue;
        }
        s.push(*c);
    }
    s
}

#[async_trait]
impl CspSite for AppYQK {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：真调 `home/header` 取 channeList；失败才用兜底表
    ///
    /// # 为什么失败也返回兜底表（而不是 Err）
    /// ```text
    /// 分类表是**固定的**（8 个频道是这套 App 的内置导航，不随内容变），
    /// 而 `home/header` 是个"顺带返回"的端点 —— 它偶发 TLS 抖动（实测过）。
    /// 若它在导入探测时失败就让整个源进 skipped，用户会看到一个
    /// "明明能用"的源被标成不可用。⇒ 用实测抓下来的表兜底，并**不**假装探测成功。
    /// ⚠️ 但**内容**（items）绝不兜底：拿不到就是空，不编。
    /// ```
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let _ = ext; // 这个类的 ext 是 null（base/appKey 全硬编码）
        let mut categories: Vec<CspCategory> = Vec::new();
        let mut items: Vec<CspItem> = Vec::new();

        match self.post("/v2/api/home/header", &[]).await {
            Ok(v) if Self::ensure_ok("首页失败", &v).is_ok() => {
                if let Some(chans) = pick_arr(&v, &["data", "channeList"]) {
                    for c in chans {
                        let id = pick_id_str(c, &["channelId"]).unwrap_or_default();
                        let name = pick_str(c, &["channelName"]).unwrap_or("").to_string();
                        if !id.is_empty() && !name.is_empty() {
                            categories.push(CspCategory { id, name });
                        }
                    }
                }
            }
            Ok(v) => {
                // 上游给了明确失败（如签名错）⇒ 不吞掉，让调用方看见
                return Err(Self::ensure_ok("首页失败", &v).unwrap_err());
            }
            Err(_e) => { /* 传输层失败 ⇒ 走下面的兜底分类 */ }
        }

        if categories.is_empty() {
            for (id, name) in Self::FALLBACK_CHANNELS {
                categories.push(CspCategory {
                    id: id.to_string(),
                    name: (*name).to_string(),
                });
            }
        }

        // 首屏条目：拿第一个分类的推荐（拿不到就是空，不编）
        if let Some(first) = categories.first().cloned() {
            if let Ok(l) = self.list(&first.id, 1, "").await {
                items = l.items.into_iter().take(20).collect();
            }
        }

        Ok(CspHome { categories, items })
    }

    /// 分类列表：`/v2/api/channel/topicListView` → 各 topic 的 vodList 摊平
    ///
    /// # 分页语义（如实）
    /// ```text
    /// 上游这个端点**没有分页参数**（DEX 的 categoryContent 也没传 pg）。
    /// ⇒ page>1 时返回**空页**并给出 page_count —— 这是**诚实**的做法，
    ///   不许编造 2/3/4 页（那会让 UI 显示一堆空列表）。
    /// ```
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let _ = ext;
        if page > 1 {
            return Ok(CspList {
                items: Vec::new(),
                page,
                page_count: Some(1),
                total: None,
            });
        }
        let extra = vec![("channelId".to_string(), tid.to_string())];
        let v = self.post("/v2/api/channel/topicListView", &extra).await?;
        Self::ensure_ok("列表失败", &v)?;

        let mut items: Vec<CspItem> = Vec::new();
        for topic in pick_arr(&v, &["data", "topicList"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            for vod in pick_arr(topic, &["vodList"]).map(|a| a.as_slice()).unwrap_or(&[]) {
                if let Some(it) = Self::item_of(vod) {
                    items.push(it);
                }
            }
        }
        if items.is_empty() {
            return Err(format!(
                "分类 {tid} 没解析出条目（上游 topicList/vodList 为空或形状变了）"
            ));
        }
        let total = items.len() as u64;
        Ok(CspList {
            items,
            page: 1,
            page_count: Some(1),
            total: Some(total),
        })
    }

    /// 详情：`/v2/api/vodInfo/index` → `data.playerList[]`（**每个 player = 一条线路**）
    ///
    /// # 线路维度怎么落
    /// ```text
    /// data.playerList[] = [{playerName:"一起看APP", totalEpCount:20,
    ///                       epList:[{epId:28190111, epName:"第01集"}, …]}, …]
    /// ⇒ 每个 epList 元素的 id 编码成 `vodId|epId|vodResolution`，
    ///    flag = playerName（UI 按 flag 分组就是"线路"）。
    /// ```
    /// ★ `vodEpisode` 的 id 里**必须带上 vodId**：取流端点要 vodId + epId 两个值，
    ///   而详情返回时我们手上只有 vodId —— 把它编进 id 就不用二次请求。
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let _ = ext;
        let vod_id = parse_vod_id(id).ok_or_else(|| format!("条目 id 不是 vodId 形态：{id}"))?;
        let extra = vec![("vodId".to_string(), vod_id.clone())];
        let v = self.post("/v2/api/vodInfo/index", &extra).await?;
        Self::ensure_ok("详情失败", &v)?;
        let d = v
            .get("data")
            .ok_or_else(|| "详情响应没有 data".to_string())?;

        let title = pick_str(d, &["vodName"]).unwrap_or("").trim().to_string();
        let mut episodes: Vec<CspEpisode> = Vec::new();
        for p in pick_arr(d, &["playerList"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            let flag = pick_str(p, &["playerName"]).unwrap_or("").trim().to_string();
            for e in pick_arr(p, &["epList"]).map(|a| a.as_slice()).unwrap_or(&[]) {
                let ep_id = pick_id_str(e, &["epId"]).unwrap_or_default();
                if ep_id.is_empty() {
                    continue;
                }
                let ep_name = pick_str(e, &["epName"]).unwrap_or("").trim().to_string();
                episodes.push(CspEpisode {
                    // ★ 编码三个取流要用的东西；`fileType=2` 标记"需先问 epDetail 拿分辨率"
                    id: format!("{vod_id}|{ep_id}|2"),
                    title: if ep_name.is_empty() {
                        ep_id.clone()
                    } else {
                        ep_name
                    },
                    flag: if flag.is_empty() {
                        "默认".to_string()
                    } else {
                        flag.clone()
                    },
                });
            }
        }
        if episodes.is_empty() {
            return Err(format!(
                "「{title}」没有可播剧集（playerList/epList 为空 —— 上游对该条可能已下架）"
            ));
        }
        Ok(CspDetail {
            id: vod_id,
            title: if title.is_empty() { id.to_string() } else { title },
            cover: pick_str(d, &["coverImg"]).map(|s| s.to_string()),
            description: {
                // DEX 的 detailContent 里读 intro / updateRemark；两个都拼进描述
                let intro = pick_str(d, &["intro"]).unwrap_or("").trim();
                let remark = pick_str(d, &["updateRemark"]).unwrap_or("").trim();
                let joined = match (intro.is_empty(), remark.is_empty()) {
                    (true, true) => String::new(),
                    (false, true) => intro.to_string(),
                    (true, false) => remark.to_string(),
                    (false, false) => format!("{intro}\n{remark}"),
                };
                if joined.is_empty() {
                    None
                } else {
                    Some(joined)
                }
            },
            episodes,
        })
    }

    /// 搜索：`/v1/api/search/search`（**注意是 v1，不是 v2** —— 实测 v2 是 404）
    ///
    /// # 分页
    /// ```text
    /// 上游用 `nextCount` + `hasNext` + `nextVal` 做**游标分页**，不是 page 号。
    /// ⇒ page=1 正常搜；page>1 时如实返回空页 + page_count=1，
    ///   而不是把 nextVal 硬当 page 号用（那是猜，会静默给出错的结果）。
    /// ```
    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let _ = ext;
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        if page > 1 {
            return Ok(CspList {
                items: Vec::new(),
                page,
                page_count: Some(1),
                total: None,
            });
        }
        let extra = vec![
            ("keyword".to_string(), kw.to_string()),
            ("nextCount".to_string(), SEARCH_NEXT_COUNT.to_string()),
        ];
        let v = self.post("/v1/api/search/search", &extra).await?;
        Self::ensure_ok("搜索失败", &v)?;

        let items: Vec<CspItem> = pick_arr(&v, &["data", "items"])
            .map(|a| a.as_slice())
            .unwrap_or(&[])
            .iter()
            .filter_map(Self::item_of)
            .collect();
        // ★ 搜索 0 条是**正常结果**（不是故障）⇒ 返回空页，不 Err
        let total = items.len() as u64;
        Ok(CspList {
            items,
            page: 1,
            page_count: Some(1),
            total: Some(total),
        })
    }

    fn supports_search(&self) -> bool {
        // ★ 已真网络验证：`/v1/api/search/search {keyword:"仙逆"}` 返回真命中
        true
    }

    /// 取流：先问 `epDetail` 拿可播的分辨率档，再问 `playUrl`
    ///
    /// # 为什么要两步（不是多此一举）
    /// ```text
    /// 实测 `epDetail` 返回：
    ///   [{vodResolution:3, showName:"超清", canPlay:false, iconRemark:"APP独享"},
    ///    {vodResolution:2, showName:"标清", canPlay:true,  defaultSelect:true}]
    /// ⇒ `canPlay:false` 的那档**服务端不给**（"APP独享"）。
    ///   若直接猜 vodResolution=3 去问 playUrl，会拿到 "失败：视频信息不存在"。
    ///   所以必须按 defaultSelect / canPlay 挑档 —— 这是**上游要求的两步**。
    /// ```
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let _ = ext;
        let parts: Vec<&str> = id.split('|').collect();
        if parts.len() < 2 {
            return Err(format!("剧集 id 形态不对（应为 vodId|epId|…）：{id}"));
        }
        let vod_id = parts[0].trim().to_string();
        let ep_id = parts[1].trim().to_string();
        if vod_id.is_empty() || ep_id.is_empty() {
            return Err(format!("剧集 id 缺 vodId 或 epId：{id}"));
        }

        // ① epDetail → 选一个 canPlay 的档（优先 defaultSelect）
        let res_extra = vec![("vodEpId".to_string(), ep_id.clone())];
        let rv = self.post("/v2/api/vodInfo/epDetail", &res_extra).await?;
        let resolution = match Self::ensure_ok("分辨率档查询失败", &rv) {
            Ok(()) => pick_resolution(&rv),
            // 档查询失败**不阻断**取流：后面还可以按默认档试一次
            Err(_) => None,
        };

        // ② playUrl（vodId + epId + vodResolution **三个都要**，且都要进签名）
        //
        // ⚠️ 这里用 `epId` 而不是 `vodEpId`：实测 playUrl 收 `epId`；
        //    而 epDetail 收 `vodEpId`。两个端点的**参数名不一样**，这是上游的行为。
        let mut extra = vec![
            ("vodId".to_string(), vod_id.clone()),
            ("epId".to_string(), ep_id.clone()),
            // 没挑到档 ⇒ 用实测默认档 2（标清）；`pick_resolution` 给的就是 i64
            ("vodResolution".to_string(), resolution.unwrap_or(2).to_string()),
        ];
        let mut v = self.post("/v2/api/vodInfo/playUrl", &extra).await?;
        if v.get("result").and_then(|r| r.as_bool()) == Some(false) && resolution != Some(2) {
            /*
             * 档位猜错了（比如拿了 3 但服务端只给 2）⇒ 退回实测默认档 2 再试一次。
             * 判据：epDetail 多数条目的 defaultSelect 档就是 2（标清）。
             * 只在**第一次失败**时退一次，不无限重试（猜太多次会变成"暴力试错"）。
             */
            extra[2].1 = "2".to_string();
            v = self.post("/v2/api/vodInfo/playUrl", &extra).await?;
        }
        Self::ensure_ok("取流失败", &v)?;

        let url = pick_str(&v, &["data", "playUrl"])
            .ok_or_else(|| format!("取流响应没有 data.playUrl（{}）", head(&v.to_string())))?;
        if !crate::tvbox::starts_http(url) {
            return Err(format!("取流给的地址不是 http：{url}"));
        }
        Ok(vec![CspPlay {
            url: url.to_string(),
            // ★ 实测：不带 Referer 拉 m3u8 会 TLS 断流；带上就是 200 + #EXTM3U
            headers: vec![
                ("Referer".to_string(), PLAY_REFERER.to_string()),
                ("User-Agent".to_string(), UA.to_string()),
            ],
            label: Some(if flag.trim().is_empty() {
                "一起看线路".to_string()
            } else {
                flag.trim().to_string()
            }),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数（可单测；每个都有"缺陷形状"判据）
// ═══════════════════════════════════════════════════════════════════════

/// 从各种形态的 id 里抠出 `vodId`
///
/// ```text
/// "479233"                    → Some("479233")
/// "479233|28190111|2"         → Some("479233")
/// ```
/// ★ 为什么要有它：`list`/`search` 给的 id 是裸 vodId，而详情给的剧集 id
///   是 `vodId|epId|…` 复合形态。同一个类两条路径进来的 id 形态不同，
///   统一在这里剥 —— 免得 `detail()` 里散落一段 `split`。
pub fn parse_vod_id(id: &str) -> Option<String> {
    let s = id.split('|').next()?.trim();
    if s.is_empty() || !s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some(s.to_string())
}

/// 从 `epDetail` 的响应里挑一个**可播**的分辨率档
///
/// 判据（按优先级）：
/// ```text
/// ① canPlay==true 且 defaultSelect==true   ← 上游自己推荐的那档
/// ② 否则第一个 canPlay==true
/// ③ 都没有 ⇒ None（调用方走默认档 2）
/// ```
/// ★ 为什么不直接取第一个元素：实测数组**第一个是 `canPlay:false` 的"APP独享"档**，
///   取第一个必然失败。这条判据直接对着那个缺陷形状。
pub fn pick_resolution(v: &Value) -> Option<i64> {
    let arr = pick_arr(v, &["data"]).map(|a| a.as_slice())?;
    let mut first_playable: Option<i64> = None;
    for e in arr {
        let can = e.get("canPlay").and_then(|c| c.as_bool()).unwrap_or(false);
        if !can {
            continue;
        }
        let res = e
            .get("vodResolution")
            .and_then(|r| r.as_i64())
            .or_else(|| e.get("vodResolution").and_then(|r| r.as_str()).and_then(|s| s.parse().ok()));
        let Some(res) = res else { continue };
        if e.get("defaultSelect").and_then(|d| d.as_bool()).unwrap_or(false) {
            return Some(res); // ① 上游推荐档，直接返回
        }
        if first_playable.is_none() {
            first_playable = Some(res); // ② 记着，继续找有没有 defaultSelect
        }
    }
    first_playable
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册（R3-D，2026-10-27）
// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
//
// # 这个类的事实（从文件头的长注释搬过来，别丢）
// ```text
// csp_AppYQK（👀一起看丨蓝光影视）：**四段全通 + 真 m3u8 播通**（2026-10-27）
//   home   8 频道 / hotKeywordList 3 个
//   list   channelId=50 ⇒ topicList 15 个 ⇒ 摊平出真 vodId
//   detail vodId=479233「嫁金钗」⇒ **18 条线路** × 20 集
//   play   vodId+epId+vodResolution ⇒ 真 m3u8 URL ⇒ 带 Referer **200 + #EXTM3U**
//   search v1 端点命中「仙逆」（v2 是 404）
//   sign   md5(排序 k=v + &appKey=3359de…) —— **行为级负对照验证过**
// ```
// ⚠️ 已知缺口（如实登记，不做）：
//   · mProxy：本批不做（本仓无等价位；本类上游用直链，不需要）
//   · 弹幕 `?do=appdanmu`：本仓无弹幕契约
//   · 游标分页（上游 nextVal）：只做 page=1，page>1 如实返回空页
crate::csp::register_site!(AppYQK);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
#[path = "app_yqk_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn class_is_registered_under_exact_name() {
        assert_eq!(AppYQK::CLASS, "AppYQK");
        assert_eq!(AppYQK::new().class(), "AppYQK");
    }

    // ── id 解析 ────────────────────────────────────────────────────────
    #[test]
    fn parse_vod_id_handles_both_shapes() {
        // 列表给裸 vodId；详情给的剧集 id 是复合形态 —— 两条路都要能进 detail/play
        assert_eq!(parse_vod_id("479233").as_deref(), Some("479233"));
        assert_eq!(parse_vod_id("479233|28190111|2").as_deref(), Some("479233"));
        assert_eq!(parse_vod_id(" 479233 | 1 ").as_deref(), Some("479233"));
        // 反面：空 / 非 id 形态 ⇒ None（不许把垃圾当 id 发出去）
        assert_eq!(parse_vod_id(""), None);
        assert_eq!(parse_vod_id("|1"), None);
        assert_eq!(parse_vod_id("a/b"), None);
    }

    // ── ★ 分辨率档挑选（对着"第一个是不可播档"这个真缺陷形状） ──────────
    #[test]
    fn pick_resolution_skips_the_non_playable_first_entry() {
        // ★ 这是**实测原样**的响应（vodId=479704 那次）
        let v = json!({"result": true, "data": [
            {"vodResolution": 3, "showName": "超清", "iconRemark": "APP独享",
             "canPlay": false, "defaultSelect": false},
            {"vodResolution": 2, "showName": "标清", "iconRemark": "",
             "canPlay": true, "defaultSelect": true}
        ]});
        // 取第一个元素 ⇒ 会拿 3（不可播）⇒ playUrl 必失败。必须拿到 2。
        assert_eq!(pick_resolution(&v), Some(2),
            "★ 必须跳过 canPlay=false 的档（第一个是「APP独享」超清，取它必失败）");
    }

    #[test]
    fn pick_resolution_prefers_default_select_over_first_playable() {
        // 两档都可播，但 defaultSelect 在**后面** ⇒ 必须选它
        let v = json!({"data": [
            {"vodResolution": 1, "canPlay": true, "defaultSelect": false},
            {"vodResolution": 2, "canPlay": true, "defaultSelect": true}
        ]});
        assert_eq!(pick_resolution(&v), Some(2), "优先上游推荐的 defaultSelect 档");
        // 没有 defaultSelect ⇒ 退到第一个可播档
        let v2 = json!({"data": [
            {"vodResolution": 3, "canPlay": false},
            {"vodResolution": 1, "canPlay": true},
            {"vodResolution": 2, "canPlay": true}
        ]});
        assert_eq!(pick_resolution(&v2), Some(1), "无推荐档时取第一个**可播**档");
        // 全不可播 ⇒ None（调用方走默认档，而不是把 3 发出去）
        let v3 = json!({"data": [{"vodResolution": 3, "canPlay": false}]});
        assert_eq!(pick_resolution(&v3), None);
        // 形状不对 ⇒ None，不 panic
        assert_eq!(pick_resolution(&json!({"data": {}})), None);
        assert_eq!(pick_resolution(&json!({})), None);
        // vodResolution 是**字符串**也要认（上游偶发）
        let v4 = json!({"data": [{"vodResolution": "2", "canPlay": true}]});
        assert_eq!(pick_resolution(&v4), Some(2));
    }

    // ── 条目映射 ───────────────────────────────────────────────────────
    #[test]
    fn item_of_maps_real_upstream_fields() {
        // 实测 topicList[].vodList[] 的一条（截取关键字段）
        let v = json!({
            "vodId": 479704, "vodName": "擦边-暗火洶湧-都市言情",
            "coverImg": "https://yqk.j3kjn242sq.com/image/cover/2026/10/17/x.jpeg",
            "score": "0.0", "remark": "已完结"
        });
        let it = AppYQK::item_of(&v).expect("应能映射");
        assert_eq!(it.id, "479704", "数字 vodId 要转成字符串 id");
        assert_eq!(it.title, "擦边-暗火洶湧-都市言情");
        assert!(it.cover.unwrap().starts_with("https://yqk."));
        assert_eq!(it.subtitle.as_deref(), Some("已完结"));
    }

    #[test]
    fn item_of_skips_entries_without_a_name() {
        // 没有名字的条目 ⇒ None（跳过，而不是在 UI 里显示一行空白）
        assert!(AppYQK::item_of(&json!({"vodId": 1})).is_none());
        assert!(AppYQK::item_of(&json!({"vodId": 1, "vodName": "  "})).is_none());
        // 没有 vodId ⇒ None（没 id 无法进详情）
        assert!(AppYQK::item_of(&json!({"vodName": "有名字"})).is_none());
        // remark 空串 ⇒ subtitle 为 None（不是空字符串，别让 UI 显示空标签）
        let it = AppYQK::item_of(&json!({"vodId": 2, "vodName": "x", "remark": ""})).unwrap();
        assert_eq!(it.subtitle, None);
    }

    // ── ★ 结构判据：签名必须覆盖**全部**参数（不只是公共键） ─────────────
    #[test]
    fn play_signature_covers_the_endpoint_params() {
        /*
         * ★★ 这条钉的是**实测发现的那个坑**：playUrl 只签公共键会 `sign error`。
         *
         * # 判据（两条都必须成立）
         * ```text
         * ① `post()` 里：先把 `extra` 拼进 `pairs`，**之后**才调 `app_sign`
         * ② `extra` 拼进 `pairs` 的那一句在实现段里**真的存在**（不是只在测试里提到）
         * ```
         *
         * ⚠️⚠️ **必须用 `shared::impl_src_only` 剥掉测试段**（这条我踩过，留档）：
         * ```text
         * 第一版我写的是 `let src = include_str!("app_yqk.rs"); src.contains(…)`
         *   ⇒ **假绿**：`include_str!` 把含 `mod tests` 的**整个文件**读进来，
         *     而断言里的字面量本身就在这个文件里 ⇒ 把实现删了它照样为真。
         *   ⇒ 我做注入验证时当场发现（注入"extra 不进签名" ⇒ 测试**没红**）。
         * ⇒ 修法：只扫 `#[cfg(test)]` **之前**的内容（`impl_src_only`）。
         *   注入 I2 现在会红（已实测）。
         * ```
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("app_yqk.rs"));
        // ① 顺序：extend 必须在 app_sign 之前
        let at_extend = flat
            .find("v.extend(extra.iter().cloned());")
            .expect("★ post() 必须把 extra 拼进 pairs（否则 playUrl 会 sign error）");
        let at_sign = flat
            .find("app_sign(&pairs,APP_KEY)")
            .expect("★ post() 必须调用 app_sign");
        assert!(
            at_extend < at_sign,
            "★ 必须**先** extend(extra) **再** app_sign —— 顺序反了签名就不含端点参数"
        );
        // ② playUrl 调用点必须显式带 vodId / epId / vodResolution 三个参数
        let call = flat.matches(r#"("vodId".to_string(),vod_id.clone())"#).count();
        assert!(call >= 2, "playUrl 调用点必须带 vodId（调用点+重试点 = ≥2 次，实际 {call}）");
        assert!(
            flat.contains(r#"("epId".to_string(),ep_id.clone())"#),
            "★ playUrl 用 `epId`（不是 epDetail 的 `vodEpId`）—— 两个端点参数名不同"
        );
        assert!(
            flat.contains(r#"("vodResolution".to_string(),resolution.unwrap_or(2).to_string())"#),
            "★ vodResolution 必须进请求（也是签名的一部分）"
        );
    }

    #[test]
    fn play_carries_a_referer_because_upstream_needs_it() {
        // ★ 实测：不带 Referer 拉 m3u8 会 TLS 断流 ⇒ 取出流头必须含 Referer
        //   （同样只扫实现段 —— 见上一条注释里的自证陷阱）
        let flat = crate::csp::shared::impl_src_only(include_str!("app_yqk.rs"));
        assert!(
            flat.contains(r#"("Referer".to_string(),PLAY_REFERER.to_string())"#),
            "★ 取流头必须有 Referer（实测缺了就 TLS 断流）"
        );
        assert_eq!(PLAY_REFERER, "https://yqk1.app/");
    }

    #[test]
    fn supports_search_is_true_and_matches_the_live_verification() {
        // ★ 已真网络验证（/v1/api/search/search 命中「仙逆」）⇒ 必须声明 true，
        //   否则 registry.rs 的 `capabilities.search` 会把这个源排除在聚合搜索外
        assert!(AppYQK::new().supports_search());
    }

    #[test]
    fn search_uses_v1_not_v2() {
        // ★ 实测：v1 是 200，v2 是 404。这条钉住"别有人顺手升成 v2"
        let flat = crate::csp::shared::impl_src_only(include_str!("app_yqk.rs"));
        assert!(flat.contains("\"/v1/api/search/search\""), "搜索端点必须是 v1（实测 v2 返回 404）");
        assert!(!flat.contains("\"/v2/api/search/search\""), "★ 不许用 v2 搜索端点（404）");
    }

    /// ★ 元门禁：证明上面那几条源码判据**真的剥掉了测试段**
    ///
    /// # 为什么"门禁的门禁"必要
    /// ```text
    /// 我自己刚栽过一次：`include_str!` 扫全文 ⇒ 断言里的字面量把门禁自己喂饱了 ⇒ 假绿。
    /// ⇒ 这条不验"实现对不对"，验的是**上面几条判据还有没有分辨力**：
    ///    下面这段假源码（含 `#[cfg(test)]` + 断言字面量）里，
    ///    `impl_src_only` **必须**把测试段剥掉 —— 若剥不掉，上面那几条就是假绿。
    /// ```
    #[test]
    fn meta_gate_impl_src_only_really_strips_the_test_module() {
        let fake = r#"
fn real_impl() { do_the_thing(); }
#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert!(include_str!("app_yqk.rs").contains("v.extend(extra.iter().cloned());")); }
}
"#;
        let flat = crate::csp::shared::impl_src_only(fake);
        assert!(flat.contains("do_the_thing();"), "实现段必须保留：{flat}");
        assert!(flat.contains("fnreal_impl()"), "空白要被归一化掉");
        assert!(
            !flat.contains(r#"v.extend(extra.iter().cloned());"#),
            "★ 测试段必须被剥掉 —— 否则「断言里的字面量」会把门禁喂成假绿：{flat}"
        );
        assert!(!flat.contains("modtests"), "测试模块本身也必须不在扫描范围：{flat}");
    }

    // ── 请求 id（形状判据） ────────────────────────────────────────────
    #[test]
    fn request_id_is_uuid_v4_shaped_and_unique() {
        let a = new_request_id();
        let b = new_request_id();
        assert_ne!(a, b, "每次请求必须换 requestId（上游会校验新鲜度）");
        // 形状：8-4-4-4-12，共 36 字符，第 13 位是 '4'
        assert_eq!(a.len(), 36, "UUID 形状：{a}");
        let parts: Vec<&str> = a.split('-').collect();
        assert_eq!(parts.len(), 5);
        assert_eq!(parts[0].len(), 8);
        assert_eq!(parts[1].len(), 4);
        assert_eq!(parts[2].len(), 4);
        assert!(parts[2].starts_with('4'), "版本位必须是 4（DEX 模板 `xxxx4xxx`）：{a}");
        assert_eq!(parts[3].len(), 4);
        assert_eq!(parts[4].len(), 12);
        assert!(a.chars().all(|c| c == '-' || c.is_ascii_hexdigit()), "只允许十六进制：{a}");
    }

    #[test]
    fn hardcoded_base_and_appkey_match_the_dex_constants() {
        // 这些值是 ext=null 时的**唯一**来源 ⇒ 改错就等于"这个类完全不可用"
        assert_eq!(BASE, "https://yzy0916.n0z6fkpuk.com");
        assert_eq!(APP_KEY, "3359de478f8d45638125e446a10ec541");
        assert_eq!(APP_ID, "e6ddefe09e0349739874563459f56c54");
        // 兜底分类表必须与实测 channeList 一致（否则导入探测拿到假分类）
        assert_eq!(AppYQK::FALLBACK_CHANNELS.len(), 6);
        assert_eq!(AppYQK::FALLBACK_CHANNELS[0], (50, "短剧"));
    }

    // ── 真网络（显式开关 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_app_yqk --release -- --ignored --nocapture"]
    async fn csp_live_app_yqk_walks_all_five_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = AppYQK::new();
        let home = s.home("").await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 频道 {} 个 {:?}，首屏 {} 条",
            home.categories.len(),
            home.categories.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
            home.items.len()
        );
        let list = s.list(&home.categories[0].id, 1, "").await.expect("list 应成功");
        eprintln!("[LIVE] list({}): {} 条", home.categories[0].name, list.items.len());
        let id = list.items[0].id.clone();
        let d = s.detail(&id, "").await.expect("detail 应成功");
        let mut flags: Vec<String> = d.episodes.iter().map(|e| e.flag.clone()).collect();
        flags.dedup();
        eprintln!(
            "[LIVE] detail({id}): 标题={} 集={} **线路={}** {:?}",
            d.title,
            d.episodes.len(),
            flags.len(),
            flags.iter().take(4).cloned().collect::<Vec<_>>()
        );
        let ep = &d.episodes[0];
        let plays = s.play(&ep.flag, &ep.id, "").await.expect("play 应成功");
        eprintln!("[LIVE] play: url={} headers={:?}", plays[0].url,
            plays[0].headers.iter().map(|(k, _)| k.clone()).collect::<Vec<_>>());
        assert!(plays[0].url.contains("m3u8") || plays[0].url.contains("mp4"), "应给真流地址");

        let se = s.search("仙逆", 1, "").await.expect("search 应成功");
        eprintln!("[LIVE] search(仙逆): {} 条，首条={:?}", se.items.len(),
            se.items.first().map(|i| i.title.clone()));
    }
}
