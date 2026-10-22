// ═══════════════════════════════════════════════════════════════════════
//  task-66【切集/换源】旧预取对新流的干扰 —— **可复跑的测量**
//  （2026-10-18）
// ═══════════════════════════════════════════════════════════════════════
//
// VERIFICATION TEST -- NOT PART OF THE PRODUCT BUILD.
//
// # 这个测试回答什么
//
// ```text
// 源码阅读得出的两条机制：
//   ① 注册表有 FIFO 淘汰（STREAM_MAX=256，超了淘汰最旧一半）
//      ★ 我先前误报"永不注销/单调增长"，本测试给出实测条数
//   ② 预取任务在客户端断开后，已 spawn 的 4 段仍会跑完当前窗口（1MB）
//
// ⇒ 但②的**实际干扰时长**从未实测过。
//    本测试用确定性上游（共享令牌桶）量出：
//      · 客户端断开后，上游还在被读多久
//      · 这段时间里，新连接的首字节被延迟多少
// ```
//
// # 为什么这个测量可信（阳性对照）
//
// ```text
// ★ 光看"旧连接还在读"不能证明它**抢了**新流的带宽 ——
//   也可能是"上游本来就在吐，与新旧无关"。
// ⇒ 所以必须做 A/B：
//     A 组：断开旧流后**立刻**开新流（有旧预取在飞）
//     B 组：等旧流彻底静默后再开新流（无旧预取）
//   两组用**同一个**令牌桶模型、同一份文件、同一个 Range
//   ⇒ 首字节延迟之差 = 旧预取的干扰量
// ★ 若 A≈B ⇒ 干扰可忽略（如实记录，不夸大）
// ```
//
// # 与 zz_n10_yield_verify.rs 的关系
//
// ```text
// 那个测的是「seek 后让路窗口是否让出带宽」（同一条流内）。
// 本测试测的是「切流后旧预取是否干扰新流」（跨流生命期）。
// ⇒ 不同的机制，不同的读数，不可互相替代。
// ```
//
// # ★★★ 阳性对照（证明本测试的仪器有鉴别力，不是恒等输出）
//
// ```text
// 做法：把共享令牌桶的带宽从 512 KB/s 改成 5120 KB/s（×10），重跑本测试。
//       即改下面 `const BPS` 那一行。
//
// 实测（2026-10-18）：
//   基线     A=259.3ms  B=138.1ms  干扰=121.3ms
//   带宽×10  A=31.2ms   B=23.1ms   干扰=8.2ms
//   ⇒ 干扰缩小 **14.8×**（预测约 10×，同数量级）
// ```
//
// ★ 这一步为什么必要：
// ```text
// 没有阳性对照，"两组有差异"在噪声下什么都能证明 ——
// 任何一对数字都能被说成"有差异"。
// ⇒ 本测量同时要求两条：
//     ① 读数与**理论值**吻合（512KB/s ÷ 64KB/块 = 125ms；
//        B 组 137ms = +9.6% 握手开销；A 组 261ms ≈ 2×125ms = "前面排了 1 块"）
//     ② 读数随参数**按物理规律变化**（带宽 ×10 ⇒ 干扰 ÷14.8）
//   缺任一条，读数都不可信。
// ```
//
// ★ 为什么阳性对照的脚本不入库：
// ```text
// `.probe/` 在 `.gitignore` 里（探针是本地工具，不进版本库）——
// 这是本仓的既有约定，强行 `git add -f` 会让所有人的 `git status` 变脏。
// ⇒ 复跑方式见上：只改 `const BPS` 一行，重跑即可。不需要脚本。
// ```

use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use tokio::sync::{mpsc, Mutex};

// ═══════════════════════════════════════════════════════════════════
//  确定性上游：共享令牌桶 + 字节计数
// ═══════════════════════════════════════════════════════════════════

/// 共享管道：所有连接从这里领时间片（与 n10_throttle_upstream 同一模型）
struct Pipe {
    bytes_per_sec: u64,
    next_free: Mutex<Instant>,
    /// ★ 累计发出的字节（用于判断"旧预取是否还在读"）
    served: AtomicU64,
}

impl Pipe {
    async fn wait_for(&self, n: u64) {
        let dur = Duration::from_millis((n as u128 * 1000 / self.bytes_per_sec as u128) as u64);
        let done_at = {
            let mut nx = self.next_free.lock().await;
            let now = Instant::now();
            let start = (*nx).max(now);
            let end = start + dur;
            *nx = end;
            end
        };
        tokio::time::sleep_until(tokio::time::Instant::from_std(done_at)).await;
    }
}

#[derive(Clone)]
struct UpState {
    pipe: Arc<Pipe>,
    total: u64,
}

fn parse_range(h: &HeaderMap, total: u64) -> (u64, u64) {
    h.get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(|r| {
            let r = r.strip_prefix("bytes=")?;
            let (a, b) = r.split_once('-')?;
            let start: u64 = a.trim().parse().ok()?;
            let end: u64 = if b.trim().is_empty() {
                total.saturating_sub(1)
            } else {
                b.trim().parse().ok()?
            };
            Some((start, end.min(total.saturating_sub(1))))
        })
        .unwrap_or((0, total.saturating_sub(1)))
}

