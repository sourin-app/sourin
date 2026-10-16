// ═══════════════════════════════════════════════════════════════════════
//  T8 ② 自定义直播源分组 —— 判据行为测试
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// > 支持一下自定义直播源拆分组（就是自定义常用的然后切换分组 就可以不用看不想看的其他源了）
//
// # 两层判据，缺一不可
//   ①②③④ 纯函数/持久化：判据**算得对**
//   ⑥     组件级：药丸**真的挂上树**、点击**真的接上**、删组**真的回落**
//   （纯函数全绿但忘了往下传 sourceGroups ⇒ 功能依然不可用，只有 ⑥ 看得见）
//
// # 为什么纯函数层测 `applyLiveSourceGroup` 而不是 pump 整个 LivePage
//   LivePage 的源列表只由 FFI 填，flutter test 里恒为空
//   （结构墙见 t1013_live_filter_test.dart:10-26）。
//   applyLiveSourceGroup 是这条判据的唯一核心，抽成顶层纯函数就是为了能直接喂输入。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/settings/live_groups_page.dart';

LiveGroup g(String id) =>
    LiveGroup(provider: id, providerName: id.toUpperCase());

void main() {
  final all = [g('iptv'), g('douyu'), g('huya'), g('kuaishou')];

  group('① 默认「全部分组」= 不筛（老用户无感）', () {
    test('group == null ⇒ 原样返回（顺序也不动）', () {
      final r = applyLiveSourceGroup(all, {'常看': ['iptv']}, null);
      expect(r.map((e) => e.provider).toList(), ['iptv', 'douyu', 'huya', 'kuaishou']);
      expect(identical(r, all), isTrue, reason: '★ 必须是同一个对象（不重排、不复制）');
    });
    test('★ 完全没存过分组 ⇒ 行为与今天一致', () {
      final r = applyLiveSourceGroup(all, const {}, null);
      expect(r.length, 4);
    });
  });

  group('② 选中某组 ⇒ 只剩该组的源', () {
    test('「常看」= [iptv, huya] ⇒ 只剩这两个', () {
      final r = applyLiveSourceGroup(all, {'常看': ['iptv', 'huya']}, '常看');
      expect(r.map((e) => e.provider).toList(), ['iptv', 'huya']);
    });
    test('★ 顺序跟源列表走，不跟组内写法走', () {
      final r = applyLiveSourceGroup(all, {'常看': ['huya', 'iptv']}, '常看');
      expect(r.map((e) => e.provider).toList(), ['iptv', 'huya'],
          reason: '★ 源列表的顺序是页面稳定契约，不能被分组打乱');
    });
  });

  group('③ 兜底：绝不筛成空（Lead 明确要求）', () {
    test('★ 组不存在 ⇒ 返回全部', () {
      final r = applyLiveSourceGroup(all, {'常看': ['iptv']}, '已删除的组');
      expect(r.length, 4, reason: '★ 组没了必须兜底，不许给用户一片空白');
    });
    test('★ 组是空的 ⇒ 返回全部', () {
      final r = applyLiveSourceGroup(all, {'空组': []}, '空组');
      expect(r.length, 4);
    });
    test('★★ 组里的源全都不可见了 ⇒ 返回全部（不是空）', () {
      final r = applyLiveSourceGroup(all, {'旧组': ['gone1', 'gone2']}, '旧组');
      expect(r.length, 4,
          reason: '★★ 最关键的一条兜底：源被停用后组内一个都不剩，'
              '若返回空，用户看到的是「直播页坏了」');
    });
    test('★ 部分源失效 ⇒ 只保留仍可见的（不因有失效项就整体放弃）', () {
      final r = applyLiveSourceGroup(all, {'常看': ['iptv', 'gone']}, '常看');
      expect(r.map((e) => e.provider).toList(), ['iptv']);
    });
  });

  group('④ 持久化：向前兼容 + 坏数据不炸', () {
    test('★ 存→读 往返一致', () {
      UiPrefs.debugResetForTest();
      UiPrefs.setLiveSourceGroups({'常看': ['iptv', 'huya'], '央视': ['iptv']});
      final back = UiPrefs.liveSourceGroups();
      expect(back.keys.toSet(), {'常看', '央视'});
      expect(back['常看'], ['iptv', 'huya']);
    });
    test('★ 没存过 ⇒ 空 Map（不是 null、不抛）', () {
      UiPrefs.debugResetForTest();
      expect(UiPrefs.liveSourceGroups(), isEmpty);
    });
    test('★ 传空 Map ⇒ 清键（不留垃圾键）', () {
      UiPrefs.debugResetForTest();
      UiPrefs.setLiveSourceGroups({'a': ['x']});
      expect(UiPrefs.get(UiPrefs.liveSourceGroupsKey), isNotNull);
      UiPrefs.setLiveSourceGroups(const {});
      expect(UiPrefs.get(UiPrefs.liveSourceGroupsKey), isNull,
          reason: '★ 与 setHomeSource 同一条纪律：不留空串垃圾键');
    });
    test('★★ 向前兼容：以后加字段（未知键）⇒ 老代码忽略它，不炸', () {
      UiPrefs.debugResetForTest();
      UiPrefs.set(UiPrefs.liveSourceGroupsKey,
          jsonEncode({'常看': ['iptv'], '排序权重': 3, '颜色': '#fff'}));
      final back = UiPrefs.liveSourceGroups();
      expect(back['常看'], ['iptv'], reason: '★ 认识的键照收');
      expect(back.containsKey('排序权重'), isFalse,
          reason: '★ 不认识的值类型（非 List）被忽略，不是把整份作废');
    });
    test('★★ 坏数据：整份是垃圾 ⇒ 空 Map，不抛', () {
      UiPrefs.debugResetForTest();
      UiPrefs.set(UiPrefs.liveSourceGroupsKey, '这不是 JSON{{');
      expect(UiPrefs.liveSourceGroups(), isEmpty);
    });
    test('★★ 坏数据：单个键坏 ⇒ 只丢那个键，其余保留', () {
      UiPrefs.debugResetForTest();
      UiPrefs.set(UiPrefs.liveSourceGroupsKey,
          jsonEncode({'好组': ['iptv'], '坏组': 'not-a-list'}));
      final back = UiPrefs.liveSourceGroups();
      expect(back['好组'], ['iptv'], reason: '★ 好数据必须留住');
      expect(back.containsKey('坏组'), isFalse);
    });
    test('★ 非字符串成员被剔掉（不污染模型）', () {
      UiPrefs.debugResetForTest();
      UiPrefs.set(UiPrefs.liveSourceGroupsKey,
          jsonEncode({'组': ['iptv', 42, null, 'huya']}));
      expect(UiPrefs.liveSourceGroups()['组'], ['iptv', 'huya']);
    });
  });

  group('⑤ 故障注入：判据必须能变红', () {
    test('★ 去掉兜底（组不存在就返回空）⇒ 上面 ③ 的判据会红', () {
      List<LiveGroup> broken(
        List<LiveGroup> gs,
        Map<String, List<String>> m,
        String? grp,
      ) {
        if (grp == null) return gs;
        final members = m[grp] ?? const <String>[];
        return gs.where((x) => members.contains(x.provider)).toList();
      }
      final bad = broken(all, {'常看': ['iptv']}, '已删除的组');
      expect(bad, isEmpty, reason: '★ 坏版本确实会筛成空 ⇒ ③ 的兜底断言有区分力');
      final good = applyLiveSourceGroup(all, {'常看': ['iptv']}, '已删除的组');
      expect(good.length, 4, reason: '★ 真版本兜底返回全部');
    });
    test('★ 组内顺序被打乱 ⇒ ② 的顺序判据会红', () {
      List<LiveGroup> brokenOrder(List<LiveGroup> gs, List<String> members) =>
          [for (final id in members) gs.firstWhere((x) => x.provider == id)];
      final bad = brokenOrder(all, ['huya', 'iptv']);
      expect(bad.map((e) => e.provider).toList(), ['huya', 'iptv'],
          reason: '★ 坏版本按组内顺序排 ⇒ ② 的顺序断言有区分力');
    });
  });

  _widgetTests();
  _settingsPageTests();
}

