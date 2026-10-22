// 门禁：release notes 正文里不许出现 Markdown 表格语法
//
// # 为什么需要它
//
// `lib/ui/widgets/release_notes.dart` 的渲染器**明确不支持表格**：
//
//     // # 明确不支持的（遇到了就按纯文本显示，不报错）
//     // 表格、图片、引用块嵌套、HTML 内联。
//
// 而 `.github/release-notes.md` 里原本有 4 张表（31 行 `|...`）。
// 2026-10-21 真机验证时，更新弹窗里这些表**原样漏出**：
//
//     | 平台 | 文件 | 说明 |
//     |---|---|---|
//
// ⇒ 用户看到的是 Markdown 源码，不是排版好的内容。
//
// 修法是**改内容**（把表改成列表），不是给渲染器加表格支持 ——
// 渲染器支持表格会推翻 `release_notes.dart` 的设计决定（语法很窄、不加包），
// 而那需要新开一篇决策笔记说明为什么翻案。
//
// ★ 本门禁防的是「下次有人在 GitHub Release 正文里又写一张表」。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 只匹配「表格行」：以 `|` 开头（允许前导空格）。
/// 不匹配正文里偶然出现的 `|`（例如「A | B」这种行内分隔），
/// 因为那些不会渲染成表格，也就不构成这个缺陷。
final _tableRow = RegExp(r'^\s*\|');

/// 扫描一段 Markdown，返回所有表格行（1-based 行号 + 内容）。
List<String> findTableRows(String md) {
  final out = <String>[];
  final lines = md.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (_tableRow.hasMatch(lines[i])) {
      out.add('${i + 1}: ${lines[i]}');
    }
  }
  return out;
}

void main() {
  test('release notes 正文里没有 Markdown 表格（渲染器不支持表格）', () {
    final f = File('.github/release-notes.md');
    expect(f.existsSync(), isTrue,
        reason: '.github/release-notes.md 不存在 —— 本门禁扫不到东西，'
            '不能让这种情况算通过（「没查」不能渲染成「没问题」）');

    final md = f.readAsStringSync();
    final rows = findTableRows(md);

    expect(rows, isEmpty,
        reason: '发现 ${rows.length} 行表格语法。'
            'release_notes.dart 不渲染表格，这些行会原样漏给用户。'
            '改成列表（`- **项** —— 说明`）。\n'
            '前几行：\n${rows.take(5).join('\n')}');
  });

  // ------------------------------------------------------------------
  //  阳性对照：证明上面的扫描器**真的能发现问题**
  // ------------------------------------------------------------------
  // 没有这条，一个永远返回空列表的坏扫描器也会让上面那条测试变绿。
  // 这正是 AGENTS.md「判据的输出必须能区分『查了没问题』与『没查/我坏了』」。
  test('阳性对照：含表格的文本必须被扫出来', () {
    const sample = '''
# 标题

| 平台 | 文件 | 说明 |
|---|---|---|
| Windows | a.exe | 安装版 |

正文段落，这里有一个竖线 A | B 但不是表格行。
''';
    final rows = findTableRows(sample);
    expect(rows.length, 3,
        reason: '阳性对照失败：扫描器没能识别出 3 行表格。'
            '若这条红了，上面那条「没有表格」的绿是**假绿**');
    expect(rows.first, contains('平台'));
  });

  test('阳性对照：列表写法（合法形态）不会被误报', () {
    const sample = '''
## 下载

**Windows**

- `a.exe` —— 安装版
- `b.zip` —— 免安装版
''';
    expect(findTableRows(sample), isEmpty,
        reason: '合法列表被误报成表格 ⇒ 门禁会永远红，而永远红的门禁会被绕过');
  });
}
