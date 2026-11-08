// Application compatibility layer backed by real flutter_miuix controls.
// Layout and callbacks stay with each feature; visual controls live in Miuix.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart'
    show kLongPressTimeout, PointerDeviceKind;
import 'package:material_ui/material_ui.dart'
    hide
        TextButton,
        OutlinedButton,
        FilledButton,
        IconButton,
        TextField,
        TextFormField,
        Slider,
        Switch,
        SwitchListTile,
        Checkbox,
        CheckboxListTile,
        ChoiceChip,
        FilterChip,
        ListTile,
        InkWell,
        RefreshIndicator,
        CircularProgressIndicator,
        Divider;
import 'package:material_ui/material_ui.dart' as material;
import 'package:flutter_miuix/miuix.dart' as miuix;

import '../tokens.dart';
import 'motion_prefs.dart';
import '../theme/miuix_framework_bridge.dart';

class RefreshIndicator extends StatefulWidget {
  const RefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<RefreshIndicator> createState() => _RefreshIndicatorState();
}

class _RefreshIndicatorState extends State<RefreshIndicator> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => miuix.MiuixPullToRefresh(
    isRefreshing: _refreshing,
    onRefresh: () => unawaited(_refresh()),
    refreshTexts: const ['下拉刷新', '松开刷新', '正在刷新…', '刷新完成'],
    child: widget.child,
  );
}

double _cornerRadius(
  BuildContext context,
  OutlinedBorder? shape,
  double fallback,
) {
  if (shape is RoundedRectangleBorder)
    return shape.borderRadius.resolve(Directionality.of(context)).topLeft.x;
  if (shape is StadiumBorder || shape is CircleBorder) return 999;
  return fallback;
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.onPressed,
    this.child,
    this.icon,
    this.label,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.onFocusChange,
    this.onHover,
    this.onLongPress,
    this.primary = false,
  });
  final VoidCallback? onPressed, onLongPress;
  final Widget? child, icon, label;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus, primary;
  final ValueChanged<bool>? onFocusChange, onHover;
  @override
  Widget build(BuildContext context) {
    final states = <WidgetState>{if (onPressed == null) WidgetState.disabled};
    final defaults = primary
        ? miuix.MiuixButtonDefaults.buttonColorsPrimary(context)
        : miuix.MiuixButtonDefaults.buttonColors(context);
    final fg =
        style?.foregroundColor?.resolve(states) ??
        (onPressed == null
            ? defaults.disabledContentColor
            : defaults.contentColor);
    final bg = style?.backgroundColor?.resolve(states) ?? defaults.color;
    final size = style?.minimumSize?.resolve(states);
    final radius = _cornerRadius(
      context,
      style?.shape?.resolve(states),
      miuix.MiuixButtonDefaults.cornerRadius,
    );
    final padding =
        style?.padding?.resolve(states) ??
        const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2);
    Widget body = miuix.MiuixButton(
      onPressed: onPressed,
      enabled: onPressed != null,
      cornerRadius: radius,
      minWidth: size?.width ?? 58,
      minHeight: size?.height ?? 40,
      insideMargin: padding,
      colors: miuix.MiuixButtonColors(
        color: bg,
        disabledColor:
            style?.backgroundColor?.resolve({WidgetState.disabled}) ??
            defaults.disabledColor,
        contentColor: fg,
        disabledContentColor:
            style?.foregroundColor?.resolve({WidgetState.disabled}) ??
            defaults.disabledContentColor,
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: fg),
        child: DefaultTextStyle.merge(
          style: style?.textStyle?.resolve(states) ?? const TextStyle(),
          child:
              child ??
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[icon!, const SizedBox(width: Sp.x2)],
                  if (label != null) Flexible(child: label!),
                ],
              ),
        ),
      ),
    );
    final side = style?.side?.resolve(states);
    if (side != null && side.style != BorderStyle.none)
      body = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(
          shape: miuix.MiuixSquircleBorder(cornerRadius: radius, side: side),
        ),
        child: body,
      );
    final maximum = style?.maximumSize?.resolve(states);
    if (maximum != null)
      body = ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maximum.width,
          maxHeight: maximum.height,
        ),
        child: body,
      );
    final fixed = style?.fixedSize?.resolve(states);
    if (fixed != null)
      body = SizedBox(
        width: fixed.width.isFinite ? fixed.width : null,
        height: fixed.height.isFinite ? fixed.height : null,
        child: body,
      );
    // Miuix's pressable exposes both an explicit tap and a gesture tap. Keep
    // the action role, label and focus on one accessible button.
    return MergeSemantics(
      child: _ControlFocus(
        onActivate: onPressed,
        focusNode: focusNode,
        autofocus: autofocus,
        onFocusChange: onFocusChange,
        onHover: onHover,
        onLongPress: onLongPress,
        child: body,
      ),
    );
  }
}

class _ControlFocus extends StatefulWidget {
  const _ControlFocus({
    required this.child,
    this.onActivate,
    this.focusNode,
    this.autofocus = false,
    this.onFocusChange,
    this.onHover,
    this.onLongPress,
  });
  final Widget child;
  final VoidCallback? onActivate, onLongPress;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange, onHover;
  @override
  State<_ControlFocus> createState() => _ControlFocusState();
}

