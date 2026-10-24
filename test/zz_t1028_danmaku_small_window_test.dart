import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import '../lib/core/ui_prefs.dart';
import '../lib/ui/widgets/danmaku_settings_dialog.dart';

void main() {
  setUp(() => UiPrefs.debugResetForTest(<String, String>{}));
  tearDown(() => UiPrefs.debugResetForTest(<String, String>{}));

  testWidgets('small window bounds settings and keeps advanced content scrollable', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 360);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DanmakuSettingsDialog(
      state: const DanmakuSettingsState(enabled: true, appId: '', appSecret: '',
        fontScale: 1, opacity: 0.9, speed: 1, area: 0.5),
      onSetEnabled: (_) {}, onSetFontScale: (_) {}, onSetOpacity: (_) {},
      onSetSpeed: (_) {}, onSetArea: (_) {}, onReload: () {}, onClose: () {},
      onOpenSearch: () {}, fill: false,
    ))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final scroll = find.byKey(const ValueKey('danmaku-settings-scroll'));
    expect(scroll, findsOneWidget);
    expect(tester.getSize(scroll).height, lessThanOrEqualTo(360));
    await tester.ensureVisible(find.text('高级').first);
    await tester.tap(find.text('高级').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(scroll, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
