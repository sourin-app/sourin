// ═══════════════════════════════════════════════════════════════════════
//  t1044：玻璃档到底贡献了什么像素（第 13 项 · 7ms 值不值得画）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★★ 先写清楚：上一轮我凭"内层不透明"推理，**判错了**
// ```text
// 我的推理是：AppGlassDialog 内层 `c.surfaceContainerHigh`（alpha 1.0）、
//             AppDialogShell 内层 `#14161B @ 0.98`
//             ⇒ 玻璃的模糊被盖住 ⇒ 7ms 是白付，可以摘掉。
// 实测评测（本文件首次运行，方差为零的确定性对比）：
//   AppGlassDialog  Δpeak=58  meanAbs=0.182  受影响像素 0.71%
//   AppDialogShell  Δpeak=13  meanAbs=0.061  受影响像素 0.07%
// ⇒ **摘掉玻璃会改变用户看到的画面**（峰值差 58 个亮度级），
//   所以"摘模糊"这条路**当场否掉**。这就是"先证明视觉没变再动"的价值：
//   透明度推理看起来天衣无缝，实测却给出相反结论。
// ```
//
// # 差在哪里（这一版量清楚了，上一版量错了）
// ```text
// 上一版把"内圈"定义成"整张图往里缩 24px" —— 但卡片本身只有 380 宽居中，
// 缩 24px 之后**仍然包含卡片边缘** ⇒ interiorΔpeak 也报 58，看起来像"卡片内部也变"。
// 这一版把内部区域改成**卡片内部的中心带**（见 _kInterior），
// 读数会直接告诉我们：峰差值到底在边缘一圈，还是在卡片里面。
// ```
//
// # 本文件现在守什么
// ```text
// ① 仪器自检：明显色差必须读得出来（防恒零假绿）；
// ② 玻璃**确实贡献可感知像素**：Δpeak 必须落在 [8, 80]、受影响像素 <2%
//    ⇒ 若有人真把玻璃摘了，Δpeak 会掉到 0，这条立刻红；
//    若玻璃被换成更重的东西（整卡变色），Δpeak 会冲到 >80 或占比暴涨，也红；
// ③ 卡片**内部中心带**的读数必须单独记录（上一版就是这里量错）；
// ④ reduced-motion：声明"减少动效"时玻璃**不挂**（本项新增分支），
//    与"显式摘玻璃"逐像素相同；同时用"vs 挂玻璃"的对照证明样本不是瞎的。
// ```
//
// # 为什么用 debugSkipGlass* 开关而不是改产品行为
// ```text
// 两个开关生产恒 false（见各自文件注释）：它们**只**用于 A/B 对照，
// 默认行为（挂玻璃）一个像素都没动。
// ```
//
// # 仪器注意（踩过的坑）
// ```text
// ① `boundary.toImage()` / `image.toByteData()` 在 FakeAsync zone 里**永不返回**
//    ⇒ 两者都必须包在 `t.runAsync` 里，且**一起**取完再比较；
// ② 两次截图**尺寸必须相同**（同一 host、同一 viewport），否则像素索引对不上；
// ③ 背景必须是**高低频混合**的图案：纯色背景下模糊前后本来就一样，
//    那样的 Δpeak=0 是假绿（模糊没有东西可糊）；
// ④ "内部"必须按**卡片几何**定义，不能按"整图缩边"（上一版的错）。
// ```
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';

const Size _kView = Size(520, 360);
const ValueKey<String> _kBoundary = ValueKey<String>('t1044-boundary');

/// 卡片**内部中心带**（卡片固定 380 宽、居中于 520 宽视口 ⇒ x 70..450）
///
/// ★ 这一版按**卡片几何**取带，不按"整图缩边"（上一版就是这么量错的）。
const Rect _kInterior = Rect.fromLTRB(110, 150, 410, 210);

