import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/app_logo.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/theme_page.dart';
import 'package:sourin_spike/ui/widgets/app_logo.dart';

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    AppLogoPreference.load();
  });
  tearDown(() {
    UiPrefs.debugResetForTest();
    AppLogoPreference.load();
  });

  testWidgets('appearance selection updates rendered logo and survives reload', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('sourin-logo-');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.runAsync(() => UiPrefs.load(dir.path));
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (context, child) => AppThemeHost(data: theme, child: child!),
        home: const Scaffold(
          body: Column(
            children: [
              AppLogo(),
              Expanded(child: ThemeSettingsPage()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    String renderedAsset() =>
        (tester
                    .widget<Image>(
                      find.descendant(
                        of: find.byType(AppLogo),
                        matching: find.byType(Image),
                      ),
                    )
                    .image
                as AssetImage)
            .assetName;
    expect(renderedAsset(), 'assets/logos/01-orbit.png');
    for (final id in ['02-frames', '03-current', '04-screen', '01-orbit']) {
      await tester.tap(find.byKey(ValueKey('app-logo-$id')));
      // Flush before fake time advances the debounce into an async disk write.
      await tester.runAsync(() => UiPrefs.flush());
      await tester.pumpAndSettle();
      expect(renderedAsset(), 'assets/logos/$id.png');
      await tester.runAsync(() async {
        final stored = jsonDecode(
          await File('${dir.path}/ui-prefs.json').readAsString(),
        );
        expect(stored['dsh.appearance.logo'], id);
        UiPrefs.debugResetForTest();
        AppLogoPreference.load();
        await UiPrefs.load(dir.path);
        AppLogoPreference.load();
      });
      await tester.pumpAndSettle();
      expect(renderedAsset(), 'assets/logos/$id.png');
    }
    expect(tester.takeException(), isNull);
  });

  test('unknown saved logo falls back to the approved default', () {
    UiPrefs.debugResetForTest({'dsh.appearance.logo': 'removed-logo'});
    AppLogoPreference.load();
    expect(AppLogoPreference.current.value, AppLogoStyle.orbit);
  });
}
