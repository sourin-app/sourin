// Actual LivePage/Navigator/visibility/embedded methods and Miuix controls.
// Only local core responses and native command leaves are controlled here.
import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:synchronized/synchronized.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/design/widgets/app_ink_well.dart';
import 'package:sourin_spike/shell.dart' show ShellOcclusionObserver;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

const _first = LiveChannel(id: 'one', name: 'First guard channel');
const _second = LiveChannel(id: 'two', name: 'Second guard channel');
const _third = LiveChannel(id: 'three', name: 'Other-source guard channel');

String _url(String provider, String channel) =>
    'https://legacy-guard.invalid/$provider/$channel.mp4';

class _HeldOpen {
  final entered = Completer<void>();
  final release = Completer<void>();
  void finish() {
    if (!release.isCompleted) release.complete();
  }
}

class _Native extends Fake implements Player {
  final Lock _lock = Lock();
  PlayerState _state = const PlayerState(playing: true, volume: 37);
  final events = <String>[];
  final opened = <({Media media, bool play})>[];
  final held = <_HeldOpen>[];
  _HeldOpen? nextOpen;
  bool disposed = false;
  int disposals = 0;

  @override
  PlayerState get state => _state;
  @override
  PlatformPlayer? get platform => null;

  _HeldOpen holdOpen() {
    final value = _HeldOpen();
    held.add(value);
    nextOpen = value;
    return value;
  }

  void releaseAll() {
    for (final value in held) {
      value.finish();
    }
  }

  Future<void> _dispatch(
    String name,
    void Function() commit, {
    _HeldOpen? wait,
  }) {
    events.add('$name:queued');
    return _lock.synchronized(() async {
      events.add('$name:start');
      if (wait != null) {
        wait.entered.complete();
        await wait.release.future;
      }
      if (disposed) throw StateError('Native command after guard disposal');
      commit();
      events.add('$name:done');
    });
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) {
    if (playable is! Media) {
      throw StateError('Expected actual Media construction');
    }
    final wait = nextOpen;
    nextOpen = null;
    return _dispatch('open', () {
      opened.add((media: playable, play: play));
      _state = _state.copyWith(playing: play);
    }, wait: wait);
  }

  @override
  Future<void> play() =>
      _dispatch('play', () => _state = _state.copyWith(playing: true));
  @override
  Future<void> pause() =>
      _dispatch('pause', () => _state = _state.copyWith(playing: false));
  @override
  Future<void> stop() =>
      _dispatch('stop', () => _state = _state.copyWith(playing: false));
  @override
  Future<void> setVolume(double value) =>
      _dispatch('volume', () => _state = _state.copyWith(volume: value));
  @override
  Future<void> dispose() => _dispatch('dispose', () {
    disposed = true;
    disposals++;
  });
}

class _Scene {
  final navigator = GlobalKey<NavigatorState>();
  final live = GlobalKey<LivePageState>();
  final observer = ShellOcclusionObserver();
  final visible = ValueNotifier(true);
  final native = _Native();
  final streamRequests = <String>[];
  final unexpected = <String>[];
  final handoffs =
      <({String provider, String id, LivePlaybackSnapshot initial})>[];
  late LiveEmbeddedPlayerState embedded;
  MaterialPageRoute<LivePlaybackSnapshot>? route;
  Future<void>? watching;
  bool finished = false;
  bool attached = false;
  late bool previousSkip;
  late bool? previousForced;
  late String? previousDirectory;
  late Future<dynamic> Function(String, Map<String, dynamic>?)? previousCore;
  late Future<List<LiveGroup>> Function()? previousGroups;
  late Future<List<StreamCandidate>> Function(String, String)? previousStreams;

  void _projectVisibility() => visible.value = observer.occluders.value == 0;

