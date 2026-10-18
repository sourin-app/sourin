// 2026-10-17：AppTooltip / AppSlider 行为验证

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/design/theme/app_theme.dart';
import 'package:sourin_spike/design/theme/app_theme_data.dart';
import 'package:sourin_spike/design/widgets/app_tooltip_slider.dart';
import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/app_typeface.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

void main() {
  Widget host(Widget child) {
    final pack = ThemePackStore.builtins.first;
    return AppThemeScope(
      data: AppThemeData(
        palette: pack.brightness == Brightness.dark
            ? AppPalette.dark
            : AppPalette.light,
        typeface: AppTypeface.forPlatform(pack.brightness),
        pack: pack,
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (_) => Center(child: child),
            ),
          ],
        ),
      ),
    );
  }

  group("AppSlider", () {
    testWidgets("1 点击左端 => 回调接近 min", (tester) async {
      final got = <double>[];
      await tester.pumpWidget(host(SizedBox(
        width: 200,
        child: AppSlider(value: 0.5, onChanged: got.add, min: 0, max: 100),
      )));

      final box = tester.getRect(find.byType(AppSlider));
      await tester.tapAt(Offset(box.left + 2, box.center.dy));
      await tester.pumpAndSettle();

      expect(got, isNotEmpty);
      expect(got.last, lessThan(10));
    });

    testWidgets("2 点击右端 => 回调接近 max", (tester) async {
      final got = <double>[];
      await tester.pumpWidget(host(SizedBox(
        width: 200,
        child: AppSlider(value: 0.5, onChanged: got.add, min: 0, max: 100),
      )));

      final box = tester.getRect(find.byType(AppSlider));
      await tester.tapAt(Offset(box.right - 2, box.center.dy));
      await tester.pumpAndSettle();

      expect(got.last, greaterThan(90));
    });

    testWidgets("3 divisions 吸附到档位", (tester) async {
      final got = <double>[];
      await tester.pumpWidget(host(SizedBox(
        width: 100,
        child: AppSlider(
          value: 0, onChanged: got.add, min: 0, max: 1, divisions: 4,
        ),
      )));

      final box = tester.getRect(find.byType(AppSlider));
      await tester.tapAt(Offset(box.left + 30, box.center.dy));
      await tester.pumpAndSettle();

      expect(got.last, closeTo(0.25, 0.001));
    });

    testWidgets("4b label 只在拖动中出现（dlg-plugin 审计要求的参数）", (tester) async {
      final got = <double>[];
      await tester.pumpWidget(host(SizedBox(
        width: 200,
        child: AppSlider(
          value: 0.5,
          onChanged: got.add,
          min: 0,
          max: 100,
          label: "50%",
        ),
      )));

      // 未拖动时不该出现
      expect(find.text("50%"), findsNothing, reason: "未拖动时不该显示 label");

      final box = tester.getRect(find.byType(AppSlider));
      final g = await tester.startGesture(box.center);
      await tester.pump();
      await g.moveBy(const Offset(20, 0));
      await tester.pump();

      expect(find.text("50%"), findsOneWidget, reason: "拖动中应显示 label");

      await g.up();
      await tester.pumpAndSettle();
      expect(find.text("50%"), findsNothing, reason: "松手后 label 应消失");
    });

    testWidgets("4 onChanged 为 null => 禁用，点击无回调", (tester) async {
      await tester.pumpWidget(host(SizedBox(
        width: 100,
        child: const AppSlider(value: 0.5, onChanged: null),
      )));

      final box = tester.getRect(find.byType(AppSlider));
      await tester.tapAt(Offset(box.center.dx, box.center.dy));
      await tester.pumpAndSettle();
      expect(find.byType(AppSlider), findsOneWidget);
    });
  });

  group("AppTooltip", () {
    testWidgets("5 悬停超时后出现气泡，移开消失", (tester) async {
      await tester.pumpWidget(host(AppTooltip(
        message: "提示文字",
        child: const SizedBox(width: 60, height: 30, child: Text("target")),
      )));

      expect(find.text("提示文字"), findsNothing);

      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      await g.moveTo(tester.getCenter(find.text("target")));
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text("提示文字"), findsOneWidget);

      await g.moveTo(const Offset(500, 500));
      await tester.pump();
      expect(find.text("提示文字"), findsNothing);
    });
  });
}
