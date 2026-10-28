// ═══════════════════════════════════════════════════════════════════════
//  csp_PanTianyi —— 网盘族：列出「我的盘」目录 + 按条目取直链
// ═══════════════════════════════════════════════════════════════════════
//
// # 语义（与影视站不同）
//
// ```text
// 网盘 csp 没有"站点首页"：它列的是**用户自己账号里的文件**。
//   home = 一个货架；list = 某目录下的条目；detail = 文件包装成"1 集"；
//   play = 该文件的直链（本类**有**取址端点，见下 —— 五家里只有它和另一家是齐的）。
// ⇒ 订阅里 `"searchable":0 / "changeable":0`。
// ```
//
// # 取证来源（DEX 常量逐字，**没用 jadx**）
//
// ```text
// .probe/csp-parity/PanTianyi.txt
//   [collect]     列目录端点 + 拼接顺序：
//                   ?folderId= … &fileType=0&mediaType=0&iconOption=5
//                   &orderBy=filename&descending=false &pageNum= … &pageSize=
//                 响应分层：fileListAO → folderList / fileList
//                 条目字段：name / id / size（+ 两个空串默认值）
//   [downloadUrl] 取址端点 ?fileId= … &dt=1  ⇒ 响应 res_code / fileDownloadUrl
//   [head]        Accept: application/json / UA 浏览器串 / Cookie
//   [f0]          首页常量：货架名 + **根目录 id = "-11"**（逐字！）+ 两个标志位
//   [h0]          播放失败文案：逐字 "获取播放地址失败"；播放参数分隔符 "~!~"
//   [clone]       季号正则 `.*S(\d).*` + 默认 "-11"（参考实现用它给条目分季命名）
// ```
//
// # ★ 真网读数（`.probe/parity-pan-a-live.log`，直连无代理无账号）
//
// ```text
// 列目录端点 ⇒ **HTTP 400** + {"errorCode":"InvalidSessionKey",
//                             "errorMsg":"cookieUserSession is null or invalid, cookieUserSession=null"}
// 取址端点   ⇒ 同一形态（也是 400 InvalidSessionKey）
// ⇒ ① 未登录**不是** 200，也不是 401，而是**400 + 业务错码**；
//   ② 参考实现只判 `fileListAO` 存在与否 ⇒ 会把这种情况显示成"目录内没有可播放的视频"
//      （把"没登录"误报成"目录空"）。**本实现不吃这个亏**：非 2xx 就直接报错，
//      并把 errorCode/errorMsg 原样带给用户（已用真片段钉住）。
// ```
//
// # ⚠️ 诚实边界
//
// ```text
// 1. 需要账号 cookie。无 cookie ⇒ home/list/detail/play 都如实报登录（逐字文案）。
// 2. 取址**已按 DEX 逐字接上**（端点 + 两个响应字段都在本类字面量里），
//    但**未在真账号下跑通** ⇒ 注释与测试都按"未验"处理；不伪造地址。
// 3. 直链通常需要带 Cookie 才能取到（`[head]` 里三个头是给"取流"用的，不是装饰）
//    ⇒ `CspPlay.headers` 一并带上；缺头会 403，而 403 会被用户当成"文件坏了"。
// 4. 参考实现用 `.*S(\d).*` 给条目分季（`S01`/`S2`）。本实现**不做**这层命名：
//    它只影响显示，不影响取流；而"猜集数"猜错会把用户带到错的集 ⇒ 不猜。
// 5. 原版这一族的播放靠它自己起的本地转发服务（基类里逐字 `127.0.0.1:5266`）；
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

/// UA —— **逐字**取 DEX `[head]`
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 无登录态时的提示 —— **逐字**取参考实现
const LOGIN_HINT: &str = "还未登录天翼账号,请前往【配置中心】登录";

/// 首页货架名 —— **逐字**取参考实现 `[f0]`
const SHELF_NAME: &str = "我的天翼云盘";

/// 播放失败文案 —— **逐字**取参考实现 `[h0]`
const PLAY_FAIL: &str = "获取播放地址失败";

/// 播放参数分隔符 —— **逐字**取 DEX（`[h0]` 里出现）
const SEP: &str = "~!~";

/// 列目录端点（逐字）
const LIST_ENDPOINT: &str = "https://cloud.189.cn/api/open/file/listFiles.action";

