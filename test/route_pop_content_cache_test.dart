// Real Navigator/MaterialPageRoute/production transition owner; no native media.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';
import 'package:sourin_spike/ui/widgets/page_transition_route.dart';

class _PaintPulse extends ChangeNotifier {
  int paints = 0;
  void invalidate() => notifyListeners();
}

class _CountedPainter extends CustomPainter {
  _CountedPainter(this.pulse) : super(repaint: pulse);
  final _PaintPulse pulse;

  @override
  void paint(Canvas canvas, Size size) {
    pulse.paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.red);
  }

  @override
  bool shouldRepaint(_CountedPainter oldDelegate) =>
      !identical(oldDelegate.pulse, pulse);
}

Widget _content(Key key, _PaintPulse pulse) => Center(
  child: SizedBox(
    key: key,
    width: 180,
    height: 180,
    child: CustomPaint(painter: _CountedPainter(pulse)),
  ),
);

double _opacity(WidgetTester tester, Key key) => tester
    .widgetList<FadeTransition>(find.ancestor(
      of: find.byKey(key),
      matching: find.byType(FadeTransition),
    ))
    .fold<double>(1, (value, fade) => value * fade.opacity.value);

void main() {
  for (final primaryPop in [false, true]) {
    testWidgets(
      primaryPop
          ? 'top route pop caches outgoing content while its own fade advances'
          : 'covered route caches content during secondary transition control',
      (tester) async {
        final previousStyle = PageTransitionStyleStore.current.value;
        PageTransitionStyleStore.resetForTest(PageTransitionStyle.fade);
        final navigator = GlobalKey<NavigatorState>();
        final rootPulse = _PaintPulse();
        final topPulse = _PaintPulse();
        const rootKey = ValueKey('root-content-cache-probe');
        const topKey = ValueKey('top-content-cache-probe');
        final theme = ThemeData(
          platform: TargetPlatform.windows,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.windows: SourinPageTransitionsBuilder(
                backgroundColor: Colors.transparent,
              ),
            },
          ),
        );
        MaterialPageRoute<void>? route;
        try {
          await tester.pumpWidget(MaterialApp(
            theme: theme,
            themeAnimationDuration: Duration.zero,
            navigatorKey: navigator,
            home: Scaffold(body: _content(rootKey, rootPulse)),
          ));
          await tester.pumpAndSettle();
          route = MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: _content(topKey, topPulse)),
          );
          navigator.currentState!.push<void>(route);
          await tester.pump();
          await tester.pump();

          final key = primaryPop ? topKey : rootKey;
          final pulse = primaryPop ? topPulse : rootPulse;
          if (primaryPop) {
            await tester.pumpAndSettle();
            final settledPaints = pulse.paints;
            pulse.invalidate();
            await tester.pump();
            expect(pulse.paints, greaterThan(settledPaints),
                reason: 'A settled page must paint live before the pop.');
            navigator.currentState!.pop();
            await tester.pump();
          }

          await tester.pump(const Duration(milliseconds: 30));
          expect(route.animation!.status,
              primaryPop ? AnimationStatus.reverse : AnimationStatus.forward);
          if (primaryPop) {
            expect(route.secondaryAnimation!.status, AnimationStatus.dismissed,
                reason: 'This is the top route own pop, not a cover/uncover animation.');
          }
          final firstOpacity = _opacity(tester, key);
          final before = pulse.paints;
          pulse.invalidate();
          await tester.pump(const Duration(milliseconds: 45));
          final secondOpacity = _opacity(tester, key);
          expect(secondOpacity, lessThan(firstOpacity),
              reason: 'The production outer fade must keep advancing.');
          expect(pulse.paints, before,
              reason: 'Only outgoing content should stay cached while outer fade moves.');
          await tester.pumpAndSettle();
          if (primaryPop) {
            expect(find.byKey(topKey), findsNothing);
          } else {
            navigator.currentState!.pop();
            await tester.pumpAndSettle();
            final restored = pulse.paints;
            pulse.invalidate();
            await tester.pump();
            expect(pulse.paints, greaterThan(restored),
                reason: 'The surviving root must release its transition cache.');
          }
          expect(tester.takeException(), isNull);
        } finally {
          navigator.currentState?.popUntil((route) => route.isFirst);
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
          rootPulse.dispose();
          topPulse.dispose();
          PageTransitionStyleStore.resetForTest(previousStyle);
        }
      },
    );
  }
}
