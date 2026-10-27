// ═══════════════════════════════════════════════════════════════════════
//  csp_ShortWeiguan —— 「围观短剧」（api.drama.9ddm.com）的 Rust 重写（**本批注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么**有** `register_site!`（三条判据，逐条给证据）
// ```text
// ① 订阅里 1 站：`.probe/ref-subscription.json` → api=csp_ShortWeiguan（ext 为 null）
// ② 有可用 host：DEX 常量给的是整条 URL
//      https://api.drama.9ddm.com/drama/home/shortVideoTags
//      https://api.drama.9ddm.com/drama/home/search
//      https://api.drama.9ddm.com/drama/home/shortVideoDetail
//    ⇒ host = api.drama.9ddm.com
// ③ 真网取到数据（2026-10-28 00:1x 直连 `--noproxy '*'`，读数见 `.probe/csp-sports-live.log`）：
//    标签 30 个 · 列表 20 条/页 · 详情 100 集 · 取流真拿到 mp4
//    `https://tv-video.cdn.drama.9ddm.com/15/E3/…….mp4?timestamp=…&sign=…`
// ```
//
// # 协议（DEX 常量逐字还原 + 实测）
// ```text
// ★ 所有请求都带**同一串设备查询参数**（DEX 里 `w()` 逐字拼出来的）：
//   ?version_code=1600&version_name=1.6.0&device_name=<16位>&device_type=phone
//   &is_first_day=true&is_first_24h=true&app_launch_way=icon
//   &default_homepage=homepage_interaction&device_owning_firm=<16位>
//   &font_scale=default&os_type=1&clientInfo=<md5>
//   缺了它：**403 Forbidden**（实测：裸 URL 只带头 UA 时就是 403，body 是 `{"error":"Forbidden"}`）
//
// home    GET  /drama/home/shortVideoTags?<设备参数>
//         → tags[]（30 个字符串）
// list    POST /drama/home/search?<设备参数>     Content-Type: application/json
//         body {"cateId":"","audience":"","order":"","page":N,"pageSize":20,"searchWord":"","subject":""}
//         → data[] {title, oneId, horzPoster, vertPoster, shortPlayTag[], episodeCount, description…}
//         ★ 用 GET 传同名参数会回 `{"code":500,"msg":"服务器内部错误"}` —— 必须 POST + JSON 体
// detail  GET  /drama/home/shortVideoDetail?<设备参数>&oneId=<id>&page=1&pageSize=1000&userId=0&queryAll=true
//         → data[] 每集 {episodeOneId, playOrder, title, videoClarityList[{name,url}]}
// play    ★ 地址**在详情里就给了**（`videoClarityList[].url`，mp4 直链）
//         ⇒ 本实现把"集 id"设成那个 url，play 只做形态校验 + 补头，不再打站点
// ```
//
// # 两类"看起来支持"的坑（都实测过，写在这里免得下一个人重踩）
// ```text
// ① 分类：DEX 有 `cateId`/`subject`/`audience`/`order` 字段，**但服务端不认字符串**——
//    传 `subject":"逆袭"`、`audience":"男频"`、`order":"最热"` 一律 `{"code":500,"msg":"服务器内部错误"}`；
//    传数字 `subject":"1"` 回 200 但 data 为空；`cateId` 1..5 结果完全相同（被忽略）。
//    ⇒ 本实现**只提供「全部」分类 + 翻页**，不把 30 个标签做成"点进去必空"的假分类。
// ② 搜索：`searchWord` 放进 JSON 体 ⇒ 500；放进查询串 ⇒ 200 但**结果不变**（等于没过滤）。
//    ⇒ `supports_search() = false`，`search()` 手写 Err 并写清这两条实测。
// ```

use async_trait::async_trait;
use serde_json::Value;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const UA: &str = "okhttp/5.1.0";
const DEFAULT_HOST: &str = "https://api.drama.9ddm.com";
const TIMEOUT: Duration = Duration::from_secs(20);

/// DEX `<init>` 里的随机字符表（逐字）：设备名/厂商名就是从这 62 个字符里取
pub const ID_CHARSET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

/// 唯一分类：全部（不把标签做成假分类，理由见文件头）
pub const ALL_CAT: &str = "全部";

