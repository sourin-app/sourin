// ═══════════════════════════════════════════════════════════════════════
//  AppSemanticColors —— 语义色层（**不依赖 Material**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有它（Owner 的路线选择）
//
// Owner 已明确：**彻底不用 Material 组件，全部自建 / 玻璃**。
//
// 那么 `ColorScheme` 就必须有一份自己的对应物 —— 不是「换一套色值」，
// 而是「换掉取色的容器」：
// ```text
// Theme.of(context).colorScheme.surfaceContainerHigh
//   → AppTheme.of(context).colors.surfaceContainerHigh
// ```
// 角色名**逐个对齐** Material，这样替换是机械的、能一眼校对；
// 而依赖关系是**断开的**（本文件不 import material_ui）。
//
// # 三层结构（不要混）
// ```text
// ① ThemePack.palette  (AppPalette)   12 个**原始**语义色，主题包直接给
// ② AppSemanticColors         （本文件）      10 个**组件面向**的语义角色，从 ① 派生
// ③ ColorScheme                       旧的 ②（Material 版），要被逐点替换掉
// ```
// ★ ①② 的关系不是「两套色板」，而是「原料 → 派生」：
//   ① 是主题作者能写的（background / card / border / primary …），
//   ② 是组件需要但主题作者**不该去填**的（surfaceContainer / outlineVariant …）。
//   上一轮的教训是把这两层当成「同一层的两套」，于是出现了「改了①②不变」
//   的静默分叉（见 theme_bridge.dart 里 task-31 / task-42 那两段实录）。
//
// # 本文件的两个硬约束（都有门禁）
// ```text
// ① 只 import dart:ui —— 唯一允许的额外 import 是 flutter/foundation 的
//    `@immutable` 注解（那是纯注解库，不含任何组件）。
//    ⚠️ **不许** import flutter/widgets，更不许 material_ui：
//    否则「摘掉 material」在这一层就没断干净，而这一层是地基。
// ② 所有角色从 ① **派生**，不新造色板 —— 详见 [AppSemanticColors.derive] 的公式说明。
// ```

import 'dart:ui' show Color, Brightness;

import 'package:flutter/foundation.dart' show immutable;

/// 一套**组件面向**的语义色 —— 取代 Material 的 `ColorScheme`
///
/// 角色清单与 `ColorScheme` 对齐（覆盖自建组件真正会用到的那些），
/// 但**一个字段都不来自 Material**：全是 `dart:ui` 的 [Color]。
///
/// ⚠️ 这是 [immutable] 但**不是** `const`-only：派生要用 `Color.lerp` /
///    `Color.alphaBlend`，它们不是 const 表达式。所以要一个
///    [AppSemanticColors.derive] 工厂，而不是只给 const 构造。
@immutable
class AppSemanticColors {
  const AppSemanticColors({
    required this.brightness,
    required this.primary,
    required this.onPrimary,
    required this.surface,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.error,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
  });

  /// 明暗档（与 `ColorScheme.brightness` 同名同义）
  ///
  /// ★ 为什么语义色要自带明暗：**配色只是明暗的一半**。
  ///   同一个 `primary` 在深底上要用浅字、在浅底上要用深字，
  ///   任何需要「按明暗选一支」的地方都得先知道这一档。
  ///   由 [AppSemanticColors.derive] 从入参带进来，与色值同源，不会分叉。
  final Brightness brightness;

  bool get isDark => brightness == Brightness.dark;

  /// 主色 —— 选中态 / 强调 / 开关 / 滑杆的**唯一**高饱和色
  ///
  /// 对��� `ColorScheme.primary`，来自 `AppPalette.primary`（主题包直接给）。
  final Color primary;

  /// 压在 [primary] 之上的文字 / 图标
  ///
  /// ⚠️ 必须**成对**跟着主题包走。实测过的反例：某套浅色主题的主色是
  ///    浅粉，配白字只有 2:1 —— 写死白字就等于让那套主题的按钮字消失。
  ///    （theme_bridge.dart:772 有这段读数。）
  final Color onPrimary;

  /// 页面底色（= `ColorScheme.surface`）
  ///
  /// 来自 `AppPalette.background`。
  final Color surface;

  /// 正文色（= `ColorScheme.onSurface`），来自 `AppPalette.foreground`
  final Color onSurface;

