// The Miuix migration retires the old per-item glass pixel contract.
// These checks observe the new popup and its reduced-motion/scroll behavior.
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_menu.dart';

Widget host({
  required bool reduced,
  required List<AppMenuItem<int>> items,
  required ValueChanged<int> onSelected,
}) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: AppThemeHost(data: theme, child: child!),
    ),
    home: Scaffold(
      body: Center(
        child: AppMenuButton<int>(items: items, onSelected: onSelected),
      ),
    ),
  );
}

void main() {
  testWidgets('menu uses Miuix popup content and no legacy glass layer', (
    t,
  ) async {
    await t.pumpWidget(
      host(
        reduced: false,
        items: const [AppMenuItem(value: 1, label: '选项')],
        onSelected: (_) {},
      ),
    );
    await t.tap(find.byType(AppMenuButton<int>));
    await t.pumpAndSettle();
    expect(find.byType(miuix.MiuixWindowListPopup), findsOneWidget);
    expect(find.byType(miuix.MiuixListPopupContent), findsOneWidget);
    expect(find.byType(miuix.MiuixCard), findsOneWidget);
    expect(find.byType(GlassContainer), findsNothing);
    expect(find.text('选项'), findsOneWidget);
  });

  testWidgets(
    'reduced motion opens at full size and dismisses without animation',
    (t) async {
      int? selected;
      await t.pumpWidget(
        host(
          reduced: true,
          items: const [AppMenuItem(value: 7, label: '立即选择')],
          onSelected: (v) => selected = v,
        ),
      );
      await t.tap(find.byType(AppMenuButton<int>));
      await t.pump();
      await t.pump();
      final popup = find.byType(miuix.MiuixListPopupContent);
      expect(popup, findsOneWidget);
      final opacity = t.widget<Opacity>(
        find.descendant(of: popup, matching: find.byType(Opacity)).first,
      );
      expect(opacity.opacity, 1);
      final transform = t.widget<Transform>(
        find.descendant(of: popup, matching: find.byType(Transform)).first,
      );
      expect(transform.transform.getMaxScaleOnAxis(), 1);
      expect(
        find.byType(miuix.MiuixWindowListPopup),
        findsNothing,
        reason: 'the upstream animated host must not bypass reduced motion',
      );
      await t.tap(find.text('立即选择'));
      await t.pump();
      await t.pump();
      expect(selected, 7);
      expect(find.text('立即选择'), findsNothing);
    },
  );

  testWidgets('long menus scroll to the final item and return its value', (
    t,
  ) async {
    t.view.physicalSize = const Size(800, 600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    int? selected;
    await t.pumpWidget(
      host(
        reduced: false,
        items: [
          for (var i = 0; i < 40; i++) AppMenuItem(value: i, label: '选项 $i'),
        ],
        onSelected: (v) => selected = v,
      ),
    );
    await t.tap(find.byType(AppMenuButton<int>));
    await t.pumpAndSettle();
    final card = t.getRect(find.byType(miuix.MiuixCard));
    expect(card.height, lessThanOrEqualTo(600));
    await t.ensureVisible(find.text('选项 39'));
    await t.pumpAndSettle();
    await t.tap(find.text('选项 39'));
    await t.pumpAndSettle();
    expect(selected, 39);
    expect(t.takeException(), isNull);
  });
}
