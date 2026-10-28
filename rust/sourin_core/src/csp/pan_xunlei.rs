// ═══════════════════════════════════════════════════════════════════════
//  csp_PanXunlei —— 迅雷云盘（「我的网盘」形态：一格、两级取流）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在原版里是什么形状（DEX 常量逐字，未起 jadx）
//
// ```text
// 来源 `.probe/csp-parity/PanXunlei.txt`（`.probe/dex_const_strings.py` 直读 class_def）：
//   [listDir]  "GET:/drive/v1/files"          ← 方法名里自带方法 + 路径
//              "https://api-pan.xunlei.com/drive/v1/files"
//              "?space=&thumbnail_size=SIZE_LARGE"  "&limit="  "&parent_id="
//              "&filters=%7B%22trashed%22%3A%7B%22eq%22%3Afalse%7D%7D"  "&page_token="
//              "error"  "files"  "next_page_token"     ← 响应里要读的键
//   [link]     "GET:/drive/v1/files/"          ← 单个文件 = 取播放地址
//              "https://api-pan.xunlei.com/drive/v1/files/"
//              "?space=&usage=PLAY&thumbnail_size=SIZE_LARGE"
//              "error"  "web_content_link"
//   [auth]     "x-captcha-token"               ← 认证要带这个头
//   [i]/[j]    "kind"  "drive#folder"  "name"  "file"   ← 条目形状
//   [k]        "我的迅雷云盘"                    ← 首页**只有一个**分类
//              "还未登录迅雷账号,请前往【配置中心】登录"   ← 无凭据时的文案（逐字）
//   [q]        "获取播放地址失败"                ← 取流失败文案（逐字）
// ```
//
// # ★ 真网读数（2026-10-28 08:0x +08，`--noproxy '*'` 直连，本文件落盘前实测）
//
// ```text
// ① 裸调列目录
//    GET https://api-pan.xunlei.com/drive/v1/files?space=&thumbnail_size=SIZE_LARGE
//        &limit=50&parent_id=&filters=…&page_token=
//    → HTTP 400 {"error":"invalid_argument","error_code":3,
//               "error_description":"请求参数错误",
//               "error_details":[{"detail":"device_id is empty"}, …]}
//    ⇒ 第一道门是 **device_id**
// ② 补一个 `x-device-id: <uuid4>` 再调 → **同一接口**换成
//    HTTP 400 {"error":"captcha_invalid","error_code":9,
//              "error_description":"验证码无效",
//              "error_details":[{"detail":"captcha_token is empty"}, …]}
//    ⇒ 第二道门正是 DEX `[auth]` 里那个 **x-captcha-token**
// ③ ⇒ 端点、方法（GET）、query 形状、两道门都被真网确认；
//    再往上就是**账号**（device-code 登录 + 验证码），本机没有 ⇒ 到此为止。
// ```
//
// # 为什么**注册**（与"12 个类只实现不注册"的分界在哪）
//
// ```text
// 本仓 `2026-10-28-csp-25-classes-implement-vs-register.md` 的判据③要求"真网取到数据"。
// 但网盘族的**东西就是用户自己的盘**——没有账号时，"取不到数据"是**正确行为**，
// 而不是"这个源是死的"：原版同样如此（`[k]`/`[q]` 两句文案就是为这个场景写的）。
// 本仓已有同判例：`pan_drive.rs` 的 PanQuark / PanUC 就是"注册了但要登录"。
// ⇒ 本类按同一判例**注册**：首页（一格）不需要网络，取数时报**逐字原版文案**。
//    ⚠️ 若将来采用更严的判据（无账号 ⇒ 不注册），只需删掉本文件末尾那一行
//       `register_site!`，代码一个字都不用改（本文件头部已标明）。
// ```
//
// # 诚实边界
//
// ```text
// · `x-device-id`：DEX 里**没有**这个头的字面量（它只出现在真网错误里）。
//   本实现从凭据 cookie 里找（`deviceid=` / `device_id=`），找不到就**不发**这个头
//   —— 让上游照原样报 `device_id is empty`，而不是自己编一个 id 去撞 200。
// · `x-captcha-token`：`pan_auth` 的凭据只存 cookie（`PanCredential` 没有 token 字段，
//   本批不许改 `pan_auth`）⇒ 从 cookie 里找 `captcha_token=`/`x-captcha-token=`，
//   找不到就发空串 ⇒ 上游会明确回 `captcha_token is empty`（可读、可追）。
// · 列表/取流的响应**成功形状未验**（没有账号，拿不到 200）。
//   ⇒ 解析器按 DEX 逐字键名（`files` / `next_page_token` / `kind` / `name` /
//     `web_content_link`）写，并在测试里用"未验"标记；**空 ⇒ Err**，绝不返回空列表冒充成功。
// ```

