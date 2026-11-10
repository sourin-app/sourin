// ═══════════════════════════════════════════════════════════════════════
//  csp_TingShijie —— TVBox `csp_TingShijie` 的 Rust 重写（纯 HTTP-JSON）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅 8815.kstore.vip/tvbox/wmz 的 📢世界｜听书资源：
//   {"type":3, "api":"csp_TingShijie", "ext": null}
// ⇒ ext 为 null ⇒ base 必须写死（见下"base 的取证"）。
// ```
//
// # ★ 更正我先前的一个判断（**我曾经报错，这里纠正**）
//
// ```text
// 我在上一批报告里说："TingShijie 常量只给了 1 个 base，**真路径不在常量里**，
//                     需要你串行出单类源码"。
//
// 【纠正】按**方法分组**重新读 DEX 常量后发现：**端点模板全在常量里**
//   我之前只看了"未分组"的字符串池，把它们当成了零散串。
//   分组后的实际形态（逐字）：
//     · appHomeByCategory?categoryId=  &page=  &size=120      ← 列表
//     · book?bookId=                                           ← 详情（书）
//     · chapter?size=1000&page=  &sort=asc&bookId=             ← 详情（章节）
//   字段：status（成功码）/ data / list / vod_id(id) / vod_name(bookTitle) /
//         vod_pic(bookImage) / vod_remarks(bookAnchor) / count / position /
//         chapterId / "世界听书"（vod_play_from）
//   拼装：`#`（分集）/ `$`（名址）/ `|`（线路）
//   ★ UA 里**内嵌了主机名**：`TingShiJie/1.8.8 (m.i275.com)` ⇒ base 就是 `m.i275.com`
// ⇒ **不需要单类源码**。请把我先前那条请求从队列里去掉（省你的 jadx 时间）。
// ```
//
// # ★★ 上游实测：**站点活着，但它的数据库挂了**（这是本类的真实卡点）
//
// ```text
// base 确认：`https://m.i275.com`（从 UA 内嵌主机名推得，**实测通了**）
// 路径形态：`/index.php/<方法名>`（实测 `/index.php/book?bookId=1` 返回 200，
//           而 `/book?bookId=1`（不带 index.php）是 404）—— 典型 PHP 框架重写形态
//
// 【实测读数，5 次重试】
//   GET https://m.i275.com/index.php/appHomeByCategory?categoryId=1&page=1&size=120
//   GET https://m.i275.com/index.php/book?bookId=1
//   → 5 次里 **1 次 HTTP 200**，其余 4 次 `HTTP=000`（TLS 握手超时）
//   → 那次 200 的**响应体逐字**：
//       「数据库连接失败: SQLSTATE[HY000] [1045] Access denied for user
//         'app_365ting_com'@'156.238.237.65' (using password: YES)」
//   ⇒ ★ 这是**上游自己的数据库凭据失效**（MySQL 1045 = 用户名/密码被拒），
//     **不是我们请求写错**（错的请求会得到 404/参数错误，而不是数据库错误）。
// ```
//
// # 因此本类的交付形态（**如实分档**）
//
// ```text
// 【协议侧：实现完整】**可交付**
//   · 三个端点模板**逐字来自 DEX 常量**（不是猜的，见上）
//   · 请求头 UA **逐字来自 DEX**（`TingShiJie/1.8.8 (m.i275.com)`）
//   · 响应字段映射**逐字来自 DEX**（status/data/list/id/bookTitle/bookImage/bookAnchor）
//   · 成功码 = `status`（DEX 里 `status` 与 `data` 成对出现；具体成功值待上游恢复后确认）
//     ⇒ 本实现把"status 必须为真值"作为判据，并在失败信息里**原样打印上游的 data**，
//        这样上游恢复后我们**第一次跑就能看到它给的成功码**（不用再改代码猜）
// 【数据侧：上游死】**如实标注**
//   · 上游现在返回"数据库连接失败" ⇒ **拿不到任何真数据**
//   · live 用例把上游的**逐字响应**打印出来 ⇒ 上游一恢复，读数会自动变成真数据
// ```
//
// # 契约边界（Lead 已裁定）
//
// ```text
// · loadPic   ⇒ 封面是 `bookImage` 指向的 CDN（上游恢复后才知道具体域）⇒ 暂不写 cover_headers
// · mProxy    ⇒ ★ **已知缺口**：原版有代理能力，本批不做。
// · initApi   ⇒ 本仓无该 API；等价物是 `ext`（本类 ext 为 null，不影响）
// · isVideoFormat / manualVideoCheck
//             ⇒ ★ DEX 里 TingShijie **没有** override 这两个（11 个方法里没有）
//                ⇒ **本仓无等价位，未实现**（如实登记，不臆造）
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// base —— ★ 从 DEX 的 UA 常量 `TingShiJie/1.8.8 (m.i275.com)` 内嵌的主机名推得，
/// 并**实测通**（见文件头读数）。
pub const BASE: &str = "https://m.i275.com";

