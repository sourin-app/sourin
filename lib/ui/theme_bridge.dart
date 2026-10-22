// ═══════════════════════════════════════════════════════════════════════
//  主题构建 —— 从自有调色板派生一套「角色齐全」的 Material 主题
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件解决过两个「不报错」的真缺陷（历史，勿删）
//
// ## 坑 ①：两套 Material 的 Theme 互相看不见（最严重）
//
// Flutter 3.47 把 Material 从 SDK 拆成独立包 `material_ui`，
// 而 `package:flutter/material` 还在（同一个 SDK 里两份源码），
// 于是**同一个 app 里可以同时存在两套 Material**。两套 `Theme` 是
// **不同的 InheritedWidget 类型**，互相看不见；`Theme.of` 找不到祖先就走兜底：
//
// ```dart
// return inheritedTheme?.theme.data ?? cupertinoTheme?.materialTheme
//        ?? ThemeData.fallback();     // ← 亮色！
// ```
//
// 症状（TV 截图量到的像素，全部精确等于 Material 3 亮色 baseline）：
// ```text
// 「设置」标题  #1D1B20（亮色 onSurface）对背景对比度 1.16:1  ✗
// ```
//
// **深色背景上写深色字，标题几乎看不见**，而且**不报错**：编译过、
// analyze 0 error、单测全绿 —— 只有看截图量像素才发现。
// ⇒ 铁律：生产代码只 import `package:material_ui/material_ui.dart`
//   （`test/theme_regression_test.dart` 全 lib 扫描守着）。
//
// ## 坑 ②：Material 的 ColorScheme 角色**有兜底值**，漏填就同色
//
// ```dart
// Color get surfaceContainerHighest => _surfaceContainerHighest ?? surface;
// Color get outlineVariant          => _outlineVariant ?? onBackground;
// ```
//
// 于是 UI 里 `surfaceContainerHighest.withValues(alpha: 0.3)` 画出来的
// 卡片底 = `surface@0.3 over surface` = **和背景一模一样，卡片消失**；
// `outlineVariant` 画的边框 = `onBackground` = **纯白 1px 亮线**。
//
// ⇒ 本文件的职责就是**把 UI 实际用到的角色逐个显式填上**。
//
// # 色值来源（不自己发明）
//
// 全部来自本项目已验证过的那套调色板：深色是原 forui `AppPalette.neutralDark`
// （已搬进 `app_palette.dart` 的 `AppPalette.dark`），浅色是原版 Vue 的
// `src/design/theme-light.css`（见 `app_theme.dart` 的 `LightTokens`）。
// 组件主题的尺寸/圆角逐值对齐移除 forui 之前的读数 —— 这次替换是
// **外科手术**，不是重新设计。

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'app_palette.dart';
import 'app_typeface.dart';
import 'tokens.dart';
import 'theme/light_tokens.dart';
import 'theme/theme_language.dart';
import 'theme/theme_pack.dart';

// ★ 2026-10-18（轨道 E）：`LightTokens` 已搬到 `theme/light_tokens.dart`。
//   这行 `export` 保证**现有 19 处 import 本文件的调用点一行都不用改**
//   （含 `app_theme.dart` 的 `export 'theme_bridge.dart' show LightTokens;` 转发链）。
//   ⚠️ 上面那个 `import` 与这里这个 `export` **两行都要**，作用域不同：
//      export 让导入本文件的人看到 LightTokens；
//      import 让本文件自己的 _buildLight() 能用它。
//      只写 export ⇒ 本文件 6 处 LightTokens. 全报 Undefined name。
export 'theme/light_tokens.dart';

// ★ task-50 候选 C2：二级页转场改为「用户选的风格」
//   ⚠️ 不能写在 `material_ui` 那行之前 —— dart 惯例：package import 在前，
//      相对 import 在后（中间空一行）。
import 'widgets/page_transition_route.dart';

/// 组件统一的圆角
///
/// ★ task-31：`10 → 14`。理由（客观）：
///   · 本仓 `Radii` 阶梯是 `8/12/16/22/28/34/999`，**没有 10** —— 10 是体系外的野值。
///   · 10 落在 `xs(8)` 与 `sm(12)` 之间，导致「默认控件」比最小档还小、
///     却又比不上任何一档，视觉上「方不够方、圆不够圆」。
///   · 取 **14** 仍不在阶梯上 —— 但它让「默认控件 14 / 卡片 16 / 胶囊 999」
///     形成 14→16→999 的单调梯度，且与 `Radii.sm(12)`/`md(16)` 的中点是 14。
///   · ★ 无任何测试钉这个值（`grep _defaultRadius test/` = 0、`Radius.circular(10)` = 0）。
///   · ⚠️ 圆角不改变元素位置与尺寸 ⇒ 符合「布局逐处一致」的锁 2。
const _defaultRadius = 14.0;
const _radius = BorderRadius.all(Radius.circular(_defaultRadius));

