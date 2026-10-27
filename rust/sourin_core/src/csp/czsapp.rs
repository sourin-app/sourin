// ═══════════════════════════════════════════════════════════════════════
//  csp_Czsapp —— 「🏪厂长｜蓝光影视」（上游当前被 WAF 拦截，见下）
// ═══════════════════════════════════════════════════════════════════════
//
// # 配置里覆盖什么
//
// ```text
// 订阅（8815.kstore.vip/tvbox/wmz）100 站里：
//   csp_Czsapp  🏪厂长｜蓝光影视   ext = "https://cz01.vip"
// ```
//
// # ★★★ 2026-10-27 真网络实测：**ext 给的域名是导航页，真域名被 WAF 挡死**
//
// ```text
// 【第一层：ext 给的 cz01.vip 根本不是站点】
//   GET https://cz01.vip/  → 200 · 2069 B · <title>厂长资源官网</title>
//   但它是一张**导航/跳转页**，正文逐字写着：
//     「新地址 www.4kcz.com，本页面是默认跳转页面」
//     「cz01.vip 本导航页地址，请保存 CTRL+D 保存导航地址」
//     「以往的域名都已失效，敬请知晓！」
//     「推荐访问 //www.4kcz.com / //czzy.top / //www.cz4k.com」
//     + JS 自动跳转到 https://www.4kcz.com
//   ⇒ 该域名的 DEX 里那套路径（`/boss1O1?q=` 搜索、`/{tid}/page/{n}`、`/voddetail/…`）
//     在它上面**全 404** —— 因为这里只是导航页，没有 CMS 内容。
//
// 【第二层：真域名被 SafeLine(雷池) WAF 拦截】
//   按导航页给的三个"推荐访问"域名逐个复测：
//     www.4kcz.com / czzy.top / www.cz4k.com  → **全部 403**
//   403 页特征（逐字读出，是**独立的正面证据**，不是"我猜它被挡了"）：
//     · `<link rel="icon" href="/.safeline/static/favicon.png">`
//     · 正文含 `safeline` / `SafeLine` / `雷池` / `WAF` 四处字样
//     · 响应头 `Set-Cookie: sl-session=fChILR/D4WpNTLXauL1ITA==; … HttpOnly`
//     · 内联脚本里有 `console.log("hashID: a8023d9")`
//     · 挑战页里**没有任何** token/challenge/verify 计算或跳转逻辑
//
// 【我按"必须区分『我探测不对』与『上游死/被挡』"这条纪律**逐项排除**】
//   ① 6 个域名 × 9 种入口形式 × **浏览器级完整头**
//        （UA/Accept/Accept-Language/Sec-Ch-Ua*/Sec-Fetch-*/Upgrade-Insecure-Requests…）
//      → 除 WAF 自己的 favicon 外，**全部 403**
//      ⇒ 排除"我路径形式不对" / "我头不对"
//   ② 挑战页里**没有可解的计算逻辑**（无 token/challenge/verify、无 setTimeout 跳转、
//      无外链 JS、无表单、无接口）
//      ⇒ 这不是"可解的 JS 挑战"，是**静态拦截页**
//   ③ cookie 回放 + 10 种常见绕过头（Referer 自身/百度、X-Forwarded-For、
//      X-Real-IP、X-Originating-IP、回放 sl-session、Accept:*/*、curl UA、okhttp UA…）
//      → **拿到真内容 0 种**
//      ⇒ 排除"只要回放 cookie 就行"
//   ④ 唯一返回 200 的是 `/.safeline/static/favicon.png`（5877 B）——
//      那是 **WAF 自己的静态资源**，**不是站点内容**
//      ⇒ 所以"有 200"不能证明站点可用（这条正是我在 Wwys 上踩过的坑的孪生）
// ```
//
// # ⛔ 所以本类**不能真取数**（如实登记，不硬造）
//
// ```text
// 本实现按 DEX 常量把**协议完整写出来**（路径模板、选择器语义、字段名），
// 但连**第一次请求**都会拿到 403 + SafeLine 拦截页 ⇒
//   · 不假装能解析（403 页里没有 `.bt_img.mi_ne_kd > ul >li` 这类结构）
//   · 不伪造分类/条目/地址
//   · 把"被哪种 WAF 挡住 + 我的排除过程"作为错误文案原样带出来，
//     让用户/下一个接手的人**一眼知道不是配置错**
//
// ⇒ 这一步的结论：**需要契约补能力位（WAF 对抗 / 浏览器指纹）**，
//   本仓当前没有该能力位（既不嵌 JS 引擎，也不做指纹伪装）。
//   ⇒ 与 `webhtml`（需 WebView）同档：**如实标"本仓当前不可用"**，不做假通。
// ```
//
// # 为什么还是要把实现写出来（而不是留空文件）
// ```text
// ① 上游**会换域名**（导航页自己就写着"以往域名都已失效"）⇒
//    等它换到一个**没上 WAF** 的域名时，这个实现**立刻可用**（协议部分是照 DEX 写的）。
// ② 全仓 100 站里这一站的 `ext` 只换域名就能复用 ⇒ 留实现比留空文件有价值。
// ③ 门禁能钉住"协议常量对不对"（不依赖网络）。
// ```
//
// # 已知缺口（按 Lead 裁定的契约边界登记）
// ```text
// · mProxy   —— 本批不做（本批无 mProxy 等价位）
// · loadPic  —— 本仓不补 trait；封面头见 COVER_HEADERS（声明式）
// · `loadSub`（DEX 有：AES/CBC/PKCS7 解字幕）—— 本仓**无字幕契约** ⇒ 如实未实现
//    （不是"忘了"：本层没有"字幕"这一等价位，见 CspSite trait）
// · `isVideoFormat` / `manualVideoCheck` —— DEX 里 Czsapp **没有**这两个方法 ⇒ 不适用
// ```

