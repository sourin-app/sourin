// ═══════════════════════════════════════════════════════════════════════
//  t1050：视频搜索在 UI 上**真的能搜到**（csp 源 / 单源失败 / 空结果）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么用 debug 注入口（`search_page.dart:476/490`）
// ```text
// 真实结果来自 SourinApi.searchAllStream()（FFI → Rust 核心）；
// flutter test 里没有核心 DLL ⇒ 该调用必抛 ⇒ `_hits` 恒空 ⇒
// 所有断言都会退化成"对空列表的全称断言"（铁律 149：候选集空时恒真）。
// ⇒ 用页面自己的注入口喂**与真实链路同形的** SearchStreamEvent。
// ```
//
// # 守三条（对应 Owner 的"搜索没实现"最后一环）
// ```text
// ① csp 源的结果能出现在结果区（点名标题）
// ② 某源失败 ⇒ 其它源结果照常显示 + 「部分源失败」提示（不许静默）
// ③ 搜完仍 0 条 ⇒ 空态文案（不是白屏）
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/search_page.dart';

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: child),
    );

/// 造一条与真实 `SearchStreamEvent` 同形的 hit
SearchStreamEvent hit(String provider, String name, List<String> titles) =>
    SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: provider,
      providerName: name,
      items: <MediaItem>[
        for (final t in titles)
          MediaItem(id: '$provider:n-$t', title: t, provider: provider),
      ],
    );

/// 造一条"该源失败"事件（reason 非空 = 被跳过）
SearchStreamEvent failed(String provider, String name, String reason) =>
    SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: provider,
      providerName: name,
      items: const <MediaItem>[],
      reason: reason,
    );


/// 把目标滚进视口再断言
///
/// ```text
/// `_SkippedList` 已是**独立 sliver**；它常被布局到视口外，但**建树即构建**
/// （`SliverToBoxAdapter` 的 child）⇒ `skipOffstage:false` 找得到、但**看不见**。
/// ⇒ 判据必须"真的滚进视口"：已构建 ⇒ `ensureVisible`；未构建 ⇒ `scrollUntilVisible`。
/// ```
Future<void> reveal(WidgetTester t, Finder f) async {
  if (f.evaluate().isEmpty) {
    await t.scrollUntilVisible(f, 240,
        scrollable: find.byKey(const ValueKey<String>('search-results-scroll')),
        maxScrolls: 60);
  } else {
    await t.ensureVisible(f);
  }
  await t.pump(const Duration(milliseconds: 60));
}

void main() {
  group('① csp 源结果真的出现在结果区', () {
    testWidgets('★★★ 喂 csp_Bili 一条命中 ⇒ 标题上屏', (t) async {
      await t.pumpWidget(host(const SearchPage()));
      await t.pump();
      final state = t.state<SearchPageState>(find.byType(SearchPage));
      state.debugSetProviderCount(2); // 真实链路里这一步来自 listProviders()
      state.debugBeginSearch('测试');
      await t.pump();
      state.debugFeedHit(hit('csp-bili-adfc5b81', '🅱️哔哩｜资源合集', <String>['测试片']));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      expect(find.text('测试片'), findsOneWidget,
          reason: '★★★ csp 源的命中必须真的画出来（这是"搜索可用"的唯一证据）；'
              '注入「_addHit 里不追加」本条立刻红');
      expect(find.text('🅱️哔哩｜资源合集'), findsWidgets,
          reason: '★ 组标题要显示源名（用户要知道结果来自哪）');
    });
  });

  group('② 单源失败 ⇒ 其它结果照常 + 明确提示', () {
    testWidgets('★★★ 一个源报错，另一个源的结果仍显示，且列出失败源', (t) async {
      await t.pumpWidget(host(const SearchPage()));
      await t.pump();
      final state = t.state<SearchPageState>(find.byType(SearchPage));
      state.debugSetProviderCount(2);
      state.debugBeginSearch('测试');
      await t.pump();
      state.debugFeedHit(hit('csp-bili-adfc5b81', '🅱️哔哩｜资源合集', <String>['能搜到的片']));
      // ★ 必须走 `debugFeedSkipped`：`debugFeedHit` 只碰 `_hits`，喂 failed() 只会建空组
      state.debugFeedSkipped(failed('csp-app99-x', '💯某影视', '请求站点失败（超时）'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      expect(find.text('能搜到的片'), findsOneWidget,
          reason: '★★★ 一个源挂掉不许拖垮整体（错误隔离）；'
              '注入「失败就清空结果」本条立刻红');
      /*
       * ★ 2026-10-26 修（本文件原断言已过期）：`_SkippedList` 现在显示
       *   **可读名**（`s.name`，`search_page.dart:1256`），name 为空才回退
       *   `s.provider`；`_skipped` 记录已扩成 `(provider, name, reason)`
       *   （`:222`，真实流与 `debugFeedSkipped` 同一份组装）。
       *   ⇒ 断言改成可读名，并且**不许**再露内部 id。
       */
      await reveal(t, find.textContaining('💯某影视', skipOffstage: false));
      expect(find.textContaining('💯某影视', skipOffstage: false),
          findsWidgets,
          reason: '★★ 失败的源要用**可读名**点名（当前显示 s.name）');
      expect(find.textContaining('csp-app99-x', skipOffstage: false), findsNothing,
          reason: '★★ 有 name 时不许把内部 provider id 露给用户');
      /*
       * ★★★ 2026-10-26 补：**原因也必须逐条显示**（可诊断性）
       *
       * 改前只钉"源名出现"⇒ 实测两种破坏都**不红**（真踩过）：
       *   ① `'· ${s.reason}'` 换成固定串 `'· 已跳过'`
       *   ② 整段删掉 `for (final s in skipped)`（只留"$N 个源未能返回结果"）
       * 更糟的是：**skipped 那段 UI 从来没被任何门禁执行过** ——
       *   旧写法用 `debugFeedHit` 喂 failed()，它只碰 `_hits`（建空组），
       *   `_skipped` 恒空 ⇒ 上面那条"点名"其实命中的是**空组标题**。
       *   （已改用 `debugFeedSkipped`，与真实流回调同一份写入逻辑。）
       */
      expect(find.textContaining('请求站点失败（超时）', skipOffstage: false),
          findsWidgets,
          reason: '★★ 失败原因必须**逐条**显示（不是只报"有源失败"）——'
              '注入「reason 改成固定串 / 删掉逐条列表」本条立刻红');
    });
  });

  group('③ 搜完 0 条 ⇒ 空态文案（不是白屏）', () {
    testWidgets('★★★ 空结果给出「没有找到相关内容」', (t) async {
      await t.pumpWidget(host(const SearchPage()));
      await t.pump();
      final state = t.state<SearchPageState>(find.byType(SearchPage));
      state.debugSetProviderCount(2);
      state.debugBeginSearch('绝不存在的关键词');
      await t.pump();
      // 只喂"该源没结果"（reason 为空），不喂任何命中
      state.debugFeedHit(failed('csp-bili-adfc5b81', '🅱️哔哩｜资源合集', ''));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      state.debugEndSearch(); // 模拟流结束（真实链路 :394-400）
      await t.pump(const Duration(milliseconds: 200));

      // ★ 加了 debugEndSearch() 之后，判据收紧成"**必须**是空态文案"（不再接受"只给进度行"）
      expect(find.text('没有找到相关内容'), findsOneWidget,
          reason: '★★★ 搜完仍 0 条 ⇒ 必须给空态文案（不是白屏、也不是只给进度）；'
              '注入「_NoResult 换 SizedBox」本条立刻红');
    });
  });
}
