import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/widgets/app_page_header.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as controls;
import 'package:sourin_spike/ui/theme/miuix_palette.dart';

class _LifetimeProbe extends StatefulWidget {
  const _LifetimeProbe({required this.onInit, required this.child});
  final VoidCallback onInit;
  final Widget child;

  @override
  State<_LifetimeProbe> createState() => _LifetimeProbeState();
}

class _LifetimeProbeState extends State<_LifetimeProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  const contentKey = ValueKey('media-content-bounds');

  testWidgets('nested Miuix scaffolds consume the keyboard inset once', (
    tester,
  ) async {
    var initializations = 0;
    final probe = _LifetimeProbe(
      onInit: () => initializations++,
      child: const AppScaffold(child: SizedBox.expand(key: contentKey)),
    );
    Future<void> pumpInset(double bottom) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: bottom)),
          child: AppScaffold(child: probe),
        ),
      ),
    );

    await pumpInset(0);
    expect(find.byType(miuix.MiuixScaffold), findsNWidgets(2));
    final fullHeight = tester.getSize(find.byKey(contentKey)).height;
    expect(fullHeight, greaterThan(300));
    await pumpInset(200);
    expect(tester.getSize(find.byKey(contentKey)).height, fullHeight - 200);
    expect(
      MediaQuery.viewInsetsOf(tester.element(find.byKey(contentKey))).bottom,
      0,
    );
    expect(
      initializations,
      1,
      reason: 'Keyboard opening must preserve page state.',
    );
    await pumpInset(0);
    expect(tester.getSize(find.byKey(contentKey)).height, fullHeight);
    expect(
      initializations,
      1,
      reason: 'Keyboard closing must preserve page state.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('resize opt-out preserves both content size and child insets', (
    tester,
  ) async {
    Future<void> pumpInset(double bottom) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: bottom)),
          child: const AppScaffold(
            resizeToAvoidBottomInset: false,
            child: SizedBox.expand(key: contentKey),
          ),
        ),
      ),
    );

    await pumpInset(0);
    final fullSize = tester.getSize(find.byKey(contentKey));
    await pumpInset(200);
    expect(tester.getSize(find.byKey(contentKey)), fullSize);
    expect(
      MediaQuery.viewInsetsOf(tester.element(find.byKey(contentKey))).bottom,
      200,
    );
    expect(tester.takeException(), isNull);
  });
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('page body and list text remain readable in $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: DefaultTextStyle(
              style: const TextStyle(color: Color(0xFF000000)),
              child: miuix.MiuixTheme(
                data: miuixThemeData(brightness),
                child: const AppScaffold(
                  child: Column(
                    children: [
                      Text('正文'),
                      miuix.MiuixCard(
                        child: controls.ListTile(
                          leading: Text('1'),
                          title: Text('源名称'),
                          subtitle: Text('来源说明'),
                        ),
                      ),
                      Text('显式颜色', style: TextStyle(color: Color(0xFFFF0000))),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Color renderedColor(String text) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
        return paragraph.text.style!.color!;
      }

      final background = brightness == Brightness.dark
          ? const Color(0xFF1C1D21)
          : const Color(0xFFFFFFFF);
      for (final label in ['正文', '1', '源名称', '来源说明']) {
        final foreground = Color.alphaBlend(renderedColor(label), background);
        final a = foreground.computeLuminance();
        final b = background.computeLuminance();
        final contrast = a > b
            ? (a + 0.05) / (b + 0.05)
            : (b + 0.05) / (a + 0.05);
        expect(contrast, greaterThanOrEqualTo(4.5), reason: label);
      }
      expect(renderedColor('显式颜色'), const Color(0xFFFF0000));
      expect(tester.takeException(), isNull);
    });
  }
  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final explicitBlack in [false, true]) {
      testWidgets(
        'scaffold renders page background and card separately ($brightness, black=$explicitBlack)',
        (tester) async {
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: MediaQuery(
                data: const MediaQueryData(),
                child: miuix.MiuixTheme(
                  data: miuixThemeData(brightness),
                  child: RepaintBoundary(
                    key: boundaryKey,
                    child: AppScaffold(
                      header: AppPageHeader(
                        title: '页面',
                        backgroundColor: explicitBlack
                            ? const Color(0xFF000000)
                            : null,
                      ),
                      backgroundColor: explicitBlack
                          ? const Color(0xFF000000)
                          : null,
                      child: const Center(
                        child: miuix.MiuixCard(
                          child: SizedBox(width: 120, height: 90),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final pixels = await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final data = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            List<int> pixel(int x, int y) {
              final offset = (y * image.width + x) * 4;
              return [for (var i = 0; i < 4; i++) data.getUint8(offset + i)];
            }

            final result = [
              pixel(10, image.height - 10),
              pixel(image.width ~/ 2, 10),
              pixel(image.width ~/ 2, image.height ~/ 2),
            ];
            image.dispose();
            return result;
          });
          expect(
            pixels![0],
            explicitBlack
                ? [0, 0, 0, 255]
                : brightness == Brightness.light
                ? [245, 246, 248, 255]
                : [16, 17, 20, 255],
          );
          expect(
            pixels[2],
            brightness == Brightness.light
                ? [255, 255, 255, 255]
                : [28, 29, 33, 255],
          );
          expect(
            pixels[1],
            pixels[0],
            reason: 'Header and page share the background role',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
