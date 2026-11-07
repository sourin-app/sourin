@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const _episodes = [
  Episode(id: 'A1', title: '第1集', index: 0),
  Episode(id: 'A2', title: '第2集', index: 1),
];

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(seconds: 3));
  }
}

Future<MediaSession> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    const MaterialApp(
      home: PlayerPage(
        provider: 'timeline-fixture',
        id: 'series',
        title: 'Timeline fixture',
        episodes: _episodes,
        episodeIndex: 0,
        episodeId: 'A1',
      ),
    ),
  );
  await tester.pump();
  expect(debugPlayerForceBarsForShot(), isTrue);
  debugPlayerPushDurationForProbe(const Duration(seconds: 75));
  debugPlayerPushPositionForProbe(const Duration(seconds: 6));
  await tester.pump();
  expect(
    tester
        .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
        .position,
    const Duration(seconds: 6),
  );
  expect(
    find.descendant(
      of: find.byType(PlayerBottomBar),
      matching: find.text('00:06'),
    ),
    findsOneWidget,
  );
  return tester.state(find.byType(PlayerPage)) as MediaSession;
}

void main() {
  setUpAll(() {
    final native = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(native.existsSync(), isTrue);
    MediaKit.ensureInitialized(libmpv: native.absolute.path);
  });
  setUp(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async =>
        [];
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinCore.debugCallAsyncTransport = (command, arguments) async {
      if (command == 'get_progress') return null;
      if (command == 'pan_cleanup_temp') return <String, dynamic>{};
      throw SourinCoreException('Unarmed fixture has no data', 'other');
    };
  });
  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
  });

  for (final transition in ['episode', 'session', 'source']) {
    testWidgets('$transition transition resets displayed progress immediately', (
      tester,
    ) async {
      final resolution = Completer<List<StreamCandidate>>();
      Future<bool>? changing;
      try {
        final state = await _mount(tester);
        SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) =>
            resolution.future;
        changing = switch (transition) {
          'episode' => debugPlayerGotoEpisodeForProbe(_episodes[1]),
          'session' => debugPlayerApplySessionForProbe(
            const PlayRequestData(
              provider: 'timeline-fixture',
              id: 'series',
              title: 'Timeline fixture',
              episodeId: 'A2',
              episodeIndex: 1,
              episodes: _episodes,
            ),
          ),
          _ => debugPlayerApplySwitchForProbe(
            provider: 'timeline-source',
            id: 'other-series',
            detail: const MediaDetail(
              id: 'other-series',
              title: 'Source fixture',
              episodes: _episodes,
            ),
          ),
        };
        await tester.pump();
        expect(identical(tester.state(find.byType(PlayerPage)), state), isTrue);
        expect(state.currentEpisodeId, transition == 'source' ? 'A1' : 'A2');
        expect(state.currentPosition, Duration.zero);
        expect(resolution.isCompleted, isFalse);

        // Reveal the actual transport after the pending resolver's loading UI.
        // This helper changes visibility/duration, never either position value.
        expect(debugPlayerForceBarsForShot(), isTrue);
        debugPlayerPushDurationForProbe(const Duration(seconds: 75));
        await tester.pump();
        expect(
          tester
              .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
              .position,
          Duration.zero,
          reason: 'New media must not display the previous media position.',
        );
        expect(
          find.descendant(
            of: find.byType(PlayerBottomBar),
            matching: find.text('00:00'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(PlayerBottomBar),
            matching: find.text('00:06'),
          ),
          findsNothing,
        );

        // A subsecond first position must also leave the transport at 00:00.
        debugPlayerPushPositionForProbe(const Duration(milliseconds: 200));
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(PlayerBottomBar),
            matching: find.text('00:00'),
          ),
          findsOneWidget,
        );
        debugPlayerPushPositionForProbe(const Duration(milliseconds: 1200));
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(PlayerBottomBar),
            matching: find.text('00:01'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!resolution.isCompleted) resolution.complete([]);
        await tester.pump();
        if (changing != null) await changing;
        await _unmount(tester);
      }
    });
  }

  testWidgets('same-session metadata refresh retains displayed progress', (
    tester,
  ) async {
    try {
      await _mount(tester);
      expect(
        await debugPlayerApplySessionForProbe(
          const PlayRequestData(
            provider: 'timeline-fixture',
            id: 'series',
            title: 'Updated title',
            episodes: _episodes,
            episodeIndex: 0,
            episodeId: 'A1',
          ),
        ),
        isTrue,
      );
      await tester.pump();
      expect(
        tester
            .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
            .position,
        const Duration(seconds: 6),
      );
      expect(
        find.descendant(
          of: find.byType(PlayerBottomBar),
          matching: find.text('00:06'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester);
    }
  });
}
