/// Shared dialog layout with a real Miuix card and one dismissal contract.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import '../app_scaffold.dart';
import '../app_theme.dart';
import '../tokens.dart';
import '../../design/icons/app_icons.dart';
import 'app_miuix_dialog_host.dart';
import 'miuix_controls.dart' as ui;
import 'overlay_motion.dart';

class AppDialogShell extends StatelessWidget {
  const AppDialogShell({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onClose,
    this.actions,
    this.width = 560,
    this.fill = true,
    this.scrollable = true,
    this.contentPadding,
    this.headerPadding,
    this.motion = false,
    this.margin,
    this.maxHeight,
    this.footer,
    this.icon,
    this.closeEnabled = true,
    this.forceDarkCard = false,
    this.glass = false,
  });

  /// Legacy call-site option. Miuix owns the surface in both modes.
  final bool glass;
  static const double _kMaxHeight = 620;
  final String title;
  final String? subtitle;
  final Widget child;
  final VoidCallback? onClose;
  final Widget? actions;
  final double width;
  final bool fill;
  final bool scrollable;
  final EdgeInsets? contentPadding;
  final EdgeInsets? headerPadding;
  final bool motion;
  final EdgeInsets? margin;
  final double? maxHeight;
  final Widget? footer;
  final IconData? icon;
  final bool closeEnabled;
  final bool forceDarkCard;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final inset = margin ?? EdgeInsets.zero;
    final effectiveWidth = math.min(
      width,
      math.max(0.0, media.size.width - math.max(Sp.x4 * 2, inset.horizontal)),
    );
    final effectiveHeight = math.min(
      maxHeight ?? _kMaxHeight,
      math.max(
        0.0,
        media.size.height -
            media.viewInsets.bottom -
            media.padding.vertical -
            inset.vertical,
      ),
    );
    Widget card = Builder(
      builder: (cardContext) => SizedBox(
        width: effectiveWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: effectiveHeight),
          child: ClipRRect(
            borderRadius: Radii.rLg,
            child: miuix.MiuixCard(
              cornerRadius: Radii.lg,
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Header(
                      title: title,
                      subtitle: subtitle,
                      onClose: onClose,
                      padding: headerPadding,
                      icon: icon,
                      closeEnabled: closeEnabled,
                    ),
                    Flexible(
                      child: scrollable
                          ? SingleChildScrollView(
                              clipBehavior: Clip.antiAlias,
                              padding:
                                  contentPadding ??
                                  const EdgeInsets.fromLTRB(
                                    Sp.x6,
                                    0,
                                    Sp.x6,
                                    Sp.x2,
                                  ),
                              child: child,
                            )
                          : child,
                    ),
                    if (footer != null) footer!,
                    if (actions != null) _ActionBar(child: actions!),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (forceDarkCard) {
      card = AppThemeHost(
        data: AppTheme.themeFor(Brightness.dark),
        child: card,
      );
    }
    final overlay = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: closeEnabled ? onClose : null,
      child: _scrim(
        Center(
          child: Padding(
            padding: inset + EdgeInsets.only(bottom: media.viewInsets.bottom),
            child: GestureDetector(
              onTap: () {},
              child: motion ? OverlayCardMotion(child: card) : card,
            ),
          ),
        ),
      ),
    );
    Widget shell = fill
        ? SizedBox(
            width: media.size.width,
            height: media.size.height,
            child: overlay,
          )
        : overlay;
    shell = AppMiuixDialogHost(child: FocusTraversalGroup(child: shell));
    // Keep the host mounted when a submission temporarily disables dismissal.
    // Removing this wrapper would dispose its popup, draft and focus scope.
    return CallbackShortcuts(
      bindings: {
        if (onClose != null)
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (closeEnabled) onClose!();
          },
      },
      child: shell,
    );
  }

  Widget _scrim(Widget child) {
    final color = Colors.black.withValues(alpha: 0.72);
    return motion
        ? OverlayScrim(color: color, child: child)
        : ColoredBox(color: color, child: child);
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    this.subtitle,
    this.onClose,
    this.padding,
    this.icon,
    this.closeEnabled = true,
  });
  final String title;
  final String? subtitle;
  final VoidCallback? onClose;
  final EdgeInsets? padding;
  final IconData? icon;
  final bool closeEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(Sp.x6, Sp.x3, Sp.x3, Sp.x2),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: colors.onSurfaceVariant),
            const SizedBox(width: Sp.x2),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: FontSizes.lg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: Sp.x1),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (onClose != null)
            ui.IconButton(
              onPressed: closeEnabled ? onClose : null,
              icon: Icon(AppIcons.close, color: colors.onSurface),
              tooltip: '关闭',
            )
          else
            // Retain the close control's slot while submission is pending.
            const SizedBox.square(dimension: Sp.x10),
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const ui.Divider(height: 1),
      Padding(
        padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x2, Sp.x6, Sp.x3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [Flexible(child: child)],
        ),
      ),
    ],
  );
}

/// Historical capture probes still assign this flag; Miuix has no glass layer.
@visibleForTesting
bool debugSkipGlassShell = false;
bool skipGlassShellFor(BuildContext context) => true;
