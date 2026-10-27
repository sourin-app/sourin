// test/zz_t1055_switch_exclude_current_source_test.dart
//
// ══════════════════════════════════════════════════════════════════════════
//  N2：换源候选列表**必须排除当前片源**（2026-10-27）
// ══════════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// 换源后还是没跟着上次的进度条走（换源应该要排除当前片源）
// ```
//
// # 守什么
// ```text
// ① 主判据：喂 3 组候选（其中 1 组 == 当前源）⇒ 渲染出来的候选里
//    该源整组都不在（源名与它的条目名都不出现）
// ② 阴性对照：只有当前源一个候选 ⇒ 列表空、如实说"没有找到其他源"，
//    **不许**把当前源又列回来（"排空后回退"是最容易写出的假修）
// ③ 非当前源不受牵连：另外两组照常渲染（防"过滤写成清空整表"）
// ④ 排的是 **provider 维度**：当前源里**别的条目**也不许作为候选出现
//    （只排一条 item 是常见的半吊子修法）
// ```
//
// # 铁律 149：候选集为空时全称断言恒真
// ```text
// 每条断言都先证明"另外两组真的渲染了"（found == 1），
// 再断言当前源不在 —— 否则"排掉了"和"根本没数据"看起来一模一样。
// ```
//
// # 为什么需要 `debugSetSwitchSearchRunner`
// ```text
// flutter test 里没有核心 DLL ⇒ listProviders() / searchAllStream() 必抛
// ⇒ _candidates 恒为空 ⇒ 所有"过滤"断言恒真（假门禁）。
// 该注入口只替换**取数那一段**，onEvent 走的仍是生产同一条
// `_handleEvent` ⇒ 真的累积 / 真排序 / 真的过滤 / 真渲染。
// ```

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/source_switch_dialog.dart';

// ══════════════════════════════════════════════════════════════════════════
// 夹具
// ══════════════════════════════════════════════════════════════════════════

const String kTitle = '鬼灭之刃';
const String kCurrent = '当前站';
const String kOtherA = '甲站';
const String kOtherB = '乙站';

MediaItem mi(String title, String id) => MediaItem(id: id, title: title);

SearchStreamEvent hitOf(String provider, List<MediaItem> items) =>
    SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: provider,
      providerName: provider,
      items: items,
    );

/// 造一个"搜一轮"的假 runner：把给定的 hit 事件按顺序喂进 onEvent，
/// 末尾补一条 `done`。
Future<void> Function(String, bool Function(SearchStreamEvent)) runnerOf(
  List<SearchStreamEvent> hits,
) {
  return (kw, onEvent) async {
    for (final ev in hits) {
      if (!onEvent(ev)) return;
    }
    onEvent(const SearchStreamEvent(kind: SearchEventKind.done));
  };
}

// ══════════════════════════════════════════════════════════════════════════
// 脚手架
// ══════════════════════════════════════════════════════════════════════════

Widget host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(body: child),
    ),
  );
}

/// 打开换源弹层（走**真的** `showSourceSwitchDialog` 入口）。
///
/// ⚠️ 弹层 `initState` 里有 `addPostFrameCallback((_) => _run())`
///   —— **打开就自动搜一次**（原版语义："点换源就是要看有哪些源"）
///   ⇒ 本测试**不需要**点「重搜」，只需把帧推到位让那次自动搜索跑完。
Future<void> openSheet(
  WidgetTester t, {
  required String currentProvider,
}) async {
  late BuildContext ctx;
  await t.pumpWidget(host(Builder(builder: (c) {
    ctx = c;
    return const SizedBox();
  })));
  unawaited(showSourceSwitchDialog(
    ctx,
    title: kTitle,
    currentProvider: currentProvider,
    currentProviderName: currentProvider,
  ));
  await t.pump(); // 弹层挂载
  await t.pump(); // 路由动画一帧 ⇒ 触发 addPostFrameCallback 里的自动 _run
  await t.pump(const Duration(milliseconds: 50)); // 让注入的 runner 跑完 + 渲染
}

/// 断言某段文本恰好渲染 1 处（防铁律 149：0 处说明这一段根本没渲染，
/// 全称断言会退化成恒真）。
void expectExactlyOne(WidgetTester t, String text, String because) {
  final n = t.widgetList(find.text(text)).length;
  expect(n, 1, reason: '「$text」应恰好渲染 1 处，实际 $n 处（$because）'
      ' —— 0 处说明这一段根本没渲染，断言会退化成恒真');
}

