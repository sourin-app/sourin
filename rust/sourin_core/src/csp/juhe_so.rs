// ═══════════════════════════════════════════════════════════════════════
//  csp_JuheSo —— 「聚合」网盘搜索（**纯搜索源**）的 Rust 重写
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类为什么**没有** `register_site!`（三条判据缺第 ③条：真网取不到数据）
// ```text
// ① 订阅里这 1 站   ✓（{"key":"聚合","api":"csp_JuheSo","searchable":1}）
// ② 有可用 host     ✓（DEX `[E]` 硬编码 https://so.n13.club）
// ③ 真网取到数据     ✗ ★ 缺的是这一条：host 的 DNS **不存在**
// ```
//
// # 第 ③ 条的取证（2026-10-27 直连，**不是"我打错了"**）
// ```text
// $ curl -sS --noproxy '*' -m 25 -A <Chrome UA> \
//     'https://so.n13.club/api/search.php?kw=三体&format=merged&page_size=50&page=1'
//   curl: (6) Could not resolve host: so.n13.club
//
// ⇒ 换公共解析器复核（排除本机 DNS 被劫持/污染这种"假死"）：
// $ curl -sS --noproxy '*' 'https://dns.alidns.com/resolve?name=so.n13.club&type=A'
//   {"Status":3, …,"Authority":[{"name":"club.", … "data":"ns1.dns.nic.club. …"}]}
//     ★ Status=3 = **NXDOMAIN**（权威侧说这个域名不存在，不是超时、不是 5xx）
// $ nslookup n13.club → *** Non-existent domain      ← 连父域 n13.club 都不存在
// ```
// ⇒ 站点是**整体下线**（父域没了），不是"风控壳页"也不是"要带某个头"。
//   按本仓纪律：**如实登记，不注册**；实现照写，一旦域名回来只需加一行注册。
//   （同类先例：`.probe` 里 `sd.sduc.site` 稳定 522、兄弟镜像仍 200 —— 那种是"可用但慢"，
//    与本例"域名不存在"不是一回事。）
//
// # 协议（DEX `[E]` = searchContent 逐字）
// ```text
// GET {host}/api/search.php?kw=<关键字>&format=merged&page_size=50&page=1
//     请求头只有 User-Agent（DEX 里没有 Referer / Origin）
// 响应 { "code":200, "data":{ "merged_by_type":{ "aliyun":[…], "quark":[…], … } } }
//      条目键：vod_id / url / vod_name / note / vod_remarks / datetime / vod_pic
//      ★ DEX 里还有 `_json`：`merged_by_type` 可能是**一段 JSON 字符串**
// ```
// ★ DEX 里 `DEFAULT_HOST` 之外**没有**任何 host 字面量；这里保留 `ext.site` 覆盖，
//   只用于"域名迁移后重新指向"这一种情况，并在文件里标明默认值来自哪里。
//
// # ⚠️ 取证局限
// ```text
// 没有真网响应可取 ⇒ tests 的 fixture 是**由 DEX 常量还原的形状**，不是真网 body。
// 域名活过来后，第一件事是补一条 CSP_LIVE 用例（真取一次 merged_by_type）。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspDetail, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `[E]` 的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// DEX `[E]` 里硬编码的站点（逐字）
pub const DEFAULT_HOST: &str = "https://so.n13.club";

const TIMEOUT: Duration = Duration::from_secs(20);

/// DEX 逐字：`&format=merged&page_size=50&page=1`
const QUERY_TAIL: &str = "&format=merged&page_size=50&page=1";

const MAX_ITEMS: usize = 300;

