@Tags(['native-media'])
library;

// ══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 native-media（默认不跑）—— 与 t458_hints_entry_ui_test.dart
//    / zz_t42_player_keys_test.dart / pc_arrow_keys_test.dart 同因
// ══════════════════════════════════════════════════════════════════════
//
// 本文件挂**真** PlayerPage，它在 initState 里 Player(...) 创建 media_kit
// 播放器 ⇒ 需要 libmpv-2.dll。实测在 flutter_tester 进程里加载该原生库会
// **偶发 native 崩溃**（访问违例 c0000005，退出码 79），失败形态是整文件用例
// 一起 did not complete。详见 .probe/native-media-tests.md。
//
// 手动跑：
// ```powershell
// flutter test test/t63_shot_ui_test.dart --run-skipped --tags native-media --concurrency=1
// ```
//
// ══════════════════════════════════════════════════════════════════════
//  task-21 P1-30：截图入口的**真实 widget 树**断言（底栏相机按钮 + S 键）
// ══════════════════════════════════════════════════════════════════════
//
// # 与 t63_shot_save_test.dart 的分工（两者都要有，缺一不可）
// ```text
// t63_shot_save_test.dart（纯 Dart）  截图**存哪、叫什么名字、绝不覆盖、清缓存不连坐**
// t63_shot_ui_test.dart（本文件）     截图**入口在不在、点了会不会真的触发**
// ```
// 落盘规则全对、但按钮没渲染出来（或按 S 没反应）—— 用户还是截不到图；
// 反过来入口在、落盘进了 clip-cache —— 用户点一次「清空缓存」图就没了。
//
// # ★★ 为什么必须有**阳性对照**（照抄 t458:23-26 的理由）
// 只断言「有相机按钮」是**不够**的 —— 若底栏因为别的原因压根没渲染，
// 该断言会以另一种方式失败，而『底栏没渲染』与『按钮被删了』需要能区分。
// ⇒ 所以先断言**同排的既有按钮**（全屏 / 设置齿轮）都在。
//
// # ★★★ 为什么不触发截图行（允许真实点击「更多」入口）
// media_kit 的 Player.screenshot() 在**播放器初始化完成之前不会返回、
// 也不会抛异常**（real.dart:1185 先 await waitForPlayerInitialization，
// 而它在 flutter_tester 里永远不完成）⇒ 点一下就等于挂起一个**永不完成的**
// await。所以：
// ```text
// ✗ await t.tap(find.byIcon(Icons.photo_camera));   // 会挂住
// ✓ 按 S 键（同一分支的键位路径）—— 触发是**同步**的（计数先加，await 在后）
// ```
// ★ 断言用只读探针 debugPlayerScreenshotCalls()（player_page.dart:9185），
//   它读的是 _screenshotCalls —— 那个自增写在 await **之前**，
//   所以「键到了没有」可以同步测到，不需要等那张图。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart' show PlayerBottomBar, PlayerPopoverIds;
import 'package:sourin_spike/ui/player/player_more_menu.dart';
import 'package:sourin_spike/ui/player/player_popover.dart' show PopoverAnchorButton, PopoverMotion;
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/remote_bridge.dart';

List<Episode> eps(int n) => [
  for (var i = 1; i <= n; i++)
    Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
];

