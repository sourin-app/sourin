// ═══════════════════════════════════════════════════════════════════════
//  11-B 预览宽高比门禁（Lead 2026-10-17 要求）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这条门禁
// ```text
// 预览的作用是「看设计语言」。而设计语言里有两项是**形状**：
//   · 圆角     —— 拉伸后从「圆」变「扁椭圆」
//   · 描边粗细 —— 拉伸后视觉占比被摊薄
// 一旦预览被横向拉伸，专门为「看出设计语言」做的预览反而看不出设计语言。
// ⇒ 这不是「难看一点」，是把功能本身废掉了，所以值得一条门禁。
// ```
//
// # 实测过的失真
// ```text
// 900 宽、每行 2 张、labelW=96 ⇒ 单卡 392px
// 预览若自适应宽 ⇒ 392 / 66 = 5.94:1
// 设计基线               ⇒ 190 / 66 = 2.88:1
// ⇒ 横向拉伸 2.06 倍：新粗野的 2.5px 粗边摊薄到和液态玻璃的细边差不多。
// ```
//
// # 门禁判据
// ```text
// 2.4 ~ 3.4  ← 以 2.88 为中心的合理浮动带
//   · 下界 2.4：「卡片比基线更方」还能接受
//   · 上界 3.4：「卡片比基线更扁」就到失真边缘了
// 392/66 = 5.94 远超上界 ⇒ 会被这条门禁抓住。
// ```
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/settings/theme_page.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

/// 从真实渲染树里量预览的尺寸
Future<Size> _measurePreview(WidgetTester t, double cardWidth) async {
  final pack = ThemePackStore.builtins.first;
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: cardWidth,
          child: ThemeCard(
            pack: pack,
            selected: false,
            onTap: () {},
            onPreview: () {},
          ),
        ),
      ),
    ),
  ));
  await t.pump();
  final finder = find.descendant(
    of: find.byType(ThemeCard),
    matching: find.byWidgetPredicate((w) =>
        w.runtimeType.toString() == '_Preview'),
  );
  expect(finder, findsOneWidget, reason: '量不到 _Preview ⇒ 门禁在空处跑，必须红');
  return t.getSize(finder);
}

void main() {
  testWidgets('① 预览宽高比必须落在 2.4~3.4（190/66 ≈ 2.88）', (t) async {
    final s = await _measurePreview(t, 400);
    final ratio = s.width / s.height;
    print('preview size = ${s.width} x ${s.height}  ratio = ${ratio.toStringAsFixed(2)}');
    expect(ratio, greaterThanOrEqualTo(2.4),
        reason: '预览比 ${ratio.toStringAsFixed(2)}:1 太方了 —— '
            '圆角/描边的形状会被压扁，看不出设计语言');
    expect(ratio, lessThanOrEqualTo(3.4),
        reason: '预览比 ${ratio.toStringAsFixed(2)}:1 太扁了（被横向拉伸）—— '
            '圆角会变扁椭圆、粗描边会被摊薄。设计基线是 2.88:1');
  });

  testWidgets('② 卡片宽度变化时，预览宽度必须恒定（不被拉伸）', (t) async {
    final narrow = await _measurePreview(t, 220);
    final wide = await _measurePreview(t, 520);
    print('narrow card => ${narrow.width} x ${narrow.height}');
    print('wide   card => ${wide.width} x ${wide.height}');
    expect(wide.width, narrow.width,
        reason: '卡片从 220 变到 520 时预览被拉宽了 —— '
            '预览必须固定宽度，否则 16 套之间无法横向比较');
    expect(wide.height, narrow.height);
  });

  testWidgets('③ 固定宽度必须等于设计基线 190', (t) async {
    expect(ThemeCard.previewWidth, 190.0,
        reason: '改这个常量必须同时改本文件的断言区间与 _Preview 的 height');
    final s = await _measurePreview(t, 400);
    expect(s.width, 190.0, reason: '实际渲染宽度与常量不一致');
  });
}