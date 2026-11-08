// The new product contract is one opaque Miuix surface, not a glass A/B delta.
// Geometry and content remain observable in both legacy call-site modes.
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';

Widget host(Widget child, Brightness mode) {
  final theme = AppTheme.themeFor(mode);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: child),
  );
}

void main() {
  for (final mode in Brightness.values) {
    testWidgets('confirmation uses one opaque Miuix card in $mode', (t) async {
      await t.pumpWidget(
        host(
          const AppGlassDialog(
            title: '确认',
            content: Text('正文'),
            actions: Text('操作'),
          ),
          mode,
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(miuix.MiuixDialogLayout), findsOneWidget);
      expect(find.byType(miuix.MiuixPopupHost), findsOneWidget);
      expect(find.byType(miuix.MiuixCard), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
      final context = t.element(find.byType(miuix.MiuixCard));
      expect(miuix.MiuixCardDefaults.defaultColors(context).color.a, 1);
      expect(find.text('正文'), findsOneWidget);
      expect(find.text('操作'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets(
      'shell surface and geometry match for both legacy glass values in $mode',
      (t) async {
        final rects = <Rect>[];
        final surfaceColors = <Color>[];
        for (final glass in [false, true]) {
          await t.pumpWidget(
            host(
              AppDialogShell(
                title: '设置',
                glass: glass,
                child: const Text('内容'),
                actions: const Text('保存'),
              ),
              mode,
            ),
          );
          await t.pumpAndSettle();
          expect(find.byType(miuix.MiuixDialogLayout), findsOneWidget);
          expect(find.byType(miuix.MiuixPopupHost), findsOneWidget);
          expect(find.byType(miuix.MiuixCard), findsOneWidget);
          expect(find.byType(GlassContainer), findsNothing);
          rects.add(t.getRect(find.byType(miuix.MiuixCard)));
          final context = t.element(find.byType(miuix.MiuixCard));
          surfaceColors.add(
            miuix.MiuixCardDefaults.defaultColors(context).color,
          );
          expect(find.text('内容'), findsOneWidget);
          expect(find.text('保存'), findsOneWidget);
        }
        expect(rects.first, rects.last);
        expect(rects.first.width, 560);
        expect(rects.first.height, lessThanOrEqualTo(620));
        expect(surfaceColors.first, surfaceColors.last);
        expect(surfaceColors.first.a, 1);
        expect(t.takeException(), isNull);
      },
    );
  }
}
