import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

/// Finds the actual Miuix tooltip anchor by its accessible description.
Finder miuixTooltip(String message) => find.byWidgetPredicate(
  (widget) =>
      (widget is MiuixTooltipBox && widget.semanticLabel == message) ||
      (widget is ui.Tooltip && widget.message == message),
  description: 'Miuix tooltip "$message"',
);

/// The complete hit target of a labelled Miuix glass navigation destination.
Finder miuixNavigationItem(String label) => find
    .ancestor(
      of: find.descendant(
        of: find.byType(MiuixGlassNavigationBar),
        matching: find.text(label),
      ),
      matching: find.byType(FocusableActionDetector),
    )
    .first;
