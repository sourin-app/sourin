/// Shared menus use the Miuix popup host and preserve caller-owned anchors.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import '../../design/icons/app_icons.dart';
import '../tokens.dart';
import 'miuix_controls.dart' as ui;
import 'motion_prefs.dart';

const BoxConstraints kAppMenuConstraints = BoxConstraints(
  minWidth: 160,
  maxWidth: 260,
);

/// Kept for historical measurement callers; production menus always use Miuix.
@visibleForTesting
bool debugSkipGlassMenu = false;

class AppMenuItem<T> {
  const AppMenuItem({
    required this.value,
    this.label = '',
    this.icon,
    this.child,
    this.danger = false,
    this.enabled = true,
  }) : assert(label != '' || child != null);

  final T value;
  final String label;
  final IconData? icon;
  final Widget? child;
  final bool danger;
  final bool enabled;
}

Future<T?> showAppMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<AppMenuItem<T>> items,
  T? initialValue,
}) async {
  if (items.isEmpty) return null;
  final navigator = Navigator.of(context, rootNavigator: true);
  final focus = FocusManager.instance.primaryFocus;
  final result = await navigator.push<T>(
    _AppMenuRoute<T>(
      position: position,
      items: items,
      initialValue: initialValue,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
  if (focus?.context != null && focus!.canRequestFocus) focus.requestFocus();
  return result;
}

class _AppMenuRoute<T> extends PopupRoute<T> {
  _AppMenuRoute({
    required this.position,
    required this.items,
    required this.initialValue,
    required this.themes,
  });

  final RelativeRect position;
  final List<AppMenuItem<T>> items;
  final T? initialValue;
  final CapturedThemes themes;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => false;
  @override
  String get barrierLabel => '关闭菜单';
  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(
    _AppMenuPopup<T>(
      position: position,
      items: items,
      initialValue: initialValue,
      themes: themes,
    ),
  );
}

class _AppMenuPopup<T> extends StatefulWidget {
  const _AppMenuPopup({
    required this.position,
    required this.items,
    required this.initialValue,
    required this.themes,
  });
  final RelativeRect position;
  final List<AppMenuItem<T>> items;
  final T? initialValue;
  final CapturedThemes themes;
  @override
  State<_AppMenuPopup<T>> createState() => _AppMenuPopupState<T>();
}

class _AppMenuPopupState<T> extends State<_AppMenuPopup<T>> {
  late final _nodes = List.generate(widget.items.length, (_) => FocusNode());
  final _focusScope = FocusScopeNode(
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  bool _show = true;
  T? _result;

  int get _initialIndex {
    final selected = widget.items.indexWhere(
      (item) => item.enabled && item.value == widget.initialValue,
    );
    return selected >= 0
        ? selected
        : widget.items.indexWhere((item) => item.enabled);
  }

  void _dismiss([T? value]) {
    if (!_show) return;
    if (MotionPrefs.reduce(context)) {
      Navigator.of(context).pop(value);
      return;
    }
    setState(() {
      _result = value;
      _show = false;
    });
  }

  void _moveFocus(int direction, {bool edge = false}) {
    final enabled = [
      for (var i = 0; i < widget.items.length; i++)
        if (widget.items[i].enabled) i,
    ];
    if (enabled.isEmpty) return;
    final current = enabled.indexWhere((i) => _nodes[i].hasFocus);
    final index = edge
        ? (direction > 0 ? enabled.first : enabled.last)
        : enabled[(current + direction + enabled.length) % enabled.length];
    _nodes[index].requestFocus();
    final target = _nodes[index].context;
    if (target != null) Scrollable.ensureVisible(target);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _dismiss();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveFocus(1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _moveFocus(-1);
    } else if (key == LogicalKeyboardKey.home) {
      _moveFocus(1, edge: true);
    } else if (key == LogicalKeyboardKey.end) {
      _moveFocus(-1, edge: true);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.select) {
      final index = _nodes.indexWhere((n) => n.hasFocus);
      if (index >= 0 && widget.items[index].enabled) {
        _dismiss(widget.items[index].value);
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _focusScope.dispose();
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildPopup(context, constraints.biggest),
  );

  Widget _buildPopup(BuildContext context, Size size) {
    final width = math.min(
      kAppMenuConstraints.maxWidth,
      math.max(0.0, size.width - Sp.x4),
    );
    // RelativeRect already describes the requested menu top (some callers
    // intentionally move it under their button), so do not add button height.
    final anchor = Rect.fromLTRB(
      widget.position.left,
      widget.position.top,
      size.width - widget.position.right,
      widget.position.top,
    );
    final alignment = widget.position.left <= widget.position.right
        ? miuix.MiuixPopupAlign.start
        : miuix.MiuixPopupAlign.end;
    final content = widget.themes.wrap(
      FocusScope(
        node: _focusScope,
        child: Focus(
          autofocus: _initialIndex < 0,
          onKeyEvent: _handleKey,
          child: FocusTraversalGroup(
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: Sp.x1),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < widget.items.length; i++)
                      _item(context, i),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (MotionPrefs.reduce(context)) {
      // The upstream window host always animates. Use its actual popup content
      // with a settled reveal, keeping Miuix positioning for reduced motion.
      return Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
            child: const ColoredBox(color: Colors.transparent),
          ),
          CustomSingleChildLayout(
            delegate: _ReducedMenuLayout(
              anchor,
              alignment,
              Directionality.of(context),
            ),
            child: miuix.MiuixListPopupContent(
              popupContentSize: Size.zero,
              onPopupContentSizeChange: (_) {},
              fractionProgress: () => 1,
              alphaProgress: () => 1,
              popupLayoutPosition: const miuix.MiuixPopupLayoutPosition(
                showBelow: true,
                showAbove: false,
                isRightAligned: false,
              ),
              localTransformOrigin: Offset.zero,
              surfaceBuilder: (_, __, child) => miuix.MiuixCard(child: child),
              child: content,
            ),
          ),
        ],
      );
    }
    return miuix.MiuixWindowListPopup(
      show: _show,
      anchorBounds: anchor,
      alignment: widget.position.left <= widget.position.right
          ? miuix.MiuixPopupAlign.start
          : miuix.MiuixPopupAlign.end,
      popupPositionProvider: _AppMenuPositionProvider(
        Offset.zero & size,
        width,
      ),
      enableWindowDim: false,
      maxHeight: size.height,
      minWidth: math.min(kAppMenuConstraints.minWidth, width),
      onDismissRequest: _dismiss,
      onDismissFinished: () {
        if (mounted) Navigator.of(context).pop(_result);
      },
      surfaceBuilder: (_, __, child) =>
          widget.themes.wrap(miuix.MiuixCard(child: child)),
      content: content,
    );
  }

  Widget _item(BuildContext context, int index) {
    final item = widget.items[index];
    final colors = Theme.of(context).colorScheme;
    final foreground = !item.enabled
        ? colors.onSurface.withValues(alpha: 0.38)
        : item.danger
        ? colors.error
        : colors.onSurface;
    final content =
        item.child ??
        Row(
          children: [
            if (item.icon != null) ...[
              Icon(item.icon, size: 16, color: foreground),
              const SizedBox(width: Sp.x3),
            ],
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: FontSizes.sm, color: foreground),
              ),
            ),
          ],
        );
    return Focus(
      focusNode: _nodes[index],
      autofocus: index == _initialIndex,
      canRequestFocus: item.enabled,
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      child: ExcludeFocus(
        child: Semantics(
          button: true,
          enabled: item.enabled,
          selected:
              widget.initialValue != null && item.value == widget.initialValue,
          child: miuix.MiuixBasicComponent(
            enabled: item.enabled,
            holdDownState: _nodes[index].hasFocus,
            insideMargin: const EdgeInsets.symmetric(
              horizontal: Sp.x4,
              vertical: Sp.x2,
            ),
            onClick: item.enabled ? () => _dismiss(item.value) : null,
            content: [
              DefaultTextStyle.merge(
                style: TextStyle(color: foreground),
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground),
                  child: content,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// RelativeRect is supplied in the Navigator overlay's coordinates. Keep that
/// actual layout boundary even when MediaQuery describes a larger display.
class _AppMenuPositionProvider implements miuix.MiuixPopupPositionProvider {
  _AppMenuPositionProvider(this.viewport, this.menuWidth);
  final Rect viewport;
  final double menuWidth;
  final _position = miuix.MiuixListPopupDefaults.dropdownPositionProvider(
    verticalMargin: 0,
  );

  @override
  EdgeInsetsGeometry get margins => _position.margins;

  @override
  Offset calculatePosition({
    required Rect anchorBounds,
    required Rect windowBounds,
    required TextDirection textDirection,
    required Size popupContentSize,
    required EdgeInsets popupMargin,
    required miuix.MiuixPopupAlign alignment,
  }) => _position.calculatePosition(
    anchorBounds: anchorBounds,
    windowBounds: windowBounds.intersect(viewport),
    textDirection: textDirection,
    // The window host asks for a position before its first post-frame size
    // report. The content width is already constrained, so use it immediately
    // instead of briefly placing a zero-width popup against the right edge.
    popupContentSize: Size(menuWidth, popupContentSize.height),
    popupMargin: popupMargin,
    alignment: alignment,
  );
}

class _ReducedMenuLayout extends SingleChildLayoutDelegate {
  const _ReducedMenuLayout(this.anchor, this.alignment, this.direction);
  final Rect anchor;
  final miuix.MiuixPopupAlign alignment;
  final TextDirection direction;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0.0, constraints.maxWidth - Sp.x4),
        maxHeight: math.max(0.0, constraints.maxHeight - Sp.x4),
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      miuix.MiuixListPopupDefaults.dropdownPositionProvider(verticalMargin: 0)
          .calculatePosition(
            anchorBounds: anchor,
            windowBounds: Offset.zero & size,
            textDirection: direction,
            popupContentSize: childSize,
            popupMargin: EdgeInsets.zero,
            alignment: alignment,
          );
  @override
  bool shouldRelayout(_ReducedMenuLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.alignment != alignment ||
      oldDelegate.direction != direction;
}

class AppMenuButton<T> extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.items,
    required this.onSelected,
    this.tooltip,
    this.icon,
    this.iconSize = 17,
  });
  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final String? tooltip;
  final IconData? icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (buttonContext) => ui.IconButton(
      tooltip: tooltip ?? '更多操作',
      padding: EdgeInsets.zero,
      icon: Icon(
        icon ?? AppIcons.more_vert,
        size: iconSize,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: items.isEmpty
          ? null
          : () async {
              final button = buttonContext.findRenderObject() as RenderBox?;
              final overlay =
                  Navigator.of(
                        buttonContext,
                        rootNavigator: true,
                      ).overlay?.context.findRenderObject()
                      as RenderBox?;
              if (button == null || overlay == null || !button.hasSize) return;
              final top = button.localToGlobal(
                Offset(0, button.size.height),
                ancestor: overlay,
              );
              final result = await showAppMenu<T>(
                context: buttonContext,
                position: RelativeRect.fromRect(
                  Rect.fromLTWH(top.dx, top.dy, button.size.width, 0),
                  Offset.zero & overlay.size,
                ),
                items: items,
              );
              if (result != null && buttonContext.mounted) onSelected(result);
            },
    ),
  );
}
