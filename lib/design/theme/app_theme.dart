// ═══════════════════════════════════════════════════════════════════════
//  自建设计系统 · 主题查找（取代 Theme.of）
// ═══════════════════════════════════════════════════════════════════════
//
// # 它取代什么
// ```text
// Material:  Theme.of(context)      → ThemeData   （67 个文件在用）
// 本仓改造:  AppTheme.of(context)  → AppThemeData
// ```
//
// # 为什么用 InheritedWidget 而不是 Provider/Riverpod
// ```text
// ① InheritedWidget 是 Flutter 内置的，零依赖 —— 摘 material 的同时不该新增依赖
// ② Material 的 Theme 本身就是 InheritedWidget（_InheritedTheme），语义等价
// ③ `dependOnInheritedWidgetOfExactType` 的更新传播是 Flutter 原生优化的
// ```
//
// # ★ 与 Material 的一个关键差异：**没有"兜底主题"**
// ```text
// Material 的 Theme.of 查不到祖先时会回落 `ThemeData.fallback()`（亮色）；
// 这正是历史 bug「主题设了深色文字却是深色」的成因之一（见 material_split_test.dart 文件头）。
//
// ⇒ 我们**故意不兜底**：查不到就抛断言。
//    理由：静默回落会把"忘了包 AppThemeScope"变成"看起来能跑但全是错色"，
//    那是比崩溃更难查的缺陷。
// ```

import 'package:flutter/widgets.dart';

import 'app_theme_data.dart';

/// 把 [AppThemeData] 注入 widget 树。
///
/// 用法与 Material 的 `Theme` 完全对应：
/// ```dart
/// AppThemeScope(
///   data: AppThemeData(palette: AppPalette.dark, typeface: t),
///   child: const MyApp(),
/// )
/// ```
class AppThemeScope extends InheritedWidget {
  const AppThemeScope({
    super.key,
    required this.data,
    required super.child,
  });

  final AppThemeData data;

  static AppThemeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppThemeScope>()?.data;

  @override
  bool updateShouldNotify(AppThemeScope oldWidget) => data != oldWidget.data;
}

/// 自建设计系统的主题入口 —— **取代 `Theme`**。
abstract final class AppTheme {
  /// 取当前主题。
  ///
  /// ⚠️ 查不到 [AppThemeScope] 会抛断言，**不回落默认值**。
  ///    理由见文件头「与 Material 的一个关键差异」。
  static AppThemeData of(BuildContext context) {
    final d = AppThemeScope.maybeOf(context);
    assert(
      d != null,
      'AppTheme.of() 找不到 AppThemeScope 祖先。\n'
      '请确认应用根（通常是 shell.dart）包了 AppThemeScope，\n'
      '测试里请用 AppTestHost 包一层。\n'
      '（本仓刻意不做兜底主题：静默回落会让"忘了包"变成"看起来能跑但全是错色"）',
    );
    return d!;
  }

  /// 取当前主题；没有 [AppThemeScope] 时返回 null。
  ///
  /// 用于「可能不在应用树里」的场景（如独立 widget 预览、条件渲染）。
  static AppThemeData? maybeOf(BuildContext context) =>
      AppThemeScope.maybeOf(context);

  /// 当前是否深色；没有 [AppThemeScope] 时按 [fallback] 判。
  static Brightness brightnessOf(
    BuildContext context, {
    Brightness fallback = Brightness.dark,
  }) =>
      AppThemeScope.maybeOf(context)?.brightness ?? fallback;
}