pub const PAGE_SIZE: u32 = 20;

/// 取流头：`videoClarityList` 在 CDN 上，带 Referer 更稳（不带也能下，但 DEX 的
/// `horzPoster`/`vertPoster` 都是 `pic.cdn.drama.9ddm.com`，同源 Referer 不违背站点策略）
pub const PLAY_HEADERS: &[(&str, &str)] =
    &[("Referer", "https://h5.drama.9ddm.com/"), ("User-Agent", "okhttp/5.1.0")];

pub fn host_of(ext: &str) -> String {
    let t = ext.trim();
    if t.starts_with("http://") || t.starts_with("https://") {
        return t.trim_end_matches('/').to_string();
    }
    if let Ok(j) = crate::tvbox::parse_loose_json(t) {
        for k in ["host", "apiDomain", "base"] {
            if let Some(s) = j.get(k).and_then(|v| v.as_str()) {
                let s = s.trim().trim_end_matches('/');
                if !s.is_empty() {
                    return s.to_string();
                }
            }
        }
    }
    DEFAULT_HOST.to_string()
}

/// 从 DEX 的 62 字符表里取 `n` 个字符（LCG；**只要求"每次不同"**，不要求密码学强度）
///
/// # 为什么不用 `rand`
/// 本仓纪律不新增运行时；设备名只是一个"让服务端觉得是新装的 App"的随机串。
pub fn device_id(seed: u64, n: usize) -> String {
    let mut x = seed ^ 0x9E37_79B9_7F4A_7C15;
    let mut out = String::with_capacity(n);
    for _ in 0..n {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.push(ID_CHARSET[(x % ID_CHARSET.len() as u64) as usize] as char);
    }
    out
}

/// DEX 里 `w()` 拼的那串设备参数（**逐字**顺序，直接拼进 query）
pub fn device_query(device_name: &str, firm: &str, client_info: &str) -> String {
    format!(
        "version_code=1600&version_name=1.6.0&device_name={device_name}&device_type=phone\
         &is_first_day=true&is_first_24h=true&app_launch_way=icon\
         &default_homepage=homepage_interaction&device_owning_firm={firm}\
         &font_scale=default&os_type=1&clientInfo={client_info}"
    )
}

/// 一次运行内稳定的设备身份（`clientInfo` = md5(device_name)，与实测可用形态一致）
fn identity() -> (String, String, String) {
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x1234_5678)
        ^ (std::process::id() as u64).rotate_left(23);
    let name = device_id(seed, 16);
    let firm = device_id(seed.rotate_left(29) ^ 0xA5A5_5A5A, 16);
    let ci = crate::csp::shared::md5_hex(&name);
    (name, firm, ci)
}

fn head(s: &str) -> String {
    s.chars().take(160).collect::<String>().replace('\n', " ")
}

fn text_of(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| {
        if let Some(s) = x.as_str() {
            let s = s.trim();
            if s.is_empty() {
                None
            } else {
                Some(s.to_string())
            }
        } else if x.is_number() {
            Some(x.to_string())
        } else {
            None
        }
    })
}

/// `tags` 响应 → 分类（首项「全部」）
///
/// 只回「全部」一个分类 —— 这是**刻意的**：标签做不成可点的分类（服务端 500，见文件头）。
pub fn parse_categories() -> Vec<CspCategory> {
    vec![CspCategory { id: String::new(), name: ALL_CAT.to_string() }]
}

/// 标签表（真网络时能在日志里看到 30 个；**不作为分类**，只用来验证接口活着）
pub fn parse_tags(text: &str) -> Result<Vec<String>, String> {
    let v: Value = crate::tvbox::parse_loose_json(text.trim())
        .map_err(|e| format!("tags 响应不是 JSON：{e}（前 120 字：{}）", head(text)))?;
    if v.get("code").and_then(|c| c.as_i64()) != Some(200) {
        return Err(format!(
            "tags 接口 code={:?}（{}）",
            v.get("code"),
            v.get("msg").and_then(|s| s.as_str()).unwrap_or("")
        ));
    }
    Ok(v.get("tags")
        .and_then(|t| t.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.to_string())).collect())
        .unwrap_or_default())
}