/// 挂载**真实** PlayerPage，窗口 = 1280x800
///
/// ⚠️⚠️ 视口用 t.view.physicalSize / devicePixelRatio，**不用**
///    setSurfaceSize —— 这是 bottom_bar_fit_test.dart:71-87 用 3 个假红
///    换来的铁律：setSurfaceSize 只改**布局约束**，FlutterView 的
///    metrics 不动 ⇒ MediaQuery 读到的还是 flutter_test 默认的 800x600@3.0
///    ⇒ 布局与 MediaQuery **打架**，修好的代码也会报红。
Future<void> mount(
  WidgetTester t, {
  bool isTv = false,
  bool isTouchOnly = false,
  int frames = 1,
}) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(1280, 800);
  addTearDown(t.view.reset);

  final episodes = eps(3);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: 'task-21 P1-30 截图入口',
        episodes: episodes,
        episodeIndex: 0,
        episodeId: episodes.first.id,
        episodeTitle: episodes.first.title,
        isTv: isTv,
        isTouchOnly: isTouchOnly,
      ),
    ),
  );
  /*
   * ★ frames 默认 1（只推首帧）是**刻意的**：
   *   _load() 挂在 addPostFrameCallback（player_page.dart:1628）上，
   *   而 flutter_tester 里 sourin_core.dll 加载不了 ⇒ _load() 必失败
   *   ⇒ _error 置上 ⇒ **底栏整条消失**（门控在 player_page.dart:7878-7886）
   *   ⇒ 多推几帧反而量不到底栏。
   *   首帧时 _loading 为 true、_error 为 null ⇒ 底栏在（已被
   *   .probe/yamby/bottombar_measure_test.dart 实测到：可用宽 1248.00）。
   *
   * ★ 按键用例用 frames: 6（照抄 zz_t42:92-94）—— 那条判据不依赖底栏，
   *   而焦点树需要几帧才稳。
   */
  for (var i = 1; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// 把挂起的定时器推完（否则用例结束报 A Timer is still pending）
///
/// ★ 照抄 t458_hints_entry_ui_test.dart:62-71 与理由：有 sourin_core.dll
///   时会多一个 resolveStream 的 120s timeout。
/// ★ addTearDown 里 pump **无效**（_verifyInvariants 之后才跑）
///   ⇒ 必须在用例返回**前**推时间（pc_arrow_keys_test.dart:145-175）。
Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}

/// 一次完整的按键（down + up）—— 与真人敲键一致（照抄 zz_t42:109-114）
Future<void> tapKey(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyDownEvent(k);
  await t.pump(const Duration(milliseconds: 40));
  await t.sendKeyUpEvent(k);
  await t.pump(const Duration(milliseconds: 40));
}

/// 认领一次 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 在**捕获窗口**内执行 [body]：渲染异常正文记进 [sink]，并照旧转发
///
/// ★ 逐字照抄 t486_edge_row_label_fit_test.dart:49-76（连同它踩过的坑）：
///   同一个 pump 抛**多条**时 takeException() 只给一句
///   Multiple exceptions (2) were detected…，overflowed by N pixels
///   这种**正文全丢** —— 而我们要断言的恰恰是正文。
/// ★ 转发给 prev 是**刻意**的：本文件只是「顺带记一份」，
///   flutter_test 自己的异常账本不受影响（所以下面还要 _claim 清账）。
Future<void> _guard(List<String> sink, Future<void> Function() body) async {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    sink.add(details.exceptionAsString().split('\n').first);
    prev?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prev;
  }
}


/// Scope the positive controls to the actual mounted bottom bar.
Finder _bottomBar() => find.byType(PlayerBottomBar);

Finder _fullscreenButton() => find.descendant(
  of: _bottomBar(),
  matching: find.byWidgetPredicate(
    (widget) => widget is ui.IconButton && widget.tooltip == '全屏',
    description: 'Miuix fullscreen control with the existing tooltip',
  ),
);

Finder _moreAnchor() => find.descendant(
  of: _bottomBar(),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is PopoverAnchorButton &&
        widget.id == PlayerPopoverIds.more &&
        widget.tooltip == '更多',
    description: 'mounted More popover anchor',
  ),
);

