import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

class _DraftBody extends StatefulWidget {
  const _DraftBody({required this.onDisposed});
  final VoidCallback onDisposed;

  @override
  State<_DraftBody> createState() => _DraftBodyState();
}

class _DraftBodyState extends State<_DraftBody> {
  final controller = TextEditingController();
  final focus = FocusNode();

  @override
  void dispose() {
    widget.onDisposed();
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ui.TextField(
    key: const ValueKey('draft-field'),
    controller: controller,
    focusNode: focus,
  );
}

void main() {
  for (final initiallyBusy in [false, true]) {
    testWidgets(
      'dialog retains draft and focus when dismissal changes from $initiallyBusy',
      (tester) async {
        final busy = ValueNotifier(initiallyBusy);
        addTearDown(busy.dispose);
        var disposed = 0;
        var closed = 0;
        final theme = AppTheme.themeFor(Brightness.light);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (_, child) => AppThemeHost(data: theme, child: child!),
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: busy,
                builder: (_, value, child) => AppDialogShell(
                  title: '保存配置',
                  onClose: value ? null : () => closed++,
                  child: child!,
                ),
                child: _DraftBody(onDisposed: () => disposed++),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final draft = tester.state<_DraftBodyState>(find.byType(_DraftBody));
        await tester.enterText(
          find.byKey(const ValueKey('draft-field')),
          '未保存的地址',
        );
        await tester.pump();
        expect(draft.focus.hasFocus, isTrue);
        final bounds = tester.getRect(
          find.byKey(const ValueKey('draft-field')),
        );

        for (final value in [!initiallyBusy, initiallyBusy]) {
          busy.value = value;
          // A busy transition must not remove the painted content for a frame.
          await tester.pump();
          expect(find.byType(_DraftBody), findsOneWidget);
          expect(
            tester.state<_DraftBodyState>(find.byType(_DraftBody)),
            same(draft),
          );
          expect(disposed, 0);
          expect(draft.controller.text, '未保存的地址');
          expect(draft.focus.hasFocus, isTrue);
          expect(
            tester.getRect(find.byKey(const ValueKey('draft-field'))),
            bounds,
          );
          await tester.pumpAndSettle();
          final beforeClose = closed;
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          expect(closed, beforeClose + (value ? 0 : 1));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(disposed, 1);
      },
    );
  }
}
