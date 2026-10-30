// ═══════════════════════════════════════════════════════════════════════
//  crate 级共享的**文件日志直写器**（2026-10-30，lead 批准的方案 A）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有它（23018 猎捕二轮的观测黑洞，行号级取证）
//
// ```text
// 本 crate 从未初始化 logger（streamproxy.rs:76/2179、state.rs:813 三处审计：
// grep set_logger → 0 处）⇒ `log::warn!/info!` 在 DLL 里被**整个静默丢弃**。
// 而 logs\sourin-*.log 由三个各自为政的直写器负责（Dart AppLog、
// pan_login::write_log、streamproxy::write_sp_log_file），没有 FFI log 桥。
// ⇒ playback.rs 的 resolve 失败、pan_drive.rs 的降级 warn 全都落不进文件，
//   真机排障时"连失败日志都没有"。
// ⇒ 本助手提供 crate 级唯一入口：调用方给 tag（PLAY/PAN/…），这里负责
//   「按天文件 + 时间戳 + [tag] 前缀」的直写惯例。
// ```
//
// # 形态逐字复用 pan_login.rs:211-248 的直写惯例
//
// ```text
// SOURIN_LOG_FILE 覆盖 → in_test_process 早退 → %APPDATA%\app.sourin.player\logs
//   \sourin-<day>.log append（失败静默 —— 日志不该影响功能）。
// ⚠️ in_test_process 是与 pan_login.rs:205-208 **重复的副本，待统一**——
//    那是 rust-pan 的模块，本轮不动（lead 批准的保守版）。
// ⚠️ 测试进程防护的边界：与 pan_login 同款 —— `cfg!(test)` 只对 lib 内单测生效；
//    集成测试（tests/）须显式设 SOURIN_LOG_FILE 重定向，否则会写真实日志
//    （pan_login.rs:200-204 记过同款教训）。门禁 tests/file_log_gate.rs 全程重定向。
// ```

/// 与 `pan_login.rs:205-208` 同款的测试进程判据（**重复副本，待统一**）
fn in_test_process() -> bool {
    cfg!(test)
        || matches!(std::env::var("FLUTTER_TEST").as_deref(), Ok("true") | Ok("1"))
        || std::env::var("DART_TEST").is_ok()
        || std::env::var("SOURIN_TEST_LOG").is_ok()
}

/// 今天的日志文件路径（SOURIN_LOG_FILE 覆盖优先；测试进程 ⇒ None 不写）
fn log_file_path() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var("SOURIN_LOG_FILE") {
        if !p.trim().is_empty() {
            return Some(std::path::PathBuf::from(p));
        }
    }
    if in_test_process() {
        return None;
    }
    let base = std::env::var("APPDATA").ok()?;
    let day = chrono::Local::now().format("%Y-%m-%d").to_string();
    Some(
        std::path::PathBuf::from(base)
            .join("app.sourin.player")
            .join("logs")
            .join(format!("sourin-{day}.log")),
    )
}

/// 错误消息脱敏：保留"人能看懂哪里错了"的部分，去掉可能带凭据的 URL query 与长串
///
/// # 为什么要它（2026-10-30 真机抽测暴露）
///
/// `resolve 失败 … kind=Other` 这种日志**等于没写** —— 67 条失败全是 `Other`，
/// 一个原因都看不出来。必须记 `e.message`，但 message 里常带分享页 URL / token：
///
/// ```text
/// 原始：解析失败 https://pan.quark.cn/s/abc?pwd=xxxx&token=eyJhbGciOi...
/// 脱敏：解析失败 https://pan.quark.cn/s/abc
/// ```
///
/// # 规则（保守：宁可少记，不可漏记凭据）
///
/// ```text
/// ① 去掉每个 URL 的 `?query` 与 `#fragment`
/// ② 连续 >=40 字符的 [A-Za-z0-9_\-\.=] 长串 → `<redacted>`
///    （JWT / OSS 签名 / md5 token 都在这个形态里）
/// ③ 总长截到 240 字符（够看清原因，不撑爆日志）
/// ```
pub fn scrub_err_msg(raw: &str) -> String {
    // ① 去 URL query / fragment：逐字符扫，遇到 '?' 或 '#' 且当前在 URL 里就跳过直到空白
    let mut no_query = String::with_capacity(raw.len());
    let mut in_url = false;
    let mut skipping = false;
    for ch in raw.chars() {
        if skipping {
            // query 段一直吃到空白或引号
            if ch.is_whitespace() || ch == '"' || ch == '\'' || ch == ')' {
                skipping = false;
                no_query.push(ch);
            }
            continue;
        }
        if !in_url && ch == ':' {
            // 粗略判断：下一个是 '//' 说明进了 URL（本函数只用于日志，不求精确）
            in_url = true;
        }
        if in_url && (ch == '?' || ch == '#') {
            skipping = true;
            continue;
        }
        if ch.is_whitespace() {
            in_url = false;
        }
        no_query.push(ch);
    }

    // ② 长串脱敏：连续 token 字符 >= 40 视为凭据
    let mut out = String::with_capacity(no_query.len());
    let mut run = String::new();
    let is_tok = |c: char| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '=');
    let flush = |run: &mut String, out: &mut String| {
        if run.chars().count() >= 40 {
            out.push_str("<redacted>");
        } else {
            out.push_str(run);
        }
        run.clear();
    };
    for ch in no_query.chars() {
        if is_tok(ch) {
            run.push(ch);
        } else {
            flush(&mut run, &mut out);
            out.push(ch);
        }
    }
    flush(&mut run, &mut out);

    // ③ 截长
    let trimmed: String = out.chars().take(240).collect();
    if trimmed.chars().count() < out.chars().count() {
        format!("{trimmed}…")
    } else {
        trimmed
    }
}

/// 往当天日志文件追加一行 `<ts> [<tag>] <msg>`（失败静默）
///
/// 行格式与 Dart `AppLog`（lib/core/app_log.dart:53-60）逐字同形：
/// `2026-10-04 12:34:56.789 [DL] 完成 a.mp4` —— 两侧落同一个文件，格式必须一致。
/// `tag` 用既有惯例的大写标签（PLAY / PAN / streamproxy …），调用方自选。
pub fn write_file_log(tag: &str, msg: &str) {
    let Some(path) = log_file_path() else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let line = format!(
        "{} [{tag}] {msg}\n",
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f"),
    );
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        use std::io::Write as _;
        let _ = f.write_all(line.as_bytes());
    }
}
