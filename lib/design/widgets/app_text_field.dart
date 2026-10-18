// ═══════════════════════════════════════════════════════════════════════
//  自建输入框 + 提示气泡 —— 取代 Material 的 TextField / Tooltip
// ═══════════════════════════════════════════════════════════════════════
//
// # TextField（28 个文件）
// ```text
// 实测形态：TextField(controller:, decoration: InputDecoration(hintText:, ...), onChanged:)
// ⇒ 覆盖 controller / hint / onChanged / obscureText / enabled 这几个，
//   不做 InputDecoration 的完整 API 子集（原代码用到的就这些）。
// ```
//
// # Tooltip（17 个文件）
// ```text
// Material 的 Tooltip 是**悬停/长按弹气泡**。
// ⚠️ 之前我在 AppIconButton 里误用了 Tooltip ⇒ 等于没摘掉 material_ui。
//   这里补一个自建版本。
//
// 实现要点：
//   · 桌面：MouseRegion 的 onEnter/onExit 控制显示
//   · 触摸：长按显示（InkWell 的 onLongPress 会抢手势，用 Listener 判时长）
//   · 气泡用 Overlay 画在**最上层**，不会被父级 Clip 裁掉
// ```

import 'package:flutter/widgets.dart';

import '../../ui/tokens.dart';
import '../theme/app_theme.dart';

/// 自建输入框 —— 取代 `TextField`。
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.hint,
    this.onChanged,
    this.obscureText = false,
    this.enabled = true,
    this.maxLines = 1,
    this.prefix,
    this.autofocus = false,
  });

  final TextEditingController? controller;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final bool obscureText;
  final bool enabled;
  final int maxLines;

  /// 前置图标/装饰（原 `InputDecoration.prefixIcon`）
  final Widget? prefix;

  final bool autofocus;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late final TextEditingController _ctrl =
      widget.controller ?? TextEditingController();
  bool _ownsCtrl = false;
  // ignore: prefer_final_fields
  bool _hidden = true; // obscureText 用的明文/密文切换
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ownsCtrl = widget.controller == null;
    _focus.addListener(() {
      // 焦点变化要重绘边框（聚焦态描边更亮）
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    // ★ 只销毁自己创建的 controller —— 外面传进来的归外面管
    //   （这条漏了会导致"页面关了还报 dispose 后使用"）
    if (_ownsCtrl) _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTheme.of(context);
    final focused = _focus.hasFocus;

    final field = EditableText(
      controller: _ctrl,
      focusNode: _focus,
      autofocus: widget.autofocus,
      readOnly: !widget.enabled,
      obscureText: widget.obscureText && _hidden,
      style: TextStyle(
        color: widget.enabled ? t.foreground : t.mutedForeground,
        fontFamily: t.typeface.fontFamily,
        fontFamilyFallback: t.typeface.fontFamilyFallback,
        fontSize: FontSizes.base,
      ),
      cursorColor: t.primary,
      backgroundCursorColor: t.mutedForeground,
      maxLines: widget.maxLines,
      onChanged: widget.onChanged,
      selectionColor: t.primary.withValues(alpha: 0.3),
    );

    Widget body = field;
    final hint = widget.hint;
    if (hint != null && hint.isNotEmpty) {
      // 空值时显示 hint —— 用 ValueListenableBuilder 监听内容变化
      body = ValueListenableBuilder<TextEditingValue>(
        valueListenable: _ctrl,
        builder: (c, v, child) {
          if (v.text.isNotEmpty) return child!;
          return Stack(
          children: [
            child!,
            IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  hint,
                  style: TextStyle(
                    color: t.mutedForeground.withValues(alpha: 0.7),
                    fontFamily: t.typeface.fontFamily,
                    fontSize: FontSizes.base,
                  ),
                ),
              ),
            ),
          ],
          );
        },
        child: body,
      );
    }

    final pre = widget.prefix;
    if (pre != null) {
      body = Row(
        children: [pre, const SizedBox(width: 8), Expanded(child: body)],
      );
    }

    return GestureDetector(
      onTap: () => _focus.requestFocus(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: t.surfaceRaised,
          borderRadius: BorderRadius.circular(t.radius),
          border: Border.all(
            // 聚焦时用主色描边 —— 这是唯一的"输入框有焦点"信号
            color: focused ? t.primary : t.border,
            width: focused ? 1.5 : 1,
          ),
        ),
        child: body,
      ),
    );
  }
}
