// ═══════════════════════════════════════════════════════════════════════
//  Owner 1013：「播放页那些弹窗…而且还非常的卡顿（这里必须解决）」
//
//  钉住：拖弹幕**轻量悬浮窗**的四根滑杆时，**不**触发整页重建。
// ═══════════════════════════════════════════════════════════════════════
//
// # 根因（改前，有实测）
// ```text
// `_setDanmakuFontScale/Opacity/Speed/Area` 四个回调每个都 `setState`，
// 而 `PlayerPage.build()` 是一个 884 行的整页 build（含 Video / DanmakuOverlay
// / 全部浮层）。四根滑杆「拖动中每一帧都回调」
// （player_bottom_bar.dart `_quickSlider` 的注释自认）⇒ **每一帧整页重建**。
// 本仓旧探针：60 次鼠标移动 ⇒ PlayerPage 重建 60 次、元素重建 9960 次。
// ```
//
// # 改后
// ```text
// 拖动只推 `DanmakuQuickValues`（一个 ValueNotifier）：
//   · 滑杆读数在 `_quickSliders` 里由 ValueListenableBuilder 独立跟手；
//   · 画面侧的 overlay 由 `_danmakuQuickLive` 的监听者做**一次**重建。
// 判据不是"零 setState"（那样会丢"画面实时跟手"，Owner 明确不许），
// 而是**重建面**：一次拖动**不该**等价于一次「整页 884 行 build」。
// ```
//
// # 仪器：`debugOnRebuildDirtyWidget`
// ```text
// 框架每重建**一个** Element 就回调一次 ⇒ 直接数「重建了多少元素」，
// 且能按 `runtimeType` 分别统计 `PlayerPage` 本体与全树。
// 与 `test/t27_w21_return_jank_signature_test.dart` 同源手法。
// ```
//
// # ★ 正反两用（本仓铁律：假门禁比没门禁更危险）
// ```text
// ① 拖滑杆（现值：走 live）⇒ 重建面必须远小于整页 —— 且**有界**。
// ② 阴性对照：不碰任何东西空 pump 一帧 ⇒ 重建面 ≈ 0
//    （证明"小"不是因为仪器坏了，而是真的没重建）。
// ③ 阳性对照：点击类型开关（**故意保留**整页 setState 的那条路）⇒
//    必须触发整页级重建（> 200 元素）。
// ④ 「画面实时跟手」不许丢：拖动后 `DanmakuOverlay` 必须**拿到新值**
//    （直接读它 widget 的 opacity 字段 —— 这是"画面能变"的必要条件）。
// ```
//
// # 挂法
//   照 `t27_w21` ④：要 push **真** PlayerPage ⇒ `MediaKit.ensureInitialized()`
//   指向仓库自带 libmpv ⇒ 标 `native-media`（默认跳过；跑法见下）。
//   `--run-skipped --tags native-media --concurrency=1`
// ═══════════════════════════════════════════════════════════════════════

@Tags(['native-media'])
library;
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/danmaku_overlay.dart';

// ═══════════════════════════════════════════════════════════════════════
//  仪器：元素重建计数器
// ═══════════════════════════════════════════════════════════════════════

/// 这一帧**所有**元素的重建次数之和
int _all = 0;

/// 其中 `PlayerPage` 本体（`_PlayerPageState.build()` 那一层）重建了几次。
///
/// ⚠️ 只数 `PlayerPage` 这个 widget 的 Element，**不**数它子树 ——
///    子树里能重建的元素（如滑杆）不算"整页重建"。
int _pageBuilds = 0;

void _install() {
  _all = 0;
  _pageBuilds = 0;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    _all++;
    if (e.widget.runtimeType == PlayerPage) _pageBuilds++;
  };
}

void _uninstall() => debugOnRebuildDirtyWidget = null;

void _claim(WidgetTester t) {
  var n = 0;
  while (t.takeException() != null) {
    if (++n > 200) break;
  }
}

/// 真机（flutter_tester）里 `_setDanmakuXxx` 走 `DanmakuConfig`（会写 `UiPrefs`）
/// ⇒ 每次拖都会落盘。但 `UiPrefs` 在测试期是内存态（shared_prefs 走 mock），
/// 这里只是把**拖动前的初始值**记录/还原，避免跨用例串味。
double _savedFontScale = 1.0;
double _savedOpacity = 1.0;
double _savedSpeed = 8.0;
double _savedArea = 1.0;

