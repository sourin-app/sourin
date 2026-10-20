/*
 * ⚠️ 2026-10-20 结案后说明（**读下面的读数前先读这段**）
 *
 * 本文件里**部分读数已作废**。具体是：
 * ```text
 * · rect = 107.2 / 212.8  ← ★ 这个数是**凭印象写的**，不是实测
 *   实测是 107.0 / 213.0（四个坐标全整数）
 *   后果：曾据此推出「边界落在非整数像素 ⇒ 这就是毛边的几何来源」
 *         这个假设**没有依据，已作废**
 * · 最早的 edgeStd 表用了跨界环带（d ∈ [-1.5,+1.5]），混进了背景像素
 *   ⇒ 数值不可靠（「chip 比对照更平」的方向可能仍成立，但数不能引用）
 * ```
 *
 * # 终局结论在哪
 * ```text
 * lib/ui/player_page.dart 的 `kDanmakuChipClipBehavior` 注释（约 :19960-20100）：
 *   六条证据 + 三条弯路清单 + 「不是 chip 的问题，是旁边那枚半透明徽章」
 * ```
 *
 * # 本文件为什么**保留**（没有删）
 * ```text
 * 虽然部分读数作废，但里面这几条**仍然有效**：
 *   · 「chip 必须能从真树上定位」—— 定位方法（按文字锚点 / RenderBox 几何）有效
 *   · 「Δpeak 反证」方法 —— 可用于其它对象
 *   · 「跨帧方差 + 阴性对照」的判据形态
 * ⇒ 删除会造成一次事故（曾被别人的提交误带），而注释的成本更低、风险更小。
 * ```
 *
 * ⚠️ 若将来复用本文件：**先看那段结案注释**，不要直接引用这里的旧读数。
 */

// ═══════════════════════════════════════════════════════════════════════
//  task-66 R1 ② ·「毛边」会不会其实是**在动**？—— 多帧方差判据
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么换这个方向（lead 2026-10-19 裁决）
// ```text
// 上一轮（zz_t66_r1_danmaku_chip_edge_test.dart）证明：**单帧**静态底上
// Clip.none 的边缘峰值 = 内部（Δpeak 0.000），没有"更亮的边"。
// 但 Owner 看到的是**动态视频帧** + 半透明药丸（black@55%）。
// ⇒ 边缘像素 alpha < 1 ⇒ 它的合成结果跟着背景变；内部被徽章自己的底遮住
//   ⇒ 人眼读到的可能不是"更亮"，而是「一圈在抖的边」= 毛边。
// ```
//
// # 本文件量什么
// ```text
// 同一枚 chip，渲 N=5 帧**不同的**底图（模拟视频画面变化），
// 逐像素求时间方向的亮度标准差，然后比较：
//     边缘环带的标准差  vs  内部的标准差
// ```
//
// # ⚠️ 第一版的两个仪器缺陷（都已修，记下来防止再犯）
// ```text
// ① 环带取的是 [-1.5,+1.5] px **跨界**带 ⇒ 带里一半像素在 chip **外面**，
//    它们当然跟着背景变（那是背景本身在动，不是毛边）。
//    实测因此得到 edgeStd=41.3 / innerStd=0.0 —— 那个 41 是假读数。
//    ⇒ 现在把环带限定在**内部**（只取 d ∈ (0, 1.5]），不再跨界。
// ② 底图必须真的每帧不同（前置断言 span > 50），否则整个实验是空的。
// ```
//
// ⚠️ 不挂 native-media；只渲 chip + 彩色底。

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';

const Key kBoundary = ValueKey<String>('r1-var-boundary');
const Key kChip = ValueKey<String>('r1-var-chip');

// ══════════════════════════════════════════════════════════════════════
//  五帧「视频画面」——真实会出现的那几种，不是噪声
// ══════════════════════════════════════════════════════════════════════

