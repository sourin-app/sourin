import 'dart:async';

import 'package:desktop_webview_window/src/native_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/pan_settings_page.dart';

const accounts = [
  PanAccountStatus(
    kind: 'quark',
    kindName: 'Quark',
    loggedIn: true,
    expired: false,
    keyringAvailable: true,
  ),
  PanAccountStatus(
    kind: 'baidu',
    kindName: 'Baidu',
    loggedIn: false,
    expired: false,
    keyringAvailable: true,
  ),
];

class LocalRuntimeTransport extends NativeTransport {
  LocalRuntimeTransport() : super.testing();

  @override
  Future<T?> invoke<T>(String method, [Object? arguments]) async {
    if (method == 'isWebviewAvailable') return true as T;
    throw StateError('Unexpected local plugin request');
  }
}

Future<void> openSettings(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: const Scaffold(body: PanSettingsBody()),
    ),
  );
  await tester.pump();
}

VoidCallback? action(WidgetTester tester, String key) =>
    tester.widget<AppTextButton>(find.byKey(ValueKey(key))).onPressed;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    NativeTransport.debugOverride = LocalRuntimeTransport();
    debugPanCredentialStatusFetcher = () async => accounts;
    debugPanQrLoginStarter = (_) async => {
      'key': 'local-test-key',
      'url': '',
      'svg':
          '<svg viewBox="0 0 21 21">'
          '<path fill="#000000" d="M0 0h1v1H0V0"/></svg>',
    };
    debugPanQrLoginPoller = (_, __) async => {'status': 'pending'};
  });
  tearDown(() {
    debugPanCredentialStatusFetcher = null;
    debugPanQrLoginStarter = null;
    debugPanQrLoginPoller = null;
    debugPanLogoutCaller = null;
    debugPanWebLoginCaller = null;
    NativeTransport.debugOverride = null;
  });

  testWidgets('web startup blocks duplicate, other account and QR actions', (
    tester,
  ) async {
    final pending = Completer<bool>();
    final starts = <String>[];
    var qrStarts = 0;
    var logouts = 0;
    debugPanLogoutCaller = (_) async {
      logouts++;
    };
    debugPanWebLoginCaller = (kind) {
      starts.add(kind);
      return pending.future;
    };
    debugPanQrLoginStarter = (_) async {
      qrStarts++;
      return {'key': 'local-test-key', 'svg': '<svg/>', 'url': ''};
    };
    try {
      await openSettings(tester);
      final first = action(tester, 'pan-account-weblogin-quark')!;
      final other = action(tester, 'pan-account-weblogin-baidu')!;
      final qr = action(tester, 'pan-account-qrlogin-baidu')!;
      final logout = action(tester, 'pan-account-logout-quark')!;
      first();
      first();
      other();
      qr();
      logout();
      await tester.pump();
      expect(starts, ['quark']);
      expect(qrStarts, 0);
      expect(logouts, 0);
      expect(action(tester, 'pan-account-weblogin-baidu'), isNull);
      expect(action(tester, 'pan-account-qrlogin-quark'), isNull);
      expect(action(tester, 'pan-account-logout-quark'), isNull);
      pending.complete(false);
      await tester.pump();
      expect(action(tester, 'pan-account-weblogin-baidu'), isNotNull);
      expect(action(tester, 'pan-account-qrlogin-quark'), isNotNull);
    } finally {
      if (!pending.isCompleted) pending.complete(false);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('QR startup blocks a queued web action until the modal closes', (
    tester,
  ) async {
    var webStarts = 0;
    debugPanWebLoginCaller = (_) async {
      webStarts++;
      return false;
    };
    try {
      await openSettings(tester);
      final qr = action(tester, 'pan-account-qrlogin-quark')!;
      final web = action(tester, 'pan-account-weblogin-baidu')!;
      qr();
      web();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(webStarts, 0);
      action(tester, 'pan-qr-login-close')!();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      action(tester, 'pan-account-weblogin-baidu')!();
      await tester.pump();
      expect(webStarts, 1);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('web startup failure releases the login lock without logging', (
    tester,
  ) async {
    final originalPrint = debugPrint;
    final logs = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    debugPanWebLoginCaller = (_) async =>
        throw StateError('local-test-web-start-secret');
    try {
      await openSettings(tester);
      action(tester, 'pan-account-weblogin-quark')!();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('local-test-web-start-secret'), findsNothing);
      expect(
        logs.where((line) => line.contains('local-test-web-start-secret')),
        isEmpty,
      );
      expect(action(tester, 'pan-account-weblogin-baidu'), isNotNull);
      expect(action(tester, 'pan-account-qrlogin-quark'), isNotNull);
    } finally {
      debugPrint = originalPrint;
      await tester.pumpWidget(const SizedBox());
    }
  });
}
