// ═══════════════════════════════════════════════════════════════════════
//  主题入口 —— 三态（跟随系统 / 浅色 / 深色）+ 偏好持久化
// ═══════════════════════════════════════════════════════════════════════
//
// # 这里只管「现在是亮还是暗 / 用户选的哪一态」
//
// 具体的色值与组件样式在 `theme_bridge.dart`，语义色在 `app_palette.dart`，
// 字号字族在 `app_typeface.dart`。三件事分开，是为了让将来里程碑 2 的
// 「多套调色板」只需要换调色板，不用碰这一层。

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../core/ui_prefs.dart';
import 'app_palette.dart';
import 'theme/theme_pack.dart';
import 'theme_bridge.dart';

export 'theme_bridge.dart' show LightTokens;

/// 主题切换的全局信号
///
/// # 为什么需要
///
/// 设置页改主题后要**立刻**生效，但设置页在很深的子树里，而 `MaterialApp`
/// 在最顶层 —— 没有共同的 State 可提升。原版是 Vue 的响应式 `ref`，
/// Flutter 侧等价物就是 `ValueNotifier`。
///
/// ⚠️ 放在这个**中立文件**里，不放在 `shell.dart`：设置页若反过来 import
///    `shell.dart` 就成**环**了（标题栏那轮已经因此挪过一次位置）。
final appThemeRevision = ValueNotifier<int>(0);

/// 请求重建主题（设置页改完主题后调它）
void notifyThemeChanged() => appThemeRevision.value++;

/// 主题模式（三态，与原版 `ThemeMode` 一一对应）
enum AppThemeMode {
  system('system', '跟随系统'),
  light('light', '浅色'),
  dark('dark', '深色');

  const AppThemeMode(this.id, this.label);

  /// 存储用的 id（与原版 `localStorage` 的值一致，便于将来迁移）
  final String id;

  /// 设置页显示的名字
  final String label;
}

/// 主题管理器
class AppTheme {
  /// 存储键 —— **故意用原版的键名** `dsh.theme`，将来「从原版导入设置」能直接对上
  static const storageKey = 'dsh.theme';

  /// 用户选择（默认 `system`）
  static AppThemeMode get mode {
    final v = UiPrefs.get(storageKey);
    if (v == null) return AppThemeMode.system;
    for (final m in AppThemeMode.values) {
      if (m.id == v) return m;
    }
    return AppThemeMode.system; // 值非法时回落
  }

  static void setMode(AppThemeMode m) => UiPrefs.set(storageKey, m.id);

  /// 原始存储值（`null` = **从没设过**，与"设成了 system"不同）
  ///
  /// 交付实测要依次写 system/light/dark 再"还原"，但**还原成 system 不等于
  /// 删掉那个键** —— 那会往用户真实偏好文件里多塞一个键，属于未经要求修改
  /// 用户数据。所以探针保存原始值，测完原样写回。
  static String? get rawStored => UiPrefs.get(storageKey);

  /// 原样恢复（`null` = 删掉那个键，回到"从没设过"）
  static void restoreRaw(String? raw) {
    if (raw == null) {
      UiPrefs.remove(storageKey);
    } else {
      UiPrefs.set(storageKey, raw);
    }
  }

  /// 解析成实际生效的明暗（`system` 时读系统偏好）
  static Brightness resolve({required Brightness systemBrightness}) {
    switch (mode) {
      case AppThemeMode.light:
        return Brightness.light;
      case AppThemeMode.dark:
        return Brightness.dark;
      case AppThemeMode.system:
        return systemBrightness;
    }
  }

  /// 当前生效的主题包
  ///
  /// ⚠️ 用户选了主题包就用它（它自带明暗），否则退回「跟随系统 / 浅色 / 深色」
  ///    这套三态。这就是两者的衔接点：主题包是**叠加**在明暗之上的，
  ///    不是替换 —— 删掉主题包选择就回到原来的三态行为。
  static ThemePack get pack => ThemePackStore.current();