/// 取址端点（逐字）
const DOWNLOAD_ENDPOINT: &str =
    "https://cloud.189.cn/api/open/file/getFileDownloadUrl.action";

/// 根目录 id —— **逐字**取 `[f0]` 的 `"-11"`（这条不是猜的，是本类最有价值的一条常量）
///
/// ★ 为什么单独强调：五家里只有两家给出根 id 的逐字证据（这家 `-11`、另一家 `root`），
///   其余靠惯例。**根 id 猜错的代价**是"列出来是空目录"，
///   没有"空 ⇒ Err"那条纪律的话，用户会以为自己的盘是空的。
const ROOT_FOLDER: &str = "-11";

/// 每页条数（DEX 里 `pageSize` 是拼接位 ⇒ 保守值）
const PAGE_SIZE: u32 = 100;

/// 网盘里的一个条目
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// 条目 id（DEX `id`；取址端点的参数就是它）
    pub id: String,
    pub name: String,
    /// true = 目录（来自 `fileListAO.folderList` 这一层）
    pub is_dir: bool,
    pub size: u64,
}

/// `csp_PanTianyi`
pub struct PanTianyi {
    client: reqwest::Client,
}

impl PanTianyi {
    pub const CLASS: &'static str = "PanTianyi";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("build pan_tianyi http client");
        Self { client }
    }

    /// 本盘的登录 cookie
    ///
    /// ★ 这个盘的鉴权是**会话 cookie**（`[head]` 里逐字有 `Cookie` 头，
    ///   实测未登录报 `cookieUserSession is null`）⇒ 与其他几家"token"不同，
    ///   但本仓凭据位只有一个字符串字段，统一放 `cookie`。
    fn cookie() -> Option<String> {
        crate::pan_auth::load(PanKind::Tianyi)
            .map(|c| c.cookie.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    /// 根目录 id（ext 可覆盖）
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

    /// 带 cookie 发一次 GET，返回原文
    async fn get_text(&self, cookie: &str, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            // 逐字取 DEX `[head]`：三件头
            .header("Accept", "application/json;charset=UTF-8")
            .header("Cookie", cookie)
            .send()
            .await
            .map_err(|e| format!("天翼 请求失败：{e}"))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        ensure_json_body(&body, status.as_u16())?;
        if !status.is_success() {
            // ★ 实测未登录 = 400 + errorCode/errorMsg ⇒ 必须带出来
            return Err(format!("天翼 返回 HTTP {status}：{}", business_reason(&body)));
        }
        Ok(body)
    }
}

#[async_trait]
impl CspSite for PanTianyi {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        if Self::cookie().is_none() {
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
        let Some(cookie) = Self::cookie() else {
            return Err(LOGIN_HINT.to_string());
        };
        let folder = if tid.trim().is_empty() {
            Self::root_folder(ext)
        } else {
            tid.trim().to_string()
        };
        let page = if page == 0 { 1 } else { page };
        let url = list_url(&folder, page, PAGE_SIZE);
        let body = self.get_text(&cookie, &url).await?;
        let v = parse_json(&body)?;
        let entries = parse_entries(&v)?;
        let n = entries.len();
        let items = entries.iter().map(item_of).collect();
        Ok(CspList {
            items,
            page,
            page_count: if n < PAGE_SIZE as usize { Some(page) } else { None },
            total: None,
        })
    }

    /// 详情：单个文件 ⇒ "1 集"
    ///
    /// ★ 条目 id 里可能带上参考实现的播放参数形状（`名字~!~id`）；
    ///   这里只取最后一段当 id（与取址端点的参数对齐），名字取前面那半截。
    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        if Self::cookie().is_none() {
            return Err(LOGIN_HINT.to_string());
        }
        let (name, file_id) = split_param(id);
        Ok(CspDetail {
            id: id.to_string(),
            title: if name.is_empty() { id.to_string() } else { name },
            cover: None,
            description: None,
            episodes: vec![CspEpisode {
                id: file_id,
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
    /// 依据：未登录必然 Err（真网读数：InvalidSessionKey）
    /// ⇒ 默认不自动暴露（用户导入带 ext 的站点时照常出现）。
    fn needs_ext(&self) -> bool {
        true
    }


    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("天翼 不支持搜索（它只列出你自己账号里的目录）".to_string())
    }

    /// 取播放地址（端点 + 两个响应字段都在本类字面量里）
    ///
    /// # 走到哪里
    /// ```text
    /// ① 无 cookie ⇒ 逐字登录提示。
    /// ② id 为空 ⇒ 逐字"获取播放地址失败"。
    /// ③ 打取址端点：`res_code != 0` 或没有 `fileDownloadUrl` ⇒ 逐字 PLAY_FAIL + 上游原因。
    /// ④ 成功 ⇒ 直链 + **必须带的头**（Cookie/UA/Accept）：
    ///    该盘的直链认会话 ⇒ 缺头就是 403，而用户会把 403 读成"文件坏了"。
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let Some(cookie) = Self::cookie() else {
            return Err(LOGIN_HINT.to_string());
        };
        let (_name, file_id) = split_param(id.trim());
        if file_id.is_empty() {
            return Err(PLAY_FAIL.to_string());
        }
        let url = download_url(&file_id);
        let body = self.get_text(&cookie, &url).await?;
        let v = parse_json(&body)?;
        if let Some(code) = res_code_of(&v) {
            if code != 0 {
                return Err(format!(
                    "{PLAY_FAIL}：{}",
                    business_reason(&v.to_string())
                ));
            }
        }
        let Some(dl) = v
            .get("fileDownloadUrl")
            .and_then(|x| x.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| s.starts_with("http"))
        else {
            return Err(format!(
                "{PLAY_FAIL}：响应里没有 fileDownloadUrl（可能改版/风控壳页）：{}",
                short(&v.to_string())
            ));
        };
        Ok(vec![CspPlay {
            url: dl,
            headers: vec![
                ("Cookie".to_string(), cookie),
                ("User-Agent".to_string(), UA.to_string()),
                ("Accept".to_string(), "application/json;charset=UTF-8".to_string()),
            ],
            label: None,
        }])
    }
}

/// 拼"列目录"URL（**纯函数**）
///
/// ★ 顺序照 DEX 的拼接顺序：`folderId` → 固定三件 → 排序两件 → `pageNum` → `pageSize`。
///   这类"顺序无所谓"的参数，**照抄**比"我觉得无所谓"更容易复核。
fn list_url(folder: &str, page: u32, size: u32) -> String {
    format!(
        "{LIST_ENDPOINT}?folderId={folder}\
         &fileType=0&mediaType=0&iconOption=5\
         &orderBy=filename&descending=false\
         &pageNum={page}&pageSize={size}"
    )
}

/// 拼"取址"URL（**纯函数**）
fn download_url(file_id: &str) -> String {
    format!("{DOWNLOAD_ENDPOINT}?fileId={file_id}&dt=1")
}

/// 拆播放参数：`名字~!~id`（**纯函数**）
///
/// ★ 从右侧切：id 是最后一段，名字里即使含分隔符也不会串位。
fn split_param(id: &str) -> (String, String) {
    match id.rsplit_once(SEP) {
        Some((name, fid)) => (name.trim().to_string(), fid.trim().to_string()),
        None => (String::new(), id.trim().to_string()),
    }
}

fn parse_json(body: &str) -> Result<serde_json::Value, String> {
    crate::tvbox::parse_loose_json(body)
        .map_err(|e| format!("天翼 返回的不是 JSON（{e}）：{}", short(body)))
}

fn ensure_json_body(body: &str, http: u16) -> Result<(), String> {
    let t = body.trim_start();
    if t.starts_with('<') {
        return Err(format!(
            "天翼 返回的是 HTML（HTTP {http}），不是 JSON —— 多半是 CDN/WAF 拦截页或改版壳页：{}",
            short(body)
        ));
    }
    if t.is_empty() {
        return Err(format!("天翼 返回空响应体（HTTP {http}）"));
    }
    Ok(())
}

/// 业务错码/原因（实测未登录：`errorCode` + `errorMsg`）
fn business_reason(body: &str) -> String {
    let Ok(v) = crate::tvbox::parse_loose_json(body) else {
        return short(body);
    };
    let code = v
        .get("errorCode")
        .and_then(|x| x.as_str())
        .unwrap_or("");
    let msg = v.get("errorMsg").and_then(|x| x.as_str()).unwrap_or("");
    // ★ 逐字取自实测：未登录是 InvalidSessionKey + cookieUserSession is null
    let need_login = code.eq_ignore_ascii_case("InvalidSessionKey")
        || msg.to_ascii_lowercase().contains("cookiusersession")
        || msg.to_ascii_lowercase().contains("cookieusersession");
    let txt = match (code.is_empty(), msg.is_empty()) {
        (false, false) => format!("{msg}（{code}）"),
        (false, true) => code.to_string(),
        (true, false) => msg.to_string(),
        (true, true) => short(body),
    };
    if need_login && !txt.contains("重新登录") {
        format!("{txt} ⇒ 会话失效，请在【配置中心】重新登录")
    } else {
        txt
    }
}

/// `res_code`（取址响应里逐字有这个字段）
fn res_code_of(v: &serde_json::Value) -> Option<i64> {
    match v.get("res_code").or_else(|| v.get("resCode"))? {
        serde_json::Value::Number(n) => n.as_i64(),
        serde_json::Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

/// 从响应里抽条目（**纯函数**；0 条 ⇒ `Err`）
///
/// # 分层**逐字**照 DEX：`fileListAO` → `folderList` / `fileList`
/// ```text
/// ★ 顺序先目录后文件 —— 这是参考实现的解析顺序（两个数组分开取）。
///   改了顺序会让"目录排在文件后面"，用户要翻很久才能钻进子目录。
/// ```
fn parse_entries(v: &serde_json::Value) -> Result<Vec<Entry>, String> {
    let Some(ao) = v.get("fileListAO") else {
        return Err(format!(
            "天翼 列目录响应里没有 fileListAO（可能改版/风控壳页）：{}",
            short(&v.to_string())
        ));
    };
    let mut out = Vec::new();
    // ① 目录
    if let Some(arr) = ao.get("folderList").and_then(|x| x.as_array()) {
        for it in arr {
            let id = str_of(it, &["id", "folderId"]);
            if id.is_empty() {
                continue; // 没 id 钻不进去 ⇒ 丢掉，不编
            }
            out.push(Entry {
                id,
                name: str_of(it, &["name", "folderName"]),
                is_dir: true,
                size: 0,
            });
        }
    }
    // ② 文件
    if let Some(arr) = ao.get("fileList").and_then(|x| x.as_array()) {
        for it in arr {
            let id = str_of(it, &["id", "fileId"]);
            if id.is_empty() {
                continue;
            }
            out.push(Entry {
                id,
                name: str_of(it, &["name", "fileName"]),
                is_dir: false,
                size: u64_of(it, &["size", "fileSize"]),
            });
        }
    }
    if out.is_empty() {
        return Err(format!(
            "天翼 列目录解析出 0 条（可能改版/风控壳页，也可能是空目录）：{}",
            short(&v.to_string())
        ));
    }
    Ok(out)
}

/// 条目 → UI 一行
///
/// ★ 文件 id 用参考实现的播放参数形状 `名字~!~id`：这样详情能显示真名，
///   而播放只需要最后一段（`split_param` 从右侧切）⇒ 不必再编一层编码。
fn item_of(e: &Entry) -> CspItem {
    let (id, subtitle) = if e.is_dir {
        (e.id.clone(), "目录".to_string())
    } else {
        (format!("{}{SEP}{}", e.name, e.id), human_size(e.size))
    };
    CspItem {
        id,
        title: e.name.clone(),
        cover: None,
        subtitle: Some(subtitle),
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

crate::csp::register_site!(PanTianyi);

#[cfg(test)]
mod tests {
    use super::*;

    /// **真实响应片段**（直连实测、无账号）：HTTP 400 + InvalidSessionKey
    ///
    /// ```text
    /// curl --noproxy '*' 'https://cloud.189.cn/api/open/file/listFiles.action?…'
    /// ⇒ 400 {"errorCode":"InvalidSessionKey","errorMsg":"cookieUserSession is null or invalid, cookieUserSession=null","success":null}
    /// ★ 参考实现只判 `fileListAO` 在不在 ⇒ 这种情况会被它显示成"目录内没有可播放的视频"
    ///   （把"没登录"误报成"目录空"）。本实现的判据是**状态码 + 错码**，已用这条真片段钉住。
    /// ```
    const LIVE_UNAUTH: &str = r#"{"errorCode":"InvalidSessionKey","errorMsg":"cookieUserSession is null or invalid, cookieUserSession=null","success":null}"#;

    /// **不是真网响应**：按 DEX 的 `fileListAO`/`folderList`/`fileList`/`name`/`id`/`size` 还原
    const DEX_SHAPE_OK: &str = r#"{"fileListAO":{
        "folderList":[{"id":"f01","name":"剧集目录"},{"name":"没有 id 的目录"}],
        "fileList":[{"id":"u01","name":"第一集.mp4","size":"734003200"},{"name":"没有 id 的文件"}]
    }}"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(PanTianyi::CLASS, "PanTianyi");
    }

    #[test]
    fn registration_is_present() {
        assert!(
            crate::csp::is_implemented("csp_PanTianyi"),
            "★ csp_PanTianyi 必须在注册表里（有 host 常量 + 订阅有站）"
        );
        let s = crate::csp::route("csp_PanTianyi").expect("必须能路由出实例");
        assert_eq!(s.class(), "PanTianyi");
        assert!(!s.supports_search());
    }

    #[test]
    fn visible_wording_matches_reference() {
        assert_eq!(LOGIN_HINT, "还未登录天翼账号,请前往【配置中心】登录");
        assert_eq!(SHELF_NAME, "我的天翼云盘");
        assert_eq!(PLAY_FAIL, "获取播放地址失败");
        for s in [LOGIN_HINT, SHELF_NAME, PLAY_FAIL] {
            assert!(!s.contains("**"), "★ 用户可见文案不许有 markdown 强调：{s}");
        }
        // 根目录 id 有逐字证据（首页常量里的 "-11"）
        assert_eq!(ROOT_FOLDER, "-11");
    }

    /// ★★ URL 逐字门禁（列目录：五段固定参数，顺序照 DEX）
    #[test]
    fn list_url_matches_reference_byte_for_byte() {
        assert_eq!(
            list_url("-11", 1, 100),
            "https://cloud.189.cn/api/open/file/listFiles.action?folderId=-11\
             &fileType=0&mediaType=0&iconOption=5\
             &orderBy=filename&descending=false\
             &pageNum=1&pageSize=100"
        );
        // 反空真：三个参数都要真的生效
        let u = list_url("f01", 3, 50);
        assert!(u.contains("folderId=f01"), "{u}");
        assert!(u.contains("pageNum=3"), "{u}");
        assert!(u.contains("pageSize=50"), "{u}");
    }

    /// ★★ 取址 URL 逐字（端点 + `&dt=1`）
    #[test]
    fn download_url_matches_reference_byte_for_byte() {
        assert_eq!(
            download_url("u01"),
            "https://cloud.189.cn/api/open/file/getFileDownloadUrl.action?fileId=u01&dt=1"
        );
        assert!(download_url("x9").contains("fileId=x9&dt=1"), "参数必须生效");
    }

    /// ★★ 真网读数：400 + InvalidSessionKey ⇒ 必须说"会话失效/重新登录"
    ///
    /// 注入验证：删掉 `business_reason` 里 need_login 那段 ⇒ 本条红 ——
    /// 用户只会看到一句 `cookieUserSession is null`（英文、且指不出动作）。
    #[test]
    fn live_unauth_fragment_tells_user_to_relogin() {
        let r = business_reason(LIVE_UNAUTH);
        assert!(r.contains("InvalidSessionKey"), "★ 带错码便于排障：{r}");
        assert!(r.contains("重新登录"), "★ 必须给出动作：{r}");
        // 非登录类错误不许乱说"重新登录"
        let r2 = business_reason(r#"{"errorCode":"FileNotFound","errorMsg":"no such file"}"#);
        assert!(r2.contains("no such file"), "{r2}");
        assert!(!r2.contains("重新登录"), "★ 别把别的错都说成登录问题：{r2}");
    }

    /// ★★ 分层/字段门禁：folderList 先、fileList 后；`name`/`id`/`size` 全读到
    #[test]
    fn parse_entries_reads_dex_layers_in_order() {
        let v = parse_json(DEX_SHAPE_OK).unwrap();
        let e = parse_entries(&v).unwrap();
        assert_eq!(e.len(), 2, "★ 没 id 的条目必须丢掉");
        assert!(e[0].is_dir, "★ 目录必须排在前面（照参考实现的解析顺序）");
        assert_eq!(e[0].id, "f01");
        assert_eq!(e[0].name, "剧集目录");
        assert!(!e[1].is_dir);
        assert_eq!(e[1].id, "u01");
        assert_eq!(e[1].size, 734003200, "★ size 是字符串也要能读");
    }

    /// ★★ 0 条 ⇒ Err（本仓硬约束）
    #[test]
    fn empty_list_is_error_not_empty_ok() {
        let v = parse_json(r#"{"fileListAO":{"folderList":[],"fileList":[]}}"#).unwrap();
        let e = parse_entries(&v).expect_err("★ 解析 0 条必须 Err，不许 Ok(vec![])");
        assert!(e.contains("改版") || e.contains("风控"), "{e}");
        // 连分层都没有（改版最典型的样子）也要 Err，并说清缺哪一层
        let e2 = parse_entries(&parse_json(r#"{"data":{}}"#).unwrap()).expect_err("必须 Err");
        assert!(e2.contains("fileListAO"), "{e2}");
    }

    #[test]
    fn html_intercept_is_reported_as_intercept() {
        let e = ensure_json_body("<html>502</html>", 502).expect_err("必须 Err");
        assert!(e.contains("HTML") && e.contains("拦截"), "{e}");
        assert!(ensure_json_body(r#"{"fileListAO":{}}"#, 200).is_ok());
    }

    /// ★★ 播放参数形状：`名字~!~id`，从右侧切 ⇒ 名字里含分隔符也安全
    #[test]
    fn play_param_shape_and_right_split() {
        let e = Entry {
            id: "u01".into(),
            name: "第 1 集.mp4".into(),
            is_dir: false,
            size: 2048,
        };
        let it = item_of(&e);
        assert_eq!(it.id, "第 1 集.mp4~!~u01");
        assert_eq!(it.subtitle.as_deref(), Some("2.0 KB"));

        let (n, fid) = split_param("第 1 集.mp4~!~u01");
        assert_eq!((n.as_str(), fid.as_str()), ("第 1 集.mp4", "u01"));
        let (n2, fid2) = split_param("怪~!~名字~!~u9");
        assert_eq!((n2.as_str(), fid2.as_str()), ("怪~!~名字", "u9"));
        // 没有分隔符 ⇒ 整串当 id（详情标题退化成 id）
        let (n3, fid3) = split_param("u77");
        assert_eq!((n3.as_str(), fid3.as_str()), ("", "u77"));
    }

    /// ★★ `res_code` 判据：0 才是成功（别的值都要带上上游原因）
    #[test]
    fn res_code_zero_is_success_only() {
        assert_eq!(res_code_of(&parse_json(r#"{"res_code":0}"#).unwrap()), Some(0));
        assert_eq!(res_code_of(&parse_json(r#"{"res_code":"0"}"#).unwrap()), Some(0));
        assert_eq!(res_code_of(&parse_json(r#"{"res_code":-1}"#).unwrap()), Some(-1));
        assert_eq!(res_code_of(&parse_json(r#"{}"#).unwrap()), None);
    }

    #[test]
    fn root_folder_defaults_to_evidence_value_and_ext_overrides() {
        assert_eq!(PanTianyi::root_folder(""), "-11");
        assert_eq!(PanTianyi::root_folder(r#"{"folder":"f99"}"#), "f99");
        assert_eq!(PanTianyi::root_folder("坏"), "-11");
    }

    /// ★★★ 无 cookie 时四条路径都必须如实报登录
    #[tokio::test]
    async fn without_cookie_every_path_says_login_not_empty() {
        if crate::pan_auth::load(PanKind::Tianyi).is_some() {
            eprintln!("本机钥匙串已有天翼凭据 ⇒ 跳过『无 cookie』用例（避免假绿/假红）");
            return;
        }
        let s = PanTianyi::new();
        assert_eq!(s.home("").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.list("-11", 1, "").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.detail("u01", "").await.expect_err("必须 Err"), LOGIN_HINT);
        assert_eq!(s.play("默认", "名字~!~u01", "").await.expect_err("必须 Err"), LOGIN_HINT);
    }

    #[tokio::test]
    async fn search_says_unsupported_not_empty_result() {
        let s = PanTianyi::new();
        let e = s.search("任意词", 1, "").await.expect_err("★ 必须 Err");
        assert!(e.contains("不支持搜索"), "{e}");
    }

    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("pan_tianyi.rs"));
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
