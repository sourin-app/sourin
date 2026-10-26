// skip_window.dart 的三条门禁 + 两条保守原则
//
// 为什么单独测这个文件：判定是纯函数（位置 + 窗口 + 最近拖动时间 ⇒ 目标位置），
// 不需要播放器、不需要 network、不需要 widget —— 这样"跳过逻辑"才有可复跑的判据。
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/skip_window.dart';

void main() {
  const s69 = Duration(seconds: 69);

  group('① 有标记区间 ⇒ 只跳一次', () {
    test('片头 [0,69) 内 ⇒ 跳到 69s；69s 之后不再跳', () {
      final w = [SkipWindow(start: Duration.zero, end: s69, kind: 'intro')];
      // 0s / 1s / 67s 都在区间内且距末尾 > tolerance(1s) ⇒ 都该跳到 69
      for (final p in [0, 1, 67]) {
        final t = skipTarget(position: Duration(seconds: p), windows: w);
        expect(t, s69, reason: '在片头区间内必须跳到 introEnd（p=$p）');
      }
      // 68s：距末尾只有 1s（= tolerance）⇒ **不跳**，让那一小段自然播过去
      expect(skipTarget(position: const Duration(seconds: 68), windows: w), isNull,
          reason: 'tolerance 语义：快到头了就别 seek');
      // 69s 恰好在**半开区间**之外 ⇒ 不许再跳
      expect(skipTarget(position: s69, windows: w), isNull);
      expect(skipTarget(position: const Duration(seconds: 70), windows: w), isNull);
    });

    test('区间末尾 tolerance 内 ⇒ 视为已跳过（防每秒 tick 反复 seek）', () {
      final w = [SkipWindow(start: Duration.zero, end: s69, kind: 'intro')];
      // 68.5s：距离末尾 0.5s < tolerance(1s) ⇒ 不跳
      expect(
        skipTarget(position: const Duration(milliseconds: 68500), windows: w),
        isNull,
        reason: '距末尾 <= tolerance 时不许再跳（否则边界抖动）',
      );
    });
  });

  group('② 无标记 ⇒ 一次 seek 都不发', () {
    test('空窗口列表永远返回 null', () {
      for (final p in [0, 1, 300, 99999]) {
        expect(skipTarget(position: Duration(seconds: p), windows: const []), isNull);
      }
    });

    test('windowsOf 对"只有 introStart 没有 introEnd"不产出窗口', () {
      // 旧数据里可能只有 intro_start（用户点了"记住片头开始"但没点结束）
      expect(windowsOf(introStart: 5), isEmpty);
      expect(windowsOf(), isEmpty);
      // 反向区间（end <= start）也不产出
      expect(windowsOf(introStart: 30, introEnd: 10), isEmpty);
    });
  });

  group('③ 片头 / 中插 / 片尾三种位置都对，且 grace 内不跳', () {
    final windows = [
      SkipWindow(start: Duration.zero, end: s69, kind: 'intro'),
      SkipWindow(
        start: const Duration(seconds: 600),
        end: const Duration(seconds: 660),
        kind: 'midroll',
      ),
      SkipWindow(
        start: const Duration(seconds: 1800),
        end: const Duration(seconds: 1850),
        kind: 'outro',
      ),
    ];

    test('中插 [600,660) ⇒ 跳到 660', () {
      expect(skipTarget(position: const Duration(seconds: 601), windows: windows),
          const Duration(seconds: 660));
      expect(skipTarget(position: const Duration(seconds: 599), windows: windows), isNull);
    });

    test('片尾 [1800,1850) ⇒ 跳到 1850', () {
      expect(skipTarget(position: const Duration(seconds: 1801), windows: windows),
          const Duration(seconds: 1850));
    });

    test('用户刚拖过（grace 内）⇒ 不跳；超过 grace ⇒ 恢复', () {
      final now = DateTime(2026, 10, 26, 12, 0, 0);
      // 刚拖完 1 秒（< grace 2s）
      expect(
        skipTarget(
          position: Duration.zero,
          windows: windows,
          lastUserSeekAt: now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        isNull,
        reason: '★ 用户刚拖到 0 秒时不能被片头规则顶回 69s（本仓真实事故）',
      );
      // 拖完 3 秒（> grace）⇒ 恢复自动跳过
      expect(
        skipTarget(
          position: Duration.zero,
          windows: windows,
          lastUserSeekAt: now.subtract(const Duration(seconds: 3)),
          now: now,
        ),
        s69,
      );
    });

    test('windowsOf 把 midrolls 展开成 midroll 窗口（顺序 片头→中插→片尾）', () {
      final ws = windowsOf(
        introStart: 0,
        introEnd: 69,
        midrolls: const [(startSec: 600, endSec: 660), (startSec: 900, endSec: 940)],
        outroStart: 1800,
        outroEnd: 1850,
      );
      expect(ws.map((w) => w.kind).toList(), ['intro', 'midroll', 'midroll', 'outro']);
      expect(ws[1].start, const Duration(seconds: 600));
      expect(ws[2].end, const Duration(seconds: 940));
    });
  });

  group('④ ★ 真实 SkipMarker 对象驱动（不是合成函数）', () {
    test('real_marker_with_midrolls_expands_into_windows', () {
      // 真 JSON（含 midrolls）→ SkipMarker → windowsOf ⇒ 中插必须出现在展开结果里
      final m = SkipMarker.fromJson(<String, dynamic>{
        'key': 'p:n',
        'provider': 'p',
        'native_id': 'n',
        'intro_start': 0,
        'intro_end': 69,
        'outro_start': 1800,
        'outro_end': 1850,
        'midrolls': [
          {'start': 600, 'end': 660},
          {'start': 900, 'end': 940},
        ],
      });
      expect(m.midrolls.length, 2, reason: '★ fromJson 必须解出 midrolls');
      final ws = windowsOf(
        introStart: m.introStart,
        introEnd: m.introEnd,
        outroStart: m.outroStart,
        outroEnd: m.outroEnd,
        midrolls: m.midrolls,
      );
      expect(ws.where((w) => w.kind == 'midroll').length, 2,
          reason: '★ 真实对象驱动下，中插窗口必须出现在展开结果里');
      expect(
        skipTarget(position: const Duration(seconds: 601), windows: ws),
        const Duration(seconds: 660),
        reason: '★ 端到端：真实 marker → 窗口 → 该跳 660',
      );
    });

    test('old_marker_without_midrolls_still_parses', () {
      // 旧数据：完全没有 midrolls 键
      final m = SkipMarker.fromJson(<String, dynamic>{
        'key': 'p:n',
        'provider': 'p',
        'native_id': 'n',
        'intro_end': 69,
      });
      expect(m.midrolls, isEmpty, reason: '★ 缺字段必须容忍（?? const []）');
      final ws = windowsOf(introStart: m.introStart, introEnd: m.introEnd, midrolls: m.midrolls);
      expect(ws.length, 1, reason: '只有片头一个窗口');
      expect(ws.single.kind, 'intro');
    });
  });
}
