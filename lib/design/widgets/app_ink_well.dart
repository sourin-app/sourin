// ═══════════════════════════════════════════════════════════════════════
//  自建点击态容器 —— 取代 Material 的 InkWell（Owner 第 4/8/9 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不能直接用现成的 PressFeedback
// ```text
// lib/ui/widgets/press_feedback.dart 的 PressFeedback **只做按下缩放**，
// 它自己写着：「不消费手势 —— 外层原有的 onTap / InkWell 照常工作」。
// ⇒ 它是"叠加的视觉反馈"，不是"可点击容器"，替代不了 InkWell。
// ```
//
// # InkWell 在本仓的用法非常统一（实测 49 个文件）
// ```text
// 绝大多数只有三个参数：
//   InkWell(onTap: ..., borderRadius: ..., child: ...)
// ⇒ 只覆盖这一种形态，不做 InkWell 的完整 API 子集。
// ```
//
// # 行为对齐
// ```text
// ① 只有 onTap != null 才响应点击（null = 禁用态，不抢手势）
// ② 点击区域 = child 的实际布局范围
// ③ tap 后能收到按下视觉反馈
// ④ 不新增长按/右键行为
// ⑤ 走 PressFeedback 已有的 Reduce Motion 机制
// ```
//
// # ⚠️ 与 InkWell 的一个**有意差异**
// ```text
// InkWell 的水波画在**祖先 Material** 上（所以必须在 Material 里才生效）；
// 我们自绘高亮，画在自己身上 ⇒ **不再需要祖先 Material**。
// 这正是摘掉 material_ui 的关键一步。
// ```

import 'package:flutter/widgets.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets/press_feedback.dart';

/// 自建可点击容器 —— 取代 `InkWell`。
class AppInkWell extends StatefulWidget {
  const AppInkWell({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius,
    this.enabled = true,
    this.onFocusChange,
    this.focusNode,
  });

  final Widget child;

  /// 为 null ⇒ 禁用态：不响应点击，也不显示按下反馈
  /// （与 `InkWell(onTap: null)` 语义一致）。
  final VoidCallback? onTap;

  /*
   * ★ 2026-10-17 新增：焦点变化回调
   *
   * # 为什么需要
   * ```text
   * Material 的 InkWell 有 onFocusChange，episode_strip 用了 **4 处**：
   *   遥控器/TV 方向键移到某一集时，把那一集画成品牌色高亮。
   * 这不是"水波反馈"，是**焦点可见性**，属于无障碍必需。
   * ```
   *
   * ⇒ 没有这个回调，迁过去会丢掉遥控器用户"看得见选中哪一集"的能力。
   *   所以必须先补能力，再迁移。
   */
  final ValueChanged<bool>? onFocusChange;

  /// 外部可注入的焦点节点（不传则内部自建）。
  ///
  /// ⚠️ 为什么不传就取不到：`Focus` 内部创建的 node 从外部拿不到，
  ///    测试里 `widget.focusNode` 是 null ⇒ 无法 requestFocus ⇒
  ///    onFocusChange 永远不会触发。
  ///
  /// ⇒ 需要**主动控制焦点**的场景（遥控器导航、测试）必须传入。
  final FocusNode? focusNode;

  /// 高亮区域圆角。null ⇒ 直角。
  final BorderRadius? borderRadius;

  /// 额外开关（在 [onTap] 非空的前提下再关掉反馈用）
  final bool enabled;

  bool get isActive => onTap != null && enabled;

  @override
  State<AppInkWell> createState() => _AppInkWellState();
}

class _AppInkWellState extends State<AppInkWell> {
  bool _down = false;

  void _setDown(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
  }

  void _handleTap() {
    final cb = widget.onTap;
    if (cb == null || !widget.enabled) return;
    cb();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) return widget.child;

    /*
     * ★★★ 2026-10-17（player-batch 实测发现）—— 必须**自带 Focus 节点**
     *
     * # 缺口现场
     * ```text
     * InkWell 内部结构：Focus(child: MouseRegion(child: ...))
     * ⇒ 在 InkWell 的 child 子树里 Focus.of(ctx) 拿到的**正是 InkWell 自己那个节点**
     *
     * 本组件第一版没有 Focus ⇒ 换成 AppInkWell 后：
     *   Focus.of(内部 ctx) 会拿到**祖先**节点 ⇒ 焦点环挂错地方
     *
     * 真实受害处：lib/ui/widgets/settings_kit.dart:782
     *   child: Builder(builder: (ctx) => _SettingsFocusRing(node: Focus.of(ctx), ...))
     * 那个焦点环正是「业主反馈⑧：返回后这一行还是灰的」的修复零件。
     * ⇒ 换过来就等于把已修好的缺陷重新弄坏。
     * ```
     *
     * ⇒ 现在补上：自带一个 Focus 节点，且**必须**是 canRequestFocus=false 的
     *   可聚焦容器吗？不是 —— 要与 InkWell 对齐：InkWell 的节点**可聚焦**，
     *   键盘 Tab 能停在按钮上。所以这里也用默认（可聚焦）。
     *
     * ⚠️ 顺序很重要：Focus 必须在 GestureDetector **里面**，
     *    这样 Focus.of 在 child 子树里才能拿到它（与 InkWell 结构一致）。
     */
    return Focus(
      canRequestFocus: true,
      focusNode: widget.focusNode,
      onFocusChange: widget.onFocusChange,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) => _setDown(false),
        onTapCancel: () => _setDown(false),
        child: PressFeedback(
        child: Stack(
          children: [
            widget.child,
            // 高亮层：按下时盖一层极淡黑，抬起归零。
            // 自绘 ⇒ 不需要祖先 Material（InkWell 水波则需要）。
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: Motion.press,
                  decoration: BoxDecoration(
                    borderRadius: widget.borderRadius,
                    color: _down
                        ? const Color(0x14000000)
                        : const Color(0x00000000),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
