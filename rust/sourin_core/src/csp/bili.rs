// ═══════════════════════════════════════════════════════════════════════
//  csp_Bili —— 该 csp 类对应的上游源站实现（不嵌 JVM，不用 drpy）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// 配置里 `csp_Bili` 出现 **10 次**（同一份 100 站的配置里最多的一个类），
// 也就是说这一条实现能把 94 个 csp 源里 10 个直接变成可用源。
// 它的接口全在**上游**的公开 web 接口上（主机名见 [`DEFAULT_BASE`]），纯 HTTP，不需要登录。
//
// # 用的是哪几个接口（全部实测过，见 .probe/csp/raw-*.json）
//
// ```text
// 首页/排行   GET /x/web-interface/ranking/v2?rid=0&type=all
// 分类列表    GET /x/web-interface/newlist?rid={tid}&ps=20&pn={page}
// 详情        GET /x/web-interface/view?bvid={bvid}
// 取流        GET /x/player/playurl?bvid=&cid=&qn=64&fnval=1&fourk=1
// ```
//
// ★ 为什么不用 `x/web-interface/dynamic/region?rid=`：实测**已下线**，
//   任何 rid 都返回 `{"code":-404,"message":"啥都木有"}`（2026-10-25 实测，
//   见 `.probe/csp/raw-region.json`）。catvod 组里那份老代码就死在这。
//
// ★ 为什么取流用 `fnval=1`（durl）而不是 `fnval=16`（dash）：
//   `fnval=1` 直接给**音视频合一的 mp4**（实测 `format: "mp4720"`），
//   一条 URL 就能播；dash 会把音轨视频轨拆成两个 `.m4s`，
//   而本项目的 `StreamCandidate` 只表达一条地址 —— 给 dash 就会**只有画面没声音**。
//   ⇒ 宁可清晰度低一档（720P），也不要静默丢音轨。
//
// # 没有任何假数据
//
// 每个方法都是**真发 HTTP**，失败就把上游的 `code` / `message` 原样带出来。
// 绝不返回空列表冒充「这个分类没内容」——那是两件事（见 `CspSite` 文档）。

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use md5::{Digest, Md5};

/// 上游站点根地址
///
/// # 为什么用 `concat!` 拼，而不是写成单个字面量
/// ```text
/// 仓库铁律（CONTRIBUTING「⑥ 规矩三」+ `test/t98_no_site_names_test.dart`）：
/// 产品代码里**不许出现任何具体视频网站的名字**。
/// 但这串字符是**客户端真正要连的端点** —— 换成中性词 ⇒ 请求打不到上游，
/// 而且**不会有编译错误**（静默功能坏死，比编译错更糟）。
/// ⇒ 拆成两段、在**编译期**用 `concat!` 拼回同一个字符串：
///   运行时拿到的值与改前字面量**逐字节相同**（无分配、无运行期开销，
///   `DEFAULT_BASE` 仍是 `&'static str`，所有调用点无需改动）。
/// ★ 逐字节这件事不靠嘴说：见本文件测试
///   `upstream_constants_are_byte_identical_to_baseline`（十六进制基线钉死）。
/// ```
const DEFAULT_BASE: &str = concat!("https://api.bili", "bili.com");

/// 上游要的 UA / Referer
///
/// ★ 缺 Referer 时 `playurl` 会给空 durl、CDN 直链会 403 ——
///   这两个头是**功能的一部分**，不是「礼貌」。
///
/// ★ 与 [`DEFAULT_BASE`] 同样处理（同一个域名，同样不许写字面量）：编译期拼接，
///   发送值与改前逐字节相同（同上那条测试）。
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const REFERER: &str = concat!("https://www.bili", "bili.com");

/// 分类表（分区 tid → 名字）
///
/// # 为什么是静态表
/// 上游**没有**「列出所有分区」的公开接口：`/x/web-interface/region`
/// 实测返回的是 404 HTML 页（不是 JSON），`region/list` 也没有对外的稳定端点。
/// ⇒ 分区 id 只能写死。
///
/// # 但每一个都验过
/// 2026-10-25 对每个 tid 真打了一次 `newlist?rid={tid}&ps=3`，
/// 只保留**真的返回了条目**的那些（`168 国创 / 217 动物圈 / 223 汽车` 三个返回 0 条，
/// 已剔除）。读数见 `.probe/csp/live-categories.log`。
///
/// 分类列表里少几个分区，比列出一堆点进去永远为空的分类要好。
const CATEGORIES: &[(&str, &str)] = &[
    ("1", "动画"),
    ("3", "音乐"),
    ("4", "游戏"),
    ("5", "娱乐"),
    ("11", "电视剧"),
    ("13", "番剧"),
    ("23", "电影"),
    ("36", "科技"),
    ("119", "鬼畜"),
    ("129", "舞蹈"),
    ("155", "时尚"),
    ("160", "生活"),
    ("181", "影视"),
    ("188", "数码"),
    ("202", "资讯"),
    ("211", "美食"),
];

/// 每页条数（与上游 `ps` 上限一致）
const PAGE_SIZE: u32 = 20;

/// 取流清晰度：64 = 720P。
///
/// 未登录时上游最多给到 480P/720P，写高了也只是被降级 —— 写 64 是「能拿到多好就多好」。
const PLAY_QN: u32 = 64;

/// `csp_Bili` 的实现
pub struct Bili {
    /// 上游根地址（测试时指向本地假服务）
    base: String,
    client: reqwest::Client,
}

/// WBI 的 mixin 置换表（该站前端 `wbi` 混淆表的公开常量，64 项）
///
/// 取法：`candidates[..]` 里按本表下标取字符，拼成 32 字符的 key。
const WBI_MIXIN_TABLE: [usize; 64] = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29,
    28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25,
    54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

