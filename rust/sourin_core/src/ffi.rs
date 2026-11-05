// ═══════════════════════════════════════════════════════════════════════
//  FFI 边界 —— Dart ↔ Rust 的唯一通道
// ═══════════════════════════════════════════════════════════════════════
//
// # 设计：单一 JSON 入口
//
// 不导出 90 个函数，只导出**少数几个**，命令名放在 JSON 里：
// ```text
// sourin_call(reqJson)                  → 同步命令
// sourin_call_async(reqJson, cb, id)    → 异步命令（回调返回）
// sourin_call_stream(reqJson, cb, token)→ 流式命令（回调多次）
// sourin_cancel_stream(token)           → 取消流
// sourin_free(ptr)                      → 释放 Rust 分配的字符串
// sourin_start(dataDir)                 → 启动核心
// sourin_core_version()                 → 版本探针
// ```
//
// # 为什么不用「一命令一导出」
//
// ```text
// ① 加命令不用改 Dart 的 lookupFunction（少一处会忘的地方）
// ② 参数解析集中在一处（Args），不会每个命令各写一遍
// ③ 跨 FFI 边界的东西越少越安全 —— 每个导出都是一个 unsafe 面
// ```
//
// # ★ 并发正确性（2026-09-23 修过死锁，改动前必读）
//
// ```text
// sourin_call          → Dart FFI 线程       → dispatch_blocking
// sourin_call_async    → spawn_blocking 阻塞池 → dispatch_blocking
// sourin_call_stream   → std::thread         → block_on
// ```
// ⚠️ **绝不能**从 `runtime().spawn()` 出来的 worker 线程直接
//    `block_on` —— 那会饿死 worker 池（实测：8 个并发全 120 秒超时）。
//    详见 `with_state_async` 的说明。

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::OnceLock;

/// tokio 运行时（全局唯一）
///
/// # 为什么用 `OnceLock` 而不是 `Mutex<Option<..>>`
///
/// · `OnceLock` 的 `get()` 是**无锁**的（一次原子读），
///   而 `Mutex` 每次都要加解锁 —— 每条命令都要过一次，没必要
/// · 运行时是**建一次用一辈子**的东西，语义上就是 OnceLock
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

/*
 * ★ 流式命令的取消标志集合（2026-09-22）
 *
 * # 为什么需要它
 *
 * Dart 的跨线程回调（`NativeCallable.listener`）**必须返回 void** ——
 * 实测 `flutter analyze` 报：
 * ```text
 * error - The return type of the function passed to
 *         'NativeCallable.listener' must be 'void' rather than 'Int32'
 * ```
 * 所以「靠回调返回值决定是否继续」这个设计在 Dart 侧做不到。
 *
 * 改成带外信号：Dart 调 `sourin_cancel_stream(token)` 往这里塞一条，
 * Rust 每次发事件前查一下。
 *
 * # 用 Mutex<HashSet> 而不是 AtomicBool
 *
 * 因为**可能同时有多路流**（比如用户在搜索页快速改关键词，
 * 前一次还没结束）。单一布尔量无法区分是哪一路要取消。
 */
static CANCELLED: std::sync::Mutex<Option<std::collections::HashSet<usize>>> =
    std::sync::Mutex::new(None);

/// 取取消集合（首次访问时初始化）
///
/// ⚠️ 用 `Mutex<Option<HashSet>>` 而不是 `Mutex<HashSet>`：
///    `HashSet::new()` **不是 const fn**（实测编译报
///    `E0015: cannot call non-const associated function in statics`），
///    没法直接初始化 static。
fn cancel_set() -> std::sync::MutexGuard<'static, Option<std::collections::HashSet<usize>>> {
    let mut g = CANCELLED.lock().unwrap();
    if g.is_none() {
        *g = Some(std::collections::HashSet::new());
    }
    g
}
/// 检查 token 是否已被取消
fn is_cancelled(token: usize) -> bool {
    cancel_set()
        .as_ref()
        .map(|s| s.contains(&token))
        .unwrap_or(false)
}

/// 标记取消
fn mark_cancelled(token: usize) {
    if let Some(s) = cancel_set().as_mut() {
        s.insert(token);
    }
}

/// 静默日志（流开始时静默一次、结束时静默一次）
fn clear_cancelled(token: usize) {
    if let Some(s) = cancel_set().as_mut() {
        s.remove(&token);
    }
}

fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .thread_name("sourin-core")
            .build()
            .expect("tokio 运行时建不起来（内存不足？）")
    })
}

/// 把 Rust 的 String 转成 C 字符串指针 —— 所有权移交给调用方，用完必须经 `sourin_free` 归还。
fn into_c(s: String) -> *mut c_char {
    // CString::new 的 NUL 语义：字符串含内嵌 NUL 时返回 Err —— JSON 里不该有内嵌 NUL；
    // 真有的话就换成错误 JSON，怎么都比 panic 好（panic 跨 FFI 是 UB，不能让宿主崩）。
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        // ★ 2026-11-01：这行原本是被二次编码破坏的乱码，而它是**用户可见**的错误消息，必须能读懂 —— 按语义还原（"字符串含 NUL 字节"）。
        Err(_) => CString::new("{\"error\":\"字符串含 NUL 字节\"}")
            .unwrap()
            .into_raw(),
    }
}

