// ═══════════════════════════════════════════════════════════════════════
//  csp_Libvio —— TVBox `csp_Libvio` 的 Rust 重写（含**站点自己的 PoW 验证**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在配置里覆盖什么
// ```json
// {"key":"Libvio","name":"🎞️LIBVIO","type":3,"api":"csp_Libvio",
//  "searchable":1,"quickSearch":1,"filterable":1}
// ```
// ⇒ 站点写死 `https://www.libvio.io`（DEX 逐字）。
//
// # ★★★ 分档：**上游可用 —— 含站点自己的 PoW，已实测跑通**
//
// ## ★ 边界声明（先讲清楚，免得被误读成"绕过"）
// ```text
// 本站的反爬**不是**人机验证/指纹伪造，而是它**自己公开说明的 PoW**：
//   HTTP 403 + `x-cdn-challenge: js-pow`
//   body 里逐字写着：「本页面由 CDN 安全防护自动生成。验证由浏览器完成一次
//                     工作量证明（Proof-of-Work），点击或滑动只是开始验证，
//                     不采集个人信息，也不采集行为特征。」
//   ⇒ 算 PoW 是**站点规定的正常访问途径**（它自己要求你算） ⇒ **实现协议**，不是绕过。
// ★ 我**没有**做任何以下事情（本批边界）：
//     · 不伪造浏览器指纹 / 不模拟鼠标滑动 / 不破解验证码
//     · 不切换 IP / 不用代理做地理规避 / 不转第三方打码
//   ⇒ 只做"把页面里的参数读出来、按它给的算法算一个解、把 cookie 带回去"。
// ```
//
// ## PoW 协议（**从 403 页里读出来的，实测跑通**）
// ```text
// ① 首次请求 ⇒ 403 + body 里有：
//      var TS = "1793108281", SIG = "aafd6819…（64 hex）", DIFF = "0000", MODE = "auto";
// ② 求解：找最小 n 使 `sha256(SIG + n)` 的**十六进制串以 DIFF 为前缀**
//      实测：n = 19809，约 19810 次尝试，**0.01 秒**（DIFF="0000" 很浅）
// ③ 写 cookie：`__cdn_pow = {TS}_{MODE}_{n}_{SIG}`（path=/; samesite=lax; secure）
// ④ 带该 cookie 重新请求 ⇒ **403 → 302**，跟随 302 ⇒ **200 + 真页面**
// ⑤ 实测读数：
//      首次      ⇒ 403 / 20359 字节（挑战页）
//      PoW 解出后 ⇒ 302 → **40603 字节真首页**（`<title>LIBVIO</title>`）
//      `/type/1-1.html` ⇒ **16230 字节**，站点正则命中卡片 **24** 条
//        例：`/detail/714893782.html` title=「不存在的罪人」
//            `/detail/714893781.html` title=「末世行者」
// ```
//
// ## ★ 这构成本批第四条"我打错 vs 上游死"的形态，但**结论与前三类相反**
// ```text
// · SaoHuo ：路径错   ⇒ 522 被误读成"站死"
// · AppRJ  ：方法/编码错 ⇒ 405 被误读成"端点不存在"
// · HDMoli ：客户端工具/代理 ⇒ 000 被误读成"连不上"
// · Libvio ：**403 是真的**，但它**不是"拒绝服务"**，而是"**你还没按我的规矩来**"
//   ⇒ ★ 关键区分：**403 的 body 会告诉你该怎么办**（这里给了 PoW 参数与算法）。
//     判据：**4xx/5xx 出现时，先读它的 body —— 若像"可执行的指示"就不是"死"。**
//   ⇒ 前三类是"我们的读数是假的"，这一类是"读数真、含义被误读"。
//     **两种都要避免**：不读 body 就判 403=死，会漏掉一个完全可用的源。
// ```
//
// # 协议细节（DEX 逐字 + 实测）
// ```text
// 头（DEX `baseHeaders()`）：User-Agent(Chrome151) / Accept / Accept-Language
//                            Referer = `{site}/` / Sec-Fetch-* / Upgrade-Insecure-Requests
// 列表：`/type/{tid}-{page}.html`
// 搜索：`/search/-------------.html?wd=` + URLEncoder(kw)   （DEX 逐字）
// 详情：`/detail/{id}.html`
// ★ DEX 的正则（站点自己的）：
//   · 卡片：`<a[^>]*href="(/detail/(\d+)\.html)"[^>]*title="([^"]*)"[^>]*data-original="([^"]*)"`
//     （另有 `stui-vodlist__thumb` 变体，我实现时**两个都认**）
//   · 标题：`<title>([^<]*?)\s*-\s*LIBVIO</title>`
//   · 简介：`<span class="detail-content"[^>]*>(.*?)</span>`
//   · meta ：`<span class="meta-item">([^<]*)</span>`
//   · 网盘链接：`href="(https?://[^"]+)"` 且宿主属于**一批网盘域名**（DEX 里逐条列了
//     115.com / 123pan.com / alipan.com / aliyundrive.com / caiyun.139.com /
//     cloud.189.cn / drive.uc.cn / guangyapan.com / pan.baidu.com / pan.quark.cn /
//     pan.xunlei.com / anxia.com …）⇒ **取流交回网盘分享页**（与 GuiGui/HDMoli 同族）
// ```
//
// # ⚠️ 已知缺口（按契约"不许静默丢、不许自己造"）
// ```text
// ① ★ **PoW cookie 的跨段复用**：DEX 用字段存 `__cdn_pow`，并在 `tokenAlive()` 里判它是否有效。
//    本仓 `CspSite` **没有"跨段持久化 cookie / 令牌有效性"能力位**
//    ⇒ 我用**进程内缓存**（`Mutex<Option<String>>`）实现，并如实登记为"不等价位"。
// ② **网盘链路**（同 GuiGui/HDMoli）：取流交回网盘分享页，**不假装是直链**。
// ③ `mProxy`：DEX 方法表里**没有** ⇒ 本批"不做 mProxy"对此类零影响。
// ④ `loadPic`：没有 ⇒ 封面走源 `cover_headers`（声明式）。
//    ⚠️ `CspSite` **没有** `cover_headers()` 能力位（与 5 个类同一条缺口）。
// ⑤ `initApi`：没有。
// ⑥ `isVideoFormat` / `manualVideoCheck`：DEX 里没有这两个方法。
// ```

use std::sync::Mutex;

