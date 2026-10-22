//! C7 故障注入验证：宿主是否把 `ok:false` 当软失败放行。
//!
//! ══════════════════════════════════════════════════════════════════════
//! 这个文件验什么
//! ══════════════════════════════════════════════════════════════════════
//! ```text
//! 契约（`plugins/mod.rs:3763`）：
//!     if !r.ok { return Err(unsupported("插件返回 ok=false …")) }
//!
//! 本文件用一个**故意违规**的插件（`danmakuSend` 返回 `{ok:false}`）
//! 直接打宿主，看它到底走 Err 还是 Ok。
//!
//! ★ 为什么单独一个文件、而不是塞进 zz_n15_acceptance：
//!   后者验的是**真实数据目录里那个插件**（行为正确、只会抛异常）；
//!   本文件需要的是一个**故意写坏**的插件。
//!   两者的夹具性质相反，混在一起会让断言互相掩盖。
//! ```
//!
//! # 故障注入怎么用
//! ```text
//! ① 正常（宿主有纪律）⇒ 本测试**通过**（拿到 Err）
//! ② 把 `plugins/mod.rs` 的 `if !r.ok { return Err(...) }` 改成 `Ok(r)`
//!    ⇒ 本测试**必须失败**（拿到 Ok）
//! ```
//!
//! 运行：
//! ```bash
//! cargo test --test zz_n15_c7_ok_false_injection -- --nocapture
//! ```

use sourin_core::model::DanmakuSendRequest;
use sourin_core::plugins::JsPluginProvider;
use sourin_core::provider::MediaProvider;

/// 故意违规的插件：`danmakuSend` 返回 `{ ok: false }`
const BAD_PLUGIN: &str = r#"
/** @id c7-probe
 * @name C7 probe
 * @version 1.0.0
 * @author test
 * @description Returns ok:false instead of throwing (a contract violation)
 */
globalThis.plugin = {
  capabilities: { vod: true, danmaku: true, danmakuSend: true },
  async home() { return [] },
  async search() { return { items: [], page: 1, pageCount: 1 } },
  async detail() { throw new Error('n/a') },
  async resolve() { return [] },
  async danmakuSend(req) { return { ok: false } }
}
"#;

#[tokio::test]
async fn host_rejects_ok_false() {
    let mut p = JsPluginProvider::from_source(BAD_PLUGIN).expect("from_source");
    p = p.with_data_dir(std::env::temp_dir());
    p.hydrate_capabilities().await;

    let r = p
        .danmaku_send(DanmakuSendRequest {
            episode_id: "1".into(),
            text: "probe".into(),
            ..Default::default()
        })
        .await;

    match r {
        Ok(v) => {
            /*
             * ★ 走到这里说明宿主**放行了 ok:false** —— 契约纪律失效。
             * 这正是「用户以为发出去了」的最坏形态。
             */
            panic!(
                "★ 宿主放行了 `ok:false`（拿到 Ok(ok={})）。\n\
                 ⇒ `plugins/mod.rs` 的 `if !r.ok {{ return Err(...) }}` 那条纪律失效了。",
                v.ok
            );
        }
        Err(e) => {
            eprintln!("★ 宿主正确拒绝：{}", e.message);
            assert!(
                e.message.contains("ok=false") || e.message.contains("发送未成功"),
                "★ 错误消息里应该点明「ok=false」这件事，实际：{:?}",
                e.message
            );
            eprintln!("★ PASS：ok:false 被转成 Err，且消息点明了原因");
        }
    }
}

/// 阳性对照：插件抛异常时，宿主要如实透传（不是被上面那条兜底吞掉）
#[tokio::test]
async fn host_passes_through_plugin_throw() {
    const THROWING: &str = r#"
/** @id c7-probe2
 * @name C7 probe2
 * @version 1.0.0
 * @author test
 * @description Throws a prefixed error
 */
globalThis.plugin = {
  capabilities: { vod: true, danmaku: true, danmakuSend: true },
  async home() { return [] },
  async danmakuSend(req) { throw new Error('unauthorized: probe says no'); }
}
"#;
    let mut p = JsPluginProvider::from_source(THROWING).expect("from_source");
    p = p.with_data_dir(std::env::temp_dir());
    p.hydrate_capabilities().await;

    let r = p
        .danmaku_send(DanmakuSendRequest {
            episode_id: "1".into(),
            text: "probe".into(),
            ..Default::default()
        })
        .await;

    match r {
        Ok(v) => panic!("★ 插件抛了异常，宿主却返回 Ok(ok={})", v.ok),
        Err(e) => {
            eprintln!("★ 异常透传：{}", e.message);
            eprintln!("★ PASS：插件抛异常 ⇒ 宿主返回 Err（不是被兜底成 ok:false）");
        }
    }
}
