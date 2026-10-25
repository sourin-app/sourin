// ═══════════════════════════════════════════════════════════════════════
//  行尾门禁（EOL gate）—— 扫**工作树**，专抓「CRLF 让门禁失效」这一类
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它（真实事故，不是假想）
// ```text
// 2026-10-25：`test/t73_bili_wiring_test.dart` 的 ④ 从绿变红。
// 根因不是产品改坏，而是被匹配的文件在工作树里是 `\r\n`：
//   门禁用 `_page.substring(i, i+700)` 取 Esc 分支再做 indexOf 次序断言，
//   而 `\r` 让同样的逻辑内容整体**变长**、把 `_episodeElseif` 挤出窗口
//   ⇒ indexOf == -1 ⇒ 误红。
// 那次是"人肉 + 交叉复核"才定位到的。本条门禁的目的就是让它以后**机械可抓**。
// ```
//
// # 与 `t74_cover_image_test` 的 E1 是什么关系（不重复，且互补）
// ```text
// E1 读的是 **`git show HEAD:<path>` 的 blob**，判的是"入库内容"：
//   · 豁免文件 blob 必须纯 CRLF；
//   · 另有 4 个**硬编码**文件的 blob 不许有 `\r`。
// 它**看不见**：
//   · 工作树被编辑器改成 CRLF 而 blob 仍是 LF 的情形（本次事故正是这种）；
//   · 未跟踪的新文件（HEAD 里没有 blob ⇒ 无从检查）；
//   · 上面 4 个文件之外的任何文件。
// ⇒ 本文件补的正是"**工作树**、**全量**、`lib/**` + `test/**`"这一格。
//   两者都在才完整：E1 管"别把 CRLF 提交进库"，本文件管"别让工作树的行尾
//   悄悄改变门禁的匹配结果"。
// ```
//
// # 判据（三条 + 两条防腐）
// ```text
// ① 除白名单外，任何 lib/**/*.dart、test/**/*.dart 都不许含 `\r\n`；
// ② 任何被扫到的文件都不许**混合行尾**（既有 CRLF 又有裸 LF）——
//    混合行尾是"半转"的典型形态，比纯 CRLF 更难发现；
// ③ 白名单必须**逐条有效**：文件存在、且现在**真的**是 CRLF。
//    （转成 LF 之后忘了删条目 ⇒ 条目过期 ⇒ 红，逼你删）
// ④ 白名单条目数必须 == 27（防膨胀）；
// ⑤ 覆盖度自检：扫到的文件数必须 ≥ 800（本仓 lib+test 实测 826）。
//    这条防的是"扫描器悄悄什么都没扫到 ⇒ 0 违规 ⇒ 假绿"。
// ```
//
// # 白名单为什么是这 27 条（逐条理由见 `_whitelist`）
// ```text
// 1 条 = 有意的 CRLF：`lib/ui/live_page.dart`（`.gitattributes` 里 `-text -eol`，
//        理由见该文件 :56-72：不许整文件重写，否则 blame 全失效；t74 E1 钉着）。
// 26 条 = **存量** CRLF：本批开始之前工作树就是 CRLF，且**不在本批改动范围**
//        （本批只统一了 10 个"本批改动过且是 CRLF"的文件）。
//        它们在 git index 里是 LF（`*.dart text eol=lf` 会让入库归一），
//        只是本机工作树因历史检出而保留 CRLF ⇒ 属"环境残留"，不是本批缺陷。
//        ⚠️ 这 26 条是**待清理**清单，不是"永久豁免"：
//           谁要改这些文件，顺手转成 LF 并把条目删掉（③ 会逼你删）。
// ```
//
// # 跑法
// ```powershell
// flutter test test/zz_eol_gate_test.dart --concurrency=1
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 白名单：路径 → 为什么它现在允许是 CRLF
///
/// ⚠️ **新增条目之前先问：能不能直接把这个文件转成 LF？**
///   能 ⇒ 转（一行命令的事），**不要**往这里加。
///   不能（例如豁免文件必须保持 CRLF 以保住 blame）⇒ 才加，并写清理由。
const Map<String, String> _whitelist = <String, String>{
  // ── 有意 CRLF（唯一真豁免）──────────────────────────────────────────
  'lib/ui/live_page.dart':
      '`.gitattributes` 里是 `-text -eol`：有意保持 CRLF。理由见该文件 :56-72 '
          '（整文件重写会让 blame 全失效）。t74 E1 钉着它的 blob 必须纯 CRLF。',

  // ── 存量 CRLF（本批范围外；待清理清单，不是永久豁免）────────────────
  'lib/design/theme/app_theme.dart': '存量：本批之前的工作树就是 CRLF，不在本批改动集',
  'lib/design/theme/app_theme_data.dart': '存量：同上',
  'lib/design/widgets/app_icon_button.dart': '存量：同上',
  'lib/design/widgets/app_outlined_button.dart': '存量：同上',
  'lib/design/widgets/app_switch.dart': '存量：同上',
  'lib/design/widgets/app_text_button.dart': '存量：同上',
  'lib/design/widgets/app_text_field.dart': '存量：同上',
  'lib/design/widgets/app_tooltip_slider.dart': '存量：同上',
  'lib/ui/app_update_bootstrap.dart': '存量：同上',
  'lib/ui/cast/cast_button.dart': '存量：同上',
  'lib/ui/widgets/plugin_speedtest.dart': '存量：同上',
  'test/t134_live_source_groups_test.dart': '存量：同上',
  'test/t27_w3_download_button_style_test.dart': '存量：同上',
  'test/t67_stage1_data.dart': '存量：同上',
  'test/toast_host_mounted_test.dart': '存量：同上',
  'test/zz_t66_app_colors_test.dart': '存量：同上',
  'test/zz_t66_glass_detail_icon_test.dart': '存量：同上',
  'test/zz_t66_glass_detail_outlined_test.dart': '存量：同上',
  'test/zz_t66_glass_detail_test.dart': '存量：同上',
  'test/zz_t66_glass_follow_test.dart': '存量：同上',
  'test/zz_t66_glass_toast_test.dart': '存量：同上',
  'test/zz_t66_layout_home_test.dart': '存量：同上',
  'test/zz_t66_live_avail_states_test.dart': '存量：同上',
  'test/zz_t66_live_availability_cache_test.dart': '存量：同上',
  'test/zz_t66_live_embed_bounds_test.dart': '存量：同上',
  'test/zz_t66_live_pause_intent_test.dart': '存量：同上',
};

