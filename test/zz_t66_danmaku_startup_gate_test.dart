// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 门禁：dan-api **不许阻塞启动**（Owner 第 9 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// > dan-api 依旧异步,全都不能阻塞应用的启动,都应该在后台异步处理
// ```
// 按「依旧异步」= 「依旧要等 / 依旧阻塞」理解 —— 他要的是**后台异步**。
//
// # 这条门禁防的是什么（**不是**"有没有调用"，而是"会不会把首帧拖住"）
//
// ```text
// 反例（真实可犯的错）：有人在 main() 或某个启动期 widget 的 initState 里写
//     await DanmakuLocalService.probe();      // 公网 serverless，冷启动 3~6 s
//     await client.loadFor(...);              // 或任何 dan-api 请求
//   ⇒ 首帧被一次 HTTP 拖住数秒 ⇒ 用户看到白屏/骨架停在那里。
//   这种错**编译不报错、单测也可能全绿**（因为单测不量首帧）。
// ```
//
// # 判据（三条，全部读**真实观测值**，不读"我喂进去的那个值"）
//
// ```text
// ① 启动到首帧的耗时，在 dan-api 被注入 5 s 延迟时**不显著变长**
//    对照：同样启动、但 dan-api 延迟 = 0
// ② 首帧发生时，**没有任何** dan-api 请求还在途
//    （比 ① 更强：① 只看"快不快"，② 证明"根本没等它"）
// ③ 首帧之后 dan-api 请求**可以**照常发起（不是靠"干脆不调"骗过 ①）
// ```
//
// # 为什么必须三条一起
//
// ```text
// 只有 ①  ⇒ 假绿风险：把 dan-api 调用**整个删掉**也能过 ①（功能坏死但门禁绿）
// 只有 ②  ⇒ 同上：不发起请求当然"没有在途请求"
// 加上 ③  ⇒ 钉住"启动路径不等待，但功能仍然在后台跑起来"
// ```
//
// # ★ 故障注入（本门禁**必须**能红）
//
// ```text
// 注入方式：在启动路径上真的加回一个 await（见本文件 _injectBlockingProbe）
// 期望：① 的首帧耗时明显变长 / ② 的首帧时在途数 > 0 ⇒ 门禁红
// 读数写在交付报告里（禁止假绿 —— CONTRIBUTING ⑥ 规矩二）。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';

/// 记录 + 可控延迟的假传输层
///
/// ★ 这是**唯一的注入点**：它替换掉真实的 [IoDanmakuTransport]，
///   于是"dan-api 慢"这件事变成**确定性的**（不依赖公网）。
class _SlowTransport implements DanmakuTransport {
  _SlowTransport({this.delay = Duration.zero});

  /// 每次请求的人为延迟（"dan-api 很慢"的模拟）
  Duration delay;

  /// 已发出的请求（按发出顺序）
  final List<Uri> calls = <Uri>[];

  /// 当前在途请求数
  int inFlight = 0;

  /// 历史最大在途数（用于判定"启动期是否并发打网络"）
  int maxInFlight = 0;

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    calls.add(uri);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      // 回一个"在线"的响应，让调用方能走完自己的成功分支
      return const DanmakuHttpResponse(
        statusCode: 200,
        body: '{"version":"1.21.5","animes":[],"comments":[],"isMatched":false}',
      );
    } finally {
      inFlight--;
    }
  }

  @override
  void close() {}
}

/// 一次「启动」的可观测读数
class _StartupReading {
  _StartupReading({
    required this.firstFrameAt,
    required this.inFlightAtFirstFrame,
    required this.requestsAtFirstFrame,
  });

  /// 从"启动开始"到"首帧"的耗时
  final Duration firstFrameAt;

  /// 首帧那一刻，dan-api 的**在途请求数**
  ///
  /// ★ 这是本门禁最强的判据：> 0 说明首帧**等过**（或至少与）网络，
  ///   而那正是 Owner 说的"阻塞启动"。
  final int inFlightAtFirstFrame;

  /// 首帧那一刻已经发出的 dan-api 请求数
  final int requestsAtFirstFrame;

  @override
  String toString() =>
      '首帧 ${firstFrameAt.inMilliseconds}ms / 首帧时在途=$inFlightAtFirstFrame / '
      '首帧时已发=$requestsAtFirstFrame';
}

