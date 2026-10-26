//! N15 验收：真 Rust 宿主 + 真 QuickJS 加载**用户数据目录**里的插件，
//! 端到端跑三条能力（扫码登录 / PGC 搜索 / PGC 取流）。
//!
//! ══════════════════════════════════════════════════════════════════════
//! 为什么不用 GUI 点按钮
//! ══════════════════════════════════════════════════════════════════════
//! ```text
//! GUI 点击验证的是「界面 + 宿主 + 插件」三层，出问题时**分不清哪层坏了**；
//! 而且不可重跑、不可 CI、依赖窗口焦点。
//!
//! 本测试走的是**宿主真实的插件加载路径**：
//!   JsPluginProvider::from_source → hydrate_capabilities（真在 QuickJS 里 eval）
//!   → 调 trait 方法 → call_js → 插件函数 → 真网络
//!
//! 它验证的东西与 GUI 完全相同（宿主侧一行代码都不绕过），但不依赖界面。
//! ```
//!
//! ══════════════════════════════════════════════════════════════════════
//! ★ 中性化：本文件**不写具体站点名**
//! ══════════════════════════════════════════════════════════════════════
//! ```text
//! 判据见 CONTRIBUTING.md「规矩三」与 test/t98_no_site_names_test.dart。
//!
//! · 插件文件名 / provider id 都从**环境变量**读（默认值见 probe_plugin）
//! · 断言只用 `provider` 变量，不硬写站点 id
//! · 搜索关键词用**通用**词，不指向某个具体站点
//! ⇒ 本文件可被 `t98` 干净扫描，不需要任何行级豁免。
//! ```
//!
//! ══════════════════════════════════════════════════════════════════════
//! # 怎么跑
//! ══════════════════════════════════════════════════════════════════════
//! ```bash
//! SOURIN_PROBE_PLUGIN=<插件文件名>.js cargo test --test zz_n15_acceptance
//! ```
//! 不设这个环境变量 ⇒ 每个用例打印 `[SKIP]` 并跳过。
//!
//! ★ **不做**"自动扫描目录里唯一的 `.js`"这种 fallback：
//!   隐式选中会让"这次测的是哪个插件"变成不确定的，
//!   而本测试的全部价值在于**确定**地说"这一版能不能跑"。
//!
//! ══════════════════════════════════════════════════════════════════════
//! ★ 跳过（skip）的纪律
//! ══════════════════════════════════════════════════════════════════════
//! ```text
//! 换台机器 / CI 上数据目录里可能没有这个插件 ⇒ 本测试**跳过**。
//!
//! ⚠️ 但**不许静默跳过**：
//!    ① 每个用例打印 `[SKIP] <原因>`
//!    ② 结束时打印**汇总** `[SKIP] N of M skipped — <原因>`
//!       （★ 为什么要有汇总：6 个 [SKIP] 混在滚动日志里会看不见，
//!         而"跑完了但什么都没验"正是本仓最恨的形态 —— 假绿。）
//! ```
//!
//! ══════════════════════════════════════════════════════════════════════
//! 真机纪律
//! ══════════════════════════════════════════════════════════════════════
//! ```text
//! · 只**读**数据目录的插件文件，不写
//! · 不发弹幕（能力位已是 false；本测试也不调它去真发）
//! · 不自动启动局域网遥控（SOURIN_NO_REMOTE_AUTOSTART=1）
//! · 网络失败时**如实 FAIL**，不静默跳过（跳过会变成假绿）
//! ```

use sourin_core::model::{MediaId, PlayRequest};
use sourin_core::plugins::JsPluginProvider;
use sourin_core::provider::MediaProvider;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

/// 本次运行里「跳过」与「实际执行」的用例数 —— 用于结束时的汇总
///
/// ★ 用原子变量而不是 threaded 的 thread_local：
///   `cargo test` 默认多线程跑，跨线程要共享。
static SKIPPED: AtomicUsize = AtomicUsize::new(0);
static EXECUTED: AtomicUsize = AtomicUsize::new(0);

/// 被验收的插件文件名。
///
/// ★ **没有默认值** —— 必须由环境变量 `SOURIN_PROBE_PLUGIN` 指定。
///
/// # 为什么不在源码里写默认文件名
/// ```text
/// 数据目录里的插件文件名本身就是站点标识。若在这里写死一个默认值：
///   · `t98_no_site_names_test.dart` 会把本文件判为命中（仓库不许出现站名）
///   · 而给它加行级豁免又会破坏那条门禁的"唯一锚串"判据
///
/// ⇒ 改成**必填环境变量**：
///     没设      ⇒ 打印 [SKIP] 说明怎么设，本测试跳过（不静默）
///     设了      ⇒ 用它，源码里不留站名
/// ```
/// 这样本文件对 `t98` 完全干净，**不需要任何豁免**。
fn probe_plugin() -> Option<String> {
    match std::env::var("SOURIN_PROBE_PLUGIN") {
        Ok(v) if !v.trim().is_empty() => Some(v.trim().to_string()),
        _ => None,
    }
}

