// ═══════════════════════════════════════════════════════════════════════
//  csp_XBPQ —— 「配置驱动的通用抓取器」的 Rust 重写（**本批注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类是什么
// ```text
// 它不是"某个站的 spider"，而是**一整套由 ext 配置驱动的抓取引擎**：
//   ext = 一个配置 URL（或内联 JSON 文本）→ 配置里写「分类url」「数组」「标题」
//   「图片」「链接」「播放数组」「播放链接」… → 引擎按这些标记去抓/切/拼。
// 所以它没有写死的站点：同一个类配 10 份配置就是 10 个源（订阅里正是这样用的）。
// ```
//
// # 参考（DEX 逐字，`.probe/csp-parity/XBPQ.txt`，51900 B；581 个字符串）
// ```text
// 类：com.github.catvod.spider.XBPQ（class_def #346）
//   · 同批还有 XBPQ$1…$7、XBPQPlay、XBPQa/b/c 几个类 —— 逐类看常量：
//     $1/$2 只有 "$$$"（内部 lambda）；$4 是「key=value」串的 toString（`=.*?;`）；
//     XBPQPlay 只有播放相关的短常量；XBPQa/b/c 各 3 条（枚举/内部状态）。
//     ⇒ **它们是 XBPQ 的内部实现**，订阅里也只暴露 `csp_XBPQ` 一个类 ⇒ 本文件只交付 XBPQ，
//       变体不单独注册。
//   · 配置键（逐字）：首页 / 数组 / 图片 / 副标题 / 标题 / 链接 / 链接前缀 / 播放数组 /
//     播放列表 / 播放标题 / 播放链接 / 分类url / 分类 / 类型 / 编码 / 请求头
//   · 取值方言（DEX 里的例子就是证据）：
//       `A&&B`     前标记 A、后标记 B（例：`<div&&</div>`、`src="&&"`）
//       `P+A&&B`   结果 = P + 中间文本（例：`https://www.aliyundrive.com/s/+aliyundrive.com/s/&&"`）
//       `A*B`      前标记里 `*` 是通配（例：`<a*href="&&"`）
//       `[包含:x]` 结果必须含 x（例：`<a*href="&&"[包含:http]`）
//   · 另有 `二次截取` / `jiequqian` 等「先截整页再截条目」的键与 `/@title` 形态的 JSONPath
//     选择器 —— 本实现**只落地上面两套**（订阅里两份配置只用这两套），其余键读到也不认，
//     并在解析不出条目时如实报「本实现不支持的配置键」。
// ```
//
// # ★ 2026-10-28 真网读数（两份订阅配置，逐条给状态与 body 证据）
// ```text
// 配置①（影视站，只有 5 个键：请求头/编码/分类/类型/分类url）
//   ★ 判「源站不可用」前，按本仓纪律**复刻六项**逐项试过（不是只看一次状态码）：
//     路径  `/` · `/index.php` · `/vodshow/1--------1---.html`（配置自己拼出来的那条）
//     方法  GET（站点是普通页面，无 POST 入口）
//     编码  无（body 只有 16 字节，不存在编码问题）
//     头    `Accept: */*` + 桌面 UA 与 `MOBILE_UA` 两种
//     URL   `https://www.` / `https://`(apex) / `http://www.`
//     代理  `curl --noproxy '*'`（**不读系统代理** —— 否则 000 会被误读成"站死"）
//   读数：`http://www.` → **523**（body 16 B「error code: 523」）；https 侧在 522/523/000 之间摆动
//   （000 = TLS/连接层失败，同一时刻 http 仍回 523）⇒ **源站不可用**（Cloudflare 523：回源挂）
//   ⚠️ 该配置**没有** 数组/标题/链接 等选择器 ⇒ 即使站活着，也需要 XBPQ 的**内置默认选择器**；
//     DEX 常量里没有任何 maccms 选择器（只有配置键）⇒ 本实现不做猜测，直接给它可读 Err。
// 配置②（栏目站，完整选择器）
//   $ curl --noproxy '*' 'https://pc.api.btime.com/btimeweb/infoFlow?…&list_id=…_2026&refresh=1…'
//     → 200 · 103091 B · JSONP（callback 包裹的 data.list[]，50 条）
//   $ 按配置切：数组 `data":{"tit`…`s_log` ⇒ 50 块
//       标题 `text":"&&"` → 10-27期（期数） · 副标题 `le":"&&"` → 《…》节目名
//       图片 `https://p0.ssl.cdn.btime.com/+ssl.cdn.btime.com/&&"` → 真封面（`+` 前缀生效）
//       链接 `item.btime.com/&&"` → 25lv4eql54fm6ddhptn2n6elsc9
//   $ 链接前缀 + id → 播放接口 200 · 824 B · video_streams / stream_vbt「原画」/ stream_url 真 mp4
//   ⇒ 这一份配置**完整可用**（home/list/detail/play 全链路真网打通：9 分类 / 304 条 / 真 mp4）。
//   ⚠️ 播放接口**不下发标题**（body 里没有 title 字段），配置也没有「详情标题」这类键
//      ⇒ 详情标题回退成「视频 <id>」；列表标题在上一屏已经给过。
// ```
//
// # 能力边界（如实）
// ```text
// ✅ home / list / detail / play：配置② 真网全通（50 条 + 真 mp4）
// ✅ 无 ext ⇒ 可读 Err（说明该类是配置驱动，需要配置 URL/JSON）—— 这也是内置源形态下的表现
// ❌ search：两份配置都没有搜索键（XBPQ 的搜索另需 搜索url/搜索数组 一族），
//    本实现不猜 ⇒ search 明确 Err、supports_search=false
// ❌ 只有 分类url 的配置（配置①）：缺 数组/标题/链接 ⇒ 可读 Err（不猜内置默认选择器）
// ❌ 非 UTF-8 编码（配置键 `编码`）：本仓没有 GBK 解码器 ⇒ 可读 Err（不静默乱码）
// ```

