// test/zz_t1062_agg_groups_test.dart
//
// ══════════════════════════════════════════════════════════════════════════
// 「全部」搜索：聚合源必须**按子站分组**（对标原版）
// ══════════════════════════════════════════════════════════════════════════
//
// Owner 原话（2026-10-28）：
//   「搜『老舅』，原版出来几十条、左边一排源分组；我们这边不是这个形态」
//
// # 判据（两条，缺一条就不算做到）
// ```text
// ① 数据侧：聚合源一个事件里的条目，按 id 里的**子站前缀**拆成多个组
//            （拆分前后条目总数必须相等 —— 丢一条就是"结果变少"的静默 bug）
// ② 界面侧：拆出来的组标题是**子站名**（真 widget 树上真的渲染出两个标题，
//            且顺序 = 到达顺序）
// ```
//
// # 为什么必须两段都测
// ```text
// 只测纯函数：可能"拆对了但页面没用它"（本仓反复出现的"测了个没人用的东西"）。
// 只测界面：拆分规则里的边界（认不出前缀的条目、名字缺失）无法逐条钉死。
// ⇒ 下方 `split` 组测纯函数；`页面` 组用真 `SearchPage` + 真 `_addHit` 渲染。
// ```
//
// # 注入口与既有门禁同源
//   `debugSetProviderCount` / `debugBeginSearch` / `debugFeedHit` 三个口子
//   t73 已立过（`flutter test` 里没有核心 DLL，否则结果区永远不渲染）。
//   本文件新增 `debugAggChannelNamesFetcher`（子站名清单的替身，**生产恒 null**）。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/search_page.dart';

// ══════════════════════════════════════════════════════════════════════════
// 夹具
// ══════════════════════════════════════════════════════════════════════════

const String kAgg = 'tvbox_agg';
const String kW = '老舅';

MediaItem it(String id, String title) => MediaItem(id: id, title: title);

SearchStreamEvent hitOf(
  String provider,
  String providerName,
  List<MediaItem> items,
) =>
    SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: provider,
      providerName: providerName,
      items: items,
    );

/// 聚合条目的 id 形状：`<聚合id>:<子站id>::<子站原始 id>`
String aggId(String child, String native) => '$kAgg:$child::$native';

Widget host(Widget child, Size size) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(body: child),
      ),
    ),
  );
}