RoundedSuperellipseBorder _shape({BorderSide side = BorderSide.none}) =>
    RoundedSuperellipseBorder(side: side, borderRadius: _radius);

/// 页面转场（关掉那层 scrim）
///
/// # 为什么必须把 scrim 设成透明
///
/// Windows 的默认转场是 `ZoomPageTransitionsBuilder`，它在**离场路由**外面
/// 套了一层 `ColoredBox(color: secondaryAnimation.isAnimating ? surface : transparent)`。
/// 那层色块**铺满整个离场路由**（含顶部操作条）⇒ 用户看到"一条白/浅色把顶栏盖住"
/// （Owner 原话：「进播放页面的时候这个白色条会把顶部的操作条给覆盖掉」）。
///
/// ★ 只改转场这一处：`colorScheme.surface` 还被 Scaffold / Card / Dialog
///   当兜底底色用着，改它会让整个 UI 的底色消失。
///
/// ⚠️ `PageTransitionsTheme.builders` 是**直通 getter，不与 SDK 默认值合并**，
///    所以 android / fuchsia 必须**显式登记**，否则真机上用户选的转场风格
///    完全不生效、时长还退回 SDK 的 300ms（与底栏 260ms 不一致）。
PageTransitionsTheme buildPageTransitionsTheme() {
  return const PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      // `SourinPageTransitionsBuilder` **继承** Zoom：离场页仍放大 1.05，
      // scrim 的透明处理逐字不变，只是新页的入场风格改为「用户在设置里选的」。
      TargetPlatform.windows: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
      TargetPlatform.linux: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
      TargetPlatform.android: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
      TargetPlatform.fuchsia: SourinPageTransitionsBuilder(
        backgroundColor: Colors.transparent,
      ),
    },
  );
}

/// 组装一套完整的 `ThemeData`
///
/// ⚠️ 深 / 浅是**两条独立分支**而不是一个按 brightness 分流后统一补色的
///    函数 —— 因为要补的角色不同（浅色要反过来设 surface / onSurface / 描边）。
///    ★ 所以**任何一处修复都必须在另一处同步做**，否则只有一半主题被修好。
ThemeData buildAppTheme(Brightness brightness, {ThemePack? pack}) {
  final td = brightness == Brightness.light
      ? _buildLight(pack?.palette)
      : _buildDark(pack?.palette);

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ T14 接线（2026-10-17）：设计语言统一走 `ThemeLanguage.apply`
   * ══════════════════════════════════════════════════════════════════
   *
   * # 改前这里只做**一件事**：按 `pack.radius` 覆盖圆角
   *
   * 于是主题包上的另外三个「设计语言」维度 —— `borderWidth` /
   * `dividerThickness` / `buttonPadding` —— **全仓没有一处读它们**：
   * 用户在主题包里写了也不生效，而且**不报错**（本仓已经踩过的
   * "假接口"形态：能解析、能序列化、能导出 JSON，就是没人消费）。
   *
   * ⇒ 现在把这段**整块换掉**，交给 `ThemeLanguage.apply(td, pack)`：
   * ```text
   * 面     card / dialog / bottomSheet / snackBar / listTile / chip
   * 按钮   四类（圆角 + 内边距 + 描边粗细）
   * 输入框 圆角 + 六态描边
   * 分隔线 粗细
   * ```
   *
   * # ★ 默认零变化（这是本仓的回归纪律，不是优化）
   *
   * `pack == null`（跟随系统 / 明暗三态）或四个维度**全为默认值**时，
   * `ThemeLanguage.apply` **原样返回同一个 ThemeData 实例**（`identical`）
   * —— 由 `zz_t14_theme_language_test.dart` 的 ③ 组钉死。
   * ⇒ 既有 6 套主题与"跟随系统"路径的渲染结果**逐像素不变**。
   *
   * ⚠️ 不能在这里自己再判一次 `pack?.radius == null`：判据必须只有
   *    **一份**（`ThemeLanguage.of(pack).isDefault`）。两处判据迟早漂移，
   *    而漂移的表现正是"某个维度在某个主题包上不生效"。
   */
  return ThemeLanguage.apply(td, pack);
}

