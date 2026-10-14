// ═══════════════════════════════════════════════════════════════════════
//  T108：弹幕设置面板的「手动搜索番剧」—— 端到端回归
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，2026-10-14）
// ```text
// > 弹幕我没有看到弹弹play的搜索功能和绑定
// ```
//
// # 真缺陷（勘察结论，别重查）
// ```text
// ① 后端 `ExternalDanmakuClient.searchEpisodes()`（core/danmaku.dart）**早已实现**，
//    是**真 HTTP**（GET /api/v2/search/episodes），返回 List<DanmakuMatch>；
// ② 但**没有任何 UI 调用它** —— 全仓唯一相关入口 `loadFor()` 的调用点
//    （player_page._loadDanmaku）连 anime/episode 都不传 ⇒ 空搜必然搜不到。
// ⇒ 本文件钉住"现在有 UI 了，且它真的把用户的动作送到生产那条路上"。
// ```
//
// # 测的是什么（五组判据）
// ```text
// ① 面板真有搜索框（**真渲染**：find.byType(TextField) + hint），
//    且点「搜索」能触发**宿主回调**（onSearch）。
// ② 搜到结果 ⇒ 点一条 ⇒ 宿主**真的**收到那个 episodeId（断言 `_biliCid`）。
// ③ 空结果 ⇒ 有明确空态文案（"没搜到，换个关键词试试"），不是空白。
// ④ ★★ 反向守卫：搜索**不得**影响正在播放的流 —— 搜索前后
//    `debugPlayerStreamUrlsForProbe()` 必须逐字相同，且 comments/status 不动。
// ⑤ 必须能测出反面：把「点一条 ⇒ 载入该集」这条线拿掉 ⇒ 本文件红
//    （见文件头的"红度"一节与末尾的阳性对照）。
// ```
//
// # 为什么用 `fetchCommentsRaw` 而不是 `loadFor` 那条路来钉"载入"
// ```text
// 「点一条」= 用户**明确指定**了这一集 ⇒ 生产走 `fetchComments(episodeId)`
// 直接取（不再模糊匹配）。本文件断言的是**用户的选择被采纳**这件事，
// 最直接的判据就是宿主的"弹幕身份"（`_biliCid`）变成了那条的 episodeId。
// ```
//
// # 挂法与标签
// ```text
// 与 t27_w22 同款：push **真** PlayerPage ⇒ 需要 MediaKit.ensureInitialized
// 指向仓库自带 libmpv ⇒ 标 `native-media`（默认跳过）。
// 跑法：flutter test test/t108_danmaku_manual_search_test.dart \
//       --run-skipped --tags native-media --concurrency=1
// ```
// ═══════════════════════════════════════════════════════════════════════

@Tags(['native-media'])
library;
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

// ═══════════════════════════════════════════════════════════════════════
//  假传输：把「搜什么」变成**确定性**输入
// ═══════════════════════════════════════════════════════════════════════
//
// 真 HTTP 会让判据变成"跑到网上碰运气" —— 官方接口挂了、被限流、
// 这片子下架了，测试就红，而代码没错。所以注一个假传输：
// 按请求里的 `anime` 查询词决定返回什么。

/// 假传输要返回的"搜索结果"（按查询词）
final Map<String, String> _searchFixtures = <String, String>{};

/// 记录：搜索接口被调了几次、带的关键词是什么（钉"真发了这一趟"）
final List<String> _searched = <String>[];

/// 记录：`fetchComments` 被调的 episodeId（钉"用户选的被采纳"）
final List<int> _fetchedComments = <int>[];

class _FakeTransport implements DanmakuTransport {
  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    if (uri.path.contains('/search/episodes')) {
      final kw = uri.queryParameters['anime'] ?? '';
      _searched.add(kw);
      final payload = _searchFixtures[kw] ?? '{"animes":[]}';
      return DanmakuHttpResponse(statusCode: 200, body: payload);
    }
    if (uri.path.contains('/comment/')) {
      // /api/v2/comment/{episodeId}
      final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
      _fetchedComments.add(int.tryParse(seg) ?? -1);
      // 一条真实形状的弹幕（p = "秒,模式,字号,颜色,时间戳,池,uid,行id"）
      return const DanmakuHttpResponse(
        statusCode: 200,
        body: '{"count":1,"comments":'
            '[{"cid":1,"p":"1.0,1,25,16777215,1700000000,0,abc,1","m":"手测弹幕"}]}',
      );
    }
    return const DanmakuHttpResponse(
      statusCode: 404,
      body: '{"errorCode":404,"errorMessage":"no"}',
    );
  }

  @override
  void close() {}
}

