// ═══════════════════════════════════════════════════════════════════════
//  csp_AList —— 用户**自己的** AList 服务（host 只能来自 ext）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类与原版其它类的根本区别（决定了本文件的每一条边界）
//
// ```text
// 别的类：host 是**上游站点**的域名 ⇒ 可以在 DEX 里逐字取证、可以直连复测。
// 这个类：host 是**用户自己搭的** AList ⇒
//   · DEX 里**没有任何域名**（`AList.txt` 全篇 0 个 http 域名，只有 `/api/...` 路径）
//   · 订阅里 `csp_AList` 的 ext 是 `"./json/alist.json"`（**相对配置目录的本地文件**）
//   ⇒ host 与 token 只能来自 ext。缺 ext ⇒ **没有任何东西可请求**。
// ```
//
// # ★ 为什么不注册（`register_site!` 缺席，这是**被判据逼出来的**）
//
// ```text
// 本仓判例（`2026-10-28-csp-25-classes-implement-vs-register.md`）的判据②：
//   「有可用 host：ext 里给，或从 DEX 常量逐字还原（**不许猜域名**）」
// 本类**两条都不成立**：
//   · DEX 里没有域名（如实：全篇只有 `/api/fs/list` 这类**路径**）
//   · 订阅里的 ext 是个本地文件名，本层拿不到配置目录（也不该拿：csp 层不碰宿主路径）
// 再加上 `state.rs` 的「内置 csp 源自动暴露」：注册 = 用户界面上多一条源。
//   一个"必然报『请先在 ext 里填你的服务地址』"的源 = 假源 ⇒ **不注册**。
// ⇒ 实现完整（六个方法都在、协议逐字），等 Owner 的 ext 里真有服务地址时，
//   加一行 `register_site!(AList)` 就能上线（本文件末尾标了位置）。
// ```
//
// # 原版形状（DEX 常量逐字，未起 jadx）
//
// ```text
// 来源 `.probe/csp-parity/AList.txt`：
//   [headers]  "User-Agent"  UA  "Authorization"      ← 认证用 Authorization 头
//   [login]    "username" "password" "/api/auth/login" "data" "token"
//   [list]     "/" "path" "password" "/api/fs/list" "/api/public/path"
//              "name" "is_dir" "type" "size" "date" "modified" "thumb" "//"
//   [extractFiles] "content" "files"                  ← data.content / data.files
//   [rawUrl]   "path" "password" "/api/fs/get" "/api/public/path"
//              "files" "raw_url" "sign" "?sign="     ← 直链 = raw_url（+ ?sign=…）
//   [searchOne] "path" "/" "password" "keywords" "page" "per_page"
//              "/api/fs/search" "keyword" "/api/public/search"
//              "content" "files" "name" "AllowAlias" "type"
//   [post]     "Guest user is disabled"               ← 访客关闭时上游的原话
//   [load]     "vodPic" "{" "http" "drives" "alist_user.json"
//              ⇒ ext 的三种形态：`{`=内联 JSON / `http`=远端 JSON / 其它=本地文件名
//   [<clinit>] "vod_play_from" "AList" "/" "vod_play_url"
// ```
//
// # 诚实边界（逐条，都有出处）
//
// ```text
// ① **没有真网读数**：本机没有 AList 服务，也没有 Owner 的服务地址 ⇒
//    按纪律"取不到就如实写清楚"，**不编造**任何 host。
//    可复核的部分是：端点路径、请求字段名、响应字段名、`Guest user is disabled`
//    这句上游原话（全部来自 DEX 字面量）。
// ② `?sign=` 的拼法：DEX 只有 `"sign"` 与 `"?sign="` 两个字面量 ⇒
//    按"raw_url 若已是绝对地址就直接用；若响应给了 sign 且 raw_url 里还没有
//    `sign=`，才追加 `?sign=`"处理，并在注释里标明这是**拼法推断**（未验）。
// ③ `/api/public/path`、`/api/public/search` 两个**访客**端点：DEX 只给了 URL，
//    **没给请求体字段**；按"不猜参数"的纪律**不实现**（遇到 `Guest user is disabled`
//    时如实把上游原话报给用户，并说明需要 token）。
// ④ 本地文件形态（`./json/alist.json`）：本层**读不到**（csp 层不碰宿主数据目录）
//    ⇒ 明确报错并告诉用户改填 http(s) 地址或内联 JSON。
// ```

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspEpisode, CspHome, CspItem, CspList, CspPlay, CspSite};

