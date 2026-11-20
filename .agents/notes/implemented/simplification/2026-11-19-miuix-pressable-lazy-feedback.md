# Agent Note: 按需分配可选的 Miuix 按压反馈控制器

Status: implemented

适用：2026-11-19，vendored MiuixPressable 的 controller 分配。
关联：[播放器 Miuix 控件](../feature/2026-11-08-player-miuix-controls.md)与
[播放器局部重建](2026-10-18-player-mouse-jank-localize-rebuilds.md)的现行交互约束保持。

## Problem

每个 MiuixPressable 挂载时都创建四个 AnimationController，即使按钮只使用覆盖层反馈。
卡片密集页面因此也为从未选择的 sink 与 tilt 反馈分配 ticker 和控制器。

## Decision

覆盖层控制器保持立即创建。sink 控制器只在该反馈第一次需要时创建，初始 scale 仍为 1.0；
每个 tilt 控制器也只在第一次需要时创建，初始值仍为零。控制器一旦创建就保留，切回原反馈类型
时维持既有状态与进行中的模拟。销毁只 dispose 已分配控制器，不能为销毁未使用控制器而初始化它。

改变的是分配时机，不是交互树、动画弹簧、手势回调、hover/焦点、语义或键盘操作。
普通反馈使用 1 个控制器，sink 使用 2 个，tilt 使用 3 个；曾使用全部模式的组件仍可保留 4 个。

## Alternatives considered

- **四个控制器全部立即创建**：实现直观、没有懒分配分支，但保留了普通组件不使用的挂载分配。
- **每次 feedbackType 改变就销毁并重建**：能够回收控制器，却重置原状态和进行中的模拟，故不采用。

## Consequences

`test/t20261119_miuix_pressable_allocations_test.dart` 读取真实分配数量，覆盖指针激活、hover、
禁用、Enter/Space/数字键盘 Enter、heldDown、按住指针切换反馈、被打断的模拟、首次懒分配前的
TickerMode 与销毁。原六文件相关套件记录 57 项通过；补两项生命周期用例后的完整分配文件为 6 项通过。
普通、sink、tilt 的 idle/hover/press/focus/held/disabled 以及模式切换共 23 对 PNG 逐字节一致。

已有回执在 `.probe/pressable-lazy-20261119-root-v1/PRESSABLE_LAZY_ALLOCATION_SCOPED_VERIFICATION_V1.json`
与 `PRESSABLE_LAZY_ALLOCATION_FINAL_HANDOFF_V2.json`。首次图像采集因 tester.runAsync 条件中断的记录保留；
首次回执绑定的是格式化前测试及当时笔记，后继分别记录仅格式化后的测试与当前说明。补记不改这些冻结回执。

收益是普通组件少创建三个控制器，并有局部行为/像素等价证据；代价是可选分支与保留已用控制器的状态。
这不证明帧时间改善，不满足原始 20 场景严格预算，也不赋予当前整包资格。
[海报配置复用](2026-11-19-poster-image-configuration-reuse.md)与
[封面 provider 身份复用](2026-11-19-cover-provider-identity-reuse.md)有各自输入，不归这条分配决定。
反馈生命周期或对应输入改变时才重开影响面，未变更的已有阳性不重复执行。