class _ControlFocusState extends State<_ControlFocus> {
  bool highlight = false;
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    focusNode: widget.focusNode,
    autofocus: widget.autofocus,
    enabled: widget.onActivate != null,
    onFocusChange: widget.onFocusChange,
    onShowHoverHighlight: widget.onHover,
    onShowFocusHighlight: (v) {
      if (highlight != v) setState(() => highlight = v);
    },
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    },
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onActivate?.call();
          return null;
        },
      ),
    },
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: Radii.rMd,
        border: highlight
            ? Border.all(
                color: miuix.MiuixTheme.of(context).colors.primary,
                width: 2,
              )
            : null,
      ),
      child: GestureDetector(
        onLongPress: widget.onLongPress,
        child: ExcludeFocus(child: widget.child),
      ),
    ),
  );
}

class TextButton extends _ActionButton {
  const TextButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.style,
    super.focusNode,
    super.autofocus,
    super.onFocusChange,
    super.onHover,
    super.onLongPress,
  }) : super(primary: false);
  const TextButton.icon({
    super.key,
    required super.onPressed,
    required super.icon,
    required super.label,
    super.style,
    super.focusNode,
    super.autofocus,
    super.onFocusChange,
    super.onHover,
    super.onLongPress,
  }) : super(primary: false);
  static ButtonStyle styleFrom({
    Color? foregroundColor,
    Color? backgroundColor,
    Color? disabledForegroundColor,
    Color? disabledBackgroundColor,
    Color? overlayColor,
    Color? shadowColor,
    Color? surfaceTintColor,
    double? elevation,
    TextStyle? textStyle,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    Size? fixedSize,
    Size? maximumSize,
    BorderSide? side,
    OutlinedBorder? shape,
    MouseCursor? enabledMouseCursor,
    MouseCursor? disabledMouseCursor,
    VisualDensity? visualDensity,
    MaterialTapTargetSize? tapTargetSize,
    Duration? animationDuration,
    bool? enableFeedback,
    AlignmentGeometry? alignment,
    double? iconSize,
    Color? iconColor,
  }) => material.TextButton.styleFrom(
    foregroundColor: foregroundColor,
    backgroundColor: backgroundColor,
    disabledForegroundColor: disabledForegroundColor,
    disabledBackgroundColor: disabledBackgroundColor,
    overlayColor: overlayColor,
    shadowColor: shadowColor,
    surfaceTintColor: surfaceTintColor,
    elevation: elevation,
    textStyle: textStyle,
    padding: padding,
    minimumSize: minimumSize,
    fixedSize: fixedSize,
    maximumSize: maximumSize,
    side: side,
    shape: shape,
    enabledMouseCursor: enabledMouseCursor,
    disabledMouseCursor: disabledMouseCursor,
    visualDensity: visualDensity,
    tapTargetSize: tapTargetSize,
    animationDuration: animationDuration,
    enableFeedback: enableFeedback,
    alignment: alignment,
    iconSize: iconSize,
    iconColor: iconColor,
  );
}

class OutlinedButton extends _ActionButton {
  const OutlinedButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.style,
    super.focusNode,
    super.autofocus,
    super.onFocusChange,
    super.onHover,
    super.onLongPress,
  }) : super(primary: false);
  const OutlinedButton.icon({
    super.key,
    required super.onPressed,
    required super.icon,
    required super.label,
    super.style,
    super.focusNode,
    super.autofocus,
    super.onFocusChange,
    super.onHover,
    super.onLongPress,
  }) : super(primary: false);
  static ButtonStyle styleFrom({
    Color? foregroundColor,
    Color? backgroundColor,
    Color? disabledForegroundColor,
    Color? disabledBackgroundColor,
    Color? overlayColor,
    Color? shadowColor,
    Color? surfaceTintColor,
    double? elevation,
    TextStyle? textStyle,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    Size? fixedSize,
    Size? maximumSize,
    BorderSide? side,
    OutlinedBorder? shape,
    MouseCursor? enabledMouseCursor,
    MouseCursor? disabledMouseCursor,
    VisualDensity? visualDensity,
    MaterialTapTargetSize? tapTargetSize,
    Duration? animationDuration,
    bool? enableFeedback,
    AlignmentGeometry? alignment,
    double? iconSize,
    Color? iconColor,
  }) => material.TextButton.styleFrom(
    foregroundColor: foregroundColor,
    backgroundColor: backgroundColor,
    disabledForegroundColor: disabledForegroundColor,
    disabledBackgroundColor: disabledBackgroundColor,
    overlayColor: overlayColor,
    shadowColor: shadowColor,
    surfaceTintColor: surfaceTintColor,
    elevation: elevation,
    textStyle: textStyle,
    padding: padding,
    minimumSize: minimumSize,
    fixedSize: fixedSize,
    maximumSize: maximumSize,
    side: side,
    shape: shape,
    enabledMouseCursor: enabledMouseCursor,
    disabledMouseCursor: disabledMouseCursor,
    visualDensity: visualDensity,
    tapTargetSize: tapTargetSize,
    animationDuration: animationDuration,
    enableFeedback: enableFeedback,
    alignment: alignment,
    iconSize: iconSize,
    iconColor: iconColor,
  );
}

