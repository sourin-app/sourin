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
    show EpisodeLineBar, LineChip;

import 't102_playback_failure_banner_test.dart' as fixture;

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
}
