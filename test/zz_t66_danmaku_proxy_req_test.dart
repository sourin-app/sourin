// 判据② 真请求验证：代理**真的**被用上了吗？
//
// # 为什么必须"两条一起跑"
// ```text
// 只测 custom(不通代理) ⇒ target.received == 0
//   ⚠️ 这可能是"目标本来就不通"，与代理无关 ⇒ **证明不了任何事**
//
// 只测 direct ⇒ target.received == 1
//   ⚠️ 这只证明"直连能用"，证明不了 custom 时流量被导走了
//
// ⇒ 两条必须在**同一次 run、同一个 target** 上跑：
//      direct  ⇒ received == 1   （目标确实是活的）
//      custom  ⇒ received == 0   （同一个目标，换了代理就够不着）
//   两条一起才排除"目标本身不通"这个替代解释。
// ```
//
// # 三个角色
// ```text
//   target   ：本机 HTTP 服务，记录被访问次数 —— 判断"请求到没到"
//   deadProxy：本机 TCP 服务，accept 后**什么都不回** —— "不通的代理"
//              ★ 它 accept 但不响应 ≈ 真实的黑洞代理
//   danmaku  ：被测对象，走 IoDanmakuTransport + findProxy
// ```
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';

/// 一个只记录"被访问过几次"的本机 HTTP 服务
class _TargetServer {
  _TargetServer(this._server) {
    _server.listen((req) async {
      hits++;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.text
        ..write('ok');
      await req.response.close();
    });
  }

  final HttpServer _server;
  int hits = 0;

  int get port => _server.port;
  static Future<_TargetServer> start() async =>
      _TargetServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> stop() => _server.close(force: true);
}

/// "不通的代理"：accept 连接后**不读不写**，让调用方超时
///
/// # 为什么不用"端口无人监听"
/// ```text
/// 连一个 closed port 会立刻 ECONNREFUSED —— 那**也是**"代理生效"的证据，
/// 但它和"代理配置没被用上、直接连目标失败"在异常类型上可能混同。
/// 用 accept-但不响应 更接近真实的黑洞代理：
///   · 连接**建立了** ⇒ 证明 TCP 确实被导向了这个端口
///   · 但没有响应     ⇒ 请求到不了 target
/// ⇒ 这样"连上了但没数据"是本机可观测的、明确的代理生效证据。
/// ```
class _DeadProxy {
  _DeadProxy(this._server) {
    _server.listen((sock) {
      accepted++;
      // 故意什么都不做：不读、不写、不关。靠调用方超时。
      _held.add(sock);
    });
  }

  final ServerSocket _server;
  final List<Socket> _held = [];
  int accepted = 0;