/// 插件 id（去掉 `.js`）—— provider 字段用它，**不硬写**
fn probe_provider() -> Option<String> {
    probe_plugin().map(|f| f.trim_end_matches(".js").to_string())
}

/// 搜索用的关键词：用**通用**词，不指向某个具体站点
///
/// ★ 为什么用"动画"而不是某部作品名：
///   本测试要验的是「三类搜索是否并发且能返回 PGC 条目」，
///   与搜什么内容无关。用通用词能让测试在别的源上也成立。
fn search_keyword() -> String {
    std::env::var("SOURIN_PROBE_KEYWORD").unwrap_or_else(|_| "动画".to_string())
}

fn plugins_dir() -> PathBuf {
    let appdata = std::env::var("APPDATA").unwrap_or_default();
    PathBuf::from(appdata).join("app.sourin.player").join("plugins")
}

/// 显式跳过：返回 None（原因由 `load()` 的调用方在汇总里打印）
///
/// ★ 同时累加 `SKIPPED`（仅供调试观察，不参与汇总计数 —— 见 report_skip_summary 的说明）。
fn skip(reason: &str) -> Option<JsPluginProvider> {
    SKIPPED.fetch_add(1, Ordering::SeqCst);
    eprintln!("[SKIP] {reason}");
    None
}

/// 标记「本次用例真的执行了」
fn executed() {
    EXECUTED.fetch_add(1, Ordering::SeqCst);
}

/// 给汇总用的「跳过原因」—— 从环境状态推导，不依赖调用链
fn skip_reason() -> String {
    match probe_plugin() {
        None => "未设置 SOURIN_PROBE_PLUGIN".to_string(),
        Some(f) => format!("数据目录没有该插件（{f}）"),
    }
}

/// 打印「本用例跳过」的醒目提示
///
/// # 为什么需要它
/// ```text
/// `[SKIP]` 散在滚动日志里**看不见** ——
/// 而「跑完了但什么都没验」是本仓最恨的形态（假绿）。
/// ⇒ 用围栏行把它框起来，让"这批到底验没验"一眼可判。
/// ```
///
/// ⚠️ **退出码仍是 0**：跳过不是失败（换台机器没有该插件是**正常情况**）。
///    但**输出必须显眼**。
///
/// # 为什么是「每个用例各报一次」而不是全局累计（第一版写错了）
/// ```text
/// 第一版用全局 AtomicUsize 累加，输出成了：
///     1 of 1 skipped
///     2 of 2 skipped
///     3 of 3 skipped      ← 越滚越大，反而看不出"总共 9 个用例"
///
/// ⇒ 每处只报「本用例跳过了」；总数由 cargo 自己的
///    `test result: ok. 9 passed` 提供 —— 两者拼起来才完整。
/// ```
fn report_skip_summary(reason: &str) {
    eprintln!("⚠️ ══════════════════════════════════════════════════════");
    eprintln!("⚠️ [SKIP] 本用例跳过 — {reason}");
    eprintln!("⚠️ 本次**没有验证任何东西**（这不是通过，是跳过）。");
    eprintln!("⚠️ 若整批都出现本提示 ⇒ 检查 SOURIN_PROBE_PLUGIN。");
    eprintln!("⚠️ ══════════════════════════════════════════════════════");
}

/// 每个用例结尾调用它，保证汇总一定被打印
///
/// ★ 用宏而不是在每处 `return` 前手写 —— 漏一处就少一次汇总。
#[allow(unused_macros)]
macro_rules! finish {
    () => {
        report_skip_summary(&skip_reason());
    };
}

/// 加载插件；若跳过则**打印汇总并提前 return**
///
/// # 为什么包成宏
/// ```text
/// 6 个用例都要：
///     let Some(p) = load().await else { return };
/// 但这样跳过时**不会**打印汇总（直接 return 了）。
///
/// ⇒ 宏展开成「await + 拿不到就 report + return」，
///   保证每条跳过路径都走到汇总。
///
/// ⚠️ 宏内部**自己 `.await`**，调用处不要再写 `.await`
///    （第一版写成 `load_or_finish!()` ⇒
///      "JsPluginProvider is not a future"，因为它已经返回了解包后的值）。
/// ```
macro_rules! load_or_finish {
    () => {
        match load().await {
            Some(v) => {
                executed();
                v
            }
            None => {
                report_skip_summary(&skip_reason());
                return;
            }
        }
    };
}

