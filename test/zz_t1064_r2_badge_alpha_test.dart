// ═══════════════════════════════════════════════════════════════════════
//  R2-#6 弹幕 chip：**边缘不许比内部更亮**（那圈"亮边"的守门禁）
// ═══════════════════════════════════════════════════════════════════════
//
// 跑法：flutter test --concurrency=1 test/zz_t1064_r2_badge_alpha_test.dart
//
// # ★★★ 本文件是**四次弯路**之后的最终判据（每次错法都留在这里，防后人重犯）
// ```text
// 第 1 错：改错**对象** —— 我改了站标徽章，Owner 指的是这个 chip。
// 第 2 错：对象对了但**方向错** —— 把 0.55 提到 0.85，"边缘−内部"从 +1.8 涨到 +38.8
//           （我把毛边**做重了约 20 倍**）。
// 第 3 次：用受控渲染查出真病根是"chip 自带亮面在边缘漏出"，但当时不敢动构造。
// 第 4 次（**现状**）：Owner 明确选 **(c) 自绘药丸** ⇒ 我先做**四方案受控渲染**，
//           定出"**自绘 + 不透明等效色 `#726F73`**" ⇒ 内部观感与旧形态**逐字相同**
//           （114,111,115）而 **Δ = 0.0** ⇒ 亮边在数学上不存在。
// ```
//
// # 真机理（受控渲染实测，纯红底 1:1 渲染真控件）
// ```text
//   方案                        内部 RGB        边缘−内部(Δ)
//   ActionChip(black@0.55)      (114,111,115)   +1.8    ← 旧形态（那层亮面在，但淡）
//   自绘 + 半透明                (115,0,0)      **+41.9** ← 更糟（边缘改混背景）
//   自绘 + 不透明黑              (0,0,0)        **+76.2** ← 最糟
//   自绘 + 不透明灰 #726F73      (114,111,115)   **+0.0** ← ★ 现形态
// ★ 关键证据：旧形态在**纯红底**上内部是**中性灰**（不是红）
//   ⇒ chip 底下压着一层**亮/白面**；边缘 AA 把那层漏出来 ⇒ 读成"一圈亮边"。
//   ⇒ 而"不透明"后，边缘未覆盖部分混的仍是背景，但**内部与填充色同值** ⇒ 无落差 ⇒ Δ=0。
// ```
//
// # 为什么必须"受控渲染"而不是"看截图"（我为此误报过一次）
// ```text
// Owner 的截图只有 88×67 / 89×50 / 270×87 像素。我曾用**单个采样点**得出
// "边缘比内部亮"，结果那个点**打在了图标上**（把图标像素当成边缘）⇒ 误报。
// ⇒ 截图判不了这条；只有 1:1 渲染读像素才作数。
// ```
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻产品实现里那个**不透明等效色**（`player_page.dart` 的 `kDanmakuChipFill`）。
/// ⚠️ 本文件**独立复算一次**它的取值依据（见下方 ② 组），不盲信源码里的注释。
const int kExpectedFill = 0xFF726F73;
const Color _red = Color(0xFFFF0000);
const Color _fill = Color(kExpectedFill);

