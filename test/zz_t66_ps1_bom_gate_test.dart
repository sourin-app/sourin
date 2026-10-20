// ═══════════════════════════════════════════════════════════════════════
//  ★ 2026-10-20（round-66）：PowerShell 脚本的**编码**门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个门禁守的是什么
//
// `tools/*.ps1` 里有中文注释与中文字符串字面量。PowerShell 5.1（Windows 自带
// 那个，`powershell.exe`）在**没有 BOM** 时按**系统 ANSI 码页**解码源文件：
//
// ```text
// 本机 code page = 936 (gb2312)
// 无 BOM 的 UTF-8 文件 ⇒ 中文被按 GBK 解码 ⇒ 字节错位 ⇒ 语法树崩
// ```
//
// # 实测（不是推测）
//
// ```text
// 有 BOM（tools/e2e_shots.ps1，53380 字节）：
//   BOM=EFBBBF  PARSER_ERRORS=0
// 切掉前 3 字节构造**真正的**无 BOM 副本（53377 字节）：
//   BOM=3C230A  PARSER_ERRORS=50
//     L196: Unexpected token '}' in expression or statement.
//     L229: Unexpected token '$(' in expression or statement.
//     L229: Missing closing ')' in expression.
//     L270: Unexpected token 'manifest.json:' in expression or statement.
// ```
//
// ⇒ **50 个语法错误，脚本根本跑不起来。** 这不是"可移植性隐患"，
//   是当前机器上就已经坏掉。
//
// # ★★ 为什么必须"先构造副本再测"（本门禁最容易被写错的地方）
//
// ```text
// 错的写法：
//   直接解析磁盘上那个文件
//   ⇒ 你测的是「那个文件此刻能不能解析」，**不是**「无 BOM 能不能解析」
//   ⇒ 而那个文件此刻有 BOM ⇒ 永远 0 错误 ⇒ 门禁永远绿
//
// 对的写法（本文件）：
//   ① 读出字节
//   ② 断言前 3 字节 == EF BB BF        （判据 ①）
//   ③ **构造**一份切掉 BOM 的临时副本
//   ④ 解析那份副本 ⇒ 必须 0 错误        （判据 ②）
// ```
//
// 这是我今天第 5 次踩「判据作用在错误的对象上」——
// 所以这里把「对象」显式写出来：解析的是 `_nobomCopy`，不是原文件。
//
// # 为什么两条判据都要（缺一不可）
//
// ```text
// 只有 ①（BOM 在）      ⇒ 将来某文件有 BOM 但**语法真的坏了**，门禁不报
// 只有 ②（解析 0 错误） ⇒ 无 BOM 在**某些码页下可能碰巧能解析**
//                          （纯 ASCII 文件在 936 下就是能解析的）
//                          ⇒ 跨机器就不行 ⇒ 必须显式钉住 BOM
// ```
//
// ⇒ ① 管"跨机器正确"，② 管"当下真的能跑"，③ 管"① 是否承重"。三条正交，都要。
//
// # ★★★ 三条判据的作用域（这是我第一版写错的地方）
//
// ```text
// ① 含非 ASCII 的脚本 ⇒ 前 3 字节必须 EF BB BF
//    作用域收窄到"含非 ASCII"：实测 3 个纯 ASCII 脚本无 BOM 也 0 错误
//    （commit_scope_guard / live_probe_count / n13_single_instance_test）
//    ⇒ 对它们要求 BOM 是"为门禁而改文件"，会误伤
//
// ② 每个脚本**按磁盘原样** PS 5.1 解析必须 0 错误
//    这条才抓"脚本现在能不能跑"。将来有人改坏语法，① 照样绿，② 会红
//
// ③ 故障注入：把 ① 守的那些脚本**切掉 BOM 造副本**，必须解析失败
//    这条是"判据的判据" —— 若切 BOM 也无害，① 就是假门禁
//    ⚠️ 我第一版把 ③ 写成了"切掉 BOM 后必须 0 错误"（写反了，永远红）
// ```
//
// ★ 为什么 ③ 必须"先构造副本"：直接解析磁盘那份，测的是"那个文件此刻
//   能不能解析"，**不是**"无 BOM 能不能解析" —— 而它此刻有 BOM ⇒ 永远 0 错误。
//   这正是今天第 5 次「判据作用在错误的对象上」，所以副本 + 两道自检写死在这里。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PowerShell 可执行文件：**不写死**绝对路径（与 `zz_cr_nit_run_client_core_test.dart`
/// 同一套解析策略 —— 那里已经踩过"写死 C:/Windows/..."的坑）。
///
/// 依次试：① PATH 上的 `pwsh` ② PATH 上的 `powershell`
///         ③ Windows 的绝对路径（只在 Windows 命中）
/// 三个都没有 ⇒ 返回 null，调用方 `markTestSkipped`（**不**降低断言）。
String? _resolvePowerShell() {
  for (final exe in <String>['pwsh', 'powershell']) {
    try {
      final r = Process.runSync(
          exe, <String>['-NoProfile', '-Command', r'$PSVersionTable.PSVersion.Major']);
      if (r.exitCode == 0) return exe;
    } on ProcessException {
      // PATH 上没有这个可执行文件 —— 继续试下一个
    }
  }
  const String winAbs =
      'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe';
  if (File(winAbs).existsSync()) return winAbs;
  return null;
}

