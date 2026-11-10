@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/batch_bind.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

const _episodes = [
  Episode(id: 'e1', title: 'Episode One'),
  Episode(id: 'e2', title: 'Episode Two'),
];

class _CommentTransport implements DanmakuTransport {
  _CommentTransport({this.pending});
  final Completer<DanmakuHttpResponse>? pending;
  final fetched = <int>[];
  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    if (uri.path.contains('/comment/')) {
      fetched.add(int.parse(uri.pathSegments.last));
      if (pending != null) return pending!.future;
      return const DanmakuHttpResponse(
        statusCode: 200,
        body:
            '{"count":1,"comments":[{"cid":1,'
            '"p":"1,1,25,16777215,1700000000,0,fixture,1","m":"Bound"}]}',
      );
    }
    return const DanmakuHttpResponse(statusCode: 404, body: '{}');
  }

  @override
  void close() {}
}

class _RaceTransport implements DanmakuTransport {
  _RaceTransport({this.holdSearch = false});
  final bool holdSearch;
  final probes = <Completer<DanmakuHttpResponse>>[];
  final searches = <String>[];
  final searchResponses = <Completer<DanmakuHttpResponse>>[];
  final comments = _CommentTransport();
  static const probeResponse = DanmakuHttpResponse(
    statusCode: 200,
    body: '{"version":"fixture"}',
  );
  static const searchResponse = DanmakuHttpResponse(
    statusCode: 200,
    body:
        '{"animes":[{"animeTitle":"Old","episodes":['
        '{"episodeId":88,"episodeTitle":"Episode One"}]}]}',
  );

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    if (uri.path.endsWith('/version')) {
      final pending = Completer<DanmakuHttpResponse>();
      probes.add(pending);
      return pending.future;
    }
    if (uri.path.contains('/search/episodes')) {
      searches.add(uri.queryParameters['anime'] ?? '');
      if (holdSearch) {
        final pending = Completer<DanmakuHttpResponse>();
        searchResponses.add(pending);
        return pending.future;
      }
      return searchResponse;
    }
    if (uri.path.endsWith('/match')) {
      return const DanmakuHttpResponse(
        statusCode: 200,
        body:
            '{"isMatched":true,"matches":['
            '{"episodeId":88,"animeTitle":"Old","episodeTitle":"Episode One"}]}',
      );
    }
    return comments.send(
      method: method,
      uri: uri,
      headers: headers,
      body: body,
    );
  }

  @override
  void close() {}
}

Future<void> _switchContent(WidgetTester tester) async {
  final widget = tester.widget<PlayerPage>(find.byType(PlayerPage));
  final session = tester.state(find.byType(PlayerPage)) as MediaSession;
  await session.applySession(
    const PlayRequestData(
      provider: 'next',
      id: 'next-work',
      title: 'Next Work',
      episodeId: 'e1',
      episodeTitle: 'Episode One',
      episodes: _episodes,
    ),
  );
  await tester.pump();
  expect(
    identical(widget, tester.widget<PlayerPage>(find.byType(PlayerPage))),
    isTrue,
    reason: 'Exercise in-place applySession, not a replacement widget',
  );
  expect(
    tester.widget<DanmakuSearchPage>(find.byType(DanmakuSearchPage)).workTitle,
    'Next Work',
  );
}

Future<DanmakuSearchPage> _mountSearch(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });
  await tester.pumpWidget(
    const MaterialApp(
      home: PlayerPage(
        provider: 'fixture',
        id: 'work',
        title: 'Work',
        episodes: _episodes,
        episodeId: 'e1',
        episodeTitle: 'Episode One',
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(PlayerPage), findsOneWidget);
  // This native-media fixture deliberately has no playable stream. Expose its
  // controls for setup, then use the currently mounted production callbacks:
  // bottom-bar gear -> quick panel -> details/batch binding search page.
  expect(debugPlayerForceBarsForShot(), isTrue);
  await tester.pump();
  final gear = find.descendant(
    of: find.byKey(PlayerBottomBar.danmakuSettingsKey),
    matching: find.byType(ui.TextButton),
  );
  expect(gear, findsOneWidget);
  tester.widget<ui.TextButton>(gear).onPressed!();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsOneWidget);
  final details = find.descendant(
    of: find.byKey(PlayerBottomBar.danmakuQuickSearchKey),
    matching: find.byType(ui.TextButton),
  );
  expect(details, findsOneWidget);
  tester.widget<ui.TextButton>(details).onPressed!();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsNothing);
  expect(find.byType(DanmakuSearchPage), findsOneWidget);
  return tester.widget<DanmakuSearchPage>(find.byType(DanmakuSearchPage));
}

