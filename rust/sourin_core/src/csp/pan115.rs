// ═══════════════════════════════════════════════════════════════════════
//  csp_Pan115 —— 网盘族：列出「我的盘」根目录 / 子目录，逐条取播放地址
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一类到底做什么（先对齐语义，别照着影视站的样子写）
//
// ```text
// 影视站 csp：home 抓站点首页 → 分类 → 列表 → 详情（多集）→ 取流。
// 网盘 csp：**没有"站点"** —— 它列的是**用户自己账号里的文件**。
//   ⇒ home = 一个货架（"我的盘"），list = 某个目录下的条目，
//      detail = 把**单个文件**包装成"1 集"，play = 该文件的直链。
//   ⇒ 订阅里这条是 `"searchable":0 / "changeable":0`，正是这个原因：
//      没有分类可换、也没有远端可搜。
// ```
//
// # 取证来源（DEX 常量逐字，**没用 jadx**）
//
// ```text
// .probe/csp-parity/Pan115.txt（方法 → 字面量）
//   [collect]  https://webapi.xxx.com/files
//              ?aid=1&cid=            ← cid 是**拼接位**（目录 id 由调用方给）
//              &o=file_name&asc=1&show_dir=1&natsort=1&format=json
//              &offset= &limit=
//              state / data / n / fid / cid / "" / pc / s / count   ← **响应字段名**
//   [headApi]  UA "Mozilla/5.0 <product>/30.1.0" / Accept json / Cookie
//   [head]     UA 浏览器串 / Cookie
//   [logged]   "UID="                ← 登录判据：cookie 里有没有 UID=
//   [reason]   msg / error / msg_code / errno / 未知错误 / "(" / ")"
//   [download] 取址端点（chrome 通道）+ 备用端点（android 通道）
//              pickcode / pick_code / "｜备用端点："
//   [downloadVia] data / "{" / ?t= / "解密失败（data 长度 " / "解密结果非 JSON："
//                 "解密结果里没有 url：" …        ← ★ 响应是**加密**的
//   [pickUrl]  "" / url              ← 解密后形状：{ "<pickcode>": { "url": … } }
//   [b]        "我的115网盘" + 逐字登录提示 + "~!~" + "播放参数为空"
//   [hashCode] "目录内没有可播放的视频" / "115原画" / file
// ```
//
// # ★ 用两条**真网读数**当夹具（`.probe/parity-pan-a-live.log`，直连无代理无账号）
//
// ```text
// ① 取址端点（干净 JSON，未登录）：
//    {"state":false,"error":"请重新登录","errno":99,"request":"…","data":[]}
//    ⇒ 这正是 `[reason]` 那条梯子的输入（error 优先，末尾带 errno）。
// ② 列目录端点（不是 JSON！）：
//    HTTP **405** + 一页 CDN 拦截 HTML（`<!doctype html>…<title>405</title>…`）
//    ⇒ 所以"非 JSON 就报错"不是防御性编程，是**实测会发生的路径**；
//      文案里必须点到"拦截页/改版壳页"，否则用户会以为是自己账号坏了。
// ```
//
// # ⚠️ 诚实边界（**不许**把"没验过"说成"能用"）
//
// ```text
// 1. 列目录需要**账号 cookie**。本实现在没有 cookie / cookie 里没有 UID= 时
//    **如实报登录**（逐字用参考实现那句提示），绝不返回空列表冒充"盘是空的"。
// 2. **取址链路做出到"加密为止"**：`[downloadVia]` 里三条错误文案
//    （"解密失败（data 长度 …" / "解密结果非 JSON：" / "解密结果里没有 url："）
//    证明响应体是**密文**，而**密钥不在本类任何字面量里**
//    ⇒ 本批**不做解密**，play 走到"拿到密文"就如实报告"密钥未取证"。
//    这一条是本文件最容易被"顺手编过去"的地方：伪造一个 m3u8 只会让用户点进去 404。
// 3. 目录里的**文件大小/名字**用 DEX 逐字字段名（n/fid/cid/s/pc），
//    但**未在真账号下跑通** ⇒ 若真响应换名，`parse_entries` 会返回 0 条，
//    然后走"0 条 ⇒ Err（可能改版/风控壳页）"这条路 —— 用户拿到的是原因，不是空列表。
// 4. 原版这些"我的盘"类的**播放**其实靠它自己起的本地转发服务
//    （基类 `Pan.processPan/proxy` 里逐字 `http://127.0.0.1:5266`）。
//    本仓的等价物是 `streamproxy::register(url, headers)`；本批**未接通**（未验）。
// ```
//
// # 为什么 `supports_search() == false`（硬依据，不是省事）
//
// ```text
// 订阅里这条 `"searchable":0`；`registry.rs` 用 `capabilities.search` 决定
// 要不要把这个源拉进搜索 ⇒ 返 true 会让用户每次搜索都多打一轮**注定失败**的请求。
// ⇒ 返 false，且 `search()` 如实报"不支持"（不占位返回空）。
// ```

use std::time::Duration;

use async_trait::async_trait;

use crate::pan::PanKind;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 请求超时
///
/// ★ 为什么 10s 而不是更长：网盘接口要么快（几十毫秒），要么根本不答
/// （风控/CDN 静默丢包）。等 30s 只会让用户在界面上干等，拿不到更多信息。
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

