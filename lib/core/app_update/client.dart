// ═══════════════════════════════════════════════════════════════════════
//  更新相关的 HTTP 出口（全局代理 / 镜像）
// ═══════════════════════════════════════════════════════════════════════
//
// 核心按当前全局代理建立上游连接，Dart 通过一次性的本地端点流式读取。
// 镜像失败可重试原地址，两者均遵守同一代理配置。代理失败不会绕过代理。
// 下载保留流式进度、取消和临时文件清理；本地桥接请求始终直连。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_log.dart';
import '../ffi.dart';
import 'release.dart';
import 'route.dart';

/// 更新功能用的 HTTP 客户端
class UpdateHttp {
  UpdateHttp(this.config);

  UpdateRouteConfig config;

  static const Duration _timeout = Duration(seconds: 20);

  /// 当前设备该用的平台 + ABI
  static (UpdatePlatform, String?) currentTarget() {
    if (Platform.isWindows) return (UpdatePlatform.windows, null);
    if (Platform.isMacOS || Platform.isIOS) return (UpdatePlatform.macos, null);
    if (Platform.isAndroid) {
      final abi = _androidAbi();
      // TV 与手机同一个 APK，用 arch 的 feature 区分不出来对我们没意义
      return (UpdatePlatform.android, abi);
    }
    return (UpdatePlatform.windows, null);
  }

  static String? _androidAbi() {
    // Android 上 `Platform.version` 形如 `Version 13`；ABI 只能从环境变量
    // 猜不到。老实做法：让 [selectForAbi] 自己按候选顺序退回 arm64。
    return const String.fromEnvironment('SOURIN_ABI', defaultValue: '');
  }

  Future<_UpdateOpen> _open(Uri url, {Map<String, String>? headers}) async {
    final result = await SourinCore.callAsync('global_proxy_open_download', {
      'url': url.toString(),
      'headers': headers ?? const <String, String>{},
    });
    final local = Uri.parse((result as Map)['url'] as String);
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..autoUncompress = true
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.getUrl(local).timeout(_timeout);
      return _UpdateOpen(client, await request.close().timeout(_timeout));
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  /// GET 一个文本（API / SHA256SUMS.txt）
  ///
  /// 镜像失败时可重试原地址，每次请求均遵守当前全局代理配置。
  Future<String> getText(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    final candidates = <Uri>[url];
    if (config.route == UpdateRoute.mirror) {
      final mirrored = Uri.tryParse(config.mirrorPrefix + url.toString());
      if (mirrored != null && mirrored.toString() != url.toString()) {
        candidates.insert(0, mirrored);
      }
    }
    Object? last;
    for (final c in candidates) {
      _UpdateOpen? opened;
      try {
        opened = await _open(c, headers: headers);
        final r = opened.response;
        final body = await utf8.decoder.bind(r).join();
        if (r.statusCode != 200) {
          throw HttpException('HTTP ${r.statusCode}', uri: c);
        }
        return body;
      } catch (e) {
        last = e;
        AppLog.write('UPDATE', '请求失败（${c.host}）: $e');
      } finally {
        // 读完（或放弃）响应后立刻释放 client，否则每次请求泄漏一个连接
        opened?.close();
      }
    }
    throw UpdateNetworkException('连接不上更新服务', last);
  }

  /// 下载到临时文件，带进度回调与取消
  ///
  /// - [onProgress] 收到 (已写字节, 总字节)；总字节未知时 total ≤ 0
  /// - 返回写好的文件
  /// - 抛 [UpdateCancelled] 表示用户取消（不留半截文件）
  Future<File> download(
    Uri url,
    File dest, {
    void Function(int done, int total)? onProgress,
    Future<bool> Function()? cancelled,
  }) async {
    Object? last;
    // ① 首选 URL（镜像模式已改写过），失败再试原地址
    final fallbacks = <Uri>[url];
    if (config.route == UpdateRoute.mirror) {
      final u = Uri.tryParse(
        url.toString().substring(
          config.mirrorPrefix.length.clamp(0, config.mirrorPrefix.length),
        ),
      );
      if (u != null && u.toString() != url.toString()) fallbacks.add(u);
    }
    for (final target in fallbacks) {
      {
        File? part;
        _UpdateOpen? opened;
        try {
          part = File('${dest.path}.part');
          part.parent.createSync(recursive: true);
          opened = await _open(target);
          final r = opened.response;
          if (r.statusCode != 200) {
            throw HttpException('HTTP ${r.statusCode}', uri: target);
          }
          final total = r.contentLength;
          final sink = part.openWrite();
          var done = 0;
          var lastTick = DateTime.now();
          try {
            await for (final chunk in r) {
              // 返回 true 才算取消 —— 以前返回值被丢掉，UpdateCancelled
              // 永远抛不出来，用户点「取消」下载照跑到底。
              if (cancelled != null && await cancelled()) {
                throw UpdateCancelled();
              }
              sink.add(chunk);
              done += chunk.length;
              // 进度回调节流到 ~10Hz —— 每个 chunk 都回调会让 UI 重建上百次
              final now = DateTime.now();
              if (onProgress != null &&
                  now.difference(lastTick) >
                      const Duration(milliseconds: 100)) {
                lastTick = now;
                onProgress(done, total);
              }
            }
          } finally {
            await sink.flush();
            await sink.close();
            // 写完（或中途放弃）都要关掉 client
            opened.close();
            opened = null;
          }
          onProgress?.call(done, total);
          if (dest.existsSync()) dest.deleteSync();
          part.renameSync(dest.path);
          return dest;
        } on UpdateCancelled {
          opened?.close();
          _safeDelete(part);
          rethrow;
        } catch (e) {
          opened?.close();
          _safeDelete(part);
          last = e;
          AppLog.write('UPDATE', '安装包下载失败（${target.host}）: $e');
        }
      }
    }
    throw UpdateNetworkException('下载失败，请稍后重试', last);
  }

  static void _safeDelete(File? f) {
    try {
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {
      // 半截文件删不掉不是致命问题（下次会覆盖）
    }
  }
}

/// 一个已建立的连接：响应体由调用方读完，然后必须 [close]。
///
/// 以前每次请求都 new 一个 HttpClient 却从不 close，等于每个请求泄漏一个
/// 连接；现在把 client 和响应绑在一起，读完一起关。
class _UpdateOpen {
  _UpdateOpen(this.client, this.response);

  final HttpClient client;
  final HttpClientResponse response;

  void close() {
    try {
      // body 读完之后 close() 是优雅关闭。
      client.close(force: false);
    } catch (_) {
      // 关不掉也不是致命问题
    }
  }
}

/// 网络类失败（统一一个类型，UI 只显示 [message]）
class UpdateNetworkException implements Exception {
  UpdateNetworkException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => message;
}

/// 用户主动取消
class UpdateCancelled implements Exception {
  UpdateCancelled();
  @override
  String toString() => '已取消';
}
