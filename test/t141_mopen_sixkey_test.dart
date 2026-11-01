// ═══════════════════════════════════════════════════════════════════════
//  T8 · 六键兼容解析单测（danmakuListFromAnyJson / DanmakuComment.fromAnyJson）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么
// ```text
// ① 六种键形态（danmaku/data/list/result/results/items）都能吃 —— T2 取证
// ② 缺层容错（键在任意层、值不是数组时沿树继续找）
// ③ 元素形态探测：p/m wire 优先，泛化 {time,text} 兜底
// ④ ★ 硬门禁（Owner 批复）：既有 comments 形态命中走原路零变化 ——
//    fetchComments 集成级红度对照：comments+data 同现时 comments 赢。
// ```

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku.dart';

void main() {
  // ── ① 六键形态 ──────────────────────────────────────────────────────
  group('① 六种键形态（顶层）', () {
    final elements = <Object>[
      {'time': 1.5, 'text': '第一条'},
      {'time': 3.0, 'text': '第二条'},
    ];
    for (final k in kDanmakuSixKeys) {
      test('顶层键 "$k" 的数组被识别为弹幕列表', () {
        final out = danmakuListFromAnyJson(<String, dynamic>{k: elements});
        expect(out, isNotNull, reason: '键 "$k" 是六键之一，必须被识别');
        expect(out!.length, 2);
        expect(out[0].text, '第一条');
        expect(out[1].time, 3.0);
      });
    }
  });

  group('② 缺层容错（键在任意层）', () {
    test('嵌套一层：data.list', () {
      final out = danmakuListFromAnyJson(<String, dynamic>{
        'data': <String, dynamic>{
          'list': <Object>[
            {'time': 5, 'text': '嵌套'},
          ],
        },
      });
      expect(out, isNotNull);
      expect(out!.single.text, '嵌套');
    });

    test('嵌套两层：result.items', () {
      final out = danmakuListFromAnyJson(<String, dynamic>{
        'result': <String, dynamic>{
          'items': <Object>[
            {'time': 5, 'text': '两层'},
          ],
        },
      });
      expect(out, isNotNull);
      expect(out!.single.text, '两层');
    });

    test('键存在但值不是数组 ⇒ 沿树继续往下找（缺层容错）', () {
      final out = danmakuListFromAnyJson(<String, dynamic>{
        'data': <String, dynamic>{
          'meta': '不是数组',
          'inner': <String, dynamic>{
            'items': <Object>[
              {'time': 5, 'text': '深层'},
            ],
          },
        },
      });
      expect(out, isNotNull, reason: 'data 不是数组时应继续沿子对象找 items');
      expect(out!.single.text, '深层');
    });

    test('裸数组本身就是一种形态', () {
      final out = danmakuListFromAnyJson(<Object>[
        {'time': 5, 'text': '裸数组'},
      ]);
      expect(out, isNotNull);
      expect(out!.single.text, '裸数组');
    });

    test('键序：六个键同时存在时按取证表序取第一个命中的（danmaku 优先）', () {
      final out = danmakuListFromAnyJson(<String, dynamic>{
        'items': <Object>[
          {'time': 9, 'text': 'items'},
        ],
        'danmaku': <Object>[
          {'time': 1, 'text': 'danmaku'},
        ],
      });
      expect(out!.single.text, 'danmaku');
    });

    test('没有任何六键形态 ⇒ null（不是空列表——调用方维持原判）', () {
      expect(danmakuListFromAnyJson(<String, dynamic>{'comments': <Object>[]}),
          isNull, reason: 'comments 不在六键里——既有形态不归它管');
      expect(danmakuListFromAnyJson(<String, dynamic>{}), isNull);
      expect(danmakuListFromAnyJson(null), isNull);
      expect(danmakuListFromAnyJson('文字'), isNull);
    });

    test('找到键但列表为空 ⇒ 空列表（有效形态，0 条）', () {
      final out = danmakuListFromAnyJson(<String, dynamic>{
        'data': <Object>[],
      });
      expect(out, isNotNull);
      expect(out, isEmpty);
    });

    test('深度上限：超过 8 层不再找（防病态输入）', () {
      Map<String, dynamic> wrap(Map<String, dynamic> inner) =>
          {'a': inner};
      var node = <String, dynamic>{
        'items': <Object>[
          {'time': 1, 'text': '太深'},
        ],
      };
      for (var i = 0; i < 10; i++) {
        node = wrap(node);
      }
      expect(danmakuListFromAnyJson(node), isNull);
    });
  });

  group('③ 元素形态探测（DanmakuComment.fromAnyJson）', () {
    test('p/m wire 元素优先（弹弹play 形态不吃泛化路）', () {
      final c = DanmakuComment.fromAnyJson(<String, dynamic>{
        'cid': 7,
        'p': '12.5,4,16711680,uid1',
        'm': 'wire 文本',
      });
      expect(c, isNotNull);
      expect(c!.cid, 7);
      expect(c.time, 12.5);
      expect(c.text, 'wire 文本');
      expect(c.color, 16711680);
    });

    test('泛化字段 {time,text}；cid 缺失用 fallbackCid（下标+1）补位', () {
      final c = DanmakuComment.fromAnyJson(
        <String, dynamic>{'time': 4.2, 'text': '泛化'},
        fallbackCid: 3,
      );
      expect(c!.cid, 3);
      expect(c.time, 4.2);
      expect(c.mode, DanmakuMode.scroll);
      expect(c.color, 0xFFFFFF);
    });

    test('mode/color/uid 泛化字段都吃', () {
      final c = DanmakuComment.fromAnyJson(<String, dynamic>{
        'time': 6,
        'text': '带样式',
        'mode': 4,
        'color': 255,
        'uid': 'u9',
      });
      expect(c!.mode, DanmakuMode.fromWire(4));
      expect(c.color, 255);
      expect(c.userId, 'u9');
    });

    test('毫秒歧义：>36000 按毫秒解释（40000ms → 40s）', () {
      final c = DanmakuComment.fromAnyJson(
        <String, dynamic>{'time': 40000, 'text': '毫秒'},
      );
      expect(c!.time, 40.0);
    });

    test('秒口径不误伤：7200（2 小时）仍是秒', () {
      final c = DanmakuComment.fromAnyJson(
        <String, dynamic>{'time': 7200, 'text': '长片'},
      );
      expect(c!.time, 7200.0);
    });

    test('time 缺失 / 不可解析 / 负数 ⇒ 整条丢弃（不钉在片头）', () {
      expect(
        DanmakuComment.fromAnyJson(<String, dynamic>{'text': '没时间'}),
        isNull,
        reason: 'time 缺失当 0 会把弹幕全钉在片头——必须丢',
      );
      expect(
        DanmakuComment.fromAnyJson(
            <String, dynamic>{'time': 'abc', 'text': '坏时间'}),
        isNull,
      );
      expect(
        DanmakuComment.fromAnyJson(
            <String, dynamic>{'time': -1, 'text': '负时间'}),
        isNull,
      );
      expect(
        DanmakuComment.fromAnyJson(
            <String, dynamic>{'time': 1, 'text': '   '}),
        isNull,
        reason: '空文本丢',
      );
      expect(DanmakuComment.fromAnyJson('不是对象'), isNull);
      expect(DanmakuComment.fromAnyJson(null), isNull);
    });

    test('shift 叠加进时间', () {
      final c = DanmakuComment.fromAnyJson(
        <String, dynamic>{'time': 10, 'text': '偏移'},
        shift: 2.5,
      );
      expect(c!.time, 12.5);
    });

    test('列表级：坏元素跳过、结果按时间排序、cid 按下标补位', () {
      final out = danmakuListFromAnyJson(<String, dynamic>{
        'items': <Object>[
          '不是对象',
          {'time': 8, 'text': '后'},
          {'text': '没时间'},
          {'time': 2, 'text': '前'},
        ],
      });
      expect(out!.length, 2);
      expect(out[0].text, '前');
      expect(out[0].cid, 4, reason: '第 4 个元素（下标 3）⇒ 补位 cid=4');
      expect(out[1].text, '后');
      expect(out[1].cid, 2, reason: '第 2 个元素（下标 1）⇒ 补位 cid=2');
    });
  });

  // ── ④ 硬门禁：既有 comments 形态零变化 ─────────────────────────────
  group('④ fetchComments：comments 命中走原路（零变化）', () {
    final commentsBody = jsonEncode(<String, dynamic>{
      'comments': <Object>[
        {'cid': 1, 'p': '1.0,1,16777215,u', 'm': '既有形态A'},
        {'cid': 2, 'p': '2.0,1,16777215,u', 'm': '既有形态B'},
      ],
      // ★ 干扰项：同响应里还有个 data 数组——comments 命中时**绝不**走六键
      'data': <Object>[
        {'time': 99, 'text': '不该被采用的六键形态'},
      ],
    });

    test('comments + data 同现 ⇒ 只解析 comments', () async {
      final t = _FakeTransport([_resp(commentsBody)]);
      final client = ExternalDanmakuClient(transport: t);
      final out = await client.fetchComments(9527);
      expect(out.length, 2, reason: 'comments 赢，六键形态即使存在也不许插队');
      expect(out[0].text, '既有形态A');
      expect(out.any((c) => c.text == '不该被采用的六键形态'), isFalse);
      expect(out[0].cid, 1, reason: 'wire 的 cid 原样保留（六键补位 cid 不参与）');
      client.close();
    });

    test('无 comments、有六键 ⇒ 走六键（既有响应本来会空，现在多一次容错）', () async {
      final t = _FakeTransport([
        _resp(jsonEncode(<String, dynamic>{
          'data': <Object>[
            {'time': 3, 'text': '六键来的'},
          ],
        })),
      ]);
      final client = ExternalDanmakuClient(transport: t);
      final out = await client.fetchComments(9527);
      expect(out.single.text, '六键来的');
      client.close();
    });

    test('★ comments 键存在但**不是 List** ⇒ 不算命中，落到六键探测（is List 才算命中）',
        () async {
      final t = _FakeTransport([
        _resp(jsonEncode(<String, dynamic>{
          // comments 是个对象（坏形态），不是 List ⇒ 既有形态未命中
          'comments': <String, dynamic>{'error': 'bad'},
          // 六键的 data 数组在 ⇒ 走六键解析
          'data': <Object>[
            {'time': 7, 'text': 'comments 坏了走六键'},
          ],
        })),
      ]);
      final client = ExternalDanmakuClient(transport: t);
      final out = await client.fetchComments(9527);
      expect(out.single.text, 'comments 坏了走六键',
          reason: 'is List 才算既有形态命中——非 List 的 comments 不许挡住六键回退');
      client.close();
    });

    test('comments 非 List 且无六键形态 ⇒ 空列表（与改前语义一致，不抛）', () async {
      final t = _FakeTransport([
        _resp(jsonEncode(<String, dynamic>{
          'comments': '坏成字符串了',
        })),
      ]);
      final client = ExternalDanmakuClient(transport: t);
      final out = await client.fetchComments(9527);
      expect(out, isEmpty);
      client.close();
    });

    test('两种形态都没有 ⇒ 空列表（与改前语义逐字一致，不抛）', () async {
      final t = _FakeTransport([
        _resp(jsonEncode(<String, dynamic>{'data': {'x': 1}})),
      ]);
      final client = ExternalDanmakuClient(transport: t);
      final out = await client.fetchComments(9527);
      expect(out, isEmpty);
      client.close();
    });
  });
}

DanmakuHttpResponse _resp(String body) => DanmakuHttpResponse(
      statusCode: 200,
      body: body,
      headers: <String, String>{'content-type': 'application/json'},
    );

/// 可编程假传输层：按序回放响应，记录请求
class _FakeTransport implements DanmakuTransport {
  _FakeTransport(this.responses);
  final List<DanmakuHttpResponse> responses;
  final List<Uri> uris = [];

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    uris.add(uri);
    if (responses.isEmpty) {
      fail('测试脚本没有更多响应了（请求打多了）: $uri');
    }
    return responses.removeAt(0);
  }

  @override
  void close() {}
}
