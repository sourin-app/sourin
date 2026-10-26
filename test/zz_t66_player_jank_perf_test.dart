// ══════════════════════════════════════════════════════════════════════
//  控制条「隐藏后 hover 叫回」的**帧耗时护栏**（独占机器跑）
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么不许进全量（2026-10-27 拆分，lead 批准）
// ```text
// 这条判据量的是**帧耗时**（p50 < 16.7ms、p95 ≤ 33.4ms）。同一份代码：
//   · 单跑（干净机器）：p50 = 5358us、max = 7895us
//   · 全量（4700+ 用例把机器占满）：p50 = 16146us、max = 42566us   ⇒ 3.0× / 5.4×
// 而**行为计数逐轮完全一致**（page=0、topBar/轮=68、other/轮=2/1 交替）
//   ⇒ 抖动只在帧耗时通道，**判据在满载下没有可解释性**。
// 把护栏留在满载全量里，长期只会训练人"看到这条当噪声"，等于让它失效。
// ```
//
// # 行为判据在哪（**不要在找回归时看这个文件**）
// ```text
// 8 条行为断言（`pages == 0`、`topBars ∈ [40,80]`、`others ≤ 5`、每轮收起前置 /
// 叫回副作用）**留在** `test/zz_t66_player_jank_test.dart`，它**不带 tag**，
// 全量必跑。本文件只承载"帧耗时"这两条护栏。
// ★ 元门禁在那边反向钉着：本文件里出现 `pages/topBars/others/pageBuild` ⇒ 红。
// ```
//
// # 跑法（独占机器；`dart_test.yaml` 里 `perf-timing` 带 skip，必须 --run-skipped）
// ```powershell
// flutter test test/zz_t66_player_jank_perf_test.dart --run-skipped --tags perf-timing --concurrency=1
// ```
@Tags(<String>['perf-timing'])
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';

/// 60fps 预算
const int kBudgetUs = 16700;

/// 允许**一次**尖峰（2× 预算）
const int kSpikeUs = kBudgetUs * 2;

const int kRounds = 8;

List<Episode> _eps(int n) => [
      for (var i = 0; i < n; i++)
        Episode(
          id: 'cctv1-e${i + 1}',
          title: '第${i + 1}集',
          index: i,
          flag: '默认',
        ),
    ];

Future<void> _mount(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final episodes = _eps(3);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '卡顿测试',
        episodes: episodes,
        episodeIndex: 0,
        episodeId: episodes.first.id,
        episodeTitle: episodes.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

Future<void> _enterFullscreenPlaying(WidgetTester t) async {
  debugPlayerSetPlayingForProbe(true);
  debugPlayerSetFullscreenForProbe(true);
  debugPlayerSetPointerInsideForProbe(true);
  await t.pump();
}

Future<int> _timedPump(
  WidgetTester t, [
  Duration step = const Duration(milliseconds: 16),
]) async {
  final sw = Stopwatch()..start();
  await t.pump(step);
  sw.stop();
  return sw.elapsedMicroseconds;
}

void main() {
  testWidgets('T1-perf 隐藏后 1 次 hover 叫回：p50 在预算内、p95 允许一次尖峰', (t) async {
    MediaKit.ensureInitialized();
    await _mount(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await _enterFullscreenPlaying(t);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();
    await t.pump(const Duration(milliseconds: 320));

    final times = <int>[];
    for (var cyc = 0; cyc < kRounds; cyc++) {
      debugPlayerAutoHideControlsForProbe();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(debugPlayerControlsVisibleForProbe(), isFalse,
          reason: '第 $cyc 轮前置：控制条必须真的收起');
      await t.sendEventToBinding(p.hover(Offset(210.0 + cyc, 400)));
      times.add(await _timedPump(t));
      expect(debugPlayerControlsVisibleForProbe(), isTrue,
          reason: '第 $cyc 轮副作用：控制条必须真的回来（不许靠"不显示"换性能）');
    }

    final sorted = [...times]..sort();
    final p50 = sorted[3]; // 8 个读数的下中位
    final p95 = sorted[7]; // 最慢一帧
    // ignore: avoid_print
    print('T1-perf ⇒ 帧耗时 p50=${p50}us max=${p95}us '
        '（预算 ${kBudgetUs}us，尖峰上限 ${kSpikeUs}us）单跑干净机器基准 p50≈5358 max≈7895');

    expect(p50, lessThan(kBudgetUs),
        reason: '★★ 中位帧必须落在 60fps 预算（16.7ms）内 —— 阈值未放宽。\n'
            '⚠️ **满载机器上本判据无可解释性**（实测全量 p50=16146us），'
            '请独占机器跑：`flutter test test/zz_t66_player_jank_perf_test.dart '
            '--run-skipped --tags perf-timing --concurrency=1`');
    expect(p95, lessThan(kSpikeUs),
        reason: '★ 最慢一帧允许一次尖峰（≤2× 预算）：同机抖动实测 7913~14922us，'
            '单帧硬断言会偶发假红；**分布判据**才是可解释的形态。\n'
            '⚠️ **满载机器上本判据无可解释性**（实测全量 max=42566us），'
            '请独占机器跑：`flutter test test/zz_t66_player_jank_perf_test.dart '
            '--run-skipped --tags perf-timing --concurrency=1`');
  });
}
