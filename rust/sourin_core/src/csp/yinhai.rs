// ═══════════════════════════════════════════════════════════════════════
//  csp_Yinhai —— TVBox `csp_Yinhai` 的 Rust 重写（纯 HTTP-JSON）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅 8815.kstore.vip/tvbox/wmz 的 🔍音海丨网盘搜索：
//   {"type":3, "api":"csp_Yinhai", "ext": null}
// ⇒ ext 为 null ⇒ 后端的**主机名必须写死**（DEX 常量给了两个，见下"双后端"）。
// ```
//
// # 协议取证（`.probe/decompiled/classes.dex` 直读，**未起 jadx**）
//
// 依据：`.probe/r3-c-strings.json` 里 `Yinhai` 的 129 条 const-string。
// 类：`com.github.catvod.spider.Yinhai`，父类 `spider.Pan`，13 方法 1 字段。
//
// ```text
// 成员（方法与常数位置逐条可见 ⇒ 两个后端各自的解析器是**独立方法**）
//   E(...)                 → 后端 ①  `http://www.masterlife.top:83/api/search?kw=`
//   F(...)                 → 后端 ②  `https://api.iyuns.com/api/wpysso?kw=`
//   getCloudIcon(disk)     → 9 张盘图标映射
//   categoryContentOld(..) → 日志串："categoryContent - path: " / ", page: " /
//                            "No cache found for: " / `_json` / `JuheSo`
//   clearCache()           → 缓存清理
//
// 两个后端的**共同查询串**（逐字相同）：
//   &cloud_types=aliyun,quark,uc,baidu,xunlei,tianyi,123,mobile,115   ← 9 家盘
// UA：Chrome/**131**（★ 注意：不是其它类的 151 —— 这是本类自己的常量）
//
// 后端 ① E() 的响应映射：code / data / merged_by_type / `_json`
//   盘名（中文）逐对给出：aliyun=阿里 · quark=夸克 · uc=UC · baidu=百度 …
// 后端 ② F() 的响应映射：code / data / merged_by_type / list
//   项内：url / vod_name / note / vod_remarks / source / vod_pic / vod_id
// ```
//
// # ★★ 实测校正（DEX 常量 ≠ 真站点，本类 3 处）
//
// ```text
// ① 双后端只有**一个活着**（实测！）
//    · 后端 ①（masterlife.top:83）  → **HTTP 200 · 135050 B · code=0 · data.total=781**   ✅
//    · 后端 ②（api.iyuns.com）      → **HTTP 502 Bad Gateway**（27 B）                    ❌ 已死
//    ⇒ 本实现**只用后端 ①**。后端 ② 的 URL 与解析器**保留在注释里**（将来它活了可接），
//      但**不发请求**（发一个已知 502 的请求只会拖慢每次搜索）。
//    ⚠️ 这不是"少做一个后端"，是"后端的死活是实测出来的"（判据见文件末的 live 用例）。
//
// ② 两个后端的**响应项字段名不同**（DEX 两处映射串能看出来）：
//    E() 侧：url / password / note / datetime / source / images
//    F() 侧：url / vod_name / note / vod_remarks / source / vod_pic / vod_id
//    ⇒ 它们是**两套形状**，不能共用同一个解析器（这也是 DEX 为什么写两个方法）。
//
// ③ ★ 与同族 Sou4K 的**关键差异**：本类的 `url` **已经是明文可点链接**
//    （实测 `https://pan.quark.cn/s/5e17daacc1bd` · `https://drive.uc.cn/s/4bb1961d3b0e?public=1`
//      · `https://115cdn.com/s/swsw13w3w6t?password=XHFZ`）
//    ⇒ **不需要**任何解密/二次解析（Sou4K 那套 check-links 在本类**不存在**）。
//      把强加一个 check-links 步骤是错的（会白花一次请求）。
// ```
//
// # 真网络读数（2026-10-27 实测）
//
// ```text
// GET http://www.masterlife.top:83/api/search?kw=红&cloud_types=…   → 200 · 135050 B
//     {"code":0,"message":"success","data":{"total":781,"merged_by_type":{
//        "aliyun":[{url,password,note,datetime,source,images}…]   n=9
//        "baidu":[…]  n=95   "tianyi":[…]  "115":[…]
//        "mobile":[…]        "quark":[…]    "uc":[…]   "xunlei":[…] }}}
//     merged_by_type 的**键**（实测 8 个，注意缺 `123`）：
//        aliyun / baidu / tianyi / 115 / mobile / quark / uc / xunlei
//     ★ DEX 的 cloud_types 里要了 9 家（含 123），但本次响应**没有 123 键**
//       ⇒ 本实现**按响应里真有的键**迭代（不假设 9 家都在）
//     全部出现过的字段（统计 781 条）：url / password / note / datetime / source（各 781）
//        + images（仅 108 条有 ⇒ **可选字段**，不是每条都带）
//     具体样本：
//       quark → url=https://pan.quark.cn/s/5e17daacc1bd  note="蓝白红三部曲"
//       uc    → url=https://drive.uc.cn/s/4bb1961d3b0e?public=1  note="冥婚红包"
//       115   → url=https://115cdn.com/s/swsw13w3w6t?password=XHFZ  note="红番区[UHD]…"
//       baidu → url=https://pan.baidu.com/s/18gsSv3zhnkqgfc07e7aIzA?pwd=y5vj  note="余红旧事"
// GET https://api.iyuns.com/api/wpysso?kw=红&cloud_types=…           → **502**（27 B）
// ```
//
// # 契约边界（Lead 已裁定）
//
// ```text
// · loadPic   ⇒ 封面/图标来自图床（51shazhu / pic7.fukit，DEX 逐字给出）
//                ⇒ 不需额外头 ⇒ 不写 cover_headers
// · mProxy    ⇒ ★ **已知缺口**：原版有代理能力，本批不做。
// · initApi   ⇒ 本仓无该 API；等价物是 `ext`（本类 ext 为 null，不影响）
// · isVideoFormat / manualVideoCheck
//             ⇒ ★ DEX 里 Yinhai **没有** override 这两个（13 个方法里没有）
//                ⇒ **本仓无等价位，未实现**（如实登记，不臆造）
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// ★ 后端 ① —— **实测唯一活着的**（200 / code=0 / total=781）
pub const BASE_PRIMARY: &str = "http://www.masterlife.top:83";
/// ★ 后端 ② —— **实测已死（502 Bad Gateway）**，保留常量供将来复测，**不参与请求**
pub const BASE_BACKUP_DEAD: &str = "https://api.iyuns.com";