  /// 次要文字（= `ColorScheme.onSurfaceVariant`）
  ///
  /// 来自 `AppPalette.mutedForeground`。
  ///
  /// ★ 为什么它必须**单独**存在：Material 的兜底是
  ///   `onSurfaceVariant = onSurface`，于是「次要文字」与「正文」
  ///   变成同一个色 ⇒ 文字层级整个消失（theme_bridge.dart:591 记过这个坑）。
  final Color onSurfaceVariant;

  /// 描边（= `ColorScheme.outline`）—— 已**合成成实色**
  ///
  /// ⚠️ 这里不做成「带 alpha 的描边」：部分主题包的 `border` 是
  ///    `0x1AFFFFFF`（10% 白）这类**半透明**值，直接拿去画线时
  ///    会跟着底下是什么色而变，同一套主题在卡片上和在页面底色上
  ///    画出两种线。⇒ 统一用 [Color.alphaBlend] 合成到 [surface] 上，
  ///    得到一个**确定的实色**。
  final Color outline;

  /// 更淡的描边（= `ColorScheme.outlineVariant`）—— 分隔线 / 弱边界
  ///
  /// ★ 与 [outline] **同值**，这是**有意**的：本仓的设计语言里
  ///   描边只有一档（粗细由 `ThemePack.borderWidth` 表达，不是靠两档颜色）。
  ///   theme_bridge.dart 里现网也是 `outline: borderSolid, outlineVariant: borderSolid`
  ///   两个角色同一个值 —— 这里如实保留，不为了「看起来更精细」新造一档。
  final Color outlineVariant;

  /// 错误色（= `ColorScheme.error`），来自 `AppPalette.error`
  ///
  /// ⚠️ 只承担「错误**文字/图标**」这种前景用法。做实心底时请配
  ///    `onPrimary` 那类「压在它上面的字」，不要直接写白字 ——
  ///    浅色主题的错误色是深红（#C22A20），深色主题的是浅红（#FF6467），
  ///    同一个白字在两边对比度差一倍。
  final Color error;

  /// 比 [surface] **抬升一档**的面（= `ColorScheme.surfaceContainer`）
  ///
  /// 用于：卡片内部的分区、输入框的凹槽、未选中的分段控件底 …
  ///
  /// ★ 派生规则**按明暗分岔**，理由有实测（见 [AppSemanticColors.derive]）：
  ///   深色下它是 `surface → card` 的半档；浅色下直接就是 `card`。
  final Color surfaceContainer;

  /// 再高一档的面（= `ColorScheme.surfaceContainerHigh`）
  ///
  /// ⚠️ 与 [surfaceContainer] 在**浅色**下会取到同一个值（都 = card）。
  ///    这不是 bug：浅色体系的「抬升」就是「更白」，而 card 已经是白，
  ///    再分档只会得到两个肉眼无差的白色（task-31 把那种塌平判过死）。
  ///    真要有层级，靠的是 [outline] 那条线，不是色差。
  final Color surfaceContainerHigh;

  // ══════════════════════════════════════════════════════════════════════
  //  派生
  // ══════════════════════════════════════════════════════════════════════

