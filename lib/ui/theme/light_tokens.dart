// ═══════════════════════════════════════════════════════════════════════
//  浅色设计语言的真源 —— LightTokens
// ═══════════════════════════════════════════════════════════════════════
//
// ★★★ 2026-10-18（轨道 E · M1）：**纯搬迁**，从 `theme_bridge.dart` 整块搬来
//
// # 为什么要把这个类搬出来（不是整理癖）
//
// ```text
// 它原本埋在 theme_bridge.dart（863 行的**胶水文件**）的第 624–709 行。
// 而 theme_bridge 里其余 590 多行的职责是「把色值喂给 Material 组件主题」
// —— 那部分在换成玻璃/自建组件后**要整段删掉**。
//
// ⇒ 真色值与待删胶水放在同一个文件里，删胶水时极容易连带删掉真色值。
//   实测证据：本文件里的 11 个常量被 **12 个 lib 文件 + 7 个测试**消费：
//     app_theme.dart 9 处 · shell.dart 3 处 · app_dialog_section.dart 3 处
//     app_loading.dart / detail_page.dart / media_page.dart / search_page.dart
//     settings_kit.dart · theme_pack.dart · tokens.dart …
//   ⇒ 删它 = 立刻编译失败。
// ```
// 把真色值**物理搬出**胶水文件，是最直接的保护。
//
// # 为什么没有顺手改成 `AppSemanticColors` 的一部分
//
// ```text
// `AppSemanticColors` 是**组件面向**的角色（surfaceContainer / outline …），
// 而 `LightTokens` 是**设计语言面向**的原料色（bgBase / textPrimary / brand …）。
// 两者是「原料 → 派生」的关系，不是同一层（见 app_colors.dart 的三层说明）。
// 现在合并会让原料与角色混在一层，正是上一轮踩过的坑。
// ```
//
// # 兼容性
//
// `theme_bridge.dart` 用 `export 'light_tokens.dart';` 把本文件再导出 ⇒
// 现有 **19 处** `import '…/theme_bridge.dart'` 的调用点**一行都不用改**
// （其中多处是 `export 'theme_bridge.dart' show LightTokens;` 的转发，
//  只要 re-export 还在，转发链就不断）。
//
// # ⚠️ 本轮纪律：不改任何色值、不改任何语义
//
// 下面的常量与注释**逐字**来自 theme_bridge.dart 的原处，一个字没动。
// 连「原版 CSS 变量」的出处与 task-31 / task-42 的实测读数都保留 ——
// 那些是「为什么是这个值」的唯一记录，删了等于把结论变成信仰。

import 'dart:ui' show Color;

/// 浅色主题的语义色（照抄原版 `theme-light.css`）
///
/// # 它是什么层次
/// ```text
/// 原料色（设计语言面向）—— 不是组件角色。
///   bgBase / bgElevated    页面底 / 抬升面
///   textPrimary / textSecondary   正文 / 次要文字
///   divider / glassStroke  分隔线 / 描边
///   brand / brand2         品牌主色 / 次色
///   error / errorContainer 错误前景 / 错误淡底
///   surface2               次级容器
/// ```
/// 组件真正该用的角色请用 `AppSemanticColors`（app_colors.dart），
/// 那层是从这些原料**派生**出来的。
class LightTokens {
  /// `--bg-base: #eef0f6`
  static const bgBase = Color(0xFFEEF0F6);

  /// `--bg-elevated: #ffffff`
  static const bgElevated = Color(0xFFFFFFFF);

  /// `--text-primary: rgb(16 18 26 / 0.93)`
  ///
  /// ⚠️ 不是纯黑 —— 原版注释：「不能纯黑（刺眼）」。合成后约 `#1E2028`。
  static const textPrimary = Color(0xFF1E2028);

  /// 原版 `--text-secondary: rgb(16 18 26 / 0.60)`；本值 = **加深后**的等价色，
  /// 不再照抄 CSS 的字面合成值。
  ///
  /// ⚠️ 为什么不能再写 `rgb(16 18 26 / 0.60)` 的合成值 `#70727A`：
  /// 原版那支是**带 alpha** 的色，它在原版里合成在**抬升的白卡 `#ffffff`** 上
  /// ⇒ `#70727A over #FFFFFF` = 4.80:1 ✓（那才是原设计的意图）。
  /// Flutter 侧把它**压平成不透明常量**后，它就落到**页面底 `#EEF0F6`** 上
  /// ⇒ **4.21:1 ✗**（< WCAG AA 4.5）。
  /// 这正是「把 alpha 色压平」引入的回归：原设计在卡片上达标，压平后挂在页面底上不达标。
  ///
  /// ⇒ 修法：调**前景**（不动 `bgBase`，`#EEF0F6` 是原版 `--bg-base`，牵动整站底色），
  ///    取 `#60626B`（同色相、更暗一档）：
  /// ```text
  /// 对页面底 #EEF0F6 = 5.33:1 ✓
  /// 对白卡   #FFFFFF = 6.08:1 ✓
  /// 对 surface2 #F5F7FA = 5.66:1 ✓
  /// 与正文 #1E2028 仍明显不同 ⇒ 「次要 ≠ 正文」的层级保留
  /// ```
  static const textSecondary = Color(0xFF60626B);

