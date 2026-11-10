import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_log.dart';
import 'package:sourin_spike/core/app_update/client.dart';
import 'package:sourin_spike/core/app_update/route.dart';
import 'package:sourin_spike/core/ffi.dart';

void main() {
  setUp(() {
    AppLog.debugClear();
    AppLog.debugSetEnabled(false);
  });

  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    AppLog.debugClear();
    AppLog.debugSetEnabled(true);
  });

  test(
    'each text request obtains a fresh core stream and forwards headers',
    () async {
      final upstream = Uri.parse('https://updates.invalid/releases/latest');
      final requests = <Map<String, dynamic>>[];
      final locals = [
        Uri.parse('http://127.0.0.1:45678/fixture/first'),
        Uri.parse('http://127.0.0.1:45678/fixture/second'),
      ];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        expect(command, 'global_proxy_open_download');
        requests.add(Map<String, dynamic>.from(args!));
        return {'url': locals[requests.length - 1].toString()};
      };
      final network = _FixtureNetwork(
        (uri) => _FixtureResponse([
          utf8.encode(uri == locals.first ? '第一份更新' : '第二份更新'),
        ]),
      );
      final client = UpdateHttp(
        const UpdateRouteConfig(
          route: UpdateRoute.proxy,
          proxyHost: 'legacy-proxy.invalid',
          proxyPort: 7890,
        ),
      );
      await HttpOverrides.runZoned(() async {
        expect(
          await client.getText(upstream, headers: {'x-fixture': 'first'}),
          '第一份更新',
        );
        expect(
          await client.getText(upstream, headers: {'x-fixture': 'second'}),
          '第二份更新',
        );
      }, createHttpClient: network.createHttpClient);

      expect(requests, [
        {
          'url': upstream.toString(),
          'headers': {'x-fixture': 'first'},
        },
        {
          'url': upstream.toString(),
          'headers': {'x-fixture': 'second'},
        },
      ]);
      expect(network.urls, locals);
      expect(network.clients, hasLength(2));
      for (final client in network.clients) {
        expect(client.proxyFor(client.urls.single), 'DIRECT');
        expect(client.connectionTimeout, const Duration(seconds: 20));
        expect(client.autoUncompress, isTrue);
        expect(client.closeCalls, [false]);
      }
    },
  );

  test(
    'each download obtains a fresh core stream and finishes its file',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'sourin_update_stream_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final dest = File('${temp.path}/update.zip');
      final upstream = Uri.parse('https://updates.invalid/update.zip');
      final requests = <Map<String, dynamic>>[];
      final locals = [
        Uri.parse('http://127.0.0.1:45678/fixture/download-first'),
        Uri.parse('http://127.0.0.1:45678/fixture/download-second'),
      ];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        expect(command, 'global_proxy_open_download');
        requests.add(Map<String, dynamic>.from(args!));
        return {'url': locals[requests.length - 1].toString()};
      };
      final network = _FixtureNetwork(
        (uri) => _FixtureResponse(
          uri == locals.first
              ? [
                  [1, 2],
                  [3, 4],
                ]
              : [
                  [5],
                  [6, 7],
                ],
        ),
      );
      final client = UpdateHttp(const UpdateRouteConfig());
      final progress = <(int, int)>[];
      await HttpOverrides.runZoned(() async {
        expect(
          await client.download(
            upstream,
            dest,
            onProgress: (done, total) => progress.add((done, total)),
          ),
          same(dest),
        );
        expect(await dest.readAsBytes(), [1, 2, 3, 4]);
        expect(progress.last, (4, 4));
        expect(await File('${dest.path}.part').exists(), isFalse);
        progress.clear();
        expect(
          await client.download(
            upstream,
            dest,
            onProgress: (done, total) => progress.add((done, total)),
          ),
          same(dest),
        );
        expect(await dest.readAsBytes(), [5, 6, 7]);
        expect(progress.last, (3, 3));
        expect(await File('${dest.path}.part').exists(), isFalse);
      }, createHttpClient: network.createHttpClient);

      expect(requests, [
        {'url': upstream.toString(), 'headers': <String, String>{}},
        {'url': upstream.toString(), 'headers': <String, String>{}},
      ]);
      expect(network.urls, locals);
      expect(network.clients, hasLength(2));
      for (final client in network.clients) {
        expect(client.closeCalls, [false]);
      }
    },
  );

  test('core proxy failures never fall back to a direct HTTP client', () async {
    final temp = await Directory.systemTemp.createTemp(
      'sourin_update_failure_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final dest = File('${temp.path}/update.zip');
    final upstream = Uri.parse('https://updates.invalid/update.zip');
    final failure = StateError('Synthetic configured proxy unavailable');
    final requests = <Map<String, dynamic>>[];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      expect(command, 'global_proxy_open_download');
      requests.add(Map<String, dynamic>.from(args!));
      throw failure;
    };
    var httpClientsCreated = 0;
    final client = UpdateHttp(
      const UpdateRouteConfig(
        route: UpdateRoute.proxy,
        proxyHost: 'legacy-proxy.invalid',
        proxyPort: 7890,
      ),
    );
    final expectedFailure = throwsA(
      isA<UpdateNetworkException>().having(
        (error) => error.cause,
        'cause',
        same(failure),
      ),
    );
    await HttpOverrides.runZoned(
      () async {
        await expectLater(client.getText(upstream), expectedFailure);
        await expectLater(client.download(upstream, dest), expectedFailure);
      },
      createHttpClient: (_) {
        httpClientsCreated++;
        throw StateError('A failed core request must not open a direct client');
      },
    );

    expect(requests, [
      {'url': upstream.toString(), 'headers': <String, String>{}},
      {'url': upstream.toString(), 'headers': <String, String>{}},
    ]);
    expect(httpClientsCreated, 0);
    expect(await dest.exists(), isFalse);
    expect(await File('${dest.path}.part').exists(), isFalse);
  });

  test(
    'mirror retries for text and downloads still pass through the core',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'sourin_update_mirror_',
      );
      addTearDown(() => temp.delete(recursive: true));
      const config = UpdateRouteConfig(
        route: UpdateRoute.mirror,
        customMirror: 'https://mirror.invalid/',
      );
      final upstream = Uri.parse('https://updates.invalid/update.zip');
      final mirror = Uri.parse('${config.mirrorPrefix}$upstream');
      final local = Uri.parse('http://127.0.0.1:45678/fixture/origin');
      final requests = <Map<String, dynamic>>[];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        expect(command, 'global_proxy_open_download');
        requests.add(Map<String, dynamic>.from(args!));
        if (args['url'] == mirror.toString()) {
          throw StateError('Synthetic mirror unavailable');
        }
        return {'url': local.toString()};
      };
      final network = _FixtureNetwork(
        (_) => _FixtureResponse([utf8.encode('fixture')]),
      );
      final client = UpdateHttp(config);
      final dest = File('${temp.path}/update.zip');
      await HttpOverrides.runZoned(() async {
        expect(await client.getText(upstream), 'fixture');
        await client.download(mirror, dest);
        expect(await dest.readAsString(), 'fixture');
      }, createHttpClient: network.createHttpClient);

      expect(requests.map((request) => request['url']), [
        mirror.toString(),
        upstream.toString(),
        mirror.toString(),
        upstream.toString(),
      ]);
      expect(network.urls, [local, local]);
      expect(network.clients, hasLength(2));
      for (final client in network.clients) {
        expect(client.closeCalls, [false]);
      }
    },
  );
}

