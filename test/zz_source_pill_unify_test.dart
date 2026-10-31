// ═══════════════════════════════════════════════════════════════════════
//  zz_source_pill_unify：首页液态玻璃选择器统一门禁（批次 T4，2026-10-31）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，本批任务书 T4）
// ```text
// > 首页就算只有一个源也要显示那个液态选择的，然后 tvbox 聚合源下面的
// > 也要跟那个液态玻璃选择的样式一样，这里样式都不一样，要优化和矫正。
// ```
//
// # 这条门禁守什么（两条，各有牙）
// ```text
// ① 单源也渲染 —— 改前 SourceBar 在 `sources.length <= 1` 时整条
//   SizedBox.shrink()（原版 SourceBar.vue 行为）。Owner 2026-10-31 明确
//   推翻 ⇒ 谁把早退加回去，★ 用例当场红。
// ② "两处构造走同一组件" —— 源条（SourceBar）与聚合渠道条
//   （home_page._AggChannelRail）的药丸都必须是 source_bar.dart 的
//   **公共件 SourcePill**。判据是"改一处两处同变"：
//   药丸样式（选中高亮/圆角/字重/焦点环/失效标记）只活在 SourcePill
//   一个类里 ⇒ 谁把渠道条改回 ActionChip（或再抄一份私有 pill），
//   ★★★ 用例当场红。
// ```
//
// # 为什么②用静态契约而不是真挂 AggChannelsBlock
// ```text
// 渠道条区块要 FakeAgg 数据夹具（zz_n9_agg_channel_rail_test.dart 已有
// 一整套）；"用什么组件构造"是**结构属性**，与 t94 同一条纪律：
// 静态判据能守的接线/构造问题，不必为它搭运行时夹具。
// 渠道条的**行为**（请求数/切渠道换子树）由 zz_n9 那套 runtime 门禁守，
// 两边不重叠。
// ```
// ⚠️ 静态判据必须**先去注释**再匹配：本批改后 rail 的注释里就写着
//    "ActionChip"（历史注脚），裸 contains 会拿注释当实现（假绿/假红）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';

/// 去注释（状态机；与 t94 同一条实现纪律：字符串里的 // 与 /* 不算注释）
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (quote != null) {
      if (c == '\\') {
        out.write(c);
        if (next.isNotEmpty) out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

List<ProviderManifest> _sources(int n) => [
      for (var i = 0; i < n; i++)
        ProviderManifest(
          id: 'src-$i',
          name: '源$i',
          enabled: true,
        ),
    ];

Widget _host(Widget child) {
  final data = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: data,
    builder: (_, c) => AppThemeHost(data: data, child: c ?? const SizedBox()),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('zz SourcePill 统一门禁（T4 2026-10-31）', () {
    testWidgets('★ 单源也渲染液态玻璃条（不许再 shrink）', (t) async {
      await t.pumpWidget(_host(
        SourceBar(
          sources: _sources(1),
          current: 'src-0',
          onSelect: (_) {},
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('源0'), findsOneWidget,
          reason: '★ Owner 逐字：「首页就算只有一个源也要显示那个液态选择的」'
              '—— 谁把 `sources.length <= 1` 的早退加回去，这里当场红。\n'
              '单源默认选中；点击重选由 `_switchSource` 的同源守卫短路，无害。');
      expect(find.byType(SourcePill), findsOneWidget,
          reason: '★ 渲染出来的必须是公共药丸本体（不是别的芯片样式）。');
    });

    testWidgets('★ 多源渲染不受影响（回归：每源一颗公共药丸）', (t) async {
      await t.pumpWidget(_host(
        SourceBar(
          sources: _sources(3),
          current: 'src-1',
          onSelect: (_) {},
        ),
      ));
      await t.pumpAndSettle();

      expect(find.byType(SourcePill), findsNWidgets(3),
          reason: '★ 放开单源不许伤到多源路径。');
    });

    test('★★★ 源码契约：渠道条与源条走**同一个** SourcePill（改一处两处同变）', () {
      final home =
          stripComments(File('lib/ui/home_page.dart').readAsStringSync());
      final sb = stripComments(
          File('lib/ui/widgets/source_bar.dart').readAsStringSync());

      // ── 渠道条（home_page._AggChannelRail）──────────────────────────
      final railStart = home.indexOf('class _AggChannelRail');
      final railEnd = home.indexOf('class _MoreButton');
      expect(railStart > 0 && railEnd > railStart, isTrue,
          reason: '★ 前置：渠道条类区间的两个锚点都必须找得到'
              '（锚点挪了就改这里，不许放宽判据）');
      final rail = home.substring(railStart, railEnd);

      expect(rail.contains('child: SourcePill('), isTrue,
          reason: '★★★ 渠道条药丸必须用公共 SourcePill 构造 —— '
              'Owner 逐字：「tvbox 聚合源下面的也要跟那个液态玻璃选择的样式一样」');
      expect(rail.contains('ActionChip('), isFalse,
          reason: '★★★ 渠道条不许再有自己的芯片视觉 —— '
              '把 SourcePill 改回 ActionChip（或并存一份）当场红');

      // ── 源条（source_bar.SourceBar）───────────────────────────────
      final barStart = sb.indexOf('class SourceBar');
      final pillStart = sb.indexOf('class SourcePill');
      expect(barStart > 0 && pillStart > barStart, isTrue,
          reason: '★ 前置：源条/公共药丸两个类锚点都必须找得到');
      final bar = sb.substring(barStart, pillStart);
      expect(bar.contains('child: SourcePill('), isTrue,
          reason: '★ 源条自己也必须走同一公共件（不许内联一份样式）');

      // ── 公共件唯一性 ─────────────────────────────────────────────
      expect(sb.contains('class SourcePill extends StatelessWidget'), isTrue,
          reason: '★ 公共药丸必须存在且公开（下划线私有件两个消费方都够不到）');
      expect(sb.contains('class _SourcePill'), isFalse,
          reason: '★ 私有旧件必须已删 —— 留着就是两套样式并存，'
              '"改一处两处同变"落空');
    });
  });
}
