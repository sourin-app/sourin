//! 文件日志直写器的门禁（23018 猎捕二轮·观测黑洞修复，lead 批准方案 A）
//!
//! ```text
//! 背景：本 crate 从未初始化 logger（streamproxy.rs:76/2179）⇒ log::warn/info 全部
//!       被静默丢弃，logs\sourin-*.log 只由三个各自为政的直写器负责。
//! 判据核心：applog::write_file_log（SOURIN_LOG_FILE 覆盖 → 测试早退 → 按天 append），
//!       行格式与 Dart AppLog 逐字同形（"ts [TAG] msg"，app_log.dart:53-60）。
//! 接线断言（源码级，include_str! 先例 tvbox_aggregate.rs:2720）：
//!       playback.rs 的 resolve 失败必须调 write_file_log("PLAY")；
//!       pan_drive.rs 的降级必须调 write_file_log("PAN")。
//! 注入证红：删掉两处 write_file_log 调用 ⇒ 接线断言红（记录见决策笔记）。
//! ⚠️ 全程 SOURIN_LOG_FILE 重定向到临时文件（测试进程写真实日志是 pan_login.rs:200-204
//!    记过的同款教训）。
//! ```
//!
//! 详见 .agents/notes/implemented/bug-fix/2026-10-30-applog-file-log-writer.md

use sourin_core::applog::write_file_log;
use sourin_core::csp::pan_drive::{degrade_pick, DriveEntry, SHARE_PICK_MAX_TRIES};

fn pan_entry(name: &str, size: u64) -> DriveEntry {
    DriveEntry {
        fid: format!("fid-{name}"),
        name: name.to_string(),
        is_dir: false,
        size,
        fid_token: None,
    }
}

const LIMIT_ERR: &str =
    "夸克网盘 取下载地址失败（code=23018）：download file size limit（该文件超出账号单文件下载上限）";

