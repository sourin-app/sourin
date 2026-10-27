// ═══════════════════════════════════════════════════════════════════════
//  csp_AppFox —— 「AppleCMS/Appfox 接口族」的 Rust 重写（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ 为什么**没有** `register_site!`（与 `app_sy.rs` / `app3q.rs` 同一判据）
// ```text
// ① 订阅（100 站）里 `csp_AppFox` = **0 站**（`.probe/ref-subscription.json` 逐字比对）
// ② host 只能从 ext 拿（DEX `init` 读 `apiDomain` / `host` / `cms` / `ver` / `from` / `ua` …），
//    无 ext ⇒ 无 host ⇒ **真网络无可打**
// ③ ⇒ **做实现、不注册**（注册 = 交付"看起来支持但无法验证"的类）
// ```
//
// # 协议（DEX 常量逐字还原，按行为重写）
// ```text
// 形态：**AppleCMS**（`/api.php/Appfox/*`），与 AppSy 的 `v1.*`、App3Q 的 `app/*` 是**不同变体**
//
// home    GET {host}/api.php/Appfox/init
//         → data.type_list[] {type_id, type_name}；DEX 里把首项补"全部"
//         ★ 另有 `homeVideoContent()` → `/api.php/appfox/nav`（**注意大小写不同**：
//            `appfox` 小写 vs 其他 `Appfox`）—— 本实现保留这个差异（写错就 404）
// list    GET {host}/api.php/Appfox/vodList?type_id=N
//         → list[] {vod_id, ...}（DEX 里读 `vod_id`）
// detail  GET {host}/api.php/Appfox/vod?ac=detail&ids=N
//         → list[] {vod_name, vod_play_from, vod_play_url, …}
//         ★ 另打 `/api.php/Appfox/config` 拿 `playerList` / `jiexiDataList`
//           （解析器配置：`playerCode` / `playerName`）
// search  GET {host}/api.php/Appfox/vod?ac=detail&wd=…&from=…
//         → list[]
// play    ★ 走 detail/config 给的**解析器**（`playerCode` + 解析地址）
//           而不是直链 —— DEX 里 `playerContent` 拼接解析地址
//         ⚠️ 解析器配置**未实测**（无 host）⇒ 如实标
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::{pick_arr, pick_id_str, pick_str, split_lines};

/// DEX `init()` 的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

pub const COVER_HEADERS: &[(&str, &str)] = &[];

const TIMEOUT: Duration = Duration::from_secs(20);

/// 从 ext 取 host（DEX `init` 读 `apiDomain`，退到 `host`）
pub fn host_of(ext: &str) -> Option<String> {
    let j = crate::tvbox::parse_loose_json(ext).ok()?;
    let pick = |k: &str| -> Option<String> {
        j.get(k)
            .and_then(|v| v.as_str())
            .map(|s| s.trim().trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
    };
    pick("apiDomain").or_else(|| pick("host"))
}

/// DEX 里 home 会把首项补成"全部"（逐字）
pub const ALL_NAME: &str = "全部";

pub struct AppFox {
    client: reqwest::Client,
}

impl AppFox {
    pub const CLASS: &'static str = "AppFox";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build app_fox http client");
        Self { client }
    }

    fn need_host(ext: &str) -> Result<String, String> {
        host_of(ext).ok_or_else(|| {
            "AppFox 需要 ext 里的站点地址（键 `apiDomain` 或 `host`）——本仓当前无该站配置，\
             且订阅里没有任何 csp_AppFox 站（该类为「做实现、不注册」状态）"
                .to_string()
        })
    }

    async fn get_json(&self, url: &str) -> Result<Value, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*")
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）：{}", head(&text)));
        }
        crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 120 字：{}）", head(&text)))
    }

    fn item_of(v: &Value) -> Option<CspItem> {
        let id = pick_id_str(v, &["vod_id"])?;
        let title = pick_str(v, &["vod_name"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return None;
        }
        Some(CspItem {
            id,
            title,
            cover: pick_str(v, &["vod_pic"]).map(|s| s.to_string()),
            subtitle: pick_str(v, &["vod_remarks"])
                .filter(|s| !s.trim().is_empty())
                .map(|s| s.to_string()),
        })
    }
}

