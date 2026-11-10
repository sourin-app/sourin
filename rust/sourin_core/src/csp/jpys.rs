// ═══════════════════════════════════════════════════════════════════════
//  csp_Jpys —— TVBox `csp_Jpys` 的 Rust 重写（「金牌影视」蓝光秒播）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么（实测取自 `.probe/ref-subscription.json`）
//
// ```json
// {"key":"金牌影视","name":"🧿金牌｜蓝光秒播","type":3,"api":"csp_Jpys",
//  "ext":"https://m.610pkea.com,https://y2s52n7.com,https://m.hkybqufgh.com,
//         https://m.sizhengxt.com,https://m.9zhoukj.com,https://m.jiabaide.cn"}
// ```
// ⇒ **站点从 ext 取**：逗号分隔的**多域名**，逐个探活（`checkDomainValid` 用 HEAD）。
//    同一个类换 ext 就是另一个站。
//
// # ★ 签名协议（反汇编复原 + 真网络实证，2026-10-27）
//
// ```text
// 从 `.probe/r3-batchA-Jpys.disasm.txt`（dex 直读，非 jadx）读出：
//   categoryContent：query = "area={area}&pageNum={page}&type1={type1}&year={year}&key={key}&t={now}"
//                    sign  = Jpys.sha1( FM.o.z.a(query) )
//                    FM.o.z.a(String) 的实现体 = MessageDigest.getInstance("MD5")
//                                            + String.getBytes("UTF-8")
//                                            + digest() + BigInteger(1,digest).toString(16)
//                                            ⇒ 即 **md5 的 16 进制小写**
//                    Jpys.sha1(String)  的实现体 = MessageDigest.getInstance("SHA-1")
//                                            ⇒ 即 **sha1 的 16 进制小写**
//   key  = "cb808529bae6b6be45ecfab29a4889bc"   （Jpys.init 里 iput 的常量）
//   请求头 = { sign: <sign>, T: <now>, Deviceid: <UUID> }
//   URL   = {domain}/api/mw-movie/anonymous/video/list?type1={type1}&pageNum={page}&area={area}&year={year}
//            （★ URL 里**没有** key/t —— 那两个只进 query 参与签名，见 categoryContent 的
//              StringBuilder 组装顺序：area → pageNum → type1 → year → key → t）
// ```
//
// ★ **实证读数（2026-10-27 真打上游）**：
// ```text
// GET https://y2s52n7.com/api/mw-movie/anonymous/video/list?type1=1&pageNum=1&area=&year=
//   头 sign/T/Deviceid
//   ⇒ HTTP 200  {"code":200,"msg":"操作成功",
//                 "data":{"totalCount":10000,"pageNum":1,"pageSize":48,"totalPage":209,
//                         "list":[{"vodId":147748,"vodName":"大力水手4：复活","vodClass":"恐怖",
//                                  "vodPic":"https://…", …}]}}
// GET /api/mw-movie/anonymous/home/hotSearch（同签名）
//   ⇒ HTTP 200  {"code":200, … "data":[{"vodId":147594,"vodName":"嫁金钗", …}]}
// 其余 4 个域名当时 403（`m.610pkea.com` / `m.sizhengxt.com` / `m.9zhoukj.com` / `m.jiabaide.cn`）
// ⇒ 这正是 `checkDomainValid` 存在的理由：**ext 里 6 个域名，不是每个都活**。
// ```
//
// # ⚠️ 已知缺口（Lead 已裁定本批不做，如实登记，不静默丢）
// ```text
// ① `mProxy`：DEX 里 Jpys 没有该方法（见 `.probe/decompiled/r3dex-spider.json` 的
//    methods 清单：<clinit>/<init>/categoryContent/checkDomainValid/detailContent/
//    getUUID/homeContent/init/playerContent/sha1/searchContent —— **无 mProxy**）。
//    ⇒ 本批"mProxy 不做"对该类**零影响**，登记只为对齐契约。
// ② `loadPic`：DEX 里也**没有**。取图只需 Referer/UA ⇒ 走源 `cover_headers`（声明式）。
// ③ `initApi`：DEX 无此方法（本类的 init(Context,String) 只做 ext 解析）。
// ④ `isVideoFormat` / `manualVideoCheck`：**DEX 里 Jpys 没有这两个方法**
//    （对照 AppYsV2 有）⇒ 该类不存在这两个位。
// ```

use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use serde_json::Value;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 浏览器/客户端 UA（反汇编里 playerContent 用的那一条，逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36";

/// 签名密钥（`Jpys.init` 里 iput 的常量）
const SIGN_KEY: &str = "cb808529bae6b6be45ecfab29a4889bc";

/// 上游路径（全部来自反汇编的 const-string）
const P_LIST: &str = "/api/mw-movie/anonymous/video/list";
const P_HOT: &str = "/api/mw-movie/anonymous/home/hotSearch";
const P_SEARCH: &str = "/api/mw-movie/anonymous/video/searchByWord";
const P_DETAIL: &str = "/api/mw-movie/anonymous/video/detail";
const P_EPISODE: &str = "/api/mw-movie/anonymous/v2/video/episode/url";

/// 兜底域名（ext 没给时用实证可用的那个）
const DEFAULT_DOMAIN: &str = "https://y2s52n7.com";

// ═══════════════════════════════════════════════════════════════════════
//  签名（纯函数，全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// md5 的 16 进制小写 —— 等价于 `FM.o.z.a(String)`
pub fn md5_hex(s: &str) -> String {
    use md5::{Digest, Md5};
    let mut h = Md5::new();
    h.update(s.as_bytes());
    let out = h.finalize();
    let mut r = String::with_capacity(32);
    for b in out {
        r.push_str(&format!("{b:02x}"));
    }
    r
}

/// sha1 的 16 进制小写 —— 等价于 `Jpys.sha1(String)`
pub fn sha1_hex(s: &str) -> String {
    use ring::digest;
    let out = digest::digest(&digest::SHA1_FOR_LEGACY_USE_ONLY, s.as_bytes());
    let mut r = String::with_capacity(40);
    for b in out.as_ref() {
        r.push_str(&format!("{b:02x}"));
    }
    r
}

/// 签名 = `sha1_hex(md5_hex(query))` —— 等价于 `sha1(FM.o.z.a(query))`
///
/// # 为什么这一层不能省
/// ```text
/// 上游是**两层哈希**（先 MD5 再 SHA-1）。只做一层会得到 code:122012「应用签名不可为空」
/// 或其它鉴权错 —— 实测：不带 sign 头 ⇒ `{"code":122012,"msg":"应用签名不可为空"}`。
/// ```
pub fn sign_of(query: &str) -> String {
    sha1_hex(&md5_hex(query))
}

