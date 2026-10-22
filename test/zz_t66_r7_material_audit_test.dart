// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R7「material 化做完了吗」—— **只读取证门禁**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这份门禁存在的理由
// ```text
// R7 在 §0.2 里只写了「✅ 已答」—— 回答了 Owner，但没有**读数**。
// 「标了『已答』就交付」与「标了『未确定』就交付」是同一个错：
//   后者是没查就承认不知道，前者是没查就宣称知道。
// ⇒ 本文件把当时的真实读数**钉住**，让下一个人不必重新考古，
//   也让「已答」两个字从此有出处。
//
// # ⚠️ 本文件是**只读型**门禁：它不改产品代码，只证明「现状还是我读到的那样」
//   ⇒ 因此它断言的是**事实**，不是**愿望**。
//   哪天真去做了某一项，这里的读数会红 —— 那是**该红**（要同步更新本文件），
//   不是缺陷。
//
// # 本轮实测（2026-09-19，Windows，grep/read 原始输出见交付报告）
// ```text
// A 产品根 widget（lib/shell.dart:1941）      = WidgetsApp(     ← 不是 MaterialApp
// B MaterialApp( 在 lib/ 非注释               = 39   全部是探针/备份文件
// C MaterialApp( 在**产品**代码（剔探针）      = **0**
// D theme_bridge 真实 import 在 lib/          = 2
// E theme_bridge 真实 import 在 test/         = 14
// F colorScheme 在产品 lib/（剔探针非注释）    = **185**
// G package:flutter/material.dart 在 *.dart   = **0**
// ```
//
// ★ 与计划里「剩 3 项」的说法**不一致**（这是本门禁最重要的事实）：
// ```text
// 计划 §0.2 写： 剩 3 项（首页 3 控件 / 彻底去 MaterialApp / 删 theme_bridge）
// 实测：         「彻底去 MaterialApp」**已完成**（A/C 两项读数）——
//                计划同一份文件里既列了「✅ MaterialApp → WidgetsApp（8157a03）」
//                又把「彻底移除 MaterialApp」列进待办 ⇒ 两条自相矛盾，
//                而**待办那一行已经过期**（M4 已于 2026-10-18 完成，见 shell.dart:60
//                与 app_theme.dart:256-261 的实测记录）。
// ```
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String libRoot;

  /// 读一个 lib/ 下文件的全部源码
  String read(String rel) =>
      File('lib/$rel').readAsStringSync();

  // ★ 2026-10-22：`lineAt(rel, n)` 已删 —— 唯一的调用方是「shell.dart:1941」那个
  //   行号锚，本次把它换成按内容的锚（`child: ScrollConfiguration(`）。行号锚会漂，
  //   留着它只会诱导下一个人再写一条"第 N 行必须写着 X"的判据。

  setUpAll(() {
    libRoot = Directory.current.path;
    expect(Directory('lib').existsSync(), isTrue,
        reason: '必须在仓库根运行（找的是 lib/）');
  });

  // ────────────────────────────────────────────────────────────────────
  // ① 材料化第一项：产品根到底是不是 MaterialApp
  // ────────────────────────────────────────────────────────────────────
  group('① 产品根：WidgetsApp（计划里那行「待办」已过期）', () {
    test('★★★ lib/shell.dart 的 App 根是 WidgetsApp，不是 MaterialApp', () {
      /*
       * ★ 2026-10-22（PR #32 复核线程 1/9）：锚从「1941 行必须是 WidgetsApp(」
       *   改成「找到 ScrollConfiguration 那一行，再往下的窗口里必须出现 WidgetsApp(」。
       *   原来那个行号锚在本次给 App 外面包一层 ScrollConfiguration 后立刻假红
       *   （1941 变成了 `child: ScrollConfiguration(`）—— **行号锚天生会漂**，
       *   而它想守的语义是"根是 WidgetsApp"，不是"第 1941 行写着 WidgetsApp"。
       */
      final lines = read('shell.dart').split(RegExp(r'\r?\n'));
      final at = lines.indexWhere((l) => l.contains('child: ScrollConfiguration('));
      expect(at, greaterThan(0),
          reason: '★ 找不到 `child: ScrollConfiguration(` ⇒ 外层那层没挂上'
              '（或写法变了），要更新本门禁');
      expect(
        lines[at + 1].trim(),
        startsWith('behavior: const _SourinScrollBehavior()'),
        reason: '★ ScrollConfiguration 挂的不是 _SourinScrollBehavior() ⇒ '
            'arm64 Clip.none 那组修复又失效了',
      );
      final window =
          lines.sublist(at, (at + 40).clamp(0, lines.length)).join('\n');
      expect(window, contains('WidgetsApp('),
          reason: '★ ScrollConfiguration 下面 40 行内没有 WidgetsApp( ⇒ 根换了，'
              '本门禁要跟着更新并改写结论');
      expect(window, isNot(contains('MaterialApp(')),
          reason: '若产品根改回 MaterialApp，本门禁要跟着更新并改写结论');
    });

    test('★★★ shell.dart 全文没有 MaterialApp( 的**真实调用**', () {
      final real = read('shell.dart')
          .split(RegExp(r'\r?\n'))
          .asMap()
          .entries
          .where((e) => e.value.contains('MaterialApp('))
          // 剔掉注释行：grep 给你的是行，不是结构（AGENTS.md §8）
          .where((e) => !RegExp(r'^\s*(///|//|\*)').hasMatch(e.value.trimLeft()))
          .map((e) => e.key + 1)
          .toList();
      expect(real, isEmpty,
          reason: 'shell.dart 出现 MaterialApp( 的真实调用于第 $real 行');
    });

    test('★★ 全产品 lib/（剔探针）没有任何 MaterialApp( 真实调用', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final base = f.uri.pathSegments.last;
        // 探针与 spike 备份不是产品入口
        if (RegExp(r'^(t\d|probe_|merge_view|delivery_test|main\.dart$)')
            .hasMatch(base)) {
          continue;
        }
        f.readAsLinesSync().asMap().forEach((i, line) {
          final t = line.trimLeft();
          if (t.startsWith('///') || t.startsWith('//') || t.startsWith('*')) {
            return;
          }
          if (t.contains('MaterialApp(')) {
            offenders.add('$base:${i + 1}');
          }
        });
      }
      expect(offenders, isEmpty,
          reason: '这些产品文件仍在真实调用 MaterialApp：$offenders');
    });

    test('★★★ 自检：上面那条扫描**真的扫到了 ui/ 与 core/**（防空转假绿）', () {
      // ⚠️ 本条是 2026-10-19 故障注入抓出来的：扫描最初用 listSync()（非递归），
      //   而 lib/ 顶层的 .dart 全是探针 ⇒ 剔掉探针后**一个文件都不剩** ⇒
      //   「产品代码没有 MaterialApp」这条恒为真，注入真实调用也不红。
      // ⇒ 这里钉住「扫描面非空」，否则上面那条又会被当成有效判据。
      final scanned = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map((f) => f.uri.pathSegments.last)
          .where((b) => !RegExp(
              r'^(t\d|probe_|merge_view|delivery_test|main\.dart$)').hasMatch(b))
          .toSet();
      expect(scanned, contains('home_page.dart'),
          reason: '扫描面必须覆盖 lib/ui/，否则上面两条都是空转');
      expect(scanned, contains('shell.dart'));
      expect(scanned.length, greaterThan(20),
          reason: '产品文件数实测 > 20；只剩个位数说明扫描又退化了');
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // ② 材料化第二项：首页 3 个 Material 控件（**读数 = 仍在，不是我说改完**）
  // ────────────────────────────────────────────────────────────────────
  group('② 首页 Material 控件：仍在，且都在真实路径上', () {
    // 三个真实控件（均来自 material_ui，故不违反「必须 import material_ui」）
    const controls = <String, String>{
      'ActionChip': '直播条入口（home_page.dart:2804）',
      'TextButton': '「查看全部」按钮（home_page.dart:2851，_MoreButton 内）',
    };

    controls.forEach((name, where) {
      test('★★★ 首页仍有 $name（$where）—— 未完成项，不许报成已完成', () {
        final src = read('ui/home_page.dart');
        expect(src, contains('$name('),
            reason: '$name 若已被替换掉，R7 第①项就该记为已完成并更新本门禁');
      });
    });

    test('★★★ _MoreButton 的两个调用点都在（证明它不是死代码）', () {
      final uses = read('ui/home_page.dart')
          .split(RegExp(r'\r?\n'))
          .asMap()
          .entries
          .where((e) => e.value.contains('_MoreButton('))
          .map((e) => e.key + 1)
          .toList();
      // 1 处是类自身的构造函数定义，另 2 处才是真实调用
      expect(uses.where((n) => n != 2843).length, greaterThanOrEqualTo(2),
          reason: '只有定义没有调用 ⇒ 那是死代码，R7 的第①项就该重判。实读 $uses');
    });

    test('★★ ActionChip 那一路被 source.type == \'custom\' 闸住（已知的行为条件）', () {
      final src = read('ui/home_page.dart');
      expect(src, contains("'custom'"),
          reason: '直播条按 custom 类型过闸；该条件若变，需重判这条路的可达性');
    });

    test('★★★ 首页取色走的是 Theme.of(context).colorScheme（故 F 项读数成立）', () {
      final src = read('ui/home_page.dart');
      expect(RegExp(r'Theme\.of\(context\)\.colorScheme').hasMatch(src), isTrue,
          reason: '这是产品内 colorScheme 仍有大量使用的一个实证');
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // ③ 材料化第三项：theme_bridge 胶水（**lib/ 里只剩 2 处真实 import**）
  // ────────────────────────────────────────────────────────────────────
  group('③ theme_bridge：胶水还没删，但真实依赖已很少', () {
    test('★★★ lib/ 里真实 import theme_bridge 的文件 ≤ 3 个（实测 2）', () {
      final files = <String>{};
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        f.readAsLinesSync().forEach((line) {
          final t = line.trimLeft();
          if (t.startsWith('//')) return;
          if (RegExp(r"^\s*import\s+.*theme_bridge").hasMatch(line)) {
            files.add(f.uri.pathSegments.last);
          }
        });
      }
      expect(files.length, lessThanOrEqualTo(3),
          reason: '真实依赖变多了（实测：$files）⇒ R7 第③项的状态要重写');
    });

    test('★★ 它仍被 test/ 大量引用 ⇒ 删它不是「删个文件」，是拆一串门禁', () {
      final n = Directory('test')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => f
              .readAsLinesSync()
              .any((l) => RegExp(r"import\s+.*theme_bridge").hasMatch(l)))
          .length;
      expect(n, greaterThan(5),
          reason: '实测 14 个测试文件 import 它；这个数字是「删除代价」的量度');
    });

    test('★★ LightTokens 仍是它对外的唯一公共出口（删它要先迁这个）', () {
      expect(read('ui/app_theme.dart'),
          contains("export 'theme_bridge.dart' show LightTokens;"));
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // ④ 复核：AGENTS.md §4「取色走 Theme.of(...).colorScheme 或 tokens」**仍然成立**
  // ────────────────────────────────────────────────────────────────────
  group('④ colorScheme 那条规矩：实测仍成立（曾被怀疑过期，证伪）', () {
    test('★★★ 产品 lib/ 里 colorScheme 的真实使用处 ≥ 100（实测 185）', () {
      var n = 0;
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final base = f.uri.pathSegments.last;
        if (RegExp(r'^(t\d|probe_|merge_view|delivery_test)').hasMatch(base)) {
          continue;
        }
        f.readAsLinesSync().forEach((line) {
          final t = line.trimLeft();
          if (t.startsWith('///') || t.startsWith('//') || t.startsWith('*')) {
            return;
          }
          if (line.contains('colorScheme')) n++;
        });
      }
      expect(n, greaterThanOrEqualTo(100),
          reason: '实测 185 处。若真降到个位数，说明 M1 换出口这件事已完成，'
              'AGENTS.md §4 第二条才可以改写 —— 现在改会是错的。');
    });

    test('★★★ AppColors 不是 colorScheme 的替代出口（它只有 9 处直接用）', () {
      var n = 0;
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        f.readAsLinesSync().forEach((line) {
          final t = line.trimLeft();
          if (t.startsWith('///') || t.startsWith('//') || t.startsWith('*')) {
            return;
          }
          if (line.contains('AppColors.')) n++;
        });
      }
      expect(n, lessThan(30),
          reason: '实测 9 处 ⇒ M1 只是**新增**了语义色层，并没有替换掉 colorScheme');
    });
  });

  // ────────────────────────────────────────────────────────────────────
  // ⑤ 全局硬约束（AGENTS.md §4 第一条）—— 它是**真的**，本门禁守着
  // ────────────────────────────────────────────────────────────────────
  group('⑤ lib/ 里没有 flutter/material.dart 的真实 import', () {
    test('★★★ 全 lib/ *.dart 的真实 import 数 = 0', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        f.readAsLinesSync().asMap().forEach((i, line) {
          final t = line.trimLeft();
          if (t.startsWith('///') || t.startsWith('//') || t.startsWith('*')) {
            return;
          }
          if (line.contains('import') &&
              line.contains('package:flutter/material.dart')) {
            offenders.add('${f.uri.pathSegments.last}:${i + 1}');
          }
        });
      }
      expect(offenders, isEmpty,
          reason: 'lib/ 里出现了 flutter/material 的真实 import：$offenders');
    });

    test('★★ 注释里提到它**不算违规**（仓库现有 13 处就是这么写的）', () {
      // 说明这一条判据是「剔注释后计数」，不是裸 grep —— 避免下一个人
      // 看到 grep 有命中就误报「铁律破了」
      final commented = read('ui/widgets/danmaku_settings_dialog.dart')
          .split(RegExp(r'\r?\n'))
          .where((l) => l.contains('package:flutter/material.dart'))
          .where((l) => l.trimLeft().startsWith('//'))
          .length;
      expect(commented, greaterThan(0),
          reason: '前提：注释里确实有这种写法，所以「剔注释」是必要的判据');
    });
  });

  test('★ 本门禁自身可运行性自检（防止门禁读不到文件而假绿）', () {
    expect(libRoot, isNotEmpty);
    expect(read('ui/home_page.dart').length, greaterThan(1000));
    expect(read('shell.dart').length, greaterThan(1000));
  });
}
