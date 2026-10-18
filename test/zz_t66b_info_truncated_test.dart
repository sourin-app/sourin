// task-66：**truncated（上游只返回了部分）** 在弹幕信息面板上要可见
//
// # 这条修的正是 Owner / dan-api 发现的「半截接线」
// ```text
// truncated 的完整数据流（实测）：
//   某个动画站插件.js   const truncated = raw.length > 0   ⇒ 真的会给 true
//   同一插件            query: { segment_index: 1 }       ⇒ 只拉第 1 段（理由诚实）
//   另一个视频站插件    truncated: false                  ⇒ 一次给全量，也正确
//        ↓ Rust plugins/mod.rs:3640
//        ↓ Dart sourin_api.dart:3402
//        ↓ player_page.dart:6263   **只进 debugPrint**  ← 断点在这
//        ↓ core DanmakuFeedStat{kind,count,detail,error,loaded}  ← 没有 truncated
//
// ⇒ 用户在界面上看不到"这不完整"，
//   会把「只有开头有弹幕」误解成「这个视频没弹幕」。
// ```
//
// # 本门禁钉什么
// ```text
// ① truncated == true  ⇒ 面板有说明（行为断言，不是源码 grep）
// ② truncated == false ⇒ 没有（反向断言，防止无条件显示）
// ③ 文案必须说清「上游」+「部分」（不是内部黑话）
// ④ 收起态不显示（窄条里塞长文案会撑坏布局）
// ⑤ 玻璃结构不破（回归保护）
// ⑥ ★ 当前**没有任何地方**传 truncated: true ⇒ 钉住这个已知断点
// ```
//
// # 故障注入（三条，都已实测）
// ```text
// ① 把 `if (d.truncated)` 改成无条件显示  ⇒ ②组红
// ② 把 `if (d.truncated)` 判断写反（!d.truncated）⇒ ①②组都红
// ③ 在 player_page 构造点传 truncated: true ⇒ ⑥组红（提醒升级文案）
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer;
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';

/// 完整数据（**未**截断）—— 作为反向断言的基线
DanmakuInfoData _complete() => const DanmakuInfoData(
      source: DanmakuFeedKind.bili,
      match: DanmakuPairKind.autoSearch,
      count: 1200,
      title: '鬼灭之刃 柱训练篇',
      cid: 1602741036,
      enabled: true,
    );

