import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';

const _pixels = String.fromEnvironment('SOURIN_PRESSABLE_PIXELS');
const _checkAllocation = bool.fromEnvironment(
  'SOURIN_CHECK_PRESSABLE_ALLOCATION',
  defaultValue: true,
);

int _tickerCount(WidgetTester tester) {
  final state = tester.state(find.byType(miuix.MiuixPressable));
  final properties = state.toDiagnosticsNode().getProperties();
  final tickers = properties.singleWhere((p) => p.name == 'tickers').value;
  return tickers == null ? 0 : (tickers as Set<Object>).length;
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (_pixels.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('pixels')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_pixels/$name.png');
      await file.parent.create(recursive: true);
      // Each run owns a fresh folder; never replace earlier evidence.
      if (file.existsSync()) throw StateError('Pixel evidence already exists');
      await file.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
    } finally {
      image.dispose();
    }
  });
}

Widget _host({
  required miuix.MiuixPressFeedbackType feedback,
  required VoidCallback onPressed,
  FocusNode? focusNode,
  bool enabled = true,
  bool heldDown = false,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: RepaintBoundary(
        key: const ValueKey('pixels'),
        child: miuix.MiuixPressable(
          feedbackType: feedback,
          onPressed: onPressed,
          enabled: enabled,
          heldDown: heldDown,
          focusNode: focusNode,
          semanticLabel: '播放',
          borderRadius: BorderRadius.circular(12),
          child: const ColoredBox(
            color: Color(0xFF6699BB),
            child: SizedBox(width: 180, height: 100),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  for (final feedback in miuix.MiuixPressFeedbackType.values) {
    testWidgets('${feedback.name}: visual feedback and input stay intact', (
      tester,
    ) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var calls = 0;
      await tester.pumpWidget(
        _host(feedback: feedback, onPressed: () => calls++, focusNode: focus),
      );
      if (_checkAllocation) {
        expect(_tickerCount(tester), switch (feedback) {
          miuix.MiuixPressFeedbackType.none => 1,
          miuix.MiuixPressFeedbackType.sink => 2,
          miuix.MiuixPressFeedbackType.tilt => 3,
        });
      }
      await _capture(tester, '${feedback.name}-idle');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(miuix.MiuixPressable)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await _capture(tester, '${feedback.name}-hover');
      await mouse.down(
        tester.getTopLeft(find.byType(miuix.MiuixPressable)) +
            const Offset(30, 30),
      );
      await tester.pump(const Duration(milliseconds: 110));
      await tester.pump(const Duration(milliseconds: 70));
      await _capture(tester, '${feedback.name}-pressed');
      await mouse.up();
      await tester.pumpAndSettle();
      expect(calls, 1);
      focus.requestFocus();
      await tester.pumpAndSettle();
      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.numpadEnter,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(calls, 4);
      await _capture(tester, '${feedback.name}-focus');
      await tester.pumpWidget(
        _host(
          feedback: feedback,
          onPressed: () => calls++,
          focusNode: focus,
          heldDown: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));
      await _capture(tester, '${feedback.name}-held');
      await tester.pumpWidget(
        _host(
          feedback: feedback,
          onPressed: () => calls++,
          focusNode: focus,
          enabled: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(miuix.MiuixPressable));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, 4);
      await _capture(tester, '${feedback.name}-disabled');
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('feedback can switch while a press is animating', (tester) async {
    var calls = 0;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final feedback in [
      miuix.MiuixPressFeedbackType.none,
      miuix.MiuixPressFeedbackType.sink,
      miuix.MiuixPressFeedbackType.tilt,
      miuix.MiuixPressFeedbackType.none,
      miuix.MiuixPressFeedbackType.sink,
    ]) {
      await tester.pumpWidget(
        _host(feedback: feedback, onPressed: () => calls++),
      );
      await mouse.moveTo(tester.getCenter(find.byType(miuix.MiuixPressable)));
      await mouse.down(tester.getCenter(find.byType(miuix.MiuixPressable)));
      await tester.pump(const Duration(milliseconds: 110));
      await tester.pump(const Duration(milliseconds: 40));
      await _capture(tester, 'switch-${feedback.name}-$calls');
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(calls, 5);
    if (_checkAllocation) expect(_tickerCount(tester), 4);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('feedback can switch during an active pointer and held state', (
    tester,
  ) async {
    var calls = 0;
    var feedback = miuix.MiuixPressFeedbackType.none;
    var held = false;
    late StateSetter update;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (_, setState) {
          update = setState;
          return _host(
            feedback: feedback,
            heldDown: held,
            onPressed: () => calls++,
          );
        },
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(miuix.MiuixPressable)),
    );
    await tester.pump(const Duration(milliseconds: 110));
    for (final next in [
      miuix.MiuixPressFeedbackType.sink,
      miuix.MiuixPressFeedbackType.tilt,
      miuix.MiuixPressFeedbackType.none,
    ]) {
      update(() => feedback = next);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 1);
    for (final next in [
      miuix.MiuixPressFeedbackType.sink,
      miuix.MiuixPressFeedbackType.none,
      miuix.MiuixPressFeedbackType.tilt,
    ]) {
      update(() {
        feedback = next;
        held = !held;
      });
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('lazy feedback observes TickerMode before its first allocation', (
    tester,
  ) async {
    var tickersEnabled = false;
    var held = false;
    var feedback = miuix.MiuixPressFeedbackType.none;
    late StateSetter update;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (_, setState) {
          update = setState;
          return TickerMode(
            enabled: tickersEnabled,
            child: _host(feedback: feedback, heldDown: held, onPressed: () {}),
          );
        },
      ),
    );
    update(() {
      feedback = miuix.MiuixPressFeedbackType.sink;
      held = true;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.binding.transientCallbackCount, 0);
    final sink = find.descendant(
      of: find.byType(miuix.MiuixPressable),
      matching: find.byType(Transform),
    );
    expect(tester.widget<Transform>(sink).transform.entry(0, 0), 1.0);
    update(() => tickersEnabled = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.widget<Transform>(sink).transform.entry(0, 0), lessThan(1.0));
    update(() {
      tickersEnabled = false;
      feedback = miuix.MiuixPressFeedbackType.tilt;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
