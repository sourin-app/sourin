# crate 级文件日志直写器 applog::write_file_log（观测黑洞修复·方案 A）

- Status: implemented
- 日期: 2026-10-30
- 任务: b749c8d 真机读数「降级链已触发但文件日志零 [PAN]、resolve warn 不落盘」的修复（lead 批准方案 A 保守版）
- 相关: [../bug-fix/2026-10-30-csp-episode-url-direct-play.md](../bug-fix/2026-10-30-csp-episode-url-direct-play.md)
  （那篇给 resolve 失败加的是 `log::warn!`——本篇查实 log 门面无 sink 后把它换成真落盘的 write_file_log；
  不取代它，脱敏口径沿用）；[../bug-fix/2026-10-30-quark-23018-pick-degrade.md](../bug-fix/2026-10-30-quark-23018-pick-degrade.md)
  （降级链路本身原样，本篇只把它的日志从死掉的 log 门面接到文件直写器）。

## 根因（行号级取证）

```text
本 crate 从未初始化 logger（三处既有审计逐字：streamproxy.rs:76「从来没有初始化 logger」、
streamproxy.rs:2179「log::info! 会被整个丢弃」、state.rs:813「grep … set_logger → 0 处」）
⇒ playback.rs 的 log::warn 与 pan_drive.rs 全部 log::info/warn（含降级 [PAN]）被静默丢弃。
logs\sourin-*.log 实际由三个各自为政的直写器负责（无 FFI log 桥、stdout 不是 sink）：
  · Dart AppLog（lib/core/app_log.dart，[PLAY] 行来源，纯 Dart IO 直写）
  · pan_login.rs:211-248 write_log（历史 [PAN] 行来源，扫码链路）
  · streamproxy.rs:146 write_sp_log_file（[streamproxy] 行）
```

## 改动（lead 批准的最小面）

1. 新建 `src/applog.rs`：`pub fn write_file_log(tag, msg)`——形态逐字复用 pan_login.rs:211-248
   （SOURIN_LOG_FILE 覆盖优先 → in_test_process 早退 → %APPDATA%\app.sourin.player\logs\sourin-<day>.log
   append，失败静默）；行格式与 Dart AppLog 逐字同形（`ts [TAG] msg`，app_log.dart:53-60）。
   `in_test_process` 是与 pan_login.rs:205-208 **重复的副本，待统一**（那是 rust-pan 的模块，本轮不动）；
   测试防护边界与 pan_login 同款：集成测试须显式 SOURIN_LOG_FILE 重定向。
2. `lib.rs` 注册 `pub mod applog;`（一行）。
3. `playback.rs` resolve 失败：`log::warn!` → `applog::write_file_log("PLAY", …)`（tag 对齐 Dart [PLAY] 惯例；
   脱敏口径不变：provider/错误类别/id 前缀 24 字符，不含完整 URL 与 token）。
4. `pan_drive.rs` 降级：`log::warn!` → `applog::write_file_log("PAN", …)`（对齐既有 [PAN] 惯例）——
   顺带修掉「整个降级过程零 [PAN]」的观测黑洞。

## Alternatives

```text
A. 装一个真正的 logger（fern/env_logger + 文件 sink）—— 一处初始化全局生效，
   但动 bootstrap（state.rs）且会改变既有三套直写器的并发行为（重复行/交错），超出授权面，砍。
B. 方案 B（playback 单点内联 8 行复制品）—— 改动更小但降级 [PAN] 黑洞留着，lead 选 A，砍。
C. 共用 pan_login 的 write_log —— 那是 rust-pan 模块且为私有 fn，跨模块改判据超出授权，砍
   （判据以 4 行重复副本落地，注明待统一）。
D. 经 Dart AppLog 桥回写（FFI 反调）—— 依赖 UI 层存活，Rust 侧启动期/无 UI 时丢日志，砍。
```

## 验证结果（门禁 + 注入证红 + 回归）

```text
门禁 rust/sourin_core/tests/file_log_gate.rs（独立新建）:
  cargo test --test file_log_gate --release
    ⇒ test result: ok. 2 passed; 0 failed
    （①行为：SOURIN_LOG_FILE 重定向落盘 + 行格式同 Dart AppLog + 降级链真实触发必留
      [PAN] 降级行；②接线：playback.rs→"PLAY"、pan_drive.rs→"PAN" 源码级断言，
      include_str! 先例 tvbox_aggregate.rs:2720）
注入证红（纪律②，删掉两处 write_file_log 调用）:
  ⇒ test result: FAILED. 0 passed; 2 failed（接线与降级落盘断言全红）
  ⇒ 恢复后复跑 2 passed / 0 failed。
回归: --lib playback ⇒ 4 passed/0 failed；--lib pan_drive ⇒ 39 passed/0 failed；
  --test quark_pick_degrade ⇒ 7 passed/0 failed（降级门禁不受影响）。
真机验证：DLL 重 build 部署由 driver-ops 统一轮，随批末实机复播验证。
```
