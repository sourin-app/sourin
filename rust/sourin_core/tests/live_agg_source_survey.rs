// ═══════════════════════════════════════════════════════════════════════
//  聚合子源全覆盖普查（Owner 2026-10-30 要求：每个子源都要找三条实机播）
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景
//
// 上一轮 `play-audit-2026-10-30.md` 只有 16 条记录，抽测面集中在少数"能返回结果"的子源。
// Owner 指出："聚合源里面的每个你都找了三个然后实机测试播放了吗？没有吧"。
// 本测试把**每个子源各自的真实检索结果**全部打出，作为实机抽测的候选来源，
// 避免再用"少数源的代表性抽样"冒充"全覆盖"。
//
// # 为什么这一步只做检索、不做播放
//
// 播放必须走遥控 API 在**运行中的 App** 里做（真机判据），不能在测试进程里假装。
// 所以本测试产出候选清单（provider / id / title / 是否命中），
// 由 `.probe/play-driver/` 逐条 drive 到 App 里播。
//
// # 判据（禁止假绿）
//
// ```text
// ① 子源总数必须 > 1              —— 否则注册表是空的，"普查"无意义
// ② 有命中的源数与报错源数必须打印  —— 区分"该源没这类内容"与"该源挂了"
// ③ 全部零命中 ⇒ 红                —— 那不可能是真实状态
// ```
//
// # 跑法
//
// ```powershell
// cd rust\sourin_core
// cargo test --test live_agg_source_survey --release -- --ignored --nocapture --test-threads=1
// ```

use std::sync::Arc;

use sourin_core::state::AppState;

/// 探测词：覆盖剧集/电影两类，且至少一个是 Owner 现场用过的（老舅、兰香如故）
const PROBES: [&str; 4] = ["老舅", "兰香如故", "庆余年", "流浪地球"];

async fn real_state() -> Arc<AppState> {
    let dir = std::env::var("APPDATA")
        .map(|p| std::path::PathBuf::from(p).join("app.sourin.player"))
        .expect("APPDATA");
    AppState::bootstrap(dir).await.expect("bootstrap")
}

#[tokio::test]
#[ignore = "真网测试：需要网络，默认门禁不跑；用 --ignored 显式执行"]
async fn survey_every_child_source() {
    let st = real_state().await;

    // ① 全部已注册子源（排除聚合源自身）
    let manifests = st.registry.manifests();
    let mut child_ids: Vec<String> = manifests
        .iter()
        .map(|m| m.id.clone())
        .filter(|id| id != sourin_core::tvbox_aggregate::AGGREGATE_ID)
        .collect();
    child_ids.sort();
    println!("=== 子源总数 = {} ===", child_ids.len());
    for id in &child_ids {
        let name = manifests
            .iter()
            .find(|m| &m.id == id)
            .map(|m| m.name.clone())
            .unwrap_or_default();
        println!("CHILD\t{id}\t{name}");
    }
    assert!(child_ids.len() > 1, "注册表里只有一个源 ⇒ 普查无意义");

    // ② 逐个探测词做跨源搜索，按 provider 归类命中
    //    key = provider_id, value = (provider_name, hit_count, samples)
    let mut per_source: std::collections::BTreeMap<String, (String, usize, Vec<String>)> =
        std::collections::BTreeMap::new();
    let mut ever_hit: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut ever_err: std::collections::BTreeMap<String, String> = std::collections::BTreeMap::new();

    for kw in PROBES {
        println!("\n--- 探测词：{kw} ---");
        let r = st.registry.search_all(kw, 1).await;
        for (pid, pname, page) in &r.results {
            let n = page.items.len();
            let e = per_source
                .entry(pid.clone())
                .or_insert_with(|| (pname.clone(), 0, Vec::new()));
            e.1 += n;
            for it in page.items.iter().take(3) {
                if e.2.len() < 6 {
                    e.2.push(format!("{kw}|{}|{}", it.id, it.title));
                }
            }
            ever_hit.insert(pid.clone());
            println!("HIT\t{pid}\t{kw}\tn={n}");
        }
        for (pid, reason) in &r.skipped {
            ever_err.insert(pid.clone(), reason.clone());
            println!("SKIP\t{pid}\t{kw}\t{}", reason.chars().take(100).collect::<String>());
        }
    }

    // ③ 汇总：每个有命中的子源的候选（供实机抽测）
    println!("\n=== 汇总：有命中的子源 ===");
    for (pid, (pname, total, samples)) in &per_source {
        println!("CAND\t{pid}\t{pname}\ttotal={total}");
        for s in samples {
            println!("  SAMPLE\t{pid}\t{s}");
        }
    }
    println!("\n=== 汇总：全程零命中的子源 ===");
    let mut zero: Vec<&String> = child_ids.iter().filter(|id| !ever_hit.contains(*id)).collect();
    zero.sort();
    for id in &zero {
        let why = ever_err.get(*id).map(|s| s.as_str()).unwrap_or("<无返回且无报错>");
        println!("ZERO\t{id}\t{}", why.chars().take(80).collect::<String>());
    }
    println!(
        "\n=== 统计 === 子源 {} / 有命中 {} / 零命中 {} ===",
        child_ids.len(),
        ever_hit.len(),
        zero.len()
    );

    assert!(
        !ever_hit.is_empty(),
        "所有子源对全部探测词都零命中 —— 这不可能是真实状态（要么网络断了，要么注册表空了）"
    );
}
