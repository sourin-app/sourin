# Agent Note: 逐行自审揪出的三处「接线断开」—— 投屏日志、退出重入、空感知写法

Status: implemented

## Problem

第 66 轮收尾做逐行自审（Owner 的 PR 前置条件之一），在**已经全量测试全绿**的
HEAD 上又找出三处「代码在，但那条路径永远不会按预期执行」的缺陷。
三者症状不同，根因是同一类：**写下了意图，但没接上让它生效的那一段**。

```text
① cast_button.dart 的排障日志 `widget.onLog?.call(...)`
   —— 生产环境 onLog 恒为 null，那行从未执行
② player_page.dart 的 `_exitPlayer()` 无防重入
   —— 中段 await 16.6ms 的窗口里可被再次进入 ⇒ 双 pop
③ sourin_api.dart 三处 `jmap(r)?['x']`
   —— jmap() 返回非空，`?[` 与 `[` 等价，摆出"能容忍 null"的假姿态
```

## Decision

### ① 给生产唯一用点补上 `onLog`

`CastButton` 的提示路径是「先打日志、再弹 toast」：

```dart
widget.onLog?.call('[投屏] $msg');
showAppToast(context, msg);
```

全仓 `CastButton` 只有两处实例化：`lib/probe_cast.dart`（探针，不传）与
`lib/ui/player_page.dart`（**生产唯一用点，原来也没传**）。
⇒ 生产环境 `onLog` 恒为 null。

后果不是「少一条日志」，而是**两个兜底同时失效**：`showAppToast` 在找不到宿主时
是静默 no-op（这是它相对 `ScaffoldMessenger.maybeOf` 的改进），
于是投屏失败时用户和日志**两条线索都没有**。

修法：`onLog: (line) => AppLog.write('投屏', line)`。

### ② `_exitPlayer()` 加 `_exiting` 防重入守卫

本方法中段有 `await _toggleFullscreen(awaitOs: false)`，全屏路径实测 16.6ms。
这段窗口里 `_fullscreen` 首帧仍为 true，而末尾的 `if (mounted)` 拦不住（页面还活着）
⇒ 第二次进入会**再 pop 一次**，把详情页也弹掉。

守卫放在方法最前面，且**故意不在 `finally` 复位**：退出是终止性操作，
本页随即被 pop；若之后还能再进来，说明这页没真的退出。

### ③ 去掉 `jmap(r)?['x']` 的空感知

`lib/core/json_utils.dart` 的 `jmap()` **返回非空**（null 时抛异常），
所以 `?[` 的后半永远走不到。功能上两者等价，但它摆出「这里可能为 null，
所以兜底」的姿态 ⇒ 下一个读者会据此写出错误的重构。改成 `jmap(r)['x']`。

## Alternatives considered

- **只补日志、不改 `_exitPlayer`** —— 它最强的论据是「按住键不放」属于边缘操作，
  且 `mounted` 守卫已经挡住最常见的情形。
  否决理由：`mounted` 挡的是「页面已销毁」，而这里页面**还活着**，
  守卫根本没进入判定。且修复成本是一行 `bool`。

- **把既有 34 处 `jmap(r) ?? {}` 一起清掉** —— 它最强的论据是同类问题一次清干净。
  否决理由：跨多个业务方法，改动面大；更关键的是
  **不能盲目换成 `jmapOrNull(r) ?? const {}`** —— 那会把「抛异常」变成
  「静默返回空」，是**行为改变**，必须逐个判断原语义。⇒ 留作独立清理任务。

- **直接给 t98 词表加 `srca` / `hongniuzy`** —— 它最强的论据是这两个确实出现在
  产品代码注释里（`cache_page.dart:358` 等处），加了以后新代码就写不进来。
  否决理由：实测加进去后命中 15+ 处，全部是**注释里举例说明插件 id 格式**
  （`srca:3862`），不是用户可见文案。要过关得写十几条行级豁免 ——
  那会把门禁的信号稀释成噪声。⇒ 保持词表不动，取舍记录在此。

## Consequences

- **收益**：三处都是「测试全绿但产品行为不对」的路径被提前堵住；
  其中 ② 是可到达的双 pop（按住返回键），①是故障时完全没有线索。
- **代价**：② 的守卫加了一个字段，且**不**在 `finally` 复位 ——
  这要求 `_exitPlayer` 保持「终止性」语义（它现在确实是）。
  将来若有人把 `_exitPlayer` 改成可取消 / 可恢复的操作，这个守卫必须同步重审。
- **未做的**：既有 34 处 `jmap(r) ?? {}` 与 1 处 `invalid_null_aware` 保持原样，
  已记为独立清理候选；t98 词表按上面的理由不动。
- **重访条件**：当 `_exitPlayer` 变成非终止性操作（如可撤销的退出动画），
  或当「投屏」改走新的提示通道（那时 `onLog` 可能整体不再需要）。
