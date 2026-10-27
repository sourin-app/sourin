// ═══════════════════════════════════════════════════════════════════════
//  csp_PanSou —— 「盘搜」网盘聚合搜索（**纯搜索源**）的 Rust 重写
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类为什么**没有** `register_site!`（三条判据缺第 ②条）
// ```text
// ① 订阅里这 1 站   ✓（{"key":"盘搜","api":"csp_PanSou","searchable":1}）
// ② 有可用 host     ✗ ★ 缺的是这一条
// ③ 真网取到数据     ✗（②不成立 ⇒ 无从取数）
// ```
// host 从哪来（DEX `[E]` / `[F]` 逐字）：
// ```text
//   "/peizhi.json"   →  键 "pansouUrl"  →  {pansouUrl}/api/search?kw=…&cloud_types=…
// ```
// ★ `/peizhi.json` 是 **TVBox 配置目录下的本地文件**（与 douban.rs 里记的那条同源：
//   "DEX 是读本地文件，不是网络请求"）。本仓 Rust 侧没有那个文件、也不该去猜宿主目录
//   ⇒ 只能从 **ext** 的 `pansouUrl`（或 `site`）拿。而订阅这条 **没有 ext**：
// ```json
// {"key":"盘搜","name":"🔍盘搜｜网盘搜索","api":"csp_PanSou","searchable":1,
//  "quickSearch":0,"filterable":0,"timeout":60}      ← 没有 ext ⇒ 没有 pansouUrl
// ```
// ⇒ 按本批纪律：**做实现、不注册**。
//
// # 协议（DEX 常量逐字 + 形状）
// ```text
// search  GET {pansouUrl}/api/search?kw=<urlencode(kw)>&cloud_types=<9 家逗号串>
//         请求头只要 User-Agent（DEX 里没有 Referer / Origin）
//   响应  { "code": 200, "data": { "merged_by_type": { "aliyun":[...], "quark":[...], … } } }
//         条目字段（DEX `[F]` 逐字读的键）：vod_id / url / vod_name / note /
//         vod_remarks / source / vod_pic
// ★ DEX 里还有 `_json`：某些部署把 `merged_by_type` 塞成**一段 JSON 字符串**
//   ⇒ 这里两种形态都认（对象直接用，字符串先再解析一次）。
// ```
//
// # ⚠️ 取证局限（如实写）
// ```text
// 本类**没有真网样本**：没有 pansouUrl ⇒ 取不到响应。
// tests 里的 fixture 是**由 DEX 常量还原的形状**（分层与字段名），不是真网 body。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspDetail, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX 里的 UA（`[E]` / `[F]` 逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(20);

/// DEX 逐字的云盘清单（顺序也是逐字）
pub const CLOUD_TYPES: &str = "aliyun,quark,uc,baidu,tianyi,123,xunlei,mobile,115";

const MAX_ITEMS: usize = 300;

const ICON_ALI: &str =
    "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/8Yr6/1200X800/aliyun.jpg/webp";
const ICON_QUARK: &str =
    "https://img.51shazhu.com/autoupload/g1b6f/20260807/bsds/1200X800/quark.jpg/webp";
const ICON_UC: &str =
    "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/kbEn/1200X800/uc.jpg/webp";
const ICON_BAIDU: &str =
    "https://img.51shazhu.com/autoupload/g1b6f/20260806/V6JN/1200X800/baidu.jpg/webp";
const ICON_XUNLEI: &str =
    "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260623/4oPO/1200X800/xunlei.jpg/webp";
const ICON_TIANYI: &str =
    "https://img.51shazhu.com/autoupload/g1b6f/20260807/kltE/1200X800/189.jpg/webp";
const ICON_123: &str =
    "https://img.51shazhu.com/autoupload/g1b6f/20260806/bp2h/1200X800/123.jpg/webp";
const ICON_MOBILE: &str =
    "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/D9nT/1200X800/139.jpg/webp";
const ICON_115: &str = "https://img.meituan.net/content/d7da8a8163ebca219968a6f88f5a49097860.webp";