use async_trait::async_trait;
use regex::Regex;
use serde_json::Value;
use std::sync::OnceLock;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 配置里 `请求头` 的 `MOBILE_UA` 占位值（DEX 常量里就是这个占位名）
const MOBILE_UA: &str = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Mobile Safari/537.36";

/// 桌面 UA（`请求头` 没写时的兜底）
const DESKTOP_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

const TIMEOUT: Duration = Duration::from_secs(25);

pub struct Xbpq {
    client: reqwest::Client,
}

impl Xbpq {
    pub const CLASS: &'static str = "XBPQ";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(DESKTOP_UA)
            .timeout(TIMEOUT)
            // 本仓既定惯例：不读系统代理（否则「站点可用」会被测成「全宕」）
            .no_proxy()
            .build()
            .expect("build xbpq http client");
        Self { client }
    }

    async fn fetch(&self, url: &str, ua: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "*/*")
            .header(reqwest::header::USER_AGENT, ua)
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!(
                "HTTP {status}（{url}）· 前 120 字：{}",
                head(&text)
            ));
        }
        Ok(text)
    }

    /// 载配置：ext 是 URL 就取回来，否则当成内联 JSON 文本
    async fn load(&self, ext: &str) -> Result<Cfg, String> {
        let ext = ext.trim();
        if ext.is_empty() {
            return Err(
                "XBPQ 是配置驱动的通用类，需要 ext 里的配置（一个配置 URL，或内联的配置 JSON 文本）。\
                 当前是内置源形态、ext 为空 ⇒ 没有任何站点可打。\
                 订阅里该类的每一个源都自带一份配置 URL，导入订阅后才有站点。"
                    .to_string(),
            );
        }
        let text = if ext.starts_with("http://") || ext.starts_with("https://") {
            self.fetch(ext, DESKTOP_UA).await?
        } else {
            ext.to_string()
        };
        Cfg::parse(&text)
    }

    /// 取一页分类列表的原始响应
    async fn page_text(&self, cfg: &Cfg, cate_id: &str, pg: u32) -> Result<String, String> {
        let tpl = cfg
            .s("分类url")
            .ok_or_else(|| "配置缺「分类url」——没有分类页模板，取不到列表".to_string())?;
        let url = fill_url(tpl, cate_id, pg);
        let body = self.fetch(&url, cfg.ua()).await?;
        Ok(body)
    }
}

impl Default for Xbpq {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

// ═══════════════════════════════════════════════════════════════════════
//  配置
// ═══════════════════════════════════════════════════════════════════════

/// 一份 XBPQ 配置（键是中文/拼音，值全是字符串）
#[derive(Debug, Clone, Default)]
pub struct Cfg {
    map: serde_json::Map<String, Value>,
}

impl Cfg {
    /// 解析配置文本
    ///
    /// ★ 真实配置里有 **整行 `//` 注释**（订阅里的第二份配置第 2 行就是），
    ///   而 `serde_json` 不认注释 ⇒ 先按「整行注释」剥掉（**不碰 `http://` 里的双斜杠**）。
    pub fn parse(text: &str) -> Result<Self, String> {
        let cleaned: String = text
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect::<Vec<_>>()
            .join("\n");
        let v = crate::tvbox::parse_loose_json(&cleaned)
            .map_err(|e| format!("配置不是合法 JSON：{e}（前 120 字：{}）", head(text)))?;
        let map = v
            .as_object()
            .ok_or_else(|| "配置顶层不是对象（应为 {键: 值}）".to_string())?
            .clone();
        if map.is_empty() {
            return Err("配置是空对象（没有任何键）".to_string());
        }
        Ok(Self { map })
    }

    pub fn s(&self, k: &str) -> Option<&str> {
        self.map
            .get(k)
            .and_then(|v| v.as_str())
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
    }

