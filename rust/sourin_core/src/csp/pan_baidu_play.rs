// ═══════════════════════════════════════════════════════════════════════
//  百度网盘 分享页 → 已证跳接线（T1b 取流 · 2026-11-01 网盘批次）
// ═══════════════════════════════════════════════════════════════════════
//
// # 本批做到哪一跳（如实，lead 批复的混合方案）
//
// ```text
// 已证（真网逐字，产物 .probe/baidu-forensics/）：
//   verify ：POST /share/verify {t, surl, pwd} → errno=0 → randsk
//            （initNew 逐字：randsk 即 BDCLND cookie = sekey）
//   列表   ：GET /share/list?web=1&root=1&shorturl=<surl>&clienttype=0
//            （hp0 形态）＋ web 形态追加 &is_from_web=true&sekey=<BDCLND>
//            （common-chunks 逐字：{is_from_web:!!sekey, sekey, uk, shareid, web:1,…}）
// 未证（如实标注"未取证"，不编造 —— 115/123 加密形态的先例）：
//   dlink  ：/api/(download|sharedownload) 端点族存在（boot.js 逐字 regex），
//            但**请求参数形状**在登录后懒加载 chunk 里；本轮活链接取证因
//            钥匙串百度凭据**服务端已失效**（探针实证：带 BDUSS 访问分享页
//            渲染出的是登录页）而拿不到 ⇒ dlink 跳不实现，到这里如实停。
// ```
//
// # Owner 要做什么才能闭环
// ```text
// 到【配置中心】重新登录百度网盘（凭据过期是服务端现实），之后批末验收
// 或下一批用活链接补 dlink 取证即可接线 —— 本文件的 verify/list 已就位。
// ```
//
// # 鉴权/纪律
// ```text
// · 凭据走 pan_auth（钥匙串），零硬编码；X-Requested-With / Referer 头
//   与 hp0、web 客户端逐字一致。
// · 归因：非会员限速/直链可用性是内容现实 —— 等接线后按响应如实归因。
// ```

use crate::pan::PanKind;
use super::CspPlay;

/// 端点（可被测试回放替换）
#[derive(Debug, Clone)]
pub struct BaiduEndpoints {
    pub page: String,  // https://pan.baidu.com/s（分享页前缀）
    pub verify: String, // https://pan.baidu.com/share/verify
    pub list: String,  // https://pan.baidu.com/share/list
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

/// 桌面 Chrome UA（hp0 对百度用桌面组 —— T2 逐字）
const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36";

fn short(s: &str) -> String {
    let t: String = s.chars().take(160).collect();
    t
}

/// ★★★ 把百度分享页走到"已证"的最远点（provider.rs 的 resolve 出口钩子用）
///
/// 未登录 ⇒ `Err("NEED_LOGIN:baidu|…")`；登录态被服务端拒绝 ⇒ 如实报"已失效"；
/// 走完 verify/list 之后 ⇒ 如实停在"dlink 未取证"（不假装能播）。
pub async fn resolve(share_id: &str, passcode: &str) -> Result<CspPlay, String> {
    let cookie = crate::pan_auth::load(PanKind::Baidu).map(|c| c.cookie);
    resolve_with(&BaiduEndpoints::default(), cookie.as_deref(), share_id, passcode).await
}

/// 可注入端点 + 可注入凭据的内核（门禁用回放服务直接打）
pub async fn resolve_with(
    ep: &BaiduEndpoints,
    cookie: Option<&str>,
    share_id: &str,
    passcode: &str,
) -> Result<CspPlay, String> {
    let share_id = share_id.trim();
    if share_id.is_empty() {
        return Err("百度分享 id 为空（分享页 URL 解析失败）".to_string());
    }
    let Some(cookie) = cookie else {
        return Err(format!(
            "NEED_LOGIN:{}|还未登录百度网盘账号，请前往【配置中心】登录",
            PanKind::Baidu.code()
        ));
    };
    let client = reqwest::Client::builder()
        .user_agent(UA)
        .timeout(std::time::Duration::from_secs(15))
        .no_proxy()
        .build()
        .expect("HTTP client 构建失败（TLS 后端不可用）");

    // ── ① 登录态活性检查（探针实证的失效形态：分享页渲染出登录页）────────
    let page_url = format!("{}/{}", ep.page.trim_end_matches('/'), share_id);
    let (page_body, _set_cookie_names) = get_with_cookies(&client, &page_url, cookie).await?;
    if page_body.contains("登录百度网盘") || page_body.contains("passLoginType") {
        return Err(format!(
            "NEED_LOGIN:{}|百度登录态已失效，请到【配置中心】重新扫码登录",
            PanKind::Baidu.code()
        ));
    }

    // ── ② verify（有提取码才走；surl 去掉开头的 '1' —— web 逐字惯例）────
    let mut bdclnd = String::new();
    if !passcode.trim().is_empty() {
        let surl = share_id.strip_prefix('1').unwrap_or(share_id);
        let form = format!(
            "t={}&surl={}&pwd={}",
            now_ms(),
            urlencode(surl),
            urlencode(passcode.trim())
        );
        let resp = client
            .post(&ep.verify)
            .header("Cookie", cookie)
            .header("X-Requested-With", "XMLHttpRequest")
            .header("Referer", &page_url)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form)
            .send()
            .await
            .map_err(|e| format!("百度 verify 请求失败：{e}"))?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| format!("读 verify 响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("百度 verify 返回 HTTP {}：{}", status.as_u16(), short(&body)));
        }
        let v: serde_json::Value = serde_json::from_str(&body)
            .map_err(|e| format!("百度 verify 响应不是 JSON（{e}）：{}", short(&body)))?;
        let errno = v.get("errno").and_then(|x| x.as_i64()).unwrap_or(-1);
        if errno != 0 {
            return Err(format!(
                "百度分享校验未通过（verify errno={errno}）—— 提取码可能不对或已失效"
            ));
        }
        // randsk 即 BDCLND（initNew 逐字：localStorage.setItem(surl+'_bdclnd', resp.randsk)）
        bdclnd = v
            .get("randsk")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
    }

