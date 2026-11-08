import 'package:flutter/widgets.dart';

import '../../ui/widgets/miuix_controls.dart' as ui;

/// Shared application action backed by MiuixButton.
class AppTextButton extends StatelessWidget {
  const AppTextButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.foregroundColor,
  });
  final VoidCallback? onPressed;
  final Widget child;
  final Color? foregroundColor;
  @override
  Widget build(BuildContext context) => ui.TextButton(
    onPressed: onPressed,
    style: ui.TextButton.styleFrom(foregroundColor: foregroundColor),
    child: child,
  );
}
