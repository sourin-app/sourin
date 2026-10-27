// ═══════════════════════════════════════════════════════════════════════
//  csp_App3Q —— 「AppleCMS/app 接口族」的 Rust 重写（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ 为什么**没有** `register_site!`（与 `app_sy.rs` 同一条判据）
// ```text
// ① 订阅（100 站）里 `csp_App3Q` = **0 站**（逐字比对 `.probe/ref-subscription.json`）
// ② host 只能从 ext 拿（DEX `init` 读 `host` / `sk` / `ver` / `pkg` / `finger` / `updateId`），
//    无 ext ⇒ **无 host ⇒ 真网络无可打**（不是"上游死"，是"没有目标"）
// ③ 所以：**做实现、不注册**；将来别的订阅带上它时加一行即可。
//    ⚠️ 注册=交付一个"看起来支持但无法验证"的类 ⇒ 不注册是**诚实**，不是遗漏。
// ```
//
// # 协议（DEX 常量逐字还原，按行为重写）
// ```text
// home   GET {host}/api.php/app/index/home
//        → data.categories[] / data.recommend[]（`type_name`, DEX 里默认名含"电影"）
// list   GET {host}/api.php/app/vod/get_detail?vod_id=…  ← ⚠️ DEX 里**详情**就是这个端点
//        （本类的列表与详情共用 `vod/get_detail`；分类走 home 的 categories）
// detail GET {host}/api.php/app/vod/get_detail?vod_id=N
//        → data.{vod_name,vod_pic,vod_class,vod_remarks,vod_content,vod_actor,vod_director,
//                vodplayer[], from, show, vod_play_from, vod_play_url}
//        ★ 剧集拼装用 `$$$`（线）+ `#`（集）+ `$`（名址）—— DEX 里同时有 `\$\$\$` 与 `$$$`
//          （前者是**正则**、后者是**字面**：说明它先 split 再 join）
// search GET {host}/api.php/app/search/index?wd=…&page=1&limit=15
//        → data[]（DEX 里搜索只读 `data`，没再套一层）
// play   ★ DEX 里本类**没有独立的取流端点**（`playerContent` 不在 12 个方法里被单独列出）
//        ⇒ 取流靠 detail 给的 `vod_play_url` **直链**（`m3u8/mp4` 形态）
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

/// 搜索的单页条数（DEX 逐字：`&page=1&limit=15`）
pub const SEARCH_LIMIT: u32 = 15;

/// 从 ext 取 host（DEX `init` 读 `host` 键）；抽成纯函数以便门禁驱动
pub fn host_of(ext: &str) -> Option<String> {
    let j = crate::tvbox::parse_loose_json(ext).ok()?;
    j.get("host")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().trim_end_matches('/').to_string())
        .filter(|s| !s.is_empty())
}

pub struct App3Q {
    client: reqwest::Client,
}