/// 一张已经取到字节的截图（比较时不再碰引擎）
class _Shot {
  const _Shot(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

/// 一次逐像素对照的三个读数
class _Diff {
  const _Diff({
    required this.peak,
    required this.meanAbs,
    required this.affectedRatio,
    required this.interiorPeak,
  });

  /// 最大单通道绝对差（0–255）
  final int peak;

  /// 所有像素所有通道的平均绝对差
  final double meanAbs;

  /// 最大单通道差 > 1 的像素占比（0–1）
  final double affectedRatio;

  /// **只统计卡片内部**（去掉四周 24px 边）的最大单通道差
  ///
  /// ★ 这条才是模糊有没有贡献的判据：玻璃的**描边/高光**只影响边缘一圈，
  ///   而模糊若有贡献，一定在**内部**（边缘之外）也改变像素。
  final int interiorPeak;

  @override
  String toString() => 'Δpeak=$peak interiorΔpeak=$interiorPeak '
      'meanAbs=${meanAbs.toStringAsFixed(3)} '
      'affected=${(affectedRatio * 100).toStringAsFixed(2)}%';
}

_Diff _diff(_Shot a, _Shot b, {Rect? interior}) {
  expect(a.width, b.width, reason: '★ 两张图宽度必须一致（同 host / 同 viewport）');
  expect(a.height, b.height, reason: '★ 两张图高度必须一致');

  /*
   * 内部区域：去掉四周 24px（卡片在 520×360 里居中、最宽 380 ⇒ 这一圈一定在卡片外）
   * ⇒ interiorPeak 只反映**卡片内容/垫层**；玻璃的描边/高光只会在边缘那一圈。
   */
  final inner = interior;
  var peak = 0;
  var interiorPeak = 0;
  var sum = 0;
  var affected = 0;
  final pixels = a.width * a.height;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final i = y * a.width + x;
      var pixelMax = 0;
      for (var ch = 0; ch < 3; ch++) {
        final idx = i * 4 + ch;
        final d = (a.rgba[idx] - b.rgba[idx]).abs();
        sum += d;
        if (d > pixelMax) pixelMax = d; // 只按 RGB 算（alpha 由不透明垫层保证恒 255）
      }
      if (pixelMax > peak) peak = pixelMax;
      if (pixelMax > 1) affected++;
      final inBand = inner != null &&
          x >= inner.left &&
          y >= inner.top &&
          x < inner.right &&
          y < inner.bottom;
      if (inBand && pixelMax > interiorPeak) interiorPeak = pixelMax;
    }
  }
  return _Diff(
    peak: peak,
    meanAbs: sum / (pixels * 3),
    affectedRatio: affected / pixels,
    interiorPeak: interiorPeak,
  );
}

/// 高低频混合的测试底图 —— 只有这种底图上，模糊才会真的改变像素
Widget _backdrop() => Stack(
      children: <Widget>[
        Positioned.fill(child: Container(color: const Color(0xFF0E1116))),
        for (var row = 0; row < 6; row++)
          for (var col = 0; col < 8; col++)
            Positioned(
              left: col * 66.0,
              top: row * 62.0,
              width: 40,
              height: 40,
              child: Container(
                color: Color.fromARGB(
                  255,
                  40 + (col * 27) % 200,
                  30 + (row * 41) % 200,
                  90 + ((row + col) * 19) % 160,
                ),
              ),
            ),
      ],
    );

