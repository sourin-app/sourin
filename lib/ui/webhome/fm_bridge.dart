// ═══════════════════════════════════════════════════════════════════════
//  T6 webHome：fm 桥 —— 方法白名单 + SSRF 判据（纯函数，可门禁）
// ═══════════════════════════════════════════════════════════════════════
//
// # 对标（T2 ⑥）：参考实现 `ip1` 暴露 `window.fm` 全家桶；我们 V1 只开
// **六个方法**（设计书 .probe/t6-homepage-html-design.md 第五节白名单）：
//   player.playVod / app.openLive / net.request / cache.get|set|del /
//   log.write / ui.toast / navigation.back（页面内消化）。
// 任何不在白名单里的方法一律 `{error: 'unknown-method'}` —— 桥只暴露能力，
// 绝不把凭据 / getAllCookies / FFI 原生命令交给页面。
//
// # SSRF 为什么必须是纯函数
// `net.request` 是宿主代发（页面免 CORS 的 HTTP 客户端），等于把内网
// 暴露给任意 HTML。判据必须**两段**都过：
//   ① 字面量段（本文件，纯函数）：scheme 白名单 + 主机名/IP 字面量黑名单，
//      含尾点归一与十进制/十六进制整型主机（浏览器把它们按 IPv4 解析，
//      `2130706433` == `127.0.0.1`、`[::ffff:7f00:1]` 同理）；
//   ② 解析段（fm_net_request.dart）：DNS 解析出的**每个** IP 再过一遍 ①，
//      且连接只拨**校验过的那批 IP**（connectionFactory 直连）。
// # N3b（Lead 批复）：②的实现按已解析 IP 直连，解析与连接同源、
//    无第二次 DNS —— DNS rebinding 的 TOCTOU 窗口已**闭合**。
//    T6 互检 P2-1 的旧措辞"双判收窄窗口、未闭合"自本批起作废：
//    那描述的是 T6 时点（连接仍走 HttpClient 默认二次解析）的状态。
import 'dart:io';

/// fm 桥方法白名单（与注入 SDK `fm_sdk_js.dart` 一一对应，两处必须同改）
const String fmMethodPlayVod = 'player.playVod';
const String fmMethodOpenLive = 'app.openLive';
const String fmMethodNetRequest = 'net.request';
const String fmMethodCacheGet = 'cache.get';
const String fmMethodCacheSet = 'cache.set';
const String fmMethodCacheDel = 'cache.del';
const String fmMethodLogWrite = 'log.write';
const String fmMethodToast = 'ui.toast';

/// 页面里消化、不过 Dart 桥的方法（SDK 直接实现，不经 callHandler）
const String fmMethodGetViewport = 'ui.getViewport';
const String fmMethodBack = 'navigation.back';

/// net.request 响应体上限（设计书第五节：2MB）
const int netResponseMaxBytes = 2 * 1024 * 1024;

/// net.request 超时
const Duration netRequestTimeout = Duration(seconds: 20);

/// # 判据①：请求目标字面量是否放行
///
/// - scheme 只许 http/https（file:/data:/javascript: 一律拒）；
/// - 主机名黑名单：localhost / *.localhost / *.local / *.internal；
/// - **尾点归一**（`127.0.0.1.` 在 DNS 语义上就是 127.0.0.1）；
/// - **整型主机**按 IPv4 展开（`2130706433` → 127.0.0.1，浏览器同款语义）；
/// - IP 字面量过 [_ipAllowed]（含 ::ffff: 映射态，见其 IPv6 分支）；
/// - [resolvedIps] 非空时（判据②）逐个再过 [_ipAllowed]，**一个不合法全拒**。
bool isNetRequestTargetAllowed(
  Uri url, {
  Iterable<String> resolvedIps = const [],
}) {
  final scheme = url.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  var host = url.host.toLowerCase();
  if (host.isEmpty) return false;
  // 尾点归一：Uri.host 保留原样尾点，DNS 语义等价于剥掉
  while (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (host.isEmpty) return false;
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal')) {
    return false;
  }
  // 整型主机：浏览器/系统解析器把纯十进制按 IPv4 整数展开
  //（2130706433 = 127.0.0.1，134744072 = 8.8.8.8）。不显式处理的话，
  // 放行与否取决于 InternetAddress.tryParse 的实现细节 —— 意外 fail-open。
  final decimal = RegExp(r'^\d+$');
  if (decimal.hasMatch(host)) {
    final v = int.tryParse(host);
    if (v != null && v >= 0 && v <= 0xFFFFFFFF) {
      final ip = InternetAddress.tryParse(
          '${(v >> 24) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 8) & 0xFF}.${v & 0xFF}');
      // 展开后再过 IP 黑名单：127.0.0.1 类拒，公网类放行
      return ip != null && _ipAllowed(ip);
    }
    // 超出 32 位或非数值：不可能是真实 IPv4 整型，按普通域名走下面流程
  }
  final literal = InternetAddress.tryParse(host);
  if (literal != null && !_ipAllowed(literal)) return false;
  for (final raw in resolvedIps) {
    final ip = InternetAddress.tryParse(raw);
    if (ip == null || !_ipAllowed(ip)) return false;
  }
  return true;
}

