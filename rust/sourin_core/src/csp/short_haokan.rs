// ═══════════════════════════════════════════════════════════════════════
//  csp_ShortHaokan —— TVBox `csp_ShortHaokan` 的 Rust 重写（HTTP-JSON，POST 为主）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅 8815.kstore.vip/tvbox/wmz 的 💞好看丨短剧爽看：
//   {"type":3, "api":"csp_ShortHaokan", "ext": null}
// ⇒ ext 为 null ⇒ 端点写死（DEX 常量逐字给出，都是 `sv.baidu.com` 上的）。
// ```
//
// # 协议取证（`.probe/decompiled/classes.dex` 直读，**未起 jadx**）
//
// 依据：`.probe/r3-c-strings.json` 里 `ShortHaokan` 的 76 条 const-string。
// 类：`com.github.catvod.spider.ShortHaokan`，父类 `crawler.Spider`，12 方法 0 字段。
//
// ```text
// 请求头（DEX 的 a() 里逐字给出，**这是本站的门槛**）
//   Content-Type: application/x-www-form-urlencoded; charset=utf-8
//   User-Agent  : Mozilla/5.0 (Linux; **Android 11**; M2012K10C Build/RP1A.200720.011; wv)
//                 AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/**87**.0.4280.141
//                 Mobile Safari/537.36                     ← ★ **移动端 UA**，不是桌面
//   Cookie      : BAIDUCUID=giHCu0azv80G8SfQ0avU8gaaH8jfiv86ju2MugiR2i8-k3a35avAa1_mA
//   Talos-Module-Version: 1.0.71.1
//   Talos-Module-Name   : shortDrama
//   响应字段：'url'（play 里）· status/msg/data（统一信封，★ **status==0 才是成功**）
// 端点：
//   homeContent   https://sv.baidu.com/haokan/ui-feed/playletShelfFeed?osbranch=a0   （from=feed）
//   categoryContent https://sv.baidu.com/haokan/ui-feed/playletTagsFeed?osbranch=a0
//                   参数 cateId / rn / tag_id / pn
//   detailContent   https://sv.baidu.com/appui/api?osbranch=a0   ← **"方法名当参数"的分派接口**
//                   两个子方法：`video/commonlist` · `video/relate`
//                   ＋ https://sv.baidu.com/haokan/ui-video/playlet/rec/detail?osbranch=a0
//   playerContent   https://sv.baidu.com/appui/api?osbranch=a0   子方法 `video/relate`
//                   ＋ method=post&vid=  · &play_screen_type=1&play_volume_type=2&play_external_device_type=1
//                   响应 data.cur_video.clarityUrl
//   extractVideoUrl(String) → 取 'url'（自有方法，1 个）
// ```
//
// # ★★ 实测校正（DEX 常量 ≠ 真站点，本类 **3 处**；这是本批最"坑"的一类）
//
// ```text
// ① ★ 端点看起来是"GET + 查询串"，其实**必须 POST（表单体）**
//    DEX 常量把参数写成 `...?osbranch=a0&from=feed` 这种形状 ⇒ 看着像 GET。
//    【实测】GET  `…/playletShelfFeed?osbranch=a0&from=feed` → **404 Not Found**（25 B）
//            POST 同路径（体 `from=feed`）                   → **200 · 16968 B · status=0 成功** ✅
//    ⇒ 全部端点都改用 POST + 表单体（与 DEX 的"查询串"外观不同）
//
// ② ★ `appui/api` 是**"方法名当表单参数"的分派接口**（最反直觉的一处）
//    它不是 `…?name=<方法>&<参数>`，而是**把方法名本身当表单键**：
//      POST 体 `video/commonlist=&id=<playlet_id>`  → **status 0 成功** ✅
//      POST 体 `video/commonlist=9175494588921467958` → status=101001 "param error: id is required"
//      POST 体 `playlet_id=…`                          → status=3 "参数错误"
//    ★ 键名里的 `/` **不编码**（`video/commonlist`，不是 `video%2Fcommonlist`）；
//      值**留空**，id 另用 `&id=` 传 —— 这是我实测出的形态，DEX 常量里看不出来。
//
// ③ 成功码是 **status==0**（与 code==0/200 都不同）：
//    实测 `status` 取值见过 0（成功）/ 3（参数错误）/ 7（非法请求）/ 101001（param error）
//    ⇒ 判据必须钉 `status == 0`（只看 HTTP 200 会把 3/7/101001 都当成功）。
// ```
//
// # ★ 能力分档（**如实**：本类**部分可用**）
//
// ```text
// ✅ home   —— 实测 POST playletShelfFeed(from=feed) → 200 · 16968 B · status=0
//              data 里有 playlet_banner / my_collection / my_record / playlet_book(None) /
//              playlet_feed_tags / playlet_tags
//              playlet_tags：12 个分类（tag_id + name，如 tag_id=1 name="热播剧"）
// ✅ list   —— 实测 POST playletTagsFeed(tag_id=1&pn=1&rn=9&cateId=1)
//              → 200 · status=0 · data.list[] 每项 17 个字段
//              （playlet_id/playlet_title/playlet_poster/description/hot_value_num/
//                episodes_num/episodes_num_text/is_end/tags/scheme/preview_url/
//                progress_desc/progress_num/progress_vid/playlet_type 等）
//              ★ 首次探测我漏了 `cateId` ⇒ 返回 `{"list":null,"pn":1,"rn":0,"has_more":1}`
//                （这是 200 + status 0 的**假成功**：status 说成功、list 却是 null）
//                ⇒ 加 `cateId=1` 后才出数据。这条已写进门禁（`list_needs_cate_id`）。
// ⚠️ detail —— **未打通**（实测记录如下，如实标"未实现"，不猜）
//              · rec/detail 带 `playlet_id=<真 id>` → **status=3 "参数错误"**（试过 10 余种
//                参数组合：playlet_id / cid / id / from / tag_id / pn / rn / cateId …）
//              · `appui/api` 的 `video/commonlist` 能 **status=0 成功**，但
//                `data.response_count=0` · `results=[]`（**空**）——两个候选 id 都如此
//                （`playlet_id` 与 `progress_vid` 各试过）
//              · `video/relate` 带任何 id 都 `status=101001 param error: id is required`
//              ⇒ 结论：**要么缺一个我们没探到的必需参数，要么该接口要求登录态**
//                （Cookie 是 DEX 写死的 BAIDUCUID）。**不猜参数** ⇒ 本类 detail 如实报错。
// ⚠️ play   —— 依赖 detail 的 vid/clarityUrl ⇒ 同上一并**未打通**
//              （DEX 的 `playerContent` 走 `video/relate` 取 `clarityUrl`，
//                而 relate 对未登录返回 101001 ⇒ 取不到）
// ```
//
// # 真网络读数（2026-10-27 实测，全部 POST + 表单体）
//
// ```text
// POST /haokan/ui-feed/playletShelfFeed?osbranch=a0   body=from=feed
//      → 200 · 16968 B · status=0 · msg="成功"
//        data.playlet_banner[0] = {playlet_id:"9161446330548442445",
//                                  playlet_title:"逆袭人生之飞龙在天",
//                                  playlet_poster:"https://pic.rmb.bdstatic.com/…png?x-bce-process=…"}
//        data.playlet_tags[0]    = {tag_id:1, name:"热播剧"}      （共 12 个）
//        data.my_collection/my_record/playlet_feed_tags = {list,pn,rn,has_more}
// POST /haokan/ui-feed/playletTagsFeed?osbranch=a0    body=tag_id=1&pn=1&rn=9&cateId=1
//      → 200 · status=0 · data.list[0] = {playlet_id:"9175494588921467958",
//          playlet_title:"假太监的我 被娘娘强行诞下龙嗣",
//          episodes_num_text:"153集", progress_vid:"3549555209703517460", …}
// POST /appui/api?osbranch=a0   body=video/commonlist=&id=9175494588921467958
//      → 200 · status=0 · data={response_count:0, has_more:0, has_pre:0, results:[], ctime:""}  ← 空
// POST /haokan/ui-video/playlet/rec/detail?osbranch=a0  body=playlet_id=<真 id>
//      → 200 · status=3 · msg="参数错误"
// GET  /haokan/ui-feed/playletShelfFeed?osbranch=a0&from=feed
//      → **404**（证明必须 POST）
// ```
//
// # 契约边界（Lead 已裁定）
//
// ```text
// · loadPic   ⇒ 封面来自 `pic.rmb.bdstatic.com`（公开 CDN），不需额外头 ⇒ 不写 cover_headers
// · mProxy    ⇒ ★ **已知缺口**：原版有代理能力，本批不做。
// · initApi   ⇒ 本仓无该 API；等价物是 `ext`（本类 ext 为 null，不影响）
// · isVideoFormat / manualVideoCheck
//             ⇒ ★ DEX 里 ShortHaokan **没有** override 这两个（12 个方法里没有）
//                ⇒ **本仓无等价位，未实现**（如实登记，不臆造）
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 站点根（DEX 常量逐字）
pub const BASE: &str = "https://sv.baidu.com";

