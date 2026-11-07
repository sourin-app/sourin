//! Baidu share inspection, actual file episodes and selected-file downloads.
//! Official request evidence includes the archived share scripts and the public
//! home.6c242846.js download/user-info helpers. No page or limited preview is
//! returned as media; live account and decoded content require separate evidence.

use super::CspPlay;
use crate::pan::PanKind;
use reqwest::{header, Method, Request, Url};
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub struct BaiduEndpoints {
    pub page: String,
    pub verify: String,
    pub list: String,
}

impl Default for BaiduEndpoints {
    fn default() -> Self {
        Self {
            page: "https://pan.baidu.com/s".to_string(),
            verify: "https://pan.baidu.com/share/verify".to_string(),
            list: "https://pan.baidu.com/share/list".to_string(),
        }
    }
}

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";
const WEB_QUERY: [(&str, &str); 3] = [("clienttype", "0"), ("app_id", "250528"), ("web", "1")];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BaiduInspection {
    Files,
    Empty,
    NeedsPasscode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BaiduStage {
    Verify,
    List,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BaiduFailureCause {
    Protocol,
    Expired,
    Http(u16),
    Business(BaiduStage, i64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BaiduJsonShape {
    NotApplicable,
    Missing,
    Null,
    Boolean,
    UnsignedInteger,
    SignedInteger,
    FloatingNumber,
    String,
    Array,
    Object,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BaiduListShapeStage {
    InitialList,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct BaiduFieldShape {
    pub kind: BaiduJsonShape,
    pub rejected: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct BaiduInitialEntryShape {
    pub stage: BaiduListShapeStage,
    pub entry_kind: BaiduJsonShape,
    pub fs_id: BaiduFieldShape,
    pub server_filename: BaiduFieldShape,
    pub isdir: BaiduFieldShape,
}

tokio::task_local! {
    static INITIAL_LIST_SHAPE: std::cell::Cell<Option<BaiduInitialEntryShape>>;
}

/// Observe only the first rejected initial-list entry; no response values are retained.
pub async fn with_initial_list_rejection_shape<T>(
    future: impl std::future::Future<Output = T>,
) -> (T, Option<BaiduInitialEntryShape>) {
    INITIAL_LIST_SHAPE
        .scope(std::cell::Cell::new(None), async {
            let result = future.await;
            let shape = INITIAL_LIST_SHAPE.with(std::cell::Cell::get);
            (result, shape)
        })
        .await
}

fn json_shape(value: Option<&serde_json::Value>) -> BaiduJsonShape {
    use BaiduJsonShape::*;
    match value {
        None => Missing,
        Some(serde_json::Value::Null) => Null,
        Some(serde_json::Value::Bool(_)) => Boolean,
        Some(serde_json::Value::Number(number)) if number.as_u64().is_some() => UnsignedInteger,
        Some(serde_json::Value::Number(number)) if number.as_i64().is_some() => SignedInteger,
        Some(serde_json::Value::Number(_)) => FloatingNumber,
        Some(serde_json::Value::String(_)) => String,
        Some(serde_json::Value::Array(_)) => Array,
        Some(serde_json::Value::Object(_)) => Object,
    }
}

fn initial_entry_shape(value: &serde_json::Value) -> BaiduInitialEntryShape {
    let not_applicable = BaiduFieldShape {
        kind: BaiduJsonShape::NotApplicable,
        rejected: None,
    };
    let mut shape = BaiduInitialEntryShape {
        stage: BaiduListShapeStage::InitialList,
        entry_kind: json_shape(Some(value)),
        fs_id: not_applicable,
        server_filename: not_applicable,
        isdir: not_applicable,
    };
    if let Some(entry) = value.as_object() {
        let id = entry
            .get("fs_id")
            .and_then(|id| id.as_u64().or_else(|| id.as_str()?.parse::<u64>().ok()));
        shape.fs_id = BaiduFieldShape {
            kind: json_shape(entry.get("fs_id")),
            rejected: Some(!id.is_some_and(|id| id > 0)),
        };
        shape.server_filename = BaiduFieldShape {
            kind: json_shape(entry.get("server_filename")),
            rejected: Some(!entry
                .get("server_filename")
                .and_then(serde_json::Value::as_str)
                .is_some_and(|name| !name.trim().is_empty())),
        };
        shape.isdir = BaiduFieldShape {
            kind: json_shape(entry.get("isdir")),
            rejected: Some(!entry
                .get("isdir")
                .is_none_or(|flag| directory_flag(flag).is_some())),
        };
    }
    shape
}

fn observe_initial_rejection_if_scoped(value: &serde_json::Value) {
    let _ = INITIAL_LIST_SHAPE.try_with(|slot| {
        if slot.get().is_none() {
            slot.set(Some(initial_entry_shape(value)));
        }
    });
}

pub(crate) struct BaiduInspectionFailure {
    pub(crate) message: String,
    pub(crate) cause: BaiduFailureCause,
    // Selected failure-envelope fields only; never reflected in user text or Debug.
    pub(crate) error_messages: Vec<String>,
}

impl std::fmt::Debug for BaiduInspectionFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BaiduInspectionFailure")
            .field("cause", &self.cause)
            .field("message", &self.message)
            .finish()
    }
}

impl From<String> for BaiduInspectionFailure {
    fn from(message: String) -> Self {
        let cause = if message == "播放解析请求已过期" {
            BaiduFailureCause::Expired
        } else {
            BaiduFailureCause::Protocol
        };
        Self {
            message,
            cause,
            error_messages: Vec::new(),
        }
    }
}

impl From<&str> for BaiduInspectionFailure {
    fn from(message: &str) -> Self {
        message.to_string().into()
    }
}

impl BaiduInspectionFailure {
    fn business(stage: BaiduStage, errno: i64, value: &serde_json::Value) -> Self {
        let message = match stage {
            BaiduStage::Verify => format!("百度分享校验未通过（verify errno={errno}）"),
            BaiduStage::List => format!("百度分享列表失败（share/list errno={errno}）"),
        };
        let mut error_messages = Vec::new();
        for key in ["message", "msg", "errmsg", "error_description", "error"] {
            if let Some(message) = value.get(key).and_then(serde_json::Value::as_str) {
                error_messages.push(message.into());
            }
        }
        if let Some(error) = value.get("error").and_then(serde_json::Value::as_object) {
            for key in ["message", "name", "code"] {
                if let Some(message) = error.get(key).and_then(serde_json::Value::as_str) {
                    error_messages.push(message.into());
                }
            }
        }
        Self {
            message,
            cause: BaiduFailureCause::Business(stage, errno),
            error_messages,
        }
    }
}

pub async fn resolve(share_id: &str, passcode: &str) -> Result<CspPlay, String> {
    super::pan_playback_guard::check_current()?;
    let cookie = crate::pan_auth::load(PanKind::Baidu).map(|c| c.cookie);
    super::pan_playback_guard::check_current()?;
    resolve_with(
        &BaiduEndpoints::default(),
        cookie.as_deref(),
        share_id,
        passcode,
    )
    .await
}

pub async fn resolve_with(
    ep: &BaiduEndpoints,
    cookie: Option<&str>,
    share_id: &str,
    passcode: &str,
) -> Result<CspPlay, String> {
    resolve_selected_with(
        ep,
        cookie,
        share_id,
        passcode,
        None,
        &super::pan_episode_select::EpisodeSpec::default(),
    )
    .await
}

pub async fn resolve_selected(
    share_id: &str,
    passcode: &str,
    fid: Option<&str>,
    spec: &super::pan_episode_select::EpisodeSpec,
) -> Result<CspPlay, String> {
    super::pan_playback_guard::check_current()?;
    let cookie = crate::pan_auth::load(PanKind::Baidu).map(|c| c.cookie);
    super::pan_playback_guard::check_current()?;
    resolve_selected_with(
        &BaiduEndpoints::default(),
        cookie.as_deref(),
        share_id,
        passcode,
        fid,
        spec,
    )
    .await
}

pub async fn resolve_selected_with(
    ep: &BaiduEndpoints,
    cookie: Option<&str>,
    share_id: &str,
    passcode: &str,
    fid: Option<&str>,
    spec: &super::pan_episode_select::EpisodeSpec,
) -> Result<CspPlay, String> {
    super::pan_playback_guard::check_current()?;
    let share_id = share_id.trim();
    if share_id.is_empty() {
        return Err("百度分享 id 为空（分享页 URL 解析失败）".into());
    }
    let Some(cookie) = cookie.filter(|value| !value.trim().is_empty()) else {
        return Err(format!(
            "NEED_LOGIN:{}|还未登录百度网盘账号，请前往【配置中心】登录",
            PanKind::Baidu.code()
        ));
    };
    let context = inspect_context(ep, cookie, share_id, passcode)
        .await
        .map_err(|failure| failure.message)?;
    match context.inspection {
        BaiduInspection::Empty => Err("百度分享里没有列出文件（list 为空）".into()),
        BaiduInspection::NeedsPasscode => Err("百度分享需要提取码（share/list HasPwd）".into()),
        BaiduInspection::Files => download_selected(context, fid, spec).await,
    }
}

/// Shares the production protocol without loading any stored account credential.
pub(crate) async fn inspect_anonymous(
    ep: &BaiduEndpoints,
    share_id: &str,
    passcode: &str,
) -> Result<BaiduInspection, BaiduInspectionFailure> {
    inspect_with(ep, "", share_id, passcode).await
}

async fn inspect_with(
    ep: &BaiduEndpoints,
    cookie: &str,
    share_id: &str,
    passcode: &str,
) -> Result<BaiduInspection, BaiduInspectionFailure> {
    Ok(inspect_context(ep, cookie, share_id, passcode)
        .await?
        .inspection)
}

struct InspectionContext {
    inspection: BaiduInspection,
    items: Vec<serde_json::Value>,
    page: String,
    page_url: Url,
    share_id: String,
    cookies: Cookies,
    client: reqwest::Client,
    deadline: tokio::time::Instant,
    list_url: Url,
    list_query: Vec<(&'static str, String)>,
}

async fn inspect_context(
    ep: &BaiduEndpoints,
    cookie: &str,
    share_id: &str,
    passcode: &str,
) -> Result<InspectionContext, BaiduInspectionFailure> {
    super::pan_playback_guard::check_current()?;
    let share_id = share_id.trim();
    if share_id.is_empty() {
        return Err("百度分享 id 为空（分享页 URL 解析失败）".into());
    }
    let mut page_url = endpoint(&ep.page)?;
    let verify_url = endpoint(&ep.verify)?;
    let list_url = endpoint(&ep.list)?;
    if verify_url.origin() != page_url.origin() || list_url.origin() != page_url.origin() {
        return Err("百度端点不同源（未发起请求）".into());
    }
    page_url
        .path_segments_mut()
        .map_err(|_| "百度分享页端点格式无效".to_string())?
        .pop_if_empty()
        .push(share_id);
    let mut cookies = Cookies::new(cookie, &page_url)?;
    let client = reqwest::Client::builder()
        .user_agent(UA)
        .timeout(std::time::Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .build()
        .map_err(|_| "百度 HTTP 客户端初始化失败".to_string())?;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(45);
    let request = client
        .get(page_url.clone())
        .header("Referer", &ep.page)
        .build()
        .map_err(|_| "百度分享页请求构建失败".to_string())?;
    let (page, final_url) = send(
        &client,
        &mut cookies,
        request,
        &page_url,
        deadline,
        "分享页",
    )
    .await?;
    let has_share = (page_scalar(&page, "shareid").is_some()
        && page_scalar(&page, "share_uk").is_some())
        || page.contains("verify-form")
        || (page.contains("locals.mset") && page.contains("file_list"));
    if final_url.path() == "/login"
        || (!has_share && (page.contains("登录百度网盘") || page.contains("passLoginType")))
    {
        return Err("百度当前请求未获分享信息（返回登录入口；不证明已保存账号过期）".into());
    }

    let mut bdclnd = String::new();
    if !passcode.trim().is_empty() {
        let surl = share_id
            .strip_prefix('1')
            .or_else(|| share_id.strip_prefix('5'))
            .unwrap_or(share_id);
        let mut query = ajax_query(&page, &cookies, &page_url);
        query.extend([
            ("t", now_ms().to_string()),
            ("bioc", "1".into()),
            ("surl", surl.into()),
        ]);
        let request = client
            .post(verify_url)
            .query(&query)
            .header("X-Requested-With", "XMLHttpRequest")
            .header("Referer", page_url.as_str())
            .form(&[("pwd", passcode.trim()), ("vcode", ""), ("vcode_str", "")])
            .build()
            .map_err(|_| "百度 verify 请求构建失败".to_string())?;
        let (body, _) = send(
            &client,
            &mut cookies,
            request,
            &page_url,
            deadline,
            "verify",
        )
        .await?;
        let value = response_json(&body, "verify")?;
        let errno = integer_errno(&value, "verify")?;
        if errno != 0 {
            return Err(BaiduInspectionFailure::business(
                BaiduStage::Verify,
                errno,
                &value,
            ));
        }
        bdclnd = value
            .get("randsk")
            .and_then(|value| value.as_str())
            .filter(|value| !value.trim().is_empty() && valid_cookie_pair("BDCLND", value))
            .ok_or_else(|| "百度 verify 未提供有效 randsk（停止分享列表请求）".to_string())?
            .to_string();
        cookies.insert("BDCLND", &bdclnd, &page_url, "/", false);
    }

    let mut query = ajax_query(&page, &cookies, &page_url);
    query.extend([
        ("page", "1".into()),
        ("num", "20".into()),
        ("order", "time".into()),
        ("desc", "1".into()),
        ("showempty", "0".into()),
        (
            "shorturl",
            share_id
                .strip_prefix('1')
                .or_else(|| share_id.strip_prefix('5'))
                .unwrap_or(share_id)
                .into(),
        ),
        ("root", "1".into()),
    ]);
    if !bdclnd.is_empty() {
        // Official getVideoList uses decodeURIComponent for sekey, not form decoding.
        if !valid_percent_encoding(&bdclnd) {
            return Err("百度 randsk 百分号编码无效（停止分享列表请求）".into());
        }
        let sekey = urlencoding::decode(&bdclnd)
            .map_err(|_| "百度 randsk 百分号编码无效（停止分享列表请求）".to_string())?;
        query.extend([
            ("is_from_web", "true".into()),
            ("sekey", sekey.into_owned()),
        ]);
    }
    let request = client
        .get(list_url.clone())
        .query(&query)
        .header("X-Requested-With", "XMLHttpRequest")
        .header("Referer", page_url.as_str())
        .build()
        .map_err(|_| "百度 share/list 请求构建失败".to_string())?;
    let (body, _) = send(
        &client,
        &mut cookies,
        request,
        &page_url,
        deadline,
        "share/list",
    )
    .await?;
    let value = response_json(&body, "share/list")?;
    let errno = integer_errno(&value, "share/list")?;
    if errno != 0 {
        return Err(BaiduInspectionFailure::business(
            BaiduStage::List,
            errno,
            &value,
        ));
    }
    let needs_passcode = value.get("HasPwd").and_then(serde_json::Value::as_bool) == Some(true);
    if needs_passcode && value.get("list").is_none() && passcode.trim().is_empty() {
        return Ok(InspectionContext {
            inspection: BaiduInspection::NeedsPasscode,
            items: vec![],
            page,
            page_url,
            share_id: share_id.into(),
            cookies,
            client,
            deadline,
            list_url,
            list_query: query,
        });
    }
    let items = value
        .get("list")
        .and_then(|value| value.as_array())
        .ok_or_else(|| "百度 share/list 未提供文件列表".to_string())?;
    if items.is_empty() {
        let inspection = if needs_passcode {
            BaiduInspection::NeedsPasscode
        } else {
            BaiduInspection::Empty
        };
        return Ok(InspectionContext {
            inspection,
            items: vec![],
            page,
            page_url,
            share_id: share_id.into(),
            cookies,
            client,
            deadline,
            list_url,
            list_query: query,
        });
    }
    if let Some(rejected) = items.iter().find(|item| !valid_file_entry(item)) {
        observe_initial_rejection_if_scoped(rejected);
        return Err("百度 share/list 文件条目结构无效".into());
    }
    Ok(InspectionContext {
        inspection: BaiduInspection::Files,
        items: items.clone(),
        page,
        page_url,
        share_id: share_id.into(),
        cookies,
        client,
        deadline,
        list_url,
        list_query: query,
    })
}

pub async fn list_share_files(
    share_id: &str,
    passcode: &str,
) -> Result<Vec<super::pan_drive::DriveEntry>, String> {
    list_share_files_with(&BaiduEndpoints::default(), share_id, passcode).await
}

pub async fn list_share_files_with(
    ep: &BaiduEndpoints,
    share_id: &str,
    passcode: &str,
) -> Result<Vec<super::pan_drive::DriveEntry>, String> {
    let mut ctx = inspect_context(ep, "", share_id, passcode)
        .await
        .map_err(|v| v.message)?;
    match ctx.inspection {
        BaiduInspection::NeedsPasscode => Err("百度分享需要提取码（share/list HasPwd）".into()),
        BaiduInspection::Empty => Ok(vec![]),
        BaiduInspection::Files => collect_share_files(&mut ctx).await,
    }
}

async fn collect_share_files(
    ctx: &mut InspectionContext,
) -> Result<Vec<super::pan_drive::DriveEntry>, String> {
    let uk = page_scalar(&ctx.page, "share_uk")
        .filter(|v| unsigned_text(v).is_some_and(|v| v > 0))
        .ok_or("百度分享 uk 元数据缺失")?;
    let shareid = page_scalar(&ctx.page, "shareid")
        .filter(|v| unsigned_text(v).is_some_and(|v| v > 0))
        .ok_or("百度分享 id 元数据缺失")?;
    let mut queue = std::collections::VecDeque::from([(None::<String>, ctx.items.clone(), 1u32)]);
    let mut seen_dirs = std::collections::HashSet::new();
    let mut seen_files = std::collections::HashSet::new();
    ctx.items.clear();
    let mut requests = 0usize;
    while let Some((dir, mut items, mut page_number)) = queue.pop_front() {
        loop {
            super::pan_playback_guard::check_current()?;
            let full = items.len() == 20;
            if items.len() > 20 {
                return Err("百度列表超过请求分页大小".into());
            }
            for item in items {
                if !valid_file_entry(&item) {
                    return Err("百度列表文件结构无效".into());
                }
                match item.get("isdir").and_then(directory_flag) {
                    Some(1) => {
                        let path = item
                            .get("path")
                            .and_then(|v| v.as_str())
                            .filter(|v| {
                                v.starts_with('/')
                                    && !v.chars().any(char::is_control)
                                    && !v.split('/').any(|s| matches!(s, "." | ".."))
                            })
                            .ok_or("百度目录路径缺失或无效")?;
                        if !seen_dirs.insert(path.to_string()) {
                            return Err("百度目录循环或重复路径".into());
                        }
                        queue.push_back((Some(path.into()), vec![], 0));
                    }
                    Some(0) => {
                        let id = item
                            .get("fs_id")
                            .and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse().ok()))
                            .ok_or("百度文件标识无效")?;
                        if !seen_files.insert(id) {
                            return Err("百度列表重复文件标识".into());
                        }
                        ctx.items.push(item);
                    }
                    _ => return Err("百度文件目录标记缺失或无效".into()),
                }
            }
            if seen_dirs.len() > 64 || ctx.items.len() > 2560 {
                return Err("百度分享目录或分页遍历超过限制".into());
            }
            if page_number > 0 && !full {
                break;
            }
            requests += 1;
            if requests > 128 || seen_dirs.len() > 64 || ctx.items.len() > 2560 {
                return Err("百度分享目录或分页遍历超过限制".into());
            }
            page_number += 1;
            let mut query = ctx.list_query.clone();
            query.retain(|(key, _)| !matches!(*key, "page" | "root" | "order" | "desc"));
            query.push(("page", page_number.to_string()));
            if let Some(dir) = &dir {
                query.retain(|(key, _)| *key != "shorturl");
                query.extend([
                    ("uk", uk.clone()),
                    ("shareid", shareid.clone()),
                    ("order", "name".into()),
                    ("desc", "0".into()),
                    ("view_mode", "1".into()),
                    ("dir", dir.clone()),
                ]);
            } else {
                query.extend([
                    ("root", "1".into()),
                    ("order", "time".into()),
                    ("desc", "1".into()),
                ]);
            }
            let req = ctx
                .client
                .get(ctx.list_url.clone())
                .query(&query)
                .header("Referer", ctx.page_url.as_str())
                .header("X-Requested-With", "XMLHttpRequest")
                .build()
                .map_err(|_| "百度目录列表请求构建失败")?;
            let (body, _) = send(
                &ctx.client,
                &mut ctx.cookies,
                req,
                &ctx.page_url,
                ctx.deadline,
                "share/list",
            )
            .await
            .map_err(|v| v.message)?;
            let value = response_json(&body, "share/list")?;
            let errno = integer_errno(&value, "share/list")?;
            if errno != 0 {
                return Err(format!("百度分享列表失败（errno={errno}）"));
            }
            items = value
                .get("list")
                .and_then(|v| v.as_array())
                .ok_or("百度目录列表缺失")?
                .clone();
        }
    }
    let mut files = Vec::new();
    for item in &ctx.items {
        let id = item
            .get("fs_id")
            .and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse().ok()))
            .filter(|id| *id > 0)
            .ok_or("百度文件标识无效")?;
        let name = item
            .get("server_filename")
            .and_then(|v| v.as_str())
            .filter(|v| !v.trim().is_empty() && !v.chars().any(char::is_control))
            .ok_or("百度文件名无效")?;
        if item.get("isdir").and_then(directory_flag) != Some(0) {
            return Err("百度文件目录标记缺失或无效".into());
        }
        let size = item
            .get("size")
            .and_then(|v| v.as_u64())
            .ok_or("百度文件大小缺失或无效")?;
        files.push(super::pan_drive::DriveEntry {
            fid: id.to_string(),
            name: name.into(),
            size,
            is_dir: false,
            fid_token: None,
        });
    }
    super::pan_playback_guard::check_current()?;
    if tokio::time::Instant::now() >= ctx.deadline {
        return Err("百度请求总预算耗尽".into());
    }
    Ok(files
        .into_iter()
        .filter(|file| file.size > 0 && super::pan_drive::is_video_name(&file.name))
        .collect())
}

async fn download_selected(
    mut ctx: InspectionContext,
    fid: Option<&str>,
    spec: &super::pan_episode_select::EpisodeSpec,
) -> Result<CspPlay, String> {
    let files = collect_share_files(&mut ctx).await?;
    let selected = super::pan_episode_select::pick_episode_file(spec, &files, fid)?;
    let uk = page_scalar(&ctx.page, "share_uk").ok_or("百度分享 uk 元数据缺失")?;
    let shareid = page_scalar(&ctx.page, "shareid").ok_or("百度分享 id 元数据缺失")?;
    // Account metadata must belong to the viewer, not the share owner.
    let mut login = ctx.page_url.clone();
    login.set_path("/api/loginStatus");
    login.set_query(None);
    let req = ctx
        .client
        .get(login)
        .query(&WEB_QUERY)
        .header("Referer", ctx.page_url.as_str())
        .header("X-Requested-With", "XMLHttpRequest")
        .build()
        .map_err(|_| "百度账户信息请求构建失败")?;
    let (body, _) = send(
        &ctx.client,
        &mut ctx.cookies,
        req,
        &ctx.page_url,
        ctx.deadline,
        "loginStatus",
    )
    .await
    .map_err(|v| v.message)?;
    let viewer = response_json(&body, "loginStatus")?;
    let errno = integer_errno(&viewer, "loginStatus")?;
    if errno != 0 {
        return Err(format!("百度当前请求未获得账户信息（errno={errno}）"));
    }
    let viewer = viewer.get("login_info").ok_or("百度 viewer 信息缺失")?;
    if !viewer
        .get("uk")
        .and_then(unsigned_value)
        .is_some_and(|v| v > 0)
    {
        return Err("百度 viewer uk 缺失或无效".into());
    }
    let token = viewer
        .get("bdstoken")
        .and_then(|v| v.as_str())
        .filter(|v| !v.is_empty() && !v.chars().any(char::is_control))
        .ok_or("百度 viewer bdstoken 缺失或无效")?
        .to_string();
    let vip = viewer
        .get("vip_identity")
        .and_then(unsigned_value)
        .map(|v| (v / 10).to_string())
        .ok_or("百度 viewer vip_identity 缺失或无效")?;
    let mut tpl = ctx.page_url.clone();
    tpl.set_path("/share/tplconfig");
    tpl.set_query(None);
    let surl = if ctx.share_id.starts_with('5') {
        format!("1{}", &ctx.share_id[1..])
    } else {
        ctx.share_id.clone()
    };
    let req = ctx
        .client
        .get(tpl)
        .query(&WEB_QUERY)
        .query(&[
            ("surl", surl.as_str()),
            ("fields", "sign,timestamp"),
            ("bdstoken", token.as_str()),
        ])
        .header("Referer", ctx.page_url.as_str())
        .header("X-Requested-With", "XMLHttpRequest")
        .build()
        .map_err(|_| "百度签名请求构建失败")?;
    let (body, _) = send(
        &ctx.client,
        &mut ctx.cookies,
        req,
        &ctx.page_url,
        ctx.deadline,
        "tplconfig",
    )
    .await
    .map_err(|v| v.message)?;
    let value = response_json(&body, "tplconfig")?;
    let errno = integer_errno(&value, "tplconfig")?;
    if errno != 0 {
        return Err(format!("百度签名请求失败（errno={errno}）"));
    }
    let data = value.get("data").ok_or("百度签名元数据缺失")?;
    let sign = data
        .get("sign")
        .and_then(|v| v.as_str())
        .filter(|v| !v.is_empty() && !v.chars().any(char::is_control))
        .ok_or("百度签名缺失或无效")?;
    let timestamp = data
        .get("timestamp")
        .and_then(unsigned_value)
        .filter(|v| *v > 0)
        .ok_or("百度签名时间缺失或无效")?
        .to_string();
    let fsid = selected
        .fid
        .parse::<u64>()
        .map_err(|_| "百度文件标识无效")?;
    let fid_list = serde_json::to_string(&[fsid]).map_err(|_| "百度文件标识序列化失败")?;
    let mut api = ctx.page_url.clone();
    api.set_path("/api/sharedownload");
    api.set_query(None);
    let req = ctx
        .client
        .post(api)
        .query(&WEB_QUERY)
        .query(&[
            ("sign", sign),
            ("timestamp", timestamp.as_str()),
            ("bdstoken", token.as_str()),
            ("channel", "chunlei"),
        ])
        .header("Referer", ctx.page_url.as_str())
        .header("X-Requested-With", "XMLHttpRequest")
        .form(&[
            ("encrypt", "0"),
            ("product", "share"),
            ("vip", vip.as_str()),
            ("fid_list", fid_list.as_str()),
            ("uk", uk.as_str()),
            ("primaryid", shareid.as_str()),
        ])
        .build()
        .map_err(|_| "百度取直链请求构建失败")?;
    let (body, _) = send(
        &ctx.client,
        &mut ctx.cookies,
        req,
        &ctx.page_url,
        ctx.deadline,
        "sharedownload",
    )
    .await
    .map_err(|v| v.message)?;
    let value = response_json(&body, "sharedownload")?;
    let errno = integer_errno(&value, "sharedownload")?;
    if errno != 0 {
        return Err(format!("百度完整文件下载未获允许（errno={errno}）"));
    }
    let entries = value
        .get("list")
        .and_then(|v| v.as_array())
        .ok_or("百度下载响应缺少文件列表")?;
    if entries.len() != 1 {
        return Err("百度下载响应文件数量不匹配".into());
    }
    let out = &entries[0];
    if out
        .get("fs_id")
        .and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse().ok()))
        != Some(fsid)
    {
        return Err("百度下载响应文件标识不匹配".into());
    }
    let raw = out
        .get("dlink")
        .and_then(|v| v.as_str())
        .filter(|v| !v.chars().any(char::is_control))
        .ok_or("百度下载响应缺少有效直链")?;
    let url = Url::parse(raw).map_err(|_| "百度下载直链格式无效")?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("百度下载直链格式无效".into());
    }
    if matches!(url.host_str(), Some("pan.baidu.com" | "passport.baidu.com")) {
        return Err("百度下载响应返回分享或认证页面，不能播放".into());
    }
    super::pan_playback_guard::check_current()?;
    if tokio::time::Instant::now() >= ctx.deadline {
        return Err("百度请求总预算耗尽".into());
    }
    let mut headers = vec![
        ("User-Agent".into(), UA.into()),
        ("Referer".into(), ctx.page_url.to_string()),
    ];
    let cookie = ctx.cookies.header(&url);
    if !cookie.is_empty() {
        headers.push(("Cookie".into(), cookie));
    }
    Ok(CspPlay {
        url: url.to_string(),
        headers,
        label: Some(format!("百度网盘 · {}", selected.name)),
    })
}

