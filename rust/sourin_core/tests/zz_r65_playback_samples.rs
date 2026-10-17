// ═══════════════════════════════════════════════════════════════════════
//  第 65 轮 · 第 8 条：不可播样本集取证（真实插件 + 真实网络）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个测试是干什么的
//
// Owner 第 8 条原话（语义）：有些源的有些视频不能播放、有些能播，
// 不确定是谁的问题。Owner 补充：「大概是属于软件或者插件的问题，这个要修复」。
//
// 计划 `docs/notes/plan-round-65.md` 的「第 8 条专项」把失败分成六类
// （A 宿主解码 / B 宿主代理取流 / C 宿主分P路由 / D 插件解析 /
//   E 源站权限 / F 源站限流）。
//
// ⚠️ 归类**必须来自真实读数**，不能靠猜。本测试就是那台仪器：
// 它拿真实插件、对真实源发真实请求，把**每一层的原始返回**打出来，
// 让人按读数归类，而不是先假定「是软件问题」再去改代码。
//
// # 为什么不放在 `cargo test` 的默认路径里
//
// ```text
// ① 需要真实网络 + 可用源（与 batch3_search 同一条理由）
// ② 会打真实站点的接口（只读 GET，不写任何东西）
// ⇒ 标 `#[ignore]`，显式 `--ignored` 运行。
// ```
//
// # 用什么数据目录
//
// `R65_DATA_DIR` 环境变量；缺省用仓库内 `.probe/round65-c/devdata`
// （`tools/seed_dev_data.ps1` 播种出来的**隔离副本**）。
// ★ 绝不碰 `%APPDATA%\app.sourin.player`（用户真实库）。
//
// # 跑法
//
// ```text
// cargo test --test zz_r65_playback_samples -- --ignored --nocapture
// ```

use sourin_core::model::PlayRequest;
use sourin_core::state::AppState;
use std::sync::Arc;

/// 隔离数据目录（缺省 = 仓库内播种副本）
fn data_dir() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("R65_DATA_DIR") {
        return std::path::PathBuf::from(p);
    }
    // 测试的 cwd 是 crate 根（rust/sourin_core）⇒ 往上两层是仓库根
    let crate_root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repo = crate_root
        .parent()
        .and_then(|p| p.parent())
        .expect("仓库根")
        .to_path_buf();
    repo.join(".probe").join("round65-c").join("devdata")
}

async fn state() -> Arc<AppState> {
    let dir = data_dir();
    assert!(
        dir.join("dsh-media.db").exists(),
        "隔离数据目录不存在或没播种: {} —— 先跑 tools/seed_dev_data.ps1",
        dir.display()
    );
    AppState::bootstrap(dir).await.expect("bootstrap")
}

/// 一条样本的原始读数（全部来自真实调用）
#[derive(Debug)]
struct Sample {
    provider: String,
    id: String,
    episode_id: Option<String>,
    /// ① 详情层：能不能拿到剧集
    detail_ok: bool,
    detail_err: String,
    /// ② 取流层：原始返回
    resolve_ok: bool,
    resolve_err: String,
    candidates: Vec<CandRead>,
}

#[derive(Debug)]
struct CandRead {
    url: String,
    kind: String,
    quality: Option<String>,
    drm: bool,
    needs_host_resolve: bool,
    headers: Vec<(String, String)>,
    not_web_ready: bool,
    audio_url: Option<String>,
    /// 抓一次候选地址的真实读数 —— **B 类（代理/取流链路）的判据**
    fetch: Option<FetchRead>,
    /// 上游真实地址的编解码读数 —— **A 类（解码能力）的判据**
    probe: Option<ProbeRead>,
}

/// 抓一次候选地址的读数 —— B 类的判据就在这几个数里
#[derive(Debug, Default)]
struct FetchRead {
    status: u16,
    bytes: usize,
    content_type: String,
    head_hex: String,
    err: String,
}

