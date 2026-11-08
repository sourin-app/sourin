import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_popover.dart'
    hide PlayerPopoverIds;

Future<void> _pumpPlayerControls(
  WidgetTester tester,
  PopoverController controller,
) async {
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
      onOpenAdvanced: () {},
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
              Stack(children: [bar]),
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
