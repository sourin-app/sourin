import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as controls;

void main() {
  testWidgets(
    'real Miuix editor focuses after ancestor double-tap completion',
    (tester) async {
      final focus = FocusNode();
      final controller = TextEditingController(text: 'Synthetic title');
      addTearDown(focus.dispose);
      addTearDown(controller.dispose);
      final theme = AppTheme.themeFor(mui.Brightness.dark)
          .copyWith(platform: TargetPlatform.windows);
      await tester.pumpWidget(
        mui.MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: mui.Scaffold(
            body: GestureDetector(
              // Same real gesture arena boundary as desktop PlayerPage.
              onTap: () {},
              onDoubleTap: () {},
              child: Center(
                child: SizedBox(
                  width: 300,
                  child: controls.TextFormField(
                    controller: controller,
                    focusNode: focus,
                    decoration: const mui.InputDecoration(hintText: '输入片名'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final actualField = find.byType(miuix.MiuixTextField);
      final editor = find.descendant(
        of: actualField,
        matching: find.byType(EditableText),
      );
      expect(actualField, findsOneWidget);
      expect(editor, findsOneWidget);
      final original = tester.element(editor);
      final actualFocus = tester.widget<EditableText>(editor).focusNode;
      expect(identical(actualFocus, focus), isTrue);
      expect(actualFocus.hasFocus, isFalse);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(5, 5));
      addTearDown(mouse.removePointer);
      try {
        final point = tester.getCenter(editor);
        await mouse.moveTo(point);
        await mouse.down(point);
        await mouse.up();
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          actualFocus.hasFocus,
          isFalse,
          reason:
              'The real ancestor still holds the single-click arena at '
              'the diagnostic driver\'s former 250 ms checkpoint',
        );

        await tester.pump(
          kDoubleTapTimeout - const Duration(milliseconds: 250),
        );
        await tester.pump();
        final firstFrame = tester.element(editor);
        await tester.pump();
        final secondFrame = tester.element(editor);
        expect(identical(original, firstFrame), isTrue);
        expect(identical(firstFrame, secondFrame), isTrue);
        expect(
          actualFocus.hasFocus,
          isTrue,
          reason:
              'The original pointer click must focus the actual editor '
              'when the double-tap deadline and frame updates finish',
        );
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    },
  );
}
