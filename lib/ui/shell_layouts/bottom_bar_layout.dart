// ═══════════════════════════════════════════════════════════════════════
//  骨架 1 · 底栏式（现状，默认）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这套骨架就是「现状」，判据是**逐像素不变**
// ```text
// Lead 的原话：「骨架 1 是搬家不是重写。如果搬完后现有截图有任何
// 像素差异，说明你在搬家时改动了逻辑 —— 那是引入回归，要查出来。」
// ```
//
// # ★ 为什么导航件是**注入**的，而不是在本文件里重建
// ```text
// `_BottomBar` 与 `shell.dart` 内部深度耦合：
//   · _BottomPalette（药丸/文字/阴影三者成对的调色板）
//   · _BottomItem（含 FocusableActionDetector 的遥控器焦点）
//   · _tabWidthFor / _pillLeft（宽度与位置的唯一来源）
//   · 拖动状态 _dragPillLeft / _dragging（task-36 刚加的）
//   · BottomBarMarker（空间导航的结构判据）
//
// 把这 ~540 行整体搬过来，等于在「必须逐像素一致」的前提下
// 重写一遍依赖关系 —— 那是**引入回归的最短路径**。
//
// ⇒ 本文件只接管**「导航放在哪」**（这是骨架的定义），
//   导航件本身由 ShellPage 注入（它本来就是对的，一个像素都不用改）。
//   这样「搬家」搬的是**布局职责**，不是**重写控件**。
// ```

import 'package:flutter/widgets.dart';

import '../../shell.dart' show AppTab;
import 'shell_layout.dart';

class BottomBarShellLayout extends ShellLayout {
  const BottomBarShellLayout({required this.nav});

  /// 底栏导航件（由 ShellPage 注入，见文件头说明）
  final Widget nav;

  @override
  String get id => 'bottomBar';

  @override
  String get label => '底栏式';

  @override
  Widget build({
    required BuildContext context,
    required AppTab current,
    required ValueChanged<AppTab> onSelect,
    required Widget body,
    required List<AppTab> tabs,
  }) {
    /*
     * ★★★ 这一段的几何必须与改动前**逐字一致**
     *
     * 改动前（shell.dart 的 build 里）：
     * ```text
     * Stack
     *   ├ Positioned.fill(child: ClipRect(... body ...))
     *   └ Positioned(left:0, right:0,
     *                bottom: MediaQuery.paddingOf(context).bottom,
     *                child: BottomBarMarker(child: _bottomBar(colors)))
     * ```
     * ⇒ 本方法只是把这四行搬过来，**参数一个不改**。
     *
     * ⚠️ `bottom` 那一项是「底栏别被系统导航栏盖住」的修复
     *    （用户报过「手机端底部都被遮挡了」）。
     *    它读的是**根** padding —— 本 Positioned 是 SafeArea 的兄弟，
     *    不被 removePadding 清零。搬过来时不能顺手改成别的。
     */
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.paddingOf(context).bottom,
          child: nav,
        ),
      ],
    );
  }
}