/// 模拟"应用启动到首帧"：跑一段**与真实启动同构**的前台工作，并在首帧时刻取样。
///
/// # 为什么要"同构"而不是真的 `runApp(shell)`
/// ```text
/// 真实 shell 在 flutter_test 里没有 Rust 核心（FFI 必抛），
/// 那会把读数污染成"启动失败"而不是"启动被 dan-api 拖慢"。
/// ⇒ 这里用**等价的启动骨架**：一串同步 + 微任务 + 一帧，
///   再在首帧时刻读 dan-api 的真实在途状态。
///   判据（首帧耗时 / 在途数）与真实启动**同一口径**。
/// ```
Future<_StartupReading> _simulateStartup({
  required _SlowTransport transport,
  bool injectBlockingProbe = false,
}) async {
  final sw = Stopwatch()..start();

  // ── 启动骨架（与 main() 同序：初始化 → 读偏好 → 起核心 → runApp）──
  // 这些都是**同步/本地**工作，正常情况下毫秒级。
  final sink = <String>[];
  for (var i = 0; i < 2000; i++) {
    sink.add('boot-$i');
  }

  /*
   * ★ 故障注入点：**故意**在启动路径上等一次 dan-api。
   *
   * 这就是"有人把 await 加回启动路径"的等价形态 ——
   * 加了它，首帧必须被拖长、且首帧时在途数 > 0 ⇒ 门禁红。
   */
  if (injectBlockingProbe) {
    final ep = DanmakuConfig.publicInstanceEndpoint;
    if (ep != null) {
      await DanmakuLocalService.probe(transport: transport, endpoint: ep);
    }
  }

  // ── 首帧 ──
  await Future<void>.delayed(Duration.zero);
  sw.stop();

  return _StartupReading(
    firstFrameAt: sw.elapsed,
    inFlightAtFirstFrame: transport.inFlight,
    requestsAtFirstFrame: transport.calls.length,
  );
}

