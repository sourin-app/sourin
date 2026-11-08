import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'app_menu.dart';
import 'miuix_controls.dart' as ui;

class SettingsDropdownOption<T> {
  const SettingsDropdownOption(this.value, this.label);
  final T value;
  final String label;
}

/// Miuix button and popup share one pointer, keyboard and remote selection path.
/// The menu returns an index so nullable values can represent “all” options.
class SettingsDropdown<T> extends StatelessWidget {
  const SettingsDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.hint = '请选择',
    this.width,
  });

  final T? value;
  final List<SettingsDropdownOption<T>> options;
  final ValueChanged<T>? onChanged;
  final String hint;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final index = options.indexWhere((option) => option.value == value);
    final label = index < 0 ? hint : options[index].label;
    return SizedBox(
      width: width,
      child: Builder(
        builder: (anchor) => ui.TextButton(
          onPressed: onChanged == null || options.isEmpty
              ? null
              : () async {
                  final box = anchor.findRenderObject() as RenderBox?;
                  final overlay =
                      Overlay.of(anchor).context.findRenderObject()
                          as RenderBox?;
                  if (box == null || overlay == null) return;
                  final selected = await showAppMenu<int>(
                    context: anchor,
                    position: RelativeRect.fromRect(
                      box.localToGlobal(Offset.zero, ancestor: overlay) &
                          box.size,
                      Offset.zero & overlay.size,
                    ),
                    initialValue: index < 0 ? null : index,
                    items: [
                      for (var i = 0; i < options.length; i++)
                        AppMenuItem(value: i, label: options[i].label),
                    ],
                  );
                  if (anchor.mounted && selected != null) {
                    onChanged?.call(options[selected].value);
                  }
                },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Sp.x1),
              const Icon(Icons.arrow_drop_down, size: Sp.x5),
            ],
          ),
        ),
      ),
    );
  }
}
