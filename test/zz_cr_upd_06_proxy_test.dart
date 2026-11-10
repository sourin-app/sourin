// 更新统一代理回归：核心决定上游路由，Dart 只读取返回的本机流地址。
// A：保留原始 URL 交给核心，旧更新代理字段不会自行改路由，文件字节完整。
// B：核心代理失败时不直连原站，不产生目标文件或临时文件。
// C：实际 HTTP keep-alive 连接由客户端在每次文本请求/下载后关闭。
// 所有 HTTP/TCP 端点均在 IPv4 loopback；只替代核心 IPC，不调用原生核心。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_log.dart';
import 'package:sourin_spike/core/app_update/client.dart';
import 'package:sourin_spike/core/app_update/route.dart';
import 'package:sourin_spike/core/ffi.dart';

List<int> _payload(int n) => List<int>.generate(n, (i) => i % 251);

class _Raw {
  _Raw(this.server);

  final ServerSocket server;
  final Set<Socket> sockets = {};
  final StreamController<int> _finishedCounts =
      StreamController<int>.broadcast();
  int accepted = 0;
  int finished = 0;
  final List<String> requestLines = [];

  Uri url(String path) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: path,
  );

  void connectionFinished(Socket socket) {
    sockets.remove(socket);
    finished++;
    if (!_finishedCounts.isClosed) _finishedCounts.add(finished);
  }

  Future<void> waitForFinished(int count) async {
    if (finished >= count) return;
    await _finishedCounts.stream
        .firstWhere((value) => value >= count)
        .timeout(const Duration(seconds: 3));
  }

  Future<void> shutdown() async {
    await server.close();
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    await _finishedCounts.close();
  }
}

/// 不发 Connection: close，等客户端结束连接后才计数并清理服务端 socket。
Future<_Raw> _startRaw(List<int> body) async {
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final raw = _Raw(listener);
  listener.listen((socket) async {
    raw.accepted++;
    raw.sockets.add(socket);
    var buffer = '';
    try {
      await for (final chunk in socket) {
        buffer += utf8.decode(chunk, allowMalformed: true);
        var end = buffer.indexOf('\r\n\r\n');
        while (end >= 0) {
          final head = buffer.substring(0, end);
          buffer = buffer.substring(end + 4);
          raw.requestLines.add(head.split('\r\n').first);
          socket.add([
            ...utf8.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: application/octet-stream\r\n'
              'Content-Length: ${body.length}\r\n\r\n',
            ),
            ...body,
          ]);
          await socket.flush();
          end = buffer.indexOf('\r\n\r\n');
        }
      }
    } on SocketException {
      // 客户端主动断开也会以 reset 结束读取。
    } finally {
      raw.connectionFinished(socket);
      socket.destroy();
    }
  });
  return raw;
}

