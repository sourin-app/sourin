import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/theme_page.dart';

void main() {
  testWidgets('theme 大预览：统一外壳 + 显式 maxWidth 560 + Material 宿主',
      (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1400, 1000);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: const Scaffold(body: ThemeSettingsPage()),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 800));

    // 内置主题包恒存在 ⇒ 卡片与预览入口应渲染
    final eye = find.byIcon(Icons.visibility_outlined);
    expect(eye, findsWidgets, reason: '内置主题包应渲染预览入口');

    await t.tap(eye.first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 900));

    expect(find.byType(AppGlassDialog), findsOneWidget,
        reason: '大预览必须走统一外壳（第 18 项迁移）');
    final dlg = t.widget<AppGlassDialog>(find.byType(AppGlassDialog));
    expect(dlg.maxWidth, 560,
        reason: '内容固定 460 宽 ⇒ 必须显式传 560（§3.5 白名单档）');
    // 机制②：预览含 Switch，必须就地补 Material 宿主
    expect(
      find.descendant(
        of: find.byType(AppGlassDialog),
        matching: find.byType(Material),
      ),
      findsWidgets,
      reason: 'Switch 需要 Material 祖先，必须在调用点补',
    );
    expect(t.takeException(), isNull, reason: '打开不许抛');
    expect(find.text('用这套'), findsOneWidget);
  });
}