  /// 该明暗下的语义色（供需要「不建整套 ThemeData 也能取色」的地方用）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ T7（2026-10-17）：**必须与 [themeFor] 同源**，否则主题割裂
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 改前的缺陷（Owner 第 11 条：「主题非常的割裂」）
  ///
  /// 改前这里写的是：
  /// ```dart
  /// final p = selectedPack;
  /// if (p != null && p.brightness == b) return p.palette;   // ← 只在「恰好相等」时用包
  /// return b == Brightness.light ? _buildLightColors() : AppPalette.dark;
  /// ```
  /// 也就是**只有包与传入的 b 恰好同明暗**才用包，否则**整个包被忽略**、
  /// 按 `b` 返回内置亮/暗。而 [themeFor] 走 [themeForPack]，是
  /// `pack?.brightness ?? b` —— **包说了算**。
  /// ⇒ 两者**优先级相反**，一旦 `dsh.theme` 与所选主题包的 `brightness`
  ///   冲突，它们就返回**相反**的明暗。
  ///
  /// # 实测读数（`.probe/probe_tests/zz_t7d_rootcause_test.dart`，纯函数）
  ///
  /// ```text
  /// dsh.theme=dark  pack=builtin.daylight | resolve=dark | pack?.brightness=light
  ///   | themeFor().brightness=light   ← 包说了算（浅）
  ///   | floorColor=#0A0A0A            ← b 说了算（深）  ★ 相反
  /// ```
  /// 真机像素（`.probe/shots/t7_dark_home.png`，1444x845）：
  /// ```text
  /// y=8   标题栏 = (27,27,27)      深 ✓
  /// y=42  内容区 = (238,240,246)   = #EEF0F6 ★ 浅 ✗ ⇒ 与标题栏 13.6:1 割裂
  /// ```
  ///
  /// # 为什么症状长成「标题栏深、内容区浅」
  ///
  /// 标题栏与窗口外框**不经过**这里 —— 它们走 [floorColor] → 本方法，
  /// 而更外层还有 `MaterialApp.builder` 那层 `ColoredBox(floorColor)`
  /// （见 `shell.dart`）。但**内容区**（`AppScaffold` / `Scaffold` /
  /// `Material` 的默认底色）取的是 **`MaterialApp.theme`**，也就是
  /// [themeFor] 的结果（浅）。⇒ 两层各取一个源，必然割裂。
  ///
  /// # 修法：优先级**唯一** —— 与 [themeForPack] 逐字对齐
  ///
  /// ```dart
  /// final p = selectedPack;
  /// if (p != null) return p.palette;        // ★ 包永远优先（自带明暗）
  /// return b == Brightness.light ? ... : AppPalette.dark;
  /// ```
  /// 这样 `colorsFor(b)` 与 `themeFor(b)` 在**任何** `b` 与包组合下都同明暗，
  /// 结构上不可能再出现「地板深、内容浅」。
  ///
  /// ⚠️ 不冲突时**行为逐字不变**（对照读数见上面的探针）：
  /// ```text
  /// dsh.theme=dark  pack=builtin.midnight（同为深） ⇒ 一致（改前也一致）
  /// dsh.theme=light pack=builtin.daylight（同为浅） ⇒ 一致（改前也一致）
  /// dsh.theme=dark  pack=(无)                      ⇒ 一致（改前也一致）
  /// ```
  /// ⇒ 只有「冲突组合」这一种情形的输出会变，而它改前本来就是错的。
  static AppPalette colorsFor(Brightness b) {
    // ★ 包自带明暗 ⇒ 选了包就以包为准（与 themeForPack 的
    //   `pack?.brightness ?? b` 同一条优先级）。绝不能在这里再与 b 比一次。
    final p = selectedPack;
    if (p != null) return p.palette;
    return b == Brightness.light
        ? (_lightColors ??= _buildLightColors())
        : AppPalette.dark;
  }

  static AppPalette? _lightColors;

  static AppPalette _buildLightColors() => AppPalette.light.copyWith(
        background: LightTokens.bgBase,
        foreground: LightTokens.textPrimary,
        mutedForeground: LightTokens.textSecondary,
        secondary: const Color(0xFFE8EAF0),
        secondaryForeground: LightTokens.textPrimary,
        muted: const Color(0xFFE8EAF0),
        card: LightTokens.bgElevated,
        border: LightTokens.glassStroke,
        primary: LightTokens.brand,
        primaryForeground: Colors.white,
        error: LightTokens.error,
      );