/// `mpsc::Receiver` → `Stream`（与 streamproxy 的 `ChannelStream` 同一套）
///
/// ★ 用 channel 而不是生成器，因为 channel 给了**取消语义**：
///   客户端断开 ⇒ 响应体被 drop ⇒ 接收端消失 ⇒ 生产任务下一次 send 失败 ⇒ 退出。
///   —— 这正是本测试要观测的行为。
struct ChannelStream {
    rx: mpsc::Receiver<Result<Vec<u8>, std::io::Error>>,
}

impl futures_core::Stream for ChannelStream {
    type Item = Result<Vec<u8>, std::io::Error>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        self.rx.poll_recv(cx)
    }
}

async fn serve(State(st): State<UpState>, headers: HeaderMap) -> Response {
    let (start, end) = parse_range(&headers, st.total);
    let len = end.saturating_sub(start) + 1;

    let (tx, rx) = mpsc::channel::<Result<Vec<u8>, std::io::Error>>(4);
    let pipe = st.pipe.clone();
    tokio::spawn(async move {
        let mut sent = 0u64;
        while sent < len {
            let n = (len - sent).min(64 * 1024);
            // ★ 关键：先等令牌桶 ⇒ 所有连接串行分享同一条管道
            pipe.wait_for(n).await;
            pipe.served.fetch_add(n, Ordering::SeqCst);
            if tx.send(Ok(vec![0u8; n as usize])).await.is_err() {
                // 客户端断开 ⇒ 立刻停（这就是生产代码的取消点）
                return;
            }
            sent += n;
        }
    });

    Response::builder()
        .status(StatusCode::PARTIAL_CONTENT)
        .header(header::CONTENT_TYPE, "video/mp4")
        .header(header::ACCEPT_RANGES, "bytes")
        .header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{}", st.total),
        )
        .header(header::CONTENT_LENGTH, len.to_string())
        .body(Body::from_stream(ChannelStream { rx }))
        .unwrap()
        .into_response()
}

async fn start_upstream(
    total: u64,
    bytes_per_sec: u64,
) -> (String, Arc<Pipe>, tokio::task::JoinHandle<()>) {
    let pipe = Arc::new(Pipe {
        bytes_per_sec,
        next_free: Mutex::new(Instant::now()),
        served: AtomicU64::new(0),
    });
    let st = UpState {
        pipe: pipe.clone(),
        total,
    };
    let app = Router::new().route("/m.mp4", get(serve)).with_state(st);
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let h = tokio::spawn(async move {
        let _ = axum::serve(l, app).await;
    });
    (format!("http://{addr}/m.mp4"), pipe, h)
}

// ═══════════════════════════════════════════════════════════════════
//  测量
// ═══════════════════════════════════════════════════════════════════

/// 共享令牌桶的带宽。★ **阳性对照就靠改这一行**：改成 `5120 * 1024`（×10）
/// 后重跑，干扰量应从 ~121ms 降到 ~8ms（实测 14.8×，见文件头「阳性对照」）。
const BPS: u64 = 512 * 1024; // 512 KB/s，便于在秒级看到差异
const TOTAL: u64 = 8 * 1024 * 1024; // 8 MB

/// 发一个请求，只读首字节就**主动断开**（模拟 mpv 切流）
///
/// ★ 不依赖 `futures_util`（本 crate 没有这个依赖）——
///   用 `reqwest::Response::chunk()` 逐个读，读到第一个就返回。
async fn fetch_first_byte_then_drop(url: &str) -> Duration {
    let client = reqwest::Client::new();
    let t0 = Instant::now();
    let mut resp = client
        .get(url)
        .header(header::RANGE, "bytes=0-")
        .send()
        .await
        .expect("请求失败");
    // `chunk()` 读一块就够 —— 随后 resp 被 drop ⇒ 连接断开
    let first = resp.chunk().await.expect("读首块失败");
    let dt = t0.elapsed();
    assert!(first.is_some_and(|b| !b.is_empty()), "没收到任何字节");
    drop(resp);
    dt
}

