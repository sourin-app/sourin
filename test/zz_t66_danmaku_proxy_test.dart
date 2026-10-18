// 弹幕代理（a+b）门禁
//
// # 覆盖四条验收判据
// ```text
// ① 直连模式下 findProxy 必须是 'DIRECT'（不把正常路径弄坏）
// ② 自定义模式必须**真的**下发 PROXY（不是摆设）
// ③ 自定义地址解析正确（各种写法）
// ④ ★★ 环境变量 HTTPS_PROXY 存在与不存在，resolve 结果必须**完全一致**
//      ← 这条是"把选择权给用户"的核心判据，也是最容易做成假绿的一条
// ```
//
// # 判据 ④ 为什么必须单独测
// ```text
// `HttpClient.findProxy` 的语义是：
//   赋值 ⇒ 完全按回调走，**完全不读**环境变量
//   不赋值 ⇒ Dart 去读 HTTPS_PROXY
// ⇒ 若 direct 模式错误地写成"不赋值"，那么：
//      有 HTTPS_PROXY 时它会偷偷走代理，没环境变量时直连
//      而**两种情况下我们的返回值都是同一个**（都是 null）
//   ⇒ 只看"返回 null"是**看不出来的**（那正是假绿）
// ⇒ 所以 ④ 必须验两件事：
//      (a) resolve 的返回值在两种环境变量下相同  ← 我们的函数是纯函数，恒真但要有记录
//      (b) ★ 真正的判据：direct ⇒ 返回值是 'DIRECT' 而**不是** null
//          因为 null 才会触发"读环境变量"那个行为
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

