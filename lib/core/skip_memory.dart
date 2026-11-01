// ═══════════════════════════════════════════════════════════════════════
//  skip_memory.dart —— 「记忆式片头」的**纯函数**分类器（T7）
// ═══════════════════════════════════════════════════════════════════════
//
// # 对标的是什么（T2 取证第 ② 节）
// ```text
// 参考（FongMi fork）：History 表 opening/ending 两列 —— 用户对某片
// 手动设定后**每条目记忆**，下次播到区间自动 seek。我们给它接上行为推断：
// 用户在片头区主动拖走 ⇒ 记下落点，下次自动跳。
// ```
//
// # 保守原则（宁可少记，不可乱记）
// ```text
// ① 声明优先：**声明值在 Rust 库级拦截**（`upsert_skip_memory` 返回 false，
//    调用方据此不出 flash）。本函数**不收** declared 短路 ——
//    互检 P2-1 的活案例：把"生效值"（声明 ⊕ 记忆）当声明传入，会让
//    记忆一旦存在就永远无法修正（"记忆跨会话冻结"）。**记忆来源的值
//    必须允许被新 seek 覆盖**；声明的保护交给库级兜底，不在这里重演。
// ② 只认"从片头疑似区出发的前跳"：回跳/原地/微调都不是片头信号；
// ③ 落点双上限：绝对 600s + 相对片长 50%（互检 P3-1：短片防"把整片
//    记成片头"——取更紧的那个）；
// ④ 同值去重：同一落点不重复记/不重复打扰（flash）。
// ```
// 一期只有片头：片尾推理被批复砍掉（片尾误记的代价是静默吃掉结局）。
//
// # 为什么单独一个文件
// 与 `skip_window.dart` 同理：判定是纯逻辑，脱离播放器可测；
// UI 侧（player_page）只调函数，不内联判据。

/// 「记忆式片头」阈值集（调用方可覆盖，便于测试边界）
class SkipMemoryThresholds {
  const SkipMemoryThresholds({
    this.earliestFrom = const Duration(seconds: 90),
    this.minJump = const Duration(seconds: 30),
    this.maxIntro = const Duration(seconds: 600),
    this.maxIntroFraction = 0.5,
  });

  /// 出发点必须不晚于 `max(earliestFrom, 片长 × 5%)` 才算"片头疑似区"
  final Duration earliestFrom;

  /// 前跳幅度下限（低于它更像日常微调，不是"跳过片头"）
  final Duration minJump;

  /// 落点绝对上限（超过它不算片头终点）
  final Duration maxIntro;

  /// 落点相对上限（片长 × maxIntroFraction）。
  /// 短片里比绝对上限更紧的那个生效（互检 P3-1：5 分钟短片拖到 3 分钟
  /// ⇒ 记"片头 3 分钟" = 整片跳过）。
  final double maxIntroFraction;
}

/// 分类一次用户 seek 是否值得记成「片头终点」
///
/// 返回 `null` = 不记；有值 = 应记忆的片头终点（起点固定 0，参考 opening 单点语义）。
///
/// # 判据（全落地在纯函数里，行为单测见 `test/skip_memory_test.dart`）
/// ```text
/// ① 片长未知（≤0）           ⇒ 不记（比例阈值算不出）
/// ② 出发点不在片头疑似区      ⇒ 不记（从正片中段拖走不是片头信号）
/// ③ 回跳 / 原地              ⇒ 不记（用户想重看，不是想跳过）
/// ④ 前跳幅度 < minJump       ⇒ 不记（微调）
/// ⑤ 落点超过绝对/相对上限     ⇒ 不记（像"跳到想看的剧情"/整片跳过）
/// ⑥ 与已记值相同             ⇒ 不记（同值去重：不重写、不重复打扰）
/// ```
/// ⚠️ 「声明已存在 ⇒ 不落库」由 Rust `upsert_skip_memory` 库级兜底
/// （写不进去 + 调用方拿 false 不出 flash）——**不是**这里的职责（见上 ①）。
/// ⚠️ 总开关（默认关）与直播闸门在调用方（player_page）——这里只回答
/// "这次 seek 该不该记"，不回答"记忆功能开没开"。
Duration? classifyIntroMemorySeek({
  required Duration from,
  required Duration to,
  required Duration duration,
  /// 会话内已**记忆**的片头终点（null = 本会话还没记过）。
  /// ⚠️ 只收记忆、不收声明（P2-1）：记忆可被新 seek 修正。
  int? memoryIntroEnd,
  SkipMemoryThresholds t = const SkipMemoryThresholds(),
}) {
  // ① 片长未知：5% 阈值算不出，且"早/晚"无从判断
  if (duration <= Duration.zero) return null;
  // ② 片头疑似区：max(90s, 片长 5%) —— 长片放宽，短剧收紧
  final fivePercent = duration * 0.05;
  final early = t.earliestFrom > fivePercent ? t.earliestFrom : fivePercent;
  if (from > early) return null;
  // ③ 只有**前跳**才是片头信号
  if (to <= from) return null;
  // ④ 幅度过小 = 日常微调
  if (to - from < t.minJump) return null;
  // ⑤ 落点双上限：绝对（600s）与相对（片长 50%）取更紧者
  if (to > t.maxIntro) return null;
  if (to > duration * t.maxIntroFraction) return null;
  final sec = to.inSeconds;
  // ⑥ 同值去重：已记过同一落点 ⇒ 静默（不重写、不重复 flash）
  if (memoryIntroEnd != null && sec == memoryIntroEnd) return null;
  return Duration(seconds: sec);
}
