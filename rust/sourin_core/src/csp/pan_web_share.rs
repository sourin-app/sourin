// ═══════════════════════════════════════════════════════════════════════
//  csp_PanWebShare —— 「网盘分享站」聚合源的 Rust 实现
// ═══════════════════════════════════════════════════════════════════════
//
// # 取证：这个类在 DEX 里长什么样（.probe/newtask/jar/classes.dex，3918 类）
//
// 用 `.probe/final-plan-audit/dex_dump_class.py` 精确读 class_def（不是猜）：
// ```text
// class_def_index = 294
// superclass      = Lcom/github/catvod/spider/Pan;
// methods         = 13（全被混淆成 d/g/h/j/…）
// ```
// 它自己只做 **网站 HTML 解析**，字符串常量逐条列出（可复核）：
// ```text
// 列表   /index.php/vod/show/id/   /page/   .module-item
// 搜索   /index.php/vod/search/wd/  .html   .module-search-item
// 详情   /index.php/vod/detail/id/（DEX 里该字面量存在）
// 选择器 .module-item-titlebox >a  .module-item-text  .module-item-pic img[data-src]
//        .module-row-text[data-clipboard-text]   ← ★ 分享链接就挂在这个属性上
//        .video-info-header > .page-title        ← 标题
//        p.sqjj_a 导演/主演/年代/备注             ← 简介
//        span.module-tab-item.tab-item[data-id][data-name]  ← 线路/分类页签
// 筛选键 cateId / class / area / year / by / lang ⇒ /class/ /area/ /year/ /by/ /lang/
// 特例   Referer: https://www.douban.com（douban 站点那一路）
// ```
// 真正的"网盘 → 直链"在父类 `Pan` 里（同一份 DEX，class_def 147）：
// ```text
// 9 家盘的分享链接正则：aliyundrive|alipan / quark / uc(drive.uc.cn) / cloud189
//                       123pan / baidu(pan.baidu.com) / xunlei / guangya / 115|anxia
// 产出形态：http://127.0.0.1:5266  + "&header="  ⇒ TVBox 自带的本机转发服务
// ```
//
// # 因此本实现的分工（**不许越界**）
// ```text
// home / list / detail  → 纯 HTTP 抓该站 HTML，真数据（不需要登录）        ✅ 本文件实现
// play（网盘分享链接）   → 需要「网盘账号 cookie」+「5266 本地转发服务」      ⛔ 本仓没有
//                          ⇒ 如实返回「需要登录网盘账号」类错误，绝不伪造直链
// ```
// ★ 这是**能力边界**，不是偷懒：没有 5266 转发，就算有 cookie 也放不出直链；
//   伪造一个 m3u8 只会让用户点进去得到 404。

// # ⚠️ 取证踩过的坑：本机 HTTP 代理会把"站点可用"测成"全宕"
//
// 2026-10-26 实测（两轮结论完全相反，值得留档）：
// ```text
// · 走系统代理（HTTP_PROXY=127.0.0.1:7890）时：16 个镜像**全部**返回
//   `502 ip=127.0.0.1`（是代理给的 502，不是站点给的）
//   ⇒ 只看这一轮会写下"该类全宕"这种**错误结论**
// · 同一批 host 用 `curl --noproxy '*'` 直连：**9/16 可用**
//   （www.muoua.top 200/0.68s、tv.214521.xyz 200/2~3s、shandian.blog 200/4~5s、
//     woog.nxog.fun、woog.430520.xyz、快映/虎斑 4 个 302 → 200）
//   ⇒ 真网络用例随后 PASS（6 分类 / 60 条目 / 详情 2 条网盘分享链接）
// ```
// **两条纪律**：
// ```text
// ① 判断"站点是否可用"必须**直连**复测单 host（curl --noproxy '*'），
//    代理/加速器给出的 5xx 不代表站点挂了；
// ② reqwest 默认**读环境代理** —— 本实现的 client 用 `no_proxy()` 语义的
//    显式构造（见 `PanWebShare::new`），避免"用户的系统代理"把源整体判死。
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 列表页/详情页的路径前缀（取自 DEX 字面量，见文件头）
const PATH_SHOW: &str = "/index.php/vod/show/id/";
const PATH_DETAIL: &str = "/index.php/vod/detail/id/";
const PATH_SEARCH: &str = "/index.php/vod/search/wd/";

