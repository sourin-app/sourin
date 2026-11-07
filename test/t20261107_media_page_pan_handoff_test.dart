@Tags(['native-media'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

// Real page events and request serialization, not Rust/network/media decoding.
// The opt-in receiver mutation must fail the same episode03 identity assertion.
final _dropEpisodeId =
    Platform.environment['SOURIN_TEST_PAN_HANDOFF_DROP_EPISODE_ID'] == '1';
const _provider = 'tvbox_agg';
const _child = 'csp-quark-media-handoff-fixture';
const _item = '$_child::synthetic-work';
const _share = 'synthetic-media-handoff-share';
const _source = 'synthetic-quark-line';
const _flag = 'Quark';
const _title = 'Synthetic cloud series';

Episode _file(int index, String fid, String title) {
  final encoded = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'kind': 'quark',
            'share_id': _share,
            'passcode': '',
            'fid': fid,
          }),
        ),
      )
      .replaceAll('=', '');
  return Episode(
    id: '$_child::panfile:$encoded',
    title: title,
    index: index,
    flag: _flag,
  );
}

final _files = [
  _file(0, 'file-03-copy', 'Synthetic Anime - 03 (1).mp4'),
  _file(1, 'file-04-copy', 'Synthetic Anime - 04 (1).mp4'),
  _file(2, 'file-05', 'Synthetic Anime - 05.mp4'),
  _file(3, 'file-07', 'Synthetic Anime - 07.mp4'),
  _file(4, 'file-01', 'Synthetic Anime - 01.mp4'),
  _file(5, 'file-02', 'Synthetic Anime - 02.mp4'),
  _file(6, 'file-03-original', 'Synthetic Anime - 03.mp4'),
];

Map<String, dynamic> _episodeJson(Episode episode) => {
  'id': episode.id,
  'title': episode.title,
  'index': episode.index,
  'flag': episode.flag,
};

Map<String, dynamic> _decodeFile(String id) {
  const prefix = '$_child::panfile:';
  expect(id, startsWith(prefix));
  return Map<String, dynamic>.from(
    jsonDecode(
      utf8.decode(
        base64Url.decode(base64Url.normalize(id.substring(prefix.length))),
      ),
    ) as Map,
  );
}

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(seconds: 3));
  }
}