/// Observe real geometry/blockers/hit path; never replace a reachability pass.
void _logMoreReachability(
  WidgetTester t,
  Finder menu,
  Finder row,
  String phase,
) {
  final blockers = <String>[];
  var scrollables = 0;
  t.element(row).visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is IgnorePointer) {
      blockers.add('IgnorePointer=${widget.ignoring}');
    } else if (widget is AbsorbPointer) {
      blockers.add('AbsorbPointer=${widget.absorbing}');
    } else if (widget is Opacity) {
      blockers.add('Opacity=${widget.opacity}');
    } else if (widget is AnimatedOpacity) {
      blockers.add('AnimatedOpacity.target=${widget.opacity}');
    } else if (widget is FadeTransition) {
      blockers.add('FadeTransition=${widget.opacity.value}/${widget.opacity.status}');
    } else if (widget is PopoverMotion) {
      blockers.add('PopoverMotion.visible=${widget.visible}');
    } else if (widget is Scrollable) {
      scrollables++;
    }
    return true;
  });
  final controller = t.widget<PopoverAnchorButton>(_moreAnchor()).controller;
  final hit = HitTestResult();
  final center = t.getCenter(row);
  t.binding.hitTestInView(hit, center, t.view.viewId);
  final path = hit.path.map((entry) => entry.target.runtimeType.toString()).toList();
  final barOpacity = find.descendant(of: _bottomBar(), matching: find.byType(Opacity))
      .evaluate().map((element) => (element.widget as Opacity).opacity).toList();
  final barIgnore = find.descendant(of: _bottomBar(), matching: find.byType(IgnorePointer))
      .evaluate().map((element) => (element.widget as IgnorePointer).ignoring).toList();
  debugPrint(
    '[SHOT-MORE] $phase openId=${controller.openId} '
    'anchor=${controller.anchorRectOf(PlayerPopoverIds.more)} '
    'menu=${t.getRect(menu)} row=${t.getRect(row)} center=$center '
    'view=${t.view.physicalSize / t.view.devicePixelRatio} '
    'scrollables=$scrollables blockers=$blockers '
    'barOpacity=$barOpacity barIgnore=$barIgnore '
    'hit=${row.hitTestable().evaluate().length} path=$path',
  );
}

/// Advance at most 960ms, checking the production enter/unmount phase.
/// Pumping separately flushes pointer arbitration, post-frame anchor reports,
/// animation registration and the existing retained-panel onEnd removal.
Future<bool> _waitForMorePhase(WidgetTester t, {required bool open}) async {
  final controller = t.widget<PopoverAnchorButton>(_moreAnchor()).controller;
  Rect? previousRect;
  for (var frame = 0; frame < 24; frame++) {
    await t.pump();
    await t.pump(const Duration(milliseconds: 40));
    final menu = find.byType(PlayerMoreMenu);
    final menuCount = menu.evaluate().length;
    if (!open) {
      if (controller.openId == null && menuCount == 0) {
        debugPrint('[SHOT-MORE-PHASE] closed frames=${frame + 1} openId=null menu=0');
        return true;
      }
      continue;
    }
    if (controller.openId != PlayerPopoverIds.more || menuCount != 1) {
      previousRect = null;
      continue;
    }
    final shot = find.descendant(of: menu, matching: find.text('截图'));
    if (shot.evaluate().length != 1) {
      previousRect = null;
      continue;
    }
    final row = find.ancestor(of: shot, matching: find.byType(miuix.MiuixPressable));
    if (row.evaluate().length != 1) {
      previousRect = null;
      continue;
    }
    final element = t.element(row);
    final fade = element.findAncestorWidgetOfExactType<FadeTransition>();
    final motion = element.findAncestorWidgetOfExactType<PopoverMotion>();
    final rect = t.getRect(row);
    final atEndpoint = motion?.visible == true &&
        fade?.opacity.value == 1.0 &&
        fade?.opacity.status == AnimationStatus.completed;
    final ready = atEndpoint && row.hitTestable().evaluate().length == 1;
    if (ready && rect == previousRect) {
      _logMoreReachability(t, menu, row, 'open-endpoint');
      debugPrint('[SHOT-MORE-PHASE] open frames=${frame + 1} fade=1 geometry=stable hit=1');
      return true;
    }
    previousRect = ready ? rect : null;
  }
  debugPrint('[SHOT-MORE-PHASE] timeout open=$open openId=${controller.openId} '
      'menu=${find.byType(PlayerMoreMenu).evaluate().length}');
  return false;
}

