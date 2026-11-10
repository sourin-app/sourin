@Tags(['native-media'])
library;

// Uses the mounted PlayerPage and its real precheck/transport/start sequence.
// Substitutes HTTP responses, video-platform initialization, final native open
// and (only in the lifecycle group) diagnostic native property reads.
// This proves cancellation, not native decode or real source playback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const _oldUrl = 'https://media.invalid/delayed';
const _newStream = StreamCandidate(
  url: 'https://media.invalid/new.m3u8',
  kind: 'hls',
  label: '线路乙',
  headers: [('X-Candidate', 'new')],
);

const _videoChannelName = 'com.alexmercerind/media_kit_video';
const _videoChannel = MethodChannel(_videoChannelName);
final _createdHandles = <String>[];
final _disposedHandles = <String>[];
final _pushedHandles = <String>{};

// A mounted VideoController waits for the native platform's first texture ID.
// Complete that real initialization handshake so disposal can release the
// NativePlayer global lock before the next case creates its own player.
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

class _Opened {
  _Opened(this.media, this.play);

  final Media media;
  final bool play;
}

class _DelayedHttp implements HttpClient {
  final requested = <Uri>[];
  final entered = Completer<void>();
  final response = Completer<HttpClientResponse>();
  final headers = _Headers();

  @override
  Duration? connectionTimeout;

  @override
  set findProxy(String Function(Uri)? callback) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    return _Request(this);
  }

  void complete(String contentType, [String body = '']) {
    response.complete(_Response(contentType, body));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected HTTP client call: ${invocation.memberName}',
  );
}

class _Request implements HttpClientRequest {
  _Request(this.http);

  final _DelayedHttp http;

  @override
  HttpHeaders get headers => http.headers;

  @override
  Future<HttpClientResponse> close() {
    http.entered.complete();
    return http.response.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected HTTP request call: ${invocation.memberName}',
  );
}

class _Headers implements HttpHeaders {
  _Headers([this.contentTypeValue]);

  final String? contentTypeValue;

  @override
  String? value(String name) =>
      name == HttpHeaders.contentTypeHeader ? contentTypeValue : null;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected HTTP headers call: ${invocation.memberName}',
  );
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(String contentType, String body)
    : headers = _Headers(contentType),
      bytes = utf8.encode(body);

  final List<int> bytes;

  @override
  final HttpHeaders headers;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => bytes.length;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected HTTP response call: ${invocation.memberName}',
  );
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
  expect(ready(), isTrue, reason: 'The production playback stage must finish');
}

Future<void> _mount(WidgetTester tester, List<_Opened> opened) async {
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
        title: '候选切换',
        episodes: [Episode(id: 'ep1', title: '第1集')],
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: '第1集',
      ),
    ),
  );
  addTearDown(() async {
    if (find.byType(PlayerPage).evaluate().isNotEmpty) {
      await _finish(tester);
    }
  });
  await tester.pump();
  expect(debugPlayerSetStreamsForProbe([_newStream]), isTrue);
  expect(debugPlayerClearErrorForProbe(), isTrue);
  expect(
    debugPlayerSetOpenForProbe((media, {required play}) async {
      opened.add(_Opened(media, play));
    }),
    isTrue,
  );
  final native = tester.widget<Video>(find.byType(Video)).controller.player
      .platform as NativePlayer;
  await _waitFor(
    tester,
    () => native.videoControllerCompleter.isCompleted,
  );
  await tester.pump();
}

Future<void> _finish(WidgetTester tester) async {
  final native = tester.widget<Video>(find.byType(Video)).controller.player
      .platform as NativePlayer;
  final handle = _createdHandles.single;
  debugPlayerSetOpenForProbe(null);
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
  // NativePlayer schedules mpv_terminate_destroy five seconds after disposal.
  await tester.pump(const Duration(seconds: 6));
  await tester.pump(const Duration(seconds: 1));
  expect(tester.takeException(), isNull);
}

Future<bool> _startOld(_DelayedHttp http) => HttpOverrides.runZoned(
  () => debugPlayerStartPlaybackForProbe(_oldUrl),
  createHttpClient: (_) => http,
);

void _pickNew(WidgetTester tester) {
  final bar = tester.widget<PlayerBottomBar>(find.byType(PlayerBottomBar));
  expect(bar.onPickQuality, isNotNull);
  bar.onPickQuality!(_newStream.url);
}

Future<void> _finishOld(WidgetTester tester, Future<bool> old) async {
  bool? result;
  old.then((value) => result = value);
  await _waitFor(tester, () => result != null);
  expect(result, isTrue);
  await tester.pump();
}

