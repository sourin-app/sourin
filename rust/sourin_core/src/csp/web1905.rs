// ═══════════════════════════════════════════════════════════════════════
//  csp_Web1905 —— TVBox `csp_Web1905` 的 Rust 重写（1905 电影网）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么（实测取自 `.probe/ref-subscription.json`）
//
// ```json
// {"key":"1905","name":"🎥1905｜蓝光秒播","type":3,"api":"csp_Web1905",
//  "searchable":1,"quickSearch":0,"filterable":0}
// ```
// ⇒ **没有 ext**：站点写死 `https://www.1905.com`，`profile.m1905.com` 是取流域名。
//
// # ★ 协议（反汇编复原，逐段）
//
// ```text
// list   GET https://www.1905.com/vod/list/{tid}/o3p{page}.html
//        （DEX：`「https://www.1905.com/vod/list/」+ tid + 「/o3p」+ page + 「.html」`）
//        选择器：tid=="n_2" ? "div.mod > div > a" : "section.search-list > div > a"
//        每项：href（再用 `play/(.*?).sh` 正则抠出 play id）/ title / img.src / p
// home   GET https://www.1905.com/vod/list/n_1/o3p1.html（首个分类写死 n_1）
//        分类表（DEX 逐字）：n_1 电影 / c_927 微电影 / n_1_c_586 系列电影 /
//          n_1_c_178 记录片 / n_1_c_1024 晚会 / n_1_c_1053 独家 / n_2 综艺 / …体育
// detail GET https://www.1905.com/api/content/?m=Vod&a=getVodSidebar&id={id}&fomat=json
//        字段：title / thumb / commendreason / description / direct / starring /
//              info.series_data[].contentid
// play   ★ 两段：
//        ① 组装待签名串（DEX 的 String.format，参数顺序见下）
//             "cid={cid}&expiretime={exp}&nonce={nonce}&page={page}&playerid={pid}&type=hls&uuid={uuid}.dde3d61a0411511d"
//             cid     = 集 contentid
//             exp     = now_ms + 600*1000          ← DEX: currentTimeMillis + 1000*600
//             nonce   = now_ms
//             page    = "https://www.1905.com/vod/play/{contentid}.shtml"
//                       （★ 还要把 ':'→'%3A'、'/'→'%2F' 后再进 format —— 见下面 page_of）
//             playerid= 20 位随机大写十六进制（UUID.toString().replace("-","").substring(0,20)）
//             uuid    = 同样那 20 位 + 固定后缀 ".dde3d61a0411511d" 才是 format 里 %s 的值？
//                       ⇒ ⚠️ 见下面 uuid_and_nonce() 的注释：DEX 是**同一个 20 位串**
//                         被两个 %s 用到（同一个寄存器 v9），故两处一致。
//             signature = sha1_hex(该串)          ← merge.m.I.k = MessageDigest("SHA-1")
//        ② GET https://profile.m1905.com/mvod/getVideoinfo.php
//             ?nonce={nonce}&expiretime={exp}&cid={cid}&uuid={uuid}
//             &playerid={pid}&page={page%3A%2F 编码后的}&type=hls&signature={sig}&callback={cb}
//           响应是可 JSONP 的 `({...})` ⇒ 先去 `(` `)` 再 parse
//           有 uhd 用 uhd / 有 sd 用 sd / 有 hd 用 hd ⇒ 取 {host}+{path}
//           （DEX：`quality` → 那个档位 → `host` 与 `path`，再拼成地址）
// ```
//
// # ⚠️ 上游反爬（如实分档：**协议对，但上游当前打不通**）
//
// ```text
// 2026-10-27 首测：
//   GET https://www.1905.com/vod/list/n_1/o3p1.html      ⇒ HTTP 403 / 6072b
//   GET https://www.1905.com/                            ⇒ HTTP 403 / 6072b
//   GET /api/content/?m=Vod&a=getVodSidebar&id=1&fomat=json ⇒ HTTP 403 / 6072b
//   body 是 "Embed Iframe" 反爬页（本站对所有非浏览器请求的统一拦页面）
//   ⚠️ 但 GET https://profile.m1905.com/mvod/getVideoinfo.php ⇒ HTTP 200 / 110b
//      ⇒ 取流域名**没被同一层拦**；被拦的是 www.1905.com 那三个入口。
//
// 2026-10-29 复测（**把"WAF"与"签名"拆成两件事**；证据全在 `.probe/api-fix/`）：
//   ① WAF（www 全部入口，无差别）—— 证据 `1905-list-403.txt` / `1905-list-noheaders.txt`
//      / `ws_sec_page.js`：
//      - 403 响应头：`Server: nginx`、`x-via: 1.1 PS-XFN-…(Cdn Cache Server V2.0)`（网宿）、
//        `x-ws-request-id: …`、裸请求额外有 **`Ws-Action: bot`**、`Cache-Control: no-store`
//      - body 6072 字节：`<title>Embed Iframe</title>` + `window._jsc_ch_conf={…}` +
//        `/_jsc_sbu/ws_sec_page.js?sc=…&chID=…&chHash=…`（JS 挑战页；脚本本身再取也是 403）
//      - 覆盖面：`/`、`/robots.txt`、`/favicon.ico`、`/vod/list/…`、`/api/content/…` 全 403；
//        `http://` 302 到 https；无 www 的 `1905.com` 也 302 到 www ⇒ **没有可绕的入口**
//      - 浏览器全套头（sec-ch-ua / Sec-Fetch-* / Accept-Language / 完整 Accept）复测仍 403
//      ⇒ 判据：**站点侧 WAF 的 JS 挑战**，不是我们少 header
//   ② 取流签名（profile.m1905.com，HTTP 200 但**业务码**分档）——
//      证据 `1905-playinfo-signed.txt` / `1905_sig_matrix.out.txt`：
//      - 参数齐全 + DEX 逐字 SHA-1 ⇒ `{"StatusCode":403,"info":"HTTP请求不合法,请求参数可能被篡改"}`
//      - 缺 `signature` 或缺 `page`  ⇒ `{"StatusCode":400,"info":"请求参数不完整或不正确"}`
//        ⇒ **参数完整性这一层我们是对的**（400/403 的差别就是判据）
//      - 52 个变体全 403（page 单/双/不转义 × uuid 带/不带后缀 × ms/s × sha1/md5 × 大写/小写，
//        外加只签 page、只签 cid+page、去掉 expiretime 等 4 个简化式）
//      ⇒ 判据：**服务端签名密钥/算法已变**，不是我们编码错
// ⇒ 处置：协议按 DEX 逐字实现，打不通就**如实报状态 + 分档**，不假装拿到数据；
//   **不做** WAF 绕过（不跑它的挑战 JS、不做验证码/指纹伪装、不走代理绕地域）。
// ```
//
// # ⚠️ 已知缺口（Lead 已裁定本批不做，如实登记）
// ```text
// ① `mProxy`：DEX 方法表里**没有**（本批"mProxy 不做"对该类零影响）。
// ② `loadPic`：也没有。取图只需 Referer/UA/Accept ⇒ 走源 `cover_headers`（声明式）。
// ③ `initApi`：没有（`Web1905.init` 是空方法体）。
// ④ `isVideoFormat` / `manualVideoCheck`：DEX 里**没有这两个方法**（对照 AppYsV2 有）。
// ```