    /// 配置里的请求头（`User-Agent$MOBILE_UA` 形态：名$值）
    pub fn ua(&self) -> &str {
        if let Some(h) = self.s("请求头") {
            for part in h.split('$') {
                let p = part.trim();
                if p.eq_ignore_ascii_case("MOBILE_UA") {
                    return MOBILE_UA;
                }
                if p.starts_with("Mozilla/") {
                    // 值是内联 UA 时不可能从 `$` 里拆出来（有空格），这里只兜底
                    return MOBILE_UA;
                }
            }
        }
        MOBILE_UA
    }

    /// `名$id#名$id` 形态（`分类`）；`类型` 同形但含 `||` 分组，这里只取第一层
    pub fn pairs(&self, k: &str) -> Vec<(String, String)> {
        let Some(raw) = self.s(k) else {
            return Vec::new();
        };
        raw.split('#')
            .filter_map(|seg| {
                let seg = seg.trim();
                if seg.is_empty() {
                    return None;
                }
                match seg.split_once('$') {
                    Some((n, id)) if !n.trim().is_empty() && !id.trim().is_empty() => {
                        Some((n.trim().to_string(), id.trim().to_string()))
                    }
                    _ => None,
                }
            })
            .collect()
    }

    /// 编码（只支持 UTF-8；其它值由调用方报可读 Err）
    pub fn encoding(&self) -> &str {
        self.s("编码").unwrap_or("UTF-8")
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  取值方言（纯函数，全部可离线测）
// ═══════════════════════════════════════════════════════════════════════

/// 把 `[包含:x]` 从 spec 尾巴上剥出来
fn split_contains(spec: &str) -> (&str, Option<&str>) {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"\[包含:(.*?)\]$").expect("xbpq contains regex"));
    if let Some(c) = re.captures(spec) {
        return (
            &spec[..c.get(0).map(|m| m.start()).unwrap_or(spec.len())],
            c.get(1).map(|m| m.as_str()),
        );
    }
    (spec, None)
}

/// 找「前标记」的起始位置与结束位置（`*` 是通配）
fn find_pre(text: &str, pre: &str) -> Option<(usize, usize)> {
    if !pre.contains('*') {
        let i = text.find(pre)?;
        return Some((i, i + pre.len()));
    }
    let pat = regex::escape(pre).replace(r"\*", ".*?");
    let re = Regex::new(&pat).ok()?;
    let m = re.find(text)?;
    Some((m.start(), m.end()))
}

/// `A&&B` 取一段；支持 `P+前缀`、`*` 通配、`[包含:x]` 过滤
pub fn cut(text: &str, spec: &str) -> Option<String> {
    let (spec, contains) = split_contains(spec);
    let (pre, suf) = spec.split_once("&&")?;
    let (add, pre) = match pre.split_once('+') {
        Some((a, b)) => (a, b),
        None => ("", pre),
    };
    let (_, mend) = find_pre(text, pre)?;
    let rest = text.get(mend..)?;
    let e = rest.find(suf)?;
    let val = format!("{add}{}", &rest[..e]);
    if let Some(c) = contains {
        if !val.contains(c) {
            return None;
        }
    }
    Some(val)
}

/// 反复按 `A&&B` 切出所有块（`数组`/`播放数组`/`播放列表` 都用它）
pub fn cut_all(text: &str, spec: &str) -> Vec<String> {
    let (spec, contains) = split_contains(spec);
    let Some((pre, suf)) = spec.split_once("&&") else {
        return Vec::new();
    };
    let (add, pre) = match pre.split_once('+') {
        Some((a, b)) => (a, b),
        None => ("", pre),
    };
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos < text.len() {
        let Some((_, mend)) = find_pre(&text[pos..], pre) else {
            break;
        };
        let abs_start = pos + mend;
        let Some(rel_end) = text[abs_start..].find(suf) else {
            break;
        };
        let abs_end = abs_start + rel_end;
        let val = format!("{add}{}", &text[abs_start..abs_end]);
        if let Some(c) = contains {
            if !val.contains(c) {
                pos = abs_end + suf.len().max(1);
                continue;
            }
        }
        out.push(val);
        pos = abs_end + suf.len().max(1);
    }
    out
}

/// 把 `分类url` 模板里的占位符换掉
///
/// ```text
/// {cateId} {catePg}  —— 真配置用到的两个
/// {area} {by} {class} {lang} {letter} {year} —— 影视站配置里的筛选位（无筛选时留空）
/// {pg} —— 少数配置用它指页码
/// ```
pub fn fill_url(tpl: &str, cate_id: &str, pg: u32) -> String {
    let mut u = tpl
        .replace("{cateId}", cate_id)
        .replace("{catePg}", &pg.max(1).to_string())
        .replace("{pg}", &pg.max(1).to_string());
    for k in ["{area}", "{by}", "{class}", "{lang}", "{letter}", "{year}"] {
        u = u.replace(k, "");
    }
    u
}

// ═══════════════════════════════════════════════════════════════════════
//  解析（纯函数；fixture 是真响应片段）
// ═══════════════════════════════════════════════════════════════════════

/// 把 JSON 里的 `\/` 还原成 `/`
///
/// ★ 真响应是 JSONP 包裹的 JSON，URL 里写作 `https:\/\/…`；而配置里的标记是
///   `item.btime.com/`（无转义）。**不还原就切不出链接** —— 实测过一次（切空）。
fn json_unescape_slash(s: &str) -> String {
    s.replace(r"\/", "/")
}

/// 解析一页列表
pub fn parse_items(cfg: &Cfg, body: &str) -> Result<Vec<CspItem>, String> {
    let body = &json_unescape_slash(body);
    let Some(arr) = cfg.s("数组") else {
        return Err(
            "配置缺「数组」：这一类配置只给了「分类url」，需要 XBPQ 的「内置默认选择器」；\
             本仓没有该默认选择器的参考形态（DEX 常量里只有配置键、没有内置选择器），\
             所以不做猜测解析。请在配置里补「数组/标题/链接」等键。"
                .to_string(),
        );
    };
    let blocks = cut_all(body, arr);
    if blocks.is_empty() {
        return Err(format!(
            "按配置的「数组」切出 0 条（模板可能改版/风控壳页）· 页面长度 {} 字节 · 数组前标记=`{}`",
            body.len(),
            arr.split("&&").next().unwrap_or("")
        ));
    }
    let mut out: Vec<CspItem> = Vec::new();
    for b in blocks {
        let Some(link) = cfg.s("链接").and_then(|s| cut(&b, s)) else {
            continue;
        };
        let title = cfg
            .s("标题")
            .and_then(|s| cut(&b, s))
            .or_else(|| cfg.s("副标题").and_then(|s| cut(&b, s)));
        let Some(title) = title.filter(|t| !t.trim().is_empty()) else {
            continue;
        };
        let cover = cfg.s("图片").and_then(|s| cut(&b, s));
        let subtitle = cfg
            .s("副标题")
            .and_then(|s| cut(&b, s))
            .filter(|s| s != &title);
        out.push(CspItem {
            id: link,
            title: title.trim().to_string(),
            cover: cover
                .map(|c| c.trim().to_string())
                .filter(|c| c.starts_with("http")),
            subtitle: subtitle.map(|s| s.trim().to_string()),
        });
    }
    if out.is_empty() {
        return Err(
            "切出了数组块，但「没有一条」同时具备「标题」与「链接」（选择器与响应可能不匹配）"
                .to_string(),
        );
    }
    Ok(out)
}

/// 解析详情页里的播放列表
pub fn parse_play(cfg: &Cfg, body: &str) -> Vec<CspEpisode> {
    let body = &json_unescape_slash(body);
    let block = cfg
        .s("播放数组")
        .map(|s| cut_all(body, s).join(""))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| body.to_string());
    let lines = match cfg.s("播放列表") {
        Some(spec) => {
            let v = cut_all(&block, spec);
            if v.is_empty() {
                vec![block]
            } else {
                v
            }
        }
        None => vec![block],
    };
    let mut out = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let Some(url) = cfg.s("播放链接").and_then(|s| cut(line, s)) else {
            continue;
        };
        if !url.starts_with("http") {
            continue;
        }
        let title = cfg
            .s("播放标题")
            .and_then(|s| cut(line, s))
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| format!("线路{}", i + 1));
        out.push(CspEpisode {
            id: url,
            title: title.clone(),
            flag: title,
        });
    }
    out
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for Xbpq {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let cfg = self.load(ext).await?;
        let cats = cfg.pairs("分类");
        if cats.is_empty() {
            return Err("配置缺「分类」（形如 `名称$id#名称$id`）——首页没有分类可用".to_string());
        }
        let categories: Vec<CspCategory> = cats
            .iter()
            .map(|(n, id)| CspCategory {
                id: id.clone(),
                name: n.clone(),
            })
            .collect();
        let body = self.page_text(&cfg, &cats[0].1, 1).await?;
        check_encoding(&cfg)?;
        let items = parse_items(&cfg, &body)?;
        Ok(CspHome { categories, items })
    }

    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let tid = tid.trim();
        if tid.is_empty() {
            return Err("分类 id 为空".to_string());
        }
        let cfg = self.load(ext).await?;
        let page = page.max(1);
        let body = self.page_text(&cfg, tid, page).await?;
        check_encoding(&cfg)?;
        let items =
            parse_items(&cfg, &body).map_err(|e| format!("分类 {tid} 第 {page} 页：{e}"))?;
        Ok(CspList {
            items,
            page,
            page_count: None,
            total: None,
        })
    }

    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("XBPQ 的搜索需要配置里的「搜索url/搜索数组」一族键；\
             订阅里的两份配置都没有这些键（它们只配了分类页），\
             本实现不猜测搜索入口 ⇒ 不声明搜索能力。"
            .to_string())
    }

    fn supports_search(&self) -> bool {
        false
    }

    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("详情 id 为空".to_string());
        }
        let cfg = self.load(ext).await?;
        let url = if id.starts_with("http") {
            id.to_string()
        } else if let Some(pre) = cfg.s("链接前缀") {
            format!("{pre}{id}")
        } else {
            return Err(format!(
                "详情 id 不是完整地址，且配置没有「链接前缀」——无法拼出详情地址：`{id}`"
            ));
        };
        let body = self.fetch(&url, cfg.ua()).await?;
        check_encoding(&cfg)?;

        let episodes = parse_play(&cfg, &body);
        if episodes.is_empty() {
            return Err(format!(
                "详情页里没有可播地址（按配置的「播放数组/播放列表/播放链接」切不出来）· \
                 页面长度 {} 字节",
                body.len()
            ));
        }
        let title = cfg
            .s("标题")
            .and_then(|s| cut(&body, s))
            .or_else(|| cfg.s("副标题").and_then(|s| cut(&body, s)))
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| format!("视频 {id}"));
        let description = ["简介", "介绍", "剧情", "描述"]
            .iter()
            .find_map(|k| cfg.s(k).and_then(|s| cut(&body, s)))
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let cover = cfg
            .s("图片")
            .and_then(|s| cut(&body, s))
            .filter(|c| c.starts_with("http"));
        Ok(CspDetail {
            id: id.to_string(),
            title,
            cover,
            description,
            episodes,
        })
    }

    async fn play(&self, _flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.starts_with("http://") || id.starts_with("https://") {
            let cfg = self.load(ext).await.unwrap_or_default();
            return Ok(vec![CspPlay {
                url: id.to_string(),
                headers: vec![
                    ("User-Agent".to_string(), cfg.ua().to_string()),
                    ("Referer".to_string(), referer_of(id)),
                ],
                label: Some("直链".to_string()),
            }]);
        }
        Err(format!(
            "播放 id 不是 http(s) 地址（`{id}`）——本类只把配置切出来的真实流地址当播放目标，不做假通"
        ))
    }
}

