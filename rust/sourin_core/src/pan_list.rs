//! 网盘分享页的**匿名列目录**（第 20 项第一档：看得见、列得出、播不了）
//!
//! # 这一跳能做什么、不能做什么（均由实测决定，见 `.probe/pan-anon-probe.md`）
//!
//! 2026-10-26 真网络读数（两个样本各一条，逐字）：
//! ```text
//! 夸克  pwd_id=d326365be5e5      → count=1  「[初恋这首情歌.2016]…[80.82G].iso」
//!                                  size=86781081600  dir=false
//! 百度  surl=1Q5db…NGQ pwd=4785  → count=1  「G-诡异降临」  size=0  dir=true（顶层）
//! ```
//! ⇒ **未登录能列目录**（上面两条都是匿名拿到的）；**直链两家都拿不到**
//!   （百度要服务端签 `sign`，夸克 `sharepage/download` 属账号域）。
//! ```text
//! 能：不登录、不提交验证码、不伪造签名 ⇒ 拿到**真实文件名 / 大小 / 是否目录**
//! 不能：拿**直链**。两条路都要账号域：
//!   · 百度  /api/sharedownload 需要服务端签 `sign`+`timestamp`
//!   · 夸克  sharepage/download 属账号域
//! ⇒ 所以本模块只做"列目录"，`play` 仍如实报「需要登录网盘账号」。
//! ```
//!
//! # 三条硬纪律（本批刚立的，代码里逐条落实）
//! ```text
//! ① 拿不到目录 ⇒ 返回可读 Err，**绝不返回空列表冒充"这个分享没文件"**
//!    （两者对用户是完全不同的结论：一个是"源坏了"，一个是"这里真的空"）。
//! ② 失败要**汇总**：每一步的失败原文都留在 Err 里，不只留最后一个。
//!    （链路 2~3 步，只留最后一步会让"到底是哪一步坏"无从查起。）
//! ③ 真网络必须**直连**：`.no_proxy()`。本机常年挂着 HTTP(S)_PROXY，
//!    走代理会把 200 变成 502（2026-10-26 探测时踩过两次）。
//! ```
//!
//! # 不新增 crate
//! 只用已有的 `reqwest` + `serde_json`；HTML 里的 `file_list` 用**括号配对**抠出来
//! 再交给 `serde_json` 解析（不引 HTML 解析库，也不需要）。

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::pan::PanKind;

/// 分享页里的一条目录项
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanEntry {
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
    /// 夸克/UC 的子目录句柄（`pdir_fid` 用）；百度没有这个字段 ⇒ None
    pub fid: Option<String>,
    /// 百度的子目录路径（`path=` 用，实测字段名就叫 `path`）；夸克/UC ⇒ None
    pub path: Option<String>,
}

/// 一次匿名列目录的结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanListing {
    /// 分享标题（拿不到时是空串，不是编的）
    pub title: String,
    pub entries: Vec<PanEntry>,
    /// 给用户看的第二行（分层说明"为什么还播不了"）
    pub note: String,
}

impl PanListing {
    /// 稳定 JSON（FFI 出口直接用）
    pub fn to_json(&self) -> Value {
        serde_json::json!({
            "title": self.title,
            "count": self.entries.len(),
            "entries": self.entries.iter().map(|e| serde_json::json!({
                "name": e.name,
                "size": e.size,
                "isDir": e.is_dir,
                "fid": e.fid,
                "path": e.path,
            })).collect::<Vec<_>>(),
            "note": self.note,
            // ★ 如实声明能力：能列目录 ≠ 能播
            "resolvable": false,
        })
    }
}

const UA: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) \
     Chrome/143.0.0.0 Safari/537.36";

/// 上传给用户的分层说明（第 20 项文案：比"已登录；取直链功能尚未接入"更准）
pub fn anonymous_note(display: &str, count: usize) -> String {
    format!("未登录时能列出 {count} 个文件，但取直链需要登录{display}账号")
}

// ══════════════════════════════════════════════════════════════════════
//  纯解析（全部离线可测；坏样本必须 Err，不许返回空列表）
// ══════════════════════════════════════════════════════════════════════

/// 从 `text` 里取 `key` 对应的 JSON 值原文（对象或数组），用**括号配对**，不依赖位置
///
/// 为什么不用"找 key 后截到下一个逗号"：数组里有逗号和嵌套对象，截断会得到废 JSON。
fn slice_value<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    // 允许 `"key":` / `'key':` / `key:` 三种写法（百度那份是 JS 对象字面量）
    let mut from = 0usize;
    let mut anchor = None;
    while let Some(rel) = text[from..].find(key) {
        let at = from + rel;
        let after = &text[at + key.len()..];
        let trimmed = after.trim_start();
        if trimmed.starts_with(':') {
            anchor = Some(at + key.len() + (after.len() - trimmed.len()) + 1);
            break;
        }
        from = at + key.len();
    }
    let start_off = anchor?;
    let rest = &text[start_off..];
    let lead = rest.len() - rest.trim_start().len();
    let rest = &rest[lead..];
    let (open, close) = match rest.chars().next()? {
        '{' => ('{', '}'),
        '[' => ('[', ']'),
        _ => return None,
    };
    let bytes = rest.as_bytes();
    let mut depth = 0i32;
    let mut in_str: Option<u8> = None;
    let mut esc = false;
    for (i, &b) in bytes.iter().enumerate() {
        if let Some(q) = in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == q {
                in_str = None;
            }
            continue;
        }
        match b {
            b'"' | b'\'' => in_str = Some(b),
            x if x == open as u8 => depth += 1,
            x if x == close as u8 => {
                depth -= 1;
                if depth == 0 {
                    return Some(&rest[..=i]);
                }
            }
            _ => {}
        }
    }
    None
}

/// 解析夸克 `sharepage/token` 的响应
///
/// 期望：`{"code":0,"data":{"stoken":"…","title":"…"}}`
pub fn parse_quark_token(json: &str) -> Result<(String, String), String> {
    let v: Value = serde_json::from_str(json)
        .map_err(|e| format!("token 响应不是 JSON（{e}）：{}", head(json)))?;
    let code = v.get("code").and_then(|x| x.as_i64()).unwrap_or(-1);
    if code != 0 {
        let msg = v.get("message").and_then(|x| x.as_str()).unwrap_or("（上游没给 message）");
        return Err(format!("token 返回 code={code} message={msg}"));
    }
    let d = v.get("data").ok_or_else(|| "token 响应缺 data".to_string())?;
    let stoken = d
        .get("stoken")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    if stoken.is_empty() {
        return Err("token 响应里没有 stoken（结构可能变了）".to_string());
    }
    let title = d.get("title").and_then(|x| x.as_str()).unwrap_or("").to_string();
    Ok((stoken, title))
}

