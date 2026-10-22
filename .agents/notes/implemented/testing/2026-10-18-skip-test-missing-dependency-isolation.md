# Agent Note: 测试装置缺依赖隔离 —— 有 DLL 就红 4 条

Status: implemented

> 同域：[2026-10-18-skipped-test-hides-certain-red.md](./2026-10-18-skipped-test-hides-certain-red.md)
> 那篇讲「被 skip 的测试会让过时断言永远暴露不出来」；
> 本篇是它的**反面做法**：同样是「测试环境问题」，但正确处置是
> **注入依赖让它能跑**，而不是打上 `native-media` 标签跳过去。

## Problem

`skip_pair_grouping_test` 在本仓根目录存在 `libmpv-2.dll` / `sourin_core.dll` 时
**稳定红 4 条**；把 DLL 移走就全绿。

六步二分实验（同一份代码，只改环境）：

```text
基线 4fda18c（无 DLL）      +10 绿
HEAD（无 DLL）              +10 绿
HEAD + 两个 DLL             +6 -4 红
HEAD + 只 libmpv-2.dll      +6 -4 红
HEAD + 只 sourin_core.dll   +6 -4 红
HEAD 去掉两个 DLL           +10 绿
```

⇒ 只要任一 DLL 存在就红，与代码版本无关。

## Decision

用仓库**已有的**注入点隔离依赖：

```dart
SourinApi.debugSkipMarkerFetcher = (provider, id) async => null;
addTearDown(() => SourinApi.debugSkipMarkerFetcher = null);
```

### 为什么这是「测试装置缺陷」而不是「环境偶发」

```text
sourin_api.dart:1228-1232 的注释原话：
  「★ 它让门禁能在**不加载 libmpv** 的前提下驱动真实的 `_loadSkipMarker()`
    竞态路径（否则只能打 `native-media` 标签、在 CI 里被默认跳过）」

⇒ 这个注入点**就是为这个场景存在的**。测试没用它才是缺陷 ——
  在任何有 DLL 的机器/CI 上都会红，不是「偶发」。
```

### 根因链（逐层实测）

```text
① 弹窗在树上（SkipMarkerDialog count = 1），但内容为 0
   （Text count = 1，唯一文本是 "open"）
② ★ 零异常（takeException = null / FlutterError count = 0）
   ⇒ 不是崩了，是走了 `_loading == true` 那条**正常分支**
③ skip_marker_dialog.dart:1969  _loading ? 转圈 : 正文
④ _loading 由 _loadExisting() 的 await getSkipMarker(...) 解锁
⑤ 该调用走真实 FFI；有 sourin_core.dll 时在 flutter_test 里**挂住不返回**
⑥ 注入一行 fetcher ⇒ Text 从 1 变 21，四行全回来
```

## Alternatives considered

- **给测试打 `native-media` 标签，让它默认跳过** —— 它最强的论据是
  「需要原生库的测试本来就该跳过」，与仓库既有约定一致。
  否决理由：本仓已实证过被 skip 的测试会让**过时断言永远暴露不出来**
  （`t118:746` 那条躺在 skip 里很久）。而且这 4 条守的是「四行在视口内」
  「行高没变大」这类纯布局契约，**根本不需要原生库**。

- **把 DLL 从仓库根目录移走** —— 它最强的论据是一行 `mv` 解决，最省事。
  否决理由：DLL 是产品运行所必需的，移走就跑不了产品。
  而且 CI 上也可能有它们 ⇒ 治标不治本。

- **给 `_loadExisting()` 加超时（改产品代码）** —— 它最强的论据是
  「这才是真正的健壮性修复」，顺带让测试不挂。
  否决理由：这是**两个不同的问题**。测试装置缺陷应当用注入点解决
  （快、零风险）；产品健壮性缺口（无超时）是另一个真实缺陷，
  单独修（本轮已另开一项做，见 commit `2460801`）。

- **放宽那 4 条断言（比如改成「≥1 行」）** —— 它最强的论据是让测试变绿。
  否决理由：本仓 §4 明文禁止「为变绿而放宽断言」。

## Consequences

- **收益**：这 4 条在**任何**机器上都稳定（有 DLL / 无 DLL 都一样）；
  生产路径逐字不变（fake 默认 null）。
- **代价**：测试里多了一行注入 + `addTearDown`。新读者需要知道
  「这个 fetcher 是测试专用」——已由 `@visibleForTesting` 标注。
- **已知上限**：注入把**核心层传输**换掉了，所以这 4 条**不再覆盖真实 FFI 路径**。
  但它们的断言本来就是纯布局契约（四行在视口内 / 行高没变），
  不依赖 FFI ⇒ 覆盖未受损。
- **重访条件**：若将来要验证「真 FFI 下读跳过点的行为」，
  应另写一个 `native-media` 标签的测试，而不是复用这个。
