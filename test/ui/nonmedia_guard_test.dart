// ═══════════════════════════════════════════════════════════════════════
//  非媒体预检门禁（T4-I，2026-10-31）
// ═══════════════════════════════════════════════════════════════════════
//
// # 覆盖面（lead 四分支要求）
// ```text
// ① 直通（明显媒体 / 二进制应答）          ⇒ keep，零网络
// ② JSON 解析接口信封 ⇒ 换地址；HTML 刮出 m3u8 ⇒ 换地址
// ③ 人话错误（纯 HTML 页/分享页）          ⇒ fail
// 证红：把预检短路（debugShortCircuitNonMediaPrecheck = true）⇒ ②③ 用例必须红
// ```
// 夹具全是 127.0.0.1 本地 HttpServer 假上游 + 假头，不碰真网。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/player/nonmedia_guard.dart';

Future<HttpServer> _spawn(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((req) async {
    try {
      await handler(req);
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  });
  return server;
}

void main() {
  tearDown(() {
    debugShortCircuitNonMediaPrecheck = false;
  });

  // ── 纯函数：判据本身必须站得住 ──────────────────────────────────────

  test('pathHasMediaExt：明显媒体直通；页面/解析接口不算', () {
    expect(pathHasMediaExt('https://x.com/a/index.m3u8?sign=1&t=2'), isTrue);
    expect(pathHasMediaExt('https://x.com/a/b.MP4'), isTrue);
    expect(pathHasMediaExt('https://www.iqiyi.com/v_1wc7muawbrc.html'), isFalse);
    expect(
      pathHasMediaExt('https://api.nbyjson.top:7788/api/?key=K&url=NBY-X%7Cs'),
      isFalse,
    );
  });

  test('envelopeUrlOf：顶层 url / data.url 都认；非 http(s)/空/非 JSON 不认', () {
    const body = '{"code":200,"playVodId":76902,'
        '"url":"http://43.248.96.62:9090/nby/m3u8/getM3u8?name=x","From":"","UA":"Mozilla"}';
    expect(
      envelopeUrlOf(body),
      'http://43.248.96.62:9090/nby/m3u8/getM3u8?name=x',
    );
    expect(envelopeUrlOf('{"code":1,"data":{"url":"https://x.com/a.m3u8"}}'),
        'https://x.com/a.m3u8');
    expect(envelopeUrlOf('{"code":200,"url":""}'), isNull);
    expect(envelopeUrlOf('{"code":200,"url":"base64blob"}'), isNull);
    expect(envelopeUrlOf('not json at all'), isNull);
  });

  test('extractM3u8FromHtml：引号里的直链/相对地址；无引号不认', () {
    expect(
      extractM3u8FromHtml(
        '<html><script>var u = "https://cdn.example.com/hls/index.m3u8";</script></html>',
      ),
      'https://cdn.example.com/hls/index.m3u8',
    );
    expect(
      extractM3u8FromHtml(
        "<body data-v='/hls/x.m3u8'>",
        pageUrl: 'https://page.example.com/play/1.html',
      ),
      'https://page.example.com/hls/x.m3u8',
    );
    expect(
      extractM3u8FromHtml('请下载客户端观看 https://x.com/a.m3u8 直接裸串'),
      isNull,
    );
  });

  test('decideFromFetch 分支①④：视频应答 keep；JSON 非信封 keep', () {
    expect(
      decideFromFetch(status: 200, contentType: 'video/mp4', body: null).isKeep,
      isTrue,
    );
    expect(
      decideFromFetch(status: 200, contentType: 'application/octet-stream', body: null)
          .isKeep,
      isTrue,
    );
    expect(
      decideFromFetch(status: 200, contentType: 'application/json', body: '{"code":1}')
          .isKeep,
      isTrue,
    );
  });

  test('decideFromFetch 分支②：JSON 信封 ⇒ 换地址；HTML 刮出 m3u8 ⇒ 换地址', () {
    final viaJson = decideFromFetch(
      status: 200,
      contentType: 'application/json; charset=utf-8',
      body: '{"code":200,"url":"http://43.248.96.62:9090/nby/m3u8/getM3u8?name=x"}',
    );
    expect(viaJson.url, 'http://43.248.96.62:9090/nby/m3u8/getM3u8?name=x');
    expect(viaJson.error, isNull);

    final viaHtml = decideFromFetch(
      status: 200,
      contentType: 'text/html',
      body: '<script>var u = "https://cdn.example.com/hls/i.m3u8";</script>',
    );
    expect(viaHtml.url, 'https://cdn.example.com/hls/i.m3u8');
  });

  test('decideFromFetch 分支③：纯 HTML 页/分享页 ⇒ 人话错误（不再"格式解不了"）', () {
    final d = decideFromFetch(
      status: 200,
      contentType: 'text/html; charset=utf-8',
      body: '<!doctype html><html><body>请下载客户端观看</body></html>',
    );
    expect(d.url, isNull);
    expect(d.error, isNotNull);
    expect(d.error, contains('网页'));
    expect(d.error, contains('媒体流'));
  });

  // ── 异步：本地假上游，全链路（含头传递） ────────────────────────────

  test('预检②：解析接口信封 ⇒ 换真流地址，且候选自带头真的发出去了', () async {
    String? seenReferer;
    String? seenUa;
    final streamServer = await _spawn((req) async {
      req.response.headers.contentType =
          ContentType('application', 'vnd.apple.mpegurl');
      req.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:7\n');
      await req.response.close();
    });
    addTearDown(streamServer.close);
    final realUrl = 'http://127.0.0.1:${streamServer.port}/real/index.m3u8';

    final parserServer = await _spawn((req) async {
      seenReferer = req.headers.value('referer');
      seenUa = req.headers.value(HttpHeaders.userAgentHeader);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'code': 200, 'url': realUrl}));
      await req.response.close();
    });
    addTearDown(parserServer.close);

    final check = await precheckNonMedia(
      'http://127.0.0.1:${parserServer.port}/api/?key=K&url=NBY-X%7Cs',
      const {'Referer': 'https://up.example/', 'User-Agent': 'TestUA/1.0'},
    );

    expect(check.error, isNull);
    expect(check.url, realUrl, reason: '★ 信封里的真流地址要替换进起播');
    expect(seenReferer, 'https://up.example/',
        reason: '★ 候选自带的 Referer 必须随预检 GET 发出去');
    expect(seenUa, 'TestUA/1.0',
        reason: '★ 候选自带的 User-Agent 必须随预检 GET 发出去');
  });

  test('预检①：明显媒体直通 ⇒ 零网络', () async {
    var hits = 0;
    final server = await _spawn((req) async {
      hits++;
      await req.response.close();
    });
    addTearDown(server.close);

    final check = await precheckNonMedia(
      'http://127.0.0.1:${server.port}/hls/master.m3u8?sign=abc',
      const {},
    );
    expect(check.isKeep, isTrue);
    expect(hits, 0, reason: '明显媒体的 URL 不许发预检 GET');
  });

  test('预检③：纯 HTML 页 ⇒ fail，人话里点明是网页不是媒体流', () async {
    final server = await _spawn((req) async {
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html><body>请下载客户端观看</body></html>');
      await req.response.close();
    });
    addTearDown(server.close);

    final check = await precheckNonMedia(
      'http://127.0.0.1:${server.port}/v_1wc7muawbrc.html',
      const {},
    );
    expect(check.url, isNull);
    expect(check.error, isNotNull);
    expect(check.error, contains('网页'));
  });

  test('预检自身失败（上游不响应/超时）⇒ keep，不拦播放（行为与修复前一致）', () async {
    final server = await _spawn((req) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      await req.response.close();
    });
    addTearDown(server.close);

    final check = await precheckNonMedia(
      'http://127.0.0.1:${server.port}/api/?key=K&url=NBY-X',
      const {},
      timeout: const Duration(milliseconds: 200),
    );
    expect(check.isKeep, isTrue);
  });

  test('证红开关语义：短路 ⇒ 一切原样放行（把预检短路掉时 ②③ 用例必红）', () async {
    final server = await _spawn((req) async {
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html><body>请下载客户端观看</body></html>');
      await req.response.close();
    });
    addTearDown(server.close);

    debugShortCircuitNonMediaPrecheck = true;
    final check = await precheckNonMedia(
      'http://127.0.0.1:${server.port}/v_x.html',
      const {},
    );
    // 短路后这条候选原样放行 ⇒ 正是"预检被短路 ⇒ 应拦的没拦"的红形态
    expect(check.isKeep, isTrue);
  });
}