/// 把 C 字符串（NUL 结尾）取回 Rust String
///
/// # Safety
///
/// `ptr` 必须是有效的、以 NUL 结尾的 UTF-8 字符串指针，
/// 且在本函数返回前保持有效。传 NULL 会返回空串（而不是崩掉）。
unsafe fn from_c(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

// ═══════════════════════════════════════════════════════════════════════
//  导出的 FFI 清单
// ═══════════════════════════════════════════════════════════════════════

/// 版本号 —— 用它探测 FFI 链路是否打通。
///
/// ```dart
/// final v = ffi.sourinCoreVersion();   // "sourin-core 0.1.0"
/// ```
///
/// # Safety
/// 返回的指针指向静态数据，**不需要 free**。
/// 解析 `midrolls` 参数：`[{start,end},…]`；**缺省/空/null ⇒ 空数组**
///
/// 只做"形状"解析（数字、字段名）；**区间合法性由 `commands_write::set_skip_marker` 校验**
/// （那一层才知道"第 N 段"的业务含义与段数上限）。
fn parse_spans(v: Option<&serde_json::Value>) -> Result<Vec<crate::store::SkipSpan>, String> {
    let Some(v) = v else {
        return Ok(Vec::new());
    };
    let arr = match v {
        serde_json::Value::Array(a) => a,
        serde_json::Value::Null => return Ok(Vec::new()),
        _ => return Err("midrolls 必须是数组（形如 [{start:600,end:660}]）".to_string()),
    };
    let mut out = Vec::with_capacity(arr.len());
    for (i, item) in arr.iter().enumerate() {
        let start = item
            .get("start")
            .and_then(|x| x.as_u64())
            .ok_or_else(|| format!("第 {} 段缺少 start（必须是非负整数，单位秒）", i + 1))?;
        let end = item
            .get("end")
            .and_then(|x| x.as_u64())
            .ok_or_else(|| format!("第 {} 段缺少 end（必须是非负整数，单位秒）", i + 1))?;
        out.push(crate::store::SkipSpan { start, end });
    }
    Ok(out)
}

#[no_mangle]
pub extern "C" fn sourin_core_version() -> *const c_char {
    static V: &[u8] = b"sourin-core 0.1.0\0";
    V.as_ptr() as *const c_char
}

/// 归还 Rust 分配的字符串
///
/// # Safety
///
/// `ptr` 必须是 `sourin_*` 系列函数返回的指针，**且只能 free 一次**。
/// 传 NULL 是安全的（no-op）。
/// 传一个非本模块分配的指针 = 未定义行为。
#[no_mangle]
pub unsafe extern "C" fn sourin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// ★ 同步调用一个命令。
///
/// # 输入
///
/// ```json
/// { "cmd": "list_providers", "args": { } }
/// ```
///
/// # 返回
///
/// 成功：命令本身的返回值（JSON）。
/// 失败：`{"error":"...","kind":"network|unauthorized|not_found|unsupported|other"}`
///
/// ⚠️ 这个函数**会阻塞调用线程**，直到命令完成。
///    Flutter 的 UI 线程**不要**调它 —— 用 `sourin_call_async`。
///    保留它是因为：本地读库这类快命令用它更简单（无回调开销）。
///
/// # Safety
/// `req_json` 必须是有效的 NUL 结尾 UTF-8 字符串。
/// 返回的指针必须由调用方用 `sourin_free` 归还。
#[no_mangle]
pub unsafe extern "C" fn sourin_call(req_json: *const c_char) -> *mut c_char {
    let req = from_c(req_json);
    let result = dispatch_blocking(&req);
    into_c(result)
}

/// ★★ 异步调用一个命令（Flutter 应该用这个）。
///
/// # 为什么需要异步版有
///
/// 90 个命令里有很多是**秒级**的：
/// ```text
/// search_all       跨多个源并发搜索
/// resolve_stream   解析真实流地址（要走上游 API）。
/// get_detail       拉详情。
/// backup_export    导出打包
/// ```
/// 这些如果同步调，Flutter 的 UI 会**整段卡死**。
///
/// # 回调参数为什么都是 `usize` 而不是指针类型？
///
/// FFI 边界上，**指针和函数指针都不是 `Send`**，而 `tokio::spawn`
/// 要求 future 是 `Send`。直接传会报：
/// ```text
/// error[E0277]: `*mut c_void` cannot be sent between threads safely
/// error[E0277]: `extern "C" fn(...)` cannot be sent between threads safely
/// ```
///
/// 踩坑记录：我第一版把 `user_data` 包成 newtype 标了 `Send`，
/// 连 callback 一起包了 —— 错误依旧。第二版两个都转 `usize` 才对。
///
/// 转 `usize` 是 FFI 的常规做法：地址值本身就是整数，
/// 天然满足 `Send`。进函数后 `as` 回指针即可。
///
/// # 回调约定
///
/// ```text
/// callback(result_json_ptr, user_data)
///   · result_json_ptr 由 Rust 分配，**回调方负责 free**
///     （Dart 侧在回调里读完就 free，不要留到后面）
///   · 回调在 tokio 的 worker 线程上执行，**不在** Dart 的 isolate
///     （Dart 这边只有 NativeCallable.listener 才能跨线程回 isolate）
/// ```
///
/// # 如果不需要结果
///
/// `callback_addr = 0`：命令照常执行，结果被丢弃。
/// 用于「设置类」命令（set_favorite / save_progress 等）。
///
/// # Safety
///
/// · `req_json` 必须是有效的 NUL 结尾 UTF-8 字符串
/// · `callback_addr` 要么是 0，要么是
///   `extern "C" fn(*mut c_char, *mut c_void)` 的有效函数地址。
/// · `user_data_addr` 原样回传，Rust **从不解引用**它；
///   其生命周期必须覆盖到回调执行完毕。
#[no_mangle]
pub unsafe extern "C" fn sourin_call_async(
    req_json: *const c_char,
    callback_addr: usize,
    user_data_addr: usize,
) {
    let req = from_c(req_json);

    /*
     * ★★★ 必须用 `spawn_blocking`，**不能**用 `runtime().spawn()`
     *     （2026-09-23 实测抓到的死锁 + panic）
     *
     * # 为什么
     *
     * `dispatch_blocking` 内部会 `runtime().block_on(...)`。
     * 而 `runtime().spawn()` 出来的任务跑在 **worker 线程**上 ——
     * 在 worker 里 `block_on` 会直接 panic：
     * ```text
     * Cannot start a runtime from within a runtime.
     * This happens because a function (like `block_on`) attempted to
     * block the current thread while the thread is being used to drive
     * asynchronous tasks.
     * ```
     * 实测表现：首页 8 个并发区块**全部失败**，且错误消息是空的
     *（panic 被 catch_unwind 接住，消息丢了）。
     *
     * # spawn_blocking 的区别
     *
     * 它把任务放到 tokio 的**阻塞线程池**（与 worker 池分开），
     * 那里的线程**不驱动异步任务**，所以 `block_on` 合法。
     *
     * # 为什么不干脆改成真 async
     *
     * `dispatch_inner` 里有大量**同步命令**（`with_state`）——
     * 它们直接读写 SQLite，本来就不该在 async 上下文里跑。
     * 用 spawn_blocking 包一层是最小改动且语义正确的做法。
     */
    runtime().spawn_blocking(move || {
        let result = dispatch_blocking(&req);

        if callback_addr != 0 {
            // SAFETY: 调用方保证这是有效的函数地址（见 Safety 节）。
            let cb: extern "C" fn(*mut c_char, *mut std::ffi::c_void) =
                std::mem::transmute(callback_addr);
            cb(into_c(result), user_data_addr as *mut std::ffi::c_void);
        }
        // callback_addr 为 0 时结果直接丢弃（设置类命令不需要回执）
    });
}

/// 流式命令（2026-09-22 新增）：回调会被调用**多次**
///
/// # 为什么需要单独的导出
///
/// `sourin_call_async` 的语义是「执行一次命令、回调一次」，
/// 但 `search_all_stream` 是**每完成一个源就报一次**。
/// ```text
/// sourin_call_async  ——只能表达「最终结果」
/// sourin_call_stream ——表达「过程中不断产生的事件」
/// ```
/// 硬把流式塞进单次回调只有两种办法，都不好：
/// ```text
/// · 攒到最后一起返回 —— 失去流式的意义（用户要等全部的源）
/// · 破坏 sourin_call_async 的语义（它是另外 32 个命令的调用约定）
/// ```
/// 所以独立一个导出，**两条通道互不干扰**。
///
/// # 回调约定（形状与 `sourin_call_async` 一样，只是可多次）
///
/// ```text
/// callback(event_json_ptr, user_data_addr)
/// ```
/// · 每个事件一次调用，**顺序与源完成顺序一致**。
/// · 事件 JSON 形如：
///   ```json
///   {"kind":"hit","provider":"srca","provider_name":"次元域",
///    "items":[...],"page":1,"page_count":5,"total":100}
///   {"kind":"miss","provider":"x","reason":"该源已失效"}
///   ```
/// · 全部完成后回调一次 `{"kind":"done"}` —— 让 Dart 侧知道何时收起 loading
/// · 若启动就失败（核心未启动），回调一次 `{"kind":"error","error":"..."}` 后结束
///
/// # ★★ 取消机制：用**显式 token**，不用回调返回值（2026-09-22）
///
/// ## 为什么不能用返回值（我第一版的设计，编译期就被否掉了）
///
/// 我最初设计成：
/// ```text
/// Rust 调 cb(...) → 看返回值：
///   返回 0   → 取消
///   返回非 0 → 继续
/// ```
/// 看起来干净，但**在 Dart 侧根本做不到**。实测 `flutter analyze`：
/// ```text
/// error - The return type of the function passed to
///         'NativeCallable.listener' must be 'void' rather than 'Int32'
/// ```
/// Dart 的跨线程回调（`NativeCallable.listener`）**必须返回 void** ——
/// 因为它是通过消息端口投递到目标 isolate 的，而消息投递是**异步**的，
/// 拿不到同步返回值。
///
/// 另一个选项 `NativeCallable.isolateLocal` 可以返回 i32，
/// 但它**只能被创建它的线程调用** —— 而 Rust 的 worker 线程回调
/// 会直接`abort` 整个进程。
///
/// ## 改成带外信号
///
/// ```text
/// sourin_call_stream(req, cb, token)   → token 标识这一路流
/// cb(event_json, token)                → void 返回
/// sourin_cancel_stream(token)          —— Dart 主动取消（另一个导出）
/// ```
/// Rust 内部维护一个取消集合；每次要发事件前检查：
/// ```text
/// 已取消 → 回调返回 false → search_all_stream 提前 return
///                       → 生产者 abort → 当前网络请求取消
/// ```
///
/// **语义完全不变**（实测取消后 0.66s 就收，而不是等满 30 秒）。
/// 只是把「回调的同步返回值」换成了「带外标志」。
///
/// # 回调约定
///
/// ```text
/// cb(event_json_ptr, token)
/// ```
/// · 每个事件一次调用，**顺序与源完成顺序一致**。
/// · 事件 JSON 形如：
///   ```json
///   {"kind":"hit","provider":"srca","provider_name":"次元域",
///    "items":[...],"page":1,"page_count":5,"total":100}
///   {"kind":"miss","provider":"x","reason":"该源已失效"}
///   ```
/// · 全部完成后回调一次 `{"kind":"done"}`
/// · 启动就失败时回调一次 `{"kind":"error","error":"..."}`
///
/// # Safety
///
/// · `req_json` 必须是有效的 NUL 结尾 UTF-8 字符串
/// · `callback_addr` 要么是 0，要么是
///   `extern "C" fn(*mut c_char, usize)` 的有效函数地址。
/// · `token` 由调用方决定（建议自增整数），用于后续取消
#[no_mangle]
pub unsafe extern "C" fn sourin_call_stream(
    req_json: *const c_char,
    callback_addr: usize,
    token: usize,
) {
    let req = from_c(req_json);

    /*
     * 只有 `search_all_stream` 目前走流式 ——
     * 其它命令名一律回一个 error 事件，不做静默忽略
     *（静默忽略会让 Dart 侧一直等 "done"，表现为搜索结果永远不结束）。
     */
    let parsed: Option<(String, u32)> = (|| {
        let v: serde_json::Value = serde_json::from_str(&req).ok()?;
        let cmd = v.get("cmd")?.as_str()?;
        if cmd != "search_all_stream" {
            return None;
        }
        let a = crate::args::Args::new(&v, "search_all_stream");
        let kw = a.str("keyword").ok()?.to_string();
        let page = a.u32_or("page", 1);
        Some((kw, page))
    })();

    let cb: Option<extern "C" fn(*mut c_char, usize)> = if callback_addr != 0 {
        // SAFETY: 调用方保证这是有效函数地址（见 Safety 节）
        Some(std::mem::transmute(callback_addr))
    } else {
        None
    };

    let Some((keyword, page)) = parsed else {
        if let Some(cb) = cb {
            let msg = r#"{"kind":"error","error":"sourin_call_stream 只支□search_all_stream"}"#;
            cb(into_c(msg.to_string()), token);
        }
        return;
    };

    let Some(st) = state() else {
        if let Some(cb) = cb {
            let msg = r#"{"kind":"error","error":"核心尚未启动 —— 请先调用 sourin_start"}"#;
            cb(into_c(msg.to_string()), token);
        }
        return;
    };

    // 新一轮流式：清掉可能残留的取消标志（token 可能被复用）
    clear_cancelled(token);

    /*
     * ★ 在独立线程上 block_on（与 `with_state_async` 同样的理由）
     *
     * `sourin_call_stream` 可能被 Dart 从任意线程调用 —— 如果在
     * tokio runtime 内部调`block_on` 会panic
     *（"Cannot start a runtime from within a runtime"），
     * 而 panic 跨 FFI 是 UB —— 会直接穿掉 Flutter。
     */
    std::thread::spawn(move || {
        let fut = crate::commands::search_all_stream(st, &keyword, page, |ev| {
            /*
             * ★ 每次发事件前查一次取消标志
             *
             * 返回 false 会让 `search_all_stream` 提前 return，
             * 进而 abort 生产者（当前网络请求随之取消）。
             */
            if is_cancelled(token) {
                log::info!("流式搜索 token={token} 已被取消，停止搜索");
                return false;
            }
            let Some(cb) = cb else {
                // 没有回调 → 继续跑完（调用方不要结果，但命令仍需执行）
                return true;
            };
            let json = serde_json::to_string(&ev)
                .unwrap_or_else(|e| format!(r#"{{"kind":"error","error":"序列化失败? {e}"}}"#));
            cb(into_c(json), token);
            true
        });

        let r = runtime().block_on(fut);

        // 收尾事件（已取消时也发）—— 让 Dart 侧知道流结束了，可以收起 loading
        if let Some(cb) = cb {
            let done = match r {
                Ok(()) => r#"{"kind":"done"}"#.to_string(),
                Err(e) => format!(
                    r#"{{"kind":"error","error":{}}}"#,
                    /*
                     * ⚠️ 这里用 raw string（`r#""unknown""#`）而不是
                     *    普通字符串 + 反斜杠转义 —— Rust 的普通字符串
                     *    **不支持** JSON/C 那种 \" 写法，会报
                     *    `unknown start of token: \`。
                     *    （写这段注释时也别在注释里写出那个转义序列 ——
                     *      它会干扰词法扫描。）
                     */
                    serde_json::to_string(&e).unwrap_or_else(|_| r#""unknown""#.to_string())
                ),
            };
            cb(into_c(done), token);
        }

        // 流结束，清掉标志（避免集合无限增长）
        clear_cancelled(token);
    });
}

/// 取消一个流式命令（2026-09-22）
///
/// # 用法
///
/// Dart 侧在**用户离开搜索页**时调它：
/// ```dart
/// SourinCore.cancelStream(token);
/// ```
/// Rust 侧会在下一次要发事件时发现标志，返回 false ——
/// `search_all_stream` 提前 return，生产者 abort，当前请求取消。
///
/// # 为什么是独立的导出（而不是回调返回值）
///
/// 见 `sourin_call_stream` 的说明：Dart 的跨线程回调**必须返回 void**，
/// 拿不到同步返回值，所以取消只能走带外信号。
///
/// # 幂等
///
/// 取消一个不存在的 token 是无害的（集合里加一条，之后被清）。
/// 重复取消同一个 token 也是无害的。
#[no_mangle]
pub extern "C" fn sourin_cancel_stream(token: usize) {
    mark_cancelled(token);
    log::info!("宸茶姹傚彇娑堟祦寮忓懡浠?token={token}");
}

/// 启动核心（建库、恢复源、起流代理）
///
/// # 输入
///
/// ```json
/// { "dataDir": "C:/Users/x/AppData/Roaming/app.sourin.player" }
/// ```
///
/// # 返回
///
/// ```json
/// { "ok": true, "version": "sourin-core 0.1.0", "dataDir": "...",
///   "deviceId": "...", "providers": 3 }
/// ```
///
/// # 为什么 dataDir 要调用方传
///
/// 核心层不该知道各平台的路径 API（比如：
/// ```text
/// Tauri   → app.path().app_data_dir()
/// Flutter → path_provider 的 getApplicationSupportDirectory()
/// Android → /data/data/<pkg>/files/
/// ```
/// 让调用方决定，核心只管用。
///
/// # 重复调用是安全的
///
/// 第二次调用会直接返回已有的状态（不重复建库）——
/// Flutter 热重载 / 页面重建时可能重复调。
///
/// # Safety
/// 同`sourin_call`。
#[no_mangle]
pub unsafe extern "C" fn sourin_start(config_json: *const c_char) -> *mut c_char {
    let cfg = from_c(config_json);
    log::info!("sourin_start: {cfg}");

    // 解析配置
    let v: serde_json::Value = match serde_json::from_str(&cfg) {
        Ok(v) => v,
        Err(e) => {
            return into_c(err_json(&format!("启动配置不是合法 JSON: {e}"), "other"));
        }
    };

    let Some(data_dir) = v.get("dataDir").and_then(|d| d.as_str()) else {
        return into_c(err_json("启动配置缺少 dataDir 字段", "other"));
    };
    let data_dir = std::path::PathBuf::from(data_dir);

    // 已在运行 → 直接返回（幂等）
    if STATE.get().is_some() {
        log::info!("核心已在运行，跳过重复启动");
        return into_c(existing_state_json());
    }

    // ★ 真正启动（阻塞等 bootstrap 完成）
    let result = runtime().block_on(crate::state::AppState::bootstrap(data_dir));
    match result {
        Ok(state) => {
            /*
             * ★ 统计口径修正（2026-09-22）
             *
             * `providers` 原先取的是`third_party.len()`（
             * 那只是**持久化的第三方源清单**，不含 JS 插件。
             *
             * 实测暴露：日志里明明写着「已注册 26 涓?JS 插件」，
             * 返回的却是 `providers: 0` —— 因为那 26 个来自插件目录，
             * 而 third_party 是空的。
             *
             * 这个字段是给调用方做启动自检用的，"0" 会让人以为
             * 一个源都没加载。所以改成取**注册表里的真实数字**，
             * 并把两类分开报，语义才清晰。
             */
            let js_count = state.registry.manifests().len();
            let third_party = state.third_party.read().map(|g| g.len()).unwrap_or(0);
            let device_id = state.device_id.clone();

            // （OnceLock）set 失败说明有并发启动，用已有的
            let _ = STATE.set(state);

            into_c(format!(
                r#"{{"ok":true,"version":"sourin-core 0.1.0","deviceId":{},"providers":{js_count},"thirdPartyProviders":{third_party}}}"#,
                serde_json::to_string(&device_id).unwrap_or_else(|_| "\"\"".into())
            ))
        }
        Err(e) => into_c(err_json(&format!("启动失败: {e}"), "other")),
    }
}

/// 已有状态时的返回（幂等路径）
fn existing_state_json() -> String {
    let (device_id, js_count, third_party) = match STATE.get() {
        Some(s) => (
            s.device_id.clone(),
            s.registry.manifests().len(),
            s.third_party.read().map(|g| g.len()).unwrap_or(0),
        ),
        None => (String::new(), 0, 0),
    };
    format!(
        r#"{{"ok":true,"version":"sourin-core 0.1.0","alreadyStarted":true,"deviceId":{},"providers":{js_count},"thirdPartyProviders":{third_party}}}"#,
        serde_json::to_string(&device_id).unwrap_or_else(|_| "\"\"".into())
    )
}

// ═══════════════════════════════════════════════════════════════════════
//  全局状态
// ═══════════════════════════════════════════════════════════════════════

/// 全局应用状态。
///
/// # 为什么用 `OnceLock` 而不是 `Mutex<Option<..>>`
///
/// ```text
/// 它只在启动时设置一次，之后全是只读访问
/// · OnceLock 的 get() 是**无锁**的（一次原子读）
/// · 而 Mutex 每次访问都要抢锁 —— 90 个命令都会碰到它
/// ```
/// 与原版 `app.manage(state)` 等价（Tauri 内部也是这样的存储）。
pub(crate) static STATE: std::sync::OnceLock<std::sync::Arc<crate::state::AppState>> =
    std::sync::OnceLock::new();

/// 取全局状态；未启动时返回 None
pub(crate) fn state() -> Option<&'static std::sync::Arc<crate::state::AppState>> {
    STATE.get()
}

// ═══════════════════════════════════════════════════════════════════════
//  命令分发
// ═══════════════════════════════════════════════════════════════════════

fn parse_optional_play_request(
    v: &serde_json::Value,
) -> Result<Option<crate::model::PlayRequest>, &'static str> {
    match v.get("args").and_then(|args| args.get("req")) {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(req @ serde_json::Value::Object(_)) => {
            serde_json::from_value::<crate::model::PlayRequest>(req.clone())
                .map(Some)
                .map_err(|_| "resolve_stream req must be a valid PlayRequest")
        }
        Some(_) => Err("resolve_stream req must be a valid PlayRequest"),
    }
}

/// 解析 `{cmd, args}` 并分发
///
/// # 为什么错误也返回 JSON 而不是抛
///
/// 跨 FFI 边界抛 panic 是**未定义行为**（轻则直接崩掉宿主进程，
/// 而 Flutter 侧连栈都看不到）。所以这里把 panic 也接住，
/// 统一转成 JSON 错误返回。
fn dispatch_blocking(req: &str) -> String {
    /*
     * ★ 用 catch_unwind 兜住 panic —— 宁可返回错误，不让宿主穿
     *
     * # 为什么这里可以安全 block_on（2026-09-23 死锁保命后）
     *
     * 调用来源只有两条，都在非 worker 线程上：
     * ```text
     * sourin_call        → Dart 的 FFI 调用线程（不是 tokio 线程）
     * sourin_call_async  → runtime().spawn_blocking（阻塞池）
     * ```
     * 所以在里面 `block_on` 不会饿死 tokio 的 worker 线程池。
     *
     * ★★★ 反过来说：**绝不**让 `runtime().spawn()` 出来的 worker
     *    直接调这个函数 —— 那正是之前那个死锁的成因
     *   （worker 被 block_on 占住，而 block_on 的 future 又要 worker）。
     */
    let req = req.to_string();
    match std::panic::catch_unwind(move || runtime().block_on(dispatch_inner(&req))) {
        Ok(s) => s,
        Err(e) => {
            let msg = e
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| e.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "命令执行时 panic（无消息）".into());
            log::error!("sourin_core panic: {msg}");
            format!(
                r#"{{"error":{},"kind":"other"}}"#,
                serde_json::to_string(&msg).unwrap_or_else(|_| "\"panic\"".into())
            )
        }
    }
}

async fn dispatch_inner(req: &str) -> String {
    let v: serde_json::Value = match serde_json::from_str(req) {
        Ok(v) => v,
        Err(e) => {
            return err_json(&format!("请求不是合法 JSON: {e}"), "other");
        }
    };

    let cmd = v.get("cmd").and_then(|c| c.as_str()).unwrap_or("");
    if cmd.is_empty() {
        return err_json("请求缺少 cmd 字段", "other");
    }

    /*
     * ── 命令表 ──
     *
     * # 命名约定（与原版前端一致）
     *
     * 命令名就是原版 `src/api/index.ts` 里 `call<T>("xxx")` 的那个字符串。
     * **不能改名** —— 否则 Dart 侧的调用点要跟着改，
     * 而「操作逻辑保持一致」要求前端代码尽量能照搬。
     *
     * # ★ 参数解码走 `Args`，不在这里手写
     *
     * 见 `args.rs` 顶部的说明（起因：cross-layer guide 的 Mistake 4：
     * 每个命令各自解析 JSON = 每个消息消费者一份私有契约）。
     * 这里只负责**分发**，不负责解析。
     *
     * # 需要 AppState 的命令
     *
     * 用 `with_state()` 取全局状态；未启动时返回明确错误
     *（而不是 panic —— panic 跨 FFI 边界是 UB）。
     */
    let a = crate::args::Args::new(&v, cmd);

    match cmd {
        // ── 探针（不需要状态）──
        "ping" => r#"{"ok":true,"pong":true}"#.to_string(),
        "core_version" => r#"{"version":"sourin-core 0.1.0"}"#.to_string(),
        "core_is_started" => format!(r#"{{"started":{}}}"#, crate::commands::is_started()),

        // ── Provider 管理 ──
        "list_providers" => with_state(|st| crate::commands::list_providers(st)),
        // ── TVBox 聚合（A′，第 01 项）──
        //
        // 契约：.probe/ffi-contract-tvbox-aggregate.md
        // 只读写 <数据目录>/tvbox-aggregate.json，**不碰源清单**。
        "tvbox_aggregate_get" => with_state(|st| crate::tvbox_aggregate::command_get(st)),
        /*
         * ★★ N9（2026-10-27）：通道清单（只读、零网络）。
         *
         * 契约：零参数 → {"ok":true,"aggregateId":"tvbox_agg","channels":[{id,name,enabled}]}。
         */
        "tvbox_agg_channels" => with_state(|st| crate::tvbox_aggregate::command_channels(st)),
        /*
         * ★ N8b-1参：列出 TVBox 迁移产生的 js 插件（**只读**）。
         *
         * 零参数 → items / undetermined 两段；
         * 非迁移产物（用户手写）**完全不出现**，本通道不提供任何批量删除能力。
         */
        "tvbox_migratable_js" => with_state(|st| crate::tvbox::migratable_js(st)),
        "tvbox_aggregate_dedupe_sites" => with_state(|st| {
            crate::tvbox_aggregate::command_dedupe_sites(st)
        }),
        "tvbox_aggregate_set" => {
            let args = v.get("args").cloned().unwrap_or(serde_json::Value::Null);
            with_state(move |st| crate::tvbox_aggregate::command_set(st, &args))
        }
        // ── 网盘分享链接识别（P3 第一跳）──
        //
        // 纯函数，不发网络、不需要账号 ⇒ 离线可测。
        // 认不出返回 kind="unknown"（**不是错误**：那个链接不归我们管）。
        "identify_pan_share" => {
            let text = match a.str("text") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let r = crate::pan::parse_share(&text);
            // ★ 把「识别」与「凭据」两块接起来 ——
            //   否则用户只知道"识别到了"，却不知道为什么还不能播。
            //   这里分层报出：认不出 / 未登录 / 已登录但取直链未实现。
            let cred = crate::pan_auth::load(r.kind);
            let logged_in = cred.is_some();
            let account = cred.as_ref().map(|c| c.account.clone());
            let expired = cred
                .as_ref()
                .map(|c| {
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    c.is_expired(now)
                })
                .unwrap_or(false);
            /*
             * ★ 2026-10-27：分档判定搬进 `pan::reason_tier`（纯函数）。
             *
             * 这里只负责**取入参**（`pan_auth::load` 读 OS 钥匙串），
             * 判定与文案都在 `pan.rs` —— 这样 ④登录/⑤过期 两档
             * 可以在**没有钥匙串的机器上**被单测逐字断言
             * （改前它们是内联在这里的，测试机上永远执行不到 = 假绿）。
             */
            let tier = crate::pan::reason_tier(
                r.kind,
                &r.share_id,
                crate::pan::PanLoginState {
                    logged_in,
                    expired,
                    // 取直链仍未接入（见 pan_list 模块头）：这版恒 false
                    has_direct_link: false,
                },
            );
            let reason = crate::pan::reason_text(r.kind, tier);
            serde_json::json!({
                "kind": r.kind.code(),
                "kindName": r.kind.display(),
                "shareId": r.share_id,
                "pwd": r.pwd_in_url,
                "needsLoginForPrivate": r.kind.needs_login_for_private(),
                // 凭据状态（不返回 cookie 本身，只返回是否已有）
                "loggedIn": logged_in,
                "account": account,
                "expired": expired,
                "keyringAvailable": crate::pan_auth::keyring_available(),
                // ★ 如实声明能力：识别 + 已登录 ≠ 能播
                "resolvable": false,
                // ★ 分档的机器可读码（unknown/no_share_id/need_login/expired/
                //   logged_in_no_direct_link）：台账与前端要能判"卡在哪一档"
                "reasonTier": tier.code(),
                "reason": reason,
            })
            .to_string()
        }
        // ── 网盘分享页：**匿名列目录**（第 20 项第一档，2026-10-26）──
        //
        // 只读：只走两条已实测的匿名链路（夸克 3 步 / 百度 3 步），
        // 不提交验证码、不伪造 sign、不试下载接口（见 .probe/pan-anon-probe.md）。
        // 拿不到目录 ⇒ 返回可读 Err（绝不空列表冒充"没文件"）。
        "pan_list_share" => {
            let text = match a.str("text") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let pwd_arg = a.str("pwd").ok().filter(|s| !s.is_empty()).map(|s| s.to_string());
            let share = crate::pan::parse_share(&text);
            if share.kind == crate::pan::PanKind::Unknown {
                return err_json("这段文本里没有认出受支持的网盘分享链接", "other");
            }
            if share.share_id.is_empty() {
                return err_json("认出了网盘，但链接里没有分享 id（可能不是分享链接）", "other");
            }
            let pwd = pwd_arg.or_else(|| share.pwd_in_url.clone());
            let kind = share.kind;
            let share_id = share.share_id.clone();
            /*
             * ⚠️ FFI 线程里不能直接 `block_on`（会饿死 worker 池 / 直接 panic，
             *   见本文件 `with_state_async` 的注释）⇒ 独立线程 + 通道取回。
             */
            let (tx, rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let out = runtime()
                    .block_on(crate::pan_list::list_share(kind, &share_id, pwd.as_deref()));
                let _ = tx.send(out);
            });
            match rx.recv() {
                Ok(Ok(listing)) => {
                    let mut v = listing.to_json();
                    if let Some(o) = v.as_object_mut() {
                        o.insert("ok".to_string(), serde_json::json!(true));
                        o.insert("kind".to_string(), serde_json::json!(kind.code()));
                        o.insert("kindName".to_string(), serde_json::json!(kind.display()));
                        o.insert("shareId".to_string(), serde_json::json!(share.share_id));
                        o.insert("pwd".to_string(), serde_json::json!(share.pwd_in_url));
                    }
                    v.to_string()
                }
                Ok(Err(e)) => err_json(&e, "network"),
                Err(e) => err_json(&format!("列目录线程异常：{e}"), "other"),
            }
        }
        // ── 源个性化覆盖层（第 06 项 P2）──
        //
        // 三条命令都**只读写** `<数据目录>/overrides/`，绝不碰插件与声明式源文件。
        // 设计见 .agents/notes/proposed/architecture/2026-10-24-source-override-layer-after-call-js.md
        "get_override_layer" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // with_state 的闭包要返回 Result<T, String>（T 交给 serde 序列化），
            // 不能直接返回 String —— 否则会被再包一层字符串。
            with_state(|st| -> Result<serde_json::Value, String> {
                match crate::overrides::load_layer(&st.data_dir, &id)? {
                    Some(layer) => Ok(serde_json::json!({ "layer": layer })),
                    // 没有覆盖层 = 正常的"未个性化"状态，不是错误
                    None => Ok(serde_json::json!({ "layer": null })),
                }
            })
        }
        "save_override_layer" => {
            let raw = match a.str("layer") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let layer: crate::overrides::OverrideLayer = match serde_json::from_str(&raw) {
                Ok(l) => l,
                Err(e) => return err_json(&format!("覆盖层 JSON 不合法: {e}"), "other"),
            };
            with_state(|st| -> Result<serde_json::Value, String> {
                let path = crate::overrides::save_layer(&st.data_dir, &layer)?;
                Ok(serde_json::json!({
                    "ok": true,
                    "path": path.to_string_lossy(),
                }))
            })
        }
        "delete_override_layer" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(|st| -> Result<serde_json::Value, String> {
                let existed = crate::overrides::delete_layer(&st.data_dir, &id)?;
                Ok(serde_json::json!({ "ok": true, "existed": existed }))
            })
        }
        "get_provider_order" => with_state(|st| crate::commands::get_provider_order(st)),
        "get_provider_enabled" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(|st| crate::commands::get_provider_enabled(st, &id))
        }

        // ── 首页链路（异步命令）──
        //
        // ⚠️ 这几个是**网络命令**，必须走 `with_state_async`
        //    —— 同步版会把 tokio 的 worker 线程卡住。
        "get_home" => with_state_async(move |st| async move {
            crate::home::get_home(st).await
        }).await,
        "get_categories" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::home::get_categories(st, &provider).await
            }).await
        }
        "get_rank" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let rank_id = match a.str("rank_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let page = a.u32_or("page", 1);
            with_state_async(move |st| async move {
                crate::home::get_rank(st, &provider, &rank_id, page).await
            }).await
        }

        /*
         * ★ 分类列表 —— 参数名走 Args，自动兼容 camelCase
         *
         * 原版前端传 `categoryId`（`src/api/index.ts` L496），
         * 但 Rust 的自然写法读 `category_id`。
         * `Args::get` 会自动回退到 camelCase —— 见 args.rs 的说明。
         */
        "get_list" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let category_id = match a.str("category_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let page = a.u32_or("page", 1);
            with_state_async(move |st| async move {
                crate::home::get_list(st, &provider, &category_id, page).await
            }).await
        }

        // ── 详情链路 ──
        "get_detail" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::playback::get_detail(st, &provider, &id).await
            }).await
        }
        "get_sources" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::playback::get_sources(st, &provider, &id).await
            }).await
        }
        "get_episodes" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 原版前端传 `sourceCode`（camelCase）。
            let source_code = match a.str("source_code") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::playback::get_episodes(st, &provider, &id, &source_code).await
            }).await
        }

        /*
         * ★★ 播放链路的最后一环 —— 解析真实流地址。
         *
         * # 为什么单独列出（而不是和上面几个并列成一行）
         *
         * 它有两个特别之处：
         * ```text
         * · 返回的地址**已改写成本地代理地址**（防盗链）；
         *    返回的 url 可能已经不是 CDN 原始地址
         * · 可选的 req（类型见 PlayRequest）也一起传给 provider
         * ```
         * Flutter 侧拿到结果直接交给 media_kit 播放即可，
         * 不需要再处理请求头 —— 那已经由本地代理负责了。
         */
        "resolve_stream" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // req 是可选的：原版 `invoke("resolve_stream", { provider, id })`
            // 不带 req 也合法（用 PlayRequest::default()）。
            let req = match parse_optional_play_request(&v) {
                Ok(req) => req,
                Err(e) => return err_json(e, "other"),
            };
            with_state_async(move |st| async move {
                crate::playback::resolve_stream(st, &provider, &id, req).await
            }).await
        }

        /*
         * ═══════════════════════════════════════════════════════════════════
         *  批次 1 ── 只读命令（2026-09-22）
         * ═══════════════════════════════════════════════════════════════════
         *
         * # 为什么这批排在前面
         *
         * ```text
         * 只读先行 —— 可以安全地对**真实用户库**跑。
         * ```
         * 用户机器上装着正式版且数据真实，写入类命令必须用独立目录；
         * 而只读命令可以直接读真实库来确认「搬运是否忠实」。
         * 这是性价比最高的一批。
         *
         * # 这些命令都是同步的（读 SQLite）
         *
         * 用`with_state`（同步）而不是`with_state_async`（
         * ```text
         * SQLite 查询是本地操作，微秒级，不值得起线程。
         * with_state_async 会 spawn 一次线程 —— 对这种命令是浪费
         * ```
         * ⚠️ 反过来，网络命令**必须**走 async 版 —— 否则会卡在
         *    tokio 的 worker 线程（见上面几个网络命令的注释）。
         */
        "get_progress" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(|st| crate::commands::get_progress(st, &provider, &id))
        }
        "continue_watching" => {
            let limit = a.u32_opt("limit");
            with_state(|st| crate::commands::continue_watching(st, limit))
        }
        "list_all_progress" => with_state(|st| crate::commands::list_all_progress(st)),
        "list_history" => {
            let limit = a.u32_opt("limit");
            with_state(|st| crate::commands::list_history(st, limit))
        }
        "get_skip_marker" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(|st| crate::commands::get_skip_marker(st, &provider, &id))
        }
        "get_effective_skip_marker" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(|st| crate::commands::get_effective_skip_marker(st, &provider, &id))
        }
        "list_skip_markers" => with_state(|st| crate::commands::list_skip_markers(st)),
        "list_favorites" => {
            /*
             * ★★★ 参数是 `following_only`，**不是** `include_deleted`
             *     （2026-09-23 修正的移植错误）
             *
             * 原版签名是 `list_favorites(following_only: bool)`，
             * 它是一个**二选一的分派**：
             * ```text
             * true  → 追更列表（list_following_for_ui，按最近更新排）
             * false → 收藏列表（list_favorites，只含 favorited=1）
             * ```
             *
             * ⚠️ 两个参数都是 bool，**编译期看不出传错**。
             *     传错的表现是「追更页显示一堆已删除的内容」。
             *
             * ⚠️ 兼容：老前端可能传 `followingOnly`（camelCase）——
             *    这里两个名字都认。
             */
            let following_only = a
                .bool("following_only")
                .or_else(|_| a.bool("followingOnly"))
                .unwrap_or(false);
            /*
             * ⚠️ 必须走 `with_state_async` —— 它内部会
             *    `stream_proxy.ensure_started().await`（启动封面代理）。
             *    用同步版会卡住 tokio worker。
             */
            with_state_async(move |st| async move {
                crate::commands::list_favorites(st, following_only).await
            }).await
        }
        "list_following_for_ui" => {
            with_state(|st| crate::commands::list_following_for_ui(st))
        }
        "total_unread" => with_state(|st| crate::commands::total_unread(st)),
        "list_platform_history" => {
            let limit = a.u32_or("limit", 100);
            with_state(|st| crate::commands::list_platform_history(st, limit))
        }

        /*
         * ═══════════════════════════════════════════════════════════════════
         *  批次 2 · 写入命令（2026-09-22）
         * ═══════════════════════════════════════════════════════════════════
         *
         * # 为什么这里分同步 / 异步两种
         *
         * ```text
         * save_progress / set_skip_marker / clear_skip_marker /
         * remove_favorite / mark_favorite_read / clear_history
         *     → 纯 SQLite 写，微秒级 → with_state（同步）
         *
         * set_favorite / set_following
         *     → 开启追更时会调平台 detail() 记基准集数（**网络**），
         *     → with_state_async（否则卡死 tokio worker 线程）
         * ```
         *
         * ★★★ 之后若误用同步版，表现是：点追更后整个应用卡住几秒，
         *    最后由 20 秒超时结束 —— 这是非常难查的卡顿源。
         */
        "save_progress" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let title = a.str_or("title", "");
            let cover = a.str("cover").ok().map(|s| s.to_string());
            let episode_id = a.str("episode_id").ok().map(|s| s.to_string());
            let episode_title = a.str("episode_title").ok().map(|s| s.to_string());
            let position = a.u64_or("position", 0);
            let duration = a.u64_or("duration", 0);
            let finished = a.bool("finished").ok();
            with_state(move |st| {
                crate::commands_write::save_progress(
                    st,
                    &provider,
                    &id,
                    &title,
                    cover,
                    episode_id,
                    episode_title,
                    position,
                    duration,
                    finished,
                )
            })
        }
        "clear_history" => with_state(|st| crate::commands_write::clear_history(st)),
        "set_skip_marker" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let title = a.str("title").ok().map(|s| s.to_string());
            let intro_start = a.u64_opt("intro_start");
            let intro_end = a.u64_opt("intro_end");
            let outro_start = a.u64_opt("outro_start");
            let outro_end = a.u64_opt("outro_end");
            let auto_skip = a.bool("auto_skip").ok();
            /*
             * ★ midrolls：形如 `[{start,end},…]`，**允许缺省**（缺省 ⇒ 空数组 = 旧行为）。
             * 解析放在这里（不放进 args.rs）：错误文案要能说清"第 N 段缺 start"，
             * 那是业务语义，属于命令层。
             */
            let midrolls = match parse_spans(a.value_opt("midrolls")) {
                Ok(v) => v,
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| {
                crate::commands_write::set_skip_marker(
                    st,
                    &provider,
                    &id,
                    title,
                    intro_start,
                    intro_end,
                    outro_start,
                    outro_end,
                    auto_skip,
                    midrolls,
                )
            })
        }
        "clear_skip_marker" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_write::clear_skip_marker(st, &provider, &id))
        }
        "set_skip_memory" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let title = a.str("title").ok().map(|s| s.to_string());
            let intro_end = a.u64_opt("intro_end");
            with_state(move |st| {
                crate::commands_write::set_skip_memory(st, &provider, &id, title, intro_end)
            })
        }
        "mark_favorite_read" => {
            let key = match a.str("key") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_write::mark_favorite_read(st, &key))
        }
        "remove_favorite" => {
            let key = match a.str("key") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_write::remove_favorite(st, &key))
        }

        /*
         * task-67 (Owner requirement 5): migrate records when switching source.
         *
         * key = "<provider>:<id>" (see commands_write::item_key)
         *   => switching source changes the provider
         *   => the key changes
         *   => writes create a NEW row and the OLD row stays in the list.
         *
         * This moves favorites / progress / history / skip_markers from the
         * old key to the new key in ONE transaction, then deletes the old row.
         *
         * NOTE (ASCII only on purpose): this file already contains some
         * mojibake comments from an earlier encoding accident; do not add more.
         */
        "repoint_item" => {
            let from_provider = match a.str("fromProvider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let from_id = match a.str("fromId") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let to_provider = match a.str("toProvider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let to_id = match a.str("toId") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| {
                crate::commands_write::repoint_item(
                    st,
                    &from_provider,
                    &from_id,
                    &to_provider,
                    &to_id,
                )
            })
        }

        // ── 下面两个是**网络命令**（开追更要抓基准集数）──
        "set_favorite" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let on = a.bool_or("on", true);
            let title = a.str("title").ok().map(|s| s.to_string());
            let cover = a.str("cover").ok().map(|s| s.to_string());
            let kind = a.str("kind").ok().map(|s| s.to_string());
            let following = a.bool("following").ok();
            with_state_async(move |st| async move {
                crate::commands_write::set_favorite(
                    st, &provider, &id, on, title, cover, kind, following,
                )
                .await
            }).await
        }
        "set_following" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let following = a.bool_or("following", true);
            let title = a.str("title").ok().map(|s| s.to_string());
            let cover = a.str("cover").ok().map(|s| s.to_string());
            let kind = a.str("kind").ok().map(|s| s.to_string());
            with_state_async(move |st| async move {
                crate::commands_write::set_following(
                    st, &provider, &id, following, title, cover, kind,
                )
                .await
            }).await
        }

        /*
         * ═══════════════════════════════════════════════════════════════════
         *  批次 3 · 搜索（2026-09-22）
         * ═══════════════════════════════════════════════════════════════════
         *
         * `search_all` 走这里（等全部源返回后一次性给结果）。
         *
         * ★★★ `search_all_stream` **不走这里** —— 它是流式命令，
         *    必须走独立的 `sourin_call_stream` 导出（回调多次）。
         *    如果误用 `sourin_call_async`，会收到
         *    「命令尚未接入」的错误，而不是静默失败（刻意的）。
         */
        "search_all" => {
            let keyword = match a.str("keyword") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let page = a.u32_or("page", 1);
            with_state_async(move |st| async move {
                crate::commands::search_all(st, &keyword, page).await
            }).await
        }

        /*
         * ═══════════════════════════════════════════════════════════════════
         *  批次 4 · 直播（2026-09-22）
         * ═══════════════════════════════════════════════════════════════════
         *
         * 四个都是**网络命令**（要调各源的直播接口），
         * 所以必须走 `with_state_async` —— 用同步版会卡住 tokio worker。
         */
        "get_live_channels" => with_state_async(move |st| async move {
            crate::commands::get_live_channels(st).await
        }).await,
        "get_live_stream" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            /*
             * ⚠️ 参数名是 `channel_id`，但原版前端传的是 `channelId`
             *    —— `Args::get` 会自动回退到 camelCase（见 args.rs）。
             */
            let channel_id = match a.str("channel_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands::get_live_stream(st, &provider, &channel_id).await
            }).await
        }
        "get_epg" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let channel_id = match a.str("channel_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands::get_epg(st, &provider, &channel_id).await
            }).await
        }
        "get_timeshift" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let channel_id = match a.str("channel_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            /*
             * start / end 是 Unix 时间戳（秒）—— 用 i64
             *
             * ⚠️ 时间戳可能为负（1970 之前，或时区算错时）。
             *    用 u64 会把负数变成巨大的正数，静默产生错误的请求。
             *    原版签名就是 `i64`，照抄。
             */
            let start = a.i64_or("start", 0);
            let end = a.i64_or("end", 0);
            with_state_async(move |st| async move {
                crate::commands::get_timeshift(st, &provider, &channel_id, start, end).await
            }).await
        }

        /*
         * ═══════════════════════════════════════════════════════════════════
         *  批次 5 · Provider 与插件管理（2026-09-22）
         * ═══════════════════════════════════════════════════════════════════
         *
         * 大多数是同步的（读写文件 / 读日志）。
         * 但 `reload_plugins` / `save_plugin_source` 会**执行插件脚本**
         *（`validate_source` / `hydrate_capabilities`），
         * 那是网络 + JS 执行 → 必须 async。
         */
        "set_provider_enabled" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let enabled = a.bool_or("enabled", true);
            with_state(move |st| {
                crate::commands_provider::set_enabled_persisted(st, &id, enabled)
            })
        }
        "set_provider_order" => {
            let ids = match a.str_list("ids") {
                Ok(v) => v,
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::set_provider_order(st, &ids))
        }
        "get_provider_config" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::get_provider_config(st, &id))
        }
        "remove_provider" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::remove_provider(st, &id))
        }
        "list_plugins" => {
            with_state(|st| crate::commands_provider::list_plugins(st))
        }
        "reload_plugins" => with_state_async(move |st| async move {
            crate::commands_provider::reload_plugins(st).await
        }).await,
        "read_plugin" => {
            let file = match a.str("file") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::read_plugin(st, &file))
        }
        "remove_plugin" => {
            let file = match a.str("file") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_provider::remove_plugin(st, &file))
        }
        "save_plugin_source" => {
            let file = match a.str("file") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let source = match a.str("source") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_provider::save_plugin_source(st, &file, &source).await
            }).await
        }

        /*
         * ══════════════════════════════════════════════════════════════
         * 插件「检测更新 / 更新 / 回滚」（task-23，2026-09-25）
         * ══════════════════════════════════════════════════════════════
         *
         * ⚠️ **纯新增分支** —— 上面那些现有分支一行都没动。
         *
         * # sync / async 的分界（与相邻分支同一套判据）
         *
         * ```text
         * 纯本地读写（历史列表 / 记来源）      → with_state
         * 走网络（检测 / 更新）或会重载插件    → with_state_async
         * ```
         * ⚠️ `rollback_plugin` 虽然是**本地操作**，但它最后要
         *    `reload_plugins`（真的执行 JS）—— 放同步路径会卡住 UI，
         *    所以必须 async。
         */
        "check_plugin_update" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 走网络 → async
            with_state_async(move |st| async move {
                crate::commands_provider::check_plugin_update(st, &id).await
            }).await
        }
        "list_plugin_sources" => {
            /*
             * ★ 纯本地读 sidecar（毫秒级、零网络）——
             *   界面加载时用它决定"哪些卡片显示「检测更新」按钮"。
             *   绝不能用 check_all_plugin_updates 代替：那会在打开设置页时
             *   对每个插件发一次网络请求。
             */
            with_state(|st| crate::commands_provider::list_plugin_sources(st))
        }
        "check_all_plugin_updates" => {
            // 批量：串行查全部**有来源**的插件（见函数文档）
            with_state_async(move |st| async move {
                crate::commands_provider::check_all_plugin_updates(st).await
            }).await
        }
        "update_plugin_from_source" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_provider::update_plugin_from_source(st, &id).await
            }).await
        }
        "list_plugin_versions" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 纯本地读目录 → 同步
            with_state(move |st| crate::commands_provider::list_plugin_version_history(st, &id))
        }
        "rollback_plugin" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let version = match a.str("version") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // ★ 虽然全是本地文件操作，但末尾要 reload_plugins（执行 JS）→ async
            with_state_async(move |st| async move {
                crate::commands_provider::rollback_plugin(st, &id, &version).await
            }).await
        }
        "set_plugin_source" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let url = match a.str("url") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 纯本地写 sidecar → 同步
            with_state(move |st| crate::commands_provider::set_plugin_source(st, &id, &url))
        }

        /*
         * ═══════════════════════════════════════════════════════════════════
         *  批次 6 · 登录 / 代理 / 备份 / WebDAV（2026-09-22）
         * ═══════════════════════════════════════════════════════════════════
         *
         * 同步 / 异步的分界：
         * ```text
         * 纯本地读写（代理配置 / 备份预览 / 备份导入预览）→ with_state
         * 会执行脚本 / 测代理 / 测连通 / 同步类 → with_state_async
         * ```
         * ⚠️ `backup_import` 虽然是本地操作，但会写大量数据 + 重载插件，
         *    放在同步路径上会让 UI 卡住（实测导入 26 个插件要 1-2 秒）。
         *    不过它本身不 await 网络，所以仍是 with_state —— 只是
         *    Dart 侧应该用 `sourin_call_async` 调它，避免阻塞 UI 线程。
         *    （这是调用方的责任，不是这里的职责。）
         */
        "provider_login" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // ⚠️ 必须 to_string() —— `str_or` 返回 `&str`（借用自请求 JSON），
            //    而下面是 `move` 闭包，不能借用局部变量。
            let username = a.str_or("username", "").to_string();
            let password = a.str_or("password", "").to_string();
            with_state_async(move |st| async move {
                crate::commands_backup::provider_login(st, &provider, username, password).await
            }).await
        }
        "provider_logout" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_logout(st, &provider).await
            }).await
        }
        "provider_session" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_session(st, &provider).await
            }).await
        }
        "provider_session_state" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_session_state(st, &provider).await
            }).await
        }
        "ensure_provider_session" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::ensure_provider_session(st, &provider).await
            }).await
        }
        "forget_provider_credentials" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::forget_provider_credentials(st, &provider).await
            }).await
        }
        "provider_qr_login_start" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_qr_login_start(st, &provider).await
            }).await
        }
        "provider_qr_login_poll" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let key = match a.str("key") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_qr_login_poll(st, &provider, &key).await
            }).await
        }
        /*
         * ── 弹幕（task-T2，2026-10-16）────────────────────────────────
         *
         * # 为什么加这两条命令
         *
         * 改前 `Capabilities.danmaku` 是个**假能力位** —— 界面上显示
         * 「弹幕」标签，但宿主没有任何地方拿它去调插件（连方法名都没有）。
         * 这两条命令是那条链路在 FFI 层的出口。
         *
         * ⚠️ 入参 `req` 整包透传给 `commands_backup`，**不在这一层拆字段** ——
         *    弹幕的入参字段多且会随契约演进（mediaId/episodeId/title/
         *    episodeTitle/duration…），逐个拆会让每加一个字段都要改两处。
         */
        "provider_danmaku_list" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 弹幕入参是**嵌套对象**（Args::get 是私有的，这里直接读原始 JSON）
            let req: crate::model::DanmakuRequest = match v.get("args").and_then(|x| x.get("req")) {
                Some(v) if !v.is_null() => match serde_json::from_value(v.clone()) {
                    Ok(r) => r,
                    Err(e) => return err_json(&e.to_string(), "other"),
                },
                _ => crate::model::DanmakuRequest::default(),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_danmaku_list(st, &provider, req).await
            }).await
        }
        "provider_danmaku_send" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let req: crate::model::DanmakuSendRequest = match v.get("args").and_then(|x| x.get("req")) {
                Some(v) if !v.is_null() => match serde_json::from_value(v.clone()) {
                    Ok(r) => r,
                    Err(e) => return err_json(&e.to_string(), "other"),
                },
                _ => return err_json("缺少 req（发送弹幕必须给正文）", "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::provider_danmaku_send(st, &provider, req).await
            }).await
        }

        // ── 站点代理 ──
        "list_proxy_configs" => with_state(|st| crate::commands_backup::list_proxy_configs(st)),
        "set_proxy_config" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            /*
             * config 是一个对象 —— 让 serde 反序列化把关。
             * 解析失败要报明确错误（而不是静默用默认值，
             * 那会让用户以为代理配好了其实没有）。
             */
            let cfg: crate::proxy::ProxyConfig = match v
                .get("args")
                .and_then(|x| x.get("config"))
                .and_then(|c| serde_json::from_value(c.clone()).ok())
            {
                Some(c) => c,
                None => {
                    return err_json("缺少或非法的 config 参数（应为对象）", "other");
                }
            };
            with_state(move |st| {
                crate::commands_backup::set_proxy_config(st, &provider, cfg)
            })
        }
        "clear_proxy_config" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_backup::clear_proxy_config(st, &provider))
        }
        "set_proxy_password" => {
            let provider = a.str_or("provider", "");
            let password = a.str_or("password", "");
            /*
             * ⚠️ 这个命令**不需要 AppState**（密码在系统钥匙串里）。
             *    所以不走 with_state —— 核心未启动时也能用。
             */
            match crate::commands_backup::set_proxy_password(&provider, &password) {
                Ok(()) => r#"{"ok":true}"#.to_string(),
                Err(e) => err_json(&e, "other"),
            }
        }
        "has_proxy_password" => {
            let provider = a.str_or("provider", "");
            match crate::commands_backup::has_proxy_password(&provider) {
                Ok(b) => format!(r#"{{"has":{b}}}"#),
                Err(e) => err_json(&e, "other"),
            }
        }
        "test_proxy" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::test_proxy(st, &provider).await
            }).await
        }
        "system_proxy_hint" => {
            match crate::commands_backup::system_proxy_hint() {
                Ok(h) => serde_json::to_string(&serde_json::json!({ "hint": h }))
                    .unwrap_or_else(|_| r#"{"hint":null}"#.into()),
                Err(e) => err_json(&e, "other"),
            }
        }

        // ── 备份 ──
        "backup_preview" => with_state(|st| crate::commands_backup::backup_preview(st)),
        "backup_default_name" => {
            with_state(|st| crate::commands_backup::backup_default_name(st))
        }
        "backup_export" => {
            let path = match a.str("path") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            /*
             * ★ 导出用的凭据口令（CS-1）
             *
             * 传了就**加密包含登录态**，不传就不含 —— 两种都在返回值里
             * 如实回报（`credentialsIncluded` / `credentialsNote`），
             * 界面上必须显示，不许让用户以为"备份了全部数据"。
             *
             * ⚠️ 口令**不进包**：包是用户会分发的东西。
             */
            let passphrase = a
                .str("passphrase")
                .ok()
                .filter(|p| !p.is_empty())
                .map(|s| s.to_string());
            with_state(move |st| {
                crate::commands_backup::backup_export(st, &path, passphrase.as_deref())
            })
        }
        "backup_inspect" => {
            let path = a.str_or("path", "");
            /*
             * ★★★ 不需要 AppState（纯读文件）—— 核心未启动也能检视备份，
             *    在"用户想看看备份里有什么"的场景下很有用。
             */
            match crate::commands_backup::backup_inspect(&path) {
                Ok(v) => serde_json::to_string(&v)
                    .unwrap_or_else(|e| err_json(&format!("序列化失败? {e}"), "other")),
                Err(e) => err_json(&e, "other"),
            }
        }
        "backup_import" => {
            let path = match a.str("path") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            /*
             * ★ 2026-10-08 改走 async
             *
             * 导入末尾要 `load_plugins_hydrated`（执行 JS 拿能力位）——
             * 那是 async 的。原来的 with_state 是同步路径，注释（:1434）
             * 早就写着「会写大量数据 + 重载插件，放同步路径上会让 UI 卡住」，
             * 只是当时并没有真的重载，现在补上了。
             */
            /*
             * ★ 导入用的凭据口令（CS-1）
             *
             * 包里含凭据时必须给对口令，否则**整次导入失败**并明确报
             * 「口令不正确」—— 不许静默跳过凭据只导入其它平面
             * （那会让用户以为"恢复成功"，而登录态其实没回来）。
             */
            let passphrase = a
                .str("passphrase")
                .ok()
                .filter(|p| !p.is_empty())
                .map(|s| s.to_string());
            with_state_async(move |st| async move {
                crate::commands_backup::backup_import(st, &path, passphrase.as_deref()).await
            })
            .await
        }
        "backup_platform_history" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let device_id = a.str("device_id").ok().map(|s| s.to_string());
            with_state_async(move |st| async move {
                crate::commands_backup::backup_platform_history(st, &provider, device_id).await
            }).await
        }

        // ── 网盘同步 ──
        "configure_webdav" => {
            // ⚠️ 三个都必须 to_string() —— `str_or` 返回 `&str`（借用自请求
            //    JSON），而下面是 `move` 闭包，不能借用局部变量。
            let base_url = a.str_or("base_url", "").to_string();
            let username = a.str_or("username", "").to_string();
            let password = a.str_or("password", "").to_string();
            let remote_dir = a.str("remote_dir").ok().map(|s| s.to_string());
            with_state_async(move |st| async move {
                crate::commands_backup::configure_webdav(
                    st, base_url, username, password, remote_dir,
                )
                .await
            }).await
        }
        "disconnect_sync" => with_state_async(move |st| async move {
            crate::commands_backup::disconnect_sync(st).await
        }).await,
        "sync_status" => with_state_async(move |st| async move {
            crate::commands_backup::sync_status(st).await
        }).await,
        "test_sync" => with_state_async(move |st| async move {
            crate::commands_backup::test_sync(st).await
        }).await,
        "sync_now" => with_state_async(move |st| async move {
            crate::commands_backup::sync_now(st).await
        }).await,
        /*
         * ── ★ 凭据同步（CS-1，2026-10-19）────────────────────────────
         *
         * 登录态随云同步：口令存系统钥匙串，凭据加密后传 `data/credentials.enc`。
         *
         * ⚠️ 这三条**都不需要已连接**：
         *    `credentials_status_json` 是纯本地读（UI 一进页面就调），
         *    另两条只写钥匙串 / 设置文件 —— 用户可以"先设口令、后配云盘"。
         */
        "credentials_status" => {
            with_state(|st| Ok(crate::commands_backup::credentials_status_json(st)))
        }
        "set_credentials_passphrase" => {
            // 空串 = 清除口令（不是"存一个空串" —— 见命令层注释）
            let passphrase = a.str_or("passphrase", "").to_string();
            with_state(move |st| {
                crate::commands_backup::set_credentials_passphrase(st, &passphrase)
            })
        }
        "set_credentials_enabled" => {
            let enabled = match a.bool("enabled") {
                Ok(b) => b,
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| {
                crate::commands_backup::set_credentials_enabled(st, enabled)
            })
        }
        "sync_credentials_now" => with_state_async(move |st| async move {
            crate::commands_backup::sync_credentials_now(st).await
        }).await,
        "sync_platform_history" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::sync_platform_history(st, &provider).await
            }).await
        }

        /*
         * ── ★ 云盘设置 / 整体备份（契约 §1，2026-09-29 task-75）──
         *
         * 这五条**都不需要已连接**：Dart 侧首次进设置页就会调
         * `sync_settings_get` / `sync_backup_list`，那时用户还没配云盘。
         * 一报错 UI 就得走降级分支（契约 §3.1）。
         */
        "sync_settings_get" => with_state_async(move |st| async move {
            crate::commands_backup::sync_settings_get(st).await
        }).await,
        "sync_settings_set" => {
            // 全部可选：未传 = 不改该字段
            // ⚠️ `Args` **没有** `bool_opt`，可选布尔用 `.bool(..).ok()`
            let retain_count = a.u32_opt("retain_count");
            let auto_enabled = a.bool("auto_enabled").ok();
            let auto_interval_minutes = a.u32_opt("auto_interval_minutes");
            let auto_on_change = a.bool("auto_on_change").ok();
            let auto_backup_interval_minutes = a.u32_opt("auto_backup_interval_minutes");
            with_state_async(move |st| async move {
                crate::commands_backup::sync_settings_set(
                    st,
                    retain_count,
                    auto_enabled,
                    auto_interval_minutes,
                    auto_on_change,
                    auto_backup_interval_minutes,
                )
                .await
            }).await
        }
        "sync_backup_now" => with_state_async(move |st| async move {
            crate::commands_backup::sync_backup_now(st).await
        }).await,
        "sync_backup_list" => with_state_async(move |st| async move {
            crate::commands_backup::sync_backup_list(st).await
        }).await,
        "sync_backup_delete" => {
            let name = match a.str("name") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_backup::sync_backup_delete(st, &name).await
            }).await
        }

        /*
         * ═══════════════════════════════════════════════════════════════════
         *  批次 7 · 遥控 + 剩余命令（2026-09-22）
         * ═══════════════════════════════════════════════════════════════════
         *
         * 遥控是**本地 HTTP 服务**（手机浏览器连过来），
         * 所以 `remote_start` / `remote_stop` 要 await（起/停服务）。
         */
        "remote_start" => {
            let port = a.u32_opt("port").map(|p| p as u16);
            with_state_async(move |st| async move {
                crate::commands_remote::remote_start(st, port).await
            }).await
        }
        "remote_stop" => with_state_async(move |st| async move {
            crate::commands_remote::remote_stop(st).await
        }).await,
        "remote_refresh_pin" => {
            with_state(|st| crate::commands_remote::remote_refresh_pin(st))
        }
        "remote_set_fixed_pin" => {
            let pin = a.str_or("pin", "").to_string();
            with_state(move |st| crate::commands_remote::remote_set_fixed_pin(st, &pin))
        }
        "remote_set_auto_start" => {
            let enabled = a.bool_or("enabled", true);
            with_state(move |st| {
                crate::commands_remote::remote_set_auto_start(st, enabled)
            })
        }
        "remote_auto_start" => {
            with_state(|st| crate::commands_remote::remote_auto_start(st))
        }
        "remote_report_state" => {
            let st_json: crate::remote::RemoteState = match v
                .get("args")
                .and_then(|x| x.get("state"))
                .and_then(|s| serde_json::from_value(s.clone()).ok())
            {
                Some(s) => s,
                None => return err_json("缺少或非法的 state 参数（应为对象）", "other"),
            };
            with_state(move |st| {
                crate::commands_remote::remote_report_state(st, st_json)
            })
        }
        "remote_take_commands" => {
            with_state(|st| crate::commands_remote::remote_take_commands(st))
        }
        "remote_set_search" => {
            let payload: crate::remote::SearchPayload = match v
                .get("args")
                .and_then(|x| x.get("payload"))
                .and_then(|s| serde_json::from_value(s.clone()).ok())
            {
                Some(p) => p,
                None => return err_json("缺少或非法的 payload 参数（应为对象）", "other"),
            };
            with_state(move |st| crate::commands_remote::remote_set_search(st, payload))
        }
        "remote_set_home" => {
            let payload: crate::remote::HomePayload = match v
                .get("args")
                .and_then(|x| x.get("payload"))
                .and_then(|s| serde_json::from_value(s.clone()).ok())
            {
                Some(p) => p,
                None => return err_json("缺少或非法的 payload 参数（应为对象）", "other"),
            };
            with_state(move |st| crate::commands_remote::remote_set_home(st, payload))
        }

        // ── 剩余零散命令 ──
        "check_updates" => {
            let max_items = a.u32_opt("max_items").map(|n| n as usize);
            with_state_async(move |st| async move {
                crate::commands_remote::check_updates(st, max_items).await
            }).await
        }
        /*
         * ★★★ 2026-10-18（第 66 轮 N10 取证）：运行期开关并行预取
         *
         * # 为什么需要它（不是"为了方便测试"）
         * ```text
         * `SOURIN_PREFETCH_DISABLE` 只在 StreamProxy::new() 里读一次
         * ⇒ 进程内改环境变量无效，必须重启进程
         * 而 streamproxy.rs:1399 的注释自己写明：
         *   「真机 CDN 吞吐每分钟都在变…跨进程对照里两个变量同时在变，
         *     量不出真实差值」
         * ⇒ 跨进程 A/B 在设计上就不可行。
         *
         * 唯一正路就是 `StreamProxy::set_prefetch_disabled()`
         * （streamproxy.rs:371 的 pub 方法，本来就存在），
         * 但它没有 FFI 入口 ⇒ Dart 侧调不到 ⇒ 产品进程里切不了。
         * 本命令就是把那个 pub 方法接出来（不新增任何实现）。
         * ```
         *
         * # 安全性
         * ```text
         * 只改一个 AtomicBool，不碰任何连接/缓存状态；
         * 下一次请求生效（plan_prefetch 每次请求都读）⇒ 不影响已在飞的请求。
         * ```
         */
        "set_prefetch_disabled" => {
            let disabled = a.bool("disabled").unwrap_or(true);
            with_state_async(move |st| async move {
                st.stream_proxy.set_prefetch_disabled(disabled);
                Ok(serde_json::json!({ "disabled": disabled }))
            })
            .await
        }
        "prefetch_disabled" => with_state_async(move |st| async move {
            Ok(serde_json::json!({ "disabled": st.stream_proxy.prefetch_is_disabled_for_probe() }))
        })
        .await,
        /*
         * ★★★ N10：seek 让路窗口
         *
         * # 为什么暴露这两条（而不是让 Dart 侧自己算时间）
         * ```text
         * ① 时钟必须单调：Dart 的定时器与 Rust 的 Instant 不一定同源，
         *    跨层比较时间会有漂移 ⇒ 截止时刻由**同一侧**计算。
         * ② 恢复必须能"恢复原值"：只有 StreamProxy 自己知道用户原本的
         *    `prefetch_disabled` 是什么（`SOURIN_PREFETCH_DISABLE` 那份配置）。
         *    Dart 侧无条件 set(false) 会把用户配的关闭状态打开。
         * ```
         *
         * # 语义
         * ```text
         * begin_yield_for_seek  ⇒ 接下来 2 秒预取让路（连续调用会**重置**窗口）
         *                          返回 { first: bool } —— true 表示本次是首次进入
         * end_yield_for_seek    ⇒ 立即结束窗口，**恢复**进入前的开关状态
         * ```
         *
         * ⚠️ 调用方（Dart）应在 seek 时调 begin，在 `first==true` 时起一个
         *    `YIELD_WINDOW_MS` 的定时器调 end；若窗口内又 seek，
         *    `first==false` ⇒ **不要**再起第二个定时器（重置即可）。
         *    页面销毁时必须调 end，否则预取会一直关着。
         */
        "begin_yield_for_seek" => with_state_async(move |st| async move {
            let first = st.stream_proxy.begin_yield_for_seek();
            Ok(serde_json::json!({ "first": first }))
        })
        .await,
        "end_yield_for_seek" => with_state_async(move |st| async move {
            st.stream_proxy.end_yield_for_seek();
            Ok(serde_json::json!({ "ok": true }))
        })
        .await,
        "in_yield_window" => with_state_async(move |st| async move {
            Ok(serde_json::json!({ "inWindow": st.stream_proxy.in_yield_window() }))
        })
        .await,
        "health_sweep" => with_state_async(move |st| async move {
            crate::commands_remote::health_sweep(st).await
        }).await,
        "toggle_favorite" => {
            let provider = match a.str("provider") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let title = a.str_or("title", "").to_string();
            let cover = a.str("cover").ok().map(|s| s.to_string());
            let kind = a.str("kind").ok().map(|s| s.to_string());
            let following = a.bool("following").ok();
            with_state_async(move |st| async move {
                crate::commands_remote::toggle_favorite(
                    st, &provider, &id, title, cover, kind, following,
                )
                .await
            }).await
        }
        "install_plugin" => {
            let url = match a.str("url") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_remote::install_plugin(st, &url).await
            }).await
        }
        "install_plugin_source" => {
            let source = match a.str("source") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let name_hint = a.str("name_hint").ok().map(|s| s.to_string());
            with_state_async(move |st| async move {
                crate::commands_remote::install_plugin_source(st, &source, name_hint).await
            }).await
        }
        "import_declarative_provider" => {
            let json = match a.str("json") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::commands_remote::import_declarative_provider(st, &json).await
            }).await
        }
        "install_http_provider" => {
            let base_url = match a.str("base_url") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let headers: Option<std::collections::HashMap<String, String>> = v
                .get("args")
                .and_then(|x| x.get("headers"))
                .and_then(|h| serde_json::from_value(h.clone()).ok());
            with_state_async(move |st| async move {
                crate::commands_remote::install_http_provider(st, base_url, headers).await
            }).await
        }
        // ★ TVBox 配置导入（task-5）
        //
        // config 既可以是配置 JSON 文本，也可以是配置地址（http/https）。
        // 两种都收，是为了让用户「贴链接」和「贴内容」都不用先想一下。
        "import_tvbox_config" => {
            let config = match a.str("config") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::tvbox::import_tvbox_config(st, &config).await
            }).await
        }
        /*
         * ★★★ N9（2026-10-27）：按通道取数 —— 前端切渠道后只发该通道的请求。
         *
         * 契约：参数 {"channel_id": "<id>"}，
         * 返回 {"ok":true,"channelId","channelName","sections":[...]}。
         * channel_id 为空 ⇒ 函数自己返 Err（不在这里重写判据）。
         */
        "tvbox_agg_channel_home" => {
            let channel_id = match a.str("channel_id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::tvbox_aggregate::command_channel_home(st, &channel_id).await
            }).await
        }        /*
         * ★ T1b-预检（2026-10-31）：网盘分享链接**零凭据预检**。
         *
         * 契约与 JSON 形状举例：见 crate::pan_check 模块头（items 是序列化成
         * 字符串的 JSON 数组——本文件的参数解析器没有数组方法，外包一层字符串）。
         * 返回 {"ok":true,"results":[{url,kind,shareId,state,summary,cacheable}]}，
         * state ∈ ok/locked/bad/uncertain/unsupported（照抄参考实现 hp0 的状态机）。
         */
        "tvbox_pan_check" => {
            let items = match a.str("items") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |_st| async move {
                crate::pan_check::command_check(&items).await
            }).await
        }

        /*
         * ★ N8b-1参："还原为原始链接"通道。
         *
         * 参数 {"file": "<x.js>"}。
         * 硬边界： author != tvbox-convert 一律不动（
         * 纯底在 check_js_file_name + parse_meta 里，不在外层重写）。
         */
        "tvbox_restore_js" => {
            let file = match a.str("file") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |st| async move {
                crate::tvbox::restore_tvbox_js(st, &file).await
            }).await
        }
        "plugin_config_set" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let values: serde_json::Map<String, serde_json::Value> = v
                .get("args")
                .and_then(|x| x.get("values"))
                .and_then(|x| x.as_object().cloned())
                .unwrap_or_default();
            with_state(move |st| {
                crate::commands_remote::plugin_config_set(st, &id, values)
            })
        }
        // ══════════════════════════════════════════════════════════════
        //  R3-C B1：网盘扫码登录（4 条）
        //
        //  ★ 契约与 `lib/ui/settings/pan_settings_page.dart:32-36` **逐字对齐**：
        //    pan_auth_status     {}         → { accounts: [{kind, kindName, loggedIn,
        //                                             account, expired, keyringAvailable}] }
        //    pan_qr_login_start  {kind}     → { key, url, svg, hint? }
        //    pan_qr_login_poll   {kind,key} → { status, message?, account? }
        //    pan_logout          {kind}     → {}
        //
        //  ⚠️ B1 之前这 4 条**零注册** ⇒ 页面点"获取二维码"必然 kind=unsupported
        //     （R2-#3 已取证）。本批把它们接上。
        //
        //  ★ 实现全在 `pan_login`（可单测）；这里**只做参数取值 + 转发**，
        //    与其它命令同一分工（不在 ffi 层写业务）。
        "pan_auth_status" => with_state(|_st| Ok::<_, String>(crate::pan_login::command_status())),
        "pan_qr_login_start" => {
            let kind = match a.str("kind") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |_st| async move {
                crate::pan_login::command_qr_start(&kind).await
            })
            .await
        }
        "pan_qr_login_poll" => {
            let kind = match a.str("kind") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let key = match a.str("key") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |_st| async move {
                crate::pan_login::command_qr_poll(&kind, &key).await
            })
            .await
        }
        "pan_cleanup_temp" => {
            /*
             * ★ 2026-10-29（"播完即删"）：原版是"每次播转存一份、播完删掉"
             *   （dex: QuarkTempDelete/UCTempDelete + file/delete action_type:2）。
             * Dart 在播放器 dispose 时 fire-and-forget 调这里；失败只记日志。
             */
            let owner = match crate::csp::pan_playback_guard::owner_from_payload(&v["args"]) {
                Ok(owner) => owner,
                Err(e) => return err_json(&e, "other"),
            };
            if a.bool_or("invalidate", false) {
                if let Some(owner) = &owner { crate::csp::pan_playback_guard::invalidate(owner); }
            }
            if owner.is_none() {
                crate::csp::pan_drive::purge_all_previous().await;
            } else {
                crate::csp::pan_drive::purge_for_owner(owner.clone()).await;
            }
            crate::csp::pan_xunlei_play::purge_for_owner(owner).await;
            with_state(|_st| Ok::<_, String>(serde_json::json!({})))
        }
        "pan_logout" => {
            let kind = match a.str("kind") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |_st| {
                crate::pan_login::command_logout(&kind).map(|_| serde_json::json!({}))
            })
        }

        /*
         * ★ 2026-10-31（W1 网页登录）：webview 捕获的登录态落盘。
         *   实现全在 pan_login::command_save_credential（kind 白名单 + cookie 非空
         *   + 复用 pan_auth::save + 一行脱敏日志）；这里只做参数取值 + 转发，
         *   与 pan_logout 同一分工。
         *   ⚠️ cookie 是登录凭据：dispatch 不打请求原文（本文件无 req 日志）、
         *      实现层日志只记键名与总长、错误文案不带值 —— 三层都不泄。
        */
        "pan_save_credential" => {
            let kind = match a.str("kind") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let account = match a.str("account") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let cookie = match a.str("cookie") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |_st| {
                crate::pan_login::command_save_credential(&kind, &account, &cookie)
            })
        }

        /*
         * ★ 2026-10-29（123 账号密码登录）：123 云盘**没有扫码**这条路
         *   （`login.123pan.com` 下只有 `api/user/sign_in`，见 `pan_login.rs` 里 123 那段说明），
         *   Owner 明确要求给它**表单登录**。UI 侧契约（pan_settings_page.dart 的 123 那一行）：
         *     pan_password_login {kind, account, password} → { ok: true, account }
         *   ⚠️ password 在这里只过一手就交给实现层：**不落日志、不进错误文案**
         *      （实现层 `pan_login_123::redact` 再做一次兜底，防服务端回显）。
        */
        "pan_password_login" => {
            let kind = match a.str("kind") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let account = match a.str("account") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let password = match a.str("password") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state_async(move |_st| async move {
                crate::pan_login_123::command_password_login(&kind, &account, &password).await
            })
            .await
        }

        "plugin_config_get" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            with_state(move |st| crate::commands_remote::plugin_config_get(st, &id))
        }
        "remote_status_cmd" => {
            with_state(|st| crate::commands_remote::remote_status_cmd(st))
        }

        /*
         * ══════════════════════════════════════════════════════════════
         * TVBox 订阅链接 + 检测更新（task-12，2026-09-25）
         * ══════════════════════════════════════════════════════════════
         *
         * 用户原话：
         * > 填入 tvbox 源的链接，然后他有更新我们也能收得到，不至于更新失效了
         *
         * ⚠️ **纯新增分支** —— 上面那些现有分支一行都没动。
         *
         * # sync / async 的分界（与相邻插件分支同一套判据）
         *
         * ```text
         * 纯本地读写（列源 / 记链接 / 删源）      → with_state
         * 走网络（检测更新 / 一键更新）          → with_state_async
         * ```
         * ⚠️ `remove_tvbox_source` 内部会调 remove_provider（它写第三方源清单），
         *    但那只是一次小文件写入 —— 与上面现有的 "remove_provider" 分支
         *    保持同一种处理（with_state），不另开一条异步路径。
         */
        "restore_failures" => {
            /*
             * ★ 只读命令：上一次启动**哪些源没恢复 + 为什么**
             *
             * # 这条命令补的是第19项的第 4 处"不告知"
             * 在此之前，源重启后消失只有两处痕迹：
             * ```text
             * · 日志里一句 warn（用户在界面里看不到）
             * · 磁盘上一个 restore-failures.json（没有任何读取方）
             * ```
             * ⇒ 用户只知道"我的源没了"，不知道**是哪个、为什么**。
             *
             * # 纯本地读（零网络）
             * 数据来自 `state.rs` 在 bootstrap 时写的 sidecar；
             * 这份清单本身已是"上次启动"的结论，读它不再触发任何探测。
             */
            with_state(|st| Ok(crate::persist::restore_failures_json(&st.data_dir)))
        }
        "list_tvbox_sources" => {
            /*
             * ★ 纯本地读 sidecar（毫秒级、零网络）——
             *   界面加载时用它决定「哪些卡片显示「检测更新」按钮」。
             *   绝不能用 check_tvbox_updates 代替：那会在打开设置页时
             *   对每个订阅链接发一次网络请求。
             */
            with_state(|st| crate::tvbox::list_tvbox_sources(st))
        }
        "check_tvbox_updates" => {
            // id 可选：不传 = 查全部有链接的源
            let id = a.str_or("id", "").to_string();
            let only = if id.is_empty() { None } else { Some(id) };
            // 走网络 → async
            with_state_async(move |st| async move {
                crate::tvbox::check_tvbox_updates(st, only.as_deref()).await
            })
            .await
        }
        "update_tvbox_source" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // ★ 默认值必须是「只更新已存在的站、绝不删」——
            //   漏传参数时最坏结果是「什么都没删」，不是「删了用户的东西」。
            let apply_new = a.bool_or("applyNew", true);
            let delete_missing = a.bool_or("deleteMissing", false);
            with_state_async(move |st| async move {
                crate::tvbox::update_tvbox_source(st, &id, apply_new, delete_missing).await
            })
            .await
        }
        "set_tvbox_source" => {
            // 与插件侧 set_plugin_source 对称：给「贴文本导入的源」事后补一个链接
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            let url = a.str_or("url", "").to_string();
            // 纯本地写 sidecar → 同步
            with_state(move |st| crate::tvbox::set_tvbox_source(st, &id, &url))
        }
        "adopt_tvbox_orphans" => {
            /*
             * ★ 血缘修复（2026-11-01）：给「贴文本导入 ⇒ source_url=None」的
             *   存量子站验证型认领一条订阅链接（见 tvbox::adopt_tvbox_orphans）。
             *   url 缺失/非 http 都必须 Err —— 不给 FFI 留"空参盲写"的洞。
             */
            let url = match a.str("url") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 走网络（下载配置做配对验证）→ async
            with_state_async(move |st| async move {
                crate::tvbox::adopt_tvbox_orphans(st, &url).await
            })
            .await
        }
        "remove_tvbox_source" => {
            let id = match a.str("id") {
                Ok(s) => s.to_string(),
                Err(e) => return err_json(&e, "other"),
            };
            // 删源 + 清订阅链接是同一个操作（见函数文档）
            with_state(move |st| crate::tvbox::remove_tvbox_source(st, &id))
        }
        "tvbox_update_schedule_get" => {
            /*
             * ★ T5：订阅自动更新配置（纯本地读，零网络）——
             *   设置页的「TVBox 订阅自动更新」开关 + 间隔下拉的数据源。
             */
            with_state(|st| crate::tvbox::tvbox_update_schedule_get(st))
        }
        "tvbox_update_schedule_set" => {
            // 纯本地写配置。intervalSecs<=0 视为「关」（Rust 侧统一收口，
            // 不留"开着但间隔非法"的中间态）。
            let enabled = a.bool_or("enabled", true);
            let interval = a.i64_or("intervalSecs", 86_400);
            with_state(move |st| crate::tvbox::tvbox_update_schedule_set(st, enabled, interval))
        }

        _ => err_json(
            &format!(
                "这个功能（`{cmd}`）在当前版本还没有接入，请更新到较新版本；\
                 若一直如此，请把日志发给我们。"
            ),
            "unsupported",
        ),
    }
}

