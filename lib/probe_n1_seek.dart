// ═══════════════════════════════════════════════════════════════════════
//  N1（目标站播放卡顿）· 取流侧 / 渲染侧 权重分离探针 —— 真机 Windows release
// ═══════════════════════════════════════════════════════════════════════
//
// # 它回答什么（N1 唯一未完成的那一步）
// ```text
// N1 两半读数已齐，但**没有同一时刻的对照**：
//   取流侧：媒体流 ttfb n=17 p50=675ms（Owner 在场那次 seek 的 range 请求 ttfb=1811ms）
//   渲染侧：964 帧 raster 超预算 19.8%（build 只 1.0%）
// ⇒ 缺的是"同一次起播 + 同一次 seek"下的两侧读数
//   ⇒ 只有这样才能把"用户感觉的那一卡"拆成上游首字节 / 光栅化 两份权重。
// ```
//
// # 为什么必须是**真机 release**、且必须挂**真实 PlayerPage**
// ```text
// ① `flutter_test` 不上报 FrameTiming（本仓已实测登记）；
// ② debug 构建的 raster 与 release 不同量级 ⇒ 不可比；
// ③ 复刻一个"像播放页的页面"量出来的不是用户看的那一页
//    ⇒ 直接 `PlayerPage(...)` 挂上去，走**生产构造**与**生产取流**（streamproxy 全链路）。
// ```
//
// # 为什么不用鼠标/键盘驱动（本仓硬纪律）
// ```text
// 禁止 SetCursorPos / mouse_event / SetForegroundWindow，也不许让 Owner 代点。
// 这里的 seek 走**生产探针钩子** `debugPlayerSeekForProbe` ——
// 它内部就是 `s._player.seek(target)`（player_page.dart:20386），
// 与用户拖进度条落到的是**同一个原生 seek 边界**。
// ```
//
// # 仪器口径（与 shell.dart 的帧日志同款语义）
// ```text
// · addTimingsCallback **全程不摘**（本仓踩过："采完就 remove" 会把迟到的批次丢掉，
//   于是"打开"窗口恒 n=0 —— 见 lib/t107_perf_open_probe.dart 头部三条实测结论）；
// · 按**窗口下标切片**：W0 预热 / W1 播放 / W2 seek 后；
// · 每窗口结束 drain 一次（连续两次无增量或超时）再统计。
// ```
//
// # 跑法
// ```bash
// flutter build windows --release \
//   -t lib/probe_n1_seek.dart \
//   --dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\n1run\data
// # 然后 cd 到仓库根再启动（帧日志/读数都落在 .probe/ 下）
// ```
// ⚠️ 生产**不含**本文件（它是独立 `-t` 入口，`lib/shell.dart` 一行都不改）。

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';

import 'core/ffi.dart';
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'ui/player_page.dart';

// ══════════════════════════════════════════════════════════════════════
//  参数（可用 --dart-define 覆盖）
// ══════════════════════════════════════════════════════════════════════

/// 目标 provider —— **必须由 `--dart-define=N1_PROVIDER=…` 传进来**
///
/// ★ 这里**不写死站名/站代号**：本仓有一条"产品代码与文档里不许出现具体视频网站名"
///   的门禁（`test/t98_no_site_names_test.dart`），探针也算产品代码。
///   ⇒ 目标站由调用方在命令行给，本文件保持中立。
const kProvider = String.fromEnvironment('N1_PROVIDER');

/// 目标作品 id —— 同样由 `--dart-define=N1_ID=…` 传（形如 `<provider>:<数字>`）
const kMediaId = String.fromEnvironment('N1_ID');

/// 播放窗口秒数（起播 → 记 W1）
const kWarmupSec = int.fromEnvironment('N1_WARMUP', defaultValue: 25);

/// seek 目标（秒）。取 300s：远大于任何缓存窗口 ⇒ 必然新发 range 请求
const kSeekTargetSec = int.fromEnvironment('N1_SEEK', defaultValue: 300);

/// seek 后观察窗口秒数
const kAfterSeekSec = int.fromEnvironment('N1_AFTER', defaultValue: 15);

// ══════════════════════════════════════════════════════════════════════
//  帧仪器（与 shell.dart `_installFrameLogger` 同款语义，但**按窗口切片**）
// ══════════════════════════════════════════════════════════════════════

class _FrameBook {
  final List<FrameTiming> all = <FrameTiming>[];
  final StringBuffer out = StringBuffer();
  File? file;

  void add(List<FrameTiming> ts) => all.addAll(ts);

  static int pct(List<int> xs, double p) {
    if (xs.isEmpty) return -1;
    final s = [...xs]..sort();
    final i = ((s.length - 1) * p).round();
    return s[i];
  }