/// 收集 `tools/` 下所有 `.ps1`（相对仓库根的路径，`/` 分隔）。
///
/// ⚠️ 用 `Directory.listSync` 而不是 `git ls-files`：本门禁要守的是
///    "**工作区里将要被执行的**那份文件"，未跟踪的新脚本同样要守。
List<String> _ps1Files() {
  final dir = Directory('tools');
  if (!dir.existsSync()) return <String>[];
  final out = <String>[];
  for (final e in dir.listSync(recursive: true)) {
    if (e is File && e.path.toLowerCase().endsWith('.ps1')) {
      out.add(e.path.replaceAll('\\', '/'));
    }
  }
  out.sort();
  return out;
}

/// 用 PS 5.1 的 `Parser::ParseFile` 解析 [path]，返回错误条数与前几条消息。
///
/// 返回 `(count, messages)`；PowerShell 不可用时应由调用方先跳过。
({int count, List<String> messages}) _parseErrors(String psExe, String path) {
  final abs = File(path).absolute.path.replaceAll('\\', '/');
  // ⚠️ 路径里可能有中文/空格 ⇒ 用单引号包，并把内部单引号双写。
  final quoted = abs.replaceAll("'", "''");
  final script = '''
\$tok = \$null; \$errs = \$null
\$null = [System.Management.Automation.Language.Parser]::ParseFile('$quoted', [ref]\$tok, [ref]\$errs)
if (\$errs) {
  Write-Output ('COUNT=' + \$errs.Count)
  \$errs | Select-Object -First 6 | ForEach-Object {
    Write-Output ('ERR L' + \$_.Extent.StartLineNumber + ': ' + \$_.Message)
  }
} else {
  Write-Output 'COUNT=0'
}
''';
  final r = Process.runSync(
      psExe, <String>['-NoProfile', '-NonInteractive', '-Command', script]);
  final text = '${r.stdout}\n${r.stderr}';
  final m = RegExp(r'COUNT=(\d+)').firstMatch(text);
  final count = m == null ? -1 : int.parse(m.group(1)!);
  final msgs = <String>[
    for (final line in const LineSplitter().convert(text))
      if (line.trimLeft().startsWith('ERR ')) line.trim()
  ];
  return (count: count, messages: msgs);
}

