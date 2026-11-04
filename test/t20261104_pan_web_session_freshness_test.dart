import 'dart:async';
import 'package:desktop_webview_window/src/native_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/pan_web_login.dart';
import 'package:sourin_spike/ui/widgets/pan_login_session.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 't20261104_pan_login_ux_session_test.dart' as fixture;

const oldCookies = [CapturedCookie(domain: '.baidu.com', name: 'BDUSS', value: 'old-test-session')];

Future<void> open(WidgetTester tester, fixture.LocalWindow window, {Map<String, String>? baseline}) async {
  await tester.pumpWidget(fixture.host(Builder(builder: (context) => TextButton(
    onPressed: () => showAppDialog<bool>(context: context,
      builder: (_) => PanWebLoginWaitingDialog(webview: window, spec: PanWebLoginSpec.of('baidu')!, initialAuthKeys: baseline)),
    child: const Text('open'),
  ))));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

class StartupTransport extends NativeTransport {
  StartupTransport({this.failBaseline = false}) : super.testing();
  final bool failBaseline;
  final methods = <String>[];
  @override
  Future<T?> invoke<T>(String method, [Object? arguments]) async {
    methods.add(method);
    if (method == 'isWebviewAvailable') return true as T;
    if (method == 'create') return <Object?, Object?>{'id': 904, 'windowHandle': 0} as T;
    if (method == 'getAllCookies') {
      if (failBaseline) throw StateError('synthetic-plugin-private-error');
      return <Object?>[] as T;
    }
    return null;
  }
}

void main() {
  final commands = <String>[];
  setUp(() {
    commands.clear();
    debugPanLoginCommandCaller = (command, _) async {
      commands.add(command);
      return command == 'pan_save_credential' ? {'ok': true} : fixture.status(kind: 'baidu');
    };
  });
  tearDown(() {
    debugPanLoginCommandCaller = null;
    NativeTransport.debugOverride = null;
  });
  testWidgets('unknown baseline never automatically saves existing authentication', (tester) async {
    final window = fixture.LocalWindow(() async => oldCookies);
    try {
      await open(tester, window);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(commands, isEmpty);
      expect(window.closes, 0);
    } finally { await tester.pumpWidget(const SizedBox()); }
  });
  testWidgets('ordinary recheck does not authorize existing authentication', (tester) async {
    final window = fixture.LocalWindow(() async => oldCookies);
    try {
      await open(tester, window);
      await tester.tap(find.byKey(const ValueKey('pan-web-login-recheck')));
      await tester.pump();
      await tester.pump();
      expect(commands, isEmpty);
    } finally { await tester.pumpWidget(const SizedBox()); }
  });
  testWidgets('known unchanged auth and tracking changes do not auto-save', (tester) async {
    final window = fixture.LocalWindow(() async => [...oldCookies,
      const CapturedCookie(domain: '.baidu.com', name: 'BAIDUID', value: 'changed-test-tracking')]);
    try {
      await open(tester, window, baseline: const {'BDUSS': 'old-test-session'});
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(commands, isEmpty);
    } finally { await tester.pumpWidget(const SizedBox()); }
  });
  for (final baseline in [const <String, String>{}, const {'BDUSS': 'different-test-session'}]) {
    testWidgets('new or changed authentication saves with known baseline $baseline', (tester) async {
      final window = fixture.LocalWindow(() async => oldCookies);
      try {
        await open(tester, window, baseline: baseline);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        await tester.pump();
        expect(commands, ['pan_save_credential', 'pan_auth_status']);
      } finally { await tester.pumpWidget(const SizedBox()); }
    });
  }
  testWidgets('explicit existing-session confirmation rereads and saves current value', (tester) async {
    final read = Completer<List<CapturedCookie>>();
    final window = fixture.LocalWindow(() => read.future);
    try {
      await open(tester, window);
      await tester.tap(find.byKey(const ValueKey('pan-web-login-confirm-existing')));
      await tester.pump();
      expect(window.reads, 1);
      expect(commands, isEmpty);
      read.complete(oldCookies);
      await tester.pump();
      await tester.pump();
      expect(commands, ['pan_save_credential', 'pan_auth_status']);
    } finally {
      if (!read.isCompleted) read.complete(const []);
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('cancel during confirmed reread cannot save late cookie', (tester) async {
    final read = Completer<List<CapturedCookie>>();
    final window = fixture.LocalWindow(() => read.future);
    try {
      await open(tester, window);
      await tester.tap(find.byKey(const ValueKey('pan-web-login-confirm-existing')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pan-web-login-cancel')));
      await tester.pump(const Duration(milliseconds: 400));
      read.complete(oldCookies);
      await tester.pump();
      expect(commands, isEmpty);
    } finally {
      if (!read.isCompleted) read.complete(const []);
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('failed reread followed by ordinary retry still needs confirmation', (tester) async {
    final window = fixture.LocalWindow(() async => throw StateError('synthetic-private-error'));
    try {
      await open(tester, window);
      await tester.tap(find.byKey(const ValueKey('pan-web-login-confirm-existing')));
      await tester.pump();
      expect(find.byKey(const ValueKey('pan-web-login-error')), findsOneWidget);
      window.reader = () async => oldCookies;
      await tester.tap(find.byKey(const ValueKey('pan-web-login-recheck')));
      await tester.pump();
      expect(commands, isEmpty);
    } finally { await tester.pumpWidget(const SizedBox()); }
  });
  testWidgets('narrow action area wraps without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    final window = fixture.LocalWindow(() async => const []);
    try {
      await open(tester, window);
      expect(find.byKey(const ValueKey('pan-web-login-confirm-existing')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
  for (final failBaseline in [false, true]) {
    testWidgets('production startup snapshots cookies before launch (failure=$failBaseline)', (tester) async {
      final transport = StartupTransport(failBaseline: failBaseline);
      NativeTransport.debugOverride = transport;
      try {
        await tester.pumpWidget(fixture.host(Builder(builder: (context) => TextButton(
          onPressed: () => showPanWebLogin(context, kind: 'baidu'), child: const Text('start'),
        ))));
        await tester.tap(find.text('start'));
        for (var i = 0; i < 8; i++) { await tester.pump(); }
        expect(transport.methods.take(4), ['isWebviewAvailable', 'create', 'getAllCookies', 'launch']);
        final dialog = tester.widget<PanWebLoginWaitingDialog>(find.byType(PanWebLoginWaitingDialog));
        expect(dialog.initialAuthKeys, failBaseline ? isNull : equals({'BDUSS': ''}));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 16));
        await tester.pump();
        expect(commands, isEmpty);
      } finally { await tester.pumpWidget(const SizedBox()); }
    });
  }
}
