//! Baidu share verification/list preconditions only, not complete-file playback.
//! Official request evidence: .probe/baidu-forensics/initNew-all_98048b2.js
//! and boot_7dd69c6.js. Listing success does not prove account validity.
//! No page URL or limited preview is returned as a playable result.

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

pub async fn resolve(share_id: &str, passcode: &str) -> Result<CspPlay, String> {
    let cookie = crate::pan_auth::load(PanKind::Baidu).map(|c| c.cookie);
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
            return Err(format!("百度分享校验未通过（verify errno={errno}）"));
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
        ("shorturl", share_id.into()),
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
        .get(list_url)
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
        return Err(format!("百度分享列表失败（share/list errno={errno}）"));
    }
    let items = value
        .get("list")
        .and_then(|value| value.as_array())
        .ok_or_else(|| "百度 share/list 未提供文件列表".to_string())?;
    if items.is_empty() {
        return Err("百度分享里没有列出文件（list 为空）".into());
    }
    Err("百度分享文件列表已取得，但本版本仍未接入完整文件取直链 \
        （dlink 请求形状未取证；列表成功不证明账号远端有效）"
        .into())
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
) -> Result<(String, Url), String> {
    for hop in 0..=5 {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(format!("百度 {stage} 请求总预算耗尽"));
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
        let mut response = client
            .execute(next_request)
            .await
            .map_err(|_| format!("百度 {stage} 请求传输失败"))?;
        cookies.observe(response.headers(), response.url());
        if matches!(response.status().as_u16(), 301 | 302 | 303 | 307 | 308) {
            if hop == 5 {
                return Err(format!("百度 {stage} 跳转次数超限"));
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
            return Err(format!(
                "百度 {stage} 返回 HTTP {}",
                response.status().as_u16()
            ));
        }
        let final_url = response.url().clone();
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| format!("百度 {stage} 响应读取失败"))?
        {
            if body.len() + chunk.len() > 2 * 1024 * 1024 {
                return Err(format!("百度 {stage} 响应超过大小限制"));
            }
            body.extend_from_slice(&chunk);
        }
        let body = String::from_utf8(body).map_err(|_| format!("百度 {stage} 响应编码无效"))?;
        return Ok((body, final_url));
    }
    Err(format!("百度 {stage} 跳转次数超限"))
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
    ///            （web 逐字）→ 走到"dlink 未取证"的诚实边界为止。
    #[tokio::test]
    async fn verify_then_list_reaches_honest_wall() {
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
            .expect_err("dlink 未取证 ⇒ 必须停在诚实边界");
        assert!(
            err.contains("仍未接入完整文件取直链") && err.contains("dlink"),
            "要停在 dlink 未取证的如实文案：{err}"
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
        assert!(err.contains("list 为空"), "{err}");
    }
}