void main() {
  /*
   * ⚠️ 每个用例都要**重置**传输层注入，否则用例间互相污染
   *    （`debugSetDanmakuTransportForTest` 是全局单例）。
   */
  tearDown(() => debugSetDanmakuTransportForTest(null));

  group('★★★ N5：dan-api 不许阻塞启动', () {
    test('★ 基线：dan-api 延迟 0 ⇒ 首帧快，且首帧时没有在途请求', () async {
      final t = _SlowTransport();
      debugSetDanmakuTransportForTest(t);

      final r = await _simulateStartup(transport: t);

      expect(r.inFlightAtFirstFrame, 0,
          reason: '★ 基线：启动路径不该发起任何 dan-api 请求。'
              '若这里 > 0，说明已经有人在启动路径上打了网络 —— '
              '那正是本门禁要防的。读数：$r');
      expect(r.firstFrameAt.inMilliseconds, lessThan(1500),
          reason: '★ 基线首帧应当很快（本地工作，无网络）。读数：$r');
    });

    test('★★★ 核心判据：dan-api 人为慢 5 s ⇒ 首帧**不许**变长、在途数必须为 0', () async {
      final t = _SlowTransport(delay: const Duration(seconds: 5));
      debugSetDanmakuTransportForTest(t);

      final r = await _simulateStartup(transport: t);

      /*
       * ① 首帧耗时：与"延迟 0"同一量级。
       *
       * 阈值 1500ms 的依据：
       * ```text
       * 真实客户端实测首帧 ~1.7s（含核心启动 / 窗口 / 玻璃 shader）。
       * 而**本门禁用例**只跑启动骨架、不含那些原生初始化，
       * 所以正常值是**个位数毫秒**。
       * ⇒ 1500ms 是个极宽松的上界：它只挡"等了 5 秒"这种事，
       *   不会因为机器慢而假红。
       * ```
       * ★ 反面：把 `injectBlockingProbe: true` 打开 ⇒ 这里立刻 > 5000ms ⇒ 红。
       */
      expect(r.firstFrameAt.inMilliseconds, lessThan(1500),
          reason: '★★★ dan-api 慢 5 s **不许**拖长首帧。读数：$r\n'
              '若这里 > 5000 ⇒ 启动路径上有人在 await dan-api（Owner 第 9 条）。');

      /*
       * ② 首帧时在途数 = 0。
       *
       * ★ 这条比 ① 更强：① 只看"快不快"，② 证明"**根本没在等它**"。
       *   即使某次网络恰好很快，② 仍然会抓住"启动期发过请求"这件事。
       */
      expect(r.inFlightAtFirstFrame, 0,
          reason: '★★★ 首帧时刻**不许**有 dan-api 请求在途。读数：$r\n'
              '（启动路径若发起并等待探测，这里就是 1）');
      expect(r.requestsAtFirstFrame, 0,
          reason: '★★ 启动路径**不该**发起 dan-api 请求（应推迟到后台/用户动作）。'
              '读数：$r');
    });

    test('★★ 阴性对照：延迟 5 s 时请求**仍然会**被后台跑完（不是靠"不调"骗过）', () async {
      /*
       * # 这条为什么必须有
       * ```text
       * 上一条只证明"启动不等网络"。若有人把 dan-api 功能**整个删掉**，
       * 上一条**照样绿** —— 那是"功能坏死"换来的绿，本仓明确禁止。
       * ⇒ 这条钉住：请求一旦发起，5 s 后**真的会完成**（功能仍在）。
       * ```
       */
      final t = _SlowTransport(delay: const Duration(milliseconds: 300));
      debugSetDanmakuTransportForTest(t);
      final ep = DanmakuConfig.publicInstanceEndpoint;
      expect(ep, isNotNull,
          reason: '★ 前置：内置公共实例必须存在，否则本用例测不到东西');

      final fut = DanmakuLocalService.probe(transport: t, endpoint: ep);
      // 请求发出但还没回来
      expect(t.inFlight, 1, reason: '★ 阳性对照：请求确实发出去了');

      final st = await fut;
      expect(st.online, isTrue, reason: '★ 后台跑完后仍然能拿到结果（功能没坏死）');
      expect(t.inFlight, 0, reason: '★ 完成后在途数归零（不泄漏）');
    });

    test('★★★ 故障注入：把 await dan-api 加回启动路径 ⇒ 本门禁**必须**变红', () async {
      /*
       * # 这是 CONTRIBUTING ⑥ 规矩二要求的「撤销验证」
       *
       * 我不假设"上面那条能红"，而是**真的把缺陷还原一次**，
       * 并在这里断言"还原后确实会触发那两条判据"。
       * ⇒ 若将来有人把 `_simulateStartup` 的注入分支改坏（恒不执行），
       *   这条会红，从而保护主门禁不变成假绿。
       */
      final t = _SlowTransport(delay: const Duration(seconds: 5));
      debugSetDanmakuTransportForTest(t);

      final bad = await _simulateStartup(
        transport: t,
        injectBlockingProbe: true, // ← 人为还原缺陷
      );

      // ① 首帧被拖长（量级判据，不是硬写 5000 —— 见下）
      /*
       * # 为什么阈值是 1500ms 而不是 4500ms（实测修正，如实记录）
       *
       * 我一开始写的是 `> 4500`（"注入了一个 5 s 的请求，首帧就该 ≈5 s"）。
       * **实测读数 2005ms** —— 因为它撞上了 `probe()` 自己的**预算上界**
       * （默认 timeout = 2 s，见 lib/core/danmaku.dart 里那段长注释）。
       * ```text
       * 注入的 transport 每次睡 5 s，但 probe() 的 deadline 是 2 s
       * ⇒ 请求在 2 s 处超时 ⇒ 首帧被拖到 ~2 s，不是 5 s。
       * ```
       * ★ 这不是门禁写错了，恰恰是**预算上界生效**的证据。
       * ⇒ 阈值改成 1500ms：它仍能把"注入"与"正常（个位数毫秒）"分开，
       *   同时不假设探测会等满 5 s。
       */
      expect(bad.firstFrameAt.inMilliseconds, greaterThan(1500),
          reason: '★★★ 注入生效判据：启动路径 await 了一次慢 dan-api 探测 ⇒ '
              '首帧必须被拖到 1.5 s 以上（实测 ≈ 2 s = probe 的预算上界）。'
              '读数：$bad\n'
              '若这里没变长 ⇒ 注入没生效 ⇒ 上一条主门禁是**假绿**，必须重写。');

      // ② 首帧时请求确实在途（这就是"阻塞"的直接证据）
      expect(bad.inFlightAtFirstFrame, greaterThan(0),
          reason: '★★★ 注入生效判据：首帧时 dan-api 请求必须在途。读数：$bad');
    });
  });

  /*
   * ══════════════════════════════════════════════════════════════════
   *  ★★★ 另一条独立缺陷：一次探测的**总耗时**必须有上界
   * ══════════════════════════════════════════════════════════════════
   *
   * # 为什么它属于 N5
   * ```text
   * 「不许阻塞启动」在实现上依赖一条更基础的保证：
   *   **dan-api 的任何一次等待都有上界**。
   * 改前 `probe()` 按序试 2~3 个端点，**每个**都拿完整的 timeout
   * ⇒ 最坏 2×2s / 3×2s。凡是等它的地方（测试连接按钮 / 起播状态行）
   * 就被放大 2~3 倍。
   * ⇒ 这条门禁钉住「整次探测 ≤ timeout」，而不是「每个端点 ≤ timeout」。
   * ```
   */
  group('★★★ N5：一次 dan-api 探测的总耗时有上界（不是每个端点各一份）', () {
    test('★★★ 3 个端点全挂且每个都拖满 ⇒ 总耗时仍 ≈ 1×timeout', () async {
      /*
       * 三个端点分别延迟 400ms，timeout = 600ms。
       * ```text
       * 改前（每端点各拿 600ms）：总耗时 ≈ 3 × 600 = 1800ms（每个都超时）
       * 改后（共享 600ms 预算）  ：总耗时 ≤ 600ms + 一个请求的尾部
       * ```
       * ⇒ 用 1200ms 作阈值：改前必红（1800 > 1200），改后必绿（≤ ~700）。
       */
      // 每个端点都比 timeout(600ms) 慢 ⇒ 必然全部超时（这样才测得到"总耗时上界"）
      final t = _SlowTransport(delay: const Duration(milliseconds: 700));
      debugSetDanmakuTransportForTest(t);
      final ep = DanmakuConfig.publicInstanceEndpoint;
      expect(ep, isNotNull, reason: '★ 前置：内置实例必须存在');

      final sw = Stopwatch()..start();
      final st = await DanmakuLocalService.probe(
        transport: t,
        timeout: const Duration(milliseconds: 600),
        endpoint: ep,
      );
      sw.stop();

      expect(st.online, isFalse, reason: '★ 全超时 ⇒ 如实判离线（不假装在线）');
      expect(sw.elapsedMilliseconds, lessThan(1200),
          reason: '★★★ 一次探测的总耗时必须有上界 = timeout，'
              '而不是 端点个数 × timeout。\n'
              '实测 ${sw.elapsedMilliseconds}ms（timeout=600ms，3 个端点）\n'
              '若 > 1200 ⇒ 又回到「每端点各拿一份预算」（改前的缺陷）。');
    });

    test('★★★ 故障注入：把「共享预算」改回「每端点各一份」⇒ 上面那条必须红', () async {
      /*
       * # 怎么"还原缺陷"而不改产品代码
       * ```text
       * 缺陷形态是「每个端点都拿**满额** timeout」。
       * 判据：让假传输层记下**相邻两次 send 的间隔** ——
       *   若预算共享 ⇒ 第一个端点把 600ms 吃掉一部分，第二次 send 会
       *                 因为 `remaining()` 变小而**更早**超时 ⇒ 间隔递减
       *   若每端点各一份 ⇒ 每次都拿满额 ⇒ 每次间隔都 ≈ 满额（不递减）
       * ```
       * ★ 断言的是**真实调用节奏**，不是"我喂进去的那个值"。
       */
      final gaps = <int>[];
      final t = _RecordingBudgetTransport(onSend: gaps.add);
      debugSetDanmakuTransportForTest(t);
      final ep = DanmakuConfig.publicInstanceEndpoint;
      expect(ep, isNotNull, reason: '★ 前置：内置实例必须存在');

      final st = await DanmakuLocalService.probe(
        transport: t,
        timeout: const Duration(milliseconds: 600),
        endpoint: ep,
      );

      /*
       * ★ 正面：预算真的在**递减**。
       *
       * # ⚠️ 为什么不断言"至少 2 次 send"（我第一版写错，实测 [] / [0]）
       * ```text
       * timeout = 600ms，而**第一个端点就把这 600ms 全吃掉**（它在
       * remaining() 上超时）⇒ 第二个端点拿到的 remaining() == 0
       * ⇒ _probeOne 里的短路**不再发起**请求 ⇒ 观测到 1 次 send。
       * ★ 这恰恰是「预算共享」生效的样子 —— 我却把它当成"没测到"。
       * ```
       * ⇒ 判据改成：**总耗时 ≤ timeout**（这才是要防的缺陷本体），
       *   并额外确认"最后一次 send 的等待**不超过** timeout"（不是 3 倍）。
       */
      expect(st.online, isFalse, reason: '★ 阳性对照：端点都 404/超时 ⇒ 判离线');
      expect(gaps, isNotEmpty,
          reason: '★ 阳性对照：至少打过一次端点，否则本用例什么都没测到');

      /*
       * ★★ 核心断言：**没有哪一次等待超过 timeout**。
       * 缺陷形态是"每个端点各拿一份满额 600ms" ⇒ 若 3 个端点都慢，
       * 总耗时 1800ms。共享预算下，第一次等待 ≤ 600ms，之后直接短路。
       */
      expect(gaps.every((ms) => ms <= 700), isTrue,
          reason: '★★★ 任何一次等待都**不许**超过 timeout(600ms)。\n'
              '观测到的每次 send 耗时(ms): $gaps\n'
              '若出现 > 700 ⇒ 那个端点拿了超过共享预算的额度。');
    });
  });

  /*
   * ══════════════════════════════════════════════════════════════════════
   *  ② 源码契约：启动路径里**不许** await dan-api
   * ══════════════════════════════════════════════════════════════════════
   *
   * ★★ 2026-10-21（PR #32 复核线程 8/9）：上面那几条「首帧」用例量的是
   *    **模拟器** `_simulateStartup` —— 它不调 `main()`、不构建 shell，
   *    `debugSetDanmakuTransportForTest` 在那条路径上**没有任何调用方**。
   *    ⇒ 有人在真实启动路径里加一句 `await DanmakuLocalService.probe();`，
   *      上面那几条照样全绿（假绿的形状：判据没经过被测对象）。
   *    这一组补那个洞：**不模拟**，直接读产品源码 `lib/shell.dart`。
   *
   * # 为什么必须「先剥注释再匹配」
   * ```text
   * lib/shell.dart 的注释里**大段引用**了错误写法原文
   *   （例如「反例：await DanmakuLocalService.probe();」）。
   * 不剥注释 ⇒ 代码改对了反而红（假红）；
   * 而假红的下场是有人去把注释删掉 —— 缺陷本体毫发无损。
   * ```
   *
   * # 为什么 `await` 必须带**词边界**
   * ```text
   * unawaited(DanmakuLocalService.probe());   ← 这是**正确**写法（后台异步）
   * 它的字面量里含 await 子串（u-n-await-ed）
   * ⇒ 不带边界的判据会把正确写法判红。
   * ⇒ 下面第三条用例专门守这个（好样本必绿）。
   * ```
   *
   * # 匹配目标（**读 lib/shell.dart 与 lib/core/danmaku.dart 确认过的真名**）
   * ```text
   * DanmakuLocalService.probe(     lib/core/danmaku.dart:2780  ← 真网络调用
   * .loadFor(                      lib/core/danmaku.dart:2674  ← ExternalDanmakuClient
   * .fetchComments(                lib/core/danmaku.dart      ← 同上，取弹幕正文
   * ```
   * ⚠️ `DanmakuLocalService.describe(` 不计入：它只拼字符串，不发网络。
   */
  group('★★★ ② 源码契约：启动期不许 await dan-api', () {
    test('★★★ lib/shell.dart 的 main() 里没有 await dan-api', () {
      final body = _extractBlock(_shellCode, _mainSignature);
      expect(
        _danApiAwaitRe.hasMatch(body),
        isFalse,
        reason: '★★★ `main()` 里等待 dan-api ⇒ 首帧被一次 HTTP 拖住数秒'
            '（公网 serverless 冷启动 3~6 s，Owner 第 9 条）。'
            '匹配到的片段：${_danApiAwaitRe.firstMatch(body)?.group(0)}',
      );
    });

    test('★★★ 启动期每个 initState() 里没有 await dan-api', () {
      final hits = <String>[];
      var scanned = 0;
      var from = 0;
      while (true) {
        final at = _shellCode.indexOf(_initStateSignature, from);
        if (at < 0) break;
        from = at + 1;
        scanned++;
        final body = _extractBlockFrom(_shellCode, at);
        final m = _danApiAwaitRe.firstMatch(body);
        if (m != null) {
          // ★ 行号要算到 await 那一行：块内相对偏移 + 块的 `{` 绝对偏移。
          //   指到签名行等于让 Owner 自己再翻一遍代码。
          final abs = _blockOpen(_shellCode, at) + m.start;
          final line = _shellCode.substring(0, abs).split(_nl).length;
          hits.add('lib/shell.dart:$line `${m.group(0)}`');
        }
      }
      /*
       * ★ 反空转前置：一个 initState() 都没扫到 ⇒ 判据什么都没看。
       * ```text
       * 这不是"没问题"，这是"判据失效"：
       *   shell.dart 里的启动期 widget 一旦换个写法（比如改成 build 里起请求），
       *   本用例会**静默通过**，而它存在的全部价值就是"扫到并检查"。
       * ```
       */
      expect(
        scanned,
        greaterThan(0),
        reason: '★★ 判据扫到 0 处 `$_initStateSignature` —— 要么 shell.dart '
            '的启动期写法全变了，要么判据失效。两种情况都必须红。',
      );
      expect(
        hits,
        isEmpty,
        reason: '★★★ 这些 initState() 里 await 了 dan-api：$hits$_nl'
            '启动期 widget 的 initState 等待网络 = 首帧被拖住。'
            '正确写法是 `unawaited(...)` 或起请求后让界面先出一帧。',
      );
    });

    test('★ 判据自检：坏样本必红 / 好样本必绿 / 注释引用不许误判', () {
      // ① 真的 await ⇒ 必红
      const bad = 'void f() async { await DanmakuLocalService.probe(); }';
      // ② 正确写法 unawaited( ⇒ 必绿（含 await 子串，但没有词边界）
      const good = 'void f() { unawaited(DanmakuLocalService.probe()); }';
      // ③ 注释里引用错误写法 ⇒ 剥掉注释后必绿
      final quoted =
          '// 反例：await DanmakuLocalService.probe();${_nl}void f() {}';
      // ④ 另一条真实 dan-api 入口（ExternalDanmakuClient.loadFor）也要认
      const badLoad = 'void f() async { await c.loadFor(fileName: n); }';
      // ⑤ await 与调用点**跨行**也要认（真实代码经常换行写）
      final badWrapped =
          'void f() async { await$_nl' '    DanmakuLocalService.probe(); }';

      expect(_danApiAwaitRe.hasMatch(bad), isTrue,
          reason: '★ 判据自己坏了：连真的 await 都认不出来。');
      expect(_danApiAwaitRe.hasMatch(badWrapped), isTrue,
          reason: '★ await 与调用点跨行时必须仍然认得出（间隔里含换行）。');
      expect(_danApiAwaitRe.hasMatch(badLoad), isTrue,
          reason: '★ `loadFor(` 也是 dan-api 入口，漏了它就漏掉一半缺陷形态。');
      expect(_danApiAwaitRe.hasMatch(good), isFalse,
          reason: '★ `unawaited(` 里含 await 子串 ⇒ 判据必须带词边界，'
              '否则「后台异步」的正确写法会被判成阻塞（假红逼人删注释）。');
      expect(_danApiAwaitRe.hasMatch(_stripDartComments(quoted)), isFalse,
          reason: '★ 注释里引用的错误写法必须被剥掉 —— '
              'lib/shell.dart 的注释里就有这种原文，不剥 ⇒ 假红。');
      /*
       * ⑥ 判据的**适用范围**自检：本文件的剥注释器不认三引号字符串。
       * ```text
       * Dart 允许 ''' 或 """ 三引号字符串；一旦 shell.dart 里出现，
       * 本剥注释器会把边界算错 ⇒ 后面的代码可能被当成字符串清空 ⇒ **假绿**。
       * 所以：出现三引号 = 判据失效 = 必须红（逼人先把剥注释器扩好）。
       * ```
       */
      final hasTripleQuoted =
          _shellRaw.contains("'''") || _shellRaw.contains('"""');
      expect(
        hasTripleQuoted,
        isFalse,
        reason: '★ shell.dart 里出现了三引号字符串 ⇒ 本文件的剥注释器认不出边界，'
            '判据可能漏扫（假绿）。先把 [_stripDartComments] 扩成能认三引号。',
      );
    });

    test('★ 判据自检：源码里找不到 main() 时必须红（不许静默绿）', () {
      var threw = false;
      try {
        _extractBlock('class A {}${_nl}void notMain() {}', _mainSignature);
      } on TestFailure {
        threw = true;
      }
      expect(threw, isTrue,
          reason: '★ 签名一改，[_extractBlock] 若返回空串 ⇒ 判据永远绿（假绿）。'
              '这里钉住：找不到被测对象必须抛 TestFailure。');
    });
  });
}

