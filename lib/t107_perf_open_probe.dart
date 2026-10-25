// ═══════════════════════════════════════════════════════════════════════
//  第 13 项 · 弹窗「打开」类帧耗时采集 —— 真机（Windows release）探针
// ═══════════════════════════════════════════════════════════════════════
//
// # 它回答什么问题
// ```text
// 总计划第 13 项缺的正是「逐类帧耗时」里的**打开**一半：
//   t105 探针已实测：「关闭」11 个框各 n=34（build p50 292~345us /
//   raster p50 3.3~4.3ms，健康），而**打开**一律 `batches=0 / n=0`。
// ⇒ 本探针只解决一件事：把「打开」这一类变成**可测**。
//   测不到就照实写测不到，**绝不**把 n=0 写成"不卡"。
// ```
//
// # 上一版为什么采不到（三条实测结论，不重复调研）
// ```text
// ① t105 的采法是 `addTimingsCallback` + **采完就 removeTimingsCallback**。
// ② `FrameTiming` 的投递语义是「**光栅化完成之后**才上报」
//    （`platform_dispatcher.dart` 的 onReportTimings 注释：
//     recently rasterized frames），而 `endOfFrame` 只等 UI 线程
//    （build/layout/paint 结束），**不等光栅线程**。
// ③ `removeTimingsCallback` 在列表清空时会把
//    `platformDispatcher.onReportTimings = null`
//    （`scheduler/binding.dart` 的 removeTimingsCallback）⇒ 引擎**停止收集**，
//    尚未送达的批次**直接丢掉**。
// ⇒ 「打开」窗口是 200ms 入场动效 + 立刻报告，光栅批次还没回来就被摘了回调；
//   「关闭」窗口里有 `Future.delayed(420ms)` 兜着，批次回来了才摘 ⇒ n=34。
//   这解释了同一个函数里"关闭有、打开没有"的**全部**差异。
// ```
//
// # 本探针换了什么（三处，都是"不摘 + 双路"）
// ```text
// ① **全程不摘回调**：进程启动就 `addTimingsCallback`，一次都不 remove。
//    每个窗口按**下标切片**（`[mark, len)`），而不是按"注册/注销"切分
//    ⇒ 迟到的批次仍然被算进它真正所属的窗口。
// ② **窗口结束后 drain**：等到批次不再增长（连续两次检查无增量）或超时，
//    把光栅线程迟到的批次收干净，再切片。
// ③ **第二路仪器（不依赖引擎上报）**：`addPostFrameCallback` 常驻链，
//    逐帧记 `SchedulerBinding.currentFrameTimeStamp` + 墙钟
//    ⇒ 即使引擎一条 timings 都不给，也能给出「窗口内到底画了几帧」
//    与「帧间隔」两个读数，用来区分两种完全不同的结论：
//      · 没画帧        ⇒ 无读数（不能解释成不卡）
//      · 画了帧但没上报 ⇒ 仪器问题（换第二路读数），**不是**不卡
// ```
//
// # 真实负载对照（第 2 项要求）
// ```text
// 产品列表卡片 = `PosterCard`（首页/搜索页同一个组件），封面走它自己的
// `Image.network` 链路。为了让"封面图"是**真解码 + 真上传 + 真合成**，
// 本探针在 **loopback 上起一个临时 HTTP server**，用 `ui.PictureRecorder`
// 现画 300×450 的渐变 PNG 当封面 ⇒ 数据与图片**全部是合成的**，
// **一个字节都不碰用户真实目录**（`%APPDATA%\app.sourin.player`）。
// 对照：同一页 0 张卡 vs 60 张卡（含 60 张封面图）上开**同一个**弹窗。
// ```
//
// # 仪器可信度（第 4 项要求，缺一不可）
// ```text
// 阳性对照 A：在 **transient 回调**里忙等 200ms ⇒ buildDuration 必须跳到 ≈200ms
// 阳性对照 B：在 **postFrame 回调**里忙等 200ms ⇒ 帧间隔必须跳到 ≥200ms
// 阴性对照  ：静止窗口（不弹窗、无动画、无 setState）⇒ 两路都必须 n=0，
//             且日志必须写「无读数，不能解释成"不卡"」
// 两条阳性只要有一条读不出 200ms 量级 ⇒ 结论写「仪器不可信」，
// **不许**拿它去论证产品不卡。
// ```
//
// # 用法
// ```powershell
// flutter build windows --release -t lib/t107_perf_open_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\WishProject\sourin-flutter-spike\.probe\round107\data"
// # 外层把 APPDATA / USERPROFILE 指进同一个隔离目录，再直接跑 exe
// ```
// 产物：`.probe/round107/t107_open_probe.log`（本文件自己写，不依赖控制台）
//
// ⚠️ 本探针**不改产品代码、不写用户真实数据目录**：数据目录解析结果必须落在
//    `.probe/round107` 下，否则 `exit(3)` 什么都不做。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart' show FrameTiming, SchedulerBinding;
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_tray.dart' show AppTray, CloseAction;
import 'core/clip_download.dart' show ClipDownloader;
import 'core/ffi.dart' show SourinCore;
import 'core/ui_prefs.dart' show UiPrefs;
import 'design/widgets/app_glass_dialog.dart';
import 'shell.dart' show SourinApp;
import 'ui/tokens.dart' show AppMetrics;
import 'ui/widgets/app_dialog_shell.dart' show AppDialogShell;
import 'ui/widgets/overlay_motion.dart' show showAppDialog;
import 'ui/widgets/poster_card.dart' show PosterCard;

// ═══════════════════════════════════════════════════════════════════════
//  日志
// ═══════════════════════════════════════════════════════════════════════

late Directory _outDir;
File? _logFile;
final StringBuffer _pending = StringBuffer();

