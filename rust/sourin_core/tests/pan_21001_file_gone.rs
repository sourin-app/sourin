//! N-23018 门禁：夸克 21001「file not found」分类 + purge 等待 + 21001 自愈（纯函数级）
//!
//! ```text
//! 真机实锤（sourin-2026-11-01.log）：
//!   14:39:13  file/download → 400 code=23018 file size limit[e2d3230f…]
//!   14:39:40  file/download → 404 {"code":21001,"message":"file not found [e2d3230f…]"}
//! 同 fid 27 秒"在→不在"：上次解析的 purge（file/delete 异步、不等待）把文件删了，
//! save 对同名文件去重回吐刚删的 fid ⇒ 下载 404(21001)。
//! 修复（lead 批复 A+B）：A = purge 等删除任务终态（预算封顶）；B = 下载遇 21001
//! 自愈重转存一次（等旧 fid 从清单消失 → 重新 save → 再下载）。
//! ```
//!
//! # 门禁怎么打（注入证红）
//! ```text
//! · 把 `is_file_not_found_21001` 改成恒 false ⇒ 本文件 ① 组全红
//!   （play 的 21001 终态分支与 degrade_attempt 的自愈分支同时失明）。
//! · 把 degrade_attempt 里的自愈分支删掉 ⇒ ③ 组接线断言红。
//! · 把 purge_previous 里的 wait_delete_task 调用删掉 ⇒ ③ 组 A 接线断言红。
//! · 把 PURGE_DELETE_WAIT_BUDGET 改成 > 5s ⇒ ② 组护栏红（删除确认不许挂住 resolve）。
//! ```

use sourin_core::csp::pan_drive::{
    delete_task_done, is_file_not_found_21001, PAN_POLL_INTERVAL, PURGE_DELETE_WAIT_BUDGET,
    SELFHEAL_LISTING_WAIT,
};

// ── ① 21001 判据（纯函数）────────────────────────────────────────────

/// 真机日志原文（14:39:40，逐字）
const REAL_404_BODY: &str = r#"{"status":404,"code":21001,"message":"file not found [e2d3230f98f54014aeffdaae5967dc32]","req_id":"9f2tu9-2b7a614afce4ec","timestamp":1793515180}"#;

/// 真 23018 的响应体（对照：不许误伤）
const REAL_23018_BODY: &str = r#"{"status":400,"code":23018,"message":"download file size limit[d8edbb119fc447f3bda0bb3f59aa13e1]","req_id":"35db42-2b7a62335968d7","timestamp":1793515299}"#;

#[test]
fn file_not_found_21001_matches_real_body() {
    assert!(is_file_not_found_21001(REAL_404_BODY));
    // play 拼出来的错误串形态（自愈检测吃的就是它；含码 + 含短语）
    assert!(is_file_not_found_21001(
        "夸克网盘 取下载地址返回 HTTP 404 Not Found：{\"code\":21001,\"message\":\"file not found\"}"
    ));
    // Rust 侧终态人话（自愈失败后）也要能认出 —— degrade_attempt 的自愈检测不空转
    assert!(is_file_not_found_21001(
        "夸克网盘 文件已不存在（code=21001 file not found），无法播放，请换一条线路"
    ));
}

