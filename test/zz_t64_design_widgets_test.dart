// 2026-10-17 Owner 第 4/8/9 条：AppTextField / AppTextButton / AppIconButton 行为验证
//
// 这些控件是摘掉 material_ui 的关键路径 —— 每个都必须能在**没有祖先 Material** 的环境下工作。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/design/theme/app_theme.dart';
import 'package:sourin_spike/design/theme/app_theme_data.dart';
import 'package:sourin_spike/design/widgets/app_icon_button.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/design/widgets/app_text_field.dart';
import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/app_typeface.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

void main() {
  /// ★ 刻意**不包 MaterialApp** —— 用 AppThemeScope 提供主题
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

  group('AppTextButton', () {
    testWidgets('1 点击触发', (tester) async {
      var n = 0;
      await tester.pumpWidget(host(AppTextButton(
        onPressed: () => n++,
        child: const Text('确定'),
      )));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(n, 1);
    });

    testWidgets('2 onPressed 为 null => 禁用，不触发', (tester) async {
      await tester.pumpWidget(host(const AppTextButton(
        onPressed: null,
        child: Text('禁用'),
      )));
      await tester.tap(find.text('禁用'), warnIfMissed: false);
      await tester.pumpAndSettle();
      // 没有崩溃 = 通过（禁用态不该包 AppInkWell）
      expect(find.byType(AppTextButton), findsOneWidget);
    });
  });

  group('AppIconButton', () {
    testWidgets('3 点击触发', (tester) async {
      var n = 0;
      await tester.pumpWidget(host(AppIconButton(
        onPressed: () => n++,
        icon: const SizedBox(width: 16, height: 16),
      )));
      await tester.tap(find.byType(AppIconButton));
      await tester.pumpAndSettle();
      expect(n, 1);
    });

    testWidgets('4 tooltip 走 Semantics（不用 Material Tooltip）', (tester) async {
      await tester.pumpWidget(host(AppIconButton(
        onPressed: () {},
        icon: const SizedBox(width: 16, height: 16),
        tooltip: '返回',
      )));
      // 语义树里能找到 label
      expect(find.bySemanticsLabel('返回'), findsOneWidget);
    });
  });

  group('AppTextField', () {
    testWidgets('5 输入触发 onChanged', (tester) async {
      final got = <String>[];
      await tester.pumpWidget(host(AppTextField(
        onChanged: got.add,
        hint: '请输入',
      )));

      await tester.enterText(find.byType(AppTextField), 'abc');
      await tester.pumpAndSettle();
      expect(got.join(''), contains('abc'));
    });

    testWidgets('6 hint 在有内容时消失', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(host(AppTextField(
        controller: ctrl,
        hint: '地址',
      )));

      expect(find.text('地址'), findsOneWidget, reason: '空值时应显示 hint');

      ctrl.text = 'http://x';
      await tester.pump();
      expect(find.text('地址'), findsNothing, reason: '有内容时 hint 必须消失');
      ctrl.dispose();
    });

    testWidgets('7 ★ 外部传入的 controller 不许被内部 dispose', (tester) async {
      final ctrl = TextEditingController();
      await tester.pumpWidget(host(AppTextField(controller: ctrl)));
      // 卸载组件
      await tester.pumpWidget(host(const SizedBox()));
      await tester.pumpAndSettle();

      // 如果内部错误地 dispose 了它，这里会抛 "A TextEditingController was used after being disposed"
      ctrl.text = 'still alive';
      expect(ctrl.text, 'still alive',
          reason: '外部传入的 controller 归外部管，内部 dispose 会导致销毁后使用');
      ctrl.dispose();
    });
  });
}
