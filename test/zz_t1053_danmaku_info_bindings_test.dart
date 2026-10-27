// ignore_for_file: avoid_print
//
// ═══════════════════════════════════════════════════════════════════════
//  N6 · 弹幕信息面板：默认展开 + 绑定全量可见 + 解绑 —— 行为门禁
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（2026-10-27）：「我说的弹幕来源就是这个（弹幕信息卡片），这里
// 默认展开，然后来源、渠道、绑定的什么来源、哪一个弹幕都要显示出来，并且
// 支持解绑。」
//
// # 这份门禁钉四件事
// ```text
// ① 缺省展开 —— 不传 initiallyExpanded 也必须直接见全量卡片
//    （根因是 danmaku_info_panel.dart 的 initiallyExpanded = false）。
// ② 「绑定」区逐路渲染 —— 两路绑定 ⇒ 两行都在，各自显示番剧/集/id。
// ③ 解绑 —— 点「解绑」⇒ 回调携带该路；core 侧清存储后**重读为空**
//    （持久化证据：解绑态在真实 prefs 往返后仍是解绑态）。
// ④ 阴性对照 —— 本片源自带（旧10 强制常开语义）**没有**解绑入口。
//
// # 故障注入（先红后绿，日志落 .probe/）
// ```text
// n6-injectA.log  把缺省翻回 false ⇒ ①红
// n6-injectB.log  把 core 清除改成空操作 ⇒ ③红
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/batch_bind.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0B0D),
        body: Align(alignment: Alignment.topRight, child: child),
      ),
    );

/// 典型快照：bili 直连 + 有数据（展开卡片才有"已载入"那一行）
const _loaded = DanmakuInfoData(
  source: DanmakuFeedKind.bili,
  match: DanmakuPairKind.autoSearch,
  count: 1200,
  cid: 1602741036,
  enabled: true,
);

/// N6-② 的两路绑定 + 两路无绑定：Bili 绑了《无职转生》第2集（cid 1602741036，
/// 当前供弹），dan-api 绑了同一部第2集（库 #307）；本片源自带 / 本机外部无绑定。
const _twoBound = DanmakuInfoData(
  source: DanmakuFeedKind.bili,
  match: DanmakuPairKind.manual,
  count: 1900,
  cid: 1602741036,
  enabled: true,
  bindings: <DanmakuBindRouteView>[
    DanmakuBindRouteView(
      route: DanmakuBindRoute.sourceNative,
      label: '本片源自带',
      note: '片源自带，常开',
    ),
    DanmakuBindRouteView(
      route: DanmakuBindRoute.danApi,
      label: 'dan-api',
      workTitle: '无职转生',
      episodeNo: 2,
      bindId: 307,
      bound: true,
      unbindable: true,
    ),
    DanmakuBindRouteView(
      route: DanmakuBindRoute.bili,
      label: 'Bili',
      workTitle: '无职转生',
      episodeNo: 2,
      episodeTitle: '第2话 敬佩!',
      bindId: 1602741036,
      bound: true,
      active: true,
      unbindable: true,
    ),
    DanmakuBindRouteView(
      route: DanmakuBindRoute.localExternal,
      label: '本机外部',
    ),
  ],
);

