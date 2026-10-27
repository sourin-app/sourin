// ═══════════════════════════════════════════════════════════════════════
//  csp_AppQi —— 「齐家 App / qijiappapi.index 接口族」（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★ 为什么**没有** `register_site!`（与 app_sy.rs / app3q.rs / app_fox.rs 同一判据）
// ```text
// ① 订阅（100 站）里 `csp_AppQi` = **0 站**（`.probe/ref-subscription.json` 逐字比对）
// ② host 只能从 ext 拿（DEX `init` 读 `url` / `site` / `dataKey` / `dataIv` / `deviceId` /
//    `version` / `ua` / `search` / `init`），无 ext ⇒ 无 host ⇒ **真网络无可打**
// ③ ⇒ **做实现、不注册**
// ```
//
// # 协议（DEX 常量逐字还原，按行为重写）
//
// ```text
// 形态：**齐家 App 接口**（`/qijiappapi.index/*`），**与 AppleCMS 三族都不同**：
//   · 路径无 `.php`：`/api.php/qijiappapi.index/<动作>`
//   · 请求头一套自定义验签：`app-user-device-id` / `app-version-code` /
//     `app-api-verify-time` / `app-ui-mode` / `app-api-verify-sign`
//
// home    `/qijiappapi.index/initV120` → `recommend_list` / `type_list`(type_id,type_name)
//                                       / `filter_type_list`（class/area/lang/year/sort）
//         ★ DEX 里有三个**写死的分类名**常量：`伦理` / `福利` / `小影院`
//           （那是这个 App 的内置分类，不是通用分类）
// list    `/qijiappapi.index/typeFilterVodList?page=N` + 筛选项（type_id/class/lang/area/year/by）
//         → `recommend_list`
// detail  `/qijiappapi.index/vodDetail` → `vod{}` + `play_list[]`
//         ★ `play_list[]` 每项有 `show`/`parse`/`urls[]`；每个 url 有 `url`/`parse_api_url`/
//           `token`/`name`；拼装用 `$$$`（线）+ `#`（集）
// search  `/qijiappapi.index/searchList`（`type_id`/`keywords`/`page`）→ `search_list`
// play    ★ 走 `parse_api_url`（**站点下发的解析器**）+ `token`：
//             拼成 `…$parse_api=<解析地址>&url=<地址>&token=<token>`
//           ⇒ 需要 `dataKey` / `dataIv` 的 **AES 解密**（见 `edu`/`eduAesDecode`）
// ```
//
// # ⚠️ 两个我**如实标未实现**的点（都不硬造）
//
// ```text
// ① 【AES 解密】DEX 有 `eduAesDecode(String)`：把 `&url=<密文>&token=` 里的 url 密文
//    解密后再送解析器。密钥/IV 来自 ext 的 `dataKey` / `dataIv`（**配置下发**）。
//    · 本实现**不做**这一步：`aes`/`cbc` 本仓有，但**没有真 dataKey/dataIv 可验**
//      （无 host、订阅 0 站）⇒ 写了也是**不可测的代码**。
//    ⇒ 如实留成"需 ext.dataKey/dataIv 才能解"，并在错误里点名。
// ② 【滑块验证】DEX 有 `performSliderVerification()`（`/getSlider` → `slider_id`/`target_x`/
//    `pos_x` → `/verifySlider`）。这是**反爬验证**，本仓没有该能力位，
//    且**不属于"实现站点自己的协议"**（那是绕验证）⇒ **不做**，如实登记。
// ```
// ★ 边界说明：① 是"站点自己的加密协议"（可以做，但缺密钥值）；
//   ② 是"绕过站点的人机验证"（**不做**）—— 两者性质不同，别混。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX `b()` 的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// ★ DEX `okhttp/3.14.9` 是 `b()` 里那个 map 的 UA（另一个方法用）
pub const APP_UA: &str = "okhttp/3.14.9";

pub const COVER_HEADERS: &[(&str, &str)] = &[];

const TIMEOUT: Duration = Duration::from_secs(20);

