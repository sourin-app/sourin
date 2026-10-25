// ═══════════════════════════════════════════════════════════════════════════
// t1040_csp_route —— TVBox `type:3` + `csp_Xxx` 路由（第19项 P1）
//
// 门禁要锁死的是**三个方向的判断**，少一条就会出现「静默假装支持」：
// ```text
// ① 已实现的类（csp_Bili）      → 必须进 jobs（真探测），绝不能进 skipped
// ② 没实现的类（csp_PanWebShare）→ 必须进 skipped，reason 逐字 = "csp_X 尚未实现"
// ③ 不是 csp 的 type:3          → 维持原有文案（spider / 需要 Java），别被新分支吃掉
// ```
//
// ★ 为什么这个文件放在 `csp/` 下却被 `tvbox.rs` 引入：
//   ```rust
//   #[cfg(test)]
//   #[path = "csp/route_tests.rs"]
//   mod t1040_csp_route;
//   ```
//   判据对象是 `tvbox.rs` 的**私有**函数（`collect_sites` / `build_site_provider` /
//   `SiteJob`），只有作为 `tvbox` 的子模块才能直接摸到它们；
//   而文件本身属于 csp 这条线的写范围 —— 两边都不越界。
//
// ★ 故障注入：把 `crate::csp::route` 改成恒 `None`，
//   ① 里「csp_Bili 进 jobs」与 ② 里「没实现的类不建 Provider」的断言会立刻变红
//   （读数见 .probe/csp-fault-route-short-circuit.log）。

use super::{build_site_provider, collect_sites, import_tvbox_config, now_secs, parse_loose_json,
            ProbeOk, SiteJob};
use crate::provider::MediaProvider;
use std::path::PathBuf;

/// 一份**真配置形态**的 sites 段（字段与野外配置一致，含 ext 对象/字符串两种）
fn cfg_with(sites: &str) -> serde_json::Value {
    parse_loose_json(&format!("{{\"sites\":[{sites}]}}")).expect("测试配置必须是合法 JSON")
}

fn tmp_dir(tag: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!(
        "sourin-t1040-{tag}-{}-{}",
        std::process::id(),
        now_secs()
    ));
    std::fs::create_dir_all(&p).expect("建临时目录失败");
    p
}

// ── ① 已实现的类：进 jobs ──────────────────────────────────────────────
#[test]
fn implemented_csp_goes_into_jobs_not_skipped() {
    let cfg = cfg_with(
        r#"{"key":"bili1","name":"哔哩合集","type":3,"api":"csp_Bili",
            "ext":{"json":"https://x/cover.png","cookie":"http://127.0.0.1:9978/file/c.txt"}}"#,
    );
    let (jobs, skipped, _) = collect_sites(&cfg, "");

    assert_eq!(
        jobs.len(),
        1,
        "csp_Bili 必须进 jobs，实际 skipped={skipped:?}"
    );
    let j = &jobs[0];
    assert_eq!(j.csp.as_deref(), Some("Bili"), "必须标出 csp 类名");
    assert_eq!(
        j.api, "csp_Bili",
        "★ api 必须保持原样（不能被当成相对 URL 补全）"
    );
    assert_eq!(j.kind, Some(3));
    assert!(
        skipped.is_empty(),
        "★ 已实现的类绝不能出现在 skipped 里（那是「假装不支持」）"
    );
    // ext 原样透传：对象里的每个键都在，且仍是合法 JSON
    let ext = parse_loose_json(&j.ext).expect("ext 归一后必须仍是 JSON");
    assert_eq!(ext["cookie"], "http://127.0.0.1:9978/file/c.txt");
    assert_eq!(ext["json"], "https://x/cover.png");
}

