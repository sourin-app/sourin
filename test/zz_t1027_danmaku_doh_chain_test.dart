// ═══════════════════════════════════════════════════════════════════════
//  第 05 项独立验收门禁 —— dan-api 代理 / DoH / 探活（合入后逐条核）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件（而不是继续往 zz_t1027_danmaku_network_test 里塞）
// ```text
// 合入 origin/main 之后，第 05 项的**实现形态变了**：
//   · DoH 查询搬到 lib/core/danmaku_network_diagnostics.dart（lookupDanmakuDoh）
//   · 计划里那两个符号 `kDohProviders` / `dohQueried` 在合入版本里**不存在**
// ⇒ 计划原文的门禁（读 kDohProviders）已无法照抄。本文件按**真实代码**重写判据：
//   每一条都驱动生产函数，不读不存在的符号，也不把"计划写了"当成"已验"。
// ```
//
// # 本条sheet 逐条对应验收依据（05）
// ```text
// ① DoH 跟随用户代理设置（不是硬写 DIRECT）
// ② 多源降级链，且**显式排除 alidns**（实测它返回伪造段）
// ③ 探活预算按实例类型分档（公共 15s / 本机 2s），且公共实例 search 端点优先
// ④ 热路径文案三档：查到 / 查了连不上 / 根本没查
// ```
//
// # 断言纪律
// ```text
// 每档文案都**成对**断言：该在的词在 AND 不该在的词不在。
// 只断"什么是"会漏掉"两档其实是同一句"这一整类假绿（本仓踩过）。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/danmaku_network_diagnostics.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

/// 记录**每一个被真的发出去**的探测端点；一律 404 ⇒ 探测会把所有端点试完
class _Recorder implements DanmakuTransport {
  final paths = <String>[];
  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    paths.add(uri.path);
    return DanmakuHttpResponse(statusCode: 404, body: '{}');
  }

  @override
  void close() {}
}

/// 应答**慢**但内容合法：用来把"预算是 2s 还是 15s"变成可观测的行为差
///
/// # 为什么必须用真延时（而不是读源码/读常量）
/// ```text
/// `probe` 的预算是**运行期**的量：它由 `timeout ??= 分档` 决定，
/// 再作为 `.timeout(remaining)` 施加到真实的 `send()` future 上。
/// ⇒ 唯一能证明"分档真的生效"的观测是：
///     一个 3s 才应答的 transport，在公共实例上**必须判 online**，
///     而显式给 2s 时**必须判 offline**。
///   两条一起断，才排除"恒真"（只断 online 时，若把 3s 应答改成 0s 也会绿）。
/// ```
class _SlowRecorder implements DanmakuTransport {
  _SlowRecorder({required this.delay});

  final Duration delay;
  final paths = <String>[];

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    paths.add(uri.path);
    await Future<void>.delayed(delay);
    return DanmakuHttpResponse(statusCode: 200, body: '{"animes":[]}');
  }

  @override
  void close() {}
}

String _fn(String source, String anchor) {
  final i = source.indexOf(anchor);
  expect(i, greaterThan(0), reason: '★★ 锚点 "$anchor" 不在了 ⇒ 下面的判据会恒真，先修门禁');
  /*
   * ★★ 截函数体：先跳过**参数表**里的大括号，再按大括号配对收尾。
   * ```text
   * 第一版直接 `indexOf('{', i)`：命名参数块 `{ String? findProxy, … }`
   * 的 `{` 先被当成函数体开头，配到参数块结尾就停了
   * ⇒ body 只有签名 + 参数 ⇒ 「body 里没有 currentDanmakuFindProxy()」
   *   这类断言**全是假红**（实测就是这么红的）。
   * ```
   */
  var paren = 0;
  var bodyStart = -1;
  for (var k = i; k < source.length; k++) {
    final c = source[k];
    if (c == '(') paren++;
    if (c == ')') paren--;
    if (c == '{' && paren == 0) {
      bodyStart = k;
      break;
    }
  }
  expect(bodyStart, greaterThan(0), reason: '★★ 没找到函数体起始大括号（锚点不是函数？）');
  var depth = 0;
  for (var k = bodyStart; k < source.length; k++) {
    if (source[k] == '{') depth++;
    if (source[k] == '}') {
      depth--;
      if (depth == 0) return source.substring(i, k + 1);
    }
  }
  fail('★★ 函数体没截到（大括号不配对）');
}

