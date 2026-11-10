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
    _state = _state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    events.add('native-pause');
    pauses++;
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

  void _projectVisibility() {
    // Fixture wiring is exactly the live-tab projection of the production
    // observer. It neither changes playback flags nor implements restoration.
    final next = observer.occluders.value == 0;
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
  ) => handoffLivePlayback(
    initialPlayback: snapshot,
    buildPlayer: (value, report) {
      initial = value;
      return PlayerPage(provider: provider, id: channel, title: title,
        liveChannelId: channel, initialLivePlayback: value, onLivePlaybackExit: report);
    },
    push: (player) async {
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
      home: Scaffold(body: LivePage(key: liveKey, visible: visible, onWatchLivePlayback: _push)),
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

  for (final playing in [false, true]) {
    testWidgets('real route visibility and delayed native restore preserve returned playing=$playing', (tester) async {
      final scene = _Scene();
      addTearDown(() => scene.finish(tester));
      await scene.mount(tester);
      scene.returned = LivePlaybackSnapshot(playing: playing, muted: false, volume: 37);
      final receipt = LiveRoundtripReceipt();
      // Box the Future: an async helper returning a Future directly would await
      // navigation accidentally instead of returning its pending handle.
      late Future<void> roundtrip;
      await tester.runAsync(() async { roundtrip = scene.liveKey.currentState!.watchLiveForProbe(receipt); });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Return fixture'), findsOneWidget);
      expect(scene.observer.occluders.value, 1);
      expect(scene.visible.value, isFalse);
      expect(scene.embeddedNative.state.playing, isFalse);
      expect(scene.initial?.playing, isTrue);
      expect(scene.initial?.muted, isFalse);
      final playsBefore = scene.embeddedNative.plays;
      final held = (await tester.runAsync(() async => scene.embeddedNative.holdPositiveVolume()))!;
      try {
        await tester.tap(find.text('Return fixture'));
        await tester.pump();
        await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
        expect(scene.popped, isTrue);
        expect(scene.visible.value, isTrue);
        expect(held.entered.isCompleted, isTrue,
            reason: 'The actual positive native volume write must be held, not a timing guess.');
        // The gate can belong to generic visibility resume on the baseline or
        // to the legitimate snapshot-volume restore after an owning fix.
      } finally {
        held.finish();
      }
      await tester.runAsync(() => roundtrip.timeout(const Duration(seconds: 5)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(scene.embeddedNative.state.playing, playing,
          reason: 'A late automatic command must not override the adopted return intent.');
      if (!playing) {
        expect(scene.embeddedNative.plays, playsBefore,
            reason: 'Returning paused must not issue an automatic native play.');
      } else {
        expect(scene.embeddedNative.plays, greaterThan(playsBefore));
      }
      expect(scene.embeddedNative.state.volume, 37);
      expect(receipt.error, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('restorePlaying=false is metadata-only rather than an implicit pause', (tester) async {
    final scene = _Scene();
    addTearDown(() => scene.finish(tester));
    final embedded = await scene.mount(tester);
    final plays = scene.embeddedNative.plays;
    final pauses = scene.embeddedNative.pauses;
    await tester.runAsync(() => embedded.applyPlaybackSnapshot(
      LivePlaybackSnapshot(playing: false, muted: false, volume: 23),
      restorePlaying: false,
    ));
    expect(scene.embeddedNative.state.playing, isTrue);
    expect(scene.embeddedNative.state.volume, 23);
    expect(scene.embeddedNative.plays, plays);
    expect(scene.embeddedNative.pauses, pauses);
  });

  testWidgets('popped, transition completion and native-disposal completion remain distinct', (tester) async {
    final scene = _Scene();
    addTearDown(() => scene.finish(tester));
    await scene.mount(tester);
    final nativeDispose = (await tester.runAsync(() async => scene.outgoingNative.holdDisposal()))!;
    final receipt = LiveRoundtripReceipt();
    late Future<void> roundtrip;
    await tester.runAsync(() async { roundtrip = scene.liveKey.currentState!.watchLiveForProbe(receipt); });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    try {
      expect(scene.route.reverseTransitionDuration, greaterThan(Duration.zero));
      await tester.tap(find.text('Return fixture'));
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      expect(scene.popped, isTrue);
      expect(scene.transitionCompleted, isFalse);
      expect(find.byType(_ReportRoute), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      expect(scene.transitionCompleted, isTrue);
      expect(scene.outgoingNative.disposals, 1);
      expect(nativeDispose.entered.isCompleted, isTrue);
      expect(scene.outgoingNative.disposalFinished, isFalse,
          reason: 'A completed route is not evidence that an async native release finished.');
    } finally {
      nativeDispose.finish();
    }
    await tester.runAsync(() => roundtrip.timeout(const Duration(seconds: 5)));
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    expect(scene.outgoingNative.disposalFinished, isTrue);
  });
}
