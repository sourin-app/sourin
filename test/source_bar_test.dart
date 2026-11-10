// ═══════════════════════════════════════════════════════════════════════
//  首页源条 SourceBar —— 四条用户要求的回归测试
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户原话（验收标准）
//
// > 左上角和这个源切换,还是跟底部的不太一样,然后这个源切换,
// > 随着页面滚动也没有媳妇(吸附)在顶部,最右侧也没显示有多少个源,
// > 鼠标拖动,也不能左右滑动
//
// 拆成 4 条：
// ```text
// ① 2026-11-08：实际 Miuix 控件在亮暗主题下保持可读选择态
// ② 滚动时**吸附在顶部**（sticky）
// ③ 最右侧显示**有多少个源**
// ④ **鼠标拖拽**能左右滑动
// ```
//
// # ⚠️ 为什么这些测试值得写（而不是只截图看）
//
// ④ 尤其重要：`ScrollConfiguration.dragDevices` 是 **Flutter 手势竞技场
// 真正读取的那个值** —— 用 `PointerDeviceKind.mouse` 派发真实指针事件，
// 走到的是**生产代码的同一条路径**（不是我复刻的影子实现）。
//
// 而截图验证这条**很不可靠**：本机有别的进程（DSH 自己）不断抢焦点，
// 合成的鼠标拖拽经常落空 —— 我实测时 `cursorOverApp=False`，
// 拖拽根本没到达应用。所以**行为类断言交给 widget test**，
// 截图只用来确认"观感"这一类无法断言的东西。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

/// 造 N 个假源（只用得到 id / name；其余字段不影响源条渲染）
List<ProviderManifest> _sources(int n) => [
  for (var i = 0; i < n; i++)
    ProviderManifest(id: 'src-$i', name: '源$i', enabled: true),
];

Widget _host(Widget child, {ThemeData? theme}) {
  // Each test selects the production light/dark Miuix theme explicitly.
  final data = theme ?? AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: data,
    builder: (_, c) => AppThemeHost(data: data, child: c ?? const SizedBox()),
    home: AppScaffold(child: Center(child: child)),
  );
}

Color _surfaceColor(WidgetTester tester, Finder pill) {
  final panel = tester.widget<miuix.MiuixGlassPanel>(
    find.descendant(of: pill, matching: find.byType(miuix.MiuixGlassPanel)),
  );
  final colors = miuix.MiuixTheme.of(tester.element(pill)).colors;
  return Color.alphaBlend(panel.fill!, colors.background);
}

Color _textColor(WidgetTester tester, String label) {
  final text = find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText() == label,
  );
  expect(text, findsOneWidget);
  final paint = tester.renderObject<RenderParagraph>(text);
  expect(paint.text.style?.color, isNotNull);
  return paint.text.style!.color!;
}

double _contrast(Color foreground, Color background) {
  final a = Color.alphaBlend(foreground, background).computeLuminance();
  final b = background.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}

Finder _pill(String label) => find.widgetWithText(SourcePill, label);

