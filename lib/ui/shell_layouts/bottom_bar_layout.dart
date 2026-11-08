// Responsive placement for the shell's real Miuix navigation. The body remains
// owned by ShellPage, which preserves each page and its scroll state.
import 'package:flutter/widgets.dart';

import '../../shell.dart' show AppTab;
import 'shell_layout.dart';

class BottomBarShellLayout extends ShellLayout {
  const BottomBarShellLayout({required this.nav, this.rail});

  /// Compact navigation, injected by ShellPage.
  final Widget nav;
  final Widget? rail;

  static const double railBreakpoint = 900;

  @override
  String get id => 'bottomBar';

  @override
  String get label => '底栏式';

  @override
  Widget build({
    required BuildContext context,
    required AppTab current,
    required ValueChanged<AppTab> onSelect,
    required Widget body,
    required List<AppTab> tabs,
  }) {
    if (rail != null && MediaQuery.sizeOf(context).width >= railBreakpoint) {
      return Row(
        children: [
          rail!,
          Expanded(child: body),
        ],
      );
    }
    // Compact navigation overlays scrolling content. Pages retain their shared
    // bottom inset; the system navigation inset is consumed exactly once here.
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.paddingOf(context).bottom,
          child: nav,
        ),
      ],
    );
  }
}