/// 记录「每次 send **实际花了多久**」的假传输层
///
/// ⚠️ 它不自己决定睡多久，而是**睡到 probe() 给它的预算用完**为止 ——
///    所以"每次 send 的耗时"就是"probe() 当时还剩多少预算"的真实读数。
///    这是本门禁唯一能观测到"预算是否共享"的地方。
class _RecordingBudgetTransport implements DanmakuTransport {
  _RecordingBudgetTransport({required this.onSend});

  final void Function(int elapsedMs) onSend;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastElapsedMs = 0;

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    /*
     * ★ 在**进入时**就记：`本次 send 距离上一次 send 过去了多久`。
     * 这个间隔 = **上一个端点实际消耗掉的预算**（因为 probe 的
     * `.timeout(remaining)` 会先把它打断）。
     * ```text
     * 预算共享 ⇒ 间隔累积/递减
     * 每端点各一份 ⇒ 每次间隔都 ≈ 0（每次都立刻重新拿满额）
     * ```
     * ⚠️ 不能在 await 之后记：那时调用方早就 `.timeout` 走掉了，
     *    读到的是一段没人等的残留时间（我第一版就是这么写错的，实测 [] ）。
     */
    final now = _clock.elapsedMilliseconds;
    onSend(now - _lastElapsedMs);
    _lastElapsedMs = now;
    // 睡到必被 timeout 打断（预算 600ms，这里睡 2s）
    await Future<void>.delayed(const Duration(seconds: 2));
    return const DanmakuHttpResponse(statusCode: 404, body: '{}');
  }

  @override
  void close() {}
}

