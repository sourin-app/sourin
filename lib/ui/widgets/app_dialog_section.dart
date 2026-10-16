// ═══════════════════════════════════════════════════════════════════════
//  弹窗「分区」共用件 —— 分区标题 / 分组留白 / 分组分隔线
//  task-12（2026-10-16）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么抽出来（实测：逐字重复）
//
// 这三样东西此前在每个弹窗里各写各的，实测有 **3 份逐字相同** 的
// `_sectionTitle` 和 **2 份逐字相同** 的 `_divider`（出处如下，行号是
// 抽出来之前的 HEAD）：
//
// ```text
// _sectionTitle  lib/ui/widgets/bili_import_dialog.dart:345    Colors.white / Colors.white38
//                lib/ui/widgets/danmaku_settings_dialog.dart:957  DanmakuTextColors.body / .muted
//                lib/ui/widgets/player_settings_sheet.dart:806    Colors.white / Colors.white38
// _divider       lib/ui/widgets/bili_import_dialog.dart:340    Colors.white24
//                lib/ui/widgets/player_settings_sheet.dart:800    Colors.white24
// _gap           lib/ui/widgets/danmaku_settings_dialog.dart:868  SizedBox(height: Sp.x3)
// ```
//
// 三份 `_sectionTitle` 的结构**逐字一致**，只有颜色来源不同：
//
// ```dart
// Padding(bottom: Sp.x3) > Row > [
//   Text(主标题, fontSize: FontSizes.base, fontWeight: w600),
//   if (note != null) SizedBox(width: Sp.x2) + Flexible(Text(注释, cap)),
// ]
// ```
//
// 重复的代价不是「多打几个字」，而是**改一处忘一处**：同一种「分区标题」
// 在三个弹窗里会各自漂移（字号、间距、颜色），而用户看到的是同一个产品。
// 所以定义只留这一份，`_sectionTitle` / `_divider` / `_gap` 三个名字都收拢到这里。
//
// # ★ 顺手修掉的缺陷：写死的白色
//
// 改前两处弹窗的主标题写 `Colors.white`、注释写 `Colors.white38`、
// 分隔线写 `Colors.white24` —— 深色主题下能看，**浅色主题下等于隐形**
// （白字压白底、白线压白底）。本文件一律改走
// `Theme.of(context).colorScheme`，三个角色都不是新发明的：
//
// ```text
// 分区标题  colorScheme.onSurface          = AppPalette.foreground
//                                            深色 #FAFAFA（≈ 旧 Colors.white）
//                                            浅色 #1E2028（LightTokens.textPrimary）
// 注释      colorScheme.onSurfaceVariant   = AppPalette.mutedForeground
//                                            深色 #A1A1A1（旧 white38 对深底合成 ≈ #676767）
//                                            浅色 #60626B（LightTokens.textSecondary）
// 分隔线    colorScheme.outlineVariant     = 深色 #222222（= 旧 border「白 10%」的实色合成）
//                                            浅色 #DFE1E8（LightTokens.divider）
// ```
//
// ⚠️ 角色的选择有**现成门禁**兜底，不是拍的：
// `test/theme_regression_test.dart` ③ 组钉着 onSurface / onSurfaceVariant
// 对背景 ≥ 4.5:1，且「次要文字不许等于正文」（层级必须存在）；
// `test/theme_tokens_test.dart` 钉着「不许硬编码单一色，必须按主题分支」。
//
// # 视觉等价的依据（换过去为什么不变样）
//
// **几何是逐像素不变的** —— 本文件里每一层的 widget 结构、`Sp.*` 间距、
// `FontSizes.*` 字号、`Divider(height: 1)` 都与改前那三份**逐字相同**，
// 只是把 `const TextStyle(color: 写死的白)` 换成了按主题取的角色色：
//
// ```text
// 深色主题  主标题 #FAFAFA  vs 旧 Colors.white      —— 同一档，肉眼不可分
//           分隔线 #222222  vs 旧 white24@#14161C（合成 ≈ #4A4A4F）—— 见下方注
//           注释   #A1A1A1  vs 旧 white38@#14161C（合成 ≈ #676767）
//                  ⇒ 旧值实测仅 3.50:1，**本就不达标**；新值 7.66:1
// 浅色主题  三者全部从「看不见」变成可见（这是本次的目的，不是回归）
// ```
//
// ★ 也就是说：**几何零差异；深色下标题同档、分隔线同族、注释被有意提亮**
//   （旧 `Colors.white38` 对深色底只有 3.50:1，是读不清的值 —— 提亮是
//   修缺陷，不是改设计；这一点在 `theme_bridge.dart` 的注释里也记着）。
//   浅色主题下的颜色变化本身就是任务要求（改前在那里是隐形的）。
//
// # 禁止 `package:flutter/material.dart`
//
// 项目用拆包后的 `material_ui`（见 `test/material_split_test.dart`）——
// 两套 Material 的 `Theme` 是**不同的 InheritedWidget**，混用会静默拿到
// 亮色兜底主题。本文件只 import `package:material_ui/material_ui.dart`。

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// 三种分区件的形态标签。
///
/// 用一个私有枚举而不是三个 bool：调用点只能落在**一种**形态上，
/// 不存在「既当标题又当分隔线」的非法组合。
enum _SectionKind { title, gap, divider }

