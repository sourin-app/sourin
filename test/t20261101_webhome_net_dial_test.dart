// ═══════════════════════════════════════════════════════════════════════
//  N3b webHome net.request 门禁：解析与连接同 IP（TOCTOU 闭合的行为断言）
// ═══════════════════════════════════════════════════════════════════════
//
// # 防的是什么
// SSRF 判据②在校验时解析的 IP，如果连接时被二次解析（HttpClient 默认
// 路径），两次解析之间就是 DNS rebinding 的 TOCTOU 窗口。这里断言的
// **行为不变量**：拨号（Socket.startConnect）第一参**恒为已验证的
// InternetAddress，绝不出现 hostname 字符串**——字符串一旦回到拨号口，
// 就等于把解析权交还给系统/代理，窗口重开。
//
// # 证红记录（2026-11-01）
// - 注入 rebinding 解析器：首调 [8.8.8.8]、次调 [10.0.0.1] ⇒ 新实现只
//   解析一次、拨 8.8.8.8（绿）；
// - 对照组：legacy 形态（hostname 交还拨号口）跑同一断言 ⇒ 红（已验）；
// - 解析段负例：lookup 返回 [192.168.1.1] ⇒ target-not-allowed 且零拨号。
// 手法：IOOverrides 拦 socketStartConnect 记录拨号口实参，实际连接一律
// 转拨本地 ServerSocket——注入的公网/内网 IP 都不会真的出网。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/webhome/fm_bridge.dart';
import 'package:sourin_spike/ui/webhome/fm_net_request.dart';

const _lookup = InternetAddressType.any;

/// 断言：拨号只吃校验过的 IP，hostname 永不回到拨号口。
void _expectPinned({
  required List<String> dialedIps,
  required List<String> hostnameDials,
  required List<String> validatedIps,
}) {
  expect(hostnameDials, isEmpty,
      reason: '拨号口出现 hostname 字符串 ⇒ 连接在做二次解析，TOCTOU 窗口重开');
  expect(dialedIps, validatedIps,
      reason: '连接必须只拨校验过的那批 IP（解析与连接同源）');
}

/// 本地 HTTP 服务器：收到连接即回固定 200 响应。
Future<ServerSocket> _startCannedServer(String body) async {
  final payload = utf8.encode(body);
  final resp = utf8.encode('HTTP/1.1 200 OK\r\n'
      'Content-Type: text/plain\r\n'
      'Content-Length: ${payload.length}\r\n'
      'Connection: close\r\n'
      '\r\n'
      '$body');
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) {
    client.add(resp);
    client.flush().then((_) => client.destroy());
  });
  return server;
}

/// 拨号口记录器：记录 [Socket.startConnect] 收到的原始实参类型，
/// 实际连接一律转拨本地测试服务器（注入的公网/内网 IP 不出网）。
final class _DialRecorder extends IOOverrides {
  _DialRecorder(this.serverPort);

  final int serverPort;
  final List<String> dialedIps = [];
  final List<String> hostnameDials = [];

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(host, int port,
      {sourceAddress, int sourcePort = 0}) {
    if (host is InternetAddress) {
      dialedIps.add(host.address);
    } else if (host is String) {
      hostnameDials.add(host);
    }
    // ★ 必须 super（直通 Socket._startConnect）：在 hook 里再调
    //   Socket.startConnect 会重新进 override 无限递归
    //   （首轮实踩：Stack Overflow）。
    return super.socketStartConnect(InternetAddress.loopbackIPv4, serverPort,
        sourceAddress: sourceAddress, sourcePort: sourcePort);
  }
}

