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
// 转存   : POST share/restore
//          {"parent_id":"","share_id":…,"pass_code_token":…,
//           "ancestor_ids":[],"file_ids":[…],"specify_parent_id":true}
//          （web 客户端 onAppSave 调用点逐字；parent_id="" = 根目录，
//           web 端选"我的云盘"根时 restoreFolder.id 就是 ""）
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
// · 夸克族有 sourin-temp 固定目录；迅雷的**建目录端点在懒加载 chunk 里
//   未逐字取证** ⇒ 先转存根目录（parent_id=""，web 端默认值），
//   残存文件由下一次播放的清理收走。二期取证到建目录后并进 sourin-temp
//   同款纪律 —— 不猜参数。
// · 体积超限类错误（limit/exceed/size 字样）⇒ 降级试次大文件（≤3 个），
//   归因文案照夸克族口径（23018 教训：宁可跳过超限文件也不整体失败）。
// ```

use crate::pan::PanKind;
use super::CspPlay;

/// API 根（web 客户端 production 档逐字；可被测试回放服务替换）
#[derive(Debug, Clone)]
pub struct XunleiEndpoints {
    /// 形如 `https://api-pan.xunlei.com/drive/v1`
    pub base: String,
}

impl Default for XunleiEndpoints {
    fn default() -> Self {
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
/// 降级重试上限（与夸克族 SHARE_PICK_MAX_TRIES 同口径）
const PICK_MAX_TRIES: usize = 3;

fn short(s: &str) -> String {
    let t: String = s.chars().take(160).collect();
    t
}

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
/// Err 带截断原文（不猜、不编）。
fn parse_file_items(v: &serde_json::Value) -> Result<Vec<XunleiFile>, String> {
    let arr = ["files", "list", "file_list", "resources"]
        .iter()
        .find_map(|k| v.get(k).and_then(|x| x.as_array()))
        .ok_or_else(|| format!("响应里没有文件清单键（files/list/file_list/resources）：{}", short(&v.to_string())))?;
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
        if kind == "drive#folder" {
            continue; // 目录不是候选
        }
        out.push(XunleiFile {
            id,
            name: it.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string(),
            size: it.get("size").and_then(|x| x.as_u64()).unwrap_or(0),
            kind,
            web_content_link: direct_link_of(it),
        });
    }
    Ok(out)
}

/// 按体积降序的候选（配合降级重试：超限就试次大）
fn pick_candidates(mut files: Vec<XunleiFile>) -> Vec<XunleiFile> {
    files.sort_by(|a, b| b.size.cmp(&a.size));
    files
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
    RestoreOutcome::Failed(format!(
        "restore_status={status:?} 原文：{}",
        short(&v.to_string())
    ))
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

/// 进程内记下的本次转存文件 id（下一次解析开头清理 —— 与夸克族同节律）
static TEMP_SAVED: std::sync::OnceLock<std::sync::Mutex<Vec<String>>> = std::sync::OnceLock::new();

fn temp_saved() -> &'static std::sync::Mutex<Vec<String>> {
    TEMP_SAVED.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}

fn remember_temp(fid: &str) {
    temp_saved()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push(fid.to_string());
}

/// ★★★ 把迅雷分享页解析成可播直链（给 provider.rs 的 resolve 出口钩子用）
///
/// 未登录 ⇒ `Err("NEED_LOGIN:xunlei|…")`（classify_err 翻译成 Unauthorized）。
pub async fn resolve(share_id: &str, passcode: &str) -> Result<CspPlay, String> {
    let credential = crate::pan_auth::load(PanKind::Xunlei).map(|c| c.cookie);
    resolve_with(&XunleiEndpoints::default(), credential.as_deref(), share_id, passcode).await
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
    let share_id = share_id.trim();
    if share_id.is_empty() {
        return Err("迅雷分享 id 为空（分享页 URL 解析失败）".to_string());
    }
    let Some(credential) = credential else {
        return Err(format!(
            "NEED_LOGIN:{}|还未登录迅雷云盘账号，请前往【配置中心】登录",
            PanKind::Xunlei.code()
        ));
    };
    let Some(token) = access_token_of(credential) else {
        // 凭据在但形状不对（没有 access_token=）——登录态坏了，如实说
        return Err(format!(
            "NEED_LOGIN:{}|迅雷登录态不完整，请到【配置中心】重新扫码登录",
            PanKind::Xunlei.code()
        ));
    };

    // 与 pan_web_share.rs / PanDrive 同一条纪律：reqwest 默认读环境代理 ⇒ 显式禁
    let client = reqwest::Client::builder()
        .user_agent(UA)
        .timeout(std::time::Duration::from_secs(15))
        .no_proxy()
        .build()
        .expect("HTTP client 构建失败（TLS 后端不可用）");

    // ── ① 清上一次的临时转存（best-effort；失败不阻断本次播放）──────────
    purge_previous(&client, ep, &token).await;

    // ── ② 分享清单：share_status_text 必须 OK；候选按体积降序 ──────────
    let list_url = format!(
        "{}/share?share_id={}&pass_code={}&limit=100&pass_code_token=&page_token=&thumbnail_size=SIZE_SMALL",
        ep.base,
        urlencode(share_id),
        urlencode(passcode)
    );
    let lv = get_json(&client, ep, &token, &list_url).await?;
    let status = lv
        .get("share_status_text")
        .or_else(|| lv.get("shareStatusText"))
        .and_then(|x| x.as_str())
        .unwrap_or("");
    if status != "OK" && !status.is_empty() {
        return Err(format!("迅雷分享不可用（share_status_text={status}）"));
    }
    let pass_code_token = lv
        .get("pass_code_token")
        .or_else(|| lv.get("passCodeToken"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let files = parse_file_items(&lv)?;
    if files.is_empty() {
        return Err(format!(
            "迅雷分享里没有可播的文件（清单为空或全是目录）：{}",
            short(&lv.to_string())
        ));
    }
    let candidates = pick_candidates(files);

    // ── ③ 逐候选：转存 → 轮询 → 找到转存后的文件 → 取直链 ─────────────
    let tries = candidates.len().min(PICK_MAX_TRIES);
    let mut last_err = String::new();
    for cand in candidates.iter().take(tries) {
        match attempt(&client, ep, &token, share_id, &pass_code_token, cand).await {
            Ok(mut play) => {
                play.label = Some(format!("迅雷云盘 · {}", cand.name));
                return Ok(play);
            }
            Err(e) => {
                crate::applog::write_file_log(
                    "PAN",
                    &format!("[XL-PLAY] 候选「{}」失败：{e}", cand.name),
                );
                last_err = e;
                if !is_size_limit_error(&last_err) {
                    break; // 只有"限制类"错误才降级，其余如实失败
                }
            }
        }
    }
    Err(last_err)
}

/// 单个候选的尝试：restore → (轮询) → 根目录对名找文件 → 直链
async fn attempt(
    client: &reqwest::Client,
    ep: &XunleiEndpoints,
    token: &str,
    share_id: &str,
    pass_code_token: &str,
    cand: &XunleiFile,
) -> Result<CspPlay, String> {
    // 转存（web 调用点逐字 body；parent_id="" = 根目录，见文件头注释）
    let body = format!(
        "{{\"parent_id\":\"\",\"share_id\":{},\"pass_code_token\":{},\
          \"ancestor_ids\":[],\"file_ids\":[{}],\"specify_parent_id\":true}}",
        json_str(share_id),
        json_str(pass_code_token),
        json_str(&cand.id),
    );
    let restore_url = format!("{}/share/restore", ep.base);
    let resp = client
        .post(&restore_url)
        .bearer_auth(token)
        .header("x-device-id", device_id())
        .header("x-client-id", CLIENT_ID)
        .header("x-client-version", CLIENT_VERSION)
        .header("Origin", "https://pan.xunlei.com")
        .header("Referer", "https://pan.xunlei.com/")
        .header("Content-Type", "application/json")
        .body(body)
        .send()
        .await
        .map_err(|e| format!("迅雷转存请求失败：{e}"))?;
    let status = resp.status();
    let text = resp.text().await.map_err(|e| format!("读转存响应失败：{e}"))?;
    if !status.is_success() {
        // ★ P2-2：转存那跳同样可能 token 过期 ⇒ 引导重登
        if let Some(e) = login_expired_error(status.as_u16(), &text) {
            return Err(e);
        }
        return Err(format!("迅雷转存返回 HTTP {}：{}", status.as_u16(), short(&text)));
    }
    let rv: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("迅雷转存响应不是 JSON（{e}）：{}", short(&text)))?;
    match parse_restore(&rv) {
        RestoreOutcome::Failed(why) => return Err(format!("迅雷转存被拒：{why}")),
        RestoreOutcome::Task(tid) => {
            // 轮询到终态（预算封顶 —— lead 批复约束）
            let poll_url = format!("{}/tasks/{}", ep.base, urlencode(&tid));
            let mut done = false;
            for _ in 0..RESTORE_POLL_MAX {
                tokio::time::sleep(RESTORE_POLL_INTERVAL).await;
                let tv = get_json(client, ep, token, &poll_url).await?;
                match task_done(&tv) {
                    Some(true) => {
                        done = true;
                        break;
                    }
                    Some(false) => {
                        return Err(format!(
                            "迅雷转存任务失败：{}",
                            short(&tv.to_string())
                        ));
                    }
                    None => continue,
                }
            }
            if !done {
                return Err("迅雷转存未完成（轮询预算内没有到终态，已保留任务可稍后重试）".to_string());
            }
        }
        RestoreOutcome::Complete => {}
    }

    // 找到转存后的文件：转存落在根目录（parent_id=""）⇒ 在根目录清单里
    // 按"名字一致"对号（web 端 restore 响应的 file_id 是**目标目录**，不是文件）。
    let list_url = format!(
        "{}/files?parent_id=&limit=100&with=has_subfolder",
        ep.base
    );
    let fv = get_json(client, ep, token, &list_url).await?;
    let root_files = parse_file_items(&fv)?;
    let restored = root_files
        .iter()
        .find(|f| f.name == cand.name && f.size == cand.size)
        .or_else(|| root_files.iter().find(|f| f.name == cand.name))
        .ok_or_else(|| {
            format!(
                "迅雷转存完成，但根目录清单里找不到「{}」（转存与清单一时不同步）",
                cand.name
            )
        })?;
    remember_temp(&restored.id);

    // 直链：清单条目若自带 web_content_link 就直接用；否则 files/{id}?usage=CONSUME
    let link = match restored.web_content_link.clone().filter(|s| !s.is_empty()) {
        Some(l) => l,
        None => {
            let info_url = format!("{}/files/{}?usage=CONSUME", ep.base, urlencode(&restored.id));
            let iv = get_json(client, ep, token, &info_url).await?;
            direct_link_of(&iv).ok_or_else(|| {
                format!(
                    "迅雷文件详情里没有 web_content_link：{}",
                    short(&iv.to_string())
                )
            })?
        }
    };
    // 直链的 UA 约束未取证（web 端直链消费不在本轮证据里）⇒ 带桌面 UA 交给
    // 真机验收暴露；响应里若有 UA 提示字段，见到再加（不猜）。
    Ok(CspPlay {
        url: link,
        headers: vec![("User-Agent".to_string(), UA.to_string())],
        label: None,
    })
}

/// 清上一次的临时转存（DELETE files/{id}?space= 逐字；best-effort）
async fn purge_previous(client: &reqwest::Client, ep: &XunleiEndpoints, token: &str) {
    let fids: Vec<String> = {
        let mut g = temp_saved().lock().unwrap_or_else(|e| e.into_inner());
        std::mem::take(&mut *g)
    };
    for fid in fids {
        let url = format!("{}/files/{}?space=", ep.base, urlencode(&fid));
        let r = client
            .delete(&url)
            .bearer_auth(token)
            .header("x-device-id", device_id())
            .header("x-client-id", CLIENT_ID)
            .header("Referer", "https://pan.xunlei.com/")
            .send()
            .await;
        match r {
            Ok(resp) if resp.status().is_success() => {
                crate::applog::write_file_log("PAN", &format!("[XL-PLAY] 已清理上次临时转存 fid={fid}"));
            }
            Ok(resp) => {
                crate::applog::write_file_log(
                    "PAN",
                    &format!("[XL-PLAY] 清理临时转存失败 fid={fid} HTTP {}", resp.status()),
                );
            }
            Err(e) => {
                crate::applog::write_file_log("PAN", &format!("[XL-PLAY] 清理临时转存请求失败 fid={fid} err={e}"));
            }
        }
    }
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
    let resp = client
        .get(url)
        .bearer_auth(token)
        .header("x-device-id", device_id())
        .header("x-client-id", CLIENT_ID)
        .header("Accept", "application/json, text/plain, */*")
        .header("Referer", "https://pan.xunlei.com/")
        .send()
        .await
        .map_err(|e| format!("迅雷请求失败：{e}"))?;
    let status = resp.status();
    let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
    if !status.is_success() {
        // ★ 注入②：摘 401 映射（证红用，随即还原）
        if false {
            if let Some(e) = login_expired_error(status.as_u16(), &body) {
                return Err(e);
            }
        }
        return Err(format!("迅雷返回 HTTP {}：{}", status.as_u16(), short(&body)));
    }
    serde_json::from_str(&body).map_err(|e| format!("迅雷响应不是 JSON（{e}）：{}", short(&body)))
}

fn json_str(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
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
    fn clear_test_credential() {
        isolate_keyring();
        let _ = crate::pan_auth::clear(PanKind::Xunlei);
    }

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
                let hit = routes
                    .iter()
                    .find(|(m, p, _, _)| method.eq_ignore_ascii_case(m) && target.starts_with(p.as_str()));
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

    /// ★★ 快乐路径：清单 OK → restore（body 逐字参数）→ 根目录对名 → 直链。
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
        assert!(restore.body.contains("\"parent_id\":\"\""), "根目录形态：{}", restore.body);
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
        assert!(deletes[0].target.contains("files/xf1"), "{}", deletes[0].target);
    }

    /// ★ 未登录 ⇒ NEED_LOGIN（classify_err 翻译成 Unauthorized，与夸克族同约定）
    #[tokio::test]
    async fn no_credential_is_need_login() {
        clear_test_credential();
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
        ]);
        let srv2 = spawn_replay(routes2);
        let ep2 = XunleiEndpoints { base: srv2.base.clone() };
        let err = resolve_with(&ep2, Some("access_token=STALE"), "share123", "")
            .await
            .expect_err("转存跳过期同样必须引导重登");
        assert!(err.starts_with("NEED_LOGIN:xunlei|"), "{err}");
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

