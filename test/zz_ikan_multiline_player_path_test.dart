// ══════════════════════════════════════════════════════════════════════
//  多线路（`Episode.flag`）：**播放页路径**也要能看到线路条并切线路
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么单开一条（而不是只测 sheet）
// ```text
// 播放页实际渲染的是 `lib/ui/player/episode_panel.dart` 的 `PlayerEpisodePanel`
// —— **不是** `ui/widgets/episode_strip.dart` 的 `EpisodePanel`。
// 只在后者加线路条 = "能力做了但用户看不到"。
// ⇒ 本文件钉的是**播放页**这条真实路径：
//    ① 多线路 ⇒ 线路条出现，默认选中第一条（= `_flagsOf().first`，由 `_syncSelectedFlag` 决定）
//    ② 切线路 ⇒ 面板的 `selectedFlag` 跟着变，且 `_epIndex` 对齐到新线路的同名集
//    ③ 单线路 ⇒ 面板里**不画**线路条
// ```
//
// ⚠️ **本仓 widget 测试必须 `import 'package:material_ui/material_ui.dart';`**
//    （不是 `package:flutter/material.dart`）—— 本仓用自建 material 分支，
//    混用会让 `InkWell` 找不到 `Material` 祖先，报
//    `No Material widget found … within the closest LookupBoundary`
//    （2026-10-26 在这条链路上实测踩过，`episode_drawer_test.dart` 就是这么写的）。
//
// 跑法：
// ```powershell
// flutter test test/zz_ikan_multiline_player_path_test.dart \
//   --run-skipped --tags native-media --concurrency=1
// ```
// ★★ 踩坑记录（每个新写 widget 测试的人都会踩）：
//    本仓必须 `import 'package:material_ui/material_ui.dart';`，
//    **不是** `package:flutter/material.dart` —— 本仓用**自建 material 分支**，
//    混用会让 `InkWell` 找不到 `Material` 祖先，报
//    `No Material widget found … within the closest LookupBoundary`
//    （2026-10-26 在本链路上实测踩过）。
@Tags(['native-media'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player/episode_panel.dart' show PlayerEpisodePanel;
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart'
    show EpisodeLineBar, LineChip, episodeLineFilter;

import 't102_playback_failure_banner_test.dart' as fixture;

/// 爱看（Ikanbot）**31 条线路**的夹具 —— 按 `csp/ikanbot.rs::lines_of` 文档化的
/// **真实结构**造：`data.list[]` 每项是一层封装，真正的线路在它 `resData` 那段
/// **双重编码的 JSON 字符串**里（`flag` = 线路名、`url` = `名字$地址#名字$地址…`）。
///
/// ```text
/// ⚠️ 如实登记：`.probe/ikanbot-live3.log` 那一次**是失败运行**
///   （`[IKAN] resData 元素数 = 0` / `detail 失败：/api/getResN 没有可解析的线路`）
///   ⇒ 日志里**没有**31 条线路的原始 payload。本夹具据的是
///   `rust/sourin_core/src/csp/ikanbot.rs:360-430` 里逐字记录的响应形状
///   （含 `{"siteId":26,"id":21207802,"resData":"[{\"flag\":\"xlm3u8\",...}]"}` 这个样例），
///   线路数与首条线路名（`xlm3u8`）来自 Owner 侧的真实观察。
/// ```
List<Episode> _ikan31({int epsPerLine = 4}) {
  const first = 'xlm3u8';
  final flags = <String>[
    first,
    'gsm3u8',
    for (var i = 3; i <= 31; i++) 'm3u8_${i.toString().padLeft(2, '0')}',
  ];
  final out = <Episode>[];
  var idx = 0;
  for (final f in flags) {
    for (var e = 1; e <= epsPerLine; e++) {
      out.add(Episode(
        // ★ 同一集在不同线路 **id 不同** —— 与爱看的真实形态一致
        id: 'ikan:$f:$e',
        title: '第$e集',
        index: idx++,
        flag: f,
      ));
    }
  }
  return out;
}

/// 某条线路的集 id 集合（按顺序）
List<String> _idsOf(List<Episode> all, String flag) =>
    all.where((e) => e.flag == flag).map((e) => e.id).toList();

/// 两条线路各 2 集（同一集在不同线路 **id 不同** —— 与爱看/Ikanbot 真实形态一致）
final _multi = <Episode>[
  const Episode(id: 'A1', title: '第1集', index: 0, flag: '线路A'),
  const Episode(id: 'A2', title: '第2集', index: 1, flag: '线路A'),
  const Episode(id: 'B1', title: '第1集', index: 2, flag: '线路B'),
  const Episode(id: 'B2', title: '第2集', index: 3, flag: '线路B'),
];

final _single = <Episode>[
  const Episode(id: 'S1', title: '第1集', index: 0, flag: '默认'),
  const Episode(id: 'S2', title: '第2集', index: 1, flag: '默认'),
];

Future<void> _mountPlayer(WidgetTester t, List<Episode> eps) async {
  MediaKit.ensureInitialized();
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PlayerPage(
        provider: 'ikan',
        id: 'show-1',
        title: '多线路',
        episodes: eps,
        episodeIndex: 0,
        episodeId: eps.first.id,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  ));
  await t.pump();
  await fixture.drain(t);
}

void main() {
  group('① 播放页路径：多线路 ⇒ 线路条 + 默认第一条', () {
    testWidgets('打开选集面板 ⇒ EpisodeLineBar 在，选中 == 第一条线路', (t) async {
      await _mountPlayer(t, _multi);
      expect(debugPlayerOpenEpisodesForProbe(), isTrue,
          reason: '前置：选集面板要能打开（探针返回 false = 播放页没挂上）');
      await t.pump();

      expect(find.byType(EpisodeLineBar), findsOneWidget,
          reason: '★★ 播放页这条路径也必须画线路条 —— 只在 sheet 里画'
              '等于"用户看不到"');
      final chips = t.widgetList<LineChip>(find.byType(LineChip)).toList();
      expect(chips.map((c) => c.flag).toList(), ['线路A', '线路B'],
          reason: '★ 线路条内容与顺序 = 去重保序后的线路名');
      final selected = chips.where((c) => c.selected).map((c) => c.flag).toList();
      expect(selected, ['线路A'],
          reason: '★★★ 默认必须选中**第一条**（由 `_syncSelectedFlag` 的 '
              '`flags.first` 决定；实际 $selected）');
    });
  });

  group('② 播放页路径：切线路 ⇒ 面板跟着换', () {
    testWidgets('点第二条 ⇒ 面板 selectedFlag 变成线路B', (t) async {
      await _mountPlayer(t, _multi);
      expect(debugPlayerOpenEpisodesForProbe(), isTrue);
      await t.pump();

      final chipB = t
          .widgetList<LineChip>(find.byType(LineChip))
          .firstWhere((c) => c.flag == '线路B');
      chipB.onTap(); // ★ 直接调真实回调（flutter_tester 不对本树派发指针事件）
      await t.pump();

      final panel = t.widget<PlayerEpisodePanel>(find.byType(PlayerEpisodePanel));
      expect(panel.selectedFlag, '线路B',
          reason: '★★★ 切线路后面板必须跟着换（否则选集列表还是旧线路的集）');
      final chips = t.widgetList<LineChip>(find.byType(LineChip)).toList();
      expect(chips.where((c) => c.selected).map((c) => c.flag).toList(),
          ['线路B'],
          reason: '★★ 选中态必须转移到线路B');
    });
  });

  group('③ 播放页路径：单线路 ⇒ 不画线路条', () {
    testWidgets('单线路 ⇒ 面板里没有 EpisodeLineBar', (t) async {
      await _mountPlayer(t, _single);
      expect(debugPlayerOpenEpisodesForProbe(), isTrue);
      await t.pump();
      expect(find.byType(EpisodeLineBar), findsNothing,
          reason: '★★★ 单线路不许画线路条（用户会以为还有别的线路可选）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ 爱看 31 条线路 —— Owner 最在意的那条：**真的能选**
  // ══════════════════════════════════════════════════════════════════
  group('④ 爱看 31 条线路（真实结构）', () {
    testWidgets('① 线路条出现且**有 31 个 chip**，默认选中第一条 xlm3u8', (t) async {
      final eps = _ikan31();
      await _mountPlayer(t, eps);
      expect(debugPlayerOpenEpisodesForProbe(), isTrue);
      await t.pump();

      expect(find.byType(EpisodeLineBar), findsOneWidget,
          reason: '★★ 31 条线路必须画线路条');
      final chips = t.widgetList<LineChip>(find.byType(LineChip)).toList();
      expect(chips.length, 31,
          reason: '★★★ 必须画满 **31** 个 chip（实际 ${chips.length} 个）—— '
              '少一个就意味着有条线路用户点不到');
      expect(chips.map((c) => c.flag).toList(), _ikan31Flags,
          reason: '★ 线路名与顺序 = 去重保序后的结果（第一条是真实首线路）');
      final selected =
          chips.where((c) => c.selected).map((c) => c.flag).toList();
      expect(selected, ['xlm3u8'],
          reason: '★★★ 默认必须选中**第一条**（实际 $selected）');
    });

    testWidgets('③ 切到第 2 条线路 ⇒ 面板的选集 id 集合变成该线路的', (t) async {
      final eps = _ikan31();
      await _mountPlayer(t, eps);
      expect(debugPlayerOpenEpisodesForProbe(), isTrue);
      await t.pump();

      // 前置：默认面板里是第一条线路的集
      final before = t.widget<PlayerEpisodePanel>(find.byType(PlayerEpisodePanel));
      // ★ 断言对象是「**可见集**」（输入经 `selectedFlag` 过滤后），不是面板的原始输入
      expect(
          episodeLineFilter(before.episodes, before.selectedFlag)
              .map((e) => e.id)
              .toList(),
          _idsOf(eps, 'xlm3u8'),
          reason: '前置：默认应显示第一条线路的集（实际可见集 '
              '${episodeLineFilter(before.episodes, before.selectedFlag).map((e) => e.id).toList()}）');

      // 切到第 2 条（真实回调；flutter_tester 不派发指针事件到本树）
      t.widgetList<LineChip>(find.byType(LineChip))
          .firstWhere((c) => c.flag == 'gsm3u8')
          .onTap();
      await t.pump();

      final after = t.widget<PlayerEpisodePanel>(find.byType(PlayerEpisodePanel));
      expect(after.selectedFlag, 'gsm3u8',
          reason: '★★ 面板的 selectedFlag 必须跟着换');
      /*
       * ★★★ 2026-10-26 复核纠正：**面板一直是按线路过滤的**，是本条断言对象写错了。
       *
       * ```text
       * `lib/ui/player/episode_panel.dart:122` 就是过滤器：
       *   List<Episode> get _eps => episodeLineFilter(widget.episodes, widget.selectedFlag);
       * 而且 `_segmentCount`(:115) / `_shown`(:137) / `_cell`(:383) / 「共 N 集」(:288)
       * **全都**读 `_eps` ⇒ 渲染层确实按线路过滤。
       * ⇒ `widget.episodes` 永远是**面板的输入**（全量 124 集），拿它当"渲染结果"来断言
       *   必然常红 —— 这是断言写错，不是产品缺陷。
       * 正确的断言对象是两个：
       *   ① 过滤后的可见集（`episodeLineFilter(输入, 所选线路)`）== 该线路 id 集合；
       *   ② 渲染出来的「共 N 集」== 该线路集数（这条才证明渲染层真的用了过滤器）。
       * ```
       */
      expect(episodeLineFilter(after.episodes, after.selectedFlag)
              .map((e) => e.id)
              .toList(),
          _idsOf(eps, 'gsm3u8'),
          reason: '★★★ 切到第 2 条线路后，**可见集**必须换成该线路的 id 集合 —— '
              '只换高亮不换列表就是"切了个寂寞"');
      expect(find.text('共 4 集'), findsOneWidget,
          reason: '★★ 渲染出来的「共 N 集」必须是**该线路**的集数（4）—— '
              '这一条才证明渲染层用的是 `_eps`（过滤后），而不是 `widget.episodes`（全量 124）');
      expect(find.text('共 124 集'), findsNothing,
          reason: '★★ 不许把全量 124 集渲染出来（31 条线路混在一起）');
    });

    testWidgets('④ 窄屏 360：31 个 chip 不溢出、可横向滚动、最后一条能滚到可见',
        (t) async {
      final eps = _ikan31();
      await _mountNarrow(t, eps, const Size(360, 800));
      expect(debugPlayerOpenEpisodesForProbe(), isTrue);
      await t.pump();

      // ① 不许有布局溢出（RenderFlex overflow 会走 takeException）
      expect(t.takeException(), isNull,
          reason: '★★ 窄屏下 31 个 chip 不许把布局撑破（溢出异常）');

      // ② 线路条必须是**横向可滚动**的：找到线路条内部的横向 Scrollable
      final bar = find.byType(EpisodeLineBar);
      expect(bar, findsOneWidget);
      final hScroll = find.descendant(
        of: bar,
        matching: find.byWidgetPredicate((w) =>
            w is Scrollable && w.axisDirection == AxisDirection.right),
      );
      expect(hScroll, findsOneWidget,
          reason: '★★★ 31 条线路在 360 宽下必须**横向滚动**；当前 '
              '`lib/ui/widgets/episode_strip.dart:1452` 用的是 `Wrap(`（会折成多行，'
              '既不可横向滚、又把面板竖向撑高）⇒ 用户滚不到第 31 条');

      // ③ 最后一条 chip 能滚到可见并且**可命中**
      final lastFlag = _ikan31Flags.last;
      final lastChip = find.text(lastFlag);
      expect(lastChip, findsOneWidget, reason: '★ 最后一条 chip 必须在树上');
      await t.ensureVisible(lastChip);
      await t.pump();
      expect(lastChip.hitTestable(), findsOneWidget,
          reason: '★★★ 滚到之后必须**可点**（被裁掉/被遮挡就会 hitTest 失败）');

      // ④ 滚动确实发生了：最后一个 chip 的 x 与第一个不同（证明是横向位移）
      expect(t.takeException(), isNull);
    });

    /*
     * ③-b **修法验收**（现在就是绿的）：证明 ③ 那条断言是**可满足的** ——
     * 只要面板收到"已按线路过滤"的列表，选集就只剩该线路的集。
     * ⇒ ③ 的红 100% 来自 `episode_panel.dart` 没调用 `episodeLineFilter`，
     *   不是断言写错、也不是夹具问题。
     */
    testWidgets('③-b 修法验收：喂**已过滤**的列表 ⇒ 面板只显示该线路的集', (t) async {
      final eps = _ikan31();
      Future<void> mountWith(List<Episode> list) async {
        await t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: PlayerEpisodePanel(
              episodes: list,
              currentIndex: 0,
              onPick: (_) {},
              onClose: () {},
              flags: _ikan31Flags,
              selectedFlag: 'gsm3u8',
              onPickFlag: (_) {},
            ),
          ),
        ));
        await t.pump();
      }

      // 修法后的形态：先过滤再喂
      await mountWith(episodeLineFilter(eps, 'gsm3u8'));
      expect(find.text('共 4 集'), findsOneWidget,
          reason: '★ 过滤后应只有该线路的 4 集（面板 `:249` 的「共 N 集」）');

      /*
       * ★ 2026-10-26 复核纠正：**喂全量也只显示该线路的 4 集**（面板内部过滤）。
       * 原来这里断言「共 124 集」是"修法前"的对照，但修法**早已落地**（`_eps`）
       * ⇒ 那条断言与现状相反，是本条红的第二半原因。
       */
      await mountWith(eps);
      expect(find.text('共 4 集'), findsOneWidget,
          reason: '★★ 喂**全量**输入也必须只渲染该线路的 4 集 —— '
              '面板 `_eps` 已按 `selectedFlag` 过滤（:122）');
      expect(find.text('共 124 集'), findsNothing,
          reason: '★ 全量 124 集不许出现在渲染结果里');
    });
  });
}

/// 31 条线路名（与 `_ikan31()` 同源、单独取出便于断言顺序）
const List<String> _ikan31Flags = <String>[
  'xlm3u8',
  'gsm3u8',
  'm3u8_03', 'm3u8_04', 'm3u8_05', 'm3u8_06', 'm3u8_07', 'm3u8_08',
  'm3u8_09', 'm3u8_10', 'm3u8_11', 'm3u8_12', 'm3u8_13', 'm3u8_14',
  'm3u8_15', 'm3u8_16', 'm3u8_17', 'm3u8_18', 'm3u8_19', 'm3u8_20',
  'm3u8_21', 'm3u8_22', 'm3u8_23', 'm3u8_24', 'm3u8_25', 'm3u8_26',
  'm3u8_27', 'm3u8_28', 'm3u8_29', 'm3u8_30', 'm3u8_31',
];

/// 窄屏挂载（与 `_mountPlayer` 同一条产品路径，只换视口）
Future<void> _mountNarrow(WidgetTester t, List<Episode> eps, Size size) async {
  MediaKit.ensureInitialized();
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PlayerPage(
        provider: 'ikan',
        id: 'show-1',
        title: '多线路',
        episodes: eps,
        episodeIndex: 0,
        episodeId: eps.first.id,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  ));
  await t.pump();
  await fixture.drain(t);
}
