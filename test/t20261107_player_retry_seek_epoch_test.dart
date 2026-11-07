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
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const _episode = Episode(id: 'episode-1', title: 'Episode 1', index: 0);
const _target = Duration(seconds: 42);
const _duration = Duration(seconds: 180);

Future<MediaSession> _mountInactivePlayer(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() async {
    debugPlayerSetResumeSeekForProbe(null);
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });
  await tester.pumpWidget(
    const MaterialApp(
      home: PlayerPage(
        provider: 'retry-fixture',
        id: 'series',
        title: 'Retry epoch fixture',
        episodes: [_episode],
        episodeIndex: 0,
        episodeId: 'episode-1',
      ),
    ),
  );
  await tester.pump();
  expect(debugPlayerSessionKeyForProbe(), 'retry-fixture:series');
  expect(debugPlayerLoadCallsForProbe(), 1);
  expect(debugPlayerStartPlaybackCallsForProbe(), 0);
  final state = tester.state(find.byType(PlayerPage));
  expect(state, isA<MediaSession>());
  final session = state as MediaSession;
  expect(session.currentEpisodeId, _episode.id);
  return session;
}

void main() {
  setUpAll(() {
    final native = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(native.existsSync(), isTrue, reason: 'Native fixture is required.');
    MediaKit.ensureInitialized(libmpv: native.absolute.path);
  });

  setUp(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async => [];
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinCore.debugCallAsyncTransport = (command, arguments) async {
      if (command == 'get_progress') return null;
      if (command == 'pan_cleanup_temp') return <String, dynamic>{};
      throw SourinCoreException('Unarmed fixture has no data', 'other');
    };
  });

  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSetResumeSeekForProbe(null);
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
  });

  testWidgets(
    'ordinary retry invalidates an older resume waiter before resolve completes',
    (tester) async {
      final originalState = await _mountInactivePlayer(tester);
      final nativeSeeks = <Duration>[];
      expect(
        debugPlayerSetResumeSeekForProbe((target) async {
          nativeSeeks.add(target);
        }),
        isTrue,
      );

      // This starts the real production waiter, including its original token.
      final oldWaiter = debugPlayerStartResumeWaitForProbe(_target);
      expect(debugPlayerPendingSeekForProbe(), _target);
      final resolverEntered = Completer<void>();
      final resolution = Completer<List<StreamCandidate>>();
      var retryCompleted = false;
      SourinApi.debugResolveStreamFetcher = (
        provider,
        id, {
        PlayRequest? req,
      }) {
        resolverEntered.complete();
        expect(provider, 'retry-fixture');
        expect(id, 'series');
        expect(req?.episodeId, _episode.id);
        return resolution.future;
      };
      final retry = debugPlayerLoadForProbe().then((completed) {
        retryCompleted = true;
        return completed;
      });

      try {
        await resolverEntered.future;
        expect(resolution.isCompleted, isFalse);
        expect(retryCompleted, isFalse);
        expect(debugPlayerLoadCallsForProbe(), 2);
        expect(debugPlayerStartPlaybackCallsForProbe(), 0);
        expect(
          identical(tester.state(find.byType(PlayerPage)), originalState),
          isTrue,
        );
        expect(originalState.currentEpisodeId, _episode.id);

        // Deliver metadata while retry still awaits resolve, not after open.
        debugPlayerPushDurationForProbe(_duration);
        await tester.pump(const Duration(milliseconds: 250));
        expect(await oldWaiter, isTrue);
        expect(resolution.isCompleted, isFalse);
        expect(retryCompleted, isFalse);
        expect(
          nativeSeeks,
          isEmpty,
          reason:
              'Retry must invalidate the old waiter before its resolve await.',
        );
        expect(
          debugPlayerPendingSeekForProbe(),
          _target,
          reason: 'Old finally must not clear the current retry intent.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        if (!resolution.isCompleted) {
          resolution.complete(<StreamCandidate>[]);
        }
        await tester.pump();
        expect(await retry, isTrue);
        debugPlayerPushDurationForProbe(_duration);
        await tester.pump(const Duration(milliseconds: 250));
        await oldWaiter;
      }
    },
  );

  testWidgets(
    'an uncanceled current resume waiter still issues exactly one native seek',
    (tester) async {
      final originalState = await _mountInactivePlayer(tester);
      final nativeSeeks = <Duration>[];
      expect(
        debugPlayerSetResumeSeekForProbe((target) async {
          nativeSeeks.add(target);
        }),
        isTrue,
      );

      final waiter = debugPlayerStartResumeWaitForProbe(_target);
      try {
        debugPlayerPushDurationForProbe(_duration);
        await tester.pump(const Duration(milliseconds: 250));
        expect(await waiter, isTrue);
        expect(nativeSeeks, [_target]);
        expect(debugPlayerPendingSeekForProbe(), isNull);
        expect(debugPlayerLoadCallsForProbe(), 1);
        expect(
          identical(tester.state(find.byType(PlayerPage)), originalState),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugPlayerPushDurationForProbe(_duration);
        await tester.pump(const Duration(milliseconds: 250));
        await waiter;
      }
    },
  );
}