  Future<dynamic> _core(String command, Map<String, dynamic>? args) async {
    if (command == 'get_live_channels') {
      return [
        {
          'provider': 'guard-a',
          'providerName': 'Guard A',
          'channels': [
            {'id': _first.id, 'name': _first.name},
            {'id': _second.id, 'name': _second.name},
          ],
        },
        {
          'provider': 'guard-b',
          'providerName': 'Guard B',
          'channels': [
            {'id': _third.id, 'name': _third.name},
          ],
        },
      ];
    }
    if (command == 'get_live_stream') {
      final provider = args!['provider'] as String;
      final channel = args['channel_id'] as String;
      streamRequests.add('$provider:$channel');
      return [
        {
          'url': _url(provider, channel),
          'kind': 'mp4',
          'headers': [
            ['Referer', 'https://legacy-guard.invalid/$provider'],
          ],
        },
      ];
    }
    unexpected.add(command);
    throw StateError('Unexpected legacy guard command: $command');
  }

  Future<LivePlaybackSnapshot?> _watch(
    String provider,
    String id,
    String name,
    LivePlaybackSnapshot initial,
  ) {
    handoffs.add((provider: provider, id: id, initial: initial));
    route = MaterialPageRoute<LivePlaybackSnapshot>(
      builder: (_) =>
          const Scaffold(body: Center(child: Text('Fullscreen guard route'))),
    );
    return navigator.currentState!.push<LivePlaybackSnapshot>(route!);
  }

  Future<void> mount(WidgetTester tester) async {
    previousSkip = debugSkipPlayerCreation;
    previousForced = debugForcePlaying;
    previousCore = SourinCore.debugCallAsyncTransport;
    previousDirectory = DiskCache.dataDir;
    previousGroups = LivePageState.debugLiveGroupsFetcher;
    previousStreams = SourinApi.debugLiveStreamFetcher;
    debugSkipPlayerCreation = true;
    debugForcePlaying = null;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String, String>{});
    SourinApi.debugClearLiveStreamCache();
    LivePageState.debugLiveGroupsFetcher = null;
    SourinApi.debugLiveStreamFetcher = null;
    SourinCore.debugCallAsyncTransport = _core;
    observer.occluders.addListener(_projectVisibility);
    addTearDown(() => finish(tester));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        theme: theme,
        builder: (_, child) => AppThemeHost(data: theme, child: child!),
        home: Scaffold(
          body: LivePage(
            key: live,
            visible: visible,
            onWatchLivePlayback: _watch,
          ),
        ),
      ),
    );
    await drain(tester);
    expect(find.byType(LiveEmbeddedPlayer), findsOneWidget);
    expect(
      tester
          .widget<LiveEmbeddedPlayer>(find.byType(LiveEmbeddedPlayer))
          .stream
          ?.url,
      _url('guard-a', _first.id),
      reason: 'Actual selected stream must be ready before native injection',
    );
    embedded = tester.state<LiveEmbeddedPlayerState>(
      find.byType(LiveEmbeddedPlayer),
    );
    embedded.attachPlayerForTest(native);
    attached = true;
    await tester.runAsync(() => embedded.setVolume(37));
    await tester.pump();
    expect(_displayedVolume(tester), 37);
    expect(streamRequests, ['guard-a:one']);
  }

  Future<void> drain(WidgetTester tester) async {
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    }
    await tester.pump();
  }

  Future<void> beginFullscreen(WidgetTester tester) async {
    await tester.runAsync(() async {
      watching = live.currentState!.watchLiveForProbe(LiveRoundtripReceipt());
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await drain(tester);
    expect(route, isNotNull);
    expect(
      visible.value,
      isFalse,
      reason: 'Actual route observer must hide the embedded owner',
    );
    expect(handoffs, hasLength(1));
  }

  Future<void> returnFullscreen(
    WidgetTester tester,
    LivePlaybackSnapshot snapshot,
  ) async {
    navigator.currentState!.pop<LivePlaybackSnapshot>(snapshot);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await drain(tester);
    await tester.runAsync(() async => await watching);
    expect(visible.value, isTrue);
    expect(
      identical(
        embedded,
        tester.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer)),
      ),
      isTrue,
    );
    expect(embedded.disposalReceiptForProbe.started, isFalse);
  }

  Future<void> finish(WidgetTester tester) async {
    if (finished) return;
    finished = true;
    native.releaseAll();
    final receipt = attached ? embedded.disposalReceiptForProbe : null;
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      for (
        var frame = 0;
        frame < 20 && receipt != null && receipt.completedAt == null;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
        await drain(tester);
      }
      if (receipt != null) {
        expect(receipt.started, isTrue);
        expect(receipt.completedAt, isNotNull);
        expect(receipt.error, isNull);
        expect(native.disposals, 1);
        final afterDispose = native.events.length;
        await tester.runAsync(() => embedded.togglePlayPause());
        await tester.runAsync(
          () => embedded.applyPlaybackSnapshot(
            LivePlaybackSnapshot(playing: true, muted: false, volume: 21),
          ),
        );
        expect(
          native.events.length,
          afterDispose,
          reason:
              'Disposed playback owners must not submit another native command',
        );
      }
      expect(unexpected, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      observer.occluders.removeListener(_projectVisibility);
      observer.occluders.dispose();
      visible.dispose();
      debugSkipPlayerCreation = previousSkip;
      debugForcePlaying = previousForced;
      SourinCore.debugCallAsyncTransport = previousCore;
      LivePageState.debugLiveGroupsFetcher = previousGroups;
      SourinApi.debugLiveStreamFetcher = previousStreams;
      SourinApi.debugClearLiveStreamCache();
      DiskCache.debugResetForTest(previousDirectory);
      UiPrefs.debugResetForTest();
    }
  }
}

