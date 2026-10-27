// ═══════════════════════════════════════════════════════════════════════
//  csp_GuanYing —— 「观影 4K 网盘站」的 Rust 重写（**本批不注册**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 参考（DEX 逐字，`.probe/csp25/GuanYing.txt`）
// ```text
// fq=com.github.catvod.spider.GuanYing  parent=Lcom/github/catvod/spider/Pan;
// HOSTS = 4 个 punycode 镜像（解码后是中文片名域名）：
//   https://www.xn--wcv59z.com            → 教父.com
//   https://www.xn--74qz10cqsltibh40akss.com → 肖申克的救赎.com
//   https://www.xn--10vr61a3xc5x3b.com    → 盗梦空间.com
//   https://www.xn--kivn76b41nnhi.com     → 星际穿越.com
// TYPES = rec/推荐 · mv/电影 · tv/剧集 · ac/动漫；filters: 类型/地区/排序
// 页面数据：`_obj.inlist={…};` / `_obj.search={…};` / `_obj.d={…};`（JS 内联 JSON）
// 反爬：solvePow() + `/res/pow` + cookie `browser_pow` / `browser_verified`
// 登录：`/user/login`（username/password/cookietime…）+ `PHPSESSID` / `app_auth`
// ```
//
// # ★ 2026-10-28 真网实测（不是推测；读数见 `.probe/csp-live-live.log`）
// ```text
// $ curl --noproxy '*' -A <Chrome> https://www.xn--wcv59z.com/          → 200 · 1076 B
//   <title>浏览器安全验证</title> + `pow.core.js`/`powSolve.js` + Set-Cookie `browser_pow=…`
// $ GET /res/pow（带 browser_pow） → 200 JSON {"N":"<2048bit>","x":"<2048bit>","t":400000}
// $ 按 pow.worker 的算法（y = x；重复 t 次 y = y² mod N）解出 y（Python 参考实现 3.40s）
// $ POST /res/pow  body `y=<hex>` → 200 {"success":true,"challenge_id":"570cc52f…"}
//   并下发 Set-Cookie `browser_verified=…`（PoW 通过）
// $ 之后 GET /（带 browser_verified）→ 200 · 828 B
//   <title>未登录，访问受限</title> · `_obj.header={"q":"","t":"","p":"","l":"home",…}`
//   `_obj.inlist` / `_obj.search` / `_obj.d` **一个都没有**
// $ /mv/ · /tv/ · /search?q=仙逆 → 全部同一张「未登录，访问受限」
// ⇒ **整站要登录**：PoW 只是第一道门，第二道门是账号（PHPSESSID/app_auth）。
// ```
//
// # ★ 为什么**没有** `register_site!`（判据三条，缺第 ③ 条）
// ```text
// ① 订阅里有这 1 站（csp_GuanYing，key=guanying）✓
// ② 有可用 host（4 个镜像第 1 个真网 200，PoW 可解）✓
// ③ **真网取到数据** ✗ —— 拿到 browser_verified 之后仍然是「未登录，访问受限」，
//    home/list/search/detail **一条内容都取不到**（页面 828 B 的登录墙）
// ⇒ 只做实现、不注册。注册它 = 交付一个「看起来支持、点开全报错」的源。
// ```
//
// # 那 PoW 为什么还要实现（不是白写）
// ```text
// 它是**协议的一部分**：没有它连登录页都看不到（所有请求都返回验证页）。
// 本文件把它完整落地（`pow_solve` + cookie 链），并用**真 challenge + 真提交**验证过一次
// （`{"success":true}`）。将来一旦拿到账号，`get()` 之后的所有解析**已经是通的**
// （解析器按 DEX 的 `_obj.*` 结构实现，见下）。
// ```
//
// # 解析器的证据等级（如实标注，别把推断说成事实）
// ```text
// ✅ `未登录，访问受限` 的判定：**真响应**（`FIX_LOGIN_WALL` 是真页面片段）
// ⚠️ `_obj.inlist` / `_obj.d` 的**字段名**：按 DEX 常量（i/t/a/g/ty、vod_*、url/name/p）推断，
//    **没有取得登录态真样本** ⇒ 解析器写成「宽进」（多个候选键都认），并在测试里用
//    「按 DEX 常量重构的样本」验证；夹具上明写「重构样本，不是真响应」。
// ```