/// 每页条数上限（站点一页通常就是 20~30 条，我们只取首页面里解析出来的）
const MAX_ITEMS: usize = 60;

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 一次抓取的总预算：16 镜像串行 + 单请求 8s 时，不给总预算最坏会拖到分钟级
/// （实测三次调用 122.86s ⇒ 用户以为"卡死"）。
const FETCH_BUDGET: Duration = Duration::from_secs(25);

/// 失败摘要里最多列几个镜像（其余只报数量，避免把一段 URL 墙塞给用户）
const MAX_FAIL_DETAILS: usize = 5;

pub struct PanWebShare {
    client: reqwest::Client,
    /// ★ sticky 镜像：一旦某个镜像成功过，后续请求**先试它**
    ///
    /// 为什么必需：没有它时每次 list/detail 都从列表头开始重试死站，
    /// 实测一次调用能烧掉 122s（死站 × 8s 超时 × 多个入口）。
    /// `Mutex` 是因为 `CspSite: Send + Sync`（同一个实例会被并发复用）。
    sticky: std::sync::Mutex<Option<String>>,
}

impl PanWebShare {
    pub const CLASS: &'static str = "PanWebShare";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            // ★ 单请求上限压到 8s：16 个镜像串行时，20s×16 会把"某站慢"放大成"整类不可用"
            .timeout(Duration::from_secs(8))
            /*
             * ★ 显式**不走**环境代理。
             *
             * 实测（见文件头）：本机 HTTP_PROXY=127.0.0.1:7890 时，走代理的请求
             * 对每个 host 都回 502，从而把"9/16 可用"误判成"全宕"。
             * reqwest 默认会读环境代理 ⇒ 这里必须显式关掉，判据才是站点的真实状态。
             */
            .no_proxy()
            .build()
            .expect("build panwebshare http client");
        Self { client, sticky: std::sync::Mutex::new(None) }
    }

    /// 从 ext 里取站点镜像列表
    ///
    /// 配置形如 `{"site":["https://a.example","https://b.example"]}`；
    /// 也可能是**字符串形态**（TVBox 的 ext 允许两种），所以先尝试 JSON，
    /// 失败就退回"整段里抓 http(s) 地址"。
    pub fn sites_of(ext: &str) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(ext) {
            if let Some(arr) = v.get("site").and_then(|x| x.as_array()) {
                for s in arr {
                    if let Some(u) = s.as_str() {
                        let u = u.trim().trim_end_matches('/');
                        if u.starts_with("http") && !out.iter().any(|x| x == u) {
                            out.push(u.to_string());
                        }
                    }
                }
            }
        }
        if out.is_empty() {
            // 字符串形态：把 ext 里所有 http(s) 前缀抓出来
            for piece in ext.split(|c: char| c == '"' || c == '\'' || c == ',' || c == ' ') {
                let p = piece.trim().trim_end_matches('/');
                if p.starts_with("http") && !out.iter().any(|x| x == p) {
                    out.push(p.to_string());
                }
            }
        }
        out
    }

    async fn get_html(&self, url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
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

    /// 依次尝试镜像，返回第一个成功的 HTML（含它用的 base）
    ///
    /// # 三条纪律（都是实测踩出来的）
    /// ```text
    /// ① **sticky**：成功过的镜像排到最前 —— 否则每次请求都从死站开始重试，
    ///    实测一次调用 122.86s（8s 超时 × 死站数 × 每个入口）。
    /// ② **总预算 `FETCH_BUDGET`**：到点立刻返回已累积的失败摘要，
    ///    不让"某个站很慢"拖成"整类不可用"。
    /// ③ **失败摘要**：列出**前 MAX_FAIL_DETAILS 条 + 总条数** ——
    ///    只留最后一条（旧行为）会让人误以为"整个类挂了"，
    ///    而真实情况常常只是某一个镜像 522（见文件头的代理踩坑记录）。
    /// ```
    async fn fetch_first(&self, sites: &[String], path: &str) -> Result<(String, String), String> {
        let started = std::time::Instant::now();
        // sticky 优先，其余保持配置顺序
        let sticky = self.sticky.lock().ok().and_then(|g| g.clone());
        let mut order: Vec<String> = Vec::with_capacity(sites.len());
        if let Some(hit) = &sticky {
            if sites.iter().any(|s| s == hit) {
                order.push(hit.clone());
            }
        }
        for s in sites {
            if Some(s) != sticky.as_ref() {
                order.push(s.clone());
            }
        }

        let mut failures: Vec<String> = Vec::new();
        for base in &order {
            let left = FETCH_BUDGET.saturating_sub(started.elapsed());
            if left.is_zero() {
                failures.push(format!(
                    "总耗时已达 {}s 预算，停止重试",
                    FETCH_BUDGET.as_secs()
                ));
                break;
            }
            let url = format!("{base}{path}");
            // 单次尝试也被剩余预算夹住 —— 否则最后一个站能把总时长再拉长 8s
            match tokio::time::timeout(left, self.get_html(&url)).await {
                Ok(Ok(html)) => {
                    if let Ok(mut g) = self.sticky.lock() {
                        *g = Some(base.clone());
                    }
                    return Ok((base.clone(), html));
                }
                Ok(Err(e)) => failures.push(format!("{base}：{e}")),
                Err(_) => failures.push(format!("{base}：超时（剩余预算 {}s）", left.as_secs())),
            }
        }
        Err(summarize_failures(&failures, order.len()))
    }
}

