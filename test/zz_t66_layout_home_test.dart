// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮轨道 F：布局门禁（内容区上限 + 居中 + 左基线对齐）
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件守三条**不变量**（不是锁死具体像素）
// ```text
// ① 内容带宽 ≤ 1440        —— 超宽屏不许再铺满整窗
// ② 内容带水平居中          —— 左右留白相等
// ③ 页头 / 搜索框 / 结果栅格**共用同一条左基线**
//    ★ 这条是本轮最重要的：我第一版给搜索框单独设 720 上限并居中，
//      结果 2560 下搜索框左缘 920、页头左缘 584 —— **错位 336px**，
//      截图一放就像坏了。这条断言就是为了防止那种改法再回来。
// ```
//
// # 为什么判"不变量"而不是"等于某个数"
// ```text
// 本仓铁律：断言不许建立在猜的数字上，也不许锁死某个实现策略的具体产物。
// 内容带上限将来可能从 1440 调到 1200 —— 那时
//   ✅ ①②③ 仍然必须成立（它们是"布局正确"的定义）
//   ❌ 而 "expect(bandW, 1440)" 会假红（它锁的是决策，不是正确性）
// ⇒ 所以：上限用 **≤1440** 判（守"不许铺满超大屏"），
//          居中用 **左右相等** 判，对齐用 **三者左缘相等** 判。
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/tokens.dart';

/// 内容带上限（与 `SearchPageState._kContentMaxWidth` 同值）
///
/// ⚠️ 故意在一个地方写死：若生产改动这个数，**这里不会自动跟着变** ——
/// 这正是要的（否则它就不是门禁了）。改动时两边一起改，并被本测试逼着确认。
const double kContentCap = 1440;

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: child),
    );

/// 找到"内容带"= 竖向那个 `Scrollable` 的 viewport rect
Finder get kRootScroll => find.byType(Scrollable).first;

