// ═══════════════════════════════════════════════════════════════════════
//  第 14 项 · 弹幕**文字**边缘门禁（**只覆盖"毛边/发光"这一类**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 一句话
// ```text
// 本门禁只验一件事：**弹幕文字的"过渡坡"有没有被模糊/阴影糊宽**（毛边/发光）。
// 它**抓不到**锯齿、抓不到重影/双描边 —— 那两类的量具还没做出来，见 §覆盖边界。
// ```
//
// # ★★★ 为什么只剩一条判据（三版判据被自己的读数证伪的过程，留作路标）
// ```text
// 产品样式是 **白字 + 黑描边**（`danmaku_overlay.dart:318/330-341`：
// strokeW = max(2.0, fontSize*0.12)，先 stroke 后 fill）。
// 一幅图里因此有**两个**边界：背景→描边、描边→字芯。
// 而 chip 门禁（`zz_t66_r1_danmaku_chip_edge_test`）的「背景 / 过渡坡 / 实心」
// **单坡模型只对一个边界成立** ⇒ 文字这个对象上，头三版判据接连被证明无效：
//
//   版1「最陡相邻跃变 ≤ 120 ⇒ 硬边」
//       实测：正常样本 **206~231**（描边与字芯之间本来就是一步 ≈240 级）
//       ⇒ 连正常都判红。**删**。
//   版2「光晕宽度 = 从墨迹走到回到背景的距离」
//       实测：**26~38px** —— 量到的是**笔画宽度**，不是抗锯齿带。
//       ⇒ 换成「背景 / 过渡坡 / 实心」的单坡后才有意义（现在的 haloWidth）。
//   版3「字间缝隙不许停在 20%~80% 峰 ⇒ 重影」
//       实测：正常样本 **8 段**（把**描边自身的抗锯齿**数成了重影）；
//             发光样本 99 段 ⇒ 阈值取 0 会把正常判红，取 50 是拍数字。**删**。
//
//   另有「浅底暗环比」公式 `(bgL-ringPeak)/(bgL-coreMean)`：浅底实测 **2.7~2.96**
//   （>1.35 阈值）说明该定义不成立 ⇒ **删掉该判据**，只留作读数打印。
// ```
//
// # 唯一判据：过渡坡长 haloWidth（**上限**）
// ```text
// 定义：一行被切成 背景(d≤5%峰) / 过渡坡(5%~80%) / 实心(d≥80%)；
//       haloWidth = 夹在「背景」与「实心」之间那一段坡的**最长像素数**（物理像素, DPR=2）。
// 判据：haloWidth ≤ 4px。超了 ⇒ 边缘被 blur/shadow 糊宽 ⇒ 毛边/发光。
//
// 判别力（三组实测，同一舞台、同一 DPR）：
//   好样本（产品现状：字+描边）        haloWidth 1~2px
//   **发光样本**（fill 加 blur≈7.7px） haloWidth **8px**   ⇒ 判据能干净分开
//   硬描边样本（fill 的 AA 关掉）      haloWidth **1px**   ⇒ 与好样本**一样**（见下）
// ```
//
// # ★ 字体策略（2026-10-26）：**本门禁不依赖系统字体**，所以没有"缺字体"分支
// ```text
// 本文件用 flutter_test 的**默认测试字体 Ahem**（实心方块、无抗锯齿）当**受控基底**：
//   · 好处：任何平台都能跑，**没有** skip，也**没有**"缺字体 ⇒ 红"这种环境红；
//   · 代价：量到的是"方块边缘"的过渡坡，不是真实字形的（真实字形的同类判据见
//     `zz_t1024_danmaku_text_contour_test.dart`，那个文件需要真实字体）。
//
// ⚠️ 2026-10-26 实测过"把它换成真实字体 Arial"，结论是**不能换**：
//   换成 Arial 后 `+7 -1`，红的是**本条自己的仪器自检 ①**（加 blur 的样本）：
//     Ahem  上 haloWidth = 8.00px（远超 4px 阈值，说明判据抓得住毛边）；
//     Arial 上 haloWidth = 1.00px（低于阈值 ⇒ 自检失效）。
//   原因：Arial 字形笔画细，画 `blurRadius = fontSize*0.35` 的晕被"5% 峰"门槛切掉。
//   ⇒ **本判据的阈值与样本都是按 Ahem 标定的**；要换字体必须重新标定阈值
//   （那是另一个任务，不能顺手改）。这一格维持 Ahem，并把这件事写在这里，
//   免得后人再试一次、又红一次。
// ```
//
// # ★ 覆盖边界（四条，读日志的人必须先看这四条）
// ```text
// ① 只覆盖「毛边/发光」这一类（模糊把过渡坡糊宽）。
// ② **不覆盖锯齿 / 不覆盖关抗锯齿**：实测把 fill 的 `isAntiAlias=false` 之后
//    haloWidth 仍是 ~1px（与正常**相同**）⇒ 本门禁对"锯齿"零判别力。
//    因此"硬描边样本是绿的"**不构成**"描边被验过了"——它只是抓不到。
// ③ **不覆盖重影/双描边**（版3 的 midGap 已删；要做需换量具）。
// ④ `zz_t66_r1_danmaku_chip_edge_test` 只覆盖**胶囊边**，与本文**不互相替代**：
//    那条量的是 stadium 几何边界（单边界）；本文量的是文字笔画的栅格化过渡带。
// ```
//
// # 如需补齐 ②③，正确方向（未做，别照现在这套硬套）
// ```text
// 对每个字形取**连通域外轮廓**，沿轮廓**法向**采样亮度剖面 ⇒ 得到真实边缘
// 过渡坡（而不是整行扫描）；"抗锯齿是否生效"用**亚像素覆盖率的方差**，
// 而不是看坡长。工作量与不确定性都不小，本轮未做（如实登记为"量具未达标"）。
// ```
//
// # 跑法（**不带 tag**，进默认全量）
// ```powershell
// flutter test test/zz_t1024_danmaku_text_edge_test.dart --concurrency=1
// ```

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// 只为搭一个与产品一致的根（与 chip 门禁同一个 `mui.MaterialApp` 舞台）
import 'package:material_ui/material_ui.dart' as mui;

