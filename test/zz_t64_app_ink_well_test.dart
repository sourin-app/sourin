// 2026-10-17 Owner 第 4/8/9 条：AppInkWell 取代 InkWell 的行为验证
//
// 钉住的判据（这些是 InkWell 有、而自绘容易漏的）：
//   1 onTap 非空 ⇒ 点击真的触发
//   2 onTap 为 null ⇒ 不触发（禁用态），且不抢手势
//   3 enabled=false ⇒ 即使 onTap 非空也不触发
//   4 按下时有视觉反馈（高亮层出现）
//   5 抬起后高亮消失
//   6 ★ 不需要祖先 Material（这是摘掉 material_ui 的关键）

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/design/widgets/app_ink_well.dart';
import 'package:sourin_spike/ui/tokens.dart';

void main() {
  Widget host(Widget child) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: child),
      );

  testWidgets('1 onTap 非空 => 点击真的触发', (tester) async {
    var hits = 0;
    await tester.pumpWidget(host(AppInkWell(
      onTap: () => hits++,
      child: const SizedBox(width: 100, height: 40, child: Text('x')),
    )));

    await tester.tap(find.byType(AppInkWell));
    await tester.pumpAndSettle();
    expect(hits, 1);
  });

  testWidgets('2 onTap 为 null => 不触发（禁用态）', (tester) async {
    await tester.pumpWidget(host(const AppInkWell(
      child: SizedBox(width: 100, height: 40, child: Text('x')),
    )));

    // 禁用态直接返回 child，连 GestureDetector 都没有
    expect(find.byType(GestureDetector), findsNothing,
        reason: 'onTap 为 null 时不该包 GestureDetector，免得抢手势');
    await tester.tap(find.text('x'), warnIfMissed: false);
    await tester.pumpAndSettle();
    // 没有崩溃、没有回调就是通过（这里没有回调可断言，验的是不抢手势）
  });

  testWidgets('3 enabled=false => 即使 onTap 非空也不触发', (tester) async {
    var hits = 0;
    await tester.pumpWidget(host(AppInkWell(
      onTap: () => hits++,
      enabled: false,
      child: const SizedBox(width: 100, height: 40, child: Text('x')),
    )));

    await tester.tap(find.text('x'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(hits, 0);
  });

  testWidgets('4+5 按下出现高亮、抬起消失', (tester) async {
    await tester.pumpWidget(host(AppInkWell(
      onTap: () {},
      borderRadius: Radii.rMd,
      child: const SizedBox(width: 100, height: 40, child: Text('x')),
    )));

    // 找高亮层（AnimatedContainer 里那个 Positioned.fill 下的）
    AnimatedContainer highlight() => tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byType(AppInkWell),
            matching: find.byType(AnimatedContainer),
          ),
        );

    BoxDecoration deco() => highlight().decoration! as BoxDecoration;

    // 初始：透明
    expect(deco().color, const Color(0x00000000));

    // 按下：出现高亮
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('x')));
    await tester.pump(const Duration(milliseconds: 10));
    expect(deco().color, const Color(0x14000000),
        reason: '按下必须有可见高亮，否则用户不知道点到了');

    // 抬起：归零
    await gesture.up();
    await tester.pumpAndSettle();
    expect(deco().color, const Color(0x00000000));
  });

  testWidgets('6 ★ 不需要祖先 Material（摘 material_ui 的关键）', (tester) async {
    var hits = 0;
    // 故意只给 Directionality，**不给 Material**
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: AppInkWell(
          onTap: () => hits++,
          child: const SizedBox(width: 80, height: 40, child: Text('y')),
        ),
      ),
    ));

    await tester.tap(find.text('y'));
    await tester.pumpAndSettle();
    expect(hits, 1,
        reason: '没有祖先 Material 也必须能点 —— InkWell 在同样条件下会抛错/不显示水波');
  });
}
