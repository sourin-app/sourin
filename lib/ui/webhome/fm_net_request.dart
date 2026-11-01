// ═══════════════════════════════════════════════════════════════════════
//  N3b webHome：net.request 宿主代发 —— 按已解析 IP 直连，闭合 TOCTOU
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么连接必须吃校验用的同一批 IP（T6 收窄 → N3b 闭合，Lead 批复）
// 判据①（fm_bridge.dart 字面量）+ 判据②（本文件解析段）在校验时解析了
// 目标主机的 IP；若连接时再解析一次（HttpClient 默认路径
// `_ConnectionTarget.connect → Socket.startConnect(host, port)`），
// 两次解析之间就是 DNS rebinding 的 TOCTOU 窗口。本文件给 HttpClient
// 设 `connectionFactory`，**只拨校验过的那批 IP**：解析与连接同源，
// 窗口闭合。
//
// # https 的坑（SDK 源码实锤，sdk/lib/_http/http_impl.dart）
// connectionFactory 路径下 SDK 对返回的 socket **不做 TLS 升级**
// （`SecureSocket.startConnect` 只在无 factory 的默认路径调用）；
// 而 `SecureSocket.startConnect(IP)` 会把 IP 当 SNI/校验主机名，
// 真域名证书必挂。解法：裸拨 IP 后 `SecureSocket.secure(raw,
// host: 原域名)`（SNI/证书校验保持按真域名，与 SDK 自身
// createProxyTunnel 同款机制），再经 `ConnectionTask.fromSocket`
// 包回 factory（Dart 3.13 稳定线 API，文档原文即为此场景而设）。
//
// # findProxy = DIRECT（有意的行为收紧，Lead 批复）
// 默认 findProxy 是 findProxyFromEnvironment（读 HTTP_PROXY 等）；
// 本机环境长期有 HTTP_PROXY=127.0.0.1:7890，走代理意味着校验通过后
// 代理仍可二次解析/重绑——SSRF 判据被架空（t69 假红事故元凶）。
// net.request 显式直连："校验的那个 IP 就是连接的那个 IP"。
//
// 备胎留档：若未来 SDK 变更使 fromSocket 不可用，退路是本机
// 127.0.0.1 CONNECT 中继（HttpClient 经 findProxy 指向它，中继拨
// 已验证 IP，https 由 SDK 走 createProxyTunnel 升级）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/app_log.dart';
import 'fm_bridge.dart';

/// DNS 解析缝：默认 [InternetAddress.lookup]（无 IOOverrides 钩子，
/// 必须 typedef 注入）。测试注入多次返回不同 IP 的解析器以证红。
typedef FmDnsLookup = Future<List<InternetAddress>> Function(String host,
    {InternetAddressType type});

/// 单次拨号（含 https 握手）超时，原 client.connectionTimeout 语义。
const Duration _netConnectTimeout = Duration(seconds: 10);

/// `net.request` 宿主代发（原 webhome_page._netRequest 整体迁入）。
///
/// 判据②：DNS 解析出的每个 IP 重过白名单；**连接只吃这批 IP**
/// （[_dialPinned]），解析与连接之间没有第二次 DNS —— TOCTOU 闭合。
Future<Map<String, Object?>> fmNetRequest(
  FmNetRequest req, {
  FmDnsLookup lookup = InternetAddress.lookup,
}) async {
  final uri = Uri.tryParse(req.url);
  if (uri == null || uri.host.isEmpty) {
    return const {'error': 'bad-args'};
  }
  try {
    // 判据②：解析一次，此后所有连接只拨这批地址（TOCTOU 闭合点）。
    final ips = await lookup(uri.host).timeout(const Duration(seconds: 10));
    if (!isNetRequestTargetAllowed(uri,
        resolvedIps: ips.map((e) => e.address))) {
      AppLog.write('WEBHOME', 'net.request rejected(dns): ${_describe(uri)}');
      return const {'error': 'target-not-allowed'};
    }
    final client = HttpClient()
      ..connectionTimeout = _netConnectTimeout
      ..connectionFactory = (requestUri, proxyHost, proxyPort) =>
          _dialPinned(ips, requestUri);
    // ★ DIRECT：绝不走 env 代理——代理会架空"校验 IP = 连接 IP"
    //   （t69 假红元凶 HTTP_PROXY=127.0.0.1:7890，理由见文件头）。
    //   不放进上面的级联：箭头函数体会把后续 `..` 吞成 String 级联。
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client.openUrl(req.method, uri);
      // ⚠️ headers 可能带凭据：只加不记。
      req.headers.forEach(request.headers.add);
      if (req.body != null) request.add(utf8.encode(req.body!));
      final response = await request.close().timeout(netRequestTimeout);
      final builder = BytesBuilder(copy: false);
      var total = 0;
      var truncated = false;
      await for (final chunk in response) {
        total += chunk.length;
        if (total > netResponseMaxBytes) {
          truncated = true;
          break;
        }
        builder.add(chunk);
      }
      final body = utf8.decode(builder.takeBytes(), allowMalformed: true);
      // ★ 日志只有 method + host + path（query 可能带 token，不给）。
      AppLog.write('WEBHOME',
          'net.request ${req.method} ${_describe(uri)} → ${response.statusCode}${truncated ? ' (truncated)' : ''}');
      return {
        'status': response.statusCode,
        'contentType': response.headers.value('content-type') ?? '',
        'body': body,
        if (truncated) 'truncated': true,
      };
    } finally {
      client.close(force: true);
    }
  } catch (e) {
    AppLog.write('WEBHOME', 'net.request failed: ${_describe(uri)} $e');
    return {'error': 'network-error'};
  }
}

/// 按校验过的 IP 顺序逐个拨号：连接失败试下一个，https 拨通后按
/// **原域名**做 TLS（SNI/证书校验与今天按主机名连接一致，握手失败
/// 终止——证书与主机绑定，与 IP 无关）。全程无第二次解析。
Future<ConnectionTask<Socket>> _dialPinned(
    List<InternetAddress> ips, Uri requestUri) {
  final secure = requestUri.scheme == 'https';
  ConnectionTask<Socket>? current;

  Future<Socket> dial() async {
    Object? lastError;
    for (final ip in ips) {
      try {
        current = await Socket.startConnect(ip, requestUri.port);
        final raw = await current!.socket.timeout(_netConnectTimeout);
        if (!secure) return raw;
        try {
          return await SecureSocket.secure(raw, host: requestUri.host);
        } catch (_) {
          raw.destroy();
          rethrow;
        }
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ??
        const SocketException('net.request: no resolved address to dial');
  }

  return Future.value(ConnectionTask.fromSocket(
    dial(),
    // HttpClient 超时/关闭时会 cancel —— 别把在途连接留在后台。
    () => current?.cancel(),
  ));
}

String _describe(Uri u) => '${u.host}${u.path}';