  /// 该明暗下的完整 Material 主题（按用户当前的选择）
  static ThemeData themeFor(Brightness b) => themeForPack(b, selectedPack);

  /// 指定一个主题包来建主题（`themeFor` 的可注入版本）
  ///
  /// ⚠️ 显式传 `pack` 时**必须**用它，不要再与 `b` 合成 ——
  ///    一份包自带明暗，调用方传的 `b` 与它冲突时以包为准
  ///    （否则会出现"卡片是樱粉的、底色是深色的"这种半拼接）。
  static ThemeData themeForPack(Brightness b, ThemePack? pack) =>
      buildAppTheme(pack?.brightness ?? b, pack: pack);

  /// 用户当前选中的主题包（没选 = null，即"只用三态明暗"）
  static ThemePack? get selectedPack =>
      ThemePackStore.selectedId.isEmpty ? null : pack;

  /// 窗口「地板色」—— 自绘标题栏的玻璃**背后**垫的那一层
  ///
  /// # 为什么必须集中成一个方法
  ///
  /// `MaterialApp.builder` 里的 `context` 在主题注入点**之上**，
  /// `Theme.of` / forui 的 `XTheme.of` 在那里都会**静默兜底成浅色**（都不报错）。
  /// 后果（真机取证）：深色下标题栏玻璃透出 `(239,239,239)` 浅灰，
  /// 而内容区画的是 `#0A0A0A` —— 一条浅色横条压在深色内容上。
  ///
  /// ⇒ 只认调用方**自己算出来的** brightness，色值与 `MaterialApp.theme` 同源。
  ///
  /// # 为什么浅色用 `LightTokens.bgBase` 而不是纯白
  ///
  /// 玻璃是"半透明白叠在底色上"—— 白叠白等于没有色差，玻璃会整个消失。
  /// 所以浅色必须用原版那一档带蓝的浅灰（`--bg-base: #eef0f6`）。
  static Color floorColor(Brightness b) => colorsFor(b).background;

  /// ★★★ 窗口投影色 —— 「像 QQ 那种边缘模糊阴影」
  ///
  /// # 曾经想做、Owner 决定不做：窗口描边（细边框）
  ///
  /// 用户原话：「是不是应该加个浅色的边框或者阴影的,用来区分跟其他浅色客户端的重叠」。
  /// 当时计划过一条 1px 实线边框（画在窗口**内侧**、Flutter 画，与"投影"是
  /// 两件事），常量也写好了（浅 `#E3E5EB` / 深 `#2A2A2A`），但**从未接到渲染上**
  /// （`window_frame.dart` 全文只有一个 `BorderRadius`，没有 `Border`）。
  ///
  /// ⇒ **Owner 已裁定：不做**（2026-10-11 复核时确认），死常量已删除。
  ///    留这段是因为用户确实提过两次"区分重叠"，别误以为从没想过。
  ///    ⚠️ 上面的 [windowShadowColor] 是**另一件事**（用户明确否掉过系统阴影，
  ///    见其说明），不要与这条混为一谈。
  ///
  /// ★★★ 窗口投影色 —— 「像 QQ 那种边缘模糊阴影」
  ///
  /// 用户原话：「像 qq 客户端这种边缘模糊阴影,之前的是实体的非常难看」
  ///
  /// # 为什么系统给不了（实测，不是推测）
  ///
  /// ```text
  /// ① DWM 阴影 —— 本机拿不到：DwmGetWindowAttribute(EXTENDED_FRAME_BOUNDS)
  ///    返回 0,0,0,0。★ 根因是【系统设置】VisualFXSetting = 2
  ///    （「调整为最佳性能」）⇒ 用户机器上"窗口阴影"被系统关掉了。
  ///    依赖系统 = 在用户机器上必然拿不到。
  /// ② SetWindowCompositionAttribute 的 accent 渐变 → 【实心硬色带】
  ///    = 用户说的「实体的非常难看」
  /// ③ SetWindowRgn —— 二值裁剪，做不出模糊
  /// ```
  ///
  /// ⇒ 只能自绘。返回值只用**明度**（绘制时按层降 alpha）。
  static Color windowShadowColor(Brightness b) => b == Brightness.light
      ? const Color(0xFF1A1D26)
      : const Color(0xFF000000);
}