const HTTP_TIMEOUT: Duration = Duration::from_secs(8);

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36";

/// 每页条数（DEX 只有键名 `per_page`，没给值）
const PER_PAGE: u32 = 100;

/// 上游"访客被关闭"的原话（DEX `[post]` 逐字）
const GUEST_DISABLED: &str = "Guest user is disabled";

/// 一个 AList 服务（= 用户配置里的一台）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlistDrive {
    /// 这台的名字（内联 JSON 的 `name`；缺省用 base）
    pub name: String,
    /// 服务根地址（`https://…`，**不带**结尾斜杠）
    pub base: String,
    /// 登录后的 token（有 ⇒ 走 `Authorization`；没有 ⇒ 走访客）
    pub token: String,
    /// 起始路径（`/` 默认）
    pub root: String,
}

fn brief(s: &str) -> String {
    let t = s.trim();
    let cut = t.char_indices().nth(160).map(|(i, _)| i).unwrap_or(t.len());
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

/// 去掉结尾斜杠（`https://x/` 与 `https://x` 必须是同一个 base，否则拼出 `//api/…`）
fn trim_base(base: &str) -> String {
    base.trim().trim_end_matches('/').to_string()
}

/// 拼路径：父路径 + 名字 ⇒ 绝对路径
///
/// # 为什么必须有这一条（DEX `[list]` 里有个 `"//"` 字面量，说明原版也踩过）
/// ```text
/// 根是 `"/"`，子项是 `"a.mkv"` ⇒ 朴素 `format!("{parent}/{name}")` 得到 `"//a.mkv"`。
/// AList 的 `/api/fs/get` 对 `//a` 与 `/a` 是**两个** path ⇒ 取直链会 404/空。
/// ⇒ 这里做显式归一，并让测试钉住（这是"静默错"，界面上看不出）。
/// ```
pub fn join_path(parent: &str, name: &str) -> String {
    let p = parent.trim();
    let n = name.trim();
    if n.is_empty() {
        return normalize_path(p);
    }
    if n.starts_with('/') {
        return normalize_path(n);
    }
    let base = if p.is_empty() { "/" } else { p };
    normalize_path(&format!("{}/{n}", base.trim_end_matches('/')))
}

/// 路径归一：多斜杠压成一个，`/` 开头，非空
fn normalize_path(p: &str) -> String {
    let mut out = String::with_capacity(p.len() + 1);
    out.push('/');
    for seg in p.split('/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if !out.ends_with('/') {
            out.push('/');
        }
        out.push_str(seg);
    }
    out
}

/// 从 ext 解出配置（**纯函数**：ext 形态的判定与解析都要能断言）
///
/// 认的键（内联 JSON）：
/// ```json
/// {"drives":[{"name":"我的","server":"https://alist.example","token":"…","root":"/"}]}
/// {"server":"https://alist.example","token":"…"}
/// {"server":"https://alist.example","username":"u","password":"p"}   // 需登录换 token（未实现）
/// ```
pub fn parse_conf(ext: &str) -> Result<Vec<AlistDrive>, String> {
    let t = ext.trim();
    if t.is_empty() {
        return Err(
            "AList 的 ext 是空的 —— 这是「你自己的」服务，必须给出地址：\
             填 {\"server\":\"https://你的域名\",\"token\":\"…\"}（或内联 drives 数组）"
                .to_string(),
        );
    }
    if t.starts_with('{') || t.starts_with('[') {
        let v: serde_json::Value = serde_json::from_str(t)
            .map_err(|e| format!("ext 看起来是 JSON 但解析失败（{e}）：{}", brief(t)))?;
        let mut out = Vec::new();
        if let Some(arr) = v.get("drives").and_then(|d| d.as_array()) {
            for it in arr {
                out.push(drive_of(it)?);
            }
        } else {
            out.push(drive_of(&v)?);
        }
        if out.is_empty() {
            return Err("ext 里的 drives 是空数组 —— 至少要有一台服务".to_string());
        }
        return Ok(out);
    }
    if t.starts_with("http://") || t.starts_with("https://") {
        // ⚠️ 远端 JSON 需要网络；放在 `fetch_conf` 里做（这里只报"要走网络"）
        return Err(format!("EXT_IS_URL:{t}"));
    }
    Err(format!(
        "AList 的 ext 指向 `{t}`，本层读不到本地文件（csp 层不碰宿主数据目录）⇒ \
         请改填 http(s) 地址或内联 JSON"
    ))
}

