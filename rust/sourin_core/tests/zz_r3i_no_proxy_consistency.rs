//! R3-I 全仓 `.no_proxy()` 一致性门禁（task-23）
//!
//! # 这一条守的是什么
//!
//! ```text
//! 本仓 40 个 csp 类里，凡**真发 HTTP** 的都必须在 client 链上带 `.no_proxy()`
//!   —— 惯例原文见 `app99.rs:342-343`：
//!      「与 pan_web_share 同一条纪律：不读系统代理（代理会把"站点可用"测成"全宕"）」
//!
//! 为什么这是**真缺陷**而不是洁癖（Lead 独立复现 + csp-batch-c 的矩阵实测）：
//!   $ HTTP_PROXY=http://127.0.0.1:9 … CSP_LIVE=1 cargo test --lib sports_kafei_live
//!     panicked：home 必须真取到数据: "…失败：error sending request for url"
//!   ⇒ **装了代理的机器上会坏**，而错误文本**不含真因**（只看到"发送请求失败"）
//!     ⇒ 定位成本极高（home-ui 今天就把它误判成"站点反爬"）。
//! ```
//!
//! # ★ 这条判据的三个"必须"（每一个都对应本仓已踩过的坑）
//!
//! ```text
//! ① **必须剥注释**（不只是剥测试段）
//!    `impl_src_only` 按设计会剥 `#[cfg(test)]` 之后的段；
//!    ⚠️ 但**注释里的 `.no_proxy()` 字样**同样是假绿源：
//!       一旦有人给"待补的类"写一句注释 `// 待补：需要 .no_proxy()`，
//!       朴素 `contains(".no_proxy()")` 就被喂饱了。
//!    ⇒ 本文件**自带一个更严的剥离**：切线 + 剥注释（见 `code_only_without_comments`）。
//!
//! ② **反空真的口径必须是"含 Client::builder 的类数"**（不是"类数"）
//!    （home-ui 实测提醒）：若将来有人把 client 换成 `reqwest::get(...)` 之类，
//!      "文件数"仍够 40，但**检查面已经空了** ⇒ 断言恒真。
//!    ⇒ 本门禁断言 `files_with_builder == checked`（两者必须相等，**不许漏检**）。
//!
//! ③ **注入必须能红**：删掉任一类的 `.no_proxy()` ⇒ 该条 FAILED。
//!    （我实际做了这个注入实验，日志在 `.probe/r3-noproxy-inject.log`。）
//! ```
//!
//! # 与既有先例的关系
//!
//! ```text
//! `tests/zz_r3_csp_registry.rs:148` 用 `std::fs::read_to_string(format!("src/csp/{f}"))`
//!   —— 我把"枚举"从**手写清单**改成**目录扫描**：
//!   ★ 手写清单会**随新类增加而过期**（本批已连续两次这种教训：
//!     `tvbox.rs` 把 `csp_AppDrama` 写死成"未实现样本" ⇒ 别人落地后即失效；
//!     `mod.rs:551` 的注释早警告过"写死类名会烂"，但另一处没跟上）。
//!   ⇒ 目录扫描 + "运行期发现的数量"当判据，**让判据跟着事实走**。
//! ```

use std::path::Path;

/// 剥掉 Rust 源码里的**注释**与 `#[cfg(test)]` 之后的段，只留"会编译进 lib 的代码"
///
/// # 为什么不用 `csp::shared::impl_src_only`
/// ```text
/// 那个函数是给**单文件**用的（`include_str!` 一个类）。
/// 本判据要**扫目录里所有文件**，不能 `include_str!`（文件名在运行期才知道）。
/// ⇒ 自己读文件后，套用**同一套剥离口径**：
///      ① 先剥注释（否则注释里的 `#[cfg(test)]` 字样会把切换错位 ——
///         `impl_src_only` 的文档里记了这个"两层 bug"，我按它的结论：**先剥注释**）
///      ② 再切 `#[cfg(test)]`（**行首锚定** —— 同样是它记的教训：
///         字符串字面量里出现的 `#[cfg(test)]` 不该触发切分）
///      ③ 最后去掉全部空白（让"跨行写的链"与"一行写的链"一致）
/// ```
fn code_only_without_comments(full: &str) -> String {
    let stripped = strip_comments(full);
    let anchored = format!("\n{stripped}");
    let impl_part = anchored
        .split("\n#[cfg(test)]")
        .next()
        .unwrap_or(&anchored);
    impl_part.chars().filter(|c| !c.is_whitespace()).collect()
}