use async_trait::async_trait;
use std::time::Duration;

use crate::pan::PanKind;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 无凭据文案 —— **逐字**取自 DEX `[k]`（用户看到的话不该变）
const LOGIN_HINT: &str = "还未登录迅雷账号,请前往【配置中心】登录";

/// 取流失败文案 —— **逐字**取自 DEX `[q]`
const PLAY_FAIL: &str = "获取播放地址失败";

/// 首页唯一那一格的名字 —— **逐字**取自 DEX `[k]`
const ROOT_NAME: &str = "我的迅雷云盘";

/// API 根（DEX `[listDir]`/`[link]` 逐字）
const API: &str = "https://api-pan.xunlei.com/drive/v1/files";

/// 每页条数（DEX 只给了 `&limit=`，没给数值；50 是实测时用的值，未验对上游的含义）
const PAGE_SIZE: u32 = 50;

const HTTP_TIMEOUT: Duration = Duration::from_secs(8);

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 列目录的 URL（**纯函数**：URL 拼错不会报错，只会让结果不对 ⇒ 必须能逐字断言）
///
/// 逐字照 DEX 的拼接顺序：`?space=&thumbnail_size=SIZE_LARGE` 打头，
/// 再接 `&limit=` / `&parent_id=` / `&filters=`（**已编码**的 JSON）/ `&page_token=`。
pub fn list_url(parent_id: &str, page_token: &str) -> String {
    format!(
        "{API}?space=&thumbnail_size=SIZE_LARGE&limit={PAGE_SIZE}\
         &parent_id={parent_id}\
         &filters=%7B%22trashed%22%3A%7B%22eq%22%3Afalse%7D%7D\
         &page_token={page_token}"
    )
}

/// 取播放地址的 URL（DEX `[link]` 逐字：`/files/<id>?space=&usage=PLAY&thumbnail_size=SIZE_LARGE`）
pub fn link_url(file_id: &str) -> String {
    format!("{API}/{file_id}?space=&usage=PLAY&thumbnail_size=SIZE_LARGE")
}

/// 云盘里的一个条目
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanFile {
    pub id: String,
    pub name: String,
    /// true = 目录（DEX `[i]`：`kind` 为 `drive#folder` 时是目录）
    pub is_dir: bool,
    /// 文件大小（DEX 里**没有** size 的字面量 ⇒ 只认响应里真有的 `size`，拿不到就 0）
    pub size: u64,
}

/// 摘要
fn brief(s: &str) -> String {
    let t = s.trim();
    let cut = t.char_indices().nth(160).map(|(i, _)| i).unwrap_or(t.len());
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

/// 上游错误的可读文本
///
/// # 为什么要把 `error_details` 里的 `detail` 也挖出来
/// ```text
/// 实测两条错误都是 `error_description` = "请求参数错误"/"验证码无效"（**很泛**），
/// 真正的定位信息在 `error_details[].detail`：
///     "device_id is empty" / "captcha_token is empty"
/// ⇒ 只报前者，用户/开发者会以为是"参数写错了"，其实缺的是一个**具体的头**。
/// ```
fn upstream_error(v: &serde_json::Value) -> Option<String> {
    let err = v.get("error").and_then(|x| x.as_str()).unwrap_or("");
    if err.is_empty() {
        return None;
    }
    let desc = v
        .get("error_description")
        .and_then(|x| x.as_str())
        .unwrap_or("");
    let detail = v
        .get("error_details")
        .and_then(|x| x.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|d| d.get("detail").and_then(|x| x.as_str()))
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" / ")
        })
        .unwrap_or_default();
    let code = v.get("error_code").and_then(|x| x.as_i64());
    let mut s = format!("{err}");
    if let Some(c) = code {
        s.push_str(&format!("（error_code={c}）"));
    }
    if !desc.is_empty() {
        s.push_str(&format!("：{desc}"));
    }
    if !detail.is_empty() {
        s.push_str(&format!("［{detail}］"));
    }
    Some(s)
}

