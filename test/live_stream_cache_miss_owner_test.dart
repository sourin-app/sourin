// Independent API-level schedules extending the existing cache tests in
// test/t27_w6_live_switch_timing_test.dart. No widget/native player is mounted.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';

const _provider = 'cache-owner-fixture';
const _channel = 'one';

String _url(String revision) => 'https://cache-owner.invalid/$revision.mp4';

class _Miss {
  final entered = Completer<void>();
  final result = Completer<List<StreamCandidate>>();

  Future<void> get started =>
      entered.future.timeout(const Duration(seconds: 3));

  void succeed(String revision) {
    if (!result.isCompleted) {
      result.complete([StreamCandidate(url: _url(revision), kind: 'mp4')]);
    }
  }
}

class _CacheMissFixture {
  final queued = <_Miss>[];
  final all = <_Miss>[];
  final pending = <Future<List<StreamCandidate>>>[];
  final unexpected = <String>[];
  int requests = 0;

  _Miss hold() {
    final miss = _Miss();
    queued.add(miss);
    all.add(miss);
    return miss;
  }

  Future<List<StreamCandidate>> fetch(String provider, String channel) async {
    requests++;
    if (provider != _provider || channel != _channel || queued.isEmpty) {
      unexpected.add('$provider:$channel');
      throw StateError('Unprepared cache-owner request');
    }
    final miss = queued.removeAt(0);
    miss.entered.complete();
    return await miss.result.future;
  }

  Future<List<StreamCandidate>> start() {
    final future = SourinApi.getLiveStream(_provider, _channel);
    pending.add(future);
    // Attach cleanup handling immediately, without changing what the actual
    // returned Future reports to the test's independent success/error checks.
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    return future;
  }

  Future<void> expectCached(String revision) async {
    final before = requests;
    final result = await start();
    expect(requests, before, reason: 'Read must use the ordinary TTL cache');
    expect(result.single.url, _url(revision));
  }

  Future<void> finish() async {
    for (final miss in all) {
      if (!miss.result.isCompleted) miss.result.complete(<StreamCandidate>[]);
    }
    await Future.wait(
      pending.map(
        (future) =>
            future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
      ),
    );
    expect(unexpected, isEmpty);
  }
}

void main() {
  late Future<List<StreamCandidate>> Function(String, String)? previousFetcher;
  late _CacheMissFixture fixture;

  setUp(() {
    previousFetcher = SourinApi.debugLiveStreamFetcher;
    SourinApi.debugClearLiveStreamCache();
    fixture = _CacheMissFixture();
    SourinApi.debugLiveStreamFetcher = fixture.fetch;
  });

  tearDown(() async {
    try {
      await fixture.finish();
    } finally {
      SourinApi.debugLiveStreamFetcher = previousFetcher;
      SourinApi.debugClearLiveStreamCache();
    }
  });

  test(
    'older success cannot overwrite the latest successful miss cache',
    () async {
      final old = fixture.hold();
      final oldFuture = fixture.start();
      await old.started;
      final latest = fixture.hold();
      final latestFuture = fixture.start();
      await latest.started;
      latest.succeed('latest');
      expect((await latestFuture).single.url, _url('latest'));
      await fixture.expectCached('latest');
      old.succeed('old');
      expect(
        (await oldFuture).single.url,
        _url('old'),
        reason: 'A superseded caller still receives its own result',
      );
      await fixture.expectCached('latest');
      expect(fixture.requests, 2);
    },
  );

  test(
    'newer failure cannot let an older success resurrect the cache',
    () async {
      final old = fixture.hold();
      final oldFuture = fixture.start();
      await old.started;
      final latest = fixture.hold();
      final latestFuture = fixture.start();
      await latest.started;
      final failure = StateError('Synthetic latest cache miss failure');
      final errorCheck = expectLater(latestFuture, throwsA(same(failure)));
      latest.result.completeError(failure);
      await errorCheck;
      old.succeed('old');
      expect((await oldFuture).single.url, _url('old'));
      expect(
        SourinApi.debugLiveStreamCacheSize,
        0,
        reason:
            'The failed latest request does not transfer ownership backward',
      );
      final retry = fixture.hold();
      final retryFuture = fixture.start();
      await retry.started;
      retry.succeed('retry');
      expect((await retryFuture).single.url, _url('retry'));
      await fixture.expectCached('retry');
      expect(fixture.requests, 3);
    },
  );

  test(
    'older completion cannot release a still-pending newer miss owner',
    () async {
      final old = fixture.hold();
      final oldFuture = fixture.start();
      await old.started;
      final latest = fixture.hold();
      final latestFuture = fixture.start();
      await latest.started;
      old.succeed('old');
      expect((await oldFuture).single.url, _url('old'));
      expect(
        SourinApi.debugLiveStreamCacheSize,
        0,
        reason: 'No superseded value may become a temporary cache hit',
      );
      latest.succeed('latest');
      expect((await latestFuture).single.url, _url('latest'));
      await fixture.expectCached('latest');
      expect(fixture.requests, 2);
    },
  );

  for (final clearAll in [false, true]) {
    test(
      '${clearAll ? 'global clear' : 'key invalidation'} retires old ownership without erasing a later miss',
      () async {
        final old = fixture.hold();
        final oldFuture = fixture.start();
        await old.started;
        final generation = SourinApi.debugLiveStreamGen(_provider, _channel);
        if (clearAll) {
          SourinApi.debugClearLiveStreamCache();
        } else {
          SourinApi.invalidateLiveStream(_provider, _channel);
        }
        expect(
          SourinApi.debugLiveStreamGen(_provider, _channel),
          greaterThan(generation),
        );
        final latest = fixture.hold();
        final latestFuture = fixture.start();
        await latest.started;
        old.succeed('invalidated');
        expect((await oldFuture).single.url, _url('invalidated'));
        expect(SourinApi.debugLiveStreamCacheSize, 0);
        latest.succeed('after-invalidation');
        expect((await latestFuture).single.url, _url('after-invalidation'));
        await fixture.expectCached('after-invalidation');
        expect(fixture.requests, 2);
      },
    );
  }
}
