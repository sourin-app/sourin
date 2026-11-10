import 'package:media_kit/media_kit.dart';

/// A native transport policy could not be confirmed before opening media.
class NativeMediaTransportException implements Exception {
  const NativeMediaTransportException();

  @override
  String toString() => '播放连接配置未能完成，请重试。';
}

/// Keeps native media requests on the route selected by the application core.
///
/// An empty mpv http-proxy alone still permits FFmpeg environment fallback.
/// NativePlayer.setProperty discards mpv's return code, so the nonempty explicit
/// stream AVOption must be read back before any media is opened.
Future<void> prepareNativeMediaTransport(PlatformPlayer? platform) async {
  if (platform is! NativePlayer) return;
  try {
    await platform.setProperty('http-proxy', '');
    await platform.setProperty('stream-lavf-o', 'http_proxy=');
    final configured = await platform.getProperty('stream-lavf-o');
    if (configured.trim() != 'http_proxy=') {
      throw const NativeMediaTransportException();
    }
  } catch (_) {
    // Do not expose native option values or allow an unconfirmed route to open.
    throw const NativeMediaTransportException();
  }
}
