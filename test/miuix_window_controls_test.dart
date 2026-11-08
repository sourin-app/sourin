import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart' show SourinApp;
import 'package:sourin_spike/ui/titlebar_visibility.dart';

import 'support/follow_fixture.dart';

Color _paintedBackground(WidgetTester tester, Finder button) {
  final surfaces = find.descendant(
    of: button,
    matching: find.byType(DecoratedBox),
  );
  return tester
      .renderObjectList<RenderDecoratedBox>(surfaces)
      .map((box) => box.decoration)
      .whereType<ShapeDecoration>()
      .single
      .color!;
}

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    // Use the production app/root titlebar without mounting the remote server.
    Device.overrideKind(DeviceKind.touchOnly);
    SourinCore.debugCallAsyncTransport = followFixtureTransport;
    titleBarVisible.value = true;
  });
  tearDown(() {
    Device.overrideKind(null);
    SourinCore.debugCallAsyncTransport = null;
    titleBarDark.value = false;
    UiPrefs.debugResetForTest();
  });

  for (final dark in [false, true]) {
    testWidgets(
      'production Miuix titlebar paints window hover states / dark=$dark',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);
        titleBarDark.value = dark;
        final methods = <String>[];
        const channel = MethodChannel('window_manager');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            methods.add(call.method);
            return call.method == 'isMaximized' ? false : null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          const SourinApp(coreError: 'PathAccessException: Permission denied'),
        );
        await tester.pumpAndSettle();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(100, 100));
        addTearDown(mouse.removePointer);

        for (final name in ['minimize', 'maximize', 'close']) {
          final windowButton = find.byKey(ValueKey('shell-window-$name'));
          expect(windowButton, findsOneWidget);
          final button = find.descendant(
            of: windowButton,
            matching: find.byType(miuix.MiuixIconButton),
          );
          expect(button, findsOneWidget);
          expect(_paintedBackground(tester, button), Colors.transparent);
          final initialIcon = tester
              .widget<Icon>(
                find.descendant(of: button, matching: find.byType(Icon)),
              )
              .color!;
          await mouse.moveTo(tester.getCenter(button));
          await tester.pumpAndSettle();
          final expected = name == 'close'
              ? const Color(0xFFE81123)
              : dark
              ? Colors.white24
              : initialIcon.withValues(alpha: .12);
          expect(_paintedBackground(tester, button), expected);
          final hoverIcon = tester
              .widget<Icon>(
                find.descendant(of: button, matching: find.byType(Icon)),
              )
              .color;
          expect(hoverIcon, name == 'close' ? Colors.white : initialIcon);
          await mouse.moveTo(const Offset(100, 100));
          await tester.pumpAndSettle();
          expect(_paintedBackground(tester, button), Colors.transparent);
        }

        await tester.tap(find.byKey(const ValueKey('shell-window-close')));
        await tester.pump();
        expect(methods.where((method) => method == 'close'), hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
}
