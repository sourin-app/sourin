import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

import '../../design/icons/app_icons.dart';
import '../tokens.dart';
import 'miuix_controls.dart' as ui;

/// Shared page navigation. The window titlebar owns the window controls.
class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle = '',
    this.onBack,
    this.actions = const [],
    this.backgroundColor,
  });

  final String title;
  final String subtitle;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final colors = miuix.MiuixTheme.of(context).colors;
    return miuix.MiuixSmallTopAppBar(
      title: title,
      color: backgroundColor ?? colors.background,
      defaultWindowInsetsPadding: false,
      navigationIconPadding: 0,
      actionIconPadding: 0,
      titlePadding: math.max(56.0, actions.length * 44.0 + 12),
      navigationIcon: ui.IconButton(
        key: const ValueKey('page-header-back'),
        tooltip: '返回',
        onPressed: onBack ?? () => Navigator.of(context).maybePop(),
        icon: const Icon(AppIcons.arrow_back, size: 22),
      ),
      actions: actions,
      bottomContent: subtitle.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: Sp.x1, bottom: Sp.x4),
              child: Text(
                subtitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurfaceVariantSummary,
                  height: 1.5,
                ),
              ),
            ),
    );
  }
}