/// 剥掉源码里的注释（**只留代码**）—— 与 `t73_search_order_test.dart:195`
/// 同一份实现。
///
/// # 为什么源码锚点**必须**剥注释（交叉复核 D1 的修法）
/// ```text
/// 一条「调用点必须显式传 X」的判据，若能被**注释里写着的 X** 满足，
/// 那它验的就是注释、不是代码 —— 删掉真代码、在注释里留同名，断言照样绿。
/// 本文件第一版就踩了这个（`.probe/t5-crosscheck-inject-R5.log`）。
/// ```
/// ⚠️ 实现要点：**字符串字面量里的 `//` 与 `/*` 不算注释**
///   （否则 `'https://…'` 会把后面整行当注释吃掉）⇒ 必须带引号状态机。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\') {
        if (i + 1 < src.length) {
          out.write(src[i + 1]);
          i += 2;
          continue;
        }
      } else if (c == quote) {
        quote = null;
      }
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  group('N6-① 缺省展开', () {
    testWidgets('★★★ 不传 initiallyExpanded ⇒ 直接见全量卡片', (t) async {
      await t.pumpWidget(_host(const DanmakuInfoPanel(data: _loaded)));
      await t.pumpAndSettle();
      // "已载入"只在展开卡片里有；收起窄条只有「弹幕 N」。
      expect(find.text('已载入'), findsOneWidget,
          reason: '★★★ Owner：「这里默认展开」—— 点开徽标就是要看详情，'
              '不许还要再点一次');
    });

    testWidgets('★ 显式传 false 仍可收成窄条（× 的收起能力保留）', (t) async {
      await t.pumpWidget(
          _host(const DanmakuInfoPanel(data: _loaded, initiallyExpanded: false)));
      await t.pumpAndSettle();
      expect(find.text('已载入'), findsNothing,
          reason: '★ 收起能力必须保留 —— 缺省翻面不许把窄条形态删了');
    });
  });

  group('N6-② 绑定区逐路渲染', () {
    testWidgets('★★★ 两路绑定 ⇒ 两行都在，各自显示番剧/集/id', (t) async {
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        data: _twoBound,
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();

      expect(find.text('绑定'), findsOneWidget, reason: '★ 分区标题要在');
      // Bili 行：番剧名 + 集 + cid（cid 是 Bili 路的 id 语系）
      expect(find.textContaining('无职转生'), findsWidgets,
          reason: '★ 番剧名要显示（Bili 与 dan-api 两行都有）');
      expect(find.textContaining('第2集'), findsWidgets, reason: '★ 集号要显示');
      expect(find.textContaining('cid 1602741036'), findsOneWidget,
          reason: '★★★ Bili 路的绑定 id 就是 cid —— Owner 要看"哪一个弹幕"');
      // dan-api 行：id 语系是弹幕库 episodeId，必须与 cid 区分开
      expect(find.textContaining('库 #307'), findsOneWidget,
          reason: '★★★ dan-api 路显示弹幕库 id，不许和 cid 混成一个数');
      expect(find.text('dan-api：无职转生'), findsOneWidget);
    });

    testWidgets('★★ 当前实际供弹的是哪一路要有徽标，且只标那一路', (t) async {
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        data: _twoBound,
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();

      expect(find.text('供弹中'), findsOneWidget,
          reason: '★★ 两路都绑了，但实际供弹的只有一路 —— '
              '两路都标"供弹中"就是撒谎');
    });

    testWidgets('★★ 没绑定的路如实说「未绑定」；带 note 的路说 note', (t) async {
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        data: _twoBound,
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();

      expect(find.text('本片源自带：片源自带，常开'), findsOneWidget,
          reason: '★ 片源自带不是"未绑定"（它根本不需要绑定）—— 不能说谎');
      expect(find.text('本机外部：未绑定'), findsOneWidget,
          reason: '★ 没绑定就说未绑定 —— 重新绑定走独立搜索页（旧11）');
    });

    testWidgets('★ 宿主没递 bindings ⇒ 不画这一节（退化成原样）', (t) async {
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        data: _loaded,
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();
      expect(find.text('绑定'), findsNothing,
          reason: '★ 空列表 = 宿主没接线 —— 不许画一个空的绑定区');
    });
  });

  group('N6-③ 解绑', () {
    testWidgets('★★★ 点「解绑」⇒ 回调携带那一路', (t) async {
      DanmakuBindRoute? unbound;
      await t.pumpWidget(_host(DanmakuInfoPanel(
        data: _twoBound,
        initiallyExpanded: true,
        onUnbindRoute: (r) => unbound = r,
      )));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('dm-unbind-bili')));
      await t.pumpAndSettle();
      expect(unbound, DanmakuBindRoute.bili,
          reason: '★★★ 面板只上报"解哪一路"；清存储/刷弹幕归宿主');
    });

    testWidgets('★★ 每条可解绑的绑定行都有入口', (t) async {
      DanmakuBindRoute? unbound;
      await t.pumpWidget(_host(DanmakuInfoPanel(
        data: _twoBound,
        initiallyExpanded: true,
        onUnbindRoute: (r) => unbound = r,
      )));
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('dm-unbind-danApi')), findsOneWidget,
          reason: '★ dan-api 路有绑定记录 ⇒ 有解绑入口');
      expect(find.byKey(const ValueKey('dm-unbind-bili')), findsOneWidget);
      expect(find.byKey(const ValueKey('dm-unbind-sourceNative')), findsNothing,
          reason: '★★★ 阴性对照：本片源自带（旧10 强制常开）永远没有解绑入口');
      expect(find.byKey(const ValueKey('dm-unbind-localExternal')), findsNothing,
          reason: '★ 本机外部没有逐片绑定记录 ⇒ 无可解之物');
      expect(unbound, isNull, reason: '★ 只是挂载不该误触回调');
    });

    testWidgets('★ 宿主没给回调 ⇒ 不画解绑入口（不画点了没反应的死按钮）', (t) async {
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        data: _twoBound,
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('dm-unbind-danApi')), findsNothing,
          reason: '★ 回调没接 = 宿主没接线 —— 画出来就是个死按钮');
      expect(find.text('解绑'), findsNothing);
    });

    testWidgets('★★ 解绑后宿主重建快照 ⇒ 该路显示「未绑定」', (t) async {
      // 行为级：模拟宿主在回调后重建 data（bound 翻 false）再挂载。
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        data: _twoBound,
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();
      expect(find.textContaining('cid 1602741036'), findsOneWidget);

      const after = DanmakuInfoData(
        source: DanmakuFeedKind.bili,
        match: DanmakuPairKind.manual,
        count: 1900,
        enabled: true,
        bindings: <DanmakuBindRouteView>[
          DanmakuBindRouteView(
            route: DanmakuBindRoute.bili,
            label: 'Bili',
          ),
          DanmakuBindRouteView(
            route: DanmakuBindRoute.danApi,
            label: 'dan-api',
            workTitle: '无职转生',
            episodeNo: 2,
            bindId: 307,
            bound: true,
            unbindable: true,
          ),
        ],
      );
      await t.pumpWidget(_host(const DanmakuInfoPanel(
        data: after,
        initiallyExpanded: true,
      )));
      await t.pumpAndSettle();
      expect(find.text('Bili：未绑定'), findsOneWidget,
          reason: '★★ 解绑后回到未绑定态 —— 面板不能残留旧绑定');
      expect(find.textContaining('cid 1602741036'), findsNothing);
    });
  });

  group('N6-core 渠道边界与持久化（真实 prefs 往返）', () {
    const p = 'test-provider';
    const id = 't1053-roundtrip';

    test('★★★ 解绑边界：本片源自带/本机外部不可解，dan-api/Bili 可解', () {
      expect(danmakuChannelUnbindable(DanmakuBindChannel.sourceNative), isFalse,
          reason: '★★★ 旧10 强制常开语义 —— 本片源自带不许解绑');
      expect(danmakuChannelUnbindable(DanmakuBindChannel.localExternal), isFalse,
          reason: '★ 本机外部没有逐片绑定记录');
      expect(danmakuChannelUnbindable(DanmakuBindChannel.danApi), isTrue);
      expect(danmakuChannelUnbindable(DanmakuBindChannel.bili), isTrue);
    });

    test('★★★ dan-api 路快照现读既有 DanmakuBindStore（不新造存储）', () {
      saveDanmakuBind(p, id, const DanmakuBindStore(
        workTitle: '无职转生',
        episodes: <int, int>{0: 101, 2: 307},
      ));
      final hit = loadDanmakuChannelBinding(p, id, 2);
      expect(hit, isNotNull);
      expect(hit!.channel, DanmakuBindChannel.danApi);
      expect(hit.workTitle, '无职转生');
      expect(hit.episodeIndex, 2);
      expect(hit.bindId, 307, reason: '★ 该集的弹幕库 episodeId');
      expect(hit.bound, isTrue);

      // 整部绑了但这一集没在映射里 ⇒ 如实说"这一集没绑"
      expect(loadDanmakuChannelBinding(p, id, 1), isNull,
          reason: '★ 缺集不许拿别的集冒充（旧10/11 同一条"不撒谎"纪律）');
      // 没绑过 ⇒ null
      expect(loadDanmakuChannelBinding('nope', 'nope', 0), isNull);
      clearDanmakuBind(p, id);
    });

    test('★★★ 解绑 = 真清存储，重读为空（持久化证据）', () {
      saveDanmakuBind(p, id, const DanmakuBindStore(
        workTitle: '无职转生',
        episodes: <int, int>{2: 307},
      ));
      expect(loadDanmakuChannelBinding(p, id, 2), isNotNull,
          reason: '★ 前置：先确认真的绑上了');

      clearDanmakuChannelBinding(p, id);
      expect(loadDanmakuBind(p, id), isNull,
          reason: '★★★ 清除必须落到既有命名空间（UiPrefs），'
              '重进页面读出来仍是解绑态 —— 这就是持久化证据');

      // 解绑后可重新绑定：upsert 仍写同一把键
      saveDanmakuBind(p, id, const DanmakuBindStore(
        workTitle: '无职转生',
        episodes: <int, int>{2: 999},
      ));
      expect(loadDanmakuChannelBinding(p, id, 2)!.bindId, 999,
          reason: '★ 解绑 → 重新走独立搜索页绑定，链路必须还是通的');
      clearDanmakuBind(p, id);
      expect(UiPrefs.get('$kDanmakuBindPrefix.$p:$id'), isNull,
          reason: '★ 测试不留垃圾键');
    });

    test('★ dan-api 与 Bili 两把键不串（T113c-3 契约在 N6 下仍成立）', () {
      saveDanmakuBind(p, '$id-a', const DanmakuBindStore(
        workTitle: 'w', episodes: <int, int>{0: 1}));
      // Bili 路的解绑归 bili_bind.dart 的 clearBinding（本文件不许 import 它）；
      // 这里只钉：清 dan-api 路不动 Bili 路的键空间。
      clearDanmakuChannelBinding(p, '$id-b');
      expect(loadDanmakuChannelBinding(p, '$id-a', 0), isNotNull,
          reason: '★ 清 A 路不许误伤别的键');
      clearDanmakuBind(p, '$id-a');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  ★★★ 2026-10-27（Lead 补，实测缺口）：**宿主挂载点必须真的接线**
  // ═══════════════════════════════════════════════════════════════════════
  //
  // # 缺口是怎么被发现的（不是推测，是实跑）
  // ```text
  // 上面所有用例（① ② ③…）**全部直接构造 `DanmakuInfoPanel`** ——
  // 它们证明"面板自己没问题"，但**完全不覆盖宿主挂载点**。
  // 实测：把 `player_page.dart` 的 `initiallyExpanded: true` 注入成 false
  // ⇒ 本文件**全绿不红**（`.probe/n6-injectC.log`，EXIT=0）。
  // ⇒ "宿主接线"这一整段没有任何门禁看着 —— 正是本仓点名的
  //   「看着绿、其实没覆盖」。
  // ```
  //
  // # 为什么只能做源码锚点判据
  // ```text
  // 宿主是 `_PlayerPageState`（私有 State），它的展开态由内部
  // `_danmakuInfoOpen` / 挂载条件共同决定，且依赖真播放器（native-media）。
  // 在普通 widget 测试里构造不出"从徽标点进来的那条路径"。
  // ⇒ 退一档：钉**调用点上的三件事必须逐字在位**（都是源码里可判的事实），
  //   并配"删掉任一条即红"的注入证据。行为级判据由上一条用例
  //   （面板自己的缺省）覆盖，两者互补。
  // ```
  group('N6-host 宿主挂载点接线（Lead 补：覆盖实测缺口）', () {
    /*
     * ⚠️ ★ 2026-10-27（**交叉复核 D1**，复核者 tvbox-rust）：
     *   本组第一版读源码**不剥注释** ⇒ 把代码行 `initiallyExpanded: true,`
     *   删掉、只在**注释里**留同名 ⇒ 那条 ★★★ 断言**仍绿**（注释满足了判据）。
     *   实验：`.probe/t5-crosscheck-inject-R5.log`（复核者的实验）。
     *
     * # 定性（复核者 R7 自我纠正后的准确说法，别高估这条）
     * ```text
     * 不是假绿 —— 单删宿主行时**面板缺省兜着、行为没坏**，那时绿是**正确**读数；
     * 更严格的 R7（删宿主行 + 面板缺省翻 false，真功能失效）⇒ `+17 -2`，
     * 行为层与锚点层**都红**。
     * ⇒ 准确定性：**判据强度低于它的 ★★★ 标记**（可被注释满足）。
     * ```
     *
     * # 修法（照 `t73_search_order_test.dart:195` 的先例：源码锚点必须剥注释）
     * 注释不是代码 —— 一条"调用点必须显式传 X"的判据，被一句写着 X 的**注释**
     * 满足，就是在验注释而不是验代码。
     */
    final src = _stripComments(File('lib/ui/player_page.dart').readAsStringSync());

    test('★★★ 宿主必须显式传 initiallyExpanded: true（面板缺省被谁改都要挡住）',
        () {
      expect(
        src.contains('initiallyExpanded: true'),
        isTrue,
        reason: '★★★ 宿主挂载点必须显式要求展开 —— '
            '注入「改成 false / 删掉这行」本条立刻红'
            '（实测：删掉后 t1053 其余用例全绿，只有本条能抓住）',
      );
    });

    test('★★★ 宿主必须把解绑回调接到 State 上的实现（不是画个死按钮）', () {
      expect(
        src.contains('onUnbindDanmakuRoute: _unbindDanmakuRoute'),
        isTrue,
        reason: '★★★ 解绑的落点必须在宿主 State（清存储 + 重取弹幕）；'
            '面板那边的回调没接就不会画解绑入口',
      );
      expect(
        src.contains('void _unbindDanmakuRoute(DanmakuBindRoute route)'),
        isTrue,
        reason: '★ 那个回调必须真的有实现',
      );
      // 两条硬边界：只清**既有存储**，不新造存储
      expect(src.contains('clearDanmakuBind(p, id)'), isTrue,
          reason: '★ dan-api 路解绑 = 清既有 UiPrefs 绑定');
      expect(src.contains('clearBinding(p, id)'), isTrue,
          reason: '★ Bili 路解绑 = 清既有 bili_bind 绑定');
    });

    test('★★★ 绑定明细必须走 DanmakuInfoData（不是往 Panel 构造器乱塞）', () {
      expect(
        src.contains('bindings: _danmakuInfoVisible ? _danmakuBindings'),
        isTrue,
        reason: '★★★ 明细是 `DanmakuInfoData.bindings` 的字段 —— '
            '必须随 data 进面板（往 Panel 构造器传会直接 analyze 报错）',
      );
      expect(
        src.contains('List<DanmakuBindRouteView> get _danmakuBindings'),
        isTrue,
        reason: '★ 那个 getter 必须存在（现读既有存储拼四路明细）',
      );
    });

    test('★★ 不可解绑那两路必须 unbindable: false（旧10 边界在宿主侧也成立）', () {
      // 四路里 sourceNative / localExternal 各一处 unbindable: false
      final n = 'unbindable: false'.allMatches(src).length;
      expect(n, greaterThanOrEqualTo(2),
          reason: '★★ 本片源自带 + 本机外部两路在宿主侧也要标 false'
              '（面板侧还有一道，两处独立）');
    });

    test('★ 阴性对照：宿主侧源码里不再残留"窄条缺省"的旧写法', () {
      expect(src.contains('initiallyExpanded: false'), isFalse,
          reason: '★ 宿主不许再出现窄条缺省（面板侧那条也一样，见 ①）');
    });
  });
}