/// 接口 UA —— **逐字**取 DEX `[headApi]`
///
/// ⚠️ 这个 UA 与 `[head]` 里那条浏览器 UA **不同**：参考实现给"接口请求"用
/// 客户端串、给"网页/分享页"用浏览器串。**串了不会报错**，只会让某一侧被判成爬虫。
/// ⇒ 本实现只走接口链路（列目录 + 取址），所以只保留客户端串；
///   `[head]` 那条浏览器 UA 属于"打开网页/分享页"的链路，**本类不实现那条链路**
///   ⇒ 不在代码里留一个没人调用的常量（那会让人以为这里也支持网页链路）。
const UA_API: &str = "Mozilla/5.0 115disk/30.1.0";

/// 无登录态时的提示 —— **逐字**取参考实现（用户可见文案属行为层，不该被我们改写）
const LOGIN_HINT: &str = "还未登录115账号,请前往【配置中心】登录";

/// 首页那个货架的名字 —— **逐字**取参考实现 `[b]`
const SHELF_NAME: &str = "我的115网盘";

/// 根目录 id
///
/// ```text
/// ★ 取证等级：**弱**。DEX 只给出 `&cid=` 是**拼接位**，值不在常量里；
///   `[b]`（首页）里出现过字面量 "0"，与同族其它类的"根 = 固定串"一致
///   （阿里那条逐字是 "root"、天翼那条逐字是 "-11"）⇒ 这里取 "0"。
/// ⚠️ 若真实根不是 "0"，list 会拿到一个空目录 ⇒ 走"0 条 ⇒ Err"，**不会静默错**。
///   （这也是为什么"空 ⇒ Err"这条纪律在本类尤其重要：它把这个弱假设的代价
///     从"用户以为盘是空的"降成"用户看到一句可读的错"。）
/// ★ 允许 ext 覆盖：`{"cid":"…"}`。别人的盘根 id 可能不同，且我们**不能**靠猜。
/// ```
const ROOT_CID: &str = "0";

/// 列目录端点（`[collect]` 第一段，逐字）
const FILES_ENDPOINT: &str = "https://webapi.115.com/files";

/// 列目录端点的固定查询串（`[collect]` 第二段，逐字）
const FILES_FIXED_QUERY: &str = "&o=file_name&asc=1&show_dir=1&natsort=1&format=json";

/// 取址端点（**唯一实现的那一条**，`[download]` 逐字）
///
/// ★ 参考实现的 `[download]` 里其实有**两条**端点（第二条是 android 通道，标签逐字
///   「｜备用端点：」）。这里**只留一条**，理由是取证结论：
/// ```text
/// ① 两条的响应体**都是密文**（`[downloadVia]` 三条解密失败文案可证）
///    ⇒ 备用端点即便接上，也一样卡在"密钥未取证"，接它换不来任何可用地址；
/// ② 备用端点在真网里我**没有**逐个验证过（只验了主通道的未登录形态）
///    ⇒ 留一条死常量会被后来人读成"已经做了故障切换"，那正是本仓最忌讳的
///      「看起来支持」。
/// ⇒ 结论：写清楚"有第二条、但本批不接"，比留一个没人调用的常量诚实。
/// ```
const DOWN_URL_ENDPOINT: &str = "https://proapi.115.com/app/chrome/downurl";

/// 播放参数分隔符 —— **逐字**取 DEX（`[b]` 的播放方法里就有这个串）
///
/// ```text
/// 参考实现把"名字 + pickcode"拼成一个参数串传进播放链路，用 "~!~" 分隔。
/// 我们沿用同一个分隔符 ⇒ 详情/播放两处的 id 语义与上游一致
/// （将来若有"从上游 id 直接播"的入口，不必再换一层编码）。
/// ```
const PLAY_SEP: &str = "~!~";

/// 网盘里的一个条目
///
/// ★ 字段名全部来自 DEX `[collect]` 的字面量：`n` / `fid` / `cid` / `s` / `pc`。
///   **不是**我按常见命名猜的（对比：夸克/UC 那边是 `fid` + `file_name`）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// 稳定 id：文件用 `fid`，目录用 `cid`（两者在响应里互斥出现）
    pub id: String,
    /// 文件名（DEX `n`）
    pub name: String,
    /// true = 目录
    pub is_dir: bool,
    /// 字节数（DEX `s`；目录通常 0）
    pub size: u64,
    /// 取址用的 pickcode（DEX `pc`；目录通常没有）
    ///
    /// ★ 这个字段是本类的**关键**：没有它，play 一步都走不了
    ///   （取址端点的参数就叫 `pickcode`）。
    pub pickcode: String,
}

/// `csp_Pan115`
pub struct Pan115 {
    client: reqwest::Client,
}

impl Pan115 {
    pub const CLASS: &'static str = "Pan115";

    pub fn new() -> Self {
        // ★ 三条构造纪律（与 `pan_drive.rs` / `pan_web_share.rs` 同一批教训）：
        //   ① `.no_proxy()` 必须在 `.timeout(…)` 之后、`.build()` 之前
        //      —— 本机系统代理会把"接口可用"测成"全失败"，且错误文本不含真因；
        //   ② 用 `.expect()` 而不是 `unwrap_or_else(|_| Client::new())`：
        //      后者在 build 失败时会**悄悄丢掉 no_proxy**（等于纪律①失效）；
        //   ③ 不在字段里缓存 cookie —— 登录态必须热生效（`pan_auth::load` 每次现读）。
        let client = reqwest::Client::builder()
            .user_agent(UA_API)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("build pan115 http client");
        Self { client }
    }

    /// 本盘的登录 cookie（没有 ⇒ `None`，由调用方如实报错）
    fn cookie() -> Option<String> {
        crate::pan_auth::load(PanKind::Pan115).map(|c| c.cookie)
    }

