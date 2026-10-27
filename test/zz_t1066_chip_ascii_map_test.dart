// ASCII 亮度图探针：把弹幕 chip 1:1 渲染在三种背景上，直接"看见"边缘
// 跑法：flutter test --concurrency=1 test/zz_t1066_chip_ascii_map_test.dart
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Widget chipUnderTest({required double alpha}) => ActionChip(
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
      label: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.subtitles_outlined, size: 13, color: Colors.white70),
          SizedBox(width: 4),
          Text('弹幕', style: TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );

Future<({int w, int h, Uint8List px})> render(
    WidgetTester tester, Color bg, double alpha) async {
  tester.view.physicalSize = const Size(200, 70);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  const key = ValueKey('cap');
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    // ★ 背景画在 RepaintBoundary **内部最外层**（保证被捕获）
    // ⚠️ 外面必须套 `Material`（`ActionChip` 要求 Material 祖先；
    //    且 `RawChip` 还要求 `MaterialLocalizations` —— 那由 `MaterialApp` 提供，
    //    缺了会抛异常 ⇒ 捕获到的其实是错误占位，读数全一样。我踩过。）
    home: Material(
      color: Colors.transparent,
      child: RepaintBoundary(
        key: key,
        child: Container(
          width: 200,
          height: 70,
          color: bg,
          alignment: Alignment.center,
          child: chipUnderTest(alpha: alpha),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  final b = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  debugPrint('  boundary.size = ${b.size}');
  late ByteData d;
  await tester.runAsync(() async {
    final img = await b.toImage(pixelRatio: 1.0);
    d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    img.dispose();
  });
  return (w: 200, h: 70, px: d.buffer.asUint8List());
}

String map(Uint8List px, int w, int x0, int x1, int y0, int y1) {
  const ramp = ' .:-=+*#%@';
  final sb = StringBuffer();
  for (var y = y0; y <= y1; y++) {
    sb.write('y=${y.toString().padLeft(2)} |');
    for (var x = x0; x <= x1; x++) {
      final i = (y * w + x) * 4;
      final l = (0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2]) / 255.0;
      sb.write(ramp[(l * (ramp.length - 1)).round().clamp(0, ramp.length - 1)]);
    }
    sb.write('|\n');
  }
  return sb.toString();
}

void main() {
  for (final alpha in <double>[0.55, 0.85]) {
    for (final e in <String, Color>{
      '黑': const Color(0xFF000000),
      '中灰': const Color(0xFF808080),
      '白': const Color(0xFFFFFFFF),
    }.entries) {
      testWidgets('chip alpha=$alpha bg=${e.key} 的像素图',
          (tester) async {
        final r = await render(tester, e.value, alpha);
        debugPrint('\n═══ alpha=$alpha  bg=${e.key} ═══');
        debugPrint(map(r.px, r.w, 62, 138, 14, 54));
        final i = (35 * r.w + 100) * 4;
        debugPrint('  中心像素 L=%s'
            .replaceFirst('%s',
                (0.299 * r.px[i] + 0.587 * r.px[i + 1] + 0.114 * r.px[i + 2])
                    .toStringAsFixed(1)));
      });
    }
  }
}