// ═══════════════════════════════════════════════════════════════════════
//  t1063：R2-A 源卡片**启用/停用开关**（可见 + 真翻转 + ⚡ 热重载）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，2026-10-27 13:0x + 13:28）
// ```text
// 「源 页面 加上 启用停用的开关功能,现在没有」
// 「你可以给源做一个状态,启用才使用,未启用的都不生效」
// 「这个源 的开关要热重载生效,而不是开关状态之后必须重启软件才能生效」  ← 硬要求
// ```
//
// # 本文件守什么（每条都配能红的机器判据）
// ```text
// ① 根因钉死：`onToggle` 在卡片里**只被声明、从未被渲染**（Owner"现在没有"的本体）。
//    ★ 这条是"缺陷的形状"，不是"修法好看"—— 注入"把开关摘掉"必须回到这个形状。
// ② 开关**真的画出来**：每条可见源的卡片上有它，且 `value` 来自 `provider.enabled`（真相）。
// ③ **真点一下**：翻转 ── 用真宿主驱动（不全走替身糊过去）。
// ④ ⚡ **热重载**：点完**不重启**，断言界面读数立刻变（Owner 的验收动作）。
// ⑤ 反空真：开关的 key 必须带**源 id** —— 否则"所有卡共用一个 key"这种写法
//    在"只有一条可见源的夹具里"会照样全绿，而真机上 32 条源会串味。
// ```
//
// # 为什么 ④ 要单独一条
// ```text
// Owner 那句"必须重启才生效"是**验收动作**。若门禁只验"点了之后回调被调到"，
// 那么"点了界面不动、下次进页面才对"这种实现**照样绿** —— 而那正是被否定的形态。
// ⇒ 必须断言"点完之后、**同一个 widget 实例**上，界面的开关值已经变了"。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/design/widgets/app_switch.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

ProviderManifest p(String id, {bool enabled = true, String kind = 'js'}) =>
    ProviderManifest(
      id: id,
      name: id,
      version: '1',
      kind: kind,
      enabled: enabled,
    );

/// 找一个源卡片的开关
Finder switchOf(String id) =>
    find.byKey(ValueKey<String>('provider-enabled-switch-$id'));

