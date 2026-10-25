// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R3-③ / R3-⑦ 收尾门禁 —— **取数/搜索那条路也必须说真话**
// ═══════════════════════════════════════════════════════════════════════
//
// # 范围（先说清楚我没测什么，否则"全绿"会被误读）
// ```text
// 已有的 `zz_t66_r3_probe_truth_test.dart` 覆盖的是**「测试连接」那条路**
//   （`_diagnose`：InternetAddress.lookup → 伪造段 → DoH 对照）。
// 本文件覆盖的是**另一条路**，此前完全没有 dnsHijacked 这一档：
//   取弹幕 / 搜索 → core 抛 `DanmakuException` → 面板画 `err.message`
//   改前画出来的是「连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。」
//   ⇒ 本机 DNS 被劫持时，**用户被指向"去查服务"**，方向错的。
// ```
//
// # 本轮加的唯一一个新信号（为什么不需要联网）
// ```text
// `DanmakuException.resolvedAddress` —— 本机**解析到并去连**的那个 IP，
// 直接取自 `SocketException.address`（它本来就在异常里，改前被丢掉了）。
// ⇒ 判据 `DanmakuProbeReport.looksForged` 拿到它即可定案，
//    失败路径上**零新增网络请求**（DoH 仍然只留在「测试连接」那条路）。
// ```
//
// # ★ 本文件的断言纪律（AGENTS.md §8 最后一行的坑）
// ```text
// 同一句结论可以由不同原因产生时，必须能分辨是**哪一个原因**。
//   上一轮的实例：两档文案都以「凭据未同步」开头，
//   只断言 contains('凭据未同步') ⇒ 注入后 19 条全绿。
// ⇒ 本文件所有文案断言都**成对**：
//     该在的词在  AND  **不该在的词不在**。
//     特别地：dnsHijacked 文案里必须**没有**「服务没起来」。
// ```
//
// ⚠️ 根因归属（Lead 用 DoH 真值对照定案，本文件**不重修**）：
//   DNS 被**劫持**（返回伪造段），TCP 超时是它的**后果**，服务本体是活的。
//   ⇒ 判「劫持」的依据是**地址**，不是「解析有没有抛异常」。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

