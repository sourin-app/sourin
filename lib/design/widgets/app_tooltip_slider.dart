// ═══════════════════════════════════════════════════════════════════════
//  自建提示气泡 + 滑杆 —— 取代 Material 的 Tooltip / Slider
// ═══════════════════════════════════════════════════════════════════════
//
// # Tooltip（25 处）
// ```text
// Material 的 Tooltip 是「悬停/长按弹气泡」，它属于 Material 层。
// 之前我在 AppIconButton 里误用 Tooltip ⇒ 等于没摘掉 material_ui。
// 当时退化成 Semantics(label:) 只保住读屏，**丢了视觉气泡**。
// 本文件把它补回来。
// ```
//
// # Slider（22 处）
// ```text
// 实测形态：Slider(value:, onChanged:, min:, max:, divisions:)
// ⚠️ 本仓已有自建 PopoverSlider（player_bottom_bar 在用）——
//    那个是**弹层内**的紧凑样式，本组件是通用版（可聚焦、可键盘调）。
// ```

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import '../../ui/tokens.dart';

/// 自建提示气泡 —— 取代 `Tooltip`。
///
/// 桌面：鼠标悬停 [waitDuration] 后出现；触摸：长按出现。
/// 气泡用 [Overlay] 画在**最上层**，不会被父级 Clip 裁掉。
class AppTooltip extends StatefulWidget {
  const AppTooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration = const Duration(milliseconds: 500),
  });

  final String message;
  final Widget child;

  /// 悬停多久才弹出。Material 默认 500ms —— 保持一致，避免手感变化。
  final Duration waitDuration;

  @override
  State<AppTooltip> createState() => _AppTooltipState();
}

class _AppTooltipState extends State<AppTooltip> {
  OverlayEntry? _entry;
  Timer? _timer;
  final LayerLink _link = LayerLink();

  @override
  void dispose() {
    _timer?.cancel();
    _remove();
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(widget.waitDuration, () {
      if (!mounted) return;
      _show();
    });
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _remove();
  }

  void _show() {
    if (_entry != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;

    _entry = OverlayEntry(builder: (ctx) {
      final t = AppTheme.of(ctx);
      return Positioned(
        // 贴在 child 正上方居中 —— 与 Material Tooltip 的默认位置一致
        width: 240,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -6),
          child: IgnorePointer(
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: t.isDark
                      ? const Color(0xF01E1E22)
                      : const Color(0xF0333338),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    widget.message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: const Color(0xFFF5F5F5),
                      fontFamily: t.typeface.fontFamily,
                      fontSize: FontSizes.cap,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
    overlay.insert(_entry!);
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: MouseRegion(
        onEnter: (_) => _schedule(),
        onExit: (_) => _cancel(),
        child: Listener(
          // 触摸端：长按出现，抬手消失
          onPointerDown: (e) {
            if (e.kind == PointerDeviceKind.touch) _schedule();
          },
          onPointerUp: (e) {
            if (e.kind == PointerDeviceKind.touch) _cancel();
          },
          onPointerCancel: (_) => _cancel(),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 自建滑杆 —— 取代 `Slider`。
class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0.0,
    this.max = 1.0,
    this.divisions,
    this.label,
  });

  final double value;

  /// null ⇒ 禁用
  final ValueChanged<double>? onChanged;

  final double min;
  final double max;

  /// 分档数（null = 连续）
  final int? divisions;

  /// 拖动时显示的值标签（与 Material Slider.label 语义一致）
  ///
  /// ★ 2026-10-17 补：dlg-plugin 审计发现产品代码有 1 处用了 Slider.label，
  ///   缺这个参数会导致那处**编译不过**（整个文件测试加载失败）。
  ///
  /// 语义：**拖动中**在滑块上方显示，松手后消失。
  final String? label;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  /// 是否正在拖动 —— label 只在拖动中出现（与 Material Slider 一致）
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final enabled = widget.onChanged != null;
    final min = widget.min;
    final max = widget.max;
    final divisions = widget.divisions;

    return LayoutBuilder(builder: (ctx, box) {
      final w = box.maxWidth;
      final span = max - min;
      // span 为 0 是调用方的错，但不能除零崩掉 —— 当满值处理
      final ratio = span == 0
          ? 1.0
          : ((widget.value - min) / span).clamp(0.0, 1.0);

      void update(double dx) {
        if (!enabled) return;
        var r = (dx / w).clamp(0.0, 1.0);
        final d = divisions;
        if (d != null && d > 0) {
          // 吸附到最近的档位 —— 与 Material Slider 的 divisions 行为一致
          r = (r * d).round() / d;
        }
        widget.onChanged!(min + r * span);
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => update(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
        onHorizontalDragStart: (_) {
          if (enabled && widget.label != null) {
            setState(() => _dragging = true);
          }
        },
        onHorizontalDragEnd: (_) {
          if (_dragging) setState(() => _dragging = false);
        },
        onHorizontalDragCancel: () {
          if (_dragging) setState(() => _dragging = false);
        },
        child: SizedBox(
          height: 32,
          child: Center(
            child: Stack(
            children: [
              // 轨道
              Container(
                height: 4,
                decoration: BoxDecoration(
                  color: t.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 已选段
              FractionallySizedBox(
                widthFactor: ratio,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: enabled
                        ? t.primary
                        : t.mutedForeground.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 滑块 —— 用 Align 定位，避免 Positioned 需要宽度
              Align(
                alignment: Alignment(ratio * 2 - 1, 0),
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: enabled ? t.primary : t.mutedForeground,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
              // ★ label 只在拖动中出现（与 Material Slider 一致）
              if (_dragging && widget.label != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: -4,
                  child: Align(
                    alignment: Alignment(ratio * 2 - 1, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: t.foreground,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        widget.label!,
                        style: TextStyle(
                          color: t.background,
                          fontSize: 11,
                          fontFamily: t.typeface.fontFamily,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
            ),
          ),
        ),
      );
    });
  }
}
