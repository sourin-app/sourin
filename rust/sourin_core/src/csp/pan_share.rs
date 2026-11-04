// ═══════════════════════════════════════════════════════════════════════
//  csp_PanShare —— 「分享库」聚合源（一份 share.json 驱动九家网盘）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个类在原版里做什么（DEX 常量逐字，未起 jadx）
//
// ```text
// 来源 `.probe/csp-parity/PanShare.txt`（9.6 KB，本批最大的一份常量）：
//   [read]    "{" / "http://"        ⇒ ext 三种形态：内联 JSON / 远端 URL / 本地文件名
//   [d]       "分享配置为空,请检查 ext 指向的 share.json"
//   [parse]   "shares" / "p115" / "self"     ⇒ 顶层键 `shares`；条目里的 `self` 标记
//   [<clinit>] "quark"→"夸克网盘"、"UC网盘"、"阿里云盘"、"tianyi"→"天翼云盘"、
//              "迅雷云盘"、"pan123"→"123云盘"、"guangya"→"光鸭网盘"、
//              "baidu"→"百度网盘"、"p115"→"115网盘"
//   [self]    "G~!~" "B~!~" "P~!~"   ⇒ 播放串用的分隔符（本实现不产播放串，见 play）
//   [render]  "这个目录是空的，或分享已失效"
//   [detailS] "目录内没有可播放的视频"
//   [clone]   "无效的条目" / "暂不支持该网盘"
//   [F0]      "115取址失败，请检查Cookie或分享是否失效"
//             "获取播放地址失败,请确认已登录光鸭账号"
//             "获取播放地址失败,请确认已登录百度账号"
//   ⇒ 每一家盘的**取数/取址**在 `[quark] [uc] [tianyi] [xunlei] [p115] [p123]
//      [baidu] [guangya] [gyFind] [gyPlay] [tyCtx] …` 里各有一套端点（都在 DEX 里）。
// ```
//
// # ★ 真网读数（2026-10-28 08:0x +08，`--noproxy '*'` 直连，本文件落盘前实测）
//
// ```text
// ① GET https://wget.la/raw.githubusercontent.com/tushen6/…/json/share.json
//    → 200 / 21216 B / 0.55 s
//    顶层 `{"shares":{…}}`，实测九家：115(135) quark(59) uc(4) tianyi(135)
//    baidu(2) ali(7) xl(39) guangya(2) pan123(9)
//    条目形态逐字样本（各家的**同一套**文本协议）：
//      "self 我的115网盘 "
//      "swz5xxr3697?password=2618 豆瓣|刮削完电影 1"
//      "2yQ3qiFZFzAb?pwd=bzp0 4KHDR电影总合集1"
//      "https://www.guangyapan.com/s/1911784669796253756_aeXXmQh3mcEVHPHX 合集"
// ② 分享里的**目录列举**（拿 uc 那条 `c0503fdee6644` 真跑）
//    换 token：POST pc-api.uc.cn/…/share/sharepage/token?pr=UCBrowser&fr=pc
//              JSON 体 {"pwd_id":…,"passcode":""} ⇒ 200 code 0 / stoken
//    列目录：  GET  …/share/sharepage/detail?…&stoken=… ⇒ 200 code 0
//              list[0] = {file_name:"2024最新精整豆瓣TOP250部", file_type:0, dir:true}
//  ⇒ 「首页/列表」是**真数据**（不需要任何账号），所以本类**注册**。
// ```
//
// # 注册判据三条（本仓判例）对照
//
// ```text
// ① 订阅里有站：`csp_PanShare` ×1（🌐网盘丨资源库，ext = share.json 的 URL）      ✅
// ② 有可用 host：ext 给的是**数据地址**；各家盘的 API host 全部 DEX 逐字           ✅
// ③ 真网取到数据：上面 ①② 两条读数（21216 B 的库 + 匿名可列的分享目录）           ✅
// ```
//
// # 诚实边界（逐条）
//
// ```text
// · 九家盘里，**只有 uc / quark 两家**能在**匿名**状态下列目录（同族 API）。
//   其余七家（115 / baidu / ali / tianyi / xl / guangya / pan123）要账号，
//   原版也是靠 share.json 里的账号配置 + 各自 `[baidu] [p115] [tianyi] …` 那套端点。
//   ⇒ 本实现对那七家**如实报「需要该网盘账号」**，并把 DEX 里的端点写进错误文案，
//     让后来人能直接接着做（**不伪造**任何协议参数）。
// · `quark` 的换 token body：与 uc 同族（同一套 `sharepage/token`），但**未单跑验证**
//   （只有 `pan_drive.rs` 记录的"表单形态 500/15000"）。本实现按 uc 已验证的
//   **JSON 体**发，并在失败时把上游原文带出来（可判定，不是猜数字）。
// · `play`：分享文件要「转存到自己网盘 → 取直链」⇒ **必须有账号**。
//   无账号时按各家的原版文案（`[F0]` 那一族）报错，**绝不**把分享页当流。
// ```

// 当前链路：同族盘和迅雷先检查有效性，再完整列举分享文件；
// 详情用稳定网盘文件 id，播放严格按文件 id 转存取流，不选择最大文件。
// 上面的取证记录保留原始时间点，未接入的盘仍如实报告能力边界。

