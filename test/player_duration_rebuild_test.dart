@Tags(['native-media'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const _line = StreamCandidate(
  url: 'https://media.invalid/first.m3u8',
  kind: 'hls',
  label: '线路甲',
  playlistTotalMs: 82720,
  playlistDiscontinuous: true,
);
const _otherLine = StreamCandidate(
  url: 'https://media.invalid/second.m3u8',
  kind: 'hls',
  label: '线路乙',
  playlistTotalMs: 82720,
  playlistDiscontinuous: true,
);
const _plainLine = StreamCandidate(
  url: 'https://media.invalid/plain.mp4',
  kind: 'mp4',
  label: '普通线路',
);

int _pageBuilds = 0;
void _countBuilds() {
  _pageBuilds = 0;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (element.widget is PlayerPage) _pageBuilds++;
  };
}

String _key(StreamCandidate line) =>
    lineDurationKey(provider: 'fixture', contentId: 'work', s: line);

Future<void> _mount(WidgetTester tester, StreamCandidate line) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: const PlayerPage(
        provider: 'fixture',
        id: 'work',
        title: '播放时长',
        episodes: [Episode(id: 'ep1', title: '第1集')],
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: '第1集',
      ),
    ),
  );
  await tester.pump();
  expect(debugPlayerSetStreamsForProbe([line, _otherLine]), isTrue);
  expect(debugPlayerSetAggregateTitleForProbe(current: line), isTrue);
  expect(debugPlayerClearErrorForProbe(), isTrue);
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

Future<void> _finish(WidgetTester tester) async {
  debugOnRebuildDirtyWidget = null;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(
      dll.existsSync(),
      isTrue,
      reason: 'Explicit native-media run requires libmpv',
    );
    MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() {
    UiPrefs.debugResetForTest();
    Device.overrideKind(DeviceKind.desktop);
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      if (command == 'resolve_stream' || command == 'list_providers')
        return <dynamic>[];
      if (command == 'pan_cleanup_temp' ||
          command == 'end_yield_for_seek' ||
          command == 'save_progress') {
        return <String, dynamic>{};
      }
      throw SourinCoreException('隔离测试无数据', 'other');
    };
  });
  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    Device.overrideKind(null);
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    UiPrefs.debugResetForTest();
  });

  testWidgets(
    'changing segment duration leaves unchanged authoritative UI intact',
    (tester) async {
      await _mount(tester, _line);
      debugPlayerPushDurationForProbe(const Duration(seconds: 6));
      await tester.pump();
      expect(
        tester.widget<PlayerBottomBar>(find.byType(PlayerBottomBar)).duration,
        const Duration(milliseconds: 82720),
      );
      final starts = debugPlayerStartPlaybackCallsForProbe();
      final episode = debugPlayerEpisodeIndexForProbe();
      _countBuilds();
      for (final seconds in [4, 3, 6, 4, 3, 6, 4, 3]) {
        debugPlayerPushDurationForProbe(Duration(seconds: seconds));
        await tester.pump();
      }
      expect(
        _pageBuilds,
        0,
        reason: 'Distinct native values map to the same visible duration',
      );
      expect(debugPlayerLineDurationForProbe(_key(_line)), 82);
      expect(
        tester.widget<PlayerBottomBar>(find.byType(PlayerBottomBar)).duration,
        const Duration(milliseconds: 82720),
      );
      expect(debugPlayerStartPlaybackCallsForProbe(), starts);
      expect(debugPlayerEpisodeIndexForProbe(), episode);
      await _finish(tester);
    },
  );

  testWidgets('a new line with equal duration still records its own duration', (
    tester,
  ) async {
    await _mount(tester, _line);
    debugPlayerPushDurationForProbe(const Duration(seconds: 6));
    await tester.pump();
    expect(debugPlayerLineDurationForProbe(_key(_otherLine)), isNull);
    expect(debugPlayerSetAggregateTitleForProbe(current: _otherLine), isTrue);
    await tester.pump();
    _countBuilds();
    debugPlayerPushDurationForProbe(const Duration(seconds: 4));
    await tester.pump();
    expect(debugPlayerLineDurationForProbe(_key(_otherLine)), 82);
    expect(_pageBuilds, 0);
    await _finish(tester);
  });

  testWidgets('equal duration on a new short line updates its visible badge', (
    tester,
  ) async {
    const first = StreamCandidate(
      url: 'https://media.invalid/short-first.mp4',
      label: '短线路甲',
    );
    const second = StreamCandidate(
      url: 'https://media.invalid/short-second.mp4',
      label: '短线路乙',
    );
    await _mount(tester, first);
    debugPlayerSetStreamsForProbe([first, second]);
    debugPlayerPushDurationForProbe(const Duration(seconds: 20));
    await tester.pump();
    expect(debugPlayerSetAggregateTitleForProbe(current: second), isTrue);
    expect(debugPlayerOpenStreamSheetForProbe(), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('疑似样片 (0:20)'), findsOneWidget);
    _countBuilds();
    debugPlayerPushDurationForProbe(const Duration(seconds: 20));
    await tester.pump();
    expect(debugPlayerLineDurationForProbe(_key(second)), 20);
    expect(find.text('疑似样片 (0:20)'), findsNWidgets(2));
    expect(_pageBuilds, 1, reason: 'The newly learned line badge changed');
    _countBuilds();
    debugPlayerPushDurationForProbe(const Duration(seconds: 20));
    await tester.pump();
    expect(
      _pageBuilds,
      0,
      reason: 'Repeated identical cache/UI values are idle',
    );
    await _finish(tester);
  });

  testWidgets(
    'true duration changes render and zero keeps last real duration for progress',
    (tester) async {
      await _mount(tester, _plainLine);
      final starts = debugPlayerStartPlaybackCallsForProbe();
      for (final duration in [
        const Duration(seconds: 18),
        const Duration(milliseconds: 18250),
        const Duration(milliseconds: 18750),
        Duration.zero,
        const Duration(seconds: 25),
      ]) {
        final progress =
            tester.state(find.byType(PlayerPage)) as MediaProgressSession;
        final before = progress.playbackProgress.value;
        _countBuilds();
        debugPlayerPushDurationForProbe(duration);
        await tester.pump();
        expect(_pageBuilds, 1, reason: 'The actual duration changed');
        expect(
          tester.widget<PlayerBottomBar>(find.byType(PlayerBottomBar)).duration,
          duration,
        );
        if (duration > Duration.zero) {
          expect(
            debugPlayerLineDurationForProbe(_key(_plainLine)),
            duration.inSeconds,
          );
        } else {
          expect(debugPlayerLineDurationForProbe(_key(_plainLine)), 18);
          expect(progress.playbackProgress.value, same(before));
          // Progress snapshots publish on whole-second boundaries. Advance
          // position to verify the precise last usable duration survived zero.
          debugPlayerPushPositionForProbe(const Duration(seconds: 1));
          await tester.pump();
          expect(
            progress.playbackProgress.value?.duration,
            const Duration(milliseconds: 18750),
          );
        }
      }
      expect(debugPlayerStartPlaybackCallsForProbe(), starts);
      await _finish(tester);
    },
  );
}
