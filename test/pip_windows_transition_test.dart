// PipController selects Windows with dart:io, so these channel fixtures run on
// Windows. Native geometry/visibility is outside this headless test's scope.
@TestOn('windows')
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/pip.dart';

import 'support/pip_window_mock.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final controller = PipController.instance;
  late PipWindowMock window;
  late List<bool> notifications;
  void listener(bool active) => notifications.add(active);

  setUp(() async {
    window = PipWindowMock();
    notifications = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      window.handle,
    );
    controller.onNativeStateChanged(false);
    controller.addListener(listener);
  });

  tearDown(() async {
    window.releaseGate();
    window.clearFailures();
    expect(await controller.exit(), isTrue);
    controller.removeListener(listener);
    expect(controller.isActive, isFalse);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
  });

  // This runs before any probe on the singleton, and queues exit immediately
  // without waiting for a window-method gate or the entering Future.
  test('immediate first-probe enter then exit follows call order', () async {
    final original = window.snapshot();
    final entering = controller.enter();
    final exiting = controller.exit();
    expect(await Future.wait([entering, exiting]), [true, true]);
    expect(window.snapshot(), equals(original));
    expect(controller.isActive, isFalse);
    expect(notifications, [true, false]);
  });

  test('immediate toggle then exit follows call order', () async {
    final original = window.snapshot();
    final toggling = controller.toggle();
    final exiting = controller.exit();
    expect(await Future.wait([toggling, exiting]), [true, true]);
    expect(window.snapshot(), equals(original));
    expect(notifications, [true, false]);
  });

  test(
    'immediate enter exit enter preserves order and last aspect ratio',
    () async {
      final original = window.snapshot();
      final first = controller.enter();
      final second = controller.exit();
      final third = controller.enter(aspectRatio: 1);
      expect(await Future.wait([first, second, third]), [true, true, true]);
      expect(window.size, const Size(420, 420));
      expect(window.counts['getBounds'], 4);
      expect(await controller.exit(), isTrue);
      expect(window.snapshot(), equals(original));
      expect(notifications, [true, false, true, false]);
    },
  );

  test('immediate two toggles restore original state', () async {
    final original = window.snapshot();
    final first = controller.toggle();
    final second = controller.toggle();
    expect(await Future.wait([first, second]), [true, true]);
    expect(window.snapshot(), equals(original));
    expect(notifications, [true, false]);
  });

  for (final topmost in [false, true]) {
    for (final resizable in [false, true]) {
      for (final taskbar in [false, true]) {
        test(
          'normal restores original topmost=$topmost resizable=$resizable skipTaskbar=$taskbar',
          () async {
            window.alwaysOnTop = topmost;
            window.resizable = resizable;
            window.skipTaskbar = taskbar;
            final original = window.snapshot();
            expect(await controller.enter(), isTrue);
            expect(controller.isActive, isTrue);
            expect(window.size, const Size(420, 236.25));
            expect(window.minimumSize, Size.zero);
            expect(window.alwaysOnTop, isTrue);
            expect(window.resizable, isFalse);
            expect(window.skipTaskbar, isTrue);
            window.position = const Offset(401.5, 209.25);
            expect(await controller.exit(), isTrue);
            expect(window.snapshot(), equals(original));
            expect(notifications, [true, false]);
          },
        );
      }
    }
  }

  for (final value in [(0.1, 640.0), (100.0, 160.0), (1.0, 420.0)]) {
    test('entry clamps height for aspect ratio ${value.$1}', () async {
      expect(await controller.enter(aspectRatio: value.$1), isTrue);
      expect(window.size, Size(420, value.$2));
    });
  }

  for (final getter in [
    ('getBounds', 1),
    ('getBounds', 2),
    ('isAlwaysOnTop', 1),
    ('isResizable', 1),
    ('isSkipTaskbar', 1),
  ]) {
    test(
      'snapshot failure ${getter.$1}/${getter.$2} changes no window properties',
      () async {
        final original = window.snapshot();
        window.failNext(getter.$1, occurrence: getter.$2);
        expect(await controller.enter(), isFalse);
        expect(window.snapshot(), equals(original));
        expect(
          window.calls.where(
            (call) => (call['method']! as String).startsWith('set'),
          ),
          isEmpty,
        );
        expect(await controller.exit(), isTrue);
        expect(notifications, isEmpty);
      },
    );
  }

  for (final setter in [
    'setMinimumSize:zero',
    'setBounds:size',
    'setAlwaysOnTop:true',
    'setResizable:false',
  ]) {
    for (final afterMutation in [false, true]) {
      test(
        'entry failure $setter afterMutation=$afterMutation rolls back full snapshot',
        () async {
          final original = window.snapshot();
          window.failNext(setter, afterMutation: afterMutation);
          expect(await controller.enter(), isFalse);
          expect(controller.isActive, isFalse);
          expect(window.snapshot(), equals(original));
          expect(await controller.exit(), isTrue);
          expect(window.snapshot(), equals(original));
          expect(notifications, isEmpty);
          window.save('entry-${setter.replaceAll(':', '-')}-$afterMutation', {
            'original': original,
            'afterExit': window.snapshot(),
            'recovered': true,
          });
        },
      );
    }
  }

  for (final afterMutation in [false, true]) {
    test(
      'entry taskbar failure remains optional afterMutation=$afterMutation',
      () async {
        final original = window.snapshot();
        window.failNext('setSkipTaskbar:true', afterMutation: afterMutation);
        expect(await controller.enter(), isTrue);
        expect(window.alwaysOnTop, isTrue);
        expect(await controller.exit(), isTrue);
        expect(window.snapshot(), equals(original));
      },
    );
  }

  test(
    'inactive failed enter and failed rollback remain recoverable by exit',
    () async {
      final original = window.snapshot();
      window.failNext('setResizable:false');
      window.failNext('setAlwaysOnTop:false');
      expect(await controller.enter(), isFalse);
      expect(controller.isActive, isFalse);
      expect(window.alwaysOnTop, isTrue);
      expect(window.size, const Size(420, 236.25));
      expect(await controller.exit(), isTrue);
      expect(window.snapshot(), equals(original));
      expect(notifications, isEmpty);
      window.save('inactive-exit-retry', {
        'original': original,
        'restored': window.snapshot(),
      });
    },
  );

  test(
    'new enter restores pending snapshot before capturing another snapshot',
    () async {
      final original = window.snapshot();
      window.failNext('setResizable:false');
      window.failNext('setAlwaysOnTop:false');
      expect(await controller.enter(), isFalse);
      window.failNext('setAlwaysOnTop:false');
      expect(await controller.enter(), isFalse);
      expect(window.counts['getBounds'], 2);
      expect(await controller.enter(), isTrue);
      expect(window.counts['getBounds'], 4);
      expect(await controller.exit(), isTrue);
      expect(window.snapshot(), equals(original));
    },
  );

  for (final setter in [
    ('setResizable:true', 1),
    ('setAlwaysOnTop:false', 1),
    ('setBounds:size', 1),
    ('setBounds:position', 1),
    ('setSkipTaskbar:false', 1),
    ('setMinimumSize:restore', 1),
    ('setResizable:true', 2),
  ]) {
    for (final afterMutation in [false, true]) {
      test(
        'exit failure ${setter.$1}/${setter.$2} afterMutation=$afterMutation retries full snapshot',
        () async {
          final original = window.snapshot();
          expect(await controller.enter(), isTrue);
          window.position = const Offset(488, 315);
          window.failNext(
            setter.$1,
            occurrence: setter.$2,
            afterMutation: afterMutation,
          );
          expect(await controller.exit(), isFalse);
          expect(controller.isActive, isTrue);
          expect(notifications, [true]);
          expect(await controller.exit(), isTrue);
          expect(window.snapshot(), equals(original));
          expect(notifications, [true, false]);
        },
      );
    }
  }

  test(
    'repeated enter keeps original snapshot and repeated exit is a no-op',
    () async {
      final original = window.snapshot();
      expect(await controller.enter(), isTrue);
      final entryCalls = window.calls.length;
      expect(await controller.enter(aspectRatio: 1), isTrue);
      expect(window.calls.length, entryCalls);
      expect(await controller.exit(), isTrue);
      expect(window.snapshot(), equals(original));
      final exitCalls = window.calls.length;
      expect(await controller.exit(), isTrue);
      expect(window.calls.length, exitCalls);
      expect(notifications, [true, false]);
    },
  );

  test(
    'concurrent enter and exit execute in order and restore original state',
    () async {
      final original = window.snapshot();
      window.blockNext('setAlwaysOnTop:true');
      final entering = controller.enter();
      await window.gateReached!.future;
      final callsAtGate = window.calls.length;
      final exiting = controller.exit();
      await Future<void>.delayed(Duration.zero);
      expect(window.calls.length, callsAtGate);
      window.releaseGate();
      expect(await Future.wait([entering, exiting]), [true, true]);
      expect(window.snapshot(), equals(original));
      expect(notifications, [true, false]);
    },
  );

  test('concurrent enters capture one snapshot', () async {
    final original = window.snapshot();
    window.blockNext('setAlwaysOnTop:true');
    final first = controller.enter();
    await window.gateReached!.future;
    final second = controller.enter();
    window.releaseGate();
    expect(await Future.wait([first, second]), [true, true]);
    expect(window.counts['getBounds'], 2);
    expect(notifications, [true]);
    expect(await controller.exit(), isTrue);
    expect(window.snapshot(), equals(original));
  });

  test('concurrent exits restore once', () async {
    final original = window.snapshot();
    expect(await controller.enter(), isTrue);
    window.blockNext('setAlwaysOnTop:false');
    final first = controller.exit();
    await window.gateReached!.future;
    final second = controller.exit();
    window.releaseGate();
    expect(await Future.wait([first, second]), [true, true]);
    expect(window.counts['setMinimumSize:restore'], 1);
    expect(window.snapshot(), equals(original));
    expect(notifications, [true, false]);
  });

  test(
    'concurrent toggles decide activity inside their ordered transition',
    () async {
      final original = window.snapshot();
      window.blockNext('setAlwaysOnTop:true');
      final first = controller.toggle();
      await window.gateReached!.future;
      final second = controller.toggle();
      window.releaseGate();
      expect(await Future.wait([first, second]), [true, true]);
      expect(window.snapshot(), equals(original));
      expect(controller.isActive, isFalse);
      expect(notifications, [true, false]);
    },
  );

  test(
    'queued enter exit enter toggles use successive complete states',
    () async {
      final original = window.snapshot();
      window.blockNext('setAlwaysOnTop:true');
      final first = controller.enter();
      await window.gateReached!.future;
      final second = controller.exit();
      final third = controller.enter(aspectRatio: 1);
      window.releaseGate();
      expect(await Future.wait([first, second, third]), [true, true, true]);
      expect(window.size, const Size(420, 420));
      expect(window.counts['getBounds'], 4);
      expect(await controller.exit(), isTrue);
      expect(window.snapshot(), equals(original));
      expect(notifications, [true, false, true, false]);
    },
  );

  test(
    'queued exit retries after earlier exit failure without breaking queue',
    () async {
      final original = window.snapshot();
      expect(await controller.enter(), isTrue);
      window.blockNext('setAlwaysOnTop:false');
      window.failNext('setBounds:position');
      final first = controller.exit();
      await window.gateReached!.future;
      final second = controller.exit();
      window.releaseGate();
      expect(await Future.wait([first, second]), [false, true]);
      expect(window.snapshot(), equals(original));
      expect(notifications, [true, false]);
    },
  );
}