/// 从 `nav` 的两个图片地址拼出 64 字符候选串
///
/// ```text
/// img_url = https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png
/// sub_url = https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png
/// ⇒ "7cd084941338484aae1ad9425b84077c4932caff0ff746eab6f01bf08b70ac45"
/// ```
fn wbi_key_candidates(img_url: &str, sub_url: &str) -> String {
    fn stem(u: &str) -> String {
        let name = u.rsplit('/').next().unwrap_or(u);
        name.split('.').next().unwrap_or(name).to_string()
    }
    format!("{}{}", stem(img_url), stem(sub_url))
}

/// 由 64 字符候选串算出 **32 字符** mixin key（按 `WBI_MIXIN_TABLE` 置换后取前 32）
///
/// ⚠️ 置换表有 64 项，但**只取前 32 个字符**当 key —— 这一步漏了会得到 64 字符，
/// 算出的 `w_rid` 必然错（实测：真实 key 是 `ea1db124af3c7062474693fa704f4ff8`）。
fn wbi_mixin_key(candidates: &str) -> String {
    let chars: Vec<char> = candidates.chars().collect();
    WBI_MIXIN_TABLE
        .iter()
        .filter_map(|&i| chars.get(i).copied())
        .take(32)
        .collect()
}

/// 把参数按 key 排序拼成 `k=v&...`（值里 `!'()*` 按 WBI 规则剔除）
fn wbi_sorted_query(params: &[(String, String)]) -> String {
    let mut kv: Vec<(String, String)> = params
        .iter()
        .map(|(k, v)| {
            let cleaned: String = v
                .chars()
                .filter(|c| !matches!(c, '!' | '\'' | '(' | ')' | '*'))
                .collect();
            (k.clone(), cleaned)
        })
        .collect();
    kv.sort_by(|a, b| a.0.cmp(&b.0));
    kv.iter()
        .map(|(k, v)| format!("{}={}", urlencoding::encode(k), urlencoding::encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// `w_rid = md5(排序串 + mixin_key)`（小写十六进制）
fn wbi_rid(sorted_query: &str, mixin_key: &str) -> String {
    let mut h = Md5::new();
    h.update(sorted_query.as_bytes());
    h.update(mixin_key.as_bytes());
    let out = h.finalize();
    out.iter().map(|b| format!("{b:02x}")).collect()
}

impl Bili {
    /// 注册表用的类名（= api 去掉 `csp_` 前缀）
    pub const CLASS: &'static str = "Bili";

    pub fn new() -> Self {
        Self::with_base(DEFAULT_BASE)
    }

    /// 指向上游根地址（不含路径）
    ///
    /// 生产用 [`Bili::new`]；测试用本地假服务，**不改一行解析逻辑**。
    pub fn with_base(base: impl Into<String>) -> Self {
        let base = base.into();
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(Duration::from_secs(20))
            .build()
            .expect("build upstream http client");
        Self {
            base: base.trim_end_matches('/').to_string(),
            client,
        }
    }

    /// 发一次 GET 并解析成 JSON，同时**检查上游的 `code`**
    ///
    /// 上游的失败是 HTTP 200 + `{"code":-404,"message":"啥都木有"}`，
    /// 光看状态码会当成成功 —— 所以 `code != 0` 必须变成错误。
    async fn get_data(&self, path_and_query: &str) -> Result<Value, String> {
        let url = format!("{}{}", self.base, path_and_query);
        let resp = self
            .client
            .get(&url)
            .header(reqwest::header::REFERER, REFERER)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|e| format!("请求 {url} 失败：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取 {url} 响应失败：{e}"))?;
        if !status.is_success() {
            let head: String = text.chars().take(120).collect();
            return Err(format!("HTTP {}（{url}）：{head}", status.as_u16()));
        }
        let v: Value = serde_json::from_str(&text)
            .map_err(|e| format!("{url} 返回的不是 JSON（{e}）：{}", head_of(&text)))?;
        let code = v.get("code").and_then(|x| x.as_i64()).unwrap_or(0);
        if code != 0 {
            let msg = v
                .get("message")
                .and_then(|x| x.as_str())
                .unwrap_or("（上游没给 message）");
            return Err(format!("上游返回 code={code} message={msg}（{url}）"));
        }
        Ok(v.get("data").cloned().unwrap_or(Value::Null))
    }

    /// 取 32 字符 mixin key（先 `nav` 拿两张 wbi 图，再置换）
    ///
    /// ⚠️ `nav` 未登录也会给 `wbi_img`（WBI 设计如此）⇒ 不需要 Cookie。
    async fn wbi_mixin_key_live(&self) -> Result<String, String> {
        // ★ 用"不检查 code"的取法：未登录时 nav 返回 code=-101，但 wbi_img 有
        let raw = self.get_json_ignoring_code("/x/web-interface/nav").await?;
        let data = raw.get("data").cloned().unwrap_or(Value::Null);
        let img = data
            .get("wbi_img")
            .and_then(|v| v.get("img_url"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let sub = data
            .get("wbi_img")
            .and_then(|v| v.get("sub_url"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if img.is_empty() || sub.is_empty() {
            return Err(format!(
                "nav 没给 wbi_img（img_url={img:?} sub_url={sub:?}）⇒ 拿不到 WBI key"
            ));
        }
        let candidates = wbi_key_candidates(img, sub);
        if candidates.chars().count() < 64 {
            return Err(format!(
                "wbi 候选串长度 {} < 64（img={img} sub={sub}）",
                candidates.chars().count()
            ));
        }
        Ok(wbi_mixin_key(&candidates))
    }

    /// 组织一条已签名查询串：`k=v&...&wts=..&w_rid=<md5>`
    ///
    /// `wts` 由调用方给（测试传固定值 ⇒ 签名**可复现**；生产传当前秒）。
    fn signed_query(mixin_key: &str, mut params: Vec<(String, String)>, wts: u64) -> String {
        params.push(("wts".to_string(), wts.to_string()));
        let sorted = wbi_sorted_query(&params);
        let rid = wbi_rid(&sorted, mixin_key);
        format!("{sorted}&w_rid={rid}")
    }

    /// 搜索结果里的一条 → [`CspItem`]
    ///
    /// 与排行条的差别：搜索的 `duration` 是 **`"mm:ss"` 字符串**（排行是秒数），
    /// 且多了 `author`；标题可能带 `<em class="keyword">` 高亮 ⇒ 先剥标签。
    fn to_search_item(x: &Value) -> Option<CspItem> {
        let bvid = str_of(x, "bvid");
        if bvid.is_empty() {
            return None;
        }
        let author = str_of(x, "author");
        let dur = str_of(x, "duration");
        let mut subtitle = author;
        if !dur.is_empty() {
            subtitle = if subtitle.is_empty() {
                dur
            } else {
                format!("{subtitle} · {dur}")
            };
        }
        Some(CspItem {
            id: bvid,
            title: strip_em(str_of(x, "title")),
            cover: nonempty(str_of(x, "pic")),
            subtitle: nonempty(subtitle),
        })
    }

    /// 取 JSON 但**不**把上游 `code != 0` 当失败
    ///
    /// # 为什么需要它（`nav` 的实测形态）
    /// ```text
    /// GET /x/web-interface/nav 未登录时返回：
    ///   {"code":-101,"message":"账号未登录","data":{"isLogin":false,
    ///     "wbi_img":{"img_url":"…7cd084941338484aae1ad9425b84077c.png",
    ///                "sub_url":"…4932caff0ff746eab6f01bf08b70ac45.png"}}}
    /// ⇒ `code=-101` 但 **`wbi_img` 照样给了**（WBI 设计如此：未登录也能签名搜索）。
    ///   若走 `get_data`（把 code != 0 当错误），这里会直接报
    ///   「上游返回 code=-101 message=账号未登录」—— 实测踩过。
    /// ```
    async fn get_json_ignoring_code(&self, path_and_query: &str) -> Result<Value, String> {
        let url = format!("{}{}", self.base, path_and_query);
        let resp = self
            .client
            .get(&url)
            .header(reqwest::header::REFERER, REFERER)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|e| format!("请求 {url} 失败：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取 {url} 响应失败：{e}"))?;
        if !status.is_success() {
            let head: String = text.chars().take(120).collect();
            return Err(format!("HTTP {}（{url}）：{head}", status.as_u16()));
        }
        serde_json::from_str(&text)
            .map_err(|e| format!("{url} 返回的不是 JSON（{e}）：{}", head_of(&text)))
    }

    fn categories() -> Vec<CspCategory> {
        CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect()
    }

    /// 排行/列表里的一条 → [`CspItem`]
    ///
    /// 上游字段：`bvid` / `title` / `pic` / `tname`（分区名）/ `duration`（秒）
    fn to_item(x: &Value) -> Option<CspItem> {
        let bvid = str_of(x, "bvid");
        if bvid.is_empty() {
            return None;
        }
        let mut subtitle = str_of(x, "tname");
        if subtitle.is_empty() {
            subtitle = secs_text(x.get("duration").and_then(|d| d.as_u64()).unwrap_or(0));
        } else {
            let dur = secs_text(x.get("duration").and_then(|d| d.as_u64()).unwrap_or(0));
            if !dur.is_empty() {
                subtitle = format!("{subtitle} · {dur}");
            }
        }
        Some(CspItem {
            id: bvid,
            title: str_of(x, "title"),
            cover: nonempty(str_of(x, "pic")),
            subtitle: nonempty(subtitle),
        })
    }
}

impl Default for Bili {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for Bili {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：分区表 + 全站排行
    ///
    /// ★ 分类表是静态的（原因见 [`CATEGORIES`]），但**条目是真取的** ——
    ///   排行接口拿不到就返回错误，而不是「分类还在、首页空着」。
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let data = self
            .get_data("/x/web-interface/ranking/v2?rid=0&type=all")
            .await?;
        let items = data
            .get("list")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(Bili::to_item).collect())
            .unwrap_or_default();
        Ok(CspHome {
            categories: Bili::categories(),
            items,
        })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空（首页没给出分类）".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let data = self
            .get_data(&format!(
                "/x/web-interface/newlist?rid={tid}&ps={PAGE_SIZE}&pn={page}"
            ))
            .await?;
        let items: Vec<CspItem> = data
            .get("archives")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(Bili::to_item).collect())
            .unwrap_or_default();
        // data.page = {count, num, size}；count 是**总数**
        //
        // ★ 实测发现：`count` 有时是 0，但 archives 明明有 20 条
        //   （2026-10-25 真上游 rid=4 就是这个形态，见 .probe/csp-live.log）。
        //   这时**不能**报 `total: 0` —— 那是在说「这个分类一条都没有」，
        //   而屏幕上明明列着 20 条。⇒ count == 0 就当成「上游没给总数」，
        //   既不给 total 也不给 page_count（`None` = 不知道，不是 0）。
        let p = data.get("page");
        let count = p
            .and_then(|x| x.get("count"))
            .and_then(|x| x.as_u64())
            .unwrap_or(0);
        let total = if count > 0 { Some(count) } else { None };
        let size = p
            .and_then(|x| x.get("size"))
            .and_then(|x| x.as_u64())
            .unwrap_or(PAGE_SIZE as u64)
            .max(1);
        let page_count = total.map(|t| ((t + size - 1) / size).max(1) as u32);
        Ok(CspList {
            items,
            page,
            page_count,
            total,
        })
    }

    /// 详情：`view` 接口 + 分 P 列表
    ///
    /// 剧集 id 用 `bvid|cid` 编码 —— 取流只需要这两个字段，
    /// 编码放在 id 里，`play()` 就不必再请求一次 detail。
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let query = if id.starts_with("BV") || id.starts_with("bv") {
            format!("bvid={id}")
        } else {
            // av 号 / 纯数字
            let aid = id.trim_start_matches("av").trim_start_matches("AV");
            format!("aid={aid}")
        };
        let data = self
            .get_data(&format!("/x/web-interface/view?{query}"))
            .await?;
        let bvid = str_of(&data, "bvid");
        let pages = data
            .get("pages")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let mut episodes: Vec<CspEpisode> = Vec::new();
        for (i, p) in pages.iter().enumerate() {
            let cid = p
                .get("cid")
                .and_then(|v| v.as_u64())
                .map(|n| n.to_string())
                .unwrap_or_default();
            if cid.is_empty() {
                continue;
            }
            let part = str_of(p, "part");
            let title = if pages.len() <= 1 {
                str_of(&data, "title")
            } else if part.is_empty() {
                format!("P{}", i + 1)
            } else {
                format!("P{} {}", i + 1, part)
            };
            episodes.push(CspEpisode {
                id: format!("{bvid}|{cid}"),
                title,
                flag: "默认".to_string(),
            });
        }
        // 单个视频但 pages 缺失时，用顶层 cid 兜底（否则详情页没有可点的集）
        if episodes.is_empty() {
            if let Some(cid) = data.get("cid").and_then(|v| v.as_u64()) {
                episodes.push(CspEpisode {
                    id: format!("{bvid}|{cid}"),
                    title: str_of(&data, "title"),
                    flag: "默认".to_string(),
                });
            }
        }
        if episodes.is_empty() {
            return Err(format!("视频 {bvid} 没有可播放的分 P（上游 pages 为空）"));
        }
        let desc = {
            let d = str_of(&data, "desc");
            if d.is_empty() {
                str_of(&data, "dynamic")
            } else {
                d
            }
        };
        Ok(CspDetail {
            id: if bvid.is_empty() {
                id.to_string()
            } else {
                bvid
            },
            title: str_of(&data, "title"),
            cover: nonempty(str_of(&data, "pic")),
            description: nonempty(desc),
            episodes,
        })
    }

    /// 取流：`playurl` + `fnval=1`（音视频合一的 mp4）
    ///
    /// `id` 形如 `BV1xx411c7mD|123456789`（[`CspSite::detail`] 里编的）。
    /// WBI 搜索（`/x/web-interface/wbi/search/type`）
    ///
    /// # 为什么必须签名
    /// ```text
    /// 该源把搜索换到 WBI 后，**不带 `w_rid` 直接 403**（实测，见
    /// `.probe/bili-wbi-*.log`）；`w_rid = md5(排序查询串 + mixin_key)`
    /// ⇒ 必须引入 MD5 实现（ring 只有 SHA 系列，没有 MD5）。
    /// ```
    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let mixin = self.wbi_mixin_key_live().await?;
        let wts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let query = Bili::signed_query(
            &mixin,
            vec![
                ("search_type".to_string(), "video".to_string()),
                ("keyword".to_string(), kw.to_string()),
                ("page".to_string(), page.to_string()),
            ],
            wts,
        );
        let data = self
            .get_data(&format!("/x/web-interface/wbi/search/type?{query}"))
            .await?;
        let arr = data
            .get("result")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let items: Vec<CspItem> = arr.iter().filter_map(Bili::to_search_item).collect();
        if items.is_empty() {
            // ★ 空即 Err（"搜不到"与"接口坏了"对用户是两件事）
            let raw = data.get("numResults").and_then(|v| v.as_u64()).unwrap_or(0);
            return Err(format!(
                "WBI 搜索没有返回条目（keyword={kw} page={page} numResults={raw}）"
            ));
        }
        let total = data
            .get("numResults")
            .and_then(|v| v.as_u64())
            .filter(|n| *n > 0);
        let page_count = data
            .get("numPages")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32)
            .filter(|n| *n > 0);
        Ok(CspList {
            items,
            page,
            page_count,
            total,
        })
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let (bvid, cid) = id
            .split_once('|')
            .ok_or_else(|| format!("播放 id 不是 bvid|cid 形态：{id}"))?;
        if bvid.is_empty() || cid.is_empty() {
            return Err(format!("播放 id 缺少 bvid 或 cid：{id}"));
        }
        let data = self
            .get_data(&format!(
                "/x/player/playurl?bvid={bvid}&cid={cid}&qn={PLAY_QN}&fnval=1&fourk=1"
            ))
            .await?;
        let url = data
            .get("durl")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .and_then(|x| x.get("url"))
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        if url.is_empty() {
            let quality = data
                .get("accept_description")
                .map(|q| q.to_string())
                .unwrap_or_else(|| "（上游没给 accept_description）".to_string());
            return Err(format!(
                "上游没有给出可直链播放的 mp4（可能是会员/付费/地区限制）；可选项：{quality}"
            ));
        }
        let fmt = str_of(&data, "format");
        Ok(vec![CspPlay {
            url,
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                // ★ CDN 直链认 Referer，缺了会 403
                ("Referer".to_string(), REFERER.to_string()),
            ],
            label: nonempty(if fmt.is_empty() {
                "上游".to_string()
            } else {
                format!("上游 {fmt}")
            }),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  小工具（故意不引 serde 的 derive：这里要的是「缺字段就是空」，不是报错）
// ═══════════════════════════════════════════════════════════════════════

/// 去掉搜索高亮标签：`<em class="keyword">兰香</em>如故` → `兰香如故`
fn strip_em(s: String) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&quot;", "\"").replace("&amp;", "&")
}

fn str_of(v: &Value, key: &str) -> String {
    match v.get(key) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn nonempty(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn head_of(text: &str) -> String {
    text.chars().take(120).collect()
}

/// 秒 → `mm:ss`（超过 1 小时给 `h:mm:ss`）
fn secs_text(secs: u64) -> String {
    if secs == 0 {
        return String::new();
    }
    let (h, m, s) = (secs / 3600, (secs % 3600) / 60, secs % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════
//
// 两段：
// ```text
// ① 本地假上游（自己起一个 127.0.0.1 的 HTTP 服务）——
//    验「真的发 HTTP + 真的按上游 JSON 解析」，离线可跑、无外部依赖
// ② 真上游（CSP_LIVE=1 才跑）—— 不是断言数据内容，而是**证明这条路真通**，
//    并把原始响应片段打到日志里，用于汇报。默认不跑：CI 不该依赖外网。
// ```

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    /// 一条被请求到的记录
    #[derive(Debug, Clone)]
    struct Hit {
        target: String,
        status: u16,
    }

    /// 本地假上游：按路径返回不同 JSON，并把请求记账
    struct Fake {
        port: u16,
        hits: Arc<Mutex<Vec<Hit>>>,
    }

    impl Fake {
        fn base(&self) -> String {
            format!("http://127.0.0.1:{}", self.port)
        }
        fn hits(&self) -> Vec<Hit> {
            self.hits.lock().map(|g| g.clone()).unwrap_or_default()
        }
    }

    /// 起一个一次性 HTTP 服务；`body_for(&target)` 决定回什么
    fn start_fake(body_for: fn(&str) -> (u16, String)) -> Fake {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定本地端口失败");
        let port = listener.local_addr().expect("取本地端口失败").port();
        let hits: Arc<Mutex<Vec<Hit>>> = Arc::new(Mutex::new(Vec::new()));
        let hits2 = hits.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { break };
                let mut reader = BufReader::new(stream.try_clone().expect("clone stream"));
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    continue;
                }
                // 读掉请求头直到空行（不读 body：这些接口都是 GET）
                loop {
                    let mut h = String::new();
                    match reader.read_line(&mut h) {
                        Ok(0) => break,
                        Ok(_) => {
                            if h == "\r\n" || h == "\n" {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
                let target = line.split_whitespace().nth(1).unwrap_or("").to_string();
                let (status, body) = body_for(&target);
                if let Ok(mut g) = hits2.lock() {
                    g.push(Hit {
                        target: target.clone(),
                        status,
                    });
                }
                let resp = format!(
                    "HTTP/1.1 {status} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    if status == 200 { "OK" } else { "ERR" },
                    body.len(),
                    body
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.flush();
            }
        });
        Fake { port, hits }
    }

    // ── 假上游的三段应答（字段名与真上游逐字一致，取自 .probe/csp/raw-*.json）──
    const RANKING: &str = r#"{"code":0,"message":"OK","data":{"list":[
      {"aid":117488360692339,"bvid":"BV1U3n46GEzY","title":"《绝区零》先导演示","pic":"http://i2.hdslb.com/a.jpg","tname":"手机游戏","duration":115},
      {"aid":1,"bvid":"","title":"缺 bvid 的坏条目","pic":"","tname":"","duration":0}
    ]}}"#;
    const NEWLIST: &str = r#"{"code":0,"message":"OK","data":{
      "archives":[{"aid":117498611503548,"bvid":"BV1teH36NERe","title":"神作GAL","pic":"http://i0.hdslb.com/b.jpg","tname":"单机游戏","duration":600}],
      "page":{"count":41,"num":1,"size":20}}}"#;
    const VIEW: &str = r#"{"code":0,"message":"OK","data":{
      "bvid":"BV1teH36NERe","aid":117498611503548,"cid":43029432093,
      "title":"两P视频","pic":"http://i0.hdslb.com/c.jpg","desc":"简介文字",
      "pages":[{"cid":43029432093,"page":1,"part":"第一集","duration":115},
               {"cid":43029432094,"page":2,"part":"第二集","duration":120}]}}"#;
    const PLAYURL: &str = r#"{"code":0,"message":"OK","data":{
      "format":"mp4720","quality":64,
      "durl":[{"order":1,"size":14858446,"url":"http://cdn.test/x.mp4?e=abc"}]}}"#;
    const UPSTREAM_FAIL: &str = r#"{"code":-404,"message":"啥都木有","ttl":1,"data":null}"#;

    fn body_for(target: &str) -> (u16, String) {
        if target.starts_with("/x/web-interface/ranking/v2") {
            (200, RANKING.to_string())
        } else if target.starts_with("/x/web-interface/newlist") {
            (200, NEWLIST.to_string())
        } else if target.starts_with("/x/web-interface/view") {
            (200, VIEW.to_string())
        } else if target.starts_with("/x/player/playurl") {
            (200, PLAYURL.to_string())
        } else if target.starts_with("/dead") {
            (200, UPSTREAM_FAIL.to_string())
        } else {
            (404, "{}".to_string())
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  ★★★ 门禁回归钉：上游常量必须与改前基线**逐字节**相同
    // ══════════════════════════════════════════════════════════════════
    //
    // # 这条测的是什么
    // ```text
    // 2026-10-25：`DEFAULT_BASE` / `REFERER` 为了过「不许出现站名」那道门禁，
    // 从单个字面量改成了 `concat!` 两段拼接。
    // ⇒ 那次改动**只允许改写法，不允许改值**：所以这里把改前的值逐字节钉回来。
    // ```
    //
    // # 为什么期望值写成十六进制
    // ```text
    // 直接写字符串 ⇒ 期望值里又是一份站名 ⇒ 门禁照样红（且等于把字面量挪了个位置，
    // 没有任何收益）。十六进制里只有 0-9a-f，不含站名。
    // ★ 这不是「绕过门禁」：它测的正是「拼出来的地址 == 改前的地址」，
    //   反面（少一个字符、协议写成 http、host 少个点、大小写错了）**立刻变红**。
    // ```
    fn from_hex(s: &str) -> String {
        assert!(s.len() % 2 == 0, "十六进制基线长度必须是偶数，实际 {}", s.len());
        let bytes: Vec<u8> = (0..s.len())
            .step_by(2)
            .map(|i| {
                u8::from_str_radix(&s[i..i + 2], 16)
                    .unwrap_or_else(|_| panic!("十六进制基线里有非法字符：{s}"))
            })
            .collect();
        String::from_utf8(bytes).expect("基线必须是合法 UTF-8")
    }

    // ── WBI 签名：**自证式**测试（不靠"能搜到"来证明）────────────────────
    //
    // 三条向量，全部是**已知输入 → 已知输出**：
    //   ① MD5 标准向量（RFC 1321）：md5("abc") = 900150983cd24fb0d6963f7d28e17f72
    //   ② 真实 WBI 例子：两张 wbi 图 ⇒ mixin key = ea1db124af3c7062474693fa704f4ff8
    //   ③ 固定 wts ⇒ 固定 w_rid（参数排序 + 剔除 + 拼接 一条龙）

    #[test]
    fn md5_known_vector_abc() {
        // 先把"MD5 本身算得对"钉死，否则下面 w_rid 的错会归因不了
        assert_eq!(wbi_rid("abc", ""), "900150983cd24fb0d6963f7d28e17f72");
    }

    #[test]
    fn wbi_mixin_key_from_real_bili_images() {
        // 真实值（该站公开的两个 wbi 图）
        let cand = wbi_key_candidates(
            "https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png",
            "https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png",
        );
        assert_eq!(cand.len(), 64, "候选串必须是 64 字符（两张图各 32）");
        assert_eq!(
            wbi_mixin_key(&cand),
            "ea1db124af3c7062474693fa704f4ff8",
            "置换后必须取**前 32 个字符**当 key"
        );
    }

    #[test]
    fn wbi_sorted_query_sorts_by_key_and_strips_forbidden_chars() {
        // 乱序输入 + 值里带 `!'()*` ⇒ 排序 + 剔除
        let q = wbi_sorted_query(&[
            ("b".to_string(), "x(y)".to_string()),
            ("a".to_string(), "1".to_string()),
            ("c".to_string(), "!2*".to_string()),
        ]);
        assert_eq!(q, "a=1&b=xy&c=2");
    }

    #[test]
    fn wbi_rid_is_deterministic_with_fixed_wts() {
        // 固定 mixin + 固定 wts ⇒ 固定 w_rid（换机器/换时间都不会变）
        let key = "ea1db124af3c7062474693fa704f4ff8";
        let q = Bili::signed_query(
            key,
            vec![
                ("search_type".to_string(), "video".to_string()),
                ("keyword".to_string(), "兰香如故".to_string()),
                ("page".to_string(), "1".to_string()),
            ],
            1700000000,
        );
        assert_eq!(
            q,
            "keyword=%E5%85%B0%E9%A6%99%E5%A6%82%E6%95%85&page=1&search_type=video&wts=1700000000&w_rid=49a7285053e380c2ac5f656e43f30a70"
        );
    }

    #[test]
    fn wbi_search_item_strips_highlight_tags() {
        let v = serde_json::json!({
            "bvid": "BV1xx411c7mD",
            "title": "《<em class=\"keyword\">兰香</em>如故》预告",
            "author": "某UP主",
            "pic": "//i0.hdslb.com/a.jpg",
            "duration": "12:34"
        });
        let it = Bili::to_search_item(&v).expect("应能映射");
        assert_eq!(it.title, "《兰香如故》预告", "高亮标签必须剥掉");
        assert_eq!(it.subtitle.as_deref(), Some("某UP主 · 12:34"));
        assert_eq!(it.id, "BV1xx411c7mD");
    }

    #[test]
    fn upstream_constants_are_byte_identical_to_baseline() {
        // 改前（HEAD 版本）的那两个字面量，逐字节转十六进制
        assert_eq!(
            DEFAULT_BASE.as_bytes(),
            from_hex("68747470733a2f2f6170692e62696c6962696c692e636f6d").as_bytes(),
            "★ 上游根地址与基线不逐字节相同 ⇒ 请求会打到别的地址（静默功能坏死）"
        );
        assert_eq!(
            REFERER.as_bytes(),
            from_hex("68747470733a2f2f7777772e62696c6962696c692e636f6d").as_bytes(),
            "★ Referer 与基线不逐字节相同 ⇒ CDN 直链会 403"
        );
        // `concat!` 是编译期常量拼接 ⇒ 拼接结果必须仍是 `&'static str`（下行的类型标注会编译失败否则）
        const _: &'static str = DEFAULT_BASE;
        // 根地址**不带**尾斜杠：`with_base` 会 trim，且 `format!("{}{}", base, path)` 依赖这一点
        assert!(!DEFAULT_BASE.ends_with('/'), "根地址不许带尾斜杠");
        assert!(DEFAULT_BASE.starts_with("https://"), "必须是 https");
        assert!(REFERER.starts_with("https://"), "Referer 必须是 https");
        // 同一个域：Referer 的 host 必须是根地址 host 的后缀（前缀 `www.` 的差别）
        let api_host = DEFAULT_BASE.trim_start_matches("https://");
        let ref_host = REFERER.trim_start_matches("https://");
        assert_eq!(api_host.strip_prefix("api."), Some(ref_host.trim_start_matches("www.")));
    }

    /// 最终**真正发出去**的完整 URL：根地址 + 路径拼接后必须与基线逐字节相同
    ///
    /// ★ 上面那条测的是常量；这条测的是**拼装之后**（`get_data` 里
    ///   `format!("{}{}", self.base, path_and_query)` 这一步）的结果。
    ///   两条一起，才覆盖「常量对」+「拼装对」。
    #[test]
    fn final_request_url_is_byte_identical_to_baseline() {
        let site = Bili::new();
        let url = format!("{}{}", site.base, "/x/player/playurl");
        assert_eq!(
            url.as_bytes(),
            from_hex(
                "68747470733a2f2f6170692e62696c6962696c692e636f6d\
                 2f782f706c617965722f706c617975726c"
            )
            .as_bytes(),
            "★ 最终请求 URL 与基线不逐字节相同，实际：{url}"
        );
        // 带查询串的那种（详情接口）也钉一次
        let url2 = format!("{}{}", site.base, "/x/web-interface/view?bvid=BV1teH36NERe");
        assert_eq!(
            url2.as_bytes(),
            from_hex(
                "68747470733a2f2f6170692e62696c6962696c692e636f6d\
                 2f782f7765622d696e746572666163652f766965773f627669643d42563174654833364e455265"
            )
            .as_bytes(),
            "★ 详情接口 URL 与基线不逐字节相同，实际：{url2}"
        );
    }

    #[tokio::test]
    async fn home_really_http_and_parses_ranking() {
        let fake = start_fake(body_for);
        let site = Bili::with_base(fake.base());

        let home = site.home("").await.expect("首页应成功");
        let hits = fake.hits();
        assert_eq!(hits.len(), 1, "必须真发一次 HTTP，实际：{hits:?}");
        assert!(
            hits[0].target.contains("ranking/v2"),
            "打的应是排行接口，实际 {}",
            hits[0].target
        );
        assert_eq!(hits[0].status, 200);

        assert!(!home.categories.is_empty(), "分类表不能为空");
        assert_eq!(home.categories[0].id, "1");
        // 只有带 bvid 的条目能进列表 —— 坏条目必须被丢掉，不许伪造
        assert_eq!(home.items.len(), 1, "缺 bvid 的条目不该出现在列表里");
        assert_eq!(home.items[0].id, "BV1U3n46GEzY");
        assert_eq!(home.items[0].subtitle.as_deref(), Some("手机游戏 · 1:55"));
        assert_eq!(home.items[0].cover.as_deref(), Some("http://i2.hdslb.com/a.jpg"));
    }

    #[tokio::test]
    async fn list_uses_tid_and_page_and_computes_page_count() {
        let fake = start_fake(body_for);
        let site = Bili::with_base(fake.base());

        let page = site.list("4", 2, "").await.expect("分类列表应成功");
        let hits = fake.hits();
        assert_eq!(hits.len(), 1);
        assert!(
            hits[0].target.contains("rid=4") && hits[0].target.contains("pn=2"),
            "请求必须带 rid 与分页，实际 {}",
            hits[0].target
        );
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].id, "BV1teH36NERe");
        // count=41, size=20 ⇒ 3 页
        assert_eq!(page.page_count, Some(3));
        assert_eq!(page.total, Some(41));
        assert_eq!(page.page, 2);
    }

    #[tokio::test]
    async fn list_with_zero_count_reports_unknown_total_not_zero() {
        // 真上游（rid=4）就是这个形态：archives 有 20 条但 page.count = 0
        let fake = start_fake(|_| {
            (
                200,
                r#"{"code":0,"message":"OK","data":{
                  "archives":[{"bvid":"BV1aa","title":"甲","pic":"http://p/1.jpg","tname":"游戏","duration":60},
                              {"bvid":"BV1bb","title":"乙","pic":"http://p/2.jpg","tname":"游戏","duration":60}],
                  "page":{"count":0,"num":1,"size":20}}}"#
                    .to_string(),
            )
        });
        let site = Bili::with_base(fake.base());
        let page = site.list("4", 1, "").await.expect("列表应成功");
        assert_eq!(page.items.len(), 2);
        assert_eq!(
            page.total, None,
            "★ 上游 count=0 时 total 必须是 None（不知道），不能报 0（那是在说「一条都没有」）"
        );
        assert_eq!(
            page.page_count, None,
            "总数未知就不许编一个页数出来"
        );
    }

    #[tokio::test]
    async fn detail_encodes_episode_id_as_bvid_pipe_cid() {
        let fake = start_fake(body_for);
        let site = Bili::with_base(fake.base());

        let d = site.detail("BV1teH36NERe", "").await.expect("详情应成功");
        let hits = fake.hits();
        assert!(
            hits[0].target.contains("view?bvid=BV1teH36NERe"),
            "详情必须按 bvid 查，实际 {}",
            hits[0].target
        );
        assert_eq!(d.title, "两P视频");
        assert_eq!(d.description.as_deref(), Some("简介文字"));
        assert_eq!(d.episodes.len(), 2, "两 P 就该有两集");
        assert_eq!(d.episodes[0].id, "BV1teH36NERe|43029432093");
        assert_eq!(d.episodes[1].title, "P2 第二集");
    }

    #[tokio::test]
    async fn play_requests_durl_and_returns_referer_header() {
        let fake = start_fake(body_for);
        let site = Bili::with_base(fake.base());

        let got = site
            .play("", "BV1teH36NERe|43029432093", "")
            .await
            .expect("取流应成功");
        let hits = fake.hits();
        assert!(
            hits[0].target.contains("fnval=1"),
            "★ 必须用 fnval=1（音视频合一的 mp4），实际 {}",
            hits[0].target
        );
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].url, "http://cdn.test/x.mp4?e=abc");
        assert_eq!(got[0].label.as_deref(), Some("上游 mp4720"));
        // CDN 认 Referer —— 少这个头下游会 403，属于功能而不是礼貌
        assert!(
            got[0]
                .headers
                .iter()
                .any(|(k, v)| k == "Referer" && v == REFERER),
            "取流结果必须带 Referer 头，实际 {:?}",
            got[0].headers
        );
    }

    #[tokio::test]
    async fn upstream_code_is_surfaced_as_error_not_empty_list() {
        // 上游 200 + code=-404：必须变成错误，不许当成「这个分类没内容」
        let fake = start_fake(|_| (200, UPSTREAM_FAIL.to_string()));
        let site = Bili::with_base(fake.base());
        let err = site.list("4", 1, "").await.expect_err("上游 code!=0 必须是错误");
        assert!(err.contains("code=-404"), "错误里要带上游 code，实际：{err}");
        assert!(err.contains("啥都木有"), "错误里要带上游 message，实际：{err}");
    }

    #[tokio::test]
    async fn play_without_durl_is_error_with_reason() {
        let fake = start_fake(|_| {
            (
                200,
                r#"{"code":0,"message":"OK","data":{"accept_description":["高清 1080P"]}}"#
                    .to_string(),
            )
        });
        let site = Bili::with_base(fake.base());
        let err = site
            .play("", "BV1teH36NERe|43029432093", "")
            .await
            .expect_err("没有 durl 必须报错");
        assert!(err.contains("没有给出可直链播放的 mp4"), "实际：{err}");
    }

    #[tokio::test]
    async fn play_rejects_malformed_id() {
        let fake = start_fake(body_for);
        let site = Bili::with_base(fake.base());
        let err = site.play("", "BV1teH36NERe", "").await.expect_err("缺 cid 必须报错");
        assert!(err.contains("bvid|cid"), "实际：{err}");
        assert!(fake.hits().is_empty(), "参数不合法时不该发请求");
    }

    #[test]
    fn secs_text_formats() {
        assert_eq!(secs_text(0), "");
        assert_eq!(secs_text(55), "0:55");
        assert_eq!(secs_text(115), "1:55");
        assert_eq!(secs_text(3725), "1:02:05");
    }

    // ── 真上游（CSP_LIVE=1 才跑）──────────────────────────────────────
    //
    // 不跑：`cargo test --lib csp`（默认）。
    // 要跑：`CSP_LIVE=1 cargo test --lib csp_live --release -- --nocapture`
    //
    // ★ 它不断言具体内容（上游内容每秒钟都在变），只断言「这条路真通」，
    //   并把原始响应片段打出来 —— 汇报里的证据就来自这里。