/// 组装**列表**段的签名 query（**顺序即 DEX 里的 append 顺序**，不能重排）
pub fn sign_query(area: &str, page: u32, type1: &str, year: &str, t: &str) -> String {
    format!("area={area}&pageNum={page}&type1={type1}&year={year}&key={SIGN_KEY}&t={t}")
}

/// 组装**搜索**段的签名 query
///
/// ⚠️ ★★ **这一段与列表段不同，且是"真网读数逼出来的"**（2026-10-27）
/// ```text
/// 第一版按 DEX searchContent 的 append 顺序照抄成
///   `keyword=..&pageNum=1&pageSize=8&key=..&t=..`
/// 拿去真打上游 ⇒ **{"code":122001,"msg":"应用签名失败"}**。
/// 实测枚举（`keyword` 那侧的区别才是关键）：
///   keyword=战狼（**原文**）&pageNum=1&pageSize=8&key=..&t=..   → **code:200**（8 条真结果）
///   keyword=%E6%88%98%E7%8B%BC（URL 编码）&…                  → code:122001
///   /api/…/searchByWord?…&key=..&t=..（整条路径进签名）        → code:122001
/// ```
/// ⇒ 结论：**签名串里的 keyword 是原文，URL 里的 keyword 才做 URLEncoder**。
///    这正是 DEX 里两个 StringBuilder 的分工（URL 那个 append 了
///    `URLEncoder.encode(kw)`，签名那个直接用 `kw`）—— 第一版把它们混成了一个。
pub fn sign_query_search(kw: &str, page: u32, t: &str) -> String {
    format!("keyword={kw}&pageNum={page}&pageSize=8&key={SIGN_KEY}&t={t}")
}

/// 组装**详情**段的签名 query（实测：`id=<id>&key=<key>&t=<ms>`）
pub fn sign_query_detail(id: &str, t: &str) -> String {
    format!("id={id}&key={SIGN_KEY}&t={t}")
}

/// 组装**取流**段的签名 query（实测：`id=<vodId>&nid=<nid>&key=<key>&t=<ms>`）
pub fn sign_query_episode(vid: &str, nid: &str, t: &str) -> String {
    format!("id={vid}&nid={nid}&key={SIGN_KEY}&t={t}")
}

/// `now` 毫秒（`System.currentTimeMillis()` 的等价）
pub fn now_ms() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
        .to_string()
}

/// Deviceid —— 等价于 `UUID.randomUUID().toString()`，**进程内只生成一次**
///
/// 实测该头不会被服务端校验内容（固定 UUID 也能 200），但忠实按 UUID 形态生成。
///
/// ⚠️ `fill` 是 `SecureRandom` trait 的方法 —— **不 `use` 这个 trait 就报
///    "method not found"**（`SystemRandom` 自身没有这个方法）。本仓用 `ring` 是因为
///    它已在依赖树里（`reqwest → rustls → ring`），**不新增依赖**。
pub fn device_id() -> &'static str {
    use ring::rand::SecureRandom;
    static ID: OnceLock<String> = OnceLock::new();
    ID.get_or_init(|| {
        let mut b = [0u8; 16];
        if ring::rand::SystemRandom::new().fill(&mut b).is_err() {
            // 拿不到真随机就退化成时间派生的固定串（**不 panic**：取不到随机不该让整个源挂掉）
            let ms = now_ms();
            let s = md5_hex(&ms);
            return format!(
                "{}-{}-{}-{}-{}",
                &s[0..8], &s[8..12], &s[12..16], &s[16..20], &s[20..32]
            );
        }
        b[6] = (b[6] & 0x0f) | 0x40; // version 4
        b[8] = (b[8] & 0x3f) | 0x80; // variant
        let h = |r: &[u8]| -> String { r.iter().map(|x| format!("{x:02x}")).collect() };
        format!(
            "{}-{}-{}-{}-{}",
            h(&b[0..4]),
            h(&b[4..6]),
            h(&b[6..8]),
            h(&b[8..10]),
            h(&b[10..16])
        )
    })
    .as_str()
}

// ═══════════════════════════════════════════════════════════════════════
//  ext 解析 + 域名探活
// ═══════════════════════════════════════════════════════════════════════

/// 从 ext 取域名表（逗号分隔；也容忍 JSON 数组文本）
///
/// ⚠️ 刻意**不整体解析 ext JSON**：`ext` 只有"站点在哪"这一件事，
///    整段 JSON 解析会把"上游多一个字段"变成硬失败。
pub fn domains_of(ext: &str) -> Vec<String> {
    let t = ext.trim();
    if t.is_empty() {
        return vec![DEFAULT_DOMAIN.to_string()];
    }
    let mut out: Vec<String> = Vec::new();
    for raw in t.split(|c| c == ',' || c == '\n' || c == ';') {
        // 从每一段里抠出 http(s) 开头的原样域名
        let piece = raw.trim().trim_matches('"').trim_matches('[').trim_matches(']');
        let mut cur = String::new();
        for tok in piece.split_whitespace() {
            let tok = tok.trim_matches('"').trim_end_matches(',');
            if tok.starts_with("http") {
                cur = tok.trim_end_matches('/').to_string();
                break;
            }
        }
        if cur.is_empty() && piece.starts_with("http") {
            cur = piece.trim_end_matches('/').to_string();
        }
        if !cur.is_empty() && !out.contains(&cur) {
            out.push(cur);
        }
    }
    if out.is_empty() {
        out.push(DEFAULT_DOMAIN.to_string());
    }
    out
}

/// 探活判据：**`200 <= code <= 399` 才算这个域名可用**（DEX `checkDomainValid` 的等价）
///
/// # 为什么必须是这个区间而不是 `< 500`
/// ```text
/// 第一版写 `< 500` ⇒ 实测 403 的域名被当成"可用" ⇒ **永远选中被拦的那个**
/// （ext 里第一个就是 403），后面能用的 5 个轮不到。
/// 现象是"这个源打不通"，真因是域名选择 —— 见本文件测试
/// `probe_status_ok_is_the_dex_interval_not_under_500`。
/// ```
pub fn probe_status_ok(code: u16) -> bool {
    (200..=399).contains(&code)
}

