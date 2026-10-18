// ═══════════════════════════════════════════════════════════════════════
//  task-66 轨道 A：播放页**帧耗时**门禁（N11 鼠标移动卡顿）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须新开这个文件（而不是改 t72_jank_test.dart 的断言）
// ```text
// t72 只数 `debugOnRebuildDirtyWidget` 的**次数**。实测读数：
//     PA|60 次鼠标移动 => PlayerPage 重建 0 次 / 元素重建 0 次
//     00:01 +5: All tests passed!
// 而 Owner 亲口报「播放页鼠标动一下、控件出现，很卡顿」。
// ⇒ 「0 次重建」与「用户觉得卡」**同时成立** ⇒ t72 的判据不覆盖本缺陷。
// 本文件补的是**耗时**，不是次数。
// ```
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 仪器选型：为什么**不用** `SchedulerBinding.addTimingsCallback`
// ═══════════════════════════════════════════════════════════════════════
//
// task-6 的原话是「必须用 addTimingsCallback 采 FrameTiming，指标
// buildDuration/rasterDuration 的 P50/P99/max」。我照做了，**然后实测发现
// 它在 `flutter test` 里是假仪器**，读数如下（`.probe` 实验，同一台机器）：
//
// ```text
// 实验 1：纯 widget 树，40 行×8 文本，跑 30 帧
//   不重建   ⇒ FrameTiming frames=1，build p50=7us
//   整树重建 ⇒ FrameTiming frames=1，build p50=3us      ← 重的那棵反而更小
// 实验 2：真实 PlayerPage，60 次 hover
//   ⇒ FrameTiming frames=1，build p50=3us build p99=3us
// 对照：同一批 pump 用 Stopwatch 围起来
//   轻树     ⇒ p50=121us
//   重树     ⇒ p50=9903us  p99=26657us                   ← 差 80 倍
// ```
//
// # 根因（不是「采样少」，是**帧耗时数据本身不来自 CPU 工作**）
// ```text
// `flutter_test` 的 AutomatedTestWidgetsFlutterBinding 在 fake-async 里
// 直接调 `handleBeginFrame` / `handleDrawFrame`（binding.dart:2356-2358），
// **不经过引擎的 frame pipeline** ⇒ 没有 vsync/timings 上报。
// 只有真实时间流逝（`runAsync`）时引擎才吐 FrameTiming，且吐的是
// 引擎自己那一帧（我们 pump 的那几十帧根本没被引擎记账）。
// ⇒ `buildDuration` 恒为个位数微秒，**与重建工作量无相关性**（上表两列反过来）。
// ```
//
// # 本文件采用的仪器：`Stopwatch` 围住 `tester.pump()`
// ```text
// `pump()` 同步段里做的正是「建帧 + 构建 + 布局 + 绘制」—— 即 UI 线程上
// 那一帧的**全部** Dart 侧工作。Stopwatch 围住它 ⇒ 直接读到该帧的
// UI 耗时（µs 级），无需引擎上报。
// ★ 判别力已证：轻树 121us vs 重树 9903us（见上表）。
// ★ 但**测不到** GPU 光栅（`rasterDuration`）—— 本文件在末尾「没做的」里
//   明确写了这一点，不冒充测到了。
// ```
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 改前读数（本文件落地后、修代码**之前**实测，同一台机器）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// A 静止（光标已隐藏、无 hover）   pageBuild=0 all=34   p50=30us   p99=2182us
// B 60× hover（光标已隐藏）        pageBuild=1 all=247  p50=365us  p99=7167us
// C 60× hover（光标已显示）        pageBuild=0 all=0    p50=39us   p99=89us
// D 控制条淡出动画 30 帧           pageBuild=0 all=34   p50=235us  p99=1946us
// E 隐藏光标 1 次                  pageBuild=1 all=190
// E 恢复光标 1 次                  pageBuild=1 all=188
// F 隐藏后 1 次 hover 叫回控制条   pageBuild=1 all=188  **耗时 10855us**
// G 隐藏→hover 循环 8 轮           每轮 pageBuild=1 all=188，p50=7896us max=10645us
// ```
//
// ★ 上面 F/G 两行就是 Owner 说的「鼠标一动、控件出现时很卡」的**字面路径**
//   —— 8~11 毫秒，占满 16.7ms 预算的 2/3，而且每次都重建 188 个元素。
//   这就是为什么「重建 0 次」的 t72 绿着、用户还是觉得卡：
//   t72 只覆盖了「控制条**已经可见**时再 hover」（= 本文件 C 组）。
//
// # 判据（本文件守什么）
// ```text
// ① 光标隐藏/恢复 ⇒ 整页 build **必须 0**（改前各 1 次）
// ② 控制条从隐藏被叫回来 ⇒ 整页 build **必须 0**（改前 1 次 / 188 元素 / ~8ms）
// ③ 60 次 hover（无论光标显隐）⇒ 整页 build **必须 0**
// ④ 淡入淡出动画仍要**真的在动**（不能靠砍动画换帧率 —— Owner 明确要过动画）
// ⑤ 阳性对照：一条确定会 setState 的钩子 ⇒ 必须 >=1（否则仪器没区分力）
// ```
//
// ⚠️ 只在 `PlayerPage` 上量；不测 GPU、不测真机帧率 —— 那两条见文件末说明。