/// ★ 路径前缀：实测 `/index.php/<方法>` 可用，`/<方法>` 是 404 ⇒ 必须带 `index.php`
pub const PATH_PREFIX: &str = "/index.php";

/// DEX 里逐字给出的 UA（**主机名内嵌在里面**）
const UA: &str = "TingShiJie/1.8.8 (m.i275.com)";

/// 列表每页条数（DEX 模板 `&size=120`）
pub const LIST_SIZE: u32 = 120;
/// 章节每页条数（DEX 模板 `&size=1000`）
pub const CHAPTER_SIZE: u32 = 1000;

const GET_TIMEOUT: Duration = Duration::from_secs(20);

pub struct TingShijie {
    client: super::http_context::CspHttpContext,
}

impl TingShijie {
    pub const CLASS: &'static str = "TingShijie";

    /// 首页分类 —— DEX 常量里**没有**给出"分类名↔categoryId"成对表
    /// （只有模板 `appHomeByCategory?categoryId=<n>` 与一个孤立的 `'1'`）
    /// ⇒ 只给**一个**入口，id 用模板里那个 `'1'`，名字写"听书"（**不臆造具体分类名**）。
    ///
    /// ⚠️ 上游恢复后，真分类应当从它自己的分类接口取 —— 那时这里要改。
    pub const CATEGORIES: &'static [(&'static str, &'static str)] = &[("1", "听书")];

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

    async fn get_text(&self, url: &str) -> Result<String, String> {
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
        Ok(body)
    }
}