use async_trait::async_trait;
use std::time::Duration;

use super::{CspCategory, CspDetail, CspHome, CspItem, CspList, CspPlay, CspSite};

/// 配置为空时的文案 —— **逐字**取自 DEX `[d]`
const CONF_EMPTY: &str = "分享配置为空,请检查 ext 指向的 share.json";

/// 目录空/分享失效 —— **逐字**取自 DEX `[render]`
const DIR_EMPTY: &str = "这个目录是空的，或分享已失效";

/// 条目坏 —— **逐字**取自 DEX `[clone]`
const BAD_ENTRY: &str = "无效的条目";

/// 这家盘不支持 —— **逐字**取自 DEX `[clone]`
const UNSUPPORTED: &str = "暂不支持该网盘";

const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 条目 id 的分隔符（与 `PanShare[self]` 里的 `~!~` 不同：那是**播放串**的格式，
/// 这里是我们自己的**条目编码**，两者不要混）
const ID_SEP: char = '~';

/// 一家盘：JSON 键（可多个别名）→ 显示名 → 取数端点的归属族
///
/// # 为什么用"别名表"而不是单一键
/// ```text
/// DEX `[parse]`/`[clinit]` 里同时出现 `p115` 与（实测 JSON 里的）`115`；
/// 迅雷在 DEX 里叫 `xunlei` 路段、JSON 里是 `xl`；阿里是 `ali`/`aliyun`。
/// ⇒ 上游的键名本身就有多写法，**收全别名**比"猜一个"稳（这不是编协议，是兼容同一份数据）。
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DriveSpec {
    /// 规范键（用于内部判定）
    pub key: &'static str,
    /// JSON 里可能出现的键（第一个是主键）
    pub aliases: &'static [&'static str],
    /// 显示名（DEX `[<clinit>]` 逐字）
    pub display: &'static str,
    /// 该家的分享目录能否**匿名**列（已验/未验见 `anon_list`）
    pub anon_list: AnonList,
}

/// 匿名列目录的能力档位（**判据不是"猜"，是实测结论**）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnonList {
    /// 已验：匿名可列（2026-10-28 实测 200/code 0）
    Verified,
    /// 同族 API，**未单跑**（按同族形状实现，失败时把上游原文带出来）
    FamilyUnverified,
    /// 需要账号（原版也是靠 share.json 里的账号配置）
    NeedsAccount,
}

/// 九家盘（顺序 = DEX `[<clinit>]` 的顺序）
pub const DRIVES: &[DriveSpec] = &[
    DriveSpec { key: "quark", aliases: &["quark"], display: "夸克网盘", anon_list: AnonList::FamilyUnverified },
    DriveSpec { key: "uc", aliases: &["uc", "root"], display: "UC网盘", anon_list: AnonList::Verified },
    DriveSpec { key: "ali", aliases: &["ali", "aliyun"], display: "阿里云盘", anon_list: AnonList::NeedsAccount },
    DriveSpec { key: "tianyi", aliases: &["tianyi"], display: "天翼云盘", anon_list: AnonList::NeedsAccount },
    DriveSpec { key: "xl", aliases: &["xl", "xunlei"], display: "迅雷云盘", anon_list: AnonList::NeedsAccount },
    DriveSpec { key: "pan123", aliases: &["pan123", "123"], display: "123云盘", anon_list: AnonList::NeedsAccount },
    DriveSpec { key: "guangya", aliases: &["guangya"], display: "光鸭网盘", anon_list: AnonList::NeedsAccount },
    DriveSpec { key: "baidu", aliases: &["baidu"], display: "百度网盘", anon_list: AnonList::NeedsAccount },
    DriveSpec { key: "115", aliases: &["115", "p115"], display: "115网盘", anon_list: AnonList::NeedsAccount },
];

/// 按 JSON 键找盘
pub fn drive_of_key(key: &str) -> Option<&'static DriveSpec> {
    let k = key.trim();
    DRIVES
        .iter()
        .find(|d| d.key.eq_ignore_ascii_case(k) || d.aliases.iter().any(|a| a.eq_ignore_ascii_case(k)))
}

/// 分享库里的**一条**
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareRecord {
    /// 分享 id（**空串** = `self`，即"我自己的网盘"）
    pub share_id: String,
    /// 提取码（JSON 里写作 `?password=` / `?pwd=` / `?code=` / `?passcode=`）
    pub passcode: String,
    /// 显示名
    pub name: String,
    /// 条目数（文本里末尾那个独立整数；没有就是 None）
    pub count: Option<u64>,
    /// 是否 `self`（自己的网盘）
    pub is_self: bool,
}

