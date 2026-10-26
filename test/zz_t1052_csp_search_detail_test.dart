// ═══════════════════════════════════════════════════════════════════════
//  t1052：csp 源的搜索结果**上屏 + 可点进详情**（第 19 项最后的产物核验）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守三条
// ```text
// ① 真实形状的 csp 命中 ⇒ 组标题是可读名（"🅱️哔哩｜资源合集"），不是 csp-bili-xxxx
// ② 点卡片 ⇒ onOpenDetail 收到 ('csp-bili-adfc5b81', '98765')（真的走到回调）
// ③ 注入「把 id 前缀丢掉」⇒ ② 必红
// ```
//
// # 另含「被跳过的源」显示口径（与组标题统一）
// ```text
// · `_skipped` 记录 = (provider, name, reason)（search_page.dart:222）
// · UI :1256 显示 `name`，**name 为空回退 provider**（不许空白）
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/search_page.dart';

const String kCspProvider = 'csp-bili-adfc5b81';
const String kCspName = '🅱️哔哩｜资源合集';
const String kNative = '98765';

SearchStreamEvent cspHit() => SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: kCspProvider,
      providerName: kCspName,
      items: <MediaItem>[
        MediaItem(
          id: '$kCspProvider:$kNative',
          title: '兰香如故',
          provider: kCspProvider,
        ),
      ],
    );

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: child),
    );


/// 把目标滚进视口再断言
///
/// ```text
/// `_SkippedList` 现在是**独立 sliver**（search_page.dart:895），
/// 结果一多它就落到视口外 ⇒ SliverList 懒构建 ⇒ finder 找不到
/// （`skipOffstage:false` 只搜"已建"的，不构建就搜不到）。
/// ⇒ 不是产品没显示，是测试没让它进视口；判据强度不变。
/// ```
Future<void> reveal(WidgetTester t, Finder f) async {
  if (f.evaluate().isEmpty) {
    // 真·懒构建（还没进树）⇒ 边滚边找
    await t.scrollUntilVisible(f, 240,
        scrollable: find.byKey(const ValueKey<String>('search-results-scroll')),
        maxScrolls: 60);
  } else {
    // 已在树上但可能在视口外（`SliverToBoxAdapter` 的 child **建树即构建**）
    // ⇒ 这里必须用 ensureVisible 真滚，否则"已构建"会让我们误以为不用滚
    await t.ensureVisible(f);
  }
  await t.pump(const Duration(milliseconds: 60));
}

