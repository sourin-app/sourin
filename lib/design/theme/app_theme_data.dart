// ═══════════════════════════════════════════════════════════════════════
//  自建设计系统 · 主题数据（去 Material 的 A 步）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这个类（Owner 第 4/8/9 条）
// ```text
// Owner 原话：「按照全套换掉 material去做」，不接受分阶段。
//
// Material 的 Theme / ThemeData / ColorScheme 三件套是整个 UI 层的根：
//   67 个文件用 Theme、62 个用 Material、23 个用 ColorScheme。
// 只要还有一个 widget 走 Theme.of(context)，material_ui 就摘不掉。
// ```
//
// # 设计取舍：不做 ThemeData 那样的"组件主题大杂烩"
// ```text
// Material 的 ThemeData 有 200+ 字段，大部分是"某组件的默认样式"
// （buttonTheme / cardTheme / dialogTheme / chipTheme …）。
// 那是为了兼容 Material 组件库才需要的。
//
// 我们的自建组件把样式写在组件内，由语义色 + 令牌驱动
// ⇒ 不需要"组件主题"这一层。
//
// ⇒ 本类只装真正跨组件共享的东西：语义色 / 明暗 / 字体族 / 皮肤参数。
// ```

import 'package:flutter/widgets.dart';

import '../../ui/app_palette.dart';
import '../../ui/app_typeface.dart';
import '../../ui/theme/theme_pack.dart';
import '../../ui/tokens.dart';

/// 自建设计系统的主题数据 —— 取代 Material 的 `Theme` + `ThemeData` + `ColorScheme`。
@immutable
class AppThemeData {
  const AppThemeData({
    required this.palette,
    required this.typeface,
    this.pack,
  });

  /// 12 个语义色（background / foreground / primary / secondary / muted /
  /// mutedForeground / card / border / error / barrier / primaryForeground /
  /// secondaryForeground）。
  final AppPalette palette;

  /// 字体族与字号阶梯
  final AppTypeface typeface;

  /// 用户选中的主题包（null = 内置默认）
  final ThemePack? pack;

  /// 明暗**从 palette 派生**，不单独存 —— 避免两处真源分叉。
  ///
  /// ⚠️ 这一点是刻意的：`AppPalette` 本来就带 `brightness`（app_palette.dart:46），
  ///    再存一份就会出现"palette 是深色但 theme 说是浅色"的不一致状态。
  Brightness get brightness => palette.brightness;

  bool get isDark => brightness == Brightness.dark;

  // ── 皮肤参数（从 ThemePack 读，缺省回落令牌）──────────────────────

  /// 统一圆角。`ThemePack.radius` 为 null 时回落 [Radii.md]。
  double get radius => pack?.radius ?? Radii.md;

  /// 描边宽度
  double get borderWidth => pack?.borderWidth ?? 1.0;

  /// 分隔线厚度
  double get dividerThickness => pack?.dividerThickness ?? 1.0;

  // ── 语义色快捷方式（组件里最常用，省去 .palette.xxx）──────────────

  Color get background => palette.background;
  Color get foreground => palette.foreground;
  Color get primary => palette.primary;
  Color get primaryForeground => palette.primaryForeground;
  Color get secondary => palette.secondary;
  Color get secondaryForeground => palette.secondaryForeground;
  Color get muted => palette.muted;
  Color get mutedForeground => palette.mutedForeground;
  Color get card => palette.card;
  Color get border => palette.border;
  Color get error => palette.error;
  Color get barrier => palette.barrier;

  /// 派生：抬升一档的表面色。
  ///
  /// ⚠️ 浅色下越抬越**白**，深色下越抬越**亮** —— 方向相反，不能共用一个公式。
  ///    浅色：抬升 = 白卡 `#FFFFFF`（比页面底亮）
  ///    深色：抬升 = 在背景上叠 6% 白（比背景亮）
  Color get surfaceRaised => isDark
      ? Color.alphaBlend(const Color(0x0FFFFFFF), background)
      : card;

  /// 派生：下沉一档的表面色（凹槽 / 未选中的分段控件底）。
  Color get surfaceSunken => isDark
      ? Color.alphaBlend(const Color(0x14FFFFFF), background)
      : Color.alphaBlend(const Color(0x0A000000), card);

  AppThemeData copyWith({
    AppPalette? palette,
    AppTypeface? typeface,
    ThemePack? pack,
  }) =>
      AppThemeData(
        palette: palette ?? this.palette,
        typeface: typeface ?? this.typeface,
        pack: pack ?? this.pack,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppThemeData &&
          other.palette == palette &&
          other.typeface == typeface &&
          other.pack == pack;

  @override
  int get hashCode => Object.hash(palette, typeface, pack);
}