#[test]
fn implemented_csp_api_survives_base_url_resolution() {
    // 配置是从链接导入的（base_url 非空）—— csp api 仍然必须原样
    let cfg = cfg_with(r#"{"key":"b","name":"哔哩","type":3,"api":"csp_Bili"}"#);
    let (jobs, _, _) = collect_sites(&cfg, "https://cfg.example.com/tvbox/cfg.json");
    assert_eq!(
        jobs[0].api, "csp_Bili",
        "★ 带 base_url 时也不许补成 https://cfg.example.com/.../csp_Bili"
    );
    assert_eq!(jobs[0].csp.as_deref(), Some("Bili"));
}

// ── ② 没实现的类：进 skipped，reason 逐字 ─────────────────────────────
#[test]
fn unimplemented_csp_is_skipped_with_exact_reason() {
    let cfg = cfg_with(
        r#"{"key":"p1","name":"木偶","type":3,"api":"csp_PanWebShare",
            "ext":{"site":["https://123.666291.xyz"]}},
           {"key":"p2","name":"短剧","type":3,"api":"csp_AppDrama"}"#,
    );
    let (jobs, skipped, _) = collect_sites(&cfg, "");
    assert!(jobs.is_empty(), "没实现的类不许进 jobs，实际 {jobs:?}");
    assert_eq!(skipped.len(), 2);

    let reasons: Vec<String> = skipped
        .iter()
        .map(|s| s["reason"].as_str().unwrap_or("").to_string())
        .collect();
    assert!(
        reasons.contains(&"csp_PanWebShare 尚未实现".to_string()),
        "★ 文案必须是「csp_X 尚未实现」，实际 {reasons:?}"
    );
    assert!(
        reasons.contains(&"csp_AppDrama 尚未实现".to_string()),
        "实际 {reasons:?}"
    );
    // stage 仍是 "type"：与既有 skipped 结构一致（UI 按 stage 分组）
    assert_eq!(skipped[0]["stage"], "type");
    assert_eq!(skipped[0]["type"], 3);
}

// ── ③ 非 csp 的 type:3：老路不变 ──────────────────────────────────────
#[test]
fn non_csp_type3_keeps_original_reason() {
    let cfg = cfg_with(
        r#"{"key":"j","name":"某JS源","type":3,"api":"https://x.example/a.js"},
           {"key":"d","name":"东篱","type":3,"api":"csp_DongLi"}"#,
    );
    let (jobs, skipped, _) = collect_sites(&cfg, "");
    assert!(jobs.is_empty(), "这两种都不支持，不许进 jobs");
    assert_eq!(skipped.len(), 2);
    // 不带 csp_ 前缀的 type:3 → 原有「需要 Java 运行时」文案
    let js_reason = skipped
        .iter()
        .find(|s| s["name"] == "某JS源")
        .and_then(|s| s["reason"].as_str())
        .unwrap_or("")
        .to_string();
    assert!(js_reason.contains("需要 Java 运行时"), "实际 {js_reason:?}");
    // csp_ 前缀但没实现 → 新文案（两条路不能混）
    let dong_reason = skipped
        .iter()
        .find(|s| s["name"] == "东篱")
        .and_then(|s| s["reason"].as_str())
        .unwrap_or("")
        .to_string();
    assert_eq!(dong_reason, "csp_DongLi 尚未实现");
}