void main() {
  group('① csp 命中上屏：组标题是可读名', () {
    testWidgets('★★★ 组标题 = 🅱️哔哩｜资源合集，卡片标题 = 兰香如故', (t) async {
      await t.pumpWidget(host(const SearchPage()));
      await t.pump();
      final state = t.state<SearchPageState>(find.byType(SearchPage));
      state.debugSetProviderCount(2);
      state.debugBeginSearch('兰香如故');
      await t.pump();
      state.debugFeedHit(cspHit());
      await t.pump();
      await t.pump(const Duration(milliseconds: 120));

      expect(find.text(kCspName), findsWidgets,
          reason: '★★★ 组标题必须是 manifest 的可读名（不能显示 csp-bili-xxxx）');
      expect(find.text('兰香如故'), findsWidgets, reason: '★ 卡片标题要上屏');
      expect(find.textContaining(kCspProvider), findsNothing,
          reason: '★ 用户可见区域不许出现内部 provider id');
    });
  });

  group('② 点卡片 ⇒ 详情回调收到 (provider, native)', () {
    testWidgets('★★★ onOpenDetail("$kCspProvider","$kNative")', (t) async {
      String? gotProvider;
      String? gotId;
      await t.pumpWidget(host(SearchPage(
        onOpenDetail: (p, id) {
          gotProvider = p;
          gotId = id;
        },
      )));
      await t.pump();
      final state = t.state<SearchPageState>(find.byType(SearchPage));
      state.debugSetProviderCount(1);
      state.debugBeginSearch('兰香如故');
      await t.pump();
      state.debugFeedHit(cspHit());
      await t.pump();
      await t.pump(const Duration(milliseconds: 120));

      final card = find.text('兰香如故').first;
      await t.tap(card);
      await t.pump(const Duration(milliseconds: 60));

      expect(gotProvider, kCspProvider,
          reason: '★★★ 点结果必须真的回调详情（id 前缀是 provider 段）；'
              '注入「丢掉 id 前缀」本条立刻红');
      expect(gotId, kNative, reason: '★★ native 段必须原样传出（丢一位就路由到错条目）');
    });
  });

  group('③ 被跳过的源显示可读名（与组标题同一口径）', () {
    testWidgets('★★★ name 优先，name 为空回退 provider', (t) async {
      await t.pumpWidget(host(const SearchPage()));
      await t.pump();
      final state = t.state<SearchPageState>(find.byType(SearchPage));
      state.debugSetProviderCount(2);
      state.debugBeginSearch('兰香如故');
      await t.pump();
      /*
       * ⚠️ 必须先喂**一条命中**：结果区是
       *   `if (_totalResults == 0 && !_searching) _NoResult() else if (_totalResults > 0) …`
       *   而 `_SkippedList` 挂在后一个分支里 ⇒ 0 命中时它根本不会被渲染。
       *   （这也正是真实场景：一部分源有结果、一部分源失败。）
       */
      state.debugFeedHit(cspHit());
      // 有 name ⇒ 显示 name
      state.debugFeedSkipped(SearchStreamEvent(
        kind: SearchEventKind.miss,
        provider: 'csp-app99-x',
        providerName: '💯某影视',
        reason: '请求站点失败（超时）',
      ));
      // 无 name ⇒ 回退 provider
      state.debugFeedSkipped(SearchStreamEvent(
        kind: SearchEventKind.miss,
        provider: 'csp-noname-y',
        reason: '超时',
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 120));

      await reveal(t, find.textContaining('💯某影视', skipOffstage: false));
      expect(find.textContaining('💯某影视', skipOffstage: false), findsWidgets,
          reason: '★★★ 有 name 时显示可读名（用户看不懂 csp-app99-x 这种键）');
      expect(find.textContaining('csp-noname-y', skipOffstage: false), findsWidgets,
          reason: '★★ name 为空必须回退 provider（不许显示空白）');
      expect(find.textContaining('csp-app99-x', skipOffstage: false), findsNothing,
          reason: '★ 有 name 时不许再露内部 id');
    });
  });

  _skippedAlongsideEmpty();
}

void _skippedAlongsideEmpty() {
  group('④ 全源失败 ⇒ 空态 + 失败清单同时出现', () {
    testWidgets('★★★ 0 结果 + 有 skipped ⇒ 两者都在', (t) async {
      await t.pumpWidget(host(const SearchPage()));
      await t.pump();
      final state = t.state<SearchPageState>(find.byType(SearchPage));
      state.debugSetProviderCount(2);
      state.debugBeginSearch('绝不存在的关键词');
      await t.pump();
      state.debugFeedSkipped(SearchStreamEvent(
        kind: SearchEventKind.miss,
        provider: 'csp-app99-x',
        providerName: '💯某影视',
        reason: '请求站点失败（超时）',
      ));
      await t.pump();
      state.debugEndSearch(); // 搜索结束（真实链路 :394-400）
      await t.pump(const Duration(milliseconds: 120));

      expect(find.text('没有找到相关内容'), findsOneWidget,
          reason: '★★ 空态那句必须在');
      await reveal(t, find.textContaining('个源未能返回结果', skipOffstage: false));
      expect(find.textContaining('个源未能返回结果', skipOffstage: false),
          findsWidgets,
          reason: '★★★ 失败清单也必须在（并列，不是替代）；'
              '注入「把它移回 _totalResults > 0 分支」本条立刻红');
      expect(find.textContaining('💯某影视', skipOffstage: false), findsWidgets,
          reason: '★ 清单里要有可读名');
    });

    testWidgets('★★ 没有 skipped ⇒ 只画空态，不画空列表头', (t) async {
      await t.pumpWidget(host(const SearchPage()));
      await t.pump();
      final state = t.state<SearchPageState>(find.byType(SearchPage));
      state.debugSetProviderCount(2);
      state.debugBeginSearch('绝不存在的关键词');
      await t.pump();
      state.debugEndSearch();
      await t.pump(const Duration(milliseconds: 120));

      expect(find.text('没有找到相关内容'), findsOneWidget);
      expect(find.textContaining('个源未能返回结果', skipOffstage: false),
          findsNothing,
          reason: '★★ 没有失败源时不许出现"0 个源未能返回结果"这种空列表头');
    });
  });

  _revealNeeded();
}

