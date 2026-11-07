// ═══════════════════════════════════════════════════════════════════════
//  TVBox 配置导入（task-5）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个模块干什么
//
// TVBox 生态里分享的配置是一份 JSON，里面有：
//
// ```text
// sites[]  站点列表（type 字段决定协议：0 纯 JSON / 1 苹果CMS / 3 spider / 4 其它）
// lives[]  直播源（m3u/txt）
// parses[] 第三方网页解析接口
// ```
//
// 本模块把其中 **type=1（苹果CMS v10）** 的站点就地转成 sourin 的
// MediaProvider（不是生成 JS 插件，见下），其余类型如实报告「转不了」。
//
// # 为什么不生成 JS 插件（与 tools/tvbox-convert.mjs 的差别）
//
// 外部工具 tvbox-convert.mjs 的做法是「生成一份 .js 插件源码，丢给
// QuickJS 跑」。应用内**不走那条路**，而是直接实现 Rust 原生 Provider：
//
// ```text
// · 少一层「生成 JS → 沙箱执行 → 解析 JSON」的翻译，链路短、失败点少
// · 不受 QuickJS 10s 脚本预算限制（大分类扫描要连发多页请求）
// · 纯逻辑（JSON 宽松解析 / URL 归一化 / 剧集切分）可直接单测
// ```
//
// 协议映射规则与 tvbox-convert.mjs **逐条等价**（那份工具踩过的坑都在
// 这里复刻了，包括 normalizeApiUrl 必须剥查询串、分类兜底绝不能退回
// 全站最新、PARSE_SERVICES 出错必须 continue 而不是 throw）。
//
// # 苹果CMS v10 协议
//
// ```text
// 分类 {api}?ac=list
// 列表 {api}?ac=videolist&t={typeId}&pg={page}
// 详情 {api}?ac=videolist&ids={id}
// 搜索 {api}?ac=videolist&wd={关键词}&pg={page}
// 响应 { code, page, pagecount, total, class:[...], list:[{vod_id,vod_name,
//        vod_pic,vod_play_url,vod_content,vod_blurb,vod_remarks,type_id,type_id_1}] }
// ```

use crate::model::{
    Capabilities, Category, Episode, ErrorKind, MediaDetail, MediaId, MediaItem, MediaKind, Page,
    PlayRequest, PlaySource, ProviderError, ProviderManifest, Result, Section, SectionSource,
    StreamCandidate, StreamKind, TvboxCategoryEntry,
};
use crate::provider::{ListRequest, MediaProvider};
use async_trait::async_trait;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

/// 与 TVBox / tvbox-convert.mjs 保持一致的 UA
pub const TVBOX_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) \
AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";

/// 下载 **TVBox 配置**时用的 UA（与上面那个不同，是有原因的）
///
/// # ★ 实测（2026-10-04）：同一个 URL，UA 决定拿到的是配置还是网页
///
/// 站点 `https://tv.xn--yhqu5zs87a.top`（菜妮丝）做了内容协商：
/// ```text
/// UA = Mozilla/5.0 (Chrome)  → 200 text/html          13.8KB 「FongMi 影视APP 下载页」
/// UA = okhttp/3.12.13        → 200 application/json   19.3KB  真配置
/// UA = 完全不发              → 200 text/html          13.8KB  下载页
/// ```
/// 逐项排除过：HTTP/1.1 与 HTTP/2、Accept、Accept-Encoding 都不影响结果，
/// **只有 UA 影响**（诊断见 `real_sites::diagnose_content_negotiation`）。
///
/// 为什么不能把全局 [TVBOX_UA] 也改成 okhttp：那是解析/播放链路在用的 UA，
/// 有 task5 的实测约束（假源站与真解析服务都按它验过），改它属于越界改动。
/// 所以**只给「下载配置」这一条路径**用 TVBox 生态自己的 UA。
///
/// ⚠️ 不这么做的后果（真实症状）：用户在浏览器里明明看到的是 JSON，
///    导入时报「配置不是合法 JSON」，而错误里看不到任何线索 ——
///    因为服务端回的是**一个完全合法的 HTML 页面**。
pub const TVBOX_CONFIG_UA: &str = "okhttp/3.12.13";

/// 下载一份 TVBox 配置（带上面那个 UA）
///
/// 与 [get_text_with] 的区别只有 UA —— 但这个区别是**功能性的**，不是风格。
pub async fn fetch_config_text(
    client: &reqwest::Client,
    url: &str,
) -> std::result::Result<String, String> {
    let resp = client
        .get(url)
        .header(reqwest::header::USER_AGENT, TVBOX_CONFIG_UA)
        .header(reqwest::header::ACCEPT, "*/*")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    // ★ 血缘批次（2026-11-01）：野外配置常以 base64** 包裹，不剥掉的话
    //   import / 检测更新 / 定时更新三条路径全部报"配置不是合法 JSON"。
    //   真实案例：https://8815.kstore.vip/tvbox/wmz（Owner 指定的订阅链接）。
    unwrap_tvbox_config_text(&text)
}
/// 第三方网页解析服务（前缀 + urlencoded(目标页)）
///
/// 来源：tvbox-convert.mjs 里收集 15 个 type=1 接口实测后只剩这一个活着。
///
/// ★ 2026-10-10（review agent 查出安全问题，lead 处理）：这里原来还有第二个
///   `huaqi 那个域名 + 一个 32 位的 key 参数` —— **那是一个真实的付费服务凭据，
///   却被硬编码进了公开仓库**。而且本文件上方原有的注释自己就写着
///   「2026-10-02 复测：huaqi 已失效（返回 {"code":"404",...,"msg":"解析失败"}，
///   没有 url 字段 → 自动 continue）」
///   ⇒ **它既不安全、也早已不工作**，留着只是让每个用户都在用一个死服务。
///   ⇒ 直接删掉。若将来要恢复，请改成从**用户自己的源配置**里读 key，
///      不要再把任何人的密钥写进代���。
///
/// ⚠️ 因此：如果你在别处见过 `api.huaqi.pro` 的 key，**请去该服务后台吊销它**
///   （凭据已随公开仓库泄露过）。
/// ⚠️ 类型刻意写成**切片** `[&str]` 而不是 `[&str; 1]`：
///   固定长度的数组会让「加一个解析服务」变成**编译错误**，而加服务是正常需求；
///   更重要的是，它会让下面那条「凭据不许回来」的守卫在改代码时先炸在编译期，
///   根本走不到断言（实测踩过：把凭据放回去时先报 E0308，守卫形同虚设）。
pub const PARSE_SERVICES: &[&str] = &[
    "https://player.gimy.bot/u/parse.php?url=",
];

/// 单次 HTTP 超时（探测与取列表共用）
const HTTP_TIMEOUT_SECS: u64 = 20;
/// 导入时并发探测的上限（站点多时不要打爆网络）
const MAX_PROBE_CONCURRENCY: usize = 12;
/// 分类兜底扫描的最大页数（服务端不认 t= 时用）
const SCAN_MAX_PAGES: u32 = 8;
/// 分类兜底扫描最多收集多少条
const SCAN_MAX_ITEMS: usize = 20;
/// 首页最多放几个分类区块
const HOME_SECTIONS: usize = 8;

// ═══════════════════════════════════════════════════════════════════════
//  纯函数区（全部可单测，无网络、无 IO）
// ═══════════════════════════════════════════════════════════════════════

/// 是否以 http:// 或 https:// 开头（大小写不敏感）
pub fn starts_http(s: &str) -> bool {
    match s.get(..7) {
        Some(p) if p.eq_ignore_ascii_case("http://") => true,
        _ => matches!(s.get(..8), Some(p) if p.eq_ignore_ascii_case("https://")),
    }
}

/// 拆出 (scheme, origin)，如 ("https:", "https://a.com")
///
/// 手写而不是用 url crate —— 本项目依赖树里**没有 url crate**
/// （Cargo.toml 只有 urlencoding / regex）。
pub fn split_origin(base: &str) -> Option<(String, String)> {
    let rest = if let Some(r) = base.strip_prefix("https://") {
        ("https:", r)
    } else if let Some(r) = base.strip_prefix("http://") {
        ("http:", r)
    } else {
        return None;
    };
    let (scheme, host_and_path) = rest;
    let end = host_and_path
        .find(|c| c == '/' || c == '?' || c == '#')
        .unwrap_or(host_and_path.len());
    let host = &host_and_path[..end];
    if host.is_empty() {
        return None;
    }
    Some((scheme.to_string(), format!("{scheme}//{host}")))
}

/// 取 host（不含端口之后的路径）
fn host_of(url: &str) -> Option<String> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let end = rest
        .find(|c| c == '/' || c == '?' || c == '#')
        .unwrap_or(rest.len());
    let host = &rest[..end];
    if host.is_empty() {
        None
    } else {
        Some(host.to_string())
    }
}

/// 宽松 JSON 解析 —— 直接对应 tvbox-convert.mjs 的 parseLooseJson
///
/// TVBox 配置在野外的真实形态经常不是严格 JSON：
///
/// ```text
/// · 带 UTF-8 BOM（Windows 记事本另存）
/// · JSONP 包裹     foo({...});
/// · 整行 // 注释
/// · 对象/数组末尾多余逗号
/// · ★ 字符串字面量里直接换行（裸控制字符）—— 2026-10-04 实测两条真配置栽在这
/// ```
pub fn parse_loose_json(text: &str) -> std::result::Result<serde_json::Value, String> {
    let s = text.trim_start_matches('\u{feff}').trim();
    let s = strip_jsonp(s);
    // ★ 顺序关键：必须在逐行剥注释之前先把字符串里的裸控制字符转义掉，
    //   否则「整行 // 注释」会把字符串内部那半行也一并删掉。
    let escaped = escape_control_chars_in_strings(s);
    let mut cleaned = String::with_capacity(escaped.len());
    for line in escaped.lines() {
        if line.trim_start().starts_with("//") {
            continue;
        }
        cleaned.push_str(line);
        cleaned.push('\n');
    }
    let cleaned = remove_trailing_commas(&cleaned);
    serde_json::from_str(&cleaned).map_err(|e| e.to_string())
}

/// 剥掉 TVBox 野外混淆形态的 `base64**` 包裹（血缘批次，2026-11-01）
///
/// # 形态考证（真链接实抓，`.probe/bdjmcc-sub.json`）
///
/// `https://8815.kstore.vip/tvbox/wmz` 的响应体是：
///
/// ```text
/// "\n" + "YmFzZTY0**" + base64(JSON)
/// ```
///
/// `YmFzZTY0` 恰是 base64("base64") —— 即 TVBox 的 `base64**` 包裹标记
/// （标记自身也按 base64 写出）。不剥掉它，import / 检测更新 / 定时更新
/// 三条链接路径全部死在「配置不是合法 JSON」—— 用户于是被迫走文本粘贴
/// 导入，血缘（source_url）就此丢失（64 条子站「从未更新」的根因）。
///
/// # 解包语义
///
/// ```text
/// · 只认明确以 `base64**` 或 `YmFzZTY0**` 开头的形态，其余原样返回（绝不猜）
/// · 该标记按设计可嵌套（剥一层出来还可能再包一层）⇒ 循环解包，上限 3 层，
///   超限报清晰错误 —— 上限防的是恶意套娃，不是正常配置
/// · base64 解码用 csp::shared::b64_decode（仓内自带宽容实现，零新依赖）
/// ```
pub fn unwrap_tvbox_config_text(text: &str) -> std::result::Result<String, String> {
    const MAX_LAYERS: usize = 3;
    let mut cur = text.trim().to_string();
    for _ in 0..MAX_LAYERS {
        let rest = match cur.strip_prefix("base64**") {
            Some(r) => r,
            None => match cur.strip_prefix("YmFzZTY0**") {
                Some(r) => r,
                // 不是混淆形态（普通 JSON / JSONP / 带注释的宽松配置）⇒ 原样放行。
                // trim 是无害的：parse_loose_json 自己也先 trim。
                None => return Ok(cur),
            },
        };
        let bytes = crate::csp::shared::b64_decode(rest)
            .map_err(|e| format!("TVBox 配置是 base64** 混淆形态，但解码失败：{e}"))?;
        cur = String::from_utf8(bytes)
            .map_err(|_| "TVBox 配置 base64** 解码后不是合法 UTF-8 文本".to_string())?
            .trim()
            .to_string();
    }
    Err(format!(
        "TVBox 配置的 base64** 包裹嵌套超过 {MAX_LAYERS} 层，拒绝处理（疑似恶意套娃）"
    ))
}

/// 把字符串字面量里的裸控制字符补成转义序列
///
/// ★ 为什么需要它（2026-10-04 实测，两条真实 TVBox 配置因此导入失败）：
///
/// · http://xhztv.top/4k.json          字符串内 3 个裸 0x0A，形如 "优<LF>酷"
/// · https://gh-proxy.com/…/svip.json  字符串内 1 个裸 0x0A，形如 "简介": "…安静<LF>       "
///
/// 两份配置用 Python json.loads(strict=False)（宽松模式）都能解析、strict=True 都失败
/// ⇒ 字符串内的裸控制字符是**唯一**的拦路虎，其余（BOM / // 注释 / 尾逗号）我们本来就已处理。
///
/// RFC 8259 规定字符串里不许出现 U+0000-U+001F，serde_json 严格执行；
/// 但配置作者的本意显然只是「这里有个换行」，所以按最保守的方式补成转义序列：
/// 能用短转义的用 \b \f \n \r \t，其余（如 0x01、0x1F）用 \uXXXX。
///
/// ★ 必须认字符串状态：字符串外的空白（含 CRLF 里的 \r）保持原样，交给后面的逐行处理。
fn escape_control_chars_in_strings(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_string = false;
    let mut escaped = false;
    for c in s.chars() {
        if !in_string {
            if c == '"' {
                in_string = true;
            }
            out.push(c);
            continue;
        }
        if escaped {
            // 上一个字符是反斜杠，当前字符是字面量（含 \" 与 \\），原样保留
            escaped = false;
            out.push(c);
            continue;
        }
        match c {
            '\\' => {
                escaped = true;
                out.push(c);
            }
            '"' => {
                in_string = false;
                out.push(c);
            }
            c if (c as u32) < 0x20 => {
                let esc = match c as u32 {
                    0x08 => "\\b".to_string(),
                    0x0c => "\\f".to_string(),
                    0x0a => "\\n".to_string(),
                    0x0d => "\\r".to_string(),
                    0x09 => "\\t".to_string(),
                    n => format!("\\u{:04x}", n),
                };
                out.push_str(&esc);
            }
            c => out.push(c),
        }
    }
    out
}

/// JSONP 拆壳：foo.bar({...}); → {...}
fn strip_jsonp(s: &str) -> &str {
    let open = match s.find('(') {
        Some(i) => i,
        None => return s,
    };
    let head = &s[..open];
    if head.is_empty()
        || !head
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$' || c == '.')
    {
        return s;
    }
    let t = s.trim_end();
    let t = t.strip_suffix(';').map(|x| x.trim_end()).unwrap_or(t);
    if !t.ends_with(')') {
        return s;
    }
    let close = t.len() - 1;
    if close <= open {
        return s;
    }
    &s[open + 1..close]
}

/// 去掉逗号后紧跟 } / ] 的尾逗号
///
/// ★ 必须认字符串状态：早期版本逐字符扫、不认字符串，
/// 字符串里形如 "a,\n}" 的逗号会被误删（真配置里有这种文本）。
fn remove_trailing_commas(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    while i < chars.len() {
        let c = chars[i];
        if in_string {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
            out.push(c);
            i += 1;
            continue;
        }
        if c == '"' {
            in_string = true;
            out.push(c);
            i += 1;
            continue;
        }
        if c == ',' {
            let mut j = i + 1;
            while j < chars.len() && chars[j].is_whitespace() {
                j += 1;
            }
            if j < chars.len() && (chars[j] == '}' || chars[j] == ']') {
                i += 1;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

/// 归一化接口地址 —— ★ 必须剥掉自带查询串
///
/// 实测踩过的坑：TVBox 配置里常见
/// https://api.apibdzy.com/api.php/provide/vod?ac=list，
/// 直接拼 ?ac=videolist&pg=1 会变成 ...vod?ac=list?ac=videolist&pg=1，
/// 站端认不出 → **所有分类都是 0 条**（看起来像「这个源没内容」）。
pub fn normalize_api_url(api: &str) -> String {
    let raw = api.trim();
    if raw.is_empty() {
        return String::new();
    }
    let cut = raw.split(|c| c == '?' || c == '#').next().unwrap_or("");
    cut.trim_end_matches('/').to_string()
}

/// 把相对接口地址按配置来源地址补全（对应 resolveApi）
pub fn resolve_api(api: &str, base_url: &str) -> Option<String> {
    let a = api.trim();
    if a.is_empty() {
        return None;
    }
    if starts_http(a) {
        return Some(a.to_string());
    }
    let (scheme, origin) = split_origin(base_url)?;
    // ★ 协议相对地址：拼 scheme 时**必须保留**原来的两条斜杠
    //   （JS 版是 scheme + 原串；剥掉再拼会得到 "https:b.com/x"）
    if a.starts_with("//") {
        return Some(format!("{scheme}{a}"));
    }
    if a.starts_with('/') {
        return Some(format!("{origin}{a}"));
    }
    let no_query = base_url
        .split(|c| c == '?' || c == '#')
        .next()
        .unwrap_or("");
    match no_query.rfind('/') {
        Some(i) => Some(format!("{}{}", &no_query[..i + 1], a)),
        None => Some(format!("{origin}/{a}")),
    }
}

/// 相对地址补全 —— ★ **纯字符串实现**
///
/// 不能依赖 url crate（依赖树里没有），而且这段逻辑要跟
/// tvbox-convert.mjs 里的 absolutize 逐条对齐（那边是给 QuickJS 用的，
/// 同样不能用 new URL）。
pub fn absolutize(r: &str, base_url: &str) -> String {
    let r = r.trim();
    if r.is_empty() {
        return String::new();
    }
    if starts_http(r) {
        return r.to_string();
    }
    let (scheme, origin) = match split_origin(base_url) {
        Some(x) => x,
        None => return r.to_string(),
    };
    // ★ 同上：协议相对地址要保留 "//"
    if r.starts_with("//") {
        return format!("{scheme}{r}");
    }
    if r.starts_with('/') {
        return format!("{origin}{r}");
    }
    let no_query = base_url
        .split(|c| c == '?' || c == '#')
        .next()
        .unwrap_or("");
    match no_query.rfind('/') {
        Some(i) => format!("{}{}", &no_query[..i + 1], r),
        None => format!("{origin}/{r}"),
    }
}

/// 从网页里挖第一个 m3u8 地址（对应 extractM3u8）
pub fn extract_m3u8(html: &str, page_url: &str) -> Option<String> {
    let chars: Vec<(usize, char)> = html.char_indices().collect();
    let mut k = 0usize;
    while k < chars.len() {
        let (start, c) = chars[k];
        if c == '"' || c == '\'' {
            let mut j = k + 1;
            while j < chars.len() && chars[j].1 != c {
                j += 1;
            }
            if j >= chars.len() {
                return None;
            }
            let inner = &html[start + c.len_utf8()..chars[j].0];
            if inner.contains(".m3u8") {
                return Some(absolutize(inner, page_url));
            }
            k = j + 1;
            continue;
        }
        k += 1;
    }
    None
}

/// 剧集串切分：第1集$http://a.m3u8#第2集$http://b.m3u8
///
/// 返回 (集名, 地址)，只保留 http(s) 的地址（对应 parseEpisodes）。
pub fn parse_episodes(s: &str) -> Vec<(String, String)> {
    s.split('#')
        .filter_map(|part| {
            let (name, url) = match part.find('$') {
                Some(i) => (
                    part[..i].trim().to_string(),
                    part[i + 1..].trim().to_string(),
                ),
                None => (String::new(), part.trim().to_string()),
            };
            if starts_http(&url) {
                Some((name, url))
            } else {
                None
            }
        })
        .collect()
}

fn native_episode_url(id: &str) -> Option<&str> {
    if starts_http(id) { return Some(id); }
    let (line, url) = id.strip_prefix("tvbox-line:")?.split_once(':')?;
    line.parse::<usize>().ok()?;
    starts_http(url).then_some(url)
}

fn is_direct_file_url(url: &str) -> bool {
    let path = url.split(['?', '#']).next().unwrap_or(url).to_ascii_lowercase();
    [".mp4", ".mkv", ".mov", ".avi", ".webm", ".flv", ".m4v"]
        .iter().any(|extension| path.ends_with(extension))
}

/// HTML 实体解码（对应插件模板的 decodeEntities）
///
/// # ★★ 顺序是**实测**定的，不是推理定的：`&amp;` 必须**最后**解
///
/// 直觉是"先解 `&amp;` 免得 `&amp;nbsp;` 被解成 `&nbsp;`" ——
/// **反过来才对**。实测（`.probe/t9_order_test.mjs`，真跑 JS）：
/// ```text
/// 输入 "&amp;nbsp;"
///   · &amp; 最先解 ⇒ 得到 "&nbsp;" ⇒ 后续规则再把它换成空格 ⇒ **" "**   ← 错
///   · &amp; 最后解 ⇒ 得到 "&nbsp;" ⇒ 已经没有后续规则 ⇒ **"&nbsp;"** ← 对
/// ```
/// 即：`&amp;nbsp;` 是"用户**想显示** `&nbsp;` 这 6 个字符"，
/// 所以解码后必须**停**在字面量 `&nbsp;` 上，不能再被当实体解一次。
/// 只有把 `&amp;` 放在最后，其它规则跑完时它还没变成 `&`，
/// 因此**不可能**再触发第二轮替换 —— 这正是"只解一遍"的语义。
///
/// ⚠️ 只解**标准 HTML 实体**，不许顺手改别的字符
///    （例如把 U+00A0 全角空格也当 nbsp 处理 —— 那是**另一件事**，
///     真要处理得由调用方自己决定，见 `strip_tags` 的说明）。
pub fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = s.to_string();
    // ① 具名实体（`&amp;` 除外 —— 见上，它留到最后）
    for (from, to) in [
        ("&nbsp;", " "),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
    ] {
        if out.contains(from) {
            out = out.replace(from, to);
        }
    }
    // ② 数字实体 `&#NNNN;` 与十六进制 `&#xNNNN;`（十进制先做：`&#` 前缀更短）
    out = replace_numeric_entities(&out);
    // ③ `&amp;` **最后**（见上）
    if out.contains("&amp;") {
        out = out.replace("&amp;", "&");
    }
    out
}

/// 解 `&#NNNN;` / `&#xNNNN;` 数字实体（手写扫描，不引正则）
///
/// 无法解析的（超范围 / 空 / 非法码点）**原样保留** ——
/// 与 assrt/bili 的 Dart 实现同语义（那里是 `v == null ? 原样 : 转换`）。
fn replace_numeric_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < bytes.len() {
        // 需要 "&#" 开头，且后面至少有 1 个数字字符 + ";"
        if bytes[i] == '&' && i + 1 < bytes.len() && bytes[i + 1] == '#' {
            let hex = i + 2 < bytes.len() && (bytes[i + 2] == 'x' || bytes[i + 2] == 'X');
            let start = if hex { i + 3 } else { i + 2 };
            let mut j = start;
            while j < bytes.len() && bytes[j].is_ascii_hexdigit() && (hex || bytes[j].is_ascii_digit())
            {
                j += 1;
            }
            if j > start && j < bytes.len() && bytes[j] == ';' {
                let digits: String = bytes[start..j].iter().collect();
                let v = u32::from_str_radix(&digits, if hex { 16 } else { 10 })
                    .ok()
                    .and_then(char::from_u32);
                if let Some(c) = v {
                    out.push(c);
                    i = j + 1;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    out
}

/// 去 HTML 标签（对应 stripTags：/<[^>]+>/g）+ **解 HTML 实体**
///
/// # ★ 为什么要解实体（Owner 实测报的 bug）
///
/// Owner 原话：「右边介绍居然还有 &nbsp; 这种代码」。
/// 根因：本函数原来**只去标签**，一个实体都不解 ——
/// 苹果CMS 的 `vod_content` 里写着 `&nbsp;`，于是详情页简介直接把它
/// 当普通文本显示出来了。
///
/// 上游 TVBox 原版同样不解，转换器模板（`tools/tvbox-convert.mjs` 的
/// `stripTags`）也照抄了 ⇒ 这是**共性**缺陷，三处一起修
/// （本函数、转换器 JS 模板、Dart 详情页兜底）。
pub fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut tag = String::new();
    let mut in_tag = false;
    for ch in s.chars() {
        if in_tag {
            if ch == '>' {
                in_tag = false;
                if tag.is_empty() {
                    // <> 在 JS 正则里不算标签（要求 [^>]+）→ 原样保留
                    out.push('<');
                    out.push('>');
                }
                tag.clear();
            } else {
                tag.push(ch);
            }
            continue;
        }
        if ch == '<' {
            in_tag = true;
            tag.clear();
            continue;
        }
        out.push(ch);
    }
    if in_tag {
        out.push('<');
        out.push_str(&tag);
    }
    // ★ 去完标签**再**解实体（顺序不能反：先解实体会把 `&lt;p&gt;` 解成
    //   真标签 `<p>`，那它就躲过了上面这轮去标签，最后**显示成标签**）
    decode_entities(&out).trim().to_string()
}

/// 由站名/域名生成源 id（对应 toId）
///
/// ★ **绝不返回固定值** —— 第一版写成 || 'src'，结果 4 个中文源
/// 全变成 "src" 互相覆盖，最后只剩一个。
///
/// ```text
/// ① 站名里的 ASCII 字母数字，长度 ≥2 → 小写
/// ② 否则取 api 域名（去 www.）第一段，长度 ≥2 → 小写
/// ③ 兜底 tvbox{index+1}
/// ```
/// CRC-32（IEEE 802.3，与 zlib/crc32 同参数）—— 只用来把名字压成 8 位十六进制
///
/// 为什么自己写 10 行而不是引 crate：`crc32` 这类小功能一旦引依赖，
/// 就要为它背供应链与编译时间；而这里只需要"稳定、够散、跨平台一致"。
fn crc32_ieee(bytes: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for b in bytes {
        crc ^= *b as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

/// csp 源的 id 基串 —— **与配置里的顺序无关**
///
/// # 为什么不能沿用 `to_id`
/// `to_id(name, api, index)` 对 csp 会一路退到 `format!("tvbox{}", index+1)`：
/// ```text
/// ① 名字里的 ASCII 字母数字 → "哔哩｜资源合集" 一个都没有
/// ② host_of(api)            → api 是 "csp_Bili"，没有 http(s):// 前缀
/// ③ 兜底                    → tvbox{配置序号}
/// ```
/// ⇒ 用户在配置里插一条/删一条/改顺序，再导入一次，**id 全变**：
/// 旧源残留 + 收藏/进度对不上（而苹果CMS 有 ② 兜底，不受影响）。
///
/// # 现在的口径
/// ```text
/// csp-<class 小写>-<name 的 crc32 十六进制>
/// 例：csp-bili-3f2a9c41
/// ```
/// 同一份配置里名字不同 ⇒ 不撞；重排 ⇒ **不变**。
/// ⚠️ 名字完全相同（两份 csp_Bili 都叫"哔哩"）仍会撞 ⇒ 交给 `unique_id` 加 `-2`，
///    那种情况下"顺序"是唯一可区分信息，退化是**必然**的，不是本函数的缺陷。
fn csp_id_base(class: &str, name: &str) -> String {
    format!(
        "csp-{}-{:08x}",
        class.to_ascii_lowercase(),
        crc32_ieee(name.as_bytes())
    )
}

/// 一个站点该用哪个 id 基串（按类型分流）
fn id_base_for(job: &SiteJob) -> String {
    match job.csp.as_deref() {
        Some(class) => csp_id_base(class, &job.name),
        None => to_id(&job.name, &job.api, job.index),
    }
}

pub fn to_id(name: &str, api: &str, index: usize) -> String {
    let from_name: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
        .to_lowercase();
    if from_name.len() >= 2 {
        return from_name;
    }
    if let Some(host) = host_of(api) {
        let h = host.strip_prefix("www.").unwrap_or(&host);
        let seg = h.split('.').next().unwrap_or("");
        let from_host: String = seg
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .collect::<String>()
            .to_lowercase();
        if from_host.len() >= 2 {
            return from_host;
        }
    }
    format!("tvbox{}", index + 1)
}

/// 撞名就加 -2 / -3（对应 uniqueId）
pub fn unique_id(base: &str, used: &mut HashSet<String>) -> String {
    if used.insert(base.to_string()) {
        return base.to_string();
    }
    let mut n = 2usize;
    loop {
        let cand = format!("{base}-{n}");
        if used.insert(cand.clone()) {
            return cand;
        }
        n += 1;
    }
}

/// serde_json::Value 取字符串（对应 JS 的 String(x.k)）
fn jstr(v: &serde_json::Value, key: &str) -> String {
    match v.get(key) {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        Some(serde_json::Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn nonempty(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn contains_ci(hay: &str, needle: &str) -> bool {
    hay.to_lowercase().contains(&needle.to_lowercase())
}

// ═══════════════════════════════════════════════════════════════════════
//  配置解析（纯函数，可单测）
// ═══════════════════════════════════════════════════════════════════════

/// 一个待探测的 type=1 站点
#[derive(Debug, Clone)]
pub struct SiteJob {
    /// 在 sites 数组里的下标（决定 id 兜底序号）
    pub index: usize,
    /// sites[] 里的 key —— 更新对比时用来认出「还是同一个站」
    ///
    /// ⚠️ 可能为空（有些配置只写 name）—— 空 key 在 diff_sites 里退化为按 api 配对。
    pub key: String,
    pub name: String,
    pub api: String,
    /// 原始 type（仅用于报告）
    pub kind: Option<i64>,
    /// `type: 3` + `api: csp_Xxx` 且 **Xxx 有 Rust 实现**时的类名（`"Bili"`）
    ///
    /// ```text
    /// None     → 苹果CMS 站点，走 probe_apple_cms 探测
    /// Some("Bili") → csp 源，走 csp::provider::probe_categories 探测
    /// ```
    /// ★ 只有**注册表里真的有实现**才会是 `Some` —— 没实现的类根本不进 jobs
    ///   （见 `collect_sites`：它们直接进 skipped，reason 写「csp_X 尚未实现」）。
    pub csp: Option<String>,
    /// 配置里 `sites[].ext` 的**原样文本**（没有就是空串）
    ///
    /// 本层不解析、不填默认值（见 `crate::csp::ext_text`）。
    pub ext: String,
}

fn site_type(v: &serde_json::Value) -> Option<i64> {
    match v.get("type") {
        Some(serde_json::Value::Number(n)) => n.as_i64(),
        Some(serde_json::Value::String(s)) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

/// 不支持的类型说明（对应 TYPE_DESC）
///
/// # 适用范围（第19项之后收窄了）
/// 这个函数只说**「这种 type 本身就不支持」**，现在只用于：
/// ```text
/// type 3 且 api **不是** csp_ 形态（drpy JS / 需要真 Java 的 jar）
/// type 0 / 1（不该走到这里）/ 4 / 未知 / 未声明
/// ```
/// `type 3 + api: "csp_Xxx"` 走**另一条判据**（查 csp 注册表）：
/// ```text
/// 已实现 → 进 jobs（真发 HTTP）
/// 没实现 → crate::csp::unimplemented_reason() = "csp_Xxx 尚未实现"
/// ```
/// ⚠️ 两条绝不能混：`csp_Xxx` 不能说成「需要 Java 运行时」——
///    那类源的行为我们已经用 Rust 重写了，只是**这一个大类还没写**而已；
///    说成需要 Java 会让用户以为「这台机器装个 Java 就能用」，是不实描述。
pub fn skip_reason(kind: Option<i64>) -> String {
    match kind {
        Some(1) => "苹果CMS（可转换）".to_string(),
        Some(3) => "spider（Java JAR / drpy JS）—— 需要 Java 运行时，本项目不支持".to_string(),
        Some(0) => "纯 JSON API（各家格式不同，需要手工适配）".to_string(),
        Some(4) => "其它（非标准协议）".to_string(),
        Some(n) => format!("未知类型 type={n}"),
        None => "配置未声明 type".to_string(),
    }
}

/// 从配置里提取**可用的**解析服务前缀
///
/// # 只取 `type: 0`
/// `type: 0` 是「URL 前缀式」：`https://jx.example/?url=<页面地址>`，
/// 我们把页面地址拼上去发一次 GET 就能拿回播放地址 —— 纯 HTTP，能做。
///
/// `parses[]` 里的 `type: 3` 是「WebView 式」：需要一个真实浏览器内核去跑
/// 页面里的 JS。本仓没有 WebView，**不假装支持**（静默跳过，不占位）。
///
/// # ⚠️ 这里的 `type: 3` 与 `sites[]` 的 `type: 3` **不是同一件事**
///
/// 两处 type 数字撞车，是 TVBox 配置本身的命名巧合；语义完全不同，
/// 别看到「第19项把 sites 的 type:3 接进来了」就以为这里也该接：
/// ```text
/// parses[].type: 3  = 解析服务（拿一个页面地址 → 换出直链）
///                     形态是「把 url 丢给一个网页播放页」，只能靠浏览器跑
///                     ⇒ 本仓仍然不支持，且**与 csp 注册表毫无关系**
/// sites[].type: 3   = 爬虫源（自带分类/详情/取流的一整套接口）
///                     api 形如 "csp_Xxx" 的，第19项用 Rust 重写后可以真跑
/// ```
/// 换句话说：`csp_Bili` 能播，不代表「WebView 式解析服务」能跑 ——
/// 前者是**我们自己实现了那个类的四个方法**，后者需要别人家的 JS 执行环境。
///
/// # 为什么现在才接
/// `try_parsers` 早就存在，但它只用了编译期常量 `PARSE_SERVICES`（1 个）。
/// 配置里 `parses[]` 声明的东西**从来没被读过** —— 配置作者验证过的解析器
/// 反而没被用上。这个函数补的就是这一跳。
pub fn collect_parsers(cfg: &serde_json::Value) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let Some(arr) = cfg.get("parses").and_then(|v| v.as_array()) else {
        return out;
    };
    for p in arr {
        let t = p.get("type").and_then(|v| v.as_i64());
        if t != Some(0) {
            continue; // parses[] 的 type 3 = WebView 式，本仓无法执行（≠ sites[] 的 type 3）
        }
        let u = jstr(p, "url");
        let u = u.trim();
        if u.is_empty() || !starts_http(u) {
            continue;
        }
        // 去重（配置里常有重复条目）
        if !out.iter().any(|x| x == u) {
            out.push(u.to_string());
        }
    }
    out
}

/// 扫描配置：挑出 type=1 的站点，其余分类归档
///
/// 返回值：(待探测站点, 跳过清单, 直播源清单)
pub fn collect_sites(
    cfg: &serde_json::Value,
    base_url: &str,
) -> (
    Vec<SiteJob>,
    Vec<serde_json::Value>,
    Vec<serde_json::Value>,
) {
    let mut jobs = Vec::new();
    let mut skipped = Vec::new();
    let sites = cfg
        .get("sites")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    for (i, s) in sites.iter().enumerate() {
        let raw_name = {
            let n = jstr(s, "name");
            if n.is_empty() {
                let k = jstr(s, "key");
                if k.is_empty() {
                    "TVBox 源".to_string()
                } else {
                    k
                }
            } else {
                n
            }
        };
        let kind = site_type(s);
        let raw_api = jstr(s, "api");
        let api = if base_url.is_empty() {
            raw_api.clone()
        } else {
            resolve_api(&raw_api, base_url).unwrap_or(raw_api.clone())
        };
        if kind == Some(1) {
            jobs.push(SiteJob {
                index: i,
                key: jstr(s, "key"),
                name: raw_name,
                api,
                kind,
                csp: None,
                ext: crate::csp::ext_text(s.get("ext")),
            });
        } else if kind == Some(3) && crate::csp::is_csp(&raw_api) {
            // ── type:3 + csp_Xxx ────────────────────────────────────────
            //
            // ★ 这里有**三种**结局，必须分清（需求原话：
            //   「没实现的类必须进不支持」）：
            // ```text
            // ① 注册表里有这个类   → 进 jobs，当成可用源（真发 HTTP 探测）
            // ② 注册表里没这个类   → 进 skipped，reason = "csp_X 尚未实现"
            // ③ api 不是 csp_ 形态 → 落到最后的 else（原有的 type:3 文案）
            // ```
            //
            // ⚠️ ② 不能悄悄 continue：静默跳过 = 用户以为「配置里没这个站」。
            //
            // ⚠️ api 必须用**原串**，不能过 `resolve_api`：
            //   `csp_Bili` 不是 URL，按相对地址补全会变成
            //   `https://配置所在域/path/csp_Bili` —— 那是彻底错的地址。
            if crate::csp::is_implemented(&raw_api) {
                jobs.push(SiteJob {
                    index: i,
                    key: jstr(s, "key"),
                    name: raw_name,
                    // 归一化（剥查询串/尾斜杠）保留 `csp_Bili` 原样
                    api: normalize_api_url(&raw_api),
                    kind,
                    csp: crate::csp::class_of(&raw_api).map(|c| c.to_string()),
                    ext: crate::csp::ext_text(s.get("ext")),
                });
            } else {
                skipped.push(serde_json::json!({
                    "name": raw_name,
                    "type": kind,
                    "stage": "type",
                    "reason": crate::csp::unimplemented_reason(&raw_api),
                }));
            }
        } else {
            skipped.push(serde_json::json!({
                "name": raw_name,
                "type": kind,
                "stage": "type",
                "reason": skip_reason(kind),
            }));
        }
    }
    let lives = cfg
        .get("lives")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .map(|l| {
                    serde_json::json!({
                        "name": jstr(l, "name"),
                        "url": jstr(l, "url"),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    (jobs, skipped, lives)
}

// ═══════════════════════════════════════════════════════════════════════
//  探测（联网）
// ═══════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone)]
pub struct ProbeOk {
    pub classes: Vec<TvboxCategoryEntry>,
    pub total: u64,
}

pub fn probe_client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(TVBOX_UA)
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()
        .expect("build tvbox http client")
}

async fn get_text_with(
    client: &reqwest::Client,
    url: &str,
) -> std::result::Result<String, String> {
    let resp = client
        .get(url)
        .header(reqwest::header::USER_AGENT, TVBOX_UA)
        // ★ 必须显式带 Accept（reqwest 默认**不发**这个头）
        //
        // 实测（2026-10-04）：不带 Accept 请求 https://tv.xn--yhqu5zs87a.top 时，
        // 站点返回的是**下载页 HTML**（13.5KB，<title>FongMi - 影视APP - 下载</title>）
        // 而不是同一 URL 的配置 JSON（18.5KB）—— 站点按 Accept 做了内容协商。
        // 表现为「明明在浏览器/其它客户端里是 JSON，我们这边说不是合法 JSON」。
        .header(reqwest::header::ACCEPT, "*/*")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    Ok(text)
}

/// 探测一个苹果CMS接口是否可用（对应 probeAppleCms）
///
/// 两道关：分类接口要能出 class，列表接口要能出 list。
/// 只有都通过才认为可用 —— 只看分类会放进一堆「有分类但没内容」的死站。
pub async fn probe_apple_cms(
    client: &reqwest::Client,
    api: &str,
) -> std::result::Result<ProbeOk, String> {
    let base = normalize_api_url(api);
    if base.is_empty() {
        return Err("接口地址为空".to_string());
    }
    let list_url = format!("{base}?ac=list");
    let text = get_text_with(client, &list_url)
        .await
        .map_err(|e| format!("分类接口 {e}"))?;
    let j = parse_loose_json(&text).map_err(|_| "分类响应不是 JSON".to_string())?;
    let classes: Vec<TvboxCategoryEntry> = j
        .get("class")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|c| {
                    let id = jstr(c, "type_id");
                    if id.is_empty() {
                        return None;
                    }
                    Some(TvboxCategoryEntry {
                        id,
                        name: jstr(c, "type_name"),
                        pid: pid_of(c),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    if classes.is_empty() {
        return Err("分类为空".to_string());
    }

    let video_url = format!("{base}?ac=videolist&pg=1");
    let vtext = get_text_with(client, &video_url)
        .await
        .map_err(|e| format!("列表接口 {e}"))?;
    let vj = parse_loose_json(&vtext).map_err(|_| "列表响应不是 JSON".to_string())?;
    let list = vj
        .get("list")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        return Err("列表为空".to_string());
    }
    let total = vj.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
    Ok(ProbeOk { classes, total })
}

/// 按站点类型选**探测方式** —— 苹果CMS 与 csp 两条路
///
/// # 为什么要收口成一个函数
/// `import_tvbox_config` 与 `update_tvbox_source` 两处都要探测，
/// 探测逻辑如果各写一份，「csp 源在两处行为不同」这类 bug 迟早出现
/// （本仓已经因为两份拷贝漂移踩过一次：见 `collect_parsers` 的注释）。
pub async fn probe_site(
    client: &reqwest::Client,
    job: &SiteJob,
) -> std::result::Result<ProbeOk, String> {
    match job.csp.as_deref() {
        // csp 源：问一次 home()，把**真实分类**拿回来
        Some(class) => {
            log::debug!("探测 csp 源 {}（类 {class}）", job.api.trim());
            let classes = crate::csp::provider::probe_categories(&job.api, &job.ext)
                .await
                .map_err(|e| format!("{} 探测失败：{e}", job.api.trim()))?;
            // total 留 0：csp 源的「条目总数」只有具体分类才有，不在这里编一个
            Ok(ProbeOk { classes, total: 0 })
        }
        None => probe_apple_cms(client, &job.api).await,
    }
}

/// 导入探测失败时，这条站还该不该**照样落盘**？
///
/// # 为什么必须有这条判断（2026-10-29 现场）
/// 用户数据目录里这 5 条一直在报"缺配置"，而**原始订阅里它们的 `ext` 是有的**
/// （真证据：`.probe/ext-real-fragments.json` 逐字抄自 `.probe/ref-subscription.json`）：
/// ```text
/// csp-app99        ext 不是合法 JSON：EOF while parsing a value at line 1 column 0
/// csp-app-get      ext 里缺 dataKey
/// csp-app-rj       ext 里没有站点地址（`url`）
/// csp-hj-zhen-cai  需要 ext 里的站点地址（键 `site`）
/// csp-wogg         需要 ext 里的镜像列表（键 `site`）
/// ```
/// 报错的是 `state.rs` 给每个 csp 类自动建的**内置占位源**（`ext` 恒为空），
/// 而带 `ext` 的那条**从来没落过盘**：
/// ```text
/// ① 导入那一刻该类还没实现 → 进 skipped（"csp_X 尚未实现"）→ 不落盘
/// ② 该类后来实现了 → 没有任何东西会回头重导 → 占位源一直替它报"缺配置"
/// ③ 今天即便重导，只要探测那一下抖动（站点 5xx/超时），本函数之前也会
///    `continue` 把整条丢掉 —— `ext` 就此**真的**丢了，而且报错还说"配置里没有"
/// ```
/// ⇒ 判据：**csp 类 + 配置里带了 ext** ⇒ 生产源（`ext` 就是它的全部配置），
///    探测失败只影响"分类表能不能预先探到"，不影响"这条源存不存在"。
///
/// # 为什么不套用到苹果CMS
/// 苹果CMS 的 api 是配置里唯一的东西，探测失败 = 那个 api 当下就是死的；
/// 落一条死源只会在源列表里留一个点进去必报错的条目（本仓最忌讳的"看起来有"）。
/// csp 源相反：`ext` 是**用户的选择**（站点列表/密钥），一次超时不代表它失效。
///
/// ⚠️ 这是本卡的门禁故障注入点：把它改成恒 `false`，
///    `t_ext_import::probe_failure_still_persists_real_ext` 必须立刻变红。
pub fn keep_ext_on_probe_failure(job: &SiteJob) -> bool {
    job.csp.is_some() && !job.ext.trim().is_empty()
}

/// 按站点类型建 Provider（苹果CMS / csp 的 Rust 实现）
///
/// `id` / 名称 / api 的语义与 `collect_sites` 产出的 [`SiteJob`] 一致；
/// 两个导入路径（首次导入、订阅更新）共用这一份，避免行为漂移。
pub fn build_site_provider(
    id: &str,
    job: &SiteJob,
    ok: &ProbeOk,
    proxy: Option<Arc<crate::proxy::ProxyStore>>,
    parsers: Vec<String>,
) -> std::result::Result<Arc<dyn MediaProvider>, String> {
    match job.csp.as_deref() {
        Some(_) => {
            let p = crate::csp::provider::CspProvider::new(
                id,
                job.name.clone(),
                &job.api,
                &job.ext,
                ok.classes.clone(),
                // ★ 这里就是"从 TVBox 配置导入"的那条路（probe_site/build_site_provider）
                //   ⇒ from_import: true（子站在源列表里藏起来，经 tvbox_agg 聚合使用）
                true,
                // hidden：导入的子站一律藏（经聚合二级页使用）
                true,
            )?;
            Ok(Arc::new(p) as Arc<dyn MediaProvider>)
        }
        None => {
            let p = TvboxAppleCmsProvider::new(id, job.name.clone(), &job.api, ok.classes.clone())?
                .with_parsers(parsers);
            let p = match proxy {
                Some(pr) => p.with_proxy(pr),
                None => p,
            };
            Ok(Arc::new(p) as Arc<dyn MediaProvider>)
        }
    }
}

/// type_pid：null / 0 表示没有父类
fn pid_of(c: &serde_json::Value) -> Option<String> {
    match c.get("type_pid") {
        None | Some(serde_json::Value::Null) => None,
        Some(serde_json::Value::Number(n)) => {
            if n.as_i64() == Some(0) {
                None
            } else {
                Some(n.to_string())
            }
        }
        Some(serde_json::Value::String(s)) => {
            if s.is_empty() || s == "0" {
                None
            } else {
                Some(s.clone())
            }
        }
        _ => None,
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  Provider
// ═══════════════════════════════════════════════════════════════════════

pub struct TvboxAppleCmsProvider {
    manifest: ProviderManifest,
    /// 已归一化的接口地址
    api: String,
    classes: Vec<TvboxCategoryEntry>,
    client: reqwest::Client,
    proxy: Option<Arc<crate::proxy::ProxyStore>>,
    /// 配置里声明的解析服务前缀（TVBox 的 `parses[]` 中 `type: 0` 那些）
    ///
    /// ★ 优先于内置的 [`PARSE_SERVICES`]：那是配置作者**明确选用**的解析器，
    ///   比我们硬编码的那一个更贴合用户拿到的配置。
    ///   内置列表仍然作为兜底（配置没写时才用）。
    ///
    /// 只取 `type: 0`（URL 前缀式）。`type: 3`（WebView 式）本仓无法执行 ——
    /// 那需要真实浏览器内核，不在这里假装支持。
    parsers: Vec<String>,
}

impl TvboxAppleCmsProvider {
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        api: &str,
        classes: Vec<TvboxCategoryEntry>,
    ) -> std::result::Result<Self, String> {
        let id = id.into();
        let name = name.into();
        let api = normalize_api_url(api);
        if id.is_empty() {
            return Err("源 id 为空".to_string());
        }
        if api.is_empty() {
            return Err("接口地址为空".to_string());
        }
        if !starts_http(&api) {
            return Err(format!("接口地址不是 http(s)：{api}"));
        }
        let client = reqwest::Client::builder()
            .user_agent(TVBOX_UA)
            .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
            .build()
            .map_err(|e| format!("HTTP 客户端创建失败：{e}"))?;
        let capabilities = Capabilities {
            vod: true,
            search: true,
            ..Default::default()
        };
        let manifest = ProviderManifest {
            id,
            name,
            version: "1.0.0".to_string(),
            // ★ 与 js / declarative / http 并列的第四种来源类型
            kind: "tvbox".to_string(),
            description: Some(format!("由 TVBox 配置导入（苹果CMS v10）：{api}")),
            icon: None,
            id_prefixes: Vec::new(),
            capabilities,
            cover_headers: vec![("User-Agent".to_string(), TVBOX_UA.to_string())],
            config: Vec::new(),
            api_version: 1,
            theme_color: None,
            working: true,
            broken_reason: None,
            enabled: None,
            // ★ A′：子站被「TVBox 聚合」接管 ⇒ 列表里不展示（路由不变，
            //   收藏/进度/弹幕绑定仍走原子站 id）
            hidden: true,
        };
        Ok(Self {
            manifest,
            api,
            classes,
            client,
            proxy: None,
            parsers: Vec::new(),
        })
    }

    /// ★ 固有方法（**不是** trait 方法）—— 照抄 HttpProvider 的写法
    pub fn with_proxy(mut self, proxy: Arc<crate::proxy::ProxyStore>) -> Self {
        self.proxy = Some(proxy);
        self
    }

    fn http(&self) -> reqwest::Client {
        match self.proxy.as_ref() {
            Some(store) => store
                .client_for(&self.manifest.id, None)
                .unwrap_or_else(|_| self.client.clone()),
            None => self.client.clone(),
        }
    }

    async fn get_text(&self, url: &str) -> Result<String> {
        let resp = self
            .http()
            .get(url)
            .header(reqwest::header::USER_AGENT, TVBOX_UA)
            .send()
            .await
            .map_err(|e| ProviderError::network(format!("请求失败：{e}")))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ProviderError::network(format!("读取响应失败：{e}")))?;
        if !status.is_success() {
            let head: String = text.chars().take(160).collect();
            return Err(ProviderError::network(format!(
                "HTTP {}：{head}",
                status.as_u16()
            )));
        }
        Ok(text)
    }

    async fn get_json(&self, url: &str) -> Result<serde_json::Value> {
        let text = self.get_text(url).await?;
        parse_loose_json(&text)
            .map_err(|e| ProviderError::parse(format!("接口返回的不是 JSON —— {e}")))
    }

    fn to_item(&self, x: &serde_json::Value) -> MediaItem {
        MediaItem {
            id: MediaId::new(&self.manifest.id, jstr(x, "vod_id")),
            title: jstr(x, "vod_name"),
            cover: nonempty(jstr(x, "vod_pic")),
            subtitle: nonempty(jstr(x, "vod_remarks")),
            badges: Vec::new(),
            kind: MediaKind::Movie,
            description: nonempty(strip_tags(&jstr(x, "vod_blurb"))),
        }
    }

    fn items_of(&self, j: &serde_json::Value) -> Vec<MediaItem> {
        j.get("list")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().map(|x| self.to_item(x)).collect())
            .unwrap_or_default()
    }

    fn page_of(&self, j: &serde_json::Value, items: Vec<MediaItem>, page: u32) -> Page<MediaItem> {
        let page_count = j
            .get("pagecount")
            .and_then(|v| v.as_u64())
            .unwrap_or(1)
            .max(1) as u32;
        let total = j.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
        Page {
            items,
            page,
            page_count: Some(page_count),
            total: Some(total),
        }
    }

    /// Referer = 接口地址去掉 /api.php 及其后的部分 + /
    fn referer(&self) -> String {
        match self.api.find("/api.php") {
            Some(i) => format!("{}/", &self.api[..i]),
            None => format!("{}/", self.api.trim_end_matches('/')),
        }
    }

    /// 依次试第三方解析服务（对应 tryParsers）
    ///
    /// ★ 任何一个环节出错都 **continue** 而不是抛出 —— 解析服务挂掉是常态，
    /// 不该让整次播放解析崩在这里。
    /// 挂上配置里声明的解析服务前缀
    ///
    /// 与 `with_proxy` 同一个 builder 风格：不改 `new()` 签名，
    /// 既有调用点零改动。
    pub fn with_parsers(mut self, parsers: Vec<String>) -> Self {
        self.parsers = parsers;
        self
    }

    async fn try_parsers(&self, page_url: &str) -> Option<String> {
        // ★ 先试**配置里**声明的（配置作者明确选用的），再退回内置兜底。
        //   顺序不能反：用户拿到的配置里写过哪个解析器，就说明作者验证过它；
        //   内置那一个是我们的兜底，不该抢在前面。
        if !self.parsers.is_empty() {
            let refs: Vec<&str> = self.parsers.iter().map(|s| s.as_str()).collect();
            if let Some(u) = self.try_parsers_with(page_url, &refs).await {
                return Some(u);
            }
        }
        self.try_parsers_with(page_url, &PARSE_SERVICES).await
    }

    /// 与 [`Self::try_parsers`] 完全相同，只是解析服务前缀由调用方给出。
    ///
    /// ★ 存在的唯一理由：`PARSE_SERVICES` 是编译期常量、指向公网。测试要覆盖
    /// 「解析服务失败就 continue」这条分支，必须能把前缀换成 127.0.0.1 上的假解析服务。
    /// 生产路径只有 `try_parsers` 一个入口，行为与重构前逐字节一致。
    async fn try_parsers_with(&self, page_url: &str, bases: &[&str]) -> Option<String> {
        for base in bases.iter() {
            let u = format!("{}{}", base, urlencoding::encode(page_url));
            let text = match self.get_text(&u).await {
                Ok(t) => t,
                Err(e) => {
                    log::debug!("解析服务 {base} 失败（换下一个）：{}", e.message);
                    continue;
                }
            };
            if text.is_empty() {
                continue;
            }
            let mut found = match parse_loose_json(&text) {
                Ok(j) => json_parse_url(&j),
                Err(_) => first_media_url(&text),
            };
            if found.is_none() {
                // JSON 解析成功但里面没有可用字段时，再从原文里挖一次
                found = first_media_url(&text);
            }
            let f = match found {
                Some(f) if !f.is_empty() => f,
                _ => continue,
            };
            if contains_ci(&f, "error")
                || contains_ci(&f, "placeholder")
                || contains_ci(&f, "default.mp4")
            {
                continue;
            }
            let f = if f.starts_with('/') {
                match split_origin(base) {
                    Some((_, origin)) => format!("{origin}{f}"),
                    None => continue,
                }
            } else {
                f
            };
            if !starts_http(&f) {
                continue;
            }
            return Some(f);
        }
        None
    }
}

/// 从解析服务返回的 JSON 里取地址（对应 j.url || j.m3u8 || j.data?.url ...）
fn json_parse_url(j: &serde_json::Value) -> Option<String> {
    for k in ["url", "m3u8"] {
        if let Some(s) = j.get(k).and_then(|v| v.as_str()) {
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
    }
    if let Some(d) = j.get("data") {
        for k in ["url", "m3u8", "playUrl"] {
            if let Some(s) = d.get(k).and_then(|v| v.as_str()) {
                if !s.is_empty() {
                    return Some(s.to_string());
                }
            }
        }
        if let Some(s) = d.as_str() {
            if starts_http(s) {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// 从文本里挖第一个媒体地址（解析服务返回非 JSON 时的兜底）
fn first_media_url(text: &str) -> Option<String> {
    let mut from = 0usize;
    while from < text.len() {
        let rel = match text[from..].find("http") {
            Some(r) => r,
            None => return None,
        };
        let start = from + rel;
        let rest = &text[start..];
        if rest.starts_with("http://") || rest.starts_with("https://") {
            let end = rest
                .find(|c: char| {
                    c.is_whitespace() || c == '"' || c == '\'' || c == '<' || c == '>' || c == ')'
                })
                .unwrap_or(rest.len());
            let tok = &rest[..end];
            let low = tok.to_lowercase();
            if low.contains(".m3u8") || low.contains(".mp4") || low.contains(".flv") {
                return Some(tok.to_string());
            }
            from = start + end.max(1);
        } else {
            from = start + 4;
        }
    }
    None
}

#[async_trait]
impl MediaProvider for TvboxAppleCmsProvider {
    fn manifest(&self) -> &ProviderManifest {
        &self.manifest
    }

    async fn home(&self) -> Result<Vec<Section>> {
        Ok(self
            .classes
            .iter()
            .take(HOME_SECTIONS)
            .map(|c| Section {
                id: format!("{}-{}", self.manifest.id, c.id),
                title: c.name.clone(),
                source: SectionSource::Category {
                    category_id: c.id.clone(),
                },
                items: Vec::new(),
            })
            .collect())
    }

    async fn categories(&self) -> Result<Vec<Category>> {
        Ok(self
            .classes
            .iter()
            .map(|c| Category {
                id: c.id.clone(),
                name: c.name.clone(),
                children: Vec::new(),
            })
            .collect())
    }

    async fn list(&self, req: ListRequest) -> Result<Page<MediaItem>> {
        let page = if req.page == 0 { 1 } else { req.page };
        let cat = req.category_id.clone();

        // ① 服务端认 t= 就直接用（一次请求搞定）
        let first_url = format!(
            "{}?ac=videolist&t={}&pg={}",
            self.api,
            urlencoding::encode(&cat),
            page
        );
        let first = self.get_json(&first_url).await;
        if let Ok(j) = &first {
            let items = self.items_of(j);
            if !items.is_empty() {
                return Ok(self.page_of(j, items, page));
            }
        } else if let Err(e) = &first {
            log::debug!(
                "TVBox 源 {} 带分类参数取列表失败：{}",
                self.manifest.id, e.message
            );
        }

        // ② 服务端不认 t= → 客户端按分类过滤（两级：子类 type_id / 父类 type_id_1）
        //
        // ★★ 极端兜底**返回空列表**，绝不退回「全站最新」——
        //    那正是「所有分类点进去数据一模一样」这个 bug 的根源。
        let mut picked: Vec<serde_json::Value> = Vec::new();
        let mut scanned = 0u32;
        let mut last_page_count = 1u32;
        let mut scan_err: Option<ProviderError> = None;
        for p in 1..=SCAN_MAX_PAGES {
            if picked.len() >= SCAN_MAX_ITEMS {
                break;
            }
            let u = format!("{}?ac=videolist&pg={}", self.api, p);
            match self.get_json(&u).await {
                Ok(jj) => {
                    scanned = p;
                    last_page_count = jj
                        .get("pagecount")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(1)
                        .max(1) as u32;
                    let list = jj
                        .get("list")
                        .and_then(|v| v.as_array())
                        .cloned()
                        .unwrap_or_default();
                    if list.is_empty() {
                        break;
                    }
                    for it in list {
                        let hit = jstr(&it, "type_id") == cat || jstr(&it, "type_id_1") == cat;
                        if hit
                            && !picked
                                .iter()
                                .any(|x| jstr(x, "vod_id") == jstr(&it, "vod_id"))
                        {
                            picked.push(it);
                        }
                    }
                    if p >= last_page_count {
                        break;
                    }
                }
                Err(e) => {
                    scan_err = Some(e);
                    break;
                }
            }
        }
        if scanned == 0 {
            // 扫描第一页就失败：如实抛出（优先用带 t= 那次的原因）
            if let Err(e) = first {
                return Err(e);
            }
            if let Some(e) = scan_err {
                return Err(e);
            }
        }
        let page_count = ((last_page_count as f64 / scanned.max(1) as f64).ceil() as u32).max(1);
        let items: Vec<MediaItem> = picked.iter().map(|x| self.to_item(x)).collect();
        Ok(Page {
            items,
            page,
            page_count: Some(page_count),
            total: Some(picked.len() as u64),
        })
    }

    async fn search(&self, keyword: &str, page: u32) -> Result<Page<MediaItem>> {
        let page = if page == 0 { 1 } else { page };
        let url = format!(
            "{}?ac=videolist&wd={}&pg={}",
            self.api,
            urlencoding::encode(keyword),
            page
        );
        let j = self.get_json(&url).await?;
        let items = self.items_of(&j);
        Ok(self.page_of(&j, items, page))
    }

    async fn detail(&self, id: &MediaId) -> Result<MediaDetail> {
        let native = id.native.clone();
        let url = format!(
            "{}?ac=videolist&ids={}",
            self.api,
            urlencoding::encode(&native)
        );
        let j = self.get_json(&url).await?;
        let d = j
            .get("list")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .cloned()
            .ok_or_else(|| {
                ProviderError::new(ErrorKind::NotFound, "取不到详情（上游没有返回这个条目）")
            })?;

        // Keep all lines. First-line URL ids remain compatible with saved history;
        // later lines carry an index so even a shared URL has distinct identity.
        let play = jstr(&d, "vod_play_url");
        let from = jstr(&d, "vod_play_from");
        let names: Vec<&str> = from.split("$$$").collect();
        let mut used = HashSet::new();
        let mut episodes = Vec::new();
        for (line, group) in play.split("$$$").enumerate() {
            let raw_name = names.get(line).map(|s| s.trim()).filter(|s| !s.is_empty());
            let mut flag = raw_name.map(str::to_string).unwrap_or_else(|| format!("线路 {}", line + 1));
            if !used.insert(flag.clone()) {
                flag = format!("{flag} ({})", line + 1);
                while !used.insert(flag.clone()) { flag.push('_'); }
            }
            for (index, (name, url)) in parse_episodes(group).into_iter().enumerate() {
                episodes.push(Episode {
                    id: if line == 0 { url } else { format!("tvbox-line:{line}:{url}") },
                    title: if name.is_empty() { format!("第{}集", index + 1) } else { name },
                    order: (episodes.len() + 1) as u32,
                    player_id: None,
                    flag: flag.clone(),
                });
            }
        }

        let vid = {
            let v = jstr(&d, "vod_id");
            if v.is_empty() {
                native.clone()
            } else {
                v
            }
        };
        let desc_src = {
            let c = jstr(&d, "vod_content");
            if c.is_empty() {
                jstr(&d, "vod_blurb")
            } else {
                c
            }
        };
        Ok(MediaDetail {
            id: MediaId::new(&self.manifest.id, vid),
            title: jstr(&d, "vod_name"),
            cover: nonempty(jstr(&d, "vod_pic")),
            description: nonempty(strip_tags(&desc_src)),
            badges: Vec::new(),
            kind: MediaKind::Movie,
            meta: serde_json::Map::new(),
            // ★ 字段名是 title 不是 name
            sources: vec![PlaySource {
                code: "default".to_string(),
                title: self.manifest.name.clone(),
                count: episodes.len() as u32,
                nested: Vec::new(),
            }],
            episodes,
        })
    }

    async fn resolve(&self, id: &MediaId, req: &PlayRequest) -> Result<Vec<StreamCandidate>> {
        /*
         * ★★★ 剧集地址优先于条目 id —— 与 plugins/mod.rs 那处是**同一个 bug**
         *
         * # Owner 报的症状
         * > 播放第二集,实际还是第一集,这是bug
         *
         * # 为什么本模块也要改
         *
         * 本模块是"应用内直接导入 TVBox 配置"走的那条路（Rust 原生 Provider，
         * 不生成 JS 插件，见文件头说明）。它与转换插件**同构**：
         *   · detail() 的首线路 id 是剧集地址，后续线路是 tvbox-line:<序号>:<地址>
         *   · resolve() 原来只认 id.native（条目 id），**忽略 req**
         * ⇒ 无论点第几集，都会掉进下面 ① 分支、取 episodes.first() = 第一集。
         *
         * # 判据与 plugins/mod.rs 保持一致（必须一致，否则两条路行为不同）
         *
         * req.episode_id 是 http(s) URL 或上述带线路序号的 id ⇒ 还原剧集地址；
         * 否则（None / 空 / 纯数字条目 id）⇒ 维持原行为，走 ① 取第一集。
         *
         * ⚠️ 不能无条件信任 episode_id：别的 provider 用这个字段表达别的东西
         *    （如 srca 拿它当 section_id），所以必须校验格式及还原后的 HTTP 地址。
         *    本条只影响"episode_id 明确是 URL"的情形 —— 那种情形下**只有**
         *    tvbox 系（转换插件 / 本模块）会产生，语义无歧义。
         */
        let mut url = match req.episode_id.as_deref().and_then(native_episode_url) {
            Some(ep) => ep.to_string(),
            _ => id.native.clone(),
        };

        // ① 不是 URL → 当成条目 id，去取详情拿第一集
        if !starts_http(&url) {
            let d = self
                .detail(&MediaId::new(&self.manifest.id, url.clone()))
                .await?;
            let first = d.episodes.first().ok_or_else(|| {
                ProviderError::new(ErrorKind::NotFound, "这个条目没有可播放的剧集")
            })?;
            url = first.id.clone();
        }

        // ② 非明确媒体直链 → 先当网页找 m3u8，找不到再上第三方解析
        if !url.to_lowercase().contains(".m3u8") && !is_direct_file_url(&url) {
            let page_url = url.clone();
            let mut found = match self.get_text(&page_url).await {
                Ok(html) => extract_m3u8(&html, &page_url),
                Err(e) => {
                    log::debug!("取播放页失败（继续试解析服务）：{}", e.message);
                    None
                }
            };
            if found.is_none() {
                found = self.try_parsers(&page_url).await;
            }
            match found {
                Some(u) => url = u,
                None => {
                    let msg = "这个源没有可直接播放的地址（可能需要专用解析）";
                    return Err(ProviderError::new(ErrorKind::Unsupported, msg));
                }
            }
        }

        // ③ kind：只有明确的媒体文件才判 mp4，其余一律 hls
        let kind = if is_direct_file_url(&url) {
            StreamKind::Mp4
        } else {
            StreamKind::Hls
        };
        let headers = vec![
            ("User-Agent".to_string(), TVBOX_UA.to_string()),
            ("Referer".to_string(), self.referer()),
        ];
        Ok(vec![StreamCandidate::new(url, kind)
            .with_label(self.manifest.name.clone())
            .with_quality("自动")
            .with_headers(headers)])
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  导入入口
// ═══════════════════════════════════════════════════════════════════════

/// 导入 TVBox 配置
///
/// input 可以是**配置 JSON 文本**，也可以是**配置地址**（http/https）。
///
/// 流程：解析 → 分类（type=1 留，其余归档）→ 并发探测 type=1 站点
/// → 可用的注册成 Provider 并持久化 → 返回导入报告。
/// 把注册过的直播源写进持久化列表
///
/// # 为什么单独一个函数
/// `import_tvbox_config` 有**两条**返回路径（一个点播源都没探测成功时走早返回），
/// 两条都必须落盘 —— 否则"这次能用、重启后消失"是最难查的分裂。
/// 抽成函数而不是复制两遍：复制的那份迟早会漂。
///
/// # 为什么直接写 `third_party` 而不走 `to_persist`
/// `to_persist` 里放的是"探测成功的点播源"，与直播源生命周期无关；
/// 而 m3u 源除了 `{id,name,url}` 没有别的要存，直接写更直白。
/// `persist_from_registry` 只是把当前列表克隆落盘，**不改列表**，
/// 所以这里写进去的条目不会被它覆盖（已核实现）。
fn persist_live_rows(
    state: &crate::state::AppState,
    rows: &[serde_json::Value],
) -> std::result::Result<(), String> {
    if rows.is_empty() {
        return Ok(());
    }
    {
        let mut list = state
            .third_party
            .write()
            .map_err(|_| "第三方源列表被污染".to_string())?;
        for r in rows {
            let id = r.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let name = r.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let url = r.get("url").and_then(|v| v.as_str()).unwrap_or("");
            if id.is_empty() || url.is_empty() {
                continue;
            }
            // 同一地址重复导入 ⇒ 同 id ⇒ 先删旧再推新（幂等）
            list.retain(|x| x.id() != id);
            list.push(crate::model::PersistedProvider::M3uLive {
                id: id.to_string(),
                name: name.to_string(),
                url: url.to_string(),
            });
        }
    }
    crate::commands_provider::persist_from_registry(state)?;
    crate::commands_provider::touch_providers(state);
    Ok(())
}

pub async fn import_tvbox_config(
    state: &crate::state::AppState,
    input: &str,
) -> std::result::Result<serde_json::Value, String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err("TVBox 配置内容为空".to_string());
    }

    // 允许直接贴配置地址
    let (text, base_url) = if starts_http(trimmed) && !trimmed.starts_with('{') {
        let client = probe_client();
        let t = fetch_config_text(&client, trimmed)
            .await
            .map_err(|e| format!("下载配置失败（{trimmed}）：{e}"))?;
        (t, trimmed.to_string())
    } else {
        (trimmed.to_string(), String::new())
    };

    let cfg = parse_loose_json(&text).map_err(|e| format!("配置不是合法 JSON：{e}"))?;

    // 多仓配置：只有 urls，没有 sites
    //
    // ★ task-12 改了这里：原来是直接 Err（把子仓清单塞进错误文案里），
    //   现在是**结构化返回** {multiRepo:true, repos:[...]} —— 界面据此
    //   列出子仓供用户选一个继续导入，而不是让用户自己从一段红字错误里
    //   抠链接。
    //   ```text
    //   旧：弹一个红字错误框，里面是「请打开其中某个子仓…· 名称 链接」
    //   新：正常面板里列出「子仓」清单，每条可点（界面把它的链接填回输入框）
    //   ```
    //   ⚠️ 仍然**不会**把多仓当成可导入的配置（那是假装有能力）——
    //      只是把「转不了」说清楚，并给出下一步能用的东西。
    if cfg.get("sites").and_then(|v| v.as_array()).is_none() {
        let repos = multi_repo_repos(&cfg, &base_url);
        if !repos.is_empty() {
            return Ok(serde_json::json!({
                "totalSites": 0,
                "imported": [],
                "skipped": [],
                "lives": [],
                "multiRepo": true,
                "repos": repos,
            }));
        }
        return Err("配置里没有 sites 段（这可能是直播源配置或空配置）".to_string());
    }

    let (jobs, mut skipped, lives) = collect_sites(&cfg, &base_url);

    // ── 直播源：解析成 provider 并注册（P1'.2b）─────────────────────
    //
    // ★ 必须在 `jobs.is_empty()` 的早返回**之前**做 ——
    //   Owner 给的那份配置里 100 个站点全是 Java（无可用 job），
    //   正好走早返回分支；若把这段放在后面，那份配置的直播源永远进不来。
    //
    // ★ 这里只**注册**，落盘由下面统一处理（早返回与正常路径各一次），
    //   否则重启后列表就丢了。
    let mut live_rows: Vec<serde_json::Value> = Vec::new();
    for l in &lives {
        let lname = l.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let lurl = l.get("url").and_then(|v| v.as_str()).unwrap_or("");
        if lurl.trim().is_empty() {
            continue; // 没有地址的条目无法播放，不注册也不虚报
        }
        let p = crate::providers::m3u_live::M3uLiveProvider::new(lname, lurl);
        let pid = crate::provider::MediaProvider::manifest(&p).id.clone();
        let pname = crate::provider::MediaProvider::manifest(&p).name.clone();
        state.registry.register(Arc::new(p));
        live_rows.push(serde_json::json!({
            "id": pid,
            "name": pname,
            "url": lurl.trim(),
        }));
    }
    if jobs.is_empty() {
        // 即便一个点播源都用不了，直播源也可能可用 ⇒ 必须落盘
        persist_live_rows(state, &live_rows)?;
        return Ok(serde_json::json!({
            "totalSites": cfg.get("sites").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
            "imported": [],
            "skipped": skipped,
            "lives": lives,
            "liveImported": live_rows,
        }));
    }

    // ── 并发探测（保序：结果按下标回填，保证 id 生成稳定）────────────
    let client = probe_client();
    let sem = Arc::new(tokio::sync::Semaphore::new(MAX_PROBE_CONCURRENCY));
    let mut results: Vec<Option<std::result::Result<ProbeOk, String>>> =
        (0..jobs.len()).map(|_| None).collect();
    let mut set = tokio::task::JoinSet::new();
    for (idx, job) in jobs.iter().enumerate() {
        let client = client.clone();
        let sem = sem.clone();
        let job = job.clone();
        set.spawn(async move {
            let _permit = sem.acquire_owned().await;
            (idx, probe_site(&client, &job).await)
        });
    }
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok((idx, r)) => results[idx] = Some(r),
            Err(e) => log::warn!("TVBox 探测任务异常退出：{e}"),
        }
    }

    // ── 生成 Provider 并注册 ────────────────────────────────────────
    //
    // used 预置**已存在的非 tvbox 源 id**：避免 TVBox 源顶掉同名插件；
    // 上一次导入的 tvbox 源不预置 —— 重复导入同一份配置要能原地覆盖。
    let mut used: HashSet<String> = state
        .registry
        .manifests()
        .iter()
        .filter(|m| m.kind != "tvbox")
        .map(|m| m.id.clone())
        .collect();
    let mut imported: Vec<serde_json::Value> = Vec::new();
    let mut to_persist: Vec<crate::model::PersistedProvider> = Vec::new();
    // (源 id, site key, 名称, 接口) —— 只用于落盘订阅来源
    let mut meta_rows: Vec<(String, String, String, String)> = Vec::new();
    for (idx, job) in jobs.iter().enumerate() {
        // ★ 探测失败但"配置还在"的 csp 源：照样往下走（见 keep_ext_on_probe_failure）
        let mut probe_failed: Option<String> = None;
        let ok = match results.get_mut(idx).and_then(|x| x.take()) {
            Some(Ok(ok)) => ok,
            Some(Err(reason)) => {
                /*
                 * ⚠️ **保留的源不进 `skipped`**。
                 *
                 * 两个列表的语义必须泾渭分明（界面直接照搬这两个列表）：
                 * ```text
                 * skipped  = 这次**没**进源列表的（用户不必对它抱期待）
                 * imported = 这次**进了**源列表的（probeFailed 说明"没探通但配置在"）
                 * ```
                 * 同一条站同时出现在两个列表里，界面就会一边说"已导入"一边说
                 * "跳过"，用户无从判断 —— 那是本仓最忌讳的分裂。
                 */
                if !keep_ext_on_probe_failure(job) {
                    skipped.push(serde_json::json!({
                        "name": job.name,
                        "type": job.kind,
                        "stage": "probe",
                        "reason": reason,
                    }));
                    continue;
                }
                probe_failed = Some(reason);
                // 分类留空：运行期 home() 再问，绝不在这里编一个假分类
                ProbeOk {
                    classes: Vec::new(),
                    total: 0,
                }
            }
            None => {
                skipped.push(serde_json::json!({
                    "name": job.name,
                    "type": job.kind,
                    "stage": "probe",
                    "reason": "探测任务异常",
                }));
                continue;
            }
        };
        // ★ csp 源用"与顺序无关"的 id（见 csp_id_base）；其余沿用 to_id
        let id = unique_id(&id_base_for(job), &mut used);
        // ★ 按站点类型建 Provider：csp_Bili 走 Rust 重写实现，其余走苹果CMS
        let provider = build_site_provider(
            &id,
            job,
            &ok,
            Some(state.proxy.clone()),
            collect_parsers(&cfg),
        )
        .map_err(|e| format!("生成源「{}」失败：{e}", job.name))?;
        let manifest = provider.manifest().clone();
        state.registry.register(provider);
        /*
         * ── 落盘：csp 源与苹果CMS 源**一样写**（第19项收口，2026-10-25）────
         *
         * # 为什么现在能写了
         * 之前不写，是因为重启重建只认苹果CMS：
         * ```text
         * PersistedProvider::Tvbox { .. } => TvboxAppleCmsProvider::new(api)
         * api = "csp_Bili" 不是 http 地址 ⇒ 必然失败 ⇒ 写进去也是"重启即失效"
         * ```
         * 现在两件配套都到位了：
         * ```text
         * ① model.rs：Tvbox 增加 ext（csp 的行为参数，旧清单缺省 None 仍可读）
         * ② state.rs：api 形如 csp_X 时走 csp::provider::CspProvider::new
         * ```
         * ⇒ 写它就是**真的持久**，不再是"骗用户重启后还在"。
         */
        to_persist.push(crate::model::PersistedProvider::Tvbox {
            id: id.clone(),
            name: manifest.name.clone(),
            api: normalize_api_url(&job.api),
            categories: ok.classes.clone(),
            parsers: collect_parsers(&cfg),
            // ★ ext 原样保存：csp 源的行为参数（站点列表/口令/分类名覆盖）。
            //   空串 ⇒ None（"配置没写"与"写了空"要能区分）
            ext: {
                let e = job.ext.trim();
                if e.is_empty() { None } else { Some(e.to_string()) }
            },
        });
        imported.push(serde_json::json!({
            "id": id,
            "name": manifest.name,
            "api": normalize_api_url(&job.api),
            "categories": ok.classes.len(),
            "total": ok.total,
            // ★ 供界面/汇报如实显示「这次导入的源重启后还在不在」
            //   csp 源现在也落盘 ⇒ 一律 true（旧值 job.csp.is_none() 已废）
            "persisted": true,
            "kindTag": if job.csp.is_some() { "csp" } else { "appleCms" },
            /*
             * ★ 2026-10-29：`ext` 在、但探测没通的 csp 源**也会**走到这里。
             * 必须把"没探通"和"探通了但 0 个分类"分开说 —— 否则界面把前者
             * 显示成"导入成功、分类 0"，用户点进去看到运行期报错会以为是新 bug。
             */
            "extLen": job.ext.trim().len(),
            "probeFailed": probe_failed,
        }));
        // 记下 (id, site key, 名称, 接口) —— 落盘订阅来源时要用（见下）
        meta_rows.push((
            id.clone(),
            job.key.clone(),
            job.name.clone(),
            normalize_api_url(&job.api),
        ));
    }

    // ── 持久化（重启后自动重建，不需要重新联网探测）──────────────────
    if !to_persist.is_empty() {
        {
            let mut list = state
                .third_party
                .write()
                .map_err(|_| "第三方源列表被污染".to_string())?;
            for p in to_persist {
                let pid = p.id().to_string();
                list.retain(|x| x.id() != pid);
                list.push(p);
            }
        }
        crate::commands_provider::persist_from_registry(state)?;
        // 标记改动时间：云同步据此判断「本地是新的」
        crate::commands_provider::touch_providers(state);
    }
    // 直播源单独落盘（它不走 `to_persist`：那份列表由 persist_from_registry 重建，
    // 而 m3u 源没有 manifest 以外的东西要存，直接写 third_party 更直接）
    persist_live_rows(state, &live_rows)?;

    // ── 记下「这些源是从哪来的」（task-12）───────────────────────────
    //
    // ★ 与插件侧的 plugins/.meta/<id>.json 对称，但有一条**关键区别**：
    //   ```text
    //   插件：没链接 → 什么都不记（也就没有 site key 可言）
    //   TVBox：没链接 → 仍然记 site key / 名称 / 接口，只是 source_url = None
    //   ```
    //   为什么必须记：site key 是**导入那一刻就知道**的事实（来自 sites[]），
    //   与"有没有链接"无关。如果贴文本导入时不记，用户事后用
    //   set_tvbox_source 补上链接，配对就只能退化成按 api 认 ——
    //   而"站换了域名"恰恰是最需要靠 key 认出来的情况。
    //   → 表现为：补完链接后第一次检测，明明只是换了域名，却被报成
    //     「新增一个 + 消失一个」，用户点了更新就会多出一个重复的源。
    //
    // ⚠️ 写 sidecar 失败**不让整次导入失败**（源已经注册好、能用了）——
    //    但必须留日志，不能静默吞掉。
    if !meta_rows.is_empty() {
        let src = if base_url.is_empty() {
            None
        } else {
            Some(base_url.clone())
        };
        /*
         * ★ B3（2026-11-01）：**链接导入成功 ⇒ 盖 installed 时刻的初始章**
         *
         * # 为什么原来那句注释是错的
         * ```text
         * 旧注释：「导入 ≠ 订阅更新：新导入的源如实显示「从未更新」」。
         * 这个**前提只对"贴配置文本导入"成立** —— 那种情况 base_url 为空，
         * 磁盘上确实没有可核对的链接，"从未更新"是实话。
         * 但"填链接导入"时，我们**刚刚从那个链接成功下载并完成安装** ——
         * 这是一次真实的成功核对。把它显示成"从未更新"
         * = **把已发生的事实显示成未发生**（读数说谎，比漏修更糟），
         *   而且用户要等 24h 定时第一轮跑完才第一次看见时间。
         * ```
         * ⇒ 精确口径（覆盖两条导入路径，各自如实）：
         * ```text
         * 文本导入（base_url 空）        ⇒ last_update_at = 0（无可核对链接）
         * 链接导入且下载安装成功（走到这里）⇒ last_update_at = now, ok = true
         * 链接导入但下载/解析失败         ⇒ 压根走不到这里（上面已 return Err）
         * ```
         */
        let initial_stamp = src.is_some();
        let stamp_at = now_secs();
        for (id, key, name, api) in meta_rows.iter() {
            let meta = TvboxSourceMeta {
                source_url: src.clone(),
                site_key: key.clone(),
                site_name: name.clone(),
                api: api.clone(),
                installed_at: stamp_at,
                last_update_at: if initial_stamp { stamp_at } else { 0 },
                last_update_ok: initial_stamp,
                last_update_error: None,
            };
            if let Err(e) = write_tvbox_meta(&state.data_dir, id, &meta) {
                log::warn!("记录 TVBox 订阅来源失败（{id}）：{e}");
            }
        }
    }

    log::info!(
        "TVBox 配置导入完成：{} 个源可用，{} 条跳过，{} 个直播源未导入",
        imported.len(),
        skipped.len(),
        lives.len()
    );
    Ok(serde_json::json!({
        "totalSites": cfg.get("sites").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
        "imported": imported,
        "skipped": skipped,
        "lives": lives,
        "liveImported": live_rows,
        // ★ 保留这个键（Dart 侧 `notPersisted` 已接线），但现在恒为空：
        //   csp 源已落盘 ⇒ 没有任何"重启后需要重新导入"的源。
        "notPersisted": Vec::<String>::new(),
    }))
}

// ═══════════════════════════════════════════════════════════════════════
//  订阅链接 + 检测更新（task-12）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 填入 tvbox 源的链接，然后他有更新我们也能收得到，不至于更新失效了
//
// # 与插件那套（plugins/.meta/<id>.json）同构，只差一处
//
// ```text
// 插件    1 个 .js   ↔ 1 个安装链接 → 一个 id 一个 sidecar 文件
// TVBox   1 份配置   ↔ 1 个订阅链接 → 一份配置产出几十个源
//                                    → sidecar 是单文件 map {id: meta}
// ```
//
// 96 个站点写 96 个文件会把数据目录炸掉，所以这里用单文件 map。
//
// # ★★ 产品原则（与 commands_provider.rs 里插件那套同一条）：没有的能力不假装有
//
// ```text
// 直接贴 JSON 文本导入的源 → 没有链接可查
//   → list_tvbox_sources 里 needsSource = true
//   → 界面不显示「检测更新」按钮，只如实说明「无订阅链接」
//   → 绝不显示成「已是最新」（那是假装查过了）
// ```
//
// 用户可以用 set_tvbox_source 事后补一个链接 —— 与插件侧的
// set_plugin_source 对称，同样是真实功能而不是测试开关。

/// 一个 TVBox 源的「订阅来源」sidecar 条目
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TvboxSourceMeta {
    /// 当初导入它的配置链接（None = 贴文本导入的，没有源可查）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url: Option<String>,
    /// 站点在配置 sites[] 里的 key —— 更新时用来认出「还是同一个站」
    #[serde(default)]
    pub site_key: String,
    #[serde(default)]
    pub site_name: String,
    /// 导入时的接口地址（已归一化）
    #[serde(default)]
    pub api: String,
    /// Unix 秒
    #[serde(default)]
    pub installed_at: i64,
    /// ★ 上次订阅更新的时间（Unix 秒）
    ///
    /// # 三态（界面据此如实显示，不许合并）
    /// ```text
    /// 0     = 从未更新过 ⇒ 界面如实「从未更新」
    ///        · 且**必须区分两种"0"**（本批真机判读打回的根因）：
    ///          (a) 有订阅链接、只是还没轮到/没成功 ⇒ 等更新跑一次就有数
    ///          (b) 压根没有订阅链接（贴文本导入）   ⇒ 永远不会自动更新，
    ///              界面要如实报原因 + 指出路（去聚合页补链接）
    ///          ⇒ 判据看 `source_url`：None 是 (b)，Some 是 (a)
    /// >0    = 上次核对的时刻（成功与否看 `last_update_ok`）
    /// ```
    ///
    /// 成功的判定覆盖 `update_tvbox_source` 的**两条**出口：
    /// 远端有变化并应用、以及「远端与本地一致无需更新」（后者也是一次成功的核对，
    /// 不盖章的话定时器会把同一条链接判成永远超期、每轮重复下载）。
    #[serde(default)]
    pub last_update_at: i64,
    /// 上次更新是否成功（`last_update_at > 0 && !ok` = 上次失败，原因见 error）
    #[serde(default)]
    pub last_update_ok: bool,
    /// 上次失败的原因（成功 / 从未更新为 None；Dart 界面据此显示失败行）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_update_error: Option<String>,
}

/// sidecar 的磁盘形态（带版本号，将来能迁移）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct TvboxMetaFile {
    #[serde(default = "tvbox_meta_version")]
    version: u32,
    #[serde(default)]
    sources: std::collections::HashMap<String, TvboxSourceMeta>,
}

/// 订阅来源 sidecar 的**写锁**（★ P2-2：五条写路径共用同一把）
///
/// # 为什么锁在**最底层**而不是逐个入口加
///
/// ```text
/// 写 sidecar 的入口有五条：import / set_tvbox_source / remove /
/// restore_tvbox_js / update（盖章）。
/// 它们最终都走同一个形状：load 整份 map → 改一条 → save 整份（rename）。
/// ⇒ 只给 update 那一条加锁（本批 T5 初版就是这么做的）等于没加：
///   用户点"导入"的同时定时器在盖章，两边各自读到旧整份、各自写回
///   ⇒ 后写的那份**整份覆盖**先写的 ⇒ 先写那次改动凭空消失
///   （表现为"刚导入的源，重启后订阅链接没了"）。
/// ⇒ 锁必须建在「load→改→save」这个**临界区**上，五条路径一次性全覆盖。
/// ```
///
/// # 为什么用 `std::sync::Mutex` 而不是 tokio 的
///
/// 临界区内没有 `.await`（全是文件读写），持 std 锁不会阻塞线程池。
/// tokio 那把 `UPDATE_LOCK` 管的是另一件事（同一条链接别并发下载），二者并存。
static TVBOX_META_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 订阅链接的**归一形态**（★ P3-2：三处匹配必须用同一个形状）
///
/// # 为什么必须有它
///
/// ```text
/// 用户从网页/聊天窗口复制出来的链接常带前后空白或换行（" http://x/a.json\n"）。
/// 写入侧（set_tvbox_source）存的是 trim **后**的值，
/// 而 stamp 的匹配曾经写的是 `m.source_url.as_deref() == Some(url)`（URL 原样），
/// collect_due_links 传进来的又是 trim 后的值 ——
/// ⇒ 三处形状不一致时，"刚补完链接、立即更新"会盖不上章
///   （表现为界面永远停在「从未更新」，而定时器还每 60s 重复下载一次）。
/// ```
///
/// ⚠ 空串归一成 None：sidecar 里"没有链接"只有一种形态（键不存在），
///    不许同时存在 `Some("")` 这种第二种形态 —— 两种形态必然漏判一处。
pub fn norm_source_url(u: Option<&str>) -> Option<String> {
    let s = u?.trim();
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

fn tvbox_meta_version() -> u32 {
    1
}

/// `<data_dir>/tvbox-sources.json`
pub fn tvbox_meta_file(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join("tvbox-sources.json")
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 读全部订阅来源
///
/// # 容错（与 plugins 的 read_plugin_meta 同一条）
///
/// ```text
/// 文件不存在  → 空 map（从没导入过的正常状态，不是错误）
/// JSON 坏了   → 空 map + 警告日志（不能因为一个坏文件就让设置页打不开）
/// ```
///
/// ⚠️ 一律不返回 Err：调用方要能无条件列出全部 TVBox 源，
///    缺 sidecar 只是「查不了更新」，不该让整个列表失败。
pub fn load_tvbox_metas(
    dir: &std::path::Path,
) -> std::collections::HashMap<String, TvboxSourceMeta> {
    let p = tvbox_meta_file(dir);
    let Ok(raw) = std::fs::read_to_string(&p) else {
        return std::collections::HashMap::new();
    };
    match serde_json::from_str::<TvboxMetaFile>(&raw) {
        Ok(m) => m.sources,
        Err(e) => {
            log::warn!("TVBox 订阅 sidecar 解析失败（忽略，当作没有链接）: {p:?}: {e}");
            std::collections::HashMap::new()
        }
    }
}

/// 读某个源的订阅来源（没有 → None，不是错误）
pub fn read_tvbox_meta(dir: &std::path::Path, id: &str) -> Option<TvboxSourceMeta> {
    load_tvbox_metas(dir).remove(id)
}

/// 原子写回整份 map（先写 .tmp 再 rename —— 与 persist::save_persisted 同一手法）
///
/// ⚠ 调用方必须已持有 `TVBOX_META_LOCK`（见该锁的注释：五条写路径共用）。
fn save_tvbox_metas(
    dir: &std::path::Path,
    map: &std::collections::HashMap<String, TvboxSourceMeta>,
) -> std::result::Result<(), String> {
    let p = tvbox_meta_file(dir);
    let tmp = p.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(&TvboxMetaFile {
        version: tvbox_meta_version(),
        sources: map.clone(),
    })
    .map_err(|e| format!("序列化订阅 sidecar 失败: {e}"))?;
    std::fs::write(&tmp, body).map_err(|e| format!("写入订阅 sidecar 临时文件失败: {e}"))?;
    std::fs::rename(&tmp, &p).map_err(|e| format!("替换订阅 sidecar 失败: {e}"))
}

/// 写/覆盖某个源的订阅来源（自动建目录）
///
/// ★ P2-2：整段「load → insert → save」在 `TVBOX_META_LOCK` 里完成。
/// ★ P3-2：链接**存进去之前**就归一（trim）⇒ 磁盘上只有一种形态，
///         从源头消灭"写入是 A 形态、匹配是 B 形态"的缝隙。
pub fn write_tvbox_meta(
    dir: &std::path::Path,
    id: &str,
    meta: &TvboxSourceMeta,
) -> std::result::Result<(), String> {
    if id.is_empty() {
        return Err("源 id 为空，无法记录订阅链接".to_string());
    }
    let _guard = TVBOX_META_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let mut meta = meta.clone();
    meta.source_url = norm_source_url(meta.source_url.as_deref());
    std::fs::create_dir_all(dir).map_err(|e| format!("创建数据目录失败: {e}"))?;
    let mut map = load_tvbox_metas(dir);
    map.insert(id.to_string(), meta);
    save_tvbox_metas(dir, &map)
}

/// 忘掉某个源的订阅来源（源被移除时调用）
///
/// ⚠️ 幂等：没有这个 id / 文件不存在都算成功 —— 调用方不该为此写错误处理。
/// ★ P2-2：同样在 `TVBOX_META_LOCK` 里。
pub fn forget_tvbox_meta(dir: &std::path::Path, id: &str) -> std::result::Result<(), String> {
    let _guard = TVBOX_META_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let mut map = load_tvbox_metas(dir);
    if map.remove(id).is_none() {
        return Ok(());
    }
    save_tvbox_metas(dir, &map)
}

// ═══════════════════════════════════════════════════════════════════════
//  订阅定时自动更新（T5：Owner「源里面没显示上次更新时间…定时更新」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 复用而非重写
//
// 到点之后做的就是**既有的** `update_tvbox_source`（apply_new=true,
// delete_missing=false —— 与手动一键更新同一组保守默认值）。
// 本节只补三件事：配置落盘、到点判定、后台循环。

/// 订阅自动更新配置（`<data_dir>/tvbox-update-schedule.json`）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TvboxUpdateSchedule {
    /// 总开关（Owner 要的是「定时更新」，默认**开** —— 关掉是他明确动作才算数）
    pub enabled: bool,
    /// 间隔秒数（默认 24h；合法档位 6h/12h/24h —— 白名单在 `tvbox_update_schedule_set`）
    pub interval_secs: i64,
}

impl Default for TvboxUpdateSchedule {
    fn default() -> Self {
        Self {
            enabled: true,
            interval_secs: 86_400,
        }
    }
}

fn tvbox_update_schedule_file(dir: &std::path::Path) -> std::path::PathBuf {
    dir.join("tvbox-update-schedule.json")
}

/// 读自动更新配置（文件不存在 / 坏了 ⇒ 默认值，不让设置页打不开）
pub fn load_tvbox_update_schedule(dir: &std::path::Path) -> TvboxUpdateSchedule {
    let p = tvbox_update_schedule_file(dir);
    let Ok(raw) = std::fs::read_to_string(&p) else {
        return TvboxUpdateSchedule::default();
    };
    match serde_json::from_str(&raw) {
        Ok(s) => s,
        Err(e) => {
            log::warn!("订阅自动更新配置解析失败（按默认值处理）: {p:?}: {e}");
            TvboxUpdateSchedule::default()
        }
    }
}

/// 写自动更新配置（原子写，与 sidecar 同一手法）
pub fn save_tvbox_update_schedule(
    dir: &std::path::Path,
    sched: &TvboxUpdateSchedule,
) -> std::result::Result<(), String> {
    let p = tvbox_update_schedule_file(dir);
    let tmp = p.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(sched)
        .map_err(|e| format!("序列化订阅自动更新配置失败: {e}"))?;
    std::fs::write(&tmp, body).map_err(|e| format!("写入订阅自动更新配置失败: {e}"))?;
    std::fs::rename(&tmp, &p).map_err(|e| format!("替换订阅自动更新配置失败: {e}"))
}

/// ★ 到点判定（**纯函数** —— 门禁钉的就是它）
///
/// ```text
/// 从未更新过（at ≤ 0）      ⇒ 到点（冷启动补一次，正是 Owner 要的）
/// 距上次 ≥ interval         ⇒ 到点
/// 其余（含禁用 / interval≤0）⇒ 不到点
/// ```
pub fn tvbox_update_due(last_update_at: i64, interval_secs: i64, now: i64, enabled: bool) -> bool {
    if !enabled || interval_secs <= 0 {
        return false;
    }
    if last_update_at <= 0 {
        return true;
    }
    now >= last_update_at.saturating_add(interval_secs)
}

/// 从本地源清单里挑出到点要更新的**链接**（**纯函数**，返回 `(url, 代表源 id)`）
///
/// # 为什么按链接去重
///
/// 一份配置产出几十个源共用一个链接；`update_tvbox_source` 对任一代表源
/// 调用一次就会核对整条链接并给全部 in_link 源盖章（见 `stamp_link_update`）
/// ⇒ 每条链接只挑**第一个**到点的源当代表，绝不重复下载。
pub fn collect_due_links(
    sources: &[(String, String, String, Option<String>)],
    metas: &std::collections::HashMap<String, TvboxSourceMeta>,
    enabled: bool,
    interval_secs: i64,
    now: i64,
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for (id, _name, _api, _ext) in sources.iter() {
        let Some(m) = metas.get(id) else { continue };
        // ★ P3-2：与 stamp / in_link 同一把尺子（三处只能有一个判据）
        let Some(url) = norm_source_url(m.source_url.as_deref()) else {
            continue;
        };
        if out.iter().any(|(u, _)| u == &url) {
            continue;
        }
        if tvbox_update_due(m.last_update_at, interval_secs, now, enabled) {
            out.push((url.to_string(), id.clone()));
        }
    }
    out
}

/// 后台循环：每 60s 醒一次，把到点的订阅链接各更新一次
///
/// ```text
/// · 首轮先等 60s：避开启动恢复风暴，但仍是「冷启动超期即补一次」
/// · 每轮重新读配置 ⇒ 用户改开关/间隔最迟 60s 生效，不用重启
/// · 失败只 warn（update_tvbox_source 已盖章 + 落日志），绝不 panic ——
///   定时任务崩了比不跑更糟
/// ```
pub fn spawn_auto_update(state: &std::sync::Arc<crate::state::AppState>) {
    let st = state.clone();
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(60));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
        loop {
            ticker.tick().await;
            let sched = load_tvbox_update_schedule(&st.data_dir);
            let sources = match local_tvbox_sources(&st) {
                Ok(s) => s,
                Err(e) => {
                    log::warn!("TVBox 定时更新：列本地源失败（本轮跳过）: {e}");
                    continue;
                }
            };
            if sources.is_empty() {
                continue;
            }
            let metas = load_tvbox_metas(&st.data_dir);
            let due =
                collect_due_links(&sources, &metas, sched.enabled, sched.interval_secs, now_secs());
            for (url, rep) in due {
                log::info!("TVBox 订阅定时更新开始：{url}（代表源 {rep}）");
                match update_tvbox_source(&st, &rep, true, false).await {
                    Ok(_) => log::info!("TVBox 订阅定时更新完成：{url}"),
                    Err(e) => log::warn!("TVBox 订阅定时更新失败（已保留旧配置）：{e}"),
                }
            }
        }
    });
}

/// 读自动更新配置（FFI：设置页的开关 + 间隔）
pub fn tvbox_update_schedule_get(
    state: &crate::state::AppState,
) -> std::result::Result<serde_json::Value, String> {
    let s = load_tvbox_update_schedule(&state.data_dir);
    Ok(serde_json::json!({
        "enabled": s.enabled,
        "intervalSecs": s.interval_secs,
    }))
}

/// 写自动更新配置（FFI：设置页的开关 + 间隔）
///
/// # ★ 档位白名单（互检 P3-1）
///
/// ```text
/// 只收 6h / 12h / 24h 三档（「关」由 enabled=false 表达，不占间隔档位）。
/// 其它值一律拒绝 —— 防手改配置文件或直调 FFI 塞个 60 秒上来，
/// 把订阅更新变成"每分钟下载一次"（那是对上游的攻击，也是对自己流量的浪费）。
/// ```
pub fn tvbox_update_schedule_set(
    state: &crate::state::AppState,
    enabled: bool,
    interval_secs: i64,
) -> std::result::Result<serde_json::Value, String> {
    const ALLOWED: [i64; 3] = [21_600, 43_200, 86_400];
    if !ALLOWED.contains(&interval_secs) {
        return Err(format!(
            "订阅自动更新的间隔只支持 6 小时 / 12 小时 / 24 小时（收到 {interval_secs} 秒）"
        ));
    }
    let sched = TvboxUpdateSchedule {
        enabled,
        interval_secs,
    };
    save_tvbox_update_schedule(&state.data_dir, &sched)?;
    Ok(serde_json::json!({
        "enabled": sched.enabled,
        "intervalSecs": sched.interval_secs,
    }))
}

// ── 远端 vs 本地的站点差异 ─────────────────────────────────────────────

/// 远端配置里的一个可转换站点（type=1）
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteSite {
    pub key: String,
    pub name: String,
    pub api: String,
    /// 配置里的 `sites[].ext` 归一文本（没有 ⇒ None）
    ///
    /// ★ 参与 diff：csp 源的行为参数（站点列表/口令/分类名覆盖）全在 ext 里。
    ///   不比它 ⇒ 用户改了 ext，检测更新会答"远端与本地一致，无需更新"。
    pub ext: Option<String>,
}

/// 本地已注册的 TVBox 源（对比用）
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalSite {
    pub id: String,
    pub key: String,
    pub name: String,
    pub api: String,
    /// 已落盘记录里的 ext（`PersistedProvider::Tvbox.ext`）
    pub ext: Option<String>,
    /// 这个源是不是**当前这份订阅**导入的
    ///
    /// # ★ 为什么必须有这个标记（真实场景）
    ///
    /// 两份配置里有同一个站是常态（互相抄）。如果配对池只用"本订阅的源"：
    /// ```text
    /// 远端 A 里有「非凡」 → 本地已有（来自订阅 B）
    /// → 报成 added → 一键更新又注册一个一模一样的源
    /// → 用户看到两张「非凡」卡片
    /// ```
    /// 所以配对池要用**全部** TVBox 源。但反过来，"远端没有的站"只有在
    /// 它**属于本订阅**时才算 removed —— 否则订阅 A 的检测会把订阅 B
    /// 的源全报成"已消失"，用户一勾删除就误删。
    ///
    /// → 配对认全量，报 removed / 应用 changed 只认本订阅（in_link）。
    #[serde(skip_serializing)]
    pub in_link: bool,
}

/// 同一个站点但内容变了
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SiteChange {
    pub id: String,
    pub key: String,
    pub old_name: String,
    pub new_name: String,
    pub old_api: String,
    pub new_api: String,
}

/// 远端 vs 本地的差异
///
/// ⚠️ 不 derive Serialize：带下标（`*_idx`）的内部结构，对外由调用方自己组 JSON。
#[derive(Debug, Clone, Default)]
pub struct SiteDiff {
    /// 远端新增（本地没有）
    pub added: Vec<RemoteSite>,
    /// `added[i]` 在远端站点列表里的下标（探测要用）
    pub added_idx: Vec<usize>,
    /// 远端消失（本地还有）—— ★ 只报告，绝不自动删
    pub removed: Vec<LocalSite>,
    /// 同一个站但接口/名字变了
    pub changed: Vec<SiteChange>,
    /// `changed[i]` 在远端站点列表里的下标
    pub changed_idx: Vec<usize>,
    /// 完全没变的条数（**只算本订阅的**）
    pub unchanged: usize,
    /// 被认出来、但属于**别的订阅**的站（不算本订阅的 unchanged）
    pub unchanged_foreign: usize,
}

/// 对比远端站点列表与本地已注册的源（纯函数，可单测）
///
/// # 配对规则（顺序不能换）
///
/// ```text
/// ① 先按 site key 精确配对   —— 站改名/换域名时仍能认出「还是同一个站」
/// ② 剩下的按归一化 api 配对   —— 老数据没有 key 时的兜底
/// ③ 剩下 = 新增 / 消失
/// ```
///
/// ⚠️ api 比对用 normalize_api_url（剥 ? / # 、去尾斜杠）——
///    配置里常见 .../vod?ac=list 与 .../vod 混用，
///    不归一化会把同一个站报成「新增 + 消失」。
pub fn diff_sites(local: &[LocalSite], remote: &[RemoteSite]) -> SiteDiff {
    let mut used_remote = vec![false; remote.len()];
    let mut used_local = vec![false; local.len()];
    let mut diff = SiteDiff::default();

    // ① 按 key 配对
    for (li, l) in local.iter().enumerate() {
        if l.key.is_empty() {
            continue;
        }
        for (ri, r) in remote.iter().enumerate() {
            if used_remote[ri] || r.key != l.key {
                continue;
            }
            used_local[li] = true;
            used_remote[ri] = true;
            // 别的订阅导入的同名站：认出来（不再重复注册）但**不动它**
            if !l.in_link {
                diff.unchanged_foreign += 1;
                break;
            }
            /*
             * ★ ext 也要比：csp 源的"站点列表/口令/分类名覆盖"全在 ext 里，
             *   不比它 ⇒ 用户改了 ext 却得到"无需更新"（第 19 项收口的缺口）。
             *   归一：空白当 None，其余 trim 后逐字比（不做语义解析）。
             */
            let ext_of = |e: &Option<String>| -> Option<String> {
                e.as_deref()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
            };
            if normalize_api_url(&r.api) != normalize_api_url(&l.api)
                || r.name != l.name
                || ext_of(&r.ext) != ext_of(&l.ext)
            {
                diff.changed.push(SiteChange {
                    id: l.id.clone(),
                    key: l.key.clone(),
                    old_name: l.name.clone(),
                    new_name: r.name.clone(),
                    old_api: l.api.clone(),
                    new_api: r.api.clone(),
                });
                diff.changed_idx.push(ri);
            } else {
                diff.unchanged += 1;
            }
            break;
        }
    }

    // ② 剩下的按归一化 api 配对（老数据没有 site key）
    for (li, l) in local.iter().enumerate() {
        if used_local[li] {
            continue;
        }
        let la = normalize_api_url(&l.api);
        if la.is_empty() {
            continue;
        }
        for (ri, r) in remote.iter().enumerate() {
            if used_remote[ri] || normalize_api_url(&r.api) != la {
                continue;
            }
            used_local[li] = true;
            used_remote[ri] = true;
            // 命中即算没变化（别的订阅的站同样不动）
            if l.in_link {
                diff.unchanged += 1;
            } else {
                diff.unchanged_foreign += 1;
            }
            break;
        }
    }

    // ③ 剩下的就是新增 / 消失
    for (ri, r) in remote.iter().enumerate() {
        if !used_remote[ri] {
            diff.added.push(r.clone());
            diff.added_idx.push(ri);
        }
    }
    for (li, l) in local.iter().enumerate() {
        // ★ 只有**本订阅**的源才可能算"远端已消失"——
        //   否则订阅 A 的检测会把订阅 B 的源全报成消失。
        if !used_local[li] && l.in_link {
            diff.removed.push(l.clone());
        }
    }
    diff
}

/// 从一份（可能是多仓的）配置里取子仓列表 —— 纯函数
///
/// `urls` 在野外有两种形态：对象数组 `{name,url}` 与纯字符串数组。
/// 两种都收，相对地址按 `base_url` 补全。
pub fn multi_repo_repos(cfg: &serde_json::Value, base_url: &str) -> Vec<serde_json::Value> {
    let Some(arr) = cfg.get("urls").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for u in arr.iter().take(50) {
        let (name, url) = match u {
            serde_json::Value::String(s) => (String::new(), s.clone()),
            other => (jstr(other, "name"), jstr(other, "url")),
        };
        if url.trim().is_empty() {
            continue;
        }
        let abs = if base_url.is_empty() {
            url.trim().to_string()
        } else {
            absolutize(&url, base_url)
        };
        out.push(serde_json::json!({
            "name": if name.trim().is_empty() { abs.clone() } else { name.trim().to_string() },
            "url": abs,
        }));
    }
    out
}

/// ★ A1：聚合源（`tvbox_agg`）的「上次更新」= 其所含子站章的**聚合**
///
/// # 为什么聚合源自己没有章，却必须显示一个真实时间
///
/// ```text
/// tvbox_agg 是 Rust **内置 provider**（state.rs 的 bootstrap 里直接 register），
/// 不是 PersistedProvider::Tvbox ⇒ 不在 third_party ⇒ local_tvbox_sources 挑不到它
/// ⇒ sidecar 里也没有它这一条 ⇒ 没有任何路径会给它盖章。
/// 而它恰恰是用户在一级列表里**唯一看得见**的那条 TVBox 卡片 ——
/// Owner 要的「源里面显示上次更新时间」首先指的就是这一条。
/// ⇒ 它的时间只能从"它实际由哪些子站构成"推导出来，不能凭空造。
/// ```
///
/// # 三个口径（都是"如实"取向，不是取巧）
///
/// ```text
/// 时间  = 子站章的 **max**（最近一次真核对过的时刻）
///         · 不用 min：一条老源会把整个聚合拖成很旧 —— 那是误导，等于说谎
///         · 不用"平均值"：那是一个从来没有发生过的时刻
/// ok    = 全部**已盖章**子站都成功才 true
///         · 任一子站上次失败 ⇒ 整条聚合标失败 ——
///           定时更新一直在失败这件事，用户必须能一眼看见（硬要求）
/// error = 第一个失败子站的原因（原样，不改写）
/// ```
///
/// # 返回 `None` 的两种情形（都不许显示成"从未更新"以外的假象）
///
/// ```text
/// · 一个子站章都没有（全部从未更新）⇒ None ⇒ 界面显示「从未更新」
/// · 传入的子站集为空（聚合里没有任何 TVBox 子站）⇒ None
/// ```
///
/// ⚠️ **纯函数**（不读文件、不联网）—— 门禁可以直接穷举。
pub fn tvbox_aggregate_last_update(
    metas: &std::collections::HashMap<String, TvboxSourceMeta>,
    child_ids: &[String],
) -> Option<(i64, bool, Option<String>)> {
    let mut at = 0i64;
    let mut ok = true;
    let mut err: Option<String> = None;
    let mut any = false;
    for id in child_ids {
        let Some(m) = metas.get(id) else { continue };
        if m.last_update_at <= 0 {
            continue; // 还没盖过章的子站不参与（它自己也是"从未更新"）
        }
        any = true;
        if m.last_update_at > at {
            at = m.last_update_at;
        }
        if !m.last_update_ok && err.is_none() {
            err = m.last_update_error.clone().or(Some("更新失败（后端没有给出原因）".to_string()));
        }
        if !m.last_update_ok {
            ok = false;
        }
    }
    if !any {
        return None;
    }
    Some((at, ok, err))
}

/// 从本地已注册的源里挑出 TVBox 源（id / name / api）
fn local_tvbox_sources(
    state: &crate::state::AppState,
) -> std::result::Result<Vec<(String, String, String, Option<String>)>, String> {
    let list = state
        .third_party
        .read()
        .map_err(|_| "第三方源列表被污染（锁中毒）".to_string())?
        .clone();
    let mut out = Vec::new();
    for p in list.iter() {
        // ★ 带上 ext：diff 要用它判断"远端改了 ext"（否则会答"无需更新"）
        if let crate::model::PersistedProvider::Tvbox {
            id, name, api, ext, ..
        } = p
        {
            out.push((id.clone(), name.clone(), api.clone(), ext.clone()));
        }
    }
    Ok(out)
}

/// 列出全部 TVBox 源 + 它们有没有订阅链接（纯本地读，零网络）
///
/// # ★ 为什么必须是独立命令（与插件侧 list_plugin_sources 同一个理由）
///
/// ```text
/// 界面要在打开设置页时就知道「哪张卡该显示检测更新按钮」。
/// 若用 check_tvbox_updates 来判断 → 打开设置页会对每个订阅链接发一次 HTTP
/// → 页面要等几秒、还可能被 CDN 限流。
/// ```
pub fn list_tvbox_sources(
    state: &crate::state::AppState,
) -> std::result::Result<serde_json::Value, String> {
    let sources = local_tvbox_sources(state)?;
    let metas = load_tvbox_metas(&state.data_dir);
    /*
     * ★ A2：聚合源的时间从"它实际由哪些子站构成"推导 ——
     *   子站集 = 本地 TVBox 源 ∩ sidecar 里有记录的
     *   （与 tvbox_aggregate::channels_of 判"用户导入"用的是同一份 provenance：
     *     sidecar 存在性 —— 同一件事在本仓只有一个判据）。
     *   内置 csp 源若从未导入过（没有 sidecar）就不算它的子站，
     *   否则一条没章的内置源会把聚合永远拖成"从未更新"。
     */
    let child_ids: Vec<String> = sources
        .iter()
        .map(|(id, _, _, _)| id.clone())
        .filter(|id| metas.contains_key(id))
        .collect();
    let agg = tvbox_aggregate_last_update(&metas, &child_ids);
    let mut out = Vec::new();
    let mut with_source = 0usize;
    for (id, name, api, _ext) in sources.iter() {
        let meta = metas.get(id);
        // ★ P3-2：对外也只有一种形态（写入侧已归一，这里是双保险 + 空串当没有）
        let url = norm_source_url(meta.and_then(|m| m.source_url.as_deref()));
        if url.is_some() {
            with_source += 1;
        }
        out.push(serde_json::json!({
            "id": id,
            "name": name,
            "api": api,
            "sourceUrl": url,
            "needsSource": url.is_none(),
            "siteKey": meta.map(|m| m.site_key.clone()).unwrap_or_default(),
            "installedAt": meta.map(|m| m.installed_at).unwrap_or(0),
            // ★ T5：上次订阅更新（0 = 从未更新；ok=false 时界面显示失败行）
            "lastUpdateAt": meta.map(|m| m.last_update_at).unwrap_or(0),
            "lastUpdateOk": meta.map(|m| m.last_update_ok).unwrap_or(false),
            "lastUpdateError": meta.and_then(|m| m.last_update_error.clone()),
        }));
    }
    Ok(serde_json::json!({
        "sources": out,
        "total": sources.len(),
        "withSource": with_source,
        /*
         * ★ A2：聚合源（`tvbox_agg`）的上次更新 —— 走**顶层字段**
         *
         * # 为什么不能塞进 `sources[]`
         * ```text
         * Dart 侧的「检测更新」按钮判据是 `_tvboxSources.containsKey(id)`。
         * 一旦把 tvbox_agg 塞进 sources[]，那张卡就多出一个"检测更新"按钮，
         * 而 update_tvbox_source 的第一句就是
         *   `if !sources.iter().any(|(sid,_,_,_)| sid == id)` ⇒ "没有找到 TVBox 源 tvbox_agg"
         * ⇒ 一个永远必然报错的按钮（聚合页 tvbox_aggregate_page.dart:333 已注明同款坑）。
         * ```
         * 顶层字段是**附加信息**，不进 sources[] ⇒ 零副作用。
         *
         * ⚠️ 一个子站都没盖过章 ⇒ `null`（Dart 侧据此显示"从未更新"）——
         *    绝不返回一个 0 假装"更新过"。
         */
        "aggregate": {
            "id": crate::tvbox_aggregate::AGGREGATE_ID,
            "lastUpdateAt": agg.as_ref().map(|(at, _, _)| *at).unwrap_or(0),
            "lastUpdateOk": agg.as_ref().map(|(_, ok, _)| *ok).unwrap_or(false),
            "lastUpdateError": agg.and_then(|(_, _, e)| e),
            /*
             * ★ 必须显式给 false：Dart 侧 `needsSource` 的缺省是 **true**
             *   （`j['needsSource'] != false`），不给就会把聚合源判成
             *   "没有订阅链接" ⇒ 显示「无法定时更新，去补链接」——
             *   而聚合源根本不是一条源，它没有（也不需要）自己的链接，
             *   它的时间来自子站。那是把"不适用"说成"配置缺失"。
             */
            "needsSource": false,
        },
    }))
}

/// 给某个 TVBox 源指定/清除订阅链接（纯本地写 sidecar）
///
/// 传空字符串 = 清除链接（回到「贴文本导入」状态，界面据此不再显示检测按钮）。
pub fn set_tvbox_source(
    state: &crate::state::AppState,
    id: &str,
    url: &str,
) -> std::result::Result<serde_json::Value, String> {
    let sources = local_tvbox_sources(state)?;
    let found = sources
        .iter()
        .find(|(sid, _, _, _)| sid == id)
        .ok_or_else(|| format!("没有找到 TVBox 源 {id}"))?;
    let url = url.trim();

    if url.is_empty() {
        forget_tvbox_meta(&state.data_dir, id)?;
        return Ok(serde_json::json!({
            "id": id, "name": found.1, "sourceUrl": serde_json::Value::Null,
        }));
    }
    if !starts_http(url) {
        return Err(format!("订阅链接必须是 http/https 地址：{url}"));
    }

    let old = read_tvbox_meta(&state.data_dir, id).unwrap_or_default();
    let meta = TvboxSourceMeta {
        source_url: Some(url.to_string()),
        // 老 site_key 保留 —— 换链接不等于换站点身份
        site_key: old.site_key,
        site_name: if old.site_name.is_empty() { found.1.clone() } else { old.site_name },
        api: if old.api.is_empty() { found.2.clone() } else { old.api },
        installed_at: if old.installed_at == 0 { now_secs() } else { old.installed_at },
        // 换/补链接不等于更新过：保留旧章（没有就还是「从未更新」）
        last_update_at: old.last_update_at,
        last_update_ok: old.last_update_ok,
        last_update_error: old.last_update_error,
    };
    write_tvbox_meta(&state.data_dir, id, &meta)?;
    Ok(serde_json::json!({
        "id": id, "name": found.1, "sourceUrl": url,
    }))
}

/// ★ 血缘修复（2026-11-01）：把「贴文本导入 ⇒ source_url=None」的存量子站
/// 与一条订阅链接做**验证型认领**关联
///
/// # 背景（考证结论）
///
/// 真机 64 条子站是上一批智能体把解码后的配置**文本**灌进导入产生的
/// （链接路径当时解不了 base64** 包裹，见 `unwrap_tvbox_config_text`），
/// 于是 sidecar 全部 source_url=None ⇒ `collect_due_links` 永远挑不到链接
/// ⇒ 定时更新从不下载 ⇒ 聚合卡永远「从未更新」。
///
/// # 为什么是"验证型认领"，不是重导、也不是逐条补链接
///
/// ```text
/// 重导              ：id 含名字成分，远端改名 ⇒ 新 id ⇒ 双份；还要重探测 64 站
/// 逐条 set_tvbox_source：没有配对验证，无法保证只给"真属于这条链接"的源补
/// 认领（本函数）      ：下载该链接、按 diff_sites 同一把尺子配对，命中才写
/// ```
///
/// # 认领规则
///
/// ```text
/// · 只动 source_url=None 的条目（已认领/已有链接的绝不碰 ⇒ 幂等，无双份）
/// · 配对判据与 diff_sites 同一把尺子：① site key 精确 ② 归一化 api
/// · 命中多少认领多少；未命中的数量在返回值里如实带出（远端可能已改名/删站）
/// · 一条都配不上 ⇒ Err（多半是链接给错了），绝不盲写
/// · 章不动：认领本身不比对子站内容；下一轮订阅更新（last≤0 ⇒ 到点）盖真章
/// ```
pub async fn adopt_tvbox_orphans(
    state: &crate::state::AppState,
    url: &str,
) -> std::result::Result<serde_json::Value, String> {
    let url = url.trim();
    if !starts_http(url) {
        return Err(format!("订阅链接必须是 http/https 地址：{url}"));
    }

    // 下载 + 解析（fetch_config_text 已带 base64** 解包）
    let client = probe_client();
    let text = fetch_config_text(&client, url)
        .await
        .map_err(|e| format!("下载配置失败（{url}）：{e}"))?;
    let cfg = parse_loose_json(&text).map_err(|e| format!("配置不是合法 JSON：{e}"))?;
    if cfg.get("sites").and_then(|v| v.as_array()).is_none() {
        return Err(format!(
            "远端链接 {url} 没有 sites 段（多仓配置请先选子仓，用子仓链接认领）"
        ));
    }
    let (remote_jobs, _skipped, _lives) = collect_sites(&cfg, url);

    // 无主子站 = 已注册的 TVBox 源里、sidecar 记着 source_url=None 的
    let sources = local_tvbox_sources(state)?;
    let metas = load_tvbox_metas(&state.data_dir);
    let orphan_ids: Vec<String> = sources
        .iter()
        .filter(|(sid, _, _, _)| {
            norm_source_url(metas.get(sid).and_then(|m| m.source_url.as_deref())).is_none()
        })
        .map(|(sid, _, _, _)| sid.clone())
        .collect();

    let mut used_remote = vec![false; remote_jobs.len()];
    let mut claimed: Vec<String> = Vec::new();
    let mut unmatched: Vec<serde_json::Value> = Vec::new();
    for sid in &orphan_ids {
        let Some(m) = metas.get(sid) else { continue };
        let key = m.site_key.trim();
        let api_norm = normalize_api_url(&m.api);
        let mut hit: Option<usize> = None;
        // ① site key 精确配对
        if !key.is_empty() {
            for (ri, job) in remote_jobs.iter().enumerate() {
                if !used_remote[ri] && job.key == key {
                    hit = Some(ri);
                    break;
                }
            }
        }
        // ② 剩下的按归一化 api 兜底（与 diff_sites 第②步同一判据）
        if hit.is_none() && !api_norm.is_empty() {
            for (ri, job) in remote_jobs.iter().enumerate() {
                if !used_remote[ri] && normalize_api_url(&job.api) == api_norm {
                    hit = Some(ri);
                    break;
                }
            }
        }
        match hit {
            Some(ri) => {
                used_remote[ri] = true;
                let old = m.clone();
                write_tvbox_meta(
                    &state.data_dir,
                    sid,
                    &TvboxSourceMeta {
                        // ★ 只补血缘，站点身份字段原样保留（换的是"从哪来"，不是站点）
                        source_url: norm_source_url(Some(url)),
                        site_key: old.site_key,
                        site_name: old.site_name,
                        api: old.api,
                        installed_at: old.installed_at,
                        last_update_at: old.last_update_at,
                        last_update_ok: old.last_update_ok,
                        last_update_error: old.last_update_error,
                    },
                )?;
                claimed.push(sid.clone());
            }
            None => unmatched.push(serde_json::json!({
                "id": sid,
                "siteKey": m.site_key,
                "siteName": m.site_name,
            })),
        }
    }

    // ★ 如实：一条都配不上不许写成功
    if !orphan_ids.is_empty() && claimed.is_empty() {
        return Err(format!(
            "该链接与任何无主子站都配不上（无主 {} 条，远端站点 {} 条），拒绝认领——请核对链接",
            orphan_ids.len(),
            remote_jobs.len()
        ));
    }

    Ok(serde_json::json!({
        "sourceUrl": url,
        "orphans": orphan_ids.len(),
        "claimed": claimed.len(),
        "claimedIds": claimed,
        "unmatched": unmatched.len(),
        "unmatchedList": unmatched,
    }))
}

/// 移除一个 TVBox 源，并**同时忘掉它的订阅链接**
///
/// # ★ 为什么必须同时清 sidecar（不能只调 remove_provider）
///
/// ```text
/// 只删源不删 sidecar → 数据目录里留一条孤儿记录。
/// 将来任何一份配置若恰好产出同一个 id（to_id 是可预测的：
/// 名称的 ASCII 字母 → api 域名首段 → tvboxN），新源就会**继承**
/// 那条陈旧的订阅链接 —— 表现为「刚导入的源却显示有更新可查」，
/// 而那个链接其实属于用户早就删掉的另一个站。
/// ```
///
/// 所以「删源」与「忘链接」必须是**同一个操作**，不能指望调用方记得调两次。
pub fn remove_tvbox_source(
    state: &crate::state::AppState,
    id: &str,
) -> std::result::Result<serde_json::Value, String> {
    let removed = crate::commands_provider::remove_provider(state, id)?;
    // 无论源在不在，都清一次链接（幂等）
    forget_tvbox_meta(&state.data_dir, id)?;
    Ok(serde_json::json!({ "id": id, "removed": removed }))
}

/// 检测订阅链接有没有更新
///
/// # 三种结局，都不许静默（与 check_plugin_update 同一条原则）
///
/// ```text
/// ① 没有订阅链接            → 进 skipped（needsSource），如实说「查不了」
/// ② 网络 / 解析失败          → 该条 error=Some(原因)
/// ③ 查到了                  → added / removed / changed / unchanged
/// ```
///
/// # 为什么按链接分组而不是按源
///
/// 一份配置产出几十个源，它们共用同一个链接 —— 一次下载就能对比全部，
/// 而不是每个源各下一遍（96 个站点就是 96 次请求）。
pub async fn check_tvbox_updates(
    state: &crate::state::AppState,
    only_id: Option<&str>,
) -> std::result::Result<serde_json::Value, String> {
    let sources = local_tvbox_sources(state)?;
    let metas = load_tvbox_metas(&state.data_dir);

    // 按 id 过滤（只查一个源）
    let picked: Vec<(String, String, String, Option<String>)> = match only_id {
        Some(want) => {
            let one = sources
                .iter()
                .find(|(id, _, _, _)| id == want)
                .ok_or_else(|| format!("没有找到 TVBox 源 {want}"))?;
            vec![one.clone()]
        }
        None => sources.clone(),
    };

    // 某个源属于哪个订阅链接（None = 没有链接，查不了）
    let url_of = |id: &str| -> Option<String> {
        metas
            .get(id)
            .and_then(|m| m.source_url.clone())
            .filter(|u| !u.trim().is_empty())
    };

    // 要查的链接（去重；BTreeSet 保证顺序稳定，结果可复现）
    let mut wanted: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut skipped_ids: Vec<String> = Vec::new();
    for (id, _, _, _) in picked.iter() {
        match url_of(id) {
            Some(u) => {
                wanted.insert(u);
            }
            None => skipped_ids.push(id.clone()),
        }
    }

    // 每个链接 → 配对池
    //
    // ★ 配对池是**全部** TVBox 源，不只是这个链接下的：
    //   两份配置里出现同一个站是常态，认不出来就会重复注册成两张一样的卡片。
    //   LocalSite::in_link 区分「属于本订阅」（可报 removed / 可应用变更）
    //   与「别的订阅导入的」（只认出来、绝不动它）。
    let mut groups: std::collections::BTreeMap<String, Vec<LocalSite>> =
        std::collections::BTreeMap::new();
    for url in wanted.iter() {
        let pool: Vec<LocalSite> = sources
            .iter()
            .map(|(sid, name, api, ext)| LocalSite {
                id: sid.clone(),
                key: metas.get(sid).map(|m| m.site_key.clone()).unwrap_or_default(),
                name: name.clone(),
                api: api.clone(),
                ext: ext.clone(),
                in_link: url_of(sid).as_deref() == Some(url.as_str()),
            })
            .collect();
        groups.insert(url.clone(), pool);
    }

    let client = probe_client();
    let mut items = Vec::new();
    for (url, locals) in groups.iter() {
        // 这条链接"拥有"的源（别的订阅的源不算在内）
        let mut ids: Vec<String> = locals
            .iter()
            .filter(|l| l.in_link)
            .map(|l| l.id.clone())
            .collect();
        ids.sort();

        let text = match fetch_config_text(&client, url).await {
            Ok(t) => t,
            Err(e) => {
                items.push(serde_json::json!({
                    "sourceUrl": url,
                    "ids": ids,
                    "ok": false,
                    "error": format!("下载配置失败：{e}"),
                }));
                continue;
            }
        };
        let cfg = match parse_loose_json(&text) {
            Ok(c) => c,
            Err(e) => {
                items.push(serde_json::json!({
                    "sourceUrl": url,
                    "ids": ids,
                    "ok": false,
                    "error": format!("配置不是合法 JSON：{e}"),
                }));
                continue;
            }
        };
        // 链接后来变成了「多仓」—— 如实说明，不硬凑一份对比
        if cfg.get("sites").and_then(|v| v.as_array()).is_none() {
            let repos = multi_repo_repos(&cfg, url);
            items.push(serde_json::json!({
                "sourceUrl": url,
                "ids": ids,
                "ok": false,
                "multiRepo": !repos.is_empty(),
                "repos": repos,
                "error": if repos.is_empty() {
                    "远端配置里没有 sites 段（可能是直播源配置或空配置）".to_string()
                } else {
                    "远端链接现在是一份「多仓」配置（只有 urls，没有 sites），无法直接对比站点列表".to_string()
                },
            }));
            continue;
        }

        let (jobs, skipped, _lives) = collect_sites(&cfg, url);
        let remote: Vec<RemoteSite> = jobs
            .iter()
            .map(|j| RemoteSite {
                key: j.key.clone(),
                name: j.name.clone(),
                api: normalize_api_url(&j.api),
                // 空串 ⇒ None（与落盘口径一致：没写 ≠ 写了空）
                ext: {
                    let e = j.ext.trim();
                    if e.is_empty() { None } else { Some(e.to_string()) }
                },
            })
            .collect();
        let diff = diff_sites(&locals, &remote);

        items.push(serde_json::json!({
            "sourceUrl": url,
            "ids": ids,
            "ok": true,
            "remoteTotalSites": cfg.get("sites").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
            "remoteConvertible": jobs.len(),
            "remoteUnsupported": skipped.len(),
            "added": diff.added,
            "removed": diff.removed,
            "changed": diff.changed,
            "unchanged": diff.unchanged,
            "unchangedForeign": diff.unchanged_foreign,
        }));
    }

    Ok(serde_json::json!({
        "items": items,
        "checked": groups.len(),
        "skipped": skipped_ids.len(),
        "skippedIds": skipped_ids,
    }))
}

/// 一键应用订阅链接上的更新
///
/// # 语义（用户点的是某张卡，但更新的是整份订阅）
///
/// ```text
/// ① 重新下载这个源所属的订阅链接（同一个链接下的源一起处理）
/// ② 远端还有的站  → 重新探测 → 沿用原 id 原地覆盖
///    （沿用 id 才能保住用户设过的启用状态/排序/收藏）
/// ③ 远端新增的站  → 注册进来（apply_new=false 时只报告）
/// ④ 远端消失的站  → ★ 只报告，默认绝不删（delete_missing=true 才删）
/// ⑤ 探测失败的站  → 如实进 failed，不动本地
/// ```
///
/// ⚠️ 第 ④ 条是这个功能的核心：配置作者临时删掉一个站又加回来是常事，
///    静默删掉用户本地的东西是不可逆的伤害。
/// 进程级订阅更新锁：手动更新（FFI 命令）与定时更新共用
///
/// sidecar 是整份读改写（`write_tvbox_meta` = load → insert → save），
/// 两个并发更新同一条链接会互相覆盖盖章结果 ⇒ 一律串行。
static UPDATE_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// 更新一个 TVBox 源（入口：FFI 命令 / 定时任务都走这里）
///
/// # ★ 失败也要留下痕迹（T5；「静默失败 = 缺陷」）
///
/// ```text
/// 内层 _inner 失败时只把 Err 抛给调用方 —— 手动更新界面能显示，
/// 但定时更新只拿得到日志。这里统一收口：
///   · log::warn!（落日志，stderr 可见）
///   · 给同一条链接的全部源盖「失败章」（时间 + 原因）
///     ⇒ 界面的「上次更新」行如实显示失败，而不是停留在旧的成功时间
/// 「没有找到这个源 / 没有订阅链接」不算更新失败（根本没有可更新的东西）⇒ 不盖章。
/// ```
pub async fn update_tvbox_source(
    state: &crate::state::AppState,
    id: &str,
    apply_new: bool,
    delete_missing: bool,
) -> std::result::Result<serde_json::Value, String> {
    let _guard = UPDATE_LOCK.lock().await;
    let r = update_tvbox_source_inner(state, id, apply_new, delete_missing).await;
    if let Err(e) = &r {
        // ★ P3-2：与 stamp 同一把尺子（否则"链接带空白 + 更新失败"盖不上失败章）
        let url = norm_source_url(
            read_tvbox_meta(&state.data_dir, id)
                .and_then(|m| m.source_url)
                .as_deref(),
        );
        if let Some(url) = url {
            log::warn!("TVBox 订阅更新失败（{url}）：{e}");
            stamp_link_update(&state.data_dir, &url, now_secs(), false, Some(e.clone()));
        }
    }
    r
}

/// 给同一条订阅链接下的全部源盖一次章（成功或失败）
///
/// 一份配置产出几十个源、共用同一个链接 —— 一次下载核对的是**整条链接**，
/// 所以章也必须盖整条：只盖 added/changed 的话，未变的源 `last_update_at`
/// 不动，定时器每轮都会把这条链接判成超期、重复下载。
fn stamp_link_update(
    dir: &std::path::Path,
    url: &str,
    now: i64,
    ok: bool,
    error: Option<String>,
) {
    // ★ P3-2：两边都按同一把尺子归一后再比（写入侧存的是 trim 后的值，
    //   这里的 url 可能来自用户输入/配置文件，带空白是常态）。
    let Some(want) = norm_source_url(Some(url)) else {
        return;
    };
    let _guard = TVBOX_META_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let mut map = load_tvbox_metas(dir);
    let mut touched = 0usize;
    for m in map.values_mut() {
        if norm_source_url(m.source_url.as_deref()).as_deref() == Some(want.as_str()) {
            m.last_update_at = now;
            m.last_update_ok = ok;
            m.last_update_error = if ok { None } else { error.clone() };
            touched += 1;
        }
    }
    if touched == 0 {
        return;
    }
    if let Err(e) = save_tvbox_metas(dir, &map) {
        // 盖章失败不该连累更新本身，但必须留日志（静默失败 = 缺陷）
        log::warn!("写 TVBox 订阅更新时间失败（{url}）：{e}");
    }
}

async fn update_tvbox_source_inner(
    state: &crate::state::AppState,
    id: &str,
    apply_new: bool,
    delete_missing: bool,
) -> std::result::Result<serde_json::Value, String> {
    let sources = local_tvbox_sources(state)?;
    if !sources.iter().any(|(sid, _, _, _)| sid == id) {
        return Err(format!("没有找到 TVBox 源 {id}"));
    }
    let Some(url) = norm_source_url(
        read_tvbox_meta(&state.data_dir, id)
            .and_then(|m| m.source_url)
            .as_deref(),
    ) else {
        return Err("这个源没有订阅链接，无法更新（请先填入链接）".to_string());
    };

    // ── 下载 + 解析 ─────────────────────────────────────────────────
    let client = probe_client();
    let text = fetch_config_text(&client, &url)
        .await
        .map_err(|e| format!("下载配置失败（{url}）：{e}"))?;
    let cfg = parse_loose_json(&text).map_err(|e| format!("配置不是合法 JSON：{e}"))?;
    if cfg.get("sites").and_then(|v| v.as_array()).is_none() {
        return Err(format!(
            "远端链接 {url} 现在是一份「多仓」配置（只有 urls，没有 sites），\
             不能直接更新。请打开其中某个子仓，把它的链接填进来。"
        ));
    }

    // 配对池 = **全部** TVBox 源，但只有同一个链接下的那些才算「本订阅的」
    // （in_link=true）—— 见 LocalSite::in_link 的说明。
    let metas = load_tvbox_metas(&state.data_dir);
    let in_link = |sid: &str| -> bool {
        norm_source_url(
            metas
                .get(sid)
                .and_then(|m| m.source_url.as_deref()),
        )
        .as_deref()
            == norm_source_url(Some(&url)).as_deref()
    };
    let locals: Vec<LocalSite> = sources
        .iter()
        .map(|(sid, name, api, ext)| LocalSite {
            id: sid.clone(),
            key: metas.get(sid).map(|m| m.site_key.clone()).unwrap_or_default(),
            name: name.clone(),
            api: api.clone(),
            ext: ext.clone(),
            in_link: in_link(sid),
        })
        .collect();

    let (jobs, skipped, _lives) = collect_sites(&cfg, &url);
    let remote: Vec<RemoteSite> = jobs
        .iter()
        .map(|j| RemoteSite {
            key: j.key.clone(),
            name: j.name.clone(),
            api: normalize_api_url(&j.api),
            ext: {
                let e = j.ext.trim();
                if e.is_empty() { None } else { Some(e.to_string()) }
            },
        })
        .collect();
    let diff = diff_sites(&locals, &remote);

    let want_delete = delete_missing && !diff.removed.is_empty();
    if diff.added.is_empty() && diff.changed.is_empty() && !want_delete {
        // ★ 「远端与本地一致」也是一次成功的核对 ⇒ 盖成功章。
        //   不盖的话这条链接在定时器眼里永远没更新过，每 60s 都会重复下载。
        stamp_link_update(&state.data_dir, &url, now_secs(), true, None);
        return Ok(serde_json::json!({
            "updated": false,
            "reason": "远端配置与本地一致，无需更新",
            "sourceUrl": url,
            "added": [],
            "changed": [],
            // ★ 即使"没更新"，也要如实报告"远端已经没有的站"——
            //   否则用户会以为一切都对，实际上本地留着几个已经下线的站。
            "removed": diff.removed,
            "deleted": [],
            "failed": [],
            "unchanged": diff.unchanged,
            "unchangedForeign": diff.unchanged_foreign,
            "skippedByType": skipped.len(),
        }));
    }

    // ── 需要（重新）探测的站：新增 + 变更 ────────────────────────────
    //
    // 每项 = (远端站点下标, 要覆盖的本地 id)；新增项本地 id 为 None。
    let mut todos: Vec<(usize, Option<String>)> = Vec::new();
    for (i, _r) in diff.added.iter().enumerate() {
        todos.push((diff.added_idx[i], None));
    }
    for (i, c) in diff.changed.iter().enumerate() {
        todos.push((diff.changed_idx[i], Some(c.id.clone())));
    }

    let sem = Arc::new(tokio::sync::Semaphore::new(MAX_PROBE_CONCURRENCY));
    let mut results: Vec<Option<std::result::Result<ProbeOk, String>>> =
        (0..todos.len()).map(|_| None).collect();
    let mut set = tokio::task::JoinSet::new();
    for (idx, (remote_idx, _)) in todos.iter().enumerate() {
        let client = client.clone();
        let sem = sem.clone();
        // ★ 与首次导入同一条探测路由（csp 源不能拿去当苹果CMS 探）
        let job = jobs.get(*remote_idx).cloned();
        set.spawn(async move {
            let _permit = sem.acquire_owned().await;
            match job {
                Some(job) => (idx, probe_site(&client, &job).await),
                None => (idx, Err("远端站点下标越界".to_string())),
            }
        });
    }
    while let Some(joined) = set.join_next().await {
        match joined {
            Ok((idx, r)) => results[idx] = Some(r),
            Err(e) => log::warn!("TVBox 更新探测任务异常退出：{e}"),
        }
    }

    // ── 生成要写盘的源 ───────────────────────────────────────────────
    //
    // used 预置**全部已存在的 id**（含别的订阅里的 tvbox 源）：
    // 新增站点绝不顶掉任何已有源；要覆盖的老站直接沿用原 id，不走 unique_id。
    let mut used: HashSet<String> = state
        .registry
        .manifests()
        .iter()
        .map(|m| m.id.clone())
        .collect();

    let mut to_persist: Vec<crate::model::PersistedProvider> = Vec::new();
    let mut meta_writes: Vec<(String, TvboxSourceMeta)> = Vec::new();
    let mut added_out: Vec<serde_json::Value> = Vec::new();
    let mut changed_out: Vec<serde_json::Value> = Vec::new();
    let mut not_applied: Vec<serde_json::Value> = Vec::new();
    let mut failed_out: Vec<serde_json::Value> = Vec::new();

    for (idx, (remote_idx, local_id)) in todos.iter().enumerate() {
        let Some(job) = jobs.get(*remote_idx) else {
            continue;
        };
        /*
         * ★ 与首次导入**同一判据**（`keep_ext_on_probe_failure`）：
         * 带 ext 的 csp 源探测失败 ⇒ 仍然落盘（ext 就是它的配置），
         * 只把原因挂到报告行上。否则"检测更新"会把用户改好的 ext 又丢一次
         * —— 那正是本卡要修的那条丢失路径的副本。
         */
        let mut probe_failed: Option<String> = None;
        let ok = match results.get_mut(idx).and_then(|x| x.take()) {
            Some(Ok(ok)) => ok,
            Some(Err(reason)) => {
                if !keep_ext_on_probe_failure(job) {
                    failed_out.push(serde_json::json!({
                        "name": job.name,
                        "api": normalize_api_url(&job.api),
                        "reason": reason,
                    }));
                    continue;
                }
                probe_failed = Some(reason);
                // 分类留空：运行期 home() 再问（不编假分类）
                ProbeOk {
                    classes: Vec::new(),
                    total: 0,
                }
            }
            None => {
                failed_out.push(serde_json::json!({
                    "name": job.name,
                    "api": normalize_api_url(&job.api),
                    "reason": "探测任务异常",
                }));
                continue;
            }
        };

        let (sid, is_new) = match local_id.clone() {
            Some(existing) => (existing, false),
            None => {
                if !apply_new {
                    // 用户没勾「同时加入新增站点」—— 如实报告，不偷偷加
                    not_applied.push(serde_json::json!({
                        "name": job.name,
                        "api": normalize_api_url(&job.api),
                    }));
                    continue;
                }
                (
                    unique_id(&id_base_for(job), &mut used),
                    true,
                )
            }
        };

        let provider = build_site_provider(
            &sid,
            job,
            &ok,
            Some(state.proxy.clone()),
            collect_parsers(&cfg),
        )
        .map_err(|e| format!("生成源「{}」失败：{e}", job.name))?;
        let manifest = provider.manifest().clone();
        state.registry.register(provider);

        let api_norm = normalize_api_url(&job.api);
        /*
         * ★ 与首次导入同一条规矩：csp 源**也要落盘**（含 ext）。
         *
         * 只改导入不改更新，会出现「更新一次，源就再也回不来了」——
         * 比不更新更糟。两条路径必须写同一份结构（特别是 `ext`：
         * 更新时配置里的 ext 可能与上次不同，用户改过就该被新值覆盖）。
         */
        to_persist.push(crate::model::PersistedProvider::Tvbox {
            id: sid.clone(),
            name: manifest.name.clone(),
            api: api_norm.clone(),
            categories: ok.classes.clone(),
            parsers: collect_parsers(&cfg),
            ext: {
                let e = job.ext.trim();
                if e.is_empty() { None } else { Some(e.to_string()) }
            },
        });
        meta_writes.push((
            sid.clone(),
            TvboxSourceMeta {
                source_url: Some(url.clone()),
                site_key: job.key.clone(),
                site_name: job.name.clone(),
                api: api_norm.clone(),
                installed_at: now_secs(),
                // 走到这里的源刚被这次更新重写 ⇒ 盖成功章
                //（同链接下没变的源由下面的 stamp_link_update 统一补章）
                last_update_at: now_secs(),
                last_update_ok: true,
                last_update_error: None,
            },
        ));
        let row = serde_json::json!({
            "id": sid,
            "name": manifest.name,
            "api": api_norm,
            "categories": ok.classes.len(),
            "total": ok.total,
            // csp 源现在也落盘 ⇒ 一律 true
            "persisted": true,
            // ★ 没探通但配置在：如实标（与首次导入同名字段）
            "extLen": job.ext.trim().len(),
            "probeFailed": probe_failed,
        });
        if is_new {
            added_out.push(row);
        } else {
            changed_out.push(row);
        }
    }

    // ── 先落盘新增/变更，再处理「远端消失」（顺序不能换）──────────────
    //
    // remove_provider 内部会 persist_from_registry —— 它写的是内存里的
    // third_party。若先删后写，新站还没进内存就被写成清单，等于白探测。
    if !to_persist.is_empty() {
        {
            let mut list = state
                .third_party
                .write()
                .map_err(|_| "第三方源列表被污染".to_string())?;
            for p in to_persist {
                let pid = p.id().to_string();
                list.retain(|x| x.id() != pid);
                list.push(p);
            }
        }
        crate::commands_provider::persist_from_registry(state)?;
        crate::commands_provider::touch_providers(state);
    }
    for (sid, meta) in meta_writes.iter() {
        write_tvbox_meta(&state.data_dir, sid, meta)?;
    }
    // ★ 成功路径收尾：同链接下**没变化**的源也要补章（见 stamp_link_update 的注释）
    stamp_link_update(&state.data_dir, &url, now_secs(), true, None);

    // ── 远端消失的站：默认只报告 ────────────────────────────────────
    let mut deleted_out: Vec<serde_json::Value> = Vec::new();
    if want_delete {
        for l in diff.removed.iter() {
            // 只在**这一份订阅**里确认它真的没了才删
            if !locals.iter().any(|x| x.id == l.id && x.in_link) {
                continue;
            }
            match crate::commands_provider::remove_provider(state, &l.id) {
                Ok(_) => {
                    let _ = forget_tvbox_meta(&state.data_dir, &l.id);
                    deleted_out.push(serde_json::json!({ "id": l.id, "name": l.name }));
                }
                Err(e) => failed_out.push(serde_json::json!({
                    "name": l.name,
                    "api": normalize_api_url(&l.api),
                    "reason": format!("删除失败：{e}"),
                })),
            }
        }
    }

    let updated = !added_out.is_empty() || !changed_out.is_empty() || !deleted_out.is_empty();
    log::info!(
        "TVBox 订阅更新（{url}）：新增 {} 变更 {} 删除 {} 失败 {} 远端消失 {} 未加入 {} {}",
        added_out.len(),
        changed_out.len(),
        deleted_out.len(),
        failed_out.len(),
        diff.removed.len(),
        not_applied.len(),
        if delete_missing { "" } else { "（未勾选删除，已保留）" }
    );
    Ok(serde_json::json!({
        "updated": updated,
        "sourceUrl": url,
        "added": added_out,
        "changed": changed_out,
        "removed": diff.removed,
        "deleted": deleted_out,
        "notApplied": not_applied,
        "failed": failed_out,
        "unchanged": diff.unchanged,
        "unchangedForeign": diff.unchanged_foreign,
        "skippedByType": skipped.len(),
    }))
}

// ═══════════════════════════════════════════════════════════════════════
//  N8b-1② 存量「TVBox 迁移 js 插件」的还原数据通道（2026-10-27）
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景考证（.probe/n8b0-spec-audit.md §4）
//
// 本仓的导入/更新路径**从不生成 js 插件**（见本文件头部注释）；用户机器上
// 那些 js 插件是历史外部工具 `tools/tvbox-convert.mjs` 生成的。转换器在
// 生成文件的头注释里写了两样东西，构成还原的**可靠标记**：
//
// ```text
//  @author tvbox-convert                       ← 来源标记（commands_provider.rs 的 PluginEntry 注释有逐字考证）
//  * 上游接口（苹果CMS v10）：http://…          ← 原始链接，plugins::upstream_of 可提取
// ```
//
// # 硬边界（Owner 裁定，2026-10-27）
//
// ```text
// · 只认 @author == tvbox-convert 的文件；其它一律不列、不删、不猜
//   —— 用户手写的 js 插件绝不能因为长得像就被当成迁移产物
// · 还原是**逐文件显式**操作：本通道没有任何"批量还原/批量删除"入口
// · 标记对但上游提取不出 ⇒ 进 undetermined 清单交 Leader 给 Owner 过目，
//   绝不默认删除
// ```
//
// # FFI 接线（本批写范围不含 ffi.rs —— 那是含 NUL 的文件，归 Lead）
//
// ```rust
// // sync dispatch（与 tvbox_aggregate_get 同一段，ffi.rs ~:778）：
// "tvbox_migratable_js" => with_state(|st| crate::tvbox::migratable_js(st)),
// // async dispatch（与 import_tvbox_config 同一段，ffi.rs ~:2257）：
// "tvbox_restore_js" => {
//     let file = match a.str("file") { Ok(s) => s.to_string(), Err(e) => return err_json(&e, "other") };
//     with_state_async(move |st| async move { crate::tvbox::restore_tvbox_js(st, &file).await }).await
// }
// ```
//
// （不接线的理由按 AGENTS「新增公开 API 必须给出调用点」的例外条款在此声明：
//   ffi.rs 不在本批写入范围，且 Dart 侧接线归 tvbox-ui。）

/// 迁移产物的作者标记（转换器写死在头注释里）
pub const TVBOX_CONVERT_AUTHOR: &str = "tvbox-convert";

/// 插件文件名校验（与 commands_provider::check_plugin_name 同一条规则）
///
/// ⚠️ 参数来自前端，必须当作**不可信输入**（防目录穿越）。
fn check_js_file_name(file: &str) -> std::result::Result<(), String> {
    if file.contains('/') || file.contains('\\') || file.contains("..") {
        return Err("非法的文件名".to_string());
    }
    if !file.ends_with(".js") {
        return Err("只接受 .js 插件文件".to_string());
    }
    Ok(())
}

/// `tvbox_migratable_js`：列出「TVBox 迁移产生的 js 插件」及其原始链接（**只读**）
///
/// 返回三段：
/// ```text
/// items         author=tvbox-convert 且上游可提取 —— UI 可逐条提供「还原为原始链接」
/// undetermined  author=tvbox-convert 但上游提取不出 —— 判定不出，列清单交 Owner 过目
///               （不进 items，更不允许删）
/// （其余）      非迁移产物（用户手写/内置/其它作者）**完全不出现** —— 硬边界
/// ```
/// `alreadyLinked`：本地已有同接口的 tvbox 直连源（真还原只需删 js，不用重建）。
pub fn migratable_js(state: &crate::state::AppState) -> std::result::Result<serde_json::Value, String> {
    let list = crate::commands_provider::list_plugins(state)?;
    // 已有 tvbox 直连源的 api 集合（persisted 清单是 api 的权威来源 ——
    // manifest 不携带 api，别在这里猜）
    let linked: std::collections::HashMap<String, String> = crate::persist::load_persisted(&state.data_dir)
        .into_iter()
        .filter_map(|p| match p {
            crate::model::PersistedProvider::Tvbox { id, api, .. } => Some((api, id)),
            _ => None,
        })
        .collect();

    let mut items = Vec::new();
    let mut undetermined = Vec::new();
    for e in list.plugins {
        if e.author != TVBOX_CONVERT_AUTHOR {
            continue; // 非迁移产物：硬边界，不出现
        }
        if e.upstream.trim().is_empty() {
            undetermined.push(serde_json::json!({
                "file": e.file,
                "id": e.id,
                "name": e.name,
                "reason": "上游接口无法提取（头部注释里没有「上游接口」行）",
            }));
            continue;
        }
        let linked_id = linked.get(e.upstream.trim()).cloned();
        items.push(serde_json::json!({
            "file": e.file,
            "id": e.id,
            "name": e.name,
            "upstream": e.upstream,
            "author": e.author,
            "loaded": e.loaded,
            "alreadyLinked": linked_id.is_some(),
            "linkedProviderId": linked_id,
        }));
    }
    Ok(serde_json::json!({
        "ok": true,
        "items": items,
        "undetermined": undetermined,
    }))
}

/// `tvbox_restore_js`：把一个迁移 js 插件「还原为原始链接」
///
/// 步骤（顺序即安全边界）：
/// ```text
/// ① 文件名校验（防穿越）+ 读源码
/// ② @author 必须 == tvbox-convert（否则 Err —— 手写插件到此为止）
/// ③ upstream 必须能提取且是 http(s)
/// ④ alreadyLinked ⇒ 只删 js（同接口的直连源已在，重建就是重复）
/// ⑤ 真探测上游（probe_site）—— 探测失败就 Err，**不删任何东西**
/// ⑥ 建 tvbox kind 的直连 provider（build_site_provider，与导入同一路）
///    注册 + 落盘 + 记 sidecar（source_url=None：单文件无从知道原订阅链接，
///    如实不填 ⇒ UI 按「无订阅链接」口径显示）
/// ⑦ 最后才删 js 文件（remove_plugin：unregister + remove_file）
///    删除失败不回滚源（源已可用），如实在返回值里报 deleted:false
/// ```
pub async fn restore_tvbox_js(
    state: &crate::state::AppState,
    file: &str,
) -> std::result::Result<serde_json::Value, String> {
    check_js_file_name(file)?;
    let src = crate::commands_provider::read_plugin(state, file)?;
    let meta = crate::plugins::parse_meta(&src);
    if meta.author != TVBOX_CONVERT_AUTHOR {
        // 硬边界：不是转换器产物，一个字节都不动
        return Err(format!(
            "「{file}」不是 TVBox 迁移产生的插件（@author={}），已拒绝还原",
            if meta.author.is_empty() { "（空）" } else { &meta.author }
        ));
    }
    let upstream = crate::plugins::upstream_of(&src);
    let upstream = upstream.trim().to_string();
    if upstream.is_empty() {
        return Err(format!(
            "「{file}」的上游接口无法提取（判定不出），请先在清单里确认后再处理"
        ));
    }
    if !starts_http(&upstream) {
        return Err(format!("「{file}」的上游接口不是 http(s) 地址：{upstream}"));
    }

    // alreadyLinked：同接口的直连源已存在 ⇒ 只删 js
    let already = crate::persist::load_persisted(&state.data_dir)
        .into_iter()
        .find_map(|p| match p {
            crate::model::PersistedProvider::Tvbox { id, api, .. } if api == upstream => Some(id),
            _ => None,
        });
    if let Some(pid) = already {
        match crate::commands_provider::remove_plugin(state, file) {
            Ok(()) => {
                log::info!("N8b-1 还原：{file} 的上游 {upstream} 已有直连源 {pid}，仅删除迁移 js");
                return Ok(serde_json::json!({
                    "ok": true,
                    "restored": false,
                    "alreadyLinked": true,
                    "linkedProviderId": pid,
                    "deleted": true,
                }));
            }
            Err(e) => {
                return Ok(serde_json::json!({
                    "ok": false, "alreadyLinked": true, "linkedProviderId": pid,
                    "deleted": false, "error": e,
                }));
            }
        }
    }

    // ⑤ 真探测上游（失败即 Err，不删不建）
    let job = SiteJob {
        index: 0,
        key: String::new(),
        name: meta.name.clone(),
        api: upstream.clone(),
        kind: Some(1),
        csp: None,
        ext: String::new(),
    };
    let client = probe_client();
    let ok = probe_site(&client, &job)
        .await
        .map_err(|e| format!("上游探测失败（{upstream}）：{e} —— 迁移 js 保持原样，未做任何改动"))?;

    // ⑥ 建直连 provider（与导入/更新同一条 build_site_provider 路）
    let mut used: HashSet<String> = state
        .registry
        .manifests()
        .iter()
        .map(|m| m.id.clone())
        .collect();
    let id = unique_id(&to_id(&meta.name, &upstream, 0), &mut used);
    let provider = build_site_provider(&id, &job, &ok, Some(state.proxy.clone()), Vec::new())
        .map_err(|e| format!("生成直连源失败：{e}"))?;
    let manifest = provider.manifest().clone();
    state.registry.register(provider);
    {
        let mut list = state
            .third_party
            .write()
            .map_err(|_| "第三方源列表被污染".to_string())?;
        let pid = id.clone();
        list.retain(|x| x.id() != pid);
        list.push(crate::model::PersistedProvider::Tvbox {
            id: id.clone(),
            name: manifest.name.clone(),
            api: upstream.clone(),
            categories: ok.classes.clone(),
            parsers: Vec::new(),
            ext: None,
        });
    }
    crate::commands_provider::persist_from_registry(state)?;
    crate::commands_provider::touch_providers(state);
    // 单文件还原不知道原订阅链接 ⇒ source_url 如实留 None（UI 按「无订阅链接」显示）
    let _ = write_tvbox_meta(
        &state.data_dir,
        &id,
        &TvboxSourceMeta {
            source_url: None,
            site_key: String::new(),
            site_name: manifest.name.clone(),
            api: upstream.clone(),
            installed_at: now_secs(),
            // 还原 ≠ 订阅更新过 ⇒ 如实「从未更新」
            last_update_at: 0,
            last_update_ok: false,
            last_update_error: None,
        },
    );

    // ⑦ 最后删 js（探测/建源都成功后才动文件）
    let deleted = match crate::commands_provider::remove_plugin(state, file) {
        Ok(()) => true,
        Err(e) => {
            log::warn!("N8b-1 还原：直连源 {id} 已建好，但删 {file} 失败：{e}");
            false
        }
    };
    log::info!("N8b-1 还原完成：{file} → {id}（{upstream}），deleted={deleted}");
    Ok(serde_json::json!({
        "ok": true,
        "restored": true,
        "id": id,
        "name": manifest.name,
        "api": upstream,
        "deleted": deleted,
    }))
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
  // TVBox 配置示例（含注释与尾逗号 —— 野外真实形态）
  "sites": [
    {"key":"bf","name":"暴风","type":1,"api":"https://bfzyapi.com/api.php/provide/vod?ac=list","searchable":1},
    {"key":"dl","name":"东篱","type":3,"api":"csp_DongLi","jar":"./jar/dongli.jar"},
    {"key":"jx","name":"解析","type":0,"api":"https://jx.example.com/?url="},
    {"key":"cn","name":"中文名源","type":1,"api":"https://www.ffzyapi.com/api.php/provide/vod",},
  ],
  "lives": [{"name":"某电视台","url":"http://x/y.m3u"},],
  "parses": [{"name":"爱心","type":4,"url":"http://119.91.123.253:2345/Api/yun.php?url="}]
}"#;

    #[test]
    fn loose_json_handles_comments_and_trailing_commas() {
        let v = parse_loose_json(SAMPLE).expect("宽松解析");
        assert_eq!(v.get("sites").unwrap().as_array().unwrap().len(), 4);
    }

    #[test]
    fn loose_json_handles_bom_and_jsonp() {
        let with_bom = format!("\u{feff}{{\"a\":1}}");
        assert_eq!(parse_loose_json(&with_bom).unwrap()["a"], 1);
        let jsonp = parse_loose_json("my.cb({ \"a\": 2 });").unwrap();
        assert_eq!(jsonp["a"], 2);
        // 括号出现在字符串里时不能误拆
        let s = "{\"a\":\"(\"}";
        assert_eq!(parse_loose_json(s).unwrap()["a"], "(");
    }

    #[test]
    fn loose_json_escapes_raw_control_chars_inside_strings() {
        // ★ 实测两条真配置栽在这：http://xhztv.top/4k.json 的 "优<LF>酷"、
        //   gh-proxy 那份 svip.json 的 "喜欢热闹还是喜欢安静<LF>       "。
        //   serde_json 严格执行 RFC 8259（字符串内不许 U+0000-U+001F）⇒ 必须自己补转义。
        let s = "{\"a\":\"优\n酷\",\"b\":\"x\ty\",\"c\":\"p\rq\"}";
        let v = parse_loose_json(s).expect("字符串里的裸控制字符应被补成转义序列");
        assert_eq!(v["a"], "优\n酷");
        assert_eq!(v["b"], "x\ty");
        assert_eq!(v["c"], "p\rq");
        // 没有短转义的控制字符走 \uXXXX
        let v2 = parse_loose_json("{\"a\":\"x\u{1}y\"}").unwrap();
        assert_eq!(v2["a"], "x\u{1}y");
        // ★ 字符串外的空白不能被误伤：CRLF 换行的配置照样解析
        let v3 = parse_loose_json("{\r\n  \"a\": 1\r\n}\r\n").unwrap();
        assert_eq!(v3["a"], 1);
    }

    #[test]
    fn loose_json_keeps_escapes_and_in_string_punctuation_intact() {
        // 已经是转义的 \n 不能被二次转义
        let v = parse_loose_json("{\"a\":\"x\\ny\"}").unwrap();
        assert_eq!(v["a"], "x\ny");
        // 字符串里的 , 与 } 不能被当成结构字符（尾逗号清理必须认字符串状态）
        let v2 = parse_loose_json("{\"a\":\"x,\n}\",\"b\":1,}").unwrap();
        assert_eq!(v2["a"], "x,\n}");
        assert_eq!(v2["b"], 1);
        // 字符串里的 // 不能被当成注释
        let v3 = parse_loose_json("{\"a\":\"http://x/y\"}").unwrap();
        assert_eq!(v3["a"], "http://x/y");
        // 真配置形态：字符串内换行后的续行以 // 开头，也不能被整行注释删掉
        let v4 = parse_loose_json("{\"a\":\"head\n//tail\",\"b\":2}").unwrap();
        assert_eq!(v4["a"], "head\n//tail");
        assert_eq!(v4["b"], 2);
    }

    #[test]
    fn normalize_api_strips_query_string() {
        // ★ 实测踩过的坑：不剥查询串 → 所有分类 0 条
        assert_eq!(
            normalize_api_url("https://api.apibdzy.com/api.php/provide/vod?ac=list"),
            "https://api.apibdzy.com/api.php/provide/vod"
        );
        assert_eq!(
            normalize_api_url("  http://cj.ffzyapi.com/api.php/provide/vod/  "),
            "http://cj.ffzyapi.com/api.php/provide/vod"
        );
        assert_eq!(normalize_api_url(""), "");
    }

    #[test]
    fn to_id_never_returns_constant() {
        // 中文名 → 域名兜底（第一版返回固定 'src' 导致四个源互相覆盖）
        assert_eq!(to_id("暴风", "https://bfzyapi.com/api.php", 0), "bfzyapi");
        assert_eq!(
            to_id("中文名源", "https://www.ffzyapi.com/api.php", 3),
            "ffzyapi"
        );
        // ASCII 名优先
        assert_eq!(to_id("BaoFeng", "https://bfzyapi.com/api.php", 0), "baofeng");
        // 都取不到 → 序号兜底
        assert_eq!(to_id("中文", "", 6), "tvbox7");
        // 两个中文名源不能撞成同一个 id
        assert_ne!(
            to_id("玄珠", "https://a1.com/api.php", 0),
            to_id("小马", "https://a2.com/api.php", 1)
        );
    }

    #[test]
    fn unique_id_appends_suffix() {
        let mut used = HashSet::new();
        assert_eq!(unique_id("bf", &mut used), "bf");
        assert_eq!(unique_id("bf", &mut used), "bf-2");
        assert_eq!(unique_id("bf", &mut used), "bf-3");
    }

    #[test]
    fn parse_episodes_splits_and_filters() {
        let s = "第1集$https://a.com/1.m3u8#第2集$https://a.com/2.m3u8#坏数据$notaurl";
        let eps = parse_episodes(s);
        assert_eq!(eps.len(), 2);
        assert_eq!(eps[0].0, "第1集");
        assert_eq!(eps[1].1, "https://a.com/2.m3u8");
        // 没有 $ 分隔时整段当地址
        let only = parse_episodes("https://a.com/x.m3u8");
        assert_eq!(only.len(), 1);
        assert_eq!(only[0].0, "");
    }

    // ═══════════════════════════════════════════════════════════════
    //  task-9 ②：HTML 实体解码（Owner：「右边介绍居然还有 &nbsp; 这种代码」）
    // ═══════════════════════════════════════════════════════════════

    #[test]
    fn decode_entities_named() {
        assert_eq!(decode_entities("a&nbsp;b"), "a b");
        assert_eq!(decode_entities("&lt;p&gt;"), "<p>");
        assert_eq!(decode_entities("&quot;x&quot;"), "\"x\"");
        assert_eq!(decode_entities("&apos;y&apos;"), "'y'");
        assert_eq!(decode_entities("a&amp;b"), "a&b");
        // 没有 & 就原样返回（不白跑一遍）
        assert_eq!(decode_entities("纯文本"), "纯文本");
    }

    #[test]
    fn decode_entities_numeric() {
        assert_eq!(decode_entities("&#39;"), "'");
        assert_eq!(decode_entities("&#x2913;"), "\u{2913}");
        assert_eq!(decode_entities("&#65;&#66;"), "AB");
        assert_eq!(decode_entities("&#x41;"), "A");
        // 解不出来的一律**原样保留**（不吞、不变成空）
        assert_eq!(decode_entities("&#xZZ;"), "&#xZZ;");
        assert_eq!(decode_entities("&#;"), "&#;");
        assert_eq!(decode_entities("&#999999999;"), "&#999999999;");
    }

    /// ★★ 顺序：`&amp;` 必须**最后**解
    ///
    /// 实测（`.probe/t9_order_test.mjs`）：
    /// ```text
    /// 输入 "&amp;nbsp;"
    ///   · &amp; 最先解 ⇒ 得 "&nbsp;" ⇒ 再被 nbsp 规则换成空格 ⇒ " "      ← 错
    ///   · &amp; 最后解 ⇒ 得 "&nbsp;" ⇒ 没有后续规则 ⇒ 字面量 "&nbsp;"    ← 对
    /// ```
    /// 语义上 `&amp;nbsp;` 表示"用户想显示 `&nbsp;` 这 6 个字符"。
    #[test]
    fn decode_entities_amp_is_last() {
        // 若把 &amp; 放最前，这里会得到 " "（错）
        assert_eq!(decode_entities("&amp;nbsp;"), "&nbsp;");
        assert_eq!(decode_entities("&amp;lt;"), "&lt;");
        // 真嵌套（只有一层实体，&amp; 解完就停）也不重复解
        assert_eq!(decode_entities("&amp;amp;"), "&amp;");
    }

    #[test]
    fn strip_tags_removes_markup() {
        assert_eq!(strip_tags("<p>你好<br/>世界</p>"), "你好世界");
        assert_eq!(strip_tags("  <b>x</b>  "), "x");
        assert_eq!(strip_tags("a < b"), "a < b");
        // ★ task-9 ②：去完标签还要解实体（Owner 截图里就是 &nbsp;）
        assert_eq!(strip_tags("<p>介绍&nbsp;文本</p>"), "介绍 文本");
        assert_eq!(strip_tags("A&amp;B"), "A&B");
        // ⚠️ 顺序：必须**先**去标签**再**解实体 ——
        //    反过来会把 &lt;p&gt; 解成真标签，那它就躲过去标签、最后显示成标签
        assert_eq!(strip_tags("&lt;p&gt;x&lt;/p&gt;"), "<p>x</p>");
        // 真实形态：标签 + 实体混排
        assert_eq!(
            strip_tags("<div>第1集&nbsp;&nbsp;主演：A&amp;B</div>"),
            "第1集  主演：A&B"
        );
    }

    #[test]
    fn absolutize_handles_all_shapes() {
        let base = "https://a.com/share/abc";
        assert_eq!(
            absolutize("https://b.com/x.m3u8", base),
            "https://b.com/x.m3u8"
        );
        assert_eq!(absolutize("//b.com/x.m3u8", base), "https://b.com/x.m3u8");
        assert_eq!(absolutize("/p/x.m3u8", base), "https://a.com/p/x.m3u8");
        assert_eq!(absolutize("x.m3u8", base), "https://a.com/share/x.m3u8");
        assert_eq!(absolutize("", base), "");
        // base 本身畸形时原样返回
        assert_eq!(absolutize("x.m3u8", "not-a-url"), "x.m3u8");
    }

    #[test]
    fn extract_m3u8_from_html() {
        let html = r#"<script>var u = "/20260718/36834/index.m3u8?sign=abc";</script>"#;
        assert_eq!(
            extract_m3u8(html, "https://super.ffzy-online6.com/share/9f").as_deref(),
            Some("https://super.ffzy-online6.com/20260718/36834/index.m3u8?sign=abc")
        );
        // 没有 m3u8 的页面（真实样本里量子采集有 1 条这种）
        assert!(extract_m3u8("<html>no video here</html>", "https://a.com/p").is_none());
        // 中文内容不应 panic
        assert!(extract_m3u8("中文页面 <div>没有地址</div>", "https://a.com/p").is_none());
    }

    #[test]
    fn collect_sites_classifies_by_type() {
        // SAMPLE 里的 4 个站 = 2 个 type:1（可用）+ type:3 csp_DongLi（未实现）
        //                    + type:0 解析式 JSON（不支持）
        let cfg = parse_loose_json(SAMPLE).unwrap();
        let (jobs, skipped, lives) = collect_sites(&cfg, "");
        assert_eq!(jobs.len(), 2, "两个 type=1 站点");
        assert_eq!(jobs[0].name, "暴风");
        assert_eq!(jobs[1].name, "中文名源");
        // ★ 不许变成「静默丢弃」：两个不可用站点**都必须**在 skipped 里
        assert_eq!(skipped.len(), 2, "两个不可用站点都必须进 skipped");
        assert_eq!(lives.len(), 1);
        let reasons: Vec<String> = skipped
            .iter()
            .map(|s| s["reason"].as_str().unwrap().to_string())
            .collect();

        /*
         * ── 第19项迁移（2026-10-25）──────────────────────────────────
         *
         * 旧断言：`reasons.any(contains("spider"))`。
         *
         * 为什么它会红、而且**红得对**：
         * `csp_DongLi` 是 `type:3 + api:"csp_Xxx"`，第19项之后这条不再走
         * `skip_reason(Some(3))`（那句「spider…需要 Java 运行时」），
         * 而是查 csp 注册表 —— 没这个类 ⇒ reason = "csp_DongLi 尚未实现"。
         *
         * ⇒ 新断言守的**不变量**变了，而且更硬：
         * ```text
         * ① 源码里必须能看到**类名**（用户能照着去配置里找到是哪一条）
         * ② 必须写明「尚未实现」（这是真话：这一类我们还没写）
         * ③ 不许再说「需要 Java 运行时」（假话：这条路根本不走 Java）
         * ```
         * ③ 比旧断言严格：旧断言只要求出现 "spider"，改文案也照样绿。
         */
        let csp_reason = reasons
            .iter()
            .find(|r| r.contains("csp_"))
            .unwrap_or_else(|| panic!("未实现的 csp 类必须如实进 skipped，实际 {reasons:?}"))
            .clone();
        assert!(
            csp_reason.contains("csp_DongLi"),
            "① reason 里必须带类名，实际 {csp_reason:?}"
        );
        assert!(
            csp_reason.ends_with("尚未实现"),
            "② reason 必须写明尚未实现，实际 {csp_reason:?}"
        );
        assert!(
            !csp_reason.contains("Java") && !csp_reason.contains("spider"),
            "③ ★ csp 类「不许」再用「需要 Java 运行时」那套说辞（那是另一条路的事），实际 {csp_reason:?}"
        );
        // type:0 那条仍走 skip_reason(Some(0))，文案不变
        assert!(
            reasons.iter().any(|r| r.contains("纯 JSON API")),
            "实际 {reasons:?}"
        );
    }

    #[test]
    fn collect_sites_reason_names_the_right_bucket() {
        // 同一份配置里同时存在「非 csp 的 type:3」与「csp 未实现」——
        // 两条 reason 必须**分别命中各自那一句**，不许互换
        let cfg = parse_loose_json(
            r#"{"sites":[
                {"key":"js","name":"某JS源","type":3,"api":"https://x.example/a.js"},
                {"key":"csp","name":"东篱","type":3,"api":"csp_DongLi"}
            ]}"#,
        )
        .unwrap();
        let (_, skipped, _) = collect_sites(&cfg, "");
        assert_eq!(skipped.len(), 2);
        let find = |name: &str| -> String {
            skipped
                .iter()
                .find(|s| s["name"] == name)
                .and_then(|s| s["reason"].as_str())
                .unwrap_or("")
                .to_string()
        };
        // 非 csp 的 type:3：JS/jar 那套，仍然要提 Java（这是真话）
        assert!(find("某JS源").contains("需要 Java 运行时"), "{}", find("某JS源"));
        // csp 未实现：只提类名，不提 Java
        assert_eq!(find("东篱"), "csp_DongLi 尚未实现");
    }

    #[test]
    fn collect_sites_resolves_relative_api_against_config_url() {
        let cfg = parse_loose_json(
            r#"{"sites":[{"name":"rel","type":1,"api":"/api.php/provide/vod"}]}"#,
        )
        .unwrap();
        let (jobs, _, _) = collect_sites(&cfg, "https://cfg.example.com/tvbox/cfg.json");
        assert_eq!(jobs[0].api, "https://cfg.example.com/api.php/provide/vod");
    }

    #[test]
    fn skip_reason_covers_known_types() {
        assert!(skip_reason(Some(3)).contains("Java"));
        assert!(skip_reason(Some(0)).contains("JSON API"));
        assert!(skip_reason(Some(4)).contains("其它"));
        assert!(skip_reason(Some(9)).contains("type=9"));
        assert!(skip_reason(None).contains("未声明"));

        /*
         * ── 第19项补充：这个函数**只**对「非 csp 的 type:3」负责 ──────────
         *
         * 下面三条守的是「两条判据没有互相渗透」这个不变量 ——
         * 光靠上面 `contains("Java")` 是锁不住的：
         * 如果有人图省事把 csp 分支也塞回 `skip_reason`，
         * 上面那条**仍然是绿的**（它只测函数本身），
         * 而用户会看到「csp_Bili 需要 Java 运行时」这种假话。
         */
        // ① 函数本身不该知道 csp 这回事（csp 文案唯一来源是 unimplemented_reason）
        let s3 = skip_reason(Some(3));
        assert!(
            !s3.contains("csp_") && !s3.contains("尚未实现"),
            "★ skip_reason 不许掺 csp 文案，实际 {s3:?}"
        );
        // ② csp 文案反过来也不许掺 Java
        let csp = crate::csp::unimplemented_reason("csp_DongLi");
        assert!(!csp.contains("Java") && !csp.contains("spider"), "实际 {csp:?}");
        // ③ 两者**逐字不同**：混用会立刻在导入报告里露出破绽
        assert_ne!(s3, csp);
    }

    #[test]
    fn provider_manifest_is_tvbox_kind() {
        let p = TvboxAppleCmsProvider::new(
            "demo",
            "示例",
            "https://a.com/api.php/provide/vod?ac=list",
            vec![TvboxCategoryEntry {
                id: "1".into(),
                name: "电影".into(),
                pid: None,
            }],
        )
        .expect("构造 Provider");
        let m = p.manifest();
        assert_eq!(m.kind, "tvbox");
        assert_eq!(m.id, "demo");
        assert!(m.capabilities.vod && m.capabilities.search);
        // 接口地址必须已归一化（不带查询串）
        assert_eq!(p.api, "https://a.com/api.php/provide/vod");
        assert_eq!(p.referer(), "https://a.com/");
    }

    #[test]
    fn provider_rejects_bad_api() {
        assert!(TvboxAppleCmsProvider::new("x", "x", "", vec![]).is_err());
        assert!(TvboxAppleCmsProvider::new("x", "x", "not-a-url", vec![]).is_err());
    }

    #[tokio::test]
    async fn provider_home_matches_classes() {
        let p = TvboxAppleCmsProvider::new(
            "demo",
            "示例",
            "https://a.com/api.php/provide/vod",
            (0..10)
                .map(|i| TvboxCategoryEntry {
                    id: format!("{i}"),
                    name: format!("分类{i}"),
                    pid: None,
                })
                .collect(),
        )
        .unwrap();
        let secs = MediaProvider::home(&p).await.unwrap();
        assert_eq!(secs.len(), HOME_SECTIONS, "首页最多 8 个区块");
        match &secs[0].source {
            SectionSource::Category { category_id } => assert_eq!(category_id, "0"),
            _ => panic!("应为分类区块"),
        }
        assert_eq!(secs[0].id, "demo-0");
        let cats = MediaProvider::categories(&p).await.unwrap();
        assert_eq!(cats.len(), 10);
        assert_eq!(cats[3].name, "分类3");
    }

    #[test]
    fn json_parse_url_reads_nested_shapes() {
        let j: serde_json::Value =
            serde_json::from_str(r#"{"code":200,"url":"https://q.iisfu.top/a.m3u8"}"#).unwrap();
        assert_eq!(json_parse_url(&j).unwrap(), "https://q.iisfu.top/a.m3u8");
        let j2: serde_json::Value =
            serde_json::from_str(r#"{"data":{"playUrl":"https://x/b.m3u8"}}"#).unwrap();
        assert_eq!(json_parse_url(&j2).unwrap(), "https://x/b.m3u8");
        // 失效解析服务的真实响应：没有 url 字段 → None（调用方 continue）
        let j3: serde_json::Value = serde_json::from_str(
            r#"{"code":"404","type":"hls","msg":"解析失败 https://api.huaqi.pro"}"#,
        )
        .unwrap();
        assert!(json_parse_url(&j3).is_none());
    }

    #[test]
    fn first_media_url_finds_link_in_text() {
        let t = "callback('https://cdn.example.com/x/index.m3u8?sign=1');";
        assert_eq!(
            first_media_url(t).unwrap(),
            "https://cdn.example.com/x/index.m3u8?sign=1"
        );
        assert!(first_media_url("no links here").is_none());
    }

    #[test]
    fn resolve_api_joins_relative() {
        assert_eq!(
            resolve_api("/api.php", "https://a.com/x/y.json").unwrap(),
            "https://a.com/api.php"
        );
        assert_eq!(
            resolve_api("api.php", "https://a.com/x/y.json").unwrap(),
            "https://a.com/x/api.php"
        );
        assert_eq!(
            resolve_api("https://b.com/api.php", "https://a.com/x.json").unwrap(),
            "https://b.com/api.php"
        );
        assert!(resolve_api("", "https://a.com/x.json").is_none());
        assert!(resolve_api("/api.php", "not-a-url").is_none());
    }
}

// ============================================================================
// imports_e2e —— TVBox 导入链路的宿主侧端到端测试
// ============================================================================
//
// 为什么单独开一个模块：上面的 mod tests 全是纯函数单测（解析/拼接/分类），
// 而这里要真的在 127.0.0.1 上起一个 HTTP 假服务、真的用 reqwest 发请求，
// 属于集成级验证；跟纯函数单测混在一起会让失败定位变模糊。
//
// ★ 本模块的两个测试都不碰公网、不碰用户数据、不写任何文件。
#[cfg(test)]
mod imports_e2e {
    use super::*;
    use axum::body::Body as AxumBody;
    use axum::http::{header, Request, StatusCode};
    use axum::response::{IntoResponse, Response};
    use axum::Router;

    fn reply(status: StatusCode, content_type: &str, body: &str) -> Response {
        Response::builder()
            .status(status)
            .header(header::CONTENT_TYPE, content_type)
            .body(AxumBody::from(body.to_string()))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
    }

    /// 取出原始（仍是百分号编码的）query 串。
    ///
    /// ★ 故意不做百分号解码：urlencoding 这个依赖只导出过 encode，decode 的可用性
    /// 没有验证过，所以这里只做「包含某个纯字母数字哨兵」的判断 —— 字母数字一定
    /// 不会被百分号编码，哨兵必然原样出现在 query 里。
    fn raw_query(req: &Request<AxumBody>) -> String {
        req.uri().query().unwrap_or("").to_string()
    }

    /// 假解析服务 A：按 page_url 里的哨兵返回不同形态的响应。
    ///
    /// 覆盖：JSON url / JSON data.playUrl / 非 JSON 原文 / 以 / 开头 /
    ///       含 error、placeholder、default.mp4 的坏地址 / HTTP 500 / 空 body。
    async fn parse_server_a(req: Request<AxumBody>) -> Response {
        let q = raw_query(&req);
        if q.contains("zjson1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"http://cdn.test/json/a.m3u8"}"#,
            );
        }
        if q.contains("zdata1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"data":{"playUrl":"http://cdn.test/data/b.m3u8"}}"#,
            );
        }
        if q.contains("ztext1") {
            return reply(
                StatusCode::OK,
                "text/plain",
                r#"window.__p = "http://cdn.test/raw/c/index.m3u8?sign=1";"#,
            );
        }
        if q.contains("zslash1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"/live/rel.m3u8"}"#,
            );
        }
        if q.contains("zerr1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"http://a.test/error.mp4"}"#,
            );
        }
        if q.contains("zph1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"http://a.test/placeholder.mp4"}"#,
            );
        }
        if q.contains("zdef1") {
            return reply(
                StatusCode::OK,
                "application/json",
                r#"{"url":"http://a.test/default.mp4"}"#,
            );
        }
        if q.contains("z500") {
            return reply(StatusCode::INTERNAL_SERVER_ERROR, "text/plain", "boom");
        }
        if q.contains("zempty") {
            return reply(StatusCode::OK, "application/json", "");
        }
        reply(StatusCode::NOT_FOUND, "text/plain", "nope")
    }

    /// 假解析服务 B：无论问什么都给一个能用的地址。
    ///
    /// 用来证明「A 的坏结果被 continue 掉之后，循环真的走到了第二个解析服务」。
    async fn parse_server_b(_req: Request<AxumBody>) -> Response {
        reply(
            StatusCode::OK,
            "application/json",
            r#"{"url":"http://b.test/ok.m3u8"}"#,
        )
    }

    async fn spawn_a() -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定假解析服务 A 失败");
        let port = listener.local_addr().expect("取端口失败").port();
        let app = Router::new().fallback(parse_server_a);
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        port
    }

    async fn spawn_b() -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("绑定假解析服务 B 失败");
        let port = listener.local_addr().expect("取端口失败").port();
        let app = Router::new().fallback(parse_server_b);
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        port
    }

    /// 源码断言：生产入口 try_parsers 必须只有一行委托，逻辑全在 try_parsers_with。
    ///
    /// 这条断言防的是「以后有人把解析逻辑再抄回 try_parsers」—— 那样公网
    /// PARSE_SERVICES 就会绕过下面那个测试缝，让 E2E 变成在测一个不存在的分支。
    #[test]
    fn production_entry_delegates_to_injectable_seam() {
        let src = include_str!("tvbox.rs");

        let start = src
            .find("async fn try_parsers(")
            .expect("tvbox.rs 里找不到 async fn try_parsers(");
        let rest = &src[start..];
        let end = rest
            .find("\n    }\n")
            .expect("找不到 try_parsers 的函数体结尾");
        let body = &rest[..end];

        assert!(
            body.contains("self.try_parsers_with(page_url, &PARSE_SERVICES).await"),
            "生产入口必须把 PARSE_SERVICES 原样交给 try_parsers_with，实际函数体：\n{body}"
        );
        assert!(
            !body.contains("bases"),
            "生产入口不该自己接 bases 参数，实际函数体：\n{body}"
        );
        assert!(
            !body.contains("for "),
            "生产入口不该自己写循环，实际函数体：\n{body}"
        );
        assert!(
            !body.contains("get_text"),
            "生产入口不该自己发请求，实际函数体：\n{body}"
        );

        // 缝的另一头必须真的有实现，而不是个空壳
        let start2 = src
            .find("async fn try_parsers_with(")
            .expect("tvbox.rs 里找不到 async fn try_parsers_with(");
        let rest2 = &src[start2..];
        let end2 = rest2
            .find("\n    }\n")
            .expect("找不到 try_parsers_with 的函数体结尾");
        let body2 = &rest2[..end2];

        assert!(
            body2.contains("for base in bases.iter()"),
            "try_parsers_with 必须按调用方给的解析服务列表循环，实际函数体：\n{body2}"
        );
        assert!(
            body2.contains("self.get_text(&u).await"),
            "try_parsers_with 必须真的发请求，实际函数体：\n{body2}"
        );
    }

    /// 用 127.0.0.1 上的两个假解析服务，把 try_parsers_with 的每条分支走一遍。
    ///
    /// ★ 被测的是 try_parsers_with —— 也就是生产入口 try_parsers 的唯一实现，
    /// 所以没有任何生产行为被测试代码改写，PARSE_SERVICES 仍然指向公网。
    #[tokio::test]
    async fn try_parsers_with_covers_every_branch() {
        let port_a = spawn_a().await;
        let port_b = spawn_b().await;
        let base_a = format!("http://127.0.0.1:{port_a}/p?u=");
        let base_b = format!("http://127.0.0.1:{port_b}/p?u=");
        let api = format!("http://127.0.0.1:{port_a}/api.php");
        let p = TvboxAppleCmsProvider::new("e2e-parse", "E2E 解析", &api, Vec::new())
            .expect("构造 TvboxAppleCmsProvider 失败");
        let bases: Vec<&str> = vec![base_a.as_str(), base_b.as_str()];
        let only_a: Vec<&str> = vec![base_a.as_str()];
        let page = |tag: &str| format!("http://page.test/{tag}.html");

        // ① 解析服务返回 JSON {"url": ...}
        assert_eq!(
            p.try_parsers_with(&page("zjson1"), &bases).await.as_deref(),
            Some("http://cdn.test/json/a.m3u8"),
            "JSON 的 url 字段应被直接采用"
        );

        // ② 解析服务返回 JSON {"data":{"playUrl": ...}}
        assert_eq!(
            p.try_parsers_with(&page("zdata1"), &bases).await.as_deref(),
            Some("http://cdn.test/data/b.m3u8"),
            "JSON 的 data.playUrl 字段应被采用"
        );

        // ③ 解析服务返回非 JSON 原文，里面埋着媒体直链
        assert_eq!(
            p.try_parsers_with(&page("ztext1"), &bases).await.as_deref(),
            Some("http://cdn.test/raw/c/index.m3u8?sign=1"),
            "非 JSON 原文应走 first_media_url 兜底"
        );

        // ④ 返回以 / 开头的地址 → 必须拼到解析服务自己的 origin 上（端口要保留）
        let expect_slash = format!("http://127.0.0.1:{port_a}/live/rel.m3u8");
        assert_eq!(
            p.try_parsers_with(&page("zslash1"), &only_a)
                .await
                .as_deref(),
            Some(expect_slash.as_str()),
            "以 / 开头的地址应拼到解析服务的 origin 上"
        );

        // ⑤⑥⑦ 坏地址（error / placeholder / default.mp4）必须被跳过，落到第二个解析服务
        assert_eq!(
            p.try_parsers_with(&page("zerr1"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "含 error 的地址应被跳过"
        );
        assert_eq!(
            p.try_parsers_with(&page("zph1"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "含 placeholder 的地址应被跳过"
        );
        assert_eq!(
            p.try_parsers_with(&page("zdef1"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "含 default.mp4 的地址应被跳过"
        );

        // ⑧ 第一个解析服务 HTTP 500 → 必须 continue 而不是 panic
        assert_eq!(
            p.try_parsers_with(&page("z500"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "解析服务 500 应被跳过"
        );

        // ⑨ 第一个解析服务返回空 body → 必须 continue
        assert_eq!(
            p.try_parsers_with(&page("zempty"), &bases).await.as_deref(),
            Some("http://b.test/ok.m3u8"),
            "解析服务返回空 body 应被跳过"
        );

        // ⑩ 所有解析服务都不可用 → None（不能 panic，也不能编一个地址出来）
        assert_eq!(
            p.try_parsers_with(&page("znone"), &only_a).await.as_deref(),
            None,
            "全部解析服务失败应返回 None"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// task5_ab_restart —— 本地封闭端到端：A/B 分支对照 + 解析服务 + 重启持久化
//
//   仪器：一个「原始 TCP 假服务」，同时充当假代理与假源站。
//     · http:// 目标经代理 → absolute-form GET，可观察到完整 URL；
//     · https:// 目标经代理 → CONNECT host:443，TLS 无法完成 → 回 502，
//       这正好落进 try_parsers_with 的「解析服务失败 → 换下一个」分支。
//   每条请求在回包【之前】先记账，所以计数不依赖最终 play_url 字符串，
//   也不需要真的连上外网或改一行生产代码。
//
//   A：分享页（无 m3u8）→ 必须真的请求两个解析服务（目标主机/状态码/字节数）
//   A 对照：分享页里已有 m3u8 → 解析服务请求数必须为 0
//   B：直链 .m3u8 → 在 tvbox.rs 的 .m3u8 短路判断处返回，总请求数 0
//   C：导入 → 二次 bootstrap（重启）后源仍在注册表
// ═══════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod task5_ab_restart {
    use super::*;
    use crate::model::{ErrorKind, MediaId, PlayRequest, StreamKind, TvboxCategoryEntry};
    use crate::provider::MediaProvider;
    use crate::proxy::{ProxyConfig, ProxyMode, ProxyStore};
    use crate::state::AppState;
    use std::io::{BufRead, BufReader, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::{Arc, Mutex};

    // ── 应答体 ────────────────────────────────────────────────────────────
    /// 分享页：全篇不含引号 ⇒ extract_m3u8 的引号扫描一个都找不到 ⇒ None。
    pub(super) const SHARE_PLAIN: &str =
        "<!doctype html><html><head><title>分享页</title></head><body><div id=app>请下载客户端观看</div></body></html>";
    /// 对照分享页：引号里就有一个 m3u8。
    const SHARE_WITH_M3U8: &str =
        "<html><body><script>var s = \"http://cdn.control/ctrl/index.m3u8?sign=9\";</script></body></html>";
    /// 模拟 huaqi 那种「200 但解析失败」的应答（无任何可播放字段）。
    const DEAD_BODY: &str = "{\"code\":\"404\",\"type\":\"hls\",\"msg\":\"解析失败 https://api.huaqi.pro\"}";
    /// 模拟还活着的解析服务。
    const OK_BODY: &str = "{\"url\":\"http://cdn.test/real/ok.m3u8\"}";
    const CLASS_BODY: &str = "{\"class\":[{\"type_id\":\"1\",\"type_name\":\"电影\"}]}";
    const LIST_BODY: &str =
        "{\"page\":1,\"pagecount\":1,\"total\":1,\"list\":[{\"vod_id\":\"1001\",\"vod_name\":\"测试片\"}]}";
    /// task-12：一份**多仓**配置（只有 urls，没有 sites）。
    ///
    /// 用它验证两件事：
    /// ```text
    /// ① import_tvbox_config 不再把它当"错误" —— 而是结构化返回 repos
    /// ② 相对地址（/cfg/sub.json）按配置自身的链接补全成绝对地址
    /// ```
    const MULTI_REPO_BODY: &str =
        "{\"urls\":[{\"name\":\"子仓甲\",\"url\":\"/cfg/sub.json\"},{\"name\":\"子仓乙\",\"url\":\"http://other.test/b.json\"}]}";
    /// task-12：一份**含 sites** 的配置（两个 type=1 站）。
    ///
    /// ⚠️ api 占位符 API_PLACEHOLDER 在运行时被替换成假源站地址 ——
    ///    常量里没法知道端口，所以只能这样。
    const CFG_V2_BODY: &str =
        "{\"sites\":[{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"@@API1@@\"},{\"key\":\"k3\",\"name\":\"丙站\",\"type\":1,\"api\":\"@@API3@@\"}]}";
    /// task-12：第 3 版配置 —— k1 **换了接口**（→ changed），k3 没变，k2 仍缺席。
    const CFG_V3_BODY: &str =
        "{\"sites\":[{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"@@API9@@\"},{\"key\":\"k3\",\"name\":\"丙站\",\"type\":1,\"api\":\"@@API3@@\"}]}";

    // task-12：本模块的假源站要被 task12_subscription 复用（真发 HTTP），
    //          所以可见性从私有放宽到 pub(super)。
    #[derive(Debug, Clone)]
    pub(super) struct Hit {
        pub(super) method: String,
        pub(super) target: String,
        pub(super) status: u16,
        pub(super) bytes: usize,
    }

    pub(super) struct Sink {
        port: u16,
        hits: Arc<Mutex<Vec<Hit>>>,
    }

    impl Sink {
        pub(super) fn url(&self) -> String {
            format!("http://127.0.0.1:{}", self.port)
        }
        pub(super) fn hits(&self) -> Vec<Hit> {
            self.hits.lock().map(|g| g.clone()).unwrap_or_default()
        }
        fn count_method(&self, m: &str) -> usize {
            self.hits()
                .iter()
                .filter(|h| h.method.eq_ignore_ascii_case(m))
                .count()
        }
        pub(super) fn lines(&self) -> Vec<String> {
            self.hits()
                .into_iter()
                .map(|h| format!("{} {} -> {} ({} bytes)", h.method, h.target, h.status, h.bytes))
                .collect()
        }
    }

    fn status_text(s: u16) -> &'static str {
        match s {
            200 => "OK",
            404 => "Not Found",
            502 => "Bad Gateway",
            _ => "Unknown",
        }
    }

    /// 把 absolute-form（代理）与 origin-form（直连）统一成 path?query。
    fn path_of(target: &str) -> &str {
        let after_scheme = match target.find("://") {
            Some(i) => &target[i + 3..],
            None => target,
        };
        match after_scheme.find('/') {
            Some(i) => &after_scheme[i..],
            None => "/",
        }
    }

    fn route(target: &str, share: &str, host: &str) -> (u16, String, &'static str) {
        let pq = path_of(target);
        if pq.starts_with("/share") {
            (200, share.to_string(), "text/html; charset=utf-8")
        } else if pq.starts_with("/pdead") {
            (200, DEAD_BODY.to_string(), "application/json")
        } else if pq.starts_with("/pok") {
            (200, OK_BODY.to_string(), "application/json")
        } else if pq.contains("ac=list") {
            (200, CLASS_BODY.to_string(), "application/json")
        } else if pq.contains("ac=videolist") {
            (200, LIST_BODY.to_string(), "application/json")
        } else if pq.starts_with("/cfg") {
            // task-12：假的 TVBox 配置 —— 订阅链接指向它
            // api 占位符换成**请求里带的 Host** —— 常量里不知道端口
            let base = format!("http://{host}");
            let plain_v2 = || {
                CFG_V2_BODY
                    .replace("@@API1@@", &format!("{base}/api.php/provide/vod"))
                    .replace("@@API3@@", &format!("{base}/api3/vod"))
            };
            let body = if pq.contains("/cfg/v2b64.json") {
                // 血缘批次（2026-11-01）：同一份 v2 配置但套 base64** 包裹
                //（真链接 https://8815.kstore.vip/tvbox/wmz 的实抓形态）
                format!(
                    "YmFzZTY0**{}",
                    crate::csp::shared::b64_encode(plain_v2().as_bytes())
                )
            } else if pq.contains("/cfg/v2.json") {
                plain_v2()
            } else if pq.contains("/cfg/v3.json") {
                CFG_V3_BODY
                    .replace("@@API9@@", &format!("{base}/api9/vod"))
                    .replace("@@API3@@", &format!("{base}/api3/vod"))
            } else {
                MULTI_REPO_BODY.to_string()
            };
            (200, body, "application/json")
        } else {
            (404, "{\"error\":\"not found in fake sink\"}".to_string(), "application/json")
        }
    }

    fn handle(stream: &mut TcpStream, share: &str, hits: &Arc<Mutex<Vec<Hit>>>) -> std::io::Result<()> {
        let mut reader = BufReader::new(stream.try_clone()?);
        let mut request_line = String::new();
        if reader.read_line(&mut request_line)? == 0 {
            return Ok(());
        }
        let request_line = request_line.trim_end().to_string();
        // 排空请求头，避免客户端还在写就把连接关掉（会变成 RST）
        // ★ task-12：顺手记下 Host —— 假配置里的 api 要用它拼成绝对地址
        let mut host = String::new();
        loop {
            let mut line = String::new();
            if reader.read_line(&mut line)? == 0 {
                break;
            }
            if line == "\r\n" || line == "\n" {
                break;
            }
            let low = line.to_ascii_lowercase();
            if let Some(rest) = low.strip_prefix("host:") {
                host = rest.trim().to_string();
            }
        }
        let mut parts = request_line.split(' ');
        let method = parts.next().unwrap_or("").to_string();
        let target = parts.next().unwrap_or("").to_string();

        let (status, body, ctype) = if method.eq_ignore_ascii_case("CONNECT") {
            (502u16, "fake sink: CONNECT refused\n".to_string(), "text/plain")
        } else {
            route(&target, share, &host)
        };

        // ★ 先记账，再回包：收到即计数，不依赖客户端读成功与否
        if let Ok(mut g) = hits.lock() {
            g.push(Hit { method: method.clone(), target: target.clone(), status, bytes: body.len() });
        }

        let head = format!(
            "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            status,
            status_text(status),
            ctype,
            body.len()
        );
        stream.write_all(head.as_bytes())?;
        stream.write_all(body.as_bytes())?;
        stream.flush()?;
        Ok(())
    }

    pub(super) fn start_sink(share: &'static str) -> Sink {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定假服务端口失败");
        let port = listener.local_addr().expect("取端口失败").port();
        let hits = Arc::new(Mutex::new(Vec::new()));
        let hits_bg = hits.clone();
        std::thread::spawn(move || {
            for conn in listener.incoming() {
                match conn {
                    Ok(mut stream) => {
                        let h = hits_bg.clone();
                        let _ = handle(&mut stream, share, &h);
                    }
                    Err(_) => break,
                }
            }
        });
        Sink { port, hits }
    }

    fn make_provider(id: &str, api: &str) -> TvboxAppleCmsProvider {
        TvboxAppleCmsProvider::new(
            id,
            "假CMS",
            api,
            vec![TvboxCategoryEntry { id: "1".to_string(), name: "电影".to_string(), pid: None }],
        )
        .expect("构造 TvboxAppleCmsProvider 失败")
    }

    fn proxied(id: &str, api: &str, sink: &Sink) -> TvboxAppleCmsProvider {
        let store = Arc::new(ProxyStore::new());
        store
            .set(
                id,
                ProxyConfig { mode: ProxyMode::Custom, url: Some(sink.url()), ..Default::default() },
            )
            .expect("配置测试代理失败");
        make_provider(id, api).with_proxy(store)
    }

    pub(super) fn unique_tmp_dir(tag: &str) -> std::path::PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        std::env::temp_dir().join(format!("sourin-task5-{tag}-{}-{nanos}", std::process::id()))
    }

    /// 把仪器记录原样打到 stdout —— 报告里的「真实读数」直接来自这些行。
    pub(super) fn dump_hits(tag: &str, hits: &[Hit]) {
        println!("[EVIDENCE] {tag} hit_count={}", hits.len());
        for (i, h) in hits.iter().enumerate() {
            println!(
                "[EVIDENCE] {tag} #{i} method={} target={} status={} bytes={}",
                h.method, h.target, h.status, h.bytes
            );
        }
    }

    // ── ① 生产代码接缝必须还在（防有人在跑之前把这几个点改掉） ───────────
    #[test]
    fn seam_pins_are_intact() {
        let src = include_str!("tvbox.rs");
        let head = src.split("mod task5_ab_restart").next().expect("split 失败");
        let count = |n: &str| head.matches(n).count();
        /*
         * ⚠️ 这里**不再**写死「2 个解析服务」。2026-10-10 删掉了 `api.huaqi.pro`
         *    那条 —— 它是一个被硬编码进公开仓库的**真实付费凭据**，而且
         *    本文件上方注释自己就写着它自 2026-10-02 起已失效（返回 404）。
         *    真正的判据是**形状**：这个数组还在、且非空。
         *    （写成 `count("PARSE_SERVICES: [&str; 2]")` 的话，以后每加删一个
         *    服务都要改这里 —— 而「加服务」本是正常需求，不该被门禁挡住。）
         */
        assert_eq!(
            count("pub const PARSE_SERVICES: &[&str] = &["),
            1,
            "PARSE_SERVICES 应仍声明在生产代码里"
        );
        assert!(
            !PARSE_SERVICES.is_empty(),
            "★ 解析服务列表不能为空 —— 空的话任何非 m3u8 的地址都解析不出来"
        );
        assert_eq!(count("if !url.to_lowercase().contains(\".m3u8\") {"), 1, "resolve 里的 .m3u8 短路判断应存在且唯一");
        assert_eq!(count("found = self.try_parsers(&page_url).await;"), 1, "resolve 必须真的走到 try_parsers");
        for svc in PARSE_SERVICES {
            assert_eq!(
                count(svc),
                1,
                "解析服务 {svc} 应在生产代码里出现且唯一"
            );
        }
        /*
         * ★ 反面判据：凭据不许再回到代码里（2026-10-10 的安全事故）。
         *   挡的是「把 key 又硬编码回来」—— 那种改动编译通过、测试全绿，
         *   但凭据又泄露一次。
         *
         * ⚠️ 两个坑（都是实测踩的）：
         *  ① 只查 `huaqi` 这个**词**会判红 —— 上方那段解释「为什么删掉它」的
         *     注释里就写着那个域名。
         *  ② 查完整的 URL 形状同样会判红 —— **连注释里那句「该域名 + key=」
         *     都会被匹配到**。注意这里踩的是块注释：`/** */` 的续行以 ` * ` 开头，
         *     逐行剥 `//` 或 `///` 都识别不到它（实测：判据改了三版才绿）。
         * ⇒ 干脆不查 URL 形状，只查**那个 key 的数字片段**，并且运行时拼出来
         *    —— 注释里提到「已移除」时不可能恰好带上那串数字。
         */
        let bad_url: String = ["api.huaqi", ".pro/api/"].concat();
        assert!(
            !src.contains(&bad_url),
            "★ 硬编码的第三方付费凭据不许再出现（2026-10-10 已移除：它既不安全也早已失效）"
        );
        // 那个具体 key 的片段**在运行时拼出来** —— 否则这条断言会匹配到它自己
        // 源码里的那个字面量，把自己判红（实测踩过）。
        let key_needle: String = ["key=", "5bd0", "db7c858"].concat();
        assert!(
            !src.contains(&key_needle),
            "★ 那个具体凭据不许再出现在代码里"
        );
    }

    // ── ② A：分享页（无 m3u8）必须真的请求**每一个**解析服务 ───────────────
    #[tokio::test]
    async fn a_share_page_reaches_parse_services_with_counted_requests() {
        let sink = start_sink(SHARE_PLAIN);
        let id = "task5-ab-a";
        let p = proxied(id, "http://cms.test/api.php/provide/vod", &sink);
        let page = "http://cms.test/share/55b41404d256c30aeee0e2c554dc43f6".to_string();

        let got = p.resolve(&MediaId::new(id, page.clone()), &PlayRequest::default()).await;

        let hits = sink.hits();
        dump_hits("A-share-page-no-m3u8(real PARSE_SERVICES via proxy)", &hits);
        let g = hits.iter().find(|h| h.method == "GET").expect("缺少分享页 GET");
        assert!(g.target.contains("/share/"), "分享页 GET 目标不对：{}", g.target);
        assert_eq!(g.status, 200, "分享页应回 200");
        assert_eq!(g.bytes, SHARE_PLAIN.len(), "分享页字节数应等于服务端应答体长度");

        /*
         * ⚠️ 断言「**每一个**已配置的服务都被真实请求」，而不是「恰好 N 条」。
         *    （2026-10-10 删掉 huaqi 后，原来写死的 3 条 / 2 个 CONNECT 就��红了。）
         *    这样以后增删解析服务都不必改这里，而「配置了却不请求」这个缺陷
         *    仍然会被抓住。
         */
        let targets: Vec<String> =
            hits.iter().filter(|h| h.method == "CONNECT").map(|h| h.target.clone()).collect();
        assert_eq!(
            targets.len(),
            PARSE_SERVICES.len(),
            "每个已配置的解析服务都必须被真实请求，实际：{:?}",
            sink.lines()
        );
        for svc in PARSE_SERVICES {
            let host = svc
                .split("://")
                .nth(1)
                .and_then(|r| r.split('/').next())
                .expect("服务地址应形如 https://host/path");
            assert!(
                targets.iter().any(|t| t == &format!("{host}:443")),
                "应请求 {host}，实际 {targets:?}"
            );
        }
        for h in hits.iter().filter(|h| h.method == "CONNECT") {
            assert_eq!(h.status, 502, "CONNECT 应被假服务用 502 拒掉：{}", h.target);
            assert!(h.bytes > 0, "CONNECT 也应有真实回包字节：{}", h.target);
        }

        let e = got.expect_err("分享页刮不出 m3u8 且解析服务全挂，必须报错");
        assert_eq!(e.kind, ErrorKind::Unsupported, "kind 应为 Unsupported，实际 {:?}：{}", e.kind, e.message);
        assert!(e.message.contains("这个源没有可直接播放的地址"), "message 实际：{}", e.message);
        assert!(!e.message.contains("某长视频站"), "cms.test 不含第三方站点关键词，不该走那句文案：{}", e.message);
    }

    // ── ③ A 对照：分享页里已有 m3u8 ⇒ 解析服务请求数必须为 0 ──────────────
    #[tokio::test]
    async fn a_control_share_page_with_m3u8_never_touches_parse_services() {
        let sink = start_sink(SHARE_WITH_M3U8);
        let id = "task5-ab-a-ctl";
        let p = proxied(id, "http://cms.test/api.php/provide/vod", &sink);

        let got = p
            .resolve(
                &MediaId::new(id, "http://cms.test/share/55b41404d256c30aeee0e2c554dc43f6".to_string()),
                &PlayRequest::default(),
            )
            .await
            .expect("分享页里能刮出 m3u8，应成功");

        let hits = sink.hits();
        dump_hits("A-control-share-page-with-m3u8", &hits);
        assert_eq!(hits.len(), 1, "只该有 1 条分享页请求，实际：{:?}", sink.lines());
        assert_eq!(sink.count_method("CONNECT"), 0, "页面里已经有 m3u8，不该再请求解析服务：{:?}", sink.lines());
        assert_eq!(got.len(), 1);
        assert!(got[0].url.contains("cdn.control"), "刮出的地址应来自页面，实际 {}", got[0].url);
        assert!(got[0].url.contains(".m3u8"), "实际 {}", got[0].url);
        assert_eq!(got[0].kind, StreamKind::Hls);
    }

    // ── ④ B：直链 .m3u8 短路，总请求数 0（与 A 的 3 条构成反转） ──────────
    #[tokio::test]
    async fn b_direct_m3u8_short_circuits_with_zero_requests() {
        let sink = start_sink(SHARE_PLAIN); // 与 A 完全相同的仪器，且已挂上
        let id = "task5-ab-b";
        let p = proxied(id, "http://cms.test/api.php/provide/vod", &sink);
        let direct = "http://cms.test/live/direct/x.m3u8".to_string();

        let got = p
            .resolve(&MediaId::new(id, direct.clone()), &PlayRequest::default())
            .await
            .expect("直链 m3u8 应直接成功");

        let hits = sink.hits();
        dump_hits("B-direct-m3u8-short-circuit", &hits);
        assert_eq!(hits.len(), 0, "B 必须零请求（A 是 3 条），实际：{:?}", sink.lines());
        assert_eq!(sink.count_method("CONNECT"), 0, "B 绝不能碰解析服务");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].url, direct, "直链必须原样返回");
        assert_eq!(got[0].kind, StreamKind::Hls);
    }

    // ── ⑤ 解析服务：第一个挂（200 但解析失败）→ 换第二个 → 拿到真地址 ──────
    #[tokio::test]
    async fn parse_service_failure_then_success_returns_real_url() {
        let sink = start_sink(SHARE_PLAIN);
        let p = make_provider("task5-ab-parse", "http://cms.test/api.php/provide/vod");
        let dead = format!("{}/pdead?u=", sink.url());
        let ok = format!("{}/pok?u=", sink.url());

        let got = p.try_parsers_with("http://cms.test/share/xxx", &[dead.as_str(), ok.as_str()]).await;
        assert_eq!(got.as_deref(), Some("http://cdn.test/real/ok.m3u8"), "第二个解析服务应被采纳，实际 {got:?}");

        let hits = sink.hits();
        dump_hits("parse-service-fail-then-ok", &hits);
        assert_eq!(hits.len(), 2, "两个解析服务都应被真实请求，实际：{:?}", sink.lines());
        assert!(hits[0].target.contains("/pdead?u="), "第 1 条应是死接口，实际 {}", hits[0].target);
        assert_eq!(hits[0].status, 200);
        assert_eq!(hits[0].bytes, DEAD_BODY.len(), "死接口也要有真实回包字节（200 但无 url 字段）");
        assert!(hits[1].target.contains("/pok?u="), "第 2 条应是可用接口，实际 {}", hits[1].target);
        assert_eq!(hits[1].status, 200);
        assert_eq!(hits[1].bytes, OK_BODY.len());
    }

    // ── ⑥ C：导入 → 重启（同一数据目录二次 bootstrap）后源还在 ─────────────
    #[tokio::test]
    async fn c_import_then_restart_keeps_the_source() {
        // 保险：别让 bootstrap 里的远程自启去等 8642 端口
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");

        let sink = start_sink(SHARE_PLAIN);
        let dir = unique_tmp_dir("c");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");

        let cfg = format!(
            "{{\"sites\":[{{\"key\":\"cms1\",\"name\":\"假CMS\",\"type\":1,\"api\":\"{}/api.php/provide/vod\"}}]}}",
            sink.url()
        );

        let st = AppState::bootstrap(dir.clone()).await.expect("首次 bootstrap 失败");
        let res = import_tvbox_config(&st, &cfg).await.expect("导入失败");
        println!("[EVIDENCE] C-import-result {res}");
        assert_eq!(res["totalSites"], 1u64, "实际 {res}");
        assert_eq!(
            res["imported"].as_array().map(|a| a.len()).unwrap_or(0),
            1,
            "应导入 1 个源（探测失败会进 skipped），实际 {res}"
        );
        let id = res["imported"][0]["id"].as_str().unwrap_or_default().to_string();
        assert!(!id.is_empty(), "导入结果必须带 id，实际 {res}");

        let live = st
            .registry
            .manifests()
            .into_iter()
            .find(|m| m.kind == "tvbox" && m.name == "假CMS")
            .expect("导入当场注册表里就该有这个源");
        assert_eq!(live.id, id, "导入结果里的 id 应与注册表一致");
        assert!(live.working, "刚导入的源应可用");
        println!(
            "[EVIDENCE] C-after-import id={} kind={} name={} working={}",
            live.id, live.kind, live.name, live.working
        );

        let file = crate::persist::providers_file(&dir);
        assert!(file.exists(), "第三方源清单应已落盘：{}", file.display());
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        println!("[EVIDENCE] C-persisted-file {} bytes={}", file.display(), text.len());
        println!("[EVIDENCE] C-persisted-body {text}");
        assert!(text.contains(&id), "清单文件应记录 {id}，实际内容：{text}");
        drop(st);

        // 重启
        let st2 = AppState::bootstrap(dir.clone()).await.expect("重启 bootstrap 失败");
        let again = st2
            .registry
            .manifests()
            .into_iter()
            .find(|m| m.id == id)
            .expect("重启后源应仍在注册表里");
        assert_eq!(again.kind, "tvbox");
        assert_eq!(again.name, "假CMS");
        assert!(again.working, "重启恢复的源应仍为可用状态");
        println!(
            "[EVIDENCE] C-after-restart id={} kind={} name={} working={}",
            again.id, again.kind, again.name, again.working
        );
        drop(st2);

        let _ = std::fs::remove_dir_all(&dir);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  task12_subscription —— TVBox 订阅链接 + 检测更新的端到端测试
// ═══════════════════════════════════════════════════════════════════════════
//
// 与 task5_ab_restart 的区别：
// ```text
// task5   验证「解析 / 播放」链路（假解析服务 + 假源站）
// task12  验证「订阅 / 检测更新」链路（假源站当配置宿主，真发 HTTP）
// ```
// ★ 全部走 127.0.0.1，不碰公网、不碰用户数据目录（unique_tmp_dir）。
#[cfg(test)]
mod task12_subscription {
    use super::*;
    use crate::state::AppState;

    /// 本地已注册的 TVBox 源（按 id 查，返回 (id,name,api)）
    fn local_of(st: &AppState, id: &str) -> Option<(String, String, String)> {
        st.third_party
            .read()
            .ok()?
            .iter()
            .find_map(|x| match x {
                crate::model::PersistedProvider::Tvbox { id: pid, name, api, .. }
                    if pid == id =>
                {
                    Some((pid.clone(), name.clone(), api.clone()))
                }
                _ => None,
            })
    }

    fn remote(key: &str, name: &str, api: &str) -> RemoteSite {
        remote_ext(key, name, api, None)
    }

    /// 带 ext 的远端站（task-42：diff 要比 ext）
    fn remote_ext(key: &str, name: &str, api: &str, ext: Option<&str>) -> RemoteSite {
        RemoteSite {
            key: key.to_string(),
            name: name.to_string(),
            api: api.to_string(),
            ext: ext.map(|s| s.to_string()),
        }
    }

    fn local(id: &str, key: &str, name: &str, api: &str) -> LocalSite {
        local_ext(id, key, name, api, None)
    }

    /// 带 ext 的本地站
    fn local_ext(id: &str, key: &str, name: &str, api: &str, ext: Option<&str>) -> LocalSite {
        LocalSite {
            id: id.to_string(),
            key: key.to_string(),
            name: name.to_string(),
            api: api.to_string(),
            ext: ext.map(|s| s.to_string()),
            // 单测默认都是"本订阅的"
            in_link: true,
        }
    }

    /// 假源站上「能通过探测」的 api 地址
    fn fake_api(sink: &super::task5_ab_restart::Sink) -> String {
        format!("{}/api.php/provide/vod", sink.url())
    }

    // ── ① 纯函数：diff_sites 的配对规则 ──────────────────────────────────
    #[test]
    fn diff_pairs_by_key_then_api_and_never_hides_removed() {
        let l = vec![
            local("a", "k1", "甲", "http://a.test/vod"),
            local("b", "k2", "乙", "http://b.test/vod"),
            // 老数据：没有 key，只能靠 api 认
            local("c", "", "丙", "http://c.test/vod"),
        ];
        let r = vec![
            // k1 还在，但换了接口和名字 → changed
            remote("k1", "甲（新）", "http://a2.test/vod"),
            // k2 没了 → removed（只在本地）
            // c 靠 api 配上 → unchanged
            remote("", "丙", "http://c.test/vod"),
            // 新增
            remote("k9", "丁", "http://d.test/vod"),
        ];
        let d = diff_sites(&l, &r);
        println!(
            "[EVIDENCE] T12-diff added={:?} removed={:?} changed={:?} unchanged={}",
            d.added.iter().map(|x| &x.name).collect::<Vec<_>>(),
            d.removed.iter().map(|x| &x.name).collect::<Vec<_>>(),
            d.changed
                .iter()
                .map(|x| format!("{} -> {}", x.old_api, x.new_api))
                .collect::<Vec<_>>(),
            d.unchanged
        );
        assert_eq!(d.added.len(), 1, "应识别 1 个新增");
        assert_eq!(d.added[0].name, "丁");
        assert_eq!(d.removed.len(), 1, "应识别 1 个消失");
        assert_eq!(d.removed[0].id, "b", "消失的应是 k2（乙）");
        assert_eq!(d.changed.len(), 1, "应识别 1 个变更");
        assert_eq!(d.changed[0].id, "a", "变更的应是 k1（甲）");
        assert_eq!(d.changed[0].old_api, "http://a.test/vod");
        assert_eq!(d.changed[0].new_api, "http://a2.test/vod");
        assert_eq!(d.unchanged, 1, "丙 应算没变");
        assert_eq!(d.added_idx, vec![2], "新增在远端列表里的下标应为 2");
        assert_eq!(d.changed_idx, vec![0], "变更在远端列表里的下标应为 0");
    }

    /// ⚠️ 归一化：...vod?ac=list 与 ...vod 是**同一个站**，不能报成新增+消失。
    #[test]
    fn diff_normalizes_api_query_string() {
        let l = vec![local("a", "", "甲", "https://a.test/api.php/provide/vod")];
        let r = vec![remote("", "甲", "https://a.test/api.php/provide/vod?ac=list")];
        let d = diff_sites(&l, &r);
        println!(
            "[EVIDENCE] T12-normalize added={} removed={} changed={} unchanged={}",
            d.added.len(),
            d.removed.len(),
            d.changed.len(),
            d.unchanged
        );
        assert!(d.added.is_empty(), "不该报新增（只是带了 ?ac=list）：{:?}", d.added);
        assert!(d.removed.is_empty(), "不该报消失：{:?}", d.removed);
        assert_eq!(d.unchanged, 1);
    }

    /// 站换了域名但 key 没变 → 必须是 changed，而不是「新增 + 消失」。
    #[test]
    fn diff_same_key_new_domain_is_changed_not_added_and_removed() {
        let l = vec![local("a", "k1", "甲", "https://old.test/vod")];
        let r = vec![remote("k1", "甲", "https://new.test/vod")];
        let d = diff_sites(&l, &r);
        assert_eq!(d.added.len(), 0, "换域名不该算新增");
        assert_eq!(d.removed.len(), 0, "换域名不该算消失");
        assert_eq!(d.changed.len(), 1);
        assert_eq!(d.changed[0].id, "a", "必须沿用原 id，否则用户设过的启用状态会丢");
    }

    // ── ② 纯函数：多仓子仓清单 ───────────────────────────────────────────
    #[test]
    fn multi_repo_repos_accepts_objects_and_strings_and_absolutizes() {
        let cfg: serde_json::Value = serde_json::json!({
            "urls": [
                {"name": "子仓甲", "url": "/cfg/sub.json"},
                {"url": "https://b.test/x.json"},
                "https://c.test/y.json"
            ]
        });
        let repos = multi_repo_repos(&cfg, "https://host.test/config.json");
        println!("[EVIDENCE] T12-repos {repos:?}");
        assert_eq!(repos.len(), 3, "两种形态都要收：{repos:?}");
        assert_eq!(repos[0]["name"], "子仓甲");
        assert_eq!(repos[0]["url"], "https://host.test/cfg/sub.json", "相对地址要按配置链接补全");
        assert_eq!(repos[1]["url"], "https://b.test/x.json");
        assert_eq!(repos[1]["name"], "https://b.test/x.json", "没写 name 就用地址兜底");
        assert_eq!(repos[2]["url"], "https://c.test/y.json", "纯字符串形态也要收");
    }

    // ── ③ 端到端：文本导入 → 补链接 → 落盘 → 重启仍在 ───────────────────
    #[tokio::test]
    async fn e2e_subscription_survives_restart() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
        let api = fake_api(&sink);
        let dir = super::task5_ab_restart::unique_tmp_dir("t12a");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");

        let cfg = format!(
            "{{\"sites\":[\
               {{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"{api}\"}},\
               {{\"key\":\"k2\",\"name\":\"乙站\",\"type\":1,\"api\":\"{api}\"}}\
             ]}}"
        );

        let st = AppState::bootstrap(dir.clone()).await.expect("首次 bootstrap 失败");
        // ── ③-1 贴**文本**导入：没有链接可查 ──────────────────────────
        let res = import_tvbox_config(&st, &cfg).await.expect("文本导入失败");
        println!("[EVIDENCE] T12-import-text {res}");
        assert_eq!(res["imported"].as_array().map(|a| a.len()), Some(2), "应导入 2 个源");

        let listed = list_tvbox_sources(&st).expect("列出源失败");
        println!("[EVIDENCE] T12-list-after-text-import {listed}");
        assert_eq!(listed["total"], 2u64);
        assert_eq!(
            listed["withSource"],
            0u64,
            "贴文本导入的源不该有订阅链接（没有的能力不假装有）"
        );
        // ★ site key 是**导入那一刻**就知道的事实（来自 sites[]），
        //   与"有没有链接"无关 —— 必须记，否则事后补链接时配对只能退化成
        //   按 api 认，"换了域名"就会被误报成「新增 + 消失」。
        assert!(
            listed["sources"]
                .as_array()
                .map(|a| a.iter().all(|x| x["siteKey"] != ""))
                .unwrap_or(false),
            "site key 必须随导入一起记下来：{listed}"
        );
        assert!(
            listed["sources"]
                .as_array()
                .map(|a| a
                    .iter()
                    .all(|x| x["needsSource"] == serde_json::Value::Bool(true)))
                .unwrap_or(false),
            "每个源都该如实标 needsSource=true：{listed}"
        );

        let checked0 = check_tvbox_updates(&st, None).await.expect("检测不该报错");
        println!("[EVIDENCE] T12-check-no-source {checked0}");
        assert_eq!(checked0["checked"], 0u64, "没有链接 → 一个链接都不查");
        assert_eq!(checked0["skipped"], 2u64, "两个源都如实进 skipped");
        assert_eq!(checked0["items"].as_array().map(|a| a.len()), Some(0), "不该产出任何条目");

        // ── ③-2 事后补一个订阅链接（set_tvbox_source）─────────────────
        let first_id = res["imported"][0]["id"].as_str().unwrap_or_default().to_string();
        let second_id = res["imported"][1]["id"].as_str().unwrap_or_default().to_string();
        assert!(!first_id.is_empty() && !second_id.is_empty(), "导入结果必须带 id：{res}");
        let cfg_url = format!("{}/cfg/sub.json", sink.url());
        let set = set_tvbox_source(&st, &first_id, &cfg_url).expect("补链接失败");
        println!("[EVIDENCE] T12-set-source {set}");
        assert_eq!(set["sourceUrl"], cfg_url);

        let listed2 = list_tvbox_sources(&st).expect("列出源失败");
        assert_eq!(listed2["withSource"], 1u64, "补完链接后应有 1 个源有链接：{listed2}");

        // 非法链接要如实拒绝
        let bad = set_tvbox_source(&st, &first_id, "not-a-url");
        assert!(bad.is_err(), "非 http 链接应被拒绝：{bad:?}");
        assert!(bad.unwrap_err().contains("http"), "错误文案要说清楚");

        // ── ③-3 链接指向**多仓** → 检测如实报告，不硬凑 ────────────────
        let chk_multi = check_tvbox_updates(&st, None).await.expect("检测失败");
        println!("[EVIDENCE] T12-check-multirepo {chk_multi}");
        assert_eq!(chk_multi["checked"], 1u64, "只该查 1 个链接");
        let item = &chk_multi["items"][0];
        assert_eq!(item["ok"], serde_json::Value::Bool(false), "多仓链接应如实标 ok=false");
        assert_eq!(item["multiRepo"], serde_json::Value::Bool(true), "应标出这是多仓");
        let repos = item["repos"].as_array().cloned().unwrap_or_default();
        assert_eq!(repos.len(), 2, "应列出 2 个子仓：{item}");
        assert_eq!(repos[0]["url"], format!("{}/cfg/sub.json", sink.url()), "相对地址要补全");
        assert_eq!(repos[0]["name"], "子仓甲");
        assert_eq!(repos[1]["name"], "子仓乙");
        assert!(
            item["error"].as_str().unwrap_or("").contains("多仓"),
            "错误文案要说清楚为什么查不了：{item}"
        );
        let hits_cfg = sink.hits();
        super::task5_ab_restart::dump_hits("T12-check-multirepo", &hits_cfg);
        assert!(
            hits_cfg.iter().any(|h| h.target.contains("/cfg/sub.json")),
            "必须真的发过 GET 去下载配置：{:?}",
            sink.lines()
        );

        // ── ③-4 多仓配置**导入**：不再报错，而是列出子仓供选择 ──────────
        let res_multi = import_tvbox_config(&st, &cfg_url).await.expect("多仓导入不该失败");
        println!("[EVIDENCE] T12-import-multirepo {res_multi}");
        assert_eq!(res_multi["multiRepo"], serde_json::Value::Bool(true), "应标 multiRepo=true");
        assert_eq!(
            res_multi["imported"].as_array().map(|a| a.len()),
            Some(0),
            "多仓本身不产出任何源（不假装有能力）"
        );
        let mrepos = res_multi["repos"].as_array().cloned().unwrap_or_default();
        assert_eq!(mrepos.len(), 2, "应列出 2 个子仓：{res_multi}");
        assert_eq!(mrepos[0]["name"], "子仓甲");
        assert_eq!(mrepos[0]["url"], format!("{}/cfg/sub.json", sink.url()));

        // ── ③-5 链接是多仓 → 一键更新如实报错，且**不动本地** ───────────
        set_tvbox_source(&st, &second_id, &cfg_url).expect("给第二个源补链接失败");
        let upd_err = update_tvbox_source(&st, &first_id, true, false).await;
        println!("[EVIDENCE] T12-update-on-multirepo {upd_err:?}");
        assert!(upd_err.is_err(), "链接是多仓时更新应如实报错，而不是假装成功");
        assert!(
            upd_err.as_ref().unwrap_err().contains("多仓"),
            "错误文案要说清楚：{:?}",
            upd_err
        );
        assert!(local_of(&st, &first_id).is_some(), "报错后本地源必须还在");
        assert!(local_of(&st, &second_id).is_some(), "报错后本地源必须还在");

        // ── ③-6 侧车文件真的落盘了，且重启后还在 ────────────────────────
        let sidecar = tvbox_meta_file(&dir);
        assert!(sidecar.exists(), "订阅 sidecar 应已落盘：{}", sidecar.display());
        let raw = std::fs::read_to_string(&sidecar).unwrap_or_default();
        println!("[EVIDENCE] T12-sidecar {} bytes={}", sidecar.display(), raw.len());
        println!("[EVIDENCE] T12-sidecar-body {raw}");
        assert!(raw.contains(&first_id), "sidecar 应记录 {first_id}");
        assert!(raw.contains(&cfg_url), "sidecar 应记录订阅链接 {cfg_url}");
        assert!(raw.contains("siteKey"), "sidecar 应记录 site key：{raw}");
        drop(st);

        let st2 = AppState::bootstrap(dir.clone()).await.expect("重启 bootstrap 失败");
        let listed3 = list_tvbox_sources(&st2).expect("重启后列出源失败");
        println!("[EVIDENCE] T12-list-after-restart {listed3}");
        assert_eq!(listed3["total"], 2u64, "重启后两个源都应在：{listed3}");
        assert_eq!(
            listed3["withSource"],
            2u64,
            "重启后订阅链接必须还在（这正是用户要的「不至于更新失效」）：{listed3}"
        );
        let one = listed3["sources"]
            .as_array()
            .and_then(|a| a.iter().find(|x| x["id"] == first_id.as_str()))
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        assert_eq!(one["sourceUrl"], cfg_url, "重启后链接应与写入时一致：{one}");
        assert_eq!(one["needsSource"], serde_json::Value::Bool(false));
        assert_eq!(one["siteKey"], "k1", "site key 也要能恢复：{one}");
        assert!(local_of(&st2, &first_id).is_some(), "重启后源本体也应还在");
        drop(st2);

        // 清链接：回到「贴文本导入」状态
        let st3 = AppState::bootstrap(dir.clone()).await.expect("三次 bootstrap 失败");
        set_tvbox_source(&st3, &first_id, "").expect("清链接失败");
        let listed4 = list_tvbox_sources(&st3).expect("列出源失败");
        assert_eq!(listed4["withSource"], 1u64, "清掉一个后应剩 1 个：{listed4}");
        drop(st3);

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── ④ 检测更新 + 一键更新（真发 HTTP，默认只加不删）────────────────
    #[tokio::test]
    async fn e2e_check_and_apply_never_deletes_by_default() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
        let api = fake_api(&sink);
        let dir = super::task5_ab_restart::unique_tmp_dir("t12b");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // 本地先有两个源：k1 甲站（api1）/ k2 乙站（api2）
        let cfg_local = format!(
            "{{\"sites\":[\
               {{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"{api}\"}},\
               {{\"key\":\"k2\",\"name\":\"乙站\",\"type\":1,\"api\":\"{api}\"}}\
             ]}}"
        );
        let res = import_tvbox_config(&st, &cfg_local).await.expect("导入失败");
        let ids: Vec<String> = res["imported"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|x| x["id"].as_str().unwrap_or_default().to_string())
                    .collect()
            })
            .unwrap_or_default();
        assert_eq!(ids.len(), 2, "应导入 2 个源：{res}");
        // 直接写 sidecar：记成 k1/k2（两个源共用同一个订阅链接）
        let sub_url = format!("{}/cfg/v2.json", sink.url());
        for (i, id) in ids.iter().enumerate() {
            let meta = TvboxSourceMeta {
                source_url: Some(sub_url.clone()),
                site_key: if i == 0 { "k1".to_string() } else { "k2".to_string() },
                site_name: if i == 0 { "甲站".to_string() } else { "乙站".to_string() },
                api: api.clone(),
                installed_at: now_secs(),
                ..Default::default()
            };
            write_tvbox_meta(&dir, id, &meta).expect("写 sidecar 失败");
        }
        let listed0 = list_tvbox_sources(&st).expect("列出源失败");
        println!("[EVIDENCE] T12-list-before-check {listed0}");
        assert_eq!(listed0["withSource"], 2u64, "两个源都该有链接：{listed0}");

        // ── ④-1 检测：v2 里 k1 不变 / k3 新增 / k2 消失 ────────────────
        let chk = check_tvbox_updates(&st, None).await.expect("检测失败");
        println!("[EVIDENCE] T12-check-v2 {chk}");
        assert_eq!(chk["checked"], 1u64, "两个源共用一个链接 → 只查 1 次");
        let it = &chk["items"][0];
        assert_eq!(it["ok"], serde_json::Value::Bool(true), "v2 应能解析：{it}");
        assert_eq!(it["sourceUrl"], sub_url);
        assert_eq!(it["remoteTotalSites"], 2u64, "v2 里 2 个 site");
        assert_eq!(it["remoteConvertible"], 2u64, "v2 里 2 个 type=1");
        assert_eq!(it["added"].as_array().map(|a| a.len()), Some(1), "k3 应算新增：{it}");
        assert_eq!(it["added"][0]["name"], "丙站");
        assert_eq!(
            it["added"][0]["api"],
            format!("{}/api3/vod", sink.url()),
            "相对/绝对地址要正确：{it}"
        );
        assert_eq!(it["removed"].as_array().map(|a| a.len()), Some(1), "k2 应算消失：{it}");
        assert_eq!(it["unchanged"].as_u64().unwrap_or(0), 1, "k1 应算没变：{it}");
        let hits1 = sink.hits();
        super::task5_ab_restart::dump_hits("T12-check-v2", &hits1);
        assert!(
            hits1.iter().any(|h| h.target.contains("/cfg/v2.json")),
            "检测必须真的联网下载配置：{:?}",
            sink.lines()
        );

        // ── ④-2 一键更新（applyNew=true / deleteMissing=false）──────────
        let upd = update_tvbox_source(&st, &ids[0], true, false).await.expect("更新失败");
        println!("[EVIDENCE] T12-update-apply-new-no-delete {upd}");
        assert_eq!(upd["updated"], serde_json::Value::Bool(true), "应有新增：{upd}");
        assert_eq!(upd["added"].as_array().map(|a| a.len()), Some(1), "应加入 1 个新站：{upd}");
        assert_eq!(upd["added"][0]["name"], "丙站");
        assert_eq!(upd["changed"].as_array().map(|a| a.len()), Some(0), "没有变更：{upd}");
        assert_eq!(upd["deleted"].as_array().map(|a| a.len()), Some(0), "★ 默认绝不删：{upd}");
        assert_eq!(
            upd["removed"].as_array().map(|a| a.len()),
            Some(1),
            "消失的站要如实报告：{upd}"
        );
        assert!(local_of(&st, &ids[1]).is_some(), "★ 消失的站必须还在（没勾删除）");
        let listed1 = list_tvbox_sources(&st).expect("列出源失败");
        println!("[EVIDENCE] T12-list-after-update {listed1}");
        assert_eq!(listed1["total"], 3u64, "更新后应是 3 个源：{listed1}");
        let new_id = upd["added"][0]["id"].as_str().unwrap_or_default().to_string();
        assert!(!new_id.is_empty(), "新加入的站必须带 id：{upd}");
        assert!(local_of(&st, &new_id).is_some(), "新站应已持久化");
        assert!(
            read_tvbox_meta(&dir, &new_id).is_some(),
            "新站的订阅链接也要落盘（否则下次检测不到它）"
        );
        // 新站**绝不能**顶掉已有源
        assert!(local_of(&st, &ids[0]).is_some(), "老站不能被顶掉");
        assert_eq!(local_of(&st, &ids[0]).unwrap().2, api, "老站接口不该变");

        // ── ④-3 再更新一次：应如实说「无需更新」，但仍报告消失的站 ───────
        let upd2 = update_tvbox_source(&st, &ids[0], true, false).await.expect("二次更新失败");
        println!("[EVIDENCE] T12-update-again {upd2}");
        assert_eq!(upd2["updated"], serde_json::Value::Bool(false), "第二次应无变化：{upd2}");
        assert_eq!(upd2["reason"], "远端配置与本地一致，无需更新");
        assert_eq!(
            upd2["removed"].as_array().map(|a| a.len()),
            Some(1),
            "★ 即使没更新也要如实报告远端已消失的站：{upd2}"
        );

        // ── ④-4 变更：链接切到 v3（k1 换接口）→ changed ─────────────────
        let v3 = format!("{}/cfg/v3.json", sink.url());
        set_tvbox_source(&st, &ids[0], &v3).expect("改链接失败");
        let chk3 = check_tvbox_updates(&st, None).await.expect("检测失败");
        println!("[EVIDENCE] T12-check-v3 {chk3}");
        let items3 = chk3["items"].as_array().cloned().unwrap_or_default();
        let i3 = items3
            .iter()
            .find(|x| x["sourceUrl"] == v3.as_str())
            .cloned()
            .expect("应有一条 v3 的检测结果");
        assert_eq!(i3["changed"].as_array().map(|a| a.len()), Some(1), "k1 应算变更：{i3}");
        assert_eq!(i3["changed"][0]["id"], ids[0].as_str(), "变更必须沿用原 id：{i3}");
        assert_eq!(
            i3["changed"][0]["newApi"],
            format!("{}/api9/vod", sink.url()),
            "变更后的接口地址：{i3}"
        );

        let upd3 = update_tvbox_source(&st, &ids[0], true, false).await.expect("更新失败");
        println!("[EVIDENCE] T12-update-changed {upd3}");
        assert_eq!(upd3["changed"].as_array().map(|a| a.len()), Some(1), "应有 1 个变更：{upd3}");
        assert_eq!(upd3["changed"][0]["id"], ids[0].as_str());
        assert_eq!(
            upd3["added"].as_array().map(|a| a.len()),
            Some(0),
            "k3 已在本地，不该再报新增：{upd3}"
        );
        let after = local_of(&st, &ids[0]).expect("源应还在");
        assert_eq!(after.2, format!("{}/api9/vod", sink.url()), "接口应已更新：{after:?}");
        assert_eq!(after.1, "甲站", "名字不该变");

        // ── ④-5 deleteMissing=true 才删（用户明确勾选）──────────────────
        let v2 = format!("{}/cfg/v2.json", sink.url());
        set_tvbox_source(&st, &ids[0], &v2).expect("改回 v2 失败");
        let upd4 = update_tvbox_source(&st, &ids[0], true, true).await.expect("带删除的更新失败");
        println!("[EVIDENCE] T12-update-delete-missing {upd4}");
        assert_eq!(upd4["deleted"].as_array().map(|a| a.len()), Some(1), "勾选后才应删：{upd4}");
        assert_eq!(upd4["deleted"][0]["id"], ids[1].as_str());
        assert!(local_of(&st, &ids[1]).is_none(), "勾选后消失的站应被移除");
        assert!(
            read_tvbox_meta(&dir, &ids[1]).is_none(),
            "删源必须同时清掉它的订阅链接（否则将来 id 复用会继承陈旧链接）"
        );

        // ── ④-6 remove_tvbox_source：删源 + 清链接 ──────────────────────
        let rm = remove_tvbox_source(&st, &ids[0]).expect("删源失败");
        println!("[EVIDENCE] T12-remove {rm}");
        assert_eq!(rm["removed"], serde_json::Value::Bool(true));
        assert!(read_tvbox_meta(&dir, &ids[0]).is_none(), "删源后链接也该没了");
        let listed2 = list_tvbox_sources(&st).expect("列出源失败");
        println!("[EVIDENCE] T12-list-final {listed2}");
        assert_eq!(listed2["total"], 1u64, "删掉 2 个后应剩 1 个：{listed2}");
        // 幂等：再删一次不报错
        let rm2 = remove_tvbox_source(&st, &ids[0]).expect("重复删源不该报错");
        assert_eq!(rm2["removed"], serde_json::Value::Bool(false));

        // ── ④-7 找不到的 id：如实报错 ──────────────────────────────────
        assert!(update_tvbox_source(&st, "no-such-id", true, false).await.is_err());
        assert!(check_tvbox_updates(&st, Some("no-such-id")).await.is_err());
        assert!(set_tvbox_source(&st, "no-such-id", "http://x.test/a.json").is_err());
        drop(st);

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── ⑤ 坏 sidecar 不能让设置页打不开（容错）──────────────────────────
    #[tokio::test]
    async fn corrupt_sidecar_degrades_to_no_source() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let dir = super::task5_ab_restart::unique_tmp_dir("t12c");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        std::fs::write(tvbox_meta_file(&dir), "{ 这不是 JSON").expect("写坏文件失败");

        let metas = load_tvbox_metas(&dir);
        println!("[EVIDENCE] T12-corrupt-sidecar metas={}", metas.len());
        assert!(metas.is_empty(), "坏文件应退化成空 map，而不是 panic/Err");
        assert!(read_tvbox_meta(&dir, "whatever").is_none());

        // 坏文件存在时仍能正常写入（覆盖掉它）
        let meta = TvboxSourceMeta {
            source_url: Some("http://x.test/a.json".to_string()),
            site_key: "k".to_string(),
            site_name: "甲".to_string(),
            api: "http://x.test/api".to_string(),
            installed_at: 1,
            ..Default::default()
        };
        write_tvbox_meta(&dir, "id1", &meta).expect("覆盖坏文件失败");
        let got = read_tvbox_meta(&dir, "id1").expect("应能读回");
        assert_eq!(got.site_key, "k");
        assert_eq!(got.source_url.as_deref(), Some("http://x.test/a.json"));

        // 幂等删除
        forget_tvbox_meta(&dir, "id1").expect("删除失败");
        forget_tvbox_meta(&dir, "id1").expect("重复删除应幂等");
        assert!(read_tvbox_meta(&dir, "id1").is_none());
        // 空 id 要拒绝
        assert!(write_tvbox_meta(&dir, "", &meta).is_err(), "空 id 应被拒绝");

        // 文件不存在时读也是空（不是错误）
        let dir2 = super::task5_ab_restart::unique_tmp_dir("t12d");
        assert!(load_tvbox_metas(&dir2).is_empty(), "文件不存在应返回空 map");

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&dir2);
    }

    // ═════════════════════════════════════════════════════════════════
    //  T5：上次更新盖章 + 定时判定（Owner：「源…上次更新时间…定时更新」）
    // ═════════════════════════════════════════════════════════════════

    /// ★ 到点判定（纯函数）四象限：从未更新 / 新鲜 / 超期 / 禁用
    #[test]
    fn t5_due_judgment() {
        let now: i64 = 1_800_000_000;
        // 从未更新过（at=0）⇒ 到点（冷启动补一次的判据）
        assert!(
            tvbox_update_due(0, 86_400, now, true),
            "从未更新过必须判到点，否则冷启动永远不会补"
        );
        // 新鲜（at 在间隔内）⇒ 不到点
        assert!(!tvbox_update_due(now - 3_600, 86_400, now, true));
        // 超期（at + interval ≤ now）⇒ 到点（边界含等号）
        assert!(tvbox_update_due(now - 86_400, 86_400, now, true), "到点即该更新（边界含等号）");
        // 禁用 ⇒ 永远不到点（哪怕超期一万年）
        assert!(!tvbox_update_due(0, 86_400, now, false));
        assert!(!tvbox_update_due(now - 999_999, 86_400, now, false));
        // interval 非法 ⇒ 不到点（不留"开着但间隔非法"的中间态）
        assert!(!tvbox_update_due(0, 0, now, true));
        assert!(!tvbox_update_due(0, -1, now, true));
    }

    /// ★ 链接挑选（纯函数）：按链接去重、无链接跳过、禁用不出
    #[test]
    fn t5_collect_due_links_dedupes_by_link() {
        let sources = vec![
            ("a".to_string(), "甲".to_string(), "http://x/api".to_string(), None),
            ("b".to_string(), "乙".to_string(), "http://x/api".to_string(), None),
            ("c".to_string(), "丙".to_string(), "http://y/api".to_string(), None),
            ("d".to_string(), "丁".to_string(), "http://z/api".to_string(), None),
        ];
        let mut metas = std::collections::HashMap::new();
        // a、b 同一条链接 L1：a 超期、b 新鲜 ⇒ 只该出一条，代表是 a
        metas.insert(
            "a".to_string(),
            TvboxSourceMeta { source_url: Some("http://cfg/1.json".into()), last_update_at: 0, ..Default::default() },
        );
        metas.insert(
            "b".to_string(),
            TvboxSourceMeta {
                source_url: Some("http://cfg/1.json".into()),
                last_update_at: 1_800_000_000,
                last_update_ok: true,
                ..Default::default()
            },
        );
        // c 另一条链接 L2，也超期 ⇒ 第二条
        metas.insert(
            "c".to_string(),
            TvboxSourceMeta { source_url: Some("http://cfg/2.json".into()), last_update_at: 0, ..Default::default() },
        );
        // d 没有订阅链接 ⇒ 永远不该出现
        metas.insert("d".to_string(), TvboxSourceMeta { source_url: None, ..Default::default() });

        let got = collect_due_links(&sources, &metas, true, 86_400, 1_800_000_000);
        assert_eq!(
            got,
            vec![
                ("http://cfg/1.json".to_string(), "a".to_string()),
                ("http://cfg/2.json".to_string(), "c".to_string()),
            ],
            "同链接去重成一条（代表 a），无链接的 d 不该出现：{got:?}"
        );

        // 禁用 ⇒ 空
        assert!(
            collect_due_links(&sources, &metas, false, 86_400, 1_800_000_000).is_empty(),
            "总开关关着就不该挑出任何链接"
        );
    }

    /// 配置文件：默认值（开 + 24h）/ 往返 / 坏文件回退默认
    #[test]
    fn t5_schedule_persist_roundtrip() {
        let dir = super::task5_ab_restart::unique_tmp_dir("t5sched");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");

        // 文件不存在 ⇒ 默认：开 + 24h（Lead 批复的默认档位）
        let d = load_tvbox_update_schedule(&dir);
        assert!(d.enabled && d.interval_secs == 86_400, "默认必须是 开+24h：{d:?}");

        // 往返
        save_tvbox_update_schedule(&dir, &TvboxUpdateSchedule { enabled: false, interval_secs: 21_600 })
            .expect("写配置失败");
        let r = load_tvbox_update_schedule(&dir);
        assert!(!r.enabled && r.interval_secs == 21_600, "写读应往返：{r:?}");

        // 坏文件 ⇒ 回退默认（设置页不能因此打不开）
        std::fs::write(tvbox_update_schedule_file(&dir), "{not json").expect("写坏文件失败");
        let b = load_tvbox_update_schedule(&dir);
        assert!(b.enabled && b.interval_secs == 86_400, "坏文件应回退默认：{b:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ 档位白名单（互检 P3-1）：只收 6/12/24 小时；非法值拒绝且**不改写现有配置**
    ///
    /// ```text
    /// 注入证红：把 tvbox_update_schedule_set 的白名单判断摘掉 ⇒ 本条红。
    /// 防的场景：手改配置文件 / 直调 FFI 塞 60 秒 ⇒ 订阅变成"每分钟下载"。
    /// ```
    #[tokio::test]
    async fn t5_schedule_set_whitelist() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let dir = super::task5_ab_restart::unique_tmp_dir("t5wl");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // 合法档位：三档 + 关（关由 enabled 表达，间隔仍须合法）
        for (en, secs) in [(true, 21_600), (true, 43_200), (true, 86_400), (false, 21_600)] {
            let r = tvbox_update_schedule_set(&st, en, secs).expect("合法档位应成功");
            assert_eq!(r["intervalSecs"], secs, "{r}");
            let s = load_tvbox_update_schedule(&dir);
            assert_eq!(s.interval_secs, secs, "写盘应生效：{s:?}");
            assert_eq!(s.enabled, en, "{s:?}");
        }

        // 非法值：拒绝 + 原因可读 + **现有配置不被改写**
        let before = load_tvbox_update_schedule(&dir);
        for bad in [0i64, -1, 60, 3_600, 172_800] {
            let e = tvbox_update_schedule_set(&st, true, bad)
                .expect_err("非法档位必须拒绝");
            assert!(e.contains("6 小时"), "拒绝原因要说清支持哪些档：{e}");
            let after = load_tvbox_update_schedule(&dir);
            assert_eq!(
                (after.enabled, after.interval_secs),
                (before.enabled, before.interval_secs),
                "拒绝 {bad} 秒时不得改写现有配置：{after:?}"
            );
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ 盖章只碰**同一条链接**的源（别的链接 / 无链接的源不许被牵连）
    #[test]
    fn t5_stamp_touches_only_same_link() {
        let dir = super::task5_ab_restart::unique_tmp_dir("t5stamp");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let mk = |u: Option<&str>| TvboxSourceMeta {
            source_url: u.map(String::from),
            ..Default::default()
        };
        write_tvbox_meta(&dir, "l1a", &mk(Some("http://cfg/1.json"))).unwrap();
        write_tvbox_meta(&dir, "l1b", &mk(Some("http://cfg/1.json"))).unwrap();
        write_tvbox_meta(&dir, "l2", &mk(Some("http://cfg/2.json"))).unwrap();
        write_tvbox_meta(&dir, "nolink", &mk(None)).unwrap();

        // 失败章（带原因）只应落在 l1a / l1b
        stamp_link_update(&dir, "http://cfg/1.json", 1_234, false, Some("下载配置失败：炸了".into()));

        let m = load_tvbox_metas(&dir);
        for id in ["l1a", "l1b"] {
            let x = &m[id];
            assert_eq!(x.last_update_at, 1_234, "{id} 应盖章");
            assert!(!x.last_update_ok, "{id} 应是失败章");
            assert_eq!(
                x.last_update_error.as_deref(),
                Some("下载配置失败：炸了"),
                "{id} 应带原因"
            );
        }
        assert_eq!(m["l2"].last_update_at, 0, "别的链接不许被牵连");
        assert!(!m["nolink"].last_update_ok, "无链接的源不许被牵连");

        // 成功章清掉原因
        stamp_link_update(&dir, "http://cfg/1.json", 2_345, true, None);
        let m = load_tvbox_metas(&dir);
        assert!(m["l1a"].last_update_ok && m["l1a"].last_update_error.is_none());
        assert_eq!(m["l1a"].last_update_at, 2_345);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ e2e：远端无变化（「无需更新」早退路径）也必须盖成功章 ——
    ///   且**同链接两个源都盖**。不盖的话定时器每轮都把这条链接判成超期，
    ///   60s 重复下载一次（这正是盖章要防的那个回潮）。
    #[tokio::test]
    async fn t5_update_unchanged_stamps_all_in_link_sources() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
        let api = fake_api(&sink);
        let dir = super::task5_ab_restart::unique_tmp_dir("t5unchanged");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // 本地导入与 /cfg/v2.json **完全一致**的配置（k1 甲站 + k3 丙站）
        let cfg_local = format!(
            "{{\"sites\":[\
               {{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"{api}\"}},\
               {{\"key\":\"k3\",\"name\":\"丙站\",\"type\":1,\"api\":\"{}/api3/vod\"}}\
             ]}}",
            sink.url()
        );
        let res = import_tvbox_config(&st, &cfg_local).await.expect("导入失败");
        let ids: Vec<String> = res["imported"]
            .as_array()
            .map(|a| a.iter().map(|x| x["id"].as_str().unwrap_or_default().to_string()).collect())
            .unwrap_or_default();
        assert_eq!(ids.len(), 2, "应导入 2 个源：{res}");

        // 两个源都记上同一条订阅链接（sidecar 直接写，与 e2e 既有写法一致）
        let sub_url = format!("{}/cfg/v2.json", sink.url());
        for id in ids.iter() {
            write_tvbox_meta(
                &dir,
                id,
                &TvboxSourceMeta {
                    source_url: Some(sub_url.clone()),
                    ..Default::default()
                },
            )
            .expect("写 sidecar 失败");
        }
        // 盖章前清零（导入路径不盖章 ⇒ 本来就是 0；这里断言起点）
        for id in ids.iter() {
            assert_eq!(read_tvbox_meta(&dir, id).unwrap().last_update_at, 0);
        }

        let upsink_before = sink
            .hits()
            .iter()
            .filter(|h| h.method.eq_ignore_ascii_case("GET"))
            .count();
        let upd = update_tvbox_source(&st, &ids[0], true, false).await.expect("更新失败");
        assert_eq!(upd["updated"], serde_json::Value::Bool(false), "远端一致 ⇒ 无需更新：{upd}");

        // ★ 两个源都必须盖上成功章 —— 这是本条的核心判据
        for id in ids.iter() {
            let m = read_tvbox_meta(&dir, id).unwrap();
            assert!(m.last_update_at > 0, "{id} 必须盖章（否则定时器会重复下载）：{m:?}");
            assert!(m.last_update_ok, "{id} 应是成功章：{m:?}");
            assert!(m.last_update_error.is_none(), "{id} 成功章不该带原因：{m:?}");
        }
        let upsink_after = sink
            .hits()
            .iter()
            .filter(|h| h.method.eq_ignore_ascii_case("GET"))
            .count();
        assert_eq!(
            upsink_after,
            upsink_before + 1,
            "远端一致时只应下载一次配置（hits: {} -> {}）",
            upsink_before,
            upsink_after
        );

        // list 输出也要带上新字段（Dart 界面的数据源）
        let listed = list_tvbox_sources(&st).expect("列出源失败");
        let one = &listed["sources"][0];
        assert!(one["lastUpdateAt"].as_i64().unwrap_or(0) > 0, "list 应带 lastUpdateAt：{one}");
        assert_eq!(one["lastUpdateOk"], serde_json::Value::Bool(true), "{one}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ e2e：更新失败盖**失败章**（时间 + 原因），本地源原样保留
    #[tokio::test]
    async fn t5_update_failure_stamps_error() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
        let api = fake_api(&sink);
        let dir = super::task5_ab_restart::unique_tmp_dir("t5fail");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        let cfg_local = format!(
            "{{\"sites\":[{{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"{api}\"}}]}}"
        );
        let res = import_tvbox_config(&st, &cfg_local).await.expect("导入失败");
        let id = res["imported"][0]["id"].as_str().unwrap_or_default().to_string();
        // 指向一个必然拒连的端口（既有测试同款：127.0.0.1:1）
        write_tvbox_meta(
            &dir,
            &id,
            &TvboxSourceMeta {
                source_url: Some("http://127.0.0.1:1/cfg/v2.json".to_string()),
                ..Default::default()
            },
        )
        .expect("写 sidecar 失败");

        let upd = update_tvbox_source(&st, &id, true, false).await;
        assert!(upd.is_err(), "拒连地址必须报错：{upd:?}");

        // ★ 失败章：时间 + 原因（用户界面据此显示"上次更新失败"）
        let m = read_tvbox_meta(&dir, &id).unwrap();
        assert!(m.last_update_at > 0, "失败也要盖时间章：{m:?}");
        assert!(!m.last_update_ok, "必须标失败：{m:?}");
        let why = m.last_update_error.clone().unwrap_or_default();
        assert!(why.contains("下载配置失败"), "原因要进章：{why:?}");

        // list 输出如实带失败信息（Dart 界面的数据源）
        let listed = list_tvbox_sources(&st).expect("列出源失败");
        let one = listed["sources"]
            .as_array()
            .and_then(|a| a.iter().find(|x| x["id"] == id.as_str()))
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        assert_eq!(one["lastUpdateOk"], serde_json::Value::Bool(false), "{one}");
        assert!(!one["lastUpdateError"].as_str().unwrap_or_default().is_empty(), "{one}");

        // 本地源本体原样（「失败不影响旧配置」）
        assert!(
            st.third_party.read().unwrap().iter().any(|p| p.id() == id),
            "失败后本地源必须还在"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ═════════════════════════════════════════════════════════════════
    //  T5 真机判读打回项（2026-11-01）：功能加了但**用户看不见**
    // ═════════════════════════════════════════════════════════════════
    //
    // 打回的两条：
    // ```text
    // ① 聚合源 tvbox_agg 永远显示不出来（sidecar 里没有它这一条）
    // ② 64 条子站永远盖不上章（它们是贴文本导入的，source_url=None）
    // ```
    //
    // 下面四条门禁共用**一套真形状夹具**（见 `real_shape_fixture`）：
    // 只用两条理想夹具是上一版漏网的直接原因 —— 真数据 64 条、
    // 每条只有 siteKey/siteName/api/installedAt、没有 lastUpdate 三件套。

    /// 真 sidecar 形状的一条（`csp-xxx` 形态 id + 四个字段，**没有** source_url
    /// / lastUpdateAt —— 与真机 `tvbox-sources.json` 逐字同形）
    fn real_shape_entry(site_key: &str, name: &str, api: &str) -> TvboxSourceMeta {
        TvboxSourceMeta {
            source_url: None,
            site_key: site_key.to_string(),
            site_name: name.to_string(),
            api: api.to_string(),
            installed_at: 1_793_268_523, // 真机那批的同一个时刻
            last_update_at: 0,
            last_update_ok: false,
            last_update_error: None,
        }
    }

    /// ★ 夹具自证：**必须**是真形状（否则下面四条门禁全是空转的假绿）
    ///
    /// ```text
    /// 若哪天有人给夹具补上 source_url / lastUpdateAt，
    /// "补链接后能盖章""聚合能取到时间"就变成恒真 —— 门禁失效且看不出来。
    /// 这条先钉住夹具本身：n 条、全部无链接、全部未盖章、字段名逐字。
    /// ```
    fn real_shape_fixture(dir: &std::path::Path, n: usize) -> Vec<String> {
        let mut ids = Vec::new();
        for i in 0..n {
            // 真机 id 形状：`csp-<类名 kebab>-<8 位十六进制>`
            let id = format!(
                "csp-fixture-{:08x}",
                (i as u32).wrapping_mul(0x9e3779b1u32).wrapping_add(0x51ed270b)
            );
            write_tvbox_meta(dir, &id, &real_shape_entry(&format!("k{i}"), &format!("站{i}"), "csp_Fixture"))
                .expect("写真形状夹具失败");
            ids.push(id);
        }
        // 夹具自证（反假绿）
        let metas = load_tvbox_metas(dir);
        assert_eq!(metas.len(), n, "夹具条数不对：{}", metas.len());
        for id in ids.iter() {
            let m = &metas[id];
            assert!(m.source_url.is_none(), "{id} 必须是「无订阅链接」（真形状）");
            assert_eq!(m.last_update_at, 0, "{id} 必须是「从未更新」（真形状）");
            assert!(!m.site_key.is_empty() && !m.api.is_empty(), "{id} 应带 siteKey/api");
        }
        // 磁盘上也不许出现 source_url 键（`skip_serializing_if` ⇒ None 就整个键不落盘，
        // 真机那份文件正是这样 —— 这正是"文本导入"在磁盘上的唯一证据）
        let raw = std::fs::read_to_string(tvbox_meta_file(dir)).expect("读夹具失败");
        assert!(
            !raw.contains("source_url"),
            "真形状夹具里不许出现 source_url 键（真机那份是 None ⇒ 键不存在）"
        );
        // lastUpdateAt 是**没有** skip_serializing_if 的（T5 才加的字段，
        // 真机那份文件早于 T5 ⇒ 压根没有这个键）。所以这里不能判"键不存在"，
        // 判"值全为 0"—— 语义上等价（0 = 从未更新过）。
        let zeros = raw.matches("\"lastUpdateAt\": 0").count();
        assert_eq!(
            zeros, n,
            "真形状夹具的 lastUpdateAt 必须全为 0（实际 {zeros}/{n}）—— 有一个非 0 就是夹具被污染了"
        );
        ids
    }

    /// ★ R1：聚合源更新后能取到**非空** lastUpdateAt，且等于子站章的 max
    ///
    /// 证红：把 `tvbox_aggregate_last_update` 改成返回 None（或就地返回 0）
    ///      ⇒ 本条红（且红在"聚合时间是 0"这一行，不是别处）。
    #[test]
    fn t5_aggregate_last_update_is_real() {
        let dir = super::task5_ab_restart::unique_tmp_dir("t5agg");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");

        // 真形状：64 条、无链接、未盖章
        let ids = real_shape_fixture(&dir, 64);
        let mut metas = load_tvbox_metas(&dir);

        // ① 全未盖章 ⇒ 聚合也必须是 None（不许返回 0 假装"更新过"）
        assert!(
            tvbox_aggregate_last_update(&metas, &ids).is_none(),
            "一个子站都没盖过章 ⇒ 聚合必须是 None"
        );

        // ② 只给**其中几条**盖章（模拟"这条链接下既有子站已更新"）
        let t_old = 1_800_000_000i64;
        let t_new = 1_800_006_000i64;
        metas.get_mut(&ids[0]).unwrap().last_update_at = t_old;
        metas.get_mut(&ids[0]).unwrap().last_update_ok = true;
        metas.get_mut(&ids[7]).unwrap().last_update_at = t_new;
        metas.get_mut(&ids[7]).unwrap().last_update_ok = true;

        let (at, ok, err) = tvbox_aggregate_last_update(&metas, &ids)
            .expect("★ 有子站盖过章 ⇒ 聚合必须能取到时间（不能永远'从未更新'）");
        assert_eq!(at, t_new, "★ 口径是 max（最近一次真核对），不是 min/平均：{at}");
        assert!(ok, "全部子站都成功 ⇒ ok=true");
        assert!(err.is_none(), "成功不该带原因");

        // ③ 任一子站上次失败 ⇒ 整条聚合标失败（定时更新一直在失败必须看得见）
        metas.get_mut(&ids[3]).unwrap().last_update_at = t_old;
        metas.get_mut(&ids[3]).unwrap().last_update_ok = false;
        metas.get_mut(&ids[3]).unwrap().last_update_error = Some("下载配置失败：连接被拒".to_string());
        let (at2, ok2, err2) = tvbox_aggregate_last_update(&metas, &ids).unwrap();
        assert_eq!(at2, t_new, "失败子站不改变 max 口径");
        assert!(!ok2, "★ 任一子站失败 ⇒ 聚合必须标失败（否则用户看不见定时一直在失败）");
        assert!(
            err2.as_deref().unwrap_or("").contains("下载配置失败"),
            "失败原因要带上：{err2:?}"
        );

        // ④ 子站集为空 ⇒ None（不是 0，不是 panic）
        assert!(tvbox_aggregate_last_update(&metas, &[]).is_none());
        // ⑤ 不存在的 id 不参与（不许凭空造章）
        assert_eq!(
            tvbox_aggregate_last_update(&metas, &["no-such-id".to_string()]),
            None
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ R1-e2e：走**生产命令** `list_tvbox_sources` ⇒ 顶层 `aggregate` 字段
    /// 带真实时间，且 **sources[] 里没有 tvbox_agg**（防"检测更新按钮误出现"）
    ///
    /// 证红：把顶层 `aggregate` 拿掉 / 把 tvbox_agg 塞进 sources[] ⇒ 本条红。
    #[tokio::test]
    async fn t5_list_exposes_aggregate_last_update() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let dir = super::task5_ab_restart::unique_tmp_dir("t5aggcmd");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // 真形状：64 个子站（注册进 third_party + sidecar）
        let ids = real_shape_fixture(&dir, 64);
        {
            let mut list = st.third_party.write().expect("锁中毒");
            for (i, id) in ids.iter().enumerate() {
                list.push(crate::model::PersistedProvider::Tvbox {
                    id: id.clone(),
                    name: format!("站{i}"),
                    api: "csp_Fixture".to_string(),
                    categories: Vec::new(),
                    parsers: Vec::new(),
                    ext: None,
                });
            }
        }
        crate::commands_provider::persist_from_registry(&st).expect("落盘失败");

        // 盖章前：聚合时间是 0（如实 —— 不许伪造）
        let before = list_tvbox_sources(&st).expect("列出源失败");
        assert_eq!(
            before["aggregate"]["lastUpdateAt"].as_i64().unwrap_or(-1),
            0,
            "★ 一个子站都没更新过 ⇒ 聚合如实为 0：{before}"
        );

        // 给其中 3 条盖章（真实路径：走 stamp_link_update）
        for id in ids.iter().take(3) {
            let mut m = read_tvbox_meta(&dir, id).unwrap();
            m.source_url = Some("http://cfg/real.json".to_string());
            write_tvbox_meta(&dir, id, &m).expect("补链接失败");
        }
        stamp_link_update(&dir, "http://cfg/real.json", 1_800_009_999, true, None);

        let got = list_tvbox_sources(&st).expect("列出源失败");
        println!("[EVIDENCE] T5-agg-list aggregate={}", got["aggregate"]);

        // ① 顶层 aggregate：非空 + 真实时间 + 成功
        let agg_at = got["aggregate"]["lastUpdateAt"].as_i64().unwrap_or(0);
        assert_eq!(agg_at, 1_800_009_999, "★ 聚合必须取到真实时间：{got}");
        assert_eq!(got["aggregate"]["id"], "tvbox_agg");
        assert_eq!(got["aggregate"]["lastUpdateOk"], serde_json::Value::Bool(true));
        // ★ 聚合源**不是**一条源 ⇒ 不许被判成"没有订阅链接"
        //   （Dart 侧 needsSource 缺省 true ⇒ 必须显式给 false，
        //    否则界面会对聚合源显示"无法定时更新，去补链接"——那是错的）
        assert_eq!(
            got["aggregate"]["needsSource"],
            serde_json::Value::Bool(false),
            "★ 聚合源没有自己的订阅链接，但那不是'缺链接'：{got}"
        );

        // ② ★ 聚合**不许**进 sources[]（否则卡片多出一个必然报错的"检测更新"按钮）
        let in_sources = got["sources"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .iter()
            .any(|x| x["id"] == "tvbox_agg");
        assert!(
            !in_sources,
            "★ tvbox_agg 不许出现在 sources[] —— 它会让 Dart 侧多出「检测更新」按钮，点了必然报'没有找到 TVBox 源'"
        );
        // 顺带钉住：子站们确实都在（聚合时间不是凭空来的）
        assert_eq!(got["total"], 64u64, "{got}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ R2：一次订阅更新后，该链接下的**既有子站条目**（不只本次新增/变更的）
    /// **全部**带上 lastUpdateAt
    ///
    /// 真形状夹具：64 条、无链接、未盖章 ⇒ 先补链接（用户归属动作），
    /// 再跑一次更新 ⇒ 64 条**一条不落**全部有章。
    ///
    /// 证红：把 `stamp_link_update` 改成只盖 added/changed ⇒ 本条红
    ///      （红在"第 N 条没盖章"，N 是一个未变更的既有子站）。
    #[tokio::test]
    async fn t5_existing_sub_sites_all_stamped() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
        let dir = super::task5_ab_restart::unique_tmp_dir("t5allstamp");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // ── 真形状夹具：64 条既有子站 ──────────────────────────────────
        let ids = real_shape_fixture(&dir, 64);
        let api = format!("{}/api.php/provide/vod", sink.url());
        {
            let mut list = st.third_party.write().expect("锁中毒");
            for (i, id) in ids.iter().enumerate() {
                list.push(crate::model::PersistedProvider::Tvbox {
                    id: id.clone(),
                    name: format!("站{i}"),
                    api: api.clone(),
                    categories: Vec::new(),
                    parsers: Vec::new(),
                    ext: None,
                });
            }
        }
        crate::commands_provider::persist_from_registry(&st).expect("落盘失败");

        // 起点自证：64 条**全部**没有章（真形状）
        for id in ids.iter() {
            assert_eq!(
                read_tvbox_meta(&dir, id).unwrap().last_update_at,
                0,
                "{id} 起点必须是「从未更新」"
            );
        }

        // ── 归属：给全部 64 条补上同一条订阅链接（= 用户去聚合页补链接）──
        let sub_url = format!("{}/cfg/v2.json", sink.url());
        for id in ids.iter() {
            let mut m = read_tvbox_meta(&dir, id).unwrap();
            m.source_url = Some(sub_url.clone());
            write_tvbox_meta(&dir, id, &m).expect("补链接失败");
        }

        // ── 一次更新（代表源任选一条：命令层按链接整条核对）──────────────
        let rep = ids[0].clone();
        let upd = update_tvbox_source(&st, &rep, true, false).await;
        println!("[EVIDENCE] T5-all-stamp upd={upd:?}");

        // ★ 核心判据：64 条**既有子站一条不落**全部带上章
        let metas = load_tvbox_metas(&dir);
        let mut missing: Vec<String> = Vec::new();
        for id in ids.iter() {
            match metas.get(id) {
                Some(m) if m.last_update_at > 0 => {}
                other => missing.push(format!("{id} -> {other:?}")),
            }
        }
        assert!(
            missing.is_empty(),
            "★ 该链接下的既有子站必须全部盖章（不只本次新增/变更的）：{} 条没盖：{missing:?}",
            missing.len()
        );

        // 且这些里绝大多数是**本次未变更**的既有条目 ——
        // 若只盖 added/changed，这里必然只剩 1~2 条有章。
        let stamped = metas
            .iter()
            .filter(|(_, m)| m.last_update_at > 0)
            .count();
        assert_eq!(
            stamped, 64,
            "★ 64 条既有子站应全部有章（实际 {stamped}）—— 只有 1~2 条说明章只盖了 added/changed"
        );

        // 章是成功章（这条链接可达且解析成功）
        let any_fail = metas.values().filter(|m| m.last_update_at > 0 && !m.last_update_ok).count();
        assert_eq!(any_fail, 0, "可达链接 ⇒ 应全是成功章");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ P3-2 证红：链接带前后空白/换行时**也必须盖得上**
    ///
    /// ```text
    /// 修前：stamp 用 `m.source_url.as_deref() == Some(url)`（URL 原样），
    ///      而 collect_due_links 传的是 trim 后的值 ⇒ 两边形状不一致 ⇒ 盖不上。
    /// 修后：三处统一走 norm_source_url ⇒ 盖得上。
    /// ```
    /// 证红：把 stamp/in_link 改回 `== Some(url)` 原样比较 ⇒ 本条红。
    #[tokio::test]
    async fn t5_stamp_survives_whitespace_in_link() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
        let dir = super::task5_ab_restart::unique_tmp_dir("t5ws");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        let api = format!("{}/api.php/provide/vod", sink.url());
        let id = "csp-ws-00000001".to_string();
        {
            let mut list = st.third_party.write().expect("锁中毒");
            list.push(crate::model::PersistedProvider::Tvbox {
                id: id.clone(),
                name: "空白站".to_string(),
                api: api.clone(),
                categories: Vec::new(),
                parsers: Vec::new(),
                ext: None,
            });
        }
        crate::commands_provider::persist_from_registry(&st).expect("落盘失败");

        // 用户从网页复制出来的链接：**带前后空白和换行**（真机常态）
        let dirty = format!("  {}/cfg/v2.json\n", sink.url());
        write_tvbox_meta(
            &dir,
            &id,
            &TvboxSourceMeta {
                source_url: Some(dirty.clone()),
                ..Default::default()
            },
        )
        .expect("写 sidecar 失败");

        // ① 写入即归一：磁盘上存的必须是 trim 后的形态
        let stored = read_tvbox_meta(&dir, &id).unwrap().source_url.unwrap_or_default();
        assert_eq!(
            stored,
            format!("{}/cfg/v2.json", sink.url()),
            "★ 写入侧必须存 trim 后的值（从源头消灭两种形态）：{stored:?}"
        );

        // ② 到点判定：空白链接也能被挑出来（不是被跳过）
        let sources = local_tvbox_sources(&st).expect("列源失败");
        let metas = load_tvbox_metas(&dir);
        let due = collect_due_links(&sources, &metas, true, 86_400, now_secs());
        assert_eq!(
            due.len(),
            1,
            "★ 带空白的链接也必须被挑出来更新（否则定时器永远跳过它）：{due:?}"
        );
        assert_eq!(due[0].0, format!("{}/cfg/v2.json", sink.url()));

        // ③ 真跑一次更新 ⇒ 章必须落上（P3-2 的正主判据）
        let upd = update_tvbox_source(&st, &id, true, false).await;
        println!("[EVIDENCE] T5-ws upd={upd:?}");
        let m = read_tvbox_meta(&dir, &id).unwrap();
        assert!(
            m.last_update_at > 0,
            "★ 链接带空白也必须盖得上章（修前这里恒为 0 ⇒ 界面永远'从未更新'）：{m:?}"
        );
        assert!(m.last_update_ok, "可达链接 ⇒ 成功章：{m:?}");

        // ④ stamp 传"脏 URL"也要能盖上（调用方没 trim 的情况）
        stamp_link_update(&dir, &dirty, 1_800_000_123, false, Some("炸了".to_string()));
        let m2 = read_tvbox_meta(&dir, &id).unwrap();
        assert_eq!(
            m2.last_update_at, 1_800_000_123,
            "★ stamp 收到未 trim 的 URL 也必须匹配上（三处同一把尺子）：{m2:?}"
        );
        assert!(!m2.last_update_ok, "失败章：{m2:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ P2-2：sidecar 的**五条**写路径共用同一把锁 —— 并发写不丢条目
    ///
    /// ```text
    /// 写 sidecar 的形状是 load 整份 → 改一条 → save 整份。
    /// 不加锁时 N 个线程各读到旧整份、各自写回 ⇒ 后写的整份覆盖先写的
    /// ⇒ 先写那次改动**凭空消失**（"刚导入的源，重启后订阅链接没了"）。
    /// ```
    /// 证红：把 write_tvbox_meta / forget_tvbox_meta 里的锁去掉 ⇒ 本条红
    ///      （红在"丢了 K 条"，K>0）。
    #[test]
    fn t5_sidecar_writes_are_serialized() {
        let dir = super::task5_ab_restart::unique_tmp_dir("t5lock");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");

        const N: usize = 32;
        let mut handles = Vec::new();
        for i in 0..N {
            let d = dir.clone();
            handles.push(std::thread::spawn(move || {
                let id = format!("csp-lock-{i:04}");
                write_tvbox_meta(
                    &d,
                    &id,
                    &TvboxSourceMeta {
                        source_url: Some(format!("http://cfg/{i}.json")),
                        site_key: format!("k{i}"),
                        site_name: format!("站{i}"),
                        api: "csp_Fixture".to_string(),
                        installed_at: 1,
                        last_update_at: i as i64 + 1,
                        last_update_ok: true,
                        last_update_error: None,
                    },
                )
                .expect("并发写失败");
            }));
        }
        for h in handles {
            h.join().expect("线程 panic");
        }

        let metas = load_tvbox_metas(&dir);
        assert_eq!(
            metas.len(),
            N,
            "★ {N} 个并发写一条都不许丢（丢了说明写路径没上锁）：实际 {}",
            metas.len()
        );
        for i in 0..N {
            let id = format!("csp-lock-{i:04}");
            let m = metas.get(&id).unwrap_or_else(|| panic!("{id} 被覆盖了"));
            assert_eq!(m.site_key, format!("k{i}"), "{id} 内容不对：{m:?}");
            assert_eq!(m.last_update_at, i as i64 + 1, "{id} 章被覆盖：{m:?}");
        }

        // 另一条路径（forget）也在锁里：并发删不互相覆盖
        let mut handles2 = Vec::new();
        for i in 0..8 {
            let d = dir.clone();
            handles2.push(std::thread::spawn(move || {
                forget_tvbox_meta(&d, &format!("csp-lock-{i:04}")).expect("并发删失败");
            }));
        }
        for h in handles2 {
            h.join().expect("线程 panic");
        }
        let left = load_tvbox_metas(&dir);
        assert_eq!(left.len(), N - 8, "并发删应精确删掉 8 条：{}", left.len());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// ★ B3：链接导入成功 ⇒ 盖 installed 时刻的初始章；文本导入 ⇒ 不盖
    ///
    /// ```text
    /// 链接导入：刚刚从那个链接成功下载并安装 ⇒ 那是**已发生的事实**，
    ///          显示成"从未更新"= 把已发生的说成未发生（读数说谎）。
    /// 文本导入：磁盘上确实没有可核对的链接 ⇒ "从未更新"才是实话。
    /// ```
    /// 证红：把 import 里的 `last_update_at` 改回恒 0 ⇒ 第一条红。
    #[tokio::test]
    async fn t5_link_import_stamps_initial_time() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
        let api = fake_api(&sink);

        // ── ① 链接导入：应当盖初始章 ───────────────────────────────────
        let dir = super::task5_ab_restart::unique_tmp_dir("t5initlink");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");
        let sub_url = format!("{}/cfg/v2.json", sink.url());
        let res = import_tvbox_config(&st, &sub_url).await.expect("链接导入失败");
        let link_ids: Vec<String> = res["imported"]
            .as_array()
            .map(|a| a.iter().map(|x| x["id"].as_str().unwrap_or_default().to_string()).collect())
            .unwrap_or_default();
        assert!(!link_ids.is_empty(), "链接导入应产出源：{res}");
        for id in link_ids.iter() {
            let m = read_tvbox_meta(&dir, id).unwrap();
            assert!(
                m.last_update_at > 0,
                "★ 链接导入成功必须盖初始章（否则用户要等 24h 才第一次看见时间）：{m:?}"
            );
            assert!(m.last_update_ok, "初始章是成功章：{m:?}");
            assert_eq!(
                m.last_update_at, m.installed_at,
                "★ 初始章的时间 == 安装时刻（那是真实下载完成的时刻）：{m:?}"
            );
        }
        drop(st);
        let _ = std::fs::remove_dir_all(&dir);

        // ── ② 文本导入：如实不盖（没有可核对的链接）────────────────────
        let dir2 = super::task5_ab_restart::unique_tmp_dir("t5inittext");
        std::fs::create_dir_all(&dir2).expect("建临时目录失败");
        let st2 = AppState::bootstrap(dir2.clone()).await.expect("bootstrap 失败");
        let cfg_text = format!(
            "{{\"sites\":[{{\"key\":\"k1\",\"name\":\"甲站\",\"type\":1,\"api\":\"{api}\"}}]}}"
        );
        let res2 = import_tvbox_config(&st2, &cfg_text).await.expect("文本导入失败");
        let text_ids: Vec<String> = res2["imported"]
            .as_array()
            .map(|a| a.iter().map(|x| x["id"].as_str().unwrap_or_default().to_string()).collect())
            .unwrap_or_default();
        assert!(!text_ids.is_empty(), "文本导入应产出源：{res2}");
        for id in text_ids.iter() {
            let m = read_tvbox_meta(&dir2, id).unwrap();
            assert_eq!(
                m.last_update_at, 0,
                "★ 文本导入没有可核对的链接 ⇒ 如实「从未更新」（不盖章）：{m:?}"
            );
            assert!(m.source_url.is_none(), "文本导入不该有 source_url：{m:?}");
        }
        drop(st2);
        let _ = std::fs::remove_dir_all(&dir2);
    }
}

// ───────────────────────────────────────────────────────────────────────
//  ⚠️ 以下测试**要联网**，默认不跑（cargo test 会 skip）。
//     手动取证：
//     cargo test --lib real_sites -- --ignored --nocapture --test-threads=1
//
// 为什么不放进默认套件：它们依赖第三方站点是否可达 —— 别人家的站点
// 挂了不该让本仓库的 CI 变红。但它们**必须存在**：
// ```text
// 单元测试只能证明"我写的解析对"，证明不了"真实配置长这样"。
// 前者用假数据自证，后者只能拿真站点跑。
// ```
#[cfg(test)]
mod real_sites {
    use super::*;
    use crate::state::AppState;

    /// 用户实测可用的两个真实 TVBox 配置地址
    const SITES: [(&str, &str); 2] = [
        ("王二小", "https://9280.kstore.vip/newwex.json"),
        ("菜妮丝", "https://tv.xn--yhqu5zs87a.top"),
    ];

    /// 真实下载 + 解析：只证明"我读得懂真实配置"
    #[tokio::test]
    #[ignore = "需要联网，手动跑：cargo test --lib real_sites -- --ignored --nocapture"]
    async fn real_configs_parse_and_report_what_is_convertible() {
        let client = probe_client();
        for (label, url) in SITES.iter() {
            let text = match fetch_config_text(&client, url).await {
                Ok(t) => t,
                Err(e) => {
                    println!("[EVIDENCE] REAL-download {label} 失败（跳过，不算失败）：{e}");
                    continue;
                }
            };
            let cfg = match parse_loose_json(&text) {
                Ok(c) => c,
                Err(e) => {
                    // 如实取证：把**实际拿到的前 300 字节**打出来，
                    // 否则"解析失败"无法定位（是反爬页？是空 body？）
                    let head: String = text.chars().take(300).collect();
                    println!(
                        "[EVIDENCE] REAL-parse {label} 失败：{e}；textLen={} head={:?}",
                        text.len(),
                        head
                    );
                    continue;
                }
            };
            let (jobs, skipped, lives) = collect_sites(&cfg, url);
            let mut by_type: std::collections::BTreeMap<String, usize> = Default::default();
            for s in skipped.iter() {
                let k = s
                    .get("type")
                    .map(|v| v.to_string())
                    .unwrap_or_else(|| "null".to_string());
                *by_type.entry(k).or_insert(0) += 1;
            }
            println!(
                "[EVIDENCE] REAL {label} url={url} bytes={} sites={} convertible={} skipped={} lives={} byType={:?}",
                text.len(),
                cfg.get("sites").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0),
                jobs.len(),
                skipped.len(),
                lives.len(),
                by_type
            );
            if let Some(j) = jobs.first() {
                println!("[EVIDENCE] REAL {label} first-convertible key={} name={} api={}", j.key, j.name, j.api);
            }
            // 多仓检测：真实配置里也会出现只有 urls 的（那时这里会打印出来）
            let repos = multi_repo_repos(&cfg, url);
            println!("[EVIDENCE] REAL {label} multiRepoRepos={}", repos.len());
        }
    }

    /// 诊断：为什么同一个 URL 在不同客户端上返回不同内容
    ///
    /// 实测（2026-10-04）菜妮丝 https://tv.xn--yhqu5zs87a.top 对 node fetch 回
    /// 18.5KB 的配置 JSON，对 reqwest 回 13.5KB 的**下载页 HTML**。
    /// 这个测试逐个变量排除：HTTP 版本 / Accept / Accept-Encoding / UA。
    #[tokio::test]
    #[ignore = "诊断用，需要联网"]
    async fn diagnose_content_negotiation() {
        let url = "https://tv.xn--yhqu5zs87a.top";
        let variants: Vec<(&str, reqwest::Client)> = vec![
            (
                "default",
                reqwest::Client::builder()
                    .user_agent(TVBOX_UA)
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
            (
                "http1_only",
                reqwest::Client::builder()
                    .user_agent(TVBOX_UA)
                    .http1_only()
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
            (
                "accept-star",
                reqwest::Client::builder()
                    .user_agent(TVBOX_UA)
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
            (
                "ua-chrome",
                reqwest::Client::builder()
                    .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
            (
                "no-ua",
                reqwest::Client::builder()
                    .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
                    .build()
                    .unwrap(),
            ),
        ];
        for (name, client) in variants.iter() {
            let mut req = client.get(url);
            if *name == "accept-star" {
                req = req.header(reqwest::header::ACCEPT, "*/*");
            }
            let res = match req.send().await {
                Ok(r) => r,
                Err(e) => {
                    println!("[EVIDENCE] DIAG {name}: send 失败 {e}");
                    continue;
                }
            };
            let ver = res.version();
            let status = res.status();
            let ct = res
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let ae = res
                .headers()
                .get(reqwest::header::CONTENT_ENCODING)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let text = res.text().await.unwrap_or_default();
            let is_json = text.trim_start().starts_with('{');
            let head: String = text.chars().take(60).collect();
            println!(
                "[EVIDENCE] DIAG {name}: ver={ver:?} status={status} ct={ct} contentEncoding={ae} len={} isJson={is_json} head={:?}",
                text.len(),
                head.replace('\n', " ")
            );
        }
    }

    /// 真实联网跑**生产命令** check_tvbox_updates
    ///
    /// 构造一个"用户昨天导入过菜妮丝配置"的本地状态（一个真实源 + 真实链接），
    /// 然后让生产命令自己去下载、解析、对比 —— 这是端到端取证，不是纯函数自证。
    #[tokio::test]
    #[ignore = "需要联网，手动跑：cargo test --lib real_sites -- --ignored --nocapture"]
    async fn real_check_updates_against_live_site() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let dir = super::task5_ab_restart::unique_tmp_dir("t12real");
        std::fs::create_dir_all(&dir).expect("建临时目录失败");
        let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

        // 用户本地已有的那个源：真实配置里唯一的 type1 站（key=非凡）
        {
            let mut list = st.third_party.write().expect("锁中毒");
            list.push(crate::model::PersistedProvider::Tvbox {
                id: "ffzy".to_string(),
                name: "非凡┃影视".to_string(),
                api: "http://cj.ffzyapi.com/api.php/provide/vod".to_string(),
                categories: Vec::new(),
                parsers: Vec::new(),
                ext: None,
            });
        }
        crate::commands_provider::persist_from_registry(&st).expect("落盘失败");

        let mut any_ok = false;
        for (label, url) in SITES.iter() {
            write_tvbox_meta(
                &dir,
                "ffzy",
                &TvboxSourceMeta {
                    source_url: Some(url.to_string()),
                    site_key: "非凡".to_string(),
                    site_name: "非凡┃影视".to_string(),
                    api: "http://cj.ffzyapi.com/api.php/provide/vod".to_string(),
                    installed_at: now_secs(),
                    ..Default::default()
                },
            )
            .expect("写 sidecar 失败");

            let res = match check_tvbox_updates(&st, None).await {
                Ok(v) => v,
                Err(e) => {
                    println!("[EVIDENCE] REAL-CHECK {label} 命令失败：{e}");
                    continue;
                }
            };
            println!("[EVIDENCE] REAL-CHECK {label} url={url} {res}");
            let it = &res["items"][0];
            if it["ok"] == serde_json::Value::Bool(true) {
                any_ok = true;
                println!(
                    "[EVIDENCE] REAL-CHECK {label} 远端可转换={} 新增={} 消失={} 变更={} 未变={}",
                    it["remoteConvertible"],
                    it["added"].as_array().map(|a| a.len()).unwrap_or(0),
                    it["removed"].as_array().map(|a| a.len()).unwrap_or(0),
                    it["changed"].as_array().map(|a| a.len()).unwrap_or(0),
                    it["unchanged"]
                );
            } else {
                println!("[EVIDENCE] REAL-CHECK {label} 如实报错（不算失败）：{}", it["error"]);
            }
        }

        // 两个站点都不可达（比如本机没网）时**不算失败** —— 这只是取证测试。
        if !any_ok {
            println!("[EVIDENCE] REAL-CHECK 两个真实站点都没查成（可能无网络）—— 本次未取得联网证据");
        }

        drop(st);
        let _ = std::fs::remove_dir_all(&dir);
    }
    /// ★ 核心：Owner 给的那份配置形态 —— **点播源全不可用，但有直播源**
    ///
    /// 这条门禁守两件事：
    /// 1. Java 源（type 3）不许被算进 imported（不虚报）
    /// 2. 直播源**必须**被导入、注册、落盘、并在重启后恢复
    ///    （放在早返回分支之前处理，否则这份配置的直播源永远进不来）
    #[tokio::test]
    async fn lives_are_imported_even_when_all_sites_are_java() {
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        // 自包含临时目录（不依赖相邻子模块的 helper，避免跨 mod 可见性纠缠）
        let dir = std::env::temp_dir().join(format!(
            "sourin_tvbox_lives_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).expect("建临时目录失败");

        // 1 个 Java 源（不可用）+ 1 个直播源 ⇒ 会走 jobs.is_empty() 早返回
        let cfg = concat!(
            r#"{"spider":"http://x/spider.jar;md5;000","#,
            r#""sites":[{"key":"j1","name":"Java源","type":3,"api":"csp_Foo"}],"#,
            r#""lives":[{"name":"测试直播","url":"http://127.0.0.1:1/test.m3u"}]}"#
        );

        let st = AppState::bootstrap(dir.clone()).await.expect("首次 bootstrap 失败");
        let res = import_tvbox_config(&st, cfg).await.expect("导入失败");
        println!("[EVIDENCE] L-import-result {res}");

        // ① Java 源不许进 imported
        assert_eq!(
            res["imported"].as_array().map(|a| a.len()).unwrap_or(0),
            0,
            "★ Java 源一个都不许被导入：{res}"
        );
        assert_eq!(
            res["skipped"].as_array().map(|a| a.len()).unwrap_or(0),
            1,
            "Java 源应进 skipped：{res}"
        );

        // ② 直播源必须被导入
        let live = res["liveImported"]
            .as_array()
            .expect("返回体必须有 liveImported");
        assert_eq!(live.len(), 1, "★ 直播源必须被导入：{res}");
        let lid = live[0]["id"].as_str().unwrap_or_default().to_string();
        assert!(!lid.is_empty(), "直播源必须带 id：{res}");
        println!("[EVIDENCE] L-live-id {lid}");

        // ③ 注册表里当场可见，且 kind 正确
        let m = st
            .registry
            .manifests()
            .into_iter()
            .find(|x| x.id == lid)
            .expect("★ 导入当场注册表里就该有直播源");
        assert_eq!(m.kind, "m3u_live", "kind 必须是 m3u_live，实际 {}", m.kind);
        assert!(m.capabilities.live, "必须声明 live 能力");

        // ④ 落盘（含变体标签，重启靠它认出来）
        let file = crate::persist::providers_file(&dir);
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        println!("[EVIDENCE] L-persisted-body {text}");
        assert!(text.contains(&lid), "清单应记录直播源 id：{text}");
        assert!(
            text.contains("m3u_live"),
            "清单应记录 m3u_live 变体标签：{text}"
        );
        drop(st);

        // ⑤ 重启后仍在（不带这一步就是"这次能用、重启消失"）
        let st2 = AppState::bootstrap(dir).await.expect("重启 bootstrap 失败");
        let m2 = st2
            .registry
            .manifests()
            .into_iter()
            .find(|x| x.id == lid)
            .expect("★ 重启后直播源应仍在注册表里");
        assert_eq!(m2.kind, "m3u_live");
        println!("[EVIDENCE] L-after-restart id={} kind={}", m2.id, m2.kind);
    }

    // ── 配置里的解析器（parses[]）──

    #[test]
    fn collect_parsers_takes_only_type0_with_http_url() {
        let cfg = serde_json::json!({
            "parses": [
                // 要的：type 0 + http 前缀
                {"name": "a", "type": 0, "url": "https://jx.example/?url="},
                // 跳过：type 3 是 WebView 式，本仓无法执行
                {"name": "b", "type": 3, "url": "Web"},
                // 跳过：空 url
                {"name": "c", "type": 0, "url": ""},
                // 跳过：不是 http
                {"name": "d", "type": 0, "url": "jx.example/?url="},
                // 要的：另一个 type 0
                {"name": "e", "type": 0, "url": "http://jx2.example/?url="},
                // 跳过：重复
                {"name": "f", "type": 0, "url": "https://jx.example/?url="},
            ]
        });
        let got = collect_parsers(&cfg);
        assert_eq!(
            got,
            vec![
                "https://jx.example/?url=".to_string(),
                "http://jx2.example/?url=".to_string(),
            ],
            "★ 只收 type:0 + http 且去重；type:3 不许混进来"
        );
    }

    #[test]
    fn collect_parsers_handles_missing_or_broken_section() {
        assert!(collect_parsers(&serde_json::json!({})).is_empty());
        assert!(collect_parsers(&serde_json::json!({"parses": "oops"})).is_empty());
        assert!(collect_parsers(&serde_json::json!({"parses": []})).is_empty());
    }

    #[test]
    fn with_parsers_is_a_builder_that_does_not_change_new() {
        // 关键：`new()` 签名不能变（既有调用点依赖它），
        // 解析器只能通过 builder 挂上。
        let p = TvboxAppleCmsProvider::new("t1", "n1", "http://x/api.php/provide/vod", vec![])
            .expect("构造应成功");
        assert!(p.parsers.is_empty(), "未调 with_parsers 时必须是空的");
        let p2 = p.with_parsers(vec!["https://jx.example/?url=".into()]);
        assert_eq!(p2.parsers.len(), 1);
    }

    #[test]
    fn old_persisted_tvbox_without_parsers_still_loads() {
        // 向后兼容：旧清单里没有 parsers 字段 ⇒ 读出来是空 Vec，行为退回内置兜底
        let json = r#"{"kind":"tvbox","id":"x","name":"n","api":"http://a/b","categories":[]}"#;
        let p: crate::model::PersistedProvider =
            serde_json::from_str(json).expect("旧清单必须仍能读");
        match p {
            crate::model::PersistedProvider::Tvbox { parsers, .. } => {
                assert!(parsers.is_empty(), "缺字段 ⇒ 空，不许解析失败")
            }
            _ => panic!("kind 应识别为 tvbox"),
        }
    }

}

// ── ★ 第19项：TVBox csp_Xxx 路由的门禁 ──
//
// 测试体在 csp/route_tests.rs（属于 csp 这条线的写范围），
// 但必须以 tvbox 的子模块形式编译 —— 判据对象是这里的私有函数。
#[cfg(test)]
#[path = "csp/route_tests.rs"]
mod t1040_csp_route;

// ── ★ 第19项收口：csp 源落盘 + 重启恢复的门禁（测试体内联，见 task-23 写范围）──
#[cfg(test)]
mod t1041_csp_persist {
// ═══════════════════════════════════════════════════════════════════════════
// t1041_csp_persist —— csp 源落盘 + 重启恢复（第19项收口）
//
// 覆盖四件事，缺一条这个功能就不算真的可用：
// ```text
// ① 落盘：providers.json 里**真的**有这条源，含 api=`csp_Bili` 与 ext
// ② 重启：同一个 data_dir 再 bootstrap ⇒ 源被重建，且走的是 csp 路由
// ③ 降级：未实现的类落盘后重启 ⇒ 只跳过它自己 + 有可查询的原因
// ④ 阴性对照：旧清单没有 ext 字段 ⇒ 照常能读（在 persist.rs 的单测里）
// ```
//
// ⚠️ 这里**故意不用真网络**：`CspProvider::new` 不联网（只有 home/list/detail/play 才发请求），
//    所以"重启恢复"可以在离线环境稳定复现。导入路径的真网络用例单独 `#[ignore]` 门禁。
// ═══════════════════════════════════════════════════════════════════════════

use super::*;
use crate::persist::{
    load_persisted, load_restore_failures, providers_file, save_persisted, RestoreFailure,
};
use crate::provider::MediaProvider;
use crate::state::AppState;

fn tmp(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!(
        "sourin-t1041-{tag}-{}-{}",
        std::process::id(),
        now_secs()
    ));
    std::fs::create_dir_all(&d).expect("建临时目录失败");
    // 别让 bootstrap 去起 8642 的遥控服务（并发跑测试会撞端口）
    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    d
}

/// 一条**像导入产出的** csp 源清单记录
fn csp_row(ext: Option<&str>) -> crate::model::PersistedProvider {
    crate::model::PersistedProvider::Tvbox {
        id: "tvbox1".to_string(),
        name: "哔哩｜资源合集".to_string(),
        api: "csp_Bili".to_string(),
        categories: vec![crate::model::TvboxCategoryEntry {
            id: "4".to_string(),
            name: "游戏".to_string(),
            pid: None,
        }],
        parsers: Vec::new(),
        ext: ext.map(|s| s.to_string()),
    }
}

// ── ① + ② 落盘 → 重启恢复 ───────────────────────────────────────────
#[tokio::test]
async fn csp_source_survives_restart_via_csp_route() {
    let dir = tmp("restart");
    // 先写一份"导入后应该长这样"的清单（等价于 import 的落盘结果）
    save_persisted(&dir, &[csp_row(Some(r#"{"n":"哔哩音乐"}"#))]).expect("写清单");

    // ── 首次启动 ──
    let st1 = AppState::bootstrap(dir.clone()).await.expect("首次 bootstrap");
    let m1 = st1
        .registry
        .manifests()
        .into_iter()
        .find(|m| m.id == "tvbox1");
    let m1 = m1.expect("csp 源必须在首次启动时被恢复");
    assert_eq!(m1.kind, "tvbox", "kind 仍是 tvbox（UI 分组不变）");
    assert!(
        m1.description.as_deref().unwrap_or("").contains("Rust 重写"),
        "★ 恢复出来的必须是 csp 的 Rust 实现，而不是苹果CMS：{:?}",
        m1.description
    );
    drop(st1);

    // ── 模拟重启：同一个 data_dir 再 bootstrap 一次 ──
    let st2 = AppState::bootstrap(dir.clone()).await.expect("重启 bootstrap");
    let m2 = st2
        .registry
        .manifests()
        .into_iter()
        .find(|m| m.id == "tvbox1")
        .expect("★ 重启后源还在（这正是第19项之前做不到的事）");
    assert!(
        m2.description.as_deref().unwrap_or("").contains("Rust 重写"),
        "重启后仍必须是 csp 路由建的源：{:?}",
        m2.description
    );

    // 清单里的 api / ext 必须原样保留（丢了 ext ⇒ 恢复出来的不是用户配的那个源）
    let saved = load_persisted(&dir);
    let row = saved
        .iter()
        .find(|p| p.id() == "tvbox1")
        .expect("清单里应仍有这条");
    match row {
        crate::model::PersistedProvider::Tvbox { api, ext, .. } => {
            assert_eq!(api, "csp_Bili", "★ api 必须保持 csp 形态（不是被补成 URL）");
            assert_eq!(
                ext.as_deref(),
                Some(r#"{"n":"哔哩音乐"}"#),
                "★★ ext 必须原样保存并读回 —— 丢了就等于换了个源"
            );
        }
        _ => panic!("应仍是 tvbox"),
    }

    // 重启没有失败 ⇒ 不该留下失败报告
    assert!(
        load_restore_failures(&dir).is_empty(),
        "全部成功时不该有 restore-failures.json"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

// ── ③ 未实现的类：只跳过它自己 + 原因可查询 ─────────────────────────
#[tokio::test]
async fn unimplemented_csp_is_skipped_on_restore_without_breaking_others() {
    let dir = tmp("degrade");
    /*
     * ★★ 2026-10-27（R3 增量批次，Lead 改）：样本从**写死 `csp_AppDrama`** 改成
     *    **动态取一个仍未实现的类**（`crate::csp::unimplemented_sample()`）。
     *
     * # 为什么必须改（这不是"迁就"，是判据本身的前提被推倒了）
     * ```text
     * 本条要验的是「**未实现的** csp 类在恢复时被跳过、且原因可查询」。
     * 它原先把 `csp_AppDrama` 当作"未实现"的样本 —— 那在写入时**是真的**。
     * 但 R3 批正在**批量实现**这些类：`AppDrama` 已落地并注册 ⇒
     *   · 它**不再是被跳过的**，于是 `bad-csp` 真的被注册进 registry
     *   · 断言 `!ids.contains("bad-csp")` 失败
     * ⇒ **判据没错，是"未实现样本"过期了**。
     * ```
     * # 为什么用现成的 `unimplemented_sample()` 而不是换一个写死的类名
     * ```text
     * `csp/mod.rs` 里已有该函数（它的注释逐字写明了本问题）：
     *   候选表按"最不可能马上被实现"排序，**运行时取第一个仍未实现的**；
     *   真的全实现了 ⇒ 明确 panic 说"这条反向断言该换判据"。
     * ⇒ 换写死的类名只是把同一个坑推给下一个落地的人（本批已连续踩到两次同形）；
     *   动态取样本才是**结构性**修法。
     * ```
     */
    let unimplemented = crate::csp::unimplemented_sample();
    let rows = vec![
        crate::model::PersistedProvider::Tvbox {
            id: "bad-csp".to_string(),
            name: "木偶".to_string(),
            api: unimplemented.to_string(),
            categories: Vec::new(),
            parsers: Vec::new(),
            ext: Some(r#"{"site":["https://123.666291.xyz"]}"#.to_string()),
        },
        // 一条完全无关、必须活下来的源（m3u 直播源不联网、不同类）
        crate::model::PersistedProvider::M3uLive {
            id: "live-1".to_string(),
            name: "某电视台".to_string(),
            url: "http://example.test/a.m3u".to_string(),
        },
    ];
    save_persisted(&dir, &rows).expect("写清单");

    let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
    let ids: Vec<String> = st.registry.manifests().iter().map(|m| m.id.clone()).collect();
    assert!(
        !ids.iter().any(|i| i == "bad-csp"),
        "未实现的 csp 类不该被注册（否则点进去必报错）：{ids:?}"
    );
    // ⚠️ M3uLiveProvider 的 manifest id 是**生成式**（`m3ulive-<hash>`），
    //    不是清单里那个 id —— 所以判据按前缀认，别按精确 id 认（那样会假红）
    assert!(
        ids.iter().any(|i| i.starts_with("m3ulive-")),
        "★ 一条坏源**不许**带走其它源：{ids:?}"
    );

    // 原因必须可查询（不能只在日志里）
    let fails = load_restore_failures(&dir);
    assert_eq!(fails.len(), 1, "应恰好一条失败记录，实际 {fails:?}");
    let f: &RestoreFailure = &fails[0];
    assert_eq!(f.id, "bad-csp");
    /*
     * ⚠️ 这两条**也必须**跟着样本走（第一版只改了 rows 里的 api ⇒ 换样本后立刻又红）：
     *    · `f.api` 必须是那个动态样本（不是写死的 `csp_AppDrama`）
     *    · `f.reason` 必须是**实现层原文** `"<样本> 尚未实现"`
     *      —— ★ 这正是本条要守的语义：用户据此判断"是等版本还是重试"，
     *        所以**不许**在这里放松成 `contains("尚未实现")`（那会放走"原因被改写"的缺陷）。
     */
    assert_eq!(f.api, unimplemented);
    assert_eq!(
        f.reason,
        format!("{unimplemented} 尚未实现"),
        "★ 原因必须是实现层原文（用户据此判断是等版本还是重试）"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

// ── ④ 清单文件本体：csp 记录必须带 ext（结构断言，防"字段加了但没写"）──
#[tokio::test]
async fn persisted_file_contains_csp_api_and_ext() {
    let dir = tmp("file-shape");
    save_persisted(&dir, &[csp_row(Some(r#"{"cookie":"http://127.0.0.1:9978/c.txt"}"#))])
        .expect("写清单");
    let raw = std::fs::read_to_string(providers_file(&dir)).expect("读清单");
    // ★ 用 JSON 解析而不是在 pretty 文本里找裸引号：
    //   ext 是**字符串里的 JSON**，落盘后引号都被转义成 \"，字符串匹配会假红
    let v: serde_json::Value = serde_json::from_str(&raw).expect("清单必须是合法 JSON");
    let row = &v[0];
    assert_eq!(row["kind"], "tvbox");
    assert_eq!(row["api"], "csp_Bili", "清单里必须有 api 原文");
    let ext = row["ext"].as_str().unwrap_or("");
    assert!(
        ext.contains("cookie") && ext.contains("127.0.0.1:9978"),
        "★ ext 必须落进文件（不是只在内存里），实际 ext={ext:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

// ── ⑥ 订阅更新路径：新 csp 源落盘时 ext 必须一起写（task-23 缺口）──────
//
// 为什么单独一条：task12 那批 update 用例**全是苹果CMS 源**，
// 更新路径的 `ext` 若被漏写，`zz_t1040` ④b 那种"文件里存在 `ext: {`"
// 的存在性断言**抓不到**（导入路径还写着，字符串照样在）。
// 所以这条走**真行为**：真的更新一次，然后读清单断言 ext 还在。
//
// ⚠️ 真网络：更新时会 `probe_site` → csp 的 `home()` 要打**上游接口**（真 HTTP）。
//    与 B10 同一条纪律：`#[ignore]`，显式跑必须给 CSP_LIVE=1。
#[tokio::test]
#[ignore = "真网络：CSP_LIVE=1 cargo test --lib t1041 --release -- --ignored --nocapture"]
async fn update_path_persists_ext_for_new_csp_source() {
    assert_eq!(
        std::env::var("CSP_LIVE").ok().as_deref(),
        Some("1"),
        "★ 这条要真网络（csp 探测）：显式跑就必须给 CSP_LIVE=1"
    );
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;

    let dir = tmp("update-ext");

    // ── 假订阅源站：一份"远端多了一条 csp_Bili"的配置 ──
    let cfg_body = r#"{"sites":[
      {"key":"bili-new","name":"哔哩｜新来的","type":3,"api":"csp_Bili",
       "ext":{"n":"远端配的分类名","cookie":"http://127.0.0.1:9978/file/bili_cookie.txt"}}
    ]}"#;
    let body_for_http = cfg_body.to_string();
    let listener = TcpListener::bind("127.0.0.1:0").expect("绑定假源站失败");
    let port = listener.local_addr().expect("取端口失败").port();
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(mut stream) = conn else { break };
            let mut reader = BufReader::new(stream.try_clone().expect("clone"));
            let mut line = String::new();
            let _ = reader.read_line(&mut line);
            loop {
                let mut h = String::new();
                match reader.read_line(&mut h) {
                    Ok(0) => break,
                    Ok(_) if h == "\r\n" || h == "\n" => break,
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body_for_http.len(),
                body_for_http
            );
            let _ = stream.write_all(resp.as_bytes());
            let _ = stream.flush();
        }
    });
    let sub_url = format!("http://127.0.0.1:{port}/tvbox.json");

    // ── 本地已有一个"同订阅"里的苹果CMS 源（update 要求这条 id 存在且有 srcUrl）──
    save_persisted(
        &dir,
        &[crate::model::PersistedProvider::Tvbox {
            id: "tvbox0".to_string(),
            name: "老源".to_string(),
            api: "http://cj.example.com/api.php/provide/vod".to_string(),
            categories: Vec::new(),
            parsers: Vec::new(),
            ext: None,
        }],
    )
    .expect("写清单");
    write_tvbox_meta(
        &dir,
        "tvbox0",
        &TvboxSourceMeta {
            source_url: Some(sub_url.clone()),
            site_key: "old".to_string(),
            site_name: "老源".to_string(),
            api: "http://cj.example.com/api.php/provide/vod".to_string(),
            installed_at: now_secs(),
            ..Default::default()
        },
    )
    .expect("写 meta");

    let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
    // apply_new=true ⇒ 远端新增的 csp 源要真的加进来（正是 ④d 描述的场景）
    let upd = update_tvbox_source(&st, "tvbox0", true, false)
        .await
        .expect("更新不该失败");
    println!("[EVIDENCE] t1041-update {upd}");
    let added = upd["added"].as_array().cloned().unwrap_or_default();
    assert_eq!(added.len(), 1, "远端新增的 csp 源应被加进来，实际 {upd}");
    assert_eq!(added[0]["api"], "csp_Bili");
    assert_eq!(
        added[0]["persisted"],
        serde_json::json!(true),
        "★ 更新路径同样要如实吐 persisted:true"
    );

    // ★ 本条的核心：**清单里**这条 csp 源必须带 ext（不是只在返回值里）
    let saved = load_persisted(&dir);
    let row = saved
        .iter()
        .find(|p| {
            matches!(p, crate::model::PersistedProvider::Tvbox { api, .. } if api == "csp_Bili")
        })
        .expect("清单里应有这条 csp 源");
    match row {
        crate::model::PersistedProvider::Tvbox { api, ext, .. } => {
            assert_eq!(api, "csp_Bili", "★ api 必须保持 csp 形态");
            let ext = ext.as_deref().unwrap_or("");
            assert!(
                ext.contains("远端配的分类名"),
                "★★★ 更新路径必须把 ext 一起落盘（漏写 ⇒ 重启后建出行为不对的源），实际 ext={ext:?}"
            );
        }
        _ => panic!("应落成 tvbox 记录"),
    }
    let _ = std::fs::remove_dir_all(&dir);
}

// ── ⑤ 真网络：导入一条 csp 源 ⇒ 报告 persisted=true 且清单里有 ext ──
//
// 与 B10 同一条纪律：真网络用例 `#[ignore]`，显式跑时必须给 CSP_LIVE=1。
#[tokio::test]
#[ignore = "真网络：CSP_LIVE=1 cargo test --lib t1041 --release -- --ignored --nocapture"]
async fn csp_live_import_persists_source_to_disk() {
    assert_eq!(
        std::env::var("CSP_LIVE").ok().as_deref(),
        Some("1"),
        "★ 这条要真网络：显式跑就必须给 CSP_LIVE=1（不给就失败，不许记成 ok）"
    );
    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    let dir = tmp("live-import");
    let cfg = r#"{"sites":[
      {"key":"bili1","name":"哔哩｜资源合集","type":3,"api":"csp_Bili",
       "ext":{"n":"哔哩音乐","cookie":"http://127.0.0.1:9978/file/bili_cookie.txt"}}
    ]}"#;
    let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
    let res = import_tvbox_config(&st, cfg).await.expect("导入");
    println!("[EVIDENCE] t1041-import {res}");
    let imported = res["imported"].as_array().cloned().unwrap_or_default();
    assert_eq!(imported.len(), 1, "应导入 1 条，实际 {res}");
    assert_eq!(
        imported[0]["persisted"],
        serde_json::json!(true),
        "★★ 现在 csp 源**真的**落盘，报告必须吐 true（旧值是 false）"
    );

    let saved = load_persisted(&dir);
    let row = saved.iter().find(|p| p.id() == "tvbox1").expect("清单里应有它");
    match row {
        crate::model::PersistedProvider::Tvbox { api, ext, .. } => {
            assert_eq!(api, "csp_Bili");
            let ext = ext.as_deref().unwrap_or("");
            assert!(ext.contains("哔哩音乐"), "★ ext 必须原样落盘，实际 {ext:?}");
        }
        _ => panic!("应落成 tvbox 记录"),
    }
    let _ = std::fs::remove_dir_all(&dir);
}

}

// ── ★ task-42：三处契约修正的门禁（陈旧报告到期 / csp id 顺序无关 / diff 比 ext）──
#[cfg(test)]
mod t1042_contract_fixes {
    use super::*;
    use crate::persist::{restore_failures_file, write_restore_failures, RestoreFailure};
    use crate::state::AppState;

    /// 本模块自带的站点构造器（task12 那两份是私有 helper，跨模块拿不到）
    fn local_ext(id: &str, key: &str, name: &str, api: &str, ext: Option<&str>) -> LocalSite {
        LocalSite {
            id: id.to_string(),
            key: key.to_string(),
            name: name.to_string(),
            api: api.to_string(),
            ext: ext.map(|s| s.to_string()),
            in_link: true,
        }
    }

    fn remote_ext(key: &str, name: &str, api: &str, ext: Option<&str>) -> RemoteSite {
        RemoteSite {
            key: key.to_string(),
            name: name.to_string(),
            api: api.to_string(),
            ext: ext.map(|s| s.to_string()),
        }
    }

    fn tmp(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "sourin-t1042-{tag}-{}-{}",
            std::process::id(),
            now_secs()
        ));
        std::fs::create_dir_all(&d).expect("建临时目录失败");
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        d
    }

    // ── ① 陈旧失败报告必须"到期"（病修好后不能一直挂红字）──
    #[tokio::test]
    async fn stale_restore_failures_are_deleted_after_clean_boot() {
        let dir = tmp("stale-report");
        // 造一份"上次启动有失败"的报告
        write_restore_failures(
            &dir,
            &[RestoreFailure {
                id: "bad".to_string(),
                api: "csp_AppDrama".to_string(),
                reason: "csp_AppDrama 尚未实现".to_string(),
            }],
        )
        .expect("写报告");
        assert!(restore_failures_file(&dir).exists(), "前置：报告先在");

        // 这次启动**零失败**（清单为空）
        let _st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");

        assert!(
            !restore_failures_file(&dir).exists(),
            "★★ 病修好之后再启动，旧报告必须被删 —— 陈旧告警比没有告警更误导。\
             改前 state.rs 用 `if !restore_failures.is_empty()` 包着写调用 ⇒ 空列表时\
             根本不调用、于是永远删不掉（注入：把那个 if 加回去，本条必红）"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── ② csp id 与配置顺序无关（appleCMS 的 to_id 行为不变）──
    #[test]
    fn csp_id_base_is_order_independent_and_apple_path_kept() {
        // csp：同名同类 ⇒ 同 id，与 index 无关（id_base_for 里不看 job.index）
        let a = csp_id_base("Bili", "哔哩｜资源合集");
        let b = csp_id_base("Bili", "哔哩｜资源合集");
        assert_eq!(a, b, "同一份配置里同一源必须同 id");
        assert!(a.starts_with("csp-bili-"), "口径：csp-<class 小写>-<crc32>，实际 {a}");
        assert_ne!(
            a,
            csp_id_base("Bili", "哔哩｜音乐合集"),
            "★ 不同名字必须不同 id（否则 10 个 csp_Bili 会撞成一个）"
        );
        // 顺序无关：文件名/序号不进 id —— 用两个不同 index 的 SiteJob 验证
        let mk = |i: usize| SiteJob {
            index: i,
            key: "k".to_string(),
            name: "哔哩｜资源合集".to_string(),
            api: "csp_Bili".to_string(),
            kind: Some(3),
            csp: Some("Bili".to_string()),
            ext: String::new(),
        };
        assert_eq!(
            id_base_for(&mk(0)),
            id_base_for(&mk(7)),
            "★★ csp 的 id 不许含配置序号（插一条/重排就全变 ⇒ 旧源残留 + 收藏失配）"
        );
        // appleCMS 行为**不变**：仍由 api host 兜底，同样与 index 无关
        assert_eq!(
            to_id("非凡┃影视", "http://cj.ffzyapi.com/api.php/provide/vod", 3),
            to_id("非凡┃影视", "http://cj.ffzyapi.com/api.php/provide/vod", 9),
            "苹果CMS 的 id 本来就不该随 index 变（改名会破坏既有收藏）"
        );
    }

    // ── ③ diff 必须能看出 ext 变化（否则"改了 ext 却报无需更新"）──
    #[test]
    fn diff_detects_ext_change() {
        let l = vec![local_ext(
            "id1",
            "k1",
            "哔哩｜资源合集",
            "csp_Bili",
            Some(r#"{"n":"旧"}"#),
        )];
        let r = vec![remote_ext(
            "k1",
            "哔哩｜资源合集",
            "csp_Bili",
            Some(r#"{"n":"新"}"#),
        )];
        let d = diff_sites(&l, &r);
        assert_eq!(
            d.changed.len(),
            1,
            "★★ ext 变了必须报 changed（csp 的站点列表/口令/分类覆盖都只在 ext 里）"
        );
        assert_eq!(d.added.len(), 0, "同一个 key 不是新增");
        assert_eq!(d.removed.len(), 0, "同一个 key 不是消失");

        // 对照一：ext 完全相同 ⇒ unchanged（不许对一切都报 changed）
        let same = vec![remote_ext(
            "k1",
            "哔哩｜资源合集",
            "csp_Bili",
            Some(r#"{"n":"旧"}"#),
        )];
        let d2 = diff_sites(&l, &same);
        assert_eq!(d2.changed.len(), 0, "ext 没变就不许报 changed");
        assert_eq!(d2.unchanged, 1);

        // 对照二：None 与 "空白串" 等价（落盘口径：没写 ≠ 写了空，但空白等于没写）
        let l_none = vec![local_ext("id1", "k1", "同名", "csp_Bili", None)];
        let r_blank = vec![remote_ext("k1", "同名", "csp_Bili", Some("   "))];
        assert_eq!(
            diff_sites(&l_none, &r_blank).changed.len(),
            0,
            "空白串应归一成 None，不许因此报 changed"
        );
    }

    // ── ②b 真网络：同一份配置重排后重新导入 ⇒ 同一源 id 不变（#[ignore] 纪律）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib t1042 --release -- --ignored --nocapture"]
    async fn csp_ids_survive_reorder_on_reimport() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 导入要探测 csp（真网络）：显式跑必须给 CSP_LIVE=1"
        );
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        let dir_a = tmp("reorder-a");
        let dir_b = tmp("reorder-b");

        let site = |n: &str, key: &str| {
            format!(
                r#"{{"key":"{key}","name":"{n}","type":3,"api":"csp_Bili"}}"#
            )
        };
        let cfg_a = format!(
            r#"{{"sites":[{},{}]}}"#,
            site("哔哩｜资源合集", "b1"),
            site("哔哩｜音乐合集", "b2")
        );
        let cfg_b = format!(
            r#"{{"sites":[{},{}]}}"#,
            site("哔哩｜音乐合集", "b2"),
            site("哔哩｜资源合集", "b1")
        );

        let st_a = AppState::bootstrap(dir_a.clone()).await.expect("bootstrap A");
        let res_a = import_tvbox_config(&st_a, &cfg_a).await.expect("导入 A");
        drop(st_a);
        let st_b = AppState::bootstrap(dir_b.clone()).await.expect("bootstrap B");
        let res_b = import_tvbox_config(&st_b, &cfg_b).await.expect("导入 B");

        let ids = |res: &serde_json::Value| -> std::collections::BTreeMap<String, String> {
            res["imported"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .iter()
                .map(|r| {
                    (
                        r["name"].as_str().unwrap_or("").to_string(),
                        r["id"].as_str().unwrap_or("").to_string(),
                    )
                })
                .collect()
        };
        let (ia, ib) = (ids(&res_a), ids(&res_b));
        println!("[EVIDENCE] t1042-reorder A={ia:?} B={ib:?}");
        assert_eq!(ia.len(), 2, "两次导入都应得到 2 个源：{res_a} / {res_b}");
        for name in ["哔哩｜资源合集", "哔哩｜音乐合集"] {
            assert_eq!(
                ia.get(name),
                ib.get(name),
                "★★ 重排配置后重新导入，「{name}」的 id 必须不变（否则收藏/进度全失配）"
            );
        }
        let _ = std::fs::remove_dir_all(&dir_a);
        let _ = std::fs::remove_dir_all(&dir_b);
    }

    // ═══════════════════════════════════════════════════════════════════
    // t8b_direct —— N8b-1 直连化门禁（2026-10-27）
    //
    // ① 导入/订阅更新**不产 js 文件**（文件系统断言：导入前后插件目录文件集不变）
    // ② 未实现类仍进"尚未实现"清单（逐字，既有机制不被直连化改动）
    // ③ 迁移 js 的还原数据通道：清单只认 tvbox-convert 标记；还原全链路
    //    （探测成功才建源+删 js；探测失败一个字节不动；手写插件拒绝）
    // ═══════════════════════════════════════════════════════════════════
    mod t8b_direct {
        use super::*;
        use crate::persist::save_persisted;
        use std::io::{BufRead, BufReader, Write};
        use std::net::TcpListener;

        fn tmp8b(tag: &str) -> std::path::PathBuf {
            let d = std::env::temp_dir().join(format!(
                "sourin-t8b-{tag}-{}-{}",
                std::process::id(),
                now_secs()
            ));
            std::fs::create_dir_all(&d).expect("建临时目录失败");
            std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
            d
        }

        /// 插件目录里的 .js 文件名集合（排序后比对 ⇒ "导入不新增文件"的判据）
        fn js_files(dir: &std::path::Path) -> Vec<String> {
            let pdir = crate::state::plugins_dir(dir);
            let mut v: Vec<String> = std::fs::read_dir(&pdir)
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|e| {
                    let p = e.path();
                    if p.extension().and_then(|s| s.to_str()) == Some("js") {
                        p.file_name().and_then(|s| s.to_str()).map(|s| s.to_string())
                    } else {
                        None
                    }
                })
                .collect();
            v.sort();
            v
        }

        /// 假站：同一端口回答三种请求（配置 / 苹果CMS 分类 / 苹果CMS 列表）
        ///
        /// 配置体由 `cfg_with_api` 生成 —— 端口绑定后才知道 api 地址，
        /// 所以配置里要写 api 的站点交给这个闭包现场拼。
        fn spawn_fake_site(
            cfg_with_api: impl Fn(&str) -> String + Send + 'static,
        ) -> (String, String) {
            let api_base = "/api.php/provide/vod";
            let class_body =
                r#"{"class":[{"type_id":"1","type_name":"电影"},{"type_id":"2","type_name":"剧集"}]}"#.to_string();
            let video_body = r#"{"list":[{"vod_id":"10","vod_name":"测试片","vod_pic":"",
                "vod_play_url":"第1集$https://cdn.example.com/1.m3u8","vod_content":"简介","vod_remarks":"HD"}],
                "total":1}"#
                .to_string();
            let listener = TcpListener::bind("127.0.0.1:0").expect("绑定假站失败");
            let port = listener.local_addr().expect("取端口失败").port();
            let cfg_body = cfg_with_api(&format!("http://127.0.0.1:{port}{api_base}"));
            std::thread::spawn(move || {
                for conn in listener.incoming() {
                    let Ok(mut stream) = conn else { break };
                    let mut reader = BufReader::new(stream.try_clone().expect("clone"));
                    let mut reqline = String::new();
                    let _ = reader.read_line(&mut reqline);
                    loop {
                        let mut h = String::new();
                        match reader.read_line(&mut h) {
                            Ok(0) => break,
                            Ok(_) if h == "\r\n" || h == "\n" => break,
                            Ok(_) => {}
                            Err(_) => break,
                        }
                    }
                    let body = if reqline.contains("ac=videolist") {
                        &video_body
                    } else if reqline.contains("ac=list") {
                        &class_body
                    } else {
                        &cfg_body
                    };
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = stream.write_all(resp.as_bytes());
                    let _ = stream.flush();
                }
            });
            (
                format!("http://127.0.0.1:{port}/tvbox.json"),
                format!("http://127.0.0.1:{port}{api_base}"),
            )
        }

        /// 一份迁移 js 的源码模板（头注释形态与转换器产物一致）
        fn conv_js(id: &str, upstream: Option<&str>) -> String {
            let up = upstream
                .map(|u| format!(" * 上游接口（苹果CMS v10）：{u}\n"))
                .unwrap_or_default();
            format!(
                "/**\n * 测试源 —— 由 TVBox 源自动转换\n *\n * @id {id}\n * @author tvbox-convert\n *\n{up} */\nconst API = 1;\n"
            )
        }

        /// ①+a 导入不产 js：type:1（真探测）+ 未实现 csp（skipped）⇒ 插件目录文件集不变
        ///
        /// ★★ 快照必须取在 `bootstrap` **之后**（2026-10-27 修，第一版是错的）：
        /// ```text
        /// 错版：before 取在 bootstrap 之前 ⇒ before=[] ，
        ///       而 bootstrap 会释放内置 demo.js ⇒ after=["demo.js"]
        ///       ⇒ 断言恒红（且红的原因**不是**"导入产了 js"，是快照取早了）。
        ///       更糟的是反过来如果内置 demo 释放失败，before==after==[] 会**恒绿**
        ///       ⇒ 一条恒红/恒绿双面失效的门禁。
        /// 正版：先 bootstrap，再取 before；并断言 before 里**确实有** demo.js
        ///       （否则这条门禁就是空转的 —— 反假绿）。
        /// ```
        #[tokio::test]
        async fn import_produces_no_js_files() {
            let dir = tmp8b("import-nojs");
            let (sub_url, _api) = spawn_fake_site(|api| {
                format!(
                    r#"{{"sites":[
                  {{"key":"a1","name":"直连站","type":1,"api":"{api}"}},
                  {{"key":"dl","name":"东篱","type":3,"api":"csp_DongLi"}}
                ]}}"#
                )
            });
            let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
            let before = js_files(&dir);
            assert!(
                before.iter().any(|f| f == "demo.js"),
                "★ 前置：内置 demo.js 必须已在（否则 before/after 都空 ⇒ 本门禁空转）：{before:?}"
            );
            let res = import_tvbox_config(&st, &sub_url).await.expect("导入");
            drop(st);

            let after = js_files(&dir);
            assert_eq!(
                before, after,
                "★ 导入前后插件目录的 .js 文件集必须逐字节相同（直连化：导入绝不产 js）"
            );
            // 直连化的另一半：type:1 真的进了（不是全跳过导致假绿）
            let imported = res["imported"].as_array().cloned().unwrap_or_default();
            assert_eq!(imported.len(), 1, "type:1 必须真导入：{res}");
            assert_eq!(imported[0]["kindTag"], "appleCms");
            // 未实现类仍是逐字原因（既有机制不许被本次改动弄丢）
            let skipped = res["skipped"].as_array().cloned().unwrap_or_default();
            assert!(
                skipped.iter().any(|s| s["reason"] == "csp_DongLi 尚未实现"),
                "未实现类必须逐字进清单：{skipped:?}"
            );
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// ①+b 订阅更新同样不产 js：更新路径走完（新增 type:1 真注册）后文件集不变
        #[tokio::test]
        async fn update_produces_no_js_files() {
            let dir = tmp8b("update-nojs");
            let (sub_url, _api) = spawn_fake_site(|api| {
                format!(
                    r#"{{"sites":[
                  {{"key":"a1","name":"直连站","type":1,"api":"{api}"}},
                  {{"key":"b1","name":"新来的","type":1,"api":"{api}"}}
                ]}}"#
                )
            });
            save_persisted(
                &dir,
                &[crate::model::PersistedProvider::Tvbox {
                    id: "tvbox0".to_string(),
                    name: "老源".to_string(),
                    api: "http://127.0.0.1:1/api.php/provide/vod".to_string(),
                    categories: Vec::new(),
                    parsers: Vec::new(),
                    ext: None,
                }],
            )
            .expect("写清单");
            write_tvbox_meta(
                &dir,
                "tvbox0",
                &TvboxSourceMeta {
                    source_url: Some(sub_url.clone()),
                    site_key: "a1".to_string(),
                    site_name: "直连站".to_string(),
                    api: "http://127.0.0.1:1/api.php/provide/vod".to_string(),
                    installed_at: now_secs(),
                    ..Default::default()
                },
            )
            .expect("写 meta");

            let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
            // ★ 快照取在 bootstrap **之后**（理由同 ①+a：bootstrap 会释放内置 demo.js）
            let before = js_files(&dir);
            assert!(
                before.iter().any(|f| f == "demo.js"),
                "★ 前置：内置 demo.js 必须已在（否则本门禁空转）：{before:?}"
            );
            let upd = update_tvbox_source(&st, "tvbox0", true, false)
                .await
                .expect("更新");
            drop(st);
            let after = js_files(&dir);

            assert!(
                !upd["added"].as_array().cloned().unwrap_or_default().is_empty(),
                "更新必须真的新增了源（否则这条是空转假绿）：{upd}"
            );
            assert_eq!(
                before, after,
                "★ 订阅更新前后插件目录的 .js 文件集必须相同（更新直达 Rust 配置，不经 js 中转）"
            );
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// ②+a 清单只认 tvbox-convert 标记；手写插件完全不出现
        #[tokio::test]
        async fn migratable_list_classifies_by_marker() {
            let dir = tmp8b("migrate-list");
            let pdir = crate::state::plugins_dir(&dir);
            std::fs::create_dir_all(&pdir).expect("建插件目录");
            std::fs::write(
                pdir.join("conv.js"),
                conv_js("conv1", Some("http://conv.example.com/api.php/provide/vod")),
            )
            .expect("写迁移插件");
            std::fs::write(pdir.join("conv-noup.js"), conv_js("conv2", None)).expect("写无上游的迁移插件");
            std::fs::write(
                pdir.join("hand.js"),
                "/**\n * 我自己的插件\n * @id hand1\n * @author myself\n *\n * 上游接口（苹果CMS v10）：http://hand.example.com/api.php/provide/vod\n */\nconst API = 1;\n",
            )
            .expect("写手写插件");

            let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
            let res = migratable_js(&st).expect("清单");
            drop(st);
            let items = res["items"].as_array().cloned().unwrap_or_default();
            let undet = res["undetermined"].as_array().cloned().unwrap_or_default();
            assert_eq!(items.len(), 1, "只有标记+上游齐的进 items：{res}");
            assert_eq!(items[0]["file"], "conv.js");
            assert_eq!(items[0]["upstream"], "http://conv.example.com/api.php/provide/vod");
            assert_eq!(undet.len(), 1, "标记对但上游提取不出 ⇒ 判定不出清单：{res}");
            assert_eq!(undet[0]["file"], "conv-noup.js");
            let dump = serde_json::to_string(&res).unwrap();
            assert!(
                !dump.contains("hand.js") && !dump.contains("hand1"),
                "★ 硬边界：手写插件绝不能出现在任何一段里：{dump}"
            );
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// ②+b 还原拒绝手写插件（一个字节不动）
        #[tokio::test]
        async fn restore_rejects_handwritten() {
            let dir = tmp8b("restore-hand");
            let pdir = crate::state::plugins_dir(&dir);
            std::fs::create_dir_all(&pdir).expect("建插件目录");
            let hand = pdir.join("hand.js");
            std::fs::write(
                &hand,
                "/**\n * @id hand1\n * @author myself\n * 上游接口（苹果CMS v10）：http://x.example.com/api.php/provide/vod\n */\nconst API = 1;\n",
            )
            .expect("写手写插件");
            let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
            let err = restore_tvbox_js(&st, "hand.js")
                .await
                .expect_err("手写插件必须被拒绝");
            drop(st);
            assert!(
                err.contains("不是 TVBox 迁移产生的插件"),
                "拒绝原因要点名标记：{err}"
            );
            assert!(hand.exists(), "★ 拒绝后文件必须原样存在");
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// ②+c 还原全链路：真探测 → 建直连源（与导入同路）→ 删 js
        #[tokio::test]
        async fn restore_builds_direct_source_then_deletes_js() {
            let dir = tmp8b("restore-full");
            let (_sub, api) = spawn_fake_site(|_api| r#"{"sites":[]}"#.to_string());
            let pdir = crate::state::plugins_dir(&dir);
            std::fs::create_dir_all(&pdir).expect("建插件目录");
            // ★ 先 bootstrap（它会释放内置 demo.js），**再**写迁移插件 + 取快照。
            //   理由：把 demo.js 排除在"这次还原动到的东西"之外，判据才有意义。
            let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
            std::fs::create_dir_all(&pdir).expect("建插件目录");
            std::fs::write(pdir.join("conv.js"), conv_js("conv1", Some(&api))).expect("写迁移插件");

            let before = js_files(&dir);
            assert!(
                before.iter().any(|f| f == "conv.js") && before.iter().any(|f| f == "demo.js"),
                "★ 前置：conv.js 与内置 demo.js 都要在（否则本门禁空转）：{before:?}"
            );
            let res = restore_tvbox_js(&st, "conv.js").await.expect("还原");
            let after = js_files(&dir);
            let persisted = crate::persist::load_persisted(&dir);
            drop(st);

            assert_eq!(res["restored"], serde_json::json!(true), "{res}");
            assert_eq!(res["api"], serde_json::json!(api), "{res}");
            assert_eq!(res["deleted"], serde_json::json!(true), "{res}");
            let id = res["id"].as_str().expect("id").to_string();
            assert!(
                !after.contains(&"conv.js".to_string()),
                "★ 还原后 js 文件必须已删除：{after:?}"
            );
            // 直连源真的落了盘、真的在 registry（kind=tvbox，与导入产物同形）
            assert!(
                persisted.iter().any(|p| matches!(p,
                    crate::model::PersistedProvider::Tvbox { api: a, .. } if a == &api)),
                "清单里必须有同 api 的 tvbox 直连源：{persisted:?}"
            );
            assert_eq!(
                before.iter().filter(|f| f.as_str() == "demo.js").count(),
                after.iter().filter(|f| f.as_str() == "demo.js").count(),
                "内置 demo.js 不该被这次还原动到"
            );
            let _ = id;
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// ②+d 探测失败 ⇒ 一个字节都不动（文件在、清单不变）
        #[tokio::test]
        async fn restore_probe_failure_keeps_everything() {
            let dir = tmp8b("restore-dead");
            let pdir = crate::state::plugins_dir(&dir);
            std::fs::create_dir_all(&pdir).expect("建插件目录");
            std::fs::write(
                pdir.join("conv.js"),
                conv_js("conv1", Some("http://127.0.0.1:9/api.php/provide/vod")),
            )
            .expect("写迁移插件");
            let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
            let err = restore_tvbox_js(&st, "conv.js")
                .await
                .expect_err("探测失败必须 Err");
            let persisted = crate::persist::load_persisted(&dir);
            drop(st);
            assert!(err.contains("上游探测失败"), "失败原因要点名探测：{err}");
            assert!(
                crate::state::plugins_dir(&dir).join("conv.js").exists(),
                "★ 探测失败后迁移 js 必须原样在"
            );
            assert!(
                !persisted.iter().any(|p| matches!(p,
                    crate::model::PersistedProvider::Tvbox { api, .. } if api.contains("127.0.0.1:9"))),
                "探测失败不许建源：{persisted:?}"
            );
            let _ = std::fs::remove_dir_all(&dir);
        }

        /// ②+e alreadyLinked：同接口直连源已存在 ⇒ 只删 js，不重建
        #[tokio::test]
        async fn restore_already_linked_only_deletes_js() {
            let dir = tmp8b("restore-linked");
            let pdir = crate::state::plugins_dir(&dir);
            std::fs::create_dir_all(&pdir).expect("建插件目录");
            let api = "http://linked.example.com/api.php/provide/vod";
            std::fs::write(pdir.join("conv.js"), conv_js("conv1", Some(api))).expect("写迁移插件");
            save_persisted(
                &dir,
                &[crate::model::PersistedProvider::Tvbox {
                    id: "linked1".to_string(),
                    name: "已是直连".to_string(),
                    api: api.to_string(),
                    categories: Vec::new(),
                    parsers: Vec::new(),
                    ext: None,
                }],
            )
            .expect("写清单");
            let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap");
            let res = restore_tvbox_js(&st, "conv.js").await.expect("还原");
            drop(st);
            assert_eq!(res["restored"], serde_json::json!(false), "{res}");
            assert_eq!(res["alreadyLinked"], serde_json::json!(true), "{res}");
            assert_eq!(res["linkedProviderId"], serde_json::json!("linked1"), "{res}");
            assert_eq!(res["deleted"], serde_json::json!(true), "{res}");
            assert!(
                !crate::state::plugins_dir(&dir).join("conv.js").exists(),
                "js 必须已删"
            );
            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// t_ext_import —— 「导入链路把 ext 弄丢」的门禁（App99/AppGet/AppRJ/HJZhenCai/Wogg）
//
// # 现场（`.probe/each-post-migration.txt`，2026-10-29）
// ```text
// csp-app99        错：ext 不是合法 JSON：EOF while parsing a value at line 1 column 0
// csp-app-get      错：ext 里缺 dataKey（本站响应体是 AES/CBC 密文，缺密钥无法解）
// csp-app-rj       错：ext 里没有站点地址（DEX init 读的是 ext 的 `url` 字段）
// csp-hj-zhen-cai  错：HJZhenCai 需要 ext 里的站点地址（键 `site`）
// csp-wogg         错：Wogg 需要 ext 里的镜像列表（键 `site`）
// ```
// 这 5 条都是 **builtin** 源（`state.rs` 给每个 csp 类自动建的那条，`ext` 恒空）。
// 而**原始订阅里这几类是有 ext 的**（`.probe/ext-real-fragments.json` 逐字抄自
// `.probe/ref-subscription.json`）⇒ ext 是在**导入这一跳**丢的，不是配置里没有。
// ═══════════════════════════════════════════════════════════════════════════
#[cfg(test)]
mod t_ext_import {
    use super::*;

    /// 真实 ext 片段仓（`.probe/ext-real-fragments.json`，由参考订阅逐字抄出）
    fn fixture_path() -> std::path::PathBuf {
        if let Ok(p) = std::env::var("SOURIN_EXT_FIXTURE") {
            return std::path::PathBuf::from(p);
        }
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../.probe/ext-real-fragments.json")
    }

    fn fixture() -> serde_json::Value {
        let p = fixture_path();
        let raw = std::fs::read_to_string(&p)
            .unwrap_or_else(|e| panic!("读不到真实 ext 片段仓 {}：{e}", p.display()));
        serde_json::from_str(&raw).expect("片段仓必须是合法 JSON")
    }

    fn tmp(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "sourin-ext-{tag}-{}-{}",
            std::process::id(),
            now_secs()
        ));
        std::fs::create_dir_all(&d).expect("建临时目录失败");
        std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
        d
    }

    /// 把片段仓里那几个站拼成一份**真实现场形状**的 TVBox 配置
    fn config_from_fixture() -> String {
        let f = fixture();
        let sites: Vec<serde_json::Value> = f["sites"]
            .as_array()
            .expect("sites 应是数组")
            .iter()
            .map(|s| {
                serde_json::json!({
                    "key": s["key"],
                    "name": s["name"],
                    "type": 3,
                    "api": s["api"],
                    "ext": parse_loose_json(s["extText"].as_str().unwrap_or("{}"))
                        .expect("片段仓里的 extText 必须是合法 JSON"),
                })
            })
            .collect();
        serde_json::json!({ "sites": sites }).to_string()
    }

    /// ★ 诊断（真网络，ignored）：把真实 ext 配置走一遍**真导入链路**，逐条打印归处。
    ///
    /// 给了 `SOURIN_DATA_DIR` ⇒ 就导入到那个目录并**保留**（供随后跑
    /// `live_search_count` 直接看"这几家能不能真搜到"）；否则用临时目录并在末尾删掉。
    #[tokio::test]
    #[ignore = "真网络：片段仓里的镜像要真的发请求"]
    async fn diag_import_real_ext_sites() {
        let keep = std::env::var("SOURIN_DATA_DIR").ok();
        let dir = match &keep {
            Some(d) => {
                let p = std::path::PathBuf::from(d);
                std::fs::create_dir_all(&p).expect("建数据目录失败");
                std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
                p
            }
            None => tmp("diag"),
        };
        let st = crate::state::AppState::bootstrap(dir.clone()).await.expect("bootstrap");
        let cfg = config_from_fixture();
        let rep = import_tvbox_config(&st, &cfg).await.expect("导入应当返回报告");
        eprintln!("[EXT-DIAG] 报告 imported={} skipped={}",
            rep["imported"].as_array().map(|a| a.len()).unwrap_or(0),
            rep["skipped"].as_array().map(|a| a.len()).unwrap_or(0));
        for r in rep["imported"].as_array().cloned().unwrap_or_default() {
            eprintln!("[EXT-DIAG] 导入 {} | {} | 分类={} | 落盘={}",
                r["id"], r["api"], r["categories"], r["persisted"]);
        }
        for r in rep["skipped"].as_array().cloned().unwrap_or_default() {
            eprintln!("[EXT-DIAG] 跳过 {} | stage={} | {}",
                r["name"], r["stage"], r["reason"]);
        }
        let saved = crate::persist::load_persisted(&dir);
        for p in &saved {
            if let crate::model::PersistedProvider::Tvbox { api, ext, .. } = p {
                let e = ext.as_deref().unwrap_or("");
                eprintln!("[EXT-DIAG] 落盘 {} extLen={} 可解析={}",
                    api, e.len(), parse_loose_json(e).is_ok());
            }
        }
        if keep.is_none() {
            let _ = std::fs::remove_dir_all(&dir);
        } else {
            eprintln!("[EXT-DIAG] 数据目录保留在 {}（可直接跑 live_search_count）", dir.display());
        }
    }

    /// 每类源**必须**带的那几个 ext 键（判据逐字来自真实现场的报错文案）
    fn required_keys(api: &str) -> &'static [&'static str] {
        match api {
            // "HJZhenCai 需要 ext 里的站点地址（键 `site`）"
            "csp_HJZhenCai" | "csp_Wogg" | "csp_SeedHub" | "csp_4KZhinan" => &["site"],
            // "ext 里没有站点地址（DEX init 读的是 ext 的 `url` 字段）"
            "csp_AppRJ" => &["url"],
            // "ext 里缺 dataKey（本站响应体是 AES/CBC 密文）"
            "csp_AppGet" => &["url", "dataKey"],
            // App99：DEX systemInit 用 host + appkey（真响应 200 application/json）
            "csp_App99" => &["host", "appkey"],
            _ => &[],
        }
    }

    // ── 门禁 ①：真实 ext 片段经「配置 → SiteJob」不许被改写/丢掉 ──────────
    //
    // 判据三条，缺一条这条链就不算通：
    // ```text
    // ① ext 的**语义**不许变：
    //      字符串形态 → 逐字相同（`ext_text` 对字符串是原样透传）
    //      对象形态   → 解析后**值相等**（不是逐字：serde_json 默认 BTreeMap，
    //                   多键 ext 的键序会被排成字典序 —— 那是等价 JSON，不是丢失。
    //                   2026-10-29 实测：App99 的 8 键 ext 因此假红过一次，
    //                   判据改成"值相等"才是真契约）
    // ② 仍是合法 JSON（`parse_loose_json` 能读）
    // ③ 该类的必需键都在（site / url / dataKey / host+appkey）
    // ```
    #[test]
    fn real_ext_fragment_passes_through_collect_sites() {
        let cfg_text = config_from_fixture();
        let cfg = parse_loose_json(&cfg_text).expect("配置必须可解析");
        let (jobs, _, _) = collect_sites(&cfg, "");
        let frags = fixture();
        let want = frags["sites"].as_array().expect("sites").clone();
        assert_eq!(jobs.len(), want.len(), "每一条片段都必须进 jobs：{jobs:?}");
        for (job, w) in jobs.iter().zip(want.iter()) {
            let api = w["api"].as_str().unwrap_or("");
            let ext_text = w["extText"].as_str().unwrap_or("");
            if matches!(w["extRaw"], serde_json::Value::String(_)) {
                assert_eq!(
                    job.ext, ext_text,
                    "★★ {api} 的 ext 是字符串形态 ⇒ 必须**逐字**透传"
                );
            }
            let back = parse_loose_json(&job.ext)
                .unwrap_or_else(|e| panic!("★★ {api} 的 ext 不是合法 JSON（{e}）：{:?}", job.ext));
            let want_v = parse_loose_json(ext_text)
                .unwrap_or_else(|e| panic!("片段仓里 {api} 的 extText 不合法：{e}"));
            assert_eq!(
                back, want_v,
                "★★ {api} 的 ext 过了导入链路后**值必须一模一样**（丢键/改值/截断都算坏）"
            );
            for k in required_keys(api) {
                assert!(
                    back.get(*k).is_some(),
                    "★★ {api} 的 ext 缺必需键 `{k}`：{:?}",
                    job.ext
                );
            }
        }
    }

    // ── 门禁 ②：导入时**探测失败**也不许把带 ext 的 csp 源丢掉 ───────────
    //
    // # 为什么必须是"真导入一次"而不是只测纯函数
    // 丢 ext 的那一跳在 `import_tvbox_config` 的探测结果分支里
    // （旧行为：`Some(Err(reason)) => { skipped.push(..); continue; }`）。
    // 只断言 `keep_ext_on_probe_failure` 返回 true 是**测自己写的 true**：
    // 把调用点删掉，它照样绿。所以这里走真导入，再从**清单文件**读回来。
    //
    // # 探测失败怎么做到**确定性**（不吃网络）
    // 片段仓里 Wogg 的镜像四个域名是活的，真打过去反而可能成功（那就测不到
    // "探测失败"这一支）。所以把 `site` 指向本机闭合端口 —— 连接立刻被拒，
    // 与"站点临时挂了"是**同一条代码路径**，且不看外网脸色。
    //
    // # 阴性对照（同一份配置里）
    // 一条**苹果CMS** 站也指向闭合端口 ⇒ 探测失败 ⇒ 必须**不落盘**。
    // 没有这条对照，把 `keep_ext_on_probe_failure` 改成恒 true 也会绿。
    #[tokio::test]
    async fn probe_failure_still_persists_ext_csp_source() {
        let dir = tmp("probe-fail");
        let dead = "http://127.0.0.1:1";
        let wogg_ext = format!(r#"{{"site":["{dead}"]}}"#);
        let cfg = serde_json::json!({
            "sites": [
                { "key": "Wogg", "name": "玩耦丨4K臻享", "type": 3, "api": "csp_Wogg",
                  "ext": parse_loose_json(&wogg_ext).expect("ext 是 JSON") },
                // 阴性对照：苹果CMS + 死接口
                { "key": "dead", "name": "死接口站", "type": 1,
                  "api": "http://127.0.0.1:1/api.php/provide/vod" }
            ]
        })
        .to_string();

        let st = crate::state::AppState::bootstrap(dir.clone()).await.expect("bootstrap");
        let rep = import_tvbox_config(&st, &cfg).await.expect("导入应返回报告");
        drop(st);

        // ① 报告：这条源**被保留**，且如实标了"探测没通"
        let imported = rep["imported"].as_array().cloned().unwrap_or_default();
        let row = imported
            .iter()
            .find(|r| r["api"] == "csp_Wogg")
            .unwrap_or_else(|| panic!("★★ 带 ext 的 csp 源不许因探测失败而消失：{rep}"));
        assert_eq!(row["persisted"], serde_json::json!(true), "必须真落盘：{rep}");
        assert!(
            row["probeFailed"].is_string(),
            "★★ 必须如实标出「探测没通」（不许伪装成探测成功）：{rep}"
        );

        // ② 清单文件本体：ext 逐字在、可解析、键齐
        let saved = crate::persist::load_persisted(&dir);
        let ext = saved
            .iter()
            .find_map(|p| match p {
                crate::model::PersistedProvider::Tvbox { api, ext, .. } if api == "csp_Wogg" => {
                    Some(ext.clone().unwrap_or_default())
                }
                _ => None,
            })
            .unwrap_or_else(|| panic!("★★ 清单里必须有这条 csp 源：{saved:?}"));
        let back = parse_loose_json(&ext)
            .unwrap_or_else(|e| panic!("★★ 落盘的 ext 必须可解析（{e}）：{ext:?}"));
        assert!(
            back.get("site").is_some(),
            "★★ 落盘的 ext 必须带 `site` 键：{ext:?}"
        );

        // ③ 阴性对照：苹果CMS 死接口**不许**落盘（否则等于把所有死源都摆给用户）
        assert!(
            !saved.iter().any(|p| matches!(p,
                crate::model::PersistedProvider::Tvbox { api, .. } if api.contains("127.0.0.1:1"))),
            "★ 苹果CMS 探测失败仍必须丢弃：{saved:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 假订阅源站（本地 HTTP，吐一段配置文本）→ 返回订阅地址
    fn fake_sub_url(body: String) -> String {
        use std::io::{BufRead, BufReader, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定假源站失败");
        let port = listener.local_addr().expect("取端口失败").port();
        std::thread::spawn(move || {
            for conn in listener.incoming() {
                let Ok(mut stream) = conn else { break };
                let mut reader = BufReader::new(stream.try_clone().expect("clone"));
                let mut line = String::new();
                let _ = reader.read_line(&mut line);
                loop {
                    let mut h = String::new();
                    match reader.read_line(&mut h) {
                        Ok(0) => break,
                        Ok(_) if h == "\r\n" || h == "\n" => break,
                        Ok(_) => {}
                        Err(_) => break,
                    }
                }
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.flush();
            }
        });
        format!("http://127.0.0.1:{port}/tvbox.json")
    }

    // ── 门禁 ③：「检测更新」那条路也必须保住 ext（同一条丢失路径的副本）──────
    //
    // # 为什么单独一条
    // `update_tvbox_source` 有**自己的一份**探测结果分支（不是 import 那个循环）。
    // 只修 import ⇒ 用户点一次「检测更新」，带 ext 的 csp 源又被丢一次，
    // 而且这次连 ext 都不会出现在任何报告里（只进 `failed`）。
    #[tokio::test]
    async fn update_path_also_keeps_ext_on_probe_failure() {
        let dir = tmp("update-ext-keep");
        let dead = "http://127.0.0.1:1";
        let cfg_body = format!(
            r#"{{"sites":[{{"key":"wogg","name":"玩耦丨4K臻享","type":3,"api":"csp_Wogg","ext":{{"site":["{dead}"]}}}}]}}"#
        );
        let sub_url = fake_sub_url(cfg_body);

        // 本地已有"同订阅"里的一条源：update 要求这个 id 存在且带 srcUrl
        crate::persist::save_persisted(
            &dir,
            &[crate::model::PersistedProvider::Tvbox {
                id: "tvbox0".to_string(),
                name: "老源".to_string(),
                api: "http://127.0.0.1:1/api.php/provide/vod".to_string(),
                categories: Vec::new(),
                parsers: Vec::new(),
                ext: None,
            }],
        )
        .expect("写清单");
        write_tvbox_meta(
            &dir,
            "tvbox0",
            &TvboxSourceMeta {
                source_url: Some(sub_url.clone()),
                site_key: "old".to_string(),
                site_name: "老源".to_string(),
                api: "http://127.0.0.1:1/api.php/provide/vod".to_string(),
                installed_at: now_secs(),
                ..Default::default()
            },
        )
        .expect("写 meta");

        let st = crate::state::AppState::bootstrap(dir.clone()).await.expect("bootstrap");
        // apply_new=true ⇒ 远端这条"新增的 csp 源"要真的加进来
        let upd = update_tvbox_source(&st, "tvbox0", true, false)
            .await
            .expect("更新不该失败");
        drop(st);
        eprintln!("[EVIDENCE] update-keep-ext {upd}");

        let added = upd["added"].as_array().cloned().unwrap_or_default();
        let row = added
            .iter()
            .find(|r| r["api"] == "csp_Wogg")
            .unwrap_or_else(|| panic!("★★ 更新路径也不许丢带 ext 的 csp 源：{upd}"));
        assert_eq!(row["persisted"], serde_json::json!(true), "{upd}");
        assert!(row["probeFailed"].is_string(), "必须如实标探测没通：{upd}");

        let saved = crate::persist::load_persisted(&dir);
        let ext = saved
            .iter()
            .find_map(|p| match p {
                crate::model::PersistedProvider::Tvbox { api, ext, .. } if api == "csp_Wogg" => {
                    Some(ext.clone().unwrap_or_default())
                }
                _ => None,
            })
            .unwrap_or_else(|| panic!("★★ 更新后清单里必须有这条源：{saved:?}"));
        assert!(
            parse_loose_json(&ext).map(|v| v.get("site").is_some()).unwrap_or(false),
            "★★ 更新后落盘的 ext 必须仍带 `site`：{ext:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ═════════════════════════════════════════════════════════════════
    //  血缘修复批次（2026-11-01）：base64** 解包 + 验证型认领
    // ═════════════════════════════════════════════════════════════════
    //
    // 考证结论（决策笔记）：真机 64 条子站是"解码后的文本"灌进导入产生的
    // （链接路径当时解不了 base64** 包裹）⇒ source_url=None ⇒ 从不更新。
    // 本批两件事：① 链接路径学会剥 base64**；② 存量无主子站验证型认领。
    mod lineage_adopt {
        use super::*;
        use crate::state::AppState;

        fn b64(s: &str) -> String {
            crate::csp::shared::b64_encode(s.as_bytes())
        }
        fn wrap(t: &str) -> String {
            format!("YmFzZTY0**{}", b64(t))
        }

        /// ★ G1：真链接实抓形态（`\n` + `YmFzZTY0**` + base64(JSON)）解得开；
        ///       字面标记 `base64**` 同样认。
        ///
        /// 证红：把 unwrap_tvbox_config_text 改成恒等函数 ⇒ 本条红（解出来还是乱码）。
        #[test]
        fn unwrap_strips_base64_marker_real_shape() {
            let cfg = r#"{"spider":"http://x/jar;md5;abc","sites":[{"key":"k","name":"站","type":3,"api":"csp_X"}]}"#;
            let out = super::unwrap_tvbox_config_text(&wrap(cfg))
                .expect("★ 真形态必须解得开（这就是 Owner 那条链接的形状）");
            let v = parse_loose_json(&out).expect("解包后必须是合法 JSON");
            assert_eq!(v["sites"][0]["key"], "k", "{v}");
            // 带前导换行 + 字面 `base64**` 标记的变体也要认
            let out2 = super::unwrap_tvbox_config_text(&format!("\nbase64**{}", b64(cfg)))
                .expect("字面标记也要认");
            assert_eq!(
                parse_loose_json(&out2).unwrap()["sites"][0]["api"],
                "csp_X",
                "{out2}"
            );
        }

        /// ★ G2：嵌套语义 —— 2 层在限内解得开；4 层报清晰错误，不许糊死/死循环。
        #[test]
        fn unwrap_two_layers_ok_but_four_rejected() {
            let cfg = r#"{"sites":[]}"#;
            let two = super::unwrap_tvbox_config_text(&wrap(&wrap(cfg)))
                .expect("2 层在 3 层限内，必须解得开");
            assert!(
                parse_loose_json(&two).is_ok(),
                "解到底应该是明文 JSON：{two}"
            );
            let four = wrap(&wrap(&wrap(&wrap(cfg))));
            let err = super::unwrap_tvbox_config_text(&four)
                .expect_err("★ 4 层超过上限，必须报错");
            assert!(err.contains("3 层"), "错误里要说明上限：{err}");
        }

        /// ★ G3：普通配置原样放行（解包只认明确标记，绝不猜）；坏 base64 报清晰错误。
        #[test]
        fn unwrap_passes_plain_config_through_and_bad_b64_errors() {
            // 普通 JSON / 前导空白 —— 原样放行
            let out = super::unwrap_tvbox_config_text("\n {\"sites\":[]} ")
                .expect("普通配置不该报错");
            assert!(parse_loose_json(&out).is_ok(), "{out}");
            // JSONP / 注释等宽松形态也不许被误伤（仍是 parse_loose_json 的职责）
            let out2 = super::unwrap_tvbox_config_text("foo({\"a\":1});").expect("JSONP 原样放行");
            assert_eq!(out2, "foo({\"a\":1});");
            let err = super::unwrap_tvbox_config_text("YmFzZTY0**!!!not-base64!!!")
                .expect_err("坏 base64 必须报错");
            assert!(err.contains("解码失败"), "{err}");
        }

        /// 血缘认领用的三条真形状夹具：k1/k3 属于远端配置（CFG_V2），kx 是
        /// 别的来源的无主子站（远端没有它 —— 验证"未命中的如实带出"）。
        /// 返回 (id, name, api) 供 provider 注册复用（api 必须与远端一致，
        /// 这样 update 的 diff 是干净的 unchanged ⇒ 只走盖章，不掺探测变量）。
        fn adopt_fixture(dir: &std::path::Path, sink_url: &str) -> Vec<(String, String, String)> {
            let mk = |key: &str, name: &str, api: &str| TvboxSourceMeta {
                source_url: None,
                site_key: key.to_string(),
                site_name: name.to_string(),
                api: api.to_string(),
                // 真机那批的同一个时刻（real_shape_entry 同款）
                installed_at: 1_793_268_523,
                last_update_at: 0,
                last_update_ok: false,
                last_update_error: None,
            };
            let rows = [
                (
                    "csp-fixture-k1",
                    mk("k1", "甲站", &format!("{sink_url}/api.php/provide/vod")),
                ),
                ("csp-fixture-k3", mk("k3", "丙站", &format!("{sink_url}/api3/vod"))),
                // 远端配置里没有的站：认领必须**不碰**它并如实上报
                ("csp-fixture-kx", mk("kx", "外来站", "csp_Outsider")),
            ];
            for (id, meta) in rows.iter() {
                write_tvbox_meta(dir, id, meta).expect("写认领夹具失败");
            }
            // 夹具自证：磁盘上不许有 source_url 键（真形状）
            let raw = std::fs::read_to_string(tvbox_meta_file(dir)).expect("读夹具失败");
            assert!(!raw.contains("source_url"), "夹具必须是真形状（无链接）");
            rows.iter()
                .map(|(id, m)| (id.to_string(), m.site_name.clone(), m.api.clone()))
                .collect()
        }

        /// ★ G4（本批核心）：认领 → 订阅更新 → **既有子站全部盖章** → 聚合 max。
        ///
        /// 全链路：sink 吐的是 **base64** 包裹**的配置（真链接形态）⇒ 解包
        /// 必须先成立。认领只动 source_url=None 的条目；更新后 in_link 的全部
        /// 盖章；聚合时间 = 子站 max。
        ///
        /// 证红：把认领的配对判据去掉（claimed 恒空）⇒ 本条红在 claimed==0；
        ///      把 stamp_link_update 改成只盖 added/changed ⇒ 红在"k3 没盖章"。
        #[tokio::test]
        async fn adopt_then_update_stamps_all_orphans() {
            std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
            let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
            let dir = super::task5_ab_restart::unique_tmp_dir("adopt-e2e");
            std::fs::create_dir_all(&dir).expect("建临时目录失败");
            let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

            let rows = adopt_fixture(&dir, &sink.url());
            let (id1, id3, idx) = (
                rows[0].0.clone(),
                rows[1].0.clone(),
                rows[2].0.clone(),
            );
            // 三条都注册成 provider（真机上它们都是注册过的源）；
            // api/name 与 sidecar 同源 ⇒ update 的 diff 是干净的 unchanged
            {
                let mut list = st.third_party.write().expect("锁中毒");
                for (id, name, api) in rows.iter() {
                    list.push(crate::model::PersistedProvider::Tvbox {
                        id: id.clone(),
                        name: name.clone(),
                        api: api.clone(),
                        categories: Vec::new(),
                        parsers: Vec::new(),
                        ext: None,
                    });
                }
            }
            crate::commands_provider::persist_from_registry(&st).expect("落盘失败");

            // ★ 修好的链接路径：sink 吐 base64** 包裹配置，fetch_config_text 自动解包
            let sub_url = format!("{}/cfg/v2b64.json", sink.url());
            let res = super::adopt_tvbox_orphans(&st, &sub_url)
                .await
                .expect("★ 认领不该失败");
            println!("[EVIDENCE] adopt res={res}");
            assert_eq!(res["claimed"], 2, "★ k1/k3 配得上 ⇒ 认领 2 条：{res}");
            assert_eq!(res["unmatched"], 1, "★ kx 远端没有 ⇒ 如实带出：{res}");
            assert_eq!(res["orphans"], 3, "{res}");
            assert_eq!(res["sourceUrl"], sub_url.as_str(), "{res}");

            // 认领只补血缘：installed_at / site_key 原样保留
            let metas = load_tvbox_metas(&dir);
            assert_eq!(
                metas[&id1].source_url.as_deref(),
                Some(sub_url.as_str()),
                "k1 必须带上链接"
            );
            assert_eq!(
                metas[&id1].installed_at, 1_793_268_523,
                "★ 认领不许改 installed_at（安装时刻是历史事实）"
            );
            assert_eq!(metas[&id1].site_key, "k1", "site_key 原样保留");
            assert!(
                metas[&idx].source_url.is_none(),
                "★ 外来站远端没有 ⇒ 不许被误认领：{:?}",
                metas[&idx]
            );

            // 重复调用：剩余的 kx 真的与该链接配不上 ⇒ 如实 Err（"一条都配不上
            // 才 Err"），且**盘上什么都不写** —— 这就是"不产生双份"的结构保证。
            // （64 条全配得上的真机场景里，二次调用 orphans=0 ⇒ Ok{claimed:0}。）
            let again = super::adopt_tvbox_orphans(&st, &sub_url)
                .await
                .expect_err("★ 剩一条配不上 ⇒ 如实 Err");
            assert!(again.contains("配不上"), "{again}");
            let metas = load_tvbox_metas(&dir);
            assert_eq!(
                metas[&id1].source_url.as_deref(),
                Some(sub_url.as_str()),
                "Err 路径不许动已认领的条目"
            );
            assert_eq!(metas[&idx].source_url, None, "Err 路径不许盲写");

            // ── 一次订阅更新（走生产命令，代表源任选已认领的一条）─────────
            let upd = super::update_tvbox_source(&st, &id1, true, false)
                .await
                .expect("更新不该失败");
            println!("[EVIDENCE] adopt-e2e upd={upd}");

            // ★ 核心判据：已认领的既有子站**全部**盖章；外来站仍是从未更新
            let metas = load_tvbox_metas(&dir);
            for id in [&id1, &id3] {
                assert!(
                    metas[id].last_update_at > 0 && metas[id].last_update_ok,
                    "★ {id} 必须盖上成功章（这是本批要闭环的读数）"
                );
            }
            assert_eq!(
                metas[&idx].last_update_at, 0,
                "外来站不属于这条链接 ⇒ 不许盖错章"
            );

            // 聚合时间 = 子站 max ⇒ 设置页聚合卡从此显示真实「上次更新」
            let ids = vec![id1.clone(), id3.clone(), idx.clone()];
            let (at, ok, err) = super::tvbox_aggregate_last_update(&metas, &ids)
                .expect("★ 有子站盖过章 ⇒ 聚合必须拿到时间");
            assert_eq!(at, metas[&id1].last_update_at.max(metas[&id3].last_update_at), "{at}");
            assert!(ok && err.is_none(), "全部成功 ⇒ ok=true：{ok} {err:?}");

            let _ = std::fs::remove_dir_all(&dir);
        }

        /// ★ G5：认领的诚实性/边界 —— 一条都配不上 ⇒ Err 且不写盘；
        ///       url 空/非 http ⇒ Err（FFI 不留洞）。
        ///
        /// 证红：把"claimed 为空 ⇒ Err"的守卫删掉 ⇒ 本条红（应该 Err 却 Ok 了）。
        #[tokio::test]
        async fn adopt_rejects_no_pair_and_bad_url() {
            std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
            let sink = super::task5_ab_restart::start_sink(super::task5_ab_restart::SHARE_PLAIN);
            let dir = super::task5_ab_restart::unique_tmp_dir("adopt-reject");
            std::fs::create_dir_all(&dir).expect("建临时目录失败");
            let st = AppState::bootstrap(dir.clone()).await.expect("bootstrap 失败");

            // 一条无主子站，key/api 都与远端（k1/k3）对不上
            write_tvbox_meta(
                &dir,
                "csp-fixture-kz",
                &TvboxSourceMeta {
                    source_url: None,
                    site_key: "kz".to_string(),
                    site_name: "对不上".to_string(),
                    api: "csp_Nobody".to_string(),
                    installed_at: 1_793_268_523,
                    ..Default::default()
                },
            )
            .expect("写夹具失败");
            {
                let mut list = st.third_party.write().expect("锁中毒");
                list.push(crate::model::PersistedProvider::Tvbox {
                    id: "csp-fixture-kz".to_string(),
                    name: "对不上".to_string(),
                    api: "csp_Nobody".to_string(),
                    categories: Vec::new(),
                    parsers: Vec::new(),
                    ext: None,
                });
            }
            crate::commands_provider::persist_from_registry(&st).expect("落盘失败");

            let sub_url = format!("{}/cfg/v2b64.json", sink.url());
            let err = super::adopt_tvbox_orphans(&st, &sub_url)
                .await
                .expect_err("★ 一条都配不上必须 Err（不许静默成功）");
            println!("[EVIDENCE] adopt-reject err={err}");
            assert!(err.contains("配不上"), "{err}");
            // 拒绝认领 ⇒ 盘上什么都没写（source_url 仍是 None）
            let metas = load_tvbox_metas(&dir);
            assert!(
                metas["csp-fixture-kz"].source_url.is_none(),
                "Err 路径不许有半截写入"
            );

            // args 校验：空 / 非 http 一律 Err（不给 FFI 留"空参盲写"的洞）
            assert!(super::adopt_tvbox_orphans(&st, "").await.is_err(), "空 url 必须 Err");
            assert!(
                super::adopt_tvbox_orphans(&st, "not-a-url").await.is_err(),
                "非 http url 必须 Err"
            );

            let _ = std::fs::remove_dir_all(&dir);
        }

        /// ★ G6：修好的**链接导入**路径 —— base64** 包裹的配置能导入，
        ///       且 source_url 落盘 + 盖 installed 初始章（B3 口径）。
        ///
        /// 这就是"上一批智能体被迫走文本粘贴"的那条路 —— 修完它，下次
        /// 正规导入不会再产生 source_url=None 的孤儿。
        ///
        /// 证红：把 fetch_config_text 里的 unwrap 拿掉 ⇒ 本条红（导入报
        ///      "配置不是合法 JSON"）。
        #[tokio::test]
        async fn import_via_link_unwraps_base64_and_records_source_url() {
            std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
            let dir = tmp("adopt-import");
            // csp+ext ⇒ 探测失败照样落盘（127.0.0.1:1 闭合端口，离线确定性）
            let dead = "http://127.0.0.1:1";
            let cfg_body = format!(
                r#"{{"sites":[{{"key":"wogg","name":"玩耦丨4K臻享","type":3,"api":"csp_Wogg","ext":{{"site":["{dead}"]}}}}]}}"#
            );
            let sub_url = fake_sub_url(wrap(&cfg_body));

            let st = crate::state::AppState::bootstrap(dir.clone()).await.expect("bootstrap");
            let res = super::import_tvbox_config(&st, &sub_url)
                .await
                .expect("★ 链接导入必须成功（这是本批修的主路径）");
            println!("[EVIDENCE] import-b64 res={res}");
            assert_eq!(
                res["imported"].as_array().map(|a| a.len()),
                Some(1),
                "csp+ext 探测失败也要保留：{res}"
            );

            let metas = load_tvbox_metas(&dir);
            let m = metas
                .values()
                .next()
                .unwrap_or_else(|| panic!("★ sidecar 必须有这条源：{metas:?}"));
            assert_eq!(
                m.source_url.as_deref(),
                Some(sub_url.as_str()),
                "★ 血缘必须落盘（这次的导入走的是链接，不许再丢）：{m:?}"
            );
            assert!(
                m.last_update_at > 0 && m.last_update_ok,
                "★ 链接导入成功 ⇒ 盖 installed 初始章（B3 口径）：{m:?}"
            );

            let _ = std::fs::remove_dir_all(&dir);
        }
    }
}