fn unsigned_text(value: &str) -> Option<u64> {
    if value.is_empty() || !value.bytes().all(|v| v.is_ascii_digit()) {
        return None;
    }
    value.parse().ok()
}

fn unsigned_value(value: &serde_json::Value) -> Option<u64> {
    value.as_u64().or_else(|| unsigned_text(value.as_str()?))
}

fn directory_flag(value: &serde_json::Value) -> Option<u64> {
    match value {
        serde_json::Value::String(flag) => match flag.as_str() {
            "0" => Some(0),
            "1" => Some(1),
            _ => None,
        },
        _ => value.as_u64().filter(|flag| matches!(*flag, 0 | 1)),
    }
}

fn valid_file_entry(value: &serde_json::Value) -> bool {
    let Some(entry) = value.as_object() else {
        return false;
    };
    let id = entry
        .get("fs_id")
        .and_then(|id| id.as_u64().or_else(|| id.as_str()?.parse().ok()));
    id.is_some_and(|id| id > 0)
        && entry
            .get("server_filename")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|name| !name.trim().is_empty())
        && entry
            .get("isdir")
            .is_none_or(|flag| directory_flag(flag).is_some())
}

fn endpoint(value: &str) -> Result<Url, String> {
    let url = Url::parse(value).map_err(|_| "百度端点格式无效".to_string())?;
    let loopback = url
        .host_str()
        .and_then(|host| {
            host.trim_matches(['[', ']'])
                .parse::<std::net::IpAddr>()
                .ok()
        })
        .is_some_and(|host| host.is_loopback());
    let official = url.scheme() == "https"
        && url.host_str() == Some("pan.baidu.com")
        && url.port_or_known_default() == Some(443);
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || (!official && !loopback)
    {
        return Err("百度端点格式无效".into());
    }
    Ok(url)
}