void main() {
  setUp(() {
    AppLog.debugClear();
    AppLog.debugSetEnabled(false);
  });

  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    AppLog.debugClear();
    AppLog.debugSetEnabled(true);
  });

  test('CR-06A 下载原地址交给核心，旧代理字段不改变本机桥接路由', () async {
    final body = _payload(16 * 1024);
    final origin = await _startRaw(_payload(7));
    addTearDown(origin.shutdown);
    final legacyProxy = await _startRaw(_payload(11));
    addTearDown(legacyProxy.shutdown);
    final bridge = await _startRaw(body);
    addTearDown(bridge.shutdown);
    final dir = await Directory.systemTemp.createTemp('zz_cr_upd_06a_');
    addTearDown(() => dir.delete(recursive: true));
    final dest = File('${dir.path}/pkg.bin');
    final upstream = origin.url('/original/pkg.bin');
    final local = bridge.url('/bridge/pkg.bin');
    final calls = <Map<String, dynamic>>[];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      expect(command, 'global_proxy_open_download');
      calls.add(Map<String, dynamic>.from(args!));
      return {'url': local.toString()};
    };

    final downloaded = await UpdateHttp(
      UpdateRouteConfig(
        route: UpdateRoute.proxy,
        proxyHost: InternetAddress.loopbackIPv4.address,
        proxyPort: legacyProxy.server.port,
      ),
    ).download(upstream, dest);

    expect(downloaded, same(dest));
    expect(calls, [
      {'url': upstream.toString(), 'headers': <String, String>{}},
    ]);
    expect(bridge.requestLines, ['GET /bridge/pkg.bin HTTP/1.1']);
    expect(origin.accepted, 0, reason: 'Dart 不应绕过核心访问原站');
    expect(legacyProxy.accepted, 0, reason: '旧更新私有代理不应自行建立连接');
    expect(await dest.readAsBytes(), body);
    expect(await File('${dest.path}.part').exists(), isFalse);
  });

  test('CR-06B 核心代理失败时禁止直连原站或留下下载文件', () async {
    final origin = await _startRaw(_payload(12 * 1024));
    addTearDown(origin.shutdown);
    final legacyProxy = await _startRaw(_payload(11));
    addTearDown(legacyProxy.shutdown);
    final dir = await Directory.systemTemp.createTemp('zz_cr_upd_06b_');
    addTearDown(() => dir.delete(recursive: true));
    final dest = File('${dir.path}/pkg.bin');
    final upstream = origin.url('/original/pkg.bin');
    final failure = StateError('Synthetic global proxy unavailable');
    final calls = <Map<String, dynamic>>[];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      expect(command, 'global_proxy_open_download');
      calls.add(Map<String, dynamic>.from(args!));
      throw failure;
    };

    await expectLater(
      UpdateHttp(
        UpdateRouteConfig(
          route: UpdateRoute.proxy,
          proxyHost: InternetAddress.loopbackIPv4.address,
          proxyPort: legacyProxy.server.port,
        ),
      ).download(upstream, dest),
      throwsA(
        isA<UpdateNetworkException>().having(
          (error) => error.cause,
          'cause',
          same(failure),
        ),
      ),
    );

    expect(calls, [
      {'url': upstream.toString(), 'headers': <String, String>{}},
    ]);
    expect(origin.accepted, 0, reason: '全局代理不可用不能回退到原站直连');
    expect(origin.requestLines, isEmpty);
    expect(legacyProxy.accepted, 0);
    expect(await dest.exists(), isFalse);
    expect(await File('${dest.path}.part').exists(), isFalse);
  });

  test('CR-06C 每次本机桥接请求完成后客户端关闭 keep-alive 连接', () async {
    final content = 'sourin-${'x' * 4095}';
    final body = utf8.encode(content);
    final origin = await _startRaw(_payload(7));
    addTearDown(origin.shutdown);
    final bridge = await _startRaw(body);
    addTearDown(bridge.shutdown);
    final dir = await Directory.systemTemp.createTemp('zz_cr_upd_06c_');
    addTearDown(() => dir.delete(recursive: true));
    final upstream = origin.url('/original/pkg.bin');
    final calls = <Map<String, dynamic>>[];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      expect(command, 'global_proxy_open_download');
      calls.add(Map<String, dynamic>.from(args!));
      return {'url': bridge.url('/bridge/${calls.length}').toString()};
    };
    final client = UpdateHttp(const UpdateRouteConfig());

    expect(await client.getText(upstream), content);
    expect(await client.getText(upstream), content);
    final dest = File('${dir.path}/pkg.bin');
    await client.download(upstream, dest);
    expect(await dest.readAsBytes(), body);
    await bridge.waitForFinished(3);

    expect(
      calls,
      List.generate(
        3,
        (_) => {'url': upstream.toString(), 'headers': <String, String>{}},
      ),
    );
    expect(bridge.requestLines, [
      'GET /bridge/1 HTTP/1.1',
      'GET /bridge/2 HTTP/1.1',
      'GET /bridge/3 HTTP/1.1',
    ]);
    expect(origin.accepted, 0);
    expect(bridge.accepted, 3);
    expect(
      bridge.finished,
      bridge.accepted,
      reason: '三个 keep-alive 连接都必须由客户端在请求完成后关闭',
    );
  });
}
