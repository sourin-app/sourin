import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_more_menu.dart';
import 'package:sourin_spike/ui/player/player_popover.dart'
    hide PlayerPopoverIds;
import 'package:sourin_spike/ui/tokens.dart';

const _playerHeight = 388.8;
const _tail = '上一集';

List<MoreMenuGroup> _groups(
  PopoverController controller,
  List<String> actions,
) {
  MoreMenuEntry entry(String label, {bool enabled = true}) => MoreMenuEntry(
    label: label,
    icon: AppIcons.settings,
    enabled: enabled,
    onTap: () => actions.add('$label:${controller.openId ?? 'closed'}'),
  );
  return [
    MoreMenuGroup('画面', [
      entry('截图'),
      entry('画面缩放'),
      entry('画中画', enabled: false),
      MoreMenuEntry(
        label: '投屏',
        icon: AppIcons.settings,
        onTap: () => actions.add('row-should-not-activate'),
        trailing: SizedBox.square(
          dimension: 48,
          child: mui.TextButton(
            key: const ValueKey('owned-cast-action'),
            onPressed: () => actions.add('cast'),
            child: const Text('投'),
          ),
        ),
      ),
    ]),
    MoreMenuGroup('播放', [entry('播放设置'), entry('字幕搜索'), entry('换源')]),
    MoreMenuGroup('弹幕', [entry('弹幕设置')]),
    MoreMenuGroup('剧集', [entry('片头片尾'), entry(_tail)]),
  ];
}