/// 从域名表里挑第一个**探活可用**的（`alive` 由调用方注入真正的探活）
///
/// # 为什么把探活抽成参数
/// ```text
/// 这样"跳过被拦的第一个域名"这条行为**能在离线门禁里稳定验**
/// （喂一个 `alive` 闭包即可），不必依赖真网 —— 而真网的读数另在 CSP_LIVE 段留档。
/// ```
///
/// ⚠️ `alive` 收 `&'a str` 且返回的 future **借同一个 `'a`**（`Fut: Future + 'a`），
///    且 `doms` 也必须是 `'a`：早先写成 `F: Fn(&str) -> Fut` 会报
///    "lifetime may not live long enough"；只给 `Fut: 'a` 会报
///    "explicit lifetime required in the type of `doms`"。两处都要标。
pub async fn pick_domain_from<'a, F, Fut>(doms: &'a [String], alive: F) -> String
where
    F: Fn(&'a str) -> Fut,
    Fut: std::future::Future<Output = bool> + 'a,
{
    for d in doms {
        if alive(d).await {
            return d.clone();
        }
    }
    // 全不可用 ⇒ **仍返回第一个**：不在这里造"站点全挂"的结论（探活失败可能只是 HEAD 被拦），
    // 让真正的请求去报错 —— 错误里会带上它试的是哪个域名。
    doms.first()
        .cloned()
        .unwrap_or_else(|| DEFAULT_DOMAIN.to_string())
}

// ═══════════════════════════════════════════════════════════════════════
//  响应解析（纯函数，可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// 上游统一的 `code` 判据：**只有 200 才是成功**
///
/// ★ 不把"缺 code"当成功 —— 那会把一个错误页解析成 0 条，用户看到空列表却不知道原因。
///
/// ⚠️ 生命周期必须写 `'a`（同时借 `v` 与 `what`）：只写 `&Value` 会报
///    "missing lifetime specifier" —— 返回值借的是 `v`，而 `what` 只进错误串。
pub fn ensure_ok<'a>(v: &'a Value, what: &str) -> Result<&'a Value, String> {
    let code = v.get("code").and_then(|c| c.as_i64());
    match code {
        Some(200) => Ok(v),
        Some(c) => Err(format!(
            "上游 {what} 返回 code={c}（msg={}）",
            v.get("msg").and_then(|m| m.as_str()).unwrap_or("")
        )),
        None => Err(format!("上游 {what} 响应里没有 code 字段（可能被拦或改协议了）")),
    }
}

/// 从 `data.list[]` 抽条目；**0 条 ⇒ Err**（反空真：不许把空集当成功）
pub fn items_from_list(v: &Value, what: &str) -> Result<Vec<CspItem>, String> {
    let arr = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array())
        .ok_or_else(|| format!("上游 {what} 响应里没有 data.list（键名可能变了）"))?;
    let items: Vec<CspItem> = arr
        .iter()
        .filter_map(|o| {
            let id = o.get("vodId").map(|x| x.to_string().trim_matches('"').to_string())?;
            let title = o.get("vodName").and_then(|x| x.as_str())?.to_string();
            Some(CspItem {
                id,
                title,
                cover: o
                    .get("vodPic")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string()),
                subtitle: o
                    .get("vodRemarks")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.is_empty())
                    .or_else(|| o.get("vodVersion").and_then(|x| x.as_str()))
                    .map(|s| s.to_string()),
            })
        })
        .collect();
    if items.is_empty() {
        return Err(format!(
            "上游 {what} 解析出 0 条（data.list 有 {} 项但无一条能取出 vodId/vodName）",
            arr.len()
        ));
    }
    Ok(items)
}

/// 搜索：条目在 `data.result.list[]`（**实测**：`data` 下还有 `typeResult`，
/// 两者都是 `{totalCount,pageNum,pageSize,totalPage,list}`）
///
/// ⚠️ **不是** `data.list` —— 我第一版按"list 兼容"写法先在 `data.list` 找，
/// 真打后才发现是 `data.result.list`（见 `.probe/r3-batchA-inspect.log` 的真网读数）。
pub fn search_items_of(v: &Value, what: &str) -> Result<Vec<CspItem>, String> {
    ensure_ok(v, what)?;
    let arr = v
        .get("data")
        .and_then(|d| d.get("result"))
        .and_then(|r| r.get("list"))
        .and_then(|l| l.as_array())
        .ok_or_else(|| {
            format!(
                "上游 {what} 响应里没有 data.result.list（实际 data 键：{:?}）",
                v.get("data")
                    .and_then(|d| d.as_object())
                    .map(|o| o.keys().cloned().collect::<Vec<_>>())
                    .unwrap_or_default()
            )
        })?;
    let items: Vec<CspItem> = arr
        .iter()
        .filter_map(|o| {
            let id = o
                .get("vodId")
                .map(|x| x.to_string().trim_matches('"').to_string())?;
            let title = o.get("vodName").and_then(|x| x.as_str())?.to_string();
            Some(CspItem {
                id,
                title,
                cover: o
                    .get("vodPic")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.is_empty())
                    .map(String::from),
                subtitle: o
                    .get("vodRemarks")
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.is_empty())
                    .map(String::from),
            })
        })
        .collect();
    if items.is_empty() {
        return Err(format!(
            "上游 {what} 的 data.result.list 解析出 0 条（list 有 {} 项）",
            arr.len()
        ));
    }
    Ok(items)
}

/// `data[]` 形态（hotSearch 用的就是数组，不是 list）
pub fn items_from_data_array(v: &Value, what: &str) -> Result<Vec<CspItem>, String> {
    let arr = v
        .get("data")
        .and_then(|d| d.as_array())
        .ok_or_else(|| format!("上游 {what} 响应里没有 data[]（键名可能变了）"))?;
    let items: Vec<CspItem> = arr
        .iter()
        .filter_map(|o| {
            let id = o.get("vodId").map(|x| x.to_string().trim_matches('"').to_string())?;
            let title = o.get("vodName").and_then(|x| x.as_str())?.to_string();
            Some(CspItem {
                id,
                title,
                cover: o.get("vodPic").and_then(|x| x.as_str()).map(|s| s.to_string()),
                subtitle: o
                    .get("vodRemarks")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string()),
            })
        })
        .collect();
    if items.is_empty() {
        return Err(format!("上游 {what} 解析出 0 条（data[] 有 {} 项）", arr.len()));
    }
    Ok(items)
}