fn allowed_redirect(destination: &Url, origin: &Url) -> bool {
    if !destination.username().is_empty() || destination.password().is_some() {
        return false;
    }
    destination.origin() == origin.origin()
        || (origin.scheme() == "https"
            && origin.host_str() == Some("pan.baidu.com")
            && destination.scheme() == "https"
            && destination.port_or_known_default() == Some(443)
            && matches!(
                destination.host_str(),
                Some("pan.baidu.com" | "passport.baidu.com")
            ))
}

async fn send(
    client: &reqwest::Client,
    cookies: &mut Cookies,
    mut request: Request,
    origin: &Url,
    deadline: tokio::time::Instant,
    stage: &str,
) -> Result<(String, Url), BaiduInspectionFailure> {
    for hop in 0..=5 {
        super::pan_playback_guard::check_current()?;
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(format!("百度 {stage} 请求总预算耗尽").into());
        }
        *request.timeout_mut() = Some(remaining.min(std::time::Duration::from_secs(15)));
        request.headers_mut().remove(header::COOKIE);
        let cookie = cookies.header(request.url());
        if !cookie.is_empty() {
            request.headers_mut().insert(
                header::COOKIE,
                header::HeaderValue::from_str(&cookie)
                    .map_err(|_| format!("百度 {stage} 会话格式无效"))?,
            );
        }
        let next_request = request
            .try_clone()
            .ok_or_else(|| format!("百度 {stage} 请求不可重试"))?;
        super::pan_playback_guard::check_current()?;
        let response = client.execute(next_request).await;
        super::pan_playback_guard::check_current()?;
        let mut response = response.map_err(|_| format!("百度 {stage} 请求传输失败"))?;
        cookies.observe(response.headers(), response.url());
        if matches!(response.status().as_u16(), 301 | 302 | 303 | 307 | 308) {
            if hop == 5 {
                return Err(format!("百度 {stage} 跳转次数超限").into());
            }
            let destination = response
                .headers()
                .get(header::LOCATION)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| response.url().join(value).ok())
                .filter(|destination| allowed_redirect(destination, origin))
                .ok_or_else(|| format!("百度 {stage} 认证跳转未获允许"))?;
            if response.status().as_u16() == 303
                || (matches!(response.status().as_u16(), 301 | 302)
                    && request.method() == Method::POST)
            {
                *request.method_mut() = Method::GET;
                *request.body_mut() = None;
                request.headers_mut().remove(header::CONTENT_TYPE);
                request.headers_mut().remove(header::CONTENT_LENGTH);
            }
            *request.url_mut() = destination;
            continue;
        }
        if !response.status().is_success() {
            let status = response.status().as_u16();
            return Err(BaiduInspectionFailure {
                message: format!("百度 {stage} 返回 HTTP {status}"),
                cause: BaiduFailureCause::Http(status),
                error_messages: Vec::new(),
            });
        }
        let final_url = response.url().clone();
        let mut body = Vec::new();
        loop {
            super::pan_playback_guard::check_current()?;
            let chunk = response.chunk().await;
            super::pan_playback_guard::check_current()?;
            let Some(chunk) = chunk.map_err(|_| format!("百度 {stage} 响应读取失败"))?
            else {
                break;
            };
            if body.len() + chunk.len() > 2 * 1024 * 1024 {
                return Err(format!("百度 {stage} 响应超过大小限制").into());
            }
            body.extend_from_slice(&chunk);
        }
        let body = String::from_utf8(body).map_err(|_| format!("百度 {stage} 响应编码无效"))?;
        return Ok((body, final_url));
    }
    Err(format!("百度 {stage} 跳转次数超限").into())
}