/// 从响应里抽条目（`files` 在顶层；`data.files` 是**兜底**，见文件头"诚实边界"）
fn parse_files(v: &serde_json::Value) -> Vec<PanFile> {
    let arr = v
        .get("files")
        .and_then(|x| x.as_array())
        .or_else(|| v.get("data").and_then(|d| d.get("files")).and_then(|x| x.as_array()));
    let Some(arr) = arr else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let id = it.get("id").and_then(|x| x.as_str()).unwrap_or("").to_string();
        if id.is_empty() {
            continue; // 没 id 的条目进不了详情/取流
        }
        out.push(PanFile {
            id,
            name: it.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            is_dir: it
                .get("kind")
                .and_then(|x| x.as_str())
                .map(|k| k == "drive#folder")
                .unwrap_or(false),
            size: it.get("size").and_then(|x| x.as_u64()).unwrap_or(0),
        });
    }
    out
}

/// 取流响应里的直链（DEX `[link]`：`web_content_link`）
fn parse_link(v: &serde_json::Value) -> Option<String> {
    let link = v
        .get("web_content_link")
        .and_then(|x| x.as_str())
        .or_else(|| {
            v.get("data")
                .and_then(|d| d.get("web_content_link"))
                .and_then(|x| x.as_str())
        })
        .unwrap_or("");
    if link.trim().is_empty() {
        None
    } else {
        Some(link.to_string())
    }
}