void _savePrefs() {
  _savedFontScale = DanmakuConfig.fontScale;
  _savedOpacity = DanmakuConfig.opacity;
  _savedSpeed = DanmakuConfig.speed;
  _savedArea = DanmakuConfig.area;
}

void _restorePrefs() {
  DanmakuConfig.setFontScale(_savedFontScale);
  DanmakuConfig.setOpacity(_savedOpacity);
  DanmakuConfig.setSpeed(_savedSpeed);
  DanmakuConfig.setArea(_savedArea);
}

/// 在 `PlayerPage` 里找当前挂载的 overlay widget（读它**真实**拿到的值）
DanmakuOverlay _overlay(WidgetTester t) =>
    t.widget<DanmakuOverlay>(find.byType(DanmakuOverlay));

// ═══════════════════════════════════════════════════════════════════════
//  挂载：push 真 PlayerPage，并打开轻量悬浮窗
// ═══════════════════════════════════════════════════════════════════════

/// 挂载：push 真 PlayerPage，并打开弹幕轻量悬浮窗。
///
/// # 为什么用探针而不是 `t.tap`
/// ```text
/// flutter_tester 里没有核心库 ⇒ `_load()` 必然失败 ⇒ `_error != null`
/// ⇒ 底栏那条门控不成立 ⇒ **底栏根本不画**（齿轮也就无处可点）。
/// 仓库为此备了 `debugPlayerForceBarsForShot()`（只改 UI 状态，不碰播放器）。
/// 另外本仓铁律：flutter_tester 里 PlayerPage 整棵树的**指针回调不触发**
/// （见 test/t98 文件头、`.probe/probe_tests/README.md`）⇒ 底栏上的按钮
/// 点不动。⇒ 打开轻量悬浮窗走 `debugPlayerOpenPopoverForProbe('danmakuQuick')`
/// —— 它走**生产**的那个 `PopoverController`，与用户点齿轮同一条路。
///
/// ★ 四根滑杆的**拖动**用 `startGesture`（原始指针事件）——
///   与 `tester.drag` 同机制，不经底栏按钮那套 `InkWell` 命中，
///   这正是"拖动中每一帧都回调"的真实路径。
/// ```
Future<void> _mountPlayer(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));

  RemoteBridge.instance.stop();
  addTearDown(() => RemoteBridge.instance.stop());

  await t.pumpWidget(MaterialApp(home: ShellPage(key: debugShellKey)));
  await t.pump();
  await t.pump(const Duration(milliseconds: 200));
  _claim(t);

  final nav = Navigator.of(t.element(find.byType(ShellPage)));
  nav.push(
    MaterialPageRoute<void>(
      builder: (_) => const PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '弹幕滑杆卡顿验收',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  _claim(t);
  expect(find.byType(PlayerPage), findsOneWidget, reason: '前置：PlayerPage 没挂上');

  // 把底栏从「起播失败」那层救出来（否则齿轮不画）
  expect(debugPlayerForceBarsForShot(), isTrue);
  await t.pump();
  _claim(t);

  // 打开轻量悬浮窗（走生产那个 PopoverController）
  expect(
    debugPlayerOpenPopoverForProbe('danmakuQuick'),
    isTrue,
    reason: '前置：popover id 没打开',
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
  _claim(t);
  expect(
    find.byKey(PlayerBottomBar.danmakuQuickPanelKey),
    findsOneWidget,
    reason: '前置：轻量悬浮窗没弹出来 ⇒ 下面没有滑杆可拖',
  );
}

/// 用 `startGesture` 做**逐帧**拖动（`tester.drag` 只发一次 move，
/// 测不出"拖动中每一帧都回调"那个规模）。
Future<void> _frameByFrameDrag(
  WidgetTester t,
  Finder slider,
  double dx, {
  int steps = 8,
}) async {
  final center = t.getCenter(slider);
  final g = await t.startGesture(center);
  for (var i = 0; i < steps; i++) {
    await g.moveBy(Offset(dx / steps, 0));
    await t.pump();
  }
  await g.up();
  await t.pump();
}

void main() {
  setUpAll(() {
    final candidates = [
      File('build/windows/x64/libmpv/libmpv-2.dll'),
      File('../../../build/windows/x64/libmpv/libmpv-2.dll'),
      File('../../build/windows/x64/libmpv/libmpv-2.dll'),
    ];
    for (final dll in candidates) {
      if (dll.existsSync()) {
        MediaKit.ensureInitialized(libmpv: dll.absolute.path);
        print('DL|libmpv = ${dll.absolute.path}');
        return;
      }
    }
    print('DL|★ 警告：没找到 libmpv-2.dll ⇒ 本文件会因前置不成立而红');
  });

  setUp(_savePrefs);
  tearDown(() {
    _uninstall();
    _restorePrefs();
    RemoteBridge.instance.stop();
  });

  /// 收尾：`flutter_test` 在树拆掉后会断言「没有挂起的 Timer」。
  /// 播放页内部有若干周期性定时器/`Future.delayed`（进度轮询、角标计时…），
  /// 拆树前要把它们走完 —— 与 `t27_w21` ④ 结尾同款：多 pump 若干帧。
  ///
  /// ⚠️ 这只是**测试收尾**，不改任何生产逻辑（生产里这些定时器由
  ///    `dispose` 成对取消）。
  Future<void> settleTimers(WidgetTester t) async {
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    _claim(t);
  }

  testWidgets('DL① 拖字号滑杆逐帧 ⇒ **不**整页重建（重建面有界且与拖动帧数解耦）',
      (t) async {
    await _mountPlayer(t);

    // 前置：overlay 挂着，且拿的是初值（下面要证明它拿到了新值）
    final before = _overlay(t).fontScale;
    expect(before, closeTo(DanmakuConfig.fontScale, 1e-6),
        reason: '前置：overlay 初值应与 DanmakuConfig 一致');

    /*
     * 先量一把「一次整页 setState」的代价 —— 拿它当 DL① 的**标尺**。
     * 判据因此不依赖任何硬编码数字：拖动 N 帧的总重建必须**小于一次整页**。
     */
    _install();
    debugPlayerForceBarsForShot();
    await t.pump();
    final oneFullPage = _all;
    _uninstall();
    print('DL①|标尺：一次整页 setState 重建 $oneFullPage 个元素');

    _install();
    await _frameByFrameDrag(
      t,
      find.byKey(PlayerBottomBar.danmakuQuickFontScaleKey),
      80, // 往右拖 ⇒ 字号变大
      steps: 8,
    );
    final allDrag = _all;
    final pageDrag = _pageBuilds;
    _uninstall();
    await t.pump(const Duration(milliseconds: 20));
    final after = _overlay(t).fontScale;
    print('DL①|拖字号 8 帧：全树重建=$allDrag  PlayerPage 本体重建=$pageDrag  '
        'overlay.fontScale $before → $after');

    // ★ 判据一：**不许**重建 PlayerPage 本体（整页 884 行 build）
    //   改前：每帧 `setState` ⇒ 8 帧至少 8 次
    expect(pageDrag, 0,
        reason: '★★★ PlayerPage 本体在 8 帧拖动里重建了 $pageDrag 次 —— '
            '这正是 Owner 报的卡顿：整页 884 行 build 被拖动逐帧触发。'
            '（现值应只在滑杆 + overlay 两小块里重建，Page 本体 0 次）');

    // ★ 判据二：拖 N 帧的总重建**必须小于「一次整页 setState」** ——
    //   这就是"从『每帧一整页』变成『远比一整页便宜』"的可测表述。
    expect(allDrag, lessThan(oneFullPage),
        reason: '★★ 拖 8 帧重建了 $allDrag 个元素，而一次整页 setState 只要 '
            '$oneFullPage —— 拖动的总代价竟不亚于一次整页重建，'
            '性能收益没落到实处（旧探针：60 次移动总重建 9960 元素）。');

    // ★ 判据三（功能不许丢）：画面侧**必须**拿到新值 —— 否则"不卡"是
    //   拿"画面不跟手"换来的，那是 Owner 明确不许的。
    expect(after, greaterThan(before + 1e-6),
        reason: '★★★ 拖动后 DanmakuOverlay **没拿到**新字号 ⇒ '
            '"画面实时跟手"被弄丢了 —— 这比卡顿更严重（Owner 明确要跟手）。');
    await settleTimers(t);
  });

  testWidgets('DL② 阴性对照：不碰任何东西空 pump 一帧 ⇒ 重建面 ≈ 0', (t) async {
    await _mountPlayer(t);
    _install();
    await t.pump();
    final idle = _all;
    _uninstall();
    print('DL②|空 pump 一帧：全树重建=$idle');
    expect(idle, lessThanOrEqualTo(2),
        reason: '★ 阴性对照：什么都没改却重建了 $idle 个元素 ⇒ '
            '仪器会把"背景噪音"算进去 ⇒ DL① 的读数不可信。');
    await settleTimers(t);
  });

  testWidgets('DL③ 阳性对照：整页 setState（`debugPlayerForceBarsForShot`）⇒ 整页级重建',
      (t) async {
    await _mountPlayer(t);

    /*
     * ⚠️ 这里**不能**用 `t.tap(类型开关)` 做阳性对照：flutter_tester 里
     *    PlayerPage 整棵树的**指针回调不触发**（见 test/t98 文件头 + 实测：
     *    点开关时 `_all == 0`）⇒ tap 走不通。
     * ⇒ 改用一个**确实会整页 setState** 的探针：`debugPlayerForceBarsForShot()`
     *    （它内部 `setState(...)` 翻 `_error/_playing/_controlsVisible` 等）。
     *    它证明的是"仪器**能**看见整页级重建"，与是不是弹幕回调无关 ——
     *    这正是阳性对照要的「仪器有区分力」。
     */
    _install();
    expect(debugPlayerForceBarsForShot(), isTrue);
    await t.pump();
    final allChip = _all;
    final pageChip = _pageBuilds;
    _uninstall();
    print('DL③|整页 setState（forceBars）：全树重建=$allChip  '
        'PlayerPage 本体重建=$pageChip');

    // ★ 阳性对照必须**能**测出整页重建 —— 否则 DL① 的"小"证明不了任何事
    expect(pageChip, greaterThanOrEqualTo(1),
        reason: '★★ 阳性对照失败：一次整页 setState 却没重建 PlayerPage 本体 ⇒ '
            '仪器没有区分力 ⇒ DL① 的"不重建"读数是假的。');
    expect(allChip, greaterThan(100),
        reason: '★★ 阳性对照失败：整页 setState 只重建了 $allChip 个元素？'
            '正常应是数百（旧探针口径 166 元素/次起步）⇒ 仪器坏了。');

    // ★ 顺带给出量级对照：DL① 的拖动是 8 帧，若逐帧整页 setState
    //   ⇒ ≈ 8 × 这个数。
    print('DL③|★ 一次整页 setState ≈ $allChip 元素；'
        'DL① 拖 8 帧若走老路 ⇒ ≈ ${allChip * 8} 元素');
    await settleTimers(t);
  });

  testWidgets('DL④ 拖不透明度滑杆 ⇒ 画面侧 opacity 实时跟手', (t) async {
    await _mountPlayer(t);
    final before = _overlay(t).opacity;

    _install();
    await _frameByFrameDrag(
      t,
      find.byKey(PlayerBottomBar.danmakuQuickOpacityKey),
      -60, // 往左拖 ⇒ 透明度变小
      steps: 6,
    );
    final allDrag = _all;
    final pageDrag = _pageBuilds;
    _uninstall();
    await t.pump(const Duration(milliseconds: 20));
    final after = _overlay(t).opacity;
    print('DL④|拖不透明度 6 帧：全树重建=$allDrag  PlayerPage 本体重建=$pageDrag  '
        'overlay.opacity $before → $after');

    expect(after, lessThan(before - 1e-6),
        reason: '★★★ 拖不透明度后 overlay 没拿到新值 ⇒ 画面不跟手');
    expect(pageDrag, 0,
        reason: '★★ 6 帧拖动里 PlayerPage 本体重建了 $pageDrag 次 —— 拖动仍在'
            '驱动整页 884 行 build（应只重建滑杆 + overlay 两小块）。');
    await settleTimers(t);
  });
}