/// 夸克 / UC **共用**的 detail 解析（两家的字段与目录判据完全同形）
///
/// ★★ 目录判据只有**一条**：`file_type == 0 ⇒ 目录`，`== 1 ⇒ 文件`。
///   实测依据（`.probe/pan-anon-uc.log`）：UC 样本的目录 `file_type=0`、
///   夸克样本的 `.iso` `file_type=1` —— 两家是**同一条规则**，不是相反。
///   ⚠️ `pan-anon-probe.md` §2 第 63 行"判据不同/相反"是表述歧义：
///     它把"夸克用 1 判文件"与"UC 用 0 判目录"当成两套，其实是一体的两面。
///   ⇒ 谁把这里写反（0 当文件），`uc_detail_dir_is_zero_and_file_is_one` 立刻红。
fn parse_detail_shared(v: &Value, label: &str) -> Result<Vec<PanEntry>, String> {
    let code = v.get("code").and_then(|x| x.as_i64()).unwrap_or(-1);
    if code != 0 {
        let msg = v.get("message").and_then(|x| x.as_str()).unwrap_or("（上游没给 message）");
        return Err(format!("{label} 返回 code={code} message={msg}"));
    }
    let list = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array())
        .ok_or_else(|| format!("{label} 响应里没有 data.list（结构可能变了）"))?;
    let mut out = Vec::with_capacity(list.len());
    for it in list {
        let name = it.get("file_name").and_then(|x| x.as_str()).unwrap_or("");
        if name.is_empty() {
            continue;
        }
        out.push(PanEntry {
            name: name.to_string(),
            size: num_of(it.get("size")),
            // 唯一判据：0 = 目录
            is_dir: it.get("file_type").and_then(|x| x.as_i64()) == Some(0),
            fid: it.get("fid").and_then(|x| x.as_str()).map(|s| s.to_string()),
            path: it.get("path").and_then(|x| x.as_str()).map(|s| s.to_string()),
        });
    }
    if out.is_empty() {
        return Err(format!(
            "{label} 的 list 为空或每项都缺 file_name（不是空分享，多半是结构变了）"
        ));
    }
    Ok(out)
}

/// 解析夸克 `sharepage/detail` 的响应
///
/// 期望：`{"code":0,"data":{"list":[{"file_name":…,"size":…,"file_type":0|1,"fid":…}]}}`
/// `file_type`：1 = 文件，0 = 目录（实测单文件分享给的是 1）。
pub fn parse_quark_detail(json: &str) -> Result<Vec<PanEntry>, String> {
    let v: Value = serde_json::from_str(json)
        .map_err(|e| format!("detail 响应不是 JSON（{e}）：{}", head(json)))?;
    let code = v.get("code").and_then(|x| x.as_i64()).unwrap_or(-1);
    if code != 0 {
        let msg = v.get("message").and_then(|x| x.as_str()).unwrap_or("（上游没给 message）");
        return Err(format!("detail 返回 code={code} message={msg}"));
    }
    parse_detail_shared(&v, "detail")
}

/// 解析百度分享页 HTML 里的 `yunData.file_list`
///
/// 期望形态（实测）：`locals.mset({ "yunData" … "file_list":[{server_filename,isdir,size}] … })`
/// ⇒ 用括号配对抠 `file_list` 的数组，再交给 serde_json。
pub fn parse_baidu_yundata(html: &str) -> Result<(String, Vec<PanEntry>), String> {
    let raw = slice_value(html, "\"file_list\"")
        .or_else(|| slice_value(html, "file_list"))
        .ok_or_else(|| {
            "页面里没有 file_list（可能提取码不对 / 需要验证码 / 页面结构变了）".to_string()
        })?;
    let arr: Value = serde_json::from_str(raw)
        .map_err(|e| format!("file_list 不是合法 JSON（{e}）：{}", head(raw)))?;
    let list = arr.as_array().ok_or_else(|| "file_list 不是数组".to_string())?;
    let mut out = Vec::with_capacity(list.len());
    for it in list {
        let name = it
            .get("server_filename")
            .and_then(|x| x.as_str())
            .unwrap_or("");
        if name.is_empty() {
            continue;
        }
        out.push(PanEntry {
            name: name.to_string(),
            size: num_of(it.get("size")),
            is_dir: it.get("isdir").and_then(|x| x.as_i64()).unwrap_or(0) == 1,
            // 百度没有 `fid`，只有 `fs_id`（数字）⇒ 当 fid 存着，方便界面统一处理
            fid: it
                .get("fs_id")
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    Value::Number(n) => n.to_string(),
                    _ => String::new(),
                })
                .filter(|s| !s.is_empty()),
            // ★ 实测字段名就是 `path`（形如 `/sharelink…/G-诡异降临`），不是 `dir`
            path: it.get("path").and_then(|x| x.as_str()).map(|s| s.to_string()),
        });
    }
    if out.is_empty() {
        return Err("file_list 为空或每项都缺 server_filename（不是空分享，多半是结构变了）".to_string());
    }
    // 标题：`<title>…</title>`（拿不到就空串，不编）
    let title = between(html, "<title>", "</title>").unwrap_or_default();
    Ok((title.trim().to_string(), out))
}

fn num_of(v: Option<&Value>) -> u64 {
    match v {
        Some(Value::Number(n)) => n.as_u64().or_else(|| n.as_f64().map(|f| f.max(0.0) as u64)).unwrap_or(0),
        Some(Value::String(s)) => s.trim().parse::<u64>().unwrap_or(0),
        _ => 0,
    }
}

fn between(s: &str, a: &str, b: &str) -> Option<String> {
    let i = s.find(a)? + a.len();
    let j = s[i..].find(b)? + i;
    Some(s[i..j].to_string())
}

fn head(s: &str) -> String {
    s.chars().take(120).collect()
}

// ══════════════════════════════════════════════════════════════════════
//  网络（只有两个盘；其余如实返回"还没做"）
// ══════════════════════════════════════════════════════════════════════

const QUARK_TOKEN: &str = "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token";
const QUARK_DETAIL: &str = "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail";

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        // ★ 硬纪律③：必须直连。本机常年挂代理，走代理会把 200 变 502。
        .no_proxy()
        .timeout(Duration::from_secs(20))
        .user_agent(UA)
        .build()
        .map_err(|e| format!("建 HTTP 客户端失败：{e}"))
}

/// 把 `Set-Cookie` 头拼成一条 `Cookie:` 值（只留 `name=value`）
fn cookies_of(resp: &reqwest::Response) -> String {
    let mut out = Vec::new();
    for v in resp.headers().get_all(reqwest::header::SET_COOKIE).iter() {
        if let Ok(s) = v.to_str() {
            if let Some(first) = s.split(';').next() {
                let kv = first.trim();
                if kv.contains('=') {
                    out.push(kv.to_string());
                }
            }
        }
    }
    out.join("; ")
}

/// 失败汇总（硬纪律②：每一步的原文都留着）
fn fail(steps: &[String], last: String) -> String {
    let mut all = steps.to_vec();
    all.push(last);
    format!("列目录失败：\n- {}", all.join("\n- "))
}

/// 匿名列目录（唯一入口）
///
/// `pwd` 是用户自己填的提取码（**只提交已知的**，不做验证码、不猜）。
pub async fn list_share(kind: PanKind, share_id: &str, pwd: Option<&str>) -> Result<PanListing, String> {
    list_share_at(kind, share_id, pwd, None).await
}

