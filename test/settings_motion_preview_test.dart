import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';
import 'package:sourin_spike/ui/widgets/settings_motion_panel.dart';

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    PageTransitionStyleStore.syncFromPrefs();
  });
  tearDown(() {
    UiPrefs.debugResetForTest();
    PageTransitionStyleStore.syncFromPrefs();
  });
  for (final reduced in [false, true]) {
    testWidgets('settings preview and actual route respect reduced=$reduced', (
      t,
    ) async {
      final theme = AppTheme.themeFor(Brightness.light);
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: AppThemeHost(data: theme, child: child!),
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: SettingsMotionPanel()),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('上滑').first);
      await t.pump();
      expect(UiPrefs.get(PageTransitionStyleStore.prefKey), 'slideUp');
      final card = find.byKey(const ValueKey('motion-preview-card'));
      final start = t.getTopLeft(card);
      await t.pumpAndSettle();
      final end = t.getTopLeft(card);
      if (reduced) {
        expect(start.dy, end.dy);
        expect(find.textContaining('系统已关闭动态效果'), findsOneWidget);
      } else {
        expect(start.dy, greaterThan(end.dy + 2));
      }
      await t.tap(find.text('试试页面切换'));
      await t.pumpAndSettle();
      expect(find.text('动画预览'), findsOneWidget);
      Navigator.of(t.element(find.text('动画预览'))).pop();
      await t.pumpAndSettle();
      expect(find.byType(SettingsMotionPanel), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