class FilledButton extends _ActionButton {
  const FilledButton({
    super.key,
    required super.onPressed,
    required super.child,
    super.style,
    super.focusNode,
    super.autofocus,
    super.onFocusChange,
    super.onHover,
    super.onLongPress,
  }) : super(primary: true);
  const FilledButton.icon({
    super.key,
    required super.onPressed,
    required super.icon,
    required super.label,
    super.style,
    super.focusNode,
    super.autofocus,
    super.onFocusChange,
    super.onHover,
    super.onLongPress,
  }) : super(primary: true);
  const FilledButton.tonal({
    super.key,
    required super.onPressed,
    required super.child,
    super.style,
    super.focusNode,
    super.autofocus,
    super.onFocusChange,
    super.onHover,
    super.onLongPress,
  }) : super(primary: false);
  const FilledButton.tonalIcon({
    super.key,
    required super.onPressed,
    required super.icon,
    required super.label,
    super.style,
    super.focusNode,
    super.autofocus,
    super.onFocusChange,
    super.onHover,
    super.onLongPress,
  }) : super(primary: false);
  static ButtonStyle styleFrom({
    Color? foregroundColor,
    Color? backgroundColor,
    Color? disabledForegroundColor,
    Color? disabledBackgroundColor,
    Color? overlayColor,
    Color? shadowColor,
    Color? surfaceTintColor,
    double? elevation,
    TextStyle? textStyle,
    EdgeInsetsGeometry? padding,
    Size? minimumSize,
    Size? fixedSize,
    Size? maximumSize,
    BorderSide? side,
    OutlinedBorder? shape,
    MouseCursor? enabledMouseCursor,
    MouseCursor? disabledMouseCursor,
    VisualDensity? visualDensity,
    MaterialTapTargetSize? tapTargetSize,
    Duration? animationDuration,
    bool? enableFeedback,
    AlignmentGeometry? alignment,
    double? iconSize,
    Color? iconColor,
  }) => material.TextButton.styleFrom(
    foregroundColor: foregroundColor,
    backgroundColor: backgroundColor,
    disabledForegroundColor: disabledForegroundColor,
    disabledBackgroundColor: disabledBackgroundColor,
    overlayColor: overlayColor,
    shadowColor: shadowColor,
    surfaceTintColor: surfaceTintColor,
    elevation: elevation,
    textStyle: textStyle,
    padding: padding,
    minimumSize: minimumSize,
    fixedSize: fixedSize,
    maximumSize: maximumSize,
    side: side,
    shape: shape,
    enabledMouseCursor: enabledMouseCursor,
    disabledMouseCursor: disabledMouseCursor,
    visualDensity: visualDensity,
    tapTargetSize: tapTargetSize,
    animationDuration: animationDuration,
    enableFeedback: enableFeedback,
    alignment: alignment,
    iconSize: iconSize,
    iconColor: iconColor,
  );
}

class IconButton extends StatelessWidget {
  const IconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.iconSize = 24,
    this.color,
    this.disabledColor,
    this.padding = const EdgeInsets.all(8),
    this.constraints,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.visualDensity,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.alignment = Alignment.center,
    this.isSelected,
    this.selectedIcon,
    this.enableFeedback = true,
    this.filled = false,
  });
  const IconButton.filled({
    super.key,
    required this.onPressed,
    required this.icon,
    this.tooltip,
    this.iconSize = 24,
    this.color,
    this.disabledColor,
    this.padding = const EdgeInsets.all(8),
    this.constraints,
    this.style,
    this.focusNode,
    this.autofocus = false,
    this.visualDensity,
    this.hoverColor,
    this.highlightColor,
    this.splashColor,
    this.alignment = Alignment.center,
    this.isSelected,
    this.selectedIcon,
    this.enableFeedback = true,
  }) : filled = true;
  final VoidCallback? onPressed;
  final Widget icon;
  final String? tooltip;
  final double iconSize;
  final Color? color, disabledColor, hoverColor, highlightColor, splashColor;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;
  final ButtonStyle? style;
  final FocusNode? focusNode;
  final bool autofocus, enableFeedback, filled;
  final VisualDensity? visualDensity;
  final AlignmentGeometry alignment;
  final bool? isSelected;
  final Widget? selectedIcon;
  static ButtonStyle styleFrom({
    Color? foregroundColor,
    Color? backgroundColor,
    Color? hoverColor,
    Color? highlightColor,
    Size? minimumSize,
    EdgeInsetsGeometry? padding,
    OutlinedBorder? shape,
    MaterialTapTargetSize? tapTargetSize,
    VisualDensity? visualDensity,
    double? iconSize,
  }) => material.IconButton.styleFrom(
    foregroundColor: foregroundColor,
    backgroundColor: backgroundColor,
    hoverColor: hoverColor,
    highlightColor: highlightColor,
    minimumSize: minimumSize,
    padding: padding,
    shape: shape,
    tapTargetSize: tapTargetSize,
    visualDensity: visualDensity,
    iconSize: iconSize,
  );
  @override
  Widget build(BuildContext context) {
    final states = <WidgetState>{
      if (onPressed == null) WidgetState.disabled,
      if (isSelected == true) WidgetState.selected,
    };
    final colors = miuix.MiuixTheme.of(context).colors;
    final fg =
        style?.foregroundColor?.resolve(states) ??
        (onPressed == null
            ? disabledColor ?? colors.disabledOnSecondary
            : color ?? (filled ? colors.onPrimary : colors.onBackground));
    final minimum = style?.minimumSize?.resolve(states);
    final radius = _cornerRadius(
      context,
      style?.shape?.resolve(states),
      miuix.MiuixIconButtonDefaults.cornerRadius,
    );
    final iconPadding = style?.padding?.resolve(states) ?? padding;
    Widget body = miuix.MiuixIconButton(
      onPressed: onPressed,
      minWidth: constraints?.minWidth ?? minimum?.width ?? 40,
      minHeight: constraints?.minHeight ?? minimum?.height ?? 40,
      cornerRadius: radius,
      backgroundColor:
          style?.backgroundColor?.resolve(states) ??
          (filled ? colors.primary : null),
      holdDownState: isSelected == true,
      child: Padding(
        padding: iconPadding,
        child: Align(
          alignment: alignment,
          widthFactor: 1,
          heightFactor: 1,
          child: IconTheme.merge(
            data: IconThemeData(
              size: style?.iconSize?.resolve(states) ?? iconSize,
              color: fg,
            ),
            child: isSelected == true ? selectedIcon ?? icon : icon,
          ),
        ),
      ),
    );
    if (constraints != null)
      body = ConstrainedBox(constraints: constraints!, child: body);
    body = MergeSemantics(
      child: _ControlFocus(
        onActivate: onPressed,
        focusNode: focusNode,
        autofocus: autofocus,
        child: body,
      ),
    );
    return tooltip == null ? body : Tooltip(message: tooltip!, child: body);
  }
}

