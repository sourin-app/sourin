// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · r4-dialog `_LoadState` 取证的**独立复核**（只读取证）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★ 本文件有一条用例**故意让自己红**（用例 A，见下面）
//
// ```text
// 它故意留下 pending 的 FakeTimer，让 test 框架在收尾时打出证据。
// 代价：全量读数被它永久污染 1 个 -1。
//
// ⇒ 用 `@Tags(['evidence'])` 挪出默认套件：
//     默认全量：读数干净
//     显式复现：flutter test --tags evidence test/zz_t66_skip_loadstate_review_test.dart
//
// ★ 为什么不用 skip / markTestSkipped：
//   `~1` 比 `-1` **更隐蔽** —— 没人会去看它是「故意跳过」还是「忘了跑」。
//   详见 .agents/notes/implemented/testing/
//     2026-10-19-evidence-gate-that-is-red-on-purpose.md
// ```
//
// # 被复核的主张（r4-dialog 只取证没动手）
// ```text
// 7 个测试没注入 `debugSkipMarkerFetcher`
//   ⇒ 真 FFI 异常落在**真实时间**轴上
//   ⇒ 而 `tester.pump()` 只推进 fake clock
//   ⇒ 超时（10 秒真实时间）不会在测试预算内触发
//   ⇒ `_LoadState` 永远停在 `loading` ⇒ 时间轴等控件根本不挂载
// ```
//
// # 本文件的立场：**独立复核，不是复述**
// ```text
// ① 决定性读数：**不注入 + runAsync ⇒ 失败文案出现**（A vs A2）
//    —— r4 把 A/A2 的差别归给「让真实事件循环跑」，这是因果的关键，
//       不采信表格，必须复现。
// ② 相关性表：逐条自己跑（见交付报告，不在本文件里贴耗时读数）
// ③ 修法抉择：补注入 vs native-media 标签 —— 见文件末尾的实测依据
// ```
//
// ⚠️ 本文件**不改**那 7 个测试，也**不改** `skip_marker_dialog.dart`。
//    只出「结论 + 该选哪个修法 + 理由」。
//
// ⚠️ 判据纪律：每条都要能回答「**这个缺陷存在时，它凭什么会红**」。
//    本会话已出四次恒真/假绿（R7 非递归扫描、R8 不挂订阅的 getter、
//    R2 的不可辨样本、CS-1 的恒真断言）⇒ 自检是必备项，不是加分项。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_timeline.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Builder(builder: (_) => child)));

/// 数一数页面上三类东西各出现几个（用来区分「停在 loading」与「读失败了」）
String _probeCounts(WidgetTester t) {
  String n(Finder f) => '${f.evaluate().length}';
  return 'timeline=${n(find.byType(SkipTimeline))} '
      '失败文案=${n(find.textContaining('读取跳过点失败'))} '
      '转圈=${n(find.byType(CircularProgressIndicator))}';
}

