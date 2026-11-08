@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'support/miuix_finders.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player/episode_panel.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart' show LineChip;

const _episodes = [
  Episode(id: 'A1', title: '第1集', index: 0, flag: '线路A'),
  Episode(id: 'A2', title: '第2集', index: 1, flag: '线路A'),
  Episode(id: 'B1', title: '第01集', index: 2, flag: '线路B'),
  Episode(id: 'B2', title: '第02集', index: 3, flag: '线路B'),
];

Future<void> _mount(
  WidgetTester t, {
  Size size = const Size(1280, 800),
  bool tv = false,
  List<Episode> episodes = _episodes,
  int episodeIndex = 1,
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  addTearDown(() async {
    if (find.byType(PlayerPage).evaluate().isNotEmpty) await _dispose(t);
  });
  await t.pumpWidget(MaterialApp(
    home: PlayerPage(
      provider: 'line-fixture',
      id: 'series',
      title: '线路切换',
      episodes: episodes,
      episodeIndex: episodeIndex,
      episodeId: episodes[episodeIndex].id,
      episodeTitle: episodes[episodeIndex].title,
      isTv: tv,
      isTouchOnly: size.width < 600,
    ),
  ));
  await t.pump();
}

Future<void> _dispose(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
}

Future<void> _pickLine(WidgetTester t, String flag) async {
  final chip = find.byWidgetPredicate((w) => w is LineChip && w.flag == flag);
  await t.ensureVisible(chip);
  await t.tap(chip);
  // Allow the host's double-tap gesture arena and sheet motion to finish.
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
  });
  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = null;
  });

  for (final entry in [
    (const Size(1280, 800), false, 'desktop'),
    (const Size(360, 800), false, 'phone'),
    (const Size(1280, 720), true, 'tv'),
  ]) {
    testWidgets('${entry.$3}: line selection requests the same episode and keeps position',
        (t) async {
      final requests = <PlayRequest?>[];
      SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
        requests.add(req);
        return [];
      };
      await _mount(t, size: entry.$1, tv: entry.$2);
      expect(requests.single?.episodeId, 'A2');
      expect(requests.single?.episodeTitle, '第2集');
      expect(requests.single?.episodeOrder, 2);
      debugPlayerSetPositionOnlyForProbe(const Duration(seconds: 123));
      expect(find.text('线路'), findsOneWidget,
          reason: 'Failed parsing must still offer a real line-switch entry.');
      await t.tap(find.text('线路'));
      await t.pump(const Duration(milliseconds: 400));
      final before = requests.length;
      final stalled = Completer<List<StreamCandidate>>();
      SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) {
        requests.add(req);
        return stalled.future;
      };

      // Drive the rendered control. Keep the parser pending to observe resume intent.
      await _pickLine(t, '线路B');
      expect(requests.length, before + 1,
          reason: 'Changing a line must fetch a new stream, not only change its highlight.');
      expect(requests.last?.episodeId, 'B2');
      expect(requests.last?.flag, '线路B');
      expect(requests.last?.episodeTitle, '第02集');
      expect(requests.last?.episodeOrder, 2,
          reason: 'The B line has two episodes, not four global positions.');
      expect(debugPlayerPendingSeekForProbe(), const Duration(seconds: 123));
      expect(t.widget<PlayerEpisodePanel>(find.byType(PlayerEpisodePanel)).selectedFlag,
          '线路B');
      expect(t.takeException(), isNull);
      stalled.complete([]);
      await t.pump();
      SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
        requests.add(req);
        return [];
      };
      await _pickLine(t, '线路A');
      expect(requests.last?.episodeId, 'A2');
      expect(requests.last?.episodeOrder, 2);
      expect(debugPlayerPendingSeekForProbe(), const Duration(seconds: 123));
      await _dispose(t);
    });
  }

  testWidgets('selected initial line follows the current episode, not the first flag',
      (t) async {
    final requests = <PlayRequest?>[];
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
      requests.add(req);
      return [];
    };
    await _mount(t, episodeIndex: 3);
    expect(requests.single?.episodeId, 'B2');
    expect(requests.single?.flag, '线路B');
    expect(requests.single?.episodeTitle, '第02集');
    expect(requests.single?.episodeOrder, 2);
    await _dispose(t);
  });

  testWidgets('missing current episode never resolves another line with the old id',
      (t) async {
    final requests = <PlayRequest?>[];
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
      requests.add(req);
      return [];
    };
    await _mount(t, episodes: _episodes.sublist(0, 3));
    expect(debugPlayerOpenEpisodesForProbe(), isTrue);
    await t.pump();
    final before = requests.length;
    await _pickLine(t, '线路B');
    expect(requests.length, before);
    expect(debugPlayerEpisodeIndexForProbe(), 1);
    expect(debugPlayerErrorForProbe(), contains('没有当前集'));
    await _pickLine(t, '线路A');
    expect(requests.length, before + 1);
    expect(requests.last?.episodeId, 'A2');
    await _dispose(t);
  });

  testWidgets('shared ids keep the selected line identity and its local order', (t) async {
    const eps = [
      Episode(id: 'shared-1', title: '第1集', index: 0, flag: '线路A'),
      Episode(id: 'shared-2', title: '第2集', index: 1, flag: '线路A'),
      Episode(id: 'shared-1', title: '第01集', index: 2, flag: '线路B'),
      Episode(id: 'shared-2', title: '第02集', index: 3, flag: '线路B'),
    ];
    final requests = <PlayRequest?>[];
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
      requests.add(req);
      return [];
    };
    await _mount(t, episodes: eps);
    expect(debugPlayerOpenEpisodesForProbe(), isTrue);
    await t.pump(const Duration(milliseconds: 400));
    await _pickLine(t, '线路B');
    expect(requests.last?.episodeId, 'shared-2');
    expect(requests.last?.flag, '线路B');
    expect(requests.last?.episodeTitle, '第02集');
    expect(requests.last?.episodeOrder, 2);
    await debugPlayerGotoEpisodeForProbe(eps[2]);
    await t.pump();
    expect(requests.last?.episodeId, 'shared-1');
    expect(requests.last?.flag, '线路B');
    expect(requests.last?.episodeTitle, '第01集');
    expect(requests.last?.episodeOrder, 1);
    expect(debugPlayerEpisodeIndexForProbe(), 2);
    await _dispose(t);
  });

  testWidgets('season episode notation maps by episode, not season number', (t) async {
    const eps = [
      Episode(id: 'A2', title: 'S01E02', index: 0, flag: '线路A'),
      Episode(id: 'B1', title: '第1集', index: 1, flag: '线路B'),
      Episode(id: 'B2', title: '第2集', index: 2, flag: '线路B'),
    ];
    final requests = <PlayRequest?>[];
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
      requests.add(req);
      return [];
    };
    await _mount(t, episodes: eps, episodeIndex: 0);
    expect(debugPlayerOpenEpisodesForProbe(), isTrue);
    await t.pump(const Duration(milliseconds: 400));
    await _pickLine(t, '线路B');
    expect(requests.last?.episodeId, 'B2');
    expect(requests.last?.episodeOrder, 2);
    await _dispose(t);
  });

  testWidgets('same-year movie names do not imply the same episode', (t) async {
    const eps = [
      Episode(id: 'A', title: '2024电影甲', index: 0, flag: '线路A'),
      Episode(id: 'B', title: '2024电影乙', index: 1, flag: '线路B'),
    ];
    final requests = <PlayRequest?>[];
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
      requests.add(req);
      return [];
    };
    await _mount(t, episodes: eps, episodeIndex: 0);
    expect(debugPlayerOpenEpisodesForProbe(), isTrue);
    await t.pump(const Duration(milliseconds: 400));
    await _pickLine(t, '线路B');
    expect(requests, hasLength(1));
    expect(debugPlayerEpisodeIndexForProbe(), 0);
    expect(debugPlayerErrorForProbe(), contains('没有当前集'));
    await _dispose(t);
  });

  testWidgets('retry requests the newly selected line episode, not the widget entry',
      (t) async {
    final requests = <PlayRequest?>[];
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
      requests.add(req);
      return [];
    };
    await _mount(t);
    await t.tap(find.text('线路'));
    await t.pump(const Duration(milliseconds: 400));
    await _pickLine(t, '线路B');
    await t.tap(miuixTooltip('关闭'));
    await t.pump(const Duration(milliseconds: 400));
    final before = requests.length;
    await t.tap(find.text('重试'));
    await t.pump(const Duration(milliseconds: 400));
    expect(requests.length, before + 1);
    expect(requests.last?.episodeId, 'B2');
    expect(requests.last?.flag, '线路B');
    expect(requests.last?.episodeTitle, '第02集');
    expect(requests.last?.episodeOrder, 2);
    await _dispose(t);
  });

  testWidgets('source switching transports the matched target episode context', (t) async {
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async => [];
    await _mount(t);
    PlayRequest? target;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
      target = req;
      return [];
    };
    expect(
      await debugPlayerApplySwitchForProbe(
        provider: 'other-fixture',
        id: 'other-series',
        detail: const MediaDetail(
          id: 'other-series',
          title: '线路切换',
          episodes: [
            Episode(id: 'C1', title: '第01集', index: 0, flag: '线路C'),
            Episode(id: 'C2', title: '第02集', index: 1, flag: '线路C'),
          ],
        ),
      ),
      isTrue,
    );
    expect(target?.episodeId, 'C2');
    expect(target?.flag, '线路C');
    expect(target?.episodeTitle, '第02集');
    expect(target?.episodeOrder, 2);
    await _dispose(t);
  });

  testWidgets('a successful rendered line selection reaches playback startup', (t) async {
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async => [];
    await _mount(t);
    expect(debugPlayerOpenEpisodesForProbe(), isTrue);
    await t.pump();
    final before = debugPlayerStartPlaybackCallsForProbe()!;
    PlayRequest? selected;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
      selected = req;
      return [const StreamCandidate(url: 'https://fixture.invalid/second.m3u8')];
    };
    await _pickLine(t, '线路B');
    await t.pump();
    expect(selected?.episodeId, 'B2');
    expect(debugPlayerStartPlaybackCallsForProbe(), before + 1);
    expect(debugPlayerStreamUrlsForProbe(), ['https://fixture.invalid/second.m3u8']);
    await _dispose(t);
  });

  testWidgets('a superseded line response cannot replace the latest line', (t) async {
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async => [];
    await _mount(t);
    expect(debugPlayerOpenEpisodesForProbe(), isTrue);
    await t.pump();
    final stale = Completer<List<StreamCandidate>>();
    final current = Completer<List<StreamCandidate>>();
    final requests = <PlayRequest?>[];
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) {
      requests.add(req);
      return req?.flag == '线路B' ? stale.future : current.future;
    };
    final before = debugPlayerStartPlaybackCallsForProbe()!;
    await _pickLine(t, '线路B');
    await _pickLine(t, '线路A');
    expect(requests.map((r) => r?.episodeId), ['B2', 'A2']);
    current.complete([]);
    await t.pump();
    stale.complete([
      const StreamCandidate(url: 'https://fixture.invalid/stale.m3u8'),
    ]);
    await t.pump();
    expect(debugPlayerEpisodeIndexForProbe(), 1);
    expect(debugPlayerStreamUrlsForProbe(), isEmpty);
    expect(debugPlayerStartPlaybackCallsForProbe(), before);
    expect(debugPlayerErrorForProbe(), contains('没有可播放'));
    await _dispose(t);
  });
}