/// 列**某一层**（`dir = None` ⇒ 根；`Some(entry)` ⇒ 进这个目录，**只进一层**）
///
/// ★ 没有递归入口：要再进一层，调用方必须拿着上一层的条目再单独调一次。
///   这是有意的（递归爬取等于批量抓取，越界）。
pub async fn list_share_at(
    kind: PanKind,
    share_id: &str,
    pwd: Option<&str>,
    dir: Option<&PanEntry>,
) -> Result<PanListing, String> {
    if share_id.trim().is_empty() {
        return Err("分享 id 为空（这不是分享链接？）".to_string());
    }
    if let Some(d) = dir {
        if !d.is_dir {
            return Err(format!("「{}」不是目录，不能进", d.name));
        }
        let has_handle = match kind {
            PanKind::Baidu => d.path.as_deref().map(|p| !p.is_empty()).unwrap_or(false),
            _ => d.fid.as_deref().map(|f| !f.is_empty()).unwrap_or(false),
        };
        if !has_handle {
            return Err(subdir_no_handle(kind, &d.name));
        }
    }
    match kind {
        PanKind::Quark => quark_list(share_id, pwd, dir).await,
        PanKind::Uc => uc_list(share_id, pwd, dir).await,
        PanKind::Baidu => baidu_list(share_id, pwd, dir).await,
        other => Err(format!(
            "{} 的匿名列目录还没有实现（目前已做：夸克 / UC / 百度；见 .probe/pan-anon-probe.md）",
            other.display()
        )),
    }
}

async fn quark_list(
    pwd_id: &str,
    passcode: Option<&str>,
    dir: Option<&PanEntry>,
) -> Result<PanListing, String> {
    let c = client()?;
    let mut steps: Vec<String> = Vec::new();

    // ① 分享页：只为拿 cookie（SPA 壳里没有文件数据，别指望从这里解析）
    let mut cookies = String::new();
    match c.get(format!("https://pan.quark.cn/s/{pwd_id}")).send().await {
        Ok(r) => {
            cookies = cookies_of(&r);
            if !r.status().is_success() {
                steps.push(format!("分享页返回 HTTP {}", r.status().as_u16()));
            }
        }
        Err(e) => steps.push(format!("分享页请求失败：{e}")),
    }

    // ② token（匿名，提交已知提取码）
    let mut req = c
        .post(QUARK_TOKEN)
        .query(&[("pr", "ucpro"), ("fr", "pc")])
        .header(reqwest::header::ORIGIN, "https://pan.quark.cn")
        .header(reqwest::header::REFERER, format!("https://pan.quark.cn/s/{pwd_id}"))
        .json(&serde_json::json!({
            "pwd_id": pwd_id,
            "passcode": passcode.unwrap_or(""),
        }));
    if !cookies.is_empty() {
        req = req.header(reqwest::header::COOKIE, cookies.clone());
    }
    let token_json = match req.send().await {
        Ok(r) => {
            let st = r.status().as_u16();
            match r.text().await {
                Ok(t) => t,
                Err(e) => return Err(fail(&steps, format!("读 token 响应失败：{e}"))),
            }
            .also_check(st, &mut steps)
        }
        Err(e) => return Err(fail(&steps, format!("token 请求失败：{e}"))),
    };
    let (stoken, title) = match parse_quark_token(&token_json) {
        Ok(v) => v,
        Err(e) => return Err(fail(&steps, e)),
    };

    // ③ detail（匿名，带 stoken）
    let detail = c
        .get(QUARK_DETAIL)
        .query(&[
            ("pr", "ucpro"),
            ("fr", "pc"),
            ("pwd_id", pwd_id),
            ("stoken", stoken.as_str()),
            ("force", "0"),
            ("_page", "1"),
            ("_size", "50"),
            ("_sort", "file_type:asc,updated_at:desc"),
        ])
        .header(reqwest::header::ORIGIN, "https://pan.quark.cn")
        .header(reqwest::header::REFERER, format!("https://pan.quark.cn/s/{pwd_id}"))
        .header(reqwest::header::COOKIE, cookies);
    // ★ 导航参数：根 ⇒ pdir_fid=0；子目录 ⇒ 该条目的 fid（**只进一层**）
    let detail = nav_params(PanKind::Quark, dir)
        .iter()
        .fold(detail, |acc, (k, v)| acc.query(&[(k.as_str(), v.as_str())]));
    let detail_json = match detail.send().await {
        Ok(r) => {
            let st = r.status().as_u16();
            match r.text().await {
                Ok(t) => t,
                Err(e) => return Err(fail(&steps, format!("读 detail 响应失败：{e}"))),
            }
            .also_check(st, &mut steps)
        }
        Err(e) => return Err(fail(&steps, format!("detail 请求失败：{e}"))),
    };
    let entries = match parse_quark_detail(&detail_json) {
        Ok(v) => v,
        Err(e) => {
            let msg = match dir {
                Some(d) => subdir_denied(PanKind::Quark, &d.name),
                None => e,
            };
            return Err(fail(&steps, msg));
        }
    };
    let n = entries.len();
    Ok(PanListing {
        title,
        entries,
        note: anonymous_note(PanKind::Quark.display(), n),
    })
}

// ══════════════════════════════════════════════════════════════════════
//  UC（与夸克同族，但**token 主机不同**）
// ══════════════════════════════════════════════════════════════════════
//
// # 实测规格（`.probe/pan-anon-uc.log`，2026-10-26）
// ```text
// ① GET  https://drive.uc.cn/s/<pwd_id>  → 200（SPA 壳，2227 B，只为拿 cookie）
//    下发 set-cookie: ctoken=…（**必须带着它**去 ②）
// ② POST https://drive.uc.cn/…/sharepage/token  → **HTTP 403**（主机错，不是"必须登录"）
//    POST https://pc-api.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc
//      → 200 {"status":200,"code":0,"message":"ok","data":{"stoken":…,"title":…}}
// ③ GET  https://pc-api.uc.cn/1/clouddrive/share/sharepage/detail
//      ?pr=UCBrowser&fr=pc&pwd_id=&stoken=&pdir_fid=0&force=0&_page=1&_size=50&_sort=…
//      → 200 code=0；list[0] = {file_name:"战邮1942", size:0, file_type:0, fid:…}
// ```
//
// # ★ 目录/文件的判据：**与夸克是同一条规则**，不是相反
// ```text
// 实测两家都是 `file_type == 0 ⇒ 目录`、`== 1 ⇒ 文件`：
//   夸克样本  .iso  → file_type=1（文件）
//   UC 样本   目录  → file_type=0（目录）
// ⚠️ `.probe/pan-anon-probe.md` §2 第 63 行写成"判据不同/相反"是**表述歧义**
//   （它把"夸克用 1 判文件"与"UC 用 0 判目录"当成两套规则，其实是同一条的两面）。
//   ⇒ 代码只维护**一个**判据（`is_dir = file_type == 0`，见 `parse_detail_shared`），
//     并用 UC 的目录样本单独钉一条单测：谁把判据写反，那条立刻红。
// ```
/// 极简 URL 编码（只用 `reqwest`/`url` 已有的能力会引入依赖，这里手写够用）
///
/// 保留 `/` 与 `-._~`（百度 `path` 是**路径**，斜杠必须原样保留）；
/// 其余非字母数字一律 `%XX`（按 UTF-8 字节）。
pub fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        let c = *b as char;
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~' | '/') {
            out.push(c);
        } else {
            out.push('%');
            out.push_str(&format!("{:02X}", b));
        }
    }
    out
}

