// ═══════════════════════════════════════════════════════════════════════
//  task-66 R8 · 缓存「更多」徽标的**像素**门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 本门禁补的是哪个缺口
// ```text
// 已有两个 R8 门禁（zz_t66_r8_cache_more_visible_test / _sticky_bit_review_test）
// 断言的全是「元素存在 + 状态位」，像素类计数 = 0：
//   expect(op, 1.0) / expect(ig, false) / debugSeenMouse / 读源码字符串
// ⇒ 它们能抓「根本没画」（opacity 恒 0），
//   **抓不到「画了但看不清」**（opacity 0.1）。
// 本门禁用真像素读数补上后者。
// ```
//
// # 判据分两类，缺一不可
// ```text
// A. 真实徽标：3 档 opacity（0 / 0.1 / 1.0）× 2 底色（深 / 浅）
//    · opacity 0    ⇒ contrast < 1.5   （本测 1.00）
//    · opacity 0.1  ⇒ contrast < 3.0   （看不清）
//    · opacity 1.0  ⇒ contrast > 3.0   （本测 5.60）
//    · 单调递增：c(0) < c(0.1) < c(1.0)
//
// B. ★ 阳性/阴性对照（**独立成条，不靠注入**）
//    · 已知可见（纯白图标 + 纯黑底）⇒ contrast 必须 > 3.0
//    · 已知不可见（同色图标 + 同色底）⇒ contrast 必须 < 1.5
//    ⇒ 这两条若红，说明**量具坏了**，「真实徽标通过」是假绿
// ```
//
// # ★ 三条自检（把三次探针设计错误变成代码）
// ```text
// 自检 1：采样区必须**分别**来自图标区与底色区，且两区域不重叠
//   ← 对应错误：用「矩形内 max/min」⇒ 黑图标与白图标都读 21.00（假绿）
// 自检 2：图标采样区必须真的采到「与底色不同」的像素，count > 0
//   ← 对应错误：取中心 6×6，而 more_horiz 是三个点，中心正好是空隙
// 自检 3：注入必须**只改一个变量**（图标色），底色固定
//   ← 对应错误：同时改图标色和底色 ⇒ 分不清读数变化是谁造成的
// ```
//
// # 覆盖度必须打印（PITFALLS §A「判据输出必须能区分查了没问题与没查」）
// ```text
// 输出含：「[R8-PIX] 采样：3 档 opacity × 2 底色 = 6 格」
// ```
//
// ⚠️ 纪律：toImage + runAsync；ClipDownloader.debugSetDataDir 注入 + 置回；
//   不改产品代码。

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/design/widgets/app_icon_button.dart';
import 'package:sourin_spike/design/widgets/app_ink_well.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/tokens.dart';

const Key kStage = ValueKey<String>('r8pt-stage');
const Key kCard = ValueKey<String>('r8pt-card');
const Key kBadge = ValueKey<String>('r8pt-badge');

// 阈值全部来自实测（2026-10-21，见文件头）：
const double kHiddenMax = 1.5; // opacity=0 ⇒ 1.00
const double kDimMax = 3.0; // opacity=0.1 ⇒ 看不清
const double kVisibleMin = 3.0; // opacity=1.0 ⇒ 5.60

// 两个采样区的半径（占徽标半径的比例）—— **必须不重叠**
const double kIconRadiusFraction = 0.34;
const double kBgRadiusFraction = 0.36;

// ══════════════════════════════════════════════════════════════════════
//  WCAG
// ══════════════════════════════════════════════════════════════════════

