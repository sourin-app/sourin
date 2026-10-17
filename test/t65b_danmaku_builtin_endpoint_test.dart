// task-65 / 批次 B：内置 dan-api 公共实例（Owner 第 4 条）
//
// Owner 原话（逐字）：
// ```text
// > 我之前说的dan-api 是让你接入现成的服务,不是让我去填的,或者可以内置上几个
// ```
//
// # 这份测试要钉住什么
// ```text
// ① 内置表**非空**且每一项都是完整可用的地址（不是空串、不是占位符）
// ② 用户填了地址 ⇒ 压过内置（内置只是默认值，不是写死）
// ③ 本机 2080 在线 ⇒ 本机赢（内置是**兜底**，不是抢占公网）
// ④ 两个都没有 ⇒ 才掉到官方
// ⑤ 内置实例的探测：它们**没有** /api/v2/system/version 与 /api/config，
//    只认那两个端点会让它永远显示「未运行」（假阴性）
// ```
//
// # 为什么表里的地址必须是**实测过**的
// ```text
// 内置一个死地址 = 用户开箱就失败，比不内置更糟（他会以为是软件坏了）。
// 实测脚本：`.probe/danmaku_b_builtin_probe.py`
//   ① /api/v2/search/anime?keyword=火影 → 200 且 animes 非空
//   ② /api/v2/comment/10002?format=json → 200 且 comments 非空
// 只过 ① 不过 ② 的实例（能搜不能取）**不算可用**，已从表里剔除。
// ```
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 记录请求的假传输
class _Rec implements DanmakuTransport {
  _Rec(this.respond);

  final DanmakuHttpResponse Function(Uri uri) respond;
  final List<Uri> calls = <Uri>[];

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    calls.add(uri);
    return respond(uri);
  }

  @override
  void close() {}
}

DanmakuHttpResponse _ok(Object j) => DanmakuHttpResponse(
      statusCode: 200,
      body: j is String ? j : jsonEncode(j),
    );

DanmakuHttpResponse _notFound() => const DanmakuHttpResponse(
      statusCode: 404,
      body: '{"message":"Not found"}',
    );