/// DEX 里写死的三个内置分类名（**逐字**）
///
/// ```text
/// 它们是这个 App 自带的分类（不是从接口拉的），DEX 的 homeContent 里直接用了。
/// ⚠️ 保留为常量只为"契约保真"；**不注册** ⇒ 现在用不到。
/// ```
pub const BUILTIN_CATEGORY_NAMES: &'static [&'static str] = &["伦理", "福利", "小影院"];

/// ext 配置（DEX `init` 读的键）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtCfg {
    pub host: String,
    /// ★ AES 解密的密钥/IV（**配置下发**；无 ext 时为空）
    pub data_key: String,
    pub data_iv: String,
    pub device_id: String,
    pub version: String,
}

pub struct AppQi {
    client: reqwest::Client,
}

impl AppQi {
    pub const CLASS: &'static str = "AppQi";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build app_qi http client");
        Self { client }
    }

    /// 从 ext 抽配置（DEX `init` 的键名逐字：`url`/`site`/`dataKey`/`dataIv`/`deviceId`/`version`）
    ///
    /// ★ **抽成纯函数**：本类无真网络可打 ⇒ 门禁必须靠纯函数（否则是永远绿的类）
    pub fn cfg_of(ext: &str) -> Option<ExtCfg> {
        let j = crate::tvbox::parse_loose_json(ext).ok()?;
        let pick = |k: &str| -> String {
            j.get(k)
                .and_then(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .unwrap_or_default()
        };
        let mut host = pick("url");
        if host.is_empty() {
            host = pick("site");
        }
        let host = host.trim_end_matches('/').to_string();
        if host.is_empty() {
            return None;
        }
        Some(ExtCfg {
            host,
            data_key: pick("dataKey"),
            data_iv: pick("dataIv"),
            device_id: pick("deviceId"),
            version: pick("version"),
        })
    }

    fn need_cfg(ext: &str) -> Result<ExtCfg, String> {
        Self::cfg_of(ext).ok_or_else(|| {
            "AppQi 需要 ext 里的站点地址（键 `url` 或 `site`）——本仓当前无该站配置，\
             且订阅里没有任何 csp_AppQi 站（该类为「做实现、不注册」状态）"
                .to_string()
        })
    }

    /// 请求头（DEX `a`/`b`/`c` 三处共用的一套自定义验签头）
    fn headers_of(cfg: &ExtCfg) -> Vec<(String, String)> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis().to_string())
            .unwrap_or_default();
        vec![
            ("Content-Type".to_string(), "application/x-www-form-urlencoded".to_string()),
            ("app-user-device-id".to_string(), cfg.device_id.clone()),
            ("app-version-code".to_string(), cfg.version.clone()),
            ("app-api-verify-time".to_string(), now),
            ("app-ui-mode".to_string(), "light".to_string()),
        ]
    }

    async fn get_json(&self, cfg: &ExtCfg, path: &str) -> Result<Value, String> {
        let url = format!("{}{}", cfg.host, path);
        let mut req = self.client.get(&url);
        for (k, v) in Self::headers_of(cfg) {
            req = req.header(k, v);
        }
        let resp = req.send().await.map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）：{}", head(&text)));
        }
        crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 120 字：{}）", head(&text)))
    }

    fn item_of(v: &Value) -> Option<CspItem> {
        let id = crate::csp::shared::pick_id_str(v, &["vod_id"])?;
        let title = crate::csp::shared::pick_str(v, &["vod_name"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return None;
        }
        Some(CspItem {
            id,
            title,
            cover: crate::csp::shared::pick_str(v, &["vod_pic"]).map(|s| s.to_string()),
            subtitle: crate::csp::shared::pick_str(v, &["vod_remarks"])
                .filter(|s| !s.trim().is_empty())
                .map(|s| s.to_string()),
        })
    }
}