void expectNone(WidgetTester t, String text, String because) {
  expect(find.text(text), findsNothing, reason: because);
}

// ══════════════════════════════════════════════════════════════════════════
// 用例
// ══════════════════════════════════════════════════════════════════════════

void main() {
  tearDown(() => debugSetSwitchSearchRunner(null));

  testWidgets('★★★ 主判据：当前源整组不出现在候选里', (t) async {
    debugSetSwitchSearchRunner(runnerOf(<SearchStreamEvent>[
      hitOf(kCurrent, <MediaItem>[
        mi('$kTitle 当前站版本', '$kCurrent:1'),
        mi('$kTitle 当前站另一条', '$kCurrent:2'),
      ]),
      hitOf(kOtherA, <MediaItem>[mi('$kTitle 甲站版本', '$kOtherA:1')]),
      hitOf(kOtherB, <MediaItem>[mi('$kTitle 乙站版本', '$kOtherB:1')]),
    ]));

    await openSheet(t, currentProvider: kCurrent);

    // ── 铁律 149：先证明"有别的源真的渲染了" ──
    expectExactlyOne(t, kOtherA, '另外两个源必须照常渲染，否则下面断言恒真');
    expectExactlyOne(t, kOtherB, '另外两个源必须照常渲染，否则下面断言恒真');
    expectExactlyOne(t, '$kTitle 甲站版本', '甲站的候选条目必须可见');

    // ── 主判据：当前源整组不在 ──
    expectNone(t, kCurrent, '★★★ 当前源不许作为候选出现（Owner 明确要求排除当前片源）');
    expectNone(t, '$kTitle 当前站版本', '★★ 当前源的条目也不许出现（只排 item 不排源是半吊子修法）');
    expectNone(t, '$kTitle 当前站另一条', '★★ 同上：该组的**每条**都不许出现');
  });

  testWidgets('★★★ 阴性对照：只有当前源 ⇒ 如实说"没有找到其他源"，不许回退列出当前源',
      (t) async {
    debugSetSwitchSearchRunner(runnerOf(<SearchStreamEvent>[
      hitOf(kCurrent, <MediaItem>[mi('$kTitle 当前站版本', '$kCurrent:1')]),
    ]));

    await openSheet(t, currentProvider: kCurrent);

    expectExactlyOne(t, '没有找到其他源', '★★★ 排空后必须如实说，而不是把当前源列回来');
    expectNone(t, kCurrent, '★★★ 排空后更不许把当前源又列出来（最常见的假修）');
    expectNone(t, '$kTitle 当前站版本', '★ 同上，条目也不许漏出来');
  });

  testWidgets('★★ 非当前源不受牵连：两组源都还在（防"过滤写成清空整表"）', (t) async {
    debugSetSwitchSearchRunner(runnerOf(<SearchStreamEvent>[
      hitOf(kOtherA, <MediaItem>[mi('$kTitle 甲站版本', '$kOtherA:1')]),
      hitOf(kOtherB, <MediaItem>[mi('$kTitle 乙站版本', '$kOtherB:1')]),
    ]));

    await openSheet(t, currentProvider: kCurrent);

    expectExactlyOne(t, kOtherA, '★★ 甲站必须在（没有当前源可排时也不许清空）');
    expectExactlyOne(t, kOtherB, '★★ 乙站必须在');
  });

  testWidgets('★★ 排的是 provider 维度：当前源内任意条目都不作为候选（不是只排一条）',
      (t) async {
    debugSetSwitchSearchRunner(runnerOf(<SearchStreamEvent>[
      hitOf(kCurrent, <MediaItem>[
        mi('甲条目', '$kCurrent:a'),
        mi('乙条目', '$kCurrent:b'),
        mi('丙条目', '$kCurrent:c'),
      ]),
      hitOf(kOtherA, <MediaItem>[mi('$kTitle 甲站版本', '$kOtherA:1')]),
    ]));

    await openSheet(t, currentProvider: kCurrent);

    expectExactlyOne(t, kOtherA, '对照组必须先渲染出来');
    for (final label in <String>['甲条目', '乙条目', '丙条目']) {
      expectNone(t, label, '★★ 当前源的「$label」不许出现 —— 排的是整个源，不是某一条');
    }
  });
}