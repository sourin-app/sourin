// Protect the original white-on-white regression at the rendered components.
// The old glass gradient constants were retired by the Miuix migration.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart' show AppTab;
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/shell_layouts/miuix_shell_navigation.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';

double _contrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}

Color _textColor(WidgetTester tester, Finder root, String label) {
  final paragraph = find.descendant(
    of: root,
    matching: find.byWidgetPredicate(
      (widget) => widget is RichText && widget.text.toPlainText() == label,
    ),
  );
  expect(paragraph, findsOneWidget);
  final render = tester.renderObject<RenderParagraph>(paragraph);
  final color = render.text.style?.color;
  expect(
    color,
    isNotNull,
    reason: 'Read the resolved text paint, not a token declaration.',
  );
  return color!;
}

Color _shapeColor(WidgetTester tester, Finder root) {
  final shape = find.descendant(
    of: root,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox && widget.decoration is ShapeDecoration,
    ),
  );
  expect(shape, findsWidgets);
  final decoration =
      tester.renderObject<RenderDecoratedBox>(shape.first).decoration
          as ShapeDecoration;
  expect(decoration.color, isNotNull);
  return decoration.color!;
}

const _favorites = <Favorite>[
  Favorite(
    key: 'fixture:fav',
    provider: 'fixture',
    nativeId: 'fav',
    title: '颜色验证收藏',
  ),
];
const _following = <Favorite>[
  Favorite(
    key: 'fixture:follow',
    provider: 'fixture',
    nativeId: 'follow',
    title: '颜色验证追更',
    following: true,
  ),
];

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    debugShelfLoadOverride = () async =>
        (_favorites, _following, const <Progress>[]);
  });
  tearDown(() {
    debugShelfLoadOverride = null;
    UiPrefs.debugResetForTest();
  });

  test('shell continues to use the repository Material facade', () {
    final source = File('lib/shell.dart').readAsStringSync();
    expect(source, isNot(contains("import 'package:flutter/material.dart'")));
    expect(source, contains("import 'package:material_ui/material_ui.dart'"));
  });

  testWidgets(
    'mounted Miuix navigation shelf and source retain readable selection across theme changes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(520, 900);
      addTearDown(tester.view.reset);
      final brightness = ValueNotifier(Brightness.light);
      addTearDown(brightness.dispose);
      var current = AppTab.home;
      var sourceActive = true;
      await tester.pumpWidget(
        ValueListenableBuilder<Brightness>(
          valueListenable: brightness,
          builder: (_, value, child) {
            final theme = AppTheme.themeFor(value);
            return MaterialApp(
              theme: theme,
              builder: (_, child) => AppThemeHost(data: theme, child: child!),
              home: AppScaffold(
                child: StatefulBuilder(
                  builder: (context, setState) => Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              const MyShelf(),
                              SourcePill(
                                label: '测试来源',
                                active: sourceActive,
                                onTap: () => setState(
                                  () => sourceActive = !sourceActive,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      MiuixShellNavigation(
                        current: current,
                        unread: 0,
                        onSelect: (tab) => setState(() => current = tab),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();

      final bar = find.byType(miuix.MiuixNavigationBar);
      final tabs = find.byType(miuix.MiuixTabRow);
      final source = find.byType(SourcePill);
      expect(bar, findsOneWidget);
      expect(tabs, findsOneWidget);
      expect(source, findsOneWidget);
      final existingTabs = tester.element(tabs);
      final surfaces = <Brightness, Color>{};

      for (final mode in [
        Brightness.light,
        Brightness.dark,
        Brightness.light,
      ]) {
        brightness.value = mode;
        await tester.pumpAndSettle();
        expect(
          tester.element(tabs),
          same(existingTabs),
          reason: 'Changing appearance must update the mounted shelf, retaining its state.',
        );
        final colors = miuix.MiuixTheme.of(tester.element(bar)).colors;
        final barPaint = find
            .descendant(of: bar, matching: find.byType(ColoredBox))
            .first;
        final barColor = tester.widget<ColoredBox>(barPaint).color;
        expect(barColor, colors.surface);
        surfaces[mode] = barColor;

        for (final tab in [AppTab.home, AppTab.search]) {
          await tester.tap(find.byKey(ValueKey('shell-nav-${tab.name}')));
          await tester.pumpAndSettle();
          final selected = find.descendant(
            of: find.byKey(ValueKey('shell-nav-${tab.name}')),
            matching: find.byType(miuix.MiuixNavigationBarItem),
          );
          expect(
            tester.widget<miuix.MiuixNavigationBarItem>(selected).selected,
            isTrue,
          );
          final text = _textColor(tester, selected, tab.label);
          expect(text, colors.onSurfaceContainer);
          expect(
            _contrast(text, barColor),
            greaterThanOrEqualTo(4.5),
            reason: 'The active destination must never become white-on-white.',
          );
        }

        for (final (label, index) in [('最近追更 1', 0), ('最近收藏 1', 1)]) {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(
            tester.widget<miuix.MiuixTabRow>(tabs).selectedTabIndex,
            index,
          );
          final surface = _shapeColor(tester, tabs);
          final text = _textColor(tester, tabs, label);
          expect(surface, colors.surfaceContainer);
          expect(text, colors.onBackground);
          expect(_contrast(text, surface), greaterThanOrEqualTo(4.5));
        }

        for (final active in [true, false, true]) {
          if (sourceActive != active) {
            await tester.tap(find.text('测试来源'));
            await tester.pumpAndSettle();
          }
          expect(tester.widget<SourcePill>(source).active, active);
          final button = find.descendant(
            of: source,
            matching: find.byType(miuix.MiuixButton),
          );
          expect(button, findsOneWidget);
          final surface = _shapeColor(tester, button);
          final text = _textColor(tester, button, '测试来源');
          expect(surface, active ? colors.primary : colors.secondaryVariant);
          expect(text, active ? colors.onPrimary : colors.onSecondaryVariant);
          expect(_contrast(text, surface), greaterThanOrEqualTo(4.5));
        }
        expect(tester.takeException(), isNull);
      }
      expect(surfaces[Brightness.light], isNot(surfaces[Brightness.dark]));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    },
  );
}