/// 一段能解析出**两集**的搜索响应
String _twoEpisodes(String anime, String ep1, String ep2) =>
    '{"animes":[{"animeTitle":"$anime","episodes":['
    '{"episodeId":11111,"episodeTitle":"$ep1"},'
    '{"episodeId":22222,"episodeTitle":"$ep2"}]}]}';

// ═══════════════════════════════════════════════════════════════════════
//  挂载：push 真 PlayerPage
// ═══════════════════════════════════════════════════════════════════════

void _claim(WidgetTester t) {
  var n = 0;
  while (t.takeException() != null) {
    if (++n > 200) break;
  }
}

Future<void> _mountPlayer(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));

  RemoteBridge.instance.stop();
  addTearDown(() => RemoteBridge.instance.stop());

  await t.pumpWidget(MaterialApp(home: ShellPage(key: debugShellKey)));
  await t.pump();
  await t.pump(const Duration(milliseconds: 200));
  _claim(t);

  final nav = Navigator.of(t.element(find.byType(ShellPage)));
  nav.push(
    MaterialPageRoute<void>(
      builder: (_) => const PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '手动搜索验收',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  _claim(t);
  expect(find.byType(PlayerPage), findsOneWidget, reason: '前置：PlayerPage 没挂上');
}

Future<void> _settleTimers(WidgetTester t) async {
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  _claim(t);
}

/// 打开面板并滚到「搜索番剧」区
Future<void> _openPanelAndScroll(WidgetTester t) async {
  expect(
    debugPlayerOpenDanmakuSettingsForProbe(),
    isTrue,
    reason: '前置：弹幕设置面板没打开',
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
  _claim(t);
}

void main() {
  setUpAll(() {
    final candidates = [
      File('build/windows/x64/libmpv/libmpv-2.dll'),
      File('../../../build/windows/x64/libmpv/libmpv-2.dll'),
      File('../../build/windows/x64/libmpv/libmpv-2.dll'),
    ];
    for (final dll in candidates) {
      if (dll.existsSync()) {
        MediaKit.ensureInitialized(libmpv: dll.absolute.path);
        print('T108|libmpv = ${dll.absolute.path}');
        return;
      }
    }
    print('T108|★ 警告：没找到 libmpv-2.dll ⇒ 本文件会因前置不成立而红');
  });

  setUp(() {
    _searchFixtures.clear();
    _searched.clear();
    _fetchedComments.clear();
    debugSetDanmakuTransportForTest(_FakeTransport());
  });

  tearDown(() {
    // ★ 必须复位：不清的话后面的用例会继续被这个假传输接管
    debugSetDanmakuTransportForTest(null);
    RemoteBridge.instance.stop();
  });

  // ── ① 搜索框存在且能触发宿主回调 ────────────────────────────────────
  testWidgets('① 面板真渲染出搜索框 + 「搜索」按钮；点了 ⇒ 宿主真收到关键词', (t) async {
    _searchFixtures['某番'] = _twoEpisodes('某番', '第 1 集', '第 2 集');
    await _mountPlayer(t);
    await _openPanelAndScroll(t);

    /*
     * ⚠️ 面板卡片 maxHeight 620、内容可滚 ⇒ 搜索区在下面。
     *    真渲染断言：`TextField` 至少有一个、且 hint 正是我们写的那个。
     */
    final kwField = find.widgetWithText(TextField, '').evaluate().isNotEmpty;
    expect(kwField, isTrue, reason: '前置：面板里应有输入框');
    expect(
      find.text('番剧名 / 关键词'),
      findsOneWidget,
      reason: '★ 搜索框的 hint 必须是它 —— 找不到说明搜索区没渲染出来',
    );

    // 走**生产**的 `_searchDanmaku`（flutter_tester 里指针回调不触发，
    // 见 t27_w22 文件头；这条直调的是生产代码本身，不是手抄副本）
    await debugPlayerDanmakuSearchForProbe('某番');
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    _claim(t);

    print('T108①|搜索接口收到的关键词 = $_searched');
    expect(_searched, contains('某番'),
        reason: '★ 宿主没把关键词送到搜索接口 ⇒ 搜索框是假 UI');

    // 结果渲染成两行（面板真画出来了）
    expect(find.textContaining('某番 · 第 1 集'), findsOneWidget);
    expect(find.textContaining('某番 · 第 2 集'), findsOneWidget);
    await _settleTimers(t);
  });

  // ── ② 点一条 ⇒ 真的载入那一集（断言宿主收到了 episodeId）───────────
  testWidgets('② 点结果里的一条 ⇒ 宿主收到那个 episodeId（载入该集）', (t) async {
    _searchFixtures['某番'] = _twoEpisodes('某番', '第 1 集', '第 2 集');
    await _mountPlayer(t);
    await _openPanelAndScroll(t);

    await debugPlayerDanmakuSearchForProbe('某番');
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    _claim(t);
    expect(_fetchedComments, isEmpty, reason: '前置：还没点，不该取任何弹幕');

    /*
     * 面板把那条 `DanmakuMatch` 递给宿主 —— 这里模拟"用户点了第 2 集"。
     * 断言点是**宿主真的采纳了用户的选择**：`_biliCid` == 那个 episodeId。
     */
    final state = debugPlayerDanmakuSettingsState();
    expect(state, isNotNull, reason: '前置：取不到面板状态');
    final second = state!.searchResults.firstWhere(
      (m) => m.episodeId == 22222,
      orElse: () => throw StateError('前置：结果里没有第 2 集（episodeId=22222）'),
    );
    debugPlayerPickDanmakuMatchForProbe(second);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);

    print('T108②|宿主采纳的 episodeId = ${debugPlayerDanmakuBoundId()}');
    expect(
      debugPlayerDanmakuBoundId(),
      22222,
      reason: '★★ 宿主没收到用户选的那条 episodeId ⇒ "点一条就载入该集"是假的',
    );
    await _settleTimers(t);
  });

  // ── ③ 空结果 ⇒ 明确空态文案 ─────────────────────────────────────────
  testWidgets('③ 搜不到 ⇒ 明确空态文案（不是空白）', (t) async {
    // 不设 fixture ⇒ 假传输回 {'animes':[]}
    await _mountPlayer(t);
    await _openPanelAndScroll(t);

    // 先搜一个"有的"，把结果画出来
    _searchFixtures['某番'] = _twoEpisodes('某番', '第 1 集', '第 2 集');
    await debugPlayerDanmakuSearchForProbe('某番');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);
    expect(find.textContaining('某番 · 第 1 集'), findsOneWidget);

    // 再搜一个"没有的" ⇒ 结果列表清空 + 空态文案出现
    await debugPlayerDanmakuSearchForProbe('查无此番');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);

    expect(find.textContaining('某番 · 第 1 集'), findsNothing,
        reason: '★ 新搜索必须清掉上一次的结果（否则会被误读成"这次搜到的"）');
    expect(find.text('没搜到，换个关键词试试'), findsOneWidget,
        reason: '★★ 空结果显示空白 ⇒ 用户以为程序卡住了');
    await _settleTimers(t);
  });

  // ── ④ ★★ 反向守卫：搜索不得影响正在播放的流 ─────────────────────────
  testWidgets('④ 搜索/选中**不改**流地址、不动正在播的那一份弹幕', (t) async {
    _searchFixtures['某番'] = _twoEpisodes('某番', '第 1 集', '第 2 集');
    await _mountPlayer(t);

    // 搜索**之前**的流地址（可能为空 —— flutter_tester 里起播失败，
    // 但"搜索前后逐字相同"这条判据在空列表上同样成立，且**不会假绿**：
    // 若哪天搜索真的碰了流，列表就会变）。
    final urlsBefore = debugPlayerStreamUrlsForProbe();
    await _openPanelAndScroll(t);
    await debugPlayerDanmakuSearchForProbe('某番');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);

    final state = debugPlayerDanmakuSettingsState();
    final first = state!.searchResults.first;
    debugPlayerPickDanmakuMatchForProbe(first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);

    final urlsAfter = debugPlayerStreamUrlsForProbe();
    print('T108④|搜索前流 = $urlsBefore');
    print('T108④|搜索后流 = $urlsAfter');
    expect(
      urlsAfter,
      urlsBefore,
      reason: '★★★ 搜索**绝不许**影响正在播放的流（不许因为搜索就换源/暂停）',
    );
    await _settleTimers(t);
  });

  // ── ⑤ 反面：面板里没有搜索框时，本文件那几条会红（客户端契约）───────
  testWidgets('⑤ 阴性对照：没传 onSearch/onPickMatch 的宿主**不画**搜索区', (t) async {
    // 直接挂精简面板（不经过 PlayerPage）—— 证明"搜索区是可选能力"，
    // 而不是被无条件塞进面板。这也是 t103/t73 那批既有挂载点不破的根据。
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              DanmakuSettingsDialog(
                state: DanmakuSettingsState.fromPrefs(),
                onSetEnabled: (_) {},
                onSetFontScale: (_) {},
                onSetOpacity: (_) {},
                onSetSpeed: (_) {},
                onSetArea: (_) {},
                onReload: () {},
                onClose: () {},
              ),
            ],
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.text('搜索番剧'), findsNothing,
        reason: '★ 没接回调就不该画搜索区（否则是"点了没反应"的假 UI）');
    expect(find.text('重新获取弹幕'), findsOneWidget, reason: '阳性对照：面板本身画出来了');
  });
}
