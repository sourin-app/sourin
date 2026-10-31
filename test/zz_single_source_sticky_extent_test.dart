// ═══════════════════════════════════════════════════════════════════════
//  单源吸附头 extent —— **把上一层（SliverPersistentHeader）也钉住**
//  （批次 T4 收尾补漏，2026-10-31）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 首页就算只有一个源也要显示那个液态选择的
// ```
//
// # 这条门禁补的是**上一次漏掉的那一层**
//
// ```text
// commit 6452525 做了什么      删掉 source_bar.dart 里的单源早退
//                              （`if (sources.length <= 1) return SizedBox.shrink()`）
// 漏了什么                     home_page.dart 的吸附头 extent 门控
//                              `_StickySourceBar.extentFor`:
//                                  visibleCount <= 1 ? 0 : _extent
// 真机表现                     单源 ⇒ extent = 0 ⇒ SliverPersistentHeader
//                              高度压成 0 ⇒ 玻璃条/药丸**肉眼完全看不到**
//                              （截图 .probe/shots/batch-20261031/13-home-top.png：
//                               「我的」分段控件下方直接是 shelf，零玻璃条）
// ```
//
// ⚠️ 为什么 `zz_source_pill_unify_test.dart` 抓不到它（**漏网的机制**）
// ```text
// 那条只有两个判据：
//   ① 直接挂 SourceBar(sources: 1 个) ⇒ 见到一颗 SourcePill
//   ② 静态：源码里没有那种早退
// 两条都成立的时候，**外层那个 SliverPersistentHeader 仍然可以把
// 整条压成 0 高度** —— 源条自己会画、但宿主不给它任何空间。
// ⇒ ★ 判据必须升到**宿主那层**（量 extent / 量渲染后的几何），
//    不能停在"组件自己能画出来"这一层。
// ```
//
// # 本文件守的三条（各有一条独立的牙）
// ```text
// ① 静态：`extentFor` **不许**再出现 `visibleCount <= 1 ? 0` 这种门控
//    —— 那是本次漏改的字面形状（注入 A 就是把 `== 0` 改回 `<= 1 ? 0`）
// ② 运行时：**生产那一个 delegate**（`debugStickySourceBar()` 注入点取出的
//    _StickySourceBar，不是测试自己复刻的 delegate）在单源时
//    minExtent == maxExtent == 60（≠ 0）
//    —— instrument 与被测对象是同一个东西（同 debugHomeReadout 的纪律）
// ③ 运行时几何：真挂一个 CustomScrollView + SliverPersistentHeader +
//    单源 SourceBar，滚到底后 RenderSliverPinnedPersistentHeader 的
//    paintExtent **非零**，且 `SourceBar` 真的能找到
//    —— 这一条同时是旧 `paintExtent 16.0 vs layoutExtent 60.0` 非法几何的回归哨兵
// ```
//
// # 为什么 ②不用"再写一份 delegate"
// ```text
// 复刻一份 ⇒ 产品改动 prod 代码时测试不知道（那正是这次事故的成因：
//           source_bar 已经改了，可谁也没想到 home_page 还有个门控）
// ⇒ 判据必须落在**生产那一个对象**上。
// ```
//
// Flutter SDK：flutter（3.47.5）
// 跑法：flutter test --concurrency=1 test/zz_single_source_sticky_extent_test.dart

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';