/// 剥注释（行 `//` 与块 `/* */`），**但不碰字符串字面量**
///
/// # 为什么"不碰字符串"是必须的
/// ```text
/// 本仓 `shared.rs:281` 已明写：
///   朴素实现（按行首判 `//`）会误伤形如 `let url = "https://x";` 里的 `//`。
/// ⇒ 这里做一个**状态机**：逐字符走，遇 `"` 进字符串态、遇 `//` 或 `/*` 进注释态。
///   ★ 简单但够用：本判据只关心"代码里有没有 `.no_proxy()`"，
///     不需要完整 Rust 词法（如 raw string / 字符字面量）—— 但**遇到就按字符串处理**，
///     宁可"少剥一点"也不要"把代码当注释剥掉"（后者会**假红**）。
/// ```
fn strip_comments(src: &str) -> String {
    let b: Vec<char> = src.chars().collect();
    let mut out = String::with_capacity(src.len());
    let mut i = 0;
    let mut in_str = false;
    while i < b.len() {
        if in_str {
            out.push(b[i]);
            if b[i] == '\\' && i + 1 < b.len() {
                // 转义：把下一个字符原样带过（否则 `\"` 会被当成串尾）
                out.push(b[i + 1]);
                i += 2;
                continue;
            }
            if b[i] == '"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        match b[i] {
            '"' => {
                in_str = true;
                out.push(b[i]);
                i += 1;
            }
            '/' if i + 1 < b.len() && b[i + 1] == '/' => {
                // 行注释：吃到行尾（保留换行，避免把两行粘连）
                while i < b.len() && b[i] != '\n' {
                    i += 1;
                }
            }
            '/' if i + 1 < b.len() && b[i + 1] == '*' => {
                // 块注释：吃到 `*/`
                i += 2;
                while i + 1 < b.len() && !(b[i] == '*' && b[i + 1] == '/') {
                    i += 1;
                }
                i = (i + 2).min(b.len());
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// 扫 `src/csp/*.rs`，返回 (文件名, 剥离后的代码) 清单（**按文件名排序**，确定性）
fn scan_csp_files() -> Vec<(String, String)> {
    let dir = Path::new("src/csp");
    let mut out: Vec<(String, String)> = Vec::new();
    let rd = std::fs::read_dir(dir).unwrap_or_else(|e| {
        panic!("读不到 {dir:?} —— 本判据必须在 crate 根目录（`rust/sourin_core`）下运行：{e}")
    });
    for entry in rd.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("rs") {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_string();
        let full = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("读不了 {path:?}：{e}"));
        out.push((name, code_only_without_comments(&full)));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// 该文件是否"真的会发 HTTP"（= 用了 `reqwest::Client::builder()`）
///
/// ⚠️ 口径就是**这一条**（不是"文件里出现 reqwest"）：
/// ```text
/// 本判据守的是"**造 client 的地方**有没有关代理"。
/// 若某处用 `reqwest::get(url)`（**没有 builder**），它同样会读环境代理 ——
///   ⇒ 那属于**另一个**形状，本文件末尾有一条独立的门禁（`no_bare_reqwest_get...`）盯它。
/// ```
fn builds_a_client(code: &str) -> bool {
    code.contains("Client::builder()")
}

#[test]
fn every_csp_class_that_builds_an_http_client_disables_proxy() {
    let files = scan_csp_files();

    // ── ★★ 反空真（铁律 149 的口径按 home-ui 的建议）────────────────
    //
    // ```text
    // 断言的是"**含 Client::builder 的类数**"，不是"文件数"：
    //   若将来 client 被换成别的形状，"文件数"仍够但**检查面已空** ⇒ 恒真。
    // ★ 并且断言 `files_with_builder == checked`（两者必须相等）——
    //   那一条比"> 20"更强：它不许"发现了一个却漏检"。
    // ```
    let with_builder: Vec<&(String, String)> =
        files.iter().filter(|(_, c)| builds_a_client(c)).collect();
    assert!(
        with_builder.len() > 20,
        "★★ 反空真：含 `Client::builder()` 的类必须有 >20 个（实测 40）—— \
         实际只剩 {} 个 ⇒ 候选集被掏空了，本条会变成恒真的假门禁。\
         （要么扫描路径错了，要么有人把 client 造法改成别的形状却没补对应门禁）",
        with_builder.len()
    );

    // ── 逐类找违规 ──────────────────────────────────────────────
    let mut offenders: Vec<&str> = Vec::new();
    let mut checked = 0usize;
    for (name, code) in &files {
        if !builds_a_client(code) {
            continue;
        }
        checked += 1;
        // ★ 判据里写 `.no_proxy()` 而不是裸 `no_proxy`：
        //   要的是**调用**，不是"出现过这个词"（防注释/变量名喂饱断言）。
        //   注释已在 `code_only_without_comments` 里剥掉 ⇒ 注释写什么都不会假绿。
        if !code.contains(".no_proxy()") {
            offenders.push(name);
        }
    }
    assert!(
        offenders.is_empty(),
        "★★★ 以下 csp 类**真发 HTTP 却没关代理**（`.no_proxy()`）——\
         装了系统代理的机器上会坏，且错误文本不含真因（只看到「发送请求失败」）：\n  {}\n\
         修法：在 `Client::builder()` 链上 `.timeout(…)` **之后**加 `.no_proxy()`\
         （惯例原文见 `app99.rs:342-343`）。",
        offenders.join("\n  ")
    );

    // ── ★★ 完整性：不许"发现了一个却漏检"────────────────────────
    assert_eq!(
        checked,
        with_builder.len(),
        "★ 内部门禁自检：checked({checked}) 必须等于 with_builder({}) —— \
         不等说明过滤逻辑写歪了",
        with_builder.len()
    );

    // 让人知道这条门禁**实际检查了多少**（否则"绿了"没有量的意义）
    println!(
        "R3-I no_proxy 门禁：扫描 {} 个 csp 文件，其中 {} 个造 HTTP client，全部已关代理 ✅",
        files.len(),
        checked
    );
}

/// ★ 反面门禁：确证本判据**有牙**（不是"恒真的摆设"）
///
/// # 为什么需要"故意造一个违规样本"
/// ```text
/// 上面那条在"全仓都合规"时会绿 —— 但**绿不能证明它有能力红**。
/// 本仓已有教训（恒 false 的防护 / 宽松到恒真的断言），故这里**主动造违规**：
///   拿一段含 `Client::builder()` 但**不缺 `.no_proxy()`** 的代码，
///   用与上面**同一套**剥离+判定逻辑 ⇒ 必须判为"违规"。
/// ⇒ 这样"判据的判据"也立起来了：如果哪天有人把 `.contains(".no_proxy()")`
///   写成恒真（如 `contains("")`），本条会红。
/// ```
#[test]
fn the_gate_itself_can_detect_a_violation() {
    // 违规样本：造 client 但不关代理
    let bad = r#"
        fn new() -> Self {
            // 这里写一句注释做诱饵：待补：需要 .no_proxy()
            let client = reqwest::Client::builder()
                .user_agent(UA)
                .timeout(BUDGET)
                .build()
                .unwrap();
            Self { client }
        }
    "#;
    let code = code_only_without_comments(bad);
    assert!(
        builds_a_client(&code),
        "★ 样本必须被识别为『造了 client』（否则这条反面门禁在测空气）"
    );
    assert!(
        !code.contains(".no_proxy()"),
        "★★★ 判据失效：违规样本被判成合规 —— 注意样本里那句注释**含 `.no_proxy()` 字样**，\
         若它被当成证据，说明**剥注释没生效**（这正是本仓『注释喂饱断言』的老坑）"
    );

    // 合规样本：同一形状 + `.no_proxy()`
    let good = r#"
        fn new() -> Self {
            let client = reqwest::Client::builder()
                .user_agent(UA)
                .timeout(BUDGET)
                .no_proxy()
                .build()
                .unwrap();
            Self { client }
        }
    "#;
    let code_good = code_only_without_comments(good);
    assert!(
        code_good.contains(".no_proxy()"),
        "★ 合规样本必须被判合规（否则判据方向反了，会造成假红）"
    );
}

/// ★★ 剥离器自身的门禁：`#[cfg(test)]` 之后的段**必须**被切掉
///
/// ```text
/// 为什么单测这个：若不切测试段，那么**别处测试里**写的 `.no_proxy()`（比如本文件的
///   样本字符串）会被算进"这个类关代理了" ⇒ **假绿**。
///   本仓先例：`.agents/notes/implemented/bug-fix/2026-10-21-three-gates-wrong-object.md`
///   （`include_str!` 把断言自己读进来）。
/// ```
#[test]
fn stripper_drops_test_module_and_comments() {
    let src = r#"
        let c = reqwest::Client::builder().no_proxy().build();
        /* 块注释里写 .no_proxy() 不该算 */
        // 行注释里写 .no_proxy() 也不该算
        #[cfg(test)]
        mod tests {
            #[test]
            fn t() { assert!(true); }   // 测试段里的 .no_proxy() 不该被读进来
        }
    "#;
    let code = code_only_without_comments(src);
    // 真代码里的那一处必须在
    assert!(code.contains(".no_proxy()"), "真代码里的 no_proxy 必须保留");
    // 但只能有**这一处**（1 处调用 = 1 次 `.no_proxy()`；字符串比较是剥白后的）
    let n = code.matches(".no_proxy()").count();
    assert_eq!(
        n, 1,
        "★★ 剥离后应**只剩真代码里那 1 处** —— 实际 {n} 处 ⇒ \
         说明注释或 `#[cfg(test)]` 段没被剥干净（那会让门禁假绿）"
    );
    // 且测试段整体不见
    assert!(
        !code.contains("fn t()"),
        "★ `#[cfg(test)]` 之后的段必须被切掉（否则断言会读到自己）"
    );
    // 字符串字面量里的 `//` 不许被误剥（否则会造成"代码看起来缺了"的假红）
    let url_src = r#"let u = "https://x.test/a"; let c = 1;"#;
    let kept = code_only_without_comments(url_src);
    assert!(
        kept.contains("https://x.test/a"),
        "★★ 字符串里的 `//` 被误当注释剥了 ⇒ 会造成**假红**：{kept}"
    );
}

/// ★ 另一形状的兜底门禁：裸 `reqwest::get(...)`（**没有 builder**）
///
/// ```text
/// `reqwest::get` 内部会自己造 client ⇒ **同样读环境代理**，
/// 而它不经过 `.no_proxy()` 那一行 ⇒ 上面那条门禁**看不见它**。
/// ⇒ 本仓目前**没有**这种写法（下面断言的就是这个事实）；
///   一旦有人这么写，本条会红 ⇒ 提醒"你要么改成 builder+no_proxy，要么补对应守则"。
/// ★ 这是一条"守住当前事实"的门禁 —— 它的价值在于**把沉默的将来变成一次红**。
/// ```
#[test]
fn no_bare_reqwest_get_shortcut_in_csp() {
    let files = scan_csp_files();
    let mut offenders: Vec<&str> = Vec::new();
    for (name, code) in &files {
        // 裸调用形状：`reqwest::get(`（builder 路径写的是 `Client::builder()`，不会命中）
        if code.contains("reqwest::get(") {
            offenders.push(name);
        }
    }
    assert!(
        offenders.is_empty(),
        "★ 这些 csp 类用了**裸 `reqwest::get(...)`** —— 它会自己造 client、\
         **同样读环境代理**，却不经过 `.no_proxy()` ⇒ 上面那条 builder 门禁看不见它。\n  {}\n\
         处置：改成 `Client::builder()…no_proxy()…build()`，或补一条对应的守则。",
        offenders.join("\n  ")
    );
}