use async_trait::async_trait;
use regex::Regex;
use serde_json::Value;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

/// DEX 的 UA（逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// DEX 的 4 个镜像（逐字，punycode）。第 1 个 = 教父.com（实测 200）
pub const HOSTS: &[&str] = &[
    "https://www.xn--wcv59z.com",
    "https://www.xn--74qz10cqsltibh40akss.com",
    "https://www.xn--10vr61a3xc5x3b.com",
    "https://www.xn--kivn76b41nnhi.com",
];

const TIMEOUT: Duration = Duration::from_secs(25);

/// PoW 提交后站点给的 cookie 名（DEX 常量）
const VERIFIED: &str = "browser_verified";
const POW: &str = "browser_pow";

/// DEX 的 3 个分类
pub const TYPES: &[(&str, &str)] = &[("rec", "推荐"), ("mv", "电影"), ("tv", "剧集"), ("ac", "动漫")];

/// 登录墙的原文（真响应标题）
pub const LOGIN_WALL_TITLE: &str = "未登录，访问受限";

pub struct GuanYing {
    client: reqwest::Client,
    host: String,
    /// `browser_verified=<token>`（PoW 通过后才有）
    cookie: Mutex<String>,
}

impl GuanYing {
    pub const CLASS: &'static str = "GuanYing";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(TIMEOUT)
            // 本仓既定惯例：不读系统代理（否则「站点可用」会被测成「全宕」）
            .no_proxy()
            .build()
            .expect("build guan_ying http client");
        Self {
            client,
            host: HOSTS[0].to_string(),
            cookie: Mutex::new(String::new()),
        }
    }

    fn cookie(&self) -> String {
        self.cookie.lock().map(|g| g.clone()).unwrap_or_default()
    }

    fn set_cookie(&self, v: String) {
        if let Ok(mut g) = self.cookie.lock() {
            *g = v;
        }
    }

    /// 发一个 GET（自动带上 browser_verified）
    async fn get(&self, path: &str) -> Result<String, String> {
        let url = format!("{}{}", self.host, path);
        let resp = self
            .client
            .get(&url)
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .header(reqwest::header::REFERER, format!("{}/", self.host))
            .header(reqwest::header::COOKIE, self.cookie())
            .send()
            .await
            .map_err(|e| format!("请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读取失败（{url}）：{e}"))?;
        if !status.is_success() {
            return Err(format!("HTTP {status}（{url}）· 前 120 字：{}", head(&text)));
        }
        Ok(text)
    }

    /// 完整 PoW 握手：GET /（拿 browser_pow）→ GET /res/pow（拿 challenge）→
    /// 解 y → POST /res/pow（拿 browser_verified）
    ///
    /// 返回一句**可复核**的读数（含 challenge 的 t 与提交结果），供日志/测试打印。
    pub async fn handshake(&self) -> Result<String, String> {
        // ① 首页（拿 browser_pow）
        let resp = self
            .client
            .get(format!("{}/", self.host))
            .header(reqwest::header::ACCEPT, "text/html,application/xhtml+xml")
            .send()
            .await
            .map_err(|e| format!("首页请求失败：{e}"))?;
        let pow_cookie = cookie_of(resp.headers(), POW)
            .ok_or_else(|| "首页没有下发 browser_pow（反爬形态可能变了）".to_string())?;

        // ② challenge
        let resp = self
            .client
            .get(format!("{}/res/pow", self.host))
            .header(reqwest::header::ACCEPT, "application/json, text/plain, */*")
            .header(reqwest::header::REFERER, format!("{}/", self.host))
            .header(reqwest::header::COOKIE, format!("{POW}={pow_cookie}"))
            .send()
            .await
            .map_err(|e| format!("取 PoW challenge 失败：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读 PoW challenge 失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("PoW challenge HTTP {status}：{text}"));
        }
        let ch = crate::tvbox::parse_loose_json(&text)
            .map_err(|e| format!("PoW challenge 不是 JSON：{e}（前 120 字：{}）", head(&text)))?;
        let n = str_of(&ch, "N").ok_or_else(|| "challenge 缺 N".to_string())?;
        let x = str_of(&ch, "x").ok_or_else(|| "challenge 缺 x".to_string())?;
        let t = ch
            .get("t")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| "challenge 缺 t".to_string())?;
        if t > 5_000_000 {
            return Err(format!("challenge 的 t={t} 过大（拒绝执行，避免卡死）"));
        }

        // ③ 解（CPU 密集 ⇒ 丢到阻塞线程池）
        let (n2, x2) = (n.clone(), x.clone());
        let y = tokio::task::spawn_blocking(move || pow_solve(&n2, &x2, t as u32))
            .await
            .map_err(|e| format!("PoW 计算任务失败：{e}"))??;

        // ④ 提交（form: y=<hex>）
        let resp = self
            .client
            .post(format!("{}/res/pow", self.host))
            .header(reqwest::header::REFERER, format!("{}/", self.host))
            .header(reqwest::header::COOKIE, format!("{POW}={pow_cookie}"))
            .form(&[("y", y)])
            .send()
            .await
            .map_err(|e| format!("提交 PoW 失败：{e}"))?;
        let status = resp.status();
        let headers = resp.headers().clone();
        let text = resp.text().await.map_err(|e| format!("读 PoW 响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("提交 PoW HTTP {status}：{text}"));
        }
        let ok = crate::tvbox::parse_loose_json(&text)
            .ok()
            .and_then(|v| v.get("success").and_then(|s| s.as_bool()))
            .unwrap_or(false);
        if !ok {
            return Err(format!("PoW 未被接受：{text}"));
        }
        let token = cookie_of(&headers, VERIFIED)
            .ok_or_else(|| "PoW 通过但没有下发 browser_verified（形态可能变了）".to_string())?;
        self.set_cookie(format!("{VERIFIED}={token}"));
        Ok(format!(
            "PoW ok：t={t} N={} bits x={} bits → success:true，已取得 {VERIFIED}",
            n.len() * 4,
            x.len() * 4
        ))
    }

    /// 确保拿到 `browser_verified`（没有就握手一次）
    async fn ensure_verified(&self) -> Result<(), String> {
        if self.cookie().contains(VERIFIED) {
            return Ok(());
        }
        self.handshake().await.map(|_| ())
    }
}

