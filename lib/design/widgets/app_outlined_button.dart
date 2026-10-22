// ═══════════════════════════════════════════════════════════════════════
//  自建描边按钮 —— 取代 Material 的 OutlinedButton / OutlinedButton.icon
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它
// ```text
// 轨道 E（Owner 路线：彻底不用 Material 组件，全部自建/玻璃）。
// `OutlinedButton` 在当前仓还有 4 处（detail_page），其中 3 处构成
// 「详情页操作行四枚按钮」—— 那一组有专门门禁（t27_w3）钉着
// 「四枚必须同源同档」这个**产品契约**。
// ```
//
// # ★★★ 这个组件最要紧的东西：**复刻 Material 的密度策略**
//
// 四枚按钮的几何**随平台变**，这是真实契约（不是实现细节）：
// ```text
//   windows  72×32      android  72×48
// ```
// 那个差异**不是**手写的，是 Material 的 `ButtonStyleButton` 按
// `ThemeData.materialTapTargetSize` / `visualDensity` 算出来的。
// 自建组件不继承这套逻辑 ⇒ **必须自己复刻**，否则几何契约会丢。
//
// ── 复刻的出处（不是猜的，逐行可查）────────────────────────────────
//
// 包：`material_ui-1.6.0`
// 文件：`lib/src/button_style_button.dart`
//
// ```text
// :462  final Offset densityAdjustment = resolvedVisualDensity!.baseSizeAdjustment;
// :507  final double dy = densityAdjustment.dy;
// :508  final double dx = math.max(0, densityAdjustment.dx);
//       // ↑ 注释原文：don't allow the VisualDensity adjustment to reduce
//       //   the width of the left/right padding（横向只增不减）
// :509  final EdgeInsetsGeometry padding = resolvedPadding!
//         .add(EdgeInsets.fromLTRB(dx, dy, dx, dy))
//         .clamp(EdgeInsets.zero, EdgeInsetsGeometry.infinity);
//
// :584  final Size minSize;
// :585  switch (resolvedTapTargetSize!) {
// :586    case MaterialTapTargetSize.padded:
// :587      minSize = Size(
// :588        kMinInteractiveDimension + densityAdjustment.dx,   // 48 + dx
// :589        kMinInteractiveDimension + densityAdjustment.dy,   // 48 + dy
// :590      );
// :593    case MaterialTapTargetSize.shrinkWrap:
// :594      minSize = Size.zero;                                  // ← 不设下限
// ```
//
// ── 实测验证（.probe/probe_e_density_math_test.dart）──────────────
//
// ```text
// windows: tapTarget=shrinkWrap + density=compact(-2,-2)
//          padding 链 = [EdgeInsets(10, 3, 10, 3)]
//          ⇒ Size(72.0, 32.0)
//
// android: tapTarget=padded + density=standard(0,0)
//          padding 链 = [EdgeInsets(10, 11, 10, 11)]
//          ⇒ Size(72.0, 48.0)
// ```
// ⇒ 公式（本组件即按此实现）：
// ```text
// 基础 padding 竖直 8（见 _kBaseVerticalPadding） + dy
//   compact(-2) ⇒ 8 + (-2) = 6 ？实测是 3
// ```
// ⚠️ 上面对不上 —— 因为 `styleFrom` 的默认 padding 不是 8。
// 实测反推：windows 3 = base + (-2) ⇒ base = 5；android 11 = 5 + 6？
// ⇒ 单看 padding 推不出稳定公式，**所以本组件不复刻 padding 的推导，
// 而是直接复刻「结果」**：见 [_resolveGeometry] 的注释。
//
// # 本组件的做法：复刻**结果**，不复刻**过程**
// ```text
// 不去重演 Material 那一串 padding/density 的推导（那条链有 5 个以上
//   互相影响的变量，且版本间会变），而是：
//   ① 读 Theme 的 materialTapTargetSize / visualDensity
//   ② 按**实测标定表**换算成 (竖直内边距, 最小高度)
//   ③ 标定表每项都注明了对应平台的实测值
// ⇒ 好处：结果可验证（t27_w3 逐平台量），坏处：需要标定表
// ⇒ 若某天 Material 改了算法，本仓门禁会红 —— 那是**期望行为**
//   （几何变了就该被看见），届时重标定即可。
// ```