/// 详情：`data` 对象 → `CspDetail`
///
/// 剧集来自 `data.episodeList[]`；DEX 里集名走 `name`，集 id 走 `nid`。
pub fn detail_from(v: &Value, id: &str) -> Result<CspDetail, String> {
    ensure_ok(v, "视频详情")?;
    let d = v
        .get("data")
        .and_then(|x| x.as_object())
        .ok_or_else(|| "上游视频详情响应里没有 data 对象".to_string())?;
    let title = d
        .get("vodName")
        .and_then(|x| x.as_str())
        .unwrap_or(id)
        .to_string();
    let episodes = episode_list_of(d.get("episodeList"));
    if episodes.is_empty() {
        return Err(format!(
            "上游视频详情 {id} 的 episodeList 解析出 0 集（键名可能变了）"
        ));
    }
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover: d.get("vodPic").and_then(|x| x.as_str()).map(|s| s.to_string()),
        description: d
            .get("vodBlurb")
            .or_else(|| d.get("vodContent"))
            .and_then(|x| x.as_str())
            .map(|s| s.to_string()),
        episodes,
    })
}

/// `episodeList[]` → 剧集（DEX：`name` 是集名，`nid` 是集 id）
pub fn episode_list_of(v: Option<&Value>) -> Vec<CspEpisode> {
    let mut out = Vec::new();
    if let Some(arr) = v.and_then(|x| x.as_array()) {
        for (i, e) in arr.iter().enumerate() {
            let nid = e
                .get("nid")
                .map(|x| x.to_string().trim_matches('"').to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| (i + 1).to_string());
            let name = e
                .get("name")
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
                .unwrap_or_else(|| format!("第{}集", i + 1));
            out.push(CspEpisode {
                id: nid,
                title: name,
                // 单线路源：flag 固定「在线播放」（DEX detailContent 里那条 const-string）
                flag: "在线播放".to_string(),
            });
        }
    }
    out
}

/// 取流：`data.list[]` 里第一条 `url`
pub fn play_url_of(v: &Value) -> Result<String, String> {
    ensure_ok(v, "取流")?;
    let arr = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array())
        .ok_or_else(|| "上游取流响应里没有 data.list".to_string())?;
    for o in arr {
        if let Some(u) = o.get("url").and_then(|x| x.as_str()).filter(|s| !s.is_empty()) {
            return Ok(u.to_string());
        }
    }
    Err("上游取流响应 data.list 里没有任何 url（可能该集无源）".to_string())
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct Jpys {
    client: super::http_context::CspHttpContext,
}

impl Jpys {
    pub const CLASS: &'static str = "Jpys";

    /// 首页分类（DEX homeContent 的 const-string：1电影 / 2电视剧 / 4动漫 / 3综艺）
    const CATS: &'static [(&'static str, &'static str)] =
        &[("1", "电影"), ("2", "电视剧"), ("4", "动漫"), ("3", "综艺")];

    pub fn new() -> Self {
        let client = super::http_context::CspHttpContext::new(|| reqwest::Client::builder()
            // Unbound sites remain direct; the context applies the current app policy.
            .no_proxy()
            .user_agent(UA)
            .timeout(std::time::Duration::from_secs(20))
        );
        Self { client }
    }

    /// 带签名头 GET
    async fn get_signed(&self, base: &str, query: &str, path_with_query: &str) -> Result<String, String> {
        let url = format!("{base}{path_with_query}");
        let t = now_ms();
        let sign = sign_of(query.replace("{t}", &t).as_str());
        let resp = self
            .client
            .client()?
            .get(&url)
            .header("sign", sign)
            .header("T", t.clone())
            .header("Deviceid", device_id())
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await
            .map_err(|e| format!("请求上游失败（{url}）：{e}"))?;
        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取上游响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("上游返回 HTTP {status}（{url}）"));
        }
        Ok(body)
    }

    /// HEAD 探活（等价于 DEX 的 `checkDomainValid`）
    ///
    /// ★★ **判据必须与 DEX 逐字一致：`200 <= code <= 399` 才算有效**
    /// ```text
    /// 我第一版写的是 `< 500` ⇒ **403 被当成"域名可用"**。
    /// 真网读数（2026-10-27）直接把它打出来：
    ///   list 应成功: "上游返回 HTTP 403 Forbidden（https://m.610pkea.com/…）"
    /// —— 因为 ext 里第一个域名 `m.610pkea.com` 实测 403，却被探活判为可用，
    ///    于是**永远选中被拦的那个**，而后面 5 个能用的域名根本轮不到。
    ///     这类错的形态最阴：现象是"这个源打不通"，而真因是**域名选择**。
    /// DEX 依据：`.probe/r3-batchA-Jpys.disasm.txt` 的 `checkDomainValid`
    ///   `if-lt 200` / `if-gt 399` 两条分支 ⇒ 区间 [200,399] 返回 true。
    /// ```
    async fn probe_domain(&self, d: &str) -> bool {
        let Ok(client) = self.client.client() else { return false; };
        match client
            .head(d)
            .timeout(std::time::Duration::from_secs(10))
            .send()
            .await
        {
            Ok(r) => probe_status_ok(r.status().as_u16()),
            Err(_) => false,
        }
    }

    /// 按 ext 顺序挑第一个可用域名（走 [`pick_domain_from`]，使该行为可离线测）
    async fn pick_domain(&self, ext: &str) -> String {
        let doms = domains_of(ext);
        pick_domain_from(&doms, |d| self.probe_domain(d)).await
    }
}

