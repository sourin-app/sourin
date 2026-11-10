// Candidate only: not installed under test/, compiled or executed.
// Actual LivePage/watchLive/embedded restore and Navigator/occlusion owners run.
// Only the embedded native Player commands and fullscreen report leaf are fake.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart' show ShellOcclusionObserver, handoffLivePlayback;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player_page.dart' show PlayerPage;
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';

class _HeldCommand {
  final entered = Completer<void>();
  final release = Completer<void>();

  void finish() {
    if (!release.isCompleted) release.complete();
  }
}

class _NativeCommands extends Fake implements Player {
  _NativeCommands(this.events);

  final List<String> events;
  PlayerState _state = const PlayerState(playing: true, volume: 37);
  final holds = <_HeldCommand>[];
  _HeldCommand? nextPositiveVolume;
  _HeldCommand? nextPause;
  _HeldCommand? nextPlay;
  _HeldCommand? disposal;
  int plays = 0;
  int pauses = 0;
  int disposals = 0;
  bool disposalFinished = false;

  @override
  PlayerState get state => _state;

  _HeldCommand holdPositiveVolume() {
    final held = _HeldCommand();
    holds.add(held);
    nextPositiveVolume = held;
    return held;
  }

  _HeldCommand holdDisposal() {
    final held = _HeldCommand();
    holds.add(held);
    disposal = held;
    return held;
  }

  _HeldCommand holdPause() {
    final held = _HeldCommand();
    holds.add(held);
    nextPause = held;
    return held;
  }

  _HeldCommand holdPlay() {
    final held = _HeldCommand();
    holds.add(held);
    nextPlay = held;
    return held;
  }

  void releaseAll() {
    for (final held in holds) {
      held.finish();
    }
  }

  @override
  Future<void> setVolume(double value) async {
    events.add(value > 0 ? 'native-volume-positive:start' : 'native-volume-zero:start');
    final held = value > 0 ? nextPositiveVolume : null;
    if (held != null) {
      nextPositiveVolume = null;
      held.entered.complete();
      await held.release.future;
    }
    _state = _state.copyWith(volume: value);
    events.add('native-volume:done');
  }

  @override
  Future<void> play() async {
    events.add('native-play');
    plays++;
    final held = nextPlay;
    if (held != null) {
      nextPlay = null;
      held.entered.complete();
      await held.release.future;
    }
    _state = _state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    events.add('native-pause');
    pauses++;
    final held = nextPause;
    if (held != null) {
      nextPause = null;
      held.entered.complete();
      await held.release.future;
    }
    _state = _state.copyWith(playing: false);
  }

  @override
  Future<void> stop() async {
    _state = _state.copyWith(playing: false);
  }

  @override
  Future<void> dispose() async {
    events.add('native-dispose:start');
    disposals++;
    final held = disposal;
    if (held != null) {
      held.entered.complete();
      await held.release.future;
    }
    disposalFinished = true;
    events.add('native-dispose:done');
  }
}

// Fullscreen report boundary only. The real PlayerPage object supplies the
// actual initial/report callback contract via handoffLivePlayback, but its
// native State is deliberately NOT mounted. This fixture cannot prove real
// outgoing decoder release or audible silence.
class _ReportRoute extends StatefulWidget {
  const _ReportRoute({required this.exit, required this.native, required this.events});

  final VoidCallback exit;
  final _NativeCommands native;
  final List<String> events;

  @override
  State<_ReportRoute> createState() => _ReportRouteState();
}

class _ReportRouteState extends State<_ReportRoute> {
  @override
  void dispose() {
    widget.events.add('outgoing-widget:dispose');
    unawaited(widget.native.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(child: TextButton(onPressed: widget.exit, child: const Text('Return fixture'))),
  );
}

class _Scene {
  final navigator = GlobalKey<NavigatorState>();
  final liveKey = GlobalKey<LivePageState>();
  final observer = ShellOcclusionObserver();
  final visible = ValueNotifier(true);
  final events = <String>[];
  late final embeddedNative = _NativeCommands(events);
  late final outgoingNative = _NativeCommands(events);
  late MaterialPageRoute<void> route;
  bool popped = false;
  bool transitionCompleted = false;
  LivePlaybackSnapshot? initial;
  LivePlaybackSnapshot returned = LivePlaybackSnapshot(playing: false, muted: false, volume: 37);
  final commands = <String>[];
  bool activeTab = true;
  bool removeLive = false;
  int pushes = 0;
  int callbackFailuresRemaining = 0;
  final sceneChanged = ValueNotifier(0);