impl Default for TingShijie {
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

/// 三个端点（模板**逐字来自 DEX 常量**，拼接时补 `index.php` 前缀）
pub fn home_url(base: &str, category_id: &str, page: u32) -> String {
    let page = if page == 0 { 1 } else { page };
    format!(
        "{base}{PATH_PREFIX}/appHomeByCategory?categoryId={category_id}&page={page}&size={LIST_SIZE}"
    )
}

pub fn book_url(base: &str, book_id: &str) -> String {
    format!("{base}{PATH_PREFIX}/book?bookId={book_id}")
}

pub fn chapter_url(base: &str, book_id: &str, page: u32) -> String {
    let page = if page == 0 { 1 } else { page };
    format!(
        "{base}{PATH_PREFIX}/chapter?size={CHAPTER_SIZE}&page={page}&sort=asc&bookId={book_id}"
    )
}

/// 统一信封判定
///
/// # 为什么这么设计（上游当前是"数据库连接失败"）
/// ```text
/// DEX 里 `status` 与 `data` 成对出现，但**没给"成功时 status 等于什么"**。
/// 实测上游现在返回的是**纯文本** MySQL 错误（不是 JSON）。
/// ⇒ 本实现：
///   ① 先判"响应是不是 JSON" —— 不是 ⇒ 报"上游不是 JSON 响应"并把**原文**带出来
///      （这样"数据库连接失败"这类上游错会被**原样暴露**，而不是被我们包装成
///        "结构可能变了" 这种误导性理由）
///   ② 是 JSON 且缺 `status` ⇒ 报缺字段
///   ③ `status` 存在但为假值 ⇒ 报上游业务错误（带 msg/data）
/// ```
pub fn check_envelope(body: &str, url: &str) -> Result<serde_json::Value, String> {
    let v: serde_json::Value = serde_json::from_str(body).map_err(|e| {
        format!(
            "{url} 的响应不是 JSON（{e}）⇒ 上游未给出结构化数据；原文前 200 字符：{}",
            truncate(body, 200)
        )
    })?;
    match v.get("status") {
        None => Err(format!(
            "{url} 的 JSON 响应缺少 status 字段 ⇒ 结构可能变了；原文前 200 字符：{}",
            truncate(body, 200)
        )),
        Some(s) => {
            // `status` 的"成功值"未知 ⇒ 用**真值判定**（false / 0 / "" 视为失败）
            let truthy = match s {
                serde_json::Value::Bool(b) => *b,
                serde_json::Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
                serde_json::Value::String(t) => !t.is_empty() && t != "0",
                serde_json::Value::Null => false,
                _ => true,
            };
            if truthy {
                Ok(v)
            } else {
                Err(format!(
                    "{url} 上游 status 为假值（status={s}）⇒ 上游业务失败；data={}",
                    truncate(&v.get("data").cloned().unwrap_or(serde_json::Value::Null).to_string(), 200)
                ))
            }
        }
    }
}

/// 列表响应 → `CspList`
///
/// 字段映射**逐字来自 DEX**：`data.list[].id` / `.bookTitle` / `.bookImage` / `.bookAnchor`
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
        let Some(id) = row
            .get("id")
            .and_then(|i| i.as_i64().map(|n| n.to_string()).or_else(|| i.as_str().map(|s| s.to_string())))
        else {
            continue;
        };
        if id.is_empty() {
            continue;
        }
        items.push(CspItem {
            id,
            title: row
                .get("bookTitle")
                .and_then(|t| t.as_str())
                .filter(|s| !s.is_empty())
                .unwrap_or("（上游未给标题）")
                .to_string(),
            cover: row
                .get("bookImage")
                .and_then(|c| c.as_str())
                .filter(|s| s.starts_with("http"))
                .map(|s| s.to_string()),
            subtitle: row
                .get("bookAnchor")
                .and_then(|a| a.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string()),
        });
    }

    // ★ 反空真：list 非空却一条都建不出来 ⇒ 结构变了
    if items.is_empty() && !list.is_empty() {
        return Err(format!(
            "list 有 {} 条但都缺 id ⇒ 结构可能变了：{}",
            list.len(),
            truncate(&list[0].to_string(), 200)
        ));
    }

    Ok(CspList {
        items,
        page,
        page_count: data.get("pagecount").and_then(|p| p.as_u64()).map(|p| p as u32),
        total: data.get("total").and_then(|t| t.as_u64()),
    })
}