fn response_json(body: &str, stage: &str) -> Result<serde_json::Value, String> {
    serde_json::from_str(body).map_err(|_| format!("百度 {stage} 响应不是有效 JSON"))
}

fn integer_errno(value: &serde_json::Value, stage: &str) -> Result<i64, String> {
    value
        .get("errno")
        .and_then(|value| value.as_i64())
        .ok_or_else(|| format!("百度 {stage} 响应未提供整数 errno"))
}

fn page_scalar(page: &str, key: &str) -> Option<String> {
    let pattern = format!(
        r#"(?m)(?:^|[^\w])["']?{}["']?\s*[:=]\s*("(?:\\.|[^"\\])*"|'[^'\\]*'|-?\d+)"#,
        regex::escape(key)
    );
    let regex = regex::Regex::new(&pattern).ok()?;
    let scalar = regex.captures(page)?.get(1)?.as_str();
    if scalar.starts_with('\'') {
        return Some(scalar[1..scalar.len() - 1].to_string());
    }
    match serde_json::from_str::<serde_json::Value>(scalar).ok()? {
        serde_json::Value::String(value) => Some(value),
        serde_json::Value::Number(value) if value.as_i64().is_some() => Some(value.to_string()),
        _ => None,
    }
}

fn ajax_query(page: &str, cookies: &Cookies, url: &Url) -> Vec<(&'static str, String)> {
    vec![
        ("channel", "chunlei".into()),
        ("web", "1".into()),
        ("app_id", "250528".into()),
        ("clienttype", "0".into()),
        (
            "bdstoken",
            page_scalar(page, "bdstoken").unwrap_or_default(),
        ),
        (
            "logid",
            super::shared::b64_encode(cookies.value("BAIDUID", url).unwrap_or("").as_bytes()),
        ),
    ]
}

