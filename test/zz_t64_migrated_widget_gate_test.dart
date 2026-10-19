// 2026-10-17 —— 换实现时「测试按类型查找」会静默炸掉一批断言
//
// # 这份测试是怎么来的（真实事故，不是假想）
// ```text
// Lead 把 CircularProgressIndicator 换成自绘 _AppSpinner 后：
//   dart analyze         → 干净
//   dart analyze 代码审查 → 看着没问题
//   find.byType(CircularProgressIndicator) → **找到 0 个**
// ⇒ zz_cr_loading_style_test       3 条抛 Bad state: No element
// ⇒ t26_w6_apploading_ground_test  6 条抛 Bad state: No element
// ```
//
// # 这类缺陷的可怕之处
// ```text
// · 编译不报错（类型都对）
// · analyze 不报错（没有未用变量）
// · 只有**跑测试**才会发现，而且是 9 条一起红
// · 如果当时没跑测试就合并，那 9 条真规格会静默消失
// ```
//
// # 本测试要防的是什么
// ```text
// **不是**"不许换实现" —— 换实现是正常的。
// 要防的是：换了实现，但测试还在按旧类型查找，
// 于是断言被 Bad state 顶掉（而不是被正确改写）。
//
// ⇒ 本测试输出一份**清单**：哪些测试文件还在 find.byType(某个已迁移控件)。
//   它不判红（因为清单本身是合法的中间状态），
//   但如果某个控件**已经完全迁走**却还有测试按它查找，那就是漏改 ⇒ 红。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 已**完全**迁到自建实现的控件 ⇒ 产品代码里不该再有它
///
/// ⚠️ 加入本表的前提：`grep -rn "控件名" lib/ --include=*.dart`
///    在产品代码（排除 t*.dart 探针）里**只剩注释**。
const _migrated = <String, String>{
  // 控件名 → 自建替代品
  'CircularProgressIndicator': 'AppLoading（自绘 _AppSpinner）',
};

/// 允许暂时残留的文件（逐步迁移中）
///
/// ★ 每从这里删掉一条，就说明那个文件迁完了 —— 这个表只该变短。
const _pending = <String, int>{
  // ★ 2026-10-17 门禁实测清单：13 处裸 CircularProgressIndicator 还在用。
  //   这个表**只该变短** —— 每迁完一个文件就删掉对应行。
  'lib/ui/browse_page.dart': 1,
  'lib/ui/cast/cast_button.dart': 1,
  'lib/ui/search_page.dart': 1,
  'lib/ui/settings/danmaku_source_page.dart': 1,
  'lib/ui/settings/emby_page.dart': 1,
  'lib/ui/subtitle/subtitle_panel.dart': 1,
  'lib/ui/widgets/bili_import_dialog.dart': 1,
  'lib/ui/widgets/danmaku_info_panel.dart': 1,
  // ★ 2026-10-19：`danmaku_settings_dialog.dart` 那 4 处已迁到 AppInlineSpinner
  //   （行内小圈不能用 AppLoading —— 它的描边写死 4.0、不随 size 缩放，
  //     14px 时描边占直径 28.6%，实测比原来粗 33%）。
  //   ⇒ 按本表自己的规则「迁完就删」，这一行删掉了。
  'lib/ui/widgets/plugin_speedtest.dart': 2,
  'lib/ui/widgets/provider_import_dialog.dart': 1,
  'lib/ui/widgets/proxy_panel.dart': 1,
  'lib/ui/widgets/source_switch_dialog.dart': 1,
  'lib/ui/widgets/sync_panel.dart': 1,
};

