@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const _raw = 'csp-yinhai-fixture::https://pan.quark.cn/s/fixture';
const _files = [
  Episode(
    id: 'csp-yinhai-fixture::panfile:third',
    title: 'Episode 03.mp4',
    index: 0,
    flag: 'Quark',
  ),
  Episode(
    id: 'csp-yinhai-fixture::panfile:fourth',
    title: 'Episode 04.mp4',
    index: 1,
    flag: 'Quark',
  ),
  Episode(
    id: 'csp-yinhai-fixture::panfile:first',
    title: 'Episode 01.mp4',
    index: 2,
    flag: 'Quark',
  ),
];
const _stream = [
  {'url': 'https://fixture.invalid/current.m3u8', 'kind': 'hls'},
];
const _multiVideo =
    '\u5206\u4eab\u91cc\u6709\u591a\u4e2a\u89c6\u9891\uff0c'
    '\u8bf7\u5237\u65b0\u8be6\u60c5\u540e\u9009\u62e9\u5177\u4f53\u6587\u4ef6';

final _requests = <Map<String, dynamic>>[];
Future<dynamic> Function(Map<String, dynamic>)? _resolve;
Map<String, dynamic>? _storedProgress;

Future<MediaSession> _mount(
  WidgetTester t, {
  String? episodeId = _raw,
  int episodeIndex = 0,
  List<Episode> episodes = const [],
}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  addTearDown(() async {
    if (find.byType(PlayerPage).evaluate().isNotEmpty) await _dispose(t);
  });
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'tvbox_agg',
        id: 'csp-yinhai-fixture::share-item',
        title: 'Share',
        episodeId: episodeId,
        episodeIndex: episodeIndex,
        episodes: episodes,
      ),
    ),
  );
  await t.pump();
  return (t.state(find.byType(PlayerPage)) as dynamic) as MediaSession;
}

Future<void> _dispose(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
}