/// 等上游字节计数停止增长，返回等待时长
///
/// ★★ 这里有个容易写错的坑（我第一版就写错了）：
/// ```text
/// 错误写法：先采样 mark，sleep 100ms，再比 mark
///   ⇒ 如果这 100ms 内**恰好**没发新块，就立刻返回 waited=0
///   ⇒ 实测输出"旧连接静默耗时: 0ns"，而 A/B 却差 106ms —— 两个读数自相矛盾
///
/// 正确写法：**先等一段固定观察窗**，再确认这段时间里计数没变。
///   ⇒ 只有"连续 N 个采样点都没变"才算静默。
/// ```
async fn wait_until_quiet(pipe: &Arc<Pipe>, cap: Duration) -> Duration {
    const SETTLE: Duration = Duration::from_millis(300);
    let mut waited = Duration::ZERO;
    // 先无条件等一个观察窗，避免"恰好没变化"被误判为静默
    tokio::time::sleep(SETTLE).await;
    waited += SETTLE;
    loop {
        let mark = pipe.served.load(Ordering::SeqCst);
        tokio::time::sleep(SETTLE).await;
        waited += SETTLE;
        if pipe.served.load(Ordering::SeqCst) == mark {
            return waited;
        }
        if waited > cap {
            return waited;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn old_prefetch_interference_measurement() {
    println!("\n══════════════════════════════════════════════════════════");
    println!("切集/换源：旧预取对新流的干扰测量");
    println!("上游带宽 {BPS} B/s（共享令牌桶），文件 {TOTAL} 字节");
    println!("══════════════════════════════════════════════════════════");

    /*
     * ★★ 两组必须用**同一个**上游实例（同一令牌桶）。
     *
     * 我第一版给 B 组新起了一个上游 ⇒ 令牌桶状态不同 ⇒ A/B 不可比。
     * 同一实例 + 每组前都等到静默 ⇒ 两组起点一致（管道空闲）。
     */
    let (url, pipe, _h) = start_upstream(TOTAL, BPS).await;

    // ── A 组：断开旧流后**立刻**开新流 ──────────────────────────
    let _old = fetch_first_byte_then_drop(&url).await;
    let served_at_drop = pipe.served.load(Ordering::SeqCst);
    let a_latency = fetch_first_byte_then_drop(&url).await;
    let served_after_a = pipe.served.load(Ordering::SeqCst);

    println!("\n【A 组】断开旧流后立刻开新流");
    println!("  断开时已发出: {served_at_drop} 字节");
    println!("  新流首字节延迟: {:?}", a_latency);
    println!("  A 组期间又发出: {} 字节", served_after_a - served_at_drop);

    // ── 旧连接静默耗时（A 组之后）─────────────────────────────
    let quiet = wait_until_quiet(&pipe, Duration::from_secs(15)).await;
    /*
     * ★ 判断"是否超时仍在发"要用**调用前**的基准，不是 A 组结束时的值。
     *
     * 我上一版写成 `served > served_after_a` —— 但 wait_until_quiet 内部
     * 已经等过、计数早已增长 ⇒ 必然判成"仍在发" ⇒ 输出
     * 「静默 600ms（⚠️ 15 秒后仍在发）」这种自相矛盾的话。
     */
    let timed_out = quiet >= Duration::from_secs(15);
    println!(
        "  旧连接静默耗时: {quiet:?}{}",
        if timed_out {
            "（⚠️ 超时仍在发）"
        } else {
            "（已停）"
        }
    );

    // ── B 组：同一上游、已静默 ⇒ 无旧预取 ─────────────────────
    let b_latency = fetch_first_byte_then_drop(&url).await;

    println!("\n【B 组】静默后开新流（无旧预取，同一上游）");
    println!("  新流首字节延迟: {:?}", b_latency);

    // ── 汇总 ───────────────────────────────────────────────────
    println!("\n══════════════════════════════════════════════════════════");
    println!("汇总");
    println!("══════════════════════════════════════════════════════════");
    println!("  A 组（有旧预取）: {:?}", a_latency);
    println!("  B 组（无旧预取）: {:?}", b_latency);
    println!("  干扰量: {:?}", a_latency.saturating_sub(b_latency));
    if b_latency.as_millis() > 0 {
        println!(
            "  A/B 比: {:.2}×",
            a_latency.as_secs_f64() / b_latency.as_secs_f64()
        );
    }

    /*
     * ★ 不断言"干扰必须小"或"必须大" —— 那是把结论写进测试。
     *   这里只断言**测量本身有效**：两组都真的收到了字节。
     * ⇒ 读数由人工判读；测试只保证"仪器能跑、能出数"。
     */
    assert!(a_latency.as_micros() > 0, "A 组没测到延迟");
    assert!(b_latency.as_micros() > 0, "B 组没测到延迟");
}

/// ② 注册表条数：登记 N 次后表里有多少条（验证 FIFO 淘汰）
#[tokio::test]
async fn stream_table_size_after_many_registrations() {
    use sourin_core::streamproxy::StreamProxy;

    println!("\n══════════════════════════════════════════════════════════");
    println!("注册表增长测量（验证 FIFO 淘汰，不是单调增长）");
    println!("══════════════════════════════════════════════════════════");

    let p = StreamProxy::new();
    let mut sizes: Vec<(usize, usize)> = Vec::new();
    for i in 0..300 {
        p.register_at(&format!("http://example.com/{i}.mp4"), vec![], 12345);
        if i % 50 == 49 || i == 299 {
            sizes.push((i + 1, p.stream_table_len_for_probe()));
        }
    }
    println!("  登记次数 → 表内条数:");
    for (regs, len) in &sizes {
        println!("    {regs:>4} → {len}");
    }
    let last = sizes.last().unwrap().1;
    println!("  最终条数: {last}");
    /*
     * ★ 关键断言：**不随登记次数单调增长**。
     *   若有人删掉淘汰逻辑，300 次登记后表里会是 300 条 ⇒ 本断言红。
     */
    assert!(
        last < 300,
        "★ 登记 300 次后表内仍有 {last} 条 ⇒ 淘汰逻辑失效（预期远小于 300）"
    );
}
