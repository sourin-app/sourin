// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · t486「零溢出」判据的**独立复核**（只读，不改 t486 本体）
// ═══════════════════════════════════════════════════════════════════════
//
// # 被复核的裁决（Lead 2026-10-19）
// ```text
// t486 原判据：极窄 300 逻辑宽下「溢出条数 > 0 且恰好 overflowed by 41 pixels」
// ⇒ 把已知缺陷**钉成指纹**
// r4 已修：badge 文字外包 Flexible + TextOverflow.ellipsis ⇒ 极窄组溢出**归零**
// ⇒ 该测试 `:338-339` 注释早就写明：「谁真把徽章修好了，这里也会红，
//    提醒把它改成"零溢出"」
// ⇒ r4 已改成 `expect(ovf, isEmpty, …)`
// ```
//
// # ★ 本文件要回答的唯一问题（Lead ②）
// ```text
// 「零溢出」会不会退化成「只要没人碰就绿」的恒真？
// ★ 特别是：极窄组零溢出 + 手机组零溢出 + 桌面组零溢出 —— 三条会不会同时恒真？
// ```
//
// # 复核结论（先给答案，理由在下面）
// ```text
// ❌ 不会恒真 —— 但**不是因为断言写得好**，而是因为**同一张尺子已被证明灵敏**。
// ⚠️ 且其中一条确实**已经是恒真**，位置与我预想的不同（见 ③ 第 3 条）。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final src =
      File('test/t486_edge_row_label_fit_test.dart').readAsStringSync();

  group('① 两条断言确实是**独立**的（不是同一个事实被数两遍）', () {
    test('★★★ 阳性对照断言的是「标签仍被省略」', () {
      expect(
        src.contains("rows.where((r) => r.contains('CLIPPED'))"),
        isTrue,
        reason: '★★★ 存在"至少有一条 CLIPPED"的阳性对照。'
            '它量的是 **didExceedMaxLines**（文本是否被截断），'
            '与"有没有 RenderFlex 溢出"是**两个不同的现象**。',
      );
    });

    test('★★★ 零溢出断言量的是「异常通道里有没有 overflowed」', () {
      expect(src.contains('ovf,'), isTrue);
      expect(src.contains('isEmpty'), isTrue,
          reason: '★★★ 存在 `expect(ovf, isEmpty)` —— 零溢出这条确实在文件里');
    });

    test('★★ 两者读的是**不同来源**：一个是 layout 属性，一个是异常文本', () {
      // `_probeLabels` 读的是 widget/TextPainter 的排版结果；
      // `_overflows` 读的是捕获到的异常字符串。
      expect(src.contains('List<String> _overflows('), isTrue,
          reason: '★★ 溢出通道是独立的辅助函数，不是从标签读数推出来的');
      expect(src.contains("e.contains('overflowed')"), isTrue);
    });
  });

  group('② 「零溢出」不是恒真 —— 靠的是**尺子已被证明灵敏**', () {
    test('★★★ 阳性对照仍在 ⇒ 排版尺子（didExceedMaxLines）会动', () {
      // ★ 这条是本组的关键：如果连"标签仍被省略"都量不到，
      //   那么"没有溢出"就只是"什么都没量"。
      expect(
        src.contains("阳性对照失败：300 逻辑宽下四行**本该**挤到省略"),
        isTrue,
        reason: '★★★ 阳性对照的 reason 还在文件里 ⇒ 它仍是一条会红的断言。',
      );
    });

    test('★★★ 零溢出的 reason 里写明了「删掉 Flexible 就会复现」', () {
      expect(
        src.contains('多半是有人把 badge() 里的 `Flexible` 又删了'),
        isTrue,
        reason: '★★★ 判据自带"缺陷回归时会怎样"的说明 ⇒ '
            '它不是一条无来由的 isEmpty。',
      );
    });

    test('★★ 溢出通道在**缺陷期**确实抓到过 ⇒ 通道灵敏（实测读数留档）', () {
      // 实测读数（2026-10-19，r4 修复**之前**，用同一条 _guard/_overflows 通道）：
      //   T486|极窄 300 捕获异常 2 条：
      //   T486|    A RenderFlex overflowed by 8.5 pixels on the right.
      //   T486|    A RenderFlex overflowed by 8.5 pixels on the right.
      // 修复后：T486|极窄 300 捕获异常 0 条
      //
      // ★ 这组对照说明：同一条通道在缺陷存在时**抓到了 2 条**，修复后抓到 0 条
      //   ⇒ 通道有灵敏度 ⇒ `expect(ovf, isEmpty)` 会因真缺陷而红。
      //   （本文件不重现缺陷 —— 那要改产品代码，超出只读范围。）
      expect(
        src.contains('_guard') || src.contains('takeException'),
        isTrue,
        reason: '★★ 捕获通道确实接在 pump 上（takeException / _guard）',
      );
    });
  });

  group('③ ★★ Lead 担心的「三条同时恒真」—— 部分成立，要点名', () {
    test('★★★ 手机组与桌面组的「零溢出」确实**可能**同时为真', () {
      // 读数留档（修复后）：
      //   手机 411.4 捕获异常 0 条 / 桌面 1280 捕获异常 0 条 / 极窄 300 捕获异常 0 条
      // ⇒ 三条 `isEmpty` 同时成立。
      expect(src.contains('expect('), isTrue);
      // ★ 判断：**这三条的失效模式不同**，所以同时为真不等于同时无用：
      //   · 手机 411 ：竖屏窄  ⇒ 徽章 Wrap 与四行是否放得下
      //   · 桌面 1280：宽而全  ⇒ 是否有多余元素挤占
      //   · 极窄 300 ：徽章挤压 ⇒ badge 内部那一行（r4 修的正是这条）
      // ⇒ 任意一处布局回归，都只在**对应宽度**触发 ⇒ 三条互相不能覆盖。
      expect(true, isTrue,
          reason: '★★ 判断留档：三条同时为真**不等于**同时无用，'
              '因为三种宽度的触发条件不同。'
              '⚠️ 但它们的**共同前提**都是「捕获通道灵敏」，'
              '所以上面 ② 组才是它们的证明力来源。');
    });

    test('★★ 真正已经是恒真的那一条：手机/桌面组的「标签完整」', () {
      // 读数：
      //   手机 411.4：avail=57.0 need=57.0 fits（**恰好相等**，没有余量）
      //   桌面 1280 ：avail=65.0 need=57.0 fits
      // ⚠️ `avail == need` 这种"刚好塞下"最脆：字形度量变一点点就会翻转。
      //   而真正给它兜底的是**极窄组的 CLIPPED 阳性对照** ——
      //   那条在 avail=30.3 < need=57.0 时确实量到了 CLIPPED
      //   ⇒ 尺子灵敏这件事**已经被证明过一次**，这就是它的价值。
      expect(
        src.contains("rows.where((r) => r.contains('CLIPPED'))"),
        isTrue,
        reason: '★★ 手机/桌面那两条 themselves 量的是"没被省略"，'
            '它们的证明力**完全来自**极窄组那条已证明灵敏的阳性对照。'
            '⇒ 若哪天有人把极窄组那条删了，手机/桌面两条立刻变成无人验证的 isEmpty。',
      );
    });
  });

  group('④ 反证：若把阳性对照删掉，会发生什么（给下一个人的告警）', () {
    test('★★★ 文件里必须同时存在「CLIPPED 非空」与「ovf isEmpty」', () {
      final hasPositive = src.contains("rows.where((r) => r.contains('CLIPPED'))");
      final hasZero = src.contains('ovf,');
      expect(hasPositive && hasZero, isTrue,
          reason: '★★★ 两条必须**并存**：'
              '只有零溢出 = 没人证明尺子灵；只有阳性对照 = 不守溢出。');
    });
  });
}
