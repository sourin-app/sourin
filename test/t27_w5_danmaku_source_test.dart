import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku.dart';

// ══════════════════════════════════════════════════════════════════════
// T27-05（w5-dmsrc）：本地弹弹play数据源 —— 选择逻辑门禁
//
// 背景：dandanplay 弹幕服务有两个形态 ——
//   1. 本机桌面版（127.0.0.1:2080，**本地接口免签名**）；
//   2. 官方开放平台（api.dandanplay.net，要 X-AppId/X-Timestamp/X-Signature）。
// 改前客户端只会走官方 ⇒ 本机跑着弹弹play也要填凭证。本任务把「本地优先、
// 官方退路」做成 core 逻辑，并用假 transport 在**两种环境**（本地在线 /
// 本地离线）下钉死选路；同时用**源码断言**钉死：本地模式不生成签名头、
// 用 http://127.0.0.1:2080。
// ══════════════════════════════════════════════════════════════════════

const _versionPath = '/api/v2/system/version';
const _matchPath = '/api/v2/match';
const _commentsPath = '/api/v2/comment/9527';

Future<DanmakuHttpResponse> _okJson(Object? json) async =>
    DanmakuHttpResponse(
      statusCode: 200,
      body: jsonEncode(json),
      headers: const {'content-type': 'application/json'},
    );

/// 记录请求的假 transport（形状对齐 task13_danmaku_test.dart 的 FakeTransport）
class _RecTransport implements DanmakuTransport {
  _RecTransport(this.handler);

