// Uses actual LivePage and real row taps across a delayed membership refresh.
import 'package:flutter_test/flutter_test.dart';

import 'support/live_selection_fixture.dart';

void main() {
  testWidgets('a held list refresh cannot replace a newer clicked selection', (
    tester,
  ) async {
    final scene = LiveSelectionScene();
    await scene.mount(tester);
    final groups = scene.holdGroups();
    Future<void>? refreshing;
    await tester.runAsync(() async {
      refreshing = scene.key.currentState!.loadAll(keepSelection: true);
    });
    await scene.drain(tester);
    expect(groups.entered, isTrue);
    expect(scene.groupReads, 2);
    await scene.pick(tester, selectionProvider, selectionB);
    expect(
      scene.streamUrl(tester),
      selectionUrl(selectionProvider, selectionB),
    );
    final requestsBeforeResponse = List.of(scene.streamRequests);
    await scene.complete(tester, groups, selectionGroups());
    await tester.runAsync(() async => await refreshing);
    await scene.drain(tester);
    scene.expectSelected(tester, selectionProvider, selectionB);
    expect(
      scene.streamUrl(tester),
      selectionUrl(selectionProvider, selectionB),
    );
    expect(
      scene.streamRequests,
      requestsBeforeResponse,
      reason:
          'Refreshing unchanged membership must not request a different row',
    );
  });

  testWidgets(
    'a held unchanged refresh keeps the selection without a new click',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      final groups = scene.holdGroups();
      Future<void>? refreshing;
      await tester.runAsync(() async {
        refreshing = scene.key.currentState!.loadAll(keepSelection: true);
      });
      await scene.drain(tester);
      await scene.complete(tester, groups, selectionGroups());
      await tester.runAsync(() async => await refreshing);
      await scene.drain(tester);
      scene.expectSelected(tester, selectionProvider, selectionA);
      expect(
        scene.streamUrl(tester),
        selectionUrl(selectionProvider, selectionA),
      );
      expect(scene.groupReads, 2);
    },
  );

  testWidgets(
    'a refresh removes a newly clicked missing row with a real fallback',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      final groups = scene.holdGroups();
      Future<void>? refreshing;
      await tester.runAsync(() async {
        refreshing = scene.key.currentState!.loadAll(keepSelection: true);
      });
      await scene.drain(tester);
      await scene.pick(tester, selectionProvider, selectionB);
      await scene.complete(tester, groups, selectionGroups(includeB: false));
      await tester.runAsync(() async => await refreshing);
      await scene.drain(tester);
      scene.expectSelected(tester, selectionProvider, selectionA);
      expect(
        scene.streamUrl(tester),
        selectionUrl(selectionProvider, selectionA),
      );
    },
  );
}
