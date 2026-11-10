import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/settings/danmaku_source_page.dart';
import 'package:sourin_spike/ui/settings/global_proxy_settings_page.dart';

import 'danmaku_proxy_test_support.dart';

void main() {
  late DanmakuProxyFixture fixture;
  setUp(() {
    fixture = DanmakuProxyFixture()..install();
  });
  tearDown(() => fixture.restore());

  for (final edit in [GlobalEdit.mode, GlobalEdit.address, GlobalEdit.none]) {
    for (final outcome in [ServiceOutcome.success, ServiceOutcome.exception]) {
      testWidgets(
        '${edit.name}: an old service ${outcome.name} cannot publish before the global route pops',
        (tester) async {
          await fixture.mount(tester);
          await fixture.draft(tester);
          await fixture.startProbe(tester,
              endpoint: draftService, token: draftToken);
          fixture.expectSaved(savedService, savedToken);
          try {
            await fixture.openGlobal(tester);
            await fixture.editGlobal(tester, edit);
            fixture.expectSaved(savedService, savedToken);
            fixture.expectDraft(tester, draftService, draftToken, hidden: true);
            // Complete while the real child route is still on top. Checking
            // only after pop would let its UI invalidation conceal a bad write.
            fixture.finish(0, outcome);
            await frames(tester);
            expect(find.byType(GlobalProxySettingsPage), findsOneWidget);
            expect(find.byType(DanmakuSourcePage), findsNothing);
            fixture.expectSaved(savedService, savedToken);
            fixture.expectDraft(tester, draftService, draftToken, hidden: true);
            fixture.expectIdle(tester, hidden: true);
            expect(find.textContaining(staleVersion, skipOffstage: false),
                findsNothing);
            expect(find.textContaining(staleError, skipOffstage: false),
                findsNothing);
            fixture.expectGlobal(edit);
            expect(fixture.calls, hasLength(1));
            await fixture.closeGlobal(tester);
            fixture.expectSaved(savedService, savedToken);
            fixture.expectDraft(tester, draftService, draftToken);
            fixture.expectIdle(tester);
            expect(find.textContaining(staleVersion), findsNothing);
            expect(find.textContaining(staleError), findsNothing);
            // Cancellation does not erase the user's draft. A new explicit
            // current test can still succeed, render, and persist both fields.
            await fixture.startProbe(tester,
                endpoint: draftService, token: draftToken);
            fixture.finish(1, ServiceOutcome.success, version: currentVersion);
            await frames(tester);
            expect(find.textContaining(currentVersion), findsOneWidget);
            fixture.expectSaved(draftService, draftToken);
            fixture.expectDraft(tester, draftService, draftToken);
            fixture.expectIdle(tester);
            fixture.expectGlobal(edit);
            expect(fixture.calls, hasLength(2));
            expect(tester.takeException(), isNull);
          } finally {
            fixture.releasePending();
            await tester.pump();
          }
        },
      );
    }
  }

  for (final outcome in ServiceOutcome.values) {
    testWidgets('unchanged current service ${outcome.name} remains legitimate', (
      tester,
    ) async {
      await fixture.mount(tester);
      await fixture.draft(tester);
      await fixture.startProbe(tester,
          endpoint: draftService, token: draftToken);
      fixture.finish(0, outcome,
          version: currentVersion, error: currentError);
      await frames(tester);
      fixture.expectDraft(tester, draftService, draftToken);
      fixture.expectIdle(tester);
      if (outcome == ServiceOutcome.success) {
        expect(find.textContaining(currentVersion), findsOneWidget,
            reason: 'Positive control: a current probe must render and persist');
        fixture.expectSaved(draftService, draftToken);
      } else {
        fixture.expectSaved(savedService, savedToken);
        if (outcome == ServiceOutcome.exception) {
          expect(find.textContaining(currentError), findsOneWidget,
              reason: 'Positive control: the structured exception path renders');
        } else {
          expect(find.textContaining('未运行'), findsOneWidget,
              reason: 'Positive control: a current offline result is displayed');
        }
      }
      fixture.expectGlobal(GlobalEdit.none);
      expect(fixture.calls, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an unchanged global visit preserves service drafts without writes or automatic probes', (
    tester,
  ) async {
    await fixture.mount(tester);
    await fixture.draft(tester);
    await fixture.openGlobal(tester);
    fixture.expectSaved(savedService, savedToken);
    fixture.expectDraft(tester, draftService, draftToken, hidden: true);
    await fixture.closeGlobal(tester);
    fixture.expectSaved(savedService, savedToken);
    fixture.expectDraft(tester, draftService, draftToken);
    fixture.expectIdle(tester);
    fixture.expectGlobal(GlobalEdit.none);
    expect(fixture.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