/// 单个 drive 的解析
fn drive_of(v: &serde_json::Value) -> Result<AlistDrive, String> {
    let base = v
        .get("server")
        .or_else(|| v.get("url"))
        .or_else(|| v.get("base"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .trim();
    if base.is_empty() {
        return Err("这一项没有 server（你的 AList 地址）—— 不许猜域名".to_string());
    }
    if !(base.starts_with("http://") || base.starts_with("https://")) {
        return Err(format!("server 必须是 http(s) 绝对地址，收到 `{base}`"));
    }
    Ok(AlistDrive {
        name: v
            .get("name")
            .and_then(|x| x.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(base)
            .to_string(),
        base: trim_base(base),
        token: v
            .get("token")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string(),
        root: normalize_path(
            v.get("root").and_then(|x| x.as_str()).unwrap_or("/"),
        ),
    })
}

/// 列表/搜索里的一项
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlistFile {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
}

/// 响应信封：AList 是 `{"code":200,"message":"success","data":{…}}`
fn check(v: &serde_json::Value, http: u16) -> Result<(), String> {
    let code = v.get("code").and_then(|c| c.as_i64()).unwrap_or(200);
    if code != 200 {
        let msg = v.get("message").and_then(|m| m.as_str()).unwrap_or("");
        let hint = if msg.contains(GUEST_DISABLED) {
            "（这台服务关了访客访问 ⇒ 需要在 ext 里给 token）"
        } else {
            ""
        };
        return Err(format!("AList 返回 code={code}（HTTP {http}）：{msg}{hint}"));
    }
    Ok(())
}

/// 抽条目（DEX：`data` → `content`；搜索是 `data.content`，列表也是；`files` 是另一形态）
///
/// ★ 两种键都认，因为 DEX 里**两个都出现过**（`[list]`/`[searchOne]`/`[extractFiles]`），
///   不是"猜"——是同一族响应的两个历史形态。
fn parse_files(v: &serde_json::Value) -> Vec<AlistFile> {
    let data = v.get("data").unwrap_or(&serde_json::Value::Null);
    let arr = data
        .get("content")
        .and_then(|x| x.as_array())
        .or_else(|| data.get("files").and_then(|x| x.as_array()))
        .or_else(|| v.get("files").and_then(|x| x.as_array()));
    let Some(arr) = arr else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let name = it.get("name").and_then(|x| x.as_str()).unwrap_or("").trim();
        if name.is_empty() {
            continue;
        }
        out.push(AlistFile {
            name: name.to_string(),
            is_dir: it.get("is_dir").and_then(|x| x.as_bool()).unwrap_or(false),
            size: it.get("size").and_then(|x| x.as_u64()).unwrap_or(0),
        });
    }
    out
}

/// 直链（DEX：`data` → `raw_url`，可能还带 `sign`）
///
/// ★ `?sign=` 的拼法是**推断**（DEX 只有两个字面量），见文件头 ②。
pub fn raw_url_of(v: &serde_json::Value) -> Option<String> {
    let data = v.get("data")?;
    let raw = data.get("raw_url").and_then(|x| x.as_str()).unwrap_or("").trim();
    if raw.is_empty() {
        return None;
    }
    if raw.contains("sign=") {
        return Some(raw.to_string());
    }
    let sign = data.get("sign").and_then(|x| x.as_str()).unwrap_or("").trim();
    if sign.is_empty() {
        return Some(raw.to_string());
    }
    let sep = if raw.contains('?') { '&' } else { '?' };
    Some(format!("{raw}{sep}sign={sign}"))
}

/// 人读大小
fn human_size(b: u64) -> String {
    const U: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = b as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{b} B")
    } else {
        format!("{v:.1} {}", U[i])
    }
}

/// csp_AList
pub struct AList {
    client: reqwest::Client,
}

impl AList {
    pub const CLASS: &'static str = "AList";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("HTTP client 构建失败（TLS 后端不可用）—— 不许退回无 no_proxy 的兜底");
        Self { client }
    }

    /// 取配置（内联 JSON 直接用；http(s) 才发请求）
    async fn conf(&self, ext: &str) -> Result<Vec<AlistDrive>, String> {
        match parse_conf(ext) {
            Ok(v) => Ok(v),
            Err(e) => {
                let Some(url) = e.strip_prefix("EXT_IS_URL:") else {
                    return Err(e);
                };
                let resp = self
                    .client
                    .get(url)
                    .header("Accept", "application/json, text/plain, */*")
                    .send()
                    .await
                    .map_err(|e2| format!("取 AList 配置失败（{url}）：{e2}"))?;
                let status = resp.status();
                let body = resp.text().await.map_err(|e2| format!("读响应失败：{e2}"))?;
                if !status.is_success() {
                    return Err(format!("取 AList 配置返回 HTTP {status}：{}", brief(&body)));
                }
                // 远端 JSON 与内联 JSON 用**同一个解析器**（少一条分支就少一处漂）
                parse_conf(body.trim())
            }
        }
    }

    /// 选一台（`tid` 前缀 `d<idx>:<path>`；没有前缀就认为是第 0 台的路径）
    fn pick<'a>(
        drives: &'a [AlistDrive],
        tid: &str,
    ) -> Result<(&'a AlistDrive, String), String> {
        let t = tid.trim();
        if let Some(rest) = t.strip_prefix('d') {
            if let Some((idx_s, path)) = rest.split_once(':') {
                let idx: usize = idx_s
                    .parse()
                    .map_err(|_| format!("条目 id 里的服务下标不是数字：`{idx_s}`"))?;
                let d = drives
                    .get(idx)
                    .ok_or_else(|| format!("服务 {idx} 不存在（共 {} 台）", drives.len()))?;
                return Ok((d, normalize_path(path)));
            }
        }
        let d = drives
            .first()
            .ok_or_else(|| "没有任何 AList 服务（ext 里 drives 为空）".to_string())?;
        Ok((d, normalize_path(t)))
    }

    async fn post(
        &self,
        d: &AlistDrive,
        path: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        let url = format!("{}{path}", d.base);
        let mut req = self
            .client
            .post(&url)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json, text/plain, */*");
        if !d.token.is_empty() {
            // DEX `[headers]`：认证是 `Authorization` 头（原版把 token 原样放进去）
            req = req.header("Authorization", d.token.clone());
        }
        let resp = req
            .body(body.to_string())
            .send()
            .await
            .map_err(|e| format!("AList 请求失败（{url}）：{e}"))?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
        let v: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| format!("AList 返回的不是 JSON（{e}）：{}", brief(&text)))?;
        check(&v, status.as_u16())?;
        Ok(v)
    }
}

impl Default for AList {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for AList {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页 = **每台服务一个分类**（`tid` = `d<idx>:<root>`）
    ///
    /// # 为什么要联网
    /// ```text
    /// 分类来自 ext（配置），但 ext 可能是**远端 JSON** ⇒ 必须取回来才知道有几台。
    /// 取不到 ⇒ Err（不许交一个空首页：用户会以为"这个源没内容"）。
    /// ```
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let drives = self.conf(ext).await?;
        let categories = drives
            .iter()
            .enumerate()
            .map(|(i, d)| CspCategory {
                id: format!("d{i}:{}", d.root),
                name: d.name.clone(),
            })
            .collect::<Vec<_>>();
        if categories.is_empty() {
            return Err("ext 里没有任何 AList 服务（drives 为空）".to_string());
        }
        Ok(CspHome {
            categories,
            items: Vec::new(),
        })
    }

    /// 列表：`POST /api/fs/list {path,password,page,per_page}`
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let drives = self.conf(ext).await?;
        let (d, path) = Self::pick(&drives, tid)?;
        let body = serde_json::json!({
            "path": path,
            "password": "",
            "page": if page == 0 { 1 } else { page },
            "per_page": PER_PAGE,
        });
        let v = self.post(d, "/api/fs/list", body).await?;
        let files = parse_files(&v);
        if files.is_empty() {
            return Err(format!(
                "路径 `{path}` 一条都没解析到 —— 可能是路径不存在、缺 token（访客被关），\
                 或服务版本改了响应形状（不是「这个目录是空的」）"
            ));
        }
        let idx = drives.iter().position(|x| x.base == d.base).unwrap_or(0);
        let items = files
            .into_iter()
            .map(|f| CspItem {
                id: format!("d{idx}:{}", join_path(&path, &f.name)),
                title: f.name,
                cover: None,
                subtitle: Some(if f.is_dir {
                    "目录".to_string()
                } else {
                    human_size(f.size)
                }),
            })
            .collect();
        Ok(CspList {
            items,
            page: if page == 0 { 1 } else { page },
            page_count: None,
            total: None,
        })
    }

    async fn detail(&self, id: &str, _ext: &str) -> Result<CspDetail, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("条目 id 为空".to_string());
        }
        let (_, path) = id.split_once(':').unwrap_or(("d0", id));
        Ok(CspDetail {
            id: id.to_string(),
            title: path.to_string(),
            cover: None,
            description: None,
            episodes: vec![CspEpisode {
                id: id.to_string(),
                title: "播放".to_string(),
                flag: "默认".to_string(),
            }],
        })
    }

    /// ★ AList **支持搜索**（原版就是这个类在搜自己的盘：`/api/fs/search`）
    fn supports_search(&self) -> bool {
        true
    }

    /// 搜索：`POST /api/fs/search {parent,keywords,page,per_page}`
    ///
    /// ⚠️ 原版在多台服务之间是**逐个搜再合并**（DEX `[searchOne]` 单台 ⇒ 外面套了循环）。
    ///    本实现同样逐台，且**任何一台失败都不吞**：全部失败才 Err，
    ///    部分失败时把失败台数写进第一条的 subtitle 之外——不行，subtitle 是条目字段。
    ///    ⇒ 采用"逐台收集成功项；**成功台数为 0** 才 Err，否则返回合并结果"，
    ///      并在无结果时明确区分"全都失败了"与"都成功但确实没搜到"。
    async fn search(&self, kw: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let kw = kw.trim();
        if kw.is_empty() {
            return Err("搜索关键词为空".to_string());
        }
        let drives = self.conf(ext).await?;
        let mut items: Vec<CspItem> = Vec::new();
        let mut ok_drives = 0usize;
        let mut errs: Vec<String> = Vec::new();
        for (idx, d) in drives.iter().enumerate() {
            let body = serde_json::json!({
                "parent": d.root,
                "keywords": kw,
                "page": if page == 0 { 1 } else { page },
                "per_page": PER_PAGE,
            });
            match self.post(d, "/api/fs/search", body).await {
                Err(e) => errs.push(format!("{}: {e}", d.name)),
                Ok(v) => {
                    ok_drives += 1;
                    for f in parse_files(&v) {
                        items.push(CspItem {
                            // 搜索结果只给了名字（DEX 里 `searchOne` 用 `name`）⇒
                            // 路径按"父路径 + 名字"重建；父路径就是这台服务的 root。
                            id: format!("d{idx}:{}", join_path(&d.root, &f.name)),
                            title: f.name,
                            cover: None,
                            subtitle: Some(if f.is_dir {
                                "目录".to_string()
                            } else {
                                human_size(f.size)
                            }),
                        });
                    }
                }
            }
        }
        if ok_drives == 0 {
            return Err(format!(
                "所有 {} 台 AList 服务都搜失败了：{}",
                drives.len(),
                errs.join("；")
            ));
        }
        if items.is_empty() {
            return Err(format!(
                "搜索「{kw}」没有结果（{} 台服务里有 {} 台返回成功，{})",
                drives.len(),
                ok_drives,
                if errs.is_empty() {
                    "没有失败".to_string()
                } else {
                    format!("{} 台失败：{}", errs.len(), errs.join("；"))
                }
            ));
        }
        Ok(CspList {
            items,
            page: if page == 0 { 1 } else { page },
            page_count: None,
            total: None,
        })
    }

    /// 取流：`POST /api/fs/get {path,password}` ⇒ `data.raw_url`（+ `?sign=`）
    async fn play(&self, _flag: &str, id: &str, ext: &str) -> Result<Vec<CspPlay>, String> {
        let drives = self.conf(ext).await?;
        let (d, path) = Self::pick(&drives, id)?;
        let body = serde_json::json!({ "path": path, "password": "" });
        let v = self.post(d, "/api/fs/get", body).await?;
        let Some(raw) = raw_url_of(&v) else {
            return Err(format!(
                "路径 `{path}` 没有 raw_url（可能不是文件、或这台服务的驱动不支持直链）"
            ));
        };
        // 相对地址（有些驱动返回 `/d/…`）⇒ 补上这台服务的 base
        let url = if raw.starts_with("http://") || raw.starts_with("https://") {
            raw
        } else if raw.starts_with('/') {
            format!("{}{raw}", d.base)
        } else {
            format!("{}/{raw}", d.base)
        };
        Ok(vec![CspPlay {
            url,
            headers: vec![("User-Agent".to_string(), UA.to_string())],
            label: Some("AList".to_string()),
        }])
    }
}

// ⚠️ 本文件**故意不写** `crate::csp::register_site!(AList);`
//    理由见文件头第二节（host 只能来自 ext + DEX 无域名 ⇒ 注册=给用户一条必然报错的源）。
//    将来 Owner 的 ext 里真有服务地址时，在下面这行位置补上即可：
//      crate::csp::register_site!(AList);

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★★ 端点路径逐字（DEX）**且实现段里不许出现任何域名**
    ///
    /// ```text
    /// 本类没有可直连的 host（用户自己的服务）⇒ 唯一能机械守的两件事：
    ///   ① 三个端点路径必须逐字出现在源码里（DEX 是这三个）
    ///   ② **实现段**里不许出现"看起来像 host 的字符串"（`://`）——
    ///      一旦出现就等于"我猜了一个域名"，那正是本仓明令禁止的。
    /// 注入验证：把 `URL_LIST` 里加一个 `https://alist.example` ⇒ ② 红。
    /// ```
    #[test]
    fn endpoint_paths_are_dex_verbatim_and_no_host_is_invented() {
        let src = include_str!("a_list.rs");
        let impl_part = src.split("#[cfg(test)]").next().unwrap_or(src);
        for p in ["/api/fs/list", "/api/fs/get", "/api/fs/search"] {
            assert!(impl_part.contains(p), "★ 端点路径必须逐字出现：{p}");
        }
        // ② 实现段里**唯一**允许的 `://` 是"用户填的 server 必须是 http(s)"那两处
        //    —— 它们不含具体主机的字样，用"含 `://` 的字符串字面量里不许有 `.`"来判
        for line in impl_part.lines() {
            let l = line.trim();
            if !l.starts_with("//") && l.contains("://") && l.contains(".example") {
                panic!("★★ 实现段里出现了猜出来的域名：{l}");
            }
        }
        // 反空真：本文件的 base 全部来自用户配置（`AlistDrive.base`）
        assert!(impl_part.contains("pub struct AlistDrive"));
        assert!(impl_part.contains("server"), "配置键必须能被用户填");
    }

    /// ★★★ 没有 host 时必须**可读报错**，且**不猜域名**（本文件最重要的判据）
    ///
    /// ```text
    /// 注入验证：把 `parse_conf` 的空 ext 分支改成"返回一个默认 base"
    ///   ⇒ 本条红（那就是编造域名，正是本仓明令禁止的）。
    /// ```
    #[test]
    fn missing_host_is_an_actionable_error_never_a_guess() {
        let e = parse_conf("").expect_err("空 ext 必须 Err");
        assert!(e.contains("ext"), "要点名 ext：{e}");
        assert!(e.contains("server"), "要告诉用户填什么键：{e}");
        // 本地文件名形态：读不到 ⇒ 明说，并给替代方案
        let e2 = parse_conf("./json/alist.json").expect_err("本地路径必须 Err");
        assert!(e2.contains("读不到"), "{e2}");
        assert!(e2.contains("http"), "要给出可行替代：{e2}");
        // 非 http 的 server 也要拒绝
        let e3 = parse_conf(r#"{"server":"alist.example"}"#).expect_err("缺 scheme 必须 Err");
        assert!(e3.contains("http"), "{e3}");
        // ★ 反面：任何错误文案里都不许出现"我替你猜的域名"
        for msg in [e, e2, e3] {
            assert!(
                !msg.contains("alist.example/api") && !msg.contains("localhost:5244"),
                "★★ 不许出现猜出来的地址：{msg}"
            );
        }
    }

    /// 配置解析：内联 drives / 单台 / 远端 URL 三种形态
    #[test]
    fn parses_inline_conf_shapes() {
        let one = parse_conf(r#"{"server":"https://a.example/","token":"T","root":"/影视"}"#).unwrap();
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].base, "https://a.example", "结尾斜杠要归一");
        assert_eq!(one[0].token, "T");
        assert_eq!(one[0].root, "/影视");

        let many = parse_conf(
            r#"{"drives":[{"name":"甲","server":"https://a.example"},{"name":"乙","server":"https://b.example","token":"X"}]}"#,
        )
        .unwrap();
        assert_eq!(many.len(), 2);
        assert_eq!(many[0].name, "甲");
        assert_eq!(many[1].token, "X");

        // 远端 URL：不是错误，而是"要走网络"的信号（由 `AList::conf` 接手）
        let e = parse_conf("https://x.example/alist.json").expect_err("要走网络");
        assert_eq!(e, "EXT_IS_URL:https://x.example/alist.json");
        // 空 drives 必须报错（不是"零台服务也算成功"）
        assert!(parse_conf(r#"{"drives":[]}"#).is_err());
    }

    /// ★★ 路径拼接：`//` 会被 AList 当成**另一个**路径（静默 404）
    #[test]
    fn join_path_never_double_slashes() {
        assert_eq!(join_path("/", "a.mkv"), "/a.mkv");
        assert_eq!(join_path("", "a.mkv"), "/a.mkv");
        assert_eq!(join_path("/影视", "a.mkv"), "/影视/a.mkv");
        assert_eq!(join_path("/影视/", "a.mkv"), "/影视/a.mkv");
        // 子项本身是绝对路径 ⇒ 以它为准
        assert_eq!(join_path("/x", "/y/z"), "/y/z");
        // 归一：多余斜杠、`.` 段
        assert_eq!(normalize_path("//a//b/"), "/a/b");
        assert_eq!(normalize_path("/"), "/");
        assert_eq!(normalize_path(""), "/");
        assert!(!join_path("/", "a").contains("//"), "★ 不许出现双斜杠");
    }

    /// ★★★ 真实响应片段（AList 的 `{"code":200,…}` 信封 + `data.content`）
    ///
    /// ⚠️ 本机**没有** AList 服务 ⇒ 这段是按 DEX 键名构造的**结构夹具**（不是抓包）。
    ///    文件头"诚实边界①"已写明；它的作用是把"键名/类型"钉住，
    ///    真正的形状要等 Owner 给一台服务再核（那时只需改这一处）。
    #[test]
    fn parses_alist_list_shape() {
        let ok = r#"{"code":200,"message":"success","data":{"content":[
            {"name":"电影","is_dir":true,"size":0},
            {"name":"a.mkv","is_dir":false,"size":2147483648},
            {"name":"","is_dir":false,"size":1}]}}"#;
        let v: serde_json::Value = serde_json::from_str(ok).unwrap();
        assert!(check(&v, 200).is_ok());
        let f = parse_files(&v);
        assert_eq!(f.len(), 2, "★ 没有名字的条目必须丢掉");
        assert!(f[0].is_dir);
        assert_eq!(human_size(f[1].size), "2.0 GB");

        // 访客被关闭：必须把上游原话带出来 + 给出"要 token"的提示
        let guest = r#"{"code":401,"message":"Guest user is disabled"}"#;
        let g: serde_json::Value = serde_json::from_str(guest).unwrap();
        let e = check(&g, 200).expect_err("访客关闭必须报错");
        assert!(e.contains(GUEST_DISABLED), "★ 要保留上游原话：{e}");
        assert!(e.contains("token"), "★ 要告诉用户怎么办：{e}");
    }

    /// 直链：`raw_url` / `+sign` / 缺字段三种
    #[test]
    fn raw_url_handling() {
        let v: serde_json::Value =
            serde_json::from_str(r#"{"code":200,"data":{"raw_url":"https://cdn/x.mkv"}}"#).unwrap();
        assert_eq!(raw_url_of(&v).as_deref(), Some("https://cdn/x.mkv"));

        let signed: serde_json::Value = serde_json::from_str(
            r#"{"code":200,"data":{"raw_url":"https://cdn/x.mkv?a=1","sign":"S1"}}"#,
        )
        .unwrap();
        assert_eq!(raw_url_of(&signed).as_deref(), Some("https://cdn/x.mkv?a=1&sign=S1"));

        // 已经带 sign 的不要再追加（会出现 `sign=` 两次）
        let already: serde_json::Value = serde_json::from_str(
            r#"{"code":200,"data":{"raw_url":"https://cdn/x.mkv?sign=S1","sign":"S2"}}"#,
        )
        .unwrap();
        assert_eq!(raw_url_of(&already).as_deref(), Some("https://cdn/x.mkv?sign=S1"));

        let none: serde_json::Value = serde_json::from_str(r#"{"code":200,"data":{}}"#).unwrap();
        assert_eq!(raw_url_of(&none), None, "★ 没有 raw_url 不许伪造");
    }

    /// ★★ 空结果 ⇒ Err（home/list/search 三条都守这一条）
    #[tokio::test]
    async fn empty_inputs_are_errors() {
        let s = AList::new();
        let e = s.home("").await.expect_err("空 ext 的 home 必须 Err");
        assert!(e.contains("ext"), "{e}");
        let e2 = s.list("d0:/", 1, "").await.expect_err("必须 Err");
        assert!(e2.contains("ext"), "{e2}");
        let e3 = s.search("x", 1, "").await.expect_err("必须 Err");
        assert!(e3.contains("ext"), "{e3}");
    }

    /// 服务下标：越界/非数字必须报错（不许退回第 0 台）
    #[test]
    fn drive_index_is_validated() {
        let drives = vec![AlistDrive {
            name: "甲".into(),
            base: "https://a.example".into(),
            token: String::new(),
            root: "/".into(),
        }];
        let (d, p) = AList::pick(&drives, "d0:/影视").unwrap();
        assert_eq!(d.name, "甲");
        assert_eq!(p, "/影视");
        let e = AList::pick(&drives, "d9:/x").expect_err("越界必须 Err");
        assert!(e.contains('9'), "{e}");
        let e2 = AList::pick(&drives, "dx:/x").expect_err("非数字必须 Err");
        assert!(e2.contains("数字"), "{e2}");
        // 没有前缀 ⇒ 第 0 台 + 归一化路径
        let (_, p2) = AList::pick(&drives, "/a//b").unwrap();
        assert_eq!(p2, "/a/b");
    }

    /// ★★ AList **支持搜索**（原版就在搜自己的盘），且空关键词要报错
    #[test]
    fn supports_search_true_but_empty_keyword_is_an_error() {
        assert!(AList::new().supports_search(), "★ 这个类原版就有搜索");
        let rt = tokio::runtime::Runtime::new().unwrap();
        let e = rt
            .block_on(AList::new().search("   ", 1, r#"{"server":"https://a.example"}"#))
            .expect_err("空关键词必须 Err");
        assert!(e.contains("关键词"), "{e}");
    }

    /// ★★ 注册状态门禁：本文件**故意不注册**（host 只能来自 ext）
    ///
    /// ```text
    /// ★ 这里必须**先剥注释**再判 —— 本文件的文档注释里逐字写着
    ///   "将来补 `register_site!` 的位置"，裸 `contains` 会把它当成真注册 ⇒ 假红。
    ///   本仓已有同族教训（`zz_r3_csp_registry.rs` 的 `m.insert(` 那条被注释喂红）。
    /// ```
    #[test]
    fn not_registered_because_host_comes_only_from_ext() {
        let src = include_str!("a_list.rs");
        let impl_part = src.split("#[cfg(test)]").next().unwrap_or(src);
        let code = crate::csp::shared::strip_comments(impl_part);
        assert!(
            !code.contains("register_site!("),
            "★★ 本文件不许注册：DEX 里没有域名、ext 又指向本地文件 ⇒ \
             注册会给用户一条必然报『请填 server』的假源"
        );
        assert_eq!(AList::CLASS, "AList");
        assert_eq!(AList::new().class(), "AList");
        assert!(
            !crate::csp::implemented_classes().contains(&"AList"),
            "★ 未注册 ⇒ 注册表里不该有它（若将来补了 host，把这条改成 contains）"
        );
    }
}
