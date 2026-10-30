// ═══════════════════════════════════════════════════════════════════════
//  取证：那条「第33集」的 6 秒流，源站的 m3u8 里到底写了什么
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 要求"不要凭时长猜"。这条把事实拿到：
//   1) 用生产 resolve 路径（resolve_stream）拿到候选的**真实 URL + headers**
//   2) 直接 GET 那个 m3u8，把原始内容打出来
//      （#EXT-X-TARGETDURATION / #EXTINF 条目数 / 每段时长 / 总时长 / 是不是 master→子清单）
//   3) 若是 master 清单，顺着追一层子清单再打
//
// 目的：判断 6 秒是「源站只给了 6 秒的段」还是「段都在但时长声明错了」
//      还是「这是预告/试看」。这三种的修法完全不同，不能靠猜阈值贴标签。
//
// 跑法：
//   cargo test --test live_probe_6s_stream --release -- --ignored --nocapture --test-threads=1

use sourin_core::state::AppState;

async fn real_state() -> std::sync::Arc<AppState> {
    let dir = std::env::var("APPDATA")
        .map(|p| std::path::PathBuf::from(p).join("app.sourin.player"))
        .expect("APPDATA");
    AppState::bootstrap(dir).await.expect("bootstrap")
}

/// 打印一个 m3u8 文本的关键事实
fn dump_playlist(tag: &str, body: &str) {
    let is_master = body.contains("#EXT-X-STREAM-INF");
    println!("---- {tag} ----");
    println!("len_bytes={}", body.len());
    println!("is_master_playlist={is_master}");
    for line in body.lines() {
        let l = line.trim();
        if l.is_empty() {
            continue;
        }
        // 只打关键行：时长声明 + 分片行 + 变体行
        if l.starts_with("#EXT-X-TARGETDURATION")
            | l.starts_with("#EXTINF")
            | l.starts_with("#EXT-X-STREAM-INF")
            | l.starts_with("#EXT-X-MEDIA-SEQUENCE")
            | l.starts_with("#EXT-X-ENDLIST")
            | l.starts_with("#EXT-X-DISCONTINUITY")
            | (!l.starts_with('#'))
    {
            let show: String = l.chars().take(120).collect();
            println!("  |{show}");
        }
    }
    // 汇总：EXTINF 求和
    let mut total = 0f64;
    let mut segs = 0usize;
    for line in body.lines() {
        if let Some(rest) = line.trim().strip_prefix("#EXTINF:") {
            let secs: f64 = rest
                .split(',')
                .next()
                .and_then(|s| s.trim().parse().ok())
                .unwrap_or(0.0);
            total += secs;
            segs += 1;
        }
    }
    println!("SUM extinf_count={segs} total_seconds={total:.3}");
}

#[tokio::test]
#[ignore = "真网取证：需要网络，用 --ignored 显式执行"]
async fn probe_6s_stream() {
    let st = real_state().await;

    // 现场读数里 dur=6 的那条
    const CASES: [(&str, &str); 2] = [
        (
            "tvbox_agg",
            "csp-appyqk-af741cf6::202674", // 「老舅除三害-家庭情感 第33集」dur=6
        ),
        (
            "tvbox_agg",
            "csp-appyqk-af741cf6::338581", // 「老舅 第1集」dur=2
        ),
    ];

    let client = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .expect("client");

    for (provider, id) in CASES {
        println!("\n======== resolve {id} ========");
        let list = match sourin_core::playback::resolve_stream(&st, provider, id, None).await {
            Ok(l) => l,
            Err(e) => {
                println!("RESOLVE_ERR {e}");
                continue;
            }
        };
        println!("candidates={}", list.len());
        for (i, c) in list.iter().enumerate() {
            // URL 脱敏打印（去掉 query 里的签名），但保留 host/path 便于定位
            let shown: String = c.url.split(['?', '#']).next().unwrap_or(&c.url).to_string();
            println!(
                "  cand[{i}] kind={:?} label={:?} quality={:?} url={shown}",
                c.kind, c.label, c.quality
            );
        }
        // 抓第一个候选的清单
        if let Some(first) = list.first() {
            let mut req = client.get(&first.url);
            for (k, v) in &first.headers {
                req = req.header(k.as_str(), v.as_str());
            }
            match req.send().await {
                Ok(resp) => {
                    let status = resp.status();
                    let ct = resp
                        .headers()
                        .get("content-type")
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or("?")
                        .to_string();
                    let body = resp.text().await.unwrap_or_default();
                    println!("FETCH status={status} content-type={ct}");
                    dump_playlist("playlist#0", &body);

                    // 若是 master，追第一个变体
                    if body.contains("#EXT-X-STREAM-INF") {
                        let base = first
                            .url
                            .rsplit_once('/')
                            .map(|(a, _)| a.to_string())
                            .unwrap_or_default();
                        let variant = body
                            .lines()
                            .map(|l| l.trim())
                            .find(|l| !l.is_empty() && !l.starts_with('#'));
                        if let Some(v) = variant {
                            let vurl = if v.starts_with("http") {
                                v.to_string()
                            } else {
                                format!("{base}/{v}")
                            };
                            println!("\n>>> 追子清单 {}", vurl.split(['?', '#']).next().unwrap_or(&vurl));
                            let mut r2 = client.get(&vurl);
                            for (k, val) in &first.headers {
                                r2 = r2.header(k.as_str(), val.as_str());
                            }
                            if let Ok(resp2) = r2.send().await {
                                let b2 = resp2.text().await.unwrap_or_default();
                                dump_playlist("variant#1", &b2);
                            }
                        }
                    }
                }
                Err(e) => println!("FETCH_ERR {e}"),
            }
        }
    }
}