void _say(String s) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  final line = '[T107 $ts] $s';
  _pending.writeln(line);
  // 逐行落盘：release 的 windows runner 是 GUI 子系统，stdout 不一定接得住
  // （见 t74/t105 的同一条注释）⇒ 外层脚本只读这个文件。
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

  /// 最近一次批次到达的墙钟（drain 判据用）
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
//  仪器 B：常驻 postFrame 链（**不依赖引擎上报**）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// 只回答两个问题：① 这个窗口**到底画了几帧** ② 帧与帧之间隔了多久。
// 用 `currentFrameTimeStamp`（引擎 Vsynct 时钟，Monotonic）算间隔，
// 用 `DateTime.now()` 落墙钟，两者都存 ⇒ 时钟域不混。
// ⚠️ postFrame 回调**不会**主动请求新帧（不像 transient 回调会 scheduleFrame）
//    ⇒ 静止时它真的一条都不进，"无帧"这个阴性对照才有意义。
// ```
class _WallTap {
  final List<int> frameTsUs = <int>[]; // 引擎帧时间戳（相对，单调）
  final List<int> wallUs = <int>[]; // postFrame 时刻墙钟

  /// 这一帧画完之后，**是否还有下一帧被请求**
  ///
  /// 判「丢帧」必须用它：`endOfFrame` 之后我们主动 `Future.delayed(380ms)`
  /// 等待，那段时间本来就没有帧被请求 ⇒ 相邻帧时间戳会差 150~450ms。
  /// 若把这种**空闲间隔**当成丢帧，就会把「探针自己在等」记成「产品卡了」
  /// —— 那是把仪器噪声写进结论。
  final List<bool> hasNext = <bool>[];
  int ticks = 0;

  void install() {
    WidgetsBinding.instance.addPostFrameCallback(_on);
  }