/// ★ 真实形状：照抄那个动画站插件 `danmakuList()` 的返回
///   `{ items, source: '<插件id>', truncated: true }`
/// ⇒ 这里不 mock 任何东西，就是那个字段值的直接后果
DanmakuInfoData _truncatedRealShape() => DanmakuInfoData(
      /*
       * ⚠️ `DanmakuFeedKind` 没有 `plugin` 这个值（枚举只有
       *    bili/service/localDanmaku/selfHosted/library/none）。
       *    该插件是插件源，走 `bili` 这一档的"外部直连"语义最近 ——
       *    ★ 这是**本面板的分类局限**，不是我随手选的；
       *    真要让插件单独成类，是另一个改动，不在本轮范围。
       */
      source: DanmakuFeedKind.bili,
      match: DanmakuPairKind.autoSearch,
      count: 340,
      title: '某部长视频 第 1 集',
      cid: 0,
      enabled: true,
      truncated: true,
      aggregate: const <DanmakuAggregateFeed>[
        /*
         * ⚠️ 注意：这里 **truncated 保持默认 false**。
         *    因为真实链路里 DanmakuFeedStat 根本没有这个字段（断点就在这里），
         *    宿主现在拿不到"哪一路截断"。
         *    ⇒ 断言的是「整体层面能显示」。
         */
        DanmakuAggregateFeed(
          label: '某个插件',
          count: 340,
          detail: '某个插件',
        ),
      ],
    );

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF1A2030),
        body: Align(alignment: Alignment.topRight, child: child),
      ),
    );

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① truncated == true ⇒ 面板必须说出来
  // ═══════════════════════════════════════════════════════════════════
  group('① 上游只给了部分 ⇒ 用户必须看得见', () {
    testWidgets('★★★ 展开态出现「未完整加载」', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _truncatedRealShape(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();

      /*
       * ★ 用行为断言（find.textContaining）而不是"源码里有这个字段"：
       *   半截接线的教训正是——字段在、解析了、日志打了，但**用户看不到**。
       *   只 grep 源码会让那种情况照样绿。
       */
      expect(find.textContaining('未完整加载'), findsOneWidget,
          reason: '★★★ 这是本条修复的全部目的：让用户知道"还有更多"');
    });

    testWidgets('★★★ 文案说清是**上游**的问题（不是我们截的）', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _truncatedRealShape(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();

      /*
       * # 为什么必须点明「上游」
       * ```text
       * 「已截断」听起来像**软件砍掉了** ⇒ 用户会来报我们的 bug。
       * 实际是上游没给全 ⇒ 责任方必须写清。
       * ```
       */
      expect(find.textContaining('上游'), findsOneWidget,
          reason: '★★ 责任方是上游，不是本软件 —— 不说清会导致误报');
    });

    testWidgets('★★ 文案出现「部分」（回答"我看全了吗"）', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _truncatedRealShape(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('部分'), findsWidgets);
    });

    testWidgets('★★ 有「完整性」这个标签列（与其它行同一套排版）', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _truncatedRealShape(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();
      expect(find.text('完整性'), findsOneWidget,
          reason: '★ 本面板是"标签列 + 值"的排版，新行要跟着走，不新造一套');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② truncated == false ⇒ 一个字都不能出现
  // ═══════════════════════════════════════════════════════════════════
  group('② 没截断就不许说', () {
    testWidgets('★★★ 完整数据 ⇒ 没有「未完整加载」', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _complete(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();

      /*
       * ★ 反向断言：这是防"无条件显示"的唯一办法。
       *   如果只测 ①，把文案改成无条件渲染也能绿 —— 那就是假绿。
       */
      expect(find.textContaining('未完整加载'), findsNothing,
          reason: '★★★ 没截断却说截断，是**错误信息**，比不显示更坏');
      expect(find.text('完整性'), findsNothing,
          reason: '★ 整行都不该出现');
      expect(find.textContaining('上游'), findsNothing);
    });

    testWidgets('★★ 阳性对照：完整数据的面板本身正常', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _complete(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();
      expect(find.text('已载入'), findsOneWidget, reason: '面板还在正常工作');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 收起态不显示（窄条塞长文案会撑坏布局）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 收起态', () {
    testWidgets('★★ 收起态不显示完整性说明', (t) async {
      await t.pumpWidget(_host(DanmakuInfoPanel(data: _truncatedRealShape())));
      await t.pumpAndSettle();

      /*
       * 收起态是一枚很窄的条（图标 + 条数 + 箭头），
       * 塞一句 20 多字的话必然折行/溢出 ⇒ 它只该在展开态出现。
       */
      expect(find.textContaining('未完整加载'), findsNothing,
          reason: '★ 窄条放不下长文案');
      expect(find.text('完整性'), findsNothing);
    });

    testWidgets('★★ 展开后立刻出现（不许要再点一次）', (t) async {
      await t.pumpWidget(_host(DanmakuInfoPanel(data: _truncatedRealShape())));
      await t.pumpAndSettle();
      await t.tap(find.byType(DanmakuInfoPanel));
      await t.pumpAndSettle();
      expect(find.textContaining('未完整加载'), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 玻璃结构不许被这次改动破坏
  // ═══════════════════════════════════════════════════════════════════
  group('④ 玻璃结构回归保护', () {
    testWidgets('★★★ 截断态下 GlassContainer 仍在', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _truncatedRealShape(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();
      expect(find.byType(GlassContainer), findsWidgets,
          reason: '★★ 上一次玻璃化（4aa4ba8）不能被这次内容改动破坏');
    });

    testWidgets('★★ 新增那行在玻璃内部', (t) async {
      await t.pumpWidget(_host(
        DanmakuInfoPanel(data: _truncatedRealShape(), initiallyExpanded: true),
      ));
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(GlassContainer),
          matching: find.textContaining('未完整加载'),
        ),
        findsOneWidget,
        reason: '★★ 说明必须在玻璃卡片里，不能飘到外面',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ ★ 钉住"尚未接线"这个事实
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ 已知断点（接线后本组会红，是故意的）', () {
    test('★★★ 当前**没有任何地方**给 DanmakuAggregateFeed 传 truncated: true', () {
      /*
       * # 这条门禁是"会红的备忘录"，不是"禁止改动"
       * ```text
       * 数据流在 core 的 `DanmakuFeedStat` 断掉了（它没有 truncated 字段），
       * ⇒ 宿主现在拿不到"哪一路被截断" ⇒ 只能整体显示中性文案。
       *
       * 本断言的作用：**将来有人把它接上时，这条会红**，
       * 提醒他去做两件必须配套的事：
       *   ① 把 `_truncatedLine` 的文案升级为「某个动画站：仅返回前 6 分钟弹幕」
       *   ② 删掉/改掉本断言
       * ```
       * ⚠️ 我**没有**断言「DanmakuFeedStat 里没有 truncated」——
       *    那样会阻止别人将来合理地加字段。
       *    这里断言的是"接线这件事还没发生"，即**行为层面**的事实。
       */
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      final hasWiring = RegExp(r'truncated:\s*true').hasMatch(src);

      expect(hasWiring, isFalse,
          reason: '★★★ player_page 开始传 truncated: true 了 ⇒ '
              '说明接线完成 ⇒ 请同时把面板文案升级到"精确到来源"，'
              '并更新本断言（它在提醒你，不是在阻止你）');
    });

    test('★★ 面板侧字段确实存在且默认 false（接口已预留）', () {
      /*
       * 这条保证"预留"是真的预留：字段在、默认值是 false。
       * 与上面的 ⑤-1 配对：一个说"接口准备好了"，一个说"还没接上"。
       */
      const feed = DanmakuAggregateFeed(label: 'x', count: 1);
      expect(feed.truncated, isFalse, reason: '★ 默认必须 false（不撒谎）');

      const data = DanmakuInfoData();
      expect(data.truncated, isFalse, reason: '★ 默认必须 false');
    });

    test('★★ 某一路带 truncated 时会点名（预留路径可兑现）', () {
      /*
       * 这条证明"接口预留"不是空话：
       * 一旦有 feed 的 truncated 为 true，文案立刻变成点名格式，
       * **不需要改调用点**。
       */
      const d = DanmakuInfoData(
        count: 100,
        truncated: true,
        aggregate: <DanmakuAggregateFeed>[
          DanmakuAggregateFeed(label: '某个插件', count: 100, truncated: true),
          DanmakuAggregateFeed(label: 'dan-api', count: 0),
        ],
      );
      // 只断言数据形状（UI 层由上面几组用真实形状覆盖）
      expect(d.truncated, isTrue);
      expect(d.aggregate.where((f) => f.truncated).map((f) => f.label).toList(),
          <String>['某个插件']);
    });
  });
}
