// ═══════════════════════════════════════════════════════════════════════
//  第 14 项 · 弹幕文字边缘「硬度 / 加厚」门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 与 `zz_t1024_danmaku_text_edge_test.dart` 的分工（不重复、不互相替代）
// ```text
// 那条（edge）：量"**坡有多宽**"  —— 毛边 / 发光（过渡坡 ≤4px）。
// 这条（contour）：量"**边缘有没有被加硬 / 加厚**" ——
//                 二值化（边缘变硬）、描边加厚、重影位移。
// 判据对象不同：那条看**一维过渡坡长**；这条看**连通域几何 + 覆盖率分布**。
// ```
//
// # 两条判据（每条都写明"为什么这么定"的实测依据）
// ```text
// ① 边缘被**二值化**（部分覆盖像素消失）：
//      partialFrac = 边界带（轮廓外扩 2px）上 alpha 在 (5%,95%) 的像素占比
//      正常 0.112~0.117；二值化样本 0.000 ⇒ 阈值 < 0.03（4 倍间距）
//
// ② 边缘被**描边加厚** / 被**重影**拉开：
//      impliedW = (area - refArea) / refContour     （单位=像素，有物理量纲）
//      refArea = **同一轮**渲染的"同字体同字号纯 fill"（必须同轮，不能跨轮）
//      实测（本文件口径）：1px 描边 ⇒ 0.94 / 1.22；2px 重影 ⇒ 1.74 / 1.88
//      ⇒ 阈值 ≤ 0.5px（对注入真值 1px/2px 的偏差 ≤0.26px，留 2.5 倍余量）
// ```
//
// # ★★★ 一处必须说清的边界：①（锯齿）这条**不是**"引擎抗锯齿开关"
// ```text
// 实测：`TextStyle(foreground: Paint()..isAntiAlias = false)` 对**文字**渲染
//       完全无效 —— 我把它当"关抗锯齿"跑过，与正常样本**逐位相同**
//       （partialFrac 0.117=0.117、area 492=492、contour 148=148、levels 16=16）。
//       文字走字形位图缓存，不吃 Paint 的 AA 开关
//       ⇒ "真关引擎 AA"这个形态**在生产里可能根本不可达**。
// ⇒ 本门禁的断言文案是「**边缘被二值化**（5%~95% 部分覆盖像素≈0）」，
//   而不是「抗锯齿被关」。它守的是"边缘变硬"这个**可观测现象**：
//   只要输出退化成 0/1 两档（换渲染路径 / 关字形平滑 / 硬边遮罩后处理）就红。
//   我造 ① 样本的方式也是**后处理二值化**（alpha 在 0.5 处二分），
//   而不是真的关掉引擎 AA —— 后者在 flutter_test 里做不到。
// ```
//
// # 判别力矩阵**内置**（门禁自带红度证明，不依赖外部注入）
// ```text
// 每一档字号都跑四个样本：
//   ① 纯 fill（参考）      ⇒ partialFrac >=0.03 且 impliedW 正常（不越界）
//   ② 二值化（后处理）      ⇒ partialFrac <0.03（越界：边缘被加硬）
//   ③ 纯 fill + 1px 硬描边  ⇒ impliedW >0.5（越界：边缘被加厚）
//   ④ 纯 fill 两遍偏移 2px  ⇒ impliedW >0.5（越界：重影）
// 四条都成立 ⇒ 这台仪器**能**分辨四类；任一不成立 ⇒ 仪器坏了（红），
// 而不是"产品没问题"。
// ```
//
// # 产品侧（第 2 层）：声明描边 vs 实测加厚
// ```text
// 生产样式本来就带一圈黑描边（`danmaku_overlay.dart:318`：
// strokeW = max(2.0, fontSize*0.12)）⇒ 产品的 impliedW 本来就该 ≈ 这个值
// （22px→2.64、56px→6.72；实测 2.54 / 7.09）。
// ⇒ 产品断言不是"≤0.5"（那会永远红，因为描边是有意的），而是：
//      impliedW <= 声明描边 * 1.10 + 0.5px
//    多出来的部分 = 有人额外加了 shadow / 第二层描边 / 发光。
//
// # 为什么不是"乘 1.35"（实测否掉的）
//   56px 声明 6.72 * 1.35 = 9.07，实测 7.09 ⇒ 余量 1.98px > 1px
//   ⇒ 加一层 1px 描边仍然绿（抓不到）。
//   换成"*1.10（吸收估计器在大字号的系统偏差 +5.5%）+ 绝对 0.5px"后：
//   22px 上限 3.40（实测 2.54，余量 0.86）；56px 上限 7.89（实测 7.09，余量 0.80）
//   加 1px 描边（+0.94 / +1.22）分别到 ≈3.48 / ≈8.31 ⇒ 两档都红。
// ```
//
// # ⚠️ 本文件的一处来历（blame 到这段不会困惑）
// ```text
// 2026-10-26 00:5x：我在给本文件加"产品侧绝对余量"时，用脚本按锚点做替换，
//   锚点匹配到了文件头的注释行 ⇒ **误删了 94~498 行**（约 400 行）。
//   发现后整份重写（内容与本文件当前形态一致），随后 analyze 0 error/0 warning、
//   门禁复跑绿。因此这一段没有历史增量 diff，**不是**谁故意重写。
// ```
//
// # ★ 附：早期用"算术推演"回答"加 1px 会不会红"，结论**仅供参考**
// ```text
// 下面的表是**推演，不是断言**；真正的证据是第 ⑤ 条断言里的**合成样本**
// （渲染生产样式 → 掩膜膨胀 1px → 实测 impliedW）。
// 推演之所以不可靠：22px 上推演差 0.08px，实测差 0.013px，都贴着阈值 ⇒
// 任何"擦线的算术"都不能当判据。表留在这里只是让人知道当初怎么想的：
//   字号 | 声明 | 上限(×1.10+0.5) | 生产实测 | 余量 | 推演"加1px" | 超出
//   22px | 2.64 | 3.404            | 2.54      | 0.86 | 3.48          | 0.08(擦线)
//   56px | 6.72 | 7.892            | 7.09      | 0.80 | 8.31          | 0.42
// 实测（0.5 时期）：22px ⑤=3.39 ⇒ **没越过 3.404**；56px ⑤=8.00 ⇒ 越过 0.11
// ⇒ 据此把 slack 收到 0.35（有证据的收紧，见 kDeclaredStrokeSlackPx 注释）。
// ```
//
// # 跑法（不带 tag，进默认全量）
// ```powershell
// flutter test test/zz_t1024_danmaku_text_contour_test.dart --concurrency=1
// ```
//
// # 环境依赖（缺字体 => **fail**，不 skip、不假装通过）
// ```text
// 需要一款真实字体（默认测试字体 Ahem 是实心方块、无抗锯齿 => 本文件的判据会失真）。
// 候选 `kFontCandidates` 覆盖三平台（CI 有 macOS / Linux 的 test job）：
//   Windows：C:/Windows/Fonts/arialbd.ttf -> arial.ttf -> segoeui.ttf -> seguisb.ttf
//   macOS  ：/System/Library/Fonts/Supplemental/Arial Bold.ttf -> Arial.ttf -> /System/Library/Fonts/SFNS.ttf
//   Linux  ：/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf -> DejaVuSans.ttf
//            -> liberation/LiberationSans-Bold.ttf -> liberation2/...
// 一条都没有 => **fail**（不是 markTestSkipped）：与 `test/support/core_gate.dart`
// 的既有约定一致 —— "门禁跑不起来"必须**可见**，否则 CI 结论会从"红"变成
// "绿（有 N 项跳过）"，一个跑不了的门禁可以一路混进发布。
// ⚠️ 判据本身是**归一的**（`impliedW = Δarea / refContour`，约等于边缘平均加厚
// 的像素数）=> 换字体不影响"1px 描边必须越界"这类结论；但阈值是按 Arial Bold
// 实测标定的，换字体后第一次跑应当核对矩阵读数。
// ```

