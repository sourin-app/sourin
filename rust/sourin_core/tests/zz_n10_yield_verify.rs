// ═══════════════════════════════════════════════════════════════════════
// N10 独立验证：seek 让路窗口**真的**让出了带宽吗？
// ═══════════════════════════════════════════════════════════════════════
//
// # 这份测试要回答的问题（Lead 2026-10-18 派给 playback-fix）
//
// ```text
// perf-player 的 7 条门禁（test/zz_t66_prefetch_yield_test.dart）全是**源码断言**：
//   ① seek 路径上调了 _beginPrefetchYield()
//   ② 定时器到点调了 endYieldForSeek()
//   ③ 用 first 判据避免叠定时器
//   ④ dispose 取消定时器
//   ⑤ Rust 侧恢复读回原值
//   ⑥ 两侧窗口长度一致
//   ⑦ 窗口内 prefetch_is_disabled() 返回 true
// ⇒ 它们证明的是「代码接线正确」，**证明不了「用户感受到的卡顿变短了」**。
// ★ 所以必须独立验证**行为**。
// ```
//
// # 判据（本测试要产出的那个数）
//
// ```text
// 场景：预取已经启动（占着带宽），此时前台来要数据。
//   A 组（让路生效）：前台读取**不被预取抢带宽** ⇒ 快
//   B 组（让路关闭）：前台读取与预取**抢同一条上游** ⇒ 慢
//
// ★ 本测试用**确定性限速上游**（合成数据，无 CDN 噪声），
//   与 `deterministic_before_after_same_upstream_same_throttle` 同一个测试台。
// ```
//
// # 为什么不用 mpv 真机测 buffering
//
// ```text
// · 真机 buffering 受真实网络抖动/上游限速/CDN 影响，同一位置两次读数可差 2~3 倍
//   ⇒ 5 个位置 × 2 组 = 10 个数，噪声可能盖过信号
// · 而这里的"带宽争抢"是让路机制**唯一**的作用原理
//   ⇒ 直接测量它，比测量端到端 buffering 更接近因果
// ★ 但这是**必要条件不是充分条件**：本测试绿 ⇒ 让路真的让开了带宽；
//   它**不**证明用户在 UI 上一定感觉更快（那还需要真机 buffering 读数）。
//   如实记录这个边界。
// ```

use std::sync::Arc;