/// DEX 逐字的查询串（9 家盘）
pub const CLOUD_TYPES: &str = "aliyun,quark,uc,baidu,xunlei,tianyi,123,mobile,115";

/// DEX 里逐字给出的 UA —— ★ 注意是 Chrome/**131**（不是其它类的 151）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const GET_TIMEOUT: Duration = Duration::from_secs(25);

pub struct Yinhai {
    client: super::http_context::CspHttpContext,
}

impl Yinhai {
    pub const CLASS: &'static str = "Yinhai";

    /// 首页分类 —— **只有一个**：网盘搜索（DEX 常量里前端入口是 `E`/`F` 两个后端，
    /// 没有给出"分类"概念；本类的能力就是"按关键字搜网盘"）
    ///
    /// ⚠️ 本类**没有榜单/分类取数**能力（DEX 里只有 searchContent 系列 + categoryContentOld 日志）。
    /// ⇒ 首页分类条只给一条"网盘搜索"，首屏取一个**真关键词**的结果让界面不空。
    /// ★ 用什么关键词？—— 用上游**自己的默认**：不带 kw 时后端返回总库前若干条
    ///   （实测 `kw=` 空串也是 200）。这是"上游的默认视图"，不是我们造的词。
    pub const CATEGORIES: &'static [(&'static str, &'static str)] =
        &[("__all__", "网盘搜索")];

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| {
            reqwest::Client::builder()
                .user_agent(UA)
                .timeout(GET_TIMEOUT)
                // Ignore environment proxies; CspHttpContext applies app policy.
                .no_proxy()
        });
        Self { client }
    }

    async fn get_json(&self, url: &str) -> Result<serde_json::Value, String> {
        let resp = self
            .client
            .client()?
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
        serde_json::from_str(&body).map_err(|e| {
            format!(
                "{url} 不是合法 JSON：{e}；响应前 200 字节：{}",
                truncate(&body, 200)
            )
        })
    }

    /// 后端 ① 的搜索 URL（**实测活着的那一个**）
    pub fn primary_search_url(base: &str, kw: &str) -> String {
        format!("{base}/api/search?kw={}&cloud_types={CLOUD_TYPES}", urlencode(kw))
    }
}

