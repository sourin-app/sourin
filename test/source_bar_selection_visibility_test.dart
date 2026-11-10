import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';

List<ProviderManifest> sources({bool varied = false}) => [
  for (var i = 0; i < 60; i++)
    ProviderManifest(
      id: 'source-$i',
      name: varied && i.isEven ? 'Long provider title number $i' : 'S$i',
      enabled: true,
    ),
];

Widget host(ValueNotifier<String> current, List<ProviderManifest> items) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: AppScaffold(
      child: Center(
        child: SizedBox(
          width: 500,
          child: ValueListenableBuilder<String>(
            valueListenable: current,
            builder: (_, selected, __) => SourceBar(
              sources: items,
              current: selected,
              onSelect: (id) => current.value = id,
            ),
          ),
        ),
      ),
    ),
  );
}

Finder pill(String id) =>
    find.byWidgetPredicate((w) => w is SourcePill && w.label == id);
Finder get list => find.descendant(
  of: find.byType(SourceBar),
  matching: find.byType(ListView),
);
ScrollPosition position(WidgetTester tester) =>
    tester.widget<ListView>(list).controller!.position;
void expectVisible(WidgetTester tester, String name) {
  expect(
    pill(name).hitTestable(),
    findsOneWidget,
    reason: 'Selected source must remain reachable',
  );
  final viewport = tester.getRect(list), selected = tester.getRect(pill(name));
  expect(selected.left, greaterThanOrEqualTo(viewport.left - .5));
  expect(selected.right, lessThanOrEqualTo(viewport.right + .5));
  expect(tester.widget<SourcePill>(pill(name)).active, isTrue);
}

void main() {
  setUp(UiPrefs.debugResetForTest);
  tearDown(UiPrefs.debugResetForTest);

  testWidgets(
    'selecting a visible short source does not scroll it out of view',
    (t) async {
      final current = ValueNotifier('source-0');
      addTearDown(current.dispose);
      await t.pumpWidget(host(current, sources()));
      await t.pumpAndSettle();
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      await t.scrollUntilVisible(pill('S20'), 300, scrollable: scrollable);
      await t.ensureVisible(pill('S20'));
      await t.pumpAndSettle();
      final before = position(t).pixels;
      await t.tap(pill('S20'));
      await t.pumpAndSettle();
      expect(current.value, 'source-20');
      expectVisible(t, 'S20');
      expect(
        position(t).pixels,
        closeTo(before, .5),
        reason: 'A fully visible choice should not cause a jump',
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'restored selection is visible in a lazy list with mixed widths',
    (t) async {
      final current = ValueNotifier('source-43');
      addTearDown(current.dispose);
      await t.pumpWidget(host(current, sources(varied: true)));
      await t.pumpAndSettle();
      expectVisible(t, 'S43');
      expect(
        find.byType(SourcePill).evaluate().length,
        lessThan(24),
        reason: 'Do not mount all sources to locate one',
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'remote selection, reverse selection and reorder reveal the actual pill',
    (t) async {
      final current = ValueNotifier('source-0');
      addTearDown(current.dispose);
      final items = sources(varied: true);
      await t.pumpWidget(host(current, items));
      await t.pumpAndSettle();
      current.value = 'source-55';
      await t.pumpAndSettle();
      expectVisible(t, 'S55');
      current.value = 'source-3';
      await t.pumpAndSettle();
      expectVisible(t, 'S3');
      final reordered = [
        ...items.where((p) => p.id != current.value),
        items[3],
      ];
      await t.pumpWidget(host(current, reordered));
      await t.pumpAndSettle();
      expectVisible(t, 'S3');
      expect(find.byType(SourcePill).evaluate().length, lessThan(24));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('a visible newer choice stops an older reveal animation', (
    t,
  ) async {
    final current = ValueNotifier('source-0');
    addTearDown(current.dispose);
    await t.pumpWidget(host(current, sources()));
    await t.pumpAndSettle();
    current.value = 'source-7';
    await t.pump();
    await t.pump(const Duration(milliseconds: 30));
    current.value = 'source-2';
    await t.pump();
    await t.pumpAndSettle();
    expectVisible(t, 'S2');
    expect(t.takeException(), isNull);
  });

  testWidgets('a newer selection or unmount cancels pending source reveal', (
    t,
  ) async {
    final current = ValueNotifier('source-0');
    addTearDown(current.dispose);
    await t.pumpWidget(host(current, sources(varied: true)));
    await t.pumpAndSettle();
    current.value = 'source-55';
    await t.pump();
    current.value = 'source-3';
    await t.pumpAndSettle();
    expectVisible(t, 'S3');
    current.value = 'source-55';
    await t.pump();
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
