import 'package:flutter/gestures.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/miuix_tooltip_host.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    themeAnimationDuration: Duration.zero,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('visible tooltip keeps its accessible name and Miuix surface', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _host(
          const ui.Tooltip(
            message: '全屏',
            showDuration: Duration(minutes: 1),
            child: SizedBox(width: 40, height: 40, child: Text('按钮')),
          ),
        ),
      );
      final anchorFinder = find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.tooltip == '全屏',
      );
      expect(
        tester.getSemantics(anchorFinder),
        containsSemantics(tooltip: '全屏'),
      );
      final anchor = tester.widget<Semantics>(anchorFinder);
      anchor.properties.onLongPress!();
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
      expect(find.text('全屏'), findsOneWidget);
      expect(
        tester.getSemantics(anchorFinder),
        containsSemantics(tooltip: '全屏'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 2));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('hidden anchor rejects a retained tooltip long-press callback', (
    tester,
  ) async {
    final opacity = ValueNotifier<double>(1);
    addTearDown(opacity.dispose);
    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<double>(
          valueListenable: opacity,
          builder: (_, value, child) => Opacity(opacity: value, child: child),
          child: const ui.Tooltip(
            message: '隐藏的全屏',
            showDuration: Duration(minutes: 1),
            child: SizedBox(width: 40, height: 40, child: Text('按钮')),
          ),
        ),
      ),
    );
    final callback = tester
        .widget<Semantics>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.tooltip == '隐藏的全屏',
          ),
        )
        .properties
        .onLongPress!;
    opacity.value = 0;
    await tester.pump();
    callback();
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
    opacity.value = 1;
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
  });

  testWidgets('scrolled tooltip anchors reject focus and retained callbacks', (
    tester,
  ) async {
    final scroll = ScrollController();
    final focus = FocusNode();
    addTearDown(scroll.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 200,
          height: 100,
          child: SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: [
                ui.Tooltip(
                  message: 'Scrolled hint',
                  waitDuration: Duration.zero,
                  showDuration: const Duration(minutes: 1),
                  child: SizedBox(
                    height: 64,
                    child: ui.TextButton(
                      focusNode: focus,
                      onPressed: () {},
                      child: const Text('Anchor'),
                    ),
                  ),
                ),
                const SizedBox(height: 600),
              ],
            ),
          ),
        ),
      ),
    );
    final callback = tester
        .widget<Semantics>(
          find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.tooltip == 'Scrolled hint',
          ),
        )
        .properties
        .onLongPress!;
    scroll.jumpTo(200);
    await tester.pump();
    callback();
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
    focus.unfocus();
    // Partial visibility remains a real anchor, and moving it out closes it.
    scroll.jumpTo(40);
    await tester.pump();
    callback();
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
    scroll.jumpTo(200);
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
    callback();
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('control fade removes tooltip before its anchor disappears', (
    tester,
  ) async {
    final fade = AnimationController(
      vsync: tester,
      value: 1,
      duration: const Duration(milliseconds: 260),
    );
    addTearDown(fade.dispose);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _host(
          MiuixTooltipVisibility(
            visibility: fade,
            child: FadeTransition(
              opacity: fade,
              child: const ui.Tooltip(
                message: '随控制条隐藏',
                showDuration: Duration(minutes: 1),
                child: SizedBox(width: 40, height: 40, child: Text('按钮')),
              ),
            ),
          ),
        ),
      );
      final callback = tester
          .widget<Semantics>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.tooltip == '随控制条隐藏',
            ),
          )
          .properties
          .onLongPress!;
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
      fade.reverse();
      await tester.pump();
      expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
      fade.forward();
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
      fade.value = 0;
      await tester.pump();
      expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 2));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('visible tooltip survives focus and parent content rebuilds', (
    tester,
  ) async {
    final revision = ValueNotifier(0);
    final focus = FocusNode();
    addTearDown(revision.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (_, value, __) => ui.Tooltip(
            message: '提示 $value',
            waitDuration: Duration.zero,
            showDuration: const Duration(minutes: 1),
            child: ui.TextButton(
              focusNode: focus,
              onPressed: () {},
              child: Text('操作 $value'),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(find.text('提示 0'), findsOneWidget);
    for (var value = 1; value <= 4; value++) {
      revision.value = value;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('提示 $value'), findsOneWidget);
      expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
      expect(focus.hasPrimaryFocus, isTrue);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
    expect(tester.takeException(), isNull);
    expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
  });

  testWidgets('visible tooltip closes when its rebuilt anchor loses its area', (
    tester,
  ) async {
    final size = ValueNotifier(const Size(80, 40));
    final state = miuix.MiuixTooltipState(
      initialIsVisible: true,
      isPersistent: true,
    );
    addTearDown(size.dispose);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<Size>(
          valueListenable: size,
          builder: (_, value, __) => MiuixTooltipHost(
            state: state,
            preferBelow: true,
            spacing: 8,
            tooltip: (_, scope) => miuix.MiuixPlainTooltip(
              scope: scope,
              child: const Text('Resized anchor tooltip'),
            ),
            child: SizedBox(width: value.width, height: value.height),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Resized anchor tooltip'), findsOneWidget);
    size.value = Size.zero;
    await tester.pumpAndSettle();
    expect(find.text('Resized anchor tooltip'), findsNothing);
    expect(state.isVisible, isFalse);
    size.value = const Size(80, 40);
    await tester.pumpAndSettle();
    expect(find.text('Resized anchor tooltip'), findsNothing);
    state.show();
    await tester.pumpAndSettle();
    expect(find.text('Resized anchor tooltip'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'visible tooltip follows layout and theme changes without idle frames',
    (tester) async {
      final revision = ValueNotifier(0);
      final state = miuix.MiuixTooltipState(
        initialIsVisible: true,
        isPersistent: true,
      );
      addTearDown(revision.dispose);
      addTearDown(state.dispose);
      final anchorKey = GlobalKey();
      var anchorMounts = 0;
      final child = _MountCounter(
        key: anchorKey,
        onMount: () => anchorMounts++,
      );
      await tester.pumpWidget(
        _host(
          ValueListenableBuilder<int>(
            valueListenable: revision,
            builder: (_, value, __) => miuix.MiuixTheme(
              data: value == 0
                  ? miuix.MiuixThemeData.dark()
                  : miuix.MiuixThemeData.light(),
              child: Transform.translate(
                offset: Offset(value * 120, 0),
                child: MiuixTooltipHost(
                  state: state,
                  preferBelow: true,
                  spacing: 8,
                  tooltip: (_, scope) => miuix.MiuixPlainTooltip(
                    scope: scope,
                    child: const Text('Moving tooltip'),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final anchorState = tester.state(find.byKey(anchorKey));
      final beforeRect = tester.getRect(find.text('Moving tooltip'));
      final beforeColor = tester
          .widget<DefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('Moving tooltip'),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          )
          .style
          .color;
      expect(tester.binding.hasScheduledFrame, isFalse);
      revision.value = 1;
      await tester.pumpAndSettle();
      final afterRect = tester.getRect(find.text('Moving tooltip'));
      final afterColor = tester
          .widget<DefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('Moving tooltip'),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          )
          .style
          .color;
      expect(afterRect.left - beforeRect.left, closeTo(120, 0.01));
      expect(afterColor, isNot(beforeColor));
      expect(tester.state(find.byKey(anchorKey)), same(anchorState));
      expect(anchorMounts, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.text('Moving tooltip'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nested route coverage dismisses its tooltip before returning', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final state = miuix.MiuixTooltipState(
      initialIsVisible: true,
      isPersistent: true,
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 320,
          height: 240,
          child: Navigator(
            key: navigator,
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              transitionDuration: Duration.zero,
              pageBuilder: (_, __, ___) => Center(
                child: MiuixTooltipHost(
                  state: state,
                  preferBelow: true,
                  spacing: 8,
                  tooltip: (_, scope) => miuix.MiuixPlainTooltip(
                    scope: scope,
                    child: const Text('Nested tooltip'),
                  ),
                  child: const SizedBox(width: 80, height: 40),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final overlayElement =
        find
                .ancestor(
                  of: find.text('Nested tooltip'),
                  matching: find.byType(Overlay),
                )
                .evaluate()
                .first
            as StatefulElement;
    expect(overlayElement.state, same(navigator.currentState!.overlay));
    navigator.currentState!.push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) =>
            const Center(child: Text('Covering route')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Covering route'), findsOneWidget);
    expect(find.text('Nested tooltip'), findsNothing);
    expect(state.isVisible, isFalse);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Nested tooltip'), findsNothing);
    state.show();
    await tester.pumpAndSettle();
    expect(find.text('Nested tooltip'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('edge tooltip retains local text scaling and RTL direction', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = miuix.MiuixTooltipState(
      initialIsVisible: true,
      isPersistent: true,
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      _host(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(260, 200),
            textScaler: TextScaler.linear(1.6),
          ),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Stack(
              children: [
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: MiuixTooltipHost(
                    state: state,
                    preferBelow: true,
                    spacing: 8,
                    tooltip: (_, scope) => miuix.MiuixPlainTooltip(
                      scope: scope,
                      child: const Text('Viewport tooltip content'),
                    ),
                    child: const SizedBox(width: 40, height: 40),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final label = find.text('Viewport tooltip content');
    final richText = tester.widget<RichText>(
      find.descendant(
        of: find.byType(miuix.MiuixPlainTooltip),
        matching: find.byType(RichText),
      ),
    );
    expect(richText.textScaler.scale(10), 16);
    expect(Directionality.of(tester.element(label)), TextDirection.rtl);
    final rect = tester.getRect(find.byType(miuix.MiuixPlainTooltip));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(260));
    expect(rect.bottom, lessThanOrEqualTo(200));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('showing a new tooltip closes the previous mounted tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final label in ['A', 'B'])
              ui.Tooltip(
                message: '提示 $label',
                waitDuration: Duration.zero,
                child: SizedBox(width: 100, height: 48, child: Text(label)),
              ),
          ],
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final label in ['A', 'B', 'A']) {
      await mouse.moveTo(tester.getCenter(find.text(label)));
      await tester.pumpAndSettle();
      expect(find.text('提示 $label'), findsOneWidget);
      expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('controller replacement and disposal cancel queued visibility', (
    tester,
  ) async {
    final first = miuix.MiuixTooltipState(initialIsVisible: true);
    final second = miuix.MiuixTooltipState(initialIsVisible: true);
    final current = ValueNotifier(first);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    addTearDown(current.dispose);
    await tester.pumpWidget(
      _host(
        ValueListenableBuilder<miuix.MiuixTooltipState>(
          valueListenable: current,
          builder: (_, state, __) => MiuixTooltipHost(
            state: state,
            preferBelow: true,
            spacing: 8,
            tooltip: (_, scope) => miuix.MiuixPlainTooltip(
              scope: scope,
              child: Text(identical(state, first) ? 'First' : 'Second'),
            ),
            child: const SizedBox(width: 80, height: 40),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    current.value = second;
    await tester.pumpAndSettle();
    expect(find.text('Second'), findsOneWidget);
    expect(tester.takeException(), isNull);
    second.dismiss();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
  });
}

class _MountCounter extends StatefulWidget {
  const _MountCounter({super.key, required this.onMount});
  final VoidCallback onMount;

  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 80, height: 40);
}