    // ── ③ share/list（hp0 形态 + 有 sekey 时追加 web 形态参数）──────────
    let mut list_url = format!(
        "{}?web=1&page=1&num=20&order=time&desc=1&showempty=0&shorturl={}&root=1&clienttype=0",
        ep.list,
        urlencode(share_id)
    );
    if !bdclnd.is_empty() {
        // web 形态逐字：is_from_web=!!sekey + sekey=<BDCLND>
        list_url.push_str(&format!(
            "&is_from_web=true&sekey={}",
            urlencode(&bdclnd)
        ));
    }
    let (body, set_cookie_names) = get_with_cookies(&client, &list_url, cookie).await?;
    let lv: serde_json::Value = serde_json::from_str(&body)
        .map_err(|e| format!("百度 share/list 响应不是 JSON（{e}）：{}", short(&body)))?;
    let errno = lv.get("errno").and_then(|x| x.as_i64()).unwrap_or(-1);
    if errno != 0 {
        return Err(format!(
            "百度分享列表失败（share/list errno={errno}）—— 链接可能已失效{}",
            if set_cookie_names.contains(&"BDCLND".to_string()) {
                "（服务端在响应里重置了 BDCLND）"
            } else {
                ""
            }
        ));
    }
    let items = lv.get("list").and_then(|x| x.as_array()).map(|a| a.len()).unwrap_or(0);
    if items == 0 {
        return Err("百度分享里没有列出文件（list 为空）".to_string());
    }

    // ── ④ dlink 跳：未取证，如实停（115/123 先例；见文件头注释）─────────
    Err(
        "已登录百度网盘：能列出分享里的文件，但本版本仍未接入取直链 \
         （dlink 请求形状未取证，需重新登录后用活链接补一次取证）"
            .to_string(),
    )
}

