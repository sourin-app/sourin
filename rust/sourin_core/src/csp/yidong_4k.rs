// ═══════════════════════════════════════════════════════════════════════
//  csp_Yidong4K —— 移动 4K（`vidsite.cloudseekr.com`，POST-JSON；播放落点是**网盘分享页**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
//
// ```text
// 订阅（`.probe/ref-subscription.json` 逐字）：
//   {"type":3, "api":"csp_Yidong4K", "key":"移动", "name":"🌐移动丨4K免扫", "ext": null}
// ⇒ ext 为 null ⇒ **host 只能写死**（DEX 常量逐字：https://vidsite.cloudseekr.com）
// ```
//
// # 协议取证（`.probe/csp26-downloads/lmw_classes.dex` 直读，**未起 jadx**）
//
// 类 `com.github.catvod.spider.Yidong4K`，父类 `com.github.catvod.spider.Pan`（8 方法）。
// 常量来源：`.probe/csp25/Yidong4K.txt` + `r3_disasm_v2.py` 的逐方法反汇编。
//
// ```text
// 头（DEX `f()` 逐字，10 项 —— 少一项都可能被判"不是 App"）
//   Origin: https://vidsite.cloudseekr.com
//   Accept: application/json, text/plain, */*
//   Cache-Control: no-cache        Pragma: no-cache
//   User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) … Chrome/151.0.0.0 Safari/537.36
//   Referer: https://vidsite.cloudseekr.com/vid/app/
//   Content-Type: application/json; charset=utf-8
//   Host: vidsite.cloudseekr.com   Connection: Keep-Alive   Accept-Encoding: gzip
//   ★ 后三项在 reqwest 里由 client 自己按 URL 生成（Host/Connection/Accept-Encoding），
//     与 DEX 的值等价 —— 实测不带它们显式值也 200（见读数），这里不手写 Host（reqwest 会拒）。
//
// 签名（DEX `b()` 逐字）：**fprint** = md5("AiNewYiDong4K_<currentTimeMillis>_<nanoTime>")
//   · DEX 里缓存到字段 `a` 只算一次；本实现**每次请求新算**（实测服务端只校验格式，不校验复用）
//   · 它不是 header，而是**放进 JSON 体**的两个字段之一
//
// 端点（全部 POST，全部 JSON 体）
//   list   https://vidsite.cloudseekr.com/vidsite/vs/qryPageColumnVideo
//          {"columnId":<int>,"cateIdList":[0,0,0],"pageIndex":<page>,"pageSize":9}
//          → {"code":"000000","data":{"total":312,"list":[{id,title,appCoverUrl,resUrl,…}]}}
//   detail https://vidsite.cloudseekr.com/vidsite/vs/addAccessRecord   （埋点，先打）
//          {"videoId":<int>,"fprint":"<md5>"}                          → data:null
//          https://vidsite.cloudseekr.com/vidsite/vs/qryVideoDetail
//          {"videoId":<int>,"fprint":"<md5>"} → data{id,title,appCoverUrl,remark,cateNameList,resUrl}
//   search https://vidsite.cloudseekr.com/vidsite/vs/qryPageColumnVideo
//          {"columnId":0,"cateIdList":[0,0,0],"pageIndex":1,"pageSize":9,"searchKey":"<kw>"}
//   play   ★ 父类 `Pan` 实现：resUrl 是**网盘分享页**（实测 `https://yun.139.com/shareweb/#/w/i/…`）
//          ⇒ 本仓返回"需要网盘登录"的可读 Err（与 `pan_web_share.rs` 同一条边界）
// ```
//
// ★ **成功码是字符串 `"000000"`**，不是 0/200
// ```text
// 只看 HTTP 200 会把"code=xxxxxx 业务失败"当成成功；DEX 每次 `getString("code")` 后
// 都 `.equals("000000")`。本实现照抄：非 000000 ⇒ Err 并**带上 code/message**。
// ```
//
// # 真网络读数（2026-10-27 实测，直连；原始行见 `.probe/csp-short-live.log`）
//
// ```text
// POST qryPageColumnVideo {columnId:1}       → 200 · 8926 B · code=000000 · total=312 · 9 条
//                                              list[0]={id:624,title:"黑球",appCoverUrl:"https://vidsite-file.oss-accelerate…jpg"}
// POST qryPageColumnVideo {columnId:2}       → 200 · code=000000 · total=108（电视剧）
// POST qryPageColumnVideo {columnId:3}       → 200 · code=000000 · total=16 （动漫）
// POST addAccessRecord {videoId:624,fprint}  → 200 · {"code":"000000","data":null}
// POST qryVideoDetail  {videoId:624,fprint}  → 200 · 1145 B · code=000000
//                                              data.resUrl=https://yun.139.com/shareweb/#/w/i/2yA8x3HAXdV06
//                                              data.title=黑球 · cateNameList=[2026,剧情,历史,西班牙,法国]
// POST qryPageColumnVideo {searchKey:"黑球"} → 200 · code=000000 · total=1
// POST qryPageColumnVideo {searchKey:"爱情"} → 200 · code=000000 · total=2
// ```
//
// ★ 如实登记的两条边界
// ```text
// ① `play` **不通**：resUrl 是移动云盘（139）分享页，取直链需要账号 + 转发服务，
//    本仓未接 ⇒ play 给可读 Err，不伪造直链（伪造 = 用户点了播不了，更糟）。
// ② `pageSize` 实测 9 / 18 都能出数据；DEX 里是 9 ⇒ 照抄 9（分页口径随之：pages=total/9）。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};
use crate::csp::shared::md5_hex;
use crate::tvbox::parse_loose_json;