/// 弹窗分区的三件套：**分区标题** / **分组留白** / **分组分隔线**。
///
/// 用法（三个命名构造一一对应改前的三个私有方法）：
///
/// ```dart
/// AppDialogSection.title('状态')                          // ← 原 _sectionTitle('状态')
/// AppDialogSection.title('搜索视频', note: '按关键词找')   // ← 原 _sectionTitle(..., note: ...)
/// AppDialogSection.gap()                                  // ← 原 _gap()
/// AppDialogSection.divider()                              // ← 原 _divider()
/// ```
///
/// # 为什么是「一个类 + 三个命名构造」而不是三个类
///
/// 这三件套永远一起出现在同一个 `Column` 里（标题 / 留白 / 分隔线），
/// 一个名字能让人在调用点一眼认出「这是分区件」，`import` 也只有一行。
///
/// ⚠️ 三种形态**不共用任何尺寸参数**：标题的 `bottom: Sp.x3`、
///    留白的 `Sp.x3`、分隔线的 `vertical: Sp.x4` 都是各自形态的固有几何，
///    与改前逐字相同 —— 暴露成参数反而给了「换个值试试」的口子，
///    而这三个值是几个弹窗对齐过的结果。
class AppDialogSection extends StatelessWidget {
  /// 分区标题 —— 主标题 + 可选注释。
  ///
  /// 对应改前的 `_sectionTitle(String text, {String? note})`。
  ///
  /// [title] 主标题，`FontSizes.base` + `FontWeights.semibold`，
  ///        取色 `colorScheme.onSurface`（改前是写死的 `Colors.white`）。
  ///
  /// [note] 可选注释，跟在主标题**同一行**的右侧，`FontSizes.cap`，
  ///        取色 `colorScheme.onSurfaceVariant`（改前是写死的
  ///        `Colors.white38` / `DanmakuTextColors.muted`）。
  ///        传 `null`（默认）时**整块不渲染** —— 连那 8px 的 `Sp.x2`
  ///        间隔也不占位，与改前的 `if (note != null)` 行为一致。
  ///
  /// ⚠️ 注释是 `Flexible(fit: loose)`，不是 `Expanded`：一行放不下时
  ///    注释自己折行，而**不**去挤压主标题。这正是改前的行为
  ///    （弹幕面板的 `_sectionTitle('数据源', note: widget.state.sourceLine)`
  ///    注释会很长，靠的就是这条）。
  const AppDialogSection.title(this.title, {super.key, this.note})
      : _kind = _SectionKind.title;

