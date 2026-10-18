# Agent Note: 判据锁 API 名 —— 产品是对的，门禁错了

Status: implemented

> 同域：本篇是「假红」而非假绿 —— 产品对、门禁错。总原则见
> [2026-10-12-gates-must-be-able-to-fail.md](../process/2026-10-12-gates-must-be-able-to-fail.md)；
> 同批修的另两个实例见
> [2026-10-18-gate-reads-worktree-not-blob.md](./2026-10-18-gate-reads-worktree-not-blob.md)
> 与 [2026-10-18-skipped-test-hides-certain-red.md](./2026-10-18-skipped-test-hides-certain-red.md)。

## Problem

```text
flutter test test/fullscreen_titlebar_test.dart --concurrency=1
  ★ 退出播放器必须走统一出口（否则全屏状态会残留）  [E]
  Expected: <1>   Actual: <0>
```

红的是**门禁**，不是产品。

根因：N-PAUSE（`8e8be90` / `2b5f793`）要把「用户是否想暂停」回传，
于是把出口从 `maybePop()` 升级成带泛型的 `pop<bool>`：

```dart
if (mounted) Navigator.of(context).pop<bool>(_userWantsPause);
```

而原断言锁的是具体 API 名：

```dart
RegExp(r'Navigator\.of\(context\)\.maybePop\(\)').allMatches(codeOnly).length
expect(directPops, 1)
```

实测（剥注释后）：

```text
Navigator.of(context).pop       ⇒ 1 处，且就在 _exitPlayer 内
Navigator.of(context).maybePop  ⇒ 0 处
```

**统一出口完好无损**，只是换了写法。

### 这类门禁最坏的地方

它不是「测错了功能」，而是**把实现细节当成了不变量**。
后果有两个方向：

- 实现合法演进 → 门禁误红，人被逼着改门禁（这次就是）；
- 或者有人为了让它绿，把 API 改回旧写法 → **门禁逆向限制了产品**。

后者更危险，因为「让门禁变绿」永远是更省事的选择。

## Decision

**从「锁 API 名」改成「守安全属性」。**

旧判据把两件事混在了一起：

```text
① 「有且仅有一处 pop」        ← 真正的安全属性
② 「它必须写作 maybePop()」   ← 实现细节（错）
```

新判据把 ① 拆成两条**方向性**断言：

```text
A. `_exitPlayer` **之外** 不许有任何 Navigator pop/maybePop
B. `_exitPlayer` **之内** 必须有且仅有一处
```

**must**：不写「全仓计数 == 1」。

理由：全仓计数只在「恰好一处」时成立。将来若**合法地**多一处
（且已正确还原全屏），全仓计数会误伤；而「别处不许有」才对应真实纪律 ——
**所有退出都必须走这个出口**。

正则同时接受 `maybePop` 与带泛型的 `pop`：

```dart
RegExp(r'Navigator\.of\(context\)\.(?:maybePop\(\)|pop(?:<[^>]*>)?\()')
```

## Alternatives considered

- **把断言改成 `pop<bool>`（跟着实现换字面量）** — 一行就绿，最省事。
  否掉：下次实现再演进又会红，而且这次修复会重复无数次。更根本的是
  它继续把「写法」当不变量，问题只是被推后。
- **删掉这条断言** — 红消失，也不必维护。否掉：这条守的是真实安全属性
  （退出必须走统一出口，否则全屏状态残留）。删掉等于放弃这条纪律。
- **用全仓计数 == 1** — 实现简单，表达「唯一出口」也直观。
  否掉：如上，它把「唯一」钉死在数量上。合法的第二处出口（若它也正确
  还原全屏）会被误判；而纪律的真实含义是「别处不许有」，不是「只能有一处」。
- **改成运行时断言（加一个 debug 计数器，出口被调用时自增）** —
  比静态文本检查更真实。否掉：这条测试是**静态源码断言**，不启动播放器；
  引入运行时计数需要 widget test 或真机，成本与覆盖面不成比例。
- **解析 Dart AST 精确找出 `_exitPlayer` 函数体** — 比正则可靠。
  否掉：为一条断言引入解析器依赖值得商榷；而这里两端锚点
  （函数名与 `Navigator` 调用）都稳定，正则足够。

## Consequences

- **收益**：门禁不再用实现细节限制产品演进。带泛型的 `pop<bool>` 是
  **合法演进**，现在能被正确接受。
- **收益**：判据从「锁一行源码」变成「守两个方向的安全属性」，
  表达的是真实纪律而不是某次写法。这类判据的抗重构能力显著更高。
- **收益**：明确了「别处不许有 pop」才是核心纪律。它比「全仓恰好一处」
  更准确地描述了「所有退出都必须走这个出口」。
- **代价**：两条方向性断言的推理成本高于一条计数断言 ——
  读的人需要理解「内/外」的划分，而计数一看就懂。
- **代价**：正则仍需按函数名 `_exitPlayer` 定位边界。若这个函数被重命名，
  断言会失败（这是**希望**的：重命名统一出口是值得被拦住的事）。
- **已知缺口**：本次只修了 `fullscreen_titlebar_test.dart` 这一条。
  同仓其它「锁 API 名」的判据若存在同样问题，没有全仓排查。
  重访信号：改动某个实现细节后，门禁红而产品行为正常。

## Verification

```text
flutter test test/fullscreen_titlebar_test.dart --concurrency=1
  ⇒ 退出播放器必须走统一出口（否则全屏状态会残留）  [E] 通过
```

改动前同一命令是 `Expected: <1>  Actual: <0>`。

关键证据：实测确认 `Navigator.of(context).pop` **1 处且就在 `_exitPlayer` 内**、
`maybePop` **0 处** —— 也就是说产品侧的「唯一出口」属性一直成立，
红完全来自判据锁错了对象。