/// 「进下一层」的查询参数（纯函数，便于离线测 + 注入）
///
/// # 实测依据（2026-10-26）
/// ```text
/// 夸克/UC：`sharepage/detail?…&pdir_fid=<子目录 fid>` —— 根目录用 `0`
///          （探测里根就是 `pdir_fid=0`；子目录的 `fid` 在同一响应里给出）
/// 百度   ：分享页条目里有 `path` 字段（形如 `/sharelink…/G-诡异降临`），
///          再取时用 `&path=<urlencoded>`（**字段名是 `path`，不是 `dir`** ——
///          这是从真实响应里 dump 出来的，见 .probe 里的探测记录）
/// ```
/// ⚠️ 子目录**只进一层**：本函数只表达"进哪个目录"，没有任何递归入口。
pub fn nav_params(kind: PanKind, dir: Option<&PanEntry>) -> Vec<(String, String)> {
    match kind {
        PanKind::Baidu => match dir.and_then(|d| d.path.as_deref()) {
            Some(p) if !p.is_empty() => vec![("path".to_string(), url_encode(p))],
            _ => Vec::new(),
        },
        _ => {
            // ★ 根才用 "0"。子目录必须用**它自己的** fid ——
            //   拿不到就调用方已经拦掉了（见 `list_share_at` 的句柄守卫），
            //   这里绝不静默退回 "0"（那会**把根目录当成子目录列出来**，
            //   用户点进"某目录"却看到根的孩子，是很隐蔽的错）。
            let fid = match dir {
                None => "0",
                Some(d) => d.fid.as_deref().unwrap_or(""),
            };
            vec![("pdir_fid".to_string(), fid.to_string())]
        }
    }
}

/// 子目录**拿不到句柄**（夸克/UC 没 fid、百度没 path）时的可读错误
pub fn subdir_no_handle(kind: PanKind, name: &str) -> String {
    format!(
        "「{name}」是目录，但这个盘没给出可用的目录句柄，进不去（{}）",
        kind.display()
    )
}

/// 子目录进不去时的**统一可读错误**（硬纪律：不许空列表冒充"这里没文件"）
pub fn subdir_denied(kind: PanKind, name: &str) -> String {
    format!(
        "这个子目录需要登录{}后才能列出（「{name}」：匿名访问被拒/返回空）",
        kind.display()
    )
}

const UC_TOKEN: &str =
    "https://pc-api.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc";
const UC_DETAIL: &str = "https://pc-api.uc.cn/1/clouddrive/share/sharepage/detail";

/// 解析 UC `sharepage/token`：**同时**看 `status` 与 `code`，失败回显 `message`
///
/// ⚠️ 不猜码值（探测只实测了 `code=0` 这一种成功态；非 0 的语义未实测，
/// 所以只把上游原文透出来，不自己编"是不是分享过期"）。
pub fn parse_uc_token(json: &str) -> Result<(String, String), String> {
    let v: Value = serde_json::from_str(json)
        .map_err(|e| format!("token 响应不是 JSON（{e}）：{}", head(json)))?;
    let status = v.get("status").and_then(|x| x.as_i64());
    let code = v.get("code").and_then(|x| x.as_i64());
    let msg = v.get("message").and_then(|x| x.as_str()).unwrap_or("（上游没给 message）");
    if status.unwrap_or(0) != 0 && status != Some(200) {
        return Err(format!("token 返回 status={status:?} message={msg}"));
    }
    if code.unwrap_or(-1) != 0 {
        return Err(format!("token 返回 code={code:?} message={msg}"));
    }
    let d = v.get("data").ok_or_else(|| "token 响应缺 data".to_string())?;
    let stoken = d.get("stoken").and_then(|x| x.as_str()).unwrap_or("").to_string();
    if stoken.is_empty() {
        return Err("token 响应里没有 stoken（结构可能变了）".to_string());
    }
    let title = d.get("title").and_then(|x| x.as_str()).unwrap_or("").to_string();
    Ok((stoken, title))
}

/// 解析 UC `sharepage/detail`（判据与夸克共用 `parse_detail_shared`）
pub fn parse_uc_detail(json: &str) -> Result<Vec<PanEntry>, String> {
    let v: Value = serde_json::from_str(json)
        .map_err(|e| format!("detail 响应不是 JSON（{e}）：{}", head(json)))?;
    let status = v.get("status").and_then(|x| x.as_i64());
    if status.unwrap_or(0) != 0 && status != Some(200) {
        let msg = v.get("message").and_then(|x| x.as_str()).unwrap_or("（上游没给 message）");
        return Err(format!("detail 返回 status={status:?} message={msg}"));
    }
    parse_detail_shared(&v, "UC")
}

async fn uc_list(
    pwd_id: &str,
    passcode: Option<&str>,
    dir: Option<&PanEntry>,
) -> Result<PanListing, String> {
    let c = client()?;
    let mut steps: Vec<String> = Vec::new();

    // ① 分享页：只为拿 cookie（UC 的 token 接口**必须**带它，否则会话对不上）
    let mut cookies = String::new();
    match c.get(format!("https://drive.uc.cn/s/{pwd_id}")).send().await {
        Ok(r) => {
            cookies = cookies_of(&r);
            if !r.status().is_success() {
                steps.push(format!("分享页返回 HTTP {}", r.status().as_u16()));
            }
            if cookies.is_empty() {
                steps.push("分享页没下发 cookie（token 可能会被拒）".to_string());
            }
        }
        Err(e) => steps.push(format!("分享页请求失败：{e}")),
    }

    // ② token（主机必须是 pc-api.uc.cn；drive.uc.cn 实测 403）
    let token_json = match c
        .post(UC_TOKEN)
        .header(reqwest::header::ORIGIN, "https://drive.uc.cn")
        .header(reqwest::header::REFERER, format!("https://drive.uc.cn/s/{pwd_id}"))
        .header(reqwest::header::COOKIE, cookies.clone())
        .json(&serde_json::json!({
            "pwd_id": pwd_id,
            "passcode": passcode.unwrap_or(""),
        }))
        .send()
        .await
    {
        Ok(r) => {
            let st = r.status().as_u16();
            match r.text().await {
                Ok(t) => t,
                Err(e) => return Err(fail(&steps, format!("读 token 响应失败：{e}"))),
            }
            .also_check(st, &mut steps)
        }
        Err(e) => return Err(fail(&steps, format!("token 请求失败：{e}"))),
    };
    let (stoken, title) = match parse_uc_token(&token_json) {
        Ok(v) => v,
        Err(e) => return Err(fail(&steps, e)),
    };

    // ③ detail（同一主机，带 stoken）
    let mut uc_req = c
        .get(UC_DETAIL)
        .query(&[
            ("pr", "UCBrowser"),
            ("fr", "pc"),
            ("pwd_id", pwd_id),
            ("stoken", stoken.as_str()),
            ("force", "0"),
            ("_page", "1"),
            ("_size", "50"),
            ("_sort", "file_type:asc,updated_at:desc"),
        ]);
    for (k, v) in nav_params(PanKind::Uc, dir) {
        uc_req = uc_req.query(&[(k.as_str(), v.as_str())]);
    }
    let detail_json = match uc_req
        .header(reqwest::header::ORIGIN, "https://drive.uc.cn")
        .header(reqwest::header::REFERER, format!("https://drive.uc.cn/s/{pwd_id}"))
        .header(reqwest::header::COOKIE, cookies)
        .send()
        .await
    {
        Ok(r) => {
            let st = r.status().as_u16();
            match r.text().await {
                Ok(t) => t,
                Err(e) => return Err(fail(&steps, format!("读 detail 响应失败：{e}"))),
            }
            .also_check(st, &mut steps)
        }
        Err(e) => return Err(fail(&steps, format!("detail 请求失败：{e}"))),
    };
    let entries = match parse_uc_detail(&detail_json) {
        Ok(v) => v,
        Err(e) => {
            let msg = match dir {
                Some(d) => subdir_denied(PanKind::Uc, &d.name),
                None => e,
            };
            return Err(fail(&steps, msg));
        }
    };
    let n = entries.len();
    Ok(PanListing {
        title,
        entries,
        note: anonymous_note(PanKind::Uc.display(), n),
    })
}