impl Default for GuanYing {
    fn default() -> Self {
        Self::new()
    }
}

fn head(s: &str) -> String {
    s.chars().take(120).collect::<String>().replace('\n', " ")
}

fn str_of(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(|s| s.to_string())
}

/// 从响应头里取某个 cookie 的值（`browser_pow=abc; Path=/` ⇒ `abc`）
pub fn cookie_of(headers: &reqwest::header::HeaderMap, name: &str) -> Option<String> {
    for v in headers.get_all(reqwest::header::SET_COOKIE) {
        let s = v.to_str().ok()?;
        for part in s.split(';') {
            let p = part.trim();
            if let Some(rest) = p.strip_prefix(&format!("{name}=")) {
                let val = rest.trim();
                if !val.is_empty() && val != "deleted" {
                    return Some(val.to_string());
                }
            }
        }
    }
    None
}

/// PoW：`y = x`，重复 `t` 次 `y = y² mod N`，返回十六进制。
///
/// # 证据
/// ```text
/// 算法来自站点自己的 `pow.worker-*.js`（逐字）：
///   const N=BigInt('0x'+data.N); let y=BigInt('0x'+data.x); for(...t...) y=(y*y)%N
/// 并用**真 challenge** 在 Python 里复算后提交，站点返回 `{"success":true}` ⇒ 算法对。
/// ```
/// ⚠️ 用 `rsa::BigUint`（`rsa` 已是本仓直接依赖，`pub use num_bigint::BigUint`）——
/// 不新增依赖、不新增运行时。
pub fn pow_solve(n_hex: &str, x_hex: &str, t: u32) -> Result<String, String> {
    use rsa::BigUint;
    let n = BigUint::parse_bytes(n_hex.trim().as_bytes(), 16)
        .ok_or_else(|| format!("N 不是十六进制（长度 {}）", n_hex.len()))?;
    let mut y = BigUint::parse_bytes(x_hex.trim().as_bytes(), 16)
        .ok_or_else(|| format!("x 不是十六进制（长度 {}）", x_hex.len()))?;
    if n == BigUint::from(0u8) {
        return Err("N 为 0（challenge 坏了）".to_string());
    }
    for _ in 0..t {
        y = (&y * &y) % &n;
    }
    Ok(y.to_str_radix(16))
}

