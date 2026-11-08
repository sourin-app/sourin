import 'package:flutter/widgets.dart';

import '../../ui/widgets/miuix_controls.dart' as ui;

class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) =>
      ui.Switch(value: value, onChanged: onChanged);
}

class AppDivider extends StatelessWidget {
  const AppDivider({super.key, this.indent = 0, this.thickness});
  final double indent;
  final double? thickness;
  @override
  Widget build(BuildContext context) => ui.Divider(
    height: thickness ?? 1,
    thickness: thickness,
    indent: indent,
    endIndent: indent,
  );
}
