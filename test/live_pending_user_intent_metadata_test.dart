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
  bool disposed = false;
  int disposals = 0;

  @override
  PlayerState get state => _state;

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
          ],
        },
      ];
    }
    if (command == 'get_live_stream') {
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
    'metadata-only restoration preserves a pending user pause owner',
    (tester) async {
      final scene = _Scene(lockedNative: true);
      await scene.mount(tester);
      addTearDown(() => scene.finish(tester));
      final held = await _hold(scene, tester, 'pause');
      await _tapControl(scene, tester, '播放');
      expect(held.entered.isCompleted, isTrue);
      expect(scene.native.state.playing, isTrue);
      late Future<void> metadata;
      await tester.runAsync(() async {
        metadata = scene.embedded.applyPlaybackSnapshot(
          LivePlaybackSnapshot(playing: false, muted: false, volume: 23),
          restorePlaying: false,
        );
      });
      await scene.drain(tester);
      await scene.pushCover(tester);
      await scene.drain(tester);
      await scene.popCover(tester);
      await scene.drain(tester);
      await _release(scene, tester, held);
      await tester.runAsync(() => metadata);
      await scene.drain(tester);
      expect(
        scene.native.state.playing,
        isFalse,
        reason: 'Restoring metadata may not retire the pending user pause and let visibility resume against it.',
      );
      expect(
        scene.native.events.where((event) => event == 'play:done'),
        isEmpty,
      );
      expect(scene.embedded.desiredVolume, 23);
      expect(_displayedVolume(tester), 23);
    },
  );
}
