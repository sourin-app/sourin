import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';

/// 只有「动态库/符号缺失」这一类异常才算"环境缺件"
///
/// # 为什么必须有它（2026-10-25 交叉复核：这里原来是 `catch (_) {}`）
/// ```text
/// 原写法把**任何**启动异常都降级成 `coreReady = false` ⇒ 后续 3 条 FFI
/// 用例 `markTestSkipped`。后果：
///   · FFI 契约真的坏了（签名改错 / JSON 字段改名 / 初始化顺序回归）
///     ⇒ 测试**一样是绿的**（只是多了几个 skip）；
///   · 而"缺件"与"坏了"在用户那里是两件完全不同的事，门禁必须能分开。
/// ⇒ 只对下面这些**可指名的**缺件标记放行，其余 `fail()`。
/// 手法与 `zz_dialog18_unified_shell_test.dart:109 _isLibMissing` 同一套。
/// ```
bool _isLibMissing(Object e) {
  final s = e.toString().toLowerCase();
  const marks = <String>[
    'failed to load dynamic library',
    'cannot open shared object',
    'the specified module could not be found',
    '找不到指定的模块',
    'undefined symbol',
    'error code: 126',
  ];
  return marks.any(s.contains);
}

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
    } catch (e, st) {
      /*
       * ★ 2026-10-25（task-24 C）：这里原来是 `catch (_) { coreReady = false; }`
       * ⇒ **任何**异常都被当成"缺 DLL"，随后 3 条 FFI 用例静默 skip。
       * 现在分两类：
       *   ① 不是缺件（契约破坏 / 初始化回归 / JSON 形状错）⇒ **fail**，把红露出来；
       *   ② 是缺件：非 Windows ⇒ 允许 skip；**Windows ⇒ 必须 fail** ——
       *      本仓 Windows 的 dll 由 `cargo build --release` 产出并拷进 `windows/`
       *      （CI `.github/workflows/build.yml:518-528` 也是这么做的）
       *      ⇒ 本机缺它说明环境没搭好，skip 会把这件事藏起来。
       */
      if (!_isLibMissing(e)) {
        fail('核心启动失败（**不是**缺件 ⇒ 不许降级成 skip）：$e\n$st');
      }
      if (Platform.isWindows) {
        fail('Windows 上缺 sourin_core.dll 必须 fail（不许 skip）：$e\n'
            '先 `cd rust/sourin_core && cargo build --release`，'
            '再把 sourin_core.dll 拷到 windows/'
            '（CI 见 .github/workflows/build.yml:518-528）。');
      }
      coreReady = false;
      // ignore: avoid_print
      print('PAN_E2E|lib_missing ⇒ 本文件 FFI 部分会 skip（非 Windows 缺件）：$e');
    }
    if (!coreReady) {
      // ignore: avoid_print
      print('PAN_E2E|core_ready=false ⇒ 本文件 FFI 部分会 skip');
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

  test('认出分享后 ⇒ 原因必须与「登录态/过期」两字段**一一对应**（④⑤ 两档也钉死）', () async {
    // 用天翼云盘：测试机上大概率没有它的登录态
    final s = await call('https://cloud.189.cn/t/abcdef');
    if (s == null) {
      markTestSkipped('核心未启动');
      return;
    }
    expect(s.kind, 'tianyi');
    expect(s.shareId, 'abcdef');
    /*
     * ★★★ 2026-10-25（task-24 C）：这一段原来是
     * ```text
     *   if (!s.loggedIn) { expect(reason, contains('需要先登录')); }
     *   else            { expect(reason, isNotEmpty); }   // ← 兜底，等于没验
     * ```
     * ⇒ **④过期 / ⑤已登录但未接直链** 两档从来没有断言，
     *   而 `else expect(reason, isNotEmpty)` 连"非空"都能过。
     *
     * 现在改成**按响应自己的两个字段选档**，每一档都断言**逐字文案**：
     *   ③ 未登录      → 「需要先登录<盘名>」
     *   ④ 已登录过期  → 「<盘名>的登录已过期，请重新登录」
     *   ⑤ 已登录正常  → 「已登录；取直链功能尚未接入」（`resolvable=false` 的如实声明）
     * ⚠️ 这是**全映射**判据：无论本机停在哪个状态，落到的那一档文案都必须逐字对上，
     *    不再有"非空即过"的出口。④⑤ 在本机可能不触发（需要钥匙串里有对应凭据），
     *    缺的是**夹具**而不是判据——这一点如实登记，不假装覆盖。
     */
    if (!s.loggedIn) {
      expect(s.reason, '需要先登录${s.kindName}',
          reason: '★★ ③ 未登录档：必须点名是哪个网盘，且不是"不支持"');
    } else if (s.expired) {
      expect(s.reason, '${s.kindName}的登录已过期，请重新登录',
          reason: '★★ ④ 过期档：必须说"过期"，不许退回"需要先登录"（那是误诊）');
    } else {
      expect(s.reason, '已登录；取直链功能尚未接入',
          reason: '★★★ ⑤ 已登录但取直链未实现：逐字断言 —— '
              '这一档的全部意义就是**不许**冒充能播');
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