/// ★ 移动端 UA（DEX 逐字）—— 桌面 UA 会被拒
const UA: &str = "Mozilla/5.0 (Linux; Android 11; M2012K10C Build/RP1A.200720.011; wv) \
AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/87.0.4280.141 Mobile Safari/537.36";
/// DEX 里写死的 Cookie
const COOKIE: &str = "BAIDUCUID=giHCu0azv80G8SfQ0avU8gaaH8jfiv86ju2MugiR2i8-k3a35avAa1_mA";
const TALOS_VERSION: &str = "1.0.71.1";
const TALOS_NAME: &str = "shortDrama";

/// 列表每页条数（DEX 模板里的 `rn=9`）
pub const LIST_RN: u32 = 9;

const POST_TIMEOUT: Duration = Duration::from_secs(20);

pub struct ShortHaokan {
    client: super::http_context::CspHttpContext,
}

impl ShortHaokan {
    pub const CLASS: &'static str = "ShortHaokan";

    /// 首页分类（**兜底**）
    ///
    /// # 为什么会有兜底表
    /// ```text
    /// 真分类来自 home() 的 `data.playlet_tags`（实测 12 个，tag_id + name）。
    /// 但 home() 若失败，分类条会空 ⇒ 用 DEX 常量里出现过的 `2739` 作为**唯一兜底**。
    /// ★ 注意：`2739` 是 DEX 常量里那个孤立的 tag_id（在 homeContent 段），
    ///   它的**名字**DEX 里没有 ⇒ 兜底名写"全部"，**不臆造**一个像样的分类名。
    /// ```
    pub const FALLBACK_TAG: (&'static str, &'static str) = ("2739", "全部");

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| reqwest::Client::builder()
            .user_agent(UA)
            .timeout(POST_TIMEOUT)
            // Unbound sites remain direct; the context applies the current app policy.
            .no_proxy()
        );
        Self { client }
    }

    /// 统一 POST（表单体）—— ★ 全部端点都走这里（见文件头①）
    async fn post_form(&self, url: &str, fields: &[(&str, &str)]) -> Result<serde_json::Value, String> {
        let resp = self
            .client
            .client()?
            .post(url)
            // ★ 表单体里可能出现 `/`（如 `video/commonlist`）⇒ 用 form 让 reqwest 自行编码，
            //   但键名里的 `/` **必须保留**（实测不编码才对）⇒ 见 post_appui 里手拼
            .header(reqwest::header::COOKIE, COOKIE)
            .header("Talos-Module-Version", TALOS_VERSION)
            .header("Talos-Module-Name", TALOS_NAME)
            .form(fields)
            .send()
            .await
            .map_err(|e| format!("POST {url} 失败：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取 POST {url} 响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "POST {url} 返回 HTTP {status}；响应前 200 字节：{}",
                truncate(&body, 200)
            ));
        }
        serde_json::from_str(&body).map_err(|e| {
            format!(
                "POST {url} 不是合法 JSON：{e}；响应前 200 字节：{}",
                truncate(&body, 200)
            )
        })
    }

    /// ★ `appui/api` 专用：把**方法名当表单键**、值留空，参数另用 `&k=v` 拼
    ///
    /// # 为什么不能复用 `post_form`
    /// ```text
    /// reqwest 的 `.form()` 会把键名里的 `/` 编码成 %2F ⇒ 上游不认（实测）。
    /// 实测正确形态是**手拼体**：`video/commonlist=&id=<id>`（`/` 原样、值留空）。
    /// ```
    async fn post_appui(
        &self,
        method: &str,
        id: &str,
        extra: &[(&str, &str)],
    ) -> Result<serde_json::Value, String> {
        let url = format!("{BASE}/appui/api?osbranch=a0");
        self.post_appui_url(&url, method, id, extra).await
    }

    async fn post_appui_url(
        &self,
        url: &str,
        method: &str,
        id: &str,
        extra: &[(&str, &str)],
    ) -> Result<serde_json::Value, String> {
        let mut body = format!("{method}=&id={}", urlencode(id));
        for (k, v) in extra {
            body.push('&');
            body.push_str(&format!("{}={}", k, urlencode(v)));
        }
        let resp = self
            .client
            .client()?
            .post(url)
            .header(reqwest::header::COOKIE, COOKIE)
            .header(reqwest::header::CONTENT_TYPE, "application/x-www-form-urlencoded; charset=utf-8")
            .header("Talos-Module-Version", TALOS_VERSION)
            .header("Talos-Module-Name", TALOS_NAME)
            .body(body)
            .send()
            .await
            .map_err(|e| format!("POST {url} 失败：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取 POST {url} 响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "POST {url} 返回 HTTP {status}；响应前 200 字节：{}",
                truncate(&text, 200)
            ));
        }
        serde_json::from_str(&text).map_err(|e| {
            format!(
                "POST {url} 不是合法 JSON：{e}；响应前 200 字节：{}",
                truncate(&text, 200)
            )
        })
    }
}

