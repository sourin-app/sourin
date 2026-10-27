// ═══════════════════════════════════════════════════════════════════════
//  csp_Mipansou —— 「觅盘」网盘聚合搜索（**纯搜索源**）的 Rust 重写
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类为什么**没有** `register_site!`（三条判据缺第 ②条）
// ```text
// ① 订阅里这 1 站           ✓（`.probe/ref-subscription.json`：{"key":"觅盘","api":"csp_Mipansou"}）
// ② 有可用 host             ✗ ★ 缺的是这一条
// ③ 真网真的取到数据         ✗（②不成立 ⇒ 无从取数）
// ```
// host 从哪来：DEX 里 `Mipansou` **一个 host 字面量都没有**（逐条列过：
// `.probe/csp24-dex-Mipansou.txt` 里只有 `""`/`quark`/`X-Mipan-Token`/`/api/search`…），
// 它继承 `Lcom/github/catvod/spider/Pan;`，站点由父类 `init(Context, String ext)` 从
// **ext** 取（`site`）。而订阅这条 **没有 ext**：
// ```json
// {"key":"觅盘","name":"🔍觅盘｜网盘搜索","api":"csp_Mipansou","searchable":1,
//  "quickSearch":0,"filterable":0,"timeout":60}      ← 没有 ext ⇒ 没有 host
// ```
// ⇒ 按本批纪律：**做实现、不注册**（注册 = 交付"看起来支持但无法验证"的类）。
//
// # 协议（DEX 方法级常量逐字还原）
// ```text
// search   POST {site}/api/search                       ← `[search]`
//          headers  X-Mipan-Token: <token> · User-Agent · Referer: {site}/
//          body     {"kw":"<关键字>"}                    ← DEX 逐字 `{"kw":"` + kw + `"}`
//          若 body 里出现 `token_required` ⇒ GET {site}/api/token → {"token":…,"ttl":…}
//          取到 token 后**重试一次**
//   响应    data.merged_by_type.{quark|uc|aliyun|baidu|tianyi|123|xunlei|115|guangya|mobile}[]
//           每条 {url, password, note, datetime, …}
// 组合分享链接  `[withPwd]` 的逐字常量：pwd= / password= / code=
//           · 115    → ?password=
//           · guangya→ ?code=
//           · mobile → ?pwd=
//           · 其余   → ?pwd=
// 盘名/图标      `[label]`/`[icon]` 逐字（夸克/UC/阿里/百度/天翼/123/迅雷/115/光鸭/移动）
// ```
//
// # ⚠️ 取证局限（如实写，别当成"实测过"）
// ```text
// 本类**没有真网样本**：没有 host ⇒ 取不到响应。
// 因此 tests 里的响应 fixture 是**由 DEX 常量还原的形状**（`data`→`merged_by_type`→
// `_json` 的分层与字段名），不是真网 body。它证明的是"分层与字段名对得上"，
// 不证明"上游现在这么回" ⇒ 真网一有 host，必须补一条 CSP_LIVE 用例复测。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspDetail, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `[head]` 的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(20);

/// 一次搜索最多收多少条（纯内存上限，防某天上游一次回几万条）
const MAX_ITEMS: usize = 300;

// ── 盘名与图标（DEX `[label]` / `[icon]` 逐字）──
const CLOUDS: &[(&str, &str, &str)] = &[
    (
        "quark",
        "夸克",
        "https://pic7.fukit.cn/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/LX2y/1200X800/quark.jpg/webp",
    ),
    (
        "uc",
        "UC",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/kbEn/1200X800/uc.jpg/webp",
    ),
    (
        "aliyun",
        "阿里",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/8Yr6/1200X800/aliyun.jpg/webp",
    ),
    (
        "baidu",
        "百度",
        "https://img.51shazhu.com/autoupload/g1b6f/20260806/V6JN/1200X800/baidu.jpg/webp",
    ),
    (
        "tianyi",
        "天翼",
        "https://img.51shazhu.com/autoupload/g1b6f/20260807/kltE/1200X800/189.jpg/webp",
    ),
    (
        "123",
        "123",
        "https://img.51shazhu.com/autoupload/g1b6f/20260806/bp2h/1200X800/123.jpg/webp",
    ),
    (
        "xunlei",
        "迅雷",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260623/4oPO/1200X800/xunlei.jpg/webp",
    ),
    (
        "115",
        "115",
        "https://img.meituan.net/content/d7da8a8163ebca219968a6f88f5a49097860.webp",
    ),
    (
        "guangya",
        "光鸭",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260625/kqrL/1200X800/guangya.jpg/webp",
    ),
    (
        "mobile",
        "移动",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/D9nT/1200X800/139.jpg/webp",
    ),
];