use axum::body::Body as AxumBody;
use axum::http::{header, Request, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use bytes::Bytes;
use tokio::sync::mpsc;

use sourin_core::streamproxy::StreamProxy;

/// 合成数据规模（足够大，保证预取窗口之外还有数据）
const TOTAL: u64 = 8 * 1024 * 1024;
/// 每次发的块大小
const CHUNK: usize = 64 * 1024;
/// 每块延迟 ⇒ 单连接限速 ≈ 64KB/50ms = 1280 KB/s
///
/// ⚠️ 取 50ms 而不是 100ms：让"预取占满 4 条并发"的总带宽
///    明显高于前台单连接，否则争抢效应太小、读数分不开。
const CHUNK_DELAY_MS: u64 = 50;

fn byte_at(i: u64) -> u8 {
    ((i.wrapping_mul(31)).wrapping_add((i >> 8).wrapping_mul(17)) & 0xFF) as u8
}

/// ★★ 限速上游：**共享带宽**（全局令牌桶），不是每连接各自限速
///
/// # 为什么必须共享
/// ```text
/// 第一版我用"每块 sleep 50ms"⇒ 那是**每条连接各自限速**。
/// 于是预取的 4 条并行连接**不会**分走前台那条连接的份额
/// ⇒ 实测让路关闭 497ms vs 生效 499ms，**根本没有差别**
/// ⇒ 那个测试台测不出让路的收益 —— 限速模型错了，不是代码错了。
///
/// 真实网络是一根共享的管子：预取多占一份，前台就少一份。
/// ⇒ 用一个**全局**令牌桶，所有连接从同一个桶里取字节。
/// ```
struct SharedThrottle {
    /// 整条管子的速率（所有连接共享）
    bytes_per_sec: u64,
    /// ★ 管子"忙到什么时候"—— 每个块在这里排队领自己的时间片
    ///
    /// # 为什么不能用"累计已发字节 / 速率"算配速（第一版就是这么写的，错了）
    /// ```text
    /// 那版：due = sent_total / rate；sent_total 只增不减
    /// ⇒ 第 N 个请求永远要等到 (所有历史字节/速率) 之后
    /// ⇒ **顺序效应**：后测的那组一定更慢
    /// ⇒ 实测让路关闭 12193ms、生效 17994ms，"差异"完全是这个假象
    /// ★ 这不是被测代码的问题，是我的限速模型错了。
    /// ```
    /// 正确模型：**管道串行化** —— 每个块领一个时间片，片与片首尾相接。
    /// 没有历史欠账，只有真实的占用。
    next_free: tokio::sync::Mutex<std::time::Instant>,
}

impl SharedThrottle {
    fn new(bytes_per_sec: u64) -> Self {
        Self {
            bytes_per_sec,
            next_free: tokio::sync::Mutex::new(std::time::Instant::now()),
        }
    }

    /// 为 `n` 字节领一个时间片，等它过去
    async fn wait_for(&self, n: u64) {
        let dur = std::time::Duration::from_millis(
            (n as u128 * 1000 / self.bytes_per_sec as u128) as u64,
        );
        let done_at = {
            let mut nx = self.next_free.lock().await;
            let now = std::time::Instant::now();
            let start = (*nx).max(now);
            let end = start + dur;
            *nx = end;
            end
        };
        // 等到这一片"发完"
        tokio::time::sleep_until(tokio::time::Instant::from_std(done_at)).await;
    }
}

/// 限速上游：支持 Range，从**共享**令牌桶取额度
async fn serve_throttled(
    axum::extract::State(thr): axum::extract::State<Arc<SharedThrottle>>,
    req: Request<AxumBody>,
) -> Response {
    let (start, end) = req
        .headers()
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(|r| {
            let r = r.strip_prefix("bytes=")?;
            let (a, b) = r.split_once('-')?;
            Some((
                a.trim().parse::<u64>().ok()?,
                b.trim().parse::<u64>().ok()?.min(TOTAL - 1),
            ))
        })
        .unwrap_or((0, TOTAL - 1));

    let (tx, rx) = mpsc::channel::<Result<Bytes, std::io::Error>>(2);
    tokio::spawn(async move {
        let mut pos = start;
        while pos <= end {
            let n = CHUNK.min((end - pos + 1) as usize);
            // ★ 共享额度：所有连接在这里排队
            thr.wait_for(n as u64).await;
            let buf: Vec<u8> = (pos..pos + n as u64).map(byte_at).collect();
            if tx.send(Ok(Bytes::from(buf))).await.is_err() {
                return; // 客户端走了
            }
            pos += n as u64;
        }
    });

    Response::builder()
        .status(StatusCode::PARTIAL_CONTENT)
        .header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{TOTAL}"),
        )
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_TYPE, "video/mp4")
        .body(AxumBody::from_stream(ChannelStream { rx }))
        .unwrap()
        .into_response()
}

/// 把 mpsc::Receiver 包成 Stream（与本文件既有的同名辅助一致）
struct ChannelStream {
    rx: mpsc::Receiver<Result<Bytes, std::io::Error>>,
}

impl futures_core::Stream for ChannelStream {
    type Item = Result<Bytes, std::io::Error>;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        self.rx.poll_recv(cx)
    }
}