// ── 盘名/图标（DEX `[E]`/`[getCloudIcon]` 逐字；多一个 guangya）──
const CLOUDS: &[(&str, &str, &str)] = &[
    (
        "aliyun",
        "阿里",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/8Yr6/1200X800/aliyun.jpg/webp",
    ),
    (
        "quark",
        "夸克",
        "https://img.51shazhu.com/autoupload/g1b6f/20260807/bsds/1200X800/quark.jpg/webp",
    ),
    (
        "uc",
        "UC",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/kbEn/1200X800/uc.jpg/webp",
    ),
    (
        "baidu",
        "百度",
        "https://img.51shazhu.com/autoupload/g1b6f/20260806/V6JN/1200X800/baidu.jpg/webp",
    ),
    (
        "xunlei",
        "迅雷",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260623/4oPO/1200X800/xunlei.jpg/webp",
    ),
    (
        "guangya",
        "光鸭",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260625/kqrL/1200X800/guangya.jpg/webp",
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
        "mobile",
        "移动",
        "https://img.51shazhu.com/autoupload/gE6Y0Af2tjXBCNig6CtNDI12_FRYNb81z6UPhMWD8iI/20260503/D9nT/1200X800/139.jpg/webp",
    ),
    (
        "115",
        "115",
        "https://img.meituan.net/content/d7da8a8163ebca219968a6f88f5a49097860.webp",
    ),
];

pub struct JuheSo {
    client: reqwest::Client,
}

impl JuheSo {
    pub const CLASS: &'static str = "JuheSo";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // 与 pan_web_share / zhinan 同一条纪律：不读系统代理
            //（代理会把"站点可用"测成"全宕"，且错误文本不含真因）
            .no_proxy()
            .build()
            .expect("build juhe_so http client");
        Self { client }
    }

    /// host：DEX 硬编码优先；`ext.site` 只用于"域名迁移后重新指向"
    pub fn host_of(ext: &str) -> String {
        let pick = |k: &str| -> Option<String> {
            crate::tvbox::parse_loose_json(ext)
                .ok()?
                .get(k)
                .and_then(|v| v.as_str())
                .map(|s| s.trim().trim_end_matches('/').to_string())
                .filter(|s| s.starts_with("http"))
        };
        pick("site")
            .or_else(|| pick("host"))
            .unwrap_or_else(|| DEFAULT_HOST.to_string())
    }

    /// 搜索 URL（DEX 逐字拼法：`?kw=` + kw + `&format=merged&page_size=50&page=1`）
    pub fn search_url(host: &str, kw: &str) -> String {
        format!(
            "{host}/api/search.php?kw={}{QUERY_TAIL}",
            urlencoding::encode(kw)
        )
    }
}

