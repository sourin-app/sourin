import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/pan_web_login.dart';
import 'package:sourin_spike/ui/widgets/pan_login_session.dart';

import 't20261104_pan_login_ux_session_test.dart' as fixture;

void main() {
  const channel = MethodChannel('sourin/pan-web-login');
  Future<void> confirm(int id) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('confirm', {'browserId': id}),
          ),
          (_) {},
        );
  }

  testWidgets('native save failure reports error and confirmation retries', (
    tester,
  ) async {
    final states = <String>[];
    var saves = 0;
    final window = fixture.LocalWindow(
      () async => const [
        CapturedCookie(
          domain: '.baidu.com',
          name: 'BDUSS',
          value: 'synthetic-session',
        ),
      ],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          states.add((call.arguments as Map)['state'] as String);
          return null;
        });
    debugPanLoginCommandCaller = (command, _) async {
      if (command == 'pan_save_credential') return {'ok': ++saves > 1};
      return fixture.status(kind: 'baidu');
    };
    try {
      await tester.pumpWidget(
        fixture.host(
          PanWebLoginWaitingDialog(
            webview: window,
            spec: PanWebLoginSpec.of('baidu')!,
            nativeBrowserId: 42,
            initialAuthKeys: const {'BDUSS': 'synthetic-session'},
          ),
        ),
      );
      await confirm(42);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(states.last, 'error');
      expect(saves, 1);
      await confirm(42);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(saves, 2);
      expect(window.closes, greaterThan(0));
    } finally {
      await tester.pumpWidget(const SizedBox());
      debugPanLoginCommandCaller = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
  testWidgets('native confirmation during background read is preserved once', (
    tester,
  ) async {
    final pending = Completer<List<CapturedCookie>>();
    const cookies = [
      CapturedCookie(
        domain: '.baidu.com',
        name: 'BDUSS',
        value: 'synthetic-session',
      ),
    ];
    final window = fixture.LocalWindow(() => pending.future);
    final commands = <String>[];
    final states = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          states.add((call.arguments as Map)['state'] as String);
          return null;
        });
    debugPanLoginCommandCaller = (command, _) async {
      commands.add(command);
      return command == 'pan_save_credential'
          ? {'ok': true}
          : fixture.status(kind: 'baidu');
    };
    try {
      await tester.pumpWidget(
        fixture.host(
          PanWebLoginWaitingDialog(
            webview: window,
            spec: PanWebLoginSpec.of('baidu')!,
            nativeBrowserId: 42,
            initialAuthKeys: const {'BDUSS': 'synthetic-session'},
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(states, isNot(contains('busy')));
      await confirm(42);
      await confirm(42);
      window.reader = () async => cookies;
      pending.complete(cookies);
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(commands, ['pan_save_credential', 'pan_auth_status']);
      await tester.pumpWidget(const SizedBox());
      await confirm(42);
      await tester.pump();
      expect(commands.length, 2);
    } finally {
      await tester.pumpWidget(const SizedBox());
      debugPanLoginCommandCaller = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets(
    'native completion rereads and recognizes unchanged browser session',
    (tester) async {
      final commands = <String>[];
      final window = fixture.LocalWindow(
        () async => const [
          CapturedCookie(
            domain: '.baidu.com',
            name: 'BDUSS',
            value: 'synthetic-session',
          ),
        ],
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      debugPanLoginCommandCaller = (command, _) async {
        commands.add(command);
        return command == 'pan_save_credential'
            ? {'ok': true}
            : fixture.status(kind: 'baidu');
      };
      try {
        await tester.pumpWidget(
          fixture.host(
            PanWebLoginWaitingDialog(
              webview: window,
              spec: PanWebLoginSpec.of('baidu')!,
              nativeBrowserId: 42,
              initialAuthKeys: const {'BDUSS': 'synthetic-session'},
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(commands, isEmpty);
        await confirm(99);
        await tester.pump();
        expect(commands, isEmpty);
        await confirm(42);
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        expect(commands, ['pan_save_credential', 'pan_auth_status']);
        expect(window.reads, greaterThan(1));
      } finally {
        await tester.pumpWidget(const SizedBox());
        debugPanLoginCommandCaller = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
}
