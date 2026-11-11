@Tags(['native-media'])
library;

// Mounts the production PlayerPage, exercises its real pinned-fetch fallback,
// and observes transport requests and the host's actual panel state. Native
// video initialization is acknowledged; opening media is disabled. These cases
// prove request cancellation, not live source playback or decoded pixels.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:sourin_spike/core/batch_bind.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const _videoChannelName = 'com.alexmercerind/media_kit_video';
const _videoChannel = MethodChannel(_videoChannelName);
final _createdHandles = <String>[];
final _disposedHandles = <String>[];
final _pushedHandles = <String>{};

Future<void> _pushCreatedTextures() async {
  for (final handle in _createdHandles.toList()) {
    if (!_pushedHandles.add(handle)) continue;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _videoChannelName,
          _videoChannel.codec.encodeMethodCall(
            MethodCall('VideoOutput.Resize', <String, dynamic>{
              'handle': int.parse(handle),
              'rect': <String, dynamic>{
                'left': 0.0,
                'top': 0.0,
                'width': 0.0,
                'height': 0.0,
              },
              'id': 7,
            }),
          ),
          null,
        );
  }
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump();
    if (ready()) return;
    await tester.runAsync(() async {
      await _pushCreatedTextures();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  expect(ready(), isTrue, reason: 'The real production stage must finish');
}

class _PinnedFailureTransport implements DanmakuTransport {
  final calls = <String>[];
  final entered = Completer<void>();
  final pending = Completer<DanmakuHttpResponse>();

  void fail() {
    if (!pending.isCompleted) {
      pending.complete(const DanmakuHttpResponse(statusCode: 500, body: '{}'));
    }
  }

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
    if (uri.path == '/api/v2/comment/41') {
      if (!entered.isCompleted) entered.complete();
      return pending.future;
    }
    if (uri.path.startsWith('/api/v2/comment/')) {
      return const DanmakuHttpResponse(
        statusCode: 200,
        body: '{"comments":[]}',
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

void _bind(int id) => saveDanmakuBind(
  'fixture',
  'work',
  DanmakuBindStore(workTitle: 'Fixture', episodes: {0: id}, updatedAt: 1),
);

Future<void> _mount(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: const PlayerPage(
        provider: 'fixture',
        id: 'work',
        title: 'Fixture',
        episodes: [Episode(id: 'ep1', title: 'Episode One')],
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: 'Episode One',
      ),
    ),
  );
  addTearDown(() async {
    if (find.byType(PlayerPage).evaluate().isNotEmpty) await _finish(tester);
  });
  final native =
      tester.widget<Video>(find.byType(Video)).controller.player.platform
          as NativePlayer;
  await _waitFor(tester, () => native.videoControllerCompleter.isCompleted);
  await tester.pump();
}

Future<void> _finish(WidgetTester tester) async {
  final native =
      tester.widget<Video>(find.byType(Video)).controller.player.platform
          as NativePlayer;
  final handle = _createdHandles.single;
  await tester.pumpWidget(const SizedBox.shrink());
  await _waitFor(
    tester,
    () => native.disposed && _disposedHandles.contains(handle),
  );
  var unlocked = false;
  final disposalBarrier = NativePlayer.lock.synchronized(() async {
    unlocked = true;
  });
  await _waitFor(tester, () => unlocked);
  await disposalBarrier;
  await tester.pump(const Duration(seconds: 6));
  await tester.pump(const Duration(seconds: 1));
  expect(tester.takeException(), isNull);
}

Future<int> _completeLoad(WidgetTester tester, Future<int> load) async {
  int? result;
  load.then((value) => result = value);
  await _waitFor(tester, () => result != null);
  return load;
}

Future<({Future<int> load})> _startPinned(
  WidgetTester tester,
  _PinnedFailureTransport transport,
) async {
  _bind(41);
  final load = debugPlayerLoadDanmakuForProbe('OldRequest');
  addTearDown(() async {
    transport.fail();
    await _completeLoad(tester, load);
  });
  await _waitFor(tester, () => transport.entered.isCompleted);
  expect(transport.calls.where((path) => path.contains('/comment/')), [
    '/api/v2/comment/41',
  ]);
  return (load: load);
}

void main() {
  late Directory scratch;
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(dll.existsSync(), isTrue);
    MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('pinned-fallback-test-');
    ClipDownloader.debugSetDataDir(scratch.path);
    _createdHandles.clear();
    _disposedHandles.clear();
    _pushedHandles.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_videoChannel, (call) async {
          if (call.method == 'VideoOutputManager.Create') {
            _createdHandles.add(call.arguments['handle'] as String);
          } else if (call.method == 'VideoOutputManager.Dispose') {
            _disposedHandles.add(call.arguments['handle'] as String);
          }
          return null;
        });
    UiPrefs.debugResetForTest();
    Device.overrideKind(DeviceKind.desktop);
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      if (command == 'resolve_stream' || command == 'list_providers') {
        return <dynamic>[];
      }
      if (command == 'pan_cleanup_temp' ||
          command == 'end_yield_for_seek' ||
          command == 'save_progress') {
        return <String, dynamic>{};
      }
      throw SourinCoreException('No isolated fixture data', 'other');
    };
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_videoChannel, null);
    debugSetDanmakuTransportForTest(null);
    debugPlayerDanmakuLocalProbeTransportForTest = null;
    debugPlayerSkipOpenForProbe = false;
    Device.overrideKind(null);
    RemoteBridge.instance.stop();
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    UiPrefs.debugResetForTest();
    ClipDownloader.debugSetDataDir(null);
    await scratch.delete(recursive: true);
  });

  for (final cancellation in ['new request', 'disabled', 'unmounted']) {
    testWidgets('$cancellation: late pinned failure sends no old fallback', (
      tester,
    ) async {
      final transport = _PinnedFailureTransport();
      debugSetDanmakuTransportForTest(transport);
      debugPlayerDanmakuLocalProbeTransportForTest = transport;
      await _mount(tester);
      final old = (await _startPinned(tester, transport)).load;
      if (cancellation == 'new request') {
        _bind(42);
        expect(
          await _completeLoad(
            tester,
            debugPlayerLoadDanmakuForProbe('CurrentRequest'),
          ),
          0,
        );
        expect(debugPlayerDanmakuStatus(), contains('CurrentRequest'));
      } else if (cancellation == 'disabled') {
        expect(await debugPlayerToggleDanmakuForProbe(), isFalse);
      } else {
        await _finish(tester);
      }
      final before = List<String>.of(transport.calls);
      transport.fail();
      await _completeLoad(tester, old);
      expect(
        transport.calls,
        before,
        reason: 'Canceled work must stop before starting match/search I/O',
      );
      if (cancellation == 'new request') {
        expect(debugPlayerDanmakuStatus(), contains('CurrentRequest'));
        expect(debugPlayerDanmakuSettingsState()!.error, isNull);
      } else if (cancellation == 'disabled') {
        expect(debugPlayerDanmakuSettingsState()!.enabled, isFalse);
      }
      if (find.byType(PlayerPage).evaluate().isNotEmpty) await _finish(tester);
    });
  }

  testWidgets(
    'a current pinned failure retains the normal match/search fallback',
    (tester) async {
      final transport = _PinnedFailureTransport();
      debugSetDanmakuTransportForTest(transport);
      debugPlayerDanmakuLocalProbeTransportForTest = transport;
      await _mount(tester);
      final current = (await _startPinned(tester, transport)).load;
      transport.fail();
      expect(await _completeLoad(tester, current), 0);
      expect(
        transport.calls.where((path) => path.endsWith('/match')),
        hasLength(1),
      );
      expect(
        transport.calls.any((path) => path.contains('/search/episodes')),
        isTrue,
      );
      expect(debugPlayerDanmakuSettingsState()!.status, '未找到匹配弹幕，可手动搜索');
      expect(debugPlayerDanmakuSettingsState()!.error, isNull);
      await _finish(tester);
    },
  );
}