use async_trait::async_trait;
use regex::Regex;
use serde_json::Value;
use std::sync::OnceLock;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
const REFERER: &str = "https://www.1905.com";
const ACCEPT: &str = "text/html,application/xhtml+xml,application/xml;q=0.9,\
image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7";
const SITE: &str = "https://www.1905.com";
const PROFILE: &str = "https://profile.m1905.com";

/// 取流串里的固定尾巴（DEX 逐字：`uuid` 后面跟的那一截）
const UID_SUFFIX: &str = ".dde3d61a0411511d";

// ═══════════════════════════════════════════════════════════════════════
//  纯函数（全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// 分类表（DEX homeContent 的 const-string 逐字：tid 与名字成对出现）
///
/// ⚠️ 顺序按 DEX 里名字出现的先后（电影→微电影→系列电影→记录片→晚会→独家→综艺→体育）。
pub const CATS: &[(&str, &str)] = &[
    ("n_1", "电影"),
    ("n_1_c_922", "微电影"),
    ("n_2", "系列电影"),
    ("c_927", "记录片"),
    ("n_1_c_586", "晚会"),
    ("n_1_c_178", "独家"),
    ("n_1_c_1024", "综艺"),
    ("n_1_c_1053", "体育"),
];

/// 列表页 URL（DEX：`/vod/list/` + tid + `/o3p` + page + `.html`）
pub fn list_url(tid: &str, page: u32) -> String {
    format!("{SITE}/vod/list/{tid}/o3p{page}.html")
}

/// ★ 列表选择器**随 tid 变**（DEX：`"n_2".equals(tid)` ⇒ 用另一个选择器）
///
/// # 为什么必须跟着变
/// ```text
/// DEX 里只有这两条：tid=="n_2" ⇒ "div.mod > div > a"；其余一律
/// "section.search-list > div > a"。若写死一个，**另一半分类永远解析出 0 条**，
/// 而现象是"这个分类空的"（静默）而不是报错。
/// ```
pub fn list_selector(tid: &str) -> &'static str {
    if tid == "n_2" {
        "div.mod > div > a"
    } else {
        "section.search-list > div > a"
    }
}

/// 从 href 里抠出 1905 的 play id（DEX 的 `<clinit>` 正则 `play/(.*?).sh`）
///
/// 实测该正则**未锚定**且 `.*?` 非贪婪、`.sh` 会先匹到 `.shtml` 的 `.sh` 前缀 ⇒
/// 抠出来的是 play id 前那一截。这里忠实照搬（**不"修正"成更严的正则** ——
/// 严了会与上游 DEX 行为不一致，风险更大），但把"抠不到"变成显式 `None`。
pub fn play_id_of(href: &str) -> Option<String> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"play/(.*?).sh").expect("play regex"));
    re.captures(href)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .filter(|s| !s.is_empty())
}

/// 详情 id 归一：配置里的 id 可能是 `/vod/play/xxxx.shtml`、`xxxx`、或带查询串
pub fn detail_id_of(raw: &str) -> String {
    let s = raw.trim();
    let s = s
        .strip_prefix("/vod/play/")
        .or_else(|| s.split("/vod/play/").nth(1))
        .unwrap_or(s);
    let s = s.split(['?', '#']).next().unwrap_or(s);
    s.trim_end_matches(".shtml").trim_end_matches('/').to_string()
}

/// 详情 URL（DEX：`api/content/?m=Vod&a=getVodSidebar&id=` + id + `&fomat=json`）
pub fn detail_url(id: &str) -> String {
    format!("{SITE}/api/content/?m=Vod&a=getVodSidebar&id={id}&fomat=json")
}

