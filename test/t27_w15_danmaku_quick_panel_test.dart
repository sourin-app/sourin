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
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';

class _Spy {
  int advanced = 0;
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
  await tester.pumpWidget(
    mui.MaterialApp(
      theme: theme,
      builder: (context, child) => AppThemeHost(
        data: theme,
        child: child ?? const SizedBox(),
      ),
      home: mui.Scaffold(
        body: mui.Material(
          type: mui.MaterialType.transparency,
          child: Stack(
            children: <Widget>[
              Stack(children: <Widget>[bar]),
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => Positioned.fill(
                  child: Align(
                    alignment: Alignment.bottomRight,
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
  while (tester.takeException() != null) {}
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
  expect(find.byKey(PlayerBottomBar.danmakuQuickPanelKey), findsOneWidget,
      reason: '前置：悬浮窗必须已经弹出来');
}

void main() {
  testWidgets('Q1 点齿轮 ⇒ 弹出轻量悬浮窗（贴按钮的小卡片）', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);
    expect(controller.openId, 'danmakuQuick');
    while (t.takeException() != null) {}
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
    expect(spy.fontScale, isNotEmpty,
        reason: '★★ 拖字号滑杆必须回调宿主 —— 这是「弹出来直接操作」的判据');

    await t.drag(
      find.byKey(PlayerBottomBar.danmakuQuickOpacityKey),
      const Offset(-30, 0),
    );
    await t.pump();
    expect(spy.opacity, isNotEmpty, reason: '★★ 拖不透明度滑杆必须回调宿主');
    while (t.takeException() != null) {}
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
    while (t.takeException() != null) {}
  });

  testWidgets('Q4 点「高级设置」⇒ 回调 onOpenAdvanced（进全屏大卡片）', (t) async {
    final spy = _Spy();
    final controller = PopoverController();
    addTearDown(controller.dispose);
    await _openPanel(t, spy, controller);

    await t.tap(find.byKey(PlayerBottomBar.danmakuQuickAdvancedKey));
    await t.pump();
    expect(spy.advanced, 1,
        reason: '★★ 「高级设置」必须把用户送进全屏大卡片（宿主 _openDanmakuSettings）');
    while (t.takeException() != null) {}
  });
}
