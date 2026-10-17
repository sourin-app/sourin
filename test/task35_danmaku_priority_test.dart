// ═══════════════════════════════════════════════════════════════════════
//  task-35 / Owner 第 7 条：dan-api 优先 + 设置页可发现
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的两个真缺陷
// ```text
// ① 优先级倒置：本机弹弹play 一在线，用户配的 dan-api 就**永远轮不到**
// ② 发现性：能力全实现了，但设置页一级看不到任何「弹幕」字样
// ```
//
// # ① 的机制（不是猜的，是读代码 + 跑出来的）
// ```text
// 宿主 player_page 的判据是：
//   usingLocal = localStatus.online && !_danmakuForceOfficial
// 而 localStatus.online 是「本机 2080 或 自建后端」**共用**的一个标志。
// 改前 ExternalDanmakuClient._endpoint 写成：
//   if (explicit != null) return explicit;
//   if (_unsignedLocal) return null;          // ← 本机在线就到这里返回 null
//   return DanmakuConfig.danmakuEndpoint;      // ← 用户的 dan-api 永不执行
// ⇒ 用户填了地址、点测试也通，取弹幕却还在打 2080。
// ```
//
// # 为什么用「请求真的落在哪」作判据
// 断言 `_endpoint != null` 是**读实现**，实现换个写法就假绿。
// 这里注入假 transport 记下每一次请求的 host/port —— 那是**行为**读数：
// 只有真的把请求发到 dan-api 的端口，才算「优先级生效」。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 记录每次请求落点的假 transport（零联网）
class _RecTransport implements DanmakuTransport {
  _RecTransport(this.handler);

  final Future<DanmakuHttpResponse> Function(
      String method, Uri uri, Map<String, String> headers, String? body) handler;

  final List<({String method, Uri uri, Map<String, String> headers})> calls = [];

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
  void close() {}
}

DanmakuHttpResponse _json(Object j) => DanmakuHttpResponse(
      statusCode: 200,
      body: j is String ? j : '{}',
    );

void main() {
  setUp(() => UiPrefs.debugResetForTest());
  tearDown(() => UiPrefs.debugResetForTest());

  // ═══════════════════════════════════════════════════════════════════
  //  ① 优先级：dan-api 必须压过本机弹弹play
  // ═══════════════════════════════════════════════════════════════════

  group('① dan-api 优先于本机弹弹play', () {
    test('★★★ 配了 dan-api + unsignedLocal=true ⇒ 请求落在 dan-api（不是 2080）', () async {
      UiPrefs.setDanmakuEndpoint('http://127.0.0.1:9321');
      final t = _RecTransport((m, uri, h, b) async => _json({'isMatched': false, 'matches': []}));
      final c = ExternalDanmakuClient(transport: t, unsignedLocal: true);
      await c.match(fileName: 'A.mp4');
      c.close();

      expect(t.calls, isNotEmpty, reason: '一个请求都没发 ⇒ 判据无读数');
      expect(
        t.calls.first.uri.port,
        9321,
        reason: '★ 配了 dan-api 却仍然打本机 2080 —— 这就是 Owner 说的'
            '「弹弹play不行就换成dan-api」做不到的根因（改前 _unsignedLocal'
            ' 提前 return null，用户的地址被完全忽略）。',
      );
    });

    test('★ 没配 dan-api ⇒ 仍然走本机 2080（老路径一条都没删）', () async {
      final t = _RecTransport((m, uri, h, b) async => _json({'isMatched': false, 'matches': []}));
      final c = ExternalDanmakuClient(transport: t, unsignedLocal: true);
      await c.match(fileName: 'A.mp4');
      c.close();

      expect(t.calls.first.uri.port, 2080,
          reason: '没配 dan-api 的机器必须与改前逐字一致');
    });

    test('★ 配了 dan-api + unsignedLocal=false ⇒ 也是 dan-api', () async {
      UiPrefs.setDanmakuEndpoint('http://10.1.2.3:9321');
      final t = _RecTransport((m, uri, h, b) async => _json({'isMatched': false, 'matches': []}));
      final c = ExternalDanmakuClient(transport: t);
      await c.match(fileName: 'A.mp4');
      c.close();

      expect(t.calls.first.uri.host, '10.1.2.3');
    });

    test('★ 显式传入的 endpoint 仍然最优先（测试注入不许被偏好顶掉）', () async {
      UiPrefs.setDanmakuEndpoint('http://127.0.0.1:9321');
      final t = _RecTransport((m, uri, h, b) async => _json({'isMatched': false, 'matches': []}));
      final c = ExternalDanmakuClient(
        transport: t,
        endpoint: const DanmakuEndpoint(baseUrl: 'http://10.0.0.5:8080'),
      );
      await c.match(fileName: 'A.mp4');
      c.close();

      expect(t.calls.first.uri.host, '10.0.0.5',
          reason: '显式参数必须压过偏好 —— 否则测试注入会失效');
    });

    test('★ dan-api 模式下仍然**不发签名头**（免凭证，与 2080 同款）', () async {
      UiPrefs.setDanmakuEndpoint('http://127.0.0.1:9321');
      final t = _RecTransport((m, uri, h, b) async => _json({'isMatched': false, 'matches': []}));
      final c = ExternalDanmakuClient(
        transport: t,
        unsignedLocal: true,
        appId: 'myid',
        appSecret: 'mysecret',
      );
      await c.match(fileName: 'A.mp4');
      c.close();

      final h = t.calls.first.headers;
      expect(h.containsKey('X-AppId'), isFalse, reason: 'dan-api 免凭证，不该发签名');
      expect(h.containsKey('X-Signature'), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 发现性：设置页一级必须有一条弹幕源入口，且副标题带状态
  // ═══════════════════════════════════════════════════════════════════

  group('② 设置页一级的可发现性', () {
    test('★★★ 一级页有「弹幕源」入口行，且指向 DanmakuSourcePage', () async {
      final src = _read('lib/ui/settings_page.dart');
      expect(src, contains("title: '弹幕源'"),
          reason: '★ Owner 原话「配置页没看到」—— 一级页必须有这条入口');
      expect(src, contains('DanmakuSourcePage'),
          reason: '入口必须真的指向那个配置页（光有字不叫接线）');
      expect(src, contains("import 'settings/danmaku_source_page.dart';"));
    });

    test('★★ 副标题随偏好变化（已配置 / 未配置两种文案都在）', () async {
      final src = _read('lib/ui/settings_page.dart');
      expect(src, contains('_danmakuEndpointSubtitle'),
          reason: '副标题必须是**动态**的 —— 写死一句话就看不出配没配');
      expect(src, contains("UiPrefs.danmakuEndpoint"));
    });

    test('★★ 配置页真的有地址 + token 两个输入框和测试按钮', () async {
      final src = _read('lib/ui/settings/danmaku_source_page.dart');
      expect(src, contains('test连接'.replaceAll('test', '测试')));
      expect(src, contains('UiPrefs.setDanmakuEndpoint'),
          reason: '测通了必须落盘，否则用户改了等于没改');
      expect(src, contains('UiPrefs.setDanmakuToken'));
      expect(src, contains('TextEditingController'),
          reason: '没有输入框 = 用户没法改地址');
    });
  });
}

/// 读源码做「契约断言」—— 本项目既有做法（见 test/models_contract_test.dart）。
///
/// ⚠️ 这里断言的是**接线**（「有没有这条入口行」），不是实现细节；
///    行为层面的判据在 group ① 里（请求真的落在哪个端口）。
String _read(String rel) => File(rel).readAsStringSync();