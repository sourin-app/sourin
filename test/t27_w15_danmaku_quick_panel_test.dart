// ══════════════════════════════════════════════════════════════════════
//  T27-15（w15-quickpanel）门禁：弹幕**轻量悬浮窗**（B 站图 1 那种）
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，2026-10-11 反馈第 1 条）
// ```text
// > 1.弹幕设置没有像我给你的那个b站弹幕的悬浮窗样式一样,我想要b站图中的
// >   这些快捷悬浮的设置项,这些都要,图1
// ```
// Owner 已确认的形态 = **轻量悬浮窗 + 高级设置入口**：
//   点底栏齿轮（`danmakuSettingsKey`）⇒ 弹出贴按钮的小卡片（B 站图 1 那些
//   快捷项）；最后一行「高级设置」⇒ 才进现在的全屏大卡片。
//
// # 本文件钉住什么（与 t27_w14 分工）
// ```text
// t27_w14 = 「底栏两枚入口的**形态**」+ 「大卡片能力没丢」（源码契约为主）
// 本文件  = 轻量悬浮窗的**行为**：
//   ① 点齿轮 ⇒ 弹窗（openId == danmakuQuick）
//   ② 悬浮窗里有四根滑杆，**直接拖**会回调宿主（实时生效那条线）
//   ③ 三枚类型开关点一下会回调宿主
//   ④ 「高级设置」这一行点一下 ⇒ 回调 onOpenAdvanced（进大卡片）
// ```
//
// # 挂法
//   照 t27_w14 / t26_w5：`PlayerBottomBar` 是**纯 widget**（无 FFI），
//   浮层与底栏当**兄弟**挂在同一个 Stack（与生产 player_page 逐字同款）。
//   不写 @Tags(['native-media']) —— 不挂 PlayerPage。
// ══════════════════════════════════════════════════════════════════════

import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'support/miuix_finders.dart';

import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';
import 'package:sourin_spike/ui/tokens.dart';

class _Spy {
  int advanced = 0;
  int searchOpened = 0;
  final searches = <String>[];
  final List<double> fontScale = <double>[];
  final List<double> opacity = <double>[];
  int showScroll = 0;
  int showTop = 0;
  int showBottom = 0;
  int colorOnly = 0;
}

PlayerBottomBar _bar(_Spy spy, PopoverController controller) => PlayerBottomBar(
  controller: controller,
  playing: true,
  positionListenable: ValueNotifier<Duration>(Duration.zero),
  duration: const Duration(minutes: 24),
  isLive: false,
  rate: 1.0,
  volume: 60,
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
  streams: const <StreamCandidate>[
    StreamCandidate(url: 'https://a/1.m3u8'),
    StreamCandidate(url: 'https://a/2.m3u8'),
  ],
  danmakuEnabled: false,
  danmakuBusy: false,
  onDanmakuToggle: () {},
  onDanmakuSettings: () {},
  danmakuQuick: DanmakuQuickPanelData(
    fontScale: 1.0,
    opacity: 1.0,
    speed: 8.0,
    area: 1.0,
    showScroll: true,
    showTop: true,
    showBottom: true,
    colorOnly: false,
    onSetFontScale: spy.fontScale.add,
    onSetOpacity: spy.opacity.add,
    onSetSpeed: (_) {},
    onSetArea: (_) {},
    onSetShowScroll: (_) => spy.showScroll++,
    onSetShowTop: (_) => spy.showTop++,
    onSetShowBottom: (_) => spy.showBottom++,
    onSetColorOnly: (_) => spy.colorOnly++,
    onOpenAdvanced: () => spy.advanced++,
    onOpenSearch: () => spy.searchOpened++,
    onSearch: spy.searches.add,
    searchKeyword: '当前作品',
  ),
);

