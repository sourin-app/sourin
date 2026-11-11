@Tags(['native-media'])
library;

// Reuses the qualified external-aggregation fixture's native handshake.
// Uses real mounted PlayerPage session/aggregation/host-publication paths.
// The external fetch and new resolver are gated; plugin data is local and empty.
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
  text: 'Old-session late external response',
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No external HTTP is allowed: ${invocation.memberName}');
}

class _ExternalApi extends BiliApi {
  _ExternalApi() : super(client: _NoNetworkClient());
  final entered = Completer<void>();
  Completer<List<DanmakuComment>>? _pending;
  final fetched = <int>[];

  void release() {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    pending.complete(const [_oldComment]);
  }

  @override
  Future<List<DanmakuComment>> danmaku(int cid) async {
    fetched.add(cid);
    if (fetched.length != 1)
      throw StateError('Unexpected second external fetch');
    // Create the request Future at the actual API entry in the production
    // caller's error zone, following the qualified fixture's gate discipline.
    final pending = _pending = Completer<List<DanmakuComment>>();
    entered.complete();
    return pending.future;
  }

  @override
  Future<BiliVideoInfo> videoInfo(BiliRef ref) async => const BiliVideoInfo(
    bvid: 'BV1fixture0001',
    aid: 1,
    title: 'Fixture external binding',
  );
}