/// 去注释（状态机）：**与 `zz_source_pill_unify_test.dart` 同一份实现纪律**
///
/// ⚠️ 静态判据必须**先去注释**再匹配：本批改后 home_page 的注释里很可能
///    写着 `<= 1 ? 0`（历史注脚），裸 contains 会拿注释当实现（假红/假绿）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (quote != null) {
      if (c == '\\') {
        out.write(c);
        if (next.isNotEmpty) out.write(next);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 假源（只用得到 id / name / capabilities.vod —— 后两者决定它是否现身）
List<ProviderManifest> _sources(int n) => [
      for (var i = 0; i < n; i++)
        ProviderManifest(
          id: 'src-$i',
          name: '源$i',
          capabilities: const Capabilities(vod: true),
        ),
    ];

Widget _host(Widget child) {
  final data = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: data,
    builder: (_, c) => AppThemeHost(data: data, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 静态：`extentFor` 不许再有"少于 2 个源 ⇒ 0"的门控
  // ═══════════════════════════════════════════════════════════════════
  group('① 源码契约：吸附头 extent 不许按源数门槛归零', () {
    late String home;

    setUpAll(() {
      home = stripComments(File('lib/ui/home_page.dart').readAsStringSync());
    });

    test('★★ `extentFor` 必须无条件返回 `_extent`（含单源）', () {
      /*
       * # 本次漏改的字面形状
       * ```dart
       * static double extentFor(int visibleCount) =>
       *     visibleCount <= 1 ? 0 : _extent;      // ← 改前
       * ```
       * 它与 `source_bar.dart` 的旧早退（`length <= 1 ⇒ shrink`）
       * 是**同一个旧语义的两处实现**。上一版只删了后者 ⇒ 单源时
       * 源条自己会画，可宿主把它压成 0 高度 ⇒ 肉眼完全看不到。
       *
       * ⇒ 这里直接钉**没有这个三元门控**：谁把它加回来，当场红。
       */
      final i = home.indexOf('static double extentFor');
      expect(i > 0, isTrue,
          reason: '★ 前置：`extentFor` 必须还在（挪了/改名了就改这里）');
      final decl = home.substring(i, (i + 200).clamp(0, home.length));

      expect(decl.contains('visibleCount <= 1'), isFalse,
          reason: '★★★ Owner 逐字：「首页就算只有一个源也要显示那个液态选择的」。\n'
              '`extentFor` 里出现 `visibleCount <= 1` ⇒ 单源时 extent 被压成 0，\n'
              '宿主不给它任何高度 ⇒ 用户看到的仍然是「没有源条」（本次漏改原样）。');
      expect(decl.contains('visibleCount < 2'), isFalse,
          reason: '★★★ `extentFor` 里出现 `visibleCount < 2` —— '
              '与 `<= 1` 是同一个旧门槛的另一种写法，同样会把单源压成 0。');
      expect(decl.contains('visibleCount <='), isFalse,
          reason: '★★★ `extentFor` 不许再用 `<=` 当门槛 —— '
              '门槛必须是 `== 0`（一个可用源都没有才是真没有），不是 <= 1/<= 0。');
      expect(
        decl.contains(RegExp(r'visibleCount\s*==\s*0\s*\?\s*0\s*:\s*_extent')),
        isTrue,
        reason: '★★★ `extentFor` 必须**逐字**是这个形状：'
            '`visibleCount == 0 ? 0 : _extent` ——\n'
            '门槛只允许是「零源」；任何别的分支形状都要人现场判定，\n'
            '那正是本文件存在的理由（防再出一次"只改一半"的漏改）。\n'
            '实际 decl：$decl',
      );
    });

    test('★ 调用方传的 visibleCount 与 SourceBar 同源（不许另算一套）', () {
      expect(home.contains('visibleCount: visibleSourceList(_enabled).length'),
          isTrue,
          reason: '★ 吸附头的 extent 判据必须与 `SourceBar` 用同一份过滤结果 —— '
              '两处各写一遍必然漂（这正是 `_StickySourceBar` 那段注释的教训）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 运行时：**生产那一个 delegate** 在单源时 extent ≠ 0
  // ═══════════════════════════════════════════════════════════════════
  group('② 生产 delegate（非复刻）在单源时的 extent 读数', () {
    testWidgets('★★★ visibleCount == 1 ⇒ minExtent == maxExtent == 60（≠ 0）',
        (t) async {
      /*
       * ★★★ 为什么必须拿**产品那个 delegate**
       *
       * `test/source_bar_test.dart` 里有一个 `_TestHeader`（同构复刻）——
       * 它再像也不是产品代码：产品把 `extentFor` 改回 `<= 1 ? 0` 时，
       * 那个 `_TestHeader` **照样绿**。本次事故就是这么发生的。
       * ⇒ 用 `debugStickySourceBar()` 取**生产类本身**的实例。
       */
      final one = _sources(1);
      final prod = debugStickySourceBar(
        visibleCount: visibleSourceList(one).length,
        sources: one,
        current: 'src-0',
        onSelect: (_) {},
      );

      final callCount = visibleSourceList(one).length;
      expect(callCount, 1,
          reason: '★ 前置：这次要量的就是**单源**形态（拿到 $callCount）');

      expect(prod.minExtent, greaterThan(0),
          reason: '★★★ 单源时 minExtent 必须 > 0（实测 ${prod.minExtent}）—— '
              'Owner 逐字：「首页就算只有一个源也要显示那个液态选择的」。\n'
              '把 extentFor 改回 `<= 1 ? 0` ⇒ 这里是 0 ⇒ 当场红。');
      expect(prod.maxExtent, prod.minExtent,
          reason: '★ min == max（否则会随滚动伸缩 —— source_bar_test 那条同理）');
      expect(prod.maxExtent, closeTo(60, 0.01),
          reason: '★ 必须是源条自身 44 + 上下各 8 的呼吸空间（实测 ${prod.maxExtent}）');
      // delegate 必须能真 build：单源时它必须返回**给了 Padding** 的那一条
      // （44 + 8 + 8），而不是裸 child（那是 `_extentNow == 0` 的分支）
      final built = prod.build(t.binding.rootElement!, 0, false);
      expect(built, isNotNull,
          reason: '★ delegate 必须能真 build（单源时不能返回 null）');
      expect(built, isA<Padding>(),
          reason: '★★ 单源时 build 必须走**给了 Padding** 的那条分支 —— '
              '走另一条（裸 child）说明源码里 `_extentNow == 0`，'
              '即 extent 仍被压成 0 ⇒ childExtent 44 vs maxExtent 60 ⇒ 非法几何');

      // 多源对照：不能因为放开单源就把多源改矮了
      final many = _sources(3);
      final prodMany = debugStickySourceBar(
        visibleCount: visibleSourceList(many).length,
        sources: many,
        current: 'src-1',
        onSelect: (_) {},
      );
      expect(prodMany.maxExtent, prod.maxExtent,
          reason: '★ 多源形态的 extent 必须与单源一致（放开单源不许动到多源）');
    });

    testWidgets('★ 一个可用源都没有 ⇒ 仍然可以为 0（这条不是本次改的范围）',
        (t) async {
      final none = <ProviderManifest>[];
      final prod = debugStickySourceBar(
        visibleCount: visibleSourceList(none).length,
        sources: none,
        current: '',
        onSelect: (_) {},
      );
      expect(visibleSourceList(none).length, 0, reason: '★ 前置：零源');
      // ⚠️ 本条**不断言** 0 或非 0 —— 真没有源时两条 UI 都说得通，
      //    本次任务只改单源口径。这里仅把读数打出来，供回归对比。
      // ignore: avoid_print
      print('[EXTENT] 零源读数：min=${prod.minExtent} max=${prod.maxExtent}');
      expect(prod.maxExtent, prod.minExtent,
          reason: '★ 无论取什么值，min 必须等于 max（非法几何的源头）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 几何：真挂起来滚一次，单源必须**真的占高度**
  // ═══════════════════════════════════════════════════════════════════
  group('③ 真挂载：单源时吸附头必须真的有高度（不是 0）', () {
    testWidgets('★★★ 单源 ⇒ header 的 paintExtent > 0 且找得到 SourceBar',
        (t) async {
      final one = _sources(1);

      await t.pumpWidget(_host(
        SizedBox(
          width: 520,
          height: 400,
          child: CustomScrollView(
            slivers: [
              // 「我的」版块（高 200，会被滚上去）
              const SliverToBoxAdapter(child: SizedBox(height: 200)),
              SliverPersistentHeader(
                pinned: true,
                delegate: debugStickySourceBar(
                  visibleCount: visibleSourceList(one).length,
                  sources: one,
                  current: 'src-0',
                  onSelect: (_) {},
                ),
              ),
              SliverList(
                delegate: SliverChildListDelegate([
                  for (var i = 0; i < 30; i++)
                    const SizedBox(height: 60, child: Text('content')),
                ]),
              ),
            ],
          ),
        ),
      ));
      await t.pumpAndSettle();

      // ① 源条 widget 必须存在（source_bar 那层早退已经删了 ⇒ 这条本来就绿）
      expect(find.byType(SourceBar), findsOneWidget,
          reason: '★ 前置：单源时 SourceBar 本身已渲染'
              '（由 zz_source_pill_unify_test.dart 那条守）');
      expect(find.text('源0'), findsOneWidget,
          reason: '★ 单源那颗药丸必须在');

      // ② ★★★ 关键：宿主（persistent header）的几何必须非零
      final headers = <RenderSliverPinnedPersistentHeader>[];
      for (final e in t.allElements) {
        if (e.renderObject is RenderSliverPinnedPersistentHeader) {
          headers.add(e.renderObject! as RenderSliverPinnedPersistentHeader);
        }
      }
      expect(headers, isNotEmpty,
          reason: '★ 前置：树上必须有一个 pinned header（否则这条判据是空的）');

      final g = headers.first.geometry;
      expect(g, isNotNull, reason: '★ 前置：header 必须有几何');

      expect(g!.maxPaintExtent, closeTo(60, 0.01),
          reason: '★★★ 单源时 header 的 maxPaintExtent 必须是 60（实测 ${g.maxPaintExtent}）'
              ' —— 0 就是本次那个漏改（整条被压扁、肉眼看不见）。');
      expect(g.paintExtent, greaterThan(0),
          reason: '★★★ 单源时 **实际画出来的高度**必须 > 0（实测 ${g.paintExtent}）'
              ' —— 这就是用户「零玻璃条、零药丸」的直接读数。');
      expect(g.layoutExtent, greaterThan(0),
          reason: '★★★ layoutExtent 也必须 > 0（实测 ${g.layoutExtent}）'
              ' —— 为 0 意味着它不占滚动空间（源条会压在内容上）。');

      // ③ 越界哨兵：`layoutExtent > paintExtent` 就是当年那条真崩溃
      expect(g.layoutExtent <= g.paintExtent + 0.01, isTrue,
          reason: '★ SliverGeometry 合法性：layout=${g.layoutExtent} '
              'paint=${g.paintExtent} —— 越界会每帧抛异常（"到处都卡"）。');

      // ④ 滚到底之后再量一次：钉住时同样不许被压扁
      final pos = Scrollable.of(t.element(find.text('content').first)).position;
      var guard = 0;
      while (pos.pixels < pos.maxScrollExtent - 1 && guard < 40) {
        pos.jumpTo((pos.pixels + 300).clamp(0.0, pos.maxScrollExtent));
        await t.pumpAndSettle();
        guard++;
      }
      final gp = (t
              .allElements
              .firstWhere(
                  (e) => e.renderObject is RenderSliverPinnedPersistentHeader)
              .renderObject! as RenderSliverPinnedPersistentHeader)
          .geometry;
      expect(gp, isNotNull, reason: '★ 前置：滚到底后仍需有几何');
      expect(gp!.paintExtent, greaterThan(0),
          reason: '★★ 滚到底（钉住状态）时源条仍然必须**看得见**'
              '（实测 paintExtent=${gp.paintExtent}）');
      expect(gp.layoutExtent <= gp.paintExtent + 0.01, isTrue,
          reason: '★ 钉住态同样不许越界：layout=${gp.layoutExtent} '
              'paint=${gp.paintExtent}');
    });
  });
}
