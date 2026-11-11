@Tags(['native-media'])
library;

// Private software decode/API qualification. The native video output channel is
// a test adapter, not a real texture/surface or an Owner client acceptance.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;
import 'package:sourin_spike/core/app_log.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart' show PlayerBottomBar, PlayerPopoverIds;
import 'package:sourin_spike/ui/player/player_more_menu.dart';
import 'package:sourin_spike/ui/player/player_popover.dart' show PopoverAnchorButton, PopoverMotion;
import 'package:sourin_spike/ui/remote_bridge.dart';

const _assetSha = 'A7F9B098190919564D466B5E6F2B46ECE3BEC6671E13748D02262DBF09307C67';
const _work = 'playerpage-shot-fixture';
const _videoChannel = MethodChannel('com.alexmercerind/media_kit_video');

// Future callbacks created by testWidgets belong to its fakeAsync zone.
// Only the real delay is awaited in runAsync; each pump resumes those callbacks.
Future<void> _pumpUntil(WidgetTester t, bool Function() ready, String message,
    {Duration budget = const Duration(seconds: 15)}) async {
  final wall = Stopwatch()..start();
  while (!ready()) {
    if (wall.elapsed >= budget) throw TimeoutException(message, budget);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 40));
  }
  if (wall.elapsed > budget) throw TimeoutException(message, budget);
}

Future<T> _pumpFuture<T>(WidgetTester t, Future<T> pending, String message) async {
  var completed = false;
  late T value;
  Object? error;
  StackTrace? stack;
  unawaited(pending.then<void>((result) {
    value = result;
    completed = true;
  }, onError: (Object failure, StackTrace failureStack) {
    error = failure;
    stack = failureStack;
    completed = true;
  }));
  await _pumpUntil(t, () => completed, message);
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value;
}

final _phaseWall = Stopwatch()..start();
var _phaseSequence = 0;

void _phase(String name, [Object? failure]) {
  final run = Platform.environment['SOURIN_SCREENSHOT_PAGE_RUN']!;
  File('$run/completion-phases.jsonl').writeAsStringSync(jsonEncode({
    'sequence': ++_phaseSequence, 'elapsed_ms': _phaseWall.elapsedMilliseconds,
    'utc': DateTime.now().toUtc().toIso8601String(), 'phase': name,
    if (failure != null) 'failure': failure.toString(),
  }) + '\n', mode: FileMode.append, flush: true);
}

// Trace the same public Automated binding methods. The original runTest Future
// is returned unchanged, and the original invariants/postTest still execute.
class _CompletionTracingBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  Future<void> runTest(Future<void> Function() testBody, void Function() invariantTester,
      {String description = ''}) {
    _phase('binding_runTest_enter');
    final result = super.runTest(testBody, () {
      _phase('binding_invariants_before');
      invariantTester();
      _phase('binding_invariants_after');
    }, description: description);
    unawaited(result.then<void>((_) => _phase('binding_runTest_completed'),
        onError: (Object error, StackTrace stack) => _phase('binding_runTest_failed', error)));
    return result;
  }

  @override
  void asyncBarrier() {
    _phase('binding_async_barrier_before');
    super.asyncBarrier();
    _phase('binding_async_barrier_after');
  }

  @override
  void postTest() {
    _phase('binding_postTest_before');
    super.postTest();
    _phase('binding_postTest_after');
  }
}


// Only the actual shots Directory.create completion is delayed. Every forwarded
// operation still reaches the original filesystem in the captured parent zone.
class _ShotsCreateGate implements Directory {
  _ShotsCreateGate(this.delegate, this.parentZone);
  final Directory delegate;
  final Zone parentZone;
  final entered = Completer<void>();
  final resume = Completer<void>();
  final completed = Completer<void>();
  int createCalls = 0;
  void release() { if (!resume.isCompleted) resume.complete(); }
  @override String get path => delegate.path;
  @override Directory get absolute => this;
  @override Uri get uri => parentZone.run(() => delegate.uri);
  @override Future<bool> exists() => parentZone.run(delegate.exists);
  @override Future<Directory> create({bool recursive = false}) async {
    createCalls++;
    if (createCalls != 1) throw StateError('Repeated owned shots creation');
    entered.complete();
    try {
      await resume.future;
      await parentZone.run(() => delegate.create(recursive: recursive));
      return this;
    } finally { completed.complete(); }
  }
  @override dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected shots operation: ${invocation.memberName}');
}
String _pathKey(String path) => path.replaceAll('\\', '/').toLowerCase();

