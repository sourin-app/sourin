import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/theme_page.dart';

void main() {
  testWidgets('appearance changes mode in place with an interactive preview', (t) async {
    UiPrefs.debugResetForTest();
    addTearDown(UiPrefs.debugResetForTest);
    final theme = AppTheme.themeFor(Brightness.dark);
    await t.pumpWidget(MaterialApp(theme: theme,
      builder: (context, child) => AppThemeHost(data: theme, child: child!),
      home: const Scaffold(body: ThemeSettingsPage())));
    await t.pumpAndSettle();
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.byType(ThemeGrid), findsNothing);
    expect(find.text('粘贴 JSON'), findsNothing);
    await t.tap(find.text('浅色'));
    await t.pumpAndSettle();
    expect(AppTheme.mode, AppThemeMode.light);
    expect(find.byType(ThemeSettingsPage), findsOneWidget);
    final preview = find.byType(miuix.MiuixSwitchPreference);
    expect(t.widget<miuix.MiuixSwitchPreference>(preview).value, isTrue);
    await t.tap(find.text('试试开关'));
    await t.pumpAndSettle();
    expect(t.widget<miuix.MiuixSwitchPreference>(preview).value, isFalse);
    expect(t.takeException(), isNull);
  });
}
