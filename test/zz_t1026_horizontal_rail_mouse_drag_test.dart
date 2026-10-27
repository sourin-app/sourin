import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/sourin_scroll_behavior.dart';

class _ParentBehavior extends ScrollBehavior {
  const _ParentBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return KeyedSubtree(
      key: ValueKey('scrollbar-${details.direction}'),
      child: child,
    );
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return ClipRect(clipBehavior: Clip.none, child: child);
  }
}

void main() {
  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ 2026-10-27（Lead 裁定）：这条从**形状计数**改成**守恒律**
   * ══════════════════════════════════════════════════════════════════════
   *
   * # 改前（假绿形状）
   * ```dart
   * RegExp(r'child: SourinHorizontalRail\(\s*child: ListView\.separated\(')
   *     .allMatches(home), hasLength(2)
   * ```
   * 两个问题：
   * ```text
   * ① 它钉的是**实现形状**（"必须用 ListView.separated 且必须恰好 2 处"），
   *    不是**契约**（"每一条可交互横向轨道都必须包鼠标拖拽行为"）。
   *    ⇒ 本仓点名的假绿形状：数字对不对与"拖拽真的能用"无关。
   * ② 它把"第 3 条真实横向轨道"读成**违规** —— N9（首页聚合源二级渠道条，
   *    必须复用 SourinHorizontalRail、不许造第二套）一落地，这条就误报红。
   *    若为此把渠道条改写成另一种形状（例如换 ListView.builder）来躲开
   *    正则计数，那是**为了让门禁变绿而变形实现** —— 正是要禁止的事。
   * ```
   *
   * # 改后（守恒律，真的能红）
   * ```text
   * 遍历 home_page.dart 里**每一条** `scrollDirection: Axis.horizontal`：
   *   可交互的（physics 不是 NeverScrollableScrollPhysics）
   *     ⇒ 它的上方必须已包上 `SourinHorizontalRail(`
   *   不可交互的（骨架轨道，NeverScrollable）
   *     ⇒ 不需要包（旧04 已裁定）
   * ⇒ 违约条目数必须为 0。新增轨道忘了包行为 ⇒ 立刻红（这才是这条门禁
   *   原本想守的东西）；新增轨道**正确包了** ⇒ 不再误报。
   * ```
   *
   * ★ 判据与 `my_shelf` 那组（同文件 :405「包裹写法判据」）同一个精神：
   *   验"**包住**了那个 ListView"，不是"数够几个"。
   * ⚠️ 这条只读源码形状（静态判据），鼠标拖拽**行为**由本文件下半部分的
   *   真 widget 用例负责 —— 两者互补，缺一不可。
   */
  test('home 每条可交互横向轨道都包了 SourinHorizontalRail（守恒律，不是计数）',
      () {
    final home = File('lib/ui/home_page.dart').readAsStringSync();

    /// 每条横向 ListView 的 (行号, 是否可交互, 上方是否已包 rail)
    final offenders = <String>[];
    var interactive = 0;

    for (final m in RegExp(r'scrollDirection: Axis\.horizontal').allMatches(home)) {
      final line = home.substring(0, m.start).split('\n').length;
      // 该 ListView 自身往后一小段里的 physics 声明
      final ahead = home.substring(m.start, (m.start + 300).clamp(0, home.length));
      final isSkeleton = ahead.contains('NeverScrollableScrollPhysics');
      // 上方是否已包上行为类（包裹写法：rail 构造在 horizontal 之前）
      final behind = home.substring(
          (m.start - 400).clamp(0, home.length), m.start);
      final wrapped = behind.contains('SourinHorizontalRail(');

      if (!isSkeleton) {
        interactive++;
        if (!wrapped) {
          offenders.add('line $line（可交互横向轨道未包 SourinHorizontalRail）');
        }
      }
    }

    // ★ 反空真：一个可交互轨道都没有 ⇒ 说明上面的解析口径坏了，
    //   不能让"0 违约"在没扫到东西时也成立（铁律 149 同款）。
    expect(interactive, greaterThan(0),
        reason: '★★★ 必须至少扫到 1 条可交互横向轨道 —— '
            '扫到 0 条说明口径漂了（例如 physics 写法变了），'
            '那条"违约数为 0"就成了空真');

    expect(offenders, isEmpty,
        reason: '★★★ 每条可交互横向轨道都必须包 SourinHorizontalRail '
            '（鼠标拖拽 + 无障碍）。违约条目：$offenders');
  });

  Future<({ScrollController horizontal, ScrollController vertical})> mount(
    WidgetTester tester, {
    required VoidCallback onTap,
  }) async {
    final horizontal = ScrollController();
    final vertical = ScrollController();
    addTearDown(horizontal.dispose);
    addTearDown(vertical.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScrollConfiguration(
          behavior: const _ParentBehavior(),
          child: Column(
            children: [
              SizedBox(
                height: 140,
                child: SourinHorizontalRail(
                  child: ListView.builder(
                    key: const ValueKey('horizontal'),
                    controller: horizontal,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, index) => GestureDetector(
                      onTap: onTap,
                      child: SizedBox(
                        width: 160,
                        child: ColoredBox(
                          color: const Color(0xff224466),
                          child: Center(child: Text('card $index')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('vertical'),
                  controller: vertical,
                  itemCount: 40,
                  itemBuilder: (_, index) =>
                      SizedBox(height: 80, child: Text('row $index')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return (horizontal: horizontal, vertical: vertical);
  }

  testWidgets(
    'left mouse drag scrolls rail without activating card; click still works',
    (tester) async {
      var taps = 0;
      final controllers = await mount(tester, onTap: () => taps++);
      final rail = find.byKey(const ValueKey('horizontal'));
      await tester.tapAt(
        tester.getTopLeft(rail) + const Offset(80, 60),
        kind: PointerDeviceKind.mouse,
      );
      expect(taps, 1);
      await tester.drag(
        rail,
        const Offset(-350, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controllers.horizontal.offset, greaterThan(100));
      expect(taps, 1);
      expect(controllers.vertical.offset, 0);
    },
  );

  testWidgets(
    'parent rebuild preserves rail position and ScrollPosition identity',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      late StateSetter rebuild;
      var generation = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ScrollConfiguration(
            behavior: const _ParentBehavior(),
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return SourinHorizontalRail(
                  child: ListView.builder(
                    key: const ValueKey('rebuild-rail'),
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, index) => SizedBox(
                      width: 160,
                      child: Text('generation $generation card $index'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      controller.jumpTo(320);
      await tester.pump();
      final position = controller.position;
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      rebuild(() => generation++);
      await tester.pump();
      expect(controller.offset, 320);
      expect(controller.position, same(position));
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)),
        same(scrollable),
      );
      await tester.drag(
        find.byKey(const ValueKey('rebuild-rail')),
        const Offset(-250, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(320));
    },
  );

  testWidgets('touch and trackpad retain horizontal scrolling', (tester) async {
    final controllers = await mount(tester, onTap: () {});
    final rail = find.byKey(const ValueKey('horizontal'));
    await tester.drag(
      rail,
      const Offset(-250, 0),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();
    expect(controllers.horizontal.offset, greaterThan(0));
    controllers.horizontal.jumpTo(0);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(tester.getCenter(rail));
    await gesture.panZoomUpdate(
      tester.getCenter(rail),
      pan: const Offset(-250, 0),
    );
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
    expect(controllers.horizontal.offset, greaterThan(0));
  });

  testWidgets(
    'scrollbar suppression and mouse drag are local; parent Clip.none survives',
    (tester) async {
      final controllers = await mount(tester, onTap: () {});
      final rail = find.byKey(const ValueKey('horizontal'));
      final vertical = find.byKey(const ValueKey('vertical'));
      expect(
        find.byKey(const ValueKey('scrollbar-AxisDirection.right')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('scrollbar-AxisDirection.down')),
        findsOneWidget,
      );
      final railContext = tester.element(rail);
      const parent = _ParentBehavior();
      final local = ScrollConfiguration.of(railContext);
      expect(local.dragDevices, containsAll(parent.dragDevices));
      expect(local.dragDevices, contains(PointerDeviceKind.mouse));
      expect(
        ScrollConfiguration.of(tester.element(vertical)).dragDevices,
        isNot(contains(PointerDeviceKind.mouse)),
      );
      expect(
        tester
            .widgetList<ClipRect>(find.byType(ClipRect))
            .where((clip) => clip.clipBehavior == Clip.none),
        hasLength(2),
      );
      await tester.drag(
        vertical,
        const Offset(0, -250),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controllers.vertical.offset, 0);
      await tester.drag(
        vertical,
        const Offset(0, -250),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(controllers.vertical.offset, greaterThan(0));
    },
  );

  // ═══════════════════════════════════════════════════════════════════
  //  N3（2026-10-27）：my_shelf 三条横向轨道（最近追更 / 最近收藏 / 播放历史）
  //
  //  三个 tab 共用 `my_shelf.dart` 里那**一个**横向 ListView（被
  //  `SourinHorizontalRail` 包裹，与 home `_Rail` 同款）。所以"三条轨道"
  //  在这里 = 同一个包裹 × 三个 tab 各自的数据与切换路径，各测一条。
  // ═══════════════════════════════════════════════════════════════════
  group('my_shelf 三条横向轨道（N3）', () {
    /// 造一条追更/收藏记录（`key` 必填，同 shelf_card_opens_detail_test.dart）
    Favorite fav(String title) => Favorite.fromJson(<String, dynamic>{
          'key': 'probe:$title',
          'provider': 'probe',
          'native_id': title,
          'title': title,
          'cover': null,
          'kind': 'series',
          'favorited': true,
          'following': true,
          'unread_count': 0,
          'last_episode_title': null,
        });

    /// 造一条播放历史
    Progress prog(String title) => Progress.fromJson(<String, dynamic>{
          'key': 'probe:$title',
          'provider': 'probe',
          'native_id': title,
          'title': title,
          'position': 120.0,
          'duration': 600.0,
          'episode_id': 'ep-1',
        });

    /// 挂载**真 MyShelf**（1280x800 真实窗口，同既有 shelf 用例），
    /// 用 `debugSetData` 注入该 tab 的 12 张卡片（绕过 FFI 取数）。
    /// 返回父级重建句柄（same(position) 判据用）与回调记录。
    Future<({StateSetter rebuild, List<String> opened})> mountShelf(
      WidgetTester tester,
      ShelfTab tab,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final opened = <String>[];
      final key = GlobalKey<MyShelfState>();
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return MyShelf(
                  key: key,
                  onOpenDetail: (p, i) => opened.add('$p/$i'),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final titles = [for (var i = 0; i < 12; i++) '轨道卡片${tab.name}$i'];
      key.currentState!.debugSetData(
        following: tab == ShelfTab.following
            ? [for (final t in titles) fav(t)]
            : null,
        favorites: tab == ShelfTab.favorites
            ? [for (final t in titles) fav(t)]
            : null,
        history:
            tab == ShelfTab.history ? [for (final t in titles) prog(t)] : null,
        tab: tab,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return (rebuild: rebuild, opened: opened);
    }

    /// 三条轨道共用的判据链（照 home 用例的形态，逐 tab 驱动）：
    /// ① 前置断言"状态真的变了"（t108 效训：卡片真渲染出来，finder 找到，
    ///    且轨道 maxScrollExtent > 0 —— 防"拖了也没动"的恒真绿）；
    /// ② 真鼠标 drag 驱动滚动，offset 真前进；
    /// ③ 父级 rebuild 后 position 身份保留（`same(position)`）；
    /// ④ 拖拽不得误触成"点卡片进详情"。
    Future<void> driveShelfRail(WidgetTester tester, ShelfTab tab) async {
      final env = await mountShelf(tester, tab);
      final firstCard = find.text('轨道卡片${tab.name}0');

      // t108 效训：可滚容器里打点前先 ensureVisible。
      await tester.ensureVisible(firstCard);
      expect(firstCard, findsOneWidget,
          reason: '★ 前置：$tab tab 的卡片必须真的渲染出来（状态真的变了）');

      final position = Scrollable.of(tester.element(firstCard)).position;
      expect(position.maxScrollExtent, greaterThan(100),
          reason: '★ 前置：轨道必须真的可滚，否则后面的拖拽断言是恒真绿');

      // 父级 rebuild：位置与 ScrollPosition 身份都必须原地保留。
      env.rebuild(() {});
      await tester.pump();
      expect(Scrollable.of(tester.element(firstCard)).position, same(position));
      expect(position.pixels, 0);

      await tester.drag(
        firstCard,
        const Offset(-350, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(100));
      // ★ 拖拽后 index 0 已被滚出视口并被 ListView 回收（finder 会落空，
      //   t108 教训的变体）—— 用仍可见的中部卡片复核 position 身份。
      final visibleCard = find.text('轨道卡片${tab.name}6');
      expect(visibleCard, findsOneWidget,
          reason: '★ 前置：拖拽 350px 后 index 6 必须仍在视口内');
      expect(Scrollable.of(tester.element(visibleCard)).position, same(position));
      expect(env.opened, isEmpty, reason: '★ 鼠标拖拽不得误触成点卡片');
    }

    testWidgets('最近追更 rail：真 mouse drag 驱动滚动 + same(position)',
        (tester) async {
      await driveShelfRail(tester, ShelfTab.following);
    });

    testWidgets('最近收藏 rail：真 mouse drag 驱动滚动 + same(position)',
        (tester) async {
      await driveShelfRail(tester, ShelfTab.favorites);
    });

    testWidgets('播放历史 rail：真 mouse drag 驱动滚动 + same(position)',
        (tester) async {
      await driveShelfRail(tester, ShelfTab.history);
    });

    testWidgets('mouse 拖拽只授给 shelf 轨道；MyShelf 根部不含 mouse', (tester) async {
      await mountShelf(tester, ShelfTab.following);
      final shelfCtx = tester.element(find.byType(MyShelf));
      expect(
        ScrollConfiguration.of(shelfCtx).dragDevices,
        isNot(contains(PointerDeviceKind.mouse)),
        reason: '★ 阴性对照：包裹必须是局部的，MyShelf 根层级不得全局放开 mouse',
      );
      // 拖 tab 胶囊条（未包裹的那条横向 SCV）用鼠标 ⇒ 不动。
      // ⚠️ context 取 SCV **内部**的 tab 文案 —— SCV 自身的 context 在
      //    Scrollable 之上，`Scrollable.of` 会抛"无 Scrollable 祖先"。
      final tabLabel = find.text('最近收藏');
      expect(tabLabel, findsOneWidget,
          reason: '★ 前置：tab 胶囊必须渲染出来');
      await tester.drag(tabLabel, const Offset(-200, 0),
          kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      final tabsPosition = Scrollable.of(tester.element(tabLabel)).position;
      expect(tabsPosition.pixels, 0,
          reason: '★ tab 胶囊条不在 N3 范围内，必须维持"鼠标拖不动"的现状');
    });

    test('my_shelf 轨道真的包了 SourinHorizontalRail（包裹写法判据）', () {
      final shelf = File('lib/ui/widgets/my_shelf.dart').readAsStringSync();
      expect(
        RegExp(r'child: SourinHorizontalRail\(\s*child: ListView\.separated\(')
            .allMatches(shelf),
        hasLength(1),
        reason: '★ 包裹写法判据：必须"包住"那个横向 ListView —— '
            '单独的构造器声明/未使用的引用（PR #32 假绿形状）满足不了它',
      );
    });
  });
}
