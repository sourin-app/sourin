// ═══════════════════════════════════════════════════════════════════════
//  迅雷云盘 分享页 → 直链（T1b 取流 · 2026-11-01 网盘批次）
// ═══════════════════════════════════════════════════════════════════════
//
// # 协议取证（真网 web 客户端 JS 逐字，产物 `.probe/xl-forensics/`）
//
// ```text
// host   : https://api-pan.xunlei.com/drive/v1/…（web 客户端 production env 映射逐字）
// 列表   : GET  share?share_id=&pass_code=&limit=100&pass_code_token=&page_token=
//          （hp0 逐字参数集；响应 share_status_text="OK" + 文件清单）
// 建目录 : POST files {"parent_id":"","name":…,"kind":"drive#folder","space":""}
//          response.file.id；web 端 withCaptcha:true，拒绝时不退回根目录。
// 转存   : POST share/restore
//          {"parent_id":<本次自建目录>,"share_id":…,"pass_code_token":…,
//           "ancestor_ids":[],"file_ids":[…],"specify_parent_id":true}
//          （web 客户端 restoreFolder.id / specify_parent_id 调用点逐字）
// 轮询   : GET  tasks/{restore_task_id}（checkRestoreStatus 逐字；预算封顶）
// 文件   : GET  files/{id}?usage=CONSUME（getFileInfo 逐字）⇒ 直链字段
//          web_content_link（103.js 三处消费逐字：原图/BT/详情）
// 删除   : DELETE files/{id}?space=（fileDelete 逐字）—— 清理临时转存
// 鉴权   : Authorization: Bearer <access_token>（逐字）+ x-device-id / x-client-id
//          （device-sign chunk 逐字）。access_token 来自仓内设备码登录链
//          （pan_login_device → pan_auth 钥匙串，零硬编码）。
// ```
//
// # captcha_sign 为什么不用带（如实）
// ```text
// web 端 per-host 配置表逐字在案：pan.xunlei.com 的签名由 signKey + 远端动态
// 下发的混淆代码（funName/funFile="code-res"）计算 —— 静态不可逆（这正是参考
// APK 把它字符串加密的原因）。但带 Bearer 登录态的取流请求（restore/tasks/
// files/delete）在 web 客户端里**都不挂 withCaptcha**（只有匿名 share/list
// 预检那条传）⇒ 本链路不依赖那个签名。若服务端将来对转存也要 captcha ⇒
// 这里会拿到明确的拒绝响应，按响应如实归因，不硬凑。
// ```
//
// # 转存纪律（照搬夸克族 PanDrive，Owner 的"别堆根目录"教训）
// ```text
// · 播完不删 —— 直链绑文件，删了断流；**下一次解析开头**清上一次的
//   （"Temp" 节律：每次播放转存一份、不复用，与参考实现一致）。
// · 每次新建独立目录，仅登记服务端返回的本次目录 ID；不枚举根目录差集，
//   不复用同名用户目录。建目录协议已逐字取证，但登录态是否足够须真网验收；
//   服务端要求验证码时诚实失败，不退回根目录。
// · 指定集/文件失败不换最大或次大文件；没有具体选片上下文时只接受唯一视频。
// ```

use crate::pan::PanKind;
use super::CspPlay;
use super::pan_playback_guard::{self, PlaybackOwner};

/// API 根（web 客户端 production 档逐字；可被测试回放服务替换）
#[derive(Debug, Clone)]
pub struct XunleiEndpoints {
    /// 形如 `https://api-pan.xunlei.com/drive/v1`
    pub base: String,
}

impl Default for XunleiEndpoints {
    fn default() -> Self {
        #[cfg(test)]
        if let Some(base) = TEST_ENDPOINT.with(|slot| slot.borrow().clone()) {
            return Self { base };
        }
        Self { base: "https://api-pan.xunlei.com/drive/v1".to_string() }
    }
}

/// web 客户端（pan.xunlei.com 档）的 client_id（配置表逐字）
const CLIENT_ID: &str = "Xqp0kJBXWhwaTpB6";
/// hp0 的 client_version（T2 取证逐字；x-client-version 头用）
const CLIENT_VERSION: &str = "1.10.0.2633";

/// 桌面 Chrome UA（与 PanDrive 同形）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

/// 转存轮询预算（次数 × 间隔）。lead 批复：必须封顶，超时如实报。
const RESTORE_POLL_MAX: usize = 10;
const RESTORE_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(1);
const SHARE_MAX_DEPTH: usize = 4;
const SHARE_MAX_REQUESTS: usize = 128;
const SHARE_LIST_BUDGET: std::time::Duration = std::time::Duration::from_secs(60);

/// 进程内稳定的 device-id（x-device-id 头）
///
/// web 客户端取的是设备指纹（浏览器环境）；我们无设备 ⇒ 生成一次、
/// 进程内稳定（同一进程所有请求同值，服务端只要求非空一致）。
fn device_id() -> &'static str {
    static ID: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    ID.get_or_init(|| {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let pid = std::process::id() as u64;
        let mut out = String::with_capacity(32);
        for i in 0..4u64 {
            let mut h: u64 = 0xcbf29ce484222325 ^ (pid.wrapping_add(i));
            for b in format!("{nanos}-{pid}-{i}").bytes() {
                h ^= b as u64;
                h = h.wrapping_mul(0x100000001b3);
            }
            out.push_str(&format!("{h:08x}"));
        }
        out.truncate(32);
        out
    })
}

