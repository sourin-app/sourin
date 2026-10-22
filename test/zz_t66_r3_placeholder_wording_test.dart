// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R3 文案门禁：**占位态不许用完成态的文案**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条修的是什么（Lead 2026-10-20 裁决「问题 2」）
// ```text
// `_runProbe` 判了 offline 之后、`_diagnose` 还没跑完的那一两秒，
// 面板显示的是：
//     remedy: remedyFor(DanmakuProbeFailure.connectionTimeout)
//   ⇒ 「连不上（超时）⇒ 地址解析出来了但连不过去，
//      通常是「被墙 / 需要代理 / 路由不通」…」
//
// 而此刻：
//   · `_diagnose` **还没跑**
//   · `InternetAddress.lookup` **还没执行**
//   · `Socket.connect` **还没执行**
// ⇒ 界面上那三句陈述的都是**当时尚未发生**的事。
// ```
//
// # 同仓已有正确写法（这是本条门禁的依据，不是我发明的）
// ```text
// `danmaku_source_page.dart:215`
//     remedy: '连不上 —— 正在确认是本机网络还是服务端的问题…'
// ⇒ 只说"连不上"（已观测到）+ "正在确认"（还不知道）。
//   本门禁要求面板**与它一致**。
// ```
//
// # 本门禁钉什么
// ```text
// ① 占位态（还没诊断）的 remedy **不含**断言词：
//      地址解析出来了 / 被墙 / 需要代理 / 路由不通 / 连不过去
// ② 占位态 remedy 必须含「正在确认」（表达"还不知道"）
// ③ ★ 两档对照：诊断**完成**态的 connectionTimeout **应该**有那些词
//      （那是真的：真解析过、真连过）—— 防止门禁写成"凡出现就红"的恒真判据
// ④ 面板与设置页的占位态文案**必须一致**（同一个事实，两处不该两种说法）
// ```
//
// # 故障注入（已实测）
// ```text
// ① 把占位态改回 `remedyFor(connectionTimeout)` ⇒ ① 组红
// ② 把占位态 remedy 改成 `'连不上'`（去掉"正在确认"）⇒ ② 组红
// ③ 把 connectionTimeout 的完成态 remedy 也删掉断言词 ⇒ ③ 组红（对照失效）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

// ── 断言词：只在**有证据**时才能出现的措辞 ────────────────────────────
//
// ⚠️ 这三组词是「陈述已发生的事实」，占位态没有任何证据 ⇒ 不许出现。
const _assertionWords = <String>[
  '地址解析出来了',
  '被墙',
  '需要代理',
  '路由不通',
  '连不过去',
];

/// 剥注释（字符串里的 `//` 不算）
String _strip(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else if (c == "'" || c == '"') {
      final q = c;
      out.write(c);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == '\\') {
          out.write(src[i]);
          i++;
          if (i >= src.length) break;
        }
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
      continue;
    } else {
      out.write(c);
    }
    i++;
  }
  return out.toString();
}

