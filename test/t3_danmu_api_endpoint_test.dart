// ═══════════════════════════════════════════════════════════════════════
//  T3 · 自建弹幕服务后端（dan-api / danmu_api）—— 离线单测
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景
// ```text
// 弹弹play 官方要 AppId/AppSecret 签名，本仓没有凭证 ⇒ 403。
// 自建弹幕服务（danmu_api 这类）免凭证、且与弹弹play **协议同构**
// ⇒ 给客户端一个「可配置 baseUrl」就能绕开凭证问题。
// ```
//
// # 本文件守什么
// ```text
// ① DanmakuEndpoint 解析：地址归一化 / token 前缀 / 非法输入不炸
// ② 请求真的落在用户填的地址上，且**不发签名头**（免凭证的证据）
// ③ 协议兼容：danmu_api 的真实响应形状能被仓内解析器吃下
// ④ ★ 探测端点：只认 /api/v2/system/version 会把活着的自建服务判成不可用
//    （真缺陷）⇒ 现在必须按序试两个端点
// ⑤ ★ 故障注入：服务不可用时**如实回退**，不许假装成功
// ```
//
// ⚠️ 全程**不联网**：所有请求都走注入的假 transport。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

// ── 假传输层（形状对齐 t27_w5_danmaku_source_test.dart）─────────────

class _RecTransport implements DanmakuTransport {
  _RecTransport(this.handler);

  final Future<DanmakuHttpResponse> Function(
      String method, Uri uri, Map<String, String> headers, String? body) handler;
  final List<({String method, Uri uri, Map<String, String> headers})> calls = [];
  bool closed = false;

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) {
    calls.add((method: method, uri: uri, headers: Map.of(headers)));
    return handler(method, uri, headers, body);
  }

  @override
  void close() => closed = true;
}

DanmakuHttpResponse _json(Object o, {int status = 200}) => DanmakuHttpResponse(
      statusCode: status,
      body: jsonEncode(o),
      headers: const {'content-type': 'application/json'},
    );

/// 一条 danmu_api 真实形状的弹幕（实测样本，2026-10-16）
Map<String, Object?> _danmuApiComment(int cid, String p, String m) =>
    <String, Object?>{'cid': cid, 'p': p, 'm': m, 't': 0};

