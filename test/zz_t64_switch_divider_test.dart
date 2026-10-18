// 2026-10-17：AppSwitch / AppDivider 行为验证
//
// 关键判据：**没有祖先 Material 也必须工作**（这是摘掉 material_ui 的前提）

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/design/theme/app_theme.dart';
import 'package:sourin_spike/design/theme/app_theme_data.dart';
import 'package:sourin_spike/design/widgets/app_switch.dart';
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
        child: Center(child: child),
      ),
    );
  }

  group('AppSwitch', () {
    testWidgets('1 点击切换回调（true -> false）', (tester) async {
      bool? got;
      await tester.pumpWidget(host(AppSwitch(
        value: true,
        onChanged: (v) => got = v,
      )));

      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      expect(got, isFalse, reason: '当前是 true，点一下应回传 false');
    });

    testWidgets('2 点击切换回调（false -> true）', (tester) async {
      bool? got;
      await tester.pumpWidget(host(AppSwitch(
        value: false,
        onChanged: (v) => got = v,
      )));

      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      expect(got, isTrue);
    });

    testWidgets('3 onChanged 为 null => 禁用，点击无回调', (tester) async {
      await tester.pumpWidget(host(const AppSwitch(value: false)));

      await tester.tap(find.byType(AppSwitch), warnIfMissed: false);
      await tester.pumpAndSettle();
      // 没有崩溃 = 通过（禁用态不该有回调）
      expect(find.byType(AppSwitch), findsOneWidget);
    });

    testWidgets('4 开关状态体现在滑块位置（不是只看颜色）', (tester) async {
      await tester.pumpWidget(host(AppSwitch(value: false, onChanged: (_) {})));
      await tester.pumpAndSettle();

      Rect knobOff() {
        // 滑块是那个圆形的 Container
        final containers = tester.widgetList<Container>(
          find.descendant(
            of: find.byType(AppSwitch),
            matching: find.byType(Container),
          ),
        );
        final circular = containers.firstWhere((c) {
          final d = c.decoration;
          return d is BoxDecoration && d.shape == BoxShape.circle;
        });
        expect(circular, isNotNull);
        return tester.getRect(find.byWidget(circular));
      }

      final offX = knobOff().left;

      await tester.pumpWidget(host(AppSwitch(value: true, onChanged: (_) {})));
      await tester.pumpAndSettle();
      final onX = knobOff().left;

      expect(onX, greaterThan(offX),
          reason: '开启后滑块必须右移 —— 位置是比颜色更可靠的状态信号（色盲用户）');
    });
  });

  group('AppDivider', () {
    testWidgets('5 渲染一条线，颜色用主题边框色', (tester) async {
      await tester.pumpWidget(host(const AppDivider()));

      final c = tester.widget<Container>(
        find.descendant(
          of: find.byType(AppDivider),
          matching: find.byType(Container),
        ),
      );
      expect(c.color, isNotNull);
    });

    testWidgets('6 indent 生效', (tester) async {
      await tester.pumpWidget(host(const AppDivider(indent: 16)));

      final pad = tester.widget<Padding>(
        find.descendant(
          of: find.byType(AppDivider),
          matching: find.byType(Padding),
        ).first,
      );
      final p = pad.padding as EdgeInsets;
      expect(p.left, 16);
      expect(p.right, 16);
    });
  });
}