    /// 根目录 id（ext 可覆盖）
    pub fn root_cid(ext: &str) -> String {
        ext_json(ext)
            .and_then(|j| {
                j.get("cid")
                    .or_else(|| j.get("root"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim().to_string())
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| ROOT_CID.to_string())
    }

    /// 带 cookie 发一次 GET，返回**原文**（JSON 解析交给纯函数，便于单测）
    async fn get_text(&self, cookie: &str, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header("Cookie", cookie)
            // 逐字取 DEX `[headApi]`
            .header("Accept", "application/json;charset=UTF-8")
            .send()
            .await
            .map_err(|e| format!("115 请求失败：{e}"))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        // ★ 先判"这是不是 HTML"（实测会走到：拦截页），再判状态码。
        //   顺序不能反：拦截页的 405 与"接口真的 405"在状态码上不可区分，
        //   但 body 形态（HTML vs JSON）能区分 ⇒ 先看形态能给出更准的原因。
        ensure_json_body(&body, status.as_u16())?;
        if !status.is_success() {
            // 走到这里说明"是 JSON 但状态码不对" ⇒ 带上 code + 摘要，别只报数字
            return Err(format!(
                "115 返回 HTTP {status}：{}",
                short(&body)
            ));
        }
        Ok(body)
    }
}

#[async_trait]
impl CspSite for Pan115 {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页 = **一个货架**（没有"分类页"可抓，这点与影视站不同）
    ///
    /// ★ 无 cookie ⇒ 如实报登录，**不返回空首页**
    ///   （空首页会让用户以为"这个盘里没东西"，而事实是"你没登录"）。
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let Some(cookie) = Self::cookie() else {
            return Err(LOGIN_HINT.to_string());
        };
        if !is_logged(&cookie) {
            // ★ 有 cookie 但没有 UID= ⇒ 是个**残缺/过期**的 cookie。
            //   这里不能当"已登录"往下走：那会让 list 拿到 401，
            //   而用户看到的是接口错误而不是"请重新登录"。
            return Err(LOGIN_HINT.to_string());
        }
        let cid = Self::root_cid(ext);
        Ok(CspHome {
            categories: vec![CspCategory {
                // tid 直接用目录 id：本类的 list 拿它去 `&cid=`（不像货架族用下标）
                id: cid,
                name: SHELF_NAME.to_string(),
            }],
            // 首屏条目留给 list 去取（网盘目录可能很大，预取会拖慢启动）
            items: Vec::new(),
        })
    }

    /// 列表：`tid` = 目录 id（空 ⇒ 根）
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let Some(cookie) = Self::cookie() else {
            return Err(LOGIN_HINT.to_string());
        };
        if !is_logged(&cookie) {
            return Err(LOGIN_HINT.to_string());
        }
        let cid = if tid.trim().is_empty() {
            Self::root_cid(ext)
        } else {
            tid.trim().to_string()
        };
        let page = if page == 0 { 1 } else { page };
        let offset = (page - 1) * PAGE_LIMIT;
        let url = files_url(&cid, offset, PAGE_LIMIT);
        let body = self.get_text(&cookie, &url).await?;
        let v: serde_json::Value = parse_json(&body)?;
        let entries = parse_entries(&v)?;
        let items = entries.iter().map(item_of).collect();
        Ok(CspList {
            items,
            page,
            // 分页：DEX 里有 `count` 与 `&offset=`/`&limit=`，但**每页条数**是拼接位，
            // 未取证到参考实现用的常量 ⇒ 不编 page_count（给 None 让 UI 按"还有下一页"处理）
            page_count: None,
            total: count_of(&v),
        })
    }

    /// 详情：网盘条目没有"多集"概念 ⇒ 把单个文件包装成"1 集"
    ///
    /// # 为什么不是"直接报不支持"
    /// ```text
    /// UI 的链路是 list → detail → play；detail 报错 = 用户点了条目就断。
    /// 而条目**确实**有可播内容（一个文件）⇒ 如实包装成 1 集是行为正确。
    /// ```
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        if Self::cookie().as_deref().map(is_logged) != Some(true) {
            return Err(LOGIN_HINT.to_string());
        }
        let (name, pickcode) = split_play_param(id);
        Ok(CspDetail {
            id: id.to_string(),
            title: if name.is_empty() { id.to_string() } else { name },
            cover: None,
            description: None,
            episodes: vec![CspEpisode {
                // 集的 id = **pickcode**（取址端点的参数就叫这个名字）
                id: pickcode,
                title: "播放".to_string(),
                flag: "默认".to_string(),
            }],
        })
    }

    /// ★ 本类**不支持搜索** —— 硬依据见文件头（订阅 `searchable:0`）
    fn supports_search(&self) -> bool {
        false
    }
    /// ★ 2026-10-28（Owner：「要逐类标注」）：本类**不填 ext 不能用**
    ///
    /// 依据：未登录必然 Err（真网读数：errno=99「请重新登录」）
    /// ⇒ 默认不自动暴露（用户导入带 ext 的站点时照常出现）。
    fn needs_ext(&self) -> bool {
        true
    }


    /// 搜索：如实报"不支持"（**不许**占位返回空 —— 那会被当成"搜了但没结果"）
    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("115 不支持搜索（它只列出你自己账号里的目录）".to_string())
    }

    /// 取播放地址
    ///
    /// # 走到哪里、为什么停在这里（**如实**）
    /// ```text
    /// ① 无 cookie / cookie 无 UID= ⇒ 逐字登录提示（用户知道该去做什么）。
    /// ② id 里没有 pickcode ⇒ 逐字"播放参数为空"（对目录点播放就是这条路径）。
    /// ③ 有 pickcode ⇒ 真去打取址端点：
    ///      · `state:false` ⇒ 用 `[reason]` 梯子把上游原因带给用户；
    ///      · `state:true`  ⇒ 响应里的 data 是**密文**（`[downloadVia]` 三条解密文案可证），
    ///        而**密钥不在本类字面量里** ⇒ 报"密钥未取证"，**不猜、不伪造地址**。
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let Some(cookie) = Self::cookie() else {
            return Err(LOGIN_HINT.to_string());
        };
        if !is_logged(&cookie) {
            return Err(LOGIN_HINT.to_string());
        }
        let (_name, pickcode) = split_play_param(id);
        let pickcode = pickcode.trim();
        if pickcode.is_empty() {
            // ★ 逐字取参考实现（`[b]` 的播放方法）
            return Err("播放参数为空".to_string());
        }
        let url = format!("{DOWN_URL_ENDPOINT}?pickcode={pickcode}");
        let body = self.get_text(&cookie, &url).await?;
        let v = parse_json(&body)?;
        // `state` 是 `[collect]`/`[downloadVia]` 共用的成功位
        if v.get("state").and_then(|x| x.as_bool()) != Some(true) {
            return Err(format!("115取址失败：{}", reason_of(&v)));
        }
        // 到这一步说明"账号 + pickcode 都对，上游给了密文" ⇒ 缺的是**密钥**。
        Err(format!(
            "115取址失败：响应经加密（data 长度 {}），本实现未取证到解密密钥 ⇒ \
             不猜、不伪造地址（该链路原版靠本地转发服务 + 密钥，本批未接通）",
            v.get("data")
                .map(|d| if let Some(s) = d.as_str() { s.len() } else { d.to_string().len() })
                .unwrap_or(0)
        ))
    }
}

