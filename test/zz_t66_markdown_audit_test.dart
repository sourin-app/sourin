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

import '_support/markdown_bold.dart';
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

  // ═══════════════════════════════════════════════════════════════════════
  //  ★★★ 门禁（**真断言**）：产品路径的用户可见文案里 `**` 必须 = 0
  // ═══════════════════════════════════════════════════════════════════════
  //
  // # 为什么要在同一个文件里再来一条
  // ```text
  // 上面那条是**清单工具**：它 `print` 完只断言「扫到了 > 0 个文件」，
  // 永远不 fail（2026-10-20 `verify-34` 复核原话：
  // 「审计工具恒绿，它不能替门禁作证」）。
  // ⇒ 现在补上门禁那半：范围 = **产品路径**
  //      lib/ui/**  +  lib/core/**  +  lib/design/**  +  lib/shell.dart
  //    判据 = 其中「用户可见」桶里的 `**粗体**` 字面量 **必须一条都没有**。
  // ```
  //
  // # 三条不许踩的线
  // ```text
  // ① 不许把「不确定」桶（全仓 213 条）算进来 —— 那会让门禁**永远红**，
  //    而永远红的门禁和永不红的门禁一样是废门禁。它们只**打印**。
  // ② 不许用朴素 `contains('**')`：`lib/core/danmaku.dart` 的
  //    `'****'` / `'${id.substring(0,4)}****'` / `'***'` 是**脱敏掩码**，
  //    判成 markdown 会要求把它们改成「」⇒ 把打码的 AppId 明文暴露给用户。
  //    ⇒ 复用唯一判别式 `isMarkdownBoldLiteral`（铁律 170）。
  // ③ 必须有防空转自检：扫描器 / 提取器坏了时，本门禁**不许**恒绿
  //    （文件数门槛 + 两条已知产品文案必须真的被提取到 + 判别式自身双向自检）。
  // ```
  test('★ 产品路径（lib/ui + lib/core + lib/design + lib/shell.dart）用户可见 `**` 必须 = 0',
      () {
    const roots = <String>['lib/ui', 'lib/core', 'lib/design'];
    final files = <File>[];
    for (final r in roots) {
      final d = Directory(r);
      expect(d.existsSync(), isTrue, reason: '★ 防空转：扫描根目录不存在：$r');
      files.addAll(d
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')));
    }
    final shell = File('lib/shell.dart');
    expect(shell.existsSync(), isTrue, reason: '★ 防空转：产品入口 lib/shell.dart 不存在');
    files.add(shell);
    files.sort((a, b) => a.path.compareTo(b.path));

    final visible = <Hit>[];
    final logged = <Hit>[];
    for (final f in files) {
      final code = stripComments(f.readAsStringSync()); // ★ 剥注释，不许把注释算进来
      if (!code.contains('**')) continue;
      final lines = code.split('\n');
      for (var ln = 0; ln < lines.length; ln++) {
        final cl = lines[ln];
        if (!cl.contains('**')) continue;
        var idx = 0;
        for (final lit in _literalsInLine(cl)) {
          idx = cl.indexOf(lit, idx);
          final start = idx < 0 ? 0 : idx;
          idx = start + lit.length;
          // ★ 唯一判别式：放过脱敏掩码，只要真·成对粗体
          if (!isMarkdownBoldLiteral(lit)) continue;
          final h = Hit(
            f.path.replaceAll('\\', '/'),
            ln + 1,
            lit.length > 140 ? '${lit.substring(0, 140)}…' : lit,
            _bucket(cl, start),
          );
          if (h.bucket == '用户可见') {
            visible.add(h);
          } else if (h.bucket == '日志') {
            logged.add(h);
          }
        }
      }
    }

    // ignore: avoid_print
    print('MDGATE|产品路径扫描 ${files.length} 个 .dart：'
        '用户可见 ${visible.length} 条 / 日志 ${logged.length} 条');

    // ── 防空转自检 ──────────────────────────────────────────────────
    // ① 文件数：产品路径实测 153 个（lib/ui+lib/core+lib/design 152 + shell.dart）
    expect(files.length, greaterThanOrEqualTo(150),
        reason: '★ 防空转：只扫到 ${files.length} 个文件 ⇒ 扫描根或递归坏了，'
            '下面的「== 0」会恒真。');
    // ② 提取链真的工作：两条**已知产品文案**必须被同一个提取器读到
    //    （只验证「剥注释 + 取字面量」这条链，与 `**` 无关）
    final dmCode = stripComments(
        File('lib/ui/settings/data_manage_page.dart').readAsStringSync());
    final dmLits = dmCode.split('\n').expand(_literalsInLine).toSet();
    expect(dmLits.contains('数据管理'), isTrue,
        reason: '★ 防空转：提取器没读到已知文案「数据管理」⇒ 字面量提取已失效。');
    final ppCode = stripComments(
        File('lib/ui/widgets/proxy_panel.dart').readAsStringSync());
    final ppLits = ppCode.split('\n').expand(_literalsInLine).toSet();
    expect(ppLits.contains('代理地址'), isTrue,
        reason: '★ 防空转：提取器没读到已知文案「代理地址」⇒ 字面量提取已失效。');
    // ③ 判别式自身双向自检：退化成朴素 `contains('**')` ⇒ 立刻红
    expect(kRedactionMaskSamples.map(isMarkdownBoldLiteral), everyElement(isFalse),
        reason: '★★ 判别式退化：脱敏掩码 `****` / `abcd****` / `***` 被当成了 '
            'markdown 粗体 ⇒ 门禁会要求把打码的 AppId 改成「」，泄露给用户。');
    expect(isMarkdownBoldLiteral('**粗体**'), isTrue,
        reason: '★★ 判别式坏了：连 `**粗体**` 都认不出来 ⇒ 本门禁永远绿。');

    // ── 报告（日志/其它桶只打印，不算红）────────────────────────────
    for (final h in logged) {
      // ignore: avoid_print
      print('MDGATE|日志桶（非红）：${h.file}:${h.line}  「${h.literal}」');
    }

    // ── 真断言 ──────────────────────────────────────────────────────
    expect(
      visible,
      isEmpty,
      reason: '★★★ 产品路径里有用户可见文案带 markdown 粗体 `**`。\n'
          '全仓没有 markdown 渲染器 ⇒ 星号会**原样显示**给用户。\n'
          '修法：改成中文引号「」（先例 `lib/shell.dart:6955`），不许用 Text.rich。\n'
          '命中（文件:行 + 原文）：\n'
          '${visible.map((h) => '  · ${h.file}:${h.line}  「${h.literal}」').join('\n')}',
    );
  });
}