/// `search` 响应 → 条目
pub fn parse_list(text: &str) -> Result<Vec<CspItem>, String> {
    let v: Value = crate::tvbox::parse_loose_json(text.trim())
        .map_err(|e| format!("列表响应不是 JSON：{e}（前 120 字：{}）", head(text)))?;
    let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
    if code != 200 {
        return Err(format!(
            "列表接口 code={code}（{}）",
            v.get("msg").and_then(|s| s.as_str()).unwrap_or("")
        ));
    }
    let mut items = Vec::new();
    for d in v.get("data").and_then(|d| d.as_array()).map(|a| a.as_slice()).unwrap_or(&[]) {
        let id = match text_of(d, "oneId") {
            Some(s) => s,
            None => continue,
        };
        let title = text_of(d, "title").unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        let sub = {
            let mut s = String::new();
            if let Some(tags) = d.get("shortPlayTag").and_then(|t| t.as_array()) {
                let joined: Vec<&str> =
                    tags.iter().filter_map(|x| x.as_str()).collect();
                if !joined.is_empty() {
                    s.push_str(&joined.join("·"));
                }
            }
            if let Some(n) = d.get("episodeCount").and_then(|n| n.as_u64()) {
                if !s.is_empty() {
                    s.push(' ');
                }
                s.push_str(&format!("{n}集"));
            }
            if s.is_empty() {
                None
            } else {
                Some(s)
            }
        };
        items.push(CspItem {
            id,
            title,
            cover: text_of(d, "horzPoster").or_else(|| text_of(d, "vertPoster")),
            subtitle: sub,
        });
    }
    if items.is_empty() {
        return Err(format!(
            "列表解析出 0 条（明文 {} 字节）——可能上游改版/风控壳页（data 为空数组）",
            text.len()
        ));
    }
    Ok(items)
}

/// `shortVideoDetail` 响应 → 详情（每集的 `videoClarityList[].url` 就是直链）
pub fn parse_detail(text: &str, one_id: &str) -> Result<CspDetail, String> {
    let v: Value = crate::tvbox::parse_loose_json(text.trim())
        .map_err(|e| format!("详情响应不是 JSON：{e}（前 120 字：{}）", head(text)))?;
    let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(-1);
    if code != 200 {
        return Err(format!(
            "详情接口 code={code}（{}）",
            v.get("msg").and_then(|s| s.as_str()).unwrap_or("")
        ));
    }
    let title = text_of(&v, "title").ok_or_else(|| format!("详情没有 title（oneId={one_id}）"))?;
    let mut episodes: Vec<CspEpisode> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for ep in v.get("data").and_then(|d| d.as_array()).map(|a| a.as_slice()).unwrap_or(&[]) {
        let order = ep.get("playOrder").and_then(|p| p.as_u64()).unwrap_or(0);
        let clarities = ep
            .get("videoClarityList")
            .and_then(|c| c.as_array())
            .map(|a| a.as_slice())
            .unwrap_or(&[]);
        for c in clarities {
            let url = c.get("url").and_then(|u| u.as_str()).map(|s| s.trim()).unwrap_or("");
            if url.is_empty() || seen.iter().any(|s| s == url) {
                continue;
            }
            seen.push(url.to_string());
            let clarity = c.get("name").and_then(|n| n.as_str()).unwrap_or("").trim();
            episodes.push(CspEpisode {
                id: url.to_string(),
                title: if order > 0 { format!("第{order}集") } else { "分集".to_string() },
                flag: if clarity.is_empty() { "默认".to_string() } else { clarity.to_string() },
            });
        }
    }
    if episodes.is_empty() {
        return Err(format!(
            "「{title}」没有可播地址（`data[].videoClarityList` 全空，详情 {} 字节）——\
             可能该剧未上架/风控壳页",
            text.len()
        ));
    }
    Ok(CspDetail {
        id: one_id.to_string(),
        title,
        cover: text_of(&v, "vertPoster").or_else(|| text_of(&v, "vertPosterBgColor")),
        description: text_of(&v, "description"),
        episodes,
    })
}

// ══ 类自注册（三条判据都成立，见文件头）══
crate::csp::register_site!(ShortWeiguan);

pub struct ShortWeiguan {
    client: reqwest::Client,
}

