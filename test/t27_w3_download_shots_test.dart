@Tags(['needs-shot-dir'])
// ignore_for_file: avoid_print
//
// ═══════════════════════════════════════════════════════════════════════
//  Owner m00138「下载按钮跟前面的不一样 样式」—— 改后看图台
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独有一份（2026-10-11）
// 业主给了一张截图（421×197，亮色主题）指出四枚按钮里「下载」跟前面三枚
// 不是一个样式。断言只能锁住**可量化**的那部分（几何 / 描边 / 字重 / 图标色），
// 那部分在 t27_w3_download_button_style_test.dart；这里只负责把改后的真实
// 渲染落成 PNG，给人眼确认「看起来也一样了」。
//
// # 跑法
// ```powershell
//   $env:SOURIN_SHOT_DIR = '.probe\shots-item3'
//   flutter test test/t27_w3_download_shots_test.dart --run-skipped `
//     --tags needs-shot-dir --concurrency=1
// ```
//
// # ⚠️ 这份图**不能**替代平台几何门禁
// flutter_tester 里 defaultTargetPlatform 恒为 android（SDK
// foundation/_platform_io.dart 的 FLUTTER_TEST 断言）。本文件显式 override
// 成 windows 是为了跟业主机器一致（字号族名也跟着变），但「下载与旁钮逐平台
// 同档」这条仍然由 t27_w3_download_button_style_test.dart 在 windows / android
// 两个平台上分别量 —— 截图看不出「windows 下差 16 逻辑像素」这种事。
//
// # 渲染的是真页面
// 挂真 DetailPage + debugSetDetail 注入详情（同 t27_w3 / t64_panel_fixed 的
// 既有做法）⇒ 图里就是生产代码画出来的东西，不是影子副本。
//
// ⚠️ 沙盒：本文件不碰磁盘、不碰网络（NetworkStatus.debugProbe 注入），
//    不写 %APPDATA%，唯一落盘就是 SOURIN_SHOT_DIR 下的 PNG。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';

import 'support/ui_shot.dart';

/// 操作行四枚按钮的标签（与生产代码同一批）
const List<String> _labels = <String>['收藏', '追更', '换源', '下载'];

String _hex(Color? c) =>
    c == null ? 'null' : '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

/// 从已落盘的 PNG 里裁一块放大 —— 四枚按钮在 1440×900 整屏里太小，
/// 不放大看不出「描边 / 字重 / 图标色」是否同档。
Future<File> _crop(File src, Rect region, String name, {double scale = 3.0}) async {
  final codec = await ui.instantiateImageCodec(src.readAsBytesSync());
  final frame = await codec.getNextFrame();
  final img = frame.image;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final dst = Rect.fromLTWH(0, 0, region.width * scale, region.height * scale);
  canvas.drawImageRect(
      img, region, dst, Paint()..filterQuality = FilterQuality.high);
  final out =
      await rec.endRecording().toImage(dst.width.round(), dst.height.round());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  out.dispose();
  final f = File('${shotDir().path}${Platform.pathSeparator}$name.png');
  f.writeAsBytesSync(bd!.buffer.asUint8List());
  return f;
}

void main() {
  setUpAll(loadRealFonts);

  Widget host(Widget child, Brightness b) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(b),
        home: RepaintBoundary(
          key: const ValueKey<String>('page'),
          child: Scaffold(body: Material(child: child)),
        ),
      );

  /// 挂真 DetailPage（在线模式）+ 注入 2 集 ⇒ 操作行出现
  Future<void> mount(WidgetTester t, Brightness b) async {
    NetworkStatus.debugProbe = () async => true;
    addTearDown(NetworkStatus.debugResetForTest);

    final key = GlobalKey<State<DetailPage>>();
    await t.pumpWidget(host(
      DetailPage(key: key, provider: 'cycani', id: '3862', embedded: true),
      b,
    ));
    _claim(t);
    await t.pump(const Duration(milliseconds: 50));
    _claim(t);

    const d = MediaDetail(
      id: '3862',
      title: '无职转生 第三季',
      episodes: <Episode>[
        Episode(id: 'ep-1', title: '第01集'),
        Episode(id: 'ep-2', title: '第02集'),
      ],
    );
    // ignore: avoid_dynamic_calls
    (key.currentState! as dynamic).debugSetDetail(d, episodes: d.episodes);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 60));
      _claim(t);
    }
  }

  /// 四枚按钮（按标签定位）在整屏坐标系里的并集矩形，外扩一点留白
  Rect actionRect(WidgetTester t) {
    final rects = <Rect>[];
    for (final lb in _labels) {
      final f = find.ancestor(
          of: find.text(lb), matching: find.byType(OutlinedButton));
      expect(f, findsOneWidget, reason: '操作行必须渲染出「$lb」这一枚');
      rects.add(t.getRect(f));
    }
    var r = rects.first;
    for (final x in rects.skip(1)) {
      r = r.expandToInclude(x);
    }
    return r.inflate(14);
  }

  for (final b in Brightness.values) {
    testWidgets('ITEM3 看图 · ${b.name}', (t) async {
      // ★ 跟业主机器一致：windows（tester 默认是 android）
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await setShotViewport(t, const Size(1440, 900));
        await mount(t, b);

        // ── 文本证据：几何 / 描边 / 前景色逐枚打出来 ──
        for (final lb in _labels) {
          final f = find.ancestor(
              of: find.text(lb), matching: find.byType(OutlinedButton));
          final btn = t.widget<OutlinedButton>(f);
          final side =
              _hex(btn.style?.side?.resolve(const <WidgetState>{})?.color);
          final fg =
              _hex(btn.style?.foregroundColor?.resolve(const <WidgetState>{}));
          print('[diag] ${b.name} $lb size=${t.getRect(f).size} '
              'side=$side fg=$fg');
        }

        final region = actionRect(t);
        print('[diag] ${b.name} 操作行区域 = $region');

        final full = await saveBoundaryShot(
            t, find.byKey(const ValueKey<String>('page')), 'item3_detail_${b.name}',
            pixelRatio: 2.0);
        print('[shot] ${full.path} (${full.lengthSync()} B)');
        expect(full.lengthSync(), greaterThan(20000),
            reason: '整页截图只有 ${full.lengthSync()} 字节，疑似空图');

        // 截图是 pixelRatio 2.0 落的，裁切区域也要跟着放大 2 倍
        final zoomRegion = Rect.fromLTWH(region.left * 2.0, region.top * 2.0,
            region.width * 2.0, region.height * 2.0);
        final zoom = await t.runAsync(
            () => _crop(full, zoomRegion, 'item3_actions_${b.name}_zoom'));
        print('[shot] ${zoom!.path} (${zoom.lengthSync()} B)');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