void main() {
  // ══════════════════════════════════════════════════════════════════════
  //  ① + ② DoH：跟随代理 / 多源降级 / 排除 alidns
  // ══════════════════════════════════════════════════════════════════════
  group('①② DoH 降级链', () {
    test('★★★ 全部源都失败时能数出"有几家、分别是谁"：≥2 且不含 alidns', () async {
      final calls = <Uri>[];
      final result = await lookupDanmakuDoh('example.com', request: (uri) async {
        calls.add(uri);
        throw const SocketException('fixture');
      });

      expect(result, isEmpty, reason: '全失败 ⇒ 如实返回空表（不是编一个真值）');
      // ★ 这条是"单源即回归"的防线：只有一家时 calls.length == 1
      expect(calls.length, greaterThanOrEqualTo(2),
          reason: '★★★ DoH 必须是**降级链**：第一家连不上要换下一家。'
              '实测 calls=${calls.map((u) => u.host).toList()}');
      for (final u in calls) {
        expect(u.host.contains('alidns'), isFalse,
            reason: '★★★ 计划原文：dns.alidns.com 实测返回伪造段'
                '（199.59.148.89），把它当"权威真值"比不给真值更糟');
        expect(u.scheme, 'https', reason: 'DoH 必须走加密通道');
        expect(u.queryParameters['name'], 'example.com');
        expect(u.queryParameters['type'], 'A');
      }
      expect(calls.map((u) => u.host).toSet().length, calls.length,
          reason: '★ 同一个源试两次 = 预算被吃掉，等于降级链变短');
    });

    test('★★ 第一家失败、第二家成功 ⇒ 用第二家的答案（降级真的发生）', () async {
      final hosts = <String>[];
      final result = await lookupDanmakuDoh('example.com', request: (uri) async {
        hosts.add(uri.host);
        if (hosts.length == 1) throw const SocketException('first down');
        return '{"Status":0,"Answer":[{"type":1,"data":"192.0.2.7"}]}';
      });
      expect(hosts.length, 2, reason: '★ 必须真的换了源，而不是重试同一家');
      expect(result, ['192.0.2.7']);
    });

    test('★★ 返回 Status != 0 也要换下一家（"解析失败"不是"解析出空"）', () async {
      var n = 0;
      final result = await lookupDanmakuDoh('example.com', request: (_) async {
        n++;
        if (n == 1) return '{"Status":3}'; // NXDOMAIN
        return '{"Status":0,"Answer":[{"type":1,"data":"192.0.2.9"}]}';
      });
      expect(n, 2);
      expect(result, ['192.0.2.9']);
    });

    test('★★★ DoH 跟随代理设置：签名带 findProxy 且没有硬写 DIRECT', () {
      final src = File('lib/core/danmaku_network_diagnostics.dart').readAsStringSync();
      final body = _fn(src, 'Future<List<String>> lookupDanmakuDoh(');
      expect(body, contains('findProxy'),
          reason: '★★★ 计划根因一：DoH 曾硬写 DIRECT ⇒ 用户配了代理也绕过它，'
              'cloudflare 直连 TLS 握手失败 ⇒ 返回空表 ⇒ 文案降级成"没能核对真值"');
      expect(body, contains('currentDanmakuFindProxy()'),
          reason: '★ 默认必须跟随当前弹幕代理设置（同一真源）');
      expect(
        RegExp(r"findProxy\s*=\s*\(\s*\(\s*Uri\s+_\s*\)\s*=>\s*'DIRECT'")
            .hasMatch(body),
        isFalse,
        reason: '★★★ 硬写 DIRECT 的写法必须零命中（这是本项的核心回归点）',
      );
    });

    test('★★ 明文 IP 不做 DoH（没有"权威真值"可言）', () async {
      var called = 0;
      final r = await lookupDanmakuDoh('192.0.2.1', request: (_) async {
        called++;
        return '{}';
      });
      expect(r, isEmpty);
      expect(called, 0, reason: '★ 给 IP 再问一次 A 记录是浪费，也会误导用户');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  //  ③ 探活预算分档 + search 优先（两个方向都断）
  // ══════════════════════════════════════════════════════════════════════
  group('③ 探活预算与端点顺序', () {
    test('★★★ 预算按实例类型分档：公共 15s / 本机 2s', () {
      /*
       * ★★★ 2026-10-25（第 05 项复核修复 C1）：`>= 15` 是**弱断言**
       * ```text
       * 改前写 `inSeconds >= 15` ⇒ 有人把它改成 60s 也绿，
       *   而 60s 会让用户点"测试连接"时白等一分钟。
       * ⇒ 判据是"**真为 15s**"，就必须逐字相等（`Duration` 直接比）。
       * ```
       */
      expect(DanmakuLocalService.publicProbeBudget,
          const Duration(seconds: 15),
          reason: '★★★ 计划实测：12s 预算是 online=false（12001ms 正好撞线），'
              '30s 才 online=true（10745ms）⇒ 定为 15s；'
              '这里必须**逐字相等**（`>= 15` 会让 60s 也过，用户白等）');
      expect(DanmakuLocalService.localProbeBudget.inSeconds, 2,
          reason: '★ 本机/自建是毫秒级：放宽它只会让用户白等');
      expect(DanmakuLocalService.publicProbeBudget,
          greaterThan(DanmakuLocalService.localProbeBudget));

      final src = File('lib/core/danmaku.dart').readAsStringSync();
      final probeBody = _fn(src, 'static Future<DanmakuLocalStatus> probe(');
      expect(probeBody, contains('publicProbeBudget'),
          reason: '★ 判据必须读同一个常量（改常量窗口跟着变），不是写死一个字面量');
      expect(probeBody, contains('localProbeBudget'));
      /*
       * ★ 下面两条是**签名形状**的辅助守卫（真正判分档生效的是 ③ 的行为用例）。
       *   它们防的是"可空被改回写死"，不承担"分档真的生效"这个结论。
       */
      final describeBody = _fn(src, 'static Future<DanmakuLocalStatus> describe(');
      expect(describeBody, contains('Duration? timeout'),
          reason: '★★★ `describe` 的 timeout 必须可空：写死默认 2s 并原样透传'
              '会**顶掉** probe 的分档，而生产两处调用都用默认值 ⇒ 公共实例永远 2s');
      final selectBody = _fn(src, 'static Future<DanmakuSourceKind> select(');
      expect(selectBody, contains('Duration? timeout'),
          reason: '★★★ 修复 C3：`select` 曾经写死 `Duration(seconds: 2)` 并无条件'
              '透传给 probe ⇒ 公共实例的分档在同一层被顶掉（与 describe 同一个病）');
    });

    test('★★★ 公共实例：search 端点排在最前（唯一活的端点）', () async {
      final t = _Recorder();
      final ep = DanmakuEndpoint.tryParse(kDanmakuPublicInstances.first.baseUrl,
          token: kDanmakuPublicInstances.first.token);
      await DanmakuLocalService.probe(transport: t, endpoint: ep);
      expect(t.paths.length, 1,
          reason: '★ 公共实例只打一个端点就该结束（剩下的预算不该浪费在已知 404 上）；'
              '实测发过：${t.paths}');
      expect(t.paths.single, endsWith(DanmakuLocalService.searchProbePath));
    });

    test('★★★ 反方向：本机 2080 仍 version → config（顺序不许跟着翻）', () async {
      final t = _Recorder();
      await DanmakuLocalService.probe(transport: t);
      expect(t.paths,
          <String>[DanmakuLocalService.versionPath, DanmakuLocalService.configPath],
          reason: '★★★ 只断公共实例那一个方向，会让"把全局顺序都翻过来"也过；'
              '本机这两个端点是真活的、且比 search 快得多，必须保持原序');
    });

    test('★★ 反方向：自建后端（非公共）仍是 version → config → search 尾巴', () async {
      final t = _Recorder();
      final ep = DanmakuEndpoint.tryParse('http://192.0.2.55:9321');
      await DanmakuLocalService.probe(transport: t, endpoint: ep);
      expect(t.paths.first, endsWith(DanmakuLocalService.versionPath),
          reason: '★ 自建服务 versionPath 就是活的（danmu_api 才是 404→config）');
      expect(t.paths,
          <String>[
            DanmakuLocalService.versionPath,
            DanmakuLocalService.configPath,
            DanmakuLocalService.searchProbePath,
          ],
          reason: '★★★ 计划原文：顺序调换**只对公共实例生效**。'
              '自建后端保持 version→config→search，search 只做最后的退路；'
              '若这条红成 [search, version, config]，说明"全局都改成 search 优先"了');
    });

    // ────────────────────────────────────────────────────────────────
    //  ★★★ 修复 C1/C2/C3：**行为**证明分档真的生效（不只读常量/读源码）
    // ────────────────────────────────────────────────────────────────
    DanmakuEndpoint publicEndpoint() {
      final ep = DanmakuEndpoint.tryParse(
        kDanmakuPublicInstances.first.baseUrl,
        token: kDanmakuPublicInstances.first.token,
      );
      expect(ep, isNotNull, reason: '★ 内置公共实例必须能被解析（否则下面的用例全恒真）');
      return ep!;
    }

    test('★★★ 行为 C1：公共实例 3s 才应答 ⇒ probe 必须判 online；显式 2s ⇒ 必须 offline',
        () async {
      final ep = publicEndpoint();

      // ① 默认（= 分档到 15s）⇒ 3s 的应答必须等得到
      final slowOk = _SlowRecorder(delay: const Duration(seconds: 3));
      final online = await DanmakuLocalService.probe(
        transport: slowOk,
        endpoint: ep,
      );
      expect(online.online, isTrue,
          reason: '★★★ 公共实例 3s 应答被判离线 ⇒ 15s 分档没生效'
              '（被 2s 顶掉了）。paths=${slowOk.paths}');
      expect(online.isPublicInstance, isTrue);

      // ② 显式 2s ⇒ 必须超时判离线（否则上面那条是恒真，分不出档）
      final slowFail = _SlowRecorder(delay: const Duration(seconds: 3));
      final offline = await DanmakuLocalService.probe(
        transport: slowFail,
        endpoint: ep,
        timeout: const Duration(seconds: 2),
      );
      expect(offline.online, isFalse,
          reason: '★ 显式 2s 竟然等到了 3s 的应答 ⇒ 预算根本没被施加，'
              '那 C1 的正向用例证明不了任何东西');
    });

    test('★★★ 行为 C2：describe() 不许把分档顶掉（3s 应答仍 online）', () async {
      final ep = publicEndpoint();
      final st = await DanmakuLocalService.describe(
        transport: _SlowRecorder(delay: const Duration(seconds: 3)),
        endpoint: ep,
      );
      expect(st.online, isTrue,
          reason: '★★★ `describe` 若又写死 `Duration(seconds: 2)` 并原样透传，'
              '这里必然是 offline —— 这正是合入版本被修掉的那个 bug');
    });

    test('★★★ 行为 C3：select() 也不许写死 2s（3s 应答 ⇒ custom 而不是 official）',
        () async {
      final ep = publicEndpoint();

      final kind = await DanmakuSourceSelector.select(
        transport: _SlowRecorder(delay: const Duration(seconds: 3)),
        endpoint: ep,
      );
      expect(kind, DanmakuSourceKind.custom,
          reason: '★★★ `select` 若仍 `Duration timeout = 2s` 并无条件透传 ⇒ '
              '3s 应答被判离线 ⇒ 退到 official（用户配的实例明明能通）');

      // 反向：显式 2s ⇒ 真的退到 official（证明它在用预算，不是恒 custom）
      final kind2 = await DanmakuSourceSelector.select(
        transport: _SlowRecorder(delay: const Duration(seconds: 3)),
        endpoint: ep,
        timeout: const Duration(seconds: 2),
      );
      expect(kind2, DanmakuSourceKind.official,
          reason: '★ 显式 2s 也必须真的生效（否则 select 把 timeout 丢了）');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  //  ④ 热路径文案三档
  // ══════════════════════════════════════════════════════════════════════
  group('④ 三档文案（查到 / 查了连不上 / 根本没查）', () {
    Future<DanmakuProbeReport> queried(List<String> truth) =>
        DanmakuProbeReport.hijackReportWithTruth(
          url: 'https://danmu-api-kappa.vercel.app',
          localAddresses: const <String>['74.86.17.48'],
          host: 'danmu-api-kappa.vercel.app',
          lookup: (_) async => truth,
        );

    test('★★★ 查到：真值与本机值同时出现，且说破"不是一个东西"', () async {
      final r = await queried(<String>['216.198.79.3', '64.29.17.3']);
      expect(r.failure, DanmakuProbeFailure.dnsHijacked);
      expect(r.detail, contains('74.86.17.48'));
      expect(r.detail, contains('216.198.79.3'));
      expect(r.detail, contains('不是一个东西'));
      // ★ 反证：这一档**不该**出现"没查"或"连不上"的措辞
      expect(r.detail, isNot(contains('不做额外查询')));
      expect(r.detail, isNot(contains('全都连不上')));
    });

    test('★★★ 查了连不上：说"问过三个源都连不上"，不说"没查"', () async {
      final r = await queried(const <String>[]);
      expect(r.failure, DanmakuProbeFailure.dnsHijacked);
      expect(r.detail, contains('问过三个加密 DNS 源'));
      expect(r.detail, contains('没能核对'));
      // ★ 反证：不许退化成"根本没查"（那会把网络问题说成"我们没做"，
      //   用户就不会去开代理了）
      expect(r.detail, isNot(contains('不做额外查询')),
          reason: '★★★ 这一档是真查过且失败了 —— 与"没查"混成一句就是本轮要修的病');
      // ★ 也不许凭空出现真值
      expect(r.detail, isNot(contains('权威 DNS（加密查询）真值')));
    });

    test('★★★ 根本没查（热路径）：明说这条路径不做额外查询，并指向测试连接', () async {
      final hot = DanmakuProbeReport.fromDanmakuException(
        DanmakuException('连不上弹幕服务', resolvedAddress: '74.86.17.48'),
      );
      expect(hot.failure, DanmakuProbeFailure.dnsHijacked);
      expect(hot.detail, contains('不做额外查询'));
      expect(hot.detail, contains('测试连接'),
          reason: '★ 必须给出**可达**的下一步：设置页那个按钮真能拿到真值（见 ⑤）');
      // ★ 反证：不许把"没查"说成"查了被拦"
      expect(hot.detail, isNot(contains('加密查询也可能被拦')),
          reason: '★★★ 改前就是这句 —— 它替用户断言了一次**根本没发生**的查询，'
              '把排查方向指向网络');
      expect(hot.detail, isNot(contains('全都连不上')));
    });

    test('★★★ 纯 IP 直连（无域名）⇒ 不许假装查过', () async {
      final r = await DanmakuProbeReport.hijackReportWithTruth(
        url: 'http://192.0.2.9:9321',
        localAddresses: const <String>['74.86.17.48'],
        host: '',
        lookup: (_) async => const <String>['216.198.79.3'],
      );
      expect(r.detail, contains('不做额外查询'),
          reason: '★ host 为空时没有"权威真值"可对照，不能编');
      expect(r.detail, isNot(contains('216.198.79.3')));
    });

    test('★★ lookup 自己抛异常 ⇒ 归到"查了连不上"，不许当"查到了"', () async {
      final r = await DanmakuProbeReport.hijackReportWithTruth(
        url: 'https://x',
        localAddresses: const <String>['74.86.17.48'],
        host: 'x.example',
        lookup: (_) async => throw const SocketException('doh down'),
      );
      expect(r.detail, contains('问过三个加密 DNS 源'));
      expect(r.detail, isNot(contains('不是一个东西')));
    });

    test('★★ 三档的 detail **两两不同**（防止同一句话被复用）', () async {
      final found = await queried(const <String>['216.198.79.3']);
      final empty = await queried(const <String>[]);
      final none = DanmakuProbeReport.forHijackedDns(
        url: 'https://x',
        localAddresses: const <String>['74.86.17.48'],
      );
      expect({found.detail, empty.detail, none.detail}.length, 3,
          reason: '★★ 三档必须是三句话');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  //  ⑥ 修复 A：真值**必须与本机比较**（overlap / different / unavailable）
  // ══════════════════════════════════════════════════════════════════════
  //
  // # 为什么单独一组（这是复核查出的真缺陷）
  // ```text
  // 改前 `forHijackedDns` 拿到 dohAddresses 就无条件套
  //   "同一个域名，你这台机器拿到的和真实地址「不是一个东西」"，
  //   **从不与 localAddresses 比较**。
  // 反例：lookup 返回与本机完全相同的地址 ⇒ 文案仍说"不是一个东西"
  //   ⇒ 把用户推向"改 DNS"，而 DNS 根本没坏。
  // ⇒ 现在 overlap / different / unavailable 各自一档，且**成对断言**
  //    （该在的词在 AND 不该在的词不在），否则"两档是同一句"会假绿。
  // ```
  group('⑥ 修复 A：真值与本机的比较三态（纯函数、零网络）', () {
    Future<DanmakuProbeReport> withTruth(
      List<String> truth, {
      List<String> local = const <String>['74.86.17.48'],
    }) =>
        DanmakuProbeReport.hijackReportWithTruth(
          url: 'https://danmu-api-kappa.vercel.app',
          localAddresses: local,
          host: 'danmu-api-kappa.vercel.app',
          lookup: (_) async => truth,
        );

    test('★★★ overlap：真值里**含**本机地址 ⇒ 不是劫持，明说"问题不在 DNS"', () async {
      final r = await withTruth(const <String>['74.86.17.48', '216.198.79.3']);
      expect(r.failure, DanmakuProbeFailure.dnsConsistent,
          reason: '★★★ 真值与本机有交集却被判成 ${r.failure} ⇒ '
              '这正是"把一致说成被劫持"的原始缺陷');
      // 该在的词
      expect(r.detail, contains('有交集'));
      expect(r.detail, contains('问题不在 DNS'));
      expect(r.remedy, contains('别去改 DNS'));
      // ★ 成对反证：不许再说"不一致"，也不许再教用户换 DNS
      expect(r.detail, isNot(contains('不是一个东西')),
          reason: '★★★ 两边地址相同还说"不是一个东西" ⇒ 用户会去改一个没坏的 DNS');
      expect(r.remedy, isNot(contains('DNS 换成可信的')));
    });

    test('★★★ different：真值与本机**不相交** ⇒ 仍然是劫持（别把真劫持放过）', () async {
      final r = await withTruth(const <String>['216.198.79.3', '64.29.17.3']);
      expect(r.failure, DanmakuProbeFailure.dnsHijacked,
          reason: '★ 修 A 不能把真劫持一起放过');
      expect(r.detail, contains('不是一个东西'));
      expect(r.remedy, contains('DNS 换成可信的'));
      expect(r.detail, isNot(contains('问题不在 DNS')));
    });

    test('★★ unavailable：有真值但本机没答案 ⇒ 如实说"无法比较"，不猜', () async {
      final r = await withTruth(
        const <String>['216.198.79.3'],
        local: const <String>[],
      );
      expect(r.failure, DanmakuProbeFailure.dnsUnverifiable,
          reason: '★★ 拿不到本机答案时既不能判劫持、也不能说没事 ⇒ 只能如实说比不了');
      expect(r.detail, contains('没有可比较'));
      expect(r.detail, isNot(contains('不是一个东西')));
      expect(r.detail, isNot(contains('有交集')));
      expect(r.remedy, isNot(contains('DNS 换成可信的')));
    });

    test('★★★ 三档 detail 两两不同（防止同一句话被复用）', () async {
      final overlap =
          await withTruth(const <String>['74.86.17.48', '216.198.79.3']);
      final different = await withTruth(const <String>['216.198.79.3']);
      final unavailable = await withTruth(
        const <String>['216.198.79.3'],
        local: const <String>[],
      );
      expect(
        {overlap.detail, different.detail, unavailable.detail}.length,
        3,
        reason: '★★ 三档必须是三句话（否则用户分不出"一致"和"被劫持"）',
      );
      expect(
        {overlap.failure, different.failure, unavailable.failure}.length,
        3,
        reason: '★ 失败档也必须分得开（标题/颜色按 failure 分叉）',
      );
    });

    test('★★★ 判据同源：compareDanmakuDns 的三态与三档一一对应', () {
      /*
       * 防止"两头各写一套比较"。这条同时证明 `compareDanmakuDns`
       * 从"零生产调用点"变成了唯一判据（修复 A 的落地证据）。
       */
      expect(compareDanmakuDns(<String>['1.2.3.4'], <String>['1.2.3.4']),
          DanmakuDnsComparison.overlap);
      expect(compareDanmakuDns(<String>['1.2.3.4'], <String>['5.6.7.8']),
          DanmakuDnsComparison.different);
      expect(compareDanmakuDns(<String>['1.2.3.4'], const <String>[]),
          DanmakuDnsComparison.unavailable);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  //  ⑤ 接线：三档里的"查了"两档必须真有生产调用点
  // ══════════════════════════════════════════════════════════════════════
  group('⑤ 生产接线（不是只在测试里能构造出来）', () {
    test('★★★ 设置页 _diagnose 真的调用了真值对照，且注入点存在', () {
      final src = File('lib/ui/settings/danmaku_source_page.dart')
          .readAsStringSync();
      final body = _fn(src, 'Future<void> _diagnose(');
      expect(body, contains('hijackReportWithTruth'),
          reason: '★★★ 合入版本里 `lookupDanmakuDoh` **一个生产调用点都没有**'
              '⇒ 用户永远看不到"权威真值"那一档，设置页那句"点测试连接可以核对"是空头承诺');
      expect(body, contains('looksForged'),
          reason: '★ 只有判了"解析到伪造段"才去查真值（不是每次失败都查）');
      expect(body, contains('widget.dohOverride'),
          reason: '★★ 注入口必须透传（否则门禁只能靠真实网络验证）');
      expect(src, contains('this.dohOverride'),
          reason: '★ 注入口必须真的在构造函数里');
    });

    test('★★★ 热路径仍然零网络（fromDanmakuException 不许查 DoH）', () {
      final src = File('lib/ui/widgets/danmaku_settings_dialog.dart')
          .readAsStringSync();
      final body = _fn(src, 'static DanmakuProbeReport fromDanmakuException(');
      expect(body, isNot(contains('dohLookup')));
      expect(body, isNot(contains('hijackReportWithTruth')));
      expect(body, isNot(contains('HttpClient')));
      // ★ 阳性对照：它必须真的走到 forHijackedDns（否则上面三条是恒真）
      expect(body, contains('forHijackedDns'));
    });
  });
}
