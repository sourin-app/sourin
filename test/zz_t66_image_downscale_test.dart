/*
 * 图片「下行缩放」判据（round-66 verify-34 新建）
 *
 * 背景：全树 `grep -E "1440|222|scale|instantiateImageCodec|decodeImage"` 无命中
 * ⇒ 此前**没有任何判据**证明「大图解码时最大边长真的被 clamp」。
 *
 * 判据链（任何一环断掉都必须红）：
 *   ① 纯函数：离谱大的布局尺寸 ⇒ 被夹到 `kCoverDecodeMaxPx`，不是原样返回
 *   ② 产品接线：`coverImage()` 真的把夹过的值接到 `Image.cacheWidth/cacheHeight`
 *   ③ 真解码：源 222×1440、目标高 223 ⇒ 解出来**真的**是 223 高（比例保持）
 *   ④ 真解码上限：源 800×6000、目标高取到上限 ⇒ 解出来是 4096，**不是**源 6000
 *   ⑤ 反向上限（仪器自检）：不传目标 ⇒ 解出来就是源 800×6000
 *      —— 没有 ⑤，③④ 的读数可能只是「解码器总给源尺寸」的假象
 *
 * 注入（worktree 内，不碰主树产品码）：
 *   把 `cover_image.dart` 里两处 `.clamp(1, kCoverDecodeMaxPx)` 改成
 *   `.clamp(1, 1 << 22)`（等价拆掉上界）⇒ ①②④ 必须红，⑤ 必须仍绿。
 */
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/cover_image.dart';

/// 造一张**尺寸精确可控**的合成图（两条色带，避免纯色被优化）。
Future<Uint8List> _syntheticPng(int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFF2266AA));
  canvas.drawRect(Rect.fromLTWH(0, 0, w / 2.0, h.toDouble()),
      Paint()..color = const Color(0xFFEEAA33));
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  pic.dispose();
  return bd!.buffer.asUint8List();
}

/// 走**真实解码**：`targetW/targetH` 为空 ⇒ 不缩放（源尺寸）。
Future<ui.Image> _decode(WidgetTester t, Uint8List bytes,
    {int? targetW, int? targetH}) async {
  late ui.Image out;
  await t.runAsync(() async {
    final ImageProvider<Object> provider = (targetW == null && targetH == null)
        ? MemoryImage(bytes)
        : ResizeImage(MemoryImage(bytes),
            width: targetW, height: targetH, allowUpscaling: false);
    final c = Completer<ui.Image>();
    provider.resolve(ImageConfiguration.empty).addListener(
        ImageStreamListener((info, _) => c.complete(info.image)));
    out = await c.future;
  });
  return out;
}

Future<BuildContext> _ctx(WidgetTester t) async {
  late BuildContext ctx;
  await t.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
    ctx = c;
    return const SizedBox.shrink();
  })));
  return ctx;
}

void main() {
  testWidgets('① 纯函数：离谱布局 ⇒ 夹到 kCoverDecodeMaxPx', (t) async {
    final ctx = await _ctx(t);
    final dpr = MediaQuery.devicePixelRatioOf(ctx);
    // ignore: avoid_print
    print('DS|dpr=$dpr kCoverDecodeMaxPx=$kCoverDecodeMaxPx');
    expect(coverDecodeWidth(ctx, 1e6), kCoverDecodeMaxPx,
        reason: '布局宽 1e6×dpr 必须被夹回上限，而不是原样返回');
    expect(coverDecodeWidth(ctx, 0), 1, reason: '下界 1（0 会让 Image assert 崩）');
    expect(coverDecodeHeightFor(ctx, layoutWidth: 148, layoutHeight: 1e5),
        kCoverDecodeMaxPx,
        reason: '布局高 1e5×dpr 必须被夹回上限');
    final normal = coverDecodeHeightFor(ctx, layoutWidth: 148, layoutHeight: 223);
    // ignore: avoid_print
    print('DS|coverDecodeHeightFor(148x223)=$normal');
    expect(normal, (223 * dpr).round(),
        reason: '正常尺寸不许被夹（夹了就是把图解码小了）');
  });

  testWidgets('② 产品接线：coverImage 把夹过的值接到 cacheWidth/cacheHeight',
      (t) async {
    final ctx = await _ctx(t);
    final byWidth =
        coverImage(ctx, url: 'https://example.invalid/a.jpg', layoutWidth: 1e6);
    // Image.network 把 cacheWidth/cacheHeight 翻成 ResizeImage 的两个维度
    final pw = byWidth.image;
    // ignore: avoid_print
    print('DS|coverImage(width).provider=$pw');
    expect(pw, isA<ResizeImage>(), reason: '★ 没接到 ResizeImage ⇒ 解码尺寸根本没被控制');
    expect((pw as ResizeImage).width, kCoverDecodeMaxPx,
        reason: '★ 接线断了：解码宽直接吃未夹的布局宽');
    expect(pw.height, isNull, reason: '两种模式互斥（同时给会拉伸变形）');

    final byHeight = coverImage(ctx,
        url: 'https://example.invalid/b.jpg',
        layoutWidth: 148,
        layoutHeight: 1e5);
    final ph = byHeight.image as ResizeImage;
    // ignore: avoid_print
    print('DS|coverImage(height).provider=$ph');
    expect(ph.height, kCoverDecodeMaxPx);
    expect(ph.width, isNull);
  });

  testWidgets('③ 真解码：222×1440 源、目标高 223 ⇒ 解出 223 高、比例保持', (t) async {
    final bytes = await t.runAsync(() => _syntheticPng(222, 1440));
    final img = await _decode(t, bytes!, targetH: 223);
    // ignore: avoid_print
    print('DS|222x1440 -> targetH=223 => ${img.width}x${img.height}');
    expect(img.height, 223, reason: '★ 目标高没生效');
    expect((img.width / img.height - 222 / 1440).abs(), lessThan(0.02),
        reason: '长宽比必须保持（拉伸就说明同时给了宽高）');
    img.dispose();
  });

  testWidgets('④ 真解码上限：800×6000 源、目标高取上限 ⇒ 解出 4096（不是 6000）',
      (t) async {
    final ctx = await _ctx(t);
    final target =
        coverDecodeHeightFor(ctx, layoutWidth: 800, layoutHeight: 1e5);
    final bytes = await t.runAsync(() => _syntheticPng(800, 6000));
    final img = await _decode(t, bytes!, targetH: target);
    // ignore: avoid_print
    print('DS|800x6000 -> targetH=$target => ${img.width}x${img.height}');
    expect(target, kCoverDecodeMaxPx);
    expect(img.height, kCoverDecodeMaxPx,
        reason: '★ 上限没生效：解出来会是源 6000 ⇒ 内存白付（拆 clamp 的注入就这样红）');
    expect(img.height, lessThan(6000));
    img.dispose();
  });

  testWidgets('⑤ 仪器自检：不传目标 ⇒ 解出就是源 800×6000（否则③④读数不可信）',
      (t) async {
    final bytes = await t.runAsync(() => _syntheticPng(800, 6000));
    final img = await _decode(t, bytes!);
    // ignore: avoid_print
    print('DS|instrument: raw => ${img.width}x${img.height}');
    expect(img.width, 800);
    expect(img.height, 6000,
        reason: '仪器坏了（解码拿不到真尺寸）⇒ ③④ 的"变小"可能是假象');
    img.dispose();
  });
}
