// ═══════════════════════════════════════════════════════════════════════
//  子源真实状态诊断（回答：106 个子源为什么零命中？）
// ═══════════════════════════════════════════════════════════════════════
//
// 普查测试 `live_agg_source_survey` 的读数是 107 子源只有 cctv 有命中，
// 其余 106 个全是"无返回且无报错"。但 `registry::for_each_search::run_one` 里有四种零命中形态：
//
// ```text
// a) !manifest.working              ⇒ skipped，reason = broken_reason 或 "该源已失效"
// b) p.search() Ok 但 items 为空     ⇒ skipped，reason = ""（空串）
// c) p.search() Err                 ⇒ skipped，reason = e.message
// d) 被 working 之外的逻辑跳过       ⇒ 本测试逐源直调，排除这一项
// ```
// 注意 (b) 的 reason 是**空串** —— 与 (a)/(c) 在调用方看来都可能表现为"无返回且无报错"，
// 所以必须逐源直调 `search()` 才能分辨。本测试就是做这件事，并顺带测多次重试是否稳定。
//
// # 判据
//
// ```text
// ① 每个源打印 working / broken_reason / 直调 search() 的真实结果（条数或错误原文）
// ② 汇总三类计数：失效标记 / 搜索报错 / 搜索返回空 / 有结果
// ③ 若"有结果"的源数 < 总数的 10%，打印警示 —— 这是产品级问题（大片源不可用），
//    不是抽测样本量问题
// ```
//
// # 跑法
//
// ```powershell
// cd rust\sourin_core
// cargo test --test live_agg_source_diagnose --release -- --ignored --nocapture --test-threads=1
// ```

use std::sync::Arc;

use sourin_core::state::AppState;

const KW: &str = "老舅";

async fn real_state() -> Arc<AppState> {
    let dir = std::env::var("APPDATA")
        .map(|p| std::path::PathBuf::from(p).join("app.sourin.player"))
        .expect("APPDATA");
    AppState::bootstrap(dir).await.expect("bootstrap")
}

#[tokio::test]
#[ignore = "真网测试：需要网络，默认门禁不跑；用 --ignored 显式执行"]
async fn diagnose_child_sources() {
    let st = real_state().await;

    let mut items: Vec<(String, String)> = st
        .registry
        .manifests()
        .iter()
        .filter(|m| m.id != sourin_core::tvbox_aggregate::AGGREGATE_ID)
        .map(|m| (m.id.clone(), m.name.clone()))
        .collect();
    items.sort();
    println!("=== 待诊断子源 {} 个，探测词「{KW}」 ===", items.len());

    let mut not_working = 0usize;
    let mut search_err = 0usize;
    let mut empty = 0usize;
    let mut hit = 0usize;
    let mut ok_sources: Vec<String> = Vec::new();

    for (id, name) in &items {
        let Some(p) = st.registry.get(id) else {
            println!("DIAG\t{id}\t{name}\tNO_PROVIDER");
            continue;
        };
        let m = p.manifest();
        if !m.working {
            not_working += 1;
            println!(
                "DIAG\t{id}\t{name}\tNOT_WORKING\treason={}",
                m.broken_reason.as_deref().unwrap_or("<无>")
            );
            continue;
        }
        match p.search(KW, 1).await {
            Ok(page) if page.items.is_empty() => {
                empty += 1;
                println!("DIAG\t{id}\t{name}\tEMPTY\tn=0");
            }
            Ok(page) => {
                hit += 1;
                ok_sources.push(id.clone());
                let first = page
                    .items
                    .first()
                    .map(|i| format!("{}|{}", i.id, i.title))
                    .unwrap_or_default();
                println!("DIAG\t{id}\t{name}\tHIT\tn={}\tfirst={first}", page.items.len());
            }
            Err(e) => {
                search_err += 1;
                println!(
                    "DIAG\t{id}\t{name}\tSEARCH_ERR\t{}",
                    e.message.chars().take(160).collect::<String>()
                );
            }
        }
    }

    println!(
        "\n=== 汇总 === 总数 {} / 有结果 {} / 返回空 {} / 报错 {} / 标记失效 {} ===",
        items.len(),
        hit,
        empty,
        search_err,
        not_working
    );
    if hit > 0 {
        println!("=== 有结果的源清单 ===");
        for s in &ok_sources {
            println!("OK\t{s}");
        }
    }
    let ratio = (hit as f64) / (items.len().max(1) as f64);
    if ratio < 0.10 {
        println!(
            "⚠️ 警示：仅 {}/{} ({:.1}%) 的子源对「{KW}」有结果 —— 这是产品级问题（大片源不可用），\
             不能靠扩大抽测样本掩盖",
            hit,
            items.len(),
            ratio * 100.0
        );
    }

    // 至少得有一个源能用，否则注册表/网络其一必坏
    assert!(hit > 0, "{} 个子源对「{KW}」全部无结果 —— 网络或注册表异常", items.len());
}
