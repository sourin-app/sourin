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

import '../../ui/app_palette.dart';
import '../../ui/app_typeface.dart';
import '../../ui/app_theme.dart' as ui_theme;
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

  /// 过渡期取主题：有 [AppThemeScope] 就用它，没有则**按明暗现造一份**。
  ///
  /// ═══════════════════════════════════════════════════════════════════
  /// TODO(M4): AppThemeScope 接上后本方法应删除，调用点改回 AppTheme.of
  /// ═══════════════════════════════════════════════════════════════════
  ///
  /// # 为什么需要它（2026-10-18 实测，不是防御性编程）
  ///
  /// ```text
  /// AppTheme.of 刻意不兜底（见文件头），但实测：
  ///   AppThemeScope 在 lib/ 里**零实例化**（grep 只命中定义处），
  ///   根仍是 MaterialApp（shell.dart:1930）。
  /// ⇒ 自建组件（AppTextButton / AppSwitch …）一律用 AppTheme.of，
  ///   一旦接进真实页面就会**断言崩溃**，而不是"颜色不对"。
  ///   这比不接更糟 —— 崩溃会挡住整个页面。
  /// ```
  ///
  /// # 与 [of] 的分工（**不要混用**）
  /// ```text
  /// AppTheme.of         → 已确定在应用树里，缺 scope 就是 bug，要炸
  /// AppTheme.resolvedOf → 过渡期：产品代码还没接线，允许按明暗兜底
  /// ```
  /// ⚠️ 兜底出来的是一份**按 Brightness 现造**的 AppThemeData，
  ///    它**不知道用户选的主题包**（AppThemeMode / ThemePack）。
  ///    所以只能用于"还没接线"的过渡期，**不能**当成正式取色路径。
  static AppThemeData resolvedOf(BuildContext context) {
    final d = AppThemeScope.maybeOf(context);
    if (d != null) return d;
    return themeDataFor(context);
  }

  /// 按当前明暗现造一份 [AppThemeData]（不依赖 [AppThemeScope]）。
  ///
  /// 明暗判据优先用 `MediaQuery.platformBrightness`（纯 widgets，不碰 Material）；
  /// 拿不到时回落深色（本仓默认深色）。
  ///
  /// ⚠️ 与 [resolvedOf] 一样是过渡期设施，见那里的 TODO(M4)。
  static AppThemeData themeDataFor(BuildContext context) {
    final b = _brightnessWithoutMaterial(context);
    final pal = b == Brightness.light ? AppPalette.light : AppPalette.dark;
    return AppThemeData(
      palette: pal,
      typeface: AppTypeface.forPlatform(b),
    );
  }

  /// 不用 `Theme.of` 判断明暗（那样会重新引入 Material 依赖）。
  ///
  /// ```text
  /// 判据顺序：
  ///   ① `ui.AppTheme.resolve(systemBrightness:)` —— **唯一正确**的判据，
  ///      它把「用户选的模式」（浅色 / 深色 / 跟随系统）算进去。
  ///   ② 系统明暗从 `MediaQuery.platformBrightness` 取（纯 widgets）。
  /// ```
  ///
  /// # ★★★ 为什么不能用裸 `MediaQuery.platformBrightness`（我第一版就是）
  ///
  /// ```text
  /// 实测（.probe/probe_e_btncolor_test.dart，MaterialApp 显式给深色主题）：
  ///   resolvedOf.brightness = Brightness.light   ← 错！
  ///   Material.brightness   = Brightness.dark    ← 对的
  ///   resolvedOf.primary    = #171717（近黑）
  ///   resolvedOf.background = #FFFFFF（白）
  ///
  /// 根因：无头/测试环境的 platformBrightness 是 light，
  ///       而用户**在应用内选的是深色**。
  /// ⇒ 直接用 platformBrightness ⇒ 深色页面上出现"近黑按钮字 + 白底"，
  ///   对比度 ~1.1:1，**基本看不见**。
  /// ```
  /// ⇒ 必须走 `ui.AppTheme.resolve`，它读的是用户真正选的那个模式。
  ///
  /// ⚠️ `lib/design/` 依赖 `lib/ui/` 的 `app_palette` / `app_typeface`
  ///    是既有事实（本文件第 30-31 行），所以这里不新增反向依赖。
  static Brightness _brightnessWithoutMaterial(BuildContext context) {
    final system =
        MediaQuery.maybePlatformBrightnessOf(context) ?? Brightness.dark;
    return ui_theme.AppTheme.resolve(systemBrightness: system);
  }

  /// 当前是否深色；没有 [AppThemeScope] 时按 [fallback] 判。
  static Brightness brightnessOf(
    BuildContext context, {
    Brightness fallback = Brightness.dark,
  }) =>
      AppThemeScope.maybeOf(context)?.brightness ?? fallback;
}