Future<void> _drainRequest(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() {
    UiPrefs.debugResetForTest(<String, String>{});
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async =>
        [];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      if (command == 'pan_cleanup_temp' || command == 'save_progress')
        return {};
      throw SourinCoreException('No fixture data', 'other');
    };
  });
  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinApi.debugResolveStreamFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    debugSetDanmakuTransportForTest(null);
    debugPlayerDanmakuLocalProbeTransportForTest = null;
    UiPrefs.debugResetForTest(<String, String>{});
  });

  testWidgets('single match closes search and loads the selected episode', (
    tester,
  ) async {
    final transport = _CommentTransport();
    debugSetDanmakuTransportForTest(transport);
    final search = await _mountSearch(tester);
    search.onPickMatch(
      const DanmakuMatch(
        episodeId: 12,
        animeTitle: 'Work',
        episodeTitle: 'Episode Two',
      ),
    );
    await _drainRequest(tester);
    expect(find.byType(DanmakuSearchPage), findsNothing);
    expect(transport.fetched, [12]);
    expect(debugPlayerDanmakuCount(), 1);
    expect(debugPlayerDanmakuEnabled(), isTrue);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'confirmed batch saves mapping and loads only the current episode',
    (tester) async {
      final transport = _CommentTransport();
      debugSetDanmakuTransportForTest(transport);
      final search = await _mountSearch(tester);
      search.onBatchBindPlan!(const [
        BatchBindPlanItem(
          episodeIndex: 0,
          episodeId: 11,
          episodeTitle: 'Episode One',
          workTitle: 'Work',
        ),
        BatchBindPlanItem(
          episodeIndex: 1,
          episodeId: 12,
          episodeTitle: 'Episode Two',
          workTitle: 'Work',
        ),
      ], 'Work');
      await _drainRequest(tester);
      expect(loadDanmakuBind('fixture', 'work')!.episodes, {0: 11, 1: 12});
      expect(find.byType(DanmakuSearchPage), findsNothing);
      expect(transport.fetched, [11]);
      expect(debugPlayerDanmakuCount(), 1);
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets('conflicting batch stays editable without overwriting a target', (
    tester,
  ) async {
    final search = await _mountSearch(tester);
    search.onBatchBindPlan!(const [
      BatchBindPlanItem(
        episodeIndex: 0,
        episodeId: 11,
        episodeTitle: 'Episode One',
        workTitle: 'Work',
      ),
      BatchBindPlanItem(
        episodeIndex: 0,
        episodeId: 12,
        episodeTitle: 'Episode Two',
        workTitle: 'Work',
      ),
    ], 'Work');
    await tester.pump(const Duration(milliseconds: 350));
    expect(loadDanmakuBind('fixture', 'work'), isNull);
    expect(find.byType(DanmakuSearchPage), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'selected comments arriving after a switch cannot replace the next',
    (tester) async {
      final pending = Completer<DanmakuHttpResponse>();
      final transport = _CommentTransport(pending: pending);
      debugSetDanmakuTransportForTest(transport);
      final search = await _mountSearch(tester);
      debugPlayerSetDanmakuEnabledForProbe(true);
      search.onPickMatch(
        const DanmakuMatch(
          episodeId: 12,
          animeTitle: 'Work',
          episodeTitle: 'Episode Two',
        ),
      );
      await _drainRequest(tester);
      expect(transport.fetched, [12]);
      await debugPlayerGotoEpisodeForProbe(_episodes[1]);
      await tester.pump();
      pending.complete(
        const DanmakuHttpResponse(
          statusCode: 200,
          body:
              '{"count":1,"comments":[{"cid":1,'
              '"p":"1,1,25,16777215,1700000000,0,fixture,1","m":"Old"}]}',
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(debugPlayerDanmakuCount(), 0);
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'search paused at local probe cannot dispatch into another session',
    (tester) async {
      final search = await _mountSearch(tester);
      final transport = _RaceTransport();
      debugPlayerDanmakuLocalProbeTransportForTest = transport;
      debugSetDanmakuTransportForTest(transport);
      search.onSearch('Old');
      await tester.pump();
      expect(transport.probes, hasLength(1));
      expect(
        debugPlayerDanmakuSettingsState()!.searchLoading,
        isTrue,
        reason: 'Local service preparation belongs to the pending search.',
      );
      await _switchContent(tester);
      transport.probes.single.complete(_RaceTransport.probeResponse);
      await _drainRequest(tester);
      expect(transport.searches, isEmpty);
      final state = tester
          .widget<DanmakuSearchPage>(find.byType(DanmakuSearchPage))
          .state;
      expect(state.searchResults, isEmpty);
      expect(state.searchLoading, isFalse);
      expect(state.searchStale, isTrue);
      await tester.pump(const Duration(seconds: 2));
    },
  );

  for (final fail in [false, true]) {
    testWidgets(
      'older same-session search ${fail ? "error" : "result"} cannot replace the latest result',
      (tester) async {
        final search = await _mountSearch(tester);
        final transport = _RaceTransport(holdSearch: true);
        debugPlayerDanmakuLocalProbeTransportForTest = transport;
        debugSetDanmakuTransportForTest(transport);
        search.onSearch('Old');
        await tester.pump();
        expect(transport.probes, hasLength(1));
        expect(debugPlayerDanmakuSettingsState()!.searchLoading, isTrue);
        transport.probes.single.complete(_RaceTransport.probeResponse);
        await _drainRequest(tester);
        expect(transport.searchResponses, hasLength(1));

        search.onSearch('Latest');
        await _drainRequest(tester);
        expect(transport.searchResponses, hasLength(2));
        transport.searchResponses[1].complete(
          const DanmakuHttpResponse(
            statusCode: 200,
            body:
                '{"animes":[{"animeTitle":"Latest","episodes":['
                '{"episodeId":99,"episodeTitle":"Episode Two"}]}]}',
          ),
        );
        await _drainRequest(tester);
        expect(debugPlayerDanmakuSettingsState()!.searchKeyword, 'Latest');
        expect(
          debugPlayerDanmakuSettingsState()!.searchResults.single.episodeId,
          99,
        );
        if (fail) {
          transport.searchResponses[0].completeError(StateError('Old failure'));
        } else {
          transport.searchResponses[0].complete(_RaceTransport.searchResponse);
        }
        await _drainRequest(tester);
        final state = debugPlayerDanmakuSettingsState()!;
        expect(state.searchKeyword, 'Latest');
        expect(state.searchResults.single.episodeId, 99);
        expect(state.searchLoading, isFalse);
        expect(state.searchError, isNull);
        expect(state.searchStale, isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'late search ${fail ? "error" : "results"} cannot update a new session',
      (tester) async {
        final search = await _mountSearch(tester);
        final transport = _RaceTransport(holdSearch: true);
        debugPlayerDanmakuLocalProbeTransportForTest = transport;
        debugSetDanmakuTransportForTest(transport);
        search.onSearch('Old');
        await tester.pump();
        expect(transport.probes, hasLength(1));
        transport.probes.single.complete(_RaceTransport.probeResponse);
        await _drainRequest(tester);
        expect(transport.searchResponses, hasLength(1));
        await _switchContent(tester);
        if (fail) {
          transport.searchResponses.single.completeError(
            StateError('Old search failure'),
          );
        } else {
          transport.searchResponses.single.complete(
            _RaceTransport.searchResponse,
          );
        }
        await _drainRequest(tester);
        final state = tester
            .widget<DanmakuSearchPage>(find.byType(DanmakuSearchPage))
            .state;
        expect(state.searchResults, isEmpty);
        expect(state.searchError, isNull);
        expect(state.searchLoading, isFalse);
        expect(state.searchStale, isTrue);
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  for (final newestFirst in [false, true]) {
    testWidgets(
      'same-session search probe ${newestFirst ? "reverse" : "forward"} completion dispatches only the latest keyword',
      (tester) async {
        final search = await _mountSearch(tester);
        final transport = _RaceTransport();
        debugPlayerDanmakuLocalProbeTransportForTest = transport;
        debugSetDanmakuTransportForTest(transport);
        search.onSearch('Old');
        await tester.pump();
        search.onSearch('Latest');
        await tester.pump();
        expect(transport.probes, hasLength(2));
        expect(debugPlayerDanmakuSettingsState()!.searchLoading, isTrue);
        expect(debugPlayerDanmakuSettingsState()!.searchKeyword, 'Latest');
        transport.probes[newestFirst ? 1 : 0].complete(
          _RaceTransport.probeResponse,
        );
        await _drainRequest(tester);
        expect(transport.searches, newestFirst ? ['Latest'] : isEmpty);
        expect(debugPlayerDanmakuSettingsState()!.searchLoading, !newestFirst);
        transport.probes[newestFirst ? 0 : 1].complete(
          _RaceTransport.probeResponse,
        );
        await _drainRequest(tester);
        expect(transport.searches, ['Latest']);
        final state = debugPlayerDanmakuSettingsState()!;
        expect(state.searchKeyword, 'Latest');
        expect(state.searchLoading, isFalse);
        expect(state.searchError, isNull);
        expect(state.searchStale, isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'same-session load probe ${newestFirst ? "reverse" : "forward"} completion preserves latest pin',
      (tester) async {
        final search = await _mountSearch(tester);
        final transport = _RaceTransport();
        debugPlayerDanmakuLocalProbeTransportForTest = transport;
        debugSetDanmakuTransportForTest(transport);
        final oldLoad = debugPlayerLoadDanmakuForProbe('Old Automatic');
        await tester.pump();
        expect(transport.probes, hasLength(1));
        search.onPickMatch(
          const DanmakuMatch(
            episodeId: 12,
            animeTitle: 'Latest',
            episodeTitle: 'Episode Two',
          ),
        );
        await tester.pump();
        expect(transport.probes, hasLength(2));
        transport.probes[newestFirst ? 1 : 0].complete(
          _RaceTransport.probeResponse,
        );
        await _drainRequest(tester);
        expect(
          transport.comments.fetched,
          newestFirst ? [12] : isEmpty,
          reason: 'An older load must not consume a newer selected episode pin',
        );
        transport.probes[newestFirst ? 0 : 1].complete(
          _RaceTransport.probeResponse,
        );
        await tester.runAsync(() => oldLoad);
        await _drainRequest(tester);
        expect(transport.comments.fetched, [12]);
        expect(debugPlayerDanmakuStatus(), contains('Latest'));
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }

  testWidgets(
    'in-place source change saves binding only under the active key',
    (tester) async {
      saveDanmakuBind(
        'fixture',
        'work',
        const DanmakuBindStore(
          workTitle: 'Original',
          episodes: {0: 99},
          updatedAt: 1,
        ),
      );
      debugSetDanmakuTransportForTest(_CommentTransport());
      await _mountSearch(tester);
      await _switchContent(tester);
      final search = tester.widget<DanmakuSearchPage>(
        find.byType(DanmakuSearchPage),
      );
      search.onBatchBindPlan!(const [
        BatchBindPlanItem(
          episodeIndex: 0,
          episodeId: 77,
          episodeTitle: 'Episode One',
          workTitle: 'Next Work',
        ),
      ], 'Next Work');
      await _drainRequest(tester);
      expect(loadDanmakuBind('fixture', 'work')!.episodes, {0: 99});
      expect(loadDanmakuBind('next', 'next-work')!.episodes, {0: 77});
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'in-place source change loads the active binding not the old widget key',
    (tester) async {
      saveDanmakuBind(
        'fixture',
        'work',
        const DanmakuBindStore(
          workTitle: 'Original',
          episodes: {0: 99},
          updatedAt: 1,
        ),
      );
      saveDanmakuBind(
        'next',
        'next-work',
        const DanmakuBindStore(
          workTitle: 'Next Work',
          episodes: {0: 77},
          updatedAt: 1,
        ),
      );
      final transport = _CommentTransport();
      debugSetDanmakuTransportForTest(transport);
      await _mountSearch(tester);
      await _switchContent(tester);
      await tester.runAsync(() => debugPlayerLoadDanmakuForProbe('Next Work'));
      await _drainRequest(tester);
      expect(transport.fetched, [77]);
      await tester.pump(const Duration(seconds: 2));
    },
  );
}