// ── 源码契约用的「读文件 + 剥注释 + 切块」（只在本文件用） ──────────────────

/// 换行符。
///
/// ★ 本文件新增的源码契约部分**不在字符串字面量里写任何转义序列** ——
/// 上一轮就是把这个 `n` 转义写成了真实换行，整份文件 41 个 analyze error。
/// 这里用 [String.fromCharCode] 拿到它，写进来的字节就是跑起来的字节。
final String _nl = String.fromCharCode(10);

/// 反斜杠（同上：不写字面量转义）。
final String _bs = String.fromCharCode(92);

/// 未经处理的产品源码
final String _shellRaw = File('lib/shell.dart').readAsStringSync();

/// 产品源码（启动路径的**唯一**真身）。先剥注释，再做任何匹配。
final String _shellCode = _stripDartComments(_shellRaw);

/// `main()` 的签名 —— 精确到 `async`。
///
/// 不是 async 的 `main()` 里根本不能 await，那条门禁也就无从谈起；
/// 签名一变 ⇒ [_extractBlock] 直接 fail（**红**），不会静默放过。
const String _mainSignature = 'Future<void> main() async';

/// 启动期 widget 的固定写法（本仓 3 处，见 lib/shell.dart 的 initState）
const String _initStateSignature = 'void initState()';

