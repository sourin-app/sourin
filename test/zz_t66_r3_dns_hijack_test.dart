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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
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
}
