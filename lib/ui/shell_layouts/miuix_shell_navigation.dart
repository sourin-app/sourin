import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import '../../design/icons/app_icons.dart';
import '../../shell.dart' show AppTab;
import '../tokens.dart';
import '../widgets/app_logo.dart';
import '../widgets/app_menu.dart';

/// The desktop dock exposes all destinations; narrow windows keep secondary
/// destinations in the overflow menu. Interaction and motion are owned by Miuix.
class MiuixShellNavigation extends StatelessWidget {
  const MiuixShellNavigation({
    super.key,
    required this.current,
    required this.unread,
    required this.onSelect,
    this.rail = false,
  });

  final AppTab current;
  final int unread;
  final ValueChanged<AppTab> onSelect;
  final bool rail;

  static const _primaryTabs = <AppTab>[
    AppTab.home,
    AppTab.live,
    AppTab.follow,
    AppTab.search,
  ];
  static const _secondaryTabs = <AppTab>[AppTab.cached, AppTab.settings];

  Widget? _badge(AppTab tab) => tab == AppTab.follow && unread > 0
      ? miuix.MiuixBadge(
          child: miuix.MiuixText(
            unread > 99 ? '99+' : '$unread',
            fontSize: FontSizes.cap,
          ),
        )
      : null;

  Future<void> _showMore(BuildContext context, {int itemCount = 1}) async {
    final anchor = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final bounds = Rect.fromPoints(
      anchor.localToGlobal(
        Offset(
          Directionality.of(context) == TextDirection.rtl
              ? 0
              : anchor.size.width * (itemCount - 1) / itemCount,
          0,
        ),
        ancestor: overlay,
      ),
      anchor.localToGlobal(
        Offset(
          Directionality.of(context) == TextDirection.rtl
              ? anchor.size.width / itemCount
              : anchor.size.width,
          anchor.size.height,
        ),
        ancestor: overlay,
      ),
    );
    final selected = await showAppMenu<AppTab>(
      context: context,
      position: RelativeRect.fromRect(bounds, Offset.zero & overlay.size),
      initialValue: _secondaryTabs.contains(current) ? current : null,
      items: [
        for (final tab in _secondaryTabs)
          AppMenuItem(
            value: tab,
            label: tab.label,
            icon: tab.icon(active: tab == current),
          ),
      ],
    );
    if (context.mounted && selected != null) onSelect(selected);
  }

  @override
  Widget build(BuildContext context) {
    if (rail) {
      final colors = miuix.MiuixTheme.of(context).colors;
      return miuix.MiuixNavigationRail(
        key: const ValueKey('shell-navigation-rail'),
        defaultWindowInsetsPadding: false,
        minWidth: Sp.x16 + Sp.x6,
        iconSize: Sp.x6,
        itemVerticalPadding: Sp.x3,
        labelFontSize: FontSizes.cap,
        header: const AppLogo(size: Sp.x8),
        children: [
          for (final tab in AppTab.values)
            _NavigationFocus(
              key: ValueKey('shell-nav-${tab.name}'),
              selected: tab == current,
              onActivate: () => onSelect(tab),
              child: miuix.MiuixCard(
                cornerRadius: Radii.md,
                colors: miuix.MiuixCardColors(
                  color: tab == current
                      ? colors.secondaryContainer
                      : colors.surface,
                  contentColor: colors.onSurface,
                ),
                child: miuix.MiuixNavigationRailItem(
                  selected: tab == current,
                  onPressed: () => onSelect(tab),
                  icon: Icon(
                    tab.icon(active: tab == current),
                    color: tab == current
                        ? miuix.MiuixTheme.of(context).colors.primary
                        : miuix.MiuixTheme.of(context)
                              .colors
                              .onSurfaceSecondary,
                    size: Sp.x6,
                  ),
                  label: tab.label,
                  badge: _badge(tab),
                ),
              ),
            ),
        ],
      );
    }

    final colors = miuix.MiuixTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x3, 0, Sp.x3, Sp.x4),
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 440;
              final tabs = compact ? _primaryTabs : AppTab.values;
              final secondary = compact && _secondaryTabs.contains(current);
              final selectedIndex = secondary
                  ? tabs.length
                  : tabs.indexOf(current);
              final itemCount = tabs.length + (compact ? 1 : 0);
              Widget iconFor(AppTab tab) {
                final badge = _badge(tab);
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Icon(
                      tab.icon(active: tab == current),
                      color: tab == current
                          ? colors.primary
                          : colors.onSurfaceSecondary,
                      size: Sp.x6,
                    ),
                    if (badge != null)
                      Positioned(top: -Sp.x1, right: -Sp.x1, child: badge),
                  ],
                );
              }

              return Shortcuts(
                shortcuts: const <ShortcutActivator, Intent>{
                  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
                },
                child: miuix.MiuixGlassNavigationBar(
                  key: const ValueKey('shell-navigation-bar'),
                  height: Sp.x16,
                  selectedIndex: selectedIndex,
                  selectedColor: colors.onSurface,
                  unselectedColor: colors.onSurfaceSecondary,
                  indicatorColor: colors.primary.withValues(alpha: .12),
                  indicatorPressedColor: colors.primary.withValues(alpha: .20),
                  onSelect: (index) {
                    if (index < tabs.length) {
                      onSelect(tabs[index]);
                    } else {
                      _showMore(context, itemCount: itemCount);
                    }
                  },
                  items: [
                    for (final tab in tabs)
                      miuix.MiuixGlassNavigationItem(
                        icon: iconFor(tab),
                        label: tab.label,
                      ),
                    if (compact)
                      miuix.MiuixGlassNavigationItem(
                        icon: Icon(
                          secondary
                              ? current.icon(active: true)
                              : AppIcons.more_horiz,
                          color: secondary
                              ? colors.primary
                              : colors.onSurfaceSecondary,
                          size: Sp.x6,
                        ),
                        label: secondary ? current.label : '更多',
                        isAction: true,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Miuix 1.3.0 navigation uses pointer gestures. Add the application's existing
/// keyboard/remote activation and a visible focus ring without a second tap path.
class _NavigationFocus extends StatefulWidget {
  const _NavigationFocus({
    super.key,
    required this.selected,
    required this.onActivate,
    required this.child,
  });

  final bool selected;
  final VoidCallback onActivate;
  final Widget child;

  @override
  State<_NavigationFocus> createState() => _NavigationFocusState();
}

class _NavigationFocusState extends State<_NavigationFocus> {
  bool _showFocus = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    autofocus: widget.selected,
    onShowFocusHighlight: (show) => setState(() => _showFocus = show),
    mouseCursor: SystemMouseCursors.click,
    shortcuts: const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    },
    actions: <Type, Action<Intent>>{
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onActivate();
          return null;
        },
      ),
    },
    child: Container(
      foregroundDecoration: BoxDecoration(
        borderRadius: Radii.rMd,
        border: Border.all(
          width: 2,
          color: _showFocus
              ? miuix.MiuixTheme.of(context).colors.primary
              : Colors.transparent,
        ),
      ),
      child: ExcludeFocus(child: widget.child),
    ),
  );
}