double _displayedVolume(WidgetTester tester) {
  final host = find.byKey(
    const ValueKey('live-volume-slider'),
    skipOffstage: false,
  );
  expect(host, findsOneWidget);
  expect(tester.widget<ui.Slider>(host).onChanged, isNotNull);
  final actual = find.descendant(
    of: host,
    matching: find.byType(miuix.MiuixSlider, skipOffstage: false),
  );
  expect(
    actual,
    findsOneWidget,
    reason:
        'The real Miuix control must render under the compatibility wrapper',
  );
  return tester.widget<miuix.MiuixSlider>(actual).value;
}

Future<void> _tapControl(
  _Scene scene,
  WidgetTester tester,
  String label,
) async {
  final tooltip = find.descendant(
    of: find.byType(LiveEmbeddedPlayer),
    matching: find.byWidgetPredicate(
      (widget) => widget is ui.Tooltip && widget.message == label,
    ),
  );
  expect(tooltip, findsOneWidget);
  final button = find.descendant(
    of: tooltip,
    matching: find.byType(AppInkWell),
  );
  expect(button, findsOneWidget);
  final before = scene.native.events
      .where((event) => event.endsWith(':queued'))
      .length;
  await tester.tap(button);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
  await scene.drain(tester);
  expect(
    scene.native.events.where((event) => event.endsWith(':queued')).length,
    greaterThan(before),
    reason: 'The actual bottom-bar callback must reach native',
  );
}

Future<void> verifyLegacyInitialOpenIntent(WidgetTester tester) async {
  final scene = _Scene();
  await scene.mount(tester);
  await _tapControl(scene, tester, '播放');
  expect(scene.native.state.playing, isFalse);
  final beforePlay = scene.native.events
      .where((event) => event == 'play:done')
      .length;
  await tester.runAsync(() => scene.embedded.retry());
  await scene.drain(tester);
  expect(scene.native.opened, hasLength(1));
  expect(scene.native.opened.single.media.uri, _url('guard-a', _first.id));
  expect(scene.native.opened.single.media.httpHeaders, {
    'Referer': 'https://legacy-guard.invalid/guard-a',
  });
  expect(
    scene.native.opened.single.play,
    isFalse,
    reason: 'The real initial/retry method must load without native autoplay',
  );
  expect(scene.native.state.playing, isFalse);
  expect(
    scene.native.events.where((event) => event == 'play:done').length,
    beforePlay,
  );
  await scene.finish(tester);
}