class TextField extends StatelessWidget {
  const TextField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.style,
    this.autofocus = false,
    this.maxLines = 1,
    this.minLines,
    this.obscureText = false,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.keyboardType,
    this.enabled = true,
    this.readOnly = false,
    this.textCapitalization = TextCapitalization.none,
    this.onEditingComplete,
    this.cursorColor,
  });
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration? decoration;
  final TextStyle? style;
  final bool autofocus, obscureText, readOnly;
  final bool? enabled;
  final int? maxLines, minLines;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted, onChanged;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final VoidCallback? onEditingComplete;
  final Color? cursorColor;
  @override
  Widget build(BuildContext context) {
    final d = decoration;
    final dense = d?.isDense ?? false;
    final separateLabel = d?.labelText != null && d?.hintText != null;
    final defaults = miuix.MiuixTextFieldDefaults.textFieldColors(context);
    Widget field = miuix.MiuixTextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      label: separateLabel ? d!.hintText! : d?.labelText ?? d?.hintText ?? '',
      useLabelAsPlaceholder: separateLabel || d?.labelText == null,
      enabled: enabled ?? true,
      readOnly: readOnly,
      textStyle: style,
      leadingIcon: d?.prefixIcon ?? d?.prefix,
      trailingIcon: d?.suffixIcon ?? d?.suffix,
      singleLine: maxLines == 1,
      maxLines: maxLines,
      minLines: minLines,
      insideMargin:
          d?.contentPadding?.resolve(Directionality.of(context)) ??
          EdgeInsets.all(dense ? Sp.x2 : Sp.x4),
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      obscureText: obscureText,
      cursorColor: cursorColor,
      onChanged: onChanged,
      colors: miuix.MiuixTextFieldColors(
        backgroundColor: d?.fillColor ?? defaults.backgroundColor,
        labelColor: d?.hintStyle?.color ?? defaults.labelColor,
        borderColor: d?.errorText != null
            ? Theme.of(context).colorScheme.error
            : defaults.borderColor,
      ),
      onSubmitted: (v) {
        onEditingComplete?.call();
        onSubmitted?.call(v);
      },
    );
    if (separateLabel) {
      field = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x1),
            child: Text(
              d!.labelText!,
              style:
                  d.labelStyle ??
                  TextStyle(
                    fontSize: FontSizes.sm,
                    color: miuix.MiuixTheme.of(context)
                        .colors
                        .onSurfaceSecondary,
                  ),
            ),
          ),
          field,
        ],
      );
    }
    if (d?.helperText != null || d?.errorText != null)
      field = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          field,
          Padding(
            padding: const EdgeInsets.only(top: Sp.x1),
            child: Text(
              d?.errorText ?? d!.helperText!,
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: d?.errorText != null
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          ),
        ],
      );
    return MiuixFrameworkBridge(child: field);
  }
}

class TextFormField extends FormField<String> {
  TextFormField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.style,
    this.textInputAction,
    this.onFieldSubmitted,
    this.onChanged,
    super.validator,
    String? initialValue,
    this.autofocus = false,
    super.enabled = true,
    this.obscureText = false,
    this.maxLines = 1,
  }) : assert(controller == null || initialValue == null),
       super(
         initialValue: controller?.text ?? initialValue ?? '',
         builder: (state) {
           final field = state as _TextFormFieldState;
           final w = field.widget;
           return TextField(
             controller: field.effectiveController,
             focusNode: w.focusNode,
             decoration: w.decoration.copyWith(errorText: state.errorText),
             style: w.style,
             textInputAction: w.textInputAction,
             onSubmitted: w.onFieldSubmitted,
             autofocus: w.autofocus,
             enabled: w.enabled,
             obscureText: w.obscureText,
             maxLines: w.maxLines,
             onChanged: (v) {
               state.didChange(v);
               w.onChanged?.call(v);
             },
           );
         },
       );
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final TextStyle? style;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted, onChanged;
  final bool autofocus, obscureText;
  final int? maxLines;
  @override
  FormFieldState<String> createState() => _TextFormFieldState();
}

class _TextFormFieldState extends FormFieldState<String> {
  TextEditingController? internal;
  @override
  TextFormField get widget => super.widget as TextFormField;
  TextEditingController get effectiveController =>
      widget.controller ?? internal!;
  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      internal = TextEditingController(text: widget.initialValue);
    }
    effectiveController.addListener(sync);
  }

  void sync() {
    if (effectiveController.text != value) {
      didChange(effectiveController.text);
    }
  }

  @override
  void didUpdateWidget(TextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      (oldWidget.controller ?? internal)?.removeListener(sync);
      if (widget.controller == null) {
        internal = TextEditingController.fromValue(oldWidget.controller!.value);
      } else {
        internal?.dispose();
        internal = null;
      }
      effectiveController.addListener(sync);
      setValue(effectiveController.text);
    }
  }

  @override
  void reset() {
    effectiveController.text = widget.initialValue ?? '';
    super.reset();
    widget.onChanged?.call(effectiveController.text);
  }

  @override
  void dispose() {
    effectiveController.removeListener(sync);
    internal?.dispose();
    super.dispose();
  }
}

