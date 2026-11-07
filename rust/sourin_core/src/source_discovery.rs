//! Public GitHub discovery has an explicit proxy boundary and a manual install boundary.
use crate::{model::PersistedProvider, state::AppState, tvbox};
use md5::{Digest, Md5};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

const FILE: &str = "github-discovery.json";
const MAX_BYTES: usize = 2 * 1024 * 1024;
const MAX_REPOSITORIES: usize = 12;
const MAX_CONFIGS: usize = 48;
const MAX_NATIVE_CANDIDATES: usize = 36;
const MAX_UNSUPPORTED_CANDIDATES: usize = 12;
static STORE_LOCK: Mutex<()> = Mutex::new(());
static RUN_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
static RUNNING: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Discovery {
    pub proxy_url: String,
    pub automatic: bool,
    pub last_scan: i64,
    pub last_error: String,
    pub candidates: Vec<Candidate>,
    pub notices: Vec<Notice>,
    pub coverage: Coverage,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Coverage {
    pub repositories: usize,
    pub configurations: usize,
    pub native_candidates: usize,
    pub unsupported_candidates: usize,
    pub duplicate_candidates: usize,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Candidate {
    pub id: String,
    pub name: String,
    pub repository: String,
    pub config_url: String,
    pub api: String,
    pub key: String,
    pub kind: Option<i64>,
    pub status: String,
    pub message: String,
    pub checked_at: i64,
    pub provider_id: Option<String>,
    pub install_pending: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Notice {
    pub at: i64,
    pub text: String,
    pub unread: bool,
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
fn read(dir: &Path) -> Result<Discovery, String> {
    match std::fs::read(dir.join(FILE)) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|_| "源发现记录无法读取，请保留文件后重试".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Discovery::default()),
        Err(_) => Err("无法读取源发现记录".into()),
    }
}
fn write(dir: &Path, data: &Discovery) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|_| "无法创建源发现目录")?;
    let path = dir.join(FILE);
    let tmp = path.with_extension("json.tmp");
    std::fs::write(
        &tmp,
        serde_json::to_vec(data).map_err(|_| "无法编码源发现记录")?,
    )
    .map_err(|_| "无法保存源发现记录")?;
    std::fs::rename(tmp, path).map_err(|_| "无法替换源发现记录".into())
}
fn edit<T>(dir: &Path, f: impl FnOnce(&mut Discovery) -> T) -> Result<T, String> {
    let _guard = STORE_LOCK.lock().map_err(|_| "源发现存储忙")?;
    let mut data = read(dir)?;
    let result = f(&mut data);
    write(dir, &data)?;
    Ok(result)
}
pub fn status(state: &AppState) -> Result<Value, String> {
    let _guard = STORE_LOCK.lock().map_err(|_| "源发现存储忙")?;
    let mut value =
        serde_json::to_value(read(&state.data_dir)?).map_err(|_| "无法读取源发现状态")?;
    if let Some(candidates) = value["candidates"].as_array_mut() {
        for c in candidates {
            c["installed"] = json!(
                c["installPending"] != true
                    && c["providerId"]
                        .as_str()
                        .is_some_and(|id| state.registry.get(id).is_some())
            );
        }
    }
    value["running"] = json!(RUNNING.load(Ordering::Acquire));
    Ok(value)
}
fn proxy_url(raw: &str) -> Result<String, String> {
    let mut u = reqwest::Url::parse(raw.trim()).map_err(|_| "请先填写有效代理地址")?;
    if !matches!(u.scheme(), "http" | "https" | "socks5" | "socks5h")
        || u.host_str().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.query().is_some()
        || u.fragment().is_some()
        || u.path() != "/" && !u.path().is_empty()
    {
        return Err("代理需为 HTTP、HTTPS 或 SOCKS5 地址，不含账号或额外路径".into());
    }
    // Remote DNS prevents local resolution from becoming a separate network path.
    if u.scheme() == "socks5" {
        let _ = u.set_scheme("socks5h");
    }
    Ok(u.to_string())
}
pub fn configure(state: &AppState, raw: &str, automatic: bool) -> Result<Value, String> {
    let proxy = if raw.trim().is_empty() {
        String::new()
    } else {
        proxy_url(raw)?
    };
    edit(&state.data_dir, |s| {
        s.proxy_url = proxy;
        s.automatic = automatic;
    })?;
    status(state)
}
pub fn mark_read(state: &AppState) -> Result<Value, String> {
    edit(&state.data_dir, |s| {
        for n in &mut s.notices {
            n.unread = false;
        }
    })?;
    status(state)
}
fn public_url(u: &reqwest::Url) -> bool {
    if !matches!(u.scheme(), "http" | "https") || !u.username().is_empty() || u.password().is_some()
    {
        return false;
    }
    let Some(host) = u.host_str() else {
        return false;
    };
    if host.eq_ignore_ascii_case("localhost")
        || host.ends_with(".localhost")
        || host.ends_with(".local")
    {
        return false;
    }
    if let Ok(ip) = host.trim_matches(['[', ']']).parse::<std::net::IpAddr>() {
        return match ip {
            std::net::IpAddr::V4(ip) => {
                !ip.is_private()
                    && !ip.is_loopback()
                    && !ip.is_link_local()
                    && !ip.is_unspecified()
                    && !ip.is_multicast()
            }
            std::net::IpAddr::V6(ip) => {
                !ip.is_loopback()
                    && !ip.is_unspecified()
                    && !ip.is_unique_local()
                    && !ip.is_unicast_link_local()
                    && !ip.is_multicast()
            }
        };
    }
    true
}
fn strict_client(proxy: &str) -> Result<reqwest::Client, String> {
    let proxy = proxy_url(proxy)?;
    reqwest::Client::builder()
        .no_proxy()
        .proxy(
            reqwest::Proxy::all(proxy)
                .map_err(|_| "代理地址无效")?
                .no_proxy(None),
        )
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(12))
        .user_agent("Sourin-Source-Discovery/1.0")
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 3 || !public_url(attempt.url()) {
                attempt.stop()
            } else {
                attempt.follow()
            }
        }))
        .build()
        .map_err(|_| "无法建立代理连接".into())
}
async fn text(client: &reqwest::Client, raw: &str) -> Result<String, String> {
    let url = reqwest::Url::parse(raw).map_err(|_| "地址格式不正确")?;
    if !public_url(&url) {
        return Err("仅校验公开 HTTP/HTTPS 地址".into());
    }
    let mut response = client
        .get(url)
        .send()
        .await
        .map_err(|_| "代理请求失败或超时")?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status().as_u16()));
    }
    if response.content_length().unwrap_or(0) > MAX_BYTES as u64 {
        return Err("响应超过大小限制".into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "响应读取失败")? {
        if bytes.len() + chunk.len() > MAX_BYTES {
            return Err("响应超过大小限制".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    String::from_utf8(bytes).map_err(|_| "响应编码不支持".into())
}
fn native_job(c: &Candidate) -> tvbox::SiteJob {
    tvbox::SiteJob {
        index: 0,
        key: c.key.clone(),
        name: c.name.clone(),
        api: c.api.clone(),
        kind: c.kind,
        csp: None,
        ext: String::new(),
    }
}
async fn validate(client: &reqwest::Client, c: &Candidate) -> Result<tvbox::ProbeOk, String> {
    if !matches!(c.kind, Some(0 | 1)) {
        return Err("此类型无法在强制代理通道内校验，暂不启用".into());
    }
    // Validate exactly the URL the installed native provider will request.
    let base = tvbox::normalize_api_url(&c.api);
    let mut url = reqwest::Url::parse(&base).map_err(|_| "接口地址无效")?;
    url.query_pairs_mut().append_pair("ac", "list");
    let classes = tvbox::parse_loose_json(&text(client, url.as_str()).await?)?;
    let categories: Vec<crate::model::TvboxCategoryEntry> = classes
        .get("class")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|v| {
            let id = scalar_id(v.get("type_id")?)?;
            let name = v.get("type_name")?.as_str()?.trim();
            if name.is_empty() {
                return None;
            }
            Some(crate::model::TvboxCategoryEntry {
                id,
                name: name.into(),
                pid: None,
            })
        })
        .collect();
    if categories.is_empty() {
        return Err("分类接口没有数据".into());
    }
    let mut url = reqwest::Url::parse(&base).map_err(|_| "接口地址无效")?;
    url.query_pairs_mut()
        .append_pair("ac", "videolist")
        .append_pair("pg", "1");
    let listing = tvbox::parse_loose_json(&text(client, url.as_str()).await?)?;
    if !listing
        .get("list")
        .and_then(Value::as_array)
        .is_some_and(|items| {
            items.iter().any(|v| {
                v.get("vod_id").and_then(scalar_id).is_some()
                    && v.get("vod_name")
                        .and_then(Value::as_str)
                        .is_some_and(|name| !name.trim().is_empty())
            })
        })
    {
        return Err("内容接口没有有效条目".into());
    }
    Ok(tvbox::ProbeOk {
        classes: categories,
        total: listing.get("total").and_then(Value::as_u64).unwrap_or(0),
    })
}
fn scalar_id(value: &Value) -> Option<String> {
    let id = match value {
        Value::String(id) => id.trim().to_string(),
        Value::Number(n) if n.is_u64() || n.is_i64() => n.to_string(),
        _ => return None,
    };
    (!id.is_empty()).then_some(id)
}
fn trim_candidates(candidates: &mut Vec<Candidate>) {
    candidates.sort_by_key(|c| std::cmp::Reverse(c.checked_at));
    let mut native_apis: HashSet<String> = candidates
        .iter()
        .filter(|c| c.provider_id.is_some())
        .filter_map(native_identity)
        .collect();
    let mut remaining = 200;
    candidates.retain(|c| {
        if c.provider_id.is_some() {
            return true;
        }
        if remaining == 0 {
            return false;
        }
        if native_identity(c).is_some_and(|api| !native_apis.insert(api)) {
            return false;
        }
        remaining -= 1;
        true
    });
}
fn notice(s: &mut Discovery, message: String) {
    s.notices.insert(
        0,
        Notice {
            at: now(),
            text: message,
            unread: true,
        },
    );
    s.notices.truncate(30);
}
struct RunFlag;
impl Drop for RunFlag {
    fn drop(&mut self) {
        RUNNING.store(false, Ordering::Release);
    }
}

struct Collection {
    candidates: Vec<Candidate>,
    warning: String,
    coverage: Coverage,
}
async fn bounded_text(
    client: &reqwest::Client,
    url: &str,
    deadline: tokio::time::Instant,
) -> Result<String, String> {
    tokio::time::timeout_at(deadline, text(client, url))
        .await
        .unwrap_or_else(|_| Err("本轮请求时间已用完".into()))
}
// Match the installed provider's request identity, including query/fragment removal.
// Config mirrors and renamed keys must not consume repeated validation slots.
fn native_identity(c: &Candidate) -> Option<String> {
    matches!(c.kind, Some(0 | 1)).then(|| {
        let base = tvbox::normalize_api_url(&c.api);
        reqwest::Url::parse(&base)
            .map(|u| u.to_string())
            .unwrap_or(base)
    })
}

async fn fetch_batch(
    client: &reqwest::Client,
    urls: &[String],
    deadline: tokio::time::Instant,
) -> Vec<Result<String, String>> {
    let mut results = vec![Err("本轮请求时间已用完".into()); urls.len()];
    let semaphore = Arc::new(tokio::sync::Semaphore::new(4));
    let mut tasks = tokio::task::JoinSet::new();
    for (index, url) in urls.iter().cloned().enumerate() {
        let client = client.clone();
        let semaphore = semaphore.clone();
        tasks.spawn(async move {
            let _permit = semaphore.acquire_owned().await;
            (index, bounded_text(&client, &url, deadline).await)
        });
    }
    while !tasks.is_empty() {
        match tokio::time::timeout_at(deadline, tasks.join_next()).await {
            Ok(Some(Ok((index, result)))) => results[index] = result,
            Ok(Some(Err(_))) => (),
            Ok(None) => break,
            Err(_) => {
                tasks.abort_all();
                break;
            }
        }
    }
    results
}

fn config_paths(tree: &Value) -> Option<Vec<String>> {
    let mut paths: Vec<String> = tree
        .get("tree")?
        .as_array()?
        .iter()
        .filter(|f| {
            f.get("type").and_then(Value::as_str) == Some("blob")
                && f.get("size").and_then(Value::as_u64).unwrap_or(0) <= MAX_BYTES as u64
        })
        .filter_map(|f| f.get("path").and_then(Value::as_str))
        .filter(|p| {
            [".json", ".txt", ".conf"]
                .iter()
                .any(|ext| p.to_ascii_lowercase().ends_with(ext))
        })
        .map(str::to_owned)
        .collect();
    paths.sort_by_key(|p| {
        let lower = p.to_ascii_lowercase();
        (
            !(["catalog", "vod", "采集"].iter().any(|k| lower.contains(k))),
            !(["tvbox", "config", "source", "tv.json"]
                .iter()
                .any(|k| lower.contains(k))),
            p.matches('/').count(),
            p.len(),
            p.clone(),
        )
    });
    paths.truncate(6);
    Some(paths)
}

fn config_candidates(config: &Value, repository: &str, url: &str) -> Vec<Candidate> {
    let mut native_apis = HashSet::new();
    let mut unsupported = 0;
    config
        .get("sites")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|site| {
            let api = site.get("api")?.as_str()?;
            let api = tvbox::resolve_api(api, url).unwrap_or_else(|| api.to_string());
            let key = site.get("key").and_then(Value::as_str).unwrap_or("");
            let kind = site
                .get("type")
                .and_then(|v| v.as_i64().or_else(|| v.as_str()?.parse().ok()));
            Some(Candidate {
                id: format!("{:x}", Md5::digest(format!("{url}|{key}|{api}"))),
                repository: repository.into(),
                config_url: url.into(),
                api,
                key: key.into(),
                kind,
                name: site
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("未命名源")
                    .chars()
                    .take(100)
                    .collect(),
                status: "failed".into(),
                message: "本轮未完成校验，请重新发现".into(),
                checked_at: now(),
                ..Default::default()
            })
        })
        // Bound retained allocations per response without stopping before native
        // entries near the end of a large script or duplicated catalog.
        .filter(|candidate| {
            if let Some(api) = native_identity(candidate) {
                native_apis.len() < MAX_NATIVE_CANDIDATES && native_apis.insert(api)
            } else if unsupported < MAX_UNSUPPORTED_CANDIDATES {
                unsupported += 1;
                true
            } else {
                false
            }
        })
        .collect()
}

async fn collect(client: &reqwest::Client, api: &str, raw: &str) -> Result<Collection, String> {
    // Leave validation its own time share; collection must not consume its deadline.
    let started = tokio::time::Instant::now();
    let collection_deadline = started + Duration::from_secs(55);
    let deadline = started + Duration::from_secs(95);
    let mut searches = Vec::new();
    for (query, sort) in [
        ("topic:tvbox archived:false", "updated"),
        ("tvbox in:name,description archived:false", "stars"),
        ("tvbox 采集 in:readme archived:false", "updated"),
    ] {
        let mut url = reqwest::Url::parse(&format!("{api}/search/repositories"))
            .map_err(|_| "GitHub 地址无效")?;
        url.query_pairs_mut()
            .append_pair("q", query)
            .append_pair("sort", sort)
            .append_pair("per_page", "8");
        searches.push(url.to_string());
    }
    let mut failures = 0;
    let mut groups = Vec::new();
    for result in fetch_batch(client, &searches, collection_deadline).await {
        match result.and_then(|body| serde_json::from_str::<Value>(&body).map_err(|_| "".into())) {
            Ok(value) if value.get("items").and_then(Value::as_array).is_some() => {
                if value["incomplete_results"] == true {
                    failures += 1;
                }
                groups.push(value["items"].as_array().unwrap().clone());
            }
            _ => failures += 1,
        }
    }
    // Interleave cohorts before the repository cap, so recent topic updates cannot
    // crowd out established configs or repositories that have no topic tag.
    let mut repos = Vec::new();
    let mut seen_repos = HashSet::new();
    for index in 0..8 {
        for group in &groups {
            let Some(repo) = group.get(index) else {
                continue;
            };
            let Some(name) = repo.get("full_name").and_then(Value::as_str) else {
                continue;
            };
            let Some(branch) = repo.get("default_branch").and_then(Value::as_str) else {
                continue;
            };
            if repos.len() >= MAX_REPOSITORIES
                || name.split('/').count() != 2
                || name
                    .split('/')
                    .any(|part| part.is_empty() || part == "." || part == "..")
                || !name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "-_./".contains(c))
                || !seen_repos.insert(name.to_ascii_lowercase())
            {
                continue;
            }
            repos.push((name.to_string(), branch.to_string()));
        }
    }
    let mut tree_urls = Vec::new();
    for (name, branch) in &repos {
        let mut url = reqwest::Url::parse(api).map_err(|_| "GitHub 地址无效")?;
        url.path_segments_mut()
            .map_err(|_| "GitHub 地址无效")?
            .extend(["repos"])
            .extend(name.split('/'))
            .extend(["git", "trees", branch]);
        url.set_query(Some("recursive=1"));
        tree_urls.push(url.to_string());
    }
    let mut coverage = Coverage::default();
    let mut paths_by_repo = Vec::new();
    for ((name, branch), result) in repos
        .into_iter()
        .zip(fetch_batch(client, &tree_urls, collection_deadline).await)
    {
        match result.and_then(|body| serde_json::from_str::<Value>(&body).map_err(|_| "".into())) {
            Ok(tree) if config_paths(&tree).is_some() => {
                coverage.repositories += 1;
                if tree["truncated"] == true {
                    failures += 1;
                }
                paths_by_repo.push((name, branch, config_paths(&tree).unwrap()));
            }
            _ => failures += 1,
        }
    }
    let mut configurations = Vec::new();
    for index in 0..6 {
        for (name, branch, paths) in &paths_by_repo {
            let Some(path) = paths.get(index) else {
                continue;
            };
            if configurations.len() >= MAX_CONFIGS {
                break;
            }
            let mut url = reqwest::Url::parse(raw).map_err(|_| "GitHub 地址无效")?;
            url.path_segments_mut()
                .map_err(|_| "GitHub 地址无效")?
                .extend(name.split('/'))
                .push(branch)
                .extend(path.split('/'));
            configurations.push((name.clone(), url.to_string()));
        }
    }
    let urls: Vec<_> = configurations.iter().map(|(_, url)| url.clone()).collect();
    let mut pools = Vec::new();
    for ((name, url), result) in configurations
        .into_iter()
        .zip(fetch_batch(client, &urls, collection_deadline).await)
    {
        match result
            .and_then(|body| tvbox::unwrap_tvbox_config_text(&body))
            .and_then(|body| tvbox::parse_loose_json(&body))
        {
            Ok(config) => {
                coverage.configurations += 1;
                pools.push(config_candidates(&config, &name, &url));
            }
            Err(_) => failures += 1,
        }
    }
    let mut found = Vec::new();
    // Native and unsupported entries have independent caps. Round-robin each
    // configuration within each kind so a single large catalog cannot monopolize it.
    for native in [true, false] {
        let mut iterators: Vec<_> = pools
            .iter()
            .map(|pool| {
                pool.iter()
                    .filter(move |c| native_identity(c).is_some() == native)
            })
            .collect();
        let mut seen = HashSet::new();
        let limit = if native {
            MAX_NATIVE_CANDIDATES
        } else {
            MAX_UNSUPPORTED_CANDIDATES
        };
        let mut count = 0;
        loop {
            let mut progressed = false;
            for candidates in &mut iterators {
                for candidate in candidates.by_ref() {
                    progressed = true;
                    let identity =
                        native_identity(candidate).unwrap_or_else(|| candidate.id.clone());
                    if !seen.insert(identity) {
                        coverage.duplicate_candidates += 1;
                        continue;
                    }
                    found.push(candidate.clone());
                    count += 1;
                    break;
                }
                if count >= limit {
                    break;
                }
            }
            if !progressed || count >= limit {
                break;
            }
        }
        if native {
            coverage.native_candidates = count;
        } else {
            coverage.unsupported_candidates = count;
        }
    }
    let semaphore = Arc::new(tokio::sync::Semaphore::new(4));
    let mut tasks = tokio::task::JoinSet::new();
    for (index, candidate) in found.iter_mut().enumerate() {
        if native_identity(candidate).is_none() {
            candidate.status = "unsupported".into();
            candidate.message = "此类型无法在强制代理通道内校验，暂不启用".into();
            continue;
        }
        let c = candidate.clone();
        let client = client.clone();
        let semaphore = semaphore.clone();
        tasks.spawn(async move {
            let _permit = semaphore.acquire_owned().await;
            (index, validate(&client, &c).await)
        });
    }
    while !tasks.is_empty() {
        match tokio::time::timeout_at(deadline, tasks.join_next()).await {
            Ok(Some(Ok((index, result)))) => {
                let candidate = &mut found[index];
                match result {
                    Ok(_) => {
                        candidate.status = "ready".into();
                        candidate.message = "分类与内容接口校验通过；播放需启用后确认".into();
                    }
                    Err(e) => {
                        candidate.status = if matches!(candidate.kind, Some(0 | 1)) {
                            "failed"
                        } else {
                            "unsupported"
                        }
                        .into();
                        candidate.message = e;
                    }
                }
            }
            Ok(Some(Err(_))) => failures += 1,
            Ok(None) => break,
            Err(_) => {
                failures += tasks.len();
                tasks.abort_all();
                break;
            }
        }
    }
    if found.is_empty() && failures > 0 {
        return Err("仓库或配置请求未完成，请检查代理后重试".into());
    }
    Ok(Collection {
        candidates: found,
        warning: if failures > 0 {
            format!("有 {failures} 个请求未完成，已保留本轮结果，可稍后重试")
        } else {
            String::new()
        },
        coverage,
    })
}
pub async fn scan(state: &AppState) -> Result<Value, String> {
    scan_at(
        state,
        "https://api.github.com",
        "https://raw.githubusercontent.com",
    )
    .await
}
async fn scan_at(state: &AppState, api: &str, raw: &str) -> Result<Value, String> {
    let _guard = RUN_LOCK.try_lock().map_err(|_| "源发现正在进行")?;
    let proxy = {
        let _g = STORE_LOCK.lock().map_err(|_| "源发现存储忙")?;
        read(&state.data_dir)?.proxy_url
    };
    let client = strict_client(&proxy)?; // No proxy means no search request is sent.
    RUNNING.store(true, Ordering::Release);
    let _running = RunFlag;
    let result = tokio::time::timeout(Duration::from_secs(105), collect(&client, api, raw))
        .await
        .unwrap_or_else(|_| Err("本轮发现超时，请稍后重试".into()));
    edit(&state.data_dir, |s| {
        s.last_scan = now();
        match result {
            Ok(collection) => {
                let candidates = collection.candidates;
                let ready = candidates.iter().filter(|c| c.status == "ready").count();
                let count = candidates.len();
                for mut c in candidates {
                    let identity = native_identity(&c);
                    let existing = s
                        .candidates
                        .iter()
                        .enumerate()
                        .filter(|(_, old)| {
                            old.id == c.id
                                || identity
                                    .as_ref()
                                    .is_some_and(|api| native_identity(old).as_ref() == Some(api))
                        })
                        // Older scans may have stored an uninstalled mirror before
                        // its installed original. Refresh the durable record first.
                        .min_by_key(|(_, old)| (old.provider_id.is_none(), old.id != c.id))
                        .map(|(index, _)| index);
                    if let Some(index) = existing {
                        let old = &mut s.candidates[index];
                        c.id = old.id.clone();
                        c.provider_id = old.provider_id.clone();
                        c.install_pending = old.install_pending;
                        // An installed record retains its original attribution and
                        // provider id when a mirror exposes the same API later.
                        if old.provider_id.is_some() {
                            c.repository = old.repository.clone();
                            c.config_url = old.config_url.clone();
                            c.key = old.key.clone();
                            c.name = old.name.clone();
                            c.api = old.api.clone();
                        }
                        *old = c;
                    } else {
                        s.candidates.push(c);
                    }
                }
                // Keep installed provenance indefinitely; bound uninstalled candidates.
                trim_candidates(&mut s.candidates);
                s.last_error = collection.warning;
                s.coverage = collection.coverage;
                notice(
                    s,
                    format!("GitHub 发现完成：读取 {} 个仓库、{} 份配置，检查 {count} 个候选，{ready} 个可手动启用", s.coverage.repositories, s.coverage.configurations),
                );
            }
            Err(e) => {
                s.last_error = e;
                s.coverage = Coverage::default();
                notice(s, "GitHub 发现未完成，请查看发现页".into());
            }
        }
    })?;
    drop(_running);
    status(state)
}
pub async fn enable(state: &AppState, id: &str) -> Result<Value, String> {
    let _guard = RUN_LOCK
        .try_lock()
        .map_err(|_| "源发现正在进行，请稍后启用")?;
    let data = {
        let _g = STORE_LOCK.lock().map_err(|_| "源发现存储忙")?;
        read(&state.data_dir)?
    };
    let candidate = data
        .candidates
        .iter()
        .find(|c| c.id == id)
        .ok_or("候选已不存在")?;
    if candidate.status != "ready" {
        return Err("此候选尚未通过校验".into());
    }
    let client = strict_client(&data.proxy_url)?;
    let checked = validate(&client, candidate).await?;
    let provider_id = format!("github-{}", candidate.id);
    // Explicit enable revalidates, then uses the existing provider builder and persistence.
    let provider = tvbox::build_site_provider(
        &provider_id,
        &native_job(candidate),
        &checked,
        Some(state.proxy.clone()),
        Vec::new(),
    )?;
    let persisted = PersistedProvider::Tvbox {
        id: provider_id.clone(),
        name: candidate.name.clone(),
        api: tvbox::normalize_api_url(&candidate.api),
        categories: checked.classes,
        parsers: Vec::new(),
        ext: None,
    };
    // Repeat calls must not overwrite a source the user already installed or edited.
    let already_registered = state.registry.get(&provider_id).is_some();
    if already_registered && !candidate.install_pending {
        return status(state);
    }
    edit(&state.data_dir, |s| {
        if let Some(c) = s.candidates.iter_mut().find(|c| c.id == id) {
            c.provider_id = Some(provider_id.clone());
            c.install_pending = true;
        }
    })?;
    // Persist the disabled state before any source record. An interrupted install
    // may leave a disabled record, but must never become active on the next launch.
    let mut disabled = crate::commands::load_disabled(&state.data_dir);
    if !disabled.contains(&provider_id) {
        disabled.push(provider_id.clone());
    }
    crate::commands::save_disabled(&state.data_dir, &disabled)?;
    tvbox::write_tvbox_meta(
        &state.data_dir,
        &provider_id,
        &tvbox::TvboxSourceMeta {
            source_url: None,
            site_key: candidate.key.clone(),
            site_name: candidate.name.clone(),
            api: tvbox::normalize_api_url(&candidate.api),
            installed_at: now(),
            ..Default::default()
        },
    )?;
    {
        let mut sources = state.third_party.write().map_err(|_| "源列表忙")?;
        // A previous interrupted installation is already safely disabled. Reuse
        // its record; never restore a stale snapshot over unrelated source edits.
        if !sources.iter().any(|p| p.id() == provider_id) {
            sources.push(persisted);
            if let Err(e) = crate::persist::save_persisted(&state.data_dir, &sources) {
                sources.retain(|p| p.id() != provider_id);
                return Err(e);
            }
        }
    }
    let mut aggregate = crate::tvbox_aggregate::load(&state.data_dir);
    if !aggregate.enabled_site_ids.contains(&provider_id) {
        aggregate.enabled_site_ids.push(provider_id.clone());
    }
    aggregate.hidden_site_ids = crate::tvbox_aggregate::derive_hidden(&aggregate.enabled_site_ids);
    crate::tvbox_aggregate::save(&state.data_dir, &aggregate)?;
    // Final durable commit point. Registration happens after all necessary writes.
    let mut disabled = crate::commands::load_disabled(&state.data_dir);
    disabled.retain(|id| id != &provider_id);
    crate::commands::save_disabled(&state.data_dir, &disabled)?;
    if !already_registered {
        state.registry.register(provider);
    }
    state.registry.set_enabled(&provider_id, true);
    crate::commands_provider::touch_providers(state);
    edit(&state.data_dir, |s| {
        if let Some(c) = s.candidates.iter_mut().find(|c| c.id == id) {
            c.install_pending = false;
        }
        notice(s, format!("已启用来自 GitHub 的源：{}", candidate.name))
    })?;
    status(state)
}
pub fn spawn_auto_discovery(state: &Arc<AppState>) {
    if std::env::var("SOURIN_NO_REMOTE_AUTOSTART").ok().as_deref() == Some("1") {
        return;
    }
    let weak = Arc::downgrade(state);
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            let Some(state) = weak.upgrade() else {
                break;
            };
            let due = {
                let Ok(_g) = STORE_LOCK.lock() else {
                    continue;
                };
                read(&state.data_dir)
                    .map(|s| s.automatic && !s.proxy_url.is_empty() && now() - s.last_scan >= 86400)
                    .unwrap_or(false)
            };
            if due {
                let _ = scan(&state).await;
            }
        }
    });
}

