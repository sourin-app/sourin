// ═══════════════════════════════════════════════════════════════════════
//  csp_Pan123 —— 网盘族：列出「我的盘」目录 + 按条目取播放地址
// ═══════════════════════════════════════════════════════════════════════
//
// # 语义（与影视站不同，别照抄它们的样子）
//
// ```text
// 网盘 csp 没有"站点首页"可抓：它列的是**用户自己账号里的文件**。
//   home   = 一个货架（"我的…"）
//   list   = 某目录下的条目（tid = 目录 id）
//   detail = 把**单个文件**包装成"1 集"
//   play   = 该文件的直链
// ⇒ 订阅里这条是 `"searchable":0 / "changeable":0`（没有可换分类、没有远端可搜）。
// ```
//
// # 取证来源（DEX 常量逐字，**没用 jadx**）
//
// ```text
// .probe/csp-parity/Pan123.txt
//   [collect]  列目录端点 + 拼接顺序：
//                ?driveId=0&limit= … &next=0&orderBy=file_name&orderDirection=asc
//                &parentFileId= … &trashed=false&SearchData=&Page= … &OnlyLookAbnormalFile=0
//              响应字段：code / data / InfoList / FileId / FileName / Type
//   [size]     Size / size
//   [head]     referer / origin / platform=android / user-agent=Dart 串 / app-version
//              + "Bearer " ⇒ 鉴权是 **token**，不是 cookie
//   [play]     FileId|fileId / Etag|etag|ETag / S3KeyFlag|S3keyFlag|s3KeyFlag|s3keyFlag
//              / DownloadUrl|downloadUrl        ← 四组**大小写变体**
//   [other]    "原画" / "无限"
//   [<init>]   逐字登录提示 + "获取播放地址失败"
// ```
//
// # ★ 取址端点不在本类里 —— 这是**跨类取证**，必须写清楚（不许含糊成"我猜的"）
//
// ```text
// 本类只给出**响应**字段名（DownloadUrl/downloadUrl），没有取址 URL。
// 同一 jar 的相邻助手类里有 123 的下载信息端点（方法 k，参数名逐字：
//   fileId / fileName / etag / s3keyFlag / size / driveId，响应 code / data / DownloadUrl）
// ⇒ 本实现用那条端点，但**明确标注为跨类取证 + 未在真账号下跑通**。
//   若将来发现它变了，只需改 `DOWNLOAD_INFO_ENDPOINT` 一处。
// ```
//
// # ★ 真网读数（`.probe/parity-pan-a-live.log`，直连无代理无账号）
//
// ```text
// 列目录端点 ⇒ HTTP 200 + {"code":20101,"message":"未登录","trace_id":"…","timestamp":…}
//   ⇒ ① 未登录**不是** HTTP 401，而是 200 + 业务码 ⇒ 判据必须看 `code`，不能只看状态码；
//      ② 这条真片段已作为夹具进测试（断言文案必须带上游原话"未登录"与码 20101）。
// ```
//
// # ⚠️ 诚实边界
//
// ```text
// 1. 需要账号 token；无 token 时 home/list/detail/play **都如实报登录**（逐字文案）。
// 2. `Type` 的取值（0=目录 / 1=文件）**未取证**（DEX 只引用字段名，没有比较常量）。
//    ⇒ 按惯例映射，且**失败方式是良性的**：把目录误判成文件 ⇒ 点播放会得到
//      一句可读 Err，而不是错误地址。
// 3. 一页条数 / 根目录 id 都是 DEX 里的**拼接位**，不是常量 ⇒ 给保守默认值 + 允许 ext 覆盖。
// 4. 播放链路未在真账号下跑通（端点属跨类取证）。**不伪造 m3u8**。
// 5. 原版这一族的播放依赖它自己起的本地转发服务（基类里逐字 `127.0.0.1:5266`）；
//    本仓等价物是 `streamproxy::register(url, headers)` —— 本批**未接通**（未验），
//    类里**不自己起服务**（那会重复造一套）。
// ```
//
// # 为什么 `supports_search() == false`
//
// ```text
// 订阅 `"searchable":0`；`registry.rs` 用 `capabilities.search` 决定要不要把这个源
// 拉进搜索 ⇒ 返 true = 用户每次搜索多打一轮**注定失败**的请求。
// ```

use std::time::Duration;

