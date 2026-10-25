import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Only horizontal home rails opt into mouse dragging. Inherit the parent
/// behavior so platform physics and the arm64 overscroll clipping fix survive.
///
/// # ⚠️⚠️ 硬警告：**不许**往下面的 `copyWith` 里加「每次 build 都新建」的实例字段
/// （`physics:` / `platform:` 之类）
///
/// ```text
/// 为什么这一句必须写死在这里（2026-10-25 交叉复核，实测过）：
///
/// 本组件每次 build 都会 `parent.copyWith(...)` ⇒ 一个**新的**
/// `_WrappedScrollBehavior` 实例。这本身是安全的，原因**只有一个**：
///   `_WrappedScrollBehavior.shouldNotify`
///   （flutter/lib/src/widgets/scroll_configuration.dart:372-382）对
///   `dragDevices` 用的是 `setEquals(...)`（**比内容**），而本次唯一会变的
///   字段正好只有 `dragDevices` 与 `scrollbars`（bool，相等）⇒ 返回 false
///   ⇒ `ScrollConfiguration.updateShouldNotify` false
///   ⇒ `Scrollable.didChangeDependencies` 不跑
///   ⇒ `_updatePosition()` 不执行 ⇒ **ScrollPosition 不重建**。
///
/// 但 `shouldNotify` 里其它字段是**按实例比较**（`physics != physics`、
/// `platform != platform`）。所以只要有人加一句
///     `physics: const BouncingScrollPhysics()`   ← 常量，安全
///     `physics: ClampingScrollPhysics()`         ← **每次新建，炸**
/// 就会让每一次 build 都判「behavior 变了」⇒ `didChangeDependencies`
/// ⇒ `_updatePosition()` → `createScrollPosition(...)` **重建 ScrollPosition**。
///
/// 实测后果（故障注入，`zz_t1026_horizontal_rail_mouse_drag_test` 直接变红）：
///   · 偏移量**不会丢**（`ScrollPositionWithSingleContext` 用 `oldPosition`
///     `absorb` 了 pixels，实测注入后 offset 仍是 320.0）；
///   · 丢的是 **position 身份**与**活动状态**：旧 position 被
///     `scheduleMicrotask(dispose)`，在飞的拖拽/惯性被重建
///     ⇒ 用户拖到一半松手，可能突然停住或回弹。
/// ```
///
/// 结论：**要么不加**，要么加 `const` 实例（编译期同一对象）。
/// 判据由 `test/zz_t1026_horizontal_rail_mouse_drag_test.dart` 的
/// 「parent rebuild preserves rail position and ScrollPosition identity」
/// （`expect(controller.position, same(position))`）把守 —— 这是目前**唯一**
/// 一条能抓到该形态的断言，改本文件后必须跑它。
class SourinHorizontalRail extends StatelessWidget {
  const SourinHorizontalRail({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final parent = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: parent.copyWith(
        dragDevices: {...parent.dragDevices, PointerDeviceKind.mouse},
        scrollbars: false,
      ),
      child: child,
    );
  }
}