// ══════════════════════════════════════════════════════════════════════
//  ★★★ 核心测量：预取在跑时，前台一次 seek 读取要多久
// ══════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn n10_yield_window_really_frees_bandwidth() {
    // 起限速上游
    // ★ 共享带宽：256 KB/s 的管子（预取 4 并发 + 前台 1 条全从这里分）
    let throttle = Arc::new(SharedThrottle::new(256 * 1024));
    let up = Router::new()
        .route("/throttled.mp4", get(serve_throttled))
        .with_state(throttle);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let up_port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let _ = axum::serve(listener, up).await;
    });

    let proxy = Arc::new(StreamProxy::new());
    proxy.ensure_started().await.unwrap();
    let url = format!("http://127.0.0.1:{up_port}/throttled.mp4");
    let local = proxy.register(&url, vec![]);

    let client = reqwest::Client::new();

    /// 一次"前台 seek 读取"：读 512KB（约等于播放器 seek 后要补的那一段）
    async fn seek_read(client: &reqwest::Client, local: &str, from: u64) -> u64 {
        let to = from + 512 * 1024 - 1;
        let sw = std::time::Instant::now();
        let resp = client
            .get(local)
            .header(header::RANGE, format!("bytes={from}-{to}"))
            .send()
            .await
            .unwrap();
        let _ = resp.bytes().await.unwrap();
        sw.elapsed().as_millis() as u64
    }

    /*
     * ────────────────────────────────────────────────────────────────
     * ★★★ 关键设计修正（第一版错了，如实记录）
     * ────────────────────────────────────────────────────────────────
     *
     * # 第一版为什么测不出东西
     * ```text
     * 我起了一个 warm 任务发 bytes=0-8MB 的请求，想让它"预取在跑"。
     * 但 `resp.bytes().await` 会**把 8MB 全读完**才返回
     * ⇒ 它从头到尾占着管道，A 组和 B 组的读数都被它拖慢
     * ⇒ 实测 12216ms / 17996ms 的"差异"只是它和我抢的相对时序
     *    **不是让路的效应**。
     * ⇒ 而且是**顺序效应**：A 组先测，那时 warm 才刚开始；
     *    B 组后测，warm 已经攒了很多待发块 ⇒ B 组必然更慢。
     * ```
     *
     * # 正确的做法
     * ```text
     * 要测的是「**同一时刻**，预取在跑 vs 不在跑，前台一次 seek 读多久」。
     * ⇒ 两组必须**各自独立**地从干净状态开始：
     *    A 组：预取**开启**（会抢带宽）→ 测前台 seek
     *    B 组：预取**关闭**（不抢带宽）→ 测前台 seek
     *    每组前**重新建 proxy**，避免上一组的残留预取污染下一组。
     * ⇒ 这才是"控制变量"：唯一变化的是预取开关。
     * ```
     *
     * ⚠️ 顺序也要**交替**（ON→OFF→ON），取各自最好值，
     *    抵消"谁先跑谁占便宜"这类系统误差。
     */

    /// 建一个全新的 proxy（避免上一组的后台预取残留）
    async fn fresh_proxy(url: &str) -> (Arc<StreamProxy>, String) {
        let p = Arc::new(StreamProxy::new());
        p.ensure_started().await.unwrap();
        let local = p.register(url, vec![]);
        (p, local)
    }

    // ── ON（预取在跑，会抢带宽）──
    let (p_on, l_on) = fresh_proxy(&url).await;
    let on_ms = seek_read(&client, &l_on, 2 * 1024 * 1024).await;

    // ── OFF（预取关闭，不抢带宽）──
    let (p_off, l_off) = fresh_proxy(&url).await;
    p_off.set_prefetch_disabled(true);
    let off_ms = seek_read(&client, &l_off, 2 * 1024 * 1024).await;

    // ── 再一次 ON（交替，抵消顺序效应）──
    let (p_on2, l_on2) = fresh_proxy(&url).await;
    let on2_ms = seek_read(&client, &l_on2, 2 * 1024 * 1024).await;

    // 取两次 ON 的**最好值**（与既有 A/B 测试同一策略）
    let with_prefetch = on_ms.min(on2_ms);
    let no_prefetch = off_ms;

    // ── 让路窗口内的那一次读取（这是 N10 真正要证明的场景）──
    let (p_y, l_y) = fresh_proxy(&url).await;
    p_y.begin_yield_for_seek();
    let yield_ms = seek_read(&client, &l_y, 2 * 1024 * 1024).await;
    p_y.end_yield_for_seek();

    /*
     * ────────────────────────────────────────────────────────────────
     * ② 阳性对照：必须证明"预取真的占了带宽"
     * ────────────────────────────────────────────────────────────────
     *
     * 若两者都是"上限速的理论值"，说明预取根本没在跑 ⇒ 本测试无意义。
     * 理论值：512KB / 64KB = 8 块 × 50ms = 400ms（单连接串行）。
     */
    let single_conn_floor =
        (512 * 1024) as f64 / (256.0 * 1024.0) * 1000.0; // 256KB/s 管子读 512KB
    eprintln!(
        "[N10-YIELD] 共享带宽 256KB/s · 读 512KB · 四组独立起测:
             预取 ON  (会抢带宽) = {with_prefetch}ms  [第1次 {on_ms} / 第2次 {on2_ms}]
             预取 OFF (不抢)     = {no_prefetch}ms
             ★ 让路窗口内       = {yield_ms}ms
             纯带宽理论值       = {single_conn_floor:.0}ms"
    );

    assert!(
        with_prefetch > 0 && no_prefetch > 0 && yield_ms > 0,
        "★ 读数异常（0ms）"
    );

    /*
     * ★ 核心判据：让路窗口内应**接近"预取 OFF"的水平**，而不是"预取 ON"的
     * ```text
     * N10 的设计意图：seek 后 2 秒内预取让开 ⇒ 前台拿到接近独占的带宽
     * ⇒ yield_ms 应当显著小于 with_prefetch（预取在抢的情形）
     * ⇒ 且接近 no_prefetch（预取不在的情形）
     * ```
     */
    eprintln!(
        "[N10-YIELD] 让路相对预取 ON 的改善 = {:.2}x  (yield {yield_ms}ms vs prefetch-on {with_prefetch}ms)",
        with_prefetch as f64 / yield_ms.max(1) as f64
    );
    assert!(
        yield_ms <= with_prefetch,
        "★ 让路窗口内反而比预取全开更慢：yield={yield_ms}ms vs on={with_prefetch}ms"
    );

    /*
     * ★★ 更强的判据：让路窗口内应当**接近预取 OFF 的水平**（不是勉强好一点）
     * ```text
     * 设计意图：seek 后 2 秒内预取**完全让开** ⇒ 前台拿到接近独占的带宽
     * ⇒ yield_ms 应落在 [off_ms*0.9, off_ms*1.25] 区间内
     *   （下界 0.9：正常抖动；上界 1.25：容忍调度噪声）
     * ★ 若 yield_ms 只有"比 ON 好一点点"（比如 2400ms），
     *   说明让路只让了一部分 ⇒ 实现有缺陷
     * ```
     */
    let lo = (no_prefetch as f64 * 0.90) as u64;
    let hi = (no_prefetch as f64 * 1.25) as u64;
    assert!(
        yield_ms >= lo && yield_ms <= hi,
        "★★ 让路窗口内没有回到\"预取关闭\"的水平：
             yield = {yield_ms}ms
             预取OFF = {no_prefetch}ms（期望区间 {lo}~{hi}ms）
             ⇒ 让路只让开了一部分，或根本没让开"
    );

    // ★ 佐证：让路应当确实比"预取在抢"快（定量改善）
    assert!(
        with_prefetch > yield_ms,
        "★ 让路没有带来任何改善：on={with_prefetch}ms vs yield={yield_ms}ms"
    );
}