Widget _host(Widget overlay) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(
      /*
       * ⚠️ 边界必须套住**底图 + 覆盖层**：只套底图的话，截到的是"没有弹窗"的背景，
       *    两张图自然一模一样（Δpeak=0 的假绿，第一版就写错在这里）。
       */
      body: RepaintBoundary(
        key: _kBoundary,
        child: SizedBox(
          width: _kView.width,
          height: _kView.height,
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: _backdrop()),
              Positioned.fill(child: overlay),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 把"落在 RepaintBoundary 里的那张图"取成字节
Future<_Shot> _grab(WidgetTester t) async {
  late _Shot shot;
  await t.runAsync(() async {
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(_kBoundary),
    );
    final img = await boundary.toImage(pixelRatio: 1.0);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    shot = _Shot(img.width, img.height, data!.buffer.asUint8List());
  });
  return shot;
}

Future<_Shot> _shot(WidgetTester t, Widget overlay) async {
  await t.pumpWidget(_host(overlay));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  return _grab(t);
}

void main() {
  setUp(() {
    debugSkipGlassDialog = false;
    debugSkipGlassShell = false;
  });
  tearDown(() {
    debugSkipGlassDialog = false;
    debugSkipGlassShell = false;
  });

  Widget dialog() => AppGlassDialog(
        title: '样式核对',
        content: const SizedBox(
          height: 60,
          child: Text('正文一行，用来占位。'),
        ),
        actions: const SizedBox(height: 20),
        maxWidth: 380,
        maxHeight: 240,
      );

  Widget shell() => AppDialogShell(
        title: '样式核对',
        child: const SizedBox(height: 80, child: Text('面板内容')),
        glass: true,
        // 关掉入场动效：两张图必须都是"落定态"，否则量到的是动画中间帧
        motion: false,
        width: 380,
      );

  group('① 仪器自检：这套逐像素判据真的能看见差异', () {
    testWidgets('★★ 明显色差 ⇒ Δpeak 必须很大（防恒零假绿）', (t) async {
      /*
       * ⚠️ 覆盖层会盖住底图 ⇒ 第一版拿"两个相近的深色"来验，量到的只有 3 级差，
       *    被自己的判据判红 —— 那是**仪器写错**，不是判据太严。改用黑白对照。
       */
      final a = await _shot(t, const ColoredBox(color: Color(0xFF000000)));
      await t.pumpWidget(const SizedBox.shrink());
      final b = await _shot(t, const ColoredBox(color: Color(0xFFFFFFFF)));
      final d = _diff(a, b, interior: _kInterior);
      expect(d.peak, greaterThan(200),
          reason: '★ 判据看不见明显色差 ⇒ 后面所有"几乎没差"都是假绿');
      expect(d.interiorPeak, greaterThan(200),
          reason: '★ 内部读数也必须能看见（否则"内部无差"的判据恒真）');
    });
  });

  group('② AppGlassDialog：玻璃**确实贡献可感知像素**（不许摘）', () {
    testWidgets('★★★ Δpeak ∈ [8,80]、受影响像素 <2%，内部中心带单独记录', (t) async {
      final withGlass = await _shot(t, dialog());
      await t.pumpWidget(const SizedBox.shrink());
      debugSkipGlassDialog = true;
      final withoutGlass = await _shot(t, dialog());
      final d = _diff(withGlass, withoutGlass, interior: _kInterior);
      // ignore: avoid_print
      print('[T1044] AppGlassDialog  $d');

      /*
       * 判据（2026-10-26 定稿）：
       * ```text
       * ① Δpeak ∈ [8, 80] —— 玻璃的可见贡献必须**存在**且量级稳定：
       *      · 有人把玻璃摘掉 ⇒ 0 ⇒ 红（这正是我差点犯的错）
       *      · 有人把玻璃换成整卡染色 ⇒ >80 或占比暴涨 ⇒ 红
       * ② 受影响像素 <2% —— 是"边缘一圈 + 描边/高光"，不是整卡换色
       * ③ 卡片**内部中心带**（_kInterior）单独记录：它回答"模糊有没有透进卡片"，
       *    与 ①② 是两件事，不许合成一个数（上一版把"整图缩 24px"当内部，
       *    结果把边缘描边也算进去了 —— 那是量错，不是产品问题）。
       * ```
       */
      expect(d.peak, inInclusiveRange(8, 80),
          reason: '★★★ 玻璃的可见贡献应在 8~80 级之间（实测 58）。'
              '为 0 ⇒ 玻璃被摘了；>80 ⇒ 换成了别的东西。读数：$d');
      expect(d.affectedRatio, lessThan(0.02),
          reason: '★★ 应当只有边缘一圈受影响（<2%，实测 0.71%），不是整卡（$d）');
      expect(d.meanAbs, lessThan(1.0),
          reason: '★★ 全图平均差 <1 级 ⇒ 影响是局部的（$d）');
      expect(d.interiorPeak, lessThanOrEqualTo(1),
          reason: '★★ 卡片内部中心带零差（实测 0）⇒ 可见贡献在边缘一圈，'
              '不是"模糊把卡片内容糊了"（$d）');
    });
  });

  group('③ AppDialogShell 玻璃档：同样不许摘', () {
    testWidgets('★★★ 玻璃 vs 不挂玻璃（内层是 98% 不透明）', (t) async {
      final withGlass = await _shot(t, shell());
      await t.pumpWidget(const SizedBox.shrink());
      debugSkipGlassShell = true;
      final withoutGlass = await _shot(t, shell());
      final d = _diff(withGlass, withoutGlass, interior: _kInterior);
      // ignore: avoid_print
      print('[T1044] AppDialogShell  $d');

      /*
       * 实测：Δpeak 13 / 内部 0 / meanAbs 0.06 / 占比 0.07%
       * ⇒ 与 ② 同构（只是 98% 不透明让它更小），同样**不许摘**。
       */
      expect(d.peak, inInclusiveRange(8, 80),
          reason: '★★★ 玻璃的可见贡献应在 8~80 级（实测 13）；为 0 ⇒ 被摘了（$d）');
      expect(d.affectedRatio, lessThan(0.02),
          reason: '★★ 只有边缘一圈（<2%，实测 0.07%）（$d）');
      expect(d.meanAbs, lessThan(1.0), reason: '★★ 全图平均差 <1 级（$d）');
      expect(d.interiorPeak, lessThanOrEqualTo(1),
          reason: '★★ 卡片内部中心带零差（实测 0）（$d）');
    });
  });

  group('④ reduced-motion 分支：声明"减少动效"时玻璃确实不挂', () {
    testWidgets('★★ 与"显式摘玻璃"逐像素一致（并用"vs 挂玻璃"做阳性对照）',
        (t) async {
      // ── 基准 A：正常（挂玻璃）
      final glassOn = await _shot(t, dialog());

      // ── 基准 B：显式摘玻璃（仪器开关）
      await t.pumpWidget(const SizedBox.shrink());
      debugSkipGlassDialog = true;
      final plain = await _shot(t, dialog());

      // ── 实验组 C：不摘，但外层声明"减少动效"
      debugSkipGlassDialog = false;
      await t.pumpWidget(const SizedBox.shrink());
      final theme = AppTheme.themeFor(Brightness.dark);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        builder: (_, c) =>
            AppThemeHost(data: theme, child: c ?? const SizedBox()),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: RepaintBoundary(
              key: _kBoundary,
              child: SizedBox(
                width: _kView.width,
                height: _kView.height,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(child: _backdrop()),
                    Positioned.fill(child: dialog()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      final reduced = await _grab(t);

      /*
       * ★ 成因结论（回答"Δpeak=0 是分支生效还是样本看不出来"）：
       * ```text
       * 两条对照一起看才成立：
       *   ① reduced vs 摘玻璃  ⇒ 必须 0（说明 reduced 真的没挂玻璃）
       *   ② reduced vs 挂玻璃  ⇒ 必须 ≈ ②组的 58（说明**样本不是瞎的**：
       *      同一张图、同一背景下，挂不挂玻璃差得很明显）
       * ⇒ 若只有 ① 绿而 ② 也接近 0，那才是"样本看不出来"；
       *   现在 ② 必须落在 [8,80] ⇒ 分支是真的生效了。
       * ⚠️ 也就是说：reduced-motion 跳过玻璃这条**以前不存在**（三个文件里
       *    `disableAnimations` 命中 0），是本次（第 13 项）新加的分支。
       * ```
       */
      final dPlain = _diff(plain, reduced, interior: _kInterior);
      final dOn = _diff(glassOn, reduced, interior: _kInterior);
      // ignore: avoid_print
      print('[T1044] reduced-motion vs 摘玻璃  $dPlain');
      // ignore: avoid_print
      print('[T1044] reduced-motion vs 挂玻璃  $dOn');

      expect(dPlain.peak, lessThanOrEqualTo(1),
          reason: '★★ 声明减少动效 ⇒ 应当与"不挂玻璃"逐像素一致（$dPlain）');
      expect(dOn.peak, inInclusiveRange(8, 80),
          reason: '★★★ 阳性对照：与"挂玻璃"相比必须差出 8~80 级（实测同 ② 的 58）'
              '—— 否则说明这张图本来就分不出来，上一条是假绿（$dOn）');
    });
  });
}
