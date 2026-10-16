// ★ 可视化编排器接线门禁（Owner 第 9 条）
// ignore_for_file: avoid_print
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/provider_import_dialog.dart';


void main() {
  testWidgets('composer wired', (t) async {
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      builder: (c, ch) =>
          AppThemeHost(data: AppTheme.themeFor(Brightness.dark), child: ch ?? const SizedBox()),
      home: Scaffold(
        backgroundColor: const Color(0xFF101014),
        body: Builder(builder: (c) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            await ProviderImportDialog.showAdd(c);
          });
          return const SizedBox();
        }),
      ),
    ));
    await t.pumpAndSettle();
    // 找到「可视化编排」按钮
    expect(find.text('可视化编排'), findsOneWidget, reason: '入口按钮必须存在');

    // ★★ 关键：**能点**才算接线成功。只断言"存在"会漏掉 onPressed: null，
    //    那正是本条门禁第一版的假绿（故障注入实测 +1 passed）。
    final btn = t.widget<TextButton>(
      find.ancestor(
        of: find.text('可视化编排'),
        matching: find.byType(TextButton),
      ),
    );
    expect(btn.onPressed, isNotNull,
        reason: '★★ 按钮存在但 onPressed 为 null ⇒ 点了没反应，等于没接线');
    await t.tap(find.text('可视化编排'));
    await t.pumpAndSettle();
    expect(find.text('可视化编排'), findsWidgets);
    });
}
