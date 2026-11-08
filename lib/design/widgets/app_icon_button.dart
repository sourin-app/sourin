import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

import '../../ui/widgets/miuix_controls.dart' as ui;

class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.iconSize,
  });
  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double? iconSize;
  @override
  Widget build(BuildContext context) => ui.IconButton(
    icon: icon,
    onPressed: onPressed,
    tooltip: tooltip,
    iconSize: iconSize ?? 24,
    constraints: BoxConstraints(
      minWidth:
          (iconSize ?? 24) + (iconSize != null && iconSize! <= 20 ? 8 : 16),
      minHeight:
          (iconSize ?? 24) + (iconSize != null && iconSize! <= 20 ? 8 : 16),
    ),
  );
}

class AppSurface extends StatelessWidget {
  const AppSurface({
    super.key,
    required this.child,
    this.color,
    this.borderRadius,
    this.border,
    this.clipBehavior = Clip.none,
  });
  final Widget child;
  final Color? color;
  final BorderRadius? borderRadius;
  final BoxBorder? border;
  final Clip clipBehavior;
  @override
  Widget build(BuildContext context) => miuix.MiuixSurface(
    color: color ?? const Color(0x00000000),
    cornerRadius: borderRadius?.topLeft.x ?? 0,
    border: border is Border ? border as Border : null,
    child: ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      clipBehavior: clipBehavior,
      child: child,
    ),
  );
}