impl Default for AppFox {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

// ══ ⚠️ **没有 `register_site!`** ══

#[async_trait]
impl CspSite for AppFox {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = Self::need_host(ext)?;
        let v = self.get_json(&format!("{host}/api.php/Appfox/init")).await?;
        let mut categories: Vec<CspCategory> = Vec::new();
        for t in pick_arr(&v, &["data", "type_list"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            let id = pick_id_str(t, &["type_id"]).unwrap_or_default();
            let name = pick_str(t, &["type_name"]).unwrap_or("").trim().to_string();
            if !id.is_empty() && !name.is_empty() {
                categories.push(CspCategory { id, name });
            }
        }
        if categories.is_empty() {
            return Err("首页没有 data.type_list（上游结构可能变了）".to_string());
        }
        // DEX 里首项补"全部"（去重后）
        if !categories.iter().any(|c| c.name == ALL_NAME) {
            categories.insert(0, CspCategory { id: "0".to_string(), name: ALL_NAME.to_string() });
        }
        // 首屏：`/api.php/appfox/nav`（★ 小写 appfox —— DEX 里就是这样，别"顺手统一"）
        let mut items: Vec<CspItem> = Vec::new();
        if let Ok(nav) = self.get_json(&format!("{host}/api.php/appfox/nav")).await {
            items = pick_arr(&nav, &["data", "videos"])
                .or_else(|| pick_arr(&nav, &["data", "list"]))
                .map(|a| a.iter().filter_map(Self::item_of).collect())
                .unwrap_or_default();
        }
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let page = if page == 0 { 1 } else { page };
        let v = self
            .get_json(&format!("{host}/api.php/Appfox/vodList?type_id={tid}&page={page}"))
            .await?;
        let items: Vec<CspItem> = pick_arr(&v, &["list"])
            .or_else(|| pick_arr(&v, &["data", "list"]))
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        if items.is_empty() {
            if page > 1 {
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total: None,
                });
            }
            return Err(format!("分类 {tid} 没解析出条目（上游结构可能变了）"));
        }
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let vid = id.trim();
        if vid.is_empty() {
            return Err("vod_id 为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let v = self
            .get_json(&format!("{host}/api.php/Appfox/vod?ac=detail&ids={vid}"))
            .await?;
        let d = pick_arr(&v, &["list"])
            .and_then(|a| a.first())
            .ok_or_else(|| format!("详情 list 为空（vod_id={vid}）"))?;
        let title = pick_str(d, &["vod_name"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return Err(format!("详情 vod_name 为空（vod_id={vid}）"));
        }
        let from = pick_str(d, &["vod_play_from"]).unwrap_or("");
        let url = pick_str(d, &["vod_play_url"]).unwrap_or("");
        let mut episodes: Vec<CspEpisode> = Vec::new();
        for (line, eps) in split_lines(from, url) {
            for (name, ep_url) in eps {
                if ep_url.trim().is_empty() {
                    continue;
                }
                episodes.push(CspEpisode {
                    id: ep_url.clone(),
                    title: name,
                    flag: line.clone(),
                });
            }
        }
        if episodes.is_empty() {
            return Err(format!("「{title}」没有可播剧集（vod_play_url 为空）"));
        }
        Ok(CspDetail {
            id: vid.to_string(),
            title,
            cover: pick_str(d, &["vod_pic"]).map(|s| s.to_string()),
            description: {
                let content = pick_str(d, &["vod_content"])
                    .map(super::hxq::clean_intro)
                    .unwrap_or_default();
                if content.is_empty() {
                    None
                } else {
                    Some(content)
                }
            },
            episodes,
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let host = Self::need_host(ext)?;
        let _ = page;
        let v = self
            .get_json(&format!(
                "{host}/api.php/Appfox/vod?ac=detail&wd={}",
                urlencoding::encode(kw)
            ))
            .await?;
        let items: Vec<CspItem> = pick_arr(&v, &["list"])
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        Ok(CspList {
            items,
            page: 1,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        false // ★ 未实测（无 host）⇒ 不声明 true
    }

    /// 取流：本类靠 detail/config 给的**解析器**（未实测）⇒ 如实标缺配置
    ///
    /// ⚠️ 不伪造地址：`vod_play_url` 里给的是**解析器入口**（含 `playerCode`），
    ///    不是最终地址；把它当直链返回会把一个"解析页 URL"当成视频流（那是假通）。
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let host = Self::need_host(ext)?;
        let _ = host;
        let url = id.trim();
        Err(format!(
            "AppFox 取流依赖站点下发的「解析器配置」（`/api.php/Appfox/config` 的 \
             playerList/jiexiDataList 的 playerCode + 解析地址）——\
             本仓当前无该站配置（订阅里 0 站）⇒ 不能解析（线路={flag}，值前 24 字：{}）。\
             已实现的链路：home/init → list/vodList → detail/vod → search。取流部分不做假通。",
            url.chars().take(24).collect::<String>()
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(AppFox::CLASS, "AppFox");
    }

    #[test]
    fn appfox_must_not_be_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_fox.rs"));
        assert!(!flat.contains("register_site!(AppFox)"), "★ 本批 AppFox 不注册");
        assert!(!crate::csp::is_implemented("csp_AppFox"), "★ 不许进注册表");
    }

    #[test]
    fn host_comes_from_apidomain_then_host() {
        assert_eq!(host_of(r#"{"apiDomain":"https://a.example"}"#).as_deref(), Some("https://a.example"));
        // `apiDomain` 优先
        assert_eq!(
            host_of(r#"{"apiDomain":"https://a.example","host":"https://b.example"}"#).as_deref(),
            Some("https://a.example")
        );
        // 退到 host
        assert_eq!(host_of(r#"{"host":"https://b.example"}"#).as_deref(), Some("https://b.example"));
        assert_eq!(host_of("{}"), None);
        assert_eq!(host_of(""), None);
    }

    #[tokio::test]
    async fn every_segment_reports_the_missing_host() {
        let s = AppFox::new();
        for e in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.detail("1", "").await.err(),
            s.search("x", 1, "").await.err(),
        ] {
            let msg = e.expect("无 host 必须 Err");
            assert!(msg.contains("ext"), "{msg}");
            assert!(msg.contains("csp_AppFox 站"), "{msg}");
        }
    }

    /// ★ 真缺陷形状：`play` **不许**把"解析器入口"当成直链返回（那是假通）
    #[tokio::test]
    async fn play_refuses_instead_of_returning_a_parser_url_as_a_stream() {
        let s = AppFox::new();
        let e = s.play("线路1", "https://host/player/?url=xxx", r#"{"apiDomain":"https://h.example"}"#)
            .await
            .expect_err("★ 必须 Err（解析器配置缺失），不许把解析器 URL 当流地址");
        assert!(e.contains("解析器配置"), "{e}");
        assert!(e.contains("不做假通"), "{e}");
    }

    /// ★★ 大小写差异：`/api.php/appfox/nav`（小写）与 `/api.php/Appfox/*`（大写）**都要**
    #[test]
    fn nav_endpoint_keeps_the_dex_lowercase_and_others_the_capital() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_fox.rs"));
        assert!(flat.contains("/api.php/appfox/nav"), "★ nav 是小写 appfox（DEX 逐字）");
        assert!(flat.contains("/api.php/Appfox/init"), "★ init 是大写 Appfox");
        assert!(flat.contains("/api.php/Appfox/vodList?type_id="), "★ vodList 大写");
        assert!(flat.contains("/api.php/Appfox/vod?ac=detail&ids="), "★ detail 大写");
        assert!(flat.contains("/api.php/Appfox/vod?ac=detail&wd="), "★ search 大写");
    }

    #[test]
    fn home_prepends_all_when_missing() {
        // 直接测常量与语义（不联网）：ALL_NAME 是 DEX 逐字的"全部"
        assert_eq!(ALL_NAME, "全部");
        let flat = crate::csp::shared::impl_src_only(include_str!("app_fox.rs"));
        assert!(flat.contains("insert(0,"), "★ 首项要补「全部」");
    }

    #[test]
    fn item_of_maps_and_skips_empty() {
        let it = AppFox::item_of(&json!({"vod_id": 9, "vod_name": "T", "vod_pic": "https://p"})).unwrap();
        assert_eq!(it.id, "9");
        assert_eq!(it.title, "T");
        assert!(AppFox::item_of(&json!({"vod_name": "无 id"})).is_none());
        assert!(AppFox::item_of(&json!({"vod_id": 1})).is_none());
    }
}