// ═══════════════════════════════════════════════════════════════════════
//  第 65 轮批次 D：组件层 —— 频道搜索框 / 分组管理器逐频道勾选 / 设置页
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这一层不可省（判据层全绿也可能是死的）
// ```text
// 纯函数测"算得对"；本层测"**按钮真的接上了**"。
// 只测纯函数的话，我完全可能忘了把 `channelGroups` 往下传、
// 或者搜索框没接 `onChanged` —— 判据全绿而功能不可用。
// ```
//
// # 为什么 pump `LiveChannelList` 而不是 `LivePage`
// ```text
// `LivePage._groups` 只由 FFI 填（flutter test 里恒为空）
// ⇒ 整页层面喂不进频道数据（结构墙见 t48 开头那段）。
// `LiveChannelList` 是**公开**组件，可以直接喂假 channels 真渲染。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/settings/live_groups_page.dart';

LiveGroup grp(
  String id, {
  String? name,
  List<LiveChannel> channels = const [],
}) =>
    LiveGroup(
      provider: id,
      providerName: name ?? id.toUpperCase(),
      channels: channels,
    );

LiveChannel ch(String id, String name, {String? group}) =>
    LiveChannel(id: id, name: name, group: group);

LiveFlatEntry entry(String provider, String id, String name) =>
    (channel: ch(id, name), tag: provider.toUpperCase(), provider: provider);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 视口放高 —— 默认 800×600 会把靠下的控件挤出视口（tap 打空）
