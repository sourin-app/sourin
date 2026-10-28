// ═══════════════════════════════════════════════════════════════════════
//  csp_PanAli —— 网盘族：列出「我的盘」目录（POST + marker 分页）
// ═══════════════════════════════════════════════════════════════════════
//
// # 语义（与影视站不同）
//
// ```text
// 网盘 csp 没有"站点首页"：它列的是**用户自己账号里的文件**。
//   home = 一个货架；list = 某目录下的条目；detail = 把文件包装成"1 集"；
//   play = 该文件的直链（本类**未接通**，原因见下）。
// ⇒ 订阅里 `"searchable":0 / "changeable":0`。
// ```
//
// # 取证来源（DEX 常量逐字，**没用 jadx**）
//
// ```text
// .probe/csp-parity/PanAli.txt
//   首页（逐字）：[{"name":"我的<盘>","folders":[{"shareId":"","folder":"root"}]}]
//                 ⇒ **根目录 id 有逐字证据 = "root"**（比"惯例猜测"强）
//   列目录（方法 b）：POST 端点 + **请求体七个键**
//                 drive_id / limit / parent_file_id / order_by / name_enhanced
//                 order_direction / ASC / category / video / marker
//                 头：Authorization
//                 业务错码：AccessTokenExpired / AccessTokenInvalid / TokenVerifyFailed
//                 条目种类比较常量："folder" / "file"（⇒ 响应里种类字段的值就是这两个串）
//   逐字登录提示："还未登录阿里账号,请前往【配置中心】登录"
// ```
//
// # ★★ 真网读数（`.probe/parity-pan-a-live.log`，直连无代理无账号）—— 这条**改正了 DEX 读不出的东西**
//
// ```text
// ① 用 GET 打列目录端点 ⇒ HTTP 400
//      {"code":"HttpRequestMethodNotSupportedException","message":"Request method 'GET' not supported",…}
//    ⇒ **证实这个端点只吃 POST**。DEX 常量只给出"端点 + 体里的键"，
//      **看不出方法**（方法在字节码里，不在字面量里）⇒ 这条只能靠真网证。
// ② 用 POST + 空 token ⇒ HTTP 401 {"code":"AccessTokenInvalid","message":"access token is blank",…}
//    ⇒ 与 DEX 的错码表**逐字对上**（AccessTokenInvalid），且证明"没 token 时报的是它"。
// ```
//   两条读数都已作为**真实夹具**进测试。
//
// # ⚠️ 诚实边界（逐条）
//
// ```text
// 1. 需要账号 access token。无 token ⇒ home/list/detail/play 都如实报登录（逐字文案）。
// 2. `Authorization` 头的**值前缀未取证**（DEX 只给出头名）⇒ 按通用形态 `Bearer <token>`，
//    并做容错：token 里已经带前缀就原样用（避免出现 `Bearer Bearer …` 这种静默失败）。
// 3. `drive_id` **不在本类字面量里**（请求体键在、值不在）⇒ 只能从 ext 取；
//    没有就传空串 ⇒ 上游会报错 ⇒ 我们把它变成一句可读 Err（不猜一个 id 出来）。
// 4. 响应里的条目 id 字段 `file_id` **不在本类字面量里**：
//    同 jar 的相邻助手类（阿里一家）反复使用 `file_id` / `drive_id` / `parent_file_id`
//    与 `openFile/getDownloadUrl` ⇒ 属**跨类取证**，这里按它解析，并标注未在真账号下跑通。
// 5. **取址未实现**：本类里**没有**取址端点（只有列目录端点）。同 jar 相邻类里有
//    `openFile/getDownloadUrl`，但它在别处、且响应形状未取证 ⇒ 按"不猜"的纪律不接。
//    ⇒ play 一律给出可读 Err（不伪造地址、不把分享页当视频流）。
// 6. marker 分页：`marker` 是**不透明游标**，没有上一页的 `next_marker` 就取不到下一页
//    ⇒ 本实现只取第一页；第一页没满 ⇒ `page_count = 1`，UI 不会来要第二页；
//    真要第二页时**如实报错**（而不是把第一页再返回一次 —— 那会让用户翻页翻不动却看不出来）。
// 7. 原版这一族的播放靠它自己起的本地转发服务（基类里逐字 `127.0.0.1:5266`）；
//    本仓等价物 `streamproxy::register(url, headers)`，本批未接通，类里**不自己起服务**。
// ```
//
// # 为什么 `supports_search() == false`
//
// ```text
// 订阅 `"searchable":0` ⇒ 返 true 会让 registry 把它拉进搜索，
// 用户每次搜索都多打一轮**注定失败**的请求。
// ```

