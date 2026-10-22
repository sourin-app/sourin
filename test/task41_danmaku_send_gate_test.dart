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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_more_menu.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';
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
    await t.pumpWidget(_host(DanmakuSendInline(
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
    expect(find.text('发个弹幕…'), findsOneWidget,
        reason: '★ 空态有提示文案');
  });

  testWidgets('★★ 空输入时按钮不可点（防误发空弹幕）', (t) async {
    var called = 0;
    await t.pumpWidget(_host(DanmakuSendInline(
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
    await t.pumpWidget(_host(DanmakuSendInline(
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
    await t.pumpWidget(_host(DanmakuSendInline(
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
    await t.pumpWidget(_host(DanmakuSendInline(
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
    await t.pumpWidget(_host(DanmakuSendInline(
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
  /*
   * ★★★ 2026-10-18（第 66 轮 Owner 第 1 条）：口径**已反转**
   *
   * # Owner 原话
   * ```text
   * > 弹幕那个发送不要搞一个悬浮,就跟其他网站一样的设计,下面操作栏加一个
   * > 输入框,然后是发送弹幕的,随弹幕能力开关显示 也随此网站是否支持弹幕
   * > 能力显示.不支持就不显示
   * ```
   * Owner 2026-10-18 复核确认「按这轮优先」，且「弹幕总开关关闭时也不显示」。
   *
   * # 三代口径的演进（这一组的断言必须跟着走）
   * ```text
   * 第一版：不支持 ⇒ 整条不渲染
   *        ✗ Owner 第 9 条：「并没有发送弹幕的入口,这个需要修复」
   * 第二版：常驻 + 点了报错
   *        ✗ Lead 否掉：每次点都撞墙
   * 第三版（第 65 轮）：常驻 + 置灰点不动 + 一行原因
   *        ✓ 当时认为最优
   * 第四版（本轮，Owner 拍板）：**不支持就不显示**
   *        ⇒ canSend / disabledReason 两个字段删除
   * ```
   *
   * ⚠️ 所以原来那一组「置灰但可见」的断言**全部作废**。
   *    按仓库纪律：行为有意改变时改断言**新行为**，
   *    且**新断言在旧行为下必须变红**（证明行为真的变了，不是断言跟着改）。
   *    验证方式：把 `canSend` 参数加回去、让它渲染出置灰态 ⇒
   *    下面这三条必须红（`findsNothing` 会变成 findsOneWidget 而失败）。
   */
  group('④ 不支持发送 ⇒ 整条**不渲染**（第 66 轮口径，旧口径已作废）', () {
    testWidgets('★★★ 判据为假时宿主传 null ⇒ 底栏里没有输入框、没有「发送」',
        (t) async {
      /*
       * ★ 走**真实接线路径**：把 `danmakuSend: null` 传给底栏本体，
       *   而不是只测那个小组件 —— 否则"宿主算错判据"这类缺陷测不出来。
       */
      await t.pumpWidget(_host(const _BottomBarHarness(danmakuSend: null)));
      await t.pumpAndSettle();

      expect(find.byType(TextField), findsNothing,
          reason: '★★★ 不支持 ⇒ 输入框不该出现（Owner：不支持就不显示）');
      expect(find.text('发送'), findsNothing,
          reason: '★★★ 发送按钮也不该出现');
      expect(find.textContaining('发个弹幕'), findsNothing,
          reason: '★ 连 placeholder 都不该有 —— 整条不存在');
    });

    testWidgets('★★ 判据为真时正常出现（这个改动没弄坏正常路径）', (t) async {
      await t.pumpWidget(_host(_BottomBarHarness(
        danmakuSend: DanmakuSendData(
          provider: 'demo',
          episodeId: 'ep1',
          onSend: (text, ms) async => null,
        ),
      )));
      await t.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget,
          reason: '★★ 能发的时候必须有输入框');
      expect(find.text('发送'), findsOneWidget,
          reason: '★★ 能发的时候必须有发送按钮');
    });

    testWidgets('★★★ 源码里**没有** canSend / disabledReason 这两个逃生口',
        (t) async {
      /*
       * ★ 反向断言：源码里不许再出现 `canSend:` / `disabledReason:`
       *   这两处传参。它们一旦回来，说明有人把"置灰可见"那版又接回去了，
       *   而 Owner 已明确否掉它。
       *
       * ⚠️ 判在**剥注释后**的文本上 —— 否则注释里提一句就会假红。
       */
      final src = File('lib/ui/player/player_bottom_bar.dart')
          .readAsStringSync();
      final code = src
          .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
          .replaceAll(RegExp(r'//.*'), '');
      expect(code.contains('canSend:'),
          isFalse,
          reason: '★★★ 不许再传 canSend —— 那是第 65 轮"置灰可见"的入口，已作废');
      expect(code.contains('disabledReason:'),
          isFalse,
          reason: '★★★ 同理，disabledReason 也不该再出现');
    });
  });
}

/// 把 `danmakuSend` 直接喂给底栏本体的最小宿主
///
/// # 为什么不搭整个 PlayerPage
/// ```text
/// PlayerPage 构造需要 media_kit（libmpv-2.dll），在 flutter_tester 里
/// 会偶发 native 崩溃（见本文件顶部那段证据）。
/// ⇒ 测「底栏收到 null / 非 null 时的渲染」只需要底栏本体。
/// ```
class _BottomBarHarness extends StatelessWidget {
  const _BottomBarHarness({required this.danmakuSend});

  final DanmakuSendData? danmakuSend;

  @override
  Widget build(BuildContext context) => Stack(
        /*
         * ★ 必须套 Stack：`PlayerBottomBar.build` 返回的是 `Positioned`
         *   （它本来就只能挂在播放页那个整屏 Stack 里）。
         *   直接放进 Center 会抛 ParentDataWidget 断言 —— 这不是产品缺陷，
         *   是测试宿主搭错了。
         */
        children: [
          PlayerBottomBar(
            controller: PopoverController(),
            playing: true,
            positionListenable: ValueNotifier(Duration.zero),
            duration: const Duration(minutes: 20),
            isLive: false,
            rate: 1,
            volume: 100,
            muted: false,
            fullscreen: false,
            onTogglePlay: () {},
            onSeek: (_) {},
            onVolume: (_) {},
            onToggleMute: () {},
            onRate: (_) {},
            onToggleFullscreen: () {},
            onEpisodes: () {},
            hasEpisodes: false,
            showEpisodeNav: false,
            onNext: () {},
            hasNext: false,
            more: const PlayerMoreMenuData(groups: <MoreMenuGroup>[]),
            danmakuSend: danmakuSend,
          ),
        ],
      );
}
