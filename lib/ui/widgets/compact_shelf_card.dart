import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'poster_card.dart';

/// A short library card leaves room for discovery on the home screen.
class CompactShelfCard extends StatelessWidget {
  const CompactShelfCard({
    super.key,
    required this.title,
    this.cover,
    this.subtitle,
    this.percent,
    this.unread = 0,
    required this.onTap,
  });

  final String title;
  final String? cover;
  final String? subtitle;
  final int? percent;
  final int unread;
  final VoidCallback onTap;

  // Smaller text must not shrink the fixed poster or its vertical padding.
  static double heightOf(BuildContext context) =>
      Sp.x16 / AppMetrics.posterAspect +
      Sp.x6 +
      (MediaQuery.textScalerOf(context).scale(FontSizes.base) -
              FontSizes.base)
          .clamp(0.0, double.infinity) *
          4;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainer,
      borderRadius: Radii.rLg,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Sp.x3),
          child: Row(
            children: [
              ExcludeSemantics(
                child: IgnorePointer(
                  child: PosterCard(
                    title: title,
                    cover: cover,
                    width: Sp.x16,
                    showCaption: false,
                  ),
                ),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: FontSizes.base,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                    if (subtitle?.isNotEmpty ?? false) ...[
                      const SizedBox(height: Sp.x1),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (unread > 0) ...[
                      const SizedBox(height: Sp.x1),
                      Text(
                        '$unread 集待看',
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.primary,
                        ),
                      ),
                    ],
                    if (percent != null && percent! > 0) ...[
                      const SizedBox(height: Sp.x2),
                      ClipRRect(
                        borderRadius: Radii.rSm,
                        child: LinearProgressIndicator(
                          value: (percent! / 100).clamp(0.0, 1.0),
                          minHeight: Sp.x1,
                          semanticsLabel: '观看进度',
                          semanticsValue: '${percent!.round()}%',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
