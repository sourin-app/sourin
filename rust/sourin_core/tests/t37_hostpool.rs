// ═══════════════════════════════════════════════════════════════════════
//  域名池选路 —— 行为测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 这些测试在防什么
//
// ```text
// 域名池最容易写错的地方不是「能不能选」，而是**选路的稳定性**：
//   · 每次调用都重新随机选 ⇒ 缓存/会话/登录态反复失效（用户感觉「老是掉线」）
//   · 一次失败就永久拉黑 ⇒ 偶发抖动被当成永久故障（用户感觉「换了个源就再也回不来」）
//   · 冷却后清零 ⇒ 刚恢复的坏域名立刻被重选，来回撞墙
// ```
// ⇒ 下面每条测试对应其中一个失败模式，不是「测覆盖率」。

use sourin_core::hostpool::{
    HostPool, HostPools, COOLDOWN_AFTER_FAILURES, COOLDOWN_SECS,
};

/// 造一个池（域名一律用 example.com —— t98 门禁扫 .rs，不许写真实站名）
fn pool() -> HostPool {
    HostPool::from_hosts(vec![
        "https://a.example.com".into(),
        "https://b.example.com".into(),
        "https://c.example.com".into(),
    ])
}

// ─────────────────── 基本行为 ───────────────────

#[test]
fn empty_pool_returns_none() {
    let mut p = HostPool::default();
    assert_eq!(p.pick(0), None);
}

#[test]
fn first_pick_takes_declared_order() {
    let mut p = pool();
    assert_eq!(p.pick(0).as_deref(), Some("https://a.example.com"));
}

#[test]
fn hosts_are_deduped_and_trimmed() {
    let p = HostPool::from_hosts(vec![
        "https://a.example.com/".into(),
        "  https://a.example.com  ".into(),
        "".into(),
        "https://b.example.com".into(),
    ]);
    assert_eq!(
        p.hosts,
        vec!["https://a.example.com", "https://b.example.com"]
    );
}

// ─────────────────── 稳定性：成功要锁定 ───────────────────

#[test]
fn success_locks_current_and_does_not_jitter() {
    let mut p = pool();
    let h = p.pick(0).unwrap();
    p.record_success(&h);
    // 连选 10 次都必须是同一个 —— 抖动会让缓存/会话失效
    for _ in 0..10 {
        assert_eq!(p.pick(0).as_deref(), Some(h.as_str()));
    }
}

#[test]
fn failure_switches_away_from_current() {
    let mut p = pool();
    let h = p.pick(0).unwrap();
    assert_eq!(h, "https://a.example.com");

    // 失败到进冷却
    for i in 0..COOLDOWN_AFTER_FAILURES {
        p.record_failure(&h, 0);
        if i + 1 < COOLDOWN_AFTER_FAILURES {
            // 还没进冷却 ⇒ 仍锁定它（一次失败不该立刻换）
            assert_eq!(p.pick(0).as_deref(), Some(h.as_str()));
        }
    }
    // 进冷却了 ⇒ 必须换走
    let next = p.pick(0).unwrap();
    assert_ne!(next, h, "进冷却后必须切到别的域名");
}

// ─────────────────── ★ 关键：冷却后减半而不是清零 ───────────────────

#[test]
fn cooldown_recovery_halves_failures_not_clears() {
    let mut p = pool();
    let h = "https://a.example.com";
    for _ in 0..COOLDOWN_AFTER_FAILURES {
        p.record_failure(h, 0);
    }
    assert_eq!(p.states[h].failures, COOLDOWN_AFTER_FAILURES);

    // 冷却到期
    p.revive_cooled(COOLDOWN_SECS + 1);

    // ★ 减半，不是清零 —— 清零会让它立刻被重选、马上又失败
    assert_eq!(
        p.states[h].failures,
        COOLDOWN_AFTER_FAILURES / 2,
        "冷却恢复必须是 failures 减半，不是清零"
    );
    assert!(!p.states[h].cooling(COOLDOWN_SECS + 1));
}

#[test]
fn revived_host_ranks_behind_healthy_one() {
    let mut p = pool();
    let bad = "https://a.example.com";
    for _ in 0..COOLDOWN_AFTER_FAILURES {
        p.record_failure(bad, 0);
    }
    p.revive_cooled(COOLDOWN_SECS + 1);
    // 减半后仍有失败记录 ⇒ 应排在零失败的 b 之后
    let picked = p.pick(COOLDOWN_SECS + 1).unwrap();
    assert_ne!(picked, bad, "刚恢复的坏域名不该被优先选回");
}

// ─────────────────── 保证总有可用 ───────────────────

#[test]
fn all_cooling_still_returns_something() {
    let mut p = pool();
    for h in [
        "https://a.example.com",
        "https://b.example.com",
        "https://c.example.com",
    ] {
        for _ in 0..COOLDOWN_AFTER_FAILURES {
            p.record_failure(h, 0);
        }
    }
    // 全在冷却，但**不能返回 None** —— 那会让用户以为源彻底没救
    assert!(p.pick(0).is_some(), "全部冷却时仍须给出一个候选");
}