fn valid_percent_encoding(value: &str) -> bool {
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len()
                || !bytes[index + 1].is_ascii_hexdigit()
                || !bytes[index + 2].is_ascii_hexdigit()
            {
                return false;
            }
            index += 3;
        } else {
            index += 1;
        }
    }
    true
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0)
}

fn valid_cookie_pair(name: &str, value: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_\x60|~".contains(&byte))
        && value.bytes().all(
            |byte| matches!(byte, 0x21 | 0x23..=0x2B | 0x2D..=0x3A | 0x3C..=0x5B | 0x5D..=0x7E),
        )
}

struct Cookie {
    value: String,
    host_only: bool,
    secure: bool,
    expires_at: Option<CookieDeadline>,
}

enum CookieDeadline {
    MaxAge {
        received_at: std::time::Instant,
        lifetime: std::time::Duration,
    },
    Expires(chrono::DateTime<chrono::Utc>),
}

impl CookieDeadline {
    fn expired(&self) -> bool {
        match self {
            Self::MaxAge {
                received_at,
                lifetime,
            } => received_at.elapsed() >= *lifetime,
            Self::Expires(deadline) => chrono::Utc::now() >= *deadline,
        }
    }
}

struct Cookies {
    entries: BTreeMap<(String, String, String), Cookie>,
}

impl Cookies {
    fn new(header: &str, url: &Url) -> Result<Self, String> {
        let mut cookies = Self {
            entries: BTreeMap::new(),
        };
        for pair in header
            .split(';')
            .map(str::trim)
            .filter(|pair| !pair.is_empty())
        {
            let (name, value) = pair
                .split_once('=')
                .filter(|(name, value)| valid_cookie_pair(name, value))
                .ok_or_else(|| "百度请求会话格式无效（未发起请求）".to_string())?;
            let domain = if url.host_str() == Some("pan.baidu.com") {
                "baidu.com"
            } else {
                url.host_str().unwrap_or("")
            };
            cookies.entries.insert(
                (name.into(), domain.into(), "/".into()),
                Cookie {
                    value: value.into(),
                    host_only: domain != "baidu.com",
                    secure: url.scheme() == "https",
                    expires_at: None,
                },
            );
        }
        Ok(cookies)
    }

    fn insert(&mut self, name: &str, value: &str, url: &Url, path: &str, secure: bool) {
        // A newly verified share key replaces older visible keys, including scoped paths.
        self.entries
            .retain(|key, cookie| key.0 != name || !Self::host_matches(key, cookie, url));
        self.entries.insert(
            (
                name.into(),
                url.host_str().unwrap_or("").into(),
                path.into(),
            ),
            Cookie {
                value: value.into(),
                host_only: true,
                secure,
                expires_at: None,
            },
        );
    }