void main() {
  tearDown(() {
    SourinApi.debugSkipMarkerFetcher = null;
  });

  // ══════════════════════════════════════════════════════════════════
  // ① ★★★ 决定性读数：A（只 pump）vs A2（加 runAsync），**都不注入**
  // ══════════════════════════════════════════════════════════════════
  group('① 决定性读数：runAsync 单独就是分水岭（零注入）', () {
    // ★★★ 用例 A 已移到 zz_t66_skip_loadstate_evidence_test.dart。
    //   理由：它**故意**让 pending timer 打出证据，也就是**故意红**；
    //   `@Tags` 在 package:test 里只能挂 library，不能挂单个用例，
    //   留在本文件会让整条 A2/②/③ 也退出默认套件（= 整文件 skip 的坑）。
    //

    testWidgets('★★★ A2：只加 runAsync（仍不注入）⇒ **失败文案出现**', (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-26（与 t72_jank P0 同一口径）：**不赌固定窗口**
       * ══════════════════════════════════════════════════════════════
       *
       * # 改前为什么会在全量里假红
       * ```text
       * 原来写死 `for (i<12) { delay(250ms); pump(); }` = **固定 3 秒**预算，
       * 而这条用例等的是**真实 FFI** 的异常投递：
       *   · 空闲时：实测 430~450ms 就投递完 ⇒ 3 秒够 ⇒ 绿
       *   · 全量并发时：FFI/callAsync 被拖慢 ⇒ 3 秒内还没投递 ⇒ 仍停在 loading
       *     ⇒ 「失败文案」找不到 ⇒ 红
       * 而那时红的是"**仪器没等到异步落地**"，**说明不了产品有没有写失败文案**。
       * ```
       * # 改法（不放宽断言）
       * ```text
       * ① 把"固定 3 秒"换成**轮询到文案真的出现**（真实时间，上限 30 秒）；
       * ② 上限到了还没出现 ⇒ 红在**专属原因**上，并打印现场（timeline/失败文案/转圈）；
       * ③ 主断言仍是 `findsWidgets`（一个字都没放宽）。
       * ```
       */
      final sw = Stopwatch()..start();
      bool failedShown() =>
          find.textContaining('读取跳过点失败').evaluate().isNotEmpty;
      await t.runAsync(() async {
        // ★ 因果的关键一跳不变：A 与 A2 的唯一差别仍是「让真实事件循环跑」
        await t.pumpWidget(_host(const SkipMarkerDialog(
          provider: 'demo',
          id: 'reviewA2',
          title: 'probe',
          streamUrl: '',
          duration: Duration(minutes: 47, seconds: 6),
        )));
        // 轮询：每 50ms 真实让一次事件循环，再 pump 一帧
        while (sw.elapsed < const Duration(seconds: 30) && !failedShown()) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await t.pump();
          while (t.takeException() != null) {}
        }
      });
      // ignore: avoid_print
      print('REVIEW|A2|${_probeCounts(t)} elapsed=${sw.elapsedMilliseconds}ms');

      if (!failedShown()) {
        fail('仪器没等到异步落地：真实 FFI 在 ${sw.elapsedMilliseconds}ms 内'
            '没有把异常投递出来（现场 ${_probeCounts(t)}）'
            '⇒ `_LoadState` 仍停在 loading，**不是产品没写失败文案**。'
            '先重跑；若稳定复现，检查 `SourinApi.getSkipMarker` 是否被别处注入/'
            '或核心处于"能成功返回"的状态（那样本用例的前提就不成立）。');
      }

      // ★★★ A2 必须看到 failed 文案：真 FFI 异常在**真实时间**上投递了
      expect(
        find.textContaining('读取跳过点失败'),
        findsWidgets,
        reason: '★★★ 决定性读数：加了 runAsync，真实事件循环跑起来 ⇒ '
            '异常被投递 ⇒ 走到 _LoadState.failed。'
            '若这条红了，说明分水岭不是 runAsync，而是别的东西。',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ② 三臂对照：注入 / runAsync / 两者 ⇒ 证明「注入」是**另一个**独立变量
  // ══════════════════════════════════════════════════════════════════
  group('② 修法抉择的实测依据', () {
    testWidgets('★★ 注入 fake fetcher（**不加** runAsync）⇒ 直接 ok，时间轴在', (t) async {
      // ★ 这证明「补注入」这条路**不需要** runAsync —— 它把真 FFI 整个换掉
      SourinApi.debugSkipMarkerFetcher = (provider, id) async => null;

      await t.pumpWidget(_host(const SkipMarkerDialog(
        provider: 'demo',
        id: 'reviewInj',
        title: 'probe',
        streamUrl: '',
        duration: Duration(minutes: 47, seconds: 6),
      )));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 250));
        while (t.takeException() != null) {}
      }
      // ignore: avoid_print
      print('REVIEW|INJECT|${_probeCounts(t)}');

      expect(find.byType(SkipTimeline), findsOneWidget,
          reason: '★★ 补注入 ⇒ fake 直接返回 ⇒ _LoadState=ok，'
              '**不需要**真实事件循环 ⇒ CI 上不需要 libmpv。');
      expect(find.textContaining('读取跳过点失败'), findsNothing);
    });

    testWidgets('★★ 注入一个**抛异常**的 fetcher ⇒ 走 failed，且不需要 runAsync', (t) async {
      SourinApi.debugSkipMarkerFetcher = (provider, id) async =>
          throw StateError('注入的失败');

      await t.pumpWidget(_host(const SkipMarkerDialog(
        provider: 'demo',
        id: 'reviewInjFail',
        title: 'probe',
        streamUrl: '',
        duration: Duration(minutes: 47, seconds: 6),
      )));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 250));
        while (t.takeException() != null) {}
      }
      // ignore: avoid_print
      print('REVIEW|INJECT_THROW|${_probeCounts(t)}');

      // 异常在 microtask 里抛出 ⇒ pump 会推进 microtask 队列 ⇒ 无需真实时间
      expect(
        find.textContaining('读取跳过点失败'),
        findsWidgets,
        reason: '★★ 抛异常的 fake 也能走到 failed（microtask 不用真实时间）'
            '⇒ 「失败态」这条路本身不需要 FFI。',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ③ ★★ r4 自己提的坑：那些测试 `streamUrl: ''` ⇒ 补注入还需给出可用 SkipMarker
  // ══════════════════════════════════════════════════════════════════
  group('③ ★ 补注入的隐藏前提：streamUrl 为空时的预览前提', () {
    testWidgets('★★ 注入返回 null（=没设过跳过点）⇒ 预览不启动，但**不失败**', (t) async {
      // ★ 这条验的是 r4 的担心：注入必须给出「可用的 SkipMarker」吗？
      SourinApi.debugSkipMarkerFetcher = (provider, id) async => null;

      await t.pumpWidget(_host(const SkipMarkerDialog(
        provider: 'demo',
        id: 'reviewNull',
        title: 'probe',
        // ★ 与那批测试一致：空 streamUrl
        streamUrl: '',
        duration: Duration(minutes: 47, seconds: 6),
      )));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 250));
        while (t.takeException() != null) {}
      }
      // ignore: avoid_print
      print('REVIEW|NULL|${_probeCounts(t)}');

      // 前置自检：至少弹窗在树上、没异常
      expect(find.byType(SkipMarkerDialog), findsOneWidget);
      expect(find.textContaining('读取跳过点失败'), findsNothing,
          reason: '★★ 返回 null 是**正常结果**（没设过），不是失败');
      // ⇒ 结论：补注入**不需要**构造非空 SkipMarker 就能让这批测试脱离 loading。
      //   若拖拽断言另有前提，那是**另一条**依赖（预览播放器），与本条因果无关。
      expect(find.byType(SkipTimeline), findsOneWidget,
          reason: '★★ 四行/时间轴照常渲染（ok 分支）⇒ 拖拽断言有东西可拖。');
    });

    testWidgets('★★ 空 streamUrl 下预览确实起不来（记录事实，不断言产品好坏）', (t) async {
      SourinApi.debugSkipMarkerFetcher = (provider, id) async => null;

      await t.pumpWidget(_host(const SkipMarkerDialog(
        provider: 'demo',
        id: 'reviewNoStream',
        title: 'probe',
        streamUrl: '',
        duration: Duration(minutes: 47, seconds: 6),
      )));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 250));
        while (t.takeException() != null) {}
      }
      // 只记录，不作产品结论 —— media_kit 在测试环境本就起不来
      // ignore: avoid_print
      print('REVIEW|NOSTREAM|${_probeCounts(t)} '
          '有预览控件=${find.byType(SkipTimeline).evaluate().length}');
      expect(find.byType(SkipMarkerDialog), findsOneWidget,
          reason: '至少证明挂载成功；本条不为预览能力背书');
    });
  });
}