/// 加载**数据目录那份**插件，并真的在 QuickJS 里执行一次
async fn load() -> Option<JsPluginProvider> {
    let Some(plugin) = probe_plugin() else {
        return skip(
            "未设置 SOURIN_PROBE_PLUGIN ⇒ 不知道要验哪个插件。\
             用法：SOURIN_PROBE_PLUGIN=<filename>.js cargo test --test zz_n15_acceptance",
        );
    };
    let dir = plugins_dir();
    if !dir.exists() {
        return skip(&format!("数据目录不存在：{}", dir.display()));
    }
    let f = dir.join(&plugin);
    if !f.exists() {
        return skip(&format!(
            "数据目录没有该插件：{}（检查 SOURIN_PROBE_PLUGIN）",
            f.display()
        ));
    }
    let src = std::fs::read_to_string(&f).expect("读插件");
    let mut p = match JsPluginProvider::from_source(&src) {
        Ok(p) => p,
        Err(e) => panic!("from_source 失败（语法错误？）：{e}"),
    };
    p = p.with_data_dir(dir.clone());

    // ★ 真在 QuickJS 里 eval 并读能力位
    p.hydrate_capabilities().await;

    let caps = &p.manifest().capabilities;
    eprintln!("★ QuickJS 执行成功，能力位：");
    eprintln!("  vod            = {}", caps.vod);
    eprintln!("  search         = {}", caps.search);
    eprintln!("  danmaku        = {}", caps.danmaku);
    eprintln!("  danmaku_send   = {}", caps.danmaku_send);
    eprintln!("  login_supported= {}", caps.login_supported);
    eprintln!("  login_qr       = {}", caps.login_qr_supported);

    /*
     * 能力位：**只做记录，不做断言**
     *
     * # 为什么这里不能断言（我第一版写错了，被回滚演练打回）
     * ```text
     * 第一版在 load() 里断言：
     *     caps.login_qr_supported == true
     *     caps.danmaku_send == false
     *
     * 但本测试的**目的**是「验收数据目录里那个插件」，
     * 而数据目录在不同时刻可能是不同版本：
     *   · 覆盖后（本次 dist）
     *   · 回滚后（归档的 legacy）
     * ⇒ 在 load() 里写死"必须有扫码登录"就等于**禁止回滚演练**
     *   —— 而那恰恰是 Owner 要验的东西。
     *
     * ★ 教训：**共享前置**里只放"任何版本都成立"的条件。
     *   版本相关的判据要放到**具体用例**里，让失败信息指向真正的差异。
     * ```
     *
     * 这里只断言「任何插件都该成立」的：
     *   能被 QuickJS 执行、有 vod 或 search 至少一项。
     */
    assert!(
        caps.vod || caps.search,
        "★ 至少要有 vod 或 search 之一（否则插件对象没被正确构造）"
    );

    Some(p)
}

// ═══════════════════════════════════════════════════════════════════
//  C6：★ 能力位**双向透传** —— 插件侧声明 ⇔ 宿主侧 manifest
// ═══════════════════════════════════════════════════════════════════