  void _on(Duration _) {
    ticks++;
    frameTsUs.add(SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds);
    wallUs.add(DateTime.now().microsecondsSinceEpoch);
    hasNext.add(SchedulerBinding.instance.hasScheduledFrame);
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

/// 一个测量窗口的读数
class _Window {
  _Window(this.label);

  final String label;

  /// 窗口的引擎时钟边界（`currentFrameTimeStamp`，µs）
  ///
  /// ★ 这是本探针**唯一**的归属依据：引擎的 timings 批次是
  ///   「光栅化完成后」才上报的，实测**会晚一到两个窗口才到**
  ///   （实测：打开窗口 n=0，而那 18 帧随下一批 36 帧一起在"关闭"窗口里到达）。
  ///   按「注册/注销」或「批次下标」切分，必然把这 18 帧算到隔壁窗口
  ///   ⇒ 打开恒 0、关闭恒翻倍，两者都是假的。
  ///   改用帧自己的 `vsyncStart` 时间戳落在哪个窗口 ⇒ 迟到多久都不影响归属。
  int vsyncFrom = -1;
  int vsyncTo = -1;

  /// 引擎路（timings）——`_finalize()` 里按时间归属后填
  int nTiming = 0;
  int buildP50 = -1, buildP95 = -1, buildMax = -1, buildOver = 0;
  int rasterP50 = -1, rasterP95 = -1, rasterMax = -1, rasterOver = 0;

  /// 第二路（postFrame）
  int nWall = 0;
  int intervalP50 = -1, intervalP95 = -1, intervalMax = -1, intervalOver = 0;

  /// 被排除的「空闲间隔」数量（上一帧之后没有新帧被请求 ⇒ 不是丢帧）
  int idleGaps = 0;

  /// 墙钟（打开 = trigger→settle 的整段，用户能感知的那一段）
  int wallSpanUs = 0;

  /// drain 阶段的补充等待（证明"迟到批次"是否真迟到）
  int drainMs = 0;
  int drainArrived = 0;

  String? note;

  /// 结论：engine / wallonly / none
  String get verdict {
    if (nTiming > 0) return 'engine';
    if (nWall > 0) return 'wallonly';
    return 'none';
  }

  /// 按**帧自己的时间戳**把 `frames` 归属到本窗口，并算分位数。
  /// 按**引擎时钟**（`vsyncStart − offset`）归属到本窗口，并算分位数。
  ///
  /// # 为什么是"自校准偏移 + 时间戳"而不是下标/注册区间
  /// ```text
  /// ① 按注册/注销切分（t105 的做法）：引擎批次**迟到**，窗口结束时还在路上
  ///    ⇒ 打开恒 0、关闭翻倍（实测 36=18+18）。假数据。
  /// ② 直接拿 `vsyncStart` 与 `currentFrameTimeStamp` 比大小：本机实测两者
  ///    **不是同一个原点**（直接比 ⇒ 一个窗口都匹配不上，全 0）。
  ///    但差值可能是**常量** —— 那就只是时钟原点不同，减掉即可。
  /// ③ 纯按下标（累计帧数）切：本机实测引擎总帧 970 / 第二路 835，
  ///    多出的 135 帧全在**开头**（启动期），下标整体后移 ⇒ 前面几个窗口
  ///    会取到别人的帧（阳性对照那 200ms 就被挪到了别的窗口里）。
  /// ⇒ 采用 ②：先算 `offset = median(引擎帧 − 第二路帧)`，再核验**离散度**；
  ///   离散度小（≤5ms）才认为两路同源、可对齐 ⇒ 按对齐后的时间戳归属，
  ///   开头多出来的帧落在所有窗口之外，**不影响任何窗口**。
  ///   离散度大就退回 ③ 并**明说归属只到近似**。
  void finalizeByClock(List<FrameTiming> all, int offset) {
    final mine = <FrameTiming>[
      for (final t in all)
        if (t.timestampInMicroseconds(ui.FramePhase.vsyncStart) - offset >
                vsyncFrom &&
            t.timestampInMicroseconds(ui.FramePhase.vsyncStart) - offset <=
                vsyncTo)
          t
    ];
    _fill(mine);
  }

  /// 退路：按累计帧数切（见 `_finalizeAll` 的判定）
  void finalizeByIndex(List<FrameTiming> all, int start) {
    final from = start.clamp(0, all.length);
    final to = (start + nWall).clamp(from, all.length);
    _fill(all.sublist(from, to));
  }

  void _fill(List<FrameTiming> mine) {
    nTiming = mine.length;
    if (mine.isEmpty) return;
    final b = <int>[for (final t in mine) t.buildDuration.inMicroseconds];
    final r = <int>[for (final t in mine) t.rasterDuration.inMicroseconds];
    buildP50 = _pct(b, .5);
    buildP95 = _pct(b, .95);
    buildMax = _max(b);
    buildOver = b.where((x) => x > 16700).length;
    rasterP50 = _pct(r, .5);
    rasterP95 = _pct(r, .95);
    rasterMax = _max(r);
    rasterOver = r.where((x) => x > 16700).length;
  }
}

final List<_Window> _all = <_Window>[];

String _fmtUs(int v) => v < 0 ? 'n/a' : '$v';

void _emitWindow(_Window w) {
  _all.add(w);
  _say('WINDOW ${w.label}');
  _say('  ENGINE n=${w.nTiming}（窗口引擎时钟区间 (${w.vsyncFrom}, ${w.vsyncTo}]）');
  if (w.nTiming > 0) {
    _say('    build : p50=${_fmtUs(w.buildP50)} p95=${_fmtUs(w.buildP95)} '
        'max=${_fmtUs(w.buildMax)} 超预算(>16700us)=${w.buildOver}/${w.nTiming}');
    _say('    raster: p50=${_fmtUs(w.rasterP50)} p95=${_fmtUs(w.rasterP95)} '
        'max=${_fmtUs(w.rasterMax)} 超预算(>16700us)=${w.rasterOver}/${w.nTiming}');
  } else {
    _say('    ⚠️ 引擎路 n=0 ⇒ 本窗口**无 timings 读数**（不得解释成"不卡"）');
  }
  _say('  WALL frames=${w.nWall} span=${w.wallSpanUs}us');
  if (w.nWall > 1) {
    _say('    interval: p50=${_fmtUs(w.intervalP50)} p95=${_fmtUs(w.intervalP95)} '
        'max=${_fmtUs(w.intervalMax)} '
        '超预算(>16700us)=${w.intervalOver}/${w.nWall - 1} '
        '（已排除空闲间隔 ${w.idleGaps} 个：上一帧之后没有新帧被请求）');
  } else if (w.nWall == 1) {
    _say('    interval: 只有 1 帧 ⇒ 无帧间隔读数');
  } else {
    _say('    ⚠️ 第二路 frames=0 ⇒ 本窗口**一帧都没画** ⇒ 无读数（不得解释成"不卡"）');
  }
  _say('  DRAIN wait=${w.drainMs}ms');
  if (w.note != null) _say('  NOTE ${w.note}');
}

// ═══════════════════════════════════════════════════════════════════════
//  同步节奏（与 t105 同一套：endOfFrame 不含动效时间）
// ═══════════════════════════════════════════════════════════════════════

Future<void> _settle({int frames = 2, int ms = 450}) async {
  for (var i = 0; i < frames; i++) {
    await WidgetsBinding.instance.endOfFrame;
  }
  await Future<void>.delayed(Duration(milliseconds: ms));
  await WidgetsBinding.instance.endOfFrame;
}

/// drain：等到「timings 批次 / 帧数」不再增长为止（连续两次同值即停）。
///
/// 为什么必须有它：`FrameTiming` 是光栅化完成后才上报的（见文件头 ②③），
/// 窗口一结束就切片会把**还在路上的**批次丢给下一个窗口 —— 那正是
/// t105「打开」读数为 0 的机制。
Future<int> _drain({int maxMs = 1200, int stepMs = 60}) async {
  var waited = 0;
  var stable = 0;
  var last = -1;
  while (waited < maxMs) {
    await Future<void>.delayed(Duration(milliseconds: stepMs));
    waited += stepMs;
    final now = _timings.frames.length;
    if (now == last) {
      stable++;
      if (stable >= 2) break;
    } else {
      stable = 0;
      last = now;
    }
  }
  return waited;
}

// ═══════════════════════════════════════════════════════════════════════
//  单窗口测量
// ═══════════════════════════════════════════════════════════════════════

/// 最近一帧的引擎时间戳（µs）。
///
/// ⚠️ 为什么不用 `SchedulerBinding.currentFrameTimeStamp`：
///   它内部是 `_currentFrameTimeStamp!`，而那个字段**只在帧回调期间非空**
///   （2026-10-25 实测：在帧外读它 ⇒ release 下 `Null check operator used on
///   a null value`，整条探针挂掉）。第二路仪器本来就在 postFrame 里记录了
///   每帧的时间戳 ⇒ 直接用最后一条，同一个时钟域，且恒可读。
int _lastVsync() => _wall.frameTsUs.isEmpty ? 0 : _wall.frameTsUs.last;

Future<_Window> _measure(
  String label,
  Future<void> Function() body, {
  bool drain = false,
}) async {
  // 归属区间取 (vsyncFrom, vsyncTo]：
  //   `vsyncFrom` = 窗口开始前**最后一帧**的时间戳（开区间 ⇒ 那一帧归上一个窗口）
  //   `vsyncTo`   = 窗口结束后最后一帧的时间戳（闭区间 ⇒ 本窗口的末帧算进来）
  final vsyncFrom = _lastVsync();
  final wMark = _wall.mark;
  final wall0 = DateTime.now();

  // ⚠️ 场景本身炸了**也要**留下一个窗口读数：否则"这一段没数据"和
  //   "这一段没跑"就分不清，而第 13 项最忌讳的正是把两者混为一谈。
  String? bodyErr;
  try {
    await body();
  } catch (e) {
    bodyErr = '$e';
    _say('  !! 本窗口场景异常: $e');
  }

  final span = DateTime.now().difference(wall0).inMicroseconds;
  final vsyncTo = _lastVsync();

  var waited = 0;
  if (drain) waited = await _drain();

  final w = _Window(label)
    ..vsyncFrom = vsyncFrom
    ..vsyncTo = vsyncTo
    ..wallSpanUs = span
    ..drainMs = waited;

  // ── 第二路：帧数 + 帧间隔（**排除空闲间隔**）──
  final tsMark = _wall.frameTsUs.sublist(wMark);
  w.nWall = tsMark.length;
  if (tsMark.length > 1) {
    final iv = <int>[];
    var idle = 0;
    for (var i = 1; i < tsMark.length; i++) {
      final delta = tsMark[i] - tsMark[i - 1];
      // 空闲间隔判定：探针自己在 `_settle()` 里 `Future.delayed(380ms)` 等动效，
      // 那段时间**没有帧被请求** ⇒ 相邻时间戳会差 150~450ms。
      // 若把它算成丢帧，就是把"探针在等"记成"产品卡了"。
      // 判据取 50ms：60Hz 下这是 3 个 vsync，动效期间真丢 3 帧已经是肉眼可辨的卡；
      // 而探针的 idle 间隔远大于它（≥150ms）⇒ 两者不会混。
      // ⚠️ 代价：真的卡 50ms 以上会被归到"大间隔"里 —— 所以下面
      //   `intervalMax` 保留**未过滤**的最大值，阳性对照正是靠它判读。
      if (delta > 50000) {
        idle++;
        continue;
      }
      iv.add(delta);
    }
    w.idleGaps = idle;
    if (iv.isNotEmpty) {
      w.intervalP50 = _pct(iv, .5);
      w.intervalP95 = _pct(iv, .95);
      w.intervalOver = iv.where((x) => x > 16700).length;
    }
    w.intervalMax = -1;
    for (var i = 1; i < tsMark.length; i++) {
      final delta = tsMark[i] - tsMark[i - 1];
      if (delta > w.intervalMax) w.intervalMax = delta;
    }
  }

  // 引擎路留给 `_finalizeAll()`（要等迟到批次全部到齐才能按时间归属）
  if (bodyErr != null) w.note = '场景异常 ⇒ 本窗口读数不完整：$bodyErr';
  _emitWindow(w);
  return w;
}

/// 收尾：等引擎把**所有**迟到批次送完，再按时间戳把帧归属到各窗口。
Future<void> _finalizeAll() async {
  _say('');
  _say('── 终判前的长 drain：等引擎把迟到批次送干净 ──');
  var waited = 0;
  var last = -1;
  var stable = 0;
  while (waited < 10000) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    waited += 250;
    final now = _timings.frames.length;
    if (now == last) {
      stable++;
      if (stable >= 8) break; // 连续 2s 无新增 ⇒ 认定送完
    } else {
      stable = 0;
      last = now;
    }
  }
  _say('  长 drain 结束：wait=${waited}ms 累计引擎帧=${_timings.frames.length} '
      '批次=${_timings.batches}');

  final totalWall = _all.fold<int>(0, (a, w) => a + w.nWall);

  // ── 两路时钟对齐：offset = median(引擎 vsyncStart − 第二路 currentFrameTimeStamp) ──
  final engineTs = <int>[
    for (final t in _timings.frames)
      t.timestampInMicroseconds(ui.FramePhase.vsyncStart)
  ];
  final wallTs = _wall.frameTsUs;
  final n = math.min(engineTs.length, wallTs.length);
  int offset = 0;
  var spread = -1;
  if (n > 20) {
    final deltas = <int>[for (var i = 0; i < n; i++) engineTs[i] - wallTs[i]]
      ..sort();
    offset = deltas[deltas.length ~/ 2];
    final dev = <int>[for (final d in deltas) (d - offset).abs()]..sort();
    spread = dev[(dev.length * 95 / 100).round().clamp(0, dev.length - 1)];
  }
  final aligned = n > 20 && spread >= 0 && spread <= 5000;
  _say('  两路时钟对齐：引擎帧=${engineTs.length} 第二路帧=${wallTs.length} '
      '前 $n 帧配对 ⇒ offset=$offset us，离散度(p95)=$spread us');
  _say('  ⇒ ${aligned ? "✓ 两路同源（离散度 ≤5ms）⇒ 按对齐后的时间戳归属" : "✗ 对齐不了 ⇒ 退回按累计帧数归属（只到近似）"}');

  var cursor = 0;
  for (final w in _all) {
    if (aligned) {
      w.finalizeByClock(_timings.frames, offset);
    } else {
      w.finalizeByIndex(_timings.frames, cursor);
    }
    cursor += w.nWall;
  }
  final attributed = _all.fold<int>(0, (a, w) => a + w.nTiming);
  _say('  仪器自洽核对：第二路总帧=$totalWall 引擎总帧=${engineTs.length} '
      '已归属=$attributed');
  if (engineTs.length != totalWall) {
    _say('  ⚠️ 两路总帧不等（差 ${engineTs.length - totalWall}，'
        '多的在启动期）⇒ 这正是"必须按时间戳而不是按下标归属"的原因');
  }

  // ── 逐窗口的**终判**读数（emit 时引擎路还没归属，这里是归属后的真读数）──
  //
  // ⚠️ 上面 `_emitWindow()` 打在窗口刚结束时，那时引擎批次可能还在路上，
  //   所以它的 `ENGINE n=0` 是**过程态**。以这里的 FINAL 为准。
  _say('');
  _say('── 逐窗口终判（归属完成后）──');
  for (final w in _all) {
    _say('FINAL ${w.label} | engine_n=${w.nTiming} '
        'build[p50=${_fmtUs(w.buildP50)} p95=${_fmtUs(w.buildP95)} '
        'max=${_fmtUs(w.buildMax)} over=${w.buildOver}] '
        'raster[p50=${_fmtUs(w.rasterP50)} p95=${_fmtUs(w.rasterP95)} '
        'max=${_fmtUs(w.rasterMax)} over=${w.rasterOver}] '
        'wall_n=${w.nWall} iv[p50=${_fmtUs(w.intervalP50)} '
        'p95=${_fmtUs(w.intervalP95)} max=${_fmtUs(w.intervalMax)} '
        'over=${w.intervalOver} idle=${w.idleGaps}]');
  }
  _say('封面图累计请求 ${_server?.served ?? 0} 次');
}

// ═══════════════════════════════════════════════════════════════════════
//  合成数据：loopback 封面服务器（绝不碰用户真实目录）
// ═══════════════════════════════════════════════════════════════════════

/// 现画 [count] 张 300×450 的渐变 PNG（每张不同色相 + 几条不透明横杠，
/// 让解码/上传/合成的成本与真实海报同一量级，而不是纯色块的极端）。
Future<List<Uint8List>> _makeCovers(int count) async {
  final out = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final hue = (i * 37) % 360;
    final r = (120 + 100 * math.sin(hue * math.pi / 180)).round().clamp(0, 255);
    final g = (90 + 80 * math.sin((hue + 120) * math.pi / 180)).round().clamp(0, 255);
    final b = (110 + 90 * math.sin((hue + 240) * math.pi / 180)).round().clamp(0, 255);
    c.drawRect(
      const Rect.fromLTWH(0, 0, 300, 450),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          const Offset(300, 450),
          [ui.Color.fromARGB(255, r, g, b), const ui.Color(0xFF101018)],
        ),
    );
    // 海报上的"文字块"：几条高对比横杠（让像素不是纯渐变，压缩率也不极端）
    for (var k = 0; k < 6; k++) {
      c.drawRect(
        Rect.fromLTWH(20, 320.0 + k * 18, 80 + (k * 31) % 180, 6),
        Paint()..color = const ui.Color(0xCCFFFFFF),
      );
    }
    final img = await rec.endRecording().toImage(300, 450);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    out.add(bd!.buffer.asUint8List());
    img.dispose();
  }
  return out;
}

