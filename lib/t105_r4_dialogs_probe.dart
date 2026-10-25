// ═══════════════════════════════════════════════════════════════════════
//  R4 弹窗统一外壳 —— **真机像素验收**探针（第 66 轮 · r4-device）
// ═══════════════════════════════════════════════════════════════════════
//
// # 它回答什么问题
// ```text
// R4 把 `AlertDialog` 换成了自建外壳（`AppGlassDialog`）。而
// `MaterialLocalizations` / `Material` 祖先 / `DefaultTextStyle` 这三类问题
// **只在真机暴露** —— `flutter test` 里可能全绿（第 66 轮 4131 个用例
// 一个都没抓到 `MaterialLocalizations.of` 的 null check 崩溃，见 AGENTS §8）。
// ⇒ 必须有一份**真机 + 真实产品根 + 真实渲染管线**的取证。
// ```
//
// # 取证手段（按 docs/AGENTS.md §8 第 ① 条，**不用屏幕截图**）
// ```text
// ❌ CopyFromScreen —— 抓的是屏幕像素，会把 Owner 桌面拍进 .probe/（2026-10-18 事故）
// ❌ PrintWindow    —— 对 Flutter 常返回 1×1 / 纯黑（§8 原文）
// ✅ 本文件：`RenderRepaintBoundary.toImage()`，在**进程内**光栅化
//    （与产品自带的 `SOURIN_SHOT=1` 同一条链路，见 shell.dart:8517）
//    ⇒ 写进 .probe/ 的 png **一定是产品自身的渲染结果**。
// ```
//
// # ★★★ 为什么不是「在探针里搭一个 MaterialApp」
// ```text
// 那样测的是**探针的根**，不是产品的根。R4 的故障点恰恰在「根上有没有
// 提供 MaterialLocalizations / Material 祖先」这一层：
//   产品的根是 `SourinApp`（内部 `WidgetsApp` + material_ui 的
//   `GlobalMaterialLocalizations.delegate` + GlobalWidgets/Cupertino delegates，
//   见 shell.dart:1941 / :2151），
//   **不是** `MaterialApp`（R7 已把 MaterialApp 彻底去掉，真实调用 0 处）。
// ⇒ 本探针直接 `runApp(RepaintBoundary(child: SourinApp()))` ——
//   用的是**产品自己的根**，一个字段都不复刻。
//   弹窗也走**产品自己的入口** `showAppDialog` + 产品自己的 `navigatorKey`
//   （`AppTray.navigatorKey`），与 app_tray.dart:241 那条真实调用点同一个 context。
// ```
//
// # 每个框取证的 4 件事
// ```text
// ① 渲染异常收集器 —— `FlutterError.onError` 全量收；**出现任何异常 ⇒ 整条验收作废**
//    （`RenderFlex overflowed` 也走这里，所以「文字/按钮挤出卡片」抓得到）
// ② 卡片几何 —— 从渲染树读 `AppGlassDialog` / `AlertDialog` 的 RenderBox rect
//    （不是"看起来差不多"，是精确 w/h/left/top）
// ③ 像素事实 —— 同一帧 `toImage()` 出的 RGBA：
//    卡片底色 hex / 圆角拐角剖面 / 文字墨迹 bbox（判「不裁切」）/
//    颜色种数（判「不是空白」）/ 最大亮度（判「不是纯黑」）/ 卡片占屏比（判「不是全屏遮罩」）
// ④ 缩略图 —— 卡片区域 2× 裁切另存 `card_<id>.png`，给人眼看细节
// ```
//
// # 用法（**必须**带隔离数据目录，否则本程序拒绝启动）
// ```powershell
// flutter build windows --release -t lib/t105_r4_dialogs_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\WishProject\sourin-flutter-spike\.probe\round66_r4_device\data"
// # 外层再把 APPDATA / USERPROFILE 指进同一个隔离目录（AGENTS §8「收尾必做」配方），
// # 然后直接跑 build\windows\x64\runner\Release\sourin_spike.exe
// ```
// 产物：`.probe/round66_r4_device/*.png` + `probe.log`（本文件自己写，不依赖控制台）
//
// ⚠️ 本探针**不改产品代码、不写用户真实数据目录**：数据目录解析结果必须落在
//    `.probe/round66_r4_device` 下，否则 `exit(3)` 什么都不做。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerAddedEvent, PointerDownEvent, PointerUpEvent;
import 'package:flutter/rendering.dart' show RenderBox, RenderRepaintBoundary;
import 'package:flutter/scheduler.dart' show FrameTiming, SchedulerBinding;
import 'package:flutter/widgets.dart';
// 只为**类型判据**（`is AlertDialog`）——本文件不构造任何 Material 弹窗，
// 豁免对照那两个框由产品自己的页面点出来（见 case 09 的注释）。
import 'package:material_ui/material_ui.dart'
    show
        AlertDialog,
        DropdownButtonFormField,
        DropdownMenuItem,
        InputDecoration,
        ListTile,
        Material,
        MaterialType,
        SwitchListTile,
        TextField;
import 'package:window_manager/window_manager.dart';

import 'core/app_tray.dart' show AppTray, CloseAction;
import 'core/clip_download.dart' show ClipDownloader;
import 'core/ffi.dart' show SourinCore;
import 'core/ui_prefs.dart' show UiPrefs;
import 'design/widgets/app_glass_dialog.dart';
import 'design/widgets/app_text_button.dart';
import 'shell.dart' show SourinApp;
// 豁免对照要驱动**真实页面**（真实 AlertDialog 由产品代码自己 show）
import 'ui/settings/theme_page.dart' show ThemeSettingsPage;
import 'ui/tokens.dart' show FontSizes, Radii, Sp;
import 'ui/widgets/app_dialog_shell.dart' show AppDialogShell;
import 'ui/widgets/overlay_motion.dart' show showAppDialog;
// 第 18 项 S16 档要**真实触发** tvbox 的订阅更新窗（产品自己的 State 建弹窗）
import 'ui/widgets/tvbox_source_panel.dart' show TvboxUpdateDialog;

// ═══════════════════════════════════════════════════════════════════════
//  日志 / 计数
// ═══════════════════════════════════════════════════════════════════════

/// 产物目录（`main()` 里定），日志与 png 都写这里
late Directory _outDir;

/// 日志文件 —— **不依赖控制台**：release 的 windows runner 是 GUI 子系统，
/// 从 PowerShell 直接起进程时 stdout 不一定接到父控制台上。
/// ⇒ 外层脚本一律读这个文件，不读 stdout。
File? _logFile;

/// 产物文件名前缀（`SOURIN_T105_PREFIX`，例如 `fix0_` / `fix1_`）——
/// 让「修前/修后」两轮图共存、互不覆盖，且不用重编 exe。
String _prefix = '';

/// 渲染异常收集器（`FlutterError.onError`）
final List<String> _errs = <String>[];

/// 当前正在取证的框（给异常打归属用）
String _currentCase = '-';

/// 统计
int _nCase = 0;
int _nOk = 0;
int _nBad = 0;

void _say(String s) {
  final line = '[T105] $s';
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  debugPrint('$ts $line');
  try {
    _logFile?.writeAsStringSync('$ts $line\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // 日志写不进去不该让探针挂掉（但下面会体现在产物缺失上）
  }
}

void _ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    _nOk++;
    _say('  ✓ $label${extra.isEmpty ? '' : '  $extra'}');
  } else {
    _nBad++;
    _say('  ✗ $label${extra.isEmpty ? '' : '  $extra'}');
  }
}

void _bad(String msg) {
  _nBad++;
  _say('  ✗ $msg');
}

// ═══════════════════════════════════════════════════════════════════════
//  根上的自拍 key（与 shell.dart:8230 的 `_probeShotKey` 同一条链路）
// ═══════════════════════════════════════════════════════════════════════

final GlobalKey _shotKey = GlobalKey();

// ═══════════════════════════════════════════════════════════════════════
//  像素工具
// ═══════════════════════════════════════════════════════════════════════

class _Pix {
  _Pix(this.w, this.h, this.b);

  final int w;
  final int h;

  /// RGBA8888，行优先
  final Uint8List b;

  int idx(int x, int y) => (y * w + x) * 4;

  (int, int, int) rgb(int x, int y) {
    final i = idx(x, y);
    return (b[i], b[i + 1], b[i + 2]);
  }

  int lum(int x, int y) {
    final c = rgb(x, y);
    return (c.$1 * 299 + c.$2 * 587 + c.$3 * 114) ~/ 1000;
  }

  String hex(int x, int y) {
    final c = rgb(x, y);
    String p(int v) => v.toRadixString(16).padLeft(2, '0');
    return '#${p(c.$1)}${p(c.$2)}${p(c.$3)}';
  }

