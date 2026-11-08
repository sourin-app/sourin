import 'package:material_ui/material_ui.dart';

import '../../ui/widgets/miuix_controls.dart' as ui;
import '../../ui/tokens.dart';

/// Miuix action with the same sizing for download, favorite and follow actions.
class AppOutlinedButton extends StatelessWidget {
  const AppOutlinedButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.foregroundColor,
    this.borderColor,
    this.backgroundColor,
  }) : icon = null,
       label = null;
  const AppOutlinedButton.icon({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.foregroundColor,
    this.borderColor,
    this.backgroundColor,
  }) : child = null;
  final VoidCallback? onPressed;
  final Widget? child, icon, label;
  final Color? foregroundColor, borderColor, backgroundColor;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = ui.OutlinedButton.styleFrom(
      foregroundColor: foregroundColor,
      backgroundColor: backgroundColor,
      side: borderColor == null ? null : BorderSide(color: borderColor!),
      minimumSize: Size(
        0,
        theme.materialTapTargetSize == MaterialTapTargetSize.padded ? 48 : 32,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: Sp.x2),
      textStyle: const TextStyle(
        fontSize: FontSizes.sm,
        fontWeight: FontWeight.w500,
        height: 1,
        leadingDistribution: TextLeadingDistribution.even,
        letterSpacing: 0,
      ),
    );
    return icon != null
        ? ui.OutlinedButton.icon(
            onPressed: onPressed,
            icon: icon,
            label: label,
            style: style,
          )
        : ui.OutlinedButton(onPressed: onPressed, child: child, style: style);
  }
}
