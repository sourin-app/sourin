// Actual LivePage, raw core replies and rendered row/stream observations.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/live_page.dart';

import 'support/live_selection_fixture.dart';

Future<({Future<void> done})> startRefresh(
  WidgetTester tester,
  LiveSelectionScene scene, {
  bool keepSelection = true,
}) async {
  late Future<void> refresh;
  await tester.runAsync(() async {
    refresh = scene.key.currentState!.loadAll(keepSelection: keepSelection);
  });
  await scene.drain(tester);
  return (done: refresh);
}

void main() {
  testWidgets('overlapping notifications drain one fresh membership request', (
    tester,
  ) async {
    final scene = LiveSelectionScene();
    await scene.mount(tester);
    await scene.pick(tester, selectionProvider, selectionB);
    final first = scene.holdGroups();
    final active = (await startRefresh(tester, scene)).done;
    final trailing = scene.holdGroups();
    var completed = 0;
    final queued = <Future<void>>[];
    for (var i = 0; i < 3; i++) {
      queued.add(
        (await startRefresh(tester, scene)).done.then((_) {
          completed++;
        }),
      );
    }
    expect(scene.groupReads, 2, reason: 'Membership requests remain serial');
    expect(trailing.entered, isFalse);
    expect(
      completed,
      0,
      reason: 'A refresh caller waits for the accepted update',
    );
    await scene.complete(tester, first, selectionGroups());
    expect(scene.groupReads, 3, reason: 'The notification cannot be dropped');
    expect(trailing.entered, isTrue);
    expect(completed, 0);
    await scene.complete(tester, trailing, selectionGroups(includeB: false));
    await tester.runAsync(() async => await Future.wait([active, ...queued]));
    await scene.drain(tester);
    expect(completed, 3);
    expect(scene.groupReads, 3, reason: 'Concurrent notifications coalesce');
    scene.expectSelected(tester, selectionProvider, selectionA);
    expect(
      scene.streamUrl(tester),
      selectionUrl(selectionProvider, selectionA),
    );
    expect(
      find.byKey(liveChannelTileKey(selectionProvider, selectionB)),
      findsNothing,
    );
  });

  testWidgets(
    'a failed active request still drains a queued successful refresh',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      final first = scene.holdGroups();
      final active = (await startRefresh(tester, scene)).done;
      final trailing = scene.holdGroups();
      final queued = (await startRefresh(tester, scene)).done;
      await scene.complete(tester, first, null, failure: true);
      expect(trailing.entered, isTrue);
      await scene.complete(tester, trailing, selectionGroups());
      await tester.runAsync(() async => await Future.wait([active, queued]));
      await scene.drain(tester);
      expect(scene.groupReads, 3);
      scene.expectSelected(tester, selectionProvider, selectionA);
      expect(
        scene.streamUrl(tester),
        selectionUrl(selectionProvider, selectionA),
      );
      expect(find.text('这次没能取到直播频道。点重试再拉一次。'), findsNothing);
    },
  );

  testWidgets(
    'a notification during the trailing response schedules another read',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      final first = scene.holdGroups();
      final active = (await startRefresh(tester, scene)).done;
      final second = scene.holdGroups();
      final queued = (await startRefresh(tester, scene)).done;
      await scene.complete(tester, first, selectionGroups());
      expect(second.entered, isTrue);
      final third = scene.holdGroups();
      final later = (await startRefresh(tester, scene)).done;
      expect(scene.groupReads, 3);
      expect(third.entered, isFalse);
      await scene.complete(tester, second, selectionGroups());
      expect(third.entered, isTrue);
      await scene.complete(tester, third, selectionGroups(includeB: false));
      await tester.runAsync(
        () async => await Future.wait([active, queued, later]),
      );
      await scene.drain(tester);
      expect(scene.groupReads, 4);
      expect(
        find.byKey(liveChannelTileKey(selectionProvider, selectionB)),
        findsNothing,
      );
    },
  );

  testWidgets(
    'an explicit selection reset is retained across preserving notifications',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      await scene.pick(tester, selectionProvider, selectionB);
      final first = scene.holdGroups();
      final active = (await startRefresh(tester, scene)).done;
      final trailing = scene.holdGroups();
      final reset = (await startRefresh(
        tester,
        scene,
        keepSelection: false,
      )).done;
      final preserving = (await startRefresh(tester, scene)).done;
      await scene.complete(tester, first, selectionGroups());
      expect(trailing.entered, isTrue);
      await scene.complete(tester, trailing, selectionGroups());
      await tester.runAsync(
        () async => await Future.wait([active, reset, preserving]),
      );
      await scene.drain(tester);
      scene.expectSelected(tester, selectionProvider, selectionA);
      expect(
        scene.streamUrl(tester),
        selectionUrl(selectionProvider, selectionA),
      );
      expect(scene.groupReads, 3);
    },
  );

  testWidgets(
    'disposal retires queued work and releases every refresh caller',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      final first = scene.holdGroups();
      final active = (await startRefresh(tester, scene)).done;
      final trailing = scene.holdGroups();
      final queued = (await startRefresh(tester, scene)).done;
      await tester.pumpWidget(const SizedBox.shrink());
      await scene.complete(tester, first, selectionGroups());
      await tester.runAsync(() async => await Future.wait([active, queued]));
      await scene.drain(tester);
      expect(scene.groupReads, 2);
      expect(trailing.entered, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a single completed refresh does not request redundant membership',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      final first = scene.holdGroups();
      final active = (await startRefresh(tester, scene)).done;
      await scene.complete(tester, first, selectionGroups());
      await tester.runAsync(() async => await active);
      await scene.drain(tester);
      expect(scene.groupReads, 2);
      scene.expectSelected(tester, selectionProvider, selectionA);
    },
  );
}