/// 每页条数
///
/// ★ 取证等级：**中**。DEX 只给出 `&limit=` 是拼接位；同族参考实现普遍一页 100 上下。
///   取 60 是**保守值**（列表接口常有上限，取大反而可能被风控拒）。
///   ⚠️ 这个值**不影响正确性**（影响每页条数），所以不阻塞；注释里标清楚即可。
const PAGE_LIMIT: u32 = 60;

/// 拼"列目录"的 URL（**纯函数** —— 抽出来是为了能断言 URL 逐字）
///
/// # 为什么单独抽出来
/// ```text
/// URL 拼错**不会报错**（接口照样返 200，只是结果不对）⇒ 属"静默错"。
/// 抽成纯函数后就能**断言逐字**（对照 DEX 的拼接顺序）而不必发网络。
/// ```
fn files_url(cid: &str, offset: u32, limit: u32) -> String {
    format!(
        "{FILES_ENDPOINT}?aid=1&cid={cid}{FILES_FIXED_QUERY}&offset={offset}&limit={limit}"
    )
}

/// 宽松解析 JSON（配 `crate::tvbox::parse_loose_json`，能容忍 BOM / JSONP / 行注释）
fn parse_json(body: &str) -> Result<serde_json::Value, String> {
    crate::tvbox::parse_loose_json(body)
        .map_err(|e| format!("115 返回的不是 JSON（{e}）：{}", short(body)))
}

/// 非 JSON 体的**统一前置判定**（实测会走到这条路径：CDN 拦截页是 HTML）
///
/// # 为什么这条必须在"解析"之前、且单独成函数
/// ```text
/// 真网读数（`.probe/parity-pan-a-live.log`）：
///   列目录端点在本机直连、无 cookie 时返回 **HTTP 405** + 一页 HTML 拦截页。
/// ⇒ 若不先判"这是不是 HTML"，用户会看到一句 "expected value at line 1"，
///   完全指不出"你被 CDN 拦了 / 站点改版了"。
/// ★ 返回 `Result<&str, String>` 而不是 bool：调用点没法"忘了处理"。
/// ```
fn ensure_json_body(body: &str, http: u16) -> Result<&str, String> {
    let t = body.trim_start();
    if t.starts_with('<') {
        return Err(format!(
            "115 返回的是 HTML（HTTP {http}），不是 JSON —— 多半是 CDN/WAF 拦截页或改版壳页：{}",
            short(body)
        ));
    }
    if t.is_empty() {
        return Err(format!("115 返回空响应体（HTTP {http}）"));
    }
    Ok(body)
}

/// 登录判据 —— **逐字**取 DEX `[logged]`：cookie 里有没有 `UID=`
///
/// # 为什么不能只看"有没有 cookie"
/// ```text
/// 用户可能存了一条**过期**的 cookie（或者只存了 `CID=`/`SEID=` 那半截）。
/// 只看"非空" ⇒ 一路往下打到接口 ⇒ 用户看到的是接口的 401 文案，
/// 而不是"请重新登录"这句**能指导行动**的话。
/// ```
fn is_logged(cookie: &str) -> bool {
    cookie.contains("UID=")
}

/// 从响应里取"错因" —— 梯子**逐字**取 DEX `[reason]`：msg → error → msg_code → errno
///
/// ★ 末尾带 `(errno)` 的形状也是逐字的：DEX 里 `[reason]` 同时引用了 `"("` 和 `")"`。
///   实测样本：`{"state":false,"error":"请重新登录","errno":99}`
///   ⇒ 本函数返回 `请重新登录(99)`（数字对排障很关键：不同 errno 对应不同处置）。
fn reason_of(v: &serde_json::Value) -> String {
    let pick = |k: &str| -> Option<String> {
        let x = v.get(k)?;
        let s = match x {
            serde_json::Value::String(s) => s.trim().to_string(),
            serde_json::Value::Number(n) => n.to_string(),
            serde_json::Value::Bool(b) => b.to_string(),
            _ => return None,
        };
        if s.is_empty() {
            None
        } else {
            Some(s)
        }
    };
    let msg = pick("msg")
        .or_else(|| pick("error"))
        .or_else(|| pick("msg_code"))
        .or_else(|| pick("errno"))
        .unwrap_or_else(|| "未知错误".to_string());
    match pick("errno") {
        // 已经就是 errno 本身 ⇒ 别写成 "99(99)"
        Some(code) if code != msg => format!("{msg}({code})"),
        _ => msg,
    }
}

