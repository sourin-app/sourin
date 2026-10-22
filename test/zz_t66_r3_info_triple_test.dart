// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R3-⑥ 弹幕信息面板：**具体哪个源 / 上次更新时间 / 一共多少条**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 弹幕信息要显示 具体哪个源/上次更新时间/一共多少条
// ```
//
// # 改前是什么（读数，不是想象）
// ```text
// danmaku_info_panel.dart:551 `_sourceRow` 只画 `d.source.label` —— 那是**类别**
//   （`外部视频站直连` / `dan-api` / `本机弹弹play`），
//   而"具体哪一个"（内置实例 A 还是 B / 哪个插件 / 哪个端点）**画不出来**。
// 面板里**根本没有**"上次更新"这一行 —— 全仓 grep `上次更新` 在 UI 层 0 命中。
// 条数有（`_countRow`，`:569`），但只有裸数字，与上面两件事并列不起来。
// ⇒ Owner 说的三件事里，**两件半是缺的**。
// ```
//
// # 本门禁钉什么
// ```text
// ① 三种情形（有数据 / 无数据 / 有错误）各断言三段信息都在
// ② "不知道"不许画成"知道"：没给 updatedAt 且没观察到变化 ⇒ 必须写「未记录」，
//    绝不许出现「刚刚」（那是把未知画成已知）
// ③ 宿主给了 updatedAt ⇒ 用它，且**不加**"本次会话观察到"那句
//    宿主没给、面板自己观察到变化 ⇒ 用它，但**必须**加那句（局部事实 ≠ 全局事实）
// ④ 具体源名优先用宿主给的；没给时从聚合读数推；再没有才退成类别
// ⑤ 多路成功时**不挑一个**（挑谁都是撒谎）⇒ 说"N 路合并"
// ```
//
// # 故障注入（已实测，见交付说明）
// ```text
// 把 `_sourceRow` 改回只画 `d.source.label`          ⇒ ①②③ 组的"具体源名"全红
// 把 `_updatedLine` 改成无条件 `_relative(now)`       ⇒ ②组的"未记录"红
// 把 `fromHost ? ... : '... 本次会话观察到'` 的三元拆开（永远加尾巴）⇒ ③组宿主支红
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0B0D),
        body: Align(alignment: Alignment.topRight, child: child),
      ),
    );

/// 把面板渲染出来（展开态）并等定
Future<void> _pump(WidgetTester t, DanmakuInfoData d) async {
  await t.pumpWidget(_host(
    DanmakuInfoPanel(data: d, initiallyExpanded: true),
  ));
  await t.pumpAndSettle();
}

/// ① 有数据：宿主把三件事都给了（真实形状照抄 player_page 的构造点）
DanmakuInfoData _withData() => DanmakuInfoData(
      source: DanmakuFeedKind.service,
      match: DanmakuPairKind.manual,
      count: 1200,
      total: 1300,
      title: '鬼灭之刃 柱训练篇',
      cid: 1602741036,
      enabled: true,
      // ★ 宿主给了具体是谁 + 上次更新时间（这正是本次要接的两根线）
      sourceName: '内置公共实例 A · https://danmu-api-delta.vercel.app',
      updatedAt: DateTime.now().subtract(const Duration(minutes: 3)),
    );

/// ② 无数据：没问过（count = null）+ 宿主没给源名/时间
const _noData = DanmakuInfoData(
  source: DanmakuFeedKind.none,
  match: DanmakuPairKind.none,
);

