# Agent Note: 首页横向轨道局部启用鼠标拖拽

Status: implemented

## Problem

首页 `_Rail` 与 `_LiveStrip` 使用横向 ListView，但默认 ScrollBehavior 不接受鼠标拖动，桌面用户只能依赖横向滚动条。全局滚动行为还承载 arm64 overscroll 装饰层 Clip.none 兼容修复，直接替换会丢失既有行为。

Independent: 首页横向轨道此前**没有任何**指针设备分流决定——既有笔记只覆盖横向滚动条隐藏（样式）与玻璃组件替换（材质），都没有讨论「鼠标左键按住拖动」这条输入路径，因此本篇不与任何既有决定重叠或冲突。

## Decision

`lib/ui/widgets/sourin_scroll_behavior.dart` 提供 `SourinHorizontalRail`，读取父 ScrollConfiguration 并通过 copyWith 在父 dragDevices 集合中增加 mouse，同时关闭该局部子树的自动滚动条。`lib/ui/home_page.dart` 仅在海报轨道和直播条的横向 ListView 外挂载包装；纵向页面、骨架列表及全局 shell 保持原状。父行为的 physics、触摸、trackpad 与 overscroll 装饰器继续由框架代理。

## Alternatives considered

- 全局增加 mouse：接入简单，但会改变所有纵向页面的鼠标手势，因此选择局部启用。
- 搬迁 shell 中的全局 ScrollBehavior：可以集中实现，但本次无需修改全局行为，迁移还会扩大既有 arm64 门禁的接线范围，因此保留原类。
- 手写拖拽监听器：可精细控制位移，但需要额外处理点击竞争和输入设备，选择框架原生滚动手势。

## Consequences

横向拖拽由 Flutter 手势竞争处理，拖动不激活卡片，单击仍保留。局部 copyWith 每次 build 会产生配置对象；定向测试证明父组件重建后偏移 320、ScrollPosition 与 ScrollableState 身份保留，未将新实例直接视为性能问题。本次未做性能基准。

## Verification

- Flutter SDK：C:/Users/iuuuuuuuu/flutter/bin/flutter.bat，3.47.5；基线 1281a20。
- `flutter test test/zz_t1026_horizontal_rail_mouse_drag_test.dart`：最终 5 项通过，退出码 0，覆盖两处挂载、鼠标拖拽与点击互斥、父重建状态保留、触摸与 trackpad、局部滚动条及父 Clip.none 保留。
- 新增重建测试前，与 `test/zz_t66_scroll_behavior_gate_test.dart` 联跑共 10 项通过，退出码 0；既有门禁未编辑。
- 撤销对照：临时将包装 build 改成 return child，原 4 项测试中 2 项失败，退出码 1。鼠标拖动 offset 实际为 0，横向 scrollbar 标记重新出现；恢复实现后原 4 项转绿。此为行为撤销对照，不声称完整基线运行新增测试。
- 仅格式化新增包装与新增测试；首页格式化产生的无关差异已撤销，保留 import 与两处包装。
- 未运行全量测试，未提交、推送、发布或重启客户端。未实机验收，未验证真实 arm64 设备及桌面输入硬件；任务保持进行中，等待 lead 独立复核和实机验收。
