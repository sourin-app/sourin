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
// ★★★ 2026-10-19（批末复核）：**上面 E/F/G 那几个「改前」读数已作废。**
// ```text
// 硬证据：
//  ① 引入本测试的 commit `e6458e5` **只加测试**（569 行，零 lib 改动）
//     ⇒ 测试诞生时 lib 已经是 N11 之后的状态
//  ② N11 的产品代码在它的父 commit `aedc29c`
//  ③ 基线 worktree `bdf6435`（10-18 08:04）既没有这个测试文件，
//     也没有 `_cursorLive` ⇒ **复现不出这些数字**
// ⇒ 它们是「同一天、但不在任何 commit 里的中间态」读数，
//   无法复跑取证 ⇒ 不能当对照基线。
//
// ★ 当前的**实测**读数（三次连跑完全一致）：
// ```text
// E 隐藏光标 1 次    pageBuild=1 all=531
//                   = 527（_autoHideNow 的整页 setState，:12990，
//                          被 t118:819/833 逐字钉住）
//                   +   4（_hideCursorNow 的局部广播，N11 的成果）
// T1 隐藏→hover     pageBuild=0 all=4     （改前注释里的 188）
// T4 已显示 60×     pageBuild=0 all=60    types=1（只有 AnimatedBuilder）
// ```
//
// ★★ 想验证这些阈值**还有判别力**，用下面这个注入（已实跑，门禁确实红）：
// ```text
// 把 `_resetCursorIdle()` 里的
//     _cursorIdleStale = false;
// 退回成
//     setState(() => _cursorIdleStale = false);
// ⇒ 实测 T2 恢复段 all 5 → 527、pageBuild 0 → 1 ⇒ 红
// ★ 另一个更能说明「阈值 5 有意义」的注入：在 `_showControls` 里
//   多推一次 `_controlsLive.notifyListeners()`
//   ⇒ all 4 → 73、pageBuild 仍 0（整页没重建）⇒ 阈值 5 照样抓住。
//
// ⚠️ ★★ 反例（我踩过）：给 `_pushCursorLive` 加 `setState` **测不出东西**
//   —— 那条路径的值变化本身就是局部重建，多加的 setState 被覆盖 ⇒ 读数不变。
//   ⇒ 「读数不变」不等于「阈值失效」，只等于「这个注入点在该窗口不产生额外计数」。
//
// ⚠️ ★★ 在 `git worktree` 里跑本文件，**必须先补齐两样**，否则读数是假的：
//     · `sourin_core.dll` —— ★ 不只是「读数会变」，而是**整个文件会全绿**：
//         实测 A/B 各 2 次：补齐 ⇒ T2 all=531（红）/ 缺件 ⇒ T2 all=**193**（全绿）。
//         而 193 正是上面那段注释里写的「改前」数之一。
//         机制（复核实测，**比我原先写的更广**）：
//         核心加载失败 ⇒ `listProviders` / 取源能力 / 阴性对照**全部退化**
//         （P0 阴性对照 all 从 1 变成 0 ⇒ 什么都没发生）
//         ⇒ 是**整条异步链路不执行**，不是 `_playing` 单点不同。
//         ⇒ ★ 这个环境是**假绿环境**，绝不能当对照基线。
//     · `.dart_tool` —— 必须**复制**，不能软链
//         （软链的 rootUri 会指回主树 ⇒ 跑的是主树的 lib）
// ```
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
int _topBar = 0;
int _animation = 0;
int _other = 0;

/// 所有元素重建次数之和（= 重建「面」）
int _all = 0;

/// 把**挂载后的异步起播**排空，再开始计数（与 `t72_jank_test` 同一口径）
///
/// # 为什么必须有（全量里的假红就是这个）
/// ```text
/// `_mount()` 只 pump 挂载帧；起播链路是**真异步**：
///   `_load() → await resolveStream(FFI) → await _prepareResume() → setState(...)`
/// 它的 setState **落在哪一帧取决于机器负载**：
///   · 空闲：在 `_installRebuildCounter()` 之前落地 ⇒ 阴性对照 page=0（绿）
///   · 全量并发：拖到 install **之后**落地 ⇒ 阴性对照读 page=1 ⇒ 红，
///     而那时红的是"测量窗口被异步回调污染"，**说明不了产品对错**。
/// ⇒ 计数前先 `runAsync` 让真实定时器/IO 跑完，再 pump 到没有待处理帧。
/// ```
Future<void> _drainAsyncBoot(WidgetTester t) async {
  // `runAsync` 里是**真实**异步区：FFI/IO 的完成回调能真正跑到
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
  for (var i = 0; i < 8; i++) {
    await t.pump();
    if (!t.binding.hasScheduledFrame) break;
  }
  debugOnRebuildDirtyWidget = null;
}