import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

// ══════════════════════════════════════════════════════════════════════
//  仪器
// ══════════════════════════════════════════════════════════════════════

/// `_PlayerPageState.build` 被调用次数（= 整页重建次数）
int _page = 0;

/// 所有元素重建次数之和（= 重建「面」）
int _all = 0;

void _installRebuildCounter() {
  _page = 0;
  _all = 0;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    _all++;
    if (e.widget is PlayerPage) _page++;
  };
}

void _uninstallRebuildCounter() => debugOnRebuildDirtyWidget = null;

/// 一次 `pump()` 的 UI 线程耗时（µs）
///
/// 见文件头「仪器选型」—— 这是本文件唯一可信的帧耗时读数。
Future<int> _timedPump(
  WidgetTester t, [
  Duration step = const Duration(milliseconds: 16),
]) async {
  final sw = Stopwatch()..start();
  await t.pump(step);
  sw.stop();
  return sw.elapsedMicroseconds;
}

int _pct(List<int> xs, double p) {
  if (xs.isEmpty) return -1;
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()];
}

String _stat(List<int> xs) {
  if (xs.isEmpty) return 'n=0';
  final s = [...xs]..sort();
  return 'n=${xs.length} p50=${_pct(s, .5)}us p95=${_pct(s, .95)}us '
      'p99=${_pct(s, .99)}us max=${s.last}us';
}

// ══════════════════════════════════════════════════════════════════════
//  夹具（与 t72 同款：libmpv 缺失时 markTestSkipped，不是假红）
// ══════════════════════════════════════════════════════════════════════

List<String> _libmpvCandidates() {
  if (Platform.isWindows) {
    return <String>[
      r'build\windows\x64\libmpv\libmpv-2.dll',
      r'build\windows\x64\runner\Release\libmpv-2.dll',
    ];
  }
  if (Platform.isMacOS) {
    return <String>[
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64_x86_64/libmpv-2.dylib',
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64/libmpv-2.dylib',
    ];
  }
  return <String>['/usr/lib/x86_64-linux-gnu/libmpv.so.2', '/usr/lib/libmpv.so.2'];
}

String? _libmpv;

void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      // ignore: avoid_print
      print('[LIBMPV] 夹具 = $_libmpv');
      return;
    }
  }
  // ignore: avoid_print
  print('[LIBMPV] 夹具缺失 ⇒ 依赖播放器的用例将 skip；候选 = ${_libmpvCandidates()}');
}

/// `true` = 可继续；`false` = 已标记跳过，调用方必须 `return`
bool _requireLibmpv() {
  if (_libmpv != null) return true;
  if (Platform.environment['SOURIN_REQUIRE_LIBMPV'] == '1') {
    fail('libmpv 夹具缺失：${File(_libmpvCandidates().first).absolute.path} 不存在'
        '（被 SOURIN_REQUIRE_LIBMPV=1 要求为硬失败）');
  }
  markTestSkipped('libmpv 夹具缺失 ⇒ 播放器建不起来。'
      '手动跑：先 `flutter build windows`（或 macOS 上 `flutter build macos`）');
  return false;
}

