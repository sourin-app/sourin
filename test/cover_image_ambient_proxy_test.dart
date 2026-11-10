// Environment-policy fixture using the SDK's real proxy parser. No process
// environment is changed and no external host is contacted. The production
// client's findProxy remains untouched; only the parser's environment input is
// supplied through the public HttpOverrides boundary after the test loads.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/cover_image.dart';

const _posterPng =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAwCAIAAAD/zu84AAAAYklEQVR4nGNUDp3LQEvARFPTGUYtIAKMxgFBMBpEAx9ELLgkdgbOItUs9/VpmIKjkUwQjAYRQTAaRATBaBARBKNBRBCMBhFBMBpEBMFoEI2AIGIc7cYO/0hmGrWAEKB5EAEASO0FiyW/0WUAAAAASUVORK5CYII=';
const _remoteHost = 'cover-fixture.invalid';
const _lookalikeHost = '127.0.0.1.example.invalid';
const _errorKey = ValueKey('cover-proxy-fixture-error');

bool _localHost(String host) => host == '127.0.0.1' || host == 'localhost';

class _ObservedRealHttp extends HttpOverrides {
  _ObservedRealHttp(this.originPort, this.trapPort);

  final int originPort;
  final int trapPort;
  final clients = <HttpClient>[];
  int rejectedExternalConnections = 0;

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      super.findProxyFromEnvironment(url, {
        'http_proxy': 'http://127.0.0.1:$trapPort',
        'https_proxy': 'http://127.0.0.1:$trapPort',
        'no_proxy': '',
      });

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    clients.add(client);
    // Keep findProxy untouched. Observe the destination selected by the real
    // client and permit sockets only to this fixture's two loopback servers.
    // A mistaken DIRECT route for a remote control fails immediately, without
    // DNS or an external connection, rather than waiting for a network timeout.
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final host = proxyHost ?? uri.host;
      final port = proxyPort ?? uri.port;
      if (!_localHost(host) ||
          (port != originPort && port != trapPort)) {
        rejectedExternalConnections++;
        return Future<ConnectionTask<Socket>>.error(
          StateError('Cover fixture rejected a nonlocal socket destination'),
        );
      }
      // Both wrapper names use the same real IPv4 origin. This replaces only
      // localhost name resolution, not HTTP proxy policy or request identity.
      return Socket.startConnect(InternetAddress.loopbackIPv4, port);
    };
    return client;
  }

  void close() {
    for (final client in clients) {
      client.close(force: true);
    }
  }
}

class _NetworkFixture {
  late HttpServer origin;
  late HttpServer trap;
  late _ObservedRealHttp http;
  final requests = <({String boundary, String host, String path})>[];
  final png = base64Decode(_posterPng);
  HttpOverrides? previous;

  Future<void> start() async {
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    trap = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      request.response.persistentConnection = false;
      requests.add((boundary: 'origin', host: request.requestedUri.host,
          path: request.uri.path));
      if (request.uri.path == '/wrapper-redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader,
            'http://$_remoteHost/redirected.png');
      } else if (request.uri.path.startsWith('/s/')) {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    trap.listen((request) async {
      request.response.persistentConnection = false;
      final host = request.requestedUri.host;
      requests.add((boundary: 'trap', host: host, path: request.uri.path));
      if (host == _remoteHost || host == _lookalikeHost) {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
      } else {
        request.response.headers.contentType = ContentType('text', 'html');
        request.response.write('<html><body></body></html>');
      }
      await request.response.close();
    });
    previous = HttpOverrides.current;
    http = _ObservedRealHttp(origin.port, trap.port);
    HttpOverrides.global = http;
  }

  void reset() => requests.clear();

  Future<void> close() async {
    http.close();
    HttpOverrides.global = previous;
    await origin.close(force: true);
    await trap.close(force: true);
  }

  Map<String, Object?> observed(Object? error, bool decoded) => {
    'origin': requests.where((r) => r.boundary == 'origin').length,
    'trapLoopback': requests.where((r) =>
        r.boundary == 'trap' && _localHost(r.host)).length,
    'trapNonloopback': requests.where((r) =>
        r.boundary == 'trap' && !_localHost(r.host)).length,
    'rejectedExternalConnections': http.rejectedExternalConnections,
    'decoded': decoded,
    'errorType': error?.runtimeType.toString(),
  };
}

bool _decodedPoster(WidgetTester tester) => tester
    .renderObjectList<RenderImage>(find.byType(RawImage))
    .any((image) => image.image?.width == 32 && image.image?.height == 48);

Future<Object?> _showCover(WidgetTester tester, String url) async {
  Object? error;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => SizedBox(
            width: 32,
            height: 48,
            child: coverImage(
              context,
              url: url,
              layoutWidth: 32,
              errorBuilder: (_, value, __) {
                error = value;
                return const Text('Fixture image failed', key: _errorKey);
              },
            ),
          ),
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (error != null || _decodedPoster(tester)) return error;
  }
  fail('The actual cover load did not reach an error or decoded image');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final network = _NetworkFixture();
  setUpAll(() async {
    await network.start();
    // Qualify the actual origin bytes independently of coverImage, then clear
    // those qualification requests before the behavioral cases start counting.
    final direct = HttpClient()..findProxy = (_) => 'DIRECT';
    final request = await direct.getUrl(
      Uri.parse('http://127.0.0.1:${network.origin.port}/s/qualification'),
    );
    final response = await request.close();
    final received = await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    expect(response.statusCode, HttpStatus.ok);
    expect(received, network.png);
    direct.close(force: true);
  });
  tearDownAll(network.close);
  setUp(() {
    network.reset();
    network.http.rejectedExternalConnections = 0;
  });

  for (final host in ['127.0.0.1', 'localhost']) {
    testWidgets('cover wrapper $host bypasses ambient image proxy', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final error = await _showCover(tester,
          'http://$host:${network.origin.port}/s/cover-$host');
      expect(network.observed(error, _decodedPoster(tester)), {
        'origin': 1,
        'trapLoopback': 0,
        'trapNonloopback': 0,
        'rejectedExternalConnections': 0,
        'decoded': true,
        'errorType': null,
      }, reason: 'The real wrapper image must decode from its local origin');
      expect(find.byKey(_errorKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final host in [_remoteHost, _lookalikeHost]) {
    testWidgets('nonloopback image $host retains ambient proxy policy', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final error = await _showCover(tester, 'http://$host/control.png');
      expect(network.observed(error, _decodedPoster(tester)), {
        'origin': 0,
        'trapLoopback': 0,
        'trapNonloopback': 1,
        'rejectedExternalConnections': 0,
        'decoded': true,
        'errorType': null,
      }, reason: 'Only strict loopback images may bypass the selected proxy');
      expect(network.requests.single.host, host);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('local image redirect resumes proxy policy for its remote target',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final error = await _showCover(tester,
        'http://127.0.0.1:${network.origin.port}/wrapper-redirect');
    expect(network.observed(error, _decodedPoster(tester)), {
      'origin': 1,
      'trapLoopback': 0,
      'trapNonloopback': 1,
      'rejectedExternalConnections': 0,
      'decoded': true,
      'errorType': null,
    }, reason: 'A local bypass must not make a redirected remote image direct');
    expect(network.requests.map((request) => request.path),
        ['/wrapper-redirect', '/redirected.png']);
    expect(network.requests.last.host, _remoteHost);
    expect(tester.takeException(), isNull);
  });
}
