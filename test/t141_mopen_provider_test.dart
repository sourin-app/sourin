// ═══════════════════════════════════════════════════════════════════════
//  T8 · 站源弹幕 provider 注入证红（MopenDanmuClient，假 transport）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么（Owner 批复的红线）
// ```text
// ① 两步令牌流（probe 实证）：step1 拿 _m_h5_tk ⇒ step2 带 Cookie + token
//    参签重放（MTOP 标准口径，round-2 实证 SUCCESS）
// ② 失败必须留痕不静默：网关 ret 原文 / HTTP 状态 / 非 JSON 全部抛出
// ③ 风控友好：失败后 30s 冷却（冷却期内**零网络**）；
//    同 vid+mat 结果缓存 TTL 10min（pan_check 口径）
// ④ 解析按 round-2 取证的**包裹层形态**落地（data.result 二次 JSON 字符串
//    → 内层 code/count/result）；元素级字段未取证 ⇒ 泛化探测 +
//    「count>0 但解析 0 条」矛盾留痕——**绝不**静默回 0 条
// ```

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/danmaku_mopen.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 可编程假传输层：按序回放响应 + 请求留痕
class _ScriptedTransport implements DanmakuTransport {
  _ScriptedTransport(this.script);
  final List<DanmakuHttpResponse> script;
  final List<
      ({String method, Uri uri, Map<String, String> headers, String? body})>
      calls = [];

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    calls.add((method: method, uri: uri, headers: headers, body: body));
    if (script.isEmpty) fail('脚本没有更多响应了（不该再打网络）: $uri');
    return script.removeAt(0);
  }

  @override
  void close() {}
}

