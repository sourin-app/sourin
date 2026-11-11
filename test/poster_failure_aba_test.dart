// UNRUN framework-boundary test payload. Real loopback HTTP and production
// image provider/decode. No direct private state or errorBuilder invocation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show createLocalImageConfiguration;
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
        return Future<ConnectionTask<Socket>>.error(StateError('Nonfixture socket refused'));
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
      unawaited(future.then<void>((_) { active.remove(future); }));
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
      final status = sequence[count <= sequence.length ? count - 1 : sequence.length - 1];
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
      await Future.wait(List<Future<void>>.of(active)).timeout(const Duration(seconds: 8));
    } finally {
      http.close();
      HttpOverrides.global = previous;
      await server.close(force: true);
    }
  }
}

// A real render parent may lay out its child repeatedly with changed constraints.
// LayoutBuilder then asks the framework to update the same PosterCard Element.
// The callback only observes public State identity/widget.cover after each layout.
class _BurstLayout extends SingleChildRenderObjectWidget {
  const _BurstLayout({required this.armed, required this.observed, required super.child});
  final bool armed;
  final VoidCallback observed;
  @override
  RenderObject createRenderObject(BuildContext context) => _BurstRender(armed, observed);
  @override
  void updateRenderObject(BuildContext context, _BurstRender renderObject) {
    renderObject.update(armed, observed);
  }
}

class _BurstRender extends RenderProxyBox {
  _BurstRender(this.armed, this.observed);
  bool armed;
  VoidCallback observed;
  void update(bool value, VoidCallback callback) {
    armed = value;
    observed = callback;
    markNeedsLayout();
  }
  @override
  void performLayout() {
    child!.layout(BoxConstraints.tightFor(width: 120, height: 240), parentUsesSize: true);
    observed();
    if (armed) {
      armed = false;
      child!.layout(BoxConstraints.tightFor(width: 121, height: 240), parentUsesSize: true);
      observed();
      child!.layout(BoxConstraints.tightFor(width: 120, height: 240), parentUsesSize: true);
      observed();
    }
    size = constraints.constrain(child!.size);
  }
}

Finder _card(GlobalKey<State<PosterCard>> key) => find.byKey(key);
Finder _raw(GlobalKey<State<PosterCard>> key) => find.descendant(of: _card(key), matching: find.byType(RawImage));
Finder _image(GlobalKey<State<PosterCard>> key) => find.descendant(of: _card(key), matching: find.byType(Image));
Finder _placeholder(GlobalKey<State<PosterCard>> key) => find.descendant(
  of: _card(key), matching: find.byWidgetPredicate((widget) => widget is Icon && widget.icon == AppIcons.movie_outlined),
);
bool _decoded(WidgetTester tester, GlobalKey<State<PosterCard>> key) => tester
    .renderObjectList<RenderImage>(_raw(key))
    .any((render) => render.image?.width == 32 && render.image?.height == 48);