/// 白名单条目数的期望值（防膨胀；改这个数必须同时改本文件头部的说明）
const int _kWhitelistSize = 27;

/// 覆盖度下限（本仓 `lib/` + `test/` 实测 826 个 .dart）
const int _kMinScanned = 800;

/// 一个文件的扫描结果
class _Eol {
  const _Eol(this.path, this.crlf, this.bareLf);

  final String path;
  final int crlf;

  /// **裸** LF 数 = 总 `\n` 数 − `\r\n` 数
  final int bareLf;

  bool get isPureCrlf => crlf > 0 && bareLf == 0;
  bool get isPureLf => crlf == 0;
  bool get isMixed => crlf > 0 && bareLf > 0;
}

/// 扫描工作树里 `lib/**` 与 `test/**` 的 `.dart`
///
/// ⚠️ 必须按**字节**读：`readAsString` 会在解码时把 `\r\n` 保留成 `\r\n`，
///   但只要有人误用 `LineSplitter` 或 `trim()` 就再也看不到了。
List<_Eol> _scanWorktree() {
  final out = <_Eol>[];
  for (final root in <String>['lib', 'test']) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = e.path.replaceAll(Platform.pathSeparator, '/');
      if (!rel.endsWith('.dart')) continue;
      // 纵深防御：即使将来有人在 lib/ 下放构建产物目录，也不要误判
      if (rel.contains('/build/') ||
          rel.contains('/.dart_tool/') ||
          rel.contains('/.probe/') ||
          rel.contains('/.agents/')) {
        continue;
      }
      final b = e.readAsBytesSync();
      final crlf = _countAll(b, 0x0D);
      var nl = 0;
      for (var i = 0; i < b.length; i++) {
        if (b[i] == 0x0A) nl++;
      }
      out.add(_Eol(rel, crlf, nl - crlf));
    }
  }
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// 数 `\r` 的出现次数（CRLF 的判定只需要它：本仓不存在"孤立 CR"的合理场景，
/// 真出现也会因为裸 LF 计数不变而被 ② 的混合判据或 ① 的 CRLF 判据抓出来）
int _countAll(List<int> b, int byte) {
  var n = 0;
  for (final x in b) {
    if (x == byte) n++;
  }
  return n;
}