Future<void> verifyLegacyPendingPauseDuringRetry(WidgetTester tester) async {
  final scene = _Scene();
  await scene.mount(tester);
  final held = scene.native.holdOpen();
  Future<void>? opening;
  await tester.runAsync(() async {
    opening = scene.embedded.retry();
  });
  await scene.drain(tester);
  expect(held.entered.isCompleted, isTrue);
  expect(scene.native.state.playing, isTrue);
  await _tapControl(scene, tester, '播放');
  expect(scene.native.events, contains('pause:queued'));
  held.finish();
  await tester.runAsync(() async => await opening);
  await scene.drain(tester);
  expect(scene.native.opened.single.play, isFalse);
  expect(scene.native.state.playing, isFalse);
  expect(scene.native.events.where((event) => event == 'play:done'), isEmpty);
  await scene.finish(tester);
}

Future<void> verifyLegacyFullscreenChannelIntent(WidgetTester tester) async {
  final scene = _Scene();
  await scene.mount(tester);
  await scene.beginFullscreen(tester);
  expect(scene.handoffs.single.provider, 'guard-a');
  expect(scene.handoffs.single.id, _first.id);
  expect(scene.handoffs.single.initial.volume, 37);
  expect(scene.handoffs.single.initial.playing, isTrue);
  expect(scene.handoffs.single.initial.muted, isFalse);
  final picked = scene.live.currentState!.stepChannelForFullscreen(2);
  expect(picked?.provider, 'guard-b');
  expect(picked?.channel.id, _third.id);
  await scene.drain(tester);
  final playsBeforeReturn = scene.native.events
      .where((event) => event == 'play:done')
      .length;
  await scene.returnFullscreen(
    tester,
    LivePlaybackSnapshot(playing: false, muted: true, volume: 64),
  );
  expect(scene.streamRequests, ['guard-a:one', 'guard-b:three']);
  final rebuilt = tester.widget<LiveEmbeddedPlayer>(
    find.byType(LiveEmbeddedPlayer),
  );
  expect(rebuilt.title, _third.name);
  expect(rebuilt.stream?.url, _url('guard-b', _third.id));
  expect(rebuilt.playWhenReady, isFalse);
  expect(scene.native.opened.single.play, isFalse);
  expect(scene.native.opened.single.media.uri, _url('guard-b', _third.id));
  expect(scene.native.state.playing, isFalse);
  expect(
    scene.native.events.where((event) => event == 'play:done').length,
    playsBeforeReturn,
  );
  expect(scene.embedded.muted, isTrue);
  expect(scene.embedded.desiredVolume, 64);
  expect(scene.native.state.volume, 0);
  expect(_displayedVolume(tester), 0);
  await scene.finish(tester);
}

