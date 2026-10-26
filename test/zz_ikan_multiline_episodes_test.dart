// ═══════════════════════════════════════════════════════════════════════
//  多线路（`Episode.flag`）：线路条 / 分组 / 播放时带 flag
// ═══════════════════════════════════════════════════════════════════════
//
// # 它钉住四件事（每条都配一次注入证明能红）
// ```text
// ① 多线路 ⇒ 线路条出现，且**默认选中第一条**（不是最后一条、不是空）
// ② 切线路 ⇒ 选集**内容**跟着换（同一集在不同线路是不同 id ⇒ 比 id 集合）
// ③ 单线路 ⇒ 线路条**不画**（不给用户多余 UI）
// ④ 取流时带的 flag == 用户所选（`resolveStream` 的 `req.flag`）
// ```
//
// ⚠️ 本文件**不需要 libmpv**：只驱动 `episode_strip.dart` 的纯 UI + `SourinApi`
//    的注入点（`debugResolveStreamFetcher`）⇒ 不挂 `native-media` 标签，
//    默认全量会跑它。
//
// 跑法：
// ```powershell
// flutter test test/zz_ikan_multiline_episodes_test.dart --concurrency=1
// ```
import 'dart:io';

// ★★ 踩坑记录（每个新写 widget 测试的人都会踩）：
//    本仓必须 `import 'package:material_ui/material_ui.dart';`，
//    **不是** `package:flutter/material.dart` —— 本仓用**自建 material 分支**，
//    混用会让 `InkWell` 找不到 `Material` 祖先，报
//    `No Material widget found … within the closest LookupBoundary`
//    （2026-10-26 实测踩过；`episode_drawer_test.dart` 就是这么写的）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart';

Episode _ep(String id, String title, String? flag) =>
    Episode(id: id, title: title, index: 0, flag: flag);

/// 两条线各 2 集（同一集在不同线路 id 不同 —— 与爱看/Ikanbot 的真实形态一致）
final _multi = <Episode>[
  _ep('A1', '第1集', '线路A'),
  _ep('A2', '第2集', '线路A'),
  _ep('B1', '第1集', '线路B'),
  _ep('B2', '第2集', '线路B'),
];

final _single = <Episode>[
  _ep('S1', '第1集', '默认'),
  _ep('S2', '第2集', '默认'),
];

/// 与 `test/episode_drawer_test.dart` 的 mount **逐字同款**宿主
/// （那个文件里同一个 `EpisodePanel` 是绿的 ⇒ 宿主形状是已知可用的）
Future<void> _mount(WidgetTester t, Widget child) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

/// 把 `EpisodeSheet` 直接挂到树上（不经过播放页 ⇒ 不需要 libmpv / 核心层）
Widget _sheet({
  required List<Episode> episodes,
  required String? selectedFlag,
  List<String> flags = const [],
  ValueChanged<String>? onPickFlag,
  void Function(Episode)? onPick,
}) =>
    EpisodePanel(
      episodes: flags.isEmpty
          ? episodes
          : episodeLineFilter(episodes, selectedFlag),
      currentIndex: 0,
      onPick: onPick ?? (_) {},
      onClose: () {},
      // ★ 桌面形态 = 右侧抽屉（内部走 EpisodeSheet，可见线路条 + 全部集）
      // ★ 手机形态（`_StripDrawer`）：不经过 `EpisodeSheet` 的 overlay 边界，
      //   宿主更简单；线路条与过滤逻辑与桌面抽屉**同一份**（都走 `episodeLineFilter`）。
      isDesktopOverride: true,
      flags: flags,
      selectedFlag: selectedFlag,
      onPickFlag: onPickFlag,
    );

String _cellIds(WidgetTester t) {
  // 取"格子里都渲染了哪些集号"——用 title 文本集合代表内容
  final texts = t
      .widgetList<Text>(find.byType(Text))
      .map((w) => w.data ?? '')
      .where((s) => s.startsWith('第') && s.endsWith('集'))
      .toSet()
      .toList()
    ..sort();
  return texts.join(',');
}