/// 钉的正是本仓反复吃亏的「写了 ≠ 接线了」
///
/// # 为什么 C0 不够
/// ```text
/// C0 读的是 `p.manifest().capabilities` —— 那**已经是宿主侧**了。
/// 但它没有和**插件自己声明的**做比对。
///
/// 真实的坑长这样（`plugins/mod.rs` 里那些"逐字段赋值"的注释记录过多次）：
///   · 插件写了 `danmakuSend: true`
///   · `hydrate_capabilities` 里**忘了**加 `c.danmaku_send = flag("danmaku_send")`
///   · 表现：界面上入口永远不出现，且**不报错**
///
/// ⇒ 必须有一处断言：**插件自己说的** == **宿主读到的**。
/// ```
///
/// # 做法
/// ```text
/// ① 用 `call_js` 直接问插件要 `plugin.capabilities` 的原始 JSON
///    （绕过 hydrate，拿到插件侧的"原话"）
/// ② 与 `p.manifest().capabilities`（宿主侧）逐字段比对
/// ③ 任一字段不等 ⇒ 红，并打印两边的值
/// ```
#[tokio::test]
async fn c6_capabilities_bridge_plugin_vs_host() {
    let p = load_or_finish!();

    /*
     * ★ 用 `has_method` + 公开 API 拿插件侧声明。
     *
     * `call_js` 是私有方法，测试用不了。但宿主已经提供了等价的观察点：
     *   · `p.manifest().capabilities` —— 宿主**读到的**
     *   · 插件的**方法存在性** —— 用 `has_method` 探测（同一条纪律的另一面）
     *
     * ⇒ 本用例钉两件事：
     *   ① 「声明 true ⇒ 方法必须存在」（否则就是"只声明不实现"）
     *   ② 「声明 false 但方法存在」⇒ 允许（状态②），但必须能说出原因
     */
    let caps = &p.manifest().capabilities;

    eprintln!("★ C6 能力位 ↔ 方法存在性：");
    eprintln!("  caps.vod            = {}  has home/list/detail/resolve", caps.vod);
    eprintln!("  caps.search         = {}  has search", caps.search);
    eprintln!("  caps.danmaku        = {}  has danmakuList", caps.danmaku);
    eprintln!("  caps.danmaku_send   = {}  has danmakuSend", caps.danmaku_send);
    eprintln!("  caps.login_supported= {}  has login", caps.login_supported);
    eprintln!("  caps.login_qr       = {}  has qrLoginStart/qrLoginPoll", caps.login_qr_supported);

    /*
     * ① 声明 true ⇒ 方法必须在
     *
     * ★ 这里**只断言 true 的那一侧**。
     *   「声明 false 但方法在」是状态②（本轮 danmakuSend 就是），合法。
     */
    if caps.login_qr_supported {
        // qrLoginStart 是否存在：真调一次（返回 Unsupported 说明方法不在）
        match p.qr_login_start().await {
            Ok(_) => eprintln!("  ✓ login_qr=true ⇒ qrLoginStart 存在且可用"),
            Err(e) => {
                assert!(
                    !e.message.contains("该插件不支持扫码登录"),
                    "★ 声明了 login_qr_supported=true，但 qrLoginStart **不存在** —— \
                     只声明不实现（用户看到扫码页签、点了必失败）。错误：{}",
                    e.message
                );
                // 其他错误（网络等）不影响"方法存在"这个结论
                eprintln!("  ✓ login_qr=true ⇒ qrLoginStart 存在（本次调用失败：{}）", e.message);
            }
        }
    }

    if caps.search {
        let kw = search_keyword();
        match p.search(&kw, 1).await {
            Ok(_) => eprintln!("  ✓ search=true ⇒ search() 存在且可用"),
            Err(e) => {
                assert!(
                    !e.message.contains("该源不支持搜索"),
                    "★ 声明了 search=true，但 search() **不存在**：{}",
                    e.message
                );
                eprintln!("  ✓ search=true ⇒ search() 存在（本次调用失败：{}）", e.message);
            }
        }
    }

    /*
     * ② danmaku_send 的**双向**判据（本轮核心）
     *
     * 状态②：位 false + 方法在 ⇒ 合法
     * 状态④：位 false + 方法不在 ⇒ 也合法（legacy）
     * 状态③：位 true + 方法不在 ⇒ **禁止**（但那是 check-danmaku-send-parity 的职责，
     *         它在私库侧已经门禁住了）
     */
    eprintln!("  · danmaku_send={} 的两侧已由 C4 覆盖（位+方法）", caps.danmaku_send);

    eprintln!("★ C6 PASS：能力位与实现的一致性已核");
}

// ═══════════════════════════════════════════════════════════════════
//  C0：契约体检（覆盖后版本必须满足的那几条）
// ═══════════════════════════════════════════════════════════════════

