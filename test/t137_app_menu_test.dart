// Miuix replaces the former Material popup surface; menu behavior stays public.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_menu.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

Widget host(Widget child, {Brightness brightness = Brightness.light}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: Center(child: child)),
  );
}

const normalItems = [
  AppMenuItem(value: 'a', label: '调整顺序', icon: Icons.reorder),
  AppMenuItem(
    value: 'b',
    label: '移除',
    icon: Icons.delete_outline,
    danger: true,
  ),
];

Future<void> open(
  WidgetTester t, {
  Brightness brightness = Brightness.light,
  List<AppMenuItem<String>> items = normalItems,
  ValueChanged<String>? selected,
}) async {
  await t.pumpWidget(
    host(
      AppMenuButton<String>(items: items, onSelected: selected ?? (_) {}),
      brightness: brightness,
    ),
  );
  await t.tap(find.byType(AppMenuButton<String>));
  await t.pumpAndSettle();
  expect(find.byType(miuix.MiuixWindowListPopup), findsOneWidget);
  expect(find.byType(miuix.MiuixListPopupContent), findsOneWidget);
}

void main() {
  test('source and detail menus keep the shared entry points', () {
    final settings = File('lib/ui/settings_page.dart').readAsStringSync();
    final detail = File('lib/ui/detail_page.dart').readAsStringSync();
    expect(settings, contains('AppMenuButton<String>('));
    expect(detail, contains('showAppMenu<String>('));
  });

  testWidgets('both theme modes render one actual Miuix popup card', (t) async {
    final renderedColors = <Color>[];
    for (final brightness in Brightness.values) {
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      await open(t, brightness: brightness);
      expect(find.byType(miuix.MiuixCard), findsOneWidget);
      final cardContext = t.element(find.byType(miuix.MiuixCard));
      final card = t.widget<miuix.MiuixCard>(find.byType(miuix.MiuixCard));
      final colors =
          card.colors ?? miuix.MiuixCardDefaults.defaultColors(cardContext);
      renderedColors.add(colors.color);
      expect(colors.color.a, 1);
      final rect = t.getRect(find.byType(miuix.MiuixCard));
      expect(rect.width, inInclusiveRange(160, 260));
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      expect(find.text('调整顺序'), findsNothing);
    }
    expect(renderedColors.first, isNot(renderedColors.last));
  });

  testWidgets('dangerous labels and icons share the error color', (t) async {
    await open(t, brightness: Brightness.dark);
    final error = AppTheme.themeFor(Brightness.dark).colorScheme.error;
    expect(t.widget<Text>(find.text('移除')).style?.color, error);
    expect(t.widget<Icon>(find.byIcon(Icons.delete_outline)).color, error);
    expect(t.widget<Icon>(find.byIcon(Icons.reorder)).color, isNot(error));
    expect(find.byType(miuix.MiuixBasicComponent), findsNWidgets(2));
  });

  testWidgets('selection returns the original value and closes the popup', (
    t,
  ) async {
    String? picked;
    await open(t, selected: (value) => picked = value);
    await t.tap(find.text('移除'));
    await t.pumpAndSettle();
    expect(picked, 'b');
    expect(find.text('移除'), findsNothing);
  });

  testWidgets('disabled entries cannot dispatch a selection', (t) async {
    var calls = 0;
    await open(
      t,
      items: const [
        AppMenuItem(value: 'busy', label: '处理中…', enabled: false),
        AppMenuItem(value: 'ok', label: '可用'),
      ],
      selected: (_) => calls++,
    );
    await t.tap(find.text('处理中…'));
    await t.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('可用'), findsOneWidget);
    await t.tap(find.text('可用'));
    await t.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('custom child content is preserved and returns its value', (
    t,
  ) async {
    String? picked;
    await open(
      t,
      items: const [
        AppMenuItem(
          value: 'custom',
          child: Row(children: [Icon(Icons.edit), Text('自定义内容')]),
        ),
      ],
      selected: (value) => picked = value,
    );
    expect(find.byIcon(Icons.edit), findsOneWidget);
    await t.tap(find.text('自定义内容'));
    await t.pumpAndSettle();
    expect(picked, 'custom');
  });

  testWidgets('arrow navigation skips disabled rows and Enter selects', (
    t,
  ) async {
    String? picked;
    await open(
      t,
      items: const [
        AppMenuItem(value: 'a', label: '第一项'),
        AppMenuItem(value: 'b', label: '禁用项', enabled: false),
        AppMenuItem(value: 'c', label: '第三项'),
      ],
      selected: (value) => picked = value,
    );
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(picked, 'c');
    expect(find.text('第三项'), findsNothing);
  });

  testWidgets('Escape dismisses and returns focus to the invoking control', (
    t,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    String? result = 'pending';
    await t.pumpWidget(
      host(
        Builder(
          builder: (context) => ui.TextButton(
            focusNode: focus,
            autofocus: true,
            onPressed: () async {
              result = await showAppMenu<String>(
                context: context,
                position: const RelativeRect.fromLTRB(120, 160, 500, 400),
                items: normalItems,
                initialValue: 'b',
              );
            },
            child: const Text('打开菜单'),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(find.text('移除'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(result, isNull);
    expect(focus.hasFocus, isTrue);
    expect(find.text('移除'), findsNothing);
  });

  testWidgets('menu near the lower right edge stays inside the viewport', (
    t,
  ) async {
    t.view.physicalSize = const Size(800, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        Builder(
          builder: (context) => ui.TextButton(
            onPressed: () => showAppMenu<String>(
              context: context,
              position: const RelativeRect.fromLTRB(780, 580, 0, 0),
              items: normalItems,
            ),
            child: const Text('打开菜单'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开菜单'));
    await t.pumpAndSettle();
    final rect = t.getRect(find.byType(miuix.MiuixCard));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(800));
    expect(rect.bottom, lessThanOrEqualTo(600));
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'menu respects the actual overlay when media describes a larger display',
    (t) async {
      await t.binding.setSurfaceSize(const Size(433, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      String? selected;
      await t.pumpWidget(
        host(
          Builder(
            builder: (context) => ui.TextButton(
              onPressed: () async {
                selected = await showAppMenu<String>(
                  context: context,
                  position: const RelativeRect.fromLTRB(300, 500, 12, 0),
                  items: normalItems,
                );
              },
              child: const Text('打开菜单'),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开菜单'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      final firstRect = t.getRect(find.byType(miuix.MiuixCard));
      expect(firstRect.left, greaterThanOrEqualTo(0));
      expect(firstRect.right, lessThanOrEqualTo(433));
      await t.pumpAndSettle();
      final rect = t.getRect(find.byType(miuix.MiuixCard));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(433));
      expect(rect.bottom, lessThanOrEqualTo(900));
      await t.tap(find.text('移除'));
      await t.pumpAndSettle();
      expect(selected, 'b');
      expect(find.text('移除'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
