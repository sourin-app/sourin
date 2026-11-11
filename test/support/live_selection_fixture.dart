// Reuses the raw-core/real-Miuix-row pattern from
// test/live_channel_keyboard_reveal_test.dart. No native Player is constructed.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

const selectionProvider = 'selection-primary';
const selectionOtherProvider = 'selection-other';
const selectionA = 'a';
const selectionB = 'b';

List<dynamic> selectionGroups({bool includeB = true}) => [
  {
    'provider': selectionProvider,
    'providerName': 'Selection primary',
    'channels': [
      {'id': selectionA, 'name': 'Primary channel A'},
      if (includeB) {'id': selectionB, 'name': 'Primary channel B'},
    ],
  },
  {
    'provider': selectionOtherProvider,
    'providerName': 'Selection other',
    'channels': [
      {'id': selectionA, 'name': 'Other-provider channel A'},
    ],
  },
];

String selectionUrl(
  String provider,
  String channel, [
  String revision = 'base',
]) => 'https://live-selection.invalid/$provider/$channel-$revision.mp4';

List<dynamic> selectionStream(
  String provider,
  String channel, [
  String revision = 'base',
]) => [
  {'url': selectionUrl(provider, channel, revision), 'kind': 'mp4'},
];

class SelectionRawReply {
  final result = Completer<dynamic>();
  bool entered = false;

  void succeed(dynamic value) {
    if (!result.isCompleted) result.complete(value);
  }

  void fail() {
    if (!result.isCompleted) {
      result.completeError(StateError('Synthetic held stream failure'));
    }
  }
}

class LiveSelectionScene {
  final key = GlobalKey<LivePageState>();
  final streamRequests = <({String provider, String channel})>[];
  final unexpected = <String>[];
  final _allReplies = <SelectionRawReply>[];
  final _streamReplies = <String, List<SelectionRawReply>>{};
  SelectionRawReply? _nextGroups;
  int groupReads = 0;
  bool _finished = false;

  late bool _oldSkip;
  late bool? _oldForced;
  late bool _oldHitWarnings;
  late String? _oldDirectory;
  late Future<dynamic> Function(String, Map<String, dynamic>?)? _oldCore;
  late Future<List<LiveGroup>> Function()? _oldGroups;
  late Future<List<StreamCandidate>> Function(String, String)? _oldStreams;

  SelectionRawReply holdGroups() {
    expect(_nextGroups, isNull);
    final reply = SelectionRawReply();
    _allReplies.add(reply);
    _nextGroups = reply;
    return reply;
  }

  SelectionRawReply holdStream(String provider, String channel) {
    final reply = SelectionRawReply();
    _allReplies.add(reply);
    _streamReplies.putIfAbsent('$provider:$channel', () => []).add(reply);
    return reply;
  }

  Future<dynamic> _core(String command, Map<String, dynamic>? args) async {
    if (command == 'get_live_channels') {
      groupReads++;
      final reply = _nextGroups;
      _nextGroups = null;
      if (reply == null) return selectionGroups();
      reply.entered = true;
      return await reply.result.future;
    }
    if (command == 'get_live_stream') {
      final provider = args!['provider'] as String;
      final channel = args['channel_id'] as String;
      streamRequests.add((provider: provider, channel: channel));
      final queue = _streamReplies['$provider:$channel'];
      if (queue == null || queue.isEmpty) {
        return selectionStream(provider, channel);
      }
      final reply = queue.removeAt(0);
      reply.entered = true;
      return await reply.result.future;
    }
    unexpected.add(command);
    throw StateError('Unexpected selection fixture command: $command');
  }

