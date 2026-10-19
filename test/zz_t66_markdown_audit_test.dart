// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮：**全仓 markdown 星号（`**`）审计**（只读型，只出清单）
// ═══════════════════════════════════════════════════════════════════════
//
//  # 为什么做这件事
//  ```text
//  本仓已核实：**全仓没有 markdown 渲染器** —— 用户可见文本都是普通
//  `Text` / `Tooltip.message` / `hintText` 直接显示。
//  ⇒ `**粗体**` 的星号**不会被吃掉**，会原样露在界面上。
//  ```
//
//  # ★ 只读型：**不改任何产品代码**，只产出清单
//  ```text
//  逐条决定权交给 Lead 与各域 owner。
//  ★ 本文件**故意不 fail** —— 它是清单工具，���是门禁。
//  ```
//
//  # ★ 三条判据纪律
//  ```text
//  ① **区分注释与字符串**：复用共享 helper `stripComments`
//     （`test/_support/strip_comments.dart`）。本仓铁律 170：
//     「同一纪律必须只有一个实现」，**不许再抄一份**（曾有 10 份分叉）。
//     剥完注释仍含 `**` 的 ⇒ 它在**代码/字符串**里。
//  ② **区分「会被 Text 渲染」与「进日志」**：后者视觉影响小，单列一类。
//  ③ **不确定的一律标「不确定」**，不许猜
//     （AGENTS.md：0 条命令 = 没查，不是未确定）。
//  ```
//
//  # ★★★ ★ 本工具的**已知漏报/误报**（实测，别踩）
//  ```text
//  共享 helper `stripComments` 的状态机只认 `//` 与 `/* */`，
//  **不认 Dart 的文档注释 `///`** —— 它把 `///` 当成 `//` + 一个 `/`，
//  于是该行余下内容被当成**代码**留下。
//  ⇒ 后果：`/// ... **我们** ...` 这类**注释里的星号会被误报**成用户可见。
//  ⇒ 本轮实测**全仓只有 1 条**这种假阳性：
//     `lib/ui/cache_page.dart:2161`（`/// 而我们要回答的是"**我们**有没有泄漏"`)
//  ⇒ 用本工具复核某条命中时，**必须回原文件看一眼那行是不是注释**
//     （判据：`grep -n "<该行号>p<文件>" | cut -c1-60` 看有没有 `//` / `///`）。
//  ⇒ 这条是**共享 helper 的既有弱点**，不是本工具引入的；
//     修它要动 `_support/strip_comments.dart`（会影响 19 个文件的静态断言）
//     ⇒ 本轮**不动**，只在此记录。
//  ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/strip_comments.dart';

/// 一条命中
class Hit {
  Hit(this.file, this.line, this.literal, this.bucket);

  final String file;
  final int line;

  /// 字面量原文（截断到 140 字）
  final String literal;

  /// '用户可见' | '日志' | '不确定'
  final String bucket;
}

/// UI 语汇：出现在这些名字附近 ⇒ 大概率会被 Text 类控件渲染
const _uiWords = <String>[
  'Text(', 'hintText', 'tooltip', 'label', 'title', 'snippet', 'message',
  'placeholder', 'helperText', 'errorText', 'semanticsLabel', 'TextSpan',
  'subtitle', 'description', 'reason', 'detail', 'status', 'summary',
  'displayName', 'content', 'caption', 'header', 'name', 'buttonText',
];

/// 日志语汇
const _logWords = <String>[
  'debugPrint', 'print(', 'AppLog', '.error(', '.log(', '.trace(',
];

/// 取一行里所有单/双引号字符串字面量（不含引号本身）
List<String> _literalsInLine(String line) {
  final out = <String>[];
  var i = 0;
  String? q;
  var buf = StringBuffer();
  while (i < line.length) {
    final c = line[i];
    if (q != null) {
      if (c == r'\') {
        buf.write(c);
        if (i + 1 < line.length) buf.write(line[i + 1]);
        i += 2;
        continue;
      }
      if (c == q) {
        if (buf.isNotEmpty) out.add(buf.toString());
        buf = StringBuffer();
        q = null;
      } else {
        buf.write(c);
      }
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      q = c;
      buf = StringBuffer();
    }
    i++;
  }
  return out;
}

/// 分类：看该行**字面量之前**的片段（实参位通常与关键字同行）
String _bucket(String line, int litStartInLine) {
  final head = litStartInLine <= 0 ? '' : line.substring(0, litStartInLine);
  for (final w in _logWords) {
    if (head.contains(w)) return '日志';
  }
  for (final w in _uiWords) {
    if (head.contains(w)) return '用户可见';
  }
  // 同一行后面若有 UI 关键字（如 `Text('…', …)` 反过来），再扫全行
  for (final w in _logWords) {
    if (line.contains(w)) return '日志';
  }
  for (final w in _uiWords) {
    if (line.contains(w)) return '用户可见';
  }
  return '不确定';
}

void main() {
  test('全仓 markdown 星号审计（只读清单，不 fail）', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'lib 目录必须存在');

    final files = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final hits = <Hit>[];
    var scannedFiles = 0;

    for (final f in files) {
      scannedFiles++;
      final raw = f.readAsStringSync();
      final code = stripComments(raw); // ★ 剥注释（铁律 170 复用）
      if (!code.contains('**')) continue;

      final codeLines = code.split('\n');
      for (var ln = 0; ln < codeLines.length; ln++) {
        final cl = codeLines[ln];
        if (!cl.contains('**')) continue;

        // 该行里所有含 `**` 的字符串字面量
        var idx = 0;
        for (final lit in _literalsInLine(cl)) {
          idx = cl.indexOf(lit, idx);
          final start = idx < 0 ? 0 : idx;
          idx = start + lit.length;
          if (!lit.contains('**')) continue;
          hits.add(Hit(
            f.path.replaceAll('\\', '/'),
            ln + 1,
            lit.length > 140 ? '${lit.substring(0, 140)}…' : lit,
            _bucket(cl, start),
          ));
        }
      }
    }

    // ── 输出清单（按 bucket 分组）──
    // ignore: avoid_print
    print('=== MD-AUDIT 扫描 $scannedFiles 个 .dart，共 ${hits.length} 条命中（已剥注释）===');
    for (final b in ['用户可见', '日志', '不确定']) {
      final sub = hits.where((h) => h.bucket == b).toList()
        ..sort((a, b2) {
          final c = a.file.compareTo(b2.file);
          return c != 0 ? c : a.line.compareTo(b2.line);
        });
      // ignore: avoid_print
      print('--- bucket=$b  ${sub.length} 条 ---');
      for (final h in sub) {
        // ignore: avoid_print
        print('MD|${h.file}:${h.line}  「${h.literal}」');
      }
    }

    // 只读型：不断言（清单工具不是门禁）
    expect(scannedFiles, greaterThan(0));
  });
}