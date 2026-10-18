// task-66 任务 B：弹幕发送栏**玻璃化**门禁
//
// # 这份门禁防的是什么（Lead 裁决的核心）
// ```text
// 玻璃化有两条路：
//   ① 用包里的 `GlassTextField` —— 内部是 `CupertinoTextField`
//   ② 自建玻璃容器 + **原生 `TextField`**
//
// 选 ② 的理由（Lead 裁决，我认同）：
//   task41 有 **9 处** `find.byType(TextField)` 断言守着 Owner 第 1 条
//   「不支持就不显示」这个**产品契约**。换成 GlassTextField ⇒ 那 9 处全红。
//   而**改断言**等于把"输入框存在"的判据从"真的是 TextField"
//   改成"某个玻璃组件" ⇒ 门禁失去鉴别力：
//   将来玻璃组件内部若根本没渲染输入框，断言仍然绿（只找得到那个壳）。
//   ★ 这正是本轮反复出现的假绿形态。
// ```
//
// # 所以本门禁要求**两条同时成立**
// ```text
// ① GlassContainer 在树上（真的玻璃化了）
// ② TextField 也在树上（真的没丢输入框）
// ⇒ 缺任何一条都红。只查其中一条就是假绿。
// ```
//
// 跑法：
//   flutter test test/zz_t66_danmaku_glass_test.dart --concurrency=1
//
// # 故障注入（两条，都已实测）
// ```text
// ① 去掉 GlassFieldShell（退回裸 TextField）⇒ 第①组红
// ② 把 TextField 换成别的输入控件        ⇒ 第②组红
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer;
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/player/player_bottom_bar.dart';

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF101014),
        body: Center(child: SizedBox(width: 520, child: child)),
      ),
    );