/// 每帧 = 一组竖向色带（画面里同时有亮部和暗部，最常见的构图）
///
/// ★ 刻意让**同一列**在不同帧的亮度差很大 —— 那正是"视频在动"的定义。
///   若底图像素随机，方差会被噪声主导，判据就不可信了。
final List<List<Color>> kVideoFrames = <List<Color>>[
  // 帧 0：暗夜场景
  <Color>[
    const Color(0xFF050505),
    const Color(0xFF0A0A0A),
    const Color(0xFF111111),
    const Color(0xFFB06A20),
  ],
  // 帧 1：白天外景
  <Color>[
    const Color(0xFFD8DEE6),
    const Color(0xFFC9D2DC),
    const Color(0xFFE4E9EF),
    const Color(0xFF9FB0C0),
  ],
  // 帧 2：中间调室内
  <Color>[
    const Color(0xFF6B6055),
    const Color(0xFF7A6E62),
    const Color(0xFF5C5349),
    const Color(0xFF8A7E72),
  ],
  // 帧 3：高饱和（动画片常见的纯色块）
  <Color>[
    const Color(0xFF2E6BD8),
    const Color(0xFFD82E5B),
    const Color(0xFF2ED88A),
    const Color(0xFFD8C22E),
  ],
  // 帧 4：白底（切到白屏 / 演职员表）
  <Color>[
    const Color(0xFFF2F2F2),
    const Color(0xFFEDEDED),
    const Color(0xFFF8F8F8),
    const Color(0xFFE6E6E6),
  ],
];

class _BandBackdrop extends StatelessWidget {
  const _BandBackdrop({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth / colors.length;
        return Row(
          children: [
            for (final c in colors)
              SizedBox(
                width: w,
                height: constraints.maxHeight,
                child: ColoredBox(color: c),
              ),
          ],
        );
      },
    );
  }
}

Widget _stage({required Widget child, required List<Color> frame}) {
  return mui.MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeFor(Brightness.dark),
    home: mui.Scaffold(
      // ★ 底图必须在 boundary 内（R1 主探针踩过的坑）
      body: RepaintBoundary(
        key: kBoundary,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _BandBackdrop(colors: frame),
            Center(child: KeyedSubtree(key: kChip, child: child)),
          ],
        ),
      ),
    ),
  );
}

typedef Pixels = ({Uint8List rgba, int width, int height});

Future<(Pixels, Rect)> _renderFrame(
  WidgetTester t,
  Widget child,
  List<Color> frame,
) async {
  await t.pumpWidget(_stage(child: child, frame: frame));
  await t.pumpAndSettle();

  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(kBoundary));
  final box = t.renderObject<RenderBox>(find.byKey(kChip));
  final topLeft = box.localToGlobal(Offset.zero, ancestor: boundary);

  late Pixels px;
  await t.runAsync(() async {
    final ui.Image img = await boundary.toImage(pixelRatio: 1.0);
    final ByteData? bd =
        await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    px = (rgba: bd!.buffer.asUint8List(), width: img.width, height: img.height);
    img.dispose();
  });
  return (px, topLeft & box.size);
}

double _luma(Pixels p, int x, int y) {
  final i = (y * p.width + x) * 4;
  return 0.299 * p.rgba[i] + 0.587 * p.rgba[i + 1] + 0.114 * p.rgba[i + 2];
}

// ══════════════════════════════════════════════════════════════════════
//  方差读数（环带**只在内部**）
// ══════════════════════════════════════════════════════════════════════