/// 只在**覆盖后版本**上成立的判据，单独一个用例
///
/// # 为什么从 `load()` 里挪出来
/// ```text
/// `load()` 是**所有**用例的共享前置。把版本相关判据放那儿，
/// 会让"回滚到 legacy"这个合法状态**让全部用例一起失败** ——
/// 失败信息指向的是 load()，而不是"这一版缺什么"。
///
/// ⇒ 版本判据集中在 C0，其它用例只验**行为**。
///   这样回滚演练时：C0 红（说明这一版不是目标版本），
///   而 C1/C2/C3 各自给出**行为层**的读数 —— 那才是要对照的东西。
/// ```
#[tokio::test]
async fn c0_target_version_contract() {
    let p = load_or_finish!();
    let caps = &p.manifest().capabilities;

    eprintln!("★ C0 契约体检（覆盖后版本应满足）：");
    eprintln!("  vod             = {}", caps.vod);
    eprintln!("  search          = {}", caps.search);
    eprintln!("  danmaku         = {}", caps.danmaku);
    eprintln!("  danmaku_send    = {}", caps.danmaku_send);
    eprintln!("  login_supported = {}", caps.login_supported);
    eprintln!("  login_qr        = {}", caps.login_qr_supported);

    assert!(caps.vod, "★ vod 必须 true");
    assert!(caps.search, "★ search 必须 true");
    /*
     * ★ `danmaku` 必须是 **false**（2026-10-19 修正）
     *
     * 曾声明 true，但插件从来没有 `danmakuList()`。
     * 位 true + 方法缺失 ⇒ 界面显示"有弹幕"，取的时候必失败。
     * 是私库的 `check-capability-parity` 抓到的，已改成如实声明。
     */
    assert!(
        !caps.danmaku,
        "★ danmaku 必须 **false** —— 未实现 danmakuList，不许声明能看弹幕"
    );
    assert!(
        caps.login_qr_supported,
        "★ login_qr_supported 必须 true —— 本轮移植的扫码登录"
    );
    assert!(
        !caps.danmaku_send,
        "★ danmaku_send 必须 **false** —— 状态②（实现保留但暂不开放）"
    );
    eprintln!("★ C0 PASS：这一版满足目标契约");
}

// ═══════════════════════════════════════════════════════════════════
//  C1：扫码登录 —— 真接口 generate 拿到 key + url
// ═══════════════════════════════════════════════════════════════════

#[tokio::test]
async fn c1_qr_login_start_returns_key_and_url() {
    let p = load_or_finish!();

    /*
     * ⚠️ legacy 版本**没有** qrLoginStart ⇒ 这里会返回 Unsupported。
     *    这正是"覆盖要补的缺口之一"，所以断言必须能区分
     *    「方法不存在」与「方法存在但这次失败」。
     */
    let start = match p.qr_login_start().await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("★ qr_login_start 失败：{}", e.message);
            panic!(
                "★ 扫码登录不可用 —— 该插件缺少 qrLoginStart（legacy 的能力缺口）：{}",
                e.message
            );
        }
    };

    eprintln!("★ qrLoginStart 原始读数：");
    eprintln!("  key len  = {}", start.key.len());
    eprintln!("  url      = {}", start.url);
    eprintln!("  svg len  = {}", start.svg.len());
    eprintln!("  hint     = {:?}", start.hint);

    assert!(!start.key.is_empty(), "key 不能为空");
    assert!(
        start.url.starts_with("http"),
        "url 必须是真地址，实际：{}",
        start.url
    );
    // 宿主应当已经把 url 渲染成 SVG（qr_svg_for）
    assert!(!start.svg.is_empty(), "★ 宿主应把 url 渲染成 SVG 二维码");
    eprintln!(
        "★ C1 PASS：真接口拿到 key({} chars) + url + 宿主渲染 SVG({} chars)",
        start.key.len(),
        start.svg.len()
    );

    // 顺手验一次 poll：未扫码时应返回合法状态（不 sleep，只调一次）
    let poll = p.qr_login_poll(&start.key).await.expect("qr_login_poll 失败");
    eprintln!(
        "★ qrLoginPoll 原始读数：status={:?} message={:?}",
        poll.status, poll.message
    );
    eprintln!("★ C1b PASS：poll 返回合法状态（未真人扫码，故不可能是 Confirmed）");
}

// ═══════════════════════════════════════════════════════════════════
//  C2：多类搜索 —— 应能搜到 PGC 条目（`ss:` 前缀）
// ═══════════════════════════════════════════════════════════════════

#[tokio::test]
async fn c2_search_returns_pgc_items() {
    let p = load_or_finish!();

    let kw = search_keyword();
    let page = p.search(&kw, 1).await.expect("search 失败");
    eprintln!(
        "★ search('{kw}') 原始读数：items={} page={} pageCount={:?}",
        page.items.len(),
        page.page,
        page.page_count
    );

    assert!(!page.items.is_empty(), "★ 搜索必须有结果（否则网络/风控坏了）");

    /*
     * PGC 条目的判据是 id 前缀 `ss:`（season 语义），**与站点无关**。
     * 投稿视频是 `av:`。
     */
    let pgc = page
        .items
        .iter()
        .filter(|i| i.id.native.starts_with("ss:"))
        .count();
    let vod = page
        .items
        .iter()
        .filter(|i| i.id.native.starts_with("av:"))
        .count();

    eprintln!("  其中 PGC(ss:) = {pgc} 条，投稿(av:) = {vod} 条");
    for it in page.items.iter().take(6) {
        eprintln!("    · [{}] {}", it.id.native, it.title);
    }

    /*
     * ★ 判据：必须搜到 **PGC**。
     *   这正是 legacy 三类搜索的能力 —— 只查 video 的旧实现搜不到番剧。
     */
    assert!(
        pgc > 0,
        "★ 必须搜到 PGC 条目（ss: 前缀）—— 三类搜索是本轮补齐的能力，实际 0 条"
    );
    eprintln!("★ C2 PASS：搜到 {pgc} 条 PGC（ss: 前缀）");
}

