import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'poster_card.dart';

/// A compact library poster with a single-line title below the cover.
class CompactShelfCard extends StatelessWidget {
  const CompactShelfCard({
    super.key,
    required this.title,
    this.cover,
    this.subtitle,
    this.reserveSubtitleSpace = true,
    this.releaseStatus,
    this.percent,
    this.unread = 0,
    required this.onTap,
  });

  final String title;
  final String? cover;
  final String? subtitle;
  final bool reserveSubtitleSpace;
  final String? releaseStatus;
  final int? percent;
  final int unread;
  final VoidCallback onTap;

  static const double width = 132;
  static const double _posterWidth = width - Sp.x2 * 2;
  static const double _lineHeight = 1.35;

  static double _titleHeightOf(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(FontSizes.sm) * _lineHeight)
          .ceilToDouble();

  static double _subtitleHeightOf(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(FontSizes.cap) * _lineHeight)
          .ceilToDouble();

  /// A rail may omit the second caption row only when every subtitle is empty.
  /// Pass the same reservation to its cards; a real subtitle still renders even
  /// if a caller passes false, so its parent must reserve that row's height.
  static double heightOf(
    BuildContext context, {
    bool reserveSubtitleSpace = true,
  }) =>
      Sp.x2 * 2 +
      _posterWidth / AppMetrics.posterAspect +
      Sp.x2 +
      _titleHeightOf(context) +
      (reserveSubtitleSpace ? Sp.x1 + _subtitleHeightOf(context) : 0);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasSubtitle = subtitle?.isNotEmpty ?? false;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: miuix.MiuixCard(
        colors: miuix.MiuixCardColors(
          color: colors.surfaceContainer,
          contentColor: colors.onSurface,
        ),
        cornerRadius: Radii.lg,
        onPressed: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Sp.x2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: Radii.rMd,
                child: Stack(
                  children: [
                    Semantics(
                      label: [
                        if (unread > 0) '$unread 集待看',
                        if (releaseStatus?.isNotEmpty ?? false) releaseStatus!,
                      ].join('，'),
                      child: ExcludeSemantics(
                        child: ExcludeFocus(
                          child: IgnorePointer(
                            child: PosterCard(
                              title: title,
                              cover: cover,
                              width: _posterWidth,
                              unread: unread,
                              releaseStatus: releaseStatus,
                              showCaption: false,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (percent != null && percent! > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: Semantics(
                            label: '观看进度',
                            value: '${percent!.clamp(0, 100)}%',
                            child: miuix.MiuixLinearProgressIndicator(
                              progress: (percent! / 100).clamp(0.0, 1.0),
                              height: Sp.x1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Sp.x2),
              SizedBox(
                height: _titleHeightOf(context),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    height: _lineHeight,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ),
              if (reserveSubtitleSpace || hasSubtitle) ...[
                const SizedBox(height: Sp.x1),
                SizedBox(
                  height: _subtitleHeightOf(context),
                  child: hasSubtitle
                      ? Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: FontSizes.cap,
                            height: _lineHeight,
                            color: colors.onSurfaceVariant,
                          ),
                        )
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
