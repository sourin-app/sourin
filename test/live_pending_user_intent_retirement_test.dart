// LivePage, ShellOcclusionObserver, Navigator, embedded command generations and
// disposal receipts are production owners. Only the native Player leaf is fake.
// Every test uses the installed native command lock semantics.
import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:synchronized/synchronized.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/media_session.dart' show LivePlaybackSnapshot;
import 'package:sourin_spike/shell.dart' show ShellOcclusionObserver;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/design/widgets/app_ink_well.dart';

class _HeldCommand {
  final entered = Completer<void>();
  final release = Completer<void>();
  Object? failure;

  void finish() {
    if (!release.isCompleted) release.complete();
  }
}

class _NativeCommands extends Fake implements Player {
  _NativeCommands({required this.lockedNative});
  final bool lockedNative;
  PlayerState _state = const PlayerState(playing: true, volume: 37);
  final Lock _nativeLock = Lock();
  final events = <String>[];
  final holds = <_HeldCommand>[];
  final nextHolds = <String, _HeldCommand>{};
  final openedUrls = <String>[];
  bool disposed = false;
  int disposals = 0;

  @override
  PlayerState get state => _state;

  // The native boundary is intentionally absent: production open and transport
  // checks run, but no NativePlayer, decoder or network is constructed here.
  @override
  PlatformPlayer? get platform => null;

  @override
  Future<void> open(Playable playable, {bool play = true}) {
    if (playable is! Media) throw StateError('Expected production Media open');
    return _dispatch('open', () {
      openedUrls.add(playable.uri);
      _state = _state.copyWith(playing: play);
    });
  }

  _HeldCommand hold(String name) {
    final held = _HeldCommand();
    holds.add(held);
    nextHolds[name] = held;
    return held;
  }

  void releaseAll() {
    for (final held in holds) {
      held.finish();
    }
  }

  Future<void> _dispatch(String name, void Function() commit) {
    events.add('$name:queued');
    final held = nextHolds.remove(name);
    Future<void> execute() async {
      events.add('$name:start');
      if (held != null) {
        held.entered.complete();
        await held.release.future;
        if (held.failure != null) throw held.failure!;
      }
      if (disposed) throw StateError('Native command after disposal');
      commit();
      events.add('$name:done');
    }

    assert(lockedNative);
    return _nativeLock.synchronized(execute);
  }

  @override
  Future<void> setVolume(double value) => _dispatch(
    value == 0 ? 'zero' : 'positive',
    () => _state = _state.copyWith(volume: value),
  );

  @override
  Future<void> pause() =>
      _dispatch('pause', () => _state = _state.copyWith(playing: false));

  @override
  Future<void> play() =>
      _dispatch('play', () => _state = _state.copyWith(playing: true));

  @override
  Future<void> stop() =>
      _dispatch('stop', () => _state = _state.copyWith(playing: false));

  @override
  Future<void> dispose() => _dispatch('dispose', () {
    disposals++;
    disposed = true;
  });
}

class _Scene {
  _Scene({required bool lockedNative})
    : native = _NativeCommands(lockedNative: lockedNative);
  final navigator = GlobalKey<NavigatorState>();
  final liveKey = GlobalKey<LivePageState>();
  final observer = ShellOcclusionObserver();
  final visible = ValueNotifier(true);
  final _NativeCommands native;
  final commands = <String>[];
  final visibility = <bool>[];
  late LiveEmbeddedPlayerState embedded;
  MaterialPageRoute<void>? cover;
  Future<dynamic>? coverReturned;

  void _projectVisibility() {
    final next = observer.occluders.value == 0;
    visibility.add(next);
    visible.value = next;
  }