void main() {
  late Directory scratch;
  final requests = <Map<String, dynamic>>[];
  final forwarded = <PlayRequestData>[];

  setUpAll(() {
    final native = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(native.existsSync(), isTrue, reason: 'Native fixture is required.');
    MediaKit.ensureInitialized(libmpv: native.absolute.path);
  });

  setUp(() {
    requests.clear();
    forwarded.clear();
    scratch = Directory.systemTemp.createTempSync('sourin-media-pan-handoff-');
    CachePage.debugScanRootOverride = scratch.path;
    UiPrefs.debugResetForTest({
      'dsh.danmaku.enabled': '0',
      'dsh.playprefs.lastVolume': '0',
    });
    NetworkStatus.debugResetForTest();
    NetworkStatus.debugProbe = () async => true;
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    debugSetOnDetailPlayForward(forwarded.add);
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      switch (command) {
        case 'get_detail':
          return {
            'id': '$_provider:$_item',
            'title': _title,
            'episodes': _files.map(_episodeJson).toList(),
            'sources': [
              {'code': _source, 'title': _flag, 'count': _files.length},
            ],
          };
        case 'get_episodes':
          return _files.map(_episodeJson).toList();
        case 'get_progress':
          return null;
        case 'list_favorites':
        case 'list_providers':
        case 'list_all_progress':
          return <dynamic>[];
        case 'save_progress':
        case 'pan_cleanup_temp':
          return <String, dynamic>{};
        case 'resolve_stream':
          final received = Map<String, dynamic>.from(args!);
          final req = Map<String, dynamic>.from(received['req'] as Map);
          // Only the synthetic receiver is changed; production objects are not.
          if (_dropEpisodeId && req['episode_title'] == _files.first.title) {
            req.remove('episode_id');
          }
          received['req'] = req;
          requests.add(received);
          return [
            {'url': 'https://fixture.invalid/never-opened.mp4', 'kind': 'mp4'},
          ];
        default:
          throw SourinCoreException('Synthetic fixture has no data', 'other');
      }
    };
  });

  tearDown(() {
    RemoteBridge.instance.stop();
    debugSetOnDetailPlayForward(null);
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    NetworkStatus.debugResetForTest();
    UiPrefs.debugResetForTest();
    CachePage.debugScanRootOverride = null;
    expect(
      FileSystemEntity.typeSync(scratch.path, followLinks: false),
      FileSystemEntityType.directory,
    );
    final resolved = Directory(scratch.resolveSymbolicLinksSync());
    expect(
      resolved.parent.path,
      Directory.systemTemp.resolveSymbolicLinksSync(),
    );
    expect(
      resolved.path.split(Platform.pathSeparator).last,
      startsWith('sourin-media-pan-handoff-'),
    );
    scratch.deleteSync(recursive: true);
  });

  testWidgets(
    'real MediaPage right-side episode03 then04 preserve concrete file identity',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaPage(
              provider: _provider,
              id: _item,
              title: _title,
              episodeId: _files[4].id,
              episodeTitle: _files[4].title,
              episodeIndex: 4,
              episodes: _files,
              sourceCode: _source,
            ),
          ),
        );
        await _advance(tester);
        expect(find.byType(MediaPage), findsOneWidget);
        expect(find.byType(DetailPage), findsOneWidget);
        expect(find.byType(PlayerPage), findsOneWidget);
        expect(_files, hasLength(7));
        expect(_files.map((episode) => episode.id).toSet(), hasLength(7));
        final session = tester.state(find.byType(PlayerPage)) as MediaSession;
        expect(session.currentEpisodeId, _files[4].id);
        expect(requests, hasLength(1));
        expect((requests.single['req'] as Map)['episode_id'], _files[4].id);
        expect(forwarded, isEmpty);

        for (final index in [0, 1]) {
          final target = _files[index];
          final before = requests.length;
          final tile = find.descendant(
            of: find.byType(DetailPage),
            matching: find.text(target.title),
          );
          expect(tile, findsOneWidget);
          await tester.ensureVisible(tile);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(tile);
          await _advance(tester);

          expect(forwarded, hasLength(index + 1));
          final detailRequest = forwarded.last;
          expect(detailRequest.episodeId, target.id);
          expect(detailRequest.episodeTitle, target.title);
          expect(detailRequest.episodeIndex, index);
          expect(detailRequest.episodes.map((episode) => episode.id), [
            for (final episode in _files) episode.id,
          ]);
          expect(detailRequest.sourceCode, _source);
          expect(requests, hasLength(before + 1));
          final received = requests.last;
          expect(received['provider'], _provider);
          expect(received['id'], _item);
          final req = received['req'] as Map<String, dynamic>;
          expect(
            req['episode_id'],
            target.id,
            reason: 'Specific pan file selection must reach resolve_stream without identity loss.',
          );
          expect(req['flag'], _flag);
          expect(req['episode_title'], target.title);
          // The share's list order deliberately differs from its episode number.
          expect(req['episode_order'], index + 1);
          expect(req['source_code'], _source);
          expect(_decodeFile(req['episode_id'] as String), {
            'kind': 'quark',
            'share_id': _share,
            'passcode': '',
            'fid': index == 0 ? 'file-03-copy' : 'file-04-copy',
          });
          expect(
            identical(tester.state(find.byType(PlayerPage)), session),
            isTrue,
          );
          expect(session.currentEpisodeId, target.id);
          expect(debugPlayerErrorForProbe(), isNull);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await _unmount(tester);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
