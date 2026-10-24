import 'dart:convert';
import 'dart:io';

import 'danmaku.dart';

/// Recursive resolver observations, never authoritative truth or proof of hijack.
enum DanmakuDnsComparison { overlap, different, unavailable }

DanmakuDnsComparison compareDanmakuDns(
  List<String> local,
  List<String> recursive,
) {
  if (local.isEmpty || recursive.isEmpty) {
    return DanmakuDnsComparison.unavailable;
  }
  return local.toSet().intersection(recursive.toSet()).isEmpty
      ? DanmakuDnsComparison.different
      : DanmakuDnsComparison.overlap;
}

/// Diagnose the actual HTTP route, including proxy, TLS and protocol response.
/// A successful TCP connection alone is not evidence of a working HTTP service.
Future<DanmakuHttpResponse> diagnoseDanmakuEndpoint(
  DanmakuEndpoint? endpoint, {
  DanmakuTransport? transport,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final t = transport ?? IoDanmakuTransport(
    timeout: timeout,
    findProxy: currentDanmakuFindProxy(),
  );
  try {
    final uri = endpoint?.resolve(
      DanmakuLocalService.searchProbePath, const {'keyword': 'a'},
    ) ?? Uri.http('127.0.0.1:2080', DanmakuLocalService.versionPath);
    return await t.send(
      method: 'GET', uri: uri,
      headers: const {'Accept': 'application/json'},
    ).timeout(timeout);
  } finally {
    if (transport == null) t.close();
  }
}

/// Independent recursive observations over the same selected HTTP route.
/// No credentials, URLs, response bodies or exceptions are logged.
/// The finite provider list excludes providers with disputed prior evidence.
Future<List<String>> lookupDanmakuDoh(
  String host, {
  String? findProxy,
  Duration timeout = const Duration(seconds: 5),
  Future<String> Function(Uri)? request,
}) async {
  if (host.isEmpty || InternetAddress.tryParse(host) != null) return [];
  final transport = request == null
      ? IoDanmakuTransport(
          timeout: timeout,
          findProxy: findProxy ?? currentDanmakuFindProxy(),
        )
      : null;
  final clock = Stopwatch()..start();
  try {
    for (final provider in const [
      'https://cloudflare-dns.com/dns-query',
      'https://doh.pub/dns-query',
      'https://dns.google/resolve',
    ]) {
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) break;
      final uri = Uri.parse(provider).replace(queryParameters: {
        'name': host,
        'type': 'A',
      });
      try {
        final text = await (request != null
            ? request(uri)
            : transport!.send(
                method: 'GET',
                uri: uri,
                headers: const {'Accept': 'application/dns-json'},
              ).then((response) {
                if (!response.isOk) throw const FormatException('DoH status');
                return response.body;
              })).timeout(
                Duration(microseconds: remaining.inMicroseconds ~/ 2),
              );
        final data = jsonDecode(text);
        if (data is! Map || data['Status'] != 0) continue;
        final answers = data['Answer'];
        if (answers is! List) continue;
        final addresses = <String>{};
        for (final answer in answers) {
          if (answer is! Map || answer['type'] != 1) continue;
          final address = InternetAddress.tryParse('${answer['data']}');
          if (address != null && address.type == InternetAddressType.IPv4) {
            addresses.add(address.address);
          }
        }
        if (addresses.isNotEmpty) return addresses.toList();
      } catch (_) {
        // One failed recursive provider does not invalidate the next provider.
      }
    }
    return [];
  } finally {
    transport?.close();
  }
}