#[test]
fn file_not_found_21001_rejects_lookalikes() {
    // 23018（文件在、超限）不许误伤
    assert!(!is_file_not_found_21001(REAL_23018_BODY));
    // 普通网页 404（无业务码）
    assert!(!is_file_not_found_21001("<h1>404 Not Found</h1>"));
    // 只有码没有短语
    assert!(!is_file_not_found_21001(r#"{"code":21001,"message":"ok"}"#));
    // 只有短语没有码（别家网盘的 404 文案）
    assert!(!is_file_not_found_21001("file not found"));
    // 空串 / 成功信封
    assert!(!is_file_not_found_21001(""));
    assert!(!is_file_not_found_21001(
        r#"{"code":0,"data":{"download_url":"https://cdn/…/x.mkv"}}"#
    ));
}

// ── ② 删除任务终态判据 + 预算护栏（lead 批复 A 护栏）──────────────────

#[test]
fn delete_task_done_reads_terminal_states() {
    // 成功态 status=2（与 sharepage/save 任务同族读数）
    assert_eq!(
        delete_task_done(&serde_json::json!({"data": {"status": 2}})),
        Some(true)
    );
    // 失败态 status=3
    assert_eq!(
        delete_task_done(&serde_json::json!({"data": {"status": 3}})),
        Some(false)
    );
    // 还在跑（status=1）/ 形态认不出 ⇒ None（继续等，由调用方超时放行）
    assert_eq!(
        delete_task_done(&serde_json::json!({"data": {"status": 1}})),
        None
    );
    assert_eq!(delete_task_done(&serde_json::json!({})), None);
    assert_eq!(delete_task_done(&serde_json::json!({"data": {}})), None);
}

#[test]
fn purge_wait_budget_is_bounded() {
    // lead 批复 A 护栏：删除确认封顶 3~5s —— 不许无限挂住 resolve
    assert!(
        PURGE_DELETE_WAIT_BUDGET >= std::time::Duration::from_secs(3),
        "预算过短 ⇒ 删除确认形同虚设（竞态兜不住）"
    );
    assert!(
        PURGE_DELETE_WAIT_BUDGET <= std::time::Duration::from_secs(5),
        "预算超过 5s ⇒ resolve 被删除确认拖住（护栏失效）"
    );
    assert!(
        SELFHEAL_LISTING_WAIT <= std::time::Duration::from_secs(5),
        "自愈的清单确认同样不许挂住 resolve"
    );
    assert!(
        PAN_POLL_INTERVAL >= std::time::Duration::from_millis(100),
        "轮询间隔过密 = 打爆 task 接口"
    );
}

// ── ③ 接线断言（源码级：written == wired）────────────────────────────

const SRC: &str = include_str!("../src/csp/pan_drive.rs");

/// degrade_attempt 的函数体（从签名到下一个函数的分隔注释）
fn degrade_attempt_src() -> &'static str {
    let start = SRC.find("async fn degrade_attempt").expect("degrade_attempt 不见了");
    let end = SRC[start..]
        .find("/// 在分享里收集")
        .expect("找不到 degrade_attempt 之后的函数边界");
    &SRC[start..start + end]
}

#[test]
fn selfheal_is_wired_exactly_once_in_degrade_attempt() {
    // degrade_attempt 里：21001 检测 → 等清单消失 → 重转存一次 → 再下载。
    // ★ "重转存"调用在**本函数内**只允许出现两处：正常路 + 自愈路
    //   （resolve_share_play 里还有一处同名调用，不在本断言范围）。
    let body = degrade_attempt_src();
    let count = body
        .matches("save_into_temp_dir(cookie, share_id, passcode, &entry.fid, &token)")
        .count();
    assert_eq!(
        count, 2,
        "★ degrade_attempt 应有「正常转存 + 自愈重转存」两次调用；\
         数量变了 = 自愈被删（证红）或被复制成循环（违反\"只做一次\"批复）"
    );
    // 自愈分支必须先等旧 fid 消失（回收站/索引最终一致性）再重转存
    let heal = body.find("21001 自愈：文件").expect("自愈日志标记不见了");
    let wait = body[heal..]
        .find("wait_fid_gone")
        .expect("自愈分支必须先 wait_fid_gone（等删除落地）再重转存");
    let resave = body[heal..]
        .find("save_into_temp_dir(cookie, share_id, passcode, &entry.fid, &token)")
        .expect("自愈分支的重转存不见了");
    assert!(
        wait < resave,
        "★ 自愈顺序必须是「等清单消失 → 重转存」——先转存等于没等"
    );
}

#[test]
fn purge_waits_for_delete_terminal_state() {
    // A 接线：purge_previous 必须等删除任务终态（否则竞态原样保留）
    let purge = SRC.find("pub async fn purge_previous").expect("purge_previous 不见了");
    let body_end = SRC[purge..]
        .find("/// 21001 自愈的前置确认")
        .expect("找不到 purge_previous 之后的函数边界");
    let body = &SRC[purge..purge + body_end];
    assert!(
        body.contains("self.wait_delete_task("),
        "★ purge_previous 必须轮询删除任务到终态（lead 批复 A）——\
         这条红 = 有人把等待调用拆掉了，重试 404(21001) 会原样复发"
    );
    assert!(
        body.contains("PURGE_DELETE_WAIT_BUDGET"),
        "★ 等待必须有预算封顶（不许无限挂住 resolve）"
    );
}

#[test]
fn play_maps_21001_to_human_terminal_text() {
    // 21001 终态文案：与 Dart 侧 shareFileGone 分类的判据双特征对齐
    // （test/t20261101_pan_21001_classify_test.dart 吃的就是这句话）
    let marker = "文件已不存在（code=21001 file not found）";
    assert!(
        SRC.contains(marker),
        "★ play 的 21001 人话终态文案不见了 —— Dart 分类门禁靠这串特征归档"
    );
}
