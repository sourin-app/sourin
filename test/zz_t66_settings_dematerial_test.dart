// The settings migration changes the component contract from glass wrappers to
// real Miuix controls. These assertions inspect mounted controls and behavior.
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/theme/miuix_palette.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 'package:sourin_spike/ui/widgets/settings_dropdown.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: AppScaffold(child: child),
  );
}

void main() {
  setUp(UiPrefs.debugResetForTest);
  tearDown(UiPrefs.debugResetForTest);

  for (final brightness in Brightness.values) {
    testWidgets(
      'settings source groups use painted Miuix cards and working actions in $brightness',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 700);
        addTearDown(tester.view.reset);
        var configured = 0;
        var expanded = false;
        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  SourceClassHeader(
                    label: 'TVBox 聚合源',
                    count: 1,
                    onConfigure: () => configured++,
                  ),
                  TvboxGroupHeader(
                    count: 3,
                    expanded: expanded,
                    onToggle: () => setState(() => expanded = !expanded),
                    onConfigure: () => configured++,
                  ),
                ],
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        final cards = find.byType(miuix.MiuixCard);
        expect(cards, findsWidgets);
        final painted = find.descendant(
          of: cards.first,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox && widget.decoration is ShapeDecoration,
          ),
        );
        expect(painted, findsWidgets);
        final decoration =
            tester.widget<DecoratedBox>(painted.first).decoration
                as ShapeDecoration;
        expect(
          decoration.color,
          miuixThemeData(brightness).colors.surfaceContainer,
        );
        expect(find.byType(miuix.MiuixButton), findsNWidgets(2));
        await tester.tap(find.byKey(const ValueKey('source-class-configure')));
        await tester.pump();
        expect(configured, 1);
        await tester.tap(find.byKey(const ValueKey('tvbox-group-configure')));
        await tester.pump();
        expect(configured, 2);
        expect(
          expanded,
          isFalse,
          reason: 'nested configure action must not also toggle the group',
        );
        await tester.tap(
          find.byKey(const ValueKey('tvbox-group-toggle-label')),
        );
        await tester.pump();
        expect(expanded, isTrue);
        expect(find.text('收起'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'settings dropdown uses one Miuix popup path and returns nullable choices',
    (tester) async {
      bool? value = true;
      final changes = <bool?>[];
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.topLeft,
              child: SettingsDropdown<bool?>(
                value: value,
                options: const [
                  SettingsDropdownOption(null, '全部状态'),
                  SettingsDropdownOption(true, '已启用'),
                  SettingsDropdownOption(false, '已停用'),
                ],
                onChanged: (next) => setState(() {
                  value = next;
                  changes.add(next);
                }),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixButton), findsOneWidget);
      await tester.tap(find.text('已启用'));
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixWindowListPopup), findsOneWidget);
      await tester.tap(find.text('全部状态'));
      await tester.pumpAndSettle();
      expect(changes, [null]);
      expect(find.text('全部状态'), findsOneWidget);

      // The restored trigger focus supports the same route with remote Select.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixWindowListPopup), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(changes, [null, true]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Miuix settings dialog accepts typed text and returns the submitted value',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      BuildContext? opener;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              opener = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final result = showAppDialog<String>(
        context: opener!,
        builder: (context) => AppGlassDialog(
          title: '修改名称',
          content: ui.TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          actions: ui.TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixTextField), findsOneWidget);
      await tester.enterText(find.byType(EditableText), '新的名称');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(await result, '新的名称');
      expect(find.byType(AppGlassDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