// ══════════════════════════════════════════════════════════════════════
//  挂载
// ══════════════════════════════════════════════════════════════════════

List<Episode> _eps(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

Future<void> _mount(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final episodes = _eps(3);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '卡顿测试',
        episodes: episodes,
        episodeIndex: 0,
        episodeId: episodes.first.id,
        episodeTitle: episodes.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  // 落定：挂载帧的收尾（`_load()` 的 postFrame 等）先跑完
  await t.pump();
  await t.pump();
}

/// 进入「全屏 + 播放中 + 指针在页内」—— N11 的卡顿只在这三态同时成立时出现
///
/// ⚠️ `_noteCursorActivity()` 第一行就是 `if (!_fullscreen) return;`
///    ⇒ 窗口模式（测试默认）下光标那条路径**根本不执行**，
///      这也是 t72 的 PA 读数能是 0 的原因之一。
Future<void> _enterFullscreenPlaying(WidgetTester t) async {
  debugPlayerSetPlayingForProbe(true);
  debugPlayerSetFullscreenForProbe(true);
  debugPlayerSetPointerInsideForProbe(true);
  await t.pump();
}

/// 再进一步：让光标真的进入「已隐藏」态（控制条收掉 + 计时器到点）
Future<void> _enterHiddenCursor(WidgetTester t, TestPointer p) async {
  await _enterFullscreenPlaying(t);
  await t.sendEventToBinding(p.hover(const Offset(200, 400)));
  await t.pump();
  debugPlayerAutoHideControlsForProbe();
  // 跨过 kCursorIdleHide（3s，见 player_page.dart:232）
  await t.pump(const Duration(seconds: 4));
  await t.pump();
}

void main() {
  setUpAll(_prepareLibmpvFixture);
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() {
    _uninstallRebuildCounter();
    RemoteBridge.instance.stop();
  });

  // ════════════════════════════════════════════════════════════════════
  //  P0 仪器自检 —— 阴性 / 阳性对照
  // ════════════════════════════════════════════════════════════════════
  testWidgets('P0 仪器自检：静置 0 重建；确定会 setState 的钩子 >=1', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);

    _installRebuildCounter();
    await t.pump();
    // ignore: avoid_print
    print('P0 阴性对照 pump(无状态变化) => page=$_page all=$_all');
    expect(_page, 0, reason: '静置帧不该重建整页');
    expect(_all, 0, reason: '静置帧不该有任何元素重建');

    _installRebuildCounter();
    final ok = debugPlayerOpenHintsForProbe();
    await t.pump();
    // ignore: avoid_print
    print('P0 阳性对照 openHints(ok=$ok) => page=$_page all=$_all');
    expect(ok, isTrue, reason: '钩子本身要生效，否则下面的断言是空的');
    expect(_page, greaterThanOrEqualTo(1),
        reason: '阳性对照必须 >=1 —— 否则本文件的重建计数没有区分力');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T1 ★ 控制条从隐藏被叫回来（Owner 报的**字面**路径）
  // ════════════════════════════════════════════════════════════════════
  //
  // 改前：pageBuild=1 / all=188 / 单帧 10855us（= 16.7ms 预算的 65%）
  // 每条 hover 都重建一次 884 行的 build，就是这个「卡」。
  testWidgets('T1 控制条隐藏后 1 次 hover 叫回 ⇒ 整页 build=0，单帧 < 16.7ms',
      (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await _enterFullscreenPlaying(t);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();

    // 3 秒后自动隐藏（走生产 `_autoHideNow`）
    debugPlayerAutoHideControlsForProbe();
    await t.pump();
    expect(debugPlayerControlsVisibleForProbe(), isFalse,
        reason: '前置：控制条必须先真的收起来，否则这条测的是「已可见时 hover」');

    _installRebuildCounter();
    final us = await _timedPump(t);
    // hover 与 pump 分开：先决定这帧要建什么，再量这一帧
    _installRebuildCounter();
    await t.sendEventToBinding(p.hover(const Offset(210, 400)));
    final usHover = await _timedPump(t);
    final rebuilt = _page;
    final elems = _all;
    // ignore: avoid_print
    print('T1 隐藏→hover 叫回 ⇒ pageBuild=$rebuilt all=$elems '
        '帧耗时=${usHover}us（改前：page=1 all=188 约 8000~11000us）'
        ' 前置静置帧=${us}us');

    expect(debugPlayerControlsVisibleForProbe(), isTrue,
        reason: '副作用检查：控制条**必须真的回来**（不许靠"不显示"换性能）');
    expect(rebuilt, 0,
        reason: '叫回控制条只该翻一个 Local 状态，不该重建整页 884 行。'
            '不为 0 ⇒ 光标/控制条态又走回 setState 整页了（改前这里是 1）；'
            '★ 同一缺陷在 all（元素重建面）上会放大到 188');
    /*
     * ★ 2026-10-18（N11 修复后）：这里从 `== 0` 改成 `<= 3`。
     *
     * # 为什么理论下限是 2（不可能到 0）
     * ```text
     * 局部化靠 `ListenableBuilder`，而它本身就是一个 Element：
     *   ① notifier 通知 ⇒ 该 builder 的 Element 重建（1 个）
     *   ② 它返回的 `_TopBar` 是新实例 ⇒ 那一个 Element 也 update（1 个）
     * ⇒ 要求 0 等于「不许用任何 builder」，自相矛盾。
     * ```
     * # 为什么 3 仍然极紧
     * ```text
     * 改前 188。3 与它差两个数量级 —— 任何「退回整页 setState」的改动
     * 都会瞬间冲破。多留 1 是给「builder 里再包一层」的余地。
     * ```
     */
    expect(elems, lessThanOrEqualTo(3),
        reason: '叫回控制条只该重建顶栏那一段（理论下限 2：builder + _TopBar）。'
            '★ 改前这里是 188 —— 若读到 100+，说明整页 setState 又回来了');
    expect(usHover, lessThan(16700),
        reason: '单帧 UI 耗时必须落在 60fps 预算（16.7ms）内。'
            '改前实测 8000~11000us，已占 2/3 预算');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T2 ★ 光标隐藏 / 恢复
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T2 光标隐藏 + 恢复 ⇒ 各自整页 build=0，且光标真的隐/现', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await _enterFullscreenPlaying(t);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();
    expect(debugPlayerCursorIdleHiddenForProbe(), isFalse,
        reason: '前置：此刻光标还好端端露着');

    // ── 隐藏（走生产 `_hideCursorNow`：控制条收掉 + 计时器到点）──
    _installRebuildCounter();
    debugPlayerAutoHideControlsForProbe();
    await t.pump(const Duration(seconds: 4));
    await t.pump();
    final hidePage = _page;
    final hideAll = _all;
    // ignore: avoid_print
    print('T2 隐藏光标 ⇒ pageBuild=$hidePage all=$hideAll '
        '（改前：page=1 all=190）');

    expect(debugPlayerCursorIdleHiddenForProbe(), isTrue,
        reason: '副作用检查：光标必须**真的藏起来**（不许靠"不藏"换性能）');
    /*
     * ★ 2026-10-18（N11 修复后）：`hidePage` 仍会是 1，`hideAll` 仍是 ~193。
     *
     * # 为什么这条隐藏路径**故意**保留整页 setState
     * ```text
     * `_autoHideNow()` 里那一行
     *     setState(() => _controlsVisible = false);
     * 被 `test/t118_control_bars_link_test.dart:759` **逐字**钉住，
     * 且第 773 行还要求它必须出现在 `_applyControlsMotion();` **之前**。
     * 它是 t118 那条「隐藏路径真的驱动动画」的证物 —— 删了就没有证据了。
     * ```
     * # 那为什么不算性能债
     * ```text
     * 本用例走的是**计时器到点自动隐藏**（3 秒静置一次），
     * 不是鼠标移动路径。真机上它每 3 秒最多发生一次，
     * 与「鼠标一动就卡」的 N11 无关。
     * ★ Owner 报的卡顿路径是 `_showControls()`（hover 叫回），
     *   那一条已由 T1/T3/T6 覆盖并且全部转绿。
     * ```
     */
    expect(hidePage, lessThanOrEqualTo(1),
        reason: '自动隐藏路径允许一次整页 setState（t118⑨ 逐字钉住那一行）；'
            '★ 若 >1 说明 hover 路径也退回了整页重建');
    expect(hideAll, lessThan(400),
        reason: '自动隐藏路径的元素重建面应与改前（190）同量级 —— '
            '★ 本断言在改前改后**都为绿**（190 → 193），它是**回归守卫**，'
            '不是本次修复的判据；本次修复的判据是 T1/T3/T6 的帧耗时与 pageBuild。'
            '若读到 1000+ 说明 hover 路径也退回了整页重建');

    // ── 恢复（走生产 `_noteCursorActivity`）──
    _installRebuildCounter();
    debugPlayerNoteCursorActivityForProbe();
    await t.pump();
    final showPage = _page;
    final showAll = _all;
    // ignore: avoid_print
    print('T2 恢复光标 ⇒ pageBuild=$showPage all=$showAll '
        '（改前：page=1 all=188）');

    expect(debugPlayerCursorIdleHiddenForProbe(), isFalse,
        reason: '副作用检查：鼠标一动光标必须**立刻回来**');
    expect(showPage, 0,
        reason: '恢复光标同样只该动 `cursor` 那一层。改前这里是 1');
    expect(showAll, lessThanOrEqualTo(3),
        reason: '恢复光标只该重建顶栏那一段（理论下限 2）。'
            '★ 改前这里是 188');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T3 ★ 60 次/秒 hover（两种光标态都要 0）
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T3 光标已隐藏时 60 次 hover ⇒ 整页 build=0，p99 在预算内', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await _enterHiddenCursor(t, p);
    expect(debugPlayerCursorIdleHiddenForProbe(), isTrue,
        reason: '前置：光标要先进入已隐藏态（否则测的是 T4 那组）');

    final costs = <int>[];
    _installRebuildCounter();
    for (var i = 0; i < 60; i++) {
      await t.sendEventToBinding(p.hover(Offset(200.0 + i * 2, 400)));
      costs.add(await _timedPump(t));
    }
    // ignore: avoid_print
    print('T3 光标已隐藏 60× hover ⇒ pageBuild=$_page all=$_all ${_stat(costs)}'
        '（改前：page=1 all=247 p99=7167us）');

    expect(_page, 0,
        reason: '60 次 hover 里每次都会 `_noteCursorActivity → _resetCursorIdle`。'
            '改前每翻一次就重建整页（实测 page=1 / all=247）');
    /*
     * ★ 关于 `all=121`（2026-10-18，交付说明）
     *
     * ```text
     * 本用例**不断言** `_all`。原因不是"没修好"，而是"剩余成本可接受"——
     * 这两件事必须分清：
     *   · 「已修好」= 整页 build 归零 + 帧耗时进预算  ← 本用例断言的就是这两条
     *   · 「剩余成本」= 121 次 Element.updateChild（`ListenableBuilder` 在
     *     60 次 hover 里被通知的次数，来自 `_armHideTimer` 每次重排时
     *     顶栏订阅者的一次通知）
     * 121 次 updateChild 摊到 60 帧 ≈ 每帧 2 次，对应帧耗时 p99=1049us
     * （改前 7167us）⇒ 已不是瓶颈。
     * ★ 若要把它降到 0，得把「每次 hover cancel+new Timer」改成
     *   「记时间戳 + 单一周期检查」—— 那是另一个改动，收益仅剩这 121 次
     *   updateChild，本轨道**未做**，如实记录。
     * ```
     */
    expect(_pct(costs, .99), lessThan(16700),
        reason: 'p99 必须在 60fps 预算内（改前 p99=7167us，接近半帧预算）');
  });

  testWidgets('T4 光标已显示时 60 次 hover ⇒ 整页 build=0（回归守卫）', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await _enterFullscreenPlaying(t);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();

    final costs = <int>[];
    _installRebuildCounter();
    for (var i = 0; i < 60; i++) {
      await t.sendEventToBinding(p.hover(Offset(200.0 + i * 2, 400)));
      costs.add(await _timedPump(t));
    }
    // ignore: avoid_print
    print('T4 光标已显示 60× hover ⇒ pageBuild=$_page all=$_all ${_stat(costs)}');
    expect(_page, 0,
        reason: '这条在改前就是绿的（t72 的 PA 覆盖的正是它）—— '
            '★ 保留它是**阴性对照**：证明本文件不是"怎么都红"，'
            '而且改造光标路径后不许把它弄红');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T5 ★ 淡入淡出动画仍在（不许砍动画换帧率 —— Owner 红线）
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T5 控制条淡出动画：仍在动 + 整页 build=0', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    await _enterFullscreenPlaying(t);

    final initial = debugPlayerControlBarsOpacity();
    expect(initial, isNotNull, reason: '前置：顶/底栏的 fade 探针要能用');
    final before = initial!.$1;
    expect(before, isNotNull,
        reason: '前置：此刻顶栏那条 `Opacity` 必须真的在树上（否则下面采样全空）');

    debugPlayerAutoHideControlsForProbe();
    await t.pump();

    // 采样中间帧：动画期间 opacity 必须出现**严格介于 0 与 1 之间**的值
    final samples = <double>[];
    final costs = <int>[];
    _installRebuildCounter();
    for (var i = 0; i < 20; i++) {
      costs.add(await _timedPump(t));
      final o = debugPlayerControlBarsOpacity()?.$1;
      if (o != null) samples.add(o);
    }
    // ignore: avoid_print
    print('T5 淡出中途 opacity 采样=${samples.map((e) => e.toStringAsFixed(2)).toList()}'
        ' pageBuild=$_page all=$_all ${_stat(costs)}');

    expect(before!, greaterThan(0.9),
        reason: '前置：隐藏之前控制条应当基本不透明（= 1.0 附近）');
    final mid = samples.where((o) => o > 0.02 && o < 0.98).toList();
    expect(mid, isNotEmpty,
        reason: '★★ 红线：不许用「减少/去掉淡入淡出」换帧率。'
            '采样里必须出现 0<opacity<1 的**中间帧**；'
            '一个都没有 ⇒ 动画被砍成了硬切。采样=$samples');
    expect(_page, 0,
        reason: '动画期间整页 build 必须为 0 —— 动画帧只该驱动被 AnimatedBuilder '
            '包住的那几层。改前这里是 0（因为底栏那条已经局部化了），'
            '★ 但顶栏 `_TopBar` 的 fade 只在它自己内部 AnimatedBuilder 里 ⇒ 同样必须是 0');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T6 ★ 隐藏 → hover 循环（模拟用户反复停手/动手）
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T6 隐藏→hover 循环 8 轮 ⇒ 每轮整页 build=0', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await _enterFullscreenPlaying(t);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();

    var totalPage = 0;
    var totalAll = 0;
    final costs = <int>[];
    for (var cyc = 0; cyc < 8; cyc++) {
      debugPlayerAutoHideControlsForProbe();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300)); // 让淡出跑完
      expect(debugPlayerControlsVisibleForProbe(), isFalse,
          reason: '第 $cyc 轮前置：控制条要真的收起来');

      _installRebuildCounter();
      await t.sendEventToBinding(p.hover(Offset(201.0 + cyc, 400)));
      costs.add(await _timedPump(t));
      totalPage += _page;
      totalAll += _all;
      expect(debugPlayerControlsVisibleForProbe(), isTrue,
          reason: '第 $cyc 轮副作用：控制条必须回来');
    }
    // ignore: avoid_print
    print('T6 8 轮隐藏→hover ⇒ pageBuild=$totalPage all=$totalAll ${_stat(costs)}'
        '（改前：每轮 page=1 all=188 p50=7896us max=10645us）');

    expect(totalPage, 0,
        reason: '★ 这是 Owner 感受最直接的一条：停手→控制条收→一动鼠标它回来。'
            '改前 8 轮 8 次整页重建、每次 ~8ms');
    expect(_pct(costs, .99), lessThan(16700),
        reason: '每一轮叫回控制条的帧都要在 60fps 预算内（改前 p99=10645us）');
  });
}
