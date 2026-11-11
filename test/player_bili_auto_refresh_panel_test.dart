@Tags(['native-media'])
library;

// Exercises the actual updateEpisodes caller of automatic external refresh.
// Reuses the final aggregate fixture's isolated native handshake and helpers.
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No external HTTP is allowed: ${invocation.memberName}');
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
    bvid: 'BV1fixture0001',
    aid: 1,
    title: 'Fixture external binding',
  );
}

class _PluginGate {
  final entered = Completer<void>();
  final completed = Completer<void>();
  Completer<Map<String, dynamic>>? _pending;
  final calls = <Map<String, dynamic>>[];

  void release() {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    pending.complete({'items': <dynamic>[], 'source': 'fixture-plugin'});
  }

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    if (command == 'provider_danmaku_list') {
      final captured = Map<String, dynamic>.from(args!);
      captured['req'] = Map<String, dynamic>.from(captured['req'] as Map);
      calls.add(captured);
      if (calls.length != 1) throw StateError('Unexpected second plugin fetch');
      // Preserve the final fixture's request-zone Future construction.
      final pending = _pending = Completer<Map<String, dynamic>>();
      entered.complete();
      final response = await pending.future;
      completed.complete();
      return response;
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

// updateEpisodes deliberately launches its real caller unawaited. This marker
// proves transport completion, not direct _biliAutoRefresh Future completion.
// The bound bridge/aggregate/apply/panel continuation has only microtask awaits
// after this empty plugin response; pump drains them without requiring mutation.
// Root must qualify this draft's timing and positive control before accepting it.
Future<void> _drainAutoRefresh(WidgetTester tester, _PluginGate plugin) async {
  await _waitFor(tester, () => plugin.completed.isCompleted);
  await tester.pump();
  await tester.pump();
  await tester.pump();
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
      'auto-refresh-panel-draft-',
    );
    ClipDownloader.debugSetDataDir(scratch.path);
    UiPrefs.debugResetForTest();
    BiliDanmakuStore.debugResetForTest();
    setBiliAutoUpdateEnabled(false);
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
      'auto refresh via updateEpisodes: ${changeSession ? "cancelled apply must not update panel" : "current apply updates panel"}',
      (tester) async {
        var autoStarted = false;
        var switchingStarted = false;
        var switchingCompleted = false;
        Future<void> switching = Future<void>.value();
        try {
          await _mount(tester);
          final mountedPage = tester.widget<PlayerPage>(
            find.byType(PlayerPage),
          );
          final session = tester.state(find.byType(PlayerPage)) as MediaSession;
          final api = _ExternalApi();
          debugPlayerSetBiliApiForProbe(api);
          saveBinding('fixture', 'work', _manualBinding);
          expect(api.fetched, isEmpty);
          expect(debugPlayerDanmakuCount(), 0);
          expect(biliAutoUpdateEnabled(), isFalse);

          // Open through the real settings callback so the host hydrates the
          // manual binding and panel token; the raw visibility probe is unused.
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
          final initialDialog = tester.widget<BiliImportDialog>(
            find.byType(BiliImportDialog),
          );
          expect(initialDialog.state.binding!.cidFor(0), 41);
          expect(initialDialog.state.result, isNull);
          expect(initialDialog.state.comments, 0);

          // Toggle using the mounted panel's real callback only after mounting
          // and binding. Opening never fetches comments; this changed ordinary
          // episode list invokes the actual unawaited _biliAutoRefresh caller.
          initialDialog.onSetAutoUpdate(true);
          expect(biliAutoUpdateEnabled(), isTrue);
          final generation = debugPlayerSessionGenForProbe()!;
          session.updateEpisodes(const [
            Episode(id: 'ep1', title: 'Episode One refreshed'),
            Episode(id: 'ep2', title: 'Episode Two'),
          ]);
          autoStarted = true;
          await _waitFor(tester, () => plugin.entered.isCompleted);
          expect(api.fetched, [41]);
          expect(plugin.calls, hasLength(1));
          expect(plugin.calls.single['provider'], 'fixture');
          final request = plugin.calls.single['req'] as Map;
          expect(request['media_id'], 'work');
          expect(request['episode_id'], '0');
          expect(
            debugPlayerSessionGenForProbe(),
            generation,
            reason: 'updateEpisodes must retain the original session',
          );
          expect(plugin.completed.isCompleted, isFalse);
          expect(debugPlayerDanmakuCount(), 0);
          expect(
            tester
                .widget<BiliImportDialog>(find.byType(BiliImportDialog))
                .state
                .result,
            isNull,
          );

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
            expect(switchingCompleted, isFalse);
            expect(
              resolver.pending.isCompleted,
              isFalse,
              reason: 'The new resolver is held; no new loader can publish',
            );
            expect(find.byType(BiliImportDialog), findsOneWidget);
            expect(debugPlayerDanmakuCount(), 0);
          } else {
            expect(resolver.nextCalls, 0);
          }

          plugin.release();
          await _drainAutoRefresh(tester, plugin);
          final panel = tester
              .widget<BiliImportDialog>(find.byType(BiliImportDialog))
              .state;
          final comments = tester
              .widget<DanmakuOverlay>(find.byType(DanmakuOverlay))
              .comments;
          final hostCount = debugPlayerDanmakuCount();

          // Snapshot actual BiliImportState before closing the sheet. Reopen
          // settings through its established probe to read real feedSamples.
          tester
              .widget<BiliImportDialog>(find.byType(BiliImportDialog))
              .onClose();
          expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
          await tester.pump();
          final settings = tester.widget<DanmakuSettingsDialog>(
            find.byType(DanmakuSettingsDialog),
          );
          expect(settings.feedSamples, isNotNull);
          final samples = settings.feedSamples!.values
              .expand((feed) => feed)
              .toList();
          final overlayHasOld = comments.any(
            (comment) => comment.text == _oldComment.text,
          );
          final samplesHaveOld = samples.any(
            (comment) => comment.text == _oldComment.text,
          );
          debugPrint(
            '[auto-refresh-draft] observations: host=$hostCount '
            'overlayOld=$overlayHasOld samplesOld=$samplesHaveOld '
            'panelCid=${panel.result?.cid} panelCount=${panel.comments} '
            'panelTitle=${panel.episodeTitle} panelEpisodes=${panel.episodeCount} '
            'pluginCompleted=${plugin.completed.isCompleted} '
            'switchingCompleted=$switchingCompleted',
          );
          expect(plugin.calls, hasLength(1));
          expect(api.fetched, [41]);
          if (changeSession) {
            // Existing integrated helper guards should already satisfy these.
            expect(hostCount, 0);
            expect(overlayHasOld, isFalse);
            expect(samplesHaveOld, isFalse);
            expect(switchingCompleted, isFalse);
            expect(resolver.pending.isCompleted, isFalse);
            // Behavior requirement: cancelled apply must also suppress its
            // caller's stale panel continuation. Current source is predicted
            // to fail here with cid=41/count=1 and Next Episode metadata.
            expect(
              panel.result,
              isNull,
              reason: 'Cancelled old auto refresh must not publish its result',
            );
            expect(
              panel.comments,
              0,
              reason: 'Cancelled old auto refresh must not publish its count',
            );
          } else {
            expect(debugPlayerSessionGenForProbe(), generation);
            expect(hostCount, 1);
            expect(comments.single.text, _oldComment.text);
            expect(samples.single.text, _oldComment.text);
            expect(panel.result, isNotNull);
            expect(panel.result!.cid, 41);
            expect(panel.result!.comments.single.text, _oldComment.text);
            expect(panel.comments, 1);
            expect(panel.episodeIndex, 0);
            expect(panel.episodeTitle, 'Episode One refreshed');
            expect(panel.episodeCount, 2);
          }
        } finally {
          // Do not reset globals while the real unawaited auto caller has a
          // held plugin Future. Release and drain it in FakeAsync, then finish
          // the new real applySession Future and native disposal barrier.
          debugPrint('[auto-refresh-draft] cleanup: release gates');
          plugin.release();
          resolver.release();
          if (autoStarted && plugin.entered.isCompleted) {
            await _drainAutoRefresh(tester, plugin);
          }
          if (switchingStarted) {
            await _waitFor(tester, () => switchingCompleted);
            await switching;
          }
          if (find.byType(PlayerPage).evaluate().isNotEmpty) {
            await _finish(tester);
          }
          debugPrint('[auto-refresh-draft] cleanup: native terminal');
        }
      },
    );
  }
}
