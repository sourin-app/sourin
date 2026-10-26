// ═══════════════════════════════════════════════════════════════════════
//  csp_Ikanbot —— "爱看｜蓝光秒播"（多线路 / 带 UA+Referer 的同源取流）
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证（DEX 常量，`Lcom/github/catvod/spider/Ikanbot;` class_def #257，14 个方法）
// ```text
// 列表   /kanlist  /article  /{cateId}.html  /{cateId}-p-{n}.html
//        选择器：div.reslut-list div.media / div.v-list div.item / div#video-list div.item
//                img[data-src]   h5   .title a[href]
// 详情   页面隐藏字段 id="current_id" / id="mtype" / id="e_token"
//        → /api/getResN?videoId={current_id}&mtype={mtype}&token={e_token}
//        请求头 X-Requested-With: XMLHttpRequest、Accept: */*、Referer
//        响应 data.resData[] —— **每个元素 = 一条线路**
// 拼接   vod_play_from：线路名用 `$$$` 连
//        vod_play_url ：每线 `#` 分集、`名$址`、线路之间 `$$$`
// 取流   e() 也按 `$$$` 处理；UA = Chrome/151，Referer = https://www.douban.com
// ```
// 站点域名在 DEX 里只出现一次：`www1.ikanbot.com`（ext 为 None，所以用它兜底）。
//
// # ⚠️ 当前状态（2026-10-26 真网络实测）：**浏览通、详情未通**
// ```text
// home  ✅ 6 个分类（实测导航：全部/电影/剧集/动漫/综艺/纪录片），首屏 48 条
// list  ✅ /category/1（电影）48 条
// detail ❌ /api/getResN 返回 {"state":-401,"message":"unauthorized","data":{}} —— **不是解析问题**
//        原因：页面里的 `e_token` 是**被解扰过的**，DEX 的 `Ikanbot.get_tks(String)` 才是解码器：
//        它把 token 按分隔符切开、每段当整数当**下标**、再按下标从原串取子串拼回去。
//        直接拿隐藏 input 里的 e_token 去请求 ⇒ 401。
// play   ⏸ 未验（detail 没线路就无从取流）
// 路径校正（DEX 模板 ≠ 真路径）：
//        /kanlist 404  /{cateId}.html 未见 → 真路径是 **/category/{n}**、详情 **/play/{id}**
//        列表结构：div.v-list > .item > a[href="/play/…"] > img[data-src] + <p>标题</p>
//        详情隐藏字段：id="current_id" / id="mtype"(=1) / id="e_token"
// 弹幕/去广告：**无法确认** —— 401 拿不到 resData，DEX 常量里也没有 danmaku/改写逻辑
// ```

// # 线路维度
// 本实现把每条线路的每一集都塞进 `CspEpisode`，并**用 `flag` 记线路名** ——
// 这正是 `CspEpisode.flag` 这个字段存在的理由（见 `csp/mod.rs` 的注释）。
// UI 按 `flag` 分组即可显示"线路1/线路2/…"。
//
// # 未做（如实）
// ```text
// · 弹幕：DEX 常量里没有 danmaku/弹幕/barrage 之类串 ⇒ 目前**没有弹幕地址可映射**
// · 去广告：DEX 里没有对 m3u8/播放地址的改写逻辑 ⇒ 原版也没做，我们不臆造
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const DEFAULT_BASE: &str = "https://www1.ikanbot.com";
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
/// DEX 里的 Referer（部分线路的 CDN 会校验）
const REFERER: &str = "https://www.douban.com";

const GET_TIMEOUT: Duration = Duration::from_secs(12);

pub struct Ikanbot {
    client: reqwest::Client,
}

impl Ikanbot {
    pub const CLASS: &'static str = "Ikanbot";