  Future<void> mount(
    WidgetTester tester, {
    bool initialStreamHeld = false,
  }) async {
    _oldSkip = debugSkipPlayerCreation;
    _oldForced = debugForcePlaying;
    _oldCore = SourinCore.debugCallAsyncTransport;
    _oldDirectory = DiskCache.dataDir;
    _oldGroups = LivePageState.debugLiveGroupsFetcher;
    _oldStreams = SourinApi.debugLiveStreamFetcher;
    _oldHitWarnings = WidgetController.hitTestWarningShouldBeFatal;
    addTearDown(() => finish(tester));
    debugSkipPlayerCreation = true;
    debugForcePlaying = null;
    WidgetController.hitTestWarningShouldBeFatal = true;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String, String>{});
    LivePageState.debugLiveGroupsFetcher = null;
    SourinApi.debugLiveStreamFetcher = null;
    SourinApi.debugClearLiveStreamCache();
    SourinCore.debugCallAsyncTransport = _core;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (_, child) => AppThemeHost(data: theme, child: child!),
        home: Scaffold(body: LivePage(key: key)),
      ),
    );
    await drain(tester);
    expect(groupReads, 1);
    expect(streamRequests, [
      (provider: selectionProvider, channel: selectionA),
    ]);
    expectSelected(tester, selectionProvider, selectionA);
    expect(
      streamUrl(tester),
      initialStreamHeld ? null : selectionUrl(selectionProvider, selectionA),
      reason: 'Raw core decoding and the actual selected stream must be ready',
    );
  }

  Future<void> drain(WidgetTester tester) async {
    for (var turn = 0; turn < 12; turn++) {
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    }
    await tester.pump();
  }

  Future<void> pick(
    WidgetTester tester,
    String provider,
    String channel,
  ) async {
    final target = find.byKey(liveChannelTileKey(provider, channel));
    expect(target, findsOneWidget);
    expect(target.hitTestable(), findsOneWidget);
    await tester.tap(target);
    await drain(tester);
    expectSelected(tester, provider, channel);
  }

  void expectSelected(WidgetTester tester, String provider, String channel) {
    expect(
      tester.widget<LiveChannelList>(find.byType(LiveChannelList)).selectedRow,
      liveChannelRowKey(provider, channel),
      reason: 'The actual rendered list must retain provider/native identity',
    );
    final highlight = find.byKey(liveChannelHighlightKey(provider, channel));
    expect(highlight, findsOneWidget);
    bool? selected;
    tester.element(highlight).visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Semantics && widget.properties.selected != null) {
        selected = widget.properties.selected;
        return false;
      }
      return true;
    });
    expect(
      selected,
      isTrue,
      reason: 'The clicked row must really be highlighted',
    );
  }

  String? streamUrl(WidgetTester tester) => tester
      .widget<LiveEmbeddedPlayer>(find.byType(LiveEmbeddedPlayer))
      .stream
      ?.url;

  Future<void> complete(
    WidgetTester tester,
    SelectionRawReply reply,
    dynamic value, {
    bool failure = false,
  }) async {
    expect(reply.entered, isTrue, reason: 'The held request must have started');
    await tester.runAsync(() async {
      if (failure) {
        reply.fail();
      } else {
        reply.succeed(value);
      }
      await Future<void>.delayed(Duration.zero);
    });
    await drain(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    if (_finished) return;
    _finished = true;
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        for (final reply in _allReplies) {
          // Complete only observed requests: an unused prepared hold has no
          // listener and must never be completed with an unhandled error.
          reply.succeed(<dynamic>[]);
        }
        await Future<void>.delayed(Duration.zero);
      });
      await drain(tester);
      expect(find.byType(LivePage), findsNothing);
      expect(unexpected, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      SourinCore.debugCallAsyncTransport = _oldCore;
      LivePageState.debugLiveGroupsFetcher = _oldGroups;
      SourinApi.debugLiveStreamFetcher = _oldStreams;
      SourinApi.debugClearLiveStreamCache();
      DiskCache.debugResetForTest(_oldDirectory);
      UiPrefs.debugResetForTest(<String, String>{});
      debugSkipPlayerCreation = _oldSkip;
      debugForcePlaying = _oldForced;
      WidgetController.hitTestWarningShouldBeFatal = _oldHitWarnings;
      tester.view.reset();
    }
  }
}
