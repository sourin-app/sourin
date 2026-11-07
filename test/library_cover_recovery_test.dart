import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/library_cover_recovery.dart';

void main() {
  test(
    'coalesces concurrent views, shares results and throttles repeat work',
    () async {
      var now = DateTime(2026);
      var calls = 0;
      var completion = Completer<int>();
      final recovery = CoverRepairCoordinator(() {
        calls++;
        return completion.future;
      }, now: () => now);
      final home = recovery.repair();
      final library = recovery.repair();
      expect(calls, 1);
      completion.complete(3);
      expect(await home, 3);
      expect(await library, 3);
      expect(await recovery.repair(), 0);
      expect(calls, 1);
      now = now.add(const Duration(minutes: 1));
      completion = Completer<int>()..complete(2);
      expect(await recovery.repair(), 2);
      expect(calls, 2);
    },
  );

  test(
    'synchronous failures leave coordinator retryable after cooldown',
    () async {
      var now = DateTime(2026);
      var calls = 0;
      final recovery = CoverRepairCoordinator(() {
        if (++calls == 1) throw StateError('unavailable');
        return Future.value(1);
      }, now: () => now);
      expect(await recovery.repair(), 0);
      now = now.add(const Duration(minutes: 1));
      expect(await recovery.repair(), 1);
      expect(calls, 2);
    },
  );
}
