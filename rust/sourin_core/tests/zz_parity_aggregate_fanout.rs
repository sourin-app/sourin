// ═══════════════════════════════════════════════════════════════════════
//  聚合"全部"的候选集：**不许只看 hidden**
// ═══════════════════════════════════════════════════════════════════════
//
// # 由来（Owner 现场对照原版）
// ```text
// 他在原版里搜"老舅"得到 73 条（左侧十几个源分组，全部 73/73）；
// 在我们这边搜同样的词是 0 条。
// 查下来：聚合的兜底候选集写的是 `.filter(|m| m.hidden)`
//   ⇒ 只收"TVBox 导入的隐藏子站"；
//   ⇒ 内置 csp 源（`csp-*`，不 hidden）永远进不了聚合；
//   ⇒ 而他配置里那批 hidden 子站在 disabled-providers.json 里全被停用
//      ⇒ 候选集为空 ⇒ 聚合 0 渠道 ⇒ 搜索 0 条。
// 原版语义是"全部 = 所有站都扇出"。`hidden` 只该决定"要不要在源列表里露脸"，
// 不该决定"能不能被搜到"。
// ```
//
// # 判据（这条门禁守什么）
// ```text
// 造两个 provider：
//   ① `demo`         —— 非 hidden、启用     ⇒ **必须**在聚合候选集里
//   ② `tvbox1`       —— hidden、停用        ⇒ **不许**在候选集里
// 然后断言 `channels()` 里恰好是 {demo}：既证明"非 hidden 也能被搜到"（本次修复），
// 也证明"停用的不许被拉回来"（R2-B 的意图没被破坏）。
// ```
// 注入：把 `.filter(|m| m.id != AGGREGATE_ID)` 前一行加回 `.filter(|m| m.hidden)`
//       ⇒ 本条红（`demo` 消失、只剩空集）。

use std::sync::Arc;

use sourin_core::state::AppState;

#[tokio::test]
async fn aggregate_fans_out_to_non_hidden_enabled_sources() {
    let tmp = std::env::temp_dir().join(format!("sourin-agg-fanout-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).expect("建临时数据目录");

    let st = AppState::bootstrap(tmp.clone())
        .await
        .expect("空目录 bootstrap 必须成功");

    // 空目录里已经有一批**内置 csp 源**（非 hidden、启用）⇒ 聚合必须能看见它们。
    let enabled: Vec<String> = st
        .registry
        .enabled_manifests()
        .into_iter()
        .map(|m| m.id)
        .filter(|id| id != "tvbox_agg")
        .collect();
    assert!(
        !enabled.is_empty(),
        "★ 前置：空目录里应当已有内置源（否则本条是空真）"
    );

    /*
     * 用与 `TvboxAggregate::channels()` **同一份实现**的自由函数（避免 downcast：
     * `MediaProvider` 没暴露 `as_any`）。`channels_of` 就是 command 层与 provider 方法
     * 共用的那一个入口，所以判据守的仍是生产路径。
     */
    /*
     * ⚠️ 判据对象是**扇出候选集**（`enabled_children`），不是 `channels_of`：
     *    `channels_of` 是首页那条横向渠道条，只列用户导入的隐藏子站（49 个内置源不该上条）。
     *    两者共用过一份实现，放开兜底时把渠道条也撑爆了 —— N9 的门禁当场抓到。
     */
    let channels: Vec<String> = sourin_core::tvbox_aggregate::enabled_children(&st.registry, &tmp)
        .into_iter()
        .map(|p| p.manifest().id.clone())
        .collect();

    let mut missing: Vec<&String> = Vec::new();
    for id in &enabled {
        if !channels.iter().any(|c| c == id) {
            missing.push(id);
        }
    }
    assert!(
        missing.is_empty(),
        "★★ 这些「启用的非 hidden 源」没进聚合候选集 ⇒ 用户「全部」搜索搜不到它们：\n  {missing:?}\n\
         实际渠道：{channels:?}"
    );
    assert!(
        !channels.iter().any(|c| c == "tvbox_agg"),
        "★ 聚合不许把自己算成渠道（会递归）"
    );

    let _: Arc<AppState> = st;
    let _ = std::fs::remove_dir_all(&tmp);
}