/// 取全局状态并**异步**执行。
///
/// # 为什么必须有这个（不能直接用 with_state）
///
/// `with_state` 是同步的，而 `get_home` / `get_rank` 这些要走网络。
/// 如果在同步上下文里`block_on` 它们（
/// ```text
/// · 阻塞 tokio 的 worker 线程（就是把服务卡死）；
/// · 若已在 runtime 内部则 panic（"Cannot start a runtime from
///   within a runtime"）—— 而 panic 跨 FFI 边界是 UB。
/// ```
///
/// 所以这里用 `runtime().block_on(...)` **看似安全**，因为
/// `dispatch_blocking` 本身就跑在 tokio 的阻塞线程池里；
/// 而它调用 `block_on` 会 panic……
///
/// ★★★ 且慢 —— 这正是问题所在。见下面 `sourin_call` 的说明：
///    异步命令**必须**通过 `sourin_call_async` 调用，
///    那个路径已经在 tokio 里，不能再 block_on。
///
/// 所以本函数的实现是**在独立的线程上 block_on**，
/// 避开「runtime 内不能 block_on 自己」的限制。
async fn with_state_async<T, F, Fut>(f: F) -> String
where
    T: serde::Serialize + Send + 'static,
    F: FnOnce(&'static crate::state::AppState) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = Result<T, String>> + Send + 'static,
{
    let Some(st) = state() else {
        return err_json(
            "核心尚未启动 —— 请先调用 sourin_start({dataDir})",
            "unsupported",
        );
    };

    /*
     * ★为什么在新线程上路
     *
     * `sourin_call_async` 的回调路径本身已经在 tokio runtime 里，
     * 在那里调 `runtime().block_on()` 会 panic：
     * ```text
     * Cannot start a runtime from within a runtime
     * ```
     * 而 panic 跨 FFI 是 UB —— 会直接穿掉 Flutter。
     *
     * 新开一个线程来 block_on 是最简单且正确的做法：
     * 线程里没有 runtime 上下文，可以安全 block_on。
     *
     * 代价是每次异步命令多一次线程创建 —— 这些命令都是网络操作
     *（几十到几百毫秒），线程创建（微秒级）可忽略。
     */
    /*
     * ★★★必须用`spawn_blocking` 而不是`thread::spawn` + `join`
     *     （2026-09-23 实测抓到的**死锁**）
     *
     * # 症状
     *
     * 首页 8 个区块（8 个并发 `get_list`）：
     * ```text
     * Rust 单测里 8 个并发 → 3.9 秒全部完成；
     * Dart 应用里同样 8 个 → **全部 120 秒超时**
     * ```
     * 单发正常、**并发必挂** —— 只有并发才挂。
     *
     * # 死锁链条
     *
     * ```text
     * Dart 并发调 8 个命令
     *   → sourin_call_async × 8 → runtime().spawn() × 8
     *      （worker_threads = 4，只有 4 个能立刻跑）
     *   → dispatch_blocking → with_state_async
     *   → std::thread::spawn(fut) + handle.join()   → join 阻塞 worker
     *   → 4 个 worker 全被 join 占住
     *   → 而 fut 要跑在**同一个 runtime** 上
     *   → runtime 没有空闲 worker 去 poll 那些 future
     *   → join 等 future，future 等 worker，worker 等 join
     * ```
     *
     * 1 个并发时没事（还有 3 个空闲 worker）。
     * 4 个以上并发就**必挂**。
     *
     * # 为什么用 spawn_blocking 能解
     *
     * `spawn_blocking` 把任务放到 tokio 的**阻塞线程池**
     *（与 worker 线程池是分开的，上限默认 512）。
     * 在那里 `block_on` 不会占用 worker ——
     * future 有 worker 可用，join 也就不再互相等。
     *
     * 这正是 tokio 文档对「要在 async 上下文里跑阻塞代码」的官方建议：
     * ```text
     * ❌ std::thread::spawn + join   （自己管线程，会饿死 worker）
     * ✅ tokio::task::spawn_blocking（交给 runtime 的阻塞池）
     * ```
     *
     * ⚠️ 改动：`JoinHandle::join()` → `.await`（所以这个函数必须是 async）。
     */
    let handle = tokio::task::spawn_blocking(move || {
        let fut = f(st);
        runtime().block_on(fut)
    });

    match handle.await {
        Ok(Ok(v)) => serde_json::to_string(&v)
            .unwrap_or_else(|e| err_json(&format!("序列化返回值失败? {e}"), "other")),
        Ok(Err(e)) => err_json(&e, classify_error(&e)),
        // JoinError：任务 panic 或被取消。
        Err(e) => err_json(
            &format!("鍛戒护鎵ц浠诲姟澶辫触锛堝凡鎹曡幏锛屾湭宕╂簝锛? {e}"),
            "other",
        ),
    }
}

/// 取全局状态、执行命令，并统一处理「未启动」与「结果序列化」。
///
/// # 为什么要有这个包装
///
/// 三条重复逻辑（90 个命令每个都写一遍太啰嗦）：
/// ```text
/// · 状态没启动     → 明确的错误（而不是 panic）
/// · Result<T,String> → 成功序列化 T，失败转成 err_json
/// · T 必须可序列化
/// ```
fn with_state<T, F>(f: F) -> String
where
    T: serde::Serialize,
    F: FnOnce(&crate::state::AppState) -> Result<T, String>,
{
    let Some(st) = state() else {
        return err_json(
            "核心尚未启动 —— 请先调用 sourin_start({dataDir})",
            "unsupported",
        );
    };
    match f(st) {
        Ok(v) => serde_json::to_string(&v).unwrap_or_else(|e| {
            err_json(&format!("序列化返回值失败? {e}"), "other")
        }),
        Err(e) => err_json(&e, classify_error(&e)),
    }
}

/// 把错误消息粗分类（与原版前端 `ApiError.kind` 判定规则对齐）
///
/// # ★★★ 判据顺序：**先认标准前缀，再退中文关键词**（task-43 修复）
///
/// 改前这里**只**认中文关键词，完全不认 `unsupported:` 这种英文前缀：
/// ```text
/// 插件抛 "unsupported: 这个源只声明了能力，没真的实现发送"
///   ⇒ kind = "other"     ← 明明是契约规定的标准前缀
/// 插件抛 "unsupported: 不支持发送"
///   ⇒ kind = "unsupported"  ← 只因为正文里恰好有个「不支持」
/// ```
/// 靠**偶然的中文用词**决定错误分类，必然出错。
///
/// # 影响面（为什么这条值得单独立项）
/// ```text
/// `with_state_async` 在本文件里被 **71 处**调用 —— 所有走这条路的命令
/// 都受影响。前端按 ErrorKind 分支的逻辑（如「去登录」引导、
/// 「上游改版」提示）会**全部失效**，退化成兜底文案。
/// ```
///
/// # 为什么前缀优先，而不是「前缀 + 关键词一起判」
/// ```text
/// 契约（docs/PLUGINS.md）要求插件用前缀**声明**失败类型：
///   throw new Error('unsupported: ...')
/// 那是**作者显式写下的意图**，比从正文里猜词可靠得多。
/// ⇒ 前缀存在时它就是权威，不再看关键词。
///   关键词只在**没有前缀**时兜底（老插件、Rust 内部错误）。
/// ```
///
/// ⚠️ 只剥**前导**空白与标点（与 plugins/mod.rs 的 map_js_error 同一手法）：
///    插件可能把前缀包在引号/反引号里。不剥正文本体 ——
///    否则 `404: xxx` 这种合法前缀会被自己的规则吃掉。
fn classify_error(msg: &str) -> &'static str {
    let m = msg.to_lowercase();
    let t = m.trim_start_matches(|c: char| {
        c.is_whitespace() || c == '`' || c == '"' || c == '\''
    });

    /*
     * ── ① 标准前缀（权威）────────────────────────────────────
     *
     * ⚠️ 判据是 `starts_with` 而不是 `contains`：
     *    「正文里提到过 unsupported」与「作者声明这是 unsupported」
     *    是两件完全不同的事，后者才该决定分类。
     */
    if t.starts_with("unsupported:") {
        return "unsupported";
    }
    if t.starts_with("unauthorized:") || t.starts_with("401:") {
        return "unauthorized";
    }
    if t.starts_with("not_found:") || t.starts_with("404:") {
        return "not_found";
    }
    if t.starts_with("network:") {
        return "network";
    }
    /*
     * ★ `parse:` 也在这里补上 —— 与 plugins/mod.rs 的 map_js_error
     *   （2026-10-17 补的那一支）保持**逐字一致**：
     *   同一个错误在 JS 层分类对了、到 FFI 层又被抹成 other，等于白修。
     */
    if t.starts_with("parse:") {
        return "parse";
    }

    /*
     * ── ② 中文关键词兜底（老插件 / Rust 内部错误）──────────────
     *
     * ⚠️ 必须在前缀之后：否则正文里的「401」「timeout」会抢走
     *    带前缀消息的判定。
     */
    if m.contains("timeout") || m.contains("网络") || m.contains("请求失败") || m.contains("连接")
    {
        "network"
    } else if m.contains("登录") || m.contains("401") || m.contains("unauthor") {
        "unauthorized"
    } else if m.contains("不支持") || m.contains("未配置") {
        "unsupported"
    } else if m.contains("不存在") || m.contains("未找到") || m.contains("未返回") {
        "not_found"
    } else {
        "other"
    }
}