/// 列表页 HTML → 条目（正则最小抽取；**0 条 ⇒ Err**）
///
/// # 为什么不引入 HTML 选择器库
/// ```text
/// 本仓依赖表里没有 scraper/html5ever，而"不新增运行时依赖"是硬约束
/// （与 csp_4KZhinan 同一决策）。⇒ 用已有的 `regex` 做最小、可测的抽取：
///     · 只依赖 `href` / `title=` / `data-src|src` / `<p>` 这四处
///     · 每处都配"结构变了"的坏样本 ⇒ 结构一变立刻 Err，不静默返回空列表
/// ⚠️ 局限（如实写）：不做完整 DOM，不做 `div.mod > div > a` 这种**层级选择器**
///    （正则做不到父子约束）。我把 DEX 的两个选择器退化成"该选择器名对应的
///    `a` 标签集合"，并用 `list_selector` 决定**优先**匹哪个区段。
/// ```
pub fn list_from_html(html: &str, tid: &str, page: u32) -> Result<CspList, String> {
    // 1905 列表项形如 <a href="..." title="片名" ...><img data-src="..."/><p>备注</p>...</a>
    static RE_A: OnceLock<Regex> = OnceLock::new();
    let re = RE_A.get_or_init(|| {
        /*
         * 只要一个 `a` 标签里同时有 href 与 title（列表项都带 title），
         * 再宽松地把后面的 img 与 p 一起吃掉。
         */
        Regex::new(
            r#"(?is)<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*title\s*=\s*"([^"]*)"[^>]*>(.*?)</a>"#,
        )
        .expect("list item regex")
    });
    static RE_IMG: OnceLock<Regex> = OnceLock::new();
    let re_img = RE_IMG
        .get_or_init(|| Regex::new(r#"(?is)<img\b[^>]*?(?:data-src|src)\s*=\s*"([^"]+)""#).unwrap());
    static RE_P: OnceLock<Regex> = OnceLock::new();
    let re_p = RE_P.get_or_init(|| Regex::new(r"(?is)<p\b[^>]*>(.*?)</p>").unwrap());

    let mut items = Vec::new();
    for cap in re.captures_iter(html) {
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let title = cap.get(2).map(|m| m.as_str().trim()).unwrap_or("");
        if title.is_empty() {
            continue; // 导航栏的 <a> 没有 title ⇒ 不是条目
        }
        let raw_inner = cap.get(3).map(|m| m.as_str()).unwrap_or("");
        let inner = decode_entities(raw_inner);
        // play id 抠不出就退回原始 href（DEX 里抠不出会让 href 保持原样 ⇒ 这里等价）
        let id = play_id_of(href).unwrap_or_else(|| href.to_string());
        let cover = re_img
            .captures(&inner)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .filter(|s| !s.starts_with("data:"));
        let sub = re_p
            .captures(&inner)
            .and_then(|c| c.get(1))
            .map(|m| strip_tags(m.as_str()))
            .filter(|s| !s.is_empty());
        items.push(CspItem {
            id,
            title: title.to_string(),
            cover,
            subtitle: sub,
        });
    }
    if items.is_empty() {
        return Err(format!(
            "上游列表 {tid} 第 {page} 页没解析出条目（选择器 {}；页面可能被反爬拦或改版）\
             —— 实际长度 {} 字节",
            list_selector(tid),
            html.len()
        ));
    }
    Ok(CspList {
        items,
        page,
        page_count: None, // DEX 不给总页数
        total: None,
    })
}

/// 详情 JSON → `CspDetail`（DEX 字段逐字：title/thumb/commendreason/description/direct/starring）
///
/// 剧集来自 `info.series_data[].contentid`（DEX 里 `series_data` 在 `info` 下）。
/// ★ **0 集 ⇒ Err**（不返回"有详情但 0 集"这种看着成功的形状）。
pub fn detail_from(v: &Value, id: &str) -> Result<CspDetail, String> {
    if v.get("title").is_none() && v.get("info").is_none() {
        /*
         * 反爬页被解析成 JSON 时会走到这儿（或上游改协议）。
         * ⇒ 显式报"没有 1905 详情字段"，而不是把 title 兜底成 id 后当成功。
         */
        let keys: Vec<&str> = v
            .as_object()
            .map(|o| o.keys().map(|k| k.as_str()).take(8).collect())
            .unwrap_or_default();
        return Err(format!(
            "上游详情 {id} 响应里没有 1905 的字段（title/info 都缺）——\
             可能是反爬页；实际顶层键：{keys:?}"
        ));
    }
    let title = v
        .get("title")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(String::from)
        .unwrap_or_else(|| id.to_string());
    let mut eps: Vec<CspEpisode> = Vec::new();
    if let Some(arr) = v
        .get("info")
        .and_then(|i| i.get("series_data"))
        .and_then(|s| s.as_array())
    {
        for (i, o) in arr.iter().enumerate() {
            let Some(cid) = o.get("contentid").map(|c| c.to_string().trim_matches('"').to_string())
            else {
                continue;
            };
            if cid.is_empty() {
                continue;
            }
            let name = o
                .get("title")
                .or_else(|| o.get("name"))
                .and_then(|x| x.as_str())
                .filter(|s| !s.is_empty())
                .map(String::from)
                .unwrap_or_else(|| format!("第{}集", i + 1));
            eps.push(CspEpisode {
                id: cid,
                title: name,
                flag: "1905".to_string(), // DEX detailContent 的线路名 const-string '1905'
            });
        }
    }
    if eps.is_empty() {
        return Err(format!(
            "上游详情 {id} 的 info.series_data 解析出 0 集（键名可能变了）"
        ));
    }
    Ok(CspDetail {
        id: id.to_string(),
        title,
        cover: v.get("thumb").and_then(|x| x.as_str()).map(String::from),
        description: v
            .get("description")
            .or_else(|| v.get("commendreason"))
            .and_then(|x| x.as_str())
            .filter(|s| !s.is_empty())
            .map(String::from),
        episodes: eps,
    })
}

/// 取流待签名串（DEX 的 `String.format` 逐字，**顺序不能动**）
///
/// ⚠️ `page` 进 format 前要把 `:`→`%3A`、`/`→`%2F`（DEX 里就是这两条 replace）。
pub fn sign_source(cid: &str, nonce_ms: u64, playerid: &str, page: &str) -> String {
    let exp = nonce_ms + 600_000; // DEX: currentTimeMillis + 1000*600
    let page_esc = page.replace(':', "%3A").replace('/', "%2F");
    format!(
        "cid={cid}&expiretime={exp}&nonce={nonce_ms}&page={page_esc}&playerid={playerid}\
         &type=hls&uuid={playerid}{UID_SUFFIX}"
    )
}

/// sha1 十六进制小写（DEX `merge.m.I.k` = `MessageDigest("SHA-1")` + `Integer.toHexString` 补齐）
pub fn sha1_hex(s: &str) -> String {
    use ring::digest;
    let out = digest::digest(&digest::SHA1_FOR_LEGACY_USE_ONLY, s.as_bytes());
    let mut r = String::with_capacity(40);
    for b in out.as_ref() {
        r.push_str(&format!("{b:02x}"));
    }
    r
}

/// 播放页 URL（DEX：`https://www.1905.com/vod/play/` + cid + `.shtml`）
pub fn play_page_of(cid: &str) -> String {
    format!("{SITE}/vod/play/{cid}.shtml")
}

/// 取流请求 URL（DEX 的 StringBuilder 顺序逐字）
pub fn playinfo_url(cid: &str, nonce_ms: u64, playerid: &str, signature: &str, cb: &str) -> String {
    let exp = nonce_ms + 600_000;
    let page = play_page_of(cid).replace(':', "%3A").replace('/', "%2F");
    format!(
        "{PROFILE}/mvod/getVideoinfo.php?nonce={nonce_ms}&expiretime={exp}&cid={cid}\
         &uuid={playerid}{UID_SUFFIX}&playerid={playerid}&page={page}\
         &type=hls&signature={signature}&callback={cb}"
    )
}

/// 从取流响应里选出地址：`data.sign` 的档位表 + `quality` 的 `host`/`path`
///
/// DEX 的选择优先级（逐条对应它那三段 contains）：
/// ```text
/// 有 "uhd" ⇒ 用 uhd；否则有 "sd" ⇒ 用 sd；否则有 "hd" ⇒ 用 hd
/// 再取那个档位对象的 `host` + `path` 拼成地址
/// ```
/// **没有任何一档 ⇒ Err**（不许返回空字符串）。
pub fn play_url_from(v: &Value) -> Result<String, String> {
    let data = v
        .get("data")
        .ok_or_else(|| "上游取流响应里没有 data（可能被拦或改协议）".to_string())?;
    let signs = data
        .get("sign")
        .ok_or_else(|| "上游取流响应的 data 里没有 sign（档位表）".to_string())?;
    let keys: Vec<String> = signs
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default();
    for want in ["uhd", "sd", "hd"] {
        if keys.iter().any(|k| k == want) {
            let q = data
                .get("quality")
                .and_then(|x| x.get(want))
                .ok_or_else(|| format!("上游取流响应里 data.quality 没有 {want} 档"))?;
            let host = q.get("host").and_then(|x| x.as_str()).unwrap_or("");
            let path = q.get("path").and_then(|x| x.as_str()).unwrap_or("");
            if !host.is_empty() && !path.is_empty() {
                return Ok(format!("{host}{path}"));
            }
            return Err(format!(
                "上游取流响应 {want} 档的 host/path 不全（host={host:?} path={path:?}）"
            ));
        }
    }
    Err(format!(
        "上游取流响应 data.sign 里 uhd/sd/hd 三档都没有（实际键：{keys:?}）"
    ))
}

/// 去掉 `({...})` 的 JSONP 外壳（DEX：先 replace "(" 再 replace ")"）
///
/// ⚠️ **本函数比 DEX 多一步，且这一步是门禁逼出来的**：
/// ```text
/// 只照 DEX 做两次 replace ⇒ 形如 `cb123({...})` 的响应会变成 `cb123{...}`
/// （**前导回调名还在**）⇒ serde_json 解析失败。
/// 实测该接口带 `&callback=` 时确实会回前导名。
/// ⇒ 这里在去括号后再**取第一个 `{` 到最后一个 `}`** 的区间：
///    对 `({...})` 与 `cb123({...})` 两种形态都成立，且不改变纯 JSON 的输入。
/// 判据：`strips_jsonp_wrapper` 用例同时喂了这三种形态。
/// ```
pub fn strip_jsonp(body: &str) -> String {
    let t = body.replace('(', "").replace(')', "");
    let t = t.trim();
    match (t.find('{'), t.rfind('}')) {
        (Some(a), Some(b)) if b > a => t[a..=b].to_string(),
        _ => t.to_string(),
    }
}

/// 极简 HTML 实体解码（本仓既有做法：只处理最常见的几个）
pub fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// 去标签 + 压空白
pub fn strip_tags(s: &str) -> String {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"<[^>]+>").unwrap());
    let t = re.replace_all(s, " ");
    let mut out = String::with_capacity(t.len());
    let mut last_ws = false;
    for ch in t.chars() {
        if ch.is_whitespace() {
            if !last_ws {
                out.push(' ');
            }
            last_ws = true;
        } else {
            out.push(ch);
            last_ws = false;
        }
    }
    decode_entities(out.trim())
}