#[test]
fn all_cooling_picks_fewest_failures() {
    let mut p = pool();
    // a 失败 5 次，b 失败 3 次（刚进冷却），c 失败 3 次
    for _ in 0..5 {
        p.record_failure("https://a.example.com", 0);
    }
    for _ in 0..3 {
        p.record_failure("https://b.example.com", 0);
    }
    for _ in 0..3 {
        p.record_failure("https://c.example.com", 0);
    }
    let picked = p.pick(0).unwrap();
    assert_ne!(picked, "https://a.example.com", "全冷却时应选失败最少的");
}

// ─────────────────── 插件换列表时同步 ───────────────────

#[test]
fn sync_hosts_keeps_surviving_state() {
    let mut p = pool();
    p.record_failure("https://b.example.com", 0);
    p.record_success("https://a.example.com");

    // 插件去掉 c、加了 d
    p.sync_hosts(vec![
        "https://a.example.com".into(),
        "https://b.example.com".into(),
        "https://d.example.com".into(),
    ]);

    // b 的失败记忆要保住（插件只是加了镜像，不该忘掉哪个坏了）
    assert_eq!(p.states["https://b.example.com"].failures, 1);
    assert!(!p.states.contains_key("https://c.example.com"));
}

#[test]
fn sync_hosts_clears_current_if_removed() {
    let mut p = pool();
    p.record_success("https://a.example.com");
    p.sync_hosts(vec!["https://b.example.com".into()]);
    assert_eq!(p.current, None, "当前域名被移除后必须清空，不能指向不存在的");
}

// ─────────────────── 落盘 ───────────────────

#[test]
fn save_load_roundtrip_preserves_failures() {
    let dir = std::env::temp_dir().join(format!("hostpool-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let mut all = HostPools::default();
    let mut p = pool();
    for _ in 0..2 {
        p.record_failure("https://b.example.com", 0);
    }
    p.record_success("https://a.example.com");
    all.pools.insert("demo".into(), p);

    sourin_core::hostpool::save(&dir, &all).unwrap();
    let back = sourin_core::hostpool::load(&dir);

    let rp = &back.pools["demo"];
    assert_eq!(rp.states["https://b.example.com"].failures, 2, "失败计数必须跨重启保留");
    assert_eq!(rp.current.as_deref(), Some("https://a.example.com"));

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn load_missing_file_returns_empty_not_panic() {
    let dir = std::env::temp_dir().join("hostpool-does-not-exist-xyz");
    let all = sourin_core::hostpool::load(&dir);
    assert!(all.pools.is_empty());
}

#[test]
fn load_corrupt_file_returns_empty_not_panic() {
    let dir = std::env::temp_dir().join(format!("hostpool-corrupt-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(sourin_core::hostpool::pool_file(&dir), "{ not json").unwrap();

    let all = sourin_core::hostpool::load(&dir);
    assert!(all.pools.is_empty(), "坏 JSON 必须降级为空，不能崩");

    let _ = std::fs::remove_dir_all(&dir);
}


// ─────────── ★ 确定性：相同输入必须得到相同选路 ───────────
//
// # 为什么要单独钉这个
//
// 如果选路按单键排序且遍历 `states`（map），
// failures 相同的域名顺序就依赖容器遍历，
// 于是「同样的输入，不同的选路」—— 难复现的 bug。
//
// 当前实现遍历的是**有序的** `self.hosts`（Vec，插件声明顺序），
// 且比较用严格 `<`（不是 `<=`），所以平局时**保留先遇到的**，
// 即插件给的优先级。这条测试把它钉住。
#[test]
fn pick_is_deterministic_when_failures_tie() {
    // 同样的输入重复构造并选路 200 次，必须次次相同
    let mut seen = std::collections::HashSet::new();
    for _ in 0..200 {
        let mut p = pool();
        // 三个域名失败数完全相同（1）
        for h in [
            "https://a.example.com",
            "https://b.example.com",
            "https://c.example.com",
        ] {
            p.record_failure(h, 0);
        }
        seen.insert(p.pick(0).unwrap());
    }
    assert_eq!(
        seen.len(),
        1,
        "失败数相同时选路必须确定（按插件声明顺序），实测出现了多种结果：{seen:?}"
    );
    // 并且应当是声明顺序最前的那个
    assert_eq!(seen.into_iter().next().unwrap(), "https://a.example.com");
}

#[test]
fn pick_all_cooling_is_deterministic_too() {
    // 全冷却且失败数相同 ⇒ 第三档选路也必须确定
    let mut seen = std::collections::HashSet::new();
    for _ in 0..200 {
        let mut p = pool();
        for h in [
            "https://a.example.com",
            "https://b.example.com",
            "https://c.example.com",
        ] {
            for _ in 0..COOLDOWN_AFTER_FAILURES {
                p.record_failure(h, 0);
            }
        }
        seen.insert(p.pick(0).unwrap());
    }
    assert_eq!(seen.len(), 1, "全冷却且失败数相同时选路必须确定");
}
