// ═══════════════════════════════════════════════════════════════════════
//  task-105：外部弹幕服务的**凭证流程真的走通**（Owner 2026-10-14 反馈）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 本地播放提示弹弹play没有收到凭证,说明弹弹play流程根本没走通
// ```
// （★ 本仓规矩：代码/注释/文案不许出现具体服务名，这里用「外部弹幕服务」中性词。）
//
// # 本文件要钉住的那条**端到端**链路
// ```text
// 面板输入一对 AppId / AppSecret → 保存（DanmakuConfig.setAppId/setAppSecret）
//   → 生效值进 DanmakuConfig.appId/appSecret
//   → 客户端用生效值签出 X-AppId / X-Timestamp / X-Signature（签名随参数变）
// ```
// 改前这条链**断在第一步**：面板的凭证输入框被整节删了、写入口全仓 0 调用者
// ⇒ 本地构建（没有 --dart-define）里 `hasBuiltinCredentials == false`、UiPrefs
// 也没值 ⇒ 打官方边必然 403「弹幕服务没收到凭证」，用户无路可走。
//
// # 铁律：判据必须能测出反面（红度实测）
// ```text
// 本文件的「签名真的随凭证变」这条断言：把 `DanmakuConfig.setAppId` 体内的
// 写入（`_writeTrimmed(keyAppId, v)`）去掉 ⇒ 生效值回落内置/空串 ⇒
// X-AppId 不再是用户填的值 ⇒ **必红**。这一条是"证件链真的接上"的可计算证明，
// 不靠肉眼看 UI。
// ```

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 假传输层：把请求头原样记下来供断言（与 task13 同款，确定性、不联网）
class _FakeTransport implements DanmakuTransport {
  final List<Map<String, String>> headers = <Map<String, String>>[];

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    this.headers.add(Map<String, String>.of(headers));
    return const DanmakuHttpResponse(
      statusCode: 200,
      body: '{"success":true,"matches":[]}',
      headers: <String, String>{'content-type': 'application/json'},
    );
  }

  @override
  void close() {}
}