class _CoverServer {
  _CoverServer(this._server, this._covers);

  final HttpServer _server;
  final List<Uint8List> _covers;

  /// 实际被请求的封面张数 —— **证明"真实负载"里真的有封面图**
  /// （否则 60 张卡全是空占位，读数会把"没图"当成"图不贵"，属乐观假读数）
  int served = 0;

  String urlFor(int i) =>
      'http://127.0.0.1:${_server.port}/c/${i % _covers.length}.png';

  static Future<_CoverServer> start(int variants) async {
    final covers = await _makeCovers(variants);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late _CoverServer self;
    server.listen((req) async {
      final res = req.response;
      final m = RegExp(r'^/c/(\d+)\.png$').firstMatch(req.uri.path);
      if (m == null) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      final i = (int.tryParse(m.group(1)!) ?? 0) % covers.length;
      self.served++;
      res.headers.contentType = ContentType('image', 'png');
      res.add(covers[i]);
      await res.close();
    });
    self = _CoverServer(server, covers);
    return self;
  }

  Future<void> stop() => _server.close(force: true);
}

// ═══════════════════════════════════════════════════════════════════════
//  负载页：产品自己的 PosterCard 网格（与 search_page.dart:1090 同一套
//  布局参数），封面走产品自己的 Image.network 链路
// ═══════════════════════════════════════════════════════════════════════