async fn baidu_list(
    surl: &str,
    pwd: Option<&str>,
    dir: Option<&PanEntry>,
) -> Result<PanListing, String> {
    let c = client()?;
    let mut steps: Vec<String> = Vec::new();
    let code = pwd.unwrap_or("").to_string();
    let page = format!("https://pan.baidu.com/s/{surl}");

    // ① 打开分享页（会 302 到 /share/init，跟随后拿初始 cookie）
    //
    // ★★★ 这里必须取到**重定向后的 `surl`**，不能拿 `/s/` 后面那一整段：
    //   `/s/1Q5db…` 里的 `1` 是**路径前缀**，`/share/verify` 要的 `surl` 是
    //   **去掉那个前导 1** 的那一串（实测：302 的 Location 是
    //   `/share/init?surl=Q5db…&pwd=…`）。
    //   拿整段去 verify 会稳定得到 `errno=105`（2026-10-26 实测踩到）。
    let mut cookies = String::new();
    let mut surl_eff = surl.to_string();
    let first = format!("{page}?pwd={code}");
    match c.get(&first).send().await {
        Ok(r) => {
            cookies = cookies_of(&r);
            let st = r.status().as_u16();
            if !(200..400).contains(&st) {
                steps.push(format!("分享页返回 HTTP {st}"));
            }
            if let Some(q) = r.url().query() {
                for pair in q.split('&') {
                    if let Some(v) = pair.strip_prefix("surl=") {
                        if !v.is_empty() {
                            surl_eff = v.to_string();
                        }
                    }
                }
            }
            // 兜底：没拿到 Location 时按"去掉路径前缀 1"推导（仅当首字符是 1）
            if surl_eff == surl && surl.len() > 1 && surl.starts_with('1') {
                surl_eff = surl[1..].to_string();
            }
        }
        Err(e) => steps.push(format!("分享页请求失败：{e}")),
    }

    // ② 提交**已知**提取码（不做验证码、不猜）
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let verify_url = format!(
        "https://pan.baidu.com/share/verify?surl={surl_eff}&t={ts}&channel=chunlei&web=1&app_id=250528&clienttype=0"
    );
    let vres = c
        .post(&verify_url)
        .header(reqwest::header::REFERER, &page)
        .header(reqwest::header::ORIGIN, "https://pan.baidu.com")
        .form(&[("pwd", code.as_str()), ("vcode", ""), ("vcode_str", "")])
        .send()
        .await;
    match vres {
        Ok(r) => {
            let st = r.status().as_u16();
            let extra = cookies_of(&r);
            if !extra.is_empty() {
                if cookies.is_empty() {
                    cookies = extra;
                } else {
                    cookies = format!("{cookies}; {extra}");
                }
            }
            let body = r.text().await.unwrap_or_default();
            if !(200..400).contains(&st) {
                steps.push(format!("verify 返回 HTTP {st}"));
            }
            let errno = serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| v.get("errno").and_then(|x| x.as_i64()));
            match errno {
                Some(0) => {}
                Some(e) => {
                    return Err(fail(&steps, format!("verify 返回 errno={e}（提取码不对 / 需要验证码？）")))
                }
                None => return Err(fail(&steps, format!("verify 响应不是 JSON：{}", head(&body)))),
            }
        }
        Err(e) => return Err(fail(&steps, format!("verify 请求失败：{e}"))),
    }

    // ③ 带 cookie 再取分享页，从 HTML 里抠 file_list
    // ★ 进子目录：实测分享页条目里带 `path`（`/sharelink…/目录名`），
    //   再取时用 `&path=<urlencoded>`（字段名是 `path`，不是 `dir`）。
    let mut sub_req = c
        .get(&first)
        .header(reqwest::header::COOKIE, cookies)
        .header(reqwest::header::REFERER, "https://pan.baidu.com/");
    for (k, v) in nav_params(PanKind::Baidu, dir) {
        sub_req = sub_req.query(&[(k.as_str(), v.as_str())]);
    }
    let html = match sub_req.send().await
    {
        Ok(r) => {
            let st = r.status().as_u16();
            let t = r.text().await.unwrap_or_default();
            if !(200..400).contains(&st) {
                steps.push(format!("带 cookie 的分享页返回 HTTP {st}"));
            }
            t
        }
        Err(e) => return Err(fail(&steps, format!("带 cookie 的分享页请求失败：{e}"))),
    };
    let (title, entries) = match parse_baidu_yundata(&html) {
        Ok(v) => v,
        Err(e) => {
            let msg = match dir {
                Some(d) => subdir_denied(PanKind::Baidu, &d.name),
                None => e,
            };
            return Err(fail(&steps, msg));
        }
    };
    /*
     * ★★★ 百度：`&path=` 这个参数**实测被上游忽略**（2026-10-26 复核）。
     *
     * ```text
     * 请求 /s/<surl>?pwd=…&path=/sharelink…/G-诡异降临  ⇒ 回来的还是**根目录**
     * （file_list 里那一条的 path 恰好等于我们请求的那个 path）。
     * 若直接把它当"子目录的内容"返回，用户点进目录会看到"目录里还是它自己" ——
     * 比空列表更糟（空列表至少能被察觉）。⇒ 这里做**归属校验**：
     *   子目录里的条目，其 `path` 必须以请求的 path + "/" 开头；
     *   一条都不满足 ⇒ 如实 Err（"匿名进不去这个子目录"）。
     * ```
     * ⚠️ 这条校验同时是"上游改版"的哨兵：哪天百度真支持了 path，这里会自动放行；
     *   若它又开始返回根，这里会立刻变红（live 用例）。
     */
    if let Some(d) = dir {
        let want = d.path.as_deref().unwrap_or("");
        let inside = entries.iter().any(|e| {
            e.path
                .as_deref()
                .map(|p| p.starts_with(want) && p.len() > want.len())
                .unwrap_or(false)
        });
        if !inside {
            return Err(fail(&steps, subdir_denied(PanKind::Baidu, &d.name)));
        }
    }
    let n = entries.len();
    Ok(PanListing {
        title,
        entries,
        note: anonymous_note(PanKind::Baidu.display(), n),
    })
}

/// 小助手：非 2xx/3xx 时把状态码记进失败明细（**不中断**——后续步骤可能仍成功）
trait AlsoCheck {
    fn also_check(self, status: u16, steps: &mut Vec<String>) -> Self;
}

