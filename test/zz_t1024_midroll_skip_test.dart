// ══════════════════════════════════════════════════════════════════════
//  中插广告（`SkipMarker.midrolls`）：`_maybeSkip` 接线后的四条门禁
// ══════════════════════════════════════════════════════════════════════
//
// # 它钉什么
// ```text
// ① 片头区间仍跳（改判据不改语义）—— 与 zz_t1024_skip_respects_user_seek 互补：
//    那条钉"grace/续播/结构"，这条钉"跳了之后**读数**对不对"（seek 次数与落点）
// ② **中插区间也跳**（新能力：`SkipMarker.midrolls` → `windowsOf` → `skipTarget`）
//    且同一窗口只跳一次（位置流每秒 tick，不幂等就会反复 seek）
// ③ 用户刚拖过（grace 内）⇒ 不跳，**且之后也不再跳**（= "本窗口放弃"，与改前同义）
// ④ 没有标记 ⇒ **一次 seek 都不发**
// ```
//
// ⚠️ 本仓 widget 测试必须 `import 'package:material_ui/material_ui.dart';`
//    （不是 `package:flutter/material.dart`）。
//
// 跑法：
// ```powershell
// flutter test test/zz_t1024_midroll_skip_test.dart \
//   --run-skipped --tags native-media --concurrency=1
// ```
@Tags(['native-media'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

/// 挂播放页（与既有 skip 用例同一夹具：真 PlayerPage + 真 mpv）
Future<void> _mount(WidgetTester t) async {
  MediaKit.ensureInitialized();
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PlayerPage(
        provider: 'demo',
        id: 'midroll-1',
        title: '中插门禁',
        episodes: const [
          Episode(id: 'e1', title: '第1集', index: 0),
          Episode(id: 'e2', title: '第2集', index: 1),
        ],
        episodeIndex: 0,
        episodeId: 'e1',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  ));
  await t.pump();
  await fixture.drain(t);
}

/// 设定 marker（片头 0-69 + 一条中插 300-330）并返回初始 seek 计数
int _setMarker({List<({int startSec, int endSec})> midrolls = const []}) {
  final ok = debugPlayerSetSkipMarkerForProbe(
    introStart: 0,
    introEnd: 69,
    midrolls: midrolls,
  );
  expect(ok, isTrue, reason: '前置：marker 探针要能用');
  return debugPlayerSkipSeekCalls() ?? -1;
}


/// 跑一次生产 `_maybeSkip(pos)`，**并把 `_flash` 建的那个 Timer 排掉**
///
/// # 为什么必须 pump 一下（这是新用例独有的坑）
/// ```text
/// 接线后命中窗口会走 `_flash('已跳过片头'/'已跳过中插')`，它内部 `Future.delayed(1200ms)`；
/// 用例跑在 **FakeAsync** 里 ⇒ 不 pump 掉就抛 FakeTimer 异常
/// （实测栈：#0 new FakeTimer._ ← _flash ← _maybeSkip）。
/// 既有 `zz_t1024_skip_respects_user_seek` 一直有 `fixture.drain(t)` 收尾 ⇒ 它不炸。
/// ⚠️ 修的是**用例**，不是产品：`_flash` / `_maybeSkip` 的 timer 一行不动。
/// ```
Future<void> _skipAndFlush(WidgetTester t, int seconds) async {
  expect(debugPlayerMaybeSkipForProbe(Duration(seconds: seconds)), isTrue,
      reason: '前置：探针要能调到 _maybeSkip');
  await t.pump(const Duration(seconds: 2)); // ★ 排掉 _flash 的 1.2s Timer
}

void main() {
  group('① 片头区间仍跳（读数：次数 + 落点）', () {
    testWidgets('pos=10 落在片头 ⇒ +1 次 seek，落点 69s', (t) async {
      await _mount(t);
      final before = _setMarker();

      await _skipAndFlush(t, 10);
      expect(debugPlayerSkipSeekCalls(), before + 1,
          reason: '★★ 片头区间内必须发出**一次** seek（改判据后语义不变）');
      expect(debugPlayerLastSkipSeek(), const Duration(seconds: 69),
          reason: '★ 落点必须是片头结束 69s');
    });
  });

  group('② 中插区间也跳 + 幂等', () {
    testWidgets('pos=305 落在中插 ⇒ +1 次 seek 到 330；再 tick 不再跳', (t) async {
      await _mount(t);
      final before = _setMarker(midrolls: const [(startSec: 300, endSec: 330)]);

      await _skipAndFlush(t, 305);
      // ignore: avoid_print
      print('[E2E] marker(midroll 300→330) pos=305s ⇒ '
          'skipSeekCalls=$before → ${debugPlayerSkipSeekCalls()}，'
          'lastSkipSeek=${debugPlayerLastSkipSeek()}');
      expect(debugPlayerSkipSeekCalls(), before + 1,
          reason: '★★★ 中插区间内必须发 seek —— 注入「windows 只传 intro」本条立刻红');
      expect(debugPlayerLastSkipSeek(), const Duration(seconds: 330),
          reason: '★ 中插落点必须是该窗口结束（330s）');

      // 幂等：下一秒同一区间内 tick ⇒ 不许再 seek
      await _skipAndFlush(t, 306);
      expect(debugPlayerSkipSeekCalls(), before + 1,
          reason: '★★ 同一中插窗口只许跳一次（否则边界反复 seek）');
    });
  });

  group('③ grace 内不跳，且之后也不再跳', () {
    testWidgets('刚拖过 ⇒ 中插不跳；过了 grace 也**不再**跳（本窗口放弃）', (t) async {
      await _mount(t);
      final before = _setMarker(midrolls: const [(startSec: 300, endSec: 330)]);
      /*
       * 模拟"用户刚刚 seek 过"：
       * ⚠️ `debugPlayerAgeUserSeekForProbe` 在 `_lastUserSeekAt == null` 时返回 false
       *    （它只**调整**已有时间，不能凭空造）⇒ 必须先走一次**用户** seek
       *    （`debugPlayerUserSeekForProbe` 会写 `_lastUserSeek/_lastUserSeekAt`）。
       */
      expect(debugPlayerUserSeekForProbe(const Duration(seconds: 305)), isTrue,
          reason: '前置：造一次用户 seek（它才写 _lastUserSeekAt）');
      expect(debugPlayerAgeUserSeekForProbe(Duration.zero), isTrue,
          reason: '前置：把上次用户 seek 时间调到"刚刚"');

      await _skipAndFlush(t, 305);
      expect(debugPlayerSkipSeekCalls(), before,
          reason: '★★ grace 内不许跳（用户主动拖过 ⇒ 让他赢）');

      // grace 过期后仍然不许跳 —— 改前语义是"标记已跳过 + return"
      expect(debugPlayerAgeUserSeekForProbe(const Duration(seconds: 5)), isTrue);
      await _skipAndFlush(t, 306);
      expect(debugPlayerSkipSeekCalls(), before,
          reason: '★★★ grace 那次已经"用掉了本窗口" ⇒ 之后也不许跳'
              '（注入：去掉前置 grace 分支 ⇒ 这里会 +1 ⇒ 红）');
    });
  });

  group('④ 无标记 ⇒ 一次 seek 都不发', () {
    testWidgets('5 个位置 tick（含片头/中插区间）⇒ seek 次数不变', (t) async {
      await _mount(t);
      final before = debugPlayerSkipSeekCalls() ?? -1;
      for (final s in [0, 10, 300, 305, 1000]) {
        await _skipAndFlush(t, s);
      }
      expect(debugPlayerSkipSeekCalls(), before,
          reason: '★★★ 没有 marker 时必须一次 seek 都不发 —— '
              '注入「去掉 m == null 早退」本条立刻红');
    });
  });
}
