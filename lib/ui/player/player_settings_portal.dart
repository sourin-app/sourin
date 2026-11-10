import 'package:flutter/widgets.dart';

/// Owns the controller for exactly one mounted portal. The player's state may
/// survive a parent layout change; its former portal must not share a
/// controller with a newly mounted portal during that frame.
class PlayerSettingsPortal extends StatefulWidget {
  const PlayerSettingsPortal({
    super.key,
    required this.visible,
    required this.overlayChildBuilder,
  });

  final bool visible;
  final WidgetBuilder overlayChildBuilder;

  @override
  State<PlayerSettingsPortal> createState() => _PlayerSettingsPortalState();
}

class _PlayerSettingsPortalState extends State<PlayerSettingsPortal> {
  final _controller = OverlayPortalController(debugLabel: 'player-settings');
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    // show() before attachment records the initial visibility without
    // notifying an element during its parent's build.
    if (widget.visible) _controller.show();
  }

  @override
  void didUpdateWidget(PlayerSettingsPortal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    final revision = ++_revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _revision) return;
      if (widget.visible) {
        _controller.show();
      } else {
        _controller.hide();
      }
    });
  }

  @override
  Widget build(BuildContext context) => Semantics(
    // Keep the portal's traversal-parent identifier on its own node instead
    // of merging it into the player's Focus or a neighbouring portal. This
    // boundary must wrap OverlayPortal: its parent annotation wraps child.
    container: true,
    child: OverlayPortal(
      controller: _controller,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: widget.overlayChildBuilder,
      // The bounded player Stack supplies the area for this non-painting,
      // non-interactive anchor. A zero-size boundary can lose its semantics.
      child: const SizedBox.expand(),
    ),
  );
}
