// ═══════════════════════════════════════════════════════════════════════
//  csp_PanGuangya —— 光鸭网盘（「我的网盘」形态：一格、两级取流）
// ═══════════════════════════════════════════════════════════════════════
//
// # 原版形状（DEX 常量逐字，未起 jadx）
//
// ```text
// 来源 `.probe/csp-parity/PanGuangya.txt`：
//   [listDir]   "parentId" "page" "pageSize" "orderBy" "sortType"
//               "https://api.guangyapan.com/userres/v1/file/get_file_list"
//               "success" "data" "list"          ← 响应：success 标志 + data.list
//   [signedUrl] "fileId"
//               "https://api.guangyapan.com/userres/v1/get_res_download_url"
//               "success" "data" "signedURL"     ← 直链字段叫 signedURL（大写 URL）
//   [<init>]    "fileId" "fileName" "resType" "fileSize"
//               （"folder" / "file" 两个 resType 取值）
//   [b]         "我的光鸭网盘"                      ← 首页**只有一个**分类
//               "还未登录光鸭账号,请前往【配置中心】登录"
//   [a]         "获取播放地址失败"
// ```
// ⇒ 两个端点、五个请求字段、三个响应字段、两句用户文案，全部逐字可复核。
//
// # ★ 真网读数（2026-10-28 08:0x +08，`--noproxy '*'` 直连）
//
// ```text
// ① POST https://api.guangyapan.com/userres/v1/file/get_file_list
//      体：{"parentId":"","page":1,"pageSize":50,"orderBy":"name","sortType":"asc"}
//    → HTTP 401 {"code":117,"msg":"无效token"}
// ② POST https://api.guangyapan.com/userres/v1/get_res_download_url  体：{"fileId":"1"}
//    → HTTP 401 {"code":117,"msg":"无效token"}
// ③ ★ 反面对照（证明"117 不是我不带某个特定头"）：分别试
//      accessToken / token / Authorization（裸与 Bearer）/ Cookie 五种带法
//    ⇒ **一律** 117。即服务端按**值**校验 token，无法据此反推是哪个头
//    ⇒ 头的名字**未取证**（本文件如实标注，不假装知道）。
//
// ⇒ 结论：端点活着（401 是业务码，不是 DNS/连接失败），只差**账号**。
// ```
//
// # 为什么**注册**（判例同 `pan_xunlei.rs`，也同 `pan_drive.rs` 的 PanQuark/PanUC）
//
// ```text
// 「我的网盘」这类源的内容就是用户自己的盘：没账号时"取不到"是**正确行为**，
// 原版也是这个行为（`[b]`/`[a]` 两句文案就是为它写的）。
// ⇒ 注册；首页（一格）不发网络，取数时报**逐字原版文案**。
// ⚠️ 若要改判（无账号不注册），删掉本文件末尾那一行 `register_site!` 即可。
// ```
//
// # 诚实边界
//
// ```text
// · 认证头的**名字**未取证（见上 ③）。本实现把 `pan_auth` 里的凭据当 `Cookie` 头发，
//   并在失败时把上游 `{"code":117,"msg":"无效token"}` **原样**带出来。
//   为什么要发 Cookie 而不是编一个 Bearer：本仓凭据模型只有 `cookie` 一个字段
//   （`PanCredential`，本批不许改 `pan_auth`）⇒ **不做超出凭据的猜测**。
// · `orderBy` / `sortType` 的**取值**未取证（DEX 只给了键名）。
//   ⇒ 用 name/asc，影响**仅排序**（不改协议形状），并在本条注释里标明未验。
// · 成功响应形状未验（无账号拿不到 200）⇒ 解析器按 DEX 键名写，**空 ⇒ Err**。
// ```

use async_trait::async_trait;
use std::time::Duration;

use crate::pan::PanKind;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 无凭据文案 —— **逐字**取自 DEX `[b]`
const LOGIN_HINT: &str = "还未登录光鸭账号,请前往【配置中心】登录";

/// 取流失败文案 —— **逐字**取自 DEX `[a]`
const PLAY_FAIL: &str = "获取播放地址失败";

/// 首页唯一那一格 —— **逐字**取自 DEX `[b]`
const ROOT_NAME: &str = "我的光鸭网盘";

/// 列目录端点（DEX 逐字）
const URL_LIST: &str = "https://api.guangyapan.com/userres/v1/file/get_file_list";

/// 取直链端点（DEX 逐字）
const URL_SIGNED: &str = "https://api.guangyapan.com/userres/v1/get_res_download_url";

/// 每页条数（DEX 只有键名 `pageSize`，没给值；50 是实测请求里用的值）
const PAGE_SIZE: u32 = 50;

