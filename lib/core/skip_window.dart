// ═══════════════════════════════════════════════════════════════════════
//  skip_window.dart —— "该不该跳、跳到哪"的**纯函数**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件（而不是写在 player_page 里）
// ```text
// ① 现有判定（`_maybeSkip`）埋在 lib/ui/player_page.dart（1.1MB）里，
//    想加"中插广告"就得动那个文件 —— 而 player-fix 正在改它，冲突面太大；
// ② 判定是纯逻辑（位置 + 窗口 + 最近拖动时间 ⇒ 目标位置），**可以脱离播放器测试**；
// ③ 把它抽出来以后，UI 侧只改**一行**：`_maybeSkip(p)` 里调 `skipTarget(...)`。
// ```
//
// # 三种窗口（`kind`）
// ```text
// intro    片头 [0, introEnd)        —— Owner 要的"片头固定时长"就是这条
// outro    片尾 [outroStart, 末尾)
// midroll  中插 [a, b)               —— 数据驱动（SkipMarker.midrolls），不做自动识别
// ```
//
// # 两条保守原则（宁可少跳，不可乱跳）
// ```text
// ① **用户刚拖过就不跳**（grace 窗口默认 2s）：
//    否则"拖到 0 秒"会被片头规则立刻顶回 introEnd —— 本仓真实事故（见 player_page 的注释）；
// ② **已经跳过的窗口不再跳**（tolerance 容差默认 1s）：
//    位置流每秒 tick 一次，若不记"已跳过"，会在边界反复 seek。
// ```

/// 一条可跳区间（**半开区间** `[start, end)`）
class SkipWindow {
  const SkipWindow({
    required this.start,
    required this.end,
    this.kind = 'intro',
  });

  final Duration start;
  final Duration end;

  /// `intro` / `outro` / `midroll`
  final String kind;

  /// 位置是否落在窗口内（半开：`start <= p < end`）
  bool contains(Duration p) => p >= start && p < end;

  @override
  String toString() => 'SkipWindow($kind: ${start.inSeconds}..${end.inSeconds})';
}

/// 判定结果：`null` = 不跳；有值 = 应该 seek 到这个位置
///
/// 返回 `Duration.zero` 是有意义的（"跳回 0"），所以**不要**用"非零"判断是否有结果。
Duration? skipTarget({
  required Duration position,
  required List<SkipWindow> windows,
  DateTime? lastUserSeekAt,
  DateTime? now,
  Duration grace = const Duration(seconds: 2),
  Duration tolerance = const Duration(seconds: 1),
}) {
  if (windows.isEmpty) return null;

  // ① 用户刚拖过 ⇒ 让位（"继续观看"是主动意图，不能被片头规则顶掉）
  final t = now ?? DateTime.now();
  if (lastUserSeekAt != null) {
    final sinceSeek = t.difference(lastUserSeekAt);
    if (sinceSeek >= Duration.zero && sinceSeek < grace) return null;
  }

  for (final w in windows) {
    if (!w.contains(position)) continue;

    // ② 距窗口末尾不足 `tolerance` ⇒ 不跳，让那一小段**自然播过去**
    //
    //    语义精确化（我第一版把它当"防抖"，结果 68s 距末尾 1s 时被判成"不跳"，
    //    与"区间内必须跳"冲突）：这里就是"快到头了就别 seek 了" ——
    //    ①防边界抖动 ②省一次 seek；代价是末尾 tolerance 那点内容会正常播。
    //    想改成"必须跳"，把调用方 `tolerance` 传 `Duration.zero` 即可。
    final toEnd = w.end - position;
    if (toEnd <= tolerance) return null;

    return w.end;
  }
  return null;
}

/// 把 `SkipMarker` 的四个旧字段 + `midrolls` 展开成窗口列表（顺序：片头 → 中插 → 片尾）
///
/// 抽在这里而不是 UI 里：这样"字段 → 窗口"的映射也能被单测覆盖。
///
/// # ⚠️ `midrolls` 的元素形状必须与 `SkipMarker.midrolls` **逐字一致**
/// ```text
/// SkipMarker.midrolls  : List<({int startSec, int endSec})>
/// windowsOf(midrolls:) : List<({int startSec, int endSec})>
/// ```
/// 名字对不上时 Dart 不会报错，只会**静默传空** ⇒ 中插永远不跳，
/// 而且 UI 上看不出异常（今天已经踩过一次，见 models.dart 同名字段的注释）。
/// 接线时请用 `windowsOf(midrolls: marker.midrolls, …)`，不要手工再 map 一遍。
List<SkipWindow> windowsOf({
  int? introStart,
  int? introEnd,
  int? outroStart,
  int? outroEnd,
  List<({int startSec, int endSec})> midrolls = const [],
}) {
  final out = <SkipWindow>[];
  if (introEnd != null) {
    final s = introStart ?? 0;
    if (introEnd > s) {
      out.add(SkipWindow(
        start: Duration(seconds: s),
        end: Duration(seconds: introEnd),
        kind: 'intro',
      ));
    }
  }
  for (final m in midrolls) {
    if (m.endSec > m.startSec) {
      out.add(SkipWindow(
        start: Duration(seconds: m.startSec),
        end: Duration(seconds: m.endSec),
        kind: 'midroll',
      ));
    }
  }
  if (outroStart != null) {
    final e = outroEnd;
    if (e != null && e > outroStart) {
      out.add(SkipWindow(
        start: Duration(seconds: outroStart),
        end: Duration(seconds: e),
        kind: 'outro',
      ));
    }
  }
  return out;
}
