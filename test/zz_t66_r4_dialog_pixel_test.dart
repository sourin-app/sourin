// ═══════════════════════════════════════════════════════════════════════
//  R4 像素验证：三个弹窗「看起来一致吗」—— **跨视口尺寸**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么还要这个（门禁之外的第二支尺子）
//
// `zz_t66_r4_dialog_consistency_test.dart` 是**源码级**门禁：它证明
// 「三个弹窗都调用了 AppDialogShell」「width 落在白名单」。它**不能**证明
// 三者渲染出来长得一样 —— 外壳参数不同（scrollable / actions /
// 调用方自带 padding）都会改变最终像素。
//
// ⇒ 本文件从**渲染结果**读几何（rect + 像素），不读常量、不读代码。
//
// # ★★ 2026-10-21：从「单视口」改成「三视口 × 三弹窗」
//
// # 为什么要改（Lead 指出的漏洞）
// ```text
// 第一版每个弹窗只在自己那一个视口下量过：
//     update 1440x900 / skip 1280x800 / composer 1600x1000
// ⇒ 那一版**无法回答**：「视口变小会不会坏？」
//   三个读数来自三个不同视口，横向比"一致性"本身就不严谨。
//
// 现在的矩阵：3 视口 × 3 弹窗 = 9 格，每格取同一套指标。
//     1280x800（基线，也是本仓最常见的窗口）
//     1024x640（常见小窗）
//      800x600（AGENTS.md §3.5 提到的测试视口，620 上限的由来）
// ```
//
// # 判据（AGENTS.md §8：先问"我采的这个地方应该是什么"）
//
// ```text
// 【不变】跨视口必须恒定（变了 = 缺陷，因为它依赖了不该依赖的东西）
//   · 圆角半径    Radii.rLg 是常量
//   · 标题栏高度  外壳 _Header 的 padding 是常量
//   · 按钮右缘    外壳 _ActionBar 的 padding 是常量
//   · 按钮区高度  同上
//   · 关闭钮个数  外壳只画一个
//
// 【可变】设计内差异（§3.5 明写）
//   · 卡片宽     按档位 460/560/820，且窄视口下按可用宽夹取
//   · 卡片高     按内容 + maxHeight(620) 与视口夹取
//   · 出现滚动   内容超出时应该滚，而不是被裁
//
// 【绝对不许】
//   · 卡片超出视口（用户看不到底部按钮）
//   · 按钮被裁 / 圆角变化 / 关闭钮消失或重复
// ```
//
// # ★ 三个已踩的坑（都是我自己踩的，记下来防复发）
//
// ```text
// 坑 1  截图空白（PNG 只有 497 字节）
//   我把 RepaintBoundary 包在 Scaffold.body 里，但 showDialog 画在
//   **Overlay**（在 Scaffold 之上）⇒ 截到的是"没有弹窗的页面"。
//   ⇒ 必须截**整个视口**：`binding.renderViews.first.debugLayer`。
//
// 坑 2  圆角全是 -1
//   同上 —— 图上根本没有卡片，采样点落在遮罩/背景上。
//   ⇒ 已加阳性对照：遮罩与卡片亮度差 < 3 时返回 -2（而不是假装量到了）。
//
// 坑 3  第二个用例挂 10 分钟
//   `await toImage()` 在 fake-async 的 testWidgets 里会**永不完成**。
//   ⇒ 必须包在 `tester.runAsync(() async { ... })` 里。
// ```
//
// # 圆角怎么从像素读（推导，不是拍）
//
// ```text
// 圆角矩形的左上角，圆心在 (left+r, top+r)。
// 沿 45° 对角线从角点往里走，参数 t：
//     P(t) = (left + t/√2, top + t/√2)
//     到圆心距离 = |t − r√2|
// 边界在 距离 == r 处 ⇒ t = r(√2 − 1) ≈ 0.4142 r
// ⇒ r = t_mid / (√2 − 1) = t_mid × 2.41421
// ```
// 自检：r = 22 ⇒ t_mid ≈ 9.11px；r = 20 ⇒ t_mid ≈ 8.28px。
//
// # 为什么底图用**白色**
// ```text
// 遮罩 Colors.black@0.72 压纯白 ⇒ rgb(71,71,71)；
// 卡片底 surfaceContainerHighest(深色) ≈ rgb(23,23,23)；
// 差 ~48 灰阶 ⇒ 边界可稳定分辨。深色底时两者只差几个灰阶，会被抗锯齿淹没。
// ```
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/app_update/release.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/source_composer_dialog.dart';
import 'package:sourin_spike/ui/widgets/update_dialog.dart';

