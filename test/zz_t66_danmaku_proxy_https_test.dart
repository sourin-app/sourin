// 判据②- HTTPS：走代理时，代理端口上**看到的是什么**？
//
// # 为什么这条比 HTTP 那条更重要
// ```text
// 弹幕真实请求走 **https**（官方接口）。
// 若 HTTPS 不经 CONNECT 隧道而直接把明文打到代理端口：
//   ① 功能上是坏的（代理看不懂明文 GET）
//   ② 安全上是降级的（用户以为在走加密隧道，实际明文外泄）
// ⇒ 「通不通」事小，「用什么方式」事大。
// ```
//
// # 三种可能，本文件逐个断言
// ```text
//   a) CONNECT host:443 HTTP/1.1   ⇒ 正常隧道       ← 期望结果
//   b) GET https://... HTTP/1.1    ⇒ ★ 降级为明文   ← 必须红
//   c) 代理端口什么都没收到         ⇒ 请求根本没走代理 ← 必须红
// ```
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';

/// 记录型代理：记下客户端对代理说的第一个包，然后**不回**（让它超时）
///
/// ★ 为什么"记录后不回"而不是真转发：
///   我们只关心**请求行**（CONNECT vs GET），不关心隧道里的数据。
///   真转发要自己实现 CONNECT 双向 pipe，噪声大、易错，而观测价值相同。
class _SnitchProxy {
  _SnitchProxy(this._server) {
    _server.listen((sock) {
      accepted++;
      final buf = <int>[];
      sock.listen((d) {
        if (buf.length < 8192) buf.addAll(d);
      }, onError: (_) {});
      _held.add(sock);
      // 给它一点时间把请求头发完，再收走连接
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (firstBytes.isEmpty) {
          firstBytes = utf8.decode(buf, allowMalformed: true);
        }
        try {
          sock.destroy();
        } catch (_) {}
      });
    });
  }

  final ServerSocket _server;
  final List<Socket> _held = [];
  int accepted = 0;
  String firstBytes = '';

  String get firstLine {
    final i = firstBytes.indexOf('\r\n');
    return i < 0 ? firstBytes.trim() : firstBytes.substring(0, i);
  }

  int get port => _server.port;

  static Future<_SnitchProxy> start() async =>
      _SnitchProxy(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> stop() async {
    for (final s in _held) {
      try {
        s.destroy();
      } catch (_) {}
    }
    await _server.close();
  }
}

void main() {
  late _SnitchProxy proxy;

  setUp(() async => proxy = await _SnitchProxy.start());
  tearDown(() async => proxy.stop());

  /// 用**生产构造**发一次请求（走我们自己的 findProxy 解析）
  Future<({bool ok, String? err})> viaProxy({
    required String url,
    required DanmakuProxyMode mode,
    String proxyUrl = '',
  }) async {
    final t = IoDanmakuTransport(
      timeout: const Duration(seconds: 2),
      findProxy: resolveDanmakuFindProxy(mode: mode, url: proxyUrl),
    );
    try {
      final r = await t.send(
        method: 'GET',
        uri: Uri.parse(url),
        headers: const {},
      );
      return (ok: r.statusCode > 0, err: null);
    } catch (e) {
      return (ok: false, err: e.runtimeType.toString());
    } finally {
      t.close();
    }
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★ 核心：HTTPS 必须走 CONNECT，不许降级成明文
  // ══════════════════════════════════════════════════════════════════
  test('★ HTTPS 经代理 ⇒ 代理端口必须收到 CONNECT（不是明文 GET）', () async {
    final before = proxy.accepted;
    final r = await viaProxy(
      // 用 .invalid 域（RFC 6761 保证不解析）—— 我们要的不是"连上"，
      // 而是"客户端对代理说了什么"。DNS 不解析不影响 CONNECT 行的产生。
      url: 'https://probe.invalid/hello',
      mode: DanmakuProxyMode.custom,
      proxyUrl: 'http://127.0.0.1:${proxy.port}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final line = proxy.firstLine;
    // ignore: avoid_print
    print('[HTTPS] result ok=${r.ok} err=${r.err}');
    // ignore: avoid_print
    print('[HTTPS] accepted +${proxy.accepted - before}');
    // ignore: avoid_print
    print('[HTTPS] ▶ 代理收到的请求行 = "$line"');

    // ── 判据 1：流量**必须**到了代理（否则配置无效）──
    expect(proxy.accepted, greaterThan(before),
        reason: 'c) 代理端口什么都没收到 ⇒ HTTPS 请求根本没走代理');

    // ── 判据 2：★★ 必须是 CONNECT，不能是明文 GET ──
    final upper = line.toUpperCase();
    expect(upper.startsWith('CONNECT'), isTrue,
        reason: 'b) 期望 "CONNECT host:443"，实际 "$line" '
            '⇒ 若为 GET 说明 HTTPS 被降级成明文（功能坏 + 安全降级）');

    // ── 判据 3：CONNECT 的目标必须带 443（说明走的是 TLS 隧道）──
    expect(line.contains(':443'), isTrue,
        reason: 'CONNECT 目标应含 :443，实际 "$line"');

    // ── 判据 4：**不许**出现明文 URL ──
    expect(line.contains('https://'), isFalse,
        reason: '请求行里出现完整 https:// URL ⇒ 加密被剥掉了');
  });

  // ══════════════════════════════════════════════════════════════════
  //  对照：HTTP 应当是明文 GET（证明上面那条不是因为"什么都记不到"）
  // ══════════════════════════════════════════════════════════════════
  test('对照：HTTP 经代理 ⇒ 明文 GET（证明探针真的能抓到请求行）', () async {
    final before = proxy.accepted;
    await viaProxy(
      url: 'http://probe.invalid/hello',
      mode: DanmakuProxyMode.custom,
      proxyUrl: 'http://127.0.0.1:${proxy.port}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final line = proxy.firstLine;
    // ignore: avoid_print
    print('[HTTPS] 对照(HTTP) ▶ "$line"');

    expect(proxy.accepted, greaterThan(before));
    /*
     * ★ 这条对照不能省：
     * 若探针本身录不到任何东西（比如 accept 后立刻被 destroy），
     * 上面那条 `upper.startsWith('CONNECT')` 会因为 line=='' 而红，
     * 但我们无法区分"HTTPS 没用 CONNECT"和"探针坏了"。
     * ⇒ 用 HTTP 证明探针能抓到请求行，且抓到的确实是明文 GET。
     */
    expect(line.toUpperCase().startsWith('GET'), isTrue,
        reason: 'HTTP 应走明文 GET，实际 "$line" ⇒ 探针可能没工作');
  });

  // ══════════════════════════════════════════════════════════════════
  //  直连时**不该**碰代理端口
  // ══════════════════════════════════════════════════════════════════
  test('direct 模式 ⇒ HTTPS 请求不碰代理端口', () async {
    final before = proxy.accepted;
    await viaProxy(
      url: 'https://probe.invalid/hello',
      mode: DanmakuProxyMode.direct,
    );
    await Future<void>.delayed(const Duration(milliseconds: 700));

    // ignore: avoid_print
    print('[HTTPS] direct ⇒ accepted +${proxy.accepted - before}');
    expect(proxy.accepted, before,
        reason: 'direct 模式下请求不该经过代理端口');
  });
}
