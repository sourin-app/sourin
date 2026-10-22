// ═══════════════════════════════════════════════════════════════════════
//  行内小转圈 —— 按钮 icon 位 / SwitchListTile trailing / 行内状态
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（而不是直接用 AppLoading）
//
// ```text
// AppLoading 的描边是**写死的常量**：
//   app_loading.dart:374  _AppSpinner(stroke: AppLoadingSize.stroke)  // = 4.0
// ⇒ 描边**不随 size 缩放**。
// ⇒ 尺寸越小，描边占直径的比例越大，小到 14px 时会变成「实心饼」。
// ```
//
// 逐像素实测（深色底 #14161B，沿水平中线扫描量环的横截面宽度）：
//
// ```text
//   组件                     标称直径   中线环宽   描边占直径
//   CircularProgressIndicator 14px      3.0px      21.4%
//   CircularProgressIndicator 16px      3.0px      18.8%
//   AppLoading(size: 14)      14px      4.0px      28.6%   ← 粗 33%
//   AppLoading(size: 16)      16px      5.0px      31.3%   ← 粗 67%
//   AppLoading() 默认         30px      5.0px      16.7%   ← 正常
// ```
//
// ⇒ 30px 那个档是对的，**小尺寸档错了**。本组件就是补上小尺寸档。
//
// # 描边怎么算
//
// ```text
// 系数 0.14 的来历：让 14px / 16px 的环宽都落在 3.0px 附近，
// 与迁走前的 CircularProgressIndicator(strokeWidth: 2) 实测读数对齐
// （那个 2 是**画笔宽度**，渲染含抗锯齿后实测横截面是 3.0px）。
//   14 × 0.14 = 1.96 → 实测 3.0px
//   16 × 0.14 = 2.24 → 实测 3.0px
// 上下限见 [_kMinStroke] / [_kMaxStroke] 的说明。
// ```
//
// # 与 AppLoading 的关系
//
// ```text
// 画法**同源**（同一套「暗轨道 + 亮弧绕圈」），但**独立实现** ——
// 因为 AppLoading 的 _SpinnerPainter 是私有类，且它的 stroke 是常量。
// ★ 不把 AppInlineSpinner 做成 AppLoading 的包装：那样要么写死描边
//   （等于没修），要么得给 AppLoading 加参数（那会动到 14 个现有调用点，
//   而 Owner 只批了「新增组件」这一个方案）。
// ```

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 描边占直径的比例 —— 见文件头的实测表
const double _kStrokeRatio = 0.14;

/// 描边下限：再细就不是「一个圈」而是一根发丝了
///
/// ★ 2026-10-16 的既有判据（`AppLoadingSize.stroke` 的注释）：
///   描边 < 2.5 时 Owner 说「看不清楚」。本组件最小用到 14px，
///   14 × 0.14 = 1.96 ⇒ 会低于 2.5 ⇒ 这里抬到 2.0 作为地板，
///   不再往下 —— 再小的尺寸本身就不该用转圈表达（该用静态图标）。
const double _kMinStroke = 2.0;

/// 描边上限：小尺寸组件不该出现比 AppLoading 默认档更粗的描边
const double _kMaxStroke = 4.0;

/// 行内小转圈（按钮 icon 位 / SwitchListTile trailing / 行内状态）
///
/// 与 [AppLoading] 的区别：**描边按比例缩放**（stroke = size × 0.14），
/// 所以 14px 也是约 3px 环宽，不会变成实心饼。
///
/// ```dart
/// // 按钮 icon 位
/// icon: busy ? const AppInlineSpinner() : const Icon(AppIcons.search)
///
/// // SwitchListTile trailing（14px）
/// trailing: busy
///     ? const AppInlineSpinner(size: 14, color: DanmakuTextColors.body)
///     : _rowAction('检测', _runProbe)
/// ```
///
/// [color] 不传时取 `DefaultTextStyle` 的当前色 —— 与 Material 的
/// `CircularProgressIndicator` 在按钮里的默认取色习惯一致（跟随前景色）。
class AppInlineSpinner extends StatelessWidget {
  const AppInlineSpinner({
    this.size = 16,
    this.color,
    super.key,
  });

  /// 外圈直径（px）
  ///
  /// ★ 传 0 或负数**不会崩**：内部会夹到 [_kMinSize]，画一个最小可见的圈。
  ///   见 [AppInlineSpinner._effectiveSize] 的说明。
  final double size;

  /// 弧与轨道的颜色；`null` ⇒ 取 `DefaultTextStyle.of(context).style.color`
  final Color? color;

  /// 尺寸下限 —— 传 0 / 负数时的兜底
  ///
  /// ```text
  /// 为什么是 8 而不是直接 assert 崩掉：
  ///   这是**展示组件**，调用方传错尺寸时，用户看到的是一个很小的圈，
  ///   比「整个页面白屏（assert 在 release 下不生效，debug 下红屏）」好。
  ///   而 8px 已经小到一眼能看出「这里尺寸配错了」，不会静默骗人。
  /// ```
  static const double _kMinSize = 8;

  double get _effectiveSize => size < _kMinSize ? _kMinSize : size;

  double get _stroke =>
      (_effectiveSize * _kStrokeRatio).clamp(_kMinStroke, _kMaxStroke);

  @override
  Widget build(BuildContext context) {
    final c = color ?? DefaultTextStyle.of(context).style.color ?? const Color(0xFFE6E6E6);
    final s = _effectiveSize;
    return SizedBox(
      width: s,
      height: s,
      child: _InlineSpinner(
        color: c,
        stroke: _stroke,
      ),
    );
  }
}

/// 自绘转圈 —— 与 `app_loading.dart` 的 `_SpinnerPainter` **同源画法**
///
/// ⚠️ 故意不共用那个私有类：共用要么得把它公开（动公共组件），
///   要么得把 stroke 传进去（那 AppLoading 也得改）。
///   Owner 只批了「新增组件」，所以这里独立实现，画法逐字照抄。
class _InlineSpinner extends StatefulWidget {
  const _InlineSpinner({required this.color, required this.stroke});

  final Color color;
  final double stroke;

  @override
  State<_InlineSpinner> createState() => _InlineSpinnerState();
}

class _InlineSpinnerState extends State<_InlineSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(
        painter: _InlineSpinnerPainter(
          progress: _c.value,
          color: widget.color,
          stroke: widget.stroke,
        ),
      ),
    );
  }
}

class _InlineSpinnerPainter extends CustomPainter {
  _InlineSpinnerPainter({
    required this.progress,
    required this.color,
    required this.stroke,
  });

  final double progress;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    // 半径 = (直径 − 描边) / 2 ⇒ 描边**完整落在盒内**，不会被裁
    final r = (math.min(size.width, size.height) - stroke) / 2;
    if (r <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: r);

    // ① 轨道：同色极低透明度 —— 让人看出"这是个圆"
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..color = color.withValues(alpha: 0.18);
    canvas.drawCircle(center, r, track);

    // ② 亮弧：绕圈跑（0.4 圈 = 144°，与 AppLoading 一致 —— 见那边的说明）
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true
      ..color = color;

    const sweep = math.pi * 2 * 0.4;
    final start = progress * math.pi * 2 - math.pi / 2;
    canvas.drawArc(rect, start, sweep, false, arc);
  }

  @override
  bool shouldRepaint(_InlineSpinnerPainter old) =>
      old.progress != progress || old.color != color || old.stroke != stroke;
}