    /// 首页分类（DEX 的 `homeContent` 里是固定几条；这里按站点导航的固定语义给出）
    ///
    /// ⚠️ 说明：DEX 的 homeContent 常量里能看到 `/kanlist` 与 `/article` 两个入口，
    /// 具体分类 id 是从首页导航抓的。这里**写死两个已知入口**，其余从 `/{cateId}.html` 里点进来。
    /// ⚠️ 以下按 **2026-10-26 实测**（不是 DEX 常量）：DEX 里只有 `/kanlist`、`/article`、
    /// `/{cateId}.html` 这类模板串；真站点的分类在 `/category/{n}`。
    /// ```text
    /// /category/   200  → 导航里给出 6 个入口（下表就是抓下来的）
    /// /category/1  电影  /category/2 剧集  /category/18 动漫
    /// /category/19 综艺  /category/20 纪录片
    /// /kanlist     404（DEX 里的模板串不等于真路径）
    /// ```
    pub const CATEGORIES: &'static [(&'static str, &'static str)] = &[
        ("", "全部"),
        ("1", "电影"),
        ("2", "剧集"),
        ("18", "动漫"),
        ("19", "综艺"),
        ("20", "纪录片"),
    ];

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(GET_TIMEOUT)
            .no_proxy() // 同其它 csp 源：不读系统代理
            .build()
            .expect("build ikanbot http client");
        Self { client }
    }

    pub fn base_of(ext: &str) -> String {
        crate::tvbox::parse_loose_json(ext)
            .ok()
            .and_then(|j| {
                j.get("site")
                    .and_then(|s| s.as_array())
                    .and_then(|a| a.first())
                    .and_then(|v| v.as_str())
                    .map(|s| s.trim_end_matches('/').to_string())
                    .or_else(|| {
                        j.get("host")
                            .and_then(|v| v.as_str())
                            .map(|s| s.trim_end_matches('/').to_string())
                    })
            })
            .unwrap_or_else(|| DEFAULT_BASE.to_string())
    }

    async fn get(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::REFERER, REFERER)
            .send()
            .await
            .map_err(|e| format!("请求 {url} 失败：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取 {url} 失败：{e}"))?;
        if !status.is_success() {
            let head: String = text.chars().take(120).collect();
            return Err(format!("HTTP {}（{url}）：{head}", status.as_u16()));
        }
        Ok(text)
    }

    /// `/api/getResN` —— XHR 接口，必须带 `X-Requested-With`
    async fn get_res(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::REFERER, REFERER)
            .header(reqwest::header::ACCEPT, "*/*")
            .header("X-Requested-With", "XMLHttpRequest")
            .send()
            .await
            .map_err(|e| format!("请求 {url} 失败：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取 {url} 失败：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "HTTP {}（{url}）：{}",
                status.as_u16(),
                text.chars().take(120).collect::<String>()
            ));
        }
        Ok(text)
    }
}

