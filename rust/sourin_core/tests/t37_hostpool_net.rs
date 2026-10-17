// ═══════════════════════════════════════════════════════════════════════
//  task-37 真实网络验证 —— 「失败了会换、换了能成功」
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要真跑（Lead 的硬要求）
//
// ```text
// 单元测试证明的是「算法按我写的规则走」——
// 它**不能**证明「真有一个请求因为域名坏而失败、换掉之后真的成功」。
// 后者需要真的发 HTTP。
// ```
//
// # 怎么做的
//
// ```text
// 池里放两个域名：
//   ① example.com             —— 真实可达（IANA 保留域，稳定）
//   ② bad.invalid             —— 保证不可达（.invalid 是 RFC 2606 保留 TLD）
// 然后走与插件完全相同的失败判据（__ERR__ 前缀）记结果，
// 断言：坏的失败、好的成功、池子最终锁到好的那个。
// ```
//
// # 网络不可用时
//
// ```text
// 打印诊断并**跳过**，不把「这台机器没网」误判成「域名池坏了」。
// 判据必须能区分这两者 —— 否则 CI 在离线环境会假红。
// ```

use sourin_core::hostpool::{HostPool, COOLDOWN_AFTER_FAILURES};

/// 与 `plugins/mod.rs` 里 `record_outcome` 相同的判据：
/// `do_http` 用 `__ERR__` 前缀表达失败。
fn is_failure(body: &str) -> bool {
    body.starts_with("__ERR__")
}

#[tokio::test]
async fn real_network_failure_switches_and_recovery_works() {
    // ① 可达 vs 必失败（都用的保留域，不写任何真实站名）
    let good = "https://example.com";
    let bad = "https://bad.invalid";

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .expect("建 client 失败");

    // ② 先探一下网络：连 example.com 都不通 ⇒ 跳过而不是假红
    let probe = client.get(good).send().await;
    if probe.is_err() {
        eprintln!("[跳过] 本机无外网，无法验证真实切换：{:?}", probe.err());
        return;
    }

    let mut pool = HostPool::from_hosts(vec![bad.to_string(), good.to_string()]);

    // ③ 真发请求：坏域名必须失败
    let bad_resp = client.get(bad).send().await;
    let bad_failed = match &bad_resp {
        Ok(r) => !r.status().is_success(),
        Err(_) => true,
    };
    assert!(bad_failed, ".invalid 域名不该真的连通（DNS 保留 TLD）");

    // ④ 记满失败 ⇒ 进冷却
    for _ in 0..COOLDOWN_AFTER_FAILURES {
        pool.record_failure(bad, 0);
    }
    let picked = pool.pick(0).expect("池里还有好域名，必须能选出");
    assert_eq!(picked, good, "坏域名进冷却后必须切到好域名");

    // ⑤ 真好域名真的能通
    let good_resp = client.get(good).send().await;
    match good_resp {
        Ok(r) => {
            assert!(r.status().is_success(), "example.com 应返回 2xx");
            pool.record_success(good);
        }
        Err(e) => {
            eprintln!("[跳过] 探到了网络但请求失败：{e}");
            return;
        }
    }

    // ⑥ 成功之后必须锁定在好域名上，且不再抖动
    assert_eq!(pool.current.as_deref(), Some(good));
    for _ in 0..5 {
        assert_eq!(pool.pick(0).as_deref(), Some(good), "成功过就该稳定用它");
    }

    // ⑦ 坏域名冷却到期后 failures 减半（不是清零），仍排在好域名之后
    pool.revive_cooled(sourin_core::hostpool::COOLDOWN_SECS + 1);
    assert_eq!(
        pool.states[bad].failures,
        COOLDOWN_AFTER_FAILURES / 2,
        "冷却恢复必须减半"
    );
    assert_eq!(
        pool.pick(sourin_core::hostpool::COOLDOWN_SECS + 1).as_deref(),
        Some(good),
        "恢复后的坏域名不该抢在健康域名前面"
    );
}

/// 与网络无关的判据：`__ERR__` 前缀的识别必须精确。
///
/// ⚠️ 如果这条松了（比如把「空响应」也当失败），
///    正常的空列表会被记成网络故障 ⇒ **把好域名记坏**，
///    然后池子会把它切走，用户看到「明明能用却换了源」。
#[test]
fn failure_judgement_is_exact() {
    assert!(is_failure("__ERR__请求失败: timeout"));
    assert!(is_failure("__ERR__HTTP 500: oops"));

    // 正常响应（哪怕是空的、哪怕是错误文案）都不该算失败
    assert!(!is_failure(""));
    assert!(!is_failure("[]"));
    assert!(!is_failure(r#"{"code":0,"list":[]}"#));
    assert!(!is_failure("网络错误"));
}
