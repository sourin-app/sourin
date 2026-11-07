@Tags(['native-media'])
library;

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
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const episodes = [
  Episode(id: 'a1', title: '第1集', flag: 'Line A', index: 0),
  Episode(id: 'a2', title: '第2集', flag: 'Line A', index: 1),
  Episode(id: 'b1', title: '第01集', flag: 'Line B', index: 2),
  Episode(id: 'b2', title: '第02集', flag: 'Line B', index: 3),
];

void main() {
  setUpAll(
    () => MediaKit.ensureInitialized(
      libmpv: File(
        Platform.environment['SOURIN_TEST_MPV'] ??
            'build/windows/x64/libmpv/libmpv-2.dll',
      ).absolute.path,
    ),
  );
  testWidgets(
    'windowed line tap resolves matching episode through live player session',
    (t) async {
      final scratch = Directory.systemTemp.createTempSync(
        'sourin-line-session-',
      );
      CachePage.debugScanRootOverride = scratch.path;
      UiPrefs.debugResetForTest({
        'dsh.danmaku.enabled': '0',
        'dsh.playprefs.lastVolume': '0',
      });
      NetworkStatus.debugResetForTest();
      NetworkStatus.debugProbe = () async => true;
      RemoteBridge.instance.stop();
      debugPlayerSkipOpenForProbe = true;
      SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
      final requests = <Map<String, dynamic>>[];
      final eps = episodes
          .map(
            (e) => {
              'id': e.id,
              'title': e.title,
              'flag': e.flag,
              'index': e.index,
            },
          )
          .toList();
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'get_detail':
            return {
              'id': 'fixture:work',
              'title': 'Line fixture',
              'episodes': eps,
            };
          case 'get_episodes':
            return eps;
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
            requests.add(Map<String, dynamic>.from(args!['req'] as Map));
            return [
              {'url': 'https://fixture.invalid/not-opened.mp4', 'kind': 'mp4'},
            ];
          default:
            throw SourinCoreException('Fixture has no data', 'other');
        }
      };
      t.view.physicalSize = const Size(1440, 900);
      t.view.devicePixelRatio = 1;
      try {
        await t.pumpWidget(
          const MaterialApp(
            home: MediaPage(
              provider: 'fixture',
              id: 'work',
              title: 'Line fixture',
              episodeId: 'a2',
              episodeTitle: '第2集',
              episodeIndex: 1,
              episodes: episodes,
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
        expect(requests.last['episode_id'], 'a2');
        requests.clear();
        final line = find.descendant(
          of: find.byType(DetailPage),
          matching: find.text('Line B'),
        );
        expect(line, findsOneWidget);
        await t.ensureVisible(line);
        await t.tap(line);
        for (var i = 0; i < 20; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
        expect(requests, hasLength(1));
        expect(requests.single['episode_id'], 'b2');
        expect(requests.single['episode_title'], '第02集');
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        for (var i = 0; i < 60; i++) {
          await t.pump(const Duration(seconds: 3));
        }
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
        RemoteBridge.instance.stop();
        debugPlayerSkipOpenForProbe = false;
        SourinCore.debugCallAsyncTransport = null;
        SourinApi.debugSkipMarkerFetcher = null;
        UiPrefs.debugResetForTest();
        NetworkStatus.debugResetForTest();
        CachePage.debugScanRootOverride = null;
        expect(
          scratch.parent.resolveSymbolicLinksSync(),
          Directory.systemTemp.resolveSymbolicLinksSync(),
        );
        scratch.deleteSync(recursive: true);
      }
    },
  );
}