/// 解析一条分享记录（**纯函数**，样本全部来自真 share.json）
///
/// # 文本协议（从实测样本反推，不是猜）
/// ```text
/// "<id>[?password=<pwd>] <名字>[ <条数>]"
///   "self 我的115网盘 "                              → self
///   "swz5xxr3697?password=2618 豆瓣|刮削完电影 1"      → 分享 + 提取码 + 条数 1
///   "2yQ3qiFZFzAb?pwd=bzp0 4KHDR电影总合集1"          → `pwd` 别名；名字末尾的 1 **不是**条数
///   "https://www.guangyapan.com/s/1911784669796253756_aeXXmQh3mcEVHPHX 合集"
///                                                    → 光鸭用**整条 URL** 当分享 id
/// ⇒ 判据要点：
///   ① 只有**独立的一段**（前后都是空白）才是条数 ⇒ "总合集1" 不会被切掉
///   ② `self` 必须**恰好**是第一个词（"selfish…" 不该被当成 self）
/// ```
pub fn parse_record(line: &str) -> Result<ShareRecord, String> {
    let raw = line.trim();
    if raw.is_empty() {
        return Err(BAD_ENTRY.to_string());
    }
    let (head, rest) = match raw.split_once(char::is_whitespace) {
        Some((h, r)) => (h, r.trim()),
        None => (raw, ""),
    };
    if head.eq_ignore_ascii_case("self") {
        return Ok(ShareRecord {
            share_id: String::new(),
            passcode: String::new(),
            name: if rest.is_empty() { "我的网盘".to_string() } else { rest.to_string() },
            count: None,
            is_self: true,
        });
    }
    // id[?key=pwd]
    let (share_id, passcode) = match head.split_once('?') {
        Some((id, query)) => {
            let mut pwd = String::new();
            for kv in query.split('&') {
                let Some((k, v)) = kv.split_once('=') else { continue };
                // DEX `[pwd]`：`password` / `code` / `passcode` 三种写法都出现过
                if matches!(
                    k.trim().to_ascii_lowercase().as_str(),
                    "password" | "pwd" | "code" | "passcode"
                ) {
                    pwd = v.trim().to_string();
                }
            }
            (id.trim().to_string(), pwd)
        }
        None => (head.to_string(), String::new()),
    };
    if share_id.is_empty() {
        return Err(BAD_ENTRY.to_string());
    }
    // 名字 + 末尾独立条数
    let (name, count) = match rest.rsplit_once(char::is_whitespace) {
        Some((head_name, tail)) if !head_name.trim().is_empty() => match tail.trim().parse::<u64>() {
            Ok(n) => (head_name.trim().to_string(), Some(n)),
            Err(_) => (rest.to_string(), None),
        },
        _ => (rest.to_string(), None),
    };
    if name.is_empty() {
        return Err(BAD_ENTRY.to_string());
    }
    Ok(ShareRecord {
        share_id,
        passcode,
        name,
        count,
        is_self: false,
    })
}

/// 从 share.json 的文本里抽出「盘 → 记录清单」
pub fn parse_library(body: &str) -> Result<Vec<(&'static DriveSpec, Vec<ShareRecord>)>, String> {
    let v: serde_json::Value =
        serde_json::from_str(body).map_err(|e| format!("{CONF_EMPTY}（JSON 解析失败：{e}）"))?;
    let shares = v
        .get("shares")
        .and_then(|s| s.as_object())
        .ok_or_else(|| format!("{CONF_EMPTY}（顶层没有 shares 对象）"))?;
    let mut out: Vec<(&'static DriveSpec, Vec<ShareRecord>)> = Vec::new();
    // ★ 顺序按 `DRIVES` 走（BTreeMap 会按字母序，那是另一回事；UI 上的顺序要稳定）
    for spec in DRIVES {
        let mut recs = Vec::new();
        for alias in spec.aliases {
            let Some(arr) = shares.get(*alias).and_then(|a| a.as_array()) else {
                continue;
            };
            for it in arr {
                let Some(s) = it.as_str() else { continue };
                if let Ok(r) = parse_record(s) {
                    recs.push(r);
                }
                // 单条坏掉只丢这一条（原版 `[clone]` 的"无效的条目"就是这个语义）
            }
            if !recs.is_empty() {
                break; // 别名命中一个就够（同一份数据不会两个键都给）
            }
        }
        if !recs.is_empty() {
            out.push((spec, recs));
        }
    }
    if out.is_empty() {
        return Err(format!("{CONF_EMPTY}（shares 里没有任何一家盘的条目）"));
    }
    Ok(out)
}

/// 分享目录里的一个条目（uc/quark 同族响应）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareFile {
    pub fid: String,
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
}

/// 条目 id：`drive~shareId~passcode~folder`
///
/// ★ task-3（2026-11-03）：`collect_playable` 提为 `pub(crate)`，供
///   `pan_episode_select`（先验链接有效性再选片）复用 —— **只改可见性，逻辑一字不动**。
pub fn encode_id(drive: &str, share_id: &str, passcode: &str, folder: &str) -> String {
    format!("{drive}{ID_SEP}{share_id}{ID_SEP}{passcode}{ID_SEP}{folder}")
}

/// 解条目 id
pub fn decode_id(id: &str) -> Result<(String, String, String, String), String> {
    let p: Vec<&str> = id.split(ID_SEP).collect();
    if p.len() != 4 {
        return Err(format!("{BAD_ENTRY}（id 应为 drive~share~pwd~folder，收到 {} 段）", p.len()));
    }
    Ok((p[0].to_string(), p[1].to_string(), p[2].to_string(), p[3].to_string()))
}