use std::time::Duration;

use async_trait::async_trait;

use crate::pan::PanKind;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

/// 接口 UA（同族共用一条浏览器串；逐字取 DEX `[head]` 那条）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 无登录态时的提示 —— **逐字**取参考实现
const LOGIN_HINT: &str = "还未登录阿里账号,请前往【配置中心】登录";

/// 首页货架名 —— **逐字**取参考实现首页常量里的 name
const SHELF_NAME: &str = "我的阿里云盘";

/// 列目录端点（逐字）
const LIST_ENDPOINT: &str = "https://openapi.alipan.com/adrive/v1.0/openFile/list";

/// 根目录 id —— **逐字**取首页常量 `{"folder":"root"}`（这条不是猜的）
const ROOT_FOLDER: &str = "root";

/// 每页条数（DEX 里 `limit` 是请求体键，值是拼接位 ⇒ 保守值）
const PAGE_LIMIT: u32 = 100;

/// 条目种类 —— 响应里的取值**逐字**是这两个串（DEX 里就是拿它们比较的）
const KIND_FOLDER: &str = "folder";
const KIND_FILE: &str = "file";

/// 响应里的种类字段 → 三态
///
/// ★ 为什么留 `Other`：响应若出现第三种值（改版/新类型），
///   把它折成"文件"会让用户点了去播（得到一句 Err，但很意外）；
///   折成"目录"会让用户钻进一个文件。⇒ 显式第三态，UI 只显示、不宣称可播。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Folder,
    File,
    Other,
}

fn kind_of(s: &str) -> Kind {
    if s.eq_ignore_ascii_case(KIND_FOLDER) {
        Kind::Folder
    } else if s.eq_ignore_ascii_case(KIND_FILE) {
        Kind::File
    } else {
        Kind::Other
    }
}

/// 网盘里的一个条目
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// 条目 id（跨类取证的字段名 `file_id`，见文件头第 4 条）
    pub file_id: String,
    pub name: String,
    /// true = 目录（响应里 `type` == "folder"）
    pub is_dir: bool,
    pub size: u64,
    /// 更新时间（有的响应带；没有就空 —— 不编）
    pub updated_at: String,
}

/// `csp_PanAli`
pub struct PanAli {
    client: reqwest::Client,
}

impl PanAli {
    pub const CLASS: &'static str = "PanAli";

    pub fn new() -> Self {
        // ★ no_proxy 在 timeout 之后、build 之前；用 expect（`unwrap_or_else(Client::new)`
        //   会悄悄丢掉 no_proxy）；凭据每次现读，不缓存。
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("build pan_ali http client");
        Self { client }
    }