// ═══════════════════════════════════════════════════════════════════════
//  组件主题（两套明暗共用）
// ═══════════════════════════════════════════════════════════════════════

/// 与明暗无关的**形状 / 尺寸**部分
///
/// 这里所有数值都等于移除 forui 之前的读数（实测 dump 对齐），
/// 所以「移除 forui」这一步在视觉上是零差异的。
ThemeData _shared(ThemeData base, AppPalette c, AppTypeface t) {
  WidgetStateProperty<OutlinedBorder?> shape = WidgetStateProperty.all(_shape());

  TextStyle btnText = TextStyle(
    fontFamily: t.fontFamily,
    fontFamilyFallback: t.fontFamilyFallback,
    fontSize: t.sm,
    fontWeight: FontWeight.w500,
    height: 1,
    leadingDistribution: TextLeadingDistribution.even,
  );

  // 原 forui 给所有按钮的内边距都是这一档
  const pad = EdgeInsets.symmetric(horizontal: 10, vertical: 11);

  WidgetStateProperty<Color?> dim(Color fg, Color disabledBg) =>
      WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.disabled) ? disabledBg : fg);
  Color soften(Color x, double a) => x.withValues(alpha: a);

  WidgetStateProperty<Color?> overlay(Color fg) =>
      WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.pressed)) return soften(fg, 0.10);
        if (s.contains(WidgetState.hovered)) return soften(fg, 0.08);
        if (s.contains(WidgetState.focused)) return soften(fg, 0.10);
        return null;
      });

  return base.copyWith(
    textTheme: t.toTextTheme(),
    // ★ forui 用的是 `NoSplash.splashFactory` —— 保留，否则每个按钮都会多出
    //   一圈 Material 默认的水波纹，与本项目自绘的按压反馈（press_feedback.dart）
    //   叠加成"双重反馈"。
    splashFactory: NoSplash.splashFactory,
    iconTheme: IconThemeData(color: c.primary, size: 20),
    dividerTheme: DividerThemeData(color: c.secondary, thickness: 1),

    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(btnText),
        padding: WidgetStateProperty.all(pad),
        shape: shape,
        backgroundColor: dim(c.primary, soften(c.foreground, 0.12)),
        foregroundColor: dim(c.primaryForeground, soften(c.foreground, 0.38)),
        // ⚠️ `FilledButton.icon` **不读** foregroundColor 画图标 ——
        //    `iconColor` 是独立属性。只改前景的后果是「文字看得见了，
        //    ▶ 图标还是看不见」（详情页那两个按钮用的正是它）。
        iconColor: dim(c.primaryForeground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.primaryForeground),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(btnText),
        padding: WidgetStateProperty.all(pad),
        shape: shape,
        backgroundColor: dim(c.secondary, soften(c.foreground, 0.12)),
        foregroundColor: dim(c.secondaryForeground, soften(c.foreground, 0.38)),
        iconColor: dim(c.secondaryForeground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.secondaryForeground),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(btnText),
        padding: WidgetStateProperty.all(pad),
        shape: shape,
        side: WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.disabled)) return BorderSide(color: c.disable(c.border));
          if (s.contains(WidgetState.hovered)) return BorderSide(color: c.hover(c.border));
          return BorderSide(color: c.border);
        }),
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? soften(c.foreground, 0.12) : c.background),
        foregroundColor: dim(c.foreground, soften(c.foreground, 0.38)),
        iconColor: dim(c.foreground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.foreground),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStateProperty.all(btnText),
        shape: shape,
        backgroundColor: WidgetStateProperty.all(Colors.transparent),
        foregroundColor: dim(c.foreground, soften(c.foreground, 0.38)),
        iconColor: dim(c.foreground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.foreground),
      ),
    ),

    // 卡片：零投影 + 1px 描边（forui 原样）
    cardTheme: CardThemeData(
      elevation: 0,
      color: c.card,
      shape: _shape(side: BorderSide(color: c.border)),
    ),

    dialogTheme: DialogThemeData(shape: _shape()),
    bottomSheetTheme: BottomSheetThemeData(shape: _shape()),
    snackBarTheme: SnackBarThemeData(
      shape: _shape(),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: ListTileThemeData(shape: _shape()),
    chipTheme: ChipThemeData(shape: _shape()),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.primary,
      foregroundColor: c.primaryForeground,
      elevation: 0,
      shape: _shape(),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: shape,
        foregroundColor: dim(c.foreground, soften(c.foreground, 0.38)),
        overlayColor: overlay(c.foreground),
      ),
    ),

    navigationBarTheme: NavigationBarThemeData(indicatorShape: _shape()),
    navigationRailTheme: NavigationRailThemeData(indicatorShape: _shape()),
    navigationDrawerTheme: NavigationDrawerThemeData(indicatorShape: _shape()),

    // ══════════════════════════════════════════════════════════════════
    // ★ 里程碑 3：下面这些组件在里程碑 1/2 时**没有**被覆盖，
    //   全部落回 Material 3 默认 —— 于是它们是全站唯一「不是一套设计」
    //   的部分（Owner 第 11 条「别的都一般般」的直接来源之一）。
    //
    //   判据统一：**形状**跟卡片/按钮同一档圆角（`_shape()`），
    //   **配色**跟次级面同一族（`c.secondary` / `c.card`）。
    //   凡是「浮在内容之上」的（菜单 / 提示条 / 悬浮层）都要**有边界**，
    //   否则在深色页面上它会跟背景糊在一起。
    // ══════════════════════════════════════════════════════════════════

    menuTheme: MenuThemeData(
      // ⚠️ `MenuThemeData.style` 是 `MenuStyle`（**不是** `ButtonStyle`）——
      //   两者的差别正好在 `textStyle` / `foregroundColor` 这些项上，
      //   传错类型编译器会直接报出来，但很容易照着按钮那边抄。
      style: MenuStyle(
        shape: shape,
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled) ? soften(c.foreground, 0.12) : c.card),
        // ★ 浮层必须有描边：深色下 `card` 与背景只差一档，没有描边时
        //   菜单会"融"进页面（这是最常见的"看起来不高级"来源）。
        side: WidgetStateProperty.all(BorderSide(color: c.border)),
        shadowColor: WidgetStateProperty.all(Colors.transparent),
        // ⚠️ `MenuStyle` 里这几个都是 `WidgetStateProperty<Color?>`（不是裸 Color）
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: c.card,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedSuperellipseBorder(
        borderRadius: _radius,
        side: BorderSide(color: c.border),
      ),
      textStyle: TextStyle(
        color: c.foreground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        // 反色：提示条是全站唯一的「反过来」的元素（前景当底）。
        // 这样它在任何底色上都能读，也一眼就与普通卡片区分开。
        color: c.foreground,
        borderRadius: Radii.rSm,
      ),
      textStyle: TextStyle(
        color: c.background,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.xs,
        height: 1.3,
      ),
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: Sp.x1),
      // 默认 Material 是**立即**弹出 —— 鼠标扫过一排图标会闪一片提示。
      waitDuration: const Duration(milliseconds: 500),
    ),

    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: TextStyle(
        color: c.foreground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
      ),
      menuStyle: MenuStyle(
        shape: shape,
        backgroundColor: WidgetStateProperty.all(c.card),
        side: WidgetStateProperty.all(BorderSide(color: c.border)),
        shadowColor: WidgetStateProperty.all(Colors.transparent),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
      ),
    ),

    scrollbarTheme: ScrollbarThemeData(
      // ⚠️ 滚动条是**唯一**默认就在屏幕上、且天天都在看的控件 ——
      //   Material 默认那根 4px 硬边深色条在本项目里非常突兀。
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.dragged)
          ? c.mutedForeground
          : soften(c.mutedForeground, 0.55)),
      trackColor: WidgetStateProperty.all(Colors.transparent),
      // 静止时收窄、hover/拖动时加粗 —— 平时不抢视线，操作时够得着
      thickness: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.dragged) || s.contains(WidgetState.hovered) ? 6.0 : 4.0),
      // ⚠️ 这里是 `Radius?` 不是 `BorderRadius`（传 double 会编译失败）
      radius: const Radius.circular(Radii.full),
      interactive: true,
    ),

    tabBarTheme: TabBarThemeData(
      labelColor: c.primary,
      unselectedLabelColor: c.mutedForeground,
      indicatorColor: c.primary,
      // ★ 分隔线透明而不是默认的硬灰 —— 默认那条在深色下是一条亮线
      dividerColor: Colors.transparent,
      labelStyle: TextStyle(
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        fontWeight: FontWeights.semibold,
      ),
      unselectedLabelStyle: TextStyle(
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        fontWeight: FontWeights.regular,
      ),
    ),

    badgeTheme: BadgeThemeData(
      backgroundColor: c.error,
      textColor: c.background,
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.primary,
      linearTrackColor: c.secondary,
      circularTrackColor: c.secondary,
    ),

    expansionTileTheme: ExpansionTileThemeData(
      iconColor: c.mutedForeground,
      collapsedIconColor: c.mutedForeground,
      textColor: c.foreground,
      collapsedTextColor: c.foreground,
      // ★ 默认形状带一条分割线，深色下那是一条贯穿的亮线。
      //   改成无描边，由页面自己控制分隔（与 settings_kit 一致）。
      shape: const Border(),
      collapsedShape: const Border(),
    ),

    // ★ 开关：两段式（轨道 + 拇指），开态用调色板的「主色对」。
    //
    //   改前的三条病灶（业主第二次反馈"还是很难看"）：
    //   ① 开态拇指与轨道几乎同色 —— 深色下 #FAFAFA 压在 #E5E5E5 上
    //      （亮度差 0.17），看上去是"一根亮条中间一道缝"；
    //   ② 浅色开态拇指用了 foreground（近黑 #1E2028）压在蓝底上
    //      ⇒ "蓝底黑痣"；
    //   ③ 关态轨道取 secondary，深色 #262626 在 #0A0A0A 上只有 1.31:1、
    //      浅色 #E8EAF0 在 #EEF0F6 上只有 1.06:1 —— 槽几乎看不见，
    //      拇指像悬空的一个点；而且 trackOutlineColor 与 trackColor
    //      取同一个值 ⇒ 描边画了等于没画。
    //
    //   现在：开态 = primary 轨道 + primaryForeground 拇指（跟随主题包，
    //   外部 JSON 换主色也自动跟），关态 = foreground 压 22% 到 background
    //   上的中性灰（对 6 套内置主题包最差对比度 1.56:1），描边统一用
    //   mutedForeground（视觉上的"静音边框"角色，且与槽稳定拉开 0.30 亮度）。
    //   色号全部由 AppPalette 角色算出，没有写死值。
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) {
          return c.disable(s.contains(WidgetState.selected)
              ? c.primaryForeground
              : c.foreground);
        }
        return s.contains(WidgetState.selected) ? c.primaryForeground : c.foreground;
      }),
      trackColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.disabled)) {
          return c.disable(s.contains(WidgetState.selected) ? c.primary : c.muted);
        }
        // ⚠️ 必须是不透明色：Switch 画拇指时会做
        //    `Color.alphaBlend(thumb, surface)`，半透明会被"洗白"。
        return s.contains(WidgetState.selected)
            ? c.primary
            : Color.alphaBlend(c.foreground.withValues(alpha: 0.22), c.background);
      }),
      // 开态轨道自己就是主色，再描一圈边只会显脏 ⇒ 只有关态描边。
      // 关态用 mutedForeground（比槽亮一档的"静音边框"）：两套明暗都稳。
      trackOutlineColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.selected)) return null;
        if (s.contains(WidgetState.disabled)) return c.disable(c.mutedForeground);
        return c.mutedForeground;
      }),
      // lib/ui 里 25 处 BorderSide 都不写 width（默认 1.0），这里对齐同一档
      trackOutlineWidth: WidgetStateProperty.all(1.0),
    ),

    sliderTheme: SliderThemeData(
      activeTrackColor: c.primary,
      inactiveTrackColor: c.secondary,
      thumbColor: c.primary,
      overlayColor: soften(c.primary, 0.12),
      valueIndicatorColor: c.foreground,
      valueIndicatorTextStyle: TextStyle(
        color: c.background,
        fontFamily: t.fontFamily,
        fontSize: t.xs,
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      // 原 forui：普通态描边、聚焦转主色、禁用半透明、错误转红
      border: WidgetStateInputBorder.resolveWith((states) {
        final side = states.contains(WidgetState.error)
            ? BorderSide(color: states.contains(WidgetState.disabled) ? c.disable(c.error) : c.error)
            : states.contains(WidgetState.disabled)
                ? BorderSide(color: c.disable(c.border))
                : states.contains(WidgetState.focused)
                    ? BorderSide(color: c.primary)
                    : BorderSide(color: c.border);
        return OutlineInputBorder(borderSide: side, borderRadius: _radius);
      }),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.border),
        borderRadius: _radius,
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.primary),
        borderRadius: _radius,
      ),
      errorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.error),
        borderRadius: _radius,
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.error),
        borderRadius: _radius,
      ),
      disabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: c.disable(c.border)),
        borderRadius: _radius,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      hintStyle: TextStyle(
        color: c.mutedForeground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        height: 1.3,
      ),
      labelStyle: TextStyle(
        color: c.mutedForeground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        height: 1.3,
      ),
      floatingLabelStyle: TextStyle(
        color: c.foreground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        fontWeight: FontWeight.w500,
        height: 1.3,
      ),
      errorStyle: TextStyle(
        color: c.error,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        height: 1.3,
      ),
      helperStyle: TextStyle(
        color: c.mutedForeground,
        fontFamily: t.fontFamily,
        fontFamilyFallback: t.fontFamilyFallback,
        fontSize: t.sm,
        height: 1.3,
      ),
    ),

    pageTransitionsTheme: buildPageTransitionsTheme(),
  );
}