impl Default for Ikanbot {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  解析
// ═══════════════════════════════════════════════════════════════════════

/// 去掉 `<style>/<script>` 整段（页面里有 CSS 文本会污染标记匹配；FirstAid 踩过这个坑）
fn strip_style_script(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut rest = html;
    loop {
        let a = rest.find("<style").map(|i| (i, "</style>"));
        let b = rest.find("<script").map(|i| (i, "</script>"));
        let next = match (a, b) {
            (None, None) => break,
            (Some(x), None) => Some(x),
            (None, Some(y)) => Some(y),
            (Some(x), Some(y)) => Some(if x.0 <= y.0 { x } else { y }),
        };
        let (i, close) = next.expect("有 next 必有值");
        out.push_str(&rest[..i]);
        match rest[i..].find(close) {
            Some(j) => rest = &rest[i + j + close.len()..],
            None => return out,
        }
    }
    out.push_str(rest);
    out
}

fn take_attr(seg: &str, attr: &str) -> Option<String> {
    let i = seg.find(&format!("{attr}=\""))?;
    let r = &seg[i + attr.len() + 2..];
    r.find('"').map(|e| r[..e].trim().to_string())
}

/// 列表页解析（**实测结构**，2026-10-26）
///
/// ```html
/// <div class="v-list"><div class="row list-wp">
///   <div class="col-xs-4 ... item">
///     <a class="item" href="/play/1029683">
///       <div class="embed-responsive cover-wp">
///         <img id="1029683" class="img-responsive lazy" src="data:image/svg+xml,…"
///              data-src="https://tu.某视频站zyimg.com/upload/…jpg" />
///       </div>
///       <p>快跑那个星际指挥官是白岂第二季</p>
///     </a>
///   </div> …
/// ```
/// ⚠️ DEX 里的三套选择器（`div.reslut-list div.media` / `div.v-list div.item` /
/// `div#video-list div.item`）只有第二套对得上真站点；前两套在真页面上 `class="media"` 为 0 次。
pub fn list_from_html(html: &str, page: u32, path: &str) -> Result<CspList, String> {
    let html = strip_style_script(html);
    let mut items: Vec<CspItem> = Vec::new();
    let mut from = 0usize;
    while let Some(rel) = html[from..].find("href=\"/play/") {
        let at = from + rel;
        from = at + 10;
        let seg_end = at + html[at..].chars().take(700).map(|c| c.len_utf8()).sum::<usize>();
        let seg = &html[at..seg_end.min(html.len())];
        let id = take_attr(seg, "href")
            .filter(|h| h.starts_with("/play/"))
            .map(|h| h.trim_end_matches('"').to_string());
        let title = seg
            .find("<p>")
            .and_then(|i| {
                let r = &seg[i + 3..];
                r.find("</p>")
                    .map(|e| crate::tvbox::decode_entities(&r[..e]).trim().to_string())
            })
            .filter(|t| !t.is_empty());
        let (id, title) = match (id, title) {
            (Some(a), Some(b)) => (a, b),
            _ => continue,
        };
        let cover = take_attr(seg, "data-src").filter(|s| s.starts_with("http"));
        if items.iter().any(|x| x.id == id) {
            continue;
        }
        items.push(CspItem {
            id,
            title,
            cover,
            subtitle: None,
        });
        if items.len() >= 60 {
            break;
        }
    }
    if items.is_empty() {
        return Err(format!(
            "{path} 页面能打开但没解析出条目（`a[href^=/play/]` 一个都没命中；站点可能改版）"
        ));
    }
    Ok(CspList {
        items,
        page,
        page_count: None,
        total: None,
    })
}


/// `Ikanbot.get_tks(String videoId, String t)` 的复刻（DEX `code_off=2595488`）
///
/// # 寄存器级读数（这才是对的，之前那版是我猜错的）
/// ```text
///  2  v1 = videoId.length()
///  6  v2 = v1 - 4                      ← ★ 取**最后 4 个字符**（不是"去掉末位"）
///  8  v5 = videoId.substring(v2, v1)
/// 12  v5 = v5.split("")                ← 每字符一个元素（Java 无前导空串）
/// 21  v2 = 0                           ← 下标
/// 25  v3 = v5[v2]                      ← 当前字符
/// 31  if-eqz → 34 / 33 goto 146        ← 空串就跳出
/// 34  v3 = Integer.parseInt(v3)
/// 38  v3 = v3 % 3                      ← op_dc = rem-int/lit8, lit=3
/// 40  v4 = v3 + 1                      ← start = d%3 + 1
/// 42  v3 = v3 + 9                      ← end   = d%3 + 9
/// 44  v4 = t.substring(v4, v3)         ← 取 8 个字符
/// 48  sb.append(v4)
/// 55  t = t.substring(v3, len)         ← 消费掉前 (d%3+9) 个字符
/// 59  v2 += 1  → 61 goto 74（循环）
/// ```
/// ⇒ **取 videoId 末 4 位，每位数字 d：从 t 的 `[d%3+1 .. d%3+9)` 取 8 字符追加，然后把 t 截到 `[d%3+9 ..)`。**
///
/// # 实证（2026-10-26 直连）
/// ```text
/// videoId=1001027, e_token=oi4b2d060alae0c9843snad4003c8bcv384fe414
///   → get_tks = 4b2d060aae0c9843d4003c8b384fe414（32 位）
///   → GET /api/getResN?videoId=1001027&mtype=1&token=… → {"state":1,"message":"success", …}
/// ```
pub fn get_tks(video_id: &str, t: &str) -> String {
    let chars: Vec<char> = video_id.chars().collect();
    let tail: Vec<char> = if chars.len() >= 4 {
        chars[chars.len() - 4..].to_vec()
    } else {
        chars.clone()
    };
    let mut rest: Vec<char> = t.chars().collect();
    let mut out = String::new();
    for ch in tail {
        let d = match ch.to_digit(10) {
            Some(d) => (d % 3) as usize,
            None => break,
        };
        let start = d + 1;
        let end = d + 9;
        if start >= rest.len() {
            break;
        }
        let take: String = rest[start..end.min(rest.len())].iter().collect();
        out.push_str(&take);
        rest = if end < rest.len() { rest[end..].to_vec() } else { Vec::new() };
    }
    out
}

/// 从详情页取三个隐藏字段
pub fn hidden_fields(html: &str) -> (Option<String>, Option<String>, Option<String>) {
    let grab = |id: &str| -> Option<String> {
        let needle = format!("id=\"{id}\"");
        let at = html.find(&needle)?;
        let rest = &html[at + needle.len()..];
        // 形如 id="current_id" value="123"
        let v = rest.find("value=\"")?;
        let r = &rest[v + 7..];
        r.find('"').map(|e| r[..e].trim().to_string()).filter(|s| !s.is_empty())
    };
    (grab("current_id"), grab("mtype"), grab("e_token"))
}

/// 诊断：打印 `data.list[]` 每个元素的**键名**（只在 CSP_LIVE=1 时输出）
///
/// 用途：确认"弹幕/去广告"能不能做 —— 只有看到真实键名才能下结论，不靠猜。
pub fn dump_res_keys(v: &serde_json::Value) {
    if std::env::var("CSP_LIVE").is_err() {
        return;
    }
    let arr = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|r| r.as_array())
        .cloned()
        .unwrap_or_default();
    eprintln!("[IKAN] data.list 元素数 = {}", arr.len());
    for (i, it) in arr.iter().take(3).enumerate() {
        let keys: Vec<String> = it
            .as_object()
            .map(|o| o.keys().cloned().collect())
            .unwrap_or_default();
        eprintln!("[IKAN] list[{i}] 键 = {keys:?}");
        if let Some(raw) = it.get("resData").and_then(|x| x.as_str()) {
            let short: String = raw.chars().take(120).collect();
            eprintln!("[IKAN]     resData = {short}");
        }
    }
}

