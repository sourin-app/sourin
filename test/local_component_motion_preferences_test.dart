import 'package:flutter/rendering.dart' show RenderAnimatedSize;
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/design/widgets/app_ink_well.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/shelf_tabs.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';

// Exercise actual component geometry and animation activity. System reduced
// motion is the existing MotionPrefs.duration contract; page style "none" is
// deliberately not reinterpreted as a global local-component preference.
Widget _host(ValueNotifier<bool> reduced, Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (context, content) => ValueListenableBuilder<bool>(
      valueListenable: reduced,
      builder: (context, disable, _) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: disable),
        child: AppThemeHost(data: theme, child: content!),
      ),
    ),
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  );
}

Future<void> _mount(
  WidgetTester tester,
  ValueNotifier<bool> reduced,
  Widget child,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  await tester.pumpWidget(_host(reduced, child));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

// Flush update/layout and the component's post-frame reveal at zero elapsed
// time. A zero-duration fallback must not need a timed pump to reach its target.
Future<void> _layoutFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void _expectInside(Rect target, Rect viewport) {
  expect(target.left, greaterThanOrEqualTo(viewport.left - .5));
  expect(target.right, lessThanOrEqualTo(viewport.right + .5));
}

Future<void> _expectNoScrollActivity(
  WidgetTester tester,
  ScrollPosition position,
) async {
  final settled = position.pixels;
  var notifications = 0;
  void observe() => notifications++;
  position.addListener(observe);
  try {
    expect(position.isScrollingNotifier.value, isFalse,
        reason: 'The component must retire its driven scroll activity.');
    for (final elapsed in const [
      Duration(milliseconds: 40),
      Duration(milliseconds: 160),
      Duration(milliseconds: 320),
    ]) {
      await tester.pump(elapsed);
      expect(position.pixels, closeTo(settled, .01));
      expect(position.isScrollingNotifier.value, isFalse);
    }
    expect(notifications, 0, reason: 'No continuing reveal ticks may move the rail.');
  } finally {
    position.removeListener(observe);
  }
}

List<ProviderManifest> _sources() => [
  for (var index = 0; index < 30; index++)
    ProviderManifest(id: 'motion-source-$index', name: 'Source $index', enabled: true),
];

Finder _sourceList() => find.descendant(
  of: find.byType(SourceBar),
  matching: find.byType(ListView),
);

ScrollPosition _sourcePosition(WidgetTester tester) =>
    tester.widget<ListView>(_sourceList()).controller!.position;

Finder _pill(String label) => find.byWidgetPredicate(
  (widget) => widget is SourcePill && widget.label == label,
);

ProviderManifest _clippedMountedSource(
  WidgetTester tester,
  List<ProviderManifest> sources,
) {
  final viewport = tester.getRect(_sourceList());
  // Choose a real, already-laid-out lazy child. This reaches the actual-bounds
  // correction branch, rather than confusing lazy approach jumps with motion.
  for (final source in sources) {
    final finder = _pill(source.name);
    if (finder.evaluate().isEmpty) continue;
    final bounds = tester.getRect(finder);
    if (bounds.left > viewport.left && bounds.right > viewport.right + 20) {
      return source;
    }
  }
  fail('Fixture needs one clipped, mounted source pill before selection.');
}

Widget _sourceFixture(ValueNotifier<String> current, List<ProviderManifest> sources) =>
    SizedBox(
      width: 420,
      child: ValueListenableBuilder<String>(
        valueListenable: current,
        builder: (_, selected, __) => SourceBar(
          sources: sources,
          current: selected,
          onSelect: (value) => current.value = value,
        ),
      ),
    );

const _tabs = ['Segment 0', 'Segment 1', 'Segment 2', 'Segment 3', 'Segment 4', 'Segment 5'];

Widget _tabsFixture(ValueNotifier<int> selected) => SizedBox(
  width: 216,
  child: ValueListenableBuilder<int>(
    valueListenable: selected,
    builder: (_, index, __) => MiuixSegmentedTabs(
      tabs: _tabs,
      selected: index,
      onSelected: (value) => selected.value = value,
    ),
  ),
);

Finder _tabScroll() => find.descendant(
  of: find.byType(MiuixSegmentedTabs),
  matching: find.byType(SingleChildScrollView),
);

ScrollPosition _tabPosition(WidgetTester tester) =>
    tester.widget<SingleChildScrollView>(_tabScroll()).controller!.position;

Finder _tabTarget(int index) => find.descendant(
  of: find.byType(miuix.MiuixGlassSegmentedTabRow),
  matching: find.byType(FocusableActionDetector),
).at(index);

const _panelData = DanmakuInfoData(
  source: DanmakuFeedKind.service,
  match: DanmakuPairKind.autoSearch,
  count: 1234,
  title: 'Local motion fixture',
  enabled: true,
);

Finder _panelAnimation() => find.descendant(
      of: find.byType(DanmakuInfoPanel),
      matching: find.byType(AnimatedSize),
    );

RenderAnimatedSize _panelSize(WidgetTester tester) =>
    tester.renderObject<RenderAnimatedSize>(_panelAnimation());

Size _panelBounds(WidgetTester tester) => tester.getSize(find.byType(DanmakuInfoPanel));

Finder _panelContent() => find.descendant(
  of: find.byType(DanmakuInfoPanel),
  matching: find.byType(miuix.MiuixCard),
);

void _expandPanel(WidgetTester tester) {
  // Invoke the currently rendered production action, avoiding unrelated pointer
  // press/hover springs. This is a size-transition test, not a pointer hit test.
  final surface = find.descendant(
    of: find.byType(DanmakuInfoPanel),
    matching: find.byType(AppInkWell),
  );
  final action = tester.widgetList<AppInkWell>(surface).singleWhere((widget) => widget.onTap != null);
  action.onTap!();
}

void _collapsePanel(WidgetTester tester) {
  final close = find.byWidgetPredicate(
    (widget) => widget is ui.Tooltip && widget.message == '收起',
  );
  final action = tester.widget<ui.InkWell>(find.descendant(
    of: close,
    matching: find.byType(ui.InkWell),
  ));
  action.onTap!();
}

Future<void> _expectNoSizeActivity(WidgetTester tester, {required bool reduced}) async {
  final settled = _panelBounds(tester);
  expect(settled, tester.getSize(_panelContent()),
      reason: 'Panel viewport must already match the real child geometry.');
  expect(tester.getRect(find.byType(DanmakuInfoPanel)), tester.getRect(_panelContent()));
  if (reduced) {
    expect(_panelAnimation(), findsNothing,
        reason: 'Direct reduced layout must have no panel size-animation owner.');
  } else {
    expect(_panelSize(tester).isAnimating, isFalse, reason: 'The panel size ticker must stop.');
  }
  for (final elapsed in const [
    Duration(milliseconds: 40),
    Duration(milliseconds: 160),
    Duration(milliseconds: 320),
  ]) {
    await tester.pump(elapsed);
    expect(_panelBounds(tester), settled);
    expect(tester.getRect(find.byType(DanmakuInfoPanel)), tester.getRect(_panelContent()));
    if (reduced) {
      expect(_panelAnimation(), findsNothing);
    } else {
      expect(_panelSize(tester).isAnimating, isFalse);
    }
  }
}

void main() {
  setUp(UiPrefs.debugResetForTest);
  tearDown(UiPrefs.debugResetForTest);

  for (final reduced in [false, true]) {
    testWidgets('source reveal respects system reduced=$reduced geometry and scroll lifetime', (tester) async {
      final disable = ValueNotifier(reduced);
      final current = ValueNotifier('motion-source-0');
      addTearDown(disable.dispose);
      addTearDown(current.dispose);
      final sources = _sources();
      await _mount(tester, disable, _sourceFixture(current, sources));
      final target = _clippedMountedSource(tester, sources);
      final position = _sourcePosition(tester);
      final before = position.pixels;
      current.value = target.id;
      await _layoutFrames(tester);
      final zeroTime = position.pixels;
      expect(tester.widget<SourcePill>(_pill(target.name)).active, isTrue);
      if (reduced) {
        _expectInside(tester.getRect(_pill(target.name)), tester.getRect(_sourceList()));
        await _expectNoScrollActivity(tester, position);
      } else {
        expect(position.isScrollingNotifier.value, isTrue);
        await tester.pump(const Duration(milliseconds: 40));
        final middle = position.pixels;
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(zeroTime, closeTo(before, .1));
        expect(middle, greaterThan(before + .1));
        expect(middle, lessThan(position.pixels - .1));
        _expectInside(tester.getRect(_pill(target.name)), tester.getRect(_sourceList()));
        await _expectNoScrollActivity(tester, position);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('enabling system reduction retires an active source reveal without remount', (tester) async {
    final disable = ValueNotifier(false);
    final current = ValueNotifier('motion-source-0');
    addTearDown(disable.dispose);
    addTearDown(current.dispose);
    final sources = _sources();
    await _mount(tester, disable, _sourceFixture(current, sources));
    final element = find.byType(SourceBar).evaluate().single;
    final controller = tester.widget<ListView>(_sourceList()).controller;
    final target = _clippedMountedSource(tester, sources);
    current.value = target.id;
    await _layoutFrames(tester);
    await tester.pump(const Duration(milliseconds: 30));
    final position = _sourcePosition(tester);
    expect(position.isScrollingNotifier.value, isTrue);
    disable.value = true;
    await _layoutFrames(tester);
    expect(find.byType(SourceBar).evaluate().single, same(element));
    expect(tester.widget<ListView>(_sourceList()).controller, same(controller),
        reason: 'System preference changes must retain the component scroll owner.');
    _expectInside(tester.getRect(_pill(target.name)), tester.getRect(_sourceList()));
    // Scrollable may replace its position after an inherited configuration
    // update. Observe the current attachment of the same production controller.
    await _expectNoScrollActivity(tester, _sourcePosition(tester));
    expect(tester.takeException(), isNull);
  });

  for (final reduced in [false, true]) {
    testWidgets('segmented reveal respects system reduced=$reduced geometry and scroll lifetime', (tester) async {
      final disable = ValueNotifier(reduced);
      final selected = ValueNotifier(0);
      addTearDown(disable.dispose);
      addTearDown(selected.dispose);
      await _mount(tester, disable, _tabsFixture(selected));
      final position = _tabPosition(tester);
      final before = position.pixels;
      selected.value = 5;
      await _layoutFrames(tester);
      final zeroTime = position.pixels;
      expect(tester.widget<miuix.MiuixGlassSegmentedTabRow>(find.byType(miuix.MiuixGlassSegmentedTabRow)).selectedIndex, 5);
      if (reduced) {
        _expectInside(tester.getRect(_tabTarget(5)), tester.getRect(_tabScroll()));
        await _expectNoScrollActivity(tester, position);
      } else {
        expect(position.isScrollingNotifier.value, isTrue);
        await tester.pump(const Duration(milliseconds: 30));
        final middle = position.pixels;
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(zeroTime, closeTo(before, .1));
        expect(middle, greaterThan(before + .1));
        expect(middle, lessThan(position.pixels - .1));
        _expectInside(tester.getRect(_tabTarget(5)), tester.getRect(_tabScroll()));
        await _expectNoScrollActivity(tester, position);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('enabling system reduction retires an active segmented reveal without remount', (tester) async {
    final disable = ValueNotifier(false);
    final selected = ValueNotifier(0);
    addTearDown(disable.dispose);
    addTearDown(selected.dispose);
    await _mount(tester, disable, _tabsFixture(selected));
    final element = find.byType(MiuixSegmentedTabs).evaluate().single;
    final controller = tester.widget<SingleChildScrollView>(_tabScroll()).controller;
    selected.value = 5;
    await _layoutFrames(tester);
    await tester.pump(const Duration(milliseconds: 20));
    final position = _tabPosition(tester);
    expect(position.isScrollingNotifier.value, isTrue);
    disable.value = true;
    await _layoutFrames(tester);
    expect(find.byType(MiuixSegmentedTabs).evaluate().single, same(element));
    expect(tester.widget<SingleChildScrollView>(_tabScroll()).controller, same(controller),
        reason: 'System preference changes must retain the component scroll owner.');
    _expectInside(tester.getRect(_tabTarget(5)), tester.getRect(_tabScroll()));
    await _expectNoScrollActivity(tester, _tabPosition(tester));
    expect(tester.takeException(), isNull);
  });

  for (final reduced in [false, true]) {
    testWidgets('danmaku expansion and collapse respect system reduced=$reduced size ticker', (tester) async {
      final disable = ValueNotifier(reduced);
      addTearDown(disable.dispose);
      await _mount(tester, disable, const DanmakuInfoPanel(data: _panelData, initiallyExpanded: false));
      final collapsed = _panelBounds(tester);
      _expandPanel(tester);
      await _layoutFrames(tester);
      expect(find.text('已载入'), findsOneWidget);
      if (reduced) {
        expect(_panelBounds(tester).height, greaterThan(collapsed.height + 30));
        await _expectNoSizeActivity(tester, reduced: true);
      } else {
        final render = _panelSize(tester);
        expect(render.isAnimating, isTrue);
        expect(render.size.height, closeTo(collapsed.height, .1));
        await tester.pump(const Duration(milliseconds: 40));
        final middle = render.size.height;
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(middle, greaterThan(collapsed.height + 1));
        expect(middle, lessThan(render.size.height - 1));
        await _expectNoSizeActivity(tester, reduced: false);
      }
      final expanded = _panelBounds(tester);
      _collapsePanel(tester);
      await _layoutFrames(tester);
      expect(find.text('已载入'), findsNothing);
      if (reduced) {
        expect(_panelBounds(tester), collapsed);
        await _expectNoSizeActivity(tester, reduced: true);
      } else {
        final render = _panelSize(tester);
        expect(render.isAnimating, isTrue);
        expect(render.size, expanded);
        await tester.pump(const Duration(milliseconds: 40));
        final middle = render.size.height;
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(middle, lessThan(expanded.height - 1));
        expect(middle, greaterThan(collapsed.height + 1));
        expect(render.size, collapsed);
        await _expectNoSizeActivity(tester, reduced: false);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('enabling system reduction retires active danmaku size motion without remount', (tester) async {
    final disable = ValueNotifier(false);
    addTearDown(disable.dispose);
    await _mount(tester, disable, const DanmakuInfoPanel(data: _panelData, initiallyExpanded: false));
    final element = find.byType(DanmakuInfoPanel).evaluate().single;
    final collapsed = _panelBounds(tester);
    _expandPanel(tester);
    await _layoutFrames(tester);
    await tester.pump(const Duration(milliseconds: 30));
    final render = _panelSize(tester);
    expect(render.isAnimating, isTrue);
    expect(render.size.height, greaterThan(collapsed.height));
    expect(render.size.height, lessThan(render.child!.size.height));
    disable.value = true;
    await _layoutFrames(tester);
    expect(find.byType(DanmakuInfoPanel).evaluate().single, same(element));
    await _expectNoSizeActivity(tester, reduced: true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('danmaku content state and current action focus survive preference roundtrips', (tester) async {
    final disable = ValueNotifier(false);
    addTearDown(disable.dispose);
    await _mount(tester, disable, const DanmakuInfoPanel(data: _panelData));
    final panelElement = find.byType(DanmakuInfoPanel).evaluate().single;
    final contentElement = _panelContent().evaluate().single;
    final close = find.byWidgetPredicate(
      (widget) => widget is ui.Tooltip && widget.message == '收起',
    );
    final closeElement = close.evaluate().single;
    final closeState = tester.state(close);
    final icon = find.descendant(of: close, matching: find.byType(Icon));
    final focus = Focus.of(tester.element(icon));
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(focus.hasPrimaryFocus, isTrue);
    final bounds = _panelBounds(tester);
    for (final reduced in [true, false, true]) {
      disable.value = reduced;
      await _layoutFrames(tester);
      expect(find.byType(DanmakuInfoPanel).evaluate().single, same(panelElement));
      expect(_panelContent().evaluate().single, same(contentElement));
      expect(close.evaluate().single, same(closeElement));
      expect(tester.state(close), same(closeState));
      expect(Focus.of(tester.element(icon)), same(focus));
      expect(focus.hasPrimaryFocus, isTrue);
      expect(_panelBounds(tester), bounds);
      expect(find.text('已载入'), findsOneWidget,
          reason: 'Preference changes must preserve the expanded panel state.');
      expect(tester.takeException(), isNull);
    }
  });
}
