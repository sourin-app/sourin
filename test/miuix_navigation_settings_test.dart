import 'support/miuix_finders.dart';

import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart' show AppTab;
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/shell_layouts/bottom_bar_layout.dart';
import 'package:sourin_spike/ui/shell_layouts/miuix_shell_navigation.dart';
import 'package:sourin_spike/ui/widgets/compact_shelf_card.dart';
import 'package:sourin_spike/ui/widgets/settings_kit.dart';
import 'package:sourin_spike/ui/widgets/settings_tabs.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: AppScaffold(child: child),
  );
}

void main() {
  setUp(UiPrefs.debugResetForTest);
  tearDown(UiPrefs.debugResetForTest);

  testWidgets(
    'actual settings and compact cards activate once with remote Select',
    (tester) async {
      var enabled = false;
      var selected = false;
      var details = 0;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                SettingsGestureToggle(
                  label: '手势开关',
                  hint: '开关说明',
                  value: enabled,
                  onChanged: (next) => setState(() => enabled = next),
                ),
                SettingsGesturePill(
                  text: '手势选项',
                  selected: selected,
                  onTap: () => setState(() => selected = !selected),
                ),
                SizedBox(
                  width: CompactShelfCard.width,
                  height: CompactShelfCard.heightOf(context),
                  child: CompactShelfCard(
                    title: '紧凑卡片',
                    onTap: () => details++,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['手势开关', '手势选项', '紧凑卡片']) {
        final focus = Focus.of(tester.element(find.text(label)));
        expect(focus.canRequestFocus, isTrue);
        focus.requestFocus();
        await tester.pump();
        expect(focus.hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
      }
      expect(enabled, isTrue);
      expect(selected, isTrue);
      expect(details, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact Miuix navigation reaches all six destinations', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 700);
    addTearDown(tester.view.reset);
    var selected = AppTab.home;
    final visits = <AppTab>[];
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            return Align(
              alignment: Alignment.bottomCenter,
              child: MiuixShellNavigation(
                current: selected,
                unread: 3,
                onSelect: (tab) => setState(() {
                  selected = tab;
                  visits.add(tab);
                }),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixGlassNavigationBar), findsOneWidget);
    expect(
      tester
          .widget<miuix.MiuixGlassNavigationBar>(
            find.byType(miuix.MiuixGlassNavigationBar),
          )
          .items,
      hasLength(5),
    );
    expect(find.byType(miuix.MiuixBadge), findsOneWidget);
    for (final tab in [
      AppTab.home,
      AppTab.live,
      AppTab.follow,
      AppTab.search,
    ]) {
      final item = miuixNavigationItem(tab.label);
      final bounds = tester.getRect(item);
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(360));
      expect(bounds.height, greaterThanOrEqualTo(44));
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(selected, tab);
    }
    for (final tab in [AppTab.cached, AppTab.settings]) {
      await tester.tap(
        miuixNavigationItem(selected == AppTab.cached ? selected.label : '更多'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(tab.label).last);
      await tester.pumpAndSettle();
      expect(selected, tab);
      final more = tester.widget<miuix.MiuixGlassNavigationBar>(
        find.byType(miuix.MiuixGlassNavigationBar),
      );
      expect(more.selectedIndex, 4);
      expect(more.items.last.label, tab.label);
    }
    expect(visits, AppTab.values.skip(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rail exposes six actual Miuix items and one keyboard focus per item',
    (tester) async {
      final visits = <AppTab>[];
      await tester.pumpWidget(
        _host(
          Align(
            alignment: Alignment.centerLeft,
            child: MiuixShellNavigation(
              current: AppTab.home,
              unread: 0,
              rail: true,
              onSelect: visits.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixNavigationRail), findsOneWidget);
      expect(find.byType(miuix.MiuixNavigationRailItem), findsNWidgets(6));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(visits, [AppTab.home, AppTab.live]);
      for (final tab in AppTab.values) {
        await tester.tap(find.byKey(ValueKey('shell-nav-${tab.name}')));
        await tester.pump();
        expect(visits.last, tab);
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [360.0, 1280.0]) {
    testWidgets('shell keeps the floating Miuix navigation at $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              return BottomBarShellLayout(
                nav: MiuixShellNavigation(
                  current: AppTab.home,
                  unread: 0,
                  onSelect: (_) {},
                ),
              ).build(
                context: context,
                current: AppTab.home,
                onSelect: (_) {},
                body: const Center(child: Text('Page content')),
                tabs: AppTab.values,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixScaffold), findsOneWidget);
      expect(find.byType(miuix.MiuixNavigationRail), findsNothing);
      expect(find.byType(miuix.MiuixGlassNavigationBar), findsOneWidget);
      expect(find.text('Page content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'settings entry is a Miuix preference and activates by keyboard',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              SettingsEntryRow(
                title: '设置入口',
                subtitle: '说明',
                onTap: () => opened++,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixArrowPreference), findsOneWidget);
      expect(find.byType(miuix.MiuixCard), findsOneWidget);
      await tester.tap(find.text('设置入口'));
      await tester.pump();
      expect(opened, 1);
      Focus.of(tester.element(find.byType(miuix.MiuixCard))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opened, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Miuix shelf tabs support pointer and remote direction keys', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: SettingsTabs(
                  labels: const ['追更', '收藏', '历史'],
                  selected: selected,
                  onSelected: (index) => setState(() => selected = index),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixTabRow), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await tester.pump();
    expect(selected, 1);
    Focus.of(tester.element(find.byType(miuix.MiuixTabRow))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(selected, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });
}