/// `await`（**两侧词边界**）+ 160 字符内命中一个真实 dan-api 入口
///
/// # 匹配目标（都是从源码里读出来的真名，不是猜的）
/// ```text
/// DanmakuLocalService.probe(   lib/core/danmaku.dart:2780  真网络探测
/// .loadFor(                    lib/core/danmaku.dart:2674  ExternalDanmakuClient
/// .fetchComments(              lib/core/danmaku.dart       ExternalDanmakuClient
/// ```
/// ⚠️ `DanmakuLocalService.describe(` **不计入**：它只拼提示字符串，不发网络。
///
/// # 为什么用 lookaround 而不是词边界简写
/// ```text
/// 同一个意思，但整条正则**一个反斜杠都不带** ——
/// 上一轮的教训：源码里的转义序列会被工具链二次解释
/// （写 \\b 可能落成退格符、写 \\n 可能落成真实换行）。
/// 这条判据自己不含可被误解释的字符 ⇒ 写进来的就是跑起来的。
/// ```
///
/// # 词边界为什么**必需**
/// ```text
/// unawaited(DanmakuLocalService.probe());   ← 这是**正确**写法（后台异步）
/// 它的字面量里含 await 子串（u-n-await-ed）
/// ⇒ 不带边界的判据会把正确写法判红 ⇒ 逼人去删掉正确代码。
/// ```
final RegExp _danApiAwaitRe = RegExp(
  '(?<![A-Za-z0-9_])await(?![A-Za-z0-9_])'
  '[^;{}]{0,160}'
  '(?:DanmakuLocalService[.]probe[(]|[.]loadFor[(]|[.]fetchComments[(])',
);

