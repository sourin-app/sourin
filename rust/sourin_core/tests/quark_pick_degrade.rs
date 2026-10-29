//! task-5 门禁：夸克 23018「download file size limit」选文件策略**降级重试**（纯函数级）
//!
//! ```text
//! · 判据核心是 pan_drive::degrade_pick（纯调度：候选按体积降序逐个试，
//!   遇超限错误降级次大，最多 SHARE_PICK_MAX_TRIES=3 个；其它错误不降级）。
//! · 门禁用假闭包喂（不发网络），注入证红方式：把 degrade_pick 的回退循环
//!   改成"只试第一个"⇒ degrade_picks_largest_downloadable / all_exceeded 必红。
//! ```
//!
//! 详见 .agents/notes/implemented/bug-fix/2026-10-30-quark-23018-pick-degrade.md

use std::sync::atomic::{AtomicUsize, Ordering};

use sourin_core::csp::pan_drive::{
    degrade_pick, is_size_limit_error, DriveEntry, SHARE_PICK_MAX_TRIES,
};

/// 真 23018 的错误串形状（`play` 拼出来的，逐字对照真实响应 message）
const LIMIT_ERR: &str =
    "夸克网盘 取下载地址失败（code=23018）：download file size limit（该文件超出账号单文件下载上限）";

fn entry(name: &str, size: u64) -> DriveEntry {
    DriveEntry {
        fid: format!("fid-{name}"),
        name: name.to_string(),
        is_dir: false,
        size,
        fid_token: None,
    }
}

/// 按体积降序的候选（模拟 pick_share_candidates 的输出）
fn candidates_desc() -> Vec<DriveEntry> {
    vec![
        entry("老舅_4K原盘.mkv", 40_000_000_000),
        entry("老舅_1080P.mkv", 8_000_000_000),
        entry("老舅_720P.mp4", 1_500_000_000),
        entry("预告片.mp4", 20_000_000),
    ]
}

#[tokio::test]
async fn is_size_limit_error_matches_23018_and_text() {
    assert!(is_size_limit_error(LIMIT_ERR));
    assert!(is_size_limit_error("code=23018"));
    assert!(is_size_limit_error("Download File Size Limit"));
    // 非超限错误不许误判成超限（否则会把"没登录"也拿去降级）
    assert!(!is_size_limit_error(
        "NEED_LOGIN:quark|还未登录夸克账号，请前往【配置中心】登录"
    ));
    assert!(!is_size_limit_error("夸克网盘 返回 HTTP 500：inner error"));
    assert!(!is_size_limit_error("code=23019"));
}

#[tokio::test]
async fn degrade_picks_largest_downloadable() {
    // 最大、次大都超限 ⇒ 必须落到第 3 个；每次降级都要留记录（UI 文案用）
    let attempts = AtomicUsize::new(0);
    let pool = candidates_desc();
    let (idx, url, notes) = degrade_pick(&pool, SHARE_PICK_MAX_TRIES, "夸克", |e| {
        let attempts = &attempts;
        let name = e.name.clone();
        async move {
            attempts.fetch_add(1, Ordering::SeqCst);
            if name.starts_with("老舅_4K") || name.starts_with("老舅_1080P") {
                Err(LIMIT_ERR.to_string())
            } else {
                Ok(format!("https://cdn.example/{name}"))
            }
        }
    })
    .await
    .expect("第 3 大的文件可下载 ⇒ 必须成功，不许整体失败");
    assert_eq!(idx, 2, "命中必须是第 3 大（下标 2）");
    assert!(url.contains("老舅_720P"), "拿到的是可下载那个的直链：{url}");
    assert_eq!(notes.len(), 2, "两次降级各留一条记录：{notes:?}");
    assert!(notes[0].contains("老舅_4K原盘"), "记录要点名被跳过的文件：{notes:?}");
    assert_eq!(attempts.load(Ordering::SeqCst), 3);
}