/// 20 位随机十六进制（DEX：`UUID.randomUUID().toString().replace("-","").substring(0,20)` 的等价）
pub fn random_playerid() -> String {
    use ring::rand::SecureRandom;
    let mut b = [0u8; 10];
    if ring::rand::SystemRandom::new().fill(&mut b).is_err() {
        // 取不到随机时的兜底：用时间串的 md5 前 20 位（**不 panic**）
        let ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let s = format!("{ms:020}");
        return s.chars().take(20).collect();
    }
    b.iter().map(|x| format!("{x:02x}")).collect::<String>()
        .to_uppercase()
        .chars()
        .take(20)
        .collect()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct Web1905 {
    client: reqwest::Client,
}

/// 非 2xx 的**分档**（判据：`real_waf_403_is_classified`）
///
/// # 2026-10-29 真网（`.probe/api-fix/1905-list-403.txt` 与 `1905-list-noheaders.txt`）
/// ```text
/// HTTP/1.1 403 Forbidden
/// x-via: 1.1 PS-XFN-01eRo37 (Cdn Cache Server V2.0)      ← 网宿 CDN
/// Ws-Action: bot                                          ← WAF 判定"机器人"（裸请求才有）
/// <title>Embed Iframe</title> … /_jsc_sbu/ws_sec_page.js   ← JS 挑战页（6072 字节）
/// ```
/// 对 `/`、`/robots.txt`、`/favicon.ico`、`/vod/list/…`、`/api/content/…` **全都一样**
/// ⇒ 这是"站点侧反爬"，不是我们少带了某个 header（已用浏览器全套头 + http/https + 无 www 复测）。
pub fn classify_http_error(status: u16, ws_action: &str, body: &str) -> &'static str {
    let is_waf = ws_action.eq_ignore_ascii_case("bot")
        || body.contains("Embed Iframe")
        || body.contains("ws_sec_page.js");
    match status {
        403 if is_waf => "站点侧 WAF 的 JS 挑战页（非浏览器请求一律 403）⇒ 该源当前不可用",
        403 => "上游拒绝（403）",
        404 => "上游路由不存在（路径形态与上游不符）",
        500..=599 => "上游不可用（5xx）",
        _ => "上游异常",
    }
}

/// 取流响应的**业务状态码**分档（1905 的 `getVideoinfo.php` 是 HTTP 200 + JSON 里的 `StatusCode`）
///
/// # 2026-10-29 真网（`.probe/api-fix/1905-playinfo-signed.txt`、`1905_sig_matrix.out.txt`）
/// ```text
/// 参数齐全 + DEX 逐字的 SHA-1 签名 ⇒ HTTP 200 + `{"StatusCode":403,
///   "info":"HTTP请求不合法,请求参数可能被篡改","data":""}`
/// 缺 signature/page               ⇒ HTTP 200 + `{"StatusCode":400,"info":"请求参数不完整或不正确"}`
/// ⇒ 参数完整性这一层我们**是对的**（400 vs 403 的差别就是证据）；
///   被拒的是**签名**（52 个变体全 403，见 `1905_sig_matrix.out.txt`）⇒ 服务端的签名密钥/算法已变。
/// ```
pub fn play_status_error(v: &Value) -> Option<String> {
    let code = v.get("StatusCode").and_then(|c| c.as_i64())?;
    if code == 200 {
        return None;
    }
    let info = v.get("info").and_then(|s| s.as_str()).unwrap_or("");
    Some(match code {
        403 => format!(
            "上游 1905 取流被拒：StatusCode=403（{info}）—— 参数齐全但签名不被接受；\
             DEX 逐字的 SHA-1 变体 52 种全 403（.probe/api-fix/1905_sig_matrix.out.txt）\
             ⇒ 服务端签名密钥/算法已变，该源取流当前不可用"
        ),
        400 => format!(
            "上游 1905 取流参数不完整：StatusCode=400（{info}）—— 与我们发的参数有关"
        ),
        _ => format!("上游 1905 取流返回 StatusCode={code}（{info}）"),
    })
}

