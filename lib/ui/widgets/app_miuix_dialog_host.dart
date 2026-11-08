import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

/// Registers dialog content with Miuix while the existing Navigator route owns
/// results, back dismissal and motion. A local host keeps route disposal atomic.
class AppMiuixDialogHost extends StatefulWidget {
  const AppMiuixDialogHost({super.key, required this.child});

  final Widget child;

  @override
  State<AppMiuixDialogHost> createState() => _AppMiuixDialogHostState();
}

class _AppMiuixDialogHostState extends State<AppMiuixDialogHost> {
  final _controller = miuix.MiuixPopupController(visible: true);
  final _focusScope = FocusScopeNode(
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  static final _routeTransition = miuix.MiuixPopupTransition(
    duration: Duration.zero,
    builder: (_, __, child) => child,
  );

  @override
  void dispose() {
    _controller.dispose();
    _focusScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    node: _focusScope,
    child: miuix.MiuixPopupScope(
      establishRoot: true,
      child: miuix.MiuixPopupHost(
        child: miuix.MiuixDialogLayout(
          controller: _controller,
          renderInRoot: false,
          enableWindowDim: false,
          enterTransition: _routeTransition,
          exitTransition: _routeTransition,
          dimEnterTransition: _routeTransition,
          dimExitTransition: _routeTransition,
          content: (_) => widget.child,
        ),
      ),
    ),
  );
}