// ═══════════════════════════════════════════════════════════════════════
//  ⑥ 组件级：分组药丸真的渲染并真的筛（纯函数测试盖不住的部分）
// ═══════════════════════════════════════════════════════════════════════
//
// 盖住三件纯函数看不见的事：
//   · sourceGroups 到底有没有往下传（忘了传 ⇒ 纯函数全绿也没用）
//   · 点击有没有真的接到 _pickSourceGroup（接线断了 ⇒ 同上）
//   · 空 Map 时那一排到底在不在（老用户零感知这条只能看树）
void _widgetTests() {
  LiveFlatEntry ent(String prov, String ch, String? group) => (
        channel: LiveChannel(id: '$prov-$ch', name: ch, group: group),
        tag: prov,
        provider: prov,
      );

  final chans = [
    ent('iptv', 'CCTV1 综合频道', '综合'),
    ent('douyu', '某主播甲房间', '游戏'),
    ent('huya', '某主播乙房间', '游戏'),
  ];

  Widget host(LiveChannelList w) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 300, height: 600, child: w)),
      );

  LiveChannelList makeList({
    required Map<String, List<String>> groups,
    ValueChanged<String?>? onPick,
  }) =>
      LiveChannelList(
        providers: const [
          LiveGroup(provider: 'iptv', providerName: 'IPTV'),
          LiveGroup(provider: 'douyu', providerName: 'DOUYU'),
          LiveGroup(provider: 'huya', providerName: 'HUYA'),
        ],
        enabledProviders: const {'iptv', 'douyu', 'huya'},
        channels: chans,
        selectedId: null,
        onPickChannel: (_) {},
        sourceGroups: groups,
        onPickGroupFilter: onPick,
      );

  testWidgets('★★ 没建过组 ⇒ 分组那一排根本不挂（老用户零感知）', (t) async {
    await t.pumpWidget(host(makeList(groups: const {})));
    await t.pump();
    expect(find.byKey(liveGroupFilterChipKey(null)), findsNothing,
        reason: '★ 没建组就不该多占一行高度');
    // 阴性对照：源那一排照旧在（证明不是整页没渲染）
    expect(find.byKey(sourceFilterChipKey(null)), findsOneWidget);
  });

  testWidgets('★★ 建过组 ⇒ 分组药丸真的出现（含「全部分组」）', (t) async {
    await t.pumpWidget(host(makeList(groups: const {
      '常看': ['iptv'],
      '游戏': ['douyu', 'huya'],
    })));
    await t.pump();
    expect(find.byKey(liveGroupFilterChipKey(null)), findsOneWidget);
    expect(find.byKey(liveGroupFilterChipKey('常看')), findsOneWidget);
    expect(find.byKey(liveGroupFilterChipKey('游戏')), findsOneWidget);
  });

  testWidgets('★★★ 点分组 ⇒ 列表真的只剩该组的源（端到端）', (t) async {
    await t.pumpWidget(host(makeList(groups: const {'常看': ['iptv']})));
    await t.pump();
    // 点之前：三个源的频道都在
    expect(find.text('CCTV1 综合频道'), findsOneWidget);
    expect(find.text('某主播甲房间'), findsOneWidget);

    await t.tap(find.byKey(liveGroupFilterChipKey('常看')));
    await t.pump();
    // 点之后：只剩 iptv 的频道
    expect(find.text('CCTV1 综合频道'), findsOneWidget);
    expect(find.text('某主播甲房间'), findsNothing,
        reason: '★★★ 用户要的核心行为：切到组就看不到不想看的源');
    expect(find.text('某主播乙房间'), findsNothing);
  });

  testWidgets('★★★ 切到分组 ⇒ 源药丸排也只剩该组的源（「不用看不想看的其他源」）',
      (t) async {
    await t.pumpWidget(host(makeList(groups: const {'常看': ['iptv']})));
    await t.pump();
    // 点之前：三个源的药丸都在
    expect(find.byKey(sourceFilterChipKey('iptv')), findsOneWidget);
    expect(find.byKey(sourceFilterChipKey('douyu')), findsOneWidget);
    expect(find.byKey(sourceFilterChipKey('huya')), findsOneWidget);

    await t.tap(find.byKey(liveGroupFilterChipKey('常看')));
    await t.pump();
    // 点之后：只剩 iptv 的**药丸**
    expect(find.byKey(sourceFilterChipKey('iptv')), findsOneWidget);
    expect(find.byKey(sourceFilterChipKey('douyu')), findsNothing,
        reason: '★★★ 用户要的是「不用看不想看的其他源」——'
            '源名照旧列着就等于还在看它');
    expect(find.byKey(sourceFilterChipKey('huya')), findsNothing);
    // 阴性对照：「全部源」仍在（否则用户回不到不筛）
    expect(find.byKey(sourceFilterChipKey(null)), findsOneWidget);
  });

  testWidgets('★★★ 组内源被删光 ⇒ 源药丸排兜底回全部（不塌成空排）', (t) async {
    await t.pumpWidget(host(makeList(groups: const {'空组': ['gone']})));
    await t.pump();
    await t.tap(find.byKey(liveGroupFilterChipKey('空组')));
    await t.pump();
    expect(find.byKey(sourceFilterChipKey('iptv')), findsOneWidget,
        reason: '★★★ 组里没有可见源 ⇒ 兜底显示全部，不许把这一排也筛空');
    expect(find.byKey(sourceFilterChipKey('douyu')), findsOneWidget);
  });

  testWidgets('★★ 点分组会回调出去（接线没断）', (t) async {
    final calls = <String?>[];
    await t.pumpWidget(host(makeList(
      groups: const {'常看': ['iptv']},
      onPick: calls.add,
    )));
    await t.pump();
    await t.tap(find.byKey(liveGroupFilterChipKey('常看')));
    await t.pump();
    await t.tap(find.byKey(liveGroupFilterChipKey(null)));
    await t.pump();
    expect(calls, ['常看', null]);
  });

  testWidgets('★★★ 删掉正在筛的组 ⇒ 源回落全部，不消失（Lead 要求）', (t) async {
    await t.pumpWidget(host(makeList(groups: const {'常看': ['iptv']})));
    await t.pump();
    await t.tap(find.byKey(liveGroupFilterChipKey('常看')));
    await t.pump();
    expect(find.text('某主播甲房间'), findsNothing); // 确实筛掉了

    // 设置页把「常看」删了 ⇒ 组件收到空 groups
    await t.pumpWidget(host(makeList(groups: const {})));
    await t.pump();
    expect(find.text('CCTV1 综合频道'), findsOneWidget,
        reason: '★★★ 源不许因为组被删而消失');
    expect(find.text('某主播甲房间'), findsOneWidget,
        reason: '★★★ 这正是 Lead 要的「删分组时里面的源回落到全部」');
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  ⑦ 设置页：建组 / 删组 真的落到 UiPrefs（编辑入口的真实行为）
// ═══════════════════════════════════════════════════════════════════════
//
// 盖住：按钮**真的接了** _addGroup/_removeGroup、并且**真的写进了** prefs。
// （只测纯函数/持久化层看不见「按钮有没有接上」。）
void _settingsPageTests() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  /*
   * ⚠️ 默认测试视口只有 800x600，而设置页内容比它高 ⇒
   *    靠下的控件虽然「有 rect」，却**在滚动视口之外**，
   *    `tap` 会落到 ScrollView 上（实测报「would not hit test on the
   *    specified widget」）。⇒ 把视口放高，让整页一次可见。
   *    （这是测试脚手架问题，不是产品缺陷。）
   */
  Future<void> tallViewport(WidgetTester t) async {
    t.view.physicalSize = const Size(900, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
  }

  testWidgets('★★★ 设置页新建分组 ⇒ 真的落进 UiPrefs', (t) async {
    UiPrefs.debugResetForTest();
    await t.pumpWidget(host(const LiveGroupsPage()));
    await t.pump();

    await t.enterText(find.byType(TextField).first, '常看');
    await t.tap(find.text('新建'));
    await t.pump();

    expect(UiPrefs.liveSourceGroups().keys.toList(), ['常看'],
        reason: '★★★ 点了新建就必须真的写进 prefs');
    // 界面上也要看得到这个组
    expect(find.text('常看'), findsWidgets);
    // ⚠️ UiPrefs 落盘是**防抖 300ms** 的 Timer（ui_prefs.dart _flushSoon）——
    //    flutter_test 会在测试结束时抓「pending timer」⇒ 必须把它跑完。
    await t.pump(const Duration(milliseconds: 400));
  });

  testWidgets('★★ 重名分组被拒（不覆盖已有的）', (t) async {
    UiPrefs.debugResetForTest();
    UiPrefs.setLiveSourceGroups({'常看': ['iptv']});
    await t.pumpWidget(host(const LiveGroupsPage()));
    await t.pump();

    await t.enterText(find.byType(TextField).first, '常看');
    await t.tap(find.text('新建'));
    await t.pump();

    expect(UiPrefs.liveSourceGroups()['常看'], ['iptv'],
        reason: '★ 重名不许把已有的组清空');
    await t.pump(const Duration(milliseconds: 400));
  });

  testWidgets('★★★ 删组 ⇒ 键真的没了，且源回落全部（Lead 要求）', (t) async {
    await tallViewport(t);
    UiPrefs.debugResetForTest();
    UiPrefs.setLiveSourceGroups({'常看': ['iptv']});
    await t.pumpWidget(host(const LiveGroupsPage()));
    await t.pump();

    await t.tap(find.byKey(const ValueKey('live-group-del-常看')));
    await t.pump();

    expect(UiPrefs.liveSourceGroups(), isEmpty,
        reason: '★★★ 删组必须真的落盘');
    await t.pump(const Duration(milliseconds: 400));
    // ★ 源列表本身不受影响 —— 分组只是筛选器，删掉筛选器 ⇒ 全部源照旧
    final all = [g('iptv'), g('douyu')];
    expect(applyLiveSourceGroup(all, UiPrefs.liveSourceGroups(), null).length, 2,
        reason: '★★★ 这正是 Lead 要的「删分组时里面的源回落到全部」');
  });

  testWidgets('★★ 往组里加源 / 删源 都真的落盘', (t) async {
    await tallViewport(t);
    UiPrefs.debugResetForTest();
    UiPrefs.setLiveSourceGroups({'常看': <String>[]});
    await t.pumpWidget(host(const LiveGroupsPage()));
    await t.pump();

    await t.enterText(find.byKey(const ValueKey('live-group-addsrc-常看')), 'iptv');
    await t.tap(find.byKey(const ValueKey('live-group-addbtn-常看')));
    await t.pump();
    expect(UiPrefs.liveSourceGroups()['常看'], ['iptv']);

    /*
     * 删掉它 —— ⚠️ 必须点 Chip 里的**删除图标**，不能点胶囊中心：
     * 中心落在 Chip 本体上（那里没有 onDeleted），点击会落空。
     */
    await t.tap(
      find.descendant(
        of: find.byKey(const ValueKey('live-group-src-常看-iptv')),
        matching: find.byType(Icon),
      ),
    );
    await t.pump();
    expect(UiPrefs.liveSourceGroups()['常看'], isEmpty,
        reason: '★ 删源后组还在，只是空了');
    await t.pump(const Duration(milliseconds: 400));
  });
}
