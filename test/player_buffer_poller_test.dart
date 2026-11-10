import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/player/player_buffer_poller.dart';

const _interval = Duration(milliseconds: 500);

void main() {
  test(
    'changed span or percent is delivered even with the same cache endpoint',
    () {
      fakeAsync((clock) {
        final values = <String, double?>{
          'demuxer-cache-time': 30,
          'cache-buffering-state': 100,
          'demuxer-cache-duration': 25,
        };
        final samples = <(Duration?, double?, double?)>[];
        final poller = PlayerBufferPoller(
          read: (key) async => values[key],
          onChanged: (end, percent, span) => samples.add((end, percent, span)),
        )..start();
        clock.elapse(_interval);
        expect(samples, [(const Duration(seconds: 30), 100, 25)]);
        values['demuxer-cache-duration'] = 24;
        clock.elapse(_interval);
        expect(samples.last, (const Duration(seconds: 30), 100, 24));
        values['cache-buffering-state'] = 80;
        clock.elapse(_interval);
        expect(samples.last, (const Duration(seconds: 30), 80, 24));
        expect(samples, hasLength(3));
        clock.elapse(_interval * 2);
        expect(samples, hasLength(3));
        poller.stop();
      });
    },
  );

  test('slow property requests never overlap another polling cycle', () {
    fakeAsync((clock) {
      final first = Completer<double?>();
      final reads = <String>[];
      final samples = <Duration?>[];
      final poller = PlayerBufferPoller(
        read: (key) {
          reads.add(key);
          return key == 'demuxer-cache-time' ? first.future : Future.value(10);
        },
        onChanged: (end, _, __) => samples.add(end),
      )..start();
      clock.elapse(_interval * 4);
      expect(reads, ['demuxer-cache-time']);
      first.complete(20);
      clock.flushMicrotasks();
      expect(reads, [
        'demuxer-cache-time',
        'cache-buffering-state',
        'demuxer-cache-duration',
      ]);
      expect(samples, [const Duration(seconds: 20)]);
      poller.stop();
    });
  });

  test(
    'stop drops the pending sample and does not read its remaining properties',
    () {
      fakeAsync((clock) {
        final first = Completer<double?>();
        final reads = <String>[];
        final samples = <Duration?>[];
        final poller = PlayerBufferPoller(
          read: (key) {
            reads.add(key);
            return first.future;
          },
          onChanged: (end, _, __) => samples.add(end),
        )..start();
        clock.elapse(_interval);
        poller.stop();
        first.complete(20);
        clock.flushMicrotasks();
        clock.elapse(_interval * 2);
        expect(reads, ['demuxer-cache-time']);
        expect(samples, isEmpty);
        expect(poller.running, isFalse);
      });
    },
  );

  test(
    'restart ignores a previous session sample and publishes the current one',
    () {
      fakeAsync((clock) {
        final old = Completer<double?>();
        var first = true;
        final samples = <Duration?>[];
        final poller = PlayerBufferPoller(
          read: (key) {
            if (first) {
              first = false;
              return old.future;
            }
            return Future.value(key == 'demuxer-cache-time' ? 40 : 10);
          },
          onChanged: (end, _, __) => samples.add(end),
        )..start();
        clock.elapse(_interval);
        poller.stop();
        poller.start();
        old.complete(20);
        clock.flushMicrotasks();
        expect(samples, isEmpty);
        clock.elapse(_interval);
        expect(samples, [const Duration(seconds: 40)]);
        poller.clear();
        expect(poller.running, isFalse);
      });
    },
  );

  test(
    'unavailable and invalid endpoints clear once and valid readings recover',
    () {
      fakeAsync((clock) {
        double? end = 20;
        final samples = <Duration?>[];
        final poller = PlayerBufferPoller(
          read: (key) async => key == 'demuxer-cache-time' ? end : 10,
          onChanged: (value, _, __) => samples.add(value),
        )..start();
        clock.elapse(_interval);
        end = null;
        clock.elapse(_interval * 2);
        expect(samples, [const Duration(seconds: 20), null]);
        end = double.nan;
        clock.elapse(_interval);
        expect(samples, hasLength(2));
        end = double.infinity;
        clock.elapse(_interval);
        expect(samples, hasLength(2));
        end = 1e308;
        clock.elapse(_interval);
        expect(samples, hasLength(2));
        end = 21;
        clock.elapse(_interval);
        expect(samples.last, const Duration(seconds: 21));
        poller.clear();
      });
    },
  );
  for (final pendingKey in [
    'cache-buffering-state',
    'demuxer-cache-duration',
  ]) {
    test('stop also cancels a sample while $pendingKey is pending', () {
      fakeAsync((clock) {
        final pending = Completer<double?>();
        final reads = <String>[];
        final samples = <Duration?>[];
        final poller = PlayerBufferPoller(
          read: (key) {
            reads.add(key);
            return key == pendingKey ? pending.future : Future.value(10);
          },
          onChanged: (end, _, __) => samples.add(end),
        )..start();
        clock.elapse(_interval);
        expect(reads.last, pendingKey);
        final count = reads.length;
        poller.stop();
        pending.complete(5);
        clock.flushMicrotasks();
        expect(reads, hasLength(count));
        expect(samples, isEmpty);
      });
    });
  }

  test('invalid cache spans are unavailable and valid readings recover', () {
    fakeAsync((clock) {
      double? span = 10;
      final samples = <(Duration?, double?)>[];
      final poller = PlayerBufferPoller(
        read: (key) async => switch (key) {
          'demuxer-cache-time' => 20,
          'demuxer-cache-duration' => span,
          _ => 100,
        },
        onChanged: (end, _, value) => samples.add((end, value)),
      )..start();
      clock.elapse(_interval);
      expect(samples.single, (const Duration(seconds: 20), 10));
      for (final invalid in [double.nan, double.infinity, -1.0, 1e308]) {
        span = invalid;
        clock.elapse(_interval);
        expect(samples.last, (const Duration(seconds: 20), null));
      }
      expect(samples, hasLength(2));
      span = 9;
      clock.elapse(_interval);
      expect(samples.last, (const Duration(seconds: 20), 9));
      poller.clear();
    });
  });

  test(
    'start is idempotent and resume publishes unchanged cache data again',
    () {
      fakeAsync((clock) {
        var reads = 0;
        final samples = <Duration?>[];
        final poller =
            PlayerBufferPoller(
                read: (_) async {
                  reads++;
                  return 10;
                },
                onChanged: (end, _, __) => samples.add(end),
              )
              ..start()
              ..start();
        clock.elapse(_interval);
        expect(reads, 3);
        expect(samples, [const Duration(seconds: 10)]);
        poller.stop();
        clock.elapse(_interval * 2);
        expect(reads, 3);
        poller.start();
        clock.elapse(_interval);
        expect(reads, 6);
        expect(samples, [
          const Duration(seconds: 10),
          const Duration(seconds: 10),
        ]);
        poller.clear();
      });
    },
  );
}
