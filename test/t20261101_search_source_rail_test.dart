// ═══════════════════════════════════════════════════════════════════════
//  搜索页左栏源切换（2026-11-01，Owner：对标参考的搜索聚合 UX）
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话：
// > 搜索页，在左侧加上搜索出来的源，我可以快速切换点击源，切换到对应源的结果，查看
//
// # 本门禁钉什么
// ```text
// ① 宽窗口：命中三源 ⇒ 左栏出现（全部 + 三行各带条数）；点乙 ⇒ 只剩乙的组；
//    点「全部」⇒ 三组全回来（切换是可逆的视图过滤，不发新请求）；
// ② 零命中 ⇒ 不画左栏（无源可切 ⇒ 无 UI）；
// ③ 窄窗口 ⇒ 顶部 chips（同一份数据同一份交互），左栏不出现；
// ④ 默认（不点任何东西）⇒ 三组全部照常渲染（零破坏底线）；
// ⑤ 源码级注入证红：渲染循环改用 `_hits`（不过滤）⇒ 红；复位缺失 ⇒ 红。
// ```
// # 为什么走 debug 注入口
// 与 t73 同一口径：`flutter test` 无核心 DLL，`searchAllStream` 必抛 ⇒
// 三个 debug 注入口补前置条件，喂进去的事件仍走**真** `_addHit` → 真 `_hits`。

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/search_page.dart';

import 'support/app_test_host.dart';

MediaItem item(String title, String id) => MediaItem(id: id, title: title);

SearchStreamEvent hit(String provider, List<MediaItem> items) =>
    SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: provider,
      providerName: provider,
      items: items,
    );

Future<void> sizeView(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// 造好一个"搜过一轮、三个源各有命中"的搜索页
///
/// 用 [AppTestHost] 统一宿主（提供 AppThemeScope + MaterialApp；本页部分
/// 组件族的既有约定），MediaQuery 给 LayoutBuilder 一个确定的窗口宽。
Future<SearchPageState> seeded(
  WidgetTester t,
  Size size, {
  bool withHits = true,
}) async {
  await sizeView(t, size);
  await t.pumpWidget(
    AppTestHost(
      brightness: Brightness.light,
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: const SearchPage(),
        ),
      ),
    ),
  );
  await t.pump();
  final st = t.state<SearchPageState>(find.byType(SearchPage));
  st.debugSetProviderCount(9);
  st.debugBeginSearch('老舅');
  await t.pump();
  if (withHits) {
    st.debugFeedHit(
      hit('source-a', [
        item('老舅甲一', 'source-a::1'),
        item('老舅甲二', 'source-a::2'),
        item('老舅甲三', 'source-a::3'),
      ]),
    );
    st.debugFeedHit(
      hit('source-b', [
        item('老舅乙一', 'source-b::1'),
        item('老舅乙二', 'source-b::2'),
      ]),
    );
    st.debugFeedHit(hit('source-c', [item('老舅丙一', 'source-c::1')]));
  }
  st.debugEndSearch();
  await t.pump();
  return st;
}

const railKey = Key('search-source-rail');
const chipsKey = Key('search-source-chips');
const allKey = Key('search-source-all');

