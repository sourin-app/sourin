// ═══════════════════════════════════════════════════════════════════════
//  第 16 项缺口②：控件**自动隐藏 + 鼠标移动唤起**
// ═══════════════════════════════════════════════════════════════════════
//
// # 实现要点（`live_embedded_player.dart`）
// ```text
// · `_controlsVisible` + **一次性** `Timer`（`_controlsHideDelay = 3s`）：
//   每次交互 cancel 旧的再起一个新的 ⇒ 不会像 `Timer.periodic` 那样永远回调。
// · 隐藏 = `IgnorePointer(ignoring: true)` + `AnimatedOpacity(0)`
//   ⇒ `hitTestable()` 归 0，但**占位不变**（视频区域高度不变）。
// · 唤起 = 最外层 `MouseRegion.onHover` ⇒ `revealControls()`。
//   ⚠️ 必须挂最外层：藏在控件里的话，控件被 IgnorePointer 挡住就收不到 hover
//   ⇒ 用户"再也叫不出来"（这正是本文件要排除的坏形态）。
// · 只有 `stream != null` 才在 initState 起首轮计时（没画面时控制条是唯一出口，
//   不许自动收起）。
// ```
//
// # 每条断言都能红（注入读数见交付说明）
// ```text
// · 注入"永不隐藏"（Timer 里直接 return）⇒ ①② 红
// · 注入"永不恢复"（revealControls 不置 visible）⇒ ③ 红
// ```

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

/// 建一只**唯一的**鼠标指针（一个用例只能有一个：MouseTracker 会断言
/// `PointerAddedEvent` 与上一个 `PointerRemovedEvent` 成对出现）
Future<TestGesture> _mousePointer(WidgetTester t) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  return g;
}

Future<void> _hover(TestGesture mouse, WidgetTester t, Offset at) async {
  await mouse.moveTo(at);
  await t.pump();
}