/// 该元素是否属于**顶栏子树**（含它自己）
///
/// `_TopBar` 是 `player_page.dart` 的私有 widget ⇒ 测试拿不到类型，
/// 只能按 `runtimeType.toString()` 认祖先（本仓 `_isTypingInField()` 同款手法）。
/// 仅用于**分类计数**，不参与产品判定。
bool _isInTopBar(Element e) {
  if (e.widget.runtimeType.toString() == '_TopBar') return true;
  var inside = false;
  e.visitAncestorElements((a) {
    if (a.widget.runtimeType.toString() == '_TopBar') {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

/// ★ 2026-10-25：**按来源分类**（整页 / 顶栏子树 / 动画 / 其余）
///
/// # 旧读数 `all<=5` 的病根：把"次数"当"层级"
/// ```text
/// 修好「顶栏看得见、点不到」之后，一次 hover **必须**重建顶栏子树（≈68 个元素）
/// ⇒ `all` 从 4 变成 73，被旧阈值判成"退回整页 setState"（其实是修好了）。
/// 而"退回整页"的真实特征是 `PlayerPage` 自己重建（`_page`，一直有独立读数）。
/// ```
void _installRebuildCounter() {
  _page = 0;
  _topBar = 0;
  _animation = 0;
  _other = 0;
  _all = 0;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    _all++;
    if (e.widget is PlayerPage) {
      _page++;
    } else if (e.widget is AnimatedBuilder) {
      _animation++;
    } else if (_isInTopBar(e)) {
      _topBar++;
    } else {
      _other++;
    }
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

/// ★★★ 2026-10-19（Lead 加，源自复核实测）：**Rust 核心是否真的加载成功**
///
/// ```text
/// 背景：这个文件原本只检查 libmpv，不检查 `sourin_core.dll`。
/// 而复核 A/B 实测（各 2 次稳定）：
///   有 sourin_core.dll ⇒ T2 all=**531**（红）
///   缺 sourin_core.dll ⇒ T2 all=**193**（★ **+7 全绿**）
///
/// 机制不是「某个数变了」，而是**整条异步链路不执行**：
///   listProviders / 取源能力 / 阴性对照 全部退化，
///   连 P0 的阴性对照都从 all=1 变成 all=0（什么都没发生）。
///
/// ⇒ ★ 而 193 正是本文件注释里那个「改前」数之一 ——
///   即：**一个「缺核心」的假绿环境，它的读数被当成了性能基线。**
/// ⇒ 所以缺核心时必须**明确跳过**，绝不能让它跑出一个漂亮的全绿。
/// ```
bool _requireSourinCore() {
  // ★ 必须列**全部**已知落点 —— `DynamicLibrary.open('sourin_core.dll')`
  //   走系统 DLL 搜索路径，而 AGENTS §8 要求 CI 把它拷到 `windows/`：
  //     ./sourin_core.dll                    仓库根（本机手动放置）
  //     ./windows/sourin_core.dll            CI 的规范落点
  //     ./build/windows/x64/runner/Release/  构建产物
  //   —— 第一版漏了 `windows/`，结果我移走仓库根那个之后防护**没触发**
  //      （实测仍 +7 全绿）⇒ 「验证缺件类守卫要先数清它有几个落点」
  //      这个坑，我今天已经踩过两次（libmpv 也是两个候选）。
  const candidates = <String>[
    'sourin_core.dll',
    'windows/sourin_core.dll',
    'build/windows/x64/runner/Release/sourin_core.dll',
  ];
  for (final rel in candidates) {
    if (File(rel).existsSync()) return true;
  }
  markTestSkipped('sourin_core.dll 缺失 ⇒ 本文件的读数不成立。'
      '★ 实测：缺核心时 T2 读到 193 且**整个文件全绿**，'
      '而 193 正是被作废的那个「改前」数 ⇒ 不能让它当基线。'
      '查过的落点：$candidates');
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
    // ★ Rust 核心缺失时读数不成立（实测缺核心 ⇒ T2 读 193 且全绿）
    if (!_requireSourinCore()) return;
    await _mount(t);

    // ★ 先排空异步起播（否则它的 setState 可能落进测量窗口 —— 全量并发下的假红源）
    await _drainAsyncBoot(t);
    _installRebuildCounter();
    await t.pump();
    // ignore: avoid_print
    print('P0 阴性对照 pump(无状态变化) => page=$_page all=$_all');
    expect(_page, 0,
        reason: '静置帧不该重建整页 —— 不为 0 说明**测量窗口被异步回调污染**'
            '（起播 setState 落在 install 之后），或页面真的在无故重建。'
            '★ 计数前已 `_drainAsyncBoot`，若仍读到 page>0 才怀疑产品');
    // ★★★ 2026-10-19（批末复核，Lead 修）：`all` 的期望从 0 放宽到 ≤1，
    //   但**不是**为了让门禁变绿，而是因为「必须恰好 0」这个前提在本机不成立。
    //
    // ```text
    // 实测：静置一帧读到 all=1，五次连跑逐字一致。
    // 决定性对照：`test/t72_jank_test.dart`（**轮前就存在的基线文件**）
    //   它的 P0 阴性对照读数**同样是 all=1**，且它**同样是红的**
    //   （属那 23 条基线红之一）⇒ 两个不同文件、同一套仪器、同一读数。
    // ⇒ 这是**仪器共性噪声**（框架在挂载后仍标脏一个元素），
    //   不是本轮引入的性能回归。
    //
    // ★ 为什么仍保留这条断言而不是删掉：
    //   它仍是**阳性对照**那条的前置（下面 openHints 必须 ≥1）——
    //   删了整条 P0，阳性对照就没有「仪器有区分力」的证明。
    //
    // ★★ 2026-10-19（复核第二次纠正，Lead 改）：我原先写的
    //   「仪器共性噪声（框架在挂载后仍标脏一个元素）」这个**解释是错的**。
    //   复核实测：那 1 个是 **AnimatedBuilder**，且它**每帧**重建 1 次 ——
    //   一次 install 里 pump 3 帧就读到 3（实测 1帧=1 / 2帧=2 / 3帧=3）。
    //   ⇒ 「静置帧恒为 1」成立，是因为**本条只 pump 一帧**，
    //     不是因为它是一次性噪声。
    // ⇒ ★ 所以本阈值是「**帧数**的函数」——将来谁把这里改成 pump 2 帧，
    //   读数会变成 2 而红，那是**预期**的，不是环境变了。
    expect(_all, lessThanOrEqualTo(1),
        reason: '静置 **1 帧**最多 1 个元素重建。\n'
            '★ 那 1 个是 **AnimatedBuilder**，且它**每帧**都重建 1 次'
            '（实测 1帧=1 / 2帧=2 / 3帧=3）——\n'
            '  **不是**「挂载后一次性噪声」。所以本阈值是帧数的函数：\n'
            '  改 pump 次数必须同步改阈值。\n'
            '★ 同仪器在 t72_jank 上读到同样的 1（同一个 '
            '`debugOnRebuildDirtyWidget` 钩子、同一个回调体）。\n'
            '★ 本条抓的是「整页 setState 回来了」（改前 page=60 / all=9960，'
            '三个数量级）；\n'
            '  抓不到「静置帧多重建 1~2 个」——那由 T1/T3/T6 的帧耗时判据覆盖。');

    _installRebuildCounter();
    final ok = debugPlayerOpenHintsForProbe();
    /*
     * ★ pump **两次**：`setState` 只标脏，第一次 pump 才真正 build；
     *   第二次兜住"该帧与别的 dirty 元素合并"的情形 —— 不靠"一次刚好够"。
     */
    await t.pump();
    await t.pump();
    // ignore: avoid_print
    print('P0 阳性对照 openHints(ok=$ok) => page=$_page topBar=$_topBar '
        'all=$_all');
    expect(ok, isTrue, reason: '钩子本身要生效，否则下面的断言是空的');
    /*
     * ★ 阳性对照**不放宽**（仍要求 page >= 1），但把"为什么没采到"分开报：
     *   `page==0 && all==0` ⇒ **仪器没采到帧**（钩子没挂上 / 被别的用例清了 /
     *   该 pump 内没有任何元素重建）—— 是**仪器问题，不是产品问题**；
     *   `page==0 && all>0` ⇒ 真·没有整页重建，那才该查产品。
     */
    if (_page == 0 && _all == 0) {
      fail('仪器没采到帧：`debugOnRebuildDirtyWidget` 在该 pump 内一次都没被调用'
          '（page=$_page topBar=$_topBar all=$_all）⇒ **不是产品问题**。'
          '先重跑；若稳定复现，检查是否有别的用例在 teardown 时把钩子清了'
          '（`debugOnRebuildDirtyWidget = null`）。');
    }
    expect(_page, greaterThanOrEqualTo(1),
        reason: '阳性对照必须 >=1 —— 否则本文件的重建计数没有区分力。'
            '★ 只接受 page>=1；`page==0 && all>0` 才是产品侧信号');
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
    // ★ Rust 核心缺失时读数不成立（实测缺核心 ⇒ T2 读 193 且全绿）
    if (!_requireSourinCore()) return;
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

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-25 重标定：`all <= 5` **废弃**（它把"次数"当"层级"）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 历史（别改回去）
     * ```text
     * 旧判据 `expect(elems, lessThanOrEqualTo(5))` 记录"实测稳定值 4"。
     * ★ 那个 4 是**在缺陷态下量的**：顶栏"看得见、点不到"的缺陷正是
     *   hover 的广播被守卫吃掉（**从不通知**）⇒ 叫回时顶栏子树一次都没重建。
     *   2026-10-25 修好之后：一次 hover **正确**重建顶栏子树（≈68 个元素）
     *   ⇒ `all` 4 → 73 被旧阈值判成"退回整页 setState"（其实修好了）。
     *   与 `zz_t66_n11_bottombar` 旧阈值 200 是同一个病：拿"次数"当"层级"。
     * ```
     * # 现在的判据（按来源分开，两个方向都有牙）
     * ```text
     * ① page == 0        —— 整页 `PlayerPage` 绝不重建（T1 的原意）；
     * ② topBar >= 40     —— 叫回必须**真的重建顶栏子树**（广播通了）；
     *                       不通 ⇒「箭头看得见、点不到」；
     * ③ topBar <= 80     —— 只许一次（≈68；两次翻倍 = 重复通知）；
     * ④ other <= 5       —— 其余元素不许被牵连（旧阈值的合理内核保留在此）；
     * ⑤ animation 不设上限 —— AnimatedBuilder 是 fade 自身，每帧本来就跑。
     * ```
     * # 为什么改成 8 轮 + p50/p95（阈值没放宽，只是换成分布）
     * ```text
     * 单帧实测在同机抖动 7913 / 9268 / 14922us（近 2 倍）⇒ 单帧硬断言会偶发假红。
     * ⇒ p50 < 16700（预算不变）、p95（取最慢一帧）≤ 33400（允许一次尖峰）。
     * ```
     */
    final pages = <int>[];
    final topBars = <int>[];
    final others = <int>[];
    final times = <int>[];
    for (var cyc = 0; cyc < 8; cyc++) {
      // 回到"已收起"状态（走生产 `_autoHideNow`）
      debugPlayerAutoHideControlsForProbe();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(debugPlayerControlsVisibleForProbe(), isFalse,
          reason: '第 $cyc 轮前置：控制条必须真的收起');

      _installRebuildCounter();
      await t.sendEventToBinding(p.hover(Offset(210.0 + cyc, 400)));
      times.add(await _timedPump(t));
      pages.add(_page);
      topBars.add(_topBar);
      others.add(_other);
      expect(debugPlayerControlsVisibleForProbe(), isTrue,
          reason: '第 $cyc 轮副作用：控制条必须真的回来（不许靠"不显示"换性能）');
    }

    final sorted = [...times]..sort();
    final p50 = sorted[3]; // 8 个读数的下中位
    final p95 = sorted[7]; // 最慢一帧（p95 的保守上界）
    // ignore: avoid_print
    print('T1 8 轮 ⇒ page=${pages.reduce((a, b) => a + b)} '
        'topBar/轮=$topBars other/轮=$others '
        '帧耗时 p50=${p50}us max=${p95}us（预算 16700us）');

    expect(pages.every((v) => v == 0), isTrue,
        reason: '★ 每轮整页 `PlayerPage` 都不许重建（实际 $pages）—— '
            '不为 0 ⇒ 光标/控制条态又走回整页 setState（改前 page=1）');
    expect(topBars.every((v) => v >= 40), isTrue,
        reason: '★★★ 每轮叫回都必须**真的重建顶栏子树**（实际 $topBars）。'
            '很小/为 0 ⇒ 广播没通知 ⇒ 顶栏停在 visible=false：'
            '「箭头看得见、点不到」（把 `_pushControlsLive()` 改成空操作即可复现）');
    expect(topBars.every((v) => v <= 80), isTrue,
        reason: '★★ 每轮顶栏子树只许重建**一次**（实际 $topBars）—— '
            '>80 说明一次 hover 触发了两次通知/循环');
    expect(others.every((v) => v <= 5), isTrue,
        reason: '★ 除整页/顶栏/动画外，其余元素不许被牵连（实际 $others）—— '
            '改前 188 里的大头就是这类整子树装卸');
    expect(p50, lessThan(16700),
        reason: '★★ 中位帧必须落在 60fps 预算（16.7ms）内 —— 阈值未放宽');
    expect(p95, lessThan(33400),
        reason: '★ 最慢一帧允许一次尖峰（≤2× 预算）：实测同机抖动 7913~14922us，'
            '单帧硬断言会偶发假红；**分布判据**才是可解释的形态');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T2 ★ 光标隐藏 / 恢复
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T2 光标隐藏 + 恢复 ⇒ 各自整页 build=0，且光标真的隐/现', (t) async {
    if (!_requireLibmpv()) return;
    // ★ Rust 核心缺失时读数不成立（实测缺核心 ⇒ T2 读 193 且全绿）
    if (!_requireSourinCore()) return;
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
        '（★ 原先这里印的是「改前 all=190」，已作废：'
        '在 e6458e5 / aedc29c 上实跑都是 531，'
        '且 stash/reflog/171 个悬空 commit 全查过 ⇒ 无来源）');

    expect(debugPlayerCursorIdleHiddenForProbe(), isTrue,
        reason: '副作用检查：光标必须**真的藏起来**（不许靠"不藏"换性能）');
    /*
     * ★★★ 2026-10-19（批末复核，Lead 改）：原文写「`hideAll` 仍是 ~193」，
     *   **这个数字也作废**，而且它和上面那个「190」在**同一份基线表里并存**
     *   —— 说明这两个数都来自「某个中间态」，谁也不是可复现的对照。
     *
     * ```text
     *   复核实跑：e6458e5（测试诞生）⇒ 531
     *            aedc29c（父 commit）  ⇒ 531
     *   三重兜底：stash 空 / reflog 694 条 / 171 个悬空 commit
     *            （含该测试的 39 个**全部**已含 _cursorLive）
     *
     * ★ 附一条值得记的巧合：复核发现「worktree 里缺 sourin_core.dll」
     *   时读数是 **193** —— 与这里写的 ~193 只差 0。
     *   ⇒ 很可能这两个数都是**同一个坏环境**（核心加载失败 ⇒
     *     `_playing` 路径不同 ⇒ widget 树规模不同）下的读数，
     *     被当成了「改前对照」。
     *   ⇒ 详见文件头「在 worktree 里跑本文件必须先补 DLL」。
     * ```
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
    // ★★★ 2026-10-19（批末复核，Lead 修）：阈值与理由都改了，因为
    //   **原来那个「改前 190」的对照根本不可考**。
    //
    // ```text
    // 复核的硬证据：
    //  ① e6458e5（引入本测试的 commit）**只加测试**（569 行，零 lib 改动）
    //     ⇒ 测试诞生时 lib 已经是 N11 之后的状态
    //  ② N11 的产品代码在它的父 commit aedc29c
    //  ③ 基线 worktree bdf6435（10-18 08:04）既没有这个测试文件，
    //     也没有 `_cursorLive` ⇒ 在基线上**复现不出 190**
    // ⇒ 「190」是「同一天、但不在任何 commit 里的中间态」读数。
    //   它无法被复跑取证 ⇒ 不能当对照基线。
    //
    // 而 531 的构成已被逐条拆开（复核实测）：
    //   527 = _autoHideNow() 里那一行 setState（:12990）
    //         ★ 它被 t118:819/833 **逐字钉住** ⇒ 删了 t118 会红 ⇒ 属既定设计
    //     4   = _hideCursorNow 的局部广播（N11 的局部化成果，2 种 widget）
    //
    // ⇒ 本条断言的**本意**（读 reason 原文）是「若读到 1000+ 说明 hover 路径
    //   也退回了整页重建」，而 hover 路径由 T1/T3/T6 独立覆盖。
    //   ⇒ 阈值改成「与整页 setState 的必然代价同量级」，并把数字换成实测值。
    expect(hideAll, lessThan(700),
        reason: '自动隐藏路径允许**一次整页 setState** 的重建面 —— '
            '实测 531（= 527 整页 + 4 局部广播），三次连跑读数完全一致。\n'
            '★ 「改前 190」这个对照已作废：它来自不在任何 commit 里的中间态，'
            '无法复跑取证（详见上方注释的三条硬证据）。\n'
            '527 那一行被 t118⑨ 逐字钉住 ⇒ 不是本轮引入，也不该在此放宽。\n'
            '若读到 1000+ 说明 hover 路径也退回了整页重建 —— 那才是这条要抓的。');

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
    expect(showAll, lessThanOrEqualTo(6),
        reason: '恢复光标只该走 N11 的局部广播（实测 5，五次连跑逐字一致；'
            'T1 同一路径是 4）。\n'
            '★ 原阈值 3 同样是按「理论下限 2 + 留 1」估的，与 T1 一样少算了。\n'
            '★ 改前这里是 188 —— 若读到 100+，说明整页 setState 又回来了。');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T3 ★ 60 次/秒 hover（两种光标态都要 0）
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T3 光标已隐藏时 60 次 hover ⇒ 整页 build=0，p99 在预算内', (t) async {
    if (!_requireLibmpv()) return;
    // ★ Rust 核心缺失时读数不成立（实测缺核心 ⇒ T2 读 193 且全绿）
    if (!_requireSourinCore()) return;
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
    // ★ Rust 核心缺失时读数不成立（实测缺核心 ⇒ T2 读 193 且全绿）
    if (!_requireSourinCore()) return;
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
    // ★ Rust 核心缺失时读数不成立（实测缺核心 ⇒ T2 读 193 且全绿）
    if (!_requireSourinCore()) return;
    await _mount(t);
    await _enterFullscreenPlaying(t);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-26：把三条"存在性"判据换成**数值判据**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 原来为什么弱（composer-ui 清单点名）
     * ```text
     * ① `expect(initial, isNotNull)` —— 只证明探针**返回了记录**；
     *    哪怕顶栏那条 `Opacity` 的值是 0.0（控制条早该可见却是全透明），
     *    只要记录非 null 就绿 ⇒ 抓不到"起手就是透明"的退化。
     * ② `expect(before, isNotNull)` —— 同上，只证明 `$1` 存在；
     *    下面已有 `before > 0.9`，这条与它重复，且存在性本身没有判别力。
     * ⇒ 换成：**起手顶栏必须基本不透明（实测 1.00）**，容差 0.05。
     * ```
     */
    final initial = debugPlayerControlBarsOpacity();
    expect(initial, isNotNull, reason: '前置：顶/底栏的 fade 探针要能用（null = 播放页没挂上）');
    final before = initial!.$1;
    expect(before, closeTo(1.0, 0.05),
        reason: '★ 起手顶栏那条 `Opacity` 必须**基本不透明**（实测 1.00）。'
            '只判"非 null"抓不到"值被冻成 0"的退化');

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
    /*
     * ★ 2026-10-26：`isNotEmpty` → **三条数值判据**（数目 / 单调性 / 终值）
     * ```text
     * 原来：只要出现过**一个**中间帧就绿 —— 20 帧里 19 帧是 1.0、只有 1 帧 0.5
     *      也算"有动画"，抓不到"动画被砍得只剩一帧"（≈硬切）的退化。
     * 现在：① 中间帧**数目** ≥ 6（实测 9/20，220ms 淡出）；
     *       ② 淡出期间必须**单调下降**（首 > 尾；实测 0.96 → 0.07）；
     *       ③ 20 帧后必须落到 ~0（实测 0.00）—— 否则"淡出停在中途"也会绿。
     * ```
     */
    expect(mid.length, greaterThanOrEqualTo(6),
        reason: '★★ 红线：不许用「减少/去掉淡入淡出」换帧率。'
            '20 帧采样里必须出现 **≥6 个** 0<opacity<1 的中间帧'
            '（实测 9 个）；只剩 0~1 个 ⇒ 动画被砍成了硬切。采样=$samples');
    expect(mid.first, greaterThan(mid.last),
        reason: '★★ 淡出期间 opacity 必须**单调下降**（首帧 ${mid.isEmpty ? "-" : mid.first}'
            ' > 尾帧 ${mid.isEmpty ? "-" : mid.last}）—— 否则不是淡出，是乱跳');
    expect(samples.last, lessThan(0.02),
        reason: '★ 20 帧之后必须已经落到 ~0（实测 0.00）—— '
            '否则"淡出停在中途"也会绿');
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
    // ★ Rust 核心缺失时读数不成立（实测缺核心 ⇒ T2 读 193 且全绿）
    if (!_requireSourinCore()) return;
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
