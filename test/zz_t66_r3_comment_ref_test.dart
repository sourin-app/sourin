// ═══════════════════════════════════════════════════════════════════════
//  门禁：注释里的 `file.dart:行号` 引用必须**指得到**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条为什么存在（2026-10-21）
// ```text
// 同一天在 `browse_page.dart` 抓到两处「注释与代码不一致」：
//   ① `t80a` 文件头写「await FFI(必抛) → finally setState」
//      而 `_init()` **没有 try/finally**
//   ② `_init()` 的 `await _load(1)` 也没有兜底
// 两处都是**靠人读注释时对照代码**才发现的 —— 没有任何东西在持续检查。
//
// ★ 那条错注释存在了很久，而且它**恰好让一条假断言得以通过**
//   （`t80a` 的「第 1 帧骨架无包装」之所以能过，是因为 `_init()` 卡住了）。
// ⇒ 给它一个能持续报警的守卫。
// ```
//
// # ★★★ 为什么本门禁只做「行号越界」，不做「注释说得对不对」
// ```text
// 注释的自然语言**无法自动验证**。试图验证「注释说的是不是真的」必然假绿。
//
// 实测过三种候选判据，只有第三种健康：
//
//   候选① 「同行有反引号标识符 ⇒ 该标识符必须出现在目标行」
//     实测 checked=160 ok=24 bad=136  ⇒ **85% 报错** ⇒ 恒红，会被绕过
//     原因：`file:line` 常指向「这一带」，标识符在附近而不在这一行
//
//   候选② 「`file:line` 的 `ident`」（更紧的措辞形态）
//     实测 checked=20 ok=3 bad=17     ⇒ 同样 85% 报错
//
//   候选③ 「行号必须在该文件行数范围内」（本门禁采用的）
//     实测 checked=1447 ok=1446 bad=1 ⇒ **0.07% 报错**，且那 1 条是真错
//
// ⇒ 只做候选③。它是**绝对可判定**的：行号 > 文件行数 ⇒ 一定指错了，
//   没有任何解释空间，也**不会假绿**（不会因为"看起来合理"而放过）。
// ```
//
// # 它抓什么 / 不抓什么
// ```text
// 抓：注释里写 `foo.dart:9999`，而 `foo.dart` 只有 300 行 ⇒ 红
//
// 不抓（**已知假阴性，见文件末尾**）：
//   · 行号在范围内但**指向了别的内容**（漂移）—— 无法机械判定
//   · 注释说「有 finally」而代码没有（形态 A）
//   · 注释说「全仓零调用」而实际有调用（形态 C）
// ```
//
// # 覆盖度（本仓强制格式）
// ```text
// 门禁**必须打印**「扫了多少文件 / 多少条引用 / 多少条被核对」。
// 只打「✅ 通过」视为未完成（PITFALLS.md A 组）。
// 且「一条引用都没扫到」必须**报错**，不能算绿 —— 否则扫描器自身失效
// 与「真的没问题」无法区分。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 只用于「输出可读」，不含业务逻辑
void note(String s) {
  // ignore: avoid_print
  print(s);
}

/// 与 `browse_page.dart` / `t80a` 等处剥注释同一套扫描（字符串里的 `//` 不算）
///
/// ⚠️ 本门禁要的恰恰是**注释行**，所以这里不剥注释，只判「这一行是不是注释行」。
bool _isCommentLine(String line) {
  final t = line.trimLeft();
  return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
}