import 'support/ui_shot.dart';

/// 三档视口（1280x800 = 基线；800x600 = §3.5 里 620 上限的由来）
const _viewports = <String, Size>{
  '1280x800': Size(1280, 800),
  '1024x640': Size(1024, 640),
  '800x600': Size(800, 600),
};

const _dialogNames = <String>['update', 'skip', 'composer'];

class _Geo {
  String name = '';
  String vp = '';
  double vpW = 0, vpH = 0;

  double cardW = 0, cardH = 0;
  double cardLeft = 0, cardTop = 0, cardRight = 0, cardBottom = 0;
  double rTL = -1, rTR = -1, rBL = -1, rBR = -1;
  double headerH = 0;
  double padL = 0, padR = 0;
  bool hasDivider = false;
  double actionsGapR = -1;
  double actionsH = 0;
  int nClose = 0;

  /// 内容是否可滚（有 Scrollable 且 maxScrollExtent > 0）
  bool scrollable = false;

  /// 最大可滚动距离（0 = 不用滚就装得下）
  double maxScrollExtent = 0;

  /// 卡片是否**超出视口**（这是缺陷，不是设计差异）
  bool get overflowsViewport =>
      cardRight > vpW + 0.5 ||
      cardBottom > vpH + 0.5 ||
      cardLeft < -0.5 ||
      cardTop < -0.5;

  double get radius {
    final rs = [rTL, rTR, rBL, rBR].where((v) => v > 0).toList();
    if (rs.isEmpty) return -1;
    return rs.reduce((a, b) => a + b) / rs.length;
  }

  Map<String, Object> get json => {
        'name': name,
        'vp': vp,
        'cardW': cardW,
        'cardH': cardH,
        'r': radius,
        'headerH': headerH,
        'actionsGapR': actionsGapR,
        'actionsH': actionsH,
        'nClose': nClose,
        'scrollable': scrollable,
        'maxScrollExtent': maxScrollExtent,
        'overflowsViewport': overflowsViewport,
        'padL': padL,
        'padR': padR,
      };

  @override
  String toString() => 'card=${cardW.toStringAsFixed(1)}x'
      '${cardH.toStringAsFixed(1)} r=${radius.toStringAsFixed(2)} '
      'headerH=${headerH.toStringAsFixed(1)} '
      'actGapR=${actionsGapR.toStringAsFixed(1)} '
      'actH=${actionsH.toStringAsFixed(1)} nClose=$nClose '
      'scroll=${scrollable ? maxScrollExtent.toStringAsFixed(0) : "no"} '
      'overflow=$overflowsViewport';
}

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'Microsoft YaHei UI',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
      ),
      // ★ 纯白底（见文件头）
      home: Scaffold(backgroundColor: Colors.white, body: child),
    );

Rect _cardRect(WidgetTester t) {
  final titleEl = find
      .descendant(of: find.byType(AppDialogShell), matching: find.byType(Text))
      .first;
  final mat = find.ancestor(of: titleEl, matching: find.byType(Material)).first;
  return t.getRect(mat);
}

class _Pix {
  _Pix(this.w, this.h, this.bytes);
  final int w;
  final int h;
  final ByteData bytes;

  static Future<_Pix> of(ui.Image img) async {
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    return _Pix(img.width, img.height, bd!);
  }

  double lum(int x, int y) {
    if (x < 0 || y < 0 || x >= w || y >= h) return -1;
    final o = (y * w + x) * 4;
    return 0.299 * bytes.getUint8(o) +
        0.587 * bytes.getUint8(o + 1) +
        0.114 * bytes.getUint8(o + 2);
  }
}