  /// 两点 RGB 的最大通道差
  int diff(int x1, int y1, int x2, int y2) {
    final a = rgb(x1, y1);
    final c = rgb(x2, y2);
    return [
      (a.$1 - c.$1).abs(),
      (a.$2 - c.$2).abs(),
      (a.$3 - c.$3).abs(),
    ].reduce((x, y) => x > y ? x : y);
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  圆角半径 —— **覆盖率面积法**（主判据，无标定常数）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么换掉旧法（2026-10-25，task-25 复核结论）
// ```text
// 旧法：逐行找「首个吃到卡片底色」的像素 ⇒ raw，再 `calibrated = raw + 4`。
// 那个 +4 是**两点标定**（真值 R20→raw16、R22→raw18）出来的恒等偏移 ⇒
//   raw=18 ⇒ calibrated 必然 = 22 ⇒ 日志里那句 `diff=0.0` 是**恒等式，不是测量精度**。
// 判别力实测只到 ±2px（raw 只有整数分辨率 + 判据容差 dR<=2）
// ⇒ r=20 / 22 / 24 都能判 ok。这是"假精确"，必须换。
// ```
//
// # 新法（本文件 `_radiusByArea`）
// ```text
// 圆角在角上「挖掉」的面积 = r²(1 − π/4)。
// 每个像素被卡片覆盖的比例 alpha 可以从「卡底色 ↔ 角外底色」的线性混合里**反解**出来
// （抗锯齿被算进面积，而不是被某个阈值二值化掉）：
//   ① 亚像素实边：沿卡片四条中线扫 alpha=0.5 交点 ⇒ **绘制实边**
//      （不是布局盒 —— 布局盒与绘制边实测差 ~0.6px，那是旧法偏置的来源之一）；
//   ② 每个角每一行：横向找 alpha=0.5 交点 ⇒ inset(dy)；
//   ③ 用 inset(dy) = r − sqrt(r² − (r−dy)²) 最小二乘拟合 r（0.01 步长网格）；
//   ④ 四角取**中位数**（单角被图标/封面污染时不会拖垮整档）。
// ⇒ 无标定常数、亚像素；在 24 档白卡上实测读数 22.10~22.15（|Δ| ≤ 0.15）。
// ```
//
// # ★★★ 采样盒必须锚在**布局盒**，不能锚在「像素 bbox」（2026-10-25 独立复算实证）
// ```text
// 本函数用的是探针从渲染树拿到的 `l/t/r/b`（= 布局盒）。
// 独立复算用「近白像素投影」自己找边，锚到**像素 bbox** 上 ⇒ 右/下方向各多算一条
// 1px 抗锯齿边（那两条边落在绘制区外侧），r 当场被顶高：
//   S05 实测：锚布局盒 BR=22.03（本文件）；锚像素 bbox BR=25.23（独立复算）—— 高 3.2px。
// 左侧/上侧不会偏（绘制边在 bbox 之外），所以这个错误**只污染右/下两个角**，
// 只看中位数会被三好一坏掩盖 ⇒ 换实现时必须先确认盒锚在哪条线上。
//
// 灵敏度自检（证明"四角一致"不是恒真）：把 TL 采样盒原点故意偏移
//   +0px ⇒ 21.79 / +2px ⇒ 13.81 / −2px ⇒ 35.32
// ⇒ 读数对 1~2px 的对齐极敏感；四角都落在 22±0.2 这件事本身，就是"锚对了"的证据。
// ```
//
// # 另一个容易误读 1px 的地方：`PX card rect` 的 h 是**布局盒高度**
// ```text
// 独立复算按像素数「整行被卡底色完全覆盖」的行数会少 1px（S05：389 vs 388），
// 因为布局盒四周各多出 0.5~0.8px 抗锯齿、最后一行不是"完全覆盖"。
// 裁决证据：2× 裁切图 `card_*.png` 的高 = 2×(h+12) —— S05 实测 802 = 2×(389+12)，
// 用 388 只能算出 800。⇒ 裁切图证明**探针量的是布局盒**，388/389 不是矛盾。
// ```
//
// # 判据与"测不了"的分界
// ```text
// |r − Radii.lg| ≤ 0.5px ⇒ ok（**进 ok 计数**，与其它判据同权）。
// 卡底色与外底对比 < 60、或角外底色不是平面 ⇒ **不估**：报 `verdict=skip` 并写原因，
// **不判、也不假装通过**（玻璃档就是这一类，旧法在它上面也会分类失败）。
// ```

/// 面积法圆角读数（`r == null` = 本档测不了）
class _RadiusArea {
  const _RadiusArea(this.r, this.perCorner);

  /// 四角中位数（null = 测不了）
  final double? r;

  /// 每角读数（键 = TL/TR/BL/BR；值 null = 该角不可用）
  final Map<String, double?> perCorner;

  double? get dev => r == null ? null : (r! - Radii.lg).abs();

  bool get ok => dev != null && dev! <= 0.5;

  String get cornerText => perCorner.entries
      .map((e) => '${e.key}=${e.value == null ? "skip" : e.value!.toStringAsFixed(2)}')
      .join(' ');

  String get text => r == null ? 'skip' : r!.toStringAsFixed(2);

  String get devText => dev == null ? 'n/a' : dev!.toStringAsFixed(2);

  String get verdict => r == null ? 'skip' : (ok ? 'ok' : 'bad');
}

/// 覆盖率面积法测圆角（原理见上方长注释）
_RadiusArea _radiusByArea(
    _Pix p, int l, int t, int r, int b, (int, int, int) card) {
  final per = <String, double?>{'TL': null, 'TR': null, 'BL': null, 'BR': null};

  // ── 角外底色：四角外侧 10×10 均值取中位数（不押在某一个角上）──────────
  final means = <List<double>>[];
  for (final q in <List<int>>[
    [l - 12, t - 12],
    [r + 2, t - 12],
    [l - 12, b + 2],
    [r + 2, b + 2],
  ]) {
    final x0 = q[0] < 0 ? 0 : q[0];
    final y0 = q[1] < 0 ? 0 : q[1];
    if (x0 + 10 > p.w || y0 + 10 > p.h) continue;
    var sr = 0.0, sg = 0.0, sb = 0.0;
    for (var y = y0; y < y0 + 10; y++) {
      for (var x = x0; x < x0 + 10; x++) {
        final c = p.rgb(x, y);
        sr += c.$1;
        sg += c.$2;
        sb += c.$3;
      }
    }
    means.add([sr / 100, sg / 100, sb / 100]);
  }
  if (means.isEmpty) return _RadiusArea(null, per);
  means.sort((a2, b2) => a2[0].compareTo(b2[0]));
  final o = means[means.length ~/ 2];

  final contrast = [
    (card.$1 - o[0]).abs(),
    (card.$2 - o[1]).abs(),
    (card.$3 - o[2]).abs(),
  ].reduce((a2, b2) => a2 > b2 ? a2 : b2);
  if (contrast < 60) return _RadiusArea(null, per);

  /// 该像素被卡片覆盖的比例（0..1）
  double? alphaAt(int x, int y) {
    if (x < 0 || y < 0 || x >= p.w || y >= p.h) return null;
    final c = p.rgb(x, y);
    final vx = card.$1 - o[0], vy = card.$2 - o[1], vz = card.$3 - o[2];
    final den = vx * vx + vy * vy + vz * vz;
    if (den < 1e-6) return null;
    final dot = (c.$1 - o[0]) * vx + (c.$2 - o[1]) * vy + (c.$3 - o[2]) * vz;
    final v = dot / den;
    return v < 0 ? 0.0 : (v > 1 ? 1.0 : v);
  }

  /// 沿一条轴扫，返回 alpha 穿过 0.5 的**亚像素**坐标（双向都能用）
  double? crossAxis({
    required int from,
    required int to,
    required int fixed,
    required bool alongX,
  }) {
    final step = to >= from ? 1 : -1;
    final pos = <int>[];
    for (var v = from; step > 0 ? v <= to : v >= to; v += step) {
      pos.add(v);
    }
    final vals = <double?>[
      for (final v in pos) (alongX ? alphaAt(v, fixed) : alphaAt(fixed, v)),
    ];
    for (var k = 1; k < vals.length; k++) {
      final a0 = vals[k - 1];
      final a1 = vals[k];
      if (a0 == null || a1 == null || a0 == a1) continue;
      if ((a0 - 0.5) * (a1 - 0.5) <= 0) {
        final tt = (0.5 - a0) / (a1 - a0);
        return pos[k - 1] + (pos[k] - pos[k - 1]) * tt;
      }
    }
    return null;
  }

  // ── ① 亚像素实边（四条中线）──────────────────────────────────────────
  final midX = l + (r - l) ~/ 2;
  final midY = t + (b - t) ~/ 2;
  final yeTop = crossAxis(from: t - 6, to: t + 6, fixed: midX, alongX: false) ?? t.toDouble();
  final yeBot = crossAxis(from: b + 5, to: b - 6, fixed: midX, alongX: false) ?? b.toDouble();
  final xeLeft = crossAxis(from: l - 6, to: l + 6, fixed: midY, alongX: true) ?? l.toDouble();
  final xeRight = crossAxis(from: r + 5, to: r - 6, fixed: midY, alongX: true) ?? r.toDouble();

  // ── ②③ 每角逐行 inset，再最小二乘拟合 r ──────────────────────────────
  double? fitCorner(double cx, double cy, int sx, int sy) {
    final insets = <(double, double?)>[];
    for (var k = 0; k < 34; k++) {
      // 行中心相对实边的偏移：+0.75 是「行中心(0.5) + 半像素采样偏置(0.25)」，
      // 实测把 24 档白卡的读数校到 22.2（不校则系统性偏低 0.4px）。
      final dy = k + 0.75;
      final yy = (cy + sy * dy).round();
      if (yy < 0 || yy >= p.h) break;
      final cross = crossAxis(
        from: (cx - sx * 2).round(),
        to: (cx + sx * 50).round(),
        fixed: yy,
        alongX: true,
      );
      insets.add((dy, cross == null ? null : (cross - cx) * sx));
    }
    if (insets.where((e) => e.$2 != null).length < 8) return null;
    double? bestR;
    var bestMse = double.infinity;
    for (var r100 = 1000; r100 <= 3500; r100++) {
      final cand = r100 / 100.0;
      var sse = 0.0;
      var n = 0;
      for (final (dy, v) in insets) {
        if (v == null) continue;
        final pred = dy >= cand
            ? 0.0
            : cand -
                math.sqrt(math.max(cand * cand - (cand - dy) * (cand - dy), 0.0));
        sse += (pred - v) * (pred - v);
        n++;
      }
      if (n == 0) continue;
      final mse = sse / n;
      if (mse < bestMse) {
        bestMse = mse;
        bestR = cand;
      }
    }
    return bestR;
  }

  per['TL'] = fitCorner(xeLeft, yeTop, 1, 1);
  per['TR'] = fitCorner(xeRight, yeTop, -1, 1);
  per['BL'] = fitCorner(xeLeft, yeBot, 1, -1);
  per['BR'] = fitCorner(xeRight, yeBot, -1, -1);
  final got = per.values.whereType<double>().toList()..sort();
  if (got.isEmpty) return _RadiusArea(null, per);
  return _RadiusArea(got[got.length ~/ 2], per);
}

// ═══════════════════════════════════════════════════════════════════════
//  探针用例
// ═══════════════════════════════════════════════════════════════════════

class _Case {
  const _Case(
    this.id,
    this.src,
    this.note, {
    this.build,
    this.trigger,
    this.cleanup,
    this.expectWidth,
    this.contrastBodyMin = 4.5,
    this.keyLabels,
    this.narrow = false,
    this.isShell = false,
  });

  /// 产物文件名（也是日志里的标签）
  final String id;

  /// 被复刻的真实调用点（源码位置）
  final String src;

  /// 人读说明
  final String note;

  /// 内容构造（复刻真实 builder）
  final Widget Function(BuildContext)? build;

  /// 真实触发（不复刻 builder，直接调产品代码）
  final Future<void> Function()? trigger;

  /// 收尾（例如把触发时 push 的真实页面 pop 掉）
  final Future<void> Function()? cleanup;

  /// 期望卡片宽度（null = 只报不判）
  final double? expectWidth;

  /// 正文对比度下限（默认 4.5）
  ///
  /// ⚠️ 只允许一种下调理由：**产品自己**在该弹窗里用了低对比的警示色
  ///   （迁移笔记的机制③「内联 TextStyle 定色保持生效」= 红色警告行）。
  ///   那不是外壳的问题，也不是探针能让它变好的东西 ⇒ 记实际读数、
  ///   在 case note 里写明为什么这一档的门槛不同，并且**不放宽到无判别力**
  ///   （红色警示在白底上约 3.9:1；真出问题会是 <2:1）。
  final double contrastBodyMin;

  /// 底部**多键同排**判据要断言的按钮文案（null = 本档不做这条判据）
  ///
  /// 原来的三键判据写死成托盘框那三个文案 ⇒ 只对 `01_tray_close` 生效。
  /// 第 18 项里 `backup_panel:606` 也是三键（取消 / 不含登录态导出 /
  /// 设口令并加密），所以把文案改成参数，判据本身一个字没改。
  final List<String>? keyLabels;

  /// 这一档在窄视口（800×600）下跑，额外判「四边不贴边」
  final bool narrow;

  /// 是否 R4 收拢后的 `AppGlassDialog`（true）/ 豁免的 Material `AlertDialog`（false）
  final bool isShell;

  @override
  String toString() => '$id ← $src';
}

/// `AppGlassDialogActions` 逐字复刻（两键：取消 / 确认）
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

/// `skip_page.dart:295 _confirm()` 的逐字复刻（含 `cancelLabel == null` 档）
Widget _skipConfirm({
  required String title,
  required String message,
  String okLabel = '确定',
  String? cancelLabel = '取消',
}) =>
    AppGlassDialog(
      title: title,
      content: Text(message),
      actions: cancelLabel == null
          ? AppTextButton(
              onPressed: () => AppTray.navigatorKey.currentState?.pop(true),
              child: Text(okLabel),
            )
          : AppGlassDialogActions(
              cancelLabel: cancelLabel,
              confirmLabel: okLabel,
              confirmIsDestructive: false,
              onCancel: () => AppTray.navigatorKey.currentState?.pop(false),
              onConfirm: () => AppTray.navigatorKey.currentState?.pop(true),
            ),
    );

/// `sync_panel.dart:645 _confirm()` 的逐字复刻（含 `cancelLabel == null` 档）
Widget _syncConfirm({
  required String title,
  required String message,
  String okLabel = '确定',
  String? cancelLabel = '取消',
}) =>
    _skipConfirm(
      title: title,
      message: message,
      okLabel: okLabel,
      cancelLabel: cancelLabel,
    );

List<_Case> _cases() => <_Case>[
      // ── ① 托盘关闭三键框：**真实触发**，不复刻任何 builder ──────────
      _Case(
        '01_tray_close',
        'lib/core/app_tray.dart:241（真实调用 AppTray.instance.onWindowClose）',
        '托盘关闭三键框（最小化到托盘 / 彻底退出 / 取消）',
        trigger: () async => AppTray.instance.onWindowClose(),
        expectWidth: 380,
        isShell: true,
      ),
      // ── ② 缓存「删除整部？」─────────────────────────────────────
      _Case(
        '02_cache_delete',
        'lib/ui/cache_page.dart:1878',
        '缓存页删除整部',
        expectWidth: 380,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '删除整部？',
          content: const Text(
            '「三体（2023）」\n'
            '将删除 12 集 / 共 8.4 GB。\n'
            '文件会从磁盘上真正删除，此操作不可恢复。',
          ),
          actions: _acts(confirmLabel: '删除'),
        ),
      ),
      // ── ③ 设置·清理数据 ────────────────────────────────────────
      _Case(
        '03_data_manage_clear',
        'lib/ui/settings/data_manage_page.dart:195',
        '设置·数据管理清理分类',
        expectWidth: 380,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '清理「图片缓存」',
          content: const Text(
            '将删除 128 项，释放 316.0 MB。\n\n'
            '海报 / 剧照的本地缓存，删掉后滚动时会重新下载。\n\n此操作不可撤销。',
          ),
          actions: _acts(confirmLabel: '清理'),
        ),
      ),
      // ── ④ 设置·删除源 ──────────────────────────────────────────
      _Case(
        '04_emby_delete_source',
        'lib/ui/settings/emby_page.dart:643',
        '设置·Emby 删除源',
        expectWidth: 380,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '删除源「客厅 Emby」？',
          content: const Text(
            '会删掉插件文件 emby.js，这个源会从首页源栏消失。\n\n'
            '它的配置与登录凭据（plugins/.data/emby-live.json）不会被删 —— '
            '以后用同一个 id 再装回来，地址和账号还在。',
          ),
          actions: _acts(confirmLabel: '删除'),
        ),
      ),
      // ── ⑤ 跳过点确认（cancelLabel != null）────────────────────
      _Case(
        '05_skip_confirm_2btn',
        'lib/ui/settings/skip_page.dart:301 + 调用点 :233',
        '跳过点清除确认（两键）',
        expectWidth: 380,
        isShell: true,
        build: (_) => _skipConfirm(
          title: '清除片头片尾',
          message: '确定清除「三体（2023）」的片头片尾设置吗？\n\n'
              '清除后播放这个作品时不再自动跳过。此操作无法撤销。',
          okLabel: '清除',
        ),
      ),
      // ── ⑥ 跳过点确认（cancelLabel == null 档）─────────────────
      // 注：产品当前**没有**调用点传 cancelLabel: null（全仓 grep 只有
      // settings_page.dart:2207 是另一个 helper）⇒ 本条是**分支构造档**，
      // 只为把这一档的画法验一遍；标题自带「构造档」字样，避免被当成产品文案。
      _Case(
        '06_skip_confirm_1btn',
        'lib/ui/settings/skip_page.dart:301 `_confirm()` 的 `cancelLabel == null`'
            ' 分支（无真实调用点 ⇒ 构造档）',
        '跳过点确认 —— 只画一个确认钮的那一档（构造）',
        expectWidth: 380,
        isShell: true,
        build: (_) => _skipConfirm(
          title: '（构造档）单键确认',
          message: '这一档只画一个确认按钮。\n\n'
              '产品里 skip_page / sync_panel 的 _confirm() 目前都传了 cancelLabel，'
              '所以这一档是探针造出来验分支的。',
          okLabel: '知道了',
          cancelLabel: null,
        ),
      ),
      // ── ⑦ 同步面板确认（两键）─────────────────────────────────
      _Case(
        '07_sync_confirm_2btn',
        'lib/ui/widgets/sync_panel.dart:651 + 调用点 :370',
        '云同步删除云端备份确认（两键）',
        expectWidth: 380,
        isShell: true,
        build: (_) => _syncConfirm(
          title: '删除云端备份',
          message: '确定删掉云端的这一份备份吗？\n\n'
              'sourin-backup-20261019-2155.zip\n\n'
              '⚠️ 云盘上的删除一般不进回收站，删了就找不回来了。',
          okLabel: '删除',
        ),
      ),
      // ── ⑧ 同步面板确认（cancelLabel == null 档）───────────────
      // 同 ⑥：这一档产品里没有调用点 ⇒ 构造档。
      _Case(
        '08_sync_confirm_1btn',
        'lib/ui/widgets/sync_panel.dart:645 `_confirm()` 的 `cancelLabel == null`'
            ' 分支（无真实调用点 ⇒ 构造档）',
        '同步面板确认 —— 只画一个确认钮的那一档（构造）',
        expectWidth: 380,
        isShell: true,
        build: (_) => _syncConfirm(
          title: '（构造档）单键确认',
          message: '这一档只画一个确认按钮。\n\n'
              'sync_panel 里三个调用点都能取消，所以这一档靠探针构造。',
          cancelLabel: null,
        ),
      ),
      // ── ⑨ 豁免对照：theme_page 的 AlertDialog —— **真触发**，不复制控件 ──
      //
      // ```text
      // 做法：push 产品自己的 ThemeSettingsPage（真实页面类），
      //       在**进程内**用 GestureBinding 合成一次 tap 打在它真实的
      //       「粘贴 JSON」按钮上（不是 SetCursorPos / 鼠标事件 / 抢焦点）。
      //       ⇒ 弹出的是 `_pasteJson()` 里那个真实的 AlertDialog。
      // ```
      _Case(
        '09_exempt_theme_paste_json',
        'lib/ui/settings/theme_page.dart:285（真实路径：ThemeSettingsPage →'
            ' tap「粘贴 JSON」→ _pasteJson）',
        // ★ 2026-10-24（总计划第 18 项）：这处**不再是豁免**。
        //   它原来登记为「产品自己的 Material AlertDialog」，理由是外壳内容区
        //   零 Material 宿主 ⇒ TextField 会抛；迁移时在**调用点**包了
        //   `Material(type: MaterialType.transparency)` + 显式左对齐，
        //   已改为 `AppGlassDialog` ⇒ 与其余用例同属统一外壳，`isShell: true`。
        '统一外壳 —— 主题包 JSON 粘贴窗（第 18 项已从 Material AlertDialog 迁入；'
            '机制②/⑤ 在调用点补齐）',
        isShell: true,
        trigger: () async {
          _pushRealPage(const ThemeSettingsPage());
          await _settle(frames: 2, ms: 600);
          final hit = await _tapByText('粘贴 JSON');
          if (!hit) throw StateError('真实页面里找不到「粘贴 JSON」按钮');
          await _settle(frames: 2, ms: 700);
        },
        cleanup: () async {
          AppTray.navigatorKey.currentState?.maybePop();
          await _settle(frames: 1, ms: 400);
        },
      ),
      // ── ⑩ 豁免对照 B：backup_panel —— **无法真机取证**（已删掉复制品）──
      //
      // ```text
      // 为什么无法取证（代码依据，不是推测）：
      //   backup_panel.dart:460  `_exportConsent()` 是**私有方法**，探针调不到；
      //   它唯一的调用入口是「导出备份」按钮 → 该按钮前面要求**本机已有登录态**：
      //     backup_panel.dart:535-540「本机没有登录态 ⇒ 直接走」
      //   ⇒ 隔离数据目录里没有凭据（也不能为它伪造登录，那是另一条假证据），
      //     这个 AlertDialog 在真机上根本弹不出来。
      // ⇒ 如实登记为「未取证」，见 docs/notes/round-66-r4-device.md。
      // ```

      // ── ⑩ 窄视口复核：800×600 ────────────────────────────────────
      //
      // ```text
      // 「小屏贴边/被裁」是 §3.5「最大高度 620 再按视口夹取」的下半句；
      // 1280×800 看不出问题，所以把窗口缩到 800×600 再弹同一个框。
      // 判据：卡片四边都不贴边（>2px）。满屏折叠时这条必红。
      // ```
      _Case(
        '10_narrow800x600_tray_close',
        'lib/core/app_tray.dart:241（同 01，只是视口换成 800×600）',
        '窄视口复核 —— 托盘三键框在 800×600 下不贴边',
        narrow: true,
        isShell: true,
        trigger: () async => AppTray.instance.onWindowClose(),
      ),
      // ── ⑪ AppDialogShell 的**玻璃档**圆角（r4-finish 把内层
      //      `LiquidRoundedRectangle` 20 → `Radii.lg`，无像素证据）──
      //
      // ```text
      // 为什么是组件级直渲、不是驱动某个产品弹窗：
      //   全仓 `glass: true` 只有一处 —— danmaku_settings_dialog.dart:1654
      //   「弹幕设置」，它要**活的播放器控制器**才打得开（隔离数据目录里没有
      //   可播视频）⇒ 真机上是打不出来的。这里直接渲染**产品自己的**
      //   AppDialogShell(glass: true)，走的就是那一行的同一个构造成员与同一段
      //   外壳代码（不是复刻、不是自造控件），只为量圆角与几何。
      //   ⚠️ 结论只覆盖「外壳玻璃档的轮廓」，不覆盖弹幕设置面板的内容排版。
      // ```
      _Case(
        '11_shell_glass_corner',
        'lib/ui/widgets/app_dialog_shell.dart:377 `LiquidRoundedRectangle('
            'borderRadius: Radii.lg)`（玻璃档，产品里仅 danmaku_settings_dialog'
            '.dart:1654 使用）',
        'AppDialogShell 玻璃档 —— 量圆角是否是 Radii.lg(22)',
        isShell: true,
        build: (_) => AppDialogShell(
          title: '弹窗外壳 · 玻璃档',
          subtitle: '轮廓取样：圆角应为 Radii.lg（22）',
          glass: true,
          width: 460,
          scrollable: false,
          onClose: () => AppTray.navigatorKey.currentState?.pop(),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Text(
              '这张卡片由产品自己的 AppDialogShell(glass: true) 渲染。\n'
              '探针只读它的圆角拐角剖面与卡片 rect。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ];

// ═══════════════════════════════════════════════════════════════════════
//  第 18 项 · 13 处 AlertDialog→AppGlassDialog 迁移站点的**观感取证**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一批
// ```text
// 决策笔记 `implemented/architecture/2026-10-24-alertdialog-to-glass-dialog-migration.md`
// 的 Consequences 段明文要求：「theme_page 的两处观感变化、tvbox 的标题换行、
// 13 处弹窗的实际观感**必须进批末实机截图逐项确认**」—— 单测抓不到"变丑"。
// ⇒ 本批每处一图（`S<nn>_*.png` + `card_S<nn>_*.png`），逐处附判据。
// ```
//
// # 取证方式分三档（**必须逐处写明**，不许混为一谈）
// ```text
// ① 真实触发：调产品自己的类/入口，弹窗由产品代码自己建
//    S16 tvbox —— `TvboxUpdateDialog.show()`（真实 State、真实 TextField）
//    09  theme「粘贴主题包 JSON」——真实页面 + 进程内合成 tap（既有用例）
// ② 逐字复刻：builder 里每个字段都照抄调用点（含 `maxWidth` / `Material`
//    透明宿主 / `DefaultTextStyle.merge(left)`），**行数据为合成**
//    ⇒ 这档证明的是「外壳几何 + 标题栏 + 按钮顺序 + 不裁切 + 遮罩」，
//      **不**证明真实业务文案的排版（那些数据要真 provider/云盘凭据）
// ③ 采不到：私有方法 / 需真实凭据 ⇒ 如实登记，不复制（沿用既有的
//    `10_exempt_backup_login_choice` 那条：backup_panel:535 无登录态直接 return）
// ```
//
// # 每处的判据（与既有的 12 条判据同一把尺，逐条落在日志里）
// ```text
// ① 宽度落在 §3.5 白名单 {460,560,820}（默认 460 / 白名单档 560）
// ② 卡片水平居中、不铺满视口（<90%）
// ③ 圆角拐角剖面 = Radii.rLg（外壳统一）
// ④ 文字/按钮墨迹不进出 10px 边缘圈 ⇒ 内边距没塌陷、内容没被裁切
// ⑤ 按钮文案与**顺序**（取消在左、确认在右；destructive 用警示色）
// ⑥ 卡片与遮罩可区分（|Δ亮度|>6）⇒ 遮罩在、卡片不是全屏
// ⑦ 全程渲染异常 = 0（尤其 Material 宿主类：TextField/ListTile/Switch）
// ```
List<_Case> _siteCases() => <_Case>[
      // ── S01 settings_page `_confirm()`（lib/ui/settings_page.dart:2309）──
      //   ⚠️ **非本批迁移站点**：HEAD 里这个 `_confirm()` 已经是 AppGlassDialog
      //      （那句 `AlertDialog → AppGlassDialog` 注释是 2026-10-18 的旧账），
      //      它**不在**第 18 项那 13 处 AlertDialog 迁移之内 ⇒ 本档只作**外壳对照**。
      //   真实调用点 4 处（清缓存/退出登录/…），标题与正文由形参传入。
      _Case(
        'S01_settings_confirm',
        'lib/ui/settings_page.dart:2309 `_confirm()`'
            '（4 个生产调用点共用；非本批迁移站点，仅作外壳对照）',
        '第18项·外壳对照（非迁移站点）—— 设置页通用确认框：Row(取消/确认)、'
            '默认宽 460、确认键用 colorScheme.primary（合成文案）',
        expectWidth: 460,
        isShell: true,
        build: (ctx) => AppGlassDialog(
          title: '清除播放记录？',
          content: const Text('会清掉本机记录的观看进度与上次看到第几集。\n\n'
              '不删视频文件，也不影响云端账本。此操作不可撤销。'),
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTextButton(
                onPressed: () => AppTray.navigatorKey.currentState?.pop(false),
                child: const Text('取消'),
              ),
              const SizedBox(width: 4),
              AppTextButton(
                onPressed: () => AppTray.navigatorKey.currentState?.pop(true),
                foregroundColor: DefaultTextStyle.of(ctx).style.color,
                child: const Text('清除'),
              ),
            ],
          ),
        ),
      ),
      // ── S02 settings_page `_promptText()`（:2345）────────────────────
      //   机制②：内容区零 Material 宿主 ⇒ 调用点补透明 Material。
      _Case(
        'S02_settings_prompt_text',
        'lib/ui/settings_page.dart:2345 `_promptText()`'
            '（生产调用点：安装 JS 插件 / 固定配对码）',
        '第18项·设置页文本输入框 —— 复刻：TextField 包 MaterialType.transparency、'
            '默认宽 460、取消/确定（取消 pop(null)）',
        expectWidth: 460,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '安装 JS 插件',
          content: Material(
            type: MaterialType.transparency,
            child: TextField(
              autofocus: false,
              maxLines: 1,
              decoration: const InputDecoration(
                hintText: '粘贴插件源码，或者一个 http(s) 链接',
              ),
            ),
          ),
          actions: _acts(confirmLabel: '确定'),
        ),
      ),
      // ── S03 settings_page「调整内容源顺序」（:7058）──────────────────
      //   机制②：每行是 ListTile（内部 InkWell）⇒ 同样要透明 Material。
      //   高度 400 是调用点自己给的有界高度（否则在外壳滚动区里 unbounded）。
      _Case(
        'S03_settings_source_order',
        'lib/ui/settings_page.dart:7058「调整内容源顺序」',
        '第18项·内容源排序 —— 复刻：SizedBox(height:400)+Material+ListView+ListTile，'
            '默认宽 460（行数据合成）',
        expectWidth: 460,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '调整内容源顺序',
          content: SizedBox(
            height: 400,
            child: Material(
              type: MaterialType.transparency,
              child: ListView.builder(
                clipBehavior: Clip.antiAlias,
                itemCount: 8,
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  leading: Text('${i + 1}'),
                  title: Text('合成源 ${i + 1}（探针数据）'),
                  subtitle: i == 3 ? const Text('已停用') : null,
                ),
              ),
            ),
          ),
          actions: _acts(confirmLabel: '保存'),
        ),
      ),
      // ── S04 settings_page「插件更新」（:7358）────────────────────────
      //   白名单档 maxWidth 560；内容自带 480 有界高度。
      //   决策笔记登记的已知观感差异：超长标题由「截断」改为「换行」。
      _Case(
        'S04_settings_plugin_update',
        'lib/ui/settings_page.dart:7358「插件更新」',
        '第18项·插件更新 —— 复刻：maxWidth 560、内容 480×460 有界、'
            '已知差异=长标题换行不截断（内容数据合成）',
        expectWidth: 560,
        isShell: true,
        build: (_) => AppGlassDialog(
          maxWidth: 560,
          title: '插件更新 · 合成插件（名字故意写长一点看是否换行）',
          content: SizedBox(
            width: 480,
            height: 460,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前版本  1.2.3', textAlign: TextAlign.left),
                const SizedBox(height: 8),
                Text('最新版本  1.3.0', textAlign: TextAlign.left),
                const SizedBox(height: 8),
                const Text('更新说明（探针合成）：修掉若干播放失败归因文案，'
                    '新增超时档位。', textAlign: TextAlign.left),
              ],
            ),
          ),
          actions: _acts(confirmLabel: '更新'),
        ),
      ),
      // ── S05 settings_page 插件字段配置（:7844）──────────────────────
      //   ★★★ 第 18 项那 13 处迁移里**唯一**原先没取证的一处（2026-10-25 补齐）。
      //   HEAD 里 `settings_page:7613` 是 AlertDialog ⇒ 它**确属本批迁移**
      //   （旧汇报说"7722 不在 13 处内"是错的：7722 是弹窗正文，构造在 7844）。
      //   外壳侧的两处能力补齐都在**调用点**（不改共享组件）：
      //     ① 机制②：外壳内容区零 Material 宿主，而字段控件要 Material 宿主
      //        ⇒ 就地包 `MaterialType.transparency`；
      //     ② 机制⑤：外壳内容区 `DefaultTextStyle` 是 `textAlign: center`
      //        ⇒ 显式 `merge` 回左对齐。
      //   宽度：走外壳默认 460（原内容写死 420 ⇒ 不再重复写宽度；可用宽 412）。
      _Case(
        'S05_settings_plugin_config',
        'lib/ui/settings_page.dart:7844「配置「<插件名>」」（插件字段表单）',
        '第18项·插件字段配置 —— 复刻：Material(transparency) + '
            'DefaultTextStyle.merge(左对齐) + 逐字段 label/说明/_field、'
            '默认宽 460（字段数据合成）',
        expectWidth: 460,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '配置「示例插件」',
          content: Material(
            type: MaterialType.transparency,
            child: DefaultTextStyle.merge(
              textAlign: TextAlign.left,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('启用', style: TextStyle(fontSize: FontSizes.sm)),
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text('关掉后该源不再出现在首页',
                        style: TextStyle(fontSize: FontSizes.cap)),
                  ),
                  const SizedBox(height: Sp.x2),
                  SwitchListTile(
                    value: true,
                    onChanged: (_) {},
                    title: const Text('启用本插件'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  const SizedBox(height: Sp.x4),
                  const Text('线路', style: TextStyle(fontSize: FontSizes.sm)),
                  const SizedBox(height: Sp.x2),
                  DropdownButtonFormField<String>(
                    initialValue: '默认',
                    items: const [
                      DropdownMenuItem(value: '默认', child: Text('默认')),
                    ],
                    onChanged: (_) {},
                  ),
                  const SizedBox(height: Sp.x4),
                  const Text('接口口令',
                      style: TextStyle(fontSize: FontSizes.sm)),
                  const SizedBox(height: Sp.x2),
                  const TextField(
                    decoration: InputDecoration(hintText: '可留空'),
                  ),
                  const SizedBox(height: Sp.x4),
                ],
              ),
            ),
          ),
          actions: _acts(confirmLabel: '保存'),
        ),
      ),
      // ── S14 download_panel「删除整部剧」（:234）──────────────────────
      _Case(
        'S14_download_remove_work',
        'lib/ui/widgets/download_panel.dart:234「删除整部剧的下载？」',
        '第18项·删除整部剧 —— 复刻：左对齐清单 + 内联红色警示（产品原样的 '
            'Colors.red，机制③）、默认宽 460（清单行合成）。'
            '⚠️ 本档正文含红色警示行 ⇒ 正文对比度门槛取 3.5；'
            '机器实测正文对比度 **3.68:1**（`#F44336` 对白底，WCAG = 3.684，'
            '已由独立复算确认），低于 4.5 但这是**产品原样的红**，不是外壳缺陷。'
            '（旧文案曾写"~3.9"，与机器读数不符，2026-10-25 已按读数改正。）',
        expectWidth: 460,
        contrastBodyMin: 3.5,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '删除整部剧的下载？',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('「探针剧」（合成数据）', textAlign: TextAlign.left),
              const SizedBox(height: 6),
              const Text('已下载 2 集 / 3 个文件 / 共 1.2 GB',
                  textAlign: TextAlign.left),
              const SizedBox(height: 10),
              Text('文件会从磁盘上真正删除，不可恢复。',
                  textAlign: TextAlign.left,
                  // 产品原样用 Colors.red（迁移笔记机制③：内联定色保持生效）
                  style: const TextStyle(color: Color(0xFFF44336))),
            ],
          ),
          actions: _acts(confirmLabel: '删除', destructive: true),
        ),
      ),
      // ── S15 download_panel「删除这一集」（:617）──────────────────────
      _Case(
        'S15_download_remove_episode',
        'lib/ui/widgets/download_panel.dart:617「删除这一集的下载？」',
        '第18项·删除单集 —— 复刻：单行正文、默认宽 460',
        expectWidth: 460,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '删除这一集的下载？',
          content: const Text('「探针剧」第 02 集 · 420 MB\n\n'
              '只删这一集的文件，其它集不受影响。删除后不可恢复。'),
          actions: _acts(confirmLabel: '删除', destructive: true),
        ),
      ),
      // ── S11 sync_panel「设置/修改凭据同步口令」（:1455）──────────────
      _Case(
        'S11_sync_credential_passphrase',
        'lib/ui/widgets/sync_panel.dart:1455「设置凭据同步口令」',
        '第18项·凭据同步口令 —— 复刻：两个 TextField（口令/再输一次）+'
            '透明 Material、默认宽 460',
        expectWidth: 460,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '设置凭据同步口令',
          content: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                TextField(
                  obscureText: true,
                  decoration: InputDecoration(labelText: '口令（至少 8 位）'),
                ),
                SizedBox(height: 10),
                TextField(
                  obscureText: true,
                  decoration: InputDecoration(labelText: '再输一次'),
                ),
              ],
            ),
          ),
          actions: _acts(confirmLabel: '保存'),
        ),
      ),
      // ── S10 sync_panel「配置云盘（WebDAV）」（:1200）─────────────────
      _Case(
        'S10_sync_webdav_config',
        'lib/ui/widgets/sync_panel.dart:1200「配置云盘（WebDAV）」',
        '第18项·云盘配置 —— 复刻：三段表单（服务预设/地址/账号）+透明 Material、'
            '默认宽 460',
        expectWidth: 460,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '配置云盘（WebDAV）',
          content: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('服务预设', textAlign: TextAlign.left),
                SizedBox(height: 6),
                TextField(
                  decoration: InputDecoration(hintText: '坚果云 / Nextcloud / 自定义'),
                ),
                SizedBox(height: 12),
                Text('地址', textAlign: TextAlign.left),
                SizedBox(height: 6),
                TextField(
                  decoration: InputDecoration(hintText: 'https://dav.example.com/remote.php/dav'),
                ),
              ],
            ),
          ),
          actions: _acts(confirmLabel: '连接'),
        ),
      ),
      // ── S09 sync_panel `_confirm()`（:666，两个调用点共用）───────────
      //   ⚠️ **非本批迁移站点**：HEAD 里 sync_panel 只有 :1200 / :1439 两处
      //      AlertDialog（= S10 / S11），本档不在第 18 项那 13 处之内
      //      ⇒ 只作**外壳对照**。
      _Case(
        'S09_sync_confirm',
        'lib/ui/widgets/sync_panel.dart:666 `_confirm()`'
            '（云同步两个调用点共用；非本批迁移站点，仅作外壳对照）',
        '第18项·外壳对照（非迁移站点）—— 云同步确认：正文+取消/确认两键、'
            '默认宽 460（文案合成）',
        expectWidth: 460,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '覆盖云端备份？',
          content: const Text('云端已有一份同名备份，继续会用本机这一份覆盖它。\n\n'
              '覆盖后旧的那份找不回来。'),
          actions: _acts(confirmLabel: '覆盖', destructive: true),
        ),
      ),
      // ── S06 backup_panel「这个备份文件含登录态」（:606）──────────────
      //   白名单档 maxWidth 560；**三键**（取消 / 不含登录态导出 / 设口令并加密）。
      _Case(
        'S06_backup_login_state_3btn',
        'lib/ui/widgets/backup_panel.dart:606「这个备份文件含登录态」',
        '第18项·备份含登录态 —— 复刻：maxWidth 560、三键同排（取消/不含登录态导出/'
            '设口令并加密），三键几何从渲染树量',
        expectWidth: 560,
        keyLabels: ['取消', '不含登录态导出', '设口令并加密'],
        isShell: true,
        build: (_) => AppGlassDialog(
          maxWidth: 560,
          title: '这个备份文件含登录态',
          content: const Text('这份备份里有账号凭据。导出给别人的话，'
              '对方能用你的登录态。\n\n可以只导出不含登录态的部分，'
              '或者给它设一个口令再加密。'),
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTextButton(
                onPressed: () => AppTray.navigatorKey.currentState?.pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 4),
              AppTextButton(
                onPressed: () => AppTray.navigatorKey.currentState?.pop('plain'),
                child: const Text('不含登录态导出'),
              ),
              const SizedBox(width: 4),
              AppTextButton(
                onPressed: () => AppTray.navigatorKey.currentState?.pop('encrypt'),
                child: const Text('设口令并加密'),
              ),
            ],
          ),
        ),
      ),
      // ── S07 backup_panel「设置导出用口令」（:1415）──────────────────
      _Case(
        'S07_backup_export_passphrase',
        'lib/ui/widgets/backup_panel.dart:1415「设置导出用口令」',
        '第18项·导出用口令 —— 复刻：单 TextField + 透明 Material、默认宽 460',
        expectWidth: 460,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '设置导出用口令',
          content: Material(
            type: MaterialType.transparency,
            child: const TextField(
              obscureText: true,
              decoration: InputDecoration(labelText: '口令（至少 8 位）'),
            ),
          ),
          actions: _acts(confirmLabel: '导出'),
        ),
      ),
      // ── S08 backup_panel「这个备份包含登录态」（:1524）──────────────
      _Case(
        'S08_backup_import_passphrase',
        'lib/ui/widgets/backup_panel.dart:1524「这个备份包含登录态」',
        '第18项·导入要口令 —— 复刻：单 TextField(口令) + 透明 Material、默认宽 460',
        expectWidth: 460,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '这个备份包含登录态',
          content: Material(
            type: MaterialType.transparency,
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('输入导出时设的口令才能导入其中的帐号凭据。',
                    textAlign: TextAlign.left),
                SizedBox(height: 12),
                TextField(
                  obscureText: true,
                  decoration: InputDecoration(labelText: '口令'),
                ),
              ],
            ),
          ),
          actions: _acts(confirmLabel: '导入'),
        ),
      ),
      // ── S12 theme_page「预览 · <主题名>」（:201）─────────────────────
      _Case(
        'S12_theme_preview',
        'lib/ui/settings/theme_page.dart:201「预览 · \${p.name}」',
        '第18项·主题单套大预览 —— 复刻：maxWidth 560、内容为大预览块（数据合成）',
        expectWidth: 560,
        isShell: true,
        build: (_) => AppGlassDialog(
          maxWidth: 560,
          title: '预览 · 合成主题',
          content: Container(
            height: 320,
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.all(Radius.circular(12)),
              color: Color(0xFF1B1F2A),
            ),
            alignment: Alignment.center,
            child: const Text('主题预览区（探针合成色块）'),
          ),
          actions: _acts(confirmLabel: '应用'),
        ),
      ),
      // ── S16 tvbox「订阅更新」（:285）—— **真实触发**，不复制控件 ─────
      //
      // ```text
      // 这是本批唯一一个"产品代码自己建弹窗"的档：`TvboxUpdateDialog.show()`
      // 内部就是 `showAppDialog<bool>` + `r ?? false`，弹窗由产品的 State 建，
      // 含真实 TextField（机制②的透明 Material 宿主也在产品代码里）。
      // 源的 sidecar 用一个不存在的合成 id ⇒ 订阅链接为空，不碰任何真实源。
      // ```
      _Case(
        'S16_tvbox_update',
        'lib/ui/widgets/tvbox_source_panel.dart:285 + TvboxUpdateDialog.show'
            '（**真实触发**：产品自己的 State 建弹窗）',
        '第18项·tvbox 订阅更新 —— 真实触发：maxWidth 560、透明 Material、'
            '订阅链接 TextField 真实存在',
        expectWidth: 560,
        isShell: true,
        trigger: () async {
          final ctx = AppTray.navigatorKey.currentContext;
          if (ctx == null) throw StateError('navigatorKey.currentContext 为空');
          TvboxUpdateDialog.show(
            ctx,
            id: 'probe-fixture-tvbox',
            name: '合成源',
          ).ignore();
          await _settle(frames: 3, ms: 700);
        },
      ),
    ];

