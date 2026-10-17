// ═══════════════════════════════════════════════════════════════════════
//  第 65 轮 · 第 10 条门禁：搜索链路**不许**因为风控 412 就整体失败
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// > 直接搜索弹幕还是提示「拒绝了这次请求」，这次请构建后自行测试
//
// # 真实读数（`.probe/round65-c/` 里的原始记录）
// ```text
// search/type   连打三次 → 200 / 200 / 412   ← 风控随机命中
// search/all/v2 连打三次 → 200 / 200 / 200   ← 稳定
// ```
// ⇒ 改前只有 `search/type` 一条路，一撞 412 就抛 ⇒ 上层降级到要凭证的
//    弹幕服务 ⇒ 403 ⇒ 用户看到「弹幕服务拒绝了这次请求」。
//
// # 这组断言为什么不会假绿
//
// ```text
// 用**假传输**注入"search/type 恒 412"，然后断言：
//   ① 整个 searchVideos 仍返回结果     ← 旧代码必然抛 ⇒ 红
//   ② 结果来自 all/v2（能看出退路生效） ← 旧代码没有这条路 ⇒ 红
// 再注入"两条都挂"，断言：
//   ③ 抛出的错里**同时**有两条链路的读数 ← 旧代码只有一条 ⇒ 红
// ```
// 撤销验证：把 searchVideos 的 ② 段删掉 ⇒ ①②③ 全红。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/danmaku.dart';

/// 一条可控的假 HTTP 传输 —— **不发真网络**
///
/// # 为什么不用 mockito / mocktail
/// ```text
/// 本仓零新依赖（pubspec 里没有 mock 库，见 bili_api.dart 文件头）。
/// 而 `BiliApi` 收一个 `HttpClient` 参数（构造参数已留好注入点），
/// 所以这里只要实现一个最小的 HttpClient 替身即可。
/// ```
/// ⚠️ 只用 `BiliApi(httpClient:)` 那条**生产已有的**注入点，
///    不为测试在产品代码里加任何钩子。
class _FakeHttp implements HttpClient {
  _FakeHttp(this.handler);

  /// (uri) → (status, body, contentType)
  final (int, String, String) Function(Uri uri) handler;

  int calls = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    calls++;
    final (status, body, ct) = handler(url);
    return _FakeReq(url, status, utf8.encode(body), ct);
  }

  @override
  noSuchMethod(Invocation i) => throw UnsupportedError('${i.memberName}');

  @override
  void close({bool force = false}) {}
}

class _FakeReq implements HttpClientRequest {
  _FakeReq(this.uri, this.status, this.body, this.ct);

  @override
  final Uri uri;
  final int status;
  final List<int> body;
  final String ct;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async =>
      _FakeResp(status, body, ct);

  @override
  noSuchMethod(Invocation i) => throw UnsupportedError('${i.memberName}');
}

class _FakeResp implements HttpClientResponse {
  _FakeResp(this.statusCode, this._body, this._ct);

  @override
  final int statusCode;
  final List<int> _body;
  final String _ct;

  /// 真身：把 body 包成一条**真正的** Stream
  ///
  /// # 为什么必须包真 Stream（而不是自己实现 listen）
  /// ```text
  /// 生产代码里是 `await for (final chunk in resp.timeout(timeout))`
  /// —— 它调的是 **Stream.timeout**，不是 HttpClientResponse 的方法。
  /// 自己写一个 listen 不实现 timeout ⇒ timeout 落进 noSuchMethod ⇒ 抛
  /// UnsupportedError ⇒ 测试红在与产品无关的地方（假红）。
  /// ```
  late final Stream<List<int>> _stream = Stream<List<int>>.value(_body);

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  Stream<List<int>> timeout(
    Duration timeLimit, {
    void Function(EventSink<List<int>>)? onTimeout,
  }) =>
      _stream.timeout(timeLimit, onTimeout: onTimeout);

  /// 其余 Stream 成员（生产代码没用到，但别让 noSuchMethod 抛到无关处）
  @override
  Future<bool> any(bool Function(List<int> element) test) => _stream.any(test);

  @override
  Future<void> forEach(void Function(List<int> element) action) =>
      _stream.forEach(action);

  @override
  noSuchMethod(Invocation i) => throw UnsupportedError(
    '夹具没实现 ${i.memberName}（若产品代码新用了它，补上即可）',
  );
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> _m = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _m[name.toLowerCase()] = <String>['$value'];
  }

  @override
  String? value(String name) {
    final v = _m[name.toLowerCase()];
    return (v == null) ? null : (v.isEmpty ? null : v.first);
  }

  @override
  noSuchMethod(Invocation i) => null;
}

/// all/v2 的**真实形状**（只保留解析需要的字段，别的一律不要 —
/// 夹具比真实响应小得多，但结构必须同形，否则测的是我自己造的格式）
String _allV2Json(String bvid, String title) => jsonEncode({
  'code': 0,
  'message': 'OK',
  'data': {
    'result': [
      {
        'result_type': 'media_bangumi',
        'data': [
          {'season_id': 1},
        ],
      },
      {
        'result_type': 'video',
        'data': [
          {'bvid': '', 'title': '直播卡片（没有 bvid，解析时应丢弃）'},
          {
            'bvid': bvid,
            'title': '<em class="keyword">$title</em>',
            'pic': '//i0.hdslb.com/x.jpg',
            'duration': '0:37',
            'author': 'up',
            'play': 1,
            'typename': '搞笑',
            'pubdate': 1792210933,
          },
        ],
      },
    ],
  },
});