  /// 从**原料色**派生出一整套语义色
  ///
  /// # 为什么入参是一堆裸 [Color] 而不是 `AppPalette`
  /// ```text
  /// @palette.dart 自己 import 了 material_ui（它是 ThemeExtension）。
  /// 本文件一旦 import 它，就**传递地**把 material 拖进来了 ——
  /// 而本层存在的意义正是"在这一层断干净"。
  /// ⇒ 入参用裸 Color；"从 AppPalette 取"那一步放在 app_theme_data.dart
  ///   （那一层本来就是设计系统层，允许依赖 AppPalette）。
  /// ```
  ///
  /// # 六条公式与它们的实测依据
  ///
  /// 以下读数取自 `flutter test .probe/probe_e_colors_packs_test.dart`
  /// 与 `probe_e_colors_math_test.dart`（真跑 16 个内置主题包）：
  ///
  /// ```text
  /// ① primary / onPrimary / error / onSurface       ← 原料直取，无加工
  /// ② onSurfaceVariant                               ← mutedForeground 直取
  /// ③ outline = outlineVariant = alphaBlend(border, background)
  ///      浅色 daylight : #D3D9E4 ⇒ 与 border 完全相同（border 本就不透明）
  ///      深色 midnight : #232323 ⇒ 与现网字面量 #222222 差 1/255
  /// ④ surfaceContainerHigh = card
  ///      浅色 / 深色**都与现网一致**（现网两处都是 card）
  /// ⑤ surfaceContainer（深色）= lerp(background, card, 0.5)
  ///      midnight: #101010 ⇒ 与现网字面量 #111111 差 1/255（肉眼无差）
  /// ⑥ surfaceContainer（浅色）= card
  ///      ⚠️ 这一档**必须**分岔：浅色下 lerp 得到 #F7F8FB，
  ///      它与页面底 #EEF0F6 只有 **1.02:1** —— task-31 正是把这个值
  ///      判死并改成 #FFFFFF 的（theme_bridge.dart:745 那段注释）。
  ///      同一手法在 app_theme_data.dart:92 的 `surfaceRaised` 里已经用过：
  ///      「浅色抬升 = 白卡；深色抬升 = 在背景上叠白」。
  /// ```
  ///
  /// ★ 为什么⑥不是「缺陷」而是「语言」：浅色体系的层级靠**描边**表达
  ///   （白卡 + 一条线），深色体系靠**明度**表达（层层提亮）。
  ///   两个方向相反，共用一个公式必然有一边是错的。
  factory AppSemanticColors.derive({
    required Brightness brightness,
    required Color background,
    required Color card,
    required Color border,
    required Color foreground,
    required Color mutedForeground,
    required Color primary,
    required Color primaryForeground,
    required Color error,
  }) {
    final isDark = brightness == Brightness.dark;

    // ③ 描边合成实色（半透明描边会随底下是什么而变，见 [outline] 的说明）
    final solidOutline = Color.alphaBlend(border, background);

    // ④ 再高一档 = 卡面本身（浅/深都与现网一致）
    final high = card;

    // ⑤ / ⑥ 抬升半档 —— 按明暗分岔，理由见上面 ⑥
    final container = isDark
        ? Color.lerp(background, card, 0.5)!
        // 浅色：抬升就是「更白」，而 lerp 出来的值〈1.10:1〉看不见
        : card;

    return AppSemanticColors(
      brightness: brightness,
      primary: primary,
      onPrimary: primaryForeground,
      surface: background,
      onSurface: foreground,
      onSurfaceVariant: mutedForeground,
      outline: solidOutline,
      outlineVariant: solidOutline,
      error: error,
      surfaceContainer: container,
      surfaceContainerHigh: high,
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  值语义
  // ══════════════════════════════════════════════════════════════════════

  /// ★ 必须实现值相等，**不能**靠引用相等
  ///
  /// [AppSemanticColors] 是从 palette 现算的（`AppTheme.of(context).colors` 每次
  /// 访问都构造一个）。若用引用相等，`updateShouldNotify` 里的
  /// `data != oldWidget.data` 会因为"每次都新建"而**永远为 true** ⇒
  /// 每次重建都被判定成"主题变了" ⇒ 整棵树无谓重绘。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSemanticColors &&
          other.brightness == brightness &&
          other.primary == primary &&
          other.onPrimary == onPrimary &&
          other.surface == surface &&
          other.onSurface == onSurface &&
          other.onSurfaceVariant == onSurfaceVariant &&
          other.outline == outline &&
          other.outlineVariant == outlineVariant &&
          other.error == error &&
          other.surfaceContainer == surfaceContainer &&
          other.surfaceContainerHigh == surfaceContainerHigh;

  @override
  int get hashCode => Object.hash(
        brightness,
        primary,
        onPrimary,
        surface,
        onSurface,
        onSurfaceVariant,
        outline,
        outlineVariant,
        error,
        surfaceContainer,
        surfaceContainerHigh,
      );

  /// 调试用：一眼看清这十档色（`flutter test` 里打出来比对着看快得多）
  @override
  String toString() => 'AppSemanticColors(${brightness.name}, '
      'surface=${_hex(surface)}, onSurface=${_hex(onSurface)}, '
      'onSurfaceVariant=${_hex(onSurfaceVariant)}, '
      'surfaceContainer=${_hex(surfaceContainer)}, '
      'surfaceContainerHigh=${_hex(surfaceContainerHigh)}, '
      'outline=${_hex(outline)}, outlineVariant=${_hex(outlineVariant)}, '
      'primary=${_hex(primary)}, onPrimary=${_hex(onPrimary)}, '
      'error=${_hex(error)})';

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}