  /// 统计 `[from, to)` 这段帧
  void window(String tag, int from, int to) {
    final seg = to <= all.length ? all.sublist(from, to) : all.sublist(from);
    final builds = [for (final f in seg) f.buildDuration.inMicroseconds];
    final rasters = [for (final f in seg) f.rasterDuration.inMicroseconds];
    final overB = builds.where((x) => x > 16700).length;
    final overR = rasters.where((x) => x > 16700).length;
    final line = '── $tag  frames=${seg.length}  '
        'build p50=${pct(builds, .5)}us p95=${pct(builds, .95)}us '
        '超预算=$overB  |  '
        'raster p50=${pct(rasters, .5)}us p95=${pct(rasters, .95)}us '
        'max=${rasters.isEmpty ? -1 : rasters.reduce((a, b) => a > b ? a : b)}us '
        '超预算=$overR'
        '${seg.isEmpty ? "  ⚠️ n=0（不许读成「不卡」）" : ""}';
    debugPrint('[N1] $line');
    out.writeln(line);
  }

  /// 等到批次不再增长（光栅线程迟到批次）再切片
  Future<void> drain() async {
    var last = -1;
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (all.length == last) return;
      last = all.length;
    }
  }

  void flush() {
    final f = file;
    if (f == null) return;
    try {
      f.writeAsStringSync(out.toString(), mode: FileMode.write);
    } catch (_) {}
  }
}

Future<String> _resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isNotEmpty) {
    final d = Directory(override);
    if (!await d.exists()) await d.create(recursive: true);
    return d.path;
  }
  final appdata = Platform.environment['APPDATA'] ??
      Platform.environment['HOME'] ??
      '.';
  return '$appdata${Platform.pathSeparator}app.sourin.player';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  if (kProvider.isEmpty || kMediaId.isEmpty) {
    debugPrint('[N1] ✗ 拒绝启动：缺 --dart-define=N1_PROVIDER=… / N1_ID=…');
    exit(4);
  }

  final dir = await _resolveDataDir();
  await UiPrefs.load(dir);
  await SourinCore.startAsync(dir);
  debugPrint('[N1] 数据目录=$dir  核心版本=${SourinApi.version}');

  final book = _FrameBook();
  try {
    book.file = File('.probe/n1-probe-readout.txt');
    book.file!.writeAsStringSync('');
  } catch (e) {
    debugPrint('[N1] ⚠️ 读数落盘失败（仍然是仪器缺陷，不许当"没卡"）: $e');
  }
  SchedulerBinding.instance.addTimingsCallback(book.add);

  // ── 取真实剧集表（走生产 API，不 mock）
  MediaDetail detail;
  try {
    detail = await SourinApi.getDetail(kProvider, kMediaId);
  } catch (e) {
    debugPrint('[N1] ✗ getDetail 失败: $e');
    exit(2);
  }
  debugPrint('[N1] detail: "${detail.title}" 集数=${detail.episodes.length}');
  if (detail.episodes.isEmpty) {
    debugPrint('[N1] ✗ 没有剧集 ⇒ 无法起播（不许拿空读数当结论）');
    exit(3);
  }

  runApp(MaterialApp(
    home: PlayerPage(
      provider: kProvider,
      id: kMediaId,
      title: detail.title,
      cover: detail.cover,
      episodes: detail.episodes,
      episodeIndex: 0,
    ),
  ));

  // ── 时间线
  final mark0 = book.all.length;
  debugPrint('[N1] W0 开始（预热 ${kWarmupSec}s，mark=$mark0）');

  await Future<void>.delayed(const Duration(seconds: kWarmupSec));
  await book.drain();
  final mark1 = book.all.length;
  book.window('W1 起播后稳态（frames[$mark0,$mark1)）', mark0, mark1);

  // ── seek：走生产钩子（= `_player.seek`）
  final tSeek = DateTime.now();
  final okSeek = debugPlayerSeekForProbe(const Duration(seconds: kSeekTargetSec));
  debugPrint('[N1] seek → ${kSeekTargetSec}s  发送=${okSeek ? "OK" : "FAILED"}  @${tSeek.toIso8601String().substring(11, 23)}');
  book.out.writeln('seek target=${kSeekTargetSec}s sent=$okSeek at=${tSeek.toIso8601String()}');

  await Future<void>.delayed(const Duration(seconds: kAfterSeekSec));
  await book.drain();
  final mark2 = book.all.length;
  book.window('W2 seek 后 ${kAfterSeekSec}s（frames[$mark1,$mark2)）', mark1, mark2);

  book.window('W0+W1+W2 全窗口', 0, mark2);
  book.out.writeln('total_frames=${book.all.length}');
  book.flush();
  debugPrint('[N1] 读数已落盘 .probe/n1-probe-readout.txt（total=${book.all.length}）');
  debugPrint('[N1] DONE');
  exit(0);
}