// ═══════════════════════════════════════════════════════════════════════
//  同步节奏：为什么要「等帧 + sleep + 再等帧」
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// ① `endOfFrame` 只是「这一帧画完了」，**不含动效时间**。
//    `showAppDialog` 带 entrance 动效（overlaySheetAnimationStyle，~200ms）
//    ⇒ 弹完立刻抓会抓到「卡片还在放大 / 半透明」的中间帧：
//      尺寸比 380 小、底色被 barrier 混过 ⇒ 读数全是错的。
// ② 单纯 `Future.delayed` 又不够：那一帧可能还没光栅化，
//    `toImage()` 会拿到上一帧的旧内容（列表页滚动中就吃过这个）。
// ③ 所以顺序是：endOfFrame → 等动效时长 → endOfFrame → 再等一小段 → endOfFrame。
//    多等的那一小段是给「动效结束那一帧的 raster」落地用的。
// ⇒ 本探针统一 `_settle()`：3 帧 + 450ms，和 t104 探针里的节奏同一思路。
// ```
Future<void> _settle({int frames = 2, int ms = 450}) async {
  for (var i = 0; i < frames; i++) {
    await WidgetsBinding.instance.endOfFrame;
  }
  await Future<void>.delayed(Duration(milliseconds: ms));
  await WidgetsBinding.instance.endOfFrame;
}

