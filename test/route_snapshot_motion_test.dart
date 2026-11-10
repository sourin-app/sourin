import 'dart:ui' as dart_ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';
import 'package:sourin_spike/ui/widgets/page_transition_route.dart';

void main() {
  testWidgets(
    'snapshot content continues fading during both route directions',
    (t) async {
      final previous = PageTransitionStyleStore.current.value;
      PageTransitionStyleStore.current.value = PageTransitionStyle.fade;
      addTearDown(() => PageTransitionStyleStore.current.value = previous);
      final controller = AnimationController(
        vsync: t,
        duration: const Duration(milliseconds: 260),
      );
      final key = GlobalKey();
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: ColoredBox(
                    color: Colors.black,
                    child: const SourinPageTransitionsBuilder()
                        .buildTransitions(
                          route,
                          context,
                          const AlwaysStoppedAnimation<double>(1),
                          controller,
                          const ColoredBox(color: Colors.red),
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<int> red() async {
        final box =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        return (await t.runAsync(() async {
          final image = await box.toImage();
          final data = await image.toByteData(
            format: dart_ui.ImageByteFormat.rawRgba,
          );
          final value = data!.getUint8((100 * image.width + 100) * 4);
          image.dispose();
          return value;
        }))!;
      }

      await t.pump();
      controller.forward();
      await t.pump();
      await t.pump(const Duration(milliseconds: 25));
      final start = await red();
      await t.pump(const Duration(milliseconds: 100));
      final mid = await red();
      expect(
        start - mid,
        greaterThan(30),
        reason: 'cached page must continue fading instead of holding its first opacity',
      );
      await t.pumpAndSettle();
      controller.reverse();
      await t.pump();
      await t.pump(const Duration(milliseconds: 25));
      final reverseStart = await red();
      await t.pump(const Duration(milliseconds: 150));
      final reverseMid = await red();
      expect(
        reverseMid - reverseStart,
        greaterThan(20),
        reason: 'return transition must progressively reveal cached content',
      );
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      controller.dispose();
      route.dispose();
      expect(t.takeException(), isNull);
    },
  );
}