/// 详情（book + chapter）→ `CspDetail`
///
/// # 依据（DEX 常量逐字）
/// ```text
/// book 响应：data.bookData.{bookTitle, bookDesc, bookImage, count}
/// chapter 响应：data.list[].{position, chapterId}
/// 拼装：`#` 分集 / `$` 名址 / `|` 线路
/// vod_play_from = "世界听书"
/// ```
pub fn parse_detail(book: &serde_json::Value, chapters: &serde_json::Value) -> Result<CspDetail, String> {
    let book_data = book
        .pointer("/data/bookData")
        .ok_or_else(|| format!("book 响应没有 data.bookData：{}", truncate(&book.to_string(), 200)))?;

    let title = book_data
        .get("bookTitle")
        .and_then(|t| t.as_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("bookData 里没有 bookTitle：{}", truncate(&book_data.to_string(), 200)))?
        .to_string();

    let cover = book_data
        .get("bookImage")
        .and_then(|c| c.as_str())
        .filter(|s| s.starts_with("http"))
        .map(|s| s.to_string());

    let description = book_data
        .get("bookDesc")
        .and_then(|d| d.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let list = chapters
        .pointer("/data/list")
        .and_then(|l| l.as_array())
        .ok_or_else(|| {
            format!(
                "chapter 响应没有 data.list：{}",
                truncate(&chapters.to_string(), 200)
            )
        })?;

    let mut episodes = Vec::new();
    for row in list {
        let Some(cid) = row
            .get("chapterId")
            .and_then(|c| c.as_i64().map(|n| n.to_string()).or_else(|| c.as_str().map(|s| s.to_string())))
        else {
            continue; // 没 chapterId 播不了
        };
        if cid.is_empty() {
            continue;
        }
        // 标题：DEX 常量里 `position` 是章序号 ⇒ 用它拼"第 N 章"
        let title = row
            .get("position")
            .and_then(|p| p.as_i64().map(|n| format!("第 {n} 章")).or_else(|| p.as_str().map(|s| format!("第 {s} 章"))))
            .unwrap_or_else(|| format!("章节 {cid}"));
        episodes.push(CspEpisode {
            id: cid,
            title,
            flag: "世界听书".to_string(),
        });
    }

    // ★ 反空真：list 非空却一条 chapterId 都取不到 ⇒ 结构变了
    if episodes.is_empty() && !list.is_empty() {
        return Err(format!(
            "chapter 的 list 有 {} 条但都缺 chapterId ⇒ 结构可能变了：{}",
            list.len(),
            truncate(&list[0].to_string(), 200)
        ));
    }

    Ok(CspDetail {
        id: String::new(),
        title,
        cover,
        description,
        episodes,
    })
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for TingShijie {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let categories = Self::CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        let url = home_url(BASE, Self::CATEGORIES[0].0, 1);
        let body = self.get_text(&url).await?;
        let v = check_envelope(&body, &url)?;
        let items = parse_list(&v, 1)?.items;
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        if !tid.chars().all(|c| c.is_ascii_digit()) {
            return Err(format!("分类 id（categoryId）必须是数字：{tid}"));
        }
        let page = if page == 0 { 1 } else { page };
        let url = home_url(BASE, tid, page);
        let body = self.get_text(&url).await?;
        let v = check_envelope(&body, &url)?;
        parse_list(&v, page)
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("书 id 为空".to_string());
        }
        if !id.chars().all(|c| c.is_ascii_digit()) {
            return Err(format!("书 id（bookId）必须是数字：{id}"));
        }
        let bu = book_url(BASE, id);
        let bb = self.get_text(&bu).await?;
        let book = check_envelope(&bb, &bu)?;

        let cu = chapter_url(BASE, id, 1);
        let cb = self.get_text(&cu).await?;
        let chapters = check_envelope(&cb, &cu)?;

        let mut d = parse_detail(&book, &chapters)?;
        d.id = id.to_string();
        Ok(d)
    }

    /// 取流：DEX 常量里 `chapterId` + `$`（名址分隔）⇒ 取流要**再请求一次**
    /// 用 chapterId 换音频直链 —— 而那个端点**DEX 常量里没有给出**
    ///
    /// ⇒ **如实报错**（不猜端点）。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id（chapterId）为空".to_string());
        }
        Err(format!(
            "csp_TingShijie 的取流端点未确定：DEX 常量给了 book/chapter 两个端点与 \
             `chapterId`+`$` 的拼装常量，但「没有给出'用 chapterId 换音频直链'的那个端点」；\
             且上游当前返回'数据库连接失败'（MySQL 1045）⇒ 无法从响应里反推。\
             不做端点猜测（chapterId={}）。",
            truncate(id, 40)
        ))
    }

    /// DEX 的 11 个方法里「没有」 searchContent ⇒ 如实声明不支持
    fn supports_search(&self) -> bool {
        false
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("csp_TingShijie 不支持搜索（原版 TingShijie 无 searchContent 实现）".to_string())
    }
}

// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，**不改核心注册表**。
//
// # 这个类的事实（别丢）
// ```text
// csp_TingShijie（📢世界｜听书资源）：★ 协议侧完整，**上游数据库挂了**
//   base = https://m.i275.com（从 DEX 的 UA `TingShiJie/1.8.8 (m.i275.com)` 内嵌主机名推得，实测通）
//   路径 = /index.php/<方法>（实测 /index.php/book?bookId=1 通、/book?bookId=1 404）
//   端点（DEX 逐字）：appHomeByCategory?categoryId=&page=&size=120
//                     book?bookId= / chapter?size=1000&page=&sort=asc&bookId=
//   字段（DEX 逐字）：status/data/list/id/bookTitle/bookImage/bookAnchor/bookData/position/chapterId
//   拼装：`#` 分集 · `$` 名址 · `|` 线路 · vod_play_from="世界听书"
// ★ 实测上游：5 次重试里 1 次 200，响应体逐字 =
//     「数据库连接失败: SQLSTATE[HY000] [1045] Access denied for user
//       'app_365ting_com'@'156.238.237.65' (using password: YES)」
//   ⇒ **上游自己的 MySQL 凭据失效**（不是我们请求写错）
// ⇒ 交付形态：协议侧完整可跑，**数据侧如实标"上游死"**；失败信息**原样暴露上游原文**
// ★ 我先前报"真路径不在常量里、需要单类源码" —— **已自我更正**（端点全在常量里，
//   只是要**按方法分组**读才看得见；请把那条源码请求撤掉）
// ⚠️ 取流端点 DEX 没给 ⇒ 如实报错不猜
// ⚠️ 已知缺口：原版有 mProxy，本批不做
// ```
crate::csp::register_site!(TingShijie);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// 列表响应**形态**夹具（字段名逐字来自 DEX 常量；值是我造的占位，
    /// 因为上游当前给不出真数据 —— **如实标注**：这不是"真响应片段"）
    const FIX_LIST: &str = r#"{
      "status": true,
      "data": {"list": [
        {"id": 101, "bookTitle": "某听书", "bookImage": "https://cdn.example/a.jpg",
         "bookAnchor": "某主播"},
        {"id": 102, "bookTitle": "另一部", "bookAnchor": ""}
      ], "page": 1, "pagecount": 3, "limit": 120, "total": 260}
    }"#;

    const FIX_BOOK: &str = r#"{
      "status": true,
      "data": {"bookData": {"bookTitle": "某听书", "bookDesc": "简介……",
               "bookImage": "https://cdn.example/a.jpg", "count": 2}}
    }"#;

    const FIX_CHAPTER: &str = r#"{
      "status": true,
      "data": {"list": [{"position": 1, "chapterId": 9001}, {"position": 2, "chapterId": 9002}]}
    }"#;

    /// ★ 上游**当前真实**的响应体（逐字，MySQL 1045）—— 用于证明我们的错误信息会原样暴露它
    const FIX_UPSTREAM_DB_ERROR: &str =
        "数据库连接失败: SQLSTATE[HY000] [1045] Access denied for user \
         'app_365ting_com'@'156.238.237.65' (using password: YES)";

    fn j(s: &str) -> serde_json::Value {
        serde_json::from_str(s).expect("夹具必须是合法 JSON")
    }

    // ── ★ 端点模板逐字来自 DEX ────────────────────────────────────

    #[test]
    fn urls_match_dex_templates() {
        assert_eq!(
            home_url(BASE, "1", 1),
            "https://m.i275.com/index.php/appHomeByCategory?categoryId=1&page=1&size=120"
        );
        assert_eq!(book_url(BASE, "101"), "https://m.i275.com/index.php/book?bookId=101");
        assert_eq!(
            chapter_url(BASE, "101", 1),
            "https://m.i275.com/index.php/chapter?size=1000&page=1&sort=asc&bookId=101"
        );
        // page=0 归一成 1
        assert_eq!(home_url(BASE, "1", 0), home_url(BASE, "1", 1));
    }

    #[test]
    /// ★ 必须带 `index.php` 前缀（实测 `/<方法>` 是 404，`/index.php/<方法>` 通）
    ///
    /// 注入：把 `PATH_PREFIX` 改成 "" ⇒ 本条红。
    fn urls_carry_index_php_prefix() {
        assert_eq!(PATH_PREFIX, "/index.php");
        assert!(home_url(BASE, "1", 1).contains("/index.php/appHomeByCategory"));
        assert!(book_url(BASE, "1").contains("/index.php/book"));
        assert!(chapter_url(BASE, "1", 1).contains("/index.php/chapter"));
    }

    // ── ★ 上游是"数据库连接失败"：错误信息必须原样暴露它 ─────────

    #[test]
    /// ★★ 本条钉住"上游原文必须被原样带出"（而不是被我们包装成"结构可能变了"）
    ///
    /// 注入：把 `check_envelope` 里那条"不是 JSON"的 Err 改成返回 `Ok(空 JSON)` ⇒ 本条红。
    fn upstream_db_error_is_surfaced_verbatim() {
        let err = check_envelope(FIX_UPSTREAM_DB_ERROR, "https://m.i275.com/x").unwrap_err();
        assert!(err.contains("不是 JSON"), "要点出'不是 JSON'：{err}");
        assert!(
            err.contains("数据库连接失败"),
            "★ 上游的逐字原文必须带出来（否则我们会把它误报成'结构变了'）：{err}"
        );
        assert!(
            err.contains("1045"),
            "★ MySQL 错误码要带出来（1045=凭据被拒，说明是上游自己挂了）：{err}"
        );
    }

    #[test]
    /// 佐证：这条错误**不是**我们请求写错 —— 它提到的是**上游自己的库名与连接用户**
    fn upstream_error_names_its_own_database() {
        assert!(FIX_UPSTREAM_DB_ERROR.contains("app_365ting_com"), "上游自己的库名");
        assert!(
            FIX_UPSTREAM_DB_ERROR.contains("using password: YES"),
            "原文里那句'用了密码却被拒'要带出来（这正是'上游凭据失效'的特征）：{}",
            FIX_UPSTREAM_DB_ERROR
        );
        assert!(
            !FIX_UPSTREAM_DB_ERROR.contains("参数错误") && !FIX_UPSTREAM_DB_ERROR.contains("非法请求"),
            "★ 对照：它不是'参数错/非法请求'这类'我们请求写错'的错误"
        );
    }

    // ── check_envelope ───────────────────────────────────────────

    #[test]
    fn envelope_accepts_truthy_status() {
        for body in [
            r#"{"status":true,"data":{"list":[]}}"#,
            r#"{"status":1,"data":{"list":[]}}"#,
            r#"{"status":"1","data":{"list":[]}}"#,
        ] {
            assert!(check_envelope(body, "u").is_ok(), "应接受：{body}");
        }
    }

    #[test]
    /// ★ status 为假值 ⇒ 报上游业务失败（并带出 data）
    fn envelope_rejects_falsy_status() {
        for (body, want) in [
            (r#"{"status":false,"data":"某错"}"#, "status 为假值"),
            (r#"{"status":0,"data":{}}"#, "status 为假值"),
            (r#"{"status":"","data":{}}"#, "status 为假值"),
        ] {
            let err = check_envelope(body, "u").unwrap_err();
            assert!(err.contains(want), "{err}");
        }
    }

    #[test]
    fn envelope_rejects_missing_status() {
        let err = check_envelope(r#"{"data":{}}"#, "u").unwrap_err();
        assert!(err.contains("缺少 status"), "{err}");
    }

    // ── parse_list ────────────────────────────────────────────────

    #[test]
    fn list_maps_dex_field_names() {
        let l = parse_list(&j(FIX_LIST), 1).expect("夹具必须解析得出来");
        assert_eq!(l.items.len(), 2);
        assert_eq!(l.items[0].id, "101", "数字 id 收成字符串");
        assert_eq!(l.items[0].title, "某听书", "标题来自 bookTitle");
        assert_eq!(l.items[0].cover.as_deref(), Some("https://cdn.example/a.jpg"), "封面来自 bookImage");
        assert_eq!(l.items[0].subtitle.as_deref(), Some("某主播"), "副标题来自 bookAnchor");
        assert_eq!(l.items[1].cover, None, "空 bookImage 要 None");
        assert_eq!(l.items[1].subtitle, None, "空 bookAnchor 要 None");
        assert_eq!(l.page_count, Some(3));
        assert_eq!(l.total, Some(260));
    }

    #[test]
    /// ★ 反空真 ①：list 非空却都缺 id ⇒ 报错
    fn list_with_unmappable_rows_is_error() {
        let bad = j(r#"{"status":true,"data":{"list":[{"bookTitle":"无 id"}]}}"#);
        let err = parse_list(&bad, 1).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// ★ 反空真 ②（成对）：list **真为空数组** ⇒ 正常
    fn list_with_genuinely_empty_array_is_ok() {
        let v = j(r#"{"status":true,"data":{"list":[],"total":0}}"#);
        let l = parse_list(&v, 1).expect("真·空列表不是错误");
        assert!(l.items.is_empty());
    }

    #[test]
    fn list_without_data_list_is_error() {
        let err = parse_list(&j(r#"{"status":true,"data":{}}"#), 1).unwrap_err();
        assert!(err.contains("没有 list"), "{err}");
    }

    // ── parse_detail ──────────────────────────────────────────────

    #[test]
    fn detail_maps_book_and_chapters() {
        let d = parse_detail(&j(FIX_BOOK), &j(FIX_CHAPTER)).expect("夹具必须解析得出来");
        assert_eq!(d.title, "某听书");
        assert_eq!(d.cover.as_deref(), Some("https://cdn.example/a.jpg"));
        assert!(d.description.as_deref().unwrap_or("").contains("简介"));
        assert_eq!(d.episodes.len(), 2, "两章");
        assert_eq!(d.episodes[0].id, "9001", "chapterId → CspEpisode.id");
        assert_eq!(d.episodes[0].title, "第 1 章", "position → 章标题");
        assert_eq!(d.episodes[0].flag, "世界听书", "DEX 的 vod_play_from");
    }

    #[test]
    /// ★ 反空真 ③：chapter.list 非空却都缺 chapterId ⇒ 报错
    fn detail_with_chapters_but_no_ids_is_error() {
        let bad = j(r#"{"status":true,"data":{"list":[{"position":1}]}}"#);
        let err = parse_detail(&j(FIX_BOOK), &bad).unwrap_err();
        assert!(err.contains("结构可能变了"), "{err}");
    }

    #[test]
    /// ★ 反空真 ④（成对）：chapter.list 真空 ⇒ 正常（无章节）
    fn detail_with_empty_chapters_is_ok() {
        let v = j(r#"{"status":true,"data":{"list":[]}}"#);
        let d = parse_detail(&j(FIX_BOOK), &v).expect("真·无章节不是错误");
        assert!(d.episodes.is_empty());
        assert_eq!(d.title, "某听书");
    }

    #[test]
    fn detail_without_book_title_is_error() {
        let bad = j(r#"{"status":true,"data":{"bookData":{"bookDesc":"x"}}}"#);
        let err = parse_detail(&bad, &j(FIX_CHAPTER)).unwrap_err();
        assert!(err.contains("没有 bookTitle"), "{err}");
    }

    #[test]
    fn detail_without_book_data_is_error() {
        let err = parse_detail(&j(r#"{"status":true,"data":{}}"#), &j(FIX_CHAPTER)).unwrap_err();
        assert!(err.contains("没有 data.bookData"), "{err}");
    }

    // ── 边界 / 能力位 ─────────────────────────────────────────────

    #[test]
    fn search_is_declared_unsupported() {
        assert!(!TingShijie::new().supports_search(), "★ DEX 里没有 searchContent");
    }

    #[tokio::test]
    async fn search_returns_honest_error() {
        let err = TingShijie::new().search("红", 1, "").await.unwrap_err();
        assert!(err.contains("不支持搜索"), "{err}");
    }

    #[tokio::test]
    async fn list_rejects_non_numeric_category() {
        let err = TingShijie::new().list("abc", 1, "").await.unwrap_err();
        assert!(err.contains("必须是数字"), "{err}");
    }

    #[tokio::test]
    async fn list_rejects_empty_category() {
        let err = TingShijie::new().list("  ", 1, "").await.unwrap_err();
        assert!(err.contains("分类 id 为空"), "{err}");
    }

    #[tokio::test]
    async fn detail_rejects_non_numeric_book_id() {
        let err = TingShijie::new().detail("x/../etc", "").await.unwrap_err();
        assert!(err.contains("必须是数字"), "{err}");
    }

    #[tokio::test]
    /// ★ play **如实报错**：DEX 未给"chapterId→音频直链"的端点 ⇒ 不猜
    async fn play_reports_honestly_unimplemented() {
        let err = TingShijie::new().play("世界听书", "9001", "").await.unwrap_err();
        assert!(err.contains("取流端点未确定"), "{err}");
        assert!(err.contains("不做端点猜测"), "要声明不猜端点：{err}");
    }

    #[tokio::test]
    async fn play_rejects_empty_id() {
        let err = TingShijie::new().play("世界听书", "  ", "").await.unwrap_err();
        assert!(err.contains("播放 id"), "{err}");
    }

    // ── 真网络（默认不跑；显式跑必须给 CSP_LIVE=1）──

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib ting_shijie_live -- --ignored --nocapture"]
    async fn ting_shijie_live_reports_upstream_state_verbatim() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = TingShijie::new();
        let url = home_url(BASE, "1", 1);

        // ★ 本类的 live 用例**不假装成功**：它把上游当前状态**原样**报出来。
        //   上游有两个已知状态：① 数据库连接失败（MySQL 1045）② TLS 握手超时。
        //   ⇒ 无论哪种，都要**打印逐字证据**，让"上游一恢复"这件事能被立刻发现。
        let body = s.get_text(&url).await;
        match body {
            Err(e) => {
                println!("LIVE 上游不可达：{e}");
                println!("      （历史读数：5 次重试里 4 次 TLS 握手超时 ⇒ 上游在抖）");
            }
            Ok(b) => match check_envelope(&b, &url) {
                Ok(v) => {
                    println!("✅ LIVE 上游**已恢复**并返回合法 JSON ⇒ 数据侧打通了！");
                    let l = parse_list(&v, 1).expect("合法 JSON 必须能解析");
                    assert!(!l.items.is_empty(), "★ 反空真：上游恢复后列表不能空");
                    println!("LIVE home：{} 条，首条={}", l.items.len(), l.items[0].title);
                }
                Err(e) => {
                    println!("LIVE 上游仍不可用（如实打印，**不算我们的 bug**）：");
                    println!("      {e}");
                    assert!(
                        e.contains("不是 JSON") || e.contains("status"),
                        "错误信息必须可分类（不是 JSON / status 问题）：{e}"
                    );
                }
            },
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
        let src = crate::csp::shared::impl_src_only(include_str!("ting_shijie.rs"));
        assert!(
            src.contains(".no_proxy()"),
            "★ Client 构造链必须含 `.no_proxy()`（不读系统代理）；             否则装了代理的机器上会把'站点可用'测成'全宕'"
        );
    }
}

#[cfg(test)]
#[path = "ting_shijie_proxy_tests.rs"]
mod proxy_tests;