  /// `--divider`
  ///
  /// ★ task-31：原 `#DFE1E8` 对页面底只有 **1.06:1** —— 分隔线形同虚设。
  ///   取 `#D5DAE5`，与 [glassStroke] 同色相、略深一档（分隔线本就该比描边明显）。
  ///   ⚠️ 无测试钉值（`grep DFE1E8 test/` = 0）。
  ///
  /// # ⚠️ 当前**无生产调用点**（2026-10-18 第 7 波审查登记）
  ///
  /// ```text
  /// `grep -rn "LightTokens.divider" lib/` ⇒ 仅 1 处，且在**注释**里
  ///   （lib/ui/widgets/app_dialog_section.dart:49 的说明文字）
  ///
  /// 唯一真实引用在探针：
  ///   .probe/probe_e_lighttokens_identical_test.dart:49
  ///     'divider': LightTokens.divider,   ← 迁移前后"值一致"的比对样本
  /// ```
  ///
  /// **为什么保留**（不是忘了删）：
  /// ```text
  /// ① 它是 `theme_bridge.dart` 原有常量的**原样迁移**
  ///    （改前就在那儿，同样零调用）⇒ 本轮没有新增死代码，只是搬了位置
  /// ② 那个 .probe 测试需要它当**比对样本**才能验证"迁移没改值"
  ///    ⇒ 删了会让迁移一致性测试失去依据
  /// ③ 它记录了 task-31 的对比度修复（1.06:1 → 1.16:1），是设计决策的一部分
  /// ```
  /// ⚠️ 若将来 `.probe/probe_e_*` 被删除，本常量可一并评估是否移除。
  static const divider = Color(0xFFD5DAE5);

  /// `--glass-stroke`
  ///
  /// ★ task-31：原 `#E4E6EC` 在页面底 `#EEF0F6` 上只有 **1.03:1** —— 描边等于没画。
  ///   （这正是 `theme_bridge.dart` 里那条注释描述过的同一类缺陷：
  ///    「thumb 像悬空的一个点」）。取 `#D3D9E4`（1.16:1），
  ///    刚好「看得见轮廓但不像分割线」。
  ///   ⚠️ 这个常量同时被 `outline` 与 `border` 两个角色用 —— 改一处两处都受益，
  ///      且**没有任何测试**钉它的值（`grep E4E6EC test/` = 0 命中）。
  static const glassStroke = Color(0xFFD3D9E4);

  /// `--brand-1` 浅色档
  ///
  /// ★ task-31：原值 `#3b6fe0`。**不改它** —— 有 6 条测试钉着这个值
  ///   （`task32_source_highlight_test.dart:54/59`、`provider_import_test.dart:1155/1158`、
  ///   `zz_cr_switch_style_test.dart:156`、`zz_cr_settings_8_navstate_test.dart:429`）。
  ///   改它会让「源条选中环」那组断言变红，且那是**行为契约**不是皮肤。
  static const brand = Color(0xFF3B6FE0);

  /// `--brand-2: #8b4de8`
  static const brand2 = Color(0xFF8B4DE8);

  /// 原版 `--danger` 即 `#d93025`；本值 = **加深后**的等价色，不再照抄 CSS 的字面值。
  ///
  /// ⚠️ 为什么不用字面值 `#D93025`：它直接在**页面底 `#EEF0F6`** 上只有
  /// **4.19:1 ✗**（< WCAG AA 4.5）—— 原版把它当**实心底 + 白字**用
  /// （`onError = #FFFFFF` 对 `#D93025` = 4.77:1，那是另一种用法，不受影响），
  /// 而 Flutter 侧把它当**页面底上的前景字色**（`colorScheme.error`、
  /// `AppPalette.error`）用 ⇒ 必须自己够暗。
  ///
  /// ⇒ 修法：调**前景**、同色相加深一档 → `#C22A20`：
  /// ```text
  /// 对页面底 #EEF0F6 = 5.01:1 ✓
  /// 对白卡   #FFFFFF = 5.71:1 ✓
  /// 对 surface2 #F5F7FA = 5.32:1 ✓
  /// ```
  /// ⚠️ 只加深前景 ⇒ `onError`/白字仍保持 `#FFFFFF`（对比只会更高，不破坏实心红按钮）。
  static const error = Color(0xFFC22A20);
  static const errorContainer = Color(0xFFFCE8E6);

  /// 次级容器（`--surface-2` 合成值）
  ///
  /// # ⚠️ 当前**无生产调用点**（2026-10-18 第 7 波审查登记）
  ///
  /// ```text
  /// `grep -rn "LightTokens.surface2" lib/` ⇒ **0 处真实调用**
  ///
  /// 唯一真实引用在探针：
  ///   .probe/probe_e_lighttokens_identical_test.dart:55
  ///     'surface2': LightTokens.surface2,   ← 迁移前后"值一致"的比对样本
  /// ```
  ///
  /// **为什么保留**（与 [divider] 同一组理由）：
  /// ```text
  /// ① 从 `theme_bridge.dart` **原样迁移**（改前即零调用，本轮未新增死代码）
  /// ② 迁移一致性测试拿它当比对样本
  /// ③ 它是原版 CSS `--surface-2` 的落地值，属设计 token 全集的一部分
  /// ```
  /// ⚠️ 若将来 `.probe/probe_e_*` 被删除，本常量可一并评估是否移除。
  static const surface2 = Color(0xFFF5F7FA);
}