// ── ④ 建 Provider 的分流（离线：不联网也不许走错分支）────────────────
#[test]
fn build_site_provider_dispatches_csp_to_rust_impl() {
    let cfg = cfg_with(r#"{"key":"b","name":"哔哩","type":3,"api":"csp_Bili"}"#);
    let (jobs, _, _) = collect_sites(&cfg, "");
    let job = &jobs[0];
    let ok = ProbeOk {
        classes: vec![crate::model::TvboxCategoryEntry {
            id: "4".to_string(),
            name: "游戏".to_string(),
            pid: None,
        }],
        total: 0,
    };
    let p = build_site_provider("lib-bili", job, &ok, None, Vec::new()).expect("应能建 Provider");
    let m = p.manifest();
    assert_eq!(m.id, "lib-bili");
    assert_eq!(m.kind, "tvbox");
    assert_eq!(m.name, "哔哩", "名称必须用配置里的，不许实现自己编");
    assert!(
        m.description.as_deref().unwrap_or("").contains("Rust 重写"),
        "描述要能看出这是 Rust 实现，实际 {:?}",
        m.description
    );
    assert!(!m.capabilities.search, "搜索没做就不许声明");
}

#[test]
fn build_site_provider_rejects_unimplemented_class() {
    // 手工造一个「没实现的类」的 job（正常 collect_sites 不会产生它）
    let job = SiteJob {
        index: 0,
        key: "x".to_string(),
        name: "木偶".to_string(),
        api: "csp_PanWebShare".to_string(),
        kind: Some(3),
        csp: Some("PanWebShare".to_string()),
        ext: String::new(),
    };
    let ok = ProbeOk {
        classes: Vec::new(),
        total: 0,
    };
    let err = build_site_provider("x", &job, &ok, None, Vec::new())
        .map(|_| ())
        .expect_err("没实现的类不能建出 Provider");
    assert_eq!(err, "csp_PanWebShare 尚未实现");
}

// ── ⑤ 端到端（真网络，CSP_LIVE=1 才跑）────────────────────────────────
//
// 这条是**导入报告**级的证据：真配置形态 → 真探测上游接口 →
// csp_Bili 进 imported、csp_PanWebShare 进 skipped。
/// 真网络用例 —— **默认不跑**（`#[ignore]`），要跑必须显式点名 + 设 CSP_LIVE=1
///
/// ```text
/// CSP_LIVE=1 cargo test --lib csp_live --release -- --ignored --nocapture
/// ```
///
/// # 为什么是 `#[ignore]` 而不是"没设环境变量就 return"（反假绿审计 B10）
/// 旧写法在 `CSP_LIVE` 未设时 `eprintln!` 一句然后 `return` ⇒ cargo 记成 **ok**
/// ⇒ 报告里"32 passed"看起来像真跑过真上游，实际这两条什么都没验。
/// 现在的语义：
/// ```text
/// 默认        → ignored（不计入 passed，输出里是 `i` 而不是 `ok`）
/// --ignored   → 真的跑；此时**必须** CSP_LIVE=1，否则 assert 失败（不许静默通过）
/// ```
#[tokio::test]
#[ignore = "真网络：CSP_LIVE=1 cargo test --lib csp_live --release -- --ignored --nocapture"]
async fn csp_live_import_reports_bili_imported_and_others_skipped() {
    assert_eq!(
        std::env::var("CSP_LIVE").ok().as_deref(),
        Some("1"),
        "★ 这条是 --ignored 才跑的真网络用例：显式跑就必须给 CSP_LIVE=1；         不给就失败，而不是 return 后被记成 ok（假绿）"
    );
    std::env::set_var("SOURIN_NO_REMOTE_AUTOSTART", "1");
    let dir = tmp_dir("live");
    let cfg = r#"{
      "sites": [
        {"key":"bili1","name":"哔哩｜资源合集","type":3,"api":"csp_Bili",
         "ext":{"json":"https://x/cover.png","cookie":"http://127.0.0.1:9978/file/bili_cookie.txt"}},
        {"key":"bili2","name":"哔哩｜音乐合集","type":3,"api":"csp_Bili","ext":{"n":"哔哩音乐"}},
        {"key":"pan1","name":"木偶","type":3,"api":"csp_PanWebShare",
         "ext":{"site":["https://123.666291.xyz"]}},
        {"key":"js1","name":"某JS源","type":3,"api":"https://x.example/a.js"}
      ]
    }"#;
    let st = crate::state::AppState::bootstrap(dir.clone())
        .await
        .expect("bootstrap 失败");
    let res = import_tvbox_config(&st, cfg).await.expect("导入不该失败");
    println!("[EVIDENCE] csp-live-import {res}");

    let imported = res["imported"].as_array().cloned().unwrap_or_default();
    let names: Vec<String> = imported
        .iter()
        .map(|x| x["name"].as_str().unwrap_or("").to_string())
        .collect();
    assert_eq!(
        imported.len(),
        2,
        "两个 csp_Bili 都应该真导入进来，实际 {res}"
    );
    assert!(names.iter().any(|n| n.contains("哔哩")), "实际 {names:?}");
    let cats = imported[0]["categories"].as_u64().unwrap_or(0);
    assert!(cats > 0, "★ 分类必须是真探测出来的（>0），实际 {res}");

    let skipped = res["skipped"].as_array().cloned().unwrap_or_default();
    let reasons: Vec<String> = skipped
        .iter()
        .map(|s| s["reason"].as_str().unwrap_or("").to_string())
        .collect();
    assert!(
        reasons.contains(&"csp_PanWebShare 尚未实现".to_string()),
        "没实现的类必须在 skipped 里且文案准确，实际 {reasons:?}"
    );
    assert!(
        reasons.iter().any(|r| r.contains("需要 Java 运行时")),
        "非 csp 的 type:3 走老文案，实际 {reasons:?}"
    );

    // ★ 如实标记「这次能用但没落盘」——不许让界面以为它们会自己恢复
    assert_eq!(
        imported[0]["persisted"], serde_json::json!(false),
        "csp 源这一批不落盘，必须如实标 persisted:false，实际 {res}"
    );
    assert_eq!(
        imported[0]["kindTag"], serde_json::json!("csp"),
        "实际 {res}"
    );
    let not_persisted = res["notPersisted"].as_array().cloned().unwrap_or_default();
    assert_eq!(
        not_persisted.len(),
        2,
        "两个 csp 源都要出现在 notPersisted 里（界面据此提示重启需重新导入），实际 {res}"
    );

    // 注册表里真有两个源，且都是 csp 的 Rust 实现
    let ids: Vec<String> = st
        .registry
        .manifests()
        .iter()
        .map(|m| m.id.clone())
        .collect();
    for x in imported.iter() {
        let id = x["id"].as_str().unwrap_or("");
        assert!(ids.iter().any(|i| i == id), "注册表里应有 {id}，实际 {ids:?}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}