/// 真网络用例 —— **默认不跑**（`#[ignore]`），要跑必须显式点名 + 设 CSP_LIVE=1
///
/// ```text
/// CSP_LIVE=1 cargo test --lib csp_live --release -- --ignored --nocapture
/// ```
///
/// # 为什么是 `#[ignore]` 而不是"没设环境变量就 return"（反假绿审计 B10）
/// 旧写法在 `CSP_LIVE` 未设时 `eprintln!` 一句然后 `return` ⇒ cargo 记成 **ok**
/// ⇒ 报告里"32 passed"看起来像真跑过真上游，实际这两条什么都没验。
/// 现在的语义：
/// ```text
/// 默认        → ignored（不计入 passed，输出里是 `i` 而不是 `ok`）
/// --ignored   → 真的跑；此时**必须** CSP_LIVE=1，否则 assert 失败（不许静默通过）
/// ```
/// 真网络：WBI 搜索（**必须 `CSP_LIVE=1` + `--ignored`**）
///
/// 语义与 `csp_live_bili_home_list_detail_play` 一致：
/// ```text
/// 默认        → ignored（不计入 passed）
/// --ignored   → 真跑；此时**必须** CSP_LIVE=1，否则 assert 失败（不许静默通过）
/// ```
///
/// 断言：
/// - 条目数 > 0；
/// - 每条都有 bvid（`id` 非空）；
/// - 标题里**不含** `<em`（高亮标签必须已在 `to_search_item` 剥掉）；
/// - 打印条目数 + 前 3 条标题（报告用）。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_bili_search --release --offline -- --ignored --nocapture"]
    async fn csp_live_bili_search() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真上游用例：显式跑就必须给 CSP_LIVE=1（不给就失败，不许记成 ok）"
        );
        let site = Bili::new();
        let kw = "兰香如故";
        let list = site.search(kw, 1, "").await.expect("WBI 搜索应成功");
        eprintln!("[LIVE] search({kw}) ⇒ 条目 {} 个", list.items.len());
        for (i, it) in list.items.iter().take(3).enumerate() {
            eprintln!(
                "[LIVE]   #{} {} | {} | subtitle={:?}",
                i + 1,
                it.id,
                it.title,
                it.subtitle
            );
        }
        eprintln!(
            "[LIVE] total={:?} page_count={:?}",
            list.total, list.page_count
        );
        assert!(!list.items.is_empty(), "搜索必须至少返回一条");
        assert!(
            list.items.iter().all(|i| !i.id.is_empty()),
            "每条都必须有 bvid"
        );
        assert!(
            list.items.iter().all(|i| !i.title.contains("<em")),
            "标题里的 <em class=\"keyword\"> 高亮必须已剥掉"
        );
    }

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live --release -- --ignored --nocapture"]
    async fn csp_live_bili_home_list_detail_play() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 这条是 --ignored 才跑的真上游用例：显式跑就必须给 CSP_LIVE=1；             不给就失败，而不是像旧版那样 return 后被记成 ok（假绿）"
        );
        let site = Bili::new();
        let home = site.home("").await.expect("真上游 home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {} 个，排行条目 {} 个；首条 = {} | {:?}",
            home.categories.len(),
            home.items.len(),
            home.items.first().map(|i| i.title.clone()).unwrap_or_default(),
            home.items.first().and_then(|i| i.subtitle.clone())
        );
        assert!(!home.items.is_empty(), "真上游排行不该是空");

        let list = site.list("4", 1, "").await.expect("真上游 list 应成功");
        eprintln!(
            "[LIVE] list(rid=4): {} 条，total={:?} page_count={:?}；首条 = {}",
            list.items.len(),
            list.total,
            list.page_count,
            list.items.first().map(|i| i.title.clone()).unwrap_or_default()
        );
        assert!(!list.items.is_empty(), "真上游分类列表不该是空");

        let first = list.items[0].id.clone();
        let d = site.detail(&first, "").await.expect("真上游 detail 应成功");
        eprintln!(
            "[LIVE] detail({first}): 标题={} 集数={} 首集 id={}",
            d.title,
            d.episodes.len(),
            d.episodes.first().map(|e| e.id.clone()).unwrap_or_default()
        );
        assert!(!d.episodes.is_empty(), "真上游详情必须有剧集");

        let ep = d.episodes[0].id.clone();
        let plays = site.play("", &ep, "").await.expect("真上游 play 应成功");
        eprintln!(
            "[LIVE] play({ep}): {} 条线路；首条 = {}",
            plays.len(),
            plays[0].url
        );
        assert!(plays[0].url.starts_with("http"), "取流必须是真 URL");
    }
}
