// flutter_miuix uses SDK Material internally for editable text and overlays.
// This is the single SDK Material import boundary; feature controls stay Miuix.
import 'package:flutter/material.dart' as sdk;
import 'package:flutter_localizations/flutter_localizations.dart' as locales;
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart' as app;

/// Supplies the dependencies required by Miuix's internal input/overlay widgets.
/// Both Material theme systems receive the same brightness and Miuix palette.
class MiuixFrameworkBridge extends sdk.StatelessWidget {
  const MiuixFrameworkBridge({super.key, required this.child});
  final sdk.Widget child;

  @override
  sdk.Widget build(sdk.BuildContext context) {
    final theme = app.Theme.of(context);
    final miuixTheme = miuix.MiuixTheme.of(context);
    final colors = miuixTheme.colors;
    final inherited = context
        .dependOnInheritedWidgetOfExactType<_BridgeScope>();
    if (inherited?.brightness == miuixTheme.brightness &&
        inherited?.primary == colors.primary &&
        sdk.Localizations.of<sdk.MaterialLocalizations>(
              context,
              sdk.MaterialLocalizations,
            ) !=
            null) {
      return child;
    }
    final data = sdk.ThemeData(
      brightness: miuixTheme.brightness,
      colorScheme:
          sdk.ColorScheme.fromSeed(
            seedColor: colors.primary,
            brightness: miuixTheme.brightness,
          ).copyWith(
            primary: colors.primary,
            onPrimary: colors.onPrimary,
            surface: colors.surface,
            onSurface: colors.onSurface,
            error: colors.error,
          ),
      fontFamily: theme.textTheme.bodyMedium?.fontFamily,
      textSelectionTheme: sdk.TextSelectionThemeData(
        cursorColor: colors.primary,
        selectionColor: colors.primary.withValues(alpha: 0.28),
        selectionHandleColor: colors.primary,
      ),
    );
    final body = sdk.Theme(
      data: data,
      child: sdk.Material(
        type: sdk.MaterialType.transparency,
        child: _BridgeScope(
          brightness: miuixTheme.brightness,
          primary: colors.primary,
          child: child,
        ),
      ),
    );
    if (sdk.Localizations.maybeLocaleOf(context) == null) {
      return sdk.Localizations(
        locale: const sdk.Locale('en'),
        delegates: const [
          locales.GlobalMaterialLocalizations.delegate,
          locales.GlobalWidgetsLocalizations.delegate,
          locales.GlobalCupertinoLocalizations.delegate,
        ],
        child: body,
      );
    }
    return sdk.Localizations.override(
      context: context,
      delegates: const [locales.GlobalMaterialLocalizations.delegate],
      child: body,
    );
  }
}

class _BridgeScope extends sdk.InheritedWidget {
  const _BridgeScope({
    required this.brightness,
    required this.primary,
    required super.child,
  });
  final sdk.Brightness brightness;
  final sdk.Color primary;
  @override
  bool updateShouldNotify(_BridgeScope oldWidget) =>
      brightness != oldWidget.brightness || primary != oldWidget.primary;
}
