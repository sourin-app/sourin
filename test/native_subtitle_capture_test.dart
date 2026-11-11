// Local ASS glyph capture qualification; no production UI or remote media.
@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/native_screenshot.dart';

Future<void> _until(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError(reason);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

image.Image _decode(Uint8List? bytes, {bool jpeg = false}) {
  expect(bytes, isNotNull);
  final decoded = jpeg ? image.decodeJpg(bytes!) : image.decodePng(bytes!);
  expect(decoded, isNotNull);
  expect(decoded!.width, 320);
  expect(decoded.height, 180);
  for (final pixel in decoded) {
    expect(pixel.a, 255);
  }
  return decoded;
}

void main() {
  test('actual app helper composites an owned ASS glyph on the same paused frame', () async {
    final run = Directory(Platform.environment['SOURIN_SUBTITLE_RUN']!);
    final asset = File(Platform.environment['SOURIN_SUBTITLE_ASSET']!);
    final ass = File(Platform.environment['SOURIN_SUBTITLE_ASS']!);
    final dll = File(Platform.environment['SOURIN_SUBTITLE_LIBMPV']!);
    final fonts = Directory(Platform.environment['SOURIN_SUBTITLE_FONT_DIR']!);
    expect(run.existsSync(), isTrue);
    expect(fonts.existsSync(), isTrue);
    final bindings = <String, String>{
      'asset': 'A7F9B098190919564D466B5E6F2B46ECE3BEC6671E13748D02262DBF09307C67',
      'ass': Platform.environment['SOURIN_SUBTITLE_ASS_SHA256']!,
      'dll': 'D5F0694B08C124E785D858D00082F3E3B158DD9138BFC48C0382BF1EB443A5FC',
      'font': Platform.environment['SOURIN_SUBTITLE_FONT_SHA256']!,
    };
    for (final file in <String, File>{'asset': asset, 'ass': ass, 'dll': dll, 'font': File('${fonts.path}/arial.ttf')}.entries) {
      expect(sha256.convert(file.value.readAsBytesSync()).toString().toUpperCase(), bindings[file.key]);
    }
    expect(NativePlayer.test, isFalse);
    final report = <String, Object?>{
      'schema': 1, 'passed': false, 'bindings': bindings,
      'scope': 'owned local ASS glyph through actual helper; no production UI/cloud/package',
      'roi': [40, 60, 280, 140], 'player_disposed': false,
    };
    Player? player;
    NativePlayer? native;
    StreamSubscription<String>? subscription;
    final errors = <String>[];
    Object? failure;
    StackTrace? failureStack;
    try {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
      player = Player(configuration: const PlayerConfiguration(
        vo: 'null', muted: true, libass: true, title: 'Sourin owned ASS capture qualification',
        protocolWhitelist: ['file'], logLevel: MPVLogLevel.info,
      ));
      native = player.platform as NativePlayer;
      subscription = player.stream.error.listen(errors.add);
      final preopen = <String, String>{};
      report['preopen_properties'] = preopen;
      for (final property in <String, String>{
        'ao': 'null', 'vo': 'null', 'vid': 'auto', 'aid': 'no', 'sid': 'no',
        'hwdec': 'no', 'http-proxy': '', 'stream-lavf-o': 'http_proxy=',
        'load-unsafe-playlists': 'no', 'sub-ass': 'yes', 'sub-visibility': 'yes',
        'sub-fonts-dir': fonts.absolute.path, 'sub-font': 'Arial',
      }.entries) {
        await native.setProperty(property.key, property.value);
        preopen[property.key] = await native.getProperty(property.key);
        expect(preopen[property.key], property.value);
      }
      await player.open(Media(asset.absolute.uri.toString()));
      await _until(() => player!.state.position >= const Duration(seconds: 2), 'Video did not decode');
      await player.pause();
      expect(await native.getProperty('pause'), 'yes');
      final baseline = await capturePlayerScreenshot(player, format: 'image/png', includeLibassSubtitles: false);
      _decode(baseline);
      final sameFramePosition = await native.getProperty('time-pos');
      await player.setSubtitleTrack(SubtitleTrack.uri(ass.absolute.uri.toString(), title: 'Owned capture glyph'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      String subText;
      do {
        subText = await native.getProperty('sub-text');
        if (subText.contains('OWNED CAPTURE')) break;
        if (DateTime.now().isAfter(deadline)) throw StateError('Owned subtitle was not active at paused time');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      } while (true);
      final sid = await native.getProperty('sid');
      expect(sid, isNot('no'));
      expect(sid, isNotEmpty);
      final video = await capturePlayerScreenshot(player, format: 'image/png', includeLibassSubtitles: false);
      final subtitlePng = await capturePlayerScreenshot(player, format: 'image/png', includeLibassSubtitles: true);
      final raw = await capturePlayerScreenshot(player, format: null, includeLibassSubtitles: true);
      final without = _decode(video);
      final withGlyph = _decode(subtitlePng);
      expect(baseline!, orderedEquals(video!));
      expect(raw, isNotNull);
      expect(raw!.length, 320 * 180 * 4);
      var changedInside = 0, changedOutside = 0;
      for (final pixel in withGlyph) {
        final offset = (pixel.y * 320 + pixel.x) * 4;
        expect(pixel.b, raw[offset]);
        expect(pixel.g, raw[offset + 1]);
        expect(pixel.r, raw[offset + 2]);
        final other = without.getPixel(pixel.x, pixel.y);
        if (pixel.r != other.r || pixel.g != other.g || pixel.b != other.b) {
          if (pixel.x >= 40 && pixel.x < 280 && pixel.y >= 60 && pixel.y < 140) {
            changedInside++;
          } else {
            changedOutside++;
          }
        }
      }
      expect(changedInside, greaterThanOrEqualTo(100), reason: 'Actual owned subtitle glyph must be visible');
      expect(changedOutside, 0, reason: 'Same paused video frame must stay identical outside text ROI');
      final jpegVideo = await capturePlayerScreenshot(player, format: 'image/jpeg', includeLibassSubtitles: false);
      final jpegGlyph = await capturePlayerScreenshot(player, format: 'image/jpeg', includeLibassSubtitles: true);
      final jpegWithout = _decode(jpegVideo, jpeg: true);
      final jpegWith = _decode(jpegGlyph, jpeg: true);
      var jpegChangedInside = 0;
      for (var y = 60; y < 140; y++) {
        for (var x = 40; x < 280; x++) {
          final a = jpegWithout.getPixel(x, y), b = jpegWith.getPixel(x, y);
          if (a.r != b.r || a.g != b.g || a.b != b.b) jpegChangedInside++;
        }
      }
      expect(jpegChangedInside, greaterThanOrEqualTo(100));
      await player.setSubtitleTrack(SubtitleTrack.no());
      expect(await native.getProperty('sid'), 'no');
      final removed = await capturePlayerScreenshot(player, format: 'image/png', includeLibassSubtitles: true);
      _decode(removed);
      expect(removed!, orderedEquals(baseline));
      expect(await native.getProperty('pause'), 'yes');
      expect(await native.getProperty('time-pos'), sameFramePosition);
      for (final file in <String, Uint8List>{
        'baseline-video.png': baseline, 'selected-video.png': video,
        'subtitles-on.png': subtitlePng!, 'subtitles-on.bgra': raw,
        'subtitles-on.jpg': jpegGlyph!, 'selected-video.jpg': jpegVideo!, 'after-remove.png': removed,
      }.entries) {
        File('${run.path}/${file.key}').writeAsBytesSync(file.value);
      }
      report.addAll({'same_frame_time_pos': sameFramePosition, 'selected_sid': sid,
        'actual_sub_text': subText, 'changed_inside_roi': changedInside,
        'changed_outside_roi': changedOutside, 'jpeg_changed_inside_roi': jpegChangedInside,
        'png_raw_colors_exact': true, 'opaque_png': true, 'removed_matches_baseline': true,
        'subtitle_glyph_composited': true, 'passed': true});
      expect(errors, isEmpty);
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      report['failure'] = error.toString();
      report['failure_stack'] = stack.toString();
    } finally {
      if (player != null) {
        try {
          await player.dispose();
          await NativePlayer.lock.synchronized(() async {});
          await Future<void>.delayed(const Duration(seconds: 6));
          report['player_disposed'] = native?.disposed == true;
          report['native_dispose_timer_window_elapsed'] = true;
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
          report['cleanup_failure'] = error.toString();
          report['passed'] = false;
        }
      }
      await subscription?.cancel();
      report['native_errors'] = errors;
      if (report['player_disposed'] != true || errors.isNotEmpty) report['passed'] = false;
      File('${run.path}/subtitle-result.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report), flush: true);
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    expect(report['passed'], isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