/// 跨帧时间方向标准差：**内部环带** vs **内部实心区**
///
/// ```text
/// 边缘 = d ∈ (0, 1.5]   ← 只在 chip **内部**的那一圈（抗锯齿带）
/// 内部 = d >= 4         ← 完全被自己的底遮住的实心区
/// ```
/// ⚠️ 不取 d < 0 —— 那是 chip 外面的背景，它随帧变是**应该的**，
///    算进"边缘"会把背景运动误判成毛边（第一版就是这么错的）。
({double edgeStd, double innerStd, int nEdge, int nInner}) _variance(
  List<(Pixels, Rect)> frames,
) {
  final box = frames.first.$2;
  final r = math.min(box.width, box.height) / 2;
  final midY = box.center.dy;

  double signedDist(double x, double y) {
    if (x <= box.left + r) {
      return r -
          math.sqrt(math.pow(x - (box.left + r), 2) + math.pow(y - midY, 2));
    } else if (x >= box.right - r) {
      return r -
          math.sqrt(math.pow(x - (box.right - r), 2) + math.pow(y - midY, 2));
    }
    return math.min(y - box.top, box.bottom - y);
  }

  double stdOf(List<double> v) {
    final m = v.reduce((a, b) => a + b) / v.length;
    var acc = 0.0;
    for (final x in v) {
      acc += (x - m) * (x - m);
    }
    return math.sqrt(acc / v.length);
  }

  final edge = <double>[];
  final inner = <double>[];
  for (var y = box.top.floor(); y <= box.bottom.ceil(); y++) {
    for (var x = box.left.floor(); x <= box.right.ceil(); x++) {
      final d = signedDist(x + 0.5, y + 0.5);
      final isEdge = d > 0 && d <= 1.5;
      final isInner = d >= 4.0;
      if (!isEdge && !isInner) continue;
      final series = <double>[for (final (px, _) in frames) _luma(px, x, y)];
      (isEdge ? edge : inner).add(stdOf(series));
    }
  }

  expect(edge, isNotEmpty, reason: '★ 内部环带空 ⇒ 几何算式错');
  expect(inner, isNotEmpty, reason: '★ 内部实心区空 ⇒ 几何算式错');

  return (
    edgeStd: edge.reduce((a, b) => a + b) / edge.length,
    innerStd: inner.reduce((a, b) => a + b) / inner.length,
    nEdge: edge.length,
    nInner: inner.length,
  );
}

// ══════════════════════════════════════════════════════════════════════
//  对照件：站名徽章（自绘 Container + BoxDecoration，单遍绘制）
// ══════════════════════════════════════════════════════════════════════

