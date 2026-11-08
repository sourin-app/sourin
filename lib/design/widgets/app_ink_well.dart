import 'package:flutter/widgets.dart';

import '../../ui/widgets/miuix_controls.dart' as ui;

/// Press/focus feedback is owned by MiuixPressable on all input devices.
class AppInkWell extends StatelessWidget {
  const AppInkWell({
    super.key,
    required this.child,
    this.onTap,
    this.onFocusChange,
    this.focusNode,
    this.borderRadius,
    this.enabled = true,
  });
  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onFocusChange;
  final FocusNode? focusNode;
  final BorderRadius? borderRadius;
  final bool enabled;
  bool get isActive => enabled && onTap != null;
  @override
  Widget build(BuildContext context) => ui.InkWell(
    onTap: isActive ? onTap : null,
    onFocusChange: onFocusChange,
    focusNode: focusNode,
    borderRadius: borderRadius,
    child: child,
  );
}