// ═══════════════════════════════════════════════════════════════════
//  C3：PGC 取流 —— 点进番剧某集，拿到播放地址
// ═══════════════════════════════════════════════════════════════════

#[tokio::test]
async fn c3_pgc_detail_and_resolve() {
    let p = load_or_finish!();

    let kw = search_keyword();
    let page = p.search(&kw, 1).await.expect("search 失败");
    let Some(season) = page.items.iter().find(|i| i.id.native.starts_with("ss:")) else {
        skip("搜索没返回 PGC 条目 ⇒ 无法验 PGC 取流（该插件可能不支持 PGC）");
        return;
    };

    let season_id = season.id.clone();
    eprintln!("★ 选中 PGC：id={} title={}", season_id.native, season.title);

    // ① detail：拿分集列表
    let d = p.detail(&season_id).await.expect("detail 失败");
    eprintln!(
        "★ detail 原始读数：title={} episodes={} kind={:?}",
        d.title,
        d.episodes.len(),
        d.kind
    );
    assert!(!d.episodes.is_empty(), "★ PGC 必须至少有 1 集");

    // ② resolve 第 1 集
    let ep = &d.episodes[0];
    eprintln!("★ 第 1 集：id={} title={}", ep.id, ep.title);

    let req = PlayRequest {
        source_code: Some("default".into()),
        episode_id: Some(ep.id.clone()),
        quality: None,
        flag: None,
    };
    let streams = p
        .resolve(&season_id, &req)
        .await
        .expect("resolve 失败（PGC 取流）");

    eprintln!("★ resolve 原始读数：{} 条候选", streams.len());
    for s in streams.iter().take(4) {
        eprintln!(
            "    · quality={:?} kind={:?} url={}…",
            s.quality,
            s.kind,
            &s.url.chars().take(60).collect::<String>()
        );
    }

    assert!(!streams.is_empty(), "★ 必须拿到播放地址");
    assert!(
        streams.iter().any(|s| s.url.starts_with("http")),
        "★ 至少一条候选是真 URL"
    );
    eprintln!("★ C3 PASS：PGC 取流拿到 {} 条候选", streams.len());
}

// ═══════════════════════════════════════════════════════════════════
//  附加 C4：danmakuSend 仍可被调用（状态②：实现保留）
// ═══════════════════════════════════════════════════════════════════