Future<void> _pump(
  WidgetTester tester,
  _Spy spy,
  PopoverController controller,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(mui.Brightness.dark);
  final bar = _bar(spy, controller);
  final bottomInset = ValueNotifier(0.0);
  addTearDown(bottomInset.dispose);
  await tester.pumpWidget(
    mui.MaterialApp(
      theme: theme,
      builder: (context, child) =>
          AppThemeHost(data: theme, child: child ?? const SizedBox()),
      home: mui.Scaffold(
        body: mui.Material(
          type: mui.MaterialType.transparency,
          child: Stack(
            children: <Widget>[
              Stack(children: <Widget>[bar]),
              ListenableBuilder(
                listenable: Listenable.merge([controller, bottomInset]),
                builder: (context, _) => Positioned.fill(
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: bottomInset.value),
                      child: bar.buildPopoverLayer(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // Production reserves the rendered bottom bar's height for this sibling
  // layer. Omitting it lets the panel cover its own anchor in this fixture.
  bottomInset.value = tester.getSize(find.byType(PlayerBottomBar)).height;
  await tester.pump();
  /*
   * ★ 这里原来有一句 `while (tester.takeException() != null) {}` —— 已删。
   *
   * 那正是 `CONTRIBUTING.md`「⑥ 规矩二」要防的形态：把**失败静默吞掉**。
   * 夹具构建（挂底栏 + 悬浮层）若抛错，异常被这里丢弃 ⇒ 下面各测试的回调
   * 断言（fontScale/opacity/advanced…）**仍可能通过** ⇒ 门禁漏报。
   * 本夹具不挂 PlayerPage（`PlayerBottomBar` 是纯 widget，无 FFI、无 libmpv）
   * ⇒ **没有任何已知的原生异常需要放行**。构建期若抛错，就让它抛出来。
   */
}

/// 打开悬浮窗（走**生产**那条：点齿轮 ⇒ controller.toggle）
Future<void> _openPanel(
  WidgetTester tester,
  _Spy spy,
  PopoverController controller,
) async {
  await _pump(tester, spy, controller);
  await tester.tap(find.byKey(PlayerBottomBar.danmakuSettingsKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(
    find.byKey(PlayerBottomBar.danmakuQuickPanelKey),
    findsOneWidget,
    reason: '前置：悬浮窗必须已经弹出来',
  );
}

void main() {
  testWidgets('底栏与一级弹幕面板挂载实际 Miuix 控件', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);
    expect(find.byType(miuix.MiuixIconButton), findsWidgets);
    expect(find.byType(miuix.MiuixButton), findsWidgets);
    final panel = find.byKey(PlayerBottomBar.danmakuQuickPanelKey);
    expect(
      find.descendant(of: panel, matching: find.byType(miuix.MiuixTextField)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.byType(EditableText)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.byType(miuix.MiuixSlider)),
      findsNWidgets(4),
    );
    expect(
      t.widget(find.byKey(PlayerBottomBar.danmakuQuickScrollKey)),
      isA<miuix.MiuixPressable>(),
    );
  });

  testWidgets('Escape closes focused quick search without submitting', (
    t,
  ) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);
    await t.enterText(find.byType(ui.TextFormField), '未提交的片名');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(controller.openId, isNull);
    expect(
      t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
    await t.pump(Motion.fast);
    await t.pump(const Duration(milliseconds: 16));
    expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsNothing);
    expect(spy.searches, isEmpty);
  });

  testWidgets('focused quick search survives leaving panel and anchor', (
    t,
  ) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);
    final field = find.descendant(
      of: find.byKey(PlayerBottomBar.danmakuQuickPanelKey),
      matching: find.byType(ui.TextFormField),
    );
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: t.getCenter(field));
    addTearDown(mouse.removePointer);
    await t.enterText(field, '保留正在输入的片名');
    await t.pump();

    // Both the panel and its anchor can schedule a close. Neither should
    // discard a keyboard session because the pointer happens to move away.
    await mouse.moveTo(const Offset(5, 5));
    await t.pump(
      PopoverController.closeDelay + const Duration(milliseconds: 1),
    );
    expect(field, findsOneWidget);
    await mouse.moveTo(
      t.getCenter(find.byKey(PlayerBottomBar.danmakuSettingsKey)),
    );
    await t.pump();
    await mouse.moveTo(const Offset(5, 5));
    await t.pump(
      PopoverController.closeDelay + const Duration(milliseconds: 1),
    );
    expect(field, findsOneWidget);
    expect(t.widget<ui.TextFormField>(field).controller!.text, '保留正在输入的片名');
    await t.testTextInput.receiveAction(TextInputAction.search);
    expect(spy.searches, ['保留正在输入的片名']);
  });

  testWidgets('quick search closes after focus and pointer both leave', (
    t,
  ) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);
    final field = find.byType(ui.TextFormField);
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: t.getCenter(field));
    addTearDown(mouse.removePointer);
    await t.enterText(field, '保留草稿');
    await t.pump();
    await mouse.moveTo(const Offset(5, 5));
    await t.pump();
    FocusScope.of(t.element(field)).unfocus();
    await t.pump();
    await t.pump(
      PopoverController.closeDelay + const Duration(milliseconds: 1),
    );
    expect(controller.openId, isNull);
    await t.pump(Motion.fast);
    await t.pump(const Duration(milliseconds: 16));
    expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsNothing);
    expect(spy.searches, isEmpty);
  });

  testWidgets('explicit close still dismisses a focused quick search', (
    t,
  ) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);
    await t.enterText(find.byType(ui.TextFormField), '未提交');
    await t.pump();
    await t.tap(find.byKey(PlayerBottomBar.danmakuSettingsKey));
    await t.pump();
    expect(controller.openId, isNull);
    expect(
      t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isFalse,
    );
    await t.pump(Motion.fast);
    await t.pump(const Duration(milliseconds: 16));
    expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsNothing);
    expect(spy.searches, isEmpty);
  });

  testWidgets(
    'search is available in the first floating panel without advanced settings',
    (t) async {
      final spy = _Spy();
      final controller = PopoverController();
      addTearDown(controller.dispose);
      await _openPanel(t, spy, controller);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      expect(miuixTooltip('搜索弹幕'), findsOneWidget);
      await mouse.moveTo(t.getCenter(miuixTooltip('搜索弹幕')));
      await t.pump(const Duration(seconds: 1));
      await t.pump(const Duration(milliseconds: 220));
      expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(miuix.MiuixPlainTooltip),
          matching: find.text('搜索弹幕'),
        ),
        findsOneWidget,
      );
      await mouse.removePointer();
      await t.pump();
      await t.pump(const Duration(milliseconds: 220));
      final field = find.descendant(
        of: find.byKey(PlayerBottomBar.danmakuQuickPanelKey),
        matching: find.byType(ui.TextFormField),
      );
      expect(field, findsOneWidget);
      await t.enterText(field, '另一部作品');
      await t.testTextInput.receiveAction(TextInputAction.search);
      expect(spy.searches, ['另一部作品']);
      await t.enterText(field, '  按钮搜索  ');
      await t.tap(miuixTooltip('搜索弹幕'));
      expect(spy.searches, ['另一部作品', '按钮搜索']);
      await t.enterText(field, '  ');
      await t.tap(miuixTooltip('搜索弹幕'));
      expect(spy.searches, hasLength(2));
      await t.tap(find.byKey(PlayerBottomBar.danmakuQuickSearchKey));
      expect(spy.searchOpened, 1);
      expect(spy.advanced, 0);
    },
  );
  testWidgets('Q1 点齿轮 ⇒ 弹出轻量悬浮窗（贴按钮的小卡片）', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);
    expect(controller.openId, 'danmakuQuick');
  });

  testWidgets('Q2 四根滑杆都在，且**直接拖**会回调宿主（实时生效那条线）', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);

    for (final k in const [
      PlayerBottomBar.danmakuQuickFontScaleKey,
      PlayerBottomBar.danmakuQuickOpacityKey,
      PlayerBottomBar.danmakuQuickSpeedKey,
      PlayerBottomBar.danmakuQuickAreaKey,
    ]) {
      expect(find.byKey(k), findsOneWidget, reason: '★ 滑杆 $k 必须在悬浮窗里');
    }

    // ★「直接拖」= 拖动滑杆本体 ⇒ onChanged 真的发出去（不是只读）
    await t.drag(
      find.byKey(PlayerBottomBar.danmakuQuickFontScaleKey),
      const Offset(40, 0),
    );
    await t.pump();
    expect(
      spy.fontScale,
      isNotEmpty,
      reason: '★★ 拖字号滑杆必须回调宿主 —— 这是「弹出来直接操作」的判据',
    );

    await t.drag(
      find.byKey(PlayerBottomBar.danmakuQuickOpacityKey),
      const Offset(-30, 0),
    );
    await t.pump();
    expect(spy.opacity, isNotEmpty, reason: '★★ 拖不透明度滑杆必须回调宿主');
  });

  testWidgets('Q3 四枚类型开关点一下 ⇒ 回调宿主（含彩色）', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);

    await t.tap(find.byKey(PlayerBottomBar.danmakuQuickScrollKey));
    await t.pump();
    await t.tap(find.byKey(PlayerBottomBar.danmakuQuickTopKey));
    await t.pump();
    await t.tap(find.byKey(PlayerBottomBar.danmakuQuickBottomKey));
    await t.pump();
    // ★ 2026-10-11 新增：第四枚「彩色」（只显示彩色弹幕）
    await t.tap(find.byKey(PlayerBottomBar.danmakuQuickColorOnlyKey));
    await t.pump();
    expect(spy.showScroll, 1);
    expect(spy.showTop, 1);
    expect(spy.showBottom, 1);
    expect(spy.colorOnly, 1, reason: '★★ 「彩色」开关点一下必须回调宿主');
  });

  testWidgets('Q4 点「高级设置」⇒ 回调 onOpenAdvanced（进全屏大卡片）', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);

    await t.tap(find.byKey(PlayerBottomBar.danmakuQuickAdvancedKey));
    await t.pump();
    expect(
      spy.advanced,
      1,
      reason: '★★ 「高级设置」必须把用户送进全屏大卡片（宿主 _openDanmakuSettings）',
    );
  });
}
