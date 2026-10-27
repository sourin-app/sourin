// ═══════════════════════════════════════════════════════════════════════
//  N9 / N8b-1：四条新命令的 **FFI 端到端** 验收（2026-10-27，Lead）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个测试要回答什么（为什么非写不可）
//
// tvbox-rust 把四条函数写好了、Rust 侧单测也绿了；Lead 把它们接到了
// `ffi.rs` 的 dispatch 表里。但**接线本身没有门禁** —— 上面的单测直接调
// Rust 函数，**根本不经过 dispatch 表**。
//
// ⇒ 「函数对 + 接线漏了」这个组合在既有门禁眼里**完全看不见**：
//   Dart 侧调用会拿到 `unknown command`，而所有 Rust 单测照样全绿。
//   这正是本仓反复出现的那类缺口（"看着绿、其实没覆盖"）。
//
// # 所以本测试**只走 FFI 入口**：`sourin_call(cmd_json)`
//
// ```text
// 进料：{"cmd":"tvbox_agg_channels","args":{}}
// 出料：dispatch_blocking 的 JSON 字符串
// ⇒ 命令名必须在 dispatch 表里真的存在；参数解析、错误分档、序列化
//   全都真的跑一遍。接线一漏，这里立刻是 "unknown command"。
// ```
//
// ⚠️ `sourin_call` 用全局 `runtime().block_on(...)`，所以本测试是**同步**
//    `#[test]`（不是 `#[tokio::test]`）—— 在 tokio worker 上再 block_on
//    会死锁（`ffi.rs:696` 的长注释逐字写了这件事）。
// ═══════════════════════════════════════════════════════════════════════

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// ★★★ 必须先真启动核心 —— 否则每条命令都回同一个
/// `核心尚未启动 —— 请先调用 sourin_start({dataDir})`，
/// 而那句**不是** unknown command ⇒
/// "不是 unknown command" 这个信号会**恒真**（假绿）。
///
/// ★ 这正是本文件第一版实测踩到的坑（`n9_channel_home_...` 因为
///   拿不到 channel_id 那条错误而红，暴露了整个文件的判据太弱）：
///   门禁**必须**让命令真的走到 dispatch 表的分支上，才有资格谈"接线在位"。
///
/// 用进程级一次性初始化（`Once`）—— 多条 `#[test]` 并发跑，
/// 而 `sourin_start` 会建全局 `AppState`（重复调用语义未定义）。
fn ensure_started() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let dir = std::env::temp_dir().join(format!(
            "sourin-n9ffi-{}",
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).expect("建隔离数据目录");
        println!("[n9ffi] 数据目录 = {}", dir.display());
        let cfg = serde_json::json!({ "dataDir": dir.to_string_lossy() }).to_string();
        let c = CString::new(cfg).unwrap();
        let p = unsafe { sourin_core::ffi::sourin_start(c.as_ptr()) };
        let out = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { sourin_core::ffi::sourin_free(p) };
        println!("[n9ffi] sourin_start ⇒ {out}");
        assert!(
            !out.contains("\"error\""),
            "★ 核心必须真的起来（否则后面所有断言都在测一个没启动的核）：{out}"
        );
    });
}

/// 走**真 FFI 入口**发一条命令，返回解析后的 JSON
fn call(cmd: &str, args: serde_json::Value) -> serde_json::Value {
    ensure_started();
    let req = serde_json::json!({ "cmd": cmd, "args": args }).to_string();
    let c = CString::new(req).expect("req 含 NUL");
    // SAFETY：sourin_call 要求 NUL 结尾的合法 UTF-8；返回值由 sourin_free 归还
    let out_ptr: *mut c_char = unsafe { sourin_core::ffi::sourin_call(c.as_ptr()) };
    assert!(!out_ptr.is_null(), "sourin_call 返回了空指针");
    let out = unsafe { CStr::from_ptr(out_ptr) }
        .to_string_lossy()
        .into_owned();
    unsafe { sourin_core::ffi::sourin_free(out_ptr) };
    serde_json::from_str(&out)
        .unwrap_or_else(|e| panic!("命令 `{cmd}` 返回的不是合法 JSON（{e}）：{out}"))
}

/// 有没有 `error` 字段 —— 用来区分"命令存在且正常"与"命令不存在"
fn err_of(v: &serde_json::Value) -> Option<&str> {
    v.get("error").and_then(|e| e.as_str())
}