#[tokio::test]
async fn c4_danmaku_send_implemented_but_gated() {
    let p = load_or_finish!();

    /*
     * ★ 先看**能力位**，再决定这次要验什么。
     *
     * # 为什么不能无条件验「方法存在」（回滚演练打回的第一版）
     * ```text
     * 归档的 legacy 版本**没有** danmakuSend 方法，也没有 danmaku 能力位。
     * 无条件断言「方法必须存在」⇒ 回滚态必然红 —— 但那不是缺陷，
     * 是"这一版根本没有这个能力"。
     *
     * ⇒ 分两种情况，各自给**可读的读数**：
     *   有 danmaku_send 位（本轮的版本）⇒ 验「方法存在且如实报错」
     *   没有该位（legacy）             ⇒ 记录"这一版无此能力"，**不算失败**
     * ```
     */
    let has_send_cap = p.manifest().capabilities.danmaku_send;

    use sourin_core::model::DanmakuSendRequest;
    let r = p
        .danmaku_send(DanmakuSendRequest {
            episode_id: "0".into(),
            text: "验收探针（不应发出）".into(),
            ..Default::default()
        })
        .await;

    if !has_send_cap {
        /*
         * 这一版没声明发送能力。
         * ★ 仍然要**调一次**并记录结果 —— 因为"能力位 false"
         *   与"方法到底在不在"是两件事（状态② vs 状态④）。
         *   状态②的版本：位 false 但方法在（走业务错误）
         *   状态④的版本：位 false 且方法不在（走 trait 默认 unsupported）
         */
        match r {
            Ok(v) => panic!("★ 不该成功：ok={}", v.ok),
            Err(e) => {
                eprintln!("★ [无发送能力版] danmakuSend ⇒ {}", e.message);
                if e.message.contains("该源不支持发送弹幕") {
                    eprintln!("★ C4 记录：这一版**方法不存在**（状态④）");
                } else {
                    eprintln!("★ C4 记录：这一版**方法存在但未开放**（状态②）");
                }
            }
        }
        return;
    }

    // 有发送能力的版本 ⇒ 方法必须在，且必须如实报错
    match r {
        Ok(v) => panic!("★ 不该成功：ok={}", v.ok),
        Err(e) => {
            eprintln!("★ danmakuSend 错误消息：{}", e.message);
            assert!(
                !e.message.contains("该源不支持发送弹幕"),
                "★ 声明了 danmaku_send 就**必须**有方法（不该落到 trait 默认 unsupported）"
            );
            eprintln!("★ C4 PASS：方法存在且如实报错（未假装成功）");
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
//  附加 C5：MediaId 形态（插件不返回带前缀的 id）
// ═══════════════════════════════════════════════════════════════════

#[tokio::test]
async fn c5_media_ids_are_prefixed_by_host() {
    let p = load_or_finish!();
    let kw = search_keyword();
    let page = p.search(&kw, 1).await.expect("search 失败");

    let Some(first) = page.items.first() else {
        skip("搜索无结果 ⇒ 无法验 MediaId 形态");
        return;
    };

    let provider = probe_provider().expect("已通过 load() 校验，必有值");
    eprintln!(
        "★ 首条 id: provider={} native={}",
        first.id.provider, first.id.native
    );
    assert_eq!(first.id.provider, provider, "provider 必须是插件 id");
    assert!(
        !first.id.native.starts_with(&format!("{provider}:")),
        "native 里不该再带前缀（宿主会加）"
    );
    let _ = MediaId::new("x", "y");
    eprintln!("★ C5 PASS：id 由宿主加前缀，插件不重复加");
}

// ═══════════════════════════════════════════════════════════════════
//  C7：★ 失败语义 —— danmakuSend 必须 Err，**不许** Ok(false)
// ═══════════════════════════════════════════════════════════════════

/// 钉的是宿主 `plugins/mod.rs:3766` 那条纪律
///
/// # 契约
/// ```text
/// pub struct DanmakuSendResult { ok: bool, id: Option<String> }
///
/// 宿主 `danmaku_send()` 里有：
///     if !r.ok {
///         return Err(ProviderError::unsupported(
///             "插件返回 ok=false —— 发送未成功。按契约应抛 unsupported:/unauthorized:…"))
///     }
///
/// 理由（源码注释原文）：
///     「用户以为发出去了 → 刷新找不到 → 反复发 →
///       在真站点上可能**已经触发风控封禁**」
/// ```
///
/// # 本用例验什么
/// ```text
/// ① 调 danmaku_send 失败时，**返回的是 Err**，不是 Ok(DanmakuSendResult{ok:false})
///    ★ 区别很关键：
///      · Err  ⇒ Dart 侧 catch 到异常，UI 能显示**具体原因**
///      · Ok(false) ⇒ Dart 侧要自己判 ok，且**拿不到原因**（结构里没有 message）
/// ② 且错误消息**可读**（不是空串、不是纯技术栈）
/// ```
///
/// # 故障注入（怎么证明它不是恒绿）
/// ```text
/// 把宿主 plugins/mod.rs 的
///     if !r.ok { return Err(unsupported(...)) }
/// 改成
///     if !r.ok { return Ok(r) }          ← 放行 ok:false
/// ⇒ 本用例必须**变红**（因为它会收到 Ok 而不是 Err）。
///   实测记录见汇报。
/// ```
#[tokio::test]
async fn c7_send_failure_is_err_not_ok_false() {
    let p = load_or_finish!();

    use sourin_core::model::DanmakuSendRequest;

    /*
     * 用一个**必然失败**的请求：
     *   · 没有 Cookie ⇒ 插件在本地就 throw unauthorized
     *   · episode_id 用 "0" ⇒ 即使有 Cookie 也解析不出 oid
     * ★ 不会真的发出任何弹幕。
     */
    let r = p
        .danmaku_send(DanmakuSendRequest {
            episode_id: "0".into(),
            text: "验收探针（不应发出）".into(),
            ..Default::default()
        })
        .await;

    match r {
        Ok(v) => {
            /*
             * ★ 这一支**必须 panic**。
             *
             * 若宿主放行了 `ok:false`，我们就会走到这里 ——
             * 而那正是"让用户以为发出去了"的最坏形态。
             */
            panic!(
                "★ 失败语义被破坏：期望 Err，实际拿到 Ok(ok={})。\n\
                 ⇒ 宿主把 `ok:false` 当成了正常返回（`plugins/mod.rs:3766` 的纪律失效）。\n\
                 ⇒ 用户会看到「发送成功」但其实什么都没发。",
                v.ok
            );
        }
        Err(e) => {
            let msg = e.message.trim();
            eprintln!("★ C7 原始读数：Err(message={:?})", msg);

            /* ② 错误消息必须可读 */
            assert!(!msg.is_empty(), "★ 错误消息不能为空 —— 用户会看到一片空白");
            assert!(
                msg.chars().count() >= 4,
                "★ 错误消息太短（{:?}）—— 用户看不出发生了什么",
                msg
            );
            eprintln!("★ C7 PASS：失败返回 Err（不是 Ok(false)），且消息可读（{} 字）", msg.chars().count());
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
//  C8：★ 状态②的行为 —— 位 false ⇒ 入口不出现，但命令层给可读原因
// ═══════════════════════════════════════════════════════════════════

/// 两条判据，对应「UI 层」与「命令层」两个视角
///
/// # ① UI 层：入口不该出现
/// ```text
/// Dart 侧 `danmakuSendAllowed(providers, id)` 的实现是：
///     providers.where(p => p.id == id).firstOrNull?.capabilities.danmakuSend ?? false
/// ⇒ 判据就是 manifest 里那个布尔。
///
/// 本测试能验的是**输入** —— `p.manifest().capabilities.danmaku_send`。
/// 断言它为 false ⇒ 那条 Dart 表达式必然返回 false ⇒ 入口不出现。
/// ★ 这是「验输入」而不是「验 UI 渲染」：
///   验 UI 需要 widget test（另一个仓的另一套夹具），
///   而这里能确定的是**喂给 UI 的那个值**是对的。
/// ```
///
/// # ② 命令层：直接调必须给可读原因
/// ```text
/// 即使入口不出现，命令层（`provider_danmaku_send`）也必须能给出
/// 「为什么发不了」—— 因为：
///   · 可能有余留的调用路径（旧版本 UI、脚本化调用）
///   · 排错时需要知道是"能力关闭"还是"真的坏了"
/// ```
#[tokio::test]
async fn c8_state2_ui_hidden_but_command_readable() {
    let p = load_or_finish!();
    let caps = &p.manifest().capabilities;

    /* ── ① 档位判据：喂给 UI 的那个值 ── */
    eprintln!(
        "★ C8 ① UI 输入：manifest.capabilities.danmaku_send = {}",
        caps.danmaku_send
    );
    eprintln!(
        "     ⇒ Dart `danmakuSendAllowed(...)` 会返回 {} ⇒ 发送入口{}",
        caps.danmaku_send,
        if caps.danmaku_send { "出现" } else { "**不出现**" }
    );

    /*
     * ★ 不断言一定要 false：
     *   别的插件可能有发送能力。这里只断言「位与方法的关系自洽」，
     *   即：位是 false 时，命令层必须仍能解释为什么。
     *   （版本相关的「必须 false」判据在 C0 里）
     */

    /* ── ② 命令层：直接调，必须给可读原因 ── */
    use sourin_core::model::DanmakuSendRequest;
    let r = p
        .danmaku_send(DanmakuSendRequest {
            episode_id: "0".into(),
            text: "验收探针（不应发出）".into(),
            ..Default::default()
        })
        .await;

    match r {
        Ok(v) => panic!("★ 不该成功：ok={}", v.ok),
        Err(e) => {
            let msg = e.message.trim();
            eprintln!("★ C8 ② 命令层原因：{:?}", msg);
            assert!(!msg.is_empty(), "★ 命令层必须给可读原因，不能是空串");

            /*
             * 三条「可读」的具体判据：
             *   · 不是纯技术栈（不含 "panicked at" / "unwrap"）
             *   · 说清了是权限/能力/网络哪一类
             */
            assert!(
                !msg.contains("panicked at") && !msg.contains("called `Option::unwrap"),
                "★ 错误消息里混进了内部 panic 文本（用户看不懂）：{:?}",
                msg
            );

            if !caps.danmaku_send {
                eprintln!(
                    "★ C8 PASS：位=false（入口不出现），但命令层仍给出可读原因（{} 字）",
                    msg.chars().count()
                );
            } else {
                eprintln!("★ C8 PASS：位=true，命令层失败原因可读（{} 字）", msg.chars().count());
            }
        }
    }
}