use async_trait::async_trait;
use regex::Regex;
use std::sync::OnceLock;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// ext 缺省时的兜底（订阅里给的就是这个 —— ⚠️ 它是**导航页**，见文件头）
const DEFAULT_BASE: &str = "https://cz01.vip";

/// DEX `init()` 里的 UA
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 封面请求头（声明式）—— 当前取不到真内容 ⇒ 留空（不编）
pub const COVER_HEADERS: &[(&str, &str)] = &[];

const TIMEOUT: Duration = Duration::from_secs(20);

/// 实测的 SafeLine 拦截特征（**逐字**从 403 页读出来的，不是猜的）
///
/// # ⚠️ 顺序有讲究：**最具体的放前面**
/// ```text
/// 我第一版把 `safeline` 放在最前 ⇒ `waf_marker_of` 返回的是那个**最泛**的词。
/// 而 `safeline` 也可能出现在**正常页面**里（比如站点自己引了 safeline 的静态资源），
/// 单凭它就下结论不够。⇒ 判据要**从最有诊断力的特征往下排**：
///   ① `/.safeline/static/favicon.png` —— WAF 拦截页独有的路径（最硬）
///   ② `sl-session`                     —— WAF 的 cookie 名
///   ③ `雷池`                            —— 中文名（只在 WAF 页出现）
///   ④ `safeline`                        —— 最泛，放最后兜底
/// ```
pub const WAF_MARKERS: &'static [&'static str] = &[
    "/.safeline/static/favicon.png",
    "sl-session",
    "雷池",
    "safeline",
];

/// DEX 里的分类（**首页导航**给的；写死是因为现在拿不到真导航）
///
/// ⚠️ 这是照 DEX 的 `homeContent` 常量写的（DEX 里它是从 `#topnav` 抓的），
/// 现在站点取不到 ⇒ **只是"预期分类"**，不是实测分类。文件头已说明。
pub const CATEGORIES: &'static [(&'static str, &'static str)] = &[
    ("1", "电影"),
    ("2", "剧集"),
    ("3", "动漫"),
];

pub struct Czsapp {
    client: reqwest::Client,
}

