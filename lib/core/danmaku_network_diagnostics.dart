import 'dart:convert';
import 'dart:io';

import 'danmaku.dart';

/// Recursive resolver observations, never authoritative truth or proof of hijack.
///
/// ⚠️ [different] **不等于**劫持 —— 它只说"两边没有重合"。见 [compareDanmakuDns]。
enum DanmakuDnsComparison { overlap, different, unavailable }

/// 两个地址是否在**同一子网粒度**上（IPv4 前 3 段 = /24；IPv6 前 3 个 hextet = /48）
///
/// # 为什么需要这层容差（2026-10-25 实网实测）
/// ```text
/// 同一域名、同一天，三家真 DoH 给出的 A 记录：
///   cloudflare / doh.pub / 1.12.12.12 → 216.198.79.131 · 64.29.17.131
///   dns.google 第一次            → 216.198.79.195 · 64.29.17.195
///   dns.google 第二次            → 216.198.79.67  · 64.29.17.67
/// ⇒ 真实 CDN（Vercel 这类）**本来就在同一个 /24 里换末位**，
///   连"权威源自己跟自己"都会不同。
/// ⇒ 若判据是"集合求交为空 ⇒ different"，那么**完全健康的网络**里
///   本机拿 .67、DoH 拿 .131 也会被判 different，进而被说成"可能被劫持"
///   —— 把用户推去改一个没坏的 DNS。
/// ```
/// ⇒ 同一 /24（IPv6 /48）视为 `overlap`。真正跨运营商段的"完全不同"
///   仍会落到 `different`，再叠加伪造段表才够得上"劫持"。
bool sameDnsSubnet(String a, String b) {
  final x = a.trim().toLowerCase();
  final y = b.trim().toLowerCase();
  if (x.isEmpty || y.isEmpty) return false;
  final v4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.\d{1,3}$');
  final mx = v4.firstMatch(x);
  final my = v4.firstMatch(y);
  if (mx != null && my != null) {
    return mx.group(1) == my.group(1) &&
        mx.group(2) == my.group(2) &&
        mx.group(3) == my.group(3);
  }
  if (x.contains(':') && y.contains(':')) {
    List<String> head(String v) =>
        v.split(':').where((s) => s.isNotEmpty).take(3).toList();
    final hx = head(x);
    final hy = head(y);
    if (hx.length < 3 || hy.length < 3) return false;
    return hx[0] == hy[0] && hx[1] == hy[1] && hx[2] == hy[2];
  }
  return false;
}

/// 本机解析 vs 递归解析（DoH）的关系
///
/// - `overlap`：有完全相同的地址，**或**在同一 /24（IPv6 /48）里 ⇒ 视为一致
/// - `different`：跨网段完全不重合（可能是多 A/CDN，也可能是劫持 —— 由调用方
///   再叠加"是否落在已知伪造段"决定要不要说劫持）
/// - `unavailable`：任一侧为空（没得比）
DanmakuDnsComparison compareDanmakuDns(
  List<String> local,
  List<String> recursive,
) {
  if (local.isEmpty || recursive.isEmpty) {
    return DanmakuDnsComparison.unavailable;
  }
  if (local.toSet().intersection(recursive.toSet()).isNotEmpty) {
    return DanmakuDnsComparison.overlap;
  }
  for (final l in local) {
    for (final r in recursive) {
      if (sameDnsSubnet(l, r)) return DanmakuDnsComparison.overlap;
    }
  }
  return DanmakuDnsComparison.different;
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