class Slider extends StatefulWidget {
  const Slider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeStart,
    this.onChangeEnd,
    this.onChangeCancel,
    this.activeColor,
    this.inactiveColor,
    this.thumbColor,
    this.focusNode,
    this.autofocus = false,
    this.semanticFormatterCallback,
    this.height = 28,
  });
  final double value, min, max, height;
  final int? divisions;
  final String? label;
  final ValueChanged<double>? onChanged, onChangeStart, onChangeEnd;
  final VoidCallback? onChangeCancel;
  final Color? activeColor, inactiveColor, thumbColor;
  final FocusNode? focusNode;
  final bool autofocus;
  final SemanticFormatterCallback? semanticFormatterCallback;
  @override
  State<Slider> createState() => _SliderState();
}

class _SliderState extends State<Slider> {
  double? pending;
  bool started = false;
  int generation = 0;
  int? activePointer;
  bool get enabled => widget.onChanged != null && widget.max > widget.min;
  double get step =>
      (widget.max - widget.min) / math.max(1, widget.divisions ?? 100);
  void change(double v) {
    if (!enabled) return;
    if (!started) {
      started = true;
      widget.onChangeStart?.call(widget.value);
    }
    pending = v;
    widget.onChanged!(v);
  }

  void finish() {
    if (!mounted || !started) return;
    final value = pending;
    pending = null;
    started = false;
    if (value != null) widget.onChangeEnd?.call(value);
  }

  void cancel() {
    activePointer = null;
    pending = null;
    started = false;
    widget.onChangeCancel?.call();
    if (mounted) setState(() => generation++);
  }

  void increment(double delta) {
    if (!enabled) return;
    change((widget.value + delta).clamp(widget.min, widget.max));
    finish();
  }

  @override
  Widget build(BuildContext context) {
    final defaults = miuix.MiuixSliderDefaults.sliderColors(context);
    final v = widget.value
        .clamp(widget.min, math.max(widget.min, widget.max))
        .toDouble();
    final valueText =
        widget.semanticFormatterCallback?.call(v) ??
        widget.label ??
        v.toStringAsFixed(0);
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: enabled,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent)
          return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowUp) {
          increment(step);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowDown) {
          increment(-step);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        slider: true,
        value: valueText,
        enabled: enabled,
        increasedValue:
            widget.semanticFormatterCallback?.call(
              (v + step).clamp(widget.min, widget.max).toDouble(),
            ) ??
            (v + step)
                .clamp(widget.min, widget.max)
                .toDouble()
                .toStringAsFixed(0),
        decreasedValue:
            widget.semanticFormatterCallback?.call(
              (v - step).clamp(widget.min, widget.max).toDouble(),
            ) ??
            (v - step)
                .clamp(widget.min, widget.max)
                .toDouble()
                .toStringAsFixed(0),
        onIncrease: enabled ? () => increment(step) : null,
        onDecrease: enabled ? () => increment(-step) : null,
        child: Listener(
          onPointerDown: (event) {
            if (enabled) activePointer ??= event.pointer;
          },
          onPointerUp: (event) {
            if (event.pointer != activePointer) return;
            activePointer = null;
            // Tap updates arrive later in this event dispatch. Secondary touches
            // must not finish a seek while the initiating finger is still down.
            scheduleMicrotask(finish);
          },
          onPointerCancel: (event) {
            if (event.pointer == activePointer) cancel();
          },
          child: miuix.MiuixSlider(
            key: ValueKey(generation),
            value: v,
            min: widget.min,
            max: widget.max > widget.min ? widget.max : widget.min + 1,
            enabled: enabled,
            onValueChanged: enabled ? change : null,
            onValueChangeFinished: finish,
            steps: math.max(0, (widget.divisions ?? 1) - 1),
            height: widget.height,
            colors: miuix.MiuixSliderColors(
              foregroundColor: widget.activeColor ?? defaults.foregroundColor,
              disabledForegroundColor: defaults.disabledForegroundColor,
              backgroundColor: widget.inactiveColor ?? defaults.backgroundColor,
              disabledBackgroundColor: defaults.disabledBackgroundColor,
              thumbColor: widget.thumbColor ?? defaults.thumbColor,
              disabledThumbColor: defaults.disabledThumbColor,
              keyPointColor: defaults.keyPointColor,
              keyPointForegroundColor: defaults.keyPointForegroundColor,
            ),
          ),
        ),
      ),
    );
  }
}

class Switch extends StatelessWidget {
  const Switch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Semantics(
    toggled: value,
    enabled: onChanged != null,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    child: ExcludeSemantics(
      child: _ControlFocus(
        onActivate: onChanged == null ? null : () => onChanged!(!value),
        child: miuix.MiuixSwitch(
          value: value,
          onChanged: onChanged,
          enabled: onChanged != null,
        ),
      ),
    ),
  );
}

class Checkbox extends StatelessWidget {
  const Checkbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.tristate = false,
  });
  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final bool tristate;
  @override
  Widget build(BuildContext context) => Semantics(
    checked: value ?? false,
    enabled: onChanged != null,
    onTap: onChanged == null ? null : () => onChanged!(!(value ?? false)),
    child: ExcludeSemantics(
      child: _ControlFocus(
        onActivate: onChanged == null
            ? null
            : () => onChanged!(!(value ?? false)),
        child: miuix.MiuixCheckbox(
          value: value ?? false,
          enabled: onChanged != null,
          onChanged: onChanged == null ? null : (v) => onChanged!(v),
        ),
      ),
    ),
  );
}

