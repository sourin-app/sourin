@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 't102_playback_failure_banner_test.dart' as fixture;

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('automatic startup still seeks to intro end', (t) async {
    await fixture.mountPlayer(t);
    expect(debugPlayerSetAutoSkipForProbe(true), isTrue);
    expect(debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 69), isTrue);
    debugPlayerResetSkipProbe();
    expect(debugPlayerMaybeSkipForProbe(Duration.zero), isTrue);
    expect(debugPlayerSkipSeekCalls(), 1);
    expect(debugPlayerLastSkipSeek(), const Duration(seconds: 69));
    await fixture.drain(t);
  });

  testWidgets('real bottom bar manual seek to zero suppresses automatic intro', (t) async {
    await fixture.mountPlayer(t);
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue);
    debugPlayerHoverControlsForProbe();
    await t.pump();
    expect(debugPlayerSetAutoSkipForProbe(true), isTrue);
    expect(debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 69), isTrue);
    debugPlayerResetSkipProbe();
    final bar = t.widget<PlayerBottomBar>(find.byType(PlayerBottomBar));
    bar.onSeek(Duration.zero);
    expect(debugPlayerMaybeSkipForProbe(Duration.zero), isTrue);
    expect(debugPlayerSkipSeekCalls(), 0);
    expect(debugPlayerLastSkipSeek(), isNull);
    await fixture.drain(t);
  });

  for (final command in ['seek_to', 'skip_preview']) {
    testWidgets('remote $command to zero suppresses automatic intro', (t) async {
      await fixture.mountPlayer(t);
      RemoteBridge.instance.setGlobals(GlobalBridge(
        search: (_) async {},
        loadHome: () async {},
      ));
      expect(debugPlayerSetDurationForProbe(const Duration(minutes: 10)), isTrue);
      expect(debugPlayerSetAutoSkipForProbe(true), isTrue);
      expect(debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 69), isTrue);
      debugPlayerResetSkipProbe();
      // Dispatch through the production bridge. The fixture has no open media,
      // so native seek completion is not a valid synchronization point here.
      // User-intent protection must run synchronously before that native await.
      final commandFuture = RemoteBridge.instance.execCommandForTest(
        RemoteCommand(command, {'position': 0}),
      );
      commandFuture.ignore();
      expect(debugPlayerMaybeSkipForProbe(Duration.zero), isTrue);
      expect(debugPlayerSkipSeekCalls(), 0,
          reason: 'Remote user intent must suppress automatic intro seek.');
      expect(debugPlayerLastSkipSeek(), isNull);
      await fixture.drain(t);
    });
  }

  for (final command in ['seek_to', 'skip_preview']) {
    testWidgets('remote $command waits for seek completion', (t) async {
      await fixture.mountPlayer(t);
      RemoteBridge.instance.setGlobals(GlobalBridge(
        search: (_) async {},
        loadHome: () async {},
      ));
      debugPlayerSetDurationForProbe(const Duration(minutes: 10));
      final seek = Completer<void>();
      var calls = 0;
      debugPlayerSetUserSeekForProbe((_) {
        calls++;
        return seek.future;
      });
      var completed = false;
      final result = RemoteBridge.instance.execCommandForTest(
        RemoteCommand(command, {'position': 0}),
      ).then((_) => completed = true);
      await t.pump();
      expect(calls, 1);
      final completedBeforeSeek = completed;
      seek.complete();
      await result;
      expect(completedBeforeSeek, isFalse,
          reason: 'Remote command must await the native seek Future.');
      expect(completed, isTrue);
      await fixture.drain(t);
    });

    testWidgets('remote $command propagates seek failure', (t) async {
      await fixture.mountPlayer(t);
      RemoteBridge.instance.setGlobals(GlobalBridge(
        search: (_) async {},
        loadHome: () async {},
      ));
      debugPlayerSetDurationForProbe(const Duration(minutes: 10));
      final seek = Completer<void>();
      // Observe the native Future too, so a dropped Future is a failed
      // propagation assertion rather than an unrelated uncaught-zone error.
      seek.future.ignore();
      debugPlayerSetUserSeekForProbe((_) => seek.future);
      Object? received;
      final result = RemoteBridge.instance.execCommandForTest(
        RemoteCommand(command, {'position': 0}),
      ).then<void>((_) {}, onError: (Object e, StackTrace _) {
        received = e;
      });
      final failure = StateError('fixture seek failure');
      seek.completeError(failure);
      await result;
      await t.pump();
      expect(received, same(failure),
          reason: 'Remote command must preserve seek error propagation.');
      await fixture.drain(t);
    });
  }

  for (final switchSession in [false, true]) {
    testWidgets('resume waiter ${switchSession ? "rejects previous session seek" : "seeks within the same session"}', (t) async {
      final previousResolver = SourinApi.debugResolveStreamFetcher;
      final previousMarkerFetcher = SourinApi.debugSkipMarkerFetcher;
      addTearDown(() {
        SourinApi.debugResolveStreamFetcher = previousResolver;
        SourinApi.debugSkipMarkerFetcher = previousMarkerFetcher;
      });
      // Control only core transport; keep production session and resume logic.
      SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
      await fixture.mountPlayer(t);
      final seeks = <Duration>[];
      expect(debugPlayerSetResumeSeekForProbe((target) async {
        seeks.add(target);
      }), isTrue);
      const target = Duration(seconds: 120);
      final waiter = debugPlayerStartResumeWaitForProbe(target);
      await t.pump();
      expect(seeks, isEmpty,
          reason: 'The production resume waiter must wait for duration.');

      final resolution = Completer<List<StreamCandidate>>();
      Future<bool>? switching;
      if (switchSession) {
        SourinApi.debugResolveStreamFetcher = (
          String provider, String id, {PlayRequest? req}
        ) => resolution.future;
        switching = debugPlayerApplySessionForProbe(const PlayRequestData(
          provider: 'resume-fixture',
          id: 'session-b',
          title: 'Session B without resume',
        ));
        await t.pump();
        expect(debugPlayerSessionKeyForProbe(), 'resume-fixture:session-b');
        expect(debugPlayerPendingSeekForProbe(), isNull,
            reason: 'Session B must not carry a resume request.');
      }

      expect(debugPlayerSetDurationForProbe(const Duration(minutes: 10)), isTrue);
      await t.pump(const Duration(milliseconds: 250));
      expect(await waiter, isTrue);
      final observedSeeks = List<Duration>.of(seeks);
      if (switchSession) {
        resolution.complete(<StreamCandidate>[]);
        await t.pump();
        expect(await switching!, isTrue);
      }
      await fixture.drain(t);
      expect(observedSeeks, switchSession ? isEmpty : equals([target]),
          reason: switchSession
              ? 'A resume task from session A must never seek session B.'
              : 'The positive control must execute the real resume waiter.');
    });
  }

  for (final entry in ['unchanged', 'same-session', 'episode', 'remote-source', 'source-without-resume']) {
    testWidgets('resume entry $entry preserves only current session seek', (t) async {
      final previousResolver = SourinApi.debugResolveStreamFetcher;
      final previousMarker = SourinApi.debugSkipMarkerFetcher;
      addTearDown(() {
        SourinApi.debugResolveStreamFetcher = previousResolver;
        SourinApi.debugSkipMarkerFetcher = previousMarker;
      });
      SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
      await fixture.mountPlayer(t);
      RemoteBridge.instance.setGlobals(GlobalBridge(
        search: (_) async {}, loadHome: () async {},
      ));
      final seeks = <Duration>[];
      expect(debugPlayerSetResumeSeekForProbe((target) async {
        seeks.add(target);
      }), isTrue);
      const target = Duration(seconds: 120);
      final waiter = debugPlayerStartResumeWaitForProbe(target);
      await t.pump();
      expect(seeks, isEmpty);
      final resolution = Completer<List<StreamCandidate>>();
      var resolveCalls = 0;
      SourinApi.debugResolveStreamFetcher = (
        String provider, String id, {PlayRequest? req}
      ) {
        resolveCalls++;
        return resolution.future;
      };
      Future<void>? switching;
      if (entry == 'same-session') {
        switching = debugPlayerApplySessionForProbe(const PlayRequestData(
          provider: 'cctv', id: 'cctv1', title: '播放中断回归',
          episodeId: 'ep1',
        )).then((ok) { if (!ok) throw StateError('Production player entry was not mounted'); });
      } else if (entry == 'episode') {
        switching = debugPlayerGotoEpisodeForProbe(fixture.fakeEpisodes(5)[1])
            .then((ok) { if (!ok) throw StateError('Production player entry was not mounted'); });
      } else if (entry == 'remote-source') {
        switching = RemoteBridge.instance.execCommandForTest(
          RemoteCommand('switch_source', {'code': 'resume-line-b'}),
        );
      } else if (entry == 'source-without-resume') {
        switching = debugPlayerApplySwitchForProbe(
          provider: 'resume-fixture', id: 'source-b',
          detail: MediaDetail(id: 'source-b', title: 'Source B',
            episodes: fixture.fakeEpisodes(5)),
        ).then((ok) { if (!ok) throw StateError('Production player entry was not mounted'); });
      }
      await t.pump();
      await t.pump();
      final control = entry == 'unchanged' || entry == 'same-session';
      expect(resolveCalls, control ? 0 : 1,
          reason: 'The requested production entry must reach stream resolution.');
      if (entry == 'episode' || entry == 'source-without-resume') {
        expect(debugPlayerPendingSeekForProbe(), isNull,
            reason: 'The new playback request has no resume position.');
      }
      expect(debugPlayerSetDurationForProbe(const Duration(minutes: 10)), isTrue);
      await t.pump(const Duration(milliseconds: 250));
      expect(await waiter, isTrue);
      final observed = List<Duration>.of(seeks);
      resolution.complete(<StreamCandidate>[]);
      await t.pump();
      if (switching != null) await switching;
      await fixture.drain(t);
      expect(observed, control ? equals([target]) : isEmpty,
          reason: control
              ? 'An unchanged session must retain its pending resume seek.'
              : 'The old 120-second waiter must not seek after $entry.');
    });
  }

  testWidgets('recoverable failure unmounts bottom bar instead of covering retry', (t) async {
    await fixture.mountPlayer(t);
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue);
    debugPlayerHoverControlsForProbe();
    await t.pump();
    expect(find.byType(PlayerBottomBar), findsOneWidget);
    expect(debugPlayerInjectStreamErrorForProbe('fixture stream interrupted'), isTrue);
    await t.pump();
    expect(find.text('播放中断了（画面还在，可以重试）'), findsOneWidget);
    expect(find.byType(PlayerBottomBar), findsNothing);
    await fixture.drain(t);
  });
}
