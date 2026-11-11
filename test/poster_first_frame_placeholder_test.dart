// Frozen payload for both ordinary baseline and candidate qualification trees.
// Every image byte comes from this loopback fixture; no image provider, loading
// state, decoded frame, save path, source profile or production widget is mocked.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

const _posterPng =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAwCAIAAAD/zu84AAAAYklEQVR4nGNUDp3LQEvARFPTGUYtIAKMxgFBMBpEAx9ELLgkdgbOItUs9/VpmIKjkUwQjAYRQTAaRATBaBARBKNBRBCMBhFBMBpEBMFoEI2AIGIc7cYO/0hmGrWAEKB5EAEASO0FiyW/0WUAAAAASUVORK5CYII=';
const _cardKey = ValueKey('owned-poster-first-frame-card');

class _LoopbackOnlyHttp extends HttpOverrides {
  _LoopbackOnlyHttp(this.port);
  final int port;
  final clients = <HttpClient>[];
  int deniedSockets = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    clients.add(client);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (proxyHost != null || uri.host != '127.0.0.1' || uri.port != port) {
        deniedSockets++;
        return Future<ConnectionTask<Socket>>.error(
          StateError('Nonfixture cover socket refused'),
        );
      }
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

class _Images {
  late HttpServer server;
  late _LoopbackOnlyHttp http;
  HttpOverrides? previous;
  final gates = <String, Completer<void>>{};
  final calls = <String, int>{};
  final failedOnce = <String>{};
  final active = <Future<void>>[];
  final errors = <String>[];
  final png = base64Decode(_posterPng);

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    previous = HttpOverrides.current;
    http = _LoopbackOnlyHttp(server.port);
    HttpOverrides.global = http;
    server.listen((request) {
      final future = serve(request);
      active.add(future);
      unawaited(future.then<void>((_) { active.remove(future); }));
    });
  }

  Future<void> serve(HttpRequest request) async {
    try {
      final path = request.uri.path;
      calls[path] = (calls[path] ?? 0) + 1;
      request.response.persistentConnection = false;
      final gate = gates[path];
      if (gate != null) await gate.future;
      if (failedOnce.contains(path) && calls[path] == 1) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
      }
      await request.response.close();
    } catch (error) {
      errors.add(error.toString());
    }
  }

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  void hold(String path) {
    if (gates.containsKey(path)) throw StateError('Repeated fixture path');
    gates[path] = Completer<void>();
  }

  void release(String path) {
    final gate = gates[path];
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> stop() async {
    for (final path in gates.keys) {
      release(path);
    }
    try {
      await Future.wait(List<Future<void>>.of(active)).timeout(
        const Duration(seconds: 8),
      );
    } finally {
      http.close();
      HttpOverrides.global = previous;
      await server.close(force: true);
    }
  }
}

Finder get _card => find.byKey(_cardKey);
Finder get _placeholder => find.descendant(
  of: _card,
  matching: find.byWidgetPredicate(
    (widget) => widget is Icon && widget.icon == AppIcons.movie_outlined,
  ),
);
Finder get _rawImages => find.descendant(of: _card, matching: find.byType(RawImage));

bool _decoded(WidgetTester tester) => tester
    .renderObjectList<RenderImage>(_rawImages)
    .any((render) => render.image?.width == 32 && render.image?.height == 48);

