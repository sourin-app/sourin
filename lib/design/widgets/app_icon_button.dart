// ═══════════════════════════════════════════════════════════════════════
//  自建图标按钮 + 表面容器 —— 取代 Material 的 IconButton / Material
// ═══════════════════════════════════════════════════════════════════════
//
// # IconButton（28 个文件）
// ```text
// 实测形态高度统一：IconButton(onPressed:, icon:, tooltip:, iconSize:)
// ⇒ 只覆盖这四个参数。
// ```
//
// # Material 容器（62 个文件，是去 Material 里最重的一块）
// ```text
// 读用法后发现它在本仓承担**两件完全不同**的事：
//
//   ① 给 InkWell 提供水波绘制层  （例：detail_page.dart:4841 type: transparency）
//      ⇒ 这类**根本不需要替代品** —— 我们的 AppInkWell 自绘高亮，
//         去掉 Material 外壳即可，行为不变。
//
//   ② 真的当"有色表面/卡片"用  （例：cache_page.dart:2097 color + shape + clip）
//      ⇒ 这类需要 AppSurface。
//
// ⇒ 所以迁移时**先分类再动手**：
//   grep 出每处 Material( 看它有没有 color/shape/elevation —— 没有就是第 ① 类，直接删。
// ```

import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import 'app_ink_well.dart';

/// 自建图标按钮 —— 取代 `IconButton`。
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.iconSize,
  });

  final Widget icon;

  /// null ⇒ 禁用（变灰 + 不响应）
  final VoidCallback? onPressed;

  /// 悬停提示文字。null/空 ⇒ 不包提示层。
  final String? tooltip;

  /// 图标尺寸（由调用方传给 icon 本身；这里只用于决定点击热区）
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    /*
     * TODO(M4): AppThemeScope 接上后，把 resolvedOf 改回 AppTheme.of。
     * 理由见 lib/design/theme/app_theme.dart 的 resolvedOf 注释
     * （AppThemeScope 在 lib/ 里零实例化，AppTheme.of 会断言崩溃）。
     */
    final t = AppTheme.resolvedOf(context);
    final enabled = onPressed != null;
    final size = iconSize ?? 24;

    // 点击热区 = 图标 + 8px 内边距（与 Material 默认 48dp 最小热区的精神一致，
    // 但按图标实际尺寸收，避免大块空白挤压布局）
    final pad = size <= 20 ? 4.0 : 8.0;

    Widget body = AppInkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(size + pad * 2),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: IconTheme.merge(
          data: IconThemeData(
            size: size,
            color: enabled ? t.foreground : t.mutedForeground.withValues(alpha: 0.4),
          ),
          child: icon,
        ),
      ),
    );

    /*
     * ★ 原来这里想包 `Tooltip` —— 但 Tooltip 属于 Material 层，
     *   用它就等于没摘掉 material_ui。
     *
     * ⇒ 暂时只把 tooltip 文本作为 `Semantics.label`（无障碍读屏仍可用），
     *   悬停气泡等自建 AppTooltip 落地后再接（见 lib/design/widgets/ 的 TODO）。
     *   ⚠️ 这是**功能上的暂时收窄**，不是"做完了"——如实标注。
     */
    final tip = tooltip;
    if (tip != null && tip.isNotEmpty) {
      body = Semantics(label: tip, child: body);
    }
    return body;
  }
}

/// 自建表面容器 —— 取代当"有色卡片"用的 `Material`。
///
/// ⚠️ 只用于 `Material` 的第 ② 类用法（有 color/shape/elevation 的）。
///    第 ① 类（只为给 InkWell 提供水波层）**直接删掉即可**，不用本组件。
class AppSurface extends StatelessWidget {
  const AppSurface({
    super.key,
    required this.child,
    this.color,
    this.borderRadius,
    this.border,
    this.clipBehavior = Clip.none,
  });

  final Widget child;

  /// 底色。null ⇒ 透明
  final Color? color;

  /// 圆角
  final BorderRadius? borderRadius;

  /// 描边（取代 Material 的 shape: 在多数场景下的用途）
  final BoxBorder? border;

  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: borderRadius,
        border: border,
      ),
      child: ClipRRect(
        borderRadius: borderRadius ?? BorderRadius.zero,
        clipBehavior: borderRadius == null ? Clip.none : clipBehavior,
        child: child,
      ),
    );
  }
}