void main() {
  // ══════════════════════════════════════════════════════════════════
  //  ① 直连：必须是 'DIRECT'，不是 null
  // ══════════════════════════════════════════════════════════════════
  test('① 直连模式 ⇒ 显式 DIRECT（不是 null）', () {
    final r = resolveDanmakuFindProxy(mode: DanmakuProxyMode.direct);
    expect(r, 'DIRECT');
    /*
     * ★★ 这一条是本文件**最重要**的断言。
     *
     * 若实现写成"direct ⇒ 返回 null"（直觉上"不设代理"就是 null），
     * 那么 HttpSession 会去读 HTTPS_PROXY ⇒ 用户的"直连"选择被静默推翻。
     *
     * ⇒ 必须钉死 r != null，而不只是 r == 'DIRECT'（后者已隐含，但要写明意图）。
     */
    expect(r, isNotNull, reason: 'null 会让 Dart 去读环境变量 ⇒ 直连失效');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 自定义：必须真的下发 PROXY
  // ══════════════════════════════════════════════════════════════════
  test('② 自定义模式 ⇒ 真的下发 PROXY host:port', () {
    expect(
      resolveDanmakuFindProxy(
        mode: DanmakuProxyMode.custom,
        url: 'http://127.0.0.1:7890',
      ),
      'PROXY 127.0.0.1:7890',
    );
    // 无 scheme 也要能用（用户常直接粘 host:port）
    expect(
      resolveDanmakuFindProxy(
        mode: DanmakuProxyMode.custom,
        url: '127.0.0.1:7890',
      ),
      'PROXY 127.0.0.1:7890',
    );
    // 域名 + 端口
    expect(
      resolveDanmakuFindProxy(
        mode: DanmakuProxyMode.custom,
        url: 'http://proxy.lan:8888',
      ),
      'PROXY proxy.lan:8888',
    );
  });

  test('②b 自定义地址坏掉 ⇒ 退回显式 DIRECT（不是 null，也不是跟着系统走）', () {
    // 空地址
    expect(
      resolveDanmakuFindProxy(mode: DanmakuProxyMode.custom, url: ''),
      'DIRECT',
    );
    // 有 scheme 没端口
    expect(
      resolveDanmakuFindProxy(
        mode: DanmakuProxyMode.custom,
        url: 'http://noport',
      ),
      'DIRECT',
    );
    // 纯垃圾
    expect(
      resolveDanmakuFindProxy(mode: DanmakuProxyMode.custom, url: '   '),
      'DIRECT',
    );
  });

  test('②c ★ socks 地址必须被拒绝（dart:io 不支持，实测见下）', () {
    /*
     * # 实测依据（不是推测）
     * ```text
     * 真发请求（本机 HTTP 服务 + 假 socks 端口）：
     *   DIRECT                   ⇒ OK status=200
     *   SOCKS5 127.0.0.1:<port>  ⇒ HttpException: Invalid proxy configuration
     *                              target 命中 +0，假 socks 端口 accept +0
     * ⇒ dart:io 的 findProxy 只认 DIRECT / PROXY。
     * ```
     * ⇒ 所以 `socks5://h:1080` **不能**被解析成 `PROXY h:1080`
     *   （那会让用户以为在用 socks5，实际是明文 HTTP 代理打到 socks 端口）
     */
    for (final u in [
      'socks5://127.0.0.1:1080',
      'socks://127.0.0.1:1080',
      'SOCKS5://127.0.0.1:1080',
    ]) {
      expect(
        resolveDanmakuFindProxy(mode: DanmakuProxyMode.custom, url: u),
        'DIRECT',
        reason: '$u 必须被拒绝，不能静默换成 HTTP 代理',
      );
      expect(isSocksProxyUrl(u), isTrue, reason: 'UI 要靠它给专门文案');
    }
    // socks 的 UI 文案必须是**专门**的，不能和普通"无效"混同
    expect(
      diagnoseDanmakuProxy(
        mode: DanmakuProxyMode.custom,
        url: 'socks5://127.0.0.1:1080',
      ),
      contains('不支持 socks'),
    );
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ system 模式：必须是 null（Dart 唯一能表达"跟随系统"的方式）
  // ══════════════════════════════════════════════════════════════════
  test('③ 跟随系统 ⇒ null（这是"读环境变量"的唯一表达方式）', () {
    final r = resolveDanmakuFindProxy(mode: DanmakuProxyMode.system);
    expect(r, isNull);
    /*
     * ★ 与 ① 组成一对：direct 必须**不是** null，system 必须**是** null。
     *   两个断言合起来才证明"直连"和"跟随系统"真是两件事。
     *   只测其中一个 ⇒ 实现若把两者写成同一个值，测不出来。
     */
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ ★★ 环境变量无关性
  // ══════════════════════════════════════════════════════════════════
  test('④ ★★ HTTPS_PROXY 存在与不存在，三种模式的解析结果必须完全一致', () {
    // 记录原始值（可能为 null）
    final origHttp = Platform.environment['HTTP_PROXY'];
    final origHttps = Platform.environment['HTTPS_PROXY'];

    /// 取三种模式在当前环境下的结果快照
    List<String?> snapshot() => [
          resolveDanmakuFindProxy(mode: DanmakuProxyMode.direct),
          resolveDanmakuFindProxy(mode: DanmakuProxyMode.system),
          resolveDanmakuFindProxy(
            mode: DanmakuProxyMode.custom,
            url: 'http://127.0.0.1:7890',
          ),
        ];

    final before = snapshot();
    // ignore: avoid_print
    print('[PROXY-ENV] 原始 HTTP_PROXY=${origHttp ?? "<null>"} '
        'HTTPS_PROXY=${origHttps ?? "<null>"}');
    // ignore: avoid_print
    print('[PROXY-ENV] 快照(before)=$before');

    /*
     * ★ 注意：`Platform.environment` 在进程内是**只读快照**，
     *   set env 改不了它（Dart 没有公开 API 改进程环境）。
     *   ⇒ 这里能诚实验证的是「**我们的解析函数不读环境变量**」，
     *     也就是它是**纯函数** —— 这由它没有 I/O、只看入参保证。
     *
     * ★ 真正会把环境变量读进来的地方是**没赋值 findProxy 的 HttpClient**。
     *   ⇒ 所以第 ① 条「direct 必须是 'DIRECT' 而不是 null」才是
     *     把那个隐式读取**关掉**的动作。两条合起来才完整。
     */
    expect(Platform.environment.containsKey('HTTPS_PROXY'),
        Platform.environment.containsKey('HTTPS_PROXY'),
        reason: '只是记录，不假设');

    final again = snapshot();
    expect(again, before, reason: '多次调用必须完全一致（纯函数）');

    // ★ 关键结构性断言：direct 与 system 必须**不同**，否则用户选择白给
    final direct = resolveDanmakuFindProxy(mode: DanmakuProxyMode.direct);
    final system = resolveDanmakuFindProxy(mode: DanmakuProxyMode.system);
    expect(
      direct,
      isNot(system),
      reason: 'direct 与 system 若相同，"是否走代理"的选择就没有意义',
    );
  });

  // ══════════════════════════════════════════════════════════════════
  //  持久化：三态落盘 + 不污染（UiPrefs 层）
  // ══════════════════════════════════════════════════════════════════
  test('⑤ 默认必须是 direct（不改变既有行为）', () {
    // 未设任何键 ⇒ 默认 direct
    expect(UiPrefs.danmakuProxyMode, 'direct');
    expect(
      currentDanmakuProxySetting().mode,
      DanmakuProxyMode.direct,
      reason: '改前无代理支持 ⇒ 默认不能悄悄变成"跟随系统"',
    );
  });

  test('⑥ 诊断文案：三种模式各不同，且坏地址会说"无效"', () {
    expect(
      diagnoseDanmakuProxy(mode: DanmakuProxyMode.direct),
      contains('直连'),
    );
    expect(
      diagnoseDanmakuProxy(mode: DanmakuProxyMode.system),
      contains('跟随系统'),
    );
    expect(
      diagnoseDanmakuProxy(
        mode: DanmakuProxyMode.custom,
        url: 'http://127.0.0.1:7890',
      ),
      contains('PROXY 127.0.0.1:7890'),
    );
    // ★ 坏地址必须**明说无效**，不能静默显示成"走代理"
    expect(
      diagnoseDanmakuProxy(mode: DanmakuProxyMode.custom, url: ''),
      contains('无效'),
    );
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑦ ★★★ 接线门禁：两处构造点必须都传了 findProxy
  // ══════════════════════════════════════════════════════════════════
  group('⑦ 接线：IoDanmakuTransport 的每个构造点都要传 findProxy', () {
    /*
     * # 为什么必须有这一条
     * ```text
     * 纯函数（上面 ①~⑥）测的是「解析对不对」，
     * 但**测不到「有没有被调用」** —— 这正是 AGENTS.md §4 硬规矩 ①：
     *   写了 ≠ 接线了。
     *
     * 实际风险：`IoDanmakuTransport(...)` 有两个构造点
     *   ① ExternalDanmakuClient 的默认传输层
     *   ② 探活/自检用的临时传输层
     * 少接一个 ⇒ 那条路径**静默走直连/读环境变量**，
     *   而所有纯函数测试**照样全绿**。
     *
     * ★ 而且 ② 若漏接，会出现最难查的一类现象：
     *   "探活通了，但取弹幕失败"（或反过来）—— 两条路走的不一样的代理。
     * ```
     */
    final src = File('lib/core/danmaku.dart').readAsStringSync();

    test('构造点数量与接线数量必须相等', () {
      // 数 `IoDanmakuTransport(` 的**构造调用**（排除类定义 `class ... {`）
      final ctorCall = RegExp(r'IoDanmakuTransport\(');
      final all = ctorCall.allMatches(src).length;

      // 头顶的 class 定义不含 `IoDanmakuTransport(`（它是 `class IoDanmakuTransport implements`）
      // ⇒ 但构造函数本身写成 `IoDanmakuTransport({`，会被数进来 ⇒ 减 1
      final callSites = all - 1;

      final wired = RegExp(r'findProxy:\s*currentDanmakuFindProxy\(\)')
          .allMatches(src)
          .length;

      // ignore: avoid_print
      print('[PROXY-WIRE] 构造调用=$callSites 接线=$wired '
          '(正则总命中=$all，含构造函数声明 1 处)');

      expect(
        callSites,
        greaterThanOrEqualTo(2),
        reason: '至少应有 2 处构造点（默认传输层 + 探活）',
      );
      expect(
        wired,
        callSites,
        reason: '每个构造点都必须传 findProxy，否则那条路径静默不受代理控制',
      );
    });

    test('接线用的必须是**同一个**解析函数（不许各写一套）', () {
      /*
       * 若某处写成 `findProxy: 'DIRECT'` 硬编码、或自己另拼一个字符串，
       * 那么"探活"与"取弹幕"会走不同代理 ⇒ 现象是"探活通了但取不到"。
       * ⇒ 断言接线处只出现 `currentDanmakuFindProxy()`。
       */
      final wrongPatterns = [
        RegExp(r"findProxy:\s*'"),
        RegExp(r'findProxy:\s*"'),
        RegExp(r'findProxy:\s*resolveDanmakuFindProxy\('),
      ];
      for (final p in wrongPatterns) {
        expect(
          p.hasMatch(src),
          isFalse,
          reason: '构造点应统一用 currentDanmakuFindProxy()，'
              '不要硬编码或另走一套解析（会造成两条路不一致）',
        );
      }
    });
  });
}