  void setActiveTab(bool active) {
    activeTab = active;
    _projectVisibility();
  }

  void disposeLive() {
    removeLive = true;
    sceneChanged.value++;
  }

  void _projectVisibility() {
    // Fixture wiring is exactly the live-tab projection of the production
    // observer. It neither changes playback flags nor implements restoration.
    final next = activeTab && observer.occluders.value == 0;
    events.add('visibility:$next');
    visible.value = next;
  }

  Future<dynamic> core(String command, Map<String, dynamic>? args) async {
    commands.add(command);
    if (command == 'get_live_channels') {
      return [{'provider':'return-fixture','providerName':'Return fixture',
        'channels':[{'id':'one','name':'Fixture channel'}]}];
    }
    if (command == 'get_live_stream') return <dynamic>[];
    throw StateError('Unexpected return-race core request: $command');
  }

  Future<LivePlaybackSnapshot?> _push(
    String provider, String channel, String title, LivePlaybackSnapshot snapshot,
  ) {
    if (callbackFailuresRemaining > 0) {
      callbackFailuresRemaining--;
      return Future<LivePlaybackSnapshot?>.error(StateError('Synthetic refused route'));
    }
    return handoffLivePlayback(
    initialPlayback: snapshot,
    buildPlayer: (value, report) {
      initial = value;
      return PlayerPage(provider: provider, id: channel, title: title,
        liveChannelId: channel, initialLivePlayback: value, onLivePlaybackExit: report);
    },
    push: (player) async {
      pushes++;
      route = MaterialPageRoute<void>(builder: (_) => _ReportRoute(
        native: outgoingNative,
        events: events,
        exit: () {
          events.add('report:paused=${!returned.playing}');
          player.onLivePlaybackExit!(returned);
          navigator.currentState!.pop();
        },
      ));
      final result = navigator.currentState!.push<void>(route);
      result.then((_) { popped = true; events.add('route:popped'); });
      route.completed.then((_) { transitionCompleted = true; events.add('route:completed'); });
      await result;
    },
    );
  }

  Future<LiveEmbeddedPlayerState> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    observer.occluders.addListener(_projectVisibility);
    SourinCore.debugCallAsyncTransport = core;
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [observer],
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: Scaffold(body: ValueListenableBuilder<int>(
        valueListenable: sceneChanged,
        builder: (_, __, ___) => removeLive
            ? const SizedBox.shrink()
            : LivePage(key: liveKey, visible: visible, onWatchLivePlayback: _push),
      )),
    ));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump();
    }
    expect(find.byType(LiveEmbeddedPlayer), findsOneWidget);
    expect(tester.widget<LiveChannelList>(find.byType(LiveChannelList)).selectedRow,
        liveChannelRowKey('return-fixture', 'one'));
    final state = tester.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));
    state.attachPlayerForTest(embeddedNative);
    await tester.runAsync(() => state.setVolume(37));
    expect(state.playbackSnapshot.playing, isTrue);
    expect(state.playbackSnapshot.muted, isFalse);
    return state;
  }

  Future<void> finish(WidgetTester tester) async {
    embeddedNative.releaseAll();
    outgoingNative.releaseAll();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    observer.occluders.removeListener(_projectVisibility);
    observer.occluders.dispose();
    visible.dispose();
    sceneChanged.dispose();
    expect(commands.toSet().difference({'get_live_channels','get_live_stream'}), isEmpty);
    expect(tester.takeException(), isNull);
  }
}

