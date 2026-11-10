// Selected-episode parsing for the configured app protocol.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use super::{AppRJ, CspEpisode, CspPlay, APP_UA};

const PREFIX: &str = "app-rj:v1|";
const MAX_ID: usize = 512 * 1024;
const MAX_BODY: usize = 1024 * 1024;
const MAX_PARSERS: usize = 8;
const TOTAL_BUDGET: std::time::Duration = std::time::Duration::from_secs(15);
const ATTEMPT_BUDGET: std::time::Duration = std::time::Duration::from_secs(5);

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct EpisodeRef {
    pub content: String,
    pub line: String,
    pub code: String,
    pub index: usize,
    pub nid: String,
    pub value: String,
    pub parsers: Vec<String>,
    pub ua: String,
}

struct Line { name: String, code: String, ua: String, parsers: Vec<String>, entries: Vec<(usize, String, String, String)> }

fn lines(d: &Value) -> Vec<Line> {
    let mut out = Vec::new();
    for (number, raw) in d.get("vod_play_list").and_then(Value::as_array).into_iter().flatten().enumerate() {
        let pick = |keys: &[&str]| keys.iter().find_map(|key| raw.get(key).and_then(Value::as_str))
            .unwrap_or("").trim().to_string();
        let mut name = pick(&["name", "title", "flag"]);
        if name.is_empty() { name = format!("线路{}", number + 1); }
        let mut parsers = Vec::new();
        for value in raw.get("parse_urls").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
            let value = value.trim();
            if !value.is_empty() && !parsers.iter().any(|saved| saved == value) { parsers.push(value.to_string()); }
        }
        let mut entries = Vec::new();
        for (index, entry) in raw.get("urls").and_then(Value::as_array).into_iter().flatten().enumerate() {
            let value = entry.get("url").and_then(Value::as_str).unwrap_or("").trim();
            if value.is_empty() { continue; }
            let title = entry.get("name").and_then(Value::as_str).unwrap_or("").trim();
            let title = if title.is_empty() { format!("第{}集", index + 1) } else { title.to_string() };
            let nid = entry.get("nid").map(|v| v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string())).unwrap_or_default();
            entries.push((index, title, value.to_string(), nid));
        }
        if !entries.is_empty() { out.push(Line { name, code: pick(&["flag"]), ua: pick(&["ua"]), parsers, entries }); }
    }
    out
}

pub(super) fn episodes(d: &Value, content: &str) -> Result<Vec<CspEpisode>, String> {
    let mut out = Vec::new();
    for line in lines(d) {
        for (index, title, value, nid) in line.entries {
            let recipe = EpisodeRef { content: content.into(), line: line.name.clone(), code: line.code.clone(),
                index, nid, value, parsers: line.parsers.clone(), ua: line.ua.clone() };
            let bytes = serde_json::to_vec(&recipe).map_err(|_| "无法保存所选剧集信息")?;
            out.push(CspEpisode { id: format!("{PREFIX}{}", crate::csp::app99::b64_encode(&bytes)), title, flag: line.name.clone() });
        }
    }
    Ok(out)
}

pub(super) fn compatibility_lines(d: &Value) -> Vec<(String, Vec<(String, String, String, String)>)> {
    lines(d).into_iter().map(|line| {
        let first = line.parsers.first().cloned().unwrap_or_default();
        (line.name, line.entries.into_iter().map(|(_, name, value, nid)| (name, value, nid, first.clone())).collect())
    }).collect()
}

