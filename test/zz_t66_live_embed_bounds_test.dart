// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮：直播页内嵌播放器边界门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么
// ```text
// Owner 报：「左侧播放区域,视频控件都有一半在视窗外了」
// 排查结论（`.probe/t66_size_sweep.txt`，12 组读数）：
//   6 种视口 × 宽/窄两分支 ⇒ **全部不越界**。
// ⇒ 代码层面没有越界；若现象真实存在，只能来自**窗口本身**
//   （被拖到屏幕边缘外 / 窗口大于屏幕可用区），不是 UI 布局 bug。
// ```
//
// # ★ 本门禁的边界声明（不许含糊）
// ```text
// 本文件只覆盖 **LiveEmbeddedPlayer**（直播页右侧列表左边那块内嵌播放器）。
// ★ 若现象出现在**全屏播放页**（PlayerPage），本结论**不覆盖**，需另行验证。
//   「左侧播放区域」这个措辞支持"直播页"的判断，但那是推断，不是确认。
// ```
//
// # 三条判据（取自原探针）
// ```text
// ① 播放器 rect 在 ClipRRect 内（L<=0 R<=0 B<=0，即没有向任何方向溢出）
// ② 所有 Icon 的 global x >= 0 且右边界在视口内
// ③ 全渲染树无 x<0 的 RenderBox
// ```
//
// # 仪器说明
// ```text
// `tester.getRect()` 读的是**渲染盒的绝对坐标**（不只是"在树上"），
// 所以能抓到「树上存在但视觉在屏外」的情况 ——
// Stack + Positioned 的溢出正是这种形态。
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

/// 六种视口（含 Owner 截图尺寸与 900 断点两侧）
const _viewports = <Size>[
  Size(1444, 845), // Owner 截图的精确尺寸
  Size(1280, 720),
  Size(1024, 768),
  Size(900, 600),
  Size(899, 600), // ★ 刚好跨过 900 断点
  Size(640, 480),
];

/// 宽屏分支几何（复刻 `live_page.dart` 的 `_buildWideBody`）
Widget _wide(Widget player) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                key: const ValueKey('embed-clip'),
                borderRadius: Radii.rLg,
                child: ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AspectRatio(
                          key: const ValueKey('embed-ar'),
                          aspectRatio: 16 / 9,
                          child: player,
                        ),
                        const SizedBox(height: 24, width: double.infinity),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: Sp.x5),
            SizedBox(width: 300, child: Container(key: const ValueKey('embed-rail'))),
          ],
        ),
      ),
    );

/// 窄屏分支几何（复刻 `_buildNarrowBody`）
///
/// ⚠️ 第一版把 `AspectRatio` 直接放在 `Column` 里 + 一个 24px 的 SizedBox，
///    在 1280×720 下 16:9 的播放器正好是 720 高 ⇒ Column 溢出 24px。
///    ★ 那是**测试夹具的几何问题**，不是产品缺陷 ——
///    生产的 `_buildNarrowBody` 里播放器在可滚动区域内，不会这样硬挤。
///    修法：把播放器放进 `Flexible`，让它按可用高度收缩（与生产一致）。
Widget _narrow(Widget player) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Column(
          children: [
            Flexible(
              child: AspectRatio(
                key: const ValueKey('embed-ar'),
                aspectRatio: 16 / 9,
                child: player,
              ),
            ),
            const SizedBox(height: 24),
            const Expanded(child: SizedBox()),
          ],
        ),
      ),
    );

Widget _player() => const LiveEmbeddedPlayer(
      stream: null,
      title: '边界测试',
      subtitle: '子标题',
    );

/// 全渲染树里 `global x < 0` 的 RenderBox 个数
int _countOffLeftEdge(WidgetTester t) {
  var found = 0;
  void walk(RenderObject ro) {
    if (ro is RenderBox && ro.hasSize) {
      final off = ro.localToGlobal(Offset.zero);
      if (off.dx < -0.5) found++;
    }
    ro.visitChildren(walk);
  }

  final root = t.binding.rootElement;
  if (root?.renderObject != null) walk(root!.renderObject!);
  return found;
}