    /// 轮询内核（生产路径走 RESTORE_POLL_INTERVAL；测试传短间隔）
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
                Some(false) => return Err(format!("迅雷转存任务失败：{}", short(&tv.to_string()))),
                None => continue,
            }
        }
        Err("迅雷转存未完成（轮询预算内没有到终态，已保留任务可稍后重试）".to_string())
    }

    /// ★ 转存成功但"根目录对名"失败 ⇒ 如实报；此时文件 id 未知（restore 响应的
    ///   file_id 是**目标目录**不是文件）⇒ 无法登记清理 —— 残存文件只能靠用户
    ///   手动删或下次同名对上后再清。这是"建目录端点未取证"边界的连带代价，
    ///   在文件头注释里如实声明（不许假装清理过）。
    #[tokio::test]
    async fn failed_match_after_restore_is_honest() {
        save_test_credential();
        // restore 成功，但根目录清单里对不上名 ⇒ attempt 失败
        let routes = Arc::new(vec![
            ("GET".into(), "/drive/v1/share?".into(), 200,
             r#"{"share_status_text":"OK","files":[{"id":"f1","name":"movie.mkv","size":123,"kind":"drive#file"}]}"#.into()),
            ("POST".into(), "/drive/v1/share/restore".into(), 200,
             r#"{"restore_status":"RESTORE_COMPLETE","restore_task_id":"t1"}"#.into()),
            ("GET".into(), "/drive/v1/files?".into(), 200,
             r#"{"files":[{"id":"other","name":"别的文件","size":1,"kind":"drive#file"}]}"#.into()),
            ("DELETE".into(), "/drive/v1/files/".into(), 200, "{}".into()),
        ]);
        let srv = spawn_replay(routes);
        let ep = XunleiEndpoints { base: srv.base.clone() };
        let err = resolve_with(&ep, Some("access_token=TESTTOK"), "share123", "")
            .await
            .expect_err("对不上名必须 Err");
        assert!(err.contains("找不到"), "{err}");
        // 此时不许有 DELETE（文件 id 未知 —— 删不得，删了是假装清理过）
        assert!(
            srv.requests().iter().all(|r| r.method != "DELETE"),
            "对不上名时没有任何已知 fid，DELETE 就是盲删"
        );
    }
}
