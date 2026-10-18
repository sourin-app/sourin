// ═══════════════════════════════════════════════════════════════════════
//  自建按钮 —— 取代 Material 的 TextButton / ElevatedButton
// ═══════════════════════════════════════════════════════════════════════
//
// # 实测用法（37 个文件用 TextButton）
// ```text
// 绝大多数是：TextButton(onPressed: ..., child: Text(...))
// 少数带 style: TextButton.styleFrom(foregroundColor: ...)
// ⇒ 只覆盖这一种形态。颜色从 AppTheme 读，不接 style 对象。
// ```
//
// # 为什么把"按钮皮肤"写在组件里，而不是 ThemeData.buttonTheme
// ```text
// Material 的按钮样式走 ThemeData.buttonTheme —— 那是"组件主题"机制，
// 我们没有那一层（见 AppThemeData 的设计取舍）。
// 自建按钮把默认样式写在组件内，颜色从 AppTheme 读 ⇒ 效果等价且少一层间接。
// ```

import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import 'app_ink_well.dart';

/// 自建文字按钮 —— 取代 `TextButton`。
///
/// [onPressed] 为 null ⇒ 禁用态（变灰、不响应点击）。
class AppTextButton extends StatelessWidget {
  const AppTextButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.foregroundColor,
  });

  /// null ⇒ 禁用
  final VoidCallback? onPressed;
  final Widget child;

  /// 覆盖默认前景色（对应 `TextButton.styleFrom(foregroundColor:)`）
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final enabled = onPressed != null;
    final fg = enabled
        ? (foregroundColor ?? t.primary)
        // 禁用态：次要前景再压一档 —— 与 Material 的 disabled 观感一致
        : t.mutedForeground.withValues(alpha: 0.5);

    return AppInkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(t.radius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            color: fg,
            fontFamily: t.typeface.fontFamily,
            fontFamilyFallback: t.typeface.fontFamilyFallback,
            fontSize: t.typeface.sm,
            fontWeight: FontWeight.w500,
          ),
          child: child,
        ),
      ),
    );
  }
}
