import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart';
// Exercise the shipped example without a circular dev dependency on its package.
// ignore: avoid_relative_lib_imports
import '../example/lib/showcase/os4.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await MiuixGlassRendering.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    const font = String.fromEnvironment('MIUIX_QA_FONT');
    if (font.isNotEmpty) {
      final bytes = await File(font).readAsBytes();
      await (FontLoader(
        'Os4QA',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  testWidgets('真实 backdrop 可绘制折射、材质层与更新后的背景', (tester) async {
    final backdrop = MiuixLayerBackdrop(), key = GlobalKey();
    Color background = Colors.blue;
    late StateSetter update;
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.light(),
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Center(
                  child: RepaintBoundary(
                    key: key,
                    child: SizedBox(
                      width: 320,
                      height: 220,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: MiuixLayerBackdropCapture(
                              backdrop: backdrop,
                              child: ColoredBox(color: background),
                            ),
                          ),
                          Positioned(
                            left: 40,
                            top: 50,
                            width: 110,
                            height: 110,
                            child: MiuixGlassPanel(
                              backdrop: backdrop,
                              style: MiuixGlassStyles.commonSmallThin,
                              stroke: MiuixGlassStrokes.middleLight,
                              child: const SizedBox.expand(),
                            ),
                          ),
                          Positioned(
                            left: 170,
                            top: 50,
                            width: 110,
                            height: 110,
                            child: MiuixGlassPanel(
                              backdrop: backdrop,
                              shading: false,
                              material: MiuixGlassMaterials.puredThinGlassLight,
                              stroke: MiuixGlassStrokes.middleLight,
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(backdrop.snapshot, isNotNull);
    Future<Uint8List> pixels() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      if (const bool.fromEnvironment('MIUIX_WRITE_QA')) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/os4_qa').create(recursive: true);
        await File(
          'build/os4_qa/debug_material.png',
        ).writeAsBytes(png!.buffer.asUint8List());
      }
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }

    final first = (await tester.runAsync(pixels))!;
    final center = (100 * 320 + 220) * 4;
    expect(
      first[center] + first[center + 1] + first[center + 2],
      greaterThan(0),
    );
    expect(
      first.sublist(center, center + 3),
      isNot([255, 255, 255]),
      reason: 'Must sample the blue backdrop, not solid fallback',
    );
    update(() => background = Colors.red);
    await tester.pumpAndSettle();
    final second = (await tester.runAsync(pixels))!;
    expect(
      second.sublist(center, center + 3),
      isNot(first.sublist(center, center + 3)),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    backdrop.dispose();
  });
  for (final dark in [false, true]) {
    testWidgets('OS4 展示页真实渲染与菜单交互：dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        MiuixTheme(
          data: dark ? MiuixThemeData.dark() : MiuixThemeData.light(),
          child: RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
                fontFamily: 'Os4QA',
              ),
              home: const Os4Showcase(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView).first, const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      Future<void> capture(String name) async {
        if (!const bool.fromEnvironment('MIUIX_WRITE_QA')) return;
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await Directory('build/os4_qa').create(recursive: true);
        await File(
          'build/os4_qa/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      }

      await tester.runAsync(() => capture(dark ? 'dark' : 'light'));
      await tester.tap(find.byTooltip('变形菜单'));
      await tester.pumpAndSettle();
      expect(find.text('更多选项'), findsOneWidget);
      await tester.tap(find.text('更多选项'));
      await tester.pumpAndSettle();
      expect(find.text('返回上级'), findsOneWidget);
      await tester.runAsync(() => capture(dark ? 'dark_menu' : 'light_menu'));
      await tester.tap(find.text('返回上级'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'search');
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
  testWidgets('捕获背景滚动后玻璃导航重新取样', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final backdrop = MiuixLayerBackdrop();
    final scroll = ScrollController();
    final frameKey = GlobalKey();
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.light(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: frameKey,
                child: SizedBox(
                  width: 320,
                  height: 240,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: MiuixLayerBackdropCapture(
                          backdrop: backdrop,
                          child: RepaintBoundary(
                            child: ListView(
                              controller: scroll,
                              itemExtent: 240,
                              padding: EdgeInsets.zero,
                              children: const [
                                ColoredBox(color: Color(0xFF0000FF)),
                                ColoredBox(color: Color(0xFFFF0000)),
                                ColoredBox(color: Color(0xFF00FF00)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: MiuixGlassNavigationBar(
                          backdrop: backdrop,
                          selectedIndex: 0,
                          onSelect: (_) {},
                          items: const [
                            MiuixGlassNavigationItem(icon: SizedBox()),
                            MiuixGlassNavigationItem(icon: SizedBox()),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    int channel(Uint8List px, int x, int y, int c) => px[(y * 320 + x) * 4 + c];
    Future<Uint8List> snapshotPixels() async => _rgba(backdrop.snapshot!);
    Future<Uint8List> framePixels() async {
      final image =
          await (frameKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }

    final firstSnapshot = (await tester.runAsync(snapshotPixels))!;
    expect(channel(firstSnapshot, 160, 120, 2), greaterThan(200));
    expect(channel(firstSnapshot, 160, 120, 0), lessThan(20));
    final firstFrame = (await tester.runAsync(framePixels))!;
    expect(
      channel(firstFrame, 160, 197, 2),
      greaterThan(channel(firstFrame, 160, 197, 0)),
    );

    scroll.jumpTo(240);
    await tester.pump();
    await tester.pump();
    final secondSnapshot = (await tester.runAsync(snapshotPixels))!;
    expect(channel(secondSnapshot, 160, 120, 0), greaterThan(200));
    expect(channel(secondSnapshot, 160, 120, 2), lessThan(20));
    final secondFrame = (await tester.runAsync(framePixels))!;
    final navPixel = (197 * 320 + 160) * 4;
    expect(secondFrame[navPixel], greaterThan(secondFrame[navPixel + 2]));
    expect(
      secondFrame.sublist(navPixel, navPixel + 3),
      isNot(firstFrame.sublist(navPixel, navPixel + 3)),
    );

    scroll.jumpTo(480);
    await tester.pump();
    await tester.pump();
    final thirdSnapshot = (await tester.runAsync(snapshotPixels))!;
    expect(channel(thirdSnapshot, 160, 120, 1), greaterThan(200));

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    backdrop.dispose();
  });
  testWidgets('捕获内独立重绘边界更新时快照重录', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final backdrop = MiuixLayerBackdrop();
    final color = ValueNotifier<Color>(const Color(0xFF0000FF));
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.light(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 240,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: MiuixLayerBackdropCapture(
                        backdrop: backdrop,
                        child: RepaintBoundary(
                          child: ValueListenableBuilder<Color>(
                            valueListenable: color,
                            builder: (_, value, _) => ColoredBox(color: value),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: MiuixGlassNavigationBar(
                        backdrop: backdrop,
                        selectedIndex: 0,
                        onSelect: (_) {},
                        items: const [
                          MiuixGlassNavigationItem(icon: SizedBox()),
                          MiuixGlassNavigationItem(icon: SizedBox()),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    color.value = const Color(0xFFFF0000);
    await tester.pump();
    await tester.pump();
    final px = (await tester.runAsync(() => _rgba(backdrop.snapshot!)))!;
    expect(px[(120 * 320 + 160) * 4], greaterThan(200));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    color.dispose();
    backdrop.dispose();
  });
  testWidgets('空闲与玻璃自身重绘不重复截图', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final backdrop = _CountingBackdrop();
    final outside = ValueNotifier<double>(0.5);
    final inner = ValueNotifier<Color>(const Color(0xFF0000FF));
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.light(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 240,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: MiuixLayerBackdropCapture(
                        backdrop: backdrop,
                        child: ValueListenableBuilder<Color>(
                          valueListenable: inner,
                          builder: (_, value, _) => ColoredBox(color: value),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 40,
                      top: 50,
                      width: 110,
                      height: 110,
                      child: ValueListenableBuilder<double>(
                        valueListenable: outside,
                        builder: (_, value, _) => MiuixGlassPanel(
                          backdrop: backdrop,
                          alpha: value,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final baseline = backdrop.updates;
    expect(baseline, greaterThan(0));
    for (var i = 0; i < 10; i++) {
      outside.value = 0.5 + (i + 1) * 0.01;
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(backdrop.updates, baseline);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);

    inner.value = const Color(0xFFFF0000);
    await tester.pumpAndSettle();
    expect(backdrop.updates, baseline + 1);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backdrop.updates, baseline + 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    outside.dispose();
    inner.dispose();
    backdrop.dispose();
  });
  testWidgets('快照 pixelRatio 覆盖与纹理模糊采样映射一致', (tester) async {
    tester.view.physicalSize = const Size(960, 720);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final backdrop = MiuixLayerBackdrop();
    final frameKey = GlobalKey();
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.light(),
        child: MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: frameKey,
              child: SizedBox.expand(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: MiuixLayerBackdropCapture(
                        backdrop: backdrop,
                        pixelRatio: 1,
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              height: 120,
                              child: ColoredBox(color: Color(0xFF0000FF)),
                            ),
                            SizedBox(
                              height: 120,
                              child: ColoredBox(color: Color(0xFFFF0000)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Positioned(
                      left: 20,
                      top: 120,
                      width: 80,
                      height: 40,
                      child: ColoredBox(color: Color(0xFF00FF00)),
                    ),
                    Positioned(
                      left: 20,
                      top: 120,
                      width: 80,
                      height: 40,
                      child: MiuixTextureBlur(
                        backdrop: backdrop,
                        blurRadius: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(backdrop.pixelRatio, 1);
    expect(backdrop.snapshot!.width, 320);
    expect(backdrop.snapshot!.height, 240);
    final snap = (await tester.runAsync(() => _rgba(backdrop.snapshot!)))!;
    var s = (60 * 320 + 60) * 4;
    expect(snap[s + 2], greaterThan(200), reason: '上半应为蓝');
    expect(snap[s], lessThan(20));
    s = (140 * 320 + 60) * 4;
    expect(snap[s], greaterThan(200), reason: '下半应为红');
    expect(snap[s + 2], lessThan(20));
    final frame = (await tester.runAsync(() async {
      final image =
          await (frameKey.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
    final i = (140 * 320 + 60) * 4;
    expect(
      frame[i],
      greaterThan(200),
      reason:
          'rgba=${frame[i]},${frame[i + 1]},${frame[i + 2]},${frame[i + 3]}',
    );
    expect(frame[i + 1], lessThan(80));
    expect(frame[i + 2], lessThan(80));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    backdrop.dispose();
  });
  testWidgets('拖动导航滑块不重读快照也不重录背景', (tester) async {
    tester.view.physicalSize = const Size(320, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backdrop = _CountingBackdrop();
    final calls = <int>[];
    await tester.pumpWidget(
      MiuixTheme(
        data: MiuixThemeData.light(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 240,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: MiuixLayerBackdropCapture(
                        backdrop: backdrop,
                        child: const ColoredBox(color: Color(0xFF0000FF)),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 16,
                      child: MiuixGlassNavigationBar(
                        backdrop: backdrop,
                        selectedIndex: 0,
                        onSelect: calls.add,
                        items: const [
                          MiuixGlassNavigationItem(
                            icon: SizedBox(),
                            label: 'A',
                          ),
                          MiuixGlassNavigationItem(
                            icon: SizedBox(),
                            label: 'B',
                          ),
                          MiuixGlassNavigationItem(
                            icon: SizedBox(),
                            label: 'C',
                          ),
                          MiuixGlassNavigationItem(
                            icon: SizedBox(),
                            label: 'D',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(backdrop.snapshot, isNotNull);
    final baselineReads = backdrop.snapshotReads;
    final baselineUpdates = backdrop.updates;
    final bar = tester.getRect(find.byType(MiuixGlassNavigationBar));
    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pumpAndSettle();
    for (final x in [60.0, 84.0, 130.0, 160.0, 220.0, 160.0, 84.0]) {
      await gesture.moveTo(Offset(bar.left + x, bar.center.dy));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(backdrop.snapshotReads, baselineReads);
    expect(backdrop.updates, baselineUpdates);
    expect(calls, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(backdrop.snapshotReads, baselineReads);
    expect(backdrop.updates, baselineUpdates);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    backdrop.dispose();
  });
}

Future<Uint8List> _rgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

class _CountingBackdrop extends MiuixLayerBackdrop {
  int updates = 0;
  int snapshotReads = 0;

  @override
  void updateSnapshot(ui.Image image, Offset globalOffset, double pixelRatio) {
    updates++;
    super.updateSnapshot(image, globalOffset, pixelRatio);
  }

  @override
  ui.Image? get snapshot {
    snapshotReads++;
    return super.snapshot;
  }
}