pub struct PanSou {
    client: reqwest::Client,
}

impl PanSou {
    pub const CLASS: &'static str = "PanSou";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // 与 pan_web_share / zhinan 同一条纪律：不读系统代理
            //（代理会把"站点可用"测成"全宕"，且错误文本不含真因）
            .no_proxy()
            .build()
            .expect("build pan_sou http client");
        Self { client }
    }

    /// host：ext 的 `pansouUrl` 优先（DEX 里这个键名逐字），退到 `site`/`host`
    pub fn host_of(ext: &str) -> Option<String> {
        let j = crate::tvbox::parse_loose_json(ext).ok()?;
        let pick = |k: &str| -> Option<String> {
            j.get(k)
                .and_then(|v| v.as_str())
                .map(|s| s.trim().trim_end_matches('/').to_string())
                .filter(|s| s.starts_with("http"))
        };
        pick("pansouUrl")
            .or_else(|| pick("site"))
            .or_else(|| pick("host"))
    }

    fn need_host(ext: &str) -> Result<String, String> {
        Self::host_of(ext).ok_or_else(|| {
            "PanSou 需要 ext 里的 `pansouUrl`（形如 {\"pansouUrl\":\"https://…\"}）—— \
             DEX 是从**本地文件** `/peizhi.json` 的 `pansouUrl` 拿的，\
             本仓没有那个文件也不该去猜宿主目录；而订阅这条 `csp_PanSou` 没有 ext \
             ⇒ **没有可用 host**，故本类为「做实现、不注册」状态"
                .to_string()
        })
    }

    /// 搜索 URL（DEX 逐字：`/api/search?kw=` + kw + `&cloud_types=` + 9 家）
    pub fn search_url(host: &str, kw: &str) -> String {
        format!(
            "{host}/api/search?kw={}&cloud_types={CLOUD_TYPES}",
            urlencoding::encode(kw)
        )
    }
}

impl Default for PanSou {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

fn icon_of(cloud: &str) -> Option<&'static str> {
    match cloud {
        "aliyun" => Some(ICON_ALI),
        "quark" => Some(ICON_QUARK),
        "uc" => Some(ICON_UC),
        "baidu" => Some(ICON_BAIDU),
        "xunlei" => Some(ICON_XUNLEI),
        "tianyi" => Some(ICON_TIANYI),
        "123" => Some(ICON_123),
        "mobile" => Some(ICON_MOBILE),
        "115" => Some(ICON_115),
        _ => None,
    }
}

/// `merged_by_type` 可能是**对象**，也可能是**一段 JSON 字符串**（DEX 里的 `_json`）
pub fn merged_map(v: &Value) -> Option<serde_json::Map<String, Value>> {
    let raw = v.get("data")?.get("merged_by_type")?;
    if let Some(m) = raw.as_object() {
        return Some(m.clone());
    }
    let s = raw.as_str()?;
    let parsed = crate::tvbox::parse_loose_json(s).ok()?;
    parsed.as_object().cloned()
}

