// ═══════════════════════════════════════════════════════════════════════
//  Owner 的硬要求：**原版是自动的** —— 已实现的 csp 类必须自动成为源
// ═══════════════════════════════════════════════════════════════════════
//
// # 判据（这条测试守什么）
// ```text
// 在一个**空的**数据目录里 bootstrap（配置里没有任何 csp 站点），
// registry 里必须出现**每一个已注册 csp 类**对应的内置源：
//     id   = `csp-<kebab 类名>`
//     name = 类名
// ⇒ 这就是原版行为：「jar 里有什么类，客户端就出什么源」，
//   不需要用户额外导入订阅。
// ```
//
// # 为什么用空目录（这是关键）
// ```text
// 用真实数据目录测不出这件事：那里的 csp 源来自"用户导入的站点"，
// 即使自动暴露坏了也会有源（**假绿**）。空目录里只有自动暴露这一条路。
// ```
//
// # 反向断言（防空真）
// ```text
// `implemented_classes()` 必须非空，且内置源数 == 已注册类数
// ⇒ 既排除"一个源都没有"，也排除"类没了所以刚好相等"。
// ```
// 注入：把 `state.rs` 里 ⑦'' 那段循环注释掉 ⇒ 本条红（内置源数 0）。

use sourin_core::csp;
use sourin_core::state::AppState;

/// `CamelCase` → kebab（与 `state.rs::kebab_class` 同口径；这里独立实现一遍，
/// 免得把被测逻辑复制过来 —— 复制的话判据就跟着实现一起错了）
fn kebab(class: &str) -> String {
    let cs: Vec<char> = class.chars().collect();
    let mut out = String::new();
    for (i, c) in cs.iter().enumerate() {
        if c.is_ascii_uppercase() {
            let prev_lower = i > 0 && cs[i - 1].is_ascii_lowercase();
            let next_lower = i + 1 < cs.len() && cs[i + 1].is_ascii_lowercase();
            if i > 0 && (prev_lower || next_lower) && !out.ends_with('-') {
                out.push('-');
            }
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(*c);
        }
    }
    out
}

#[tokio::test]
async fn every_registered_csp_class_is_exposed_without_any_config() {
    let tmp = std::env::temp_dir().join(format!(
        "sourin-builtin-csp-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).expect("建临时数据目录");

    let st = AppState::bootstrap(tmp.clone())
        .await
        .expect("空目录 bootstrap 必须成功");

    let classes = csp::implemented_classes();
    assert!(
        !classes.is_empty(),
        "★ 前置：`implemented_classes()` 不许为空（否则下面的比较是空真）"
    );

    let ids: Vec<String> = st
        .registry
        .manifests()
        .into_iter()
        .map(|m| m.id)
        .collect();

    let mut missing: Vec<String> = Vec::new();
    for class in &classes {
        let want = format!("csp-{}", kebab(class));
        if !ids.iter().any(|id| id == &want) {
            missing.push(format!("{class} → {want}"));
        }
    }

    assert!(
        missing.is_empty(),
        "★★ 这些已注册的 csp 类没有自动成为源（原版行为缺失）: {missing:?}\n\
         现有源 id（前 20 个）: {:?}",
        ids.iter().take(20).collect::<Vec<_>>()
    );

    // 反向：内置源数必须与类数对得上（多出来的只能是导入的/插件/聚合，空目录下应为 0）
    let builtin = ids.iter().filter(|id| id.starts_with("csp-")).count();
    assert_eq!(
        builtin,
        classes.len(),
        "★ 内置 csp 源数({builtin}) 必须等于已注册类数({})，实得源: {:?}",
        classes.len(),
        ids
    );

    let _ = std::fs::remove_dir_all(&tmp);
}