impl App3Q {
    pub const CLASS: &'static str = "App3Q";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build app3q http client");
        Self { client }
    }

    fn need_host(ext: &str) -> Result<String, String> {
        host_of(ext).ok_or_else(|| {
            "App3Q 需要 ext 里的站点地址（键 `host`）——本仓当前无该站配置，\
             且订阅里没有任何 csp_App3Q 站（该类为「做实现、不注册」状态）"
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

impl Default for App3Q {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

// ══ ⚠️ **没有 `register_site!`** —— 见文件头"为什么没有注册" ══

#[async_trait]
impl CspSite for App3Q {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = Self::need_host(ext)?;
        let v = self.get_json(&format!("{host}/api.php/app/index/home")).await?;
        let d = v.get("data").ok_or_else(|| "首页没有 data".to_string())?;
        let mut categories: Vec<CspCategory> = Vec::new();
        for c in pick_arr(d, &["categories"]).map(|a| a.as_slice()).unwrap_or(&[]) {
            let id = pick_id_str(c, &["type_id"]).unwrap_or_default();
            let name = pick_str(c, &["type_name"]).unwrap_or("").trim().to_string();
            if !id.is_empty() && !name.is_empty() {
                categories.push(CspCategory { id, name });
            }
        }
        if categories.is_empty() {
            return Err("首页没有 data.categories（上游结构可能变了）".to_string());
        }
        let items = pick_arr(d, &["recommend"])
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        Ok(CspHome { categories, items })
    }

    /// ⚠️ 本类的"列表"用 `vod/get_detail`（DEX 里就这一个读接口）——
    /// 分类 id 当 vod_id 用；这是**照 DEX 行为**写的，不是"我写错了端点"。
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let d = self.detail(tid, ext).await?;
        Ok(CspList {
            items: vec![CspItem {
                id: d.id,
                title: d.title,
                cover: d.cover,
                subtitle: None,
            }],
            page: if page == 0 { 1 } else { page },
            page_count: Some(1),
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
            .get_json(&format!("{host}/api.php/app/vod/get_detail?vod_id={vid}"))
            .await?;
        let d = v.get("data").ok_or_else(|| "详情没有 data".to_string())?;
        let title = pick_str(d, &["vod_name"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return Err(format!("详情 vod_name 为空（vod_id={vid}）"));
        }
        // DEX 里剧集就在 `vod_play_from` / `vod_play_url`（与其他类同形）
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
        // 退路：若上游把剧集放在 `vodplayer[]` 里（DEX 也读这个键）
        if episodes.is_empty() {
            for p in pick_arr(d, &["vodplayer"]).map(|a| a.as_slice()).unwrap_or(&[]) {
                let line = pick_str(p, &["show"]).unwrap_or("默认").trim().to_string();
                for u in pick_arr(p, &["urls"]).map(|a| a.as_slice()).unwrap_or(&[]) {
                    let ep_url = pick_str(u, &["url"]).unwrap_or("").trim().to_string();
                    if ep_url.is_empty() {
                        continue;
                    }
                    episodes.push(CspEpisode {
                        id: ep_url,
                        title: pick_str(u, &["name"]).unwrap_or("").trim().to_string(),
                        flag: line.clone(),
                    });
                }
            }
        }
        if episodes.is_empty() {
            return Err(format!("「{title}」没有可播剧集（vod_play_url/vodplayer 都为空）"));
        }
        Ok(CspDetail {
            id: vid.to_string(),
            title,
            cover: pick_str(d, &["vod_pic"]).map(|s| s.to_string()),
            description: {
                let content = pick_str(d, &["vod_content"])
                    .map(super::hxq::clean_intro)
                    .unwrap_or_default();
                let class = pick_str(d, &["vod_class"]).unwrap_or("").trim();
                let actor = pick_str(d, &["vod_actor"]).unwrap_or("").trim();
                let director = pick_str(d, &["vod_director"]).unwrap_or("").trim();
                let mut parts: Vec<String> = Vec::new();
                if !content.is_empty() {
                    parts.push(content);
                }
                if !class.is_empty() {
                    parts.push(format!("类型：{class}"));
                }
                if !actor.is_empty() {
                    parts.push(format!("主演：{actor}"));
                }
                if !director.is_empty() {
                    parts.push(format!("导演：{director}"));
                }
                if parts.is_empty() {
                    None
                } else {
                    Some(parts.join("\n"))
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
        let url = format!(
            "{host}/api.php/app/search/index?wd={}&page=1&limit={SEARCH_LIMIT}",
            urlencoding::encode(kw)
        );
        let v = self.get_json(&url).await?;
        // DEX 里搜索只读 `data`（不再套一层）
        let items: Vec<CspItem> = pick_arr(&v, &["data"])
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
        // ★ 未实测（无 host 可打）⇒ 不声明 true（声明了会让 registry 纳入并恒返回空）
        false
    }

    /// 取流：detail 给的就是直链（DEX 里本类没有独立解析端点）
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let host = Self::need_host(ext)?;
        let url = id.trim();
        if !crate::tvbox::starts_http(url) {
            return Err(format!("剧集 id 不是 http 地址：{url}"));
        }
        Ok(vec![CspPlay {
            url: url.to_string(),
            headers: vec![
                ("Referer".to_string(), format!("{host}/")),
                ("User-Agent".to_string(), UA.to_string()),
            ],
            label: Some(if flag.trim().is_empty() {
                "App3Q".to_string()
            } else {
                flag.trim().to_string()
            }),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(App3Q::CLASS, "App3Q");
    }

    /// ★ 本类唯一的"存在性"门禁：**不许**被注册（订阅里 0 站、无 host 可打）
    #[test]
    fn app3q_must_not_be_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app3q.rs"));
        assert!(
            !flat.contains("register_site!(App3Q)"),
            "★ 本批 App3Q 是「做实现、不注册」"
        );
        assert!(
            !crate::csp::is_implemented("csp_App3Q"),
            "★ csp_App3Q 本批不许进注册表"
        );
    }

    #[test]
    fn host_comes_from_ext_host_key() {
        assert_eq!(host_of(r#"{"host":"https://a.example"}"#).as_deref(), Some("https://a.example"));
        assert_eq!(host_of(r#"{"host":"https://a.example/"}"#).as_deref(), Some("https://a.example"));
        assert_eq!(host_of("{}"), None, "缺 host ⇒ None（不猜）");
        assert_eq!(host_of(""), None);
        // DEX 里 init 读的其他键不影响 host 解析
        assert_eq!(
            host_of(r#"{"host":"https://h.example","sk":"x","ver":"1","pkg":"p"}"#).as_deref(),
            Some("https://h.example")
        );
    }

    #[tokio::test]
    async fn every_segment_reports_the_missing_host() {
        let s = App3Q::new();
        for e in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.detail("1", "").await.err(),
            s.search("x", 1, "").await.err(),
            s.play("L", "https://x/1.m3u8", "").await.err(),
        ] {
            let msg = e.expect("无 host 必须 Err");
            assert!(msg.contains("ext"), "要点名缺 ext：{msg}");
            assert!(msg.contains("csp_App3Q 站"), "要说明订阅里没有该站：{msg}");
        }
    }

    #[test]
    fn search_limit_matches_the_dex_constant() {
        assert_eq!(SEARCH_LIMIT, 15, "DEX 逐字：`&page=1&limit=15`");
    }

    #[test]
    fn endpoints_match_the_dex_constants() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app3q.rs"));
        for ep in [
            "/api.php/app/index/home",
            "/api.php/app/vod/get_detail?vod_id=",
            "/api.php/app/search/index?wd=",
        ] {
            assert!(flat.contains(ep), "★ 端点缺失/写错：{ep}");
        }
        // 搜索必须带 limit（DEX 逐字）
        assert!(flat.contains("limit={SEARCH_LIMIT}"), "★ 搜索要带 limit");
    }

    #[test]
    fn item_of_maps_and_skips_empty() {
        let it = App3Q::item_of(&json!({"vod_id": 7, "vod_name": "T", "vod_pic": "https://p",
                                        "vod_remarks": "更新至3集"})).unwrap();
        assert_eq!(it.id, "7");
        assert_eq!(it.title, "T");
        assert_eq!(it.subtitle.as_deref(), Some("更新至3集"));
        assert!(App3Q::item_of(&json!({"vod_name": "无 id"})).is_none());
        assert!(App3Q::item_of(&json!({"vod_id": 1})).is_none());
    }
}