class _Clock {
  _Clock(this.ms);
  int ms;
  DateTime call() => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

const String _tokenCookie =
    '_m_h5_tk=720fd82e14d1c7bd398a416cdd092dfd_1793501715116; '
    '_m_h5_tk_enc=a553ceee4e385c9a87f62a19ffa5e94c';

/// round-2 实证的包裹层形态：data.result 是二次 JSON 编码的字符串
DanmakuHttpResponse _successEnvelope({
  required int code,
  required List<Object> result,
  required int count,
  String message = 'success',
}) {
  final inner = jsonEncode(<String, dynamic>{
    'code': code,
    'cost': '5',
    'data': <String, dynamic>{'result': result, 'count': count, 'scm': '0.0'},
    'message': message,
  });
  return DanmakuHttpResponse(
    statusCode: 200,
    body: jsonEncode(<String, dynamic>{
      'api': 'mopen.youku.danmu.list',
      'data': <String, dynamic>{'result': inner},
      'ret': <String>['SUCCESS::调用成功'],
      'traceId': 't',
      'v': '1.0',
    }),
  );
}

DanmakuHttpResponse _envelope({
  required List<String> ret,
  Map<String, String> headers = const {},
}) =>
    DanmakuHttpResponse(
      statusCode: 200,
      body: jsonEncode(<String, dynamic>{
        'api': 'mopen.youku.danmu.list',
        'data': <String, dynamic>{},
        'ret': ret,
        'traceId': 't',
        'v': '1.0',
      }),
      headers: headers,
    );

void main() {
  // 频控/缓存是**类级**状态（互检 P2）——用例之间必须隔离
  setUp(() => MopenDanmuClient.debugResetRateLimitState());

  test('① 两步令牌流：step1 拿 _m_h5_tk ⇒ step2 带 Cookie 重放；ret 报错原文照透',
      () async {
    final t = _ScriptedTransport([
      // step1：probe 实证形态——TOKEN_EMPTY + Set-Cookie
      _envelope(
        ret: ['FAIL_SYS_TOKEN_EMPTY::令牌为空'],
        headers: <String, String>{'set-cookie': _tokenCookie},
      ),
      // step2：ret 报错（如风控/参数错）——原文必须透出
      _envelope(ret: ['FAIL_SYS_ILLEGAL_ACCESS::非法请求']),
    ]);
    final clock = _Clock(1793497040000);
    final c = MopenDanmuClient(transport: t, clock: clock.call);
    await expectLater(
      c.fetch(vid: 'XNjU3MzA0MTkxNg'),
      throwsA(isA<DanmakuException>().having(
        (e) => e.message,
        'message',
        contains('FAIL_SYS_ILLEGAL_ACCESS::非法请求'),
      )),
      reason: '网关 ret 原文必须透出，不静默、不翻译掉',
    );
    expect(t.calls.length, 2, reason: '恰好两步');
    // step1：无 Cookie
    expect(t.calls[0].headers.containsKey('Cookie'), isFalse);
    expect(t.calls[0].body, startsWith('data={"ctime": 1793497040'));
    expect(t.calls[0].uri.toString(), contains('appKey=24679788'));
    expect(t.calls[0].uri.toString(), contains('sign='));
    expect(t.calls[0].headers['Origin'], isNotEmpty);
    // step2：带令牌 Cookie（token 从 step1 的 Set-Cookie 提取）
    expect(
        t.calls[1].headers['Cookie'],
        contains(
            '_m_h5_tk=720fd82e14d1c7bd398a416cdd092dfd_1793501715116'));
    expect(t.calls[1].headers['Cookie'], contains('_m_h5_tk_enc='));
    c.close();
  });

  test('② 失败后 30s 冷却：冷却期内再取 ⇒ 抛冷却提示且**零网络**', () async {
    final t = _ScriptedTransport([
      _envelope(ret: ['FAIL_SYS_ILLEGAL_ACCESS::非法请求']),
    ]);
    final clock = _Clock(1793497040000);
    final c = MopenDanmuClient(transport: t, clock: clock.call);
    await expectLater(c.fetch(vid: 'XNjU3MzA0MTkxNg'), throwsA(anything));
    expect(t.calls.length, 1);

    clock.ms += 1000; // 1s 后再试（还在冷却期）
    await expectLater(
      c.fetch(vid: 'XNjU3MzA0MTkxNg'),
      throwsA(isA<DanmakuException>().having(
        (e) => e.message,
        'message',
        allOf(contains('风控冷却'), contains('FAIL_SYS_ILLEGAL_ACCESS')),
      )),
      reason: '冷却提示要带上"上次失败是什么"（留痕不静默的另一半）',
    );
    expect(t.calls.length, 1, reason: '冷却期内绝不发裸请求（风控友好）');

    clock.ms += 31 * 1000; // 冷却已过 ⇒ 恢复发请求（但脚本空了 ⇒ 失败提示）
    await expectLater(c.fetch(vid: 'XNjU3MzA0MTkxNg'), throwsA(anything));
    expect(t.calls.length, 2);
    c.close();
  });

  test('②b 跨实例冷却仍生效（互检 P2 门禁）：新建第二个实例打同一 vid ⇒ 冷却期内不发请求',
      () async {
    // 实例 A：失败一次（冷却开始）
    final tA = _ScriptedTransport([
      _envelope(ret: ['FAIL_SYS_ILLEGAL_ACCESS::非法请求']),
    ]);
    final clock = _Clock(1793497040000);
    final a = MopenDanmuClient(transport: tA, clock: clock.call);
    await expectLater(a.fetch(vid: 'XNjU3MzA0MTkxNg'), throwsA(anything));
    expect(tA.calls.length, 1);
    a.close();

    // ★ 实例 B：**全新实例**（生产路径每次按键新建实例的等价形态）——
    //   冷却是类级状态 ⇒ B 必须被冷却拦下，且 B 的传输层**零调用**。
    //   若冷却挂在实例上（改前的病），这里会真的发请求 = 频控骗人。
    final tB = _ScriptedTransport([]);
    final b = MopenDanmuClient(transport: tB, clock: clock.call);
    clock.ms += 1000; // 1s 后（冷却期内）
    await expectLater(
      b.fetch(vid: 'XNjU3MzA0MTkxNg'),
      throwsA(isA<DanmakuException>().having(
        (e) => e.message, 'message', contains('风控冷却'),
      )),
    );
    expect(tB.calls, isEmpty,
        reason: '跨实例冷却必须拦住请求——声明了不生效等于骗人');
    b.close();

    // 顺带钉住：类级缓存同样跨实例（A 失败不进缓存，此处只验冷却路径）
    // （缓存的跨实例行为在 ③ 的同实例路径 + debugResetRateLimitState 隔离下覆盖）
  });

  test('③ 缓存 TTL 10min：同 vid+mat 第二次取**零网络**；过期后重打', () async {
    final t = _ScriptedTransport([
      _envelope(
        ret: ['FAIL_SYS_TOKEN_EMPTY::令牌为空'],
        headers: <String, String>{'set-cookie': _tokenCookie},
      ),
      // 成功：真实包裹层形态，result 带 1 条泛化形态元素
      _successEnvelope(
        code: 1,
        count: 1,
        result: <Object>[
          <String, dynamic>{'time': 1.0, 'text': '解析出来的'},
        ],
      ),
    ]);
    final clock = _Clock(1793497040000);
    final c = MopenDanmuClient(transport: t, clock: clock.call);
    final out = await c.fetch(vid: 'XNjU3MzA0MTkxNg');
    expect(out.single.text, '解析出来的');
    expect(t.calls.length, 2);

    clock.ms += 5 * 60 * 1000; // 5 分钟后（< TTL）
    final again = await c.fetch(vid: 'XNjU3MzA0MTkxNg');
    expect(again.single.text, '解析出来的');
    expect(t.calls.length, 2, reason: '缓存命中 ⇒ 零网络');

    clock.ms += 6 * 60 * 1000; // 累计 11 分钟 > TTL ⇒ 缓存过期
    await expectLater(c.fetch(vid: 'XNjU3MzA0MTkxNg'), throwsA(anything),
        reason: '脚本已空 ⇒ 过期后真的重新打网络');
    expect(t.calls.length, 3);
    c.close();
  });

  test('④ 诚实空：SUCCESS + count=0 ⇒ 返回 []（不抛、不装失败）', () async {
    final t = _ScriptedTransport([
      _envelope(
        ret: ['FAIL_SYS_TOKEN_EMPTY::令牌为空'],
        headers: <String, String>{'set-cookie': _tokenCookie},
      ),
      // round-2 真实样本的形态：SUCCESS + code:1 + result 空数组 + count:0
      _successEnvelope(code: 1, count: 0, result: <Object>[]),
    ]);
    final c = MopenDanmuClient(transport: t, clock: _Clock(1).call);
    final out = await c.fetch(vid: 'XNjU3MzA0MTkxNg');
    expect(out, isEmpty, reason: '网关明确说这段没有弹幕——诚实空是有效结果');
    c.close();
  });

  test('⑤ 矛盾留痕：count>0 但元素字段形态未对上 ⇒ **抛**（绝不静默回 0 条）',
      () async {
    final t = _ScriptedTransport([
      _envelope(
        ret: ['FAIL_SYS_TOKEN_EMPTY::令牌为空'],
        headers: <String, String>{'set-cookie': _tokenCookie},
      ),
      // 网关报 2 条，但元素既不是 p/m wire 也没有 time/text 泛化字段
      _successEnvelope(
        code: 1,
        count: 2,
        result: <Object>[
          <String, dynamic>{'id': 1, 'content': '甲'},
          <String, dynamic>{'id': 2, 'content': '乙'},
        ],
      ),
    ]);
    final c = MopenDanmuClient(transport: t, clock: _Clock(1).call);
    await expectLater(
      c.fetch(vid: 'XNjU3MzA0MTkxNg'),
      throwsA(isA<DanmakuException>().having(
        (e) => e.message,
        'message',
        allOf(contains('2 条'), contains('形态未对上'), contains('首元素原文')),
      )),
      reason: '元素级字段未取证 ⇒ 对不上时留痕抛出，静默回 0 条=缺陷',
    );
    c.close();
  });

  test('⑥ 内层业务错误：code != 1 ⇒ 抛业务原文', () async {
    final t = _ScriptedTransport([
      _envelope(
        ret: ['FAIL_SYS_TOKEN_EMPTY::令牌为空'],
        headers: <String, String>{'set-cookie': _tokenCookie},
      ),
      _successEnvelope(code: -1, count: 0, result: <Object>[],
          message: '参数不对'),
    ]);
    final c = MopenDanmuClient(transport: t, clock: _Clock(1).call);
    await expectLater(
      c.fetch(vid: 'XNjU3MzA0MTkxNg'),
      throwsA(isA<DanmakuException>().having(
        (e) => e.message,
        'message',
        allOf(contains('code=-1'), contains('参数不对')),
      )),
    );
    c.close();
  });

  test('⑦ 输入与响应形态的证红', () async {
    // vid 校验：不发网络
    final t = _ScriptedTransport([]);
    final c = MopenDanmuClient(transport: t, clock: _Clock(1).call);
    await expectLater(
      c.fetch(vid: ''),
      throwsA(isA<DanmakuException>()
          .having((e) => e.message, 'message', contains('vid'))),
    );
    expect(t.calls, isEmpty, reason: '输入非法时零网络');

    // HTTP 500（⚠️ 脚本列表不能 const——假 transport 要 removeAt 回放；
    //   单个响应对象可以 const）
    final t2 = _ScriptedTransport([
      const DanmakuHttpResponse(statusCode: 500, body: 'oops'),
    ]);
    final c2 = MopenDanmuClient(transport: t2, clock: _Clock(1).call);
    await expectLater(
      c2.fetch(vid: 'XNjU3MzA0MTkxNg'),
      throwsA(isA<DanmakuException>()
          .having((e) => e.message, 'message', contains('HTTP 500'))),
    );

    // 非 JSON（⚠️ 前一个失败把**类级**冷却设上了——用例内也要显式隔离）
    MopenDanmuClient.debugResetRateLimitState();
    final t3 = _ScriptedTransport([
      const DanmakuHttpResponse(statusCode: 200, body: '<html>风控页</html>'),
    ]);
    final c3 = MopenDanmuClient(transport: t3, clock: _Clock(1).call);
    await expectLater(
      c3.fetch(vid: 'XNjU3MzA0MTkxNg'),
      throwsA(isA<DanmakuException>()
          .having((e) => e.message, 'message', contains('不是 JSON'))),
    );
  });

  test('⑧ UiPrefs 配置读写（默认零变化）', () {
    UiPrefs.debugResetForTest(<String, String>{});
    expect(MopenDanmuConfig.enabled, isFalse, reason: '默认关——默认行为零变化');
    expect(MopenDanmuConfig.mat, 1);
    expect(MopenDanmuConfig.vid, '');

    MopenDanmuConfig.setEnabled(true);
    MopenDanmuConfig.setVid('XNjU3MzA0MTkxNg');
    MopenDanmuConfig.setMat('2');
    expect(MopenDanmuConfig.enabled, isTrue);
    expect(MopenDanmuConfig.vid, 'XNjU3MzA0MTkxNg');
    expect(MopenDanmuConfig.mat, 2);

    MopenDanmuConfig.setVid(''); // 空 ⇒ 清键（不留垃圾键）
    expect(MopenDanmuConfig.vid, '');
    MopenDanmuConfig.setMat('abc'); // 非数字 ⇒ 回缺省
    expect(MopenDanmuConfig.mat, 1);
    MopenDanmuConfig.setEnabled(false);
    expect(MopenDanmuConfig.enabled, isFalse);
    UiPrefs.debugResetForTest(<String, String>{});
  });
}
