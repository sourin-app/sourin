import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';

/// Mounts dialogs through the production route, giving the Miuix popup host its
/// bounded viewport and allowing its registered content to finish mounting.
Future<void> pumpMiuixDialog(
  WidgetTester tester,
  Widget dialog, {
  Brightness brightness = Brightness.dark,
  bool settle = true,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  final theme = AppTheme.themeFor(brightness);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: theme,
      themeAnimationDuration: Duration.zero,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: const Scaffold(body: SizedBox.shrink()),
    ),
  );
  unawaited(
    showAppDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => dialog,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // Pending operations intentionally keep their progress ticker active.
    // Mount the route, its deferred Miuix content and the entrance animation
    // without waiting for the operation under test to finish.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }
}