const Key kBoundary = ValueKey<String>('t1024-text-edge-boundary');

/// 被测字号（Owner 报的是"小字号也有毛边" ⇒ 必须包含 16 这种小字）
const List<double> kFontSizes = <double>[16, 22, 28];

const Color kDarkBackdrop = Color(0xFF101014);
const Color kLightBackdrop = Color(0xFFF2F3F5);

/// 故意用"有直笔、有撇、有钩"的字：糊宽最容易在斜笔上被看出来
const String kText = '永春糠斜';

/// 采样倍率：DPR=2 ⇒ 一个逻辑像素 4 个子像素
const double kDpr = 2.0;

/// **唯一判据**：过渡坡长上限（物理像素）。
///
/// 好样本实测 1~2px；加 blur≈7.7px 的样本实测 **8px** ⇒ 4px 取在两组之间、
/// 偏产品侧（留给产品一倍余量，不做"贴着好样本上界"的紧判据）。
const double kMaxHaloPx = 4.0;

// ══════════════════════════════════════════════════════════════════════
//  被测文字：样式配方**逐字复刻** `danmaku_overlay.dart:318-347`
// ══════════════════════════════════════════════════════════════════════

/// 生产里的描边宽度公式（`danmaku_overlay.dart:318`）
double _strokeWidth(double fontSize) => math.max(2.0, fontSize * 0.12);

double _lumaOfColor(Color c) =>
    0.299 * (c.r * 255) + 0.587 * (c.g * 255) + 0.114 * (c.b * 255);

class _TextCanvas extends StatelessWidget {
  const _TextCanvas({
    required this.text,
    required this.fontSize,
    required this.backdrop,
    this.disableAntiAlias = false,
    this.extraShadow = false,
  });

  final String text;
  final double fontSize;
  final Color backdrop;

  /// 自检/注入用：关掉 fill 的抗锯齿
  /// ⚠️ 本门禁**抓不到**它（读数与正常一样）；保留它只为把这件事钉成证据
  final bool disableAntiAlias;

