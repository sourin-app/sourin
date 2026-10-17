// 验证 AppTestHost 真的能让 App* 组件在测试里工作
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/design/widgets/app_ink_well.dart';
import 'package:sourin_spike/design/widgets/app_switch.dart';
import 'package:sourin_spike/design/widgets/app_tooltip_slider.dart';

import 'support/app_test_host.dart';

void main() {
  testWidgets("1 AppTestHost 让 AppTextButton 正常工作", (tester) async {
    await tester.pumpWidget(AppTestHost(
      child: AppTextButton(onPressed: () {}, child: const Text('按钮')),
    ));
    await tester.pumpAndSettle();
    expect(find.text("按钮"), findsOneWidget);
  });

  testWidgets("2 AppTestHost 让 AppInkWell 正常工作", (tester) async {
    var tapped = false;
    await tester.pumpWidget(AppTestHost(
      child: AppInkWell(
        onTap: () => tapped = true,
        child: const Text('点我'),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text("点我"));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
  });

  testWidgets("3 AppTestHost 让 AppSwitch 正常工作", (tester) async {
    var v = false;
    await tester.pumpWidget(AppTestHost(
      child: StatefulBuilder(
        builder: (c, setState) => AppSwitch(
          value: v,
          onChanged: (n) => setState(() => v = n),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();
    expect(v, isTrue);
  });

  testWidgets("4 AppTestHost 让 AppSlider 正常工作", (tester) async {
    final got = <double>[];
    await tester.pumpWidget(AppTestHost(
      child: SizedBox(
        width: 200,
        child: AppSlider(value: 0.5, onChanged: got.add),
      ),
    ));
    await tester.pumpAndSettle();
    final box = tester.getRect(find.byType(AppSlider));
    await tester.tapAt(Offset(box.left + 5, box.center.dy));
    await tester.pumpAndSettle();
    expect(got, isNotEmpty);
  });

  testWidgets("5 brightness 参数能切浅色", (tester) async {
    await tester.pumpWidget(AppTestHost(
      brightness: Brightness.light,
      child: const Text('浅色'),
    ));
    await tester.pumpAndSettle();
    expect(find.text("浅色"), findsOneWidget);
  });
}
