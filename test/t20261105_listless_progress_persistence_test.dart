@Tags(['native-media'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const _oldProvider = 'old-listless-fixture';
const _oldContentId = 'old-share';
const _oldEpisodeId = 'old-fixture::panfile:old-file';
const _oldEpisodeTitle = 'Old file.mp4';
const _newProvider = 'new-listless-fixture';
const _newContentId = 'new-share';
const _newEpisodeId = 'new-fixture::panfile:selected-file';
const _newEpisodeTitle = 'Selected file.mp4';
const _otherFiles = [
  Episode(
    id: 'new-fixture::panfile:other-file',
    title: 'Other file.mp4',
    index: 0,
    flag: 'Quark',
  ),
];
const _stream = [
  {'url': 'https://fixture.invalid/current.m3u8', 'kind': 'hls'},
];

final _writes = <Map<String, dynamic>>[];
final _stored = <String, Map<String, dynamic>>{};
final _requests = <Map<String, dynamic>>[];

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

Future<MediaSession> _mount(
  WidgetTester t, {
  String? episodeId = _oldEpisodeId,
  String? episodeTitle = _oldEpisodeTitle,
}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  addTearDown(() async {
    if (find.byType(PlayerPage).evaluate().isNotEmpty) await _dispose(t);
  });
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: _oldProvider,
        id: _oldContentId,
        title: 'Old share',
        episodeId: episodeId,
        episodeTitle: episodeTitle,
      ),
    ),
  );
  await _advance(t);
  return (t.state(find.byType(PlayerPage)) as dynamic) as MediaSession;
}

Future<void> _replace(WidgetTester t, MediaSession session) async {
  await session.applySession(
    const PlayRequestData(
      provider: _newProvider,
      id: _newContentId,
      title: 'New share',
      episodeId: _newEpisodeId,
      episodeTitle: _newEpisodeTitle,
    ),
  );
  await _advance(t);
  expect(session.currentEpisodeId, _newEpisodeId);
}

Future<Map<String, dynamic>> _saveCurrent() async {
  _writes.clear();
  expect(
    await debugPlayerSaveProgressForProbe(
      duration: const Duration(seconds: 1800),
      position: const Duration(seconds: 123),
    ),
    isTrue,
  );
  expect(_writes, hasLength(1));
  return _writes.single;
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() {
    _writes.clear();
    _stored.clear();
    _requests.clear();
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinCore.debugCallAsyncTransport = (cmd, args) async {
      if (cmd == 'resolve_stream') {
        _requests.add(Map<String, dynamic>.from(args!));
        return _stream;
      }
      if (cmd == 'pan_cleanup_temp') return <String, dynamic>{};
      if (cmd == 'save_progress') {
        final saved = Map<String, dynamic>.from(args!);
        _writes.add(saved);
        final provider = saved['provider'] as String;
        final id = saved['id'] as String;
        _stored['$provider:$id'] = Progress(
          key: 'opaque-fixture-progress',
          provider: provider,
          nativeId: id,
          title: saved['title'] as String,
          cover: saved['cover'] as String?,
          episodeId: saved['episode_id'] as String?,
          episodeTitle: saved['episode_title'] as String?,
          position: (saved['position'] as num).toInt(),
          duration: (saved['duration'] as num).toInt(),
          updatedAt: 1,
        ).toJson();
        return null;
      }
      if (cmd == 'get_progress') {
        return _stored['${args!['provider']}:${args['id']}'];
      }
      throw SourinCoreException('isolated fixture has no data', 'other');
    };
  });
  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    _writes.clear();
    _stored.clear();
    _requests.clear();
  });

  testWidgets('listless replacement persists and resumes its own file', (
    t,
  ) async {
    final session = await _mount(t);
    await _replace(t, session);
    final saved = await _saveCurrent();
    expect(saved['provider'], _newProvider);
    expect(saved['id'], _newContentId);
    expect(saved['episode_id'], _newEpisodeId);
    expect(saved['episode_title'], _newEpisodeTitle);
    final progress = await SourinApi.getProgress(_newProvider, _newContentId);
    expect(progress?.episodeId, _newEpisodeId);
    expect(progress?.episodeTitle, _newEpisodeTitle);
    expect(progress?.position, 123);
    expect(debugPlayerResetResumeGuardForProbe(), isTrue);
    expect(await debugPlayerPrepareResumeForProbe(), isTrue);
    expect(debugPlayerPendingSeekForProbe(), const Duration(seconds: 123));
    await _dispose(t);
    expect(t.takeException(), isNull);
  });

  testWidgets('a disappeared explicit file keeps its persisted identity', (
    t,
  ) async {
    final session = await _mount(t);
    await _replace(t, session);
    session.updateEpisodes(_otherFiles);
    await _advance(t);
    expect(session.currentEpisodeId, _newEpisodeId);
    final saved = await _saveCurrent();
    expect(saved['provider'], _newProvider);
    expect(saved['id'], _newContentId);
    expect(saved['episode_id'], _newEpisodeId);
    expect(saved['episode_title'], _newEpisodeTitle);
    expect(saved['episode_id'], isNot(_otherFiles.first.id));
    await _dispose(t);
    expect(t.takeException(), isNull);
  });

  testWidgets('listless replacement renders its file title in the top bar', (
    t,
  ) async {
    final session = await _mount(t);
    final topBar = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_TopBar',
    );
    expect(topBar, findsOneWidget);
    expect(
      find.descendant(of: topBar, matching: find.text(_oldEpisodeTitle)),
      findsOneWidget,
    );
    await _replace(t, session);
    expect(
      find.descendant(of: topBar, matching: find.text(_newEpisodeTitle)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: topBar, matching: find.text(_oldEpisodeTitle)),
      findsNothing,
    );
    await _dispose(t);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'switching to an empty source retires the previous file identity',
    (t) async {
      final session = await _mount(t, episodeId: null, episodeTitle: null);
      await _replace(t, session);
      const provider = 'empty-source-fixture';
      const id = 'empty-source-item';
      expect(
        await debugPlayerApplySwitchForProbe(
          provider: provider,
          id: id,
          detail: const MediaDetail(id: id, title: 'Empty source'),
        ),
        isTrue,
      );
      await _advance(t);
      expect(_requests.last['provider'], provider);
      expect(_requests.last['id'], id);
      final request = Map<String, dynamic>.from(_requests.last['req'] as Map);
      expect(request['episode_id'], isNull);
      expect(request['episode_title'], isNull);
      expect(session.currentEpisodeId, isNull);
      final saved = await _saveCurrent();
      expect(saved['provider'], provider);
      expect(saved['id'], id);
      expect(saved['episode_id'], isNull);
      expect(saved['episode_title'], isNull);
      await _dispose(t);
      expect(t.takeException(), isNull);
    },
  );
}