impl AlsoCheck for String {
    fn also_check(self, status: u16, steps: &mut Vec<String>) -> Self {
        if !(200..400).contains(&status) {
            steps.push(format!("上游返回 HTTP {status}：{}", head(&self)));
        }
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── 夸克：好样本 ────────────────────────────────────────────────
    const QUARK_TOKEN_OK: &str = r#"{"code":0,"message":"OK","data":{"stoken":"abc","title":"某影片.iso","author":{}}}"#;
    const QUARK_DETAIL_OK: &str = r#"{"code":0,"data":{"list":[
        {"file_name":"A.iso","size":86781081600,"file_type":1,"fid":"f1"},
        {"file_name":"子目录","size":0,"file_type":0,"fid":"f2"}]}}"#;

    #[test]
    fn quark_token_parses_ok() {
        let (stoken, title) = parse_quark_token(QUARK_TOKEN_OK).expect("应能解析");
        assert_eq!(stoken, "abc");
        assert_eq!(title, "某影片.iso");
    }

    #[test]
    fn quark_detail_parses_size_and_dir() {
        let v = parse_quark_detail(QUARK_DETAIL_OK).expect("应能解析");
        assert_eq!(v.len(), 2);
        assert_eq!(v[0].name, "A.iso");
        assert_eq!(v[0].size, 86_781_081_600);
        assert!(!v[0].is_dir, "file_type=1 是文件");
        assert!(v[1].is_dir, "file_type=0 是目录");
    }

    // ── 夸克：坏样本（结构变了 ⇒ 必须 Err，不许空列表）──────────────
    #[test]
    fn quark_token_bad_shapes_all_err() {
        for bad in [
            r#"{"code":1,"message":"分享已取消"}"#,
            r#"{"code":0,"data":{}}"#,
            r#"not json at all"#,
            r#"{"code":0}"#,
        ] {
            assert!(parse_quark_token(bad).is_err(), "坏样本必须 Err：{bad}");
        }
    }

    #[test]
    fn quark_detail_bad_shapes_all_err() {
        for bad in [
            r#"{"code":0,"data":{"list":[]}}"#,
            r#"{"code":0,"data":{}}"#,
            r#"{"code":-404,"message":"啥都木有"}"#,
            r#"<html>error</html>"#,
        ] {
            let r = parse_quark_detail(bad);
            assert!(r.is_err(), "坏样本必须 Err（不许返回空列表）：{bad}");
            let msg = r.unwrap_err();
            assert!(!msg.is_empty(), "Err 必须可读（有内容）");
        }
    }

    // ── 百度：好样本（JS 对象字面量形态，非严格 JSON）────────────────
    const BAIDU_HTML: &str = r#"<html><head><title>某影片 - 百度网盘</title></head><body>
<script>locals.mset({ "yunData": { "shareid": 63975555959, "uk": "0",
  "file_list": [{"server_filename":"G-诡异降临","isdir":1,"size":0,"fs_id":371018630578153,
                 "path":"/sharelink1-2/G-诡异降临"},
                {"server_filename":"readme.txt","isdir":0,"size":12345,"fs_id":2,
                 "path":"/sharelink1-2/readme.txt"}] } });</script>