/// DEX `f()` 里的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 站点根（DEX 常量逐字；同时是 Referer 的前缀）
pub const BASE: &str = "https://vidsite.cloudseekr.com";
/// 列表 / 搜索（**同一个端点**，靠体内 `searchKey` 区分）
const API_LIST: &str = "https://vidsite.cloudseekr.com/vidsite/vs/qryPageColumnVideo";
const API_ACCESS: &str = "https://vidsite.cloudseekr.com/vidsite/vs/addAccessRecord";
const API_DETAIL: &str = "https://vidsite.cloudseekr.com/vidsite/vs/qryVideoDetail";

/// 成功码（**字符串**，不是数字 0）
pub const OK_CODE: &str = "000000";

/// DEX 里的 pageSize（实测 9/18 都行，照抄 9）
pub const PAGE_SIZE: u32 = 9;

/// fprint 前缀（DEX `b()` 逐字）
pub const FPRINT_PREFIX: &str = "AiNewYiDong4K_";

const TIMEOUT: Duration = Duration::from_secs(20);

/// 分类：DEX `homeContent` 里三个写死的 `type_id`/`type_name`
pub const CATS: &[(&str, &str)] = &[("1", "电影"), ("2", "电视剧"), ("3", "动漫")];

pub struct Yidong4K {
    client: reqwest::Client,
    /// fprint 的单调序号：保证同一毫秒内的两次调用也得到不同 nano 段
    seq: std::sync::atomic::AtomicU64,
}

impl Yidong4K {
    pub const CLASS: &'static str = "Yidong4K";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // ★ 不读系统代理：代理会把"站点可用"测成"全宕"（全仓判据会扫这一行）。
            //   Host / Connection / Accept-Encoding 由 reqwest 按 URL 自动生成，
            //   实测与 DEX 手写值等价（见文件头读数）。
            .no_proxy()
            .build()
            .expect("build yidong_4k http client");
        Self {
            client,
            seq: std::sync::atomic::AtomicU64::new(0),
        }
    }

    /// 生成 fprint（DEX：md5("AiNewYiDong4K_<millis>_<nanoTime>")）
    fn fprint(&self) -> String {
        let ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let nano = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
            ^ (self
                .seq
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed) as u128);
        fprint_of(ms, nano)
    }

    /// 统一的 POST-JSON（10 个头里的 7 个显式写，其余交给 client）
    async fn post_json(&self, url: &str, body: &Value) -> Result<Value, String> {
        let text = self.post_text(url, body).await?;
        parse_loose_json(&text)
            .map_err(|e| format!("{url} 不是 JSON：{e}（前 160 字：{}）", head(&text)))
    }

    async fn post_text(&self, url: &str, body: &Value) -> Result<String, String> {
        let resp = self
            .client
            .post(url)
            .header(reqwest::header::ORIGIN, BASE)
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*")
            .header(reqwest::header::CACHE_CONTROL, "no-cache")
            .header(reqwest::header::PRAGMA, "no-cache")
            .header(reqwest::header::REFERER, format!("{BASE}/vid/app/"))
            .header(reqwest::header::CONTENT_TYPE, "application/json; charset=utf-8")
            .body(body.to_string())
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

    /// 打业务码：非 `000000` ⇒ Err（**带上 code/message**，别看 200 就当真）
    fn require_ok(url: &str, v: &Value) -> Result<(), String> {
        let code = v
            .get("code")
            .and_then(|c| match c {
                Value::String(s) => Some(s.clone()),
                Value::Number(n) => Some(n.to_string()),
                _ => None,
            })
            .unwrap_or_default();
        if code == OK_CODE {
            return Ok(());
        }
        let msg = v
            .get("message")
            .or_else(|| v.get("msg"))
            .and_then(|m| m.as_str())
            .unwrap_or("");
        Err(format!("{url} 业务码 code={code} message={msg}"))
    }
}