void main() {
  late bool oldSkip;
  late bool? oldForced;
  late String? oldDirectory;
  late PageTransitionStyle oldStyle;
  late Future<List<LiveGroup>> Function()? oldGroups;
  late Future<List<StreamCandidate>> Function(String, String)? oldStreams;
  late Future<dynamic> Function(String, Map<String, dynamic>?)? oldCore;

  setUp(() {
    oldSkip = debugSkipPlayerCreation;
    oldForced = debugForcePlaying;
    oldCore = SourinCore.debugCallAsyncTransport;
    oldDirectory = DiskCache.dataDir;
    oldStyle = PageTransitionStyleStore.current.value;
    oldGroups = LivePageState.debugLiveGroupsFetcher;
    oldStreams = SourinApi.debugLiveStreamFetcher;
    debugSkipPlayerCreation = true;
    debugForcePlaying = null;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String,String>{});
    LivePageState.debugLiveGroupsFetcher = null;
    SourinApi.debugLiveStreamFetcher = null;
    SourinApi.debugClearLiveStreamCache();
    PageTransitionStyleStore.resetForTest(PageTransitionStyle.slideRight);
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
    PageTransitionStyleStore.resetForTest(oldStyle);
  });

  Future<void> showRoute(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Return fixture'), findsOneWidget);
  }

  testWidgets('two fullscreen requests while pause is pending push only once', (tester) async {
    final scene = _Scene();
    addTearDown(() => scene.finish(tester));
    await scene.mount(tester);
    final held = (await tester.runAsync(() async => scene.embeddedNative.holdPause()))!;
    final requests = <Future<void>>[];
    final requestErrors = <Object>[];
    var finished = 0;
    var secondFinished = false;

    void observeRequest(Future<void> request, {bool second = false}) {
      requests.add(request.then<void>((_) {
        finished++;
        if (second) secondFinished = true;
      }, onError: (Object error, StackTrace stack) {
        // Retain errors for the cleanup assertion without leaving a future
        // unobserved when the exactly-one-push assertion intentionally fails.
        requestErrors.add(error);
        finished++;
        if (second) secondFinished = true;
      }));
    }

    try {
      await tester.runAsync(() async {
        observeRequest(scene.liveKey.currentState!.watchLiveForProbe(LiveRoundtripReceipt()));
        await held.entered.future.timeout(const Duration(seconds: 5));
        observeRequest(scene.liveKey.currentState!.watchLiveForProbe(LiveRoundtripReceipt()), second: true);
        // The gate and both production entry futures belong to runAsync's
        // real zone. Release here, then drain the real microtask chains.
        held.finish();
        await Future<void>.delayed(Duration.zero);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        // Patched: request two has returned and request one has pushed.
        // Baseline: neither route future returns yet, but BOTH callbacks
        // have reached the actual push boundary. One push alone is not ready.
        while (scene.pushes == 0 || (!secondFinished && scene.pushes < 2)) {
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('Both fullscreen entry continuations must reach a push or finish boundary.');
          }
          await Future<void>.delayed(Duration.zero);
        }
        await Future<void>.delayed(Duration.zero);
      });
      await showRoute(tester);
      expect(scene.pushes, 1, reason: 'Handoff ownership is claimed before the first native await.');
      await tester.tap(find.text('Return fixture'));
      await tester.pump();
    } finally {
      await tester.runAsync(() async {
        held.finish();
        scene.embeddedNative.releaseAll();
        scene.outgoingNative.releaseAll();
        await Future<void>.delayed(Duration.zero);
      });
      // The RED path can have two real routes. Close all of them even when
      // the behavioral assertion fails, and let both original futures settle.
      for (var frame = 0; frame < 12; frame++) {
        scene.navigator.currentState?.popUntil((route) => route.isFirst);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
        if (finished == requests.length) break;
      }
      await tester.runAsync(() => Future.wait(requests).timeout(const Duration(seconds: 5)));
      expect(requestErrors, isEmpty, reason: 'Every original handoff future must complete without an unobserved error.');
    }
  });

  testWidgets('failed fullscreen callback releases ownership for a later request', (tester) async {
    final scene = _Scene();
    addTearDown(() => scene.finish(tester));
    await scene.mount(tester);
    scene.callbackFailuresRemaining = 1;
    final receipt = LiveRoundtripReceipt();
    await tester.runAsync(() => expectLater(
      scene.liveKey.currentState!.watchLiveForProbe(receipt),
      throwsA(isA<StateError>()),
    ));
    expect(receipt.error, isA<StateError>());
    expect(scene.embeddedNative.state.playing, isTrue,
        reason: 'Refused navigation must not leave previously playing embedded content paused.');
    late Future<void> again;
    await tester.runAsync(() async {
      again = scene.liveKey.currentState!.watchLiveForProbe(LiveRoundtripReceipt());
    });
    await showRoute(tester);
    expect(scene.pushes, 1);
    await tester.tap(find.text('Return fixture'));
    await tester.pump();
    await tester.runAsync(() => again.timeout(const Duration(seconds: 5)));
  });

  for (final playing in [false, true]) {
    testWidgets('fullscreen return while another tab is active retains playing=$playing intent until visible', (tester) async {
      final scene = _Scene();
      addTearDown(() => scene.finish(tester));
      await scene.mount(tester);
      scene.returned = LivePlaybackSnapshot(playing: playing, muted: false, volume: 37);
      late Future<void> roundtrip;
      await tester.runAsync(() async {
        roundtrip = scene.liveKey.currentState!.watchLiveForProbe(LiveRoundtripReceipt());
      });
      await showRoute(tester);
      scene.setActiveTab(false);
      await tester.tap(find.text('Return fixture'));
      await tester.pump();
      await tester.runAsync(() => roundtrip.timeout(const Duration(seconds: 5)));
      expect(scene.visible.value, isFalse);
      expect(scene.embeddedNative.state.playing, isFalse);
      expect(scene.embeddedNative.state.volume, 0);
      final before = scene.embeddedNative.plays;
      scene.setActiveTab(true);
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      expect(scene.embeddedNative.state.playing, playing);
      expect(scene.embeddedNative.plays > before, playing);
    });
  }

  testWidgets('disposing live page during held return volume cannot send native play afterward', (tester) async {
    final scene = _Scene();
    addTearDown(() => scene.finish(tester));
    await scene.mount(tester);
    scene.returned = LivePlaybackSnapshot(playing: true, muted: false, volume: 37);
    late Future<void> roundtrip;
    await tester.runAsync(() async {
      roundtrip = scene.liveKey.currentState!.watchLiveForProbe(LiveRoundtripReceipt());
    });
    await showRoute(tester);
    final held = (await tester.runAsync(() async => scene.embeddedNative.holdPositiveVolume()))!;
    try {
      await tester.tap(find.text('Return fixture'));
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      expect(held.entered.isCompleted, isTrue);
      scene.disposeLive();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(scene.liveKey.currentState, isNull);
      expect(scene.embeddedNative.disposals, 1);
    } finally {
      held.finish();
    }
    final before = scene.embeddedNative.plays;
    await tester.runAsync(() => roundtrip.timeout(const Duration(seconds: 5)));
    await tester.pump();
    expect(scene.embeddedNative.plays, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hiding during a native play await reestablishes pause after that play finishes', (tester) async {
    final scene = _Scene();
    addTearDown(() => scene.finish(tester));
    final embedded = await scene.mount(tester);
    await tester.runAsync(embedded.pause);
    final held = (await tester.runAsync(() async => scene.embeddedNative.holdPlay()))!;
    late Future<void> resuming;
    await tester.runAsync(() async {
      resuming = embedded.resume();
      await held.entered.future.timeout(const Duration(seconds: 5));
    });
    try {
      scene.setActiveTab(false);
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    } finally {
      held.finish();
    }
    await tester.runAsync(() => resuming.timeout(const Duration(seconds: 5)));
    expect(scene.visible.value, isFalse);
    expect(scene.embeddedNative.state.playing, isFalse);
    expect(scene.embeddedNative.state.volume, 0);
  });
}
