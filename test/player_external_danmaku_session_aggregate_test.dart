@Tags(['native-media'])
library;

// Reuses the pinned-failure regression's isolated native handshake.
// Uses real mounted PlayerPage session/aggregation/host-publication paths.
// The external API, plugin response, and new source resolver are fake/gated.
// Media open is disabled; this is not native decode or physical UI acceptance.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/bili/bili_auto_update.dart';
import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_overlay.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

const _oldComment = DanmakuComment(
  cid: 41,
  time: 1,
  text: 'Old-session external comment',
);
const _manualBinding = BiliBinding(
  bvid: 'BV1fixture0001',
  title: 'Fixture external binding',
  manual: true,
  episodes: [BiliEpisodeBinding(episodeIndex: 0, page: 1, cid: 41)],
);

class _NoNetworkClient implements HttpClient {
  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'No external HTTP is allowed: ${invocation.memberName}',
  );
}

class _ExternalApi extends BiliApi {
  _ExternalApi() : super(client: _NoNetworkClient());
  final fetched = <int>[];

  @override
  Future<List<DanmakuComment>> danmaku(int cid) async {
    fetched.add(cid);
    return const [_oldComment];
  }

  // Opening the real external panel can refresh its metadata. Keep that
  // established API seam local, too; never let it fall through to HTTP.
  @override
  Future<BiliVideoInfo> videoInfo(BiliRef ref) async => const BiliVideoInfo(
    bvid: 'BV1fixture0001', aid: 1, title: 'Fixture external binding',
  );
}

class _PluginGate {
  bool failOnRelease = false;
  final entered = Completer<void>();
  Completer<Map<String, dynamic>>? _pending;
  final calls = <Map<String, dynamic>>[];

  void release() {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    if (failOnRelease) {
      pending.completeError(
        SourinCoreException('Fixture plugin failure', 'other'),
      );
    } else {
      pending.complete({'items': <dynamic>[], 'source': 'fixture-plugin'});
    }
  }

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    if (command == 'provider_danmaku_list') {
      final captured = Map<String, dynamic>.from(args!);
      captured['req'] = Map<String, dynamic>.from(captured['req'] as Map);
      calls.add(captured);
      if (calls.length != 1) throw StateError('Unexpected second plugin fetch');
      // Construct the error-bearing Future in the real production request's
      // error zone, rather than setUp's outer zone. Await/catch can then see
      // the controlled plugin exception without losing Future completion.
      final pending = _pending = Completer<Map<String, dynamic>>();
      entered.complete();
      return pending.future;
    }
    if (command == 'list_providers' || command == 'resolve_stream') {
      return <dynamic>[];
    }
    if (command == 'pan_cleanup_temp' || command == 'save_progress' ||
        command == 'end_yield_for_seek') {
      return <String, dynamic>{};
    }
    throw SourinCoreException('No isolated fixture data', 'other');
  }
}

class _ResolverGate {
  final entered = Completer<void>();
  final pending = Completer<List<StreamCandidate>>();
  int nextCalls = 0;

  void release() {
    if (!pending.isCompleted) pending.complete(const <StreamCandidate>[]);
  }

  Future<List<StreamCandidate>> resolve(String provider, String id,
      {PlayRequest? req}) async {
    if (provider == 'next' && id == 'next-work') {
      nextCalls++;
      if (nextCalls != 1) throw StateError('Unexpected second new resolve');
      entered.complete();
      return pending.future;
    }
    return const <StreamCandidate>[];
  }
}

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