impl Default for JuheSo {
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

/// `merged_by_type`：对象或（DEX 的 `_json`）一段 JSON 字符串
pub fn merged_map(v: &Value) -> Option<serde_json::Map<String, Value>> {
    let raw = v.get("data")?.get("merged_by_type")?;
    if let Some(m) = raw.as_object() {
        return Some(m.clone());
    }
    let s = raw.as_str()?;
    crate::tvbox::parse_loose_json(s).ok()?.as_object().cloned()
}

/// 解析成条目（键名照 DEX `[E]` 逐字：url / note / vod_name / vod_remarks / datetime）
pub fn parse_merged(v: &Value) -> Vec<CspItem> {
    let Some(map) = merged_map(v) else {
        return Vec::new();
    };
    let mut out: Vec<CspItem> = Vec::new();
    let mut push = |cloud: &str, arr: &Vec<Value>, out: &mut Vec<CspItem>| {
        for it in arr {
            if out.len() >= MAX_ITEMS {
                return;
            }
            let url = it
                .get("url")
                .and_then(|u| u.as_str())
                .map(|s| s.trim())
                .filter(|s| s.starts_with("http"));
            let Some(url) = url else { continue };
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
                .unwrap_or_else(|| format!("{}（无标题）", label_of(cloud)));
            let subtitle = it
                .get("datetime")
                .and_then(|d| d.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .or_else(|| {
                    it.get("vod_remarks")
                        .and_then(|d| d.as_str())
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
    };
    for (cloud, _, _) in CLOUDS {
        if let Some(arr) = map.get(*cloud).and_then(|a| a.as_array()) {
            push(cloud, arr, &mut out);
        }
    }
    // 表外的盘：追加（上游加盘时不许静默丢）
    for (cloud, arr) in map {
        if CLOUDS.iter().any(|(k, _, _)| *k == cloud.as_str()) {
            continue;
        }
        if let Some(arr) = arr.as_array() {
            push(cloud.as_str(), arr, &mut out);
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

// ══ ⚠️ **没有 `register_site!`**：订阅 ①有站、②有 host、③**host 的 DNS 不存在** ══

#[async_trait]
impl CspSite for JuheSo {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        Err("JuheSo 是纯搜索源（DEX 只有 search）：没有分类表".to_string())
    }

    async fn list(&self, tid: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err(format!("JuheSo 是纯搜索源，没有分类列表（收到 tid={tid}）"))
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let _ = page; // DEX 的 URL 里写死 page=1
        let host = Self::host_of(ext);
        let url = Self::search_url(&host, kw);
        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(|e| {
                format!(
                    "请求失败（{url}）：{e} —— ★ 该 host 的 DNS 在 2026-10-27 实测为 NXDOMAIN\
                     （父域 n13.club 也不存在，见文件头取证），所以这条错误通常意味着\
                     『站点整体下线』而不是『本机网络问题』"
                )
            })?;
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
            return Err(format!("接口 code={code}（kw={kw}）—— 可能接口改版/风控"));
        }
        let items = parse_merged(&v);
        if items.is_empty() && merged_map(&v).is_none() {
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
        // 实现完整，但**host 已 NXDOMAIN ⇒ 未实测**（不注册，故不影响 registry）
        true
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        Err(format!(
            "JuheSo 没有详情页：搜索结果本身就是网盘分享页（id={}）",
            id.chars().take(48).collect::<String>()
        ))
    }

    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let url = id.trim();
        if !is_pan_share(url) {
            return Err(format!(
                "JuheSo 的剧集 id 必须是网盘分享页 URL，实际：{}（线路={flag}）",
                url.chars().take(48).collect::<String>()
            ));
        }
        let host = Self::host_of(ext);
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

    /// ⚠️ 不是真网响应（host NXDOMAIN ⇒ 取不到）：按 DEX 常量还原的分层与字段名
    const SHAPE_FIXTURE: &str = r#"{"code":200,"data":{"merged_by_type":{
        "aliyun":[{"url":"https://www.alipan.com/s/abc","note":"三体 4K","datetime":"2026-10-01"}],
        "guangya":[{"url":"https://www.guangyapan.com/s/g1","note":"三体 光鸭","datetime":"2026-09-29"}],
        "115":[{"url":"https://115.com/s/xyz","note":"三体 115","datetime":"2026-09-28"}]
    }}}"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(JuheSo::CLASS, "JuheSo");
    }

    #[test]
    fn must_not_be_registered_because_the_host_is_dead() {
        let flat = crate::csp::shared::impl_src_only(include_str!("juhe_so.rs"));
        assert!(
            !flat.contains("register_site!(JuheSo)"),
            "★ ③ 真网取不到数据（DNS NXDOMAIN）⇒ 本批不许注册"
        );
        assert!(
            !crate::csp::is_implemented("csp_JuheSo"),
            "★ 不许进注册表"
        );
    }

    #[test]
    fn host_is_the_dex_literal_and_ext_can_retarget_it() {
        assert_eq!(JuheSo::host_of(""), "https://so.n13.club");
        assert_eq!(JuheSo::host_of("{}"), DEFAULT_HOST);
        assert_eq!(
            JuheSo::host_of(r#"{"site":"https://so2.example.com/"}"#),
            "https://so2.example.com"
        );
        assert_eq!(JuheSo::host_of(r#"{"site":"nope"}"#), DEFAULT_HOST);
    }

    #[test]
    fn search_url_matches_the_dex_shape_verbatim() {
        assert_eq!(
            JuheSo::search_url("https://so.n13.club", "三体"),
            "https://so.n13.club/api/search.php?kw=%E4%B8%89%E4%BD%93&format=merged&page_size=50&page=1"
        );
    }

    #[test]
    fn merged_by_type_is_parsed_with_cloud_labels_and_icons() {
        let v = crate::tvbox::parse_loose_json(SHAPE_FIXTURE).unwrap();
        let items = parse_merged(&v);
        assert_eq!(items.len(), 3);
        assert_eq!(items[0].id, "https://www.alipan.com/s/abc");
        assert_eq!(items[0].title, "三体 4K");
        assert_eq!(items[0].subtitle.as_deref(), Some("2026-10-01"));
        assert!(items[0].cover.as_deref().unwrap_or_default().contains("aliyun.jpg"));
        // 光鸭（DEX 里多出来的那家）也要有名字与图标
        assert!(items[1].cover.as_deref().unwrap_or_default().contains("guangya.jpg"));
        assert!(items[2].cover.as_deref().unwrap_or_default().contains("meituan.net"));
    }

    #[test]
    fn merged_by_type_may_arrive_as_a_json_string() {
        let inner = r#"{"quark":[{"url":"https://pan.quark.cn/s/str","note":"字符串形态"}]}"#;
        let outer = format!(
            r#"{{"code":200,"data":{{"merged_by_type":{}}}}}"#,
            serde_json::Value::String(inner.to_string())
        );
        let v = crate::tvbox::parse_loose_json(&outer).unwrap();
        let items = parse_merged(&v);
        assert_eq!(items.len(), 1, "★ 字符串形态必须也认（DEX 的 `_json`）");
        assert_eq!(items[0].id, "https://pan.quark.cn/s/str");
    }

    #[test]
    fn missing_container_is_distinguishable_from_an_empty_one() {
        let empty =
            crate::tvbox::parse_loose_json(r#"{"code":200,"data":{"merged_by_type":{}}}"#).unwrap();
        assert!(parse_merged(&empty).is_empty());
        assert!(merged_map(&empty).is_some(), "★ 容器在 ⇒ 真没结果");
        let broken = crate::tvbox::parse_loose_json(r#"{"code":404}"#).unwrap();
        assert!(merged_map(&broken).is_none(), "★ 容器不在 ⇒ Err 路径");
    }

    #[tokio::test]
    async fn search_only_source_reports_what_it_does_not_have() {
        let s = JuheSo::new();
        let h = s.home("").await.expect_err("没有 homeContent");
        assert!(h.contains("纯搜索源"), "{h}");
        let l = s.list("1", 1, "").await.expect_err("没有 categoryContent");
        assert!(l.contains("没有分类列表"), "{l}");
        let d = s.detail("x", "").await.expect_err("没有详情页");
        assert!(d.contains("没有详情页"), "{d}");
        // 空关键词在网络前就拦掉（否则会打到死域名上，错误文案会误导成"网络问题"）
        assert!(s.search("  ", 1, "").await.is_err());
    }

    #[tokio::test]
    async fn play_refuses_non_share_ids() {
        let s = JuheSo::new();
        let e = s
            .play("夸克", "https://example.com/a.m3u8", "")
            .await
            .expect_err("★ 非分享页必须 Err");
        assert!(e.contains("必须是网盘分享页"), "{e}");
        let ok = s
            .play("夸克", "https://pan.quark.cn/s/abc", "")
            .await
            .expect("分享页应可用");
        assert_eq!(ok[0].label.as_deref(), Some("夸克（分享页）"));
    }

    /// ★ 结构性判据：`.no_proxy()` 必须在 `.timeout(…)` 之后、`.build()` 之前
    #[test]
    fn client_disables_proxy_between_timeout_and_build() {
        let flat = crate::csp::shared::impl_src_only(include_str!("juhe_so.rs"));
        let t = flat.find(".timeout(TIMEOUT)").expect("必须有 .timeout");
        let n = flat.find(".no_proxy()").expect("★ 必须 .no_proxy()");
        let b = flat.find(".build()").expect("必须有 .build()");
        assert!(t < n && n < b, "★ 位置必须是 timeout → no_proxy → build");
    }
}