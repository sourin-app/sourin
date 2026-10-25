# Agent Note: 失败必须可查询（`restore-failures.json` 的读取方）

Status: implemented

## Problem

csp 源重启恢复失败时，实现做了三件事：跳过这一条源、`log::warn` 一次、把原因写进
`<数据目录>/restore-failures.json`。**但全仓没有任何 FFI 命令 / Dart API / 界面读它** ——
引用点只有写方（`state.rs`）、定义与单测（`persist.rs`）。

用户视角于是这样：某个源重启后消失，日志里一句 warn，磁盘上一个没人看的文件，
**界面上什么都不说**。这与"导入成功、重启没了"是同一类问题的最后一段：
前三次修的是"别虚报"（`persisted: false` → `notPersisted` → 面板警示 → 订阅更新同一套），
这一次是"别沉默"。

同一族还有两个症状一起修掉了：
- `state.rs` 的 `if !restore_failures.is_empty()` 守卫让**旧报告永不到期**
  （病修好后的下一次启动零失败 ⇒ 不会走到写盘 ⇒ 旧的陈旧报告一直留在盘上）。
- 列表页/对话框都没有任何"上次启动有源没恢复"的入口。

## Decision

**凡是被记录下来的失败，必须有一条可查询的读路径，并在用户能看到的地方出现。**

1. **数据层**：`persist::restore_failures_json(dir)` 返回 `{"count": N, "items": [...]}`，
   `count` 与 `items` **同源**（避免"写 2 条却报 0 条"这种自相矛盾读数）；空时给 `[]` 而不是 null。
2. **命令层**：`ffi.rs` 新增只读命令 `restore_failures`（`with_state` 同步、纯本地、不占异步通道）。
   该文件含 79 个真实 NUL 字节 ⇒ 必须用 NUL 容错脚本做字节级编辑，`grep` 会整文件跳过。
3. **Dart 层**：`SourinApi.restoreFailures()` + **纯函数** `parseRestoreFailures(Map)`
   （拆出来是为了可单测 —— 测试环境没有 dll，`callAsync` 必失败）+ `RestoreFailure{id, api, reason, displayName}`；
   `reason` **原样透出、不改写**（它来自 `csp::unimplemented_reason` 这个唯一来源）。
4. **界面层**：`TvboxRestoreFailuresView` —— 有清单才画（标题「上次启动没能恢复 N 个源」+ 逐条「源名：原因」
   + 超 5 条给「还有 N 个没列出」+ 一句下一步）；**空清单 `SizedBox.shrink()`**（读不到也不假告警）。
   挂在对话框与更新结果面板**共用**的 `_resultBox` 头部 ⇒ 一处插入两处生效，将来加第三个视图不会漏。
5. **顺手修**：`state.rs` 去掉 `if !is_empty()` 守卫，改为无条件写（空 vec 自然走"删文件"）。

## Alternatives considered

1. **把失败清单并进 `list_tvbox_sources` 的返回值**（不新增命令）。
   省一条命令，但会让"列源"这个高频只读接口背上一个低频诊断字段，且 Dart 侧要为它改解析与缓存语义；
   独立命令职责更清。**否决**。
2. **只写日志、不加界面**。
   这正是要修的形状：日志是给开发者看的，用户不会去看 `<数据目录>` 里的 json。**否决**。
3. **自动重试失败的源**。
   诱人但危险：未实现的 csp 类重试一万次也是失败，且会掩盖真正需要"换版本"的信息。
   本轮只做"能看见原因"，**不做自动重试**（明确写进边界）。
4. **失败清单留在内存里、不落盘**。
   那"上次启动"的信息在本次启动就丢了，与需求（跨启动可见）正好相反。**否决**。

## Consequences

- 收益：第 19 项的"四处处处如实"闭环 —— 未实现/未落盘/未恢复/原因可查，四段都有读路径与界面。
- 代价：多一条 FFI 命令与一个 Dart 模型；`ffi.rs` 的字节级编辑必须继续走 NUL 容错脚本（已在注释里写明）。
- 残留（如实登记）：提示目前挂在「源对话框」与「更新结果面板」；**源列表页头部那一行还没接**
  （`settings_page.dart` 不在该批写范围，组件已导出、插一行即可）。用户当前路径是：设置 → TVBox 源 → 任意源。

## Relations

- 同族（互链）：[../bug-fix/2026-10-25-identity-must-carry-discriminator.md](../bug-fix/2026-10-25-identity-must-carry-discriminator.md)
  —— 那篇讲"判据的输出不许超出输入"，本篇是它的下一步：**已经知道的事必须能被问到**。
  两篇一起构成第 19 项"四处处处如实"的两半（别虚报 / 别沉默）。
- 部分重叠：[../architecture/2026-10-24-source-override-layer-after-call-js.md](../../../proposed/architecture/2026-10-24-source-override-layer-after-call-js.md)
  —— 那篇是覆盖层"只写 overrides/ 不动原件"的边界，与本篇的只读命令是同一套"读写路径要能被审计"的思路。

## Testing

- Rust：`cargo test --lib --release` **623 passed / 14 ignored**；五份 DLL 同哈希。
- Dart：`zz_t1043_restore_failures_test` **+6**（①命令已接线（源码判据，无 dll 跑不到）②解析正常/垃圾数据
  ③渲染有清单点名 ④空清单零尺寸 ⑤超 5 条不刷屏 ⑥用户文案纪律）；与三道文案门禁合跑 **30 passed / 1 skipped**。
- 注入：①命令名改成 `restore_failures_disabled`（字节级，NUL 79→79）⇒ `1 failed / EXIT=1`，恢复后 `cmp` 字节一致；
  ②面板 `if (_rows.isEmpty)` → `if (true)` ⇒ `2 failed / EXIT=1`，恢复后 `diff -q` 字节一致。
- 同批第 04 项的静态门禁（`zz_t66_scroll_behavior_gate` 新增"`copyWith` 里不许 `physics:`/`platform:`"）：
  注入 `physics: ClampingScrollPhysics()` ⇒ 静态 `+6 -1`、行为 `+4 -1` 双红，恢复后 `+7`/`+5` 全绿。