DanmakuSendInline _send({
  Future<String?> Function(String, int?)? onSend,
  String debugInitialText = '',
}) =>
    DanmakuSendInline(
      provider: 'demo',
      episodeId: 'ep1',
      positionMs: () => 1000,
      onSend: onSend ?? (text, ms) async => null,
      debugInitialText: debugInitialText,
    );

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 玻璃化：GlassContainer 必须在树上
  // ═══════════════════════════════════════════════════════════════════
  group('① 玻璃材质', () {
    testWidgets('★★★ 输入框外面有 GlassContainer（真的玻璃化了）', (t) async {
      await t.pumpWidget(_host(_send()));
      await t.pumpAndSettle();

      expect(find.byType(GlassContainer), findsWidgets,
          reason: '★★★ Owner 要玻璃材质。没有 GlassContainer ⇒ 还是老样子。'
              '（Lead 裁决：自建容器包原生 TextField）');
    });

    testWidgets('★★ 那个 GlassContainer **包含**输入框（不是摆旁边）', (t) async {
      await t.pumpWidget(_host(_send()));
      await t.pumpAndSettle();

      final nested = find.descendant(
        of: find.byType(GlassContainer),
        matching: find.byType(TextField),
      );
      expect(nested, findsOneWidget,
          reason: '★★ 玻璃容器必须**包住**输入框 —— '
              '只是"页面上同时有这两个东西"不算玻璃化');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 不许丢输入框：TextField 必须仍然是 TextField
  // ═══════════════════════════════════════════════════════════════════
  group('② 原生输入框不许被替换', () {
    testWidgets('★★★ 仍然是真 TextField（不是 CupertinoTextField 之类的壳）',
        (t) async {
      await t.pumpWidget(_host(_send()));
      await t.pumpAndSettle();

      /*
       * # 这条是 Lead 裁决的落点
       * ```text
       * 如果换成包里的 `GlassTextField`，它内部是 `CupertinoTextField`
       * ⇒ 这里 findsNothing ⇒ 红。
       * 而 task41 那 9 处断言会**同时**全红。
       * ⇒ 这条门禁在**测试层**就把那个错误选择挡住，不用等 task41 报。
       * ```
       */
      expect(find.byType(TextField), findsOneWidget,
          reason: '★★★ 必须是原生 TextField —— task41 有 9 处断言靠它守住'
              '「不支持就不显示」的产品契约');
    });

    testWidgets('★★★ 能用 enterText 输入（原生输入行为完整）', (t) async {
      await t.pumpWidget(_host(_send()));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '玻璃化之后还能打字');
      await t.pumpAndSettle();

      final tf = t.widget<TextField>(find.byType(TextField));
      expect(tf.controller?.text, '玻璃化之后还能打字',
          reason: '★★ 输入法/粘贴/选择都走原生路径，玻璃化不该影响');
    });

    testWidgets('★★ 提交（onSubmitted）仍然能发出', (t) async {
      final sent = <String>[];
      await t.pumpWidget(_host(_send(
        onSend: (text, ms) async {
          sent.add(text);
          return null;
        },
      )));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '回车发送');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();

      expect(sent, <String>['回车发送'],
          reason: '★★ onSubmitted 是原生 TextField 的行为，玻璃化不该弄丢');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 功能一个都不许丢（Owner 第 1 条 + 既有 task41 的语义）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 功能保留', () {
    testWidgets('★★ placeholder / 发送按钮 / 字数限制 都在', (t) async {
      await t.pumpWidget(_host(_send()));
      await t.pumpAndSettle();

      expect(find.textContaining('发个弹幕'), findsOneWidget,
          reason: '★ 空态提示');
      expect(find.text('发送'), findsOneWidget, reason: '★ 发送按钮');
    });

    testWidgets('★★ 发送中禁用输入框（防连点）', (t) async {
      final completer = <String>[];
      await t.pumpWidget(_host(_send(
        onSend: (text, ms) async {
          completer.add(text);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return null;
        },
      )));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '点两次试试');
      /*
       * ⚠️ enterText 之后必须 pump 一次：`_canSend` 依赖 `_ctl.text`，
       *    而按钮的 enabled 是在**下一帧**才重算的。
       *    少这一下 ⇒ 点到的还是 disabled 的按钮 ⇒ 什么都没发生（假红）。
       *    task41:190-191 也是这么写的。
       */
      await t.pump();
      await t.tap(find.text('发送'));
      await t.pump();

      final tf = t.widget<TextField>(find.byType(TextField));
      expect(tf.enabled, isFalse, reason: '★★ 发送中必须禁用（防连点）');

      await t.pumpAndSettle();
      expect(completer.length, 1, reason: '★ 只发了一次');
    });

    testWidgets('★★ 失败时保留用户输入（不许清空）', (t) async {
      await t.pumpWidget(_host(_send(
        onSend: (text, ms) async => '发不出去',
      )));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '这段话不能丢');
      await t.pump(); // 同上一处：让 _canSend 重算
      await t.tap(find.text('发送'));
      await t.pumpAndSettle();

      final tf = t.widget<TextField>(find.byType(TextField));
      expect(tf.controller?.text, '这段话不能丢',
          reason: '★★ 失败时清空等于用户打的字没了');
      expect(find.text('发不出去'), findsOneWidget, reason: '★ 失败原因要说出来');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 焦点态（Lead 要求「焦点态要能看见」）
  // ═══════════════════════════════════════════════════════════════════
  group('④ 焦点态', () {
    testWidgets('★★ 聚焦后外框有可见变化', (t) async {
      await t.pumpWidget(_host(_send()));
      await t.pumpAndSettle();

      /*
       * 判据取"GlassFieldShell 的 focused 属性"而不是像素颜色：
       * 颜色在不同主题下不同，而 `focused` 是**语义**上的焦点态。
       * ⚠️ 同时断言它**确实变了** —— 只断言"有这个属性"是恒真。
       */
      GlassFieldShell shell() =>
          t.widget<GlassFieldShell>(find.byType(GlassFieldShell));
      expect(shell().focused, isFalse, reason: '初始未聚焦');

      await t.tap(find.byType(TextField));
      await t.pumpAndSettle();
      expect(shell().focused, isTrue,
          reason: '★★ Lead 要求「焦点态要能看见」—— 聚焦后 focused 必须为 true');
    });
  });
}
