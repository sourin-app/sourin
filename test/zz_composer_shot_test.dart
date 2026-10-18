@Tags(['needs-shot-dir'])
// 临时：可视化编排器出图（跑完删）
// ignore_for_file: avoid_print
library;

/*
 * ⚠️ 2026-10-18（round-65 merge）：补上 `@Tags(['needs-shot-dir'])`。
 *
 * # 为什么必须补
 * 本文件是 PR #30 带进来的一次性**出图探针**（首行自己写着「跑完删」），
 * 但它**没打标签** ⇒ CI 的 `flutter test` 会**真的去跑它**。
 *
 * 而它里面写死了按旧 UI 找控件：
 * ```text
 * tap(find.text('下一步'))  ⇒  Found 0 widgets with text "下一步"
 * ```
 * 本分支的 SourceComposerDialog 已重做（PR#30 与本轮第 64 轮都动过它），
 * 「下一步」这个按钮不存在了 ⇒ 4 条断言必红。
 * 实测 CI：3808 通过 / 7 失败，**7 条全在这个文件**。
 *
 * # 为什么不删
 * 它是 main 已有的资产，删掉等于替别人做删除决定。
 * 加标签后：默认跑会 skip（exit 0），要出图时手动
 * `SOURIN_SHOT_DIR=... flutter test test/zz_composer_shot_test.dart`。
 * 这与本仓 t1009_polish_shots_test / t139_danmaku_info_panel_test 等
 * 截图工具的口径完全一致。
 *
 * # 遗留
 * 它引用的控件文案已过时，真要出图得先修 find.text('下一步')。
 * 那是出图工具的事，不影响产品，留作已知项。
 */

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