class _FixtureNetwork {
  _FixtureNetwork(this.respond);

  final _FixtureResponse Function(Uri) respond;
  final clients = <_FixtureClient>[];

  List<Uri> get urls => clients.expand((client) => client.urls).toList();

  HttpClient createHttpClient(SecurityContext? context) {
    final client = _FixtureClient(respond);
    clients.add(client);
    return client;
  }
}

class _FixtureClient implements HttpClient {
  _FixtureClient(this.respond);

  final _FixtureResponse Function(Uri) respond;
  final urls = <Uri>[];
  final closeCalls = <bool>[];
  String Function(Uri)? _findProxy;

  @override
  Duration? connectionTimeout;

  @override
  bool autoUncompress = false;

  @override
  set findProxy(String Function(Uri)? callback) => _findProxy = callback;

  String? proxyFor(Uri uri) => _findProxy?.call(uri);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    return _FixtureRequest(respond(url));
  }

  @override
  void close({bool force = false}) => closeCalls.add(force);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected HTTP client call: ${invocation.memberName}');
}

class _FixtureRequest implements HttpClientRequest {
  _FixtureRequest(this.response);

  final HttpClientResponse response;

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected HTTP request call: ${invocation.memberName}',
  );
}

class _FixtureResponse extends Stream<List<int>> implements HttpClientResponse {
  _FixtureResponse(this.chunks);

  final List<List<int>> chunks;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength =>
      chunks.fold(0, (length, chunk) => length + chunk.length);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable(chunks).listen(
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