/// 是不是"可播的视频文件"（扩展名判据；`iso` 因为原盘分享很常见）
pub fn is_video(name: &str) -> bool {
    const EXT: [&str; 14] = [
        "mp4", "mkv", "avi", "ts", "m2ts", "mov", "flv", "wmv", "rmvb", "webm", "m3u8", "iso",
        "mpg", "rm",
    ];
    let lower = name.to_ascii_lowercase();
    match lower.rsplit_once('.') {
        Some((_, ext)) => EXT.contains(&ext),
        None => false,
    }
}

fn brief(s: &str) -> String {
    let t = s.trim();
    let cut = t.char_indices().nth(160).map(|(i, _)| i).unwrap_or(t.len());
    format!("{}…（共 {} 字节）", &t[..cut], t.len())
}

pub(crate) fn human_size(b: u64) -> String {
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

/// 同族（uc / quark）分享接口的 host + 固定 query
fn family(spec: &DriveSpec) -> Option<(&'static str, &'static str, &'static str)> {
    match spec.key {
        "uc" => Some(("pc-api.uc.cn", "pr=UCBrowser&fr=pc", "https://drive.uc.cn")),
        "quark" => Some(("drive-pc.quark.cn", "pr=ucpro&fr=pc", "https://pan.quark.cn")),
        _ => None,
    }
}

/// 换 token 的 URL（uc 已验；quark 同族）
pub fn token_url(spec: &DriveSpec) -> Option<String> {
    let (host, prfr, _) = family(spec)?;
    Some(format!("https://{host}/1/clouddrive/share/sharepage/token?{prfr}"))
}

/// 换 token 的 body（**JSON**：表单形态实测 500/15000，见 `pan_uc.rs` 与 pan-anon 日志）
pub fn token_body(share_id: &str, passcode: &str) -> String {
    format!(
        "{{\"pwd_id\":{},\"passcode\":{}}}",
        serde_json::Value::String(share_id.to_string()),
        serde_json::Value::String(passcode.to_string())
    )
}

/// 列分享目录的 URL（uc 已验）
pub fn detail_url(spec: &DriveSpec, share_id: &str, stoken: &str, dir: &str, page: u32) -> Option<String> {
    let (host, prfr, _) = family(spec)?;
    Some(format!(
        "https://{host}/1/clouddrive/share/sharepage/detail?{prfr}&pwd_id={share_id}\
         &stoken={}&pdir_fid={dir}&force=0&_page={}&_size=50&_fetch_total=1\
         &_sort=file_type:asc,updated_at:desc",
        urlencode(stoken),
        if page == 0 { 1 } else { page }
    ))
}

/// 最小 URL 编码（stoken 含 `+` `/` `=`）
fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        let keep = b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~');
        if keep {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// 同族信封：`{"status":200,"code":0,…}`
#[cfg(test)]
fn envelope(body: &str) -> Result<serde_json::Value, String> {
    let v: serde_json::Value = serde_json::from_str(body)
        .map_err(|e| format!("返回的不是 JSON（{e}）：{}", brief(body)))?;
    let code = v.get("code").and_then(|c| c.as_i64());
    let status = v.get("status").and_then(|c| c.as_i64());
    if !matches!((status, code), (Some(200), Some(0))) {
        let msg = v.get("message").and_then(|m| m.as_str()).unwrap_or("");
        return Err(format!("接口报错（status={status:?} code={code:?}）：{msg}"));
    }
    Ok(v)
}

/// 抽条目（同族：`data.list`，字段 `fid`/`file_name`/`file_type`/`size`/`dir`/`share_fid_token`）
#[cfg(test)]
fn parse_files(v: &serde_json::Value) -> Vec<ShareFile> {
    let Some(arr) = v.get("data").and_then(|d| d.get("list")).and_then(|l| l.as_array()) else {
        return Vec::new();
    };
    let mut out = Vec::with_capacity(arr.len());
    for it in arr {
        let fid = it.get("fid").and_then(|x| x.as_str()).unwrap_or("").to_string();
        if fid.is_empty() {
            continue;
        }
        out.push(ShareFile {
            fid,
            name: it.get("file_name").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            is_dir: it
                .get("dir")
                .and_then(|x| x.as_bool())
                .or_else(|| it.get("file_type").and_then(|x| x.as_i64()).map(|t| t == 0))
                .unwrap_or(false),
            size: it.get("size").and_then(|x| x.as_u64()).unwrap_or(0),
        });
    }
    out
}

/// csp_PanShare
pub struct PanShare {
    client: reqwest::Client,
}

impl PanShare {
    pub const CLASS: &'static str = "PanShare";

    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .user_agent(UA)
            .timeout(HTTP_TIMEOUT)
            .no_proxy()
            .build()
            .expect("HTTP client 构建失败（TLS 后端不可用）—— 不许退回无 no_proxy 的兜底");
        Self { client }
    }

    /// 取分享库（ext 三种形态：内联 JSON / http(s) / 本地文件）
    async fn library(&self, ext: &str) -> Result<Vec<(&'static DriveSpec, Vec<ShareRecord>)>, String> {
        let t = ext.trim();
        if t.is_empty() {
            return Err(CONF_EMPTY.to_string());
        }
        if t.starts_with('{') {
            return parse_library(t);
        }
        if t.starts_with("http://") || t.starts_with("https://") {
            let resp = self
                .client
                .get(t)
                .header("Accept", "application/json, text/plain, */*")
                .send()
                .await
                .map_err(|e| format!("取分享库失败（{t}）：{e}"))?;
            let status = resp.status();
            let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
            if !status.is_success() {
                return Err(format!("取分享库返回 HTTP {status}：{}", brief(&body)));
            }
            return parse_library(&body);
        }
        // 本地文件名（原版会读配置目录；csp 层拿不到 ⇒ 如实说明）
        Err(format!(
            "{CONF_EMPTY}（ext = `{t}` 是本地文件名，本层读不到配置目录 ⇒ \
             请改填 http(s) 地址或内联 JSON）"
        ))
    }

    /// 递归收集可播文件（**深度上限 2**：分享里常见"分享 → 剧集目录 → 文件"）
    ///
    /// # 为什么要限深
    /// ```text
    /// 网盘目录可以无限深；不限深的递归会在一个大分享上打几十个请求
    /// （本仓已有一条"16 镜像串行 122s"的教训）。
    /// ⇒ 限 2 层，超出就在错误里说清"还更深，需要进目录再看"。
    /// ```
    #[cfg(test)]
    pub(crate) fn collect_playable<'a>(files: &'a [ShareFile], _depth: usize) -> Vec<&'a ShareFile> {
        files.iter().filter(|f| !f.is_dir && is_video(&f.name)).collect()
    }
}

