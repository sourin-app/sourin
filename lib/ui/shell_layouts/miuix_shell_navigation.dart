import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import '../../design/icons/app_icons.dart';
import '../../shell.dart' show AppTab;
import '../tokens.dart';
import '../widgets/app_logo.dart';
import '../widgets/app_menu.dart';

/// The package allows at most five bottom destinations. Secondary destinations
/// remain directly available in the desktop rail and in the compact overflow.
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

  Future<void> _showMore(BuildContext context) async {
    final anchor = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final bounds = Rect.fromPoints(
      anchor.localToGlobal(Offset.zero, ancestor: overlay),
      anchor.localToGlobal(
        anchor.size.bottomRight(Offset.zero),
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

    return miuix.MiuixNavigationBar(
      key: const ValueKey('shell-navigation-bar'),
      defaultWindowInsetsPadding: false,
      children: [
        for (final tab in _primaryTabs)
          _NavigationFocus(
            key: ValueKey('shell-nav-${tab.name}'),
            selected: tab == current,
            onActivate: () => onSelect(tab),
            child: miuix.MiuixNavigationBarItem(
              selected: tab == current,
              onPressed: () => onSelect(tab),
              icon: Icon(
                tab.icon(active: tab == current),
                color: tab == current
                    ? miuix.MiuixTheme.of(context).colors.primary
                    : miuix.MiuixTheme.of(context).colors.onSurfaceSecondary,
                size: Sp.x6,
              ),
              label: tab.label,
              badge: _badge(tab),
            ),
          ),
        Builder(
          builder: (anchorContext) => _NavigationFocus(
            key: const ValueKey('shell-nav-more'),
            selected: _secondaryTabs.contains(current),
            onActivate: () => _showMore(anchorContext),
            child: miuix.MiuixNavigationBarItem(
              selected: _secondaryTabs.contains(current),
              onPressed: () => _showMore(anchorContext),
              icon: Icon(
                _secondaryTabs.contains(current)
                    ? current.icon(active: true)
                    : AppIcons.more_horiz,
                color: _secondaryTabs.contains(current)
                    ? miuix.MiuixTheme.of(context).colors.primary
                    : miuix.MiuixTheme.of(context).colors.onSurfaceSecondary,
                size: Sp.x6,
              ),
              label: _secondaryTabs.contains(current) ? current.label : '更多',
            ),
          ),
        ),
      ],
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
