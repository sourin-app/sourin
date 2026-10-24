// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R3-① / R3-② 「弹窗整体看不清 / 里面的控件啊 文字啊」
//  —— **真渲染像素取证**（不是看常量、不是肉眼看截图）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，两条指向同一处）
// ```text
// R3-① 弹窗整体看不清
// R3-② 里面的控件啊 文字啊
// ```
//
// # 上一轮已排除的（本轮不重复取证）
// ```text
// 「字色对面板底色」的对比度 5.86~14.5:1 全达标
// （`t27_w1_danmaku_contrast_test.dart` 钉的是**常量对常量**）。
// ⇒ 所以"看不清"**不可能**是字色的锅 —— 那只剩一种可能：
//   **真实背景**不是那个常量色。
// ```
//
// # 本轮怎么量（关键：量渲染出来的真像素）
// ```text
// ① 弹窗底下压一张"最坏情况"底图（纯白 + 高饱和动画色块）
// ② `pumpWidget` 真渲染，`RepaintBoundary.toImage` 拿 RGBA 真像素
// ③ ★ 对**每一个 Text 控件的矩形**做直方图：
//      众数（出现最多的那个颜色）= 这一片的真实背景
//      第二众数                    = 文字笔画色
//    ⇒ 对比度 = 笔画色 vs 真实背景。**这是"文字压在什么上面"的直接读数。**
// ④ 同时量：字色 vs "卡片自己那块纯背景"（不含字形）
// ⑤ 同时量：遮罩/玻璃的压暗效果（面板内 vs 面板外）
// ```
//
// ⚠️ **不使用**屏幕截图 / `CopyFromScreen`（那会拍到 Owner 桌面，
//    本轮已出过一次事故）。全部在 flutter_tester 里渲染。
// ⚠️ 渲染前 `ClipDownloader.debugSetDataDir(<临时目录>)`，用完置 null。
//
// # 本轮实测结论（2026-10-19，读数逐字见各 test 里 print 出来的那几行）
// ```text
// 常量对 #14161B：      正文 14.50:1 · 次要 9.69:1 · 说明 5.86:1   ← 必然绿（对照）
// 信息面板真实渲染：     真实背景 rgb(114,115,118)
//                        正文 #F2F4F8 → **4.37:1**（< 4.5，AA 正文线不达标）
//                        说明 #9BA2AE → **2.06:1**（远低于 4.5）
// 设置弹窗真实渲染：     卡片内背景 rgb(92,93,96)
//                        正文 #E6E6E6 → 4.68:1（勉强过线）
//                        说明 #8E939B → **2.41:1**（远低于 4.5）
// 遮罩压暗：            底图白 rgb(255,255,255) → 遮罩后 rgb(71,71,71)
//                        → 卡片内 rgb(92,93,96)（**比遮罩还亮**，玻璃在提亮）
// 勾选框（16px 图形）：  与背景 3.74 ~ 8.19:1（大多达标）
// ```
// ⇒ **确证**：不是字色的问题，是**玻璃把底下的画面透进来了**：
//   面板内的"背景"根本不是 `panelBg #14161B`，而是被画面污染成的中灰
//   `rgb(92~114, …)`。灰阶文字压在**中灰**上 ⇒ 说明档掉到 2.0~2.4:1。
//   这正是 Owner 说的「整体看不清」「文字啊」。
//
// # 修法（已改，见两个 widget 的 `_Surface` / 玻璃档）
// ```text
// 给玻璃加一层**实色衬底**：在 GlassContainer 之下垫 `DanmakuTextColors.panelBg`
// 的高不透明度版本（α ≈ 0xE6 = 90%，即"玻璃化之前"那个值），
// 玻璃**只负责质感**（描边/模糊/高光），**不再负责遮光**。
// ⇒ 文字永远压在自己那一层实色上，与底图无关。
// ⚠️ 不是把玻璃删掉（Owner 要玻璃材质），是**把它从"遮光"职责上撤下来**。
// ```

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

// ══════════════════════════════════════════════════════════════════════
//  WCAG 相对亮度 / 对比度（直接吃真实像素）
// ══════════════════════════════════════════════════════════════════════

double _lin(int c) {
  final s = c / 255.0;
  return s <= 0.04045 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
}

double _lum(int r, int g, int b) =>
    0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b);