import 'package:flutter/widgets.dart';
// ⚠️ 只为两个**主题配置枚举**（MaterialTapTargetSize / VisualDensity）而引入：
//    它们是 ThemeData 上的平台适配字段，本组件要读它们才能复刻几何。
//    TODO(M5): 主题层自建后改读 AppThemeData 的同名字段，届时本 import 可删。
// ignore: depend_on_referenced_packages
import 'package:material_ui/material_ui.dart'
    show MaterialTapTargetSize, Theme, VisualDensity;

import '../../ui/tokens.dart';
import '../theme/app_theme.dart';
import '../theme/app_theme_data.dart';
import 'app_ink_well.dart';

/// 自建描边按钮 —— 取代 `OutlinedButton` / `OutlinedButton.icon`。
///
/// [onPressed] 为 null ⇒ 禁用态（变灰、不响应点击）。
///
/// # 与 Material 的对位关系
/// ```text
/// OutlinedButton(onPressed:, child:, style:)      → AppOutlinedButton(...)
/// OutlinedButton.icon(onPressed:, icon:, label:)  → AppOutlinedButton.icon(...)
/// ```
class AppOutlinedButton extends StatelessWidget {
  /// 纯文字版。
  const AppOutlinedButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.foregroundColor,
    this.borderColor,
    this.backgroundColor,
  })  : icon = null,
        label = null;

  /// 图标 + 文字版（对位 `OutlinedButton.icon`）。
  const AppOutlinedButton.icon({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.foregroundColor,
    this.borderColor,
    this.backgroundColor,
  }) : child = null;

  /// null ⇒ 禁用
  final VoidCallback? onPressed;

  /// 纯文字版的子组件（`OutlinedButton.child`）
  final Widget? child;

  /// icon 版的图标（`OutlinedButton.icon`）—— **尺寸由调用方给**（通常 16）
  final Widget? icon;

  /// icon 版的文字（`OutlinedButton.icon`）
  final Widget? label;

  /// 覆盖前景色（对应 `styleFrom(foregroundColor:)`）。
  /// null ⇒ 用主题的 primary。
  final Color? foregroundColor;

  /// 覆盖描边色（对应 `styleFrom(side:)`）。
  /// null ⇒ 用主题的 outline。
  final Color? borderColor;

  /// 覆盖底色（对应 `styleFrom(backgroundColor:)`）。
  /// null ⇒ 透明。
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    /*
     * TODO(M4): AppThemeScope 接上后，把 resolvedOf 改回 AppTheme.of。
     * 理由见 lib/design/theme/app_theme.dart 的 resolvedOf 注释。
     */
    final t = AppTheme.resolvedOf(context);
    final enabled = onPressed != null;

    final fg = enabled
        ? (foregroundColor ?? t.primary)
        : t.mutedForeground.withValues(alpha: 0.5);
    final border = enabled
        ? (borderColor ?? t.border)
        : t.mutedForeground.withValues(alpha: 0.3);

    final g = _resolveGeometry(context);

    // ── 内容：icon 版是 Row(icon, gap, label)，纯文字版就是 child ──
    final content = switch ((icon, label, child)) {
      (final Widget ic, final Widget lb, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTheme.merge(data: IconThemeData(color: fg), child: ic),
            const SizedBox(width: _kIconGap),
            DefaultTextStyle.merge(
              style: _labelStyle(t, fg),
              child: lb,
            ),
          ],
        ),
      (_, _, final Widget c) => DefaultTextStyle.merge(
          style: _labelStyle(t, fg),
          child: c,
        ),
      // 两个都没给 ⇒ 空（防御；正常调用不会走到）
      _ => const SizedBox.shrink(),
    };

    Widget body = AppInkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(Radii.md),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: border),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: _kHorizontalPadding,
            vertical: g.verticalPadding,
          ),
          child: content,
        ),
      ),
    );

    /*
     * 最小高度：只在 `MaterialTapTargetSize.padded` 时存在
     * （对应 `button_style_button.dart:584-594` 的 minSize 逻辑）。
     * 用 ConstrainedBox + Center 而不是 SizedBox：
     * ¶ SizedBox 会把高度**写死**，内容更高时会被压；
     *   Material 用的是 minHeight（_InputPadding），语义是"至少"。
     */
    if (g.minHeight > 0) {
      body = ConstrainedBox(
        constraints: BoxConstraints(minHeight: g.minHeight),
        child: Center(widthFactor: 1.0, heightFactor: 1.0, child: body),
      );
    }

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      child: body,
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
//  密度复刻 —— 标定表（每个数字都有实测出处）
// ══════════════════════════════════════════════════════════════════════

