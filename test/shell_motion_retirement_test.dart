import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';

// Observe the production shell's painted slots, not its diagnostic fields.
// A stopped enter animation alone cannot prove that the outgoing page is gone.
void main() {
  setUp(() => UiPrefs.debugResetForTest());
  tearDown(() {
    UiPrefs.debugResetForTest();
    PageTransitionStyleStore.syncFromPrefs();
  });

  for (final scenario in [
    (style: PageTransitionStyle.none, reduced: false, animated: false),
    (style: PageTransitionStyle.slideRight, reduced: true, animated: false),
    (style: PageTransitionStyle.slideRight, reduced: false, animated: true),
  ]) {
    testWidgets(
      'shell retires the outgoing page for ${scenario.style.name}, '
      'reduced=${scenario.reduced}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        PageTransitionStyleStore.set(scenario.style);
        final theme = AppTheme.themeFor(Brightness.dark);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: scenario.reduced,
              ),
              child: AppThemeHost(data: theme, child: child!),
            ),
            home: ShellPage(key: debugShellKey),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(HomePage), findsOneWidget);
        expect(tester.takeException(), isNull);

        final homeElement = find.byType(HomePage).evaluate().single;
        debugShellKey.currentState!.debugSwitchTo(AppTab.search);
        await tester.pump();

        final outgoing = tester.widget<Offstage>(
          find.byKey(const ValueKey<AppTab>(AppTab.home)),
        );
        expect(outgoing.offstage, !scenario.animated);
        expect(find.byType(SearchPage), findsOneWidget);
        expect(
          find.byType(HomePage, skipOffstage: false).evaluate().single,
          same(homeElement),
          reason: 'Immediate retirement must preserve the page state.',
        );
        if (!scenario.animated) {
          expect(find.byType(HomePage), findsNothing);
        }

        await tester.pump(Motion.base);
        await tester.pump();
        expect(find.byType(HomePage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