const HTTP_TIMEOUT: Duration = Duration::from_secs(8);

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 列目录请求体（**纯函数**：字段名与顺序都要能逐字断言）
///
/// 字段顺序照 DEX 的常量出现顺序：parentId → page → pageSize → orderBy → sortType。
pub fn list_body(parent_id: &str, page: u32) -> String {
    format!(
        "{{\"parentId\":{},\"page\":{},\"pageSize\":{PAGE_SIZE},\"orderBy\":\"name\",\"sortType\":\"asc\"}}",
        serde_json::Value::String(parent_id.to_string()),
        if page == 0 { 1 } else { page }
    )
}

/// 取直链请求体（DEX：`fileId`）
pub fn signed_body(file_id: &str) -> String {
    format!(
        "{{\"fileId\":{}}}",
        serde_json::Value::String(file_id.to_string())
    )
}

/// 网盘条目
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GyFile {
    pub id: String,
    pub name: String,
    /// true = 目录（DEX：`resType` 取 `folder` / `file`）
    pub is_dir: bool,
    pub size: u64,
}

fn brief(s: &str) -> String {
    let t = s.trim();
    let cut = t.char_indices().nth(160).map(|(i, _)| i).unwrap_or(t.len());
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

/// 信封判定：非 0 业务码 / `success:false` 都是失败
///
/// # 为什么要两种都看
/// ```text
/// 实测失败形态是 `{"code":117,"msg":"无效token"}`（**没有** success 字段）；
/// 而 DEX 里成功路径读的是 `success` ⇒ 两种形态都存在。
/// ⇒ 只看一种会把另一种当成功（静默空数据）。
/// ```
fn check(v: &serde_json::Value, http: u16) -> Result<(), String> {
    let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(0);
    let msg = v.get("msg").and_then(|m| m.as_str()).unwrap_or("");
    if code != 0 {
        return Err(format!("光鸭返回业务错误（HTTP {http} code={code}）：{msg}"));
    }
    let success = v.get("success").and_then(|s| s.as_bool());
    if success == Some(false) {
        let m = v
            .get("message")
            .and_then(|m| m.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(msg);
        return Err(format!(
            "光鸭返回 success=false（HTTP {http}）：{}{m}",
            if m.is_empty() { "无 message" } else { "" }
        ));
    }
    Ok(())
}

/// 从 `data.list` 抽条目（DEX：`data` → `list`；条目键 `fileId`/`fileName`/`resType`/`fileSize`）
fn parse_list(v: &serde_json::Value) -> Vec<GyFile> {
    let Some(arr) = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array())
    else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let id = it.get("fileId").and_then(|x| x.as_str()).unwrap_or("").to_string();
        if id.is_empty() {
            continue;
        }
        out.push(GyFile {
            id,
            name: it
                .get("fileName")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string(),
            is_dir: it
                .get("resType")
                .and_then(|x| x.as_str())
                .map(|t| t == "folder")
                .unwrap_or(false),
            size: it.get("fileSize").and_then(|x| x.as_u64()).unwrap_or(0),
        });
    }
    out
}