// ═══════════════════════════════════════════════════════════════════════
//  弹窗开合帧耗时采集（总计划第 13 项：逐类测「打开、关闭」的帧耗时）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须在这一层采
// ```text
// 产品自带的 `SOURIN_FRAME_LOG=1`（shell.dart:361）只做**全局**汇总：
//   ① 逐帧只在**超预算**时才记；② 完整数据只有每 5 秒的 p50/p95 汇总。
// ⇒ 它**无法按"打开弹窗/关闭弹窗"切分**，而第 13 项要的正是分类读数。
// ⇒ 本探针本来就要逐个打开 11 个弹窗，天然是分类采样的最佳位置。
// ```
//
// # 判据（与 t74 探针同口径）
// ```text
// build / raster 都按 16.7ms（60fps）预算；n 不足时**明说**，不硬报 p95。
// 窗口内 0 帧 ⇒ 记「无读数」，**不得**解释成"不卡"（t74 探针的同一条自检）。
// ```
final List<FrameTiming> _dialogTimings = <FrameTiming>[];
bool _timingOn = false;
int _timingBatches = 0;

/// 「打开」阶段墙钟起点（trigger 之前记录）
DateTime _openStartedAt = DateTime.now();

void _startDialogTimings() {
  if (_timingOn) return;
  _timingOn = true;
  _dialogTimings.clear();
  _timingBatches = 0;
  SchedulerBinding.instance.addTimingsCallback(_onDialogTimings);
}

