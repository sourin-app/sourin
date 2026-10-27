// ═══════════════════════════════════════════════════════════════════════
//  csp_TingBokan —— TVBox `csp_TingBokan` 的 Rust 重写（纯 HTTP-JSON）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅 8815.kstore.vip/tvbox/wmz 的 📕博看丨听书资源：
//   {"type":3, "api":"csp_TingBokan", "ext": null}
// ⇒ ext 为 null ⇒ base 写死（本类只有一个域族）。
// ```
//
// # 协议取证（`.probe/decompiled/classes.dex` 直读，**未起 jadx**）
//
// 依据：`.probe/r3-c-strings.json` 里 `TingBokan` 的 86 条 const-string。
//
// ```text
// 类       Lcom/github/catvod/spider/TingBokan;  父类 crawler/Spider
// 成员     8 方法（7 个 override API + <init>+<clinit>）
// ★ 分类   常量里 **18 组分类名与 id 成对给出**（不是猜的、不是从导航抓的）
//          故事会=1303 儿童文学=1304 少年读物=1305 文艺少年=1306 青春励志=1307
//          个人提升=1308 育儿心经=1309 心理哲学=1310 家庭健康=1311 历史小说=1312
//          科技科普=1313 经典必读=1314 商业财经=1315 红色岁月=1316 音乐戏剧=1317
//          社会观察=1318 相声评书=1319 国学经典=1320   ← 1303..1320 闭区间 = **18 组**
// 列表     https://api.bookan.com.cn/voice/book/list?instance_id=25304&page=<n>
//            &category_id=<id>&num=24
//          字段 code / data.list；项内 extra.author / id / name / cover / last_page
// 搜索     https://es.bookan.com.cn/api/v3/voice/book?instanceId=25304&keyword=<kw>
//            （常量里成对出现 "UTF-8" 与 &pageNum=1&limitNum=20）
//          字段 code / data.list；项内 id / name / cover / extra.author / press
// 详情     https://api.bookan.com.cn/voice/album/units?album_id=<id>&page=<n>
//            &num=200&order=1
//          字段 code / data.last_page / data.list
//          项内 title（含集号）· file（**直链音频**）· updated_at
//          常量拼装："更新于 " + updated_at ⇒ 进 vod_remarks
// 播放     vod_play_from = "博看听书"；vod_play_url 用 `#` 分集、`$` 分名址
// 取流模板 {"parse":0,"url":"…","header":{}}   ← ★ **parse:0 直链**，与 SportsKafei 同款
// ```
//
// # ★★ 一个必须说清的坑：本站业务码是 **0**，不是 200
//
// ```text
// DEX 常量里只有 `code` 这个键名，没有给"什么值算成功"。
// 【实测】两个接口 HTTP 200 且 `code: 0` —— 0 才是成功。
// ⇒ 若照本仓其它类的经验写"code==200 才算成功"，本站**每次都会被判失败**。
//   （这是"按行为重写"与"照抄模板"的分水岭；本条读数见
//    `.probe/r3-g-tier1-evidence.log`）
// ```
//
// # 真网络读数（2026-10-27 实测）
//
// ```text
// GET /voice/book/list?instance_id=25304&page=1&category_id=1303&num=24
//       HTTP 200 · len=7980 · code=0 · data.list=24 条 · last_page=22
//       item0 = {"cover":"http://img-qn.bookan.com.cn/…/defaultcover.png",
//                "name":"葵花向太阳","id":4033132,"extra":{"grade":10,…}}
// GET /voice/album/units?album_id=4033132&page=1&num=200&order=1
//       HTTP 200 · len=21239 · code=0 · data.list=60 条 · last_page=1
//       unit0 = {"id":7762053,"title":"01.《葵花向太阳》 引子 心中的桥",
//                "file":"http://audio.bookan.com.cn/video1/audio/2022120101/aache64_cf3c3a52.m4a",
//                "duration":126,"updated_at":"2022-12-01 05:30:03"}
// GET es.bookan.com.cn/api/v3/voice/book?instanceId=25304&keyword=红&pageNum=1&limitNum=20
//       HTTP 200 · len=7678 · code=0 · data.list=20 条
// ★ 详情里的 `file` 就是**可直接播的音频直链**（.m4a）⇒ play() 真能给出可播地址。
// ```
//
// # 契约边界（Lead 已裁定）
//
// ```text
// · loadPic   ⇒ 封面是公开图床（img-qn.bookan.com.cn / epub.bookan.com.cn），不需额外头
//                ⇒ 不写 cover_headers
// · mProxy    ⇒ ★ **已知缺口**：部分音频 CDN 可能校验 Referer；原版有代理能力。
//                本批不做，如实登记（不代理时能直连的照常返回）。
// · initApi   ⇒ 本仓无该 API；等价物是 `ext`（本类 ext 为 null，不影响）
// · isVideoFormat / manualVideoCheck
//             ⇒ ★ DEX 里 TingBokan **没有** override 这两个（8 个方法里没有）
//                ⇒ **本仓无等价位，未实现**（如实登记，不臆造）
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 列表/详情域（DEX 常量逐字：`api.bookan.com.cn`）
const BASE_API: &str = "https://api.bookan.com.cn";
/// 搜索域（DEX 常量逐字：`es.bookan.com.cn`）—— **与列表域不同**，别合并
const BASE_SEARCH: &str = "https://es.bookan.com.cn";
/// 实例 id：DEX 常量在**两个**接口里都写死了 `25304`
const INSTANCE_ID: &str = "25304";

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 列表每页条数（DEX 模板 `&num=24`）
const LIST_PAGE_SIZE: u32 = 24;
/// 详情每页集数（DEX 模板 `&num=200`）
const UNITS_PAGE_SIZE: u32 = 200;
/// 搜索每页条数（DEX 模板 `&limitNum=20`）
const SEARCH_PAGE_SIZE: u32 = 20;