impl ShortWeiguan {
    pub const CLASS: &'static str = "ShortWeiguan";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build short_weiguan http client");
        Self { client }
    }

    async fn get(&self, url: &str) -> Result<String, String> {
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
        Ok(text)
    }
}

impl Default for ShortWeiguan {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for ShortWeiguan {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let host = host_of(ext);
        let (dn, firm, ci) = identity();
        let q = device_query(&dn, &firm, &ci);
        // tags 只用来**证明接口活着**：分类表是固定的一项「全部」（理由见文件头）
        let tags = self.get(&format!("{host}/drama/home/shortVideoTags?{q}")).await?;
        let tags = parse_tags(&tags)?;
        if tags.is_empty() {
            return Err("标签接口回 200 但 tags 为空 —— 可能上游改版/风控壳页".to_string());
        }
        let body = serde_json::json!({
            "cateId": "", "audience": "", "order": "",
            "page": 1, "pageSize": PAGE_SIZE, "searchWord": "", "subject": ""
        });
        let text = self
            .client
            .post(format!("{host}/drama/home/search?{q}"))
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*")
            .header(reqwest::header::CONTENT_TYPE, "application/json; charset=utf-8")
            .body(body.to_string())
            .send()
            .await
            .map_err(|e| format!("列表请求失败（{host}）：{e}"))?
            .text()
            .await
            .map_err(|e| format!("列表响应读取失败：{e}"))?;
        let items = parse_list(&text)?;
        Ok(CspHome { categories: parse_categories(), items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let t = tid.trim();
        // 只有「全部」一个分类；数字 cateId 原样透传（实测被服务端忽略，但形状合法）
        if !t.is_empty() && t.parse::<u32>().is_err() {
            return Err(format!(
                "ShortWeiguan 没有分类 `{t}`：服务端对字符串筛选（subject/audience/order）\
                 一律回 500，标签做不成分类；本类只支持「全部」（id 为空）与数字 cateId"
            ));
        }
        let page = if page == 0 { 1 } else { page };
        let host = host_of(ext);
        let (dn, firm, ci) = identity();
        let q = device_query(&dn, &firm, &ci);
        let body = serde_json::json!({
            "cateId": t, "audience": "", "order": "",
            "page": page, "pageSize": PAGE_SIZE, "searchWord": "", "subject": ""
        });
        let text = self
            .client
            .post(format!("{host}/drama/home/search?{q}"))
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*")
            .header(reqwest::header::CONTENT_TYPE, "application/json; charset=utf-8")
            .body(body.to_string())
            .send()
            .await
            .map_err(|e| format!("列表请求失败（{host}）：{e}"))?
            .text()
            .await
            .map_err(|e| format!("列表响应读取失败：{e}"))?;
        let items = parse_list(&text)?;
        Ok(CspList {
            items,
            page,
            // 站点没给总页数/总数（data 只有数组）⇒ 如实 None，不猜
            page_count: None,
            total: None,
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let _ = (kw, page, ext);
        Err("ShortWeiguan 不支持搜索：`searchWord` 放进 JSON 体 ⇒ 上游 500；\
             放进查询串 ⇒ 200 但结果与不过滤完全相同（等于没搜）。\
             DEX 里虽然有 `searchWord` 字段，但服务端当前不接受它 —— 不声明假能力"
            .to_string())
    }

    fn supports_search(&self) -> bool {
        false
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let one_id = id.trim();
        if one_id.is_empty() {
            return Err("ShortWeiguan detail 的 id（oneId）为空".to_string());
        }
        let host = host_of(ext);
        let (dn, firm, ci) = identity();
        let q = device_query(&dn, &firm, &ci);
        let url = format!(
            "{host}/drama/home/shortVideoDetail?{q}&oneId={}&page=1&pageSize=1000&userId=0&queryAll=true",
            urlencoding::encode(one_id)
        );
        let text = self.get(&url).await?;
        parse_detail(&text, one_id)
    }

    async fn play(&self, flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let _ = ext;
        let url = id.trim();
        if url.is_empty() {
            return Err("ShortWeiguan play 的 id 为空".to_string());
        }
        if !url.starts_with("http") {
            return Err(format!(
                "ShortWeiguan play 的 id 应该是详情里 `videoClarityList[].url`，实际是 `{}`",
                head(url)
            ));
        }
        Ok(vec![CspPlay {
            url: url.to_string(),
            headers: PLAY_HEADERS
                .iter()
                .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
                .collect(),
            label: Some(if flag.trim().is_empty() { "默认".to_string() } else { flag.to_string() }),
        }])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 真实 `shortVideoTags` 响应（2026-10-28 00:1x，字段裁到 tags/前 5 项，其余逐字）
    const REAL_TAGS: &str = r#"{"code":200,"msg":"success","tags":["逆袭","都市","家庭","古装","复仇"],"audiences":["男频","女频"]}"#;

    /// 真实 `search` 响应（前两条，字段裁剪；`oneId`/`horzPoster`/`shortPlayTag` 逐字）
    const REAL_LIST: &str = r#"{"code":200,"msg":"success","data":[
      {"title":"我靠赶海爆赚千万第二季","oneId":"110000071281327902","shortPlayTag":["脑洞","异能"],
       "viewCount":1182046,"description":"名牌大学生叶峰……","horzPoster":"https://pic.cdn.drama.9ddm.com/cp-platform/02a65451.jpg","episodeCount":100},
      {"title":"被拐二十年，我装穷回家试探全家","oneId":"110000071281327777","shortPlayTag":["逆袭","家庭"],
       "viewCount":222,"horzPoster":"https://pic.cdn.drama.9ddm.com/cp-platform/aaaaaaaa.jpg","episodeCount":60}
    ]}"#;

    /// 真实 `shortVideoDetail` 响应（第一集，`videoClarityList` 逐字保留）
    const REAL_DETAIL: &str = r#"{"code":200,"msg":"success","data":[
      {"episodeOneId":"120000071307740048","playOrder":1,"title":"我靠赶海爆赚千万第二季","playLength":81,
       "videoClarityList":[{"name":"1080P","url":"https://tv-video.cdn.drama.9ddm.com/15/E3/15E36DA8.mp4?timestamp=1793116759&sign=2c197ba7"}]},
      {"episodeOneId":"120000071307740049","playOrder":2,"title":"我靠赶海爆赚千万第二季","playLength":90,
       "videoClarityList":[{"name":"1080P","url":"https://tv-video.cdn.drama.9ddm.com/15/E3/AAAA.mp4?timestamp=1793116760&sign=deadbeef"}]}
    ],"oneId":"110000071281327902","title":"我靠赶海爆赚千万第二季","vertPoster":"https://pic.cdn.drama.9ddm.com/cp-platform/8185f1ac.jpg","description":"名牌大学生叶峰……"}"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(ShortWeiguan::CLASS, "ShortWeiguan");
    }