void main() {
  setUp(() => UiPrefs.debugResetForTest());

  // ═══════════════════════════════════════════════════════════════════
  //  ① DanmakuEndpoint 解析
  // ═══════════════════════════════════════════════════════════════════

  group('① DanmakuEndpoint：地址解析与归一化', () {
    test('完整 URL：协议/主机/端口都照用户填的来', () {
      final ep = DanmakuEndpoint.tryParse('http://192.168.1.7:9321')!;
      expect(ep.scheme, 'http');
      expect(ep.host, '192.168.1.7');
      expect(ep.hasPort, isTrue);
      expect(ep.port, 9321);
      expect(ep.display, 'http://192.168.1.7:9321');
    });

    test('不带协议：按 http 兜底（用户常只填 host:port）', () {
      final ep = DanmakuEndpoint.tryParse('127.0.0.1:9321')!;
      expect(ep.scheme, 'http');
      expect(ep.host, '127.0.0.1');
      expect(ep.port, 9321);
    });

    test('https 原样保留（用户可能挂了反代）', () {
      final ep = DanmakuEndpoint.tryParse('https://dm.example.com')!;
      expect(ep.scheme, 'https');
      expect(ep.host, 'dm.example.com');
      expect(ep.hasPort, isFalse);
    });

    test('★ 非法/空输入返回 null（不抛 —— 填错地址不该炸掉取弹幕）', () {
      expect(DanmakuEndpoint.tryParse(''), isNull);
      expect(DanmakuEndpoint.tryParse('   '), isNull);
      expect(DanmakuEndpoint.tryParse('http://'), isNull);
    });


    test('token 前缀：/{token}{path}，空 token 时原样', () {
      const withToken = DanmakuEndpoint(baseUrl: '127.0.0.1:9321', token: '87654321');
      expect(withToken.prefixedPath('/api/v2/match'), '/87654321/api/v2/match');

      const noToken = DanmakuEndpoint(baseUrl: '127.0.0.1:9321');
      expect(noToken.prefixedPath('/api/v2/match'), '/api/v2/match');
    });

    test('resolve() 产出可用的请求 URI（含 token 前缀 + 查询串）', () {
      const ep = DanmakuEndpoint(baseUrl: '127.0.0.1:9321', token: 'abc');
      final u = ep.resolve('/api/v2/search/anime', {'keyword': '火影'});
      expect(u.scheme, 'http');
      expect(u.host, '127.0.0.1');
      expect(u.port, 9321);
      expect(u.path, '/abc/api/v2/search/anime');
      expect(u.queryParameters['keyword'], '火影');
    });

    test('★ display 不泄漏 token（状态行要能安全显示）', () {
      const ep = DanmakuEndpoint(baseUrl: 'http://h:1', token: 'SECRET123');
      expect(ep.display, 'http://h:1');
      expect(ep.display.contains('SECRET123'), isFalse,
          reason: '★ 状态行会把 display 显示给用户 ⇒ 绝不能带 token');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 请求真的打到用户填的地址，且免签名
  // ═══════════════════════════════════════════════════════════════════

  group('② 自建后端模式：落在用户地址上 + 不发签名头', () {
    test('★ match 请求落在 endpoint，且**没有**签名三件套', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({
            'errorCode': 0,
            'success': true,
            'isMatched': true,
            'matches': [
              {'episodeId': 9527, 'animeTitle': '攻壳', 'episodeTitle': '1', 'shift': 0},
            ],
          }));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: 'http://192.168.1.7:9321'),
        // 故意带凭证：自建模式也**绝不**发签名头
        appId: 'myid',
        appSecret: 'mysecret',
      );
      final res = await c.match(fileName: 'A.mp4');
      expect(res, isNotEmpty);
      expect(t.calls, isNotEmpty);
      final call = t.calls.first;
      expect(call.uri.host, '192.168.1.7');
      expect(call.uri.port, 9321);
      expect(call.uri.scheme, 'http');
      expect(call.uri.path, '/api/v2/match');
      expect(call.headers.containsKey('X-AppId'), isFalse,
          reason: '★ 自建服务免凭证 —— 发了签名头反而可能被当非法头');
      expect(call.headers.containsKey('X-Timestamp'), isFalse);
      expect(call.headers.containsKey('X-Signature'), isFalse);
      c.close();
    });

    test('token 前缀出现在**真实请求路径**上', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({
            'count': 1,
            'comments': [_danmuApiComment(1, '1.0,1,16777215,[qq]', 'hi')],
          }));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(
            baseUrl: 'http://127.0.0.1:9321', token: '87654321'),
      );
      await c.fetchComments(9527);
      expect(t.calls.first.uri.path, '/87654321/api/v2/comment/9527');
      c.close();
    });

    test('★ 没配 endpoint ⇒ 行为与改前逐字一致（官方 + 签名头）', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({
            'isMatched': true,
            'matches': [
              {'episodeId': 9527, 'animeTitle': 'A', 'episodeTitle': '1'},
            ],
          }));
      final c = ExternalDanmakuClient(transport: t, appId: 'myid', appSecret: 'b');
      await c.match(fileName: 'A.mp4');
      final call = t.calls.first;
      expect(call.uri.host, 'api.dandanplay.net');
      expect(call.uri.scheme, 'https');
      expect(call.headers['X-AppId'], 'myid');
      expect(call.headers.containsKey('X-Signature'), isTrue);
      c.close();
    });

    test('★ endpoint 优先级**高于** unsignedLocal（两个都传时走 endpoint）', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({
            'isMatched': false,
            'matches': [],
          }));
      final c = ExternalDanmakuClient(
        transport: t,
        unsignedLocal: true,
        endpoint: const DanmakuEndpoint(baseUrl: 'http://10.0.0.5:8080'),
      );
      await c.match(fileName: 'A.mp4');
      expect(t.calls.first.uri.host, '10.0.0.5');
      expect(t.calls.first.uri.port, 8080);
      c.close();
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 协议兼容：danmu_api 真实响应形状能被仓内解析器吃下
  // ═══════════════════════════════════════════════════════════════════

  group('③ 协议兼容：danmu_api 的真实响应形状', () {
    test('★ comment 响应（cid/p/m 超集）能解析出弹幕', () async {
      // 形状逐字取自 2026-10-16 实测：danmu_api 多返回 t / like 字段
      final t = _RecTransport((m, uri, h, b) async => _json({
            'count': 3,
            'comments': [
              _danmuApiComment(1, '0.00,1,16777215,[qq]', '怎么感觉都没人看啊？'),
              _danmuApiComment(2, '1.50,5,16711680,[bilibili1]', '顶部弹幕'),
              _danmuApiComment(3, '2.00,4,255,[youku]', '底部弹幕'),
            ],
          }));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      final cs = await c.fetchComments(9527);
      expect(cs.length, 3);
      // 排序按时间
      expect(cs[0].time, 0.0);
      expect(cs[0].text, '怎么感觉都没人看啊？');
      expect(cs[0].mode, DanmakuMode.scroll);
      expect(cs[1].mode, DanmakuMode.top);
      expect(cs[1].color, 0xFF0000);
      expect(cs[2].mode, DanmakuMode.bottom);
      expect(cs[2].color, 0x0000FF);
      // uid 段（danmu_api 用 [qq] 这种来源标记）也要读出来
      expect(cs[0].userId, '[qq]');
      c.close();
    });

    test('★ search/episodes 响应（animes[].episodes[]）能解析', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({
            'errorCode': 0,
            'success': true,
            'animes': [
              {
                'animeId': 5030856,
                'animeTitle': '间谍过家家 第二季(2023)【日番】from bilibili',
                'episodes': [
                  {'episodeId': 18406, 'episodeTitle': '【bilibili1】 第26话'},
                ],
              },
            ],
          }));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      final ms = await c.searchEpisodes(anime: '间谍过家家');
      expect(ms.length, 1);
      expect(ms.first.episodeId, 18406);
      expect(ms.first.episodeTitle, contains('第26话'));
      c.close();
    });

    test('★ 业务错误（429 限流）走仓内既有分支，提示"被限流"', () async {
      // 形状逐字取自实测：danmu_api 限流返回
      final t = _RecTransport((m, uri, h, b) async => _json({
            'errorCode': 429,
            'success': false,
            'errorMessage': 'Too many requests, please try again later',
          }, status: 429));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      await expectLater(
        c.fetchComments(9527),
        throwsA(isA<DanmakuException>().having(
            (e) => e.statusCode, 'statusCode', 429)),
      );
      c.close();
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ ★ 探测端点：真缺陷 —— 只认 version 会把活着的服务判死
  // ═══════════════════════════════════════════════════════════════════

  group('④ 探测端点：自建服务必须能被探到（改前是假阴性）', () {
    test('★ 只有 /api/config 的自建服务 ⇒ 必须判**在线**（改前判死）', () async {
      // 实测 danmu_api：/api/v2/system/version → 404，/api/config → 200
      final t = _RecTransport((m, uri, h, b) async {
        if (uri.path.endsWith('/api/v2/system/version')) {
          return _json({'message': 'Not found'}, status: 404);
        }
        if (uri.path.endsWith('/api/config')) {
          return _json({'message': 'Welcome', 'version': '1.21.5'});
        }
        return _json({'message': 'Not found'}, status: 404);
      });
      final st = await DanmakuLocalService.probe(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      expect(st.online, isTrue,
          reason: '★★ 服务活着（/api/config 200）却被判成不可用 = 假阴性；'
              '改前只认 /api/v2/system/version ⇒ 正是这个 bug');
      expect(st.version, '1.21.5');
    });

    test('两个端点都没有 ⇒ 判离线（不误报在线）', () async {
      final t = _RecTransport((m, uri, h, b) async =>
          _json({'message': 'Not found'}, status: 404));
      final st = await DanmakuLocalService.probe(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      expect(st.online, isFalse);
    });

    test('★ 本机弹弹play（只有 versionCode）仍然探得到 —— 老路径不回归', () async {
      final t = _RecTransport((m, uri, h, b) async {
        if (uri.path.endsWith('/api/v2/system/version')) {
          return _json({'versionCode': '1.4.2'});
        }
        return _json({'message': 'Not found'}, status: 404);
      });
      final st = await DanmakuLocalService.probe(transport: t);
      expect(st.online, isTrue);
      expect(st.version, '1.4.2');
      expect(st.endpoint, isNull, reason: '★ 没传 endpoint ⇒ 探的是本机弹弹play');
      expect(st.line, contains('本机外部弹幕'));
    });

    test('★ 状态行区分「自建服务」与「本机弹弹play」（排错方向不同）', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({'version': '9.9'}));
      final st = await DanmakuLocalService.probe(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: 'http://10.1.2.3:9321'),
      );
      expect(st.line, contains('自建弹幕服务'));
      expect(st.line, contains('10.1.2.3'));
      expect(st.line.contains('本机外部弹幕'), isFalse,
          reason: '★ 自建后端与本机弹弹play 不能混为一谈');
    });

    test('探测失败（连接拒绝）⇒ 安静返回离线，不抛', () async {
      final t = _RecTransport((m, uri, h, b) async =>
          throw const SocketException('connection refused'));
      final st = await DanmakuLocalService.probe(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      expect(st.online, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ ★★ 故障注入：服务不可用时如实回退，不许假装成功
  // ═══════════════════════════════════════════════════════════════════

  group('⑤ ★★ 故障注入：不可用时如实回退到原路径', () {
    test('★ 自建后端全挂 ⇒ select() 回退 official（不是 local、更不是 custom）', () async {
      final t = _RecTransport((m, uri, h, b) async =>
          throw const SocketException('refused'));
      final kind = await DanmakuSourceSelector.select(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      expect(kind, DanmakuSourceKind.official,
          reason: '★★ 探测失败必须**如实**回退官方；'
              '若这里返回 custom/local，就是「假装服务还在」');
    });

    test('★ 自建后端活着 ⇒ select() 返回 custom（与本机 local 区分）', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({'version': '1.0'}));
      final kind = await DanmakuSourceSelector.select(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      expect(kind, DanmakuSourceKind.custom);
    });

    test('★ 本机弹弹play 活着 ⇒ 仍然返回 local（老语义不变）', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({'versionCode': '1.0'}));
      final kind = await DanmakuSourceSelector.select(transport: t);
      expect(kind, DanmakuSourceKind.local);
    });

    test('★ 取弹幕时服务挂了 ⇒ 抛异常（如实），**不**静默返回空列表', () async {
      final t = _RecTransport((m, uri, h, b) async =>
          throw const SocketException('refused'));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      // 必须抛：静默空列表会让用户以为「这部番没弹幕」
      await expectLater(c.fetchComments(9527), throwsA(isA<Object>()));
      c.close();
    });

    test('★ 假 transport 关掉了真网络 —— 本组全程零联网', () {
      // 阳性对照：确认我们注入的 transport 真的被用上（否则上面的断言在测空气）
      final t = _RecTransport((m, uri, h, b) async => _json({'ok': 1}));
      final c = ExternalDanmakuClient(transport: t);
      expect(t.calls, isEmpty, reason: '还没发请求');
      c.close();
      expect(t.closed, isTrue, reason: '★ close() 必须传导到注入的 transport');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑦ ★ 空关键词：不发请求（Lead 裁决收紧的存量缺陷）
  // ═══════════════════════════════════════════════════════════════════

  group('⑦ 空关键词不发请求', () {
    test('★ 两个都空 ⇒ 返回空列表，且**一个请求都不发**', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({
            'errorCode': 400,
            'success': false,
            'errorMessage': 'Missing anime parameter',
          }, status: 400));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      final ms = await c.searchEpisodes();
      expect(ms, isEmpty);
      expect(t.calls, isEmpty,
          reason: '★ 空关键词**不该发请求**：发出去只是浪费往返 + 换回 400');
      c.close();
    });

    test('★ 纯空白也算空（用户清空输入框后回车）', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({'animes': []}));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      expect(await c.searchEpisodes(anime: '   '), isEmpty);
      expect(await c.searchEpisodes(anime: '  ', episode: '  '), isEmpty);
      expect(t.calls, isEmpty, reason: '★ 空白串不是关键词');
      c.close();
    });

    test('★ 阳性对照：有关键词时**照发**（守卫不许过度触发）', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({'animes': []}));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      await c.searchEpisodes(anime: '火影');
      expect(t.calls, hasLength(1), reason: '★ 有关键词就必须真的搜');
      expect(t.calls.first.uri.queryParameters['anime'], '火影');
      c.close();
    });

    test('★ loadFor(anime: 空) 仍然**明确抛错** —— 不是静默返回空弹幕', () async {
      final t = _RecTransport((m, uri, h, b) async {
        if (uri.path == '/api/v2/match') {
          return _json({'success': true, 'matches': []});
        }
        return _json({'success': true, 'animes': []});
      });
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: '127.0.0.1:9321'),
      );
      // ★ 关键：调用方必须能区分「没搜」与「搜了没有」——
      //   这里必须抛，绝不能返回空 comments 让 UI 显示「这部番没弹幕」
      await expectLater(
        c.loadFor(fileName: 'EP03'),
        throwsA(isA<DanmakuException>().having(
            (e) => e.message, 'message', contains('没有匹配到弹幕库'))),
      );
      c.close();
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑧ ★★ 安全（CWE-532）：异常里的地址不许带 token 明文
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 漏洞链
  // ```text
  // ① 自建后端把 token 放**路径前缀**（/<token>/api/v2/…）
  // ② _decode 抛 DanmakuException 时把 uri.toString() 原样带进去
  // ③ 该异常会显示给用户、也进日志 ⇒ token 明文泄露
  // ```
  //
  // ⚠️ _decode 里有 **6 处** uri.toString()（6 条不同的失败分支）。
  //    只测一条 = 只覆盖一个渲染分支 —— 这正是上一轮 token 不回显踩过的坑。
  //    ⇒ 下面**逐条**覆盖全部 6 条分支。

  group('⑧ ★★ 异常里的地址不含 token 明文（CWE-532）', () {
    const token = 'SUPERSECRETTOKEN';
    const endpointWithToken = DanmakuEndpoint(
      baseUrl: 'http://127.0.0.1:9321',
      token: 'SUPERSECRETTOKEN',
    );

    /// 造假 transport + 带 token 的客户端，捕获 [fetchComments] 抛出的异常。
    Future<DanmakuException> failing(
      DanmakuHttpResponse resp, {
      DanmakuEndpoint? endpoint = endpointWithToken,
    }) async {
      final t = _RecTransport((m, uri, h, b) async => resp);
      final c = ExternalDanmakuClient(transport: t, endpoint: endpoint);
      try {
        await c.fetchComments(9527);
        fail('这条响应本应抛异常');
      } on DanmakuException catch (e) {
        return e;
      } finally {
        c.close();
      }
    }

    /// 一条用例要同时成立的三件事（脱敏 + 可读 + 请求仍用原地址）
    void expectRedacted(DanmakuException e, String branch) {
      expect(e.uri.contains(token), isFalse,
          reason: '★★ [$branch] token 明文进了异常：${e.uri}');
      expect(e.detail.contains(token), isFalse,
          reason: '★★ [$branch] token 明文进了 detail（UI 会显示这个）：${e.detail}');
      expect(e.toString().contains(token), isFalse,
          reason: '★★ [$branch] token 明文进了 toString（日志会打这个）');
      // ★ 阳性对照：必须**确实**做了替换，而不是恰好没记录地址
      expect(e.uri, contains('***'),
          reason: '★ [$branch] 没看到打码形态 —— 若 uri 本来就是空的，'
              '上面那三条会「因为没写地址」而假绿');
      expect(e.uri, contains('/api/v2/comment/9527'),
          reason: '★ [$branch] 打码后仍要能看出打的是哪个端点（否则排错没线索）');
    }

    test('★ 分支①：403（业务拒绝）', () async {
      final e = await failing(const DanmakuHttpResponse(
          statusCode: 403, body: 'nope', headers: <String, String>{}));
      expectRedacted(e, '403');
    });

    test('★ 分支②：非 2xx（HTTP 500）', () async {
      final e = await failing(const DanmakuHttpResponse(
          statusCode: 500, body: 'boom', headers: <String, String>{}));
      expectRedacted(e, '500');
    });

    test('★ 分支③：200 但正文是网页（风控页）', () async {
      final e = await failing(const DanmakuHttpResponse(
          statusCode: 200,
          body: '<!DOCTYPE html><html></html>',
          headers: <String, String>{}));
      expectRedacted(e, 'html');
    });

    test('★ 分支④：200 但不是 JSON', () async {
      final e = await failing(const DanmakuHttpResponse(
          statusCode: 200, body: 'not json at all', headers: <String, String>{}));
      expectRedacted(e, 'non-json');
    });

    test('★ 分支⑤：JSON 但结构不对（不是对象）', () async {
      final e = await failing(const DanmakuHttpResponse(
          statusCode: 200, body: '[1,2,3]', headers: <String, String>{}));
      expectRedacted(e, 'non-map');
    });

    test('★ 分支⑥：业务错误（success:false）', () async {
      final e = await failing(const DanmakuHttpResponse(
          statusCode: 200,
          body: '{"success":false,"errorCode":9,"errorMessage":"nope"}',
          headers: <String, String>{}));
      expectRedacted(e, 'business');
    });

    test('★★ 实际请求仍用**原始** URI（只打码异常里的记录）', () async {
      final seen = <Uri>[];
      final t = _RecTransport((m, uri, h, b) async {
        seen.add(uri);
        return const DanmakuHttpResponse(
            statusCode: 500, body: 'boom', headers: <String, String>{});
      });
      final c = ExternalDanmakuClient(
          transport: t, endpoint: endpointWithToken);
      try {
        await c.fetchComments(9527);
      } catch (_) {}
      c.close();
      expect(seen, isNotEmpty, reason: '阳性对照：确实发出过请求');
      expect(seen.first.path, '/$token/api/v2/comment/9527',
          reason: '★★ 请求必须带真 token（打码不能打到请求上，否则服务端不认）');
    });

    test('★ token 为空 ⇒ 地址**逐字不变**（老路径不受影响）', () async {
      final e = await failing(
        const DanmakuHttpResponse(
            statusCode: 500, body: 'x', headers: <String, String>{}),
        endpoint: const DanmakuEndpoint(baseUrl: 'http://127.0.0.1:9321'),
      );
      expect(e.uri, 'http://127.0.0.1:9321/api/v2/comment/9527?withRelated=true',
          reason: '★ 没有 token 就不该多出 *** —— 行为与改前逐字一致');
    });

    test('★ 没配自建后端（官方路径）⇒ 地址**逐字不变**', () async {
      final e = await failing(
        const DanmakuHttpResponse(
            statusCode: 500, body: 'x', headers: <String, String>{}),
        endpoint: null,
      );
      expect(e.uri, contains('api.dandanplay.net/api/v2/comment/9527'),
          reason: '★ 官方路没有 token，一个字符都不该动');
      expect(e.uri.contains('***'), isFalse);
    });

    test('★ 协议路径本来就以 /api 开头 ⇒ 不误伤（不会把 api 打成 ***）', () async {
      // 这是阳性对照的反面：_safeUri 只认「第一段不是 api」才是 token
      final e = await failing(
        const DanmakuHttpResponse(
            statusCode: 500, body: 'x', headers: <String, String>{}),
        endpoint: const DanmakuEndpoint(baseUrl: 'http://h:1'),
      );
      expect(e.uri, 'http://h:1/api/v2/comment/9527?withRelated=true');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ UiPrefs 偏好读写
  // ═══════════════════════════════════════════════════════════════════

  group('⑥ UiPrefs：自建服务地址偏好', () {
    test('默认空 ⇒ 走内置路径', () {
      expect(UiPrefs.danmakuEndpoint, '');
      expect(UiPrefs.danmakuToken, '');
    });

    test('往返读写 + 自动 trim', () {
      UiPrefs.setDanmakuEndpoint('  http://127.0.0.1:9321  ');
      expect(UiPrefs.danmakuEndpoint, 'http://127.0.0.1:9321');
      UiPrefs.setDanmakuToken('  tok  ');
      expect(UiPrefs.danmakuToken, 'tok');
    });

    test('★ 传空串 = 清除键（不留垃圾键，同 setHomeSource 纪律）', () {
      UiPrefs.setDanmakuEndpoint('http://h:1');
      UiPrefs.setDanmakuEndpoint('');
      expect(UiPrefs.get(UiPrefs.danmakuEndpointKey), isNull,
          reason: '★ 用户清空地址必须真的回到内置路径');
      UiPrefs.setDanmakuToken('t');
      UiPrefs.setDanmakuToken('   ');
      expect(UiPrefs.get(UiPrefs.danmakuTokenKey), isNull);
    });

    test('★ 与弹弹play 凭证键互不影响（两件事不相干）', () {
      UiPrefs.setDanmakuEndpoint('http://h:1');
      UiPrefs.set('dsh.danmaku.appId', 'keepme');
      UiPrefs.setDanmakuEndpoint('');
      expect(UiPrefs.get('dsh.danmaku.appId'), 'keepme',
          reason: '★ 清自建地址不该动官方凭证');
    });
  });
}
