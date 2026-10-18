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
import '../../ui/theme/app_colors.dart';
import '../../ui/theme/theme_pack.dart';
import '../../ui/tokens.dart';

/// 自建设计系统的主题数据 —— 取代 Material 的 `Theme` + `ThemeData` + `ColorScheme`。
@immutable
class AppThemeData {
  AppThemeData({
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

  // ── 组件面向的语义色（10 个角色，取代 ColorScheme）────────────────
  //
  // ★★★ 2026-10-18（轨道 E · M1）：`AppSemanticColors` 是**从 palette 现算**的
  //
  // ```text
  // palette  = 主题作者能写的原料（background / card / border / primary …）
  // colors   = 组件真正需要的角色（surfaceContainer / outline / outlineVariant …）
  // ```
  // 这层派生放在这里，而不是放进 `AppSemanticColors` 里 import AppPalette ——
  // 因为 `app_palette.dart` 自己 import 了 material_ui（它是 ThemeExtension），
  // 而 `app_colors.dart` 必须保持「零 Material」，那是整个摘除工程的地基。
  //
  // ⚠️ 用 `late final` 缓存：一次 `AppThemeData` 只算一次。
  //    `AppThemeData` 是 @immutable 且值相等的，同一个 data 实例被
  //    多处 `AppTheme.of(context)` 拿到时，不该每次都重跑一遍 `Color.lerp`。
  //
  // ★ 为什么要去掉构造函数上的 `const`（2026-10-18）
  // ```text
  // Dart 明确禁止「有 late final 字段的类保留生成式 const 构造」
  // （late_final_field_with_const_constructor）—— 因为 const 对象必须在
  // 编译期完全定型，而 late 字段是运行期才算的。
  // ⇒ 构造改成非 const。**代价为零**：全仓 `AppThemeData(` 的调用点
  //   只有 app_theme.dart 的文档示例与本文件，没有 const 调用
  //   （`grep -n "const AppThemeData(" lib test` 在改动前就是 0 命中）。
  // ```
  late final AppSemanticColors colors = AppSemanticColors.derive(
    brightness: brightness,
    background: palette.background,
    card: palette.card,
    border: palette.border,
    foreground: palette.foreground,
    mutedForeground: palette.mutedForeground,
    primary: palette.primary,
    primaryForeground: palette.primaryForeground,
    error: palette.error,
  );

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
