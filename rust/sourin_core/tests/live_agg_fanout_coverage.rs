// ═══════════════════════════════════════════════════════════════════════
//  聚合源扇出覆盖度普查（回答 Owner：每个子源都找到三条并实机播了吗？）
// ═══════════════════════════════════════════════════════════════════════
//
// # 关键认知修正（2026-10-30，本轮自查）
//
// 上一版测试在 `registry.search_all` 层面统计，得到"107 子源只有 cctv 有命中"，
// **这是误判**：TVBox 导入的子站都被标 `hidden: true`（列表不展示），
// `registry::for_each_search` 会**刻意跳过 hidden 源**（避免与聚合源扇出重复搜索），
// 真正对子站扇出的是 `tvbox_agg` 自己。所以正确口径是：
//
// ```text
// registry.search_all → 只搜非 hidden（≈ 1 个：cctv）+ tvbox_agg（它自己扇出全部子站）
// tvbox_agg.search    → 扇出全部 enabled 子站，这才是"聚合搜索"的真实覆盖面
// ```
//
// # 本测试要回答的问题
//
// ```text
// ① 聚合搜索一次能拿到多少条结果？
// ② 这些结果来自多少个**不同的子源**？（item.id 形如 "tvbox_agg:<child>::<native>"，
//    或结果自带 provider 标记 —— 按实际结构解析）
// ③ 每个被覆盖到的子源各取前 3 条，作为实机播放抽测的候选清单
// ④ 哪些子源**没有被聚合搜索覆盖到**（在 107 个子源里）
// ```
//
// # 跑法
//
// ```powershell
// cd rust\sourin_core
// cargo test --test live_agg_fanout_coverage --release -- --ignored --nocapture --test-threads=1
// ```

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use sourin_core::state::AppState;

/// 多词探测：单一词会低估覆盖面（不同源对不同题材的收录不同）
const PROBES: [&str; 6] = ["老舅", "兰香如故", "庆余年", "流浪地球", "仙逆", "甄嬛传"];

async fn real_state() -> Arc<AppState> {
    let dir = std::env::var("APPDATA")
        .map(|p| std::path::PathBuf::from(p).join("app.sourin.player"))
        .expect("APPDATA");
    AppState::bootstrap(dir).await.expect("bootstrap")
}

/// 从聚合条目的 `MediaId` 解析出**真实子源 id**。
///
/// 聚合条目的 provider 字段是 `tvbox_agg`，native 里带子站路由前缀
/// （形态 `<child>::<native>`，或历史形态 `tvbox_agg:<child>::<native>`）。
/// 两种都兼容，解析不出返回 None。
fn child_of(id: &sourin_core::model::MediaId) -> Option<String> {
    let mut n = id.native.as_str();
    // 历史形态：native 里还带着 `tvbox_agg:` 前缀
    if let Some(rest) = n.strip_prefix("tvbox_agg:") {
        n = rest;
    }
    let idx = n.find("::")?;
    let child = &n[..idx];
    if child.is_empty() {
        None
    } else {
        Some(child.to_string())
    }
}

#[tokio::test]
#[ignore = "真网测试：需要网络，默认门禁不跑；用 --ignored 显式执行"]
async fn fanout_coverage() {
    let st = real_state().await;

    // 全部已注册子源（含 hidden 的 TVBox 导入源）
    let all_children: BTreeSet<String> = st
        .registry
        .manifests()
        .iter()
        .map(|m| m.id.clone())
        .filter(|id| id != sourin_core::tvbox_aggregate::AGGREGATE_ID)
        .collect();
    println!("=== 已注册子源（含 hidden）共 {} ===", all_children.len());

    // key = child_id, value = 该子源在聚合搜索结果里出现的样本（最多 3 条）
    let mut covered: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut total_items = 0usize;
    let mut unparsed = 0usize;

    for kw in PROBES {
        // ★ 直调**聚合源**的 search —— 这是 App 搜索页真正走的那条路
        let Some(agg) = st.registry.get(sourin_core::tvbox_aggregate::AGGREGATE_ID) else {
            panic!("聚合源没有注册");
        };
        match agg.search(kw, 1).await {
            Ok(page) => {
                let n = page.items.len();
                total_items += n;
                println!("\n--- 「{kw}」聚合返回 {n} 条 ---");
                for it in &page.items {
                    match child_of(&it.id) {
                        Some(child) => {
                            let e = covered.entry(child).or_default();
                            if e.len() < 3 {
                                e.push(format!("{kw}|{}|{}", it.id.as_key(), it.title));
                            }
                        }
                        None => {
                            unparsed += 1;
                            if unparsed <= 5 {
                                println!("UNPARSED\tid={}", it.id.as_key());
                            }
                        }
                    }
                }
            }
            Err(e) => println!("AGG_ERR\t{kw}\t{}", e.message),
        }
    }

    println!(
        "\n=== 扇出覆盖 === 聚合结果 {} 条 / 覆盖子源 {} 个 / 无法解析归属 {} 条 ===",
        total_items,
        covered.len(),
        unparsed
    );

    println!("\n=== 每个被覆盖子源的前 3 条候选（供实机抽测）===");
    for (child, samples) in &covered {
        println!("COVER\t{child}\tn_samples={}", samples.len());
        for s in samples {
            println!("  PICK\t{child}\t{s}");
        }
    }

    let missing: Vec<&String> = all_children
        .iter()
        .filter(|c| !covered.contains_key(*c))
        .collect();
    println!("\n=== 未被聚合搜索覆盖的子源 {} 个 ===", missing.len());
    for m in &missing {
        println!("MISS\t{m}");
    }

    assert!(
        covered.len() > 0,
        "聚合搜索一条结果都没解析出子源归属 —— 要么零结果，要么 id 形态变了"
    );
}