impl Default for ShortHaokan {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数（hermetic 可测）
// ═══════════════════════════════════════════════════════════════════════

fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

pub fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// ★ 成功码是 `status == 0`（与 code==0 / 200 都不同）
///
/// # 实测见过的其他值（全部**不是**成功）
/// ```text
/// 3      → "参数错误"           （rec/detail 缺必需参数时）
/// 7      → "非法请求"           （appui 参数被当成方法名时）
/// 101001 → "param error: id is required"
/// ⇒ 只看 HTTP 200 会把上面三种都当成功（它们是 **HTTP 200 + 业务失败**）。
/// ```
pub fn check_status(v: &serde_json::Value, what: &str) -> Result<(), String> {
    match v.get("status").and_then(|s| s.as_i64()) {
        Some(0) => Ok(()),
        Some(other) => Err(format!(
            "{what} 业务 status 非 0：status={other}, msg={}",
            v.get("msg").and_then(|m| m.as_str()).unwrap_or("(无)")
        )),
        None => Err(format!(
            "{what} 响应缺少 status 字段：{}",
            truncate(&v.to_string(), 200)
        )),
    }
}

/// 首页响应 → `CspHome`
///
/// 分类来自 `data.playlet_tags[]`（tag_id + name）；
/// 首屏条目取 `data.playlet_feed_tags.list[]`（**它是真内容**，实测非空）
/// 若它空，再退到 `data.playlet_banner[]`（实测 2 条）。
pub fn parse_home(v: &serde_json::Value) -> Result<CspHome, String> {
    check_status(v, "home(playletShelfFeed)")?;
    let data = v
        .get("data")
        .ok_or_else(|| format!("home 响应没有 data：{}", truncate(&v.to_string(), 200)))?;

    // ── 分类 ──
    let tags = data
        .get("playlet_tags")
        .and_then(|t| t.as_array())
        .ok_or_else(|| {
            format!(
                "home 的 data 里没有 playlet_tags 数组 ⇒ 结构可能变了：{}",
                truncate(&data.to_string(), 200)
            )
        })?;
    let mut categories = Vec::with_capacity(tags.len());
    for t in tags {
        let id = t
            .get("tag_id")
            .and_then(|x| x.as_i64().map(|n| n.to_string()).or_else(|| x.as_str().map(|s| s.to_string())));
        let name = t.get("name").and_then(|n| n.as_str());
        if let (Some(id), Some(name)) = (id, name) {
            if !id.is_empty() && !name.is_empty() {
                categories.push(CspCategory {
                    id,
                    name: name.to_string(),
                });
            }
        }
    }
    // ★ 反空真：playlet_tags 非空却一个分类都建不出来 ⇒ 结构变了
    if categories.is_empty() && !tags.is_empty() {
        return Err(format!(
            "playlet_tags 有 {} 条但都缺 tag_id/name ⇒ 结构可能变了：{}",
            tags.len(),
            truncate(&tags[0].to_string(), 200)
        ));
    }
    // 兜底：真分类拿不到时至少给一条（否则分类条空 ⇒ UI 无处可点）
    if categories.is_empty() {
        /*
         * ⚠️ 这里**必须写 `ShortHaokan::FALLBACK_TAG`，不能写 `Self::FALLBACK_TAG`**。
         *   `parse_home` 是**自由函数**（不在 `impl ShortHaokan` 里）⇒ `Self` 在此**无定义**
         *   ⇒ E0433 "failed to resolve: `Self`"。
         *   ★ 这个错是 Lead 在我"加行试编"时抓到的（我此前只做了语法层自查，
         *     **没进编译单元** ⇒ 静态自查查不出这类**作用域**错）。
         *   ⇒ 教训：**不进编译单元的"自查通过"不算通过**（与"两次判据假绿"同族）。
         */
        categories.push(CspCategory {
            id: ShortHaokan::FALLBACK_TAG.0.to_string(),
            name: ShortHaokan::FALLBACK_TAG.1.to_string(),
        });
    }

    // ── 首屏条目 ──
    let items = collect_playlets(data);
    Ok(CspHome { categories, items })
}

/// 从 home 的 data 里收条目（优先 `playlet_feed_tags.list`，退到 `playlet_banner`）
pub fn collect_playlets(data: &serde_json::Value) -> Vec<CspItem> {
    let mut out: Vec<CspItem> = Vec::new();
    for key in ["playlet_feed_tags", "playlet_book"] {
        if let Some(list) = data.pointer(&format!("/{key}/list")).and_then(|l| l.as_array()) {
            extend_from_list(list, &mut out);
            if !out.is_empty() {
                return out;
            }
        }
    }
    if let Some(list) = data.get("playlet_banner").and_then(|l| l.as_array()) {
        extend_from_list(list, &mut out);
    }
    out
}

/// 从一堆 playlet 项里取 id / 标题 / 封面
pub fn extend_from_list(list: &[serde_json::Value], out: &mut Vec<CspItem>) {
    for row in list {
        let Some(id) = row
            .get("playlet_id")
            .and_then(|i| i.as_str().map(|s| s.to_string()).or_else(|| i.as_i64().map(|n| n.to_string())))
        else {
            continue;
        };
        if id.is_empty() {
            continue;
        }
        let title = row
            .get("playlet_title")
            .and_then(|t| t.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or("（上游未给标题）")
            .to_string();
        let cover = row
            .get("playlet_poster")
            .and_then(|c| c.as_str())
            .filter(|s| s.starts_with("http"))
            .map(|s| s.to_string());
        // 副标题：集数文案（实测 `episodes_num_text` 形如 "153集"）
        let subtitle = row
            .get("episodes_num_text")
            .and_then(|s| s.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string());
        if out.iter().any(|e| e.id == id) {
            continue; // 去重（同一 playlet 可能在多个子列表里出现）
        }
        out.push(CspItem {
            id,
            title,
            cover,
            subtitle,
        });
    }
}

/// 分类列表响应 → `CspList`
///
/// # ★ `data.list == null` 是**假成功**（实测踩过）
/// ```text
/// 我第一次请求漏了 `cateId` ⇒ 返回 `{"status":0,"msg":"成功","data":{"list":null,"pn":1,"rn":0,"has_more":1}}`
/// ⇒ **status 说成功、list 却是 null、rn=0**（一条都没给）。
/// ⇒ 这里显式判：`list` 若是 **null** ⇒ 报"参数可能不全"（而不是当成"这个分类没内容"）。
///    与本仓"不许静默返回空冒充成功"一致。
/// ```
pub fn parse_list(v: &serde_json::Value, page: u32) -> Result<CspList, String> {
    check_status(v, "list(playletTagsFeed)")?;
    let data = v
        .get("data")
        .ok_or_else(|| format!("list 响应没有 data：{}", truncate(&v.to_string(), 200)))?;

    // ★ `list` 为 null ⇔ 参数不全（实测），**必须**与"真·空列表"区分开
    let raw = data.get("list");
    match raw {
        None => {
            return Err(format!(
                "list 响应 data 里没有 list 字段 ⇒ 结构可能变了：{}",
                truncate(&data.to_string(), 200)
            ))
        }
        Some(serde_json::Value::Null) => {
            return Err(
                "list 为 null（实测=请求参数不全，如缺 cateId）⇒ 不是'这个分类没内容'，\
                 请检查参数"
                    .to_string(),
            )
        }
        Some(serde_json::Value::Array(_)) => {}
        Some(other) => {
            return Err(format!(
                "list 不是数组也不是 null：{}",
                truncate(&other.to_string(), 200)
            ))
        }
    }
    /*
     * ⚠️ 这里用 `raw.unwrap().as_array()` 而不是 `raw.and_then(|l| l.as_array()).unwrap_or(&[])`。
     *   原因：`unwrap_or(&[])` 的 `&[]` 会被推成 `&[Value; 0]`（**数组**引用），
     *         而 `as_array()` 返回 `&Vec<Value>` ⇒ **类型不符**（E0308）。
     *   ★ 上面那个 `match` **已经**把"必须走到这里的形态"收敛成 `Some(Array)` 了
     *     ⇒ 直接 `unwrap().as_array().unwrap()` 是**由类型证明安全**的，
     *       再套一个 `unwrap_or(&[])` 反而既错又掩盖了逻辑。
     *   ★ 这个错也是 Lead 试编时抓到的（同上一处：静态自查查不出类型/作用域错）。
     */
    let list = raw
        .and_then(|l| l.as_array())
        .expect("上面的 match 已保证这里是数组");

    let mut items = Vec::new();
    extend_from_list(list, &mut items);

    // ★ 反空真：list 非空却取不到条目 ⇒ 结构变了
    if items.is_empty() && !list.is_empty() {
        return Err(format!(
            "list 有 {} 条但都缺 playlet_id ⇒ 结构可能变了：{}",
            list.len(),
            truncate(&list[0].to_string(), 200)
        ));
    }

    Ok(CspList {
        items,
        page,
        // ★ 上游给 `has_more`（0/1）但**不给总页数** ⇒ 如实 None，不猜
        page_count: None,
        total: None,
    })
}

/// `has_more` 是否为真 —— **整数 / 布尔 / 字符串三形态都认**
///
/// # ⚠️ 这里修过一次（**交叉复核者报的确认缺陷**，我采纳）
/// ```text
/// 第一版：`.and_then(|h| h.as_i64()).map(|n| n != 0).unwrap_or(false)`
/// 复核者（csp-batch-a）的判据 + 我自己的实测推理：
///   · 上游若把 `has_more` 改成 **布尔** `true`
///     ⇒ `as_i64()` 在布尔上返回 **None** ⇒ 落到 `unwrap_or(false)`
///     ⇒ **判成"没有下一页"**（与真意相反）⇒ 现象是"翻到第一页就没了"（静默少页）
///   · **字符串** `"1"` 同理（`as_i64()` 对字符串返回 None）
/// ★ 复核者的原话（我逐字接受）："这是**真缺口、且门禁没覆盖**"
///   （它 grep 过 8 类门禁，**没有**一条喂布尔形态的 `has_more`）
/// ```
///
/// # 现在的判据（三形态 + 保留原 0 支）
/// ```text
/// 缺失      → false（保持原行为：没这个字段就当没有下一页）
/// 整数 n    → n != 0            ← 保留（I4b 注入已证这一支被门禁钉住）
/// 布尔 b    → b                 ← 新增
/// 字符串 s  → !(s.is_empty() || s == "0")   ← 新增（兼容 "1"/"true"/"0"/""）
/// 其它类型  → false（保守）
/// ```
/// ★ 并**补了夹具**（布尔 `true` / 字符串 `"1"`）—— 修缺陷的同时堵住"门禁没覆盖"这个口子。
pub fn has_more(v: &serde_json::Value) -> bool {
    match v.pointer("/data/has_more") {
        None | Some(serde_json::Value::Null) => false,
        Some(serde_json::Value::Bool(b)) => *b,
        Some(serde_json::Value::Number(n)) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Some(serde_json::Value::String(s)) => !(s.is_empty() || s == "0" || s == "false"),
        Some(_) => false,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for ShortHaokan {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let url = format!("{BASE}/haokan/ui-feed/playletShelfFeed?osbranch=a0");
        // ★ POST + 表单体 `from=feed`（GET 是 404，见文件头①）
        let v = self.post_form(&url, &[("from", "feed")]).await?;
        parse_home(&v)
    }

    /// 分类列表：**必须带 `cateId`**（实测漏了就 list:null）
    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        // tag_id 必须是数字（DEX 模板如此）
        if !tid.chars().all(|c| c.is_ascii_digit()) {
            return Err(format!("分类 id（tag_id）必须是数字：{tid}"));
        }
        let page = if page == 0 { 1 } else { page };
        let url = format!("{BASE}/haokan/ui-feed/playletTagsFeed?osbranch=a0");
        let pn = page.to_string();
        let rn = LIST_RN.to_string();
        let v = self
            .post_form(
                &url,
                // ★ 四个参数缺一不可（`cateId` 是实测发现的那个"缺了就假成功"的）
                &[("tag_id", tid), ("pn", &pn), ("rn", &rn), ("cateId", tid)],
            )
            .await?;
        parse_list(&v, page)
    }

    /// ★ detail：**未打通** —— 如实报错（不猜参数、不伪造线路）
    ///
    /// # 已实测排除的路径（留档，供将来接手）
    /// ```text
    /// · POST /haokan/ui-video/playlet/rec/detail?osbranch=a0
    ///     带 playlet_id=<真 id>（试过 banner / tagsFeed / progress_vid 三种真 id）
    ///     → 全部 status=3 "参数错误"
    ///     另试过参数组合：cid / id / from / tag_id / pn / rn / cateId / osbranch / rec_type
    /// · POST /appui/api  `video/commonlist=&id=<真 id>`
    ///     → **status=0 成功**，但 data.response_count=0 · results=[]（**空**）
    ///     （提交的 id 是 playlet_id 与 progress_vid 两种真 id）
    /// · POST /appui/api  `video/relate=&id=<真 id>`
    ///     → status=101001 "param error: id is required"
    /// ⇒ 我**不再换参数猜**（那是"造一个无法证伪的形态"）。
    /// ```
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        Err(format!(
            "csp_ShortHaokan 的详情未打通（实测：rec/detail 对 playlet_id={} 返回 status=3 参数错误；\
             appui 的 video/commonlist 返回 status=0 但 results 为空）⇒ 本类「如实未实现详情」，\
             可能缺一个未探到的必需参数或需要登录态。不做参数猜测。",
            truncate(id, 40)
        ))
    }

    /// ★ play：依赖 detail 的 vid/clarityUrl ⇒ 同样「未打通」，如实报错
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        Err(format!(
            "csp_ShortHaokan 的取流未打通：DEX 的 playerContent 走 appui 的 `video/relate` 取 \
             data.cur_video.clarityUrl，而该接口对未登录返回 status=101001（实测）⇒ 取不到直链。\
             不做参数猜测（id={}）。",
            truncate(id, 40)
        ))
    }

