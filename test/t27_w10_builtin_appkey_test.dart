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

/// Strip comments so a passing assertion cannot be satisfied (or broken) by
/// explanatory prose. The 2026-10-15 notes legitimately MENTION the injected
/// constants, so a naive `contains` would produce a false red.
String stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return noBlock
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

void main() {
  /*
   * ⚠️ 2026-10-18（round-65 批次 B）：必须在这里关掉**内置公共实例**。
   *
   * # 为什么
   * 批次 B 给 danmaku 加了 `kDanmakuPublicInstances`（内置的 dan-api 公共实例），
   * 上线后「没配 endpoint」的含义从「走官方/本机」变成了「先走内置实例」。
   *
   * 而本文件测的是**凭证签名**（X-AppId / X-Signature）：它需要一个
   * 「只有官方这一条路」的环境，否则请求会被内置实例接管，
   * 签名头根本不产生 ⇒ `X-AppId` 读到 null（实测：
   *   Expected: 'builtin-id'  Actual: <null>）。
   *
   * # 为什么单独跑不红、混跑才红
   * 其它 danmaku 测试（t105 / t27_w5 / t3_danmu_api / task35）都在 setUp 里
   * 调了 `debugSetPublicInstances(const [])`，跑完后 **没有** 恢复成 null；
   * 本文件本来没有这一行 ⇒ 一旦谁在同一个 isolate 里先跑过别的文件，
   * 全局静态状态就带着「内置已关/已开」的残留进来。
   * ⇒ 补上这一行，让本文件**不依赖执行顺序**。
   */
  setUp(() {
    UiPrefs.debugResetForTest(<String, String>{});
    DanmakuConfig.debugSetBuiltin(); // 回到缺省（清掉上一条注入）
    DanmakuConfig.debugSetPublicInstances(const <DanmakuPublicInstance>[]);
  });
  tearDown(() {
    DanmakuConfig.debugSetBuiltin();
    DanmakuConfig.debugSetPublicInstances(null);
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
    test('panel credential input section REMOVED (built-in now); data-source row kept; player_page red line still holds', () {
      final dlgSrc =
          File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync();
      final ppSrc = stripComments(File('lib/ui/player_page.dart').readAsStringSync());

      /*
       * 2026-10-15 (Owner): assertion FLIPPED back to "the input boxes must be
       * gone", reversing the 2026-10-14 flip.
       *
       * Owner's words:
       *   > I told you to delete those two input boxes and use the built-in
       *   > credentials -- it is still not done.
       * and:
       *   > check whether the developer statement allows built-in; if not,
       *   > never mind, keep the input boxes.
       *
       * Checked: it DOES allow it. The official Open Danmaku Network docs,
       * section 7 (Security Notes), state that an open-source client may
       * "use a placeholder in the open-source code ... then at build time
       * read the AppSecret from a secret store and substitute the
       * placeholder". This repo does exactly that (String.fromEnvironment +
       * GitHub Secrets in build.yml + tools/run_client.ps1 for local builds),
       * so removing the boxes is legitimate.
       *
       * The earlier "must restore the input boxes" rationale no longer
       * applies: its premise was that a local build has no --dart-define and
       * therefore cannot work. That is a BUILD CONFIGURATION gap, and the fix
       * is to give local builds credentials too -- not to make users type
       * them by hand.
       *
       * NOTE: the inner red line (player_page must not touch the injected
       * constants directly) is UNCHANGED.
       */
      expect(dlgSrc.contains("labelText: 'AppId'"), isFalse,
          reason: 'AppId input box must be gone (built-in credentials now)');
      expect(dlgSrc.contains("labelText: 'AppSecret'"), isFalse,
          reason: 'AppSecret input box must be gone (same reason)');
      /*
       * NOTE: assert on the CODE forms (`this.onSetCredentials` / a trailing
       * `;`), not the bare identifier. The bare name still appears in an
       * explanatory comment inside that file, and matching it would make this
       * assertion fail for the wrong reason (a false red, which is just as
       * corrosive as a false green).
       */
      expect(dlgSrc.contains('this.onSetCredentials'), isFalse,
          reason: 'save path must be removed too (half-dead otherwise)');
      expect(dlgSrc.contains('this.onClearCredentials'), isFalse,
          reason: 'clear path likewise');
      expect(dlgSrc.contains('? onSetCredentials;'), isFalse);
      expect(dlgSrc.contains('? onClearCredentials;'), isFalse);
      // What was deleted is the INPUT, not the VISIBILITY: the status line
      // must stay so users can still see built-in vs not-configured.
      expect(dlgSrc.contains('_credentialStatusText'), isTrue,
          reason: 'credential status line must remain');

      // player_page 不许**直接**读构建期注入常量（一律走 DanmakuConfig getter，
      // 面板与宿主都不碰注入细节）。
      expect(ppSrc.contains('builtinAppId'), isFalse,
          reason: 'player_page 不许直接读 builtinAppId 常量');
      expect(ppSrc.contains('builtinAppSecret'), isFalse);
    });
  });
}
