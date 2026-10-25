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
    let list = v
        .get("data")
        .and_then(|d| d.get("list"))
        .and_then(|l| l.as_array())
        .ok_or_else(|| "detail 响应里没有 data.list（结构可能变了）".to_string())?;
    let mut out = Vec::with_capacity(list.len());
    for it in list {
        let name = it.get("file_name").and_then(|x| x.as_str()).unwrap_or("");
        if name.is_empty() {
            continue;
        }
        out.push(PanEntry {
            name: name.to_string(),
            size: num_of(it.get("size")),
            is_dir: it.get("file_type").and_then(|x| x.as_i64()) == Some(0),
        });
    }
    if out.is_empty() {
        return Err("detail 的 list 为空或每项都缺 file_name（不是空分享，多半是结构变了）".to_string());
    }
    Ok(out)
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
    if share_id.trim().is_empty() {
        return Err("分享 id 为空（这不是分享链接？）".to_string());
    }
    match kind {
        PanKind::Quark => quark_list(share_id, pwd).await,
        PanKind::Baidu => baidu_list(share_id, pwd).await,
        other => Err(format!(
            "{} 的匿名列目录还没有实现（本批只做了夸克与百度两个盘，见 .probe/pan-anon-probe.md）",
            other.display()
        )),
    }
}

async fn quark_list(pwd_id: &str, passcode: Option<&str>) -> Result<PanListing, String> {
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
            ("pdir_fid", "0"),
            ("force", "0"),
            ("_page", "1"),
            ("_size", "50"),
            ("_sort", "file_type:asc,updated_at:desc"),
        ])
        .header(reqwest::header::ORIGIN, "https://pan.quark.cn")
        .header(reqwest::header::REFERER, format!("https://pan.quark.cn/s/{pwd_id}"))
        .header(reqwest::header::COOKIE, cookies);
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
        Err(e) => return Err(fail(&steps, e)),
    };
    let n = entries.len();
    Ok(PanListing {
        title,
        entries,
        note: anonymous_note(PanKind::Quark.display(), n),
    })
}

async fn baidu_list(surl: &str, pwd: Option<&str>) -> Result<PanListing, String> {
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
    let html = match c
        .get(&first)
        .header(reqwest::header::COOKIE, cookies)
        .header(reqwest::header::REFERER, "https://pan.baidu.com/")
        .send()
        .await
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
        Err(e) => return Err(fail(&steps, e)),
    };
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
  "file_list": [{"server_filename":"G-诡异降临","isdir":1,"size":0},
                {"server_filename":"readme.txt","isdir":0,"size":12345}] } });</script>
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
        for k in [PanKind::Aliyun, PanKind::Pan123, PanKind::Pan115, PanKind::Tianyi, PanKind::Uc, PanKind::Unknown] {
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
}