/// Click only More; inspect the actual menu and enabled screenshot row.
/// This establishes reachability without claiming capture/save completion.
Future<void> _expectMoreScreenshotReachable(WidgetTester t) async {
  expect(_bottomBar(), findsOneWidget);
  final more = _moreAnchor();
  expect(more, findsOneWidget, reason: '更多入口必须仍在实际底栏上');
  expect(
    find.descendant(of: more, matching: find.byIcon(Icons.more_horiz)),
    findsOneWidget,
  );
  expect(find.descendant(of: more, matching: find.text('更多')), findsOneWidget);
  expect(find.byType(PlayerMoreMenu), findsNothing);
  final before = debugPlayerScreenshotCalls();
  expect(before, isNotNull);

  await t.tap(more);
  expect(
    await _waitForMorePhase(t, open: true),
    isTrue,
    reason: '更多必须在有界时间内真正进入动画端点，截图行几何稳定且可命中',
  );

  final menu = find.byType(PlayerMoreMenu);
  expect(menu, findsOneWidget, reason: '真实点击更多后必须渲染浮层');
  expect(find.descendant(of: menu, matching: find.text('画面')), findsOneWidget);
  final shot = find.descendant(of: menu, matching: find.text('截图'));
  expect(shot, findsOneWidget, reason: '截图项必须真的渲染在更多浮层中');
  final row = find.ancestor(of: shot, matching: find.byType(miuix.MiuixPressable));
  expect(row, findsOneWidget);
  _logMoreReachability(t, menu, row, 'open-ready');
  expect(row.hitTestable(), findsOneWidget, reason: '截图项必须在可点击的画面区域');
  expect(t.widget<miuix.MiuixPressable>(row).onPressed, isNotNull);
  expect(
    find.descendant(of: row, matching: find.byIcon(Icons.photo_camera)),
    findsOneWidget,
  );
  expect(debugPlayerScreenshotCalls(), before, reason: '打开更多不应提前触发截图');

  await t.tap(more);
  expect(
    await _waitForMorePhase(t, open: false),
    isTrue,
    reason: '再次点击后必须真正关闭并在有界时间内完成生产退场卸载',
  );
  expect(find.byType(PlayerMoreMenu), findsNothing, reason: '再点更多必须正常收起');
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('★★ 阳性对照 + ⑫（重做后）：截图入口在「更多」浮层里，不在底栏按钮行', (t) async {
    await mount(t);

    expect(
      _fullscreenButton(),
      findsOneWidget,
      reason: '★★ 阳性对照：实际底栏的既有全屏按钮必须仍在',
    );
    expect(t.widget<ui.IconButton>(_fullscreenButton()).onPressed, isNotNull);
    expect(
      find.descendant(of: _bottomBar(), matching: find.byIcon(Icons.photo_camera)),
      findsNothing,
      reason: '相机不应直接躺在底栏，低频截图项应收进更多',
    );
    await _expectMoreScreenshotReachable(t);
    await drain(t);
  });

  testWidgets('⑭ 1280x800 挂载后**没有** RenderFlex overflow', (t) async {
    final sink = <String>[];
    await _guard(sink, () async {
      await mount(t);
    });
    _claim(t);

    /*
     * ★ 判据⑭（PLAN.md:268-271）：加了第 14 个按钮之后，1280x800 下
     *   底栏**不许**溢出。
     *
     * 依据（.probe/yamby/measure_run.txt，实测不是估算）：
     * ```text
     * ① 行固有宽度(getMaxIntrinsicWidth) = 960.60
     * ② 可用宽度（底栏 Container 内）= 1248.00
     * ⇒ 加这一枚（同款 IconButton 实测 48.00）后 = 1008.60 ≤ 1248.00（余 239.40）
     * ```
     * ⚠️ 这里**只**断言「没有溢出」，**不**断言具体宽度 ——
     *   宽度是外观读数，会随文案变；溢出才是缺陷。
     * ⚠️ 也**不许**用「改 _kBottomBarFitWidth」来消红（Lead 裁决⑩）：
     *   那个常量是「要不要走横向滚动」的下界，与「装不装得下」是两件事。
     */
    final overflows = sink
        .where((e) => e.contains('overflow'))
        .toList(growable: false);
    expect(
      overflows,
      isEmpty,
      reason:
          '★★ 1280x800 下底栏不许溢出（实测余量 239.40）。'
          ' 若这条红了：要么按钮真的多了，要么 mount 的窗口不是 1280x800'
          '（t.view.physicalSize / devicePixelRatio 一起设才算，见 mount 的注释）',
    );

    await drain(t);
  });

  testWidgets('⑬ PC 按 S ⇒ 截图被触发一次（只读探针计数）', (t) async {
    await mount(t, frames: 6);

    final before = debugPlayerScreenshotCalls();
    expect(before, isNotNull, reason: '★ 前置条件：探针能读到状态（null = 播放页状态没建起来）');

    /*
     * ★ 按键而**不点按钮**：_takeScreenshot() 里的
     *   await _player.screenshot(...) 在 flutter_tester 里永不返回
     *   （real.dart:1185 等 waitForPlayerInitialization，它只在
     *   idle-active 时完成）⇒ 点按钮会挂住整条用例。
     * ★ 而计数 _screenshotCalls++ 写在那个 await **之前**
     *   （player_page.dart:3344-3345）⇒ 「键到没到」同步可测。
     */
    await tapKey(t, LogicalKeyboardKey.keyS);

    expect(
      debugPlayerScreenshotCalls(),
      before! + 1,
      reason:
          '★★ 判据⑬：PC 按 S 必须触发截图一次'
          '（原版 ArtPlayer 的 hk.add(KeyS, ...)；分支在 player_page.dart:6981-6985）',
    );

    await drain(t);
  });

  testWidgets('★★ S 键：浮层打开时**不许**触发截图（门控必须写在分支里面）', (t) async {
    await mount(t, frames: 6);

    final opened = debugPlayerOpenHintsForProbe();
    await t.pump(const Duration(milliseconds: 80));
    expect(opened, isTrue, reason: '★★ 前置条件：浮层必须**真的打开了** —— 否则本用例测的是「无浮层」');
    expect(
      debugPlayerAnySheetOpen(),
      isTrue,
      reason: '★★ 断言「浮层打开」这个状态本身（不靠推断）',
    );

    final before = debugPlayerScreenshotCalls()!;
    await tapKey(t, LogicalKeyboardKey.keyS);
    expect(
      debugPlayerScreenshotCalls(),
      before,
      reason:
          '★★ 浮层挡着画面时按 S 不许截图 —— 用户看不见，只会觉得「怎么多了个文件」。'
          ' 门控写在 S 分支**里面**（与空格分支同源，player_page.dart:6979-6982）：'
          ' 若写成函数开头的全局 if (_anySheetOpen) return ignored;，'
          ' Enter 的既有逻辑（浮层里激活项）就会被改坏',
    );

    await drain(t);
  });

  testWidgets('★ 触摸端也有截图入口（在「更多」浮层里，与桌面同一形态）', (t) async {
    await mount(t, isTouchOnly: true);
    expect(
      find.descendant(of: _bottomBar(), matching: find.byIcon(Icons.photo_camera)),
      findsNothing,
      reason: '触摸模式也应把截图收在更多浮层中',
    );
    await _expectMoreScreenshotReachable(t);
    await drain(t);
  });
}