void main() {
  setUp(() {
    /*
     * ★ 关掉"延迟建播放器"：本文件必须把虚拟时间推进 3s（越过 `_createDelay`
     *   380ms），而 `flutter test` 里 `Player()` 必抛 MediaKit 异常
     *   ⇒ 不关就会红在**与本判据无关**的那条路径上（已实测，见交付说明）。
     */
    debugSkipPlayerCreation = true;
    /*
     * ★★★ 2026-10-26：**必须造出"正在播放"这个前置**
     *
     * ```text
     * 内嵌侧新增了与全屏同源的判据：**只有真的在播才允许自动收起**
     * （`_playingForAutohide`，对齐 `player_page.dart` 的 `_autoHideNow`）。
     * 而 widget 测试里 `_player == null` ⇒ `isPlaying` 恒 false
     * ⇒ 不注入就等于"一直暂停"，控件**永远不该收**。
     * ⇒ 这里是**前置注入**，不是放宽断言：三条既有断言一个字没改；
     *   下面 ⑤ 专门用 `debugForcePlaying = false` 验"暂停不收"。
     * ```
     */
    debugForcePlaying = true;
  });
  tearDown(() {
    debugSkipPlayerCreation = false;
    debugForcePlaying = null;
  });

  testWidgets('① 初始可见 → 3s 后自动隐藏（hitTestable 归 0）', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(640, 360);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    await t.pumpWidget(_host(
      const LiveEmbeddedPlayer(stream: null, title: '自动隐藏'),
    ));
    await t.pump();

    final bar = find.byKey(liveEmbedBarKey);
    expect(bar, findsOneWidget, reason: '前提：控制条必须存在');
    expect(bar.hitTestable(), findsOneWidget,
        reason: '初始状态控制条必须可点（不然用户一进来就没法调音量）');

    final state =
        t.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));
    expect(state.controlsVisibleForProbe, isTrue);

    // 一次鼠标移动 ⇒ 起首轮隐藏计时
    final mouse = await _mousePointer(t);
    await _hover(mouse, t, t.getCenter(find.byType(LiveEmbeddedPlayer)));
    expect(state.controlsVisibleForProbe, isTrue,
        reason: '鼠标移动后控件必须是可见的');

    // 推进 3s（一次性 Timer 到点）
    await t.pump(const Duration(seconds: 3));
    await t.pump();

    expect(state.controlsVisibleForProbe, isFalse,
        reason: '★★ 3s 无交互后控件没隐藏 ⇒ 自动隐藏没生效'
            '（`_controlsHideDelay` / `_armHideTimer`）');
    expect(bar.hitTestable(), findsNothing,
        reason: '★★★ 控件"看不见却点得到" ⇒ 用户会误触一个不存在的按钮'
            '（IgnorePointer 没生效）');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('② 隐藏后鼠标移动必须能唤起（且保持布局不变）', (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(640, 360);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    await t.pumpWidget(_host(
      const LiveEmbeddedPlayer(stream: null, title: '唤起'),
    ));
    await t.pump();
    final state =
        t.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));
    final bar = find.byKey(liveEmbedBarKey);

    final mouse = await _mousePointer(t);
    // 先让它藏起来
    await _hover(mouse, t, t.getCenter(find.byType(LiveEmbeddedPlayer)));
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    expect(state.controlsVisibleForProbe, isFalse, reason: '前提：控件已隐藏');
    expect(bar.hitTestable(), findsNothing);

    final hiddenRect = t.getRect(bar);

    // 再动一次鼠标 ⇒ 必须回来
    await _hover(mouse, t, const Offset(10, 10));
    expect(state.controlsVisibleForProbe, isTrue,
        reason: '★★★ 隐藏后鼠标移动叫不出控件 ⇒ 用户再也没法调音量/静音'
            '（`MouseRegion.onHover` 挂错层就会这样）');
    expect(bar.hitTestable(), findsOneWidget,
        reason: '唤起后必须重新可点');

    // ★ 隐藏/显示**不许改布局**：控制条矩形必须完全一样
    expect(t.getRect(bar), hiddenRect,
        reason: '★★ 隐藏时改了布局（`Visibility` 那种移除孩子）⇒ '
            '视频区域高度会跳，第 17 项"控制条不挤占视频"会被破坏');

    await t.pumpWidget(const SizedBox.shrink());
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④⑤⑥ 与全屏对齐：**暂停时不收起**（第 16 项一致性）
  // ══════════════════════════════════════════════════════════════════
  //
  // # 对齐的是哪条判据
  // ```text
  // 全屏 `player_page.dart` 的 `_autoHideNow` 守卫要求 `_playing`
  // ⇒ 暂停时控件常显（用户刚按暂停，正要看那个播放键）。
  // 内嵌改前没有这条 ⇒ 暂停 3s 后照样淡出 ⇒ 两种形态观感不同。
  // ```
  testWidgets('④ 正在播 + 3s ⇒ 收起（新判据的"允许收起"那一半）', (t) async {
    debugForcePlaying = true;
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(640, 360);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    await t.pumpWidget(_host(
      const LiveEmbeddedPlayer(stream: null, title: '在播'),
    ));
    await t.pump();
    final state =
        t.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));

    final mouse = await _mousePointer(t);
    await _hover(mouse, t, t.getCenter(find.byType(LiveEmbeddedPlayer)));
    await t.pump(const Duration(seconds: 3));
    await t.pump();

    expect(state.controlsVisibleForProbe, isFalse,
        reason: '★★★ 正在播放时 3s 无交互必须收起控件（与全屏一致）');
    expect(find.byKey(liveEmbedBarKey).hitTestable(), findsNothing);

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('⑤ 暂停 + 3s ⇒ **不收起**（对齐全屏 `_autoHideNow` 的 `_playing` 判据）',
      (t) async {
    debugForcePlaying = false; // = 暂停态
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(640, 360);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    await t.pumpWidget(_host(
      const LiveEmbeddedPlayer(stream: null, title: '暂停'),
    ));
    await t.pump();
    final state =
        t.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));

    final mouse = await _mousePointer(t);
    await _hover(mouse, t, t.getCenter(find.byType(LiveEmbeddedPlayer)));
    await t.pump(const Duration(seconds: 3));
    await t.pump();

    expect(state.controlsVisibleForProbe, isTrue,
        reason: '★★★ 暂停时控件被自动收起了 ⇒ 用户刚按暂停就找不到播放键'
            '（与全屏 `_autoHideNow` 的 `_playing` 判据不一致）');
    expect(find.byKey(liveEmbedBarKey).hitTestable(), findsOneWidget,
        reason: '★ 暂停时控制条必须仍然可点（这是"不收"的真正意义）');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('⑥ 暂停 → 恢复播放 + 3s ⇒ 收起（证明计时器被**重新装**上了）', (t) async {
    debugForcePlaying = false;
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(640, 360);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    await t.pumpWidget(_host(
      const LiveEmbeddedPlayer(stream: null, title: '暂停后恢复'),
    ));
    await t.pump();
    final state =
        t.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));

    // ① 暂停态：装计时器（hover）→ 到点**被挡**、且一次性计时器已烧掉
    final mouse = await _mousePointer(t);
    await _hover(mouse, t, t.getCenter(find.byType(LiveEmbeddedPlayer)));
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    expect(state.controlsVisibleForProbe, isTrue, reason: '前提：暂停时不收');

    // ② 恢复播放（生产路径：`resume()` 必须**重新装**计时器）
    debugForcePlaying = true;
    await state.resume();
    await t.pump();
    expect(state.controlsVisibleForProbe, isTrue,
        reason: '刚恢复播放时控件还在（3s 还没到）');

    // ③ 再推 3s ⇒ 这次必须收起
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    expect(state.controlsVisibleForProbe, isFalse,
        reason: '★★★ 恢复播放后没有重新计时 ⇒ 控件**永远常显**'
            '（暂停那次把一次性计时器烧掉了，`resume()` 里必须重装）');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('③ 没有流（stream == null）时**不自动收起**（控制条是唯一出口）',
      (t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(640, 360);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    /*
     * 这一条钉的是**产品规则**（不是实现细节）：
     *   没选台 / 取流失败时，控制条（重试、音量）是用户唯一的出口
     *   ⇒ 不许被自动隐藏吃掉。
     * ★ 同一规则也顺带保证"不挂 Timer"，已有一批只 pump() 不 dispose 的
     *   用例不会因为 pending Timer 变红。
     */
    await t.pumpWidget(_host(
      const LiveEmbeddedPlayer(stream: null, title: '无流'),
    ));
    await t.pump();
    final bar = find.byKey(liveEmbedBarKey);

    await t.pump(const Duration(seconds: 5));
    await t.pump();
    expect(bar.hitTestable(), findsOneWidget,
        reason: '★ 没有流时控制条被自动收起了 ⇒ 用户连重试/调音量都点不到');

    await t.pumpWidget(const SizedBox.shrink());
  });
}
