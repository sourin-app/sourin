@Tags(['native-media'])
library;

// Local native helper pixel/format qualification; no production UI or remote media.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/native_screenshot.dart';

const _assetSha = 'A7F9B098190919564D466B5E6F2B46ECE3BEC6671E13748D02262DBF09307C67';

Future<void> _until(bool Function() condition, String failure) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError(failure);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

image.Image _decode(Uint8List? bytes, String format) {
  expect(bytes, isNotNull);
  expect(bytes!, isNotEmpty);
  final decoded = format == 'png' ? image.decodePng(bytes) : image.decodeJpg(bytes);
  expect(decoded, isNotNull);
  expect(decoded!.width, 320);
  expect(decoded.height, 180);
  var low = 255.0, high = 0.0;
  for (final pixel in decoded) {
    expect(pixel.a, 255, reason: 'Three-channel encoding must be opaque');
    final luma = (pixel.r + pixel.g + pixel.b) / 3;
    if (luma < low) low = luma;
    if (luma > high) high = luma;
  }
  expect(high - low, greaterThan(40), reason: 'Captured frame must have actual contrast');
  return decoded;
}

void main() {
  test('app helper captures actual pixels with opaque PNG and default JPEG', () async {
    final assetPath = Platform.environment['SOURIN_SCREENSHOT_ASSET'];
    final dllPath = Platform.environment['SOURIN_SCREENSHOT_LIBMPV'];
    final dllSha = Platform.environment['SOURIN_SCREENSHOT_LIBMPV_SHA256'];
    final runPath = Platform.environment['SOURIN_SCREENSHOT_RUN'];
    expect(assetPath, isNotNull);
    expect(dllPath, isNotNull);
    expect(dllSha, matches(RegExp(r'^[A-Fa-f0-9]{64}$')));
    expect(runPath, isNotNull);
    final asset = File(assetPath!);
    final dll = File(dllPath!);
    final run = Directory(runPath!);
    expect(run.existsSync(), isTrue, reason: 'Root must create a fresh owned run directory');
    expect(sha256.convert(asset.readAsBytesSync()).toString().toUpperCase(), _assetSha);
    expect(sha256.convert(dll.readAsBytesSync()).toString().toUpperCase(), dllSha!.toUpperCase());
    expect(NativePlayer.test, isFalse);
    final report = <String, Object?>{
      'schema': 1, 'scope': 'app helper with real local owned MP4; no production UI',
      'passed': false, 'asset_sha256': _assetSha, 'libmpv_sha256': dllSha.toUpperCase(),
      'frames': <Map<String, Object?>>[], 'player_disposed': false,
    };
    Player? player;
    NativePlayer? native;
    StreamSubscription<String>? errorsSubscription;
    final errors = <String>[];
    Object? failure;
    StackTrace? failureStack;
    try {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
      player = Player(configuration: const PlayerConfiguration(
        vo: 'null', muted: true, libass: true,
        title: 'Sourin app screenshot qualification',
        protocolWhitelist: ['file'], logLevel: MPVLogLevel.error,
      ));
      native = player.platform as NativePlayer;
      errorsSubscription = player.stream.error.listen(errors.add);
      final preopen = <String, String>{};
      report['preopen_properties'] = preopen;
      for (final property in <String, String>{
        'ao': 'null', 'vo': 'null', 'vid': 'auto', 'aid': 'no', 'sid': 'no',
        'hwdec': 'no', 'http-proxy': '', 'stream-lavf-o': 'http_proxy=',
        'load-unsafe-playlists': 'no',
      }.entries) {
        await native.setProperty(property.key, property.value);
        preopen[property.key] = await native.getProperty(property.key);
        expect(preopen[property.key], property.value);
      }
      await player.open(Media(asset.absolute.uri.toString()));
      await _until(() => player!.state.position >= const Duration(seconds: 2), 'Decode did not advance');
      await player.pause();
      expect(await native.getProperty('pause'), 'yes');
      await expectLater(capturePlayerScreenshot(player, format: 'image/gif'), throwsArgumentError);
      final png = await capturePlayerScreenshot(player,
          format: 'image/png', includeLibassSubtitles: true);
      final pngPixels = _decode(png, 'png');
      final raw = await capturePlayerScreenshot(player,
          format: null, includeLibassSubtitles: true);
      expect(raw, isNotNull);
      expect(raw!.length, 320 * 180 * 4, reason: 'This owned fixture has packed 320 x 180 BGRA/bgr0');
      final unusedFourthSlots = <String, int>{};
      for (final pixel in pngPixels) {
        final offset = (pixel.y * 320 + pixel.x) * 4;
        expect(pixel.b, raw[offset]);
        expect(pixel.g, raw[offset + 1]);
        expect(pixel.r, raw[offset + 2]);
        final fourth = raw[offset + 3].toString();
        unusedFourthSlots[fourth] = (unusedFourthSlots[fourth] ?? 0) + 1;
      }
      final jpegDefault = await capturePlayerScreenshot(player);
      final jpegExplicit = await capturePlayerScreenshot(player,
          format: 'image/jpeg', includeLibassSubtitles: false);
      _decode(jpegDefault, 'jpeg');
      _decode(jpegExplicit, 'jpeg');
      expect(jpegDefault, orderedEquals(jpegExplicit!), reason: 'Default JPEG keeps the same encoder and video mode');
      final videoPng = await capturePlayerScreenshot(player,
          format: 'image/png', includeLibassSubtitles: false);
      _decode(videoPng, 'png');
      File('${run.path}/paused-subtitles.png').writeAsBytesSync(png!);
      File('${run.path}/paused-subtitles.bgra').writeAsBytesSync(raw);
      File('${run.path}/paused-default.jpg').writeAsBytesSync(jpegDefault!);
      File('${run.path}/paused-explicit.jpg').writeAsBytesSync(jpegExplicit);
      File('${run.path}/paused-video.png').writeAsBytesSync(videoPng!);
      report['png_alpha_all_255'] = true;
      report['png_color_matches_raw'] = true;
      report['raw_unused_fourth_slot_histogram'] = unusedFourthSlots;
      report['default_jpeg_equals_explicit'] = true;
      report['tested_modes'] = ['subtitles', 'video'];
      report['subtitle_rendering_accepted'] = false;
      report['subtitle_scope'] = 'Mode reaches real C capture; fixture has sid=no, so actual subtitle glyph compositing is untested';
      report['raw_sha256'] = sha256.convert(raw).toString().toUpperCase();
      report['png_sha256'] = sha256.convert(png).toString().toUpperCase();
      report['jpeg_sha256'] = sha256.convert(jpegDefault).toString().toUpperCase();
      await player.play();
      final firstTarget = player.state.position + const Duration(milliseconds: 500);
      await _until(() => player!.state.position >= firstTarget, 'Playback did not resume');
      final motion1 = await capturePlayerScreenshot(player, format: 'image/png', includeLibassSubtitles: true);
      _decode(motion1, 'png');
      final firstPosition = player.state.position.inMilliseconds;
      final nextTarget = player.state.position + const Duration(milliseconds: 1500);
      await _until(() => player!.state.position >= nextTarget, 'Playback did not progress');
      final motion2 = await capturePlayerScreenshot(player, format: 'image/png', includeLibassSubtitles: true);
      _decode(motion2, 'png');
      final secondPosition = player.state.position.inMilliseconds;
      expect(secondPosition - firstPosition, greaterThanOrEqualTo(1000));
      expect(sha256.convert(motion1!).toString(), isNot(sha256.convert(motion2!).toString()));
      File('${run.path}/motion-1.png').writeAsBytesSync(motion1);
      File('${run.path}/motion-2.png').writeAsBytesSync(motion2);
      report['frames'] = [
        {'position_ms': firstPosition, 'png_sha256': sha256.convert(motion1).toString().toUpperCase()},
        {'position_ms': secondPosition, 'png_sha256': sha256.convert(motion2).toString().toUpperCase()},
      ];
      // Queue ordinary disposal after an actual helper call, using the same lock.
      final inFlightCapture = capturePlayerScreenshot(player, format: 'image/png', includeLibassSubtitles: true);
      final disposal = player.dispose();
      _decode(await inFlightCapture, 'png');
      await disposal;
      expect(native.disposed, isTrue);
      await expectLater(capturePlayerScreenshot(player), throwsA(isA<AssertionError>()));
      report['capture_then_dispose_completed'] = true;
      expect(errors, isEmpty);
      report['passed'] = true;
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      report['failure'] = error.toString();
      report['failure_stack'] = stack.toString();
    } finally {
      if (player != null) {
        try {
          if (native?.disposed != true) await player.dispose();
          await NativePlayer.lock.synchronized(() async {});
          await Future<void>.delayed(const Duration(seconds: 6));
          report['player_disposed'] = native?.disposed == true;
          report['native_dispose_timer_window_elapsed'] = true;
        } catch (error, stack) {
          report['cleanup_failure'] = error.toString();
          report['passed'] = false;
          failure ??= error;
          failureStack ??= stack;
        }
      }
      await errorsSubscription?.cancel();
      report['native_errors'] = errors;
      if (report['player_disposed'] != true || errors.isNotEmpty) report['passed'] = false;
      File('${run.path}/screenshot-result.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(report), flush: true);
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    expect(report['passed'], isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
