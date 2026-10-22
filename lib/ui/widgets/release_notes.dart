// ═══════════════════════════════════════════════════════════════════════
//  版本说明的极简 Markdown 渲染
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么自己渲染而不用 `flutter_markdown`
//
// 版本说明来自我们自己的 Release notes，语法很窄：标题、列表、
// 行内代码、粗体、链接。不值得为此加一个包（它还会拖进
// `markdown` 与一整套解析器，而本仓正在为安装包体积把关）。
//
// # 明确不支持的（遇到了就按纯文本显示，不报错）
// 表格、图片、引用块嵌套、HTML 内联。
//
// # 「不是内容」的东西必须跳过，不能当纯文本（2026-10-22 修）
//
// ```text
// 本次修的就是这条：`<!-- … -->` 注释与 `---` 分隔线**不是内容**，
// 但第一版把它们当普通段落 ⇒ 用户读到的是：
//
//   <!--
//     ★★★ 这一节由 `tools/gen_release_notes.py` 生成，**不要手写**。
//     …
//   -->
//   ---
//
// 而 `## 本版更新` 下面**真的有**一段 26 行的维护者注释
// （.github/release-notes.md 里提醒"占位标记别写第二份"那段），
// 它会被逐行渲染进更新弹窗 ⇒ 用户看到的是写给维护者的说明。
// 线上 v1.4.0-rc1..rc3 的 release 正文都带着它（`gh release view` 可验）。
// ```
//
// # 为什么修渲染器，而不是删模板里的注释
//
// ```text
// · 那段注释是给**维护者**看的文档（占位标记的坑），删掉等于毁掉它
// · 已发出去的 release 正文改不了 —— 只有渲染器跳过，老版本用户才不用再看
// ⇒ 「不是内容的东西不显示」是渲染器的责任，不是模板的责任
// ```
//
// ★ 表格 / 图片 / HTML 内联仍然按纯文本漏出 —— 那是另一回事：
//   它们**是内容**，只是不支持。由 `test/zz_t66_release_notes_*_test.dart`
//   在模板层拦住「别写它们」，渲染器不替作者猜意图。

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';

/// 把版本说明 Markdown 渲染成一组 widget
List<Widget> buildReleaseNotes(String md, {Color? linkColor}) {
  final lines = md.split('\n');
  final out = <Widget>[];
  final listBuf = <String>[];
  String? heading;

  void flushList() {
    if (listBuf.isEmpty) return;
    for (final l in listBuf) {
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: Sp.x1, left: Sp.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('•',
                style: TextStyle(
                    fontSize: FontSizes.sm, color: linkColor ?? Colors.grey)),
            const SizedBox(width: Sp.x2),
            Expanded(child: _inline(l, linkColor)),
          ],
        ),
      ));
    }
    listBuf.clear();
  }

  void flushHeading() {
    if (heading == null) return;
    out.add(Padding(
      padding: const EdgeInsets.only(top: Sp.x2, bottom: Sp.x1),
      child: Text(heading!,
          style: TextStyle(
              fontSize: FontSizes.base,
              fontWeight: FontWeights.semibold,
              color: linkColor)),
    ));
    heading = null;
  }

  /// HTML 注释是否还没闭合（跨行注释要一直吃到 `-->`）
  ///
  /// ★ 必须是**状态**而不是一行一个 `RegExp`：评论块是跨行的，
  ///   逐行判断只能吃掉 `<!--` 那一行，中间十几行照样漏出去。
  var inComment = false;

  for (final raw in lines) {
    var line = raw.trimRight();

    // ── 一、先剥掉 HTML 注释（它是给维护者看的，不是内容）──────────
    //
    // ★ 同一行里可能既有注释又有真内容（`- 前半 <!-- 备注 --> 后半`），
    //   所以是**剥掉注释、留下两侧**，不是"整行丢掉"。
    // ★ 未闭合的注释吃到文末 —— 宁可少显示，也不能把注释里的字漏给用户。
    if (inComment) {
      final end = line.indexOf('-->');
      if (end == -1) continue; // 整行都在注释里
      inComment = false;
      line = line.substring(end + 3);
    }
    while (true) {
      final start = line.indexOf('<!--');
      if (start == -1) break;
      final end = line.indexOf('-->', start + 4);
      if (end == -1) {
        inComment = true;
        line = line.substring(0, start);
        break;
      }
      line = line.substring(0, start) + line.substring(end + 3);
    }

    final t = line.trim();
    if (t.isEmpty) {
      flushList();
      flushHeading();
      continue;
    }
    // ── 二、分隔线不是内容（模板里有 9 条 `---`，不能显示成正文「---」）
    if (RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$').hasMatch(t)) {
      flushList();
      flushHeading();
      continue;
    }
    if (t.startsWith('#')) {
      flushList();
      flushHeading();
      final h = t.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      heading = h.isEmpty ? null : h;
      continue;
    }
    if (t.startsWith('- ') || t.startsWith('* ') || RegExp(r'^\d+[.)]\s').hasMatch(t)) {
      flushHeading();
      listBuf.add(t.replaceFirst(RegExp(r'^([-*]|\d+[.)])\s*'), ''));
      continue;
    }
    flushList();
    flushHeading();
    out.add(Padding(
      padding: const EdgeInsets.only(bottom: Sp.x1),
      child: _inline(t, linkColor),
    ));
  }
  flushList();
  flushHeading();

  if (out.isEmpty) {
    out.add(Text('这个版本没有写说明。',
        style: TextStyle(fontSize: FontSizes.sm, color: linkColor)));
  }
  return out;
}

/// 行内：`**粗**`、`` `代码` ``、`[文字](链接)`、`https://…`
Widget _inline(String text, Color? color) {
  final spans = <TextSpan>[];
  final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)');
  var i = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > i) {
      spans.add(TextSpan(text: text.substring(i, m.start)));
    }
    if (m.group(1) != null) {
      spans.add(TextSpan(
          text: m.group(1),
          style: const TextStyle(fontWeight: FontWeights.semibold)));
    } else if (m.group(2) != null) {
      spans.add(TextSpan(
          text: m.group(2),
          style: const TextStyle(fontFamily: 'monospace', fontSize: FontSizes.cap)));
    } else {
      spans.add(TextSpan(
          text: m.group(3),
          style: TextStyle(color: color, decoration: TextDecoration.underline)));
    }
    i = m.end;
  }
  if (i < text.length) spans.add(TextSpan(text: text.substring(i)));
  return Text.rich(
    TextSpan(children: spans),
    style: TextStyle(fontSize: FontSizes.sm, color: color),
  );
}