/// 解析 `/api/getResN` 的响应，展开成"每条线路 × 每集"
///
/// # 真实结构（2026-10-26 直连拿到，与 DEX 常量对得上）
/// ```json
/// {"state":1,"message":"success","data":{"list":[
///    {"siteId":26,"id":21207802,
///     "resData":"[{\"flag\":\"xlm3u8\",\"url\":\"正片$https://play.xluuss.com/play/…/index.m3u8\"}]"},
///    {"siteId":36,"id":21207803,"resData":"[{…\"flag\":\"gsm3u8\"…}]"}
/// ]}}
/// ```
/// ★ 两个坑：
/// ```text
/// ① 线路在 `data.list[]` 里，**不是** `data.resData[]`；
/// ② 每个 list 元素的 `resData` 是一段 **JSON 字符串**（双重编码），要再 parse 一次；
/// ③ `url` 是 `名字$地址` 形式，多条用 `#` 分隔。
/// ```
pub fn lines_of(v: &serde_json::Value) -> Vec<(String, Vec<(String, String)>)> {
    let list = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array())
        .cloned()
        .unwrap_or_default();
    let mut out: Vec<(String, Vec<(String, String)>)> = Vec::new();
    for (i, elem) in list.iter().enumerate() {
        let raw = elem.get("resData").and_then(|x| x.as_str()).unwrap_or("");
        let arr: Vec<serde_json::Value> = if raw.trim().is_empty() {
            // 少数情况 resData 可能已经是数组
            elem.get("resData")
                .and_then(|x| x.as_array())
                .cloned()
                .unwrap_or_default()
        } else {
            match crate::tvbox::parse_loose_json(raw) {
                Ok(serde_json::Value::Array(a)) => a,
                _ => Vec::new(),
            }
        };
        let mut eps: Vec<(String, String)> = Vec::new();
        let mut flag = String::new();
        for item in &arr {
            if flag.is_empty() {
                flag = item
                    .get("flag")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .trim()
                    .to_string();
            }
            let url = item.get("url").and_then(|x| x.as_str()).unwrap_or("");
            for (k, part) in url.split('#').enumerate() {
                let part = part.trim();
                if part.is_empty() {
                    continue;
                }
                let (name, addr) = match part.split_once('$') {
                    Some((n, a)) => (n.trim().to_string(), a.trim().to_string()),
                    None => (format!("第{}集", k + 1), part.to_string()),
                };
                if addr.is_empty() {
                    continue;
                }
                eps.push((name, addr));
            }
        }
        if eps.is_empty() {
            continue;
        }
        if flag.is_empty() {
            flag = format!("线路{}", i + 1);
        }
        out.push((flag, eps));
    }
    out
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Ikanbot {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let base = Self::base_of(ext);
        let categories: Vec<CspCategory> = Self::CATEGORIES
            .iter()
            .map(|(id, name)| CspCategory {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect();
        let html = self.get(&format!("{base}/category/")).await?;
        let first = list_from_html(&html, 1, "/category/")?;
        Ok(CspHome {
            categories,
            items: first.items,
        })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let base = Self::base_of(ext);
        let page = if page == 0 { 1 } else { page };
        /*
         * 实测：分类页是 `/category/{n}`（DEX 的 `/{cateId}.html` 模板在真站点上 404）。
         * 分页参数真站点用 `?page=N`（首页无参）。
         */
        let path = if tid.trim().is_empty() {
            format!("/category/?page={page}")
        } else if page <= 1 {
            format!("/category/{}", tid.trim())
        } else {
            format!("/category/{}?page={page}", tid.trim())
        };
        let html = self.get(&format!("{base}{path}")).await?;
        list_from_html(&html, page, &path)
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let base = Self::base_of(ext);
        let url = if id.starts_with("http") {
            id.to_string()
        } else {
            format!("{base}{id}")
        };
        let html = self.get(&url).await?;
        let (cur, mtype, token) = hidden_fields(&html);
        let (vid, mt, tk) = match (cur, mtype, token) {
            (Some(a), Some(b), Some(c)) => (a, b, c),
            _ => {
                return Err(format!(
                    "详情页缺隐藏字段（current_id/mtype/e_token 至少要三个都有）；id={id}"
                ))
            }
        };
        // ★ token 不是原样用：DEX 里是 `Ikanbot.get_tks(videoId, e_token)` 之后才拼进 URL
        let real_token = get_tks(&vid, &tk);
        if std::env::var("CSP_LIVE").is_ok() {
            eprintln!("[IKAN] e_token={tk} → get_tks={real_token}");
        }
        let api = format!("{base}/api/getResN?videoId={vid}&mtype={mt}&token={real_token}");
        let body = self.get_res(&api).await?;
        let v = crate::tvbox::parse_loose_json(&body)
            .map_err(|e| format!("/api/getResN 不是 JSON：{e}"))?;
        dump_res_keys(&v);
        let lines = lines_of(&v);
        if lines.is_empty() {
            let keys: Vec<String> = v
                .get("data")
                .and_then(|d| d.as_object())
                .map(|o| o.keys().cloned().collect())
                .unwrap_or_default();
            let state = v.get("state").map(|x| x.to_string()).unwrap_or_default();
            let msg = v.get("msg").or_else(|| v.get("message")).and_then(|x| x.as_str()).unwrap_or("");
            return Err(format!(
                "/api/getResN 没有可解析的线路（state={state} message={msg}；data 顶层键={keys:?}）；id={id}"
            ));
        }
        let line_count = lines.len();
        let mut episodes: Vec<CspEpisode> = Vec::new();
        for (flag, eps) in lines {
            for (title, url) in eps {
                episodes.push(CspEpisode {
                    id: url,
                    title,
                    flag: flag.clone(),
                });
            }
        }
        // 标题：h5 / .title（页面里取，取不到就用 id）
        let title = html
            .find("<h5")
            .and_then(|i| {
                let r = &html[i..];
                r.find('>').and_then(|g| {
                    let t = &r[g + 1..];
                    t.find('<').map(|l| crate::tvbox::decode_entities(&t[..l]).trim().to_string())
                })
            })
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| id.to_string());
        let _ = line_count;
        Ok(CspDetail {
            id: id.to_string(),
            title,
            cover: take_attr(&html, "data-src").filter(|s| s.starts_with("http")),
            description: None,
            episodes,
        })
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("Ikanbot 不支持搜索（该类的搜索入口未在 DEX 常量里确认）".to_string())
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let url = id.trim();
        if !crate::tvbox::starts_http(url) {
            return Err(format!("播放 id 不是 http 地址：{url}"));
        }
        Ok(vec![CspPlay {
            url: url.to_string(),
            // DEX 的取流头：UA + Referer（部分 CDN 缺 Referer 会 403）
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                ("Referer".to_string(), REFERER.to_string()),
            ],
            label: Some("爱看线路".to_string()),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;


    #[test]
    fn get_tks_matches_real_vector_from_live_site() {
        // ★ 实测向量（2026-10-26 直连 /play/1001027 拿到的真值）
        //   videoId=1001027, e_token=oi4b2d060alae0c9843snad4003c8bcv384fe414
        //   ⇒ 4b2d060aae0c9843d4003c8b384fe414（32 位，用它请求 /api/getResN 返回 state=1 success）
        let tok = "oi4b2d060alae0c9843snad4003c8bcv384fe414";
        let got = get_tks("1001027", tok);
        assert_eq!(
            got, "4b2d060aae0c9843d4003c8b384fe414",
            "★ 算法：取 videoId **末 4 位**，每位 d ⇒ [d%3+1, d%3+9) 取 8 字符，再 t=t[d%3+9..]"
        );
        assert_eq!(got.len(), 32, "实测是 32 位（像 md5），不是 8 位");

        // 只看末 4 位：前缀不同、末 4 位相同 ⇒ 结果相同
        assert_eq!(get_tks("99991027", tok), got);
        // 末 4 位不同 ⇒ 结果不同（否则"取末4位"这条就没被断言到）
        assert_ne!(get_tks("1001028", tok), got);
        // 太短 ⇒ 不 panic
        assert_eq!(get_tks("", tok), "");
    }

    #[test]
    fn lines_of_decodes_doubly_encoded_res_data() {
        // ★ 真实形状：data.list[] 的 resData 是 **JSON 字符串**，要二次 parse
        let v: serde_json::Value = crate::tvbox::parse_loose_json(
            r#"{"state":1,"message":"success","data":{"list":[
                 {"siteId":26,"id":21207802,
                  "resData":"[{\"flag\":\"xlm3u8\",\"url\":\"正片$https://a/1.m3u8\"}]"},
                 {"siteId":36,"id":21207803,
                  "resData":"[{\"flag\":\"gsm3u8\",\"url\":\"第1集$https://b/1.m3u8#第2集$https://b/2.m3u8\"}]"}
               ]}}"#,
        )
        .unwrap();
        let lines = lines_of(&v);
        assert_eq!(lines.len(), 2, "★ 两个 list 元素 = 两条线路");
        assert_eq!(lines[0].0, "xlm3u8", "flag 就是线路名");
        assert_eq!(lines[0].1.len(), 1);
        assert_eq!(lines[0].1[0].0, "正片", "`名$址` 拆开后是集名");
        assert_eq!(lines[0].1[0].1, "https://a/1.m3u8");
        assert_eq!(lines[1].0, "gsm3u8");
        assert_eq!(lines[1].1.len(), 2, "`#` 分集");
        assert_eq!(lines[1].1[1].1, "https://b/2.m3u8");
    }

    #[test]
    fn lines_of_skips_empty_res_data_and_broken_json() {
        let v: serde_json::Value = crate::tvbox::parse_loose_json(
            r#"{"data":{"list":[
                 {"siteId":1,"resData":"[]"},
                 {"siteId":2,"resData":"不是 JSON"},
                 {"siteId":3,"resData":"[{\"flag\":\"okm3u8\",\"url\":\"正片$https://c/1.m3u8\"}]"}
               ]}}"#,
        )
        .unwrap();
        let lines = lines_of(&v);
        assert_eq!(lines.len(), 1, "空列表与坏 JSON 都要跳过，只留能解析的那条");
        assert_eq!(lines[0].0, "okm3u8");
        // 完全没有 data.list ⇒ 空（由 detail 负责报错，不在这里 panic）
        let none: serde_json::Value = crate::tvbox::parse_loose_json(r#"{"state":-401}"#).unwrap();
        assert!(lines_of(&none).is_empty());
    }

    #[test]
    fn list_parses_real_markup_and_errs_when_empty() {
        // 真实结构（2026-10-26 抓到的 /category/ 页面）：v-list > .item > a[href="/play/…"]
        //   > img[data-src] + <p>标题</p>
        let html = r#"
          <script>var css = ".v-list .item";</script>
          <div class="v-list"><div class="row list-wp">
            <div class="col-xs-4 item">
              <a class="item" href="/play/1029683">
                <div class="cover-wp"><img class="lazy"
                     src="data:image/svg+xml,%3Csvg" data-src="https://tu.example/a.jpg" /></div>
                <p>快跑那个星际指挥官是白岂第二季</p>
              </a>
            </div>
            <div class="col-xs-4 item">
              <a class="item" href="/play/1001027"><p>蜘蛛侠：崭新之日</p></a>
            </div>
          </div></div>"#;
        let l = list_from_html(html, 1, "/category/").expect("应解析成功");
        assert_eq!(l.items.len(), 2, "两条，实际 {:?}", l.items);
        assert_eq!(l.items[0].id, "/play/1029683");
        assert_eq!(l.items[0].title, "快跑那个星际指挥官是白岂第二季");
        assert_eq!(l.items[0].cover.as_deref(), Some("https://tu.example/a.jpg"));
        assert_eq!(l.items[1].id, "/play/1001027");

        let err = list_from_html("<html><body>空</body></html>", 1, "/category/")
            .expect_err("0 条必须 Err");
        assert!(err.contains("没解析出条目"), "{err}");
    }

    #[tokio::test]
    async fn play_carries_ua_and_referer() {
        let s = Ikanbot::new();
        let v = s.play("线路A", "https://cdn.example/a.m3u8", "").await.expect("应成功");
        assert_eq!(v[0].url, "https://cdn.example/a.m3u8");
        let has = |k: &str| v[0].headers.iter().any(|(kk, _)| kk == k);
        assert!(has("User-Agent"), "★ 必须带 UA");
        assert!(has("Referer"), "★ 必须带 Referer（DEX 里的取流头）");
        assert!(s.play("", "/play/1.html", "").await.is_err());
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_ikanbot --release -- --ignored --nocapture"]
    async fn csp_live_ikanbot_four_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Ikanbot::new();
        let ext = "";
        let home = s.home(ext).await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {} 个，首屏 {} 条，首条={}",
            home.categories.len(),
            home.items.len(),
            home.items.first().map(|i| i.title.clone()).unwrap_or_default()
        );
        let list = s.list("1", 1, ext).await.expect("list 应成功");
        eprintln!("[LIVE] list(category/1 电影): {} 条", list.items.len());
        let id = list.items[0].id.clone();
        match s.detail(&id, ext).await {
            Ok(d) => {
                let mut flags: Vec<String> = d.episodes.iter().map(|e| e.flag.clone()).collect();
                flags.dedup();
                eprintln!(
                    "[LIVE] detail({id}): 标题={} 集数={} **线路数={}** 线路={:?}",
                    d.title,
                    d.episodes.len(),
                    flags.len(),
                    flags
                );
                let ep = d.episodes[0].id.clone();
                let plays = s.play(&d.episodes[0].flag, &ep, ext).await.expect("play 应成功");
                eprintln!(
                    "[LIVE] play: url={} headers={:?}",
                    plays[0].url,
                    plays[0].headers.iter().map(|(k, _)| k.clone()).collect::<Vec<_>>()
                );
            }
            Err(e) => panic!("[LIVE] detail 失败：{e}"),
        }
    }
}