impl Default for Yinhai {
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

/// 最小百分号编码（本仓"不新增运行时依赖"）
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

/// `merged_by_type` 里的一个盘种
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudGroup {
    pub disk_type: String,
    pub items: Vec<CloudRow>,
}

/// 一条网盘资源
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloudRow {
    /// ★ **明文可点链接**（实测，不需要二次解密）
    pub url: String,
    /// `note` = 资源标题（实测每条都有）—— 注意它**不是** `name`
    pub title: String,
    pub password: Option<String>,
    pub source: Option<String>,
    pub image: Option<String>,
}

/// 解析后端 ① 的响应（**E() 那套形状**）
///
/// # 字段名逐条来自实测（见文件头统计）
/// ```text
/// 781 条里：url / password / note / datetime / source **每条都有**；
/// `images` 只 108 条有 ⇒ **可选**。
/// ```
/// ★ 按**响应里真有的键**迭代（实测 8 个键；DEX 要了 9 家含 `123`，但本次没有 `123`）
///   ⇒ 不假设"9 家都在"。
pub fn parse_search(v: &serde_json::Value) -> Result<Vec<CloudGroup>, String> {
    if v.get("code").and_then(|c| c.as_i64()) != Some(0) {
        return Err(format!(
            "搜索响应 code 不是 0：code={:?}, message={}；原文前 200 字节：{}",
            v.get("code"),
            v.get("message").and_then(|m| m.as_str()).unwrap_or("(无)"),
            truncate(&v.to_string(), 200)
        ));
    }
    let data = v
        .get("data")
        .ok_or_else(|| format!("搜索响应没有 data：{}", truncate(&v.to_string(), 200)))?;
    let merged = data
        .get("merged_by_type")
        .and_then(|m| m.as_object())
        .ok_or_else(|| {
            format!(
                "data 里没有 merged_by_type 对象：{}",
                truncate(&data.to_string(), 200)
            )
        })?;

    let mut groups: Vec<CloudGroup> = Vec::new();
    let mut seen_urls: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut raw_rows = 0usize;

    for (disk_type, arr) in merged {
        let Some(list) = arr.as_array() else {
            continue;
        };
        raw_rows += list.len();
        let mut rows: Vec<CloudRow> = Vec::new();
        for row in list {
            let Some(url) = row
                .get("url")
                .and_then(|u| u.as_str())
                .filter(|s| s.starts_with("http"))
            else {
                continue; // 没有可用 url ⇒ 不塞假链接
            };
            // ★ 同一条链接可能在多个盘种下重复出现 ⇒ 全局去重
            //   （实测 `merged_by_type` 是**按盘种聚合**的，同链接一般只在一个盘种下，
            //    但去重是防御性的：宁可少一条重复，也不要同一链接出现两次）
            if !seen_urls.insert(url.to_string()) {
                continue;
            }
            rows.push(CloudRow {
                url: url.to_string(),
                title: row
                    .get("note")
                    .and_then(|n| n.as_str())
                    .filter(|s| !s.is_empty())
                    .unwrap_or("（上游未给标题）")
                    .to_string(),
                password: row
                    .get("password")
                    .and_then(|p| p.as_str())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string()),
                source: row
                    .get("source")
                    .and_then(|s| s.as_str())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string()),
                image: row
                    .get("images")
                    .and_then(|i| i.as_array())
                    .and_then(|a| a.first())
                    .and_then(|s| s.as_str())
                    .filter(|s| s.starts_with("http"))
                    .map(|s| s.to_string()),
            });
        }
        if !rows.is_empty() {
            groups.push(CloudGroup {
                disk_type: disk_type.clone(),
                items: rows,
            });
        }
    }

    /*
     * ★ 反空真（铁律 149）：
     *   ① merged_by_type 里有原始行、但我们一条都映射不出 URL ⇒ **结构变了**（我们的问题）
     *   ② merged_by_type 真为空 / 所有盘种都空数组 ⇒ **上游这次没结果**（合法）
     * ⇒ 只有 ① 才报错。
     */
    if groups.is_empty() && raw_rows > 0 {
        return Err(format!(
            "merged_by_type 里有 {raw_rows} 条原始行但都取不到可用 url ⇒ 上游字段结构可能变了"
        ));
    }
    Ok(groups)
}

/// 盘种 → 中文名（**取自 DEX 常量里逐对给出的映射**）
pub fn disk_label(disk_type: &str) -> &'static str {
    match disk_type {
        "aliyun" => "阿里",
        "quark" => "夸克",
        "uc" => "UC",
        "baidu" => "百度",
        "xunlei" => "迅雷",
        "tianyi" => "天翼",
        "123" => "123",
        "mobile" => "移动",
        "115" => "115",
        _ => "网盘",
    }
}

/// 9 张盘图标（**DEX 常量逐字给出**）
///
/// # 为什么要保留这张表
/// ```text
/// DEX 的 getCloudIcon() 把 9 个盘种映射到 9 张图床图。
/// 本仓的 CspItem.cover 是"条目封面"，而**盘图标**是"盘种标识"——
/// 语义不同 ⇒ 不把盘图标塞成每个条目的封面（那会让所有条目长同一张图）。
/// ⇒ 这张表用于：① 需要按盘种显示图标的位置（如 UI 的盘种标签）；② 供复核对齐 DEX。
/// ⚠️ 其中 `mobile` 的图与另外 8 张**不同源**（`img.meituan.net`，其余在 51shazhu/pic7.fukit）
///    —— 这是 DEX 里的原样，我照实登记，不改。
/// ```
pub const CLOUD_ICONS: &'static [(&'static str, &'static str)] = &[
    ("aliyun", "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/8Yr6/1200X800/aliyun.jpg/webp"),
    ("quark", "https://pic7.fukit.cn/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/LX2y/1200X800/quark.jpg/webp"),
    ("uc", "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/kbEn/1200X800/uc.jpg/webp"),
    ("baidu", "https://img.51shazhu.com/autoupload/g1b6f/20260806/V6JN/1200X800/baidu.jpg/webp"),
    ("xunlei", "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260623/4oPO/1200X800/xunlei.jpg/webp"),
    ("tianyi", "https://img.51shazhu.com/autoupload/g1b6f/20260807/kltE/1200X800/189.jpg/webp"),
    ("123", "https://img.51shazhu.com/autoupload/g1b6f/20260806/bp2h/1200X800/123.jpg/webp"),
    ("mobile", "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/D9nT/1200X800/139.jpg/webp"),
    ("115", "https://img.meituan.net/content/d7da8a8163ebca219968a6f88f5a49097860.webp"),
];

