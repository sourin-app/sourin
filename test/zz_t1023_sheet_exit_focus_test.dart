import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    ValueNotifier<bool> visible,
    FocusNode focus,
    VoidCallback onKey, {
    bool reduceMotion = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reduceMotion),
            child: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (context, value, child) => SheetExitMotion(
                  visible: value,
                  child: Focus(
                    focusNode: focus,
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent) onKey();
                      return KeyEventResult.handled;
                    },
                    child: const SizedBox(
                      key: ValueKey('panel'),
                      width: 100,
                      height: 100,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
  }

  testWidgets(
    'exiting sheet stays painted but stops keyboard input immediately',
    (tester) async {
      final visible = ValueNotifier(true);
      final focus = FocusNode();
      var keys = 0;
      await mount(tester, visible, focus, () => keys++);
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(keys, 1);
      visible.value = false;
      await tester.pump();
      expect(find.byKey(const ValueKey('panel')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      expect(
        keys,
        1,
        reason: 'The closed sheet must not process keyboard actions while fading out.',
      );
      expect(focus.hasFocus, isFalse);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('panel')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      visible.dispose();
    },
  );

  testWidgets(
    'reopening during exit restores focus eligibility and keeps child mounted',
    (tester) async {
      final visible = ValueNotifier(true);
      final focus = FocusNode();
      var keys = 0;
      await mount(tester, visible, focus, () => keys++);
      visible.value = false;
      await tester.pump();
      visible.value = true;
      await tester.pump();
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('panel')), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(keys, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      visible.dispose();
    },
  );

  testWidgets('reduced motion removes closed sheet on first frame', (
    tester,
  ) async {
    final visible = ValueNotifier(true);
    final focus = FocusNode();
    var keys = 0;
    await mount(tester, visible, focus, () => keys++, reduceMotion: true);
    visible.value = false;
    await tester.pump();
    expect(find.byKey(const ValueKey('panel')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(keys, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
    visible.dispose();
  });
}
