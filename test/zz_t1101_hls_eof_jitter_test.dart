import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/player_page.dart';

void main() {
  // ─────────────────────────────────────────────────────────────
  //  真实现场原文（Owner 日志逐字）
  // ─────────────────────────────────────────────────────────────
  const eofMsg = 'tcp: ffurl_read returned 0xdfb9b0bb';
  const eofDecimal = 'tcp: ffurl_read returned -541478725';

  group('⓪ 日志措辞（入口不许预设"中断"）', () {
    /*
     * ★ 2026-11-01 真机实测踩到：入口那行写死「播放中断（已有画面…）」时，
     *   续片/抑制两种情况日志里会先落一行误导性的"中断"（横幅其实没弹）。
     *   后来人据此会以为 bug 复发。⇒ 入口必须是中性措辞、定性由各分支补写。
     */
    test('★ 注入证红：入口改回"播放中断" ⇒ 本条必须红', () {
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      // 入口那行（had 三元的第一支）必须是中性措辞
      expect(
        code.contains("had ? '播放中断（已有画面，非阻断）"),
        isFalse,
        reason: '入口不许预设"中断"——续片/抑制会先落一行误导性的"播放中断"',
      );
      expect(
        code.contains("had ? '播放期 stream.error（待定性）"),
        isTrue,
        reason: '入口必须是中性事实（待定性），定性交给续片/抑制/兜底各分支',
      );
      // 兜底定性仍在：真断流的日志里必须有"播放中断"
      expect(
        code.contains("'播放中断（已有画面，非阻断）：\$e'"),
        isTrue,
        reason: '兜底分支仍要定性为播放中断，否则真断流日志缺定性',
      );
    });
  });

  group('① EOF 识别（只认错误码）', () {
    test('认补码形态 0xdfb9b0bb 与十进制真值 -541478725', () {
      expect(playerErrorIsEof(eofMsg), isTrue);
      expect(playerErrorIsEof(eofDecimal), isTrue);
      // 大小写不敏感
      expect(playerErrorIsEof('tcp: ffurl_read returned 0xDFB9B0BB'), isTrue);
    });

    test('★ 注入证红：把补码常数改错 ⇒ EOF 识别必须失效', () {
      // 这里钉的是"常数与 ffmpeg 定义对齐"这件事本身：
      // |kMpvErrorEof| + kMpvErrorEofUnsigned 必须 == 2^32 = 4294967296
      // （Dart int 是 64 位，不会回绕，所以必须显式写 2^32 而不是 0）
      expect(-kMpvErrorEof + kMpvErrorEofUnsigned, 4294967296,
          reason: '★ 补码关系：|真值| + 补码 == 2^32');
      // 反例：一个不是 EOF 的错误码不许被认成 EOF
      expect(playerErrorIsEof('tcp: ffurl_read returned 0xdeadbeef'), isFalse);
      expect(playerErrorIsEof('Failed to open http://127.0.0.1:63534/s/x.'), isFalse);
    });
  });

  group('② HLS 判定', () {
    test('kind=hls / mpegurl / .m3u8 URL 都算 HLS', () {
      expect(playerStreamIsHls(kind: 'hls'), isTrue);
      expect(playerStreamIsHls(kind: 'application/vnd.apple.mpegurl'), isTrue);
      expect(playerStreamIsHls(url: 'https://a.cn/asp/hls/main/main.m3u8'), isTrue);
      // 带 query 的 m3u8 也要认（真直链都带 sign= 等参数）
      expect(
        playerStreamIsHls(url: 'https://a.cn/x/index.m3u8?sign=abc&t=179'),
        isTrue,
      );
    });

    test('mp4 / 普通 URL 不算 HLS', () {
      expect(playerStreamIsHls(kind: 'mp4', url: 'https://a.cn/v.mp4'), isFalse);
      expect(playerStreamIsHls(), isFalse);
    });
  });

  group('③ 分片 EOF 归并（护栏 A：三条缺一不可）', () {
    test('已有画面 + HLS + EOF ⇒ 归为续片', () {
      expect(
        playerErrorIsHlsSegmentEof(eofMsg, sawFirstFrame: true, isHls: true),
        isTrue,
      );
    });

    test('★ 起播阶段（未出画面）的 EOF 不许吞', () {
      expect(
        playerErrorIsHlsSegmentEof(eofMsg, sawFirstFrame: false, isHls: true),
        isFalse,
        reason: '★ 起播期 EOF 可能是空清单/坏地址，必须如实报错',
      );
    });

    test('★ 非 HLS 的 EOF 不许吞', () {
      expect(
        playerErrorIsHlsSegmentEof(eofMsg, sawFirstFrame: true, isHls: false),
        isFalse,
        reason: '★ 非分片流的 EOF 是真读到尾/真断，必须如实报错',
      );
    });

    test('HLS 但不是 EOF ⇒ 不许吞', () {
      expect(
        playerErrorIsHlsSegmentEof(
          'Failed to open https://a.cn/x.m3u8.',
          sawFirstFrame: true,
          isHls: true,
        ),
        isFalse,
      );
    });
  });

  group('④ 抖动抑制纯函数', () {
    test('窗口外首次 ⇒ 不抑制', () {
      final d = playerErrorJitterDecide(
        key: 'k',
        previousCount: null,
        sinceLast: null,
      );
      expect(d.suppress, isFalse);
      expect(d.count, 1);
    });

    test('窗口内重复 ⇒ 抑制；达阈值 ⇒ 升级如实报错', () {
      // 第 2、3 次：抑制
      expect(
        playerErrorJitterDecide(
          key: 'k',
          previousCount: 1,
          sinceLast: const Duration(seconds: 10),
        ).suppress,
        isTrue,
      );
      expect(
        playerErrorJitterDecide(
          key: 'k',
          previousCount: 2,
          sinceLast: const Duration(seconds: 10),
        ).suppress,
        isTrue,
      );
      // 第 4 次：升级，不再抑制
      final esc = playerErrorJitterDecide(
        key: 'k',
        previousCount: 3,
        sinceLast: const Duration(seconds: 10),
      );
      expect(esc.suppress, isFalse, reason: '★ 连续 4 次必须升级如实报错');
      expect(esc.count, 4);
    });

    test('超过 30s 窗口 ⇒ 重新计数（不抑制）', () {
      final d = playerErrorJitterDecide(
        key: 'k',
        previousCount: 9,
        sinceLast: const Duration(seconds: 31),
      );
      expect(d.suppress, isFalse);
      expect(d.count, 1);
    });

    test('★ 注入证红：把窗口改成 5s ⇒ 30s 间隔不再重置（证明窗口真在生效）', () {
      // 断言窗口常量本身是 30s
      expect(kErrorJitterWindow, const Duration(seconds: 30));
      // 边界内（恰好 30s）仍算窗口内 ⇒ 抑制
      final inside = playerErrorJitterDecide(
        key: 'k',
        previousCount: 1,
        sinceLast: kErrorJitterWindow,
      );
      expect(inside.suppress, isTrue);
    });

    test('★ 注入证红：升级阈值被改大 ⇒ 第 4 次会被错误抑制', () {
      expect(kErrorJitterEscalateAt, 4);
      // 阈值前一次仍抑制，阈值这一次不抑制 —— 钉住"阈值处翻转"这个行为
      expect(
        playerErrorJitterDecide(
          key: 'k',
          previousCount: kErrorJitterEscalateAt - 2,
          sinceLast: const Duration(seconds: 1),
        ).suppress,
        isTrue,
      );
      expect(
        playerErrorJitterDecide(
          key: 'k',
          previousCount: kErrorJitterEscalateAt - 1,
          sinceLast: const Duration(seconds: 1),
        ).suppress,
        isFalse,
      );
    });
  });

  group('⑤ 去重键归一化', () {
    test('同一类抖动收敛到同一个 key', () {
      final a = playerErrorJitterKey('tcp: ffurl_read returned 0xdfb9b0bb');
      final b = playerErrorJitterKey('tcp: ffurl_read returned 0xdfb9b0bb');
      expect(a, b);
    });

    test('★ 注入证红：不做归一化 ⇒ 带不同地址的同源错误会变成不同 key', () {
      // 归一化后，指针/地址差异被抹掉 ⇒ 仍同一个 key
      final a = playerErrorJitterKey('tcp: error at 0x7ffd0012 code 0xdfb9b0bb');
      final b = playerErrorJitterKey('tcp: error at 0x5aab8834 code 0xdfb9b0bb');
      expect(a, b, reason: '★ 地址不同但骨架相同，必须收敛成同一个 key');
      // 而**不同**的错误不许收敛成同一个 key
      final c = playerErrorJitterKey('Failed to open http://x/y.');
      expect(a, isNot(c));
    });
  });

  group('⑥ 护栏 B：严重错误不得被抑制', () {
    test('HTTP 4xx/5xx / DNS / 超时 一律判为 severe', () {
      expect(playerErrorIsSevere('HTTP 404 Not Found'), isTrue);
      expect(playerErrorIsSevere('server returned 503'), isTrue);
      expect(playerErrorIsSevere('DNS lookup failed'), isTrue);
      expect(playerErrorIsSevere('connection timed out'), isTrue);
      expect(playerErrorIsSevere('Connection refused'), isTrue);
    });

    test('★ 分片 EOF 不是 severe（否则会被当成真断流弹出来）', () {
      expect(playerErrorIsSevere(eofMsg), isFalse);
    });

    test('★ 注入证红：若去掉 severe 判据，抑制会吞掉 404', () {
      // 这条钉的是"severe 与 suppress 是**两个独立**判据"：
      // 即便抖动窗口内重复，severe 也必须让它如实报错。
      final d = playerErrorJitterDecide(
        key: playerErrorJitterKey('HTTP 404'),
        previousCount: 1,
        sinceLast: const Duration(seconds: 1),
      );
      // 纯函数层面它会抑制（抑制只管重复）…
      expect(d.suppress, isTrue);
      // …但调用方**必须**用 severe 兜住它 ⇒ 这里钉住 severe 为真
      expect(playerErrorIsSevere('HTTP 404'), isTrue,
          reason: '★ 抑制只能压抖动，压不住 404/超时这类真故障');
    });
  });
}