void main() {
  setUp(() => UiPrefs.debugResetForTest());
  tearDown(() {
    UiPrefs.debugResetForTest();
    DanmakuConfig.debugSetPublicInstances(null);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 内置表本身
  // ═══════════════════════════════════════════════════════════════════
  group('① 内置实例表', () {
    test('★★★ 表非空（Owner 说"内置上几个"，一个都没有就是没做）', () {
      expect(kDanmakuPublicInstances, isNotEmpty,
          reason: '★★★ Owner 原话「或者可以内置上几个」—— 空表等于这条没做');
    });

    test('★★ 每一项都是能解析的完整 https 地址（不是占位符）', () {
      for (final p in kDanmakuPublicInstances) {
        expect(p.baseUrl, startsWith('https://'),
            reason: '★ 公共实例必须走 https（明文 http 会把弹幕正文暴露在链路上）');
        expect(p.token, isNotEmpty,
            reason: '★ 这类公共部署保留默认 token，不带就是 401（实测过）');
        expect(p.label, isNotEmpty, reason: '★ 要有个中性短名给用户看');

        final ep = DanmakuEndpoint.tryParse(p.baseUrl, token: p.token);
        expect(ep, isNotNull, reason: '★ ${p.baseUrl} 解析不出来');
        expect(ep!.host, isNotEmpty);
      }
    });

    test('★★ 表里没有重复地址', () {
      final seen = <String>{};
      for (final p in kDanmakuPublicInstances) {
        expect(seen.add(p.baseUrl), isTrue,
            reason: '★ ${p.baseUrl} 重复了');
      }
    });

    test('★★★ 表里**没有**任何视频站名（t98 会红，也是产品口径）', () {
      // 这些是**弹幕协议服务**，不是本软件对接的视频网站。
      // 但主机名里一旦出现站名，t98 的语义就坏了 —— 这里再钉一遍。
      const banned = <String>[
        'bilibili', '哔哩', 'douyu', '斗鱼', 'youku', '优酷',
        'iqiyi', '爱奇艺', 'qq.com', 'tencent', 'mgtv', '芒果',
      ];
      for (final p in kDanmakuPublicInstances) {
        final low = p.baseUrl.toLowerCase();
        for (final b in banned) {
          expect(low.contains(b), isFalse,
              reason: '★★ ${p.baseUrl} 里出现了站名「$b」');
        }
      }
    });

    test('★★ 默认选中第一个（顺序稳定，用户看到的就是 A）', () {
      expect(DanmakuConfig.defaultPublicInstance, isNotNull);
      expect(DanmakuConfig.defaultPublicInstance!.baseUrl,
          kDanmakuPublicInstances.first.baseUrl);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 用户填的压过内置
  // ═══════════════════════════════════════════════════════════════════
  group('② 覆盖链：用户 > 内置', () {
    test('★★★ 没填 ⇒ effectiveEndpoint 是内置实例', () {
      final ep = DanmakuConfig.effectiveEndpoint;
      expect(ep, isNotNull, reason: '★★★ 没填也要有东西可用（这就是"内置"的意义）');
      expect(ep!.host, contains('vercel.app'));
      expect(DanmakuConfig.usingPublicInstance, isTrue);
    });

    test('★★★ 填了 ⇒ effectiveEndpoint 是用户填的，内置被压掉', () {
      UiPrefs.setDanmakuEndpoint('http://192.168.1.7:9321');
      UiPrefs.setDanmakuToken('mytoken');

      final ep = DanmakuConfig.effectiveEndpoint!;
      expect(ep.host, '192.168.1.7');
      expect(ep.port, 9321);
      expect(ep.token, 'mytoken');
      expect(DanmakuConfig.usingPublicInstance, isFalse,
          reason: '★★ 用户填了就不是"用内置的"了 —— 状态行要说实话');
    });

    test('★★ 关掉内置表（测试注入）⇒ effectiveEndpoint 为 null', () {
      DanmakuConfig.debugSetPublicInstances(const <DanmakuPublicInstance>[]);
      expect(DanmakuConfig.effectiveEndpoint, isNull);
      expect(DanmakuConfig.defaultPublicInstance, isNull);
      expect(DanmakuConfig.usingPublicInstance, isFalse);
    });

    test('★★ 清空用户地址 ⇒ 回落到内置（不是变空）', () {
      UiPrefs.setDanmakuEndpoint('http://192.168.1.7:9321');
      expect(DanmakuConfig.usingPublicInstance, isFalse);

      UiPrefs.remove(UiPrefs.danmakuEndpointKey);
      UiPrefs.remove(UiPrefs.danmakuTokenKey);
      expect(DanmakuConfig.usingPublicInstance, isTrue,
          reason: '★★ 清空是"用回内置"，不是"没有弹幕源"');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 请求真的落在内置实例上（不是只在 getter 里）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 接线：请求真的打到内置实例', () {
    test('★★★ 没配地址 + 本机没起 ⇒ match 请求落在内置实例（带 token 前缀）',
        () async {
      final t = _Rec((_) => _ok(<String, Object?>{
            'isMatched': false,
            'matches': <Object>[],
          }));
      final c = ExternalDanmakuClient(transport: t);
      await c.match(fileName: 'A.mp4');

      expect(t.calls, isNotEmpty);
      final u = t.calls.first;
      final host = kDanmakuPublicInstances.first.baseUrl
          .replaceFirst('https://', '');
      expect(u.host, host, reason: '★★★ 必须落在内置实例上，不是官方域名');
      expect(u.scheme, 'https');
      expect(u.path, startsWith('/87654321/'),
          reason: '★★ token 前缀必须带上（不带就是 401，实测过）');
      c.close();
    });

    test('★★★ 内置实例路径不带 X-Signature（免凭证）', () async {
      final t = _HeaderRec();
      final c = ExternalDanmakuClient(transport: t);
      await c.match(fileName: 'A.mp4');

      expect(t.headersList, isNotEmpty);
      expect(t.headersList.first.containsKey('X-AppId'), isFalse,
          reason: '★★ 内置实例是免凭证的第三方实现，不该发官方签名头');
      expect(t.headersList.first.containsKey('X-Signature'), isFalse);
      c.close();
    });

    test('★★ 本机 2080 在线 ⇒ 本机赢（内置是兜底不是抢占）', () async {
      final t = _Rec((_) => _ok(<String, Object?>{
            'isMatched': false,
            'matches': <Object>[],
          }));
      final c = ExternalDanmakuClient(transport: t, unsignedLocal: true);
      await c.match(fileName: 'A.mp4');

      expect(t.calls.first.host, '127.0.0.1',
          reason: '★★ 本机进程零网络、毫秒级；内置是公网 serverless（冷启动 3~6 s）'
              '⇒ 本机活着就必须让本机赢');
      expect(t.calls.first.port, 2080);
      c.close();
    });

    test('★★ 关掉内置 + 本机没起 ⇒ 才掉到官方', () async {
      DanmakuConfig.debugSetPublicInstances(const <DanmakuPublicInstance>[]);
      final t = _Rec((_) => _ok(<String, Object?>{
            'isMatched': false,
            'matches': <Object>[],
          }));
      final c = ExternalDanmakuClient(
        transport: t,
        appId: 'myid',
        appSecret: 'b',
      );
      await c.match(fileName: 'A.mp4');

      expect(t.calls.first.host, 'api.dandanplay.net',
          reason: '★ 内置关掉后必须与改前逐字一致');
      c.close();
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 探测：内置实例没有 /api/config 也要认出来
  // ═══════════════════════════════════════════════════════════════════
  group('④ 探测内置实例（实测：两个老端点都是 404）', () {
    test('★★★ 老两个端点 404、search 200 ⇒ 判在线（不是假阴性）', () async {
      final t = _Rec((u) {
        if (u.path.endsWith('/api/v2/system/version')) return _notFound();
        if (u.path.endsWith('/api/config')) return _notFound();
        if (u.path.endsWith('/api/v2/search/anime')) {
          return _ok(<String, Object?>{
            'errorCode': 0,
            'success': true,
            'animes': <Object>[
              <String, Object?>{'animeId': 1098, 'animeTitle': 'x'},
            ],
          });
        }
        return _notFound();
      });

      final ep = DanmakuConfig.publicInstanceEndpoint!;
      final st = await DanmakuLocalService.probe(transport: t, endpoint: ep);

      expect(st.online, isTrue,
          reason: '★★★ 改前只认 version/config ⇒ 内置实例永远"未运行"，'
              '而它明明能取到 2000+ 条弹幕（假阴性，与 configPath 那次同一个病）');
      expect(st.isPublicInstance, isTrue, reason: '★ 要能认出这是内置实例');
      expect(st.line, contains('内置公共实例'), reason: '★ 文案要分开说');
      expect(st.line, contains('已就绪'));
    });

    test('★★ 三个端点全 404 ⇒ 判离线', () async {
      final t = _Rec((_) => _notFound());
      final st = await DanmakuLocalService.probe(
        transport: t,
        endpoint: DanmakuConfig.publicInstanceEndpoint!,
      );
      expect(st.online, isFalse);
      expect(st.line, contains('暂时连不上'),
          reason: '★ 内置实例挂了用户**不用去改配置**（等我们换），文案别让他去改地址');
    });

    test('★★ 本机 2080 那条路**不**多打一次 search（别拖慢老路径）', () async {
      final t = _Rec((_) => _notFound());
      await DanmakuLocalService.probe(transport: t);
      final paths = t.calls.map((u) => u.path).toList();
      expect(paths.any((p) => p.contains('search/anime')), isFalse,
          reason: '★★ 本机 2080 本来就有 version/config 两个端点；'
              '多打一次 search 只会让「未运行」这条提示慢 3~5 s');
    });

    test('★★★ 探到内置实例 ⇒ select() 判 custom（不是 local）', () async {
      final t = _Rec((u) {
        if (u.path.endsWith('/api/v2/search/anime')) {
          return _ok(<String, Object?>{'animes': <Object>[]});
        }
        return _notFound();
      });
      final kind = await DanmakuSourceSelector.select(
        transport: t,
        endpoint: DanmakuConfig.publicInstanceEndpoint,
      );
      expect(kind, DanmakuSourceKind.custom,
          reason: '★★ local 是"去启动本机桌面版"，custom 是"地址在设置里可改" —— '
              '内置实例属于后者');
    });
  });
}

/// 记 headers 的假传输
class _HeaderRec implements DanmakuTransport {
  final List<Map<String, String>> headersList = <Map<String, String>>[];

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    headersList.add(Map<String, String>.from(headers));
    return _ok(<String, Object?>{
      'isMatched': false,
      'matches': <Object>[],
    });
  }

  @override
  void close() {}
}