/// 把 `AppPalette` 注入 `ThemeData` 的扩展位
ThemeData _withColors(ThemeData base, AppPalette c) =>
    base.copyWith(extensions: [c]);

// ═══════════════════════════════════════════════════════════════════════
//  深色
// ═══════════════════════════════════════════════════════════════════════

ThemeData _buildDark([AppPalette? override]) {
  final c = override ?? AppPalette.dark;
  final t = AppTypeface.forPlatform(Brightness.dark);

  // 边框角色**不能带 alpha** —— ColorScheme 的描边会被当实色画。
  // 这里按背景 #0A0A0A 把 `border`（白 10%）合成成实色 #222222，观感一致。
  const borderSolid = Color(0xFF222222);
  // 卡片底比背景亮一档（= AppPalette.dark.card = #171717）
  const card = Color(0xFF171717);

  final base = ThemeData(useMaterial3: true, brightness: Brightness.dark);
  final cs = c.toColorScheme().copyWith(
    // ── 表面层级（坑 ② 的主角）──
    surfaceContainerLowest: const Color(0xFF060606),
    surfaceContainerLow: const Color(0xFF0D0D0D),
    surfaceContainer: const Color(0xFF111111),
    surfaceContainerHigh: card,
    surfaceContainerHighest: card,

    // ── 文字层级 ──
    // 兜底的 onSurfaceVariant = onSurface，用它画次要文字层级会消失
    onSurfaceVariant: c.mutedForeground,

    // ── 描边 ──
    outline: borderSolid,
    outlineVariant: borderSolid,

    // ── 错误容器 ──
    // 兜底 errorContainer = error（实心红），而 UI 里拿它 @35% 当"淡红底"用，
    // 实心红太重。给一个真正适合做底的暗红。
    errorContainer: const Color(0xFF3A1416),
    onErrorContainer: const Color(0xFFFFB4B6),

    // ── 其余兜底（避免将来用到时又是"同色"）──
    primaryContainer: const Color(0xFF2A2A2A),
    onPrimaryContainer: c.foreground,
    secondaryContainer: const Color(0xFF262626),
    onSecondaryContainer: c.secondaryForeground,
    tertiary: c.primary,
    // ⚠️ `tertiary` 与 `onTertiary` 必须成对给：只给 tertiary 时兜底的
    //    onTertiary 是亮色 ⇒ 「背景很亮、前景也很亮」（实测 1.21:1，几乎不可见）。
    onTertiary: c.primaryForeground,
    surfaceTint: Colors.transparent,
    inverseSurface: c.foreground,
    onInverseSurface: c.background,
  );

  return _withColors(
    _shared(base.copyWith(colorScheme: cs), c, t),
    c,
  );
}