/// 从响应里抽条目（**纯函数**）
///
/// # ★ 0 条 ⇒ `Err`（这是本仓的硬约束，不是风格）
/// ```text
/// 站点 200 但模板改版/风控壳页时，"解析出 0 条"和"盘里真的空"在**数据上不可区分**。
/// 若这里返回 `Ok(vec![])`：上层原样透传 ⇒ 用户看到"这个源没内容" ⇒
///   他会去怀疑源，而真正的原因是**我们没解析到**。
/// ⇒ 空就报错，并写明"可能改版/风控壳页"，把判断权交回用户。
/// ```
fn parse_entries(v: &serde_json::Value) -> Result<Vec<Entry>, String> {
    if v.get("state").and_then(|x| x.as_bool()) == Some(false) {
        return Err(format!("115 列目录失败：{}", reason_of(v)));
    }
    // `data` 在实测样本里既可能是数组（正常），也可能是 `[]`（未登录时的空数组）；
    // 另一个来源可能把它包成 `{"list":[…]}` ⇒ 两种都认，别只认一种。
    let arr = v.get("data").and_then(|d| {
        d.as_array()
            .cloned()
            .or_else(|| d.get("list").and_then(|l| l.as_array()).cloned())
    });
    let Some(arr) = arr else {
        return Err(format!(
            "115 列目录响应里没有 data 数组（可能改版/风控壳页）：{}",
            short(&v.to_string())
        ));
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in &arr {
        let fid = str_of(it, &["fid"]);
        let cid = str_of(it, &["cid"]);
        let (id, is_dir) = if !fid.is_empty() {
            (fid, false)
        } else if !cid.is_empty() {
            // ★ 目录只有 `cid`、文件只有 `fid`（这是 115 的响应形状，
            //   DEX `[collect]` 同时引用这两个键可证）
            (cid, true)
        } else {
            // 两个 id 都没有 ⇒ 这行没法用（拿它去详情/取址只会失败）⇒ 丢掉而不是编一个
            continue;
        };
        out.push(Entry {
            id,
            name: str_of(it, &["n", "file_name"]),
            is_dir,
            size: u64_of(it, &["s", "size"]),
            pickcode: str_of(it, &["pc", "pickcode"]),
        });
    }
    if out.is_empty() {
        return Err(format!(
            "115 列目录解析出 0 条（可能改版/风控壳页，也可能是空目录）：{}",
            short(&v.to_string())
        ));
    }
    Ok(out)
}

/// 把条目变成 UI 的一行
///
/// ★ 文件的 id 用 `名字~!~pickcode`：这是**上游自己的播放参数形状**
///   （DEX 播放方法里逐字有 `~!~` 与 `\npickcode=`）⇒ 详情/播放两处不必再编一套编码。
/// ★ 目录的 id 就是 `cid`：UI 拿它当 tid 继续 drill-down。
fn item_of(e: &Entry) -> CspItem {
    let (id, subtitle) = if e.is_dir {
        (e.id.clone(), "目录".to_string())
    } else if e.pickcode.is_empty() {
        // 没有 pickcode 的文件（少见：可能是特殊文件）⇒ id 只放名字，
        // 播放时会得到"播放参数为空"这句可读错，而不是一个错地址
        (e.name.clone(), human_size(e.size))
    } else {
        (
            format!("{}{PLAY_SEP}{}", e.name, e.pickcode),
            human_size(e.size),
        )
    };
    CspItem {
        id,
        title: e.name.clone(),
        cover: None,
        subtitle: Some(subtitle),
    }
}

/// 拆播放参数：`名字~!~pickcode`（**纯函数**）
///
/// ★ 分隔符缺失时**不报错**：把整串当名字、pickcode 留空 ——
///   由 `play` 去报"播放参数为空"。理由：详情用得到名字那半截，
///   若这里就直接 Err，用户连"这一条叫什么"都看不到。
/// ★ 为什么从**右侧**切：pickcode 是最后一个字段，而**文件名里可能出现分隔符**。
///   用 `rsplit_once` ⇒ 名字里带 `~!~` 也不会串位（用 `split_once` 会把 pickcode 切坏，
///   等于拿一个错值去打取址接口 —— 那种错**不会报错**，只会"取不到址"，难查）。
fn split_play_param(id: &str) -> (String, String) {
    match id.rsplit_once(PLAY_SEP) {
        Some((name, pc)) => (name.trim().to_string(), pc.trim().to_string()),
        None => (id.trim().to_string(), String::new()),
    }
}

/// 取 `count`（用户可见的"共 N 个"）
fn count_of(v: &serde_json::Value) -> Option<u64> {
    v.get("count").and_then(|x| match x {
        serde_json::Value::Number(n) => n.as_u64(),
        serde_json::Value::String(s) => s.trim().parse::<u64>().ok(),
        _ => None,
    })
}

/// 多键取字符串（响应字段名在不同时期可能换 casing / 换名）
fn str_of(v: &serde_json::Value, keys: &[&str]) -> String {
    for k in keys {
        if let Some(x) = v.get(*k) {
            if let Some(s) = x.as_str() {
                let s = s.trim();
                if !s.is_empty() {
                    return s.to_string();
                }
            }
            if let Some(n) = x.as_u64() {
                return n.to_string();
            }
        }
    }
    String::new()
}

/// 多键取 u64（数字可能是字符串，实测这类接口常见）
fn u64_of(v: &serde_json::Value, keys: &[&str]) -> u64 {
    for k in keys {
        if let Some(x) = v.get(*k) {
            match x {
                serde_json::Value::Number(n) => {
                    if let Some(u) = n.as_u64() {
                        return u;
                    }
                }
                serde_json::Value::String(s) => {
                    if let Ok(u) = s.trim().parse::<u64>() {
                        return u;
                    }
                }
                _ => {}
            }
        }
    }
    0
}

/// 人读的文件大小
fn human_size(b: u64) -> String {
    const U: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = b as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{b} B")
    } else {
        format!("{v:.1} {}", U[i])
    }
}