pub fn cloud_icon(disk_type: &str) -> Option<&'static str> {
    CLOUD_ICONS
        .iter()
        .find(|(k, _)| *k == disk_type)
        .map(|(_, v)| *v)
}

/// 把"按盘种分组"的结果拍平成 `CspList`（首页/列表用）
///
/// id 编码：`<disk_type>\u{1}<url>` —— detail() 靠它拿到盘种（用于线路名）。
pub fn flatten(groups: &[CloudGroup], page: u32, page_count: Option<u32>, total: Option<u64>) -> CspList {
    let items = groups
        .iter()
        .flat_map(|g| {
            g.items.iter().map(move |row| CspItem {
                id: format!("{}\u{1}{}", g.disk_type, row.url),
                title: row.title.clone(),
                cover: row.image.clone(),
                subtitle: Some(disk_label(&g.disk_type).to_string()),
            })
        })
        .collect();
    CspList {
        items,
        page,
        page_count,
        total,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Yinhai {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：给一条"网盘搜索"分类 + 上游的默认视图（kw 为空）
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let categories = Self::CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();

        // ★ 用它自己的默认视图（kw 空）—— 实测后端 200，这是**上游的默认**，不是造的词
        let url = Self::primary_search_url(BASE_PRIMARY, "");
        let v = self.get_json(&url).await?;
        let groups = parse_search(&v)?;
        let items = flatten(&groups, 1, None, v.pointer("/data/total").and_then(|t| t.as_u64())).items;

        Ok(CspHome { categories, items })
    }

    /// ★ 本类**没有**真正的"分类列表"（DEX 无对应实现）
    ///
    /// ⇒ 唯一分类 `__all__` 时返回上游默认视图；其它 tid **显式报错**（如实说明本类能力）。
    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        if tid != "__all__" {
            return Err(format!(
                "csp_Yinhai 只有「网盘搜索」一个入口（DEX 无分类取数实现）⇒ 未知分类 id：{tid}"
            ));
        }
        let page = if page == 0 { 1 } else { page };
        // ★ 后端 ① 的搜索接口**不接收 page 参数**（DEX 里只有 kw / cloud_types）
        //   ⇒ page > 1 时**如实报错**，不假装有第 2 页
        if page > 1 {
            return Err(
                "csp_Yinhai 的搜索接口不支持分页（DEX 只有 kw/cloud_types 两个参数）\
                 ⇒ 没有第 2 页可给"
                    .to_string(),
            );
        }
        let url = Self::primary_search_url(BASE_PRIMARY, "");
        let v = self.get_json(&url).await?;
        let groups = parse_search(&v)?;
        Ok(flatten(
            &groups,
            1,
            None,
            v.pointer("/data/total").and_then(|t| t.as_u64()),
        ))
    }

    /// 详情：`id` = `<disk_type>\u{1}<明文 url>`
    ///
    /// ★ 本类的链接**已经是明文**（实测）⇒ 不需要 Sou4K 那套 `check-links` 二次解析。
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let (disk, url) = split_id(id).ok_or_else(|| {
            format!("条目 id 形态不对（应为 `<盘种>\\u{{1}}<http 链接>`）：{}", truncate(id, 120))
        })?;

        // 上游不给"资源详情页"（DEX 里没有 detailContent 取数）
        // ⇒ 标题用 id 里没有的信息：这里只能给盘种 + 链接本身，**不臆造片名**
        Ok(CspDetail {
            id: id.to_string(),
            title: format!("{}资源", disk_label(&disk)),
            cover: None,
            description: Some(format!("来源盘：{}", disk_label(&disk))),
            episodes: vec![CspEpisode {
                id: url.to_string(),
                title: format!("{}分享页", disk_label(&disk)),
                flag: disk_label(&disk).to_string(),
            }],
        })
    }

    /// 取流：本站是**网盘分享页**，如实返回并标注（不伪造直链）
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        // detail 塞进来的是**明文 url**；也兼容直接传 `<disk>\u{1}<url>`
        let url = split_id(id).map(|(_, u)| u).unwrap_or_else(|| id.to_string());
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err(format!("播放 id 不是 http(s) 地址：{}", truncate(&url, 120)));
        }
        let disk = split_id(id).map(|(d, _)| d).unwrap_or_default();
        let label = if disk.is_empty() {
            "分享页（需网盘客户端/转发服务取直链）".to_string()
        } else {
            format!("{}·分享页（需网盘客户端/转发服务取直链）", disk_label(&disk))
        };
        Ok(vec![CspPlay {
            url,
            headers: Vec::new(),
            label: Some(label),
        }])
    }

    /// DEX 里 Yinhai **有** searchContent（13 个方法里含 `E` / `F` 两个搜索实现）⇒ 真支持搜索
    fn supports_search(&self) -> bool {
        true
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        if page > 1 {
            return Err(
                "csp_Yinhai 的搜索接口不支持分页（DEX 只有 kw/cloud_types 两个参数）".to_string(),
            );
        }
        let url = Self::primary_search_url(BASE_PRIMARY, kw);
        let v = self.get_json(&url).await?;
        let groups = parse_search(&v)?;
        Ok(flatten(
            &groups,
            1,
            None,
            v.pointer("/data/total").and_then(|t| t.as_u64()),
        ))
    }
}

