# Agent Note: 测试进程不得写用户的真实日志目录

Status: implemented

Independent: 现有测试策略笔记讲的是"哪些用例该跳过/该怎么跑"（
[2026-09-25-native-media-tag-skip-not-exclude.md](2026-09-25-native-media-tag-skip-not-exclude.md)、
[2026-10-14-red-baseline-needs-clean-worktree.md](2026-10-14-red-baseline-needs-clean-worktree.md)、
[2026-10-26-gates-must-run-from-production-entry.md](2026-10-26-gates-must-run-from-production-entry.md)），
本篇管的是**测试进程对用户数据的副作用**（写真实日志目录）——机制与判据都不同，互相不取代。

## Problem

跑测试会往**用户真实数据目录**写日志：

```text
%APPDATA%\app.sourin.player\logs\sourin-2026-10-26.log
当天那份里混进过 3060 行 `[DL] 探针日志` 与单测假地址 `127.0.0.1:1/never-played.mp4`
```

两条后果都比"多几行噪声"严重：

1. **用户在自己的日志里看到根本不存在的播放/下载** —— 会据此报"你们播放器坏了"；
2. 日志是我们**唯一**的取证手段（今天排查某个外部源的播放失败，全程靠 `[streamproxy]` 行）。
   一旦被测试污染，任何一次排查都先要在几万行里分辨"哪些是测试造的"。

## Decision

**两侧都隔离，且判据是"真实日志文件一个字节都没动"（不是"代码看起来对"）。**

**Dart 侧** —— `test/flutter_test_config.dart`（`flutter_test` 的全局钩子，同目录所有用例运行前先执行）：

```text
AppLog.logDir() 优先级：① AppLog.debugLogDirOverride（钩子设到 %TEMP%/sourin-test-logs）
                        ② 环境变量 SOURIN_LOG_DIR（与 Rust 侧 SOURIN_LOG_FILE 同一思路）
                        ③ <dataDir>/logs（生产默认，逐字未变）
```

放在全局钩子里，是为了**一条规则覆盖全部现有/将来用例** —— 否则"新写的测试忘了设隔离"必然复发。
另加 `tearDownAll(AppLog.debugClear)` 清内存缓冲，避免跨用例串行。

**Rust 侧** —— `streamproxy.rs:117 in_test_process()` + `:132` 在**唯一落盘出口**早退：

```text
in_test_process() = cfg!(test) ‖ FLUTTER_TEST=true/1 ‖ DART_TEST ‖ SOURIN_TEST_LOG
优先级：SOURIN_LOG_FILE 显式覆盖（测试想验格式就指到临时文件）> 测试进程不写 > 产品真实路径
```

**关键**：只判 `cfg!(test)` **挡不住** —— DLL 跑在 Dart 测试进程里、按 release 编译，
`cfg!(test)` 是 false。这正是"代码看着对、日志却还在长"的原因。

## Alternatives considered

1. **在产品代码里加 `if (isTest) return;` 分支**。
   最直接，但把"测试"这个概念塞进产品路径，且每加一个写日志点就要记着写一遍。**否决**：
   用注入口/环境变量，产品代码不知道测试存在。
2. **只改 Dart 侧**（`AppLog` 隔离够用了）。
   实测不够：DLL 里的 `sp_log` 仍写真实目录（`[streamproxy]` 行继续出现）。**否决**：两侧都要。
3. **只判 `cfg!(test)`**。
   看起来最"正统"，但在本仓的部署形态下**恒为假**（DLL 是 release 编译，跑在 Dart 测试进程里）。**否决**。
4. **每个测试文件自己 `setUpAll` 里设日志目录**。
   灵活，但"忘了设"是默认状态 ⇒ 一定复发。**否决**：用全局钩子，默认安全。

## Consequences

- 收益：真实 `logs/` 的 `mtime + size + lines` 在跑测试前后**三项全同**（Dart 侧 `t11_panel_probe`、Rust 侧 `streamproxy` 各自实测）；
  排查时"日志里有什么"重新变成可信证据。用户报障时不会再被测试噪声误导。
- 代价：`test/flutter_test_config.dart` 成了**全局单点** —— 它出错会一次性废掉整批用例（今天已发生过一次：
  少一行 `import 'dart:async' show FutureOr;` ⇒ 全量里 `t70` 起一批用例全 `Failed to load`）。
  ⇒ 纪律：**该文件的改动必须跑一次全量才算验过**，单文件绿不算。
- 代价：历史污染仍在用户目录（今天累计 5.7 万行测试噪声）。**不做破坏性清理**（那是用户数据），
  只在发布说明里提示用户可自行清空。

## Testing

- Dart：跑 `test/zz_t11_panel_probe_test.dart` 前后取真实 `logs/` 的 `mtime+size` ⇒ **完全不变**；
  注入（注释掉 `debugLogDirOverride = dir.path`）⇒ `mtime` 变化 + `md5` 变化（**隔离确实在起作用**）；
- Rust：`cargo test --lib streamproxy` 前后四项（mtime/行数/大小/md5）**全同**；
  注入（删掉 `in_test_process()` 早退）⇒ 真实日志 **+72 行**，新增行正是测试夹具的
  `127.0.0.1:50427/t.mp4` 与 `127.0.0.1:1/never-played.mp4`；
- 另有一条自检：`AppLog` 在"未设隔离且确实在测试进程里"时打一条 WARN（不抛、不改行为）。
  第一版判据（`FLUTTER_TEST` 存在 ‖ `APPDATA` 不存在）**实测恒为假**（flutter test 进程没有 `FLUTTER_TEST`、
  Windows 上 `APPDATA` 又存在）⇒ 改成看 `Platform.executable` 才真的会喊。**自检本身也必须被验证会响**。