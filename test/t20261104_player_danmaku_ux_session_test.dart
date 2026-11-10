@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/miuix_finders.dart';

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

const _episodes = [
  Episode(id: 'e1', title: 'Episode One'),
  Episode(id: 'e2', title: 'Episode Two'),
];

Future<DanmakuSearchPage> _openSearch(WidgetTester tester) async {
  // The fixture has no playable stream. Expose its controls for setup, then
  // follow the currently mounted gear -> quick panel -> details callbacks.
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
  // The Miuix dialog registers its content with the local popup host after
  // layout; give that real content a frame before hit testing its Back button.
  await tester.pump();
  expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsNothing);
  expect(find.byType(DanmakuSearchPage), findsOneWidget);
  return tester.widget<DanmakuSearchPage>(find.byType(DanmakuSearchPage));
}

Future<MediaProgressSession> _mount(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });
  await tester.pumpWidget(
    const MaterialApp(
      home: MediaPage(
        provider: 'fixture',
        id: 'work',
        title: 'Work',
        episodes: _episodes,
        episodeId: 'e1',
        episodeTitle: 'Episode One',
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  final session = tester.state(find.byType(PlayerPage)) as MediaProgressSession;
  final detail = tester.widget<DetailPage>(find.byType(DetailPage));
  expect(
    identical(detail.playbackProgress, session.playbackProgress),
    isTrue,
    reason: 'The real MediaPage must connect the real player event stream',
  );
  (tester.state(find.byType(DetailPage)) as dynamic).debugSetDetail(
    const MediaDetail(id: 'work', title: 'Work', episodes: _episodes),
    episodes: _episodes,
  );
  await tester.pump();
  debugPlayerPushDurationForProbe(const Duration(seconds: 600));
  await tester.pump();
  return session;
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() {
    UiPrefs.debugResetForTest(<String, String>{});
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async =>
        [];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      if (command == 'pan_cleanup_temp' || command == 'save_progress')
        return {};
      throw SourinCoreException('No fixture data', 'other');
    };
  });
  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    debugPlayerSetUserSeekForProbe(null);
    SourinApi.debugSkipMarkerFetcher = null;
    SourinApi.debugResolveStreamFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    UiPrefs.debugResetForTest(<String, String>{});
  });

  testWidgets('actual player tick reaches the right detail owner', (
    tester,
  ) async {
    final session = await _mount(tester);
    debugPlayerPushPositionForProbe(const Duration(seconds: 480));
    await tester.pump();
    expect(session.playbackProgress.value!.position.inSeconds, 480);
    expect(find.textContaining('剩 2 分钟'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DetailPage),
        matching: find.text('Episode One'),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('seek completion cannot overwrite a newer native tick', (
    tester,
  ) async {
    final session = await _mount(tester);
    debugPlayerPushPositionForProbe(const Duration(seconds: 120));
    final pending = Completer<void>();
    debugPlayerSetUserSeekForProbe((_) => pending.future);
    debugPlayerUserSeekForProbe(const Duration(seconds: 480));
    await tester.pump();
    debugPlayerPushPositionForProbe(const Duration(seconds: 490));
    pending.complete();
    await tester.pump();
    expect(session.playbackProgress.value!.position.inSeconds, 490);
    expect((session as MediaSession).currentPosition.inSeconds, 490);
  });

  testWidgets(
    'a delayed seek from the previous episode cannot update the next',
    (tester) async {
      final session = await _mount(tester);
      debugPlayerPushPositionForProbe(const Duration(seconds: 120));
      final pending = Completer<void>();
      debugPlayerSetUserSeekForProbe((_) => pending.future);
      debugPlayerUserSeekForProbe(const Duration(seconds: 480));
      await tester.pump();
      await debugPlayerGotoEpisodeForProbe(_episodes[1]);
      await tester.pump();
      pending.complete();
      await tester.pump();
      expect(session.playbackProgress.value!.episodeId, 'e2');
      expect(session.playbackProgress.value!.position, Duration.zero);
      expect(find.text('上次看到 '), findsNothing);
    },
  );

  testWidgets('search returns to quick settings in the existing player', (
    tester,
  ) async {
    await _mount(tester);
    final owner = tester.state(find.byType(PlayerPage));
    await _openSearch(tester);
    expect(find.byType(DanmakuSearchPage), findsOneWidget);
    await tester.tap(miuixTooltip('返回弹幕设置'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(DanmakuSearchPage), findsNothing);
    expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsOneWidget);
    expect(find.byType(DanmakuSettingsDialog), findsNothing);
    expect(tester.state(find.byType(PlayerPage)), same(owner));
  });
}