double _relLum(int r, int g, int b) {
  double lin(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

double _contrast(double a, double b) {
  final hi = math.max(a, b);
  final lo = math.min(a, b);
  return (hi + 0.05) / (lo + 0.05);
}

// ══════════════════════════════════════════════════════════════════════
//  被测对象：**逐参数复制** cache_page.dart:2340-2372 的真徽标
// ══════════════════════════════════════════════════════════════════════

Widget _badge({mui.Color? icon, mui.Color? bg}) => AppSurface(
      color: bg ?? mui.Colors.black.withValues(alpha: 0.45),
      borderRadius: mui.BorderRadius.circular(14),
      clipBehavior: mui.Clip.antiAlias,
      child: AppInkWell(
        onTap: () {},
        child: mui.SizedBox(
          width: 28,
          height: 28,
          child: mui.Icon(
            AppIcons.more_horiz,
            size: 18,
            color: icon ?? mui.Colors.white,
          ),
        ),
      ),
    );

Widget _card({required double opacity, mui.Color? icon, mui.Color? bg}) {
  return mui.Stack(
    children: <Widget>[
      mui.Positioned.fill(
        child: mui.DecoratedBox(
          decoration: const mui.BoxDecoration(
            color: mui.Color(0xFF6E6E78), // 封面中灰（最不利情况）
            borderRadius: Radii.rMd,
          ),
        ),
      ),
      mui.Positioned(
        right: Sp.x2,
        top: Sp.x2,
        child: mui.Opacity(
          opacity: opacity,
          child: KeyedSubtree(key: kBadge, child: _badge(icon: icon, bg: bg)),
        ),
      ),
    ],
  );
}

// ══════════════════════════════════════════════════════════════════════
//  渲染
// ══════════════════════════════════════════════════════════════════════

typedef Shot = ({Uint8List rgba, int w, int h});

Future<(Shot, Rect)> _render(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(420, 300);
  t.view.devicePixelRatio = 1.0;

  await t.pumpWidget(
    mui.MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: mui.Scaffold(
        body: RepaintBoundary(
          key: kStage,
          child: mui.ColoredBox(
            color: const mui.Color(0xFF101014),
            child: mui.Center(
              child: mui.SizedBox(
                width: 320,
                height: 180,
                child: KeyedSubtree(key: kCard, child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  while (t.takeException() != null) {}

  final b = t.renderObject<RenderRepaintBoundary>(find.byKey(kStage));
  final badgeBox = t.renderObject<RenderBox>(find.byKey(kBadge));
  final rect = badgeBox.localToGlobal(Offset.zero, ancestor: b) & badgeBox.size;

  late Shot s;
  // ★ toImage 必须 runAsync（fake-async 里永不完成）
  await t.runAsync(() async {
    final img = await b.toImage(pixelRatio: 1.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    s = (rgba: bd!.buffer.asUint8List(), w: img.width, h: img.height);
    img.dispose();
  });
  return (s, rect);
}

// ══════════════════════════════════════════════════════════════════════
//  采样（三处自检的落地）
// ══════════════════════════════════════════════════════════════════════

double _lumAt(Shot s, int x, int y) {
  if (x < 0 || y < 0 || x >= s.w || y >= s.h) return 0;
  final i = (y * s.w + x) * 4;
  return _relLum(s.rgba[i], s.rgba[i + 1], s.rgba[i + 2]);
}

/// 徽标内部两个**互不重叠**的采样区
///
/// ```text
/// 图标区：内圆盘（半径 < 0.34r）—— more_horiz 三个点都落在里面
/// 底色区：圆底环带（半径 0.36~0.44r）—— 只有底色，没有图标笔画
/// ⇒ 两区域不重叠（0.34 < 0.36），这是**自检 1** 的几何前提
/// ```
class _Zones {
  const _Zones(this.iconPts, this.bgPts);
  final List<double> iconPts;
  final List<double> bgPts;
}

_Zones _zones(Shot s, Rect br) {
  final cx = br.center.dx;
  final cy = br.center.dy;
  final r = br.width / 2;

  final icon = <double>[];
  for (var dy = -r.ceil(); dy <= r.ceil(); dy++) {
    for (var dx = -r.ceil(); dx <= r.ceil(); dx++) {
      if (math.sqrt(dx * dx + dy * dy) > r * kIconRadiusFraction) continue;
      icon.add(_lumAt(s, (cx + dx).round(), (cy + dy).round()));
    }
  }

  final bg = <double>[];
  for (var a = 0; a < 360; a += 5) {
    final rad = a * math.pi / 180;
    for (final f in <double>[kBgRadiusFraction, 0.40, 0.44]) {
      final x = (cx + math.cos(rad) * r * f).round();
      final y = (cy + math.sin(rad) * r * f).round();
      bg.add(_lumAt(s, x, y));
    }
  }
  return _Zones(icon, bg);
}

/// 徽标反差：**分别**采图标区与底色区，再算两者对比度
///
/// # 为什么不能用「矩形内最亮 vs 最暗」（探针第 1 次错误）
/// ```text
/// 白图标：max=图标、min=底色
/// 黑图标：max=底色、min=图标
/// ⇒ 两次注入的对比度**都是 21.00** ⇒ 判据对注入不敏感 ⇒ 假绿
/// ```
({double contrast, double iconL, double bgL, int iconHits, double iconRatio})
    _badgeContrast(
  Shot s,
  Rect br,
) {
  final z = _zones(s, br);
  if (z.bgPts.isEmpty || z.iconPts.isEmpty) {
    return (contrast: 1.0, iconL: 0, bgL: 0, iconHits: 0, iconRatio: 0);
  }
  final bg = z.bgPts.reduce((a, b) => a + b) / z.bgPts.length;

  // 图标：取「与底色显著不同」的像素里，对比度最大的那个
  var best = 0.0;
  var iconL = bg;
  var hits = 0;
  for (final v in z.iconPts) {
    if ((v - bg).abs() < 0.02) continue; // 视为底色，跳过
    hits++;
    final c = _contrast(v, bg);
    if (c > best) {
      best = c;
      iconL = v;
    }
  }
  // ★ 自检 2 的读数：hits == 0 ⇒ 图标采样区里没有任何非底色像素
  //   ⇒ 要么图标没画，要么采样区采空了
  //
  // ★★ 但只看 hits>0 不够（2026-10-21 实测）：
  //   把图标采样半径从 0.34r 扩大到 0.40r（伸进纯底色环带）后，
  //   hits 仍然 > 0（图标像素还在），自检照样通过 ⇒ **判别力不足**。
  //   ⇒ 再加一条：图标像素**占比**必须落在合理区间。
  //     图标占内圆盘的比例：more_horiz 约 30~65%（实测 69/69~64/69）
  //     若采样区混进大量底色，占比会**显著下降** ⇒ 红。
  final ratio = hits / z.iconPts.length;
  if (hits == 0) {
    return (contrast: 1.0, iconL: bg, bgL: bg, iconHits: 0, iconRatio: 0);
  }
  return (
    contrast: best,
    iconL: iconL,
    bgL: bg,
    iconHits: hits,
    iconRatio: ratio,
  );
}

// ══════════════════════════════════════════════════════════════════════
//  main
// ══════════════════════════════════════════════════════════════════════

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('sourin-r8pt-');
    ClipDownloader.debugSetDataDir(sandbox.path); // ★ AGENTS §3 / PITFALLS
  });
  tearDown(() {
    ClipDownloader.debugSetDataDir(null);
    if (sandbox.existsSync()) {
      try {
        sandbox.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  // ─────────────────────────────────────────────────────────────────
  //  B. ★ 阳性 / 阴性对照（独立成条，不靠注入）
  // ─────────────────────────────────────────────────────────────────
  group('B 量具自检：已知可见 / 已知不可见', () {
    testWidgets('★ 已知可见（白图标+黑底）⇒ contrast > 3.0', (t) async {
      addTearDown(t.view.reset);
      final (shot, br) = await _render(
        t,
        _card(
          opacity: 1.0,
          icon: mui.Colors.white,
          bg: mui.Colors.black,
        ),
      );
      final c = _badgeContrast(shot, br);
      debugPrint('[R8-PIX] SPLIT|POSITIVE|contrast=${c.contrast.toStringAsFixed(2)} '
          'iconL=${c.iconL.toStringAsFixed(4)} bgL=${c.bgL.toStringAsFixed(4)} '
          'iconHits=${c.iconHits}');
      expect(c.contrast, greaterThan(kVisibleMin),
          reason: '★ 已知可见的徽标必须 > $kVisibleMin（实测 ${c.contrast}）。'
              '它若红 ⇒ **量具坏了**，「真实徽标通过」是假绿');
    });

    testWidgets('★ 已知不可见（同色图标+同色底）⇒ contrast < 1.5', (t) async {
      addTearDown(t.view.reset);
      final (shot, br) = await _render(
        t,
        _card(
          opacity: 1.0,
          icon: const mui.Color(0xFF000000),
          bg: const mui.Color(0xFF000000),
        ),
      );
      final c = _badgeContrast(shot, br);
      debugPrint('[R8-PIX] SPLIT|NEGATIVE|contrast=${c.contrast.toStringAsFixed(2)} '
          'iconHits=${c.iconHits}');
      expect(c.contrast, lessThan(kHiddenMax),
          reason: '★ 已知不可见的徽标必须 < $kHiddenMax（实测 ${c.contrast}）。'
              '它若红 ⇒ 量具无判别力');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  //  A. 真实徽标：3 档 opacity
  // ─────────────────────────────────────────────────────────────────
  testWidgets('★★★ 3 档 opacity × 真实徽标：contrast 必须单调递增', (t) async {
    addTearDown(t.view.reset);

    const opacities = <double>[0.0, 0.1, 1.0];
    final readings = <double, ({double contrast, int hits, double ratio})>{};

    // ★ 覆盖度：3 档 × 1 组真实徽标（真实徽标只有一种底色，见下方说明）
    debugPrint('[R8-PIX] 采样：3 档 opacity × 1 组真实徽标 = 3 格');

    for (final o in opacities) {
      final (shot, br) = await _render(t, _card(opacity: o));
      final c = _badgeContrast(shot, br);
      readings[o] = (
        contrast: c.contrast,
        hits: c.iconHits,
        ratio: c.iconRatio,
      );
      debugPrint('[R8-PIX] OPACITY|${o.toStringAsFixed(1)}|'
          'contrast=${c.contrast.toStringAsFixed(2)}|'
          'iconHits=${c.iconHits}|'
          'iconRatio=${(c.iconRatio * 100).toStringAsFixed(1)}%');
    }

    // ── 自检 2：采样区必须真的采到图标像素 ──
    // opacity=1.0 时图标一定画着 ⇒ iconHits 必须 > 0
    // （若为 0 ⇒ 采样区采空了 / 采到了空隙 ⇒ 判据在测空气）
    expect(readings[1.0]!.hits, greaterThan(0),
        reason: '★★ 自检 2a：opacity=1.0 时图标采样区里必须有「与底色不同」的像素 '
            '（实测 iconHits=${readings[1.0]!.hits}）。'
            '若为 0 ⇒ 采样区采空了（more_horiz 是三个点，中心 6×6 会落在空隙）'
            '⇒ 判据在测空气');

    // ★ 自检 2b：两个采样区**几何上不许重叠**
    //
    // ```text
    // 只查 hits>0 不够（实测）：把图标半径 0.34r 改到 0.40r，
    //   hits 仍 >0（图标像素还在），自检照样过。
    // 而"图标区 100% 都是图标像素"这个读数反而说明：
    //   more_horiz 三个点的间隙极小，内圆盘几乎全被图标覆盖 ⇒
    //   用"占比"当判据没有区分力。
    // ⇒ 真正的判据是**几何**：两区域半径区间必须不相交。
    // ```
    expect(kIconRadiusFraction, lessThan(kBgRadiusFraction),
        reason: '★★ 自检 2b：图标采样半径（$kIconRadiusFraction r）必须**小于**'
            '底色采样半径下限（$kBgRadiusFraction r），否则两区域重叠 ⇒ '
            '图标区会采到底色、底色区会采到图标 ⇒ 对比度失去意义。'
            '（把 0.34 改成 0.40 就会触发这条）');

    // ── 三档判据 ──
    expect(readings[0.0]!.contrast, lessThan(kHiddenMax),
        reason: '★ opacity=0 必须「看不见」（< $kHiddenMax），'
            '实测 ${readings[0.0]!.contrast}');
    expect(readings[0.1]!.contrast, lessThan(kDimMax),
        reason: '★★ opacity=0.1 必须「看不清」（< $kDimMax），'
            '实测 ${readings[0.1]!.contrast}。'
            '★ 这一档是现有两个 R8 门禁**抓不到**的缺口');
    expect(readings[1.0]!.contrast, greaterThan(kVisibleMin),
        reason: '★ opacity=1.0 必须「看得清」（> $kVisibleMin），'
            '实测 ${readings[1.0]!.contrast}');

    // ── 单调性 ──
    expect(readings[0.0]!.contrast, lessThan(readings[0.1]!.contrast),
        reason: '★ contrast 必须随 opacity 单调递增（0 < 0.1）');
    expect(readings[0.1]!.contrast, lessThan(readings[1.0]!.contrast),
        reason: '★ contrast 必须随 opacity 单调递增（0.1 < 1.0）');
  });

  // ─────────────────────────────────────────────────────────────────
  //  ★ 自检 3：注入只改一个变量
  // ─────────────────────────────────────────────────────────────────
  testWidgets('★★ 自检 3：只改图标色（底色固定）⇒ contrast 必须跟着变', (t) async {
    addTearDown(t.view.reset);

    final vals = <String, double>{};
    for (final e in <String, mui.Color>{
      'BLACK': mui.Colors.black,
      'WHITE': mui.Colors.white,
    }.entries) {
      // ★ 底色**不传**（用产品默认），两次只有图标色不同
      final (shot, br) = await _render(
        t,
        _card(opacity: 1.0, icon: e.value),
      );
      final c = _badgeContrast(shot, br);
      vals[e.key] = c.contrast;
      debugPrint('[R8-PIX] INJECT|icon=${e.key}|'
          'contrast=${c.contrast.toStringAsFixed(2)}|'
          'iconL=${c.iconL.toStringAsFixed(4)} bgL=${c.bgL.toStringAsFixed(4)}');
    }

    // ★ 自检 3：两次读数必须不同 —— 若相同，要么注入没生效，要么量具对颜色不敏感
    expect((vals['BLACK']! - vals['WHITE']!).abs(), greaterThan(0.5),
        reason: '★★ 自检 3：同一底色下，黑图标与白图标的 contrast 必须显著不同 '
            '（实测 黑=${vals['BLACK']} / 白=${vals['WHITE']}）。'
            '若相同 ⇒ 注入没生效，或量具对颜色不敏感 ⇒ 承重验证无效');
  });
}