// ══════════════════════════════════════════════════════════════════════
//  N10 的**已知代价**：让路窗口内连续做远端 seek 会不会变慢？
// ══════════════════════════════════════════════════════════════════════

/// # 这条测什么（Lead 特别要求量化）
/// ```text
/// 方案 A 让 seek 后 2 秒关闭预取。
/// 若用户在 2 秒内**连续**做远端 seek：
///   第 1 次 seek 进入让路窗口；
///   第 2、3 次仍在窗口内 ⇒ 预取一直关着 ⇒ 会不会反而更慢？
///
/// perf-player 给的数据：远端 seek ON=162ms vs OFF=190ms
/// ⇒ 说明**远端**场景预取是有益的 ⇒ 让路对它有害
/// ⇒ 要量化"害多少"
/// ```
#[tokio::test]
async fn n10_consecutive_remote_seeks_cost_during_yield() {
    // 起共享带宽上游
    let throttle = Arc::new(SharedThrottle::new(256 * 1024));
    let up = Router::new()
        .route("/throttled.mp4", get(serve_throttled))
        .with_state(throttle);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let up_port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let _ = axum::serve(listener, up).await;
    });
    let url = format!("http://127.0.0.1:{up_port}/throttled.mp4");
    let client = reqwest::Client::new();

    /// 连续 3 次远端 seek（每次读 256KB，模拟 seek 后补数据）
    async fn three_seeks(client: &reqwest::Client, local: &str) -> u64 {
        let sw = std::time::Instant::now();
        for i in 0..3u64 {
            let from = (i + 1) * 1024 * 1024;
            let to = from + 256 * 1024 - 1;
            let resp = client
                .get(local)
                .header(header::RANGE, format!("bytes={from}-{to}"))
                .send()
                .await
                .unwrap();
            let _ = resp.bytes().await.unwrap();
        }
        sw.elapsed().as_millis() as u64
    }

    // ── 不在让路窗口内（预取正常）──
    let p_off = Arc::new(StreamProxy::new());
    p_off.ensure_started().await.unwrap();
    let l_off = p_off.register(&url, vec![]);
    let no_yield = three_seeks(&client, &l_off).await;

    // ── 全程在让路窗口内（模拟 2 秒内连点 3 次）──
    let p_y = Arc::new(StreamProxy::new());
    p_y.ensure_started().await.unwrap();
    let l_y = p_y.register(&url, vec![]);
    p_y.begin_yield_for_seek();
    // 每次 seek 之间重置窗口（模拟"每次 seek 都调 begin"，这是真实 UI 行为）
    let sw = std::time::Instant::now();
    for i in 0..3u64 {
        p_y.begin_yield_for_seek();
        let from = (i + 1) * 1024 * 1024;
        let to = from + 256 * 1024 - 1;
        let resp = client
            .get(&l_y)
            .header(header::RANGE, format!("bytes={from}-{to}"))
            .send()
            .await
            .unwrap();
        let _ = resp.bytes().await.unwrap();
    }
    let in_yield = sw.elapsed().as_millis() as u64;
    p_y.end_yield_for_seek();

    let penalty = in_yield as f64 / no_yield.max(1) as f64;
    eprintln!(
        "[N10-YIELD-COST] 连续 3 次远端 seek（每次 256KB）共耗时:
             预取正常        = {no_yield}ms
             全程让路窗口内  = {in_yield}ms
             ★ 代价 = {penalty:.2}x"
    );

    /*
     * ★ 这条**不做强断言**，只记录量级（与 perf-player 的调研测试同一态度）
     *
     * ```text
     * 理由：这个代价是方案 A 的**已知取舍**。
     * 只要"代价 < 收益"就值得，而收益是"改善拖动卡顿"（用户主诉）。
     * 但必须量出来，否则不知道取舍是否合理。
     * ```
     * ⇒ 只挡一个荒谬上界：不能让代价超过 3 倍（那说明让路设计有问题）
     */
    assert!(
        penalty < 3.0,
        "★ 让路让连续远端 seek 慢了 {penalty:.2}x —— 代价过大，需要重新设计"
    );
}