impl Default for AppQi {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

/// 洗掉 DEX `edu` 里那段正则 `(url=)(.*?)(?=&token)(&token)` 的含义：
/// **把 `url=` 与 `&token` 之间的那段（不含分隔符）取出来**
///
/// # 为什么要抽成纯函数
/// ```text
/// DEX 的 `edu`/`eduAesDecode` 都在做同一件事：定位 `url=…&token=`。
/// 把它抽出来 ⇒ 门禁能**直接断言**边界行为（不必联网），
/// 否则又是一条"不可测的分支"（Hxq 上踩过）。
/// ```
/// 返回 `(前缀含 "url=", 中间值, "&token" 起)`
pub fn split_url_token(s: &str) -> Option<(String, String, String)> {
    let at = s.find("url=")?;
    let after = at + 4;
    let rest = &s[after..];
    let end = rest.find("&token")?;
    Some((
        s[..after].to_string(),
        rest[..end].to_string(),
        rest[end..].to_string(),
    ))
}

// ══ ⚠️ **没有 `register_site!`** ══

#[async_trait]
impl CspSite for AppQi {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let cfg = Self::need_cfg(ext)?;
        let v = self.get_json(&cfg, "/api.php/qijiappapi.index/initV120").await?;
        let d = v.get("data").ok_or_else(|| "首页没有 data".to_string())?;
        let mut categories: Vec<CspCategory> = Vec::new();
        for t in crate::csp::shared::pick_arr(d, &["type_list"])
            .map(|a| a.as_slice())
            .unwrap_or(&[])
        {
            let id = crate::csp::shared::pick_id_str(t, &["type_id"]).unwrap_or_default();
            let name = crate::csp::shared::pick_str(t, &["type_name"]).unwrap_or("").trim().to_string();
            if !id.is_empty() && !name.is_empty() {
                categories.push(CspCategory { id, name });
            }
        }
        if categories.is_empty() {
            return Err("首页没有 data.type_list（上游结构可能变了）".to_string());
        }
        let items = crate::csp::shared::pick_arr(d, &["recommend_list"])
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let cfg = Self::need_cfg(ext)?;
        let page = if page == 0 { 1 } else { page };
        let v = self
            .get_json(
                &cfg,
                &format!(
                    "/api.php/qijiappapi.index/typeFilterVodList?page={page}&type_id={}",
                    urlencoding::encode(tid)
                ),
            )
            .await?;
        let items: Vec<CspItem> = crate::csp::shared::pick_arr(&v, &["data", "recommend_list"])
            .or_else(|| crate::csp::shared::pick_arr(&v, &["recommend_list"]))
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
        let cfg = Self::need_cfg(ext)?;
        let v = self
            .get_json(&cfg, &format!("/api.php/qijiappapi.index/vodDetail?vod_id={vid}"))
            .await?;
        let d = v.get("data").ok_or_else(|| "详情没有 data".to_string())?;
        let vod = d.get("vod").unwrap_or(d);
        let title = crate::csp::shared::pick_str(vod, &["vod_name"]).unwrap_or("").trim().to_string();
        if title.is_empty() {
            return Err(format!("详情 vod_name 为空（vod_id={vid}）"));
        }
        /*
         * 剧集：`play_list[]` 每项 {show, parse, urls[]}，urls 每项 {url, parse_api_url, token, name}
         * ⇒ id 里编码 `name|url`（play 需要 url；name 只作展示）
         */
        let mut episodes: Vec<CspEpisode> = Vec::new();
        for p in crate::csp::shared::pick_arr(d, &["play_list"])
            .map(|a| a.as_slice())
            .unwrap_or(&[])
        {
            let flag = crate::csp::shared::pick_str(p, &["show"]).unwrap_or("默认").trim().to_string();
            for u in crate::csp::shared::pick_arr(p, &["urls"])
                .map(|a| a.as_slice())
                .unwrap_or(&[])
            {
                let ep_url = crate::csp::shared::pick_str(u, &["url"]).unwrap_or("").trim().to_string();
                if ep_url.is_empty() {
                    continue;
                }
                let name = crate::csp::shared::pick_str(u, &["name"]).unwrap_or("").trim().to_string();
                episodes.push(CspEpisode {
                    id: format!("{name}|{ep_url}"),
                    title: if name.is_empty() { ep_url.clone() } else { name },
                    flag: flag.clone(),
                });
            }
        }
        if episodes.is_empty() {
            return Err(format!("「{title}」没有可播剧集（play_list 为空）"));
        }
        Ok(CspDetail {
            id: vid.to_string(),
            title,
            cover: crate::csp::shared::pick_str(vod, &["vod_pic"]).map(|s| s.to_string()),
            description: {
                let content = crate::csp::shared::pick_str(vod, &["vod_content"])
                    .map(super::hxq::clean_intro)
                    .unwrap_or_default();
                let actor = crate::csp::shared::pick_str(vod, &["vod_actor"]).unwrap_or("").trim();
                let director = crate::csp::shared::pick_str(vod, &["vod_director"]).unwrap_or("").trim();
                let mut parts: Vec<String> = Vec::new();
                if !content.is_empty() {
                    parts.push(content);
                }
                if !actor.is_empty() {
                    parts.push(format!("主演：{actor}"));
                }
                if !director.is_empty() {
                    parts.push(format!("导演：{director}"));
                }
                if parts.is_empty() { None } else { Some(parts.join("\n")) }
            },
            episodes,
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let cfg = Self::need_cfg(ext)?;
        let page = if page == 0 { 1 } else { page };
        let v = self
            .get_json(
                &cfg,
                &format!(
                    "/api.php/qijiappapi.index/searchList?keywords={}&type_id=0&page={page}",
                    urlencoding::encode(kw)
                ),
            )
            .await?;
        let items: Vec<CspItem> = crate::csp::shared::pick_arr(&v, &["data", "search_list"])
            .or_else(|| crate::csp::shared::pick_arr(&v, &["search_list"]))
            .map(|a| a.iter().filter_map(Self::item_of).collect())
            .unwrap_or_default();
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        false // ★ 未实测（无 host）⇒ 不声明 true
    }

    /// 取流：需 **AES 解密** `url=` 段（密钥来自 ext.dataKey/dataIv）⇒ 如实标
    ///
    /// # 边界（与"绕人机验证"区分开）
    /// ```text
    /// 这里缺的是 **站点自己的加密协议**的密钥值（ext.dataKey/dataIv）——**可以做的**，
    /// 只是本仓无该配置可验（订阅 0 站）。
    /// ⚠️ 而 DEX 里的 `performSliderVerification()`（滑块验证）是**反爬**,
    ///    本实现**不做**，也不在本错误文案里提"可以绕" ⇒ 两者性质不同。
    /// ```
    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let cfg = Self::need_cfg(ext)?;
        let url = id.splitn(2, '|').nth(1).unwrap_or(id).trim().to_string();
        let has_key = !cfg.data_key.is_empty() && !cfg.data_iv.is_empty();
        Err(format!(
            "AppQi 取流需要先用 ext 的 `dataKey`/`dataIv` 做 **AES 解密**（DEX `eduAesDecode`），\
             再送站点下发的解析器（`parse_api_url`）——\
             本仓当前{}（线路={flag}，值前 24 字：{}）。\
             已实现的链路：home/initV120 → list/typeFilterVodList → detail/vodDetail → search。",
            if has_key {
                "有密钥但仍无站点可验（订阅里 0 站）"
            } else {
                "**没有该站配置**（订阅里 0 站，ext.dataKey/dataIv 缺失）"
            },
            url.chars().take(24).collect::<String>()
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(AppQi::CLASS, "AppQi");
    }

    #[test]
    fn appqi_must_not_be_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_qi.rs"));
        assert!(!flat.contains("register_site!(AppQi)"), "★ 本批 AppQi 不注册");
        assert!(!crate::csp::is_implemented("csp_AppQi"), "★ 不许进注册表");
    }

    #[test]
    fn cfg_reads_the_dex_keys_in_order() {
        // `url` 优先，退到 `site`
        let c = AppQi::cfg_of(r#"{"url":"https://a.example/","dataKey":"K","dataIv":"I","deviceId":"D","version":"V"}"#).unwrap();
        assert_eq!(c.host, "https://a.example");
        assert_eq!(c.data_key, "K");
        assert_eq!(c.data_iv, "I");
        assert_eq!(c.device_id, "D");
        assert_eq!(c.version, "V");
        let c2 = AppQi::cfg_of(r#"{"site":"https://b.example"}"#).unwrap();
        assert_eq!(c2.host, "https://b.example");
        assert_eq!(c2.data_key, "", "缺 dataKey ⇒ 空（不是猜一个）");
        // 都没有 host ⇒ None
        assert!(AppQi::cfg_of("{}").is_none());
        assert!(AppQi::cfg_of("").is_none());
        assert!(AppQi::cfg_of(r#"{"dataKey":"K"}"#).is_none(), "只有 key 没 host ⇒ None");
    }

    #[tokio::test]
    async fn every_segment_reports_the_missing_host() {
        let s = AppQi::new();
        for e in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.detail("1", "").await.err(),
            s.search("x", 1, "").await.err(),
        ] {
            let msg = e.expect("无 host 必须 Err");
            assert!(msg.contains("ext"), "{msg}");
            assert!(msg.contains("csp_AppQi 站"), "{msg}");
        }
    }

    /// ★★ 边界判据：`play` 的错误文案**只提加密协议**（站点自己的），
    ///    **不许**提"可以绕滑块/人机验证"（那是另一码事，本实现不做）
    #[tokio::test]
    async fn play_names_the_encryption_gap_and_not_the_captcha() {
        let s = AppQi::new();
        let e = s.play("L", "第1集|https://x/a.m3u8", r#"{"url":"https://h.example"}"#)
            .await
            .expect_err("必须 Err");
        assert!(e.contains("dataKey"), "要点名缺 ext.dataKey：{e}");
        assert!(e.contains("eduAesDecode"), "要点名 DEX 里的解密方法：{e}");
        // ★ 反面：不许把"滑块验证"当成"我们可以绕的东西"写进文案
        assert!(!e.contains("滑块"), "★ 不许把反爬验证写成本类的能力缺口：{e}");
        assert!(!e.contains("verifySlider"), "★ 同上：{e}");
    }

    /// ★ 本文件**不许**实现滑块验证（那是绕反爬，不是"实现站点协议"）
    #[test]
    fn no_slider_verification_is_implemented() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_qi.rs"));
        assert!(!flat.contains("getSlider"), "★ 不许实现 /getSlider");
        assert!(!flat.contains("verifySlider"), "★ 不许实现 /verifySlider");
        assert!(!flat.contains("performSliderVerification"), "★ 不许实现滑块验证");
    }

    #[test]
    fn split_url_token_matches_the_dex_regex_boundary() {
        // DEX: `(url=)(.*?)(?=&token)(&token)` ⇒ 取 `url=` 与 `&token` 之间的段
        let (pre, mid, post) = split_url_token("xxxurl=ABC123&token=T").unwrap();
        assert_eq!(pre, "xxxurl=");
        assert_eq!(mid, "ABC123");
        assert_eq!(post, "&token=T");
        // 非贪婪 ⇒ 遇到**第一个** `&token` 就停
        let (_, m2, _) = split_url_token("url=A&token=B&token=C").unwrap();
        assert_eq!(m2, "A");
        // 缺任一段 ⇒ None（不 panic、不猜）
        assert!(split_url_token("url=ABC").is_none());
        assert!(split_url_token("token=T").is_none());
        assert!(split_url_token("").is_none());
        // 空值也要能解出来（允许 A 为空）
        let (_, m3, _) = split_url_token("url=&token=T").unwrap();
        assert_eq!(m3, "");
    }

    #[test]
    fn builtin_category_names_are_the_dex_literals() {
        assert_eq!(BUILTIN_CATEGORY_NAMES, &["伦理", "福利", "小影院"]);
    }

    #[test]
    fn endpoints_match_the_dex_constants() {
        let flat = crate::csp::shared::impl_src_only(include_str!("app_qi.rs"));
        for ep in [
            "/api.php/qijiappapi.index/initV120",
            "/api.php/qijiappapi.index/typeFilterVodList?page=",
            "/api.php/qijiappapi.index/vodDetail?vod_id=",
            "/api.php/qijiappapi.index/searchList?keywords=",
        ] {
            assert!(flat.contains(ep), "★ 端点缺失/写错：{ep}");
        }
        // 自定义验签头（DEX 逐字）
        for h in ["app-user-device-id", "app-version-code", "app-api-verify-time", "app-ui-mode"] {
            assert!(flat.contains(h), "★ 请求头缺失：{h}");
        }
    }

    #[test]
    fn item_of_maps_and_skips_empty() {
        let it = AppQi::item_of(&serde_json::json!({"vod_id": 3, "vod_name": "T"})).unwrap();
        assert_eq!(it.id, "3");
        assert!(AppQi::item_of(&serde_json::json!({"vod_name": "无 id"})).is_none());
    }
}