Future<void> tallViewport(WidgetTester t, {double h = 2000}) async {
  t.view.physicalSize = Size(1000, h);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

void main() {
  // ═════════════════════════════════════════════════════════════════════
  //  ① 频道搜索：输入框真的接上了（受控 + 命中数）
  // ═════════════════════════════════════════════════════════════════════
  group('① LiveChannelList 频道搜索', () {
    /// 三个频道，跨两个源
    final channels = <LiveFlatEntry>[
      entry('jia', '1', 'CCTV5 体育'),
      entry('jia', '2', 'CCTV1 综合'),
      entry('yi', '3', '斗鱼 某主播'),
    ];

    Widget build({
      String query = '',
      ValueChanged<String>? onSearchChanged,
    }) =>
        LiveChannelList(
          providers: [grp('jia'), grp('yi')],
          enabledProviders: const {'jia', 'yi'},
          channels: channels,
          selectedId: null,
          onPickChannel: (_) {},
          searchQuery: query,
          onSearchChanged: onSearchChanged,
        );

    testWidgets('★ 默认（空查询）⇒ 三个频道全在', (t) async {
      await tallViewport(t);
      await t.pumpWidget(host(build()));
      await t.pump();
      expect(find.text('CCTV5 体育'), findsOneWidget);
      expect(find.text('CCTV1 综合'), findsOneWidget);
      expect(find.text('斗鱼 某主播'), findsOneWidget);
    });

    testWidgets('★★ 搜「体育」⇒ 只剩那个频道（**跨源**按频道名筛）', (t) async {
      await tallViewport(t);
      await t.pumpWidget(host(build(query: '体育')));
      await t.pump();
      expect(find.text('CCTV5 体育'), findsOneWidget);
      expect(find.text('CCTV1 综合'), findsNothing,
          reason: '★★ 搜索必须真的收窄列表');
      expect(find.text('斗鱼 某主播'), findsNothing);
    });

    testWidgets('★★ 搜源名也能命中（用户可能记得"某个源的那个台"）', (t) async {
      await tallViewport(t);
      await t.pumpWidget(host(build(query: 'YI'))); // 源名是 YI（大写）
      await t.pump();
      expect(find.text('斗鱼 某主播'), findsOneWidget);
      expect(find.text('CCTV5 体育'), findsNothing);
    });

    testWidgets('★★★ 搜不到 ⇒ 有**明确空态**（不是一片空白）', (t) async {
      await tallViewport(t);
      await t.pumpWidget(host(build(query: '不存在的台')));
      await t.pump();
      expect(find.textContaining('没有频道名匹配'), findsOneWidget,
          reason: '★★★ 用户刚打的字搜不到，必须告诉他"是这个词没搜到"');
      expect(find.textContaining('不存在的台'), findsWidgets,
          reason: '★ 空态文案里要回显他搜的词');
    });

    testWidgets('★★ 搜索空态与"筛选空态"是**两种文案**（不能混）', (t) async {
      await tallViewport(t);
      // 有搜索词 ⇒ 搜索空态
      await t.pumpWidget(host(build(query: 'zzz')));
      await t.pump();
      expect(find.textContaining('没有频道名匹配'), findsOneWidget);
      expect(find.textContaining('这个筛选下没有频道'), findsNothing,
          reason: '★★ 搜索为空时不许说"这个筛选下没有"（改筛选也没用）');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ①b 搜索框**控件本身**（LiveSearchField —— 页头那一枚）
  //
  // # 为什么必须单独测它
  // ```text
  // 上面那组测的是 `LiveChannelList` 收到 `searchQuery` 后**怎么筛**；
  // 但"输入框真的把字交出去了吗"是另一件事 —— `_FilterBar` 之外的
  // 那一枚控件挂在 `LivePage` 的 ready 分支里，`LivePage._groups` 恒空
  // ⇒ 整页永远到不了那里。把它公开（`LiveSearchField`）就是为了能直接喂。
  // ```
  // ═════════════════════════════════════════════════════════════════════
  group('①b LiveSearchField 控件本身', () {
    Widget build({
      required TextEditingController ctrl,
      String query = '',
      int hit = 0,
      int total = 0,
      ValueChanged<String>? onChanged,
    }) =>
        LiveSearchField(
          controller: ctrl,
          query: query,
          hitCount: hit,
          total: total,
          onChanged: onChanged ?? (_) {},
        );

    testWidgets('★ 空查询 ⇒ 显示「共 N 个频道」（不说"命中"）', (t) async {
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      await tallViewport(t, h: 400);
      await t.pumpWidget(host(build(ctrl: ctrl, total: 42)));
      await t.pump();
      expect(find.text('共 42 个频道'), findsOneWidget);
      expect(find.textContaining('命中'), findsNothing);
    });

    testWidgets('★★ 有查询 ⇒ 显示「命中 N / 共 M」', (t) async {
      final ctrl = TextEditingController(text: '体育');
      addTearDown(ctrl.dispose);
      await tallViewport(t, h: 400);
      await t.pumpWidget(
        host(build(ctrl: ctrl, query: '体育', hit: 3, total: 42)),
      );
      await t.pump();
      expect(find.text('命中 3 / 共 42'), findsOneWidget);
    });

    testWidgets('★★★ 0 命中 ⇒ 用**错误色**（让"没搜到"一眼可辨）', (t) async {
      final ctrl = TextEditingController(text: 'zzz');
      addTearDown(ctrl.dispose);
      await tallViewport(t, h: 400);
      await t.pumpWidget(
        host(build(ctrl: ctrl, query: 'zzz', hit: 0, total: 42)),
      );
      await t.pump();
      final txt = t.widget<Text>(find.byKey(const ValueKey('live-search-hits')));
      final colors = Theme.of(t.element(find.byType(LiveSearchField)))
          .colorScheme;
      expect(txt.style?.color, colors.error,
          reason: '★★ 0 命中必须显著不同（否则用户分不清"没搜到"和"没在搜"）');
    });

    testWidgets('★★ 打字 ⇒ onChanged 真的被调用（受控链的起点）', (t) async {
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      final seen = <String>[];
      await tallViewport(t, h: 400);
      await t.pumpWidget(host(build(ctrl: ctrl, onChanged: seen.add)));
      await t.pump();
      await t.enterText(
        find.byKey(const ValueKey('live-search-field')),
        '新闻',
      );
      await t.pump();
      expect(seen, ['新闻'], reason: '★ 输入必须真的抛给宿主（否则搜索框是死的）');
    });

    testWidgets('★★★ 清空按钮 ⇒ 清掉输入框 + 回调空串', (t) async {
      final ctrl = TextEditingController(text: '体育');
      addTearDown(ctrl.dispose);
      final seen = <String>[];
      await tallViewport(t, h: 400);
      await t.pumpWidget(host(build(
        ctrl: ctrl,
        query: '体育',
        hit: 2,
        total: 42,
        onChanged: seen.add,
      )));
      await t.pump();
      expect(find.byKey(const ValueKey('live-search-clear')), findsOneWidget,
          reason: '★ 有查询时必须给清空入口（否则用户要逐字删）');
      await t.tap(find.byKey(const ValueKey('live-search-clear')));
      await t.pump();
      expect(ctrl.text, isEmpty, reason: '★★ 输入框必须真的被清空');
      expect(seen.last, isEmpty, reason: '★★ 宿主必须收到空串（否则列表不会复原）');
    });

    testWidgets('★ 空查询时**不显示**清空按钮（少一个可点区域）', (t) async {
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      await tallViewport(t, h: 400);
      await t.pumpWidget(host(build(ctrl: ctrl, total: 42)));
      await t.pump();
      expect(find.byKey(const ValueKey('live-search-clear')), findsNothing);
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ② 分组 v2 真的接进列表（channelGroups 往下传）
  // ═════════════════════════════════════════════════════════════════════
  group('② LiveChannelList 按频道分组筛选', () {
    final channels = <LiveFlatEntry>[
      entry('jia', '1', '甲一频道'),
      entry('jia', '2', '甲二频道'),
      entry('yi', '3', '乙一频道'),
    ];

    Widget build(Map<String, List<LiveChannelRef>> groups) => LiveChannelList(
          providers: [grp('jia'), grp('yi')],
          enabledProviders: const {'jia', 'yi'},
          channels: channels,
          selectedId: null,
          onPickChannel: (_) {},
          channelGroups: groups,
        );

    testWidgets('★ 没有分组 ⇒ 三颗药丸只有「全部分组」+「全部源」', (t) async {
      await tallViewport(t);
      await t.pumpWidget(host(build(const {})));
      await t.pump();
      // 没建组 ⇒ 分组那格**不画**（老用户无感）
      expect(find.byKey(const ValueKey('live-bar-group')), findsNothing);
      expect(find.byKey(const ValueKey('live-manage-groups')), findsOneWidget,
          reason: '★ 建组入口必须一直在（Owner 第 4 条：补选择入口）');
    });

    testWidgets('★★ 有 v2 组 ⇒ 分组下拉出现，且列出组名', (t) async {
      await tallViewport(t);
      await t.pumpWidget(host(build({
        '常看': [const LiveChannelRef('jia', '1')],
      })));
      await t.pump();
      expect(find.byKey(const ValueKey('live-bar-group')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('live-bar-group')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('live-bar-opt-常看')), findsOneWidget);
    });

    testWidgets('★★★ 选「常看」⇒ 只剩**被勾选的那个频道**（同源别的台也被挡）',
        (t) async {
      await tallViewport(t);
      await t.pumpWidget(host(build({
        '常看': [const LiveChannelRef('jia', '1')],
      })));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('live-bar-group')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('live-bar-opt-常看')));
      await t.pumpAndSettle();

      expect(find.text('甲一频道'), findsOneWidget);
      expect(find.text('甲二频道'), findsNothing,
          reason: '★★★ 这正是 Owner 要的「选具体房间」—— 同源的别的台也要被挡');
      expect(find.text('乙一频道'), findsNothing);
    });

    testWidgets('★★ 老格式（v1 按源）仍然可用 ⇒ 该源全部频道都在', (t) async {
      await tallViewport(t);
      await t.pumpWidget(host(LiveChannelList(
        providers: [grp('jia'), grp('yi')],
        enabledProviders: const {'jia', 'yi'},
        channels: channels,
        selectedId: null,
        onPickChannel: (_) {},
        sourceGroups: const {
          '老组': ['jia'],
        },
      )));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('live-bar-group')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('live-bar-opt-老组')));
      await t.pumpAndSettle();

      expect(find.text('甲一频道'), findsOneWidget);
      expect(find.text('甲二频道'), findsOneWidget,
          reason: '★★ 老格式语义 = 整个源都在组里（不许静默失效）');
      expect(find.text('乙一频道'), findsNothing);
    });

    testWidgets('★★★ 两套分组的组名取**并集**（谁的组都不许消失）', (t) async {
      await tallViewport(t);
      await t.pumpWidget(host(LiveChannelList(
        providers: [grp('jia'), grp('yi')],
        enabledProviders: const {'jia', 'yi'},
        channels: channels,
        selectedId: null,
        onPickChannel: (_) {},
        sourceGroups: const {
          '老组': ['jia'],
        },
        channelGroups: {
          '新组': [const LiveChannelRef('yi', '3')],
        },
      )));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('live-bar-group')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('live-bar-opt-老组')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-bar-opt-新组')), findsOneWidget,
          reason: '★★★ 只列一套 ⇒ 另一套的组在界面上"消失"（数据还在却选不到）');
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ③ 分组管理器：逐**频道**勾选（Owner 推翻了"按源"）
  // ═════════════════════════════════════════════════════════════════════
  group('③ 直播页内分组管理器 —— 逐频道勾选', () {
    final channels = <LiveFlatEntry>[
      entry('jia', '1', '甲一频道'),
      entry('jia', '2', '甲二频道'),
      entry('yi', '3', '乙一频道'),
    ];

    Widget build({Map<String, List<LiveChannelRef>> groups = const {}}) =>
        LiveChannelList(
          providers: [grp('jia'), grp('yi')],
          enabledProviders: const {'jia', 'yi'},
          channels: channels,
          selectedId: null,
          onPickChannel: (_) {},
          // ★ 必须传 groups —— 管理器的草稿是从 `channelGroups` 初始化的，
          //   不传的话已存的勾选在打开时是空的（见 `initState` 的回填逻辑）
          channelGroups: groups,
        );

    Future<void> openManager(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('live-manage-groups')));
      await t.pumpAndSettle();
    }

    testWidgets('★★★ 管理器里能看到**每个频道**一颗勾选胶囊', (t) async {
      await tallViewport(t);
      UiPrefs.debugResetForTest();
      await t.pumpWidget(host(build()));
      await t.pump();
      await openManager(t);

      await t.enterText(find.byKey(const ValueKey('live-mgr-name')), '常看');
      await t.tap(find.byKey(const ValueKey('live-mgr-add')));
      await t.pumpAndSettle();

      // ★ 三个频道各有自己的勾选胶囊（按 (group, provider, channelId) 定位）
      expect(find.byKey(const ValueKey('live-mgr-ch-常看-jia-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-mgr-ch-常看-jia-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-mgr-ch-常看-yi-3')), findsOneWidget);
    });

    testWidgets('★★★ 勾一个频道 ⇒ 只存这一个（不是整个源）', (t) async {
      await tallViewport(t);
      UiPrefs.debugResetForTest();
      await t.pumpWidget(host(build()));
      await t.pump();
      await openManager(t);

      await t.enterText(find.byKey(const ValueKey('live-mgr-name')), '常看');
      await t.tap(find.byKey(const ValueKey('live-mgr-add')));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('live-mgr-ch-常看-jia-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('live-mgr-save')));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 400)); // 落盘防抖

      final v2 = UiPrefs.liveChannelGroups();
      expect(v2['常看']!.map((e) => e.key).toList(), ['jia\u00001'],
          reason: '★★★ Owner 要的是"具体的房间"，不是"整个源"');
      // v1 由 v2 推导（向前兼容）
      expect(UiPrefs.liveSourceGroups()['常看'], ['jia'],
          reason: '★ v1 要跟着推导出来（老版本打开同一份文件仍合理）');
    });

    testWidgets('★★★ 取消勾选 ⇒ 真的从组里移除', (t) async {
      await tallViewport(t);
      UiPrefs.debugResetForTest();
      UiPrefs.setLiveChannelGroups({
        '常看': [
          const LiveChannelRef('jia', '1'),
          const LiveChannelRef('jia', '2'),
        ],
      });
      await t.pumpWidget(host(build(groups: {
        '常看': [
          const LiveChannelRef('jia', '1'),
          const LiveChannelRef('jia', '2'),
        ],
      })));
      await t.pump();
      await openManager(t);

      // 点「甲一」取消它（★ 键名带 provider + channelId，见管理器的 `_providerBlock`）
      await t.tap(find.byKey(const ValueKey('live-mgr-ch-常看-jia-1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('live-mgr-save')));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 400));

      expect(UiPrefs.liveChannelGroups()['常看']!.map((e) => e.key).toList(),
          ['jia\u00002'],
          reason: '★★★ 取消勾选必须真的生效');
    });

    testWidgets('★★ 组内搜索真的收窄胶囊（100+ 个台时是必需品）', (t) async {
      await tallViewport(t);
      UiPrefs.debugResetForTest();
      await t.pumpWidget(host(build()));
      await t.pump();
      await openManager(t);

      await t.enterText(find.byKey(const ValueKey('live-mgr-name')), '常看');
      await t.tap(find.byKey(const ValueKey('live-mgr-add')));
      await t.pumpAndSettle();

      await t.enterText(
        find.byKey(const ValueKey('live-mgr-filter-常看')),
        '甲一频道',
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('live-mgr-ch-常看-jia-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-mgr-ch-常看-jia-2')), findsNothing,
          reason: '★★ 组内搜索必须真的把不匹配的胶囊去掉');
    });

    testWidgets('★★ 全选某个源 ⇒ 该源全部频道进组（快捷方式，不是唯一入口）',
        (t) async {
      await tallViewport(t);
      UiPrefs.debugResetForTest();
      await t.pumpWidget(host(build()));
      await t.pump();
      await openManager(t);

      await t.enterText(find.byKey(const ValueKey('live-mgr-name')), '常看');
      await t.tap(find.byKey(const ValueKey('live-mgr-add')));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('live-mgr-all-常看-jia')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('live-mgr-save')));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 400));

      expect(
        UiPrefs.liveChannelGroups()['常看']!.map((e) => e.key).toList()..sort(),
        ['jia\u00001', 'jia\u00002'],
      );
    });

    testWidgets('★★★ 老格式的组打开管理器 ⇒ 回填成具体频道（保存不会清空）',
        (t) async {
      /*
       * 这是最危险的一条：用户的老组是"包含 jia 这个源"。
       * 若打开管理器时不回填成具体频道，他一点保存 ⇒ v2 里那个组是空的
       * ⇒ 下次选这个组 ⇒ 一个台都不显示（**数据损坏**）。
       */
      await tallViewport(t);
      UiPrefs.debugResetForTest();
      UiPrefs.setLiveSourceGroups({
        '老组': ['jia'],
      });
      await t.pumpWidget(host(LiveChannelList(
        providers: [grp('jia'), grp('yi')],
        enabledProviders: const {'jia', 'yi'},
        channels: channels,
        selectedId: null,
        onPickChannel: (_) {},
        sourceGroups: const {
          '老组': ['jia'],
        },
      )));
      await t.pump();
      await openManager(t);

      // 老组要出现在编辑器里
      expect(find.byKey(const ValueKey('live-mgr-del-老组')), findsOneWidget);
      // 且它下面有 jia 的两个频道胶囊
      expect(find.byKey(const ValueKey('live-mgr-ch-老组-jia-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-mgr-ch-老组-jia-2')), findsOneWidget);

      // 直接保存（什么都不改）
      await t.tap(find.byKey(const ValueKey('live-mgr-save')));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 400));

      expect(
        UiPrefs.liveChannelGroups()['老组']!.map((e) => e.key).toList()..sort(),
        ['jia\u00001', 'jia\u00002'],
        reason: '★★★ 老组必须被回填成具体频道 —— 否则保存即清空用户的分组',
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ④ 设置页：有频道快照 ⇒ 逐频道勾选；无快照 ⇒ 回落手输（永远可用）
  // ═════════════════════════════════════════════════════════════════════
  group('④ 设置页 live_groups_page', () {
    testWidgets('★ 无磁盘快照 ⇒ 手输源 id 那条路仍然可用（不炸、不空白）',
        (t) async {
      await tallViewport(t, h: 1600);
      UiPrefs.debugResetForTest();
      UiPrefs.setLiveSourceGroups({
        '常看': ['jia'],
      });
      await t.pumpWidget(host(const LiveGroupsPage()));
      await t.pump();

      // ★ 组名要出现（老分组不许因为"没快照"而消失）
      expect(find.byKey(const ValueKey('live-group-del-常看')), findsOneWidget,
          reason: '★★ 没有快照时也必须能看到已存的组');
      expect(find.byKey(const ValueKey('live-group-addsrc-常看')), findsOneWidget,
          reason: '★ 手输入口是这条路径唯一可用的编辑方式');
      // ⚠️ UiPrefs 落盘是 300ms 防抖 Timer ⇒ 测试结束前必须跑完（否则 pending timer 报错）
      await t.pump(const Duration(milliseconds: 400));
    });

    testWidgets('★★ 手输加源 ⇒ 真的落进 v1（且不被 v2 推导覆盖掉）', (t) async {
      /*
       * 这是实测抓到的真 bug：`_save` 若无条件用 v2 反推 v1，
       * 而这条路径下 v2 恒为空 ⇒ 用户刚加的源当场消失。
       */
      await tallViewport(t, h: 1600);
      UiPrefs.debugResetForTest();
      UiPrefs.setLiveSourceGroups({
        '常看': <String>[],
      });
      await t.pumpWidget(host(const LiveGroupsPage()));
      await t.pump();

      await t.enterText(
        find.byKey(const ValueKey('live-group-addsrc-常看')),
        'jia',
      );
      await t.tap(find.byKey(const ValueKey('live-group-addbtn-常看')));
      await t.pump();
      expect(UiPrefs.liveSourceGroups()['常看'], ['jia'],
          reason: '★★ 手输的源必须落进 v1');
      await t.pump(const Duration(milliseconds: 400));
    });

    testWidgets('★★ 删组 ⇒ v1 与 v2 都清掉（不留幽灵组）', (t) async {
      await tallViewport(t, h: 1600);
      UiPrefs.debugResetForTest();
      UiPrefs.setLiveSourceGroups({
        '常看': ['jia'],
      });
      UiPrefs.setLiveChannelGroups({
        '常看': [const LiveChannelRef('jia', '1')],
      });
      await t.pumpWidget(host(const LiveGroupsPage()));
      await t.pump();

      await t.tap(find.byKey(const ValueKey('live-group-del-常看')));
      await t.pump();
      expect(UiPrefs.liveSourceGroups(), isEmpty, reason: '★ v1 清掉');
      expect(UiPrefs.liveChannelGroups(), isEmpty, reason: '★ v2 也清掉');
      await t.pump(const Duration(milliseconds: 400));
    });
  });
}