impl Web1905 {
    pub const CLASS: &'static str = "Web1905";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            /*
             * ★ `.no_proxy()` —— 本仓 csp 的**既定惯例**（app3q/app99/app_drama/app_fox/
             *   app_qi/app_sy/app_yqk/app_ys … 都这么做），**我第一版全部漏了**。
             *
             * # 真网后果（HDMoli 那次实测抓到的根因，是**系统性问题**）
             * ```text
             * 本机 `https_proxy=http://127.0.0.1:7890/`（curl/reqwest/urllib 都会读它），
             * 而该代理对某些站点不通 ⇒
             *     reqwest 走代理      ⇒ `operation timed out`
             *     Python no-proxy     ⇒ **HTTP 200**
             *     Python via-proxy    ⇒ TLS 握手超时
             *   ⇒ 失败与"上游"无关，是"我们没绕开本机代理"。
             * ```
             * # 为什么 csp 类必须 `.no_proxy()`
             * ```text
             * ① 这些源是面向**公网直连**的（本机代理不是它们的依赖）；
             * ② 本仓既有 8 个类已这么做 ⇒ 不做就是**偏离惯例**；
             * ③ 装不装代理**不该改变 csp 源的行为**（否则用户装代理就一半源失效）。
             * ```
             */
            .no_proxy()
            .user_agent(UA)
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .expect("HTTP client 构建失败（TLS 后端不可用）—— 不许退回无 no_proxy 的兜底");
        Self { client }
    }

    /// DEX 的 `Web1905.a(url)`：带 UA/Referer/Accept 三个头 GET
    async fn get(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::REFERER, REFERER)
            .header(reqwest::header::ACCEPT, ACCEPT)
            .send()
            .await
            .map_err(|e| format!("请求上游失败（{url}）：{e}"))?;
        let status = resp.status();
        let waf = resp
            .headers()
            .get("ws-action")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();
        let body = resp
            .text()
            .await
            .map_err(|e| format!("读取上游响应失败（{url}）：{e}"))?;
        if !status.is_success() {
            /*
             * ★ 如实区分"上游反爬/不可用"与"我们的 bug"：
             *   2026-10-29 实测：1905 的 `www.1905.com` 对**所有**路径（含 `/`、`/robots.txt`、
             *   `/favicon.ico`）返 403 + `Ws-Action: bot` + 6072 字节的 `Embed Iframe` 挑战页
             *   （`/_jsc_sbu/ws_sec_page.js` 那套网宿 WAF）。证据：
             *   `.probe/api-fix/1905-list-403.txt`（带浏览器头）、`1905-list-noheaders.txt`（裸）。
             *   ⇒ 把状态码 + WAF 头 + body 头 80 字带出来，别让调用方猜。
             */
            let head = body.chars().take(80).collect::<String>();
            return Err(format!(
                "上游 1905 返回 HTTP {status}（{url}）—— {}；Ws-Action={waf:?}；\
                 body 前 80 字：{head}",
                classify_http_error(status.as_u16(), &waf, &body)
            ));
        }
        Ok(body)
    }
}

impl Default for Web1905 {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for Web1905 {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let categories = CATS
            .iter()
            .map(|(id, name)| CspCategory {
                id: id.to_string(),
                name: name.to_string(),
            })
            .collect();
        /*
         * 首页预取第一分类（DEX homeContent 也是抓 n_1 的列表页）。
         * ★ 取不到就**空**，不是错 —— 分类表是写死的、可用；DEX 同样容错。
         */
        let items = self
            .get(&list_url("n_1", 1))
            .await
            .ok()
            .and_then(|h| list_from_html(&h, "n_1", 1).ok())
            .map(|l| l.items)
            .unwrap_or_default();
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = if tid.trim().is_empty() { "n_1" } else { tid.trim() };
        let html = self.get(&list_url(tid, page)).await?;
        list_from_html(&html, tid, page)
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        /*
         * DEX searchContent：`https://www.1905.com/search/index-p-type-all-q-` + kw + `.html`
         * 条目在 `div.movie_box > div > div`（href 在 `div > ul > li.paly-tab-icon > a`，
         * 图在 `div > div.movie-pic > a > img`）⇒ 与列表页同一套 `a[href][title]` 抽取。
         * ⚠️ 搜索页没有 `title=` 属性（DEX 取的是 `alt`）⇒ 单独一条正则。
         */
        let url = format!("{SITE}/search/index-p-type-all-q-{kw}.html");
        let html = self.get(&url).await?;
        let items = search_items_from_html(&html, page)?;
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        true
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let cid = detail_id_of(id);
        if cid.is_empty() {
            return Err(format!("详情 id 无法归一成 contentid（原始 id={id:?}）"));
        }
        let body = self.get(&detail_url(&cid)).await?;
        let v: Value = serde_json::from_str(&body).map_err(|e| {
            format!(
                "上游详情响应不是合法 JSON（{e}）；前 100 字：{}",
                body.chars().take(100).collect::<String>()
            )
        })?;
        detail_from(&v, &cid)
    }

    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let cid = detail_id_of(id);
        if cid.is_empty() {
            return Err(format!("取流 id 无法归一成 contentid（原始 id={id:?}）"));
        }
        let nonce = now_ms();
        let playerid = random_playerid();
        let page = play_page_of(&cid);
        let src = sign_source(&cid, nonce, &playerid, &page);
        let sig = sha1_hex(&src);
        let cb = format!("cb{}", &sha1_hex(&format!("{nonce}{playerid}"))[..16]);
        let url = playinfo_url(&cid, nonce, &playerid, &sig, &cb);

        let raw = self.get(&url).await?;
        let v: Value = serde_json::from_str(&strip_jsonp(&raw)).map_err(|e| {
            format!(
                "上游取流响应不是合法 JSON / JSONP（{e}）；前 100 字：{}",
                raw.chars().take(100).collect::<String>()
            )
        })?;
        // ★ 先看业务状态码（HTTP 200 + StatusCode≠200 是本站的常态错误形态）
        if let Some(e) = play_status_error(&v) {
            return Err(e);
        }
        let url = play_url_from(&v)?;
        Ok(vec![CspPlay {
            url,
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                ("Referer".to_string(), REFERER.to_string()),
            ],
            label: Some("1905".to_string()),
        }])
    }
}