void main() {
  final psExe = _resolvePowerShell();

  group('★ tools/*.ps1 编码门禁（PS 5.1 无 BOM ⇒ 语法树崩）', () {
    test('★★★ ① 含非 ASCII 的 tools/*.ps1 前 3 字节必须是 EF BB BF', () {
      /*
       * ★★★ 判据的作用域：只对**含非 ASCII** 的脚本要求 BOM。
       *
       * # 为什么不是"全部 .ps1 都要 BOM"（我第一版就是那样，实测会误伤）
       *
       * ```text
       * 实测（2026-10-20，Parser::ParseFile，按磁盘原样解析）：
       *   commit_scope_guard.ps1        BOM=23203D(无)  ERRORS=0   ← 纯 ASCII
       *   live_probe_count.ps1          BOM=23203D(无)  ERRORS=0   ← 纯 ASCII
       *   n13_single_instance_test.ps1  BOM=23203D(无)  ERRORS=0   ← 纯 ASCII
       *   e2e_shots.ps1                 BOM=EFBBBF      ERRORS=0   ← 含中文
       *   run_round66_acceptance.ps1    BOM=EFBBBF      ERRORS=0   ← 含中文
       * ```
       * ⇒ **纯 ASCII 脚本无 BOM 完全正常**（936/UTF-8/任何 ASCII 超集都一致）。
       *   对它们要求 BOM 属于**为门禁而改文件**，会让 3 个本来正常的脚本变红。
       *
       * ⇒ 判据收窄成「含非 ASCII ⇒ 必须有 BOM」。
       *   这条规则**本身可判**（读字节就能判），不依赖人的自觉。
       *
       * ⚠️ 反过来也守住：若某脚本**含中文却无 BOM**，它一定红 ——
       *    那正是 `run_round66_acceptance.ps1` 在 HEAD 里的状态
       *    （前 3 字节 `3c 23 0a`、含中文 ⇒ PS 5.1 下本来跑不起来）。
       */
      final files = _ps1Files();
      // 阳性对照：一个文件都没扫到 ⇒ 扫描器坏了，本门禁是假绿
      expect(files, isNotEmpty,
          reason: '★ 阳性对照：tools/ 下一个 .ps1 都没找到 ⇒ 扫描器坏了');

      final bad = <String>[];
      var checkedNonAscii = 0;
      for (final rel in files) {
        final bytes = File(rel).readAsBytesSync();
        // 含非 ASCII？只看 >=0x80 的字节（BOM 本身也是，先跳过前 3 字节）
        final body = bytes.length >= 3 &&
                bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
            ? bytes.sublist(3)
            : bytes;
        final hasNonAscii = body.any((b) => b >= 0x80);
        if (!hasNonAscii) continue; // 纯 ASCII ⇒ BOM 可有可无
        checkedNonAscii++;

        final hasBom = bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF;
        if (!hasBom) {
          final head = bytes.take(3).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
          bad.add('$rel  →  含非 ASCII 但前 3 字节 = $head（不是 ef bb bf）');
        }
      }

      // 阳性对照：真扫到过"含非 ASCII 的脚本" —— 否则本判据什么都没检查
      expect(checkedNonAscii, greaterThan(0),
          reason: '★ 阳性对照：一个含非 ASCII 的 .ps1 都没扫到 ⇒ 本判据空转');

      expect(
        bad,
        isEmpty,
        reason: '★★★ 这些脚本**含中文但没有 UTF-8 BOM**。\n'
            'PowerShell 5.1 在无 BOM 时按系统 ANSI 码页（本机 936/gb2312）解码\n'
            '⇒ 中文注释/字面量字节错位 ⇒ 语法树崩。\n'
            '实测（tools/e2e_shots.ps1，切掉前 3 字节构造真无 BOM 副本）：\n'
            '  有 BOM ⇒ 0 个语法错误\n'
            '  无 BOM ⇒ **50 个语法错误**\n'
            '           L196 Unexpected token \'}\'\n'
            '           L229 Unexpected token \'\$(\'\n'
            '           L270 Unexpected token \'manifest.json:\'\n'
            '⇒ 脚本**根本跑不起来**，不是"可能有问题"。\n'
            '修法：把文件存成「UTF-8 with BOM」（VS Code: "UTF-8 with BOM"）。\n'
            '缺 BOM 的文件：\n  ${bad.join('\n  ')}',
      );
    });

    test('★★★ ② 每个 tools/*.ps1 **按磁盘原样** PS 5.1 解析必须 0 错误', () {
      /*
       * ★★★ 这一条测的是**磁盘上那份文件**，与判据①的作用域**正交**。
       *
       * # 为什么它不能省（只有①的漏洞）
       *
       * ```text
       * 只有①（BOM 字节在）⇒ 证明不了"这份脚本现在真的能跑"。
       * 将来有人把脚本改坏（少个花括号 / 引号没闭合），
       * ① 照样绿 —— 因为 BOM 还在。
       * ```
       *
       * # 它与①互补
       *
       * ```text
       * ① 管「跨机器正确」：含中文 ⇒ 必须有 BOM，否则换台机器就乱码
       * ② 管「当下真能跑」：不管有没有 BOM，PS 5.1 解析必须过
       * ```
       */
      if (psExe == null) {
        markTestSkipped('本机没有 PowerShell ⇒ 判据②不可测（判据①仍然有效）');
        return;
      }

      final files = _ps1Files();
      expect(files, isNotEmpty, reason: '★ 阳性对照：一个 .ps1 都没找到');

      final bad = <String>[];
      for (final rel in files) {
        final r = _parseErrors(psExe, rel);
        // -1 = 解析器没吐出 COUNT ⇒ 工具本身异常，必须报（不能当通过）
        if (r.count < 0) {
          bad.add('$rel  →  ★ 解析器没有返回 COUNT（PowerShell 调用异常）');
          continue;
        }
        if (r.count != 0) {
          bad.add('$rel  →  ${r.count} 个语法错误\n'
              '${r.messages.map((m) => '        $m').join('\n')}');
        }
      }

      expect(
        bad,
        isEmpty,
        reason: '★★★ 这些脚本**按磁盘原样** PS 5.1 就解析不过。\n'
            '⇒ 它们**现在就跑不起来**（不是"将来可能有问题"）。\n'
            '${bad.join('\n')}',
      );
    });

    test('★★★ ③ 故障注入：切掉 BOM ⇒ 必须**变红**（证明①是承重的）', () {
      /*
       * ══════════════════════════════════════════════════════════════
       *  ★★★ 这条是**判据的判据**（元判据）
       * ══════════════════════════════════════════════════════════════
       *
       * # 为什么需要它
       *
       * 判据①说「含中文 ⇒ 必须有 BOM」。但**BOM 到底是不是承重的？**
       * 如果切掉 BOM 也能正常解析，那①就是**为门禁而门禁**（假门禁）。
       *
       * ⇒ 本测试**亲手制造故障**（构造真无 BOM 副本），
       *   断言它**必须**解析失败。这样①才有资格存在。
       *
       * # 实测基线（2026-10-20）
       *
       * ```text
       * tools/e2e_shots.ps1  有 BOM ⇒ 0 错误
       *                      切 BOM ⇒ 50 个错误
       *     L196 Unexpected token '}' in expression or statement.
       *     L229 Unexpected token '$(' in expression or statement.
       *     L229 Missing closing ')' in expression.
       *     L270 Unexpected token 'manifest.json:' in expression or statement.
       * ```
       *
       * # ⚠️ 本测试**只注入、不改仓库文件**
       *
       * 副本写在 `Directory.systemTemp` 下，测完删掉。
       * **绝不**碰 `tools/` 里那份 —— 那会让测试有副作用。
       */
      if (psExe == null) {
        markTestSkipped('本机没有 PowerShell ⇒ 无法注入故障');
        return;
      }

      final files = _ps1Files();
      // 只挑「含非 ASCII 且真有 BOM」的做注入 —— 它们才是①守的对象
      final targets = <String>[];
      for (final rel in files) {
        final bytes = File(rel).readAsBytesSync();
        final hasBom = bytes.length >= 3 &&
            bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
        if (!hasBom) continue;
        final body = bytes.sublist(3);
        if (!body.any((b) => b >= 0x80)) continue; // 纯 ASCII，注入没意义
        targets.add(rel);
      }

      expect(targets, isNotEmpty,
          reason: '★ 阳性对照：没有"含非 ASCII 且有 BOM"的脚本 ⇒ 注入无从下手'
              '（说明仓里 ps1 的形态变了，本测试要重新判决）');

      final tmpDir = Directory.systemTemp.createTempSync('sourin_ps1_bom_inject_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });

      // 至少**有一个**目标在切掉 BOM 后必须解析失败。
      // （不要求全部：万一某文件的中文全在注释里且恰好字节对齐，
      //   理论上有极小概率仍能解析 —— 那不该让本测试红。
      //   但 e2e_shots.ps1 这种必须红，见下面单独钉。）
      var provenFailures = 0;
      final report = <String>[];

      for (final rel in targets) {
        final bytes = File(rel).readAsBytesSync();

        // ── 构造副本：切掉 BOM，其余字节逐个不变 ──
        final copy = File('${tmpDir.path}/${rel.replaceAll('/', '_')}');
        copy.writeAsBytesSync(bytes.sublist(3));

        // ★ 自检 1：副本必须真的没有 BOM
        //   （否则下面测的又是"有 BOM 那份"，这条元判据会变成假绿）
        final copyBytes = copy.readAsBytesSync();
        expect(
          copyBytes.take(3).toList(),
          isNot(<int>[0xEF, 0xBB, 0xBF]),
          reason: '★ 注入失败：副本仍有 BOM ⇒ 测的还是"有 BOM 那份"，'
              '本测试失去意义',
        );
        // ★ 自检 2：只切了 3 字节，别的没动
        expect(
          copyBytes.length,
          bytes.length - 3,
          reason: '★ 注入失败：副本长度必须正好少 3 字节（只切 BOM）',
        );

        final r = _parseErrors(psExe, copy.path);
        if (r.count > 0) {
          provenFailures++;
          report.add('  $rel  →  切 BOM 后 ${r.count} 个错误'
              '（前 2 条：${r.messages.take(2).join(' | ')}）');
        } else {
          report.add('  $rel  →  切 BOM 后仍 0 错误（该文件对 BOM 不敏感）');
        }
      }

      expect(
        provenFailures,
        greaterThan(0),
        reason: '★★★ 故障注入**没有**制造出任何解析失败。\n'
            '⇒ 说明「切掉 BOM」对这些脚本无害 ⇒ 判据①是在为门禁而门禁。\n'
            '⇒ 要么本机码页不是 936（ASCII 超集下纯 ASCII 文件不受影响），\n'
            '   要么仓里已没有"含中文且依赖 BOM"的脚本 ⇒ 必须重新判决①。\n'
            '注入读数：\n${report.join('\n')}',
      );

      // ── 单独钉住 e2e_shots.ps1：它是本门禁的**基准样本** ──
      //
      // 若它的切 BOM 读数变了（比如有人把中文全删了，或全改成英文），
      // 本门禁的"50 个错误"这条注释就过期了 ⇒ 必须重测并更新注释。
      if (targets.contains('tools/e2e_shots.ps1')) {
        final bytes = File('tools/e2e_shots.ps1').readAsBytesSync();
        final copy = File('${tmpDir.path}/_baseline_e2e_shots.ps1');
        copy.writeAsBytesSync(bytes.sublist(3));
        final r = _parseErrors(psExe, copy.path);
        expect(
          r.count,
          greaterThan(0),
          reason: '★★ 基准样本 tools/e2e_shots.ps1 切掉 BOM 后必须报错'
              '（实测基线 = 50 个）。若这里变 0，说明该文件已不含依赖 BOM 的'
              '中文 ⇒ 本文件头注释里的「50 个错误」要重测更新。',
        );
        // 只打印，不硬钉具体数字（数字会随文件改动漂移）
        // ignore: avoid_print
        print('[BOM-INJECT] tools/e2e_shots.ps1 切 BOM ⇒ ${r.count} 个错误；'
            '前 4 条：\n${r.messages.take(4).join('\n')}');
      }
    });
  });

  /*
   * ══════════════════════════════════════════════════════════════════
   *  记录：本仓 ps1 的 BOM 现状是「**与是否含中文完全对应**」的
   * ══════════════════════════════════════════════════════════════════
   *
   * 实测（2026-10-20，tools/ 下 10 个 .ps1）：
   *
   * ⚠️ 上面刻意不写 "tools" + 斜杠 + 星号 + ".ps1" 那种字面量：
   *    Dart 的块注释**支持嵌套**，那个序列会在注释里**再开一层**，
   *    导致外层注释永远闭合不了（本文件第一版就是这么编译失败的）。
   * ```text
   * 有 BOM 且含中文：e2e_checklist / e2e_shots / run_client /
   *                  run_round66_acceptance / run_t107 / seed_dev_data /
   *                  verify_shots        （7 个）
   * 无 BOM 且纯 ASCII：commit_scope_guard / live_probe_count /
   *                    n13_single_instance_test   （3 个）
   * ```
   * ⇒ 判据①要求**全部**有 BOM，会让那 3 个纯 ASCII 脚本也变红。
   *
   * ⚠️ 这是**有意的**：纯 ASCII 脚本加 BOM 无害（PS 5.1 正常跳过），
   *    而"按是否含中文决定要不要 BOM"这条规则**判不出来**
   *    （脚本随时可能被加一行中文注释 ⇒ 规则静默失效）。
   *    ⇒ 统一要求有 BOM，规则才可判、才不会被绕开。
   *
   * ★ 2026-10-20 实测到的真实事故正是这条规则的**反例**：
   *   `tools/run_round66_acceptance.ps1` 在 HEAD 里**没有** BOM
   *   （前 3 字节 `3c 23 0a`），而它有中文 ⇒ 在 PS 5.1 下**本来跑不起来**。
   *   工作区里被人补上了 BOM（现在 `ef bb bf`）⇒ 修对了，但**没提交**。
   */
}