class _LoadPage extends StatelessWidget {
  const _LoadPage({required this.count, required this.cover, required this.tag});

  final int count;
  final String Function(int) cover;
  final String tag;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const ui.Color(0xFF0A0A0F),
      child: GridView.builder(
        padding: const EdgeInsets.all(24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 6,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
          // 与产品同一算式（search_page.dart:1090 那块）
          childAspectRatio: AppMetrics.posterWidth /
              (AppMetrics.posterWidth / AppMetrics.posterAspect +
                  AppMetrics.posterMetaHeight(titleLines: 2)),
        ),
        itemCount: count,
        itemBuilder: (_, i) => PosterCard(
          title: '合成标题 $i —— $tag',
          cover: count == 0 ? null : cover(i),
          subtitle: '第 ${i + 1} 集 · 合成数据',
          titleLines: 2,
        ),
      ),
    );
  }
}

void _pushLoadPage(int count) {
  final nav = AppTray.navigatorKey.currentState;
  if (nav == null) throw StateError('navigator 不可用');
  final server = _server;
  nav.push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, __, ___) => _LoadPage(
        count: count,
        tag: 'load$count',
        cover: (i) => server == null
            ? ''
            : server.urlFor(i),
      ),
    ),
  );
}

_CoverServer? _server;

// ═══════════════════════════════════════════════════════════════════════
//  弹窗构造（与 t105 的用例同一批 builder，逐字）
// ═══════════════════════════════════════════════════════════════════════

AppGlassDialogActions _acts({
  required String confirmLabel,
  bool destructive = false,
  String cancelLabel = '取消',
}) =>
    AppGlassDialogActions(
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      confirmIsDestructive: destructive,
      onCancel: () => AppTray.navigatorKey.currentState?.pop(false),
      onConfirm: () => AppTray.navigatorKey.currentState?.pop(true),
    );

class _Dlg {
  const _Dlg(this.id, this.src, {this.build, this.trigger});

  final String id;
  final String src;
  final Widget Function(BuildContext)? build;
  final Future<void> Function()? trigger;
}