/// 从源码里取「`_runProbe` 里那个占位 report」的 remedy **值**
///
/// 判据用**源码结构**（`detail: '正在分层诊断` 之后紧跟的 `remedy:`），
/// 因为占位态在私有方法里、无法从外部实例化。
///
/// ⚠️ 只取 `remedy:` 之后到**该行字符串结束**（`'...'` 那一对引号），
///    不要用 `),` 当边界 —— 那会跨过注释和后续代码（第一版就是这么假红的：
///    切到了后面 `_diagnose` 里的 `remedyFor(...)`）。
String placeholderRemedyValueIn(String path) {
  final s = _strip(File(path).readAsStringSync());
  final anchor = s.indexOf("detail: '正在分层诊断（DNS / TCP）…'");
  expect(anchor, greaterThanOrEqualTo(0),
      reason: '$path 里找不到占位态 detail —— 判据失效（它被改名/删了？）');
  final remedyAt = s.indexOf('remedy:', anchor);
  expect(remedyAt, greaterThan(anchor),
      reason: '$path 占位态里找不到 remedy: —— 结构变了，需人工复核');
  // 从 remedy: 之后的第一个引号开始，取到配对的闭引号
  final q1 = s.indexOf("'", remedyAt);
  expect(q1, greaterThan(remedyAt), reason: '占位态 remedy 不是字符串字面量');
  var i = q1 + 1;
  while (i < s.length && s[i] != "'") {
    if (s[i] == '\\') i++;
    i++;
  }
  return s.substring(q1, i + 1);
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 占位态：不许有断言词
  // ═══════════════════════════════════════════════════════════════════
  group('① 占位态 remedy 不许陈述尚未发生的事实', () {
    test('★★★ 面板占位态不含任何断言词', () {
      final r = placeholderRemedyValueIn('lib/ui/widgets/danmaku_settings_dialog.dart');
      for (final w in _assertionWords) {
        expect(r.contains(w), isFalse,
            reason: '★★★ 占位态 remedy 里出现「$w」—— 此刻 _diagnose 还没跑，'
                '这句话陈述的事实尚未发生。\n实际 remedy 片段：$r');
      }
      /*
       * ★ 反证：确认我们取到的确实是"占位态那句字面量"，
       *   而不是空字符串导致的假绿。
       *   （辅助函数返回的是**值**，所以查实际内容，不查 `remedy:` 键名）
       */
      expect(r.contains('连不上'), isTrue,
          reason: '★ 切片必须包含占位态的实际文案 —— 否则上面的"不含断言词"是假绿\n'
              '实际切片：$r');
      expect(r.length, greaterThan(10),
          reason: '★ 切片太短 ⇒ 可能没取到内容（假绿）');
    });

    test('★★ 面板占位态必须表达「还不知道」（含"正在确认"）', () {
      final r = placeholderRemedyValueIn('lib/ui/widgets/danmaku_settings_dialog.dart');
      expect(r.contains('正在确认'), isTrue,
          reason: '★★ 占位态要如实表达"还不知道"，而不是给一个结论');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 两档对照：完成态**应该**有那些词（防判据恒真）
  // ═══════════════════════════════════════════════════════════════════
  group('② 完成态（有证据）该有断言词 —— 两档必须能分辨', () {
    test('★★★ 诊断完成后的 connectionTimeout 仍然陈述那些事实', () {
      /*
       * # 为什么这条必须有
       * ```text
       * 如果只写"出现断言词就红"，那条门禁会把**正确**的完成态也判红
       * （完成态确实解析过、确实连过 ⇒ 说这些是**对的**）。
       * ⇒ 必须成对：占位态没有、完成态有。
       *    这样门禁才能分辨「占位」与「完成」两档，而不是一刀切。
       * ```
       */
      final done =
          DanmakuProbeReport.remedyFor(DanmakuProbeFailure.connectionTimeout);
      // 完成态**应该**保留这些事实（它们是诊断出来的）
      expect(done.contains('地址解析出来了'), isTrue,
          reason: '★★★ 完成态必须有这句 —— 它是**诊断出来的事实**，不是编的');
      expect(done.contains('被墙') || done.contains('需要代理'), isTrue,
          reason: '★★ 完成态应给出可能原因');
      // 但它必须用"通常/也可能"这类**留有余地**的措辞
      expect(done.contains('通常') || done.contains('也可能'), isTrue,
          reason: '★★ 即使是完成态，也不该把可能性说成确定性');
    });

    test('★★★ 占位态与完成态**不是同一段文案**', () {
      final ph = placeholderRemedyValueIn('lib/ui/widgets/danmaku_settings_dialog.dart');
      final done =
          DanmakuProbeReport.remedyFor(DanmakuProbeFailure.connectionTimeout);
      /*
       * 占位态是**字面量**（源码里直接写的中性句），
       * 完成态是 `remedyFor(...)` 的返回值。
       * ⇒ 占位态的值里**不许**出现 `remedyFor(`（那会拿到完成态文案）。
       *
       * ⚠️ 只查 `remedyFor(` 这个**调用形态**，不查 `remedy:` 这个键名 ——
       *    切片里天然带键名，查键名会恒真（第一版就是这么假红的）。
       */
      expect(ph.contains('remedyFor('), isFalse,
          reason: '★★★ 占位态不许调用 remedyFor（那会拿到完成态文案）\n'
              '实际片段：$ph');
      // 且两者内容确实不同
      expect(done.contains('正在确认'), isFalse,
          reason: '★ 完成态不该说"正在确认"（它已经确认完了）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 两个文件必须一致（同仓对照）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 面板与设置页的占位态文案必须一致', () {
    test('★★★ 两处占位态都用中性句，且都不含断言词', () {
      final panel = placeholderRemedyValueIn('lib/ui/widgets/danmaku_settings_dialog.dart');
      final page = placeholderRemedyValueIn('lib/ui/settings/danmaku_source_page.dart');
      for (final w in _assertionWords) {
        expect(panel.contains(w), isFalse, reason: '面板占位态含「$w」');
        expect(page.contains(w), isFalse, reason: '设置页占位态含「$w」');
      }
      // 两处都应表达"正在确认"
      expect(panel.contains('正在确认'), isTrue);
      expect(page.contains('正在确认'), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 同类病排查：其它"占位态"有没有用完成态文案
  // ═══════════════════════════════════════════════════════════════════
  group('④ 其它占位态（Lead 要求的同类排查）', () {
    test('★★★ 源码里所有「正在…」的占位文案都不含断言词', () {
      /*
       * 判据：凡是表达"进行中/还不知道"的文案（含「正在」），
       *      都不该同时陈述一个**已完成**的网络事实。
       */
      for (final f in <String>[
        'lib/ui/widgets/danmaku_settings_dialog.dart',
        'lib/ui/settings/danmaku_source_page.dart',
      ]) {
        final src = _strip(File(f).readAsStringSync());
        // 找出所有含"正在"的中文字面量
        final re = RegExp(r"'([^'\\]*(?:\\.[^'\\]*)*)'");
        for (final m in re.allMatches(src)) {
          final body = m.group(1) ?? '';
          if (!body.contains('正在')) continue;
          for (final w in _assertionWords) {
            expect(body.contains(w), isFalse,
                reason: '★★★ $f 里这段"进行中"的文案含「$w」：\n  $body\n'
                    '⇒ 进行中的文案不该陈述已完成的网络事实');
          }
        }
      }
    });
  });
}