  /// 分组留白 —— 纯留白，不画线。
  ///
  /// 对应 `danmaku_settings_dialog.dart:868` 的 `_gap()`
  /// （`SizedBox(height: Sp.x3)`）。
  ///
  /// # 什么时候用留白、什么时候用分隔线
  ///
  /// 弹幕设置面板 2026-10-16 的结论（Owner：「弹幕设置这里非常的丑」）：
  /// 那里原本有 **7 条** `_divider`，横线贯穿整页 ⇒ 像表格、视觉噪音大。
  /// 改成**留白 + 分组卡片底色**之后，「有几组」靠块区分，一眼可数。
  ///
  /// ```text
  /// 改前：标题 + 内容 + ─────────────── + 标题 + 内容 …   （7 条横线）
  /// 改后：┌ 标题 ┐  ┌ 标题 ┐                            （靠块区分）
  ///       │ 内容 │  │ 内容 │
  ///       └──────┘  └──────┘
  /// ```
  ///
  /// ⇒ 判据：**内容自带底色/边界**（卡片、描边、分组容器）用 [gap]；
  ///   **一整条连续内容**（bili 导入、播放设置那种平铺表单）用 [divider]。
  ///   两者混用会让「分组」的语义自相矛盾。
  const AppDialogSection.gap({super.key})
      : title = '',
        note = null,
        _kind = _SectionKind.gap;

  /// 分组分隔线 —— 一条横线 + 上下各 `Sp.x4` 间距。
  ///
  /// 对应改前的 `_divider()`：
  /// `Padding(vertical: Sp.x4) > Divider(height: 1, color: Colors.white24)`。
  ///
  /// 颜色改取 `colorScheme.outlineVariant`（= 深色 #222222 / 浅色 #DFE1E8），
  /// 改前写死的 `Colors.white24` 在浅色主题下是白线压白底 ⇒ 看不见。
  ///
  /// ⚠️ `Divider(height: 1)` 是**总高度 1**（不是线的粗细），粗细走
  ///    `DividerThemeData.thickness`（本仓库在 `theme_bridge.dart` 里
  ///    全局给了 1）。改前改后是同一个 widget、同一份主题，故像素不变。
  ///
  /// ⚠️ 只传 `color`，**不**传 `thickness` —— 传了就绕过了全局
  ///    `dividerTheme`，以后调全局线宽会对这一处失效。
  const AppDialogSection.divider({super.key})
      : title = '',
        note = null,
        _kind = _SectionKind.divider;

  /// 主标题文本。只有 [AppDialogSection.title] 会用到；
  /// 另外两个构造给它空串（那时它根本不参与渲染）。
  final String title;

  /// 可选注释。见 [AppDialogSection.title] 的参数说明。
  final String? note;

  final _SectionKind _kind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    switch (_kind) {
      case _SectionKind.title:
        // ⚠️ 先落成局部变量再判空：`note` 是**公开字段**，Dart 只对
        //    私有 final 字段做类型提升 ⇒ 直接写 `if (note != null)` 之后
        //    在 `Flexible` 里仍要写 `note!`。局部变量可提升，读起来也干净。
        final note = this.note;
        return Padding(
          // 与改前逐字一致：标题下方 Sp.x3 是「标题属于下面那一组」的间距。
          padding: const EdgeInsets.only(bottom: Sp.x3),
          child: Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  // 深色 #FAFAFA / 浅色 #1E2028 —— 改前是写死的 Colors.white
                  color: colors.onSurface,
                  fontSize: FontSizes.base,
                  fontWeight: FontWeights.semibold,
                ),
              ),
              if (note != null) ...[
                const SizedBox(width: Sp.x2),
                Flexible(
                  child: Text(
                    note,
                    style: TextStyle(
                      // 深色 #A1A1A1 / 浅色 #60626B —— 改前是 Colors.white38
                      color: colors.onSurfaceVariant,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );

      case _SectionKind.gap:
        return const SizedBox(height: Sp.x3);

      case _SectionKind.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.x4),
          child: Divider(height: 1, color: colors.outlineVariant),
        );
    }
  }
}