  final Future<DanmakuHttpResponse> Function(String method, Uri uri,
      Map<String, String> headers, String? body) handler;
  final List<({String method, Uri uri, Map<String, String> headers})> calls =
      [];

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

void main() {
  group('ExternalDanmakuClient 本地模式（unsignedLocal）', () {
    test('本地模式：请求落在 127.0.0.1:2080，且不带任何签名头', () async {
      final t = _RecTransport((method, uri, headers, body) async {
        if (uri.path == _matchPath) {
          return await _okJson({
            'isMatched': true,
            'matches': [
              {'episodeId': 9527, 'animeTitle': '攻壳', 'episodeTitle': '1'},
            ],
          });
        }
        return await _okJson({
          'count': 1,
          'comments': [
            {'cid': '1', 'p': '1,1,16777215', 'm': 'hello'},
          ],
        });
      });
      final c = ExternalDanmakuClient(
        transport: t,
        unsignedLocal: true,
        // 故意带上凭证：本地模式也**绝不**发签名头
        appId: 'myid',
        appSecret: 'mysecret',
      );
      final res = await c.loadFor(fileName: 'A.mp4');
      expect(res.comments, isNotEmpty);
      for (final call in t.calls) {
        expect(call.uri.host, '127.0.0.1',
            reason: '本地模式必须打本机外部弹幕端口，请求实际落在 ' + call.uri.toString());
        expect(call.uri.port, 2080);
        expect(call.uri.scheme, 'http',
            reason: '本机回环不需要 https');
        expect(call.headers.containsKey('X-AppId'), isFalse);
        expect(call.headers.containsKey('X-Timestamp'), isFalse);
        expect(call.headers.containsKey('X-Signature'), isFalse);
      }
      c.close();
    });

    test('官方模式（默认）：行为不变 —— 带签名头、打官方域名', () async {
      final t = _RecTransport((method, uri, headers, body) async {
        return await _okJson({
          'isMatched': true,
          'matches': [
            {'episodeId': 9527, 'animeTitle': '攻壳', 'episodeTitle': '1'},
          ],
        });
      });
      final c = ExternalDanmakuClient(transport: t, appId: 'myid', appSecret: 'b');
      await c.loadFor(fileName: 'A.mp4');
      expect(t.calls, isNotEmpty);
      final call = t.calls.first;
      expect(call.uri.host, 'api.dandanplay.net');
      expect(call.headers['X-AppId'], 'myid');
      expect(call.headers.containsKey('X-Signature'), isTrue);
      c.close();
    });
  });

  group('DanmakuSourceSelector.select（本地优先、官方退路）', () {
    test('本地在线 ⇒ 选本地，且探测请求落在 2080', () async {
      final t = _RecTransport((method, uri, headers, body) async {
        expect(uri.host, '127.0.0.1');
        expect(uri.port, 2080);
        return await _okJson({'success': true, 'versionCode': '100100'});
      });
      final kind = await DanmakuSourceSelector.select(transport: t);
      expect(kind, DanmakuSourceKind.local);
      expect(t.calls.single.uri.path, _versionPath);
    });

    test('本地离线（连接拒绝）⇒ 退回官方', () async {
      final t = _RecTransport((method, uri, headers, body) async {
        throw StateError('connection refused');
      });
      final kind = await DanmakuSourceSelector.select(transport: t);
      expect(kind, DanmakuSourceKind.official);
    });

    test('本地有服务但接口不像弹弹play（HTML 网页）⇒ 退回官方', () async {
      final t = _RecTransport((method, uri, headers, body) async {
        return const DanmakuHttpResponse(statusCode: 200, body: '<html><body>x</body></html>');
      });
      final kind = await DanmakuSourceSelector.select(transport: t);
      expect(kind, DanmakuSourceKind.official);
    });
  });

  group('DanmakuLocalService.describe（状态行文案）', () {
    test('探测失败 ⇒ 含「检测到本机外部弹幕 未运行」', () async {
      final t = _RecTransport((m, u, h, b) async =>
          throw StateError('connection refused'));
      final d = await DanmakuLocalService.describe(transport: t);
      expect(d.line, contains('检测到本机外部弹幕 未运行'));
      expect(d.online, isFalse);
    });

    test('探测成功 ⇒ 展示端口与版本，不含「未运行」', () async {
      final t = _RecTransport((m, u, h, b) async => await _okJson({'success': true, 'versionCode': '100100'}));
      final d = await DanmakuLocalService.describe(transport: t);
      expect(d.online, isTrue);
      expect(d.line, contains('本机外部弹幕'));
      expect(d.line, contains('2080'));
      expect(d.line, isNot(contains('未运行')));
    });
  });

  // ── 源码断言（保护接线，不跑 UI）──────────────────────────────────
  group('源码契约：T27-05 接线', () {
    final playerSrc = File('lib/ui/player_page.dart').readAsStringSync();
    final coreSrc = File('lib/core/danmaku.dart').readAsStringSync();
    final dialogSrc =
        File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync();

    test('player_page：数据源状态行进入弹幕设置面板（copyWith sourceLine）', () {
      expect(playerSrc, contains('DanmakuSettingsState.fromPrefs().copyWith('));
      expect(
        playerSrc,
        contains("_danmakuSourceLine = '数据源："),
        reason: '探测结果写进数据源状态行（面板 note 展示）',
      );
      expect(
        'sourceLine: _danmakuSourceLine'.allMatches(playerSrc).length,
        2,
        reason: '成功支与打开面板两处 copyWith 都要带数据源行',
      );
    });

    test('player_page：本地源支复用同一 setState（成功赋值形态唯一）', () {
      expect(
        "_danmakuStatus = 'danmaku-service · ".allMatches(playerSrc).length,
        1,
        reason: 'zz_cr_dmk_b 钉死：成功 setState 前缀赋值形态源码里只能一份'
            ' ⇒ 本地支必须复用它，不能复制第二份',
      );
    });

    test('core：选择器与本地服务常量就位', () {
      expect(coreSrc, contains('enum DanmakuSourceKind'));
      expect(coreSrc, contains('class DanmakuSourceSelector'));
      expect(coreSrc, contains('class DanmakuLocalService'));
      expect(coreSrc, contains("static const String localAuthority = '127.0.0.1:2080'"),
          reason: '本地模式 _uri 落 127.0.0.1:2080（http、免签名）');
      expect(coreSrc, contains('Uri.http(hostPort, versionPath)'),
          reason: '探针打本地版本接口');
    });

    test('dialog：数据源状态行保留；凭证输入框**已删**（2026-10-15）', () {
      expect(dialogSrc, contains('检测到本机外部弹幕 未运行'));
      expect(dialogSrc, contains('本机外部弹幕（127.0.0.1:2080）'));
      /*
       * ★★★ 2026-10-15（Owner）：断言**再次翻转** —— 输入框已删。
       *
       * 历史（别再翻回去）：
       * ```text
       * 2026-10-11  要求删（理由：客户端内置）
       * 2026-10-14  要求恢复（理由：**本地构建没有 --dart-define** ⇒ 无内置
       *            值 ⇒ 官方边必 403 且无入路可配。这个理由是**真的**。）
       * 2026-10-15  又删（Owner：「弹弹play我说过删除那两个输入框,改用内置的」）
       * ```
       * ★ 2026-10-14 那个理由之所以不再成立，是因为修了**根因**：
       *   `tools/run_client.ps1` 现在会从 `tools/.dandanplay.local.json`（已 gitignore）
       *   读凭证并注入 `--dart-define` ⇒ 本地构建**也有**内置值了。
       *   （删前已实测真 API：HTTP 200。见 lib/ui/player_page.dart 里那段说明。）
       */
      expect(dialogSrc.contains("labelText: 'AppId'"), isFalse,
          reason: '★ 输入框已删 —— 凭证改由构建期注入（官方 §7 允许的那条路）');
      expect(dialogSrc.contains("labelText: 'AppSecret'"), isFalse);
      // 但「数据源」这一节本身必须还在（它是本机外部弹幕 的探测结果行）。
      expect(dialogSrc, contains('数据源'));
    });
  });
}
