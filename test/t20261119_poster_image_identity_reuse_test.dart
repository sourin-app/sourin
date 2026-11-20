// Exercise the production image provider and decoder over loopback HTTP.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as engine;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

// Use the already validated finite 32x48 opaque PNG fixture bytes.
const _validatedPng =
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAwCAIAAAD/zu84AAAAYklEQVR4nGNUDp3LQEvARFPTGUYtIAKMxgFBMBpEAx9ELLgkdgbOItUs9/VpmIKjkUwQjAYRQTAaRATBaBARBKNBRBCMBhFBMBpEBMFoEI2AIGIc7cYO/0hmGrWAEKB5EAEASO0FiyW/0WUAAAAASUVORK5CYII=';

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
          StateError('Nonfixture socket refused'),
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

class _Fixture {
  late HttpServer server;
  late _LoopbackOnlyHttp http;
  HttpOverrides? previous;
  final gates = <String, Completer<void>>{};
  final calls = <String, int>{};
  final statuses = <String, List<int>>{};
  final active = <Future<void>>[];
  final errors = <String>[];
  final bytes = base64Decode(_validatedPng);
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    previous = HttpOverrides.current;
    http = _LoopbackOnlyHttp(server.port);
    HttpOverrides.global = http;
    server.listen((request) {
      final future = serve(request);
      active.add(future);
      unawaited(
        future.then<void>((_) {
          active.remove(future);
        }),
      );
    });
  }

  Future<void> serve(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final count = calls.update(path, (value) => value + 1, ifAbsent: () => 1);
      request.response.persistentConnection = false;
      final gate = gates['$path#$count'];
      if (gate != null) await gate.future;
      final sequence = statuses[path] ?? <int>[HttpStatus.ok];
      final status =
          sequence[count <= sequence.length ? count - 1 : sequence.length - 1];
      request.response.statusCode = status;
      if (status == HttpStatus.ok) {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(bytes);
      }
      await request.response.close();
    } catch (error) {
      errors.add(error.toString());
    }
  }

  String url(String path) => 'http://127.0.0.1:${server.port}$path';
  void hold(String path, int count) {
    final key = '$path#$count';
    if (gates.containsKey(key)) throw StateError('Repeated fixture gate');
    gates[key] = Completer<void>();
  }

  void release(String path, int count) {
    final gate = gates['$path#$count'];
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void releaseAll() {
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<void> stop() async {
    releaseAll();
    try {
      await Future.wait(List<Future<void>>.of(active))
          .timeout(const Duration(seconds: 8));
    } finally {
      http.close();
      HttpOverrides.global = previous;
      await server.close(force: true);
    }
  }
}

const _requireReuse = bool.fromEnvironment(
  'EXPECT_IMAGE_REUSE',
  defaultValue: true,
);
const _evidence = String.fromEnvironment('POSTER_IDENTITY_EVIDENCE');
const _key = ValueKey('identity-card');

Finder get _poster => find.byKey(_key);
Finder get _image => find.descendant(of: _poster, matching: find.byType(Image));
Finder get _raw =>
    find.descendant(of: _poster, matching: find.byType(RawImage));
Finder get _placeholder => find.descendant(
  of: _poster,
  matching: find.byWidgetPredicate(
    (w) => w is Icon && w.icon == AppIcons.movie_outlined,
  ),
);
bool _decoded(WidgetTester tester) =>
    tester.renderObjectList<RenderImage>(_raw).any((r) => r.image != null);

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final wall = Stopwatch()..start();
  while (!ready()) {
    if (wall.elapsed > const Duration(seconds: 8))
      throw TimeoutException('Fixture condition not observed');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Widget _host(
  Widget child, {
  double dpr = 1,
  bool invert = false,
  bool ticker = true,
  bool reduce = false,
  Brightness brightness = Brightness.light,
}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    theme: theme,
    builder: (_, body) => AppThemeHost(
      data: theme,
      child: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          devicePixelRatio: dpr,
          invertColors: invert,
          disableAnimations: reduce,
        ),
        child: TickerMode(enabled: ticker, child: body!),
      ),
    ),
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(key: const ValueKey('capture'), child: child),
      ),
    ),
  );
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  if (_evidence.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  final rect = tester.getRect(_poster);
  final opacities = tester
      .widgetList<FadeTransition>(
        find.descendant(of: _poster, matching: find.byType(FadeTransition)),
      )
      .map((w) => w.opacity.value)
      .toList();
  final texts = tester
      .widgetList<Text>(
        find.descendant(of: _poster, matching: find.byType(Text)),
      )
      .map((t) => t.data)
      .toList();
  final semantics = tester
      .getSemantics(_poster)
      .toStringDeep()
      .replaceAll(RegExp(r'#\d+'), '#ID');
  await tester.runAsync(() async {
    final directory = Directory(_evidence);
    await directory.create(recursive: true);
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: engine.ImageByteFormat.png);
      final png = File('$_evidence/$name.png');
      if (png.existsSync()) throw StateError('Existing screenshot evidence');
      await png.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      final report = File('$_evidence/$name.json');
      if (report.existsSync()) throw StateError('Existing snapshot evidence');
      await report.writeAsString(
        jsonEncode({
          'rect': [rect.left, rect.top, rect.width, rect.height],
          'texts': texts,
          'opacities': opacities,
          'semantics': semantics,
        }),
        flush: true,
      );
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = _Fixture();
  setUpAll(fixture.start);
  tearDownAll(() async {
    await fixture.stop();
    expect(fixture.http.deniedSockets, 0);
    expect(fixture.errors, isEmpty);
  });
  setUp(() => UiPrefs.debugResetForTest(<String, String>{}));
  tearDown(() => UiPrefs.debugResetForTest(<String, String>{}));
  Future<void> cleanup(WidgetTester tester) async {
    await tester.runAsync(() async => fixture.releaseAll());
    await _until(tester, () => fixture.active.isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'exact Image configuration survives decoded frame and parent hover focus updates',
    (tester) async {
      final semantics = tester.ensureSemantics();
      const path = '/identity-real-frame.png';
      await tester.runAsync(() async => fixture.hold(path, 1));
      var title = '原始标题';
      var unread = 0;
      var focused = false;
      var calls = 0;
      late StateSetter update;
      Widget card() => PosterCard(
        key: _key,
        title: title,
        cover: fixture.url(path),
        subtitle: '更新至12集',
        badge: '9.2',
        unread: unread,
        focused: focused,
        width: 120,
        onTap: () => calls++,
      );
      try {
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return _host(card());
            },
          ),
        );
        await _until(tester, () => fixture.calls[path] == 1);
        expect(_placeholder, findsOneWidget);
        final initial = tester.widget<Image>(_image);
        final imageState = tester.state(_image);
        await _snapshot(tester, '01-pending');
        await tester.runAsync(() async => fixture.release(path, 1));
        await _until(tester, () => _decoded(tester));
        await tester.pumpAndSettle();
        expect(_placeholder, findsNothing);
        expect(identical(tester.state(_image), imageState), isTrue);
        expect(fixture.calls[path], 1);
        if (_requireReuse) {
          expect(
            identical(tester.widget<Image>(_image), initial),
            isTrue,
            reason: 'First decoded-frame parent readiness must reuse exact Image configuration',
          );
        }
        await _snapshot(tester, '02-decoded');
        update(() {
          title = '更新标题';
          unread = 3;
          focused = true;
        });
        await tester.pumpAndSettle();
        expect(find.text('更新标题'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        if (_requireReuse)
          expect(identical(tester.widget<Image>(_image), initial), isTrue);
        await _snapshot(tester, '03-parent-focused');
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(_poster));
        await tester.pumpAndSettle();
        if (_requireReuse)
          expect(identical(tester.widget<Image>(_image), initial), isTrue);
        await _snapshot(tester, '04-hover');
        await tester.tap(_poster);
        await tester.pumpAndSettle();
        expect(calls, 1);
        final context = tester.element(
          find
              .descendant(
                of: _poster,
                matching: find.byType(FocusableActionDetector),
              )
              .first,
        );
        Focus.of(context).nextFocus();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        // Activation is additionally covered by unchanged existing press tests;
        // this assertion requires the key to reach the actual focused card.
        expect(calls, 2);
        await mouse.removePointer();
        expect(fixture.calls[path], 1);
      } finally {
        await cleanup(tester);
        semantics.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 35)),
  );

  testWidgets(
    'URL width DPR and inherited Image properties invalidate correctly',
    (tester) async {
      var path = '/invalidation-a.png';
      var width = 120.0;
      var dpr = 1.0;
      var invert = false;
      var reduce = false;
      var ticker = true;
      late StateSetter update;
      try {
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return _host(
                PosterCard(
                  key: _key,
                  title: '继承状态',
                  cover: fixture.url(path),
                  width: width,
                ),
                dpr: dpr,
                invert: invert,
                reduce: reduce,
                ticker: ticker,
              );
            },
          ),
        );
        await _until(tester, () => _decoded(tester));
        await tester.pumpAndSettle();
        var previous = tester.widget<Image>(_image);
        update(() => width = 140);
        await tester.pumpAndSettle();
        var next = tester.widget<Image>(_image);
        expect(identical(previous, next), isFalse);
        expect((next.image as ResizeImage).height, 210);
        previous = next;
        update(() => dpr = 2);
        await tester.pumpAndSettle();
        next = tester.widget<Image>(_image);
        expect(identical(previous, next), isFalse);
        expect((next.image as ResizeImage).height, 420);
        previous = next;
        await _until(tester, () => _decoded(tester));
        await tester.pumpAndSettle();
        final imageStream =
            (tester
                        .state(_image)
                        .toDiagnosticsNode()
                        .getProperties()
                        .singleWhere((p) => p.name == 'stream')
                        .value
                    as ImageStream)
                .completer!;
        var detached = 0;
        void observeDetach() {
          detached++;
        }

        imageStream.addOnLastListenerRemovedCallback(observeDetach);
        update(() {
          invert = true;
          reduce = true;
          ticker = false;
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        if (_requireReuse)
          expect(identical(previous, tester.widget<Image>(_image)), isTrue);
        expect(tester.widget<RawImage>(_raw).invertColors, isTrue);
        expect(
          detached,
          1,
          reason:
              'Real stream last-listener removal observed via public callback',
        );
        update(() {
          invert = false;
          reduce = false;
          ticker = true;
        });
        await tester.pumpAndSettle();
        expect(tester.widget<RawImage>(_raw).invertColors, isFalse);
        imageStream.addOnLastListenerRemovedCallback(observeDetach);
        update(() => ticker = false);
        await tester.pump();
        expect(
          detached,
          2,
          reason: 'TickerMode alone pauses the resumed real stream',
        );
        update(() => ticker = true);
        await tester.pumpAndSettle();
        imageStream.addOnLastListenerRemovedCallback(observeDetach);
        update(() => reduce = true);
        await tester.pump();
        expect(
          detached,
          3,
          reason: 'disableAnimations alone pauses the resumed real stream',
        );
        update(() => reduce = false);
        await tester.pumpAndSettle();
        previous = tester.widget<Image>(_image);
        const b = '/invalidation-held-b.png';
        await tester.runAsync(() async => fixture.hold(b, 1));
        update(() => path = b);
        await tester.pump();
        expect(identical(previous, tester.widget<Image>(_image)), isFalse);
        await _until(tester, () => fixture.calls[b] == 1);
        expect(_decoded(tester), isFalse);
        expect(_placeholder, findsOneWidget);
        await tester.runAsync(() async => fixture.release(b, 1));
        await _until(tester, () => _decoded(tester));
        await tester.pumpAndSettle();
        expect(_placeholder, findsNothing);
      } finally {
        await cleanup(tester);
      }
    },
    timeout: const Timeout(Duration(seconds: 35)),
  );

  testWidgets('dispose while response is held has no stale readiness update', (
    tester,
  ) async {
    const path = '/dispose-held.png';
    await tester.runAsync(() async => fixture.hold(path, 1));
    try {
      await tester.pumpWidget(
        _host(PosterCard(key: _key, title: '卸载', cover: fixture.url(path))),
      );
      await _until(tester, () => fixture.calls[path] == 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async => fixture.release(path, 1));
      await _until(tester, () => fixture.active.isEmpty);
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.calls[path], 1);
      expect(tester.takeException(), isNull);
    } finally {
      await cleanup(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 25)));
  for (final brightness in Brightness.values) {
    testWidgets('matched lifecycle captures at $brightness', (tester) async {
      final semantics = tester.ensureSemantics();
      final prefix = brightness.name;
      final path = '/matched-$prefix.png';
      fixture.statuses[path] = <int>[503, 200];
      await tester.runAsync(() async {
        fixture.hold(path, 1);
        fixture.hold(path, 2);
      });
      var taps = 0;
      try {
        await tester.pumpWidget(
          _host(
            PosterCard(
              key: _key,
              width: 120,
              title: '一致性画面',
              subtitle: '更新至12集',
              badge: '9.2',
              unread: 3,
              releaseStatus: '更新至12集',
              cover: fixture.url(path),
              onTap: () => taps++,
            ),
            brightness: brightness,
          ),
        );
        await _until(tester, () => fixture.calls[path] == 1);
        await tester.pumpAndSettle();
        await _snapshot(tester, '$prefix-01-pending');
        await tester.runAsync(() async => fixture.release(path, 1));
        await _until(tester, () => _image.evaluate().isEmpty);
        await tester.pumpAndSettle();
        await _snapshot(tester, '$prefix-02-failed');
        await tester.pump(const Duration(seconds: 3));
        await _until(tester, () => fixture.calls[path] == 2);
        await tester.pumpAndSettle();
        await _snapshot(tester, '$prefix-03-retry-held');
        final image = tester.widget<Image>(_image);
        final stream = image.image.resolve(
          createLocalImageConfiguration(tester.element(_image)),
        );
        var arrived = false;
        final listener = ImageStreamListener((_, __) {
          arrived = true;
        });
        stream.addListener(listener);
        try {
          await tester.runAsync(() async => fixture.release(path, 2));
          final wall = Stopwatch()..start();
          while (!arrived) {
            if (wall.elapsed > const Duration(seconds: 8))
              throw TimeoutException('Matched image did not arrive');
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          await tester.pump();
          await tester.pump();
          await _snapshot(tester, '$prefix-04-first-frame');
          await tester.pump(const Duration(milliseconds: 100));
          await _snapshot(tester, '$prefix-05-mid-fade');
          await tester.pumpAndSettle();
          await _snapshot(tester, '$prefix-06-settled');
        } finally {
          stream.removeListener(listener);
        }
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(tester.getCenter(_poster));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 45));
        await _snapshot(tester, '$prefix-07-mid-hover');
        await tester.pumpAndSettle();
        await _snapshot(tester, '$prefix-08-hovered');
        await mouse.down(tester.getCenter(_poster));
        await tester.pump(const Duration(milliseconds: 110));
        await tester.pump(const Duration(milliseconds: 45));
        await _snapshot(tester, '$prefix-09-pressed');
        await mouse.up();
        await tester.pumpAndSettle();
        expect(taps, 1);
        await mouse.removePointer();
        expect(fixture.calls[path], 2);
        expect(_placeholder, findsNothing);
      } finally {
        await cleanup(tester);
        semantics.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 40)));
  }
}
