import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

/// Closes tooltips before a fading control loses its semantics anchor.
/// The animation is shared with the controls; no separate visibility state is kept.
class MiuixTooltipVisibility extends InheritedWidget {
  const MiuixTooltipVisibility({
    super.key,
    required this.visibility,
    required super.child,
  });

  final Animation<double> visibility;

  static Animation<double>? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MiuixTooltipVisibility>()
      ?.visibility;

  @override
  bool updateShouldNotify(MiuixTooltipVisibility oldWidget) =>
      oldWidget.visibility != visibility;
}

/// Keeps a Miuix tooltip in the anchor's state lifecycle.
///
/// Miuix 1.3.0's TooltipBox marks a separate OverlayEntry dirty from
/// didUpdateWidget. A visible tooltip then fails when its anchor rebuilds.
/// Reconcile entry changes after build and remove the entry with its host.
/// The entry has an ordinary overlay semantics parent: a fading or clipped
/// anchor must not leave a portal traversal link to an absent semantic node.
class MiuixTooltipHost extends StatefulWidget {
  const MiuixTooltipHost({
    super.key,
    required this.state,
    required this.tooltip,
    required this.child,
    required this.preferBelow,
    required this.spacing,
  });

  final miuix.MiuixTooltipState state;
  final Widget Function(BuildContext, miuix.MiuixTooltipScope) tooltip;
  final Widget child;
  final bool preferBelow;
  final double spacing;

  @override
  State<MiuixTooltipHost> createState() => _MiuixTooltipHostState();
}