// ═══════════════════════════════════════════════════════════════════════════
//  浅色
// ═══════════════════════════════════════════════════════════════════════════
//
// ★★★ 2026-10-18（轨道 E · M1）：`LightTokens` **已搬走**
//
// ```text
// 它原来就在这下面（第 624–709 行，86 行），现在整块搬到
//   lib/ui/theme/light_tokens.dart
//
// 为什么搬：本文件是**胶水文件**（590 多行的职责是把色值喂给 Material
// 组件主题，换玻璃组件后要整段删掉），而 LightTokens 是**真色值**，
// 被 12 个 lib 文件 + 7 个测试消费。两者混在一起，删胶水时极易误伤。
//
// ⚠️ 兼容：下面那两行让**现有 19 处 import 本文件的调用点一行都不用改**
//    （包括 `app_theme.dart` 那句 `export 'theme_bridge.dart' show LightTokens;`
//     的转发链）。
//
// ★ 为什么 `export` 与 `import` **两行都要**（这是 Dart 的语义，不是冗余）：
// ```text
// export '…'  → 只影响**导入本文件的人**，让 LightTokens 出现在他们的命名空间
// import '…'  → 只影响**本文件自己**，让下面的 _buildLight() 能用 LightTokens
// 两者作用域不同、互不替代。少了 import，本文件里 6 处 LightTokens.
// 全变「Undefined name」（我第一版就只写了 export，dart analyze 当场报 6 条 error）。
// ```
// ⚠️ 且**两条都得在文件顶部**：Dart 要求 directive 出现在所有声明之前
//    （放在这里会被判 directive_after_declaration —— 我第二版就是这样撞的）。
//    所以实际位置见文件头 import 区末尾。