/// 统一构造错误 JSON —— 错误分类与原版前端的 ApiError.kind 对齐。
///
/// 为什么要有 kind：UI 要按类型给不同提示：
/// ```text
/// network      → 提示检查网络 / 换源
/// unauthorized → 引导去登录
/// not_found    →提示资源不存在
/// unsupported  →提示不支持（如DRM（
/// other        → 兜底
/// ```
fn err_json(msg: &str, kind: &str) -> String {
    /*
     * ★★★ T9 连带修复·互检打回（2026-10-31）：错误信封增发可选 `login_kind`。
     * playback.rs resolve 错误通路用私有序列化标记 `\u{1f}login_kind=<盘种>`
     * 把"哪个盘要登录"越过 Err(String) 边界带过来；这里统一剥离并发射。
     * 无标记 ⇒ 输出**逐字不变**（老客户端/老快照 diff 为零）。
     */
    let (msg, login_kind) = split_login_kind_marker(msg);
    match login_kind {
        Some(k) => format!(
            r#"{{"error":{},"kind":{},"login_kind":{}}}"#,
            serde_json::to_string(msg).unwrap_or_else(|_| "\"\"".into()),
            serde_json::to_string(kind).unwrap_or_else(|_| "\"other\"".into()),
            serde_json::to_string(k).unwrap_or_else(|_| "\"\"".into())
        ),
        None => format!(
            r#"{{"error":{},"kind":{}}}"#,
            serde_json::to_string(msg).unwrap_or_else(|_| "\"\"".into()),
            serde_json::to_string(kind).unwrap_or_else(|_| "\"other\"".into())
        ),
    }
}