#[tokio::test]
async fn degrade_first_candidate_ok_means_no_degrade() {
    let pool = candidates_desc();
    let (idx, _url, notes) = degrade_pick(&pool, SHARE_PICK_MAX_TRIES, "夸克", |e| {
        let name = e.name.clone();
        async move { Ok(format!("https://cdn.example/{name}")) }
    })
    .await
    .expect("最大文件能下 ⇒ 直接用它");
    assert_eq!(idx, 0);
    assert!(notes.is_empty(), "没降级就不该有记录：{notes:?}");
}

#[tokio::test]
async fn degrade_unrelated_error_propagates_without_retry() {
    let attempts = AtomicUsize::new(0);
    let pool = candidates_desc();
    let err = degrade_pick(&pool, SHARE_PICK_MAX_TRIES, "夸克", |_e| {
        let attempts = &attempts;
        async move {
            attempts.fetch_add(1, Ordering::SeqCst);
            Err::<(), String>("夸克网盘 取下载地址请求失败：connection reset".to_string())
        }
    })
    .await
    .expect_err("非超限错误必须原样抛出（降级只针对文件太大）");
    assert!(err.contains("connection reset"), "错误要原样保留：{err}");
    assert_eq!(attempts.load(Ordering::SeqCst), 1, "非超限错误不许再试下一个");
}

#[tokio::test]
async fn degrade_all_exceeded_gives_clear_guidance() {
    let attempts = AtomicUsize::new(0);
    let pool = candidates_desc();
    let err = degrade_pick(&pool, SHARE_PICK_MAX_TRIES, "夸克", |_e| {
        let attempts = &attempts;
        async move {
            attempts.fetch_add(1, Ordering::SeqCst);
            Err::<(), String>(LIMIT_ERR.to_string())
        }
    })
    .await
    .expect_err("全部超限必须报错且给出换线路指引");
    assert!(
        err.contains("该分享的文件超出夸克下载上限"),
        "Owner 指定文案：{err}"
    );
    assert!(err.contains("请换一条线路"), "要给明确指引：{err}");
    assert_eq!(
        attempts.load(Ordering::SeqCst),
        3,
        "最多试 3 个（SHARE_PICK_MAX_TRIES）"
    );
}

#[tokio::test]
async fn degrade_max_tries_caps_attempts() {
    // 5 个候选全超限 ⇒ 只许试 3 个（不把整个分享扫完）
    let attempts = AtomicUsize::new(0);
    let pool = vec![
        entry("a.mkv", 5),
        entry("b.mkv", 4),
        entry("c.mkv", 3),
        entry("d.mkv", 2),
        entry("e.mkv", 1),
    ];
    let err = degrade_pick(&pool, SHARE_PICK_MAX_TRIES, "夸克", |_e| {
        let attempts = &attempts;
        async move {
            attempts.fetch_add(1, Ordering::SeqCst);
            Err::<(), String>(LIMIT_ERR.to_string())
        }
    })
    .await
    .expect_err("全超限 ⇒ 换线路指引");
    assert_eq!(attempts.load(Ordering::SeqCst), 3, "上限就是 3");
    assert!(err.contains("已尝试 3 个"), "报错要点出试了几个：{err}");
}

#[tokio::test]
async fn degrade_uses_candidates_shorter_than_max() {
    // 候选不足 3 个 ⇒ 有几个试几个，不越界
    let attempts = AtomicUsize::new(0);
    let pool = vec![entry("only.mkv", 1), entry("tiny.mp4", 1)];
    let err = degrade_pick(&pool, SHARE_PICK_MAX_TRIES, "夸克", |_e| {
        let attempts = &attempts;
        async move {
            attempts.fetch_add(1, Ordering::SeqCst);
            Err::<(), String>(LIMIT_ERR.to_string())
        }
    })
    .await
    .expect_err("全超限 ⇒ 换线路指引");
    assert_eq!(attempts.load(Ordering::SeqCst), 2, "候选 2 个就试 2 个");
    assert!(err.contains("已尝试 2 个"), "{err}");
}
