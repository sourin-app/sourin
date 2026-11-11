import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

class _DelayedNative extends Fake implements NativePlayer {
  final waitingForPolicy = Completer<void>();
  final policyReadback = Completer<String>();
  int policyReads = 0;

  @override
  Future<void> setProperty(String name, String value,
      {bool waitForInitialization = true}) async {}

  @override
  Future<String> getProperty(String name,
      {bool waitForInitialization = true}) async {
    if (name == 'stream-lavf-o') {
      policyReads++;
      if (!waitingForPolicy.isCompleted) waitingForPolicy.complete();
      return policyReadback.future;
    }
    return '';
  }
}

class _PlayerBoundary extends Fake implements Player {
  _PlayerBoundary(this.platform);

  @override
  final NativePlayer platform;
  final opened = <Playable>[];
  int stops = 0;
  int plays = 0;
  int disposals = 0;
  PlayerState _state = const PlayerState();

  @override
  PlayerState get state => _state;

  @override
  Future<void> setVolume(double volume) async {
    _state = _state.copyWith(volume: volume);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable);
  }

  @override
  Future<void> stop() async { stops++; }

  @override
  Future<void> play() async { plays++; }

  @override
  Future<void> dispose() async { disposals++; }
}

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: child),
  );
}

const _first = StreamCandidate(url: 'https://fixture.invalid/first.m3u8');
const _second = StreamCandidate(url: 'https://fixture.invalid/second.m3u8');

class _Scene {
  final selected = ValueNotifier<StreamCandidate?>(_first);
  final visible = ValueNotifier(true);
  final key = GlobalKey<LiveEmbeddedPlayerState>();
  final native = _DelayedNative();
  late final player = _PlayerBoundary(native);
  final errors = <String>[];

  Future<void> mount(WidgetTester tester) async {
    addTearDown(selected.dispose);
    addTearDown(visible.dispose);
    await tester.pumpWidget(_host(ValueListenableBuilder<StreamCandidate?>(
      valueListenable: selected,
      builder: (_, stream, __) => LiveEmbeddedPlayer(
        key: key,
        stream: stream,
        visible: visible,
        title: '频道',
        onError: errors.add,
      ),
    )));
    key.currentState!.attachPlayerForTest(player);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Any production output watcher already pending must observe disposal.
    await tester.pump(const Duration(seconds: 1));
    expect(player.disposals, 1);
    expect(tester.takeException(), isNull);
  }
}

void main() {
  setUp(() { debugSkipPlayerCreation = true; });
  tearDown(() { debugSkipPlayerCreation = false; });

  for (final initial in [false, true]) {
    testWidgets('clearing the selected stream cancels a pending native transport await (${initial ? 'initial' : 'switch'})', (tester) async {
    final scene = _Scene();
    await scene.mount(tester);
    final opening = initial
        ? scene.key.currentState!.retry()
        : scene.key.currentState!.open(_first);
    await tester.pump();
    expect(scene.native.waitingForPolicy.isCompleted, isTrue);
    expect(scene.player.opened, isEmpty);
    scene.selected.value = null;
    await tester.pump();
    expect(scene.player.stops, 1, reason: 'The real widget cancellation must stop the selected stream.');
    scene.native.policyReadback.complete('http_proxy=');
    await tester.pump();
    await opening;
    expect(scene.player.opened, isEmpty, reason: 'The cancelled native-policy continuation must never reopen media.');
    expect(scene.player.plays, 0);
    expect(scene.key.currentState!.pendingStreamForTest, isNull);
    expect(scene.errors, isEmpty);
    await scene.finish(tester);
    });
  }

  testWidgets('hidden cancellation does not revive the old stream on return', (tester) async {
    final scene = _Scene();
    await scene.mount(tester);
    final opening = scene.key.currentState!.open(_first);
    await tester.pump();
    expect(scene.native.waitingForPolicy.isCompleted, isTrue);
    scene.visible.value = false;
    scene.native.policyReadback.complete('http_proxy=');
    await tester.pump();
    await opening;
    expect(scene.key.currentState!.pendingStreamForTest, _first);
    scene.selected.value = null;
    await tester.pump();
    scene.visible.value = true;
    await tester.pump();
    expect(scene.native.policyReads, 1);
    expect(scene.player.opened, isEmpty);
    expect(scene.player.plays, 0);
    expect(scene.key.currentState!.pendingStreamForTest, isNull);
    await scene.finish(tester);
  });

  testWidgets('disposing during native transport await cannot open or publish an error', (tester) async {
    final scene = _Scene();
    await scene.mount(tester);
    final opening = scene.key.currentState!.open(_first);
    await tester.pump();
    expect(scene.native.waitingForPolicy.isCompleted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    scene.native.policyReadback.complete('http_proxy=');
    await tester.pump();
    await opening;
    expect(scene.player.opened, isEmpty);
    expect(scene.player.plays, 0);
    expect(scene.errors, isEmpty);
    expect(scene.player.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cancelled policy failure cannot replace the empty selection with an error', (tester) async {
    final scene = _Scene();
    await scene.mount(tester);
    final opening = scene.key.currentState!.open(_first);
    await tester.pump();
    expect(scene.native.waitingForPolicy.isCompleted, isTrue);
    scene.selected.value = null;
    await tester.pump();
    scene.native.policyReadback.complete('');
    await tester.pump();
    await opening;
    expect(scene.player.opened, isEmpty);
    expect(scene.player.plays, 0);
    expect(scene.errors, isEmpty);
    expect(find.textContaining('播放连接配置未能完成'), findsNothing);
    await scene.finish(tester);
  });

  testWidgets('the newest selected stream still opens after older transport work completes', (tester) async {
    final scene = _Scene();
    await scene.mount(tester);
    final oldOpening = scene.key.currentState!.open(_first);
    await tester.pump();
    expect(scene.native.waitingForPolicy.isCompleted, isTrue);
    scene.selected.value = _second;
    await tester.pump();
    expect(scene.native.policyReads, 2);
    scene.native.policyReadback.complete('http_proxy=');
    await tester.pump();
    await oldOpening;
    expect(scene.player.opened, hasLength(1));
    expect((scene.player.opened.single as Media).uri, _second.url);
    expect(scene.player.plays, 1);
    expect(scene.player.state.volume, 0,
        reason: 'Opening the newest stream must retain the default mute.');
    expect(scene.errors, isEmpty);
    await scene.finish(tester);
  });
}
