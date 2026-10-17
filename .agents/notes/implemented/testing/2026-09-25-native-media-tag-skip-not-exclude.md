# Agent Note: native-media 标签用 tags: {skip:} 而不是 exclude_tags:

Status: implemented

## Problem

依赖真 libmpv 的测试会让 `flutter_tester.exe` **原生崩溃**
（访问违例 c0000005，证据链见 `dart_test.yaml` 顶部）。默认必须跳过它们，
但需要时又要能放行跑。

## Decision

依赖真 libmpv 的测试标 `native-media`，在 `dart_test.yaml` 里用 `skip:` 默认跳过；
需要时 `--run-skipped --tags native-media` 放行。

## Alternatives considered

- **`exclude_tags:`** —— 它最强的论据是语义直白：「排除这些标签」。
  否决理由：排除发生在**选择之前** ⇒ 排除了就无法再用 `--tags` 放行
  （实测三选一，两条路径都 exit=79）。这是机制层面的死路，不是配置写法问题。

- **修掉崩溃本身** —— 它最强的论据是根治。否决理由：根因在第三方 `libmpv-2.dll`，
  改不了源码。

## Consequences

- **收益**：默认批次不会撞崩溃，同时保留了一条「要跑就显式放行」的路径。
- **代价与已知上限**：这批测试默认不在任何一次常规跑里执行 ⇒ 它们的红/绿平时没人看，
  回归可能潜伏。`skip:` 也让「跳过」与「失败」在输出里不易区分。
- **重访条件**：上游修掉崩溃，或 Flutter 的 `flutter_tester` 不再丢弃崩溃信息。