/// GET 并记录响应 Set-Cookie 的**键名**（值不打印 —— 凭据纪律）
async fn get_with_cookies(
    client: &reqwest::Client,
    url: &str,
    cookie: &str,
) -> Result<(String, Vec<String>), String> {
    let resp = client
        .get(url)
        .header("Cookie", cookie)
        .header("Accept", "text/html,application/json,*/*")
        .header("Referer", "https://pan.baidu.com/")
        .send()
        .await
        .map_err(|e| format!("百度请求失败：{e}"))?;
    let status = resp.status();
    let mut names = Vec::new();
    for h in resp.headers().get_all(reqwest::header::SET_COOKIE).iter() {
        if let Ok(s) = h.to_str() {
            if let Some(first) = s.split(';').next() {
                if let Some(name) = first.split('=').next() {
                    names.push(name.trim().to_string());
                }
            }
        }
    }
    let body = resp.text().await.map_err(|e| format!("读响应失败：{e}"))?;
    if !status.is_success() {
        return Err(format!("百度返回 HTTP {}：{}", status.as_u16(), short(&body)));
    }
    Ok((body, names))
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// query 值转义（与 pan_xunlei_play 同一个最小实现）
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

    fn isolate_keyring() {
        static ONCE: std::sync::OnceLock<()> = std::sync::OnceLock::new();
        ONCE.get_or_init(|| {
            std::env::set_var("SOURIN_KEYRING_SERVICE", "dsh-media-client-pan-test");
        });
    }
    fn clear_credential() {
        isolate_keyring();
        let _ = crate::pan_auth::clear(PanKind::Baidu);
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
        Replay { base: format!("http://127.0.0.1:{port}"), hits }
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
        clear_credential();
        let srv = spawn_replay(Arc::new(Vec::new()));
        let err = resolve_with(&ep_of(&srv), None, "1AbCd", "pwd")
            .await
            .expect_err("未登录必须 Err");
        assert!(err.starts_with("NEED_LOGIN:baidu|"), "{err}");
    }

    /// ★ 门禁 ②：登录态被服务端拒绝（探针实锤形态：分享页渲染登录页）
    ///            ⇒ 如实报"已失效"，引导重登 —— 不硬着头皮走后面的跳。
    ///
    /// 证红：把"登录页检测"分支删掉 ⇒ 本条红（红在"走到了 verify 而不是停"）。
    #[tokio::test]
    async fn login_page_rendered_means_credential_expired() {
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
            .expect_err("登录态失效必须 Err");
        assert!(err.contains("NEED_LOGIN:baidu|") && err.contains("已失效"), "{err}");
        assert!(
            srv.requests().iter().all(|r| !r.target.contains("/share/verify")),
            "登录页都渲染出来了，verify 不该发（白费一次风控暴露）"
        );
    }

    /// ★ 门禁 ③：verify 成功 ⇒ randsk 进 BDCLND → share/list 带 sekey 参数
    ///            （web 逐字）→ 走到"dlink 未取证"的诚实边界为止。
    #[tokio::test]
    async fn verify_then_list_reaches_honest_wall() {
        let routes = Arc::new(vec![
            ("GET".into(), "/s/1AbCd".into(), 200, OK_PAGE.into(), Vec::new()),
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
            err.contains("仍未接入取直链") && err.contains("dlink"),
            "要停在 dlink 未取证的如实文案：{err}"
        );
        let reqs = srv.requests();
        // verify 的参数形状（web 逐字：t/surl/pwd，surl 去掉开头的 '1'）
        let verify = reqs
            .iter()
            .find(|r| r.target.starts_with("/share/verify"))
            .expect("必须有 verify");
        assert!(verify.body.contains("surl=AbCd"), "surl 要去 '1' 前缀：{}", verify.body);
        assert!(verify.body.contains("pwd=pwd99"), "{}", verify.body);
        // list 带 sekey 形态（web 逐字）
        let list = reqs
            .iter()
            .find(|r| r.target.starts_with("/share/list"))
            .expect("必须有 list");
        assert!(list.target.contains("sekey="), "verify 出了 randsk ⇒ list 要带 sekey：{}", list.target);
        assert!(list.target.contains("is_from_web=true"), "{}", list.target);
        assert!(list.cookie_keys.contains(&"BDUSS".to_string()), "登录态要带上");
    }

    /// ★ 门禁 ④：verify 被拒（errno 非 0）⇒ 如实报 errno，不猜语义
    #[tokio::test]
    async fn verify_rejected_is_honest_with_errno() {
        let routes = Arc::new(vec![
            ("GET".into(), "/s/1AbCd".into(), 200, OK_PAGE.into(), Vec::new()),
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
            ("GET".into(), "/s/1NoPwd".into(), 200, OK_PAGE.into(), Vec::new()),
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
