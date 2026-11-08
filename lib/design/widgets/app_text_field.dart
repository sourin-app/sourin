import 'package:material_ui/material_ui.dart';

import '../../ui/widgets/miuix_controls.dart' as ui;

class AppTextField extends StatelessWidget {
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
  final bool obscureText, enabled, autofocus;
  final int maxLines;
  final Widget? prefix;
  @override
  Widget build(BuildContext context) => ui.TextField(
    controller: controller,
    decoration: InputDecoration(hintText: hint, prefixIcon: prefix),
    onChanged: onChanged,
    obscureText: obscureText,
    enabled: enabled,
    maxLines: maxLines,
    autofocus: autofocus,
  );
}