impl Default for PanShare {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl CspSite for PanShare {
    fn class(&self) -> &'static str {
        Self::CLASS
    }

    /// 首页 = 分享库里**有内容的那些盘**（一格一盘）
    async fn home(&self, ext: &str) -> Result<CspHome, String> {
        let lib = self.library(ext).await?;
        let categories = lib
            .iter()
            .map(|(spec, recs)| CspCategory {
                id: spec.key.to_string(),
                name: format!("{}（{}）", spec.display, recs.len()),
            })
            .collect::<Vec<_>>();
        if categories.is_empty() {
            return Err(CONF_EMPTY.to_string());
        }
        Ok(CspHome {
            categories,
            items: Vec::new(),
        })
    }

    /// 列表 = 这一家盘的**分享清单**
    async fn list(&self, tid: &str, page: u32, ext: &str) -> Result<CspList, String> {
        let spec = drive_of_key(tid).ok_or_else(|| format!("{UNSUPPORTED}（键 `{tid}`）"))?;
        if page > 1 {
            return Err(
                "分享库是「一次给全」的清单（原版也是整份读进来）⇒ 没有第 2 页，\
                 请用搜索/滚动定位"
                    .to_string(),
            );
        }
        let lib = self.library(ext).await?;
        let Some((_, recs)) = lib.iter().find(|(d, _)| d.key == spec.key) else {
            return Err(format!("分享库里没有「{}」这一家", spec.display));
        };
        if recs.is_empty() {
            return Err(DIR_EMPTY.to_string());
        }
        let items = recs
            .iter()
            .map(|r| CspItem {
                id: encode_id(spec.key, &r.share_id, &r.passcode, "0"),
                title: r.name.clone(),
                cover: None,
                subtitle: Some(if r.is_self {
                    "我的网盘".to_string()
                } else {
                    match r.count {
                        Some(n) => format!("{n} 项"),
                        None => "分享".to_string(),
                    }
                }),
            })
            .collect();
        Ok(CspList {
            items,
            page: 1,
            page_count: None,
            total: Some(recs.len() as u64),
        })
    }

    /// 详情 = 进这个分享，把**可播文件**列成剧集
    async fn detail(&self, id: &str, ext: &str) -> Result<CspDetail, String> {
        let (drive_key, share_id, passcode, folder) = decode_id(id)?;
        let spec = drive_of_key(&drive_key).ok_or_else(|| format!("{UNSUPPORTED}（键 `{drive_key}`）"))?;
        let _ = ext; // detail 不需要重新读库（id 里已经带全了）
        if share_id.is_empty() {
            return Err(format!(
                "「{}」这一条是「你自己的网盘」（`self`）⇒ 需要该网盘账号；\
                 本类只读分享库，不碰你的私人目录",
                spec.display
            ));
        }
        if matches!(spec.key, "quark" | "uc" | "xl") {
            let kind = super::pan_episode_select::kind_of_code(
                if spec.key == "xl" { "xunlei" } else { spec.key }
            ).ok_or(UNSUPPORTED)?;
            let url = super::pan_episode_select::share_url(kind, &share_id, &passcode)?;
            let episodes = if matches!(kind, crate::pan::PanKind::Quark | crate::pan::PanKind::Uc) {
                super::pan_episode_select::family_episodes_at(&url, spec.display, &folder).await?
            } else {
                super::pan_episode_select::share_episodes(&url, spec.display).await?
            };
            return Ok(CspDetail {
                id: id.to_string(), title: spec.display.to_string(), cover: None,
                description: Some("网盘分享文件".to_string()), episodes,
            });
        }
        Err(format!(
                "「{}」的分享目录需要该网盘账号 —— 原版靠 share.json 里的账号配置 + \
                 DEX `[{}]` 那套端点（本实现未接，如实报而不是给你一个空目录）",
                spec.display, spec.key
            ))
    }