class ListTile extends StatelessWidget {
  const ListTile({
    super.key,
    this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.selected = false,
    this.dense,
    this.contentPadding,
    this.selectedTileColor,
    this.tileColor,
    this.visualDensity,
    this.focusNode,
    this.autofocus = false,
    this.minLeadingWidth,
    this.horizontalTitleGap,
  });
  final Widget? title, subtitle, leading, trailing;
  final VoidCallback? onTap, onLongPress;
  final bool enabled, selected, autofocus;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;
  final Color? selectedTileColor, tileColor;
  final VisualDensity? visualDensity;
  final FocusNode? focusNode;
  final double? minLeadingWidth, horizontalTitleGap;
  @override
  Widget build(BuildContext context) {
    final margin =
        (contentPadding ??
                EdgeInsets.symmetric(
                  horizontal: Sp.x4,
                  vertical: dense == true ? Sp.x2 : Sp.x3,
                ))
            .resolve(Directionality.of(context));
    Widget body = miuix.MiuixBasicComponent(
      enabled: enabled,
      onClick: enabled ? onTap : null,
      startAction: leading,
      insideMargin: trailing == null ? margin : margin.copyWith(right: Sp.x3),
      content: [
        if (title != null) title!,
        if (subtitle != null)
          DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: FontSizes.sm,
              color: miuix.MiuixTheme.of(context).colors.onSurfaceSecondary,
            ),
            child: subtitle!,
          ),
      ],
      holdDownState: selected,
    );
    if (onTap != null || focusNode != null || autofocus || onLongPress != null)
      body = _ControlFocus(
        onActivate: enabled ? onTap : null,
        focusNode: focusNode,
        autofocus: autofocus,
        onLongPress: onLongPress,
        child: body,
      );
    // The row has one keyboard stop. Independent end actions live outside its
    // internal Miuix pressable so excluding duplicate focus cannot hide them.
    if (trailing != null)
      body = Row(
        children: [
          Expanded(child: body),
          Padding(
            padding: EdgeInsets.only(
              right: margin.right,
              top: margin.top,
              bottom: margin.bottom,
            ),
            child: trailing!,
          ),
        ],
      );
    if (selected || tileColor != null)
      body = ColoredBox(
        color: selected
            ? selectedTileColor ??
                  miuix.MiuixTheme.of(context).colors.secondaryContainer
            : tileColor!,
        child: body,
      );
    return body;
  }
}

class SwitchListTile extends StatelessWidget {
  const SwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.contentPadding,
    this.dense,
    this.visualDensity,
    this.secondary,
    this.controlAffinity = ListTileControlAffinity.platform,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? title, subtitle, secondary;
  final EdgeInsetsGeometry? contentPadding;
  final bool? dense;
  final VisualDensity? visualDensity;
  final ListTileControlAffinity controlAffinity;
  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: ListTile(
      title: title,
      subtitle: subtitle,
      leading: secondary,
      dense: dense,
      contentPadding: contentPadding,
      enabled: onChanged != null,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: ExcludeFocus(
        child: Switch(value: value, onChanged: onChanged),
      ),
    ),
  );
}

class CheckboxListTile extends StatelessWidget {
  const CheckboxListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.contentPadding,
    this.dense,
    this.secondary,
    this.controlAffinity = ListTileControlAffinity.platform,
    this.tristate = false,
  });
  final bool? value;
  final ValueChanged<bool?>? onChanged;
  final Widget? title, subtitle, secondary;
  final bool? dense;
  final bool tristate;
  final EdgeInsetsGeometry? contentPadding;
  final ListTileControlAffinity controlAffinity;
  @override
  Widget build(BuildContext context) {
    final control = ExcludeFocus(
      child: Checkbox(value: value, onChanged: onChanged, tristate: tristate),
    );
    return MergeSemantics(
      child: ListTile(
        title: title,
        subtitle: subtitle,
        dense: dense,
        contentPadding: contentPadding,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!(value ?? false)),
        leading: controlAffinity == ListTileControlAffinity.leading
            ? control
            : secondary,
        trailing: controlAffinity == ListTileControlAffinity.leading
            ? secondary
            : control,
      ),
    );
  }
}