Future<void> verifyLegacyFullscreenSelectionOnly(WidgetTester tester) async {
  final scene = _Scene();
  await scene.mount(tester);
  await scene.beginFullscreen(tester);
  final requestsBefore = List<String>.of(scene.streamRequests);
  final opensBefore = scene.native.opened.length;
  final playsBefore = scene.native.events
      .where((event) => event == 'play:done')
      .length;
  final listBefore = tester.widget<LiveChannelList>(
    find.byType(LiveChannelList, skipOffstage: false),
  );
  final query = scene.live.currentState!.channelsForFullscreen();
  expect(query?.channels.map((channel) => channel.id).toList(), [
    'one',
    'two',
    'three',
  ]);
  expect(query?.index, 0);
  scene.live.currentState!.channelsForFullscreen();
  await scene.drain(tester);
  expect(
    tester
        .widget<LiveChannelList>(
          find.byType(LiveChannelList, skipOffstage: false),
        )
        .selectedRow,
    listBefore.selectedRow,
    reason: 'Repeated actual channel lookup is read-only',
  );
  expect(scene.streamRequests, requestsBefore);
  final neighbor = scene.live.currentState!.stepChannelForFullscreen(2);
  expect(neighbor?.provider, 'guard-b');
  expect(neighbor?.channel.id, _third.id);
  await scene.drain(tester);
  expect(
    tester
        .widget<LiveChannelList>(
          find.byType(LiveChannelList, skipOffstage: false),
        )
        .selectedRow,
    liveChannelRowKey('guard-b', _third.id),
  );
  expect(scene.streamRequests, requestsBefore);
  final picked = scene.live.currentState!.pickChannelForFullscreen(_second);
  expect(picked?.provider, 'guard-a');
  expect(picked?.channel.id, _second.id);
  await scene.drain(tester);
  expect(
    tester
        .widget<LiveChannelList>(
          find.byType(LiveChannelList, skipOffstage: false),
        )
        .selectedRow,
    liveChannelRowKey('guard-a', _second.id),
  );
  expect(
    tester
        .widget<LiveEmbeddedPlayer>(
          find.byType(LiveEmbeddedPlayer, skipOffstage: false),
        )
        .stream,
    isNull,
    reason: 'Fullscreen selection clears the old embedded stream',
  );
  expect(
    scene.streamRequests,
    requestsBefore,
    reason: 'Selection/query cannot start an embedded source resolution while fullscreen owns playback',
  );
  expect(scene.native.opened.length, opensBefore);
  expect(
    scene.native.events.where((event) => event == 'play:done').length,
    playsBefore,
  );
  expect(scene.native.events, contains('stop:done'));
  expect(scene.embedded.disposalReceiptForProbe.started, isFalse);
  await scene.returnFullscreen(
    tester,
    LivePlaybackSnapshot(playing: false, muted: true, volume: 64),
  );
  expect(scene.streamRequests, ['guard-a:one', 'guard-a:two']);
  expect(scene.native.opened.single.media.uri, _url('guard-a', _second.id));
  expect(scene.native.state.playing, isFalse);
  await scene.finish(tester);
}

Future<void> verifyLegacyRenderedMuteRestore(WidgetTester tester) async {
  final scene = _Scene();
  await scene.mount(tester);
  await tester.runAsync(
    () => scene.embedded.applyPlaybackSnapshot(
      LivePlaybackSnapshot(playing: false, muted: true, volume: 64),
    ),
  );
  await scene.drain(tester);
  expect(scene.embedded.playbackSnapshot.muted, isTrue);
  expect(scene.embedded.playbackSnapshot.volume, 64);
  expect(scene.native.state.volume, 0);
  expect(_displayedVolume(tester), 0);
  await _tapControl(scene, tester, '取消静音');
  expect(scene.embedded.muted, isFalse);
  expect(scene.embedded.desiredVolume, 64);
  expect(scene.native.state.volume, 64);
  expect(_displayedVolume(tester), 64);
  expect(scene.native.state.playing, isFalse);
  await scene.finish(tester);
}

Future<void> verifyLegacyDefaultRetryPlays(WidgetTester tester) async {
  final scene = _Scene();
  await scene.mount(tester);
  await tester.runAsync(() => scene.embedded.retry());
  await scene.drain(tester);
  expect(scene.native.opened, hasLength(1));
  expect(scene.native.opened.single.play, isFalse);
  expect(scene.native.state.playing, isTrue);
  expect(
    scene.native.events.where((event) => event == 'play:done'),
    hasLength(1),
  );
  await scene.finish(tester);
}

Future<void> verifyLegacyNewChannelResetsPause(WidgetTester tester) async {
  final scene = _Scene();
  await scene.mount(tester);
  await _tapControl(scene, tester, '播放');
  expect(scene.native.state.playing, isFalse);
  await tester.runAsync(
    () => scene.live.currentState!.selectChannelForProbe(_second),
  );
  await scene.drain(tester);
  expect(scene.streamRequests, ['guard-a:one', 'guard-a:two']);
  expect(scene.native.opened, hasLength(1));
  expect(scene.native.opened.single.media.uri, _url('guard-a', _second.id));
  expect(scene.native.opened.single.play, isFalse);
  expect(
    scene.native.state.playing,
    isTrue,
    reason: 'A new explicit channel selection accepts its own play policy',
  );
  expect(
    scene.native.events.where((event) => event == 'play:done'),
    hasLength(1),
  );
  await scene.finish(tester);
}