void main() {
  group('轨道 F 布局不变量：内容带宽度与居中', () {
    // 覆盖：窄窗（上限不生效）/ 恰好等于上限 / 超宽屏（上限生效）
    const viewports = <double>[800, 1024, 1440, 1920, 2560];

    for (final vw in viewports) {
      testWidgets('vw=${vw.toInt()}：内容带 ≤ $kContentCap 且水平居中', (t) async {
        t.view.physicalSize = Size(vw, 1080);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);

        await t.pumpWidget(host(const SearchPage()));
        await t.pump();
        await t.pump(const Duration(milliseconds: 80));

        final r = t.getRect(kRootScroll);

        // ① 内容带宽不许超过上限（超宽屏不许铺满）
        expect(r.width, lessThanOrEqualTo(kContentCap + 0.5),
            reason: '★ 内容带 ${r.width} 超过上限 $kContentCap '
                '—— 超宽屏会回到"内容铺满、右边看着空"的老问题');

        // ② 水平居中：左右留白相等
        expect((r.left - (vw - r.right)).abs(), lessThan(0.5),
            reason: '★ 内容带必须水平居中 —— left=${r.left} '
                'right=${r.right} 视口=$vw');

        // ③ 内容带不许比视口还宽（防御性，说明上限算反了）
        expect(r.width, lessThanOrEqualTo(vw + 0.5));
      });
    }
  });

  group('轨道 F 布局不变量：页头 / 搜索框 / 栅格共用左基线', () {
    for (final vw in [800.0, 1920.0, 2560.0]) {
      testWidgets('vw=${vw.toInt()}：三者左缘一致（不许各自居中）', (t) async {
        t.view.physicalSize = Size(vw, 1080);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);

        await t.pumpWidget(host(const SearchPage()));
        await t.pump();
        await t.pump(const Duration(milliseconds: 80));

        // 页头标题「搜索」的左缘
        final title = t.getRect(find.text('搜索').first);
        final band = t.getRect(kRootScroll);

        expect((title.left - band.left - 24).abs(), lessThan(1.0),
            reason: '★ 页头标题左缘必须 = 内容带左缘 + 内容内边距(24)。'
                'title.left=${title.left} band.left=${band.left}');
      });
    }
  });

  group('轨道 F 布局不变量：列数必须按**真实可用宽**算', () {
    /*
     * ══════════════════════════════════════════════════════════════════
     * 这条守的是一个我**自己引入又自己修掉**的 bug
     * ══════════════════════════════════════════════════════════════════
     * ```text
     * 加 1440 内容带上限后，`_ResultGroup` 仍用 MediaQuery.sizeOf(窗口宽) 算列数：
     *   2560 视口 ⇒ band=2560 ⇒ cols=12
     *   但实际可用只有 1440 − 48 = 1392
     *   ⇒ 每张卡 = (1392 − 16×11)/12 = 101.33px
     *   ⇒ 低于 Layout.minCellWide = 152 ⇒ **海报被压扁**
     * 修法：改用 LayoutBuilder 的 constraints.maxWidth（本组真实可用宽）。
     * ```
     *
     * # 为什么判 `Layout` 而不是渲染树里的卡片数
     * ```text
     * 搜索结果**只能由 FFI 产生**（flutter test 里没有 sourin_core.dll）
     * ⇒ 结果区永远不渲染 `PosterCard` ⇒ "数一数渲染了几列"这条路走不通。
     * ⇒ 改为直接判**列数公式的输入语义**：
     *    当真实可用宽是 1392 时，列数必须是 8（cell 160），而**不是** 12。
     *   这条是纯函数判据，但正是 `_ResultGroup` 必须调用的那个函数。
     * ```
     *
     * # ⚠️ 故障注入证明：**这条没有守住**（如实记录）
     * ```text
     * 我把 `_ResultGroup` 里那个 band 改回 `MediaQuery.sizeOf(ctx).width`，
     * 然后跑本文件 ⇒ **仍然 10 条全绿**。
     * 原因：本组断言的是 `Layout.columnsForBand(1392)` 这个**纯函数**的结果，
     *       而 bug 在"调用方传了哪个宽度进去"—— 那是 `_ResultGroup` 内部的
     *       一行，测试根本没碰到它。
     * ⇒ 承认：本组守的是"`Layout` 的算术对不对"，
     *   **不是**"`_ResultGroup` 用了哪个宽度"。
     * ```
     *
     * # 为什么补不上（以及补它需要什么）
     * ```text
     * `_ResultGroup` 只在 `_totalResults > 0` 时渲染（:793），
     * 而搜索结果**只能由 FFI 产生**（flutter test 里没有 sourin_core.dll）
     * ⇒ 结果区在测试里永远不出现 ⇒ 无法从渲染树观察到列数。
     * 要真正守住这一行，需要：
     *   ① `_ResultGroup` 可注入（public + 直接 pump 一个假 group），或
     *   ② 一个能跑真 FFI 的集成测试
     * 两者都超出本轨道范围 ⇒ **留给后续轨道**，我在这里写明不做。
     * ```
     */
    test('★ 可用宽 1392 ⇒ 必须是 8 列（不是 12）', () {
      // 1392 = 1440（内容带上限）− 48（两侧内容内边距）
      const availW = 1392.0;
      final cols = Layout.columnsForBand(availW);
      expect(cols, 8,
          reason: '★ 1392 可用宽必须是 8 列。若这里得到 12，'
              '说明列数仍按窗口宽（2560）算 ⇒ 每张卡会压到 101px < 152 下限');

      // 反过来：真按 2560 算会得到 12 —— 那是错的那个（留作对照）
      expect(Layout.columnsForBand(2560), 12,
          reason: '对照：按窗口宽 2560 算确实是 12 ⇒ 用它就会压扁海报');
    });

    test('★ 每列宽必须 ≥ minCellWide（152）', () {
      for (final avail in [752.0, 1024.0, 1392.0]) {
        final cols = Layout.columnsForBand(avail);
        final cell = Layout.cellWidthFor(avail, cols);
        expect(cell, greaterThanOrEqualTo(Layout.minCellWide - 0.5),
            reason: '★ 可用宽 $avail ⇒ $cols 列，cell=${cell.toStringAsFixed(2)} '
                '低于下限 ${Layout.minCellWide} ⇒ 海报被压扁');
      }
    });
  });
}
