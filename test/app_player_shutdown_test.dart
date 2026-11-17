import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_player.dart';

void main() {
  test(
    'synchronous reentry observes the already registered release Future',
    () async {
      final registry = PlayerDisposalRegistry();
      final owner = Object();
      Future<void>? reentered;
      var calls = 0;
      registry.register(owner, () async {
        calls++;
        reentered = registry.dispose(owner);
      });
      final first = registry.dispose(owner);
      expect(identical(first, reentered), isTrue);
      await first;
      expect(calls, 1);
    },
  );

  test('shutdown waits for every active and already retiring player', () async {
    final registry = PlayerDisposalRegistry();
    final retired = Object(), live = Object(), preview = Object();
    final gates = [Completer<void>(), Completer<void>(), Completer<void>()];
    final calls = <Object>[];
    final owners = [retired, live, preview];
    for (var index = 0; index < owners.length; index++) {
      final owner = owners[index], gate = gates[index];
      registry.register(owner, () {
        calls.add(owner);
        return gate.future;
      });
    }
    final retiring = registry.dispose(retired);
    final shutdown = registry.shutdown();
    expect(registry.isClosing, isTrue);
    expect(identical(registry.shutdown(), shutdown), isTrue);
    expect(identical(registry.dispose(retired), retiring), isTrue);
    expect(calls, orderedEquals(owners));
    expect(() => registry.register(Object(), () async {}), throwsStateError);
    var closed = false;
    final close = shutdown.then((_) => closed = true);
    gates[1].complete();
    gates[2].complete();
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse, reason: 'A route disposal is still pending.');
    gates[0].complete();
    await close;
    expect(closed, isTrue);
    await registry.dispose(live);
    expect(calls, orderedEquals(owners));
  });

  test('a failed native release never authorizes engine destruction', () async {
    final registry = PlayerDisposalRegistry();
    final owner = Object();
    final failing = Completer<void>();
    registry.register(owner, () => failing.future);
    final shutdown = registry.shutdown();
    final expected = expectLater(shutdown, throwsStateError);
    failing.completeError(StateError('native release failed'));
    await expected;
    expect(registry.isClosing, isTrue);
    expect(identical(registry.shutdown(), shutdown), isTrue);
    await expectLater(registry.dispose(owner), throwsStateError);
  });

  test(
    'a synchronously failed release is reported through the shared Future',
    () async {
      final registry = PlayerDisposalRegistry();
      final owner = Object();
      var count = 0;
      registry.register(owner, () {
        count++;
        throw StateError('release rejected');
      });
      final pending = registry.dispose(owner);
      await expectLater(pending, throwsStateError);
      expect(identical(registry.dispose(owner), pending), isTrue);
      await expectLater(registry.shutdown(), throwsStateError);
      expect(count, 1);
    },
  );
}