/// 解析成条目（`url`/`note`/`source`/`vod_name` 逐字按 DEX `[F]` 读的键）
pub fn parse_merged(v: &Value) -> Vec<CspItem> {
    let Some(map) = merged_map(v) else {
        return Vec::new();
    };
    let mut out: Vec<CspItem> = Vec::new();
    // 顺序按 DEX 的 cloud_types 串（用户看到的顺序稳定）
    for cloud in CLOUD_TYPES.split(',') {
        let Some(arr) = map.get(cloud).and_then(|a| a.as_array()) else {
            continue;
        };
        for it in arr {
            if out.len() >= MAX_ITEMS {
                return out;
            }
            let Some(url) = it
                .get("url")
                .and_then(|u| u.as_str())
                .map(|s| s.trim())
                .filter(|s| s.starts_with("http"))
            else {
                continue;
            };
            let title = it
                .get("note")
                .and_then(|n| n.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .or_else(|| {
                    it.get("vod_name")
                        .and_then(|n| n.as_str())
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                })
                .unwrap_or_else(|| format!("{cloud}（无标题）"));
            let subtitle = it
                .get("source")
                .and_then(|s| s.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .or_else(|| {
                    it.get("vod_remarks")
                        .and_then(|s| s.as_str())
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                });
            out.push(CspItem {
                id: url.to_string(),
                title,
                cover: icon_of(cloud).map(|s| s.to_string()),
                subtitle,
            });
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

// ══ ⚠️ **没有 `register_site!`**：订阅 ①有站、②无 pansouUrl、③无从取数 ══

#[async_trait]
impl CspSite for PanSou {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let _ = Self::need_host(ext)?;
        Err("PanSou 是纯搜索源（DEX 只有 search）：没有分类表".to_string())
    }

    async fn list(&self, tid: &str, _page: u32, ext: &str) -> Result<CspList, String> {
        let _ = Self::need_host(ext)?;
        Err(format!("PanSou 是纯搜索源，没有分类列表（收到 tid={tid}）"))
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let _ = page; // DEX 的 URL 里没有分页参数
        let url = Self::search_url(&host, kw);
        let resp = self
            .client
            .get(&url)
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
        let v = crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("响应不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
        let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(200);
        if code != 200 {
            return Err(format!(
                "接口 code={code}（kw={kw}）—— 可能接口改版/风控"
            ));
        }
        let items = parse_merged(&v);
        if items.is_empty() && merged_map(&v).is_none() {
            // ★ 容器不在 ⇒ 接口改版（不是"没这个片"）
            return Err(format!(
                "响应里没有 data.merged_by_type（kw={kw}）—— 可能接口改版/风控壳页\
                 （前 120 字：{}）",
                head(&text)
            ));
        }
        Ok(CspList {
            items,
            page: 1,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        // 实现完整，但**没有 pansouUrl ⇒ 未实测**
        true
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let _ = Self::need_host(ext)?;
        Err(format!(
            "PanSou 没有详情页：搜索结果本身就是网盘分享页（id={}）",
            id.chars().take(48).collect::<String>()
        ))
    }

    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let host = Self::need_host(ext)?;
        let url = id.trim();
        if !is_pan_share(url) {
            return Err(format!(
                "PanSou 的剧集 id 必须是网盘分享页 URL，实际：{}（线路={flag}）",
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

    /// ⚠️ 不是真网响应（无 pansouUrl ⇒ 取不到）：按 DEX 常量还原的分层与字段名
    const SHAPE_FIXTURE: &str = r#"{"code":200,"data":{"merged_by_type":{
        "aliyun":[{"url":"https://www.alipan.com/s/abc","note":"三体 4K 阿里","source":"源A"}],
        "quark":[{"url":"https://pan.quark.cn/s/90e6","note":"三体 1080P","source":"源B"}],
        "115":[{"url":"https://115.com/s/xyz","note":"三体 原盘","source":"源C"}]
    }}}"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(PanSou::CLASS, "PanSou");
    }

    #[test]
    fn must_not_be_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("pan_sou.rs"));
        assert!(
            !flat.contains("register_site!(PanSou)"),
            "★ 缺 pansouUrl ⇒ 本批不许注册"
        );
        assert!(
            !crate::csp::is_implemented("csp_PanSou"),
            "★ 不许进注册表（订阅里那 1 站没有 ext）"
        );
    }

    #[test]
    fn host_comes_from_pansou_url_then_site() {
        assert_eq!(
            PanSou::host_of(r#"{"pansouUrl":"https://p.example.com/"}"#).as_deref(),
            Some("https://p.example.com")
        );
        // pansouUrl 优先于 site
        assert_eq!(
            PanSou::host_of(r#"{"site":"https://s.example.com","pansouUrl":"https://p.example.com"}"#)
                .as_deref(),
            Some("https://p.example.com")
        );
        assert_eq!(
            PanSou::host_of(r#"{"site":"https://s.example.com"}"#).as_deref(),
            Some("https://s.example.com")
        );
        assert_eq!(PanSou::host_of(""), None);
        assert_eq!(PanSou::host_of("{}"), None);
    }

    #[test]
    fn search_url_keeps_the_dex_cloud_types_verbatim() {
        assert_eq!(
            PanSou::search_url("https://p.example.com", "三体"),
            "https://p.example.com/api/search?kw=%E4%B8%89%E4%BD%93&cloud_types=aliyun,quark,uc,baidu,tianyi,123,xunlei,mobile,115"
        );
        assert!(CLOUD_TYPES.contains("115") && CLOUD_TYPES.contains("mobile"));
    }

    #[test]
    fn merged_by_type_object_is_parsed_in_cloud_order() {
        let v = crate::tvbox::parse_loose_json(SHAPE_FIXTURE).unwrap();
        let items = parse_merged(&v);
        assert_eq!(items.len(), 3);
        // DEX 的 cloud_types 顺序：aliyun 在 quark 之前，115 在最后
        assert_eq!(items[0].id, "https://www.alipan.com/s/abc");
        assert_eq!(items[0].title, "三体 4K 阿里");
        assert_eq!(items[0].subtitle.as_deref(), Some("源A"));
        assert_eq!(items[1].id, "https://pan.quark.cn/s/90e6");
        assert_eq!(items[2].id, "https://115.com/s/xyz");
        assert!(items[1].cover.as_deref().unwrap_or_default().contains("quark.jpg"));
    }

    /// ★ DEX 里的 `_json`：`merged_by_type` 有可能是一段 **JSON 字符串**
    #[test]
    fn merged_by_type_may_arrive_as_a_json_string() {
        let inner = r#"{"quark":[{"url":"https://pan.quark.cn/s/str","note":"字符串形态"}]}"#;
        let outer = format!(r#"{{"code":200,"data":{{"merged_by_type":{}}}}}"#,
            serde_json::Value::String(inner.to_string()));
        let v = crate::tvbox::parse_loose_json(&outer).unwrap();
        let items = parse_merged(&v);
        assert_eq!(items.len(), 1, "★ 字符串形态必须也认（DEX 的 `_json`）");
        assert_eq!(items[0].id, "https://pan.quark.cn/s/str");
    }

    #[test]
    fn missing_container_is_not_the_same_as_an_empty_one() {
        let empty =
            crate::tvbox::parse_loose_json(r#"{"code":200,"data":{"merged_by_type":{}}}"#).unwrap();
        assert!(parse_merged(&empty).is_empty());
        assert!(merged_map(&empty).is_some(), "★ 容器在 ⇒ 真没结果");
        let broken = crate::tvbox::parse_loose_json(r#"{"code":500}"#).unwrap();
        assert!(merged_map(&broken).is_none(), "★ 容器不在 ⇒ Err 路径");
    }

    #[tokio::test]
    async fn every_segment_reports_the_missing_pansou_url() {
        let s = PanSou::new();
        for e in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.search("三体", 1, "").await.err(),
            s.detail("x", "").await.err(),
            s.play("夸克", "https://pan.quark.cn/s/a", "").await.err(),
        ] {
            let msg = e.expect("无 host 必须 Err");
            assert!(msg.contains("pansouUrl"), "{msg}");
            assert!(msg.contains("/peizhi.json"), "{msg}");
            assert!(msg.contains("不注册"), "{msg}");
        }
    }

    #[tokio::test]
    async fn play_refuses_non_share_ids() {
        let s = PanSou::new();
        let e = s
            .play(
                "夸克",
                "https://example.com/a.m3u8",
                r#"{"pansouUrl":"https://p.example.com"}"#,
            )
            .await
            .expect_err("★ 非分享页必须 Err");
        assert!(e.contains("必须是网盘分享页"), "{e}");
    }

    /// ★ 结构性判据：`.no_proxy()` 必须在 `.timeout(…)` 之后、`.build()` 之前
    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("pan_sou.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("必须有 .timeout");
        let n = flat.find(".no_proxy()").expect("★ 必须 .no_proxy()");
        let b = flat.find(".build()").expect("必须有 .build()");
        assert!(t < n && n < b, "★ 位置必须是 timeout → no_proxy → build");
    }
}