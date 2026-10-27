// ═══════════════════════════════════════════════════════════════════════
//  N7 · 弹幕设置弹窗「分类帧耗时」探针（真机 Windows release）
// ═══════════════════════════════════════════════════════════════════════
//
// # 它回答什么（task-4 交付口径的第 4 件）
// ```text
// N7 的第 1 项要求：**按"打开/关闭/滚动/页签切换"分类采样**（照旧13 探针方法）。
// 旧13 已采到「关闭 11 档 × n=34 健康」与「打开 7 类（build <1ms / raster 4.2~7.9ms）」，
// 但**弹幕设置弹窗**没被单独按这四类采过 —— 而它是 Owner 点名的"最大最频"。
// ⇒ 本探针只做这一件事：把弹幕设置弹窗的**四类交互**各自变成一条可复核的读数。
// ```
//
// # 采法（**照抄 `lib/t107_perf_open_probe.dart` 的仪器纪律**，不另造一套）
// ```text
// ① **引擎 timings 常驻不摘**：进程启动就 `addTimingsCallback`，一次都不 remove。
//    每个窗口按**下标切片**（`[mark, len)`）而不是按"注册/注销"切分
//    ⇒ 迟到的批次仍然被算进它真正所属的窗口。
//    （t105 当年摘了回调 ⇒ 「打开」类一律 `batches=0 / n=0`，那条教训不能再犯）
// ② **窗口结束后 drain**：等批次不再增长或超时，把光栅线程迟到的批次收干净。
// ③ **第二路（不依赖引擎上报）**：常驻 `addPostFrameCallback` 链，逐帧记
//    `currentFrameTimeStamp` + 墙钟 ⇒ 即使引擎一条 timings 都不给，
//    也能给出「窗口内画了几帧」「帧间隔多少」—— 用来区分
//    「没画帧（无读数）」与「画了帧但没上报（仪器问题）」。
// ④ 阳性/阴性对照各一条（读不出注入的卡顿 ⇒ 仪器不可信，不许拿它论证产品）。
// ```
//
// # 与产品的隔离（硬闸）
// ```text
// `DATA_DIR_OVERRIDE` 必须落在 `.probe/n7-probe/` 下，否则 `exit(3)` 什么都不做
// —— 本探针**不写用户真实数据目录**（同 t107 的做法）。
// 探针**不改产品代码**：它只用产品自己的 `DanmakuSettingsDialog` 与
// `showAppDialog`。
// ```
//
// # 用法
// ```bash
// flutter build windows --release -t lib/n7_danmaku_dialog_probe.dart \
//   '--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\n7-probe\data'
// # 外层把 APPDATA / USERPROFILE / LOCALAPPDATA 指进同一个隔离目录，再跑 exe
// ```
// 产物：`.probe/n7-probe/n7_danmaku_dialog.log`（本文件自己写，不依赖控制台）
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
// `FramePhase` 在 `dart:ui` 里（不在 scheduler 的导出面）—— 同 t107 的写法
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerDownEvent, PointerScrollEvent, PointerUpEvent;
import 'package:flutter/scheduler.dart' show FrameTiming, SchedulerBinding;
import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show LightweightLiquidGlass, LiquidGlassWidgets;
import 'package:window_manager/window_manager.dart';

import 'core/app_tray.dart' show AppTray;
import 'core/clip_download.dart' show ClipDownloader;

import 'core/ffi.dart' show SourinCore;
import 'core/ui_prefs.dart' show UiPrefs;
import 'shell.dart' show SourinApp;
// ⚠️ `debugSkipGlassShell` 带 `@visibleForTesting` ⇒ 探针里引用要显式豁免
//    （本仓同款做法：`t106_r6b_live_probe.dart:641`、`t493_layout_probe.dart:621`）
// ignore: invalid_use_of_visible_for_testing_member
import 'ui/widgets/app_dialog_shell.dart' show debugSkipGlassShell;
import 'ui/widgets/danmaku_settings_dialog.dart';
import 'ui/widgets/overlay_motion.dart' show showAppDialog;