const GET_TIMEOUT: Duration = Duration::from_secs(15);

pub struct TingBokan {
    client: reqwest::Client,
}

impl TingBokan {
    pub const CLASS: &'static str = "TingBokan";

    /// 首页分类 —— **18 组逐对来自 DEX 常量**
    ///
    /// # 为什么这类"分类表"是可信的
    /// ```text
    /// 常量池里 18 个中文分类名与 18 个四位数字 id **紧邻成对出现**（1303…1320 连续），
    /// ⚠️ 我第一版写成"17 组"（数错闭区间长度），门禁当场红了 ⇒ 已改 18。
    /// ⇒ 不是从页面导航抓的、不是猜的。对照：本仓 zhinan.rs 的分类是从站点导航抓的
    ///   （标注"实测"，因为 DEX 里没有）。本类**有 DEX 依据**，故可信度更高。
    /// ```
    pub const CATEGORIES: &'static [(&'static str, &'static str)] = &[
        ("1303", "故事会"),
        ("1304", "儿童文学"),
        ("1305", "少年读物"),
        ("1306", "文艺少年"),
        ("1307", "青春励志"),
        ("1308", "个人提升"),
        ("1309", "育儿心经"),
        ("1310", "心理哲学"),
        ("1311", "家庭健康"),
        ("1312", "历史小说"),
        ("1313", "科技科普"),
        ("1314", "经典必读"),
        ("1315", "商业财经"),
        ("1316", "红色岁月"),
        ("1317", "音乐戏剧"),
        ("1318", "社会观察"),
        ("1319", "相声评书"),
        ("1320", "国学经典"),
    ];

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(GET_TIMEOUT)
            // 与本仓 csp 既定惯例一致 —— **不读系统代理**
            // ```text
            // 代理会把"站点可用"测成"全宕"（见 `app99.rs:342` 同一条纪律）。
            // ★ 实测依据（Lead 跨批一致性审计发现，我复现并扩面 7/8 类）：
            //   本机装了代理时 `reqwest` 会**默认读系统代理**；把代理指向死端口 `:9`
            //   ⇒ 本类 live FAILED（含糊的 `error sending request for url …`）；
            //   而同条件下**有** `.no_proxy()` 的类（app99 / app_drama）**仍 ok**。
            // ```
            .no_proxy()
            .build()
            .expect("build TingBokan http client");
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
                "{url} 返回 HTTP {status}；响应前 200 字节：{}",
                truncate(&body, 200)
            ));
        }
        serde_json::from_str(&body)
            .map_err(|e| format!("{url} 不是合法 JSON：{e}；响应前 200 字节：{}", truncate(&body, 200)))
    }

    async fn fetch_list(
        &self,
        category_id: &str,
        page: u32,
    ) -> Result<serde_json::Value, String> {
        let page = if page == 0 { 1 } else { page };
        let url = format!(
            "{BASE_API}/voice/book/list?instance_id={INSTANCE_ID}&page={page}\
             &category_id={category_id}&num={LIST_PAGE_SIZE}"
        );
        let v = self.get_json(&url).await?;
        check_code(&v, &url)?;
        Ok(v)
    }

    async fn fetch_units(&self, album_id: &str, page: u32) -> Result<serde_json::Value, String> {
        let page = if page == 0 { 1 } else { page };
        let url = format!(
            "{BASE_API}/voice/album/units?album_id={album_id}&page={page}\
             &num={UNITS_PAGE_SIZE}&order=1"
        );
        let v = self.get_json(&url).await?;
        check_code(&v, &url)?;
        Ok(v)
    }

    async fn fetch_search(&self, kw: &str, page: u32) -> Result<serde_json::Value, String> {
        let page = if page == 0 { 1 } else { page };
        // 关键字要 URL 编码（DEX 常量里紧跟 "UTF-8"，即按 UTF-8 做百分号编码）
        let url = format!(
            "{BASE_SEARCH}/api/v3/voice/book?instanceId={INSTANCE_ID}&keyword={}&pageNum={page}\
             &limitNum={SEARCH_PAGE_SIZE}",
            urlencode(kw)
        );
        let v = self.get_json(&url).await?;
        check_code(&v, &url)?;
        Ok(v)
    }
}

