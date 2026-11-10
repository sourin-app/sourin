import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_popover.dart'
    hide PlayerPopoverIds;
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

Future<void> _pumpPlayerControls(
  WidgetTester tester,
  PopoverController controller, {
  VoidCallback? onAdvanced,
  bool withSearch = false,
  ValueNotifier<bool>? anchorVisible,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(tester.view.reset);
  final position = ValueNotifier(Duration.zero);
  final bottomInset = ValueNotifier(0.0);
  addTearDown(position.dispose);
  addTearDown(bottomInset.dispose);
  final bar = PlayerBottomBar(
    controller: controller,
    playing: true,
    positionListenable: position,
    duration: const Duration(minutes: 2),
    isLive: false,
    rate: 1,
    volume: 0,
    muted: false,
    fullscreen: false,
    onTogglePlay: () {},
    onSeek: (_) {},
    onVolume: (_) {},
    onToggleMute: () {},
    onRate: (_) {},
    onToggleFullscreen: () {},
    onEpisodes: () {},
    hasEpisodes: false,
    showEpisodeNav: false,
    onNext: () {},
    hasNext: false,
    more: const PlayerMoreMenuData(groups: []),
    danmakuQuick: DanmakuQuickPanelData(
      fontScale: 1,
      opacity: 1,
      speed: 8,
      area: 1,
      showScroll: true,
      showTop: true,
      showBottom: true,
      colorOnly: false,
      onSetFontScale: (_) {},
      onSetOpacity: (_) {},
      onSetSpeed: (_) {},
      onSetArea: (_) {},
      onSetShowScroll: (_) {},
      onSetShowTop: (_) {},
      onSetShowBottom: (_) {},
      onSetColorOnly: (_) {},
      onOpenAdvanced: onAdvanced ?? () {},
      onOpenSearch: withSearch ? () {} : null,
      onSearch: withSearch ? (_) {} : null,
    ),
  );
  final theme = AppTheme.themeFor(mui.Brightness.dark);
  await tester.pumpWidget(
    mui.MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: mui.Scaffold(
        // PlayerPage's desktop ancestor recognizes double-click fullscreen.
        // Its real recognizer holds the child click arena until 300 ms.
        body: GestureDetector(
          onTap: () {},
          onDoubleTap: () {},
          child: Stack(
            children: [
              if (anchorVisible == null)
                Stack(children: [bar])
              else
                ValueListenableBuilder<bool>(
                  valueListenable: anchorVisible,
                  builder: (_, visible, __) => visible
                      ? Stack(children: [bar])
                      : const SizedBox.expand(),
                ),
              ListenableBuilder(
                listenable: Listenable.merge([controller, bottomInset]),
                builder: (_, __) => Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: bottomInset.value),
                    child: bar.buildPopoverLayer(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  bottomInset.value = tester.getSize(find.byType(PlayerBottomBar)).height;
  await tester.pump();
}

void main() {
  final panel = find.byKey(PlayerBottomBar.danmakuQuickPanelKey);
  final gear = find.byKey(PlayerBottomBar.danmakuSettingsKey);

  testWidgets(
    'closing a real popover retains its fading pixels but blocks interaction',
    (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final semantics = tester.ensureSemantics();
      var advanced = 0;
      try {
        await _pumpPlayerControls(
          tester,
          controller,
          onAdvanced: () => advanced++,
          withSearch: true,
        );
        controller.toggleOpen(PlayerPopoverIds.danmakuQuick);
        await tester.pump();
        await tester.pump(Motion.fast);
        expect(panel, findsOneWidget);
        final rect = tester.getRect(panel);
        final field = find.descendant(
          of: panel,
          matching: find.byType(ui.TextFormField),
        );
        await tester.enterText(field, '未提交');
        await tester.pump();
        final editor = tester.widget<EditableText>(
          find.descendant(of: panel, matching: find.byType(EditableText)),
        );
        expect(editor.focusNode.hasFocus, isTrue);
        controller.close();
        await tester.pump();
        expect(controller.openId, isNull);
        expect(
          panel,
          findsOneWidget,
          reason: 'The rendered card must remain for its exit animation.',
        );
        final opacityFinder = find
            .ancestor(of: panel, matching: find.byType(AnimatedOpacity))
            .first;
        final opacity = tester.renderObject<RenderAnimatedOpacity>(
          opacityFinder,
        );
        expect(opacity.opacity.value, 1);
        expect(
          tester.getRect(panel),
          rect,
          reason: 'Closing must preserve the last panel anchor.',
        );
        expect(editor.focusNode.hasFocus, isFalse);
        expect(find.bySemanticsLabel('高级设置'), findsNothing);
        await tester.tap(
          find.byKey(PlayerBottomBar.danmakuQuickAdvancedKey),
          warnIfMissed: false,
        );
        expect(advanced, 0);
        await tester.pump(Motion.fast ~/ 2);
        expect(panel, findsOneWidget);
        expect(opacity.opacity.value, greaterThan(0));
        expect(opacity.opacity.value, lessThan(1));
        await tester.pump(Motion.fast);
        expect(panel, findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'reopening or switching a closing popover cancels obsolete removal',
    (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      await _pumpPlayerControls(tester, controller);
      controller.toggleOpen(PlayerPopoverIds.danmakuQuick);
      await tester.pump();
      await tester.pump(Motion.fast);
      controller.close();
      await tester.pump();
      await tester.pump(Motion.fast ~/ 2);
      controller.toggleOpen(PlayerPopoverIds.danmakuQuick);
      await tester.pump();
      await tester.pump(Motion.fast * 2);
      expect(panel, findsOneWidget);
      controller.close();
      await tester.pump();
      await tester.pump(Motion.fast ~/ 2);
      controller.toggleOpen(PlayerPopoverIds.rate);
      await tester.pump();
      await tester.pump(Motion.fast * 2);
      expect(panel, findsNothing);
      expect(find.byType(PlayerPopoverSurface), findsOneWidget);
      expect(find.text('1.5x'), findsOneWidget);
      expect(controller.openId, PlayerPopoverIds.rate);
      controller.close();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Motion.fast * 2);
      expect(find.byType(PlayerPopoverSurface), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing retains its measured anchor after the control bar unmounts',
    (tester) async {
      final controller = PopoverController();
      final anchorVisible = ValueNotifier(true);
      addTearDown(controller.dispose);
      addTearDown(anchorVisible.dispose);
      await _pumpPlayerControls(
        tester,
        controller,
        anchorVisible: anchorVisible,
      );
      controller.toggleOpen(PlayerPopoverIds.rate);
      await tester.pump();
      await tester.pump(Motion.fast);
      final surface = find.byType(PlayerPopoverSurface);
      final rect = tester.getRect(surface);
      controller.close();
      anchorVisible.value = false;
      await tester.pump();
      expect(surface, findsOneWidget);
      expect(
        tester.getRect(surface),
        rect,
        reason: 'Advanced/full-screen sheets can remove the bar during exit.',
      );
      await tester.pump(Motion.fast);
      // The exact 150 ms edge can evaluate to zero while the floating-point
      // simulation remains forward. Observe the next normal display frame.
      await tester.pump(const Duration(milliseconds: 16));
      expect(surface, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an entrance completion cannot remove content closed before its next build',
    (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      await _pumpPlayerControls(tester, controller);
      controller.toggleOpen(PlayerPopoverIds.danmakuQuick);
      await tester.pump();
      await tester.pump(Motion.fast ~/ 2);
      controller.close();
      // The entering ticker completes before the parent's closing rebuild.
      await tester.pump(Motion.fast ~/ 2 + const Duration(milliseconds: 16));
      expect(
        panel,
        findsOneWidget,
        reason: 'Only the exit completion may remove the retained content.',
      );
      final opacity = tester
          .renderObject<RenderAnimatedOpacity>(
            find
                .ancestor(of: panel, matching: find.byType(AnimatedOpacity))
                .first,
          )
          .opacity;
      expect(opacity.value, 1);
      await tester.pump(Motion.fast ~/ 2);
      expect(opacity.value, greaterThan(0));
      expect(opacity.value, lessThan(1));
      await tester.pump(Motion.fast);
      expect(panel, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one mouse click stays open across hover and double-tap timers', (
    tester,
  ) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _pumpPlayerControls(tester, controller);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(5, 5));
    addTearDown(mouse.removePointer);
    final trace = <String>[];
    try {
      expect(panel, findsNothing);
      final point = tester.getCenter(gear);
      await mouse.moveTo(point);
      await mouse.down(point);
      await mouse.up();
      await tester.pump();
      var elapsedMs = 0;
      for (final delta in [149, 2, 150, 250]) {
        await tester.pump(Duration(milliseconds: delta));
        elapsedMs += delta;
        trace.add(
          '$elapsedMs ms: ${controller.openId}, '
          '${panel.evaluate().length} panels',
        );
      }
      expect(
        controller.openId,
        PlayerPopoverIds.danmakuQuick,
        reason:
            'A single click must open the real gear even when hover '
            'fires before the ancestor releases its tap arena. $trace',
      );
      expect(panel, findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('click explicitly closes a panel already opened by hover', (
    tester,
  ) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _pumpPlayerControls(tester, controller);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(5, 5));
    addTearDown(mouse.removePointer);
    try {
      final point = tester.getCenter(gear);
      await mouse.moveTo(point);
      await tester.pump(PopoverAnchorButtonState.hoverDelay);
      await tester.pump();
      expect(controller.openId, PlayerPopoverIds.danmakuQuick);
      expect(panel, findsOneWidget);

      await mouse.down(point);
      await mouse.up();
      await tester.pump(kDoubleTapTimeout);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        controller.openId,
        isNull,
        reason: 'An intentional click on an already-open gear must close it',
      );
      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
