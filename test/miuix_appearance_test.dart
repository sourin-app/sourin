import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/theme_page.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';
import 'package:sourin_spike/ui/widgets/settings_kit.dart';

void main() {
  setUp(() => UiPrefs.debugResetForTest());
  tearDown(() => UiPrefs.debugResetForTest());

  test('legacy pack cannot override product brightness or split window colors', () {
    ThemePackStore.select('builtin.sakura');
    for (final brightness in Brightness.values) {
      final theme = AppTheme.themeFor(brightness);
      final palette = AppTheme.colorsFor(brightness);
      expect(theme.brightness, brightness);
      expect(palette.brightness, brightness);
      expect(theme.scaffoldBackgroundColor, palette.background);
      expect(theme.colorScheme.primary, palette.primary);
      ThemePackStore.select('builtin.oled');
      expect(AppTheme.themeFor(brightness).colorScheme, theme.colorScheme);
    }
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets('appearance uses actual Miuix controls at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ValueListenableBuilder<int>(
        valueListenable: appThemeRevision,
        builder: (context, _, child) {
          final b = AppTheme.resolve(systemBrightness: Brightness.light);
          final theme = AppTheme.themeFor(b);
          return MaterialApp(theme: theme, themeAnimationDuration: Duration.zero,
            builder: (context, child) => AppThemeHost(data: theme, child: child!),
            home: const Scaffold(body: ThemeSettingsPage()));
        },
      ));
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixCard), findsNWidgets(2));
      expect(find.byType(miuix.MiuixSwitchPreference), findsOneWidget);
      expect(find.byType(ThemeGrid), findsNothing);
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(ThemeSettingsPage));
      expect(AppTheme.mode, AppThemeMode.dark);
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(miuix.MiuixTheme.of(context).brightness, Brightness.dark);
      final switchFinder = find.byType(miuix.MiuixSwitchPreference);
      expect(tester.widget<miuix.MiuixSwitchPreference>(switchFinder).value, isTrue);
      await tester.tap(find.text('试试开关'));
      await tester.pumpAndSettle();
      expect(tester.widget<miuix.MiuixSwitchPreference>(switchFinder).value, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Miuix option button activates with keyboard', (tester) async {
    var clicked = 0;
    await tester.pumpWidget(MaterialApp(home: AppThemeHost(
      data: AppTheme.themeFor(Brightness.light),
      child: Scaffold(body: SettingsGesturePill(text: 'Option', selected: false,
        onTap: () => clicked++)),
    )));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(clicked, 1);
  });
}