String _typeJson(String bvid, String title) => jsonEncode({
  'code': 0,
  'message': 'OK',
  'data': {
    'result': [
      {
        'bvid': bvid,
        'title': '<em class="keyword">$title</em>',
        'pic': '//i0.hdslb.com/y.jpg',
        'duration': '1:00',
        'author': 'up2',
        'play': 2,
        'typename': '音乐',
        'pubdate': 1792210000,
      },
    ],
  },
});

/// 412 的**真实形态**：3400 字节 text/html 的风控页（实测）
const String _kw412Html =
    '<!DOCTYPE html><html lang="zh-cn"><head>'
    '<meta http-equiv="Page-Enter" content="blendTrans(Duration=0.5)">'
    '</head><body>北邮风控</body></html>';

void main() {
  group('第 10 条：search/type 被 412 ⇒ 自动退到 all/v2', () {
    test('① search/type 恒 412，整体搜索仍然要给结果', () async {
      final fake = _FakeHttp((uri) {
        if (uri.path.contains('search/type')) {
          return (412, _kw412Html, 'text/html');
        }
        if (uri.path.contains('search/all/v2')) {
          return (200, _allV2Json('BV1AA1aa1AA1', '从头条来的'), 'application/json');
        }
        return (404, '', 'text/plain');
      });
      final api = BiliApi(client: fake, timeout: const Duration(seconds: 3));

      final items = await api.searchVideos('火影');

      expect(items, isNotEmpty,
          reason: '★ 412 不该让整个搜索失败（Owner 第 10 条的核心）');
      expect(items.first.bvid, 'BV1AA1aa1AA1',
          reason: '★ 结果必须来自 all/v2 兜底（证明退路真的走了）');
      expect(items.first.title, '从头条来的',
          reason: '★ <em> 高亮标签要被剥掉（与原生链路同一套清洗）');
      expect(fake.calls, greaterThanOrEqualTo(2),
          reason: '★ 至少打了两次（type 一次 + all/v2 一次）—— 证明不是只走一条');
      api.close();
    });

    test('② search/type 回 200 但 0 条 ⇒ 仍然用 all/v2 复核', () async {
      // 实测：search/type 被风控时**也可能**回 200（内容是风控页但能解码）
      final fake = _FakeHttp((uri) {
        if (uri.path.contains('search/type')) {
          return (200, jsonEncode({'code': 0, 'data': {'result': []}}),
              'application/json');
        }
        return (200, _allV2Json('BV1BB2bb2BB2', '复核到的'), 'application/json');
      });
      final api = BiliApi(client: fake, timeout: const Duration(seconds: 3));
      final items = await api.searchVideos('火影');
      expect(items.first.bvid, 'BV1BB2bb2BB2',
          reason: '★ 200+0 条也要复核 —— 风控页可能伪装成合法空结果');
      api.close();
    });

    test('③ search/type 正常有结果 ⇒ **不**多打一次 all/v2（省一次往返）', () async {
      var allV2Calls = 0;
      final fake = _FakeHttp((uri) {
        if (uri.path.contains('search/type')) {
          return (200, _typeJson('BV1CC3cc3CC3', '原生'), 'application/json');
        }
        allV2Calls++;
        return (200, _allV2Json('BV1ZZ0zz0ZZ0', '不该用到'), 'application/json');
      });
      final api = BiliApi(client: fake, timeout: const Duration(seconds: 3));
      final items = await api.searchVideos('火影');
      expect(items.first.bvid, 'BV1CC3cc3CC3', reason: '★ 优先用原生链路');
      expect(allV2Calls, 0,
          reason: '★ 原生有结果时**不许**再打兜底（白费一次请求）');
      api.close();
    });

    test('④ 两条都挂 ⇒ 错误里必须**同时**有两条链路的读数', () async {
      final fake = _FakeHttp((uri) {
        if (uri.path.contains('search/type')) {
          return (412, _kw412Html, 'text/html');
        }
        return (503, '{"code":-503}', 'application/json');
      });
      final api = BiliApi(client: fake, timeout: const Duration(seconds: 3));
      Object? caught;
      try {
        await api.searchVideos('火影');
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull, reason: '两条都挂时必须抛错（不许静默空结果）');
      final msg = caught is DanmakuException ? caught.message : '$caught';
      expect(msg.contains('两条链路'), isTrue,
          reason: '★ 文案要说明"两条都试过了" —— 用户据此判断该找谁: $msg');
      expect(msg.contains('①'), isTrue, reason: '要有第一条的读数: $msg');
      expect(msg.contains('②'), isTrue, reason: '要有第二条的读数: $msg');
      api.close();
    });

    test('⑤ all/v2 里的无 bvid 卡片必须被丢掉（不能绑到直播卡片上）', () async {
      final fake = _FakeHttp((uri) {
        if (uri.path.contains('search/type')) {
          return (412, _kw412Html, 'text/html');
        }
        return (200, _allV2Json('BV1DD4dd4DD4', '真视频'), 'application/json');
      });
      final api = BiliApi(client: fake, timeout: const Duration(seconds: 3));
      final items = await api.searchVideos('火影');
      expect(items.any((e) => e.bvid.isEmpty), isFalse,
          reason: '★ 空 bvid 的条目必须被过滤（否则后续 bindFromInput 必崩）');
      expect(items.length, 1, reason: '夹具里只有 1 条带 bvid 的');
      api.close();
    });
  });
}