/// ③ 有错误：连接失败，面板仍要把三段信息画全
const _withError = DanmakuInfoData(
  source: DanmakuFeedKind.service,
  match: DanmakuPairKind.none,
  count: 0,
  enabled: true,
  sourceName: '内置公共实例 B · https://danmu-api-kappa.vercel.app',
  error: '连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。',
);

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 三种情形 × 三段信息
  // ═══════════════════════════════════════════════════════════════════
  group('① 三种情形下，三段信息都必须**同时在**', () {
    testWidgets('★ 有数据：具体哪个源 / 上次更新 / 一共多少条', (t) async {
      await _pump(t, _withData());

      // ── 第 1 段：具体哪个源（不是类别）──
      expect(
        find.textContaining('公共实例 A'),
        findsOneWidget,
        reason: '★★★ Owner 原话「具体哪个源」—— 类别回答不了这个',
      );
      expect(
        find.textContaining('danmu-api-delta'),
        findsOneWidget,
        reason: '★ 具体到地址/标识，否则"内置实例 A 还是 B"仍然分不清',
      );
      // 类别仍然在（两个问题分开回答），但它是**小字第二行**
      expect(find.text('danmaku-service'), findsOneWidget,
          reason: '★ 类别维度不能丢 —— 它是分类，不是具体的那个');

      // ── 第 2 段：上次更新时间 ──
      expect(find.text('上次更新'), findsOneWidget,
          reason: '★★★ Owner 原话「上次更新时间」—— 改前面板里根本没有这一行');
      expect(find.textContaining('3 分钟前'), findsOneWidget,
          reason: '★ 宿主给的时刻要**真的**画出来（3 分钟前）');

      // ── 第 3 段：一共多少条 ──
      expect(find.text('已载入'), findsOneWidget);
      expect(find.textContaining('1200'), findsWidgets,
          reason: '★ 条数真值');
      expect(find.textContaining('共 1300 条'), findsOneWidget,
          reason: '★ 服务端声明总数时要说"一共多少"，不能只报已载入');
    });

    testWidgets('★ 无数据：「不知道」必须明说成「未查询 / 未记录」', (t) async {
      await _pump(t, _noData);

      // 具体源名：宿主没给、聚合也空 ⇒ 退成类别（且不撒谎说有个具体名字）
      expect(find.text('未取到'), findsOneWidget,
          reason: '★ 没有来源时如实说"未取到"');

      // 上次更新：**没有**观察到、宿主也没给 ⇒ 必须写"未记录"
      expect(find.text('上次更新'), findsOneWidget,
          reason: '★★★ 无数据时这一行也要在 —— 缺一行用户会以为是坏了');
      expect(find.textContaining('未记录'), findsOneWidget,
          reason: '★★★ 不知道就说不知道');
      expect(find.textContaining('刚刚'), findsNothing,
          reason: '★★★ 把"不知道"画成"刚刚"就是撒谎（与 count 的 null≠0 同一条纪律）');

      // 条数：null 明说成未查询
      expect(find.textContaining('未查询'), findsOneWidget);
    });

    testWidgets('★ 有错误：失败原因照透，三段信息一个不少', (t) async {
      await _pump(t, _withError);

      expect(find.text('失败原因'), findsOneWidget);
      expect(find.textContaining('连不上弹幕服务'), findsOneWidget,
          reason: '★ 原文照透（这是面板存在的理由）');

      // ★ 失败时三段**仍然**要在 —— 否则用户只剩一句报错，无从判断"哪一路失败了"
      expect(find.textContaining('公共实例 B'), findsOneWidget,
          reason: '★★ 失败时**更**需要知道是哪个源');
      expect(find.text('上次更新'), findsOneWidget,
          reason: '★★ 失败时也要说明上次成功是什么时候（能区分"一直没好"和"刚刚坏的"）');
      expect(find.text('已载入'), findsOneWidget,
          reason: '★★ 失败时条数仍然要显示（0 条 vs 未知 是两件事）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② "上次更新"的三种事实不许互相冒充
  // ═══════════════════════════════════════════════════════════════════
  group('② 上次更新：宿主事实 / 本次观察 / 未记录 —— 三者分开', () {
    testWidgets('★★★ 宿主给了 ⇒ 用它，且**不加**"本次会话观察到"', (t) async {
      final at = DateTime.now().subtract(const Duration(hours: 2));
      await _pump(
        t,
        DanmakuInfoData(
          source: DanmakuFeedKind.bili,
          count: 40,
          enabled: true,
          sourceName: '外部视频站直连 · cid 1602741036',
          updatedAt: at,
        ),
      );

      expect(find.textContaining('2 小时前'), findsOneWidget,
          reason: '★ 宿主给的是**全局事实**，按它画');
      expect(find.textContaining('本次会话观察到'), findsNothing,
          reason: '★★ 宿主给的事实用不着加"这是我在会话里看到的" —— 那是降级口径');
    });

    testWidgets('★★ 宿主没给、面板也没观察到 ⇒ 未记录（不是"刚刚"）', (t) async {
      await _pump(
        t,
        const DanmakuInfoData(
          source: DanmakuFeedKind.bili,
          count: 40,
          enabled: true,
        ),
      );

      expect(find.textContaining('未记录'), findsOneWidget);
      expect(find.textContaining('刚刚'), findsNothing,
          reason: '★★★ 挂载那一刻不是"弹幕被更新时间"');
    });

    testWidgets('★★ 面板观察到数据真的变了 ⇒ 记那时，并**明说**是本次观察到的',
        (t) async {
      // 先挂上：有来源但还没数据
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        data: DanmakuInfoData(source: DanmakuFeedKind.bili, enabled: true),
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();
      expect(find.textContaining('未记录'), findsOneWidget,
          reason: '起点：还没观察到任何变化');

      // 数据回来了（条数从 null → 1200）⇒ 这就是"这次更新"
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        data: DanmakuInfoData(
          source: DanmakuFeedKind.bili,
          count: 1200,
          enabled: true,
        ),
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();

      expect(find.textContaining('刚刚'), findsOneWidget,
          reason: '★ 变量变了 ⇒ 此刻就是更新时间');
      expect(find.textContaining('本次会话观察到'), findsOneWidget,
          reason: '★★★ 必须标明这是**本面板**看到的局部事实 —— '
              '它不是弹幕库里的 fetchedAt，冒充全局事实就是撒谎');
    });

    testWidgets('★ loading 开始≠一次更新（刷一次不该把时间刷成"刚刚"）',
        (t) async {
      final at = DateTime.now().subtract(const Duration(hours: 5));
      await t.pumpWidget(_host(DanmakuInfoPanel(
        data: DanmakuInfoData(
          source: DanmakuFeedKind.bili,
          count: 300,
          enabled: true,
          updatedAt: at,
        ),
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();
      expect(find.textContaining('5 小时前'), findsOneWidget);

      // 用户点了「重新获取」⇒ loading = true（数据还没变）
      await t.pumpWidget(_host(DanmakuInfoPanel(
        data: DanmakuInfoData(
          source: DanmakuFeedKind.bili,
          count: 300,
          enabled: true,
          updatedAt: at,
          loading: true,
        ),
        initiallyExpanded: true,
      )));
      /*
       * ⚠️ 这里**不能**用 pumpAndSettle：loading 态里有 CircularProgressIndicator
       *    （永远转）⇒ pumpAndSettle 永远等不到"静止"，9 秒后超时。
       *    只推两帧就够读文案了。
       */
      await t.pump();
      await t.pump(const Duration(milliseconds: 32));
      expect(find.textContaining('5 小时前'), findsOneWidget,
          reason: '★ 开始取 ≠ 更新完成；把它刷成"刚刚"会让用户以为已经取回来了');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 具体源名的退路（宿主没给时不许瞎猜）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 具体源名的三级退路', () {
    testWidgets('★★ 单路成功 ⇒ 用那一路的 label + detail', (t) async {
      await _pump(
        t,
        const DanmakuInfoData(
          source: DanmakuFeedKind.bili,
          count: 500,
          enabled: true,
          aggregate: <DanmakuAggregateFeed>[
            DanmakuAggregateFeed(
              label: '插件提供',
              count: 500,
              detail: 'acg-plugin',
            ),
          ],
        ),
      );
      expect(find.textContaining('acg-plugin'), findsOneWidget,
          reason: '★ detail 本来就是"具体是谁"（插件 id / 端点 / 文件名）');
    });

    testWidgets('★★★ 多路成功 ⇒ 说"N 路合并"，**不挑一个**冒充', (t) async {
      await _pump(
        t,
        const DanmakuInfoData(
          source: DanmakuFeedKind.bili,
          count: 900,
          enabled: true,
          aggregate: <DanmakuAggregateFeed>[
            DanmakuAggregateFeed(label: '插件提供', count: 500, detail: 'acg-plugin'),
            DanmakuAggregateFeed(label: '导入源', count: 400, detail: '弹幕库 #123'),
          ],
        ),
      );
      expect(find.textContaining('2 路合并'), findsOneWidget,
          reason: '★★★ 挑其中一路当"具体源"就是撒谎 —— 两路都在供');
      expect(find.textContaining('acg-plugin'), findsNothing,
          reason: '★★ 反证：不许把第一路偷偷当成"唯一来源"');
      // 但每一路的名字仍然逐条列着（下面的"各路"节）
      expect(find.textContaining('插件提供：500 条'), findsOneWidget);
      expect(find.textContaining('导入源：400 条'), findsOneWidget);
    });

    testWidgets('★★ 一路都没有 ⇒ 退成类别名（不编造）', (t) async {
      await _pump(
        t,
        const DanmakuInfoData(
          source: DanmakuFeedKind.localDanmaku,
          count: 0,
          enabled: true,
        ),
      );
      expect(find.text('本机弹弹play'), findsOneWidget,
          reason: '★ 没有更具体的信息时退成类别 —— 类别本身是真的');
    });
  });
}
