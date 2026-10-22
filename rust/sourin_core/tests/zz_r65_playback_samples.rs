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

    // 取哪几个源做样本
    //
    // ★ 2026-10-18（轨道 H）：改成**可按 id 精确指定**，因为
    //   「只取前 N 个」会把样本集锁死在字母序靠前的那几个源上 ——
    //   上一轮就是这样：9 条样本里 6 条来自同一个源，
    //   六类归因里 B/C/E/F 一条真实样本都没抓到。
    //   用法：`R65_SOURCES=<id1>,<id2>,<id3>`（逗号分隔的源 id）
    //        不设则退回旧的 `R65_LIMIT`（取前 N 个）
    let pick: Option<Vec<String>> = std::env::var("R65_SOURCES").ok().map(|s| {
        s.split(',')
            .map(|x| x.trim().to_string())
            .filter(|x| !x.is_empty())
            .collect()
    });
    let limit: usize = std::env::var("R65_LIMIT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(6);

    let mut samples: Vec<Sample> = Vec::new();

    let selected: Vec<_> = match &pick {
        Some(ids) => manifests
            .iter()
            .filter(|m| ids.iter().any(|want| want == &m.id))
            .collect(),
        None => manifests.iter().take(limit).collect(),
    };
    println!(
        "\n═══ 本轮取样源: {} 个（{}）═══",
        selected.len(),
        match &pick {
            Some(ids) => format!("R65_SOURCES={}", ids.join(",")),
            None => format!("R65_LIMIT={limit}"),
        }
    );

    for m in selected {
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
                        //
                        // ★ 优化：**已经证明能播的就不用再探**
                        //
                        // # 为什么
                        // ```text
                        // 判据链条是「fetch 拿到 206 + 合法容器签名 ⇒ 这条能播」。
                        // 既然能播，那它就不是 A 类（A = 封装/流结构异常）。
                        // 再花 25~45 秒 ffprobe 一遍，只为一个已知结论 ⇒ 纯浪费，
                        // 上一轮整次取证 385 秒里大半耗在这里（还多次撞 900s 超时）。
                        // ```
                        // ⚠️ 但**失败的要照探** —— 那才是要归类的对象。
                        let already_playable = fetch
                            .as_ref()
                            .map(|f| {
                                (f.status == 200 || f.status == 206)
                                    && looks_like_media(&f.head_hex)
                            })
                            .unwrap_or(false);
                        let probe = if already_playable {
                            println!(
                                "          probe 跳过（fetch 已证明能播，不必再探编码）"
                            );
                            None
                        } else {
                            probe_upstream(&c.url, &c.headers).await
                        };
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

    // ── 归类汇总 ──
    println!("\n\n══════════ 归类汇总 ══════════");
    println!(
        "★ 归类判据 = **真实 HTTP 结果**，不是结构属性。\n  \
         「走了代理」不等于「播不了」；「有 == 206 + 合法容器」就等于**能播**，\n  \
         它既不是缺陷也不是我们的锅 —— 那类样本必须**单独计数**，\n  \
         否则归类表会把大量能播的样本算成缺陷（上一轮就是这么误标 16 条的）。\n"
    );
    let mut ok = 0; // ★ 真能播（206/200 + 合法容器签名）—— 不是缺陷
    let mut a = 0; // 封装修复不了 / 流结构异常（原「解码不足」，解码器实测是齐的）
    let mut b = 0; // 代理链路断（连不上代理 / 代理 5xx 且上游正常）
    let mut c = 0; // 分P/选集路由错
    let mut d = 0; // 插件解析错（resolve 失败 / 无候选 / url 形态不可用）
    let mut e = 0; // 源站会员/地区限制
    let mut f = 0; // 源站限流/临时故障
    for s in &samples {
        let verdict = verdict_of(s);
        match verdict.0 {
            '=' => ok += 1,
            'A' => a += 1,
            'B' => b += 1,
            'C' => c += 1,
            'D' => d += 1,
            'E' => e += 1,
            'F' => f += 1,
            _ => {}
        }
        println!(
            "  {} / {} → {}（detail_ok={} resolve_ok={} 候选={}）  [{}]",
            s.provider,
            s.id,
            verdict.1,
            s.detail_ok,
            s.resolve_ok,
            s.candidates.len(),
            verdict.2,
        );
    }
    println!(
        "\n  计数：★能播={ok} A={a} B={b} C={c} D={d} E={e} F={f}  \
         样本总数={}",
        samples.len()
    );
    println!(
        "\n  ★ 关键分母：**不可播样本 = {}**（能播的 {ok} 条不计入缺陷）",
        samples.len() - ok
    );
    println!("\n★ 读数只做归类，不预设结论 —— 归类表由人按上面的原始读数填。");
}

/// 单条样本的归类 —— **只看真实读数**
///
/// 返回 `(类字符, 人类可读的类别名, 判据一句话)`
///
/// # 为什么必须按 HTTP 结果而不是结构属性
///
/// ```text
/// 上一轮的写法是：
///   "候选里有 not_web_ready && headers 非空 ⇒ 归 B"
/// 实测立刻暴露它的荒谬：
///   154 / 64346  fetch → status=206 bytes=4096 ct=video/mp4
///                head = 00 00 00 18 66 74 79 70 6d 70 34 32   （ftyp-mp42，合法 MP4）
///   这条**明明能播**，却被算成「B 类缺陷」。
/// 32 个源里每个走代理的都会被这么误标 ⇒ 缺陷数虚高，真正的问题被淹掉。
/// ```
///
/// ⇒ 现在的判据顺序（**结果优先，结构靠后**）：
/// ```text
/// ① 抓到 200/206 + 合法容器签名        → = 能播（不是缺陷）
/// ② 代理连不上（Connection refused）    → B
/// ③ 502/503 且 err 提到上游连不上      → F（源站/上游临时故障）
/// ④ 401/403 + 权限词                    → E（源站限制，不绕过）
/// ⑤ 429 / timeout                       → F
/// ⑥ resolve 失败 / 无候选 / url 形态坏  → D（插件解析错）
/// ⑦ 有流但 ffprobe 认不出容器           → A（封装/流结构异常）
/// ⑧ 以上都不是                          → ? （如实标"未归类"，不硬凑）
/// ```
fn verdict_of(s: &Sample) -> (char, &'static str, String) {
    // ① 先找**任何一条**真能取的候选 —— 有一条能播就算能播
    for c in &s.candidates {
        if let Some(fr) = &c.fetch {
            if (fr.status == 200 || fr.status == 206) && looks_like_media(&fr.head_hex) {
                return (
                    '=',
                    "★ 能播（不是缺陷）",
                    format!(
                        "status={} ct={} head={}",
                        fr.status,
                        fr.content_type,
                        fr.head_hex
                    ),
                );
            }
        }
    }

    // ①.5 代理层自己坏了（连接被拒 / 端口死）
    for c in &s.candidates {
        if let Some(fr) = &c.fetch {
            let low = fr.err.to_lowercase();
            if low.contains("connection refused")
                || fr.err.contains("连接被拒绝")
                || fr.err.contains("已失效")
            {
                return (
                    'B',
                    "B 代理链路断",
                    format!("fetch 连不上代理: {}", fr.err),
                );
            }
        }
    }

    // ③ 上游/源站临时故障（502/503/504/timeout/429）
    for c in &s.candidates {
        if let Some(fr) = &c.fetch {
            let st = fr.status;
            if st == 429 || st == 502 || st == 503 || st == 504 {
                return (
                    'F',
                    "F 源站限流/临时故障",
                    format!("fetch status={st} ct={}", fr.content_type),
                );
            }
        }
    }
    if s.resolve_err.contains("超时")
        || s.resolve_err.contains("timeout")
        || s.resolve_err.contains("429")
    {
        return ('F', "F 源站限流/临时故障", format!("resolve: {}", s.resolve_err));
    }

    // ④ 源站权限（E 类：只优化提示，不绕过）
    for c in &s.candidates {
        if let Some(fr) = &c.fetch {
            if fr.status == 401 || fr.status == 403 {
                return (
                    'E',
                    "E 源站会员/地区限制",
                    format!(
                        "fetch status={} ct={} head={}",
                        fr.status, fr.content_type, fr.head_hex
                    ),
                );
            }
        }
    }

    // ⑤ DRM
    if !s.candidates.is_empty() && s.candidates.iter().all(|c| c.drm) {
        return ('E', "E 源站版权/DRM 限制", "全部候选 drm=true".to_string());
    }

    // ⑥ 插件解析错（D）
    if !s.resolve_ok || s.candidates.is_empty() {
        return (
            'D',
            "D 插件解析错",
            format!("resolve_ok={} 候选=0 err={}", s.resolve_ok, s.resolve_err),
        );
    }
    // url 形态本身不可用，也归 D
    for c in &s.candidates {
        if !(c.url.starts_with("http://") || c.url.starts_with("https://")) {
            return (
                'D',
                "D 插件解析错",
                format!("url 不是 http(s): {}", redact(&c.url)),
            );
        }
    }

    // ⑦ 有流但探测认不出容器 ⇒ 封装/流结构异常（A 的新判据）
    for c in &s.candidates {
        if let Some(pr) = &c.probe {
            if pr.video_codec.is_empty() && !pr.err.is_empty() {
                return (
                    'A',
                    "A 封装/流结构异常",
                    format!("ffprobe: {}", pr.err),
                );
            }
        }
    }

    // ⑧ 有候选但一条都没抓到读数 —— 如实标未归类，绝不硬凑
    let any_fetch = s.candidates.iter().any(|c| c.fetch.is_some());
    if !any_fetch {
        return (
            '?',
            "? 未归类（没有 fetch 读数）",
            "所有候选都没抓到 HTTP 读数 —— 取证不足，不是产品结论".to_string(),
        );
    }

    ('?', "? 未归类", "有读数但不符合任何一类判据".to_string())
}

/// 容器/播放列表签名判定 —— 「这条响应到底是不是媒体」
///
/// # 为什么必须看签名而不只看状态码
/// ```text
/// 实测有站点回 200 但正文是 HTML 错误页（防盗链、风控页）。
/// 只看状态码会把它当"能播"，归因就全错了。
/// ```
fn looks_like_media(head_hex: &str) -> bool {
    // 空白（还没读到正文）⇒ 不算证据
    if head_hex.trim().is_empty() {
        return false;
    }
    let bytes: Vec<u8> = head_hex
        .split_whitespace()
        .filter_map(|h| u8::from_str_radix(h, 16).ok())
        .collect();
    if bytes.len() < 4 {
        return false;
    }
    // ① MP4/MOV 族：偏移 4 处是 "ftyp"（或 ftyp/free/moov/mdat/styp）
    if bytes.len() >= 8 && &bytes[4..8] == b"ftyp" {
        return true;
    }
    // ② MPEG-TS：0x47 同步字节
    if bytes[0] == 0x47 {
        return true;
    }
    // ③ FLV
    if bytes.len() >= 3 && &bytes[0..3] == b"FLV" {
        return true;
    }
    // ④ 文本型播放列表 / 分片
    let txt: String = bytes
        .iter()
        .map(|&x| if (32..127).contains(&x) { x as char } else { '.' })
        .collect();
    if txt.contains("#EXTM3U") || txt.contains("#EXTINF") {
        return true;
    }
    // ⑤ WebM/MKV（EBML 头 1A 45 DF A3）
    if bytes.len() >= 4 && bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF {
        return true;
    }
    false
}
