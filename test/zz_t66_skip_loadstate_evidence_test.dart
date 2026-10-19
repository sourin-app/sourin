// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 故意让自己红的**证据**用例（原 zz_t66_skip_loadstate_review_test 的 A）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独成一个文件
//
// ```text
// 这条用例**故意**留下一个 pending 的 FakeTimer，让 test 框架在收尾时打出：
//
//   Pending timers:
//   Timer (duration: 0:00:10.000000, periodic: false)
//   A Timer is still pending even after the widget tree was disposed.
//
// 那个 10.000000 秒就是 skip_marker_dialog.dart:733 的
//   static const Duration _kLoadTimeout = Duration(seconds: 10);
// 而它被创建成了 FakeTimer ⇒ 挂在 fake clock 上；
// 本测试预算 = 12 × 250ms = 3 秒 ⇒ 即便 pump 也到不了 10 秒
// ⇒ TimeoutException 永不触发 ⇒ _LoadState 永远是 loading。
// ```
//
// ★ **为什么不留在主文件里**：`@Tags` 在 package:test 里**只能挂 library**，
//   不能挂单个用例。留在主文件就要给整条文件打 tag
//   ⇒ A2 / ② / ③ 三条**能正常绿**的用例也一起退出默认套件
//   ⇒ 正是 MEMORY 里那条坑「整文件 skip 让断言过时永远暴露不出来」。
//
// ★ **为什么不改成 skip / markTestSkipped**：
//   `~1` 比 `-1` 更隐蔽 —— 没人会去看它是「故意跳过」还是「忘了跑」。
//
// # 怎么跑
//
// ```text
// 默认（不跑）：flutter test                    ← 读数干净
// 显式复现：  flutter test --tags evidence
// ```
//
// 决策笔记：
// .agents/notes/implemented/testing/2026-10-19-evidence-gate-that-is-red-on-purpose.md

@TestOn('vm')
@Tags(['evidence'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Builder(builder: (_) => child)));

/// 数一数页面上三类东西各出现几个（用来区分「停在 loading」与「读失败了」）
String _probeCounts(WidgetTester t) {
  String n(Finder f) => '${f.evaluate().length}';
  return 'timeline=${n(find.byType(SkipTimeline))} '
      '失败文案=${n(find.textContaining('读取跳过点失败'))} '
      '转圈=${n(find.byType(CircularProgressIndicator))}';
}

void main() {
  testWidgets('★★★ A：只 pump、不注入 ⇒ 停在 loading（那个 10 秒定时器没被推进）',
      (t) async {
    // ★★★ 这条测试**故意**留下 pending 的 fake 定时器，而且**故意让它红**。
    //   红的理由不是"断言不通过"，而是 test 框架在收尾时打出那段证据文字。
    //
    // ★ 本条是 `zz_t66_skip_loadstate_review_test.dart` 的 A2 的**对照组**：
    //   A2 只多了一个 `t.runAsync`（让真实事件循环跑）就能看到失败文案。
    //   A 与 A2 的**唯一**差别就是这个 ⇒ 它证明了主张成立。
    await t.pumpWidget(_host(const SkipMarkerDialog(
      provider: 'demo',
      id: 'reviewA',
      title: 'probe',
      streamUrl: '',
      duration: Duration(minutes: 47, seconds: 6),
    )));
    // 预算 3 秒 —— 远小于 _kLoadTimeout 的 10 秒
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 250));
      while (t.takeException() != null) {}
    }
    // ignore: avoid_print
    print('REVIEW|A|${_probeCounts(t)}');

    // ★★★ 判据只钉**一件事**：失败文案**没有**出现。
    //
    //   A  : 失败文案=0     ← 真 FFI 异常在**真实时间**上，fake clock 推不到
    //   A2 : 失败文案=1     ← 只多一个 t.runAsync 就能看到
    //   ⇒ 这个差值就是本文件要证明的主张。
    //
    // ⚠️ **不要**在这里断「转圈可见」：我第一版写了那条，被实测推翻 ——
    //   产品用 `AppLoading` 而不是 `CircularProgressIndicator`
    //   ⇒ 那条断言是我编的，且它让失败原因从「pending timer」
    //     变成「断言不通过」，**证据就被我自己的 bug 盖住了**。
    //
    // ⚠️ 也**不要**断「时间轴不挂载」：`SkipTimeline` 在两种情形下
    //   都不挂载（实测 A 与 A2 的 timeline 都是 0）⇒ 它区分不出任何东西。
    expect(
      find.textContaining('读取跳过点失败'),
      findsNothing,
      reason: '★★ 本条的**唯一**主张：只 pump 时还没走到失败分支。\n'
          '若这条红，说明真 FFI 异常**已经在**fake clock 上投递了，\n'
          '那么本文件与 A2 的差值前提就不成立，A2 也就不构成对照。',
    );
    // ★ 本文件**不 suppress** 那个 pending timer —— 真正的证据是框架收尾时
    //   打出「A Timer is still pending…（duration: 0:00:10.000000）」。
    await t.pumpWidget(_host(const SizedBox.shrink()));
    await t.pump(const Duration(milliseconds: 50));
  });
}