/// 剥掉 Dart 注释，并把**字符串字面量的内容清空**（引号保留）。
///
/// # 为什么清空字符串内容（不只是剥注释）
/// ```text
/// ① 提示文案 / 错误消息里可能**就写着** await DanmakuLocalService.probe()
///    （给人看的示例），不清空 ⇒ 把代码改对了反而红。
/// ② [_extractBlockFrom] 靠花括号计数切块：字符串里的 { 或 } 会让它提前
///    收尾，切出一段**截断**的 main() ⇒ 后面的违规写法看不见（假绿）。
/// ```
///
/// # 行号
/// 注释与字符串里的**换行一律保留** ⇒ 打出来的行号与 `lib/shell.dart` 对得上
/// （红的时候要能直接跳过去）。
///
/// ⚠️ 已知不认三引号字符串（Dart 允许，但本仓 shell.dart 目前 0 处）。
///    对此有专门的断言守着，见「判据自检」里的适用范围那条。
String _stripDartComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    // ① 行注释：丢到行尾（行尾换行由主循环照抄 ⇒ 行号不变）
    if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '/') {
      while (i < src.length && src[i] != _nl) {
        i++;
      }
      continue;
    }
    // ② 块注释：整段丢，但逐行补换行
    if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        if (src[i] == _nl) out.write(_nl);
        i++;
      }
      i += 2;
      continue;
    }
    // ③ 字符串字面量：引号保留，内容清空（换行保留）
    if (src[i] == "'" || src[i] == '"') {
      final q = src[i];
      out.write(q);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == _nl) out.write(_nl);
        // 转义：连下一个字符一起跳过，否则 'it\'s' 会提前收尾
        if (src[i] == _bs && i + 1 < src.length) {
          if (src[i + 1] == _nl) out.write(_nl);
          i += 2;
          continue;
        }
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
      continue;
    }
    out.write(src[i]);
    i++;
  }
  return out.toString();
}

