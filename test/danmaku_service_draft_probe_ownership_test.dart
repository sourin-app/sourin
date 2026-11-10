import 'package:flutter_test/flutter_test.dart';

import 'danmaku_proxy_test_support.dart';

void main() {
  late DanmakuProxyFixture fixture;
  setUp(() {
    fixture = DanmakuProxyFixture()..install();
  });
  tearDown(() => fixture.restore());

  for (final editToken in [false, true]) {
    for (final outcome in ServiceOutcome.values) {
      testWidgets(
        'editing the service ${editToken ? 'Token' : 'endpoint'} rejects an old ${outcome.name} without changing saved fields',
        (tester) async {
          await fixture.mount(tester);
          await fixture.draft(tester);
          await fixture.startProbe(tester,
              endpoint: draftService, token: draftToken);
          try {
            final editor = editToken ? serviceToken() : serviceUrl();
            await tester.ensureVisible(editor);
            await tester.enterText(editor,
                editToken ? nextToken : nextService);
            await tester.pump();
            fixture.expectIdle(tester);
            fixture.expectSaved(savedService, savedToken);
            fixture.expectDraft(tester,
                editToken ? draftService : nextService,
                editToken ? nextToken : draftToken);
            fixture.finish(0, outcome);
            await frames(tester);
            expect(find.textContaining(staleVersion), findsNothing);
            expect(find.textContaining(staleError), findsNothing);
            expect(find.textContaining('未运行'), findsNothing);
            fixture.expectSaved(savedService, savedToken);
            fixture.expectDraft(tester,
                editToken ? draftService : nextService,
                editToken ? nextToken : draftToken);
            fixture.expectIdle(tester);
            fixture.expectGlobal(GlobalEdit.none);
            expect(fixture.calls, hasLength(1));
            expect(fixture.calls.single.endpoint?.baseUrl, draftService);
            expect(fixture.calls.single.endpoint?.token, draftToken,
                reason: 'The old probe captured both inputs when dispatched');
            expect(tester.takeException(), isNull);
          } finally {
            fixture.releasePending();
            await tester.pump();
          }
        },
      );
    }
  }

  for (final editToken in [false, true]) {
    for (final oldThrows in [false, true]) {
      testWidgets(
        'editing the service ${editToken ? 'Token' : 'endpoint'} keeps a newer result after old ${oldThrows ? 'exception' : 'success'}',
        (tester) async {
          await fixture.mount(tester);
          await fixture.draft(tester);
          await fixture.startProbe(tester,
              endpoint: draftService, token: draftToken);
          try {
            final editor = editToken ? serviceToken() : serviceUrl();
            await tester.ensureVisible(editor);
            await tester.enterText(editor,
                editToken ? nextToken : nextService);
            await tester.pump();
            fixture.expectIdle(tester);
            final currentEndpoint = editToken ? draftService : nextService;
            final currentToken = editToken ? nextToken : draftToken;
            await fixture.startProbe(tester,
                endpoint: currentEndpoint, token: currentToken);
            fixture.finish(1, ServiceOutcome.success, version: currentVersion);
            await frames(tester);
            expect(find.textContaining(currentVersion), findsOneWidget);
            fixture.expectSaved(currentEndpoint, currentToken);
            fixture.finish(0, oldThrows
                ? ServiceOutcome.exception
                : ServiceOutcome.success);
            await frames(tester);
            expect(find.textContaining(currentVersion), findsOneWidget);
            expect(find.textContaining(staleVersion), findsNothing);
            expect(find.textContaining(staleError), findsNothing);
            fixture.expectSaved(currentEndpoint, currentToken);
            fixture.expectDraft(tester, currentEndpoint, currentToken);
            fixture.expectIdle(tester);
            fixture.expectGlobal(GlobalEdit.none);
            expect(fixture.calls, hasLength(2));
            expect(fixture.calls[0].endpoint?.baseUrl, draftService);
            expect(fixture.calls[0].endpoint?.token, draftToken);
            expect(fixture.calls[1].endpoint?.baseUrl, currentEndpoint);
            expect(fixture.calls[1].endpoint?.token, currentToken);
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