Future<void> _advance(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() {
    _requests.clear();
    _resolve = null;
    _storedProgress = null;
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinCore.debugCallAsyncTransport = (cmd, args) async {
      if (cmd == 'resolve_stream') {
        final req = Map<String, dynamic>.from((args!['req'] as Map));
        _requests.add(req);
        return _resolve == null ? [] : await _resolve!(req);
      }
      if (cmd == 'pan_cleanup_temp') return <String, dynamic>{};
      if (cmd == 'get_progress') return _storedProgress;
      throw SourinCoreException('isolated fixture has no data', 'other');
    };
  });
  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    _resolve = null;
    _storedProgress = null;
  });

  for (final staleFailure in [true, false]) {
    testWidgets(
      'concrete files supersede pending share ${staleFailure ? 'error' : 'result'}',
      (t) async {
        final stale = Completer<dynamic>();
        final selected = Completer<dynamic>();
        _resolve = (_) =>
            _requests.length == 1 ? stale.future : selected.future;
        final session = await _mount(t);
        expect(_requests.single['episode_id'], _raw);
        final generation = debugPlayerSessionGenForProbe()!;
        session.updateEpisodes(_files);
        await t.pump();
        expect(_requests, hasLength(2));
        expect(_requests.last['episode_id'], _files.first.id);
        expect(_requests.last['episode_title'], 'Episode 03.mp4');
        expect(
          _requests.last['episode_order'],
          1,
          reason: 'Server list order is not the episode number embedded in a filename.',
        );
        expect(_requests.last['flag'], 'Quark');
        expect(debugPlayerSessionGenForProbe(), greaterThan(generation));
        selected.complete(_stream);
        await _advance(t);
        final starts = debugPlayerStartPlaybackCallsForProbe();
        if (staleFailure) {
          stale.completeError(SourinCoreException(_multiVideo, 'other'));
        } else {
          stale.complete([
            {
              'url': 'https://fixture.invalid/wrong-episode.m3u8',
              'kind': 'hls',
            },
          ]);
        }
        await _advance(t);
        expect(session.currentEpisodeId, _files.first.id);
        expect(debugPlayerErrorForProbe(), isNull);
        expect(debugPlayerStreamUrlsForProbe(), [
          'https://fixture.invalid/current.m3u8',
        ]);
        expect(debugPlayerStartPlaybackCallsForProbe(), starts);
        await _dispose(t);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets('concrete detail recovers an already failed raw share once', (
    t,
  ) async {
    _resolve = (_) async {
      if (_requests.length == 1) {
        throw SourinCoreException(_multiVideo, 'other');
      }
      return _stream;
    };
    final session = await _mount(t);
    await _advance(t);
    expect(debugPlayerErrorForProbe(), contains(_multiVideo));
    session.updateEpisodes(_files);
    await _advance(t);
    expect(_requests, hasLength(2));
    expect(_requests.last['episode_id'], _files.first.id);
    expect(debugPlayerErrorForProbe(), isNull);
    session.updateEpisodes(_files);
    await t.pump();
    expect(
      _requests,
      hasLength(2),
      reason: 'Repeated detail callbacks must be idempotent.',
    );
    await _dispose(t);
  });

  testWidgets(
    'an explicit file id survives late detail reordering without reopening',
    (t) async {
      _resolve = (_) async => _stream;
      final session = await _mount(t, episodeId: _files[1].id, episodeIndex: 0);
      await _advance(t);
      final starts = debugPlayerStartPlaybackCallsForProbe();
      final generation = debugPlayerSessionGenForProbe();
      session.updateEpisodes(_files);
      await _advance(t);
      expect(session.currentEpisodeId, _files[1].id);
      expect(_requests, hasLength(1));
      expect(debugPlayerStartPlaybackCallsForProbe(), starts);
      expect(debugPlayerSessionGenForProbe(), generation);
      await _dispose(t);
    },
  );

  testWidgets('ordinary list backfill keeps the healthy stream and position', (
    t,
  ) async {
    _resolve = (_) async => _stream;
    final session = await _mount(t, episodeId: null);
    await _advance(t);
    debugPlayerSetPositionOnlyForProbe(const Duration(seconds: 123));
    final starts = debugPlayerStartPlaybackCallsForProbe();
    final generation = debugPlayerSessionGenForProbe();
    session.updateEpisodes(const [
      Episode(id: 'ordinary-1', title: 'Episode 1', index: 0),
      Episode(id: 'ordinary-2', title: 'Episode 2', index: 1),
    ]);
    await _advance(t);
    expect(_requests, hasLength(1));
    expect(debugPlayerStartPlaybackCallsForProbe(), starts);
    expect(debugPlayerSessionGenForProbe(), generation);
    expect(
      debugPlayerSessionCurrentPositionForProbe(),
      const Duration(seconds: 123),
    );
    await _dispose(t);
  });

  testWidgets(
    'in-place session without a list retains its explicit file identity',
    (t) async {
      _resolve = (_) async => _stream;
      final session = await _mount(t, episodeId: null);
      await _advance(t);
      await session.applySession(
        PlayRequestData(
          provider: 'tvbox_agg',
          id: 'csp-yinhai-fixture::other-share',
          title: 'Other share',
          episodeId: _files[1].id,
          episodeTitle: _files[1].title,
          episodeIndex: 1,
        ),
      );
      await _advance(t);
      expect(_requests.last['episode_id'], _files[1].id);
      expect(_requests.last['episode_title'], _files[1].title);
      final progress = (session as MediaProgressSession).playbackProgress.value;
      expect(progress?.episodeId, _files[1].id);
      expect(progress?.episodeTitle, _files[1].title);
      session.updateEpisodes(_files);
      await _advance(t);
      expect(session.currentEpisodeId, _files[1].id);
      expect(_requests, hasLength(2));
      await _dispose(t);
      expect(t.takeException(), isNull);
    },
  );

  for (final matches in [true, false]) {
    testWidgets(
      'listless replacement resumes only its own file (matches=$matches)',
      (t) async {
        _resolve = (_) async => _stream;
        final session = await _mount(t);
        await _advance(t);
        _storedProgress = Progress(
          key: 'fixture-progress',
          provider: 'tvbox_agg',
          nativeId: 'csp-yinhai-fixture::other-share',
          title: 'Other share',
          episodeId: matches ? _files[1].id : _raw,
          position: 123,
          duration: 1800,
          updatedAt: 1,
        ).toJson();
        await session.applySession(
          PlayRequestData(
            provider: 'tvbox_agg',
            id: 'csp-yinhai-fixture::other-share',
            title: 'Other share',
            episodeId: _files[1].id,
            episodeTitle: _files[1].title,
          ),
        );
        await _advance(t);
        expect(session.currentEpisodeId, _files[1].id);
        expect(await debugPlayerPrepareResumeForProbe(), isTrue);
        expect(
          debugPlayerPendingSeekForProbe(),
          matches ? const Duration(seconds: 123) : isNull,
        );
        await _dispose(t);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a missing explicit file is never replaced by another list entry',
    (t) async {
      _resolve = (_) async => _stream;
      final session = await _mount(t, episodeId: _files[1].id);
      await _advance(t);
      final starts = debugPlayerStartPlaybackCallsForProbe();
      session.updateEpisodes([_files.first, _files.last]);
      await _advance(t);
      expect(session.currentEpisodeId, _files[1].id);
      expect(_requests, hasLength(1));
      expect(debugPlayerStartPlaybackCallsForProbe(), starts);
      expect(
        (session as MediaProgressSession).playbackProgress.value?.episodeId,
        _files[1].id,
      );
      await _dispose(t);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('duplicate file IDs retain their selected line after backfill', (
    t,
  ) async {
    const sharedId = 'csp-yinhai-fixture::panfile:shared';
    const a = Episode(id: sharedId, title: 'Episode A', index: 0, flag: 'A');
    const b = Episode(id: sharedId, title: 'Episode B', index: 1, flag: 'B');
    _resolve = (_) async => _stream;
    final session = await _mount(
      t,
      episodeId: sharedId,
      episodeIndex: 1,
      episodes: const [a, b],
    );
    await _advance(t);
    expect(_requests.last['flag'], 'B');
    session.updateEpisodes(const [
      a,
      Episode(id: 'other', title: 'Other file', index: 1, flag: 'A'),
      b,
    ]);
    await _advance(t);
    expect(debugPlayerEpisodeIndexForProbe(), 2);
    expect(await debugPlayerLoadForProbe(), isTrue);
    await _advance(t);
    expect(_requests.last['episode_id'], sharedId);
    expect(_requests.last['flag'], 'B');
    expect(_requests.last['episode_title'], 'Episode B');
    expect(debugPlayerErrorForProbe(), isNull);
    await _dispose(t);
    expect(t.takeException(), isNull);
  });
}