// # 跑法（不带 tag，进默认全量）
// ```powershell
// flutter test test/zz_t1024_danmaku_text_contour_test.dart --concurrency=1
// ```
//
// # 环境依赖（缺件时明确 skip，不假装通过）
// ```text
// 需要一款真实字体（默认测试字体 Ahem 是实心方块、无抗锯齿 ⇒ ① 的判据会失真）。
// 候选：C:/Windows/Fonts/arialbd.ttf -> arial.ttf -> segoeui.ttf。
// 一个都没有 ⇒ markTestSkipped 并写明缺什么 + 替代覆盖在哪
// （CI windows-latest 有 Arial）。
// ```

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

const Key kBoundary = ValueKey<String>('t1024-text-contour-boundary');
const String kProbeFont = 'ContourProbeFont';
const double kDpr = 2.0;
const String kGlyph = 'A';
const Color kDark = Color(0xFF101014);

/// ① 的阈值：二值化判据（正常 0.112~0.117 ⇒ 4 倍间距）
const double kMaxPartialFrac = 0.03;

/// ② 的阈值：加厚/重影（实测注入 1px→0.94/1.22、2px→1.74/1.88 ⇒ 2.5 倍余量）
const double kMaxImpliedW = 0.5;

/// 产品侧容差：impliedW <= 声明描边 * kDeclaredStrokeScale + kDeclaredStrokeSlackPx
///
/// 推导见文件头（乘性容差在 56px 上会放过 1px 额外描边）。
const double kDeclaredStrokeScale = 1.10;

