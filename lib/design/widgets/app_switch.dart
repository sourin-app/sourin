// ═══════════════════════════════════════════════════════════════════════
//  自建开关 / 分隔线 / 滑杆 —— 取代 Material 的 Switch / Divider / Slider
// ═══════════════════════════════════════════════════════════════════════
//
// # 实测用量（产品代码，排除注释）
// ```text
// Switch(      13 处
// SwitchListTile( 10 处 —— 是 Switch 的包装，见下
// Divider(     16 处
// Slider(      21 处
// ```
//
// # ⚠️ 一个必须先说清的事实
// ```text
// 本仓已经有自建的 PopoverSlider / PopoverDivider（player_bottom_bar 在用），
// 说明"滑杆/分隔线"这块**早就部分去 Material 化**了。
// ⇒ 本文件不是从零开始，而是补齐产品级通用版。
// ⇒ 迁移时要先看那一处用的是哪个，别把已经自建的又包一层。
// ```

import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// 自建开关 —— 取代 `Switch`。
///
/// 与 Material 的行为差异：**没有**水波、**没有**祖先 Material 依赖。
class AppSwitch extends StatefulWidget {
  const AppSwitch({
    super.key,
    required this.value,
    this.onChanged,
  });

  final bool value;

  /// null ⇒ 禁用（变灰、不响应）
  final ValueChanged<bool>? onChanged;

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch> {
  static const double _w = 44;
  static const double _h = 26;
  static const double _pad = 3;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final on = widget.value;
    final enabled = widget.onChanged != null;

    // 轨道：开=主色，关=边框色；禁用时整体压暗
    final track = !enabled
        ? t.border
        : (on ? t.primary : t.border);
    // 滑块：开=白（压在主色上），关=前景色
    final knob = !enabled
        ? t.mutedForeground
        : (on ? const Color(0xFFFFFFFF) : t.mutedForeground);

    return Semantics(
      // 读屏要能念出"开关，已打开/已关闭" —— Material 会自动做，我们自己做
      toggled: on,
      label: '开关',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => widget.onChanged!(!on) : null,
        child: SizedBox(
          width: _w,
          height: _h,
          child: Stack(
          children: [
            // 轨道
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                color: track,
                borderRadius: BorderRadius.circular(_h / 2),
              ),
            ),
            // 滑块
            AnimatedPositioned(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              left: on ? (_w - _h + _pad) : _pad,
              top: _pad,
              child: Container(
                width: _h - _pad * 2,
                height: _h - _pad * 2,
                decoration: BoxDecoration(
                  color: knob,
                  shape: BoxShape.circle,
                  // 轻微阴影让滑块"浮"在轨道上（Material 也这么做）
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }
}

/// 自建分隔线 —— 取代 `Divider`。
class AppDivider extends StatelessWidget {
  const AppDivider({super.key, this.indent = 0, this.thickness});

  final double indent;

  /// null ⇒ 用主题的 [AppThemeData.dividerThickness]
  final double? thickness;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: indent, right: indent),
      child: Container(
        height: thickness ?? t.dividerThickness,
        // 分隔线用边框色 —— AppThemeData 没有独立的 divider 色，
        // 语义上分隔线就是最弱的一档边框，复用 border 是对的。
        color: t.border,
      ),
    );
  }
}
