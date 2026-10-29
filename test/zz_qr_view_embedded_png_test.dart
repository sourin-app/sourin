// test/zz_qr_view_embedded_png_test.dart
//
// ══════════════════════════════════════════════════════════════════════════
// 二维码弹窗要能显示"图片形态"的二维码（百度）
// ══════════════════════════════════════════════════════════════════════════
//
// # 为什么有这条
// ```text
// 百度的 getqrcode 只给一张 PNG（imgurl）⇒ Rust 侧把 PNG 内嵌进 SVG 的
// `<image href="data:image/png;base64,…">`。而本仓的 QrView 原来只认 `<rect>`+`<path>`
// ⇒ 现场表现是"弹窗里只有一行图片地址"，不是二维码。
// ⇒ 这条钉住：能解出内嵌 PNG；解不出/没有内嵌时返回 null（退回原矢量路径，不判死）。
// ```

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/qr_view.dart';

/// 1×1 透明 PNG（标准字节，用来验证"解出来的就是原字节"）
const String _png1x1B64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  group('内嵌 PNG', () {
    test('href 形态能解出原字节', () {
      final svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">'
          '<image href="data:image/png;base64,$_png1x1B64" width="1" height="1"/></svg>';
      final bytes = qrSvgEmbeddedPng(svg);
      expect(bytes, isNotNull);
      expect(bytes, equals(base64Decode(_png1x1B64)),
          reason: '★ 解出来必须与原始字节一致（差一个字节都扫不出来）');
      expect(bytes is Uint8List, isTrue);
    });

    test('xlink:href 形态也认（Rust 侧两个都写）', () {
      final svg = '<svg><image xlink:href="data:image/png;base64,$_png1x1B64"/></svg>';
      expect(qrSvgEmbeddedPng(svg), isNotNull);
    });

    test('没有内嵌图 ⇒ null（不许把矢量二维码判死）', () {
      const svg = '<svg width="231" height="231">'
          '<rect x="0" y="0" width="231" height="231" fill="#ffffff"/>'
          '<path fill="#0b0d12" d="M28 28h7v7H28V28"/></svg>';
      expect(qrSvgEmbeddedPng(svg), isNull);
    });

    test('base64 坏掉 ⇒ null（不抛异常）', () {
      const svg = '<svg><image href="data:image/png;base64,!!!!not-base64!!!!"/></svg>';
      expect(qrSvgEmbeddedPng(svg), isNull);
    });
  });
}
