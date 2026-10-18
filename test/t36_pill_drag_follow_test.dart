// ═══════════════════════════════════════════════════════════════════════
//  task-36：tab 药丸**按住拖动时跟随手指**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// > 我点击未选中的然后保持点击动作 左右滑动，这个选中态并不会跟随
//
// # 根因
//   药丸位置只由「已选中的 tab」决定（_pillLeft(current, tabWidth)），
//   而 current 只由 onTap（抬手才触发）改变 ⇒ 拖动期间没有任何路径改位置。
//
// # 挂载真实 ShellPage（与 bottom_bar_fit_test 同一套脚手架）
//   底栏是私有的 _BottomBar ⇒ 只能从整个 ShellPage 里把它找出来。
//   ⚠️ 必须用 tester.view.physicalSize（不是 setSurfaceSize），
//      否则 MediaQuery 与布局不一致（那个坑 bottom_bar_fit_test:73-91 记着）。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';

Widget _appWith() {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, child) =>
        AppThemeHost(data: theme, child: child ?? const SizedBox()),
    home: ShellPage(key: debugShellKey),
  );
}

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

Future<void> _pump(WidgetTester t) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(1280, 800);
  addTearDown(t.view.reset);
  await t.pumpWidget(_appWith());
  await t.pump();
  _claim(t);
  await t.pump(const Duration(milliseconds: 1500));
  _claim(t);
}

/// 药丸当前的 left（读**真实渲染**，不读 State 私有字段）
///
/// 药丸 = Stack 里那个带**渐变**的 DecoratedBox（见 _BottomPalette.pillGradient）。
double _pillLeft(WidgetTester t) {
  /*
   * ⚠️ 必须**限定在导航栏内**找，不能用全局 .first ——
   *   实测全树有 2 个渐变 DecoratedBox：
   *     #0 rect=(84.5,116)-(180.5,152)   ← 页面内容里的，不是药丸
   *     #1 rect=(286,736)-(404,782)      ← 这才是底栏药丸
   *   用 .first 会一直读到 #0 ⇒ 无论怎么拖都是 84.5（我第一版就这样假红）。
   */
  final pill = find.descendant(
    of: find.byKey(const ValueKey('t36-bar'), skipOffstage: false),
    matching: find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final d = w.decoration;
      return d is BoxDecoration && d.gradient != null;
    }),
  );
  expect(pill, findsOneWidget, reason: '前置：导航栏里必须恰好一颗药丸');
  return t.getRect(pill.first).left;
}

/// 底栏那块玻璃面板（拖动手势就挂在它上面）
Finder get _bar => find.byKey(const ValueKey('t36-bar'));

void main() {
  testWidgets('★★★ 拖动中药丸 left 必须真的变化（Owner 报的核心缺陷）', (t) async {
    await _pump(t);
    final before = _pillLeft(t);

    final g = await t.startGesture(t.getCenter(_bar));
    await t.pump();
    /*
     * ⚠️ 必须**分两次** moveBy，不能一次 80px。
     * 实测：第一次 moveBy 的距离有 `kTouchSlop`(≈18px) 被**手势识别**吃掉
     *   —— 那一段用于判定「这是拖动不是点击」，onStart 在越过阈值处触发，
     *   药丸此时被设成**原位**，于是只量一次会读到「没动」（我的第一版就这样）。
     * 真实用户是连续移动的，第二次之后的位移才 1:1 反映到药丸上。
     */
    await g.moveBy(const Offset(40, 0));
    await t.pump();
    await g.moveBy(const Offset(40, 0));
    await t.pump();

    final during = _pillLeft(t);
    debugPrint('[T36] 拖动前=' + before.toStringAsFixed(1) +
        '  拖动中=' + during.toStringAsFixed(1));
    expect(during, greaterThan(before + 5),
        reason: '★★★ 拖动时药丸必须跟手 —— 这正是 Owner 报的缺陷');

    await g.up();
    await t.pumpAndSettle();
    _claim(t);
  });

  testWidgets('★★★ 拖动零延迟（1ms 内必须跟上，不能是 420ms 追尾）', (t) async {
    await _pump(t);
    final g = await t.startGesture(t.getCenter(_bar));
    await t.pump();
    await g.moveBy(const Offset(50, 0));
    await t.pump(const Duration(milliseconds: 1));
    final a = _pillLeft(t);
    await g.moveBy(const Offset(50, 0));
    await t.pump(const Duration(milliseconds: 1));
    final b = _pillLeft(t);
    debugPrint('[T36] 零延迟: ' + a.toStringAsFixed(1) +
        ' → ' + b.toStringAsFixed(1) +
        '  差=' + (b - a).toStringAsFixed(1));
    expect(b - a, greaterThan(30),
        reason: '★★★ 若走 420ms 补间，1ms 内只挪几个像素 ⇒ 这里会红');
    await g.up();
    await t.pumpAndSettle();
    _claim(t);
  });

  testWidgets('★★★ 纯点击必须仍然走 420ms 补间（规格④零回归）', (t) async {
    await _pump(t);
    final before = _pillLeft(t);

    await t.tap(find.text('搜索'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    final mid = _pillLeft(t);
    await t.pumpAndSettle();
    final after = _pillLeft(t);
    debugPrint('[T36] 点击: 前=' + before.toStringAsFixed(1) +
        ' 60ms=' + mid.toStringAsFixed(1) +
        ' 结束=' + after.toStringAsFixed(1));

    expect(after, greaterThan(before + 5), reason: '★ 点击必须切换位置');
    expect(mid, lessThan(after - 1),
        reason: '★★★ 点击必须走 420ms 补间（60ms 时还没到位）——'
            '若这里已是零延迟，说明拖动分支污染了点击路径');
    _claim(t);
  });
}