use async_trait::async_trait;

use crate::pan::PanKind;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 请求超时（理由同 `pan115.rs`：这类接口要么很快，要么被风控静默丢掉）
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

/// 接口 UA —— **逐字**取 DEX `[head]`
///
/// ★ 这个串很"怪"（`Dart/2.19(dart:io)`）但**必须逐字**：参考实现用它冒充客户端。
///   换成浏览器 UA 后服务端会走另一条分支（返回体形状可能不同）⇒ 属"改了会坏"。
const UA: &str = "Dart/2.19(dart:io)";

/// 网页侧 UA（取址/详情页用；逐字取同族 `[head]` 的浏览器串）
const UA_WEB: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                      (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 无登录态时的提示 —— **逐字**取参考实现
const LOGIN_HINT: &str = "还未登录123账号,请前往【配置中心】登录";

/// 首页货架名 —— **逐字**取参考实现（该类里"我的…"那串）
const SHELF_NAME: &str = "我的123云盘";

/// 取址失败时的提示 —— **逐字**取参考实现 `[<init>]` 里的静态串
const PLAY_FAIL: &str = "获取播放地址失败";

/// 线路名 —— **逐字**取 DEX `[other]`（"原画"）
const LINE_ORIGINAL: &str = "原画";

/// 列目录端点（`[collect]` 第一段，逐字）
const LIST_ENDPOINT: &str = "https://www.123pan.cn/b/api/file/list/new";

/// 取址端点（**跨类取证**，见文件头第 2 节）
///
/// ⚠️ 注意 host 与列目录端点**不同**（一个是 `www.123pan.cn`，一个是 `www.123pan.com`）——
///    这是上游自己的分裂（列目录走 .cn、下载走 .com），不是笔误。
///    ★ 这类"跨子域"错写**不会报错**，只会 404 一页 HTML ⇒ 已用两条不同常量钉住。
const DOWNLOAD_INFO_ENDPOINT: &str = "https://www.123pan.com/b/api/file/download_info";

/// 鉴权页 host（逐字取 `[head]` 的 referer / origin）
const WEB_HOST: &str = "https://www.123pan.com";

/// 根目录 id
///
/// ★ 取证等级：**中低**。DEX 里 `&parentFileId=` 是拼接位；本类 `[collect]` 里出现的
///   `driveId=0` 与同族的"根 = 0"惯例一致 ⇒ 取 "0"。
/// ⚠️ 若真实根不是 "0"，list 会拿到空表 ⇒ 走"0 条 ⇒ Err"，**不静默**。
/// ★ 允许 ext 覆盖：`{"parent":"…"}`。
const ROOT_PARENT: &str = "0";

/// 每页条数（DEX 里是拼接位；取保守值，理由见 `pan115.rs` 的同名常量）
const PAGE_LIMIT: u32 = 100;

/// 播放参数分隔符（与 `pan115.rs` 同一套形状：上游也是把多个参数拼成一个串传）
const SEP: &str = "~!~";

/// 条目种类
///
/// ★ 为什么要有 `Unknown` 而不是硬二元：`Type` 的取值**未取证**（见文件头）。
///   把"看不懂"折成 `File` 会让用户点了目录去播放（得到一句可读 Err，但很意外）；
///   折成 `Dir` 会让用户钻进一个文件（拿到空表 ⇒ Err）。
///   ⇒ 显式第三态，UI 只显示它、不当它可播。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Dir,
    File,
    Unknown,
}

/// 网盘里的一个条目（字段名全部来自 DEX 的字面量）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// 文件/目录 id（DEX `FileId`）
    pub file_id: String,
    /// 名字（DEX `FileName`）
    pub name: String,
    /// 种类（DEX `Type`，取值未取证 ⇒ 见 [`Kind`]）
    pub kind: Kind,
    /// 字节数（DEX `Size` / `size`）
    pub size: u64,
    /// 内容指纹（DEX `Etag` 三变体；取址要它）
    pub etag: String,
    /// 存储分层标记（DEX `S3KeyFlag` 四变体；取址要它）
    pub s3key_flag: String,
}

/// `csp_Pan123`
pub struct Pan123 {
    client: reqwest::Client,
}

impl Pan123 {
    pub const CLASS: &'static str = "Pan123";