impl Default for Yidong4K {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（离线可测）
// ═══════════════════════════════════════════════════════════════════════

/// fprint 纯函数（DEX 的 `b()` 逐字）
pub fn fprint_of(millis: u128, nano: u128) -> String {
    md5_hex(&format!("{FPRINT_PREFIX}{millis}_{nano}"))
}

/// 列表请求体（`cateIdList` 在 DEX 里是 `[0,0,0]`）
pub fn list_body(column_id: &str, page: u32) -> Result<Value, String> {
    let col: i64 = column_id
        .trim()
        .parse()
        .map_err(|_| format!("分类 id 必须是整数：{column_id:?}"))?;
    Ok(serde_json::json!({
        "columnId": col,
        "cateIdList": [0, 0, 0],
        "pageIndex": page.max(1),
        "pageSize": PAGE_SIZE,
    }))
}

/// 搜索请求体（同端点 + `searchKey`）
pub fn search_body(kw: &str, page: u32) -> Value {
    serde_json::json!({
        "columnId": 0,
        "cateIdList": [0, 0, 0],
        "pageIndex": page.max(1),
        "pageSize": PAGE_SIZE,
        "searchKey": kw.trim(),
    })
}

/// 详情/埋点请求体
pub fn detail_body(video_id: &str, fprint: &str) -> Result<Value, String> {
    let id: i64 = video_id
        .trim()
        .parse()
        .map_err(|_| format!("视频 id 必须是整数：{video_id:?}"))?;
    Ok(serde_json::json!({ "videoId": id, "fprint": fprint }))
}

/// `data.list[]` → CspItem（DEX 的映射：id→vod_id, title→vod_name, appCoverUrl→vod_pic）
pub fn items_of(v: &Value) -> Vec<CspItem> {
    let arr = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array());
    arr.map(|a| a.iter().filter_map(item_of).collect())
        .unwrap_or_default()
}

