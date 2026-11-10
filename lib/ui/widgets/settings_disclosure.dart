import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

import '../../design/icons/app_icons.dart';
import '../tokens.dart';
import 'motion_prefs.dart';

/// A persistent header owns both expansion directions and keeps hover clipped.
class SettingsDisclosure extends StatelessWidget {
  const SettingsDisclosure({
    super.key,
    required this.title,
    required this.summary,
    required this.expanded,
    required this.onChanged,
    required this.child,
  });

  final String title;
  final String summary;
  final bool expanded;
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = MotionPrefs.duration(context, Motion.fast);
    return miuix.MiuixCard(
      cornerRadius: Radii.lg,
      child: ClipPath(
        clipper: const ShapeBorderClipper(
          shape: miuix.MiuixSquircleBorder(cornerRadius: Radii.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              expanded: expanded,
              child: miuix.MiuixBasicComponent(
                key: const ValueKey('settings-disclosure-header'),
                title: title,
                summary: summary,
                onClick: () => onChanged(!expanded),
                onClickLabel: expanded ? '收起$title' : '展开$title',
                insideMargin: const EdgeInsets.all(Sp.x4),
                endActions: [
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: duration,
                    child: Icon(
                      AppIcons.expand_more,
                      size: 22,
                      color: miuix.MiuixTheme.of(context)
                          .colors
                          .onSurfaceVariantSummary,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: duration,
              alignment: Alignment.topCenter,
              curve: Curves.easeOutCubic,
              child: expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Sp.x4,
                        0,
                        Sp.x4,
                        Sp.x4,
                      ),
                      child: child,
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
