import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fullscreen channel adoption preserves returned playback intent', () {
    final source = File('lib/ui/live_page.dart').readAsStringSync();
    expect(source, contains('bool preservePlaybackIntent = false'));
    expect(source, contains('if (!preservePlaybackIntent) _userPaused = false;'));
    expect(source, contains('_select(pending, preservePlaybackIntent: true)'));
    expect(source, contains('playWhenReady: !_userPaused'));
  });

  test('both embedded open paths respect playback intent before starting', () {
    final source = File('lib/ui/widgets/live_embedded_player.dart')
        .readAsStringSync();
    expect(source, contains('this.playWhenReady = true'));
    expect(source, contains('final bool playWhenReady;'));
    final guardedOpen = RegExp(
      r'await p\.open\(Media\(st\.url, httpHeaders: st\.httpHeaders\), play: false\);\s*if \(widget\.playWhenReady && _visibleNow\) \{\s*await p\.play\(\);\s*\}',
    );
    expect(guardedOpen.allMatches(source).length, 2,
        reason: 'Initial open and channel-switch open must both avoid autoplay '
            'before applying the current pause intent.');
  });
}