    pub fn new() -> Self {
        // ★ 三条构造纪律：no_proxy 在 timeout 之后、build 之前；用 expect 而不是
        //   `unwrap_or_else(Client::new)`（后者会**悄悄丢掉** no_proxy）；不缓存凭据。
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("build pan123 http client");
        Self { client }
    }

    /// 本盘的**鉴权 token**
    ///
    /// # 为什么叫 token 而不是 cookie
    /// ```text
    /// DEX `[head]` 里鉴权头逐字是 "Bearer " + 值 ⇒ 这个盘用的是 token。
    /// 但本仓的凭据位（`pan_auth::PanCredential`）只有一个 `cookie` 字段，
    /// 键名沿用 `cookie`、值语义是 token ⇒ **在这里写清楚**，别让后来人以为它真是 cookie。
    /// （改 `PanCredential` 的字段名会牵动钥匙串与 5 个盘 ⇒ 不在本批范围内。）
    /// ```
    fn token() -> Option<String> {
        crate::pan_auth::load(PanKind::Pan123)
            .map(|c| c.cookie.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    /// 根目录 id（ext 可覆盖）
    pub fn root_parent(ext: &str) -> String {
        ext_json(ext)
            .and_then(|j| {
                j.get("parent")
                    .or_else(|| j.get("root"))
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim().to_string())
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| ROOT_PARENT.to_string())
    }

    /// 带鉴权发一次 GET，返回原文（JSON 解析交给纯函数 ⇒ 便于单测）
    async fn get_text(&self, token: &str, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            // 逐字取 DEX `[head]`：四件头一起带，缺一个都可能被判成爬虫
            .header("Authorization", format!("Bearer {token}"))
            .header("referer", WEB_HOST)
            .header("origin", WEB_HOST)
            .header("platform", "android")
            .header("app-version", "3")
            .header("Accept", "application/json, text/plain, */*")
            .send()
            .await
            .map_err(|e| format!("123 请求失败：{e}"))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        ensure_json_body(&body, status.as_u16())?;
        if !status.is_success() {
            return Err(format!("123 返回 HTTP {status}：{}", short(&body)));
        }
        Ok(body)
    }
}

#[async_trait]
impl CspSite for Pan123 {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页 = 一个货架（网盘没有"分类页"）
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        if Self::token().is_none() {
            // ★ 无 token ⇒ 如实报登录，**不返回空首页**（空首页=骗用户"盘是空的"）
            return Err(LOGIN_HINT.to_string());
        }
        Ok(CspHome {
            categories: vec![CspCategory {
                id: Self::root_parent(ext),
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
            Self::root_parent(ext)
        } else {
            tid.trim().to_string()
        };
        let page = if page == 0 { 1 } else { page };
        let url = list_url(&parent, page, PAGE_LIMIT);
        let body = self.get_text(&token, &url).await?;
        let v = parse_json(&body)?;
        let entries = parse_entries(&v)?;
        let items = entries.iter().map(item_of).collect();
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    /// 详情：单个文件 ⇒ "1 集"
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        if Self::token().is_none() {
            return Err(LOGIN_HINT.to_string());
        }
        let p = PlayParam::parse(id);
        Ok(CspDetail {
            id: id.to_string(),
            title: if p.name.is_empty() {
                id.to_string()
            } else {
                p.name.clone()
            },
            cover: None,
            description: None,
            episodes: vec![CspEpisode {
                id: id.to_string(),
                title: "播放".to_string(),
                flag: LINE_ORIGINAL.to_string(),
            }],
        })
    }

    fn supports_search(&self) -> bool {
        false
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("123 不支持搜索（它只列出你自己账号里的目录）".to_string())
    }

    /// 取播放地址
    ///
    /// # 走到哪里（**如实**）
    /// ```text
    /// ① 无 token ⇒ 逐字登录提示。
    /// ② id 拆不成完整取流参数 ⇒ 逐字"获取播放地址失败"（对目录点播放走这条）。
    /// ③ 打取址端点：`code != 0` ⇒ 带上游 message；`DownloadUrl` 缺失 ⇒ PLAY_FAIL。
    /// ④ 成功 ⇒ 给直链 + 必须带的头（上游 CDN 认 Referer/Origin，缺了会 403）。
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let Some(token) = Self::token() else {
            return Err(LOGIN_HINT.to_string());
        };
        let p = PlayParam::parse(id.trim());
        if !p.is_complete() {
            return Err(PLAY_FAIL.to_string());
        }
        let url = download_info_url(&p);
        let body = self.get_text(&token, &url).await?;
        let v = parse_json(&body)?;
        if let Some(code) = code_of(&v) {
            if code != 0 {
                return Err(format!(
                    "{PLAY_FAIL}：{}（code {code}）",
                    message_of(&v).unwrap_or_else(|| "上游未给原因".to_string())
                ));
            }
        }
        let Some(dl) = download_url_of(&v) else {
            return Err(format!(
                "{PLAY_FAIL}：响应里没有 DownloadUrl（可能改版/风控壳页）：{}",
                short(&v.to_string())
            ));
        };
        Ok(vec![CspPlay {
            url: dl,
            // ★ 直链必须带头：这是"取流"的一部分，不是可选装饰（缺 Referer 会 403）
            headers: vec![
                ("Referer".to_string(), format!("{WEB_HOST}/")),
                ("Origin".to_string(), WEB_HOST.to_string()),
                ("User-Agent".to_string(), UA_WEB.to_string()),
            ],
            label: Some(LINE_ORIGINAL.to_string()),
        }])
    }
}

/// 取流所需的四项参数（**纯数据** —— 从条目 id 里拆出来）
///
/// # 为什么把参数编进 id（而不是"播放时再去列一次目录"）
/// ```text
/// 播放时我们只知道"这一条的 id"，不知道它在哪个目录里
///   ⇒ 再去列目录就得先知道 parent，而 parent 没被传进来 ⇒ 只能**编**一个（不许）。
/// ⇒ 参考实现也是把多个参数拼成一个串传给播放链路（本族普遍这么干，
///    `~!~` 那个分隔符在另一家的播放方法里逐字出现）。
/// ★ 字段顺序：**名字放最后**，这样即使文件名里含分隔符，`splitn` 也会把
///   剩余部分整段留给名字 ⇒ 不会串位（比 name 放中间稳）。
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PlayParam {
    pub file_id: String,
    pub etag: String,
    pub s3key_flag: String,
    pub size: u64,
    pub name: String,
}

impl PlayParam {
    /// 编：`fileId~!~etag~!~s3keyFlag~!~size~!~名字`
    pub fn encode(e: &Entry) -> String {
        format!(
            "{}{SEP}{}{SEP}{}{SEP}{}{SEP}{}",
            e.file_id, e.etag, e.s3key_flag, e.size, e.name
        )
    }

    /// 拆（容错：字段不足 ⇒ 缺的留空，由 `is_complete` 判定）
    pub fn parse(id: &str) -> Self {
        let mut it = id.splitn(5, SEP);
        let file_id = it.next().unwrap_or("").trim().to_string();
        let etag = it.next().unwrap_or("").trim().to_string();
        let s3key_flag = it.next().unwrap_or("").trim().to_string();
        let size = it
            .next()
            .unwrap_or("")
            .trim()
            .parse::<u64>()
            .unwrap_or(0);
        let name = it.next().unwrap_or("").trim().to_string();
        Self {
            file_id,
            etag,
            s3key_flag,
            size,
            name,
        }
    }

    /// 够不够取流（`etag` / `s3keyFlag` 缺一个都取不到 ⇒ 算不完整）
    pub fn is_complete(&self) -> bool {
        !self.file_id.is_empty() && !self.etag.is_empty() && !self.s3key_flag.is_empty()
    }
}

/// 拼"列目录"URL（**纯函数**，为了能断言逐字顺序）
fn list_url(parent: &str, page: u32, limit: u32) -> String {
    format!(
        "{LIST_ENDPOINT}?driveId=0&limit={limit}\
         &next=0&orderBy=file_name&orderDirection=asc\
         &parentFileId={parent}\
         &trashed=false&SearchData=&Page={page}&OnlyLookAbnormalFile=0"
    )
}

/// 拼"取址"URL（**纯函数**，同上）
///
/// ★ 参数名逐字取跨类取证的方法（fileId / fileName / etag / s3keyFlag / size / driveId），
///   **顺序也照它**（这类接口对顺序不敏感，但"照抄"比"我觉得无所谓"更容易复核）。
fn download_info_url(p: &PlayParam) -> String {
    format!(
        "{DOWNLOAD_INFO_ENDPOINT}?fileId={}&fileName={}&etag={}&s3keyFlag={}&size={}&driveId=0",
        enc(&p.file_id),
        enc(&p.name),
        enc(&p.etag),
        enc(&p.s3key_flag),
        p.size
    )
}

/// 最小百分号编码（只保留 unreserved 字符）
///
/// # 为什么自己写 4 行而不是加个 crate
/// ```text
/// 本仓纪律：不新增运行时依赖（`Cargo.toml` 零 diff）。
/// 这里只需要"把查询串里的一个值安全地放进去"，不需要全套 URL 语义。
/// ★ 不编码会怎样：文件名里的 `&` / `#` / 空格会把查询串**切断**
///   ⇒ 服务端收到的是另一个请求（且**不报错**，只会取不到址）⇒ 属于静默错。
/// ```
fn enc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        let c = *b as char;
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~') {
            out.push(c);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn parse_json(body: &str) -> Result<serde_json::Value, String> {
    crate::tvbox::parse_loose_json(body)
        .map_err(|e| format!("123 返回的不是 JSON（{e}）：{}", short(body)))
}

/// 非 JSON / 空体 / HTML 拦截页的统一前置判定
fn ensure_json_body(body: &str, http: u16) -> Result<(), String> {
    let t = body.trim_start();
    if t.starts_with('<') {
        return Err(format!(
            "123 返回的是 HTML（HTTP {http}），不是 JSON —— 多半是 CDN/WAF 拦截页或改版壳页：{}",
            short(body)
        ));
    }
    if t.is_empty() {
        return Err(format!("123 返回空响应体（HTTP {http}）"));
    }
    Ok(())
}

/// 业务码（`code`；有的时期是字符串 ⇒ 两种都认）
fn code_of(v: &serde_json::Value) -> Option<i64> {
    match v.get("code")? {
        serde_json::Value::Number(n) => n.as_i64(),
        serde_json::Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

/// 上游原因（`message` / `msg`）
fn message_of(v: &serde_json::Value) -> Option<String> {
    for k in ["message", "msg", "error"] {
        if let Some(s) = v.get(k).and_then(|x| x.as_str()) {
            let s = s.trim();
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// 从响应里抽条目（**纯函数**；0 条 ⇒ `Err`）
///
/// # 空 ⇒ Err 的理由（本仓硬约束）
/// ```text
/// "解析出 0 条"与"目录真的空"在数据上不可区分。若返回 Ok(vec![])，上层原样透传
/// ⇒ 用户看到"这个源没内容" ⇒ 去怀疑源，而真正原因是**我们没解析到**。
/// ```
fn parse_entries(v: &serde_json::Value) -> Result<Vec<Entry>, String> {
    // ★ 先看业务码：实测未登录是 **HTTP 200 + code 20101**（不是 401）
    if let Some(code) = code_of(v) {
        if code != 0 {
            return Err(format!(
                "123 列目录失败：{}（code {code}）",
                message_of(v).unwrap_or_else(|| "上游未给原因".to_string())
            ));
        }
    }
    let arr = v
        .get("data")
        .and_then(|d| d.get("InfoList").or_else(|| d.get("infoList")))
        .and_then(|l| l.as_array());
    let Some(arr) = arr else {
        return Err(format!(
            "123 列目录响应里没有 data.InfoList 数组（可能改版/风控壳页）：{}",
            short(&v.to_string())
        ));
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let file_id = str_of(it, &["FileId", "fileId"]);
        if file_id.is_empty() {
            // 没 id 的条目拿去详情/取址只会失败 ⇒ 丢掉，而不是编一个
            continue;
        }
        out.push(Entry {
            file_id,
            name: str_of(it, &["FileName", "fileName"]),
            kind: kind_of(it),
            size: u64_of(it, &["Size", "size"]),
            etag: str_of(it, &["Etag", "etag", "ETag"]),
            s3key_flag: str_of(
                it,
                &["S3KeyFlag", "S3keyFlag", "s3KeyFlag", "s3keyFlag", "S3keyflag"],
            ),
        });
    }
    if out.is_empty() {
        return Err(format!(
            "123 列目录解析出 0 条（可能改版/风控壳页，也可能是空目录）：{}",
            short(&v.to_string())
        ));
    }
    Ok(out)
}

/// `Type` → [`Kind`]
///
/// ⚠️ **取值未取证**（DEX 只引用字段名，没有比较常量）。按惯例：0 = 目录、1 = 文件。
///    ★ 为什么这个假设**可以接受**：失败方式是良性的 ——
///      目录被误判成文件 ⇒ 用户点播放 ⇒ `PlayParam` 里 etag/s3keyFlag 为空
///      ⇒ 逐字报"获取播放地址失败"；文件被误判成目录 ⇒ 钻进去 ⇒ 空表 ⇒ 可读 Err。
///      两种都不会给出**错误地址**（那才是真正会骗人的失败）。
fn kind_of(it: &serde_json::Value) -> Kind {
    let t = it
        .get("Type")
        .or_else(|| it.get("type"))
        .and_then(|x| match x {
            serde_json::Value::Number(n) => n.as_i64(),
            serde_json::Value::String(s) => s.trim().parse::<i64>().ok(),
            _ => None,
        });
    match t {
        Some(0) => Kind::Dir,
        Some(1) => Kind::File,
        _ => Kind::Unknown,
    }
}

/// 条目 → UI 一行
fn item_of(e: &Entry) -> CspItem {
    let (id, subtitle) = match e.kind {
        // 目录：id = 自己的 id（UI 拿它当 tid 继续钻）
        Kind::Dir => (e.file_id.clone(), "目录".to_string()),
        // 文件：id = 取流参数（见 `PlayParam`）
        Kind::File => (PlayParam::encode(e), human_size(e.size)),
        // 看不懂的种类：只给 id，不宣称可播
        Kind::Unknown => (e.file_id.clone(), "未知类型".to_string()),
    };
    CspItem {
        id,
        title: e.name.clone(),
        cover: None,
        subtitle: Some(subtitle),
    }
}

/// 取直链（`DownloadUrl` / `downloadUrl` 两变体，逐字取 DEX `[play]`）
fn download_url_of(v: &serde_json::Value) -> Option<String> {
    let d = v.get("data").unwrap_or(v);
    for k in ["DownloadUrl", "downloadUrl", "download_url"] {
        if let Some(s) = d.get(k).and_then(|x| x.as_str()) {
            let s = s.trim();
            if s.starts_with("http") {
                return Some(s.to_string());
            }
        }
    }
    None
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

crate::csp::register_site!(Pan123);

#[cfg(test)]
mod tests {
    use super::*;

    /// **真实响应片段**（直连实测、无账号、HTTP 200）
    ///
    /// ```text
    /// curl --noproxy '*' 'https://www.123pan.cn/b/api/file/list/new?…'
    /// ⇒ {"code":20101,"message":"未登录","trace_id":"…","timestamp":…}
    /// ★ 关键读数：未登录**不是** HTTP 401，而是 200 + 业务码
    ///   ⇒ 只看状态码的实现会把"未登录"当成"成功但空目录"。
    /// ```
    const LIVE_UNAUTH: &str = r#"{"code":20101,"message":"未登录","trace_id":"78d4472b-fe9c-4725-b7fd-46789986f84f","timestamp":1793144119}"#;

    /// **真实响应片段**（列目录端点被拦截时是一页 HTML —— 同族实测形态）
    const LIVE_WAF_HTML: &str = r#"<!doctype html><html><head><title>403 Forbidden</title></head></html>"#;

    /// **不是真网响应**：按 DEX 字段名还原的成功形态（无账号取不到真 200 体）
    const DEX_SHAPE_OK: &str = r#"{"code":0,"message":"ok","data":{"InfoList":[
        {"FileId":101,"FileName":"第一集.mp4","Type":1,"Size":734003200,"Etag":"e1","S3KeyFlag":"s1"},
        {"FileId":202,"FileName":"剧集目录","Type":0,"Size":0},
        {"FileName":"没有 id 的行","Type":1}
    ]}}"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Pan123::CLASS, "Pan123");
    }

    #[test]
    fn registration_is_present() {
        assert!(
            crate::csp::is_implemented("csp_Pan123"),
            "★ csp_Pan123 必须在注册表里（有 host 常量 + 订阅有站）"
        );
        let s = crate::csp::route("csp_Pan123").expect("必须能路由出实例");
        assert_eq!(s.class(), "Pan123");
        assert!(!s.supports_search(), "订阅 searchable:0 ⇒ 必须 false");
    }

    #[test]
    fn visible_wording_matches_reference() {
        assert_eq!(LOGIN_HINT, "还未登录123账号,请前往【配置中心】登录");
        assert_eq!(PLAY_FAIL, "获取播放地址失败");
        assert_eq!(LINE_ORIGINAL, "原画");
        assert_eq!(SHELF_NAME, "我的123云盘");
        for s in [LOGIN_HINT, PLAY_FAIL, LINE_ORIGINAL, SHELF_NAME] {
            assert!(!s.contains("**"), "★ 用户可见文案不许有 markdown 强调：{s}");
        }
    }

    /// ★★ URL 逐字门禁：照 DEX `[collect]` 的**拼接顺序**
    ///
    /// 注入验证：把 `&parentFileId=` 挪到 `&trashed=` 之后 ⇒ 红。
    #[test]
    fn list_url_matches_reference_byte_for_byte() {
        let u = list_url("0", 1, 100);
        assert_eq!(
            u,
            "https://www.123pan.cn/b/api/file/list/new?driveId=0&limit=100\
             &next=0&orderBy=file_name&orderDirection=asc\
             &parentFileId=0\
             &trashed=false&SearchData=&Page=1&OnlyLookAbnormalFile=0"
        );
        // 反空真：参数必须真的生效
        let u2 = list_url("987", 3, 50);
        assert!(u2.contains("parentFileId=987"), "{u2}");
        assert!(u2.contains("Page=3"), "{u2}");
        assert!(u2.contains("limit=50"), "{u2}");
        assert!(u2.ends_with("OnlyLookAbnormalFile=0"), "{u2}");
    }

    /// ★★ 取址 URL：**参数名逐字**（跨类取证）+ 中文名必须被编码
    ///
    /// 注入验证：把 `enc(&p.name)` 改成 `p.name` ⇒ 本条红 ——
    /// 而线上后果是"名字里带 & 的文件取不到址"（**不报错**，只是失败）⇒ 必须钉住。
    #[test]
    fn download_info_url_encodes_every_value() {
        let p = PlayParam {
            file_id: "101".into(),
            etag: "e 1".into(),
            s3key_flag: "s1".into(),
            size: 7,
            name: "第 1 集 & 花絮.mp4".into(),
        };
        let u = download_info_url(&p);
        assert!(u.starts_with("https://www.123pan.com/b/api/file/download_info?"), "{u}");
        assert!(u.contains("fileId=101&fileName="), "★ 参数名/顺序照取证：{u}");
        assert!(
            u.contains("fileName=%E7%AC%AC%201%20%E9%9B%86%20%26%20"),
            "★ 中文/空格/& 必须百分号编码（否则查询串会被切断）：{u}"
        );
        assert!(u.contains("&etag=e%201&"), "★ etag 里的空格也要编码：{u}");
        assert!(u.contains("&size=7&driveId=0"), "{u}");
    }

    #[test]
    fn play_param_roundtrip_and_name_last() {
        let e = Entry {
            file_id: "101".into(),
            name: "第 1 集~!~奇怪的名字.mp4".into(),
            kind: Kind::File,
            size: 2048,
            etag: "e1".into(),
            s3key_flag: "s1".into(),
        };
        let id = PlayParam::encode(&e);
        let p = PlayParam::parse(&id);
        assert_eq!(p.file_id, "101");
        assert_eq!(p.etag, "e1");
        assert_eq!(p.s3key_flag, "s1");
        assert_eq!(p.size, 2048);
        // ★ 名字放最后 ⇒ 名字里即使含分隔符也不会串位（这是刻意选的字段顺序）
        assert_eq!(p.name, "第 1 集~!~奇怪的名字.mp4");
        assert!(p.is_complete());

        // 缺 etag/s3keyFlag ⇒ 不完整（对目录点播放走这条）
        let bad = PlayParam::parse("101~!~~!~~!~0~!~名字");
        assert!(!bad.is_complete(), "★ 缺 etag/s3keyFlag 一律算不完整");
    }

    /// ★★ 真网读数：未登录是 200 + code 20101，文案要带上游原话与码
    ///
    /// 注入验证：把 `code_of` 那段判定删掉（只认数组）⇒ 本条红 ——
    /// 用户会看到"没有 InfoList 数组（可能改版）"，把"未登录"误诊成"改版"。
    #[test]
    fn live_unauth_fragment_says_not_logged_in_with_code() {
        let v = parse_json(LIVE_UNAUTH).unwrap();
        let e = parse_entries(&v).expect_err("★ code 20101 必须 Err");
        assert!(e.contains("未登录"), "★ 必须带上游原话：{e}");
        assert!(e.contains("20101"), "★ 必须带业务码（判据是码不是状态码）：{e}");
    }

    /// ★★ 0 条 ⇒ Err（不许 Ok(空)）
    #[test]
    fn empty_list_is_error_not_empty_ok() {
        let v = parse_json(r#"{"code":0,"data":{"InfoList":[]}}"#).unwrap();
        let e = parse_entries(&v).expect_err("★ 解析 0 条必须 Err，不许 Ok(vec![])");
        assert!(e.contains("改版") || e.contains("风控"), "{e}");
    }

    #[test]
    fn html_intercept_page_is_reported_as_intercept() {
        let e = ensure_json_body(LIVE_WAF_HTML, 403).expect_err("★ HTML 必须 Err");
        assert!(e.contains("HTML") && e.contains("403"), "{e}");
        assert!(e.contains("拦截") || e.contains("改版"), "{e}");
        assert!(ensure_json_body(r#"{"code":0}"#, 200).is_ok());
        assert!(ensure_json_body("", 200).is_err());
    }

    /// ★★ DEX 字段名门禁：InfoList / FileId / FileName / Type / Size / Etag / S3KeyFlag
    #[test]
    fn parse_entries_reads_dex_field_names() {
        let v = parse_json(DEX_SHAPE_OK).unwrap();
        let e = parse_entries(&v).unwrap();
        assert_eq!(e.len(), 2, "★ 没 id 的行必须丢掉");
        assert_eq!(e[0].file_id, "101", "★ 数字 id 也要能读成字符串");
        assert_eq!(e[0].name, "第一集.mp4");
        assert_eq!(e[0].kind, Kind::File);
        assert_eq!(e[0].size, 734003200);
        assert_eq!(e[0].etag, "e1");
        assert_eq!(e[0].s3key_flag, "s1");
        assert_eq!(e[1].kind, Kind::Dir, "★ Type=0 ⇒ 目录");
        assert_eq!(e[1].etag, "", "目录没有 etag，不许编");
    }

    #[test]
    fn unknown_type_is_not_claimed_playable() {
        let e = Entry {
            file_id: "9".into(),
            name: "怪东西".into(),
            kind: Kind::Unknown,
            size: 0,
            etag: String::new(),
            s3key_flag: String::new(),
        };
        let it = item_of(&e);
        assert_eq!(it.id, "9", "★ 未知类型不许编取流参数");
        assert_eq!(it.subtitle.as_deref(), Some("未知类型"));
    }

    #[test]
    fn root_parent_defaults_and_ext_override() {
        assert_eq!(Pan123::root_parent(""), "0");
        assert_eq!(Pan123::root_parent(r#"{"parent":"777"}"#), "777");
        assert_eq!(Pan123::root_parent("坏 json"), "0");
    }

    /// ★★★ 无 token 时四条路径都必须如实报登录
    ///
    /// 注入验证：把 `home` 的 `return Err(LOGIN_HINT…)` 改成 `Ok(CspHome::default())` ⇒ 红。
    #[tokio::test]
    async fn without_token_every_path_says_login_not_empty() {
        if crate::pan_auth::load(PanKind::Pan123).is_some() {
            eprintln!("本机钥匙串已有 123 凭据 ⇒ 跳过『无 token』用例（避免假绿/假红）");
            return;
        }
        let s = Pan123::new();
        assert_eq!(s.home("").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.list("0", 1, "").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.detail("x", "").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(
            s.play("原画", "1~!~e~!~s~!~0~!~n", "").await.expect_err("必须 Err"),
            LOGIN_HINT
        );
    }

    #[tokio::test]
    async fn search_says_unsupported_not_empty_result() {
        let s = Pan123::new();
        let e = s.search("任意词", 1, "").await.expect_err("★ 必须 Err");
        assert!(e.contains("不支持搜索"), "{e}");
    }

    /// ★ 结构性判据：no_proxy 的位置（写漏**不会**编译错，只会让开代理的机器全失败）
    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("pan123.rs"));
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
