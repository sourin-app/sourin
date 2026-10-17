// 临时：可视化编排器出图（跑完删）
// ignore_for_file: avoid_print
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/source_composer_dialog.dart';

import 'support/ui_shot.dart';

Future<void> pump(WidgetTester t, Brightness b) async {
  await setShotViewport(t, const Size(960, 900));
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeFor(b),
    builder: (c, ch) =>
        AppThemeHost(data: AppTheme.themeFor(b), child: ch ?? const SizedBox()),
    home: Scaffold(
      backgroundColor:
          b == Brightness.dark ? const Color(0xFF101014) : const Color(0xFFEEF0F6),
      body: const Stack(children: [SourceComposerDialog()]),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);
  for (final b in [Brightness.dark, Brightness.light]) {
    final tag = b == Brightness.dark ? 'dark' : 'light';
    testWidgets('composer-step1-' + tag, (t) async {
      await pump(t, b);
      await saveViewShot(t, 'composer_1_site_' + tag);
    });
    testWidgets('composer-step2-' + tag, (t) async {
      await pump(t, b);
      await t.tap(find.text('下一步'));
      await t.pumpAndSettle();
      // 勾三个端点
      final cbs = find.byType(CheckboxListTile);
      for (var i = 0; i < 3; i++) {
        await t.tap(cbs.at(i));
        await t.pumpAndSettle();
      }
      await saveViewShot(t, 'composer_2_endpoints_' + tag);
    });
    testWidgets('composer-step3-' + tag, (t) async {
      await pump(t, b);
      await t.tap(find.text('下一步'));
      await t.pumpAndSettle();
      final cbs = find.byType(CheckboxListTile);
      for (var i = 0; i < 3; i++) {
        await t.tap(cbs.at(i));
        await t.pumpAndSettle();
      }
      await t.tap(find.text('下一步'));
      await t.pumpAndSettle();
      await saveViewShot(t, 'composer_3_mapping_' + tag);
    });
  }
}