class _MiuixTooltipHostState extends State<MiuixTooltipHost>
    with SingleTickerProviderStateMixin {
  OverlayEntry? _entry;
  OverlayState? _overlay;
  Rect? _anchor;
  CapturedThemes? _themes;
  miuix.MiuixThemeData? _theme;
  MediaQueryData? _mediaQuery;
  TextDirection? _direction;
  bool _routeIsCurrent = true;
  bool _geometryWatchScheduled = false;
  late final _animation = AnimationController(
    vsync: this,
    duration: miuix.MiuixTooltipDefaults.animationDuration,
    reverseDuration: miuix.MiuixTooltipDefaults.animationDuration,
  )..addStatusListener(_onAnimationStatus);
  late final _fade = CurvedAnimation(
    parent: _animation,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  bool _active = true;
  bool _syncScheduled = false;
  Animation<double>? _visibility;
  final Set<ScrollPosition> _scrollPositions = {};

  bool get _visibilityAllowsTooltip =>
      _visibility == null ||
      (_visibility!.value > 0 &&
          _visibility!.status != AnimationStatus.reverse);

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_scheduleVisibility);
    _scheduleVisibility();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeIsCurrent = ModalRoute.isCurrentOf(context) ?? true;
    // Track both scroll axes: a card can sit inside a horizontal rail which
    // itself moves in the vertical page viewport.
    Scrollable.maybeOf(context, axis: Axis.vertical);
    Scrollable.maybeOf(context, axis: Axis.horizontal);
    final positions = <ScrollPosition>{};
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        positions.add((element.state as ScrollableState).position);
      }
      return true;
    });
    for (final position in _scrollPositions.difference(positions)) {
      position.removeListener(_onScroll);
    }
    for (final position in positions.difference(_scrollPositions)) {
      position.addListener(_onScroll);
    }
    _scrollPositions
      ..clear()
      ..addAll(positions);
    final visibility = MiuixTooltipVisibility.of(context);
    if (!identical(visibility, _visibility)) {
      _visibility?.removeListener(_onVisibilityChanged);
      _visibility?.removeStatusListener(_onVisibilityStatus);
      _visibility = visibility;
      _visibility?.addListener(_onVisibilityChanged);
      _visibility?.addStatusListener(_onVisibilityStatus);
    }
    if (widget.state.isVisible || _entry != null) _scheduleVisibility();
  }

  void _onVisibilityStatus(AnimationStatus _) => _onVisibilityChanged();

  void _onVisibilityChanged() {
    if (!_active || !mounted || _visibilityAllowsTooltip) return;
    // Animation/status listeners run before the frame's build and semantics
    // passes. Remove the overlay in that same frame, including instant fades.
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _scheduleVisibility();
      return;
    }
    _dismissForVisibility();
  }

  void _onScroll() {
    if (!_active || !mounted || (!widget.state.isVisible && _entry == null))
      return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _active) _dismissForVisibility();
      });
    } else {
      _dismissForVisibility();
    }
  }

  void _dismissForVisibility() {
    _removeEntry();
    if (!_animation.isDismissed) {
      _animation.stop();
      _animation.value = 0;
    }
    if (widget.state.isVisible) widget.state.dismiss();
  }

  void _removeEntry() {
    final entry = _entry;
    _entry = null;
    _overlay = null;
    _anchor = null;
    entry?.remove();
    entry?.dispose();
  }

  Rect? _anchorInOverlay(OverlayState overlay) {
    final render = context.findRenderObject();
    final overlayRender = overlay.context.findRenderObject();
    if (render is! RenderBox ||
        !render.attached ||
        !render.hasSize ||
        overlayRender is! RenderBox ||
        !overlayRender.attached) {
      return null;
    }
    final anchor = MatrixUtils.transformRect(
      render.getTransformTo(overlayRender),
      Offset.zero & render.size,
    );
    return anchor.isFinite && !anchor.isEmpty ? anchor : null;
  }

  void _showOrUpdateEntry() {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final anchor = _anchorInOverlay(overlay);
    if (anchor == null) return;
    if (_entry != null && !identical(overlay, _overlay)) _removeEntry();
    _themes = InheritedTheme.capture(from: context, to: overlay.context);
    // MiuixTheme is an InheritedWidget, so InheritedTheme.capture does not
    // include it. Read it here to retain the anchor's current palette.
    _theme = miuix.MiuixTheme.of(context);
    _mediaQuery = MediaQuery.maybeOf(context);
    _direction = Directionality.of(context);
    _anchor = anchor;
    if (_entry == null) {
      _overlay = overlay;
      _entry = OverlayEntry(builder: _buildTooltip);
      overlay.insert(_entry!);
    } else {
      _entry!.markNeedsBuild();
    }
    _watchAnchorGeometry();
  }

  void _watchAnchorGeometry() {
    if (_geometryWatchScheduled || _entry == null) return;
    _geometryWatchScheduled = true;
    // Follow frames already requested by layout, scrolling or playback.
    // Registering a post-frame callback does not keep an idle app rendering.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryWatchScheduled = false;
      if (!mounted || !_active || _entry == null) return;
      final overlay = _overlay;
      final anchor = overlay == null ? null : _anchorInOverlay(overlay);
      if (!_anchorIsPainted() || anchor == null) {
        _dismissForVisibility();
        return;
      }
      if (anchor != _anchor) {
        _anchor = anchor;
        _entry!.markNeedsBuild();
      }
      _watchAnchorGeometry();
    });
  }

  bool _anchorIsPainted() {
    if (!_routeIsCurrent || !_visibilityAllowsTooltip) return false;
    final render = context.findRenderObject();
    if (render is! RenderBox ||
        !render.attached ||
        !render.hasSize ||
        render.size.isEmpty) {
      return false;
    }
    RenderObject child = render;
    RenderObject? parent = child.parent;
    while (parent != null) {
      if (!parent.paintsChild(child)) return false;
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        final bounds = MatrixUtils.transformRect(
          render.getTransformTo(parent),
          Offset.zero & render.size,
        );
        if (!bounds.isFinite || !clip.overlaps(bounds)) return false;
      }
      child = parent;
      parent = child.parent;
    }
    return true;
  }

  @override
  void didUpdateWidget(MiuixTooltipHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_scheduleVisibility);
      widget.state.addListener(_scheduleVisibility);
    }
    if (oldWidget.state != widget.state ||
        widget.state.isVisible ||
        _entry != null) {
      // Loading and layout changes can remove the anchor's area without a
      // new hover/focus event or a change to the tooltip state itself.
      _scheduleVisibility();
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) _scheduleVisibility();
  }

  void _scheduleVisibility() {
    if (!_active || _syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted || !_active) return;
      if (widget.state.isVisible) {
        // A retained hover/long-press callback can outlive its visible anchor.
        // Do not graft an overlay semantics child onto an invisible control.
        if (!_anchorIsPainted()) {
          _dismissForVisibility();
          return;
        }
        _showOrUpdateEntry();
        if (_animation.status != AnimationStatus.forward &&
            _animation.status != AnimationStatus.completed) {
          _animation.forward();
        }
      } else if (_animation.isDismissed) {
        _removeEntry();
      } else if (_animation.status != AnimationStatus.reverse) {
        _animation.reverse();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void deactivate() {
    _active = false;
    _removeEntry();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _scheduleVisibility();
  }

  @override
  void dispose() {
    _removeEntry();
    widget.state.removeListener(_scheduleVisibility);
    for (final position in _scrollPositions) {
      position.removeListener(_onScroll);
    }
    _scrollPositions.clear();
    _visibility?.removeListener(_onVisibilityChanged);
    _visibility?.removeStatusListener(_onVisibilityStatus);
    _fade.dispose();
    _animation
      ..removeStatusListener(_onAnimationStatus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  Widget _buildTooltip(BuildContext context) {
    final anchor = _anchor;
    // Removal during a parent build is legal but the Overlay can retain its
    // entry element until the next frame. An already queued rebuild then has
    // no content to render, just as a detached anchor has no tooltip.
    if (!_active || anchor == null) return const SizedBox.shrink();
    return _themes!.wrap(
      MediaQuery(
        data: _mediaQuery ?? const MediaQueryData(),
        child: miuix.MiuixTheme(
          data: _theme!,
          child: Directionality(
            textDirection: _direction!,
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              child: IgnorePointer(
                child: CustomSingleChildLayout(
                  delegate: _TooltipPosition(
                    anchor: anchor,
                    preferBelow: widget.preferBelow,
                    spacing: widget.spacing,
                  ),
                  child: FadeTransition(
                    opacity: _fade,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.9, end: 1).animate(_fade),
                      child: Builder(
                        builder: (context) => widget.tooltip(
                          context,
                          miuix.MiuixTooltipScope(
                            positioning: widget.preferBelow
                                ? miuix.MiuixTooltipAnchorPosition.below
                                : miuix.MiuixTooltipAnchorPosition.above,
                            anchorBounds: anchor,
                          ),
                        ),
                      ),
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

class _TooltipPosition extends SingleChildLayoutDelegate {
  const _TooltipPosition({
    required this.anchor,
    required this.preferBelow,
    required this.spacing,
  });
  final Rect anchor;
  final bool preferBelow;
  final double spacing;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final fitsBelow = anchor.bottom + spacing + childSize.height <= size.height;
    final fitsAbove = anchor.top - spacing - childSize.height >= 0;
    final below = preferBelow
        ? fitsBelow || !fitsAbove
        : !fitsAbove && fitsBelow;
    final maxX = (size.width - childSize.width).clamp(0.0, size.width);
    final maxY = (size.height - childSize.height).clamp(0.0, size.height);
    return Offset(
      (anchor.center.dx - childSize.width / 2).clamp(0.0, maxX),
      (below
              ? anchor.bottom + spacing
              : anchor.top - spacing - childSize.height)
          .clamp(0.0, maxY),
    );
  }

  @override
  bool shouldRelayout(_TooltipPosition oldDelegate) =>
      anchor != oldDelegate.anchor ||
      preferBelow != oldDelegate.preferBelow ||
      spacing != oldDelegate.spacing;
}
