// 门禁：渲染器必须**跳过**不是内容的东西（HTML 注释、分隔线）
//
// # 为什么需要它（2026-10-22，Lead 读代码时发现的线上缺陷）
//
// `lib/ui/widgets/release_notes.dart` 的 `buildReleaseNotes()` 只认三种行：
// 标题（`#`）、列表（`- ` `* ` `1.`）、其余**一律当段落**。
// 于是 `.github/release-notes.md` 里那段 26 行的 HTML 注释
// （`## 本版更新` 下面、用来提醒维护者的那段）被**逐行当正文**渲染：
//
// ```text
// <!--
//   ★★★ 这一节由 `tools/gen_release_notes.py` 生成，**不要手写**。
//   背景（Owner 2026-10-19）：「最近发的几个版本都没有更新说明…」
//   ...
// -->
// ```
//
// # 这不是理论问题，线上确实这样
//
// ```text
// gh release view v1.4.0-rc3 --json body    # 正文里就有这段注释（26 行）
// ⇒ 客户端拿整份正文去渲染（lib/ui/widgets/update_dialog.dart:174）
// ⇒ 更新弹窗里显示的是维护者写给维护者的说明
// ```
//
// # 两个门禁对同一件事的信仰相反
//
// ```text
// · test/zz_t66_release_notes_syntax_gate_test.dart:79-81
//     「HTML 注释里的内容**不算**：`<!-- ... -->` 不会被渲染」
// · test/zz_t1022_manual_release_notes_gate_test.dart:12-13 + 生成器
//     「渲染器**不剥**注释，它会被原样显示给用户」
// ```
//
// 两者不可能同时成立。以代码为准：`release_notes.dart` 里**没有任何**
// 注释处理分支 ⇒ 后一种说法是对的，前一种说法是错的。
//
// # 修法为什么是「改渲染器」而不是「删模板里的注释」
//
// ```text
// · 模板里那段注释是给**维护者**看的（说明占位标记的坑），删掉等于毁掉文档
// · 已经发出去的 release 正文（rc1/rc2/rc3…）改不了，
//   只有渲染器跳过注释，老版本用户才不用再看那段说明
// ⇒ 渲染器必须负责「不是内容的东西不显示」
// ```
//
// ★ 本门禁只钉「渲染结果里没有注释/分隔线的痕迹」，
//   不钉实现方式（跳过的办法可以是状态机，也可以是先剥再解析）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/widgets/release_notes.dart';

/// 把渲染结果里的**纯文本**全抓出来（含 Text.rich 的各个 span）。
List<String> renderedTexts(List<Widget> widgets) {
  final out = <String>[];
  void visit(Widget w) {
    if (w is Text) {
      final d = w.data;
      if (d != null) out.add(d);
      final span = w.textSpan;
      if (span != null) out.add(span.toPlainText());
      return;
    }
    if (w is Padding) {
      final child = w.child;
      if (child != null) visit(child);
      return;
    }
    if (w is Row) {
      for (final c in w.children) {
        visit(c);
      }
      return;
    }
    if (w is Expanded) {
      // Expanded.child 在 Flutter 的类型里是非空的（analyzer 会说 `!= null`
      // 恒真）—— 这里直接访问，不写多余的判空。
      visit(w.child);
    }
  }

  for (final w in widgets) {
    visit(w);
  }
  return out;
}

void main() {
  test('跨行 HTML 注释不产生任何可见文本（线上 rc3 那段 26 行注释）', () {
    const md = '### 修复\n'
        '\n'
        '<!--\n'
        '  ★★★ 这一节由生成器产出，**不要手写**。\n'
        '\n'
        '  - 这一行像条目，但它也是注释\n'
        '  | 这一行像表格，同样在注释里 |\n'
        '-->\n'
        '\n'
        '- 真正的说明。\n';

    final texts = renderedTexts(buildReleaseNotes(md));
    final joined = texts.join('\n');

    expect(joined, contains('真正的说明'),
        reason: '阳性对照失败：连真内容都没渲染出来，这条用例证明不了任何事');
    expect(joined, isNot(contains('不要手写')),
        reason: '注释里的文字被当成正文渲染了 —— 线上 release 正文里就有这么一段，'
            '用户会在更新弹窗里读到维护者写给维护者的说明。');
    expect(joined, isNot(contains('<!--')),
        reason: '注释的起始标记本身被当成段落显示给用户了');
    expect(joined, isNot(contains('-->')),
        reason: '注释的结束标记本身被当成段落显示给用户了');
    expect(joined, isNot(contains('| 这一行像表格')),
        reason: '注释里的表格行被当成段落漏出去了');
  });

  test('同一行内开闭的注释也不显示（`<!-- x -->` 不是内容）', () {
    const md = '### 改进\n'
        '\n'
        '- 前半 <!-- 维护者备注 --> 后半\n';

    final texts = renderedTexts(buildReleaseNotes(md));
    final joined = texts.join('\n');
    expect(joined, contains('前半'),
        reason: '阳性对照失败：行内注释把整行吃掉了（应只吃掉注释本身）');
    expect(joined, isNot(contains('维护者备注')),
        reason: '行内注释的内容被显示给用户了');
  });

  test('分隔线（`---` / `***` / `___`）不显示成「---」这样的正文', () {
    const md = '### 修复\n'
        '\n'
        '- 一条说明。\n'
        '\n'
        '---\n'
        '\n'
        '***\n'
        '\n'
        '___\n';

    final texts = renderedTexts(buildReleaseNotes(md));
    final joined = texts.join('\n');
    expect(joined, contains('一条说明'), reason: '阳性对照失败：真内容没渲染');
    for (final rule in <String>['---', '***', '___']) {
      expect(joined, isNot(contains(rule)),
          reason: '分隔线「$rule」被当成正文段落显示了 —— 模板里现在有 9 条 `---`，'
              '用户会在更新弹窗里看到一串「---」。');
    }
  });

  test('注释没闭合时不崩，且不会把后面的真内容吞掉（坏输入也要安全）', () {
    const md = '### 修复\n'
        '\n'
        '<!-- 忘了收尾\n'
        '\n'
        '- 后面还有真内容。\n';

    // 不抛异常就是第一条要求；第二条：至少能拿到 widget 列表。
    final widgets = buildReleaseNotes(md);
    expect(widgets, isNotEmpty,
        reason: '未闭合注释导致渲染结果为空 —— 更新弹窗会显示「这个版本没有写说明」。');
  });

  test('阳性对照：注释修好之后，正常的标题 / 列表 / 段落照样渲染', () {
    const md = '# 本版更新\n'
        '\n'
        '### 修复\n'
        '\n'
        '- 第一条。\n'
        '- 第二条。\n'
        '\n'
        '一段普通说明。\n';

    final texts = renderedTexts(buildReleaseNotes(md));
    final joined = texts.join('\n');
    for (final want in <String>['本版更新', '修复', '第一条', '第二条', '一段普通说明']) {
      expect(joined, contains(want), reason: '正常内容「$want」没被渲染出来');
    }
  });
}
