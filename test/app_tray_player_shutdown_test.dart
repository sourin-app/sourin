import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_player.dart';
import 'package:sourin_spike/core/app_tray.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

void main() {
  testWidgets('original quit and reentrant close wait for media callbacks', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('player-quit-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('tray_manager'),
      (_) async => null,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('tray_manager'),
        null,
      );
    });
    await tester.runAsync(() async {
      UiPrefs.debugResetForTest();
      await UiPrefs.load(directory.path);
      final release = Completer<void>(), started = Completer<void>();
      final owner = Object();
      var releases = 0;
      AppPlayer.lifecycle.register(owner, () {
        releases++;
        started.complete();
        return release.future;
      });
      final quitting = AppTray.instance.quitNow();
      try {
        // A missing barrier may finish quit without ever starting disposal.
        // Observe either event so the negative control fails an assertion,
        // rather than hanging forever on started.future.
        await Future.any<void>([started.future, quitting])
            .timeout(const Duration(seconds: 2));
        AppTray.instance.onWindowClose();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(calls, isNot(contains('setPreventClose')));
        expect(calls, isNot(contains('close')));
        expect(calls, isNot(contains('destroy')));
        expect(releases, 1);
        release.complete();
        await quitting;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(calls, contains('close'));
        expect(releases, 1);
        await UiPrefs.flush();
      } finally {
        if (!release.isCompleted) release.complete();
        await AppPlayer.lifecycle.shutdown();
        await quitting;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await UiPrefs.flush();
      }
    });
    expect(tester.takeException(), isNull);
  });
}