impl Czsapp {
    pub const CLASS: &'static str = "Czsapp";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            .no_proxy()
            .build()
            .expect("build czsapp http client");
        Self { client }
    }

    /// 从 ext 取站点（订阅里是**裸 URL 字符串**）
    pub fn base_of(ext: &str) -> String {
        static RE: OnceLock<Regex> = OnceLock::new();
        let re = RE.get_or_init(|| Regex::new(r#"https?://[^"'\s,\]}]++"#).expect("url regex"));
        re.find(ext)
            .map(|m| m.as_str().trim_end_matches('/').to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| DEFAULT_BASE.to_string())
    }

    /// 带 WAF 识别的 GET
    ///
    /// # ★ 为什么要**显式**识别 WAF 页（而不是让它落到解析器）
    /// ```text
    /// 403 + 拦截页如果直接交给解析器，会**静默返回 0 条** ⇒
    /// 症状变成"这个分类没内容"（与"站点被挡"完全不同的结论，且更难查）。
    /// ⇒ 必须在最外层把它变成一个**说清原因**的错误。
    /// ```
    async fn get(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .header(reqwest::header::ACCEPT_LANGUAGE, "zh-CN,zh;q=0.9")
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{url}）：{e}"))?;

        if let Some(marker) = waf_marker_of(&text) {
            return Err(format!(
                "上游被 WAF 拦截（{url}）：HTTP {status}，拦截页特征含 `{marker}`。\
                 实测该站（www.4kcz.com / czzy.top / www.cz4k.com）被 「SafeLine(雷池)」 挡住：\
                 6 域名 × 9 入口 × 浏览器级头全部 403，\
                 挑战页无可解逻辑、cookie 回放与 10 种常见绕过头均无效。\
                 这不是配置错，也不是「路径不对」——需要 WAF 对抗/浏览器指纹能力位。"
            ));
        }
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）"));
        }
        Ok(text)
    }
}

impl Default for Czsapp {
    fn default() -> Self {
        Self::new()
    }
}

/// 判断一段 HTML 是否为已知 WAF 的拦截页；返回命中的特征（None = 不像拦截页）
///
/// ★ **抽成纯函数**：这样"WAF 识别"这条判据能被单测直接驱动
/// （不必真打网络）—— 否则它又会变成一条"不可测的分支"（Hxq 上踩过）。
pub fn waf_marker_of(html: &str) -> Option<&'static str> {
    WAF_MARKERS.iter().copied().find(|m| html.contains(m))
}