    fn observe(&mut self, headers: &header::HeaderMap, url: &Url) {
        for header in headers
            .get_all(header::SET_COOKIE)
            .iter()
            .filter_map(|value| value.to_str().ok())
        {
            let mut parts = header.split(';').map(str::trim);
            let Some((name, value)) = parts
                .next()
                .and_then(|part| part.split_once('='))
                .filter(|(name, value)| valid_cookie_pair(name, value))
            else {
                continue;
            };
            let host = url.host_str().unwrap_or("");
            let mut domain = host.to_string();
            let mut host_only = true;
            let mut path = url
                .path()
                .rsplit_once('/')
                .map(|(path, _)| path)
                .filter(|path| !path.is_empty())
                .unwrap_or("/")
                .to_string();
            let mut secure = false;
            let mut max_age = None;
            let mut expires = None;
            let mut accepted = true;
            for attribute in parts {
                let (key, attr) = attribute.split_once('=').unwrap_or((attribute, ""));
                match key.to_ascii_lowercase().as_str() {
                    "domain" => {
                        let requested = attr.trim_start_matches('.').to_ascii_lowercase();
                        if requested != host
                            && !(requested == "baidu.com" && host.ends_with(".baidu.com"))
                        {
                            accepted = false;
                        }
                        domain = requested;
                        host_only = false;
                    }
                    "path" if attr.starts_with('/') => path = attr.into(),
                    "secure" => secure = true,
                    "max-age" => {
                        max_age = attr.parse::<i64>().ok();
                    }
                    "expires" => {
                        expires = chrono::DateTime::parse_from_rfc2822(attr)
                            .ok()
                            .map(|date| date.with_timezone(&chrono::Utc));
                    }
                    _ => {}
                }
            }
            if !accepted {
                continue;
            }
            let key = (name.into(), domain, path);
            // Max-Age uses elapsed time, takes precedence, and avoids deadline overflow.
            let expires_at = max_age
                .map(|age: i64| CookieDeadline::MaxAge {
                    received_at: std::time::Instant::now(),
                    lifetime: std::time::Duration::from_secs(age.max(0) as u64),
                })
                .or_else(|| expires.map(CookieDeadline::Expires));
            let delete =
                value.is_empty() || expires_at.as_ref().is_some_and(CookieDeadline::expired);
            if delete {
                self.entries.remove(&key);
            } else {
                self.entries.insert(
                    key,
                    Cookie {
                        value: value.into(),
                        host_only,
                        secure,
                        expires_at,
                    },
                );
            }
        }
    }

    fn host_matches(key: &(String, String, String), cookie: &Cookie, url: &Url) -> bool {
        let host = url.host_str().unwrap_or("");
        host == key.1
            || (!cookie.host_only
                && host
                    .strip_suffix(&key.1)
                    .is_some_and(|prefix| prefix.ends_with('.')))
    }

    fn matches(key: &(String, String, String), cookie: &Cookie, url: &Url) -> bool {
        !cookie
            .expires_at
            .as_ref()
            .is_some_and(CookieDeadline::expired)
            && Self::host_matches(key, cookie, url)
            && (!cookie.secure || url.scheme() == "https")
            && (url.path() == key.2
                || (url.path().starts_with(&key.2)
                    && (key.2.ends_with('/')
                        || url.path().as_bytes().get(key.2.len()) == Some(&b'/'))))
    }

    fn value(&self, name: &str, url: &Url) -> Option<&str> {
        self.entries
            .iter()
            .filter(|(key, cookie)| key.0 == name && Self::matches(key, cookie, url))
            .max_by_key(|(key, _)| key.2.len())
            .map(|(_, cookie)| cookie.value.as_str())
    }

    fn header(&self, url: &Url) -> String {
        let mut matching: Vec<_> = self
            .entries
            .iter()
            .filter(|(key, cookie)| Self::matches(key, cookie, url))
            .collect();
        matching.sort_by_key(|(key, _)| std::cmp::Reverse(key.2.len()));
        matching
            .into_iter()
            .map(|(key, cookie)| format!("{}={}", key.0, cookie.value))
            .collect::<Vec<_>>()
            .join("; ")
    }
}

