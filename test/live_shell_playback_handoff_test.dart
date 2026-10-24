import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player_page.dart';

void main() {
  LivePlaybackSnapshot initial() => LivePlaybackSnapshot(
        playing: false,
        muted: true,
        volume: 37,
      );

  test('passes initial snapshot to the real PlayerPage', () async {
    final snapshot = initial();
    PlayerPage? pushed;
    await handoffLivePlayback(
      initialPlayback: snapshot,
      buildPlayer: (value, reportExit) => PlayerPage(
        provider: 'test-provider',
        id: 'test-channel',
        title: 'Test channel',
        liveChannelId: 'test-channel',
        initialLivePlayback: value,
        onLivePlaybackExit: reportExit,
      ),
      push: (player) async { pushed = player; },
    );
    expect(pushed, isNotNull);
    expect(pushed!.initialLivePlayback, same(snapshot));
  });

  test('captures exit snapshot before route completion and returns it afterward', () async {
    final route = Completer<void>();
    final returned = LivePlaybackSnapshot(
      playing: true,
      muted: false,
      volume: 64,
    );
    PlayerPage? pushed;
    var completed = false;
    final result = handoffLivePlayback(
      initialPlayback: initial(),
      buildPlayer: (value, reportExit) => PlayerPage(
        provider: 'test-provider',
        id: 'test-channel',
        title: 'Test channel',
        liveChannelId: 'test-channel',
        initialLivePlayback: value,
        onLivePlaybackExit: reportExit,
      ),
      push: (player) { pushed = player; return route.future; },
    ).then((value) { completed = true; return value; });
    expect(pushed!.onLivePlaybackExit, isNotNull);
    pushed!.onLivePlaybackExit!(returned);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse, reason: 'A report must not finish the route handoff early.');
    route.complete();
    expect(await result, same(returned));
  });

  test('missing exit report remains unknown after route completion', () async {
    final result = await handoffLivePlayback(
      initialPlayback: initial(),
      buildPlayer: (value, reportExit) => PlayerPage(
        provider: 'test-provider',
        id: 'test-channel',
        title: 'Test channel',
        liveChannelId: 'test-channel',
        initialLivePlayback: value,
        onLivePlaybackExit: reportExit,
      ),
      push: (_) async {},
    );
    expect(result, isNull);
  });
}