void main() {
  setUp(UiPrefs.debugResetForTest);
  tearDown(UiPrefs.debugResetForTest);
  group('源条 —— 基本显示规则', () {
    testWidgets('单源也渲染实际 Miuix 源条', (t) async {
      await t.pumpWidget(
        _host(
          SourceBar(sources: _sources(1), current: 'src-0', onSelect: (_) {}),
        ),
      );
      await t.pumpAndSettle();

      expect(
        find.text('源0'),
        findsOneWidget,
        reason:
            'Owner 2026-10-31 逐字：「首页就算只有一个源也要显示那个'
            '液态选择的」—— 原版 `sources.length > 1` 的隐藏行为已推翻。\n'
            '单源默认选中；点击重选被 `_switchSource` 的同源守卫短路，无害。',
      );
    });

    testWidgets('多个源同时显示', (t) async {
      await t.pumpWidget(
        _host(
          SourceBar(sources: _sources(2), current: 'src-0', onSelect: (_) {}),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('源0'), findsOneWidget);
      expect(find.text('源1'), findsOneWidget);
    });

    testWidgets('★ 点击 pill 回调选中（点击不能被拖拽支持破坏）', (t) async {
      String? picked;
      await t.pumpWidget(
        _host(
          SourceBar(
            sources: _sources(4),
            current: 'src-0',
            onSelect: (id) => picked = id,
          ),
        ),
      );
      await t.pumpAndSettle();

      await t.tap(find.text('源2'));
      await t.pumpAndSettle();

      expect(
        picked,
        'src-2',
        reason:
            '★ 加了 mouse 拖拽后，点击仍必须能选中 —— '
            '手势竞技场按"是否超过拖拽阈值"裁决，短按应该是点击赢',
      );
    });
  });

  group('源数量显示（用户要求 ③）', () {
    testWidgets('★ 源 > 3 时显示「N 个源」', (t) async {
      await t.pumpWidget(
        _host(
          SourceBar(sources: _sources(25), current: 'src-0', onSelect: (_) {}),
        ),
      );
      await t.pumpAndSettle();

      expect(
        find.textContaining('个源'),
        findsOneWidget,
        reason: '用户明确要求「最右侧也没显示有多少个源」',
      );
      /*
       * ⚠️ 数量是用 `Text.rich` 画的（两个 TextSpan：数字 + " 个源"），
       *    所以 `find.text('25')` **匹配不到**（它只匹配纯 Text）。
       *    要断 RichText 的 plain text。
       */
      final rich = find.byType(RichText);
      final texts = <String>[];
      for (final el in collectAllElementsFrom(
        t.binding.rootElement!,
        skipOffstage: false,
      )) {
        final w = el.widget;
        if (w is RichText) texts.add(w.text.toPlainText());
      }
      expect(
        texts.any((s) => s.contains('25')),
        isTrue,
        reason:
            '★ 要显示**真实数量**（25 个源 → 文本里得有 25）。'
            '当前所有 RichText: $texts',
      );
    });

    testWidgets('★ 源 ≤ 3 时不显示（原版 showCount 是 > 3）', (t) async {
      await t.pumpWidget(
        _host(
          SourceBar(sources: _sources(3), current: 'src-0', onSelect: (_) {}),
        ),
      );
      await t.pumpAndSettle();

      expect(
        find.textContaining('个源'),
        findsNothing,
        reason:
            '原版 `showCount = sources.length > 3` —— '
            '3 个源一眼数完，再挂个计数是噪音',
      );
    });
  });

  group('鼠标拖拽横滑（用户要求 ④）', () {
    testWidgets('★★ 用**鼠标**拖拽能滚动源条', (t) async {
      /*
       * # 这是本文件最重要的测试
       *
       * Flutter 的 `ScrollBehavior.dragDevices` **默认只含 touch/stylus**
       * —— 鼠标只能滚轮，拖拽不滚动。这正是用户报的
       * 「鼠标拖动,也不能左右滑动」。
       *
       * 修法是 `ScrollConfiguration(behavior: ...copyWith(dragDevices: {mouse, ...}))`。
       *
       * ⚠️ 断言的是**真实 Scrollable 的 offset 变化** ——
       *    不是"源码里写了 dragDevices"（那是静态断言，证明不了运行时生效）。
       */
      await t.pumpWidget(
        _host(
          SizedBox(
            width: 400, // 故意比内容窄 → 必然可滚
            child: SourceBar(
              sources: _sources(25),
              current: 'src-0',
              onSelect: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      final pos = t.state<ScrollableState>(scrollable).position;
      final before = pos.pixels;
      expect(
        pos.maxScrollExtent,
        greaterThan(0),
        reason: '前置条件：内容宽度必须超出容器，否则无从验证滚动',
      );

      // ── 用**鼠标**拖拽（不是 touch）──
      final center = t.getCenter(scrollable);
      final g = await t.startGesture(center, kind: PointerDeviceKind.mouse);
      // 分步移动（一步到位可能被判定为 fling 之外的行为）
      for (var i = 1; i <= 6; i++) {
        await g.moveBy(Offset(-40, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pumpAndSettle();

      final after = pos.pixels;
      expect(
        after,
        greaterThan(before),
        reason:
            '★ 鼠标向左拖拽后 offset 必须增大（内容往左滚）—— '
            '没变说明 `dragDevices` 没生效，用户仍"不能左右滑动"',
      );
    });

    testWidgets('★ 触摸拖拽也仍然可用（不能为了鼠标破坏触摸）', (t) async {
      await t.pumpWidget(
        _host(
          SizedBox(
            width: 400,
            child: SourceBar(
              sources: _sources(25),
              current: 'src-0',
              onSelect: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      final pos = t.state<ScrollableState>(scrollable).position;
      final before = pos.pixels;

      final g = await t.startGesture(
        t.getCenter(scrollable),
        kind: PointerDeviceKind.touch,
      );
      for (var i = 1; i <= 6; i++) {
        await g.moveBy(const Offset(-40, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pumpAndSettle();

      expect(pos.pixels, greaterThan(before), reason: '触摸端拖拽是移动端的标准操作，不能被改坏');
    });
  });

  group('滚动吸附在顶部（用户要求 ②）', () {
    testWidgets('★★ 用真实 CustomScrollView 验证 pinned header 会钉住', (t) async {
      /*
       * # 这条测的是**运行时的钉住行为**，不是"源码里写了 pinned: true"
       *
       * 手法：搭一个和首页同构的最小滚动视图（CustomScrollView +
       * `SliverPersistentHeader(pinned: true)` + 一个很长的列表），
       * 然后**真的滚**，断言源条的位置没变。
       *
       * ⚠️ 为什么不直接构造 `HomePage`：它依赖 `SourinApi`（要走 FFI 核心），
       *    `flutter_test` 里跑不起来。所以这里验证的是**结构契约**
       *    （pinned sliver 确实会钉住），而首页真的用了这个结构
       *    由下面那条静态断言保证 —— 两条合起来才完整。
       */
      const barH = 44.0 + 16; // 源条 44 + 上下各 8

      await t.pumpWidget(
        _host(
          SizedBox(
            width: 500,
            height: 400,
            child: CustomScrollView(
              slivers: [
                // 源条上方的"我的"版块（高 200，会被滚上去）
                const SliverToBoxAdapter(child: SizedBox(height: 200)),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TestHeader(
                    extent: barH,
                    child: SizedBox(
                      height: barH,
                      child: SourceBar(
                        sources: _sources(5),
                        current: 'src-0',
                        onSelect: (_) {},
                      ),
                    ),
                  ),
                ),
                // 一段足够长的内容，保证能滚
                SliverList(
                  delegate: SliverChildListDelegate([
                    for (var i = 0; i < 30; i++)
                      const SizedBox(height: 60, child: Text('content')),
                  ]),
                ),
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      final barFinder = find.byType(SourceBar);
      final startTop = t.getTopLeft(barFinder).dy;

      /*
       * ⚠️ 修正过的断言（第一版写错了，自己抓到的）
       *
       * # pinned 的**正确语义**
       *
       * ```text
       * 滚动初期  源条跟着往上走（它上面还有"我的"要滚出去）
       * 到达顶部  **停住不动**，后面的内容从它下面滚过  ← 这才是"吸附"
       * ```
       * 我第一版断言"滚动后位置 == 初始位置" —— 那**不是** pinned，
       * 那是"永远不动的悬浮层"。测试因此假失败
       * （实际 `300 → 100`：源条确实滚上去了，然后钉住）。
       *
       * # 正确断言：**滚很多之后位置不再变化**
       *
       * ```text
       * 滚一小段  → 位置变了（还在往上走）      ✓ 符合预期
       * 滚很多    → 位置**不再变**（已钉住）    ✓ 这才是 pinned 的证据
       * ```
       */
      /*
       * ⚠️ 这条测试**改过两次断言**，两次都是我写错了语义。
       *
       * # 第一次错：断言"滚动后位置 == 初始位置"
       * ```text
       * 实际 300 → 100（假失败）
       * ```
       * 那**不是** pinned 的语义 —— pinned 是"滚到顶就**停住**"，
       * 不是"永远不动"。
       *
       * # 第二次错：以为"滚一小段后位置就不该再变"
       * ```text
       * 滚 80px   → 300 → 220（还在正常上移）
       * 滚 260px  → 220 → 100（继续上移才到顶）
       * ```
       * 源条到顶需要滚掉它上方那 200px 的"我的"版块 +
       * 自身在 viewport 里的偏移，**一次 drag 到不了**。
       *
       * # 正确的做法：**滚到不能再滚**，然后断言位置不再变
       *
       * 不断滚动直到 scroll offset 到达 maxScrollExtent（滚到底），
       * 此时 pinned header **必然**已经钉住。再滚一次，位置必须不变。
       * 这样断言与"滚多少才到顶"解耦，不会因为我猜错距离而假失败。
       */
      final scrollable = find.byType(Scrollable).first;
      final pos = t.state<ScrollableState>(scrollable).position;

      /*
       * ⚠️ 不要用 `t.drag(find.text('content').first, ...)` 反复滚 ——
       *    那个 widget 滚出屏幕后就**点不到了**，报
       *    "Maybe the widget is actually off-screen"（我踩了这个坑）。
       *
       * 正确做法：直接操作 `ScrollPosition` ——
       * 这是**确定性**的，不受"哪个 widget 当前可见"影响。
       */
      var guard = 0;
      while (pos.pixels < pos.maxScrollExtent - 1 && guard < 20) {
        pos.jumpTo((pos.pixels + 300).clamp(0.0, pos.maxScrollExtent));
        await t.pumpAndSettle();
        guard++;
      }
      expect(
        pos.pixels,
        closeTo(pos.maxScrollExtent, 1.0),
        reason:
            '前置条件：必须滚到底（当前 ${pos.pixels} / '
            '${pos.maxScrollExtent}，滚了 $guard 次）',
      );

      final atBottom = t.getTopLeft(barFinder).dy;

      /*
       * 到底之后再滚一次 —— 位置必须**完全不变**。
       *
       * ⚠️ 滚到底时 `maxScrollExtent` 已经达到，`drag` 不会真的改变
       *    offset —— 所以这一步验证的是"钉住之后不会因为任何滚动而移位"。
       */
      pos.jumpTo(pos.maxScrollExtent);
      await t.pumpAndSettle();
      final afterMore = t.getTopLeft(barFinder).dy;

      expect(
        afterMore,
        closeTo(atBottom, 0.5),
        reason:
            '★★ 滚到底后源条必须**钉住不动** —— '
            '这就是用户要的「随着页面滚动吸附在顶部」。'
            ' 到底时=$atBottom 再滚后=$afterMore',
      );

      /*
       * 关键：它必须真的**贴在滚动视图的顶部**，而不是"停在中间"。
       *
       * ⚠️ 不能用绝对坐标 `dy ≈ 0` 判 —— 测试里那个 400px 高的
       *    `SizedBox` 是**居中**在 800px 测试画布里的，所以滚动视口的
       *    顶边在 dy≈100（我第一版写死 0，假失败）。
       *
       * 正确做法：拿**滚动视口自己的顶边**当基准。
       */
      final viewportTop = t.getTopLeft(scrollable).dy;
      expect(
        atBottom,
        closeTo(viewportTop, 1.0),
        reason:
            '★ 钉住的位置必须是**滚动视口的顶边**（视口顶边=$viewportTop，'
            '源条=$atBottom）—— 停在别处说明只是"跟着滚"，不是吸附',
      );

      // 吸附的意义：一直可见
      expect(barFinder, findsOneWidget, reason: '★ 吸附之后源条必须仍在屏幕上');
      expect(
        t.getRect(barFinder).height,
        greaterThan(0),
        reason: '源条高度不能为 0（被压扁就等于看不见）',
      );
    });
  });

  group('结构契约（与上面那条配套）', () {
    late String home;

    setUpAll(() {
      home = File('lib/ui/home_page.dart').readAsStringSync();
    });

    test('★★ 首页必须用 CustomScrollView + pinned SliverPersistentHeader', () {
      /*
       * `ListView` 做不到吸附 —— 它的子项都是平级的，没有一个能"钉住"。
       * 必须换成 sliver 体系。
       */
      expect(
        home.contains('CustomScrollView('),
        isTrue,
        reason: '★ 必须换成 CustomScrollView —— ListView 无法做 sticky',
      );
      expect(
        home.contains('SliverPersistentHeader('),
        isTrue,
        reason: '★ 源条必须包在 SliverPersistentHeader 里',
      );
      expect(
        home.contains('pinned: true'),
        isTrue,
        reason:
            '★ 必须 pinned: true —— 这是"吸附"的关键；'
            'pinned: false 会跟着滚走',
      );
      expect(
        home.contains('ListView(') && !home.contains('CustomScrollView('),
        isFalse,
        reason: '不应退回 ListView',
      );
    });

    test('★ minExtent 必须等于 maxExtent（否则会随滚动伸缩）', () {
      /*
       * `SliverPersistentHeader` 的默认行为是把"手势位移"映射成
       * extent 变化 —— 那是给"可折叠大标题"用的。
       * 源条要的是**固定高度**，两个 extent 必须相等。
       */
      expect(
        home.contains('double get minExtent => _extent'),
        isTrue,
        reason: 'minExtent 应是固定常量',
      );
      expect(
        home.contains('double get maxExtent => _extent'),
        isTrue,
        reason: 'maxExtent 必须与 minExtent 相同',
      );
    });

    test('★ SourceBar 必须带 GlobalKey（否则滚动时丢滚动位置）', () {
      expect(
        home.contains('sourceBarKey'),
        isTrue,
        reason:
            '★ `SliverPersistentHeaderDelegate.build()` 会被反复调用，'
            '没有 GlobalKey 的话 SourceBar 的 State 可能被重建 —— '
            'ScrollController 重置 → 用户滚到第 10 个源一滚动就跳回第 1 个',
      );
    });
  });
  group('Miuix 源条实际绘制与键盘交互', () {
    for (final brightness in Brightness.values) {
      testWidgets('选中和未选中源的文字与实际底色可读 / $brightness', (t) async {
        await t.pumpWidget(
          _host(
            SourceBar(sources: _sources(4), current: 'src-1', onSelect: (_) {}),
            theme: AppTheme.themeFor(brightness),
          ),
        );
        await t.pumpAndSettle();
        expect(find.byType(miuix.MiuixCard), findsNothing);
        expect(find.byType(miuix.MiuixButton), findsNWidgets(4));
        final colors = miuix.MiuixTheme.of(t.element(_pill('源1'))).colors;
        for (final label in ['源0', '源1']) {
          final selected = label == '源1';
          final surface = _surfaceColor(t, _pill(label));
          final text = _textColor(t, label);
          expect(
            surface,
            selected
                ? Color.alphaBlend(
                    colors.primary.withValues(
                      alpha: brightness == Brightness.dark ? .20 : .09,
                    ),
                    colors.surface,
                  )
                : Color.alphaBlend(
                    colors.surface.withValues(alpha: .72),
                    colors.background,
                  ),
          );
          expect(
            text,
            selected
                ? (brightness == Brightness.dark
                      ? const Color(0xff9dbfff)
                      : Color.alphaBlend(
                          const Color(0x1f000000),
                          colors.primary,
                        ))
                : colors.onSurfaceSecondary,
          );
          expect(_contrast(text, surface), greaterThanOrEqualTo(4.5));
        }
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('已挂载源条在亮暗往返中保留选择、滚动与焦点', (t) async {
      final brightness = ValueNotifier(Brightness.light);
      addTearDown(brightness.dispose);
      var current = 'src-0';
      final selected = <String>[];
      await t.pumpWidget(
        ValueListenableBuilder<Brightness>(
          valueListenable: brightness,
          builder: (_, value, child) => _host(
            StatefulBuilder(
              builder: (_, setState) => SizedBox(
                width: 400,
                child: SourceBar(
                  sources: _sources(12),
                  current: current,
                  onSelect: (id) => setState(() {
                    current = id;
                    selected.add(id);
                  }),
                ),
              ),
            ),
            theme: AppTheme.themeFor(value),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('源1'));
      await t.pumpAndSettle();
      expect(selected, ['src-1']);
      final scroll = t.state<ScrollableState>(find.byType(Scrollable)).position;
      scroll.jumpTo(35);
      await t.pump();
      final offset = scroll.pixels;
      final originalBar = t.element(find.byType(SourceBar));
      final innerFocus = Focus.of(t.element(find.text('源1')));
      final focus = [
        innerFocus,
        ...innerFocus.ancestors,
      ].firstWhere((node) => node.canRequestFocus);
      focus.requestFocus();
      await t.pump();
      expect(focus.hasPrimaryFocus, isTrue);
      final unselectedPaint = <Brightness, Color>{};
      for (final mode in [Brightness.dark, Brightness.light]) {
        brightness.value = mode;
        await t.pumpAndSettle();
        expect(t.element(find.byType(SourceBar)), same(originalBar));
        expect(t.widget<SourceBar>(find.byType(SourceBar)).current, 'src-1');
        expect(scroll.pixels, closeTo(offset, .01));
        expect(FocusManager.instance.primaryFocus, same(focus));
        final colors = miuix.MiuixTheme.of(t.element(_pill('源1'))).colors;
        expect(
          _surfaceColor(t, _pill('源1')),
          Color.alphaBlend(
            colors.primary.withValues(
              alpha: mode == Brightness.dark ? .20 : .09,
            ),
            colors.surface,
          ),
        );
        expect(
          _textColor(t, '源1'),
          mode == Brightness.dark
              ? const Color(0xff9dbfff)
              : Color.alphaBlend(const Color(0x1f000000), colors.primary),
        );
        final surface = _surfaceColor(t, _pill('源0'));
        unselectedPaint[mode] = surface;
        expect(
          surface,
          Color.alphaBlend(
            colors.surface.withValues(alpha: .72),
            colors.background,
          ),
        );
        expect(
          _contrast(_textColor(t, '源0'), surface),
          greaterThanOrEqualTo(4.5),
        );
      }
      expect(
        unselectedPaint[Brightness.dark],
        isNot(unselectedPaint[Brightness.light]),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.select);
      await t.pumpAndSettle();
      expect(selected, ['src-1', 'src-1']);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(selected, ['src-1', 'src-1', 'src-2']);
      expect(t.widget<SourceBar>(find.byType(SourceBar)).current, 'src-2');
      expect(t.takeException(), isNull);
    });
  });
}

/// 测试用的 pinned header delegate（与首页 `_StickySourceBar` 同构）
class _TestHeader extends SliverPersistentHeaderDelegate {
  _TestHeader({required this.extent, required this.child});

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext c, double o, bool over) => child;

  @override
  bool shouldRebuild(_TestHeader old) => old.child != child;
}
