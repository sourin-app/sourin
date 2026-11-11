import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';

Future<Uint8List?> capturePlayerScreenshot(
  Player player, {
  String? format = 'image/jpeg',
  bool includeLibassSubtitles = false,
}) => player.screenshot(
  format: format,
  includeLibassSubtitles: includeLibassSubtitles,
);