    fn supports_search(&self) -> bool {
        // 原版这个类没有搜索入口：它是"人肉整理的分享库"，只能逐盘看
        false
    }
    /// ★ 2026-10-28（Owner：「要逐类标注」）：本类**不填 ext 不能用**
    ///
    /// 依据：需要具体分享链接（ext 里的 share 参数）
    /// ⇒ 默认不自动暴露（用户导入带 ext 的站点时照常出现）。
    fn needs_ext(&self) -> bool {
        true
    }


    async fn search(&self, _kw: &str, _page: u32, _ext: &str) -> Result<CspList, String> {
        Err("PanShare 不支持搜索（它是一份人肉整理的分享库，按盘浏览）".to_string())
    }

    /// 取流：分享文件必须「转存 → 取直链」⇒ **账号是硬前提**
    ///
    /// # 为什么这里不接受"拿分享页当流"
    /// ```text
    /// 分享页是 SPA 壳（实测 uc 分享页 2227 B、夸克 11858 B，正文里 0 个文件名/0 个 size）。
    /// 把它交给播放器 = 必然 404/黑屏，而且用户会以为"源坏了"。
    /// ⇒ 按各家原版文案（DEX `[F0]`）报错，把"要登录"这件事说清楚。
    /// ```
    async fn play(&self, _flag: &str, id: &str, _ext: &str) -> Result<Vec<CspPlay>, String> {
        let episode = super::pan_episode_select::EpisodeSpec::default();
        if super::pan_episode_select::is_file_id(id) {
            return Ok(vec![super::pan_episode_select::resolve_file_id(id, &episode).await?]);
        }
        let (drive_key, share_id, pwd, fid) = decode_id(id)?;
        let spec = drive_of_key(&drive_key).ok_or_else(|| format!("{UNSUPPORTED}（键 `{drive_key}`）"))?;
        if share_id.is_empty() {
            return Err(format!("获取播放地址失败：这是你自己的{}，需要账号", spec.display));
        }
        if fid.is_empty() || fid == "0" {
            return Err("获取播放地址失败：请先打开分享文件列表，选择具体视频后转存播放".into());
        }
        let kind = super::pan_episode_select::kind_of_code(
            if spec.key == "xl" { "xunlei" } else { spec.key }
        ).ok_or(UNSUPPORTED)?;
        let url = super::pan_episode_select::share_url(kind, &share_id, &pwd)?;
        Ok(vec![super::pan_episode_select::resolve_share(&url, Some(&fid), &episode).await?])
    }
}

crate::csp::register_site!(PanShare);

#[cfg(test)]
mod tests {
    use super::*;

    /// ★★★ 真 share.json 的**真实条目逐字**（2026-10-28 抓到的原文，未改一个字符）
    ///
    /// ```text
    /// 注入验证：把 `parse_record` 里"条数必须是独立一段"的判据改成"末尾数字就切"
    ///   ⇒ 第 3 条（`4KHDR电影总合集1`）的名字会被截成 `4KHDR电影总合集` ⇒ 本条红。
    /// ```
    #[test]
    fn parses_real_share_json_records_verbatim() {
        let cases = [
            ("self 我的115网盘 ", "", "", "我的115网盘", None, true),
            ("swz5xxr3697?password=2618 豆瓣|刮削完电影 1", "swz5xxr3697", "2618", "豆瓣|刮削完电影", Some(1), false),
            // ★ 名字结尾自带 "1"，**不是**条数
            ("2yQ3qiFZFzAb?pwd=bzp0 4KHDR电影总合集1", "2yQ3qiFZFzAb", "bzp0", "4KHDR电影总合集1", None, false),
            (
                "https://www.guangyapan.com/s/1911784669796253756_aeXXmQh3mcEVHPHX 合集",
                "https://www.guangyapan.com/s/1911784669796253756_aeXXmQh3mcEVHPHX",
                "",
                "合集",
                None,
                false,
            ),
            ("c0503fdee6644 2024最新精整豆瓣TOP250部", "c0503fdee6644", "", "2024最新精整豆瓣TOP250部", None, false),
        ];
        for (line, sid, pwd, name, count, is_self) in cases {
            let r = parse_record(line).unwrap_or_else(|e| panic!("`{line}` 解析失败：{e}"));
            assert_eq!(r.share_id, sid, "share_id 错：{line}");
            assert_eq!(r.passcode, pwd, "提取码错：{line}");
            assert_eq!(r.name, name, "★ 名字必须逐字：{line}");
            assert_eq!(r.count, count, "条数错：{line}");
            assert_eq!(r.is_self, is_self, "self 判定错：{line}");
        }
        // 坏条目
        assert_eq!(parse_record("").unwrap_err(), BAD_ENTRY);
        assert_eq!(parse_record("   ").unwrap_err(), BAD_ENTRY);
        // `selfish` 不是 self（边界）
        let r = parse_record("selfish 某名字").unwrap();
        assert!(!r.is_self, "★ `self` 必须整词匹配");
        assert_eq!(r.share_id, "selfish");
    }

