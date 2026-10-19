// ═══════════════════════════════════════════════════════════════════════
//  task-66 R1 ·「弹幕」chip 的一圈毛边 —— **逐像素**读数与裁决
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// 弹幕按钮一圈毛边
// ```
//
// # 假设（任务书给定的根因）
// ```text
// _DanmakuInfoChip 用框架的 ActionChip。material_ui-1.6.0/src/chip.dart：
//   :1440  Material(shape: resolvedShape, clipBehavior: widget.clipBehavior)
//            └ _MaterialInterior → PhysicalShape(clipBehavior: Clip.none)
//              └ proxy_box.dart:2341 canvas.drawPath(..)  ← 第 1 遍实心圆角矩形
//   :1449  Ink(decoration: ShapeDecoration(shape: resolvedShape, color: ..))
//                                                     ← 第 2 遍（半透明黑 55%）
// 默认 clipBehavior = Clip.none（chip.dart:116）⇒ 子层不被裁到父层 shape 上
// ⇒ 同一圆角画两遍、两层各自抗锯齿 ⇒ 外缘一圈与内部不同值 = 毛边
// ⇒ 裁决：加 clipBehavior: Clip.antiAlias
// ```
//
// # ★★★ 本文件实测的结论：**该推论被读数否掉**
// ```text
// 纯黑视频底 / DPR=1.0 / 环带 = 距 stadium 边界 [-1.5,+1.5] px
// clipBehavior                 环带均值  环带峰值  内部中位   Δpeak    Δmean
// Clip.none                      4.505     8.641     8.641   0.000   -4.136
// Clip.hardEdge                  5.433     8.641     8.641   0.000   -4.103
// Clip.antiAlias                 4.590    10.228     8.641  +1.587   -4.051
// Clip.antiAliasWithSaveLayer    4.506     9.228     8.641  +0.587   -4.135
//
// 单遍自绘对照（Container + BoxDecoration，与站名徽章同款）
//                                ——         —        ——     见下（不可比，见注释）
// ```
// ⇒ `Clip.antiAlias` 让环带**峰值更亮 1.59 亮度级**（DPR 1.25/1.5/2.0 上
//   分别为 +1.70 / +1.59 / +1.70；opacity=0.5 时 +1.00）。方向与假设相反。
//
// **机理解释**：`Clip.none` 时上层 `Ink` 的半透明抗锯齿边缘与下层 Material
// 的实心底做 source-over 合成，覆盖率**互补** ⇒ 边缘被补回接近实色；
// 一旦 `pushClipPath`，下层在边缘被截断，上层那点半透明直接与视频背景
// 混合 ⇒ 边缘反而出现一圈更亮/更灰的环带。
//
// # 因此本文件守的是**事实**，不是"改好了"
// ```text
// ① 生产用的裁剪值 = Clip.none（不许被"顺手改成 antiAlias"）；
// ② 该值下的环带峰值不得超过内部 —— 这是"没有亮边"的**数字**定义；
// ③ 若有人改成 antiAlias，②会红（读数 +1.59），门禁会逼他重看这份证据。
// ```
//
// ⚠️ 不挂 native-media：只渲一个 chip，不加载 libmpv。
// ⚠️ 背景必须在 RepaintBoundary **内部**（第一版漏了 ⇒ 截出来的图里没有背景，
//    读数全是 0；见 `_stage` 的说明）。
// ⚠️ 几何基准必须用**真 RenderBox 矩形**，不能靠"与背景色不同"去猜外接框
//    （chip 内部是半透明黑压黑，与纯黑背景只差 8.6 亮度级，边界像素会被漏掉）。

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';

// ══════════════════════════════════════════════════════════════════════
//  舞台
// ══════════════════════════════════════════════════════════════════════

const Key kBoundary = ValueKey<String>('r1-boundary');
const Key kChip = ValueKey<String>('r1-chip');

/// 舞台 = 纯黑「视频底」+ 生产 chip
///
/// ★ 背景写在 `RepaintBoundary` **里面**：`toImage` 只截 boundary 子树，
///   背景若在外面，读到的 4 个角就会是透明/上一帧残留，判据全部失真。
Widget _stage({required Widget child, required Color backdrop}) {
  return mui.MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeFor(Brightness.dark),
    home: mui.Scaffold(
      backgroundColor: backdrop,
      body: Center(
        child: RepaintBoundary(
          key: kBoundary,
          child: ColoredBox(
            color: backdrop,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: KeyedSubtree(key: kChip, child: child),
            ),
          ),
        ),
      ),
    ),
  );
}

typedef Pixels = ({Uint8List rgba, int width, int height});