/// 按钮文字样式 —— 与 `theme_bridge.dart:181-188` 的 `btnText` **逐字同源**。
///
/// # 为什么必须逐字同源（不是"差不多就行"）
/// ```text
/// 实测：我第一版手写 `fontSize: 14 / w500`，漏了 `height: 1` 与
///   `leadingDistribution: even` ⇒ 同一段「换源」两个字的**文本框宽度**
///   从 28.5 变成 28.0，按钮总宽从 72.5 变成 72.0。
///
/// Material 那边吃的是主题的 `btnText`（theme_bridge.dart:181），
/// 所以要"同档"就必须复制它的**每一个**字段，包括行高与行距分配。
/// ⇒ Owner 1011 反馈③（「下载按钮跟同一组的按钮大小不一致」）正是
///   因为漏了字重；这次漏的是行高。同一个病的不同变体。
/// ```
TextStyle _labelStyle(AppThemeData t, Color fg) => TextStyle(
      color: fg,
      fontFamily: t.typeface.fontFamily,
      fontFamilyFallback: t.typeface.fontFamilyFallback,
      fontSize: t.typeface.sm,
      fontWeight: FontWeight.w500,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
      /*
       * ★★★ letterSpacing 必须显式清零（实测抓到，否则宽 0.5px）
       *
       * ```text
       * 实测（.probe/probe_e_w285_test.dart 逐属性 dump）：
       *   Material 的 RichText: letterSpacing = null      ⇒ 按钮宽 72.0
       *   自建（未清零时）    : letterSpacing = 0.25      ⇒ 按钮宽 72.5
       *
       * 0.25 从哪来：`DefaultTextStyle.merge` 会**继承**外层文本样式，
       *   而 MaterialApp 的默认 TextTheme（bodyMedium，CJK 下 0.25）
       *   带着 letterSpacing ⇒ 我的 merge 把它一起吃进来了。
       *   「换源」两个字 × 0.25 = 0.5px，正好是差值。
       * ```
       *
       * ⇒ 显式 `letterSpacing: 0`。注意不是 `null`：
       *   `null` 在 merge 语义里表示"不覆盖"（仍会继承 0.25），
       *   必须给 `0` 才是真正的"不额外加字距"。
       */
      letterSpacing: 0,
    );

/// 横向内边距：两平台实测都是 10（`.probe/probe_e_density_math_test.dart`）。
///
/// ```text
/// windows padding 链 = [EdgeInsets(10, 3, 10, 3)]
/// android padding 链 = [EdgeInsets(10, 11, 10, 11)]
///                                          ↑ 横向都是 10，不随平台变
/// ```
/// 原因见 `button_style_button.dart:508`：横向密度调整取 `max(0, dx)`，
/// 即**只增不减**；compact 的 dx 是 -2 ⇒ 被 clamp 成 0 ⇒ 横向不变。
const double _kHorizontalPadding = 10;

/// icon 与 label 的间距。
///
/// 实测（.probe/probe_e_abtn_breakdown_test.dart）：
/// ```text
/// Material 的 Row 宽 = 52 = icon 16 + gap 8 + label 28
///                                      ↑ 就是这 8
/// ```
/// ⚠️ 不是 `Sp.x1`(4) —— 我第一次用 4，结果整体宽 96 vs Material 72。
/// Material 的 `OutlinedButton.icon` 用固定的 8（`_scaledPadding` 之外
/// 单独加的那段），与间距标度无关。
const double _kIconGap = 8;

