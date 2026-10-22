// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 M 批次 / P1-L1：筛选条「菜」缺陷门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么（Owner 报的那个「菜」字）
// ```text
// 缺陷：右栏 300px ⇒ 每格 80.7px；8 字分类名需要 96px
//       ⇒ Row 里「文字(88上限) + 箭头(15固定)」= 103px > 80.7px
//       ⇒ 溢出 22.3px ⇒ 箭头被推出格子，压到相邻的「管理」图标上
//       ⇒ 视觉上像「菜」字
// ```
//
// # 四条判据（①视觉错乱 ②③文字不侵入 ④Tooltip 全名 ⑤fallback 缩短）
// ```text
// ② 箭头必须存在（每格一个）
// ③ 文字右边界 ≤ 箭头左边界（文字不侵入箭头区域）
// ④ Tooltip 必须显示**当前选中的完整名字**（不是固定文案）
// ⑤ 三个 fallback 必须是缩短后的版本（防回退）
// ```
//
// ⚠️ **本文件不测"长名字显示完整"** —— 当前布局做不到（300px 装不下 96px）。
//    那一项如实记录为未解决，见交付说明。这里只守"视觉不再错乱"。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/ui/live_page.dart';

/// 真实最长分类名（来自 `.probe/t66_real_names.txt`，8 字符）
const _longName = '科教·生活·科学';

LiveGroup _group() => LiveGroup(
      provider: 'srca',
      providerName: '甲源',
      channels: [
        for (var i = 0; i < 6; i++)
          LiveChannel(
            id: 'c$i',
            name: '频道$i',
            logo: null,
            group: i.isEven ? _longName : '体育',
          ),
      ],
    );

Widget host({double width = 300}) {
  final g = _group();
  final flat = <LiveFlatEntry>[
    for (final c in g.channels)
      (channel: c, tag: g.providerName, provider: g.provider),
  ];
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: LiveChannelList(
            providers: [g],
            enabledProviders: {g.provider},
            channels: flat,
            selectedId: null,
            onPickChannel: (_) {},
            channelGroups: const {
              _longName: [LiveChannelRef('srca', 'c0')],
              '体育': [LiveChannelRef('srca', 'c1')],
            },
          ),
        ),
      ),
    ),
  );
}

/// 点开分类下拉并选中指定项
Future<void> pickCategory(WidgetTester t, String label) async {
  final cat = find.byKey(const ValueKey('live-bar-category'));
  await t.tap(cat.first, warnIfMissed: false);
  await t.pump();
  await t.pump(const Duration(milliseconds: 120));
  await t.tap(find.text(label).last, warnIfMissed: false);
  await t.pump();
  await t.pump(const Duration(milliseconds: 120));
}

const _cells = ['live-bar-group', 'live-bar-source', 'live-bar-category'];