void main() {
  // ───────────────────────────────────────────────────────────────
  //  ① 根因：`onToggle` 曾被"只声明、不渲染"
  // ───────────────────────────────────────────────────────────────
  group('① 根因形状：开关必须真的被渲染（不只是接了个回调）', () {
    testWidgets('★★★ 卡片的 _actions 里真的画了开关；value 来自 provider.enabled', (t) async {
      await t.pumpWidget(host(SizedBox(
        width: 700,
        child: settingsProviderCardForTest(
          provider: p('alpha', enabled: true),
          onToggle: () {},
          onEdit: () {},
        ),
      )));
      await t.pump();

      final sw = switchOf('alpha');
      expect(sw, findsOneWidget,
          reason: '★★★ 每张卡必须有启用/停用开关（Owner「源 页面 加上…现在没有」）。'
              '注入「把开关从卡片摘掉」⇒ 本条立刻红（回到缺陷形状）');

      final w = t.widget<AppSwitch>(sw);
      expect(w.value, isTrue,
          reason: '★★ 开关的 value 必须来自 `provider.enabled`（真相），'
              '不是本地猜的布尔');

      // 反面：enabled=false 的源，开关必须是关的
      await t.pumpWidget(host(SizedBox(
        width: 700,
        child: settingsProviderCardForTest(
          provider: p('beta', enabled: false),
          onToggle: () {},
          onEdit: () {},
        ),
      )));
      await t.pump();
      expect(t.widget<AppSwitch>(switchOf('beta')).value, isFalse,
          reason: '★★★ `enabled=false` 的源开关必须是关的'
              '（注入「value 写死 true」⇒ 本条红）');
    });

    /*
    // ⚠️⚠️ 这里原本有一条"宿主没给 onToggle ⇒ 不画开关"的 widget 用例，**已删除**。
    //
    // 为什么删（自查发现它是空真）：
    // ```text
    // `_ProviderCard` 是**私有**类 ⇒ 测试无法直接构造"不给 onToggle"的卡片；
    // 而两个公开工厂（settingsProviderCardForTest / settingsProviderCardsForTest）
    // **恒给** onToggle ⇒ 我第一版只好塞一个 `SizedBox.shrink()` 占位，
    // 那条用例**永远绿、永远不可能红** —— 这正是"空真"，比不写更有害
    // （它会让人以为"这条行为有机器判据"，而其实没有）。
    // ```
    // ⇒ 该行为改由**源码锚点**守（见下一条：`final VoidCallback? onToggle;`
    //   + 生产里的 `if (toggleEnabled != null)` 分支）——
    //   判据是"类型是可空的、且渲染被它闸住"，能红（改回 required ⇒ 红）。
    //
    // ★ 覆盖边界如实登记：**"onToggle==null 时不画"这一点没有 widget 级判据**，
    //   只有源码级判据。要补 widget 级，需要先给 `_ProviderCard` 开一个
    //   可注入 onToggle 的公开工厂（属重构，不在本卡范围）。
    */

    test('★★★ 源码锚点：开关在卡片的 actions 里，且 key 带源 id', () {
      final src = File('lib/ui/settings_page.dart').readAsStringSync();
      expect(
        RegExp(r"ValueKey<String>\('provider-enabled-switch-\$\{provider\.id\}'\)")
            .hasMatch(src),
        isTrue,
        reason: '★★★ 开关 key 必须带**源 id** —— 否则多条源共用一个 key，'
            '只在"单条源夹具"下绿，真机 32 条会串味（反空真）',
      );
      expect(RegExp(r'AppSwitch\([\s\S]{0,200}?value: provider\.enabled')
          .hasMatch(src), isTrue,
          reason: '★★ value 必须来自 provider.enabled（真相），不是本地布尔');
      // 卡片的 onToggle 必须是可空 —— "有没有这个能力"由类型表达
      expect(RegExp(r'final VoidCallback\? onToggle;').hasMatch(src), isTrue,
          reason: '★★ 可空才能表达"宿主没给能力"（改回 required ⇒ 本条红）');
      /*
       * ★★ 渲染必须被**可空性闸住** —— 这是"null ⇒ 不画"的**机器判据**
       *    （widget 级判据缺失的理由见上面那段"已删除"的说明）。
       *    注入「把闸去掉、无条件画」⇒ 本条红。
       */
      expect(
        RegExp(r'if \(toggleEnabled != null\) \.\.\.<Widget>\[').hasMatch(src),
        isTrue,
        reason: '★★★ 开关的渲染必须真的被"有没有能力"闸住'
            '（否则 onToggle==null 时会画出点了没用的假控件）',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ② 真点一下：开关翻转（行为级，走公开宿主驱动）
  // ───────────────────────────────────────────────────────────────
  group('② 真点一下 ⇒ 回调真的被调到（且不自己乱翻）', () {
    testWidgets('★★★ 点开关 ⇒ onToggle 被调 1 次；**界面值不提前变**（不许乐观更新）',
        (t) async {
      var taps = 0;
      await t.pumpWidget(host(SizedBox(
        width: 700,
        child: settingsProviderCardForTest(
          provider: p('alpha', enabled: true),
          onToggle: () => taps++,
          onEdit: () {},
        ),
      )));
      await t.pump();

      await t.tap(switchOf('alpha'));
      await t.pump();

      expect(taps, 1, reason: '★★★ 点开关必须真的回调宿主（否则点了没反应）');
      /*
       * ★★ 关键判据：回调之后界面**不该自己变** ——
       *   本卡是 StatelessWidget，`value` 来自 `provider.enabled`。
       *   宿主回调里读回真相 → 重拉列表 → 用**新 provider** 重建卡片，才该变。
       *   ⇒ 若有人在卡片里加 `bool _local` 先翻过去，本条立刻红。
       *     （那正是 `_toggleProvider` 注释明令防的"乐观更新"。）
       */
      expect(t.widget<AppSwitch>(switchOf('alpha')).value, isTrue,
          reason: '★★★ 回调返回但**宿主没给新 provider** ⇒ 开关必须保持真值。'
              '注入「卡片里加本地 bool 乐观取反」⇒ 本条红');
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ③ ⚡ 热重载：点完不重启，界面读数立刻变
  // ───────────────────────────────────────────────────────────────
  group('③ ⚡ 热重载（Owner 的验收动作：点完界面立刻跟，不许要重启）', () {
    testWidgets('★★★ 宿主翻转 enabled ⇒ 同一实例上开关立刻跟着变（不重启、不重进页）',
        (t) async {
      /*
       * 用**有状态宿主**驱动，形态与生产同构：
       *   点开关 → 宿主"写 → 读回真相" → 用**读回的真相**重建卡片。
       * ⇒ 断言：**同一个 widget 实例**（不重新 pumpWidget、不重启）
       *   上，开关的值已经变成新的真相。
       */
      final writer = _FakeEnabledStore(<String, bool>{'alpha': true});
      await t.pumpWidget(host(_EnabledHost(store: writer)));
      await t.pump();

      expect(t.widget<AppSwitch>(switchOf('alpha')).value, isTrue,
          reason: '前置：初始是启用');

      // ⚡ 真点一下 —— 之后**不重启、不重进页面**
      await t.tap(switchOf('alpha'));
      await t.pump();

      expect(writer.calls, 1, reason: '★ 必须真发了一次写入');
      expect(writer.valueOf('alpha'), isFalse, reason: '★★ 盘上（后端）真的翻转了');
      expect(t.widget<AppSwitch>(switchOf('alpha')).value, isFalse,
          reason: '★★★ ⚡ 热重载：点完**不重启**，界面开关必须**立刻**变成新真相。'
              '注入「回调后本地不重建」⇒ 本条红（那正是 Owner 否定的"要点重启才生效"）');
    });

    testWidgets('★★★ 后端说没改成 ⇒ 开关**弹回**、不撒谎（读回真相优先）', (t) async {
      /*
       * 这才是"热重载"的完整语义：界面跟的是**后端的真相**，不是"用户点了什么"。
       * 若后端拒绝（源已不存在等），开关必须回到原状。
       */
      final stub = _FakeEnabledStore(<String, bool>{'alpha': true}, forceKeep: true);
      await t.pumpWidget(host(_EnabledHost(store: stub)));
      await t.pump();

      await t.tap(switchOf('alpha'));
      await t.pump();

      expect(stub.valueOf('alpha'), isTrue, reason: '★ 后端没改（模拟拒绝）');
      expect(t.widget<AppSwitch>(switchOf('alpha')).value, isTrue,
          reason: '★★★ 后端没改成 ⇒ 开关必须**弹回真值**（否则是"界面开着、其实没生效"）。'
              '注入「界面改成乐观取反」⇒ 本条红');
    });
  });

  // ───────────────────────────────────────────────────────────────
  //  ④ 五分类之后各类卡片都带开关（含聚合源那一条）
  // ───────────────────────────────────────────────────────────────
  group('④ 各类可见源都有开关（含 TVBox 聚合源）', () {
    testWidgets('★★ 一条 JS 源 + 一条 TVBox 聚合源 ⇒ 两条都有开关，key 各自独立',
        (t) async {
      await t.pumpWidget(host(SizedBox(
        width: 700,
        child: settingsProviderCardsForTest(providers: <ProviderManifest>[
          p('cycani', kind: 'js'),
          p(kTvboxAggregateId, kind: 'tvbox'),
        ]),
      )));
      await t.pump();

      expect(switchOf('cycani'), findsOneWidget, reason: '★ JS 源要有开关');
      expect(switchOf(kTvboxAggregateId), findsOneWidget,
          reason: '★★★ TVBox 聚合源也要有（Owner 现在只留的两类之一）；'
              '注入「聚合源不画开关」⇒ 本条红 —— key 不同也顺带证明不是共用 key');
    });
  });
}

/// 假的"启用状态存储" —— 模拟后端的 `set_provider_enabled` + `get_provider_enabled`
///
/// # 为什么要一个**有状态**的宿主
/// ```text
/// "热重载"验的是"点完之后界面立刻对" ⇒ 必须有东西**在点之后产出新真相**。
/// 用一个恒定的 `bool` 喂进去，只能验"渲染得对"，验不了"点完会变"。
/// ```
class _FakeEnabledStore {
  _FakeEnabledStore(this._m, {this.forceKeep = false});

  final Map<String, bool> _m;

  /// true ⇒ "写入无效"（模拟后端拒绝）：读回来还是原值
  final bool forceKeep;

  int calls = 0;

  bool valueOf(String id) => _m[id] ?? true;

  Future<bool> set(String id, bool want) async {
    calls++;
    if (!forceKeep) _m[id] = want;
    // 读回真相（后端说是什么就是什么）
    return _m[id] ?? true;
  }
}

/// 有状态宿主：与生产同构 —— 点开关 → 写 → **读回真相** → 用真相重建卡片
class _EnabledHost extends StatefulWidget {
  const _EnabledHost({required this.store});
  final _FakeEnabledStore store;

  @override
  State<_EnabledHost> createState() => _EnabledHostState();
}

class _EnabledHostState extends State<_EnabledHost> {
  static const String _id = 'alpha';

  /// 界面读的真相（初始取一次，等价于 `list_providers()` 的快照）
  late bool _truth;

  @override
  void initState() {
    super.initState();
    _truth = widget.store.valueOf(_id);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 700,
        child: settingsProviderCardForTest(
          provider: p(_id, enabled: _truth),
          onToggle: () async {
            // ① 写（期望）② 读回真相 ③ 按真相重建 —— 生产三步的等价形式
            final actual =
                await widget.store.set(_id, !widget.store.valueOf(_id));
            if (!mounted) return;
            setState(() => _truth = actual);
          },
          onEdit: () {},
        ),
      );
}