Future<void> _until(WidgetTester tester, bool Function() ready, String reason,
    {bool pump = true, Duration budget = const Duration(seconds: 8)}) async {
  final wall = Stopwatch()..start();
  while (!ready()) {
    if (wall.elapsed >= budget) throw TimeoutException(reason, budget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    if (pump) await tester.pump(const Duration(milliseconds: 20));
  }
}

Widget _root(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(theme: theme, builder: (_, body) => AppThemeHost(data: theme, child: body!),
    home: Scaffold(body: Center(child: SizedBox(width: 130, height: 240, child: child))));
}

Future<void> _mount(WidgetTester tester, GlobalKey<State<PosterCard>> key, String cover) async {
  await tester.pumpWidget(_root(PosterCard(key: key, title: 'Observed cover', width: 120, cover: cover)));
  await tester.pump();
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
    await _until(tester, () => fixture.active.isEmpty, 'Loopback responses did not finish');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets('real failed A callback cannot fail new A after one-frame same-State A B A layout', (tester) async {
    final key = GlobalKey<State<PosterCard>>(debugLabel: 'failure-aba-owned');
    final warm = GlobalKey<State<PosterCard>>(debugLabel: 'failure-aba-warm');
    const aPath = '/aba-failed-a.png';
    const bPath = '/aba-cached-b.png';
    fixture.statuses[aPath] = <int>[503, 200];
    await tester.runAsync(() async {
      fixture.hold(aPath, 1);
      fixture.hold(aPath, 2);
    });
    ImageStream? observedStream;
    ImageStreamListener? listener;
    final covers = <String?>[];
    final states = <State<PosterCard>?>[];
    final rawCounts = <int>[];
    void observe() {
      covers.add((key.currentWidget as PosterCard?)?.cover);
      states.add(key.currentState);
      rawCounts.add(_raw(key).evaluate().length);
    }
    Widget burst(bool armed) => _root(_BurstLayout(armed: armed, observed: observe,
      child: LayoutBuilder(builder: (_, constraints) => PosterCard(
        key: key, title: 'Observed cover', width: 120,
        cover: fixture.url(constraints.maxWidth == 121 ? bPath : aPath),
      ))));
    try {
      await _mount(tester, warm, fixture.url(bPath));
      await _until(tester, () => _decoded(tester, warm), 'B cache warm-up did not really decode');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(burst(false));
      await _until(tester, () => fixture.calls[aPath] == 1, 'Initial held A request missing');
      final retained = key.currentState;
      expect(retained, isNotNull);
      final imageWidget = tester.widget<Image>(_image(key));
      observedStream = imageWidget.image.resolve(createLocalImageConfiguration(tester.element(_image(key))));
      var actualHttpFailureObserved = false;
      listener = ImageStreamListener((info, _) => info.dispose(), onError: (Object error, StackTrace? stack) {
        actualHttpFailureObserved = error is NetworkImageLoadException && error.statusCode == 503;
      });
      observedStream.addListener(listener);
      await tester.runAsync(() async => fixture.release(aPath, 1));
      // Let the actual Image stream receive the HTTP error, but leave its normal
      // next-frame build pending. No errorBuilder is called by this test.
      await _until(tester, () => actualHttpFailureObserved, 'Real A HTTP failure was not observed', pump: false);
      final marker = covers.length;
      await tester.pumpWidget(burst(true));
      expect(covers.skip(marker).toList(), <String?>[fixture.url(aPath), fixture.url(bPath), fixture.url(aPath)],
          reason: 'Actual LayoutBuilder updates must traverse all three URLs in one real frame');
      expect(states.skip(marker).every((state) => identical(state, retained)), isTrue,
          reason: 'All three layout updates must reuse the production PosterCard State');
      expect(rawCounts.skip(marker).toList(), <int>[0, 1, 1],
          reason: 'Route prerequisite: initial real errorBuilder returned no RawImage, then cached B cleared ImageState error before pending new A');
      await _until(tester, () => fixture.calls[aPath] == 2, 'New A did not issue its own actual request');
      await tester.pump();
      expect(_image(key), findsOneWidget,
          reason: 'Old post-frame failure must not remove the new held A image or spend its retry budget');
      expect(_placeholder(key), findsOneWidget);
      expect(_decoded(tester, key), isFalse);
      await tester.runAsync(() async => fixture.release(aPath, 2));
      await _until(tester, () => _decoded(tester, key), 'New A did not decode without retry');
      await tester.pump();
      expect(_placeholder(key), findsNothing);
      expect(fixture.calls[aPath], 2, reason: 'Only old failed A and new successful A requests; no stale-failure retry');
      expect(fixture.calls[bPath], 1, reason: 'B is a real decoded cache hit during the ABA transition');
    } finally {
      if (observedStream != null && listener != null) observedStream.removeListener(listener);
      await cleanup(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('same-State repeated layout retains real cached A and B decoded covers', (tester) async {
    final key = GlobalKey<State<PosterCard>>(debugLabel: 'success-aba-owned');
    final warm = GlobalKey<State<PosterCard>>(debugLabel: 'success-aba-warm');
    const aPath = '/aba-success-a.png';
    const bPath = '/aba-success-b.png';
    final states = <State<PosterCard>?>[];
    Widget burst(bool armed) => _root(_BurstLayout(armed: armed, observed: () => states.add(key.currentState),
      child: LayoutBuilder(builder: (_, constraints) => PosterCard(key: key, title: 'Observed cover', width: 120,
        cover: fixture.url(constraints.maxWidth == 121 ? bPath : aPath)))));
    try {
      await _mount(tester, warm, fixture.url(bPath));
      await _until(tester, () => _decoded(tester, warm), 'Successful B warm-up did not decode');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(burst(false));
      await _until(tester, () => _decoded(tester, key), 'Successful A did not decode');
      final retained = key.currentState;
      final marker = states.length;
      await tester.pumpWidget(burst(true));
      await tester.pump();
      expect(states.skip(marker).length, 3);
      expect(states.skip(marker).every((state) => identical(state, retained)), isTrue);
      expect(_decoded(tester, key), isTrue);
      expect(_placeholder(key), findsNothing);
      expect(fixture.calls[aPath], 1);
      expect(fixture.calls[bPath], 1);
    } finally {
      await cleanup(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('actual first HTTP failure keeps ordinary same URL successful retry', (tester) async {
    final key = GlobalKey<State<PosterCard>>(debugLabel: 'ordinary-retry-owned');
    const path = '/failure-aba-retry-control.png';
    fixture.statuses[path] = <int>[503, 200];
    try {
      await _mount(tester, key, fixture.url(path));
      await _until(tester, () => fixture.calls[path] == 1 && _image(key).evaluate().isEmpty, 'HTTP failure did not reach the real placeholder');
      expect(_placeholder(key), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await _until(tester, () => fixture.calls[path] == 2 && _decoded(tester, key), 'Normal retry did not decode');
      await tester.pump();
      expect(_placeholder(key), findsNothing);
      expect(fixture.calls[path], 2);
    } finally {
      await cleanup(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('actual continuing HTTP failures keep the two-retry production bound', (tester) async {
    final key = GlobalKey<State<PosterCard>>(debugLabel: 'bounded-retry-owned');
    const path = '/failure-aba-bounded-retry-control.png';
    fixture.statuses[path] = <int>[503];
    try {
      await _mount(tester, key, fixture.url(path));
      await _until(tester, () => fixture.calls[path] == 1 && _image(key).evaluate().isEmpty, 'First bounded failure missing');
      await tester.pump(const Duration(seconds: 3));
      await _until(tester, () => fixture.calls[path] == 2 && _image(key).evaluate().isEmpty, 'First bounded retry missing');
      await tester.pump(const Duration(seconds: 5));
      await _until(tester, () => fixture.calls[path] == 3 && _image(key).evaluate().isEmpty, 'Second bounded retry missing');
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(fixture.calls[path], 3, reason: 'Initial request plus exactly two existing retries');
      expect(_placeholder(key), findsOneWidget);
      expect(_decoded(tester, key), isFalse);
    } finally {
      await cleanup(tester);
    }
  }, timeout: const Timeout(Duration(seconds: 40)));
}