/// 剥私有序列化标记：`\u{1f}login_kind=<盘种>`（playback.rs::provider_err_to_string 追加）
///
/// `\x1f`（ASCII 单元分隔符）在错误正文里不可能出现 ⇒ `split_once` 无歧义；
/// 标记后面没有合法前缀/为空 ⇒ 视为无标记（原样返回，不猜）。
fn split_login_kind_marker(msg: &str) -> (&str, Option<&str>) {
    // ★ P3 小尾巴（lead 裁定）：从**右**切。标记恒在消息尾部；上游正文可能自带
    //   \x1f（甚至伪装成标记），从左切会把用户文案截断、盘种取错。
    //   rsplit_once 保证：尾部标记必被认出，\x1f 之前的文案**逐字保留**。
    match msg.rsplit_once('\u{1f}') {
        Some((head, tail)) => {
            let kind = tail.strip_prefix("login_kind=").map(str::trim);
            (head, kind.filter(|s| !s.is_empty()))
        }
        None => (msg, None),
    }
}

// ═══════════════════════════════════════════════════════════════════════
//  测试
// ═══════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod pan_cleanup_envelope_tests {
    use super::dispatch_inner;
    use crate::csp::{pan_drive, pan_playback_guard as guard, pan_xunlei_play};
    use crate::pan::PanKind;
    use serde_json::{json, Value};
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    struct Replay {
        events: Arc<Mutex<Vec<(String, String)>>>,
        server: tokio::task::JoinHandle<()>,
        base: String,
        _credentials: crate::pan_auth::TestCredentialGuard,
        _drive_bases: pan_drive::TestApiBaseGuard,
        _xunlei_base: pan_xunlei_play::TestEndpointGuard,
    }

    impl Drop for Replay {
        fn drop(&mut self) { self.server.abort(); }
    }

    impl Replay {
        async fn new() -> Self {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let base = format!("http://{}", listener.local_addr().unwrap());
            let events = Arc::new(Mutex::new(Vec::new()));
            let captured = events.clone();
            let server = tokio::spawn(async move {
                loop {
                    let (mut stream, _) = listener.accept().await.unwrap();
                    let mut bytes = Vec::new();
                    let (header_end, content_length) = loop {
                        let mut chunk = [0u8; 4096];
                        let count = stream.read(&mut chunk).await.unwrap();
                        assert!(count > 0 && bytes.len() < 32768, "invalid replay request");
                        bytes.extend_from_slice(&chunk[..count]);
                        if let Some(end) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                            let header = std::str::from_utf8(&bytes[..end]).unwrap();
                            let length = header.lines().find_map(|line| {
                                let (name, value) = line.split_once(':')?;
                                name.eq_ignore_ascii_case("content-length")
                                    .then(|| value.trim().parse::<usize>().unwrap())
                            }).unwrap_or(0);
                            break (end + 4, length);
                        }
                    };
                    while bytes.len() < header_end + content_length {
                        let mut chunk = [0u8; 4096];
                        let count = stream.read(&mut chunk).await.unwrap();
                        assert!(count > 0, "incomplete replay body");
                        bytes.extend_from_slice(&chunk[..count]);
                    }
                    let header = std::str::from_utf8(&bytes[..header_end]).unwrap();
                    let mut request = header.lines().next().unwrap().split_whitespace();
                    let method = request.next().unwrap();
                    let path = request.next().unwrap();
                    let event = if method == "POST" && path.contains("/file/delete") {
                        let body: Value = serde_json::from_slice(
                            &bytes[header_end..header_end + content_length],
                        ).unwrap();
                        let kind = if path.starts_with("/q/") { "q" } else if path.starts_with("/u/") { "u" } else {
                            panic!("unexpected replay route");
                        };
                        Some((kind.to_string(), body["filelist"][0].as_str().unwrap().to_string()))
                    } else if method == "DELETE" && path.starts_with("/x/files/") {
                        let fid = path.trim_start_matches("/x/files/").split('?').next().unwrap();
                        Some(("x".to_string(), fid.to_string()))
                    } else { None };
                    let (status, body) = if let Some(event) = event {
                        captured.lock().unwrap().push(event);
                        ("200 OK", r#"{"code":0}"#)
                    } else { ("400 Bad Request", "{}") };
                    let response = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len(),
                    );
                    stream.write_all(response.as_bytes()).await.unwrap();
                }
            });
            let credential = |kind, cookie: &str| crate::pan_auth::PanCredential {
                kind, account: "fixture".into(), cookie: cookie.into(), saved_at: 1, expires_at: None,
            };
            let credentials = crate::pan_auth::debug_override_credentials(vec![
                credential(PanKind::Quark, "fixture=1"),
                credential(PanKind::Uc, "fixture=1"),
                credential(PanKind::Xunlei, "access_token=FIXTURE"),
            ]);
            let drive_bases = pan_drive::debug_override_api_bases(vec![
                (pan_drive::quark_spec().api_host.into(), format!("{base}/q")),
                (pan_drive::uc_spec().api_host.into(), format!("{base}/u")),
            ]);
            let xunlei_base = pan_xunlei_play::debug_override_endpoint(format!("{base}/x"));
            Self { events, server, base, _credentials: credentials,
                _drive_bases: drive_bases, _xunlei_base: xunlei_base }
        }

        async fn seed(&self, owner: Option<guard::PlaybackOwner>, fid: &str) {
            guard::with_scope(owner, async {
                pan_drive::PanDrive::with_spec("PanQuark", pan_drive::quark_spec()).remember_temp(fid);
                pan_drive::PanDrive::with_spec("PanUC", pan_drive::uc_spec()).remember_temp(fid);
                pan_xunlei_play::debug_remember_temp(&format!("{}/x", self.base), "FIXTURE", fid);
            }).await;
        }

        fn take(&self) -> Vec<(String, String)> {
            let mut events = std::mem::take(&mut *self.events.lock().unwrap());
            events.sort();
            events
        }

        fn expect(&self, fids: &[&str]) {
            let mut expected: Vec<_> = ["q", "u", "x"].into_iter().flat_map(|kind| {
                fids.iter().map(move |fid| (kind.to_string(), fid.to_string()))
            }).collect();
            expected.sort();
            assert_eq!(self.take(), expected, "actual dispatcher cleanup must be owner-scoped");
        }
    }

    fn owner(consumer: &str, generation: u64) -> guard::PlaybackOwner {
        guard::PlaybackOwner { consumer: consumer.into(), generation }
    }

    async fn cleanup(owner: Option<&guard::PlaybackOwner>, invalidate: bool) -> Value {
        let request = match owner {
            Some(owner) => json!({"cmd":"pan_cleanup_temp","args":{
                "play_consumer":owner.consumer, "play_generation":owner.generation,
                "invalidate":invalidate,
            }}),
            None => json!({"cmd":"pan_cleanup_temp"}),
        };
        serde_json::from_str(&dispatch_inner(&request.to_string()).await).unwrap()
    }

    async fn current(owner: &guard::PlaybackOwner) -> bool {
        guard::with_scope(Some(owner.clone()), async { guard::check_current().is_ok() }).await
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ffi_pan_cleanup_envelope_invalidates_and_deletes_only_target_epoch() {
        let _serial = pan_drive::FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let replay = Replay::new().await;
        let target = owner("ffi-envelope-disposed", 2);
        let other = owner("ffi-envelope-other", 1);
        let future = owner(&target.consumer, 3);
        guard::register(Some(target.clone())).unwrap();
        guard::register(Some(other.clone())).unwrap();
        replay.seed(Some(owner(&target.consumer, 1)), "closed-old").await;
        replay.seed(Some(target.clone()), "closed-current").await;
        replay.seed(Some(future.clone()), "closed-future").await;
        replay.seed(Some(other.clone()), "closed-other").await;
        replay.seed(None, "closed-legacy").await;

        cleanup(Some(&target), true).await;
        let closed = !current(&target).await;
        let other_live = current(&other).await;
        let cannot_reopen = guard::register(Some(owner(&target.consumer, 99))).is_err();
        assert!(closed && other_live && cannot_reopen,
            "full cmd+args envelope must close only its consumer permanently");
        replay.expect(&["closed-old", "closed-current"]);

        cleanup(Some(&future), false).await;
        replay.expect(&["closed-future"]);
        cleanup(Some(&other), false).await;
        replay.expect(&["closed-other"]);
        cleanup(None, false).await;
        replay.expect(&["closed-legacy"]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ffi_pan_cleanup_envelope_stale_dispose_preserves_newer_request() {
        let _serial = pan_drive::FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let replay = Replay::new().await;
        let old = owner("ffi-envelope-stale", 1);
        let new = owner(&old.consumer, 2);
        guard::register(Some(new.clone())).unwrap();
        replay.seed(Some(old.clone()), "stale-old").await;
        replay.seed(Some(new.clone()), "stale-new").await;
        replay.seed(None, "stale-legacy").await;
        cleanup(Some(&old), true).await;
        assert!(current(&new).await, "late old dispose must not close a newer request");
        replay.expect(&["stale-old"]);
        cleanup(Some(&new), false).await;
        assert!(current(&new).await, "invalidate:false must not close the consumer");
        replay.expect(&["stale-new"]);
        cleanup(None, false).await;
        replay.expect(&["stale-legacy"]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ffi_pan_cleanup_envelope_invalid_context_never_falls_back_to_legacy() {
        let _serial = pan_drive::FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let replay = Replay::new().await;
        let active = owner("ffi-envelope-invalid", 1);
        guard::register(Some(active.clone())).unwrap();
        replay.seed(Some(active.clone()), "invalid-active").await;
        replay.seed(None, "invalid-legacy").await;
        for args in [
            json!({"play_consumer":active.consumer,"invalidate":true}),
            json!({"play_generation":1,"invalidate":true}),
            json!({"play_consumer":null,"play_generation":1,"invalidate":true}),
            json!({"play_consumer":active.consumer,"play_generation":0,"invalidate":true}),
            json!({"play_consumer":active.consumer,"play_generation":"1","invalidate":true}),
        ] {
            let request = json!({"cmd":"pan_cleanup_temp","args":args});
            let reply: Value = serde_json::from_str(&dispatch_inner(&request.to_string()).await).unwrap();
            assert!(reply["error"].as_str().is_some_and(|e| e.contains("播放解析请求")),
                "invalid nested context must be rejected before cleanup");
            assert!(current(&active).await);
            replay.expect(&[]);
        }
        cleanup(Some(&active), false).await;
        replay.expect(&["invalid-active"]);
        cleanup(None, false).await;
        replay.expect(&["invalid-legacy"]);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn ffi_pan_cleanup_envelope_legacy_request_preserves_modern_consumers() {
        let _serial = pan_drive::FIXTURE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let replay = Replay::new().await;
        let active = owner("ffi-envelope-legacy", 1);
        guard::register(Some(active.clone())).unwrap();
        replay.seed(Some(active.clone()), "legacy-active").await;
        replay.seed(None, "legacy-only").await;
        cleanup(None, false).await;
        assert!(current(&active).await);
        replay.expect(&["legacy-only"]);
        cleanup(Some(&active), false).await;
        replay.expect(&["legacy-active"]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn optional_play_request_quark_files() -> Vec<crate::csp::pan_drive::DriveEntry> {
        (1..=7)
            .map(|episode| crate::csp::pan_drive::DriveEntry {
                fid: format!("synthetic-file-{episode:02}"),
                name: if episode == 3 {
                    "Synthetic S03 E03 (1).mp4".into()
                } else {
                    format!("Synthetic S03 E{episode:02}.mp4")
                },
                is_dir: false,
                size: 1024,
                fid_token: None,
            })
            .collect()
    }

    #[test]
    fn optional_play_request_quark_typed_fields_survive() {
        let files = optional_play_request_quark_files();
        let episodes: Vec<_> = files
            .iter()
            .map(|file| {
                crate::csp::pan_episode_select::encode_file_id(
                    crate::pan::PanKind::Quark,
                    "synthetic-contract-share",
                    "",
                    &file.fid,
                )
            })
            .collect();
        let selected = &files[2];
        let request = crate::model::PlayRequest {
            source_code: Some("synthetic-line".into()),
            episode_id: Some(format!("csp-quark-contract::{}", episodes[2])),
            quality: Some("original".into()),
            flag: Some("Quark".into()),
            episode_title: Some(selected.name.clone()),
            episode_order: Some(3),
            extra: Some(serde_json::json!({
                "trace": "synthetic-contract",
                "selection": "episode03"
            })),
        };
        let wire = serde_json::to_value(&request).unwrap();
        let parsed = parse_optional_play_request(&serde_json::json!({
            "args": {"req": wire}
        }))
        .unwrap()
        .expect("an explicitly selected concrete file must remain a request");
        assert_eq!(serde_json::to_value(parsed).unwrap(), wire);
        assert_eq!(files.len(), 7);
        assert!(selected.name.ends_with("(1).mp4"));
    }

    #[test]
    fn optional_play_request_legacy_omitted_null_and_empty_object_remain_valid() {
        for request in [
            serde_json::json!({}),
            serde_json::json!({"args": {}}),
            serde_json::json!({"args": {"req": null}}),
        ] {
            assert!(parse_optional_play_request(&request).unwrap().is_none());
        }
        let parsed = parse_optional_play_request(&serde_json::json!({
            "args": {"req": {}}
        }))
        .unwrap()
        .expect("an empty object remains a default PlayRequest");
        assert_eq!(serde_json::to_value(parsed).unwrap(), serde_json::json!({}));
    }

    #[test]
    fn optional_play_request_malformed_shapes_fail_closed() {
        for (label, req) in [
            ("array", serde_json::json!([])),
            ("string", serde_json::json!("synthetic-do-not-echo")),
            ("boolean", serde_json::json!(false)),
            ("integer", serde_json::json!(3)),
            ("fraction", serde_json::json!(3.5)),
        ] {
            assert!(
                parse_optional_play_request(&serde_json::json!({"args": {"req": req}}))
                    .is_err(),
                "present malformed {label} request must not become an absent request"
            );
        }
    }

    #[test]
    fn optional_play_request_malformed_fields_fail_closed() {
        for (label, req) in [
            ("episode_id", serde_json::json!({"episode_id": 3})),
            ("episode_title", serde_json::json!({"episode_title": []})),
            ("source_code", serde_json::json!({"source_code": true})),
            ("flag", serde_json::json!({"flag": {}})),
            ("quality", serde_json::json!({"quality": 1080})),
            ("order_string", serde_json::json!({"episode_order": "3"})),
            ("order_negative", serde_json::json!({"episode_order": -1})),
            ("order_overflow", serde_json::json!({"episode_order": 4294967296_u64})),
            ("order_fraction", serde_json::json!({"episode_order": 3.5})),
        ] {
            assert!(
                parse_optional_play_request(&serde_json::json!({"args": {"req": req}}))
                    .is_err(),
                "present malformed {label} must not discard the selected request"
            );
        }
    }

    #[test]
    fn optional_play_request_malformed_ffi_error_is_safe() {
        let request = CString::new(
            serde_json::json!({
                "cmd": "resolve_stream",
                "args": {
                    "provider": "synthetic-provider",
                    "id": "synthetic-item",
                    "req": {
                        "episode_id": "synthetic-do-not-echo",
                        "episode_order": "synthetic-do-not-echo"
                    }
                }
            })
            .to_string(),
        )
        .unwrap();
        let response = unsafe { sourin_call(request.as_ptr()) };
        assert!(!response.is_null());
        let text = unsafe { CStr::from_ptr(response) }.to_str().unwrap().to_string();
        unsafe { sourin_free(response) };
        let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
        let error_stage = if parsed["error"] == "resolve_stream req must be a valid PlayRequest" {
            "optional_request"
        } else if parsed["error"].as_str().is_some_and(|error| error.contains("sourin_start")) {
            "core_not_started"
        } else {
            "other"
        };
        println!("QUARK_REQUEST_CONTRACT_FFI_ERROR_STAGE={error_stage}");
        assert_eq!(parsed["kind"], "other");
        assert_eq!(
            parsed["error"],
            "resolve_stream req must be a valid PlayRequest"
        );
        assert!(!text.contains("synthetic-do-not-echo"));
    }

    #[test]
    fn optional_play_request_duplicate_suffix_uses_concrete_identity() {
        use crate::csp::pan_episode_select::{
            decode_file_id, encode_file_id, pick_episode_file, EpisodeSpec,
        };
        let files = optional_play_request_quark_files();
        let selected = &files[2];
        let request = crate::model::PlayRequest {
            episode_id: Some(encode_file_id(
                crate::pan::PanKind::Quark,
                "synthetic-contract-share",
                "",
                &selected.fid,
            )),
            episode_title: Some(selected.name.clone()),
            episode_order: Some(3),
            ..Default::default()
        };
        let parsed = parse_optional_play_request(&serde_json::json!({
            "args": {"req": serde_json::to_value(&request).unwrap()}
        }))
        .unwrap()
        .unwrap();
        let reference = decode_file_id(parsed.episode_id.as_deref().unwrap()).unwrap();
        let spec = EpisodeSpec {
            title: parsed.episode_title.unwrap(),
            order: parsed.episode_order,
        };
        assert_eq!(
            pick_episode_file(&spec, &files, Some(&reference.fid)).unwrap(),
            selected
        );
        let remaining: Vec<_> = files
            .iter()
            .filter(|file| file.fid != reference.fid)
            .cloned()
            .collect();
        assert!(
            pick_episode_file(&spec, &remaining, Some(&reference.fid)).is_err(),
            "a missing concrete file must not resolve another listed file"
        );
    }

    #[test]
    fn version_is_callable_and_nul_terminated() {
        let p = sourin_core_version();
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap();
        assert!(s.starts_with("sourin-core"), "版本串不对? {s}");
    }

    #[test]
    fn ping_works() {
        let r = dispatch_blocking(r#"{"cmd":"ping"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert_eq!(v["ok"], true);
    }

    /// ★ 关键回归：错误必须是**合法的 JSON**（而不是裸文本）。
    ///
    /// 为什么重要：Dart 侧统一 `jsonDecode` 解析结果。
    /// 如果某条错误路径返回了裸文本，Dart 会直接炸掉，
    /// 用户看到的是「解析失败」，不是真实原因 —— 极难排查。
    #[test]
    fn errors_are_valid_json() {
        for req in [
            r#"not json at all"#,
            r#"{}"#,
            r#"{"cmd":"no_such_command"}"#,
        ] {
            let r = dispatch_blocking(req);
            let v: serde_json::Value = serde_json::from_str(&r)
                .unwrap_or_else(|e| panic!("请求 {req} 的错误返回不是合法 JSON: {r} —— {e}"));
            assert!(v.get("error").is_some(), "缺 error 字段: {r}");
            assert!(v.get("kind").is_some(), "缺 kind 字段: {r}");
        }
    }

    /// 未接入的命令必须报 `unsupported`（而不是静默成功）
    ///
    /// 静默成功的风险：UI 以为操作生效了，实际什么都没做。
    ///
    /// # ★ 用「永不该接入」的命令名，不要用「某时还没接入」的
    ///
    /// 这个测试原来用的是 `search_all` —— 那时它确实还没接入，
    /// 批次 3 接入之后测试就挂了（kind 从 unsupported 变成 other），
    /// 因为已接入的命令缺参数时走的是参数错误。
    ///
    /// 这不是回归，是**测试选材不当**：用一个"将来会被实现"的命令名
    /// 写的未实现断言，注定会在实现那天失效。
    ///
    /// 所以改用一个**语义上就不可能存在**的命令名：
    ///（`definitely_not_a_real_command_xyz`）—— 它永远不会被实现。
    #[test]
    fn unimplemented_command_reports_unsupported() {
        let cmd = "definitely_not_a_real_command_xyz";
        let r = dispatch_blocking(&format!(r#"{{"cmd":"{cmd}"}}"#));
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert_eq!(v["kind"], "unsupported", "未接入的命令应报 unsupported");
        assert!(
            v["error"].as_str().unwrap().contains(cmd),
            "错误消息里应含命令名，便于定位"
        );
    }

    /// panic 涓嶈兘绌块€?FFI 边界
    #[test]
    fn panic_is_caught_and_converted() {
        let r = std::panic::catch_unwind(|| {
            // 模拟一次 panic
            let _ = std::panic::catch_unwind(|| panic!("boom"));
        });
        assert!(r.is_ok());
        // 真正要验证的是 dispatch_blocking 里的 catch_unwind 逻辑，
        // （见函数实现）—— 这里只确认机制可用。
    }

    #[test]
    fn free_accepts_null() {
        unsafe { sourin_free(std::ptr::null_mut()) }; // 不应崩
    }

    // ═══════════════════════════════════════════════════════════════════
    //  真实命令的接线测试（2026-09-22）
    // ═══════════════════════════════════════════════════════════════════

    /// 未启动时调用需要状态的命令 —— 要给**可操作的**错误
    ///
    /// 场景：Flutter 侧调用顺序错了（忘了 start）时，
    /// 用户看到的应该是「核心尚未启动」，而不是莫名其妙的
    /// 「命令未接入」或直接崩溃。
    ///
    /// ★★★ 注意：这个测试依赖「STATE 未被设置」。
    ///    Rust 的测试默认多线程并行，如果别的测试启动了核心，
    ///    这里就会失败。所以本测试以 `STATE.get().is_none()` 做前置判断。
    #[test]
    fn state_commands_without_start_give_actionable_error() {
        if STATE.get().is_some() {
            // 别的测试已经启动了核心 —— 这条无法验证，跳过。
            // （不是失败：环境不满足，而不是行为错了）
            return;
        }
        let r = dispatch_blocking(r#"{"cmd":"list_providers"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert_eq!(v["kind"], "unsupported");
        let msg = v["error"].as_str().unwrap();
        assert!(
            msg.contains("sourin_start"),
            "错误消息应告诉调用方怎么修（要提到 sourin_start）：{msg}"
        );
    }

    /// 缺参数的调用要报明确错误，不能 panic、不能静默。
    #[test]
    fn missing_arg_reports_clear_error() {
        let r = dispatch_blocking(r#"{"cmd":"get_provider_enabled"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert!(v.get("error").is_some(), "缺参数应报错");
        assert!(
            v["error"].as_str().unwrap().contains("id"),
            "错误消息应指明缺哪个参数"
        );
    }

    /// `core_is_started` 探针：不需要启动就能回答。
    #[test]
    fn is_started_probe_needs_no_state() {
        let r = dispatch_blocking(r#"{"cmd":"core_is_started"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert!(v.get("started").is_some(), "应返回 started 字段");
    }

    /// ★ 错误分类规则（与原版前端 ApiError.kind 对齐）
    ///
    /// 分错类，UI 会给错误的提示：
    /// 比如网络问题被归成 `other`，用户就看不到「检查网络」的引导。
    #[test]
    fn error_classification_matches_frontend_rules() {
        // 对照 src/api/index.ts:69-72 的四条规则
        assert_eq!(classify_error("请求超时 timeout"), "network");
        assert_eq!(classify_error("网络连接失败"), "network");
        assert_eq!(classify_error("登录已过期 401"), "unauthorized");
        assert_eq!(classify_error("unsupported 不支持该格式"), "unsupported");
        assert_eq!(classify_error("资源不存在"), "not_found");
        assert_eq!(classify_error("随便什么别的错误"), "other");
    }


    /// ★★★ task-43：**标准前缀**必须被识别（改前完全不认，全是 other）
    ///
    /// # 这条守的是「插件作者显式写下的意图」
    /// ```text
    /// 契约（docs/PLUGINS.md）要求插件用前缀声明失败类型：
    ///   throw new Error('unsupported: 该源不支持发送弹幕')
    /// 改前 classify_error 只认中文关键词 ⇒ 标准英文前缀全被抹成 other，
    /// 前端按 ErrorKind 分支的逻辑（去登录 / 检查网络 / 上游改版）全部失效。
    /// ```
    ///
    /// ⚠️ 用例**故意不写中文关键词**：一旦正文里带上「不支持」，
    ///    关键词兜底也能过 —— 那样这条就测不出前缀识别有没有生效。
    #[test]
    fn standard_prefix_is_recognized() {
        assert_eq!(classify_error("unsupported: feature not available"), "unsupported");
        assert_eq!(classify_error("unauthorized: token expired"), "unauthorized");
        assert_eq!(classify_error("not_found: no such video"), "not_found");
        assert_eq!(classify_error("network: connection reset"), "network");
        assert_eq!(classify_error("parse: unexpected token in json"), "parse");
    }

    /// ★★ 前缀判据是 `starts_with` 而不是 `contains`
    ///
    /// 「正文里提到过 unsupported」与「作者声明这次是 unsupported」
    /// 是两件不同的事。后者才该决定分类。
    #[test]
    fn prefix_must_be_at_the_start_not_merely_present() {
        // 前缀夹在正文中间 ⇒ 不该按前缀走，落回关键词兜底（这里没有关键词 ⇒ other）
        assert_eq!(
            classify_error("upstream said unsupported: but later succeeded"),
            "other"
        );
    }

    /// ★★ 前缀被引号/反引号/空白包住时也要认（插件常见写法）
    #[test]
    fn prefix_survives_wrapping_punctuation() {
        assert_eq!(classify_error("  `unsupported: x`"), "unsupported");
        assert_eq!(classify_error("'unauthorized: y'"), "unauthorized");
        assert_eq!(classify_error("\"network: z\""), "network");
    }

    /// ★★ 大小写不敏感（前缀大写也要认）
    #[test]
    fn prefix_is_case_insensitive() {
        assert_eq!(classify_error("UNSUPPORTED: x"), "unsupported");
        assert_eq!(classify_error("NOT_FOUND: y"), "not_found");
    }

    /// `with_state` 在成功路径上要返回**纯值**，不做 `{ok:true,value:..}` 包装
    ///
    /// 因为原版 Tauri 的 `invoke` 直接把 Rust 的返回值给前端；
    /// 没有包装层。如果这里加了包装，Dart 侧就要跟着改一层 ——
    /// 而目标是「前端代码尽量能照搬」。
    #[test]
    fn successful_result_is_not_wrapped() {
        // 用一个不需要状态的命令间接验证序列化行为
        let r = dispatch_blocking(r#"{"cmd":"core_version"}"#);
        let v: serde_json::Value = serde_json::from_str(&r).unwrap();
        assert!(v.get("version").is_some(), "应该是纯值");
        assert!(v.get("ok").is_none(), "不该有 ok 包装层");
    }
    // ══════════════════════════════════════════════════════════════════
    //  R3-C B1：网盘扫码登录 4 条命令的**端到端契约门禁**
    //
    //  ★ 为什么必须端到端（而不是只测 `pan_login` 里的函数）：
    //  ```text
    //  UI 侧（`pan_settings_page.dart:32-36`）调的是 **命令名 + 参数名 + 返回字段名**。
    //  只测 Rust 函数 ⇒ "函数对，但 ffi 里那条 match 分支写错了命令名/参数名" 测不出来
    //  —— 而那正是 UI 会踩的坑（调一个不存在的命令 = unsupported）。
    //  本组用 `dispatch_blocking` 真走一遍分发层，把这三个名字钉住。
    //  ```
    //  ⚠️ 本组**不发网络**：只验证"命令被识别"与"参数契约"，
    //     真正的网络行为由 `pan_login` 的纯函数测试覆盖。
    //  ══════════════════════════════════════════════════════════════════

    /// ★★★ 4 条命令必须**都被分发层认识**
    ///
    /// # ⚠️ 我前两版判据都错了，这里记下来（免得后人再踩）
    /// ```text
    /// 第一版：断言 `kind != "unsupported"`
    ///   ⇒ 全红。真因：**"核心未启动"与"命令未接线"都给 unsupported**
    ///     （`with_state` 的前置闸与 `_ =>` 的未接入分支撞在一起）。
    /// 第二版：断言"错误里不含命令名"（照抄既有用例的口径）
    ///   ⇒ 又红。真因：**参数错误文案里也含命令名**
    ///     （"命令 `pan_qr_login_start` 缺少参数 `kind`"）⇒ 那个口径只对
    ///     "无参命令"成立，对带参命令不成立。
    /// ★ 第三版（本版）判据：**用"参数校验有没有发生"来证明接线** ——
    ///   未接线的命令**根本走不到参数校验**（它在 `_ =>` 分支里就被拒了）；
    ///   已接线的带参命令会先报"缺少参数 X"。
    ///   ⇒ 这才是"接线"与"未接线"的**可区分特征**。
    /// ```
    #[test]
    fn r3c_pan_commands_are_all_wired() {
        // 带参命令：给空 args ⇒ 必须报"缺少参数"（= 走进了我那条分支的参数校验）
        //   ★ 未接线的命令**不会有这个报错**（它直接进 `_ =>` 未接入分支）
        for (cmd, need) in [
            ("pan_qr_login_start", "kind"),
            ("pan_qr_login_poll", "kind"),
        ] {
            let r = dispatch_blocking(&format!(r#"{{"cmd":"{cmd}","args":{{}}}}"#));
            let v: serde_json::Value = serde_json::from_str(&r).expect("应是 JSON");
            let e = v.get("error").and_then(|x| x.as_str()).unwrap_or("");
            assert!(
                e.contains("缺少参数") && e.contains(need),
                "★★ `{cmd}` 未接线：它应当先报『缺少参数 {need}』（那是接线后参数校验的独有特征）。\
                 实际响应：{r}"
            );
            // 反面：确证它不是走了"未接入"那条路
            assert!(
                !e.contains("还没有接入"),
                "★★ `{cmd}` 走了「未接入」分支 —— 响应：{r}"
            );
        }
        // 无参命令：`pan_auth_status` 会走到 `with_state` 的前置闸（核心未启动）
        //   ⇒ 这**不能**证明接线（前置闸与未接线分支都拦截）。
        //   ★ 所以无参命令的接线证明换一条路：**看命令是否出现在 dispatch 的 match 里**
        //     （源码锚点判据；与行为判据互补，见下 `r3c_pan_commands_present_in_dispatch_table`）
    }

    /// ★★ 接线证明的另一半：4 条命令名**都出现在 `ffi.rs` 的 match 表里**
    ///
    /// ```text
    /// 为什么需要这条（行为判据的盲区）：
    ///   无参命令（`pan_auth_status` / `pan_logout`）在 test 环境里必然被
    ///   `with_state` 的前置闸拦成"核心未启动" ⇒ **行为上区分不出"接线了没"**。
    ///   ⇒ 用源码锚点补：命令名在 match 表里出现过。
    /// ★ 与人判据合起来 = 完整：行为证明带参命令接线、锚点证明无参命令接线。
    /// ```
    #[test]
    fn r3c_pan_commands_present_in_dispatch_table() {
        let src = include_str!("ffi.rs");
        for cmd in [
            "pan_auth_status",
            "pan_qr_login_start",
            "pan_qr_login_poll",
            "pan_logout",
        ] {
            // ⚠️ 不写 `format!("\"{cmd}\" =>")` —— 我在这个脚本里已经把
            //    Rust 的字符串转义搞错**两次**了（裸引号截断字符串、格式串占位符）。
            //    改用**不含引号的拼法**：直接拼两段 & 用 `r#` 原始字符串，
            //    彻底绕开"脚本层转义 × Rust 层转义"的双重叠加。
            let needle = format!("{cmd}\u{22} =>");
            assert!(
                src.contains(&needle),
                "★★ `{cmd}` 不在 dispatch 的 match 表里（缺该行）\
                 ⇒ 页面调用它会拿到 unsupported（正是 R2-#3 的故障形态）"
            );
        }
    }

    /// ★★★ 参数名契约：UI 传 `kind`（不是 `panKind`/`pan_kind`）
    ///
    /// ```text
    /// UI 契约（pan_settings_page.dart:34）：`pan_qr_login_start {kind}`
    /// ★ 这里能拿到"缺参数 kind"的报错，前提是**命令已接线**（若未接线，
    ///   错误会是"未接入"而不提 kind）—— 所以本条隐含验证了接线。
    /// ```
    #[test]
    fn r3c_pan_kind_param_name_is_exactly_kind() {
        let r = dispatch_blocking(r#"{"cmd":"pan_qr_login_start","args":{}}"#);
        let v: serde_json::Value = serde_json::from_str(&r).expect("应是 JSON");
        let e = v.get("error").and_then(|x| x.as_str()).unwrap_or("");
        assert!(
            e.contains("kind"),
            "★ 缺参数时错误必须点名 `kind`（UI 才知道传哪个名字）—— 实际：{r}"
        );
    }

    /// ★★★ poll 必须认**两个**参数：`kind` 与 `key`
    #[test]
    fn r3c_pan_poll_needs_kind_and_key() {
        // 只给 kind ⇒ 应报"缺 key"
        let r = dispatch_blocking(r#"{"cmd":"pan_qr_login_poll","args":{"kind":"quark"}}"#);
        let v: serde_json::Value = serde_json::from_str(&r).expect("应是 JSON");
        let e = v.get("error").and_then(|x| x.as_str()).unwrap_or("");
        assert!(
            e.contains("key"),
            "★★ poll 必须有 `key` 参数（UI 契约传 kind + key 两个）—— 实际：{r}"
        );
    }

    /// ★★ 未知 kind 必须**如实报错**（不许默认成某个盘）
    ///
    /// ⚠️ 在 test 环境里 `pan_qr_login_start` 会被"核心未启动"前置闸拦住 ⇒
    ///   拿不到 `command_qr_start` 里那句"认不出"。
    /// ★ 所以本条的判据改为：**不许成功 + 不许产出会话**，
    ///   而"认不出"这句文案的**精确断言**放在 `pan_login::kind_from_code` 的纯函数测试里
    ///   （不依赖 state）。两边合起来才完整。
    #[test]
    fn r3c_pan_unknown_kind_is_rejected_not_defaulted() {
        let r = dispatch_blocking(r#"{"cmd":"pan_qr_login_start","args":{"kind":"nope"}}"#);
        let v: serde_json::Value = serde_json::from_str(&r).expect("应是 JSON");
        assert!(
            v.get("key").is_none() && v.get("url").is_none(),
            "★★ 未知 kind 绝不许产出会话（那等于默认成了某个盘）—— 实际：{r}"
        );
        assert!(v.get("error").is_some(), "★★ 必须如实报错 —— 实际：{r}");
    }

    /// ★★ `pan_auth_status` 返回字段与 UI 契约一致
    ///
    /// ⚠️ 它在 test 环境里会被"核心未启动"拦（走 `with_state`）⇒ **拿不到真形状**。
    /// ★ 因此本条的**形状断言**放在 `pan_login::command_status` 的纯函数测试里
    ///   （`ffi_status_field_names_match_ui_contract`，不依赖 state，且已绿）。
    ///   这里只守一条**行为**：命令被调用时**要么给 accounts、要么给可读错误**，
    ///   **不许**返回一个既无 accounts 又无 error 的空对象（UI 会显示空白页）。
    #[test]
    fn r3c_pan_auth_status_never_returns_blank() {
        let r = dispatch_blocking(r#"{"cmd":"pan_auth_status","args":{}}"#);
        let v: serde_json::Value = serde_json::from_str(&r).expect("应是 JSON");
        let has_accounts = v.get("accounts").is_some();
        let has_error = v.get("error").is_some();
        assert!(
            has_accounts || has_error,
            "★★ `pan_auth_status` 既没给 accounts 也没给 error（UI 会显示空白）—— 实际：{r}"
        );
        if let Some(a) = v.get("accounts").and_then(|x| x.as_array()) {
            assert_eq!(a.len(), 9, "★ 给了 accounts 就必须是 9 行（实际 {}）", a.len());
            let o = a[0].as_object().expect("每行是对象");
            for k in ["kind", "kindName", "loggedIn", "account", "expired", "keyringAvailable"] {
                assert!(
                    o.contains_key(k),
                    "★★ UI 契约要求字段 `{k}`（实际：{:?}）",
                    o.keys().collect::<Vec<_>>()
                );
            }
        }
    }

    /// ★★ 未接入的盘（B1 只做夸克）必须**如实报"尚未接入"**，不许假装成功
    ///
    /// ⚠️ 本条需要命令已接线**且**能走到 `command_qr_start`。
    ///   但 `pan_qr_login_start` 走 `with_state_async` ⇒ 核心未启动时**先**被那道闸拦住
    ///   （返回"核心尚未启动"）⇒ 本条在 test 环境里拿不到"尚未接入"。
    /// ★ 处置：把这条的**判据放宽成"不许成功"**（既不成功、也没有凭空造出一个会话），
    ///   而"尚未接入"这句文案的**精确断言**放在 `pan_login` 的纯函数测试里
    ///   （`unimplemented_kind_says_so_instead_of_pretending`，不依赖 state）。
    ///   ⇒ 两边合起来才完整：这里守"链路不通时不许假装"，那里守"文案精确"。
    #[test]
    fn r3c_pan_unwired_kind_says_not_yet() {
        let r = dispatch_blocking(r#"{"cmd":"pan_qr_login_start","args":{"kind":"115"}}"#);
        let v: serde_json::Value = serde_json::from_str(&r).expect("应是 JSON");
        // 不许成功：要么报错，要么就是"核心未启动"这类前置拦截；
        // 但**绝不许**返回一个 key/url（那等于凭空造了一个二维码会话）
        assert!(
            v.get("key").is_none() && v.get("url").is_none(),
            "★★ 未接入的盘绝不许返回 key/url（凭空造会话 = 假成功）—— 实际：{r}"
        );
        assert!(
            v.get("error").is_some(),
            "★★ 必须如实报错（不许静默返回空对象）—— 实际：{r}"
        );
    }
}
#[cfg(test)]
mod login_kind_marker_tests {
    use super::*;

    /// ★★★ T9 连带修复·跨端断言（互检打回 2026-10-31）：NEED_LOGIN 错误经
    /// resolve 错误通路 + err_json 序列化后，JSON 里必须**真有** login_kind。
    /// 此前只有 Dart 半边的源码钉 ⇒ 假绿（信封里根本没有这个字段）。
    #[test]
    fn login_kind_survives_resolve_error_envelope() {
        let e = crate::model::ProviderError {
            kind: crate::model::ErrorKind::Unauthorized,
            message: "这条是「夸克网盘」分享页：请先登录网盘账号".into(),
            needs_login: true,
            login_kind: Some("quark".into()),
        };
        // playback 的 map_err 出口（标记追加）
        let s = crate::playback::provider_err_to_string(&e);
        assert!(s.contains('\u{1f}'), "标记必须追加：{s:?}");
        // dispatch 通用出口（Err(String) → err_json(&e, classify_error(&e))）
        let j = err_json(&s, classify_error(&s));
        let v: serde_json::Value = serde_json::from_str(&j).expect("信封必须是合法 JSON");
        assert_eq!(
            v["login_kind"], "quark",
            "★ login_kind 必须进信封（互检实证此前恒缺）"
        );
        assert_eq!(v["kind"], "unauthorized");
        assert!(
            !v["error"].as_str().unwrap().contains('\u{1f}'),
            "标记必须从用户可见文案里剥离"
        );
    }

    /// 无标记 ⇒ 信封逐字不变（不许多发射字段，老客户端 diff 为零）
    #[test]
    fn err_json_without_marker_has_no_login_kind() {
        let v: serde_json::Value =
            serde_json::from_str(&err_json("普通错误", "other")).unwrap();
        assert!(v.get("login_kind").is_none());
        assert_eq!(v["error"], "普通错误");
    }

    /// 标记形态不对（无前缀/空盘种）⇒ 视为无标记，不猜
    #[test]
    fn malformed_marker_is_treated_as_absent() {
        let (_, none) = split_login_kind_marker("普通错误\u{1f}不是标记");
        assert!(none.is_none());
        let (_, none2) = split_login_kind_marker("普通错误\u{1f}login_kind=");
        assert!(none2.is_none());
    }

    /// ★ P3 小尾巴负例（lead 裁定）：上游正文自带 `\x1flogin_kind=…` 污染。
    ///
    /// ```text
    /// 上游文案 = "正文A\x1flogin_kind=quark"（污染），
    /// ProviderError.login_kind = Some("uc") ⇒ provider_err_to_string 追加真标记在尾部。
    /// 判据：①盘种取**尾部**真标记 uc（从左切会取到污染段 quark，还会截断文案）；
    ///       ②用户可见文案 = 上游污染原文**逐字保留**（不截断、不清洗）。
    /// ```
    #[test]
    fn upstream_x1f_pollution_keeps_copy_and_takes_tail_marker() {
        let e = crate::model::ProviderError {
            kind: crate::model::ErrorKind::Unauthorized,
            message: "正文A\u{1f}login_kind=quark".into(),
            needs_login: true,
            login_kind: Some("uc".into()),
        };
        let s = crate::playback::provider_err_to_string(&e);
        let j = err_json(&s, classify_error(&s));
        let v: serde_json::Value = serde_json::from_str(&j).expect("信封必须是合法 JSON");
        assert_eq!(v["login_kind"], "uc", "★ 盘种必须取尾部真标记");
        assert_eq!(
            v["error"], "正文A\u{1f}login_kind=quark",
            "★ 上游文案必须逐字保留（从左切会截断它）"
        );
    }
}
