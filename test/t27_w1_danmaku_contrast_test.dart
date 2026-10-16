// ═══════════════════════════════════════════════════════════════════════
//  T27-01 弹幕文字看不清：低对比度文本整体提亮 —— 门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 业主原话（图1 = 弹幕设置面板）
//     「1.弹幕这里的文字都看不清」
//
// # 根因（Lead 实测）
//     fig1 面板底色 rgb(20,22,27)；正文色 white38 一档实测 rgb(104,105,109)
//     ⇒ WCAG 对比度 3.30:1（white30/white24 更低：2.93 / 2.54）
//     —— 全部低于 4.5:1 正文线。面板文本色散落使用
//     Colors.white/70/60/54/38（还有两处 TextStyle 干脆没给 color），
//     没有任何一档灰阶约束。
//
// # 本门禁钉住什么
//     ① 统一灰阶常量 DanmakuTextColors（真源在 danmaku_settings_dialog.dart，
//       overlay 通过 import 复用）每档对底色 #14161B 的 WCAG 对比度：
//       正文/次要/说明 ≥ 4.5:1，边框/分隔线 ≥ 1.6:1（弱化但可辨）
//     ② 两个源文件里不得再把 dim white（white24/30/38/54/60/70）或
//       裸 Colors.white 用作颜色实参（边框/分隔线/点状指示器走白名单，
//       逐条给理由；白名单条目必须仍然存在，防止空条款假绿）
//     ③ TextStyle 不许无色：每个 TextStyle( 必须带 color:/foreground:
//       （foreground 是弹幕画笔描边层的合法写法）
//     ④ 阳性对照（铁律②）：扫描器对合成的坏样本必须报警，对好样本必须放行
//       —— 防止正则写错导致门禁空转假绿。
//
// # 对比度怎么算
//     用 Color.computeLuminance()（Flutter 内置的 WCAG 相对亮度实现），
//     本文件只做 (L1+0.05)/(L2+0.05) 的比值；底色用业主截图实测的
//     #14161B（= rgb(20,22,27)，与 Lead 量到的面板底一致）。

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/danmaku_overlay.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

// ── 业主实测底色与验收线 ────────────────────────────────────────────────

/// 弹幕设置面板卡片底色（业主 fig1 实测 rgb(20,22,27)）
const Color kPanelBgForGate = Color(0xFF14161B);

const double kBodyLine = 4.5; // WCAG 正文线
const double kDecorationLine = 1.6; // 边框/分隔线「弱化但可辨」线

// ── 注释剥离（同 t103 / zz_cr_loading_style_test：字符串里的 // 不算）────

