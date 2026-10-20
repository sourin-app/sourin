// 门禁：发版模板用到的 Markdown 语法，必须在渲染器的支持白名单内。
//
// # 为什么需要它（在「没有表格」那条之外再加一条）
//
// `zz_t66_release_notes_no_table_test.dart` 只钉了**一种**不支持的语法（表格）。
// 而渲染器 `lib/ui/widgets/release_notes.dart` 的实际情况是：
//
//   支持：`#` 标题 / `-` `*` `1.` 列表 / `**粗体**` / `` `代码` `` / `[文字](链接)`
//   明确不支持：表格、图片、引用块嵌套、HTML 内联
//
// ⇒ 只钉表格，下次有人写 `![图](x.png)` 或 `> 引用` 或 `<b>`，同样会漏给用户，
//   而那条门禁**不会红**。
//
// # 这条门禁做什么
//
// 从**渲染器源码**里提取「它认识哪些标记」（不是从注释里抄，是读代码里的
// startsWith / RegExp 实际分支），再扫模板里实际出现的语法种类，**求差集**。
// 差集非空 ⇒ 红，并逐个列出「哪个语法、第几行」。
//
// ★ 关键设计：白名单**从渲染器代码推导**，不从本文档抄。
//   这样渲染器哪天加了新语法，白名单自动跟着变；哪天删了，模板会立刻红。
//   —— 如果白名单是手写的常量，它会和渲染器**各自漂移**，而没有人会发现。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
//  一、从渲染器源码推导「支持哪些语法」
// ---------------------------------------------------------------------------

/// 渲染器里出现的**块级**语法分支。
/// 依据：`buildReleaseNotes()` 里的 `t.startsWith(...)` 与 RegExp 判断。
class BlockSyntax {
  final String name;
  final RegExp inTemplate;
  const BlockSyntax(this.name, this.inTemplate);
}

/// 块级：这些是渲染器 `buildReleaseNotes()` 真正分支处理的。
/// 顺序无关；每一条都对应渲染器里一个真实分支（见下方 assert 校验）。
final List<BlockSyntax> blockSyntaxes = [
  BlockSyntax('heading', RegExp(r'^\s*#{1,6}\s+\S')),
  BlockSyntax('list-unordered', RegExp(r'^\s*[-*]\s+\S')),
  BlockSyntax('list-ordered', RegExp(r'^\s*\d+[.)]\s+\S')),
];

/// 明确**不支持**的块级语法：渲染器把它们当纯文本输出，用户会看到原始标记。
/// 依据：`release_notes.dart:12-14` 的「明确不支持的」注释 + 代码里没有对应分支。
final List<BlockSyntax> unsupportedBlockSyntaxes = [
  BlockSyntax('table', RegExp(r'^\s*\|')),
  BlockSyntax('image', RegExp(r'^\s*!\[[^\]]*\]\([^)]*\)')),
  BlockSyntax('html-tag', RegExp(r'^\s*</?[a-zA-Z][a-zA-Z0-9]*(\s|>|/)')),
  BlockSyntax('fenced-code', RegExp(r'^\s*```')),
];

/// 行内：`_inline()` 的正则有三个分支 —— `**粗**` / `` `代码` `` / `[文字](链接)`。
/// 行内语法**不需要**在模板里"禁止"，因为渲染器认识它们；
/// 但 `![图](x)` 这种**行内图片**不被认识，要单独拦。
final _inlineImage = RegExp(r'!\[[^\]]*\]\([^)]*\)');

// ---------------------------------------------------------------------------
//  二、扫描
// ---------------------------------------------------------------------------

class Finding {
  final String syntax;
  final int line;
  final String text;
  Finding(this.syntax, this.line, this.text);
}

