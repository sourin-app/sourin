// Floating bottom placement for the shell's real Miuix navigation. The body remains
// owned by ShellPage, which preserves each page and its scroll state.
import 'package:flutter/widgets.dart';

import '../../shell.dart' show AppTab;
import 'shell_layout.dart';

class BottomBarShellLayout extends ShellLayout {
  const BottomBarShellLayout({required this.nav});

  /// Floating navigation, injected by ShellPage at every window width.
  final Widget nav;

  @override
  String get id => 'bottomBar';

  @override
  String get label => '底部悬浮栏';

  @override
  Widget build({
    required BuildContext context,
    required AppTab current,
    required ValueChanged<AppTab> onSelect,
    required Widget body,
    required List<AppTab> tabs,
  }) {
    // Floating navigation overlays scrolling content. Pages retain their shared
    // bottom inset; the system navigation inset is consumed exactly once here.
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned(
          left: 0,
          right: 0,
          bottom: MediaQuery.paddingOf(context).bottom,
          child: MediaQuery.removeViewPadding(
            context: context,
            removeBottom: true,
            child: nav,
          ),
        ),
      ],
    );
  }
}
