import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 'package:sourin_spike/ui/widgets/pan_login_session.dart';
import 'package:sourin_spike/ui/widgets/pan_qr_login_dialog.dart';
import 'package:sourin_spike/ui/widgets/pan_web_login.dart';

Map<String, dynamic> status({
  String kind = 'quark',
  bool loggedIn = true,
  bool expired = false,
  bool keyringAvailable = true,
}) => {
  'accounts': [
    {
      'kind': kind,
      'loggedIn': loggedIn,
      'expired': expired,
      'keyringAvailable': keyringAvailable,
      'account': 'local-test-account',
    },
  ],
};

class LocalWindow implements PanWebLoginWindow {
  LocalWindow(this.reader);
  Future<List<CapturedCookie>> Function() reader;
  Object? closeError;
  final closed = Completer<void>();
  int reads = 0;
  int closes = 0;
  @override
  Future<void> get onClose => closed.future;
  @override
  Future<void> close() async {
    closes++;
    if (!closed.isCompleted) closed.complete();
    if (closeError case final Object error) throw error;
  }

  @override
  Future<List<CapturedCookie>> readCookies() {
    reads++;
    return reader();
  }
}

const cookies = [
  CapturedCookie(domain: '.quark.cn', name: '__pus', value: 'local-test-value'),
  CapturedCookie(domain: '.quark.cn', name: '__kps', value: 'local-test-value'),
];
const qr = {
  'key': 'local-test-key',
  'svg':
      '<svg viewBox="0 0 21 21"><path fill="#000000" d="M0 0h1v1H0z"/></svg>',
  'url': '',
};

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.themeFor(Brightness.dark),
  home: Scaffold(body: child),
);