void main() {
  group('P1-L1 筛选条「菜」缺陷', () {
    testWidgets('② 每格都必须有 ▼ 箭头（选中长名字后也不许消失）', (t) async {
      t.view.physicalSize = const Size(300, 500);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(host());
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      // 选中长名字 —— 这是原缺陷的触发条件
      await pickCategory(t, _longName);

      var arrows = 0;
      for (final el in find.byType(Icon).evaluate()) {
        if ((el.widget as Icon).icon == AppIcons.arrow_drop_down) arrows++;
      }
      final visibleCells =
          _cells.where((k) => find.byKey(ValueKey(k)).evaluate().isNotEmpty).length;

      expect(arrows, visibleCells,
          reason: '★★ 每格必须有 ▼ 箭头。改前长名字会把它挤出格子'
              '（溢出 22.3px），箭头压到「管理」图标上 ⇒ 视觉像「菜」字。'
              '箭头是"这里能点开"的唯一提示，不许被挤掉。');
    });

    testWidgets('③ 文字不许侵入箭头区域（不许重叠）', (t) async {
      t.view.physicalSize = const Size(300, 500);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(host());
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      await pickCategory(t, _longName);

      /*
       * 判据：长名字那个 Text 的右边界 ≤ 它所在格子里 ▼ 箭头的左边界。
       * ⇒ 文字和箭头不重叠 ⇒ 不会再"叠成一个字"。
       */
      final longText = find.text(_longName);
      expect(longText, findsWidgets, reason: '前提：长名字必须已选中并渲染');

      // 找准名字所在格子的箭头（取分类格内的）
      final catCell = find.byKey(const ValueKey('live-bar-category'));
      final arrowInCell = find.descendant(
        of: catCell,
        matching: find.byIcon(AppIcons.arrow_drop_down),
      );
      expect(arrowInCell, findsOneWidget,
          reason: '前提：分类格里必须有箭头');

      final textRect = t.getRect(longText.first);
      final arrowRect = t.getRect(arrowInCell.first);

      expect(textRect.right, lessThanOrEqualTo(arrowRect.left + 0.5),
          reason: '★★ 文字右边界 (${textRect.right.toStringAsFixed(1)}) '
              '必须 ≤ 箭头左边界 (${arrowRect.left.toStringAsFixed(1)})。'
              '改前文字溢出到 96px 而格子只有 80.7px ⇒ 两者重叠。');
    });

    testWidgets('④ Tooltip 必须显示当前选中的完整名字', (t) async {
      t.view.physicalSize = const Size(300, 500);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(host());
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      await pickCategory(t, _longName);

      /*
       * 截断后用户看不全名字 ⇒ Tooltip 是唯一补偿。
       * 判据：分类格的 Tooltip.message 必须包含**完整名字**。
       *
       * ⚠️ 分组/分类两格的 `tooltip` 字段本来是 null
       *    ⇒ 改前这里什么都不显示（`message: tooltip ?? ''`）。
       */
      final catCell = find.byKey(const ValueKey('live-bar-category'));
      final tooltip = find.descendant(
        of: catCell,
        matching: find.byType(Tooltip),
      );
      expect(tooltip, findsOneWidget, reason: '前提：该格必须有 Tooltip');

      final msg = (tooltip.evaluate().first.widget as Tooltip).message ?? '';
      expect(msg, contains(_longName),
          reason: '★★ 截断后必须能悬停看到完整名字。'
              '改前 `message: tooltip ?? \'\'` ⇒ 分组/分类两格**什么都不显示**。'
              '实际 message = "$msg"');
    });

    testWidgets('⑤ 三个 fallback 必须是缩短版（防回退）', (t) async {
      t.view.physicalSize = const Size(300, 500);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(host());
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));

      /*
       * 未选中任何值时，三格显示缩短后的 fallback。
       * ⇒ 防回退：如果有人改回「全部分组」/「全部源」/「全部分类」，
       *   可用的文字宽度立刻少 24px，长名字更容易溢出。
       *
       * ⚠️ 用"简写必须存在 + 长写法必须不存在"双向断言，
       *   避免只测一边（比如只测"分组"存在，而「全部分组」也存在）。
       */
      for (final short in ['分组', '源', '分类']) {
        expect(find.text(short), findsOneWidget,
            reason: '★ fallback「$short」必须存在（缩短版）');
      }
      for (final long in ['全部分组', '全部源', '全部分类']) {
        expect(find.text(long), findsNothing,
            reason: '★★ fallback「$long」必须**不再**出现 —— '
                '它是 4 字，比缩短版多吃 24px，会让长名字更容易溢出');
      }
    });

    testWidgets('⑥ 任何宽度下都不许 RenderFlex 溢出（回归保护）', (t) async {
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      for (final w in [260.0, 300.0, 340.0, 400.0]) {
        final errors = <String>[];
        final old = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exceptionAsString());

        t.view.physicalSize = Size(w, 500);
        await t.pumpWidget(host(width: w));
        await t.pump();
        await t.pump(const Duration(milliseconds: 60));
        FlutterError.onError = old;

        expect(errors, isEmpty,
            reason: '★★ 宽度 ${w.toInt()}px 下不许溢出。实际: '
                '${errors.isEmpty ? "无" : errors.first.split("\n").first}');
      }
    });
  });
}
