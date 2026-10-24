import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Only horizontal home rails opt into mouse dragging. Inherit the parent
/// behavior so platform physics and the arm64 overscroll clipping fix survive.
class SourinHorizontalRail extends StatelessWidget {
  const SourinHorizontalRail({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final parent = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: parent.copyWith(
        dragDevices: {...parent.dragDevices, PointerDeviceKind.mouse},
        scrollbars: false,
      ),
      child: child,
    );
  }
}
