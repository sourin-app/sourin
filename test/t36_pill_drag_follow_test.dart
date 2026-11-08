// The glass drag-to-select pill was intentionally replaced by Miuix navigation.
// Test the production widget: a drag cancels, a released tap activates once,
// and keyboard/remote activation reaches pages.
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart' show AppTab;
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/shell_layouts/miuix_shell_navigation.dart';

Future<void> _mount(WidgetTester tester, List<AppTab> visits) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 700);
  addTearDown(tester.view.reset);
  var current = AppTab.home;
  final theme = AppTheme.themeFor(Brightness.dark);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: AppScaffold(
        child: StatefulBuilder(
          builder: (context, setState) => Align(
            alignment: Alignment.bottomCenter,
            child: MiuixShellNavigation(
              current: current,
              unread: 0,
              onSelect: (tab) => setState(() {
                current = tab;
                visits.add(tab);
              }),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

miuix.MiuixNavigationBarItem _item(WidgetTester tester, AppTab tab) =>
    tester.widget<miuix.MiuixNavigationBarItem>(
      find.descendant(
        of: find.byKey(ValueKey('shell-nav-${tab.name}')),
        matching: find.byType(miuix.MiuixNavigationBarItem),
      ),
    );

void main() {
  setUp(UiPrefs.debugResetForTest);
  tearDown(UiPrefs.debugResetForTest);

  testWidgets('drag cancels navigation without changing the selected page', (
    tester,
  ) async {
    final visits = <AppTab>[];
    await _mount(tester, visits);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('shell-nav-live'))),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(_item(tester, AppTab.home).selected, isTrue);
    expect(visits, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(visits, isEmpty);
    expect(_item(tester, AppTab.live).selected, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tap activates exactly once on release and changes real selection',
    (tester) async {
      final visits = <AppTab>[];
      await _mount(tester, visits);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('shell-nav-search'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(visits, isEmpty);
      expect(_item(tester, AppTab.home).selected, isTrue);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(visits, [AppTab.search]);
      expect(_item(tester, AppTab.search).selected, isTrue);
      expect(_item(tester, AppTab.home).selected, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one tab stop per item supports Enter Space and remote Select', (
    tester,
  ) async {
    final visits = <AppTab>[];
    await _mount(tester, visits);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(visits, [AppTab.home, AppTab.live, AppTab.follow]);
    expect(_item(tester, AppTab.follow).selected, isTrue);
    expect(tester.takeException(), isNull);
  });
}
