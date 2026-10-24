import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/core/danmaku.dart';
import '../lib/core/danmaku_network_diagnostics.dart';

class ProbeTransport implements DanmakuTransport {
  final paths = <String>[];
  @override
  Future<DanmakuHttpResponse> send({required String method, required Uri uri,
    required Map<String, String> headers, String? body}) async {
    paths.add(uri.path);
    if (uri.path.endsWith('/anime')) {
      return DanmakuHttpResponse(statusCode: 200, body: '{"animes":[]}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return DanmakuHttpResponse(statusCode: 404, body: '{}');
  }
  @override
  void close() {}
}

void main() {
  test('system delegates to environment while direct stays explicit', () {
    final uri = Uri.parse('https://example.com');
    expect(danmakuProxyForUri(uri, null, environment: {
      'https_proxy': 'http://127.0.0.1:17890',
    }), 'PROXY 127.0.0.1:17890');
    expect(danmakuProxyForUri(uri, 'DIRECT', environment: {
      'https_proxy': 'http://127.0.0.1:17890',
    }), 'DIRECT');
  });
  test('public instance searches before slow unsupported metadata paths', () async {
    final t = ProbeTransport();
    final ep = DanmakuEndpoint.tryParse(kDanmakuPublicInstances.first.baseUrl,
      token: kDanmakuPublicInstances.first.token);
    final result = await DanmakuLocalService.probe(transport: t,
      endpoint: ep, timeout: const Duration(milliseconds: 50));
    expect(result.online, isTrue);
    expect(t.paths.single, endsWith('/anime'));
  });
  test('different recursive DNS answers are not proof of hijacking', () {
    expect(compareDanmakuDns(['192.0.2.1'], ['198.51.100.2']),
      DanmakuDnsComparison.different);
    expect(compareDanmakuDns([], []), DanmakuDnsComparison.unavailable);
  });
  test('DoH uses supplied transport and falls back without logging URLs', () async {
    final calls = <Uri>[];
    final result = await lookupDanmakuDoh('example.com', request: (uri) async {
      calls.add(uri);
      if (calls.length == 1) throw const SocketException('fixture');
      return '{"Status":0,"Answer":[{"type":1,"data":"192.0.2.1"}]}';
    });
    expect(calls.length, 2);
    expect(result, ['192.0.2.1']);
  });
}
