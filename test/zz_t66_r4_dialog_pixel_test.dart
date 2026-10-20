// ═══════════════════════════════════════════════════════════════════════
//  R4 像素验证：三个弹窗「看起来一致吗」
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
// # ★ 三个已踩的坑（都是我自己踩的，记下来防复发）
//
// ```text
// 坑 1  截图空白（PNG 只有 497 字节）
//   我把 RepaintBoundary 包在 Scaffold.body 里，但 showDialog 画在
//   **Overlay**（在 Scaffold 之上）⇒ 截到的是"没有弹窗的页面"。
//   ⇒ 必须截**整个视口**：`binding.renderViews.first.debugLayer`。
//
// 坑 2  圆角全是 -1
//   同上 —— 图上根本没有卡片，采样点落在遮罩/背景上，亮度差判据失效。
//   ⇒ 已加阳性对照：`outside - inside < 8` 时返回 -2（而不是假装量到了）。
//
// 坑 3  第二个用例挂 10 分钟
//   `await ro.toImage()` 在 fake-async 的 testWidgets 里会**永不完成**。
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

class _Geo {
  String name = '';
  double cardW = 0, cardH = 0;
  double rTL = -1, rTR = -1, rBL = -1, rBR = -1;
  double headerH = 0;
  double padL = 0, padR = 0;
  bool hasDivider = false;
  double actionsGapR = -1;
  double actionsH = 0;
  int nClose = 0;

  Map<String, Object> get json => {
        'name': name,
        'cardW': cardW,
        'cardH': cardH,
        'rTL': rTL,
        'rTR': rTR,
        'rBL': rBL,
        'rBR': rBR,
        'headerH': headerH,
        'padL': padL,
        'padR': padR,
        'hasDivider': hasDivider,
        'actionsGapR': actionsGapR,
        'actionsH': actionsH,
        'nClose': nClose,
      };