// ══════════════════════════════════════════════════════════════════════
//  让路窗口的**语义**不变量（不涉及计时，纯状态机）
// ══════════════════════════════════════════════════════════════════════
//
// ★ 这两条是故障注入验过的（见交付报告）：
//   把 `prefetch_is_disabled` 里的窗口判断去掉 ⇒ ① 红
//   把 `end_yield_for_seek` 改成无条件置 false ⇒ ② 红

#[tokio::test]
async fn n10_yield_window_state_machine_invariants() {
    let proxy = Arc::new(StreamProxy::new());

    // ① 初始不在窗口内，预取开着
    assert!(!proxy.in_yield_window(), "初始不应在窗口内");
    assert!(!proxy.prefetch_is_disabled_for_probe(), "初始预取应开着");

    // ② 进入窗口 ⇒ 预取判定必须变成"禁用"
    let first = proxy.begin_yield_for_seek();
    assert!(first, "第 1 次进入应返回 true（调用方据此起定时器）");
    assert!(proxy.in_yield_window(), "进入后应在窗口内");
    assert!(
        proxy.prefetch_is_disabled_for_probe(),
        "★ 窗口内 prefetch_is_disabled() 必须为 true —— 这是让路生效的唯一判据"
    );

    // ③ 连续进入（模拟 2 秒内连续拖动）⇒ 不是首次，但仍在窗口内
    let second = proxy.begin_yield_for_seek();
    assert!(!second, "第 2 次应是 false（不要再起第二个定时器）");
    assert!(proxy.in_yield_window(), "连续拖动后仍应在窗口内");

    // ④ 结束 ⇒ 恢复
    proxy.end_yield_for_seek();
    assert!(!proxy.in_yield_window(), "结束后不应在窗口内");
    assert!(
        !proxy.prefetch_is_disabled_for_probe(),
        "结束后预取应恢复为开"
    );
}

/// ★ 让路必须"恢复到进入前的状态"，而不是无条件打开预取
///
/// ```text
/// 用户可能本来就配了 SOURIN_PREFETCH_DISABLE=1（预取本来就是关的）
/// ⇒ 我们的"恢复"若无条件写 false，会**把用户配的关闭状态打开**
/// ⇒ 这是 perf-player 门禁⑤用源码断言验的那条，这里用**行为**再验一次
/// ```
#[tokio::test]
async fn n10_yield_window_restores_previous_state_not_unconditional_on() {
    let proxy = Arc::new(StreamProxy::new());

    // 用户本来就关了预取
    proxy.set_prefetch_disabled(true);
    assert!(proxy.prefetch_is_disabled_for_probe());

    // 让路窗口进 + 出
    proxy.begin_yield_for_seek();
    assert!(proxy.prefetch_is_disabled_for_probe(), "窗口内仍是禁用");
    proxy.end_yield_for_seek();

    // ★ 结束之后必须**仍然是禁用**（用户的配置不能被我们改掉）
    assert!(
        proxy.prefetch_is_disabled_for_probe(),
        "★★ 让路结束把用户配置的'预取关闭'打开了 —— 这是行为回归"
    );
}