/// 产品侧绝对余量。**2026-10-26 由 0.5 收紧到 0.35 —— 这是有证据的收紧**
///
/// ```text
/// ⑤（生产 + 1px 膨胀，真样本）在 0.5 下的实测：
///   22px：⑤=3.39 vs 上限 3.404 ⇒ **差 0.013px 抓不到**（红）
///   56px：⑤=8.00 vs 上限 7.892 ⇒ 抓到 0.11px（勉强）
/// ⇒ 0.5 在 22px 上太松。收紧到 0.35 后（上限 = 声明*1.10+0.35）：
///   22px：上限 3.254；生产 2.54（余量 0.714）；⑤ 3.39（超出 0.136）✓
///   56px：上限 7.742；生产 7.09（余量 0.652）；⑤ 8.00（超出 0.258）✓
/// 两档都"正常不越界 + 加1px必越界"同时成立。
/// ⚠️ 以后调这个数，必须重跑 ⑤ 这条断言（它是唯一的证据来源）。
/// ```
const double kDeclaredStrokeSlackPx = 0.35;

/// 收紧前用过的值（留档：如果哪天 ⑤ 因为产品真变了而红，先回看这里）
const double kDeclaredStrokeSlackBeforeTighten = 0.5;

/// 分母（同轮"1px 单位"）的最低可信值：低于它就是没量出来，不许拿它做除法
const double kMinUnitPx = 0.4;

/// 产品"比声明描边多出来"的允许量（**单位 = 同轮 1px 膨胀造成的加厚量 U**）
///
/// ```text
/// excessUnits = (impliedW(prod) - 声明描边*1.10) / U
///   · 上限 0.5：多出来的不到半个 1px 单位 ⇒ 抓得到"再加一层 1px"
///     （lead 原话是 <1.0；但"参考+1px"当样本时 excessUnits 恰好 ≡1.0，
///      取 1.0 就判不出来 —— 见 main() 里 ④ 的说明。这里取 0.5，
///      等价于原 0.35px 余量在 Arial 上的折算：0.35/0.94≈0.37、0.35/1.22≈0.29）
///   · 下限 -0.5：也不许比声明描边更薄（抓"描边被删掉/变细"）
/// ⇒ 两者都是**无量纲**，换字体/字号/DPR 时 U 同步变化 ⇒ 阈值自动跟着走。
/// ```
/// 阈值**实测标定**（2026-10-26，Arial Bold，U 实测 0.99 / 1.00 px）：
/// ```text
///                              22px      56px    余量
/// 产品 excessUnits            -0.368    -0.302   距上限 0.82 / 0.75，距下限 0.43 / 0.50
/// 注入：参考换成"参考+1px"      -1.94     -6.41    远低于下限 ⇒ 必红（薄侧）
/// 自证：生产+1px                0.491     0.608   超上限 0.04 / 0.16 ⇒ 必红
/// ⇒ 上限取 0.45（不是 0.5）：0.5 时 22px 的"生产+1px"=0.491 **差 0.009 抓不到**。
/// ```
const double kExcessUpperBound = 0.45;
const double kExcessLowerBound = -0.8;

/// 字号档（22/56：小字与中字，两种轮廓长度）
const List<double> kSizes = <double>[22, 56];

/// 生产描边宽度公式（`danmaku_overlay.dart:318`）
double _declaredStroke(double fontSize) => math.max(2.0, fontSize * 0.12);

// ── 五种样本 ─────────────────────────────────────────────────────────
enum Sample {
  /// 纯 fill（参考基线）
  fillOnly,

  /// 二值化（后处理）—— 代表"边缘被加硬"的输出形态
  binarized,

  /// 纯 fill + 1px 硬描边
  stroke1px,

  /// 纯 fill 两遍，偏移 2px —— 重影
  ghost2px,

  /// 生产样式：fill + 声明描边（strokeW = max(2, fs*0.12)）
  production,

  /// **生产样式 + 1px 膨胀**（掩膜 4 邻域膨胀 1px 再合成）
  ///
  /// 自证样本之一：直接回答"若把生产改成再加一层 1px 描边，这条门禁会不会红"。
  productionPlus1px,

  /// **参考 + 1px 膨胀** —— 本文件**新的分母**（字体无关的"1px 单位"）
  ///
  /// ```text
  /// 2026-10-26（lead 要求把绝对阈值改成同轮相对量）：
  ///   原来的上限是 `声明描边*1.10 + 0.35` 这样的**绝对像素常数**，标定自
  ///   Arial Bold —— 换字体（CI 落到 DejaVu/Liberation）就可能不成立。
  ///   ⇒ 改成"用**这台机器、这个字体、这个 DPR** 下 1px 膨胀实际造成的加厚量"
  ///     当单位：`U = impliedW(ref+1px)`。判据变成无量纲量（见 kExcessUpperBound）。
  /// ```
  refPlus1px,

  /// **参考 + 2px 膨胀** —— 线性度诊断（`impliedW(ref+2px) ≈ 2 * U`）
  ///
  /// 这条不参与产品判定，只用来自证"U 是线性的、不是噪声"：
  /// 若 2px 的加厚量不≈2U，说明我把膨胀量测歪了（例如轮廓取错）。
  refPlus2px,
}