Future<void> verifyLegacyPendingPauseDuringChannelOpen(
  WidgetTester tester,
) async {
  final scene = _Scene();
  await scene.mount(tester);
  final held = scene.native.holdOpen();
  await tester.runAsync(
    () => scene.live.currentState!.selectChannelForProbe(_second),
  );
  await scene.drain(tester);
  expect(held.entered.isCompleted, isTrue);
  expect(scene.native.state.playing, isTrue);
  await _tapControl(scene, tester, '播放');
  expect(scene.native.events, contains('pause:queued'));
  held.finish();
  await scene.drain(tester);
  expect(scene.native.opened, hasLength(1));
  expect(scene.native.opened.single.media.uri, _url('guard-a', _second.id));
  expect(scene.native.opened.single.play, isFalse);
  expect(scene.native.state.playing, isFalse);
  expect(scene.native.events.where((event) => event == 'play:done'), isEmpty);
  await scene.finish(tester);
}

Future<void> verifyLegacyHiddenRetryDefersOpen(WidgetTester tester) async {
  final scene = _Scene();
  await scene.mount(tester);
  scene.visible.value = false;
  await scene.drain(tester);
  expect(scene.native.state.playing, isFalse);
  await tester.runAsync(() => scene.embedded.retry());
  await scene.drain(tester);
  expect(
    scene.native.opened,
    isEmpty,
    reason: 'A hidden retry must only remember the suppressed start',
  );
  final count = scene.native.events
      .where((event) => event == 'play:done')
      .length;
  scene.visible.value = true;
  await scene.drain(tester);
  expect(scene.native.opened, hasLength(1));
  expect(scene.native.opened.single.play, isFalse);
  expect(scene.native.state.playing, isTrue);
  expect(
    scene.native.events.where((event) => event == 'play:done').length,
    greaterThan(count),
  );
  await scene.finish(tester);
}

Future<void> verifyLegacyInitialPausedPolicy(WidgetTester tester) async {
  final previousSkip = debugSkipPlayerCreation;
  final previousForced = debugForcePlaying;
  final native = _Native();
  native._state = native.state.copyWith(playing: false);
  final visible = ValueNotifier(true);
  final key = GlobalKey<LiveEmbeddedPlayerState>();
  final theme = AppTheme.themeFor(Brightness.light);
  LiveEmbeddedPlayerState? state;
  bool finished = false;
  Future<void> finish() async {
    if (finished) return;
    finished = true;
    native.releaseAll();
    final receipt = state?.disposalReceiptForProbe;
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      for (var frame = 0; frame < 30 && receipt?.completedAt == null; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      }
      if (receipt != null) {
        expect(receipt.completedAt, isNotNull);
        expect(receipt.error, isNull);
        expect(native.disposals, 1);
      }
      expect(tester.takeException(), isNull);
    } finally {
      visible.dispose();
      debugSkipPlayerCreation = previousSkip;
      debugForcePlaying = previousForced;
    }
  }

  addTearDown(finish);
  debugSkipPlayerCreation = true;
  debugForcePlaying = null;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: Scaffold(
        body: LiveEmbeddedPlayer(
          key: key,
          title: 'Initially paused guard stream',
          stream: const StreamCandidate(
            url: 'https://legacy-guard.invalid/initial/paused.mp4',
            kind: 'mp4',
          ),
          playWhenReady: false,
          visible: visible,
        ),
      ),
    ),
  );
  state = key.currentState!;
  state.attachPlayerForTest(native);
  await tester.runAsync(() => state!.retry());
  await tester.pump();
  expect(native.opened, hasLength(1));
  expect(native.opened.single.play, isFalse);
  expect(native.state.playing, isFalse);
  expect(native.events.where((event) => event == 'play:done'), isEmpty);
  await finish();
}
