import 'package:flutter/widgets.dart';

import '../../ui/widgets/miuix_controls.dart' as ui;
import '../../ui/tokens.dart';

class AppTooltip extends StatelessWidget {
  const AppTooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration = Motion.base,
  });
  final String message;
  final Widget child;
  final Duration waitDuration;
  @override
  Widget build(BuildContext context) =>
      ui.Tooltip(message: message, waitDuration: waitDuration, child: child);
}

class AppSlider extends StatelessWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
  });
  final double value, min, max;
  final ValueChanged<double>? onChanged;
  final int? divisions;
  final String? label;
  @override
  Widget build(BuildContext context) => ui.Slider(
    value: value,
    onChanged: onChanged,
    min: min,
    max: max,
    divisions: divisions,
    label: label,
  );
}