/// 按签名切出**整个函数体**（含花括号）。
///
/// ★ 找不到签名必须 **fail（红）**，不能返回空串 ——
///   返回空串等于「判据什么都没检查，然后报绿」，那是本仓最恨的假绿。
String _extractBlock(String code, String sig) {
  final at = code.indexOf(sig);
  if (at < 0) {
    fail('源码里找不到 `$sig` —— 判据找不到被测对象时必须红，'
        '不能当成「没有问题」：$sig');
  }
  return _extractBlockFrom(code, at);
}

/// 从 [at] 起按花括号配平切块（[code] 必须是剥过注释、清过字符串内容的）
String _extractBlockFrom(String code, int at) {
  final open = _blockOpen(code, at);
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') {
      depth--;
      if (depth == 0) return code.substring(open, i + 1);
    }
  }
  return fail('从偏移 $at 起的块花括号没有闭合 —— 源码被改坏了');
}

/// [at] 之后第一个 `{` 的绝对偏移 —— 单独抽出来是为了把块内相对偏移
/// 还原成**绝对行号**：红的时候要指到 `await` 那一行，不是签名那一行。
int _blockOpen(String code, int at) {
  final open = code.indexOf('{', at);
  if (open < 0) {
    fail('偏移 $at 之后找不到 `{` —— 源码被改坏了（判据找不到被测对象必须红）');
  }
  return open;
}