class ChoiceChip extends StatelessWidget {
  const ChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    this.onSelected,
    this.showCheckmark,
    this.backgroundColor,
    this.selectedColor,
    this.side,
    this.shape,
    this.padding,
    this.labelPadding,
    this.visualDensity,
    this.materialTapTargetSize,
    this.checkmarkColor,
    this.labelStyle,
    this.avatar,
  });
  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final bool? showCheckmark;
  final Color? backgroundColor, selectedColor, checkmarkColor;
  final BorderSide? side;
  final OutlinedBorder? shape;
  final EdgeInsetsGeometry? padding, labelPadding;
  final VisualDensity? visualDensity;
  final MaterialTapTargetSize? materialTapTargetSize;
  final TextStyle? labelStyle;
  final Widget? avatar;
  @override
  Widget build(BuildContext context) {
    final colors = selected
        ? miuix.MiuixButtonDefaults.buttonColorsPrimary(context)
        : miuix.MiuixButtonDefaults.buttonColors(context);
    final radius = _cornerRadius(
      context,
      shape,
      miuix.MiuixButtonDefaults.cornerRadius,
    );
    final effectiveSide = side ?? shape?.side ?? BorderSide.none;
    return MergeSemantics(
      child: _ControlFocus(
        onActivate: onSelected == null ? null : () => onSelected!(!selected),
        child: Semantics(
          selected: selected,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: ShapeDecoration(
              shape: miuix.MiuixSquircleBorder(
                cornerRadius: radius,
                side: effectiveSide,
              ),
            ),
            child: miuix.MiuixButton(
              onPressed: onSelected == null
                  ? null
                  : () => onSelected!(!selected),
              cornerRadius: radius,
              minWidth: 0,
              minHeight: 32,
              insideMargin:
                  padding ??
                  const EdgeInsets.symmetric(
                    horizontal: Sp.x3,
                    vertical: Sp.x2,
                  ),
              colors: miuix.MiuixButtonColors(
                color:
                    (selected ? selectedColor : backgroundColor) ??
                    colors.color,
                disabledColor: colors.disabledColor,
                contentColor: labelStyle?.color ?? colors.contentColor,
                disabledContentColor: colors.disabledContentColor,
              ),
              child: DefaultTextStyle.merge(
                style: labelStyle ?? const TextStyle(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (avatar != null) ...[
                      avatar!,
                      const SizedBox(width: Sp.x1),
                    ],
                    if (selected && showCheckmark == true) ...[
                      Icon(
                        Icons.check,
                        size: FontSizes.sm,
                        color: checkmarkColor ?? colors.contentColor,
                      ),
                      const SizedBox(width: Sp.x1),
                    ],
                    Flexible(
                      child: Padding(
                        padding: labelPadding ?? EdgeInsets.zero,
                        child: label,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FilterChip extends ChoiceChip {
  const FilterChip({
    super.key,
    required super.label,
    required super.selected,
    super.onSelected,
    super.showCheckmark,
    super.backgroundColor,
    super.selectedColor,
    super.side,
    super.shape,
    super.padding,
    super.labelPadding,
    super.visualDensity,
    super.materialTapTargetSize,
    super.checkmarkColor,
    super.labelStyle,
    super.avatar,
  });
}

class InkWell extends StatelessWidget {
  const InkWell({
    super.key,
    this.onTap,
    this.onLongPress,
    this.child,
    this.borderRadius,
    this.focusNode,
    this.autofocus = false,
    this.onFocusChange,
    this.focusColor,
    this.hoverColor,
    this.splashColor,
    this.highlightColor,
    this.onHover,
  });
  final VoidCallback? onTap, onLongPress;
  final Widget? child;
  final BorderRadius? borderRadius;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange, onHover;
  final Color? focusColor, hoverColor, splashColor, highlightColor;
  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onFocusChange: onFocusChange,
    child: MouseRegion(
      onEnter: (_) => onHover?.call(true),
      onExit: (_) => onHover?.call(false),
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        },
        child: miuix.MiuixPressable(
          onPressed: onTap,
          onLongPress: onLongPress,
          borderRadius: borderRadius,
          focusNode: focusNode,
          autofocus: autofocus,
          enabled: onTap != null || onLongPress != null,
          child: child ?? const SizedBox(),
        ),
      ),
    ),
  );
}

class CircularProgressIndicator extends StatelessWidget {
  const CircularProgressIndicator({
    super.key,
    this.value,
    this.strokeWidth = 4,
    this.color,
    this.backgroundColor,
    this.valueColor,
    this.semanticsLabel,
    this.semanticsValue,
  });
  final double? value;
  final double strokeWidth;
  final Color? color, backgroundColor;
  final Animation<Color?>? valueColor;
  final String? semanticsLabel, semanticsValue;
  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticsLabel,
    value: semanticsValue,
    child: miuix.MiuixCircularProgressIndicator(
      progress: value,
      strokeWidth: strokeWidth,
      colors: miuix.MiuixProgressIndicatorColors(
        foregroundColor:
            color ??
            valueColor?.value ??
            miuix.MiuixTheme.of(context).colors.primary,
        disabledForegroundColor: miuix.MiuixTheme.of(context)
            .colors
            .disabledPrimarySlider,
        backgroundColor: backgroundColor ?? Colors.transparent,
      ),
    ),
  );
}

class Divider extends StatelessWidget {
  const Divider({
    super.key,
    this.height,
    this.thickness,
    this.indent,
    this.endIndent,
    this.color,
  });
  final double? height, thickness, indent, endIndent;
  final Color? color;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: height ?? Sp.x4,
    child: Center(
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: indent ?? 0,
          end: endIndent ?? 0,
        ),
        child: miuix.MiuixHorizontalDivider(
          color: color,
          thickness: thickness ?? 1,
        ),
      ),
    ),
  );
}

class Tooltip extends StatefulWidget {
  const Tooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration,
    this.preferBelow = true,
    this.verticalOffset,
    this.showDuration,
    this.textStyle,
    this.decoration,
    this.padding,
    this.margin,
  });
  final String message;
  final Widget child;
  final Duration? waitDuration, showDuration;
  final bool preferBelow;
  final double? verticalOffset;
  final TextStyle? textStyle;
  final Decoration? decoration;
  final EdgeInsetsGeometry? padding, margin;
  @override
  State<Tooltip> createState() => _TooltipState();
}

class _TooltipState extends State<Tooltip> {
  final state = miuix.MiuixTooltipState(isPersistent: true);
  Timer? delay, duration;
  void show() {
    delay?.cancel();
    duration?.cancel();
    if (!mounted) return;
    unawaited(state.show());
    duration = Timer(
      widget.showDuration ?? miuix.MiuixTooltipDefaults.tooltipDuration,
      state.dismiss,
    );
  }

  void schedule(Duration wait) {
    delay?.cancel();
    delay = Timer(wait, show);
  }