ThemeData _buildLight([AppPalette? override]) {
  final t = AppTypeface.forPlatform(Brightness.light);

  // 浅色板的默认值从 LightTokens 派生 —— 每个值都有原版 CSS 变量作出处。
  //
  // ⚠️ 主题包给了 `override` 时**完全用它**，不再逐字段覆盖 ——
  //    否则「用户在浅色主题包里配了 background」会被这行悄悄改回
  //    `LightTokens.bgBase`，表现为"导入的主题包不生效"。
  final c = override ??
      AppPalette.light.copyWith(
    background: LightTokens.bgBase,
    foreground: LightTokens.textPrimary,
    mutedForeground: LightTokens.textSecondary,
    // ★ task-31：凹槽/轨道的「可见层级」—— 原来 #E8EAF0 在 #EEF0F6 上只有 1.06:1
    //   几乎不可见。取同色相更深一档 #DDE2EB（对页面底 1.14:1、对数亮度差 0.075），
    //   既让凹槽「陷下去」看得出来，又不至于变成一块灰斑。
    secondary: const Color(0xFFDDE2EB),
    secondaryForeground: LightTokens.textPrimary,
    muted: const Color(0xFFDDE2EB),
    card: LightTokens.bgElevated,
    // ⚠️ 描边要**反过来**（原版要点 ⑤）：深色用白描边提亮边缘，
    //    浅色必须用深色描边才有轮廓。
    border: LightTokens.glassStroke,
    primary: LightTokens.brand,
    primaryForeground: Colors.white,
    error: LightTokens.error,
  );

  final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
  final cs = c.toColorScheme().copyWith(
    // ── 表面层级（浅色下「越高越白」，与深色相反）──
    surfaceContainerLowest: LightTokens.bgElevated,
    surfaceContainerLow: LightTokens.bgElevated,
    surfaceContainer: LightTokens.bgElevated,
    // ★ task-31：抬升层。浅色体系里「越高越白」，原 #F7F8FB 对页面底只有 1.02:1
    //   ⇒ 浮起的三层完全塌平。抬到纯白 #FFFFFF（1.16:1），让「浮起」真的成立。
    //   这与 card(#FFFFFF) 同值是有意的：抬升层就是「一张白卡」的语言。
    surfaceContainerHigh: const Color(0xFFFFFFFF),
    // ★ task-31：Highest 必须比 High **更深**才有层级语义（Material 的容器阶是
    //   「越低越浅、越高越深」在 M3 的反向约定见 _buildLight 顶部注释）。
    //   原来它 = surface2(#F5F7FA) 比 High(#F7F8FB) **只深 2 级**，肉眼无感。
    //
    // ⚠️ 2026-10-17（dlg-source 实测）：这一行是**硬编码蓝灰**，不跟主题包走。
    //   选了樱粉·浅(#F2C7CF) 之后它仍是 #E4E8F0（冷蓝灰），
    //   与粉底并置会有轻微「灰斑」感。
    //   但它是「容器最高阶」= 凹陷/轨道类底色，只占很小面积，
    //   且**刻意保持中性**才不跟主题强调色打架 ⇒ 暂不改成跟随主题。
    //   若将来要跟主题，应改成 c.secondary 一类，并重算所有用它的对比度。
    surfaceContainerHighest: const Color(0xFFE4E8F0),

    onSurfaceVariant: c.mutedForeground,

    // ★ task-42：两档描边都回到 `c.border` 单真源（原 glassStroke/divider 是写死值）
    outline: c.border,
    outlineVariant: c.border,

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-42（2026-10-17）：primary/error 这里原来写死 LightTokens,
     *      把主题包的值覆盖掉 —— 与下面 secondary 那个坑是**同一类**。
     * ══════════════════════════════════════════════════════════════════
     *
     * # 实测（改前）
     * ```text
     * pack                  palette.primary   cs.primary   一致?
     * daylight              2B54B8            3B6FE0        否
     * oled.light            171717            3B6FE0        否
     * midnightBlue.light    1E4C8A            3B6FE0        否
     * sakura.light          E38AA6(粉)        3B6FE0        否  ← 粉被换成蓝
     * forest.light          2E7D4F(绿)        3B6FE0        否  ← 绿被换成蓝
     * neoBrutal.light       000000(黑)        3B6FE0        否  ← 黑被换成蓝
     * minimal               3D5A4C            3B6FE0        否
     * ⇒ 7 套里 6 套失效；只有 glass 恰好也等于 3B6FE0 才没暴露。
     * ```
     *
     * # 为什么当时只修了 secondary
     * ```text
     * 下面那段注释记录了 secondary 的同类修复（"又写了一遍字面量 #E8EAF0"），
     * 但当时**没有把同类的其它字段全扫一遍** ⇒ primary / onPrimary /
     * onSurfaceVariant / outline / outlineVariant / error / onSecondary /
     * inverseSurface 全部漏网。
     * ⇒ 教训：修「一处覆盖」时要扫**同一个 copyWith 里的所有字段**，
     *   而不是只修被投诉的那一个。
     * ```
     *
     * # 现在：全部改为引用 `c`（AppPalette 的单真源）
     * ```text
     * 字段              改前              改后                    对比度复核
     * primary           LightTokens.brand c.primary               见下
     * onPrimary         Colors.white      c.primaryForeground     —
     * onSurfaceVariant  textSecondary     c.mutedForeground       >=4.69 全部过
     * outline           glassStroke       c.border                1.19~18.9 过
     * outlineVariant    divider           c.border                （同源）
     * error             LightTokens.error c.error                 >=3.57 全部过 3:1
     * onSecondary       textPrimary       c.secondaryForeground   —
     * inverseSurface    textPrimary       c.foreground            —
     * ```
     *
     * ★ primary/onPrimary 对比度（换成主题色后逐一复算，全部 >= 4.5）
     * ```text
     * daylight     2B54B8 + FFFFFF = 6.86
     * oled.light   171717 + FAFAFA = 17.18
     * midnightBlue 1E4C8A + FFFFFF = 8.55
     * sakura       E38AA6 + 231419 = 7.13   ← 浅粉配深字，不是白字
     * forest       2E7D4F + FFFFFF = 5.05
     * glass        3B6FE0 + FFFFFF = 4.63
     * neoBrutal    000000 + FFFFFF = 21.00
     * minimal      3D5A4C + F7F9F7 = 7.18
     * ```
     * ⚠️ sakura 的 onPrimary 是**深色** #231419（不是白字）—— 因为浅粉底上
     *    白字只有 2:1。这正说明「onPrimary 必须跟着主题包走」，
     *    写死 Colors.white 会让樱粉按钮上的字几乎看不见。
     *
     * # error 的复核（判据是 >=3:1，见 theme_invariants_test）
     * ```text
     * 换成主题包 error 后：midnightBlue/glass/neoBrutal/sakura 在 3.57~4.29，
     * 高于 3:1 判据 ⇒ 合法。
     * ⚠️ 但它们低于 4.5（正文标准）。error 是「提示色不是正文」，
     *    且原判据就定在 3:1，故不改 error 色值本身。
     * ```
     */
    primary: c.primary,
    onPrimary: c.primaryForeground,
    primaryContainer: const Color(0xFFDCE6FB),
    onPrimaryContainer: const Color(0xFF10305E),

    error: c.error,
    onError: Colors.white,
    errorContainer: LightTokens.errorContainer,
    onErrorContainer: const Color(0xFF5F1410),

    // ★ task-31：这里原来**又**写了一遍字面量 `#E8EAF0`，把上面
    //   `AppPalette.light.copyWith(secondary: ...)` 的值**覆盖掉**了 ——
    //   实测：改了 palette 的 secondary，live `colorScheme.secondary` 仍是 #E8EAF0。
    //   ⇒ 改为引用 `c.secondary`，让「凹槽色」只有一个真源。
    secondary: c.secondary,
    onSecondary: c.secondaryForeground,
    // ★ `secondaryContainer` / `onSecondaryContainer` 必须与 `secondary`
    //   同源，否则 `FilledButton.tonal` 看起来"没跟着主题走"。
    secondaryContainer: c.secondary,
    onSecondaryContainer: LightTokens.textPrimary,
    tertiary: LightTokens.brand2,
    onTertiary: Colors.white,
    surfaceTint: Colors.transparent,
    inverseSurface: c.foreground,
    onInverseSurface: LightTokens.bgBase,
  );

  return _withColors(
    _shared(base.copyWith(colorScheme: cs), c, t),
    c,
  );
}