impl Default for TingBokan {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数（hermetic 可测；网络部分只负责取回 JSON）
// ═══════════════════════════════════════════════════════════════════════

fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// 最小百分号编码（只编码"绝不能在 URL 里裸出现"的字节）
///
/// # 为什么不引 percent-encoding crate
/// ```text
/// 本仓"不新增运行时依赖"是硬约束 ⇒ 这里只覆盖 keyword 这一个用途：
///   保留 unreserved（字母数字 + `-_.~`），其余按 UTF-8 逐字节 %XX。
/// 不做表单语义（空格用 %20 而不是 +）—— 上游 keyword 是路径无关的查询参数，实测可用。
/// ```
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

/// 上游信封：**成功码是 0**（见文件头的坑）
///
/// # 为什么把"成功码"做成显式常量而不是散落的 `== 0`
/// ```text
/// 将来如果发现别的接口成功码不同，改这一处即可；
/// 也让"这里为什么是 0 不是 200"这件事**在代码里看得见**（有注释指向实测读数）。
/// ```
const OK_CODE: i64 = 0;

fn check_code(v: &serde_json::Value, url: &str) -> Result<(), String> {
    match v.get("code").and_then(|c| c.as_i64()) {
        Some(OK_CODE) => Ok(()),
        Some(other) => Err(format!(
            "{url} 业务码非 {OK_CODE}：code={other}, msg={}",
            v.get("msg").and_then(|m| m.as_str()).unwrap_or("(无)")
        )),
        None => Err(format!("{url} 响应缺少 code 字段：{}", truncate(&v.to_string(), 200))),
    }
}

/// 列表/搜索响应 → `CspList`（两者 `data.list[]` 结构一致，共用）
///
/// 字段映射逐条来自 DEX 常量：
/// ```text
/// id   ← id        （数字，收成字符串）
/// 标题  ← name
/// 封面  ← cover
/// 副标题 ← extra.author  （作者；DEX 的 `@` 拼装就是 `name@author` 形态的启发）
/// ```
pub fn parse_list(v: &serde_json::Value, page: u32) -> Result<CspList, String> {
    let data = v
        .get("data")
        .ok_or_else(|| format!("响应没有 data：{}", truncate(&v.to_string(), 200)))?;
    let list = data
        .get("list")
        .and_then(|l| l.as_array())
        .ok_or_else(|| format!("data 里没有 list 数组：{}", truncate(&data.to_string(), 200)))?;

    let mut items = Vec::with_capacity(list.len());
    for row in list {
        let Some(id) = as_string(row.get("id")) else {
            continue; // 没有 id 进不了详情 ⇒ 丢掉而不是塞假 id
        };
        if id.is_empty() {
            continue;
        }
        let title = as_string(row.get("name"))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| format!("条目 {id}"));
        let author = row
            .pointer("/extra/author")
            .and_then(|a| as_string(Some(a)))
            .filter(|s| !s.is_empty());
        items.push(CspItem {
            id,
            title,
            cover: as_string(row.get("cover")).filter(|s| !s.is_empty()),
            subtitle: author,
        });
    }