  /// 自检/注入用：给 fill 加外发光（= 毛边/发光的真实形态）
  final bool extraShadow;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: backdrop,
      child: Center(
        child: RepaintBoundary(
          key: kBoundary,
          child: ColoredBox(
            color: backdrop,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: CustomPaint(
                size: const Size(220, 80),
                painter: _DanmakuTextPainter(
                  text: text,
                  fontSize: fontSize,
                  backdrop: backdrop,
                  disableAntiAlias: disableAntiAlias,
                  extraShadow: extraShadow,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DanmakuTextPainter extends CustomPainter {
  _DanmakuTextPainter({
    required this.text,
    required this.fontSize,
    required this.backdrop,
    required this.disableAntiAlias,
    required this.extraShadow,
  });

  final String text;
  final double fontSize;
  final Color backdrop;
  final bool disableAntiAlias;
  final bool extraShadow;

  late final bool _onDark = _lumaOfColor(backdrop) <= 128;
  late final TextPainter _fill = _buildFill();
  late final TextPainter _stroke = _buildStroke();

  TextPainter _buildFill() => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: _onDark ? const Color(0xFFFFFFFF) : const Color(0xFF101014),
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            shadows: extraShadow
                ? <Shadow>[
                    Shadow(
                      color: _onDark
                          ? const Color(0xCCFFFFFF)
                          : const Color(0xCC000000),
                      blurRadius: fontSize * 0.35,
                    ),
                  ]
                : null,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

  TextPainter _buildStroke() {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth(fontSize)
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = !disableAntiAlias
      ..color = (_onDark ? const Color(0xFF000000) : const Color(0xFF101014))
          .withValues(alpha: 0.85);
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          foreground: paint,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final dy = (size.height - _fill.height) / 2;
    _stroke.paint(canvas, Offset(0, dy));
    _fill.paint(canvas, Offset(0, dy));
  }

  @override
  bool shouldRepaint(_DanmakuTextPainter old) => true;
}

typedef Pixels = ({Uint8List rgba, int width, int height});

double _lumaAt(Pixels p, int x, int y) {
  if (x < 0 || y < 0 || x >= p.width || y >= p.height) return double.nan;
  final i = (y * p.width + x) * 4;
  return 0.299 * p.rgba[i] + 0.587 * p.rgba[i + 1] + 0.114 * p.rgba[i + 2];
}

Future<Pixels> _render(
  WidgetTester t, {
  required double fontSize,
  required Color backdrop,
  bool disableAntiAlias = false,
  bool extraShadow = false,
}) async {
  await t.pumpWidget(mui.MaterialApp(
    debugShowCheckedModeBanner: false,
    home: mui.Scaffold(
      backgroundColor: backdrop,
      body: _TextCanvas(
        text: kText,
        fontSize: fontSize,
        backdrop: backdrop,
        disableAntiAlias: disableAntiAlias,
        extraShadow: extraShadow,
      ),
    ),
  ));
  await t.pumpAndSettle();
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(kBoundary));
  late Pixels px;
  await t.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: kDpr);
    final ByteData? bd =
        await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    px = (rgba: bd!.buffer.asUint8List(), width: img.width, height: img.height);
    img.dispose();
  });
  return px;
}

/// 读数：**只判 haloWidth**；另三个数是**读数**（失败时按纪律必须打印出来）
class EdgeReading {
  EdgeReading({
    required this.fontSize,
    required this.onDark,
    required this.ringPeak,
    required this.coreMean,
    required this.ratio,
    required this.haloWidth,
    required this.inkPixels,
  });

  final double fontSize;
  final bool onDark;
  final double ringPeak;
  final double coreMean;
  final double ratio;
  final double haloWidth;
  final int inkPixels;

  String get fourNumbers => '环带峰值=${ringPeak.toStringAsFixed(1)} '
      '内部均值=${coreMean.toStringAsFixed(1)} '
      '比值=${ratio.toStringAsFixed(3)} '
      '阈值=haloWidth<=$kMaxHaloPx';

  String get diagnostics =>
      'haloWidth=${haloWidth.toStringAsFixed(2)}px ink=$inkPixels';

  String get tag => '${fontSize.toInt()}px/${onDark ? "深底" : "浅底"}';
}

EdgeReading _measure(
    Pixels p, {required double fontSize, required Color backdrop}) {
  final onDark = _lumaOfColor(backdrop) <= 128;

  // ── 背景亮度：四角 8x8 的中位 ──
  final corners = <double>[];
  for (final o in <(int, int)>[
    (0, 0),
    (p.width - 8, 0),
    (0, p.height - 8),
    (p.width - 8, p.height - 8),
  ]) {
    for (var dy = 0; dy < 8; dy++) {
      for (var dx = 0; dx < 8; dx++) {
        final v = _lumaAt(p, o.$1 + dx, o.$2 + dy);
        if (!v.isNaN) corners.add(v);
      }
    }
  }
  corners.sort();
  final bgL = corners[corners.length ~/ 2];

  var dMax = 0.0;
  var ink = 0;
  var coreSum = 0.0;
  var coreN = 0;
  for (var y = 0; y < p.height; y++) {
    for (var x = 0; x < p.width; x++) {
      final l = _lumaAt(p, x, y);
      if (l.isNaN) continue;
      final d = (l - bgL).abs();
      if (d > dMax) dMax = d;
      if (d >= 0.8 * dMax) {
        ink++;
        coreSum += l;
        coreN++;
      }
    }
  }
  final coreMean = coreN == 0 ? bgL : coreSum / coreN;

  // 环带峰值（**只作读数**，不作判据 —— 理由见文件头版1/浅底 ratio 段）
  var ringPeak = onDark ? double.negativeInfinity : double.infinity;
  for (var y = 0; y < p.height; y++) {
    for (var x = 0; x < p.width; x++) {
      final l = _lumaAt(p, x, y);
      if (l.isNaN) continue;
      final d = (l - bgL).abs();
      if (d > 0 && d < 0.2 * dMax) {
        if (onDark) {
          if (l > ringPeak) ringPeak = l;
        } else {
          if (l < ringPeak) ringPeak = l;
        }
      }
    }
  }
  if (ringPeak.isInfinite) ringPeak = coreMean;

  // ── 唯一判据：过渡坡长 ──
  var halo = 0.0;
  final bgCut = 0.05 * dMax;
  final inkCut = 0.80 * dMax;
  for (var y = 0; y < p.height; y++) {
    final row = <double>[
      for (var x = 0; x < p.width; x++) (_lumaAt(p, x, y) - bgL).abs(),
    ];
    for (var x = 1; x < row.length - 1; x++) {
      if (row[x] <= bgCut || row[x] >= inkCut) continue;
      if (row[x - 1] > bgCut) continue;
      var k = x;
      while (k < row.length && row[k] > bgCut && row[k] < inkCut) {
        k++;
      }
      if (k < row.length && row[k] >= inkCut) {
        final len = (k - x).toDouble();
        if (len > halo) halo = len;
      }
      x = k;
    }
  }

  final ratio = onDark
      ? ringPeak / math.max(1.0, coreMean)
      : (bgL - ringPeak) / math.max(1.0, bgL - coreMean);
  return EdgeReading(
    fontSize: fontSize,
    onDark: onDark,
    ringPeak: ringPeak,
    coreMean: coreMean,
    ratio: ratio,
    haloWidth: halo,
    inkPixels: ink,
  );
}

void main() {
  for (final size in kFontSizes) {
    for (final backdrop in <Color>[kDarkBackdrop, kLightBackdrop]) {
      final tag =
          '${size.toInt()}px/${_lumaOfColor(backdrop) <= 128 ? "深底" : "浅底"}';
      testWidgets('文字边缘 $tag：过渡坡不许被糊宽（haloWidth ≤ $kMaxHaloPx px）',
          (t) async {
        final px = await _render(t, fontSize: size, backdrop: backdrop);
        final r = _measure(px, fontSize: size, backdrop: backdrop);

        // 前置：真的画出字了（否则"没糊宽"是因为没有字 —— 假绿）
        expect(r.inkPixels, greaterThan(200),
            reason: '前置失效：$tag 墨迹只有 ${r.inkPixels} 像素 ⇒ 压根没渲染出字。\n'
                '${r.fourNumbers} | ${r.diagnostics}');

        expect(r.haloWidth, lessThanOrEqualTo(kMaxHaloPx),
            reason: '★ 毛边/发光：$tag 的过渡坡宽达 '
                '${r.haloWidth.toStringAsFixed(2)}px（> $kMaxHaloPx）\n'
                '${r.fourNumbers}\n${r.diagnostics}\n'
                '好样本实测 1~2px、加 blur≈7.7px 实测 8px ⇒ 超过 4px 说明边缘'
                '被模糊/阴影糊宽（Owner 第 14 项"毛边"这一类）。\n'
                '⚠️ 本门禁**不覆盖**锯齿与重影，见文件头 §覆盖边界。');

        // ignore: avoid_print
        print('T1024_EDGE|$tag|产品现状|${r.fourNumbers}|${r.diagnostics}');
      });
    }
  }

  // ══════════════════════════════════════════════════════════════════
  //  仪器自检（永久可复跑）：把"能抓 / 抓不到"两件事都钉成证据
  // ══════════════════════════════════════════════════════════════════
  testWidgets('仪器自检 ①：加外发光（毛边形态）⇒ 过渡坡必须超过阈值', (t) async {
    final px = await _render(
      t,
      fontSize: 22,
      backdrop: kDarkBackdrop,
      extraShadow: true,
    );
    final r = _measure(px, fontSize: 22, backdrop: kDarkBackdrop);
    // ignore: avoid_print
    print('T1024_EDGE|发光样本(应红)|${r.fourNumbers}|${r.diagnostics}');
    expect(r.haloWidth, greaterThan(kMaxHaloPx),
        reason: '★★ 仪器失效：加 ${(22 * 0.35).toStringAsFixed(1)}px blur 外发光后'
            '过渡坡只有 ${r.haloWidth.toStringAsFixed(2)}px（≤ $kMaxHaloPx）⇒ '
            '本门禁抓不到"毛边"，上面那批绿没有意义。\n'
            '${r.fourNumbers}\n${r.diagnostics}');
  });

  testWidgets('仪器自检 ②：关掉抗锯齿 ⇒ 读数与好样本**同级**（本门禁抓不到它）',
      (t) async {
    final bad = await _render(
      t,
      fontSize: 22,
      backdrop: kDarkBackdrop,
      disableAntiAlias: true,
    );
    final good = await _render(
      t,
      fontSize: 22,
      backdrop: kDarkBackdrop,
    );
    final rb = _measure(bad, fontSize: 22, backdrop: kDarkBackdrop);
    final rg = _measure(good, fontSize: 22, backdrop: kDarkBackdrop);
    // ignore: avoid_print
    print('T1024_EDGE|硬描边样本(抓不到,应绿)|haloWidth='
        '${rb.haloWidth.toStringAsFixed(2)}px（好样本='
        '${rg.haloWidth.toStringAsFixed(2)}px）|${rb.fourNumbers}|${rb.diagnostics}');

    /*
     * ★ 这条**不是**"描边被验过了"，而是把「本门禁抓不到锯齿」钉成证据：
     *   坏样本的读数必须与好样本**同级**（都 ≤ 阈值）。若将来它超阈值，
     *   说明仪器其实能抓到锯齿 —— 那是好事，但要**如实改注释**（见 reason）。
     * ⚠️ 读日志的人：看到这条绿**不要**以为"关抗锯齿也被抓住了"。
     */
    expect(rb.haloWidth, lessThanOrEqualTo(kMaxHaloPx),
        reason: '★★ 与文件头 §覆盖边界② 不符：关掉抗锯齿后读数 '
            '${rb.haloWidth.toStringAsFixed(2)}px 超过了阈值 —— '
            '那说明本门禁其实能抓到锯齿，请把 §覆盖边界② 改成"能抓"。\n'
            '${rb.fourNumbers}\n${rb.diagnostics}');
  });
}
