import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

import 'package:sourin_spike/ui/app_scaffold.dart';

class _LifetimeProbe extends StatefulWidget {
  const _LifetimeProbe({required this.onInit, required this.child});
  final VoidCallback onInit;
  final Widget child;

  @override
  State<_LifetimeProbe> createState() => _LifetimeProbeState();
}

class _LifetimeProbeState extends State<_LifetimeProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  const contentKey = ValueKey('media-content-bounds');

  testWidgets('nested Miuix scaffolds consume the keyboard inset once', (
    tester,
  ) async {
    var initializations = 0;
    final probe = _LifetimeProbe(
      onInit: () => initializations++,
      child: const AppScaffold(child: SizedBox.expand(key: contentKey)),
    );
    Future<void> pumpInset(double bottom) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: bottom)),
          child: AppScaffold(child: probe),
        ),
      ),
    );

    await pumpInset(0);
    expect(find.byType(miuix.MiuixScaffold), findsNWidgets(2));
    final fullHeight = tester.getSize(find.byKey(contentKey)).height;
    expect(fullHeight, greaterThan(300));
    await pumpInset(200);
    expect(tester.getSize(find.byKey(contentKey)).height, fullHeight - 200);
    expect(
      MediaQuery.viewInsetsOf(tester.element(find.byKey(contentKey))).bottom,
      0,
    );
    expect(
      initializations,
      1,
      reason: 'Keyboard opening must preserve page state.',
    );
    await pumpInset(0);
    expect(tester.getSize(find.byKey(contentKey)).height, fullHeight);
    expect(
      initializations,
      1,
      reason: 'Keyboard closing must preserve page state.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('resize opt-out preserves both content size and child insets', (
    tester,
  ) async {
    Future<void> pumpInset(double bottom) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: bottom)),
          child: const AppScaffold(
            resizeToAvoidBottomInset: false,
            child: SizedBox.expand(key: contentKey),
          ),
        ),
      ),
    );

    await pumpInset(0);
    final fullSize = tester.getSize(find.byKey(contentKey));
    await pumpInset(200);
    expect(tester.getSize(find.byKey(contentKey)), fullSize);
    expect(
      MediaQuery.viewInsetsOf(tester.element(find.byKey(contentKey))).bottom,
      200,
    );
    expect(tester.takeException(), isNull);
  });
}