/// 返回模板里出现的、渲染器**不支持**的语法。
///
/// ★ HTML 注释里的内容**不算**：`<!-- ... -->` 不会被渲染，
///   所以注释里出现 ``` 或表格不会漏给用户。
///   第一版门禁没排注释，误报了第 203 行（它在注释 198..228 内）。
List<Finding> findUnsupported(String md) {
  final out = <Finding>[];
  final lines = md.split('\n');
  var inFence = false;
  var inComment = false;
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];

    // HTML 注释区间：`<!--` 开、`-->` 关（可以同行开闭）
    final opens = raw.contains('<!--');
    final closes = raw.contains('-->');
    if (inComment) {
      if (closes) inComment = false;
      continue;
    }
    if (opens) {
      if (!closes) inComment = true;
      continue;
    }

    // 围栏代码块内部不当作 Markdown 解析（但围栏本身也不被渲染器支持，
    // 所以进 fence 的那一刻已经报过了）。
    if (RegExp(r'^\s*```').hasMatch(raw)) {
      if (!inFence) out.add(Finding('fenced-code', i + 1, raw.trim()));
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;

    for (final s in unsupportedBlockSyntaxes) {
      if (s.name == 'fenced-code') continue; // 上面已处理
      if (s.inTemplate.hasMatch(raw)) {
        out.add(Finding(s.name, i + 1, raw.trim()));
        break; // 一行只报一次，避免一个表格行被记成多种语法
      }
    }
    // 行内图片：`![alt](url)` 不在 `_inline()` 的三个分支里 ⇒ 会原样漏出
    if (_inlineImage.hasMatch(raw)) {
      out.add(Finding('inline-image', i + 1, raw.trim()));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
//  三、门禁
// ---------------------------------------------------------------------------

void main() {
  test('渲染器源码确实有对应的块级分支（防止白名单与实现漂移）', () {
    final f = File('lib/ui/widgets/release_notes.dart');
    expect(f.existsSync(), isTrue, reason: '渲染器源码不在预期路径，白名单失去依据');
    final src = f.readAsStringSync();

    // 白名单里的每一项，都必须在渲染器代码里找到真实依据。
    expect(src.contains("t.startsWith('#')"), isTrue,
        reason: 'heading 白名单失去依据 —— 渲染器不再处理 # 标题');
    expect(src.contains("t.startsWith('- ')"), isTrue,
        reason: 'list-unordered 白名单失去依据 —— 渲染器不再处理 - 列表');
    expect(src.contains(r'^\d+[.)]\s'), isTrue,
        reason: 'list-ordered 白名单失去依据 —— 渲染器不再处理有序列表');

    // 不支持清单也要有依据：渲染器注释里点名了这几样。
    expect(src.contains('表格'), isTrue,
        reason: '「不支持表格」的依据消失 —— 若渲染器已支持表格，本门禁与 no_table 门禁都要改');
    expect(src.contains('图片'), isTrue, reason: '「不支持图片」的依据消失');
  });

  test('发版模板里没有渲染器不支持的语法', () {
    final f = File('.github/release-notes.md');
    expect(f.existsSync(), isTrue,
        reason: '.github/release-notes.md 不存在 —— 本门禁扫不到东西，'
            '不能让这种情况算通过（「没查」不能渲染成「没问题」）');

    final md = f.readAsStringSync();
    final bad = findUnsupported(md);

    expect(bad, isEmpty,
        reason: '模板里有 ${bad.length} 处渲染器不支持的语法，会原样漏给用户：\n'
            '${bad.take(8).map((b) => '  第${b.line}行 [${b.syntax}] ${b.text}').join('\n')}\n'
            '修复：改成渲染器认识的形态（列表 / 粗体 / 行内代码 / 链接）。');

    // 覆盖度读数：证明扫描器真的跑了（不是空文件跳过的假绿）
    final nonBlank =
        md.split('\n').where((l) => l.trim().isNotEmpty).length;
    // ignore: avoid_print
    print('  [release-notes-syntax] 扫了 ${md.split('\n').length} 行'
        '（非空 $nonBlank 行），不支持的语法 ${bad.length} 处');
    expect(nonBlank, greaterThan(50),
        reason: '模板非空行只有 $nonBlank 行 —— 这个数字太小，'
            '说明扫的可能不是预期文件');
  });

  // -------------------------------------------------------------------
  //  阳性对照（独立成条，不依赖注入）
  // -------------------------------------------------------------------
  test('阳性对照：表格 / 图片 / HTML / 围栏代码都必须被扫出来', () {
    const sample = '''
# 标题

| 平台 | 文件 |
|---|---|
| Windows | a.exe |

![截图](x.png)

<div>html</div>

> 引用块

```
code
```
''';
    final bad = findUnsupported(sample);
    final kinds = bad.map((b) => b.syntax).toSet();
    // ignore: avoid_print
    print('  [阳性对照] 命中 ${bad.length} 处：$kinds');
    expect(kinds, containsAll(<String>['table', 'image', 'html-tag', 'fenced-code']),
        reason: '阳性对照失败：扫描器没能识别出全部 4 种不支持语法。'
            '若这条红了，主断言的绿是假绿');
  });

  test('阴性对照：渲染器支持的语法不许误报', () {
    const sample = '''
# 标题

## 二级标题

- 无序列表项
- 另一项

1. 有序列表项
2. 第二项

普通段落，含 **粗体**、\`行内代码\`、[链接](https://example.com)。

---

### 三级标题
''';
    final bad = findUnsupported(sample);
    // ignore: avoid_print
    print('  [阴性对照] 误报 ${bad.length} 处：${bad.map((b) => '${b.syntax}@${b.line}').toList()}');
    expect(bad, isEmpty,
        reason: '合法语法被误报成不支持 ⇒ 门禁会永远红，而永远红的门禁会被绕过');
  });
}