fn referer_of(u: &str) -> String {
    match u.split_once("://") {
        Some((scheme, rest)) => match rest.split_once('/') {
            Some((host, _)) => format!("{scheme}://{host}/"),
            None => format!("{scheme}://{rest}/"),
        },
        None => String::new(),
    }
}

fn check_encoding(cfg: &Cfg) -> Result<(), String> {
    let enc = cfg.encoding();
    if enc.eq_ignore_ascii_case("utf-8") || enc.eq_ignore_ascii_case("utf8") {
        return Ok(());
    }
    Err(format!(
        "配置里的「编码」是 `{enc}`：本仓没有该编码的解码器（只有 UTF-8）⇒ \
         按 UTF-8 解会把正文变乱码，所以这里明确拒绝，而不是静默乱码"
    ))
}

// ═══════════════════════════════════════════════════════════════════════
//  自注册（① 订阅里 2 站都写 csp_XBPQ；② 配置②的真网接口 200（配置① 的源站 523）；
//  ③ 真网取到数据 —— 50 条 + 真 mp4）
// ═══════════════════════════════════════════════════════════════════════
crate::csp::register_site!(Xbpq);

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    /// ★ 真配置（订阅里第二份；原文 1262 B，含整行 `//` 注释 —— 解析必须能吃掉）
    const FIX_CFG: &str = r#"{
    "首页": "0",
    // "播放链接前缀": "https://www.gyf.lol",
    "数组": "data\":{\"tit&&s_log",
    "图片": "https://p0.ssl.cdn.btime.com/+ssl.cdn.btime.com/&&\"",
    "副标题": "le\":\"&&\"",
    "标题": "text\":\"&&\"",
    "链接": "item.btime.com/&&\"",
    "链接前缀": "https://app.api.btime.com/video/play?callback=jQuery36009651202523243325_1747927554988&id=",
    // "线路标题": "</i>&&<span",
    "播放数组": "video_streams&&audio_streams",
    "播放列表": "stream&&duration",
    "播放标题": "stream_vbt\":\"&&\"",
    "播放链接": "url\":\"&&\"",
    "分类url": "https://pc.api.btime.com/btimeweb/infoFlow?callback=jQuery36002244958011106073_1747920210579&list_id={cateId}&refresh={catePg}&count=2000&expands=pageinfo&_=1747920210580",
    "分类": "2026$btv_08da67cea600bf3c78973427bfaba12d_s0_2026#2025$btv_08da67cea600bf3c78973427bfaba12d_s0_2025#2024$btv_08da67cea600bf3c78973427bfaba12d_s0_2024#2023$btv_08da67cea600bf3c78973427bfaba12d_s0_2023#2022$btv_08da67cea600bf3c78973427bfaba12d_s0_2022#2021$btv_08da67cea600bf3c78973427bfaba12d_s0_2021#2020$btv_08da67cea600bf3c78973427bfaba12d_s0_2020#2019$btv_08da67cea600bf3c78973427bfaba12d_s0_2019#2018$btv_08da67cea600bf3c78973427bfaba12d_s0_2018"
}"#;

    /// ★ 真响应片段（2026-10-28 抓自配置②的分类接口；原文 103091 B，这里保留**前两条**的完整字节）
    const FIX_BODY: &str = r##"jQuery36002244958011106073_1747920210579({"errno":0,"msg":"操作成功","data":{"list":[{"gid":"25lv4eql54fm6ddhptn2n6elsc9","dupid":"25lv4eql54fm6ddhptn2n6elsc9","score":"1793030400","type":3,"module":1,"url":"https:\/\/item.btime.com\/25lv4eql54fm6ddhptn2n6elsc9","data":{"title":"《养生堂》20261027男性健康日特别节目 固本通瘀巧补肾","pdate":"1793099913","covers":["https:\/\/p2.ssl.cdn.btime.com\/t11a477708f4be3a2b181d7137b.jpg?size=1920x1080"],"covers_extends":"{\"16:9\":\"https:\\\/\\\/p2.ssl.cdn.btime.com\\\/t11a477708ff07e699d72eab3e9.jpg?size=1920x1080\",\"4:3\":\"https:\\\/\\\/p4.ssl.cdn.btime.com\\\/t11a477708fc6c4280b8dce31f2.jpg?size=1067x800\"}","summary":"","source":"养生堂","source_type":"tianmai","author_img":"","pics_count":1,"imgs_count":0,"ding":2,"live_stats":0,"live_status":0,"duration":"56:15","meta":"{\"is_yuanchuang\":\"是\",\"is_news\":\"新闻稿件\",\"corner\":[{\"position\":\"right_bottom\",\"text_color\":\"#ffffff\",\"text\":\"10-27期\"}]}","skip_count":0,"corner":[{"position":"right_bottom","text_color":"#ffffff","text":"10-27期"}],"pdate_str":"12小时前","pdate_ymdhis":"2026-10-27 19:18:33","pdate_ymdhi":"2026-10-27 19:18","pdate_ymd":"2026-10-27"},"open_url":"https:\/\/item.btime.com\/25lv4eql54fm6ddhptn2n6elsc9","s_log":"{\"gid\":\"25lv4eql54fm6ddhptn2n6elsc9\",\"news_type\":3,\"business_type\":\"news\",\"source\":\"养生堂\",\"source_type\":\"tianmai\",\"author_uid\":\"\",\"create_uid\":\"\",\"create_name\":\"\",\"channel_code\":\"1802\",\"pdate\":\"1793099913\",\"order\":1,\"first_channel_id\":\"18\",\"second_channel_id\":\"1802\",\"third_channel_id\":\"\"}","shence_rec":"","is_ad":false,"sc_log":"{\"current_page_title\":\"\",\"content_id\":\"25lv4eql54fm6ddhptn2n6elsc9\",\"content_title\":\"《养生堂》20261027男性健康日特别节目 固本通瘀巧补肾\",\"content_form\":\"视频\",\"publish_time\":\"2026-10-27 19:18:33\",\"publish_account\":\"养生堂\",\"publish_id\":\"\",\"channel_id\":\"\",\"channel_name\":\"\",\"moudle_id\":\"\",\"moudle_name\":\"\",\"cid\":\"\",\"is_news\":\"新闻稿件\",\"is_yuanchuang\":\"是\",\"module_sort\":1}"},{"gid":"26qi4fp1bulirq9ga97upbe7djh","dupid":"cd6b1a2b1375fe34","score":"1792944000","type":3,"module":1,"url":"https:\/\/item.btime.com\/26qi4fp1bulirq9ga97upbe7djh","data":{"title":"《养生堂》20261026以降为补巧养肾","pdate":"1793011117","covers":["https:\/\/p1.ssl.cdn.btime.com\/t11a477708fed286b0c91cdccca.jpg?size=1920x1080"],"covers_extends":"{\"16:9\":\"https:\/\/p3.ssl.cdn.btime.com\/t11a477708fed286b0c91cdccca.jpg?size=1920x1080\",\"4:3\":\"https:\/\/p1.ssl.cdn.btime.com\/t11a477708fb528dfdc31ba86da.jpg?size=1152x863\"}","summary":"","source":"养生堂","source_type":"tianmai","create_uid":"3314744","create_name":"杨万慧","author_img":"","pics_count":1,"imgs_count":0,"ding":12,"live_stats":0,"live_status":0,"duration":"53:04","meta":"{\"is_yuanchuang\":\"是\",\"is_news\":\"新闻稿件\",\"corner\":[{\"position\":\"right_bottom\",\"text_color\":\"#ffffff\",\"text\":\"10-26期\"}]}","skip_count":0,"corner":[{"position":"right_bottom","text_color":"#ffffff","text":"10-26期"}],"pdate_str":"1天前","pdate_ymdhis":"2026-10-26 18:38:37","pdate_ymdhi":"2026-10-26 18:38","pdate_ymd":"2026-10-26"},"open_url":"https:\/\/item.btime.com\/26qi4fp1bulirq9ga97upbe7djh","s_log":"{\"gid\":\"26qi4fp1bulirq9ga97upbe7djh\",\"news_type\":3,\"business_type\":\"news\",\"source\":\"养生堂\",\"source_type\":\"tianmai\",\"author_uid\":\"\",\"create_uid\":\"3314744\",\"create_name\":\"杨万慧\",\"channel_code\":\"1707\",\"pdate\":\"1793011117\""##;

    /// ★ 真响应（2026-10-28 抓自配置②的播放接口，824 B 原文全留）
    const FIX_PLAY: &str = r#"jQuery36009651202523243325_1747927554988({"errno":0,"data":{"play_status":2,"video_stream":[{"stream_url":"http:\/\/mp4.v.btime.com\/vod-ugc-btime-q2-bj\/250019225_4-1793101193-bd01d9e1-ec0d-3c15.mp4?time=1793146622&sign=7b9eb7e8451eb055305f915948ce7d3c","stream_rate":1500,"stream_vbt":"原画","stream_type":7,"duration":"00:56:15"}],"video_streams":[[{"stream_url":"http:\/\/mp4.v.btime.com\/vod-ugc-btime-q2-bj\/250019225_4-1793101193-bd01d9e1-ec0d-3c15.mp4?time=1793146622&sign=7b9eb7e8451eb055305f915948ce7d3c","stream_rate":1500,"stream_vbt":"原画","stream_type":7,"duration":"00:56:15"}]],"audio_streams":[],"ts":1793146622,"gid":"25lv4eql54fm6ddhptn2n6elsc9","utoken":"","video_covers":"https:\/\/p1.ssl.cdn.btime.com\/t11a477708f4be3a2b181d7137b.jpg?size=1920x1080","video_source_type":3,"duration":"00:56:15"}})"#;

    fn cfg() -> Cfg {
        Cfg::parse(FIX_CFG).expect("真配置必须解析得出来（含 // 注释）")
    }

    #[test]
    fn class_name_is_exact() {
        assert_eq!(Xbpq::CLASS, "XBPQ");
    }

    #[test]
    fn config_parses_with_line_comments() {
        let c = cfg();
        assert_eq!(c.s("首页"), Some("0"));
        assert_eq!(c.s("数组"), Some(r#"data":{"tit&&s_log"#));
        let cats = c.pairs("分类");
        assert_eq!(cats.len(), 9, "配置里 9 个年份分类：{cats:?}");
        assert_eq!(cats[0].0, "2026");
        assert!(cats[0].1.ends_with("_2026"));
        assert!(c.s("链接前缀").unwrap().ends_with("&id="));
    }

    #[test]
    fn cut_dialect_matches_the_real_body() {
        let c = cfg();
        let blocks = cut_all(FIX_BODY, c.s("数组").unwrap());
        assert_eq!(blocks.len(), 2, "夹具保留了前两条");
        // ★ 真响应里 URL 是 `\/` 转义；解析前要像 parse_items 那样先还原（否则 `+` 前缀切不到）
        let b = &json_unescape_slash(&blocks[0]);
        assert_eq!(cut(b, c.s("标题").unwrap()).as_deref(), Some("10-27期"));
        assert!(
            cut(b, c.s("副标题").unwrap()).unwrap().starts_with("《"),
            "副标题是节目名"
        );
        let img = cut(b, c.s("图片").unwrap()).expect("图片要能切出来");
        assert!(img.starts_with("https://"), "{img}");
        assert!(img.contains("t11a"), "★ `+` 前缀要拼回去：{img}");
        assert_eq!(
            cut(b, c.s("链接").unwrap()).as_deref(),
            Some("25lv4eql54fm6ddhptn2n6elsc9"),
            "★ JSON 里的 `\\/` 不还原就会切空（夹具是真响应，含转义）"
        );
    }

    #[test]
    fn cut_supports_prefix_wildcard_and_contains_filter() {
        // P+A&&B
        assert_eq!(
            cut(
                "xxhttps://pan.example/s/abc\"yy",
                r#"https://www.aliyundrive.com/s/+pan.example/s/&&""#
            )
            .as_deref(),
            Some("https://www.aliyundrive.com/s/abc")
        );
        // A*B（通配）
        assert_eq!(
            cut(r#"<a class="x" href="https://a/b">t"#, r#"<a*href="&&""#).as_deref(),
            Some("https://a/b")
        );
        // [包含:http]
        assert_eq!(
            cut(r#"<a href="/rel">"#, r#"href="&&"[包含:http]"#),
            None,
            "不含 http 必须被过滤"
        );
        // 没有 && ⇒ None（坏配置不能 panic）
        assert_eq!(cut("abc", "abc"), None);
    }

    #[test]
    fn fill_url_replaces_placeholders_and_blanks_filters() {
        let t = "https://h/vodshow/{cateId}-{area}-{by}---{catePg}---{year}.html";
        assert_eq!(
            fill_url(t, "1", 2),
            "https://h/vodshow/1-----2---.html",
            "筛选位留空、页码进页码占位"
        );
        assert_eq!(fill_url("x?p={pg}", "9", 3), "x?p=3");
    }

    #[test]
    fn parse_items_uses_the_real_config_and_body() {
        let c = cfg();
        let items = parse_items(&c, FIX_BODY).expect("真响应片段必须解析得出来");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].title, "10-27期");
        assert_eq!(items[0].id, "25lv4eql54fm6ddhptn2n6elsc9");
        assert!(items[0]
            .cover
            .as_deref()
            .unwrap_or("")
            .starts_with("https://"));
        assert!(
            items[0].subtitle.as_deref().unwrap_or("").starts_with("《"),
            "副标题是节目名：{:?}",
            items[0].subtitle
        );
    }

    #[test]
    fn empty_or_unmatched_body_reports_reason() {
        let c = cfg();
        let e = parse_items(&c, "<html><body>nothing</body></html>").unwrap_err();
        assert!(e.contains("切出 0 条"), "{e}");
        assert!(e.contains("模板可能改版"), "要写明可能原因：{e}");
        // 配置缺 数组 ⇒ 可读 Err（不猜内置选择器）
        let c2 =
            Cfg::parse(r#"{"分类":"电影$1","分类url":"https://h/vodshow/{cateId}.html"}"#).unwrap();
        let e2 = parse_items(&c2, "x").unwrap_err();
        assert!(e2.contains("缺「数组」"), "{e2}");
        assert!(e2.contains("不做猜测解析"), "{e2}");
    }

    #[test]
    fn play_list_parses_the_real_play_response() {
        let c = cfg();
        let eps = parse_play(&c, FIX_PLAY);
        assert_eq!(eps.len(), 1, "夹具里只有一条 video_stream：{eps:?}");
        assert_eq!(eps[0].title, "原画");
        assert!(
            eps[0].id.starts_with("http"),
            "播放地址要还原成真 URL：{}",
            eps[0].id
        );
        assert!(!eps[0].id.contains("\\/"), "★ `\\/` 必须还原成 `/`");
    }

    #[test]
    fn play_response_without_streams_yields_no_episodes() {
        let c = cfg();
        assert!(parse_play(&c, "{\"errno\":404}").is_empty());
    }

    #[tokio::test]
    async fn without_ext_every_segment_reports_what_is_missing() {
        let s = Xbpq::new();
        for e in [
            s.home("").await.err(),
            s.list("1", 1, "").await.err(),
            s.detail("1", "").await.err(),
        ] {
            let m = e.expect("无 ext 必须 Err");
            assert!(m.contains("配置"), "{m}");
            assert!(m.contains("ext"), "{m}");
        }
        assert!(!s.supports_search());
        let se = s.search("x", 1, "").await.expect_err("搜索必须 Err");
        assert!(se.contains("搜索url"), "{se}");
    }

    #[test]
    fn non_utf8_encoding_is_refused_not_garbled() {
        let c = Cfg::parse(r#"{"编码":"GBK","分类":"a$1"}"#).unwrap();
        let e = check_encoding(&c).unwrap_err();
        assert!(e.contains("GBK"), "{e}");
        assert!(e.contains("乱码"), "{e}");
    }

    #[test]
    fn it_is_registered() {
        assert!(
            crate::csp::is_implemented("csp_XBPQ"),
            "★ csp_XBPQ 必须已注册（订阅 2 站 + 配置② 真网 200 + 50 条数据）"
        );
        assert_eq!(
            crate::csp::route("csp_XBPQ").expect("route").class(),
            "XBPQ"
        );
    }

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp::xbpq::tests::xbpq_live -- --ignored --nocapture"]
    async fn xbpq_live() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        // 两份订阅配置（URL 里的中文按百分号编码，避免在源码里写站名/节目名）
        let cfg_a = "https://wget.la/raw.githubusercontent.com/tushen6/Tomorrow/master/XBPQ/%E6%B0%B8%E4%B9%90%E5%BD%B1%E8%A7%86.json";
        let cfg_b = "https://wget.la/raw.githubusercontent.com/tushen6/Tomorrow/master/XBPQ/%E5%85%BB%E7%94%9F%E5%A0%82.json";
        let s = Xbpq::new();

        match s.home(cfg_a).await {
            Ok(h) => println!(
                "LIVE|xbpq|A|home|分类={} 条目={}（意外：源站居然活了）",
                h.categories.len(),
                h.items.len()
            ),
            Err(e) => println!("LIVE|xbpq|A|home|ERR|{e}"),
        }
        let hb = s.home(cfg_b).await.expect("配置② home 必须取到数据");
        println!(
            "LIVE|xbpq|B|home|分类={} 条目={}",
            hb.categories.len(),
            hb.items.len()
        );
        assert!(!hb.items.is_empty());
        let first = hb.items[0].id.clone();
        let d = s
            .detail(&first, cfg_b)
            .await
            .expect("配置② 详情必须取到播放地址");
        println!(
            "LIVE|xbpq|B|detail|{first}|标题={} 线路={} 首个={:?}",
            d.title,
            d.episodes.len(),
            d.episodes.first()
        );
        assert!(!d.episodes.is_empty());
        let p = s
            .play("直链", &d.episodes[0].id, cfg_b)
            .await
            .expect("play 要能出流");
        println!("LIVE|xbpq|B|play|{}", p[0].url);
    }
}
