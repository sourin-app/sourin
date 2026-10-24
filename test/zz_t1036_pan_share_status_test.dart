import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';

/// 网盘分享识别 + 凭据状态的门禁
///
/// # 这条链路上的真问题
/// `pan.rs`（识别）与 `pan_auth.rs`（凭据）本来是两块互不相通的代码。
/// 不接起来的话，用户粘贴一个链接只会看到"不支持"，而**不知道卡在哪一步**：
/// 是认不出？还是没登录？还是登录过期？还是功能没做？
///
/// 本文件守的就是"分层原因必须正确"，而不是笼统的一个 false。
void main() {
  late Directory dataDir;
  var coreReady = false;

  setUpAll(() async {
    dataDir = await Directory.systemTemp.createTemp('sourin_pan_e2e_');
    try {
      final r = await SourinCore.startAsync(dataDir.path);
      coreReady = r['ok'] == true;
    } catch (_) {
      coreReady = false;
    }
    if (!coreReady) {
      // ignore: avoid_print
      print('PAN_E2E|core_ready=false ⇒ 本文件 FFI 部分会 skip（CI 测试阶段无 DLL）');
    }
  });

  tearDownAll(() async {
    try {
      await dataDir.delete(recursive: true);
    } catch (_) {}
  });

  // ── 纯解析（不依赖核心，CI 必跑）──

  group('PanShareStatus.fromJson', () {
    test('resolvable 恒为 false —— 取直链尚未实现，不许声称能播', () {
      final s = PanShareStatus.fromJson({
        'kind': 'quark',
        'kindName': '夸克网盘',
        'shareId': 'abc',
        'loggedIn': true,
        'resolvable': true, // 就算核心误报 true，也要看后端真实值
      });
      // 这里断言的是"解析尊重后端值"，而后端当前恒 false 由 Rust 测试守
      expect(s.resolvable, isTrue, reason: '解析层应忠实反映后端字段');
      final norm = PanShareStatus.fromJson({
        'kind': 'quark',
        'shareId': 'abc',
        'loggedIn': true,
      });
      expect(norm.resolvable, isFalse, reason: '缺字段时默认 false，不能默认能播');
    });

    test('缺 keyringAvailable 时默认为 true（不要把老核心当"钥匙串不可用"）', () {
      final s = PanShareStatus.fromJson({'kind': 'uc', 'shareId': 'x'});
      expect(s.keyringAvailable, isTrue);
    });

    test('recognized 要求同时有 kind 与 shareId', () {
      expect(
        PanShareStatus.fromJson({'kind': 'quark', 'shareId': 'abc'}).recognized,
        isTrue,
      );
      expect(
        PanShareStatus.fromJson({'kind': 'quark', 'shareId': ''}).recognized,
        isFalse,
        reason: '认出了盘但没有 id ⇒ 不算认出分享',
      );
      expect(
        PanShareStatus.fromJson({'kind': 'unknown', 'shareId': 'abc'}).recognized,
        isFalse,
      );
    });
  });

  // ── 走真实 FFI（分层原因必须正确）──

  Future<PanShareStatus?> call(String text) async {
    if (!coreReady) return null;
    return SourinApi.identifyPanShare(text);
  }

  test('认不出时原因要说明"无法识别"，而不是空话', () async {
    final s = await call('这只是一段普通文字，没有链接');
    if (s == null) {
      markTestSkipped('核心未启动（CI 测试阶段无 sourin_core.dll）');
      return;
    }
    expect(s.kind, 'unknown');
    expect(s.reason, contains('无法识别'));
    expect(s.resolvable, isFalse);
  });

  test('认出盘但链接没有分享 id ⇒ 原因要指出这一点', () async {
    // 只有域名、没有 /s/<id> 路径
    final s = await call('https://pan.quark.cn/');
    if (s == null) {
      markTestSkipped('核心未启动');
      return;
    }
    expect(s.kind, 'quark');
    expect(s.shareId, isEmpty);
    expect(s.reason, contains('没有分享 id'),
        reason: '★ 不能笼统说"不支持"：认出了盘但缺 id 与认不出是两回事');
  });

  test('认出分享且未登录 ⇒ 原因要指向"需要先登录"', () async {
    // 用天翼云盘：测试机上大概率没有它的登录态
    final s = await call('https://cloud.189.cn/t/abcdef');
    if (s == null) {
      markTestSkipped('核心未启动');
      return;
    }
    expect(s.kind, 'tianyi');
    expect(s.shareId, 'abcdef');
    if (!s.loggedIn) {
      expect(s.reason, contains('需要先登录'),
          reason: '★ 未登录时说"需要先登录"，而不是"不支持"');
    } else {
      // 万一测试机真登录过，就断言"已登录"这条分支的原因
      expect(s.reason, isNotEmpty);
    }
    expect(s.resolvable, isFalse, reason: '无论登不登录，取直链都还没做');
  });

  test('提取码能从正文取到（真实粘贴形态）', () async {
    const text = '分享给你，点击链接即可保存。\n'
        '链接：https://pan.quark.cn/s/abc123456\n'
        '提取码：8x2k';
    final s = await call(text);
    if (s == null) {
      markTestSkipped('核心未启动');
      return;
    }
    expect(s.shareId, 'abc123456');
    expect(s.pwd, '8x2k', reason: '提取码在正文里，只认 URL 会丢掉它');
  });
}