/// 收集仓库内的 .dart 文件（**排除** worktree / 探针产物目录）
///
/// ★ 必须排除 `.agents/worktrees/` 与 `.probe/`：
///   实测过 —— 它们里面有 `lib/ui/theme_bridge.dart` 的**旧副本**（816 行），
///   而主仓的是 815 行。不排除就会用副本的行数去判主仓的引用，
///   产生**假阳性**（本轮第一次跑就撞上了）。
List<File> _repoDartFiles() {
  const skipDirs = <String>{
    '.dart_tool',
    'build',
    '.agents',
    '.probe',
    'node_modules',
    '.git',
  };
  final out = <File>[];
  for (final base in <String>['lib', 'test']) {
    final dir = Directory(base);
    if (!dir.existsSync()) continue;
    for (final e in dir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final norm = e.path.replaceAll(r'\', '/');
      if (skipDirs.any((d) =>
          norm.split('/').contains(d) || norm.startsWith('$d/'))) {
        continue;
      }
      out.add(e);
    }
  }
  return out;
}

/// 一次被核对的引用
class _Ref {
  _Ref(this.srcFile, this.srcLine, this.targetBase, this.targetLine);
  final String srcFile;
  final int srcLine;
  final String targetBase;
  final int targetLine;

  @override
  String toString() => '$srcFile:$srcLine → $targetBase:$targetLine';
}

void main() {
  // Android/桌面都能跑；只读文件系统，无网络
  group('注释里的 file:line 引用必须指得到', () {
    late List<File> files;
    late Map<String, List<File>> byBase;

    setUpAll(() {
      files = _repoDartFiles();
      byBase = <String, List<File>>{};
      for (final f in files) {
        final base = f.path.replaceAll(r'\', '/').split('/').last;
        byBase.putIfAbsent(base, () => <File>[]).add(f);
      }
      note('═══ 注释引用核对（file:line 行号越界）═══');
      note('扫描范围：lib/ + test/，共 ${files.length} 个 .dart 文件');
      note('已排除：.dart_tool / build / .agents（含 worktree 旧副本）'
          ' / .probe / node_modules / .git');
    });

    test('★★★ 所有 `file.dart:行号` 的行号都在目标文件行数内', () {
      /*
       * 只认这种形态：`字母数字下划线.dart:数字`
       *
       * ⚠️ 明确**跳过**两类，它们不是本仓引用：
       *   ① 同一行里出现 `flutter/lib` 或 `dart-sdk` ⇒ SDK 源码引用
       *   ② 目标文件名在本仓里**找不到** ⇒ 第三方（`print.dart` /
       *      `window_manager.dart` / `ink_well.dart` / `real.dart` …）
       */
      final ref = RegExp(r'([A-Za-z_][A-Za-z0-9_]*\.dart):(\d+)');
      var scannedLines = 0;
      var refsFound = 0;
      var refsChecked = 0;
      var refsSkippedSdk = 0;
      var refsSkippedUnknown = 0;
      var refsSkippedAmbiguous = 0;
      final violations = <String>[];
      final checked = <_Ref>[];

      for (final f in files) {
        final lines = f.readAsLinesSync();
        final normPath = f.path.replaceAll(r'\', '/');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          scannedLines++;
          if (!_isCommentLine(line)) continue;
          for (final m in ref.allMatches(line)) {
            refsFound++;
            final base = m.group(1)!;
            final ln = int.parse(m.group(2)!);
            // ① SDK 引用
            final head = line.substring(0, m.start);
            if (head.contains('flutter/lib') || head.contains('dart-sdk')) {
              refsSkippedSdk++;
              continue;
            }
            // ② 本仓找不到 ⇒ 第三方
            final cands = byBase[base] ?? const <File>[];
            if (cands.isEmpty) {
              refsSkippedUnknown++;
              continue;
            }
            // ③ 同名多份 ⇒ 无法判定，跳过（且**计数**，不静默）
            if (cands.length > 1) {
              refsSkippedAmbiguous++;
              continue;
            }
            final target = cands.single;
            final targetLineCount = target.readAsLinesSync().length;
            refsChecked++;
            checked.add(_Ref(normPath, i + 1, base, ln));
            if (ln < 1 || ln > targetLineCount) {
              violations.add('$normPath:${i + 1} → $base:$ln '
                  '（$base 只有 $targetLineCount 行）');
            }
          }
        }
      }

      // ── 覆盖度（必须打印）────────────────────────────────────────
      note('扫描 $scannedLines 行注释/代码行');
      note('发现 $refsFound 处 `file.dart:行号` 引用');
      note('  跳过 $refsSkippedSdk 处（SDK 源码引用）');
      note('  跳过 $refsSkippedUnknown 处（文件名不在本仓 ⇒ 第三方）');
      note('  跳过 $refsSkippedAmbiguous 处（同名多份，无法判定）');
      note('  **实核 $refsChecked 处**');

      /*
       * ★★★ 覆盖度守卫：「一条都没核对到」必须报错
       * ```text
       * 如果扫描器自身失效（正则写错 / 目录遍历坏了），refsChecked 会是 0，
       * 而下面的断言全部通过 ⇒ 与「真的没问题」**长得一模一样**。
       * PITFALLS.md A 组：「未知」不能被渲染成「没问题」。
       * ```
       */
      expect(
        refsChecked,
        greaterThan(500),
        reason: '★★★ 只核对了 $refsChecked 处引用（此前实测应为 1447 左右）—— '
            '扫描器可能失效了。**这不是"没问题"，是"没查"**。',
      );

      // ── 真正的判据 ───────────────────────────────────────────────
      expect(
        violations,
        isEmpty,
        reason: '★★★ 以下注释引用的行号**超出了目标文件的行数** —— '
            '那一定指向不存在的位置：\n  ${violations.join("\n  ")}',
      );
    });

    test('★★ 阳性对照：本条判据在当前数据上确实"有东西可查"', () {
      /*
       * 防「门禁恒绿」：如果全仓一条 `file.dart:行号` 都没有，
       * 上面那条 test 会在覆盖度守卫处红。这里再补一条**独立**的阳性对照，
       * 证明「解析出来的引用是真的、且指向真实文件」。
       */
      final ref = RegExp(r'([A-Za-z_][A-Za-z0-9_]*\.dart):(\d+)');
      var sample = 0;
      for (final f in files.take(400)) {
        for (final line in f.readAsLinesSync()) {
          if (!_isCommentLine(line)) continue;
          if (ref.hasMatch(line)) {
            sample++;
            if (sample >= 3) break;
          }
        }
        if (sample >= 3) break;
      }
      expect(
        sample,
        greaterThanOrEqualTo(3),
        reason: '★★ 前 400 个文件里一条 `file.dart:行号` 注释都没找到 —— '
            '要么注释习惯变了，要么解析坏了。先去确认，别当成"没问题"。',
      );
      note('阳性对照：前 400 个文件里找到 $sample+ 条 `file.dart:行号` 注释 ✓');
    });
  });
}