class _PluginGate {
  final calls = <Map<String, dynamic>>[];

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    if (command == 'provider_danmaku_list') {
      final captured = Map<String, dynamic>.from(args!);
      captured['req'] = Map<String, dynamic>.from(captured['req'] as Map);
      calls.add(captured);
      if (calls.length != 1) throw StateError('Unexpected second plugin fetch');
      // Do not gate or unconditionally await plugin entry: a repaired old
      // caller must terminate before entering aggregation at all.
      return {'items': <dynamic>[], 'source': 'fixture-plugin'};
    }
    if (command == 'list_providers' || command == 'resolve_stream') {
      return <dynamic>[];
    }
    if (command == 'pan_cleanup_temp' ||
        command == 'save_progress' ||
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

  Future<List<StreamCandidate>> resolve(
    String provider,
    String id, {
    PlayRequest? req,
  }) async {
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
    scratch = await Directory.systemTemp.createTemp(
      'external-late-fetch-draft-',
    );
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

  for (final changeSession in [true, false]) {
    testWidgets(
      'manual update: ${changeSession ? "new session rejects" : "current session accepts"} late external success before aggregation entry',
      (tester) async {
        var oldStarted = false;
        var oldCompleted = false;
        var switchingStarted = false;
        var switchingCompleted = false;
        Future<void> old = Future<void>.value();
        Future<void> switching = Future<void>.value();
        final api = _ExternalApi();
        try {
          await _mount(tester);
          final mountedPage = tester.widget<PlayerPage>(
            find.byType(PlayerPage),
          );
          final session = tester.state(find.byType(PlayerPage)) as MediaSession;
          debugPlayerSetBiliApiForProbe(api);
          saveBinding('fixture', 'work', _manualBinding);
          expect(debugPlayerDanmakuCount(), 0);

          // Use the real panel-open callback; the raw Bili-sheet probe only
          // changes visibility and does not hydrate binding or panelToken.
          expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
          await tester.pump();
          final initialSettings = tester.widget<DanmakuSettingsDialog>(
            find.byType(DanmakuSettingsDialog),
          );
          expect(initialSettings.feedSamples, isNotNull);
          expect(initialSettings.feedSamples, isEmpty);
          expect(initialSettings.onOpenBili, isNotNull);
          initialSettings.onOpenBili!();
          await tester.pump();
          final dialog = tester.widget<BiliImportDialog>(
            find.byType(BiliImportDialog),
          );
          expect(dialog.state.binding!.cidFor(0), 41);
          expect(dialog.state.result, isNull);
          expect(dialog.state.comments, 0);
          old = dialog.onUpdateNow();
          oldStarted = true;
          old.then((_) => oldCompleted = true);

          // The suspension is in the actual external API request, before
          // _biliApplyComments and before any plugin aggregation request.
          await _waitFor(tester, () => api.entered.isCompleted);
          expect(api.fetched, [41]);
          expect(plugin.calls, isEmpty);
          expect(oldCompleted, isFalse);
          expect(debugPlayerDanmakuCount(), 0);
          final generation = debugPlayerSessionGenForProbe()!;

          if (changeSession) {
            switchingStarted = true;
            switching = session.applySession(
              const PlayRequestData(
                provider: 'next',
                id: 'next-work',
                title: 'Next Work',
                episodeId: 'ep-next',
                episodeTitle: 'Next Episode',
                episodes: [Episode(id: 'ep-next', title: 'Next Episode')],
              ),
            );
            switching.then((_) => switchingCompleted = true);
            await _waitFor(tester, () => resolver.entered.isCompleted);
            expect(debugPlayerSessionGenForProbe(), greaterThan(generation));
            expect(
              identical(
                mountedPage,
                tester.widget<PlayerPage>(find.byType(PlayerPage)),
              ),
              isTrue,
            );
            expect(
              switchingCompleted,
              isFalse,
              reason: 'The new resolver stays pending before any new loader',
            );
            expect(debugPlayerDanmakuCount(), 0);
          } else {
            expect(resolver.nextCalls, 0);
          }

          // A successful old external response is now allowed to finish.
          // Await its terminal state, not plugin entry: rejection must make
          // the old operation finish with zero plugin calls after a repair.
          api.release();
          await _waitFor(tester, () => oldCompleted);
          await old;
          await tester.pump();
          final comments = tester
              .widget<DanmakuOverlay>(find.byType(DanmakuOverlay))
              .comments;
          final finalDialog = tester.widget<BiliImportDialog>(
            find.byType(BiliImportDialog),
          );
          final panelState = finalDialog.state;
          final panelResultHasOld =
              panelState.result?.comments.any(
                (comment) => comment.text == _oldComment.text,
              ) ??
              false;
          final panelComments = panelState.comments;
          finalDialog.onClose();
          expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
          await tester.pump();
          final settings = tester.widget<DanmakuSettingsDialog>(
            find.byType(DanmakuSettingsDialog),
          );
          expect(settings.feedSamples, isNotNull);
          final samples = settings.feedSamples!.values
              .expand((feed) => feed)
              .toList();
          final hostCount = debugPlayerDanmakuCount();
          final overlayHasOld = comments.any(
            (comment) => comment.text == _oldComment.text,
          );
          final samplesHaveOld = samples.any(
            (comment) => comment.text == _oldComment.text,
          );
          final requestProviders = plugin.calls
              .map((call) => call['provider'])
              .toList();
          final requestMedia = plugin.calls
              .map((call) => (call['req'] as Map)['media_id'])
              .toList();
          // Capture all actual outputs before the first behavior assertion,
          // including the unintended new-provider request in the RED case.
          debugPrint(
            '[external-late-fetch] observations: host=$hostCount '
            'overlayOld=$overlayHasOld samplesOld=$samplesHaveOld '
            'panelOld=$panelResultHasOld panelComments=$panelComments '
            'pluginCalls=${plugin.calls.length} providers=$requestProviders '
            'mediaIds=$requestMedia switchingCompleted=$switchingCompleted',
          );
          if (changeSession) {
            expect(
              hostCount,
              0,
              reason:
                  'An old fetch must not be claimed by the new play session',
            );
            expect(overlayHasOld, isFalse);
            expect(samplesHaveOld, isFalse);
            expect(
              panelResultHasOld,
              isFalse,
              reason: 'The old response must not replace the new session panel result',
            );
            expect(panelComments, 0);
            expect(
              plugin.calls,
              isEmpty,
              reason: 'Reject the obsolete fetch before entering aggregation',
            );
            expect(switchingCompleted, isFalse);
          } else {
            expect(debugPlayerSessionGenForProbe(), generation);
            expect(hostCount, 1);
            expect(
              comments.single.text,
              _oldComment.text,
              reason:
                  'Current control requires actual host/overlay publication',
            );
            expect(
              samples.single.text,
              _oldComment.text,
              reason:
                  'Current control requires actual settings feed publication',
            );
            expect(panelResultHasOld, isTrue);
            expect(panelComments, 1);
            expect(plugin.calls, hasLength(1));
            expect(plugin.calls.single['provider'], 'fixture');
            expect((plugin.calls.single['req'] as Map)['media_id'], 'work');
          }
        } finally {
          // Preserve the qualified fixture's in-body FakeAsync cleanup and
          // unchanged wait/native-disposal budgets even on behavior failure.
          debugPrint('[external-late-fetch] cleanup: release gates');
          api.release();
          resolver.release();
          if (oldStarted) {
            await _waitFor(tester, () => oldCompleted);
            await old;
          }
          debugPrint('[external-late-fetch] cleanup: old terminal');
          if (switchingStarted) {
            await _waitFor(tester, () => switchingCompleted);
            await switching;
          }
          debugPrint('[external-late-fetch] cleanup: session terminal');
          if (find.byType(PlayerPage).evaluate().isNotEmpty) {
            await _finish(tester);
          }
          debugPrint('[external-late-fetch] cleanup: native terminal');
        }
      },
    );
  }
}