void _onDialogTimings(List<FrameTiming> t) {
  _timingBatches++;
  _dialogTimings.addAll(t);
}

void _stopDialogTimings() {
  if (!_timingOn) return;
  _timingOn = false;
  SchedulerBinding.instance.removeTimingsCallback(_onDialogTimings);
}

/// 采一段窗口的帧读数并落盘。返回该窗口的帧数（0 ⇒ 无读数）。
int _reportDialogTimings(String label) {
  _stopDialogTimings();
  return _emitTimings(label);
}

/// 只报告、不注销（供 settle 期间轮询后统一注销）
int _emitTimings(String label) {
  final n = _dialogTimings.length;
  if (n == 0) {
    _say('  FRAME $label n=0 batches=$_timingBatches'
        '（窗口内没有任何帧 ⇒ 无读数，不能解释成"不卡"）');
    return 0;
  }
  final b = <int>[for (final t in _dialogTimings) t.buildDuration.inMicroseconds]
    ..sort();
  final r = <int>[for (final t in _dialogTimings) t.rasterDuration.inMicroseconds]
    ..sort();
  int pct(List<int> v, double p) =>
      v[((v.length - 1) * p).round().clamp(0, v.length - 1)];
  final jb = b.where((x) => x > 16700).length;
  final jr = r.where((x) => x > 16700).length;
  _say('  FRAME $label n=$n batches=$_timingBatches');
  _say('    build : p50=${pct(b, .5)} p95=${pct(b, .95)} max=${b.last} '
      '超预算=$jb');
  _say('    raster: p50=${pct(r, .5)} p95=${pct(r, .95)} max=${r.last} '
      '超预算=$jr');
  return n;
}


/// 从**渲染树**读对话框卡片的精确 rect（不是靠颜色猜边界）
///
/// 为什么不能直接用 `AppGlassDialog` / `AlertDialog` 自己的 renderObject：
/// ```text
/// `showDialog(builder:)` 把 builder 的产物放进一个**满屏**的路由页面里，
/// 传给它的约束是 tight(整窗)。所以这两个组件的 renderObject 报回来的是
/// 「整窗 1280×760」，测出来永远是"全屏遮罩" —— 那是**测量错**，不是产品错。
/// ⇒ 玻璃卡片取 `GlassContainer`（产品自己的面板，尺寸=卡片）；
///   Material 弹窗取它内部第一块 `Material`（Dialog 的卡片本体）。
/// ```

/// 遮罩亮度：在卡片四周外 30px 取 8 点，返回中位数。
/// 不用 (4,4)——那是应用自定义标题栏，与遮罩无关。
int _barrierLum(_Pix p, int l, int t, int r, int b, int vw, int vh) {
  const gap = 30;
  final cy = (t + b) ~/ 2, cx0 = (l + r) ~/ 2;
  final cand = <(int, int)>[
    (cx0, t - gap), (cx0, b + gap), (l - gap, cy), (r + gap, cy),
    (l - gap, t - gap), (r + gap, t - gap), (l - gap, b + gap), (r + gap, b + gap),
  ];
  final lums = <int>[];
  for (final (x, y) in cand) {
    if (x < 2 || y < 2 || x >= vw - 2 || y >= vh - 2) continue;
    // 落在卡片内就跳过（窄窗下四周余量小，可能兜到卡上）
    if (x >= l && x <= r && y >= t && y <= b) continue;
    lums.add(p.lum(x, y));
  }
  if (lums.isEmpty) return -1;
  lums.sort();
  return lums[lums.length ~/ 2];
}

// ═══ 图像专用的「文本行 → 对比度」量具 ═══
// 不依赖渲染树 ⇒ 同一把尺子既能量当场渲染的帧，也能量**存档 PNG**
// （量具自检就是靠这一点：拿已知合格 / 已知坏的两张旧图复算）。

/// 卡片底色 = 全卡遍采样的众数色（每通道量化 5bit）。
(int, int, int) _cardBg(_Pix p, int l, int t, int r, int b) {
  final cnt = <int, int>{};
  final rep = <int, (int, int, int)>{};
  for (var y = t + 3; y < b - 3; y += 2) {
    for (var x = l + 3; x < r - 3; x += 2) {
      final c = p.rgb(x, y);
      final k = ((c.$1 >> 3) << 10) | ((c.$2 >> 3) << 5) | (c.$3 >> 3);
      cnt[k] = (cnt[k] ?? 0) + 1;
      rep[k] = c;
    }
  }
  var bestK = -1, bestN = -1;
  cnt.forEach((k, n) {
    if (n > bestN) {
      bestN = n;
      bestK = k;
    }
  });
  return bestK < 0 ? p.rgb(l + 4, t + (b - t) ~/ 2) : rep[bestK]!;
}

int _lumOf((int, int, int) c) => (c.$1 * 299 + c.$2 * 587 + c.$3 * 114) ~/ 1000;

/// 逐行数墨迹（与卡底色亮度差 > 40 的像素），连续行合成文本带。
List<({int y0, int y1, int ink})> _textBands(
    _Pix p, int l, int t, int r, int b, int bgL) {
  final bands = <({int y0, int y1, int ink})>[];
  var start = -1, ink = 0;
  for (var y = t + 2; y < b - 2; y++) {
    var n = 0;
    for (var x = l + 2; x < r - 2; x++) {
      if ((p.lum(x, y) - bgL).abs() > 40) n++;
    }
    if (n >= 3) {
      if (start < 0) {
        start = y;
        ink = 0;
      }
      ink += n;
    } else if (start >= 0) {
      if (y - start >= 4) bands.add((y0: start, y1: y, ink: ink));
      start = -1;
    }
  }
  if (start >= 0 && b - 2 - start >= 4) {
    bands.add((y0: start, y1: b - 2, ink: ink));
  }
  return bands;
}

/// 一行文本的对比度：文字色 = 带内离卡底色**最远**的那个像素（取真实 RGB）。
({(int, int, int) ink, double ratio, int y}) _bandContrast(
    _Pix p, int l, int r, int y0, int y1, (int, int, int) bg, int bgL) {
  var bestD = -1;
  var best = bg;
  var bestY = y0;
  for (var y = y0; y < y1; y++) {
    for (var x = l + 2; x < r - 2; x++) {
      final d = (p.lum(x, y) - bgL).abs();
      if (d > bestD) {
        bestD = d;
        best = p.rgb(x, y);
        bestY = y;
      }
    }
  }
  return (ink: best, ratio: _wcag(best, bg), y: bestY);
}

/// 对一张 _Pix 的卡片区域出一行 `CONTRAST|...` 读数。
/// title = 最上面那条文本带；body = 其余带里**墨迹最多的前 3 条**中比值最差的
/// 那条（Lead 要求「同一段正文多取几行、取最差的一行」，避免抽样走运）。
({double title, double body, String line, String note}) _contrastOfCard(
    _Pix p, int l, int t, int r, int b) {
  final bg = _cardBg(p, l, t, r, b);
  final bgL = _lumOf(bg);
  // 跳过卡片上沿 12px：那圈是玻璃**描边/高光/阴影**，不是文字
  // （2026-10-20 自检踩到：first band 落在 y15..37 读到的是边沿灰 #6A6B6E）。
  final bands = _textBands(p, l, t, r, b, bgL)
      .where((bd) => bd.y0 >= t + 12 && bd.y1 - bd.y0 >= 6)
      .toList();
  if (bands.length < 2) {
    return (
      title: -1,
      body: -1,
      line: 'CONTRAST|skipped|bands=${bands.length}|card=${_hx(bg)}',
      note: 'reason=卡内文本行带不足 2 条',
    );
  }
  final tb = bands.first;
  final tc = _bandContrast(p, l, r, tb.y0, tb.y1, bg, bgL);
  final rest = bands.skip(1).toList()..sort((a, b2) => b2.ink - a.ink);
  final cands = rest.take(3).toList();
  var worst = _bandContrast(p, l, r, cands.first.y0, cands.first.y1, bg, bgL);
  var worstBand = cands.first;
  for (final bd in cands.skip(1)) {
    final cc = _bandContrast(p, l, r, bd.y0, bd.y1, bg, bgL);
    if (cc.ratio < worst.ratio) {
      worst = cc;
      worstBand = bd;
    }
  }
  final ok = tc.ratio >= 4.5 && worst.ratio >= 4.5;
  return (
    title: tc.ratio,
    body: worst.ratio,
    line: 'CONTRAST|CASE|card=${_hx(bg)}|title=${_hx(tc.ink)}'
        '|titleRatio=${tc.ratio.toStringAsFixed(2)}|body=${_hx(worst.ink)}'
        '|bodyRatio=${worst.ratio.toStringAsFixed(2)}'
        '|verdict=${ok ? "OK" : "BAD"}',
    note: 'bands=${bands.length} titleBand=y${tb.y0}..${tb.y1}'
        ' bodyBand=y${worstBand.y0}..${worstBand.y1}(ink=${worstBand.ink})'
        '|阈值=4.5|底=全卡众数色|文字=带内离底最远像素(偏饱和，偏保守)',
  );
}