String stripComments(String src) {
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
      // 字符串原样拷贝（内容不参与注释判断）。注意：闭引号在这里
      // 已被消费，分支结束必须 continue，否则外层循环底部再 i++
      // 会把闭引号后的第一个字符吞掉（`import 'x.dart';` 丢分号）。
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

// ── 扫描器 ─────────────────────────────────────────────────────────────

/// dim white / 裸白 出现在代码里的匹配（行号 + 内容）
List<String> dimWhiteViolations(String code) {
  final bad = <String>[];
  final dim = RegExp(r'Colors\.white(24|30|38|54|60|70)\b');
  // 裸白：Colors.white 后面直接跟逗号/右括号 = 用作颜色实参
  // （Colors.white.withValues(...) / Colors.white38 不在此列）
  final bare = RegExp(r'Colors\.white\b\s*[,)]');
  final lines = code.split('\n');
  for (var n = 0; n < lines.length; n++) {
    if (dim.hasMatch(lines[n])) {
      bad.add('行${n + 1}: ${lines[n].trim()}');
    } else if (bare.hasMatch(lines[n])) {
      bad.add('行${n + 1}(裸白): ${lines[n].trim()}');
    }
  }
  return bad;
}

/// TextStyle( 必须带 color:/foreground: —— 返回无色的那几处
List<String> colorlessTextStyleViolations(String code) {
  final bad = <String>[];
  final re = RegExp(r'TextStyle\s*\(');
  for (final m in re.allMatches(code)) {
    // 平衡括号取出整个调用体（const TextStyle( … ) 可跨行）
    var depth = 0;
    var end = m.end - 1;
    for (; end < code.length; end++) {
      final ch = code[end];
      if (ch == '(') depth++;
      if (ch == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    final body = code.substring(m.end, math.min(end, code.length));
    if (!body.contains('color:') && !body.contains('foreground:')) {
      final line = code.substring(0, m.start).split('\n').length;
      bad.add('行$line: TextStyle 无 color/foreground（落到主题兜底色）');
    }
  }
  return bad;
}

void main() {
  // ══════════════════════════════════════════════════════════════════
  //  ① 统一灰阶常量：每档对底色的 WCAG 对比度
  // ══════════════════════════════════════════════════════════════════
  group('T27-01 · DanmakuTextColors 对 #14161B 的对比度', () {
    double contrast(Color a, Color b) {
      final l1 = a.computeLuminance();
      final l2 = b.computeLuminance();
      final hi = math.max(l1, l2);
      final lo = math.min(l1, l2);
      return (hi + 0.05) / (lo + 0.05);
    }

    test('正文档 body ≥ 4.5:1（业主实测旧值只有 3.30:1）', () {
      final c = contrast(DanmakuTextColors.body, kPanelBgForGate);
      expect(c, greaterThanOrEqualTo(kBodyLine),
          reason: 'body=${DanmakuTextColors.body} 对比度 $c');
    });

    test('次要档 secondary ≥ 4.5:1（旧 white70 实测 4.02:1，不达标）', () {
      final c = contrast(DanmakuTextColors.secondary, kPanelBgForGate);
      expect(c, greaterThanOrEqualTo(kBodyLine),
          reason: 'secondary=${DanmakuTextColors.secondary} 对比度 $c');
    });

    test('说明/占位档 muted ≥ 4.5:1（旧 white38 实测 3.30:1，不达标）', () {
      final c = contrast(DanmakuTextColors.muted, kPanelBgForGate);
      expect(c, greaterThanOrEqualTo(kBodyLine),
          reason: 'muted=${DanmakuTextColors.muted} 对比度 $c');
    });

    test('边框/分隔线档 border 保持弱化但可辨（≥ 1.6:1）', () {
      final c = contrast(DanmakuTextColors.border, kPanelBgForGate);
      expect(c, greaterThanOrEqualTo(kDecorationLine),
          reason: 'border=${DanmakuTextColors.border} 对比度 $c');
      // 同时不许被提到文本档那么亮 —— 分隔线抢戏同样是视觉缺陷
      expect(c, lessThan(kBodyLine),
          reason: '边框不是文本，不需要也不应该到 4.5:1');
    });

    test('角标文字档 badgeText 对纯黑底 ≥ 4.5:1（任务口径：black55 角标文字对纯黑）', () {
      final c = contrast(DanmakuTextColors.badgeText, Colors.black);
      expect(c, greaterThanOrEqualTo(kBodyLine),
          reason: 'badgeText=${DanmakuTextColors.badgeText} 对比度 $c');
    });

    test('灰阶与 Lead 量到的底色一致（#14161B = rgb(20,22,27)）', () {
      expect(DanmakuTextColors.panelBg, kPanelBgForGate,
          reason: '真源底色必须与业主截图实测一致，对比度才有意义');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 源码扫描：dim white / 裸白 / 无色 TextStyle
  // ══════════════════════════════════════════════════════════════════
  group('T27-01 · 源码门禁', () {
    late String dialogSrc;
    late String overlaySrc;

    setUpAll(() {
      dialogSrc = stripComments(
        File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync(),
      );
      overlaySrc = stripComments(
        File('lib/ui/widgets/danmaku_overlay.dart').readAsStringSync(),
      );
    });

    /// 边框/分隔线白名单：[文件, 锚点行, 理由]
    /// ⚠ 豁免不是免检：条目必须仍然逐字存在（防「改掉了、名单没删」假绿），
    ///   且颜色必须真的来自 DanmakuTextColors.border（写在锚点行里）。
    /*
     * ★ 2026-10-16 重新判决：删掉原「② 段落分隔线」那一条。
     *
     * 为什么删：原锚点是 `child: Divider(height: 1, color: DanmakuTextColors.border),`
     * —— 弹幕设置面板改版时把 7 条满屏横线换成了「分组卡片 + 留白」
     * （见 danmaku_settings_dialog.dart 的 `_group()` / `_gap()`），
     * 那条 Divider 已**不存在**，留着就是空条款（本文件第 3 组断言正是防这个）。
     *
     * ★ 这不是放宽门禁：豁免的对象没了，条款就该撤。
     *   若以后面板里再出现 Divider，本文件第 2 组规则（不许把 white*
     *   当颜色实参）会重新抓到它 —— 那时再按需登记新豁免。
     */
    const borderWhitelist = <List<String>>[
      <String>[
        'lib/ui/widgets/danmaku_settings_dialog.dart',
        'border: Border.all(color: DanmakuTextColors.border),',
        '① 面板卡片外框：1px 弱化描边，与近黑底保持可辨但不抢文本',
      ],
      <String>[
        'lib/ui/widgets/danmaku_settings_dialog.dart',
        'border: Border.all(color: DanmakuTextColors.border),',
        '③ 服务端返回代码块的边框：装饰性容器描边，同①',
      ],
    ];

    /// 状态指示点（关闭态）—— 弱化是语义的一部分
    const dotWhitelist = <List<String>>[
      <String>[
        'lib/ui/widgets/danmaku_settings_dialog.dart',
        'color: on ? Colors.lightBlueAccent : DanmakuTextColors.border,',
        '④ 状态指示点的「关」态：弱化=关，开启态是亮蓝对比分明',
      ],
    ];

    test('danmaku_settings_dialog.dart：不得再把 dim white / 裸白用于文本', () {
      final bad = dimWhiteViolations(dialogSrc);
      expect(bad, isEmpty, reason: '仍有低对比度文本色：\n  ${bad.join('\n  ')}');
    });

    test('danmaku_overlay.dart：不得再把 dim white / 裸白用于文本', () {
      final bad = dimWhiteViolations(overlaySrc);
      expect(bad, isEmpty, reason: '仍有低对比度文本色：\n  ${bad.join('\n  ')}');
    });

    test('danmaku_settings_dialog.dart：TextStyle 不许无色', () {
      final bad = colorlessTextStyleViolations(dialogSrc);
      expect(bad, isEmpty,
          reason: '无色 TextStyle 落到主题兜底，近黑面板上不可控：\n'
              '  ${bad.join('\n  ')}');
    });

    test('danmaku_overlay.dart：TextStyle 不许无色', () {
      final bad = colorlessTextStyleViolations(overlaySrc);
      expect(bad, isEmpty,
          reason: '无色 TextStyle 落到主题兜底，近黑面板上不可控：\n'
              '  ${bad.join('\n  ')}');
    });

    test('白名单条目必须仍然存在（空条款 = 假绿）', () {
      final src = dialogSrc; // 白名单目前只登记了 dialog 的边框/点
      for (final e in [...borderWhitelist, ...dotWhitelist]) {
        expect(src.contains(e[1]), isTrue,
            reason: '${e[0]} 找不到白名单锚点「${e[1]}」—— 该处已改动，'
                '必须重新判决这条豁免（${e[2]}），而不是留着空条款');
      }
    });

    test('overlay 的角标文字必须来自统一灰阶（import 复用真源）', () {
      expect(overlaySrc.contains('DanmakuTextColors.badgeText'), isTrue,
          reason: '_badge 仍写死白色一档 —— 灰阶必须收口到 DanmakuTextColors');
      expect(overlaySrc.contains("import 'danmaku_settings_dialog.dart';"),
          isTrue,
          reason: 'overlay 必须 import 真源，不许复制一份常量');
    });

    test('面板底色收口：不再散落写死 0xFF14161C', () {
      expect(dialogSrc.contains('0xFF14161C'), isFalse,
          reason: '卡片底色必须用 DanmakuTextColors.panelBg（#14161B，'
              '与业主实测一致），不许保留旧的近似值写死');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ 阳性对照：扫描器必须真的能抓到坏样本（防空转假绿）
  // ══════════════════════════════════════════════════════════════════
  group('T27-01 · 扫描器自检（阳性对照）', () {
    test('dim white 样本必须报警', () {
      const bad = 'style: TextStyle(color: Colors.white38, fontSize: 12)';
      expect(dimWhiteViolations(bad), isNotEmpty);
      const badBare = 'style: TextStyle(color: Colors.white)';
      expect(dimWhiteViolations(badBare), isNotEmpty);
    });

    test('灰阶样本必须放行', () {
      const good = 'style: TextStyle(color: DanmakuTextColors.muted)';
      expect(dimWhiteViolations(good), isEmpty);
      expect(colorlessTextStyleViolations(good), isEmpty);
    });

    test('无色 TextStyle 样本必须报警', () {
      const bad = 'style: const TextStyle(fontSize: 13)';
      expect(colorlessTextStyleViolations(bad), isNotEmpty);
    });

    test('多行 TextStyle 也能取到完整调用体（平衡括号）', () {
      const bad = 'style: const TextStyle(\n  fontSize: 13,\n)';
      expect(colorlessTextStyleViolations(bad), isNotEmpty);
      const good = 'style: const TextStyle(\n  color: DanmakuTextColors.body,\n)';
      expect(colorlessTextStyleViolations(good), isEmpty);
    });
  });
}