/// ffprobe 的上游读数 —— A 类的判据就在这里
#[derive(Debug, Default)]
struct ProbeRead {
    video_codec: String,
    width: u32,
    height: u32,
    audio_codec: String,
    format_name: String,
    err: String,
}

fn redact(url: &str) -> String {
    // 只保留 scheme+host+path 的头 60 字符，去掉查询串里的签名
    match url.find('?') {
        Some(i) => format!("{}?<{} 字符查询串>", &url[..i], url.len() - i),
        None => url.to_string(),
    }
}

/// 真实抓一次候选地址的前若干字节 —— **B 类（代理/取流链路）的判据**
///
/// # 为什么必须真抓
/// ```text
/// `resolve_stream` 只证明「插件给了地址、代理登记成功」，
/// **不证明代理能把字节转发回来**。B 类缺陷（代理起来了但转发失败）
/// 恰好卡在这两者之间 ⇒ 只有真发一次 HTTP 才能看见。
/// ```
///
/// 判据：
/// ```text
/// 200/206 + 媒体头（ftyp / #EXTM3U / ID3…） ⇒ 链路通
/// 4xx/5xx                                  ⇒ 上游拒绝（E/F）或代理没带上头（B）
/// 连不上（Connection refused）              ⇒ 代理进程没起来（B）
/// ```
async fn fetch_head(url: &str) -> Option<FetchRead> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(25))
        .build()
        .ok()?;
    let mut out = FetchRead::default();
    /*
     * ⚠️ 必须只读前 64KB —— 实测不加 Range 会**把整部片子拉下来**
     *    （某条样本 73,155,961 字节，单条就把这次取证拖到 15 分钟以上）。
     *    判据只需要「状态码 + 头几十字节的容器签名」，不需要正文。
     */
    let req = client
        .get(url)
        .header(reqwest::header::RANGE, "bytes=0-65535");
    match req.send().await {
        Ok(resp) => {
            out.status = resp.status().as_u16();
            out.content_type = resp
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            let mut buf: Vec<u8> = Vec::with_capacity(4096);
            let mut stream_err = String::new();
            let mut s = resp;
            loop {
                if buf.len() >= 4096 {
                    break;
                }
                match s.chunk().await {
                    Ok(Some(c)) => {
                        let take = c.len().min(4096 - buf.len());
                        buf.extend_from_slice(&c[..take]);
                        if take < c.len() {
                            break;
                        }
                    }
                    Ok(None) => break,
                    Err(e) => {
                        stream_err = format!("读正文失败: {e}");
                        break;
                    }
                }
            }
            out.bytes = buf.len();
            let n = buf.len().min(16);
            out.head_hex = buf[..n]
                .iter()
                .map(|x| format!("{x:02x}"))
                .collect::<Vec<_>>()
                .join(" ");
            let txt: String = buf[..buf.len().min(48)]
                .iter()
                .map(|&x| if (32..127).contains(&x) { x as char } else { '.' })
                .collect();
            out.content_type = format!("{ct} | {txt}", ct = out.content_type);
            if !stream_err.is_empty() {
                out.err = stream_err;
            }
        }
        Err(e) => out.err = format!("{e}"),
    }
    Some(out)
}