void main() {
  late Directory scratch;
  late _PluginGate plugin;
  late _ResolverGate resolver;

  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(dll.existsSync(), isTrue);
    MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('external-epoch-draft-');
    ClipDownloader.debugSetDataDir(scratch.path);
    UiPrefs.debugResetForTest();
    BiliDanmakuStore.debugResetForTest();
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
    plugin = _PluginGate();
    resolver = _ResolverGate();
    Device.overrideKind(DeviceKind.desktop);
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinApi.debugResolveStreamFetcher = resolver.resolve;
    SourinCore.debugCallAsyncTransport = plugin.call;
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_videoChannel, null);
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinApi.debugResolveStreamFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    Device.overrideKind(null);
    UiPrefs.debugResetForTest();
    BiliDanmakuStore.debugResetForTest();
    ClipDownloader.debugSetDataDir(null);
    await scratch.delete(recursive: true);
  });

  for (final entry in ['external load', 'manual update']) {
    for (final changeSession in [true, false]) {
      for (final pluginFailure in [false, true]) {
        testWidgets(
          '$entry: ${changeSession ? "new session rejects" : "current session accepts"} delayed ${pluginFailure ? "failed" : "successful"} aggregation',
          (tester) async {
            plugin.failOnRelease = pluginFailure;
            var oldStarted = false;
            var oldCompleted = false;
            var switchingStarted = false;
            var switchingCompleted = false;
            Future<void> old = Future<void>.value();
            Future<void> switching = Future<void>.value();
            try {
              await _mount(tester);
              final mountedPage = tester.widget<PlayerPage>(find.byType(PlayerPage));
              final session = tester.state(find.byType(PlayerPage)) as MediaSession;
              final api = _ExternalApi();
              debugPlayerSetBiliApiForProbe(api);
              saveBinding('fixture', 'work', _manualBinding);
              expect(debugPlayerDanmakuCount(), 0);

              // Open the real settings widget and read its host-owned samples.
              // No probes/search/network callbacks are invoked by this open.
              expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
              await tester.pump();
              final initialSettings = tester.widget<DanmakuSettingsDialog>(
                find.byType(DanmakuSettingsDialog),
              );
              expect(initialSettings.feedSamples, isNotNull);
              expect(initialSettings.feedSamples, isEmpty);

              if (entry == 'external load') {
                old = debugPlayerReloadDanmakuForProbe().then((_) {});
              } else {
                // The raw Bili-sheet probe only flips visibility. The real
                // settings callback runs _openBiliSheet and hydrates binding
                // and panelToken before the real update callback is read.
                expect(initialSettings.onOpenBili, isNotNull);
                initialSettings.onOpenBili!();
                await tester.pump();
                final dialog = tester.widget<BiliImportDialog>(
                  find.byType(BiliImportDialog),
                );
                expect(dialog.state.binding!.cidFor(0), 41);
                old = dialog.onUpdateNow();
              }
              oldStarted = true;
              old.then((_) => oldCompleted = true);

              await _waitFor(tester, () => plugin.entered.isCompleted);
              expect(api.fetched, [41]);
              expect(plugin.calls, hasLength(1));
              expect(plugin.calls.single['provider'], 'fixture');
              final request = plugin.calls.single['req'] as Map;
              expect(request['media_id'], 'work');
              expect(oldCompleted, isFalse);
              expect(debugPlayerDanmakuCount(), 0);
              final generation = debugPlayerSessionGenForProbe()!;

              if (changeSession) {
                switchingStarted = true;
                switching = session.applySession(const PlayRequestData(
                  provider: 'next', id: 'next-work', title: 'Next Work',
                  episodeId: 'ep-next', episodeTitle: 'Next Episode',
                  episodes: [Episode(id: 'ep-next', title: 'Next Episode')],
                ));
                switching.then((_) => switchingCompleted = true);
                await _waitFor(tester, () => resolver.entered.isCompleted);
                expect(debugPlayerSessionGenForProbe(), greaterThan(generation));
                expect(identical(mountedPage,
                    tester.widget<PlayerPage>(find.byType(PlayerPage))), isTrue);
                expect(switchingCompleted, isFalse,
                    reason: 'The new resolve remains pending; no new loader has run');
                expect(debugPlayerDanmakuCount(), 0);
              } else {
                expect(resolver.nextCalls, 0);
              }

              plugin.release();
              await _waitFor(tester, () => oldCompleted);
              await old;
              await tester.pump();
              final comments = tester.widget<DanmakuOverlay>(
                find.byType(DanmakuOverlay),
              ).comments;
              if (entry == 'manual update') {
                // Close through the real mounted panel callback, then reopen
                // settings to read its actual feedSamples constructor input.
                tester.widget<BiliImportDialog>(find.byType(BiliImportDialog))
                    .onClose();
                expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
                await tester.pump();
              }
              final settings = tester.widget<DanmakuSettingsDialog>(
                find.byType(DanmakuSettingsDialog),
              );
              expect(settings.feedSamples, isNotNull);
              final samples = settings.feedSamples!.values
                  .expand((feed) => feed).toList();
              final hostCount = debugPlayerDanmakuCount();
              final overlayHasOld = comments.any(
                (comment) => comment.text == _oldComment.text,
              );
              final samplesHaveOld = samples.any(
                (comment) => comment.text == _oldComment.text,
              );
              debugPrint('[external-fixture] observations: host=$hostCount '
                  'overlayOld=$overlayHasOld samplesOld=$samplesHaveOld '
                  'switchingCompleted=$switchingCompleted');
              if (changeSession) {
                expect(hostCount, 0,
                    reason: 'An old aggregate must not publish into a new play session');
                expect(overlayHasOld, isFalse);
                expect(samplesHaveOld, isFalse,
                    reason: 'Old feed samples must not enter the new settings session');
                expect(switchingCompleted, isFalse);
              } else {
                expect(debugPlayerSessionGenForProbe(), generation);
                expect(hostCount, 1);
                expect(comments.single.text, _oldComment.text,
                    reason: 'Positive control requires actual primary publication');
                expect(samples.single.text, _oldComment.text,
                    reason: 'Positive control requires actual settings feed publication');
              }
              expect(plugin.calls, hasLength(1));
            } finally {
              // Keep all pump/native cleanup in the test callback's FakeAsync
              // environment even when a behavior assertion throws. The gates,
              // production futures, lock barrier, and wait budgets are intact.
              debugPrint('[external-fixture] cleanup: release gates');
              plugin.release();
              resolver.release();
              if (oldStarted) {
                await _waitFor(tester, () => oldCompleted);
                await old;
              }
              debugPrint('[external-fixture] cleanup: old terminal');
              if (switchingStarted) {
                await _waitFor(tester, () => switchingCompleted);
                await switching;
              }
              debugPrint('[external-fixture] cleanup: session terminal');
              if (find.byType(PlayerPage).evaluate().isNotEmpty) {
                await _finish(tester);
              }
              debugPrint('[external-fixture] cleanup: native terminal');
            }
          },
        );
      }
    }
  }
}