    // ★ 反空真（铁律 149）：list 非空却一条都映射不出 ⇒ 结构变了（我们的问题）
    if items.is_empty() && !list.is_empty() {
        return Err(format!(
            "list 有 {} 条但都取不到 id ⇒ 上游字段结构可能变了：{}",
            list.len(),
            truncate(&list[0].to_string(), 200)
        ));
    }

    Ok(CspList {
        items,
        page,
        page_count: data
            .get("last_page")
            .and_then(|p| p.as_u64())
            .map(|p| p as u32),
        total: data.get("total").and_then(|t| t.as_u64()),
    })
}

/// 详情（album units）响应 → `CspDetail`
///
/// 每条 unit = 一集；`title` 已含集号（实测 `01.《葵花向太阳》 引子 心中的桥`）。
/// `file` 是**直链音频**（.m4a）⇒ 直接当 `CspEpisode.id`，play() 原样返回。
pub fn parse_detail(v: &serde_json::Value) -> Result<CspDetail, String> {
    let data = v
        .get("data")
        .ok_or_else(|| format!("详情响应没有 data：{}", truncate(&v.to_string(), 200)))?;
    let list = data
        .get("list")
        .and_then(|l| l.as_array())
        .ok_or_else(|| format!("详情 data 里没有 list：{}", truncate(&data.to_string(), 200)))?;

    let mut episodes = Vec::new();
    let mut title_hint: Option<String> = None;
    let mut updated: Option<String> = None;

    for (i, row) in list.iter().enumerate() {
        let Some(file) = as_string(row.get("file")).filter(|s| !s.is_empty()) else {
            continue; // 没有 file 就播不了 ⇒ 不列假集
        };
        let t = as_string(row.get("title"))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| format!("第 {} 集", i + 1));
        if title_hint.is_none() {
            // 详情接口**不给专辑名**（只有集标题）⇒ 用第一集的标题做提示，
            // 由调用方（或 UI）结合列表给出的名字显示。**不臆造一个专辑名**。
            title_hint = Some(t.clone());
        }
        if updated.is_none() {
            updated = as_string(row.get("updated_at")).filter(|s| !s.is_empty());
        }
        episodes.push(CspEpisode {
            id: file,
            title: t,
            // DEX 常量里 vod_play_from 只有一段 "博看听书" ⇒ 单线路
            flag: "博看听书".to_string(),
        });
    }

    // ★ 反空真：list 非空却一条 file 都没有 ⇒ 结构变了（不是"这张专辑没内容"）
    if episodes.is_empty() && !list.is_empty() {
        return Err(format!(
            "详情有 {} 条集但都缺 file ⇒ 上游字段结构可能变了：{}",
            list.len(),
            truncate(&list[0].to_string(), 200)
        ));
    }

    let title = title_hint.unwrap_or_else(|| "（上游未给标题）".to_string());
    // DEX 常量："更新于 " + updated_at
    let description = updated.map(|u| format!("更新于 {u}"));

    Ok(CspDetail {
        id: String::new(),
        title,
        // 详情接口不含封面（只有列表有）⇒ 如实给 None，**不从列表猜**
        cover: None,
        description,
        episodes,
    })
}

