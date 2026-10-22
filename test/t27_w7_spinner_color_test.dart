// ═════════════════════════════════════════════════════════════════════
//  T27-07 转圈发灰：lib/ui 全域 CircularProgressIndicator 颜色门禁
// ═════════════════════════════════════════════════════════════════════
//
// # 业主原话（fig7 等）
//     「加载还是灰圈」
//
// # 根因（w7 取证）
//     ① 全 lib/ui 有多处 CircularProgressIndicator() 不给 color:，
//        落到 progressIndicatorTheme.color（theme_bridge.dart:403-407
//        = colorScheme.primary）。深色板 primary=#E5E5E5（浅灰）、
//        浅色板 primary=#171717（近黑），都不是按「指示器所在真实
//        底色」选的对比色 ⇒ 灰圈/看不清。
//     ② fig7 详情栏顶部的「灰圈观感」经像素取证确认是标题大字形的
//        抗锯齿像素（最佳圆弧覆盖仅 22%，非 spinner）；真 spinner 发灰
//        来源即 ①。
//
// # 本门禁钉住什么
//     ① lib/ui/**/*.dart 全扫描：CircularProgressIndicator( 必须显式
//       给 color:；白名单逐条登记理由，白名单条目必须仍然命中
//       （防空条款假绿）。
//     ② 本任务修复的 6 个文件各含 ≥1 处带 color: 的
//       CircularProgressIndicator（钉住修复不被回退）。
//     ③ 修复色对各自真实硬编码底色 ≥ 4.5:1（WCAG，
//       Color.computeLuminance 计算，同 t27_w1 口径）。
//     ④ 阳性对照（铁律②）：扫描器对坏样本必须报警、好样本必须放行。
//
// # 白名单（scope 外，移交 Lead 裁决，本任务不改 —— Lead 指令⑥）
//     见 [kColorlessWhitelist]。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// ── 验收线与修复色 ─────────────────────────────────────────────────────

const double kBodyLine = 4.5; // WCAG 正文线

/// 弹幕设置面板硬编码深底（DanmakuTextColors.panelBg 同源）
const Color kDanmakuPanelBg = Color(0xFF14161B);

/// bili_import 导入面板硬编码深底
const Color kBiliPanelBg = Color(0xFF14161C);

/// 修复采用的指示器色（与 app_loading.dart _ReadableOn.dark 同源的 #FAFAFA）
const Color kFixIndicator = Color(0xFFFAFAFA);

// ── 注释剥离（同 t27_w1：字符串里的 // 不算注释）────────────────────────

