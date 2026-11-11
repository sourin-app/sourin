// Pure delegate-contract tests; no NativePlayer, native DLL or captured-pixel claim.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/native_screenshot.dart';

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration());

  final bytes = Uint8List.fromList([17, 23, 41]);
  final calls = <Map<String, Object?>>[];
  Object? failure;

  @override
  Future<Uint8List?> screenshot({String? format = 'image/jpeg', bool includeLibassSubtitles = false}) async {
    calls.add({'format': format, 'subtitles': includeLibassSubtitles});
    if (failure != null) throw failure!;
    return bytes;
  }
}

void main() {
  test('non-native helper delegates original default JPEG without a native call', () async {
    final backend = _Backend();
    final player = Player(platformPlayer: backend);
    expect(await capturePlayerScreenshot(player), same(backend.bytes));
    expect(backend.calls, [{'format': 'image/jpeg', 'subtitles': false}]);
    await player.dispose();
  });

  test('non-native helper preserves raw and subtitles arguments', () async {
    final backend = _Backend();
    final player = Player(platformPlayer: backend);
    expect(await capturePlayerScreenshot(player, format: null, includeLibassSubtitles: true), same(backend.bytes));
    expect(backend.calls, [{'format': null, 'subtitles': true}]);
    await player.dispose();
  });

  test('non-native helper preserves backend unsupported-format rejection', () async {
    final backend = _Backend()..failure = ArgumentError('Unsupported format');
    final player = Player(platformPlayer: backend);
    await expectLater(capturePlayerScreenshot(player, format: 'image/gif'), throwsArgumentError);
    expect(backend.calls, [{'format': 'image/gif', 'subtitles': false}]);
    await player.dispose();
  });
}
