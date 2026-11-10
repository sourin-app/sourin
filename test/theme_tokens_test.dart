import 'support/miuix_finders.dart';

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

      final bar = find.byType(miuix.MiuixGlassNavigationBar);
      final tabs = find.byType(miuix.MiuixGlassSegmentedTabRow);
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
        // Read the library's rendered label/icon paint and the navigation
        // indicator. Its opaque fallback is white / #2c2c2c without a backdrop.
        final panel = tester.widget<miuix.MiuixGlassPanel>(
          find
              .descendant(of: bar, matching: find.byType(miuix.MiuixGlassPanel))
              .first,
        );
        final barColor =
            panel.fill ??
            (mode == Brightness.dark
                ? const Color(0xff2c2c2c)
                : const Color(0xffffffff));
        surfaces[mode] = barColor;

        for (final tab in [AppTab.home, AppTab.search]) {
          await tester.tap(miuixNavigationItem(tab.label));
          await tester.pumpAndSettle();
          final navigation = tester.widget<miuix.MiuixGlassNavigationBar>(bar);
          expect(navigation.items[navigation.selectedIndex].label, tab.label);
          final selected = miuixNavigationItem(tab.label);
          final text = _textColor(tester, selected, tab.label);
          expect(text, colors.onSurface);
          final selectionColor = Color.alphaBlend(
            navigation.indicatorColor!,
            barColor,
          );
          expect(
            _contrast(text, selectionColor),
            greaterThanOrEqualTo(4.5),
            reason: 'The active destination label must remain readable.',
          );
        }

        for (final (label, index) in [('追更 1', 0), ('收藏 1', 1)]) {
          await tester.tap(
            find.descendant(of: tabs, matching: find.text(label)),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).selectedIndex,
            index,
          );
          final context = tester.element(tabs);
          final panel = tester.widget<miuix.MiuixGlassPanel>(
            find
                .descendant(
                  of: tabs,
                  matching: find.byType(miuix.MiuixGlassPanel),
                )
                .first,
          );
          final fill =
              panel.fill ??
              (mode == Brightness.dark
                  ? const Color(0xff2c2c2c)
                  : const Color(0xffffffff));
          final surface = Color.alphaBlend(
            miuix.MiuixGlassSegmentedTabRowDefaults.indicatorColor(context),
            fill,
          );
          final text = _textColor(tester, tabs, label);
          expect(text, Theme.of(context).colorScheme.onSurface);
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
          final panel = tester.widget<miuix.MiuixGlassPanel>(
            find.descendant(
              of: source,
              matching: find.byType(miuix.MiuixGlassPanel),
            ),
          );
          final surface = Color.alphaBlend(panel.fill!, colors.background);
          final text = _textColor(tester, button, '测试来源');
          expect(
            surface,
            active
                ? Color.alphaBlend(
                    colors.primary.withValues(
                      alpha: mode == Brightness.dark ? .20 : .09,
                    ),
                    colors.surface,
                  )
                : Color.alphaBlend(
                    colors.surface.withValues(alpha: .72),
                    colors.background,
                  ),
          );
          expect(
            text,
            active
                ? (mode == Brightness.dark
                      ? const Color(0xff9dbfff)
                      : Color.alphaBlend(
                          const Color(0x1f000000),
                          colors.primary,
                        ))
                : colors.onSurfaceSecondary,
          );
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
