import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

String section(String source, String start, String end) {
  final begin = source.indexOf(start);
  if (begin < 0) throw StateError('missing start marker: $start');
  final stop = source.indexOf(end, begin);
  if (stop < 0) throw StateError('missing end marker after start: $end');
  return source.substring(begin, stop);
}

void main() {
  final player = File('lib/ui/player_page.dart').readAsStringSync();
  final media = File('lib/ui/media_page.dart').readAsStringSync();
  final contract = File('lib/ui/media_session.dart').readAsStringSync();

  test('manual seek explicitly consumes automatic intro and pending resume', () {
    final body = section(player, 'void _seekBy(int seconds)', '/// 音量增减');
    expect(body, contains('_seekByUser(clamped)'));
    expect(body, contains('_seekByUser(target)'));
    final userSeek = section(
      player,
      'Future<void> _seekByUser(Duration target)',
      'void _seekBy(int seconds)',
    );
    expect(userSeek, contains('_introSkipped = true'));
    expect(userSeek, contains('_pendingSeek = null'));
    expect(userSeek, contains('++_seekToken'));
    expect(player, contains('_seekByUser(d)'));
  });

  test('automatic intro cannot race pending resume', () {
    final body = section(player, 'void _maybeSkip(Duration pos)', '/// 下一集倒计时');
    expect(body, contains('if (_pendingSeek != null) return;'));
  });

  test('recoverable banner occupies bottom controls and clears on progress', () {
    final occupied = section(player, 'bool get _bottomOccupied', '/// 底栏淡入淡出');
    expect(occupied, contains('_playbackFailure != null'));
    final tick = section(player, 'void _onPositionTick(Duration p)', 'Future<void> _load()');
    expect(tick, contains('_playbackFailure = null'));
    expect(tick, contains('p > _position'));
    expect(tick, contains('!_player.state.buffering'));
  });

  test('detail source switch forwards explicit resume intent', () {
    expect(contract, contains('final Duration? resumeFrom;'));
    expect(contract, contains('Duration get currentPosition;'));
    final switchBody = section(media, 'Future<void> _onDetailSwitchSource', '///',);
    expect(media, contains('resumeFrom:'));
    expect(player, contains('_pendingSeek = req.resumeFrom'));
    expect(switchBody, isNotEmpty);
  });
}