pub struct Mipansou {
    client: reqwest::Client,
}

impl Mipansou {
    pub const CLASS: &'static str = "Mipansou";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // 与 pan_web_share / zhinan 同一条纪律：不读系统代理
            //（代理会把"站点可用"测成"全宕"，且错误文本不含真因）
            .no_proxy()
            .build()
            .expect("build mi_pan_sou http client");
        Self { client }
    }

    /// host 只能从 ext 取（DEX 里零 host 字面量；站点由父类 `Pan.init` 从 ext 的 `site` 拿）
    pub fn host_of(ext: &str) -> Option<String> {
        let j = crate::tvbox::parse_loose_json(ext).ok()?;
        let pick = |k: &str| -> Option<String> {
            j.get(k)
                .and_then(|v| v.as_str())
                .map(|s| s.trim().trim_end_matches('/').to_string())
                .filter(|s| s.starts_with("http"))
        };
        pick("site").or_else(|| pick("host")).or_else(|| pick("url"))
    }

    fn need_host(ext: &str) -> Result<String, String> {
        Self::host_of(ext).ok_or_else(|| {
            "Mipansou 需要 ext 里的站点地址（键 `site`，形如 {\"site\":\"https://…\"}）—— \
             DEX 里没有 host 字面量（站点由父类 Pan 从 ext 取），\
             而订阅这条 `csp_Mipansou` 没有 ext ⇒ 本仓「没有可用 host」，\
             故本类为「做实现、不注册」状态"
                .to_string()
        })
    }

    /// `token_required` 判据（DEX `[search]` 里就这么判，不是看状态码）
    pub fn needs_token(body: &str) -> bool {
        body.contains("token_required")
    }

    async fn post_search(
        &self,
        host: &str,
        body: &str,
        token: Option<&str>,
    ) -> Result<String, String> {
        let url = format!("{host}/api/search");
        let mut req = self
            .client
            .post(&url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .header(reqwest::header::REFERER, format!("{host}/"))
            .body(body.to_string());
        if let Some(t) = token {
            req = req.header("X-Mipan-Token", t);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）：{}", head(&text)));
        }
        Ok(text)
    }

    /// `GET {host}/api/token` → `{"token":"…","ttl":N}`
    async fn fetch_token(&self, host: &str) -> Result<String, String> {
        let url = format!("{host}/api/token");
        let text = self
            .client
            .get(&url)
            .header(reqwest::header::REFERER, format!("{host}/"))
            .send()
            .await
            .map_err(|e| format!("取 token 请求失败（{url}）：{e}"))?
            .text()
            .await
            .map_err(|e| format!("取 token 读取失败（{url}）：{e}"))?;
        let v = crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("token 不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
        v.get("token")
            .and_then(|t| t.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| format!("token 响应里没有 token 字段（前 120 字：{}）", head(&text)))
    }
}

impl Default for Mipansou {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

fn icon_of(cloud: &str) -> Option<&'static str> {
    CLOUDS
        .iter()
        .find(|(k, _, _)| *k == cloud)
        .map(|(_, _, url)| *url)
}

fn label_of(cloud: &str) -> &str {
    CLOUDS
        .iter()
        .find(|(k, _, _)| *k == cloud)
        .map(|(_, name, _)| *name)
        .unwrap_or(cloud)
}

/// 把提取码拼进分享链接（DEX `[withPwd]` 逐字：115→`password=`、光鸭→`code=`、其余→`pwd=`）
pub fn with_pwd(url: &str, cloud: &str, pwd: &str) -> String {
    let pwd = pwd.trim();
    if pwd.is_empty() || url.contains("pwd=") || url.contains("password=") || url.contains("code=") {
        return url.to_string();
    }
    let key = match cloud {
        "115" => "password",
        "guangya" => "code",
        _ => "pwd",
    };
    let sep = if url.contains('?') { '&' } else { '?' };
    format!("{url}{sep}{key}={pwd}")
}

/// `data.merged_by_type` → 条目列表（DEX 的分层：`data` → `merged_by_type` → 每家盘一个数组）
///
/// # 为什么按 CLOUDS 的固定顺序遍历（而不是直接遍历 JSON 的键）
/// ```text
/// 上游把"盘"放在一个 object 里，object 的键序由 JSON 实现决定（不保证稳定）。
/// DEX `[<clinit>]` 里盘名是**固定顺序**的常量表 ⇒ 这里照着排，
/// 让"同一份响应每次渲染顺序一致"（用户不会看到列表忽左忽右）。
/// 表外的盘（上游新增）追加在末尾，**不丢**。
/// ```
pub fn parse_merged(v: &Value) -> Vec<CspItem> {
    let Some(map) = v
        .get("data")
        .and_then(|d| d.get("merged_by_type"))
        .and_then(|m| m.as_object())
    else {
        return Vec::new();
    };
    let mut out: Vec<CspItem> = Vec::new();
    let mut push_cloud = |cloud: &str, arr: &Vec<Value>, out: &mut Vec<CspItem>| {
        for it in arr {
            if out.len() >= MAX_ITEMS {
                return;
            }
            let Some(url) = it
                .get("url")
                .and_then(|u| u.as_str())
                .map(|s| s.trim())
                .filter(|s| s.starts_with("http"))
            else {
                continue;
            };
            let pwd = it
                .get("password")
                .and_then(|p| p.as_str())
                .unwrap_or_default();
            let title = it
                .get("note")
                .and_then(|n| n.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| format!("{}（无标题）", label_of(cloud)));
            out.push(CspItem {
                id: with_pwd(url, cloud, pwd),
                title,
                cover: icon_of(cloud).map(|s| s.to_string()),
                subtitle: it
                    .get("datetime")
                    .and_then(|d| d.as_str())
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty()),
            });
        }
    };
    for (cloud, _, _) in CLOUDS {
        if let Some(arr) = map.get(*cloud).and_then(|a| a.as_array()) {
            push_cloud(cloud, arr, &mut out);
        }
    }
    // 表外的盘：追加（上游加盘时不许静默丢）
    for (cloud, arr) in map {
        if CLOUDS.iter().any(|(k, _, _)| *k == cloud.as_str()) {
            continue;
        }
        if let Some(arr) = arr.as_array() {
            push_cloud(cloud.as_str(), arr, &mut out);
        }
    }
    out
}