    /// DEX 里 ShortHaokan **有** searchContent？—— DEX 的 12 个方法里**没有**它
    ///
    /// ⚠️ 这与我最初从常量读到的印象相反（常量里有 `curl`/`kw` 感觉的串）
    /// ⇒ 按**方法表**（权威）判：**没有** searchContent ⇒ 如实声明不支持。
    fn supports_search(&self) -> bool {
        false
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("csp_ShortHaokan 不支持搜索（原版 ShortHaokan 无 searchContent 实现）".to_string())
    }
}

// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
//
// # 这个类的事实（别丢）
// ```text
// csp_ShortHaokan（💞好看丨短剧爽看）：★ **部分可用**（如实分档）
//   ✅ home  POST playletShelfFeed(from=feed)          → 200 · 16968 B · status=0 · 12 个 tag
//   ✅ list  POST playletTagsFeed(tag_id&pn&rn&cateId) → 200 · status=0 · 真内容
//      ★ `cateId` 缺了会**假成功**（status=0 但 list=null、rn=0）—— 已写进门禁
//   ⚠️ detail/play **未打通**（rec/detail → status=3；appui commonlist → results 空）
//      ⇒ 如实报错，**不猜参数**（试过 10+ 种组合，见 detail() 的留档）
// ★ 三处"常量 ≠ 真站点"：
//   ① 端点看着是 GET+查询串，**必须 POST 表单体**（GET playletShelfFeed = 404）
//   ② appui/api 是**"方法名当表单键"**的分派接口：`video/commonlist=&id=<id>`（键里 `/` 不编码、值留空）
//   ③ 成功码是 **status==0**（见过 3/7/101001 都是 HTTP 200 的失败）
// ★ 移动端 UA（Android 11 / Chrome 87）+ DEX 写死的 BAIDUCUID Cookie
// ⚠️ 已知缺口：原版有 mProxy，本批不做
// ```
crate::csp::register_site!(ShortHaokan);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
#[path = "short_haokan_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实 home 响应片段（2026-10-27 实测，裁剪）
    const FIX_HOME: &str = r#"{
      "status": 0, "msg": "成功",
      "data": {
        "playlet_banner": [
          {"playlet_id": "9161446330548442445", "playlet_title": "逆袭人生之飞龙在天",
           "playlet_poster": "https://pic.rmb.bdstatic.com/baidu-rmb-video-cover-1/x.png",
           "description": "身怀武侠梦的农村穷小子…"}
        ],
        "my_collection": {"list": [], "pn": 1, "rn": 9, "has_more": 0},
        "my_record": {"list": [], "pn": 1, "rn": 9, "has_more": 0},
        "playlet_book": null,
        "playlet_feed_tags": {"list": [
          {"playlet_id": "9175494588921467958", "playlet_title": "假太监的我 被娘娘强行诞下龙嗣",
           "playlet_poster": "https://pic.rmb.bdstatic.com/bjh/x.JPEG",
           "episodes_num_text": "153集", "progress_vid": "3549555209703517460"}
        ], "pn": 1, "rn": 9, "has_more": 1},
        "playlet_tags": [
          {"tag_id": 1, "name": "热播剧"}, {"tag_id": 2, "name": "都市"}
        ]
      }
    }"#;

    /// 真实 list 响应片段（带 cateId，**成功**）
    const FIX_LIST_OK: &str = r#"{
      "status": 0, "msg": "成功",
      "data": {"list": [
        {"playlet_id": "9175494588921467958", "playlet_title": "假太监的我 被娘娘强行诞下龙嗣",
         "playlet_poster": "https://pic.rmb.bdstatic.com/bjh/260d900e.JPEG",
         "episodes_num_text": "153集"}
      ], "pn": 1, "rn": 9, "has_more": 1}
    }"#;

    /// ★ 真实 list 响应片段（**漏 cateId** ⇒ status=0 但 list=null 的**假成功**）
    const FIX_LIST_FAKE_OK: &str = r#"{
      "status": 0, "msg": "成功",
      "data": {"list": null, "pn": 1, "rn": 0, "has_more": 1}
    }"#;

    fn j(s: &str) -> serde_json::Value {
        serde_json::from_str(s).expect("夹具必须是合法 JSON")
    }

    // ── ★ 成功码 status==0 ────────────────────────────────────────

    #[test]
    /// ★ 成功码 `status==0`（注入：改成 `==200` ⇒ 本条 + 全部业务用例红）
    fn status_zero_is_success_here() {
        assert!(check_status(&j(r#"{"status":0,"msg":"成功","data":{}}"#), "t").is_ok());
    }

    #[test]
    /// ★ 实测见过的三种失败码（它们都是 **HTTP 200 + 业务失败**）
    fn business_failures_are_not_success() {
        for (code, msg) in [(3, "参数错误"), (7, "非法请求"), (101001, "param error: id is required")] {
            let v = j(&format!(r#"{{"status":{code},"msg":"{msg}","data":{{}}}}"#));
            let err = check_status(&v, "t").unwrap_err();
            assert!(err.contains("status 非 0"), "{err}");
            assert!(err.contains(msg), "错误信息要点出上游 msg：{err}");
        }
    }

    #[test]
    fn missing_status_is_error() {
        let err = check_status(&j(r#"{"data":{}}"#), "t").unwrap_err();
        assert!(err.contains("缺少 status"), "{err}");
    }

    // ── parse_home ────────────────────────────────────────────────

    #[test]
    fn home_categories_from_playlet_tags() {
        let h = parse_home(&j(FIX_HOME)).expect("真响应必须解析得出来");
        assert_eq!(h.categories.len(), 2);
        assert_eq!(h.categories[0].id, "1");
        assert_eq!(h.categories[0].name, "热播剧");
        assert_eq!(h.categories[1].id, "2");
        assert_eq!(h.categories[1].name, "都市");
    }

    #[test]
    /// 首屏条目优先取 `playlet_feed_tags.list`（实测它是真内容）
    fn home_items_prefer_feed_tags_list() {
        let h = parse_home(&j(FIX_HOME)).unwrap();
        assert_eq!(h.items.len(), 1);
        assert_eq!(h.items[0].id, "9175494588921467958");
        assert_eq!(h.items[0].subtitle.as_deref(), Some("153集"), "副标题 = episodes_num_text");
        assert!(h.items[0].cover.as_deref().unwrap_or("").starts_with("https://pic.rmb.bdstatic.com"));
    }

    #[test]
    /// `playlet_feed_tags.list` 为空时退到 `playlet_banner`
    fn home_items_fall_back_to_banner() {
        let v = j(r#"{"status":0,"msg":"成功","data":{"playlet_feed_tags":{"list":[]},
            "playlet_tags":[{"tag_id":1,"name":"热播剧"}],
            "playlet_banner":[{"playlet_id":"999","playlet_title":"某剧"}]}}"#);
        let h = parse_home(&v).unwrap();
        assert_eq!(h.items.len(), 1);
        assert_eq!(h.items[0].id, "999");
    }

    #[test]
    /// ★ 反空真 ①：`playlet_tags` 非空却都缺 tag_id/name ⇒ 报错
    fn home_with_unmappable_tags_is_error() {
        let v = j(r#"{"status":0,"data":{"playlet_tags":[{"name":""}],"playlet_banner":[]}}"#);
        let err = parse_home(&v).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// ★ 反空真 ②（成对）：`playlet_tags` **本就是空数组** ⇒ 给兜底分类（不是报错）
    fn home_with_empty_tags_falls_back_not_error() {
        let v = j(r#"{"status":0,"msg":"成功","data":{"playlet_tags":[],"playlet_banner":[]}}"#);
        let h = parse_home(&v).expect("真·无分类不该报错");
        assert_eq!(h.categories.len(), 1, "给一条兜底分类");
        assert_eq!(h.categories[0].id, ShortHaokan::FALLBACK_TAG.0);
        assert_eq!(h.categories[0].name, "全部", "★ 兜底名不臆造具体分类名");
    }

    #[test]
    fn home_without_playlet_tags_is_error() {
        let err = parse_home(&j(r#"{"status":0,"data":{}}"#)).unwrap_err();
        assert!(err.contains("没有 playlet_tags"), "{err}");
    }

    // ── parse_list ────────────────────────────────────────────────

    #[test]
    fn list_parses_real_items() {
        let l = parse_list(&j(FIX_LIST_OK), 1).expect("真响应必须解析得出来");
        assert_eq!(l.items.len(), 1);
        assert_eq!(l.items[0].id, "9175494588921467958");
        assert_eq!(l.items[0].title, "假太监的我 被娘娘强行诞下龙嗣");
        assert_eq!(l.items[0].subtitle.as_deref(), Some("153集"));
        assert!(has_more(&j(FIX_LIST_OK)), "has_more=1");
    }

    #[test]
    /// ★★ 本条是本类**最有价值**的判据：`list == null` 是**假成功**（漏 cateId）
    ///
    /// ```text
    /// 实测：漏 `cateId` ⇒ {"status":0,"msg":"成功","data":{"list":null,"pn":1,"rn":0,"has_more":1}}
    /// ⇒ status 说成功、一条都没有 ⇒ 若不显式判 null，会静默返回空列表（**假成功**）。
    /// ```
    /// 注入：把 `parse_list` 里那个 `Value::Null` 分支删掉 ⇒ 本条红。
    #[test]
    fn list_is_null_means_params_incomplete_not_empty_ok() {
        let err = parse_list(&j(FIX_LIST_FAKE_OK), 1).unwrap_err();
        assert!(err.contains("参数不全"), "★ 必须报'参数不全'而不是静默空：{err}");
        assert!(err.contains("cateId"), "错误信息要点出缺的那个参数：{err}");
    }

    #[test]
    /// ★ 反空真 ③（成对）：`list` 是**真数组但空** ⇒ 正常（该分类真没内容）
    fn list_with_genuinely_empty_array_is_ok() {
        let v = j(r#"{"status":0,"msg":"成功","data":{"list":[],"pn":1,"rn":9,"has_more":0}}"#);
        let l = parse_list(&v, 1).expect("真·空列表不是错误");
        assert!(l.items.is_empty());
        assert!(!has_more(&v));
    }

    #[test]
    /// ★★ 三形态 `has_more`（**交叉复核者报的确认缺陷**，本条是修它时补的门禁）
    ///
    /// # 缺陷原文（复核者 csp-batch-a）
    /// ```text
    /// "ShortHaokan::has_more 不认**布尔/字符串**形态
    ///  ⇒ 上游若把 has_more 改成 `true` ⇒ 判成'没有下一页'（静默少页）
    ///  建议：三形态都认 + 加布尔/字符串夹具；**保留** 0⇒false（I4b 已证有牙）"
    /// ```
    /// **注入**：把 `has_more` 改回只认整数
    /// （`.and_then(|h| h.as_i64()).map(|n| n != 0).unwrap_or(false)`）⇒
    /// 本条中 `true` / `"1"` 两个断言立刻红（它们会得到 `false`）。
    fn has_more_accepts_int_bool_and_string_forms() {
        // 整数形态（原行为，**必须保留** —— 复核者的 I4b 注入已证这一支被钉住）
        let int_true = j(r#"{"data":{"has_more":1}}"#);
        let int_false = j(r#"{"data":{"has_more":0}}"#);
        assert!(has_more(&int_true), "整数 1 ⇒ true");
        assert!(!has_more(&int_false), "整数 0 ⇒ false（★ 复核者 I4b 证过这支有牙）");

        // ★ 布尔形态（缺陷点：旧实现在这里会返回 false）
        let bool_true = j(r#"{"data":{"has_more":true}}"#);
        let bool_false = j(r#"{"data":{"has_more":false}}"#);
        assert!(has_more(&bool_true), "★ 布尔 true ⇒ true（旧实现会误判成 false）");
        assert!(!has_more(&bool_false), "布尔 false ⇒ false");

        // ★ 字符串形态（缺陷点：旧实现同样返回 false）
        for (raw, want) in [
            (r#"{"data":{"has_more":"1"}}"#, true),
            (r#"{"data":{"has_more":"true"}}"#, true),
            (r#"{"data":{"has_more":"0"}}"#, false),
            (r#"{"data":{"has_more":""}}"#, false),
            (r#"{"data":{"has_more":"false"}}"#, false),
        ] {
            assert_eq!(has_more(&j(raw)), want, "字符串形态：{raw}");
        }

        // 缺失 / null ⇒ false（原行为保持）
        assert!(!has_more(&j(r#"{"data":{}}"#)), "缺字段 ⇒ false");
        assert!(!has_more(&j(r#"{"data":{"has_more":null}}"#)), "null ⇒ false");
    }

    #[test]
    /// ★ 三形态的 `has_more` 在**列表路径**上也生效（不只函数本身）
    fn list_path_carries_three_form_has_more() {
        let v = j(r#"{"status":0,"msg":"成功","data":{"list":[
            {"playlet_id":"1","playlet_title":"某剧"}],"has_more":true}}"#);
        let l = parse_list(&v, 1).expect("布尔 has_more 不该影响解析");
        assert_eq!(l.items.len(), 1);
        assert!(has_more(&v), "★ 布尔 true 经列表路径也要判出 true");

        let v2 = j(r#"{"status":0,"msg":"成功","data":{"list":[],"has_more":"0"}}"#);
        assert!(!has_more(&v2), "★ 字符串 \"0\" 经列表路径要判出 false");
    }

    #[test]
    /// ★ 反空真 ④：list 非空却都缺 playlet_id ⇒ 报错
    fn list_with_unmappable_rows_is_error() {
        let v = j(r#"{"status":0,"data":{"list":[{"playlet_title":"无 id"}]}}"#);
        let err = parse_list(&v, 1).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    fn list_without_list_field_is_error() {
        let err = parse_list(&j(r#"{"status":0,"data":{"pn":1}}"#), 1).unwrap_err();
        assert!(err.contains("没有 list 字段"), "{err}");
    }

    #[test]
    fn list_with_non_array_non_null_is_error() {
        let err = parse_list(&j(r#"{"status":0,"data":{"list":"oops"}}"#), 1).unwrap_err();
        assert!(err.contains("不是数组也不是 null"), "{err}");
    }

    // ── appui 体形态（判据钉住手拼体）───────────────────────────

    #[test]
    /// ★ appui 是"方法名当表单键、值留空、参数另用 &id=" —— 键里的 `/` **不编码**
    ///
    /// 注入：把方法名编码成 `video%2Fcommonlist` ⇒ 本条红（上游不认，实测）。
    fn appui_body_shape_is_hand_built() {
        let method = "video/commonlist";
        let id = "9175494588921467958";
        let body = format!("{method}=&id={}", urlencode(id));
        assert_eq!(body, "video/commonlist=&id=9175494588921467958");
        assert!(!body.contains("%2F"), "★ 键里的 / 必须原样（不编码）");
        assert!(body.starts_with("video/commonlist=&"), "★ 方法名当键、值留空");
    }

    #[test]
    /// 中文 id 会被 urlencode（防御性：id 一般纯数字，但不许拼出畸形体）
    fn urlencode_handles_non_ascii() {
        assert_eq!(urlencode("红"), "%E7%BA%A2");
        assert_eq!(urlencode("abc123"), "abc123");
    }

    // ── 能力位 ────────────────────────────────────────────────────

    #[test]
    /// ★ DEX 的 12 个方法里**没有** searchContent ⇒ 如实声明不支持
    ///
    /// 注入：把 `supports_search` 改成 true ⇒ 本条红。
    fn search_is_declared_unsupported() {
        assert!(
            !ShortHaokan::new().supports_search(),
            "★ DEX 方法表里没有 searchContent ⇒ 不许给假能力位"
        );
    }

    #[tokio::test]
    async fn search_returns_honest_error() {
        let err = ShortHaokan::new().search("红", 1, "").await.unwrap_err();
        assert!(err.contains("不支持搜索"), "{err}");
    }

    #[tokio::test]
    /// ★ detail **如实报错**（不猜参数、不伪造线路）
    async fn detail_reports_honestly_unimplemented() {
        let err = ShortHaokan::new().detail("9175494588921467958", "").await.unwrap_err();
        assert!(err.contains("未打通"), "{err}");
        assert!(err.contains("不做参数猜测"), "错误信息要声明不猜参数：{err}");
    }

    #[tokio::test]
    async fn detail_rejects_empty_id() {
        let err = ShortHaokan::new().detail("  ", "").await.unwrap_err();
        assert!(err.contains("条目 id 为空"), "{err}");
    }

    #[tokio::test]
    /// ★ play 同样**如实报错**，并说明卡在 `video/relate` 的 101001
    async fn play_reports_honestly_unimplemented() {
        let err = ShortHaokan::new().play("短剧", "9175494588921467958", "").await.unwrap_err();
        assert!(err.contains("未打通"), "{err}");
        assert!(err.contains("101001"), "要点出实测的卡点码：{err}");
    }

    #[tokio::test]
    async fn list_rejects_non_numeric_tag_id() {
        let err = ShortHaokan::new().list("abc", 1, "").await.unwrap_err();
        assert!(err.contains("必须是数字"), "{err}");
    }

    #[tokio::test]
    async fn list_rejects_empty_tag_id() {
        let err = ShortHaokan::new().list("  ", 1, "").await.unwrap_err();
        assert!(err.contains("分类 id 为空"), "{err}");
    }

    // ── 真网络（默认不跑；显式跑必须给 CSP_LIVE=1）──

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib short_haokan_live -- --ignored --nocapture"]
    async fn short_haokan_live_home_list_and_honest_gaps() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = ShortHaokan::new();

        let home = s.home("").await.expect("home 必须真取到数据（POST playletShelfFeed）");
        assert!(!home.categories.is_empty(), "★ 反空真：必须有分类");
        assert!(!home.items.is_empty(), "★ 反空真：首屏必须有真条目");
        println!(
            "LIVE home：分类 {} 个（首={}），首屏 {} 条（首条={}）",
            home.categories.len(),
            home.categories[0].name,
            home.items.len(),
            home.items[0].title
        );

        let tag = home.categories[0].id.clone();
        let list = s.list(&tag, 1, "").await.expect("list 必须真取到数据（POST playletTagsFeed）");
        assert!(!list.items.is_empty(), "★ 反空真：分类列表必须有真条目");
        println!("LIVE list tag={tag}：{} 条，首条={}", list.items.len(), list.items[0].title);
        for it in list.items.iter().take(3) {
            println!("    - {}（{}）", it.title, it.subtitle.clone().unwrap_or_default());
        }

        // ★ ★ 关键读数：GET 必须是 404（证明"必须 POST"这条校正）
        let get_attempt = reqwest::Client::new()
            .get(format!("{BASE}/haokan/ui-feed/playletShelfFeed?osbranch=a0&from=feed"))
            .header(reqwest::header::COOKIE, COOKIE)
            .send()
            .await;
        match get_attempt {
            Ok(r) => println!("LIVE GET 同一路径 → HTTP {}（历史读数 404 ⇒ 这就是必须 POST 的证据）", r.status()),
            Err(e) => println!(
                "LIVE GET 同一路径 → 请求失败：{e}\n\
                 ★ 本条为**诊断请求**（用默认 client，故意不加 `.no_proxy()`，以便观察真实失败形态）\
                 ⇒ 它失败**不代表生产路径坏了**；生产路径的构造链已 `.no_proxy()`\
                 （见离线门禁 `client_does_not_read_system_proxy`）。"
            ),
        }

        // ★ 如实记录 detail 的卡点（**不是失败**，是读数）
        match s.detail(&list.items[0].id, "").await {
            Ok(_) => println!("⚠️ detail 竟然通了（历史读数：status=3 参数错误）⇒ 需重新核该路径"),
            Err(e) => println!("LIVE detail 如实报错：{}", &e[..e.len().min(120)]),
        }
    }

    /// ★★ 不读系统代理（**跨批一致性**：本仓 csp 既定惯例，见 `app99.rs:342`）
    ///
    /// # 为什么这条必须在"离线门禁"里（而不是 live 里）
    /// ```text
    /// 这条断言的**对象是源码形态**（Client 构造链里有没有 `.no_proxy()`），
    /// 而不依赖网络 ⇒ **不随上游抖动**。
    /// ★ 实测背景（Lead 的跨批一致性审计 → 我复现并扩面）：
    ///   · 本机装了代理时 `reqwest` 会**默认读系统代理** ⇒ 代理对该站不可用时
    ///     报含糊的 `error sending request for url …`；
    ///   · **死代理 `:9` 实测**：本类 live **FAILED**，
    ///     而同期有 `.no_proxy()` 的类（app99 / app_drama）**仍 ok**
    ///     ⇒ 8 类里 **7 例实测坏** + 1 例特殊（`ting_shijie` 的 live 是三态设计、只打印不断言）。
    ///   ★ 后一例说明：**这类"环境缺陷"离线门禁是唯一能覆盖的地方**
    ///     （live 只打印读数 ⇒ 既不抓"我们写错"、也不抓"环境坏了"）。
    /// ```
    ///
    /// # 注入（证明本条有牙）
    /// ```text
    /// 删掉 `Client::builder()` 链上的 `.no_proxy()` ⇒ 本条 FAILED。
    /// ★ 注意：断言用 `impl_src_only(include_str!(…))` —— **必须先剥掉测试段**，
    ///   否则**本函数自己的字面量**（`".no_proxy()"`）会把门禁自己喂饱 ⇒ **假绿**。
    ///   本仓 `app_yqk.rs` 与 `shared.rs:255` 都踩过这个坑并留档。
    /// ```
    #[test]
    fn client_does_not_read_system_proxy() {
        let src = crate::csp::shared::impl_src_only(include_str!("short_haokan.rs"));
        assert!(
            src.contains(".no_proxy()"),
            "★ Client 构造链必须含 `.no_proxy()`（不读系统代理）；             否则装了代理的机器上会把'站点可用'测成'全宕'"
        );
    }
}
