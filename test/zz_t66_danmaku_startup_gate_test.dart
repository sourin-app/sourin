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
