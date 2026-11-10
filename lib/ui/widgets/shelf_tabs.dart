import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'motion_prefs.dart';

/// The shared library categories, in their stable source-key order.
class ShelfTabs extends StatelessWidget {
  const ShelfTabs({
    super.key,
    required this.selected,
    required this.counts,
    required this.onSelected,
  }) : assert(counts.length == labels.length),
       assert(selected >= 0 && selected < labels.length);

  static const labels = ['追更', '收藏', '历史'];
  final int selected;
  final List<int> counts;
  final ValueChanged<int> onSelected;

  static String displayCount(int count) => count > 999 ? '999+' : '$count';

  static double widthOf(BuildContext context) => MiuixSegmentedTabs.widthOf(
    context,
    [for (final label in labels) '$label 999+'],
  );

  @override
  Widget build(BuildContext context) => MiuixSegmentedTabs(
    tabs: [
      for (var i = 0; i < labels.length; i++)
        '${labels[i]} ${displayCount(counts[i])}',
    ],
    selected: selected,
    onSelected: onSelected,
  );
}

/// Real Miuix glass tabs with measured text, scrolling and directional keys.
class MiuixSegmentedTabs extends StatefulWidget {
  const MiuixSegmentedTabs({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
  }) : assert(tabs.length > 0),
       assert(selected >= 0 && selected < tabs.length);

  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onSelected;

  static miuix.MiuixTextStyles _textStyles(BuildContext context) {
    final styles = miuix.MiuixTheme.of(context).textStyles;
    return styles.copy(
      body2: styles.body2.copyWith(fontSize: FontSizes.sm),
      subtitle: styles.subtitle.copyWith(
        fontSize: FontSizes.sm,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  static double _textWidth(BuildContext context, String text) {
    final styles = _textStyles(context);
    final theme = miuix.MiuixTheme.of(context);
    var width = 0.0;
    for (final style in [styles.body2, styles.subtitle]) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style.merge(
            miuix.MiuixFontWeightAdjustment(style)
                .withMiuixWeight(theme.fontWeightAdjustment),
          ),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > width) width = painter.width;
      painter.dispose();
    }
    return width.ceilToDouble();
  }

  static double widthOf(BuildContext context, List<String> tabs) {
    final widest = tabs.fold<double>(0, (width, tab) {
      final textWidth = _textWidth(context, tab);
      return width > textWidth ? width : textWidth;
    });
    // MiuixGlassSegmentedTabRow uses 16px horizontal padding per item,
    // 8px gaps, and 3px track padding on each side.
    final segment = widest + 34;
    return segment * tabs.length + 8 * (tabs.length - 1) + 6;
  }

  @override
  State<MiuixSegmentedTabs> createState() => _MiuixSegmentedTabsState();
}

class _MiuixSegmentedTabsState extends State<MiuixSegmentedTabs> {
  final ScrollController _scrollController = ScrollController();
  final FocusNode _group = FocusNode(skipTraversal: true);
  int? _pendingVisibleIndex;
  double? _lastViewportWidth;
  double? _lastComponentWidth;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MotionPrefs.reduce(context);
    if (_reduceMotion != reduceMotion) {
      _reduceMotion = reduceMotion;
      _ensureVisible(widget.selected);
    }
  }

  void _ensureVisible(int index) {
    final scheduled = _pendingVisibleIndex != null;
    _pendingVisibleIndex = index;
    if (scheduled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = _pendingVisibleIndex;
      _pendingVisibleIndex = null;
      if (!mounted ||
          pending == null ||
          pending >= widget.tabs.length ||
          !_scrollController.hasClients) {
        return;
      }
      if (_reduceMotion &&
          _scrollController.position.isScrollingNotifier.value) {
        _scrollController.jumpTo(_scrollController.position.pixels);
      }
      final nodes = _group.traversalDescendants.toList();
      if (nodes.length != widget.tabs.length) return;
      final target = nodes[pending].context?.findRenderObject();
      if (target == null) return;
      _scrollController.position.ensureVisible(
        target,
        alignment: .5,
        duration: MotionPrefs.duration(
          context,
          const Duration(milliseconds: 120),
        ),
        curve: MotionPrefs.curve(context, Curves.easeOut),
      );
    });
  }

  void _select(int index) {
    widget.onSelected(index);
    _ensureVisible(index);
  }

  KeyEventResult _onKey(BuildContext context, FocusNode group, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final items = group.traversalDescendants.toList();
    final focused = items.indexWhere((node) => node.hasPrimaryFocus);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final forward = (key == LogicalKeyboardKey.arrowRight) != rtl;
    final next =
        ((focused < 0 ? widget.selected : focused) + (forward ? 1 : -1)).clamp(
          0,
          widget.tabs.length - 1,
        );
    if (items.length == widget.tabs.length) {
      items[next].requestFocus();
    }
    _select(next);
    return KeyEventResult.handled;
  }

  @override
  void didUpdateWidget(MiuixSegmentedTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _ensureVisible(widget.selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = miuix.MiuixTheme.of(context);
    final colors = Theme.of(context).colorScheme;
    final tabs = widget.tabs;
    final height =
        (MediaQuery.textScalerOf(context).scale(FontSizes.sm) * 1.4 + Sp.x4)
            .clamp(40.0, double.infinity);
    return LayoutBuilder(
      builder: (context, constraints) {
        final ideal = MiuixSegmentedTabs.widthOf(context, tabs);
        final viewport = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : ideal;
        final componentWidth = ideal > viewport ? ideal : viewport;
        if (_lastViewportWidth != viewport ||
            _lastComponentWidth != componentWidth) {
          _lastViewportWidth = viewport;
          _lastComponentWidth = componentWidth;
          _ensureVisible(widget.selected);
        }
        return SizedBox(
          width: viewport,
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            primary: false,
            child: SizedBox(
              width: componentWidth,
              child: Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
                },
                child: Focus(
                  focusNode: _group,
                  skipTraversal: true,
                  onKeyEvent: (node, event) => _onKey(context, node, event),
                  child: miuix.MiuixTheme(
                    data: theme.copyWith(
                      textStyles: MiuixSegmentedTabs._textStyles(context),
                    ),
                    child: miuix.MiuixGlassSegmentedTabRow(
                      tabs: tabs,
                      selectedIndex: widget.selected,
                      onSelect: _select,
                      height: height,
                      selectedContentColor: colors.onSurface,
                      contentColor: colors.onSurfaceVariant,
                      shadow: null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _group.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}
