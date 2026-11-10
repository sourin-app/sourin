@Tags(['native-media'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/remote_bridge.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

Future<DanmakuSearchPage> _openSearch(WidgetTester tester) async {
  // Keep stream failure outside this entry/lifecycle fixture, then follow the
  // actual gear and quick-panel details buttons from the mounted player tree.
  expect(debugPlayerForceBarsForShot(), isTrue);
  await tester.pump();
  final gear = find.descendant(
    of: find.byKey(PlayerBottomBar.danmakuSettingsKey),
    matching: find.byType(ui.TextButton),
  );
  expect(gear, findsOneWidget);
  tester.widget<ui.TextButton>(gear).onPressed!();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsOneWidget);
  final details = find.descendant(
    of: find.byKey(PlayerBottomBar.danmakuQuickSearchKey),
    matching: find.byType(ui.TextButton),
  );
  expect(details, findsOneWidget);
  final button = tester.widget<ui.TextButton>(details);
  expect(button.onPressed, isNotNull);
  button.onPressed!();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsNothing);
  expect(find.byType(DanmakuSearchPage), findsOneWidget);
  return tester.widget<DanmakuSearchPage>(find.byType(DanmakuSearchPage));
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets(
    'quick settings production callback mounts search and Escape closes it',
    (t) async {
      await fixture.mountPlayer(t);
      await _openSearch(t);
      expect(find.byType(DanmakuSearchPage), findsOneWidget);
      expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsNothing);
      expect(find.byType(DanmakuSettingsDialog), findsNothing);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(find.byType(DanmakuSearchPage), findsNothing);
      await fixture.drain(t);
    },
  );

  testWidgets('search close callback unmounts the real search page', (t) async {
    await fixture.mountPlayer(t);
    final search = await _openSearch(t);
    search.onClose();
    await t.pump();
    expect(find.byType(DanmakuSearchPage), findsNothing);
    await fixture.drain(t);
  });
}
