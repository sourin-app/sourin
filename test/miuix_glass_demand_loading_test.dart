import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

Future<void> waitForPrograms(WidgetTester tester, Set<String> expected) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!expected.every(miuix.MiuixGlassRendering.has)) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'Shader programs unavailable: '
          '${miuix.MiuixGlassRendering.loadedPrograms}; '
          '${miuix.MiuixGlassRendering.loadError}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  await tester.pump();
}

void main() {
  testWidgets(
    'glass loads background shaders when the same surface gains a backdrop',
    (tester) async {
      const surface = <String>{'mask', 'stroke', 'shadow', 'rim'};
      const all = <String>{...surface, 'glass', 'blend'};
      const glassKey = ValueKey<String>('demand-glass');
      final captureKey = GlobalKey();
      final backdrop = miuix.MiuixLayerBackdrop();
      addTearDown(backdrop.dispose);

      Widget host(miuix.MiuixBackdrop? background) => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: miuix.MiuixTheme(
            data: miuix.MiuixThemeData.light(),
            child: Center(
              child: RepaintBoundary(
                key: captureKey,
                child: SizedBox(
                  width: 160,
                  height: 100,
                  child: miuix.MiuixGlassPanel(
                    key: glassKey,
                    backdrop: background,
                    fill: const Color(0xFF0044FF),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      Future<List<int>> centerPixel() async {
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await tester.runAsync(() => boundary.toImage());
        final bytes = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        image!.dispose();
        const index = (50 * 160 + 80) * 4;
        return bytes!.buffer.asUint8List().sublist(index, index + 4);
      }

      expect(miuix.MiuixGlassRendering.loadedPrograms, isEmpty);
      await tester.pumpWidget(host(null));
      final state = tester.state(find.byKey(glassKey));
      await waitForPrograms(tester, surface);
      expect(miuix.MiuixGlassRendering.loadedPrograms.toSet(), surface);
      expect(miuix.MiuixGlassRendering.isLoaded, isFalse);
      final untextured = await centerPixel();

      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 160, 100),
        Paint()..color = const Color(0xFFFF2200),
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(160, 100);
      picture.dispose();
      backdrop.updateSnapshot(
        image,
        tester.getTopLeft(find.byKey(glassKey)),
        1,
      );
      await tester.pumpWidget(host(backdrop));
      expect(identical(tester.state(find.byKey(glassKey)), state), isTrue);
      await waitForPrograms(tester, all);
      expect(miuix.MiuixGlassRendering.isLoaded, isTrue);
      expect(miuix.MiuixGlassRendering.loadError, isNull);
      final textured = await centerPixel();
      expect(
        textured,
        isNot(untextured),
        reason: 'The attached background must actually paint',
      );
      expect(
        textured[0],
        greaterThan(textured[2]),
        reason: 'The red background must reach the surface',
      );

      await tester.pumpWidget(host(null));
      expect(identical(tester.state(find.byKey(glassKey)), state), isTrue);
      expect(await centerPixel(), untextured);
      expect(
        identical(
          miuix.MiuixGlassRendering.load(),
          miuix.MiuixGlassRendering.load(),
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