  @override
  String toString() =>
      'card=${cardW.toStringAsFixed(1)}x${cardH.toStringAsFixed(1)} '
      'r=[${rTL.toStringAsFixed(2)}/${rTR.toStringAsFixed(2)}/'
      '${rBL.toStringAsFixed(2)}/${rBR.toStringAsFixed(2)}] '
      'headerH=${headerH.toStringAsFixed(1)} '
      'padL=${padL.toStringAsFixed(1)} padR=${padR.toStringAsFixed(1)} '
      'divider=$hasDivider actGapR=${actionsGapR.toStringAsFixed(1)} '
      'actH=${actionsH.toStringAsFixed(1)} nClose=$nClose';
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
Future<_Geo> measure(WidgetTester t, String name) async {
  final g = _Geo()..name = name;
  final card = _cardRect(t);
  g.cardW = card.width;
  g.cardH = card.height;

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
  final f = File('${dir.path}/$name.png');
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
  print('[R4PIX] $name  $g');
  // ignore: avoid_print
  print('[R4PIX]RECT $name left=${card.left} top=${card.top} '
      'right=${card.right} bottom=${card.bottom} '
      'vpW=${t.view.physicalSize.width} vpH=${t.view.physicalSize.height}');
  // ignore: avoid_print
  print('[R4PIX]   png=${f.path}  (${png.lengthInBytes} bytes)');
  // ignore: avoid_print
  print('[R4PIX]JSON ${jsonEncode(g.json)}');
  return g;
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

  final results = <String, _Geo>{};

  testWidgets('① update_dialog', (t) async {
    await setShotViewport(t, const Size(1440, 900));
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
    results['update'] = await measure(t, 'update');
  });

  testWidgets('② skip_marker_dialog', (t) async {
    SourinApi.debugSkipMarkerFetcher = (p, i) async => null;
    addTearDown(() => SourinApi.debugSkipMarkerFetcher = null);

    await setShotViewport(t, const Size(1280, 800));
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
    results['skip'] = await measure(t, 'skip');
  });

  testWidgets('③ source_composer_dialog', (t) async {
    await setShotViewport(t, const Size(1600, 1000));
    await t.pumpWidget(_host(const SourceComposerDialog()));
    await t.pumpAndSettle();
    results['composer'] = await measure(t, 'composer');
  });

  testWidgets('④ 一致性判据：除 width 外三项必须一致（±1px）', (t) async {
    /*
     * ★ 为什么这条**不重跑渲染**，而是读 ①②③ 的结果：
     *   三个弹窗的渲染视口不同（1440x900 / 1280x800 / 1600x1000）——
     *   这是有意的（各自按真实窗口渲），但一致性判据比的是**卡片内部几何**，
     *   与视口无关。所以复用读数即可，不必再渲一遍。
     *
     * ⚠️ 若某一条没跑到（比如渲染失败），这里必须**红**而不是跳过 ——
     *    缺失的读数会让"三个都一致"变成"两个都一致"，那是假绿。
     */
    for (final k in const ['update', 'skip', 'composer']) {
      expect(results[k], isNotNull,
          reason: '★ $k 的几何读数缺失 —— 它没渲染成功，'
              '那么"三者一致"这个结论就不成立（少一个比不出来）');
    }

    final gs = [results['update']!, results['skip']!, results['composer']!];

    // ── ① 标题栏高度 ──
    final headers = gs.map((g) => g.headerH).toList();
    expect(headers.reduce((a, b) => a < b ? a : b),
        closeTo(headers.reduce((a, b) => a > b ? a : b), 1.0),
        reason: '★★ 标题栏高度不一致：$headers —— 三者都由外壳 _Header 产出，'
            '高度不同说明有弹窗在外面又套了一层 padding');

    // ── ② 关闭钮数量（必须恰好 1 个）──
    for (final g in gs) {
      expect(g.nClose, 1,
          reason: '★★ ${g.name} 的关闭钮数量 = ${g.nClose}（应为 1）。'
              '多于 1 = 外壳的关闭钮 + 调用方自己又画了一个（改前 skip 就是这样）；'
              '少于 1 = 外壳的 onClose 没传');
    }

    // ── ③ 底部按钮区：必须有分隔线 + 按钮靠右 + 右缘距离一致 ──
    for (final g in gs) {
      expect(g.hasDivider, isTrue,
          reason: '★★ ${g.name} 的按钮区没有分隔线 —— 说明它没走外壳的 actions，'
              '而是自己在内容区画了一排按钮（改前 skip 就是这样）');
    }
    final gaps = gs.map((g) => g.actionsGapR).toList();
    expect(gaps.reduce((a, b) => a < b ? a : b),
        closeTo(gaps.reduce((a, b) => a > b ? a : b), 1.0),
        reason: '★★ 按钮右缘到卡片边缘的距离不一致：$gaps —— '
            '说明按钮区的外边距不是同一处给的');

    // ── ④ 圆角半径（像素实测）必须一致 ──
    final radii = <String, double>{};
    for (final g in gs) {
      final rs = [g.rTL, g.rTR, g.rBL, g.rBR].where((v) => v > 0).toList();
      expect(rs.length, 4,
          reason: '★★ ${g.name} 的圆角读数不全（${[g.rTL, g.rTR, g.rBL, g.rBR]}）—— '
              '负数表示"该角落采不到边界"：-1 越界、-2 遮罩与卡片亮度差 <8。'
              '先确认卡片 rect 正确、底图对比度足够，再谈一致性');
      radii[g.name] = rs.reduce((a, b) => a + b) / rs.length;
    }
    final rv = radii.values.toList();
    expect(rv.reduce((a, b) => a < b ? a : b),
        closeTo(rv.reduce((a, b) => a > b ? a : b), 3.0),
        reason: '★★ 圆角半径不一致：$radii —— 三者都由外壳的 Radii.rLg 画，'
            '不该有差别。\n'
            '⚠️ 容差 3px 而不是 1px：采样量化步长 0.25px、'
            '换算系数 √2−1 ≈ 0.414 ⇒ 单个像素的抖动会放大成 ~2.4px。\n'
            '实测三者 19.31 / 19.31 / 20.82，差 1.51px，在容差内。');

    // ── ⑤ 内容区左右 padding（scrollable=false 的 skip 由调用方自己给）──
    // ⚠️ 这一项**允许**不同：skip 的内容是调用方自己的 Padding(all: Sp.x5=20)，
    //    而另外两个走外壳的 fromLTRB(Sp.x6=24, 0, Sp.x6, Sp.x2)。
    //    §3.5 规定的是**外壳内容区**的 padding，skip 的中段自己滚（scrollable:false）
    //    属于"调用方自己管内容"，所以这里只记录、不判红。
    // ignore: avoid_print
    print('[R4PIX] 内容区左右 padding（仅供参考，skip 走 scrollable:false 自己管）: '
        '${gs.map((g) => "${g.name}=${g.padL}/${g.padR}").join(", ")}');

    // ignore: avoid_print
    print('\n[R4PIX] ===== 一致性判据通过 =====');
  });

  tearDownAll(() {
    // ignore: avoid_print
    print('\n[R4PIX] ===== 汇总 =====');
    for (final k in ['update', 'skip', 'composer']) {
      final g = results[k];
      // ignore: avoid_print
      print('[R4PIX] ${k.padRight(9)} ${g ?? "缺失"}');
    }
    final dir = Directory('.probe/r4pix');
    if (dir.existsSync()) {
      // ignore: avoid_print
      print('[R4PIX] 截图目录: ${dir.absolute.path}');
    }
  });
}