/// 结果区的懒加载 sliver 会让视口外的组不进树 ⇒ 滚到它再断言"确实渲染了"
Future<void> scrollToGroup(WidgetTester t, String title) async {
  await t.scrollUntilVisible(
    find.text(title),
    300,
    scrollable: find
        .descendant(
          of: find.byKey(const Key('search-results-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
}

void main() {
  testWidgets('① 宽窗口：三源命中 ⇒ 左栏三行带条数；点乙 ⇒ 只剩乙；点全部 ⇒ 还原', (t) async {
    await seeded(t, const Size(1400, 900));

    // 左栏在场：全部 + 三源
    // ⚠️ 源名同时出现在结果组标题里 ⇒ 左栏行必须用 descendant 限定（防歧义）
    expect(find.byKey(railKey), findsOneWidget);
    expect(find.byKey(chipsKey), findsNothing);
    expect(find.byKey(allKey), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(railKey), matching: find.text('source-a')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(railKey), matching: find.text('source-b')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(railKey), matching: find.text('source-c')),
      findsOneWidget,
    );
    // 条数标注：乙 = 2（铁律 149：先证明卡片渲染了，再谈行为）
    expect(
      find.descendant(of: find.byKey(railKey), matching: find.text('2')),
      findsOneWidget,
    );

    // 点乙 ⇒ 右侧只剩乙的组（甲/丙的条目消失，乙的还在）
    await t.tap(find.byKey(const Key('search-source-row-source-b')));
    await t.pump();
    expect(find.text('老舅乙一'), findsOneWidget);
    expect(find.text('老舅乙二'), findsOneWidget);
    expect(find.text('老舅甲一'), findsNothing);
    expect(find.text('老舅丙一'), findsNothing);

    // 点「全部」⇒ 三组全回来（可逆；丙组在首屏下方 ⇒ 滚动到它再断言）
    await t.tap(find.byKey(allKey));
    await t.pump();
    expect(find.text('老舅甲一'), findsOneWidget);
    expect(find.text('老舅乙一'), findsOneWidget);
    await scrollToGroup(t, '老舅丙一');
    expect(find.text('老舅丙一'), findsOneWidget);
  });

  testWidgets('② 零命中 ⇒ 不画左栏（无源可切 ⇒ 无 UI）', (t) async {
    await seeded(t, const Size(1400, 900), withHits: false);
    expect(find.byKey(railKey), findsNothing);
    expect(find.byKey(chipsKey), findsNothing);
  });

  testWidgets('③ 窄窗口 ⇒ 顶部 chips，左栏不出现；点 chip 同样过滤', (t) async {
    await seeded(t, const Size(500, 900));

    expect(find.byKey(railKey), findsNothing);
    expect(find.byKey(chipsKey), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(chipsKey), matching: find.text('全部')),
      findsOneWidget,
    );

    // ⚠️ chip 文本是「源名 条数」——用 find.text('source-b') 会命中**结果组标题**
    //   （点它不触发过滤，恰好是"点了没反应"的假阴性），必须限定在 chips 内
    await t.tap(
      find.descendant(
        of: find.byKey(chipsKey),
        matching: find.text('source-b 2'),
      ),
    );
    await t.pump();
    expect(find.text('老舅乙一'), findsOneWidget);
    expect(find.text('老舅甲一'), findsNothing);
  });

  testWidgets('④ 默认（不点任何东西）⇒ 三组全部照常渲染（零破坏底线）', (t) async {
    await seeded(t, const Size(1400, 900));
    expect(find.text('老舅甲一'), findsOneWidget);
    expect(find.text('老舅乙一'), findsOneWidget);
    // 丙组在首屏下方（懒加载 sliver）⇒ 滚动到它再断言"确实渲染了"
    await scrollToGroup(t, '老舅丙一');
    expect(find.text('老舅丙一'), findsOneWidget);
  });

  // ══════════════════════════════════════════════════════════════════
  //  源码级注入证红
  // ══════════════════════════════════════════════════════════════════
  test('⑤ 源码门禁：渲染必须走过滤后的 _visibleHits，换词/清空必须复位选中源', () {
    final src = File('lib/ui/search_page.dart').readAsStringSync();
    // 剥 // 行注释（本文件用到的切片里没有块注释陷阱）
    final body = src
        .split('\n')
        .map((l) => l.contains('//') ? l.substring(0, l.indexOf('//')) : l)
        .join('\n');
    // ★ 渲染循环必须用 _visibleHits（改回 _hits ⇒ 注入证红：切换失效又变回全量）
    expect(
      body.contains('for (final h in _visibleHits)'),
      isTrue,
      reason: '★★ 结果渲染必须走过滤后的组（注入证红：改回 `_hits` ⇒ 本条红）',
    );
    expect(
      body.contains('for (final h in _hits) _ResultGroup'),
      isFalse,
      reason: '★ 不许残留未过滤的渲染循环',
    );
    // ★ 换词/清空必须复位（否则旧词的选中源污染新词视图）
    final resets = '_selectedSource = null;'.allMatches(body).length;
    expect(
      resets,
      greaterThanOrEqualTo(3),
      reason: '★ _doSearch/_clear/debugBeginSearch 三处都要复位（实测 $resets 处）',
    );
    // ★ 左栏数据来自 _hits 本体（不发新请求、不复制第二份名单）
    expect(
      body.contains('List<({String name, int count})>? get _sourceRailData'),
      isTrue,
    );
  });
}
