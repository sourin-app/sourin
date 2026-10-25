// ═══════════════════════════════════════════════════════════════════════
//  t1046：源列表**空态提示**（用户当场"看不到聚合"的根因收口）
// ═══════════════════════════════════════════════════════════════════════
//
// # 现场事实（不是推测）
// ```text
// 用户真实数据目录：`third-party-providers.json == []`、`tvbox-sources.json` 不存在
// ⇒ 从未成功导入过 TVBox 配置；而"导入"入口藏在右上角 ⋮（tooltip「更多操作」）里
// ⇒ 空列表 = 一片空白 ⇒ 用户不知道下一步该点哪。
// ```
//
// # 本文件守两条
// ```text
// ① 空列表：必须有一句人话 + 一个显式「导入」按钮，且按钮真的回调宿主
// ② 有源时：这块**零尺寸**（注入"忽略 isEmpty" ⇒ ② 立刻红）
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('① 空列表 ⇒ 提示 + 显式导入按钮', () {
    testWidgets('★★★ 文案逐字 + 按钮可点（真的回调宿主）', (t) async {
      var taps = 0;
      await t.pumpWidget(host(SourcesEmptyState(
        isEmpty: true,
        onImport: () => taps++,
      )));
      await t.pump();

      expect(find.byKey(const ValueKey<String>('sources-empty-state')),
          findsOneWidget,
          reason: '★★★ 空列表必须给出下一步 —— 把 isEmpty 判据改成恒 false（注入）本条立刻红');

      final text = t
          .widget<Text>(find.byKey(const ValueKey<String>('sources-empty-text')))
          .data;
      expect(text, '还没有导入任何源 —— 点「导入」粘贴 TVBox 配置或订阅地址',
          reason: '★★ 文案要**逐字**（用户照着一句话就能动）');
      expect(text!.contains('**'), isFalse, reason: '★ 本仓无 markdown 渲染器');
      for (final banned in const ['缺陷', 'Owner', '探针', 'task-']) {
        expect(text.contains(banned), isFalse, reason: '★ 不许开发用语「$banned」');
      }

      final btn = find.byKey(const ValueKey<String>('sources-empty-import'));
      expect(btn, findsOneWidget, reason: '★★ 必须有一个显式按钮（不能只靠 ⋮ 菜单）');
      expect(find.widgetWithText(FilledButton, '导入'), findsOneWidget,
          reason: '★ 按钮文案逐字是「导入」');
      await t.tap(btn);
      await t.pump();
      expect(taps, 1, reason: '★★ 按钮必须真的调到宿主的导入动作（否则等于假按钮）');
    });
  });

  group('② 有源时 ⇒ 零尺寸（不许占位/不许改原布局）', () {
    testWidgets('★★★ isEmpty=false ⇒ 一个像素都不占', (t) async {
      await t.pumpWidget(host(SourcesEmptyState(
        isEmpty: false,
        onImport: () {},
      )));
      await t.pump();

      expect(find.byKey(const ValueKey<String>('sources-empty-state')),
          findsNothing,
          reason: '★★★ 有源时还挂提示 ⇒ 用户会以为"我没导入过"；'
              '注入"忽略 isEmpty"本条立刻红');
      expect(t.getSize(find.byType(SourcesEmptyState)).height, 0,
          reason: '★ 必须零尺寸（不是"透明但仍占位"）');
    });
  });

  group('③ 接线：宿主在列表为空时把这块挂上去', () {
    test('★★ settings_page 里 SourcesEmptyState 的 isEmpty 来自列表长度', () {
      final src = File('lib/ui/settings_page.dart').readAsStringSync();
      expect(src.contains('SourcesEmptyState('), isTrue,
          reason: '★ 组件做好了但宿主不挂 ⇒ 用户仍然看不到提示');
      final i = src.indexOf('SourcesEmptyState(');
      final seg = src.substring(i, (i + 200).clamp(0, src.length));
      expect(seg.contains('isEmpty:'), isTrue, reason: '★ 必须把空态传进去');
      expect(RegExp(r'isEmpty:\s*list\.isEmpty').hasMatch(seg), isTrue,
          reason: '★★ isEmpty 必须来自**真实列表长度**（不许写死 true/false）');
    });
  });
}