String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      // 行注释：整行替换成空格（保留换行）⇒ 剥注释不改变行号，
      // 扫描器报的行号与编辑器行号一致。
      while (i < src.length && src[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        out.write(src[i] == '\n' ? '\n' : ' ');
        i++;
      }
      out.write('  ');
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

// ── 扫描器 ─────────────────────────────────────────────────────────────

class CpiHit {
  const CpiHit(this.path, this.line, this.hasColor, this.snippet);
  final String path;
  final int line;
  final bool hasColor;
  final String snippet;
}

/// 扫一段源码里的 CircularProgressIndicator( 调用（平衡括号取全参，
/// 支持跨行），返回每处的行号与是否带 color:。
List<CpiHit> scanCpi(String path, String src) {
  final code = stripComments(src);
  final hits = <CpiHit>[];
  final re = RegExp(r'CircularProgressIndicator\s*\(');
  for (final m in re.allMatches(code)) {
    var depth = 0;
    var end = m.end - 1;
    for (; end < code.length; end++) {
      if (code[end] == '(') depth++;
      if (code[end] == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    final body =
        code.substring(m.end, end < code.length ? end + 1 : code.length);
    final line = code.substring(0, m.start).split('\n').length;
    hits.add(CpiHit(path, line, body.contains('color:'), body.trim()));
  }
  return hits;
}

/// 扫 lib/ui 整棵树（相对 flutter test 的工作目录 = 包根）
List<CpiHit> scanTree(String dirPath) {
  final hits = <CpiHit>[];
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return hits;
  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    hits.addAll(scanCpi(f.path.replaceAll('\\', '/'), f.readAsStringSync()));
  }
  return hits;
}

// ── 白名单：空（T27-07 lead 集成阶段已把 scope 外 4 处一并修复）────────
//
// 历史：w7 交付时此表曾登记 scope 外 4 处（browse_page / cast_button /
// emby_page / subtitle_panel）等 Lead 裁决；Lead 复核后按同款模式补修
// （显式 color: colors.onSurface，见各文件 T27-07 注释）⇒ 白名单清空。
// lib 根的 probe_cast.dart 是探针文件，不在 lib/ui 扫描范围内，不在此列。

const Map<String, String> kColorlessWhitelist = {};

/// 本任务修复的 6 个文件 + Lead 集成补漏的 4 个文件：
/// 修复后必须各含 ≥1 处带 color: 的 CPI（钉回退）
const List<String> kFixedMustHaveColor = [
  'lib/ui/widgets/bili_import_dialog.dart',
  // ★★★ 2026-10-19 移出：`lib/ui/widgets/danmaku_settings_dialog.dart`
  //
  // ```text
  // commit `ff54fbe` 把那 4 处 CircularProgressIndicator 全部迁到了
  // `AppInlineSpinner`（行内小圈需要描边按 size 按比例缩放 —— Material 的
  // CPI 做不到：实测 AppLoading 的 stroke 写死 4.0，14px 时描边占直径
  // 28.6%，比原来粗 33%）。
  // ⇒ 该文件现在 **0 处 CPI**（实测，`grep -c CircularProgressIndicator` = 0）。
  //
  // ★ 它**不是**「回退了修复」，而是**换了实现**：
  //   本清单的语义是「钉回退」（修复后必须**仍有**带 color 的 CPI），
  //   对一个已经没有 CPI 的文件，"钉回退"不再有意义。
  //   ⇒ 从清单移除。
  //   ⚠️ **不要**改成「必须 0 处 CPI」——那会禁止将来合理地再引入 CPI。
  //
  // ★★ 钉回退的职责**已转移**，不是丢失：
  //   `test/zz_t66_app_inline_spinner_test.dart` 钉住
  //   「那 5 处必须是 AppInlineSpinner、且 color 原样保留、描边按 size 缩放」。
  //   ⇒ 两边合起来仍然覆盖「这批行内小圈不许被改坏」。
  // ```
  'lib/ui/widgets/provider_import_dialog.dart',
  'lib/ui/widgets/proxy_panel.dart',
  'lib/ui/widgets/source_switch_dialog.dart',
  'lib/ui/widgets/sync_panel.dart',
  // ↓ lead 集成阶段补修（原 w7 清单 §3b scope 外 4 处）
  'lib/ui/browse_page.dart',
  'lib/ui/cast/cast_button.dart',
  'lib/ui/settings/emby_page.dart',
  'lib/ui/subtitle/subtitle_panel.dart',
];

void main() {
  group('T27-07 · 修复色对比度（WCAG ≥ 4.5:1，按各自真实底）', () {
    double contrast(Color a, Color b) {
      final l1 = a.computeLuminance();
      final l2 = b.computeLuminance();
      final hi = l1 > l2 ? l1 : l2;
      final lo = l1 > l2 ? l2 : l1;
      return (hi + 0.05) / (lo + 0.05);
    }

    test('kFixIndicator #FAFAFA 对弹幕面板底 #14161B ≥ 4.5:1', () {
      final c = contrast(kFixIndicator, kDanmakuPanelBg);
      expect(c, greaterThanOrEqualTo(kBodyLine), reason: '实测 $c');
    });

    test('kFixIndicator #FAFAFA 对 bili 面板底 #14161C ≥ 4.5:1', () {
      final c = contrast(kFixIndicator, kBiliPanelBg);
      expect(c, greaterThanOrEqualTo(kBodyLine), reason: '实测 $c');
    });
  });

  group('T27-07 · lib/ui 全域 CircularProgressIndicator 颜色门禁', () {
    final hits = scanTree('lib/ui');
    final colorless = hits.where((h) => !h.hasColor).toList();

    test('扫描器活着：lib/ui 下确实存在 CircularProgressIndicator 调用', () {
      expect(hits, isNotEmpty,
          reason: '扫描路径错误或正则失效 ⇒ 门禁空转假绿');
    });

    test('无 color: 的 CPI 只允许出现在白名单文件里', () {
      final offenders = <String>[];
      for (final h in colorless) {
        if (!kColorlessWhitelist.containsKey(h.path)) {
          offenders.add(
              '${h.path}:${h.line} 无 color:（落到 progressIndicatorTheme 兜底）');
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('白名单每条都必须仍然命中（防空条款假绿）', () {
      final live = colorless.map((h) => h.path).toSet();
      for (final key in kColorlessWhitelist.keys) {
        expect(live, contains(key),
            reason: '白名单 "$key" 已无对应裸 CPI：要么已修复'
                '（请把条目移出白名单），要么条目路径写错');
      }
    });

    test('本任务修复的 6 个文件各含 ≥1 处带 color: 的 CPI（钉修复）', () {
      final withColor = <String, int>{};
      for (final h in hits) {
        if (h.hasColor) {
          withColor[h.path] = (withColor[h.path] ?? 0) + 1;
        }
      }
      for (final p in kFixedMustHaveColor) {
        expect(withColor[p] ?? 0, greaterThanOrEqualTo(1),
            reason: '$p 里没有任何带 color: 的 CircularProgressIndicator'
                ' —— 修复被回退？');
      }
    });
  });

  group('T27-07 · 阳性对照（铁律②：扫描器必须能抓坏放好）', () {
    test('坏样本（无 color）必须报警', () {
      final hits = scanCpi('synthetic.dart',
          'Widget w = CircularProgressIndicator(strokeWidth: 2);');
      expect(hits, hasLength(1));
      expect(hits.single.hasColor, isFalse);
    });

    test('好样本（带 color）必须放行', () {
      final hits = scanCpi(
          'synthetic.dart',
          'Widget w = CircularProgressIndicator('
              'color: Color(0xFFFAFAFA), strokeWidth: 2);');
      expect(hits, hasLength(1));
      expect(hits.single.hasColor, isTrue);
    });
  });
}
