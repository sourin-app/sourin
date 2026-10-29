// ═══════════════════════════════════════════════════════════════════════
//  现场反馈批次 2026-10-30：1.4 线路切换集数对齐（集号归一化）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 现象（真机复现记录等 driver-ops 驱动器就绪后补 —— Owner 纪律"不要猜"）
// ```text
// 切换线路后集数错位：/api/state 的集数疑似跳回第 1 集。
// ```
//
// # 本文件先钉住的是**面板切线路**这条真路径（`_pickEpisodeFlag`，
//   选集抽屉的线路条 → 生产方法）：
// ```text
// 各线路标题形态不同（「第2集」 vs 「第02集」、「01」 vs 「第 1 集」）时，
// 改前的"标题全等"匹配不到 ⇒ 停在旧线路的集上（错位）。
// 判据改 episodeNumberOf 集号归一化（episode_filter.dart 公共函数，
// 与 1.1 详情栏/抽屉同一文件）；匹配不到停在当前集号（绝不跳 1）。
// ```
// 遥控 switch_source（_remoteSwitchSource / _applySwitch）的真机复现与
// 行为改动**等驱动器就绪后**做（本文件不预改那两条 —— 不猜）。
//
// # 故障注入（实测见笔记）
// ```text
// 注入①：_pickEpisodeFlag 的归一化匹配退回「标题全等」⇒ 组②红。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';

List<String> _libmpvCandidates() => Platform.isWindows
    ? <String>[
        r'build\windows\x64\libmpv\libmpv-2.dll',
        r'build\windows\x64\runner\Release\libmpv-2.dll',
      ]
    : <String>['/usr/lib/x86_64-linux-gnu/libmpv.so.2'];

String? _libmpv;

void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      return;
    }
  }
}

bool _requireLibmpv() => _libmpv != null;

/// 三条线路、标题形态**不同**（真机形态：同一集各线路叫法不一样）
/// ```text
/// 线路A：第1集 / 第2集 / 第3集      （无零填充）
/// 线路B：第01集 / 第02集 / 第03集   （零填充）
/// 线路C：特别篇                     （提不出数字）
/// ```
List<Episode> _episodes() => [
      for (var i = 1; i <= 3; i++)
        Episode(id: 'a$i', title: '第$i集', flag: '线路A'),
      for (var i = 1; i <= 3; i++)
        Episode(id: 'b$i', title: '第${i.toString().padLeft(2, '0')}集',
            flag: '线路B'),
      const Episode(id: 'c1', title: '特别篇', flag: '线路C'),
    ];

Future<void> _mount(WidgetTester t, {required int episodeIndex}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final eps = _episodes();
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv-1',
        title: '集号对齐测试',
        episodes: eps,
        episodeIndex: episodeIndex,
        episodeId: eps[episodeIndex].id,
        episodeTitle: eps[episodeIndex].title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  debugPlayerClearErrorForProbe();
  await t.pump();
}

void main() {
  setUpAll(_prepareLibmpvFixture);

  testWidgets('① 线路A第2集 → 切线路B ⇒ 对齐到「第02集」（index 4）', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t, episodeIndex: 1); // 线路A 的 第2集
    expect(debugPlayerEpisodeIndexForProbe(), 1, reason: '前提：确实在第 2 集');

    expect(debugPlayerPickEpisodeFlagForProbe('线路B'), isTrue);
    expect(debugPlayerEpisodeIndexForProbe(), 4,
        reason: '★ 归一化匹配：第2集(2) == 第02集(2) ⇒ 落到线路B 的第02集（index 4）。'
            '改前标题全等匹配不到 ⇒ 停在 1（错位在旧线路上）');
  });

  testWidgets('② 线路B第02集 → 切线路A ⇒ 对齐到「第2集」（反向形态也归一）', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t, episodeIndex: 4); // 线路B 的 第02集
    // ★ 夹具状态对齐：initState 的 _syncSelectedFlag 默认停在第一条线路，
    //   先真切到线路B（幂等：集号对齐回 b2 自身），再切回线路A ——
    //   这与真机"用户先切过去再切回来"的状态序列一致。
    expect(debugPlayerPickEpisodeFlagForProbe('线路B'), isTrue);
    expect(debugPlayerEpisodeIndexForProbe(), 4, reason: '前提：确实在线路B 第02集');
    expect(debugPlayerPickEpisodeFlagForProbe('线路A'), isTrue);
    expect(debugPlayerEpisodeIndexForProbe(), 1,
        reason: '反向（零填充 → 无填充）同样要归一：第02集(2) == 第2集(2) ⇒ index 1');
  });

  testWidgets('③ 线路里没有同集号（特别篇）⇒ 停在当前集号，绝不跳 1', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t, episodeIndex: 4); // 线路B 的 第02集
    expect(debugPlayerPickEpisodeFlagForProbe('线路C'), isTrue);
    expect(debugPlayerEpisodeIndexForProbe(), 4,
        reason: '★ 线路C 只有「特别篇」（提不出 2）⇒ 匹配不到必须停在当前集号（index 4）。'
            '若这里变成 0（跳第 1 集）⇒ 正是 Owner 报的集数错位形态');
  });
}
