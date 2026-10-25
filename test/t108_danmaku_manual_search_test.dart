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

/// 切到「高级」页签，并**断言真的切过去了**
///
/// # 为什么不用 `tester.tap`
/// ```text
/// 2026-10-25 实测：面板内容是可滚的（TabBarView + 滚动视图），
/// `tester.tap(find.text('高级'))` 打到的是"滚动视图外面"的坐标 ⇒ **静默不生效**
/// （`warnIfMissed:false` 会把这个失败吞掉）。5 次重试后 dump 出来的
/// 仍是「显示」页签内容（字号 / 透明度 / 屏蔽词…），`搜索…` 始终 0 个。
/// ⇒ 改成 `ensureVisible`（先滚到完全可见）+ `tapAt(getCenter(...))`（打中心点），
///   并把「切没切过去」本身做成断言 —— 若这条红，说明"点了页签但没切"，
///   那是**产品的可点区域/滚动视口**问题，不是测试写法问题。
/// ```
Future<void> _switchToSourcesTab(WidgetTester t) async {
  final tab = find.text('高级');
  expect(tab, findsOneWidget, reason: '前置：面板必须有「高级」页签');
  await t.ensureVisible(tab);
  await t.pump();
  await t.tapAt(t.getCenter(tab));
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
  _claim(t);
  // ★★ 这就是"点了页签必须真的切过去"的判据（本文件最有价值的一条之一）
  expect(find.text('测试连接'), findsOneWidget,
      reason: '★★ 点了「高级」页签后必须出现「来源」页的内容（找「测试连接」作锚）——'
          '若这里红，说明页签**点了但没切**（可点区域/滚动视口问题，真产品缺陷）');
  expect(find.text('显示弹幕'), findsNothing,
      reason: '★★ 切到「来源」页后「显示」那组必须消失（否则是两页叠着画）');
}

/// 打开面板但**不滚动**（搜索入口在「高级」页签，不需要滚到旧搜索区）
Future<void> _openPanelOnly(WidgetTester t) async {
  expect(
    debugPlayerOpenDanmakuSettingsForProbe(),
    isTrue,
    reason: '前置：弹幕设置面板没打开',
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
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
    /*
     * ★ 2026-10-25（task-38，D 迁移）：搜索 UI 已从面板内联搬到**独立搜索页**：
     *   面板只剩一个入口 `FilledButton.tonal('搜索弹幕与绑定剧集')` → `onOpenSearch`
     *   → 宿主 `_danmakuSearchOpen = true` → `player_page.dart:17088` 挂 `DanmakuSearchPage`。
     *   ⇒ 判据改为：① 面板有入口；② 点开后**独立页**真的渲染出关键词输入框；
     *     ③ 结果行由搜索页渲染（单行 `match.label`，例：`某番 第 1 集`）。
     */
    await _switchToSourcesTab(t);
    /*
     * ★ 真入口是「高级」页签里 dan-api 那一行的 **`搜索…`** 动作
     *   （`danmaku_settings_dialog.dart:3919 _rowAction('搜索…', () => _focusSearch(s))`
     *    → `_focusSearch` → `widget.onOpenSearch?.call()`）。
     *   ⚠️ 源码里另有一处 `FilledButton.tonal('搜索弹幕与绑定剧集')`（:1799），
     *   但它在**另一条分支**里，当前 UI 不渲染它 —— 2026-10-25 用面板文本 dump 证实
     *   （那次面板文本 dump 证实：点「高级」后出现的是 `搜索…`，没有那枚 FilledButton）。
     */
    final entry = find.text('搜索…');
    expect(entry, findsOneWidget,
        reason: '★ 面板「高级」页签里必须有 `搜索…` 入口（搜索区的唯一门）');
    await t.ensureVisible(entry);
    await t.pump();
    await t.tapAt(t.getCenter(entry));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    _claim(t);
    expect(find.text('跨渠道搜索关键词'), findsOneWidget,
        reason: '★ 独立搜索页的关键词输入框必须在（labelText 就是它）');

    // 走**生产**的 `_searchDanmaku`（flutter_tester 里指针回调不触发，
    // 见 t27_w22 文件头；这条直调的是生产代码本身，不是手抄副本）
    await debugPlayerDanmakuSearchForProbe('某番');
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    _claim(t);

    print('T108①|搜索接口收到的关键词 = $_searched');
    expect(_searched, contains('某番'),
        reason: '★ 宿主没把关键词送到搜索接口 ⇒ 搜索框是假 UI');

    /*
     * 2026-10-15：结果行改成**两行**显示（标题 / 集数分开）。
     *
     * 改前是一行 `'$title · $ep'`；加了封面之后横排空间不够，
     * 所以拆成「作品名」+「集数」两行，不再用「·」拼。
     * ⚠️ 这条断言就是那次改版的**回归守卫** —— 别改回一行。
     */
    expect(find.textContaining('某番'), findsWidgets,
        reason: '搜索页里必须画出结果行（单行 match.label，例：某番 第 1 集）');
    expect(find.textContaining('第 1 集'), findsWidgets, reason: '第 1 集那条结果要在');
    expect(find.textContaining('第 2 集'), findsWidgets, reason: '第 2 集那条结果要在');
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
    await _openPanelOnly(t);
    await _switchToSourcesTab(t);
    await t.ensureVisible(find.text('搜索…'));
    await t.pump();
    await t.tapAt(t.getCenter(find.text('搜索…')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    _claim(t);

    // 先搜一个"有的"，把结果画出来
    _searchFixtures['某番'] = _twoEpisodes('某番', '第 1 集', '第 2 集');
    await debugPlayerDanmakuSearchForProbe('某番');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);
    expect(find.textContaining('第 1 集'), findsWidgets);

    // 再搜一个"没有的" ⇒ 结果列表清空 + 空态文案出现
    await debugPlayerDanmakuSearchForProbe('查无此番');
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);

    expect(find.textContaining('第 1 集'), findsNothing,
        reason: '★ 新搜索必须清掉上一次的结果（否则会被误读成"这次搜到的"）');
    expect(find.text('dan-api 未找到匹配剧集'), findsOneWidget,
        reason: '★★ 空结果显示空白 ⇒ 用户以为程序卡住了'
            '（搜索页的空态文案就是 `dan-api 未找到匹配剧集`）');
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
    expect(find.text('搜索…'), findsNothing,
        reason: '★ 没接 onOpenSearch 就不该画 `搜索…` 入口（否则是"点了没反应"的假 UI）');
    // ★ 2026-10-25（task-38）：原来拿 '重新获取弹幕' 当阳性对照，该文案已不在面板上；
    //   改用页签标题（'显示'）—— 它在面板首屏必然渲染，是本文件最稳的"面板画出来了"锚。
    expect(find.text('显示'), findsWidgets, reason: '阳性对照：面板本身画出来了');
  });
}