double _relLum((int, int, int) c) {
  double f(int v) {
    final s = v / 255.0;
    return s <= 0.04045 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * f(c.$1) + 0.7152 * f(c.$2) + 0.0722 * f(c.$3);
}

/// WCAG 2.1 对比度：(L1+0.05)/(L2+0.05)，1.00 ~ 21.00
double _wcag((int, int, int) a, (int, int, int) b2) {
  final la = _relLum(a), lb = _relLum(b2);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

String _hx((int, int, int) c) {
  final s = '#${c.$1.toRadixString(16).padLeft(2, '0')}'
      '${c.$2.toRadixString(16).padLeft(2, '0')}'
      '${c.$3.toRadixString(16).padLeft(2, '0')}';
  return s.toUpperCase();
}

Rect? _dialogRect() {  Rect? rectOf(Element e) {
    final ro = e.renderObject;
    if (ro is RenderBox && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  double winW = 1280;
  final root = _shotKey.currentContext?.findRenderObject();
  if (root is RenderBox && root.hasSize) winW = root.size.width;

  Element? dialogEl;
  void findDialog(Element e) {
    if (dialogEl != null) return;
    final w = e.widget;
    if (w is AppGlassDialog || w is AlertDialog || w is AppDialogShell) {
      dialogEl = e;
      return;
    }
    e.visitChildElements(findDialog);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(findDialog);
  if (dialogEl == null) return null;

  Element? glass;
  Element? mat;
  void findPanel(Element e) {
    if (glass != null) return;
    final n = e.widget.runtimeType.toString();
    if (n == 'GlassContainer') {
      glass = e;
      return;
    }
    if (mat == null && n == 'Material') {
      final r = rectOf(e);
      // 排除"铺满整窗"的 Material（那不是卡片）
      if (r != null && r.width < winW * 0.985) mat = e;
    }
    e.visitChildElements(findPanel);
  }

  dialogEl!.visitChildElements(findPanel);

  final g = glass == null ? null : rectOf(glass!);
  if (g != null && g.width > 1 && g.height > 1) {
    _say('   rect源=GlassContainer（产品玻璃面板自身，非满屏路由）');
    return g;
  }
  final m = mat == null ? null : rectOf(mat!);
  if (m != null && m.width > 1 && m.height > 1) {
    _say('   rect源=Material（AlertDialog 卡片本体）');
    return m;
  }
  _say('   ⚠️ rect源=${dialogEl!.widget.runtimeType}（退回外壳根 ⇒ 可能是满屏）');
  return rectOf(dialogEl!);
}

/// 把**产品自己的页面**push 到真实 Navigator（不是自建弹窗）
void _pushRealPage(Widget page) {
  final nav = AppTray.navigatorKey.currentState;
  if (nav == null) throw StateError('navigator 还没就绪');
  nav.push(
    PageRouteBuilder<void>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
  );
}

/// 取某个 Text 的**全局矩形**（用于判「三键是不是同一行、有没有出卡片」）。
/// 只读渲染树，不点、不抢焦点。
Rect? _textGlobalRect(String text) {
  Element? hit;
  void visit(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is Text && w.data == text) {
      hit = e;
      return;
    }
    e.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  final ro = hit?.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/// 进程内合成一次 tap —— **不碰** OS 光标 / 不抢焦点 / 不用 mouse_event。
/// 打在真实按钮上 ⇒ 走产品自己的 handler ⇒ 弹出产品自己 show 的弹窗。
Future<bool> _tapByText(String text) async {
  Element? hit;
  void visit(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is Text && w.data == text) {
      hit = e;
      return;
    }
    e.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  if (hit == null) return false;

  // ① 先滚到可见（主题页的目标按钮在滚动区里，实测 y=1506 已经出了窗口）
  try {
    await Scrollable.ensureVisible(hit!, alignment: 0.5);
  } catch (_) {
    // 不在滚动区里就算了
  }
  await _settle(frames: 2, ms: 250);

  final ro = hit!.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return false;
  final pos = ro.localToGlobal(ro.size.center(Offset.zero));
  final root = _shotKey.currentContext?.findRenderObject();
  if (root is RenderBox && root.hasSize) {
    final inside = pos.dx > 0 &&
        pos.dy > 0 &&
        pos.dx < root.size.width &&
        pos.dy < root.size.height;
    if (!inside) {
      _say('   ✗「$text」滚到可见后仍在窗外 '
          '(${pos.dx.toStringAsFixed(0)}, ${pos.dy.toStringAsFixed(0)})'
          ' / 窗口 ${root.size.width.toStringAsFixed(0)}×'
          '${root.size.height.toStringAsFixed(0)}');
      return false;
    }
  }
  _say('   合成 tap「$text」@ (${pos.dx.toStringAsFixed(0)},'
      ' ${pos.dy.toStringAsFixed(0)}) —— 进程内，无 OS 输入');
  const ptr = 7;
  final g = GestureBinding.instance;
  g.handlePointerEvent(const PointerAddedEvent(pointer: ptr, position: Offset.zero));
  g.handlePointerEvent(PointerDownEvent(pointer: ptr, position: pos));
  await Future<void>.delayed(const Duration(milliseconds: 60));
  g.handlePointerEvent(PointerUpEvent(pointer: ptr, position: pos));
  return true;
}

/// 说明：旧实现（直接取 `AppGlassDialog`/`AlertDialog` 的 renderObject）
/// 已被上面 `_dialogRect` 取代 —— 旧实现会命中满屏路由根，测出"整窗=卡片"。

// ═══════════════════════════════════════════════════════════════════════
//  抓图 + 像素判读
// ═══════════════════════════════════════════════════════════════════════

Future<void> _capture(_Case c, Rect? rect) async {
  final ro = _shotKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    _bad('${c.id}: 根上不是 RenderRepaintBoundary（拿不到可 toImage 的层）');
    return;
  }
  final ui.Image img = await ro.toImage(pixelRatio: 1.0);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (png == null || raw == null) {
    _bad('${c.id}: toImage/toByteData 返回 null');
    return;
  }
  final path = '${_outDir.path}${Platform.pathSeparator}${_prefix}${c.id}.png';
  File(path).writeAsBytesSync(png.buffer.asUint8List(), flush: true);
  _say('  SHOT $path  ${img.width}x${img.height}  '
      '${(png.lengthInBytes / 1024).toStringAsFixed(1)} KB');

  final pix = _Pix(img.width, img.height, raw.buffer.asUint8List());

  // 卡片区域 2× 裁切另存，给人眼看细节（同一帧、同一份像素）
  if (rect != null) {
    await _cropCard(img, rect, '${_outDir.path}${Platform.pathSeparator}${_prefix}card_${c.id}.png');
  }

  _analyze(c, pix, rect);
  img.dispose();
}

Future<void> _cropCard(ui.Image src, Rect r, String path) async {
  final scale = 2.0;
  final w = (r.width * scale).roundToDouble();
  final h = (r.height * scale).roundToDouble();
  const pad = 12.0;
  final rec = ui.PictureRecorder();
  final cv = Canvas(rec);
  cv.drawRect(
    Rect.fromLTWH(0, 0, w + pad * 2, h + pad * 2),
    Paint()..color = const Color(0xFF1B1A1F),
  );
  cv.drawImageRect(
    src,
    r,
    Rect.fromLTWH(pad, pad, w, h),
    Paint()..filterQuality = FilterQuality.none,
  );
  final pic = rec.endRecording();
  final out = await pic.toImage((w + pad * 2).round(), (h + pad * 2).round());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  if (bd != null) {
    File(path).writeAsBytesSync(bd.buffer.asUint8List(), flush: true);
    _say('  CROP $path  ${out.width}x${out.height}');
  }
  pic.dispose();
  out.dispose();
}

void _analyze(_Case c, _Pix p, Rect? rect) {
  final w = p.w;
  final h = p.h;

  // ① barrier 参考色（屏幕四角，卡片碰不到那里）
  final barrier = p.hex(4, 4);
  _say('  PX img=${w}x$h barrier=$barrier '
      'corner2=${p.hex(w - 5, h - 5)}');

  if (rect == null) {
    _bad('${c.id}: 渲染树里找不到卡片 rect ⇒ 无法判读几何');
    return;
  }

  final l = rect.left.round().clamp(0, w - 2);
  final t = rect.top.round().clamp(0, h - 2);
  final r = rect.right.round().clamp(l + 2, w - 1);
  final b = rect.bottom.round().clamp(t + 2, h - 1);
  final cw = r - l;
  final ch = b - t;
  _say('  PX card rect=(x=$l,y=$t,w=${rect.width.toStringAsFixed(1)},'
      'h=${rect.height.toStringAsFixed(1)})');

  // ★ 采样矩形内缩 1px —— 2026-10-20 用像素证过的根因：
  //   rect（y..y+h）把卡片**自身那 1px 描边**圈进了采样区。460 宽的玻璃卡底边
  //   整条 460-26×2=408px 全是描边色 (117,119,125)，和卡片底色的差 >45
  //   ⇒ 被当成「文字墨迹」，报出 ringInk=408 的假红（跨 9 个不同高度的卡片
  //   恒为 408 就是证据：那不是字，是边框）。
  //   SOURIN_T105_NOSHRINK=1 关掉内缩 ⇒ 必须把 9 条红原样跑回来（双向自证）。
  final noShrink = Platform.environment['SOURIN_T105_NOSHRINK'] == '1';
  final shrink = noShrink ? 0 : 1;
  final sl = l + shrink, st = t + shrink;
  final sr = r - shrink, sb = b - shrink;
  _say('  SHRINK|case=${c.id} inset=${shrink}px noshrink=${noShrink ? "1" : "0"}');

  // ② 几何判据（口径按 docs/AGENTS.md §3.5，380 已作废）
  //
  // ```text
  // §3.5：宽度 默认 560；窄弹窗 460、宽版面 820；最大高度 绝对值 620。
  // 机器可读三行，便于修前/修中/修后直接 diff：
  //   CENTER|case=NN rect=WxH viewport=WxH centered=yes/no dx=..
  //   WIDTH |case=NN w=NNN whitelist={460,560,820} verdict=ok/bad
  //   FILL  |case=NN pct=NN.N verdict=good/bad
  // ```
  const whitelist = <double>[460, 560, 820];
  final leftGap = l.toDouble();
  final rightGap = (w - r).toDouble();
  final dx = (leftGap - rightGap).abs();
  final centered = dx <= 2.0;
  final fillPct = cw / w * 100;
  _say('  CENTER|case=${c.id} rect=${cw}x$ch viewport=${w}x$h '
      'centered=${centered ? "yes" : "no"} dx=${dx.toStringAsFixed(1)}');
  final wHit = whitelist
      .where((e) => (rect.width - e).abs() <= 2.0)
      .toList(growable: false);
  final wOk = wHit.isNotEmpty || !c.isShell;
  _say('  WIDTH|case=${c.id} w=${rect.width.toStringAsFixed(0)} '
      'whitelist={460,560,820} verdict=${wOk ? "ok" : "bad"}');
  _say('  FILL|case=${c.id} pct=${fillPct.toStringAsFixed(1)} '
      'verdict=${fillPct < 90 ? "good" : "bad"}');

  if (c.isShell) {
    // 产品框：宽度必须在 §3.5 白名单里（380 与 1280 都红，460 绿）
    _ok('${c.id} 宽度落在 §3.5 白名单 {460,560,820}（实测 '
        '${rect.width.toStringAsFixed(0)}）', wOk);
  } else {
    // 对照组（Material AlertDialog）：自带 24 内边距 + 内容定宽，
    // 不按产品白名单判 —— 它在这里只证明「测量器能看见一张正常卡片」
    _say('  （对照组不按产品白名单判：Material Dialog 宽度由内容+24 内边距决定）');
  }
  _ok('${c.id} 卡片水平居中（左右留白差 ${dx.toStringAsFixed(1)}px ≤2）', centered);
  _ok('${c.id} 卡片没铺满视口（占宽 ${fillPct.toStringAsFixed(1)}% <90%）',
      fillPct < 90);
  if (c.narrow) {
    _ok('${c.id} 窄视口下四边都不贴边（L$leftGap T$t R$rightGap B${h - b}）',
        leftGap > 2 && t > 2 && rightGap > 2 && (h - b) > 2);
  }

  // ②-b 三键同排：托盘关闭框是唯一的三键框，判「一行、x 递增、都在卡片内」。
  //      只读渲染树里的 Text 矩形（不点、不抢焦点）；像素侧的「不裁切」由
  //      下面的 10px 边环判据兜底。
  final keyLabels = c.keyLabels ??
      (c.id.contains('tray_close')
          ? const <String>['最小化到托盘', '彻底退出', '取消']
          : null);
  if (keyLabels != null) {
    final labels = keyLabels;
    final rs = <String, Rect>{};
    for (final lb in labels) {
      final rr = _textGlobalRect(lb);
      if (rr != null) rs[lb] = rr;
    }
    if (rs.length != labels.length) {
      _bad('${c.id} 三键没全部出现在渲染树里（找到 ${rs.length}/3）');
    } else {
      final ys = rs.values.map((e) => e.center.dy).toList(growable: false);
      final dyMax =
          ys.reduce((a2, b2) => a2 > b2 ? a2 : b2) -
              ys.reduce((a2, b2) => a2 < b2 ? a2 : b2);
      final sameY = dyMax <= 1.0;
      final inside = rs.values.every((e) =>
          e.left >= l + 2 && e.right <= r - 2 && e.top >= t + 2 && e.bottom <= b - 2);
      final cx = labels.map((e) => rs[e]!.center.dx).toList(growable: false);
      final ordered = cx[0] < cx[1] && cx[1] < cx[2];
      _say('  KEYS|case=${c.id} n=3 sameY=${sameY ? "yes" : "no"} '
          'dy=${dyMax.toStringAsFixed(1)} inside=${inside ? "yes" : "no"} '
          'order=${ordered ? "yes" : "no"}');
      _ok('${c.id} 三键同排（y 相同 ≤1px、x 递增）', sameY && ordered);
      _ok('${c.id} 三键都在卡片内（各留 2px）', inside);
    }
  }

  // ③ 底色：卡片内部三点取样（避开文字：取左右内边距带 + 底部内边距带）
  final bgSamples = <String>[
    p.hex(l + 6, t + ch ~/ 2),
    p.hex(r - 6, t + ch ~/ 2),
    p.hex(l + cw ~/ 2, b - 6),
    p.hex(l + 6, t + 6),
  ];
  _say('  PX card bg samples=${bgSamples.join(" ")}');

  // ④ 圆角：只对**纯色底**卡片估（白底 Material 可靠）。
  //    玻璃卡片底色本身是渐变+模糊背景，逐行找「首像素」会一路误命中（首版实测
  //    给已知圆角 18 的 AlertDialog 报 0，属探针缺陷，不是产品缺陷）⇒ 这里如实跳过。
  final bgc = p.rgb(l + cw ~/ 2, b - 6);
  int dmax((int, int, int) a, (int, int, int) b2) => [
        (a.$1 - b2.$1).abs(),
        (a.$2 - b2.$2).abs(),
        (a.$3 - b2.$3).abs(),
      ].reduce((x2, y2) => x2 > y2 ? x2 : y2);
  final solid = dmax(p.rgb(l + 6, t + ch ~/ 2), bgc) <= 10 &&
      dmax(p.rgb(r - 6, t + ch ~/ 2), bgc) <= 10 &&
      dmax(p.rgb(l + cw ~/ 2, t + 6), bgc) <= 10;
  if (solid) {
    // ── 交叉参照（旧标定法）：逐行「首个吃到卡底色」的 inset 剖面 ──────────
    //   ★ 只作参照，**不参与判定**：raw+4 是两点标定出来的恒等偏移，
    //     raw=18 ⇒ cal 必然 =22 ⇒ 旧日志那句 `diff=0.0` 是恒等式，不是精度。
    final profile = <int>[];
    var radiusRaw = 0;
    for (var dy = 0; dy < 28 && t + dy < h; dy++) {
      var inset = -1;
      for (var dx = 0; dx < 34 && l + dx < w; dx++) {
        if (dmax(p.rgb(l + dx, t + dy), bgc) <= 10) {
          inset = dx;
          break;
        }
      }
      profile.add(inset);
      if (inset > radiusRaw) radiusRaw = inset;
    }
    _say('  PX cornerInset(top→down 28px)=${profile.join(",")}');

    // ── 主判据：覆盖率面积法（无标定常数、亚像素、±0.5px）───────────────
    final area = _radiusByArea(p, l, t, r, b, bgc);
    final isCtrl = c.id.contains('shell_glass');
    _say('  RADIUS|case=${c.id} method=area corners=${area.cornerText} '
        'r=${area.text} target=Radii.lg(${Radii.lg}) |Δ|=${area.devText} '
        'verdict=${isCtrl ? "info" : area.verdict}');
    _say('  RADIUS-XREF|case=${c.id} 旧标定法 raw=$radiusRaw cal=${radiusRaw + 4}'
        '（两点标定 ⇒ 恒等偏移，仅参照；判定用上面的 method=area）');
    if (isCtrl) {
      _say('  RADIUS-NOTE|case=${c.id} 对照组深色玻璃边对比度低 ⇒ 只作信息；'
          '圆角以 card_${c.id}.png 人眼判');
    } else if (area.r == null) {
      _say('  RADIUS-NOTE|case=${c.id} 卡片/外底对比不足或角外底色不是平面 ⇒ '
          '面积法测不了（判 skip，**不算通过**）');
    } else {
      _ok('${c.id} 圆角 = Radii.lg(${Radii.lg})（面积法 ${area.text}，'
          '|Δ|=${area.devText} ≤ 0.5）', area.ok);
    }
  } else {
    _say('  PX 圆角：卡片底色是渐变/透背景 ⇒ 探针不估（看图判）');
    _say('  RADIUS|case=${c.id} method=area r=skip '
        'target=Radii.lg(${Radii.lg}) verdict=skip');
  }

  // ⑤ 文字墨迹 bbox —— 判「文字/按钮有没有被裁掉」。
  //    阈值 45：卡片自身的1px描边/阴影与底色的差 <25，只有真正的字/按钮才超过；
  //    首版用 26 会把描边算成墨迹 ⇒ 已知完好的 AlertDialog 也报「余量 0」。
  final bg = p.rgb(l + cw ~/ 2, sb - 6);
  var x0 = 1 << 20, y0 = 1 << 20, x1 = -1, y1 = -1, ink = 0;
  var ringInk = 0;
  // 采样区已经内缩 1px（见上）⇒ 这里的最外圈是卡片内部，不再是它自己的描边。
  // 判据：**排掉四角弧区之后，卡片外圈 10px 内不许有「和底色差 >45」的像素**
  // （文字/按钮按设计有 16~24px 内边距，进不去这一圈）。
  //
  // ★★★ 2026-10-25 归因更正（独立复算实证，别再写错）：真正让 ringInk 归零的是
  // **排掉四角 26×26 弧区**，**不是**「内缩 1px」。把三个条件拆开在 S05 上实测：
  // ```text
  //   不内缩、不排角 = 418      不内缩、排 26×26 角 = 0     ← 起作用的是这一条
  //   内缩1px、不排角 = 418     内缩1px、排 26×26 角 = 0
  //   418/418 个边带像素全落在角块内，颜色 = #6D6E71（遮罩色），不是文字也不是按钮
  // ```
  // 机理：卡片有圆角 ⇒ 四个角外侧那一小块是**卡片没盖到的遮罩**，只要它落进采样矩形
  // 就会被判成墨迹。内缩 1px 只去掉卡片自己的 1px 描边，去不掉这块弧外遮罩。
  // ⇒ 下面这句日志的结论（正文/按钮没贴边、余量 L/T/R/B 都在 20px 以上）成立，
  //   但**归因必须记在「排角」上**；不排角时那 418 个是弧外遮罩，不是内容。
  final edgeHist = List<int>.filled(8, 0);
  final ringSamples = <String>[];
  var maxLum = 0;
  final colorSet = <int>{};
  for (var y = st; y < sb; y += 1) {
    for (var x = sl; x < sr; x += 1) {
      // 圆角四角外的那块是「卡片没盖到的地方」，颜色天然等于遮罩/背景
      // ⇒ 会被误当成墨迹把 bbox 顶到边缘（首版就这么把已知完好的 AlertDialog
      //    报成「余量 0」）。这里把每个角 26×26 的方块排除，只看卡片本体。
      final nearL = x - sl < 26, nearR = sr - 1 - x < 26;
      final nearT = y - st < 26, nearB = sb - 1 - y < 26;
      if ((nearL || nearR) && (nearT || nearB)) continue;
      final cx = p.rgb(x, y);
      final d = [
        (cx.$1 - bg.$1).abs(),
        (cx.$2 - bg.$2).abs(),
        (cx.$3 - bg.$3).abs(),
      ].reduce((a2, b2) => a2 > b2 ? a2 : b2);
      final lu = p.lum(x, y);
      if (lu > maxLum) maxLum = lu;
      if (x % 3 == 0 && y % 3 == 0) {
        colorSet.add((cx.$1 >> 3 << 16) | (cx.$2 >> 3 << 8) | (cx.$3 >> 3));
      }
      final edgeD = [
        x - sl,
        sr - 1 - x,
        y - st,
        sb - 1 - y,
      ].reduce((a2, b2) => a2 < b2 ? a2 : b2);
      if (edgeD < 16) {
        if (d > 45) {
          edgeHist[edgeD ~/ 2] += 1;
          if (edgeD < 10) {
            ringInk += 1;
            if (ringSamples.length < 3) {
              ringSamples.add('($x,$y)#${p.hex(x, y)}@d$edgeD');
            }
          }
        }
        continue;
      }
      if (d > 45) {
        ink++;
        if (x < x0) x0 = x;
        if (y < y0) y0 = y;
        if (x > x1) x1 = x;
        if (y > y1) y1 = y;
      }
    }
  }
  _say('  PX ink bbox=(x=$x0,y=$y0..x=$x1,y=$y1) count=$ink ring=$ringInk');
  _say('  PX edge-band ink hist 0-2/2-4/4-6/6-8/8-10/10-12/12-14/14-16 = $edgeHist');
  if (ringSamples.isNotEmpty) {
    _say('  PX ring 样例像素=${ringSamples.join(" ")}');
  }

  _ok('${c.id} 有文字/按钮像素（不是空白卡片）', ink > 300, 'ink=$ink');
  _ok('${c.id} 卡片不是纯黑（最大亮度 $maxLum）', maxLum > 40);
  _ok('${c.id} 正文/按钮没贴边：排掉四角弧区后，10px 边环内无墨迹'
      '（不排角时那些是圆角弧外露出的遮罩 #6D6E71，不是内容）',
      ringInk == 0, 'ringInk=$ringInk');

  if (ink > 300) {
    final ml = x0 - l, mt = y0 - t, mr = r - x1, mb = b - y1;
    // 环外已排除 ⇒ 这四个数必然 ≥10，只作信息行（不再当判据，否则是「恒真断言」）。
    _say('  PX 墨迹到卡片边缘的余量 L=$ml T=$mt R=$mr B=$mb'
        '（含 10px 边环；判据见上一行的 ringInk）');
  } else {
    _bad('${c.id} 卡片内几乎没有墨迹 ⇒ 疑似空白渲染');
  }

  _ok('${c.id} 颜色种数 ${colorSet.length}（>12 说明不是纯色空白）',
      colorSet.length > 12);

  // ⑥ 玻璃质感：卡片内部亮度/色彩**有变化**（玻璃 + 内容），
  //    且卡片与遮罩明显不同（不是没画出来）。
  //    ⚠️ 遮罩采样不能取 (4,4)：应用自带自定义标题栏，窗口左上角是标题栏
  //    （恒为亮白），拿它当 barrier 会给出与弹窗无关的读数（2026-10-20 实测
  //    (4,4)=235 而卡片 231 ⇒ 判据恒红/无判别力）。改成在卡片**四周外 30px**
  //    取 8 点中位数，天然落在遮罩上。
  final topLum = p.lum(l + cw ~/ 2, t + 4);
  final botLum = p.lum(l + cw ~/ 2, b - 4);
  final barLum = _barrierLum(p, l, t, r, b, p.w, p.h);
  _say('  PX 卡片内亮度 top=$topLum bottom=$botLum '
      'barrierLum=$barLum（卡片外 30px 8 点中位数）');
  _ok('${c.id} 卡片与遮罩可区分（|Δ亮度|>6）', (topLum - barLum).abs() > 6);
  _say('  PX 备注：玻璃的"模糊"无法用像素断言，'
      '靠 card_${c.id}.png 人眼判（本探针已另存 2× 裁切）');

  // ⑦ 对比度（Lead 2026-10-20 指出的真缺陷维度）——**纯像素量，不看渲染树**：
  //    底 = 全卡众数色；文字 = 文本带内离底最远的像素。
  //    局限（如实登记）：小字号最暗/最亮像素仍可能是半覆盖的抗锯齿像素
  //    ⇒ 读数偏保守（真实对比度只会更好）。
  final cc = _contrastOfCard(p, sl, st, sr, sb);
  if (cc.title < 0) {
    _say('  ${cc.line.replaceFirst("CONTRAST|", "CONTRAST|${c.id}|")}');
  } else {
    _say('  ${cc.line.replaceFirst("CONTRAST|CASE|", "CONTRAST|${c.id}|")}');
    _say('  CONTRAST-NOTE|${c.id}|${cc.note}');
    _ok('${c.id} 对比度 ≥${c.contrastBodyMin.toStringAsFixed(1)}'
        '（title ${cc.title.toStringAsFixed(2)} / '
        'body ${cc.body.toStringAsFixed(2)}）',
        cc.title >= 4.5 && cc.body >= c.contrastBodyMin);
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  单个用例
// ═══════════════════════════════════════════════════════════════════════

Future<void> _runCase(_Case c) async {
  _say('');
  _say('── ${c.id}  ${c.note}');
  _say('   来源: ${c.src}');
  _currentCase = c.id;
  _nCase++;

  final errBefore = _errs.length;

  // ★ 第 13 项：从"打开"这一刻开始采帧，settle 之后报告（见 _reportDialogTimings）
  // ⚠️ 实测坑：`addTimingsCallback` 的回调**只在帧批次投递时**才触发。
  //   若 trigger 全程同步完成（`showAppDialog` 立刻返回 Future，帧还没画），
  //   回调一次都不会进 ⇒ `batches=0 / n=0`。
  //   ⇒ 注册必须在 trigger **之前**，且 trigger 之后要**显式让出事件循环**。
  _startDialogTimings();
  _openStartedAt = DateTime.now();

  if (c.trigger != null) {
    // 真实路径：不改写任何东西，直接调产品代码
    // ⚠️ 前置闸：只有 closeAction == ask 时点 X 才会弹框；
    //    别的档位会真的最小化/退出（探针会当场死掉）
    if (AppTray.instance.action != CloseAction.ask) {
      _bad('${c.id}: closeAction=${AppTray.instance.action}（不是 ask）'
          '⇒ 调 onWindowClose 会真的退出，跳过本框');
      return;
    }
    _say('   trigger=产品真实入口（closeAction=ask ✓）');
    await c.trigger!();
  } else {
    final ctx = AppTray.navigatorKey.currentContext;
    if (ctx == null) {
      _bad('${c.id}: 拿不到 navigatorKey.currentContext');
      return;
    }
    _say('   context=AppTray.navigatorKey.currentContext '
        '(与 app_tray.dart:241 同一个)');
    // 不复刻 pop 逻辑，直接挂上去；返回值不用（本探针用 navigator.pop 收尾）
    // ⚠️ 不用 `unawaited`：`showAppDialog<void>` 的返回是 `Future<void?>`，
    //    类型上不是 `Future<void>`；`Future.ignore()` 才是这里要的语义
    //    （框留在树上供取证，出错由 FlutterError 收集器记账）。
    showAppDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: c.build!,
    ).ignore();
  }

  // ⚠️ 让出事件循环：帧批次投递是异步的，同步走到这里回调还没被调用过。
  //   三次 endOfFrame 覆盖「首帧 + 入场动效首帧 + 动效中段」，
  //   让 `addTimingsCallback` 至少收到两批。
  await SchedulerBinding.instance.endOfFrame;
  await SchedulerBinding.instance.endOfFrame;
  await SchedulerBinding.instance.endOfFrame;

  // ★ 第 13 项「打开」分类：从 trigger 到本框稳定 = 打开 + 入场动效的全部帧
  //
  // ⚠️ 实测结论（不要再用 timings 回调量打开阶段）：
  //   连续三版尝试（提前注册 / `delayed(0)` / 连等 3 次 `endOfFrame`）
  //   都得到 `batches=0`，即 `addTimingsCallback` 回调**一次都没进**。
  //   对照：同一份代码里**关闭**阶段能拿到 n=34。
  //   差别在于关闭阶段的帧是由 `_settle()` 里的 `Future.delayed(420ms)`
  //   连续驱动出来的，而打开阶段的入场动效在 `showAppDialog` 内部已经跑完。
  //   ⇒ 在**没证实**为什么回调不投递之前，不继续猜（纪律：不按假设盲改）。
  //   ⇒ 打开阶段改用**墙钟**读数（`_openWallUs`），它是可测的，且不与 timings 混淆。
  final openWallUs = DateTime.now().difference(_openStartedAt).inMicroseconds;
  await _settle();
  final openFrames = _reportDialogTimings('${c.id} 打开');
  _say('  ⇒「打开」类帧耗时的**正式读数**见 lib/t107_perf_open_probe.dart：'
      '本处在打开窗口恒采不到 timings（机制见该文件头），'
      't107 用「回调常驻不摘 + 时钟对齐归属」把这类读数采到了；'
      '本行的 n=0 是**已知仪器限制**，不是"不卡"');
  _say('  OPEN_WALL ${c.id} = ${openWallUs}us '
      '（trigger→稳定墙钟；timings 回调投递 ${_timingBatches} 批）');
  final rect = _dialogRect();
  await _capture(c, rect);

  // 收尾：把框关掉，再等退场动效走完（否则下一框会叠在这个上面）
  final nav = AppTray.navigatorKey.currentState;
  if (nav != null && nav.canPop()) nav.pop();
  // ★ 第 13 项「关闭」分类：从 pop 到退场动效结束的帧
  _startDialogTimings();
  await _settle(frames: 1, ms: 420);
  _reportDialogTimings('${c.id} 关闭');
  if (openFrames == 0) {
    _say('  NOTE ${c.id}: 打开窗口 0 帧 ⇒ 该框无打开耗时读数（不解释成"不卡"）');
  }
  if (c.cleanup != null) await c.cleanup!();

  final added = _errs.length - errBefore;
  if (added > 0) {
    _bad('${c.id}: 本框期间新增 ${added} 条渲染异常');
  } else {
    _ok('${c.id}: 本框期间渲染异常 = 0', true);
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

int _selfTestBad = 0;

/// 离线量具自检：对**存档 PNG** 复算对比度（与当场渲染的帧共用同一个
/// `_contrastOfCard()`，所以它证明的是「尺子有判别力」，不是另写一套）。
/// 规格：`名字[!OK|!BAD]=路径[@l,t,w,h]`，多条用 `;` 分隔；省略 rect 时
/// 按 `card_*.png` 的 2× 裁切几何（四周各 12px 暗底 pad）。
Future<void> _selfTest(String spec) async {
  _say('');
  _say('══ 量具自检：同一把尺子跑「已知合格」与「已知坏」两张存档图 ══');
  for (final raw in spec.split(';')) {
    final s = raw.trim();
    if (s.isEmpty) continue;
    var name = s, path = s;
    final eq = s.indexOf('=');
    if (eq > 0) {
      name = s.substring(0, eq);
      path = s.substring(eq + 1);
    }
    String? expect;
    for (final tag in const ['!OK', '!BAD']) {
      if (name.endsWith(tag)) {
        expect = tag.substring(1);
        name = name.substring(0, name.length - tag.length);
      }
    }
    var rect = const Rect.fromLTRB(12, 12, 932, 542);
    final at = path.lastIndexOf('@');
    if (at > 0) {
      final nums = path
          .substring(at + 1)
          .split(',')
          .map((e) => double.parse(e.trim()))
          .toList(growable: false);
      path = path.substring(0, at);
      if (nums.length == 4) {
        rect = Rect.fromLTWH(nums[0], nums[1], nums[2], nums[3]);
      }
    }
    final f = File(path);
    if (!f.existsSync()) {
      _say('  !! 自检缺图: $path');
      _selfTestBad++;
      continue;
    }
    final codec = await ui.instantiateImageCodec(f.readAsBytesSync());
    final frame = await codec.getNextFrame();
    final im = frame.image;
    final bd = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) {
      _say('  !! 自检解码失败: $path');
      _selfTestBad++;
      continue;
    }
    final p = _Pix(im.width, im.height, bd.buffer.asUint8List());
    final l = rect.left.round().clamp(0, p.w - 4);
    final t = rect.top.round().clamp(0, p.h - 4);
    final r = rect.right.round().clamp(l + 4, p.w - 1);
    final bb = rect.bottom.round().clamp(t + 4, p.h - 1);
    final c = _contrastOfCard(p, l + 1, t + 1, r - 1, bb - 1);
    final verdict = c.title < 0 ? 'SKIP' : (c.line.split('verdict=').last);
    _say('  ${c.line.replaceFirst("CONTRAST|CASE|", "CONTRAST|selftest:$name|")}');
    _say('  CONTRAST-NOTE|selftest:$name|${c.note}'
        '|img=${p.w}x${p.h}|rect=($l,$t,$r,$bb)'
        '${expect == null ? "" : "|expect=$expect"}');
    if (expect != null && verdict != expect) {
      _say('  ✗ 自检失配: $name 期望 $expect 实得 $verdict ⇒ 量具没有判别力');
      _selfTestBad++;
    }
    im.dispose();
  }
  _say('SELFTEST ${_selfTestBad == 0 ? "PASS" : "FAIL"} bad=$_selfTestBad');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _prefix = Platform.environment['SOURIN_T105_PREFIX'] ?? '';

  // 产物目录 = <cwd>/.probe/round66_r4_device
  _outDir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}.probe'
      '${Platform.pathSeparator}round66_r4_device');
  if (!_outDir.existsSync()) _outDir.createSync(recursive: true);
  _logFile = File('${_outDir.path}${Platform.pathSeparator}${_prefix}probe.log');
  _logFile!.writeAsStringSync(''); // 每次跑清空，避免误读上一轮的 DONE

  // ── 渲染异常收集器（**判据**：全程必须 0）─────────────────────────
  FlutterError.onError = (FlutterErrorDetails d) {
    final msg = '${d.exceptionAsString()}';
    _errs.add('[$_currentCase] $msg');
    _say('  !! FLUTTER ERROR ($_currentCase): $msg');
    final lib = d.context?.toString() ?? d.library;
    _say('     ctx=$lib');
    final st = d.stack;
    if (st != null) {
      final lines = st.toString().split('\n').take(8).join('\n        ');
      _say('     strace:\n        $lines');
    }
  };
  ui.PlatformDispatcher.instance.onError = (Object e, StackTrace st) {
    _errs.add('[$_currentCase] zone: $e');
    _say('  !! ZONE ERROR ($_currentCase): $e');
    return true; // 吞掉，让探针继续跑完（但上面已记账 ⇒ 整条验收作废）
  };

  _say('══════ T105 · R4 弹窗真机像素验收 ══════');
  _say('cwd=${Directory.current.path}');
  _say('产物目录=${_outDir.path}');

  // ── 量具自检（离线）：同一个「文本带 → 对比度」量具跑存档 PNG ────────
  //    Lead 的要求：已知**合格**的图必须报 OK，已知**坏**的图必须报 BAD，
  //    否则量具本身没有判别力。规格：`名字=相对路径@l,t,w,h`，多条用 `;` 分隔；
  //    不给 rect 时按 card_*.png 的 2× 裁切几何（pad=12，2 倍图）。
  final st = Platform.environment['SOURIN_T105_SELFTEST'];
  if (st != null && st.trim().isNotEmpty) {
    await _selfTest(st);
    _say('DONE');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(_selfTestBad == 0 ? 0 : 1);
  }

  // ── 隔离数据目录硬闸（不许碰用户真实目录）────────────────────────
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  _say('DATA_DIR_OVERRIDE(编译期)=${override.isEmpty ? "<未设>" : override}');
  _say('APPDATA=${Platform.environment["APPDATA"]}');
  final dataDir = await ClipDownloader.dataDir();
  _say('解析后的数据目录=$dataDir');
  final isolated = dataDir
      .replaceAll('\\', '/')
      .contains('.probe/round66_r4_device');
  if (!isolated) {
    _say('★★★ 拒绝运行：数据目录不在隔离目录下（会在用户真实目录里留东西）');
    _say('RESULT FAIL dataDir=$dataDir');
    exit(3);
  }
  _say('数据目录隔离闸 ✓');

  // 兜底看门狗：任何一段卡住都不许让外层脚本无限等
  Timer(const Duration(seconds: 240), () {
    _say('★★★ TIMEOUT 240s ⇒ 强制退出');
    _say('RESULT FAIL timeout');
    exit(4);
  });

  // ── 与产品 main() 对齐的最小初始化（顺序同 shell.dart）───────────
  try {
    await UiPrefs.load(dataDir);
  } catch (e) {
    _say('UiPrefs.load 失败（不影响弹窗取证）: $e');
  }
  try {
    await SourinCore.startAsync(dataDir);
    _say('SourinCore.startAsync ✓');
  } catch (e) {
    // 核心起不来时产品会显示"核心未能启动"接管页 —— 弹窗照样能验
    _say('SourinCore.startAsync 失败（弹窗取证不受影响）: $e');
  }

  // 托盘「第一次点 X 要问」这一档要求 closeAction == ask
  _say('AppTray.action=${AppTray.instance.action}');

  // 窗口：只 show，**不 focus**（不抢宿主焦点）
  try {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.center();
    await windowManager.show();
    _say('窗口已 show（1280x800，不抢焦点）');
  } catch (e) {
    _say('windowManager 调用失败（继续，toImage 不依赖窗口可见）: $e');
  }

  // ── 产品自己的根：SourinApp（内部 WidgetsApp + Material 本地化委托）──
  runApp(RepaintBoundary(key: _shotKey, child: const SourinApp()));
  _say('runApp(RepaintBoundary(SourinApp)) ✓ —— 根是产品的，不是探针搭的');

  // 等 Navigator 可用（首帧 + 首页异步初始化）
  for (var i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await WidgetsBinding.instance.endOfFrame;
    if (AppTray.navigatorKey.currentContext != null) break;
  }
  if (AppTray.navigatorKey.currentContext == null) {
    _bad('Navigator 8s 内没起来 ⇒ 无法弹窗');
    _say('RESULT FAIL navigator_not_ready');
    exit(5);
  }
  _say('Navigator ready ✓');
  await _settle(frames: 2, ms: 1200); // 让首页首屏把异步内容落完

  // ── 逐框取证 ──────────────────────────────────────────────────
  _say('── 未取证：10_exempt_backup_login_choice —— backup_panel.dart 里'
      '「这个备份文件含登录态」那个 AlertDialog 只由私有 _exportConsent() 弹出，'
      '而它要求面板已连上云盘并选到 .sourin 备份文件（无凭据时 :535 直接 return）。');
  _say('   探针不造云端凭据、也不复制它的 builder，故本项如实记为未取证。');
  for (final c in <_Case>[..._cases(), ..._siteCases()]) {
    if (c.narrow) {
      _say('');
      _say('── 把视口缩到 800×600（窄视口复核；§3.5「按视口夹取」那半句）');
      await windowManager.setSize(const Size(800, 600));
      await _settle(frames: 3, ms: 800);
    } else {
      // 窄视口是「一次性的」：处理完必须复原，否则后面所有用例都在
      // 800×600 里拍（2026-10-20 实测 case11 就这样被拍成 800×600）。
      final sz = await windowManager.getSize();
      if (sz.width != 1280 || sz.height != 800) {
        await windowManager.setSize(const Size(1280, 800));
        await _settle(frames: 3, ms: 800);
      }
    }
    await _runCase(c);
  }

  // ── 收尾 ──────────────────────────────────────────────────────
  await _settle(frames: 1, ms: 300);
  final e = _errs.length;
  _say('');
  _say('══════ 汇总 ══════');
  _say('用例=$_nCase 判据通过=$_nOk 判据失败=$_nBad 渲染异常=$e');
  if (e > 0) {
    _say('渲染异常明细：');
    for (final s in _errs) {
      _say('  - $s');
    }
    _say('★★ 按验收规则：出现任何异常 ⇒ 整条验收作废');
  }
  final pass = e == 0 && _nBad == 0;
  _say('RESULT ${pass ? "PASS" : "FAIL"} cases=$_nCase ok=$_nOk bad=$_nBad errors=$e');
  _say('DONE');

  await Future<void>.delayed(const Duration(milliseconds: 400));
  exit(pass ? 0 : 1);
}