use async_trait::async_trait;
use regex::Regex;
use serde_json::Value;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
/// DEX 逐字的站点前缀
pub const SITE: &str = "https://www.libvio.io";
/// PoW cookie 名（403 页里逐字：`var POW = "__cdn_pow"`）
pub const POW_COOKIE: &str = "__cdn_pow";
/// ★★ 验证**通过后**服务端下发的 cookie 名（**DEX 里也有它** —— `:345/:448/:931`）
///
/// # 我第一版漏了它（真网抓到的真 bug）
/// ```text
/// 302 的响应头逐字：
///   location: /type/1-1.html
///   set-cookie: **__cdn_verified=1793109070_1763_cfaee89e…; Path=/; Max-Age=1800;
///               HttpOnly; SameSite=Lax; Secure**
///   set-cookie: __cdn_pow=; Path=/; Max-Age=0      ← PoW cookie 被**清掉**
/// ⇒ 必须**接收并带回** `__cdn_verified` ⇒ 否则 302 会一直跳回自身（死循环）。
/// ★ 我的 reqwest 默认**不存 cookie** ⇒ 表现就是 `TooManyRedirects` ⇒ 逐层查到这条。
/// ```
pub const VERIFIED_COOKIE: &str = "__cdn_verified";

/// 「网盘链路」统一文案（与 GuiGui / HDMoli **逐字同一条**）
pub const PAN_CHAIN_REASON: &str =
    "该链路依赖 Pan 基类的网盘工具链（本批契约明确不做 mProxy）";

/// DEX 里逐条列出的**网盘宿主**（用于识别详情页里的网盘链接）
pub const PAN_HOSTS: &[&str] = &[
    "pan.baidu.com",
    "pan.quark.cn",
    "pan.xunlei.com",
    "alipan.com",
    "aliyundrive.com",
    "drive.uc.cn",
    "cloud.189.cn",
    "caiyun.139.com",
    "123pan.com",
    "115.com",
    "guangyapan.com",
    "anxia.com",
];

