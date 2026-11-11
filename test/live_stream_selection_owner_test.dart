// Cache and StreamPreparer remain enabled across overlapping channel requests.
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';

import 'support/live_selection_fixture.dart';

void main() {
  for (final oldFailure in [false, true]) {
    testWidgets(
      'A-B-A ignores the first A ${oldFailure ? 'failure' : 'success'} after the newest result',
      (tester) async {
        final scene = LiveSelectionScene();
        final oldA = scene.holdStream(selectionProvider, selectionA);
        await scene.mount(tester, initialStreamHeld: true);
        expect(oldA.entered, isTrue);
        await scene.pick(tester, selectionProvider, selectionB);
        expect(
          scene.streamUrl(tester),
          selectionUrl(selectionProvider, selectionB),
        );
        final newA = scene.holdStream(selectionProvider, selectionA);
        await scene.pick(tester, selectionProvider, selectionA);
        expect(newA.entered, isTrue);
        expect(scene.streamRequests, [
          (provider: selectionProvider, channel: selectionA),
          (provider: selectionProvider, channel: selectionB),
          (provider: selectionProvider, channel: selectionA),
        ]);
        await scene.complete(
          tester,
          newA,
          selectionStream(selectionProvider, selectionA, 'new'),
        );
        expect(
          scene.streamUrl(tester),
          selectionUrl(selectionProvider, selectionA, 'new'),
        );
        await scene.complete(
          tester,
          oldA,
          selectionStream(selectionProvider, selectionA, 'old'),
          failure: oldFailure,
        );
        scene.expectSelected(tester, selectionProvider, selectionA);
        expect(
          scene.streamUrl(tester),
          selectionUrl(selectionProvider, selectionA, 'new'),
          reason: 'An older selection epoch cannot replace or clear the accepted result',
        );
        if (!oldFailure) {
          late List<StreamCandidate> cached;
          final reads = scene.streamRequests.length;
          await tester.runAsync(() async {
            cached = await SourinApi.getLiveStream(
              selectionProvider,
              selectionA,
            );
          });
          expect(
            scene.streamRequests.length,
            reads,
            reason:
                'The accepted result should remain in the ordinary TTL cache',
          );
          expect(
            cached.single.url,
            selectionUrl(selectionProvider, selectionA, 'new'),
            reason: 'UI ownership alone cannot protect the next cache consumer',
          );
        }
      },
    );
  }

  testWidgets(
    'late A is ignored while a different native channel is selected',
    (tester) async {
      final scene = LiveSelectionScene();
      final oldA = scene.holdStream(selectionProvider, selectionA);
      await scene.mount(tester, initialStreamHeld: true);
      await scene.pick(tester, selectionProvider, selectionB);
      await scene.complete(
        tester,
        oldA,
        selectionStream(selectionProvider, selectionA, 'old'),
      );
      scene.expectSelected(tester, selectionProvider, selectionB);
      expect(
        scene.streamUrl(tester),
        selectionUrl(selectionProvider, selectionB),
      );
    },
  );

  testWidgets(
    'late same-id A from another provider cannot replace the clicked provider',
    (tester) async {
      final scene = LiveSelectionScene();
      final oldA = scene.holdStream(selectionProvider, selectionA);
      await scene.mount(tester, initialStreamHeld: true);
      await scene.pick(tester, selectionOtherProvider, selectionA);
      await scene.complete(
        tester,
        oldA,
        selectionStream(selectionProvider, selectionA, 'old'),
      );
      scene.expectSelected(tester, selectionOtherProvider, selectionA);
      expect(
        scene.streamUrl(tester),
        selectionUrl(selectionOtherProvider, selectionA),
      );
    },
  );

  testWidgets(
    'a current held stream result is accepted without a competing selection',
    (tester) async {
      final scene = LiveSelectionScene();
      final currentA = scene.holdStream(selectionProvider, selectionA);
      await scene.mount(tester, initialStreamHeld: true);
      await scene.complete(
        tester,
        currentA,
        selectionStream(selectionProvider, selectionA, 'current'),
      );
      scene.expectSelected(tester, selectionProvider, selectionA);
      expect(
        scene.streamUrl(tester),
        selectionUrl(selectionProvider, selectionA, 'current'),
      );
      expect(scene.streamRequests, [
        (provider: selectionProvider, channel: selectionA),
      ]);
    },
  );
}