void main() {
  setUp(() {
    UiPrefs.debugResetForTest(<String, String>{});
    DanmakuConfig.debugSetBuiltin(); // 回到缺省（读 const = 无内置）
    /*
     * ★★★ 2026-10-17（Owner 第 4 条）：内置公共实例上线后，
     * 「没配地址 ⇒ 走官方（要签名）」会被内置实例顶掉。
     * 本文件测的是**签名三件套**那条边 ⇒ 必须把内置实例关掉，
     * 否则测的是免凭证的内置路（假绿：签名头根本不会发）。
     */
    DanmakuConfig.debugSetPublicInstances(const <DanmakuPublicInstance>[]);
  });

  tearDown(() {
    DanmakuConfig.debugSetBuiltin();
    UiPrefs.debugResetForTest(<String, String>{});
    DanmakuConfig.debugSetPublicInstances(null);
  });

  group('① 用户填了凭证 ⇒ 签名头真的带上了三件套（端到端）', () {
    test('setAppId + setAppSecret ⇒ X-AppId 生效，X-Timestamp / X-Signature 非空',
        () async {
      // 本地构建的现实：没有内置凭证
      expect(DanmakuConfig.hasBuiltinCredentials, isFalse);
      expect(DanmakuConfig.isConfigured, isFalse,
          reason: '未填前 = 未配置（这正是"没收到凭证"的来源）');

      // ★ 用户手填（面板「保存」按钮走的就是这两个方法）
      DanmakuConfig.setAppId('user-app-id');
      DanmakuConfig.setAppSecret('user-app-secret');

      // 生效值真的变了
      expect(DanmakuConfig.appId, 'user-app-id');
      expect(DanmakuConfig.appSecret, 'user-app-secret');
      expect(DanmakuConfig.isConfigured, isTrue);
      expect(DanmakuConfig.usingBuiltinAppId, isFalse,
          reason: '用户填写压过内置');
      expect(DanmakuConfig.userAppId, 'user-app-id',
          reason: '面板预填读的是这个（只看用户覆盖）');

      // ★★ 真正的"走通"：客户端签出的头带上三件套
      final fake = _FakeTransport();
      final client = ExternalDanmakuClient(
        transport: fake,
        appId: DanmakuConfig.appId,
        appSecret: DanmakuConfig.appSecret,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1735660800 * 1000, isUtc: true),
      );
      await client.match(fileName: 'EP01');

      final h = fake.headers.single;
      expect(h['X-AppId'], 'user-app-id');
      expect(h['X-Timestamp'], '1735660800');
      expect(h['X-Signature'], isNotEmpty, reason: '★ 签名必须非空');
      expect(
        h['X-Signature'],
        sha256Base64('user-app-id' '1735660800' '/api/v2/match' 'user-app-secret'),
        reason: '签名 = base64(sha256(AppId + Timestamp + Path + AppSecret))',
      );
      // ⚠️ 反面（红度）：把 setAppId 的写入去掉 ⇒ X-AppId 变成内置/空串 ⇒ 这里必红。
    });

    test('★ 签名随参数变（时间戳变了 ⇒ 签名必变，不是常量）', () async {
      DanmakuConfig.setAppId('id-x');
      DanmakuConfig.setAppSecret('sec-x');

      Future<String> sigAt(int seconds) async {
        final fake = _FakeTransport();
        final client = ExternalDanmakuClient(
          transport: fake,
          appId: DanmakuConfig.appId,
          appSecret: DanmakuConfig.appSecret,
          clock: () => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
        );
        await client.match(fileName: 'EP01');
        return fake.headers.single['X-Signature']!;
      }

      final a = await sigAt(1000);
      final b = await sigAt(2000);
      expect(a, isNotEmpty);
      expect(b, isNotEmpty);
      expect(a, isNot(b), reason: '时间戳变 ⇒ 签名必须变（否则签名是假的）');
    });

    test('★ AppSecret 变了 ⇒ 签名也变（凭证真的参与了签名）', () async {
      DanmakuConfig.setAppId('id-y');
      DanmakuConfig.setAppSecret('sec-1');
      DanmakuConfig.setAppSecret('sec-2'); // 用户改了 Secret
      final fake = _FakeTransport();
      final client = ExternalDanmakuClient(
        transport: fake,
        appId: DanmakuConfig.appId,
        appSecret: DanmakuConfig.appSecret,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000 * 1000, isUtc: true),
      );
      await client.match(fileName: 'EP01');
      final h = fake.headers.single;
      expect(
        h['X-Signature'],
        sha256Base64('id-y' '1000' '/api/v2/match' 'sec-2'),
        reason: '★ 签名读的是**生效**的 AppSecret（sec-2），不是旧值',
      );
    });
  });

  group('② clearCredentials() ⇒ 回到"未配置"态', () {
    test('清掉用户覆盖后：生效值回落（此处无内置 ⇒ 空串 ⇒ 未配置）', () {
      DanmakuConfig.setAppId('id-z');
      DanmakuConfig.setAppSecret('sec-z');
      expect(DanmakuConfig.isConfigured, isTrue);

      DanmakuConfig.clearCredentials();

      expect(DanmakuConfig.appId, '');
      expect(DanmakuConfig.appSecret, '');
      expect(DanmakuConfig.userAppId, '');
      expect(DanmakuConfig.userAppSecret, '');
      expect(UiPrefs.get(DanmakuConfig.keyAppId), isNull,
          reason: '两个键被 remove（不留垃圾）');
      expect(UiPrefs.get(DanmakuConfig.keyAppSecret), isNull);
      expect(DanmakuConfig.isConfigured, isFalse,
          reason: '★ 回到"未配置"态 —— 面板据此如实显示"官方边会失败"');
    });

    test('有内置时：清掉用户覆盖 ⇒ 回落内置（不是清成没配置）', () {
      DanmakuConfig.debugSetBuiltin(appId: 'builtin-id', appSecret: 'builtin-sec');
      DanmakuConfig.setAppId('user-id');
      DanmakuConfig.setAppSecret('user-sec');
      expect(DanmakuConfig.usingBuiltinAppId, isFalse);

      DanmakuConfig.clearCredentials();

      expect(DanmakuConfig.appId, 'builtin-id');
      expect(DanmakuConfig.appSecret, 'builtin-sec');
      expect(DanmakuConfig.usingBuiltinAppId, isTrue);
      expect(DanmakuConfig.isConfigured, isTrue,
          reason: '回落内置 ⇒ 仍有凭证');
    });
  });

  group('③ 落盘纪律：用户填的值只进 UiPrefs（本机），不进仓库', () {
    test('setAppId/setAppSecret 写的是 UiPrefs 那两个键', () {
      DanmakuConfig.setAppId('repo-safe-id');
      DanmakuConfig.setAppSecret('repo-safe-secret');
      expect(UiPrefs.get(DanmakuConfig.keyAppId), 'repo-safe-id');
      expect(UiPrefs.get(DanmakuConfig.keyAppSecret), 'repo-safe-secret');
    });

    test('空白串会被 trim/清除（不写空键）', () {
      DanmakuConfig.setAppId('   ');
      DanmakuConfig.setAppSecret('  ');
      expect(UiPrefs.get(DanmakuConfig.keyAppId), isNull);
      expect(UiPrefs.get(DanmakuConfig.keyAppSecret), isNull);
      expect(DanmakuConfig.isConfigured, isFalse);
    });
  });
}