    #[test]
    fn must_be_registered_this_batch() {
        assert!(crate::csp::is_implemented("csp_ShortWeiguan"), "★ 三条判据成立 ⇒ 要注册");
        let flat = crate::csp::shared::impl_src_only(include_str!("short_weiguan.rs"));
        assert!(flat.contains("register_site!(ShortWeiguan)"));
    }

    /// 设备参数是**逐字**的 DEX 形态（缺字段 ⇒ 403，实测）
    #[test]
    fn device_query_keeps_the_dex_shape() {
        let q = device_query("DEV", "FIRM", "MD5");
        for k in [
            "version_code=1600",
            "version_name=1.6.0",
            "device_name=DEV",
            "device_type=phone",
            "is_first_day=true",
            "is_first_24h=true",
            "app_launch_way=icon",
            "default_homepage=homepage_interaction",
            "device_owning_firm=FIRM",
            "font_scale=default",
            "os_type=1",
            "clientInfo=MD5",
        ] {
            assert!(q.contains(k), "设备参数缺 `{k}`：{q}");
        }
        // 随机串只取 DEX 的字符表
        let id = device_id(42, 16);
        assert_eq!(id.len(), 16);
        assert!(id.bytes().all(|b| ID_CHARSET.contains(&b)), "越界字符：{id}");
        assert_ne!(device_id(42, 16), device_id(43, 16), "不同种子要不同");
    }

