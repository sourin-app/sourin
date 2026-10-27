// 决定性探针：弹幕 chip 底下到底有没有一层不透明的亮面？它是不是"亮边"的来源？
// 跑法：flutter test --concurrency=1 test/zz_t1068_chip_layer_test.dart
//
// 背景：Owner 两张截图的读数（同一位置、同一采样方法）
//   alpha 0.55 → 内部 108.2 / 边缘 74.8   ⇒ 边缘比内部**暗**
//   alpha 0.85 → 内部  37.4 / 边缘 74.8   ⇒ 边缘比内部**亮**（"亮边"）
// 而 108.2 ≈ 0.45×240、37.4 ≈ 0.15×250 ⇒ 两者都像"黑@alpha 压在一层 **亮面**上"。
// ⇒ 本探针在**纯红底**上渲染 chip，看内部三通道是否**中性灰**（=有亮面）还是**偏红**（=真透到视频）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _red = Color(0xFFFF0000);

Widget bare({required double alpha}) => ActionChip(
      onPressed: () {},
      clipBehavior: Clip.none,
      backgroundColor: Colors.black.withValues(alpha: alpha),
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelPadding: const EdgeInsets.symmetric(horizontal: 0),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(999)),
      ),
      // ★ 用**空盒子**当 label：避免文字/图标像素污染读数（我上一版就误把图标像素当边缘）
      label: const SizedBox(width: 44, height: 14),
    );

/// 变体：试着去掉可能的不透明底层
Widget variant(String which, double alpha) {
  final chip = bare(alpha: alpha);
  switch (which) {
    case 'V1_plain':
      return chip;
    case 'V2_chiptheme_transparent':
      return ChipTheme(
        data: const ChipThemeData(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          pressElevation: 0,
          selectedColor: Colors.transparent,
          disabledColor: Colors.transparent,
        ),
        child: chip,
      );
    case 'V3_material_transparency_parent':
      return Material(type: MaterialType.transparency, child: chip);
    case 'V4_alpha_full':
      return bare(alpha: 1.0);
    default:
      throw ArgumentError(which);
  }
}

Future<Uint8List> cap(WidgetTester tester, Widget v) async {
  tester.view.physicalSize = const Size(200, 70);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  const key = ValueKey('cap');
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    // 底色用**纯红**：能一眼分辨"透到背景"（偏红）与"压在亮面上"（中性灰）
    home: Material(
      color: Colors.transparent,
      child: RepaintBoundary(
        key: key,
        child: Container(
          width: 200,
          height: 70,
          color: _red,
          alignment: Alignment.center,
          child: v,
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
  return d.buffer.asUint8List();
}

String rgb(Uint8List px, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return '(${px[i]},${px[i + 1]},${px[i + 2]})';
}

double lum(Uint8List px, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
}

void main() {
  testWidgets('★ 纯红底上各变体：内部是中性灰（有亮层）还是偏红（真透底）',
      (tester) async {
    for (final which in <String>[
      'V1_plain',
      'V2_chiptheme_transparent',
      'V3_material_transparency_parent',
      'V4_alpha_full',
    ]) {
      for (final a in <double>[0.55, 0.85]) {
        if (which == 'V4_alpha_full' && a == 0.55) continue;
        final alpha = which == 'V4_alpha_full' ? 1.0 : a;
        final px = await cap(tester, variant(which, alpha));

        // chip 在 200x70 中央；横向扫 y=35 找 chip 范围（与红底差异 > 10）
        var lo = -1, hi = -1;
        for (var x = 0; x < 200; x++) {
          if ((lum(px, 200, x, 35) - lum(px, 200, 3, 35)).abs() > 10) {
            if (lo < 0) lo = x;
            hi = x;
          }
        }
        // 内部取样：chip 内、避开空 label（label 宽 44，chip 内左端留白）
        final inX = lo + 4;
        final inner = rgb(px, 200, inX, 35);
        // 边缘带：lo-1 .. lo+1
        var edgeMax = 0.0;
        for (final x in [lo - 1, lo, lo + 1]) {
          if (x >= 0) {
            final l = lum(px, 200, x, 35);
            if (l > edgeMax) edgeMax = l;
          }
        }
        final innerL = lum(px, 200, inX, 35);
        debugPrint('  ${which.padRight(32)} a=$alpha  chip x=$lo..$hi  '
            '内部=$inner (L=${innerL.toStringAsFixed(1)})  '
            '边缘maxL=${edgeMax.toStringAsFixed(1)}  '
            '边缘−内部=${(edgeMax - innerL).toStringAsFixed(1)}');
      }
    }
    // 参考：纯红底自身的值
    final px = await cap(tester, const SizedBox());
    debugPrint('  参考：红底 rgb=${rgb(px, 200, 3, 35)}  角落=${rgb(px, 200, 2, 2)}');
    debugPrint('');
    debugPrint('判读：');
    debugPrint('  · 内部 R≈G≈B（中性灰）⇒ chip 下有一层**不透明亮面**（不是视频透出来）');
    debugPrint('  · 内部 R 明显>G,B（偏红）⇒ chip 直接压在背景上（真半透明）');
    debugPrint('  · "边缘−内部" > 0 且明显 ⇒ 那就是 Owner 看到的**亮边**');
  });
}