// ═══════════════════════════════════════════════════════════════════════
//  task-41：弹幕发送入口（Owner 第 2 条后半句）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守的是「显隐判据」+「失败必须说清」
// ```text
// ① capabilities.danmakuSend = false / 未声明 ⇒ 入口**不出现**
// ② capabilities.danmakuSend = true            ⇒ 入口**出现**
// ③ 插件没实现 danmakuSend() ⇒ 必须给**可读的错误**，不许静默
// ```
//
// # ★★★ 为什么断言用 find.text / find.byIcon，不用 find.byType(按钮类)
// ```text
// 本项目踩过这个坑：换成 AppTextButton 之后，
//   expect(find.byType(TextButton), findsNothing)  会**静默通过**
// —— 按钮明明在，只是换了个类。
// ⇒ 断言**用户能看见的东西**（文字 / 图标），与实现类解耦。
// ```
//
// # ★ 显隐判据的测试为什么测「宿主算出来的布尔」而不是直接搭 PlayerPage
// ```text
// PlayerPage 的构造需要 media_kit（libmpv-2.dll），在 flutter_tester 里
// 会**偶发 native 崩溃**（见 test/live_referer_onwire_test.dart 顶部那段证据）。
// ⇒ 本文件把「判据」抽成可单独调用的形态来测，宿主接线由源码契约断言守。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF101014),
        body: Center(child: child),
      ),
    );

/// 造一份带指定 danmakuSend 的源清单，走**真实**的 Capabilities 解析
List<ProviderManifest> _providers({required bool? danmakuSend}) {
  return [
    ProviderManifest.fromJson({
      'id': 'demo',
      'name': '演示源',
      'capabilities': {
        'danmaku': true,
        // ★ null 表示「未声明」—— 必须与「声明为 false」走同一条路
        if (danmakuSend != null) 'danmaku_send': danmakuSend,
      },
    }),
  ];
}

