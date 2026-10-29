//! 23018 猎捕二轮修复的门禁：csp resolve 的剧集 id「URL 直通」判据
//!
//! ```text
//! 现象：4K网盘子站（zhinan）剧集 id 是纯夸克分享 URL（无 '|'）⇒ 被旧判据
//!       contains('|') 误判成"条目 id" ⇒ 拿 URL 再走一次 detail 二跳 ⇒
//!       上游 404 ⇒ resolve 整体 Err，夸克分享兜底根本到不了（9 条全灭、零日志）。
//! 判据核心：csp::provider::episode_id_is_direct_play（纯函数）+ 接线源码级断言
//!       （include_str! 先例：tvbox_aggregate.rs:2720 / pan_drive.rs:2358）。
//! 注入证红：把 resolve 里的调用改回内联 contains('|') ⇒ 接线断言红；
//!           把判据函数的 URL 直通删掉 ⇒ 形状门禁红。
//! ```
//!
//! 详见 .agents/notes/implemented/bug-fix/2026-10-30-csp-episode-url-direct-play.md

use sourin_core::csp::provider::episode_id_is_direct_play;

#[test]
fn url_shaped_episode_ids_are_direct_play() {
    // 猎捕二轮的现场形态：zhinan 详情页给的夸克分享 URL（无 '|'）
    assert!(episode_id_is_direct_play("https://pan.quark.cn/s/ca8cb8cdfeb3"));
    assert!(episode_id_is_direct_play("http://pan.quark.cn/s/abc"));
    // 其它网盘分享 URL 同理（zhinan 详情页里百度/迅雷链接同形）
    assert!(episode_id_is_direct_play("https://pan.baidu.com/s/1RXwW0KP8q8liF5"));
    assert!(episode_id_is_direct_play("https://pan.xunlei.com/s/VOuVXeHitBt3suaw"));
}

#[test]
fn pipe_shaped_episode_ids_stay_direct_play() {
    // 既有形态不许回归：bili 的 `bvid|cid`、hjzhen_cai 的 `pan|URL`
    assert!(episode_id_is_direct_play("bvid|cid"));
    assert!(episode_id_is_direct_play("BV1xx|12345"));
    assert!(episode_id_is_direct_play("pan|https://pan.quark.cn/s/abc"));
}

#[test]
fn plain_item_ids_still_need_detail_lookup() {
    // 纯条目 id（无 '|'、非 URL）⇒ 仍走 detail 二跳（这是原判据的本意，不许丢）
    assert!(!episode_id_is_direct_play("20328"));
    assert!(!episode_id_is_direct_play("bvid_only_no_pipe"));
    // 空与空白也要二跳（后续分支按原样处理）
    assert!(!episode_id_is_direct_play(""));
    assert!(!episode_id_is_direct_play("   "));
}

/// 接线断言：resolve 必须真的调用这个判据（而不是判据函数存在但没人用）
///
/// ```text
/// 为什么用源码级断言：CspProvider 只能经 `route(api)` 用真 site 构造
/// （`for_test` 是 #[cfg(test)] pub(crate)，集成测试拿不到）⇒ resolve 级假 site
/// 门禁在 tests/ 无法搭。判据行为（形状）+ 接线（源码级）两层合起来等价于
/// "URL 形 episode 直达 play、不再触发 detail 二跳"。
/// ```
#[test]
fn resolve_wires_the_direct_play_predicate() {
    let src = include_str!("../src/csp/provider.rs");
    assert!(
        src.contains("episode_id_is_direct_play(&episode)"),
        "resolve 的 detail 二跳判据必须走 episode_id_is_direct_play（不许内联旧判据）"
    );
    // 旧的**内联**判断不许回来（函数体里那份不算——上面那条已经钉住调用点）
    let call_site = src
        .split("let episode = if ")
        .nth(1)
        .expect("resolve 里应有 `let episode = if` 判据行");
    let head = call_site.split('{').next().unwrap_or("");
    assert!(
        head.contains("episode_id_is_direct_play(&episode)"),
        "判据行必须是函数调用：{head}"
    );
}
