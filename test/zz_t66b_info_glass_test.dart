// The historical filename is retained for existing test selectors.
// Actual Miuix cards own the surface. Video pixels must not tint its text bed.
import 'dart:ui' as raster;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';

DanmakuInfoData _loaded() => const DanmakuInfoData(
      source: DanmakuFeedKind.bili,
      match: DanmakuPairKind.autoSearch,
      count: 1200,
      title: '鬼灭之刃 柱训练篇',
      cid: 1602741036,
      enabled: true,
    );

DanmakuInfoData _failed() => DanmakuInfoData(
      source: DanmakuFeedKind.bili,
      match: DanmakuPairKind.autoSearch,
      count: 0,
      title: '',
      cid: 0,
      enabled: true,
      aggregate: <DanmakuAggregateFeed>[
        DanmakuAggregateFeed(
          label: 'dan-api',
          count: 0,
          loaded: false,
          error: '连接被拒绝',
        ),
      ],
    );

const _captureKey = ValueKey('info-panel-surface-capture');

Widget _host(Widget child, {Color backdrop = const Color(0xFF1A2030)}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: RepaintBoundary(
          key: _captureKey,
          child: ColoredBox(
            color: backdrop,
            child: Align(alignment: Alignment.topRight, child: child),
          ),
        ),
      ),
    );

Future<Color> _surfacePixel(WidgetTester tester) async {
  final card = tester.getRect(find.byType(miuix.MiuixCard).first);
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  // This inset is inside the surface and outside the padded text content.
  final sample = boundary.globalToLocal(card.topLeft + const Offset(12, 5));
  final color = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = (await image.toByteData(format: raster.ImageByteFormat.rawRgba))!;
    final offset = (sample.dy.floor() * image.width + sample.dx.floor()) * 4;
    final result = Color.fromARGB(
      bytes.getUint8(offset + 3), bytes.getUint8(offset),
      bytes.getUint8(offset + 1), bytes.getUint8(offset + 2),
    );
    image.dispose();
    return result;
  });
  return color!;
}

void main() {
  group('实际 Miuix 信息卡片', () {
    testWidgets('展开与收起状态都使用 MiuixCard', (tester) async {
      for (final expanded in [true, false]) {
        await tester.pumpWidget(_host(DanmakuInfoPanel(
          key: ValueKey(expanded), data: _loaded(), initiallyExpanded: expanded,
        )));
        await tester.pumpAndSettle();
        expect(find.byType(miuix.MiuixCard), findsOneWidget);
      }
    });

    testWidgets('MiuixCard 实际包住信息内容', (tester) async {
      await tester.pumpWidget(_host(DanmakuInfoPanel(data: _loaded())));
      await tester.pumpAndSettle();
      expect(find.descendant(
        of: find.byType(miuix.MiuixCard), matching: find.text('已载入'),
      ), findsOneWidget);
    });

    testWidgets('亮画面和彩色画面不改变文字背后的实际表面像素', (tester) async {
      final colors = <Color>[];
      for (final backdrop in [Colors.white, const Color(0xFF00E5FF)]) {
        await tester.pumpWidget(_host(
          DanmakuInfoPanel(data: _loaded()), backdrop: backdrop,
        ));
        await tester.pumpAndSettle();
        final color = await _surfacePixel(tester);
        colors.add(color);
        expect(color.computeLuminance(), lessThan(.02));
        expect(color.a, 1);
      }
      expect(colors.last, colors.first,
          reason: '视频背景不能透进信息面板，改变文字对比度。');
    });
  });

  group('信息与交互保留', () {
    testWidgets('展开态保留来源条数与匹配信息', (tester) async {
      await tester.pumpWidget(_host(DanmakuInfoPanel(data: _loaded())));
      await tester.pumpAndSettle();
      expect(find.text('已载入'), findsOneWidget);
      expect(find.textContaining('1200'), findsWidgets);
      expect(find.text('匹配'), findsOneWidget);
      expect(find.textContaining('1602741036'), findsOneWidget);
    });

    testWidgets('失败原因仍然可见', (tester) async {
      await tester.pumpWidget(_host(DanmakuInfoPanel(data: _failed())));
      await tester.pumpAndSettle();
      expect(find.textContaining('连接被拒绝'), findsOneWidget);
    });

    testWidgets('收起态只显示条数，点击可展开', (tester) async {
      await tester.pumpWidget(_host(DanmakuInfoPanel(
        data: _loaded(), initiallyExpanded: false,
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('1200'), findsOneWidget);
      expect(find.text('已载入'), findsNothing);
      await tester.tap(find.textContaining('1200'));
      await tester.pumpAndSettle();
      expect(find.text('已载入'), findsOneWidget);
    });
  });
}