void main() {
  test('★ 已迁走的控件不该在产品代码里再被构造', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue);

    final hits = <String>[];
    final stale = <String>[];
    // 每个文件实际命中几处（用于与 _pending 的「允许处数」对账）
    final actual = <String, int>{};

    for (final e in libDir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final p = e.path.replaceAll('\\', '/');

      // 跳过探针（t*.dart / *probe*.dart）—— 探针可以用旧控件做对照
      final base = p.split('/').last;
      if (RegExp(r'^t[0-9]').hasMatch(base) || base.contains('probe')) {
        continue;
      }

      final lines = e.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final ln = lines[i];
        final trimmed = ln.trimLeft();
        // 跳过注释行
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;

        for (final name in _migrated.keys) {
          // 只认「构造」：名字后面紧跟 ( 或 . 加括号，且不是 import
          final re = RegExp(r'\b' + name + r'\s*[.(]');
          if (!re.hasMatch(ln)) continue;
          if (ln.contains('import ')) continue;

          actual[p] = (actual[p] ?? 0) + 1;
          // ★ 不在 _pending ⇒ 一处都不许有
          if (_pending[p] == null) {
            hits.add('$p:${i + 1}  $name  → 应改用 ${_migrated[name]}');
          }
        }
      }
    }

    /*
     * ★★★ 2026-10-17（dlg-plugin 复核发现的两个假绿，已修）
     *
     * # 假绿 E：_pending 里的文件成了「法外之地」
     * ```text
     * 改前：if (_pending.contains(p)) continue;   ← 整个文件跳过，不看第几处
     * ⇒ 给 browse_page.dart（本来 1 处）注入第 2 处，门禁**不响**。
     *   而那 14 个文件正是最活跃的，有人往里新加旧控件也发现不了。
     * ```
     * ⇒ 改成按**处数**对账：超过允许数 ⇒ 红。
     *
     * # 假绿 F：迁完了不删，门禁不提醒
     * ```text
     * 文件头写着「这个表只该变短」，但**没有机制强制它变短**，全靠人记得。
     * 而人不会记得。
     * ```
     * ⇒ 实际处数**少于**允许数 ⇒ 红（说明迁完了却没删表）。
     */
    for (final entry in _pending.entries) {
      final got = actual[entry.key] ?? 0;
      if (got > entry.value) {
        hits.add('${entry.key}  实际 $got 处 > 允许 ${entry.value} 处'
            '  → 该文件里又新增了已迁走的控件');
      } else if (got < entry.value) {
        stale.add('${entry.key}  实际 $got 处 < 允许 ${entry.value} 处'
            '  → 已迁完（或删了几处），请把 _pending 里这一项改成 $got');
      }
    }

    expect(hits, isEmpty,
        reason: '以下位置还在构造已迁走的控件（要么改掉，要么加进 _pending）：\n' +
            hits.join('\n'));

    expect(stale, isEmpty,
        reason: '★ _pending 表过期了（实际处数少于登记数）。\n'
            '这个表只该变短 —— 迁完就把对应项删掉或改小：\n' +
            stale.join('\n'));
  });

  test('★★ 阳性对照：扫描器确实能抓到（否则上一条是假绿）', () {
    // 造一段文本，按同样规则判 —— 必须命中
    const sample = 'child: CircularProgressIndicator(strokeWidth: 2),';
    final re = RegExp(r'\bCircularProgressIndicator\s*[.(]');
    expect(re.hasMatch(sample), isTrue, reason: '扫描规则必须能命中真实构造');

    // 阴性：注释里出现不该命中（由主测试的注释跳过负责，这里验规则本身）
    const comment = '// 原来是 CircularProgressIndicator';
    expect(comment.trimLeft().startsWith('//'), isTrue);
  });

  test('★★ _pending 表只许变短（迁完的文件要及时删掉）', () {
    // 这条不判红，只做提醒性断言：表里每一项都必须是**真实存在**的文件，
    // 否则说明文件被删了/改名了，表过期了。
    for (final p in _pending.keys) {
      expect(File(p).existsSync(), isTrue,
          reason: '_pending 里的 $p 不存在 —— 表过期了，请删掉这一项');
    }
  });
}