double _contrast(int r1, int g1, int b1, int r2, int g2, int b2) {
  final l1 = _lum(r1, g1, b1);
  final l2 = _lum(r2, g2, b2);
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

/// 一张真渲染出来的 RGBA 像素图
class _Pixels {
  _Pixels(this.width, this.height, this._b);

  final int width;
  final int height;
  final Uint8List _b;

  (int, int, int) at(int x, int y) {
    final xx = x.clamp(0, width - 1);
    final yy = y.clamp(0, height - 1);
    final i = (yy * width + xx) * 4;
    return (_b[i], _b[i + 1], _b[i + 2]);
  }

  /// 一个矩形里出现最多的颜色（= 那一片的**真实背景**）
  ///
  /// ⚠️ 这是本探针的核心手法：背景像素数远多于字形像素，
  ///    所以**众数就是背景**。之前按"最亮点"取，量到的是字形本身 —— 假红。
  ({int r, int g, int b, int n}) modal(Rect r) {
    final hist = <int, int>{};
    final x0 = r.left.floor();
    final x1 = r.right.ceil();
    final y0 = r.top.floor();
    final y1 = r.bottom.ceil();
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        final (rr, gg, bb) = at(x, y);
        final k = (rr << 16) | (gg << 8) | bb;
        hist[k] = (hist[k] ?? 0) + 1;
      }
    }
    if (hist.isEmpty) return (r: 0, g: 0, b: 0, n: 0);
    var bestK = 0;
    var bestN = -1;
    hist.forEach((k, n) {
      if (n > bestN) {
        bestN = n;
        bestK = k;
      }
    });
    return (
      r: (bestK >> 16) & 0xFF,
      g: (bestK >> 8) & 0xFF,
      b: bestK & 0xFF,
      n: bestN,
    );
  }

  /// 矩形里除**字色族**之外出现最多的颜色（= 真正的背景）
  ///
  /// 用在"众数恰好是字色"的那种矩形上（短文本 / 被遮挡），
  /// 见调用处的说明：直方图本身分不出"大面积前景"与"背景"。
  ({int r, int g, int b, int n}) modalExcludingForeground(
    Rect r,
    bool Function(int, int, int) isFg,
  ) {
    final hist = <int, int>{};
    for (var y = r.top.floor(); y < r.bottom.ceil(); y++) {
      for (var x = r.left.floor(); x < r.right.ceil(); x++) {
        final (rr, gg, bb) = at(x, y);
        if (isFg(rr, gg, bb)) continue;
        final k = (rr << 16) | (gg << 8) | bb;
        hist[k] = (hist[k] ?? 0) + 1;
      }
    }
    if (hist.isEmpty) return (r: 0, g: 0, b: 0, n: 0);
    var bestK = 0;
    var bestN = -1;
    hist.forEach((k, n) {
      if (n > bestN) {
        bestN = n;
        bestK = k;
      }
    });
    return (
      r: (bestK >> 16) & 0xFF,
      g: (bestK >> 8) & 0xFF,
      b: bestK & 0xFF,
      n: bestN,
    );
  }

  /// 矩形里**属于前景族**且出现最多的颜色（= 笔画色，跳过抗锯齿中间色）
  ///
  /// ⚠️ 与 [secondModal] 的区别：那个只排除"一个"，会量到
  ///    rgb(79,83,90) / rgb(110,115,124) 这类**抗锯齿过渡色**
  ///    （实测它们在与背景混合后仍有 56 px），从而低估对比度。
  ///    这里只接受前景族里的颜色 —— 那是笔画**真正**的颜色。
  ({int r, int g, int b, int n}) modalForeground(
    Rect r,
    ({int r, int g, int b, int n}) bg,
    bool Function(int, int, int) isFg,
  ) {
    final hist = <int, int>{};
    for (var y = r.top.floor(); y < r.bottom.ceil(); y++) {
      for (var x = r.left.floor(); x < r.right.ceil(); x++) {
        final (rr, gg, bb) = at(x, y);
        if (!isFg(rr, gg, bb)) continue;
        final k = (rr << 16) | (gg << 8) | bb;
        hist[k] = (hist[k] ?? 0) + 1;
      }
    }
    if (hist.isEmpty) return (r: 0, g: 0, b: 0, n: 0);
    var bestK = 0;
    var bestN = -1;
    hist.forEach((k, n) {
      if (n > bestN) {
        bestN = n;
        bestK = k;
      }
    });
    return (
      r: (bestK >> 16) & 0xFF,
      g: (bestK >> 8) & 0xFF,
      b: bestK & 0xFF,
      n: bestN,
    );
  }

  /// 矩形里除 [excludeRgb] 之外出现最多的颜色（= 字形笔画色）
  ({int r, int g, int b, int n}) secondModal(
    Rect r,
    ({int r, int g, int b, int n}) exclude,
  ) {
    final hist = <int, int>{};
    for (var y = r.top.floor(); y < r.bottom.ceil(); y++) {
      for (var x = r.left.floor(); x < r.right.ceil(); x++) {
        final (rr, gg, bb) = at(x, y);
        if (rr == exclude.r && gg == exclude.g && bb == exclude.b) continue;
        final k = (rr << 16) | (gg << 8) | bb;
        hist[k] = (hist[k] ?? 0) + 1;
      }
    }
    if (hist.isEmpty) return (r: 0, g: 0, b: 0, n: 0);
    var bestK = 0;
    var bestN = -1;
    hist.forEach((k, n) {
      if (n > bestN) {
        bestN = n;
        bestK = k;
      }
    });
    return (
      r: (bestK >> 16) & 0xFF,
      g: (bestK >> 8) & 0xFF,
      b: bestK & 0xFF,
      n: bestN,
    );
  }
}

