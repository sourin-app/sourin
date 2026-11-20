@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/app_player.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String message,
) async {
  final wall = Stopwatch()..start();
  while (!ready()) {
    if (wall.elapsed >= const Duration(seconds: 8)) {
      throw TimeoutException(message);
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

// Native replies arrive on the real event loop, while their Dart callbacks may
// belong to the widget test's fake clock. Advance both rather than awaiting a
// fake-zone Future inside runAsync, which would never resume its callbacks.
Future<T> _nativeFuture<T>(WidgetTester tester, Future<T> pending) async {
  var complete = false;
  late T value;
  Object? error;
  StackTrace? stack;
  unawaited(
    pending.then<void>(
      (result) {
        value = result;
        complete = true;
      },
      onError: (Object failure, StackTrace failureStack) {
        error = failure;
        stack = failureStack;
        complete = true;
      },
    ),
  );
  await _until(
    tester,
    () => complete,
    'Native player operation did not finish',
  );
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value;
}

// The generated PCM file exercises libmpv without a network source, account,
// audio device or window. Position assertions read native events/properties,
// never the slider preview or its requested seek argument.
File _writeMedia(Directory root) {
  const sampleRate = 8000;
  const seconds = 30;
  const dataLength = sampleRate * seconds * 2;
  final bytes = ByteData(44 + dataLength);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, dataLength, Endian.little);
  return File('${root.path}${Platform.pathSeparator}seek.wav')
    ..writeAsBytesSync(bytes.buffer.asUint8List());
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (Platform.isWindows) {
      expect(
        dll.existsSync(),
        isTrue,
        reason: 'Native media must actually run.',
      );
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    } else {
      MediaKit.ensureInitialized();
    }
  });

  testWidgets('mouse click moves the native playhead under double-tap parent', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('sourin-click-seek-');
    final media = _writeMedia(root);
    AppPlayer? player;
    StreamSubscription<Duration>? positions;
    final observed = <Duration>[];
    final errors = <String>[];
    StreamSubscription<String>? errorSubscription;
    try {
      player = AppPlayer(
        configuration: const PlayerConfiguration(vo: 'null', muted: true),
      );
      final native = player.platform as NativePlayer;
      await _nativeFuture(tester, native.setProperty('ao', 'null'));
      positions = player.stream.position.listen(observed.add);
      errorSubscription = player.stream.error.listen(errors.add);
      await _nativeFuture(tester, player.open(Media(media.path), play: false));
      await _until(
        tester,
        () => player!.state.duration.inSeconds >= 29,
        'Local media duration was not reported',
      );
      final actualPlayer = player;
      expect(actualPlayer.state.duration.inSeconds, 30);
      expect(actualPlayer.state.position.inSeconds, 0);
      Future<void>? seeking;
      var commits = 0;
      final theme = AppTheme.themeFor(Brightness.dark);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: Scaffold(
            body: GestureDetector(
              onDoubleTap: () {},
              child: Center(
                child: SizedBox(
                  width: 400,
                  child: PlayerProgressSlider(
                    position: actualPlayer.state.position,
                    duration: actualPlayer.state.duration,
                    onSeek: (target) {
                      commits++;
                      seeking = actualPlayer.seek(target);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(PlayerProgressSlider));
      final mouse = await tester.startGesture(
        Offset(rect.left + rect.width * .75, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(commits, 1, reason: 'A click must commit without any drag.');
      expect(seeking, isNotNull);
      await _nativeFuture(tester, seeking!);
      await _until(
        tester,
        () => observed.any((value) => value.inMilliseconds >= 22000),
        'A click did not update the native position stream',
      );
      final position = double.parse(
        await _nativeFuture(tester, native.getProperty('time-pos')),
      );
      expect(position, closeTo(22.5, .5));
      expect(observed.any((value) => value.inMilliseconds >= 22000), isTrue);
      await _nativeFuture(tester, actualPlayer.play());
      final before = actualPlayer.state.position;
      await _until(
        tester,
        () =>
            actualPlayer.state.position - before >=
            const Duration(milliseconds: 300),
        'Playback did not advance from the clicked position',
      );
      expect(
        actualPlayer.state.position - before,
        greaterThanOrEqualTo(const Duration(milliseconds: 300)),
        reason: 'Playback must continue from the clicked position.',
      );
      expect(errors, isEmpty);
      // ignore: avoid_print
      print(
        'NATIVE_CLICK_SEEK position=$position commits=$commits '
        'advancedMs=${(actualPlayer.state.position - before).inMilliseconds}',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (positions != null) await _nativeFuture(tester, positions.cancel());
      if (errorSubscription != null) {
        await _nativeFuture(tester, errorSubscription.cancel());
      }
      if (player != null) await _nativeFuture(tester, player.dispose());
      // media_kit delays playlist cleanup and native termination by five
      // seconds; run those real cleanup callbacks before leaving fakeAsync.
      await tester.pump(const Duration(seconds: 6));
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });
}
