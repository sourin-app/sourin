import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku.dart';

import 'danmaku_proxy_test_support.dart';

void main() {
  late DanmakuProxyFixture fixture;
  setUp(() {
    fixture = DanmakuProxyFixture()..install();
  });
  tearDown(() => fixture.restore());

  // The original six outcome cases now stimulate actual global settings.
  // They retain the late-result, persisted service and editable draft contract.
  for (final edit in [GlobalEdit.mode, GlobalEdit.address]) {
    for (final outcome in ServiceOutcome.values) {
      testWidgets(
        '${edit == GlobalEdit.address ? 'editing global proxy address' : 'switching global proxy mode'} discards old ${outcome.name} service probe after return',
        (tester) async {
          await fixture.mount(tester);
          await fixture.draft(tester);
          await fixture.startProbe(tester,
              endpoint: draftService, token: draftToken);
          try {
            await fixture.openGlobal(tester);
            await fixture.editGlobal(tester, edit);
            await fixture.closeGlobal(tester);
            fixture.expectSaved(savedService, savedToken);
            fixture.expectDraft(tester, draftService, draftToken);
            fixture.expectIdle(tester);
            fixture.finish(0, outcome);
            await frames(tester);
            expect(find.textContaining(staleVersion), findsNothing);
            expect(find.textContaining(staleError), findsNothing);
            final offline = DanmakuLocalStatus(
              online: false,
              endpoint: fixture.calls.single.endpoint,
            );
            expect(find.text(offline.line), findsNothing);
            fixture.expectSaved(savedService, savedToken);
            fixture.expectDraft(tester, draftService, draftToken);
            fixture.expectIdle(tester);
            fixture.expectGlobal(edit);
            expect(fixture.calls, hasLength(1),
                reason: 'Global navigation starts no replacement service probe');
            expect(tester.takeException(), isNull);
          } finally {
            fixture.releasePending();
            await tester.pump();
          }
        },
      );
    }
  }

  // The original four old/new interleavings now distinguish both service
  // endpoint and Token values, so stale persistence cannot hide behind equality.
  for (final edit in [GlobalEdit.mode, GlobalEdit.address]) {
    for (final oldThrows in [false, true]) {
      testWidgets(
        '${edit == GlobalEdit.address ? 'editing global proxy address' : 'switching global proxy mode'} keeps newer service result after old ${oldThrows ? 'exception' : 'success'}',
        (tester) async {
          await fixture.mount(tester);
          await fixture.draft(tester);
          await fixture.startProbe(tester,
              endpoint: draftService, token: draftToken);
          try {
            await fixture.openGlobal(tester);
            await fixture.editGlobal(tester, edit);
            await fixture.closeGlobal(tester);
            fixture.expectSaved(savedService, savedToken);
            fixture.expectDraft(tester, draftService, draftToken);
            fixture.expectIdle(tester);
            await fixture.draft(tester,
                endpoint: nextService, token: nextToken);
            await fixture.startProbe(tester,
                endpoint: nextService, token: nextToken);
            expect(fixture.calls, hasLength(2));
            expect(fixture.calls[0].endpoint?.baseUrl, draftService);
            expect(fixture.calls[0].endpoint?.token, draftToken);
            fixture.finish(1, ServiceOutcome.success, version: currentVersion);
            await frames(tester);
            expect(find.textContaining(currentVersion), findsOneWidget);
            fixture.expectSaved(nextService, nextToken);
            fixture.expectDraft(tester, nextService, nextToken);
            fixture.expectIdle(tester);
            fixture.finish(0, oldThrows
                ? ServiceOutcome.exception
                : ServiceOutcome.success);
            await frames(tester);
            expect(find.textContaining(currentVersion), findsOneWidget,
                reason: 'The newest successful request owns the rendered result');
            expect(find.textContaining(staleVersion), findsNothing);
            expect(find.textContaining(staleError), findsNothing);
            fixture.expectSaved(nextService, nextToken);
            fixture.expectDraft(tester, nextService, nextToken);
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
}