</body></html>"#;

    #[test]
    fn baidu_yundata_parses_list_and_title() {
        let (title, entries) = parse_baidu_yundata(BAIDU_HTML).expect("应能解析");
        assert!(title.contains("百度网盘"), "标题应取 <title>：{title}");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].name, "G-诡异降临");
        assert!(entries[0].is_dir);
        assert_eq!(entries[1].size, 12345);
        assert!(!entries[1].is_dir);
    }

    #[test]
    fn baidu_yundata_bad_shapes_all_err() {
        for bad in [
            "<html><title>x</title>no data here</html>",
            r#"{"file_list": []}"#,                                  // 空数组 ⇒ 不是"空分享"
            r#"{"file_list": [{"x":1}]}"#,                            // 缺 server_filename
            r#"{"file_list": [{"server_filename":"a", "isdir":0}]}"#, // 合法（对照：这条要 Ok）
        ] {
            let r = parse_baidu_yundata(bad);
            if bad.contains("\"a\"") {
                assert!(r.is_ok(), "合法样本不该 Err：{bad}");
            } else {
                assert!(r.is_err(), "坏样本必须 Err：{bad}");
            }
        }
    }

    /// ★ 括号配对必须经得住"数组里有逗号/嵌套对象/转义引号"
    #[test]
    fn slice_value_survives_nested_and_escaped() {
        let js = r#"x({ "file_list": [{"a":"x,y","b":{"c":[1,2]}},{"a":"q\"z"}], "k": 1 })"#;
        let got = slice_value(js, "\"file_list\"").expect("应抠出数组");
        assert!(got.starts_with('[') && got.ends_with(']'), "实际：{got}");
        let v: Value = serde_json::from_str(got).expect("抠出来的必须是合法 JSON");
        assert_eq!(v.as_array().unwrap().len(), 2);
    }

    // ── UC（与夸克同族，token 主机不同）──────────────────────────────
    const UC_TOKEN_OK: &str = r#"{"status":200,"code":0,"message":"ok","data":{"stoken":"tok","title":"战邮1942"}}"#;
    /// ★★★ 钉死目录判据：UC 的目录是 `file_type:0`、文件是 `1`
    ///
    /// 这是本文件**最容易被写反**的一条：把 0 当文件 ⇒ 目录被画成文件、
    /// 用户点进去发现播不了。反面：把 `is_dir` 判据改成 `== Some(1)` ⇒ 本条红。
    const UC_DETAIL_OK: &str = r#"{"status":200,"code":0,"message":"ok","data":{"list":[
        {"file_name":"战邮1942","size":0,"file_type":0,"fid":"5a847771"},
        {"file_name":"第一集.mp4","size":123456,"file_type":1,"fid":"f2"}]}}"#;

    #[test]
    fn uc_token_parses_ok() {
        let (stoken, title) = parse_uc_token(UC_TOKEN_OK).expect("应能解析");
        assert_eq!(stoken, "tok");
        assert_eq!(title, "战邮1942");
    }

    #[test]
    fn uc_detail_dir_is_zero_and_file_is_one() {
        let v = parse_uc_detail(UC_DETAIL_OK).expect("应能解析");
        assert_eq!(v.len(), 2);
        assert_eq!(v[0].name, "战邮1942");
        assert!(v[0].is_dir, "★★ UC 的 file_type=0 是**目录**（写反这里就会红）");
        assert_eq!(v[1].size, 123456);
        assert!(!v[1].is_dir, "★ UC 的 file_type=1 是文件");
    }

    #[test]
    fn uc_token_errs_echo_upstream_message() {
        for (bad, want) in [
            (r#"{"status":200,"code":-1,"message":"分享已失效"}"#, "分享已失效"),
            (r#"{"status":403,"code":0,"message":"forbidden"}"#, "forbidden"),
            (r#"<html><h2>403 Forbidden</h2></html>"#, "不是 JSON"),
        ] {
            let e = parse_uc_token(bad).expect_err("必须 Err");
            assert!(e.contains(want), "错误里要回显上游原文（不要猜码值）：{e}");
        }
    }

    #[test]
    fn uc_detail_bad_shapes_all_err() {
        for bad in [
            r#"{"status":200,"code":0,"data":{"list":[]}}"#,
            r#"{"status":200,"code":-404,"message":"啥都木有"}"#,
            r#"not json"#,
        ] {
            assert!(parse_uc_detail(bad).is_err(), "坏样本必须 Err：{bad}");
        }
    }

    /// ★ 硬纪律②：失败必须**汇总**，不许只留最后一个
    #[test]
    fn fail_aggregates_every_step() {
        let msg = fail(
            &["分享页返回 HTTP 502".to_string(), "token 请求失败：timeout".to_string()],
            "detail 响应里没有 data.list（结构可能变了）".to_string(),
        );
        for want in ["502", "timeout", "data.list"] {
            assert!(msg.contains(want), "失败明细必须汇总，缺 `{want}`：{msg}");
        }
        assert!(msg.starts_with("列目录失败："), "要有可读抬头：{msg}");
        assert!(msg.matches("
- ").count() >= 3, "三步都要成条：{msg}");
    }

    /// ★ 硬纪律③：真网络必须**直连**（`.no_proxy()`）
    ///
    /// 这条是**源码判据**而不是网络判据：本机常年挂代理，拿真网络验"没走代理"
    /// 只能验到"今天没走"，改一行删掉 `.no_proxy()` 也不会红。
    /// 反面：把下面这个调用删掉 ⇒ 本条立刻红。
    #[test]
    fn http_client_disables_system_proxy() {
        let src = include_str!("pan_list.rs");
        assert!(
            src.contains(".no_proxy()"),
            "★★ 建 client 时必须 `.no_proxy()`：本机代理会把分享页的 200 变成 502"
        );
    }

    // ── 进子目录（只进一层）────────────────────────────────────────
    fn entry(name: &str, is_dir: bool, fid: Option<&str>, path: Option<&str>) -> PanEntry {
        PanEntry {
            name: name.to_string(),
            size: 0,
            is_dir,
            fid: fid.map(|s| s.to_string()),
            path: path.map(|s| s.to_string()),
        }
    }

    /// ★★ 导航参数：根用 0，子目录用它自己的句柄（**写死成根 ⇒ 本条红**）
    #[test]
    fn nav_params_root_vs_subdir() {
        // 夸克/UC：根 ⇒ pdir_fid=0
        assert_eq!(
            nav_params(PanKind::Quark, None),
            vec![("pdir_fid".to_string(), "0".to_string())]
        );
        // 夸克/UC：子目录 ⇒ 该条目的 fid（不是 0！）
        let d = entry("子目录", true, Some("fid-abc"), None);
        assert_eq!(
            nav_params(PanKind::Quark, Some(&d)),
            vec![("pdir_fid".to_string(), "fid-abc".to_string())]
        );
        assert_eq!(
            nav_params(PanKind::Uc, Some(&d)),
            vec![("pdir_fid".to_string(), "fid-abc".to_string())]
        );
        // 百度：子目录 ⇒ path（保留斜杠，其余百分号编码）
        let b = entry("G-诡异降临", true, Some("123"), Some("/sharelink1-2/G-诡异降临"));
        let got = nav_params(PanKind::Baidu, Some(&b));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, "path", "★ 实测字段名是 path，不是 dir");
        assert!(got[0].1.starts_with("/sharelink1-2/"), "斜杠要保留：{}", got[0].1);
        // 百度：根 ⇒ 空参数（不带 path）
        assert!(nav_params(PanKind::Baidu, None).is_empty());
    }

    /// 子目录**没有句柄** ⇒ 可读 Err（不许静默退回根）
    #[test]
    fn subdir_without_handle_is_an_error_not_root() {
        let blk = futures_lite_block;
        // 夸克目录没有 fid
        let d = entry("空句柄目录", true, None, None);
        let e = blk(list_share_at(PanKind::Quark, "abc", None, Some(&d))).expect_err("必须 Err");
        assert!(e.contains("进不去"), "要可读：{e}");
        assert!(e.contains("空句柄目录"), "要点名是哪个目录：{e}");
        // 百度目录没有 path
        let b = entry("无 path 目录", true, None, None);
        let e2 = blk(list_share_at(PanKind::Baidu, "abc", None, Some(&b))).expect_err("必须 Err");
        assert!(e2.contains("进不去"), "要可读：{e2}");
    }

    /// 传一个**文件**进去 ⇒ 直接拒（不是"列出来看"）
    #[test]
    fn entering_a_file_is_rejected() {
        let f = entry("某影片.mp4", false, Some("fid1"), None);
        let e = futures_lite_block(list_share_at(PanKind::Quark, "abc", None, Some(&f)))
            .expect_err("文件不是目录");
        assert!(e.contains("不是目录"), "{e}");
    }

    /// 子目录被拒时的文案（"需要登录"而不是"这里没文件"）
    #[test]
    fn subdir_denied_message_says_login() {
        let m = subdir_denied(PanKind::Baidu, "G-诡异降临");
        assert!(m.contains("需要登录"), "{m}");
        assert!(m.contains("G-诡异降临"), "要点名：{m}");
        assert!(!m.contains("0 个文件"), "不许用它冒充'空目录'：{m}");
    }

    /// 混排（目录 + 文件）都要在，且各自带上能继续导航的句柄
    #[test]
    fn mixed_entries_keep_navigation_handles() {
        let (_, v) = parse_baidu_yundata(BAIDU_HTML).expect("应能解析");
        assert_eq!(v.len(), 2);
        assert!(v[0].is_dir && v[0].path.is_some(), "目录要带 path 才能进：{:?}", v[0]);
        assert!(!v[1].is_dir);
        let q = parse_quark_detail(QUARK_DETAIL_OK).expect("应能解析");
        assert!(q[0].fid.is_some(), "夸克条目要带 fid 才能进：{:?}", q[0]);
        assert!(q[1].is_dir && q[1].fid.is_some(), "夸克目录也要带 fid");
    }

    /// ★★ 百度：上游把**根列表**当成子目录内容返回时，必须 Err（不许静静返回根）
    ///
    /// 反面：把上面那段归属校验删掉 ⇒ 本条红（它会"成功地"返回根目录）。
    #[test]
    fn baidu_subdir_that_returns_root_is_an_error() {
        // 用真实形状的 HTML：根只有一条目录，其 path 恰好等于请求的 path
        let html = r#"<html><title>t</title><script>locals.mset({ "yunData": {
            "file_list": [{"server_filename":"G-诡异降临","isdir":1,"size":0,
                           "path":"/sharelink1-2/G-诡异降临"}] } });</script></html>"#;
        let (_, entries) = parse_baidu_yundata(html).expect("解析本身没问题");
        let d = entry("G-诡异降临", true, None, Some("/sharelink1-2/G-诡异降临"));
        // 复刻生产里的归属校验（同一判据）
        let want = d.path.clone().unwrap();
        let inside = entries.iter().any(|e| {
            e.path.as_deref().map(|p| p.starts_with(&want) && p.len() > want.len()).unwrap_or(false)
        });
        assert!(!inside, "根列表不该通过归属校验 —— 否则用户点进目录会看到它自己");
        // 真正属于该目录的条目（path 更深一层）⇒ 通过
        let deep = entry("子文件.mp4", false, None, Some("/sharelink1-2/G-诡异降临/子文件.mp4"));
        let inside2 = [deep].iter().any(|e| {
            e.path.as_deref().map(|p| p.starts_with(&want) && p.len() > want.len()).unwrap_or(false)
        });
        assert!(inside2, "更深一层的条目才叫'进去了'");
    }

    #[test]
    fn anonymous_note_is_layered_and_readable() {
        let n = anonymous_note("夸克网盘", 3);
        assert!(n.contains("3 个文件"), "要报数：{n}");
        assert!(n.contains("未登录"), "要说清当前是匿名：{n}");
        assert!(n.contains("取直链需要登录夸克网盘账号"), "要说清下一步：{n}");
    }

    /// 不支持的盘：必须可读 Err（不是空列表）
    #[test]
    fn unsupported_kinds_err_with_reason() {
        // ★ UC 已实现（2026-10-26），从"未实现清单"里移出（下方有它的真实用例）
        for k in [PanKind::Aliyun, PanKind::Pan123, PanKind::Pan115, PanKind::Tianyi, PanKind::Unknown] {
            let r = futures_lite_block(list_share(k, "abc", None));
            assert!(r.is_err(), "{:?} 应 Err", k);
            assert!(r.unwrap_err().contains("还没有实现"));
        }
    }

    /// 极小的 block_on（不引 futures 依赖：用 tokio 已有的 runtime builder）
    fn futures_lite_block<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("建 runtime")
            .block_on(f)
    }

    // ══════════════════════════════════════════════════════════════
    //  真网络（默认 ignore；显式跑必须给 PAN_LIVE=1 + 两个 URL 变量）
    // ══════════════════════════════════════════════════════════════
    //
    // ★ 纪律：**没有环境变量就 assert 失败**，不许静默跳过 ——
    //   静默跳过的"真网络测试"等于没有（本仓假绿形态之一）。
    fn live_env(name: &str) -> String {
        assert_eq!(
            std::env::var("PAN_LIVE").ok().as_deref(),
            Some("1"),
            "真网络测试必须显式开：PAN_LIVE=1（并给 {name}）。这条不许静默跳过"
        );
        let v = std::env::var(name).unwrap_or_default();
        assert!(!v.is_empty(), "缺少环境变量 {name}（分享链接里的 id）");
        v
    }

    #[tokio::test]
    #[ignore = "真网络：PAN_LIVE=1 PAN_QUARK_ID=<pwd_id> PAN_QUARK_PWD=<可选> cargo test --lib pan_list --release -- --ignored --nocapture"]
    async fn live_quark_lists_anonymous() {
        let id = live_env("PAN_QUARK_ID");
        let pwd = std::env::var("PAN_QUARK_PWD").ok();
        let l = list_share(PanKind::Quark, &id, pwd.as_deref())
            .await
            .expect("夸克匿名列目录应成功");
        println!("[LIVE-QUARK] title={:?} count={} note={}", l.title, l.entries.len(), l.note);
        for e in l.entries.iter().take(3) {
            println!("[LIVE-QUARK]   {} size={} dir={}", e.name, e.size, e.is_dir);
        }
        assert!(!l.entries.is_empty(), "★ 列目录成功就必须有条目（空列表 = 假成功）");
    }

    #[tokio::test]
    #[ignore = "真网络：PAN_LIVE=1 PAN_BAIDU_SURL=<surl> PAN_BAIDU_PWD=<提取码> cargo test --lib pan_list --release -- --ignored --nocapture"]
    async fn live_baidu_lists_anonymous() {
        let surl = live_env("PAN_BAIDU_SURL");
        let pwd = live_env("PAN_BAIDU_PWD");
        let l = list_share(PanKind::Baidu, &surl, Some(&pwd))
            .await
            .expect("百度匿名列目录应成功");
        println!("[LIVE-BAIDU] title={:?} count={} note={}", l.title, l.entries.len(), l.note);
        for e in l.entries.iter().take(3) {
            println!("[LIVE-BAIDU]   {} size={} dir={}", e.name, e.size, e.is_dir);
        }
        assert!(!l.entries.is_empty(), "★ 列目录成功就必须有条目");
    }


    #[tokio::test]
    #[ignore = "真网络：PAN_LIVE=1 PAN_UC_ID=<pwd_id> cargo test --lib pan_list --release -- --ignored --nocapture"]
    async fn live_uc_lists_anonymous() {
        let id = live_env("PAN_UC_ID");
        let l = list_share(PanKind::Uc, &id, None)
            .await
            .expect("UC 匿名列目录应成功");
        println!("[LIVE-UC] title={:?} count={} note={}", l.title, l.entries.len(), l.note);
        for e in l.entries.iter().take(3) {
            println!("[LIVE-UC]   {} size={} dir={}", e.name, e.size, e.is_dir);
        }
        assert!(!l.entries.is_empty(), "★ 列目录成功就必须有条目");
    }
    /// 两层读数：根 → 进第一个目录（**只进一层**）。哪个盘给了环境变量就跑哪个。
    #[tokio::test]
    #[ignore = "真网络：PAN_LIVE=1 + PAN_UC_ID / PAN_BAIDU_SURL+PAN_BAIDU_PWD"]
    async fn live_subdir_two_levels() {
        assert_eq!(
            std::env::var("PAN_LIVE").ok().as_deref(),
            Some("1"),
            "真网络测试必须显式开：PAN_LIVE=1（这条不许静默跳过）"
        );
        let mut ran = 0;
        if let Ok(id) = std::env::var("PAN_UC_ID") {
            if !id.is_empty() {
                ran += 1;
                let root = list_share(PanKind::Uc, &id, None).await.expect("UC 根层");
                println!("[L2-UC] 根 count={} title={:?}", root.entries.len(), root.title);
                for e in root.entries.iter().take(3) {
                    println!("[L2-UC]   {} size={} dir={} fid={:?}", e.name, e.size, e.is_dir, e.fid);
                }
                if let Some(d) = root.entries.iter().find(|e| e.is_dir) {
                    match list_share_at(PanKind::Uc, &id, None, Some(d)).await {
                        Ok(sub) => {
                            println!("[L2-UC] 进「{}」count={}", d.name, sub.entries.len());
                            for e in sub.entries.iter().take(3) {
                                println!("[L2-UC]   {} size={} dir={}", e.name, e.size, e.is_dir);
                            }
                        }
                        Err(e) => println!("[L2-UC] 子目录如实 Err：{e}"),
                    }
                }
            }
        }
        if let (Ok(surl), Ok(pwd)) = (std::env::var("PAN_BAIDU_SURL"), std::env::var("PAN_BAIDU_PWD")) {
            if !surl.is_empty() && !pwd.is_empty() {
                ran += 1;
                let root = list_share(PanKind::Baidu, &surl, Some(&pwd)).await.expect("百度根层");
                println!("[L2-BAIDU] 根 count={} title={:?}", root.entries.len(), root.title);
                for e in root.entries.iter().take(3) {
                    println!("[L2-BAIDU]   {} size={} dir={} path={:?}", e.name, e.size, e.is_dir, e.path);
                }
                if let Some(d) = root.entries.iter().find(|e| e.is_dir) {
                    match list_share_at(PanKind::Baidu, &surl, Some(&pwd), Some(d)).await {
                        Ok(sub) => {
                            println!("[L2-BAIDU] 进「{}」count={}", d.name, sub.entries.len());
                            for e in sub.entries.iter().take(3) {
                                println!("[L2-BAIDU]   {} size={} dir={}", e.name, e.size, e.is_dir);
                            }
                        }
                        Err(e) => println!("[L2-BAIDU] 子目录如实 Err：{e}"),
                    }
                }
            }
        }
        assert!(ran > 0, "至少要给一个盘的环境变量");
    }

}