/// 直链（DEX：`data` → `signedURL`）
fn parse_signed(v: &serde_json::Value) -> Option<String> {
    let u = v
        .get("data")
        .and_then(|d| d.get("signedURL"))
        .and_then(|x| x.as_str())
        .unwrap_or("");
    if u.trim().is_empty() {
        None
    } else {
        Some(u.to_string())
    }
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

/// csp_PanGuangya
pub struct PanGuangya {
    client: reqwest::Client,
}

impl PanGuangya {
    pub const CLASS: &'static str = "PanGuangya";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("HTTP client 构建失败（TLS 后端不可用）—— 不许退回无 no_proxy 的兜底");
        Self { client }
    }

    fn cookie(&self) -> Option<String> {
        crate::pan_auth::load(PanKind::Guangya).map(|c| c.cookie)
    }

    /// POST 一个 JSON 体并做信封判定
    async fn post_json(
        &self,
        cookie: &str,
        url: &str,
        body: &str,
    ) -> Result<serde_json::Value, String> {
        let resp = self
            .client
            .post(url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/plain, */*")
            .header("Cookie", cookie)
            .body(body.to_string())
            .send()
            .await
            .map_err(|e| format!("光鸭请求失败：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        let v: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| format!("光鸭返回的不是 JSON（{e}）：{}", brief(&text)))?;
        check(&v, status.as_u16())?;
        Ok(v)
    }
}

impl Default for PanGuangya {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for PanGuangya {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页 = 一格（DEX `[b]`）⇒ 不发网络
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        Ok(CspHome {
            categories: vec![CspCategory {
                id: "0".to_string(),
                name: ROOT_NAME.to_string(),
            }],
            items: Vec::new(),
        })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let Some(cookie) = self.cookie() else {
            return Err(LOGIN_HINT.to_string());
        };
        let parent = if tid.trim().is_empty() || tid.trim() == "0" {
            ""
        } else {
            tid.trim()
        };
        let v = self
            .post_json(&cookie, URL_LIST, &list_body(parent, page))
            .await?;
        let files = parse_list(&v);
        if files.is_empty() {
            return Err(format!(
                "目录（parentId={parent}）一条都没解析到 —— 可能是凭据无效，\
                 或响应形状改了（不是「这个目录是空的」）"
            ));
        }
        let items = files
            .into_iter()
            .map(|f| CspItem {
                id: f.id,
                title: f.name,
                cover: None,
                subtitle: Some(if f.is_dir {
                    "目录".to_string()
                } else {
                    human_size(f.size)
                }),
            })
            .collect();
        Ok(CspList {
            items,
            page: if page == 0 { 1 } else { page },
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        if self.cookie().is_none() {
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
    /// 依据：未登录必然 Err（真网读数：401 code=117 无效 token）
    /// ⇒ 默认不自动暴露（用户导入带 ext 的站点时照常出现）。
    fn needs_ext(&self) -> bool {
        true
    }


    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("光鸭网盘不支持搜索（它只列你自己的网盘目录）".to_string())
    }

    /// 取流：`get_res_download_url` ⇒ `data.signedURL`
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let Some(cookie) = self.cookie() else {
            return Err(LOGIN_HINT.to_string());
        };
        match self.post_json(&cookie, URL_SIGNED, &signed_body(id)).await {
            Err(e) => Err(format!("{PLAY_FAIL}：{e}")),
            Ok(v) => match parse_signed(&v) {
                Some(url) => Ok(vec![CspPlay {
                    url,
                    // signedURL 自带签名，但仍按同族惯例带 UA/Referer（未验是否会 403）
                    headers: vec![
                        ("User-Agent".to_string(), UA.to_string()),
                        ("Referer".to_string(), "https://www.guangyapan.com/".to_string()),
                    ],
                    label: Some("光鸭网盘".to_string()),
                }]),
                None => Err(format!(
                    "{PLAY_FAIL}：响应里没有 data.signedURL（{}）",
                    brief(&v.to_string())
                )),
            },
        }
    }
}

crate::csp::register_site!(PanGuangya);

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★★ 真实响应片段（2026-10-28 08:0x 实测，逐字）
    ///
    /// ```text
    /// 两个端点各一次，都是 HTTP 401 + 同一个业务码。
    /// 注入验证：把 `check` 里的 `code != 0` 分支删掉 ⇒ 本条红
    ///   （117 会被当成成功 ⇒ 用户看到空目录而不是"token 无效"）。
    /// ```
    #[test]
    fn real_token_error_is_reported_with_code_and_message() {
        let body = r#"{"code":117,"msg":"无效token"}"#;
        let v: serde_json::Value = serde_json::from_str(body).unwrap();
        let e = check(&v, 401).expect_err("117 必须判失败");
        assert!(e.contains("117"), "要带上业务码：{e}");
        assert!(e.contains("无效token"), "要带上上游文案：{e}");
        assert!(e.contains("401"), "要带上 HTTP 码：{e}");
        // 成功形态（`success:true` + data）不该被判错
        let ok: serde_json::Value =
            serde_json::from_str(r#"{"success":true,"data":{"list":[]}}"#).unwrap();
        assert!(check(&ok, 200).is_ok());
        // `success:false` 即使 code=0 也必须失败
        let bad: serde_json::Value =
            serde_json::from_str(r#"{"success":false,"message":"没有权限"}"#).unwrap();
        let e2 = check(&bad, 200).expect_err("success=false 必须失败");
        assert!(e2.contains("没有权限"), "{e2}");
    }

    /// ★★ 请求体逐字（字段名是协议，猜错就是"另一种协议"）
    #[test]
    fn request_bodies_match_dex_field_names() {
        assert_eq!(
            list_body("", 1),
            r#"{"parentId":"","page":1,"pageSize":50,"orderBy":"name","sortType":"asc"}"#
        );
        assert!(list_body("PID-1", 3).contains(r#""parentId":"PID-1""#));
        assert!(list_body("x", 3).contains(r#""page":3"#));
        assert_eq!(signed_body("F9"), r#"{"fileId":"F9"}"#);
    }

    /// 端点常量必须逐字（DEX）
    #[test]
    fn endpoints_are_dex_verbatim() {
        assert_eq!(URL_LIST, "https://api.guangyapan.com/userres/v1/file/get_file_list");
        assert_eq!(URL_SIGNED, "https://api.guangyapan.com/userres/v1/get_res_download_url");
    }

    /// 条目解析：`resType` 的 `folder`/`file` 决定能不能点进去
    ///
    /// ⚠️ 键名来自 DEX 字面量；**成功响应本身未验**（无账号）—— 见文件头。
    #[test]
    fn parses_list_by_res_type() {
        let body = r#"{"success":true,"data":{"list":[
            {"fileId":"F1","fileName":"a.mp4","resType":"file","fileSize":1048576},
            {"fileId":"D1","fileName":"合集","resType":"folder","fileSize":0},
            {"fileName":"没有 id","resType":"file"}]}}"#;
        let v: serde_json::Value = serde_json::from_str(body).unwrap();
        let f = parse_list(&v);
        assert_eq!(f.len(), 2, "★ 没 fileId 的条目必须丢掉");
        assert!(!f[0].is_dir && f[0].id == "F1");
        assert_eq!(human_size(f[0].size), "1.0 MB");
        assert!(f[1].is_dir, "★ resType=folder 必须是目录");
    }

    /// 直链解析：缺 `signedURL` ⇒ None（由 play 报"获取播放地址失败"）
    #[test]
    fn signed_url_is_required() {
        let ok: serde_json::Value =
            serde_json::from_str(r#"{"success":true,"data":{"signedURL":"https://x/y?sig=1"}}"#)
                .unwrap();
        assert_eq!(parse_signed(&ok).as_deref(), Some("https://x/y?sig=1"));
        let empty: serde_json::Value =
            serde_json::from_str(r#"{"success":true,"data":{"signedURL":"  "}}"#).unwrap();
        assert_eq!(parse_signed(&empty), None, "★ 空白不算地址（不许伪造）");
        let none: serde_json::Value = serde_json::from_str(r#"{"success":true,"data":{}}"#).unwrap();
        assert_eq!(parse_signed(&none), None);
    }

    /// ★★★ 空结果 ⇒ Err
    #[tokio::test]
    async fn empty_listing_is_an_error() {
        if crate::pan_auth::load(PanKind::Guangya).is_some() {
            eprintln!("本机已有光鸭凭据 ⇒ 跳过『空响应』用例");
            return;
        }
        let e = PanGuangya::new().list("0", 1, "").await.expect_err("必须 Err");
        assert_eq!(e, LOGIN_HINT);
        let v: serde_json::Value =
            serde_json::from_str(r#"{"success":true,"data":{"list":[]}}"#).unwrap();
        assert!(parse_list(&v).is_empty());
        let bad: serde_json::Value = serde_json::from_str("{}").unwrap();
        assert!(parse_list(&bad).is_empty());
    }

    /// ★★ 首页一格 + 文案逐字
    #[tokio::test]
    async fn home_is_one_category_and_wording_is_verbatim() {
        let h = PanGuangya::new().home("").await.unwrap();
        assert_eq!(h.categories.len(), 1);
        assert_eq!(h.categories[0].name, "我的光鸭网盘");
        assert_eq!(ROOT_NAME, "我的光鸭网盘");
        assert_eq!(LOGIN_HINT, "还未登录光鸭账号,请前往【配置中心】登录");
        assert_eq!(PLAY_FAIL, "获取播放地址失败");
    }

    /// ★★★ 无账号：list/detail/play 全部**可读 Err**，且不含 URL
    #[tokio::test]
    async fn every_path_without_account_says_login() {
        if crate::pan_auth::load(PanKind::Guangya).is_some() {
            eprintln!("已有光鸭凭据 ⇒ 跳过『无账号』用例");
            return;
        }
        let s = PanGuangya::new();
        for (what, r) in [
            ("list", s.list("0", 1, "").await.err()),
            ("detail", s.detail("F1", "").await.err()),
            ("play", s.play("", "F1", "").await.err()),
        ] {
            let e = r.unwrap_or_else(|| panic!("★ {what} 无账号时必须 Err"));
            assert_eq!(e, LOGIN_HINT, "★ {what} 文案必须与原版逐字一致");
            assert!(!e.contains("http"), "★★ {what} 不许出现 URL：{e}");
        }
    }

    /// 类名/注册/搜索契约
    #[test]
    fn class_contract() {
        assert_eq!(PanGuangya::CLASS, "PanGuangya");
        assert_eq!(PanGuangya::new().class(), "PanGuangya");
        assert!(
            crate::csp::implemented_classes().contains(&"PanGuangya"),
            "★ 已自注册 ⇒ 注册表里必须有它"
        );
        assert!(!PanGuangya::new().supports_search());
    }

    #[tokio::test]
    async fn search_is_an_explicit_error() {
        let e = PanGuangya::new().search("x", 1, "").await.expect_err("必须 Err");
        assert!(e.contains("不支持搜索"), "{e}");
    }
}
