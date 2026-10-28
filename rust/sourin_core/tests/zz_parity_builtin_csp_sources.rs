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

// ══════════════════════════════════════════════════════════════════════
//  ② 幂等：同一目录连续 bootstrap 两次，内置源不能翻倍
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么必须有这条
// ```text
// 复核者指出的缺口：`state.rs` 里只"按 id 查一遍"，但**没有门禁**证明它真的幂等。
// 开发期会反复 bootstrap（热重启、测试、开发者手动重启），一旦不幂等，
// 用户会看到同一个类出现两条源，而且**没有任何报错**。
// ```
#[tokio::test]
async fn builtin_sources_are_idempotent_across_bootstraps() {
    use std::collections::HashSet;

    let tmp = std::env::temp_dir().join(format!("sourin-builtin-csp-idem-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).expect("建临时目录");

    let st1 = AppState::bootstrap(tmp.clone()).await.expect("第一次 bootstrap");
    let ids1: Vec<String> = st1.registry.manifests().into_iter().map(|m| m.id).collect();
    let builtin1 = ids1.iter().filter(|i| i.starts_with("csp-")).count();

    // 第二个 AppState 走同一份数据目录（模拟进程重启）
    let st2 = AppState::bootstrap(tmp.clone()).await.expect("第二次 bootstrap");
    let ids2: Vec<String> = st2.registry.manifests().into_iter().map(|m| m.id).collect();
    let builtin2 = ids2.iter().filter(|i| i.starts_with("csp-")).count();

    assert_eq!(
        builtin1, builtin2,
        "★ 两次 bootstrap 的内置源数必须相同（幂等）：{builtin1} vs {builtin2}"
    );
    let uniq: HashSet<&String> = ids2.iter().collect();
    assert_eq!(
        uniq.len(), ids2.len(),
        "★ 第二次 bootstrap 出现了重复 id（清单长度 {} ≠ 去重后 {}）",
        ids2.len(), uniq.len()
    );
    let _ = std::fs::remove_dir_all(&tmp);
}

// ══════════════════════════════════════════════════════════════════════
//  ③ 停用恢复：内置源被停用后，重启仍是停用
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么必须有这条
// ```text
// `state.rs` 里 ⑦''（建内置源）必须排在 ⑧（应用停用状态）**之前**。
// 顺序反了 ⇒ 注册会把 enabled 重置回 true ⇒ 用户停用过的内置源"自己活了"。
// 这条判据直接钉"顺序"的**后果**，而不是去读源码顺序。
// ```
#[tokio::test]
async fn disabled_builtin_source_stays_disabled_after_restart() {
    let tmp = std::env::temp_dir().join(format!("sourin-builtin-csp-dis-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).expect("建临时目录");

    // 第一次：拿到第一个内置源 id，写进 disabled-providers.json
    let st1 = AppState::bootstrap(tmp.clone()).await.expect("第一次 bootstrap");
    let victim = st1
        .registry
        .manifests()
        .into_iter()
        .map(|m| m.id)
        .find(|i| i.starts_with("csp-"))
        .expect("★ 前置：至少要有 1 个内置源");
    drop(st1);

    let dis_path = tmp.join("disabled-providers.json");
    std::fs::write(&dis_path, format!("[\"{victim}\"]")).expect("写停用清单");

    // 第二次：同目录重启 ⇒ 该源必须仍是停用
    let st2 = AppState::bootstrap(tmp.clone()).await.expect("第二次 bootstrap");
    /*
     * ★★★ 判据必须读**正确的对象**（这条我自己先踩了一次）：
     * ```text
     * 我第一版读 `manifest().enabled` ⇒ 恒 None ⇒ 误判。
     * 真因：`enabled` 存在 `ProviderHandle` 上，`manifests()` 只是 `manifest().clone()`
     *       ⇒ **manifest 里根本没有启用态**（这是本仓"判据作用在错误的对象上"的又一例）。
     * 正确读法：`enabled_manifests()`（只返回启用的）。
     * ```
     * 三态：
     *   ① 源**消失**（manifests 里没有）      ⇒ 失败（用户收藏/进度会失去对象）
     *   ② 源在 **enabled_manifests 里**        ⇒ 失败（停用被注册重置 / 清单没应用）
     *   ③ 源在 manifests 但不在 enabled 里     ⇒ 通过
     */
    let all: Vec<String> = st2.registry.manifests().into_iter().map(|m| m.id).collect();
    assert!(
        all.iter().any(|i| i == &victim),
        "★ 停用的内置源不该消失（消失 = 用户收藏/进度会失去对象）：{victim}"
    );
    let enabled_ids: Vec<String> = st2
        .registry
        .enabled_manifests()
        .into_iter()
        .map(|m| m.id)
        .collect();
    assert!(
        !enabled_ids.iter().any(|i| i == &victim),
        "★★ 被停用的内置源 {victim} 重启后仍在 enabled 清单里 ⇒
         要么「建内置源」排在「应用停用状态」之后（注册把它重置回 true），
         要么 disabled-providers.json 没被应用。"
    );
    let _ = std::fs::remove_dir_all(&tmp);
}