/// 渲染 + 取像素 + 取 chip 的**真实**矩形（同一坐标系：boundary 内像素）
Future<(Pixels, Rect)> _renderChip(
  WidgetTester t, {
  required Clip clipBehavior,
  required Color backdrop,
  double dpr = 1.0,
  double opacity = 1.0,
}) async {
  Widget chip = debugDanmakuInfoChipForProbe(
    data: const DanmakuInfoData(count: 128),
    clipBehavior: clipBehavior,
  );
  if (opacity != 1.0) chip = Opacity(opacity: opacity, child: chip);

  await t.pumpWidget(_stage(child: chip, backdrop: backdrop));
  await t.pumpAndSettle();

  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(kBoundary));
  final chipBox = t.renderObject<RenderBox>(find.byKey(kChip));
  final topLeft = chipBox.localToGlobal(Offset.zero, ancestor: boundary);

  late Pixels px;
  await t.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: dpr);
    final ByteData? bd =
        await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    px = (rgba: bd!.buffer.asUint8List(), width: img.width, height: img.height);
    img.dispose();
  });

  final rect = Rect.fromLTWH(
    topLeft.dx * dpr,
    topLeft.dy * dpr,
    chipBox.size.width * dpr,
    chipBox.size.height * dpr,
  );
  return (px, rect);
}

double _luma(Pixels p, int x, int y) {
  if (x < 0 || y < 0 || x >= p.width || y >= p.height) return double.nan;
  final i = (y * p.width + x) * 4;
  return 0.299 * p.rgba[i] + 0.587 * p.rgba[i + 1] + 0.114 * p.rgba[i + 2];
}

// ══════════════════════════════════════════════════════════════════════
//  周界读数
// ══════════════════════════════════════════════════════════════════════

/// 一枚 chip 的周界读数
///
/// # 两个带怎么分（决定这份判据有效与否）
/// ```text
/// chip 是全圆角（Radii.rFull ⇒ 实际半径 = 半高）⇒ 形状是 stadium。
/// 到 stadium 边界的有符号距离 d：
///   环带 = d ∈ [-1.5, +1.5]  ← 抗锯齿真正发生的地方（跨界内外各 1.5px）
///   内部 = d >= 4            ← 实心区，用来当参照
/// ⚠️ 只看"环带内侧"会漏掉外缘溢出的半像素（毛边主要在外侧）；
///    只看"最外一圈像素"又会把背景算进来。⇒ 必须是跨界窄带。
/// ```
({double edgeMean, double edgePeak, double inner, int nEdge, int nInner})
    _perimeter(Pixels p, Rect box, {double band = 1.5, double innerFrom = 4.0}) {
  final r = math.min(box.width, box.height) / 2;
  final midY = box.center.dy;

  /// 到 stadium 边界的**有符号内距**（>0 在内部）
  double signedDist(double x, double y) {
    if (x <= box.left + r) {
      return r -
          math.sqrt(
              math.pow(x - (box.left + r), 2) + math.pow(y - midY, 2));
    } else if (x >= box.right - r) {
      return r -
          math.sqrt(
              math.pow(x - (box.right - r), 2) + math.pow(y - midY, 2));
    }
    return math.min(y - box.top, box.bottom - y);
  }

  var eSum = 0.0;
  var ePeak = double.negativeInfinity;
  var eN = 0;
  final innerVals = <double>[];

  final x0 = (box.left - band - 1).floor();
  final x1 = (box.right + band + 1).ceil();
  final y0 = (box.top - band - 1).floor();
  final y1 = (box.bottom + band + 1).ceil();

  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final v = _luma(p, x, y);
      if (v.isNaN) continue;
      final d = signedDist(x + 0.5, y + 0.5);
      if (d >= -band && d <= band) {
        eSum += v;
        eN++;
        if (v > ePeak) ePeak = v;
      } else if (d >= innerFrom) {
        innerVals.add(v);
      }
    }
  }

  expect(eN, greaterThan(0), reason: '★ 环带里没有像素 ⇒ 几何算式错了');
  expect(innerVals, isNotEmpty, reason: '★ 内部没有像素 ⇒ chip 尺寸异常');

  innerVals.sort();
  final inner = innerVals[innerVals.length ~/ 2];

  return (
    edgeMean: eSum / eN,
    edgePeak: ePeak,
    inner: inner,
    nEdge: eN,
    nInner: innerVals.length,
  );
}