pub(super) fn structured(id: &str) -> Option<EpisodeRef> {
    if id.len() > MAX_ID { return None; }
    let encoded = id.strip_prefix(PREFIX)?;
    let bytes = crate::csp::app99::b64_decode(encoded).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn reference(id: &str) -> Result<EpisodeRef, String> {
    let recipe = if id.starts_with(PREFIX) {
        structured(id).ok_or("剧集标识形态无效，请重新选择")?
    } else {
        let (content, line, index, nid, parser, value) = super::split_ep_id(id)
            .ok_or("剧集标识形态无效，请重新选择")?;
        EpisodeRef { content, line, code: String::new(), index, nid, value,
            parsers: if parser.is_empty() { Vec::new() } else { vec![parser] }, ua: String::new() }
    };
    if recipe.content.is_empty() || recipe.line.is_empty() || recipe.value.is_empty()
        || recipe.value.len() > MAX_ID || recipe.value.chars().any(char::is_control)
        || recipe.parsers.len() > MAX_PARSERS {
        return Err("剧集播放信息无效，请重新选择".into());
    }
    Ok(recipe)
}

fn http_url(raw: &str) -> bool {
    reqwest::Url::parse(raw).ok().is_some_and(|url| matches!(url.scheme(), "http" | "https")
        && url.host_str().is_some() && url.username().is_empty() && url.password().is_none())
}

fn number(v: &Value, name: &str) -> Option<i64> {
    v.get(name).and_then(|v| v.as_i64().or_else(|| v.as_str()?.parse().ok()))
}

fn access_rejected(v: &Value) -> bool {
    if ["code", "status"].iter().any(|key| matches!(number(v, key), Some(401 | 402 | 403 | 429))) { return true; }
    if ["login_required", "need_login", "vip_required"].iter().any(|key| v.get(key).and_then(Value::as_bool) == Some(true)) { return true; }
    ["msg", "message", "error"].iter().filter_map(|key| v.get(key).and_then(Value::as_str)).any(|text| {
        let text = text.to_ascii_lowercase();
        ["login_required", "vip_required", "platform_not_allowed", "unauthorized", "forbidden", "access denied",
            "请登录", "未登录", "需要登录", "会员权限", "权限不足", "无权限", "访问受限", "请求频繁",
            "需要付费", "购买后", "支付后", "captcha", "验证码", "次数已用完"].iter().any(|term| text.contains(term))
    })
}

fn media(value: &Value, recipe: &EpisodeRef) -> Result<CspPlay, String> {
    if value.get("success").and_then(Value::as_bool) == Some(false)
        || value.get("success").and_then(Value::as_i64) == Some(0)
        || number(value, "code").is_some_and(|code| !matches!(code, 0 | 1 | 200)) {
        return Err("解析接口没有返回成功结果".into());
    }
    let url = value.get("url").or_else(|| value.pointer("/data/url")).and_then(Value::as_str)
        .map(str::trim).filter(|url| http_url(url)).ok_or("解析接口没有返回有效媒体地址")?;
    let path = reqwest::Url::parse(url).unwrap().path().to_ascii_lowercase();
    if path.ends_with(".html") || path.ends_with(".htm") { return Err("解析接口返回了网页地址".into()); }
    let ua = value.get("UA").and_then(Value::as_str).filter(|ua| !ua.trim().is_empty()).unwrap_or(&recipe.ua);
    let ua = if ua.is_empty() { APP_UA } else { ua };
    reqwest::header::HeaderValue::from_str(ua).map_err(|_| "解析接口返回的请求头无效")?;
    Ok(CspPlay { url: url.to_string(), headers: vec![("User-Agent".into(), ua.into())], label: Some(recipe.line.clone()) })
}

impl AppRJ {
    pub(super) async fn resolve_selected(&self, flag: &str, id: &str) -> Result<Vec<CspPlay>, String> {
        let recipe = reference(id)?;
        if !flag.trim().is_empty() && flag.trim() != recipe.line { return Err("剧集与所选线路不一致，请重新选择".into()); }
        if recipe.parsers.is_empty() {
            if !http_url(&recipe.value) { return Err("当前线路没有提供解析接口，请切换线路".into()); }
            let ua = if recipe.ua.is_empty() { APP_UA } else { &recipe.ua };
            reqwest::header::HeaderValue::from_str(ua).map_err(|_| "线路请求头无效")?;
            return Ok(vec![CspPlay { url: recipe.value, headers: vec![("User-Agent".into(), ua.into())], label: Some(recipe.line) }]);
        }
        let client = self.client.client()?;
        let operation = async {
            for parser in &recipe.parsers {
                if !http_url(parser) { continue; }
                let timestamp = super::ts_secs().to_string();
                let encoded = urlencoding::encode(&recipe.value);
                let (url, _) = super::play_request_of(&encoded, parser);
                let url = format!("{url}&sign={}&timestamp={timestamp}", super::sign_of(&timestamp));
                let attempt = async {
                    let mut response = client.get(&url).header(reqwest::header::REFERER, "")
                        .timeout(ATTEMPT_BUDGET).send().await.map_err(|_| "解析请求未完成")?;
                    let status = response.status();
                    if matches!(status.as_u16(), 401 | 402 | 403 | 429) { return Ok::<_, &str>((None, true)); }
                    if !status.is_success() { return Ok((None, false)); }
                    let mut bytes = Vec::new();
                    while let Some(chunk) = response.chunk().await.map_err(|_| "解析响应未完整接收")? {
                        if bytes.len().saturating_add(chunk.len()) > MAX_BODY { return Ok((None, false)); }
                        bytes.extend_from_slice(&chunk);
                    }
                    let parsed: Value = match serde_json::from_slice(&bytes) { Ok(v) => v, Err(_) => return Ok((None, false)) };
                    if access_rejected(&parsed) { return Ok((None, true)); }
                    Ok((media(&parsed, &recipe).ok(), false))
                };
                match tokio::time::timeout(ATTEMPT_BUDGET, attempt).await {
                    Ok(Ok((_, true))) => return Err("当前解析线路需要权限或受到访问限制，请切换来源".into()),
                    Ok(Ok((Some(play), false))) => return Ok(vec![play]),
                    _ => continue,
                }
            }
            Err("配置的解析接口未返回可播放地址，请稍后重试或切换线路".into())
        };
        tokio::time::timeout(TOTAL_BUDGET, operation).await.map_err(|_| "播放解析超时，请稍后重试或切换线路".to_string())?
    }
}