/// 是不是网盘分享页（play 的自证）
pub fn is_pan_share(url: &str) -> bool {
    const HOSTS: &[&str] = &[
        "pan.quark.cn",
        "pan.baidu.com",
        "drive.uc.cn",
        "aliyundrive.com",
        "alipan.com",
        "cloud.189.cn",
        "cloud.189.com",
        "115.com",
        "115cdn.com",
        "anxia.com",
        "guangyapan.com",
        "pan.xunlei.com",
        "123pan.com",
        "123684.com",
        "123865.com",
    ];
    HOSTS.iter().any(|h| url.contains(h))
}

// ══ ⚠️ **没有 `register_site!`**：订阅 ①有站、②无 host、③无从取数 ══

#[async_trait]
impl CspSite for Mipansou {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        // 先把"缺 host"说清楚（这比"没有分类"更根本）
        let _ = Self::need_host(ext)?;
        Err("Mipansou 是纯搜索源（DEX 只有 search）：没有分类表".to_string())
    }

    async fn list(&self, tid: &str, _page: u32, ext: &str) -> Result<CspList, String> {
        let _ = Self::need_host(ext)?;
        Err(format!("Mipansou 是纯搜索源，没有分类列表（收到 tid={tid}）"))
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let _ = page; // DEX 里没有分页参数（一次给全量）
        let body = format!("{{\"kw\":\"{kw}\"}}");
        let mut text = self.post_search(&host, &body, None).await?;
        // DEX：body 里出现 `token_required` 就去换 token，再重试**一次**
        if Self::needs_token(&text) {
            let token = self.fetch_token(&host).await?;
            text = self.post_search(&host, &body, Some(&token)).await?;
            if Self::needs_token(&text) {
                return Err(format!(
                    "换了 token 仍被要求鉴权（kw={kw}）—— 该搜索后端对匿名调用收紧，\
                     可能接口改版（body 前 120 字：{}）",
                    head(&text)
                ));
            }
        }
        let v = crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("响应不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
        let items = parse_merged(&v);
        if items.is_empty() {
            // 与 QuPanSo 同一条纪律：`merged_by_type` **存在**且为空 = 真没结果；
            // 不存在 = 接口改版。这里两者分开说。
            let container = v
                .get("data")
                .and_then(|d| d.get("merged_by_type"))
                .and_then(|m| m.as_object());
            if container.is_none() {
                return Err(format!(
                    "响应里没有 data.merged_by_type（kw={kw}）—— 可能接口改版/风控壳页\
                     （前 120 字：{}）",
                    head(&text)
                ));
            }
        }
        Ok(CspList {
            items,
            page: 1,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        // 实现完整（含 token 换发），但**没有 host ⇒ 未实测**
        true
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let _ = Self::need_host(ext)?;
        Err(format!(
            "Mipansou 没有详情页：搜索结果本身就是网盘分享页（id={}）",
            id.chars().take(48).collect::<String>()
        ))
    }

    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let host = Self::need_host(ext)?;
        let url = id.trim();
        if !is_pan_share(url) {
            return Err(format!(
                "Mipansou 的剧集 id 必须是网盘分享页 URL，实际：{}（线路={flag}）",
                url.chars().take(48).collect::<String>()
            ));
        }
        Ok(vec![CspPlay {
            url: url.to_string(),
            headers: vec![("Referer".to_string(), format!("{host}/"))],
            label: Some(format!("{flag}（分享页）")),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ⚠️ **不是真网响应**（本类无 host，取不到）：这是按 DEX 常量还原的**分层与字段名**
    /// （`data` → `merged_by_type` → 每家盘一个数组；条目里有 url/password/note/datetime）
    const SHAPE_FIXTURE: &str = r#"{"code":200,"data":{"merged_by_type":{
        "quark":[{"url":"https://pan.quark.cn/s/90e6692f0e25","password":"","note":"三体 全集 4K","datetime":"2026-10-01 10:00:00"}],
        "baidu":[{"url":"https://pan.baidu.com/s/1ROthCWgXlaMvGQeb_EmPBA","password":"i5e4","note":"三体 1080P","datetime":"2026-09-30 09:00:00"}]
    }}}"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Mipansou::CLASS, "Mipansou");
    }

    #[test]
    fn must_not_be_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("mi_pan_sou.rs"));
        assert!(
            !flat.contains("register_site!(Mipansou)"),
            "★ 缺 host ⇒ 本批不许注册"
        );
        assert!(
            !crate::csp::is_implemented("csp_Mipansou"),
            "★ 不许进注册表（订阅里那 1 站没有 ext）"
        );
    }

    #[test]
    fn host_only_comes_from_ext() {
        assert_eq!(
            Mipansou::host_of(r#"{"site":"https://mipan.example.com/"}"#).as_deref(),
            Some("https://mipan.example.com")
        );
        assert_eq!(
            Mipansou::host_of(r#"{"url":"https://u.example.com"}"#).as_deref(),
            Some("https://u.example.com")
        );
        // 订阅这条就是没有 ext
        assert_eq!(Mipansou::host_of(""), None);
        assert_eq!(Mipansou::host_of("{}"), None);
        assert_eq!(Mipansou::host_of(r#"{"site":"not-a-url"}"#), None);
    }

    #[test]
    fn merged_by_type_is_parsed_in_the_dex_cloud_order() {
        let v = crate::tvbox::parse_loose_json(SHAPE_FIXTURE).unwrap();
        let items = parse_merged(&v);
        assert_eq!(items.len(), 2);
        // CLOUDS 的固定顺序是 quark 在 baidu 之前（DEX `[<clinit>]`）
        assert_eq!(items[0].id, "https://pan.quark.cn/s/90e6692f0e25");
        assert_eq!(items[0].title, "三体 全集 4K");
        assert!(items[0]
            .cover
            .as_deref()
            .unwrap_or_default()
            .contains("quark.jpg"));
        // 百度那条带提取码 ⇒ 必须拼进 URL（DEX `[withPwd]`）
        assert_eq!(
            items[1].id,
            "https://pan.baidu.com/s/1ROthCWgXlaMvGQeb_EmPBA?pwd=i5e4"
        );
        assert_eq!(items[1].subtitle.as_deref(), Some("2026-09-30 09:00:00"));
    }

    #[test]
    fn pwd_key_differs_per_cloud() {
        assert_eq!(
            with_pwd("https://pan.quark.cn/s/a", "quark", "x1"),
            "https://pan.quark.cn/s/a?pwd=x1"
        );
        assert_eq!(
            with_pwd("https://115.com/s/a", "115", "x1"),
            "https://115.com/s/a?password=x1"
        );
        assert_eq!(
            with_pwd("https://www.guangyapan.com/s/a", "guangya", "x1"),
            "https://www.guangyapan.com/s/a?code=x1"
        );
        assert_eq!(
            with_pwd("https://caiyun.139.com/w/i/a", "mobile", "x1"),
            "https://caiyun.139.com/w/i/a?pwd=x1"
        );
        // 已经有 pwd 的不重复拼
        assert_eq!(
            with_pwd("https://pan.baidu.com/s/1abc?pwd=old", "baidu", "new"),
            "https://pan.baidu.com/s/1abc?pwd=old"
        );
        // 没提取码 ⇒ 原样
        assert_eq!(
            with_pwd("https://pan.quark.cn/s/a", "quark", "  "),
            "https://pan.quark.cn/s/a"
        );
    }

    #[test]
    fn empty_merged_container_is_not_the_same_as_a_missing_one() {
        let empty =
            crate::tvbox::parse_loose_json(r#"{"code":200,"data":{"merged_by_type":{}}}"#).unwrap();
        assert!(parse_merged(&empty).is_empty());
        assert!(
            empty
                .get("data")
                .and_then(|d| d.get("merged_by_type"))
                .and_then(|m| m.as_object())
                .is_some(),
            "★ 容器在 ⇒ 真没结果"
        );
        let broken = crate::tvbox::parse_loose_json(r#"{"code":500,"msg":"err"}"#).unwrap();
        assert!(
            broken
                .get("data")
                .and_then(|d| d.get("merged_by_type"))
                .is_none(),
            "★ 容器不在 ⇒ 接口改版（search 里会 Err）"
        );
    }

    #[test]
    fn token_required_is_detected_from_the_body() {
        assert!(Mipansou::needs_token(r#"{"error":"token_required"}"#));
        assert!(!Mipansou::needs_token(
            r#"{"code":200,"data":{"merged_by_type":{}}}"#
        ));
    }

    #[tokio::test]
    async fn every_segment_reports_the_missing_host() {
        let s = Mipansou::new();
        for e in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.search("三体", 1, "").await.err(),
            s.detail("x", "").await.err(),
            s.play("夸克", "https://pan.quark.cn/s/a", "").await.err(),
        ] {
            let msg = e.expect("无 host 必须 Err");
            assert!(msg.contains("ext"), "{msg}");
            assert!(msg.contains("不注册"), "{msg}");
        }
    }

    #[tokio::test]
    async fn play_refuses_non_share_ids() {
        let s = Mipansou::new();
        let e = s
            .play(
                "夸克",
                "https://example.com/a.m3u8",
                r#"{"site":"https://h.example.com"}"#,
            )
            .await
            .expect_err("★ 非分享页必须 Err");
        assert!(e.contains("必须是网盘分享页"), "{e}");
    }

    /// ★ 结构性判据：`.no_proxy()` 必须在 `.timeout(…)` 之后、`.build()` 之前
    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("mi_pan_sou.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("必须有 .timeout");
        let n = flat.find(".no_proxy()").expect("★ 必须 .no_proxy()");
        let b = flat.find(".build()").expect("必须有 .build()");
        assert!(t < n && n < b, "★ 位置必须是 timeout → no_proxy → build");
    }
}