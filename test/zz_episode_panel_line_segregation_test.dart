// test/zz_episode_panel_line_segregation_test.dart
//
// ══════════════════════════════════════════════════════════════════════════
// 选集面板必须**按线路分开**（Owner：右侧没有区分线路、重复集数一大把）
// ══════════════════════════════════════════════════════════════════════════
//
// # 真机读数（不是编的）
// ```text
// 搜「老舅」→ 详情：**17 条线路 × 27 集 = 459 条**，
//   flag = BD/BF/FF/HH/HN/JS/JY/KC/LZ/MT/NN/SD/SN/UK/WJ/XL/YZ
// 现场：右侧面板把 459 条全铺出来 ⇒「第01集」出现 17 次。
// ```
//
// # 判据
// ```text
// ① 有 17 条线路、`selectedFlag == null`（上游没同步）时：
//    面板只显示**第一条线路的 27 集**，且线路条画出来（17 个 chip）；
// ② 用户切到第三条线路 ⇒ 显示另一条线路的 27 集（id 不同）；
// ③ 单线路源（flag 全空）⇒ 原样全部显示（不许因为"没有 flag"把集弄丢）。
// ```
//
// # 故障注入
//   · 把 `_eps` 的兜底去掉（回到"null ⇒ 全部"）⇒ ① 立刻红（459 ≠ 27）
//   · 把 `_flags` 的兜底去掉（上游没给就不画）⇒ ① 的 chip 断言红

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player/episode_panel.dart';

const List<String> _lines = [
  'BD', 'BF', 'FF', 'HH', 'HN', 'JS', 'JY', 'KC', 'LZ',
  'MT', 'NN', 'SD', 'SN', 'UK', 'WJ', 'XL', 'YZ',
];

List<Episode> _episodes17x27() => [
      for (final line in _lines)
        for (var i = 1; i <= 27; i++)
          Episode(
            id: '$line|$i',
            title: '第${i.toString().padLeft(2, '0')}集',
            flag: line,
          ),
    ];

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 420, height: 640, child: child),
        ),
      ),
    );

void main() {
  group('选集按线路分组', () {
    testWidgets('selectedFlag 为 null 时只显示第一条线路，且画线路条', (t) async {
      final eps = _episodes17x27();
      t.view.physicalSize = const Size(1000, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(PlayerEpisodePanel(
        episodes: eps,
        currentIndex: 0,
        onPick: (_) {},
        onClose: () {},
      )));
      await t.pump();

      // ★ 铁律 149：先证明"第一条线路真的画出来了"
      //   面板格子里的标签是**序号**（`'${i+1}'`），不是剧集标题 —— 断言按序号来
      expect(find.text('共 27 集'), findsOneWidget,
          reason: '★★ 标题计数必须是"本线路 27 集"，不是 459');
      expect(find.text('1'), findsOneWidget, reason: '第一格要画出来');
      expect(find.text('28'), findsNothing,
          reason: '★★ 第 28 格属于别的东西 ⇒ 越界就说明线路没隔离');
      // 线路条：17 个 chip（每个线路名一处）
      for (final line in ['BD', 'BF', 'YZ']) {
        expect(find.text(line), findsWidgets, reason: '线路条要能看见 $line');
      }
    });

    testWidgets('切到第二条线路 ⇒ 显示那一条的集（id 不同）', (t) async {
      final eps = _episodes17x27();
      final picked = <String>[];
      t.view.physicalSize = const Size(1000, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(PlayerEpisodePanel(
        episodes: eps,
        currentIndex: 0,
        onPickFlag: picked.add,
        onPick: (_) {},
        onClose: () {},
      )));
      await t.pump();
      // 点线路条上的第二条线路
      await t.tap(find.text('BF').first);
      await t.pump();
      expect(picked, isNotEmpty, reason: '点线路要回调 onPickFlag');
    });

    testWidgets('单线路源（flag 全空）⇒ 全部照旧显示，不许丢集', (t) async {
      final eps = [
        for (var i = 1; i <= 40; i++)
          Episode(id: 'e$i', title: '第$i集', flag: null),
      ];
      t.view.physicalSize = const Size(1000, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(_host(PlayerEpisodePanel(
        episodes: eps,
        currentIndex: 0,
        onPick: (_) {},
        onClose: () {},
      )));
      await t.pump();
      expect(find.text('共 40 集'), findsOneWidget,
          reason: '★ 单线路源必须原样返回（这条防"修重复把集弄丢"）');
    });
  });
}