import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/shelf_tabs.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('shelf segments support Select and arrows in $direction', (
      tester,
    ) async {
      var selected = 0;
      final selections = <int>[];
      final theme = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: ShelfTabs.widthOf(context),
                    child: ShelfTabs(
                      selected: selected,
                      counts: const [1, 12, 1234],
                      onSelected: (value) {
                        selections.add(value);
                        setState(() => selected = value);
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final tabs = find.byType(miuix.MiuixGlassSegmentedTabRow);
      expect(tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).tabs, [
        '追更 1',
        '收藏 12',
        '历史 999+',
      ]);
      expect(find.byKey(const ValueKey('shelf-current-count')), findsNothing);
      Focus.of(tester.element(find.text('收藏 12'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(selected, 1);
      expect(selections, [1]);

      await tester.sendKeyEvent(
        direction == TextDirection.ltr
            ? LogicalKeyboardKey.arrowRight
            : LogicalKeyboardKey.arrowLeft,
      );
      await tester.pump();
      expect(
        tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).selectedIndex,
        2,
      );
      expect(
        Focus.of(tester.element(find.text('历史 999+'))).hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(selections, [1, 2, 2]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [216.0, 328.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('labels and counts stay in capsules at $width / $scale', (
        tester,
      ) async {
        final theme = AppTheme.themeFor(Brightness.dark);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (_, child) => AppThemeHost(data: theme, child: child!),
            home: MediaQuery(
              data: MediaQueryData(
                size: tester.view.physicalSize / tester.view.devicePixelRatio,
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: ShelfTabs(
                      selected: 2,
                      counts: const [0, 12, 1234567],
                      onSelected: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tabs = find.byType(miuix.MiuixGlassSegmentedTabRow);
        const labels = ['追更 0', '收藏 12', '历史 999+'];
        expect(
          tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).tabs,
          labels,
        );
        expect(find.byKey(const ValueKey('shelf-current-count')), findsNothing);
        final targets = find.descendant(
          of: tabs,
          matching: find.byType(FocusableActionDetector),
        );
        expect(targets, findsNWidgets(3));
        for (var i = 0; i < labels.length; i++) {
          final label = labels[i];
          final text = find.text(label);
          expect(text, findsOneWidget);
          expect(
            tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
            isFalse,
          );
          final capsule = tester.getRect(targets.at(i));
          final labelBounds = tester.getRect(text);
          expect(labelBounds.left, greaterThanOrEqualTo(capsule.left));
          expect(labelBounds.right, lessThanOrEqualTo(capsule.right));
          expect(labelBounds.top, greaterThanOrEqualTo(capsule.top));
          expect(labelBounds.bottom, lessThanOrEqualTo(capsule.bottom));
          expect(capsule.height, greaterThanOrEqualTo(34));
        }
        final viewport = tester.getRect(find.byType(ShelfTabs));
        final active = tester.getRect(targets.at(2));
        expect(viewport.width, width);
        expect(active.left, greaterThanOrEqualTo(viewport.left - .1));
        expect(active.right, lessThanOrEqualTo(viewport.right + .1));
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final direction in TextDirection.values) {
    testWidgets('narrow capsules scroll with keyboard focus in $direction', (
      tester,
    ) async {
      var selected = 0;
      final theme = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: MediaQuery(
            data: MediaQueryData(
              size: tester.view.physicalSize / tester.view.devicePixelRatio,
              textScaler: TextScaler.linear(1.6),
            ),
            child: Directionality(
              textDirection: direction,
              child: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) => Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 216,
                      child: ShelfTabs(
                        selected: selected,
                        counts: const [0, 12, 1234567],
                        onSelected: (value) => setState(() => selected = value),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('追更 0'))).requestFocus();
      await tester.pump();
      for (final (index, label) in [(1, '收藏 12'), (2, '历史 999+')]) {
        await tester.sendKeyEvent(
          direction == TextDirection.ltr
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowLeft,
        );
        await tester.pumpAndSettle();
        expect(selected, index);
        expect(
          Focus.of(tester.element(find.text(label))).hasPrimaryFocus,
          isTrue,
        );
        final viewport = tester.getRect(find.byType(ShelfTabs));
        final targets = find.descendant(
          of: find.byType(miuix.MiuixGlassSegmentedTabRow),
          matching: find.byType(FocusableActionDetector),
        );
        final active = tester.getRect(targets.at(index));
        expect(active.left, greaterThanOrEqualTo(viewport.left - .1));
        expect(active.right, lessThanOrEqualTo(viewport.right + .1));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