/// ★★★ 接线判据：命令**必须真的在 dispatch 表里**
///
/// # 为什么这条是核心
/// ```text
/// 命令不在 dispatch 表里时，`dispatch_inner` 的**兜底分支**返回：
///   err_json("这个功能（`{cmd}`）在当前版本还没有接入…", "unsupported")
/// ⇒ "接线漏了"与"函数没实现"是两个不同的可观测结果，
///   前者是 kind=unsupported + 文案，后者是别的错。
/// ⇒ 只要某条新命令没接进 ffi.rs，这里就能把它认出来。
/// 反过来：接线漏了但 Rust 单测全绿，是**假绿**；这条能把它抓住。
/// ```
///
/// # ⚠️ 这里踩过一个坑，写下来免得重踩（本文件第一版就是假的）
/// ```text
/// 第一版判据是 `!e.contains("unknown command")` —— 而 **ffi.rs 里
/// 根本没有 "unknown command" 这个串**（兜底文案是上面那句中文）。
/// ⇒ 那个断言**恒真**：我把接线删掉做注入，5 条测试**照样全绿**
///   （`.probe/n9ffi-wiring-inject-W1.log`，EXIT=0）。
///   这是典型的"断言里写了一个不存在的字符串 ⇒ 断言没有对象"。
/// ⇒ 修法两条一起上：
///   ① 判据改成匹配**真实的兜底文案 + kind=unsupported**；
///   ② 先真启动核心，排除"核心尚未启动"这个**前置**失败
///      （它也满足"不是 unknown command"⇒ 会让弱判据恒真）。
/// ```
fn assert_wired(cmd: &str, args: serde_json::Value) {
    let v = call(cmd, args);
    let kind = v.get("kind").and_then(|k| k.as_str()).unwrap_or("");
    if let Some(e) = err_of(&v) {
        assert_ne!(
            kind, "unsupported",
            "★★★ 命令 `{cmd}` 落到 dispatch 的**兜底分支**里了（kind=unsupported）—— \
             函数写好了但 ffi.rs 没接，Dart 侧永远调不到。原文：{e}"
        );
        assert!(
            !e.contains("还没有接入"),
            "★★★ `{cmd}` 回的是「还没有接入」—— 就是没接线（原文：{e}）"
        );
        assert!(
            !e.contains("核心尚未启动"),
            "★★★ `{cmd}` 的失败是**前置条件**（核心没起来），不是接线结论 —— \
             在这种情形下上面两条会恒真（假绿）。必须先让核心真启动。实际：{e}"
        );
    }
}

#[test]
fn n9_channels_command_is_wired_through_ffi() {
    assert_wired("tvbox_agg_channels", serde_json::json!({}));
}

#[test]
fn n9_channel_home_command_is_wired_through_ffi() {
    // ★ 空 channel_id 是**预期的参数错误**（不是 unknown command）——
    //   恰好一条断言同时验"接线在位"与"参数校验在位"。
    let v = call("tvbox_agg_channel_home", serde_json::json!({ "channel_id": "" }));
    let e = err_of(&v).unwrap_or_else(|| {
        panic!("★★★ 空 channel_id 必须被拒（否则空渠道会被当成合法请求发出去）：{v}")
    });
    assert_ne!(
        v.get("kind").and_then(|k| k.as_str()).unwrap_or(""),
        "unsupported",
        "★★★ `tvbox_agg_channel_home` 落到兜底分支了（没接线）：{e}"
    );
    assert!(
        !e.contains("核心尚未启动"),
        "★★★ 失败来自前置条件（核心没起来），不是接线结论 —— 下述断言会恒真：{e}"
    );
    assert!(
        e.contains("channel_id"),
        "★ 拒绝理由必须点名 `channel_id`（用户/排查者要知道哪个参数不对），实际：{e}"
    );
}

#[test]
fn n8b1_migratable_js_command_is_wired_through_ffi() {
    assert_wired("tvbox_migratable_js", serde_json::json!({}));
}

#[test]
fn n8b1_restore_js_command_is_wired_through_ffi_and_guards_path() {
    /*
     * ★ 硬边界优先：先证明**目录穿越被挡**（这条比"接线在位"更要紧）。
     * `check_js_file_name` 拒 `/` `\` `..` 与非 .js —— 参数来自前端，
     * 必须当**不可信输入**。
     */
    for bad in ["../evil.js", "a/b.js", "a\\b.js", "notjs.txt"] {
        let v = call("tvbox_restore_js", serde_json::json!({ "file": bad }));
        let e = err_of(&v).unwrap_or_else(|| {
            panic!("★★★ 非法文件名 `{bad}` 必须被拒（防目录穿越），实际返回：{v}")
        });
        assert_ne!(
            v.get("kind").and_then(|k| k.as_str()).unwrap_or(""),
            "unsupported",
            "★★★ `tvbox_restore_js` 落到兜底分支了（没接线）：{e}"
        );
        assert!(
            !e.contains("还没有接入"),
            "★★★ `tvbox_restore_js` 回的是「还没有接入」—— 就是没接线（原文：{e}）"
        );
    }
}

#[test]
fn n9_channels_returns_the_contracted_shape() {
    /*
     * 契约（home-ui 要按它写 Dart 侧）：
     * {"ok":true,"aggregateId":"tvbox_agg","channels":[{id,name,enabled}]}
     *
     * ⚠️ 隔离数据目录里没有导入过任何 tvbox 源 ⇒ channels 允许为空数组，
     *    但**字段必须都在** —— 缺 `channels` 会让 Dart 侧解析成 null 崩掉。
     */
    let v = call("tvbox_agg_channels", serde_json::json!({}));
    if let Some(e) = err_of(&v) {
        // 接线在位时的一种合理失败：没有配置。此时**也**要有可读原因。
        assert_ne!(
            v.get("kind").and_then(|k| k.as_str()).unwrap_or(""),
            "unsupported",
            "★★★ 接线缺失（落到兜底分支）：{e}"
        );
        assert!(!e.contains("还没有接入"), "★★★ 没接线：{e}");
        return;
    }
    assert!(
        v.get("channels").map(|c| c.is_array()).unwrap_or(false),
        "★★ 返回里必须有 `channels` 数组（Dart 侧按它渲染渠道条），实际：{v}"
    );
    assert_eq!(
        v.get("aggregateId").and_then(|s| s.as_str()),
        Some("tvbox_agg"),
        "★★ `aggregateId` 必须是聚合源那条固定 id（前端用它做分流），实际：{v}"
    );
}