String _sampleName(Sample s) => switch (s) {
      Sample.fillOnly => '①纯fill(参考)',
      Sample.binarized => '②二值化(边缘变硬)',
      Sample.stroke1px => '③1px硬描边',
      Sample.ghost2px => '④2px重影',
      Sample.production => '★生产样式',
      Sample.productionPlus1px => '⑤生产+1px膨胀',
      Sample.refPlus1px => '⑥参考+1px膨胀(分母U)',
      Sample.refPlus2px => '⑦参考+2px膨胀(线性度)',
    };

class _Painter extends CustomPainter {
  _Painter({required this.sample, required this.fontSize});

  final Sample sample;
  final double fontSize;

  TextPainter _tp({double? strokeW, bool strokeAa = true}) {
    const ink = Color(0xFFFFFFFF);
    final style = strokeW == null
        ? TextStyle(color: ink, fontSize: fontSize, fontFamily: kProbeFont)
        : TextStyle(
            fontSize: fontSize,
            fontFamily: kProbeFont,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeW
              ..strokeJoin = StrokeJoin.round
              ..isAntiAlias = strokeAa
              ..color = ink,
          );
    return TextPainter(
      text: TextSpan(text: kGlyph, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
  }

  @override
  void paint(Canvas c, Size s) {
    const o = Offset(16, 16);
    switch (sample) {
      case Sample.fillOnly:
      case Sample.binarized: // 先正常画，二值化在截图后做
      case Sample.refPlus1px: // 先画纯 fill，膨胀在截图后做
      case Sample.refPlus2px:
        _tp().paint(c, o);
      case Sample.stroke1px:
        _tp(strokeW: 1.0, strokeAa: false).paint(c, o);
        _tp().paint(c, o);
      case Sample.ghost2px:
        _tp().paint(c, o);
        _tp().paint(c, o + const Offset(2, 2));
      case Sample.production:
      case Sample.productionPlus1px: // 先按生产样式画，膨胀在截图后做
        _tp(strokeW: _declaredStroke(fontSize)).paint(c, o);
        _tp().paint(c, o);
    }
  }

  @override
  bool shouldRepaint(_Painter o) => true;
}

typedef Pixels = ({Uint8List rgba, int w, int h});

Future<Pixels> _shot(WidgetTester t, Sample sample, double fontSize) async {
  await t.pumpWidget(mui.MaterialApp(
    debugShowCheckedModeBanner: false,
    home: mui.Scaffold(
      backgroundColor: kDark,
      body: Center(
        child: RepaintBoundary(
          key: kBoundary,
          child: ColoredBox(
            color: kDark,
            child: SizedBox(
              width: fontSize * 2.4 + 40,
              height: fontSize * 2.0 + 40,
              child: CustomPaint(
                painter: _Painter(sample: sample, fontSize: fontSize),
              ),
            ),
          ),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
  final b = t.renderObject<RenderRepaintBoundary>(find.byKey(kBoundary));
  late Pixels px;
  await t.runAsync(() async {
    final img = await b.toImage(pixelRatio: kDpr);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    px = (rgba: bd!.buffer.asUint8List(), w: img.width, h: img.height);
    img.dispose();
  });
  if (sample == Sample.binarized) px = _binarize(px);
  if (sample == Sample.productionPlus1px) px = _dilate1px(px, times: 1);
  if (sample == Sample.refPlus1px) px = _dilate1px(px, times: 1);
  if (sample == Sample.refPlus2px) px = _dilate1px(px, times: 2);
  return px;
}

/// 掩膜 4 邻域膨胀 [times] 次，新增像素填墨色 —— 等价于"再加 [times] 层 1px 描边"
///
/// ⚠️ 两个实现坑（都被 linearity 诊断抓到过，留作路标）：
/// ```text
/// ① `inkAt` 算在循环外 ⇒ 第二次迭代的"新增像素"已经在掩膜里 ⇒ 实际只膨胀 1 次；
/// ② 更隐蔽：`alpha()` 读的是**原始** px.rgba，而我往 `out` 里写 ⇒ 每次迭代
///    看到的掩膜都一样 ⇒ times:2 仍然等于 times:1（linearity 读 1.00 而不是 ~2）。
/// ⇒ 正确做法：**每轮从当前 out 重新估 alpha**，逐轮推进。
/// ```
Pixels _dilate1px(Pixels px, {int times = 1}) {
  final w = px.w, h = px.h;
  var out = Uint8List.fromList(px.rgba);
  for (var k = 0; k < times; k++) {
    // 本轮快照：alpha 只读它，写只写 out ⇒ 每轮都在上一轮的结果上推进
    final src = Uint8List.fromList(out);
    final corners = <double>[
      _lumAt(src, w, 2, 2),
      _lumAt(src, w, w - 3, 2),
      _lumAt(src, w, 2, h - 3),
      _lumAt(src, w, w - 3, h - 3),
    ]..sort();
    final bg = corners[1];
    var inkL = bg, far = 0.0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final d = (_lumAt(src, w, x, y) - bg).abs();
        if (d > far) {
          far = d;
          inkL = _lumAt(src, w, x, y);
        }
      }
    }
    double alpha(int x, int y) {
      if (x < 0 || y < 0 || x >= w || y >= h) return 0;
      if (far < 1) return 0;
      return ((_lumAt(src, w, x, y) - bg) / (inkL - bg)).clamp(0.0, 1.0);
    }

    final edge = <int>[];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (alpha(x, y) < 0.5) continue;
        var isEdge = x == 0 || y == 0 || x == w - 1 || y == h - 1;
        if (!isEdge) {
          for (final o in _k4) {
            if (alpha(x + o.$1, y + o.$2) < 0.5) {
              isEdge = true;
              break;
            }
          }
        }
        if (isEdge) edge.add(y * w + x);
      }
    }
    for (final i in edge) {
      final x = i % w, y = i ~/ w;
      for (final o in _k4) {
        final xx = x + o.$1, yy = y + o.$2;
        if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
        if (alpha(xx, yy) >= 0.5) continue;
        final j = (yy * w + xx) * 4;
        out[j] = 0xFF;
        out[j + 1] = 0xFF;
        out[j + 2] = 0xFF;
        out[j + 3] = 255;
      }
    }
  }
  return (rgba: out, w: w, h: h);
}

/// 4 邻域偏移常量（膨胀用）
const List<(int, int)> _k4 = <(int, int)>[(1, 0), (-1, 0), (0, 1), (0, -1)];

/// 读某个 RGBA 缓冲在 (x,y) 的亮度
double _lumAt(Uint8List buf, int w, int x, int y) {
  final j = (y * w + x) * 4;
  return 0.299 * buf[j] + 0.587 * buf[j + 1] + 0.114 * buf[j + 2];
}

/// 把图二值化：alpha<0.5 到背景色，其余到墨色
///
/// ★ 这是造"边缘被加硬"样本的手段，不是"关引擎 AA"（后者做不到，见文件头）。
Pixels _binarize(Pixels px) {
  final out = Uint8List.fromList(px.rgba);
  final w = px.w, h = px.h;
  double lum(int i) =>
      0.299 * out[i] + 0.587 * out[i + 1] + 0.114 * out[i + 2];
  final corners = <double>[
    lum((2 * w + 2) * 4),
    lum((2 * w + w - 3) * 4),
    lum(((h - 3) * w + 2) * 4),
    lum(((h - 3) * w + w - 3) * 4),
  ]..sort();
  final bg = corners[1];
  var ink = bg, far = 0.0;
  for (var i = 0; i < w * h; i++) {
    final d = (lum(i * 4) - bg).abs();
    if (d > far) {
      far = d;
      ink = lum(i * 4);
    }
  }
  for (var i = 0; i < w * h; i++) {
    final a = far < 1 ? 0.0 : ((lum(i * 4) - bg) / (ink - bg)).clamp(0.0, 1.0);
    final j = i * 4;
    if (a < 0.5) {
      out[j] = 0x10;
      out[j + 1] = 0x10;
      out[j + 2] = 0x14;
    } else {
      out[j] = 0xFF;
      out[j + 1] = 0xFF;
      out[j + 2] = 0xFF;
    }
    out[j + 3] = 255;
  }
  return (rgba: out, w: w, h: h);
}

/// 一份样本的读数
class Reading {
  Reading({
    required this.sample,
    required this.fontSize,
    required this.partialFrac,
    required this.area,
    required this.contour,
  });

  final Sample sample;
  final double fontSize;
  final double partialFrac;
  final int area;
  final int contour;

  /// 相对参考的"平均加厚像素数"（由 withRef 填入）
  double impliedW = 0;

  Reading withRef(Reading ref) {
    impliedW = ref.contour == 0 ? 0 : (area - ref.area) / ref.contour;
    return this;
  }

  String get line => 'TC|${fontSize.toInt()}px|${_sampleName(sample)}|'
      'partialFrac=${partialFrac.toStringAsFixed(3)} '
      'area=$area contour=$contour impliedW=${impliedW.toStringAsFixed(2)}px';
}

/// 连通域（4 连通最大块）+ 轮廓 + 边界带部分覆盖占比
Reading _analyze(Pixels px, Sample sample, double fontSize) {
  final w = px.w, h = px.h, r = px.rgba;
  double lum(int x, int y) {
    final j = (y * w + x) * 4;
    return 0.299 * r[j] + 0.587 * r[j + 1] + 0.114 * r[j + 2];
  }

  final corners = <double>[
    lum(2, 2),
    lum(w - 3, 2),
    lum(2, h - 3),
    lum(w - 3, h - 3),
  ]..sort();
  final bg = corners[1];
  var inkL = bg, far = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final d = (lum(x, y) - bg).abs();
      if (d > far) {
        far = d;
        inkL = lum(x, y);
      }
    }
  }
  final denom = inkL - bg;
  double alpha(int x, int y) =>
      denom.abs() < 1 ? 0 : ((lum(x, y) - bg) / denom).clamp(0.0, 1.0);

  final mask = List<bool>.filled(w * h, false);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (alpha(x, y) >= 0.5) mask[y * w + x] = true;
    }
  }
  final seen = List<bool>.filled(w * h, false);
  final comp = List<bool>.filled(w * h, false);
  var bestArea = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i0 = y * w + x;
      if (!mask[i0] || seen[i0]) continue;
      final stack = <int>[i0];
      seen[i0] = true;
      final cells = <int>[];
      while (stack.isNotEmpty) {
        final i = stack.removeLast();
        cells.add(i);
        final cx = i % w;
        for (final d in <int>[1, -1, w, -w]) {
          final j = i + d;
          if (j < 0 || j >= w * h) continue;
          if ((d == 1 && cx == w - 1) || (d == -1 && cx == 0)) continue;
          if (!mask[j] || seen[j]) continue;
          seen[j] = true;
          stack.add(j);
        }
      }
      if (cells.length > bestArea) {
        bestArea = cells.length;
        comp.fillRange(0, comp.length, false);
        for (final i in cells) {
          comp[i] = true;
        }
      }
    }
  }

  bool isEdge(int x, int y) {
    final i = y * w + x;
    if (!comp[i]) return false;
    if (x == 0 || y == 0 || x == w - 1 || y == h - 1) return true;
    for (final d in <int>[1, -1, w, -w]) {
      if (!comp[i + d]) return true;
    }
    return false;
  }

  var contour = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (isEdge(x, y)) contour++;
    }
  }

  var band = 0, partial = 0;
  for (var y = 2; y < h - 2; y++) {
    for (var x = 2; x < w - 2; x++) {
      var near = false;
      for (var dy = -2; dy <= 2 && !near; dy++) {
        for (var dx = -2; dx <= 2 && !near; dx++) {
          if (isEdge(x + dx, y + dy)) near = true;
        }
      }
      if (!near) continue;
      band++;
      final a = alpha(x, y);
      if (a > 0.05 && a < 0.95) partial++;
    }
  }

  return Reading(
    sample: sample,
    fontSize: fontSize,
    partialFrac: band == 0 ? 0 : partial / band,
    area: bestArea,
    contour: contour,
  );
}