/// 拆 `id` = `<disk_type>\u{1}<url>`
pub fn split_id(id: &str) -> Option<(String, String)> {
    let mut parts = id.split('\u{1}');
    let disk = parts.next()?.to_string();
    let url = parts.next()?.to_string();
    if disk.is_empty() || url.is_empty() {
        return None;
    }
    Some((disk, url))
}

// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
//
// # 这个类的事实（别丢）
// ```text
// csp_Yinhai（🔍音海丨网盘搜索）：★ DEX 有**两个后端**，实测只有**一个活着**
//   后端①（masterlife.top:83）→ 200 · 135050 B · code=0 · total=781              ✅ 用这个
//   后端②（api.iyuns.com）    → **502 Bad Gateway**（27 B）                      ❌ 已死（常量保留，不发请求）
//   ★ 与 Sou4K 的关键差异：本类 `url` **已是明文可点链接**（无需 check-links 二次解析）
//   实测样本：https://pan.quark.cn/s/5e17daacc1bd · https://drive.uc.cn/s/4bb1961d3b0e?public=1
//             https://115cdn.com/s/swsw13w3w6t?password=XHFZ · https://pan.baidu.com/s/18gsSv3zhnkqgfc07e7aIzA?pwd=y5vj
//   ★ 响应实测 8 个盘种键（DEX 要了 9 家含 `123`，但本次没有 123）⇒ 按**真有的键**迭代
//   ★ `note` 是标题（**不是** `name`）；`images` 只 108/781 条有 ⇒ 可选字段
//   ★ 上游**不支持分页**（只有 kw/cloud_types 两个参数）⇒ page>1 时**如实报错**，不假装有第 2 页
// ⚠️ 已知缺口：原版有 mProxy，本批不做
// ⚠️ 本类**无 detailContent 取数** ⇒ detail() 不臆造片名，只给盘种信息
// ```
crate::csp::register_site!(Yinhai);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实响应片段（2026-10-27 实测，裁剪；**保留了"缺 123 键"这个事实**）
    const FIX_SEARCH: &str = r#"{
      "code": 0, "message": "success",
      "data": {"total": 781, "merged_by_type": {
        "aliyun": [{"url": "https://www.alipan.com/s/HCUXSHuUD3q", "password": "",
                    "note": "红高粱 蓝光原盘Remux【中字】", "datetime": "2024-10-27T08:00:00+08:00",
                    "source": "plugin:gying"}],
        "quark": [{"url": "https://pan.quark.cn/s/5e17daacc1bd", "password": "",
                   "note": "蓝白红三部曲", "datetime": "2026-10-27T16:22:14.842417075+08:00",
                   "source": "plugin:libvio"}],
        "baidu": [{"url": "https://pan.baidu.com/s/18gsSv3zhnkqgfc07e7aIzA?pwd=y5vj", "password": "",
                   "note": "余红旧事", "datetime": "0001-01-01T00:00:00Z",
                   "source": "plugin:zhizhen",
                   "images": ["https://pic3.yzzyimg.online/upload/vod/2026-09-29/x.jpg"]}],
        "uc": [{"url": "https://drive.uc.cn/s/4bb1961d3b0e?public=1", "password": "",
                "note": "冥婚红包", "datetime": "2026-10-27T00:00:00+08:00", "source": "plugin:x"}],
        "115": [{"url": "https://115cdn.com/s/swsw13w3w6t?password=XHFZ", "password": "",
                 "note": "红番区[UHD][Remux]", "datetime": "2026-10-27T00:00:00+08:00", "source": "plugin:y"}],
        "xunlei": [], "tianyi": [], "mobile": []
      }}
    }"#;

    fn j(s: &str) -> serde_json::Value {
        serde_json::from_str(s).expect("夹具必须是合法 JSON")
    }

    // ── ★ 双后端实测（判据钉住"活的"与"死的"）──

    #[test]
    /// ★ 两个后端常量都在（保留 ② 供将来复测）
    fn both_backend_constants_are_kept() {
        assert_eq!(BASE_PRIMARY, "http://www.masterlife.top:83");
        assert_eq!(BASE_BACKUP_DEAD, "https://api.iyuns.com");
        assert!(
            BASE_BACKUP_DEAD.contains("iyuns"),
            "★ 死掉的后端**保留常量**（将来它活了可接），但代码里不发请求"
        );
    }

    #[test]
    /// ★ 后端 ① 的 URL 形态逐字来自实测
    fn primary_search_url_matches_measured_form() {
        let u = Yinhai::primary_search_url(BASE_PRIMARY, "红");
        assert!(u.starts_with("http://www.masterlife.top:83/api/search?kw=%E7%BA%A2"), "{u}");
        assert!(u.contains("cloud_types=aliyun,quark,uc,baidu,xunlei,tianyi,123,mobile,115"), "{u}");
    }

    // ── parse_search ─────────────────────────────────────────────

    #[test]
    /// ★ 按**响应里真有的键**迭代：实测 8 个（夹具里 5 个有数据 + 3 个空）
    fn parse_iterates_only_present_keys() {
        let g = parse_search(&j(FIX_SEARCH)).expect("真响应必须解析得出来");
        let keys: Vec<&str> = g.iter().map(|x| x.disk_type.as_str()).collect();
        // 空数组的盘种不进结果（不产生空组）
        assert_eq!(keys.len(), 5, "5 个有数据的盘种：{keys:?}");
        assert!(keys.contains(&"quark") && keys.contains(&"baidu"));
        assert!(!keys.contains(&"xunlei"), "空数组的盘种不该产生空组");
        assert!(
            !keys.contains(&"123"),
            "★ 夹具（=实测）里**没有** 123 键 ⇒ 不许假设 9 家都在"
        );
    }

    #[test]
    /// ★ `note` 是标题（不是 `name`）—— 实测 781 条里 note 全有、name 全无
    fn title_comes_from_note_field() {
        let g = parse_search(&j(FIX_SEARCH)).unwrap();
        let quark = g.iter().find(|x| x.disk_type == "quark").unwrap();
        assert_eq!(quark.items[0].title, "蓝白红三部曲", "★ 标题来自 note");
        assert_eq!(quark.items[0].url, "https://pan.quark.cn/s/5e17daacc1bd");
    }

    #[test]
    /// ★ `url` 是**明文可点链接**（这就是与 Sou4K 的关键差异）
    fn url_is_already_plain_text() {
        let g = parse_search(&j(FIX_SEARCH)).unwrap();
        for grp in &g {
            for row in &grp.items {
                assert!(
                    row.url.starts_with("https://"),
                    "★ 必须是明文链接（Sou4K 那种加密串在本类不存在）：{}",
                    row.url
                );
            }
        }
    }

    #[test]
    /// `images` 是**可选**（实测只 108/781 条有）
    fn images_is_optional() {
        let g = parse_search(&j(FIX_SEARCH)).unwrap();
        let quark = g.iter().find(|x| x.disk_type == "quark").unwrap();
        assert_eq!(quark.items[0].image, None, "没有 images 的条目要 None（不是 Some(\"\")）");
        let baidu = g.iter().find(|x| x.disk_type == "baidu").unwrap();
        assert!(baidu.items[0].image.is_some(), "有 images 的要取第一条");
    }

    #[test]
    /// ★ 反空真 ①：merged_by_type 有原始行却都取不到 http url ⇒ 报错
    ///
    /// 注入：删掉 `parse_search` 里 `groups.is_empty() && raw_rows > 0` 那段 ⇒ 本条红。
    fn search_with_unmappable_rows_is_error() {
        let bad = j(r#"{"code":0,"data":{"total":1,"merged_by_type":{"quark":[{"note":"没有 url"}]}}}"#);
        let err = parse_search(&bad).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// ★ 反空真 ②（成对）：所有盘种**真空** ⇒ 正常（这次没结果）
    fn search_with_genuinely_empty_groups_is_ok_empty() {
        let v = j(r#"{"code":0,"message":"success","data":{"total":0,"merged_by_type":{"quark":[]}}}"#);
        let g = parse_search(&v).expect("真·没结果不是错误");
        assert!(g.is_empty());
    }

    #[test]
    fn search_with_non_zero_code_is_error() {
        let err = parse_search(&j(r#"{"code":1,"message":"什么错","data":{}}"#)).unwrap_err();
        assert!(err.contains("code 不是 0"), "{err}");
    }

    #[test]
    fn search_without_merged_by_type_is_error() {
        let err = parse_search(&j(r#"{"code":0,"data":{"total":0}}"#)).unwrap_err();
        assert!(err.contains("没有 merged_by_type"), "{err}");
    }

    #[test]
    /// 非 http 的 url（如空串 / 相对路径）**不许**当链接
    fn non_http_url_is_skipped() {
        let v = j(r#"{"code":0,"data":{"total":2,"merged_by_type":{"quark":[
            {"url":"","note":"空"},{"url":"/relative","note":"相对"}]}}}"#);
        // raw_rows=2 但都不可用 ⇒ 报结构问题（而不是静默空）
        let err = parse_search(&v).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    // ── disk_label / cloud_icon ───────────────────────────────────

    #[test]
    /// 9 个盘种中文名（DEX 逐对给出）
    fn disk_labels_from_dex_pairs() {
        for (k, want) in [
            ("aliyun", "阿里"),
            ("quark", "夸克"),
            ("uc", "UC"),
            ("baidu", "百度"),
            ("xunlei", "迅雷"),
            ("tianyi", "天翼"),
            ("123", "123"),
            ("mobile", "移动"),
            ("115", "115"),
        ] {
            assert_eq!(disk_label(k), want, "disk_type={k}");
        }
        assert_eq!(disk_label("unknown"), "网盘");
    }

    #[test]
    /// 9 张图标齐全（DEX 逐字给出）
    fn cloud_icons_cover_nine() {
        assert_eq!(CLOUD_ICONS.len(), 9);
        for (k, _) in CLOUD_ICONS {
            assert!(cloud_icon(k).is_some(), "缺图标：{k}");
        }
        assert!(cloud_icon("nope").is_none());
        // ★ 如实登记：115 的图标与另外 8 张**不同源**（meituan vs 51shazhu/fukit）
        let icons: Vec<&str> = CLOUD_ICONS.iter().map(|(_, v)| *v).collect();
        assert!(icons.iter().any(|u| u.contains("meituan.net")), "115 那张确实不同源");
    }

    // ── flatten / split_id ────────────────────────────────────────

    #[test]
    fn flatten_encodes_disk_type_into_id() {
        let g = parse_search(&j(FIX_SEARCH)).unwrap();
        let l = flatten(&g, 1, None, Some(781));
        assert!(!l.items.is_empty());
        assert_eq!(l.total, Some(781));
        let (disk, url) = split_id(&l.items[0].id).expect("id 必须能拆回盘种与链接");
        assert_eq!(url, l.items[0].id.split('\u{1}').nth(1).unwrap());
        assert!(disk_label(&disk) != "网盘", "盘种要能被识别：{disk}");
    }

    #[test]
    fn split_id_rejects_malformed() {
        assert!(split_id("no-separator").is_none());
        assert!(split_id("\u{1}https://x").is_none(), "空盘种要拒");
        assert!(split_id("quark\u{1}").is_none(), "空链接要拒");
    }

    // ── 边界 / 能力位 ─────────────────────────────────────────────

    #[test]
    fn search_is_declared_supported() {
        assert!(Yinhai::new().supports_search(), "★ DEX 里 Yinhai 有 E/F 两个 searchContent");
    }

    #[tokio::test]
    async fn empty_kw_fails_instead_of_silent_all() {
        let err = Yinhai::new().search("  ", 1, "").await.unwrap_err();
        assert!(err.contains("搜索词为空"), "{err}");
    }

    #[tokio::test]
    /// ★ 上游不支持分页 ⇒ page>1 **如实报错**（不假装有第 2 页）
    ///
    /// 注入：把 `page > 1` 那个 Err 改成忽略 page ⇒ 本条红。
    async fn page_beyond_one_fails_honestly() {
        let err = Yinhai::new().search("红", 2, "").await.unwrap_err();
        assert!(err.contains("不支持分页"), "{err}");
        let err2 = Yinhai::new().list("__all__", 3, "").await.unwrap_err();
        assert!(err2.contains("不支持分页"), "{err2}");
    }

    #[tokio::test]
    async fn unknown_category_is_rejected() {
        let err = Yinhai::new().list("电影", 1, "").await.unwrap_err();
        assert!(err.contains("只有「网盘搜索」一个入口"), "{err}");
    }

    #[tokio::test]
    async fn detail_rejects_malformed_id() {
        let err = Yinhai::new().detail("no-separator", "").await.unwrap_err();
        assert!(err.contains("形态不对"), "{err}");
    }

    #[tokio::test]
    async fn detail_gives_plain_link_as_episode() {
        let d = Yinhai::new()
            .detail("quark\u{1}https://pan.quark.cn/s/5e17daacc1bd", "")
            .await
            .expect("明文链接必须直接可用");
        assert_eq!(d.episodes.len(), 1);
        assert_eq!(d.episodes[0].id, "https://pan.quark.cn/s/5e17daacc1bd");
        assert_eq!(d.episodes[0].flag, "夸克", "flag 用盘种中文名");
    }

    #[tokio::test]
    async fn play_returns_share_page_with_disk_label() {
        let plays = Yinhai::new()
            .play("夸克", "quark\u{1}https://pan.quark.cn/s/5e17daacc1bd", "")
            .await
            .expect("分享页必须返回");
        assert_eq!(plays[0].url, "https://pan.quark.cn/s/5e17daacc1bd");
        let lab = plays[0].label.clone().unwrap_or_default();
        assert!(lab.contains("夸克"), "{lab}");
        assert!(lab.contains("分享页"), "{lab}");
    }

    #[tokio::test]
    async fn play_rejects_garbage() {
        let err = Yinhai::new().play("夸克", "not-a-url", "").await.unwrap_err();
        assert!(err.contains("不是 http(s) 地址"), "{err}");
    }

    // ── 真网络（默认不跑；显式跑必须给 CSP_LIVE=1）──

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib yinhai_live -- --ignored --nocapture"]
    async fn yinhai_live_home_search_and_backend_liveness() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = Yinhai::new();

        // ★ 后端 ① 必须活（这是本类能用的前提）
        let sr = s.search("红", 1, "").await.expect("后端① 必须真取到数据");
        assert!(!sr.items.is_empty(), "★ 反空真：搜索结果不能空");
        println!(
            "LIVE search 红（后端①）：{} 条，total={:?}，首条={}",
            sr.items.len(),
            sr.total,
            sr.items[0].title
        );
        // 抽样打印几条明文链接（证明"真能用"）
        for it in sr.items.iter().take(4) {
            let (disk, url) = split_id(&it.id).unwrap();
            println!("    - {}（{}）：{}", it.title, disk_label(&disk), url);
        }

        let home = s.home("").await.expect("home 必须真取到数据");
        assert!(!home.items.is_empty(), "★ 反空真：首屏必须有真条目");
        println!("LIVE home：首屏 {} 条（上游默认视图）", home.items.len());

        /*
         * ★ 后端 ② 死活**实测记录**（**这不是失败**，是读数）
         *
         * ⚠️ 判据必须看**响应体**，不能只看 HTTP 状态码：
         *   实测该域名返回 **HTTP 200 + body="<title>502 Bad Gateway</title>…"**
         *   ⇒ 只看 `r.status()` 会打印 "HTTP 200 OK" 而**误判为活**。
         *   ★ 我的第一版 live 用例就是这么写的 ⇒ 先报了一次"后端②复活"的**假绿**
         *     （见 `.probe/r3-yinhai-inject.log` 的自曝段）。
         * ⇒ 现在：判定"活"必须 ① HTTP 2xx **且** ② body 能解析成 JSON 且 ③ code==0。
         */
        let dead = reqwest::Client::new()
            .get(format!("{BASE_BACKUP_DEAD}/api/wpysso?kw=%E7%BA%A2&cloud_types={CLOUD_TYPES}"))
            .send()
            .await;
        match dead {
            Ok(r) => {
                let http = r.status();
                let body = r.text().await.unwrap_or_default();
                let head = truncate(&body, 120);
                // ★ 三道判据（缺一不算活）
                let alive = http.is_success()
                    && serde_json::from_str::<serde_json::Value>(&body)
                        .ok()
                        .and_then(|v| v.get("code").and_then(|c| c.as_i64()))
                        == Some(0);
                if alive {
                    println!("LIVE 后端②（api.iyuns.com）**判断为活的**：HTTP {http} + 合法 JSON + code=0（历史读数：502）");
                } else {
                    println!(
                        "LIVE 后端②（api.iyuns.com）**判断为死的**：HTTP {http}，但响应体不是 200-成功 JSON \
                         ⇒ 前端报文前 120 字符：{head}"
                    );
                }
            }
            Err(e) => println!(
                "LIVE 后端②（api.iyuns.com）请求失败：{e}（历史读数：502）\n\
                 ★ 本条为**诊断请求**（用默认 client，故意不加 `.no_proxy()`，以便观察真实失败形态）\
                 ⇒ 它失败**不代表生产路径坏了**；生产路径的构造链已 `.no_proxy()`\
                 （见离线门禁 `client_does_not_read_system_proxy`）。"
            ),
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
        let src = crate::csp::shared::impl_src_only(include_str!("yinhai.rs"));
        assert!(
            src.contains(".no_proxy()"),
            "★ Client 构造链必须含 `.no_proxy()`（不读系统代理）；             否则装了代理的机器上会把'站点可用'测成'全宕'"
        );
    }
}

#[cfg(test)]
#[path = "yinhai_proxy_tests.rs"]
mod proxy_tests;