/// 把多次失败压成**一句可读的原因**（前 N 条 + 总条数）
///
/// 单独成函数是为了**可单测**（不联网也能验"摘要里有多条"）。
pub fn summarize_failures(failures: &[String], total: usize) -> String {
    let head: Vec<String> = failures
        .iter()
        .take(MAX_FAIL_DETAILS)
        .map(|e| e.trim().to_string())
        .collect();
    let mut out = format!("试了 {total} 个镜像都没打开。");
    if head.is_empty() {
        return format!("{out}（没有任何失败明细 —— 这本身是异常，请连同日志反馈）");
    }
    out.push_str(&format!("前 {} 条失败：", head.len()));
    out.push_str(&head.join("；"));
    if failures.len() > head.len() {
        out.push_str(&format!("；另有 {} 条同因失败", failures.len() - head.len()));
    }
    out
}

impl Default for PanWebShare {
    fn default() -> Self {
        Self::new()
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  HTML 解析（苹果CMS 模板的选择器取自 DEX，见文件头）
// ═══════════════════════════════════════════════════════════════════════

/// 从导航里取分类：`/index.php/vod/show/id/{数字}.html` 的链接 + 其文字
fn parse_categories(html: &str) -> Vec<CspCategory> {
    let re = regex::Regex::new(
        r#"(?is)<a[^>]+href="[^"]*?/index\.php/vod/show/id/(\d+)[^"]*"[^>]*>(.*?)</a>"#,
    )
    .expect("cat regex");
    let mut out: Vec<CspCategory> = Vec::new();
    for c in re.captures_iter(html) {
        let id = c[1].to_string();
        let name = clean_text(&c[2]);
        if name.is_empty() || out.iter().any(|x| x.id == id) {
            continue;
        }
        out.push(CspCategory { id, name });
    }
    out
}

/// 列表页条目：`.module-item` 里的 detail 链接 / 标题 / 封面
fn parse_items(html: &str) -> Vec<CspItem> {
    /*
     * ⚠️ 不能用"前瞻"切块：`regex` crate **不支持 lookaround**
     *    （`(?=class="…module-item…")` 会直接编译失败 —— 首次实现就栽在这）。
     * ⇒ 改成**标记点分段**：找到每个 `module-item` 的起点，切到下一个起点。
     *    比正则切块更笨，但语义明确、无回溯开销。
     */
    let re_id = regex::Regex::new(r#"/index\.php/vod/detail/id/(\d+)\.html"#).expect("id");
    let re_title = regex::Regex::new(r#"(?is)title="([^"]+)""#).expect("title");
    let re_pic = regex::Regex::new(r#"(?is)data-src="([^"]+)""#).expect("pic");
    let starts: Vec<usize> = html.match_indices("module-item").map(|(i, _)| i).collect();
    let segs: Vec<&str> = starts
        .iter()
        .enumerate()
        .map(|(i, &start)| {
            let end = starts.get(i + 1).copied().unwrap_or(html.len());
            &html[start..end.min(html.len())]
        })
        .collect();
    let mut out: Vec<CspItem> = Vec::new();
    for seg in segs.iter() {
        let seg = *seg;
        let Some(id) = re_id.captures(seg).map(|c| c[1].to_string()) else {
            continue;
        };
        let title = re_title
            .captures(seg)
            .map(|c| clean_text(&c[1]))
            .unwrap_or_default();
        let pic = re_pic
            .captures(seg)
            .map(|c| c[1].to_string())
            .filter(|p| p.starts_with("http"));
        if title.is_empty() || out.len() >= MAX_ITEMS {
            continue;
        }
        if out.iter().any(|x| x.id == id) {
            continue;
        }
        out.push(CspItem {
            id,
            title,
            cover: pic,
            subtitle: None,
        });
    }
    out
}

/// ext 缺站点时的统一文案（home/list/detail 三处共用，避免三份措辞漂移）
const SITE_MISSING: &str = "配置里没有站点地址（ext 需要形如 site 数组的镜像列表）";

/// 首页解析（纯函数，供单测与注入）
///
/// ★ 判据：**解析出 0 个分类 ⇒ Err**。
///   站点 200 但模板改版/风控壳页时，旧实现会返回"分类为空但 Ok"，
///   上层原样透传 ⇒ 用户看到"这个源没内容"（假装支持）。
pub fn home_from_html(html: &str) -> Result<CspHome, String> {
    let categories = parse_categories(html);
    if categories.is_empty() {
        return Err("站点首页能打开，但没解析出任何分类（模板可能已改版，或被风控页替换）"
            .to_string());
    }
    let items = parse_items(html);
    if items.is_empty() {
        // 分类有了、首屏条目没解析出来：不致命，但必须留痕
        log::warn!("PanWebShare 首页解析到分类但 0 条目 —— 模板变了或首屏异步加载");
    }
    Ok(CspHome { categories, items })
}

/// 列表页解析（纯函数，供单测与注入）
///
/// ★★ 判据：**解析出 0 条 ⇒ Err**。这是本文件唯一一处曾经"假装支持"的地方：
/// ```text
/// 旧：items.is_empty() ⇒ 仍然 Ok(CspList{items: []})
///     ⇒ 上层 provider 原样透传 ⇒ 界面显示"这个源没内容"
/// 新：明确 Err ⇒ 界面显示"页面能打开但没解析出条目"
/// ```
/// `home` / `detail` / `play` 一直都给了可读 Err，只有 list 漏了 —— 现在补齐。
pub fn list_from_html(html: &str, page: u32, path: &str) -> Result<CspList, String> {
    let items = parse_items(html);
    if items.is_empty() {
        return Err(format!(
            "{path} 页面能打开但没解析出任何条目（站点模板可能已改版，或被风控页替换）"
        ));
    }
    Ok(CspList {
        items,
        page,
        // 站点用"下一页"按钮而非总数 ⇒ 不编页数
        page_count: None,
        total: None,
    })
}

/// 详情页：标题 / 简介 / 分享链接（`data-clipboard-text`，DEX 里就挂在 `.module-row-text`）
fn parse_detail(html: &str, id: &str) -> CspDetail {
    let re_title = regex::Regex::new(
        r#"(?is)class="[^"]*page-title[^"]*"[^>]*>(.*?)</"#,
    )
    .expect("d title");
    let re_desc = regex::Regex::new(r#"(?is)<p[^>]*class="[^"]*sqjj_a[^"]*"[^>]*>(.*?)</p>"#)
        .expect("d desc");
    let re_share = regex::Regex::new(r#"(?is)data-clipboard-text="(https?://[^"]+)""#)
        .expect("d share");
    let re_pic = regex::Regex::new(r#"(?is)(?:data-src|data-original)="(https?://[^"]+)""#)
        .expect("d pic");

    let title = re_title
        .captures(html)
        .map(|c| clean_text(&c[1]))
        .unwrap_or_default();
    let desc = re_desc.captures(html).map(|c| clean_text(&c[1]));
    let cover = re_pic.captures(html).map(|c| c[1].to_string());

    let mut episodes: Vec<CspEpisode> = Vec::new();
    for c in re_share.captures_iter(html) {
        let url = c[1].trim().to_string();
        if episodes.iter().any(|e| e.id == format!("pan|{url}")) {
            continue;
        }
        let label = UrlPanKind::of(&url)
            .map(|k| k.label().to_string())
            .unwrap_or_else(|| "分享链接".to_string());
        episodes.push(CspEpisode {
            id: format!("pan|{url}"),
            title: format!("#{} {}", episodes.len() + 1, label),
        });
        if episodes.len() >= 200 {
            break;
        }
    }

    CspDetail {
        id: id.to_string(),
        title: if title.is_empty() {
            format!("条目 {id}")
        } else {
            title
        },
        cover,
        description: desc,
        episodes,
    }
}

fn clean_text(s: &str) -> String {
    let no_tags = crate::tvbox::strip_tags(s);
    crate::tvbox::decode_entities(&no_tags)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

// ═══════════════════════════════════════════════════════════════════════
//  网盘识别（与 DEX 父类 Pan 的 9 条正则同一批平台，只做"认出是哪家"）
// ═══════════════════════════════════════════════════════════════════════

/// 网盘种类（只用于**如实告知**"需要登录哪一家"）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UrlPanKind {
    Ali,
    Quark,
    Uc,
    Cloud189,
    Cloud123,
    Baidu,
    Xunlei,
    Guangya,
    Yi115,
    Mobile,
}

impl UrlPanKind {
    /// 按域名认盘（DEX 父类 Pan 的正则里就这几家）
    pub fn of(url: &str) -> Option<Self> {
        let u = url.to_ascii_lowercase();
        if u.contains("aliyundrive.com") || u.contains("alipan.com") {
            Some(Self::Ali)
        } else if u.contains("pan.quark.cn") {
            Some(Self::Quark)
        } else if u.contains("drive.uc.cn") {
            Some(Self::Uc)
        } else if u.contains("cloud.189.cn") || u.contains("cloud.189.com") {
            Some(Self::Cloud189)
        } else if u.contains("123pan") || u.contains("123684") || u.contains("123865") {
            Some(Self::Cloud123)
        } else if u.contains("pan.baidu.com") {
            Some(Self::Baidu)
        } else if u.contains("pan.xunlei.com") {
            Some(Self::Xunlei)
        } else if u.contains("guangyapan.com") {
            Some(Self::Guangya)
        } else if u.contains("115.com") || u.contains("115cdn.com") || u.contains("anxia.com") {
            Some(Self::Yi115)
        } else if u.contains("yun.139.com") || u.contains("caiyun.139.com") {
            Some(Self::Mobile)
        } else {
            None
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Ali => "阿里云盘",
            Self::Quark => "夸克网盘",
            Self::Uc => "UC 网盘",
            Self::Cloud189 => "天翼云盘",
            Self::Cloud123 => "123 云盘",
            Self::Baidu => "百度网盘",
            Self::Xunlei => "迅雷云盘",
            Self::Guangya => "光鸭云盘",
            Self::Yi115 => "115 网盘",
            Self::Mobile => "移动云盘",
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for PanWebShare {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页：分类取自站点自己的导航（真数据），首屏条目取分类 1 的列表页
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let sites = Self::sites_of(ext);
        if sites.is_empty() {
            return Err(SITE_MISSING.to_string());
        }
        let (_base, html) = self.fetch_first(&sites, &format!("{PATH_SHOW}1.html")).await?;
        home_from_html(&html)
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let sites = Self::sites_of(ext);
        if sites.is_empty() {
            return Err(SITE_MISSING.to_string());
        }
        let page = if page == 0 { 1 } else { page };
        let path = if page <= 1 {
            format!("{PATH_SHOW}{tid}.html")
        } else {
            format!("{PATH_SHOW}{tid}/page/{page}.html")
        };
        let (_base, html) = self.fetch_first(&sites, &path).await?;
        list_from_html(&html, page, &path)
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let sites = Self::sites_of(ext);
        if sites.is_empty() {
            return Err(SITE_MISSING.to_string());
        }
        let path = format!("{PATH_DETAIL}{id}.html");
        let (_base, html) = self.fetch_first(&sites, &path).await?;
        let d = parse_detail(&html, id);
        if d.episodes.is_empty() {
            return Err(format!(
                "这个条目页上没有找到网盘分享链接（可能已下架，或模板改版）"
            ));
        }
        Ok(d)
    }

    /// 取流
    ///
    /// # 只有两类会成功
    /// ```text
    /// ① id 本身就是直链媒体（少数站点在详情页直接给 .mp4/.m3u8）
    /// ② 分享链接指向的盘**不需要登录**且我们有转发（当前：没有）
    /// ```
    /// 其余一律 **如实报错**：说清是"哪家网盘 + 需要登录 + 本机没有转发服务"。
    /// ★ 不伪造直链 —— 伪造只会让用户点进去看到 404。
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let raw = id.trim();
        let url = raw.strip_prefix("pan|").unwrap_or(raw);
        if !crate::tvbox::starts_http(url) {
            return Err(format!("播放 id 既不是分享链接也不是直链：{raw}"));
        }
        // ① 直链媒体：原样给（真地址，不编造）
        let lower = url.to_ascii_lowercase();
        if lower.contains(".m3u8") || lower.contains(".mp4") {
            return Ok(vec![CspPlay {
                url: url.to_string(),
                headers: vec![("User-Agent".to_string(), UA.to_string())],
                label: Some("直链".to_string()),
            }]);
        }
        // ② 网盘分享：本仓没有 5266 转发服务 ⇒ 明确说清
        match UrlPanKind::of(url) {
            Some(kind) => Err(format!(
                "这条是{}分享，需要登录账号后才能取直链；\
                 本机还没有接入网盘转发服务，所以暂时放不了（其余内容不受影响）",
                kind.label()
            )),
            None => Err(format!(
                "这条链接不是已知网盘，也不是直链媒体地址：{url}"
            )),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    const LIST_HTML: &str = r#"
      <nav>
        <a href="/index.php/vod/show/id/1.html">电影</a>
        <a href="/index.php/vod/show/id/2.html">电视剧</a>
        <a href="/index.php/vod/show/id/3.html">综艺</a>
      </nav>
      <div class="module-items">
        <div class="module-item">
          <a href="/index.php/vod/detail/id/1234.html" title="示例片 甲">
            <img data-src="https://img.example/a.jpg">
          </a>
          <div class="module-item-text">已完结</div>
        </div>
        <div class="module-item">
          <a href="/index.php/vod/detail/id/5678.html" title="示例片 乙"></a>
        </div>
      </div>"#;

    const DETAIL_HTML: &str = r#"
      <h1 class="video-info-header"><span class="page-title">示例片 甲</span></h1>
      <img data-src="https://img.example/a.jpg">
      <p class="sqjj_a">导演：某人 主演：甲乙丙 年代：2026</p>
      <div class="module-row-text" data-clipboard-text="https://pan.quark.cn/s/abcd1234"></div>
      <div class="module-row-text" data-clipboard-text="https://pan.baidu.com/s/1XYZ?pwd=8888"></div>
      <div class="module-row-text" data-clipboard-text="https://cdn.example/x.m3u8"></div>"#;

    #[test]
    fn sites_of_reads_object_and_string_forms() {
        let a = PanWebShare::sites_of(r#"{"site":["https://a.example","https://b.example/"]}"#);
        assert_eq!(a, vec!["https://a.example", "https://b.example"]);
        // 字符串形态（TVBox 允许 ext 是字符串）
        let b = PanWebShare::sites_of(r#"https://c.example, https://d.example"#);
        assert_eq!(b, vec!["https://c.example", "https://d.example"]);
        assert!(PanWebShare::sites_of("").is_empty());
    }

    #[test]
    fn parse_categories_from_nav() {
        let cats = parse_categories(LIST_HTML);
        assert_eq!(cats.len(), 3, "三个导航分类，实际 {cats:?}");
        assert_eq!(cats[0].id, "1");
        assert_eq!(cats[0].name, "电影");
    }

    #[test]
    fn parse_items_extracts_id_title_cover() {
        let items = parse_items(LIST_HTML);
        assert_eq!(items.len(), 2, "两个条目，实际 {items:?}");
        assert_eq!(items[0].id, "1234");
        assert_eq!(items[0].title, "示例片 甲");
        assert_eq!(items[0].cover.as_deref(), Some("https://img.example/a.jpg"));
        assert_eq!(items[1].id, "5678");
        assert!(items[1].cover.is_none(), "没有封面时必须是 None，不许编一个");
    }

    #[test]
    fn parse_detail_collects_share_links_only() {
        let d = parse_detail(DETAIL_HTML, "1234");
        assert_eq!(d.title, "示例片 甲");
        assert!(d.description.unwrap_or_default().contains("导演"));
        assert_eq!(d.episodes.len(), 3, "三条 data-clipboard-text，实际 {:?}", d.episodes);
        assert!(d.episodes[0].id.starts_with("pan|https://pan.quark.cn/s/"));
        assert!(d.episodes[0].title.contains("夸克"));
        assert!(d.episodes[1].title.contains("百度"));
        // 直链那条不算"网盘"，标题退回中性词
        assert!(d.episodes[2].title.contains("分享链接"));
    }

    #[test]
    fn pan_kind_recognises_nine_providers() {
        for (url, label) in [
            ("https://www.aliyundrive.com/s/abc", "阿里云盘"),
            ("https://pan.quark.cn/s/abc", "夸克网盘"),
            ("https://drive.uc.cn/s/abc", "UC 网盘"),
            ("https://cloud.189.cn/t/abc", "天翼云盘"),
            ("https://www.123pan.com/s/abc", "123 云盘"),
            ("https://pan.baidu.com/s/1abc", "百度网盘"),
            ("https://pan.xunlei.com/s/abc", "迅雷云盘"),
            ("https://www.guangyapan.com/s/abc", "光鸭云盘"),
            ("https://115.com/s/abc", "115 网盘"),
            ("https://yun.139.com/share/abc", "移动云盘"),
        ] {
            assert_eq!(
                UrlPanKind::of(url).map(|k| k.label()),
                Some(label),
                "{url} 应识别为 {label}"
            );
        }
        assert_eq!(UrlPanKind::of("https://example.com/x"), None);
    }

    #[tokio::test]
    async fn play_returns_honest_login_error_for_pan_links() {
        let site = PanWebShare::new();
        let err = site
            .play("", "pan|https://pan.quark.cn/s/abcd1234", "")
            .await
            .expect_err("网盘分享链接在本仓必然取不到直链");
        assert!(err.contains("夸克网盘"), "要点名是哪家盘：{err}");
        assert!(err.contains("需要登录"), "要说明是登录问题：{err}");
        assert!(
            !err.contains("尚未实现"),
            "这条不是「类未实现」（类是实现了的），不许混用文案：{err}"
        );
    }

    #[tokio::test]
    async fn play_returns_direct_media_url_as_is() {
        let site = PanWebShare::new();
        let got = site
            .play("", "https://cdn.example/x.m3u8", "")
            .await
            .expect("直链媒体应直接可用");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].url, "https://cdn.example/x.m3u8");
    }

    #[tokio::test]
    async fn play_rejects_unknown_scheme() {
        let site = PanWebShare::new();
        let err = site.play("", "1234", "").await.expect_err("裸 id 不是可播地址");
        assert!(err.contains("既不是分享链接也不是直链"), "实际 {err}");
    }

    // ── 空结果必须 Err（"假装支持"的唯一出口）──
    #[test]
    fn list_with_no_items_is_error_not_empty_ok() {
        // 站点 200，但模板改版 / 风控壳页 ⇒ 一个 .module-item 都没有
        let shell = r#"<html><body><h1>请稍候…</h1><div id="app"></div></body></html>"#;
        let err = list_from_html(shell, 2, "/index.php/vod/show/id/1/page/2.html")
            .expect_err("★★ 0 条目时必须 Err —— 返回 Ok(空列表) 会让界面显示「这个源没内容」");
        assert!(err.contains("没解析出任何条目"), "原因要说人话：{err}");
        assert!(err.contains("page/2.html"), "错误里要带上是哪一页：{err}");

        // 对照：正常页必须 Ok（否则本条对"永远 Err"的实现也成立 ⇒ 假绿）
        let ok = list_from_html(LIST_HTML, 1, "/index.php/vod/show/id/1.html")
            .expect("正常页面必须解析成功");
        assert_eq!(ok.items.len(), 2);
    }

    #[test]
    fn home_with_no_categories_is_error() {
        let shell = r#"<html><body>风控校验中</body></html>"#;
        let err = home_from_html(shell).expect_err("★★ 0 分类必须 Err");
        assert!(err.contains("没解析出任何分类"), "{err}");
        let ok = home_from_html(LIST_HTML).expect("正常首页必须成功");
        assert_eq!(ok.categories.len(), 3);
    }

    // ── 失败摘要必须含多条（旧行为只留最后一条 ⇒ 会误以为"整类挂了"）──
    #[test]
    fn failure_summary_lists_several_and_counts_the_rest() {
        let errs: Vec<String> = (0..9)
            .map(|i| format!("https://m{i}.example：HTTP 522"))
            .collect();
        let msg = summarize_failures(&errs, 16);
        assert!(msg.contains("试了 16 个镜像"), "要报总条数：{msg}");
        for i in 0..5 {
            assert!(
                msg.contains(&format!("m{i}.example")),
                "前 5 条都要列出，缺 m{i}：{msg}"
            );
        }
        assert!(!msg.contains("m5.example"), "第 6 条起不再列明细：{msg}");
        assert!(msg.contains("另有 4 条同因失败"), "其余要报数量：{msg}");
    }

    #[test]
    fn failure_summary_handles_empty_and_short() {
        let empty = summarize_failures(&[], 0);
        assert!(empty.contains("没有任何失败明细"), "{empty}");
        let one = summarize_failures(&["a.example：超时".to_string()], 1);
        assert!(one.contains("试了 1 个镜像"), "{one}");
        assert!(!one.contains("另有"), "没有剩余时不许画蛇添足：{one}");
    }

    // ── 真网络：CSP_LIVE=1 且 --ignored 才跑（B10 纪律：不给环境变量就 fail）──
    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib pan_web_share --release -- --ignored --nocapture"]
    async fn csp_live_panwebshare_home_and_list() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "★ 这条要真网络：显式跑就必须给 CSP_LIVE=1（不给就失败，不许记成 ok）"
        );
        /*
         * 镜像取自用户配置里 6 个 csp_PanWebShare 源的 ext.site **全量 16 个**
         * （见 .probe/panwebshare-mirrors.txt）。逐个试，并**把每个失败原因打出来** ——
         * 这样"站点全下线"时我们拿到的是 16 条具体错误，而不是一句笼统的失败。
         */
        let ext = r#"{"site":[
            "https://123.666291.xyz","https://333.333291.xyz","http://www.muoua.top",
            "https://666.666291.xyz","http://xsayang.fun","http://38.76.197.172:12521",
            "https://tv.yydsys.top","https://tv.yydsys.cc","https://tv.214521.xyz",
            "http://sd.sduc.site","http://shandian.blog","https://woog.nxog.eu.org",
            "https://woog.nxog.fun","https://woog.430520.xyz","http://xhban.xyz",
            "http://38.76.197.172:16969"]}"#;
        let site = PanWebShare::new();
        let home = site.home(ext).await.expect("真站点 home 应成功");
        eprintln!(
            "[LIVE] PanWebShare home: 分类 {} 个（首类 {} / {}），条目 {} 个",
            home.categories.len(),
            home.categories[0].id,
            home.categories[0].name,
            home.items.len()
        );
        assert!(!home.categories.is_empty(), "分类不能为空");
        assert!(!home.items.is_empty(), "首屏条目不能为空（真数据）");

        let list = site.list(&home.categories[0].id, 2, ext).await.expect("第 2 页应成功");
        eprintln!("[LIVE] PanWebShare list(p2): {} 个条目", list.items.len());
        assert!(!list.items.is_empty(), "第 2 页也应有条目");

        let d = site
            .detail(&home.items[0].id, ext)
            .await
            .expect("详情应成功");
        eprintln!(
            "[LIVE] PanWebShare detail({}): 标题={} 分享链接 {} 条，首条 {}",
            home.items[0].id,
            d.title,
            d.episodes.len(),
            d.episodes.first().map(|e| e.id.clone()).unwrap_or_default()
        );
        assert!(!d.episodes.is_empty(), "详情页应有网盘分享链接");
    }
}