/// 按平台顺序找一款**真实字体**（三平台的候选都列上，见文件头 §字体依赖）
///
/// ★ 为什么把 Linux/macOS 的路径也列上：本仓 CI 有 macOS 与 Linux 的测试 job。
///   只列 Windows 字体 ⇒ 那些 job 会因为这台机器"没有 Arial"而红，
///   而它们其实有 DejaVu / Liberation（同样是**真实字体**，判据照样成立：
///   `impliedW = Δarea / refContour` 是**归一的**，与具体字形无关）。
const List<String> kFontCandidates = <String>[
  // Windows
  'C:/Windows/Fonts/arialbd.ttf',
  'C:/Windows/Fonts/arial.ttf',
  'C:/Windows/Fonts/segoeui.ttf',
  'C:/Windows/Fonts/seguisb.ttf',
  // macOS
  '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
  '/System/Library/Fonts/Supplemental/Arial.ttf',
  '/System/Library/Fonts/Helvetica.ttc',
  '/System/Library/Fonts/SFNS.ttf',
  // Linux（GitHub runners 通常自带 fonts-dejavu-core / fonts-liberation）
  '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
  '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  '/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf',
  '/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf',
];

void main() {
  String? fontPath;

  setUpAll(() async {
    for (final p in kFontCandidates) {
      final f = File(p);
      if (!f.existsSync()) continue;
      // .ttc 是字体集合：FontLoader 只吃单字体 ttf/otf ⇒ 跳过（免得 load 抛错）
      if (p.toLowerCase().endsWith('.ttc')) continue;
      final loader = FontLoader(kProbeFont)
        ..addFont(f.readAsBytes().then((b) => ByteData.view(b.buffer)));
      await loader.load();
      fontPath = p;
      // ignore: avoid_print
      print('TC|FONT|$p');
      return;
    }
  });

  for (final size in kSizes) {
    testWidgets('${size.toInt()}px：四类样本判别力矩阵 + 生产样式加厚量', (t) async {
      if (fontPath == null) {
        /*
         * ★★ 缺字体 ⇒ **红**，不是 skip。
         *
         * 与 `test/support/core_gate.dart` 的既有约定一致：
         *   Windows 上缺 `sourin_core.dll` 也是 **fail** 而不是 skip ——
         *   因为"门禁跑不起来"必须**可见**，否则 CI 结论会从"红"变成
         *   "绿（有 N 项跳过）"，一个跑不了的门禁可以一路混进发布。
         * ⚠️ 这里缺的是**这台机器没有真实字体**（不是产品问题），
         *   但仍要红：本门禁的全部判据都建立在"文字被真实光栅化"之上，
         *   用默认测试字体（Ahem，实心方块无抗锯齿）测出来的是假数据。
         *   候选路径已列在 kFontCandidates（三平台），缺全部才走到这里。
         */
        fail('★★ 这台机器没有可用的真实字体 ⇒ 门禁**无法运行**（不是通过、不是跳过）。\n'
            '已尝试（${kFontCandidates.length} 条，Windows/macOS/Linux）：\n'
            '  ${kFontCandidates.join('\n  ')}\n'
            '为什么必须红而不是 skip：本门禁的判据（partialFrac / impliedW）'
            '只在**真实字体被栅格化**时成立；默认测试字体 Ahem 是实心方块、'
            '无抗锯齿 ⇒ 读数恒为假（partialFrac≈0、impliedW≈0）。\n'
            '修法：装一款真实字体（Linux: fonts-dejavu-core / fonts-liberation；'
            'macOS: Arial 或 SFNS；Windows: Arial）。\n'
            '替代覆盖：`zz_t1024_danmaku_text_edge_test.dart` 覆盖"毛边/发光"'
            '（过渡坡上限），但它**同样**依赖真实字体 ⇒ 缺字体时两条都红，这是有意的。');
      }

      final ref = _analyze(await _shot(t, Sample.fillOnly, size), Sample.fillOnly, size);
      final binarized =
          _analyze(await _shot(t, Sample.binarized, size), Sample.binarized, size)
            ..withRef(ref);
      final stroke1 =
          _analyze(await _shot(t, Sample.stroke1px, size), Sample.stroke1px, size)
            ..withRef(ref);
      final ghost2 =
          _analyze(await _shot(t, Sample.ghost2px, size), Sample.ghost2px, size)
            ..withRef(ref);
      final prod =
          _analyze(await _shot(t, Sample.production, size), Sample.production, size)
            ..withRef(ref);
      final prod1 = _analyze(await _shot(t, Sample.productionPlus1px, size),
              Sample.productionPlus1px, size)
        ..withRef(ref);
      final ref1 =
          _analyze(await _shot(t, Sample.refPlus1px, size), Sample.refPlus1px, size)
            ..withRef(ref);
      final ref2 =
          _analyze(await _shot(t, Sample.refPlus2px, size), Sample.refPlus2px, size)
            ..withRef(ref);

      // ignore: avoid_print
      print([
        ref.line,
        binarized.line,
        stroke1.line,
        ghost2.line,
        prod.line,
        prod1.line,
      ].join('\n'));

      // 前置：参考样本自己必须有部分覆盖像素（否则 ① 没有对照）
      expect(ref.partialFrac, greaterThanOrEqualTo(kMaxPartialFrac),
          reason: '★ 参考样本本身没有部分覆盖像素（partialFrac='
              '${ref.partialFrac.toStringAsFixed(3)} < $kMaxPartialFrac）⇒ '
              '这台机器/字体上压根没有抗锯齿输出，① 的判据无从对照。\n'
              '${ref.line}\n请检查字体是否真的加载成功（当前：$fontPath）。');

      // ① 判别力：二值化样本必须越界
      expect(binarized.partialFrac, lessThan(kMaxPartialFrac),
          reason: '★★ 仪器失效：把样本二值化之后 partialFrac 仍有 '
              '${binarized.partialFrac.toStringAsFixed(3)}（≥ $kMaxPartialFrac）⇒ '
              '本门禁抓不到"边缘被加硬"。\n${binarized.line} / ref: ${ref.line}');

      // ② 判别力：1px 描边必须越界
      expect(stroke1.impliedW, greaterThan(kMaxImpliedW),
          reason: '★★ 仪器失效：1px 描边的加厚量只量到 '
              '${stroke1.impliedW.toStringAsFixed(2)}px（≤ $kMaxImpliedW）⇒ '
              '抓不到"描边加厚"。\n${stroke1.line} / ref: ${ref.line}');

      // ③ 判别力：2px 重影必须越界
      expect(ghost2.impliedW, greaterThan(kMaxImpliedW),
          reason: '★★ 仪器失效：2px 重影的加厚量只量到 '
              '${ghost2.impliedW.toStringAsFixed(2)}px（≤ $kMaxImpliedW）⇒ '
              '抓不到"重影"。\n${ghost2.line} / ref: ${ref.line}');

      /*
       * ④ ★★★ 字体无关判据（2026-10-26 lead 要求：把绝对常数换成同轮相对量）
       *
       * ```text
       * U = impliedW(参考 + 1px 膨胀)   ← 这台机器 / 这个字体 / 这个 DPR 下
       *                                  "1px 膨胀"实际造成的加厚量（像素）
       * excessUnits = (impliedW(prod) − 声明描边 × 1.10) / U
       *   ⇒ 无量纲：产品比"声明描边"多出来的厚度，折算成几个"1px 单位"
       * 判据：kExcessLowerBound < excessUnits <= kExcessUpperBound
       * ```
       */
      final declared = _declaredStroke(size);
      final u = ref1.impliedW; // 同轮分母
      expect(u, greaterThan(kMinUnitPx),
          reason: '★★ 分母不可用：参考+1px 膨胀只量到 ${u.toStringAsFixed(2)}px'
              '（≤ $kMinUnitPx）⇒ "1px 单位"在这台机器上测不出来，'
              '比值判据会除以近似 0。\n${ref1.line} / ref: ${ref.line}');

      final excessUnits = (prod.impliedW - declared * kDeclaredStrokeScale) / u;
      // 线性度诊断：2px 膨胀应约为 2 个 U（证明 U 不是噪声）
      final linearity = u == 0 ? 0.0 : ref2.impliedW / u;

      expect(excessUnits, lessThanOrEqualTo(kExcessUpperBound),
          reason: '★ 生产样式的边缘**比声明描边厚了 '
              '${excessUnits.toStringAsFixed(2)} 个 1px 单位**'
              '（上限 $kExcessUpperBound）\n'
              '${prod.line}\n'
              '分母 U（参考+1px）= ${u.toStringAsFixed(2)}px｜'
              '线性度 ref+2px/U = ${linearity.toStringAsFixed(2)}（应约为 2）\n'
              'ref: ${ref.line}\n'
              '生产描边是有意的（danmaku_overlay.dart:318 '
              'strokeW=max(2,fs*0.12)=${declared.toStringAsFixed(2)}px）'
              '⇒ 判据是"不许比它更厚"，不是"不许有描边"。'
              '更厚 ⇒ 有人额外加了 shadow/第二层描边/发光。');

      expect(excessUnits, greaterThan(kExcessLowerBound),
          reason: '★ 生产样式的边缘**比声明描边薄了 '
              '${(-excessUnits).toStringAsFixed(2)} 个 1px 单位**'
              '（下限 $kExcessLowerBound）\n'
              '${prod.line}\n分母 U = ${u.toStringAsFixed(2)}px\n'
              'ref: ${ref.line}\n'
              '比声明值薄 ⇒ 描边被删掉/变细（生产样式的黑描边是**可读性**的一部分：'
              '白字压在亮画面上，没有它会糊成一片）。');

      /*
       * ⑤ 自证 A：把"产品"换成"参考 + 1px 膨胀" ⇒ 必须被**拒**。
       *
       * ★ 注意方向：它比声明描边**薄**（参考只有 fill，没有那圈声明描边），
       *   所以它落在**下限之外**（不是上限之外）。这里断言"被拒"这个事实，
       *   而不是硬套"必须超上限"—— 后者物理上不成立（薄的东西不可能超上限）。
       *   实测：22px −1.94 / 56px −6.41，远低于下限 −0.8 ⇒ 拒绝得很干脆。
       */
      final injectUnits = (ref1.impliedW - declared * kDeclaredStrokeScale) / u;
      expect(injectUnits, lessThan(kExcessLowerBound),
          reason: '★★ 判据太松：把产品样式换成"参考+1px 膨胀"后 '
              'excessUnits=${injectUnits.toStringAsFixed(2)}，'
              '却仍在可接受带 [$kExcessLowerBound, $kExcessUpperBound] 内 ⇒ '
              '这条门禁对"描边整体消失换成一个 1px 环"没有判别力。\n'
              '${ref1.line}\n分母 U=${u.toStringAsFixed(2)}px｜声明描边 '
              '${declared.toStringAsFixed(2)}px');

      // ⑥ 自证（保留）：生产+1px 也必须越界
      final prod1Units = (prod1.impliedW - declared * kDeclaredStrokeScale) / u;
      expect(prod1Units, greaterThan(kExcessUpperBound),
          reason: '★★ 判据太松：生产样式再膨胀 1px 后 excessUnits='
              '${prod1Units.toStringAsFixed(2)}（上限 $kExcessUpperBound）⇒ '
              '抓不到"生产上再加一层 1px 描边"。\n${prod1.line}\n'
              '生产（未膨胀）：${prod.line}\n分母 U=${u.toStringAsFixed(2)}px');

      // ignore: avoid_print
      print('TC|RATIO|${size.toInt()}px|U=${u.toStringAsFixed(3)}px '
          'linearity=${linearity.toStringAsFixed(2)} '
          'prod_excessUnits=${excessUnits.toStringAsFixed(3)} '
          'inject_refPlus1_excessUnits=${injectUnits.toStringAsFixed(3)} '
          'prodPlus1_excessUnits=${prod1Units.toStringAsFixed(3)}');
    });
  }
}