fn item_of(row: &Value) -> Option<CspItem> {
    let id = match row.get("id") {
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::String(s)) if !s.trim().is_empty() => s.trim().to_string(),
        _ => return None,
    };
    let title = row.get("title").and_then(|t| t.as_str()).unwrap_or("").trim().to_string();
    if title.is_empty() {
        return None;
    }
    let cover = row
        .get("appCoverUrl")
        .and_then(|c| c.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let remark = row
        .get("remark")
        .and_then(|c| c.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    Some(CspItem {
        id,
        title,
        cover,
        subtitle: remark,
    })
}

/// 分页：DEX 用 `data.total` / `data.pages`
pub fn page_info(v: &Value) -> (Option<u64>, Option<u32>) {
    let d = v.get("data");
    let total = d
        .and_then(|d| d.get("total"))
        .and_then(|t| t.as_u64().or_else(|| t.as_str()?.parse().ok()));
    let pages = d
        .and_then(|d| d.get("pages"))
        .and_then(|p| p.as_u64().map(|n| n as u32).or_else(|| p.as_str()?.parse().ok()));
    (total, pages)
}

/// `data` → CspDetail（剧集来自 `resUrl`：网盘分享页）
pub fn detail_of(v: &Value, id: &str) -> Result<CspDetail, String> {
    let d = v
        .get("data")
        .filter(|d| d.is_object())
        .ok_or_else(|| format!("详情没有 data（id={id}，可能改版/风控壳页）"))?;
    let title = d.get("title").and_then(|t| t.as_str()).unwrap_or("").trim().to_string();
    if title.is_empty() {
        return Err(format!("详情 title 为空（id={id}）"));
    }
    let res = d.get("resUrl").and_then(|r| r.as_str()).unwrap_or("").trim();
    if res.is_empty() {
        return Err(format!(
            "「{title}」没有 resUrl（该条目没挂网盘资源；不是解析失败）"
        ));
    }
    let cover = d
        .get("appCoverUrl")
        .and_then(|c| c.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let mut desc = d
        .get("remark")
        .and_then(|r| r.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    // 分类标签拼在简介前（DEX 里 cateNameList 进 type_name；本仓 CspDetail 没有 type 字段）
    if let Some(tags) = d.get("cateNameList").and_then(|c| c.as_array()) {
        let joined: Vec<&str> = tags.iter().filter_map(|t| t.as_str()).collect();
        if !joined.is_empty() {
            let head_tag = joined.join(" / ");
            desc = Some(match desc {
                Some(s) => format!("[{head_tag}] {s}"),
                None => format!("[{head_tag}]"),
            });
        }
    }
    Ok(CspDetail {
        id: id.trim().to_string(),
        title: title.clone(),
        cover,
        description: desc,
        episodes: vec![CspEpisode {
            id: res.to_string(),
            title: format!("{title}（网盘分享页）"),
            flag: "移动云盘".to_string(),
        }],
    })
}

// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Yidong4K {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：DEX 只给 3 个分类（`{"class":[…],"filters":{}}`），**不预取条目**
    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let categories: Vec<CspCategory> = CATS
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        if categories.is_empty() {
            return Err("移动 4K 分类表为空（内置常量被清空了？）".to_string());
        }
        Ok(CspHome {
            categories,
            items: Vec::new(),
        })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let page = if page == 0 { 1 } else { page };
        let body = list_body(tid, page)?;
        let v = self.post_json(API_LIST, &body).await?;
        Self::require_ok(API_LIST, &v)?;
        let items = items_of(&v);
        if items.is_empty() {
            if page > 1 {
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total: None,
                });
            }
            return Err(format!(
                "分类 {tid} 第 1 页没解析出条目（可能模板改版/风控壳页）"
            ));
        }
        let (total, pages) = page_info(&v);
        Ok(CspList {
            items,
            page,
            page_count: pages,
            total,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let vid = id.trim();
        if vid.is_empty() {
            return Err("视频 id 为空".to_string());
        }
        let fp = self.fprint();
        let body = detail_body(vid, &fp)?;
        // ① 埋点（DEX 先打 addAccessRecord）：失败**不影响**详情，只是少一条访问记录
        if let Ok(txt) = self.post_text(API_ACCESS, &body).await {
            // 埋点成功/失败都不改变主流程；这里只解析一下形状，便于排障时留下真相
            if let Ok(j) = parse_loose_json(&txt) {
                let _ = Self::require_ok(API_ACCESS, &j);
            }
        }
        // ② 正题
        let v = self.post_json(API_DETAIL, &body).await?;
        Self::require_ok(API_DETAIL, &v)?;
        detail_of(&v, vid)
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let body = search_body(kw, page);
        let v = self.post_json(API_LIST, &body).await?;
        Self::require_ok(API_LIST, &v)?;
        let items = items_of(&v);
        if items.is_empty() {
            if page > 1 {
                return Ok(CspList {
                    items: Vec::new(),
                    page,
                    page_count: Some(page - 1),
                    total: None,
                });
            }
            return Err(format!(
                "搜索「{kw}」没解析出条目（可能模板改版/风控壳页）"
            ));
        }
        let (total, pages) = page_info(&v);
        Ok(CspList {
            items,
            page,
            page_count: pages,
            total,
        })
    }

    fn supports_search(&self) -> bool {
        // ★ true 的理由：真网实测 `searchKey="黑球"` → total=1、`"爱情"` → total=2
        true
    }

    /// 取流：`resUrl` 是**网盘分享页**（139 云盘），不是直链
    ///
    /// ★ 不伪造直链：把分享页 URL 当播放地址返回 = 用户点了播不了（假通）。
    ///   与 `pan_web_share.rs` 同一条边界：直链需要**账号 + 转发服务**，本仓未接。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let raw = id.trim();
        if raw.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if !crate::tvbox::starts_http(raw) {
            return Err(format!("播放 id 既不是直链也不是分享链接：{raw}"));
        }
        let lower = raw.to_ascii_lowercase();
        // 万一条目直接给了媒体地址（不是分享页），原样给 —— 真地址不编造
        if lower.contains(".m3u8") || lower.contains(".mp4") {
            return Ok(vec![CspPlay {
                url: raw.to_string(),
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some("直链".to_string()),
            }]);
        }
        if lower.contains("yun.139.com") {
            return Err(
                "这条是「移动云盘（139）分享页」：本机没有接入网盘转发服务，取不到直链，\
                 所以现在播不了（浏览/搜索/详情都正常，只有这一步要账号）"
                    .to_string(),
            );
        }
        Err(format!("这条链接不是已知网盘分享页，也不是直链媒体：{raw}"))
    }
}