// ═══════════════════════════════════════════════════════════════════════
//  日志
// ═══════════════════════════════════════════════════════════════════════

late Directory _outDir;
File? _logFile;
final StringBuffer _pending = StringBuffer();

void _say(String s) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  _pending.writeln('[N7 $ts] $s');
  final f = _logFile;
  if (f != null) {
    try {
      f.writeAsStringSync(_pending.toString(), mode: FileMode.append);
      _pending.clear();
    } catch (_) {/* 落盘失败不致命 */}
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  仪器 A：引擎 timings（**常驻不摘**）
// ═══════════════════════════════════════════════════════════════════════

class _TimingTap {
  final List<FrameTiming> frames = <FrameTiming>[];
  int batches = 0;
  DateTime lastBatchAt = DateTime.fromMillisecondsSinceEpoch(0);

  void install() => SchedulerBinding.instance.addTimingsCallback(_on);

  void _on(List<FrameTiming> t) {
    batches++;
    frames.addAll(t);
    lastBatchAt = DateTime.now();
  }

  int get mark => frames.length;
}

final _TimingTap _timings = _TimingTap();

// ═══════════════════════════════════════════════════════════════════════
//  仪器 B：常驻 postFrame 链（不依赖引擎上报）
// ═══════════════════════════════════════════════════════════════════════

class _WallTap {
  final List<int> frameTsUs = <int>[];
  int ticks = 0;

  void install() => WidgetsBinding.instance.addPostFrameCallback(_on);

  void _on(Duration _) {
    ticks++;
    frameTsUs.add(
        SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds);
    WidgetsBinding.instance.addPostFrameCallback(_on);
  }

  int get mark => ticks;
}

final _WallTap _wall = _WallTap();

// ═══════════════════════════════════════════════════════════════════════
//  统计
// ═══════════════════════════════════════════════════════════════════════

int _pct(List<int> v, double p) {
  if (v.isEmpty) return -1;
  final s = [...v]..sort();
  return s[((s.length - 1) * p).round().clamp(0, s.length - 1)];
}

int _max(List<int> v) => v.isEmpty ? -1 : v.reduce(math.max);

class _Window {
  _Window(this.label);

  final String label;
  int nTiming = 0;
  int buildP50 = -1, buildP95 = -1, buildMax = -1, buildOver = 0;
  int rasterP50 = -1, rasterP95 = -1, rasterMax = -1, rasterOver = 0;

  /// 第二路：窗口内画了几帧 + 帧间隔（已排除探针自己的空闲等待）
  int nWall = 0;
  int ivP50 = -1, ivP95 = -1, ivMax = -1, ivOver = 0, idleGaps = 0;
  int wallSpanUs = 0, drainMs = 0;
  /// 窗口的引擎时钟区间（收尾时按 `t.timestampInMicroseconds(FramePhase.vsyncStart)`
/// 把帧归属到各窗口）。
  ///
  /// ⚠️ 没有 `FrameTiming.vsyncStart` 这个 getter —— 必须用
  ///    `timestampInMicroseconds(FramePhase.vsyncStart)`
  ///    （本仓 `t107_perf_open_probe.dart:398` 用的就是同一个 API）。
  int vsyncFrom = 0;
  int vsyncTo = 0;

  String note = '';

  /// 把一组引擎帧填成本窗口的读数（build/raster 分位数 + 超预算数）
  void fill(List<FrameTiming> mine) {
    nTiming = mine.length;
    if (mine.isEmpty) return;
    final b = <int>[for (final t in mine) t.buildDuration.inMicroseconds];
    final r = <int>[for (final t in mine) t.rasterDuration.inMicroseconds];
    buildP50 = _pct(b, .5);
    buildP95 = _pct(b, .95);
    buildMax = _max(b);
    buildOver = b.where((x) => x > _kBudgetUs).length;
    rasterP50 = _pct(r, .5);
    rasterP95 = _pct(r, .95);
    rasterMax = _max(r);
    rasterOver = r.where((x) => x > _kBudgetUs).length;
  }

  @override
  String toString() => '$label | engine_n=$nTiming '
      'build[p50=$buildP50 p95=$buildP95 max=$buildMax over=$buildOver] '
      'raster[p50=$rasterP50 p95=$rasterP95 max=$rasterMax over=$rasterOver] '
      'wall_n=$nWall iv[p50=$ivP50 p95=$ivP95 max=$ivMax over=$ivOver idle=$idleGaps]'
      '${note.isEmpty ? '' : '  NOTE: $note'}';
}

const int _kBudgetUs = 16700; // 16.7ms = 60fps

// ═══════════════════════════════════════════════════════════════════════
//  测量一个窗口
// ═══════════════════════════════════════════════════════════════════════

List<_Window> _all = <_Window>[];

/// 窗口开始/结束时"最后一帧"的引擎时间戳 —— **必须是 live getter**。
///
/// ⚠️★★★ 第一版这里写成 `int _lastVsync = 0`（一个只在 drain 之后才更新的
/// **变量**）⇒ `final vsyncTo = _lastVsync;` 读到的其实是**上一个窗口结束时**
/// 的值，于是每个窗口的归属区间 `(vsyncFrom, vsyncTo]` **恒为空**
/// ⇒ 全部窗口 `engine_n=0`（实测 12 个交互窗口一个引擎读数都没归到）。
/// 那不是"引擎不上报"，是**仪器写错**（t107 的 `_lastVsync()` 是函数 —— 我抄漏了这一点）。
int _lastVsync() => _wall.frameTsUs.isEmpty ? 0 : _wall.frameTsUs.last;

Future<_Window> _measure(String label, Future<void> Function() body,
    {bool drain = true}) async {
  final vsyncFrom = _lastVsync();
  final wMark = _wall.mark;
  final wall0 = DateTime.now();

  String? bodyErr;
  try {
    await body();
  } catch (e) {
    bodyErr = '$e';
    _say('  !! 本窗口场景异常: $e');
  }

  final span = DateTime.now().difference(wall0).inMicroseconds;
  // ★ 与 t107 一致：**body 之后、drain 之前**取 vsyncTo
  final vsyncTo = _lastVsync();

  var waited = 0;
  if (drain) waited = await _drain();

  final w = _Window(label)
    ..vsyncFrom = vsyncFrom
    ..vsyncTo = vsyncTo
    ..wallSpanUs = span
    ..drainMs = waited;

  final ts = _wall.frameTsUs.sublist(wMark);
  w.nWall = ts.length;
  if (ts.length > 1) {
    final iv = <int>[];
    var idle = 0;
    for (var i = 1; i < ts.length; i++) {
      final d = ts[i] - ts[i - 1];
      // 空闲间隔：探针自己在等动效（≥150ms），不该记成丢帧
      if (d > 50000) {
        idle++;
        continue;
      }
      iv.add(d);
    }
    w.idleGaps = idle;
    if (iv.isNotEmpty) {
      w.ivP50 = _pct(iv, .5);
      w.ivP95 = _pct(iv, .95);
      w.ivOver = iv.where((x) => x > _kBudgetUs).length;
    }
    w.ivMax = _max(ts.sublist(1).asMap().entries.map((e) {
      return e.value - ts[e.key];
    }).toList());
  }

  if (bodyErr != null) w.note = '场景异常 ⇒ 读数不完整：$bodyErr';
  _emit(w);
  return w;
}

/// 等引擎把迟到的批次送完（连续两次检查无增量 ⇒ 认定送完）
Future<int> _drain() async {
  var waited = 0;
  var last = -1;
  var stable = 0;
  while (waited < 1200) {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    waited += 120;
    final now = _timings.frames.length;
    if (now == last) {
      stable++;
      if (stable >= 3) break;
    } else {
      stable = 0;
      last = now;
    }
  }
  return waited;
}

void _emit(_Window w) {
  _say('WINDOW ${w.label}  wall_span=${w.wallSpanUs}us drain=${w.drainMs}ms');
  if (w.nTiming == 0) {
    _say('  ⚠️ 引擎路 n=0 ⇒ 本窗口**无 timings 读数**（不得解释成"不卡"）');
  }
  if (w.nWall == 0) {
    _say('  ⚠️ 第二路 frames=0 ⇒ 本窗口**一帧都没画** ⇒ 无读数（不得解释成"不卡"）');
  }
  _all.add(w);
}

/// 把引擎帧按**对齐后的时间戳**归属到各窗口（收尾时统一做）。
///
/// # ★★★ 为什么必须先算一个 `offset`（t107 的坑，我第一版没抄这一段）
/// ```text
/// 引擎路 `FrameTiming.timestampInMicroseconds(vsyncStart)` 与第二路
/// `SchedulerBinding.currentFrameTimeStamp` **不是同一个原点**
/// （t107 头部 ② 的实测：直接比大小 ⇒ 一个窗口都匹配不上、全部 0）。
/// ⇒ 必须先估一个**常量偏移**，减掉之后再比。
///
/// 实测佐证（本探针第一版，2026-10-27）：把 `_lastVsync` 误写成变量之后，
/// 12 个交互窗口**全部** `engine_n=0` —— 看起来像"引擎不上报"，
/// 其实是**归属区间算空**。加上偏移 + 修掉 getter 之后才有读数。
/// ```
/// 偏移取 `median(引擎帧时间戳 − 第二路帧时间戳)`（两路等长部分），
/// 并核验**离散度**：≤5ms 才认为同源可对齐；否则如实标注"归属只到近似"。
void _finalizeAll() {
  _say('');
  _say('── 终判：按引擎时钟把帧归属到各窗口 ──');
  _say('  累计引擎帧=${_timings.frames.length} 批次=${_timings.batches} '
      '第二路帧=${_wall.frameTsUs.length}');

  // ── 两路时钟对齐：offset = median(引擎 vsyncStart − 第二路 currentFrameTimeStamp) ──
  //
  // ★★★ 必须**从头上配对**（`for (var i = 0; i < n; i++)`）并核验**p95 偏差**。
  //     我第一版从**尾部**配对（`frames[len-1-i]` vs `frameTsUs[len-1-i]`），
  //     两路帧数不等时尾部对不齐 ⇒ 算出一个荒谬的 offset（实测 7.5e10us、
  //     离散度 3.6e6us）⇒ 归属结果不可信。t107 是**从头配对**：
  //     多出来的引擎帧都在启动期，落在所有窗口**之外**，不影响任何窗口。
  final engineTs = <int>[
    for (final t in _timings.frames)
      t.timestampInMicroseconds(ui.FramePhase.vsyncStart)
  ];
  final wallTs = _wall.frameTsUs;
  final n = math.min(engineTs.length, wallTs.length);
  var offset = 0;
  var spread = -1;
  if (n > 20) {
    final deltas = <int>[for (var i = 0; i < n; i++) engineTs[i] - wallTs[i]]
      ..sort();
    offset = deltas[deltas.length ~/ 2];
    final dev = <int>[for (final d in deltas) (d - offset).abs()]..sort();
    spread = dev[(dev.length * 95 / 100).round().clamp(0, dev.length - 1)];
  }
  final aligned = n > 20 && spread >= 0 && spread <= 5000;
  _say('  引擎帧=${engineTs.length} 第二路帧=${wallTs.length} 前 $n 帧配对 '
      '⇒ offset=$offset us 离散度(p95)=$spread us');
  _say('  ⇒ ${aligned ? '✓ 两路同源（p95 ≤5ms）⇒ 按对齐后时间戳归属' : '✗ 对齐不了 ⇒ 退回按累计帧数归属（只到近似）'}');

  var cursor = 0;
  for (final w in _all) {
    if (aligned) {
      final mine = <FrameTiming>[
        for (final t in _timings.frames)
          if (t.timestampInMicroseconds(ui.FramePhase.vsyncStart) - offset >
                  w.vsyncFrom &&
              t.timestampInMicroseconds(ui.FramePhase.vsyncStart) - offset <=
                  w.vsyncTo)
            t
      ];
      w.fill(mine);
    } else {
      // 退路：按**累计帧数**切（只到近似，如实标注）
      final from = cursor.clamp(0, _timings.frames.length);
      final to = (cursor + w.nWall).clamp(from, _timings.frames.length);
      w.fill(_timings.frames.sublist(from, to));
      w.note = '${w.note.isEmpty ? '' : '${w.note} '}[归属=按累计帧数,近似]';
    }
    cursor += w.nWall;
  }

  final attributed = _all.fold<int>(0, (a, w) => a + w.nTiming);
  final totalWall = _all.fold<int>(0, (a, w) => a + w.nWall);
  _say('  仪器自洽：第二路总帧=$totalWall 引擎总帧=${engineTs.length} 已归属=$attributed');
  if (engineTs.length != totalWall) {
    _say('  ⚠️ 两路总帧不等（差 ${engineTs.length - totalWall}，多的在启动期）'
        '⇒ 这正是"必须按时间戳而不是按下标归属"的原因');
  }

  _say('');
  _say('══════ 逐窗口最终读数（微秒；预算 16700us）══════');
  for (final w in _all) {
    _say('FINAL ${w.toString()}');
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  场景：弹幕设置弹窗的四类交互
// ═══════════════════════════════════════════════════════════════════════

/// 固定落到「显示」页签的初始状态（三块固定区 + 滑块 + 屏蔽词都在）
const DanmakuSettingsState _kState = DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1.0,
      opacity: 1.0,
      speed: 8.0,
      area: 0.5,
      status: '合成数据 · 探针',
      count: 842,
      lanes: 12,
      dropped: 3,
    );

/// ★ 环境开关 `N7_GLASS=off` ⇒ 把弹窗外壳的玻璃摘掉再量同一批场景。
///
/// # 为什么要有这一档
/// ```text
/// Owner 的抱怨是「弹窗卡顿」。要回答"**这是不是玻璃的锅**"，只有一条路：
/// 同一台机、同一次进程、同一批场景，**只切玻璃这一个变量**再量一遍。
/// ⇒ 用产品自己的 `debugSkipGlassShell`（`app_dialog_shell.dart:839`，
///   生产恒 false）当仪器开关 —— 与 `app_menu.dart` 的
///   `debugSkipGlassMenu` 同一套做法。
/// ```
/// ⚠️ 这一档**不改产品**、也不改观感结论：
///   `debugSkipGlassShell == true` 时外壳原样返回 ⇒ 那是"摘掉玻璃"的世界。
///   它只用来回答"差值归谁"，**不**作为"该不该删玻璃"的依据
///   （ledger-31 已定：模糊在卡片内部贡献为 0，可见差异只在描边带；
///     本档只为量"整块玻璃面的重绘成本"，不为论证删它）。
bool get _glassOff => Platform.environment['N7_GLASS'] == 'off';

/// 真挂弹幕设置弹窗（产品自己的组件 + 产品自己的 `showAppDialog`）
Future<void> _openDialog() async {
  // ignore: invalid_use_of_visible_for_testing_member
  debugSkipGlassShell = _glassOff;
  final ctx = AppTray.navigatorKey.currentContext;
  if (ctx == null) throw StateError('navigatorKey.currentContext 为空');
  showAppDialog<void>(
    context: ctx,
    barrierDismissible: false,
    builder: (_) => DanmakuSettingsDialog(
      state: _kState,
      onSetEnabled: (_) {},
      onSetFontScale: (_) {},
      onSetOpacity: (_) {},
      onSetSpeed: (_) {},
      onSetArea: (_) {},
      onReload: () {},
      onClose: () => AppTray.navigatorKey.currentState?.pop(),
      canSendDanmaku: true,
    ),
  ).ignore();
}

/// 等动效落定：推 N 帧 + 等 wall 毫秒
Future<void> _settle({int frames = 3, int ms = 380}) async {
  for (var i = 0; i < frames; i++) {
    await WidgetsBinding.instance.endOfFrame;
  }
  await Future<void>.delayed(Duration(milliseconds: ms));
}

Element? _rootElement() => WidgetsBinding.instance.rootElement;

/// 深度优先找**第一个** widget 是 `Text` 且文本等于 [text] 的 element
Element? _findTextElement(String text) {
  final root = _rootElement();
  if (root == null) return null;
  Element? hit;
  void visit(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is Text && w.data == text) {
      hit = e;
      return;
    }
    e.visitChildren(visit);
  }

  visit(root);
  return hit;
}

/// 在树里按**文本**找一个可点元素并点它（release 里没有 `WidgetTester`，
/// 也**不能** import `flutter_test`）。
///
/// ⚠️ 用真实指针事件（`GestureBinding.handlePointerEvent`）走**与物理鼠标
///    完全相同的手势管线**（同 `t458_drag_selftest` 的做法）—— 不调回调、
///    不调 setState，这样量到的才是"用户点那一下"的帧。
Future<bool> _tapText(String text) async {
  final e = _findTextElement(text);
  if (e == null) return false;
  final box = e.renderObject;
  if (box is! RenderBox) return false;
  final at = box.localToGlobal(box.size.center(Offset.zero));
  final b = WidgetsBinding.instance;
  b.handlePointerEvent(PointerDownEvent(
      position: at, pointer: 880, kind: PointerDeviceKind.mouse));
  b.handlePointerEvent(PointerUpEvent(
      position: at, pointer: 880, kind: PointerDeviceKind.mouse));
  return true;
}

/// 页签切换 —— 点 SegmentedButton 里那一段（真指针事件）
Future<void> _switchTab(String label) async {
  final ok = await _tapText(label);
  if (!ok) _say('  ⚠️ 页签「$label」没找到（读数仍然有效：那一轮点了 0 次）');
  await _settle(frames: 2, ms: 220);
}

/// 滚动：把弹窗里的滚动区推一段（**真实滚轮事件**）
Future<void> _scrollDialog() async {
  _injectScroll(const Offset(640, 400), 320);
  await _settle(frames: 2, ms: 180);
}

/// 指针信号（滚轮）。`_handlePointerEventImmediately` 对 `PointerSignalEvent`
/// 会**重新 hitTest** ⇒ 只要给 `position` + `scrollDelta`，不需要先 Down/Up。
///
/// ★ `PointerScrollEvent` 的构造器**不透传 `pointer`**（见
///   `gestures/events.dart` 的 const ctor）⇒ 这里不能写 `pointer:`，
///   写了就是 `undefined_named_parameter`（本仓 `t74_perf_probe.dart:587`
///   早就记过同一条）。
void _injectScroll(Offset at, double dy) {
  WidgetsBinding.instance.handlePointerEvent(PointerScrollEvent(
    position: at,
    scrollDelta: Offset(0, dy),
    kind: PointerDeviceKind.mouse,
  ));
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _outDir = Directory('${Directory.current.path}${Platform.pathSeparator}'
      '.probe${Platform.pathSeparator}n7-probe');
  if (!_outDir.existsSync()) _outDir.createSync(recursive: true);
  _logFile = File('${_outDir.path}${Platform.pathSeparator}n7_danmaku_dialog.log');
  _logFile!.writeAsStringSync('');

  _say('══════ N7 · 弹幕设置弹窗分类帧耗时 ══════');
  _say('cwd=${Directory.current.path}');
  _say('产物=${_logFile!.path}');

  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  _say('DATA_DIR_OVERRIDE=${override.isEmpty ? "<未设>" : override}');
  final dataDir = await ClipDownloader.dataDir();
  _say('解析后的数据目录=$dataDir');
  if (!dataDir.replaceAll('\\', '/').contains('.probe/n7-probe')) {
    _say('★★★ 拒绝运行：数据目录不在 .probe/n7-probe 下');
    _say('RESULT FAIL dataDir=$dataDir');
    exit(3);
  }
  _say('数据目录隔离闸 ✓');

  Timer(const Duration(seconds: 300), () {
    _say('★★★ TIMEOUT 300s');
    _say('RESULT FAIL timeout');
    exit(4);
  });

  _timings.install();
  _wall.install();
  _say('仪器 A（引擎 timings，常驻不摘）✓');
  _say('仪器 B（postFrame 链）✓');

  try {
    await UiPrefs.load(dataDir);
  } catch (e) {
    _say('UiPrefs.load 失败（不影响帧采集）: $e');
  }
  try {
    await SourinCore.startAsync(dataDir);
    _say('SourinCore.startAsync ✓');
  } catch (e) {
    _say('SourinCore.startAsync 失败（弹窗照样能开）: $e');
  }

  try {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.center();
    await windowManager.show();
    _say('窗口已 show（1280x800）');
  } catch (e) {
    _say('windowManager 失败（继续）: $e');
  }

  runApp(const SourinApp());
  _say('runApp(SourinApp) ✓');

  for (var i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await WidgetsBinding.instance.endOfFrame;
    if (AppTray.navigatorKey.currentContext != null) break;
  }
  if (AppTray.navigatorKey.currentContext == null) {
    _say('RESULT FAIL navigator_not_ready');
    exit(5);
  }
  _say('Navigator ready ✓');
  await _settle(frames: 3, ms: 1200);

  // ── 仪器可信度（与 t107 同款）──
  _say('');
  _say('══ 仪器可信度 · 阳性对照（postFrame 忙等 200ms）══');
  final pos = await _measure('POS postFrame 忙等 200ms', () async {
    var done = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sw = Stopwatch()..start();
      while (sw.elapsedMicroseconds < 200000) {}
      done = true;
    });
    SchedulerBinding.instance.scheduleFrame();
    final sw = Stopwatch()..start();
    while (!done && sw.elapsedMilliseconds < 3000) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await _settle(frames: 1, ms: 120);
  });
  final posOk = pos.ivMax >= 150000;
  _say('  POS 判定 ivMax=${pos.ivMax}us ⇒ ${posOk ? '✓ 读得出 200ms 忙等' : '✗ 读不出'}');

  _say('');
  _say('══ 阴性对照（静止窗口，不请求任何帧）══');
  final neg = await _measure('NEG 静止窗口', () async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
  });
  _say('  阴性 frames=${neg.nWall} timings=${neg.nTiming} ⇒ '
      '${neg.nWall == 0 && neg.nTiming == 0 ? '✓ 零帧被如实记为「无读数」' : '窗口里仍有帧（对照不成立）'}');
  _say('  仪器总判：${posOk ? '可信（能读出注入的卡顿）' : '★★ 不可信'}');

  // ── 四类交互，每类 3 轮 ──
  _say('');
  _say('══ 弹幕设置弹窗：打开 / 关闭 / 滚动 / 页签切换（每类 3 轮）══');

  // ── ★ 可选：**预热**（`N7_WARMUP=1`）──────────────────────────────
  //
  // # 它验证什么
  // ```text
  // 改前读数里"打开 r1"的 raster **max=34366us、2 帧超预算**，
  // 而 r2/r3 只有 6881/11174 ⇒ 典型"**首次**才付"的成本。
  //
  // 实测（2026-10-27）：
  //   · `N7_GLASS=off`（摘掉外壳玻璃）⇒ 打开 r1 max 掉到 5891、超预算 **0** 帧
  //   · `N7_WARMUP=1`（先真开一次弹窗）⇒ 尖峰**移到预热那一次**（max 30473、2 超），
  //     之后 打开 r1 max=8410、超预算 **0** 帧
  //   ⇒ 两路都指向"进程内**第一次渲染玻璃面**才付"的一次性成本。
  // ```
  //
  // # ★★★ 还需要一个**判决性对照**：这成本是"玻璃"的，还是"第一次开弹窗"的？
  // ```text
  // 上面两路对**两种解释都一致**：
  //   ① 玻璃着色器/管线的首次编译      ② 头一次建那棵弹幕设置树（8 个 _group 等）
  // ⇒ 判决办法：`N7_WARMUP_NG=1` —— **用"摘掉玻璃"的弹窗预热**（付掉 ②），
  //   再在**挂玻璃**状态下量 打开 r1：
  //     尖峰**仍在** ⇒ 成本归**玻璃**（② 已付掉，剩下的只能是 ①）
  //     尖峰**消失** ⇒ 成本归"第一次开弹窗"，与玻璃无关
  // ```
  if (Platform.environment['N7_WARMUP'] == '1') {
    final ng = Platform.environment['N7_WARMUP_NG'] == '1';
    _say('');
    _say('══ 预热（N7_WARMUP=1${ng ? " + N7_WARMUP_NG=1" : ""}）══');
    if (ng) {
      _say('  ⚠️ 预热这一棵**摘掉玻璃** ⇒ 只付"第一次开弹窗"的成本');
      // ignore: invalid_use_of_visible_for_testing_member
      debugSkipGlassShell = true;
    }
    await _measure('WARMUP 开', () async {
      await _openDialog();
      await _settle(frames: 3, ms: 400);
    });
    final nav0 = AppTray.navigatorKey.currentState;
    if (nav0 != null && nav0.canPop()) nav0.pop();
    await _measure('WARMUP 关', () async {
      await _settle(frames: 1, ms: 320);
    });
    if (ng) {
      // ignore: invalid_use_of_visible_for_testing_member
      debugSkipGlassShell = _glassOff;
      _say('  预热后恢复挂玻璃 ⇒ 下面 打开 r1 = **挂玻璃**下的第一次开');
    }
    _say('  预热完成');
  }

  // ── ★ 可选：**包自带的着色器预缓存**（`N7_PRECACHE=1`）────────────
  //
  // # 它验证什么（比"先开一次弹窗"更有用）
  // ```text
  // `liquid_glass_widgets` 自带 `LightweightLiquidGlass.preWarm()`
  // （包内 `liquid_glass_setup.dart:113` 的 `LiquidGlassSetup.initialize()` 会调它）。
  // 本仓 `lib/` 里**一次都没调**过（grep 为空）⇒ 首次开玻璃弹窗时才现编译
  // ⇒ 改前实测"打开 r1" raster max=34366us、2 帧超预算。
  //
  // 本条对照回答的是：**在启动期调那个官方 API，能不能把尖峰吃掉**
  //   —— 若可以，修法就是"启动期预热"（一行），**而不是**去动玻璃/模糊/裁剪。
  // ```
  // ⚠️ 这是**测量**：本开关只在探针里生效，产品代码一个字不改。
  if (Platform.environment['N7_PRECACHE'] == '1') {
    _say('');
    _say('══ 预缓存：启动期调官方 LightweightLiquidGlass.preWarm() ══');
    final sw = Stopwatch()..start();
    try {
      // 先试"只预热轻量那张"（对照上一轮：它单独不管用）
      await LightweightLiquidGlass.preWarm();
      _say('  LightweightLiquidGlass.preWarm() ✓ ${sw.elapsedMilliseconds}ms');
      // 再走**官方整套**初始化（含 GlassEffect / ProgressiveBlur / 高级着色器）
      final sw2 = Stopwatch()..start();
      await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
      _say('  LiquidGlassWidgets.initialize() ✓ ${sw2.elapsedMilliseconds}ms');
    } catch (e) {
      _say('  预热失败: $e');
    }
  }

  for (var round = 1; round <= 3; round++) {
    _say('');
    _say('── round $round ──');
    // ① 打开
    await _measure('打开 r$round', () async {
      await _openDialog();
      await _settle(frames: 3, ms: 400);
    });

    // ② 滚动（弹窗内滚动区滚一段）
    await _measure('滚动 r$round', () async {
      await _scrollDialog();
      await _scrollDialog();
      await _settle(frames: 2, ms: 220);
    });

    // ③ 页签切换（显示 → 弹幕来源 → 高级 → 显示）
    await _measure('页签切换 r$round', () async {
      for (final tab in <String>['弹幕来源', '高级', '显示']) {
        await _switchTab(tab);
      }
    });

    // ④ 关闭
    final nav = AppTray.navigatorKey.currentState;
    if (nav != null && nav.canPop()) nav.pop();
    await _measure('关闭 r$round', () async {
      await _settle(frames: 1, ms: 320);
    });
  }

  _finalizeAll();

  _say('');
  _say('DONE');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  exit(0);
}