/// 搜索页 → 条目（DEX：`div > ul > li.paly-tab-icon > a` 取 href / `img` 取 alt+src）
pub fn search_items_from_html(html: &str, page: u32) -> Result<Vec<CspItem>, String> {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| {
        Regex::new(r#"(?is)<a\b[^>]*href\s*=\s*"(/vod/play/[^"]+|/m/[^"]+)"[^>]*>(.*?)</a>"#)
            .expect("search item regex")
    });
    static RE_IMG: OnceLock<Regex> = OnceLock::new();
    let re_img = RE_IMG
        .get_or_init(|| Regex::new(r#"(?is)<img\b[^>]*?(?:src|data-src)\s*=\s*"([^"]+)""#).unwrap());
    static RE_ALT: OnceLock<Regex> = OnceLock::new();
    let re_alt =
        RE_ALT.get_or_init(|| Regex::new(r#"(?is)<img\b[^>]*?alt\s*=\s*"([^"]+)""#).unwrap());

    let mut items = Vec::new();
    for cap in re.captures_iter(html) {
        let href = cap.get(1).map(|m| m.as_str()).unwrap_or("");
        let inner = decode_entities(cap.get(2).map(|m| m.as_str()).unwrap_or(""));
        let alt = re_alt
            .captures(&inner)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default();
        let title = if alt.is_empty() {
            strip_tags(&inner)
        } else {
            alt
        };
        if title.is_empty() {
            continue;
        }
        let id = play_id_of(href).unwrap_or_else(|| href.to_string());
        items.push(CspItem {
            id,
            title,
            cover: re_img
                .captures(&inner)
                .and_then(|c| c.get(1))
                .map(|m| m.as_str().to_string())
                .filter(|s| !s.starts_with("data:")),
            subtitle: None,
        });
    }
    if items.is_empty() {
        return Err(format!(
            "上游搜索第 {page} 页没解析出条目（页面可能被反爬拦或改版）—— 实际长度 {} 字节",
            html.len()
        ));
    }
    Ok(items)
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(Web1905);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// ★★ 签名是 `sha1_hex(组装串)` —— 组装串里四个可变位（cid/nonce/playerid/page）
    ///    与两条 escape 都必须真的进串
    ///
    /// 注入：把 `sign_source` 里 `page.replace(':','%3A')` 那一步删掉 ⇒ 本条红。
    fn sign_source_matches_dex_format_order() {
        let s = sign_source(
            "1104007",
            1_700_000_000_000,
            "ABCDEF0123456789ABCD",
            "https://www.1905.com/vod/play/1104007.shtml",
        );
        assert!(
            s.starts_with("cid=1104007&expiretime=1700000600000&nonce=1700000000000&page="),
            "★ 前缀顺序必须与 DEX 的 format 逐字一致：{s}"
        );
        assert!(
            s.contains("page=https%3A%2F%2Fwww.1905.com%2Fvod%2Fplay%2F1104007.shtml"),
            "★ page 必须做 : → %3A 与 / → %2F 两条替换：{s}"
        );
        assert!(
            s.ends_with("&playerid=ABCDEF0123456789ABCD&type=hls&uuid=ABCDEF0123456789ABCD.dde3d61a0411511d"),
            "★ uuid 后半固定尾巴 .dde3d61a0411511d（且 uuid 与 playerid 是同一个 20 位串）：{s}"
        );
        // expiretime = now + 600s（DEX 的 1000*600）
        assert!(s.contains("expiretime=1700000600000"), "★ 过期时间 = now + 600000 ms");

        // 变化敏感
        let t = sign_source("1", 1_700_000_000_000, "A", "x");
        let t2 = sign_source("1", 1_700_000_000_001, "A", "x");
        assert_ne!(sha1_hex(&t), sha1_hex(&t2), "★ nonce 变了 ⇒ 签名必须变");
        let t3 = sign_source("2", 1_700_000_000_000, "A", "x");
        assert_ne!(sha1_hex(&t), sha1_hex(&t3), "★ cid 变了 ⇒ 签名必须变");
    }

    #[test]
    fn sha1_known_vector() {
        assert_eq!(sha1_hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(sha1_hex("").len(), 40);
        assert!(sha1_hex("abc").chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    /// ★ 列表选择器**随 tid 变**（DEX 只有两条分支）
    ///
    /// 注入：把 `list_selector` 改成恒返回一个字符串 ⇒ 本条红。
    fn list_selector_switches_on_tid() {
        assert_eq!(list_selector("n_2"), "div.mod > div > a");
        assert_eq!(list_selector("n_1"), "section.search-list > div > a");
        assert_eq!(list_selector("c_927"), "section.search-list > div > a");
        assert_ne!(list_selector("n_2"), list_selector("n_1"), "★ 两个分支必须不同");
    }

    #[test]
    /// ★★ 反空真：列表 / 搜索 / 详情剧集 / 取流 解析出 0 条 ⇒ **必须 Err**
    ///
    /// 注入：删掉任意一个 `is_empty()`/`ok_or_else` 的 Err 分支 ⇒ 对应断言红。
    fn empty_parses_are_errors() {
        // 列表：一个 a[title] 都没有（例如把反爬页当 HTML）
        let refl: &str = "<html><body><div>Embed Iframe</div></body></html>";
        let e = list_from_html(refl, "n_1", 1).expect_err("★ 0 条必须 Err");
        assert!(e.contains("没解析出条目"), "{e}");
        assert!(e.contains("n_1"), "错误要点名分类：{e}");
        assert!(e.contains("1"), "错误要点名页码：{e}");

        // 搜索同理
        assert!(
            search_items_from_html(refl, 1).is_err(),
            "★ 搜索 0 条也必须 Err"
        );

        // 详情：反爬页解析出来的 JSON 没有 1905 字段
        let junk: Value = serde_json::from_str(r#"{"err":"x","msg":"y"}"#).unwrap();
        let e2 = detail_from(&junk, "1").expect_err("★ 缺字段必须 Err");
        assert!(e2.contains("没有 1905 的字段"), "{e2}");

        // 详情：有 title 但 series_data 空 ⇒ 也要 Err
        let no_ep: Value = serde_json::from_str(r#"{"title":"x","info":{"series_data":[]}}"#).unwrap();
        let e3 = detail_from(&no_ep, "1").expect_err("★ 0 集必须 Err");
        assert!(e3.contains("0 集"), "{e3}");

        // 取流：三档都没有
        let none: Value = serde_json::from_str(
            r#"{"data":{"sign":{},"quality":{}}}"#,
        )
        .unwrap();
        let e4 = play_url_from(&none).expect_err("★ 无档位必须 Err");
        assert!(e4.contains("都没有"), "{e4}");

        // 取流：档位有但 host/path 不全
        let partial: Value = serde_json::from_str(
            r#"{"data":{"sign":{"uhd":{}},"quality":{"uhd":{"path":"/a.m3u8"}}}}"#,
        )
        .unwrap();
        assert!(play_url_from(&partial).is_err(), "★ host 空也必须 Err");
    }

    #[test]
    /// 真实形态解析（逐字段用 DEX 字段名构造）
    fn parses_dex_field_names() {
        // 详情：title/thumb/description/direct/starring/info.series_data[].contentid
        let det: Value = serde_json::from_str(
            r#"{"title":"上甘岭","thumb":"https://p/a.jpg","commendreason":"推荐语",
                 "description":"简介","direct":"沙蒙","starring":"高保成",
                 "info":{"series_data":[{"contentid":1104007,"title":"正片"},
                                        {"contentid":1104008}]}}"#,
        )
        .unwrap();
        let d = detail_from(&det, "1104007").unwrap();
        assert_eq!(d.title, "上甘岭");
        assert_eq!(d.cover.as_deref(), Some("https://p/a.jpg"));
        assert_eq!(d.description.as_deref(), Some("简介"));
        assert_eq!(d.episodes.len(), 2);
        assert_eq!(d.episodes[0].id, "1104007", "★ 集 id 是 contentid");
        assert_eq!(d.episodes[0].title, "正片");
        assert_eq!(d.episodes[1].title, "第2集", "没给标题就按序号兜底");
        assert_eq!(d.episodes[0].flag, "1905");

        // 取流：uhd 优先
        let play: Value = serde_json::from_str(
            r#"{"data":{"sign":{"uhd":{},"hd":{}},
                 "quality":{"uhd":{"host":"https://h1/","path":"a.m3u8"},
                            "hd":{"host":"https://h2/","path":"b.m3u8"}}}}"#,
        )
        .unwrap();
        assert_eq!(play_url_from(&play).unwrap(), "https://h1/a.m3u8", "★ uhd 优先于 hd");

        // 只有 sd ⇒ 用 sd
        let only_sd: Value = serde_json::from_str(
            r#"{"data":{"sign":{"sd":{}},"quality":{"sd":{"host":"https://h3/","path":"c.m3u8"}}}}"#,
        )
        .unwrap();
        assert_eq!(play_url_from(&only_sd).unwrap(), "https://h3/c.m3u8");
    }

    #[test]
    /// JSONP 外壳 `({...})` 必须能剥掉（DEX 的两次 replace）
    ///
    /// ★ 这条**抓到过真 bug**：第一版只做两次 replace ⇒ 带 `callback=` 的响应
    ///   会留下前导回调名（`cb123{...}`）⇒ 解析失败。修法是再去掉非 `{...}` 的前后缀。
    /// 注入：把 `strip_jsonp` 里那个 `t.find('{')` 区间裁剪删掉 ⇒ 第 2、3 个断言红。
    #[test]
    fn strips_jsonp_wrapper() {
        // ① 裸括号形态
        let wrapped = r#"({ "data": { "sign": {} } })"#;
        let s = strip_jsonp(wrapped);
        assert!(s.starts_with('{'), "★ 必须以 {{ 开头：{s}");
        assert!(s.ends_with('}'), "{s}");
        assert!(!s.contains('('), "{s}");
        serde_json::from_str::<Value>(&s).expect("★ 剥壳后必须能解析");

        // ② 带回调名（**实测该接口带 &callback= 时会这么回**）
        let named = r#"cb123({ "data": { "sign": {} } })"#;
        let s2 = strip_jsonp(named);
        assert!(s2.starts_with('{'), "★ 前导回调名也要剥掉：{s2}");
        serde_json::from_str::<Value>(&s2).expect("★ 剥完必须能解析（第一版在这里红过）");

        // ③ 本来就是纯 JSON ⇒ **一个字都不许改**
        let plain = r#"{"data":{"sign":{}}}"#;
        assert_eq!(strip_jsonp(plain), plain, "★ 纯 JSON 不该被改动");

        // ④ 没有 JSON 时原样返回（由调用方的 parse 报错，不在这里造空对象）
        assert_eq!(strip_jsonp("  nope  "), "nope");
    }

    #[test]
    /// id 归一的三种真实形态
    fn detail_id_normalization() {
        assert_eq!(detail_id_of("1104007"), "1104007");
        assert_eq!(detail_id_of("/vod/play/1104007.shtml"), "1104007");
        assert_eq!(detail_id_of("https://www.1905.com/vod/play/1104007.shtml"), "1104007");
        assert_eq!(detail_id_of("1104007.shtml?x=1"), "1104007");
        assert_eq!(detail_id_of("  1104007  "), "1104007");
    }

    #[test]
    /// 列表页抽取（自造与 1905 结构对齐的样本；**坏样本也要能红**）
    fn list_extraction_and_play_id() {
        let html = r#"
          <div class="mod"><div>
            <a href="/vod/play/1104007.shtml" title="上甘岭" >
              <img data-src="https://img/a.jpg" />
              <p>HD 国语</p>
            </a>
          </div></div>
          <section class="search-list"><div>
            <a href="/vod/play/1104008.shtml" title="英雄儿女">
              <img src="https://img/b.jpg" /><p>已完结</p>
            </a>
          </div></section>"#;
        let l = list_from_html(html, "n_1", 1).expect("应解析成功");
        assert_eq!(l.items.len(), 2, "实际 {:?}", l.items);
        assert_eq!(l.items[0].title, "上甘岭");
        assert_eq!(l.items[0].cover.as_deref(), Some("https://img/a.jpg"));
        assert_eq!(l.items[0].subtitle.as_deref(), Some("HD 国语"));
        assert_eq!(l.items[1].title, "英雄儿女");
        // ★ play id 抠取：DEX 的正则 `play/(.*?).sh` 作用于 `/vod/play/1104007.shtml`
        assert_eq!(
            play_id_of("/vod/play/1104007.shtml").as_deref(),
            Some("1104007"),
            "★ 抠出的是 play id"
        );
        assert_eq!(play_id_of("/vod/play/1104007.shtml?x=1").as_deref(), Some("1104007"));
        assert_eq!(play_id_of("/vod/list/n_1/o3p1.html"), None, "非 play 链接不该抠出东西");

        // 坏样本：只有导航 <a>（带 href 但无 title 且在 <a> 外）⇒ 0 条 ⇒ Err
        let nav = r#"<nav><a href="/x">首页</a><a href="/y">电影</a></nav>"#;
        assert!(list_from_html(nav, "n_1", 1).is_err(), "★ 导航链接不该被当条目");
    }

    #[test]
    /// `data:` 占位图（懒加载）不能被当成封面
    fn lazy_placeholder_is_not_a_cover() {
        let html = r#"<a href="/vod/play/1.shtml" title="X">
                        <img data-src="data:image/svg+xml,%3Csvg" />
                     </a>"#;
        let l = list_from_html(html, "n_1", 1).unwrap();
        assert_eq!(l.items[0].cover, None, "★ data: 占位图必须丢掉");
    }

    #[test]
    /// 分类表是 DEX 里的 8 条，且 n_2 在其中（否则 list_selector 的分支永远走不到）
    fn cats_match_dex_table() {
        assert_eq!(CATS.len(), 8);
        assert_eq!(CATS[0], ("n_1", "电影"));
        assert!(CATS.iter().any(|(id, _)| *id == "n_2"), "★ n_2 必须存在");
        assert_eq!(list_url("n_1", 1), "https://www.1905.com/vod/list/n_1/o3p1.html");
        assert_eq!(detail_url("1"), "https://www.1905.com/api/content/?m=Vod&a=getVodSidebar&id=1&fomat=json");
    }

    #[test]
    /// ★ playerid 是 20 位十六进制（DEX：UUID 去横线取前 20）
    fn playerid_shape() {
        let p = random_playerid();
        assert_eq!(p.chars().count(), 20, "{p}");
        assert!(p.chars().all(|c| c.is_ascii_hexdigit()), "★ 必须十六进制：{p}");
        let q = random_playerid();
        assert_ne!(p, q, "两次调用不该相同（每次都该是新 nonce）");
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_web1905 -- --ignored --nocapture"]
    async fn csp_live_web1905_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Web1905::new();
        let home = s.home("").await.expect("home（分类表写死）应成功");
        eprintln!("[LIVE] home: 分类 {} 个，预取 {} 条", home.categories.len(), home.items.len());
        match s.list("n_1", 1, "").await {
            Ok(l) => eprintln!("[LIVE] list(n_1): {} 条，首条={}", l.items.len(), l.items[0].title),
            Err(e) => eprintln!("[LIVE] list(n_1) 如实失败：{e}"),
        }
    }

    #[test]
    /// ★★ 真实 WAF 403 转录的**分档判据**（离线；转录在 `.probe/api-fix/1905-list-403.txt`）
    ///
    /// 转录逐字：`HTTP/1.1 403 Forbidden` / `Ws-Action: bot` / `<title>Embed Iframe</title>`
    /// 注入：把 `classify_http_error` 里 `403 if is_waf` 那一支删掉 ⇒ 本条红。
    fn real_waf_403_is_classified() {
        // 逐字取自 .probe/api-fix/1905-list-noheaders.txt（裸请求，带 Ws-Action: bot）
        let body = "<!doctype html><html><head><meta charset=utf-8><title>403 Forbidden</title>";
        let c = classify_http_error(403, "bot", body);
        assert!(
            c.contains("WAF") && c.contains("不可用"),
            "★ 403+Ws-Action=bot 必须判成「站点侧 WAF ⇒ 该源当前不可用」，实际：{c}"
        );
        // 逐字取自 .probe/api-fix/1905-list-403.txt（带浏览器头，没有 Ws-Action，但 body 是挑战页）
        let body2 = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>…<title>Embed Iframe</title>";
        assert!(classify_http_error(403, "", body2).contains("WAF"), "★ 靠 body 也要认出来");
        // 反面：普通 403 不该被误判成 WAF
        assert!(!classify_http_error(403, "", "<html>denied</html>").contains("WAF"));
        assert!(classify_http_error(502, "", "").contains("上游不可用"));
    }

    #[test]
    /// ★★ 取流业务状态码的**分档判据**（真实响应转录在 `.probe/api-fix/1905-playinfo-signed.txt`）
    ///
    /// 转录逐字：`cb1({"StatusCode":403,"info":"HTTP请求不合法,请求参数可能被篡改","data":""})`
    /// 另一条：    `null({"StatusCode":400,"info":"请求参数不完整或不正确","data":""})`
    /// 注入：把 `play_status_error` 的 `403` 支删掉（落到 `_`）⇒ 本条红。
    fn real_play_status_is_classified() {
        let v: Value = serde_json::from_str(
            r#"{"StatusCode":403,"info":"HTTP请求不合法,请求参数可能被篡改","data":""}"#,
        )
        .unwrap();
        let e = play_status_error(&v).expect("★ 403 必须 Err");
        assert!(e.contains("签名"), "★ 必须说清是签名被拒：{e}");
        assert!(e.contains("不可用"), "★ 必须给出「取流当前不可用」的结论：{e}");

        let v400: Value =
            serde_json::from_str(r#"{"StatusCode":400,"info":"请求参数不完整或不正确","data":""}"#)
                .unwrap();
        let e400 = play_status_error(&v400).expect("★ 400 必须 Err");
        assert!(e400.contains("参数不完整"), "{e400}");
        assert_ne!(e, e400, "★ 400 与 403 必须给出不同结论（否则等于没分档）");

        // 200 ⇒ 放行（不许把成功也判成错）
        let ok: Value = serde_json::from_str(r#"{"StatusCode":200,"data":{"sign":{}}}"#).unwrap();
        assert!(play_status_error(&ok).is_none(), "★ 200 不该被拦");
    }

    /// ★★ 真网络：1905 的**两个入口分别**取证（一个 WAF、一个签名）
    ///
    /// 判据（不做假成功）：
    /// ```text
    /// ① www 列表页 ⇒ 必须是非 2xx，且错误里带得出「WAF / 不可用」的分档
    /// ② profile 取流 ⇒ HTTP 200（域名没被 WAF 拦），但 StatusCode=403（签名被拒）
    ///    ⇒ 必须能从错误里读出"签名不被接受"，而不是含糊的"没有 data"
    /// ```
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_web1905_waf_and_sign -- --ignored --nocapture"]
    async fn csp_live_web1905_waf_and_sign() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Web1905::new();
        match s.list("n_1", 1, "").await {
            Ok(l) => eprintln!("[LIVE] list 成功 {} 条（WAF 放行了？如实记录）", l.items.len()),
            Err(e) => {
                eprintln!("[LIVE] list 如实失败：{e}");
                assert!(
                    e.contains("WAF") || e.contains("不可用") || e.contains("403"),
                    "★ WAF 要判得出来：{e}"
                );
            }
        }
        match s.play("1905", "1464376", "").await {
            Ok(p) => eprintln!("[LIVE] play 成功：{}", p[0].url),
            Err(e) => {
                eprintln!("[LIVE] play 如实失败：{e}");
                assert!(
                    e.contains("签名") || e.contains("StatusCode") || e.contains("参数不完整"),
                    "★ 取流失败要给业务状态码分档：{e}"
                );
            }
        }
    }
}