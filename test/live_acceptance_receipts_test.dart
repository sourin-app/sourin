import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

void main() {
  for (final playing in [true, false]) {
    test('user toggle awaits ${playing ? 'pause' : 'play'} before intent', () async {
      final command = Completer<void>();
      final events = <String>[];
      final pending = runLiveUserPlaybackToggle(
        playing: playing,
        pause: () { events.add('pause'); return command.future; },
        play: () { events.add('play'); return command.future; },
        onUserPause: (paused) => events.add('intent:$paused'),
      );
      expect(events, [playing ? 'pause' : 'play']);
      command.complete();
      await pending;
      expect(events, [playing ? 'pause' : 'play', 'intent:$playing']);
    });
  }

  test('failed native command does not publish user intent', () async {
    final failure = StateError('command failed');
    var notified = false;
    await expectLater(runLiveUserPlaybackToggle(
      playing: true,
      pause: () async => throw failure,
      play: () async {},
      onUserPause: (_) => notified = true,
    ), throwsA(same(failure)));
    expect(notified, isFalse);
  });

  test('route result and restoration completion are distinct', () async {
    final receipt = LiveRoundtripReceipt();
    final route = Completer<void>();
    final restore = Completer<void>();
    var finished = false;
    receipt.finished.then((_) => finished = true);
    final pending = receipt.observe(() async {
      await route.future;
      receipt.markRouteReturnedForProbe();
      await restore.future;
    });
    expect(receipt.routeReturnedAt, isNull);
    route.complete();
    await receipt.routeResultReturned;
    expect(receipt.routeReturnedAt, isNotNull);
    expect(receipt.restoredAt, isNull);
    expect(finished, isFalse);
    restore.complete();
    await pending;
    await receipt.finished;
    expect(receipt.restoredAt, isNotNull);
    expect(receipt.restoredAt!.isBefore(receipt.routeReturnedAt!), isFalse);
  });

  test('unmounted or failed restoration is not reported as restored', () async {
    final unmounted = LiveRoundtripReceipt();
    await unmounted.observe(() async {
      unmounted.markRouteReturnedForProbe();
    }, restored: () => false);
    expect(unmounted.routeReturnedAt, isNotNull);
    expect(unmounted.restoredAt, isNull);
    final failed = LiveRoundtripReceipt();
    final failure = StateError('restore failed');
    await expectLater(failed.observe(() async {
      failed.markRouteReturnedForProbe();
      throw failure;
    }), throwsA(same(failure)));
    await failed.finished;
    expect(failed.error, same(failure));
    expect(failed.restoredAt, isNull);
  });

  test('disposal receipt waits for native future and retains error', () async {
    final receipt = LiveEmbeddedDisposalReceipt();
    final native = Completer<void>();
    final failure = StateError('dispose failed');
    receipt.observeForTest(() => native.future);
    expect(receipt.started, isTrue);
    expect(receipt.hadNativePlayer, isTrue);
    expect(receipt.completedAt, isNull);
    native.completeError(failure, StackTrace.current);
    await receipt.completed;
    expect(receipt.completedAt, isNotNull);
    expect(receipt.error, same(failure));
    expect(receipt.stackTrace, isNotNull);
    expect(LiveEmbeddedDisposalReceipt().instanceId, isNot(receipt.instanceId));
  });

  test('successful disposal receipt records completion without error', () async {
    final receipt = LiveEmbeddedDisposalReceipt();
    final native = Completer<void>();
    receipt.observeForTest(() => native.future);
    expect(receipt.completedAt, isNull);
    native.complete();
    await receipt.completed;
    expect(receipt.completedAt, isNotNull);
    expect(receipt.error, isNull);
  });

  testWidgets('State.dispose returns synchronously and retained receipt completes', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox(
      width: 532, height: 356,
      child: LiveEmbeddedPlayer(stream: null, title: 'receipt test'),
    ))));
    final state = tester.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));
    final receipt = state.disposalReceiptForProbe;
    expect(receipt.started, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(state.mounted, isFalse);
    expect(receipt.started, isTrue);
    await receipt.completed;
    expect(receipt.hadNativePlayer, isFalse);
    expect(receipt.completedAt, isNotNull);
    expect(receipt.error, isNull);
  });

  // Wiring-only guard. This is NOT behavioral or native playback evidence.
  test('source contract: production controls retain native method wiring', () {
    final embedded = File('lib/ui/widgets/live_embedded_player.dart').readAsStringSync();
    expect(embedded, contains('onTogglePlay: toggleUserPlaybackForProbe'));
    expect(embedded, contains('pause: p.pause'));
    expect(embedded, contains('play: p.play'));
    expect(embedded, contains('_disposalReceipt._start(p == null ? null : p.dispose)'));
    final live = File('lib/ui/live_page.dart').readAsStringSync();
    expect(live, contains('receipt.observe(() => _watchLive(receipt: receipt)'));
    expect(live, contains('receipt?._markRouteReturned()'));
  });
}
