# Agent Note: 被 skip 藏住的「确定会红」—— 过时判据比红更隐蔽

Status: implemented

> 同域：本篇讲「被 skip 藏住的确定会红」。总原则见
> [2026-10-12-gates-must-be-able-to-fail.md](../process/2026-10-12-gates-must-be-able-to-fail.md)；
> 相关实例见
> [2026-10-18-gate-locked-api-name-not-invariant.md](./2026-10-18-gate-locked-api-name-not-invariant.md)
> 与 [2026-10-18-gate-reads-worktree-not-blob.md](./2026-10-18-gate-reads-worktree-not-blob.md)。

## Problem

`test/t118_control_bars_link_test.dart:746` 的断言：

```dart
expect(src.contains('if (!_chromeVisible && !keepForFade) {'), isTrue)
```

与 `t73` / `t57` 完全同一个过时字面量 —— N11（`ddb0794`）已按设计删掉
`keepForFade`。实测 `grep -c` ⇒ **0**，唯一出现处是 `player_page.dart:15391`
的一行**注释**（记录「改前是什么」的历史，不该删）。

### 为什么它一直没被发现

整个文件被 skip（`dart_test.yaml` 的 `native-media` 标签）：

```text
单独跑  ⇒ 00:00 +0 ~1: All tests skipped.        ← 至少有大字提示
全量跑  ⇒ grep "All tests skipped" = 0，只体现为 ~N 计数器 +1
```

**这比「红」更隐蔽**：红会被人看见，skip 不会。
一条永远不执行的断言，在报告里只是一个数字的变化。

实证确认它不是「可能过时」而是**确定过时 + 确定会红**：

```text
--run-skipped --plain-name "⑧"
  Expected: true  Actual: <false>
```

## Decision

照 `t27_w13_chrome_ssot_test.dart:216-228` 的正确范本改成两条：

```dart
// ① 反向断言：不许用 _chromeVisible 决定卸下底栏（否则第二个真源）
// ② 实质断言：只在占据态才卸下
```

**must**：**必须剥注释再断言。**

第一次写这条时忘了剥注释，反向断言命中了 `player_page.dart:15391` 那行
注释 ⇒ **假红**。那行注释记录「改前是什么」，是历史记录，本身不该删。

这是 `AGENTS.md §8` 已经记过的坑（「命中注释」），我自己又踩了一次 ——
说明「写在文档里的坑」对下一次编写仍不构成保护，**只有断言里显式
调用 `stripComments` 才算**。

## Alternatives considered

- **直接删掉这条过时断言** — 最简单，红与假红都没了。否掉：这条断言
  原本守的是「底栏卸下的判据唯一」这个安全属性，删掉等于不再守。
  过时的是**字面量**，不是意图。
- **把字面量更新成新实现里的那行** — 改动最小。否掉：那仍然是
  「锁一行源码文本」，下次重构又会过时 —— 与 `t73`/`t57` 踩的是同一个坑。
  而且它会重新引入「判据有两个真源」的问题，正是这条断言要防的。
- **把 `native-media` 标签的 skip 去掉，让它每次真跑** — 能让问题立刻暴露。
  否掉：那个标签存在有理由（需要真实媒体环境），去掉会让 CI 在不具备
  条件的机器上大面积失败，噪音压过信号。
- **只加反向断言，不管实质断言** — 少写一条。否掉：反向断言只能证明
  「没有走错的路」，证明不了「走对了路」。两条缺一，判据都不完整。
- **不剥注释，把断言范围限定到某个函数体内** — 也能绕开注释命中。
  否掉：定位函数体需要解析源码结构，字符串操作做不到可靠；
  而 `stripComments` 是仓里已有且已被验证的工具。

## Consequences

- **收益**：一条**确定会红但从未执行**的断言被修复。这类缺陷的特点是
  它既不在失败列表里，也不在跳过提示里 —— 只在计数器里。
- **收益**：判据从「锁一行源码文本」改成「守唯一出口安全属性」，
  下次重构不会再过时。
- **收益**：再次确认「必须剥注释」这条纪律的必需性 —— 并且这次是在
  明知有这条纪律的情况下踩的，说明它必须靠代码而不是记忆保证。
- **代价**：`--run-skipped` 才能验证这类被 skip 的测试，常规全量跑
  看不到它。这条测试的日常守门仍然依赖有人记得单跑。
- **已知缺口**：本次只修了 t118。仓里其它被 `native-media` 等标签 skip 的
  测试，可能同样藏着「确定会红」的过时判据。
  重访信号：改某个被删的实现细节后，grep 到旧字面量仍留在测试里。
- **未做**：没有加「skip 数量不得超过 N」之类的门禁。那种阈值门禁很容易
  被一次合法调整打破，然后被调阈值绕过，治不了根。

## Verification

```text
--run-skipped --plain-name "⑧"   ⇒ +1 All tests passed
```

改动前同一命令是 `Expected: true  Actual: <false>`，确认这是真修而不是
把它改成恒绿 —— 反向断言若命中注释会立刻假红，实测加 `stripComments`
之后才通过。
