// ═══════════════════════════════════════════════════════════════════════
//  IME 兜底通道：Dart 侧插入行为
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁守什么
// ```text
// runner 读出了中文（`ime-fallback commit chars=2`）之后，字必须真的进输入框。
// 三个具体判据：
//   ① 有焦点时：字插在光标处，光标落在插入末尾，composing 被清空；
//   ② 选中一段时：替换选区（不是插在选区前面）；
//   ③ 没有焦点输入框时：**什么都不做**（不许乱插到别处），且返回 false。
// ```
// 注入：把 `_insertNow` 里的 `replaceRange(start, end, text)` 改成只拼在末尾
//       ⇒ ① 的"替换选区"与 ② 都会红。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ime_fallback.dart';

Widget _host(TextEditingController c, FocusNode f) => MaterialApp(
      home: Scaffold(
        body: TextField(controller: c, focusNode: f, autofocus: true),
      ),
    );

void main() {
  testWidgets('① 有焦点：中文插在光标处，光标跟在后面，composing 清空', (t) async {
    final c = TextEditingController(text: 'ab');
    final f = FocusNode();
    addTearDown(() {
      c.dispose();
      f.dispose();
    });
    await t.pumpWidget(_host(c, f));
    await t.pumpAndSettle();
    // 光标放在 ab 之间
    c.selection = const TextSelection.collapsed(offset: 1);

    final ok = insertIntoFocusedEditableNow('中文');
    await t.pump();

    expect(ok, isTrue, reason: '★ 有焦点输入框时必须插进去');
    expect(c.text, 'a中文b', reason: '★★ 必须插在**光标处**，不是拼在末尾');
    expect(c.selection.baseOffset, 3, reason: '★ 光标要落在插入内容之后');
    expect(c.value.composing, TextRange.empty,
        reason: '★ 这是"已提交"的字，composing 必须清空（否则输入法会再改它）');
  });

  testWidgets('② 选中一段时：替换选区', (t) async {
    final c = TextEditingController(text: 'abcd');
    final f = FocusNode();
    addTearDown(() {
      c.dispose();
      f.dispose();
    });
    await t.pumpWidget(_host(c, f));
    await t.pumpAndSettle();
    c.selection = const TextSelection(baseOffset: 1, extentOffset: 3); // "bc"

    expect(insertIntoFocusedEditableNow('X'), isTrue);
    await t.pump();

    expect(c.text, 'aXd', reason: '★★ 选中 bc 时插入必须**替换**它们');
    expect(c.selection.baseOffset, 2);
  });

  testWidgets('③ 没有焦点输入框：什么都不做', (t) async {
    final c = TextEditingController(text: 'keep');
    final f = FocusNode();
    addTearDown(() {
      c.dispose();
      f.dispose();
    });
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Text('没有输入框'))));
    await t.pumpAndSettle();

    expect(insertIntoFocusedEditableNow('X'), isFalse,
        reason: '★ 没有焦点输入框时必须返回 false（不许假装成功）');
    await t.pump();
    expect(c.text, 'keep', reason: '★ 也不许改到别的 controller');
  });

  testWidgets('④ 空串直接丢（不许把已有内容清掉）', (t) async {
    final c = TextEditingController(text: 'keep');
    final f = FocusNode();
    addTearDown(() {
      c.dispose();
      f.dispose();
    });
    await t.pumpWidget(_host(c, f));
    await t.pumpAndSettle();

    expect(insertIntoFocusedEditableNow(''), isFalse);
    await t.pump();
    expect(c.text, 'keep', reason: '★★ 空串会清空用户已经打好的字 —— 必须直接丢');
  });
}
