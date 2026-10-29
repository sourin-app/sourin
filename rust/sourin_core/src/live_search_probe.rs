// ═══════════════════════════════════════════════════════════════════════
//  真网络度量：搜「老舅」到底出多少条、按源分布（对标原版 75 条）
// ═══════════════════════════════════════════════════════════════════════
//
// 跑法（需要本机真实数据目录；默认 ignored）：
// ```text
// set SOURIN_LIVE_SEARCH=1 && cargo test --lib live_search_count --release -- --ignored --nocapture
// 可选：SOURIN_DATA_DIR=<数据目录>（默认 %APPDATA%\app.sourin.player）
//       SOURIN_KW=老舅
// ```
//
// 判据（打印给人看，不是断言）：
//   · 每个源各出多少条（用来判断"聚合扇出是否覆盖到足够多的源"）
//   · 聚合那一路（`tvbox_agg`）出了多少条、耗时多少
//   · 总数与"原版 75 条"的差距
#[cfg(test)]
mod live_search_probe {
    #[tokio::test]
    #[ignore = "真网络：需要本机数据目录与已启用源"]
    async fn live_search_count() {
        if std::env::var("SOURIN_LIVE_SEARCH").ok().as_deref() != Some("1") {
            eprintln!("[LIVE] 未设置 SOURIN_LIVE_SEARCH=1 ⇒ 跳过");
            return;
        }
        let kw = std::env::var("SOURIN_KW").unwrap_or_else(|_| "老舅".to_string());
        let dir = std::env::var("SOURIN_DATA_DIR").unwrap_or_else(|_| {
            let base = std::env::var("APPDATA").unwrap_or_default();
            format!("{base}\\app.sourin.player")
        });
        let st = crate::state::AppState::bootstrap(std::path::PathBuf::from(&dir))
            .await
            .expect("bootstrap");
        let manifests = st.registry.manifests();
        eprintln!("[LIVE] 数据目录={dir} 源数={} 关键词={kw}", manifests.len());
        let t0 = std::time::Instant::now();
        let res = st.registry.search_all(&kw, 1).await;
        let elapsed = t0.elapsed();
        let mut total = 0usize;
        for (pid, name, page) in &res.results {
            let n = page.items.len();
            total += n;
            eprintln!("[LIVE]   {pid:<28} {n} 条（{name}）");
        }
        for (pid, why) in &res.skipped {
            eprintln!("[LIVE]   {pid:<28} 跳过：{}", &why[..why.len().min(90)]);
        }
        eprintln!(
            "[LIVE] 合计 {total} 条 / {} 个源有结果 / {} 个源跳过 / 耗时 {:?}",
            res.results.len(),
            res.skipped.len(),
            elapsed
        );
    }
}