/// 从 cookie 里挑一个头的值（`k=v; k2=v2` 形状）
///
/// ★ 只在**凭据已经给到**的情况下做"值搬运"，不是猜协议：
///   我们不知道上游要不要这个头，但**知道**不能自己编值 ⇒ 找不到就不发（见文件头）。
fn cookie_value(cookie: &str, keys: &[&str]) -> Option<String> {
    for part in cookie.split(';') {
        let part = part.trim();
        let Some((k, v)) = part.split_once('=') else {
            continue;
        };
        if keys.iter().any(|want| k.trim().eq_ignore_ascii_case(want)) && !v.trim().is_empty() {
            return Some(v.trim().to_string());
        }
    }
    None
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

/// csp_PanXunlei
pub struct PanXunlei {
    client: reqwest::Client,
}

impl PanXunlei {
    pub const CLASS: &'static str = "PanXunlei";

    pub fn new() -> Self {
        // 与全仓同一条纪律：`.timeout()` 之后、`.build()` 之前关代理
        // （门禁 `tests/zz_r3i_no_proxy_consistency.rs` 会扫）。
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("HTTP client 构建失败（TLS 后端不可用）—— 不许退回无 no_proxy 的兜底");
        Self { client }
    }

    /// 凭据（每次现读：扫码/device-code 完成后立刻生效，不必重启）
    fn cookie(&self) -> Option<String> {
        crate::pan_auth::load(PanKind::Xunlei).map(|c| c.cookie)
    }

    /// 带认证头发一次 GET
    async fn get_json(&self, cookie: &str, url: &str) -> Result<serde_json::Value, String> {
        let mut req = self
            .client
            .get(url)
            .header("Cookie", cookie)
            .header("Accept", "application/json, text/plain, */*")
            .header("Referer", "https://pan.xunlei.com/");
        // ★ 这两个头**只在凭据里有值时**才发；没有就让它缺着，
        //   上游会明确回 `device_id is empty` / `captcha_token is empty`（实测）。
        if let Some(d) = cookie_value(cookie, &["deviceid", "device_id"]) {
            req = req.header("x-device-id", d);
        }
        if let Some(t) = cookie_value(cookie, &["x-captcha-token", "captcha_token"]) {
            req = req.header("x-captcha-token", t);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| format!("迅雷云盘请求失败：{e}"))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        let v: serde_json::Value = serde_json::from_str(&body)
            .map_err(|e| format!("迅雷云盘返回的不是 JSON（{e}）：{}", brief(&body)))?;
        if let Some(e) = upstream_error(&v) {
            return Err(format!("迅雷云盘返回错误（HTTP {status}）：{e}"));
        }
        if !status.is_success() {
            return Err(format!("迅雷云盘返回 HTTP {status}：{}", brief(&body)));
        }
        Ok(v)
    }
}

impl Default for PanXunlei {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for PanXunlei {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页 = **一格**（DEX `[k]` 只有"我的迅雷云盘"一个名字）⇒ 不发网络
    ///
    /// # 为什么这里不报"未登录"
    /// ```text
    /// 分类表是**常量**（原版 homeContent 就返回这一格）。
    /// 若首页直接报错，用户连"这个源存在"都看不到；
    /// 而原版的行为是"进得去、点开才说要登录"。
    /// ```
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        Ok(CspHome {
            categories: vec![CspCategory {
                id: "0".to_string(),
                name: ROOT_NAME.to_string(),
            }],
            items: Vec::new(),
        })
    }

    /// 列表：`tid` = 父目录 id（`"0"` = 根）
    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let Some(cookie) = self.cookie() else {
            return Err(LOGIN_HINT.to_string());
        };
        let parent = if tid.trim().is_empty() || tid.trim() == "0" {
            ""
        } else {
            tid.trim()
        };
        // 分页：接口用 `page_token`（不是页码）⇒ 第 1 页给空串；
        // 更深页需要上一页返回的 token，本实现没把它带到 tid 里 ⇒ 如实只取第一页。
        if page > 1 {
            return Err(format!(
                "迅雷云盘的翻页要用上一页返回的 page_token（不是页码）⇒ 目前只取第 1 页，\
                 第 {page} 页取不到"
            ));
        }
        let v = self.get_json(&cookie, &list_url(parent, "")).await?;
        let files = parse_files(&v);
        if files.is_empty() {
            return Err(format!(
                "目录（parent_id={parent}）一条都没解析到 —— 可能是凭据失效，\
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
            page: 1,
            page_count: None,
            total: None,
        })
    }

    /// 详情：云盘条目没有剧集概念 ⇒ 包成 1 集
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

    /// ★ 不支持搜索（原版该类没有搜索入口，只有"我的网盘"一棵树）
    fn supports_search(&self) -> bool {
        false
    }
    /// ★ 2026-10-28（Owner：「要逐类标注」）：本类**不填 ext 不能用**
    ///
    /// 依据：未登录必然 Err（真网读数：device_id / captcha_token 缺失）
    /// ⇒ 默认不自动暴露（用户导入带 ext 的站点时照常出现）。
    fn needs_ext(&self) -> bool {
        true
    }


    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("迅雷云盘不支持搜索（它只列你自己的网盘目录）".to_string())
    }

    /// 取流：`GET /drive/v1/files/<id>?space=&usage=PLAY…` ⇒ `web_content_link`
    ///
    /// # 无账号时的语义（本仓硬约束：不许把"没拿到"说成"没内容"）
    /// ```text
    /// 先撞登录闸 ⇒ 逐字原版文案。有凭据但取不到 ⇒ 逐字 `获取播放地址失败` + 上游原因。
    /// **绝不**返回一个分享页/m3u8 冒充地址（那只会让用户点进去 404）。
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let Some(cookie) = self.cookie() else {
            return Err(LOGIN_HINT.to_string());
        };
        match self.get_json(&cookie, &link_url(id)).await {
            Err(e) => Err(format!("{PLAY_FAIL}：{e}")),
            Ok(v) => match parse_link(&v) {
                Some(url) => Ok(vec![CspPlay {
                    url,
                    // 迅雷的直链绑 UA/Referer 一族，缺了常见 403 ⇒ 一并交给播放器
                    headers: vec![
                        ("User-Agent".to_string(), UA.to_string()),
                        ("Referer".to_string(), "https://pan.xunlei.com/".to_string()),
                    ],
                    label: Some("迅雷云盘".to_string()),
                }]),
                None => Err(format!(
                    "{PLAY_FAIL}：响应里没有 web_content_link（{}）",
                    brief(&v.to_string())
                )),
            },
        }
    }
}