/// 卡片底亮度 = 卡片矩形内出现最多的亮度（众数）
///
/// ★ 为什么用众数而不是"对角线 60px 处那一点"（我第一版就是这么错的）：
/// ```text
/// 60px 处可能正好压在**标题文字**上 —— 实测 composer 那个点 lum=81，
/// 比遮罩(71)还亮 ⇒ `outside - inside < 8` 阳性对照直接失败，四角全 -2。
/// 众数对文字/图标/分隔线都免疫（它们面积远小于底色）。
/// ```
int _cardLum(_Pix p, Rect card) {
  final counts = <int, int>{};
  for (var y = card.top.round() + 2; y < card.bottom.round() - 2; y += 3) {
    for (var x = card.left.round() + 2; x < card.right.round() - 2; x += 3) {
      final l = p.lum(x, y);
      if (l < 0) continue;
      counts[l.round()] = (counts[l.round()] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return -1;
  var best = -1, bestN = -1;
  counts.forEach((k, v) {
    if (v > bestN) {
      bestN = v;
      best = k;
    }
  });
  return best;
}

/// 沿 45° 对角线找「遮罩 ⇄ 卡片」过渡的**中点**距离，换算成半径
///
/// ★ **不假设极性**：`update` 的卡片(54)比遮罩(33)**亮**，
///   `composer` 的卡片(54)比遮罩(71)**暗** —— 取决于主题与是否双层遮罩。
///   第一版写死"外侧更亮" ⇒ update 四角全 -2。现在按两者大小自动选方向。
double _radiusAtCorner(_Pix p, Rect card, int cardLum,
    {required int sx, required int sy}) {
  final cx = sx > 0 ? card.left.round() : card.right.round() - 1;
  final cy = sy > 0 ? card.top.round() : card.bottom.round() - 1;

  final scrim = p.lum(cx + sx * 2, cy + sy * 2);
  if (scrim < 0 || cardLum < 0) return -1;
  /*
   * ★ 阈值从 8 降到 3（2026-10-20 实测）。
   *
   * # 为什么不能是 8
   * ```text
   * skip 的卡片底 lum=64、遮罩 lum=57 ⇒ 只差 **7**（其余两个是 17~21）。
   * 7 < 8 ⇒ 阳性对照误判成"采错地方"，四角全 -2。
   * 而它其实是**三张图里过渡最干净的一张**：
   *   t=0..7.5 → 57（遮罩）／t=8 → 63／t=9.5 → 64（卡片）
   * 与另外两张的过渡形态完全一样。
   * ```
   * ⇒ 对比度小不代表采错地方，只代表遮罩更厚/主题更暗。
   *    阈值只用来挡住"根本没边界"（差 0~2），3 足够。
   */
  if ((scrim - cardLum).abs() < 3) return -2;
  final goingDown = scrim > cardLum; // 从遮罩到卡片是变暗还是变亮
  final mid = (scrim + cardLum) / 2;

  for (var i = 0; i <= 400; i++) {
    final t = i * 0.25;
    final l = p.lum(cx + (sx * t / math.sqrt2).round(),
        cy + (sy * t / math.sqrt2).round());
    if (l < 0) break;
    if (goingDown ? l <= mid : l >= mid) return t / (math.sqrt2 - 1);
  }
  return -1;
}

/// 量一个**已经渲染好**的弹窗。★ 不 pump（会把弹窗销毁）
Future<_Geo> measure(WidgetTester t, String name, String vpName) async {
  final g = _Geo()
    ..name = name
    ..vp = vpName;
  g.vpW = t.view.physicalSize.width / t.view.devicePixelRatio;
  g.vpH = t.view.physicalSize.height / t.view.devicePixelRatio;

  final card = _cardRect(t);
  g.cardW = card.width;
  g.cardH = card.height;
  g.cardLeft = card.left;
  g.cardTop = card.top;
  g.cardRight = card.right;
  g.cardBottom = card.bottom;

  // ── 截图：**整个视口**（含 Overlay 里的弹窗）──
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size;
  late ui.Image img;
  late Uint8List png;
  // ★ 必须 runAsync：toImage 在 fake-async 里永不完成
  await t.runAsync(() async {
    img = await layer.toImage(Offset.zero & size);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    png = bd!.buffer.asUint8List();
  });
  final dir = Directory('.probe/r4pix')..createSync(recursive: true);
  final f = File('${dir.path}/${name}_$vpName.png');
  f.writeAsBytesSync(png, flush: true);

  // ── 圆角：从像素读 ──
  late _Pix pix;
  await t.runAsync(() async {
    pix = await _Pix.of(img);
  });
  final cardLum = _cardLum(pix, card);
  g.rTL = _radiusAtCorner(pix, card, cardLum, sx: 1, sy: 1);
  g.rTR = _radiusAtCorner(pix, card, cardLum, sx: -1, sy: 1);
  g.rBL = _radiusAtCorner(pix, card, cardLum, sx: 1, sy: -1);
  g.rBR = _radiusAtCorner(pix, card, cardLum, sx: -1, sy: -1);

  // ── 标题栏高度（外壳 _Header 的 Padding）──
  final header = find.descendant(
    of: find.byType(AppDialogShell),
    matching: find.byWidgetPredicate((w) =>
        w is Padding &&
        w.padding == const EdgeInsets.fromLTRB(Sp.x6, Sp.x3, Sp.x3, Sp.x2)),
  );
  expect(header, findsOneWidget, reason: '找不到 _Header 的 Padding —— 结构变了');
  g.headerH = t.getRect(header).height;

  // ── 内容区左右 padding ──
  final sv = find.descendant(
      of: find.byType(AppDialogShell),
      matching: find.byType(SingleChildScrollView));
  if (sv.evaluate().isNotEmpty) {
    final s = t.widget<SingleChildScrollView>(sv.first);
    final p = s.padding as EdgeInsets?;
    g.padL = p?.left ?? 0;
    g.padR = p?.right ?? 0;
  } else {
    final pad = find.descendant(
      of: find.byType(AppDialogShell),
      matching: find.byWidgetPredicate((w) => w is Padding),
    );
    for (var i = 0; i < pad.evaluate().length; i++) {
      final p = (pad.at(i).evaluate().first.widget as Padding).padding;
      if (p is EdgeInsets &&
          p != const EdgeInsets.fromLTRB(Sp.x6, Sp.x3, Sp.x3, Sp.x2) &&
          p != const EdgeInsets.fromLTRB(Sp.x6, Sp.x2, Sp.x6, Sp.x3)) {
        g.padL = p.left;
        g.padR = p.right;
        break;
      }
    }
  }

  // ── 滚动：弹窗里任一 Scrollable 的 maxScrollExtent ──
  // ★ 用**真实 ScrollPosition**，不是"内容高 - 视口高"的推算
  final scrollables = find.descendant(
      of: find.byType(AppDialogShell), matching: find.byType(Scrollable));
  for (var i = 0; i < scrollables.evaluate().length; i++) {
    final st = t.state<ScrollableState>(scrollables.at(i));
    final ext = st.position.maxScrollExtent;
    if (ext > g.maxScrollExtent) g.maxScrollExtent = ext;
  }
  g.scrollable = g.maxScrollExtent > 0.5;

  // ── 底部按钮区 ──
  final div = find.descendant(
      of: find.byType(AppDialogShell), matching: find.byType(Divider));
  g.hasDivider = div.evaluate().isNotEmpty;
  if (g.hasDivider) {
    final dr = t.getRect(div.first);
    g.actionsH = card.bottom - dr.top;
    final btns = find.descendant(
      of: find.byType(AppDialogShell),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    );
    var rightMost = double.negativeInfinity;
    for (var i = 0; i < btns.evaluate().length; i++) {
      final r = t.getRect(btns.at(i));
      if (r.top >= dr.top - 1 && r.right > rightMost) rightMost = r.right;
    }
    if (rightMost.isFinite) g.actionsGapR = card.right - rightMost;
  }

  g.nClose = find.byTooltip('关闭').evaluate().length;

  // ignore: avoid_print
  print('[R4PIX] ${name.padRight(8)} @${vpName.padRight(8)} $g');
  // ignore: avoid_print
  print('[R4PIX]RECT $name @$vpName '
      'card=[${card.left.toStringAsFixed(0)},${card.top.toStringAsFixed(0)} .. '
      '${card.right.toStringAsFixed(0)},${card.bottom.toStringAsFixed(0)}] '
      'vp=${g.vpW.toStringAsFixed(0)}x${g.vpH.toStringAsFixed(0)}');
  // ignore: avoid_print
  print('[R4PIX]JSON ${jsonEncode(g.json)}');
  return g;
}

/// 渲染一个弹窗并测量（在指定视口下）
Future<_Geo> renderAndMeasure(
  WidgetTester t,
  String dialog,
  String vpName,
  Size vp,
) async {
  await setShotViewport(t, vp);

  switch (dialog) {
    case 'update':
      await t.pumpWidget(_host(Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showUpdateDialog(
            ctx,
            parseReleaseJson(jsonDecode(
                    File('test/fixtures/github_release_v1_1_0.json')
                        .readAsStringSync()) as Map<String, dynamic>),
            platform: UpdatePlatform.windows,
          ),
          child: const Text('open'),
        ),
      )));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    case 'skip':
      SourinApi.debugSkipMarkerFetcher = (p, i) async => null;
      addTearDown(() => SourinApi.debugSkipMarkerFetcher = null);
      await t.pumpWidget(_host(Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showAppDialog<SkipMarkerResult>(
            context: ctx,
            barrierDismissible: false,
            builder: (_) => const SkipMarkerDialog(
              provider: 'tyyszy',
              id: '70260',
              title: '怒鲨狂潮',
              streamUrl: 'file:///nonexistent.mp4',
              duration: Duration(seconds: 600),
            ),
          ),
          child: const Text('open'),
        ),
      )));
      await t.tap(find.text('open'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
    case 'composer':
      await t.pumpWidget(_host(const SourceComposerDialog()));
      await t.pumpAndSettle();
  }

  return measure(t, dialog, vpName);
}

void main() {
  setUpAll(loadRealFonts);

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('r4pix');
    await UiPrefs.load(tmp.path);
    AppUpdateController.instance.loadPrefs();
    AppUpdateController.instance.debugResetAvailable();
    AppUpdateController.instance.debugSetDownloadState(
        UpdateDownloadState.idle);
  });

  /// 9 格读数：key = "<dialog>@<viewport>"
  final results = <String, _Geo>{};

  // ── 9 格：3 视口 × 3 弹窗 ──
  for (final vpEntry in _viewports.entries) {
    for (final d in _dialogNames) {
      testWidgets('$d @ ${vpEntry.key}', (t) async {
        results['$d@${vpEntry.key}'] =
            await renderAndMeasure(t, d, vpEntry.key, vpEntry.value);
      });
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  判据 A：跨视口**不变**的指标（变了 = 缺陷）
  // ═══════════════════════════════════════════════════════════════════
  test('A 跨视口恒定：圆角 / 标题栏高 / 按钮右缘 / 按钮区高 / 关闭钮', () {
    for (final d in _dialogNames) {
      final gs = [
        for (final v in _viewports.keys)
          results['$d@$v'] ??
              (throw StateError('★ $d@$v 的读数缺失 —— '
                  '少一个视口，"跨视口恒定"这个结论就不成立')),
      ];

      // ── 圆角 ──
      final radii = gs.map((g) => g.radius).toList();
      expect(radii.reduce((a, b) => a < b ? a : b),
          closeTo(radii.reduce((a, b) => a > b ? a : b), 3.0),
          reason: '★★ $d 的圆角随视口变了：$radii\n'
              '  Radii.rLg 是常量（22），渲染出来不该随视口变。\n'
              '  ⚠️ 容差 3px：采样步长 0.25px、换算系数 √2−1≈0.414，'
              '单像素抖动会放大成 ~2.4px。');

      // ── 标题栏高度 ──
      final hs = gs.map((g) => g.headerH).toList();
      expect(hs.reduce((a, b) => a < b ? a : b),
          closeTo(hs.reduce((a, b) => a > b ? a : b), 1.0),
          reason: '★★ $d 的标题栏高度随视口变了：$hs\n'
              '  外壳 _Header 的 padding 是常量 fromLTRB(x6,x3,x3,x2)，'
              '高度只由文字行高决定 ⇒ 不该随视口变。');

      // ── 按钮右缘 ──
      final gaps = gs.map((g) => g.actionsGapR).toList();
      expect(gaps.reduce((a, b) => a < b ? a : b),
          closeTo(gaps.reduce((a, b) => a > b ? a : b), 1.0),
          reason: '★★ $d 的按钮右缘到卡片边缘的距离随视口变了：$gaps\n'
              '  外壳 _ActionBar 的 padding 是常量 fromLTRB(x6,x2,x6,x3)，'
              '它是**绝对 padding** 不是百分比 ⇒ 不该变。');

      // ── 按钮区高度 ──
      final ahs = gs.map((g) => g.actionsH).toList();
      expect(ahs.reduce((a, b) => a < b ? a : b),
          closeTo(ahs.reduce((a, b) => a > b ? a : b), 1.0),
          reason: '★★ $d 的按钮区高度随视口变了：$ahs');

      // ── 关闭钮个数 ──
      for (final g in gs) {
        expect(g.nClose, 1,
            reason: '★★ ${g.name}@${g.vp} 的关闭钮数量 = ${g.nClose}（应为 1）。'
                '多于 1 = 外壳的 + 调用方自己又画了一个；少于 1 = onClose 没传');
      }

      // ── 分隔线 ──
      for (final g in gs) {
        expect(g.hasDivider, isTrue,
            reason: '★★ ${g.name}@${g.vp} 的按钮区没有分隔线 —— '
                '说明它没走外壳的 actions，而是自己在内容区画了一排按钮');
      }
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  判据 B：卡片**绝不许**超出视口（这是缺陷，不是设计差异）
  // ═══════════════════════════════════════════════════════════════════
  test('B 卡片不许超出视口（否则用户看不到底部按钮）', () {
    final bad = <String>[];
    results.forEach((k, g) {
      if (g.overflowsViewport) {
        bad.add('$k: card=[${g.cardLeft.toStringAsFixed(0)},'
            '${g.cardTop.toStringAsFixed(0)} .. '
            '${g.cardRight.toStringAsFixed(0)},'
            '${g.cardBottom.toStringAsFixed(0)}] vs viewport '
            '${g.vpW.toStringAsFixed(0)}x${g.vpH.toStringAsFixed(0)}');
      }
    });
    expect(bad, isEmpty,
        reason: '★★ 这些格子里的卡片**超出了视口** —— 用户会看不到底部按钮：\n'
            '${bad.join('\n')}\n'
            '§3.5 写的是「最大高度 620，再按视口夹取」⇒ 小视口下必须变矮，'
            '而不是溢出屏幕。');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  判据 C：内容超出时必须**可滚**（而不是被裁掉）
  // ═══════════════════════════════════════════════════════════════════
  test('C 小视口下内容超出 ⇒ 必须可滚（不许静默裁掉）', () {
    for (final d in _dialogNames) {
      final g = results['$d@800x600'];
      expect(g, isNotNull, reason: '★ $d@800x600 读数缺失');
      /*
       * ★ 判据的写法：不要求"必须出现滚动条"（内容装得下时不该有），
       *   而是要求「**若**卡片高度被视口夹取到比内容矮，**则**必须可滚」。
       *
       * 怎么判断"被夹取"：卡片高 == 视口高（或非常接近）⇒ 说明顶到了上限。
       * 那种情况下内容装不下，必须有 Scrollable 且 maxScrollExtent > 0；
       * 否则就是"内容被裁掉、用户滚不到"。
       */
      final clamped = g!.cardH >= g.vpH - 2;
      if (clamped) {
        expect(g.scrollable, isTrue,
            reason: '★★ ${g.name}@800x600 的卡片高 ${g.cardH} 已经顶到视口高 '
                '${g.vpH}（被夹取），但**不可滚** ⇒ 内容被裁掉了，用户看不到。');
      }
      // ignore: avoid_print
      print('[R4PIX] 判据C ${g.name}@800x600 clamped=$clamped '
          'cardH=${g.cardH.toStringAsFixed(0)} vpH=${g.vpH.toStringAsFixed(0)} '
          'maxScrollExtent=${g.maxScrollExtent.toStringAsFixed(0)}');
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  判据 D：窄视口下卡片必须**保留边距**（不许贴满屏幕）
  //
  //  ★ 2026-10-21 新增 —— 本轮发现的缺陷（已修在外壳）
  //  ★ 同日 Lead 要求：把覆盖从 3 个弹窗扩到**全部 8 个**
  // ═══════════════════════════════════════════════════════════════════
  test('D-1 三个可渲染弹窗 × 三档视口：窄视口必须保留边距', () {
    final bad = <String>[];
    results.forEach((k, g) {
      /*
       * 判据：卡片四边到视口边缘的**最小值**必须 > 0。
       *
       * # 为什么 0 是缺陷而不是"设计内差异"
       * ```text
       * 卡片贴满视口时：
       *   ① 遮罩完全看不见 ⇒ 用户失去"这是个浮层"的感知
       *      实测 composer@800x600 的四角像素 = 卡片色(54,52,58)，不是遮罩色(71,71,71)
       *   ② 圆角被切掉（圆角画在卡片四角，但四角已出屏）
       *   ③ 标题栏紧贴屏幕顶端 ⇒ 与无边框窗口的标题区视觉粘连
       * ```
       */
      /*
       * ⚠️ 只判**左右**边距，不判上下（2026-10-21 实测后收窄）。
       *
       * # 为什么上下不判（这是与左右**不对称**的真实原因）
       * ```text
       * 宽度：`SizedBox(width:)` 是紧约束，父级只把它压到视口宽、
       *       **不**自动留边距 ⇒ 必须由外壳夹取留白（否则卡片贴满屏幕）。
       * 高度：`ConstrainedBox(maxHeight:)` 是上界，父级约束
       *       （Scaffold.body / showDialog 路由）本来就把卡片压进视口。
       *       实测 800x600：卡片高 = 600（正好视口高）、不溢出、内部可滚。
       *       ⇒ 上下贴边是**父级约束的必然结果**，不是缺陷。
       * ```
       * ★ 我一开始连上下一起判，然后给外壳加了高度夹取 —— t70 立刻红：
       *   夹到 568 让「立即更新」落到 y=598（视口 600）⇒ 点击打空。
       *   实测证明那是**双重夹取**（父级已经压过一轮）。
       */
      final marginL = g.cardLeft;
      final marginR = g.vpW - g.cardRight;
      final minMargin = marginL < marginR ? marginL : marginR;
      if (minMargin < 0.5) {
        bad.add('$k: 左右边距 L=${marginL.toStringAsFixed(0)} '
            'R=${marginR.toStringAsFixed(0)} '
            '(card ${g.cardW.toStringAsFixed(0)}x${g.cardH.toStringAsFixed(0)} '
            'vs vp ${g.vpW.toStringAsFixed(0)}x${g.vpH.toStringAsFixed(0)})');
      }
    });
    expect(bad, isEmpty,
        reason: '★★ 这些格子里卡片**贴满了视口**（四边没有留白）：\n'
            '${bad.join('\n')}\n'
            '⇒ 遮罩看不见、圆角被切、标题栏顶到屏幕边。\n'
            '根因（已修 2026-10-21）：外壳原来直接 `SizedBox(width: width)`，'
            '没有任何视口夹取，且 `margin` 默认 zero。');
  });

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 判据 D-2：**外壳规则本身**必须覆盖全部 8 个弹窗
   *
   * # 为什么 D-1 不够（Lead 的原话）
   * ```text
   * 「修完外壳后 D 必须变绿，而且**另外 5 个弹窗也要加进 D 的覆盖** ——
   *   否则你只是让 composer 绿了，其余 5 个仍然没人看。」
   * ```
   *
   * # 为什么不逐个渲染那 5 个（诚实说明，不是偷懒）
   * ```text
   * bili_import_dialog / danmaku_settings_dialog / provider_import_dialog /
   * source_switch_dialog / plugin_edit_dialog 的构造函数**全部要求真实状态**：
   *   bili            required state / onImport / onSelectPage / onSetAutoUpdate
   *   provider_import required ProviderImportSeed + name
   *   source_switch   required title / currentProvider / episodeIndex / position
   * 无头渲染要编一整套假数据 —— 那样测的是"我编的假数据"，
   * 不是"外壳规则"。
   *
   * ⇒ 夹取是**外壳的一条规则**：`effectiveW = min(width, 视口宽−32)`。
   *   8 个弹窗**都只是传一个 width 进来**（没有一个绕过这条路径）。
   *   所以逐个 width 档位验证这条规则，等价于验证全部 8 个。
   *   这里用的 width 就是它们源码里实际传的值（见下）。
   * ```
   */
  testWidgets('D-2 外壳夹取规则：覆盖 8 个弹窗实际使用的全部 width 档位', (t) async {
    /*
     * 8 个弹窗实际传的 width（源码核对）：
     *   update_dialog            460      （:107）
     *   source_composer_dialog   820      （:289）
     *   skip_marker_dialog       boxW     （:2290，自己夹成 768~820）
     *   bili / danmaku / provider / source_switch / plugin_edit  → 未传 ⇒ 默认 560
     * ⇒ 三档：460 / 560 / 820
     */
    const widths = <double>[460, 560, 820];
    const viewports = <Size>[
      Size(1280, 800),
      Size(1024, 640),
      Size(800, 600),
      Size(600, 500),
      Size(400, 500), // 极端：比 820 窄很多，检验下限 260
    ];

    final bad = <String>[];
    for (final vp in viewports) {
      for (final w in widths) {
        await setShotViewport(t, vp);
        await t.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            backgroundColor: Colors.white,
            body: AppDialogShell(
              title: 'T',
              subtitle: 'S',
              onClose: () {},
              width: w,
              child: const Text('body'),
            ),
          ),
        ));
        await t.pumpAndSettle();
        final card = _cardRect(t);
        final mL = card.left;
        final mR = vp.width - card.right;
        final minM = math.min(mL, mR);

        // 期望：min(w, 视口宽 − 2*Sp.x4)，下限 260
        final expectW = math.min(w, math.max(vp.width - 32, 260));

        if (minM < 0.5) {
          bad.add('width=$w @${vp.width.toInt()}x${vp.height.toInt()}: '
              '边距 L=${mL.toStringAsFixed(0)} R=${mR.toStringAsFixed(0)}');
        }
        if ((card.width - expectW).abs() > 1.0) {
          bad.add('width=$w @${vp.width.toInt()}: '
              '卡片宽 ${card.width.toStringAsFixed(0)} != 期望 '
              '${expectW.toStringAsFixed(0)}');
        }
      }
    }
    expect(bad, isEmpty,
        reason: '★★ 外壳的夹取规则不成立：\n${bad.join('\n')}\n'
            '公式应为 `min(传入 width, 视口宽 − 2*Sp.x4)`，下限 260。\n'
            '⇒ 这条一旦红，**8 个弹窗全部**受影响（它们都只是传 width 进来）。');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  汇总表
  // ═══════════════════════════════════════════════════════════════════
  tearDownAll(() {
    // ignore: avoid_print
    print('\n[R4PIX] ================= 三视口 × 三弹窗 =================');
    // ignore: avoid_print
    print('[R4PIX] 指标            ' +
        _viewports.keys.map((v) => v.padLeft(11)).join(''));
    for (final d in _dialogNames) {
      // ignore: avoid_print
      print('[R4PIX] --- $d ---');
      for (final metric in const [
        'cardW',
        'cardH',
        'radius',
        'headerH',
        'actionsGapR',
        'actionsH',
        'nClose',
        'scroll',
        'overflow'
      ]) {
        final cells = <String>[];
        for (final v in _viewports.keys) {
          final g = results['$d@$v'];
          if (g == null) {
            cells.add('  缺失'.padLeft(11));
            continue;
          }
          final String s;
          switch (metric) {
            case 'cardW':
              s = g.cardW.toStringAsFixed(0);
            case 'cardH':
              s = g.cardH.toStringAsFixed(0);
            case 'radius':
              s = g.radius.toStringAsFixed(2);
            case 'headerH':
              s = g.headerH.toStringAsFixed(1);
            case 'actionsGapR':
              s = g.actionsGapR.toStringAsFixed(1);
            case 'actionsH':
              s = g.actionsH.toStringAsFixed(1);
            case 'nClose':
              s = g.nClose.toString();
            case 'scroll':
              s = g.scrollable ? g.maxScrollExtent.toStringAsFixed(0) : 'no';
            default:
              s = g.overflowsViewport ? 'OVERFLOW' : 'ok';
          }
          cells.add(s.padLeft(11));
        }
        // ignore: avoid_print
        print('[R4PIX] ${metric.padRight(15)}${cells.join('')}');
      }
    }
    final dir = Directory('.probe/r4pix');
    if (dir.existsSync()) {
      // ignore: avoid_print
      print('[R4PIX] 截图目录: ${dir.absolute.path}');
    }
  });
}