/// 摘要（报错时给用户看，别甩整页 HTML）
fn short(s: &str) -> String {
    let t = s.trim();
    let max = 180;
    let cut = t.char_indices().nth(max).map(|(i, _)| i).unwrap_or(t.len());
    if cut == t.len() {
        return t.to_string();
    }
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

/// 宽松读 ext（对象或字符串都认；坏数据 ⇒ `None`，不 panic）
fn ext_json(ext: &str) -> Option<serde_json::Value> {
    if ext.trim().is_empty() {
        return None;
    }
    crate::tvbox::parse_loose_json(ext).ok()
}

crate::csp::register_site!(Pan115);

#[cfg(test)]
mod tests {
    use super::*;

    // ── 夹具①：**真实响应片段**（未登录，直连实测，逐字）
    //
    // `.probe/parity-pan-a-live.log`：
    //   curl --noproxy '*' 'https://proapi.xxx.com/app/chrome/downurl?pickcode='
    //   ⇒ {"state":false,"error":"请重新登录","errno":99,…}
    const LIVE_UNAUTH: &str = r#"{"state":false,"error":"\u8bf7\u91cd\u65b0\u767b\u5f55","errno":99,"request":"\/app\/chrome\/downurl?pickcode=","data":[]}"#;

    // ── 夹具②：**真实响应片段**（列表端点被 CDN 以 HTML 拦截，实测 HTTP 405）
    const LIVE_WAF_HTML: &str = r#"<!doctypehtml><html lang="zh-cn"><meta charset="utf-8"><title>405</title></html>"#;

    // ── 夹具③：**不是真网响应** —— 按 DEX `[collect]` 的字段名还原的成功形态
    //   （无账号取不到真 200 体；这里只用来验"字段名读对了吗"，文件头已声明）
    const DEX_SHAPE_OK: &str = r#"{"state":true,"count":3,"offset":0,"limit":60,"data":[
        {"fid":"3412345678901234567","n":"第一集.mp4","s":"734003200","pc":"abcdefghijklmnop"},
        {"cid":"3412345678901234999","n":"剧集目录","s":0,"pc":""},
        {"n":"没有 id 的行"}
    ]}"#;

    #[test]
    fn class_name_is_exact() {
        // ★ 注册键与类名必须逐字（`csp_Pan115` ⇒ "Pan115"）；大小写错 = 假装实现了
        assert_eq!(Pan115::CLASS, "Pan115");
    }

    #[test]
    fn registration_is_present() {
        // ★ 注册项在：不是"文件里有 register_site! 这行"，而是**注册表里真查得到**
        assert!(
            crate::csp::is_implemented("csp_Pan115"),
            "★ csp_Pan115 必须在注册表里（本类有 host 常量 + 订阅有站 ⇒ 够格注册）"
        );
        let s = crate::csp::route("csp_Pan115").expect("必须能路由出实例");
        assert_eq!(s.class(), "Pan115");
        assert!(!s.supports_search(), "订阅 searchable:0 ⇒ 必须 false");
    }

    #[test]
    fn login_hint_matches_reference_wording() {
        // ★ 用户可见文案属行为层，与参考实现逐字一致（用户看到的话不该被我们改写）
        assert_eq!(LOGIN_HINT, "还未登录115账号,请前往【配置中心】登录");
        assert_eq!(SHELF_NAME, "我的115网盘");
    }

    /// ★★ URL 逐字门禁：对照 DEX `[collect]` 的**拼接顺序**（不是"能构造出来"）
    ///
    /// 注入验证：把 `&offset=` 与 `&limit=` 调换顺序、或把 `cid` 挪到 `format` 尾部 ⇒ 红。
    #[test]
    fn files_url_matches_reference_byte_for_byte() {
        let u = files_url("0", 0, 60);
        assert_eq!(
            u,
            "https://webapi.115.com/files?aid=1&cid=0\
             &o=file_name&asc=1&show_dir=1&natsort=1&format=json&offset=0&limit=60"
        );
        // 反空真：换个 cid/offset 必须**真的**跟着变（否则上面的断言只证明常量没被改）
        let u2 = files_url("3412", 120, 60);
        assert!(u2.contains("cid=3412"), "★ cid 必须生效：{u2}");
        assert!(u2.contains("offset=120"), "★ offset 必须生效：{u2}");
        assert!(u2.ends_with("limit=60"), "★ limit 在最后（照 DEX 顺序）：{u2}");
    }

    #[test]
    fn root_cid_defaults_and_can_be_overridden_by_ext() {
        assert_eq!(Pan115::root_cid(""), "0");
        assert_eq!(Pan115::root_cid("{}"), "0");
        assert_eq!(Pan115::root_cid(r#"{"cid":"987654"}"#), "987654");
        assert_eq!(Pan115::root_cid(r#"{"root":" 42 "}"#), "42");
        // 坏 ext 不许 panic，也不许把怪值当目录
        assert_eq!(Pan115::root_cid("not-json"), "0");
        assert_eq!(Pan115::root_cid(r#"{"cid":"  "}"#), "0");
    }

    /// ★★★ 真实响应片段（未登录）⇒ 可读 Err，且**带上游原话 + errno**
    ///
    /// 注入验证：把 `reason_of` 里 `error` 这个键去掉（只留 msg）⇒ 本条红 ——
    /// 用户就只能看到"未知错误"，排障方向全丢。
    #[test]
    fn live_unauth_fragment_says_relogin_with_errno() {
        let v = parse_json(LIVE_UNAUTH).expect("真样本必须是合法 JSON");
        let e = parse_entries(&v).expect_err("★ state:false 必须 Err");
        assert!(e.contains("请重新登录"), "★ 必须带上游原话：{e}");
        assert!(e.contains("99"), "★ 必须带 errno（不同 errno 处置不同）：{e}");
    }

    /// ★★ 0 条 ⇒ Err（不是 Ok(空)）—— 本仓硬约束
    ///
    /// 注入验证：把这条 `Err` 改成 `Ok(vec![])` ⇒ 本条立刻红（**真红**，见注入日志）。
    #[test]
    fn empty_list_is_error_not_empty_ok() {
        let v = parse_json(r#"{"state":true,"data":[],"count":0}"#).unwrap();
        let e = parse_entries(&v).expect_err("★ 解析 0 条必须 Err，不许 Ok(vec![])");
        assert!(
            e.contains("改版") || e.contains("风控"),
            "★ 文案必须点出「可能改版/风控壳页」（把判断权交回用户）：{e}"
        );
    }

    /// ★★ 真网会发生的路径：列表端点被 CDN 拦成 HTML（实测 405）
    ///
    /// 注入验证：删掉 `ensure_json_body` 里的 `starts_with('<')` 判定 ⇒ 本条红
    /// （用户会看到 `expected value at line 1` 这种指不出原因的错）。
    #[test]
    fn html_intercept_page_is_reported_as_intercept_not_parse_error() {
        let e = ensure_json_body(LIVE_WAF_HTML, 405).expect_err("★ HTML 必须 Err");
        assert!(e.contains("HTML"), "{e}");
        assert!(e.contains("405"), "★ 要带上状态码（405 是拦截页的特征）：{e}");
        assert!(
            e.contains("拦截") || e.contains("改版"),
            "★ 要指明可能是拦截/改版，而不是干巴巴的解析失败：{e}"
        );
        // 空体也必须有话说
        let e2 = ensure_json_body("   ", 200).expect_err("空体必须 Err");
        assert!(e2.contains("空"), "{e2}");
        // 正常 JSON 要放行（反空真：否则上面两条只证明"永远报错"）
        assert!(ensure_json_body(r#"{"state":true}"#, 200).is_ok());
    }

    /// ★★ DEX 字段名门禁：`n/fid/cid/s/pc` 读对，且**目录靠 cid、文件靠 fid**
    #[test]
    fn parse_entries_reads_dex_field_names() {
        let v = parse_json(DEX_SHAPE_OK).unwrap();
        let e = parse_entries(&v).unwrap();
        assert_eq!(e.len(), 2, "★ 没有 id 的行必须丢掉（编一个 id 只会让详情失败）");

        assert_eq!(e[0].id, "3412345678901234567");
        assert_eq!(e[0].name, "第一集.mp4");
        assert!(!e[0].is_dir, "★ 有 fid ⇒ 是文件");
        assert_eq!(e[0].size, 734003200, "★ 大小是字符串也要能读（s 字段）");
        assert_eq!(e[0].pickcode, "abcdefghijklmnop", "★ 没有 pc 就播不了");

        assert_eq!(e[1].id, "3412345678901234999");
        assert!(e[1].is_dir, "★ 只有 cid、没有 fid ⇒ 是目录");
        assert_eq!(e[1].size, 0);
        assert!(e[1].pickcode.is_empty());
    }

    /// ★★ 播放参数形状：`名字~!~pickcode`（分隔符逐字取 DEX）
    #[test]
    fn play_param_split_and_item_shape() {
        let e = Entry {
            id: "f".into(),
            name: "第 3 集.mp4".into(),
            is_dir: false,
            size: 2048,
            pickcode: "PC123".into(),
        };
        let it = item_of(&e);
        assert_eq!(it.id, "第 3 集.mp4~!~PC123", "★ 文件 id 必须带 pickcode");
        assert_eq!(it.title, "第 3 集.mp4");
        assert_eq!(it.subtitle.as_deref(), Some("2.0 KB"));

        // 目录：id = cid（UI 拿它当 tid 继续钻），副标题明写"目录"
        let d = Entry {
            id: "999".into(),
            name: "目录".into(),
            is_dir: true,
            size: 0,
            pickcode: String::new(),
        };
        let dit = item_of(&d);
        assert_eq!(dit.id, "999");
        assert_eq!(dit.subtitle.as_deref(), Some("目录"));

        let (n, pc) = split_play_param("第 3 集.mp4~!~PC123");
        assert_eq!((n.as_str(), pc.as_str()), ("第 3 集.mp4", "PC123"));
        // 没有分隔符 ⇒ 整串当名字、pickcode 空（由 play 报"播放参数为空"）
        let (n2, pc2) = split_play_param("光名字");
        assert_eq!((n2.as_str(), pc2.as_str()), ("光名字", ""));
        // ★ 名字里**含分隔符** ⇒ 从右侧切，pickcode 仍对（用 split_once 会切坏）
        let (n3, pc3) = split_play_param("怪~!~名字~!~PC9");
        assert_eq!((n3.as_str(), pc3.as_str()), ("怪~!~名字", "PC9"));
    }

    #[test]
    fn is_logged_uses_uid_marker() {
        // ★ 逐字取 DEX `[logged]`：只有 UID= 才算登录
        assert!(is_logged("UID=12345_A1_1600000000; CID=abc; SEID=xyz"));
        assert!(!is_logged("CID=abc; SEID=xyz"));
        assert!(!is_logged(""));
        // ★ 残缺 cookie 不能当"已登录"往下走（否则用户看到的是接口 401 而不是"请重新登录"）
        assert!(!is_logged("seid=UID"));
    }

    #[test]
    fn human_size_is_readable_and_never_panics() {
        assert_eq!(human_size(0), "0 B");
        assert_eq!(human_size(512), "512 B");
        assert_eq!(human_size(1024), "1.0 KB");
        assert_eq!(human_size(1024 * 1024 * 3 / 2), "1.5 MB");
    }

    /// ★★★ 无 cookie 时：home/list/detail/play **都必须如实报登录**，不许返回空
    ///
    /// 注入验证：把 `home` 里那句 `return Err(LOGIN_HINT…)` 改成 `Ok(CspHome::default())`
    ///   ⇒ 本条红（用户会看到"这个盘是空的"，而事实是"你没登录"）。
    #[tokio::test]
    async fn without_cookie_every_path_says_login_not_empty() {
        // ⚠️ 若本机钥匙串**恰好有**115 凭据（开发者真登录过），本用例会失真 ⇒
        //   先探一下，有就如实跳过（不静默假绿）。
        if crate::pan_auth::load(PanKind::Pan115).is_some() {
            eprintln!("本机钥匙串已有 115 凭据 ⇒ 跳过『无 cookie』用例（避免假绿/假红）");
            return;
        }
        let s = Pan115::new();
        let e = s.home("").await.expect_err("★ 无 cookie 必须 Err");
        assert_eq!(e, LOGIN_HINT, "★ home 必须逐字用参考实现的登录提示");

        let e = s.list("0", 1, "").await.expect_err("★ 无 cookie 必须 Err");
        assert_eq!(e, LOGIN_HINT);

        let e = s.detail("x", "").await.expect_err("★ 无 cookie 必须 Err");
        assert_eq!(e, LOGIN_HINT);

        let e = s
            .play("默认", "名字~!~PC", "")
            .await
            .expect_err("★ 无 cookie 必须 Err（不许把分享页当视频流）");
        assert_eq!(e, LOGIN_HINT);
    }

    #[tokio::test]
    async fn empty_id_detail_is_error() {
        let s = Pan115::new();
        // 注意：这里**故意**先撞 id 空检查（它在登录闸之前），
        // 所以本判据与凭据无关 —— 有账号的机器上也成立。
        let e = s.detail("   ", "").await.expect_err("空 id 必须 Err");
        assert!(e.contains("为空"), "{e}");
    }

    #[tokio::test]
    async fn search_says_unsupported_not_empty_result() {
        let s = Pan115::new();
        let e = s.search("任意词", 1, "").await.expect_err("★ 必须 Err，不许 Ok(空)");
        assert!(e.contains("不支持搜索"), "{e}");
    }

    /// ★ 结构性判据：`.no_proxy()` 必须在 `.timeout(…)` 之后、`.build()` 之前
    ///
    /// 这条为什么值得一条独立判据：`no_proxy` 写漏**不会**编译错，
    /// 只会在"用户开了系统代理"的机器上把全部接口判成失败（且错误文本不含真因）。
    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("pan115.rs"));
        let t = flat.find(".timeout(HTTP_TIMEOUT)").expect("必须有 .timeout");
        let n = flat.find(".no_proxy()").expect("★ 必须 .no_proxy()");
        let b = flat.find(".build()").expect("必须有 .build()");
        assert!(t < n && n < b, "★ 位置必须是 timeout → no_proxy → build");
        // ★ 反空真：这条判据不能靠"随便找个子串"成立 —— 必须真在 client builder 链上
        assert!(
            flat.contains("Client::builder().user_agent(UA_API).timeout(HTTP_TIMEOUT).no_proxy().build()"),
            "★ 必须是同一条 builder 链"
        );
    }

    /// ★ 用户可见文案里**不许**出现 markdown 粗体标记（全仓没有 markdown 渲染器）
    ///
    /// 门禁 `zz_t66_rust_markdown_gate` 会扫普通字面量；这里再做一次本地钉死，
    /// 让错误在本文件就暴露（而不是等全仓门禁）。
    #[test]
    fn user_visible_text_has_no_markdown_emphasis() {
        for s in [LOGIN_HINT, SHELF_NAME] {
            assert!(!s.contains("**"), "★ 用户可见文案不许有 **：{s}");
        }
        // 本文件里所有拼给用户看的文案，都经过这两个常量或下面的函数 ⇒ 再扫一遍函数产物
        let e = parse_entries(&parse_json(r#"{"state":true,"data":[]}"#).unwrap())
            .expect_err("空必须 Err");
        assert!(!e.contains("**"), "★ 错误文案不许有 **：{e}");
    }
}