/// 从钥匙串凭据里取 access_token（`access_token=<…>; refresh_token=<…>`）
///
/// 键名是 pan_login_device 的约定（`token_credential_string`），这里只读。
fn access_token_of(credential: &str) -> Option<String> {
    for pair in credential.split(';') {
        let pair = pair.trim();
        if let Some(v) = pair.strip_prefix("access_token=") {
            let v = v.trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

/// 分享清单里的一个文件
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct XunleiFile {
    pub id: String,
    pub name: String,
    pub size: u64,
    /// 原始 kind（"drive#file" / "drive#folder"；响应没给就是空串）
    pub kind: String,
    /// 清单条目若自带直链（files 列表响应有时直接给）⇒ 免一次 fileinfo
    pub web_content_link: Option<String>,
}

/// 从分享清单/文件清单响应里抽文件条目（**防御性解析**）
///
/// web 端消费者用 `files` 键、hp0 用 `share/list` 族 ⇒ 两把键都认；
/// 条目字段 `id`/`file_id`、`name`、`size`、`kind` 同理。形状认不出 ⇒
/// 形状认不出给静态错误，不回传可能含凭据的原文。
fn parse_file_items(v: &serde_json::Value) -> Result<Vec<XunleiFile>, String> {
    Ok(parse_entries(v)?
        .into_iter()
        .filter(|f| f.kind != "drive#folder")
        .collect())
}

fn parse_entries(v: &serde_json::Value) -> Result<Vec<XunleiFile>, String> {
    let arr = ["files", "list", "file_list", "resources"]
        .iter()
        .find_map(|k| v.get(k).and_then(|x| x.as_array()))
        .ok_or_else(|| "响应里没有文件清单键（files/list/file_list/resources）".to_string())?;
    let mut out = Vec::new();
    for it in arr {
        let id = it
            .get("id")
            .or_else(|| it.get("file_id"))
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        if id.is_empty() {
            continue;
        }
        let kind = it.get("kind").and_then(|x| x.as_str()).unwrap_or("").to_string();
        out.push(XunleiFile {
            id,
            name: it.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            size: it.get("size").and_then(|x| x.as_u64().or_else(|| x.as_str()?.parse().ok())).unwrap_or(0),
            kind,
            web_content_link: direct_link_of(it),
        });
    }
    Ok(out)
}

/// 体积超限类错误（降级触发词）—— 迅雷的具体配额码未逐字取证，
/// 按夸克族 23018 的口径认"限制类"字样，其余错误不降级（如实失败）。
fn is_size_limit_error(text: &str) -> bool {
    let lower = text.to_lowercase();
    ["limit", "exceed", "out of size", "file size", "vip only"]
        .iter()
        .any(|k| lower.contains(k))
}

/// 转存响应的三种结局
enum RestoreOutcome {
    /// restore_status = RESTORE_COMPLETE（同步完成）
    Complete,
    /// 异步：拿 task_id 进轮询
    Task(String),
    /// 明确失败（带原因）
    Failed(String),
}

/// 解析 share/restore 响应（web 消费者字段逐字：restore_status / restore_task_id）
fn parse_restore(v: &serde_json::Value) -> RestoreOutcome {
    let status = v
        .get("restore_status")
        .or_else(|| v.get("status"))
        .and_then(|x| x.as_str())
        .unwrap_or("");
    if status == "RESTORE_COMPLETE" {
        return RestoreOutcome::Complete;
    }
    if let Some(tid) = v
        .get("restore_task_id")
        .or_else(|| v.get("task_id"))
        .and_then(|x| x.as_str())
        .filter(|x| !x.is_empty())
    {
        return RestoreOutcome::Task(tid.to_string());
    }
    RestoreOutcome::Failed(if is_size_limit_error(&v.to_string()) {
        "文件大小或账号配额限制（size limit），请检查迅雷账号配额".to_string()
    } else {
        "服务端未确认转存完成，请稍后重试".to_string()
    })
}

/// 任务轮询的终态判定：true = 完成
fn task_done(v: &serde_json::Value) -> Option<bool> {
    let s = v
        .get("restore_status")
        .or_else(|| v.get("status"))
        .or_else(|| v.get("task_status"))
        .and_then(|x| x.as_str())
        .unwrap_or("");
    match s {
        "RESTORE_COMPLETE" | "SUCCESS" | "2" => Some(true),
        "FAILED" | "ERROR" | "3" => Some(false),
        "" => None,
        _ => None, // RUNNING 等 ⇒ 继续轮询
    }
}

/// 从文件条目里取直链（web_content_link 逐字字段）
fn direct_link_of(it: &serde_json::Value) -> Option<String> {
    it.get("web_content_link")
        .and_then(|x| x.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// 仅记本次 POST 返回的自建目录；按端点、账号、播放器会话与代次清理。
#[derive(Clone)]
struct SavedDirectory {
    base: String,
    account: u64,
    owner: Option<PlaybackOwner>,
    fid: String,
}

static TEMP_SAVED: std::sync::OnceLock<std::sync::Mutex<Vec<SavedDirectory>>> =
    std::sync::OnceLock::new();

fn temp_saved() -> &'static std::sync::Mutex<Vec<SavedDirectory>> {
    TEMP_SAVED.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}

fn account_key(token: &str) -> u64 {
    token.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

fn remember_temp(base: &str, token: &str, fid: &str) {
    temp_saved()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push(SavedDirectory {
            base: base.to_string(), account: account_key(token),
            owner: pan_playback_guard::current_owner(), fid: fid.to_string(),
        });
}

/// ★★★ 把迅雷分享页解析成可播直链（给 provider.rs 的 resolve 出口钩子用）
///
/// 未登录 ⇒ `Err("NEED_LOGIN:xunlei|…")`（classify_err 翻译成 Unauthorized）。
pub async fn resolve(share_id: &str, passcode: &str) -> Result<CspPlay, String> {
    let credential = crate::pan_auth::load(PanKind::Xunlei).map(|c| c.cookie);
    resolve_with(&XunleiEndpoints::default(), credential.as_deref(), share_id, passcode).await
}

fn http_client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(UA)
        .timeout(std::time::Duration::from_secs(15))
        .no_proxy()
        .build()
        .expect("HTTP client 构建失败（TLS 后端不可用）")
}

struct ShareListing {
    files: Vec<XunleiFile>,
    pass_code_token: String,
}

/// The share API itself validates availability before any file is restored.
pub async fn list_share_files(share_id: &str, passcode: &str) -> Result<Vec<XunleiFile>, String> {
    let client = http_client();
    let ep = XunleiEndpoints::default();
    let anonymous = list_share_with(&client, &ep, None, share_id, passcode).await;
    match anonymous {
        Ok(list) => Ok(list.files),
        Err(why) => {
            let credential = crate::pan_auth::load(PanKind::Xunlei).map(|c| c.cookie);
            let token = credential.as_deref().and_then(access_token_of);
            match token {
                Some(token) => list_share_with(&client, &ep, Some(&token), share_id, passcode)
                    .await.map(|list| list.files),
                None => Err(why),
            }
        }
    }
}

async fn list_share_with(
    client: &reqwest::Client,
    ep: &XunleiEndpoints,
    token: Option<&str>,
    share_id: &str,
    passcode: &str,
) -> Result<ShareListing, String> {
    tokio::time::timeout(SHARE_LIST_BUDGET, async {
        use std::collections::{HashSet, VecDeque};
        if share_id.trim().is_empty() {
            return Err("迅雷分享 id 为空".to_string());
        }
        let mut folders = VecDeque::from([(String::new(), 0usize)]);
        let mut visited = HashSet::from([String::new()]);
        let mut file_ids = HashSet::new();
        let mut files = Vec::new();
        let mut pass_code_token = String::new();
        let mut requests = 0usize;
        while let Some((folder, depth)) = folders.pop_front() {
            let mut page_token = String::new();
            let mut pages_seen = HashSet::new();
            loop {
                requests += 1;
                if requests > SHARE_MAX_REQUESTS {
                    return Err("迅雷分享目录过大，未能完整列出文件，请使用更具体的分享目录".to_string());
                }
                let path = if folder.is_empty() { "share" } else { "share/detail" };
                let mut url = reqwest::Url::parse(&format!("{}/{path}", ep.base))
                    .map_err(|_| "迅雷分享 API 地址无效".to_string())?;
                {
                    let mut q = url.query_pairs_mut();
                    q.append_pair("share_id", share_id)
                        .append_pair("pass_code_token", &pass_code_token)
                        .append_pair("limit", "100")
                        .append_pair("page_token", &page_token)
                        .append_pair("thumbnail_size", "SIZE_MEDIUM");
                    if folder.is_empty() {
                        q.append_pair("pass_code", passcode);
                    } else {
                        q.append_pair("parent_id", &folder);
                    }
                }
                let v = get_json_optional(client, token, url.as_str()).await?;
                let status = v.get("share_status_text")
                    .or_else(|| v.get("shareStatusText"))
                    .or_else(|| v.get("share_status"))
                    .and_then(|x| x.as_str()).unwrap_or("");
                if !status.is_empty() && status != "OK" {
                    return Err(match status {
                        "CRITICAL_PRESSURE" | "DELETED" | "EXPIRED" | "NOT_FOUND" | "PASS_CODE_ERROR" =>
                            format!("迅雷分享不可用（share_status_text={status}）"),
                        _ => "迅雷分享不可用，服务端未确认分享有效".to_string(),
                    });
                }
                if let Some(pct) = v.get("pass_code_token")
                    .or_else(|| v.get("passCodeToken"))
                    .and_then(|x| x.as_str()).filter(|s| !s.is_empty()) {
                    pass_code_token = pct.to_string();
                }
                for f in parse_entries(&v)? {
                    if f.kind == "drive#folder" {
                        if visited.insert(f.id.clone()) {
                            if depth >= SHARE_MAX_DEPTH {
                                return Err("迅雷分享目录层级过深，未能完整列出文件，请使用更具体的分享目录".to_string());
                            }
                            folders.push_back((f.id, depth + 1));
                        }
                    } else if super::pan_drive::is_video_name(&f.name) && file_ids.insert(f.id.clone()) {
                        files.push(f);
                    }
                }
                let next = v.get("next_page_token").and_then(|x| x.as_str()).unwrap_or("");
                if next.is_empty() {
                    break;
                }
                if !pages_seen.insert(next.to_string()) {
                    return Err("迅雷分享分页未推进，请稍后重试".to_string());
                }
                page_token = next.to_string();
            }
        }
        if files.is_empty() {
            return Err("迅雷分享里没有可播的视频文件".to_string());
        }
        Ok(ShareListing { files, pass_code_token })
    }).await.map_err(|_| "迅雷分享文件检查超时，请稍后重试".to_string())?
}

pub async fn resolve_selected(
    share_id: &str,
    passcode: &str,
    fid: Option<&str>,
    spec: &super::pan_episode_select::EpisodeSpec,
) -> Result<CspPlay, String> {
    let credential = crate::pan_auth::load(PanKind::Xunlei).map(|c| c.cookie);
    resolve_selected_with(&XunleiEndpoints::default(), credential.as_deref(), share_id, passcode, fid, spec).await
}

pub async fn resolve_selected_with(
    ep: &XunleiEndpoints,
    credential: Option<&str>,
    share_id: &str,
    passcode: &str,
    fid: Option<&str>,
    spec: &super::pan_episode_select::EpisodeSpec,
) -> Result<CspPlay, String> {
    let token = credential.and_then(access_token_of).ok_or_else(|| {
        "NEED_LOGIN:xunlei|还未登录迅雷云盘账号，请前往【配置中心】登录".to_string()
    })?;
    let client = http_client();
    // Listing proves that the selected file still belongs to this live share.
    let list = list_share_with(&client, ep, Some(&token), share_id, passcode).await?;
    let selected = match fid.filter(|s| !s.is_empty()) {
        Some(fid) => list.files.iter().position(|f| f.id == fid)
            .ok_or_else(|| "迅雷分享中已找不到所选视频文件，请刷新选集".to_string())?,
        None => super::pan_episode_select::pick_episode_index(
            spec, &list.files.iter().map(|f| f.name.clone()).collect::<Vec<_>>(),
        )?,
    };
    let _mutation = pan_playback_guard::mutation_lock("xunlei").await;
    pan_playback_guard::check_current()?;
    purge_previous(&client, ep, &token, &pan_playback_guard::current_owner()).await;
    pan_playback_guard::check_current()?;
    let cand = &list.files[selected];
    let mut play = attempt(&client, ep, &token, share_id, &list.pass_code_token, cand).await?;
    play.label = Some(format!("迅雷云盘 · {}", cand.name));
    pan_playback_guard::check_current()?;
    Ok(play)
}

/// 可注入端点 + 可注入凭据的内核（门禁用回放服务直接打）
///
/// `credential`：pan_auth 里存的原始串（None = 未登录）。
pub async fn resolve_with(
    ep: &XunleiEndpoints,
    credential: Option<&str>,
    share_id: &str,
    passcode: &str,
) -> Result<CspPlay, String> {
    let spec = super::pan_episode_select::EpisodeSpec { title: String::new(), order: None };
    resolve_selected_with(ep, credential, share_id, passcode, None, &spec).await
}

async fn post_json(
    client: &reqwest::Client, ep: &XunleiEndpoints, token: &str,
    path: &str, body: &serde_json::Value,
) -> Result<serde_json::Value, String> {
    let resp = client.post(format!("{}/{path}", ep.base))
        .bearer_auth(token)
        .header("x-device-id", device_id())
        .header("x-client-id", CLIENT_ID)
        .header("x-client-version", CLIENT_VERSION)
        .header("Origin", "https://pan.xunlei.com")
        .header("Referer", "https://pan.xunlei.com/")
        .json(body).send().await
        .map_err(|e| format!("迅雷请求失败：{}", e.without_url()))?;
    let status = resp.status().as_u16();
    let body = resp.text().await.map_err(|e| format!("读迅雷响应失败：{}", e.without_url()))?;
    if let Some(err) = login_expired_error(status, &body) { return Err(err); }
    if !(200..300).contains(&status) {
        return Err(if is_size_limit_error(&body) {
            format!("迅雷返回 HTTP {status}：文件大小或账号配额限制（size limit）")
        } else {
            format!("迅雷返回 HTTP {status}，请求被拒绝，请检查登录态或验证码要求")
        });
    }
    serde_json::from_str(&body).map_err(|_| "迅雷响应不是 JSON，请稍后重试".to_string())
}

async fn create_owned_directory(
    client: &reqwest::Client, ep: &XunleiEndpoints, token: &str,
) -> Result<String, String> {
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let seq = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    pan_playback_guard::check_current()?;
    let v = post_json(client, ep, token, "files", &serde_json::json!({
        "parent_id":"", "name":format!("sourin-play-{}-{seq}", device_id()),
        "kind":"drive#folder", "space":"",
    })).await?;
    let file = v.get("file").ok_or("迅雷未返回新建目录标识，不能安全转存")?;
    let fid = file.get("id").and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty() && !s.chars().any(char::is_control))
        .ok_or("迅雷未返回新建目录标识，不能安全转存")?;
    if file.get("kind").and_then(|v| v.as_str()).is_some_and(|s| s != "drive#folder") {
        return Err("迅雷返回的对象不是目录，不能安全转存".into());
    }
    remember_temp(&ep.base, token, fid);
    pan_playback_guard::check_current()?;
    Ok(fid.to_string())
}

/// 单个候选：新建专属目录 → restore → 轮询 → 目录内确认文件 → 直链。
async fn attempt(
    client: &reqwest::Client,
    ep: &XunleiEndpoints,
    token: &str,
    share_id: &str,
    pass_code_token: &str,
    cand: &XunleiFile,
) -> Result<CspPlay, String> {
    let directory = create_owned_directory(client, ep, token).await?;
    pan_playback_guard::check_current()?;
    let rv = post_json(client, ep, token, "share/restore", &serde_json::json!({
        "parent_id":directory, "share_id":share_id, "pass_code_token":pass_code_token,
        "ancestor_ids":[], "file_ids":[cand.id], "specify_parent_id":true,
    })).await?;
    match parse_restore(&rv) {
        RestoreOutcome::Failed(why) => return Err(format!("迅雷转存被拒：{why}")),
        RestoreOutcome::Task(tid) => {
            poll_until_done(client, ep, token, &tid, RESTORE_POLL_INTERVAL).await?;
        }
        RestoreOutcome::Complete => {}
    }

    pan_playback_guard::check_current()?;
    let files = list_directory_files(client, ep, token, &directory).await?;
    let matches: Vec<_> = files.iter()
        .filter(|f| f.name == cand.name && f.size == cand.size)
        .collect();
    let restored = match matches.as_slice() {
        [file] => *file,
        [] => return Err(
            format!(
                "迅雷转存完成，但本次专属目录里找不到所选「{}」（清单可能尚未同步）",
                cand.name
            )
        ),
        _ => return Err("迅雷转存后出现多个同名同大小文件，无法确认所选文件，请稍后重试".to_string()),
    };

    // 直链：清单条目若自带 web_content_link 就直接用；否则 files/{id}?usage=CONSUME
    let link = match restored.web_content_link.clone().filter(|s| !s.is_empty()) {
        Some(l) => l,
        None => {
            let info_url = format!("{}/files/{}?usage=CONSUME", ep.base, urlencode(&restored.id));
            let iv = get_json(client, ep, token, &info_url).await?;
            direct_link_of(&iv).ok_or_else(|| "迅雷文件详情里没有 web_content_link".to_string())?
        }
    };
    // 直链的 UA 约束未取证（web 端直链消费不在本轮证据里）⇒ 带桌面 UA 交给
    // 真机验收暴露；响应里若有 UA 提示字段，见到再加（不猜）。
    pan_playback_guard::check_current()?;
    Ok(CspPlay {
        url: link,
        headers: vec![("User-Agent".to_string(), UA.to_string())],
        label: None,
    })
}

async fn list_directory_files(
    client: &reqwest::Client,
    ep: &XunleiEndpoints,
    token: &str,
    directory: &str,
) -> Result<Vec<XunleiFile>, String> {
    tokio::time::timeout(SHARE_LIST_BUDGET, async {
        let mut files = Vec::new();
        let mut page = String::new();
        let mut seen = std::collections::HashSet::new();
        for _ in 0..SHARE_MAX_REQUESTS {
            let mut url = reqwest::Url::parse(&format!("{}/files", ep.base))
                .map_err(|_| "迅雷文件 API 地址无效".to_string())?;
            url.query_pairs_mut().append_pair("parent_id", directory)
                .append_pair("limit", "100").append_pair("with", "has_subfolder")
                .append_pair("page_token", &page);
            let v = get_json(client, ep, token, url.as_str()).await?;
            files.extend(parse_file_items(&v)?);
            let next = v.get("next_page_token").and_then(|x| x.as_str()).unwrap_or("");
            if next.is_empty() {
                return Ok(files);
            }
            if !seen.insert(next.to_string()) {
                return Err("迅雷文件清单分页未推进，请稍后重试".to_string());
            }
            page = next.to_string();
        }
        Err("迅雷文件清单过大，无法确认本次转存文件".to_string())
    }).await.map_err(|_| "迅雷转存文件确认超时，请稍后重试".to_string())?
}

async fn poll_until_done(
    client: &reqwest::Client,
    ep: &XunleiEndpoints,
    token: &str,
    task_id: &str,
    interval: std::time::Duration,
) -> Result<(), String> {
    let url = format!("{}/tasks/{}", ep.base, urlencode(task_id));
    for _ in 0..RESTORE_POLL_MAX {
        tokio::time::sleep(interval).await;
        let tv = get_json(client, ep, token, &url).await?;
        match task_done(&tv) {
            Some(true) => return Ok(()),
            Some(false) => return Err("迅雷转存任务失败，请稍后重试".to_string()),
            None => continue,
        }
    }
    Err("迅雷转存未完成（轮询预算内没有到终态，已保留任务可稍后重试）".to_string())
}

/// 清上一次的临时转存（DELETE files/{id}?space= 逐字；best-effort）
///
/// ★ 只删**本端点账本**记下的 fid（"只删自记"）—— 别的端点记的留在账本里，
///   绝不拿当前端点去盲删（并行/换端点场景会删错，互检 P2 红点）。
async fn purge_previous(
    client: &reqwest::Client, ep: &XunleiEndpoints, token: &str, target: &Option<PlaybackOwner>,
) {
    let dirs: Vec<SavedDirectory> = temp_saved().lock().unwrap_or_else(|e| e.into_inner())
        .iter().filter(|saved| saved.base == ep.base && saved.account == account_key(token)
            && pan_playback_guard::cleanup_matches(&saved.owner, target)).cloned().collect();
    for saved in dirs {
        let fid = &saved.fid;
        let url = format!("{}/files/{}?space=", ep.base, urlencode(fid));
        let r = client
            .delete(&url)
            .bearer_auth(token)
            .header("x-device-id", device_id())
            .header("x-client-id", CLIENT_ID)
            .header("Referer", "https://pan.xunlei.com/")
            .send()
            .await;
        match r {
            Ok(resp) if resp.status().is_success() || matches!(resp.status().as_u16(), 404 | 410) => {
                temp_saved().lock().unwrap_or_else(|e| e.into_inner()).retain(|entry| {
                    !(entry.base == saved.base && entry.account == saved.account
                        && entry.owner == saved.owner && entry.fid == saved.fid)
                });
                crate::applog::write_file_log("PAN", &format!("[XL-PLAY] 已清理上次临时转存 fid={fid}"));
            }
            Ok(resp) => {
                crate::applog::write_file_log(
                    "PAN",
                    &format!("[XL-PLAY] 清理临时转存失败 fid={fid} HTTP {}", resp.status()),
                );
            }
            Err(e) => {
                crate::applog::write_file_log("PAN", &format!("[XL-PLAY] 清理临时转存请求失败：{}", e.without_url()));
            }
        }
    }
}

pub async fn purge_for_owner(target: Option<PlaybackOwner>) {
    let credential = crate::pan_auth::load(PanKind::Xunlei).map(|c| c.cookie);
    let Some(token) = credential.as_deref().and_then(access_token_of) else { return };
    let _mutation = pan_playback_guard::mutation_lock("xunlei").await;
    purge_previous(&http_client(), &XunleiEndpoints::default(), &token, &target).await;
}

/// token 过期/无效的响应形态（HTTP 401，或响应体里的 unauthenticated 族）
/// ⇒ `NEED_LOGIN:xunlei|…`（P2-2，互检 2026-11-01：否则用户无限重试不被
/// 引导重登，与"如实引导"纪律冲突）。
fn login_expired_error(status: u16, body: &str) -> Option<String> {
    let lower = body.to_lowercase();
    if status == 401
        || lower.contains("unauthenticated")
        || lower.contains("unauthorized")
        || lower.contains("token expired")
        || lower.contains("invalid token")
    {
        return Some(format!(
            "NEED_LOGIN:{}|迅雷登录态已过期，请到【配置中心】重新扫码登录",
            PanKind::Xunlei.code()
        ));
    }
    None
}

async fn get_json(
    client: &reqwest::Client,
    _ep: &XunleiEndpoints,
    token: &str,
    url: &str,
) -> Result<serde_json::Value, String> {
    get_json_optional(client, Some(token), url).await
}

async fn get_json_optional(
    client: &reqwest::Client,
    token: Option<&str>,
    url: &str,
) -> Result<serde_json::Value, String> {
    let mut request = client.get(url)
        .header("x-device-id", device_id())
        .header("x-client-id", CLIENT_ID)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://pan.xunlei.com/");
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let resp = request.send()
        .await
        .map_err(|e| format!("迅雷请求失败：{}", e.without_url()))?;
    let status = resp.status();
    let body = resp.text().await.map_err(|e| format!("读响应失败：{}", e.without_url()))?;
    if !status.is_success() {
        // ★ P2-2：token 过期 ⇒ 引导重登（不是裸 HTTP 401 文案）
        if let Some(e) = login_expired_error(status.as_u16(), &body) {
            return Err(e);
        }
        return Err(format!("迅雷返回 HTTP {}", status.as_u16()));
    }
    serde_json::from_str(&body).map_err(|_| "迅雷响应不是 JSON，请稍后重试".to_string())
}

/// query 值转义（仓库无 url crate —— 与 pan.rs 同一个做法，最小实现）
fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
thread_local! {
    static TEST_ENDPOINT: std::cell::RefCell<Option<String>> = const {
        std::cell::RefCell::new(None)
    };
}

#[cfg(test)]
pub(crate) struct TestEndpointGuard {
    previous: Option<String>,
    _thread_bound: std::marker::PhantomData<std::rc::Rc<()>>,
}

#[cfg(test)]
impl Drop for TestEndpointGuard {
    fn drop(&mut self) {
        TEST_ENDPOINT.with(|slot| *slot.borrow_mut() = self.previous.take());
    }
}

#[cfg(test)]
pub(crate) fn debug_override_endpoint(base: String) -> TestEndpointGuard {
    let previous = TEST_ENDPOINT.with(|slot| slot.replace(Some(base)));
    TestEndpointGuard { previous, _thread_bound: std::marker::PhantomData }
}

#[cfg(test)]
pub(crate) fn debug_remember_temp(base: &str, token: &str, fid: &str) {
    remember_temp(base, token, fid);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    // ── 钥匙串隔离（2026-10-31 事故的既定纪律：测试只准写 -test 命名空间）──
    fn isolate_keyring() {
        static ONCE: std::sync::OnceLock<()> = std::sync::OnceLock::new();
        ONCE.get_or_init(|| {
            std::env::set_var("SOURIN_KEYRING_SERVICE", "dsh-media-client-pan-test");
        });
    }
    fn save_test_credential() {
        isolate_keyring();
        crate::pan_auth::save(&crate::pan_auth::PanCredential {
            kind: PanKind::Xunlei,
            account: "test".to_string(),
            cookie: "access_token=TESTTOK; refresh_token=RT".to_string(),
            saved_at: 0,
            expires_at: None,
        })
        .expect("写测试凭据失败");
    }
    // 注：clear_test_credential 已删 —— "清凭据"与并发用例的"写凭据"互踩
    //（并行竞态），且用例里凭据参数直接传 None 即可表达"未登录"。
    // 注：账本**不再用"全局 reset"做用例隔离** —— 那本身就是并发互扰通道
    //（并行用例的 reset 会把别的用例刚记下的账清掉）。账本按端点分账后，
    // 各回放服务端口唯一 ⇒ base 唯一 ⇒ 用例天然互不见账目，无需 reset。
    // 见 ledger_scoped_to_endpoint_and_resettable 的门禁注释。

    // ── 回放服务（真 HTTP，逐字形状夹具）────────────────────────────────
    #[derive(Debug, Clone)]
    struct Recorded {
        method: String,
        target: String,
        authorization: String,
        device_id: String,
        body: String,
    }

    struct Replay {
        base: String,
        hits: Arc<Mutex<Vec<Recorded>>>,
    }

    impl Replay {
        fn requests(&self) -> Vec<Recorded> {
            self.hits.lock().unwrap_or_else(|e| e.into_inner()).clone()
        }
    }

    /// routes: (method, path 前缀, 状态码, 应答体)。命中即记账并应答。
    fn spawn_replay(routes: Arc<Vec<(String, String, u16, String)>>) -> Replay {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回放端口失败");
        let port = listener.local_addr().expect("取端口失败").port();
        let hits: Arc<Mutex<Vec<Recorded>>> = Arc::new(Mutex::new(Vec::new()));
        let hits_bg = hits.clone();
        std::thread::spawn(move || {
            for conn in listener.incoming() {
                let Ok(mut stream) = conn else { break };
                let mut reader = BufReader::new(stream.try_clone().expect("clone"));
                let mut line = String::new();
                let _ = reader.read_line(&mut line);
                let mut parts = line.split_whitespace();
                let method = parts.next().unwrap_or("").to_string();
                let target = parts.next().unwrap_or("").to_string();
                let mut auth = String::new();
                let mut dev = String::new();
                let mut len = 0usize;
                loop {
                    let mut h = String::new();
                    match reader.read_line(&mut h) {
                        Ok(0) | Err(_) => break,
                        Ok(_) if h == "\r\n" || h == "\n" => break,
                        Ok(_) => {
                            let low = h.to_ascii_lowercase();
                            if low.starts_with("authorization:") {
                                auth = h[14..].trim().to_string();
                            }
                            if low.starts_with("x-device-id:") {
                                dev = h[12..].trim().to_string();
                            }
                            if let Some(v) = low.strip_prefix("content-length:") {
                                len = v.trim().parse().unwrap_or(0);
                            }
                        }
                    }
                }
                let mut body = String::new();
                if len > 0 {
                    let mut buf = vec![0u8; len];
                    let _ = reader.read_exact(&mut buf);
                    body = String::from_utf8_lossy(&buf).to_string();
                }
                if let Ok(mut g) = hits_bg.lock() {
                    g.push(Recorded {
                        method: method.clone(),
                        target: target.clone(),
                        authorization: auth,
                        device_id: dev,
                        body,
                    });
                }
                let matching: Vec<_> = routes.iter()
                    .filter(|(m, p, _, _)| method.eq_ignore_ascii_case(m) && target.starts_with(p.as_str()))
                    .collect();
                let hit = matching.first().map(|first| {
                    let count = hits_bg.lock().unwrap().iter()
                        .filter(|r| r.method == method && r.target.starts_with(first.1.as_str()))
                        .count();
                    matching[(count - 1) % matching.len()]
                });
                let (status, resp_body) = match hit {
                    Some((_, _, s, b)) => (*s, b.clone()),
                    None => (404u16, "{\"error\":\"not in replay\"}".to_string()),
                };
                let resp = format!(
                    "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    status,
                    if status == 200 { "OK" } else { "Err" },
                    resp_body.len(),
                    resp_body
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.flush();
            }
        });
        Replay { base: format!("http://127.0.0.1:{port}/drive/v1"), hits }
    }

    /// 场景 A：清单条目不带 web_content_link ⇒ 走 files/{id}?usage=CONSUME
    fn full_routes() -> Arc<Vec<(String, String, u16, String)>> {
        Arc::new(vec![
            (
                "GET".into(),
                "/drive/v1/share?".into(),
                200,
                r#"{"share_status_text":"OK","pass_code_token":"pctok","files":[
                    {"id":"d1","name":"字幕","size":0,"kind":"drive#folder"},
                    {"id":"f1","name":"movie.mkv","size":123,"kind":"drive#file"}]}"#
                    .into(),
            ),
            (
                "POST".into(),
                "/drive/v1/share/restore".into(),
                200,
                r#"{"restore_status":"RESTORE_COMPLETE","restore_task_id":"t1","file_id":"rootfolder"}"#
                    .into(),
            ),
            (
                "GET".into(),
                "/drive/v1/files?".into(),
                200,
                r#"{"files":[{"id":"xf1","name":"movie.mkv","size":123,"kind":"drive#file"}]}"#.into(),
            ),
            (
                "GET".into(),
                "/drive/v1/files/xf1?".into(),
                200,
                r#"{"id":"xf1","name":"movie.mkv","web_content_link":"http://127.0.0.1:9/direct.mkv"}"#
                    .into(),
            ),
            ("DELETE".into(), "/drive/v1/files/".into(), 200, "{}".into()),
            (
                "GET".into(),
                "/drive/v1/files?".into(),
                200,
                r#"{"files":[{"id":"xf1","name":"movie.mkv","size":123,"kind":"drive#file"}]}"#.into(),
            ),
            ("GET".into(), "/drive/v1/share/detail?".into(), 200, r#"{"files":[]}"#.into()),
            ("POST".into(), "/drive/v1/files".into(), 200,
                r#"{"file":{"id":"owned-dir","kind":"drive#folder"}}"#.into()),
        ])
    }

    // ── 纯函数门禁 ──────────────────────────────────────────────────────

    /// 清单解析：files/list 两把键、目录排除、形状认不出 ⇒ Err（不猜）
    #[test]
    fn parse_file_items_is_defensive() {
        let files = parse_file_items(&serde_json::json!({
            "files": [
                {"id":"f1","name":"a.mkv","size":10,"kind":"drive#file"},
                {"id":"d1","name":"dir","size":0,"kind":"drive#folder"}
            ]
        }))
        .expect("files 键要认");
        assert_eq!(files.len(), 1, "目录必须被排除");
        assert_eq!(files[0].id, "f1");

        let list = parse_file_items(&serde_json::json!({
            "list": [{"file_id":"x1","name":"b.mp4","size":5}]
        }))
        .expect("list 键也要认（hp0 形状）");
        assert_eq!(list[0].id, "x1");

        let err = parse_file_items(&serde_json::json!({"something":"else"}))
            .expect_err("形状认不出必须 Err");
        assert!(err.contains("文件清单键"), "{err}");
    }

    #[test]
    fn access_token_parsing_and_size_limit_words() {
        assert_eq!(
            access_token_of("access_token=AT; refresh_token=RT").as_deref(),
            Some("AT")
        );
        assert_eq!(access_token_of("refresh_token=RT"), None, "只有 refresh 不算");
        assert_eq!(access_token_of("access_token=  "), None, "空 token 不算");
        assert!(is_size_limit_error("exceed download limit"));
        assert!(!is_size_limit_error("server busy"));
    }

    #[test]
    fn device_id_is_stable_within_process() {
        assert_eq!(device_id(), device_id());
        assert_eq!(device_id().len(), 32);
    }

    // ── 全链门禁（真 HTTP 回放）────────────────────────────────────────

    /// 清单 OK → 新建目录 → restore（body 逐字参数）→ 目录内选片 → 直链。
    ///
    /// 证红：把 get_json/restore 的 `bearer_auth` 拿掉 ⇒ 本条红
    ///      （红在"请求缺 Bearer 头"——服务端记账逐请求断言）。
    #[tokio::test]
    async fn full_chain_yields_direct_link_and_records_verbatim_params() {
        save_test_credential();
        let routes = full_routes();
        let srv = spawn_replay(routes.clone());
        let ep = XunleiEndpoints { base: srv.base.clone() };

        let out = resolve_with(&ep, Some("access_token=TESTTOK; refresh_token=RT"), "share123", "pwd9")
            .await
            .expect("全链不该失败");
        assert_eq!(out.url, "http://127.0.0.1:9/direct.mkv", "{:?}", out.url);
        let label = out.label.as_deref().unwrap_or("");
        assert!(label.contains("迅雷云盘") && label.contains("movie.mkv"), "{label}");
        assert_eq!(out.headers[0].0, "User-Agent", "直链要带 UA（约束未取证，带桌面 UA 交给真机验收）");

        let reqs = srv.requests();
        // ① 每个请求都带 Bearer + x-device-id（鉴权纪律的服务端记账断言）
        assert!(!reqs.is_empty());
        for r in &reqs {
            assert_eq!(r.authorization, "Bearer TESTTOK", "缺 Bearer：{}", r.target);
            assert_eq!(r.device_id.len(), 32, "缺 x-device-id：{}", r.target);
        }
        // ② restore body 的逐字参数
        let restore = reqs
            .iter()
            .find(|r| r.target.starts_with("/drive/v1/share/restore"))
            .expect("必须有转存请求");
        assert!(restore.body.contains("\"parent_id\":\"owned-dir\""), "专属目录形态：{}", restore.body);
        assert!(restore.body.contains("\"specify_parent_id\":true"), "{}", restore.body);
        assert!(restore.body.contains("\"ancestor_ids\":[]"), "{}", restore.body);
        assert!(restore.body.contains("\"file_ids\":[\"f1\"]"), "{}", restore.body);
        assert!(restore.body.contains("\"pass_code_token\":\"pctok\""), "{}", restore.body);
        // ③ 列表请求带了提取码与 share_id
        let list = reqs
            .iter()
            .find(|r| r.target.starts_with("/drive/v1/share?"))
            .expect("必须有清单请求");
        assert!(list.target.contains("share_id=share123"), "{}", list.target);
        assert!(list.target.contains("pass_code=pwd9"), "{}", list.target);
        // ④ 下一次解析开头清上一次的转存（"Temp" 节律 —— 夸克族同款）
        let _ = resolve_with(&ep, Some("access_token=TESTTOK"), "share123", "pwd9")
            .await
            .expect("第二次解析不该失败");
        let deletes: Vec<Recorded> = srv
            .requests()
            .into_iter()
            .filter(|r| r.method == "DELETE")
            .collect();
        assert_eq!(deletes.len(), 1, "第二次解析开头必须 DELETE 上一次的转存");
        assert!(deletes[0].target.contains("files/owned-dir"), "{}", deletes[0].target);
    }

    /// ★ 未登录 ⇒ NEED_LOGIN（classify_err 翻译成 Unauthorized，与夸克族同约定）
    ///
    /// ★ 并行安全：凭据传 **None**（不碰钥匙串）——并发用例在写同一把测试
    ///   凭据，这里任何"先清空"的动作都会跟它们互踩（2026-11-02 复盘）。
    #[tokio::test]
    async fn no_credential_is_need_login() {
        let srv = spawn_replay(full_routes());
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let err = resolve_with(&ep, None, "share123", "")
            .await
            .expect_err("未登录必须 Err");
        assert!(err.starts_with("NEED_LOGIN:xunlei|"), "{err}");
        // 凭据在但没有 access_token=（形状坏了）⇒ 同样引导重登，不是裸 500
        let err = resolve_with(&ep, Some("refresh_token=RT"), "share123", "")
            .await
            .expect_err("坏形状凭据也要 Err");
        assert!(err.starts_with("NEED_LOGIN:xunlei|"), "{err}");
    }

    /// ★ share_status_text != OK ⇒ 如实报（hp0 判据），不打清单不转存
    #[tokio::test]
    async fn share_not_ok_is_honest() {
        save_test_credential();
        let routes = Arc::new(vec![(
            "GET".into(),
            "/drive/v1/share?".into(),
            200,
            r#"{"share_status_text":"CRITICAL_PRESSURE"}"#.into(),
        )]);
        let srv = spawn_replay(routes);
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let err = resolve_with(&ep, Some("access_token=TESTTOK"), "share123", "")
            .await
            .expect_err("非 OK 必须 Err");
        assert!(err.contains("CRITICAL_PRESSURE"), "{err}");
        assert!(srv.requests().iter().all(|r| !r.target.contains("/share/restore")), "不许转存");
    }

    /// ★ P2-2：token 过期（HTTP 401 / unauthenticated 族）⇒ NEED_LOGIN 引导重登
    ///            （restore 与 GET 两跳都要认 —— 过期可能死在任意一跳）。
    ///
    /// 证红：把 get_json/restore 里的 `login_expired_error` 分支删掉 ⇒ 本条红
    ///      （红在"拿到的是裸 HTTP 401 文案，不是 NEED_LOGIN"）。
    #[tokio::test]
    async fn token_expired_maps_to_need_login() {
        save_test_credential();
        // ① 列表那跳 401
        let routes = Arc::new(vec![(
            "GET".into(),
            "/drive/v1/share?".into(),
            401,
            r#"{"error":"unauthenticated","error_description":"token 过期"}"#.into(),
        )]);
        let srv = spawn_replay(routes);
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let err = resolve_with(&ep, Some("access_token=STALE"), "share123", "")
            .await
            .expect_err("token 过期必须 Err");
        assert!(
            err.starts_with("NEED_LOGIN:xunlei|") && err.contains("重新扫码"),
            "★ 过期要翻译成引导重登，实际：{err}"
        );
        // ② 转存那跳 401（清单过了、转存被拒）
        let routes2 = Arc::new(vec![
            (
                "GET".into(),
                "/drive/v1/share?".into(),
                200,
                r#"{"share_status_text":"OK","files":[{"id":"f1","name":"movie.mkv","size":123,"kind":"drive#file"}]}"#.into(),
            ),
            (
                "POST".into(),
                "/drive/v1/share/restore".into(),
                401,
                r#"{"error":"unauthorized"}"#.into(),
            ),
            ("GET".into(), "/drive/v1/files?".into(), 200, r#"{"files":[]}"#.into()),
            ("POST".into(), "/drive/v1/files".into(), 200,
                r#"{"file":{"id":"owned-dir","kind":"drive#folder"}}"#.into()),
        ]);
        let srv2 = spawn_replay(routes2);
        let ep2 = XunleiEndpoints { base: srv2.base.clone() };
        let err = resolve_with(&ep2, Some("access_token=STALE"), "share123", "")
            .await
            .expect_err("转存跳过期同样必须引导重登");
        assert!(err.starts_with("NEED_LOGIN:xunlei|"), "{err}");
    }

    /// ★★ 并行安全断言（互检 P2 红点的回归门禁）：账本按端点分账、用例可重置
    ///
    /// ```text
    /// · 端点 A 解析一次（A 的账本记下 fid）
    /// · 端点 B 解析一次 ⇒ B 的账本为空 ⇒ 对 B **不许有任何 DELETE**
    ///   （旧实现拿"当前端点"删全量账本 ⇒ 并行/换端点场景盲删）
    /// · 回到 A 再解析 ⇒ A 清**A 自己记的** fid（files/xf1）
    /// ```
    #[tokio::test]
    async fn ledger_scoped_to_endpoint_and_resettable() {
        save_test_credential();
        // 端点 A：解析一次（记下 A 的账）
        let srv_a = spawn_replay(full_routes());
        let ep_a = XunleiEndpoints { base: srv_a.base.clone() };
        resolve_with(&ep_a, Some("access_token=TESTTOK"), "share123", "pwd9")
            .await
            .expect("A 第一次解析");
        // 端点 B：B 的账本为空 ⇒ 不许对 B 发任何 DELETE
        let srv_b = spawn_replay(full_routes());
        let ep_b = XunleiEndpoints { base: srv_b.base.clone() };
        resolve_with(&ep_b, Some("access_token=TESTTOK"), "share123", "pwd9")
            .await
            .expect("B 解析");
        assert!(
            srv_b.requests().iter().all(|r| r.method != "DELETE"),
            "★ 跨端点盲删：A 记的 fid 不许拿 B 的端点去删"
        );
        // 回到 A：A 清 A 自己的账
        resolve_with(&ep_a, Some("access_token=TESTTOK"), "share123", "pwd9")
            .await
            .expect("A 第二次解析");
        let deletes: Vec<Recorded> = srv_a
            .requests()
            .into_iter()
            .filter(|r| r.method == "DELETE")
            .collect();
        assert_eq!(deletes.len(), 1, "A 的第二次解析清 A 自己记的 fid");
        assert!(deletes[0].target.contains("files/owned-dir"), "{}", deletes[0].target);
    }

    /// ★ 轮询预算封顶：任务一直 RUNNING ⇒ 到点如实报"转存未完成"
    #[tokio::test]
    async fn restore_poll_budget_is_capped() {
        save_test_credential();
        // restore 给 task_id（异步形态），tasks 永远 RUNNING
        let routes = Arc::new(vec![
            (
                "POST".into(),
                "/drive/v1/share/restore".into(),
                200,
                r#"{"restore_status":"RESTORING","restore_task_id":"t9"}"#.into(),
            ),
            (
                "GET".into(),
                "/drive/v1/tasks/t9".into(),
                200,
                r#"{"status":"RUNNING"}"#.into(),
            ),
        ]);
        let srv = spawn_replay(routes);
        let ep = XunleiEndpoints { base: srv.base.clone() };
        // 直接测轮询内核（1ms 间隔 × 封顶次数 —— 测试不等 10 秒）
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let started = std::time::Instant::now();
        let err = poll_until_done(&client, &ep, "TESTTOK", "t9", std::time::Duration::from_millis(1))
            .await
            .expect_err("永不完成的任务必须 Err");
        assert!(err.contains("转存未完成"), "{err}");
        assert!(started.elapsed() < std::time::Duration::from_secs(5), "封顶要真封顶（实测 {:?}）", started.elapsed());
        let polls = srv
            .requests()
            .iter()
            .filter(|r| r.target.starts_with("/drive/v1/tasks/"))
            .count();
        assert_eq!(polls, RESTORE_POLL_MAX, "轮询次数必须正好封顶");
    }

    /// 文件匹配失败明确报错；本次已知自建目录仍留账，下次同会话清理。
    #[tokio::test]
    async fn failed_match_after_restore_is_honest() {
        save_test_credential();
        // restore 成功，但专属目录清单里对不上名 ⇒ attempt 失败
        let routes = Arc::new(vec![
            ("GET".into(), "/drive/v1/share?".into(), 200,
             r#"{"share_status_text":"OK","files":[{"id":"f1","name":"movie.mkv","size":123,"kind":"drive#file"}]}"#.into()),
            ("POST".into(), "/drive/v1/share/restore".into(), 200,
             r#"{"restore_status":"RESTORE_COMPLETE","restore_task_id":"t1"}"#.into()),
            ("GET".into(), "/drive/v1/files?".into(), 200,
             r#"{"files":[{"id":"other","name":"别的文件","size":1,"kind":"drive#file"}]}"#.into()),
            ("DELETE".into(), "/drive/v1/files/".into(), 200, "{}".into()),
            ("POST".into(), "/drive/v1/files".into(), 200,
                r#"{"file":{"id":"owned-dir","kind":"drive#folder"}}"#.into()),
        ]);
        let srv = spawn_replay(routes);
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let err = resolve_with(&ep, Some("access_token=TESTTOK"), "share123", "")
            .await
            .expect_err("对不上名必须 Err");
        assert!(err.contains("找不到"), "{err}");
        // 当前尝试不立即删除：目录内的异步转存仍可能尚未结束。
        assert!(
            srv.requests().iter().all(|r| r.method != "DELETE"),
            "对不上名时没有任何已知 fid，DELETE 就是盲删"
        );
    }

    #[tokio::test]
    async fn selected_file_does_not_restore_largest_or_another_episode() {
        let mut routes = full_routes().as_ref().clone();
        routes[0].3 = r#"{"share_status_text":"OK","pass_code_token":"pctok","files":[
            {"id":"largest","name":"第1集.mkv","size":"9999","kind":"drive#file"},
            {"id":"f2","name":"第2集.mkv","size":"123","kind":"drive#file"}]}"#.into();
        routes[2].3 = r#"{"files":[{"id":"xf2","name":"第2集.mkv","size":"123","kind":"drive#file"}]}"#.into();
        routes[3].1 = "/drive/v1/files/xf2?".into();
        let srv = spawn_replay(Arc::new(routes));
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let spec = super::super::pan_episode_select::EpisodeSpec {
            title: "第2集".into(), order: Some(2),
        };
        let out = resolve_selected_with(&ep, Some("access_token=TESTTOK"), "share", "", Some("f2"), &spec)
            .await.expect("指定第二集");
        assert!(out.label.as_deref().unwrap_or("").contains("第2集"));
        let restore = srv.requests().into_iter().find(|r| r.target == "/drive/v1/share/restore").unwrap();
        let body: serde_json::Value = serde_json::from_str(&restore.body).unwrap();
        assert_eq!(body["file_ids"], serde_json::json!(["f2"]));
    }

    #[tokio::test]
    async fn absent_selected_file_is_rejected_before_restore() {
        let srv = spawn_replay(full_routes());
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let spec = super::super::pan_episode_select::EpisodeSpec { title: "第2集".into(), order: Some(2) };
        let err = resolve_selected_with(&ep, Some("access_token=TESTTOK"), "share", "", Some("gone"), &spec)
            .await.expect_err("不能退回最大文件");
        assert!(err.contains("找不到"), "{err}");
        assert!(srv.requests().iter().all(|r| r.method != "POST" && r.method != "DELETE"));
    }

    #[tokio::test]
    async fn share_listing_traverses_directories_and_filters_non_video_files() {
        let routes = Arc::new(vec![
            ("GET".into(), "/drive/v1/share?".into(), 200,
                r#"{"share_status_text":"OK","pass_code_token":"pct","files":[
                {"id":"sub","name":"剧集","kind":"drive#folder"},
                {"id":"poster","name":"poster.jpg","kind":"drive#file"}]}"#.into()),
            ("GET".into(), "/drive/v1/share/detail?".into(), 200,
                r#"{"files":[{"id":"f3","name":"第3集.mkv","size":"100","kind":"drive#file"}]}"#.into()),
        ]);
        let srv = spawn_replay(routes);
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let out = list_share_with(&http_client(), &ep, None, "share", "pwd").await.unwrap();
        assert_eq!(out.files.len(), 1);
        assert_eq!(out.files[0].id, "f3");
        assert_eq!(out.files[0].size, 100);
        let reqs = srv.requests();
        assert!(reqs.iter().all(|r| r.authorization.is_empty()));
        let child = reqs.iter().find(|r| r.target.contains("/share/detail?")).unwrap();
        assert!(child.target.contains("parent_id=sub") && child.target.contains("pass_code_token=pct"));
    }

    #[tokio::test]
    async fn repeated_share_page_token_is_not_partial_success() {
        let srv = spawn_replay(Arc::new(vec![
            ("GET".into(), "/drive/v1/share?".into(), 200,
                r#"{"share_status_text":"OK","next_page_token":"same","files":[
                {"id":"f1","name":"第1集.mp4","kind":"drive#file"}]}"#.into()),
        ]));
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let err = list_share_with(&http_client(), &ep, None, "share", "").await.err().unwrap();
        assert!(err.contains("分页"), "{err}");
        assert_eq!(srv.requests().len(), 2);
    }

    #[tokio::test]
    async fn production_restore_checks_task_failure_before_file_lookup() {
        let mut routes = full_routes().as_ref().clone();
        routes[1].3 = r#"{"restore_status":"RESTORING","restore_task_id":"t9"}"#.into();
        routes.push(("GET".into(), "/drive/v1/tasks/t9".into(), 200, r#"{"status":"FAILED"}"#.into()));
        let srv = spawn_replay(Arc::new(routes));
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let err = resolve_with(&ep, Some("access_token=TESTTOK"), "share", "").await.expect_err("失败任务不能取流");
        assert!(err.contains("任务失败"), "{err}");
        let reqs = srv.requests();
        assert_eq!(reqs.iter().filter(|r| r.target.contains("/tasks/")).count(), 1);
        let task = reqs.iter().position(|r| r.target.contains("/tasks/")).unwrap();
        assert!(reqs[task + 1..].iter().all(|r| !r.target.contains("/files?")));
    }

    #[tokio::test]
    async fn preexisting_root_file_is_never_queried_or_registered_for_cleanup() {
        let mut routes = full_routes().as_ref().clone();
        routes.insert(0, ("GET".into(), "/drive/v1/files?parent_id=&".into(), 200,
            r#"{"files":[{"id":"user-file","name":"movie.mkv","size":123}]}"#.into()));
        let srv = spawn_replay(Arc::new(routes));
        let ep = XunleiEndpoints { base: srv.base.clone() };
        resolve_with(&ep, Some("access_token=TESTTOK"), "share", "").await.unwrap();
        resolve_with(&ep, Some("access_token=TESTTOK"), "share", "").await.unwrap();
        let reqs = srv.requests();
        assert!(reqs.iter().all(|r| !r.target.contains("user-file")));
        assert!(reqs.iter().filter(|r| r.method == "GET")
            .all(|r| !r.target.starts_with("/drive/v1/files?parent_id=&")));
    }

    #[tokio::test]
    async fn restore_targets_a_new_owned_directory_not_root_delta() {
        let srv = spawn_replay(Arc::new(vec![
            ("GET".into(), "/drive/v1/share?".into(), 200,
                r#"{"share_status_text":"OK","files":[{"id":"f1","name":"movie.mkv","size":123}]}"#.into()),
            ("POST".into(), "/drive/v1/files".into(), 200,
                r#"{"file":{"id":"owned-dir","kind":"drive#folder"}}"#.into()),
            ("POST".into(), "/drive/v1/share/restore".into(), 200,
                r#"{"restore_status":"RESTORE_COMPLETE"}"#.into()),
            ("GET".into(), "/drive/v1/files?parent_id=owned-dir".into(), 200,
                r#"{"files":[{"id":"ours","name":"movie.mkv","size":123,"web_content_link":"http://127.0.0.1:9/ours.mkv"}]}"#.into()),
            ("GET".into(), "/drive/v1/files?".into(), 200, r#"{"files":[]}"#.into()),
            ("GET".into(), "/drive/v1/files?".into(), 200,
                r#"{"files":[{"id":"user-upload","name":"movie.mkv","size":123,"web_content_link":"http://127.0.0.1:9/user.mkv"}]}"#.into()),
        ]));
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let spec = super::super::pan_episode_select::EpisodeSpec { title: "movie".into(), order: Some(1) };
        let out = resolve_selected_with(&ep, Some("access_token=TESTTOK"), "share", "", Some("f1"), &spec)
            .await.expect("独立目录转存");
        assert_eq!(out.url, "http://127.0.0.1:9/ours.mkv", "不能误播并发的用户上传");
        let reqs = srv.requests();
        let create = reqs.iter().find(|r| r.method == "POST" && r.target == "/drive/v1/files")
            .expect("必须新建目录");
        let body: serde_json::Value = serde_json::from_str(&create.body).unwrap();
        assert_eq!(body["kind"], "drive#folder");
        assert_eq!(body["parent_id"], "");
        assert_eq!(body["space"], "");
        assert!(body["name"].as_str().unwrap().starts_with("sourin-play-"));
        let restore = reqs.iter().find(|r| r.target == "/drive/v1/share/restore").unwrap();
        let body: serde_json::Value = serde_json::from_str(&restore.body).unwrap();
        assert_eq!(body["parent_id"], "owned-dir");
        assert!(reqs.iter().filter(|r| r.method == "GET" && r.target.starts_with("/drive/v1/files?"))
            .all(|r| r.target.contains("parent_id=owned-dir")));
    }

    #[tokio::test]
    async fn refused_directory_creation_never_falls_back_to_root() {
        let mut routes = full_routes().as_ref().clone();
        routes[7].2 = 403;
        routes[7].3 = r#"{"error":"captcha_required","token":"DO_NOT_EXPOSE_SENTINEL"}"#.into();
        let srv = spawn_replay(Arc::new(routes));
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let spec = super::super::pan_episode_select::EpisodeSpec { title: "movie".into(), order: Some(1) };
        let err = resolve_selected_with(&ep, Some("access_token=TESTTOK"), "share", "", Some("f1"), &spec)
            .await.expect_err("没有专属目录不得转存");
        assert!(!err.contains("DO_NOT_EXPOSE_SENTINEL"));
        assert!(srv.requests().iter().all(|r| !r.target.contains("/share/restore") && r.method != "DELETE"));
    }

    #[tokio::test]
    async fn restore_errors_never_expose_response_body_or_unknown_status() {
        for (status, body) in [
            (500, r#"{"token":"DO_NOT_EXPOSE_SENTINEL","url":"https://private.invalid/DO_NOT_EXPOSE_SENTINEL"}"#),
            (200, "DO_NOT_EXPOSE_SENTINEL not json"),
            (200, r#"{"restore_status":"DO_NOT_EXPOSE_SENTINEL","token":"DO_NOT_EXPOSE_SENTINEL"}"#),
        ] {
            let mut routes = full_routes().as_ref().clone();
            routes[1].2 = status;
            routes[1].3 = body.into();
            let srv = spawn_replay(Arc::new(routes));
            let ep = XunleiEndpoints { base: srv.base.clone() };
            let spec = super::super::pan_episode_select::EpisodeSpec { title: "movie".into(), order: Some(1) };
            let err = resolve_selected_with(&ep, Some("access_token=TESTTOK"), "share", "", Some("f1"), &spec)
                .await.expect_err("上游错误");
            assert!(!err.contains("DO_NOT_EXPOSE_SENTINEL"), "不能泄露响应原文");
        }
    }

    #[tokio::test]
    async fn stale_parser_result_never_mutates_a_newer_playback_directory() {
        let srv = spawn_replay(full_routes());
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let old = PlaybackOwner { consumer: format!("xl-stale-{}", ep.base), generation: 1 };
        let new = PlaybackOwner { consumer: old.consumer.clone(), generation: 2 };
        pan_playback_guard::register(Some(old.clone())).unwrap();
        pan_playback_guard::register(Some(new.clone())).unwrap();
        pan_playback_guard::with_scope(Some(new), async {
            remember_temp(&ep.base, "TESTTOK", "current-playing-dir");
        }).await;
        let spec = super::super::pan_episode_select::EpisodeSpec { title: "movie".into(), order: Some(1) };
        let err = pan_playback_guard::with_scope(Some(old), async {
            resolve_selected_with(&ep, Some("access_token=TESTTOK"), "share", "", Some("f1"), &spec).await
        }).await.expect_err("旧解析不能覆盖新会话");
        assert!(err.contains("过期"));
        assert!(srv.requests().iter().all(|r| r.method == "GET"), "旧解析不得建目录、转存或清理");
    }

    #[tokio::test]
    async fn cleanup_cannot_delete_later_generation_other_consumer_or_other_account() {
        let srv = spawn_replay(full_routes());
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let owner = PlaybackOwner { consumer: format!("xl-cleanup-{}", ep.base), generation: 7 };
        for (saved_owner, token, fid) in [
            (Some(owner.clone()), "TESTTOK", "mine-old"),
            (Some(PlaybackOwner { generation: 8, ..owner.clone() }), "TESTTOK", "mine-current"),
            (Some(PlaybackOwner { consumer: "other-page".into(), generation: 1 }), "TESTTOK", "other-page-dir"),
            (Some(owner.clone()), "OTHER-ACCOUNT", "other-account-dir"),
            (None, "TESTTOK", "legacy-dir"),
        ] {
            pan_playback_guard::with_scope(saved_owner, async { remember_temp(&ep.base, token, fid); }).await;
        }
        purge_previous(&http_client(), &ep, "TESTTOK", &Some(owner)).await;
        let deletes: Vec<_> = srv.requests().into_iter().filter(|r| r.method == "DELETE").collect();
        assert_eq!(deletes.len(), 1);
        assert!(deletes[0].target.contains("/files/mine-old?"));
    }

    #[tokio::test]
    async fn legacy_share_with_multiple_files_requires_a_concrete_selection() {
        let mut routes = full_routes().as_ref().clone();
        routes[0].3 = r#"{"share_status_text":"OK","files":[
            {"id":"f1","name":"第1集.mkv","size":123},
            {"id":"largest","name":"第2集.mkv","size":9999}]}"#.into();
        let srv = spawn_replay(Arc::new(routes));
        let ep = XunleiEndpoints { base: srv.base.clone() };
        assert!(resolve_with(&ep, Some("access_token=TESTTOK"), "share", "").await.is_err());
        assert!(srv.requests().iter().all(|r| r.method == "GET"));
    }

    #[tokio::test]
    async fn failed_directory_cleanup_keeps_ownership_for_a_later_retry() {
        let srv = spawn_replay(Arc::new(vec![
            ("DELETE".into(), "/drive/v1/files/".into(), 503, "{}".into()),
            ("DELETE".into(), "/drive/v1/files/".into(), 200, "{}".into()),
        ]));
        let ep = XunleiEndpoints { base: srv.base.clone() };
        remember_temp(&ep.base, "TESTTOK", "retry-dir");
        purge_previous(&http_client(), &ep, "TESTTOK", &None).await;
        purge_previous(&http_client(), &ep, "TESTTOK", &None).await;
        assert_eq!(srv.requests().len(), 2, "清理失败不能丢失自己的目录账目");
        purge_previous(&http_client(), &ep, "TESTTOK", &None).await;
        assert_eq!(srv.requests().len(), 2, "成功清理后不得重复删除");
    }

    #[tokio::test]
    async fn unknown_share_status_never_exposes_server_payload() {
        let srv = spawn_replay(Arc::new(vec![
            ("GET".into(), "/drive/v1/share?".into(), 200,
                r#"{"share_status_text":"https://private.invalid/DO_NOT_EXPOSE_SENTINEL"}"#.into()),
        ]));
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let err = resolve_with(&ep, Some("access_token=TESTTOK"), "share", "").await.expect_err("不可用");
        assert!(!err.contains("DO_NOT_EXPOSE_SENTINEL"));
    }
}