  void hide() {
    delay?.cancel();
    duration?.cancel();
    state.dismiss();
  }

  @override
  void dispose() {
    delay?.cancel();
    duration?.cancel();
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (focused) {
      if (focused) {
        schedule(widget.waitDuration ?? Motion.base);
      } else {
        hide();
      }
    },
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        hide();
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      tooltip: widget.message,
      onLongPress: show,
      child: MouseRegion(
        onEnter: (_) => schedule(widget.waitDuration ?? Motion.base),
        onExit: (_) => hide(),
        child: Listener(
          onPointerDown: (e) {
            if (e.kind != PointerDeviceKind.mouse) schedule(kLongPressTimeout);
          },
          onPointerUp: (_) {
            delay?.cancel();
          },
          onPointerCancel: (_) => hide(),
          onPointerMove: (_) {
            delay?.cancel();
          },
          child: miuix.MiuixTooltipBox(
            state: state,
            enableUserInput: false,
            semanticLabel: widget.message,
            spacing:
                widget.verticalOffset ??
                miuix.MiuixTooltipDefaults.spacingBetweenTooltipAndAnchor,
            positioning: widget.preferBelow
                ? miuix.MiuixTooltipAnchorPosition.below
                : miuix.MiuixTooltipAnchorPosition.above,
            tooltip: (context, scope) => miuix.MiuixPlainTooltip(
              scope: scope,
              insideMargin:
                  widget.padding ??
                  miuix.MiuixTooltipDefaults.plainTooltipInsideMargin,
              containerColor: widget.decoration is BoxDecoration
                  ? (widget.decoration as BoxDecoration).color
                  : null,
              child: Text(widget.message, style: widget.textStyle),
            ),
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}

class LinearProgressIndicator extends StatelessWidget {
  const LinearProgressIndicator({
    super.key,
    this.value,
    this.minHeight,
    this.color,
    this.backgroundColor,
    this.valueColor,
    this.borderRadius,
    this.semanticsLabel,
    this.semanticsValue,
  });
  final double? value, minHeight;
  final Color? color, backgroundColor;
  final Animation<Color?>? valueColor;
  final BorderRadiusGeometry? borderRadius;
  final String? semanticsLabel, semanticsValue;
  @override
  Widget build(BuildContext context) {
    final colors = miuix.MiuixProgressIndicatorDefaults.defaultColors(context);
    return Semantics(
      label: semanticsLabel,
      value: semanticsValue,
      child: miuix.MiuixLinearProgressIndicator(
        progress: value,
        height: minHeight ?? 6,
        colors: miuix.MiuixProgressIndicatorColors(
          foregroundColor: color ?? valueColor?.value ?? colors.foregroundColor,
          disabledForegroundColor: colors.disabledForegroundColor,
          backgroundColor: backgroundColor ?? colors.backgroundColor,
        ),
      ),
    );
  }
}

class RadioListTile<T> extends StatelessWidget {
  const RadioListTile({
    super.key,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.dense,
    this.contentPadding,
    this.controlAffinity = ListTileControlAffinity.platform,
  });
  final T value;
  final T? groupValue;
  final ValueChanged<T?>? onChanged;
  final Widget? title, subtitle;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;
  final ListTileControlAffinity controlAffinity;
  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    final control = miuix.MiuixRadioButton(
      selected: selected,
      enabled: onChanged != null,
      onChanged: onChanged == null ? null : (_) => onChanged!(value),
    );
    return Semantics(
      checked: selected,
      inMutuallyExclusiveGroup: true,
      child: ListTile(
        title: title,
        subtitle: subtitle,
        dense: dense,
        contentPadding: contentPadding,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(value),
        leading: controlAffinity == ListTileControlAffinity.trailing
            ? null
            : control,
        trailing: controlAffinity == ListTileControlAffinity.trailing
            ? control
            : null,
      ),
    );
  }
}

/// Expandable Miuix preference. The library has no dedicated expansion tile;
/// its real preference and card compose the header and disclosed content.
class ExpansionTile extends StatefulWidget {
  const ExpansionTile({
    super.key,
    required this.title,
    this.children = const [],
    this.initiallyExpanded = false,
    this.onExpansionChanged,
    this.tilePadding,
    this.childrenPadding,
    this.maintainState = false,
    this.enabled = true,
  });
  final Widget title;
  final List<Widget> children;
  final bool initiallyExpanded, maintainState, enabled;
  final ValueChanged<bool>? onExpansionChanged;
  final EdgeInsetsGeometry? tilePadding, childrenPadding;
  @override
  State<ExpansionTile> createState() => _ExpansionTileState();
}

class _ExpansionTileState extends State<ExpansionTile> {
  late bool expanded = widget.initiallyExpanded;
  void toggle() {
    setState(() => expanded = !expanded);
    widget.onExpansionChanged?.call(expanded);
  }

  @override
  Widget build(BuildContext context) => miuix.MiuixCard(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          expanded: expanded,
          child: ListTile(
            title: widget.title,
            enabled: widget.enabled,
            contentPadding: widget.tilePadding,
            onTap: widget.enabled ? toggle : null,
            trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          ),
        ),
        AnimatedSize(
          duration: MotionPrefs.reduce(context) ? Duration.zero : Motion.fast,
          curve: Motion.easeOut,
          child: expanded
              ? Padding(
                  padding:
                      widget.childrenPadding ?? const EdgeInsets.all(Sp.x4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: widget.children,
                  ),
                )
              : widget.maintainState
              ? Offstage(child: Column(children: widget.children))
              : const SizedBox(width: double.infinity),
        ),
      ],
    ),
  );
}