void main() {
  _CompletionTracingBinding();
  Future<void> exercise(WidgetTester t, {required bool unmount}) async {
    _phase('callback_enter');
    final asset = File(Platform.environment['SOURIN_SCREENSHOT_ASSET']!);
    final dll = File(Platform.environment['SOURIN_SCREENSHOT_LIBMPV']!);
    final run = Directory(Platform.environment['SOURIN_SCREENSHOT_PAGE_RUN']!);
    final data = Directory('${run.path}${Platform.pathSeparator}data${Platform.pathSeparator}${unmount ? 'disposed' : 'alive'}');
    expect(run.existsSync(), isTrue);
    expect(run.isAbsolute && asset.isAbsolute && dll.isAbsolute, isTrue);
    expect(sha256.convert(asset.readAsBytesSync()).toString().toUpperCase(), _assetSha);
    expect(sha256.convert(dll.readAsBytesSync()).toString().toUpperCase(),
        Platform.environment['SOURIN_SCREENSHOT_LIBMPV_SHA256']!.toUpperCase());
    expect(NativePlayer.test, isFalse);
    final report = <String, Object?>{
      'schema': 1, 'passed': false,
      'scope': 'real PlayerPage original screenshot storage await versus page disposal; actual software capture, filesystem and More callback, mocked output API',
      'native_video_output_api_mocked': true, 'native_video_surface_accepted': false,
      'native_first_frame_rendered_accepted': false, 'owner_acceptance_complete': false,
      'production_local_boot_path_used': true, 'screenshot_bytes_injected': false,
      'instrumentation_revision': 'late-controls-v1',
      'future_wait_strategy': 'latched completion + runAsync(real20ms delay) + pump40ms',
      'per_phase_wall_budget_seconds': 15,
      'screenshot_helper_overridden': false, 'save_or_flash_shortcut_used': false,
      'desktop_input_actions': 0, 'production_entry_launches': 0,
      'asset_sha256': _assetSha, 'libmpv_sha256': Platform.environment['SOURIN_SCREENSHOT_LIBMPV_SHA256'],
    };
    final coreCalls = <Map<String, Object?>>[];
    final deniedCore = <String>[];
    final channelCalls = <Map<String, Object?>>[];
    final errors = <String>[];
    final frameworkErrors = <String>[];
    final frameworkMissingPluginFlags = <bool>[];
    final allFrameworkErrorRecords = <Map<String, Object?>>[];
    final pendingExceptionRecords = <Map<String, Object?>>[];
    final allowedEnvironmentErrors = <String>[];
    final parentZone = Zone.current;
    Directory realDirectory(String path) => parentZone.run(() => Directory(path).absolute);
    final shots = realDirectory('${data.path}${Platform.pathSeparator}shots');
    final storage = _ShotsCreateGate(shots, parentZone);
    var pageUnmounted = false;
    final mountedPlayer = Completer<Player>();
    Player? player;
    NativePlayer? native;
    StreamSubscription<String>? errorSubscription;
    final previousCore = SourinCore.debugCallAsyncTransport;
    final previousErrorHandler = FlutterError.onError;
    Object? failure;
    StackTrace? failureStack;
    FlutterError.onError = (details) {
      final text = details.exceptionAsString();
      frameworkErrors.add(text);
      frameworkMissingPluginFlags.add(details.exception is MissingPluginException);
      allFrameworkErrorRecords.add({'type': details.exception.runtimeType.toString(),
        'text': text, 'explicit_missing_plugin': details.exception is MissingPluginException});
      previousErrorHandler?.call(details);
    };
    void claimEnvironmentErrors() {
      final allRecordedAreMissing = frameworkErrors.isNotEmpty &&
          frameworkErrors.length == frameworkMissingPluginFlags.length &&
          frameworkMissingPluginFlags.every((allowed) => allowed);
      final currentPending = <Map<String, Object?>>[];
      Object? pending;
      while ((pending = t.takeException()) != null) {
        final text = pending.toString().trim();
        final aggregate = RegExp(r'^Multiple exceptions \((\d+)\) were detected during the running of the current test, and at least one was unexpected\.$').firstMatch(text);
        final allowedAggregate = aggregate != null && allRecordedAreMissing &&
            int.parse(aggregate.group(1)!) == frameworkErrors.length;
        final allowed = pending is MissingPluginException || allowedAggregate;
        final record = <String, Object?>{'type': pending.runtimeType.toString(),
          'text': text, 'allowed': allowed, 'explicit_missing_plugin': pending is MissingPluginException,
          'aggregate_fully_recorded_missing_plugins': allowedAggregate,
          'recorded_framework_error_count': frameworkErrors.length};
        currentPending.add(record);
        pendingExceptionRecords.add(record);
      }
      expect(currentPending.where((record) => record['allowed'] != true), isEmpty,
          reason: 'Unrecorded or non-environment pending exceptions must fail');
      expect(frameworkMissingPluginFlags.where((allowed) => !allowed), isEmpty,
          reason: 'Only missing platform plugins are environment exclusions; capture/save/UI errors fail');
      allowedEnvironmentErrors.addAll(frameworkErrors);
      frameworkErrors.clear();
      frameworkMissingPluginFlags.clear();
    }
    try {
      expect(previousCore, isNull);
      await t.runAsync(() async {
        await data.create(recursive: true);
        ClipDownloader.debugSetDataDir(data.path);
        await UiPrefs.load(data.path);
        UiPrefs.set('dsh.playprefs.autoSkip', '0');
        DiskCache.init(data.path);
        MediaKit.ensureInitialized(libmpv: dll.absolute.path);
      });
      AppLog.debugClear();
      AppLog.debugSetEnabled(false);
      SourinCore.debugCallAsyncTransport = (command, arguments) async {
        final args = arguments ?? <String, dynamic>{};
        coreCalls.add({'command': command, 'args': args});
        switch (command) {
          case 'list_providers':
          case 'get_provider_order':
            expect(args, isEmpty);
            return <dynamic>[];
          case 'remote_status_cmd':
            expect(args, isEmpty);
            // Owning RemoteBridge._ensurePolling + RemoteStatus.fromJson:
            // fixed disabled response never enables remote service/commands.
            return <String, dynamic>{'running': false, 'reachable': false,
              'url': '', 'port': 8642, 'pin': '', 'fixedPin': null,
              'lanIp': '', 'qrSvg': ''};
          case 'end_yield_for_seek':
            expect(args, isEmpty); // Owning production page dispose always ends its yield window.
            return <String, dynamic>{'ok': true};
          case 'get_progress':
          case 'get_skip_marker':
          case 'get_effective_skip_marker':
          case 'save_progress':
            expect(args['provider'], 'local');
            expect(args['id'], _work);
            return null;
          case 'pan_cleanup_temp':
            expect(args['invalidate'], isTrue);
            expect(args['play_consumer'], isA<String>());
            expect(args['play_generation'], isA<int>());
            return <String, dynamic>{};
          default:
            deniedCore.add(command);
            throw StateError('Unapproved isolated core command: $command');
        }
      };
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(_videoChannel, (call) async {
        channelCalls.add({'method': call.method, 'arguments': call.arguments});
        if (call.method == 'VideoOutputManager.Create') {
          final actual = await mountedPlayer.future;
          final backend = actual.platform as NativePlayer;
          final handle = await actual.handle;
          expect((call.arguments as Map)['handle'], handle.toString());
          for (final property in {'vo': 'null', 'ao': 'null', 'hwdec': 'no',
              'aid': 'no', 'sid': 'no', 'http-proxy': '', 'load-unsafe-playlists': 'no'}.entries) {
            await backend.setProperty(property.key, property.value, waitForInitialization: false);
          }
          final replied = Completer<void>();
          // An ID unblocks controller construction. A zero rect deliberately
          // does not signal a real rendered first frame. JPEG still comes from C.
          t.binding.defaultBinaryMessenger.handlePlatformMessage(_videoChannel.name,
              const StandardMethodCodec().encodeMethodCall(MethodCall('VideoOutput.Resize', {
                'handle': handle, 'id': 19001,
                'rect': {'left': 0, 'top': 0, 'width': 0, 'height': 0},
              })), (_) => replied.complete());
          await replied.future;
          return null;
        }
        if (call.method == 'VideoOutputManager.SetSize' || call.method == 'VideoOutputManager.Dispose') return null;
        throw StateError('Unapproved video output adapter call: ${call.method}');
      });
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1280, 800);
      await t.pumpWidget(MaterialApp(home: PlayerPage(
        provider: 'local', id: _work, title: 'Owned local screenshot fixture',
        localPath: asset.path,
        episodes: [Episode(id: 'owned-episode', title: 'Owned episode', url: asset.uri.toString())],
        episodeId: 'owned-episode', episodeTitle: 'Owned episode',
      )));
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(find.byType(Video), findsOneWidget);
      final video = t.widget<Video>(find.byType(Video));
      player = video.controller.player;
      native = player!.platform as NativePlayer;
      mountedPlayer.complete(player);
      errorSubscription = player!.stream.error.listen(errors.add);
      await _pumpFuture(t, video.controller.platform.future,
          'Production VideoController platform did not initialize');
      await _pumpFuture(t, native!.setProperty('hwdec', 'no'),
          'Same page software decode property did not complete');
      await _pumpUntil(t, () => player!.state.position >= const Duration(seconds: 2),
          'Same page player did not decode/advance');
      await _pumpFuture(t, player!.pause(), 'Same page player did not pause');
      await t.pump();
      claimEnvironmentErrors();
      expect(debugPlayerErrorForProbe(), isNull);
      expect(debugPlayerLoadCallsForProbe(), 0, reason: 'Production local boot must avoid provider resolution');
      expect(debugPlayerStartPlaybackCallsForProbe(), 1);
      expect(player!.state.width, 320);
      expect(player!.state.height, 180);
      final initialHandle = await _pumpFuture(t, player!.handle, 'Same page player handle did not resolve');
      report['same_player_handle'] = initialHandle;
      report['native_position_ms'] = player!.state.position.inMilliseconds;
      final bar = find.byType(PlayerBottomBar);
      final anchor = find.descendant(of: bar, matching: find.byWidgetPredicate(
          (widget) => widget is PopoverAnchorButton && widget.id == PlayerPopoverIds.more));
      expect(anchor, findsOneWidget);
      final controller = t.widget<PopoverAnchorButton>(anchor).controller;
      controller.toggle(PlayerPopoverIds.more); // Existing production controller API, no OS input.
      Rect? previousRect;
      var ready = false;
      for (var frame = 0; frame < 24; frame++) {
        await t.pump();
        await t.pump(const Duration(milliseconds: 40));
        final menu = find.byType(PlayerMoreMenu);
        final shot = find.descendant(of: menu, matching: find.text('截图'));
        if (menu.evaluate().length != 1 || shot.evaluate().length != 1) { previousRect = null; continue; }
        final row = find.ancestor(of: shot, matching: find.byType(miuix.MiuixPressable));
        if (row.evaluate().length != 1) { previousRect = null; continue; }
        final element = t.element(row);
        final fade = element.findAncestorWidgetOfExactType<FadeTransition>();
        final motion = element.findAncestorWidgetOfExactType<PopoverMotion>();
        final rect = t.getRect(row);
        final terminal = controller.openId == PlayerPopoverIds.more && motion?.visible == true &&
            fade?.opacity.value == 1 && fade?.opacity.status == AnimationStatus.completed &&
            row.hitTestable().evaluate().length == 1;
        if (terminal && rect == previousRect) { ready = true; break; }
        previousRect = terminal ? rect : null;
      }
      expect(ready, isTrue, reason: 'Actual screenshot row must reach terminal/hit geometry');
      final shot = find.descendant(of: find.byType(PlayerMoreMenu), matching: find.text('截图'));
      final row = find.ancestor(of: shot, matching: find.byType(miuix.MiuixPressable));
      expect(row.hitTestable(), findsOneWidget);
      final pressable = t.widget<miuix.MiuixPressable>(row);
      expect(pressable.onPressed, isNotNull);
      final before = debugPlayerScreenshotCalls()!;
      expect(await t.runAsync(shots.exists), isFalse,
          reason: 'The storage delay must be the first actual shots-directory creation');
      await IOOverrides.runZoned(() async {
        pressable.onPressed!(); // Same real More row: original capture/save/UI method.
        await _pumpUntil(t, () => storage.entered.isCompleted,
            'Original capture did not reach the actual shots create await');
        expect(storage.createCalls, 1);
        expect(debugPlayerScreenshotCalls(), before + 1);
        expect(await t.runAsync(shots.exists), isFalse,
            reason: 'The original create must still be held before either scenario');
        if (unmount) {
          await t.pumpWidget(const SizedBox.shrink());
          pageUnmounted = true;
          expect(find.byType(PlayerPage), findsNothing);
          expect(debugPlayerScreenshotCalls(), isNull);
          await _pumpUntil(t, () => native!.disposed,
              'Original page did not dispose its own native player before save release');
          expect(native!.disposed, isTrue);
        } else {
          expect(find.byType(PlayerPage), findsOneWidget);
          expect(identical(t.widget<Video>(find.byType(Video)).controller.player, player), isTrue);
          expect(native!.disposed, isFalse);
        }
        storage.release();
        await _pumpUntil(t, () => storage.completed.isCompleted,
            'The original filesystem creation did not resume');
        await _pumpUntil(t, () => AppLog.lines.any((line) =>
            line.tag == 'DL' && line.message.startsWith('截图 ')),
            'Original saved-file success log did not complete');
        // Success logging and _showControls/catch are one synchronous tail;
        // this pump finishes that tail rather than inventing a completion hook.
        await t.pump();
        final files = await t.runAsync(() => shots.list().where((entry) => entry is File).toList());
        expect(files, hasLength(1), reason: 'A requested screenshot must finish saving even after exit');
        final saved = files!.single as File;
        expect(saved.path, endsWith('.jpg'));
        final bytes = (await t.runAsync(saved.readAsBytes))!;
        expect(bytes, isNotEmpty);
        expect(bytes.take(2).toList(), [0xff, 0xd8]);
        expect(AppLog.lines.where((line) => line.tag == 'DL' && line.message.startsWith('截图 ')), hasLength(1));
        expect(AppLog.lines.any((line) => line.tag == 'DL' && line.message.contains(saved.path)), isTrue);
        final falseFailures = AppLog.lines.where((line) =>
            line.tag == 'DL' && line.message.startsWith('截图失败：')).map((line) => line.message).toList();
        report.addAll({'scenario': unmount ? 'disposed-before-save-completion' : 'alive-through-save',
          'storage_create_calls': storage.createCalls, 'storage_create_completed': storage.completed.isCompleted,
          'page_unmounted_before_release': pageUnmounted, 'native_disposed_before_release': unmount,
          'actual_saved_path': saved.path, 'actual_saved_bytes': bytes.length,
          'saved_jpeg_sha256': sha256.convert(bytes).toString().toUpperCase(),
          'false_failure_logs_after_success': falseFailures});
        expect(falseFailures, isEmpty,
            reason: 'Successful screenshot must not be reclassified as failure after its page is disposed');
        claimEnvironmentErrors();
        if (!unmount) {
          final tip = debugPlayerTipForProbe()!;
          expect(tip, startsWith('已截图 '));
          expect(tip, contains(saved.path));
          expect(find.text(tip), findsOneWidget);
          expect(debugPlayerControlsVisibleForProbe(), isTrue);
          report['alive_original_feedback_visible'] = true;
          report['alive_original_controls_visible'] = true;
        } else {
          expect(find.byType(PlayerPage), findsNothing);
          expect(debugPlayerTipForProbe(), isNull);
          report['disposed_page_not_restored'] = true;
        }
      }, createDirectory: (path) {
        final actual = realDirectory(path);
        return _pathKey(actual.path) == _pathKey(shots.path) ? storage : actual;
      });
      expect(errors, isEmpty);
      expect(deniedCore, isEmpty);
      report['passed'] = true;
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      report['failure'] = error.toString();
      report['failure_stack'] = stack.toString();
    } finally {
      try {
        storage.release();
        if (storage.entered.isCompleted) {
          await _pumpUntil(t, () => storage.completed.isCompleted, "Held shots creation did not settle during cleanup");
        }
        await t.pumpWidget(const SizedBox.shrink());
        if (native != null) {
          await _pumpUntil(t, () => native!.disposed, 'Production page disposal did not finish');
        }
        await _pumpFuture(t, NativePlayer.lock.synchronized(() async {}),
            'Production native disposal lock did not drain');
        final destroyWindow = Stopwatch()..start();
        await _pumpUntil(t, () => destroyWindow.elapsed >= const Duration(seconds: 6),
            'Production native six-second destroy window did not drain');
        report['native_destroy_window_real_elapsed_ms'] = destroyWindow.elapsedMilliseconds;
        await _pumpFuture(t, UiPrefs.flush(), 'Isolated preferences did not flush');
        for (var i = 0; i < 60; i++) { await t.pump(const Duration(seconds: 3)); }
        claimEnvironmentErrors();
      } catch (error, stack) {
        report['cleanup_failure'] = error.toString();
        report['cleanup_failure_stack'] = stack.toString();
        report['passed'] = false;
        failure ??= error;
        failureStack ??= stack;
      }
      RemoteBridge.instance.stop();
      _phase('cancel_before');
      if (errorSubscription != null) {
        await _pumpFuture(t, errorSubscription!.cancel(), 'Page error subscription cancellation did not complete');
      }
      _phase('cancel_after');
      // This is a final bounded real/fake continuation barrier, not a claim
      // that cancellation caused v2's post-report completion timeout.
      _phase('tail_barrier_before');
      final tailWall = Stopwatch()..start();
      await _pumpUntil(t, () => tailWall.elapsed >= const Duration(milliseconds: 20),
          'Final real/fake continuation barrier did not complete');
      _phase('tail_barrier_after');
      claimEnvironmentErrors();
      report['player_disposed'] = native?.disposed == true;
      report['native_errors'] = errors;
      report['strict_core_calls'] = coreCalls;
      report['denied_core_calls'] = deniedCore;
      report['video_output_adapter_calls'] = channelCalls;
      report['allowed_missing_plugin_environment_errors'] = allowedEnvironmentErrors;
      report['all_framework_error_records'] = allFrameworkErrorRecords;
      report['all_taken_pending_exception_records'] = pendingExceptionRecords;
      report['remaining_framework_errors'] = frameworkErrors;
      if (report['player_disposed'] != true || errors.isNotEmpty || deniedCore.isNotEmpty) report['passed'] = false;
      File('${run.path}/page-${unmount ? 'disposed' : 'alive'}-result.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(report), flush: true);
      _phase('page_report_written');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(_videoChannel, null);
      _phase('restore_video_channel');
      SourinCore.debugCallAsyncTransport = previousCore;
      _phase('restore_core_transport');
      FlutterError.onError = previousErrorHandler;
      _phase('restore_framework_handler');
      ClipDownloader.debugSetDataDir(null);
      _phase('restore_clip_data');
      AppLog.debugSetEnabled(true);
      _phase('restore_app_log');
      UiPrefs.debugResetForTest();
      _phase('restore_ui_prefs');
      t.view.reset();
      _phase('restore_view');
    }
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    expect(report['passed'], isTrue);
    _phase('callback_final_expect_passed');
    _phase('callback_tail_return');
  }
  testWidgets('alive PlayerPage preserves screenshot save feedback and controls', (t) => exercise(t, unmount: false), timeout: const Timeout(Duration(seconds: 90)));
  testWidgets('disposed PlayerPage finishes screenshot save without stale controls or false failure', (t) => exercise(t, unmount: true), timeout: const Timeout(Duration(seconds: 90)));
}

