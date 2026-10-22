// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 M 批次：直播页筛选条玻璃化门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件守四条（都是"改完不能退化/不能越界"的判据）
// ```text
// ① 筛选条**真的是玻璃组件**（GlassCard 存在）
// ② 列表行**没有被玻璃化**（反向断言 —— 防止将来有人误用 A 方案）
// ③ 搜索框**没有被玻璃化**（边界最容易错的地方，Lead 特别要求）
// ④ 筛选条与列表之间**有间距**（几何断言，不是"看着差不多"）
// ```
//
// # 为什么②③要写"反向断言"
// ```text
// 玻璃化最容易犯的错是**范围过大**：
//   · 顺手把列表行也包进 GlassCard ⇒ 20 行都变圆角条，
//     1178 个台的扫视变慢（实测变化率 46.8%，行间出现缝隙感）
//   · 顺手把 header 整块包进 GlassCard ⇒ 搜索框被包进去，
//     焦点态（`358da42` 刚做出来的 outlineVariant→primary）被玻璃模糊掉
// ⇒ 这两条断言守的是"**不许做过头**"，比"做了没有"更重要。
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/live_page.dart';

LiveGroup _group() => LiveGroup(
      provider: 'srca',
      providerName: '甲源',
      channels: [
        for (var i = 0; i < 8; i++)
          LiveChannel(
            id: 'c$i',
            name: '频道$i',
            logo: null,
            group: i.isEven ? '综合' : '体育',
            nowPlaying: i.isEven ? '正在播节目 $i' : null,
          ),
      ],
    );

Widget host({String selectedId = 'c2', bool withHeader = false}) {
  final g = _group();
  final flat = <LiveFlatEntry>[
    for (final c in g.channels)
      (channel: c, tag: g.providerName, provider: g.provider),
  ];
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(
      backgroundColor: const Color(0xFF15161C),
      body: LiveChannelList(
        providers: [g],
        enabledProviders: {g.provider},
        channels: flat,
        selectedId: selectedId,
        onPickChannel: (_) {},
        /*
         * ★ ③ 需要搜索框真实存在于树里。
         * 生产路径里它是 `LivePageState._buildListHeader()` 通过 `header:`
         * 槽位传进来的（`live_page.dart:2387`）⇒ 这里必须模拟同样的位置，
         * 否则测试里根本没有 TextField，③ 会误报"找不到"。
         */
        header: withHeader
            ? LiveSearchField(
                controller: TextEditingController(),
                query: '',
                hitCount: 0,
                total: 8,
                onChanged: (_) {},
                compact: true,
              )
            : null,
      ),
    ),
  );
}

void main() {
  group('M 批次：直播页筛选条玻璃化', () {
    testWidgets('① 筛选条真的是玻璃组件', (t) async {
      t.view.physicalSize = const Size(760, 460);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(host());
      await t.pump();

      expect(find.byType(GlassCard), findsWidgets,
          reason: '★ 筛选条必须真的用玻璃组件（不是 Container）');
    });

    testWidgets('② 列表行**没有被玻璃化**（反向断言）', (t) async {
      t.view.physicalSize = const Size(760, 460);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(host());
      await t.pump();

      /*
       * 判据：列表行的文字（频道0..7）**祖先链里不许有 GlassCard**。
       * 用第一个频道名做代表（所有行的结构相同）。
       */
      final channelText = find.text('频道0');
      expect(channelText, findsOneWidget, reason: '前提：频道行必须渲染出来');

      expect(
        find.ancestor(of: channelText, matching: find.byType(GlassCard)),
        findsNothing,
        reason: '★★ 列表行**不许**玻璃化 —— 实测全行玻璃会让 20 行变成'
            '独立圆角条（变化率 46.8%），行间出现缝隙感，'
            '1178 个台的扫视变慢。行背景保持透明是有意设计。',
      );
    });

    testWidgets('③ 搜索框**没有被玻璃化**（边界防线）', (t) async {
      t.view.physicalSize = const Size(760, 460);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(host(withHeader: true));
      await t.pump();

      final field = find.byType(TextField);
      expect(field, findsWidgets, reason: '前提：搜索框必须存在');

      expect(
        find.ancestor(of: field.first, matching: find.byType(GlassCard)),
        findsNothing,
        reason: '★★ 搜索框**不许**被包进玻璃 —— 它是输入控件，'
            '需要清晰边界让用户知道"点哪里能打字"。'
            '玻璃化会模糊掉 `358da42` 刚做好的焦点态'
            '（outlineVariant → primary）。',
      );
    });

    testWidgets('④ 筛选条与列表之间有间距（几何断言）', (t) async {
      t.view.physicalSize = const Size(760, 460);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(host());
      await t.pump();

      /*
       * ★ 判据分两层 —— 第一层是**关键**，第二层只是"渲染上真的生效"。
       *
       * # 为什么不能只判"第一行顶边 − 玻璃底边 ≥ 8"
       * ```text
       * 我第一版就是这么写的，然后**故障注入没红**：
       * 删掉那个 SizedBox 后实测 gap 仍然 = 31 ——
       * 因为 `ListView` 自己的 `padding: EdgeInsets.all(Sp.x3)` 就贡献了 19px，
       * 加上行内边距，31 依然 ≥ 8 ⇒ 断言形同虚设。
       * ⇒ 必须直接量**那个间距组件本身**。
       * ```
       */
      final gapBox = find.byKey(const ValueKey('live-filterbar-gap'));
      expect(gapBox, findsOneWidget,
          reason: '★ 筛选条与列表之间的间距组件必须存在'
              '（删掉它，玻璃条的下边缘高光会直接撞上第一行）');

      final gapRect = t.getRect(gapBox);
      expect(gapRect.height, greaterThanOrEqualTo(8.0),
          reason: '★ 间距高度必须 ≥ 8（实际用 Sp.x3=12），'
              '实测 ${gapRect.height}');

      /*
       * 第二层：几何上确认它**真的把第一行推下去了**（不是被别的东西吃掉）。
       * 这一层允许 gap 大于间距本身（`ListView` 的 padding 也会贡献）。
       */
      final glassRect = t.getRect(find.byType(GlassCard).first);
      final firstRowRect = t.getRect(find.text('频道0'));
      final visualGap = firstRowRect.top - glassRect.bottom;
      expect(visualGap, greaterThanOrEqualTo(8.0),
          reason: '★ 视觉上第一行必须明显低于玻璃条底边，实测 $visualGap');
    });
  });
}