/// 单个 IP 是否可出网（页面请求目标）。
/// 黑名单：回环 / 链路本地 / 多播 / 内网四大段 / 未指定地址 /
/// IPv6 唯一本地（fc00::/7）/ ::ffff: 映射的 IPv4（剥前缀再判）。
bool _ipAllowed(InternetAddress ip) {
  if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return false;
  if (ip.type == InternetAddressType.IPv4) {
    final o = ip.address.split('.');
    if (o.length != 4) return false;
    final a = int.tryParse(o[0]), b = int.tryParse(o[1]);
    if (a == null || b == null) return false;
    if (a == 0 || a == 10 || a == 127) return false; // 未指定 / 内网 / 回环
    if (a == 172 && b >= 16 && b <= 31) return false; // 172.16/12
    if (a == 192 && b == 168) return false; // 192.168/16
    if (a == 169 && b == 254) return false; // 169.254/16 链路本地
    if (a == 100 && b >= 64 && b <= 127) return false; // 100.64/10 CGNAT
    return true;
  }
  if (ip.type == InternetAddressType.IPv6) {
    // ★ IPv4-mapped（::ffff:0:0/96）按**字节**判定，不依赖字符串归一形态：
    //   '::ffff:7f00:1' 与 '::ffff:127.0.0.1' 是同一个地址，
    //   tryParse 对两种写法都能解析，字符串 startsWith 只兜住其中一种。
    final raw = ip.rawAddress; // 16 字节
    var mappedV4 = true;
    for (var i = 0; i < 10; i++) {
      if (raw[i] != 0) {
        mappedV4 = false;
        break;
      }
    }
    if (mappedV4 && raw[10] == 0xff && raw[11] == 0xff) {
      final v4 = InternetAddress.tryParse(
          '${raw[12]}.${raw[13]}.${raw[14]}.${raw[15]}');
      return v4 != null && _ipAllowed(v4);
    }
    final a = ip.address.toLowerCase();
    if (a.startsWith('fc') || a.startsWith('fd')) return false; // fc00::/7
    if (a == '::') return false; // 未指定地址
    return true;
  }
  return false;
}

/// `net.request` 的入参（SDK 传 `{url, method, headers, body}`）。
/// 解析失败返回 null（桥层回 `bad-args`），**绝不抛异常出桥**。
class FmNetRequest {
  const FmNetRequest({
    required this.url,
    required this.method,
    required this.headers,
    this.body,
  });

  final String url;
  final String method;

  /// ⚠️ 只作请求用，**禁止写进日志**（可能带 Authorization/Cookie）。
  final Map<String, String> headers;
  final String? body;

  static FmNetRequest? fromArgs(Object? args) {
    if (args is! Map) return null;
    final url = args['url'];
    if (url is! String || url.isEmpty) return null;
    final method = args['method'];
    final headers = <String, String>{};
    final rawHeaders = args['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k is String && v is String) headers[k] = v;
      });
    }
    final body = args['body'];
    return FmNetRequest(
      url: url,
      method: method is String && method.isNotEmpty ? method.toUpperCase() : 'GET',
      headers: headers,
      body: body is String ? body : null,
    );
  }
}

/// cache 配额判据（V1：5MB / 全局一个命名空间；超了拒绝写入并让页面拿到错误）。
const int webhomeCacheQuotaBytes = 5 * 1024 * 1024;

bool cacheWriteAllowed(int currentBytes, int incomingBytes, int quotaBytes) =>
    currentBytes + incomingBytes <= quotaBytes;

