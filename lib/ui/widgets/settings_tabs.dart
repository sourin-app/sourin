import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// A real Miuix tab row with keyboard/remote selection. Miuix 1.3.0 exposes
/// pointer gestures for this component, so the application owns its focus node.
class SettingsTabs extends StatefulWidget {
  const SettingsTabs({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.height = Sp.x12,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  final double height;

  @override
  State<SettingsTabs> createState() => _SettingsTabsState();
}

class _SettingsTabsState extends State<SettingsTabs> {
  bool _showFocus = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || widget.labels.isEmpty) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final next =
        (widget.selected + (key == LogicalKeyboardKey.arrowRight ? 1 : -1))
            .clamp(0, widget.labels.length - 1);
    widget.onSelected(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    skipTraversal: true,
    onKeyEvent: _onKey,
    child: FocusableActionDetector(
      onShowFocusHighlight: (value) => setState(() => _showFocus = value),
      child: Container(
        foregroundDecoration: BoxDecoration(
          borderRadius: Radii.rSm,
          border: Border.all(
            width: 2,
            color: _showFocus
                ? miuix.MiuixTheme.of(context).colors.primary
                : Colors.transparent,
          ),
        ),
        child: miuix.MiuixTheme(
          data: miuix.MiuixTheme.of(context).copyWith(
            textStyles: miuix.MiuixTheme.of(context).textStyles.copy(
              body1: miuix.MiuixTheme.of(context).textStyles.body1
                  .copyWith(fontSize: FontSizes.cap),
            ),
          ),
          child: miuix.MiuixTabRow(
            tabs: widget.labels,
            selectedTabIndex: widget.selected,
            onTabSelected: widget.onSelected,
            minWidth: Sp.x12,
            maxWidth: double.infinity,
            height: widget.height,
            itemSpacing: Sp.x1,
            cornerRadius: Radii.sm,
          ),
        ),
      ),
    ),
  );
}
