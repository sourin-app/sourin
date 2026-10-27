// R2-#2「聚合源不能编辑链接」—— **渲染级**端到端探针（Owner 第二次反馈后）
// 跑法：flutter test --concurrency=1 test/zz_t1070_r2_agg_link_e2e_test.dart
//
// # 为什么还要这条（源码门禁 zz_t1069 已 +5 全绿）
// ```text
// Owner 说"**还是**不能编辑" ⇒ 我已修三处门控（源码门禁 + 3 条注入全红）。
// 但源码门禁只能证"代码里有那三处"，**证不了"改完真的存得下去"**。
// ⇒ 本条走**真实渲染 + 真实交互**：mount 真面板 → 找输入框 → 改文字 → 点保存
//   → 断言 `linkSaver` 真收到了新值。
// ```
//
// # 为什么 mount `TvboxSourceManagePanel` 而不是整个 `TvboxAggregatePage`
// ```text
// `TvboxAggregatePage` 的构造只接受 `showCredentialPanels`，**没有**给链接读写留测试缝
//   ⇒ 直接 mount 它就得打真网（违反"测试不打真网"）。
// 而链接编辑的**真正承载者**是 `TvboxSourceManagePanel`，它**有** `sourceUrl` / `linkSaver`
// 两个测试缝 ⇒ mount 它既是**真实组件**（不是复制品），又能完全隔离外部依赖。
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

void main() {
  /// mount 真面板（链接读写全走测试缝 ⇒ 不打真网、不写盘）
  Future<void> mount(
    WidgetTester tester, {
    required List<String> saved,
    String? initialUrl,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TvboxSourceManagePanel(
              id: 'tvbox_agg',
              name: 'TVBox 聚合',
              sourceUrl: initialUrl,
              linkSaver: (id, url) async => saved.add('$id=$url'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('R2-#2 · 聚合源「编辑链接」（渲染级端到端）', () {
    testWidgets('★★★ 面板里真的有**可编辑**的链接输入框', (tester) async {
      await mount(tester, saved: <String>[]);
      final editables = find.byType(EditableText).evaluate().length;
      // ignore: avoid_print
      debugPrint('[E2E] 可编辑控件数 = $editables');
      expect(
        editables,
        greaterThan(0),
        reason: '★★★ 必须有**可编辑**的链接框 —— Owner 报"不能编辑链接"，'
            '若这里只有只读 Text 就是不达标',
      );
    });

    testWidgets('★★★ 改文字 + 点保存 ⇒ linkSaver 收到**我输入的那条**', (tester) async {
      final saved = <String>[];
      await mount(tester, saved: saved);
      final target = find.byType(EditableText).first;
      await tester.tap(target);
      await tester.pumpAndSettle();
      await tester.enterText(target, 'https://example.invalid/new-sub.txt');
      await tester.pumpAndSettle();
      /*
       * ★★ 按钮文案是**两态**的（我第一版只找「保存」⇒ 假红）：
       *   `_hasLink ? '保存' : '填入'` —— 初始没有链接时显示「**填入**」。
       * ⇒ 判据必须认**两种**（否则会在"首次填写"这个最常见的路径上漏判，
       *   而那正是 Owner 要用的路径）。
       * ★ 这与本批"判据的触发条件比实际窄"同族 —— 这次是我自己的探针踩的。
       */
      final save = find.text('保存');
      final fill = find.text('填入');
      final btn = save.evaluate().isNotEmpty ? save : fill;
      expect(btn.evaluate().isNotEmpty, isTrue,
          reason: '★ 必须有「保存」或「填入」入口（文案是 `_hasLink ? 保存 : 填入`）—— '
              '否则"能编辑"没有落地点');
      await tester.tap(btn.first);
      await tester.pumpAndSettle();
      // ignore: avoid_print
      debugPrint('[E2E] linkSaver 收到 = $saved');
      expect(saved, isNotEmpty,
          reason: '★★★ 点保存后 `linkSaver` **必须**被调用 —— '
              '否则"改了存不下去"，Owner 会读作"不能编辑"');
      expect(saved.last.contains('example.invalid/new-sub.txt'), isTrue,
          reason: '★★ 保存的必须是**我刚输入的那条**（不是旧值/空串）。实际：${saved.last}');
    });

    testWidgets('★★ 已有链接时，输入框**预填**了现值（不是空的）', (tester) async {
      await mount(tester, saved: <String>[],
          initialUrl: 'https://example.invalid/old-sub.txt');
      final w = tester.widget<EditableText>(find.byType(EditableText).first);
      // ignore: avoid_print
      debugPrint('[E2E] 输入框现值 = "${w.controller.text}"');
      expect(
        w.controller.text.contains('old-sub.txt'),
        isTrue,
        reason: '★★ 有链接时必须**预填**现值 —— 否则用户看不到当前链接，'
            '「编辑」会变成"重新输入一条"，容易存错',
      );
    });
  });
}