// ══════════════════════════════════════════════════════════════════════
//  门禁
// ══════════════════════════════════════════════════════════════════════

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 纯黑 = Owner 报缺陷时的那种视频底
  const black = Color(0xFF000000);

  setUp(() {
    // 每个 case 自己设视口
  });

  void setViewport(WidgetTester t) {
    t.view.physicalSize = const Size(360, 140);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
  }

  // ══════════════════════════════════════════════════════════════════
  //  ① 生产值就是 Clip.none —— 钉住"没有被悄悄改掉"
  // ══════════════════════════════════════════════════════════════════

  testWidgets('★★★ 生产渲染出的 ActionChip.clipBehavior 必须是 Clip.none', (t) async {
    setViewport(t);
    await t.pumpWidget(_stage(
      child: debugDanmakuInfoChipForProbe(
        data: const DanmakuInfoData(count: 128),
      ),
      backdrop: black,
    ));
    await t.pumpAndSettle();

    final chip = t.widget<mui.ActionChip>(find.byType(mui.ActionChip));
    debugPrint('[R1] 生产 chip.clipBehavior = ${chip.clipBehavior}');
    expect(
      chip.clipBehavior,
      kDanmakuChipClipBehavior,
      reason: '★ 探针与生产必须共用同一个源（kDanmakuChipClipBehavior）',
    );
    expect(
      chip.clipBehavior,
      Clip.none,
      reason: '★★★ 读数证明 Clip.antiAlias 会让环带峰值 +1.59 亮度级'
          '（详见 kDanmakuChipClipBehavior 上方的表格）。'
          '要改成 antiAlias 必须先用新读数推翻那份证据，不许凭假设改。',
    );
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 像素判据：生产值下**没有**比内部更亮的边
  // ══════════════════════════════════════════════════════════════════

  testWidgets('★★★ 生产值（Clip.none）下环带峰值不得超过内部 —— 即"没有亮边"',
      (t) async {
    setViewport(t);
    final (px, box) = await _renderChip(
      t,
      clipBehavior: kDanmakuChipClipBehavior,
      backdrop: black,
    );
    final r = _perimeter(px, box);
    debugPrint('[R1] prod(Clip.none) inner=${r.inner.toStringAsFixed(3)} '
        'edgeMean=${r.edgeMean.toStringAsFixed(3)} '
        'edgePeak=${r.edgePeak.toStringAsFixed(3)} '
        'Δpeak=${(r.edgePeak - r.inner).toStringAsFixed(3)} '
        'Δmean=${(r.edgeMean - r.inner).toStringAsFixed(3)} '
        'n_edge=${r.nEdge} n_inner=${r.nInner}');

    expect(
      r.edgePeak - r.inner,
      lessThanOrEqualTo(0.5),
      reason: '★★★ 环带里的最亮像素不得超过内部 0.5 亮度级 —— '
          '这就是"没有一圈更亮的边"的数字定义。'
          '实测 Δpeak=${(r.edgePeak - r.inner).toStringAsFixed(3)}',
    );
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ 反证：Clip.antiAlias 会**变差** —— 这条把证据钉死
  // ══════════════════════════════════════════════════════════════════

  testWidgets('★★★ 反证：Clip.antiAlias 让环带峰值明显抬升（不是修好，是变差）',
      (t) async {
    setViewport(t);
    final (pxNone, boxNone) = await _renderChip(
      t,
      clipBehavior: Clip.none,
      backdrop: black,
    );
    final (pxAa, boxAa) = await _renderChip(
      t,
      clipBehavior: Clip.antiAlias,
      backdrop: black,
    );
    final none = _perimeter(pxNone, boxNone);
    final aa = _perimeter(pxAa, boxAa);

    final dNone = none.edgePeak - none.inner;
    final dAa = aa.edgePeak - aa.inner;
    debugPrint('[R1] none   Δpeak=${dNone.toStringAsFixed(3)} '
        'Δmean=${(none.edgeMean - none.inner).toStringAsFixed(3)}');
    debugPrint('[R1] aa     Δpeak=${dAa.toStringAsFixed(3)} '
        'Δmean=${(aa.edgeMean - aa.inner).toStringAsFixed(3)}');

    expect(
      dAa,
      greaterThan(dNone),
      reason: '★★★ 这是任务书里那条推论的**反证**：裁剪把"两层互补"变成'
          '"上层半透明直接压视频"，边缘反而更亮。'
          '若这条变红，说明框架行为变了 —— 那时才应该回头复核 R1 的裁决。',
    );
    expect(
      dAa - dNone,
      greaterThan(0.5),
      reason: '★ 抬升必须是**可测的**（>0.5 亮度级），不是数值噪声。'
          '实测抬升 ${(dAa - dNone).toStringAsFixed(3)}',
    );
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ 稳定性：换 DPR 结论不变（真机 DPR 不是 1.0）
  // ══════════════════════════════════════════════════════════════════

  for (final dpr in <double>[1.25, 1.5, 2.0]) {
    testWidgets('★★ DPR=$dpr：生产值的 Δpeak 仍 <= 0.5', (t) async {
      setViewport(t);
      final (px, box) = await _renderChip(
        t,
        clipBehavior: kDanmakuChipClipBehavior,
        backdrop: black,
        dpr: dpr,
      );
      final r = _perimeter(px, box, band: 1.5 * dpr, innerFrom: 4.0 * dpr);
      final dp = r.edgePeak - r.inner;
      debugPrint('[R1] dpr=$dpr inner=${r.inner.toStringAsFixed(3)} '
          'edgePeak=${r.edgePeak.toStringAsFixed(3)} '
          'Δpeak=${dp.toStringAsFixed(3)}');
      expect(dp, lessThanOrEqualTo(0.5),
          reason: '★ DPR=$dpr 下也不许出现更亮的边（实测 Δpeak=${dp.toStringAsFixed(3)}）');
    });
  }
}
