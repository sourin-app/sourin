// ═══════════════════════════════════════════════════════════════════════
//  玻璃对话框 —— 取代 Material 的 AlertDialog（仅"确认框"形态）
// ═══════════════════════════════════════════════════════════════════════
//
// # 它是什么、不是什么
// ```text
// ✅ 一个**纯 Widget**，只画"标题 + 正文 + 两个按钮"的玻璃确认框
// ❌ **不自带 show()** —— 弹出必须由调用方用 `showAppDialog` 装
// ```
//
// # ★★★ 为什么不自带 show()（这一条是本次设计的关键）
// ```text
// 本仓有唯一对话框入口：lib/ui/widgets/overlay_motion.dart:311 `showAppDialog`。
// 它的文件里逐字写着（:282-284）：
//   「lib/ 里除本文件与两个真机探针外，不许再出现裸 `showDialog(`」
//   「★ 不许为了"让 showDialog 退场更快"去自建 RawDialogRoute ——
//     那会丢掉 _FullWindowDialogWrapper / _DialogPopScope 等 3.47 才有的对话框语义」
// ⇒ 它承载了 task-104 的退场动效（animationStyle）。
// ```
// `liquid_glass_widgets` 的 `GlassDialog.show()` 内部直接调
// `showCupertinoDialog`（glass_dialog.dart:272）⇒ **绕过** showAppDialog，
// 会丢掉 animationStyle、并换用 CupertinoDialogRoute。
// ⇒ 所以本组件**只做壳**，弹出交给 showAppDialog。
//
// # 为什么不复用已有的 AppDialogShell（我在实现前查过）
// ```text
// lib/ui/widgets/app_dialog_shell.dart 已有 glass:true 档、scrollable、maxHeight，
// 看起来正合适。但实测：
//   showAppDialog(builder: AppDialogShell(...)) ⇒ 它的占位是 **800×600 全屏**
//   （.probe/probe_e4_shell2_test.dart）
// 根因：它自带一个铺满全屏的 scrim（:340 `GestureDetector(onTap: closeEnabled ? onClose : null)`
//   + :472 `_scrim` 的 `ColoredBox`）。
// ⇒ 它是**全屏面板**形态，不是对话框形态：
//   ① 会盖住 showDialog 自己的 barrier
//   ② 它自己的 onTap 关窗会**绕过** barrierDismissible
//      （实测：传 barrierDismissible:false 后点外面仍然关了 ⇒ 语义失效）
// ⇒ 不能复用。本组件只画"卡片"，不画 scrim —— scrim 交给路由层（barrier）。
// ```
//
// # 与 AlertDialog 的对位
// ```text
// AlertDialog(title:, content:, actions:)  →  AppGlassDialog(title:, content:, actions:)
// 弹出仍是 showAppDialog<bool>(...)，返回 Future<bool?>，与现在逐字一致。
// ```

import 'package:flutter/widgets.dart';
// 只为 GlassContainer（玻璃材质）。TODO(M5)：玻璃层若也自建则删本 import。
// ignore: depend_on_referenced_packages
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer, LiquidRoundedSuperellipse;

import '../../ui/theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'app_text_button.dart';

/// 玻璃确认对话框 —— 取代 `AlertDialog`（确认框形态）。
///
/// ⚠️ **不自带 show()**：请用
/// `showAppDialog<T>(context: ..., builder: (ctx) => AppGlassDialog(...))`。
class AppGlassDialog extends StatelessWidget {
  const AppGlassDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.maxWidth = 380,
    this.maxHeight = 420,
  });

  /// 标题（对应 `AlertDialog.title`）
  final String title;

  /// 正文（对应 `AlertDialog.content`）
  final Widget content;

  /// 底部按钮行（对应 `AlertDialog.actions`）
  final Widget actions;

  /// 卡片最大宽度。默认 380 —— 比 Material 的 280 宽一点，
  /// 因为这 3 个确认框的正文是**两行中文**，280 会折得很碎。
  final double maxWidth;

  /// 内容区最大高度。超出后**内部滚动**。
  ///
  /// # 为什么要这个（Lead 第 4 步硬要求）
  /// ```text
  /// 实测：`AlertDialog` 与 `GlassDialog` 在长内容下**都会溢出**
  ///   （.probe/probe_e4_overflow_test.dart：两者 Scrollable 都是 0、
  ///    都有 `RenderFlex overflowed` 异常）。
  /// ⇒ 新建组件时**顺手做对**，不留"将来塞长内容就坏"的坑。
  /// ```
  /// 现在这 3 个确认框正文都很短，但**没有任何机制保证以后也是**。
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    /*
     * TODO(M4): AppThemeScope 接上后，把 resolvedOf 改回 AppTheme.of。
     * 理由见 lib/design/theme/app_theme.dart 的 resolvedOf 注释。
     */
    final t = AppTheme.resolvedOf(context);
    final AppSemanticColors c = t.colors;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: GlassContainer(
        /*
         * 圆角 20 —— 与本仓其它面板（AppDialogShell 的 LiquidRoundedRectangle(20)）
         * 保持同档，避免"弹窗圆角两套"。
         */
        shape: const LiquidRoundedSuperellipse(borderRadius: 20),
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.onSurface,
                  fontFamily: t.typeface.fontFamily,
                  fontFamilyFallback: t.typeface.fontFamilyFallback,
                  fontSize: t.typeface.md,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  // ⚠️ 显式清零：DefaultTextStyle.merge 会继承 TextTheme 的
                  //    letterSpacing（CJK 0.25）⇒ 标题会被拉宽（第 3 步踩过）
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 10),
              /*
               * ★ 内容区滚动（Lead 硬要求）
               *
               * `Flexible` + `SingleChildScrollView`：
               *   Flexible 让它在 Column 里**可被压缩**，
               *   ScrollView 让压缩后内容**可滚**而不是溢出。
               * ⚠️ 不能只写 SingleChildScrollView 不写 Flexible ——
               *    Column(mainAxisSize.min) 下它仍会按内容全高撑开。
               */
              Flexible(
                child: SingleChildScrollView(
                  child: DefaultTextStyle(
                    style: TextStyle(
                      color: c.onSurfaceVariant,
                      fontFamily: t.typeface.fontFamily,
                      fontFamilyFallback: t.typeface.fontFamilyFallback,
                      fontSize: t.typeface.sm,
                      height: 1.45,
                      letterSpacing: 0,
                    ),
                    textAlign: TextAlign.center,
                    child: content,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              /*
               * 按钮行：右对齐，与 Material AlertDialog 的动作区一致。
               * 用第 1 步建好的 `AppTextButton`（自建、零 Material）。
               */
              Align(
                alignment: Alignment.centerRight,
                child: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 便捷构造：一对「取消 / 确认」按钮。
///
/// 三个确认框都是这个形态（取消 pop(false)、确认 pop(true)），
/// 抽出来是为了让调用点保持和 `AlertDialog` 一样短。
class AppGlassDialogActions extends StatelessWidget {
  const AppGlassDialogActions({
    super.key,
    required this.onCancel,
    required this.onConfirm,
    required this.confirmLabel,
    this.cancelLabel = '取消',
    this.confirmIsDestructive = true,
  });

  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final String confirmLabel;
  final String cancelLabel;

  /// 确认按钮是否用错误色（删除类操作为 true）。
  final bool confirmIsDestructive;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.resolvedOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppTextButton(onPressed: onCancel, child: Text(cancelLabel)),
        const SizedBox(width: 4),
        AppTextButton(
          onPressed: onConfirm,
          foregroundColor:
              confirmIsDestructive ? t.colors.error : t.colors.primary,
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
