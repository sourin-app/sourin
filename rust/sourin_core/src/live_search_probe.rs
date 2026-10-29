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
        let mut per_child: std::collections::BTreeMap<String, usize> =
            std::collections::BTreeMap::new();
        for (pid, name, page) in &res.results {
            let n = page.items.len();
            total += n;
            eprintln!("[LIVE]   {pid:<28} {n} 条（{name}）");
            for it in &page.items {
                let child = it
                    .id
                    .native
                    .split_once("::")
                    .map(|(c, _)| c.to_string())
                    .unwrap_or_else(|| it.id.provider.clone());
                *per_child.entry(child).or_insert(0) += 1;
            }
        }
        eprintln!(
            "[LIVE] ★ 按源分组：{} 个**有结果的源**（原版「全部」是 75 个源）",
            per_child.len()
        );
        for (c, n) in &per_child {
            eprintln!("[LIVE]     {c:<28} {n}");
        }
        let fails = crate::tvbox_aggregate::last_fanout_failures();
        eprintln!("[LIVE] ★ 上一个扇出里失败/超时的子站：{} 个", fails.len());
        let mut by_reason: std::collections::BTreeMap<String, usize> =
            std::collections::BTreeMap::new();
        for (_c, why) in &fails {
            let key: String = why.chars().take(60).collect();
            *by_reason.entry(key).or_insert(0) += 1;
        }
        for (why, n) in by_reason {
            eprintln!("[LIVE]     {n:>3} 个：{why}");
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

        /*
         * ★ 2026-10-29（Owner："右侧没有区分线路、重复集数一大把"）：
         * 把前几个条目的**详情**也打出来 —— 看 episodes 的 flag 分布与 id 形态。
         */
        let mut seen = 0;
        for (_pid, _name, page) in &res.results {
            for it in page.items.iter() {
                if seen >= 3 {
                    break;
                }
                seen += 1;
                match st.registry.route(&it.id) {
                    Some(p) => match p.detail(&it.id).await {
                        Ok(d) => {
                            let mut by_flag: std::collections::BTreeMap<String, usize> =
                                std::collections::BTreeMap::new();
                            for e in &d.episodes {
                                *by_flag.entry(e.flag.clone()).or_insert(0) += 1;
                            }
                            eprintln!(
                                "[LIVE]   详情 {:?} provider={} 集数={} 线路分布={:?}",
                                d.title,
                                it.id.provider,
                                d.episodes.len(),
                                by_flag
                            );
                            if let Some(e) = d.episodes.first() {
                                let head: String = e.id.chars().take(70).collect();
                                eprintln!("[LIVE]     首集 id={head}");
                            }
                        }
                        Err(e) => eprintln!("[LIVE]     detail 失败：{e}"),
                    },
                    None => eprintln!("[LIVE]     route 失败：{}", it.id.provider),
                }
            }
        }
        /*
         * ★ 2026-10-29（Owner："夸克的还是不能播放"）：
         * 从搜索结果里找**把分享页当剧集**的条目，直接把 resolve 那一步跑出来。
         * 只看前 12 个子站（每个子站取第一条），避免把 218 个详情全打一遍。
         */
        if std::env::var("SOURIN_LIVE_SHARE").ok().as_deref() == Some("1") {
            let mut tried_children: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
            let mut found_any = false;
            'outer: for (_pid, _name, page) in &res.results {
                for it in page.items.iter() {
                    let child = it
                        .id
                        .native
                        .split_once("::")
                        .map(|(c, _)| c.to_string())
                        .unwrap_or_else(|| it.id.provider.clone());
                    if tried_children.contains(&child) || tried_children.len() >= 12 {
                        continue;
                    }
                    tried_children.insert(child.clone());
                    let Some(p) = st.registry.route(&it.id) else { continue };
                    let Ok(d) = p.detail(&it.id).await else { continue };
                    for e in &d.episodes {
                        let probe = e.id.clone();
                        let href = if probe.contains("pan.quark.cn/s/") {
                            probe.split("pan.quark.cn/s/").nth(1).map(|s| s.split(|c: char| !c.is_ascii_alphanumeric()).next().unwrap_or("").to_string())
                        } else if probe.contains("drive.uc.cn/s/") {
                            probe.split("drive.uc.cn/s/").nth(1).map(|s| s.split(|c: char| !c.is_ascii_alphanumeric()).next().unwrap_or("").to_string())
                        } else {
                            None
                        };
                        if let Some(sid) = href.filter(|s| !s.is_empty()) {
                            found_any = true;
                            eprintln!("[LIVE] 分享页条目：child={child} 集={:?} share_id={sid}", e.title);
                            let (kind, drive) = if probe.contains("pan.quark.cn") {
                                (crate::pan::PanKind::Quark, crate::csp::pan_drive::PanDrive::with_spec("PanQuark", crate::csp::pan_drive::quark_spec()))
                            } else {
                                (crate::pan::PanKind::Uc, crate::csp::pan_drive::PanDrive::with_spec("PanUC", crate::csp::pan_drive::uc_spec()))
                            };
                            match drive.resolve_share_play(&sid, "").await {
                                Ok(p) => {
                                    eprintln!(
                                        "[LIVE]   ⇒ 解析成功 kind={:?} 直链={}",
                                        kind,
                                        p.url.chars().take(90).collect::<String>()
                                    );
                                    /*
                                     * ★ 关键分界：**拿到地址** ≠ **地址能播**。
                                     * 逐层加请求头，看哪一层才让 CDN 放行（mpv 能不能播就看这个）：
                                     *   ① 裸 GET（Range 0-1）   ② +UA   ③ +UA+Cookie(含 __puus)
                                     */
                                    if let Ok(c) = reqwest::Client::builder()
                                        .no_proxy()
                                        .timeout(std::time::Duration::from_secs(20))
                                        .build()
                                    {
                                        for mode in 0..3 {
                                            let mut rb = c
                                                .get(&p.url)
                                                .header("Range", "bytes=0-1")
                                                .header("Accept", "*/*");
                                            if mode >= 1 {
                                                rb = rb.header("User-Agent", "Mozilla/5.0");
                                            }
                                            if mode >= 2 {
                                                for (k, v) in &p.headers {
                                                    rb = rb.header(k, v);
                                                }
                                            }
                                            match rb.send().await {
                                                Ok(r) => {
                                                    let ct = r
                                                        .headers()
                                                        .get("content-type")
                                                        .and_then(|v| v.to_str().ok())
                                                        .unwrap_or("-")
                                                        .to_string();
                                                    let body = r.text().await.unwrap_or_default();
                                                    eprintln!(
                                                        "[LIVE]     GET mode={mode} status={} ct={ct} body={}",
                                                        if body.is_empty() { "-".to_string() } else { body.chars().take(120).collect::<String>() },
                                                        ""
                                                    );
                                                }
                                                Err(e) => {
                                                    eprintln!("[LIVE]     GET mode={mode} 失败：{e}")
                                                }
                                            }
                                        }
                                    }
                                }
                                Err(err) => eprintln!("[LIVE]   ⇒ 解析失败 kind={:?}：{err}", kind),
                            }
                            if tried_children.len() >= 3 {
                                break 'outer;
                            }
                        }
                    }
                }
            }
            if !found_any {
                eprintln!("[LIVE] 前 12 个子站里没有发现把分享页当剧集的条目");
            }
        }
    }
}