Future<void> openWeb(WidgetTester tester, LocalWindow window) async {
  await tester.pumpWidget(
    host(
      Builder(
        builder: (context) {
          return TextButton(
            onPressed: () => showAppDialog<bool>(
              context: context,
              builder: (_) => PanWebLoginWaitingDialog(
                webview: window,
                spec: PanWebLoginSpec.of('quark')!,
                initialAuthKeys: const {},
              ),
            ),
            child: const Text('open'),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  tearDown(() => debugPanLoginCommandCaller = null);

  test('untrusted login errors do not expose credential text or log it', () {
    final originalPrint = debugPrint;
    final logs = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      const fallback = '登录检测失败，请重新检测';
      final text = panLoginErrorText(
        StateError('BDUSS=local-test-secret; https://local.test/session'),
        fallback: fallback,
      );
      expect(text, fallback);
      expect(logs, isEmpty);
    } finally {
      debugPrint = originalPrint;
    }
  });

  test('save must succeed before backend status is read', () async {
    final commands = <String>[];
    await expectLater(
      saveAndRecognizePanWebLogin(
        kind: 'quark',
        cookie: 'local-test-cookie',
        caller: (command, arguments) async {
          commands.add(command);
          return {'ok': false};
        },
      ),
      throwsA(isA<PanLoginFlowException>()),
    );
    expect(commands, ['pan_save_credential']);
  });

  test('save success alone never confirms application recognition', () async {
    for (final response in [
      status(loggedIn: false),
      status(expired: true),
      status(kind: 'baidu'),
      status(keyringAvailable: false),
      {'accounts': []},
    ]) {
      await expectLater(
        saveAndRecognizePanWebLogin(
          kind: 'quark',
          cookie: 'local-test-cookie',
          caller: (command, arguments) async =>
              command == 'pan_save_credential' ? {'ok': true} : response,
        ),
        throwsA(isA<PanLoginFlowException>()),
      );
    }
  });

  test(
    'valid save is followed by authoritative local status readback',
    () async {
      final commands = <String>[];
      final result = await saveAndRecognizePanWebLogin(
        kind: 'quark',
        cookie: 'local-test-cookie',
        caller: (command, arguments) async {
          commands.add(command);
          return command == 'pan_save_credential' ? {'ok': true} : status();
        },
      );
      expect(commands, ['pan_save_credential', 'pan_auth_status']);
      expect(result.account, 'local-test-account');
    },
  );

  test('cancelled generation cannot begin a credential write', () async {
    var calls = 0;
    await expectLater(
      saveAndRecognizePanWebLogin(
        kind: 'quark',
        cookie: 'local-test-cookie',
        isCurrent: () => false,
        caller: (_, __) async {
          calls++;
          return {'ok': true};
        },
      ),
      throwsA(isA<PanLoginFlowException>()),
    );
    expect(calls, 0);
  });

  test(
    'cancel during existing save does not read status or confirm success',
    () async {
      final save = Completer<dynamic>();
      var current = true;
      final commands = <String>[];
      final result = saveAndRecognizePanWebLogin(
        kind: 'quark',
        cookie: 'local-test-cookie',
        isCurrent: () => current,
        caller: (command, _) {
          commands.add(command);
          return save.future;
        },
      );
      final assertion = expectLater(
        result,
        throwsA(isA<PanLoginFlowException>()),
      );
      current = false;
      save.complete({'ok': true});
      await assertion;
      expect(commands, ['pan_save_credential']);
    },
  );

  testWidgets('web cookie read error stops and offers explicit recheck', (
    tester,
  ) async {
    final window = LocalWindow(
      () async => throw StateError('local-test-secret'),
    );
    try {
      await openWeb(tester, window);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('pan-web-login-error')), findsOneWidget);
      expect(find.textContaining('local-test-secret'), findsNothing);
      final reads = window.reads;
      await tester.pump(const Duration(seconds: 10));
      expect(window.reads, reads);
      window.reader = () async => const [];
      await tester.tap(find.byKey(const ValueKey('pan-web-login-recheck')));
      await tester.pump();
      expect(window.reads, greaterThan(reads));
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a hanging cookie read is bounded and cannot overlap', (
    tester,
  ) async {
    final read = Completer<List<CapturedCookie>>();
    final window = LocalWindow(() => read.future);
    try {
      await openWeb(tester, window);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 10));
      expect(window.reads, 1);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(find.byKey(const ValueKey('pan-web-login-error')), findsOneWidget);
      expect(window.reads, 1);
    } finally {
      read.complete(const []);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('pending web recheck owns a fresh full timeout period', (
    tester,
  ) async {
    final window = LocalWindow(() async => const []);
    try {
      await openWeb(tester, window);
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(find.byKey(const ValueKey('pan-web-login-error')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('pan-web-login-recheck')));
      await tester.pump();
      final reads = window.reads;
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(find.byKey(const ValueKey('pan-web-login-error')), findsNothing);
      expect(window.reads, greaterThan(reads));
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(find.byKey(const ValueKey('pan-web-login-error')), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('close before capture completes cannot save credentials', (
    tester,
  ) async {
    final read = Completer<List<CapturedCookie>>();
    final window = LocalWindow(() => read.future);
    var commands = 0;
    debugPanLoginCommandCaller = (_, __) async {
      commands++;
      return status();
    };
    await openWeb(tester, window);
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byKey(const ValueKey('pan-web-login-cancel')));
    await tester.pump(const Duration(milliseconds: 400));
    read.complete(cookies);
    await tester.pump();
    expect(commands, 0);
    expect(window.closes, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native close failures do not escape the login cleanup', (
    tester,
  ) async {
    final window = LocalWindow(() async => const [])
      ..closeError = StateError('local-test-close-secret');
    await openWeb(tester, window);
    await tester.tap(find.byKey(const ValueKey('pan-web-login-cancel')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(window.closes, greaterThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'web saved-but-unrecognized result stays open with actionable error',
    (tester) async {
      final window = LocalWindow(() async => cookies);
      debugPanLoginCommandCaller = (command, _) async =>
          command == 'pan_save_credential'
          ? {'ok': true}
          : status(loggedIn: false);
      try {
        await openWeb(tester, window);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('pan-web-login-error')),
          findsOneWidget,
        );
        expect(find.textContaining('应用尚未识别'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('pan-web-login-recheck')),
          findsOneWidget,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('QR expiry clears the code and retry requests a fresh session', (
    tester,
  ) async {
    var starts = 0;
    Future<dynamic> caller(String command, Map<String, dynamic> _) async {
      if (command == 'pan_qr_login_start') {
        starts++;
        return qr;
      }
      return {'status': 'expired'};
    }

    try {
      await tester.pumpWidget(
        host(PanQrLoginDialog(kind: 'quark', commandCaller: caller)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const ValueKey('pan-qr-login-view')), findsNothing);
      expect(find.textContaining('二维码已失效'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pan-qr-login-retry')));
      await tester.pump();
      expect(starts, 2);
      expect(find.byKey(const ValueKey('pan-qr-login-view')), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('QR confirmed still requires recognized backend status', (
    tester,
  ) async {
    final commands = <String>[];
    Future<dynamic> caller(String command, Map<String, dynamic> _) async {
      commands.add(command);
      return switch (command) {
        'pan_qr_login_start' => qr,
        'pan_qr_login_poll' => {'status': 'confirmed'},
        _ => status(loggedIn: false),
      };
    }

    try {
      await tester.pumpWidget(
        host(PanQrLoginDialog(kind: 'quark', commandCaller: caller)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(commands, [
        'pan_qr_login_start',
        'pan_qr_login_poll',
        'pan_auth_status',
      ]);
      expect(find.textContaining('应用尚未识别'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('QR rendering failure never displays a session URL', (
    tester,
  ) async {
    Future<dynamic> caller(String command, Map<String, dynamic> _) async => {
      'key': 'local-test-key',
      'svg': '',
      'url': 'https://local.test/?token=local-test-session-secret',
    };
    try {
      await tester.pumpWidget(
        host(PanQrLoginDialog(kind: '115', commandCaller: caller)),
      );
      await tester.pump();
      expect(find.textContaining('local-test-session-secret'), findsNothing);
      expect(find.text('二维码无法显示，请重新获取'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
    }
  });
}