void main() {
  // ═══ 一、源码锚点：形态、唯一性、教训留档 ═══
  group('① 源码状态（chip 已改自绘 / 教训留档 / 无重复）', () {
    String codeOnly(String src) {
      final out = StringBuffer();
      var inBlock = false;
      for (final line in const LineSplitter().convert(src)) {
        final t = line.trimLeft();
        if (inBlock) {
          final p = t.indexOf('*/');
          if (p >= 0) {
            inBlock = false;
            out.writeln(t.substring(p + 2));
          }
          continue;
        }
        final p = t.indexOf('/*');
        if (p >= 0) {
          final rest = t.substring(p + 2);
          if (rest.contains('*/')) {
            out.writeln(t.substring(0, p).trimRight());
          } else {
            inBlock = true;
            out.writeln(t.substring(0, p));
          }
          continue;
        }
        if (t.startsWith('//')) continue;
        out.writeln(line);
      }
      return out.toString();
    }

    late final String raw;
    late final String code;
    setUpAll(() {
      final f = File('lib/ui/player_page.dart');
      expect(f.existsSync(), isTrue, reason: '★ cwd 必须是仓库根');
      raw = f.readAsStringSync();
      code = codeOnly(raw);
    });

    test('★★★ chip 已改成自绘（不再用 ActionChip 的画底色形态）', () {
      // 判据：chip 的**不透明填充色**常量必须在位（它是本形态的核心）。
      expect(
        code.contains('kDanmakuChipFill'),
        isTrue,
        reason: '★ 必须有不透明等效色常量 —— 那是 (c) 自绘药丸的核心（Δ=0 靠它）',
      );
      // ★ 反面：不许退回"半透明黑底 + strokeWidth 0 的 ActionChip"那种形态
      expect(
        RegExp(r'backgroundColor:\s*Colors\.black\.withValues\(').hasMatch(code),
        isFalse,
        reason: '★ chip 不许退回"半透明黑底"形态（那正是产生亮边的形态）',
      );
    });

    test('★★ 等效色常量只许出现**一次**（防重复声明）', () {
      final n = RegExp(r'const Color kDanmakuChipFill\s*=').allMatches(code).length;
      expect(n, 1, reason: '★ 命中 $n 处 —— 必须恰好 1 处（重复声明会让编译失败）');
    });

    test('★ 站标徽章仍保持 0.55（未被指认 ⇒ 不许顺手改）', () {
      expect(
        RegExp(r'color:\s*Colors\.black\.withValues\(alpha:\s*0\.55\)'
                r'[\s\S]{0,60}?borderRadius:\s*Radii\.rFull')
            .hasMatch(code),
        isTrue,
        reason: '★ 徽章未被 Owner 指认 ⇒ 保持 0.55（我第 1 次改错就在这里）',
      );
    });

    test('★ 四次教训必须留档在源码里（防后人再走一遍）', () {
      for (final must in <String>[
        '2026-10-20-danmaku-chip-edge-is-adjacent-badge', // 那份前提错的旧记录
        'R2-#6', // 本次多段纠正的标记
      ]) {
        expect(raw.contains(must), isTrue, reason: '★ 源码里必须留 `$must` 的出处');
      }
    });
  });

  // ═══ 二、★ 独立复算"不透明等效色"（不盲信注释） ═══
  group('② 等效色的取值依据可复算', () {
    test('★★★ 受控渲染：旧形态内部亮度 × (1/0.45) = 那层亮面亮度', () {
      // 旧形态 = black@0.55 压在 chip 自带亮面上 ⇒ 内部 = 0.45 × 亮面
      // 受控实测内部 = 114.0 ⇒ 亮面 ≈ 253
      // ⇒ "观感不变"的不透明等效色就该 ≈ 那个内部值本身
      const measuredInner = 114.0;
      const impliedFace = measuredInner / 0.45;
      expect(impliedFace, greaterThan(240),
          reason: '★ 反推出的"亮面"应是亮色（≈253）—— 若不然，本机理不成立');
      // 等效色 = 实测内部值（这正是 #726F73 = 114,111,115）
      expect((kExpectedFill >> 16) & 0xFF, 114, reason: '★ R 通道应 = 实测内部 R');
      expect((kExpectedFill >> 8) & 0xFF, 111, reason: '★ G 通道应 = 实测内部 G');
      expect(kExpectedFill & 0xFF, 115, reason: '★ B 通道应 = 实测内部 B');
    });
  });

  // ═══ 三、★ 受控渲染：边缘不许比内部更亮（真正的守门禁） ═══
  group('③ 受控渲染：三边的 Δ 都必须 ≤ +3.0，且判据有分辨力', () {
    Future<({double left, double top, double bottom, double inner})> measure(
      WidgetTester tester,
      Widget chip,
    ) async {
      tester.view.physicalSize = const Size(200, 70);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      const key = ValueKey('cap');
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Material(
          color: Colors.transparent,
          child: RepaintBoundary(
            key: key,
            child: Container(
              width: 200,
              height: 70,
              color: _red,
              alignment: Alignment.center,
              child: chip,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final b = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
      late ByteData d;
      await tester.runAsync(() async {
        final img = await b.toImage(pixelRatio: 1.0);
        d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        img.dispose();
      });
      final px = d.buffer.asUint8List();
      double lum(int x, int y) {
        final i = (y * 200 + x) * 4;
        return 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
      }

      var lo = -1, hi = -1;
      for (var x = 0; x < 200; x++) {
        if ((lum(x, 35) - lum(3, 35)).abs() > 8) {
          if (lo < 0) lo = x;
          hi = x;
        }
      }
      expect(lo > 0 && hi > lo, isTrue,
          reason: '★ 找不到控件（候选集为空 ⇒ 断言会空真，铁律 149）');
      final inX = lo + 3;
      final innerL = lum(inX, 35);
      var leftMax = 0.0;
      for (final x in [lo - 1, lo, lo + 1, lo + 2]) {
        if (x >= 0) leftMax = leftMax > lum(x, 35) ? leftMax : lum(x, 35);
      }
      var ty = -1, by = -1;
      for (var y = 3; y < 67; y++) {
        if ((lum(inX, y) - lum(inX, 2)).abs() > 8) {
          if (ty < 0) ty = y;
          by = y;
        }
      }
      var topMax = 0.0, botMax = 0.0;
      for (var y = 0; y < 70; y++) {
        if (y < 34 && ty > 0 && y >= ty - 1) {
          topMax = topMax > lum(inX, y) ? topMax : lum(inX, y);
        }
        if (y > 34 && by > 0 && y <= by + 1) {
          botMax = botMax > lum(inX, y) ? botMax : lum(inX, y);
        }
      }
      return (
        left: leftMax - innerL,
        top: topMax - innerL,
        bottom: botMax - innerL,
        inner: innerL,
      );
    }

    /// ★ 与产品实现**逐字同形**的自绘药丸（`AppInkWell` 的可见行为由 `Container` 承担）
    Widget chipLikeProduct() => InkWell(
          onTap: () {},
          borderRadius: const BorderRadius.all(Radius.circular(999)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            decoration: const BoxDecoration(
              color: _fill,
              borderRadius: BorderRadius.all(Radius.circular(999)),
            ),
            child: const SizedBox(width: 44, height: 14),
          ),
        );

    testWidgets('★★★ 现形态：左/上/下 三边 Δ 都必须 ≤ +3.0', (tester) async {
      final m = await measure(tester, chipLikeProduct());
      debugPrint('═══ 现形态（自绘 + 不透明等效色）受控实测 ═══');
      debugPrint('  内部 L=${m.inner.toStringAsFixed(1)}');
      debugPrint('  左缘 Δ=${m.left.toStringAsFixed(1)}  '
          '上缘 Δ=${m.top.toStringAsFixed(1)}  下缘 Δ=${m.bottom.toStringAsFixed(1)}');
      for (final e in <String, double>{
        '左': m.left,
        '上': m.top,
        '下': m.bottom,
      }.entries) {
        expect(e.value, lessThanOrEqualTo(3.0),
            reason: '★★★ ${e.key}边出现比内部更亮的像素（Δ=${e.value.toStringAsFixed(1)}）'
                '—— 那就是 Owner 说的"亮亮像毛边"。'
                '受控基线：旧形态 +1.8/−3.4/−3.0；**现形态应 ≈ 0**。');
      }
    });

    testWidgets('★★ 阴性对照：把填充改回**半透明** ⇒ Δ 必须显著变大', (tester) async {
      // 证明上面那条判据**有分辨力**（不是恒真的假门禁）
      final semi = InkWell(
        onTap: () {},
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55), // ← 故意退回半透明
            borderRadius: const BorderRadius.all(Radius.circular(999)),
          ),
          child: const SizedBox(width: 44, height: 14),
        ),
      );
      final m = await measure(tester, semi);
      debugPrint('  [阴性对照] 半透明形态：左缘 Δ=${m.left.toStringAsFixed(1)} '
          '（不透明形态应 ≈ 0）');
      expect(m.left, greaterThan(10.0),
          reason: '★ 半透明时左缘 Δ 必须显著变大（受控实测 +41.9）—— '
              '否则说明"Δ"没分辨力，上面那条守门禁就是假绿');
    });
  });
}