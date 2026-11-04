import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/pan_settings_page.dart';
import 'package:sourin_spike/ui/widgets/pan_web_login.dart';
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';

void main() {
  tearDown(() {
    debugPanCredentialStatusFetcher = null;
    debugPanQrLoginStarter = null;
    debugPanQrLoginPoller = null;
  });

  final quark = PanWebLoginSpec.of('quark')!;
  CapturedCookie cookie(String name, String value) =>
      CapturedCookie(domain: '.quark.cn', name: name, value: value);

  test('capture rejects unusable authentication values', () {
    for (final value in [
      'token; injected=secret',
      'token\r\nheader',
      'token\n',
    ]) {
      expect(
        panWebLoginCaptured([
          cookie('__pus', value),
          cookie('__kps', 'valid-test-value'),
        ], quark),
        isFalse,
      );
    }
  });

  test('cleared final authentication cookie does not reuse an older value', () {
    expect(
      panWebLoginCaptured([
        cookie('__pus', 'old-test-value'),
        cookie('__kps', 'valid-test-value'),
        cookie('__pus', ''),
      ], quark),
      isFalse,
    );
    expect(
      panWebLoginMissingKeys([
        cookie('__pus', 'old-test-value'),
        cookie('__kps', 'valid-test-value'),
        cookie('__pus', ''),
      ], quark),
      contains('__pus'),
    );
  });

  test('cookie builder rejects control characters in names', () {
    for (final name in ['bad\tname', '\t__pus', '__pus\n']) {
      expect(
        panWebBuildCookieString([cookie(name, 'value')], quark),
        isNull,
      );
    }
  });

  testWidgets('settings starts QR in an independent modal', (tester) async {
    debugPanCredentialStatusFetcher = () async => const [
      PanAccountStatus(
        kind: 'quark',
        kindName: 'Quark',
        loggedIn: false,
        expired: false,
        keyringAvailable: true,
      ),
    ];
    debugPanQrLoginStarter = (_) async => {
      'key': 'local-test-key',
      'url': '',
      'svg':
          '<svg viewBox="0 0 21 21">'
          '<path fill="#000000" d="M0 0h1v1H0z"/></svg>',
    };
    debugPanQrLoginPoller = (_, __) async => {'status': 'pending'};
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(Brightness.dark),
          home: const Scaffold(body: PanSettingsBody()),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('pan-qr-start')));
      await tester.tap(find.byKey(const ValueKey('pan-qr-start')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AppGlassDialog), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(AppGlassDialog))),
        isA<PopupRoute<dynamic>>(),
      );
      expect(
        find.descendant(
          of: find.byType(PanSettingsBody),
          matching: find.byKey(const ValueKey('pan-qr-view')),
        ),
        findsNothing,
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });
}