    /// 账号 access token（本仓凭据位只有 `cookie` 一个字符串字段，值语义是 token）
    fn token() -> Option<String> {
        crate::pan_auth::load(PanKind::Aliyun)
            .map(|c| c.cookie.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    /// `Authorization` 头（容错：token 已带前缀就原样用）
    fn auth_header(token: &str) -> String {
        if token.to_ascii_lowercase().starts_with("bearer ") {
            token.to_string()
        } else {
            format!("Bearer {token}")
        }
    }

    /// `drive_id`：**只能**从 ext 取（本类字面量里没有值）
    pub fn drive_id(ext: &str) -> String {
        ext_json(ext)
            .and_then(|j| {
                j.get("drive_id")
                    .or_else(|| j.get("driveId"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim().to_string())
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_default()
    }

    /// 根目录 id（ext 可覆盖：别人的盘/共享目录根可能不是 "root"）
    pub fn root_folder(ext: &str) -> String {
        ext_json(ext)
            .and_then(|j| {
                j.get("folder")
                    .or_else(|| j.get("root"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim().to_string())
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| ROOT_FOLDER.to_string())
    }

    /// POST 一次并返回原文（JSON 解析交给纯函数）
    async fn post_text(&self, token: &str, body: &serde_json::Value) -> Result<String, String> {
        let resp = self
            .client
            // ★ 必须 POST：GET 实测 400 `HttpRequestMethodNotSupportedException`
            .post(LIST_ENDPOINT)
            .header("Authorization", Self::auth_header(token))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/plain, */*")
            .json(body)
            .send()
            .await
            .map_err(|e| format!("阿里 请求失败：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        ensure_json_body(&text, status.as_u16())?;
        if !status.is_success() {
            // ★ 上游的业务错码（AccessTokenExpired 等）就在 body 里 ⇒ 带出来，别只报状态码
            return Err(format!("阿里 返回 HTTP {status}：{}", business_reason(&text)));
        }
        Ok(text)
    }
}

#[async_trait]
impl CspSite for PanAli {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        if Self::token().is_none() {
            // ★ 无 token ⇒ 如实报登录，**不返回空首页**
            return Err(LOGIN_HINT.to_string());
        }
        Ok(CspHome {
            categories: vec![CspCategory {
                id: Self::root_folder(ext),
                name: SHELF_NAME.to_string(),
            }],
            items: Vec::new(),
        })
    }

    /// 列表：`tid` = 目录 id（空 ⇒ 根）
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let Some(token) = Self::token() else {
            return Err(LOGIN_HINT.to_string());
        };
        let parent = if tid.trim().is_empty() {
            Self::root_folder(ext)
        } else {
            tid.trim().to_string()
        };
        let page = if page == 0 { 1 } else { page };
        if page > 1 {
            // ★ 不假装能翻页：marker 是不透明游标，没有上一页的 next_marker 就取不到。
            //   若这里把第一页再返一次，用户会"翻页翻不动但看不出来"（静默错）。
            return Err(format!(
                "阿里 的列表用 marker 游标分页，第 {page} 页需要上一页返回的 next_marker；\
                 本实现只取第一页（未接通增量）⇒ 不重复返回第一页冒充第二页"
            ));
        }
        let body = list_body(&Self::drive_id(ext), &parent, PAGE_LIMIT, "");
        let text = self.post_text(&token, &body).await?;
        let v = parse_json(&text)?;
        let entries = parse_entries(&v)?;
        let n = entries.len();
        let items = entries.iter().map(item_of).collect();
        Ok(CspList {
            items,
            page,
            // 不满一页 ⇒ 明确"只有一页"，UI 不必来要第二页（否则会撞上面那条 Err）
            page_count: if n < PAGE_LIMIT as usize { Some(1) } else { None },
            total: None,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        if Self::token().is_none() {
            return Err(LOGIN_HINT.to_string());
        }
        Ok(CspDetail {
            id: id.to_string(),
            title: id.to_string(),
            cover: None,
            description: None,
            episodes: vec![CspEpisode {
                id: id.to_string(),
                title: "播放".to_string(),
                flag: "默认".to_string(),
            }],
        })
    }

    fn supports_search(&self) -> bool {
        false
    }
    /// ★ 2026-10-28（Owner：「要逐类标注」）：本类**不填 ext 不能用**
    ///
    /// 依据：未登录必然 Err（真网读数：401 AccessTokenInvalid）
    /// ⇒ 默认不自动暴露（用户导入带 ext 的站点时照常出现）。
    fn needs_ext(&self) -> bool {
        true
    }


    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("阿里 不支持搜索（它只列出你自己账号里的目录）".to_string())
    }

    /// 取播放地址 —— **本类没有取址端点**，如实报未接通
    ///
    /// ```text
    /// 本类字面量里只有列目录端点；取址端点在同 jar 的**别的类**里
    /// （`openFile/getDownloadUrl`），且它的响应形状没有取证到
    ///   ⇒ 按"不猜协议"的纪律：**不接、不伪造地址**。
    /// ★ 为什么不"顺手拼一个直链"：拼错不会报错，只会让用户点进去 404
    ///   （比"明确说没接通"更糟：它看起来像"这个文件坏了"）。
    /// ```
    async fn play(&self, _flag: &str, _id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        if Self::token().is_none() {
            return Err(LOGIN_HINT.to_string());
        }
        Err("阿里 的取流链路尚未接通：本类里只有列目录端点，取址端点（openFile/getDownloadUrl）\
             在参考实现的相邻类里且响应形状未取证 ⇒ 不猜协议、不伪造地址"
            .to_string())
    }
}

/// 列目录请求体（**纯函数** —— 抽出来才能断言"七个键逐字"）
///
/// # 为什么要逐字钉住请求体
/// ```text
/// 少一个键 / 值写错**不会报错**：上游照样 200，只是结果集不同
/// （比如 order_by 写错 ⇒ 顺序乱；category 写错 ⇒ 少一类文件）⇒ 属"静默错"。
/// ⇒ 用纯函数 + 断言键集合与值，比"能发出去"强得多。
/// ```
fn list_body(drive_id: &str, parent: &str, limit: u32, marker: &str) -> serde_json::Value {
    serde_json::json!({
        "drive_id": drive_id,
        "limit": limit,
        "parent_file_id": parent,
        "order_by": "name_enhanced",
        "order_direction": "ASC",
        "category": "video",
        "marker": marker,
    })
}

fn parse_json(body: &str) -> Result<serde_json::Value, String> {
    crate::tvbox::parse_loose_json(body)
        .map_err(|e| format!("阿里 返回的不是 JSON（{e}）：{}", short(body)))
}

/// 非 JSON / 空体 / HTML 拦截页的统一前置判定
fn ensure_json_body(body: &str, http: u16) -> Result<(), String> {
    let t = body.trim_start();
    if t.starts_with('<') {
        return Err(format!(
            "阿里 返回的是 HTML（HTTP {http}），不是 JSON —— 多半是 CDN/WAF 拦截页或改版壳页：{}",
            short(body)
        ));
    }
    if t.is_empty() {
        return Err(format!("阿里 返回空响应体（HTTP {http}）"));
    }
    Ok(())
}

/// 把上游的业务错码/原因摘出来（**不是**给人看的整段 JSON）
///
/// 三个错码逐字取 DEX：`AccessTokenExpired` / `AccessTokenInvalid` / `TokenVerifyFailed`
/// ⇒ 它们的共同含义是"凭据不行"，文案里必须点到"重新登录"，否则用户会去查网络。
fn business_reason(body: &str) -> String {
    let Ok(v) = crate::tvbox::parse_loose_json(body) else {
        return short(body);
    };
    let code = v.get("code").and_then(|x| x.as_str()).unwrap_or("");
    let msg = v
        .get("message")
        .or_else(|| v.get("display_message"))
        .and_then(|x| x.as_str())
        .unwrap_or("");
    let need_login = matches!(
        code,
        "AccessTokenExpired" | "AccessTokenInvalid" | "TokenVerifyFailed"
    );
    let body_txt = if msg.is_empty() {
        short(body)
    } else {
        format!("{msg}（{code}）")
    };
    if need_login {
        format!("{body_txt} ⇒ 凭据失效/未授权，请在【配置中心】重新登录")
    } else {
        body_txt
    }
}

/// 从响应里抽条目（**纯函数**；0 条 ⇒ `Err`）
fn parse_entries(v: &serde_json::Value) -> Result<Vec<Entry>, String> {
    let arr = v
        .get("items")
        .or_else(|| v.get("file_list"))
        .and_then(|x| x.as_array());
    let Some(arr) = arr else {
        return Err(format!(
            "阿里 列目录响应里没有 items 数组（可能改版/风控壳页）：{}",
            short(&v.to_string())
        ));
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let file_id = str_of(it, &["file_id", "fileId"]);
        if file_id.is_empty() {
            // 没 id 的条目拿去详情/钻目录只会失败 ⇒ 丢掉，而不是编一个
            continue;
        }
        out.push(Entry {
            file_id,
            name: str_of(it, &["name", "file_name"]),
            // ★ 种类取值逐字是 "folder" / "file"（DEX 里就是拿这两个串比较的）
            is_dir: kind_of(&str_of(it, &["type"])) == Kind::Folder,
            size: u64_of(it, &["size", "file_size"]),
            updated_at: str_of(it, &["updated_at", "update_at"]),
        });
    }
    if out.is_empty() {
        return Err(format!(
            "阿里 列目录解析出 0 条（可能改版/风控壳页，也可能是空目录）：{}",
            short(&v.to_string())
        ));
    }
    Ok(out)
}

/// 条目 → UI 一行
///
/// ★ 目录 id 直接用它自己的 `file_id`（UI 拿它当 tid 继续钻）；
///   文件 id 也用 `file_id`（取址未接通，所以不需要再编参数串 —— 少编一层少一层错）。
fn item_of(e: &Entry) -> CspItem {
    CspItem {
        id: e.file_id.clone(),
        title: e.name.clone(),
        cover: None,
        subtitle: Some(if e.is_dir {
            "目录".to_string()
        } else {
            human_size(e.size)
        }),
    }
}

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

fn short(s: &str) -> String {
    let t = s.trim();
    let max = 180;
    let cut = t.char_indices().nth(max).map(|(i, _)| i).unwrap_or(t.len());
    if cut == t.len() {
        return t.to_string();
    }
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

fn ext_json(ext: &str) -> Option<serde_json::Value> {
    if ext.trim().is_empty() {
        return None;
    }
    crate::tvbox::parse_loose_json(ext).ok()
}

crate::csp::register_site!(PanAli);

#[cfg(test)]
mod tests {
    use super::*;

    /// **真实响应片段①**（直连实测）：GET 打列目录端点 ⇒ 400 + 方法不支持
    ///
    /// 价值：DEX 常量里**看不出方法**（方法在字节码里），这条读数把"必须 POST"钉死。
    const LIVE_GET_400: &str = r#"{"code":"HttpRequestMethodNotSupportedException","message":"Request method 'GET' not supported","data":null,"headers":null,"requestId":"0a00a0fb17931441198512683e48ae","pdsRequestId":null,"resultCode":"HttpRequestMethodNotSupportedException","display_message":null}"#;

    /// **真实响应片段②**（直连实测）：POST + 空 token ⇒ 401 + AccessTokenInvalid
    const LIVE_POST_401: &str = r#"{"code":"AccessTokenInvalid","message":"access token is blank","data":null,"headers":null,"requestId":"0a00601717931441200404175ebbe1","pdsRequestId":null,"resultCode":"AccessTokenInvalid","display_message":null}"#;

    /// **不是真网响应**：按 DEX 的 `folder`/`file` 取值 + 跨类取证的 `file_id` 还原
    const DEX_SHAPE_OK: &str = r#"{"items":[
        {"file_id":"f1","name":"第一集.mp4","type":"file","size":"734003200","updated_at":"2026-10-01T10:00:00Z"},
        {"file_id":"d1","name":"剧集目录","type":"folder","size":0},
        {"name":"没有 id 的行","type":"file"}
    ],"next_marker":""}"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(PanAli::CLASS, "PanAli");
    }

    #[test]
    fn registration_is_present() {
        assert!(
            crate::csp::is_implemented("csp_PanAli"),
            "★ csp_PanAli 必须在注册表里（有 host 常量 + 订阅有站）"
        );
        let s = crate::csp::route("csp_PanAli").expect("必须能路由出实例");
        assert_eq!(s.class(), "PanAli");
        assert!(!s.supports_search());
    }

    #[test]
    fn visible_wording_matches_reference() {
        assert_eq!(LOGIN_HINT, "还未登录阿里账号,请前往【配置中心】登录");
        assert_eq!(SHELF_NAME, "我的阿里云盘");
        for s in [LOGIN_HINT, SHELF_NAME] {
            assert!(!s.contains("**"), "★ 用户可见文案不许有 markdown 强调：{s}");
        }
        // 根目录 id 有逐字证据（首页常量里的 "folder":"root"）
        assert_eq!(ROOT_FOLDER, "root");
    }

    /// ★★ 真网读数：GET 会被 400 拒 ⇒ 代码里**必须**是 POST
    ///
    /// ```text
    /// 注入验证：把 `.post(LIST_ENDPOINT)` 改成 `.get(LIST_ENDPOINT)` ⇒ 本条红。
    /// （注意：改错了**编译不报错**，只有这条结构性判据能抓 —— 而线上表现是全部 400。）
    /// ```
    #[test]
    fn list_uses_post_because_get_is_rejected() {
        let flat = crate::csp::shared::impl_src_only(include_str!("pan_ali.rs"));
        assert!(
            flat.contains(".post(LIST_ENDPOINT)"),
            "★ 列目录必须是 POST（GET 实测 400 HttpRequestMethodNotSupportedException）"
        );
        assert!(
            !flat.contains(".get(LIST_ENDPOINT)"),
            "★ 不许用 GET 打列目录端点（实测 400）"
        );
        // 反空真：真网读数本身也在测试里，且它确实是"方法不支持"那条
        assert!(LIVE_GET_400.contains("HttpRequestMethodNotSupportedException"));
    }

    /// ★★ 请求体七个键逐字（少一个 / 值错都不会报错，只会结果不对）
    #[test]
    fn list_body_has_exactly_the_reference_keys() {
        let b = list_body("d9", "root", 100, "");
        for k in [
            "drive_id",
            "limit",
            "parent_file_id",
            "order_by",
            "order_direction",
            "category",
            "marker",
        ] {
            assert!(b.get(k).is_some(), "★ 缺键 {k}：{b}");
        }
        assert_eq!(b.as_object().unwrap().len(), 7, "★ 键数必须正好 7（多了也是偏离）：{b}");
        assert_eq!(b["order_by"], "name_enhanced");
        assert_eq!(b["order_direction"], "ASC");
        assert_eq!(b["category"], "video");
        assert_eq!(b["parent_file_id"], "root");
        assert_eq!(b["drive_id"], "d9");
        // 反空真：参数必须真的进体
        let b2 = list_body("", "abc", 7, "m1");
        assert_eq!(b2["parent_file_id"], "abc");
        assert_eq!(b2["limit"], 7);
        assert_eq!(b2["marker"], "m1");
    }

    /// ★★ 真网读数：401 + AccessTokenInvalid ⇒ 文案必须点"重新登录"（不是"网络错误"）
    #[test]
    fn token_errors_tell_user_to_relogin() {
        for body in [LIVE_POST_401, r#"{"code":"AccessTokenExpired","message":"expired"}"#] {
            let r = business_reason(body);
            assert!(
                r.contains("重新登录"),
                "★ 凭据类错码必须指向「重新登录」这个动作：{r}"
            );
        }
        // 非凭据类错误 ⇒ 原样带出来，且不许乱说"重新登录"
        let r = business_reason(r#"{"code":"NotFound","message":"file not found"}"#);
        assert!(r.contains("file not found"), "{r}");
        assert!(!r.contains("重新登录"), "★ 别把所有错误都说成登录问题：{r}");
        // 非 JSON ⇒ 退化成摘要，不 panic
        assert!(!business_reason("oops").is_empty());
    }

    #[test]
    fn auth_header_never_double_prefixes() {
        assert_eq!(PanAli::auth_header("tok"), "Bearer tok");
        assert_eq!(PanAli::auth_header("Bearer tok"), "Bearer tok");
        assert_eq!(PanAli::auth_header("bearer tok"), "bearer tok");
    }

    #[test]
    fn drive_id_and_root_only_come_from_ext() {
        // ★ drive_id 在本类字面量里**没有值** ⇒ 只能从 ext 取；没有就空串（不猜）
        assert_eq!(PanAli::drive_id(""), "");
        assert_eq!(PanAli::drive_id(r#"{"drive_id":" 888 "}"#), "888");
        assert_eq!(PanAli::drive_id(r#"{"driveId":"999"}"#), "999");
        // 根目录：默认逐字 "root"
        assert_eq!(PanAli::root_folder(""), "root");
        assert_eq!(PanAli::root_folder(r#"{"folder":"f_abc"}"#), "f_abc");
        assert_eq!(PanAli::root_folder("坏"), "root");
    }

    /// ★★ DEX 种类常量门禁：只有 "folder" 是目录，"file" 不是
    #[test]
    fn parse_entries_reads_kind_strings() {
        let v = parse_json(DEX_SHAPE_OK).unwrap();
        let e = parse_entries(&v).unwrap();
        assert_eq!(e.len(), 2, "★ 没 id 的行必须丢掉");
        assert_eq!(e[0].file_id, "f1");
        assert!(!e[0].is_dir, "★ type=file ⇒ 不是目录");
        assert!(
            kind_of("file") == Kind::File && kind_of("folder") == Kind::Folder,
            "★ 种类串必须按 DEX 的两个取值判"
        );
        assert_eq!(kind_of("FILE"), Kind::File, "★ 大小写不该影响判定");
        assert_eq!(kind_of(""), Kind::Other, "★ 看不懂的种类不许折成文件或目录");
        assert_eq!(kind_of("zip"), Kind::Other);
        assert_eq!(e[0].size, 734003200, "★ size 是字符串也要能读");
        assert_eq!(e[0].updated_at, "2026-10-01T10:00:00Z");
        assert_eq!(e[1].file_id, "d1");
        assert!(e[1].is_dir, "★ type=folder ⇒ 目录");
        assert_eq!(item_of(&e[1]).subtitle.as_deref(), Some("目录"));
    }

    /// ★★ 0 条 ⇒ Err（本仓硬约束）
    #[test]
    fn empty_list_is_error_not_empty_ok() {
        let v = parse_json(r#"{"items":[],"next_marker":""}"#).unwrap();
        let e = parse_entries(&v).expect_err("★ 解析 0 条必须 Err，不许 Ok(vec![])");
        assert!(e.contains("改版") || e.contains("风控"), "{e}");
        // 形状不对（没有 items）也必须 Err，且说清缺什么
        let e2 = parse_entries(&parse_json(r#"{"data":[]}"#).unwrap()).expect_err("必须 Err");
        assert!(e2.contains("items"), "{e2}");
    }

    #[test]
    fn html_intercept_is_reported_as_intercept() {
        let e = ensure_json_body("<html>403</html>", 403).expect_err("必须 Err");
        assert!(e.contains("HTML") && e.contains("拦截"), "{e}");
        assert!(ensure_json_body(r#"{"items":[]}"#, 200).is_ok());
    }

    /// ★★★ 无 token 时四条路径都必须如实报登录
    #[tokio::test]
    async fn without_token_every_path_says_login_not_empty() {
        if crate::pan_auth::load(PanKind::Aliyun).is_some() {
            eprintln!("本机钥匙串已有阿里凭据 ⇒ 跳过『无 token』用例（避免假绿/假红）");
            return;
        }
        let s = PanAli::new();
        assert_eq!(s.home("").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.list("root", 1, "").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.detail("f1", "").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.play("默认", "f1", "").await.expect_err("必须 Err"), LOGIN_HINT);
    }

    #[tokio::test]
    async fn search_says_unsupported_not_empty_result() {
        let s = PanAli::new();
        let e = s.search("任意词", 1, "").await.expect_err("★ 必须 Err");
        assert!(e.contains("不支持搜索"), "{e}");
    }

    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("pan_ali.rs"));
        let t = flat.find(".timeout(HTTP_TIMEOUT)").expect("必须有 .timeout");
        let n = flat.find(".no_proxy()").expect("★ 必须 .no_proxy()");
        let b = flat.find(".build()").expect("必须有 .build()");
        assert!(t < n && n < b, "★ 位置必须是 timeout → no_proxy → build");
        assert!(
            flat.contains("Client::builder().user_agent(UA).timeout(HTTP_TIMEOUT).no_proxy().build()"),
            "★ 必须是同一条 builder 链"
        );
    }

    #[test]
    fn human_size_is_readable() {
        assert_eq!(human_size(0), "0 B");
        assert_eq!(human_size(1024), "1.0 KB");
    }
}