void _revealNeeded() {
  group('⑤ reveal() 必须真的在滚（30 条命中 ⇒ 失败清单在视口外）', () {
    testWidgets('★★★ 空 reveal ⇒ 红；真 reveal ⇒ 失败清单可见', (t) async {
      // 小窗口：确保 30 条命中一定把下面顶出视口
      t.view.physicalSize = const Size(900, 700);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      await t.pumpWidget(host(const SearchPage()));
      await t.pump();
      final state = t.state<SearchPageState>(find.byType(SearchPage));
      state.debugSetProviderCount(2);
      state.debugBeginSearch('兰香如故');
      await t.pump();
      // ★ 30 条命中（同一源、标题各异）
      state.debugFeedHit(SearchStreamEvent(
        kind: SearchEventKind.hit,
        provider: kCspProvider,
        providerName: kCspName,
        items: <MediaItem>[
          for (var i = 0; i < 30; i++)
            MediaItem(
              id: '$kCspProvider:$i',
              title: '兰香如故 第 $i 条',
              provider: kCspProvider,
            ),
        ],
      ));
      state.debugFeedSkipped(SearchStreamEvent(
        kind: SearchEventKind.miss,
        provider: 'csp-app99-x',
        providerName: '💯某影视',
        reason: '请求站点失败（超时）',
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 120));

      final scrollable = t.state<ScrollableState>(find
          .descendant(
            of: find.byKey(const ValueKey<String>('search-results-scroll')),
            matching: find.byType(Scrollable),
          )
          .first);
      expect(scrollable.position.pixels, 0,
          reason: '★ 前置条件：滚之前偏移必须是 0（否则这条测不到"滚动"这件事）');

      // ★ 前置条件（几何）：滚之前失败清单在**视口下方**
      //
      // 实测（`.probe/reveal_measure_test.dart`）：maxScrollExtent=3762、
      // 失败清单 rect.top≈4313、视口高 700 ⇒ 它在视口外，但**已经在树上**
      // （`SliverToBoxAdapter` 的 child 建树即构建，只是布局到视口外）。
      // ⚠️ 所以"找不到它"永远不成立 —— 判据必须是**几何**，不是 finder 命中数。
      final skipText = find.textContaining('个源未能返回结果', skipOffstage: false);
      expect(t.getRect(skipText).top, greaterThan(700),
          reason: '★★ 前置条件（几何）：滚之前失败清单必须在视口下方');

      // 滚过去（reveal 内部按 key 找主滚动区）
      await reveal(t, skipText);
      await t.pump(const Duration(milliseconds: 80));

      // ★★ reveal() 真的滚过的**双重证据**：偏移变大 + 目标进了视口
      expect(scrollable.position.pixels, greaterThan(0),
          reason: '★★★ reveal() 必须真的滚动（偏移 > 0）；'
              '把它换成空实现 ⇒ 本条立刻红');
      expect(t.getRect(skipText).top, lessThan(700),
          reason: '★★★ 滚动后失败清单必须进入视口（否则 reveal 等于没滚）');

      expect(skipText, findsWidgets,
          reason: '★★★ 必须能滚到失败清单（这一条就是 reveal() 存在的证据）');
    });
  });
}