/// 跑一个命令并**强制超时**（超时就 kill，绝不阻塞取证）
///
/// # 为什么必须自己实现
/// ```text
/// ffprobe 打一个响应很慢的上游时**会一直等**（实测某条样本卡了 10 分钟以上，
/// 直接把整次取证拖死）。std::process::Command::output() 没有超时参数，
/// 而为了一个取证工具引入新依赖不值得 ⇒ 自己 try_wait 轮询。
/// ```
fn run_with_timeout(mut cmd: std::process::Command, secs: u64) -> (String, String, bool) {
    use std::io::Read;
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return (String::new(), format!("spawn 失败: {e}"), false),
    };
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if start.elapsed() > std::time::Duration::from_secs(secs) {
                    let _ = child.kill();
                    let _ = child.wait();
                    return (String::new(), format!("超时 {secs}s（已 kill）"), true);
                }
                std::thread::sleep(std::time::Duration::from_millis(120));
            }
            Err(e) => return (String::new(), format!("wait 失败: {e}"), false),
        }
    }
    let mut so = String::new();
    let mut se = String::new();
    if let Some(mut s) = child.stdout.take() {
        let _ = s.read_to_string(&mut so);
    }
    if let Some(mut s) = child.stderr.take() {
        let _ = s.read_to_string(&mut se);
    }
    (so, se, false)
}

/// 用 ffprobe 读上游真址的编解码 —— **A 类（宿主解码能力）的判据**
///
/// # 判据
/// ```text
/// hevc / av1 / vp9        ⇒ A 类候选（libmpv 软解可能不足，取决于构建）
/// h264 + aac              ⇒ 宿主应当能解
/// probe 失败（4xx/超时）   ⇒ 归到 E/F，不是 A
/// ```
async fn probe_upstream(proxy_url: &str, headers: &[(String, String)]) -> Option<ProbeRead> {
    let hdr_arg = if headers.is_empty() {
        None
    } else {
        let h = headers
            .iter()
            .map(|(k, v)| format!("{k}: {v}"))
            .collect::<Vec<_>>()
            .join("\r\n");
        Some(format!("{h}\r\n"))
    };

    let mut p = ProbeRead::default();

    // ① 视频轨 + 容器
    let mut cmd = std::process::Command::new("ffprobe");
    cmd.args([
        "-v",
        "error",
        "-rw_timeout",
        "15000000",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name,width,height",
        "-show_entries",
        "format=format_name",
        "-of",
        "default=noprint_wrappers=1",
    ]);
    if let Some(h) = &hdr_arg {
        cmd.args(["-headers", h]);
    }
    cmd.arg(proxy_url);
    let (so, se, timed_out) = run_with_timeout(cmd, 25);
    if timed_out {
        p.err = se;
        return Some(p);
    }
    for line in so.lines() {
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        match k.trim() {
            "codec_name" if p.video_codec.is_empty() => {
                p.video_codec = v.trim().to_string();
            }
            "width" => p.width = v.trim().parse().unwrap_or(0),
            "height" => p.height = v.trim().parse().unwrap_or(0),
            "format_name" => p.format_name = v.trim().to_string(),
            _ => {}
        }
    }

    // ② 音轨（-select_streams v:0 只给视频）
    let mut acmd = std::process::Command::new("ffprobe");
    acmd.args([
        "-v",
        "error",
        "-rw_timeout",
        "15000000",
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=codec_name",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
    ]);
    if let Some(h) = &hdr_arg {
        acmd.args(["-headers", h]);
    }
    acmd.arg(proxy_url);
    let (aso, _ase, _t) = run_with_timeout(acmd, 20);
    p.audio_codec = aso.trim().to_string();

    if p.video_codec.is_empty() && !se.trim().is_empty() {
        p.err = se.lines().last().unwrap_or("").to_string();
    }
    Some(p)
}