void _releaseOldAtTearDown(
  WidgetTester tester,
  _DelayedHttp http,
  Future<bool> old,
) {
  addTearDown(() async {
    if (!http.response.isCompleted) http.complete('video/mp4');
    await _finishOld(tester, old);
  });
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(dll.existsSync(), isTrue);
    MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() {
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
      throw SourinCoreException('隔离测试无数据', 'other');
    };
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_videoChannel, null);
    debugPlayerSetOpenForProbe(null);
    debugPlayerSetHwdecReadForProbe(null);
    debugPlayerSkipOpenForProbe = false;
    Device.overrideKind(null);
    RemoteBridge.instance.stop();
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
    UiPrefs.debugResetForTest();
  });

  testWidgets('a late old precheck cannot reopen an earlier candidate', (
    tester,
  ) async {
    final opened = <_Opened>[];
    final http = _DelayedHttp();
    await _mount(tester, opened);
    final session = debugPlayerSessionGenForProbe();
    final old = _startOld(http);
    _releaseOldAtTearDown(tester, http, old);
    await _waitFor(tester, () => http.entered.isCompleted);
    expect(http.requested.map((uri) => uri.toString()), [_oldUrl]);
    expect(opened, isEmpty);

    _pickNew(tester);
    await _waitFor(tester, () => opened.isNotEmpty);
    expect(opened.map((call) => call.media.uri), [_newStream.url]);
    expect(opened.single.media.httpHeaders, {'X-Candidate': 'new'});
    expect(opened.single.play, isTrue);
    http.complete('video/mp4');
    await _finishOld(tester, old);

    expect(
      opened.map((call) => call.media.uri),
      [_newStream.url],
      reason: 'The old candidate must not reach the native open boundary',
    );
    expect(debugPlayerSessionGenForProbe(), session);
    expect(debugPlayerEpisodeIndexForProbe(), 0);
    await _finish(tester);
  });

  testWidgets('a late old precheck error cannot replace the new candidate', (
    tester,
  ) async {
    final opened = <_Opened>[];
    final http = _DelayedHttp();
    await _mount(tester, opened);
    final old = _startOld(http);
    _releaseOldAtTearDown(tester, http, old);
    await _waitFor(tester, () => http.entered.isCompleted);
    _pickNew(tester);
    await _waitFor(tester, () => opened.isNotEmpty);
    expect(debugPlayerErrorForProbe(), isNull);
    http.complete('text/html', '<html>Not a media stream</html>');
    await _finishOld(tester, old);

    expect(opened.map((call) => call.media.uri), [_newStream.url]);
    expect(debugPlayerErrorForProbe(), isNull);
    await _finish(tester);
  });

  testWidgets('a completed candidate still opens before a later selection', (
    tester,
  ) async {
    final opened = <_Opened>[];
    final http = _DelayedHttp();
    await _mount(tester, opened);
    final old = _startOld(http);
    _releaseOldAtTearDown(tester, http, old);
    await _waitFor(tester, () => http.entered.isCompleted);
    http.complete('video/mp4');
    await _finishOld(tester, old);
    expect(opened.map((call) => call.media.uri), [_oldUrl]);

    _pickNew(tester);
    await _waitFor(tester, () => opened.length == 2);
    expect(opened.map((call) => call.media.uri), [_oldUrl, _newStream.url]);
    expect(debugPlayerErrorForProbe(), isNull);
    await _finish(tester);
  });

  group('hwdec lifecycle', () {
    testWidgets('a late ready property cannot read again after unmount', (
      tester,
    ) async {
      final reads = <String>[];
      final pending = Completer<String>();
      await _mount(tester, <_Opened>[]);
      expect(
        debugPlayerSetHwdecReadForProbe((name) {
          reads.add(name);
          return name == 'video-params'
              ? pending.future
              : Future<String>.value('no');
        }),
        isTrue,
      );
      final report = debugPlayerReportHwdecForProbe();
      addTearDown(() async {
        if (!pending.isCompleted) pending.complete('ready');
        await _finishOld(tester, report);
      });
      await _waitFor(tester, () => reads.isNotEmpty);
      await _finish(tester);
      pending.complete('ready');
      await _finishOld(tester, report);

      expect(
        reads,
        ['video-params'],
        reason: 'A property completion after unmount must end the observer',
      );
    });

    testWidgets('a late empty property cannot schedule another read', (
      tester,
    ) async {
      final reads = <String>[];
      final pending = Completer<String>();
      var allowCleanup = false;
      var reportCompleted = false;
      await _mount(tester, <_Opened>[]);
      expect(
        debugPlayerSetHwdecReadForProbe((name) {
          reads.add(name);
          if (name == 'video-params' && reads.length == 1) {
            return pending.future;
          }
          return Future<String>.value(allowCleanup ? 'ready' : '');
        }),
        isTrue,
      );
      final report = debugPlayerReportHwdecForProbe();
      report.then((_) => reportCompleted = true);
      addTearDown(() async {
        allowCleanup = true;
        if (!pending.isCompleted) pending.complete('ready');
        await tester.pump(const Duration(milliseconds: 250));
        await _finishOld(tester, report);
      });
      await _waitFor(tester, () => reads.isNotEmpty);
      await _finish(tester);
      pending.complete('');
      await tester.pump();
      // This is the production observer's exact retry interval, not an
      // extended timeout or a substitute for waiting on its real future.
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        reads,
        ['video-params'],
        reason: 'An exited page must not start another native property read',
      );
      expect(reportCompleted, isTrue);
      await _finishOld(tester, report);
    });

    testWidgets('a mounted ready observer reads the final hardware property', (
      tester,
    ) async {
      final reads = <String>[];
      await _mount(tester, <_Opened>[]);
      expect(
        debugPlayerSetHwdecReadForProbe((name) async {
          reads.add(name);
          return name == 'video-params' ? 'ready' : 'no';
        }),
        isTrue,
      );
      await _finishOld(tester, debugPlayerReportHwdecForProbe());

      expect(reads, ['video-params', 'hwdec-current']);
      await _finish(tester);
    });
  });
}