Future<void> sizeView(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// ★ 2026-11-01（左栏源切换）：源名会**同时**出现在左栏行与结果组标题
/// ⇒ 组标题断言/几何读取限定在结果滚动区内（左栏在 `search-results-scroll`
///   外面；无左栏时该 scoped 查找与原样等价。与 t73 同款修法）。
Finder resultsText(String text) => find.descendant(
      of: find.byKey(const ValueKey<String>('search-results-scroll')),
      matching: find.text(text),
    );

void main() {
  tearDown(() {
    SearchPageState.debugAggChannelNamesFetcher = null;
  });

  // ══════════════════════════════════════════════════════════════════
  //  ① 子站前缀解析
  // ══════════════════════════════════════════════════════════════════

  group('子站前缀', () {
    test('聚合条目能取出子站 id', () {
      expect(
        aggregateChildOf('tvbox_agg:csp-4k-zhinan::https://example/a'),
        'csp-4k-zhinan',
      );
      expect(aggregateChildOf('tvbox_agg:tvbox-abc::123'), 'tvbox-abc');
    });

    test('非聚合形状 ⇒ null（不许瞎猜）', () {
      expect(aggregateChildOf('srca:3862'), isNull, reason: '普通源的 id 没有子站段');
      expect(aggregateChildOf('tvbox_agg:nocolon'), isNull);
      expect(aggregateChildOf(''), isNull);
      expect(aggregateChildOf('tvbox_agg:::x'), isNull, reason: '空子站 id 不算');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 事件拆分（纯函数）
  // ══════════════════════════════════════════════════════════════════

  group('split', () {
    test('非聚合源：原样一组', () {
      final ev = hitOf('srca', '源A', [it('srca:1', '老舅')]);
      final gs = splitAggregateHit(ev);
      expect(gs.length, 1);
      expect(gs[0].name, '源A');
      expect(gs[0].items.length, 1);
    });

    test('聚合源：按子站拆成多组，组名用清单里的名字', () {
      final ev = hitOf(kAgg, 'TVBox 聚合', [
        it(aggId('sub-a', '1'), '老舅 A'),
        it(aggId('sub-b', '2'), '老舅 B'),
        it(aggId('sub-a', '3'), '老舅 A2'),
      ]);
      final gs = splitAggregateHit(ev, channelNames: {
        'sub-a': '源甲',
        'sub-b': '源乙',
      });
      expect(gs.length, 2, reason: '两个子站 ⇒ 两组');
      expect(gs[0].name, '源甲');
      expect(gs[0].items.length, 2, reason: 'sub-a 有两条');
      expect(gs[1].name, '源乙');
      expect(gs[1].items.length, 1);
      // 到达顺序：sub-a 先出现 ⇒ 排在前
      expect(gs[0].items[0].id, aggId('sub-a', '1'));
    });

    test('名字缺失 ⇒ 退回子站 id（绝不画空标题）', () {
      final ev = hitOf(kAgg, 'TVBox 聚合', [it(aggId('sub-x', '1'), '老舅')]);
      final gs = splitAggregateHit(ev);
      expect(gs.length, 1);
      expect(gs[0].name, 'sub-x');
      expect(gs[0].name.trim().isNotEmpty, isTrue);
    });

    test('认不出前缀的条目不许丢：兜底组保留，总数不变', () {
      final ev = hitOf(kAgg, 'TVBox 聚合', [
        it(aggId('sub-a', '1'), '老舅 A'),
        it('tvbox_agg:没有子站段', '老舅 未知'),
        it(aggId('sub-b', '2'), '老舅 B'),
      ]);
      final gs = splitAggregateHit(ev, channelNames: {'sub-a': '源甲', 'sub-b': '源乙'});
      final total = gs.fold<int>(0, (n, g) => n + g.items.length);
      expect(total, ev.items.length, reason: '★ 拆分组不许吞掉任何一条');
      // 兜底组的名字是聚合源名（不是空串）
      final fallback = gs.where((g) => g.name == 'TVBox 聚合').toList();
      expect(fallback.length, 1);
      expect(fallback[0].items.length, 1);
    });

    test('空结果：保持"一组空组"（组标题照旧，不变成零组）', () {
      final ev = hitOf(kAgg, 'TVBox 聚合', const []);
      final gs = splitAggregateHit(ev);
      expect(gs.length, 1);
      expect(gs[0].name, 'TVBox 聚合');
      expect(gs[0].items, isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ 真界面：两个子站各一组，标题真的渲染出来
  // ══════════════════════════════════════════════════════════════════

  group('页面', () {
    testWidgets('聚合一次事件 ⇒ 页面上出现两个子站分组标题', (t) async {
      await sizeView(t, const Size(1200, 900));
      SearchPageState.debugAggChannelNamesFetcher = () async => {
            'sub-a': '源甲',
            'sub-b': '源乙',
          };
      await t.pumpWidget(host(const SearchPage(), const Size(1200, 900)));
      await t.pump(); // initState 里的两个异步加载（都走替身/失败兜底）

      final st = t.state<SearchPageState>(find.byType(SearchPage));
      st.debugSetProviderCount(2);
      st.debugBeginSearch(kW);
      await t.pump();

      // 走**真实** `_addHit`：一个聚合事件、两个子站
      st.debugFeedHit(hitOf(kAgg, 'TVBox 聚合', [
        it(aggId('sub-a', '1'), '老舅 甲站'),
        it(aggId('sub-b', '2'), '老舅 乙站'),
      ]));
      await t.pump();

      // ★ 铁律 149：先证明真的渲染了，再断言结构
      expect(resultsText('源甲'), findsOneWidget, reason: '子站名必须成为组标题');
      expect(resultsText('源乙'), findsOneWidget);
      expect(find.text('老舅 甲站'), findsOneWidget);
      expect(find.text('老舅 乙站'), findsOneWidget);

      // 组标题按到达顺序：源甲在上
      final a = t.getRect(resultsText('源甲')).top;
      final b = t.getRect(resultsText('源乙')).top;
      expect(a, lessThan(b), reason: '先到的子站排在前面（源甲 $a / 源乙 $b）');
    });

    testWidgets('非聚合源仍是单组（不许把普通源也拆）', (t) async {
      await sizeView(t, const Size(1200, 900));
      await t.pumpWidget(host(const SearchPage(), const Size(1200, 900)));
      await t.pump();

      final st = t.state<SearchPageState>(find.byType(SearchPage));
      st.debugSetProviderCount(2);
      st.debugBeginSearch(kW);
      await t.pump();

      st.debugFeedHit(hitOf('srca', '源A', [
        it('srca:1', '老舅 一'),
        it('srca:2', '老舅 二'),
      ]));
      await t.pump();

      expect(resultsText('源A'), findsOneWidget);
      expect(find.text('2 个结果'), findsOneWidget, reason: '两条都在同一组里');
    });
  });
}
