@Tags(['native-media'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

class _Transport implements DanmakuTransport {
  _Transport({this.status = 200});
  final int status;
  final calls = <String>[];
  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    calls.add(uri.path);
    if (uri.path.endsWith('/version')) {
      return const DanmakuHttpResponse(
        statusCode: 200,
        body: '{"version":"fixture"}',
      );
    }
    if (status != 200) {
      return DanmakuHttpResponse(
        statusCode: status,
        body: '{}',
        headers: const {'x-error-message': 'Missing Authentication Headers'},
      );
    }
    return DanmakuHttpResponse(
      statusCode: 200,
      body: jsonEncode({'isMatched': false, 'matches': [], 'animes': []}),
    );
  }

  @override
  void close() {}
}

Future<void> _mount(WidgetTester tester) async {
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
        id: 'no-match',
        title: 'Fixture',
        episodes: [Episode(id: 'e1', title: 'Episode One')],
        episodeId: 'e1',
        episodeTitle: 'Episode One',
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() {
    UiPrefs.debugResetForTest(<String, String>{});
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async =>
        [];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      if (command == 'pan_cleanup_temp' || command == 'save_progress') {
        return {};
      }
      throw SourinCoreException('No fixture data', 'other');
    };
  });
  tearDown(() {
    debugSetDanmakuTransportForTest(null);
    debugPlayerDanmakuLocalProbeTransportForTest = null;
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinApi.debugResolveStreamFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    UiPrefs.debugResetForTest(<String, String>{});
  });

  testWidgets(
    'empty automatic match stays in quick panel without a playback failure toast',
    (tester) async {
      final transport = _Transport();
      debugSetDanmakuTransportForTest(transport);
      debugPlayerDanmakuLocalProbeTransportForTest = transport;
      await _mount(tester);
      final result = await debugPlayerLoadDanmakuForProbe('PrivateFixtureName');
      await tester.pump();
      expect(transport.calls.any((p) => p.endsWith('/match')), isTrue);
      expect(
        transport.calls.any((p) => p.contains('/search/episodes')),
        isTrue,
      );
      expect(result, 0);
      final settings = debugPlayerDanmakuSettingsState()!;
      expect(settings.error, isNull);
      expect(settings.loading, isFalse);
      expect(settings.sourceLine, contains('fixture'));
      expect(settings.status, '未找到匹配弹幕，可手动搜索');
      expect(debugPlayerFlashForProbeText() ?? '', isNot(contains('弹幕失败')));
      expect(
        debugPlayerFlashForProbeText() ?? '',
        isNot(contains('PrivateFixtureName')),
      );
      expect(debugPlayerForceBarsForShot(), isTrue);
      await tester.pump();
      final gear = find.descendant(
        of: find.byKey(PlayerBottomBar.danmakuSettingsKey),
        matching: find.byType(ui.TextButton),
      );
      tester.widget<ui.TextButton>(gear).onPressed!();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsOneWidget);
      expect(find.text('未找到匹配弹幕，可手动搜索'), findsOneWidget);
      expect(find.byKey(PlayerBottomBar.danmakuQuickSearchKey), findsOneWidget);
    },
  );

  testWidgets('authentication failure keeps actionable error feedback', (
    tester,
  ) async {
    final transport = _Transport(status: 403);
    debugSetDanmakuTransportForTest(transport);
    debugPlayerDanmakuLocalProbeTransportForTest = transport;
    await _mount(tester);
    expect(await debugPlayerLoadDanmakuForProbe('Fixture'), -1);
    await tester.pump();
    expect(debugPlayerDanmakuSettingsState()!.error?.statusCode, 403);
    expect(debugPlayerFlashForProbeText(), contains('弹幕失败'));
    expect(
      debugPlayerFlashForProbeText(),
      contains('Missing Authentication Headers'),
    );
    await tester.pump(const Duration(seconds: 2));
  });
}