Future<void> _until(WidgetTester tester, bool Function() ready, String reason,
    {Duration budget = const Duration(seconds: 8)}) async {
  final wall = Stopwatch()..start();
  while (!ready()) {
    if (wall.elapsed >= budget) throw TimeoutException(reason, budget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (wall.elapsed > budget) throw TimeoutException(reason, budget);
}

Future<void> _mount(WidgetTester tester, String? cover) async {
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: Center(child: PosterCard(
      key: _cardKey,
      title: 'Owned pending poster',
      width: 120,
      cover: cover,
    ))),
  ));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final images = _Images();
  setUpAll(images.start);
  tearDownAll(() async {
    await images.stop();
    expect(images.http.deniedSockets, 0);
    expect(images.errors, isEmpty);
  });
  setUp(() => UiPrefs.debugResetForTest(<String, String>{}));
  tearDown(() => UiPrefs.debugResetForTest(<String, String>{}));

  Future<void> cleanup(WidgetTester tester) async {
    for (final path in images.gates.keys) {
      images.release(path);
    }
    await _until(tester, () => images.active.isEmpty, 'Owned image responses did not finish');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(images.http.deniedSockets, 0);
    expect(images.errors, isEmpty);
    expect(tester.takeException(), isNull);
  }

  testWidgets('held cover keeps placeholder until its first decoded frame', (tester) async {
    const path = '/held-initial.png';
    // Create the request signals outside fakeAsync so the actual socket handler
    // and its release future share the real network zone.
    await tester.runAsync(() async => images.hold(path));
    try {
      await _mount(tester, images.url(path));
      await _until(tester, () => images.calls[path] == 1, 'Held cover was not requested');
      await tester.pump();
      expect(_decoded(tester), isFalse);
      expect(_placeholder, findsOneWidget,
          reason: 'Null chunk progress before any response is not decoded artwork');
      expect(find.text('Owned pending poster'), findsOneWidget);
      await tester.runAsync(() async => images.release(path));
      await _until(tester, () => _decoded(tester), 'Released PNG did not decode');
      await tester.pump();
      expect(_placeholder, findsNothing);
      expect(images.calls[path], 1);
      expect(find.text('Owned pending poster'), findsOneWidget);
    } finally {
      await cleanup(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('decoded network and cached covers remove the placeholder', (tester) async {
    const path = '/decoded-control.png';
    try {
      final url = images.url(path);
      await _mount(tester, url);
      await _until(tester, () => _decoded(tester), 'Control PNG did not decode');
      await tester.pump();
      expect(_placeholder, findsNothing);
      expect(images.calls[path], 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _mount(tester, url);
      expect(_decoded(tester), isTrue, reason: 'Cache hit retains its real decoded frame');
      expect(_placeholder, findsNothing);
      expect(images.calls[path], 1, reason: 'Cached artwork should not refetch');
    } finally {
      await cleanup(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('replacement held cover does not inherit decoded cover readiness', (tester) async {
    const oldPath = '/replacement-old.png';
    const newPath = '/replacement-held.png';
    await tester.runAsync(() async => images.hold(newPath));
    try {
      await _mount(tester, images.url(oldPath));
      await _until(tester, () => _decoded(tester), 'Old cover did not decode');
      await tester.pump();
      expect(_placeholder, findsNothing);
      final state = tester.state(_card);
      await _mount(tester, images.url(newPath));
      expect(identical(tester.state(_card), state), isTrue,
          reason: 'The test must reuse the real card state');
      await _until(tester, () => images.calls[newPath] == 1, 'Replacement cover was not requested');
      await tester.pump();
      expect(_decoded(tester), isFalse);
      expect(_placeholder, findsOneWidget);
      await tester.runAsync(() async => images.release(newPath));
      await _until(tester, () => _decoded(tester), 'Replacement PNG did not decode');
      await tester.pump();
      expect(_placeholder, findsNothing);
      expect(images.calls[oldPath], 1);
      expect(images.calls[newPath], 1);
    } finally {
      await cleanup(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('temporary cover failure retains the existing same URL retry', (tester) async {
    const path = '/retry-control.png';
    images.failedOnce.add(path);
    try {
      await _mount(tester, images.url(path));
      await _until(tester, () => images.calls[path] == 1 && find.descendant(
          of: _card, matching: find.byType(Image)).evaluate().isEmpty,
          'First HTTP failure did not reach the real error placeholder');
      expect(_decoded(tester), isFalse);
      expect(_placeholder, findsOneWidget);
      // Keep the real production retry timer. Pumping fake time advances a
      // fake-zone timer; alternating real delay also covers an HTTP-zone timer.
      await tester.pump(const Duration(seconds: 3));
      await _until(tester, () => images.calls[path] == 2 && _decoded(tester),
          'Production same-URL retry did not decode the repaired response');
      await tester.pump();
      expect(_placeholder, findsNothing);
      expect(images.calls[path], 2);
    } finally {
      await cleanup(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