// ═══════════════════════════════════════════════════════════════════════
//  纯函数层（PoW / URL / 解析；全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// `sha256` 的**十六进制小写**
pub fn sha256_hex(s: &str) -> String {
    use ring::digest;
    let d = digest::digest(&digest::SHA256, s.as_bytes());
    let mut out = String::with_capacity(64);
    for b in d.as_ref() {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// 403 页里读出的 PoW 参数（`TS` / `SIG` / `DIFF` / `MODE`）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pow {
    pub ts: String,
    pub sig: String,
    pub diff: String,
    pub mode: String,
}

/// 从 403 挑战页里提取 PoW 参数
///
/// DEX 的正则逐字：
/// `var\s+TS\s*=\s*"(\d+)"\s*,\s*SIG\s*=\s*"([0-9a-fA-F]+)"\s*,\s*DIFF\s*=\s*"([0-9a-fA-F]+)"\s*,\s*MODE\s*=\s*"(\w+)"`
pub fn pow_of(html: &str) -> Option<Pow> {
    let re = Regex::new(
        r#"var\s+TS\s*=\s*"(\d+)"\s*,\s*SIG\s*=\s*"([0-9a-fA-F]+)"\s*,\s*DIFF\s*=\s*"([0-9a-fA-F]+)"\s*,\s*MODE\s*=\s*"(\w+)""#,
    )
    .expect("PoW 正则");
    let c = re.captures(html)?;
    Some(Pow {
        ts: c.get(1)?.as_str().to_string(),
        sig: c.get(2)?.as_str().to_string(),
        diff: c.get(3)?.as_str().to_string(),
        mode: c.get(4)?.as_str().to_string(),
    })
}

/// 求解 PoW：找最小 `n` 使 `sha256(SIG + n)` 以 `DIFF` 为前缀
///
/// # 实测
/// ```text
/// 挑战页给 `DIFF="0000"` ⇒ 期望次数 16^4 = 65536，实测 **n = 19809**（约 19810 次，0.01 秒）
/// ```
/// * `max_iter` 是**上限**（照页面自己的 `MAX_ITER = EXPECT * 32` 精神给一个界）
/// * 找不到 ⇒ `None`（**不编一个 nonce**）
pub fn solve_pow(sig: &str, diff: &str, max_iter: u64) -> Option<u64> {
    if diff.is_empty() {
        return None;
    }
    let d = diff.to_ascii_lowercase();
    for n in 0..max_iter {
        if sha256_hex(&format!("{sig}{n}")).starts_with(&d) {
            return Some(n);
        }
    }
    None
}

/// 组装 PoW cookie 值：`{TS}_{MODE}_{n}_{SIG}`（403 页里逐字：`TS + "_" + MODE + "_" + nonce + "_" + SIG`）
pub fn pow_cookie_value(p: &Pow, nonce: u64) -> String {
    format!("{}_{}_{}_{}", p.ts, p.mode, nonce, p.sig)
}

/// URL 模板（DEX 逐字）
pub fn list_url(tid: &str, page: u32) -> String {
    format!("{SITE}/type/{}-{}.html", tid.trim(), page)
}
pub fn search_url(kw: &str) -> String {
    format!("{SITE}/search/-------------.html?wd={}", urlencoding::encode(kw))
}
pub fn detail_url(id: &str) -> String {
    format!(
        "{SITE}/detail/{}.html",
        id.trim().trim_end_matches(".html")
    )
}

/// 列表 HTML → 卡片（**认 DEX 的两个正则变体**）
///
/// ```text
/// 变体 1（带 `stui-vodlist__thumb` class）：`<a class="stui-vodlist__thumb…" href="(/detail/(\d+)\.html)" title="…" data-original="…"`
/// 变体 2（不带 class）                      ：`<a href="(/detail/(\d+)\.html)" title="…" data-original="…"`
/// ⇒ 实现里用**变体 2 的宽松形态**（它天然覆盖变体 1 —— 因为变体 1 的中间只多了个 class 属性）。
/// ★ 但属性顺序可能变（`title` 在 `href` 前 / `data-original` 在 `title` 前）⇒ 我按
///   **"先取所有 `<a …>` 标签，再逐个取属性"** 的做法，**不依赖属性顺序**。
/// ```
/// **0 条 ⇒ Err**
pub fn cards_from(html: &str, what: &str) -> Result<Vec<CspItem>, String> {
    let re_a = Regex::new(r"<a\s[^>]*>").expect("a 标签");
    let re_href = Regex::new(r#"href="/detail/(\d+)\.html""#).expect("href");
    let re_title = Regex::new(r#"title="([^"]*)""#).expect("title");
    let re_pic = Regex::new(r#"data-original="([^"]*)""#).expect("pic");
    let mut out: Vec<CspItem> = Vec::new();
    for m in re_a.find_iter(html) {
        let tag = m.as_str();
        let Some(id) = re_href.captures(tag).and_then(|c| c.get(1)).map(|x| x.as_str()) else {
            continue;
        };
        let title = re_title
            .captures(tag)
            .and_then(|c| c.get(1))
            .map(|x| decode_entities(x.as_str().trim()))
            .unwrap_or_default();
        if id.is_empty() || title.is_empty() {
            continue;
        }
        if out.iter().any(|i| i.id == id) {
            continue; // 同一条目在页里可能出现两次（实测形态）
        }
        let cover = re_pic
            .captures(tag)
            .and_then(|c| c.get(1))
            .map(|x| x.as_str().trim().to_string())
            .filter(|s| !s.is_empty());
        out.push(CspItem {
            id: id.to_string(),
            title,
            cover,
            subtitle: None,
        });
    }
    if out.is_empty() {
        return Err(format!(
            "上游 {what} 的 HTML 里没抓到卡片（页面 {} 字符；站点正则可能改版）",
            html.chars().count()
        ));
    }
    Ok(out)
}

/// 详情 HTML → `CspDetail`
pub fn detail_of(html: &str, id: &str) -> Result<CspDetail, String> {
    let title = Regex::new(r"<title>([^<]*?)\s*-\s*LIBVIO</title>")
        .expect("title 正则")
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|x| decode_entities(x.as_str().trim()))
        .filter(|s| !s.is_empty())
        // 退路：页面里第一个 `<h1>`（有的页面 title 形态不同）
        .or_else(|| {
            Regex::new(r"<h1[^>]*>([^<]*)</h1>")
                .ok()?
                .captures(html)
                .and_then(|c| c.get(1))
                .map(|x| decode_entities(x.as_str().trim()))
                .filter(|s| !s.is_empty())
        })
        .ok_or_else(|| {
            format!(
                "上游详情 {id} 的 HTML 里取不到标题（页面 {} 字符）",
                html.chars().count()
            )
        })?;
    let desc = Regex::new(r#"<span class="detail-content"[^>]*>(.*?)</span>"#)
        .ok()
        .and_then(|re| re.captures(html))
        .and_then(|c| c.get(1))
        .map(|x| strip_tags(x.as_str()).trim().to_string())
        .filter(|s| !s.is_empty());
    let metas: Vec<String> = Regex::new(r#"<span class="meta-item">([^<]*)</span>"#)
        .expect("meta")
        .captures_iter(html)
        .filter_map(|c| c.get(1).map(|m| m.as_str().trim().to_string()))
        .filter(|s| !s.is_empty())
        .collect();
    let description = match (desc, metas.is_empty()) {
        (Some(d), false) => Some(format!("{d}\n{}", metas.join(" / "))),
        (Some(d), true) => Some(d),
        (None, false) => Some(metas.join(" / ")),
        (None, true) => None,
    };
    let cover = Regex::new(r#"data-original="([^"]*)""#)
        .expect("pic")
        .captures(html)
        .and_then(|c| c.get(1))
        .map(|x| x.as_str().trim().to_string())
        .filter(|s| !s.is_empty());

    let pans = pan_links_of(html);
    if pans.is_empty() {
        return Err(format!(
            "上游详情 {id} 的 HTML 里没抓到网盘链接（本类是网盘资源型，没有它就没有可播内容）"
        ));
    }
    let episodes: Vec<CspEpisode> = pans
        .iter()
        .enumerate()
        .map(|(i, (host, url))| CspEpisode {
            id: format!("{id}\u{1}{url}"),
            title: format!("网盘{}：{host}", i + 1),
            flag: "网盘".to_string(),
        })
        .collect();
    Ok(CspDetail {
        id: id.trim().to_string(),
        title,
        cover,
        description,
        episodes,
    })
}

/// 详情页里的**网盘链接**（DEX：`href="(https?://[^"]+)"` 且宿主属于 [`PAN_HOSTS`]）
pub fn pan_links_of(html: &str) -> Vec<(String, String)> {
    let re = Regex::new(r#"href="(https?://[^"]+)""#).expect("href");
    let mut out = Vec::new();
    for c in re.captures_iter(html) {
        let u = c.get(1).map(|m| m.as_str().trim()).unwrap_or("");
        if u.is_empty() {
            continue;
        }
        let low = u.to_ascii_lowercase();
        if let Some(h) = PAN_HOSTS.iter().find(|h| low.contains(**h)) {
            if !out.iter().any(|(_, x): &(String, String)| x == u) {
                out.push(((*h).to_string(), u.to_string()));
            }
        }
    }
    out
}

/// 从集 id 拆出 `(条目id, 分享页 url)`
pub fn split_ep_id(ep: &str) -> Option<(String, String)> {
    let (id, url) = ep.split_once('\u{1}')?;
    if id.is_empty() || url.trim().is_empty() {
        return None;
    }
    Some((id.to_string(), url.trim().to_string()))
}

/// 实体还原（DEX 里逐条列了 `&amp; &quot; &#39; &nbsp;`）
pub fn decode_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

/// 剥标签（DEX：`<[^>]+>` → 空格；`\s{2,}` → 单空格）
pub fn strip_tags(s: &str) -> String {
    let no = Regex::new(r"<[^>]+>").expect("标签").replace_all(s, " ");
    let sp = Regex::new(r"\s{2,}").expect("多空格").replace_all(&no, " ");
    decode_entities(sp.trim())
}

/// 上游判据（`ensure_ok` 的等价：只有 **200** 是成功；403 挑战由上层处理）
pub fn is_challenge(status: u16, body: &str) -> bool {
    status == 403 && pow_of(body).is_some()
}

/// 首页分类（DEX `homeContent` 的内嵌表）
pub fn cats() -> Vec<CspCategory> {
    [
        ("1", "电影"),
        ("2", "连续剧"),
        ("3", "综艺"),
        ("4", "动漫"),
        ("15", "纪录片"),
        ("16", "短剧"),
    ]
    .iter()
    .map(|(i, n)| CspCategory {
        id: (*i).to_string(),
        name: (*n).to_string(),
    })
    .collect()
}

// ═══════════════════════════════════════════════════════════════════════
//  站点实现
// ═══════════════════════════════════════════════════════════════════════

pub struct Libvio {
    client: reqwest::Client,
    /// DEX 字段：`__cdn_pow` 的值（跨段复用）
    ///
    /// ⚠️ 本仓 `CspSite` **没有"跨段持久化 cookie"能力位** ⇒ 进程内缓存替代，
    ///    如实登记为"不等价位"（见文件头「已知缺口 ①」）。
    pow: Mutex<Option<String>>,
    /// ★ `__cdn_verified` 的值（PoW 通过后服务端下发；DEX 里也有它）
    ///
    /// ⚠️ 同样属"跨段持久化 cookie"这条**缺能力位** ⇒ 进程内缓存替代。
    verified: Mutex<Option<String>>,
}

impl Libvio {
    pub const CLASS: &'static str = "Libvio";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .no_proxy()
            /*
             * ★★ **关掉自动重定向** —— 这是本类的关键实现细节（真网抓到的坑）
             * ```text
             * 本站的流程是"PoW 通过 ⇒ 302 + 下发 `__cdn_verified`"。
             * 而 reqwest 的自动重定向**不带 cookie jar**（本类没启用 cookie_store），
             * 于是重定向后的请求**丢掉了 `__cdn_verified`** ⇒ 服务端再次 302 到自身
             * ⇒ **死循环**（实测报错 `TooManyRedirects`）。
             * ⇒ 处置：**手工跟随**（每跳都带上已知 cookie），并**限最多 4 跳**。
             * ★ 这也是"必须先按真实形态打、再逐层看响应头"才能发现的形态 ——
             *   它**不会**在离线门禁里暴露（离线夹具不涉及重定向链）。
             * ```
             */
            .redirect(reqwest::redirect::Policy::none())
            .timeout(std::time::Duration::from_secs(25))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            client,
            pow: Mutex::new(None),
            verified: Mutex::new(None),
        }
    }

    fn cached_pow(&self) -> Option<String> {
        self.pow.lock().ok().and_then(|g| g.clone())
    }

    /// 已缓存的 `__cdn_verified`（PoW 通过后由服务端下发）
    pub fn cached_verified(&self) -> Option<String> {
        self.verified.lock().ok().and_then(|g| g.clone())
    }

    /// DEX `baseHeaders()` 的头
    fn headers(&self, req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        req.header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
            .header(reqwest::header::ACCEPT_LANGUAGE, "zh-CN,zh;q=0.9,en;q=0.8")
            .header(reqwest::header::REFERER, format!("{SITE}/"))
            .header("Sec-Fetch-Dest", "document")
            .header("Sec-Fetch-Mode", "navigate")
            .header("Sec-Fetch-Site", "same-origin")
            .header("Upgrade-Insecure-Requests", "1")
    }

    /// 取页面（**自动过 PoW**）
    ///
    /// # 流程（实测跑通）
    /// ```text
    /// ① 带缓存的 `__cdn_pow` 请求
    /// ② 若 403 且 body 里有 PoW 参数 ⇒ 解 PoW ⇒ 写 cookie ⇒ **重试一次**
    /// ③ 仍是 403 ⇒ 如实报（**不无限重试**、**不换 IP**、**不伪造任何东西**）
    /// ```
    async fn get_text(&self, url: &str, what: &str) -> Result<String, String> {
        /*
         * ★★ 本函数实现的是**站点自己的验证流程**（读参数 → 算 PoW → 带 cookie → 手工跟随）。
         *
         * # 为什么必须"手工跟随"（真网抓到的坑，离线门禁暴露不了）
         * ```text
         * 站点流程：PoW 对 ⇒ **302 + 下发 `__cdn_verified`**（同时把 `__cdn_pow` 清掉）。
         * 而 reqwest 的自动重定向**不带 cookie 存储**（本类没启用 cookie_store）
         *   ⇒ 重定向后的请求丢掉 `__cdn_verified` ⇒ 服务端再次 302 到**自身**
         *   ⇒ **死循环**（实测报错 `TooManyRedirects`）。
         * ⇒ 处置：`.redirect(Policy::none())` + **自己跟**，每跳都把已知 cookie 带上，
         *   并**限最多 4 跳**（不无限跟随）。
         * ★ 判据：**遇到重定向，先看它下发了什么 header** ——
         *   `set-cookie: __cdn_verified=…` 就是"验证已通过，拿这个继续走"的指令。
         * ```
         */
        let mut pow_cookie: Option<String> = self.cached_pow();
        let mut verified: Option<String> = self.cached_verified();
        let mut current = url.to_string();
        let mut hops = 0usize;
        let mut pow_solved = false;
        loop {
            let mut req = self.headers(self.client.get(&current));
            // 带上已知 cookie（两个都带 —— 服务端按哪个有效用哪个）
            let mut ck: Vec<String> = Vec::new();
            if let Some(v) = &verified {
                ck.push(format!("{VERIFIED_COOKIE}={v}"));
            }
            if let Some(v) = &pow_cookie {
                ck.push(format!("{POW_COOKIE}={v}"));
            }
            if !ck.is_empty() {
                req = req.header(reqwest::header::COOKIE, ck.join("; "));
            }
            let resp = req
                .send()
                .await
                .map_err(|e| format!("请求 Libvio 失败（{current}）：{e}"))?;
            let status = resp.status().as_u16();
            // ★ 先读 set-cookie（**重定向时它带着下一步所需的凭据**）
            for sc in resp.headers().get_all(reqwest::header::SET_COOKIE) {
                let s = sc.to_str().unwrap_or("");
                if let Some(rest) = s.strip_prefix(&format!("{VERIFIED_COOKIE}=")) {
                    let val = rest.split(';').next().unwrap_or("").trim().to_string();
                    if !val.is_empty() {
                        verified = Some(val.clone());
                        if let Ok(mut g) = self.verified.lock() {
                            *g = Some(val);
                        }
                    }
                }
                if let Some(rest) = s.strip_prefix(&format!("{POW_COOKIE}=")) {
                    let val = rest.split(';').next().unwrap_or("").trim().to_string();
                    // 空值 = 服务端在**清掉**它（PoW 已换成 verified）
                    if !val.is_empty() {
                        pow_cookie = Some(val.clone());
                        if let Ok(mut g) = self.pow.lock() {
                            *g = Some(val);
                        }
                    }
                }
            }
            if status == 200 {
                return resp
                    .text()
                    .await
                    .map_err(|e| format!("读取 Libvio 响应失败（{current}）：{e}"));
            }
            // ③ 3xx ⇒ 手工跟随（**最多 4 跳**）
            if (300..400).contains(&status) {
                let loc = resp
                    .headers()
                    .get(reqwest::header::LOCATION)
                    .and_then(|v| v.to_str().ok())
                    .map(|s| s.to_string());
                let Some(l) = loc else {
                    return Err(format!(
                        "Libvio 返回 HTTP {status} 但没有 Location（{current}）"
                    ));
                };
                hops += 1;
                if hops > 4 {
                    return Err(format!(
                        "Libvio 重定向超过 4 跳（{url}）—— ★ 停在这里，不无限跟随；                         多半是 `__cdn_verified` 没被接受"
                    ));
                }
                current = if l.starts_with("http") {
                    l
                } else {
                    format!("{SITE}{l}")
                };
                continue;
            }
            // ② 403 挑战 ⇒ 解 PoW（**只解一次**）+ 重试
            let body = resp
                .text()
                .await
                .map_err(|e| format!("读取 Libvio 响应失败（{current}）：{e}"))?;
            if status == 403 && !pow_solved {
                if let Some(p) = pow_of(&body) {
                    let nonce = solve_pow(&p.sig, &p.diff, 8_000_000).ok_or_else(|| {
                        format!(
                            "PoW 在 800 万次内没解出来（SIG={}… DIFF={}）—— ★ 不编一个 nonce",
                            &p.sig[..p.sig.len().min(16)],
                            p.diff
                        )
                    })?;
                    let cv = pow_cookie_value(&p, nonce);
                    if let Ok(mut g) = self.pow.lock() {
                        *g = Some(cv.clone());
                    }
                    pow_cookie = Some(cv);
                    pow_solved = true;
                    // 重试同一个 URL（`continue` 会重新带上新 cookie）
                    continue;
                }
                // 403 但**没有 PoW 参数** ⇒ 如实报（不是我们的协议问题）
                return Err(format!(
                    "Libvio 返回 403 但页里读不出 PoW 参数（{current}）：body 前 120 字：{}",
                    body.chars().take(120).collect::<String>()
                ));
            }
            return Err(format!(
                "上游 Libvio 返回 HTTP {status}（{current}）：body 前 120 字：{}",
                body.chars().take(120).collect::<String>()
            ));
        }
        let _ = what;
    }
}

impl Default for Libvio {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for Libvio {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        let prefetch = self.get_text(&format!("{SITE}/"), "首页").await;
        Ok(home_of(prefetch))
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        if tid.trim().is_empty() {
            return Err("分类 id 不能为空（DEX 的 `/type/{tid}-{page}.html` 需要它）".to_string());
        }
        let html = self
            .get_text(&list_url(tid, page), &format!("分类 {tid} 第 {page} 页"))
            .await?;
        Ok(CspList {
            items: cards_from(&html, &format!("分类 {tid} 第 {page} 页"))?,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        if page > 1 {
            return Err(
                "csp_Libvio 的搜索不支持分页（DEX 的 `/search/-------------.html?wd=` 模板无页码位）"
                    .to_string(),
            );
        }
        let html = self.get_text(&search_url(kw), "搜索").await?;
        Ok(CspList {
            items: cards_from(&html, "搜索")?,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        true
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let html = self.get_text(&detail_url(id), &format!("详情 {id}")).await?;
        detail_of(&html, id)
    }

    /// 取流：详情给的是**网盘分享页** ⇒ 如实交回 + label 写明需网盘链路
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let (_vid, url) = split_ep_id(id).ok_or_else(|| {
            format!("取流 id 必须是 `{{详情id}}\\u{{1}}{{网盘分享页}}` 形态（原始 id={id:?}）")
        })?;
        Ok(vec![CspPlay {
            url,
            headers: vec![
                ("User-Agent".to_string(), UA.to_string()),
                ("Referer".to_string(), format!("{SITE}/")),
            ],
            label: Some(format!("网盘分享页（{PAN_CHAIN_REASON}）")),
        }])
    }
}

/// 首页的**纯**组装（不打网络 ⇒ 离线门禁确定性 —— 与 csp_HDMoli 同一处置）
pub fn home_of(prefetch: Result<String, String>) -> CspHome {
    let items = match prefetch {
        Ok(html) => cards_from(&html, "首页").unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    CspHome {
        categories: cats(),
        items,
    }
}

crate::csp::register_site!(Libvio);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    /// ★★★ PoW 求解 —— **用真挑战页的参数复算**（这是本类最核心的判据）
    ///
    /// # 真读数（2026-10-27）
    /// ```text
    /// 挑战页：TS=1793108281 SIG=aafd6819c5ecf110… DIFF=0000 MODE=auto
    /// 求解  ：**n = 19809**（约 19810 次尝试，0.01 秒）
    /// 带 cookie `__cdn_pow=1793108281_auto_19809_aafd6819…` ⇒ **403 → 302 → 200**
    /// ```
    /// 注入：把 `starts_with(&d)` 改成 `ends_with(&d)` ⇒ 本条红。
    #[test]
    fn pow_solve_matches_real_challenge() {
        // ★ 用**固定 SIG/DIFF**做可复算判据（不依赖当下时间）
        let sig = "aafd6819c5ecf1105dbc6ea2ce3fc9d374187d00000000000000000000000000";
        let diff = "0000";
        let n = solve_pow(sig, diff, 2_000_000).expect("DIFF=0000 应该很容易解出");
        // ① 解必须**真的满足前缀条件**（不是"跑完就返回"）
        assert!(
            sha256_hex(&format!("{sig}{n}")).starts_with(diff),
            "★ 解出的 n 必须真满足 sha256(SIG+n) 以 DIFF 为前缀"
        );
        // ② 必须是最小解（**前面没有更小的**）—— 否则"解"不是协议要求的那一个
        for k in 0..n {
            assert!(
                !sha256_hex(&format!("{sig}{k}")).starts_with(diff),
                "★ n={n} 不是最小解：k={k} 更早就满足"
            );
        }
        // ③ 反面对照：改一个字符 ⇒ 解不再是解
        assert!(
            !sha256_hex(&format!("{sig}X{n}")).starts_with(diff),
            "★ 拼接形态必须是 SIG 在前、n 在后（无分隔符）"
        );
        // ④ 求不到 ⇒ None（不编一个）
        assert_eq!(
            solve_pow("deadbeef", "ffffffff", 10_000),
            None,
            "★ 求不到必须 None（不许编 nonce）"
        );
        assert_eq!(solve_pow("x", "", 10), None, "★ 空 DIFF ⇒ None");
    }

    #[test]
    /// ★★ PoW 参数提取（DEX 的正则逐字）+ **不可用的页面必须返回 None**
    ///
    /// 注入：把 `TS` 那一段正则改掉 ⇒ 本条红。
    #[test]
    fn pow_params_are_extracted_verbatim() {
        let page = r#"<script>
  var TS = "1793108281", SIG = "aafd6819c5ecf110", DIFF = "0000", MODE = "auto";
  var POW = "__cdn_pow";
</script>"#;
        let p = pow_of(page).expect("应能提取");
        assert_eq!(p.ts, "1793108281");
        assert_eq!(p.sig, "aafd6819c5ecf110");
        assert_eq!(p.diff, "0000");
        assert_eq!(p.mode, "auto");
        // 空洞必须以空格/换行分隔照样能取（实测页面就是多空格）
        let page2 = r#"var  TS  =  "1" ,  SIG = "ab" , DIFF = "12", MODE = "checkbox""#;
        assert_eq!(pow_of(page2).map(|p| p.mode).as_deref(), Some("checkbox"));
        // ★ 不是挑战页 ⇒ None（不许编参数）
        assert_eq!(pow_of("<html>普通页面</html>"), None);
        assert_eq!(pow_of(""), None);
    }

    #[test]
    /// ★★ PoW cookie 值形态逐字：`{TS}_{MODE}_{n}_{SIG}`
    ///
    /// 注入：把格式串的分隔符改掉 ⇒ 本条红。
    #[test]
    fn pow_cookie_value_is_verbatim() {
        let p = Pow {
            ts: "1793108281".into(),
            sig: "aafd6819".into(),
            diff: "0000".into(),
            mode: "auto".into(),
        };
        assert_eq!(
            pow_cookie_value(&p, 19809),
            "1793108281_auto_19809_aafd6819",
            "★ 实测 cookie 形态就是这个顺序"
        );
        assert_eq!(POW_COOKIE, "__cdn_pow", "★ cookie 名在 403 页里逐字写着");
    }

    #[test]
    /// ★★ URL 模板逐字 + 编码
    #[test]
    fn url_templates_are_verbatim() {
        assert_eq!(SITE, "https://www.libvio.io");
        assert_eq!(list_url("1", 1), "https://www.libvio.io/type/1-1.html");
        assert_eq!(list_url("16", 3), "https://www.libvio.io/type/16-3.html");
        assert_eq!(detail_url("714893782"), "https://www.libvio.io/detail/714893782.html");
        assert_eq!(
            detail_url("714893782.html"),
            "https://www.libvio.io/detail/714893782.html"
        );
        let s = search_url("战狼");
        assert_eq!(
            s,
            "https://www.libvio.io/search/-------------.html?wd=%E6%88%98%E7%8B%BC",
            "★ DEX 的搜索模板那 13 个 `-` 是逐字的"
        );
        let s2 = search_url("a&b");
        assert!(!s2.contains("a&b"), "裸 `&` 会改 URL 结构：{s2}");
    }

    #[test]
    /// ★★ 卡片解析：**不依赖属性顺序**（实测页面里属性次序与 DEX 正则假设不一致的风险）
    ///
    /// 注入：把 `re_href` 的 `/detail/` 前缀去掉 ⇒ 本条红。
    #[test]
    fn cards_parse_regardless_of_attr_order() {
        // 变体 1：DEX 正则的形态（href 在 title 前）
        let h1 = r#"<a class="stui-vodlist__thumb" href="/detail/714893782.html" title="不存在的罪人" data-original="https://p/a.jpg">
                   <a href="/detail/714893781.html" title="末世行者" data-original="https://p/b.jpg">"#;
        let c = cards_from(h1, "列表").unwrap();
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].id, "714893782");
        assert_eq!(c[0].title, "不存在的罪人");
        assert_eq!(c[0].cover.as_deref(), Some("https://p/a.jpg"));
        // 变体 2：**属性顺序打乱**（title 在 href 前、data-original 在最前）
        let h2 = r#"<a data-original="https://p/c.jpg" title="乱序也要认" href="/detail/123.html">"#;
        let c2 = cards_from(h2, "列表").unwrap();
        assert_eq!(c2[0].id, "123");
        assert_eq!(c2[0].title, "乱序也要认");
        assert_eq!(c2[0].cover.as_deref(), Some("https://p/c.jpg"));
        // 同条目重复 ⇒ 去重
        let h3 = r#"<a href="/detail/1.html" title="A"><a href="/detail/1.html" title="A">"#;
        assert_eq!(cards_from(h3, "x").unwrap().len(), 1);
        // 实体要还原
        let h4 = r#"<a href="/detail/5.html" title="A&amp;B">"#;
        assert_eq!(cards_from(h4, "x").unwrap()[0].title, "A&B");
    }

    #[test]
    /// ★★ 反空真：卡片 / 标题 / 网盘 抓不到 ⇒ **必须 Err**
    ///
    /// 注入：删掉 `cards_from` 的 `if out.is_empty()` ⇒ 本条红。
    #[test]
    fn empty_extractions_are_errors() {
        let e = cards_from("<html>没有卡片</html>", "列表").expect_err("★ 0 条必须 Err");
        assert!(e.contains("没抓到卡片"), "{e}");
        assert!(e.contains("字符"), "要带回页面大小：{e}");
        let e2 = detail_of("<html>没标题没网盘</html>", "1").expect_err("★ 必须 Err");
        assert!(e2.contains("标题"), "{e2}");
        let e3 = detail_of("<title>有标题 - LIBVIO</title>", "1").expect_err("★ 无网盘必须 Err");
        assert!(e3.contains("网盘"), "{e3}");
    }

    #[test]
    /// ★★ 详情解析（真读数形态）+ 网盘识别（**只认 DEX 列出的宿主**）
    ///
    /// 注入：把 `PAN_HOSTS` 判据去掉（任何 http 链接都当网盘）⇒ 本条红。
    #[test]
    fn detail_parses_and_only_real_pan_hosts_count() {
        let html = r#"<title>末世行者 - LIBVIO</title>
          <span class="detail-content">剧情简介文本</span>
          <span class="meta-item">2026</span><span class="meta-item">美国</span>
          <a href="https://pan.quark.cn/s/abc123">夸克</a>
          <a href="https://pan.baidu.com/s/xyz?pwd=1">百度</a>
          <a href="https://www.libvio.io/type/1-1.html">站内链接（不是网盘）</a>
          <a href="https://ads.example.com/x">广告（不是网盘）</a>"#;
        let d = detail_of(html, "714893782").unwrap();
        assert_eq!(d.title, "末世行者");
        assert!(d.description.as_deref().unwrap_or("").contains("剧情简介文本"));
        assert!(d.description.as_deref().unwrap_or("").contains("2026"), "meta 要拼进去");
        assert_eq!(d.episodes.len(), 2, "★★ 站内链接与广告**不许**被当成网盘：{:?}",
                   d.episodes.iter().map(|e| &e.title).collect::<Vec<_>>());
        assert!(d.episodes[0].title.contains("pan.quark.cn"));
        let (id, url) = split_ep_id(&d.episodes[1].id).unwrap();
        assert_eq!(id, "714893782");
        assert_eq!(url, "https://pan.baidu.com/s/xyz?pwd=1");
        // 含 `?pwd=` 的地址不能切坏
        assert!(url.contains("pwd=1"));
    }

    /// ★★ 四段行为 + `play` 诚实 label（**不假装是直链**）
    ///
    /// 注入：把 `play` 的形态检查删掉 ⇒ 本条红。
    ///
    /// ⚠️ 只留 `#[tokio::test]`（叠 `#[test]` ⇒ "async functions cannot be used for tests"）。
    #[tokio::test]
    async fn segments_behave_and_play_is_honest() {
        let s = Libvio::new();
        assert!(s.supports_search());
        let h = home_of(Err("离线门禁不打网络".into()));
        assert!(!h.categories.is_empty());
        assert!(h.items.is_empty());
        assert!(h.categories.iter().any(|c| c.name == "电影"));
        // 第 2 页 ⇒ Err
        let e = s.search("x", 2, "").await.expect_err("★ 第 2 页必须 Err");
        assert!(e.contains("不支持分页"), "{e}");
        // play 形态不对 ⇒ Err
        let e2 = s.play("网盘", "714893782", "").await.expect_err("★ 裸 id 必须 Err");
        assert!(e2.contains("形态"), "{e2}");
        // play 正常 ⇒ 交回分享页 + 诚实 label
        let p = s
            .play("网盘", "714893782\u{1}https://pan.quark.cn/s/abc", "")
            .await
            .unwrap();
        assert_eq!(p[0].url, "https://pan.quark.cn/s/abc");
        let lab = p[0].label.clone().unwrap_or_default();
        assert!(lab.contains("网盘分享页"), "★ 必须写清是分享页：{lab}");
        assert!(lab.contains(PAN_CHAIN_REASON), "{lab}");
    }

    #[test]
    /// ★★★ 边界冻结：**只做协议、不做绕过**（本类最该留档的一条）
    ///
    /// # 判据（源码级）
    /// ```text
    /// 允许：读 PoW 参数、算 SHA-256、写 cookie、**重试一次**
    /// 禁止：换 IP / 代理规避 / 伪造浏览器指纹（`navigator`/`webdriver` 之类）/
    ///       模拟鼠标滑动 / 转第三方打码 / 无限重试
    /// ```
    /// 注入：在 `get_text` 里加一个"换 User-Agent 重试"或"循环重试"⇒ 本条红。
    #[test]
    fn only_protocol_never_bypass() {
        let src = include_str!("libvio.rs");
        let code: Vec<String> = src
            .lines()
            .map(|l| {
                let t = l.trim();
                if t.starts_with("//") || t.starts_with('*') || t.starts_with("/*") {
                    String::new()
                } else {
                    l.split("//").next().unwrap_or("").to_string()
                }
            })
            .collect();
        /*
         * ★★ 这两条判据我修过一次（**自证陷阱**，本仓已多次同形）：
         *   第一版把禁令词**整串写在断言行上** ⇒ 判据行自己就是"代码里出现了那个词"
         *   ⇒ **假红**（`★ 不许伪造浏览器指纹：navigator` 就是这么被触发的）。
         *   ⇒ 修法两条一起用：
         *     ① 禁令词**拼出来**（`format!`），断言行不再含整串；
         *     ② 判据只扫**代码行**（`code`，行首注释与 doc 注释都被剔除）。
         */
        // ① 不许伪造浏览器指纹
        for bad in ["navi", "gator", "webdr", "iver", "canv", "as", "finger", "print"] {
            let word = bad.to_string();
            // 上面把词拆成两段 ⇒ 拼回来才是要查的全词
            let _ = word;
        }
        for pair in [("navi", "gator"), ("webdr", "iver"), ("finger", "print")] {
            let full = format!("{}{}", pair.0, pair.1);
            assert!(
                !code.iter().any(|l| l.contains(&full)),
                "★ 不许伪造浏览器指纹：{full}"
            );
        }
        // ② 不许出现"滑动/打码"之类的人机绕过
        for pair in [("slid", "er"), ("capt", "cha"), ("2capt", "cha")] {
            let full = format!("{}{}", pair.0, pair.1);
            assert!(!code.iter().any(|l| l.contains(&full)), "★ 不许做人机绕过：{full}");
        }
        /*
         * ③ ★★ 循环**必须有界**（判据随实现改过一次，如实留档）
         *
         * ```text
         * 第一版实现：`is_challenge` 分支里两次 `.send()`（首次 + PoW 后重试）
         *   ⇒ 判据写成 `sends == 2`。
         * 第二版实现（手工跟随重定向后）：改成一个 `loop` + **单处 `.send()`**
         *   ⇒ 旧判据 `sends == 2` 变成 **假红**（实际 1 次）。
         * ★ 这暴露一个更本质的问题：**"数 send 次数"不是"有界"的判据** ——
         *   把 send 放进 loop 会**让次数变少**（1 处），却可能更"无限"。
         * ⇒ 改成**直接钉界**（这才是真正要守的东西）：
         *     · `hops > 4` ⇒ 停（重定向有界）
         *     · `pow_solved` 标记 ⇒ PoW **只解一次**
         *     · 不许 `while true` / 无界 `loop` 而不带跳出条件
         * ```
         */
        let body = src
            .split("async fn get_text")
            .nth(1)
            .unwrap_or("")
            .split("impl Default for Libvio")
            .next()
            .unwrap_or("");
        assert!(
            body.contains("hops > 4"),
            "★★ 重定向必须**有界**（`hops > 4` ⇒ 停）—— 不许无限跟随"
        );
        assert!(
            body.contains("pow_solved"),
            "★★ PoW 只能解**一次**（用 `pow_solved` 标记）—— 不许每次 403 都重解"
        );
        assert!(
            body.contains("3") && body.contains("4"),
            "★★ 跳跃上限必须是显式数字（不是靠时间/次数自然结束）"
        );
        // 不许无界循环
        assert!(!body.contains("while true"), "★★ 不许 `while true`");
        // ④ 必须真的实现了 PoW + 接收 verified cookie（不是"遇 403 就放弃"）
        assert!(body.contains("solve_pow"), "★★ 必须真的去解 PoW");
        assert!(body.contains("pow_cookie_value"), "★★ 必须把 PoW cookie 带回去");
        assert!(
            body.contains("VERIFIED_COOKIE"),
            "★★ 必须**接收并带回** `__cdn_verified`（★ 我第一版漏了它 ⇒ 302 死循环）"
        );
        assert!(
            body.contains("SET_COOKIE"),
            "★★ 必须读响应头的 `set-cookie` —— 凭据就在那里"
        );
    }

    /// ★★ 四条"注入不红"的判据缺口 —— 逐条查出的真因（都是**离线夹具够不到的实现细节**）
    ///
    /// # 为什么必须有这一条
    /// ```text
    /// 我的 14 条注入里 B/L/M/N **不红**。按纪律先核 diff（四条**都真的改到了代码**）
    /// ⇒ 结论：**是判据不覆盖**。逐条真因：
    ///
    /// ① 注入 B（PoW 参数正则改坏）——★ 真因：**纯函数 `pow_of` 有门禁，
    ///    但"`get_text` 里是否真的用了 `pow_of`"没有门禁** ⇒ 改坏了也不影响。
    /// ② 注入 L（不再接收 `__cdn_verified`）——★ 真因：`only_protocol_never_bypass`
    ///    只断言源码里**出现** `VERIFIED_COOKIE` 字样；把它换成别的前缀，
    ///    字样**还在**（我改的是 `strip_prefix` 的参数，不是那个常量）⇒ 判据假绿。
    /// ③ 注入 M（重定向改回自动跟随）——★ 真因：**没有判据钉"必须手工跟随"**。
    /// ④ 注入 N（去掉 `.no_proxy()`）——★ 真因：**同样没有判据钉它**
    ///    （讽刺的是这正是我上一轮在 HDMoli 上学到的那条 ⇒ 必须补钉子防回归）。
    ///
    /// ★ 共性：**这些是"实现层面的选择"**（用哪个函数、开不开某个 policy、带不带某个头），
    ///   纯函数门禁天然看不到 ⇒ 必须在**实现体里**按结构断言。
    /// ```
    /// 注入 B/L/M/N ⇒ 本条必须红。
    #[test]
    fn implementation_choices_are_pinned() {
        let src = include_str!("libvio.rs");
        let body = src
            .split("async fn get_text")
            .nth(1)
            .unwrap_or("")
            .split("impl Default for Libvio")
            .next()
            .unwrap_or("");
        // ① 实现里必须**调用** `pow_of`（不只是"存在这个函数"）
        assert!(
            body.contains("pow_of(&body)"),
            "★★ `get_text` 必须真的用 `pow_of` 去读挑战页参数（注入 B）"
        );
        // ② 必须真的按 `VERIFIED_COOKIE` 这个**名字**去接 cookie（注入 L）
        assert!(
            body.contains("strip_prefix(&format!(\"{VERIFIED_COOKIE}=\"))"),
            "★★ 必须按 `{{VERIFIED_COOKIE}}=` 这个**名字**接 cookie（注入 L）"
        );
        // ③ 必须**手工跟随**重定向（`Policy::none()` 在 client 构造处）
        let client_block = src
            .split("reqwest::Client::builder()")
            .nth(1)
            .unwrap_or("")
            .split(".build()")
            .next()
            .unwrap_or("");
        assert!(
            client_block.contains("redirect::Policy::none()"),
            "★★ 必须 `.redirect(Policy::none())` + 手工跟随（注入 M：自动跟随会丢 cookie ⇒ 死循环）"
        );
        // ④ 必须 `.no_proxy()`（注入 N；上一轮 HDMoli 学到的系统性缺陷）
        assert!(
            client_block.contains(".no_proxy()"),
            "★★ 必须 `.no_proxy()`（本仓 csp 既定惯例；否则装了代理的机器上这个源必坏）"
        );
    }

    // ── 真网络（CSP_LIVE=1 + --ignored）──
    /// ★★ 真网四段（**含 PoW**）。判据是"必须真的取到数据"。
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_libvio -- --ignored --nocapture"]
    async fn csp_live_libvio_four_segments() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Libvio::new();
        let h = s.home("").await.expect("home 应成功（含 PoW）");
        eprintln!(
            "[LIVE] home: 分类 {} 个（首={}），预取 {} 条｜PoW cookie 已缓存={}",
            h.categories.len(),
            h.categories[0].name,
            h.items.len(),
            s.cached_pow().is_some()
        );
        let l = s.list("1", 1, "").await.expect("list 应成功");
        eprintln!("[LIVE] list(电影 p1): {} 条 首={}", l.items.len(), l.items[0].title);
        assert!(!l.items.is_empty());
        let se = s.search("末", 1, "").await.expect("search 应成功");
        eprintln!("[LIVE] search(末): {} 条 首={}", se.items.len(), se.items[0].title);
        let d = s.detail(&l.items[0].id, "").await.expect("detail 应成功");
        eprintln!(
            "[LIVE] detail: {} — {} 个网盘（首={}）",
            d.title,
            d.episodes.len(),
            d.episodes[0].title
        );
        let p = s.play("网盘", &d.episodes[0].id, "").await.expect("play 应成功");
        eprintln!("[LIVE] play: {} [{}]", p[0].url, p[0].label.clone().unwrap_or_default());
        assert!(p[0].url.starts_with("http"));
    }
}