  Future<dynamic> core(String command, Map<String, dynamic>? args) async {
    commands.add(command);
    if (command == 'get_live_channels') {
      return [
        {
          'provider': 'order-fixture',
          'providerName': 'Order fixture',
          'channels': [
            {'id': 'one', 'name': 'Fixture channel'},
            {'id': 'two', 'name': 'Second fixture channel'},
          ],
        },
      ];
    }
    if (command == 'get_live_stream') {
      if (args?['channel_id'] == 'two') {
        return [
          {
            'url': 'https://pending-intent.invalid/channel-two.mp4',
            'kind': 'mp4',
          },
        ];
      }
      return [
        {
          'url': 'https://pending-intent.invalid/channel-one.mp4',
          'kind': 'mp4',
        },
      ];
    }
    throw StateError('Unexpected command-order core request: $command');
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    observer.occluders.addListener(_projectVisibility);
    SourinCore.debugCallAsyncTransport = core;
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        theme: theme,
        builder: (_, child) => AppThemeHost(data: theme, child: child!),
        home: Scaffold(
          body: LivePage(key: liveKey, visible: visible),
        ),
      ),
    );
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump();
    }
    expect(find.byType(LiveEmbeddedPlayer), findsOneWidget);
    expect(
      tester
          .widget<LiveEmbeddedPlayer>(find.byType(LiveEmbeddedPlayer))
          .stream
          ?.url,
      'https://pending-intent.invalid/channel-one.mp4',
      reason: 'The production player must own a selected nonempty stream before its control is invoked.',
    );
    embedded = tester.state<LiveEmbeddedPlayerState>(
      find.byType(LiveEmbeddedPlayer),
    );
    embedded.attachPlayerForTest(native);
    await tester.runAsync(() => embedded.setVolume(37));
    // Native completion updates state outside the widget zone. Rebuild the
    // actual bottom bar before reading its completed mute label or slider.
    await tester.pump();
    expect(embedded.muted, isFalse);
    expect(
      _displayedVolume(tester),
      37,
      reason: 'The rendered bottom bar must have adopted completed native volume before user input.',
    );
  }

  Future<void> pushCover(WidgetTester tester) async {
    cover = MaterialPageRoute<void>(
      builder: (_) =>
          const Scaffold(body: Center(child: Text('Cover fixture'))),
    );
    coverReturned = navigator.currentState!.push<void>(cover!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(visible.value, isFalse);
  }

  Future<void> popCover(WidgetTester tester) async {
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await coverReturned;
      await cover!.completed;
    });
    expect(visible.value, isTrue);
  }

  Future<void> drain(WidgetTester tester) async {
    for (var turn = 0; turn < 12; turn++) {
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    }
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.runAsync(() async => native.releaseAll());
    final receipt = embedded.disposalReceiptForProbe;
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      for (var frame = 0; frame < 20 && receipt.completedAt == null; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        await drain(tester);
      }
      expect(receipt.started, isTrue);
      expect(
        native.events,
        contains('dispose:start'),
        reason: 'Unmount must issue native disposal; events=${native.events}',
      );
      expect(
        receipt.completedAt,
        isNotNull,
        reason:
            'Bounded cleanup must observe native disposal completion; events=${native.events}',
      );
      expect(receipt.error, isNull);
      expect(native.disposals, 1);
      expect(
        commands.toSet().difference({'get_live_channels', 'get_live_stream'}),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    } finally {
      observer.occluders.removeListener(_projectVisibility);
      observer.occluders.dispose();
      visible.dispose();
    }
  }
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
  final queuedBefore = scene.native.events
      .where((event) => event.endsWith(':queued'))
      .length;
  await tester.tap(button);
  // The live surface owns a double-tap recognizer. Its arena must settle
  // before this real child tap callback can be expected to reach native.
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
  await scene.drain(tester);
  expect(
    scene.native.events.where((event) => event.endsWith(':queued')).length,
    greaterThan(queuedBefore),
    reason:
        'The actual bottom-bar tap must reach its native callback; events=${scene.native.events}',
  );
}

double _displayedVolume(WidgetTester tester) => tester
    .widget<ui.Slider>(find.byKey(const ValueKey('live-volume-slider')))
    .value;

Future<_HeldCommand> _hold(
  _Scene scene,
  WidgetTester tester,
  String name,
) async => (await tester.runAsync(() async => scene.native.hold(name)))!;

