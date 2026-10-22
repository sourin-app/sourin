# Agent Note: 健康检测进度在二级页不刷新（宿主重建到不了另一条路由）

Status: implemented

> 同域：[2026-10-18-player-mouse-jank-localize-rebuilds.md](../simplification/2026-10-18-player-mouse-jank-localize-rebuilds.md)
> 那篇是**同一个教训的另一半**：在播放页把整页 `setState` 改成局部 notifier，
> 重建面 1624→20。本篇是它没覆盖的另一种形状 —— 消费点根本不在宿主的子树里
> （另一条路由），所以局部化不解决，得另开一路通知。
> 判据也不同：那篇看**重建次数**，本篇看**「谁通知谁」这条通道存不存在**。

## Problem

「健康检测」跑的时候，`SettingsPageState._healthSweep` 靠 `setState` 推进
`_healthDone / _healthOk / _sweeping`；进度行本来是写在 `_pluginsBlock` 里的一段
内联 `if (_sweeping) ...[ Row(...) ]`。

但 `_pluginsBlock` 不是宿主自己渲染的：它由 `_PluginsPage` 渲染，而 `_PluginsPage`
是 `Navigator.push` 出来的**另一条路由**。Flutter 里 `setState` 只重建自己的子树，
另一条路由不在这棵子树里，所以宿主每完成一个源 `setState` 一次，二级页一个像素都不动。

用户可见症状（PR #32 / CodeRabbit 线程 5）：点「健康检测」→ 进插件页 → 进度一直停在
`健康检测 0/26`；检测其实在后台正常跑；跑完/按停止后，那条 `0/26` 还挂着不消失。

根因不是「忘了刷新」，而是**跨路由的状态通知**：状态挂在 `SettingsPageState`，消费点在
另一条路由上，两边没有任何通道。

## Decision

宿主对外提供两个契约（`lib/ui/settings_page.dart`）：

1. `final ValueNotifier<int> _healthRev = ValueNotifier<int>(0);`
   —— 谁建谁销毁，`dispose()` 里 `_healthRev.dispose()`。
2. **三个推送点**，与三个状态变化点一一对应：
   - 开跑：`_sweeping = true` 之后；
   - 每完成一个：紧跟 `_healthDone++`（这是 `3/26` 能一格一格推进的唯一来源）；
   - `finally`：`setState(() => _sweeping = false)` 之后 —— 这一处同时覆盖
     「跑完了」和「用户按了停止」（取消路径也是穿 `finally` 出去的）。

进度行 `HealthSweepProgressRow` 自己订阅（`ValueListenableBuilder<int>` on `rev`），
`_pluginsBlock` 只把**宿主那个** `_healthRev` 交进去，不再指望 `_pluginsBlock` 被重建。
`sweeping == false` 时行自己返回 `SizedBox.shrink()` —— 停止/结束时消失也不再依赖宿主。
文案仍在宿主里拼（`label: () => '健康检测 $_healthDone/$_healthTotal'`），因为
`zz_t66_track_c_gates_test` 逐字断言了这句字面量必须在 UI 代码里。

形态约束（踩过，写进注释与门禁）：

- `rev` 的类型是**抽象** `ValueListenable<int>`，不是 `ValueNotifier<int>`：这一行只需要
  「值 + 通知」，不需要能写。
- 必须**精确** `import 'package:flutter/foundation.dart' show ValueListenable;`：
  `material_ui` 只 `export 'package:flutter/widgets.dart';`，而 `widgets.dart` 对
  foundation 只 `show Brightness, UniqueKey` —— `ValueNotifier` /
  `ValueListenableBuilder` 在，抽象的 `ValueListenable` 不在。写成 `ValueNotifier<int>`
  当参数类型可以躲过这条，但那是把「只读」这个意图弄丢了。

## Alternatives considered

1. **宿主每 tick 重建整条路由**（`Navigator.pop` + `push`，或给路由挂全局 key）。
   能让二级页跟着重建，但每次 tick 重建整页：滚动位置、Focus、Tab 状态全丢，
   26 个源要重建 26 次页面。否。
2. **进度行搬到宿主子树里，用 `Overlay` / `ScaffoldMessenger` 浮出来。**
   跨路由可见是做到了，但视觉位置和层级都变了（用户会看到它浮在插件页上面），
   `zz_settings_geometry_test` 的读数要跟着改。为一个 bug fix 改视觉，否。
3. **把 `_PluginsPage` 改成同一棵树里的条件渲染**（不再 `Navigator.push`）。
   最彻底，但路由、返回手势、Tab 状态、几何门禁全要重做，改动面远大于这个 bug；否。
4. **自定义 `ChangeNotifier` / `Stream` 通知对象。**
   本仓既有语义就是 `ValueListenableBuilder<int>`（`settings_page.dart:3822` 的
   `_dataRev`，`shell.dart` 同款）。为一行进度引入第二种通知机制，下次读代码的人
   要多学一套；否。

## Consequences

- 收益：二级页上的 `健康检测 N/26` 真推进；停止/结束立刻消失；宿主不再需要重建自己
  够不到的子树。
- 代价 1：多了一个「谁建谁销毁」的 `ValueNotifier`。忘了 `dispose()`，`finally` 那句
  推送会往死 notifier 上写（`ValueNotifier` 在 dispose 后赋值会抛）。`dispose` 门禁
  + 注入 E 覆盖这条。
- 代价 2：三个推送点必须与三个状态变化点同步，少推一处就是「只出现不推进」或
  「停在 N/N」。所以 `sync` 门禁钉的是**位置**（`_healthRev.value++` 必须落在
  `_healthDone++` 之后 220 字窗口内），不是只数总数。
- 代价 3：`snapshot()` 每次 tick 读一次宿主字段，多一层闭包；26 个源各一次，可忽略。

## Testing

`test/zz_t66_health_progress_gate_test.dart`（9 条，新增）：5 条真 widget —— 真
`MaterialApp` + 真 `Navigator.push` 拓扑（宿主 `SettingsPageState` 性行为在测试里用
同名同签名的 fake host 复刻，`HealthSweepProgressRow` 用产品代码原文），4 条接线断言
（`_healthSweep` 推送点、`finally`、`dispose`、`_pluginsBlock` 交的是真 notifier）。

故障注入五面，每条都真红（读数见 PR 回复）：去订阅 → A 组 4 红；删 `sweeping` 早退 →
5 红；删 per-item tick → `sync` 红；删 finally 复位 → `finally` 红；交新 notifier →
接线红。

空转史（写下来防止下次再写）：`sync` 第一版只数 `_healthRev.value++` 出现次数
（`>= 2`），注入「删掉 per-item tick」时**仍然绿** —— start + finally 两处照样凑够 2。
改成位置判据后才真红。数总数是最容易自我说服的假门禁。