void main() {
  final scanned = _scanWorktree();

  /// 报表：**先打印覆盖度**，再打印结论。
  ///
  /// 为什么"打印 0 违规"不算数：扫描器一旦因为路径写错而一个文件都没扫到，
  /// 违规数也是 0 —— 那是假绿。⇒ 必须同时能看到"扫了多少"。
  void report() {
    final hits = scanned.where((e) => _whitelist.containsKey(e.path)).toList();
    final violations = scanned
        .where((e) => e.crlf > 0 && !_whitelist.containsKey(e.path))
        .toList();
    final mixed = scanned.where((e) => e.isMixed).toList();
    // ignore: avoid_print
    print('EOL_GATE|scanned=${scanned.length} '
        'whitelist_hits=${hits.length}/$_kWhitelistSize '
        'nonwhitelist_crlf=${violations.length} '
        'mixed=${mixed.length}');
    for (final v in violations) {
      // ignore: avoid_print
      print('EOL_GATE|VIOLATION ${v.path} CRLF=${v.crlf} bareLF=${v.bareLf}');
    }
    for (final m in mixed) {
      // ignore: avoid_print
      print('EOL_GATE|MIXED ${m.path} CRLF=${m.crlf} bareLF=${m.bareLf}');
    }
  }

  test('① 覆盖度自检：真的扫到了 lib/ 与 test/ 下的 .dart', () {
    report();
    expect(scanned.length, greaterThanOrEqualTo(_kMinScanned),
        reason: '★★★ 只扫到 ${scanned.length} 个 .dart（期望 ≥$_kMinScanned）'
            '⇒ 扫描器大概率没读到东西。\n'
            '这一条防的是"0 违规 = 没扫到"的假绿：'
            '门禁必须能证明自己**看过**文件，而不是在一片空白上通过。');
    // 两个根目录都必须有产出（防止只扫到 lib/ 就宣布通过）
    expect(scanned.any((e) => e.path.startsWith('lib/')), isTrue,
        reason: '★ 一个 lib/ 下的文件都没扫到 ⇒ 根路径写错了');
    expect(scanned.any((e) => e.path.startsWith('test/')), isTrue,
        reason: '★ 一个 test/ 下的文件都没扫到 ⇒ 根路径写错了');
  });

  test('② 除白名单外，不许有 CRLF（工作树，lib/ + test/）', () {
    final bad = scanned
        .where((e) => e.crlf > 0 && !_whitelist.containsKey(e.path))
        .toList();
    expect(bad, isEmpty,
        reason: '★★★ 下列文件在工作树里是 CRLF，且不在白名单：\n'
            '${bad.map((e) => '  · ${e.path}（CRLF=${e.crlf}, 裸LF=${e.bareLf}）').join('\n')}\n'
            '为什么这是缺陷：`\\r` 会让"按 \\n 做多行匹配"的门禁**静默失效**——'
            '2026-10-25 `t73_bili_wiring_test` ④ 就是这么误红的'
            '（`substring` 窗口被 \\r 撑大 ⇒ indexOf=-1）。\n'
            '修法：把这个文件转成 LF（`git config core.autocrlf` 已是 true 也救不了'
            '已检出的工作树副本），**不要**往 _whitelist 里加。');
  });

  test('③ 不许出现混合行尾（CRLF 与裸 LF 混在同一个文件里）', () {
    final mixed = scanned.where((e) => e.isMixed).toList();
    expect(mixed, isEmpty,
        reason: '★★★ 下列文件**混合行尾**（既有 \\r\\n 又有裸 \\n）：\n'
            '${mixed.map((e) => '  · ${e.path}（CRLF=${e.crlf}, 裸LF=${e.bareLf}）').join('\n')}\n'
            '混合行尾比纯 CRLF 更难发现：一部分行号会偏移、一部分不会 ⇒'
            '按行取内容的门禁会得到"有时对有时错"的结论。\n'
            '修法：整文件统一成 LF（不要逐行改）。');
  });

  test('④ 白名单必须逐条有效：文件存在，且现在**真的**是纯 CRLF', () {
    final stale = <String>[];
    final missing = <String>[];
    for (final entry in _whitelist.entries) {
      final f = File(entry.key);
      if (!f.existsSync()) {
        missing.add(entry.key);
        continue;
      }
      final hit = scanned.where((e) => e.path == entry.key).toList();
      if (hit.isEmpty) {
        // 文件在磁盘上但没被扫到 ⇒ 扫描器路径规则有问题
        missing.add('${entry.key}（存在但未被扫描到）');
        continue;
      }
      if (!hit.first.isPureCrlf) stale.add(entry.key);
    }
    expect(missing, isEmpty,
        reason: '★★ 白名单里有文件不存在/没被扫到：$missing\n'
            '⇒ 白名单在掩护一个不存在的路径（改路径或删条目）。'
            '理由：${{for (final m in missing) m: _whitelist[m]}}');
    expect(stale, isEmpty,
        reason: '★★★ 下列白名单条目已经**过期**（文件现在不是纯 CRLF）：$stale\n'
            '说明它们已经被转成 LF 了 —— 这是好事，但**条目必须删掉**：\n'
            '留着它等于给"下次再变回 CRLF"留了后门，也让 ⑤ 的条目数失去意义。\n'
            '删除时同步把 _kWhitelistSize 减 1 并更新本文件头部的分布说明。');
  });

  test('⑤ 白名单条目数必须 == $_kWhitelistSize（防膨胀）', () {
    expect(_whitelist.length, _kWhitelistSize,
        reason: '★★★ 白名单变成了 ${_whitelist.length} 条（应为 $_kWhitelistSize）。\n'
            '**新增条目之前先把它转成 LF** —— 白名单是"存量待清理清单"，'
            '不是"允许 CRLF 的名册"：\n'
            '  · 本批就是因为容忍了工作树 CRLF，才让 `t73 ④` 静默误红；\n'
            '  · 条目一多，这条门禁就会退化成"什么都允许"。\n'
            '确实必须保留 CRLF（例如 git blame 约束）⇒ 才加，并写清理由。');
  });

  test('⑥ 扫描器自检：同一份代码上 CRLF 与 LF 都能读对', () {
    // 正面样本：豁免文件（整文件 CRLF）
    final crlfSample =
        scanned.firstWhere((e) => e.path == 'lib/ui/live_page.dart');
    expect(crlfSample.crlf, greaterThan(1000),
        reason: '★ 扫描器读不出 live_page.dart 的 CRLF ⇒ 它对 `\\r` 不敏感，'
            '那 ② 的"0 违规"就毫无意义');
    expect(crlfSample.bareLf, 0, reason: '★ 豁免文件不该有裸 LF');

    // 反面样本：本文件自身（必须是纯 LF，否则本门禁自己就违规）
    final self = scanned.firstWhere((e) => e.path == 'test/zz_eol_gate_test.dart');
    expect(self.crlf, 0,
        reason: '★★ 本门禁文件自己是 CRLF —— 请把它转成 LF（它不该出现在白名单里）');
    expect(self.bareLf, greaterThan(50),
        reason: '★ 本文件竟然没有裸 LF ⇒ 扫描读的是空内容');
  });
}