void main() {
  // ────────────────────────────────────────────────────────────────────
  // ① 伪造解析结果 ⇒ 判 dnsHijacked（正向）
  // ────────────────────────────────────────────────────────────────────
  group('① 伪造解析结果 ⇒ dnsHijacked', () {
    // 本轮实测到的伪造段样例（DoH 真值与本机答案不同，见 docs/notes/2026-10-19-dns-hijack-vs-tcp.md）
    const forged = <String>[
      '74.86.17.48', // PTR → SoftLayer/IBM
      '108.160.173.207', // PTR → Dropbox
      '2a03:2880:f117:83:face:b00c:0:25de', // Facebook 花样段
    ];

    for (final addr in forged) {
      test('★★★ 取数失败落在伪造段 $addr ⇒ dnsHijacked', () {
        final e = DanmakuException(
          '连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。',
          resolvedAddress: addr,
        );
        final r = DanmakuProbeReport.fromDanmakuException(e);

        // 该在的：这一档的标题
        expect(
          r.failure,
          DanmakuProbeFailure.dnsHijacked,
          reason: '地址 $addr 落在已知伪造段 ⇒ 必须判 dnsHijacked',
        );
        // ★ 不该在的：不能回落成"连不上 / 服务没起来"
        //   （这就是"只断言是什么、不断言不是什么"会漏掉的一整类错误）
        expect(
          r.failure,
          isNot(DanmakuProbeFailure.connectionTimeout),
          reason: '劫持**不得**被说成"连不上"——那是 TCP 层，后果不是病因',
        );
        expect(
          r.detail,
          isNot(contains('服务没起来')),
          reason: '文案不许出现「服务没起来」：服务是活的，指错方向等于让用户白查',
        );
        // 必须说清行动：换 DNS / 开代理
        // ⚠️ 断言按**真实文案**写（`把系统 DNS 换成可信的`），
        //    不是按我记忆里的措辞 —— 措辞一改就红，说明它真在钉文案。
        expect(r.remedy, contains('DNS 换成可信的'));
        expect(r.remedy, contains('代理'));
      });
    }

    test('★★★ 搜索失败同一条判据（面板与取数共用一份）', () {
      final e = DanmakuException(
        '连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。',
        resolvedAddress: '74.86.17.48',
      );
      final r = DanmakuProbeReport.fromDanmakuException(e);
      expect(r.failure, DanmakuProbeFailure.dnsHijacked);
      expect(r.failure.title, contains('错误地址'));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // ② 正常解析 + 连接失败 ⇒ **不是** dnsHijacked（防止"所有失败都归 DNS"）
  // ────────────────────────────────────────────────────────────────────
  group('② 正常解析 + 连接失败 ⇒ 不是 dnsHijacked', () {
    test('★★★ 真值地址 + 连接失败 ⇒ 不是劫持', () {
      // DoH 真值（216.198.79.x / 64.29.17.x），连不上它只是路由/墙的问题
      final e = DanmakuException(
        '连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。',
        resolvedAddress: '216.198.79.3',
      );
      final r = DanmakuProbeReport.fromDanmakuException(e);

      // ★ 这是本文件最关键的一条反证：防止判据写成恒真。
      expect(
        r.failure,
        isNot(DanmakuProbeFailure.dnsHijacked),
        reason: '地址不在伪造段 ⇒ 绝不能判劫持（否则所有失败都会被推去改 DNS）',
      );
      expect(
        r.remedy,
        isNot(contains('换 DNS')),
        reason: '没证据就不许把用户指向换 DNS',
      );
    });

    test('★★★ 没有地址证据（超时/非网络失败）⇒ 不是劫持', () {
      // 超时分支拿不到 resolvedAddress ⇒ 空串
      final e = DanmakuException('弹幕服务没有响应（超时）。可以稍后重试。');
      expect(e.resolvedAddress, isEmpty, reason: '前提：默认必须是空');
      final r = DanmakuProbeReport.fromDanmakuException(e);
      expect(r.failure, isNot(DanmakuProbeFailure.dnsHijacked));
      expect(r.remedy, isNot(contains('换 DNS')));
    });

    test('★★★ detail 里的地址必须是**裸 IP**，不是 Dart 调试表示（P1-3）', () {
      // ★ 2026-10-19（Lead 补）：`_addressOf` 曾用 `InternetAddress.toString()`，
      //   它返回的是 `"InternetAddress('74.86.17.48', IPv4)"` ——
      //   **Dart 的调试表示**，而 detail 在面板里是**用户可见**的。
      //
      // ⚠️ 判据分两层，缺一不可（第一版只写第二层，实测**注入后仍全绿**）：
      //   ① 源码级：`_addressOf` 必须用 `.address`（它 private，行为测不到）
      //   ② 行为级：detail 里不得出现 `InternetAddress(`，且**必须**含裸 IP
      //      （阳性对照，防止"因为根本没进 detail"而恒绿）
      final src = File('lib/core/danmaku.dart').readAsStringSync();
      final i = src.indexOf('static String _addressOf');
      expect(i, greaterThan(0), reason: '前提：`_addressOf` 还在');
      // ★★ 按**大括号配对**截函数体，不用固定窗口长度。
      //   固定 `i + 600` 是本会话反复出现的坑（R8 探针、r6 注释锚点）：
      //   注释一变长，`return a.address` 就掉出窗口 ⇒ 判据变恒真/恒假。
      final open = src.indexOf('{', i);
      var depth = 0;
      var end = open;
      for (var k = open; k < src.length; k++) {
        if (src[k] == '{') depth++;
        if (src[k] == '}') {
          depth--;
          if (depth == 0) {
            end = k;
            break;
          }
        }
      }
      final body = src.substring(i, end + 1);
      expect(
        body.length,
        greaterThan(50),
        reason: '★★ 函数体只截到 ${body.length} 字符 ⇒ 截取失败，'
            '下面两条判据会变成恒值',
      );
      expect(
        body.contains('return a.toString()'),
        isFalse,
        reason: '★★ `_addressOf` 不能用 `toString()` —— 它返回的是\n'
            "      Dart 调试表示 \"InternetAddress('74.86.17.48', IPv4)\"，\n"
            '      而这串会原样显示给用户。改用 `a.address`（裸 IP）。\n'
            '实测该函数体片段：\n${body.substring(0, 260)}',
      );
      expect(
        body.contains('return a.address'),
        isTrue,
        reason: '★★ 前提：它应当用 `a.address`；若这条红，'
            '说明实现换了别的方式，上一条的判据就失效了',
      );

      // ② 行为级
      final e = DanmakuException(
        '连不上弹幕服务',
        resolvedAddress: '74.86.17.48',
      );
      final r = DanmakuProbeReport.fromDanmakuException(e);
      expect(
        r.detail,
        isNot(contains('InternetAddress(')),
        reason: '★★★ detail 是**用户可见**的，不能出现 Dart 调试表示。\n'
            '实测 detail=${r.detail}',
      );
      expect(
        r.detail,
        contains('74.86.17.48'),
        reason: '★★ 前置：detail 里应当出现裸 IP；'
            '若这条红，说明地址根本没进 detail，'
            '那上面那条「不含 InternetAddress(」就是恒真的假绿。',
      );
    });

    test('★★★ 空串地址绝不会被当成"命中伪造段"', () {
      final e = DanmakuException('连不上弹幕服务', resolvedAddress: '');
      final r = DanmakuProbeReport.fromDanmakuException(e);
      expect(r.failure, isNot(DanmakuProbeFailure.dnsHijacked));
    });

    test('★★★ 服务端错误（HTTP 5xx/4xx）⇒ serverError，不是劫持', () {
      final e = DanmakuException(
        '弹幕服务返回了不合法的响应（协议错误）。请确认这个地址是弹幕服务。',
        statusCode: 502,
      );
      final r = DanmakuProbeReport.fromDanmakuException(e);
      expect(r.failure, DanmakuProbeFailure.serverError);
      expect(r.failure, isNot(DanmakuProbeFailure.dnsHijacked));
    });

    test('★★ 判据是纯函数：同一输入永远同一输出', () {
      DanmakuException mk() => DanmakuException(
            '连不上弹幕服务',
            resolvedAddress: '74.86.17.48',
          );
      final a = DanmakuProbeReport.fromDanmakuException(mk());
      final b = DanmakuProbeReport.fromDanmakuException(mk());
      expect(a.failure, b.failure);
      expect(a.detail, b.detail);
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // ③ 「没有新增网络依赖」—— 这条是本轮的设计硬约束，必须钉住
  // ────────────────────────────────────────────────────────────────────
  group('③ 判据本身零网络（不引入探测依赖到热路径）', () {
    test('★★★ fromDanmakuException 是同步的（不是 Future ⇒ 不可能偷偷联网）', () {
      final r = DanmakuProbeReport.fromDanmakuException(
        DanmakuException('连不上', resolvedAddress: '74.86.17.48'),
      );
      // 若它变成异步，这条 expect 会直接编译不过 ⇒ 门禁自己就是防线
      expect(r, isA<DanmakuProbeReport>());
      expect(r.failure, DanmakuProbeFailure.dnsHijacked);
    });

    test('★★★ 源码核对：判据函数体内不出现任何 HTTP/DoH 调用', () {
      // 只取这个方法的函数体（到下一个 "  /// " 注释块之前）
      final src = File(
        'lib/ui/widgets/danmaku_settings_dialog.dart',
      ).readAsStringSync();
      final start = src.indexOf('static DanmakuProbeReport fromDanmakuException');
      expect(start, greaterThan(0), reason: '方法必须还在（锚点漂了就要改门禁）');
      final body = src.substring(start, start + 2000);
      expect(body, isNot(contains('HttpClient')));
      expect(body, isNot(contains('dohLookup')),
          reason: 'DoH 只能留在「测试连接」那条路，不能进取数/搜索热路径');
    });
  });

  // ────────────────────────────────────────────────────────────────────
  //  ③b ★★★ 修复 B：**真接线**（驱动真实 widget，不是字符串匹配源码）
  // ────────────────────────────────────────────────────────────────────
  //
  // # 为什么这一段必须存在（复核给的证据）
  // ```text
  // 复核实测：`fromDanmakuException` 在 lib/ 里**零生产调用点**，
  //   而它的注释指着一个**不存在**的 `_searchResultBody`
  //   （`grep -rni searchresultbody lib/` 只命中注释本身）。
  // ⇒ 之前 ③ 那组只证明"这个函数体里没有 HTTP/DoH"，对
  //   "热路径到底有没有用它"是**恒真**的。
  // # 现在
  // ```text
  // 真正的渲染点在 `lib/ui/danmaku_search_page.dart` 的 `_hotPathFailure`
  //   （搜索失败 + 取弹幕失败两处都接了）。
  // ⇒ 本组 pump 真实 `DanmakuSearchPage`，断言屏幕上**真的出现**了归因标题：
  //     伪造段地址 ⇒ 出现"错误地址/劫持"标题；
  //     真值地址   ⇒ **不**出现该标题（反向：证明 widget 用的是判据，不是常量）。
  // ```
  group('③b 热路径真接线（驱动真实 DanmakuSearchPage）', () {
    DanmakuSettingsState stateWith(DanmakuException? searchError) =>
        DanmakuSettingsState(
          enabled: true,
          appId: '',
          appSecret: '',
          fontScale: 1,
          opacity: 1,
          speed: 1,
          area: 1,
          searchSearched: true,
          searchError: searchError,
        );

    Widget pageWith(DanmakuException? searchError) => MaterialApp(
          home: DanmakuSearchPage(
            state: stateWith(searchError),
            biliState: const BiliImportState(),
            localTitles: const <String>['第1集'],
            onSearch: (_) {},
            onBiliSearch: (_) {},
            onPickMatch: (_) {},
            onBatchBind: (_) {},
            onBiliImport: (_) {},
            onBiliSelectPage: (_) {},
            onClose: () {},
          ),
        );

    testWidgets('★★★ 搜索失败：伪造段地址 ⇒ 搜索页真的画出"劫持"归因', (tester) async {
      await tester.pumpWidget(pageWith(DanmakuException(
        '连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。',
        resolvedAddress: '74.86.17.48',
      )));
      await tester.pump();

      // 归因标题（来自 DanmakuProbeReport.failure.title）
      expect(find.textContaining('错误地址'), findsWidgets,
          reason: '★★★ 搜索页没画出归因 ⇒ `fromDanmakuException` 仍然是死代码'
              '（改前这里只有 error.toString() 的原文）');
      // 行动建议（来自 remedy）：必须指向"换 DNS / 代理"，不是"查服务"
      expect(find.textContaining('DNS 换成可信的'), findsWidgets,
          reason: '★ 归因块必须带上可照做的下一步');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('★★★ 反向：真值地址 ⇒ 搜索页**不**说劫持（判据不是常量）', (tester) async {
      await tester.pumpWidget(pageWith(DanmakuException(
        '连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。',
        resolvedAddress: '216.198.79.3',
      )));
      await tester.pump();

      expect(find.textContaining('错误地址'), findsNothing,
          reason: '★★★ 地址不在伪造段却画出"劫持"⇒ 归因是写死的常量，'
              '那比不接更糟（会把所有失败都推去改 DNS）');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('★★★ 接线位置与"诊断区不许再插块"（含实测可达性理由）', () {
      final src = File('lib/ui/danmaku_search_page.dart').readAsStringSync();
      /*
       * ① 归因块只在**列表层**（搜索失败）出现**一次**。
       *    主判据是上面两个 widget 用例；这条防"接到别处"或"接了两套"。
       */
      expect(
        RegExp(r'_hotPathFailure\(s\.searchError!\)').hasMatch(src),
        isTrue,
        reason: '★ 搜索失败那一处没接线',
      );
      expect(RegExp(r'_hotPathFailure\(').allMatches(src).length, 2,
          reason: '★ `_hotPathFailure` 只该有 1 处定义 + 1 处调用；'
              '多处调用=同一份归因铺了两遍（会挤占诊断区的可点区域）');

      /*
       * ② 诊断区（详情展开区）里**不许**再插归因块。
       *    2026-10-25 实测（.probe/fixlive-regress1.log）：把归因块插进诊断区后，
       *    两个动作按钮的中心点从 y=560 被推到 y≈645，而 800x600 窗口底边是 600
       *    ⇒ `hitTestable()` 变 0，`zz_t1028_danmaku_regressions_test`
       *      的「凭证补救动作真实可达」直接红。
       *    ⇒ 这条断言把"不要再插回去"钉住（否则下次谁再插一遍又会静默回归）。
       */
      final anchor = src.indexOf('for (final error in [s.error, s.searchError])');
      expect(anchor, greaterThan(0),
          reason: '★ 诊断区那个 for 循环不见了（锚点漂了就要改门禁）');
      // 循环体够长（中间有一大段说明注释）：取到文件尾，足够覆盖整个 children 块
      final loopBody = src.substring(anchor);
      expect(loopBody, contains('SelectableText(error.toString())'),
          reason: '★ 诊断区必须仍然渲染 error 原文（那是证据，不能只剩结论）');
      expect(loopBody.split('_hotPathFailure').length - 1, lessThanOrEqualTo(1),
          reason: '★ 诊断区又被插了归因块 ⇒ 动作按钮会被挤出视口（实测过）');

      expect(src, contains('fromDanmakuException'),
          reason: '★ 归因必须来自单一判据（不许在页面里另写一套）');
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // ④ 反证：伪造段表本身不能判真值地址（防止判据写成恒真）
  // ────────────────────────────────────────────────────────────────────
  group('④ 伪造段表反证', () {
    test('★★★ DoH 真值地址一个都不许被判成伪造', () {
      const truth = <String>[
        '216.198.79.3',
        '216.198.79.67',
        '64.29.17.3',
        '64.29.17.67',
        '216.198.79.131',
      ];
      for (final a in truth) {
        expect(
          DanmakuProbeReport.isKnownForgedAddress(a),
          isFalse,
          reason: '$a 是 DoH 真值，不许被判成伪造',
        );
      }
    });

    test('★★ 空串/垃圾输入不许命中', () {
      for (final a in <String>['', '   ', 'not-an-ip', '256.256.256.256']) {
        expect(DanmakuProbeReport.isKnownForgedAddress(a), isFalse);
      }
    });
  });

  // ────────────────────────────────────────────────────────────────────
  //  ⑤ 归因不再靠猜类型（task-33：修第 05 项带出的新语义破坏）
  //
  //  # 缺陷（task-29 复核实锤）
  //  ```text
  //  core 的 `_send` 把 TimeoutException 翻成 DanmakuException 之后，
  //  类型信息就丢了 ⇒ `fromError` 里 `error is TimeoutException` 为假
  //    ⇒ 落到兜底 probeFailed（"检测过程本身出错了，请把原文反馈给我们"）。
  //  最常见的「网络超时」因此被错误归因，且原本没有任何门禁盯它。
  //  ```
  //  # 修法（正解②）
  //  ```text
  //  DanmakuException.failureKind（core 在 catch 里直接填）+ osErrorCode，
  //  UI 直接读；文案与归因解耦 —— 以后改文案不会静默改掉归因。
  //  ```
  //  ⚠️ 下面两条正向用例**真的走 core 的翻译**（假 transport 抛真异常），
  //     而不是手写一个带 kind 的 DanmakuException —— 后者证明不了 core 会填。
  // ────────────────────────────────────────────────────────────────────
  group('⑤ 归因读 failureKind（不许再靠猜异常类型）', () {
    test('★★★ 正向：真 TimeoutException → core 翻译 → 超时档（不是 probeFailed）', () async {
      final client = ExternalDanmakuClient(
        transport: _ThrowTransport(TimeoutException('假超时', const Duration(seconds: 8))),
        appId: 'a',
        appSecret: 'b',
      );
      DanmakuException? caught;
      try {
        await client.match(fileName: '第01话');
      } on DanmakuException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull, reason: '前提：假 transport 抛超时必须被翻译成 DanmakuException');
      expect(caught!.failureKind, DanmakuFailureKind.timeout,
          reason: '★★★ core 必须在 catch 处就把归因带上（这就是"文案与归因分离"的落点）');
      expect(caught.message, contains('超时'), reason: '前提：这句就是用户会看到的原文');

      final r = DanmakuProbeReport.fromDanmakuException(caught);
      expect(r.failure, DanmakuProbeFailure.connectionTimeout,
          reason: '★★★ 核心超时原文 ⇒ 必须是"连不上（超时）"档');
      expect(r.failure, isNot(DanmakuProbeFailure.probeFailed),
          reason: '★★★ 改前就是这里错的：超时被说成"检测过程本身出错了"');
      expect(r.failure.title, contains('连接超时'),
          reason: '★ 屏幕上的标题必须说超时（用户据此决定"重试/查网络"）');
      expect(r.remedy, isNot(contains('反馈给我们')),
          reason: '★ 超时不该让用户去反馈日志');
    });

    test('★★★ 正向：真 SocketException(10061) → core 翻译 → 连接被拒档（errno 不许丢）', () async {
      final client = ExternalDanmakuClient(
        transport: _ThrowTransport(SocketException(
          '拒绝',
          osError: const OSError('远程计算机拒绝网络连接。', 10061),
        )),
        appId: 'a',
        appSecret: 'b',
      );
      DanmakuException? caught;
      try {
        await client.match(fileName: '第01话');
      } on DanmakuException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.failureKind, DanmakuFailureKind.socket);
      expect(caught.osErrorCode, 10061,
          reason: '★★ errno 必须随异常带出去 —— 否则上层分不清'
              '「解析失败 / 被拒 / 超时」，只能一律归成"检测出错"');

      final r = DanmakuProbeReport.fromDanmakuException(caught);
      expect(r.failure, DanmakuProbeFailure.connectionRefused,
          reason: '★★★ 10061 ⇒ 连接被拒（这条只有 errno 能分辨，靠文案永远分不出来）');
      expect(r.failure, isNot(DanmakuProbeFailure.probeFailed));
      expect(r.failure, isNot(DanmakuProbeFailure.connectionTimeout),
          reason: '★ 被拒 ≠ 超时：一个该去启动服务，一个该去看网络/代理');
    });

    test('★★★ 反向：陌生异常仍必须 probeFailed（证明没把所有东西都归成超时）', () {
      final r = DanmakuProbeReport.fromError(
        StateError('boom-detail'),
        url: 'https://x',
      );
      expect(r.failure, DanmakuProbeFailure.probeFailed,
          reason: '★★★ 反向判据：认不出来的错必须保持"检测过程本身出错"，'
              '不许因为这次修超时就把它也说成超时');
      expect(r.failure, isNot(DanmakuProbeFailure.connectionTimeout));
    });

    test('★★★ 反向：没带归因的 DanmakuException 也不许被猜成超时', () {
      final r = DanmakuProbeReport.fromDanmakuException(
        DanmakuException('某种完全陌生的失败'),
      );
      expect(r.failure, DanmakuProbeFailure.probeFailed,
          reason: '★★ failureKind == none ⇒ 不猜；改前改后都该是 probeFailed');
      expect(r.failure, isNot(DanmakuProbeFailure.connectionTimeout));
    });

    test('★★ 反向：认不出的 errno 仍是 probeFailed（X4 的老规矩没被顺手改掉）', () {
      final r = DanmakuProbeReport.fromError(
        SocketException('怪错误', osError: const OSError('怪错误', 99999)),
        url: 'https://x',
      );
      expect(r.failure, DanmakuProbeFailure.probeFailed,
          reason: '★ 认不出的 errno 不许归成超时（否则等于替用户断言一个没证据的因果）');
    });
  });
}

/// 抛指定异常的 transport（用来驱动 core 的 `_send` 三个 catch）
class _ThrowTransport implements DanmakuTransport {
  _ThrowTransport(this.error);
  final Object error;
  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async =>
      throw error;
  @override
  void close() {}
}