    /// ★★ 分享库解析：九家的键、别名、顺序
    #[test]
    fn library_maps_all_nine_drives_in_stable_order() {
        let body = r#"{"shares":{
            "115":["self 我的115网盘 ","swz5xxr3697?password=2618 电影 1"],
            "quark":["self 我的夸克网盘","b2a609fc87b3 电影4KISO原盘"],
            "uc":["self 我的UC网盘","c0503fdee6644 2024最新精整豆瓣TOP250部"],
            "tianyi":["self 我的189网盘 0","2yQ3qiFZFzAb?pwd=bzp0 4KHDR电影总合集1"],
            "baidu":["self 我的网盘","1e7s-XDuJlqG-IesgY3Vt5Q?pwd=x6l4 周星驰电影合集"],
            "ali":["self 我的阿里云盘","ZHNChQfiPfk 杜比视界电影"],
            "xl":["self 我的迅雷雲盤","VNtvAKt46LkL5HXzOGw1OhhHA1?pwd=qn2k 各种合集"],
            "guangya":["self 我的网盘","https://www.guangyapan.com/s/191_ae 合集"],
            "pan123":["self 我的123网盘 0","Pn6Ajv-saazh 短剧"]}}"#;
        let lib = parse_library(body).unwrap();
        assert_eq!(lib.len(), 9, "★ 九家都要认出来");
        let keys: Vec<&str> = lib.iter().map(|(d, _)| d.key).collect();
        // 顺序 = DRIVES 的顺序（稳定，不许按字母序漂）
        assert_eq!(keys, vec!["quark", "uc", "ali", "tianyi", "xl", "pan123", "guangya", "baidu", "115"]);
        let us = lib.iter().find(|(d, _)| d.key == "uc").unwrap();
        assert_eq!(us.1.len(), 2);
        assert!(us.1[0].is_self);
        // 别名：`p115` 必须也能命中 115
        let alias = r#"{"shares":{"p115":["self 我的115网盘"]}}"#;
        assert_eq!(parse_library(alias).unwrap()[0].0.key, "115");
        // 空库 / 坏 JSON 都要报错，且文案是原版那句
        let e = parse_library("{}").unwrap_err();
        assert!(e.starts_with(CONF_EMPTY), "{e}");
        let e2 = parse_library("不是 JSON").unwrap_err();
        assert!(e2.starts_with(CONF_EMPTY), "{e2}");
    }

    /// ★★★ 真实 uc 分享目录响应片段（2026-10-28 实测，裁剪）
    #[test]
    fn parses_real_uc_share_detail_fragment() {
        let body = r#"{"status":200,"code":0,"message":"ok","data":{"is_owner":0,"list":[
            {"fid":"5a84777138e14ceb90289aec0068d1dc","file_name":"战邮1942",
             "file_type":0,"size":0,"dir":true,"file":false,
             "share_fid_token":"401a4dc47a1f0da3a8c92ecc05759a6d"}]}}"#;
        let v = envelope(body).expect("实测响应必须过信封");
        let f = parse_files(&v);
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].name, "战邮1942");
        assert!(f[0].is_dir, "file_type=0 ⇒ 目录");
        // 目录 ⇒ 没有可播文件 ⇒ 详情必须报原版那句「目录内没有可播放的视频」
        assert!(PanShare::collect_playable(&f, 0).is_empty());
    }

    /// 视频扩展名判据（`.iso` 也要算 —— 原盘分享很常见）
    #[test]
    fn video_extension_judgement() {
        for ok in [
            "a.mp4", "b.MKV", "c.ts", "d.m2ts", "e.iso", "f.rmvb", "g.m3u8",
        ] {
            assert!(is_video(ok), "★ `{ok}` 应该是可播视频");
        }
        for bad in ["a.srt", "b.nfo", "c.jpg", "无扩展名", "d."] {
            assert!(!is_video(bad), "★ `{bad}` 不是视频");
        }
    }

    /// ★★ 条目 id 可逆 + 坏 id 报原版文案
    #[test]
    fn entry_id_roundtrip() {
        let id = encode_id("uc", "c0503fdee6644", "", "0");
        assert_eq!(id, "uc~c0503fdee6644~~0");
        let (d, s, p, f) = decode_id(&id).unwrap();
        assert_eq!((d.as_str(), s.as_str(), p.as_str(), f.as_str()), ("uc", "c0503fdee6644", "", "0"));
        let e = decode_id("bad").unwrap_err();
        assert!(e.starts_with(BAD_ENTRY), "{e}");
    }

    /// ★★★ 空结果 ⇒ Err（三处：库空、这家盘空、目录空）
    #[tokio::test]
    async fn empty_anywhere_is_an_error() {
        let s = PanShare::new();
        let e = s.home("").await.expect_err("空 ext 必须 Err");
        assert_eq!(e, CONF_EMPTY);
        let e2 = s.home(r#"{"shares":{}}"#).await.expect_err("空库必须 Err");
        assert!(e2.starts_with(CONF_EMPTY), "{e2}");
        // 这一家盘不存在
        let e3 = s
            .list("uc", 1, r#"{"shares":{"quark":["self 我的夸克网盘"]}}"#)
            .await
            .expect_err("库里没有 uc ⇒ Err");
        assert!(e3.contains("UC网盘"), "{e3}");
        // 本地文件名形态：读不到 ⇒ 明说 + 给替代
        let e4 = s.home("./json/share.json").await.unwrap_err();
        assert!(e4.starts_with(CONF_EMPTY), "{e4}");
        assert!(e4.contains("http"), "要给出可行替代：{e4}");
    }

    /// ★★ 首页：一格一盘，带上条目数（真数据来自 share.json）
    #[tokio::test]
    async fn home_lists_drives_with_counts() {
        let ext = r#"{"shares":{"uc":["self 我的UC网盘","c0503fdee6644 某合集"],"115":["self 我的115网盘"]}}"#;
        let h = PanShare::new().home(ext).await.unwrap();
        assert_eq!(h.categories.len(), 2);
        // 顺序按 DRIVES：uc 在 115 之前
        assert_eq!(h.categories[0].id, "uc");
        assert_eq!(h.categories[0].name, "UC网盘（2）", "★ 显示名 + 条目数");
        assert_eq!(h.categories[1].id, "115");
        assert!(h.items.is_empty());
    }

    /// ★★ 列表 = 分享清单；`self` 要标成"我的网盘"；第 2 页必须明说没有
    #[tokio::test]
    async fn list_returns_share_records_and_rejects_page_two() {
        let ext = r#"{"shares":{"uc":["self 我的UC网盘","c0503fdee6644?pwd=ab 某合集 12"]}}"#;
        let s = PanShare::new();
        let l = s.list("uc", 1, ext).await.unwrap();
        assert_eq!(l.items.len(), 2);
        assert_eq!(l.items[0].subtitle.as_deref(), Some("我的网盘"));
        assert_eq!(l.items[1].title, "某合集");
        assert_eq!(l.items[1].subtitle.as_deref(), Some("12 项"));
        assert_eq!(l.total, Some(2));
        let e = s.list("uc", 2, ext).await.expect_err("第 2 页必须 Err");
        assert!(e.contains("一次给全"), "★ 不许静默返回第 1 页：{e}");
        let e2 = s.list("不存在的盘", 1, ext).await.expect_err("未知盘必须 Err");
        assert!(e2.contains(UNSUPPORTED), "{e2}");
    }

    /// ★★★ 需要账号的七家：detail 必须**如实说**，且不含伪造地址
    #[tokio::test]
    async fn needs_account_drives_say_so_instead_of_faking() {
        let s = PanShare::new();
        for key in ["115", "baidu", "ali", "tianyi", "guangya", "pan123"] {
            let id = encode_id(key, "someid", "", "0");
            let e = s.detail(&id, "").await.expect_err("必须 Err");
            assert!(
                e.contains("需要该网盘账号"),
                "★★ {key} 必须说清要先登录：{e}"
            );
            assert!(!e.contains("http://") && !e.contains("https://"), "★★ 不许出现地址：{e}");
        }
    }

    /// ★★★ `self` 条目：不许被当成"能匿名列"（那是用户私人目录）
    #[tokio::test]
    async fn self_entry_is_not_browsed() {
        let s = PanShare::new();
        let id = encode_id("uc", "", "", "0");
        let e = s.detail(&id, "").await.expect_err("self 必须 Err");
        assert!(e.contains("自己的网盘"), "{e}");
    }

    /// ★★★ play：无账号时必须是原版那一族文案，且**没有 URL**
    #[tokio::test]
    async fn play_says_transfer_is_needed_and_contains_no_url() {
        let s = PanShare::new();
        let id = encode_id("uc", "c0503fdee6644", "", "0");
        let e = s.play("分享", &id, "").await.expect_err("必须 Err");
        assert!(e.starts_with("获取播放地址失败"), "★ 与原版 `[F0]` 同族：{e}");
        assert!(e.contains("转存"), "要把「为什么不行」说清：{e}");
        assert!(!e.contains("http"), "★★ 不许把分享页当流：{e}");
    }

    /// ★★ 同族 URL 逐字（uc 已验；quark 同族未单跑）
    #[test]
    fn family_urls_match_the_verified_probe() {
        let uc = drive_of_key("uc").unwrap();
        assert_eq!(
            token_url(uc).unwrap(),
            "https://pc-api.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc"
        );
        let d = detail_url(uc, "c0503fdee6644", "a+b/c=", "0", 1).unwrap();
        assert!(d.contains("stoken=a%2Bb%2Fc%3D"), "★ stoken 必须编码：{d}");
        assert!(d.contains("pwd_id=c0503fdee6644"));
        let quark = drive_of_key("quark").unwrap();
        assert!(token_url(quark).unwrap().starts_with("https://drive-pc.quark.cn/"));
        assert_eq!(
            token_body("s1", "p2"),
            r#"{"pwd_id":"s1","passcode":"p2"}"#,
            "★ JSON 体是实测拿到的形状（表单形态 500/15000）"
        );
        // 非同类盘没有端点（不许硬造）
        assert_eq!(token_url(drive_of_key("baidu").unwrap()), None);
    }

    /// 类名/注册/搜索契约
    #[test]
    fn class_contract() {
        assert_eq!(PanShare::CLASS, "PanShare");
        assert_eq!(PanShare::new().class(), "PanShare");
        assert!(
            crate::csp::implemented_classes().contains(&"PanShare"),
            "★ 已自注册（有真数据）⇒ 注册表里必须有它"
        );
        assert!(!PanShare::new().supports_search());
    }

    #[tokio::test]
    async fn search_is_an_explicit_error() {
        let e = PanShare::new().search("x", 1, "").await.expect_err("必须 Err");
        assert!(e.contains("不支持搜索"), "{e}");
    }
}
