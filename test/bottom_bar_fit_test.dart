import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart' show AppTab;
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/shell_layouts/bottom_bar_layout.dart';
import 'package:sourin_spike/ui/shell_layouts/miuix_shell_navigation.dart';

void main() {
  setUp(UiPrefs.debugResetForTest);
  tearDown(UiPrefs.debugResetForTest);

  for (final (size, dpr) in const [
    (Size(320, 700), 1.0),
    (Size(411.43, 914.29), 2.625),
    (Size(899, 700), 1.0),
    (Size(900, 700), 1.0),
    (Size(960, 540), 2.0),
    (Size(1280, 800), 1.0),
  ]) {
    testWidgets(
      'Miuix navigation fits $size at DPR $dpr and reaches all pages',
      (tester) async {
        // Keep MediaQuery and layout constraints on the same logical viewport.
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = size * dpr;
        addTearDown(tester.view.reset);
        var current = AppTab.home;
        final visited = <AppTab>[];
        final theme = AppTheme.themeFor(Brightness.dark);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (_, child) => AppThemeHost(data: theme, child: child!),
            home: AppScaffold(
              child: StatefulBuilder(
                builder: (context, setState) {
                  void select(AppTab tab) => setState(() {
                    current = tab;
                    visited.add(tab);
                  });
                  return BottomBarShellLayout(
                    nav: MiuixShellNavigation(
                      current: current,
                      unread: 0,
                      onSelect: select,
                    ),
                    rail: MiuixShellNavigation(
                      current: current,
                      unread: 0,
                      onSelect: select,
                      rail: true,
                    ),
                  ).build(
                    context: context,
                    current: current,
                    onSelect: select,
                    body: const SizedBox.expand(key: ValueKey('page-body')),
                    tabs: AppTab.values,
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rail = size.width >= BottomBarShellLayout.railBreakpoint;
        final panel = find.byType(
          rail ? miuix.MiuixNavigationRail : miuix.MiuixNavigationBar,
        );
        expect(panel, findsOneWidget);
        final panelBounds = tester.getRect(panel);
        expect(panelBounds.left, greaterThanOrEqualTo(0));
        expect(panelBounds.right, lessThanOrEqualTo(size.width + .01));
        expect(panelBounds.top, greaterThanOrEqualTo(0));
        expect(panelBounds.bottom, lessThanOrEqualTo(size.height + .01));
        if (rail) {
          final body = tester.getRect(find.byKey(const ValueKey('page-body')));
          expect(body.left, greaterThanOrEqualTo(panelBounds.right));
        }
        final direct = rail ? AppTab.values : AppTab.values.take(4);
        for (final tab in direct) {
          final target = find.byKey(ValueKey('shell-nav-${tab.name}'));
          final bounds = tester.getRect(target);
          expect(bounds.width, greaterThanOrEqualTo(44));
          expect(bounds.height, greaterThanOrEqualTo(44));
          expect(panelBounds.inflate(.01).contains(bounds.topLeft), isTrue);
          expect(panelBounds.inflate(.01).contains(bounds.bottomRight), isTrue);
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(current, tab);
        }
        if (!rail) {
          for (final tab in [AppTab.cached, AppTab.settings]) {
            await tester.tap(find.byKey(const ValueKey('shell-nav-more')));
            await tester.pumpAndSettle();
            expect(find.byType(miuix.MiuixWindowListPopup), findsOneWidget);
            await tester.tap(find.text(tab.label).last);
            await tester.pumpAndSettle();
            expect(current, tab);
            final selected = tester.widget<miuix.MiuixNavigationBarItem>(
              find.byType(miuix.MiuixNavigationBarItem).last,
            );
            expect(selected.selected, isTrue);
            expect(selected.label, tab.label);
          }
        }
        expect(visited, AppTab.values);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
