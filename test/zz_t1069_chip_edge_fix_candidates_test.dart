// 候选修法实测：哪个方案能真正去掉那圈"亮边"？
// 跑法：flutter test --concurrency=1 test/zz_t1069_chip_edge_fix_candidates_test.dart
//
// 已确认（zz_t1068，纯红底受控渲染）：
//   chip 内部是**中性灰** ⇒ 黑@alpha 下面压着一层**亮面**（≈白），
//   边缘 AA 像素把那层亮面漏出来 ⇒ 读成"一圈亮边"。
//   alpha 0.55→0.85→1.0 时"边缘−内部"= +1.8 → +38.8 → +76.2（**调 alpha 方向反了**）。
// 本文件测**实用候选**，谁把"边缘−内部"压到 ≈0 谁就是根上的修法。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _red = Color(0xFFFF0000);

Widget _label() => const SizedBox(width: 44, height: 14);

Widget _chip({double? alpha, Color? bg}) => ActionChip(
      onPressed: () {},
      clipBehavior: Clip.none,
      backgroundColor: bg ?? Colors.black.withValues(alpha: alpha ?? 0.55),
      side: BorderSide.none,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      labelPadding: const EdgeInsets.symmetric(horizontal: 0),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(999)),
      ),
      label: _label(),
    );

/// 各候选方案
Widget candidate(String id) {
  switch (id) {
    case 'BASE_0.55':
      return _chip(alpha: 0.55);
    case 'A_transparent_bg':
      return _chip(bg: Colors.transparent);
    case 'B_opaque_black':
      return _chip(bg: Colors.black); // 完全不透明
    case 'C_bg_black55_on_transparent_material':
      return ChipTheme(
        data: const ChipThemeData(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          pressElevation: 0,
        ),
        child: _chip(bg: Colors.black.withValues(alpha: 0.55)),
      );
    case 'D_opaque_black_with_55_visual':
      // 视觉上像 55%：用**不透明**色模拟（黑压在白面上 = 灰 114）
      // ⇒ 边缘 AA 是 灰↔红 过渡（不是 白↔红）⇒ 亮边应消失
      return _chip(bg: const Color(0xFF726F73));
    case 'E_black55_materialcolor_wrapper':
      // 把 chip 包在一个**己方控制**的半透明黑容器里，chip 自身不透明贴容器
      return Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(999),
        ),
        child: _chip(bg: Colors.transparent),
      );
    default:
      throw ArgumentError(id);
  }
}

Future<Uint8List> cap(WidgetTester tester, Widget v) async {
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

double lum(Uint8List px, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
}

String rgb(Uint8List px, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return '(${px[i]},${px[i + 1]},${px[i + 2]})';
}

void main() {
  testWidgets('★★★ 候选修法：谁把"边缘−内部"压到 ≈0', (tester) async {
    final ids = <String>[
      'BASE_0.55',
      'A_transparent_bg',
      'B_opaque_black',
      'C_bg_black55_on_transparent_material',
      'D_opaque_black_with_55_visual',
      'E_black55_materialcolor_wrapper',
    ];
    for (final id in ids) {
      final px = await cap(tester, candidate(id));
      // 找 chip 横向范围
      var lo = -1, hi = -1;
      for (var x = 0; x < 200; x++) {
        if ((lum(px, 200, x, 35) - lum(px, 200, 3, 35)).abs() > 8) {
          if (lo < 0) lo = x;
          hi = x;
        }
      }
      if (lo < 0) {
        debugPrint('  ${id.padRight(42)} ★ 找不到 chip（该方案可能不可见）');
        continue;
      }
      final inX = lo + 3;
      final innerRgb = rgb(px, 200, inX, 35);
      final innerL = lum(px, 200, inX, 35);
      var eMax = 0.0;
      for (final x in [lo - 1, lo, lo + 1, lo + 2]) {
        if (x >= 0) {
          final l = lum(px, 200, x, 35);
          if (l > eMax) eMax = l;
        }
      }
      // 垂直方向（上下边）
      final cx = lo + 3;
      var tMax = 0.0, bMax = 0.0;
      var ty = -1, by = -1;
      for (var y = 3; y < 66; y++) {
        final l = lum(px, 200, cx, y);
        if ((l - lum(px, 200, cx, 2)).abs() > 8) {
          if (ty < 0) ty = y;
          by = y;
        }
      }
      for (final y in [ty - 1, ty, by, by + 1]) {
        if (y >= 0 && y < 70) {
          final l = lum(px, 200, cx, y);
          if (y <= 34) {
            if (l > tMax) tMax = l;
          } else {
            if (l > bMax) bMax = l;
          }
        }
      }
      debugPrint('  ${id.padRight(42)} 内部=$innerRgb L=${innerL.toStringAsFixed(1)}  '
          '左缘maxL=${eMax.toStringAsFixed(1)}(Δ${(eMax - innerL).toStringAsFixed(1)})  '
          '上缘maxL=${tMax.toStringAsFixed(1)}(Δ${(tMax - innerL).toStringAsFixed(1)})  '
          '下缘maxL=${bMax.toStringAsFixed(1)}(Δ${(bMax - innerL).toStringAsFixed(1)})');
    }
    debugPrint('');
    debugPrint('★ 判读：Δ 越接近 0（或负）⇒ 那圈亮边越看不出。BASE_0.55 的 Δ≈+1.8 是现状基准。');
    debugPrint('  ⇒ 若某方案的 Δ 明显小于 1.8 且内部观感仍像"半透明黑"，它就是根上的修法。');
  });
}