#[cfg(test)]
#[path = "source_discovery_coverage_tests.rs"]
mod coverage_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    async fn fixture() -> Arc<AppState> {
        let dir = std::env::temp_dir().join(format!(
            "sourin-discovery-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("remote-pref.json"), r#"{"auto_start":false}"#).unwrap();
        AppState::bootstrap(dir).await.unwrap()
    }
    async fn fake_proxy() -> (
        String,
        Arc<Mutex<Vec<String>>>,
        Arc<AtomicBool>,
        tokio::task::JoinHandle<()>,
    ) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let hits = Arc::new(Mutex::new(vec![]));
        let healthy = Arc::new(AtomicBool::new(true));
        let requests = hits.clone();
        let state = healthy.clone();
        let server = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let hits = requests.clone();
                let healthy = state.clone();
                tokio::spawn(async move {
                    let mut bytes = vec![0; 16384];
                    let n = socket.read(&mut bytes).await.unwrap();
                    let request = String::from_utf8_lossy(&bytes[..n]);
                    let target = request
                        .lines()
                        .next()
                        .unwrap_or("")
                        .split_whitespace()
                        .nth(1)
                        .unwrap_or("")
                        .to_string();
                    hits.lock().unwrap().push(target.clone());
                    let (status, body) = if target.contains("/search/repositories") {
                        (
                            200,
                            json!({"items":[{"full_name":"fixture/public-config","default_branch":"main"}]}),
                        )
                    } else if target.contains("/git/trees/") {
                        (
                            200,
                            json!({"tree":[{"path":"config.json","type":"blob","size":300}]}),
                        )
                    } else if target.ends_with("config.json") {
                        (
                            200,
                            json!({"sites":[
                                {"key":"native","name":"Synthetic catalog","type":1,"api":"http://content.invalid/api"},
                                {"key":"script","name":"Synthetic script","type":3,"api":"csp_Synthetic"}
                            ]}),
                        )
                    } else if target.contains("content.invalid") && healthy.load(Ordering::SeqCst) {
                        (
                            200,
                            json!({"class":[{"type_id":"1","type_name":"Examples"}],"list":[{"vod_id":"1","vod_name":"Example"}],"total":1}),
                        )
                    } else {
                        (503, json!({"error":"fixture unavailable"}))
                    };
                    let body = body.to_string();
                    let response = format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len());
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });
        (url, hits, healthy, server)
    }
    #[tokio::test]
    async fn discovery_requires_proxy_and_never_enables_automatically() {
        let state = fixture().await;
        let before = state.registry.manifests().len();
        assert!(
            scan_at(&state, "http://github.invalid", "http://raw.invalid")
                .await
                .is_err()
        );
        assert_eq!(state.registry.manifests().len(), before);
        let (proxy, hits, _, server) = fake_proxy().await;
        configure(&state, &proxy, true).unwrap();
        let response = scan_at(&state, "http://github.invalid", "http://raw.invalid")
            .await
            .unwrap();
        assert_eq!(response["candidates"].as_array().unwrap().len(), 2);
        assert_eq!(response["candidates"][0]["status"], "ready");
        assert_eq!(response["candidates"][1]["status"], "unsupported");
        assert_eq!(state.registry.manifests().len(), before);
        let targets = hits.lock().unwrap();
        assert_eq!(targets.len(), 7);
        assert!(targets.iter().all(|s| s.starts_with("http://")));
        assert!(targets.iter().any(|s| s.contains("raw.invalid")));
        assert_eq!(
            targets
                .iter()
                .filter(|s| s.contains("content.invalid"))
                .count(),
            2
        );
        drop(targets);
        let saved = read(&state.data_dir).unwrap();
        assert!(saved.automatic && saved.notices[0].unread);
        assert_eq!(saved.candidates[0].provider_id, None);
        mark_read(&state).unwrap();
        assert!(!read(&state.data_dir).unwrap().notices[0].unread);
        server.abort();
    }
    #[tokio::test]
    async fn manual_enable_revalidates_and_persists_github_origin() {
        let state = fixture().await;
        let (proxy, hits, healthy, server) = fake_proxy().await;
        configure(&state, &proxy, false).unwrap();
        scan_at(&state, "http://github.invalid", "http://raw.invalid")
            .await
            .unwrap();
        let candidates = read(&state.data_dir).unwrap().candidates;
        let ready = &candidates[0];
        assert!(enable(&state, &candidates[1].id).await.is_err());
        healthy.store(false, Ordering::SeqCst);
        assert!(enable(&state, &ready.id).await.is_err());
        assert!(!state
            .registry
            .manifests()
            .iter()
            .any(|m| m.id.starts_with("github-")));
        healthy.store(true, Ordering::SeqCst);
        let before = hits.lock().unwrap().len();
        enable(&state, &ready.id).await.unwrap();
        assert_eq!(hits.lock().unwrap().len(), before + 2);
        let saved = read(&state.data_dir).unwrap();
        let id = saved.candidates[0].provider_id.as_ref().unwrap();
        assert!(state
            .registry
            .enabled_manifests()
            .iter()
            .any(|m| &m.id == id));
        assert!(crate::persist::load_persisted(&state.data_dir)
            .iter()
            .any(|p| p.id() == id));
        assert_eq!(saved.candidates[0].repository, "fixture/public-config");
        assert!(crate::tvbox_aggregate::load(&state.data_dir)
            .enabled_site_ids
            .contains(id));
        // The general updater has no raw GitHub URL to fetch outside this boundary.
        assert!(tvbox::read_tvbox_meta(&state.data_dir, id)
            .unwrap()
            .source_url
            .is_none());
        enable(&state, &ready.id).await.unwrap();
        assert_eq!(
            state
                .registry
                .manifests()
                .iter()
                .filter(|m| &m.id == id)
                .count(),
            1
        );
        crate::commands_provider::remove_provider(&state, id).unwrap();
        assert_eq!(status(&state).unwrap()["candidates"][0]["installed"], false);
        assert_eq!(
            read(&state.data_dir).unwrap().candidates[0]
                .provider_id
                .as_ref(),
            Some(id)
        );
        enable(&state, &ready.id).await.unwrap();
        assert_eq!(status(&state).unwrap()["candidates"][0]["installed"], true);
        server.abort();
    }
    #[tokio::test]
    async fn unavailable_proxy_has_no_direct_fallback_even_for_no_proxy_hosts() {
        let origin = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = format!("http://{}/", origin.local_addr().unwrap());
        let requests = Arc::new(AtomicUsize::new(0));
        let calls = requests.clone();
        let server = tokio::spawn(async move {
            while let Ok((mut stream, _)) = origin.accept().await {
                calls.fetch_add(1, Ordering::SeqCst);
                let _ = stream
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                    .await;
            }
        });
        let unused = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy = format!("http://{}", unused.local_addr().unwrap());
        drop(unused);
        let client = strict_client(&proxy).unwrap();
        assert!(client.get(target).send().await.is_err());
        assert_eq!(requests.load(Ordering::SeqCst), 0);
        server.abort();
    }
    #[test]
    fn proxy_and_destination_validation_do_not_accept_credentials_or_local_targets() {
        assert!(strict_client("").is_err());
        assert!(strict_client("direct://localhost").is_err());
        assert!(strict_client("http://user:pass@localhost:8000").is_err());
        assert!(proxy_url("socks5://127.0.0.1:1080")
            .unwrap()
            .starts_with("socks5h://"));
        for u in [
            "http://127.0.0.1/api",
            "http://10.0.0.1/api",
            "http://[::1]/api",
            "file:///config",
            "http://localhost/config",
        ] {
            assert!(!public_url(&reqwest::Url::parse(u).unwrap()));
        }
    }
    #[tokio::test]
    async fn validation_uses_the_installed_native_url_semantics() {
        let (proxy, hits, _, server) = fake_proxy().await;
        let c = Candidate {
            api: "http://content.invalid/api/?ac=list&unused=value#fragment".into(),
            kind: Some(1),
            ..Default::default()
        };
        validate(&strict_client(&proxy).unwrap(), &c).await.unwrap();
        assert_eq!(
            *hits.lock().unwrap(),
            vec![
                "http://content.invalid/api?ac=list",
                "http://content.invalid/api?ac=videolist&pg=1"
            ]
        );
        server.abort();
    }
    #[tokio::test]
    async fn failed_install_stays_disabled_across_bootstrap_and_can_retry() {
        let state = fixture().await;
        let (proxy, _, _, server) = fake_proxy().await;
        configure(&state, &proxy, false).unwrap();
        scan_at(&state, "http://github.invalid", "http://raw.invalid")
            .await
            .unwrap();
        let candidate = read(&state.data_dir).unwrap().candidates[0].clone();
        let id = format!("github-{}", candidate.id);
        let aggregate_path = state.data_dir.join("tvbox-aggregate.json");
        if aggregate_path.is_file() {
            std::fs::remove_file(&aggregate_path).unwrap();
        }
        std::fs::create_dir(&aggregate_path).unwrap();
        assert!(enable(&state, &candidate.id).await.is_err());
        assert!(crate::commands::load_disabled(&state.data_dir).contains(&id));
        assert!(state.registry.get(&id).is_none());
        let restored = AppState::bootstrap(state.data_dir.clone()).await.unwrap();
        assert!(!restored
            .registry
            .enabled_manifests()
            .iter()
            .any(|m| m.id == id));
        assert_eq!(
            status(&restored).unwrap()["candidates"][0]["installed"],
            false
        );
        std::fs::remove_dir(&aggregate_path).unwrap();
        enable(&restored, &candidate.id).await.unwrap();
        assert_eq!(
            status(&restored).unwrap()["candidates"][0]["installed"],
            true
        );
        assert!(restored
            .registry
            .enabled_manifests()
            .iter()
            .any(|m| m.id == id));
        server.abort();
    }
    async fn fixed_proxy(response: String) -> (String, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let mut buf = vec![0; 16384];
                let _ = socket.read(&mut buf).await;
                let _ = socket.write_all(response.as_bytes()).await;
            }
        });
        (url, task)
    }
    #[tokio::test]
    async fn rejects_empty_items_null_category_and_oversized_or_private_redirect_responses() {
        for body in [
            json!({"class":[{"type_id":null,"type_name":"Empty"}],"list":[{"vod_id":"1","vod_name":"Example"}]}),
            json!({"class":[{"type_id":"1","type_name":"Example"}],"list":[{}]}),
        ] {
            let body = body.to_string();
            let (proxy, server) = fixed_proxy(format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            ))
            .await;
            let c = Candidate {
                api: "http://content.invalid/api".into(),
                kind: Some(1),
                ..Default::default()
            };
            assert!(validate(&strict_client(&proxy).unwrap(), &c).await.is_err());
            server.abort();
        }
        for response in [
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/private\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string(),
            format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", MAX_BYTES+1)
        ] {
            let (proxy, server) = fixed_proxy(response).await;
            assert!(text(&strict_client(&proxy).unwrap(), "http://content.invalid/api").await.is_err());
            server.abort();
        }
    }
    #[test]
    fn retains_newest_candidates_and_installed_origin() {
        let mut candidates = vec![Candidate {
            id: "installed".into(),
            provider_id: Some("source".into()),
            ..Default::default()
        }];
        candidates.extend((1..=205).map(|i| Candidate {
            id: i.to_string(),
            checked_at: i,
            ..Default::default()
        }));
        trim_candidates(&mut candidates);
        assert_eq!(candidates.len(), 201);
        assert_eq!(candidates[0].id, "205");
        assert!(!candidates.iter().any(|c| c.id == "5"));
        assert!(candidates.iter().any(|c| c.id == "installed"));
    }
}