Future<void> _release(
  _Scene scene,
  WidgetTester tester,
  _HeldCommand held,
) async {
  await tester.runAsync(() async => held.finish());
  await scene.drain(tester);
}

void main() {
  late bool oldSkip;
  late bool? oldForced;
  late String? oldDirectory;
  late Future<List<LiveGroup>> Function()? oldGroups;
  late Future<List<StreamCandidate>> Function(String, String)? oldStreams;
  late Future<dynamic> Function(String, Map<String, dynamic>?)? oldCore;

  setUp(() {
    oldSkip = debugSkipPlayerCreation;
    oldForced = debugForcePlaying;
    oldCore = SourinCore.debugCallAsyncTransport;
    oldDirectory = DiskCache.dataDir;
    oldGroups = LivePageState.debugLiveGroupsFetcher;
    oldStreams = SourinApi.debugLiveStreamFetcher;
    debugSkipPlayerCreation = true;
    debugForcePlaying = null;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String, String>{});
    LivePageState.debugLiveGroupsFetcher = null;
    SourinApi.debugLiveStreamFetcher = null;
    SourinApi.debugClearLiveStreamCache();
  });

  tearDown(() {
    debugSkipPlayerCreation = oldSkip;
    debugForcePlaying = oldForced;
    SourinCore.debugCallAsyncTransport = oldCore;
    LivePageState.debugLiveGroupsFetcher = oldGroups;
    SourinApi.debugLiveStreamFetcher = oldStreams;
    DiskCache.debugResetForTest(oldDirectory);
    UiPrefs.debugResetForTest();
    SourinApi.debugClearLiveStreamCache();
  });

  testWidgets(
    'adopting paused snapshot retires pending pause without reviving deferred visibility',
    (tester) async {
      final scene = _Scene(lockedNative: true);
      await scene.mount(tester);
      addTearDown(() => scene.finish(tester));
      final held = await _hold(scene, tester, 'pause');
      await _tapControl(scene, tester, '播放');
      expect(held.entered.isCompleted, isTrue);
      await scene.pushCover(tester);
      await scene.drain(tester);
      await scene.popCover(tester);
      await scene.drain(tester);
      late Future<void> adoption;
      await tester.runAsync(() async {
        adoption = scene.embedded.applyPlaybackSnapshot(
          LivePlaybackSnapshot(playing: false, muted: false, volume: 23),
        );
      });
      await scene.drain(tester);
      await _release(scene, tester, held);
      await tester.runAsync(() => adoption);
      await scene.drain(tester);
      expect(
        scene.native.state.playing,
        isFalse,
        reason: 'Retirement is not settlement: old deferred visibility must not invalidate the paused snapshot command.',
      );
      expect(
        scene.native.events.where((event) => event == 'play:done'),
        isEmpty,
      );
      expect(scene.embedded.desiredVolume, 23);
      expect(_displayedVolume(tester), 23);
    },
  );

  testWidgets(
    'retired pause completion cannot overwrite adopted playing intent',
    (tester) async {
      final scene = _Scene(lockedNative: true);
      await scene.mount(tester);
      addTearDown(() => scene.finish(tester));
      final held = await _hold(scene, tester, 'pause');
      await _tapControl(scene, tester, '播放');
      expect(held.entered.isCompleted, isTrue);
      late Future<void> adoption;
      await tester.runAsync(() async {
        adoption = scene.embedded.applyPlaybackSnapshot(
          LivePlaybackSnapshot(playing: true, muted: false, volume: 23),
        );
      });
      await scene.drain(tester);
      await _release(scene, tester, held);
      await tester.runAsync(() => adoption);
      await scene.drain(tester);
      expect(
        scene.native.state.playing,
        isTrue,
        reason: 'The replacement snapshot must have completed before checking the next visibility cycle.',
      );
      await scene.pushCover(tester);
      await scene.drain(tester);
      await scene.popCover(tester);
      await scene.drain(tester);
      expect(
        scene.native.state.playing,
        isTrue,
        reason: 'The retired user pause must not change LivePage accepted intent after a playing snapshot is adopted.',
      );
      expect(scene.embedded.desiredVolume, 23);
      expect(_displayedVolume(tester), 23);
    },
  );

  testWidgets('retired mute success cannot revive when a new mute fails', (
    tester,
  ) async {
    final scene = _Scene(lockedNative: true);
    await scene.mount(tester);
    addTearDown(() => scene.finish(tester));
    final first = await _hold(scene, tester, 'zero');
    await _tapControl(scene, tester, '静音');
    expect(first.entered.isCompleted, isTrue);
    late Future<void> adoption;
    await tester.runAsync(() async {
      adoption = scene.embedded.applyPlaybackSnapshot(
        LivePlaybackSnapshot(playing: true, muted: false, volume: 23),
        restorePlaying: false,
      );
    });
    await scene.drain(tester);
    final failure = StateError('Synthetic replacement mute failure');
    final second = (await _hold(scene, tester, 'zero'))..failure = failure;
    Object? error;
    late Future<void> operation;
    await tester.runAsync(() async {
      operation = scene.embedded.toggleMute().catchError((Object value) {
        error = value;
      });
    });
    await scene.drain(tester);
    await _release(scene, tester, first);
    await tester.runAsync(() => adoption);
    await scene.drain(tester);
    expect(
      second.entered.isCompleted,
      isTrue,
      reason:
          'The post-adoption mute must reach its own held zero-volume command.',
    );
    await _release(scene, tester, second);
    await tester.runAsync(() => operation);
    await scene.drain(tester);
    expect(error, same(failure));
    expect(
      scene.embedded.muted,
      isFalse,
      reason: 'A new pending flag cannot make an older retired native mute success accepted again.',
    );
    expect(scene.native.state.volume, 23);
    expect(scene.embedded.desiredVolume, 23);
    expect(_displayedVolume(tester), 23);
  });

  testWidgets(
    'failed unmute during held visibility restore ends muted at native zero',
    (tester) async {
      final scene = _Scene(lockedNative: true);
      await scene.mount(tester);
      addTearDown(() => scene.finish(tester));
      final first = await _hold(scene, tester, 'zero');
      await _tapControl(scene, tester, '静音');
      expect(first.entered.isCompleted, isTrue);
      final failure = StateError('Synthetic unmute failure during visibility');
      final second = (await _hold(scene, tester, 'positive'))
        ..failure = failure;
      Object? error;
      late Future<void> operation;
      await tester.runAsync(() async {
        operation = scene.embedded.toggleMute().catchError((Object value) {
          error = value;
        });
      });
      await scene.drain(tester);
      // B consumed its held command when queued. This distinct later positive
      // hold belongs to automatic visibility restoration, never to B.
      final restoration = await _hold(scene, tester, 'positive');
      await scene.pushCover(tester);
      await scene.drain(tester);
      await scene.popCover(tester);
      await scene.drain(tester);
      await _release(scene, tester, first);
      expect(second.entered.isCompleted, isTrue);
      expect(
        scene.embedded.muted,
        isTrue,
        reason: 'The earlier native mute success must remain accepted while the newer unmute is pending.',
      );
      await _release(scene, tester, second);
      await tester.runAsync(() => operation);
      await scene.drain(tester);
      expect(error, same(failure));
      expect(
        restoration.entered.isCompleted,
        isTrue,
        reason: 'The race requires an already-accepted positive visibility restoration waiting in native.',
      );
      expect(scene.embedded.muted, isTrue);
      await _release(scene, tester, restoration);
      expect(scene.native.state.playing, isTrue);
      expect(
        scene.native.state.volume,
        0,
        reason: 'Visibility restoration must recheck completed mute after its positive-volume await.',
      );
      expect(scene.embedded.muted, isTrue);
      expect(scene.embedded.desiredVolume, 37);
      expect(_displayedVolume(tester), 0);
    },
  );

  testWidgets('new channel build does not inherit the old pending user pause', (
    tester,
  ) async {
    final scene = _Scene(lockedNative: true);
    await scene.mount(tester);
    addTearDown(() => scene.finish(tester));
    final held = await _hold(scene, tester, 'pause');
    await _tapControl(scene, tester, '播放');
    expect(held.entered.isCompleted, isTrue);
    await tester.runAsync(
      () => scene.liveKey.currentState!.selectChannelForProbe(
        const LiveChannel(id: 'two', name: 'Second fixture channel'),
        provider: 'order-fixture',
      ),
    );
    await scene.drain(tester);
    final replacement = tester.widget<LiveEmbeddedPlayer>(
      find.byType(LiveEmbeddedPlayer),
    );
    expect(replacement.title, 'Second fixture channel');
    expect(
      replacement.stream?.url,
      'https://pending-intent.invalid/channel-two.mp4',
      reason: 'The replacement must be a real selected nonempty stream through production getLiveStream/model/preparer.',
    );
    expect(
      scene.native.events,
      contains('open:queued'),
      reason: 'Production source replacement must dispatch its native open while the old pause is held.',
    );
    expect(
      replacement.playWhenReady,
      isTrue,
      reason: 'Source replacement must retire old pending pause before parent build decides the new channel play policy.',
    );
    await _release(scene, tester, held);
    final afterCompletion = tester.widget<LiveEmbeddedPlayer>(
      find.byType(LiveEmbeddedPlayer),
    );
    expect(
      afterCompletion.stream?.url,
      'https://pending-intent.invalid/channel-two.mp4',
    );
    expect(scene.native.openedUrls, [
      'https://pending-intent.invalid/channel-two.mp4',
    ]);
    expect(
      scene.native.state.playing,
      isTrue,
      reason: 'The new source must complete production open and play at the controlled native leaf.',
    );
    expect(
      afterCompletion.playWhenReady,
      isTrue,
      reason: 'Completion of the old channel pause must not revive its retired parent intent.',
    );
  });

  testWidgets(
    'failed visible user pause restores completed intent after old resume compensation',
    (tester) async {
      final scene = _Scene(lockedNative: true);
      await scene.mount(tester);
      addTearDown(() => scene.finish(tester));
      // Hide has sent zero but cannot yet pause. Show claims its resume and
      // consumes the parent's hide flag before this user's request arrives.
      final hiddenZero = await _hold(scene, tester, 'zero');
      await scene.pushCover(tester);
      await scene.drain(tester);
      expect(hiddenZero.entered.isCompleted, isTrue);
      expect(scene.native.state.playing, isTrue);
      final restoration = await _hold(scene, tester, 'positive');
      await scene.popCover(tester);
      await scene.drain(tester);
      await _release(scene, tester, hiddenZero);
      expect(
        restoration.entered.isCompleted,
        isTrue,
        reason: 'The real visibility resume must wait in positive restoration before the user pause arrives.',
      );
      expect(
        scene.native.state.playing,
        isTrue,
        reason: 'Hide pause was superseded before dispatch; the real toggle must therefore request pause.',
      );
      final failure = StateError('Synthetic visible user pause failure');
      final userPause = (await _hold(scene, tester, 'pause'))
        ..failure = failure;
      Object? error;
      late Future<void> operation;
      await tester.runAsync(() async {
        operation = scene.embedded.togglePlayPause().catchError((Object value) {
          error = value;
        });
      });
      await scene.drain(tester);
      await _release(scene, tester, restoration);
      expect(
        userPause.entered.isCompleted,
        isTrue,
        reason: 'The failing native command must be the newer user pause, after the older volume restore.',
      );
      await _release(scene, tester, userPause);
      await tester.runAsync(() => operation);
      await scene.drain(tester);
      expect(error, same(failure));
      expect(scene.visible.value, isTrue);
      expect(
        scene.native.state.playing,
        isTrue,
        reason: 'Failure must restore the completed playing intent even though the parent already consumed its hide flag.',
      );
      expect(scene.native.state.volume, 37);
      expect(scene.embedded.muted, isFalse);
      expect(scene.embedded.desiredVolume, 37);
      expect(_displayedVolume(tester), 37);
    },
  );
}
