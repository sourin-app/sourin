// ═══════════════════════════════════════════════════════════════════════
//  N10 真机体感验证 · 限速上游（合成视频）
// ═══════════════════════════════════════════════════════════════════════
//
// VERIFICATION TOOL -- NOT PART OF THE PRODUCT BUILD.
//
// # 它解决什么问题
//
// ```text
// N10 的单元级验证（tests/zz_n10_yield_verify.rs）已经证明：
//   「让路窗口内前台读取确实拿到了更多带宽」（1.19×，回到预取关闭水平）
// 但那只证明**带宽让开了**，不是**用户体感变快了**。
//
// 要测体感，需要 mpv 真的在播、真的 seek、真的读 buffering 状态。
// 而 mpv 需要一个**有真实带宽限制**的 HTTP 上游 —— 本地文件没有带宽概念，
// 让路也就无处体现。
//
// ⇒ 这个程序就是那个上游：读一个本地 mp4，按共享令牌桶限速吐给客户端。
//    所有连接共用一条管子（真实网络的物理模型）。
// ```
//
// # 用法
//
// ```text
//   cargo run --release --bin n10_throttle_upstream -- <file.mp4> [bytes_per_sec] [port]
//
//   例：cargo run --release --bin n10_throttle_upstream -- \
//         .probe/n10vo/n10_vo_sample.mp4 262144 18081
// ```
//
// # 为什么单独做成一个 bin
//
// ```text
// 它要被**两个进程**用：flutter 探针（经 streamproxy 拉流）—— 它只提供数据。
// 写成 cargo test 里的内联上游的话，测试进程一退出上游就没了，
// 真机探针就拿不到流。
// ```

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, Request, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use tokio::sync::Mutex;

/// 共享管道：所有连接从这里领时间片
///
/// ★ 与 `tests/zz_n10_yield_verify.rs` 里那份同一个模型（管道串行化），
///   这样两处的物理假设一致，读数可以互相印证。
struct Pipe {
    bytes_per_sec: u64,
    next_free: Mutex<Instant>,
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

/// 解析 `Range: bytes=a-b`
fn parse_range(h: &HeaderMap, total: u64) -> (u64, u64) {
    h.get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(|r| {
            let r = r.strip_prefix("bytes=")?;
            let (a, b) = r.split_once('-')?;
            let start: u64 = a.trim().parse().ok()?;
            let end: u64 = if b.trim().is_empty() {
                total - 1
            } else {
                b.trim().parse::<u64>().ok()?.min(total - 1)
            };
            Some((start, end))
        })
        .unwrap_or((0, total - 1))
}

async fn serve(
    State((pipe, data)): State<(Arc<Pipe>, Arc<Vec<u8>>)>,
    req: Request<Body>,
) -> Response {
    let total = data.len() as u64;
    let (start, end) = parse_range(req.headers(), total);
    let bytes = data.clone();

    /*
     * 关键：**流式**吐，不是一次性返回。
     *
     * 一次性返回的话，限速就没有意义了（服务端已经把整段塞进内核缓冲）。
     * 必须按块吐、每块等额度 ⇒ 客户端真的是"一点点收到"的。
     */
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<bytes::Bytes, std::io::Error>>(4);
    tokio::spawn(async move {
        const CHUNK: usize = 64 * 1024;
        let mut pos = start;
        while pos <= end {
            let n = CHUNK.min((end - pos + 1) as usize);
            pipe.wait_for(n as u64).await;
            let slice = &bytes[pos as usize..(pos as usize + n)];
            if tx
                .send(Ok(bytes::Bytes::copy_from_slice(slice)))
                .await
                .is_err()
            {
                return; // 客户端走了（seek 时常见，正常）
            }
            pos += n as u64;
        }
    });

    Response::builder()
        .status(StatusCode::PARTIAL_CONTENT)
        .header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{total}"))
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_TYPE, "video/mp4")
        .header(header::CONTENT_LENGTH, (end - start + 1).to_string())
        .body(Body::from_stream(ReceiverStream { rx }))
        .unwrap()
        .into_response()
}

struct ReceiverStream {
    rx: tokio::sync::mpsc::Receiver<Result<bytes::Bytes, std::io::Error>>,
}

impl futures_core::Stream for ReceiverStream {
    type Item = Result<bytes::Bytes, std::io::Error>;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        self.rx.poll_recv(cx)
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("用法: n10_throttle_upstream <file.mp4> [bytes_per_sec] [port]");
        std::process::exit(2);
    }
    let path = &args[1];
    let rate: u64 = args
        .get(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(256 * 1024);
    let port: u16 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(18081);

    let data = std::fs::read(path).unwrap_or_else(|e| {
        eprintln!("读不到 {path}: {e}");
        std::process::exit(2);
    });
    eprintln!(
        "[UPSTREAM] file={path} size={} bytes  rate={} KB/s  port={port}",
        data.len(),
        rate / 1024
    );

    let state = (Arc::new(Pipe {
        bytes_per_sec: rate,
        next_free: Mutex::new(Instant::now()),
    }), Arc::new(data));

    let app = Router::new()
        .route("/video.mp4", get(serve))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}"))
        .await
        .unwrap();
    eprintln!("[UPSTREAM] ready at http://127.0.0.1:{port}/video.mp4");
    // 给探针一个明确的"可以开始了"信号
    println!("READY http://127.0.0.1:{port}/video.mp4");
    use std::io::Write;
    let _ = std::io::stdout().flush();

    axum::serve(listener, app).await.unwrap();
}