List<_Dlg> _dlgs() => <_Dlg>[
      _Dlg('01_tray_close', 'lib/core/app_tray.dart（AppTray.onWindowClose → showAppDialog<CloseAction>）',
          trigger: () async => AppTray.instance.onWindowClose()),
      _Dlg('02_cache_delete', 'lib/ui/cache_page.dart（「删除整部」的 AppGlassDialog）', build: (_) {
        return AppGlassDialog(
          title: '删除整部？',
          content: const Text('「三体（2023）」\n'
              '将删除 12 集 / 共 8.4 GB。\n'
              '文件会从磁盘上真正删除，此操作不可恢复。'),
          actions: _acts(confirmLabel: '删除'),
        );
      }),
      _Dlg('03_data_manage_clear', 'lib/ui/settings/data_manage_page.dart（「清理图片缓存」的 AppGlassDialog）',
          build: (_) {
        return AppGlassDialog(
          title: '清理「图片缓存」',
          content: const Text('将删除 128 项，释放 316.0 MB。\n\n'
              '海报 / 剧照的本地缓存，删掉后滚动时会重新下载。\n\n此操作不可撤销。'),
          actions: _acts(confirmLabel: '清理'),
        );
      }),
      _Dlg('04_emby_delete_source', 'lib/ui/settings/emby_page.dart（「删除源」的 AppGlassDialog）',
          build: (_) {
        return AppGlassDialog(
          title: '删除源「客厅 Emby」？',
          content: const Text('会删掉插件文件 emby.js，这个源会从首页源栏消失。\n\n'
              '它的配置与登录凭据（plugins/.data/emby-live.json）不会被删 —— '
              '以后用同一个 id 再装回来，地址和账号还在。'),
          actions: _acts(confirmLabel: '删除'),
        );
      }),
      _Dlg('05_skip_confirm_2btn',
          'lib/ui/settings/skip_page.dart（「清除片头片尾」确认框）+ 它的调用点', build: (_) {
        return AppGlassDialog(
          title: '清除片头片尾',
          content: const Text('确定清除「三体（2023）」的片头片尾设置吗？\n\n'
              '清除后播放这个作品时不再自动跳过。此操作无法撤销。'),
          actions: _acts(confirmLabel: '清除'),
        );
      }),
      _Dlg('06_sync_confirm_2btn', 'lib/ui/widgets/sync_panel.dart（「删除云端备份」的 AppGlassDialog）', build: (_) {
        return AppGlassDialog(
          title: '删除云端备份',
          content: const Text('确定删掉云端的这一份备份吗？\n\n'
              'sourin-backup-20261019-2155.zip\n\n'
              '⚠️ 云盘上的删除一般不进回收站，删了就找不回来了。'),
          actions: _acts(confirmLabel: '删除'),
        );
      }),
      _Dlg('07_shell_glass', 'lib/ui/widgets/app_dialog_shell.dart（AppDialogShell(glass: true)）',
          build: (_) {
        return AppDialogShell(
          title: '弹窗外壳 · 玻璃档',
          subtitle: '轮廓取样：圆角应为 Radii.lg（22）',
          glass: true,
          width: 460,
          scrollable: false,
          onClose: () => AppTray.navigatorKey.currentState?.pop(),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Text('这张卡片由产品自己的 AppDialogShell(glass: true) 渲染。'),
          ),
        );
      }),
    ];

void _show(_Dlg d) {
  final ctx = AppTray.navigatorKey.currentContext;
  if (ctx == null) throw StateError('navigatorKey.currentContext 为空');
  showAppDialog<void>(
    context: ctx,
    barrierDismissible: false,
    builder: d.build!,
  ).ignore();
}

// ═══════════════════════════════════════════════════════════════════════
//  阳性 / 阴性对照
// ═══════════════════════════════════════════════════════════════════════

void _busyWait(int micros) {
  final sw = Stopwatch()..start();
  while (sw.elapsedMicroseconds < micros) {
    // 纯 CPU 忙等：不许 await（await 会让出，就不是"卡住 UI 线程"了）
  }
}

/// 阳性对照 A：transient 回调（`handleBeginFrame` 内）里忙等。
/// 相位在 build 之前 ⇒ 耗时**必须**计入 `FrameTiming.buildDuration`
/// （t74 探针已就这个相位写过同样的对照）。
Future<_Window> _positiveControlTransient(int micros) async {
  var done = false;
  return _measure('POS-A transient 忙等 ${micros ~/ 1000}ms', () async {
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _busyWait(micros);
      done = true;
    });
    // 这一帧由 scheduleFrameCallback 自己请求；等它画完。
    // ⚠️ 必须有上限：一旦注入回调没被调用（例如帧没被调度），
    //   无界 while 会把整条探针挂死（2026-10-25 实测：挂到 420s 看门狗）。
    final sw = Stopwatch()..start();
    while (!done && sw.elapsedMilliseconds < 3000) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (!done) _say('  ⚠️ POS-A 注入回调 3s 内没被调用（帧没被调度）');
    await _settle(frames: 2, ms: 120);
  });
}

/// 阳性对照 B：postFrame 回调里忙等。
/// postFrame 在 persistent 之后、提交帧之前 ⇒ 既计入 build，也把
/// **下一帧**推后（第二路的帧间隔必须跳起来）。
Future<_Window> _positiveControlPostFrame(int micros) async {
  var done = false;
  return _measure('POS-B postFrame 忙等 ${micros ~/ 1000}ms', () async {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _busyWait(micros);
      done = true;
    });
    SchedulerBinding.instance.scheduleFrame();
    final sw = Stopwatch()..start();
    while (!done && sw.elapsedMilliseconds < 3000) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (!done) _say('  ⚠️ POS-B 注入回调 3s 内没被调用');
    await _settle(frames: 2, ms: 120);
  });
}

/// 阴性对照：什么都不做的一段窗口（不弹窗、无动画、无 setState）。
Future<_Window> _negativeControl() async {
  final w = await _measure('NEG 静止窗口（不请求任何帧）', () async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
  });
  w.note = w.nWall == 0 && w.nTiming == 0
      ? '本窗口一帧都没画、一条 timings 都没有 ⇒ **无读数**，'
          '不能解释成"不卡"（这正是"没数据 ≠ 不卡"的自检）'
      : '窗口内仍有帧（有东西在动）⇒ 本对照不成立，需在更静止的时刻重跑';
  return w;
}

// ═══════════════════════════════════════════════════════════════════════
//  主流程
// ═══════════════════════════════════════════════════════════════════════

final List<String> _errs = <String>[];

