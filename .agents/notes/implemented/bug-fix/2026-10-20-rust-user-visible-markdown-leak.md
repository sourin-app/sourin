# Agent Note: Rust 侧用户可见文案的 markdown 星号（含新增 Rust 段门禁）

Status: implemented

## Problem

全仓没有 markdown 渲染器：Rust 核心交给 FFI、再由 Dart `Text` 画出来的字符串，
里面的 `**粗体**` **原样显示成星号**。Dart 侧早有一条门禁
（`test/zz_t66_markdown_audit_test.dart` 的「产品路径用户可见 `**` 必须 = 0」），
但它只扫 `lib/**/*.dart`，**一个字都扫不到 Rust**。

实测漏网的一处：

```text
rust/sourin_core/src/commands_backup.rs 导出提示
  未设置导出用的口令 ⇒ 这个包里**不含登录态**（其它数据都在）。
```

这句话的去向是 `BackupExportResult.credentialsNote` ⇒
`lib/ui/widgets/backup_panel.dart` 把它直接交给 `Text` 显示 ⇒
用户看到的是「包里**不含登录态**」。它属于「不设口令就不含凭据」这条安全提示，
星号既降低了可读性，也让人以为是格式没渲染。

## Decision

两件事，一起做：

1. **改文案**：`**不含登录态**` → `「不含登录态」`（与 Dart 侧同一条先例：
   中文引号，不用 `Text.rich`，不给单句话引入富文本渲染）。
2. **把门禁补到 Rust 段**：新建 `test/_support/rust_string_literals.dart`
   （唯一的 Rust 字面量提取器）+ `test/zz_t66_rust_markdown_gate_test.dart`
   （门禁本体）。判据与 Dart 侧同构：

   ```text
   只算字符串字面量（注释不算）
   用户可见桶 —— 必须 0 条（普通字面量，且不是日志宏的参数）
   日志桶     —— 只打印（log::info! / println! 等）
   嵌入代码桶 —— 只打印（多行原始字符串 r#"…"#：SQL DDL 与内嵌 JS，
                里面的 `--` / `/* */` 是被嵌入语言的注释，永远到不了界面）
   #[cfg(test)] 块整块跳过（夹具的失败信息里故意写 `**`）
   ```

   判别式复用 `test/_support/markdown_bold.dart`（铁律 170：同一纪律只有一个实现），
   所以脱敏掩码 `****` / `abcd****` / `***` 不会被误判成粗体。

## 为什么不复用 `_support/strip_comments.dart`

它是**为 Dart 写的**状态机，不认 Rust 的三种写法：字符字面量 `'"'`
（里面的双引号会被当成字符串开始，把后面整段代码吞进去）、
原始字符串 `r#"…"#`（内部无转义，闭合边界由 `#` 个数决定）、
生命周期标记 `'a`（与字符字面量同形但没有闭合引号）。

实测代价：用它扫 `plugins/mod.rs` 会产出 63 条假命中，全是跨几十行的注释碎片。
⇒ 宁可新写一个**只认 Rust** 的提取器，也不把 Dart 那个改成两头兼顾
（那会让 19 个文件的静态断言一起承担回归风险）。

## 防空转

「用户可见 0 条」这条断言最容易退化成恒绿 —— 扫描器一坏，它自动成立。
所以门禁里有两层自检，都不依赖仓库现状：

- **合成样本自检**（5 组）：普通文案 / 日志宏 / 多行原始字符串 / 字符字面量 `'"'` /
  `#[cfg(test)]` 块，任何一组判错就地变红；
- **仓库现状门槛**：`.rs` 文件数 ≥ 25、取出的字面量 ≥ 2000 条
  （实测 32 个文件 / 7189 条），外加一条**回归钉**：那句导出提示里不许再出现粗体。

## 与既有笔记的关系

文案写法本身早有约定：
[../simplification/2026-10-19-emphasis-uses-chinese-quotes-not-markdown.md](../simplification/2026-10-19-emphasis-uses-chinese-quotes-not-markdown.md)
（「界面强调一律用中文引号「」，不用 markdown `**`」）。

本篇**不取代它**，只是同一条约定的两件后续：
把那句约定落到 **Rust 段**（它当初只覆盖 Dart 侧文案），
并把「扫不到 Rust」这个缺口补成门禁（口径抄
[../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)
的「唯一判别式」纪律）。

## Alternatives considered

- **改共享的 `strip_comments.dart` 让它也认 Rust**：会把 19 个 Dart 静态断言
  一起拖进回归面，且两种语言的字符串语法差异会逼出一个「两头不讨好」的状态机。否决。
- **只修文案、不建门禁**：同一个洞下次还会被踩（Dart 侧那次就是靠门禁才停住的）。
  而且这次是**跨语言**的洞，Dart 门禁永远看不见。否决。
- **对三处嵌入代码（SQL DDL / 内嵌 JS）一并把星号改掉**：它们到不了界面，
  改了只是噪音，还会让「嵌入代码桶」失去样本。改为**打印**而非判红。否决。
- **把日志桶也算红**：`plugins/mod.rs` 那条 `log::info!` 里的星号只进日志文件，
  算红会让门禁从第一天起就有 1 条永远修不完的红。与 Dart 侧「日志桶只打印」对齐。

## Consequences

- Rust 段任何**新**的用户可见文案再写 `**…**`，`flutter test` 立刻红。
- 三处嵌入代码与一条日志里的星号仍然保留，门禁每次都会**打印**它们
  （`RUSTRGATE|嵌入代码（非红）…`），所以它们不会被忘掉，也不会被判成缺陷。
- 代价：门禁要跑一次全量 Rust 源码扫描（32 个文件 / 7189 条字面量），
  单测耗时约 18 秒（大头上在逐字扫描与正则上）。
- 若将来 Rust 侧出现「多行普通字符串承载用户文案」，它会被判成「用户可见」并可能变红
  —— 那时应把「嵌入代码」的判据从「多行原始字符串」收紧到「含被嵌入语言注释标记」，
  而不是把整类张冠李戴。
