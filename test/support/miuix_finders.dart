import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart';

/// Finds the actual Miuix tooltip anchor by its accessible description.
Finder miuixTooltip(String message) => find.byWidgetPredicate(
  (widget) => widget is MiuixTooltipBox && widget.semanticLabel == message,
  description: 'Miuix tooltip "$message"',
);