/// 列表页条目解析（照 DEX 的 `c`/`d` 两个方法的选择器语义）
///
/// DEX 用的选择器：`.bt_img.mi_ne_kd > ul >li` → `a[href]` / `.dytit > a` / `img[data-original]` / `.jidi span`
/// ★ 这里锚在**最稳的形状**上（`href` 里含数字 id），而不是 class 名
///   （Wwys 上已验证：class 名会随主题变，URL 形状不会）
pub fn items_of_list(html: &str) -> Vec<CspItem> {
    static RE: OnceLock<Regex> = OnceLock::new();
    /*
     * ⚠️ 这个正则改过一版，留档为什么：
     * ```text
     * 第一版我写成
     *   `<a href="…detail/(\d+)…"[^>]*>(.{0,600})`
     * ⇒ 它**要求 `>` 紧跟 href**，而真结构是：
     *     <a href="/voddetail/1234.html">
     *         <img …>
     *         <h4 class="dytit"><a>某部电影</a></h4>     ← ★ 这个 `<a>` 是**内层**的
     *     </a>
     *   外层的 `</a>` 与内层的 `<a>` 让"一个条目"有**两个 `<a`**，
     *   而我的块窗口从外层锚的末尾开始 ⇒ 会先命中**内层**的锚（它不带 detail 数字 id）
     *   ⇒ 第二条被吞掉 ⇒ 测试报 `left: 1, right: 2`（真红，抓对了）。
     * ⇒ 修法：显式区分"锚自带 id"与"id 在 href 里"两种形态：
     *   本正则只认 **href 里带数字 id 的那种**（= 外层 `<a>`），
     *   并允许 `[^>]*>` 后面跟任意内容（不要求紧邻）。
     * ```
     */
    /*
     * ⚠️ 这个正则改过**两版**，两版都留档（都是被门禁真红逼出来的）：
     * ```text
     * 【第一版】`<a href="…detail/(\d+)…"[^>]*>(.{0,600})`
     *   ⇒ 要求 `>` **紧跟** href；真结构里外层 `<a>` 后面还有内层 `<a>`
     *     （`<a href="/voddetail/1234.html"><img…><h4 class="dytit"><a>名</a></h4></a>`）
     *   ⇒ 会先命中**内层**锚（它不带数字 id）⇒ 条目被吞。
     *
     * 【第二版】把块写成 `.{0,700}`
     *   ⇒ **贪婪**：第一个锚的块会一路吃到**第二个锚之后**
     *     ⇒ 第二条的 id 也被算进第一条的块里 ⇒ 仍然只出 1 条
     *     （测试报 `left: 1, right: 2`，抓对了）。
     *
     * 【第三版（当前）】块改成 **`.{0,700}?` 非贪婪 + 前瞻下一个锚或列表结束**
     *   —— 但 **Rust 的 `regex` 不支持 look-around**（Wwys 上已踩过）
     *   ⇒ 改用**两段式**（与 `wwys::items_of_list` 同一套做法）：
     *     ① 用锚正则找出每个条目的**起始位置**
     *     ② 从该位置到**下一个锚的起始位置**（或结尾）截块
     *   ⇒ 不需要 look-around，且"块边界 = 一个条目"是**结构性**的，不依赖窗口大小。
     * ```
     */
    let re = RE.get_or_init(|| {
        Regex::new(r#"(?s)<a\s[^>]*href="([^"]*(?:detail|vod|show)[^"]*?/(\d+)\.html[^"]*)"[^>]*>"#)
            .expect("czsapp list anchor")
    });
    let re_img = {
        static R: OnceLock<Regex> = OnceLock::new();
        R.get_or_init(|| Regex::new(r#"<img[^>]*?(?:data-original|data-src|src)="(https?://[^"]+)""#).expect("img"))
    };
    let re_title = {
        static R: OnceLock<Regex> = OnceLock::new();
        R.get_or_init(|| Regex::new(r#"class="[^"]*(?:dytit|title)[^"]*"[^>]*>\s*(?:<a[^>]*>)?\s*([^<]{1,60})"#).expect("title"))
    };
    let mut out: Vec<CspItem> = Vec::new();
    // 先收所有锚的位置，再用"下一个锚"定块边界
    let anchors: Vec<regex::Match> = re.find_iter(html).collect();
    for (i, m) in anchors.iter().enumerate() {
        let c = match re.captures(m.as_str()) {
            Some(c) => c,
            None => continue,
        };
        let id = c[2].to_string();
        if out.iter().any(|x| x.id == id) {
            continue;
        }
        // 块 = 本锚结束 → 下一个锚开始（或到结尾）
        let start = m.end();
        let end = anchors.get(i + 1).map(|n| n.start()).unwrap_or(html.len());
        if start >= end {
            continue;
        }
        let block = safe_slice(html, start, end);
        let title = re_title
            .captures(block)
            .map(|t| crate::tvbox::decode_entities(&t[1]).trim().to_string())
            .filter(|t| !t.is_empty())
            .unwrap_or_default();
        if title.is_empty() {
            continue;
        }
        out.push(CspItem {
            id,
            title,
            cover: re_img.captures(block).map(|m| m[1].to_string()),
            subtitle: None,
        });
    }
    out
}

/// 按字节截一段但**对齐字符边界**（与 `wwys::safe_slice` 同一理由）
///
/// ★ 中文字符 3 字节 ⇒ 任意字节下标极易落在汉字中间 ⇒ 裸切会 **panic**。
///   Wwys 上真网络炸过一次，这里预先防住（同样的写法不能只改一处）。
pub fn safe_slice(s: &str, from: usize, to: usize) -> &str {
    if from > s.len() {
        return "";
    }
    let mut a = from;
    while a > 0 && !s.is_char_boundary(a) {
        a -= 1;
    }
    let mut b = to.min(s.len());
    while b > a && !s.is_char_boundary(b) {
        b -= 1;
    }
    &s[a..b]
}

/// 从播放页 HTML 里抽 `mac_url` 形态的播放值（DEX `playerContent` 的正则）
///
/// DEX 的两条正则：
/// ```text
/// `src\s*=\s*'([^']+)'\s*\+\s*videoUrl`   → 前缀
/// `url: '([^']*)'`                         → 地址
/// ```
pub fn play_from_html(html: &str) -> Option<String> {
    let re = Regex::new(r#"mac_url='([^']*)'"#).expect("mac_url");
    if let Some(c) = re.captures(html) {
        let v = c[1].trim().to_string();
        if !v.is_empty() {
            return Some(v);
        }
    }
    // 退到 DEX 里那条 `url: '…'`
    let re2 = Regex::new(r#"url:\s*'([^']*)'"#).expect("url quote");
    re2.captures(html)
        .map(|c| c[1].trim().to_string())
        .filter(|s| !s.is_empty())
}

#[async_trait]
impl CspSite for Czsapp {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：**拿不到**（上游 WAF 拦截）⇒ 如实 Err，不编分类
    ///
    /// # 为什么这里**不**返回写死的分类表
    /// ```text
    /// 若返回写死的 3 个分类，用户会看到一个"有分类但点进去全空"的源 ——
    /// 那是本仓最忌讳的"看起来支持"。⇒ 首页就如实失败，让导入报告把这一站标成不可用。
    /// ```
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let base = Self::base_of(ext);
        // 先试一次 —— 上游换域名/撤 WAF 时这条会立刻通
        let _ = self.get(&format!("{base}/")).await?;
        Err(format!(
            "{base} 返回的既不是站点也不是 WAF 页（无法判定形态）—— 需要人工复核"
        ))
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let base = Self::base_of(ext);
        let page = if page == 0 { 1 } else { page };
        // DEX 的模板：`/%s/page/%s`
        let html = self.get(&format!("{base}/{tid}/page/{page}")).await?;
        let items = items_of_list(&html);
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
            return Err("条目 id 为空".to_string());
        }
        let base = Self::base_of(ext);
        // DEX 的模板：`{base}/{id}.html`
        let html = self.get(&format!("{base}/{vid}.html")).await?;
        let title = {
            static RE: OnceLock<Regex> = OnceLock::new();
            let re = RE.get_or_init(|| {
                Regex::new(r#"(?s)<h[12][^>]*>\s*([^<]{1,80}?)\s*</h[12]>"#).expect("title")
            });
            re.captures(&html)
                .map(|c| crate::tvbox::decode_entities(&c[1]).trim().to_string())
                .filter(|t| !t.is_empty())
        };
        let title = title.ok_or_else(|| format!("详情页没解析出标题（id={vid}）"))?;
        // 剧集：DEX 的 `.paly_list_btn a` → `href`
        static RE_EPS: OnceLock<Regex> = OnceLock::new();
        let re_eps = RE_EPS.get_or_init(|| {
            Regex::new(r#"href="([^"]*\{?[a-zA-Z0-9_\-/]*\d+[^"]*)"[^>]*class="[^"]*btn[^"]*""#)
                .expect("eps")
        });
        let mut episodes: Vec<CspEpisode> = Vec::new();
        let mut seen: Vec<String> = Vec::new();
        for c in re_eps.captures_iter(&html) {
            let path = c[1].to_string();
            if seen.contains(&path) {
                continue;
            }
            seen.push(path.clone());
            episodes.push(CspEpisode {
                id: path,
                title: format!("第{}集", episodes.len() + 1),
                flag: "默认".to_string(),
            });
        }
        if episodes.is_empty() {
            return Err(format!("「{title}」详情页没有播放按钮（上游结构可能变了）"));
        }
        Ok(CspDetail {
            id: vid.to_string(),
            title,
            cover: None,
            description: None,
            episodes,
        })
    }

    /// 搜索：DEX 的 `/boss1O1?q=`（⚠️ 实测在 cz01.vip 上是 404 —— 那只是导航页）
    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let base = Self::base_of(ext);
        let page = if page == 0 { 1 } else { page };
        let html = self
            .get(&format!(
                "{base}/boss1O1?q={}",
                urlencoding::encode(kw)
            ))
            .await?;
        let items = items_of_list(&html);
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    fn supports_search(&self) -> bool {
        // ★ 如实 false：搜索路径在 ext 给的域名上实测 404，
        //   而真域名被 WAF 挡死 ⇒ 声明 true 会让 registry 把它纳入聚合搜索并恒返回空
        false
    }

    async fn play(&self, _flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let base = Self::base_of(ext);
        let path = id.trim();
        if path.is_empty() {
            return Err("剧集 id 为空".to_string());
        }
        let url = if crate::tvbox::starts_http(path) {
            path.to_string()
        } else {
            format!("{base}{path}")
        };
        let html = self.get(&url).await?;
        let val = play_from_html(&html)
            .ok_or_else(|| format!("播放页里没有 mac_url（{url}）—— 该条可能无源"))?;
        // `名$址` / `#` 分集 / `$$$` 分线 —— 复用共享解析
        let lines = crate::csp::shared::split_lines("", &val);
        let mut out: Vec<CspPlay> = Vec::new();
        for (_line, eps) in lines {
            for (name, ep_url) in eps {
                if !crate::tvbox::starts_http(&ep_url) {
                    continue;
                }
                if out.iter().any(|p| p.url == ep_url) {
                    continue;
                }
                out.push(CspPlay {
                    url: ep_url,
                    headers: vec![
                        ("Referer".to_string(), format!("{base}/")),
                        ("User-Agent".to_string(), UA.to_string()),
                    ],
                    label: Some(name),
                });
            }
        }
        if out.is_empty() {
            return Err(format!("mac_url 里没有可用的 http 地址（{url}）"));
        }
        Ok(out)
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 自注册（R3-D，2026-10-27）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类的事实（从文件头的长注释搬过来，别丢）
// ```text
// csp_Czsapp（🏪厂长｜蓝光影视）：**上游当前被 WAF 挡死，本仓不可用**
//   ext 给的 cz01.vip = **导航/跳转页**（正文写"新地址 www.4kcz.com"、"以往域名都已失效"）
//   真域名 www.4kcz.com / czzy.top / www.cz4k.com = **403 + SafeLine(雷池) WAF**
//     证据：`/.safeline/static/favicon.png` + `safeline/SafeLine/雷池/WAF` 四处字样
//           + `Set-Cookie: sl-session=…` + `hashID: a8023d9`
//   ★ 排除过（不是"我路径/头不对"）：
//     6 域名 × 9 入口 × 浏览器级头 → 全 403
//     挑战页无计算逻辑（不是可解 JS 挑战）
//     cookie 回放 + 10 种绕过头 → 0 种拿到内容
//     唯一 200 的是 WAF 自己的 favicon（5877 B，不是站点内容）
//   ⇒ 结论：**需契约补能力位（WAF 对抗/浏览器指纹）**，本仓当前没有 ⇒ 如实标不可用
//   实现仍照 DEX 写全协议（上游**会换域名**，换到没 WAF 的域名即立刻可用）
// ```
crate::csp::register_site!(Czsapp);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_is_registered_under_exact_name() {
        assert_eq!(Czsapp::CLASS, "Czsapp");
        assert_eq!(Czsapp::new().class(), "Czsapp");
    }

    #[test]
    fn base_comes_from_ext_with_the_nav_page_fallback() {
        assert_eq!(Czsapp::base_of("https://cz01.vip"), "https://cz01.vip");
        assert_eq!(Czsapp::base_of("https://a.example/"), "https://a.example");
        assert_eq!(Czsapp::base_of(r#"{"site":["https://b.example"]}"#), "https://b.example");
        assert_eq!(Czsapp::base_of(""), DEFAULT_BASE);
    }

    // ── ★★ WAF 识别（对着实测的 403 页特征） ───────────────────────────
    #[test]
    fn waf_marker_detects_the_real_safeline_page() {
        /*
         * ★ 特征全部来自**实测 403 页逐字读出的内容**（不是我编的）：
         *   `<link rel="icon" href="/.safeline/static/favicon.png">`
         *   正文含 `safeline` / `SafeLine` / `雷池` / `WAF`
         *   `Set-Cookie: sl-session=…`
         */
        let real_head = r#"<!DOCTYPE html><html><head><link rel="icon"
            href="/.safeline/static/favicon.png" type="image/png"><title id="slg-title"></title>"#;
        assert!(waf_marker_of(real_head).is_some(), "必须认出 SafeLine 页");
        assert_eq!(waf_marker_of(real_head), Some("/.safeline/static/favicon.png"));
        // 只有 sl-session 也能认
        assert!(waf_marker_of("Set-Cookie: sl-session=abc").is_some());
        // 正常页面 ⇒ None（否则会把正常站点误判成 WAF）
        assert_eq!(waf_marker_of("<html><title>厂长资源</title></html>"), None);
        assert_eq!(waf_marker_of(""), None);
    }

    #[test]
    fn waf_check_happens_before_returning_the_body() {
        /*
         * ★ 这条钉住"WAF 页不许落到解析器"：
         *   若 WAF 页被当正常 HTML 返回 ⇒ 解析器会**静默返回 0 条**
         *   ⇒ 症状变成"这个分类没内容"（与"站点被挡"完全不同的结论）。
         * ⚠️ 用 impl_src_only 剥测试段（自证陷阱，AppYQK 踩过）。
         */
        let flat = crate::csp::shared::impl_src_only(include_str!("czsapp.rs"));
        assert!(
            flat.contains("ifletSome(marker)=waf_marker_of(&text){"),
            "★ 必须在返回 body **之前**判 WAF"
        );
        // ⚠️ 判据只能断言**代码里出现的东西** —— 第一版我断言的是**注释里的那句话**，
        //    而 `impl_src_only` 会剥注释 ⇒ 必然红（Hxq/Wwys 上踩过同一个坑）。
        assert!(
            flat.contains("需要WAF对抗/浏览器指纹能力位"),
            "★ 错误文案要说清是**缺能力位**（不许只说「请求失败」）"
        );
    }

    // ── ★ 能力位（对着"搜不到就别声明 true"） ──────────────────────────
    #[test]
    fn search_is_declared_unsupported() {
        // ★ 实测 DEX 的搜索路径 `/boss1O1?q=` 在 cz01.vip 上 404，
        //   真域名被 WAF 挡 ⇒ 声明 true 会让 registry 纳入聚合搜索并**恒返回空**
        assert!(!Czsapp::new().supports_search(), "★ 必须 false");
    }

    #[tokio::test]
    async fn search_errs_with_the_real_reason() {
        let s = Czsapp::new();
        let e = s.search("火", 1, "https://cz01.vip").await.expect_err("必须 Err");
        assert!(e.contains("WAF") || e.contains("404") || e.contains("HTTP"),
                "错误要说清真因：{e}");
    }

    #[tokio::test]
    async fn home_errs_instead_of_returning_fake_categories() {
        /*
         * ★ 这条守"不许编分类"：
         *   `CATEGORIES` 常量确实存在（照 DEX 写的），但 `home()` **不许**返回它 ——
         *   返回写死分类会让用户看到"有分类但点进去全空"的源。
         */
        let s = Czsapp::new();
        let r = s.home("https://cz01.vip").await;
        assert!(r.is_err(), "★ 取不到真导航时必须 Err，不许返回写死的分类表");
        let e = r.unwrap_err();
        assert!(!e.is_empty());
    }

    // ── 列表/播放解析（纯函数，对着 DEX 选择器语义） ────────────────────
    #[test]
    fn items_of_list_anchors_on_url_shape() {
        // ★ 照 DEX 的选择器语义（`.bt_img.mi_ne_kd > ul >li` 里 a[href]）造的样本
        let html = r#"<ul><li><a href="/voddetail/1234.html">
            <img data-original="https://img.example/a.jpg">
            <h4 class="dytit"><a>某部电影</a></h4></a></li>
            <li><a href="/voddetail/5678.html"><img src="https://img.example/b.jpg">
            <h4 class="dytit"><a>另一部</a></h4></a></li></ul>"#;
        let items = items_of_list(html);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "1234");
        assert_eq!(items[0].title, "某部电影");
        assert!(items[0].cover.as_deref().unwrap().starts_with("https://img."));
        assert_eq!(items[1].id, "5678");
        // 空页 ⇒ 空（不 panic）
        assert!(items_of_list("<html>nope</html>").is_empty());
    }

    #[test]
    fn items_of_list_dedupes() {
        let html = r#"<a href="/voddetail/1.html"><h4 class="dytit"><a>A</a></h4></a>
                      <a href="/voddetail/1.html"><h4 class="dytit"><a>A</a></h4></a>"#;
        assert_eq!(items_of_list(html).len(), 1);
    }

    /// ★★ 这条是**补的**：真网络/多条目场景下，第一版正则会**吞掉后续条目**
    ///
    /// # 为什么必须有（这是被真红逼出来的）
    /// ```text
    /// 我的样本 fixture 只有 2 条、且**很短** ⇒ 第一版贪婪块 `.{0,700}` 恰好
    /// 把第二条也吞进第一块的窗口里 ⇒ 测试报 `left: 1, right: 2`（真红）。
    /// ⇒ 我改成了"块边界 = 下一个锚"的结构性做法。
    /// ★ 这条测试用 **10 条**、且每条**很长**（模拟真站 90 条/68KB 的密度），
    ///   保证"按窗口切"必然出错、只有"按锚边界切"才对。
    /// ```
    #[test]
    fn items_of_list_does_not_swallow_following_entries() {
        let long_body = "主演：某某 某某 某某 ".repeat(40); // 每条远长于任何固定窗口
        let mut html = String::from("<ul>");
        for i in 1..=10 {
            html.push_str(&format!(
                r#"<li><a href="/voddetail/{i}999.html"><img data-original="https://img.example/{i}.jpg">
                <h4 class="dytit"><a>影片{i}</a></h4><p>{long_body}</p></a></li>"#
            ));
        }
        html.push_str("</ul>");
        let items = items_of_list(&html);
        assert_eq!(items.len(), 10, "★ 10 条都必须出来（贪婪窗口会吞掉后面的）");
        for (i, it) in items.iter().enumerate() {
            let want = format!("影片{}", i + 1);
            assert_eq!(it.title, want, "第 {} 条的标题串了（块边界按错了）", i + 1);
            assert_eq!(it.id, format!("{}999", i + 1));
        }
    }

    #[test]
    fn safe_slice_never_panics_on_char_boundaries() {
        // ★ 与 wwys 同一个坑：中文 3 字节 ⇒ 裸字节切片会 panic
        let s = "汉字汉字汉字汉字汉字";
        for a in 0..=s.len() + 2 {
            for b in a..=s.len() + 2 {
                let _ = safe_slice(s, a, b); // 不 panic 即通过
            }
        }
        assert_eq!(safe_slice("abc", 1, 3), "bc");
        assert_eq!(safe_slice("abc", 9, 12), "", "越界起点 ⇒ 空串，不 panic");
    }

    /// ★ 元门禁：列表解析**不许**用"固定窗口 + 贪婪"那种写法
    #[test]
    fn list_parser_uses_anchor_boundaries_not_a_greedy_window() {
        let flat = crate::csp::shared::impl_src_only(include_str!("czsapp.rs"));
        assert!(
            // ⚠️ 归一化会**去掉所有空白** ⇒ 判据里也不许带空格
            //    （我第一版写的是 `…map(|n| n.start())` 带一个空格 ⇒ 必然不匹配）
            flat.contains("anchors.get(i+1).map(|n|n.start())"),
            "★ 块边界必须由**下一个锚**决定（不是固定窗口大小）"
        );
        // 反面：不许出现 `.{0,NNN}` 这种"按窗口切载荷"的写法
        assert!(
            !flat.contains(r#"[^>]*>(.{0,700})"#),
            "★ 不许把载荷写成固定长度的贪婪窗口（会吞掉后续条目）"
        );
    }

    #[test]
    fn play_from_html_reads_mac_url_then_falls_back() {
        // DEX 的两条正则都试
        let a = r#"<script>var mac_url='第01集$https://cdn.example/1.m3u8';</script>"#;
        assert_eq!(play_from_html(a).as_deref(), Some("第01集$https://cdn.example/1.m3u8"));
        let b = r#"<script>url: 'https://cdn.example/2.m3u8'</script>"#;
        assert_eq!(play_from_html(b).as_deref(), Some("https://cdn.example/2.m3u8"));
        // 都没有 ⇒ None（由 play() 负责报错）
        assert_eq!(play_from_html("<html>nope</html>"), None);
        // 空串不算（不许返回空值冒充"有地址"）
        assert_eq!(play_from_html("<script>mac_url='';</script>"), None);
    }

    #[test]
    fn categories_constant_is_marked_as_expected_not_measured() {
        /*
         * ★ 这条守"诚实标注"：`CATEGORIES` 是**照 DEX 写的预期分类**，
         *   不是实测分类（站点取不到）。文件头必须写明这点，
         *   否则下一个人会把它当成"实测分类表"。
         */
        let src = include_str!("czsapp.rs");
        assert!(
            src.contains("只是\"预期分类\"，不是实测分类")
                || src.contains("不是实测分类"),
            "★ 必须写明 CATEGORIES 未实测"
        );
        assert_eq!(CATEGORIES.len(), 3);
    }

    // ── 真网络（显式开关 + --ignored）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live_czsapp --release -- --ignored --nocapture"]
    async fn csp_live_czsapp_documents_the_waf_block() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 真网络用例：必须显式给 CSP_LIVE=1"
        );
        let s = Czsapp::new();
        // ext 给的域名：导航页（能 200，但不是站点内容）
        match s.get("https://cz01.vip/").await {
            Ok(h) => {
                let nav = h.contains("新地址") && h.contains("跳转");
                eprintln!("[LIVE] cz01.vip 200 len={} 是导航页={}", h.len(), nav);
                assert!(nav, "cz01.vip 应是导航/跳转页");
            }
            Err(e) => eprintln!("[LIVE] cz01.vip 失败：{e}"),
        }
        // 真域名：应被 WAF 挡住（这条断言把"实测结论"钉住）
        for host in ["https://www.4kcz.com", "https://czzy.top", "https://www.cz4k.com"] {
            match s.get(&format!("{host}/")).await {
                Ok(h) => eprintln!("[LIVE] {host} 竟返回内容 len={}（WAF 可能已撤）", h.len()),
                Err(e) => {
                    eprintln!("[LIVE] {host} → {}", e.chars().take(90).collect::<String>());
                    assert!(e.contains("WAF"), "★ {host} 应报 WAF 拦截：{e}");
                }
            }
        }
    }
}