impl Default for Jpys {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for Jpys {
    fn set_http_context(&self, proxy: std::sync::Arc<crate::proxy::ProxyStore>, provider: &str) {
        self.client.set_proxy(proxy, provider);
    }

    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let base = self.pick_domain(ext).await;
        let categories = Self::CATS
            .iter()
            .map(|(id, name)| CspCategory {
                id: id.to_string(),
                name: name.to_string(),
            })
            .collect();
        // 首页预取热播（DEX homeContent 用 hotSearch）；**取不到就空，不是错** ——
        // DEX 也是这个行为（热播拿不到不影响分类可用）。
        let t = now_ms();
        let q = format!("key={SIGN_KEY}&t={t}");
        let items = match self
            .get_signed(&base, &q, "/api/mw-movie/anonymous/home/hotSearch")
            .await
        {
            Ok(body) => serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| items_from_data_array(&v, "hotSearch").ok())
                .unwrap_or_default(),
            Err(_) => Vec::new(),
        };
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let base = self.pick_domain(ext).await;
        let t = now_ms();
        let q = sign_query("", page, tid, "", &t);
        let path = format!("{P_LIST}?type1={tid}&pageNum={page}&area=&year=");
        let body = self.get_signed(&base, &q, &path).await?;
        let v: Value =
            serde_json::from_str(&body).map_err(|e| format!("上游列表响应不是合法 JSON：{e}"))?;
        ensure_ok(&v, "分类列表")?;
        let items = items_from_list(&v, "分类列表")?;
        let page_count = v
            .get("data")
            .and_then(|d| d.get("totalPage"))
            .and_then(|x| x.as_u64())
            .map(|n| n as u32);
        Ok(CspList {
            items,
            page,
            page_count,
            total: v.get("data").and_then(|d| d.get("totalCount")).and_then(|x| x.as_u64()),
        })
    }

    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let base = self.pick_domain(ext).await;
        let t = now_ms();
        let enc = urlencoding::encode(kw);
        /*
         * ★★ 签名串用**原文** kw，URL 用 enc —— 实测（见 `sign_query_search` 的注释）：
         *    签名里放编码后的 kw 会得到 `code:122001 应用签名失败`。
         */
        let q = sign_query_search(kw, page, &t);
        let path = format!("{P_SEARCH}?keyword={enc}&pageNum={page}&pageSize=8");
        let body = self.get_signed(&base, &q, &path).await?;
        let v: Value =
            serde_json::from_str(&body).map_err(|e| format!("上游搜索响应不是合法 JSON：{e}"))?;
        // 条目在 `data.result.list[]`（实测；见 search_items_of 的注释）
        let items = search_items_of(&v, "搜索")?;
        Ok(CspList {
            items,
            page,
            page_count: v
                .get("data")
                .and_then(|d| d.get("result"))
                .and_then(|r| r.get("totalPage"))
                .and_then(|x| x.as_u64())
                .map(|n| n as u32),
            total: v
                .get("data")
                .and_then(|d| d.get("result"))
                .and_then(|r| r.get("totalCount"))
                .and_then(|x| x.as_u64()),
        })
    }

    fn supports_search(&self) -> bool {
        true
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let base = self.pick_domain(ext).await;
        let t = now_ms();
        // ★ 详情段的签名串是 `id=<id>&key=<key>&t=<ms>`（实测，非列表段那串）
        let q = sign_query_detail(id, &t);
        let path = format!("{P_DETAIL}?id={id}");
        let body = self.get_signed(&base, &q, &path).await?;
        let v: Value =
            serde_json::from_str(&body).map_err(|e| format!("上游详情响应不是合法 JSON：{e}"))?;
        detail_from(&v, id)
    }

    async fn play(&self, _flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        /*
         * `id` 形如 `{vodId}@{nid}`（DEX detailContent 里 `nid` 与 vod_id 用 `@` 拼）⇒ 拆开。
         * ★ 实测**必须两个都给**：只给 id ⇒ `code:122001 应用签名失败`；
         *   `id=<vodId>&nid=<nid>&key=<key>&t=<ms>` ⇒ `code:200` + 真 m3u8 直链。
         * ⇒ 缺 nid 时**显式报错**（不"试着只给 id"—— 那样的失败会伪装成"该集无源"）。
         */
        let (vid, nid) = id.split_once('@').ok_or_else(|| {
            format!(
                "取流 id 必须是 `{{vodId}}@{{nid}}` 形态（原始 id={id:?}）——\
                 实测只给 vodId 会被上游判应用签名失败，别把签名错说成该集无源"
            )
        })?;
        if vid.is_empty() || nid.is_empty() {
            return Err(format!("取流 id 的 vodId/nid 不能为空（原始 id={id:?}）"));
        }
        let base = self.pick_domain(ext).await;
        let t = now_ms();
        // ★ 取流段的签名串：`id=<vodId>&nid=<nid>&key=<key>&t=<ms>`（实测）
        let q = sign_query_episode(vid, nid, &t);
        let path = format!("{P_EPISODE}?id={vid}&nid={nid}");
        let body = self.get_signed(&base, &q, &path).await?;
        let v: Value =
            serde_json::from_str(&body).map_err(|e| format!("上游取流响应不是合法 JSON：{e}"))?;
        let url = play_url_of(&v)?;
        Ok(vec![CspPlay {
            url,
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                ("Origin".to_string(), base.clone()),
                ("Referer".to_string(), format!("{base}/")),
            ],
            label: Some("在线播放".to_string()),
        }])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册