  int get port => _server.port;
  static Future<_DeadProxy> start() async =>
      _DeadProxy(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

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
  late _TargetServer target;
  late _DeadProxy deadProxy;

  setUp(() async {
    target = await _TargetServer.start();
    deadProxy = await _DeadProxy.start();
    // ignore: avoid_print
    print('[REQ] target 端口=${target.port}  deadProxy 端口=${deadProxy.port}');
  });

  tearDown(() async {
    await target.stop();
    await deadProxy.stop();
  });

  /// 发一个真实 HTTP 请求到 target，返回 (是否成功, 异常文本)
  Future<({bool ok, String? err})> hit({
    String? findProxy,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final t = IoDanmakuTransport(timeout: timeout, findProxy: findProxy);
    try {
      final r = await t.send(
        method: 'GET',
        uri: Uri.parse('http://127.0.0.1:${target.port}/probe'),
        headers: const {},
      );
      return (ok: r.statusCode == 200, err: null);
    } catch (e) {
      return (ok: false, err: e.toString());
    } finally {
      t.close();
    }
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★ 核心：两条对照在**同一次 test 内**先后跑
  // ══════════════════════════════════════════════════════════════════
  test('② 代理真被用上：direct 到达 / custom(黑洞代理) 不到达', () async {
    /*
     * 顺序很重要：**先 direct 再 custom**。
     *
     * 理由：先证明"这个 target 是活的、这个路径是通的"，
     * 再证明"换配置后它不通了" ⇒ 差异只能来自配置本身。
     * 若反过来先跑 custom 得到 0，我们还不知道 target 到底能不能通。
     */
    final before = target.hits;
    final directRes = await hit(findProxy: 'DIRECT');
    final afterDirect = target.hits;
    final deadBefore = deadProxy.accepted;

    final customRes = await hit(
      findProxy: 'PROXY 127.0.0.1:${deadProxy.port}',
    );
    final afterCustom = target.hits;
    final deadAfter = deadProxy.accepted;

    // ignore: avoid_print
    print('[REQ] direct  ⇒ ok=${directRes.ok} err=${directRes.err} '
        'targetHits $before→$afterDirect');
    // ignore: avoid_print
    print('[REQ] custom  ⇒ ok=${customRes.ok} err=${customRes.err} '
        'targetHits $afterDirect→$afterCustom '
        'deadProxyAccepted $deadBefore→$deadAfter');

    // ── 对照 A：直连必须**真的到达** target ──
    expect(directRes.ok, isTrue,
        reason: '直连都不通 ⇒ target 本身有问题，后面那条没法解释');
    expect(afterDirect, before + 1,
        reason: '直连必须让 target 收到正好 1 次');

    // ── 对照 B：走黑洞代理必须**到不了** target ──
    expect(customRes.ok, isFalse, reason: '走了黑洞代理却成功了 ⇒ 代理没生效');
    expect(customRes.err, isNotNull);
    expect(afterCustom, afterDirect,
        reason: '★ 关键：target 命中数**不能增加** ⇒ 流量真的被导去了代理');

    // ── 对照 C：异常必须指向连接/代理层（"报错清晰"） ──
    final e = customRes.err!.toLowerCase();
    final looksLikeNet = e.contains('timeout') ||
        e.contains('timed out') ||
        e.contains('socket') ||
        e.contains('connection') ||
        e.contains('handshake');
    expect(looksLikeNet, isTrue,
        reason: '异常应能看出是连接层问题，实际=${customRes.err}');

    /*
     * ── 对照 D：黑洞代理**确实被连上过** ──
     *
     * ★★ 这条是整套判据里最硬的一条：
     * 它把"target 没收到"这个观测，和一个**正向证据**（代理端口 accept 过）
     * 绑在一起 ⇒ 不再是"什么也没发生"，而是"流量改道去了 X"。
     *
     * 没有这一条，received==0 仍可能是"请求根本没发出去"。
     */
    expect(deadAfter, greaterThan(deadBefore),
        reason: '★ 流量必须真的连到了代理端口 ⇒ 否则无法区分"改道"和"没发"');
    // ignore: avoid_print
    print('[REQ] ✅ 四条对照全部成立');
  });

  // ══════════════════════════════════════════════════════════════════
  //  附加：system 模式在**无环境变量**时应等同于直连
  // ══════════════════════════════════════════════════════════════════
  test('system(null) 在无 HTTPS_PROXY 时等同于直连', () async {
    final hasEnv = Platform.environment.containsKey('HTTPS_PROXY') ||
        Platform.environment.containsKey('https_proxy');
    final before = target.hits;
    final r = await hit(findProxy: resolveDanmakuFindProxy(
      mode: DanmakuProxyMode.system,
    ));
    // ignore: avoid_print
    print('[REQ] system ⇒ ok=${r.ok} err=${r.err} '
        'hasEnv=$hasEnv targetHits $before→${target.hits}');
    if (!hasEnv) {
      expect(r.ok, isTrue, reason: '无环境变量时 system 应等同直连');
      expect(target.hits, before + 1);
    } else {
      // 有环境变量时行为取决于那个代理 —— 只记录，不断言
      // ignore: avoid_print
      print('[REQ] ⚠️ 本机有 HTTPS_PROXY ⇒ system 走向取决于它，仅记录');
    }
  });
}