/// 把一段场景包起来：某一段炸了**不许**把整条探针带走（否则前几段读数也丢了）。
Future<void> _guard(String name, Future<void> Function() f) async {
  try {
    await f();
  } catch (e, st) {
    _errs.add('$name: $e');
    _say('  !! 场景异常 [$name]: $e');
    _say('     ${st.toString().split('\n').take(4).join(' | ')}');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _outDir = Directory('${Directory.current.path}${Platform.pathSeparator}'
      '.probe${Platform.pathSeparator}round107');
  if (!_outDir.existsSync()) _outDir.createSync(recursive: true);
  _logFile = File('${_outDir.path}${Platform.pathSeparator}t107_open_probe.log');
  _logFile!.writeAsStringSync('');

  FlutterError.onError = (FlutterErrorDetails d) {
    final msg = d.exceptionAsString();
    _errs.add(msg);
    _say('  !! FLUTTER ERROR: $msg');
  };
  ui.PlatformDispatcher.instance.onError = (Object e, StackTrace st) {
    _errs.add('zone: $e');
    _say('  !! ZONE ERROR: $e');
    return true;
  };

  _say('══════ T107 · 第 13 项「打开」类帧耗时 ══════');
  _say('cwd=${Directory.current.path}');
  _say('产物=${_logFile!.path}');

  // ── 隔离数据目录硬闸 ────────────────────────────────────────────
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  _say('DATA_DIR_OVERRIDE(编译期)=${override.isEmpty ? "<未设>" : override}');
  _say('APPDATA=${Platform.environment["APPDATA"]}');
  final dataDir = await ClipDownloader.dataDir();
  _say('解析后的数据目录=$dataDir');
  final isolated = dataDir.replaceAll('\\', '/').contains('.probe/round107');
  if (!isolated) {
    _say('★★★ 拒绝运行：数据目录不在隔离目录下（会在用户真实目录里留东西）');
    _say('RESULT FAIL dataDir=$dataDir');
    exit(3);
  }
  _say('数据目录隔离闸 ✓');

  Timer(const Duration(seconds: 420), () {
    _say('★★★ TIMEOUT 420s ⇒ 强制退出');
    _say('RESULT FAIL timeout');
    exit(4);
  });

  // ── 仪器：**先挂、全程不摘** ────────────────────────────────────
  _timings.install();
  _wall.install();
  _say('仪器 A（引擎 timings）已挂 —— 全程不摘，按窗口下标切片');
  _say('仪器 B（postFrame 链）已挂 —— 只报帧数/帧间隔，不主动请求帧');

  // ── 与产品 main() 对齐的最小初始化 ──────────────────────────────
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
  _say('AppTray.action=${AppTray.instance.action}');

  try {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.center();
    await windowManager.show();
    _say('窗口已 show（1280x800，不抢焦点）');
  } catch (e) {
    _say('windowManager 调用失败（继续）: $e');
  }

  runApp(const RepaintBoundary(child: SourinApp()));
  _say('runApp(SourinApp) ✓ —— 根是产品的');

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
  await _settle(frames: 2, ms: 1500);

  // ── ① 仪器可信度：阳性对照 ──────────────────────────────────────
  _say('');
  _say('══ 仪器可信度 · 阳性对照（读不出 200ms ⇒ 仪器不可信）══');
  final posA = await _positiveControlTransient(200000);
  final posB = await _positiveControlPostFrame(200000);

  final posAOk = posA.buildMax >= 150000;
  final posBOk = posB.intervalMax >= 150000 || posB.buildMax >= 150000;
  _say('  POS-A 判定 buildMax=${posA.buildMax}us ⇒ '
      '${posAOk ? "✓ 读得出 200ms 忙等" : "✗ 读不出（引擎路不可信）"}');
  _say('  POS-B 判定 intervalMax=${posB.intervalMax}us '
      'buildMax=${posB.buildMax}us ⇒ '
      '${posBOk ? "✓ 读得出 200ms 忙等" : "✗ 读不出（第二路不可信）"}');
  var instrumentOk = posAOk || posBOk;
  _say('  仪器总判：${instrumentOk ? "可信（至少一路能读出注入的卡顿）" : "★★ 不可信"}');

  // ── ② 阴性对照 ──────────────────────────────────────────────────
  _say('');
  _say('══ 仪器可信度 · 阴性对照 ══');
  final neg = await _negativeControl();
  _say('  阴性对照 frames=${neg.nWall} timings=${neg.nTiming} '
      '⇒ ${neg.nWall == 0 && neg.nTiming == 0 ? "✓ 零帧被如实记为「无读数」" : "窗口里仍有帧"}');

  // ── ③ 逐类弹窗：打开 + 关闭（每个 3 轮，n 累积）──────────────────
  _say('');
  _say('══ 逐类弹窗「打开」帧耗时（每框 3 轮）══');
  final openWins = <_Window>[];
  for (final d in _dlgs()) {
    _say('');
    _say('── ${d.id}  ←  ${d.src}');
    for (var round = 1; round <= 3; round++) {
      // 打开
      final w = await _measure('${d.id} 打开 r$round', () async {
        if (d.trigger != null) {
          if (AppTray.instance.action != CloseAction.ask) {
            throw StateError('closeAction=${AppTray.instance.action} 不是 ask');
          }
          await d.trigger!();
        } else {
          _show(d);
        }
        // 入场动效（overlaySheetAnimationStyle ~200ms）+ 落定
        await _settle(frames: 3, ms: 380);
      });
      openWins.add(w);
      // 关闭（同一把尺量同一段退场动效，供与 t105 的关闭读数对照）
      final nav = AppTray.navigatorKey.currentState;
      if (nav != null && nav.canPop()) nav.pop();
      await _measure('${d.id} 关闭 r$round', () async {
        await _settle(frames: 1, ms: 300);
      });
    }
  }

  // ── ④ 真实负载对照：空数据 vs 60 卡 + 60 封面图 ──────────────────
  _say('');
  _say('══ 真实负载对照（合成数据，loopback 封面图）══');
  try {
    _server = await _CoverServer.start(12);
    _say('合成封面服务器已起：${_server!.urlFor(0)} 起 12 张 300×450 PNG');
  } catch (e) {
    _say('封面服务器起不来（本轮负载对照无封面图）: $e');
  }

  final loadDlg = _dlgs().firstWhere((d) => d.id == '03_data_manage_clear');
  final loadWins = <_Window>[];
  await _guard('load', () async {
  for (final count in <int>[0, 60]) {
    _say('');
    _say('── 负载档：列表 $count 张卡（封面 ${count == 0 ? 0 : count} 张）');
    if (count > 0 && _server == null) {
      _say('   ⚠️ 无封面服务器 ⇒ 本档只是"空图卡片"，负载偏轻，读数偏乐观');
    }
    _pushLoadPage(count);
    // 让图片解码 + 上传 + 首帧合成落定（60 张封面要几轮才解完）
    await _settle(frames: 3, ms: count == 0 ? 600 : 2200);
    _say('   封面图实际被请求 ${_server?.served ?? 0} 次'
        '（${count == 0 ? "空数据基线：应为 0" : "真实负载：应 ≥ 可见卡片数"}）');
    if (count > 0 && (_server?.served ?? 0) == 0) {
      _say('   ⚠️ 一张封面都没被请求 ⇒ 本档其实是"空图卡片"，'
          '负载比声称的低，读数偏乐观');
    }
    for (var r = 1; r <= 2; r++) {
      final w = await _measure('LOAD$count 打开 03_data_manage_clear r$r', () async {
        _show(loadDlg);
        await _settle(frames: 3, ms: 380);
      });
      loadWins.add(w);
      AppTray.navigatorKey.currentState?.pop();
      await _settle(frames: 1, ms: 260);
    }
    // 退掉负载页
    AppTray.navigatorKey.currentState?.maybePop();
    await _settle(frames: 2, ms: 500);
  }
  });

  await _server?.stop();

  // ★ 终判：等迟到批次到齐，再按帧时间戳把帧归属到各窗口
  await _finalizeAll();

  // ★ 仪器可信度**终判**：必须放在归属完成之后。
  //   emit 那一刻引擎批次还在路上（实测迟到 1~2 个窗口），
  //   所以上面那段"POS-A ✗ 读不出"是**过程态**，不是结论。
  final posAOk2 = posA.buildMax >= 150000;
  final posBOk2 = posB.intervalMax >= 150000 || posB.buildMax >= 150000;
  instrumentOk = posAOk2 || posBOk2;
  _say('');
  _say('══ 仪器可信度 · 终判（归属完成后）══');
  _say('  POS-A（transient 注入 200ms 忙等）：build max=${posA.buildMax}us '
      'p95=${posA.buildP95}us ⇒ ${posAOk2 ? "✓ 读得出注入的卡顿" : "✗ 读不出"}');
  _say('  POS-B（postFrame 注入 200ms 忙等）：帧间隔 max=${posB.intervalMax}us '
      'build max=${posB.buildMax}us ⇒ ${posBOk2 ? "✓ 读得出注入的卡顿" : "✗ 读不出"}');
  _say('  阴性对照：帧数=${neg.nWall} timings=${neg.nTiming} ⇒ '
      '${neg.nWall == 0 && neg.nTiming == 0 ? "✓ 零帧如实记为「无读数」，不写成不卡" : "窗口里仍有帧"}');
  _say('  仪器总判：${instrumentOk ? "可信（两路都能读出注入的卡顿）" : "★★ 不可信"}');

  // ── ⑤ 汇总表 ────────────────────────────────────────────────────
  _say('');
  _say('══════ 汇总表 ══════');
  _say('TABLE|scene|engine_n|build_p50|build_p95|raster_p50|raster_p95|'
      'over_budget|wall_frames|interval_p50|interval_p95|wall_span_us');

  void row(String label, Iterable<_Window> ws) {
    final list = ws.toList();
    final b = <int>[for (final w in list) if (w.buildP50 >= 0) w.buildP50];
    final r = <int>[for (final w in list) if (w.rasterP50 >= 0) w.rasterP50];
    final n = list.fold<int>(0, (a, w) => a + w.nTiming);
    final over = list.fold<int>(0, (a, w) => a + w.buildOver + w.rasterOver);
    final nw = list.fold<int>(0, (a, w) => a + w.nWall);
    final iv = <int>[for (final w in list) if (w.intervalP50 >= 0) w.intervalP50];
    final span = list.isEmpty ? 0 : list.first.wallSpanUs;
    _say('TABLE|$label|$n|${_pct(b, .5)}|${_pct(b, .95)}|${_pct(r, .5)}|'
        '${_pct(r, .95)}|$over|$nw|${_pct(iv, .5)}|${_pct(iv, .95)}|$span');
  }

  row('POS-A', [posA]);
  row('POS-B', [posB]);
  row('NEG', [neg]);
  for (final d in _dlgs()) {
    row(d.id, openWins.where((w) => w.label.startsWith('${d.id} 打开')));
  }
  row('LOAD0-空数据', loadWins.where((w) => w.label.startsWith('LOAD0')));
  row('LOAD60-真实负载', loadWins.where((w) => w.label.startsWith('LOAD60')));

  // ── ⑥ 结论（只写读数支撑得了的话）───────────────────────────────
  _say('');
  _say('══════ 结论 ══════');
  final openEngine = openWins.where((w) => w.nTiming > 0).length;
  final openWallOnly = openWins.where((w) => w.nTiming == 0 && w.nWall > 0).length;
  final openNone = openWins.where((w) => w.nTiming == 0 && w.nWall == 0).length;
  _say('打开窗口共 ${openWins.length} 个：引擎路有读数 $openEngine 个 / '
      '只有第二路读数 $openWallOnly 个 / 两路都没有 $openNone 个');
  if (openNone > 0) {
    _say('★★ $openNone 个打开窗口两路都 n=0 ⇒ 这些框的打开耗时**采不到**，'
        '按纪律记为"无读数"，**不是**"不卡"');
  }
  final e = _errs.length;
  _say('渲染异常=$e${e > 0 ? '（明细见上）' : ''}');
  _say('RESULT ${instrumentOk ? "PASS" : "FAIL"} '
      'open_windows=${openWins.length} engine_readable=$openEngine '
      'wallonly=$openWallOnly none=$openNone errors=$e');
  _say('DONE');

  await Future<void>.delayed(const Duration(milliseconds: 400));
  exit(instrumentOk ? 0 : 1);
}
