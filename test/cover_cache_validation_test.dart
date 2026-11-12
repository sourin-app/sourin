import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/cache_page.dart';
import 'valid_cover_fixture.dart';

class _OnlyFixtureHttp extends HttpOverrides {
  _OnlyFixtureHttp(this.port);
  final int port;
  int denied = 0;
  final clients = <HttpClient>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    clients.add(client);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (proxyHost != null || uri.host != '127.0.0.1' || uri.port != port) {
        denied++;
        return Future<ConnectionTask<Socket>>.error(
          StateError('Only the task-owned loopback fixture is allowed'),
        );
      }
      return Socket.startConnect(InternetAddress.loopbackIPv4, port);
    };
    return client;
  }
}

Future<({int width, int height})> _decoded(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      return (width: frame.image.width, height: frame.image.height);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late _OnlyFixtureHttp http;
  HttpOverrides? previous;
  late Directory sandbox;
  late Uint8List transparent;
  final png = base64Decode(validCoverPngBase64);
  final html = utf8.encode('<html><body>Image temporarily unavailable</body></html>');
  final payloads = <String, List<int>>{};
  final calls = <String, int>{};
  final pending = <Future<void>>[];
  final fixtureErrors = <Object>[];
  final events = <String>[];
  final eventClock = Stopwatch();
  void event(String message) => events.add('${eventClock.elapsedMilliseconds}ms $message');
  Future<void> serve(HttpRequest request) async {
    try {
      final path = request.uri.path;
      event('request $path');
      calls[path] = (calls[path] ?? 0) + 1;
      request.response.persistentConnection = false;
      // Intentionally misleading in both directions: headers are no oracle.
      request.response.headers.contentType = path.contains('valid')
          ? ContentType.html : ContentType('image', 'png');
      request.response.add(payloads[path]!);
      await request.response.close();
      event('response closed $path');
    } catch (error) {
      fixtureErrors.add(error);
    }
  }
  String url(String path) => 'http://127.0.0.1:${server.port}$path';
  Directory dir(String label) => Directory('${sandbox.path}/$label')..createSync();
  Future<void> noPublishedFiles(Directory work) async {
    expect(await work.list().toList(), isEmpty,
      reason: 'Rejected bytes must not publish a cover or a temporary file');
  }
  setUpAll(() async {
    sandbox = await Directory.systemTemp.createTemp('sourin-cover-validation-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    previous = HttpOverrides.current;
    http = _OnlyFixtureHttp(server.port);
    HttpOverrides.global = http;
    server.listen((request) {
      final future = serve(request);
      pending.add(future);
      unawaited(future.whenComplete(() => pending.remove(future)));
    });
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);
    try {
      transparent = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
    expect(await _decoded(png), (width: 32, height: 48));
    expect(await _decoded(validCoverFixture(4096)), (width: 32, height: 48));
    expect(await _decoded(validCoverFixture(7 * 1024 * 1024)), (width: 32, height: 48));
  });
  setUp(() {
    events.clear();
    eventClock.reset();
    eventClock.start();
    UiPrefs.debugResetForTest(<String, String>{});
    calls.clear();
    payloads.clear();
    debugClearCacheMetaMemo();
    debugMetaFetchers = (
      history: () async => const <HistoryEntry>[],
      favorites: () async => const <Favorite>[],
    );
  });
  tearDown(() {
    CachePage.debugScanRootOverride = null;
    debugMetaFetchers = null;
    debugClearCacheMetaMemo();
    expect(http.denied, 0);
    expect(fixtureErrors, isEmpty);
  });
  tearDownAll(() async {
    await Future.wait(List<Future<void>>.of(pending)).timeout(const Duration(seconds: 8));
    for (final client in http.clients) { client.close(force: true); }
    HttpOverrides.global = previous;
    await server.close(force: true);
  });
  test('200 HTML is rejected before publishing any local cover', () async {
    final work = dir('html');
    payloads['/html.png'] = html;
    final got = await DownloadQueue.cacheCoverImage(url('/html.png'), work.path);
    expect(calls['/html.png'], 1);
    expect(got, isNull);
    await noPublishedFiles(work);
  });
  test('200 HTML cannot overwrite a previously decoded offline cover', () async {
    final work = dir('existing');
    payloads['/replace.png'] = png;
    final original = await DownloadQueue.cacheCoverImage(url('/replace.png'), work.path);
    expect(original, '_sourin-cover.png');
    final file = File('${work.path}/$original');
    expect(await _decoded(await file.readAsBytes()), (width: 32, height: 48));
    payloads['/replace.png'] = html;
    final rejected = await DownloadQueue.cacheCoverImage(url('/replace.png'), work.path);
    expect(calls['/replace.png'], 2);
    final after = await file.readAsBytes();
    expect(listEquals(after, png), isTrue,
      reason: 'The original decoded image bytes must survive the failed refresh');
    expect(await _decoded(after), (width: 32, height: 48));
    expect(rejected, isNull);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });
  test('a valid PNG is saved byte-for-byte despite a misleading HTML header', () async {
    final work = dir('valid');
    payloads['/valid.png'] = png;
    final got = await DownloadQueue.cacheCoverImage(url('/valid.png'), work.path);
    expect(got, '_sourin-cover.png');
    final file = File('${work.path}/$got');
    final saved = await file.readAsBytes();
    expect(listEquals(saved, png), isTrue);
    expect(await _decoded(saved), (width: 32, height: 48));
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });
  test('a truncated encoded PNG is rejected before publication', () async {
    final work = dir('truncated');
    payloads['/truncated.png'] = png.sublist(0, 32);
    expect(await DownloadQueue.cacheCoverImage(url('/truncated.png'), work.path), isNull);
    await noPublishedFiles(work);
  });
  test('a genuinely decoded fully transparent 1x1 sentinel is rejected', () async {
    final work = dir('sentinel');
    payloads['/sentinel.png'] = transparent;
    expect(await _decoded(transparent), (width: 1, height: 1));
    expect(await DownloadQueue.cacheCoverImage(url('/sentinel.png'), work.path), isNull);
    await noPublishedFiles(work);
  });
  test('cancelled queue workers drain before fixture reset', () async {
    final root = dir('queue-cancel');
    DownloadQueue.debugReset();
    DownloadDir.debugReset();
    DownloadDir.setConfiguredDir(root.path);
    final resolving = Completer<void>();
    final release = Completer<void>();
    DownloadQueue.debugSetResolver((_) async {
      resolving.complete();
      await release.future;
      return StreamCandidate(url: url('/cancel.m3u8'));
    });
    payloads['/cancel.m3u8'] = utf8.encode('#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\ncancel.ts\n#EXT-X-ENDLIST\n');
    const id = 'fixture:cancel:episode';
    try {
      expect(DownloadQueue.enqueue(const DownloadTask(
        id: id, title: 'Owned cancel', episodeTitle: 'Episode',
        provider: 'fixture', mediaId: 'cancel', episodeId: 'episode',
        sourceCode: 'fixture', fileName: 'episode',
      )), isTrue);
      await resolving.future.timeout(const Duration(seconds: 8));
      DownloadQueue.cancel(id);
      expect(DownloadQueue.tasks.value.single.state, DownloadState.failed);
      expect(DownloadQueue.debugInFlightCount, 1);
      var drained = false;
      final idle = DownloadQueue.debugWaitForIdle().then((_) { drained = true; });
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse, reason: 'Cancellation is not worker completion');
      release.complete();
      await idle.timeout(const Duration(seconds: 8));
      expect(DownloadQueue.debugInFlightCount, 0);
      expect(DownloadQueue.tasks.value.single.state, DownloadState.failed);
      expect(calls['/cancel.m3u8'], 1);
      expect(calls['/cancel.ts'], isNull);
      expect(await root.list(recursive: true).where((entry) => entry is File).toList(), isEmpty);
      debugPrint('QUEUE_DRAIN cancellationObservedBeforeExit=true workers=0 files=0');
    } finally {
      if (!release.isCompleted) release.complete();
      DownloadQueue.cancel(id);
      await DownloadQueue.debugWaitForIdle().timeout(const Duration(seconds: 45));
      DownloadQueue.debugReset();
      DownloadQueue.debugSetResolver(null);
      DownloadDir.debugReset();
    }
  });
  test('real second-episode finish retains a decoded offline cover reference', () async {
    final root = dir('queue-refresh');
    DownloadQueue.debugReset();
    DownloadDir.debugReset();
    DownloadDir.setConfiguredDir(root.path);
    DownloadQueue.debugSetResolver((task) async {
      event('resolve ${task.id}');
      return StreamCandidate(url: url('/owned.m3u8'));
    });
    payloads['/owned.m3u8'] = utf8.encode('#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n');
    payloads['/segment.ts'] = List<int>.filled(256, 0x47);
    DownloadTask task(int episode) => DownloadTask(
      id: 'fixture:owned:episode$episode', title: 'Owned refresh',
      episodeTitle: 'Episode $episode', provider: 'fixture', mediaId: 'owned',
      episodeId: 'episode$episode', sourceCode: 'fixture', fileName: 'episode$episode',
      cover: url('/refresh.png'),
    );
    Future<void> download(int episode) async {
      event('enqueue episode$episode');
      expect(DownloadQueue.enqueue(task(episode)), isTrue);
      final watch = Stopwatch()..start();
      while (DownloadQueue.tasks.value.any((task) => task.state == DownloadState.queued ||
          task.state == DownloadState.running) && watch.elapsed < const Duration(seconds: 8)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final current = DownloadQueue.tasks.value.singleWhere((value) => value.id == task(episode).id);
      event('deadline observed episode$episode ${current.state} ${current.done}/${current.total}');
      expect(current.state, DownloadState.done, reason: events.join('\n'));
    }
    void observeQueue() {
      for (final task in DownloadQueue.tasks.value) {
        event('queue ${task.id} ${task.state} ${task.done}/${task.total}');
      }
    }
    DownloadQueue.tasks.addListener(observeQueue);
    try {
      payloads['/refresh.png'] = png;
      await download(1);
      final work = await DownloadDir.forWork('Owned refresh');
      final sidecar = File('$work/_sourin-cache.json');
      final first = jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      expect(first['coverFile'], '_sourin-cover.png');
      final original = File('$work${Platform.pathSeparator}${first['coverFile']}');
      expect(await _decoded(await original.readAsBytes()), (width: 32, height: 48));
      payloads['/refresh.png'] = html;
      await download(2);
      final second = jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      expect(second['episodeId'], 'episode2', reason: 'The new episode metadata must still finish');
      expect(second['coverFile'], first['coverFile'], reason: 'Failed refresh must retain the valid offline reference');
      expect(listEquals(await original.readAsBytes(), png), isTrue);
      final scanned = await scanCacheWorks(root.path);
      expect(scanned.single.localCoverPath, original.path);
      expect(await _decoded(await File(scanned.single.localCoverPath!).readAsBytes()), (width: 32, height: 48));
      expect(calls['/owned.m3u8'], 2);
      expect(calls['/segment.ts'], 2);
      expect(calls['/refresh.png'], 2);
      expect(await Directory(work).list().where((entry) => entry.path.endsWith('.tmp')).toList(), isEmpty);
      debugPrint('OFFLINE_REFERENCE realHlsDone=2 metadataEpisode=episode2 decoded=32x48');
    } finally {
      for (final task in List<DownloadTask>.of(DownloadQueue.tasks.value)) {
        DownloadQueue.cancel(task.id);
      }
      await DownloadQueue.debugWaitForIdle().timeout(const Duration(seconds: 45));
      expect(DownloadQueue.debugInFlightCount, 0);
      event('workers drained');
      debugPrint('OFFLINE_REFERENCE_EVENTS ${events.join(' | ')}');
      DownloadQueue.tasks.removeListener(observeQueue);
      DownloadQueue.debugReset();
      DownloadQueue.debugSetResolver(null);
      DownloadDir.debugReset();
    }
  });
  testWidgets('the real scanned cache card still decodes its network fallback', (tester) async {
    final root = dir('fallback');
    final work = Directory('${root.path}/Owned cache')..createSync();
    payloads['/fallback-error.png'] = html;
    payloads['/valid-fallback.png'] = png;
    final cached = await tester.runAsync(() => DownloadQueue.cacheCoverImage(
      url('/fallback-error.png'), work.path,
    ));
    File('${work.path}/episode.mp4').writeAsBytesSync(<int>[0]);
    File('${work.path}/_sourin-cache.json').writeAsStringSync(jsonEncode({
      'provider': 'fixture', 'id': 'owned', 'title': 'Owned cache',
      'episodeId': 'episode', 'cover': url('/valid-fallback.png'), 'coverFile': cached,
    }));
    final works = await tester.runAsync(() => scanCacheWorks(root.path));
    expect(works, hasLength(1));
    expect(works!.single.cover, url('/valid-fallback.png'));
    CachePage.debugScanRootOverride = root.path;
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: const Scaffold(body: CachePage()),
    ));
    final watch = Stopwatch()..start();
    bool decoded() => tester.renderObjectList<RenderImage>(find.byType(RawImage))
      .any((render) => render.image?.width == 32 && render.image?.height == 48);
    while (!decoded() && watch.elapsed < const Duration(seconds: 8)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(decoded(), isTrue, reason: 'A real RenderImage must contain the fixture poster frame');
    expect(calls['/valid-fallback.png'], 1);
    debugPrint('FALLBACK realDecoded=32x48 localCoverPresent=${works.single.localCoverPath != null}');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