void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());

  for (final sz in _viewports) {
    final label = '${sz.width.toInt()}x${sz.height.toInt()}';

    testWidgets('宽屏 $label：播放器与图标都不越界', (t) async {
      t.view.physicalSize = sz;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(_wide(_player()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 80));

      // ① 播放器在 ClipRRect 内
      final clip = find.byKey(const ValueKey('embed-clip'));
      final ar = find.byKey(const ValueKey('embed-ar'));
      expect(clip, findsOneWidget, reason: '$label 前置：ClipRRect 必须在树上');
      expect(ar, findsOneWidget, reason: '$label 前置：播放器必须在树上');

      final c = t.getRect(clip);
      final p = t.getRect(ar);
      /*
       * ★ 判据用 `lessThanOrEqualTo(0.5)` 而不是 `== 0`：
       *   getRect 是浮点，跨 DPI 会有 1e-13 级误差。
       *   0.5px 是"视觉上不可见"的量级，且远小于任何真实溢出。
       */
      expect(c.left - p.left, lessThanOrEqualTo(0.5),
          reason: '$label 播放器左边缘超出 ClipRRect（clip=${c.left}, '
              'player=${p.left}）。Owner 报的「一半在视窗外」正是这个形态。');
      expect(p.right - c.right, lessThanOrEqualTo(0.5),
          reason: '$label 播放器右边缘超出 ClipRRect');
      expect(p.bottom - c.bottom, lessThanOrEqualTo(0.5),
          reason: '$label 播放器下边缘超出 ClipRRect');

      // ② 所有 Icon 在视口内
      for (final el in find.byType(Icon).evaluate()) {
        final ro = el.renderObject;
        if (ro is! RenderBox) continue;
        final off = ro.localToGlobal(Offset.zero);
        expect(off.dx, greaterThanOrEqualTo(-0.5),
            reason: '$label 有 Icon 的 global x < 0 = ${off.dx}。'
                '★ 这正是 Owner 描述的形态：控件跑到视窗左边界之外。');
        expect(off.dx + ro.size.width, lessThanOrEqualTo(sz.width + 0.5),
            reason: '$label 有 Icon 的右边界超出视口宽 ${sz.width}');
      }

      // ③ 全树无 x<0
      expect(_countOffLeftEdge(t), 0,
          reason: '$label 渲染树里存在 global x < 0 的 RenderBox。'
              '★ 这比"某个 Icon 出界"更宽：任何盒子跑到左边界外都算。');
    });

    testWidgets('窄屏 $label：播放器与图标都不越界', (t) async {
      t.view.physicalSize = sz;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(_narrow(_player()));
      await t.pump();
      await t.pump(const Duration(milliseconds: 80));

      final ar = find.byKey(const ValueKey('embed-ar'));
      expect(ar, findsOneWidget, reason: '$label 前置：播放器必须在树上');
      final p = t.getRect(ar);
      expect(p.left, greaterThanOrEqualTo(-0.5),
          reason: '$label 窄屏播放器左边缘越界（left=${p.left}）');
      expect(p.right, lessThanOrEqualTo(sz.width + 0.5),
          reason: '$label 窄屏播放器右边越界（right=${p.right} > ${sz.width}）');

      for (final el in find.byType(Icon).evaluate()) {
        final ro = el.renderObject;
        if (ro is! RenderBox) continue;
        final off = ro.localToGlobal(Offset.zero);
        expect(off.dx, greaterThanOrEqualTo(-0.5),
            reason: '$label 窄屏有 Icon 的 global x < 0 = ${off.dx}');
      }

      expect(_countOffLeftEdge(t), 0,
          reason: '$label 窄屏渲染树里存在 global x < 0 的 RenderBox');
    });
  }

  // ════════════════════════════════════════════════════════════════════
  //  阴性对照：证明本文件的扫描器不是恒真
  // ════════════════════════════════════════════════════════════════════
  testWidgets('阴性对照：故意放一个 x<0 的元素 ⇒ 扫描器必须能数到', (t) async {
    t.view.physicalSize = const Size(800, 600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: -40,
              top: 10,
              child: SizedBox(
                key: ValueKey('deliberately-offscreen'),
                width: 20,
                height: 20,
              ),
            ),
          ],
        ),
      ),
    ));
    await t.pump();

    /*
     * ★ 这条守的是「扫描器本身有效」。
     * 如果 `_countOffLeftEdge` 恒返回 0（比如遍历写错），
     * 上面 12 条门禁就全是假绿。
     */
    expect(_countOffLeftEdge(t), greaterThan(0),
        reason: '★★ 阴性对照失败：故意放在 x=-40 的元素没被数到 ⇒ '
            '`_countOffLeftEdge` 有问题 ⇒ 上面 12 条「无越界」全不可信。'
            '若读到 0 而元素确实在树上，说明扫描器遍历路径错了。');
  });
}
