import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter/widgets.dart';
import '../app_palette.dart';

/// One palette for framework controls, existing app surfaces and window chrome.
miuix.MiuixThemeData miuixThemeData(Brightness brightness) {
  final theme = miuix.MiuixThemeData.of(brightness);
  final colors = theme.colors;
  final dark = brightness == Brightness.dark;
  final background = Color(dark ? 0xFF101114 : 0xFFF5F6F8);
  final surface = Color(dark ? 0xFF1C1D21 : 0xFFFFFFFF);
  return theme.copyWith(colors: colors.copy(
    // Keep small button labels legible in both modes (white/blue >= 4.5:1).
    primary: const Color(0xFF2168D8),
    background: background,
    surface: surface,
    surfaceContainer: surface,
    onSurfaceSecondary: Color.alphaBlend(colors.onSurfaceVariantSummary, surface),
    onBackground: Color.alphaBlend(colors.onBackground, background),
  ));
}

AppPalette miuixPalette(Brightness brightness) {
  final colors = miuixThemeData(brightness).colors;
  return AppPalette(
    brightness: brightness,
    barrier: colors.windowDimming,
    background: colors.background,
    foreground: colors.onBackground,
    primary: colors.primary,
    primaryForeground: colors.onPrimary,
    secondary: colors.secondary,
    secondaryForeground: colors.onSecondary,
    muted: colors.surfaceContainerHigh,
    mutedForeground: colors.onSurfaceSecondary,
    error: colors.error,
    card: colors.surfaceContainer,
    border: colors.dividerLine,
  );
}