Future<_Pixels> _rasterize(WidgetTester t, Finder finder) async {
  final boundary = t.renderObject<RenderRepaintBoundary>(finder);
  late _Pixels out;
  await t.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 1.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    out = _Pixels(img.width, img.height, bd!.buffer.asUint8List());
    img.dispose();
  });
  return out;
}

/// "最坏情况"底图：纯白 + 高饱和动画色块
///
/// # 为什么不能用纯黑底
/// ```text
/// 纯黑底下任何半透明深色都"看得清" ⇒ 会得出假绿。
/// 视频画面的真实分布里既有纯白（雪景/亮字幕板）也有高饱和（动画）。
/// ```
Widget _worstCaseBackdrop() => Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: Colors.white)),
        Positioned(
          left: 0,
          top: 120,
          width: 420,
          height: 260,
          child: const ColoredBox(color: Color(0xFFFF2D55)),
        ),
        Positioned(
          left: 400,
          top: 40,
          width: 400,
          height: 300,
          child: const ColoredBox(color: Color(0xFF00E5FF)),
        ),
        Positioned(
          left: 240,
          top: 340,
          width: 520,
          height: 260,
          child: const ColoredBox(color: Color(0xFFFFEB3B)),
        ),
      ],
    );

/// 三档字色的标本（**必须**与产品常量同一个值，⓪ 组会断言这一点）
const _bodyStyle = TextStyle(color: DanmakuTextColors.body, fontSize: FontSizes.sm);
const _secondaryStyle =
    TextStyle(color: DanmakuTextColors.secondary, fontSize: FontSizes.sm);
const _mutedStyle = TextStyle(color: DanmakuTextColors.muted, fontSize: FontSizes.cap);

/// 正文线（WCAG AA）
const double kBodyLine = 4.5;

