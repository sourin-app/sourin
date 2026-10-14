import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

const _matchPath = '/api/v2/match';

class _RecTransport implements DanmakuTransport {
  _RecTransport(this.handler);

  final Future<DanmakuHttpResponse> Function(
      String method, Uri uri, Map<String, String> headers) handler;
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
    return handler(method, uri, headers);
  }

  @override
  void close() {}
}

void main() {
  setUp(() {
    UiPrefs.debugResetForTest(<String, String>{});
    DanmakuConfig.debugSetBuiltin(); // 回到缺省（清掉上一条注入）
  });
  tearDown(() {
    DanmakuConfig.debugSetBuiltin();
    UiPrefs.debugResetForTest(<String, String>{});
  });

  group('① 缺省路径无害（没注入也没覆盖 ⇒ 与改前逐字一致）', () {
    test('appId/appSecret 为空串，isConfigured=false，hasBuiltin=false', () {
      expect(DanmakuConfig.builtinAppId, '');
      expect(DanmakuConfig.builtinAppSecret, '');
      expect(DanmakuConfig.hasBuiltinCredentials, isFalse);
      expect(DanmakuConfig.appId, '');
      expect(DanmakuConfig.appSecret, '');
      expect(DanmakuConfig.isConfigured, isFalse);
      expect(DanmakuConfig.usingBuiltinAppId, isFalse);
      expect(DanmakuConfig.usingBuiltinAppSecret, isFalse);
    });
    test('statusText 缺省形态不变（无内置）', () {
      DanmakuConfig.setEnabled(true); // reset 后缺省是关，先开
      expect(DanmakuConfig.statusText, '弹幕已开启，但还没填 AppId / AppSecret');
      DanmakuConfig.setEnabled(false);
      expect(DanmakuConfig.statusText, '弹幕已关闭');
    });
  });

  group('② 注入内置（debugSetBuiltin）', () {
    test('getter 取到内置值，isConfigured=true，usingBuiltin=true', () {
      DanmakuConfig.debugSetBuiltin(appId: 'xgmriqmqcq', appSecret: 's3cret');
      // const（String.fromEnvironment）在没 --dart-define 的构建里仍是空串：
      // debugSetBuiltin 只接管「运行时读路径」，编译期常量动不了
      expect(DanmakuConfig.builtinAppId, '');
      expect(DanmakuConfig.builtinAppSecret, '');
      expect(DanmakuConfig.hasBuiltinCredentials, isTrue);
      expect(DanmakuConfig.appId, 'xgmriqmqcq');
      expect(DanmakuConfig.appSecret, 's3cret');
      expect(DanmakuConfig.isConfigured, isTrue);
      expect(DanmakuConfig.usingBuiltinAppId, isTrue);
      expect(DanmakuConfig.usingBuiltinAppSecret, isTrue);
      DanmakuConfig.setEnabled(true);
      expect(DanmakuConfig.statusText, '弹幕已开启（内置凭证 AppId xgmr****）');
    });
    test('内置值真的进签名：X-AppId == 内置 appId，X-Signature 非空', () async {
      DanmakuConfig.debugSetBuiltin(appId: 'builtin-id', appSecret: 'builtin-sec');
      final fake = _RecTransport((m, u, h) async => DanmakuHttpResponse(
            statusCode: 200,
            body: jsonEncode(<String, dynamic>{
              'success': true,
              'matches': <dynamic>[],
            }),
            headers: const {'content-type': 'application/json'},
          ));
      final client = ExternalDanmakuClient(transport: fake); // 不传 appId ⇒ 读 DanmakuConfig
      await client.match(fileName: 'EP01');
      expect(fake.calls, hasLength(1));
      final h = fake.calls.first.headers;
      expect(h['X-AppId'], 'builtin-id');
      expect(h['X-Signature'], isNotEmpty);
      expect(h['X-Timestamp'], isNotEmpty);
    });
    test('半边覆盖：只覆盖 AppSecret ⇒ AppId 仍走内置（各管各的）', () {
      DanmakuConfig.debugSetBuiltin(appId: 'b-id', appSecret: 'b-sec');
      DanmakuConfig.setAppSecret('user-sec');
      expect(DanmakuConfig.appId, 'b-id');
      expect(DanmakuConfig.appSecret, 'user-sec');
      expect(DanmakuConfig.usingBuiltinAppId, isTrue);
      expect(DanmakuConfig.usingBuiltinAppSecret, isFalse);
    });
  });

  group('③ 用户覆盖优先于内置（两条腿）', () {
    test('腿A（内存注入）：覆盖值 > 内置', () {
      DanmakuConfig.debugSetBuiltin(appId: 'builtin-id', appSecret: 'builtin-sec');
      DanmakuConfig.setAppId('user-id');
      DanmakuConfig.setAppSecret('user-sec');
      expect(DanmakuConfig.appId, 'user-id');
      expect(DanmakuConfig.appSecret, 'user-sec');
      expect(DanmakuConfig.usingBuiltinAppId, isFalse);
      expect(DanmakuConfig.usingBuiltinAppSecret, isFalse);
      DanmakuConfig.setEnabled(true);
      expect(DanmakuConfig.statusText, '弹幕已开启（AppId user****）');
    });
    test('腿B（真写 UiPrefs）：落盘的覆盖值优先于内置', () {
      DanmakuConfig.debugSetBuiltin(appId: 'builtin-id', appSecret: 'builtin-sec');
      UiPrefs.set(DanmakuConfig.keyAppId, 'disk-user-id');
      expect(DanmakuConfig.appId, 'disk-user-id');
      expect(DanmakuConfig.usingBuiltinAppId, isFalse);
    });
    test('覆盖空串 = 没覆盖（trim 后空是 remove）⇒ 回落内置', () {
      DanmakuConfig.debugSetBuiltin(appId: 'b-id', appSecret: 'b-sec');
      DanmakuConfig.setAppId('x');
      DanmakuConfig.setAppId('   ');
      expect(DanmakuConfig.appId, 'b-id');
      expect(DanmakuConfig.usingBuiltinAppId, isTrue);
    });
  });

  group('④ clearCredentials 后回落内置', () {
    test('清掉用户覆盖 ⇒ 内置生效', () {
      DanmakuConfig.debugSetBuiltin(appId: 'b-id', appSecret: 'b-sec');
      DanmakuConfig.setAppId('user-id');
      DanmakuConfig.setAppSecret('user-sec');
      expect(DanmakuConfig.appId, 'user-id');
      DanmakuConfig.clearCredentials();
      expect(DanmakuConfig.appId, 'b-id');
      expect(DanmakuConfig.appSecret, 'b-sec');
      expect(DanmakuConfig.isConfigured, isTrue);
      expect(DanmakuConfig.usingBuiltinAppId, isTrue);
    });
  });

  group('⑤ 源码契约（静态审计）', () {
    test('panel 凭证输入节**已恢复**；数据源行仍在；player_page 不碰内置常量', () {
      final dlgSrc =
          File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync();
      final ppSrc = File('lib/ui/player_page.dart').readAsStringSync();

      /*
       * ★★★ 2026-10-14（Owner「外部弹幕服务的凭证流程根本没走通」）：断言**翻转**。
       *
       * 改前（2026-10-11）这里要求"凭证输入节必须已删除"（当时认为内置凭证
       * 够了）。实际上**本地构建没有 --dart-define** ⇒ hasBuiltinCredentials
       * 为 false、UiPrefs 也无值 ⇒ 官方边必然 403，而写入口全仓 0 调用者 ⇒
       * 用户无路可走。⇒ 现在要求输入框与保存/清除回调**都在**。
       */
      expect(dlgSrc.contains("labelText: 'AppId'"), isTrue,
          reason: 'AppId 输入框必须恢复（无内置凭证的构建靠它）');
      expect(dlgSrc.contains("labelText: 'AppSecret'"), isTrue,
          reason: 'AppSecret 输入框必须恢复');
      expect(dlgSrc.contains('onSetCredentials'), isTrue,
          reason: '保存回调必须存在（面板纯 UI，落盘走宿主）');
      expect(dlgSrc.contains('onClearCredentials'), isTrue,
          reason: '清除回调必须存在');
      // 清白纪律：不许出现"把用户指去官网申请"的话术（面板只让用户直接填，
      // 不引导去外部站点）。这条两侧都成立，保留它。
      expect(dlgSrc.contains('在 dev.dandanplay.com 申请'), isFalse,
          reason: '面板不引导用户去官网申请（只提供直接填写）');

      // 但「数据源」状态行必须留下（它是本机外部弹幕 探测结果，与凭证无关）——
      // 防止改过头把它并掉。
      expect(dlgSrc.contains('数据源'), isTrue,
          reason: '「数据源」状态行必须保留');

      // player_page 不许**直接**读构建期注入常量（一律走 DanmakuConfig getter，
      // 面板与宿主都不碰注入细节）。
      expect(ppSrc.contains('builtinAppId'), isFalse,
          reason: 'player_page 不许直接读 builtinAppId 常量');
      expect(ppSrc.contains('builtinAppSecret'), isFalse);
    });
  });
}