#[cfg(test)]
#[path = "pan_baidu_play_protocol_tests.rs"]
mod protocol_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    fn initial_list_shape_cases() -> Vec<serde_json::Value> {
        let mut cases = vec![
            serde_json::json!(null),
            serde_json::json!(false),
            serde_json::json!(1),
            serde_json::json!(-1),
            serde_json::json!(1.5),
            serde_json::json!("synthetic"),
            serde_json::json!([]),
            serde_json::json!({}),
        ];
        let valid = serde_json::json!({
            "fs_id": 1, "server_filename": "synthetic.mp4", "isdir": 0
        });
        cases.push(valid.clone());
        for flag in ["0", "1", "00", "01", "+0", " 1", "1 "] {
            let mut entry = valid.clone();
            entry["isdir"] = serde_json::json!(flag);
            cases.push(entry);
        }
        for field in ["fs_id", "server_filename", "isdir"] {
            let mut missing = valid.clone();
            missing.as_object_mut().unwrap().remove(field);
            cases.push(missing);
            for value in [
                serde_json::json!(null),
                serde_json::json!(false),
                serde_json::json!(1),
                serde_json::json!(-1),
                serde_json::json!(1.5),
                serde_json::json!("3"),
                serde_json::json!([]),
                serde_json::json!({}),
            ] {
                let mut entry = valid.clone();
                entry[field] = value;
                cases.push(entry);
            }
        }
        for id in [
            serde_json::json!(0),
            serde_json::json!(u64::MAX),
            serde_json::json!("+1"),
            serde_json::json!("01"),
            serde_json::json!("18446744073709551615"),
            serde_json::json!("18446744073709551616"),
            serde_json::json!(" 1"),
            serde_json::json!("1 "),
            serde_json::json!("-1"),
            serde_json::json!(""),
            serde_json::json!("++1"),
        ] {
            let mut entry = valid.clone();
            entry["fs_id"] = id;
            cases.push(entry);
        }
        for name in ["", " \t\n"] {
            let mut entry = valid.clone();
            entry["server_filename"] = serde_json::json!(name);
            cases.push(entry);
        }
        let mut directory = valid;
        directory["isdir"] = serde_json::json!(2);
        cases.push(directory);
        cases
    }

    #[test]
    fn directory_flag_accepts_only_numeric_or_canonical_text_binary_values() {
        for (value, expected) in [
            (serde_json::json!(0), 0),
            (serde_json::json!(1), 1),
            (serde_json::json!("0"), 0),
            (serde_json::json!("1"), 1),
        ] {
            assert_eq!(directory_flag(&value), Some(expected));
            let entry = serde_json::json!({
                "fs_id": 1, "server_filename": "synthetic.mp4", "isdir": value
            });
            assert!(valid_file_entry(&entry));
            assert_eq!(initial_entry_shape(&entry).isdir.rejected, Some(false));
        }
        for value in [
            serde_json::json!(null), serde_json::json!(true), serde_json::json!(false),
            serde_json::json!(-1), serde_json::json!(2), serde_json::json!(0.0),
            serde_json::json!(1.0), serde_json::json!([]), serde_json::json!({}),
            serde_json::json!(""), serde_json::json!("00"), serde_json::json!("01"),
            serde_json::json!("+0"), serde_json::json!("-0"), serde_json::json!(" 1"),
            serde_json::json!("1 "), serde_json::json!("1\n"), serde_json::json!("2"),
        ] {
            assert_eq!(directory_flag(&value), None);
            let entry = serde_json::json!({
                "fs_id": 1, "server_filename": "synthetic.mp4", "isdir": value
            });
            assert!(!valid_file_entry(&entry));
            assert_eq!(initial_entry_shape(&entry).isdir.rejected, Some(true));
        }
    }

    #[test]
    fn initial_list_shape_projection_matches_the_unchanged_guard() {
        let cases = initial_list_shape_cases();
        for value in &cases {
            let shape = initial_entry_shape(value);
            let accepted = shape.entry_kind == BaiduJsonShape::Object
                && [shape.fs_id, shape.server_filename, shape.isdir]
                    .iter()
                    .all(|field| field.rejected == Some(false));
            assert_eq!(accepted, valid_file_entry(value));
            if value.as_object().is_none() {
                for field in [shape.fs_id, shape.server_filename, shape.isdir] {
                    assert_eq!(field.kind, BaiduJsonShape::NotApplicable);
                    assert_eq!(field.rejected, None);
                }
            }
        }
        for first in &cases {
            for second in &cases {
                let items = [first, second];
                let rejected = items.iter().find(|item| !valid_file_entry(item));
                assert_eq!(rejected.is_none(), items.iter().all(|item| valid_file_entry(item)));
                let expected = if !valid_file_entry(first) {
                    Some(first)
                } else if !valid_file_entry(second) {
                    Some(second)
                } else {
                    None
                };
                assert_eq!(rejected.copied(), expected);
            }
        }
    }

    #[test]
    fn initial_list_shape_nine_field_kinds_and_missing_directory() {
        use BaiduJsonShape::*;
        let kinds = [
            (None, Missing),
            (Some(serde_json::json!(null)), Null),
            (Some(serde_json::json!(true)), Boolean),
            (Some(serde_json::json!(1)), UnsignedInteger),
            (Some(serde_json::json!(-1)), SignedInteger),
            (Some(serde_json::json!(1.5)), FloatingNumber),
            (Some(serde_json::json!("synthetic")), String),
            (Some(serde_json::json!([])), Array),
            (Some(serde_json::json!({})), Object),
        ];
        for field in ["fs_id", "server_filename", "isdir"] {
            for (value, kind) in &kinds {
                let mut entry = serde_json::json!({
                    "fs_id": 1, "server_filename": "synthetic.mp4", "isdir": 0
                });
                match value {
                    Some(value) => entry[field] = value.clone(),
                    None => { entry.as_object_mut().unwrap().remove(field); }
                }
                let shape = initial_entry_shape(&entry);
                let projected = match field {
                    "fs_id" => shape.fs_id,
                    "server_filename" => shape.server_filename,
                    _ => shape.isdir,
                };
                assert_eq!(projected.kind, *kind);
            }
        }
        let entry = serde_json::json!({"fs_id": "+1", "server_filename": "synthetic.mp4"});
        let shape = initial_entry_shape(&entry);
        assert!(valid_file_entry(&entry));
        assert_eq!(shape.fs_id.rejected, Some(false));
        assert_eq!(shape.isdir.kind, Missing);
        assert_eq!(shape.isdir.rejected, Some(false));
    }

    #[tokio::test]
    async fn initial_list_shape_unarmed_and_valid_scopes_retain_nothing() {
        observe_initial_rejection_if_scoped(&serde_json::json!(null));
        assert!(INITIAL_LIST_SHAPE.try_with(std::cell::Cell::get).is_err());
        let (result, shape) = with_initial_list_rejection_shape(async {
            let items = [serde_json::json!({"fs_id": 1, "server_filename": "synthetic.mp4"})];
            if let Some(rejected) = items.iter().find(|item| !valid_file_entry(item)) {
                observe_initial_rejection_if_scoped(rejected);
            }
            items.iter().all(valid_file_entry)
        }).await;
        assert!(result);
        assert!(shape.is_none());
        assert!(INITIAL_LIST_SHAPE.try_with(std::cell::Cell::get).is_err());
    }

    #[tokio::test]
    async fn initial_list_shape_first_only_and_task_local_isolation() {
        let first = serde_json::json!({"fs_id": 0, "server_filename": "synthetic.mp4"});
        let expected = initial_entry_shape(&first);
        let a = with_initial_list_rejection_shape(async {
            observe_initial_rejection_if_scoped(&first);
            tokio::task::yield_now().await;
            observe_initial_rejection_if_scoped(&serde_json::json!([]));
            "unchanged-result"
        });
        let b = with_initial_list_rejection_shape(async {
            tokio::task::yield_now().await;
            observe_initial_rejection_if_scoped(&serde_json::json!(null));
            7
        });
        let ((result_a, shape_a), (result_b, shape_b)) = tokio::join!(a, b);
        assert_eq!(result_a, "unchanged-result");
        assert_eq!(shape_a, Some(expected));
        assert_eq!(result_b, 7);
        assert_eq!(shape_b, Some(initial_entry_shape(&serde_json::json!(null))));
        assert!(INITIAL_LIST_SHAPE.try_with(std::cell::Cell::get).is_err());
        let (_, next) = with_initial_list_rejection_shape(async {}).await;
        assert!(next.is_none());
    }

    #[test]
    fn initial_list_shape_serialization_contains_only_fixed_schema() {
        let entry = serde_json::json!({
            "fs_id": "synthetic-do-not-echo",
            "server_filename": "synthetic-do-not-echo",
            "isdir": "synthetic-do-not-echo",
            "synthetic-do-not-echo": {"value": "synthetic-do-not-echo"}
        });
        let serialized = serde_json::to_string(&initial_entry_shape(&entry)).unwrap();
        assert!(!serialized.contains("synthetic-do-not-echo"));
        let shape: serde_json::Value = serde_json::from_str(&serialized).unwrap();
        let mut keys: Vec<_> = shape.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["entry_kind", "fs_id", "isdir", "server_filename", "stage"]);
        assert_eq!(shape["stage"], "initialList");
        for field in ["fs_id", "server_filename", "isdir"] {
            let mut keys: Vec<_> = shape[field].as_object().unwrap().keys().map(String::as_str).collect();
            keys.sort_unstable();
            assert_eq!(keys, ["kind", "rejected"]);
        }
    }

    #[derive(Debug, Clone)]
    struct Recorded {
        method: String,
        target: String,
        cookie_keys: Vec<String>,
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

    /// routes: (method, path 前缀, 状态码, 应答体, 应答 Set-Cookie 键)
    fn spawn_replay(routes: Arc<Vec<(String, String, u16, String, Vec<String>)>>) -> Replay {
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
                let mut cookie = String::new();
                let mut len = 0usize;
                loop {
                    let mut h = String::new();
                    match reader.read_line(&mut h) {
                        Ok(0) | Err(_) => break,
                        Ok(_) if h == "\r\n" || h == "\n" => break,
                        Ok(_) => {
                            let low = h.to_ascii_lowercase();
                            if low.starts_with("cookie:") {
                                // 用原始行取值（lowercase 会把 BDUSS 读成 bduss，键名断言会假红）
                                cookie = h[7..].trim().to_string();
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
                        cookie_keys: cookie
                            .split(';')
                            .filter_map(|p| p.split('=').next().map(|s| s.trim().to_string()))
                            .collect(),
                        body,
                    });
                }
                let hit = routes.iter().find(|(m, p, _, _, _)| {
                    method.eq_ignore_ascii_case(m) && target.starts_with(p.as_str())
                });
                let (status, resp_body, setck) = match hit {
                    Some((_, _, s, b, ck)) => (*s, b.clone(), ck.clone()),
                    None => (404u16, "{\"errno\":404}".to_string(), Vec::new()),
                };
                let mut resp = format!(
                    "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n",
                    status,
                    if status == 200 { "OK" } else { "Err" },
                    resp_body.len()
                );
                for name in setck {
                    // 只回键名占位（值不进任何日志/断言）
                    resp.push_str(&format!("Set-Cookie: {name}=placeholder; Path=/\r\n"));
                }
                resp.push_str("Connection: close\r\n\r\n");
                resp.push_str(&resp_body);
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.flush();
            }
        });
        Replay {
            base: format!("http://127.0.0.1:{port}"),
            hits,
        }
    }

    fn ep_of(srv: &Replay) -> BaiduEndpoints {
        BaiduEndpoints {
            page: format!("{}/s", srv.base),
            verify: format!("{}/share/verify", srv.base),
            list: format!("{}/share/list", srv.base),
        }
    }

    const LOGIN_PAGE: &str = "<title>登录百度网盘</title><script>window.localStorage.setItem('passLoginType','qrcode')</script>";
    const OK_PAGE: &str = "<html><body>分享页内容（正常）</body></html>";

    #[tokio::test]
    async fn selected_file_dlink_exact_fid() {
        let srv = spawn_replay(Arc::new(vec![
            ("GET".into(), "/s/1AbCd".into(), 200, r#"<script>locals.mset({shareid:12,share_uk:34,vip_identity:0,bdstoken:"fixture"});</script>"#.into(), vec![]),
            ("GET".into(), "/share/list".into(), 200, r#"{"errno":0,"list":[{"fs_id":9007199254740993,"server_filename":"EP03.mp4","size":42,"isdir":0},{"fs_id":2,"server_filename":"EP01.mp4","size":99,"isdir":0}]}"#.into(), vec![]),
            ("GET".into(), "/share/tplconfig".into(), 200, r#"{"errno":0,"data":{"sign":"fixture","timestamp":123}}"#.into(), vec![]),
            ("GET".into(), "/api/loginStatus".into(), 200, r#"{"errno":0,"login_info":{"vip_identity":0,"bdstoken":"fixture","uk":56}}"#.into(), vec![]),
            ("POST".into(), "/api/sharedownload".into(), 200, r#"{"errno":0,"list":[{"fs_id":9007199254740993,"dlink":"https://cdn.example.test/full.mp4"}]}"#.into(), vec![]),
        ]));
        let play = resolve_selected_with(
            &ep_of(&srv),
            Some("BDUSS=fixture"),
            "1AbCd",
            "",
            Some("9007199254740993"),
            &super::super::pan_episode_select::EpisodeSpec {
                title: "EP01".into(),
                order: Some(1),
            },
        )
        .await
        .expect("exact selected file must resolve");
        assert_eq!(play.url, "https://cdn.example.test/full.mp4");
        assert!(play.label.unwrap().contains("EP03.mp4"));
        let reqs = srv.requests();
        let post = reqs
            .iter()
            .find(|v| v.target.starts_with("/api/sharedownload"))
            .unwrap();
        assert!(post.body.contains("9007199254740993"));
        for path in ["/api/loginStatus", "/share/tplconfig", "/api/sharedownload"] {
            let request = reqs
                .iter()
                .find(|request| request.target.starts_with(path))
                .unwrap();
            let url =
                reqwest::Url::parse(&format!("http://fixture.invalid{}", request.target)).unwrap();
            let query: std::collections::BTreeMap<_, _> = url.query_pairs().into_owned().collect();
            for (key, value) in [("clienttype", "0"), ("app_id", "250528"), ("web", "1")] {
                assert_eq!(
                    query.get(key).map(String::as_str),
                    Some(value),
                    "official request defaults missing from {path}"
                );
            }
        }
    }

    /// ★ 门禁 ①：未登录 ⇒ NEED_LOGIN（classify_err 翻译成 Unauthorized）
    #[tokio::test]
    async fn no_credential_is_need_login() {
        let srv = spawn_replay(Arc::new(Vec::new()));
        let err = resolve_with(&ep_of(&srv), None, "1AbCd", "pwd")
            .await
            .expect_err("未登录必须 Err");
        assert!(err.starts_with("NEED_LOGIN:baidu|"), "{err}");
    }

    /// 登录入口仅证明当前请求未获得分享信息，不证明已保存账号过期。
    #[tokio::test]
    async fn login_only_page_reports_request_without_expiry_claim() {
        let routes = Arc::new(vec![(
            "GET".into(),
            "/s/1AbCd".into(),
            200,
            LOGIN_PAGE.into(),
            Vec::new(),
        )]);
        let srv = spawn_replay(routes);
        let err = resolve_with(&ep_of(&srv), Some("BDUSS=stale"), "1AbCd", "pwd")
            .await
            .expect_err("没有取得分享信息必须 Err");
        assert!(
            err.contains("当前请求未获分享信息")
                && !err.starts_with("NEED_LOGIN:")
                && !err.contains("已失效"),
            "{err}"
        );
        assert!(
            srv.requests()
                .iter()
                .all(|r| !r.target.contains("/share/verify")),
            "登录页都渲染出来了，verify 不该发（白费一次风控暴露）"
        );
    }

    /// ★ 门禁 ③：verify 成功 ⇒ randsk 进 BDCLND → share/list 带 sekey 参数
    ///            （web 逐字）→ 分享元数据不足时仍停止取直链。
    #[tokio::test]
    async fn verify_then_list_missing_share_metadata_stops_download() {
        let routes = Arc::new(vec![
            (
                "GET".into(),
                "/s/1AbCd".into(),
                200,
                OK_PAGE.into(),
                Vec::new(),
            ),
            (
                "POST".into(),
                "/share/verify".into(),
                200,
                r#"{"errno":0,"randsk":"RANDSK_VALUE"}"#.into(),
                Vec::new(),
            ),
            (
                "GET".into(),
                "/share/list".into(),
                200,
                r#"{"errno":0,"list":[{"fs_id":1,"server_filename":"a.mkv","size":1}]}"#.into(),
                Vec::new(),
            ),
        ]);
        let srv = spawn_replay(routes);
        let err = resolve_with(&ep_of(&srv), Some("BDUSS=x"), "1AbCd", "pwd99")
            .await
            .expect_err("分享元数据不足时必须停止取直链");
        assert!(
            err.contains("uk 元数据缺失"),
            "应明确报告缺失的分享元数据：{err}"
        );
        let reqs = srv.requests();
        // Official verify puts surl in the query, while pwd remains in the form.
        let verify = reqs
            .iter()
            .find(|r| r.target.starts_with("/share/verify"))
            .expect("必须有 verify");
        assert!(
            verify.target.contains("surl=AbCd") && !verify.body.contains("surl="),
            "surl must be a query field with the leading share marker removed"
        );
        assert!(verify.body.contains("pwd=pwd99"), "{}", verify.body);
        // list 带 sekey 形态（web 逐字）
        let list = reqs
            .iter()
            .find(|r| r.target.starts_with("/share/list"))
            .expect("必须有 list");
        assert!(
            list.target.contains("sekey="),
            "verify 出了 randsk ⇒ list 要带 sekey：{}",
            list.target
        );
        assert!(list.target.contains("is_from_web=true"), "{}", list.target);
        assert!(
            list.cookie_keys.contains(&"BDUSS".to_string()),
            "登录态要带上"
        );
    }

    /// ★ 门禁 ④：verify 被拒（errno 非 0）⇒ 如实报 errno，不猜语义
    #[tokio::test]
    async fn verify_rejected_is_honest_with_errno() {
        let routes = Arc::new(vec![
            (
                "GET".into(),
                "/s/1AbCd".into(),
                200,
                OK_PAGE.into(),
                Vec::new(),
            ),
            (
                "POST".into(),
                "/share/verify".into(),
                200,
                r#"{"errno":-12}"#.into(),
                Vec::new(),
            ),
        ]);
        let srv = spawn_replay(routes);
        let err = resolve_with(&ep_of(&srv), Some("BDUSS=x"), "1AbCd", "badpwd")
            .await
            .expect_err("verify 被拒必须 Err");
        assert!(err.contains("errno=-12"), "{err}");
    }

    /// ★ 门禁 ⑤：无提取码 + HasPwd ⇒ list 侧如实报（hp0 判据）
    #[tokio::test]
    async fn locked_share_without_passcode_is_honest() {
        let routes = Arc::new(vec![
            (
                "GET".into(),
                "/s/1NoPwd".into(),
                200,
                OK_PAGE.into(),
                Vec::new(),
            ),
            (
                "GET".into(),
                "/share/list".into(),
                200,
                r#"{"errno":0,"HasPwd":true,"list":[],"count":0}"#.into(),
                Vec::new(),
            ),
        ]);
        let srv = spawn_replay(routes);
        let err = resolve_with(&ep_of(&srv), Some("BDUSS=x"), "1NoPwd", "")
            .await
            .expect_err("需要提取码而没给 ⇒ Err");
        assert!(err.contains("需要提取码"), "{err}");
    }
}