/// # 桥分发（能力注入式，纯逻辑可门禁）
///
/// 页面侧只有一个 handler 入口 `callHandler('fm', method, payload)`；
/// 这里按白名单分发。导航（back）/视口（getViewport）在 SDK 内直接实现，
/// 到不了 Dart；这里收到也按 unknown 拒（防御 SDK 被页面篡改后绕路）。
class FmBridge {
  FmBridge({
    required this.onPlayVod,
    required this.onOpenLive,
    required this.onNetRequest,
    required this.onCacheGet,
    required this.onCacheSet,
    required this.onCacheDelete,
    required this.onLog,
    required this.onToast,
  });

  final void Function(String provider, String id) onPlayVod;
  final void Function(String provider, String channelId, String name)?
      onOpenLive;
  final Future<Map<String, Object?>> Function(FmNetRequest req) onNetRequest;
  final Future<Object?> Function(String key) onCacheGet;
  final Future<bool> Function(String key, String value) onCacheSet;
  final Future<void> Function(String key) onCacheDelete;

  /// 日志出口（webhome_page 里落 AppLog；**只许 method+URL，禁 headers/body**）
  final void Function(String level, String message) onLog;
  final void Function(String message) onToast;

  /// 返回值直接成为页面 Promise 的 resolution。
  Future<Object?> dispatch(String method, Object? payload) async {
    switch (method) {
      case fmMethodPlayVod:
        final p = _asMap(payload);
        final provider = p?['provider'];
        final id = p?['id'];
        if (provider is! String ||
            provider.isEmpty ||
            id is! String ||
            id.isEmpty) {
          return const {'error': 'bad-args'};
        }
        onPlayVod(provider, id);
        return const {'ok': true};
      case fmMethodOpenLive:
        final p = _asMap(payload);
        final provider = p?['provider'];
        final channelId = p?['channelId'];
        if (provider is! String ||
            provider.isEmpty ||
            channelId is! String ||
            channelId.isEmpty) {
          return const {'error': 'bad-args'};
        }
        final name = p?['name'];
        onOpenLive?.call(
            provider, channelId, name is String ? name : channelId);
        return const {'ok': true};
      case fmMethodNetRequest:
        final req = FmNetRequest.fromArgs(payload);
        if (req == null) return const {'error': 'bad-args'};
        final uri = Uri.tryParse(req.url);
        if (uri == null || !isNetRequestTargetAllowed(uri)) {
          onLog('warn', 'net.request rejected: ${req._safeDescribe()}');
          return const {'error': 'target-not-allowed'};
        }
        return onNetRequest(req);
      case fmMethodCacheGet:
        final key = _stringArg(payload, 'key');
        if (key == null) return const {'error': 'bad-args'};
        return {'value': await onCacheGet(key)};
      case fmMethodCacheSet:
        final p = _asMap(payload);
        final key = p?['key'];
        final value = p?['value'];
        if (key is! String || key.isEmpty || value is! String) {
          return const {'error': 'bad-args'};
        }
        return {'ok': await onCacheSet(key, value)};
      case fmMethodCacheDel:
        final key = _stringArg(payload, 'key');
        if (key == null) return const {'error': 'bad-args'};
        await onCacheDelete(key);
        return const {'ok': true};
      case fmMethodLogWrite:
        final p = _asMap(payload);
        final level = p?['level'];
        final msg = p?['msg'];
        onLog(
          level is String ? level : 'log',
          msg is String ? msg : '',
        );
        return const {'ok': true};
      case fmMethodToast:
        final msg = _stringArg(payload, 'msg');
        if (msg == null) return const {'error': 'bad-args'};
        onToast(msg);
        return const {'ok': true};
      default:
        // ★ 白名单外一律拒 —— 这是"桥只暴露能力"的执行点。
        return const {'error': 'unknown-method'};
    }
  }

  static Map<dynamic, dynamic>? _asMap(Object? o) => o is Map ? o : null;

  static String? _stringArg(Object? payload, String key) {
    final p = _asMap(payload);
    final v = p?[key];
    return v is String && v.isNotEmpty ? v : null;
  }
}

extension on FmNetRequest {
  /// 日志安全描述：只有 method + host + path，**永不带 query/headers/body**
  /// （query 里可能有 token）。凭据零打印是批次纪律。
  String _safeDescribe() {
    final u = Uri.tryParse(url);
    if (u == null) return '<unparseable>';
    return '$method ${u.host}${u.path}';
  }
}