// ═══════════════════════════════════════════════════════════════════════
//
// 注册项长在类自己的文件里 ⇒ 新增类 = 新增文件，不改核心注册表。
crate::csp::register_site!(Jpys);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
#[path = "jpys_proxy_tests.rs"]
mod proxy_tests;

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试用：把 `&[&str]` 转成 `Vec<String>`（`pick_domain_from` 收的是 `&[String]`）
    fn doms(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    /// ★★ 双层哈希：sha1(md5(q)) —— 少一层就通不过上游
    ///
    /// # 判据（不靠自证）
    /// ```text
    /// · 对**已知输入**断言 40 位十六进制且与"先 md5 再 sha1"的**独立重算**一致
    /// · 断言 sign_of(q) != md5_hex(q) 且 != sha1_hex(q)（否则单层就够 ⇒ 本条能抓出"只做一层"）
    /// ```
    /// 注入：把 `sign_of` 改成只返回 `md5_hex(q)` ⇒ 本条立刻红。
    #[test]
    fn sign_is_sha1_of_md5_not_a_single_layer() {
        let q = "area=&pageNum=1&type1=1&year=&key=cb808529bae6b6be45ecfab29a4889bc&t=1700000000000";
        let s = sign_of(q);
        assert_eq!(s.chars().count(), 40, "sha1 十六进制必须是 40 位，实际 {s}");
        assert!(s.chars().all(|c| c.is_ascii_hexdigit()), "必须是十六进制：{s}");
        assert_eq!(s, sha1_hex(&md5_hex(q)), "★ 必须是 sha1(md5(q))");

        // 单层不算过 —— 这条就是"少一层"的探针
        assert_ne!(s, md5_hex(q), "★ 不是单层 md5（少一层 sha1 必红）");
        assert_ne!(s, sha1_hex(q), "★ 不是单层 sha1（少一层 md5 必红）");
        assert_ne!(md5_hex(q), sha1_hex(q), "两个基础哈希不该相等");
    }

    #[test]
    /// 已知向量 + 顺序敏感 —— 参与签名的 query 顺序**不能重排**
    ///
    /// 重排（例如 area 与 year 互换）会得到另一个 sign，上游判鉴权失败，
    /// 而**现象是空列表** ⇒ 静默。所以这里把"顺序不一样 ⇒ sign 不一样"钉死。
    fn sign_query_order_is_load_bearing() {
        let a = sign_query("", 1, "1", "", "1700000000000");
        assert_eq!(
            a,
            "area=&pageNum=1&type1=1&year=&key=cb808529bae6b6be45ecfab29a4889bc&t=1700000000000",
            "★ 顺序必须与 DEX 的 append 顺序逐字一致"
        );
        let b = sign_query("", 1, "1", "", "1700000000001");
        assert_ne!(sign_of(&a), sign_of(&b), "t 变了 ⇒ sign 必须变（否则签名没带上 t）");
        let c = sign_query("", 2, "1", "", "1700000000000");
        assert_ne!(sign_of(&a), sign_of(&c), "page 变了 ⇒ sign 必须变");
        let d = sign_query("大陆", 1, "1", "", "1700000000000");
        assert_ne!(sign_of(&a), sign_of(&d), "area 变了 ⇒ sign 必须变");
    }

    #[test]
    /// ★★ **四段的签名串各不相同** —— 这是真网读数逼出来的（第一版全用列表段那串 ⇒ 122001）
    ///
    /// # 实测依据（2026-10-27 打 y2s52n7.com）
    /// ```text
    /// 列表   area=..&pageNum=..&type1=..&year=..&key=..&t=..        → code:200
    /// 搜索   keyword=<原文>&pageNum=1&pageSize=8&key=..&t=..        → code:200（8 条）
    ///        keyword=<URL编码>&…（同长度其他全对）                   → code:122001 应用签名失败
    /// 详情   id=<id>&key=..&t=..                                    → code:200
    /// 取流   id=<vodId>&nid=<nid>&key=..&t=..                       → code:200 + 真 m3u8
    ///        id=<vodId>&key=..&t=.. / nid=<nid>&key=..&t=..         → code:122001
    /// ```
    /// ⇒ 断言：四串**两两不同**，且各自与实测形态逐字一致。
    /// 注入：把 search/detail/play 任一处改回 `sign_query(…)`（列表段那串）⇒ 本条红。
    #[test]
    fn four_segments_have_distinct_sign_queries() {
        let l = sign_query("", 1, "1", "", "1700000000000");
        let s = sign_query_search("战狼", 1, "1700000000000");
        let d = sign_query_detail("147748", "1700000000000");
        let p = sign_query_episode("147748", "1326360", "1700000000000");

        assert_eq!(
            s, "keyword=战狼&pageNum=1&pageSize=8&key=cb808529bae6b6be45ecfab29a4889bc&t=1700000000000",
            "★ 搜索段：keyword 是**原文**（不是 URL 编码）"
        );
        assert_eq!(
            d, "id=147748&key=cb808529bae6b6be45ecfab29a4889bc&t=1700000000000",
            "★ 详情段"
        );
        assert_eq!(
            p, "id=147748&nid=1326360&key=cb808529bae6b6be45ecfab29a4889bc&t=1700000000000",
            "★ 取流段：**必须带 nid**"
        );

        // 两两不同（把"混成一个"这种错钉死）
        let all = [&l, &s, &d, &p];
        for i in 0..all.len() {
            for j in (i + 1)..all.len() {
                assert_ne!(all[i], all[j], "★ 第 {i} 段与第 {j} 段的签名串不该相同");
            }
        }
        // 编码后的 keyword 会得到**另一个** sign（也就是实测被判 122001 的那条）
        assert_ne!(
            sign_of(&s),
            sign_of(&sign_query_search("%E6%88%98%E7%8B%BC", 1, "1700000000000")),
            "★ 编码/非编码 keyword 必须产生不同签名（正是实测 122001 的成因）"
        );
        // 详细：取流少 nid ⇒ 另一个 sign
        assert_ne!(
            sign_of(&p),
            sign_of(&sign_query_episode("147748", "", "1700000000000")),
            "★ 少 nid ⇒ 签名不同（实测即 122001）"
        );
    }

    #[test]
    /// ★★ 搜索条目在 `data.result.list[]`（**不是** `data.list`）—— 实测结构
    ///
    /// 实测响应（真打 y2s52n7.com）：
    /// `data` = `{typeResult:{…list:[…]}, result:{totalCount,pageNum,pageSize,totalPage,list:[8 条]}}`
    /// 注入：把 `search_items_of` 改成读 `data.list` ⇒ 本条红。
    fn search_items_come_from_data_result_list() {
        let v: Value = serde_json::from_str(
            r#"{"code":200,"msg":"操作成功","data":{
                 "typeResult":{"totalCount":3,"list":[{"vodId":9,"vodName":"错位的"}]},
                 "result":{"totalCount":8,"pageNum":1,"pageSize":8,"totalPage":1,
                   "list":[{"vodId":144503,"vodName":"战狼·战狼","vodClass":"剧情,历史,战争",
                            "vodPic":"https://obs/p.webp"}]}}}"#,
        )
        .unwrap();
        let items = search_items_of(&v, "搜索").expect("应成功");
        assert_eq!(items.len(), 1, "★ 取的是 result.list（typeResult.list 不算）");
        assert_eq!(items[0].id, "144503");
        assert_eq!(items[0].title, "战狼·战狼");

        // 没有 data.result ⇒ Err（并且错误里要指出实际的 data 键，便于定位）
        let wrong: Value =
            serde_json::from_str(r#"{"code":200,"data":{"list":[{"vodId":1,"vodName":"x"}]}}"#)
                .unwrap();
        let e = search_items_of(&wrong, "搜索").expect_err("★ 必须 Err，不许静默读错位置");
        assert!(e.contains("data.result.list"), "{e}");
        assert!(e.contains("typeResult") || e.contains("list"), "错误里要带实际键：{e}");
    }

    /// ★★ 探活判据 = **[200,399] 才算有效**（不能写成 `< 500`）
    ///
    /// # 这是真网读数打出来的真 bug（2026-10-27）
    /// ```text
    /// 第一版 `status < 500` ⇒ ext 里第一个域名 `m.610pkea.com`（实测 **403**）
    /// 被判为"可用"，于是**永远选中被拦的那个**，后面 5 个能用的域名轮不到。
    /// 现象是"这个源打不通"，真因却是**域名选择**。
    /// DEX 依据：`checkDomainValid` 的 `if-lt 200` / `if-gt 399` 两条分支。
    /// ```
    /// 注入：把 `probe_status_ok` 改回 `code < 500` ⇒ 本条红。
    #[test]
    fn probe_status_ok_is_the_dex_interval_not_under_500() {
        assert!(probe_status_ok(200), "200 必须算可用");
        assert!(probe_status_ok(301), "301 必须算可用（DEX 收 399 以内）");
        assert!(probe_status_ok(399), "399 是闭区间上界");
        assert!(!probe_status_ok(400), "★ 400 不算可用");
        assert!(!probe_status_ok(403), "★★ 403 必须判不可用（第一版就错在这）");
        assert!(!probe_status_ok(404), "404 不算可用");
        assert!(!probe_status_ok(500), "500 不算可用");
        assert!(!probe_status_ok(0), "0（连接失败）不算可用");
    }

    /// ★★ 探活必须**跳过 403 的域名**、走到能用的那个（域名选择的真网 bug 回归）
    ///
    /// 注入：把 `probe_domain` 的判据改回 `< 500`（或让 `pick_domain_from` 恒返回第一个）
    /// ⇒ 本条红。
    ///
    /// ⚠️ 用 `#[tokio::test]` 时**不能**再叠 `#[test]`。
    #[tokio::test]
    async fn pick_domain_skips_blocked_first_entry() {
        /*
         * 纯函数版：喂"第一个 403、第二个 200" ⇒ 必须选第二个。
         * ★ 刻意**不真打网络**：这条要能在离线门禁里稳定红/绿，
         *   而真网读数（选到 m.hkybqufgh.com 那种）另在 CSP_LIVE 段留档。
         */
        let got = pick_domain_from(&doms(&["https://blocked.example", "https://good.example"]), |d| {
            let hit = d.contains("good");
            async move { hit }
        })
        .await;
        assert_eq!(
            got, "https://good.example",
            "★ 必须跳过第一个（它是 403），选第二个 —— 选错就是真网里那个 403 bug"
        );

        // 全不可用 ⇒ 返回**第一个**（由请求本身报错，不在这里造"站点全挂"的结论）
        let none =
            pick_domain_from(&doms(&["https://a.example", "https://b.example"]), |_| async { false })
                .await;
        assert_eq!(none, "https://a.example", "全不能用时仍返回第一个（错误交给请求）");

        // 空表 ⇒ 兜底域名
        let empty = pick_domain_from(&[], |_| async { true }).await;
        assert_eq!(empty, DEFAULT_DOMAIN, "空 ext 要给兜底域名");

        // ★ 对照：把判据换成"第一个也算可用"（即第一版 `< 500` 的行为）⇒ 会选到被拦那个
        let wrong =
            pick_domain_from(&doms(&["https://blocked.example", "https://good.example"]), |_| async {
                true
            })
            .await;
        assert_eq!(
            wrong, "https://blocked.example",
            "★ 这正是第一版的错：403 也被当可用 ⇒ 永远选中被拦的域名"
        );
    }

    #[tokio::test]
    /// ★ 取流 id **必须** `vodId@nid`（实测只给 vodId ⇒ 122001，会被误读成「该集无源」）
    ///
    /// ⚠️ 用 `#[tokio::test]` 时**不能**再叠 `#[test]` —— 叠了会报
    ///    "async functions cannot be used for tests"，把整批门禁编译断掉。
    async fn play_requires_vod_and_nid() {
        let s = Jpys::new();
        let e = s.play("在线播放", "147748", "").await.expect_err("★ 缺 nid 必须显式 Err");
        assert!(e.contains("vodId"), "{e}");
        assert!(e.contains("nid"), "{e}");
        assert!(
            e.contains("签名"),
            "错误要说明真实原因（签名失败），别被误读成该集无源：{e}"
        );
        assert!(s.play("在线播放", "147748@", "").await.is_err(), "空的 nid 也必须 Err");
        assert!(s.play("在线播放", "@1326360", "").await.is_err());
    }

    #[test]
    fn md5_and_sha1_known_vectors() {
        // 标准向量（独立可核）：md5("abc") / sha1("abc")
        assert_eq!(md5_hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(sha1_hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_ne!(md5_hex("abd"), md5_hex("abc"));
    }

    #[test]
    /// ★★ 反空真：`data.list` 解析出 0 条 ⇒ **必须 Err**，不许"成功返回空"
    ///
    /// # 防的是什么（铁律 149）
    /// ```text
    /// 候选集为空时"每个元素都合规"恒真 ⇒ 门禁/UI 都会看到"成功"，用户只看到空列表，
    /// 而真正的原因（键名变了 / 被拦）被静默吃掉。
    /// ```
    /// 注入：把 `items_from_list` 的 `if items.is_empty()` 那一段删掉（改成 `Ok(items)`）⇒ 本条红。
    fn empty_parse_is_an_error_not_a_silent_success() {
        // 键名变了（上游写 list2）
        let v: Value =
            serde_json::from_str(r#"{"code":200,"data":{"list2":[{"vodId":1,"vodName":"x"}]}}"#)
                .unwrap();
        let e = items_from_list(&v, "分类列表").expect_err("★ 没有 data.list 必须 Err");
        assert!(e.contains("data.list"), "错误要指名缺的键：{e}");

        // list 存在但空
        let v2: Value = serde_json::from_str(r#"{"code":200,"data":{"list":[]}}"#).unwrap();
        let e2 = items_from_list(&v2, "分类列表").expect_err("★ 空列表必须 Err");
        assert!(e2.contains("0 条"), "错误要写明 0 条：{e2}");

        // 有项但取不出 id/name
        let v3: Value =
            serde_json::from_str(r#"{"code":200,"data":{"list":[{"foo":1}]}}"#).unwrap();
        assert!(items_from_list(&v3, "分类列表").is_err(), "★ 取不出字段也必须 Err");

        // 对照：正常一条 ⇒ Ok
        let v4: Value = serde_json::from_str(
            r#"{"code":200,"data":{"list":[{"vodId":147748,"vodName":"大力水手4：复活",
                 "vodPic":"https://p/x.webp","vodRemarks":"HD"}]}}"#,
        )
        .unwrap();
        let ok = items_from_list(&v4, "分类列表").expect("正常数据必须 Ok");
        assert_eq!(ok.len(), 1);
        assert_eq!(ok[0].id, "147748", "★ vodId 是数字 ⇒ 要转成字符串 id，不能丢");
        assert_eq!(ok[0].title, "大力水手4：复活");
        assert_eq!(ok[0].cover.as_deref(), Some("https://p/x.webp"));
    }

    #[test]
    /// ★★ `code != 200` ⇒ **必须 Err**；缺 code 也 Err（不把错误页当成功）
    ///
    /// 实测上游判据：不带签名头 ⇒ `{"code":122012,"msg":"应用签名不可为空"}`。
    /// 注入：把 `ensure_ok` 改成恒 `Ok(v)` ⇒ 本条红。
    fn non_200_code_is_rejected() {
        let v: Value =
            serde_json::from_str(r#"{"code":122012,"msg":"应用签名不可为空"}"#).unwrap();
        let e = ensure_ok(&v, "分类列表").expect_err("★ 非 200 必须 Err");
        assert!(e.contains("122012"), "错误里要有上游 code：{e}");
        assert!(e.contains("应用签名不可为空"), "错误里要有上游 msg：{e}");

        let no_code: Value = serde_json::from_str(r#"{"msg":"nope"}"#).unwrap();
        let e2 = ensure_ok(&no_code, "分类列表").expect_err("★ 缺 code 也必须 Err");
        assert!(e2.contains("没有 code"), "{e2}");

        let ok: Value = serde_json::from_str(r#"{"code":200,"data":{}}"#).unwrap();
        ensure_ok(&ok, "分类列表").expect("200 必须通过");
    }

    #[test]
    /// 详情：集从 `episodeList[]` 取（`name` 集名 / `nid` 集 id），0 集 ⇒ Err
    ///
    /// 注入：把 `detail_from` 里的 `if episodes.is_empty()` 删掉 ⇒ 本条红。
    fn detail_requires_episodes_and_reads_nid() {
        let v: Value = serde_json::from_str(
            r#"{"code":200,"data":{"vodName":"大力水手4：复活","vodPic":"https://p/d.webp",
                 "vodBlurb":"简介","episodeList":[{"name":"正片","nid":"9001"},
                                                 {"name":"第2集","nid":"9002"}]}}"#,
        )
        .unwrap();
        let d = detail_from(&v, "147748").expect("应成功");
        assert_eq!(d.title, "大力水手4：复活");
        assert_eq!(d.episodes.len(), 2);
        assert_eq!(d.episodes[0].id, "9001", "★ 集 id 是 nid 不是下标");
        assert_eq!(d.episodes[0].title, "正片");
        assert_eq!(d.episodes[0].flag, "在线播放");
        assert_eq!(d.description.as_deref(), Some("简介"));

        // 缺 episodeList ⇒ Err（**不许**返回"有详情但 0 集"这种看着成功的形状）
        let no_ep: Value =
            serde_json::from_str(r#"{"code":200,"data":{"vodName":"x"}}"#).unwrap();
        let e = detail_from(&no_ep, "1").expect_err("★ 0 集必须 Err");
        assert!(e.contains("0 集"), "{e}");

        // nid 缺失 ⇒ 用序号兜底（不乱丢集），但**集数不能因此归零**
        let miss: Value = serde_json::from_str(
            r#"{"code":200,"data":{"vodName":"x","episodeList":[{"name":"A"},{"name":"B"}]}}"#,
        )
        .unwrap();
        let d2 = detail_from(&miss, "1").expect("应成功");
        assert_eq!(d2.episodes.len(), 2);
        assert_eq!(d2.episodes[0].id, "1");
        assert_eq!(d2.episodes[1].id, "2");
    }

    #[test]
    /// 取流：`data.list[].url` 第一条；空 ⇒ Err
    fn play_url_is_taken_or_errors() {
        let v: Value = serde_json::from_str(
            r#"{"code":200,"data":{"list":[{"url":"https://cdn.example/a.m3u8"}]}}"#,
        )
        .unwrap();
        assert_eq!(play_url_of(&v).unwrap(), "https://cdn.example/a.m3u8");

        let empty: Value = serde_json::from_str(r#"{"code":200,"data":{"list":[{"url":""}]}}"#)
            .unwrap();
        let e = play_url_of(&empty).expect_err("★ 空 url 必须 Err");
        assert!(e.contains("没有任何 url"), "{e}");
    }

    #[test]
    /// ext 解析：逗号分隔多域名（真实 ext 就是这种形态）
    fn domains_of_parses_real_ext() {
        let ext = "https://m.610pkea.com,https://y2s52n7.com,https://m.hkybqufgh.com,\
https://m.sizhengxt.com,https://m.9zhoukj.com,https://m.jiabaide.cn";
        let d = domains_of(ext);
        assert_eq!(d.len(), 6, "实测 ext 有 6 个域名，实际 {d:?}");
        assert_eq!(d[0], "https://m.610pkea.com");
        assert_eq!(d[1], "https://y2s52n7.com", "★ 顺序即优先级（探活按此顺序）");

        // 单域名 / 空 / 带尾斜杠
        assert_eq!(domains_of("https://a.b.c/"), vec!["https://a.b.c"]);
        assert_eq!(domains_of(""), vec![DEFAULT_DOMAIN.to_string()]);
        // 重复要去重
        assert_eq!(domains_of("https://a.com,https://a.com").len(), 1);
    }

    #[test]
    /// ★ Deviceid 是 UUID 形态且**进程内稳定**（同一次运行里不能每请求都变）
    fn device_id_is_uuid_and_stable() {
        let a = device_id();
        let b = device_id();
        assert_eq!(a, b, "同一进程里必须稳定（否则上游可能把每请求当新设备）");
        assert_eq!(a.len(), 36, "UUID 形态 36 字符：{a}");
        let seg: Vec<&str> = a.split('-').collect();
        assert_eq!(seg.len(), 5, "{a}");
        assert_eq!(
            seg.iter().map(|s| s.len()).collect::<Vec<_>>(),
            vec![8, 4, 4, 4, 12],
            "{a}"
        );
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_jpys -- --ignored --nocapture"]
    async fn csp_live_jpys_home_list_search_detail() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Jpys::new();
        let ext = "https://m.610pkea.com,https://y2s52n7.com,https://m.hkybqufgh.com";
        let home = s.home(ext).await.expect("home 应成功");
        eprintln!(
            "[LIVE] home: 分类 {} 个，热播 {} 条，首条={}",
            home.categories.len(),
            home.items.len(),
            home.items.first().map(|i| i.title.clone()).unwrap_or_default()
        );
        assert_eq!(home.categories.len(), 4);
        let l = s.list("1", 1, ext).await.expect("list 应成功");
        eprintln!("[LIVE] list(1 电影 p1): {} 条 total={:?}", l.items.len(), l.total);
        assert!(!l.items.is_empty());
        let se = s.search("战狼", 1, ext).await.expect("search 应成功");
        eprintln!("[LIVE] search(战狼): {} 条 首条={}", se.items.len(), se.items[0].title);
        let d = s.detail(&l.items[0].id, ext).await.expect("detail 应成功");
        eprintln!("[LIVE] detail: {} 集，首集={}", d.episodes.len(), d.episodes[0].title);
        let p = s
            .play("在线播放", &format!("{}@{}", l.items[0].id, d.episodes[0].id), ext)
            .await
            .expect("play 应成功");
        eprintln!("[LIVE] play: {}", p[0].url);
    }
}