void main() {
  test('解析与连接同 IP：拨号只吃校验过的 IP，hostname 永不回到拨号口',
      () async {
    final server = await _startCannedServer('ok');
    final rec = _DialRecorder(server.port);
    final lookups = <String>[];
    try {
      final result = await IOOverrides.runWithIOOverrides(() {
        return fmNetRequest(
          const FmNetRequest(
              url: 'http://api.example.com/vod',
              method: 'GET',
              headers: {}),
          lookup: (host, {type = _lookup}) async {
            lookups.add(host);
            return [InternetAddress('8.8.8.8')];
          },
        );
      }, rec);
      expect(result, containsPair('status', 200));
      expect(result['body'], 'ok');
      expect(lookups, ['api.example.com'], reason: '整条链路只解析一次');
      _expectPinned(
          dialedIps: rec.dialedIps,
          hostnameDials: rec.hostnameDials,
          validatedIps: ['8.8.8.8']);
    } finally {
      await server.close();
    }
  });

  test('注入 rebinding 解析器：次调返回内网 IP 也不影响连接（只解析一次）',
      () async {
    final server = await _startCannedServer('ok');
    final rec = _DialRecorder(server.port);
    var calls = 0;
    try {
      final result = await IOOverrides.runWithIOOverrides(() {
        return fmNetRequest(
          const FmNetRequest(
              url: 'http://api.example.com/x', method: 'GET', headers: {}),
          lookup: (host, {type = _lookup}) async {
            calls++;
            // 经典 rebinding 时序：校验时是公网，若连接时再解析已是内网。
            return calls == 1
                ? [InternetAddress('8.8.8.8')]
                : [InternetAddress('10.0.0.1')];
          },
        );
      }, rec);
      expect(result, containsPair('status', 200));
      expect(calls, 1, reason: '闭合的标志：连接不再发起第二次解析');
      _expectPinned(
          dialedIps: rec.dialedIps,
          hostnameDials: rec.hostnameDials,
          validatedIps: ['8.8.8.8']);
    } finally {
      await server.close();
    }
  });

  test('证红对照：legacy 拨号（hostname 交还解析器）会被同一断言抓住',
      () async {
    final server = await _startCannedServer('ok');
    final rec = _DialRecorder(server.port);
    try {
      // 旧实现等价形态：把 hostname 字符串交给 Socket.startConnect
      // ⇒ SDK 会二次解析（注入的解析器第二次已换内网 IP ⇒ 窗口被利用）。
      await IOOverrides.runWithIOOverrides(() async {
        final task = await Socket.startConnect('api.example.com', 80);
        await task.socket;
      }, rec);
      expect(rec.hostnameDials, ['api.example.com'],
          reason: 'legacy 路径确实把解析权交还给了拨号口');
      // 同一断言对 legacy 记录必然失败 —— 断言有牙。
      expect(
        () => _expectPinned(
            dialedIps: rec.dialedIps,
            hostnameDials: rec.hostnameDials,
            validatedIps: ['8.8.8.8']),
        throwsA(isA<TestFailure>()),
      );
    } finally {
      await server.close();
    }
  });

  test('解析段负例（行为化）：解析出内网 IP ⇒ target-not-allowed 且零拨号',
      () async {
    final server = await _startCannedServer('ok');
    final rec = _DialRecorder(server.port);
    try {
      final result = await IOOverrides.runWithIOOverrides(() {
        return fmNetRequest(
          const FmNetRequest(
              url: 'http://api.example.com/x', method: 'GET', headers: {}),
          lookup: (host, {type = _lookup}) async =>
              [InternetAddress('192.168.1.1')],
        );
      }, rec);
      expect(result, containsPair('error', 'target-not-allowed'));
      expect(rec.dialedIps, isEmpty);
      expect(rec.hostnameDials, isEmpty);
    } finally {
      await server.close();
    }
  });

  test('POST body / 响应头透传（行为零回归抽查）', () async {
    final server = await _startCannedServer('ok');
    final rec = _DialRecorder(server.port);
    try {
      final result = await IOOverrides.runWithIOOverrides(() {
        return fmNetRequest(
          const FmNetRequest(
              url: 'http://api.example.com/vod?id=1',
              method: 'POST',
              headers: {'x-a': '1'},
              body: 'hello'),
          lookup: (host, {type = _lookup}) async =>
              [InternetAddress('8.8.8.8')],
        );
      }, rec);
      expect(result, containsPair('status', 200));
      expect(result['body'], 'ok');
      expect(result['contentType'], 'text/plain');
      _expectPinned(
          dialedIps: rec.dialedIps,
          hostnameDials: rec.hostnameDials,
          validatedIps: ['8.8.8.8']);
    } finally {
      await server.close();
    }
  });

  test('错误码零回归：DNS 失败 ⇒ network-error；空 URL ⇒ bad-args', () async {
    final dnsFail = await fmNetRequest(
      const FmNetRequest(
          url: 'http://api.example.com/x', method: 'GET', headers: {}),
      lookup: (host, {type = _lookup}) async =>
          throw const SocketException('injected dns failure'),
    );
    expect(dnsFail, containsPair('error', 'network-error'));

    final badArgs = await fmNetRequest(
      const FmNetRequest(url: '', method: 'GET', headers: {}),
    );
    expect(badArgs, containsPair('error', 'bad-args'));
  });
}