/// ★★★ 主取证：对每个源的真实首页/搜索条目取流，逐条打印读数
///
/// 判据（写死在这里，供归类时对照）：
/// ```text
/// detail_err 非空            → 连详情都拿不到（多为 D/E）
/// resolve_err 非空           → 取流抛错（D 插件解析 / E 权限 / F 限流）
/// candidates 为空            → 源没给可播地址（D）
/// url 为空 / 非 http(s)      → D 插件解析错
/// needs_host_resolve = true  → 宿主还没实现解析（C/D 的边界）
/// drm = true                 → E（内容方限制，不是缺陷）
/// ```
#[tokio::test]
#[ignore = "需要真实网络与可用源，显式 --ignored 运行"]
async fn collect_unplayable_samples() {
    let st = state().await;
    let manifests = st.registry.manifests();
    println!("\n═══ 已加载源: {} 个 ═══", manifests.len());
    for m in &manifests {
        println!("  · {} ({})", m.id, m.name);
    }

    // 取前若干个启用的源做样本（全量太慢，且判据与源数无关）
    let limit: usize = std::env::var("R65_LIMIT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(6);

    let mut samples: Vec<Sample> = Vec::new();

    for m in manifests.iter().take(limit) {
        println!("\n─── 源 {} ({}) ───", m.id, m.name);

        // ① 分类 ⇒ 列表（最稳的入口：多数源都有分类）
        let mut items: Vec<sourin_core::model::MediaItem> = Vec::new();
        match sourin_core::home::get_categories(&st, &m.id).await {
            Ok(cats) => {
                println!("  categories → {} 个", cats.len());
                if let Some(c0) = cats.first() {
                    match sourin_core::home::get_list(&st, &m.id, &c0.id, 1).await {
                        Ok(pg) => {
                            println!("  list({}) → {} 条", c0.id, pg.items.len());
                            items = pg.items;
                        }
                        Err(e) => println!("  list({}) ✗ {e}", c0.id),
                    }
                }
            }
            Err(e) => println!("  categories ✗ {e}"),
        }
        // ② 列表空 ⇒ 退到跨源搜索，只留本源那部分
        if items.is_empty() {
            match sourin_core::commands::search_all(&st, "电影", 1).await {
                Ok(r) => {
                    for (pid, _pname, pg) in r.results {
                        if pid == m.id {
                            println!("  search 兜底 → {} 条（本源）", pg.items.len());
                            items = pg.items;
                        }
                    }
                    for (pid, why) in r.skipped {
                        if pid == m.id {
                            println!("  search 跳过本源：{why}");
                        }
                    }
                }
                Err(e) => println!("  search ✗ {e}"),
            }
        }

        // 每个源最多取 3 个条目做样本
        for it in items.iter().take(3) {
            let mut s = Sample {
                provider: m.id.clone(),
                id: it.id.native.clone(),
                episode_id: None,
                detail_ok: false,
                detail_err: String::new(),
                resolve_ok: false,
                resolve_err: String::new(),
                candidates: Vec::new(),
            };
            println!("  ▸ 条目 {} «{}»", it.id.native, it.title);

            // ③ 详情 ⇒ 剧集
            let mut ep_id: Option<String> = None;
            match sourin_core::playback::get_detail(&st, &m.id, &it.id.native).await {
                Ok(d) => {
                    s.detail_ok = true;
                    println!("    detail ✓ 剧集 {} 条 · 源 {} 个", d.episodes.len(), d.sources.len());
                    ep_id = d.episodes.first().map(|e| e.id.clone());
                    if let Some(e) = d.episodes.first() {
                        println!("    首集 id={} title={}", e.id, e.title);
                    }
                }
                Err(e) => {
                    s.detail_err = e.clone();
                    println!("    detail ✗ {e}");
                }
            }
            s.episode_id = ep_id.clone();

            // ④ 取流
            let req = ep_id
                .as_ref()
                .map(|id| PlayRequest {
                    source_code: Some(String::new()),
                    episode_id: Some(id.clone()),
                    quality: None,
                })
                .unwrap_or_default();
            match sourin_core::playback::resolve_stream(
                &st,
                &m.id,
                &it.id.native,
                Some(req),
            )
            .await
            {
                Ok(list) => {
                    s.resolve_ok = true;
                    println!("    resolve ✓ {} 条候选", list.len());
                    for (i, c) in list.iter().enumerate() {
                        println!(
                            "      [{}] kind={:?} quality={:?} drm={} nhr={} nwr={} hdrs={:?}",
                            i,
                            c.kind,
                            c.quality,
                            c.drm_protected,
                            c.needs_host_resolve,
                            c.not_web_ready,
                            c.headers.iter().map(|(k, _)| k.clone()).collect::<Vec<_>>()
                        );
                        println!("          url={}", redact(&c.url));
                        if let Some(a) = &c.audio_url {
                            println!("          audio={}", redact(a));
                        }
                        // ⑤ 真实抓一次（B 类判据）：代理是否真的转发成功
                        let fetch = fetch_head(&c.url).await;
                        match &fetch {
                            Some(f) if f.err.is_empty() => println!(
                                "          fetch → status={} bytes={} ct={} head={}",
                                f.status, f.bytes, f.content_type, f.head_hex
                            ),
                            Some(f) => println!("          fetch ✗ {}", f.err),
                            None => println!("          fetch 跳过"),
                        }
                        // ⑥ ffprobe 上游真址（A 类判据）：解不了的是什么编码
                        let probe = probe_upstream(&c.url, &c.headers).await;
                        match &probe {
                            Some(p) if p.err.is_empty() => println!(
                                "          probe → {} {}x{} audio={} container={}",
                                p.video_codec, p.width, p.height, p.audio_codec, p.format_name
                            ),
                            Some(p) => println!("          probe ✗ {}", p.err),
                            None => println!("          probe 跳过"),
                        }
                        s.candidates.push(CandRead {
                            url: c.url.clone(),
                            kind: format!("{:?}", c.kind),
                            quality: c.quality.clone(),
                            drm: c.drm_protected,
                            needs_host_resolve: c.needs_host_resolve,
                            headers: c.headers.clone(),
                            not_web_ready: c.not_web_ready,
                            audio_url: c.audio_url.clone(),
                            fetch,
                            probe,
                        });
                    }
                }
                Err(e) => {
                    s.resolve_err = e.clone();
                    println!("    resolve ✗ {e}");
                }
            }
            samples.push(s);
        }
    }

    // ── 归类汇总（纯读数，不做判断）──
    println!("\n\n══════════ 归类汇总 ══════════");
    let mut a = 0; // 有候选、非 DRM、非 nhr ⇒ 宿主应能播（解码问题要到播放器才知道）
    let mut b = 0; // 有候选且走代理（nwr+hdrs）
    let mut c = 0; // 有候选但 nhr=true（宿主未解析）
    let mut d = 0; // resolve 失败 / 无候选 / url 非法
    let mut e = 0; // DRM
    let mut f = 0; // 网络类错误
    for s in &samples {
        let kind = if !s.resolve_ok || s.candidates.is_empty() {
            if s.resolve_err.contains("超时")
                || s.resolve_err.contains("timeout")
                || s.resolve_err.contains("502")
                || s.resolve_err.contains("503")
                || s.resolve_err.contains("504")
            {
                f += 1;
                "F 源站限流/临时故障"
            } else {
                d += 1;
                "D 插件解析错"
            }
        } else if s.candidates.iter().all(|c| c.drm) {
            e += 1;
            "E 源站权限/DRM"
        } else if s.candidates.iter().all(|c| c.needs_host_resolve) {
            c += 1;
            "C/D 需宿主解析"
        } else if s.candidates.iter().any(|c| c.not_web_ready && !c.headers.is_empty()) {
            b += 1;
            "B 走本地代理"
        } else {
            a += 1;
            "A 直连（解码能力待验）"
        };
        println!(
            "  {} / {} → {}（detail_ok={} resolve_ok={} 候选={}）",
            s.provider,
            s.id,
            kind,
            s.detail_ok,
            s.resolve_ok,
            s.candidates.len()
        );
    }
    println!(
        "\n  计数：A={a} B={b} C={c} D={d} E={e} F={f}  样本总数={}",
        samples.len()
    );
    println!("\n★ 读数只做归类，不预设结论 —— 归类表由人按上面的原始读数填。");
}