// ══ 自注册 ══
//
// ① 订阅里这 1 站 ② host 是 DEX 常量（不需要 ext）
// ③ **真网取到数据**：list/detail/search 全部实测（见文件头读数）。
// ⚠️ `play` 不通（139 分享页需登录）——但那是**取流**边界，与"类可用"分开记，
//    与 `pan_web_share.rs`（注册了、play 如实报需要登录）同一口径。
crate::csp::register_site!(Yidong4K);

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── ① 真实响应片段（2026-10-27 实测，已截断）──

    const REAL_LIST: &str = r#"{"code":"000000","message":"请求成功","data":{"total":312,
        "list":[{"id":624,"shortCode":"bc7b350b","title":"黑球","resUrl":null,
                 "appCoverUrl":"https://vidsite-file.oss-accelerate.aliyuncs.com/vidsite/20261026/b08ceade.jpg",
                 "remark":""},
                {"id":625,"title":"第二个","appCoverUrl":"https://vidsite-file.oss-accelerate.aliyuncs.com/x.jpg",
                 "remark":"HD"}]}}"#;

    const REAL_DETAIL: &str = r#"{"code":"000000","message":"请求成功","data":{"id":624,"shortCode":"bc7b350b",
        "title":"黑球","resUrl":"https://yun.139.com/shareweb/#/w/i/2yA8x3HAXdV06",
        "appCoverUrl":"https://vidsite-file.oss-accelerate.aliyuncs.com/vidsite/20261026/b08ceade.jpg",
        "score":8.6,"remark":"影片以西班牙传奇同志诗人费德里戈·加西亚·洛尔卡一份仅存四页的未竟剧本《黑球》为锚点",
        "cateNameList":["2026","剧情","历史","西班牙","法国"]}}"#;

    #[test]
    fn real_list_parses_with_items_and_totals() {
        let v = parse_loose_json(REAL_LIST).expect("真实响应必须是合法 JSON");
        let items = items_of(&v);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "624");
        assert_eq!(items[0].title, "黑球");
        assert!(items[0].cover.as_deref().unwrap_or("").contains("vidsite-file"));
        assert!(items[0].subtitle.is_none(), "remark 空 ⇒ 不给副标题");
        assert_eq!(items[1].subtitle.as_deref(), Some("HD"));
        let (total, pages) = page_info(&v);
        assert_eq!(total, Some(312));
        assert_eq!(pages, None, "该响应里没有 pages 字段");
    }

    #[test]
    fn real_detail_yields_one_pan_share_episode() {
        let v = parse_loose_json(REAL_DETAIL).expect("真实响应必须是合法 JSON");
        let d = detail_of(&v, "624").expect("真实详情必须能解析");
        assert_eq!(d.title, "黑球");
        assert_eq!(d.episodes.len(), 1, "★ 单线路：一条网盘分享");
        assert_eq!(d.episodes[0].id, "https://yun.139.com/shareweb/#/w/i/2yA8x3HAXdV06");
        assert_eq!(d.episodes[0].flag, "移动云盘");
        // cateNameList 拼到简介前（不要让标签信息丢掉）
        assert!(d.description.as_deref().unwrap_or("").starts_with("[2026 / 剧情 / 历史"));
    }

    #[test]
    fn business_code_is_string_not_number() {
        let ok = parse_loose_json(REAL_LIST).unwrap();
        assert!(Yidong4K::require_ok(API_LIST, &ok).is_ok());
        // ★ 200 + code!=000000 必须 Err（别看 HTTP 状态码就当真）
        let bad = json!({"code":"100001","message":"参数异常"});
        let e = Yidong4K::require_ok(API_LIST, &bad).expect_err("非 000000 必须 Err");
        assert!(e.contains("100001") && e.contains("参数异常"), "{e}");
        // 连 code 都没有 ⇒ 也 Err（不是"成功但没有码"）
        let none = json!({"data":{}});
        assert!(Yidong4K::require_ok(API_LIST, &none).is_err());
    }

    // ── ② 空/坏 ⇒ Err ──

    #[test]
    fn empty_list_is_detectable() {
        let v = json!({"code":"000000","data":{"total":0,"list":[]}});
        assert!(items_of(&v).is_empty());
        assert!(items_of(&json!({"code":"000000","data":null})).is_empty());
    }

    #[test]
    fn detail_without_resurl_is_error_not_empty_ok() {
        let v = json!({"code":"000000","data":{"id":1,"title":"无资源","resUrl":""}});
        let e = detail_of(&v, "1").expect_err("没有 resUrl ⇒ 没有可播集 ⇒ 必须 Err");
        assert!(e.contains("resUrl"), "{e}");
        let e2 = detail_of(&json!({"code":"000000"}), "1").expect_err("没有 data 必须 Err");
        assert!(e2.contains("data"), "{e2}");
    }

    #[test]
    fn bodies_match_the_dex_shape() {
        assert_eq!(
            list_body("1", 2).unwrap(),
            json!({"columnId":1,"cateIdList":[0,0,0],"pageIndex":2,"pageSize":9})
        );
        assert!(list_body("电影", 1).is_err(), "非整数分类必须早失败");
        assert_eq!(
            search_body("黑球", 1),
            json!({"columnId":0,"cateIdList":[0,0,0],"pageIndex":1,"pageSize":9,"searchKey":"黑球"})
        );
        let db = detail_body("624", "abc").unwrap();
        assert_eq!(db["videoId"], json!(624));
        assert_eq!(db["fprint"], json!("abc"));
    }

    #[test]
    fn fprint_is_md5_of_the_dex_string() {
        let fp = fprint_of(1793116874758, 12345);
        assert_eq!(fp.len(), 32, "md5 是 32 位 hex：{fp}");
        assert_eq!(fp, md5_hex("AiNewYiDong4K_1793116874758_12345"));
        // 同一输入稳定、不同输入不同（否则签名会退化）
        assert_eq!(fp, fprint_of(1793116874758, 12345));
        assert_ne!(fp, fprint_of(1793116874758, 12346));
    }

    #[test]
    fn categories_are_the_three_dex_ones() {
        assert_eq!(CATS, &[("1", "电影"), ("2", "电视剧"), ("3", "动漫")]);
    }

    // ── ③ 注册项 + 契约形态 ──

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Yidong4K::CLASS, "Yidong4K");
    }

    #[test]
    fn registered_in_runtime_registry() {
        assert!(
            crate::csp::is_implemented("csp_Yidong4K"),
            "★ 三条判据都成立 ⇒ 必须真的在注册表里"
        );
    }

    #[test]
    fn client_builder_turns_off_proxy() {
        let src = crate::csp::shared::impl_src_only(include_str!("yidong_4k.rs"));
        let t = src.find(".timeout(TIMEOUT)").expect("必须有 timeout");
        let n = src.find(".no_proxy()").expect("★ 必须有 .no_proxy()");
        let b = src.find(".build()").expect("必须有 build");
        assert!(t < n && n < b, "★ .no_proxy() 必须在 timeout 之后、build 之前");
    }

    #[tokio::test]
    async fn pan_share_is_refused_honestly() {
        let s = Yidong4K::new();
        let e = s
            .play("", "https://yun.139.com/shareweb/#/w/i/2yA8x3HAXdV06", "")
            .await
            .expect_err("★ 分享页不是播放地址，必须 Err");
        assert!(e.contains("移动云盘"), "要点名哪家盘：{e}");
        assert!(e.contains("转发服务"), "要说清缺什么：{e}");
        assert!(!e.contains("尚未实现"), "类实现了，不许混用文案：{e}");
    }

    #[tokio::test]
    async fn direct_media_url_is_returned_as_is() {
        let s = Yidong4K::new();
        let got = s
            .play("", "https://cdn.example.com/a.m3u8", "")
            .await
            .expect("直链媒体应原样返回");
        assert_eq!(got[0].url, "https://cdn.example.com/a.m3u8");
    }

    #[tokio::test]
    async fn empty_inputs_are_rejected_before_network() {
        let s = Yidong4K::new();
        assert!(s.detail("  ", "").await.is_err());
        assert!(s.play("", "", "").await.is_err());
        assert!(s.search("  ", 1, "").await.is_err());
        assert!(s.list("", 1, "").await.is_err());
    }

    #[tokio::test]
    async fn home_returns_three_categories_without_network() {
        let s = Yidong4K::new();
        let h = s.home("").await.expect("分类是内置常量");
        assert_eq!(h.categories.len(), 3);
        assert!(h.items.is_empty(), "DEX 的 homeContent 不预取条目");
    }

    // ── ④ 真网络（`#[ignore]`，**走 Rust 代码**取数）──

    /// ★ 真网络用例：**不给 `CSP_LIVE=1` 就 assert 失败**（不做假绿）。
    ///
    /// 跑法：`CSP_LIVE=1 cargo test --lib csp::yidong_4k::tests::live_yidong -- --ignored --nocapture`
    #[tokio::test]
    #[ignore]
    async fn live_yidong_4k_list_detail_search() {
        assert!(
            std::env::var("CSP_LIVE").ok().as_deref() == Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1（不给就红）"
        );
        let s = Yidong4K::new();

        // ① 列表：columnId=1（电影）
        let l = s.list("1", 1, "").await.expect("live list(1) 必须成功");
        println!(
            "Yidong4K.list(column=1,page=1) → {} 条 · total={:?} · items[0]={{id:{},title:{}}}",
            l.items.len(),
            l.total,
            l.items[0].id,
            l.items[0].title
        );
        assert!(l.items.len() >= 5, "实测一页 9 条");
        assert!(l.total.unwrap_or(0) > 100, "实测 total=312");

        // ② 换一个分类（电视剧），证明 columnId 真的被用上
        let l2 = s.list("2", 1, "").await.expect("live list(2) 必须成功");
        println!(
            "Yidong4K.list(column=2,page=1) → {} 条 · total={:?}",
            l2.items.len(),
            l2.total
        );
        assert!(l2.total.unwrap_or(0) > 0);

        // ③ 详情：取第一条的 id（不写死 624，避免片库换了就红）
        let first_id = l.items[0].id.clone();
        let d = s.detail(&first_id, "").await.expect("live detail 必须成功");
        println!(
            "Yidong4K.detail({}) → title={} · episodes={} · 集[0].id={}",
            first_id,
            d.title,
            d.episodes.len(),
            d.episodes[0].id
        );
        assert_eq!(d.episodes.len(), 1, "单线路：一条网盘分享");
        assert!(
            d.episodes[0].id.starts_with("http"),
            "resUrl 必是网盘分享页 URL：{}",
            d.episodes[0].id
        );

        // ④ play：分享页必须**如实拒绝**（不伪造直链）
        let e = s
            .play("移动云盘", &d.episodes[0].id, "")
            .await
            .expect_err("★ 分享页不该被当播放地址");
        println!("Yidong4K.play(分享页) → Err: {e}");
        assert!(e.contains("移动云盘") || e.contains("网盘"), "{e}");

        // ⑤ 搜索
        let r = s.search("爱情", 1, "").await.expect("live search 必须成功");
        println!(
            "Yidong4K.search(爱情) → {} 条 · total={:?} · items[0].title={}",
            r.items.len(),
            r.total,
            r.items[0].title
        );
        assert!(!r.items.is_empty(), "实测「爱情」有结果");
    }
}
