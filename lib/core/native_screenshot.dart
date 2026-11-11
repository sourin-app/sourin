import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

import 'native_screenshot_stub.dart'
    if (dart.library.ffi) 'native_screenshot_native.dart' as implementation;

/// Captures the current frame with native argument storage owned by the app.
Future<Uint8List?> capturePlayerScreenshot(
  Player player, {
  String? format = 'image/jpeg',
  bool includeLibassSubtitles = false,
}) => implementation.capturePlayerScreenshot(
  player,
  format: format,
  includeLibassSubtitles: includeLibassSubtitles,
);