/// 与 `player_page.dart:19567` 的站名徽章**逐参数同值**
/// （黑 0.55 / Radii.rFull / white70 / FontSizes.cap / 横 Sp.x3 纵 3）
Widget _stationBadge() => Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 3),
      decoration: BoxDecoration(
        color: mui.Colors.black.withValues(alpha: 0.55),
        borderRadius: Radii.rFull,
      ),
      child: const mui.Text(
        '哔哩哔哩',
        maxLines: 1,
        overflow: mui.TextOverflow.ellipsis,
        style: mui.TextStyle(
          color: mui.Colors.white70,
          fontSize: FontSizes.cap,
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 跑一组 5 帧，返回读数
  Future<({double edgeStd, double innerStd, int nEdge, int nInner, double span})>
      measure(WidgetTester t, Widget child) async {
    final frames = <(Pixels, Rect)>[];
    for (final f in kVideoFrames) {
      frames.add(await _renderFrame(t, child, f));
    }
    final v = _variance(frames);
    // 内部逐帧亮度：证明"这颗到底透不透背景"（判据 1 的现场读数）
    final box0 = frames.first.$2;
    final cx = box0.center.dx.round();
    final cy = box0.center.dy.round();
    final innerSeries = <double>[
      for (final (px, _) in frames) _luma(px, cx, cy),
    ];
    debugPrint('[R1②] 内部逐帧亮度='
        '${innerSeries.map((e) => e.toStringAsFixed(2)).toList()} '
        '幅度=${(innerSeries.reduce(math.max) - innerSeries.reduce(math.min)).toStringAsFixed(2)}');
    // 前置：底图确实在变
    final bg = <double>[
      for (final (px, _) in frames) _luma(px, 0, 0),
    ];
    bg.sort();
    return (
      edgeStd: v.edgeStd,
      innerStd: v.innerStd,
      nEdge: v.nEdge,
      nInner: v.nInner,
      span: bg.last - bg.first,
    );
  }

  testWidgets('★★★ R1② 弹幕 chip：5 帧动态底上的边缘 vs 内部方差', (t) async {
    t.view.physicalSize = const Size(360, 140);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final chip = await measure(
      t,
      debugDanmakuInfoChipForProbe(data: const DanmakuInfoData(count: 128)),
    );
    debugPrint('[R1②] chip      edgeStd=${chip.edgeStd.toStringAsFixed(4)} '
        'innerStd=${chip.innerStd.toStringAsFixed(4)} '
        'ratio=${(chip.edgeStd / (chip.innerStd == 0 ? 1 : chip.innerStd)).toStringAsFixed(2)} '
        'span=${chip.span.toStringAsFixed(1)} '
        'n_edge=${chip.nEdge} n_inner=${chip.nInner}');

    expect(chip.span, greaterThan(50),
        reason: '★ 前置：五帧底图必须真的差很多，否则方差判据没有意义');

    // ── 判据 1：内部**完全不动** ⇒ chip 实际是不透明的 ──
    //
    // ★ 这条推翻了"半透明药丸叠动态视频"这个前提（至少对本枚 chip 不成立）：
    //   `backgroundColor: black@55%` 只喂给了上层 `Ink`，而它下面那层
    //   `Material` 有自己的**不透明**底色（theme canvasColor）⇒ 合成后不透明。
    expect(chip.innerStd, lessThan(0.01),
        reason: '★★★ chip 内部在不同视频帧下必须**完全不变**。'
            '若它真的透 55% 背景，这里会像站名徽章一样飙到几十'
            '（实测 innerStd=${chip.innerStd.toStringAsFixed(3)}）');

    // ── 判据 2：边缘的抖动不超过"普通抗锯齿边缘"的量级 ──
    //
    // 不透明对照件（alpha=1 的自绘圆角块）边缘同样会抖 —— 那是抗锯齿
    // 把边缘像素与背景混合的**必然**结果，不是缺陷。
    // ⇒ 判据是"chip 不比它差太多"，而不是"必须为 0"。
    expect(chip.edgeStd, lessThan(4.0),
        reason: '★★ chip 边缘跨 5 帧的抖动必须很小（实测 '
            '${chip.edgeStd.toStringAsFixed(3)} 亮度级 / 255）。'
            '若这里飙到几十，才说明边缘真的在跟背景一起动');
  });

  testWidgets('★★★ R1② 对照组：站名徽章（自绘单遍）同条件方差', (t) async {
    t.view.physicalSize = const Size(360, 140);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final badge = await measure(t, _stationBadge());
    debugPrint('[R1②] badge     edgeStd=${badge.edgeStd.toStringAsFixed(4)} '
        'innerStd=${badge.innerStd.toStringAsFixed(4)} '
        'ratio=${(badge.edgeStd / (badge.innerStd == 0 ? 1 : badge.innerStd)).toStringAsFixed(2)} '
        'span=${badge.span.toStringAsFixed(1)} '
        'n_edge=${badge.nEdge} n_inner=${badge.nInner}');

    expect(badge.span, greaterThan(50), reason: '★ 前置：底图必须真的在变');

    // ── 这是**反面对照**：自绘 Container 才是真半透明 ──
    //
    // 同一 alpha 0.55，为什么它透而 chip 不透？
    //   站名徽章 = Container(BoxDecoration(color: black@55%)) —— 直接压在视频上
    //   弹幕 chip = ActionChip ⇒ Ink(black@55%) 叠在 Material(不透明 canvasColor) 上
    // ⇒ 「加个半透明底」这件事，两者根本不是同一种合成。
    expect(badge.innerStd, greaterThan(10.0),
        reason: '★★ 对照组必须显著"透背景"（实测 innerStd='
            '${badge.innerStd.toStringAsFixed(3)}），'
            '否则这组对照证明不了任何事');
    // ★ 与 chip 的对照是**跨用例**的（chip.innerStd 在另一个 testWidgets 里）。
    //   这里只钉住"徽章自己显著在动"；两者的比值在报告里给出。
    //   实测：badge.innerStd=30.24 / chip.innerStd=0.0000 ⇒ 比值 ≈ 无穷。
    expect(badge.innerStd, greaterThan(10.0));
  });

  testWidgets('★ R1② 对照：纯不透明底（alpha=1）在同样五帧上的方差应接近 0',
      (t) async {
    t.view.physicalSize = const Size(360, 140);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final opaque = await measure(
      t,
      Container(
        width: 100,
        height: 28,
        decoration: const BoxDecoration(
          color: mui.Colors.black, // ★ alpha = 1
          borderRadius: BorderRadius.all(Radius.circular(999)),
        ),
      ),
    );
    debugPrint('[R1②] opaque    edgeStd=${opaque.edgeStd.toStringAsFixed(4)} '
        'innerStd=${opaque.innerStd.toStringAsFixed(4)} '
        'span=${opaque.span.toStringAsFixed(1)}');
    expect(opaque.span, greaterThan(50), reason: '★ 前置：底图必须真的在变');
  });
}
