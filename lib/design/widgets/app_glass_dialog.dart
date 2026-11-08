/// Compact confirmation dialog; the legacy name remains for existing callers.
import 'dart:math' as math;

import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets/app_miuix_dialog_host.dart';
import 'app_text_button.dart';

class AppGlassDialog extends StatelessWidget {
  const AppGlassDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.maxWidth = 460,
    this.maxHeight = 620,
  });
  final String title;
  final Widget content;
  final Widget actions;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final colors = Theme.of(context).colorScheme;
    final route = ModalRoute.of(context);
    return AppMiuixDialogHost(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: route?.barrierDismissible == true
            ? () => Navigator.of(context).maybePop()
            : null,
        child: Padding(
          padding:
              const EdgeInsets.all(Sp.x4) +
              EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: Align(
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.min(
                  maxWidth,
                  math.max(0.0, media.size.width - Sp.x4 * 2),
                ),
                maxHeight: math.min(
                  maxHeight,
                  math.max(
                    0.0,
                    media.size.height - Sp.x4 * 2 - media.viewInsets.bottom,
                  ),
                ),
              ),
              child: GestureDetector(
                onTap: () {},
                child: miuix.MiuixCard(
                  cornerRadius: Radii.lg,
                  insideMargin: const EdgeInsets.fromLTRB(
                    Sp.x6,
                    Sp.x5,
                    Sp.x6,
                    Sp.x4,
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colors.onSurface,
                            fontSize: FontSizes.lg,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: Sp.x3),
                        Flexible(
                          child: SingleChildScrollView(
                            child: DefaultTextStyle.merge(
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: FontSizes.sm,
                                height: 1.45,
                              ),
                              textAlign: TextAlign.center,
                              child: content,
                            ),
                          ),
                        ),
                        const SizedBox(height: Sp.x4),
                        Align(alignment: Alignment.centerRight, child: actions),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppGlassDialogActions extends StatelessWidget {
  const AppGlassDialogActions({
    super.key,
    required this.onCancel,
    required this.onConfirm,
    required this.confirmLabel,
    this.cancelLabel = '取消',
    this.confirmIsDestructive = true,
  });
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final String confirmLabel;
  final String cancelLabel;
  final bool confirmIsDestructive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppTextButton(onPressed: onCancel, child: Text(cancelLabel)),
        const SizedBox(width: Sp.x1),
        AppTextButton(
          onPressed: onConfirm,
          foregroundColor: confirmIsDestructive ? colors.error : colors.primary,
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

/// Retained for historical capture probes; production uses one Miuix surface.
@visibleForTesting
bool debugSkipGlassDialog = false;