Future<void> _mount(
  WidgetTester tester,
  PopoverController controller,
  List<String> actions, {
  double playerHeight = _playerHeight,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(860, 904);
  final position = ValueNotifier(Duration.zero);
  final bottomInset = ValueNotifier(0.0);
  addTearDown(position.dispose);
  addTearDown(bottomInset.dispose);
  addTearDown(tester.view.reset);
  final bar = PlayerBottomBar(
    controller: controller,
    playing: true,
    positionListenable: position,
    duration: const Duration(minutes: 10),
    isLive: false,
    rate: 1,
    volume: 0,
    muted: true,
    fullscreen: false,
    onTogglePlay: () {},
    onSeek: (_) {},
    onVolume: (_) {},
    onToggleMute: () {},
    onRate: (_) {},
    onToggleFullscreen: () {},
    onEpisodes: () {},
    hasEpisodes: true,
    showEpisodeNav: false,
    onNext: () {},
    hasNext: false,
    more: PlayerMoreMenuData(groups: _groups(controller, actions)),
  );
  final theme = AppTheme.themeFor(mui.Brightness.light);
  await tester.pumpWidget(
    mui.MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: mui.Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: playerHeight,
            child: Stack(
              children: [
                bar,
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
    ),
  );
  bottomInset.value = tester.getSize(find.byType(PlayerBottomBar)).height;
  await tester.pump();
  controller.toggleOpen(PlayerPopoverIds.more);
  await tester.pump();
  await tester.pump(Motion.fast);
  await tester.pump();
}

Finder _menu() => find.byType(PlayerMoreMenu);
Finder _label(String text) =>
    find.descendant(of: _menu(), matching: find.text(text));
Finder _scrollable() =>
    find.descendant(of: _menu(), matching: find.byType(Scrollable));

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets(
    'short player More menu keeps all groups and scrolls by mouse wheel to the last action',
    (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final actions = <String>[];
      try {
        await _mount(tester, controller, actions);
        expect(
          tester.takeException(),
          isNull,
          reason:
              'The 388.8px real player area must not overflow its More menu',
        );
        expect(_menu(), findsOneWidget);
        for (final group in _groups(controller, actions)) {
          expect(_label(group.title), findsOneWidget);
          for (final entry in group.entries) {
            expect(_label(entry.label), findsOneWidget);
          }
        }
        expect(_scrollable(), findsOneWidget);
        final state = tester.state<ScrollableState>(_scrollable());
        expect(state.position.maxScrollExtent, greaterThan(0));
        expect(_label(_tail).hitTestable(), findsNothing);
        final menu = tester.getRect(_menu());
        expect(menu.height, lessThan(_playerHeight));
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: menu.center,
            scrollDelta: const Offset(0, 1000),
          ),
        );
        await tester.pump();
        expect(state.position.pixels, state.position.maxScrollExtent);
        expect(_label(_tail).hitTestable(), findsOneWidget);
        final tail = tester.getRect(_label(_tail));
        expect(tail.top, greaterThanOrEqualTo(menu.top));
        expect(tail.bottom, lessThanOrEqualTo(menu.bottom));
        await tester.tap(_label(_tail));
        await tester.pump();
        expect(actions, [
          '$_tail:closed',
        ], reason: 'The original dismiss must run before the selected action');
        expect(controller.openId, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
      }
    },
  );

  testWidgets(
    'touch scrolling preserves disabled rows and independent trailing actions',
    (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final actions = <String>[];
      try {
        await _mount(tester, controller, actions);
        expect(tester.takeException(), isNull);
        await tester.tap(_label('画中画'));
        await tester.pump();
        expect(actions, isEmpty);
        expect(controller.openId, PlayerPopoverIds.more);
        await tester.tap(_label('投屏'));
        await tester.pump();
        expect(actions, isEmpty);
        await tester.tap(find.byKey(const ValueKey('owned-cast-action')));
        await tester.pump();
        expect(actions, ['cast']);
        expect(controller.openId, PlayerPopoverIds.more);
        await tester.drag(_scrollable(), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(_label(_tail).hitTestable(), findsOneWidget);
        await tester.tap(_label(_tail));
        await tester.pump();
        expect(actions, ['cast', '$_tail:closed']);
        expect(controller.openId, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
      }
    },
  );

  testWidgets(
    'keyboard traversal reveals the final menu action and keeps the popover focused',
    (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final actions = <String>[];
      try {
        await _mount(tester, controller, actions);
        expect(tester.takeException(), isNull);
        Focus.of(tester.element(_label('截图'))).requestFocus();
        await tester.pump();
        var reached = false;
        final traversal = <String>[];
        for (var step = 0; step < 15; step++) {
          final focusedTexts = <String>[];
          void visit(Element e) {
            if (e.widget is Text) {
              focusedTexts.add((e.widget as Text).data ?? '');
            }
            e.visitChildElements(visit);
          }

          final focusedContext = FocusManager.instance.primaryFocus?.context;
          if (focusedContext is Element) visit(focusedContext);
          traversal.addAll(focusedTexts);
          expect(controller.openId, PlayerPopoverIds.more);
          if (Focus.of(tester.element(_label(_tail))).hasPrimaryFocus) {
            reached = true;
            break;
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
        }
        expect(reached, isTrue);
        expect(traversal, [
          '截图',
          '画面缩放',
          '投',
          '播放设置',
          '字幕搜索',
          '换源',
          '弹幕设置',
          '片头片尾',
          _tail,
        ]);
        expect(_label(_tail).hitTestable(), findsOneWidget);
        controller.armClose();
        await tester.pump(PopoverController.closeDelay + Motion.fast);
        expect(controller.openId, PlayerPopoverIds.more);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(actions, ['$_tail:closed']);
        expect(controller.openId, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
      }
    },
  );

  testWidgets(
    'tall player More menu stays content sized without unnecessary scrolling',
    (tester) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final actions = <String>[];
      try {
        await _mount(tester, controller, actions, playerHeight: 900);
        expect(tester.takeException(), isNull);
        expect(_label(_tail).hitTestable(), findsOneWidget);
        final scrolls = _scrollable();
        if (scrolls.evaluate().isNotEmpty) {
          expect(
            tester.state<ScrollableState>(scrolls).position.maxScrollExtent,
            0,
          );
        }
        expect(tester.getSize(_menu()).height, lessThan(700));
        await tester.tap(_label(_tail));
        await tester.pump();
        expect(actions, ['$_tail:closed']);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmount(tester);
      }
    },
  );
}