    #[test]
    fn tags_and_list_parse_real_payload() {
        let tags = parse_tags(REAL_TAGS).expect("真实 tags 必须能解析");
        assert_eq!(tags.len(), 5);
        assert_eq!(tags[0], "逆袭");

        let items = parse_list(REAL_LIST).expect("真实列表必须能解析");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "110000071281327902");
        assert_eq!(items[0].title, "我靠赶海爆赚千万第二季");
        assert_eq!(items[0].subtitle.as_deref(), Some("脑洞·异能 100集"));
        assert!(items[0].cover.as_deref().unwrap_or("").contains("pic.cdn.drama.9ddm.com"));
    }

    /// ★ 空结果必须 Err（诚实契约第 1 条）
    #[test]
    fn empty_list_is_an_error() {
        let e = parse_list(r#"{"code":200,"msg":"success","data":[]}"#).expect_err("★ 0 条必须 Err");
        assert!(e.contains("风控壳页"), "{e}");
        // 上游 code!=200 也要 Err，且带上游 msg
        let e2 = parse_list(r#"{"code":500,"msg":"服务器内部错误","data":null}"#).expect_err("code 500 必须 Err");
        assert!(e2.contains("服务器内部错误"), "{e2}");
        // tags 空也要 Err（home 用它证明接口活着）
        assert!(parse_tags(r#"{"code":200,"tags":[]}"#).unwrap().is_empty());
    }

    #[test]
    fn detail_maps_episodes_from_real_payload() {
        let d = parse_detail(REAL_DETAIL, "110000071281327902").expect("真实详情必须能解析");
        assert_eq!(d.title, "我靠赶海爆赚千万第二季");
        assert_eq!(d.episodes.len(), 2);
        assert_eq!(d.episodes[0].title, "第1集");
        assert_eq!(d.episodes[0].flag, "1080P");
        assert!(d.episodes[0].id.starts_with("https://tv-video.cdn.drama.9ddm.com/"));
        assert!(d.description.as_deref().unwrap_or("").contains("叶峰"));
    }

    #[test]
    fn detail_without_playable_urls_is_an_error() {
        let page = r#"{"code":200,"data":[{"episodeOneId":"1","playOrder":1,"videoClarityList":[]}],"title":"某剧"}"#;
        let e = parse_detail(page, "1").expect_err("★ 0 条地址必须 Err");
        assert!(e.contains("没有可播地址"), "{e}");
    }

    #[test]
    fn categories_are_only_all_and_search_is_refused_honestly() {
        let cats = parse_categories();
        assert_eq!(cats.len(), 1, "★ 不把标签做成假分类（服务端 500）");
        assert_eq!(cats[0].name, ALL_CAT);
        let s = ShortWeiguan::new();
        assert!(!s.supports_search(), "★ 搜索实测无效 ⇒ 不许声明 true");
        let rt = tokio::runtime::Runtime::new().unwrap();
        let e = rt.block_on(s.search("逆袭", 1, "")).expect_err("★ 必须 Err");
        assert!(e.contains("500"), "要把实测证据写进 Err：{e}");
        // play 拒绝非 URL
        let e2 = rt.block_on(s.play("1080P", "120000071307740048", "")).expect_err("非 URL 必须 Err");
        assert!(e2.contains("videoClarityList"), "{e2}");
    }

    /// ★ 真网络（默认 ignore）：`cargo test --lib csp::short_weiguan::tests::live_ -- --ignored --nocapture`
    #[tokio::test]
    #[ignore = "真网络：直连 api.drama.9ddm.com（不走系统代理），人工触发"]
    async fn live_chain_home_list_detail_play() {
        let s = ShortWeiguan::new();
        let home = s.home("").await.expect("★ live: home 必须取到条目");
        println!(
            "LIVE ShortWeiguan home cats={} items={} first={}",
            home.categories.len(),
            home.items.len(),
            home.items[0].title
        );
        let list = s.list("", 2, "").await.expect("★ live: list 第 2 页");
        println!("LIVE ShortWeiguan list p2 n={} first={}", list.items.len(), list.items[0].title);
        let d = s.detail(&home.items[0].id, "").await.expect("★ live: detail 必须取到分集");
        println!("LIVE ShortWeiguan detail title={} eps={}", d.title, d.episodes.len());
        let plays = s.play(&d.episodes[0].flag, &d.episodes[0].id, "").await.expect("★ live: play");
        println!("LIVE ShortWeiguan play url={}", plays[0].url);
    }
}