/// 行为门禁：直写两行（PLAY/PAN 各一）+ 降级链真实触发，全部落进重定向文件
///
/// 用**单个**测试跑完全部写断言（SOURIN_LOG_FILE 是进程级环境变量，
/// 并行测试会互相踩；写断言集中在这里串行做）。
#[tokio::test]
async fn write_file_log_lands_in_redirected_file() {
    let dir = std::env::temp_dir().join(format!("sourin_file_log_gate_{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("gate.log");
    let _ = std::fs::remove_file(&path);
    // edition 2021：set_var 安全；单测试串行内设置，结束即清
    std::env::set_var("SOURIN_LOG_FILE", &path);

    // ① 直写两个既有惯例标签
    write_file_log(
        "PLAY",
        "resolve 失败 provider=t GateContent id~=abcd kind=Other needs_login=false",
    );
    write_file_log("PAN", "gate 直写样例");

    // ② 降级链真实触发 ⇒ 必须留 [PAN] 降级行（23018 猎捕二轮现场观测的黑洞）
    let entries = vec![
        pan_entry("老舅_4K原盘.mkv", 40_000_000_000),
        pan_entry("老舅_720P.mp4", 1_500_000_000),
    ];
    let err = degrade_pick(&entries, SHARE_PICK_MAX_TRIES, "夸克", |e| {
        let _name = e.name.clone();
        async move { Err::<(), String>(LIMIT_ERR.to_string()) }
    })
    .await
    .expect_err("全部超限 ⇒ 换线路指引");
    assert!(err.contains("请换一条线路"), "{err}");

    let text = std::fs::read_to_string(&path).expect("重定向文件应已落盘");
    let play_line = text
        .lines()
        .find(|l| l.contains("[PLAY]"))
        .expect("必须有 [PLAY] 行");
    let pan_line = text
        .lines()
        .find(|l| l.contains("[PAN]"))
        .expect("必须有 [PAN] 行");

    // 行格式与 Dart AppLog 同形：`YYYY-MM-DD HH:MM:SS.mmm [TAG] msg`
    assert!(
        play_line.starts_with("2026-") || play_line.starts_with("20"),
        "行首必须是时间戳：{play_line:?}"
    );
    assert!(play_line.contains("resolve 失败"), "{play_line:?}");
    assert!(play_line.contains("kind=Other"), "脱敏字段在：{play_line:?}");
    assert!(pan_line.contains("gate 直写样例"), "{pan_line:?}");

    let degrade_line = text
        .lines()
        .find(|l| l.contains("[PAN] 降级："))
        .unwrap_or_else(|| panic!("降级必须留文件日志：{text}"));
    assert!(
        degrade_line.contains("老舅_4K原盘.mkv") && degrade_line.contains("超出下载上限"),
        "降级行要点名文件与原因：{degrade_line:?}"
    );

    let _ = std::fs::remove_file(&path);
    std::env::remove_var("SOURIN_LOG_FILE");
}

/// 接线断言：两处调用点必须真的调用 write_file_log（防"函数存在但没人用"）
#[test]
fn call_sites_wire_write_file_log() {
    let playback = include_str!("../src/playback.rs").replace("\r\n", "\n");
    let pan_drive = include_str!("../src/csp/pan_drive.rs").replace("\r\n", "\n");

    // playback.rs resolve 失败 → tag "PLAY"
    let seg = playback
        .split("crate::applog::write_file_log(")
        .nth(1)
        .expect("playback.rs 必须调用 write_file_log");
    assert!(
        seg.trim_start().starts_with("\"PLAY\""),
        "resolve 失败的落盘标签必须是 PLAY：{}",
        seg.lines().next().unwrap_or("")
    );

    // pan_drive.rs 降级 → tag "PAN"
    let seg = pan_drive
        .split("crate::applog::write_file_log(")
        .nth(1)
        .expect("pan_drive.rs 降级必须调用 write_file_log");
    assert!(
        seg.trim_start().starts_with("\"PAN\""),
        "降级的落盘标签必须是 PAN：{}",
        seg.lines().next().unwrap_or("")
    );
}

/// 错误消息脱敏门禁（2026-10-30 真机抽测暴露：67 条失败只记 kind=Other，等于没写日志）
///
/// 判据三条，缺一不可：
/// ```text
/// ① URL 的 query/fragment 必须去掉（凭据常在 pwd=/token= 里）
/// ② >=40 字符的连续 token 串必须整体替换成 <redacted>（JWT / OSS 签名 / md5）
/// ③ 正常中文错误消息必须**原样保留**（脱敏不许把诊断价值一起洗掉）
/// ```
/// 注入证红：把 scrub_err_msg 改成恒等函数 ⇒ ①② 必红。
#[test]
fn scrub_err_msg_removes_credentials_keeps_diagnosis() {
    use sourin_core::applog::scrub_err_msg;

    // ① query / fragment 去掉，但 host+path 保留（那是诊断要看的）
    let raw = "解析失败 https://pan.quark.cn/s/abc123?pwd=x9f2&token=abc#frag";
    let got = scrub_err_msg(raw);
    assert!(got.contains("pan.quark.cn/s/abc123"), "host+path 必须保留：{got}");
    assert!(!got.contains("pwd="), "query 必须去掉：{got}");
    assert!(!got.contains("token="), "query 必须去掉：{got}");
    assert!(!got.contains("#frag"), "fragment 必须去掉：{got}");

    // ② 长 token 整体脱敏（OSS 签名 / JWT 那类）
    let raw = "取直链返回 HTTP 400 Signature=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef";
    let got = scrub_err_msg(raw);
    assert!(!got.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"), "长串必须脱敏：{got}");
    assert!(got.contains("<redacted>"), "必须留下脱敏标记（否则看不出这里被处理过）：{got}");
    assert!(got.contains("HTTP 400"), "状态码必须保留（诊断要用）：{got}");

    // ③ 正常中文错误原文逐字保留（不许把诊断价值洗掉）
    let raw = "该分享的文件超出夸克下载上限，请换一条线路（已尝试 1 个候选）";
    assert_eq!(scrub_err_msg(raw), raw, "正常错误文案必须原样保留");

    // ④ 短 token 不误伤（文件名 / 短 id 不该被抹）
    let raw = "找不到子站 csp-4kzhinan-47098b5a::20327";
    assert_eq!(scrub_err_msg(raw), raw, "短标识不该被脱敏");
}