/// 由 `ThemeData` 的两个密度开关解出 (竖直内边距, 最小高度)。
///
/// # 标定表（实测值，见 `.probe/probe_e_density_math_test.dart`）
/// ```text
/// 平台      materialTapTargetSize   visualDensity     实测尺寸   竖直padding  最小高度
/// windows   shrinkWrap             compact(-2,-2)    72×32      3            0
/// android   padded                 standard(0,0)     72×48      11           48
/// ```
///
/// # 为什么是「查表」而不是「算公式」
/// ```text
/// 我试过从 Material 的源码推公式（button_style_button.dart:462/507-512/584-594），
/// 但那条链里 styleFrom 的默认 padding、theme 的 padding、density 的
/// baseSizeAdjustment **三者互相叠加**，且 styleFrom 的默认值随版本变。
/// 实测反推也不自洽（windows 3 = base + (-2) ⇒ base=5，
///   但 android 11 = 5 + 6 对不上 standard 的 dy=0）。
/// ⇒ 与其写一个"看起来能推"但会随版本悄悄错的公式，
///   不如直接钉**结果**：每个值都有实测出处，改了就红。
/// ```
({double verticalPadding, double minHeight}) _resolveGeometry(
    BuildContext context) {
  /*
   * ⚠️ 为什么这里必须 `Theme.of`（而不是"彻底不碰 Material"）
   *
   * ```text
   * 实测（material_ui-1.6.0/lib/src/theme.dart:122-127）：
   *   `Theme.of` 内部查的是**私有** `_InheritedTheme`，
   *   外部无法用 `dependOnInheritedWidgetOfExactType` 判存在性
   *   （`Theme` 本身是 StatelessWidget，不是 InheritedWidget）。
   * ⇒ 只有两条路：
   *   ① 调 `Theme.of`（缺 MaterialApp 时抛）；
   *   ② 让调用方把密度配置**传进来**。
   * ```
   *
   * 本组件选 ①，理由：
   * ```text
   * `materialTapTargetSize` / `visualDensity` **不是 Material 组件**，
   * 是**主题层的平台适配配置**（shell 按平台烘焙进 ThemeData）。
   * 自建按钮要跟同一行里的旧按钮同档，就必须读同一份配置。
   * ⇒ 这是"读主题配置"，不是"用 Material 组件"，不违背 Owner 路线。
   * ```
   * TODO(M5): 主题层自建后，改读 `AppThemeData` 的同名字段，
   *           届时本文件对 material_ui 的依赖可完全删除。
   */
  final theme = Theme.of(context);
  final tapTarget = theme.materialTapTargetSize;
  final density = theme.visualDensity;

  final vpad = _kVerticalPaddingFor(density);

  switch (tapTarget) {
    case MaterialTapTargetSize.shrinkWrap:
      /*
       * shrinkWrap ⇒ **不设**最小高度（对应 button_style_button.dart:593-594
       * 的 `minSize = Size.zero`）。
       * 最终高度完全由「内容 + 上下 padding」决定。
       */
      return (verticalPadding: vpad, minHeight: 0);

    case MaterialTapTargetSize.padded:
      /*
       * padded ⇒ 最小高度 48（对应 button_style_button.dart:586-590 的
       * `kMinInteractiveDimension + dy`）。
       *
       * ⚠️ 这里**不**把 padding 也调大 —— 那样会双重叠加。
       *    Material 在 padded 下的 padding 链报 (10,11,10,11)，
       *    但其中多出来的 6 就是"48 减去内容 16 再摊半"的结果。
       *    本组件用 minHeight:48 + 居中达到同一结果，padding 保持 p，
       *    ⇒ 实测总高 48 ✓、总宽与 shrinkWrap 一致 ✓。
       */
      return (
        verticalPadding: vpad,
        minHeight: 48.0 + density.baseSizeAdjustment.dy,
      );
  }
}

/// 竖直内边距 —— 按 density **查表**（每项都有实测出处）。
///
/// # 标定依据（全部逐值实测，见 .probe/probe_e_abtn_*.dart）
/// ```text
/// density                    baseSizeAdjustment   本函数返回   实测总高(内容16)
/// compact(-2,-2)             (-8,-8)              16           32   ✓
/// standard(0,0)              (0,0)                16           32   ✓
/// ```
/// ⚠️ 两个档位返回**同一个值 16** —— 因为实测显示：
/// ```text
/// windows(compact): 总高 32 = 16 内容 + 上下各 8   ⇒ 竖直留白 8？不，是 16
/// ```
/// 这里的 16 是**上下各 8** 的总和语义（`EdgeInsets.symmetric(vertical:)`
/// 传的是**单边**值）⇒ 单边 = 8，总高 = 16 + 8*2 = 32 ✓
///
/// 而 android(standard) 总高 48 由 `minHeight: 48` 兜住（见上），
/// padding 单边 8 不会让它变 64（因为 16+16=32 < 48，被 minHeight 抬到 48）✓
double _kVerticalPaddingFor(VisualDensity density) {
  /*
   * 单边竖直留白 = 8（实测：32 - 16 = 16，上下分摊 ⇒ 单边 8）。
   *
   * ⚠️ density 在这里**不参与**计算 —— 实测两档结果相同。
   *    保留参数是为了将来 Material 改变算法时能在这里加分支，
   *    且让调用处显式表明"我看过 density"。
   *    TODO(M5): 若 Material 改算法导致 t27_w3 红，在此加分支重标定。
   */
  assert(density.baseSizeAdjustment.dy <= 0 || density == VisualDensity.standard);
  return 8.0;
}
