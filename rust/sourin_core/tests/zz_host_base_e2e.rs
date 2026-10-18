//! ★★★ 端到端：JS 里的 `host.base()` 真能拿到宿主选中的域名
//!
//! # 补的是什么缺口
//! ```text
//! 已有 t37_hostpool.rs 测的是 HostPool **纯逻辑**（选路算法）。
//! 但「插件真的能调到 host.base()」这一环**一条测试都没有**。
//!
//! 而这一环历史上**真的坏过**（见 plugins/mod.rs 的注释）：
//!   base() 先在前面注入，随后 shim 的 `globalThis.host = {...}`
//!   把整个对象**覆盖**掉 ⇒ 插件调 host.base() 报 "not a function"。
//! 这种缺陷纯逻辑测试永远测不出来 —— 必须真的在 QuickJS 里跑一遍。
//! ```

use sourin_core::plugins::JsPluginProvider;
use sourin_core::provider::{ListRequest, MediaProvider};

/// 声明两个域名的插件：把 `host.base()` 的返回值当成条目 id 暴露出来
const SRC: &str = r#"
/**
 * @id zz_base_probe
 * @name host.base e2e probe
 * @version 1.0.0
 */
globalThis.plugin = {
  id: "zz_base_probe",
  name: "host.base e2e probe",
  version: "1.0.0",
  hosts: ["https://a.example.com", "https://b.example.com"],
  capabilities: { vod: true, search: true },
  async list() {
    // ★ 这里调 host.base() —— 若 shim 没挂上会抛 "not a function"
    const b = host.base();
    const tag = (b === "") ? "EMPTY" : b.replace(/[^a-zA-Z0-9]/g, "_");
    return { items: [{ id: "probe:" + tag, title: "t" }], page: 1, hasMore: false };
  },
  async search() {
    const b = host.base();
    const tag = (b === "") ? "EMPTY" : b.replace(/[^a-zA-Z0-9]/g, "_");
    return { items: [{ id: "probe:" + tag, title: "t" }], page: 1, hasMore: false };
  },
};
"#;

/// 无 hosts 的插件（向后兼容契约：host.base() 必须返回空串）
const NO_HOSTS: &str = r#"
/**
 * @id zz_no_hosts
 * @name no hosts
 * @version 1.0.0
 */
globalThis.plugin = {
  id: "zz_no_hosts",
  name: "no hosts",
  version: "1.0.0",
  capabilities: { vod: true },
  async list() {
    const b = host.base();
    const tag = (b === "") ? "EMPTY" : b.replace(/[^a-zA-Z0-9]/g, "_");
    return { items: [{ id: "probe:" + tag, title: "t" }], page: 1, hasMore: false };
  },
};
"#;

#[tokio::test]
async fn host_base_is_callable_and_returns_declared_host() {
    let mut p = JsPluginProvider::from_source(SRC).expect("from_source 失败");
    p.hydrate_capabilities().await;

    let page = p
        .list(ListRequest::default())
        .await
        .expect("list 失败 —— host.base() 很可能抛了 not a function");

    let id = page.items.first().map(|i| i.id.native.clone()).unwrap_or_default();
    eprintln!("★ host.base() 经 JS 往返后 = {id:?}");
    assert!(
        id == "probe:https___a_example_com" || id == "probe:https___b_example_com",
        "host.base() 必须返回声明过的域名之一，实际 = {id:?}",
    );
}

#[tokio::test]
async fn plugin_without_hosts_gets_empty_base() {
    let mut p = JsPluginProvider::from_source(NO_HOSTS).expect("from_source 失败");
    p.hydrate_capabilities().await;
    let page = p.list(ListRequest::default()).await.expect("list 失败");
    let id = page.items.first().map(|i| i.id.native.clone()).unwrap_or_default();
    eprintln!("★ 无 hosts 时 host.base() = {id:?}");
    assert_eq!(id, "probe:EMPTY", "未声明 hosts ⇒ host.base() 必须是空串（向后兼容）");
}