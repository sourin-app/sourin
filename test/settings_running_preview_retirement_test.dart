import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';
import 'package:sourin_spike/ui/widgets/settings_kit.dart';
import 'package:sourin_spike/ui/widgets/settings_motion_panel.dart';

Future<ValueNotifier<bool>> _mount(WidgetTester tester) async {
  final reduced = ValueNotifier<bool>(false);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => ValueListenableBuilder<bool>(
        valueListenable: reduced,
        builder: (context, disable, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: disable),
          child: AppThemeHost(data: theme, child: child!),
        ),
      ),
      home: const Scaffold(
        body: SingleChildScrollView(child: SettingsMotionPanel()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    reduced.dispose();
    expect(tester.takeException(), isNull);
  });
  return reduced;
}

void _preview(WidgetTester tester) {
  final action = tester.widget<SettingsGesturePill>(
    find.byWidgetPredicate(
      (widget) => widget is SettingsGesturePill && widget.text == '再次预览',
    ),
  );
  // Current rendered production action, avoiding unrelated hover/press springs.
  action.onTap();
}

Animation<double> _owner(WidgetTester tester) =>
    tester
            .widget<AnimatedBuilder>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('motion-preview-card')),
                    matching: find.byType(AnimatedBuilder),
                  )
                  .first,
            )
            .animation
        as Animation<double>;

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    PageTransitionStyleStore.resetForTest(PageTransitionStyle.slideUp);
  });
  tearDown(() {
    UiPrefs.debugResetForTest();
    PageTransitionStyleStore.syncFromPrefs();
  });

  testWidgets('running preview cannot reappear after reduced-motion roundtrip', (
    tester,
  ) async {
    final reduced = await _mount(tester);
    final panel = tester.state(find.byType(SettingsMotionPanel));
    final card = find.byKey(const ValueKey('motion-preview-card'));
    final settled = tester.getRect(card);
    _preview(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.getRect(card).top, greaterThan(settled.top + .5));
    final owner = _owner(tester);
    expect(owner.status, AnimationStatus.forward);

    reduced.value = true;
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(card), settled);
    expect(tester.state(find.byType(SettingsMotionPanel)), same(panel));

    // Roundtrip at zero elapsed time catches a still-running hidden controller.
    reduced.value = false;
    await tester.pump();
    await tester.pump();
    expect(
      tester.getRect(card),
      settled,
      reason: 'Re-enabling motion must not resume the cancelled preview frame.',
    );
    expect(_owner(tester), same(owner));
    expect(owner.status, AnimationStatus.completed);
    var notifications = 0;
    void observe() => notifications++;
    owner.addListener(observe);
    try {
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getRect(card), settled);
      await tester.pump(Motion.base);
      expect(tester.getRect(card), settled);
      expect(notifications, 0);
    } finally {
      owner.removeListener(observe);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ordinary preview remains animated and can replay after reduction',
    (tester) async {
      final reduced = await _mount(tester);
      final card = find.byKey(const ValueKey('motion-preview-card'));
      final settled = tester.getRect(card);
      _preview(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final early = tester.getRect(card);
      expect(early.top, greaterThan(settled.top + .5));
      await tester.pump(const Duration(milliseconds: 45));
      expect(tester.getRect(card).top, lessThan(early.top));
      await tester.pump(Motion.base);
      expect(tester.getRect(card), settled);
      expect(_owner(tester).status, AnimationStatus.completed);

      reduced.value = true;
      await tester.pump();
      _preview(tester);
      await tester.pump();
      expect(tester.getRect(card), settled);
      reduced.value = false;
      await tester.pump();
      _preview(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getRect(card).top, greaterThan(settled.top + .5));
      await tester.pump(Motion.base);
      expect(tester.getRect(card), settled);
      expect(tester.takeException(), isNull);
    },
  );
}
