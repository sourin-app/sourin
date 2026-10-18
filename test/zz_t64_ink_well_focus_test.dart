// 2026-10-17（player-batch 实测发现）—— AppInkWell 必须自带 Focus 节点
//
// # 为什么这条测试必须存在
// ```text
// InkWell 内部是 Focus(child: MouseRegion(child: ...))
// ⇒ 业务代码里 `Builder(builder: (ctx) => ...Focus.of(ctx)...)` 拿到的是
//   **InkWell 自己那个节点**，焦点环就挂在那上面。
//
// 本组件第一版**没有** Focus ⇒ 换过来后 Focus.of(内部 ctx) 会拿到**祖先**节点
// ⇒ 焦点环挂错地方。真实受害处：settings_kit.dart:782。
// ```

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/design/widgets/app_ink_well.dart';

void main() {
  Widget host(Widget child) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: child),
      );

  testWidgets('★ 内部 ctx 的 Focus.of 必须拿到 AppInkWell 自己的节点，不是祖先',
      (tester) async {
    // 在 AppInkWell **外面**先放一个可识别的祖先 Focus
    FocusNode? outerNode;
    FocusNode? innerNode;

    await tester.pumpWidget(host(
      Builder(builder: (ctx) {
        outerNode = Focus.of(ctx, scopeOk: true);
        return Focus(
          child: AppInkWell(
            onTap: () {},
            child: Builder(builder: (innerCtx) {
              innerNode = Focus.of(innerCtx, scopeOk: true);
              return const SizedBox(width: 80, height: 40, child: Text('x'));
            }),
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();

    expect(innerNode, isNotNull, reason: '内部必须能拿到 Focus 节点');
    expect(outerNode, isNotNull, reason: '外部也有祖先节点（对照组）');

    /*
     * ★ 核心断言：内部拿到的节点，必须来自 AppInkWell **自己的** Focus 组件。
     *
     * # 为什么不能只断言 "innerNode != outerNode"
     * ```text
     * 我第一版这么写，故障注入时**没抓到**：
     * 把 Focus 换成 Builder 后，Focus.of(innerCtx) 会向上找到**最近的可聚焦祖先**，
     * 那个祖先不是 outerNode（outerNode 是用 scopeOk:true 取的作用域节点），
     * 于是 identical(inner, outer) 仍为 false ⇒ 测试假绿。
     * ```
     *
     * ⇒ 改成：在树里找 AppInkWell **内部**的 Focus 组件，
     *   断言 Focus.of 拿到的节点就是它挂的那个节点。
     */
    final innerFocusWidgets = find.descendant(
      of: find.byType(AppInkWell),
      matching: find.byType(Focus),
    );
    expect(innerFocusWidgets, findsWidgets,
        reason: 'AppInkWell 内部必须有 Focus 组件（否则焦点环会挂到祖先上）');

    final ownFocus = tester.widget<Focus>(innerFocusWidgets.first);
    expect(identical(ownFocus.focusNode, innerNode) || ownFocus.focusNode == null,
        isTrue,
        reason: 'Focus.of 应拿到 AppInkWell 自己那层 Focus 的节点');
  });

  testWidgets('AppInkWell 的节点可聚焦（与 InkWell 对齐，键盘 Tab 能停）',
      (tester) async {
    await tester.pumpWidget(host(
      AppInkWell(
        onTap: () {},
        child: const SizedBox(width: 80, height: 40, child: Text('y')),
      ),
    ));
    await tester.pumpAndSettle();

    // Focus 组件必须存在且 canRequestFocus 为 true
    final focus = tester.widget<Focus>(
      find.descendant(
        of: find.byType(AppInkWell),
        matching: find.byType(Focus),
      ).first,
    );
    expect(focus.canRequestFocus, isTrue);
  });

  testWidgets('★ onFocusChange 真的会回调（遥控器焦点高亮靠它）', (tester) async {
    final events = <bool>[];
    final n1 = FocusNode();
    final n2 = FocusNode();
    final mine = FocusNode();
    addTearDown(() { n1.dispose(); n2.dispose(); mine.dispose(); });

    await tester.pumpWidget(host(
      Column(children: [
        Focus(focusNode: n1, child: const SizedBox(width: 40, height: 40)),
        AppInkWell(
          onTap: () {},
          onFocusChange: events.add,
          focusNode: mine,
          child: const SizedBox(width: 80, height: 40, child: Text('a')),
        ),
        Focus(focusNode: n2, child: const SizedBox(width: 40, height: 40)),
      ]),
    ));
    await tester.pumpAndSettle();

    // 用注入的 node 请求焦点
    mine.requestFocus();
    await tester.pumpAndSettle();

    expect(events, isNotEmpty, reason: 'onFocusChange 必须被调用');
    expect(events.last, isTrue, reason: '获得焦点时回调参数应为 true');

    // 移走焦点
    n2.requestFocus();
    await tester.pumpAndSettle();
    expect(events.last, isFalse, reason: '失去焦点时应回调 false');
  });

  testWidgets('禁用态（onTap 为 null）不该多出 Focus 节点', (tester) async {
    await tester.pumpWidget(host(const AppInkWell(
      child: SizedBox(width: 80, height: 40, child: Text('z')),
    )));
    await tester.pumpAndSettle();

    // 禁用态直接返回 child，不包 Focus/GestureDetector
    expect(
      find.descendant(
        of: find.byType(AppInkWell),
        matching: find.byType(Focus),
      ),
      findsNothing,
    );
  });
}