// ═══════════════════════════════════════════════════════════════════════
//  页面状态 + 解析（`_obj.*` 内联 JSON）
// ═══════════════════════════════════════════════════════════════════════

/// 页面属于哪种形态
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PageState {
    /// 登录墙（真响应标题「未登录，访问受限」，正文只有 `_obj.header`）
    LoginWall,
    /// 有 `_obj.<key>` 数据块
    HasObj(&'static str),
    /// 什么都没有（模板改版/壳页）
    Unknown,
}

/// 判定页面形态（**先判登录墙**，因为它也有 `_obj.header`，容易被误认为"有数据"）
pub fn page_state(html: &str) -> PageState {
    if html.contains(LOGIN_WALL_TITLE) || html.contains("nologin") {
        return PageState::LoginWall;
    }
    for key in ["inlist", "search", "d"] {
        if obj_json(html, key).is_some() {
            return match key {
                "inlist" => PageState::HasObj("inlist"),
                "search" => PageState::HasObj("search"),
                _ => PageState::HasObj("d"),
            };
        }
    }
    PageState::Unknown
}

/// 从页面里抠出 `_obj.<key>={…};` 的 JSON（DEX 的 regex 口径：`_obj\.<key>=(\{.*?\});\s*_obj`）
pub fn obj_json(html: &str, key: &str) -> Option<Value> {
    static RES: OnceLock<Mutex<std::collections::HashMap<String, Regex>>> = OnceLock::new();
    let map = RES.get_or_init(|| Mutex::new(std::collections::HashMap::new()));
    let re = {
        let mut g = map.lock().ok()?;
        g.entry(key.to_string())
            .or_insert_with(|| {
                Regex::new(&format!(r#"(?s)_obj\.{}=(\{{.*?\}});\s*_obj"#, regex::escape(key)))
                    .expect("guan_ying obj regex")
            })
            .clone()
    };
    let cap = re.captures(html)?;
    crate::tvbox::parse_loose_json(cap.get(1)?.as_str()).ok()
}

fn first_str(v: &Value, keys: &[&str]) -> Option<String> {
    for k in keys {
        if let Some(s) = v.get(*k).and_then(|x| x.as_str()) {
            if !s.trim().is_empty() {
                return Some(s.trim().to_string());
            }
        }
        if let Some(n) = v.get(*k).and_then(|x| x.as_i64()) {
            return Some(n.to_string());
        }
    }
    None
}

/// 从 `_obj.inlist` / `_obj.search` 里取条目
///
/// ⚠️ 字段名是**推断**（DEX 常量 i/t/a/g/ty 与 vod_*），所以写成多候选键；
///    真样本没拿到（整站登录），夹具明写「重构样本」。
pub fn items_of(v: &Value) -> Vec<CspItem> {
    let arr = v
        .get("list")
        .and_then(|x| x.as_array())
        .or_else(|| v.get("data").and_then(|x| x.as_array()))
        .or_else(|| v.as_array());
    let Some(arr) = arr else { return Vec::new() };
    let mut out = Vec::new();
    for it in arr {
        let Some(id) = first_str(it, &["id", "i", "vod_id", "vid"]) else {
            continue;
        };
        let Some(title) = first_str(it, &["name", "t", "title", "vod_name"]) else {
            continue;
        };
        out.push(CspItem {
            id,
            title,
            cover: first_str(it, &["pic", "p", "cover", "vod_pic"]),
            subtitle: first_str(it, &["remarks", "r", "note", "vod_remarks"]),
        });
    }
    out
}

/// 从 `_obj.d` 里取详情（标题/封面/简介/剧集）
pub fn detail_of(v: &Value) -> Option<CspDetail> {
    let title = first_str(v, &["name", "t", "title", "vod_name"])
        .or_else(|| first_str(v.get("info").unwrap_or(&Value::Null), &["title", "name"]))?;
    let mut episodes: Vec<CspEpisode> = Vec::new();
    if let Some(arr) = v.get("list").and_then(|x| x.as_array()) {
        for (i, ep) in arr.iter().enumerate() {
            let url = first_str(ep, &["url", "p", "play_url", "link"]).unwrap_or_default();
            if url.is_empty() {
                continue;
            }
            let name = first_str(ep, &["name", "n", "title"]).unwrap_or_else(|| format!("线路{}", i + 1));
            episodes.push(CspEpisode {
                id: url,
                title: name,
                flag: "观影".to_string(),
            });
        }
    }
    Some(CspDetail {
        id: String::new(),
        title,
        cover: first_str(v, &["pic", "cover", "vod_pic"]),
        description: first_str(v, &["desc", "content", "intro", "vod_content"]),
        episodes,
    })
}

/// 登录墙的**统一错误文案**（三个方法共用，避免文案漂）
fn login_wall_err(where_: &str) -> String {
    format!(
        "{where_}：站点返回「{LOGIN_WALL_TITLE}」——PoW（browser_verified）已过，\
         但内容还要**账号登录**（DEX 里是 /user/login + PHPSESSID/app_auth）。\
         本仓没有该站账号 ⇒ 取不到数据。订阅里该源的 ext 也是 null（没有账号可配）。\
         已实现并真网验证的只有 PoW 这一段；解析器 `_obj.inlist/search/d` 结构待登录态样本证伪。"
    )
}

// ═══════════════════════════════════════════════════════════════════════
//  CspSite 实现（**没有 register_site!**）
// ═══════════════════════════════════════════════════════════════════════

#[async_trait]
impl CspSite for GuanYing {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    async fn home(&self, _ext: &str) -> Result<CspHome, String> {
        self.ensure_verified().await?;
        let html = self.get("/").await?;
        match page_state(&html) {
            PageState::LoginWall => Err(login_wall_err("首页")),
            PageState::HasObj("inlist") => {
                let v = obj_json(&html, "inlist").ok_or_else(|| "inlist 解析失败".to_string())?;
                let items = items_of(&v);
                if items.is_empty() {
                    return Err("首页 inlist 里没有条目（模板可能改版）".to_string());
                }
                Ok(CspHome {
                    categories: TYPES
                        .iter()
                        .map(|(id, name)| CspCategory {
                            id: (*id).to_string(),
                            name: (*name).to_string(),
                        })
                        .collect(),
                    items,
                })
            }
            _ => Err(format!(
                "首页没有 `_obj.inlist`（模板可能改版/风控壳页）· 页面长度 {} 字节",
                html.len()
            )),
        }
    }

    async fn list(&self, tid: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let tid = if tid.trim().is_empty() { "rec" } else { tid.trim() };
        self.ensure_verified().await?;
        let page = page.max(1);
        let path = if tid == "rec" {
            "/".to_string()
        } else if page == 1 {
            format!("/{tid}/")
        } else {
            format!("/{tid}/?page={page}")
        };
        let html = self.get(&path).await?;
        match page_state(&html) {
            PageState::LoginWall => Err(login_wall_err("分类列表")),
            PageState::HasObj("inlist") => {
                let v = obj_json(&html, "inlist").ok_or_else(|| "inlist 解析失败".to_string())?;
                let items = items_of(&v);
                if items.is_empty() {
                    return Err(format!("分类 {tid} 第 {page} 页 inlist 里没有条目（模板可能改版）"));
                }
                Ok(CspList {
                    items,
                    page,
                    page_count: None,
                    total: None,
                })
            }
            _ => Err(format!(
                "分类 {tid} 第 {page} 页没有 `_obj.inlist`（模板可能改版/风控壳页）"
            )),
        }
    }

    async fn search(&self, kw: &str, page: u32, _ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        self.ensure_verified().await?;
        let page = page.max(1);
        let path = format!(
            "/search?q={}{}",
            urlencoding::encode(kw),
            if page > 1 { format!("&page={page}") } else { String::new() }
        );
        let html = self.get(&path).await?;
        match page_state(&html) {
            PageState::LoginWall => Err(login_wall_err("搜索")),
            PageState::HasObj("search") | PageState::HasObj("inlist") => {
                let v = obj_json(&html, "search")
                    .or_else(|| obj_json(&html, "inlist"))
                    .ok_or_else(|| "search 解析失败".to_string())?;
                let items = items_of(&v);
                if items.is_empty() {
                    return Err(format!("搜索「{kw}」没有条目（可能真没结果/模板改版）"));
                }
                Ok(CspList {
                    items,
                    page,
                    page_count: None,
                    total: None,
                })
            }
            _ => Err(format!("搜索「{kw}」页没有 `_obj.search`（模板可能改版/风控壳页）")),
        }
    }

    fn supports_search(&self) -> bool {
        // ★ 未实测（登录墙挡住）⇒ 不声明 true（与 AppFox 同口径）
        false
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("详情 id 为空".to_string());
        }
        self.ensure_verified().await?;
        let html = self.get(&format!("/{id}")).await?;
        match page_state(&html) {
            PageState::LoginWall => Err(login_wall_err("详情")),
            PageState::HasObj("d") => {
                let v = obj_json(&html, "d").ok_or_else(|| "d 解析失败".to_string())?;
                let mut d = detail_of(&v)
                    .ok_or_else(|| "`_obj.d` 里没有标题（字段名可能变了）".to_string())?;
                if d.episodes.is_empty() {
                    return Err(format!("「{}」没有可播剧集（`_obj.d` 无 list/url）", d.title));
                }
                d.id = id.to_string();
                Ok(d)
            }
            _ => Err(format!("详情页没有 `_obj.d`（模板可能改版/风控壳页）：{id}")),
        }
    }

    async fn play(&self, flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("播放 id 为空".to_string());
        }
        if id.starts_with("http") {
            return Ok(vec![CspPlay {
                url: id.to_string(),
                headers: vec![
                    ("Referer".to_string(), format!("{}/", self.host)),
                    ("User-Agent".to_string(), UA.to_string()),
                ],
                label: Some(format!("{flag}（网盘分享页）")),
            }]);
        }
        Err(format!(
            "取流需要登录态（DEX 的 jfl|/jfp| 形态由登录页下发），当前是游客；\
             `{id}` 不是 http 地址，不做假通"
        ))
    }
}

// ⚠️ **没有 `register_site!`**：判据第 ③ 条（真网取到数据）不成立 —— 整站登录墙。

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// ★ 真响应片段（2026-10-28 抓自 `https://www.xn--wcv59z.com/`，带 browser_verified 之后）
    ///
    /// 原文 828 B，这里保留 `<title>`、`_obj.header` 与 `nologin` 三处关键标记。
    const FIX_LOGIN_WALL: &str = r#"<!DOCTYPE html><html><head><title>未登录，访问受限</title>
<script src="//static.1234cdn.com/static/cache/js/nologin-e7c074d3.js"></script></head>
<body><script> _obj.header={"q":"","t":"","p":"","l":"home","n":"","u":[]};_obj.footer={t:'1.1'}; _BT.PC.HTML('nologin');</script></body></html>"#;

    /// ⚠️ **重构样本**（不是真响应）：字段名按 DEX 常量（i/t/p、vod_*）拼出来的最小形态
    const FIX_INLIST: &str = r#"<script> _obj.inlist={"list":[{"i":123,"t":"示例片名","p":"https://img.example/a.jpg","r":"4K"},{"vod_id":"456","vod_name":"第二部","vod_pic":"https://img.example/b.jpg"}]};_obj.foot={};</script>"#;

    const FIX_DETAIL_RECON: &str = r#"<script> _obj.d={"name":"示例片名","pic":"https://img.example/a.jpg","desc":"简介文本","list":[{"name":"线路1","url":"https://pan.quark.cn/s/abc"}]};_obj.x={};</script>"#;

    #[test]
    fn class_name_is_exact() {
        assert_eq!(GuanYing::CLASS, "GuanYing");
    }

    /// ★ 算法向量：小 challenge 用 Python 算出的期望值（t=8，N 为 256bit）
    #[test]
    fn pow_solve_matches_the_reference_vector() {
        let n = "c1f7a3b9d5e64f0213ab89cd77e55a4b3d9f1188a2c7e40566bb90ee22ff3345";
        let x = "9f2c4a6b8d0e1f3579bdf2468ace13579bdf02468ace13579bdf02468ace1357";
        assert_eq!(
            pow_solve(n, x, 8).unwrap(),
            "100de08be71b3dbb022dfd00e2856d1031cdce7fdabaf2ba1e91f0f83669ca06",
            "★ 与 pow.worker 的算法一致性（独立实现的期望值）"
        );
        // t=0 ⇒ y=x（边界）
        assert_eq!(pow_solve(n, x, 0).unwrap(), x);
        // 坏输入 ⇒ Err（不 panic、不返回 0）
        assert!(pow_solve("zz", x, 1).is_err());
        assert!(pow_solve(n, "zz", 1).is_err());
    }

    #[test]
    fn login_wall_is_detected_before_the_fake_obj() {
        // ★ 登录墙页面里**也有** `_obj.header` —— 先判墙，否则会被当成"有数据"
        assert_eq!(page_state(FIX_LOGIN_WALL), PageState::LoginWall);
        assert_eq!(page_state(FIX_INLIST), PageState::HasObj("inlist"));
        assert_eq!(page_state("<html><body>x</body></html>"), PageState::Unknown);
    }

    #[test]
    fn inlist_items_parse_with_multiple_key_candidates() {
        let v = obj_json(FIX_INLIST, "inlist").expect("要能抠出 _obj.inlist");
        let items = items_of(&v);
        assert_eq!(items.len(), 2, "两种键形态（i/t 与 vod_*）都要认：{items:?}");
        assert_eq!(items[0].id, "123");
        assert_eq!(items[0].title, "示例片名");
        assert_eq!(items[1].id, "456");
        assert_eq!(items[1].title, "第二部");
        // 空 ⇒ 空（由调用方转 Err；这里只证明"不会凭空造条目"）
        assert!(items_of(&json!({"list": []})).is_empty());
    }

    #[test]
    fn detail_obj_maps_title_and_episodes() {
        let v = obj_json(FIX_DETAIL_RECON, "d").expect("要能抠出 _obj.d");
        let d = detail_of(&v).expect("要有标题");
        assert_eq!(d.title, "示例片名");
        assert_eq!(d.episodes.len(), 1);
        assert_eq!(d.episodes[0].id, "https://pan.quark.cn/s/abc");
        assert_eq!(d.episodes[0].flag, "观影");
    }

    #[tokio::test]
    async fn every_segment_reports_the_login_wall_not_an_empty_list() {
        // 直接调解析层之外的行为：没有 cookie 的实例在真网会握手；
        // 这里只测**文案函数**与"空 ⇒ Err"的构造（不联网）
        let e = login_wall_err("首页");
        assert!(e.contains(LOGIN_WALL_TITLE), "{e}");
        assert!(e.contains("账号登录"), "{e}");
        assert!(e.contains("没有该站账号"), "{e}");
        // play 对非 http 的 id 必须 Err（不许假通）
        let s = GuanYing::new();
        let pe = s.play("观影", "jfl|abc", "").await.expect_err("非 http 必须 Err");
        assert!(pe.contains("不做假通"), "{pe}");
    }

    #[test]
    fn it_is_not_registered_this_batch() {
        let flat = crate::csp::shared::impl_src_only(include_str!("guan_ying.rs"));
        assert!(!flat.contains("register_site!(GuanYing)"), "★ 本批 GuanYing 不注册");
        assert!(
            !crate::csp::is_implemented("csp_GuanYing"),
            "★ 不许进注册表（真网取不到数据）"
        );
    }

    #[test]
    fn hosts_are_the_dex_mirrors_verbatim() {
        assert_eq!(HOSTS.len(), 4);
        assert_eq!(HOSTS[0], "https://www.xn--wcv59z.com");
        // 解码自检：punycode 前缀形态（教父/肖申克/盗梦/星际）
        assert!(HOSTS[1].contains("xn--74qz10cqsltibh40akss"));
    }

    #[tokio::test]
    #[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp::guan_ying::tests::guanying_live -- --ignored --nocapture"]
    async fn guanying_live() {
        assert_eq!(
            std::env::var("CSP_LIVE").ok().as_deref(),
            Some("1"),
            "显式跑这条就必须给 CSP_LIVE=1（不给就失败，而不是悄悄通过）"
        );
        let s = GuanYing::new();
        // ① PoW 必须真的通过（这是本类唯一被真网验证过的一段）
        let hs = s.handshake().await.expect("PoW 握手必须成功");
        println!("LIVE|guanying|pow|{hs}");
        // ② 过了 PoW 仍然是登录墙 —— 如实打印，不断言"有数据"
        match s.home("").await {
            Ok(h) => println!(
                "LIVE|guanying|home|分类={} 条目={}（意外：居然拿到数据）",
                h.categories.len(),
                h.items.len()
            ),
            Err(e) => println!("LIVE|guanying|home|ERR|{e}"),
        }
    }
}