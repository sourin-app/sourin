import 'dart:ui' show SemanticsAction;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

import 'miuix_controls_test.dart' show host;

void main() {
  for (final callbacks in [false, true]) {
    testWidgets('InkWell preserves input with callbacks=$callbacks', (
      tester,
    ) async {
      final focus = FocusNode();
      final elsewhere = FocusNode();
      addTearDown(focus.dispose);
      addTearDown(elsewhere.dispose);
      final hoverEvents = <bool>[];
      final focusEvents = <bool>[];
      var calls = 0;
      var enabled = true;
      late StateSetter update;
      const target = ValueKey('inkwell-input-target');
      await tester.pumpWidget(
        host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  return ui.InkWell(
                    key: target,
                    focusNode: focus,
                    onTap: enabled ? () => calls++ : null,
                    onHover: callbacks ? hoverEvents.add : null,
                    onFocusChange: callbacks ? focusEvents.add : null,
                    child: const SizedBox(
                      width: 120,
                      height: 60,
                      child: Text('操作'),
                    ),
                  );
                },
              ),
              Focus(focusNode: elsewhere, child: const Text('其他位置')),
            ],
          ),
        ),
      );
      final control = find.byKey(target);
      final node = tester.getSemantics(control);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 10,
      );
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(control));
      await tester.pumpAndSettle();
      if (callbacks) expect(hoverEvents, [true]);
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(calls, 1);

      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(focus.hasPrimaryFocus, isTrue);
      if (callbacks) expect(focusEvents.last, isTrue);
      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.select,
      ]) {
        final before = calls;
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(calls, before + 1, reason: key.debugName);
      }
      elsewhere.requestFocus();
      await tester.pumpAndSettle();
      if (callbacks) expect(focusEvents.last, isFalse);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      if (callbacks) expect(hoverEvents, [true, false]);

      update(() => enabled = false);
      await tester.pumpAndSettle();
      await tester.tap(control);
      await tester.pumpAndSettle();
      expect(calls, 5);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });
  }
}
