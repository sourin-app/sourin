//! ★★★ 插件 HTTP 必须**按真实 provider id** 取代理配置
//!
//! # 这条测试在防什么（真实缺陷，已修）
//! ```text
//! 改前：do_http 里写的是 client_for("plugin", None) —— 字面量。
//!       UI 侧 proxy_panel.dart 用 widget.providerId（真实插件 id）存配置，
//!       两边 key 永远对不上 ⇒ 查不到 ⇒ ProxyConfig::default()
//!       ⇒ mode=Direct ⇒ 强制直连 ⇒ 用户配的代理**白配**。
//!
//! 实测依据（Owner 报障）：「某动画站（代号 S0）是不能挂梯子,必须直接访问 不然就是会403」
//!   同一 URL：直连 200 / 走代理 403。
//! ```

use sourin_core::proxy::{ProxyConfig, ProxyMode, ProxyStore};

/// 给某个 provider 配「自定义代理」后，按该 id 必须读得回来；
/// 按别的 id（包括旧的硬编码 "plugin"）必须读不到 —— 这正是修复的判据。
#[test]
fn proxy_config_is_keyed_by_real_provider_id() {
    let store = ProxyStore::new();

    let mut cfg = ProxyConfig::default();
    cfg.mode = ProxyMode::Custom;
    cfg.url = Some("http://127.0.0.1:7890".into());
    store
        .set("real_source_id", cfg.clone())
        .expect("set 应成功");

    let got = store.get("real_source_id");
    assert_eq!(got.mode, ProxyMode::Custom, "按真实 id 必须读回自定义代理");
    assert_eq!(got.url.as_deref(), Some("http://127.0.0.1:7890"));

    // ★ 关键断言：旧的硬编码 key 读不到这个配置
    let wrong = store.get("plugin");
    assert_eq!(
        wrong.mode,
        ProxyMode::Direct,
        "硬编码 \"plugin\" 不该命中真实 id 的配置 —— 若命中说明 key 又串了",
    );
    assert_eq!(wrong.url, None, "\"plugin\" 不该有 url");
}

/// 未配置的 provider ⇒ 默认 Direct（= 直连），这是「必须直连的源」的保障。
#[test]
fn unconfigured_provider_defaults_to_direct() {
    let store = ProxyStore::new();
    let got = store.get("never_configured");
    assert_eq!(
        got.mode,
        ProxyMode::Direct,
        "未配置必须是 Direct —— 某些源走代理会 403",
    );
}
// ═══════════════════════════════════════════════════════════════════
//  ★★★ 源码断言：do_http 必须收到**真实 provider id**
// ═══════════════════════════════════════════════════════════════════
//
// 上面两条只测了 ProxyStore 的行为。但真正会坏的是 **do_http 传错 key**，
// 那两条测试抓不到（ProxyStore 本身一直是对的）。
// ⇒ 必须直接读源码断言，否则就是假绿。

/// `do_http` 里不许再出现硬编码的 `client_for("plugin"`
#[test]
fn do_http_does_not_hardcode_plugin_key() {
    let src = std::fs::read_to_string(
        concat!(env!("CARGO_MANIFEST_DIR"), "/src/plugins/mod.rs"),
    )
    .expect("读 plugins/mod.rs");

    /*
     * 允许的**唯一**例外：fetch_plugin_source（安装插件时下载源码，
     * 此刻插件还不存在，没有 provider id 可用 —— 见该函数内注释）。
     * 统计方式：除了那一处，其余出现都算缺陷。
     */
    // 只数**代码行**：排除 `//`、`*`（块注释续行）、`/*` 三种注释形态。
    // 注释里提到历史缺陷是正常的，不该算进缺陷计数。
    let occurrences = src
        .lines()
        .filter(|l| {
            let t = l.trim_start();
            !(t.starts_with("//") || t.starts_with('*') || t.starts_with("/*"))
        })
        .filter(|l| l.contains(r#"client_for("plugin""#))
        .count();
    assert_eq!(
        occurrences, 1,
        "★ 硬编码 client_for(\"plugin\", ...) 出现 {occurrences} 次，\
         只允许 fetch_plugin_source 那 1 次（安装插件时插件还不存在）。\
         其余都必须传真实 provider id —— 否则用户按源配的代理读不到\
         （实测：同一 URL 直连 200 / 走代理 403）。"
    );
}

/// `do_http` 的签名必须带 provider 参数
#[test]
fn do_http_signature_takes_provider() {
    let src = std::fs::read_to_string(
        concat!(env!("CARGO_MANIFEST_DIR"), "/src/plugins/mod.rs"),
    )
    .expect("读 plugins/mod.rs");

    assert!(
        src.contains("provider: &str,"),
        "★ do_http 签名缺 provider: &str 参数"
    );
    assert!(
        src.contains(".client_for(provider, None)"),
        "★ do_http 必须把 provider 透传给 client_for，而不是写死字符串"
    );
}

/// 两处 host.http 调用点都必须把 pid 传进 do_http
#[test]
fn both_http_call_sites_pass_pid() {
    let src = std::fs::read_to_string(
        concat!(env!("CARGO_MANIFEST_DIR"), "/src/plugins/mod.rs"),
    )
    .expect("读 plugins/mod.rs");

    assert!(
        src.contains(r#"do_http(&px, &pid, "GET""#),
        "★ host.http.get 的调用点没把 pid 传进 do_http"
    );
    assert!(
        src.contains(r#"do_http(&px, &pid, "POST""#),
        "★ host.http.post 的调用点没把 pid 传进 do_http"
    );
}
