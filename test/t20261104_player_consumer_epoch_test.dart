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

const _episodes = [
  Episode(id: 'A1', title: '第1集', index: 0, flag: '线路A'),
  Episode(id: 'A2', title: '第2集', index: 1, flag: '线路A'),
];

typedef _Call = ({String cmd, Map<String, dynamic> args});

final _calls = <_Call>[];
Future<dynamic> Function(Map<String, dynamic>)? _resolve;

Map<String, dynamic> _extra(_Call call) =>
    (call.args['req'] as Map)['extra'] as Map<String, dynamic>;

List<_Call> get _requests =>
    _calls.where((c) => c.cmd == 'resolve_stream').toList();
List<_Call> get _cleanups =>
    _calls.where((c) => c.cmd == 'pan_cleanup_temp').toList();

const _currentStream = [
  {'url': 'https://fixture.invalid/current.m3u8', 'kind': 'hls'},
];
const _staleStream = [
  {'url': 'https://fixture.invalid/stale.m3u8', 'kind': 'hls'},
];

Future<void> _mount(
  WidgetTester t, {
  String key = 'first',
  String? localPath,
}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() async {
    if (find.byType(PlayerPage).evaluate().isNotEmpty) await _dispose(t);
  });
  await t.pumpWidget(MaterialApp(
    home: PlayerPage(
      key: ValueKey(key),
      provider: 'consumer-fixture',
      id: 'series',
      title: '剧集',
      episodes: _episodes,
      episodeIndex: 0,
      episodeId: 'A1',
      episodeTitle: '第1集',
      localPath: localPath,
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

Future<bool> _source() => debugPlayerResolveAndPlayForProbe(
      provider: 'target-fixture',
      id: 'target-series',
      episodeId: 'A1',
    );

Future<bool> _dispatch(String entry) => switch (entry) {
      'load' => debugPlayerLoadForProbe(),
      'reload' => debugPlayerReloadForProbe(),
      _ => _source(),
    };

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() {
    _calls.clear();
    _resolve = null;
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    // This intercepts the real callAsync command, after req.toJson in SourinApi.
    SourinCore.debugCallAsyncTransport = (cmd, args) async {
      final call = (cmd: cmd, args: args ?? <String, dynamic>{});
      _calls.add(call);
      if (cmd == 'resolve_stream') {
        final resolve = _resolve;
        return resolve == null ? [] : await resolve(call.args);
      }
      if (cmd == 'pan_cleanup_temp') return <String, dynamic>{};
      throw SourinCoreException('隔离接口没有数据', 'other');
    };
  });
  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    _resolve = null;
  });

  testWidgets('all production request exits use one consumer and increasing epochs',
      (t) async {
    addTearDown(() => t.binding.setSurfaceSize(null));
    await _mount(t);
    expect(_requests, hasLength(1));
    await debugPlayerGotoEpisodeForProbe(_episodes[1]);
    await t.pump();
    await debugPlayerLoadForProbe();
    await t.pump();
    await _source();
    await t.pump();
    expect(_requests, hasLength(4));
    final consumers = _requests.map((c) => _extra(c)['play_consumer']).toList();
    expect(consumers.first, isA<String>());
    expect((consumers.first as String).isNotEmpty, isTrue);
    expect(consumers.toSet(), hasLength(1));
    final epochs =
        _requests.map((c) => _extra(c)['play_generation'] as int).toList();
    expect(epochs.first, greaterThan(0));
    for (var i = 1; i < epochs.length; i++) {
      expect(epochs[i], greaterThan(epochs[i - 1]));
    }
    await _dispose(t);
    expect(_cleanups, hasLength(1));
    expect(_cleanups.single.args, {
      'play_consumer': consumers.first,
      'play_generation': epochs.last,
      'invalidate': true,
    });
    expect(t.takeException(), isNull);
  });

  for (final entry in ['load', 'reload', 'source']) {
    for (final staleFailure in [false, true]) {
      testWidgets('$entry rejects superseded ${staleFailure ? 'errors' : 'results'}',
          (t) async {
        addTearDown(() => t.binding.setSurfaceSize(null));
        await _mount(t);
        final stale = Completer<dynamic>();
        final current = Completer<dynamic>();
        var started = 0;
        _resolve = (_) => ++started == 1 ? stale.future : current.future;
        final before = debugPlayerStartPlaybackCallsForProbe()!;
        final old = _dispatch(entry);
        await t.pump();
        final latest = _dispatch(entry);
        await t.pump();
        expect(started, 2);
        current.complete(_currentStream);
        await latest;
        await t.pump();
        expect(debugPlayerErrorForProbe(), isNull,
            reason: 'The latest real API response must reach playback.');
        expect(debugPlayerStreamUrlsForProbe(),
            ['https://fixture.invalid/current.m3u8']);
        expect(debugPlayerStartPlaybackCallsForProbe(), before + 1);
        if (staleFailure) {
          stale.completeError(SourinCoreException('过期解析失败', 'network'));
        } else {
          stale.complete(_staleStream);
        }
        await old;
        await t.pump();
        expect(debugPlayerStreamUrlsForProbe(),
            ['https://fixture.invalid/current.m3u8']);
        expect(debugPlayerStartPlaybackCallsForProbe(), before + 1);
        expect(debugPlayerErrorForProbe(), isNull);
        await _dispose(t);
        expect(_cleanups.single.args['play_generation'],
            _extra(_requests.last)['play_generation']);
        expect(t.takeException(), isNull);
      });
    }
  }

  for (final staleFailure in [false, true]) {
    testWidgets('source cannot replace a local session: ${staleFailure ? 'error' : 'result'}',
        (t) async {
      addTearDown(() => t.binding.setSurfaceSize(null));
      await _mount(t);
      final stale = Completer<dynamic>();
      _resolve = (_) => stale.future;
      final old = _source();
      await t.pump();
      final path = File('.probe/local-epoch-fixture.mp4').absolute.path;
      expect(
        await debugPlayerApplySessionForProbe(PlayRequestData(
          provider: 'local',
          id: path,
          title: '本地剧集',
          localPath: path,
        )),
        isTrue,
      );
      await t.pump();
      final before = debugPlayerStartPlaybackCallsForProbe();
      final urls = debugPlayerStreamUrlsForProbe();
      expect(debugPlayerSessionKeyForProbe(), 'local:$path');
      if (staleFailure) {
        stale.completeError(SourinCoreException('旧源失败', 'network'));
      } else {
        stale.complete(_staleStream);
      }
      await old;
      await t.pump();
      expect(debugPlayerSessionKeyForProbe(), 'local:$path');
      expect(debugPlayerStreamUrlsForProbe(), urls);
      expect(debugPlayerStartPlaybackCallsForProbe(), before);
      expect(debugPlayerErrorForProbe(), isNull);
      await _dispose(t);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('a page without any resolve still closes a positive scoped epoch',
      (t) async {
    addTearDown(() => t.binding.setSurfaceSize(null));
    final path = File('.probe/local-epoch-fixture.mp4').absolute.path;
    await _mount(t, localPath: path);
    expect(_requests, isEmpty);
    await _dispose(t);
    expect(_cleanups, hasLength(1));
    final cleanup = _cleanups.single.args;
    expect(cleanup['play_consumer'], isA<String>());
    expect((cleanup['play_consumer'] as String).isNotEmpty, isTrue);
    expect(cleanup['play_generation'] as int, greaterThan(0));
    expect(cleanup['invalidate'], isTrue);
    expect(t.takeException(), isNull);
  });

  for (final staleFailure in [false, true]) {
    testWidgets('closed page cannot affect a new page: ${staleFailure ? 'error' : 'result'}',
        (t) async {
      addTearDown(() => t.binding.setSurfaceSize(null));
      final first = Completer<dynamic>();
      _resolve = (_) => first.future;
      await _mount(t);
      final oldExtra = Map<String, dynamic>.from(_extra(_requests.single));
      await _dispose(t);
      expect(_cleanups.single.args, {
        ...oldExtra,
        'invalidate': true,
      });
      _resolve = (_) async => _currentStream;
      await _mount(t, key: 'second');
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final newExtra = _extra(_requests.last);
      expect(newExtra['play_consumer'], isNot(oldExtra['play_consumer']));
      expect(newExtra['play_generation'] as int,
          greaterThan(oldExtra['play_generation'] as int));
      expect(debugPlayerStreamUrlsForProbe(),
          ['https://fixture.invalid/current.m3u8']);
      final starts = debugPlayerStartPlaybackCallsForProbe();
      if (staleFailure) {
        first.completeError(SourinCoreException('已退出解析失败', 'network'));
      } else {
        first.complete(_staleStream);
      }
      await t.pump();
      expect(debugPlayerStreamUrlsForProbe(),
          ['https://fixture.invalid/current.m3u8']);
      expect(debugPlayerStartPlaybackCallsForProbe(), starts);
      expect(debugPlayerErrorForProbe(), isNull);
      await _dispose(t);
      expect(_cleanups, hasLength(2));
      expect(_cleanups.last.args, {...newExtra, 'invalidate': true});
      expect(t.takeException(), isNull);
    });
  }
}
