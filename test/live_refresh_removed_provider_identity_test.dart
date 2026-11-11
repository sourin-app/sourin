// Parent identity/restoration contract. Native Player creation remains disabled.
// The real onUserPause success callback supplies an already accepted pause;
// this file does not claim to verify the preceding native pause command.
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

import 'support/live_selection_fixture.dart';

LiveEmbeddedPlayer _embedded(WidgetTester tester) =>
    tester.widget<LiveEmbeddedPlayer>(find.byType(LiveEmbeddedPlayer));

Future<void> _acceptPauseAndConfirmSameProvider(
  WidgetTester tester,
  LiveSelectionScene scene,
) async {
  final before = List.of(scene.streamRequests);
  expect(_embedded(tester).onUserPause, isNotNull);
  // Invoke the production child's actual successful-user-command callback.
  // Parent intent is private; the subsequent real refresh/build observes it.
  _embedded(tester).onUserPause!(true);
  await tester.runAsync(
    () => scene.key.currentState!.loadAll(keepSelection: true),
  );
  await scene.drain(tester);
  scene.expectSelected(tester, selectionProvider, selectionA);
  expect(
    _embedded(tester).playWhenReady,
    isFalse,
    reason: 'The actual parent callback must establish accepted pause intent',
  );
  expect(scene.streamUrl(tester), selectionUrl(selectionProvider, selectionA));
  expect(
    scene.streamRequests,
    before,
    reason:
        'Same-provider paused restoration must not resolve the stream again',
  );
}

void main() {
  testWidgets(
    'removing a paused selected provider cannot restore another provider by native id',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      await _acceptPauseAndConfirmSameProvider(tester, scene);
      final groups = scene.holdGroups();
      Future<void>? refreshing;
      await tester.runAsync(() async {
        refreshing = scene.key.currentState!.loadAll(keepSelection: true);
      });
      await scene.drain(tester);
      expect(groups.entered, isTrue);
      final onlyOtherProvider = <dynamic>[selectionGroups().last];
      await scene.complete(tester, groups, onlyOtherProvider);
      await tester.runAsync(() async => await refreshing);
      await scene.drain(tester);
      scene.expectSelected(tester, selectionOtherProvider, selectionA);
      expect(
        scene.streamRequests,
        [
          (provider: selectionProvider, channel: selectionA),
          (provider: selectionOtherProvider, channel: selectionA),
        ],
        reason: 'The newly chosen row must resolve against its actual surviving provider',
      );
      expect(
        scene.streamUrl(tester),
        selectionUrl(selectionOtherProvider, selectionA),
        reason: 'A removed provider stream cannot be retained under another row title',
      );
      expect(_embedded(tester).title, 'Other-provider channel A');
      expect(
        _embedded(tester).playWhenReady,
        isTrue,
        reason: 'A different provider is a new selection, not the old paused stream',
      );
    },
  );

  testWidgets(
    'same-provider refresh preserves accepted pause and its existing stream',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      await _acceptPauseAndConfirmSameProvider(tester, scene);
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
      expect(_embedded(tester).playWhenReady, isFalse);
      expect(scene.streamRequests, [
        (provider: selectionProvider, channel: selectionA),
      ]);
    },
  );

  testWidgets(
    'clicking another provider with the same native id uses new selection policy',
    (tester) async {
      final scene = LiveSelectionScene();
      await scene.mount(tester);
      await _acceptPauseAndConfirmSameProvider(tester, scene);
      await scene.pick(tester, selectionOtherProvider, selectionA);
      expect(
        scene.streamUrl(tester),
        selectionUrl(selectionOtherProvider, selectionA),
      );
      expect(_embedded(tester).title, 'Other-provider channel A');
      expect(_embedded(tester).playWhenReady, isTrue);
      expect(scene.streamRequests, [
        (provider: selectionProvider, channel: selectionA),
        (provider: selectionOtherProvider, channel: selectionA),
      ]);
    },
  );
}