/// 宽松取值：数字 / 字符串都收（上游对同一字段可能给 `4033132` 或 `"4033132"`）
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
impl CspSite for TingBokan {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：18 个分类（来自 DEX 常量）+ 首屏取第一个分类的 24 条
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let categories = Self::CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();

        let first = Self::CATEGORIES[0].0;
        let v = self.fetch_list(first, 1).await?;
        let items = parse_list(&v, 1)?.items;

        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let v = self.fetch_list(tid, page).await?;
        parse_list(&v, page)
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("专辑 id 为空".to_string());
        }
        let v = self.fetch_units(id, 1).await?;
        let mut d = parse_detail(&v)?;
        d.id = id.to_string();
        Ok(d)
    }

    /// 取流：`CspEpisode.id` 就是上游给的**直链音频**
    ///
    /// 依据：DEX 常量里取流模板是 `{"parse":0,"url":"…","header":{}}`
    /// ⇒ 原版就是 **parse:0 直链**；实测 `file` 形如
    /// `http://audio.bookan.com.cn/video1/audio/…/aache64_cf3c3a52.m4a`。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if !(id.starts_with("http://") || id.starts_with("https://")) {
            return Err(format!("播放 id 不是 http(s) 地址：{}", truncate(id, 120)));
        }
        Ok(vec![CspPlay {
            url: id.to_string(),
            headers: Vec::new(),
            label: Some("博看听书".to_string()),
        }])
    }

    /// DEX 里 TingBokan **有** searchContent（8 个方法里有它）⇒ 真支持搜索
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let v = self.fetch_search(kw, page).await?;
        parse_list(&v, page)
    }
}

// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
//
// # 这个类的事实（别丢）
// ```text
// csp_TingBokan（📕博看丨听书资源）：★ 分类表 18 组**来自 DEX 常量**（不是抓导航）
//   列表 /voice/book/list?instance_id=25304&category_id=<1303..1320>&num=24  HTTP 200 / 24 条
//   详情 /voice/album/units?album_id=<id>&num=200&order=1                    HTTP 200 / 60 集
//   搜索 es.bookan.com.cn/api/v3/voice/book?instanceId=25304&keyword=<kw>      HTTP 200 / 20 条
// ⚠️ **业务码是 0 不是 200**（实测两个接口都是 code:0）—— 照抄"200 才算成功"会全判失败。
// ⚠️ 已知缺口：原版有 mProxy，本批不做（见文件头）。
// ⚠️ detail 接口不返回专辑名（只有集标题）⇒ title 用首集标题，**不臆造**。
// ```
crate::csp::register_site!(TingBokan);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实响应片段（2026-10-27 实测抓下后裁剪）
    const FIX_LIST: &str = r#"{
      "code": 0, "msg": "ok",
      "data": {"total": 528, "current_page": 1, "per_page": 24, "last_page": 22,
        "list": [
          {"cover": "http://img-qn.bookan.com.cn/video1/audiocover/defaultcover.png",
           "name": "葵花向太阳", "id": 4033132, "press": "",
           "extra": {"grade": 10, "author": "徐鲁", "play": 4132}},
          {"cover": "", "name": "红岩", "id": 3312215, "extra": {"author": "罗广斌"}}
        ]}
    }"#;

    const FIX_UNITS: &str = r#"{
      "code": 0, "msg": "ok",
      "data": {"order": 1, "total": 60, "per_page": 200, "current_page": 1, "last_page": 1,
        "list": [
          {"id": 7762053, "title": "01.《葵花向太阳》 引子 心中的桥",
           "file": "http://audio.bookan.com.cn/video1/audio/2022120101/aache64_cf3c3a52.m4a",
           "duration": 126, "size": 1981, "created_at": "2022-12-01 01:50:03",
           "updated_at": "2022-12-01 05:30:03", "extra": {}},
          {"id": 7762054, "title": "02.《葵花向太阳》 第二章",
           "file": "http://audio.bookan.com.cn/video1/audio/2022120101/bbche64_cc33.m4a",
           "duration": 133, "updated_at": "2022-12-01 05:31:03"}
        ]}
    }"#;

    fn j(s: &str) -> serde_json::Value {
        serde_json::from_str(s).expect("夹具必须是合法 JSON")
    }

    // ── 分类表 ────────────────────────────────────────────────────

    #[test]
    /// ★ 18 组分类**逐对来自 DEX 常量**；id 连续 1303..1320
    ///
    /// ⚠️ 本条在写下的**第一次运行时红了**（我断言写了 17，实际 18：
    ///    1303..1320 是**闭区间 18 个数**，而我按"17 组"数了分类名）。
    ///    ⇒ 门禁抓出了我自己的错——这正是它该做的。现已改正为 18。
    fn categories_are_the_eighteen_from_dex_constants() {
        assert_eq!(TingBokan::CATEGORIES.len(), 18, "DEX 常量里是 18 组（1303..1320 闭区间）");
        assert_eq!(TingBokan::CATEGORIES[0], ("1303", "故事会"));
        assert_eq!(TingBokan::CATEGORIES[17], ("1320", "国学经典"));
        for (i, (id, _)) in TingBokan::CATEGORIES.iter().enumerate() {
            let expect = 1303 + i;
            assert_eq!(*id, expect.to_string(), "id 必须连续 1303..1320");
        }
    }

    // ── ★ 业务码：0 才是成功 ─────────────────────────────────────

    #[test]
    /// ★★ 本条是**本站最容易写错的地方**：成功码是 0
    ///
    /// 注入：把 `OK_CODE` 改成 200 ⇒ 本条立刻红（真响应会被判失败）。
    fn business_code_zero_is_success() {
        let v = j(r#"{"code":0,"msg":"ok","data":{"list":[]}}"#);
        assert!(
            check_code(&v, "https://x/y").is_ok(),
            "★ 博看的成功码是 0（实测）—— 判 200 会全盘失败"
        );
    }

    #[test]
    /// 对照：**code=200 在本站反而是异常**（不是成功）
    fn business_code_200_is_not_success_here() {
        let v = j(r#"{"code":200,"msg":"unexpected","data":{"list":[]}}"#);
        let err = check_code(&v, "https://x/y").unwrap_err();
        assert!(err.contains("业务码非 0"), "{err}");
    }

    #[test]
    fn missing_code_is_error() {
        let err = check_code(&j(r#"{"data":{}}"#), "https://x/y").unwrap_err();
        assert!(err.contains("缺少 code"), "{err}");
    }

    // ── parse_list ────────────────────────────────────────────────

    #[test]
    fn list_maps_dex_field_names() {
        let l = parse_list(&j(FIX_LIST), 1).expect("真响应片段必须解析得出来");
        assert_eq!(l.items.len(), 2);
        assert_eq!(l.items[0].id, "4033132", "数字 id 收成字符串");
        assert_eq!(l.items[0].title, "葵花向太阳");
        assert_eq!(
            l.items[0].cover.as_deref(),
            Some("http://img-qn.bookan.com.cn/video1/audiocover/defaultcover.png")
        );
        assert_eq!(l.items[0].subtitle.as_deref(), Some("徐鲁"), "副标题 = extra.author");
        // 空 cover 要收敛成 None（而不是 Some("")）
        assert_eq!(l.items[1].cover, None, "空封面必须成 None，不许留空串");
        assert_eq!(l.page_count, Some(22), "last_page → page_count");
        assert_eq!(l.total, Some(528));
    }

    #[test]
    /// ★ 反空真 ①：**list 非空但取不到 id** ⇒ 报错（结构变了）
    ///
    /// 注入：删掉那个 `items.is_empty() && !list.is_empty()` 的 Err ⇒ 本条红。
    fn list_with_unmappable_rows_is_error_not_empty_ok() {
        let bad = j(r#"{"code":0,"data":{"list":[{"name":"无 id 的条目"}]}}"#);
        let err = parse_list(&bad, 1).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// ★ 反空真 ②：**list 真空** ⇒ 是"这个分类没内容"（正常），返回空而不是报错
    fn list_with_genuinely_empty_data_is_ok_empty() {
        let v = j(r#"{"code":0,"msg":"ok","data":{"list":[],"last_page":1}}"#);
        let l = parse_list(&v, 1).expect("真·空列表不是错误");
        assert!(l.items.is_empty());
    }

    #[test]
    fn list_without_data_list_is_error() {
        let err = parse_list(&j(r#"{"code":0,"data":{}}"#), 1).unwrap_err();
        assert!(err.contains("没有 list"), "{err}");
    }

    // ── parse_detail ──────────────────────────────────────────────

    #[test]
    fn detail_maps_units_to_episodes_with_direct_files() {
        let d = parse_detail(&j(FIX_UNITS)).expect("真响应片段必须解析得出来");
        assert_eq!(d.episodes.len(), 2, "两集");
        assert_eq!(
            d.episodes[0].id,
            "http://audio.bookan.com.cn/video1/audio/2022120101/aache64_cf3c3a52.m4a",
            "★ file 就是可播直链"
        );
        assert_eq!(d.episodes[0].title, "01.《葵花向太阳》 引子 心中的桥");
        assert_eq!(d.episodes[0].flag, "博看听书", "DEX 里 vod_play_from 只有这一段");
        assert!(
            d.description.as_deref().unwrap_or("").contains("更新于 2022-12-01 05:30:03"),
            "DEX 常量拼装：更新于 + updated_at：{:?}",
            d.description
        );
        assert_eq!(d.cover, None, "详情接口不给封面 ⇒ 如实 None，不许从列表猜");
    }

    #[test]
    /// ★ 反空真 ③：**有集但都缺 file** ⇒ 报错（不是"这张专辑没内容"）
    fn detail_with_units_but_no_file_is_error() {
        let bad = j(r#"{"code":0,"data":{"list":[{"id":1,"title":"01"}]}}"#);
        let err = parse_detail(&bad).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// 集真为空 ⇒ 不是错误，返回空线路
    fn detail_with_empty_units_is_ok_empty() {
        let v = j(r#"{"code":0,"data":{"list":[]}}"#);
        let d = parse_detail(&v).expect("真·无集不是错误");
        assert!(d.episodes.is_empty());
    }

    #[test]
    fn detail_without_data_list_is_error() {
        let err = parse_detail(&j(r#"{"code":0,"data":{}}"#)).unwrap_err();
        assert!(err.contains("没有 list"), "{err}");
    }

    // ── urlencode ─────────────────────────────────────────────────

    #[test]
    fn urlencode_keeps_unreserved_and_escapes_utf8() {
        assert_eq!(urlencode("abc-_.~123"), "abc-_.~123");
        // 中文按 UTF-8 逐字节编码
        assert_eq!(urlencode("红"), "%E7%BA%A2");
        assert_eq!(urlencode("a b"), "a%20b", "空格用 %20（不是表单的 +）");
    }

    // ── 能力位 / 边界 ─────────────────────────────────────────────

    #[test]
    fn search_is_declared_supported() {
        assert!(
            TingBokan::new().supports_search(),
            "★ DEX 里 TingBokan 有 searchContent ⇒ 必须声明 true"
        );
    }

    #[tokio::test]
    async fn empty_kw_fails_instead_of_silent_all() {
        let err = TingBokan::new().search("  ", 1, "").await.unwrap_err();
        assert!(err.contains("搜索词为空"), "{err}");
    }

    #[tokio::test]
    async fn empty_tid_fails_instead_of_silent_default() {
        let err = TingBokan::new().list("", 1, "").await.unwrap_err();
        assert!(err.contains("分类 id 为空"), "{err}");
    }

    #[tokio::test]
    async fn play_returns_direct_audio_as_is() {
        let s = TingBokan::new();
        let url = "http://audio.bookan.com.cn/video1/audio/2022120101/aache64_cf3c3a52.m4a";
        let plays = s.play("博看听书", url, "").await.expect("直链原样返回");
        assert_eq!(plays.len(), 1);
        assert_eq!(plays[0].url, url);
        assert!(plays[0].headers.is_empty(), "DEX 的 header 是空对象");
    }

    #[tokio::test]
    async fn play_rejects_non_http_id() {
        let err = TingBokan::new().play("博看听书", "4033132", "").await.unwrap_err();
        assert!(err.contains("不是 http(s) 地址"), "{err}");
    }

    // ── 真网络（默认不跑；显式跑必须给 CSP_LIVE=1，否则**失败**）──

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib ting_bokan_live --release -- --ignored --nocapture"]
    async fn ting_bokan_live_home_list_detail_search_play() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = TingBokan::new();

        let home = s.home("").await.expect("home 必须真取到数据");
        assert_eq!(home.categories.len(), 18);
        assert!(!home.items.is_empty(), "★ 反空真：首屏必须有真条目");
        println!("LIVE home：分类 {} 个，首屏 {} 条", home.categories.len(), home.items.len());

        let list = s.list("1303", 1, "").await.expect("故事会分类必须真取到数据");
        assert!(!list.items.is_empty(), "★ 反空真");
        println!(
            "LIVE list 故事会：{} 条，page_count={:?} total={:?}",
            list.items.len(),
            list.page_count,
            list.total
        );

        let id = list.items[0].id.clone();
        let title = list.items[0].title.clone();
        let d = s.detail(&id, "").await.expect("详情必须真取到数据");
        assert!(!d.episodes.is_empty(), "★ 反空真：必须有集");
        println!("LIVE detail {id}（{title}）：{} 集", d.episodes.len());

        let ep = d.episodes.first().expect("已断言非空");
        let plays = s.play(&ep.flag, &ep.id, "").await.expect("直链必须返回");
        assert!(plays[0].url.starts_with("http"), "★ 反空真：必须是真地址");
        println!("LIVE play：{}（{}）", plays[0].url, ep.title);

        let sr = s.search("红", 1, "").await.expect("搜索必须真取到数据");
        assert!(!sr.items.is_empty(), "★ 反空真：搜索结果不能空");
        println!("LIVE search 红：{} 条，首条={}", sr.items.len(), sr.items[0].title);
    }

    #[test]
    /// ★★ 不读系统代理（**跨批一致性**：本仓 csp 既定惯例，见 `app99.rs:342`）
    ///
    /// 断言的**对象是源码形态**（构造链里有没有 `.no_proxy()`），**不依赖网络**。
    /// 注入：删掉那条 `.no_proxy()` ⇒ 本条 FAILED。
    /// ★ 用 `impl_src_only` 先剥测试段，防"本函数自己的字面量喂饱门禁 ⇒ 假绿"。
    fn client_does_not_read_system_proxy() {
        let src = crate::csp::shared::impl_src_only(include_str!("ting_bokan.rs"));
        assert!(
            src.contains(".no_proxy()"),
            "★ Client 构造链必须含 `.no_proxy()`（不读系统代理）；             否则装了代理的机器上会把'站点可用'测成'全宕'"
        );
    }
}