void main() {
  late Directory tmp;
  setUp(() {
    UiPrefs.debugResetForTest();
    // ★ 铁律：渲染前把数据目录指到临时目录（不碰用户真实配置）
    tmp = Directory.systemTemp.createTempSync('r3_pixel_');
    ClipDownloader.debugSetDataDir(tmp.path);
  });
  tearDown(() {
    ClipDownloader.debugSetDataDir(null); // ★ 用完置 null
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
    UiPrefs.debugResetForTest();
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⓪ 取证前提（防止"量的是我编的颜色"）
  // ═══════════════════════════════════════════════════════════════════
  group('⓪ 取证前提', () {
    test('★★★ 三档字色标本与产品常量一致', () {
      expect(_bodyStyle.color, DanmakuTextColors.body);
      expect(_secondaryStyle.color, DanmakuTextColors.secondary);
      expect(_mutedStyle.color, DanmakuTextColors.muted);
      expect(DanmakuTextColors.body, const Color(0xFFE6E6E6));
      expect(DanmakuTextColors.secondary, const Color(0xFFB9BEC6));
      expect(DanmakuTextColors.muted, const Color(0xFF8E939B));
    });

    test('★★ 常量对面板底色仍达标（上一轮结论的对照）', () {
      const cBody = 14.50; // 对 #14161B 的既有实测值（t27_w1）
      final actual = _contrast(0xE6, 0xE6, 0xE6, 0x14, 0x16, 0x1B);
      // ignore: avoid_print
      print('[R3-①②] 对照：正文对 #14161B = ${actual.toStringAsFixed(2)}:1 '
          '（t27_w1 记录 ${cBody.toStringAsFixed(2)}:1）');
      expect((actual - cBody).abs(), lessThan(0.2),
          reason: '★ 与 t27_w1 同口径，证明本文件的对比度算法与既有门禁一致');
      expect(actual, greaterThanOrEqualTo(kBodyLine));
      /*
       * ⇒ 这条**必然绿**。它的作用是**对照**：
       *   下面"真实像素"那几组若红，而这条绿，
       *   就把病灶精确定位在"真实背景"上，而不是字色。
       */
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 弹幕信息面板 —— 逐 Text 量"文字压在什么背景上"
  // ═══════════════════════════════════════════════════════════════════
  group('① 弹幕信息面板：每一条文字的真实背景 + 真实对比度', () {
    Future<void> mount(WidgetTester t) async {
      t.view.physicalSize = const Size(900, 700);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey<String>('whole1'),
            child: Stack(
              children: [
                Positioned.fill(child: _worstCaseBackdrop()),
                Positioned(
                  top: 20,
                  right: 20,
                  child: DanmakuInfoPanel(
                    initiallyExpanded: true,
                    data: DanmakuInfoData(
                      source: DanmakuFeedKind.bili,
                      match: DanmakuPairKind.autoSearch,
                      count: 1200,
                      title: '鬼灭之刃 柱训练篇',
                      cid: 1602741036,
                      enabled: true,
                      sourceName: '外部视频站直连 · cid 1602741036',
                      updatedAt:
                          DateTime.now().subtract(const Duration(minutes: 3)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('★★★ 正文/说明两档：真实背景上的对比度必须 ≥ 4.5', (t) async {
      await mount(t);
      final px = await _rasterize(t, find.byKey(const ValueKey<String>('whole1')));

      /*
       * # 量法（这是本探针最要紧的一段）
       * ```text
       * 对每个 Text 的**矩形**做颜色直方图：
       *   众数   = 这一片的真实背景（背景像素数远多于字形）
       *   次众数 = 字形笔画色
       * ⇒ 对比度 = 笔画 vs 真实背景。
       * ★ 不按"最亮点"取 —— 那样量到的是字形自己（第一版就是这么假红的）。
       * ```
       * # ⚠️ 为什么还要"按本面板的字色族反查"
       * ```text
       * 有的 Text 矩形**只覆盖笔画**（例如 `_kv` 的值列在短文本时，
       * 或者某段文字被前一个文本遮挡）。此时众数就是字色本身 ——
       * 直方图分不出"谁是背景"。
       *
       * ⇒ 本面板的字色是**固定三档**（#F2F4F8 / #9BA2AE / #ACB3BF …），
       *   它们对**任何**真实背景都只应作为"前景"出现。
       *   所以：若众数落在这三档附近 ⇒ **它一定是字色**，
       *   真正的背景是"除字色族之外出现最多的那个颜色"。
       * ```
       * 这不是为了让门禁变绿而放宽 —— 它修的是**判据本身的歧义**
       * （直方图无法区分"大面积的前景"与"背景"）。
       */
      bool isForegroundOfPanel(int r, int g, int b) {
        // 本面板用到的三档 + 两枚强调色 + 白色；都按"接近"判（±6）
        const fgs = <(int, int, int)>[
          (0xF2, 0xF4, 0xF8), // _fg
          (0x9B, 0xA2, 0xAE), // _fgDim
          (0x7F, 0xB2, 0xFF), // _accent
          (0xFF, 0xB4, 0x54), // _warn
          (0xFF, 0x6B, 0x6B), // _danger
          (0xFF, 0xFF, 0xFF),
        ];
        for (final (fr, fg, fb) in fgs) {
          if ((r - fr).abs() <= 6 && (g - fg).abs() <= 6 && (b - fb).abs() <= 6) {
            return true;
          }
        }
        return false;
      }

      final results = <String, (Rect, ({int r, int g, int b, int n}), ({int r, int g, int b, int n}))>{
      };
      for (final e in find.byType(Text).evaluate()) {
        final w = e.widget as Text;
        final txt = w.data;
        if (txt == null || txt.isEmpty) continue;
        final rect = t.getRect(find.byWidget(w));
        // 跳过空矩形（未布局 / 被裁掉）
        if (rect.width < 1 || rect.height < 1) continue;
        final m = px.modal(rect);
        final ({int r, int g, int b, int n}) bg;
        final ({int r, int g, int b, int n}) fg;
        /*
         * ★★ 判据修正（本轮实测踩到的真歧义）
         * ```text
         * 直方图**无法**区分"大面积的前景"与"背景"：
         *   实测 `鬼灭之刃 柱训练篇` 的矩形里 rgb(32,34,38) 有 2244 px、
         *   rgb(155,162,174) 只有 324 px —— 前者是**背景**，后者是**笔画**。
         * 但短文本（如 "1200 条" 里的数字笔画）可能反过来。
         *
         * 唯一可靠的判据是**这个面板的字色族是固定的三档**：
         *   _fg #F2F4F8 / _fgDim #9BA2AE / _accent #7FB2FF / _warn / _danger / 白
         * ⇒ 凡落在这几档附近的，**一定是前景**；背景取"除它们之外最多的颜色"。
         * ```
         * 这不是放宽 —— 它把"谁是背景"从**猜**变成**知道**。
         */
        if (isForegroundOfPanel(m.r, m.g, m.b)) {
          bg = px.modalExcludingForeground(rect, isForegroundOfPanel);
          fg = m;
        } else {
          bg = m;
          // 笔画色：取除背景外最多的，且**必须是前景族**（否则量到的是抗锯齿中间色）
          fg = px.modalForeground(rect, bg, isForegroundOfPanel);
        }
        results[txt] = (rect, bg, fg);
      }

      expect(results.length, greaterThanOrEqualTo(6),
          reason: '读到的 Text 太少 —— 面板没渲染出来，判据失效');

      // 逐条打读数（红的时候这就是证据）
      final failures = <String>[];
      for (final entry in results.entries) {
        final (rect, bg, fg) = entry.value;
        final c = _contrast(fg.r, fg.g, fg.b, bg.r, bg.g, bg.b);
        // ignore: avoid_print
        print('[R3-①②] "${entry.key}" 背景 rgb(${bg.r},${bg.g},${bg.b}) '
            '字 rgb(${fg.r},${fg.g},${fg.b}) = ${c.toStringAsFixed(2)}:1');
        if (c < kBodyLine) failures.add('"${entry.key}" ${c.toStringAsFixed(2)}:1');
      }

      /*
       * ★ 面板是**固定暗浮层**（`_fg #F2F4F8` / `_fgDim #9BA2AE`），
       *   它**不读主题 surface** —— 文件头写得很清楚："浮在视频画面上"。
       *   所以每一条对它自己的真实背景都必须过 4.5:1。
       */
      expect(failures, isEmpty,
          reason: '★★★ 这些文字压在真实背景上不达标（WCAG AA 正文线 4.5:1）：\n'
              '${failures.join("\n")}\n'
              '—— 根因：玻璃把底下的画面透进来，'
              '"背景"不再是 #14161B 而是中灰。Owner 说的「看不清」就是它。');
    });

    testWidgets('★★★ 玻璃底下必须有**实色衬底**（面板内背景 ≈ 面板色，不是画面色）',
        (t) async {
      await mount(t);
      final px = await _rasterize(t, find.byKey(const ValueKey<String>('whole1')));

      /*
       * # 这条是"机制判据"（上一条是"结果判据"）
       * ```text
       * 上一条问：够不够亮？
       * 这条问：  背景**是什么颜色**？
       *
       * 面板的语义色是 `DanmakuTextColors.panelBg` = #14161B = rgb(20,22,27)。
       * 它是一层**不透明的暗浮层**（文件头：浮在视频画面上、不读 surface）。
       * ⇒ 渲染出来的"背景"必须接近它。
       *
       * 改前实测：rgb(114,115,118) —— 比 #14161B 亮了 4~5 倍，
       *          那是**底下白底透上来**的结果。
       * ```
       * 判据：背景亮度不超过 panelBg 的 2 倍（留玻璃高光的余量）。
       */
      final panel = find.byType(DanmakuInfoPanel);
      final rect = t.getRect(panel);
      // 取一块**确定为空白**的区域：面板左下角内缩
      final probe = Rect.fromLTWH(
        rect.left + 10,
        rect.bottom - 14,
        rect.width - 20,
        8,
      );
      final bg = px.modal(probe);
      final c = _contrast(bg.r, bg.g, bg.b, 0x14, 0x16, 0x1B);
      final lumBg = _lum(bg.r, bg.g, bg.b);
      final lumPanel = _lum(0x14, 0x16, 0x1B);
      // ignore: avoid_print
      print('[R3-①②] 信息面板真实背景 rgb(${bg.r},${bg.g},${bg.b})，'
          '对 panelBg #14161B = ${c.toStringAsFixed(2)}:1，'
          '亮度 ${lumBg.toStringAsFixed(3)} vs ${lumPanel.toStringAsFixed(3)}');

      expect(
        lumBg,
        lessThan(lumPanel * 2.0 + 0.02),
        reason: '★★★ 面板背景 rgb(${bg.r},${bg.g},${bg.b}) 比面板色 #14161B '
            '亮 ${(lumBg / lumPanel).toStringAsFixed(1)} 倍 —— '
            '说明玻璃在**透光**而不是遮光，文字压在画面上了',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 弹幕设置弹窗 —— 同一套量法
  // ═══════════════════════════════════════════════════════════════════
  group('② 弹幕设置弹窗：每一条文字的真实背景 + 真实对比度', () {
    Future<void> mount(WidgetTester t) async {
      t.view.physicalSize = const Size(1100, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey<String>('whole2'),
            child: Stack(
              children: [
                Positioned.fill(child: _worstCaseBackdrop()),
                Positioned.fill(
                  child: DanmakuSettingsDialog(
                    fill: false,
                    state: const DanmakuSettingsState(
                      enabled: true,
                      appId: '',
                      appSecret: '',
                      fontScale: 1,
                      opacity: 1,
                      speed: 8,
                      area: 1,
                    ),
                    onSetEnabled: (_) {},
                    onSetFontScale: (_) {},
                    onSetOpacity: (_) {},
                    onSetSpeed: (_) {},
                    onSetArea: (_) {},
                    onReload: () {},
                    onClose: () {},
                    biliCount: 1200,
                    onOpenBili: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('★★★ 面板里每条文字的真实对比度必须 ≥ 4.5', (t) async {
      await mount(t);
      final px = await _rasterize(t, find.byKey(const ValueKey<String>('whole2')));

      // 卡片内部才有意义：外壳是 Positioned.fill，取卡片（Material）矩形
      final card = find.byType(AppDialogShell);
      final cardRect = t.getRect(card);

      final failures = <String>[];
      var measured = 0;
      for (final e in find.byType(Text).evaluate()) {
        final w = e.widget as Text;
        final txt = w.data;
        if (txt == null || txt.trim().isEmpty) continue;
        final rect = t.getRect(find.byWidget(w));
        if (rect.width < 2 || rect.height < 2) continue;
        // 只量落在卡片里的（外面的属于遮罩/底图）
        if (!cardRect.contains(rect.center)) continue;
        final bg = px.modal(rect);
        final fg = px.secondModal(rect, bg);
        // 字形像素太少 ⇒ 这个小矩形里根本读不到字（例如纯色块），跳过
        if (fg.n < 6) continue;
        measured++;
        final c = _contrast(fg.r, fg.g, fg.b, bg.r, bg.g, bg.b);
        // ignore: avoid_print
        print('[R3-①②] 弹窗 "$txt" 背景 rgb(${bg.r},${bg.g},${bg.b}) '
            '字 rgb(${fg.r},${fg.g},${fg.b}) = ${c.toStringAsFixed(2)}:1');
        if (c < kBodyLine) {
          failures.add('"$txt" ${c.toStringAsFixed(2)}:1 '
              '(字 rgb(${fg.r},${fg.g},${fg.b}) 压 rgb(${bg.r},${bg.g},${bg.b}))');
        }
      }

      expect(measured, greaterThanOrEqualTo(8),
          reason: '在卡片里只量到 $measured 条 Text —— 太少了，判据失效');

      expect(failures, isEmpty,
          reason: '★★★ 弹窗里这些文字在**真实背景**上不达标（4.5:1）：\n'
              '${failures.join("\n")}\n'
              '—— 这就是 Owner 说的「弹窗整体看不清 / 里面的文字啊」');
    });

    testWidgets('★★★ 卡片里的背景不许比遮罩更亮（玻璃必须遮光，不能提亮）',
        (t) async {
      await mount(t);
      final px = await _rasterize(t, find.byKey(const ValueKey<String>('whole2')));
      final cardRect = t.getRect(find.byType(AppDialogShell));

      /*
       * # 为什么这条能抓"玻璃透光"
       * ```text
       * 卡片外 = 底图 × 遮罩（黑 α0.72）
       * 卡片内 = 那之上再叠玻璃 + 卡片底
       * 玻璃如果有实质遮光 ⇒ 卡片内**必然更暗**。
       * 实测改前：遮罩后 rgb(71,71,71) → 卡片内 rgb(92,93,96)
       *          **卡片内比遮罩还亮** ⇒ 玻璃没有遮光，反而在提亮（高光/半透明叠加）。
       * ```
       * ⚠️ 玻璃的"提亮"本身不一定是错（液玻璃有高光），
       *    但**高光只能是小面积**；这里量的是**众数**（大面积底色）。
       */
      final outRect = Rect.fromLTWH(
        cardRect.left + 40,
        cardRect.top - 30 < 0 ? 2 : cardRect.top - 30,
        40,
        10,
      );
      final insideRect = Rect.fromLTWH(
        cardRect.left + 40,
        cardRect.center.dy - 4,
        40,
        8,
      );
      final out = px.modal(outRect);
      final inside = px.modal(insideRect);
      final lOut = _lum(out.r, out.g, out.b);
      final lIn = _lum(inside.r, inside.g, inside.b);
      // ignore: avoid_print
      print('[R3-①②] 弹窗遮罩 rgb(${out.r},${out.g},${out.b}) 亮度 '
          '${lOut.toStringAsFixed(3)} → 卡片内 rgb(${inside.r},${inside.g},'
          '${inside.b}) 亮度 ${lIn.toStringAsFixed(3)}');

      expect(lIn, lessThanOrEqualTo(lOut * 1.05 + 0.005),
          reason: '★★★ 卡片内 rgb(${inside.r},${inside.g},${inside.b}) 比遮罩 '
              'rgb(${out.r},${out.g},${out.b}) 更亮 —— '
              '玻璃没有承担遮光（透光=文字压在画面上）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 控件区（R3-② 的"控件啊"）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 控件：勾选框/开关与它所在行的背景', () {
    testWidgets('★★ 「弹幕来源」页签里的勾选框应当与背景可辨（≥ 3:1）',
        (t) async {
      t.view.physicalSize = const Size(1100, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey<String>('whole3'),
            child: Stack(
              children: [
                Positioned.fill(child: _worstCaseBackdrop()),
                Positioned.fill(
                  child: DanmakuSettingsDialog(
                    fill: false,
                    state: const DanmakuSettingsState(
                      enabled: true,
                      appId: '',
                      appSecret: '',
                      fontScale: 1,
                      opacity: 1,
                      speed: 8,
                      area: 1,
                    ),
                    onSetEnabled: (_) {},
                    onSetFontScale: (_) {},
                    onSetOpacity: (_) {},
                    onSetSpeed: (_) {},
                    onSetArea: (_) {},
                    onReload: () {},
                    onClose: () {},
                    biliCount: 1200,
                    onOpenBili: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      await t.tap(find.descendant(
        of: find.byType(SegmentedButton<DanmakuPanelTab>),
        matching: find.text('高级'),
      ));
      await t.pumpAndSettle();

      final px = await _rasterize(t, find.byKey(const ValueKey<String>('whole3')));

      for (final label in <String>['本片源自带', 'dan-api', '本机服务']) {
        final f = find.text(label);
        expect(f, findsOneWidget);
        final rowRect = t.getRect(f);
        // 勾选框在文字左边那一小片（16px 图标）
        final box = Rect.fromLTWH(
          rowRect.left - 26,
          rowRect.center.dy - 8,
          20,
          16,
        );
        final bg = px.modal(box);
        final icon = px.secondModal(box, bg);
        final c = _contrast(icon.r, icon.g, icon.b, bg.r, bg.g, bg.b);
        // ignore: avoid_print
        print('[R3-①②] 勾选框「$label」：图标 rgb(${icon.r},${icon.g},${icon.b}) '
            '压 rgb(${bg.r},${bg.g},${bg.b}) = ${c.toStringAsFixed(2)}:1');
        expect(c, greaterThanOrEqualTo(3.0),
            reason: '★★ 控件「$label」的勾选框与背景只有 ${c.toStringAsFixed(2)}:1'
                '（WCAG 非文字图形线 3:1）—— 这就是"控件看不清"');
      }
    });
  });
}