/// ★★★ 判据**必须调宿主那份实现**，不许在这里重写一遍
///
/// # 为什么（这条是踩坑之后改的）
/// ```text
/// 第一版测试自己重写了一遍同样的逻辑：
///   bool canSendFor(...) => hit?.capabilities.danmakuSend ?? false;
///
/// 然后做故障注入（把宿主的判据写死成 true）——
/// **一条测试都没变红**。
/// 因为测试测的是自己那份副本，与宿主改没改**完全无关**。
/// ⇒ 那是同义反复，不是验证。
///
/// 现在直接调 danmakuSendAllowed（宿主用的**同一个**函数）：
/// 宿主改错 ⇒ 这里跟着错 ⇒ 测试红。这才叫验证。
/// ```
bool canSendFor(List<ProviderManifest> list, String id) =>
    danmakuSendAllowed(list, id);

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 判据：false / 未声明 ⇒ 不出现
  // ═══════════════════════════════════════════════════════════════════

  test('★★★ danmakuSend=false ⇒ 判据为 false（入口不出现）', () {
    final list = _providers(danmakuSend: false);
    expect(canSendFor(list, 'demo'), isFalse,
        reason: '★★ 声明为 false 就是不能发');
  });

  test('★★★ danmakuSend 未声明 ⇒ 判据为 false（入口不出现）', () {
    final list = _providers(danmakuSend: null);
    expect(canSendFor(list, 'demo'), isFalse,
        reason: '★★ 未声明必须当成不能发 —— 不能因为「没说不行」就当行');
  });

  test('★★★ danmakuSend=true ⇒ 判据为 true（入口出现）', () {
    final list = _providers(danmakuSend: true);
    expect(canSendFor(list, 'demo'), isTrue,
        reason: '★★ 声明为 true 才显示入口');
  });

  test('★★ 源不存在 ⇒ 判据为 false（不崩）', () {
    final list = _providers(danmakuSend: true);
    expect(canSendFor(list, 'nope'), isFalse,
        reason: '★ 查不到源要当作不能发，不是抛异常');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 发送栏本体：用户能看见的东西
  // ═══════════════════════════════════════════════════════════════════

  testWidgets('★★★ 发送栏出现时，用户能看到输入框和「发送」', (t) async {
    await t.pumpWidget(_host(DanmakuSendBar(
      provider: 'demo',
      episodeId: 'ep1',
      onSend: (text, ms) async => null,
    )));
    await t.pumpAndSettle();

    // ★ 跨实现断言：找文字 / 图标，不找具体按钮类
    expect(find.text('发送'), findsOneWidget,
        reason: '★★ 发送按钮必须能被用户看见');
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget,
        reason: '★ 入口图标在');
    expect(find.byType(TextField), findsOneWidget,
        reason: '★ 必须有输入框');
    expect(find.text('发条弹幕…'), findsOneWidget,
        reason: '★ 空态有提示文案');
  });

  testWidgets('★★ 空输入时按钮不可点（防误发空弹幕）', (t) async {
    var called = 0;
    await t.pumpWidget(_host(DanmakuSendBar(
      provider: 'demo',
      episodeId: 'ep1',
      onSend: (text, ms) async {
        called++;
        return null;
      },
    )));
    await t.pumpAndSettle();

    await t.tap(find.text('发送'));
    await t.pumpAndSettle();
    expect(called, 0,
        reason: '★★ 没输入内容就点发送，不该真的发出去');
  });

  testWidgets('★★★ 输入后点发送 ⇒ 真的把文本交出去', (t) async {
    String? got;
    int? gotMs;
    await t.pumpWidget(_host(DanmakuSendBar(
      provider: 'demo',
      episodeId: 'ep1',
      positionMs: () => 12345,
      onSend: (text, ms) async {
        got = text;
        gotMs = ms;
        return null;
      },
    )));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), '  测试弹幕  ');
    await t.pump();
    await t.tap(find.text('发送'));
    await t.pumpAndSettle();

    expect(got, '测试弹幕',
        reason: '★★ 交给宿主的必须是**去空白**后的正文');
    expect(gotMs, 12345,
        reason: '★★ 必须把当前进度一起交出去（按进度发的站点要用）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 失败必须说清（不许静默）
  // ═══════════════════════════════════════════════════════════════════

  testWidgets('★★★ 发送失败 ⇒ 错误原因显示出来，且输入框内容**保留**', (t) async {
    await t.pumpWidget(_host(DanmakuSendBar(
      provider: 'demo',
      episodeId: 'ep1',
      onSend: (text, ms) async => '这个源不支持发送弹幕',
    )));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), '发不出去的弹幕');
    await t.pump();
    await t.tap(find.text('发送'));
    await t.pumpAndSettle();

    expect(find.text('这个源不支持发送弹幕'), findsOneWidget,
        reason: '★★★ 失败原因必须显示 —— 静默失败是这条功能最坏的形态');
    final tf = t.widget<TextField>(find.byType(TextField));
    expect(tf.controller?.text, '发不出去的弹幕',
        reason: '★★ 失败后不许清空 —— 用户辛苦打的字不能没了');
  });

  testWidgets('★★ 成功后清空输入框', (t) async {
    await t.pumpWidget(_host(DanmakuSendBar(
      provider: 'demo',
      episodeId: 'ep1',
      onSend: (text, ms) async => null,
    )));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), '会成功的弹幕');
    await t.pump();
    await t.tap(find.text('发送'));
    await t.pumpAndSettle();

    final tf = t.widget<TextField>(find.byType(TextField));
    expect(tf.controller?.text, '',
        reason: '★ 成功后清空，方便接着发下一条');
  });

  testWidgets('★★ onSend 抛异常时也不静默（兜底）', (t) async {
    await t.pumpWidget(_host(DanmakuSendBar(
      provider: 'demo',
      episodeId: 'ep1',
      onSend: (text, ms) async => throw StateError('boom'),
    )));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), 'x');
    await t.pump();
    await t.tap(find.text('发送'));
    await t.pumpAndSettle();

    expect(find.textContaining('发送失败'), findsOneWidget,
        reason: '★★ 兜底也不能静默 —— 否则用户以为发出去了');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ ★★★ 2026-10-17（Owner 第 9 条 + Lead 定案）
  //      不支持发送的源 ⇒ **置灰但可见**，且原因必须可读
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 这一组守的是"两次改判"之后的口径
  // ```text
  // 第一版（改前）：canSend=false ⇒ 整条不渲染
  //   ✗ Owner 第 9 条：「并没有发送弹幕的入口,这个需要修复」
  //     入口消失 ⇒ 用户连这个能力存在都不知道
  //
  // 第二版：入口常驻，但点了才报「这个源不支持发送弹幕」
  //   ✗ Lead 否掉：每次点都撞一次墙，体验是负的
  //
  // 现在：入口常驻 + **置灰点不动** + **一行原因说清为什么**
  //   ✓ 用户知道有这能力，也知道现在做不到，且不撞墙
  // ```
  group('④ 不支持发送 ⇒ 置灰但可见（不是消失、也不是点了报错）', () {
    const reason = '这个源没有开放发送弹幕能力，换一个源再试';

    testWidgets('★★★ 控件**存在**（不是整条消失）', (t) async {
      await t.pumpWidget(_host(const DanmakuSendBar(
        provider: 'demo',
        episodeId: 'ep1',
        onSend: _neverSend,
        canSend: false,
        disabledReason: reason,
      )));
      await t.pumpAndSettle();

      expect(find.byType(DanmakuSendBar), findsOneWidget,
          reason: '★★★ Owner 第 9 条要的就是"入口在" —— 整条消失等于没修');
      expect(find.byType(TextField), findsOneWidget,
          reason: '★ 输入区还在（看得出来这里有发送功能）');
    });

    testWidgets('★★★ 输入框与「发送」都点不动（不撞墙）', (t) async {
      var called = 0;
      await t.pumpWidget(_host(DanmakuSendBar(
        provider: 'demo',
        episodeId: 'ep1',
        canSend: false,
        disabledReason: reason,
        /*
         * ★★★ 必须先塞一行文字 —— 否则这条用例是**假绿**（故障注入抓出来的）：
         * 输入框空着时 `_canSend` 本来就是 false（因为"没内容"），
         * 把 canSend 从判据里拿掉也照样绿。
         * 只有带内容时，绿才证明"拦住它的是 canSend"。
         */
        debugInitialText: '这行字不该被发出去',
        onSend: (text, ms) async {
          called++;
          return null;
        },
      )));
      await t.pumpAndSettle();

      // 输入框 disabled ⇒ 打不进字
      final tf = t.widget<TextField>(find.byType(TextField));
      expect(tf.enabled, isFalse,
          reason: '★★ 只禁按钮而让人白打一行字，是另一种浪费');
      expect(tf.controller?.text, '这行字不该被发出去',
          reason: '★ 前置条件：框里**确实有内容**（见 debugInitialText 的注释）');

      /*
       * ★★★ 直接断言按钮的 `onPressed == null`，**不靠"点了没反应"**。
       *
       * # 为什么（故障注入抓出来的）
       * ```text
       * 第一版只写 `tap(...)` 然后 `expect(called, 0)` —— 假绿：
       * 把 `canSend` 从判据里拿掉（`_canSend` 只看"有没有输入文字"），
       * 那条用例**照样绿**，因为它没输入文字 ⇒ `_canSend` 本来就 false。
       * ⇒ 必须①先塞内容 ②直接问控件"你能不能点"。
       * ```
       */
      final btn = t.widget<TextButton>(
        find.widgetWithText(TextButton, '发送'),
      );
      expect(btn.onPressed, isNull,
          reason: '★★★ 置灰态按钮的 onPressed 必须是 null —— '
              '只灰不禁会让用户点了撞墙，而"撞了才报错"正是 Lead 否掉的那版');
      await t.tap(find.text('发送'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(called, 0,
          reason: '★★★ 置灰态点发送**绝不能**真的发出去，也不该报错 —— 就是点不动');
    });

    testWidgets('★★★ 原因文案**可读**（不能只灰着不说）', (t) async {
      await t.pumpWidget(_host(const DanmakuSendBar(
        provider: 'demo',
        episodeId: 'ep1',
        onSend: _neverSend,
        canSend: false,
        disabledReason: reason,
      )));
      await t.pumpAndSettle();

      expect(find.textContaining('没有开放发送弹幕'), findsOneWidget,
          reason: '★★★ Lead 要求：置灰状态下**必须能看到原因**。'
              'findOneWidget 同时钉住"别重复两遍"（hint 用短句，长句只在这里）');
      expect(find.textContaining('换一个源'), findsOneWidget,
          reason: '★★ 文案要指出下一步 —— 只说"不支持"等于把问题丢回给用户');
      expect(find.byIcon(AppIcons.info_outline), findsOneWidget,
          reason: '★ 有个信息图标，不是凭空一行灰字');
    });

    testWidgets('★★ 支持发送时**正常可用**（这个改动没弄坏正常路径）', (t) async {
      String? got;
      await t.pumpWidget(_host(DanmakuSendBar(
        provider: 'demo',
        episodeId: 'ep1',
        canSend: true,
        onSend: (text, ms) async {
          got = text;
          return null;
        },
      )));
      await t.pumpAndSettle();

      final tf = t.widget<TextField>(find.byType(TextField));
      expect(tf.enabled, isTrue, reason: '★★ 能发的时候输入框必须能用');

      await t.enterText(find.byType(TextField), '正常发一条');
      await t.pump();
      await t.tap(find.text('发送'));
      await t.pumpAndSettle();

      expect(got, '正常发一条', reason: '★★ 正常路径一个字都没受影响');
      expect(find.textContaining('没有开放发送弹幕'), findsNothing,
          reason: '★ 能发的时候不该显示那句灰字（噪音）');
    });

    testWidgets('★★ 空 disabledReason 时也有兜底文案（不出现空行）', (t) async {
      await t.pumpWidget(_host(const DanmakuSendBar(
        provider: 'demo',
        episodeId: 'ep1',
        onSend: _neverSend,
        canSend: false,
        // 故意不给原因
      )));
      await t.pumpAndSettle();

      expect(find.textContaining('不支持发送弹幕'), findsWidgets,
          reason: '★ 宿主漏传原因也不能出现一行空白 —— 那比没提示更糟');
    });
  });
}

/// 一个"永远不该被调用"的发送动作（置灰态用例用）
///
/// ⚠️ 定义成顶层函数是为了能用在 `const` 构造里。
Future<String?> _neverSend(String text, int? ms) async {
  throw StateError('置灰态不该触发发送：$text@$ms');
}