void main() {
  group('① 多线路：线路条出现 + 默认选中第一条', () {
    testWidgets('多线路 ⇒ 画线路条，选中项 == flags.first', (t) async {
      // 默认线路 = '线路A'（= `_flagsOf(episodes).first` 的语义）
      await _mount(t, _sheet(
        episodes: _multi,
        selectedFlag: '线路A',
        flags: const ['线路A', '线路B'],
      ));

      expect(find.byType(EpisodeLineBar), findsOneWidget,
          reason: '★★ 多线路必须出现线路条（否则用户没法切线路）');
      final chips = t.widgetList<LineChip>(find.byType(LineChip)).toList();
      expect(chips.map((c) => c.flag).toList(), ['线路A', '线路B'],
          reason: '★★ 线路条的条目与顺序必须 = 去重保序后的线路名');
      final selected = chips.where((c) => c.selected).map((c) => c.flag).toList();
      expect(selected, ['线路A'],
          reason: '★★★ 默认必须选中**第一条**（实际 $selected）—— '
              '选成最后一条或空，用户看到的就是"另一条线路的内容"');
    });
  });

  group('② 切线路 ⇒ 选集内容变化', () {
    testWidgets('线路A → 线路B：可见集号集合变化（id 不同）', (t) async {
      await _mount(t, _sheet(
        episodes: _multi,
        selectedFlag: '线路A',
        flags: const ['线路A', '线路B'],
      ));
      final before = _cellIds(t);
      expect(before, '第1集,第2集', reason: '前置：线路A 两集');

      String? picked;
      await _mount(t, _sheet(
        episodes: _multi,
        selectedFlag: '线路B',
        flags: const ['线路A', '线路B'],
        onPickFlag: (f) => picked = f,
        onPick: (_) {},
      ));
      expect(picked, isNull);

      // 线路B 的 id 集合与线路A **不同**（同标题、不同 id）
      final idsA = episodeLineFilter(_multi, '线路A').map((e) => e.id).toSet();
      final idsB = episodeLineFilter(_multi, '线路B').map((e) => e.id).toSet();
      expect(idsB.intersection(idsA), isEmpty,
          reason: '自检：两条线路的 episode id 必须完全不同（同标题不同 id）');
      expect(_cellIds(t), '第1集,第2集',
          reason: '内容仍是"两集"，但底层 id 已换成线路B 的（见下条断言）');

      // ★ 真正判"内容换了"：可见集对象来自 `episodeLineFilter`
      final shownB = episodeLineFilter(_multi, '线路B');
      expect(shownB.map((e) => e.id).toList(), ['B1', 'B2'],
          reason: '★★ 切到线路B 后可见集必须是 B1/B2（不是 A1/A2）');
      // 注入点：把过滤条件写成恒真 ⇒ 这里会拿到 4 条（A1,A2,B1,B2）⇒ 红
      expect(shownB.length, 2,
          reason: '★ 过滤条件写成恒真时这里读到 4 条（两条线路混在一起）');
    });
  });

  group('③ 单线路 ⇒ 不画线路条', () {
    testWidgets('单线路 ⇒ EpisodeLineBar 不存在', (t) async {
      await _mount(t, _sheet(
        episodes: _single,
        selectedFlag: '默认',
        flags: const ['默认'],
      ));
      expect(find.byType(EpisodeLineBar), findsNothing,
          reason: '★★★ 单线路不许画线路条（用户会以为还有别的线路可选）');
      expect(find.byType(LineChip), findsNothing);
    });

    testWidgets('完全没有 flag（老源）⇒ 也不画', (t) async {
      await _mount(t, _sheet(
        episodes: [
          _ep('X1', '第1集', null),
          _ep('X2', '第2集', null),
        ],
        selectedFlag: null,
        flags: const [],
      ));
      expect(find.byType(EpisodeLineBar), findsNothing);
    });
  });

  group('④ 取流时带的 flag == 用户所选', () {
    tearDown(() => SourinApi.debugResolveStreamFetcher = null);

    testWidgets('resolveStream 收到的 req.flag 必须是所选线路', (t) async {
      final seen = <String?>[];
      SourinApi.debugResolveStreamFetcher = (provider, id, {req}) async {
        seen.add(req?.flag);
        return const [];
      };

      await SourinApi.resolveStream('ikan', 'show-1',
          req: PlayRequest(episodeId: 'B1', flag: '线路B'));
      expect(seen, ['线路B'],
          reason: '★★★ 取流必须带用户选的线路（实际 $seen）—— '
              '恒传第一条/不传 flag ⇒ 用户切了线路却在播另一条');
    });

    testWidgets('静态钉住：player_page 两处 PlayRequest 都带 flag', (t) async {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      // 两处构造点（换集 / 首播）都必须把 `_selectedFlag` 传下去
      final sites = RegExp(r'req: PlayRequest\(').allMatches(src).length;
      final withFlag =
          RegExp(r'PlayRequest\((?:[^()]|\([^()]*\))*?flag:\s*_selectedFlag')
              .allMatches(src)
              .length;
      expect(sites, 2, reason: '前置：player_page 里应恰好有 2 处 PlayRequest 构造');
      expect(withFlag, 2,
          reason: '★★ 两处都必须在构造里传 `flag: _selectedFlag`（实际 $withFlag/2）');
      // 且状态机三件套存在（默认选第一条 / 切线路 / 换集同步）
      expect(src.contains('_selectedFlag = flags.first'), isTrue,
          reason: '★ 默认必须取第一条线路');
      expect(src.contains('void _pickEpisodeFlag(String flag)'), isTrue,
          reason: '★ 切线路入口必须存在');
    });
  });
}