crate::csp::register_site!(PanXunlei);

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★★ 真实错误响应片段（2026-10-28 08:0x 实测两连，逐字）
    ///
    /// ```text
    /// 这两条是**本类唯一的真网证据**，也是"两道门"的证据：
    ///   ① 裸调 ⇒ device_id is empty
    ///   ② 补 x-device-id ⇒ captcha_token is empty（对上了 DEX 的 x-captcha-token）
    /// 注入验证：把 `upstream_error` 里挖 `error_details[].detail` 那段删掉
    ///   ⇒ 本条红（用户只会看到"请求参数错误"这种无法行动的文案）。
    /// ```
    #[test]
    fn real_captured_errors_say_which_header_is_missing() {
        let bare = r#"{"error":"invalid_argument","error_code":3,"error_url":"",
            "error_description":"请求参数错误","error_details":[
            {"@type":"type.googleapis.com/google.rpc.DebugInfo","stack_entries":[],"detail":"device_id is empty"},
            {"@type":"type.googleapis.com/google.rpc.LocalizedMessage","locale":"zh-cn","message":"请求参数错误"}],
            "details":[]}"#;
        let v: serde_json::Value = serde_json::from_str(bare).unwrap();
        let e = upstream_error(&v).expect("必须识别为错误");
        assert!(e.contains("invalid_argument"), "{e}");
        assert!(e.contains("device_id is empty"), "★ 必须挖出具体缺哪个头：{e}");
        assert!(e.contains("3"), "要带上 error_code：{e}");

        let with_dev = r#"{"error":"captcha_invalid","error_code":9,"error_url":"",
            "error_description":"验证码无效","error_details":[
            {"detail":"captcha_token is empty"},
            {"message":"验证码无效"}],"details":[]}"#;
        let v2: serde_json::Value = serde_json::from_str(with_dev).unwrap();
        let e2 = upstream_error(&v2).unwrap();
        assert!(e2.contains("captcha_token is empty"), "{e2}");
        assert!(
            e2.contains("captcha_invalid"),
            "★ 第二道门要能被单独认出（它和第一道是不同错误）：{e2}"
        );
    }

    /// 正常响应**不该**被判成错误（否则永远取不到数据）
    #[test]
    fn success_body_is_not_an_error() {
        let ok = r#"{"kind":"drive#fileList","next_page_token":"","files":[]}"#;
        let v: serde_json::Value = serde_json::from_str(ok).unwrap();
        assert_eq!(upstream_error(&v), None);
    }

    /// ★★ URL 逐字门禁（DEX `[listDir]` / `[link]`）
    #[test]
    fn urls_match_dex_byte_for_byte() {
        let u = list_url("", "");
        assert!(
            u.starts_with(
                "https://api-pan.xunlei.com/drive/v1/files?space=&thumbnail_size=SIZE_LARGE&limit=50&parent_id=&filters=%7B%22trashed%22%3A%7B%22eq%22%3Afalse%7D%7D&page_token="
            ),
            "★ 与 DEX 不逐字：{u}"
        );
        let u2 = list_url("P123", "TOK");
        assert!(u2.contains("parent_id=P123") && u2.contains("page_token=TOK"), "{u2}");
        let l = link_url("F1");
        assert_eq!(
            l,
            "https://api-pan.xunlei.com/drive/v1/files/F1?space=&usage=PLAY&thumbnail_size=SIZE_LARGE",
            "★ 取流 URL 必须逐字（usage=PLAY 是关键参数）"
        );
    }

    /// 条目解析：`kind=drive#folder` ⇒ 目录；`drive#file` ⇒ 文件
    ///
    /// ⚠️ 本夹具的键名来自 DEX 字面量，**成功响应本身未验**（无账号）——
    ///    这一点在文件头"诚实边界"里已写明；解析器只在**空**时影响用户（会 Err）。
    #[test]
    fn parses_files_by_dex_keys() {
        let body = r#"{"kind":"drive#fileList","next_page_token":"NEXT","files":[
            {"id":"F1","name":"a.mkv","kind":"drive#file","size":734003200},
            {"id":"D1","name":"电影","kind":"drive#folder"},
            {"name":"没有 id 的条目","kind":"drive#file"}]}"#;
        let v: serde_json::Value = serde_json::from_str(body).unwrap();
        let f = parse_files(&v);
        assert_eq!(f.len(), 2, "★ 没 id 的条目必须丢掉");
        assert_eq!(f[0].id, "F1");
        assert!(!f[0].is_dir, "drive#file 不是目录");
        assert_eq!(human_size(f[0].size), "700.0 MB");
        assert!(f[1].is_dir, "★ drive#folder 必须是目录（否则用户点不进去）");
    }

    /// ★★★ 空结果 ⇒ Err（硬约束一：不许把"没解析到"当"目录是空的"）
    #[tokio::test]
    async fn empty_listing_is_an_error() {
        if crate::pan_auth::load(PanKind::Xunlei).is_some() {
            eprintln!("本机已有迅雷凭据 ⇒ 跳过『空响应』用例（避免假红）");
            return;
        }
        // 无凭据时先撞登录闸；这同样是"必须 Err"
        let e = PanXunlei::new().list("0", 1, "").await.expect_err("必须 Err");
        assert_eq!(e, LOGIN_HINT);
        // 空解析的判据（纯函数层面，不依赖凭据）
        let v: serde_json::Value = serde_json::from_str(r#"{"files":[]}"#).unwrap();
        assert!(parse_files(&v).is_empty());
        let bad: serde_json::Value = serde_json::from_str("{}").unwrap();
        assert!(parse_files(&bad).is_empty(), "结构不对也是空 ⇒ 由调用方 Err");
    }

    /// ★★ 首页只一格，且**不发网络**（DEX `[k]` 逐字）
    #[tokio::test]
    async fn home_is_one_category_verbatim() {
        let h = PanXunlei::new().home("").await.unwrap();
        assert_eq!(h.categories.len(), 1);
        assert_eq!(h.categories[0].name, "我的迅雷云盘");
        assert!(h.items.is_empty());
    }

    /// ★★ 文案逐字门禁（用户可见的话不许漂）
    #[test]
    fn user_visible_wording_matches_reference_verbatim() {
        assert_eq!(LOGIN_HINT, "还未登录迅雷账号,请前往【配置中心】登录");
        assert_eq!(PLAY_FAIL, "获取播放地址失败");
        assert_eq!(ROOT_NAME, "我的迅雷云盘");
    }

    /// ★★★ 无账号时 play/detail 都必须**可读 Err**，且**不含 URL**
    #[tokio::test]
    async fn play_without_account_is_readable_and_url_free() {
        if crate::pan_auth::load(PanKind::Xunlei).is_some() {
            eprintln!("已有迅雷凭据 ⇒ 跳过『无账号』用例");
            return;
        }
        let s = PanXunlei::new();
        let e = s.play("默认", "F1", "").await.expect_err("必须 Err");
        assert_eq!(e, LOGIN_HINT);
        assert!(!e.contains("http"), "★★ 不许出现 URL：{e}");
        let e2 = s.detail("F1", "").await.expect_err("必须 Err");
        assert_eq!(e2, LOGIN_HINT);
    }

    /// 翻页：`page>1` 必须**明说**取不到（不许静默返回第 1 页）
    ///
    /// ```text
    /// ★ 这条守的是"静默错"：返回第 1 页当第 2 页，UI 上表现为"翻页没反应"。
    /// ```
    #[tokio::test]
    async fn page_two_is_an_explicit_error_not_page_one_again() {
        // 有无凭据都先走到登录闸/翻页闸 —— 两者都是 Err，所以这条与凭据无关
        let e = PanXunlei::new().list("0", 2, "").await.expect_err("必须 Err");
        assert!(
            e.contains("page_token") || e.contains("登录"),
            "★ 要么说登录，要么说 page_token：{e}"
        );
    }

    /// cookie 里的头值搬运：认得出来，认不出就 None（不编值）
    #[test]
    fn cookie_value_is_only_carried_never_invented() {
        let c = "deviceid=abc; captcha_token=xyz; other=1";
        assert_eq!(cookie_value(c, &["deviceid"]).as_deref(), Some("abc"));
        assert_eq!(cookie_value(c, &["captcha_token"]).as_deref(), Some("xyz"));
        assert_eq!(cookie_value(c, &["device_id"]), None, "★ 不许近似匹配到别的键");
        assert_eq!(cookie_value("", &["deviceid"]), None);
        assert_eq!(cookie_value("deviceid=   ;", &["deviceid"]), None, "空值不发");
    }

    /// 类名与注册契约
    #[test]
    fn class_is_registered_under_the_exact_name() {
        assert_eq!(PanXunlei::CLASS, "PanXunlei");
        assert_eq!(PanXunlei::new().class(), "PanXunlei");
        // ★ 注册项的键必须逐字与订阅里的 `api`（`csp_PanXunlei`）对齐
        assert!(
            crate::csp::implemented_classes().contains(&"PanXunlei"),
            "★ 本类已自注册 ⇒ 注册表里必须有它（否则用户看不到这个源）"
        );
        assert!(!PanXunlei::new().supports_search());
    }

    #[tokio::test]
    async fn search_is_an_explicit_error() {
        let e = PanXunlei::new().search("x", 1, "").await.expect_err("必须 Err");
        assert!(e.contains("不支持搜索"), "{e}");
    }
}
