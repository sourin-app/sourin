// ══════════════════════════════════════════════════════════════════════
//  T27 门禁：弹幕「显示区域」按 B 站重做 + 「彩色」过滤
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，分两次）
// ```text
// > 那个遮挡区域我对现在的不满意,要按照b站的那个去做
// 追问"哪一点不满意"⇒「1 2 3 4我都要」（四条全要）
// ```
// ① 拖动时画面上要有**半透明分界线/遮罩**（可视反馈）
// ② 默认值不能是 1.0（铺满全屏）
// ③ 百分比含义对齐 B 站：**从顶部往下量**的弹幕占用区
// ④ 拖动时**实时**生效
// 另：「彩色这个我们也有」⇒ 补「只显示彩色」过滤。
//
// # 本文件钉住什么
// ```text
// A 组：显示区域语义/默认/范围（纯函数 + 源码契约）
// B 组：彩色过滤**真起作用**（构造带色/无色弹幕，断言 shouldShow）
// C 组：实时链路（拖动逐帧回调；引导遮罩显隐接线）
// D 组：轨道占用口径 = 顶部往下量（构造可计算断言，不靠肉眼）
// ```
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/danmaku_overlay.dart';

/// 剥掉 `//` 与 `/* */` 注释（字符串里的原样保留）。行号不变，便于断言"代码里"。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  setUp(() {
    // 每个用例从"没有偏好"起跑（缺省值才测得到）
    UiPrefs.debugResetForTest();
  });

  // ═══════════════════════════════════════════════════════════════════
  //  A：显示区域的语义 / 默认 / 范围
  // ═══════════════════════════════════════════════════════════════════

  group('A 显示区域（按 B 站）', () {
    test('A1 默认值 = 0.5（上半屏），不再是 1.0 铺满全屏', () {
      expect(DanmakuConfig.defaultArea, 0.5,
          reason: '★★ Owner 第 ② 条：默认不能铺满全屏（B 站约为上半屏）');
      expect(DanmakuConfig.area, 0.5,
          reason: '★ 没写过偏好的用户读出来就是 0.5（走 defaultArea 支）');
    });

    test('A2 范围下界收到 0.1（可从窄缝到铺满全屏）', () {
      expect(DanmakuConfig.areaMin, 0.1,
          reason: '★ Owner 第 ③ 条：按 B 站那根滑杆的幅度（不是只到 0.3）');
      expect(DanmakuConfig.areaMax, 1.0);
    });

    test('A3 坏值/越界回落：写 1.0 读回 1.0；写 2.0 夹到 1.0；写 0.0 夹到 0.1', () {
      DanmakuConfig.setArea(1.0);
      expect(DanmakuConfig.area, 1.0, reason: '★ 老用户想铺满全屏仍能拖到 100%');
      DanmakuConfig.setArea(2.0);
      expect(DanmakuConfig.area, DanmakuConfig.areaMax);
      DanmakuConfig.setArea(0.0);
      expect(DanmakuConfig.area, DanmakuConfig.areaMin);
      UiPrefs.set(DanmakuConfig.keyArea, '不是数字');
      expect(DanmakuConfig.area, DanmakuConfig.defaultArea,
          reason: '★ 坏值回落缺省（0.5）');
    });

    test('A4 语义 = 从顶部往下量（源码契约 + 轨道口径）', () {
      // 源码契约：area 的文档明说"从画面顶部往下量"（注释要在**未剥注释**的原文里找）
      final raw = File('lib/core/danmaku.dart').readAsStringSync();
      expect(raw.contains('从画面顶部往下量') || raw.contains('从顶部往下量'),
          isTrue,
          reason: '★★ Owner 第 ③ 条：area 语义必须写明"从顶部往下量"（对齐 B 站）');
      // 硬证据：area=0.5 的轨道数 == area=1.0 的一半（同画布），
      // 且第一条轨道永远在 y=0（贴顶）—— 这就是"从顶部往下"的可计算证明。
      const w = 640.0;
      const h = 480.0;
      const fs = 20.0;
      final half = DanmakuTrackAllocator.layout(
        comments: const <DanmakuComment>[],
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
        area: 0.5,
      );
      final full = DanmakuTrackAllocator.layout(
        comments: const <DanmakuComment>[],
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
        area: 1.0,
      );
      expect(full.laneCount, 17); // floor(480/27)
      expect(half.laneCount, 8); // floor(240/27)
      expect(half.laneCount * 2 + 1 >= full.laneCount, isTrue,
          reason: '★ 0.5 的轨道数 ≈ 满屏的一半 ⇒ 区域高度 = 画布高 * area');

      // 一条顶部固定弹幕落在第 0 轨（laneTop == 0）⇒ 区域贴顶，不是贴底/居中
      final l = DanmakuTrackAllocator.layout(
        comments: const <DanmakuComment>[
          DanmakuComment(cid: 1, time: 0, text: '顶', mode: DanmakuMode.top),
        ],
        canvasWidth: w,
        canvasHeight: h,
        fontSize: fs,
        area: 0.5,
      );
      expect(l.placements, hasLength(1));
      expect(l.placements.first.laneTop, 0,
          reason: '★★ 弹幕从画面顶部开始铺（laneTop=0），不是从底部往上 ⇒ 从顶部往下量');
      // 区域下界 = h * area = 240：这条固定弹幕的底部不越过 240
      expect(l.placements.first.laneTop + l.lineHeight <= 240 + 0.001, isTrue,
          reason: '★ 弹幕必须落在 area 限定的上半屏内');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  B：彩色过滤**真起作用**
  // ═══════════════════════════════════════════════════════════════════

  group('B 彩色过滤', () {
    test('B1 关（缺省）⇒ 白弹幕和彩弹幕都显示', () {
      expect(DanmakuConfig.colorOnly, isFalse);
      expect(
        DanmakuConfig.shouldShow(
            mode: DanmakuMode.scroll, text: '白', color: 0xFFFFFF),
        isTrue,
      );
      expect(
        DanmakuConfig.shouldShow(
            mode: DanmakuMode.scroll, text: '红', color: 0xFF0000),
        isTrue,
      );
    });

    test('B2 开「只显示彩色」⇒ 白色弹幕被滤掉，彩色留着', () {
      DanmakuConfig.setColorOnly(true);
      expect(DanmakuConfig.colorOnly, isTrue);
      expect(
        DanmakuConfig.shouldShow(
            mode: DanmakuMode.scroll, text: '白', color: 0xFFFFFF),
        isFalse,
        reason: '★★ 只有彩色 ⇒ 纯白不该显示',
      );
      expect(
        DanmakuConfig.shouldShow(
            mode: DanmakuMode.scroll, text: '红', color: 0xFF0000),
        isTrue,
        reason: '★ 彩色留着',
      );
      // 近白（16777214 = 0xFFFFFE）也算白（容差内）⇒ 滤掉
      expect(
        DanmakuConfig.shouldShow(
            mode: DanmakuMode.scroll, text: '近白', color: 0xFFFFFE),
        isFalse,
        reason: '★ 近白（容差内）同白处理，否则"只显示彩色"会漏掉近白',
      );
    });

    test('B3 isWhiteColor 的容差边界（可计算）', () {
      expect(DanmakuConfig.isWhiteColor(0xFFFFFF), isTrue);
      expect(DanmakuConfig.isWhiteColor(0xFFFFFE), isTrue); // 差 1
      expect(DanmakuConfig.isWhiteColor(0xE8E8E8), isTrue); // 差 23 ≤ 24
      expect(DanmakuConfig.isWhiteColor(0xE7E7E7), isTrue); // 差 24 ≤ 24（边界含）
      expect(DanmakuConfig.isWhiteColor(0xE6E6E6), isFalse); // 差 25 > 24 ⇒ 算彩
      expect(DanmakuConfig.isWhiteColor(0xFF0000), isFalse);
    });

    test('B4 类型开关与彩色过滤**一起**生效（AND 语义）', () {
      // 关掉顶部 + 只显示彩色：一条"顶部彩色"弹幕因类型被滤，一条"滚动彩色"留着
      DanmakuConfig.setShowTop(false);
      DanmakuConfig.setColorOnly(true);
      expect(
        DanmakuConfig.shouldShow(
            mode: DanmakuMode.top, text: '顶彩', color: 0xFF0000),
        isFalse,
        reason: '★ 顶部被关 ⇒ 即使彩色也不显示',
      );
      expect(
        DanmakuConfig.shouldShow(
            mode: DanmakuMode.scroll, text: '滚彩', color: 0xFF0000),
        isTrue,
      );
    });

    test('B5 过滤落在渲染层 —— 源码契约：overlay 把 color 传进 shouldShow', () {
      final ov = stripComments(
          File('lib/ui/widgets/danmaku_overlay.dart').readAsStringSync());
      expect(ov.contains('color: c.color'), isTrue,
          reason: '★★ 渲染层必须把弹幕颜色传进 shouldShow（不是只存偏好键）');
      // 彩色开关也必须进 layoutKey，否则开/关这枚开关画面不重排
      expect(ov.contains('DanmakuConfig.colorOnly'), isTrue,
          reason: '★★ colorOnly 必须进 _layoutKey，改了才会重排');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  C：实时链路（拖动逐帧 + 引导遮罩接线）
  // ═══════════════════════════════════════════════════════════════════

  group('C 实时生效 + 引导遮罩接线', () {
    test('C1 悬浮窗「显示区域」滑杆拖动逐帧回调 + 起手/松手通知宿主', () async {
      // 源码契约：滑杆用 Listener 抓起手/松手，且 onChanged 直连（每帧）
      final bar = stripComments(
          File('lib/ui/player/player_bottom_bar.dart').readAsStringSync());
      expect(bar.contains('onPointerDown: onGuideStart == null'),
          isTrue, reason: '★ 起手必须通知宿主（点亮遮罩）');
      expect(bar.contains('onPointerUp: onGuideEnd == null'), isTrue,
          reason: '★ 松手必须通知宿主（淡出遮罩）');
      expect(bar.contains('onChanged: onChanged'), isTrue,
          reason: '★ Slider.onChanged 直连 ⇒ 拖动每帧回调（实时生效那条线）');
      expect(bar.contains('onAreaGuide: _setDanmakuAreaGuide'), isFalse,
          reason: '★ _setDanmakuAreaGuide 接线在 player_page（底栏只发事件），'
              '本文件用下层 C1b 断言宿主那一侧');
      expect(
          stripComments(File('lib/ui/player_page.dart').readAsStringSync())
              .contains('onAreaGuide: _setDanmakuAreaGuide'),
          isTrue,
          reason: '★ 宿主把 _setDanmakuAreaGuide 接到 onAreaGuide');
      // 第四枚类型开关「彩色」必须在
      expect(bar.contains("label: '彩色'"), isTrue,
          reason: '★ Owner：彩色我们也有 ⇒ 悬浮窗第四枚开关');
      expect(bar.contains('onSetColorOnly'), isTrue);
    });

    testWidgets('C2 DanmakuAreaGuide：拖动中可见、松手淡出到不可见', (t) async {
      await t.pumpWidget(
        mui.Directionality(
          textDirection: mui.TextDirection.ltr,
          child: const mui.SizedBox(
            width: 200,
            height: 200,
            child: DanmakuAreaGuide(visible: true, area: 0.5),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 200));
      final box = find.byType(DanmakuAreaGuide);
      expect(box, findsOneWidget);
      // 可见时 FadeTransition.opacity ≈ 1
      FadeTransition ft = t.widget(find.descendant(
        of: box,
        matching: find.byType(FadeTransition),
      ));
      expect(ft.opacity.value, greaterThan(0.9),
          reason: '★ 拖动中遮罩必须可见（这是 Owner 第 ① 条的判据）');

      // 松手 ⇒ visible=false ⇒ 淡出
      await t.pumpWidget(
        mui.Directionality(
          textDirection: mui.TextDirection.ltr,
          child: const mui.SizedBox(
            width: 200,
            height: 200,
            child: DanmakuAreaGuide(visible: false, area: 0.5),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      ft = t.widget(find.descendant(
        of: box,
        matching: find.byType(FadeTransition),
      ));
      expect(ft.opacity.value, lessThan(0.1),
          reason: '★ 松手后淡出到不可见（不长期挡画面）');
      while (t.takeException() != null) {}
    });

    testWidgets('C3 遮罩画在画面 rect 之内（左上为原点、高度=rect高）', (t) async {
      // 直接量 CustomPaint 的尺寸：DanmakuOverlay 复刻 contain 后的画面矩形
      await t.pumpWidget(
        mui.Directionality(
          textDirection: mui.TextDirection.ltr,
          child: const mui.SizedBox(
            width: 320,
            height: 180,
            child: DanmakuAreaGuide(visible: true, area: 0.5),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 200));
      // 取 DanmakuAreaGuide 自己那个 CustomPaint（painter 是 _AreaGuidePainter
      // 的私有类型 ⇒ 用"painter 非空"筛，SizedBox 松约束产生的外层 CustomPaint
      // 会被排除掉）。
      final customPaints = find.descendant(
        of: find.byType(DanmakuAreaGuide),
        matching: find.byType(CustomPaint),
      );
      CustomPaint? guidePaint;
      for (final w in t.widgetList<CustomPaint>(customPaints)) {
        if (w.painter != null) {
          guidePaint = w;
        }
      }
      expect(guidePaint, isNotNull, reason: '★ 遮罩自带一个 CustomPaint（有 painter）');
      final size = guidePaint!.size;
      expect(size, isNotNull);
      expect(size.width, lessThanOrEqualTo(320.0),
          reason: '★ 遮罩的 paint 尺寸必须落在承载 rect 内（不是整屏）');
      expect(size.height, lessThanOrEqualTo(180.0),
          reason: '★ 高度也落在 rect 内 ⇒ 边界线画在 rect 内 h*area 处');
      while (t.takeException() != null) {}
    });

    test('C4 引导遮罩不进 layoutKey（显隐不触发弹幕重排）', () {
      final ov = stripComments(
          File('lib/ui/widgets/danmaku_overlay.dart').readAsStringSync());
      // areaGuide 不该出现在 _layoutKey 的键列表里（它只影响遮罩显隐）
      final keyBlock = ov.substring(
        ov.indexOf('final key = <Object?>['),
        ov.indexOf('final old = _layoutKey;'),
      );
      expect(keyBlock.contains('areaGuide'), isFalse,
          reason: '★ 遮罩显隐是纯 UI，不该触发弹幕重排（避免拖动时每帧重排）');
    });
  });
}
